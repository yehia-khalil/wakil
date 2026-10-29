package wakilcore

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// JiraClient is a minimal, read-only Jira Cloud REST client scoped to a
// single project per active Wakil project config. Servers never call each
// other (see plan Global Constraints); this client only ever talks to the
// Atlassian Jira REST API over HTTPS.
type JiraClient struct {
	BaseURL string
	Email   string
	Token   string
	// http is built once, on first use: wakil-ticket reads several issues at once on one client.
	httpOnce sync.Once
	http     *http.Client
}

// Issue is the shape wakil-pm's tools return: a deliberately small
// projection of a Jira issue, not the raw Jira JSON.
type Issue struct {
	Key      string `json:"key"`
	Summary  string `json:"summary"`
	Status   string `json:"status"`
	Assignee string `json:"assignee"`
	URL      string `json:"url"`
}

// IssuePage is a single page of Jira search results, together with
// whether more results exist beyond this page. This mirrors the house
// style set by Rows.Truncated (see dbdriver.go): a struct-typed result
// lets a caller — in particular an LLM — distinguish a complete list from
// a partial one, instead of silently trusting a fixed-size page as
// though it were the whole answer. It also avoids an unbounded
// pagination loop: Atlassian documents that this endpoint may return
// FEWER items than maxResults even when more exist ("API may return
// fewer items per page where a large number of fields are requested"),
// so the raw item count alone was never a reliable completeness signal.
type IssuePage struct {
	Issues    []Issue `json:"issues"`
	Truncated bool    `json:"truncated,omitempty"`
	// Filtered counts issues Jira returned but that filterToProject
	// dropped because their key did not belong to the requested project.
	// It should be 0 in normal operation. A non-zero value is a signal
	// worth investigating, not routine: it means Jira handed back an
	// issue outside the requested scope, which is either a JQL grammar
	// edge case this codebase doesn't know about or a live scope-escape
	// attempt — see filterToProject's doc comment. This field exists
	// purely to make that drop visible; it deliberately does NOT turn
	// the drop into an error, because the filter is defence in depth and
	// must keep working silently in the safety sense (fail closed on the
	// response, not fail loud on the caller) regardless of whether
	// anyone is watching Filtered.
	Filtered int `json:"filtered,omitempty"`
}

// projectKeyPattern and issueKeyPattern bound what wakil-pm will ever
// interpolate unquoted into a JQL string. Both `projectKey` and `key` are
// concatenated directly into the JQL sent to Jira (there is no
// parameterized-query facility in JQL), so an unvalidated value is a
// straight injection/scope-escape vector — see SearchIssues and GetIssue.
var (
	projectKeyPattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)
	issueKeyPattern   = regexp.MustCompile(`^[A-Z][A-Z0-9_]*-[0-9]+$`)
)

// jiraErrorBodyCap bounds how much of a Jira error response body is ever
// spliced into a user-facing message. Jira 4xx/5xx bodies can be whole
// HTML error pages; without a cap, one lands verbatim in front of a human.
const jiraErrorBodyCap = 200

// NewJiraFromEnv builds a JiraClient from org.json and the Keychain: a
// base URL from the current org's record, and email:api_token stored
// under Keychain ref "jira:<org>" for the currently active org (see
// CurrentOrg). WAKIL_JIRA_BASE is still read, but only as an override of
// the org record — see the precedence comment below. This is a
// deliberate deviation from wrapping Claude Code's own Atlassian OAuth
// token store (fragile, internal, undocumented) in favor of the same
// ref -> Keychain pattern already used by every other Wakil credential.
func NewJiraFromEnv() (*JiraClient, error) {
	// org is resolved first, unconditionally: NewJiraFromEnv cannot do
	// anything useful without it (the credential it ultimately needs is
	// keyed jira:<org>, and the org.json fallback below is keyed by org
	// too), so with WAKIL_ORG unset "WAKIL_ORG is not set" is the honest
	// first error rather than a complaint about URL syntax.
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	// WAKIL_JIRA_BASE stays supported as an override, deliberately: it is
	// the only escape hatch when org.json is wrong and a Jira call is
	// needed to diagnose something. The org record is the normal source,
	// because an org may have several providers and a value baked into
	// each registration is N chances for two of them to disagree.
	rawBase := os.Getenv("WAKIL_JIRA_BASE")
	// source names, for normalizeJiraBase's rejection messages, whichever
	// of the two knobs actually supplied rawBase — see finding 5 of the
	// final review: every one of those messages used to say
	// "WAKIL_JIRA_BASE must ...", which was simply false on the org.json
	// path (the org's normal source, below) and told the operator to fix
	// an environment variable they never set.
	source := "WAKIL_JIRA_BASE"
	if rawBase == "" {
		o, err := LoadOrgFor(org)
		if err != nil {
			return nil, err
		}
		rawBase = o.JiraBase
		if rawBase == "" {
			return nil, UserError("no Jira site configured for org " + strconv.Quote(org) +
				" — set one with: wakil org set " + org + " --jira-base https://<site>.atlassian.net")
		}
		source = "org " + strconv.Quote(org) + "'s jiraBase (org.json)"
	}
	base, err := normalizeJiraBase(rawBase, source)
	if err != nil {
		return nil, err
	}
	// SecretGet already distinguishes "no such item" (Keychain exit 44)
	// from any other failure (locked keychain, denied access, missing
	// `security` binary, ...) and returns a UserError describing exactly
	// which happened — see secrets.go's diagnostic(). Propagating that
	// error unchanged, instead of collapsing every SecretGet failure into
	// a single "not authenticated" message, is the fix for the diagnostic
	// loss the controller flagged: a locked keychain is not the same
	// problem as a missing credential, and should not read the same.
	creds, err := SecretGet("jira:" + org)
	if err != nil {
		return nil, err
	}
	parts := strings.SplitN(creds, ":", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return nil, UserError("stored Jira credential for jira:" + org + " must be email:api_token")
	}
	return &JiraClient{BaseURL: base, Email: parts[0], Token: parts[1]}, nil
}

// normalizeJiraBase requires base to parse as an absolute https URL with
// no userinfo, query, fragment, or path, and returns "scheme://host" with
// no trailing slash.
//
// source names, in every rejection message, WHERE base actually came
// from — "WAKIL_JIRA_BASE" for NewJiraFromEnv's env-var override,
// "org "x"'s jiraBase (org.json)" when NewJiraFromEnv fell back to the
// org record, "--jira-base" when normaliseOrg (org.go) is validating a
// value on its way INTO org.json. A hardcoded "WAKIL_JIRA_BASE" in every
// message, regardless of which of those actually supplied base, would
// send an operator who typed `wakil org create ... --jira-base bad` off
// to fix an environment variable they never set.
//
// Every one of the restrictions below closes a real hole:
//   - userinfo (https://user:pass@host) would make the environment
//     variable a second credential channel, directly against the
//     standing constraint that secrets live only in the Keychain, never
//     in an env var.
//   - a query string or fragment would silently ride along into
//     "BaseURL + /rest/api/3/search/jql" (see search, below), e.g.
//     "https://x/?a=b" would send the API path itself into the query
//     string rather than the path.
//   - a path would compound the same way: BaseURL is string-concatenated
//     with "/rest/api/3/search/jql" and "/browse/<key>", so a
//     "https://x/foo" base would build a request against
//     "https://x/foo/rest/api/3/search/jql" instead of the real endpoint.
//
// No rejection here echoes the raw input, or url.URL.Redacted() of it.
// Every one names the offending base by ORIGIN ONLY, via safeBaseHint —
// see that function for why Redacted() was not enough.
func normalizeJiraBase(base, source string) (string, error) {
	u, err := url.Parse(base)
	if err != nil {
		return "", UserError(source + " must be an absolute https URL")
	}
	if !u.IsAbs() || u.Scheme != "https" || u.Host == "" {
		return "", UserError(source + " must be an absolute https URL" + safeBaseHint(u))
	}
	if u.User != nil {
		return "", UserError(source + " must not contain credentials — store the Jira token in the Keychain, not the base URL" + safeBaseHint(u))
	}
	if u.RawQuery != "" {
		return "", UserError(source + " must not contain a query string" + safeBaseHint(u))
	}
	if u.Fragment != "" {
		return "", UserError(source + " must not contain a fragment" + safeBaseHint(u))
	}
	if strings.Trim(u.Path, "/") != "" {
		return "", UserError(source + " must not contain a path" + safeBaseHint(u))
	}
	return "https://" + u.Host, nil
}

// safeBaseHint renders u as the ", got <origin>" tail normalizeJiraBase
// appends to a rejection message, or "" when there is nothing safe and
// useful to name.
//
// <origin> is the SCHEME AND HOST ONLY. Userinfo, path, query, fragment
// and opaque are DROPPED, not redacted. That is the entire point of this
// helper: it replaces url.URL.Redacted(), which masks ONLY a userinfo
// PASSWORD and leaves every other component verbatim. Measured against
// Go's own net/url (go1.x, TestSafeBaseHintDropsEveryCredentialCarrier
// re-measures it on every run):
//
//	https://user:TOKEN@acme.atlassian.net  ->  https://user:xxxxx@acme.atlassian.net
//	https://TOKEN@acme.atlassian.net       ->  unchanged — bare username survives
//	https://acme.atlassian.net?t=TOKEN     ->  unchanged
//	https://acme.atlassian.net#t=TOKEN     ->  unchanged
//
// Three of those four leak in full, and the first of the three — a bare
// userinfo username with no colon — is precisely the operator mistake the
// "must not contain credentials" message names: an Atlassian API token
// pasted in front of the host instead of stored in the Keychain.
//
// Dropping is the right answer rather than merely the safer one, because
// each of these messages is complaining that the component EXISTS.
// Echoing it back adds no diagnostic value the sentence does not already
// carry, while the origin does add value: it tells an operator who
// administers several Atlassian sites which base URL they got wrong.
//
// This became load-bearing with Task 16. These messages previously
// reached only mcpx.ToolErr, as an error an operator is reading;
// wakilcore.Recall now relays a UserError VERBATIM into
// SourceStatus.Message, which is an ordinary field of a SUCCESSFUL tool
// result that wakil-recall's own tool description instructs the model to
// read — so anything that survives here lands in an LLM transcript.
//
// The empty return covers a URL with no host at all ("api.example.com",
// "/just/a/path", "https://", "mailto:x@y.z"), which can reach only the
// "must be an absolute https URL" branch. There is no origin to show, and
// both alternatives are worse: "://" is meaningless, and falling back to
// u.Path or u.Opaque would echo the raw input this helper exists to stop
// echoing — url.Parse puts an entire unparseable string into Path, so
// "TOKEN@acme.atlassian.net" (the same paste, minus the scheme) would
// come straight back out. The sentence still names the environment
// variable, which is what the operator has to act on.
func safeBaseHint(u *url.URL) string {
	switch {
	case u.Host == "":
		return ""
	case u.Scheme == "":
		// A scheme-relative "//acme.atlassian.net/x": there is a host
		// worth naming, but "://acme.atlassian.net" would read as a
		// typo of its own rather than as the operator's input.
		return ", got " + u.Host
	default:
		return ", got " + u.Scheme + "://" + u.Host
	}
}

// scrubForms, scrubSecrets, and the rest of the credential-scrubbing
// machinery this client relies on (scrubForm, jiraScrubMinTokenLen,
// literalsOf, scrubCutPoint, stripPartialCredentialTail and the
// stripPartialCredentialSuffix / dropTrailingIncompleteRune it
// sequences, truncateBytesAtRuneBoundary,
// longestScrubForm) now live in secretscrub.go — see that file for the
// full history of what each layer fixes (the interval-merge fix, the
// raw-coordinate cut, the partial-suffix backstop and the drop/strip/drop
// order it needs, the rune-safe truncation) and for SecretScrubber, the
// credential-agnostic form
// wakil-http's DoRequest builds from its own resolved auth token to
// answer the identical threat: a server echoing the Authorization header
// it was sent back into a response, handing the Keychain-held credential
// to whatever reads the MCP tool result. A live probe proved this exact
// path against Jira: a 500 response body of "echo: " + the raw
// Authorization header decoded to "person@example.com:sup3rsecret" once
// base64-decoded (see TestJiraScrubsTokenFromEchoedAuthHeader).
//
// scrubForms returns every credential representation scrubSecrets treats
// as sensitive and replaces with "[redacted]". The slice order carries no
// meaning — scrubSecrets merges occurrence intervals rather than applying
// forms in sequence. Factored out of scrubSecrets so that the
// error-body read window in search() — which must be wide enough to
// contain the LONGEST of these forms even when it starts right at the
// cap boundary — is computed from this exact list, not a second,
// independently-maintained number that could silently drift out of sync
// with what scrubSecrets actually scrubs.
func (c *JiraClient) scrubForms() []scrubForm {
	pair := c.Email + ":" + c.Token
	var forms []scrubForm
	// Pair forms are gated on the PAIR being degenerate (both halves
	// empty, i.e. pair is exactly ":"), not on checking each of its
	// derived literals ("", ":", the empty pair's base64...) one at a
	// time: a per-literal check only ever catches the specific encodings
	// someone thought to list, and round 4 found exactly that gap — the
	// old guard skipped the bare "" and ":" forms but NOT the degenerate
	// pair's base64 ("Og==", "Og"), which then got ReplaceAll'd across
	// the entire error body, shredding unrelated diagnostic text. Keying
	// on the pair itself closes that for every encoding at once.
	// Not reachable via NewJiraFromEnv, which rejects empty halves — this
	// is defence in depth for a directly-constructed JiraClient.
	if pair != ":" {
		// pairMin is the shortest trailing suffix of the pair that
		// necessarily includes byte(s) of the TOKEN, not just the email
		// and the separating colon — a shorter suffix can only ever be a
		// suffix of the email alone. pairB64Min is the base64-encoded
		// equivalent, rounded UP to the next 4-char/3-byte block: base64
		// doesn't encode byte boundaries 1:1, so the shortest base64
		// suffix guaranteed to touch a token byte is one full encoded
		// block past ceil(pairMin/3) 3-byte groups. appendSecretForms
		// (secretscrub.go) builds the actual 5 literal forms from these
		// two numbers, identically to how it builds the token-only case
		// below and how SecretScrubber builds its single-secret case.
		pairMin := len(c.Email) + 1
		pairB64Min := 4 * ((pairMin + 2) / 3)
		forms = appendSecretForms(forms, pair, pairMin, pairB64Min)
	}
	// Length-gated: forms whose length tracks the token's, and which
	// therefore risk shredding unrelated diagnostic text when the token
	// is a short placeholder. jiraScrubMinTokenLen doubles as both the
	// inclusion gate here and the minLen floor below, since a token-only
	// form has no email portion to protect against.
	if len(c.Token) >= jiraScrubMinTokenLen {
		forms = appendSecretForms(forms, c.Token, jiraScrubMinTokenLen, jiraScrubMinTokenLen)
	}
	return forms
}

// scrubSecrets scrubs msg using this client's own credential forms (see
// scrubForms above) — see secretscrub.go's scrubSecrets for the
// interval-merge algorithm itself, unchanged by this extraction.
func (c *JiraClient) scrubSecrets(msg string) string {
	return scrubSecrets(msg, literalsOf(c.scrubForms()))
}

// errJiraRedirect is returned by the http.Client's CheckRedirect hook to
// refuse every redirect outright. A read-only search API never
// legitimately redirects; Go's default client policy follows up to 10
// redirects and preserves the Authorization header across same-hostname
// redirects, which would hand the Jira credential to whatever a
// compromised or misconfigured Jira instance redirected to.
var errJiraRedirect = fmt.Errorf("Jira response tried to redirect; refusing to follow")

func (c *JiraClient) client() *http.Client {
	c.httpOnce.Do(func() {
		c.http = &http.Client{
			Timeout: 20 * time.Second,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return errJiraRedirect
			},
		}
	})
	return c.http
}

// jiraSearchRequest is the JSON body for POST /rest/api/3/search/jql, the
// live replacement for the removed GET /rest/api/2|3/search endpoints
// (both returned 410 Gone as of 2025-05-01). Confirmed against
// developer.atlassian.com's issue-search API group and Atlassian's own
// migration guidance: fields is a JSON array (not a comma-joined query
// param), and pagination uses nextPageToken — there is no startAt and no
// total in the new shape.
//
// MaxResults is capped at a single page (50): Phase 1's tool surface
// never asks for more than "the current list", and looping over
// nextPageToken without a caller-visible cap risks an unbounded number of
// requests for one tool call. Trading pagination for a single page plus
// an explicit Truncated flag (see IssuePage) means a caller always knows
// whether it saw everything, without wakil-pm silently deciding how many
// pages "enough" is.
type jiraSearchRequest struct {
	JQL           string   `json:"jql"`
	Fields        []string `json:"fields"`
	MaxResults    int      `json:"maxResults,omitempty"`
	NextPageToken string   `json:"nextPageToken,omitempty"`
}

// jiraSearchResponse decodes the full set of completeness signals the
// live endpoint sends, not just the issue list: NextPageToken and IsLast
// both indicate more results exist beyond this page, and Warnings is
// where Jira reports ingestion-limit truncation of the CURRENT page
// (e.g. too many fields requested) — a case where isLast can be true and
// nextPageToken can be absent even though the page itself was cut short.
// All three feed IssuePage.Truncated in search, below; none is silently
// dropped.
//
// Warnings is deliberately json.RawMessage — a raw slot for whatever JSON
// value the field holds — not a slice of any element shape. A first fix
// changed it from []string to []json.RawMessage after real Jira sent
// warning OBJECTS (e.g. {"type":"CLAUSE_LIMIT_EXCEEDED",...}) where
// []string expected bare strings, hard-failing the whole decode with a
// non-UserError error on exactly the response a warning exists to report.
// But []json.RawMessage is still a SLICE field: the JSON value for
// `warnings` itself must still decode as an array, or the decode fails
// the same way. A probe found three shapes that still break it: a bare
// object, a bare string, and a bare number for `warnings` (not wrapped in
// an array) each reproduce the original hard failure. We do not control
// this schema and guessing it wrong has already cost a removed endpoint
// (see the search doc comment) and one prior hard-failure bug (above);
// json.RawMessage accepts ANY valid JSON value the field holds — array,
// object, string, number, bool, null — so no server-side shape for
// `warnings` can break the call, full stop, not just the array-of-any-
// element-shape case the first fix covered. See hasWarnings, below, for
// how the truncation signal is derived without ever unmarshaling this
// into an assumed shape.
type jiraSearchResponse struct {
	Issues []struct {
		Key    string `json:"key"`
		Fields struct {
			Summary string `json:"summary"`
			Status  struct {
				Name string `json:"name"`
			} `json:"status"`
			Assignee struct {
				DisplayName string `json:"displayName"`
			} `json:"assignee"`
		} `json:"fields"`
	} `json:"issues"`
	NextPageToken string          `json:"nextPageToken"`
	IsLast        *bool           `json:"isLast"`
	Warnings      json.RawMessage `json:"warnings"`
}

// hasWarnings reports whether raw represents a "there are warnings"
// signal worth feeding into IssuePage.Truncated: present in the response,
// and neither JSON `null` nor an empty array `[]` (an absent field
// decodes to a nil/zero-length raw, which is handled the same as `null`).
// Any other decoded shape at all — including a non-empty array, a bare
// object (even `{}`), a bare string (even `""`), a number (even `0`), or
// a bool (even `false`) — counts as "has warnings": the only two values
// this function treats as "no warnings" are JSON `null` and `[]`. This
// matches the broadened tolerance in jiraSearchResponse's doc comment: whatever shape
// Jira sends here, this never re-derives a count from it (it must not
// unmarshal an assumed shape), it only asks "is this the absence value or
// not". A malformed raw (should not happen — json.Unmarshal already
// decoded the surrounding document successfully) is treated as no
// signal, matching the safe-toward-"assume more" posture only where a
// signal actually exists to interpret.
func hasWarnings(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return false
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return false
	}
	switch t := v.(type) {
	case nil:
		return false
	case []any:
		return len(t) > 0
	default:
		return true
	}
}

// search issues a single-page POST /rest/api/3/search/jql request for jql
// and decodes the result into an IssuePage. jql must already be fully
// formed and scoped: callers (MyIssues, SearchIssues, GetIssue) are
// responsible for validation and project scoping before calling this —
// including the post-filter described in SearchIssues's doc comment,
// which this function does NOT apply, since GetIssue needs a different
// projectKey-vs-single-key check than a page of results does.
//
// This is a write-verb (POST) request performing a read-only operation —
// the live Jira issue-search API simply has no GET-with-body option that
// avoids Jira's query-string length limits. It does not weaken the
// read-only constraint: this client never calls any genuinely mutating
// Jira endpoint (comment, transition, worklog, edit).
func (c *JiraClient) search(ctx context.Context, jql string) (IssuePage, error) {
	reqBody := jiraSearchRequest{
		JQL:        jql,
		Fields:     []string{"summary", "status", "assignee"},
		MaxResults: 50,
	}
	b, err := json.Marshal(reqBody)
	if err != nil {
		return IssuePage{}, fmt.Errorf("marshal Jira search request: %w", err)
	}

	u := c.BaseURL + "/rest/api/3/search/jql"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(b))
	if err != nil {
		// This is the ONE UserError on this path that does not go
		// through scrubSecrets, and it is deliberate: err.Error() here
		// is unreachable in production, and harmless even if it were
		// reached.
		//
		// Unreachable: NewRequestWithContext fails on exactly three
		// things — a method containing an invalid token (this one is
		// the http.MethodPost constant), a nil ctx (the MCP SDK always
		// supplies one), and a url.Parse failure on u. u is
		// c.BaseURL + a fixed ASCII path, and the only production
		// construction of a JiraClient is NewJiraFromEnv, which sets
		// BaseURL to normalizeJiraBase's "https://" + u.Host — a host
		// url.Parse itself just produced. Recomposing that never fails
		// to re-parse: verified by injecting all 256 single bytes into
		// a host and by ~4M random hosts over URL-significant runes,
		// with zero failures.
		//
		// Harmless: a *url.Error's message is `parse "<url>": <reason>`,
		// and that <url> is BaseURL plus the fixed path — an origin, not
		// a credential. normalizeJiraBase has already stripped any
		// userinfo, query and fragment from it, and the Keychain-held
		// token never appears in the URL at all (it rides in the
		// Authorization header, set below).
		return IssuePage{}, UserError("could not build Jira request: " + err.Error())
	}
	req.SetBasicAuth(c.Email, c.Token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client().Do(req)
	if err != nil {
		return IssuePage{}, UserError(c.scrubSecrets("Jira unreachable: " + err.Error()))
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		// org falls back to "this org" rather than propagating CurrentOrg's
		// error: this path is reporting a Jira auth failure, and a second,
		// unrelated failure (WAKIL_ORG unset) must not swallow that message.
		org := "this org"
		if got, err := CurrentOrg(); err == nil {
			org = got
		}
		return IssuePage{}, UserError("re-auth " + org + ": Jira rejected the stored credential")
	}
	if resp.StatusCode >= 400 {
		// Multiple independent layers — see scrubSecrets's doc comment for
		// why scrub-before-truncate ordering ALONE (round 3's fix) is not
		// enough: scrubbing shrinks the string, so a credential echoed
		// TWICE in the same body can drag the second occurrence's bytes
		// into the visible prefix after the first is redacted, leaking a
		// verbatim partial of it that never fully matched any scrub form.
		//
		// PRIMARY: read a window wide enough that any scrub form starting
		// anywhere within the first jiraErrorBodyCap bytes is read in
		// FULL — jiraErrorBodyCap plus the longest form's length — then
		// let scrubCutPoint choose the display cut in RAW, pre-scrub
		// coordinates: starting at jiraErrorBodyCap, pushed forward past
		// the end of any credential-form occurrence straddling it. Only
		// THEN scrub (body[:cut]), and only then cut the already-scrubbed
		// result down to jiraErrorBodyCap for display. Because every form
		// occurrence inside the cut region is whole, AND scrubSecrets
		// itself merges overlapping/adjacent occurrences before replacing
		// any of them (round 5's fix for a periodic-form gap — see that
		// function's doc comment), scrubbing removes every occurrence in
		// that region entirely; the final display cap can then only
		// shorten already-scrubbed text, never expose a fresh, previously
		// out-of-window byte range.
		//
		// SECONDARY (defence in depth, genuinely reachable — see
		// stripPartialCredentialSuffix's doc comment for a measured
		// firing count and the exact gap it
		// closes): stripPartialCredentialTail strips any trailing suffix
		// of the final displayed text that is itself a prefix of a
		// credential form, AND any trailing INCOMPLETE rune — a dangling
		// lead byte plus its continuation bytes, which is what a cut
		// through valid UTF-8 produces.
		//
		// Those two are one call, not two statements, and the order
		// inside it (drop, strip, drop) is the whole point: this code
		// used to strip and then drop, which leaked, because a dangling
		// UTF-8 byte sitting after a credential partial made the strip's
		// suffix test fail and the drop then removed that byte and
		// re-exposed the partial. That is not hypothetical here — one of
		// the two routes to a mid-rune ending listed below is a
		// mid-stream connection drop, which cuts the body at an arbitrary
		// byte, and the resulting UserError is relayed VERBATIM by
		// recall.go's sourceFailureMessage into SourceStatus.Message,
		// which wakil-recall's tool description tells the model to read.
		// See stripPartialCredentialTail for the measured before/after
		// and for the mirror-image bug in the naive two-line swap.
		//
		// The rune drop does not sanitise a body that was never valid
		// UTF-8 to begin with: a run of five or more bare continuation
		// bytes still surfaces, since no prefix of it is an incomplete
		// rune. That is acceptable — the guarantee we owe is not to
		// CREATE invalid UTF-8 by cutting, not to repair a binary payload
		// a server chose to send. This is a case
		// truncateBytesAtRuneBoundary's own rune-boundary snap cannot
		// reach, because that snap only runs when its cut actually
		// shortens the string (see its doc comment) — this text can
		// arrive already at or under jiraErrorBodyCap with a mid-rune
		// ending, either because leading whitespace pulled it under the
		// cap or because the network read itself was cut short.
		forms := c.scrubForms()
		literals := literalsOf(forms)
		window := jiraErrorBodyCap + longestScrubForm(literals)
		// readErr is deliberately not discarded: a mid-stream connection
		// drop truncates raw before the full window arrives, and silently
		// treating that as an ordinary complete read would pretend the
		// read succeeded when it didn't. We still prefer whatever was
		// read over failing the whole call outright — a truncated
		// diagnostic is still more useful than none — but the caller is
		// told the read did not complete cleanly, rather than being left
		// to assume a short message means a short Jira error body.
		raw, readErr := io.ReadAll(io.LimitReader(resp.Body, int64(window)))
		body := strings.TrimSpace(string(raw))
		cut := scrubCutPoint(body, jiraErrorBodyCap, literals)
		scrubbed := c.scrubSecrets(body[:cut])
		displayed := truncateBytesAtRuneBoundary(scrubbed, jiraErrorBodyCap)
		displayed = stripPartialCredentialTail(displayed, forms)
		msg := fmt.Sprintf("Jira error %d: %s", resp.StatusCode, displayed)
		if readErr != nil {
			msg += " (response body was cut short by a read error)"
		}
		return IssuePage{}, UserError(msg)
	}

	var raw jiraSearchResponse
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		// Not reachable in practice: Go's encoding/json decode errors echo
		// field names and Go types, never the decoded values, so there is
		// no credential-bearing text here to leak. Scrubbed anyway so the
		// next reader doesn't have to re-derive that from scratch, and so
		// this stays consistent if some future error type ever DID echo a
		// value.
		return IssuePage{}, fmt.Errorf("decode Jira search response: %s", c.scrubSecrets(err.Error()))
	}
	out := make([]Issue, 0, len(raw.Issues))
	for _, i := range raw.Issues {
		out = append(out, Issue{
			Key:      i.Key,
			Summary:  i.Fields.Summary,
			Status:   i.Fields.Status.Name,
			Assignee: i.Fields.Assignee.DisplayName,
			URL:      c.BaseURL + "/browse/" + i.Key,
		})
	}
	truncated := raw.NextPageToken != "" || hasWarnings(raw.Warnings)
	switch {
	case raw.IsLast != nil && !*raw.IsLast:
		truncated = true
	case raw.IsLast == nil && raw.NextPageToken == "":
		// Neither of Jira's completeness signals is present at all — an
		// older or proxied Jira instance, per the probe battery's
		// "both-absent" and "token-null" cases (a JSON `null`
		// nextPageToken decodes to the empty string here too, so it
		// falls into this same branch). We cannot demonstrate the page
		// is complete, so we must not report Truncated=false: that would
		// assert completeness from missing evidence. Fail toward
		// "assume more" rather than "assume complete" — this is the
		// safe direction because the two failure modes are not
		// symmetric: a spuriously-true Truncated costs the caller one
		// harmless extra check, while a spuriously-false Truncated is a
		// silently incomplete answer trusted as the whole one.
		truncated = true
	}
	return IssuePage{Issues: out, Truncated: truncated}, nil
}

// filterToProject drops any issue whose Key does not begin with
// "<projectKey>-", and reports how many were dropped. Every scoped path
// (MyIssues, SearchIssues, GetIssue) applies this to whatever Jira
// returns, independently of the JQL sent. This is deliberate defense in
// depth: even if some Jira JQL escaping rule this codebase doesn't know
// about let a caller's fragment desynchronize our scanner from Jira's
// lexer and escape the "project = <projectKey> AND (...)" wrapper (see
// SearchIssues), the RESPONSE itself can never surface an issue from
// another project once this filter runs — a scope leak becomes
// impossible regardless of what Jira's lexer actually does with any
// given input, which matters because the grammar argument behind the
// backslash ban is documentary, not something this codebase can verify
// against a live Jira instance.
//
// The drop itself stays silent-safe here (this function never errors —
// see IssuePage.Filtered's doc comment for why): it is IssuePage.Filtered
// at the call sites that makes the drop visible to a caller, without
// weakening the filter into something that could itself be defeated or
// made to fail loudly at the wrong layer. That is true at MyIssues's and
// SearchIssues's call sites, which both keep the second return value. It
// is NOT true at GetIssue's: a single-key lookup has no IssuePage to put
// a count on (GetIssue returns a bare Issue), so it discards the count
// (`issues, _ := filterToProject(...)`) and relies on a different
// behavior instead — a filtered-to-empty result already surfaces as
// "issue not found", which fails closed and is itself the diagnostic
// signal, just not as a numeric count.
func filterToProject(issues []Issue, projectKey string) ([]Issue, int) {
	prefix := projectKey + "-"
	out := make([]Issue, 0, len(issues))
	dropped := 0
	for _, i := range issues {
		if strings.HasPrefix(i.Key, prefix) {
			out = append(out, i)
		} else {
			dropped++
		}
	}
	return out, dropped
}

// MyIssues returns issues assigned to the current user in projectKey.
func (c *JiraClient) MyIssues(ctx context.Context, projectKey string) (IssuePage, error) {
	if !projectKeyPattern.MatchString(projectKey) {
		return IssuePage{}, UserError("invalid projectKey: " + projectKey)
	}
	page, err := c.search(ctx, fmt.Sprintf("project = %s AND assignee = currentUser() ORDER BY updated DESC", projectKey))
	if err != nil {
		return IssuePage{}, err
	}
	page.Issues, page.Filtered = filterToProject(page.Issues, projectKey)
	return page, nil
}

// SearchIssues runs the caller's jql fragment scoped to projectKey:
// "project = <projectKey> AND (<jql>)".
//
// The scope guarantee here rests on two independent layers — NOT on the
// wrapping parentheses alone, which a sufficiently adversarial jql
// fragment can defeat (see below):
//
//  1. validateBalancedJQL rejects any backslash in jql outright. Jira's
//     JQL lexer allows a `\'` / `\"` escape in BOTH quoted and unquoted
//     position (per the JqlLexer grammar's shared mESCAPE fragment and
//     JetBrains' independent port of it — documentary evidence, since it
//     could not be verified against a live Jira instance). A payload
//     like `summary ~ x\') OR (project = SECRET AND summary ~ 'a\'b'`
//     shows why that matters: a scanner that only tracks backslash
//     escapes INSIDE a string (as an earlier version of this function
//     did) reads the escaped quote in `x\'` as a string OPENER, so the
//     following ")" looks like it's still inside a string and the
//     fragment scans as balanced — but Jira's lexer reads `x\'` as one
//     unquoted token whose value is `x'`, so that ")" is a real
//     paren-close that escapes the wrapper entirely, unscoping the
//     search. With no backslash present, `'` and `"` cannot mean
//     anything other than "toggle string state" to either tokenizer, so
//     the two scans are provably identical — this is what actually makes
//     the AND/OR scope-escape attack impossible for anything that passes
//     validateBalancedJQL, not the paren-balance check by itself.
//  2. Independently of (1), every result is post-filtered
//     (filterToProject) to keys beginning with "<projectKey>-". This
//     makes a scope leak impossible on the RESPONSE side regardless of
//     whatever Jira's lexer actually does with any jql this codebase
//     didn't anticipate — the right posture given that (1)'s grammar
//     argument is documentary rather than something tested against a
//     live Jira.
func (c *JiraClient) SearchIssues(ctx context.Context, projectKey, jql string) (IssuePage, error) {
	if !projectKeyPattern.MatchString(projectKey) {
		return IssuePage{}, UserError("invalid projectKey: " + projectKey)
	}
	scoped := fmt.Sprintf("project = %s", projectKey)
	if strings.TrimSpace(jql) != "" {
		if err := validateBalancedJQL(jql); err != nil {
			return IssuePage{}, err
		}
		scoped += " AND (" + jql + ")"
	}
	page, err := c.search(ctx, scoped)
	if err != nil {
		return IssuePage{}, err
	}
	page.Issues, page.Filtered = filterToProject(page.Issues, projectKey)
	return page, nil
}

// GetIssue fetches a single issue by key, scoped to projectKey: key must
// have projectKey as its project prefix, or it is rejected before any
// network call. Without this, a caller could read any issue the
// credential can browse just by naming a different project's key
// directly — which would make SearchIssues's scoping moot as a
// confidentiality control, since a caller blocked from searching another
// project could simply ask get_issue for a specific key in it instead.
// The charter binds a PM tool to a single project per active Wakil
// project config, so reading another project's issue must mean switching
// project, not passing a different key to this tool.
//
// DEVIATION FROM SPEC §4.2, recorded rather than closed. The spec says
// get_issue returns "one issue with comments". It returns no comments.
// What comes back is the same five-field Issue projection every other
// Jira path returns (key, summary, status, assignee, url), because this
// goes through the same search() call as MyIssues and SearchIssues, and
// search() asks Jira for exactly Fields: ["summary","status","assignee"].
// There is no field on Issue for a comment to occupy either.
//
// Why the gap was left open rather than closed. Closing it is not adding
// "comment" to that Fields list. Three things compound:
//
//   - search() is SHARED by all three read paths, so widening its
//     projection would attach comment bodies to every my_issues and
//     search_issues result as well — up to 50 issues' worth per page.
//     get_issue would need its own request path, not a wider projection.
//   - Jira returns a comment body as Atlassian Document Format: a nested
//     JSON document tree, not text. Rendering it is a new component with
//     its own failure modes, and the alternative — handing raw ADF to an
//     LLM — is worse than returning nothing.
//   - Comments page independently of the issue and are unbounded, so a
//     cap and a Truncated signal are needed, in the house style
//     IssuePage and Rows already set. And scrubSecrets would be running
//     over a response shape it has never seen.
//
// The blocking reason is that none of those decisions can be VERIFIED
// from here. There is no live Jira instance available to this branch, and
// this codebase's standard for an integration is measurement rather than
// inference — the same standard that leaves SearchIssues's backslash ban
// and jiraJQL's absent ORDER BY as explicitly documentary arguments
// instead of tested ones. Shipping an unverifiable new API surface to
// close a documentation finding is the wrong trade, so this is carried to
// Phase 2, where a live instance can be measured against.
//
// wakil-pm's get_issue tool DESCRIPTION states the omission plainly, and
// that is the part that matters operationally rather than editorially: an
// LLM that assumes it has seen an issue's discussion will confidently
// tell a user the issue has none.
func (c *JiraClient) GetIssue(ctx context.Context, projectKey, key string) (Issue, error) {
	if !projectKeyPattern.MatchString(projectKey) {
		return Issue{}, UserError("invalid projectKey: " + projectKey)
	}
	if !issueKeyPattern.MatchString(key) {
		return Issue{}, UserError("invalid issue key: " + key)
	}
	if !strings.HasPrefix(key, projectKey+"-") {
		return Issue{}, UserError("issue " + key + " is not in the active project (" + projectKey + ") — switch project to read it")
	}
	page, err := c.search(ctx, "key = "+key)
	if err != nil {
		return Issue{}, err
	}
	issues, _ := filterToProject(page.Issues, projectKey)
	if len(issues) == 0 {
		return Issue{}, UserError("issue not found: " + key)
	}
	return issues[0], nil
}

// validateBalancedJQL scans jql tracking single/double-quote state and
// parenthesis depth, and rejects any backslash outright. See
// SearchIssues's doc comment for why the backslash ban is what actually
// makes the balanced-paren/quote check trustworthy: with no backslash in
// jql, there is no escape sequence for either this scanner or Jira's own
// lexer to interpret differently, so the two tokenizations of `'`/`"` are
// provably identical.
//
// It requires that:
//   - jql contains no backslash
//   - paren depth never goes negative (no stray closing paren)
//   - paren depth is exactly zero at the end (every opened paren closed)
//   - no quote is left unterminated
//
// This guarantees the caller's fragment cannot contain an unmatched ")"
// that closes a paren SearchIssues itself opened when wrapping the
// fragment in "project = K AND (<jql>)" — any OR the caller writes stays
// inside their own balanced parens. This is only HALF of SearchIssues's
// scope-escape defense; see that function's doc comment for the
// response-side post-filter that is the other half.
func validateBalancedJQL(jql string) error {
	if strings.ContainsRune(jql, '\\') {
		return UserError("jql must not contain a backslash")
	}
	depth := 0
	var quote rune
	for _, r := range jql {
		if quote != 0 {
			if r == quote {
				quote = 0
			}
			continue
		}
		switch r {
		case '\'', '"':
			quote = r
		case '(':
			depth++
		case ')':
			depth--
			if depth < 0 {
				return UserError("jql has unbalanced parentheses")
			}
		}
	}
	if quote != 0 {
		return UserError("jql has an unterminated quote")
	}
	if depth != 0 {
		return UserError("jql has unbalanced parentheses")
	}
	return nil
}
