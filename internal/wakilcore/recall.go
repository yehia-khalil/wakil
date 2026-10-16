package wakilcore

import (
	"context"
	"fmt"
	"strings"
	"unicode/utf8"
)

// sourceJira is the one fan-out target Phase 1 binds. It is the key used
// for this source in BOTH RecallOutput.Groups and SourceStatus.Source, so
// a caller can join the two by name; a second source is added by adding
// another constant and another branch in fanOut.
const sourceJira = "jira"

// RecallResult is one cited hit from one source: a human-readable title,
// a short snippet, and a link back to where it came from.
//
// Source is repeated on every result even though Groups already keys
// results by source. A caller (or an LLM) that flattens the groups, or
// quotes one result on its own, otherwise loses the citation entirely —
// and "grouped, CITED results" is the whole point of this tool per spec
// §4.5.
type RecallResult struct {
	Source  string `json:"source"`
	Title   string `json:"title"`
	Snippet string `json:"snippet"`
	Link    string `json:"link"`
}

// SourceStatus reports whether one BOUND source actually answered, and
// whether what it returned was complete.
//
// Message is set only when OK is false, and carries exactly one human
// sentence — see sourceFailureMessage for what is and is not allowed to
// reach it.
//
// Truncated mirrors IssuePage.Truncated (jira.go) straight through.
// Dropping it here would reintroduce precisely the failure that type's
// doc comment exists to prevent: a partial page read as the complete
// answer. Note that IssuePage.Truncated is also true when Jira gave no
// way to CONFIRM completeness, so a source with zero results and
// Truncated=true is not a contradiction — see jira.go's search().
//
// Filtered mirrors IssuePage.Filtered (jira.go): how many issues Jira
// returned that filterToProject dropped because their key did not belong
// to the requested project.
//
// An earlier round left this out, on the premises that it "should be 0 in
// all normal operation" and that it is "not something a recall caller can
// act on". Both premises are false for one ordinary, non-adversarial
// event, which is why it is here now: a Jira PROJECT KEY RENAME.
// Atlassian keeps the old key working as a JQL alias afterwards, so
// SearchIssues's "project = OLDKEY AND (...)" still MATCHES — but every
// issue comes back keyed NEWKEY-nnn, and filterToProject, which compares
// the literal "OLDKEY-" prefix, drops 100% of them. The page arrives as
// issues=0, Truncated=false, Filtered=n. Without this field that is
// byte-identical on the wire to a genuine zero-match: an ok=true source
// with an empty group, which an LLM reports as "there are no matching
// issues" with full confidence.
//
// A .wakil/project.json outliving a Jira key rename is normal operation,
// and the operator absolutely can act on it — the fix is to update
// scopes.pm.projectKey. So this is exactly the failure RecallOutput's doc
// comment exists to prevent, arriving through a different door than an
// unconfigured source, and the argument for Truncated ("a caller must be
// able to tell a partial or failed answer from a complete one") applies
// to it unchanged.
//
// The defence-in-depth reading still holds for the non-zero values that
// are NOT a rename — a JQL grammar edge case, or a live scope-escape
// attempt (see filterToProject). Those are rarer, and reporting them here
// costs nothing extra. Either way the drop itself stays silent-safe:
// surfacing the count never turns the filter into something that can
// fail loudly or be defeated.
type SourceStatus struct {
	Source    string `json:"source"`
	OK        bool   `json:"ok"`
	Truncated bool   `json:"truncated,omitempty"`
	Filtered  int    `json:"filtered,omitempty"`
	Message   string `json:"message,omitempty"`
}

// RecallOutput is what a recall fan-out returns: results grouped by
// source, plus a per-source status line saying whether that source
// actually answered.
//
// Spec §4.5's table sketches a bare `{ jira: [...] }` map. This type
// keeps exactly that shape one level down, in Groups, and adds Sources.
// The deviation is deliberate: a bare map cannot distinguish "Jira
// answered and nothing matched" from "the org's Jira site was never
// configured" or "the Keychain is locked" — under a bare map all three
// come back as an empty group, and an LLM told "no results" will
// confidently report there are none. That is not a hypothetical: an
// operator who has not yet completed docs/wakil/operator-todo.md §2 (set
// the org's Jira site with `wakil org create|set --jira-base`, store the
// jira:<org> credential) is the single most likely caller of this tool.
//
// Sources therefore answers "did this source actually answer?"
// separately from the results themselves. This matches the house
// invariant already set by Rows.Truncated (dbdriver.go) and
// IssuePage.Truncated / IssuePage.Filtered (jira.go): every one of those
// fields exists so a caller — an LLM in particular — can tell a partial
// or failed answer from a complete one. Consistency with that invariant
// beats the one-line sketch in the spec table.
type RecallOutput struct {
	// Groups maps source name -> that source's results, in the order the
	// source returned them. A source that is bound but FAILED gets an
	// empty, non-nil slice here (so the wire carries [] and not null)
	// alongside an OK=false entry in Sources.
	Groups map[string][]RecallResult `json:"groups"`
	// Sources has exactly one entry per BOUND source, in fan-out order.
	// A source that is not bound for the active project — no PM scope,
	// or no project key in it — appears in neither Groups nor Sources:
	// "this project has no Jira" is not a failure and must not read like
	// one.
	Sources []SourceStatus `json:"sources"`
}

// EmptyRecallOutput returns a RecallOutput with no groups and no sources
// and BOTH fields non-nil.
//
// It exists because a bare RecallOutput{} is not a usable value of this
// type: its Groups is a nil map, which marshals to JSON null. The MCP
// SDK validates a tool handler's typed Out value against the tool's
// generated output schema on every call — including the ERROR path,
// where the SDK still marshals Out even though the error itself is
// carried inside the *CallToolResult (see internal/mcpx's ToolErr doc
// comment for why the error lives there). A nil Groups fails that
// validation. Reproduced against the SDK, the client-side error is
// exactly:
//
//	calling "tools/call": validating tool output: validating root: validating /properties/groups: type: <invalid reflect.Value> has type "null", want "object"
//
// — note the `<invalid reflect.Value>` segment, which an earlier round of
// this comment quoted the sentence without; it is the SDK formatting a
// zero reflect.Value for the offending instance, not a placeholder for
// something omitted here. The call does not merely degrade: no
// CallToolResult reaches the client AT ALL, so the clean human sentence
// ToolErr built is replaced by a protocol-level error about JSON schemas
// — the exact opposite of what ToolErr is for. cmd/wakil-recall therefore
// returns this, not RecallOutput{}, alongside its error results.
func EmptyRecallOutput() RecallOutput {
	return RecallOutput{
		Groups:  map[string][]RecallResult{},
		Sources: []SourceStatus{},
	}
}

// jiraSearchFn is the seam fanOut reaches Jira through: the signature of
// (*JiraClient).SearchIssues without the receiver. It is unexported and
// exists ONLY so fanOut's rules can be tested without a Keychain, a live
// Jira, or an httptest server standing in for one. Production code has
// exactly one implementation, searchJiraFromEnv.
type jiraSearchFn func(ctx context.Context, projectKey, jql string) (IssuePage, error)

// recallQueryMaxRunes bounds how much caller-supplied text validateRecallQuery
// will let jiraJQL concatenate into a JQL string and send. Without it there
// was no cap at all, so an arbitrarily long string went onto the wire.
//
// The unit is RUNES, not bytes, and that is not cosmetic. Measured: a
// 512-BYTE cap admits only 170 CJK characters or 128 emoji, so a Japanese
// or emoji-bearing search phrase would be refused at a quarter to a third
// of the advertised length while an English one was not. This file's area
// has been bitten by byte-vs-rune confusion before; counting runes makes
// the number in the error message mean the same thing in every script.
//
// 512 is chosen from both ends:
//
//   - Generous enough that nothing real is refused. Measured against a
//     representative English bug-report sentence, prose runs about 6.1
//     runes per word, so 512 runes is roughly 83 words — several sentences,
//     well past anything anyone types into a search box — the realistic
//     queries in this package's own accepted-case tables ("date picker
//     (mobile)", "error: timeout ~ 30s", "réservation annulée") are all
//     around 20 runes. `text ~` is a CONTAINS match, so a phrase that long
//     would not be a better search anyway, which is what the error message
//     tells the caller to do instead.
//   - Small enough to be a meaningful bound. It caps this string's
//     contribution to the JQL at 512*utf8.UTFMax = 2048 bytes in the worst
//     case, whatever script it is written in.
//
// It is deliberately NOT derived from a URL length limit: jira.go's
// search() sends the JQL in a POST body, precisely so Jira's query-string
// limits do not apply, so no such budget exists to reason from here.
const recallQueryMaxRunes = 512

// validateRecallQuery checks a caller-supplied recall query and returns
// the trimmed text to actually search for.
//
// Everything rejected here is a WHOLE-CALL error from Recall, not a
// per-source failure: the caller passed something that cannot be
// searched for anywhere, and reporting that as "jira failed" would blame
// a source for the caller's input. (Phase 1 has one source, so the
// distinction is currently invisible on the wire; it stops being
// invisible the moment a second fan-out target is added, which is why
// the check lives here and not in the Jira branch.)
//
// What is rejected, and why each is a rejection rather than an escape:
//   - an empty or whitespace-only query: `text ~ ""` asks Jira to match
//     on nothing at all, which is not what the caller meant either way.
//   - a double or single quote: the query is concatenated into a
//     double-quoted JQL string (see jiraJQL) with no escaping, and the
//     only escape JQL offers is a backslash.
//   - a backslash: jira.go's validateBalancedJQL rejects any backslash
//     outright, so escaping is not available one layer down either. A
//     backslash that reached that layer would come back as a message
//     about JQL, which a caller who only typed a search phrase cannot
//     act on.
//   - any byte below 0x20: control characters have no meaning inside a
//     JQL string, and a raw newline inside one is a parse error.
//   - more than recallQueryMaxRunes runes: see that constant.
//
// The character checks run on the TRIMMED query, which is also what
// jiraJQL is given, so a trailing newline from a copy-paste is trimmed
// away rather than rejected while an interior one is rejected. Scanning
// bytes rather than runes is safe: every byte of a multi-byte UTF-8 rune
// is >= 0x80, so non-ASCII text can never trip the control-character
// check and is otherwise passed through untouched.
func validateRecallQuery(query string) (string, error) {
	q := strings.TrimSpace(query)
	if q == "" {
		return "", UserError("recall needs something to search for")
	}
	if n := utf8.RuneCountInString(q); n > recallQueryMaxRunes {
		return "", UserError(fmt.Sprintf(
			"recall query is too long (%d characters, limit %d) — search for the few distinctive words instead of pasting the whole text",
			n, recallQueryMaxRunes))
	}
	if strings.ContainsAny(q, `"'`) {
		return "", UserError(`recall query must not contain a quote character (" or ') — search for the same words without quotes`)
	}
	if strings.Contains(q, `\`) {
		return "", UserError("recall query must not contain a backslash — search for the same words without it")
	}
	for i := 0; i < len(q); i++ {
		if q[i] < 0x20 {
			return "", UserError("recall query must not contain control characters — search for the same words as plain text")
		}
	}
	return q, nil
}

// jiraJQL builds the Jira fan-out target's JQL fragment for a query that
// validateRecallQuery has already accepted.
//
// The query is concatenated into a double-quoted JQL string with no
// escaping whatsoever. That is safe only because validateRecallQuery has
// already rejected every character that could end the string or be read
// as an escape: `"`, `'`, `\`, and every byte below 0x20. Do not
// "improve" this by escaping quotes instead — an escape means a
// backslash, and jira.go's validateBalancedJQL rejects any backslash
// outright (see SearchIssues's doc comment for why that ban is what
// makes its scope-escape defense provable rather than merely plausible).
// Rejection is the correct posture here, not a limitation to work around.
//
// This is the OUTER of several layers, not the only one. Whatever this
// builds is independently re-validated by validateBalancedJQL, then
// scoped by SearchIssues into "project = <key> AND (<jql>)", and every
// issue that comes back is post-filtered by filterToProject to keys
// under that project. Recall cannot read outside the active project's
// Jira scope even if this function were wrong.
//
// There is deliberately NO "ORDER BY updated DESC" clause, though both
// the plan and the task brief called for one. SearchIssues wraps this
// fragment in parentheses; JQL's ORDER BY is a top-level clause that
// follows the entire where-clause and is not a term that may appear
// inside a parenthesised sub-clause, so "project = RAF AND (text ~ \"x\"
// ORDER BY updated DESC)" is a syntax error and every recall call would
// come back a Jira 400. That is a grammar argument from Atlassian's
// documented JQL syntax, not something these tests can verify against a
// live Jira — the same standard of evidence as SearchIssues's backslash
// ban. Ordering is not part of what §4.5 asks for ("no unified ranking,
// no index"), and buying it back would mean changing how SearchIssues
// wraps a fragment, which wakil-pm's search_issues tool depends on.
// TestRecallSendsUnorderedScopedJQL pins the exact JQL that reaches the
// wire, including the absence of ORDER BY.
func jiraJQL(query string) string {
	return `text ~ "` + query + `"`
}

// issuesToResults projects a page of Jira issues into cited recall
// results, preserving the order Jira returned them in.
//
// It always returns a NON-NIL slice, empty for a nil or empty input.
// That invariant is what puts `[]` rather than `null` on the wire for a
// source that answered with nothing — it is the same invariant jira.go's
// search() maintains for IssuePage.Issues. The reason is semantic, not
// schema-level: a null group is one more way for "answered, nothing
// matched" to be confused with "did not answer at all", which is the
// confusion RecallOutput exists to remove.
//
// It is specifically NOT a schema argument, though an earlier round of
// this comment made one. Dumped from a live ListTools round trip, the
// SDK-generated output schema for this tool declares the group arrays as
// `"type": ["null", "array"]` — they explicitly ADMIT null, so a client
// validating against this tool's own advertised schema cannot reject a
// null group. (The `groups` MAP is the opposite case: it is declared
// `"type": "object"`, admits no null, and a nil one fails the SDK's own
// output validation — see EmptyRecallOutput.)
//
// Snippet carries the issue's status. Issue (jira.go) is a deliberately
// small projection with no description or comment body on it, so there
// is no real excerpt to quote; status is the most useful short context
// available without widening search()'s fields request, which is out of
// scope for Phase 1.
func issuesToResults(issues []Issue) []RecallResult {
	out := make([]RecallResult, 0, len(issues))
	for _, i := range issues {
		out = append(out, RecallResult{
			Source:  sourceJira,
			Title:   i.Key + ": " + i.Summary,
			Snippet: i.Status,
			Link:    i.URL,
		})
	}
	return out
}

// sourceFailureMessage renders err as the single human sentence a failed
// source reports in SourceStatus.Message.
//
// Only a UserError's message is relayed, and it is relayed verbatim.
// That is safe because every UserError reachable on the Jira path is one
// of three things:
//   - fixed prose: NewJiraFromEnv's "WAKIL_ORG is not set — every Wakil
//     process runs for exactly one org. ..." when the org itself cannot
//     be resolved, search()'s 401/403 re-auth line, validateBalancedJQL's
//     rejections;
//   - prose plus a value from which every credential-bearing component
//     has been REMOVED, not merely masked: normalizeJiraBase names a
//     rejected base URL by scheme and host only (safeBaseHint — an
//     earlier round used url.URL.Redacted() here, which masks only a
//     userinfo PASSWORD and let a bare "https://<token>@host", a query
//     string and a fragment through verbatim onto this very field);
//   - prose plus a value that is not a credential channel at all: a
//     project or issue key, which comes from the project's own
//     .wakil/project.json or from the caller's tool argument and never
//     from the Keychain; an org id, e.g. NewJiraFromEnv's "no Jira site
//     configured for org ... — set one with: wakil org set ..." when
//     org.json has no jiraBase; or `security`'s stderr, which reports
//     why the Keychain read failed and so is produced on the path where
//     no secret was retrieved (see secrets.go's diagnostic);
//   - text that has been through the credential-scrubbing pipeline:
//     jira.go's search() runs
//     scrubForms/scrubCutPoint/scrubSecrets/stripPartialCredentialTail
//     over any 4xx/5xx body before wrapping it, and a transport failure
//     is UserError(c.scrubSecrets(...)).
//
// Anything else gets a fixed sentence and nothing more — err.Error() is
// never relayed. A non-UserError has NOT been through that pipeline
// (jira.go's "marshal Jira search request" path, for one, is a plain
// fmt.Errorf), and unlike mcpx.ToolErr's output — which surfaces as an
// error an operator is reading — this text is an ordinary field of a
// SUCCESSFUL tool result that goes straight into an LLM transcript. Fail
// closed on the diagnostic, not on the confidentiality.
func sourceFailureMessage(source string, err error) string {
	if msg, ok := IsUserError(err); ok {
		return msg
	}
	return source + ": request failed"
}

// fanOut is Recall's testable core: every rule of a recall call that
// does not depend on reading the environment. Recall is the thin wrapper
// that resolves the active project and supplies the real Jira search;
// splitting them is what lets these rules be tested without a Keychain,
// a network, or a project fixture.
//
// jiraProjectKey is the active project's configured Jira project key, or
// "" when this project has no Jira binding at all. jiraSearch is called
// only when that key is non-empty, which is what keeps an unbound
// project from ever reaching NewJiraFromEnv and therefore the Keychain.
//
// The three populating rules, which the mutation tests pin:
//   - bound and succeeded: Groups[src] set (possibly empty), one
//     SourceStatus with OK true and both of page's completeness signals,
//     Truncated and Filtered, carried across.
//   - bound and FAILED: Groups[src] set to an empty, non-nil slice, one
//     SourceStatus with OK false and one human sentence.
//   - NOT BOUND: no group and no SourceStatus at all. "Not configured
//     for this project" and "configured but broken" must not read the
//     same to a caller.
//
// Query validation runs here rather than in Recall so it is reachable
// from a unit test with no project fixture. The cost is ordering: with
// both an unusable query and no active project, Recall surfaces
// Resolve's error first. Both are UserErrors and both are actionable, so
// which one wins is not load-bearing.
func fanOut(ctx context.Context, query, jiraProjectKey string, jiraSearch jiraSearchFn) (RecallOutput, error) {
	q, err := validateRecallQuery(query)
	if err != nil {
		return RecallOutput{}, err
	}
	// Both fields start non-nil (see EmptyRecallOutput) so that a call
	// binding no sources at all marshals to {"groups":{},"sources":[]}
	// rather than {"groups":null,"sources":null}.
	out := EmptyRecallOutput()
	if jiraProjectKey != "" {
		page, err := jiraSearch(ctx, jiraProjectKey, jiraJQL(q))
		if err != nil {
			out.Groups[sourceJira] = []RecallResult{}
			out.Sources = append(out.Sources, SourceStatus{
				Source:  sourceJira,
				OK:      false,
				Message: sourceFailureMessage(sourceJira, err),
			})
		} else {
			out.Groups[sourceJira] = issuesToResults(page.Issues)
			out.Sources = append(out.Sources, SourceStatus{
				Source:    sourceJira,
				OK:        true,
				Truncated: page.Truncated,
				Filtered:  page.Filtered,
			})
		}
	}
	return out, nil
}

// searchJiraFromEnv is the production jiraSearchFn: it builds a Jira
// client from the environment and Keychain and runs one project-scoped
// search.
//
// NewJiraFromEnv's error is returned as-is rather than being handled
// here, so that fanOut treats "Jira is not configured" exactly like
// "Jira is configured but the search failed": both become an OK=false
// SourceStatus carrying NewJiraFromEnv's own message. Those messages are
// deliberately distinct — "no Jira site configured for org ... — set one
// with: wakil org set ... --jira-base ...", "WAKIL_ORG is not set" when
// there is no org to resolve at all, SecretGet's locked-Keychain vs
// missing-item distinction, and a malformed stored credential — and
// discarding them (as `if c, err := NewJiraFromEnv(); err == nil` would)
// is exactly what makes an unconfigured Jira read to an LLM as "there
// are no matching issues".
func searchJiraFromEnv(ctx context.Context, projectKey, jql string) (IssuePage, error) {
	c, err := NewJiraFromEnv()
	if err != nil {
		return IssuePage{}, err
	}
	return c.SearchIssues(ctx, projectKey, jql)
}

// Recall fans query out across the sources bound to the active project
// and returns grouped, cited results. Phase 1 binds exactly one source,
// Jira; adding a source means adding a fan-out target inside fanOut, not
// changing this function's shape.
//
// Recall calls its providers directly and never calls another Wakil MCP
// server (plan Global Constraints); it shares provider client code with
// wakil-pm through wakilcore's JiraClient.
//
// The returned error is reserved for WHOLE-CALL failures: no active
// project, or a query that cannot be sent anywhere (see
// validateRecallQuery). A bound source that fails is not an error — it
// comes back as an empty group plus an OK=false SourceStatus. See
// RecallOutput for why that distinction is the point of this type.
//
// On error the returned RecallOutput is the zero value, whose Groups is
// a nil map; a caller that must still put a RecallOutput on the wire
// (cmd/wakil-recall does) should send EmptyRecallOutput() instead.
func Recall(ctx context.Context, query string) (RecallOutput, error) {
	r, err := Resolve()
	if err != nil {
		return RecallOutput{}, err
	}
	// Only ProjectKey is consulted, not Scopes.PM.Provider — deliberately
	// the same test cmd/wakil-pm's projectKey() applies. Phase 1 has one
	// PM provider, and if recall and wakil-pm disagreed about whether a
	// project is Jira-bound, one of the two would be silently wrong about
	// the same config.
	jiraProjectKey := ""
	if r.Project.Scopes.PM != nil {
		jiraProjectKey = r.Project.Scopes.PM.ProjectKey
	}
	return fanOut(ctx, query, jiraProjectKey, searchJiraFromEnv)
}
