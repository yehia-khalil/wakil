package wakilcore

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

// TestRecallDoesNotLeakACredentialFromAFailingJira is the boundary test
// for recall's most dangerous composition: SourceStatus.Message relays a
// UserError VERBATIM (see sourceFailureMessage), and on the Jira path
// that message is a 4xx body whose contents the server chose. Unlike
// mcpx.ToolErr's output — an error an operator is reading — this text is
// an ordinary field of a SUCCESSFUL tool result that goes straight into
// an LLM transcript.
//
// TestRecallSurfacesJiraErrorBodyThroughSourceStatus covers the other
// half of this path but cannot cover this half: it uses Token "t" and a
// body containing no credential at all, so it proves the message is
// RELAYED without proving anything is REMOVED. Standing lesson 3: an
// assertion about a sanitiser proves nothing unless the sanitiser had
// something to fire on. Hence a realistic 192-character token here
// (lesson 4: an 11-char token once hid a leak a real one exposed
// instantly), echoed in every form a real proxy or Jira might use.
//
// MEASURED, and the reason this test is worth its cost: jira.go's two
// defences on this path are genuinely independent, and this fixture needs
// BOTH to fail before anything leaks.
//   - Disable only scrubSecrets: the message ends "...Basic " — the
//     display cap lands mid-base64 and stripPartialCredentialSuffix
//     removes the whole partial. Nothing leaks; this test stays green.
//   - Disable only stripPartialCredentialSuffix: scrubSecrets removes
//     every occurrence. Nothing leaks; this test stays green.
//   - Disable both: 162 verbatim bytes of the base64 credential reach
//     SourceStatus.Message. This test fails.
//
// So it is a regression test for the LAYERING, not for either layer —
// jira.go's own tests pin those individually. It fails if a future change
// collapses the two into one, or if recall ever grows an error-wrapping
// path of its own that bypasses jira.go's pipeline.
func TestRecallDoesNotLeakACredentialFromAFailingJira(t *testing.T) {
	const email = "person@example.com"
	token := strings.Repeat("A1b2C3d4", 24) // 192 chars, realistic scale
	basic := base64.StdEncoding.EncodeToString([]byte(email + ":" + token))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte("Bad request from Authorization: Basic " + basic +
			" (user " + email + ":" + token + ", token=" + token + ") retry with Basic " + basic))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
	out, err := fanOut(context.Background(), "date picker", "RAF", c.SearchIssues)
	if err != nil {
		t.Fatalf("a failing source must not fail the whole call: %v", err)
	}
	if len(out.Sources) != 1 || out.Sources[0].OK {
		t.Fatalf("sources = %+v, want one failed entry", out.Sources)
	}
	msg := out.Sources[0].Message

	// Assert the pipeline FIRED, not merely that the secret is absent: a
	// message dropped entirely would satisfy every absence check below
	// while telling the caller nothing.
	if !strings.Contains(msg, "Jira error 400") {
		t.Fatalf("sources[0].Message = %q, want jira.go's scrubbed \"Jira error 400: <body>\" diagnostic", msg)
	}

	// No verbatim run of any credential form may survive. The 8-byte
	// floor is there because shorter runs occur by chance in ordinary text.
	for _, secret := range []string{token, basic, email + ":" + token} {
		for n := len(secret); n >= 8; n-- {
			for i := 0; i+n <= len(secret); i++ {
				if strings.Contains(msg, secret[i:i+n]) {
					t.Fatalf("%d-byte credential fragment %q leaked into SourceStatus.Message: %q",
						n, secret[i:i+n], msg)
				}
			}
		}
	}

	// The marshaled result is what actually goes on the wire, so check
	// there too rather than trusting Message to be the only field a
	// credential could reach.
	b, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("marshal RecallOutput: %v", err)
	}
	for _, frag := range []string{token[:16], basic[:16], email + ":" + token[:8]} {
		if strings.Contains(string(b), frag) {
			t.Fatalf("credential fragment %q in marshaled RecallOutput: %s", frag, b)
		}
	}
}

// TestRecallQueryAcceptedSetCannotEscapeJQL pins the complement of
// TestRecallRejectsUnquotableQuery: not what validateRecallQuery turns
// away, but that everything it lets THROUGH is still inert once
// concatenated into a JQL string with no escaping (jiraJQL).
//
// The cases are the deliberate near-misses. U+00A0 NO-BREAK SPACE,
// U+2028 LINE SEPARATOR and U+007F DELETE are all
// "whitespace-or-control-ish" characters that a byte < 0x20 check does
// NOT reject, and that is intended rather than an oversight: none of them
// can terminate a double-quoted JQL string, and rejecting them would turn
// an ordinary copy-pasted search phrase into an error. This test exists so
// that stays a decision instead of drifting into an accident.
func TestRecallQueryAcceptedSetCannotEscapeJQL(t *testing.T) {
	for _, q := range []string{
		`x) OR (project = SECRET`, // parens are inert inside the string
		"x\u00a0y",                // NO-BREAK SPACE
		"x\u2028y",                // LINE SEPARATOR
		"x\u007fy",                // DELETE
		"日本語",
		"a AND b OR c",
		"text ~ everything",
		// Long, and still nothing structural — but length is now a
		// rejection reason in its own right, so the longest ACCEPTED
		// query is the cap exactly. strings.Repeat("x", 4096) used to sit
		// here for the same purpose; it moved to the rejected list below
		// when recallQueryMaxRunes was introduced. Sitting on the boundary
		// also pins the comparison as ">" and not ">=".
		strings.Repeat("x", recallQueryMaxRunes),
		// The cap counts RUNES, so the longest accepted multi-byte query
		// is the same COUNT, not the same byte length. Against a byte cap
		// this is 3x over and would be rejected.
		strings.Repeat("日", recallQueryMaxRunes),
	} {
		got, err := validateRecallQuery(q)
		if err != nil {
			t.Errorf("query %q was rejected, but this case is meant to be accepted: %v", q, err)
			continue
		}
		assertInertJQL(t, q, jiraJQL(got))
	}
}

// TestRecallRejectsOverlongQuery is where strings.Repeat("x", 4096) went.
// It sat in the ACCEPTED table above, commented "long, but nothing
// structural", until validateRecallQuery gained recallQueryMaxRunes; the
// cap — not anything structural about the text — is now the reason it is
// turned away, and the case is moved rather than deleted so that stays on
// the record.
//
// The three cases are chosen so the test cannot pass by accident:
//
//   - cap+1 ASCII runes is the boundary. Together with the cap-exactly
//     case in the accepted table above, it pins the comparison in both
//     directions, so neither ">=" nor an off-by-one survives.
//   - cap+1 CJK runes is 3x the cap in BYTES and would be rejected by a
//     byte-counting check too — but it is here to be rejected for the
//     RIGHT reason, and the message quotes the rune count, so a byte
//     count of 1539 would not match.
//   - the original 4096-x case, kept verbatim.
//
// It goes through fanOut rather than calling validateRecallQuery
// directly, matching TestRecallRejectsUnquotableQuery, because the point
// is that this is a WHOLE-CALL rejection that never consults a source.
func TestRecallRejectsOverlongQuery(t *testing.T) {
	tooLong := func(n int) string {
		return fmt.Sprintf("recall query is too long (%d characters, limit %d) — search for the few distinctive words instead of pasting the whole text",
			n, recallQueryMaxRunes)
	}
	cases := []struct {
		name  string
		query string
		want  string
	}{
		{"one rune over the cap", strings.Repeat("x", recallQueryMaxRunes+1), tooLong(recallQueryMaxRunes + 1)},
		{"one multi-byte rune over the cap", strings.Repeat("日", recallQueryMaxRunes+1), tooLong(recallQueryMaxRunes + 1)},
		{"the formerly-accepted 4096-character case", strings.Repeat("x", 4096), tooLong(4096)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			called := false
			_, err := fanOut(context.Background(), tc.query, "RAF", failingSearch(errors.New("must not be called"), &called))
			wantRecallUserError(t, err, tc.want)
			if called {
				t.Fatalf("the Jira source was consulted despite an over-long query (%d runes)", utf8.RuneCountInString(tc.query))
			}
		})
	}
}

// assertInertJQL is the invariant both the table test above and the fuzz
// target below check: whatever jiraJQL produced is a SINGLE balanced
// double-quoted string that the next layer down accepts unchanged, in the
// exact wrapping SearchIssues applies.
func assertInertJQL(t *testing.T, query, jql string) {
	t.Helper()
	if n := strings.Count(jql, `"`); n != 2 {
		t.Errorf("query %q produced JQL with %d double quotes, want exactly the 2 jiraJQL adds: %q", query, n, jql)
	}
	if strings.Contains(jql, `\`) {
		t.Errorf("query %q produced a backslash in JQL: %q", query, jql)
	}
	if !strings.HasPrefix(jql, `text ~ "`) || !strings.HasSuffix(jql, `"`) {
		t.Errorf("query %q produced JQL outside the expected shape: %q", query, jql)
	}
	if err := validateBalancedJQL(`project = RAF AND (` + jql + `)`); err != nil {
		t.Errorf("query %q produced JQL that SearchIssues's own validator rejects: %v (%q)", query, err, jql)
	}
}

// FuzzRecallQueryCannotEscapeJQL searches for any input validateRecallQuery
// accepts but that breaks out of jiraJQL's quoted string. The table tests
// above cover the escapes someone thought of; this covers the ones nobody
// did.
//
// The property is one-directional on purpose: a rejected query is always
// fine, because rejection is the fail-closed posture here (see
// validateRecallQuery), so only the ACCEPTED path is asserted on.
func FuzzRecallQueryCannotEscapeJQL(f *testing.F) {
	for _, s := range []string{
		"", " ", "date picker", `x" OR project = SECRET`, `x' OR x`,
		`x\" y`, "x\ny", "x\x00y", "x\u007fy", "x\u00a0y", "x\u2028y", "日本語",
		"x) OR (project = SECRET", strings.Repeat(`"`, 64),
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, query string) {
		got, err := validateRecallQuery(query)
		if err != nil {
			return // rejected: fail-closed, nothing to prove
		}
		assertInertJQL(t, query, jiraJQL(got))
	})
}

// TestRecallDoesNotLeakACredentialFromWAKIL_JIRA_BASE is the end-to-end
// half of the normalizeJiraBase fix, on the boundary that made it urgent.
//
// jira_test.go's TestNormalizeJiraBaseNeverEchoesACredential pins the
// sentence at the function that builds it. This pins where that sentence
// GOES: NewJiraFromEnv's error is returned to fanOut unchanged (see
// searchJiraFromEnv), fanOut relays a UserError's message verbatim (see
// sourceFailureMessage), and the result is an ok=false SourceStatus
// inside a SUCCESSFUL RecallOutput that wakil-recall's tool description
// tells the model to read. Before the fix, a base URL of
// "https://<token>@host" — no colon, so url.URL.Redacted() masked
// nothing — put the operator's Atlassian API token straight into that
// field and therefore into an LLM transcript.
//
// The base URL used here is the exact operator mistake the "must not
// contain credentials" message is about, so this fixture only proves
// anything because the guard has something to fire on (standing lesson 3).
func TestRecallDoesNotLeakACredentialFromWAKIL_JIRA_BASE(t *testing.T) {
	tok := jiraOperatorToken
	t.Setenv("WAKIL_JIRA_BASE", "https://"+tok+"@acme.atlassian.net")
	// NewJiraFromEnv resolves the org first, unconditionally, before it
	// ever looks at WAKIL_JIRA_BASE; without this the failure here would
	// be CurrentOrg's "WAKIL_ORG is not set" instead of the
	// normalizeJiraBase rejection this test exists to pin.
	t.Setenv("WAKIL_ORG", "initech")
	// Backstop, not a requirement of the path: normalizeJiraBase fails
	// before SecretGet is ever called, so no Keychain read should happen.
	// Pointing PATH at an empty dir turns a regression in that ordering
	// into a visibly different message instead of a prompt against the
	// developer's real login keychain.
	t.Setenv("WAKIL_SECURITY_BINARY", filepath.Join(t.TempDir(), "security"))

	out, err := fanOut(context.Background(), "date picker", "RAF", searchJiraFromEnv)
	if err != nil {
		t.Fatalf("a failing source must not fail the whole call: %v", err)
	}
	if len(out.Sources) != 1 || out.Sources[0].OK {
		t.Fatalf("sources = %+v, want one failed entry", out.Sources)
	}
	msg := out.Sources[0].Message

	// Assert the exact sentence first. An absence check on its own would
	// pass just as well on an empty Message, or if the whole SourceStatus
	// were dropped — and it would also stay green if the message stopped
	// naming the origin, which is the one thing here an operator with
	// several Atlassian sites needs.
	const want = "WAKIL_JIRA_BASE must not contain credentials — store the Jira token in the Keychain, not the base URL, got https://acme.atlassian.net"
	if msg != want {
		t.Fatalf("sources[0].Message = %q, want %q", msg, want)
	}

	// No verbatim run of the token anywhere in the message...
	for n := len(tok); n >= 8; n-- {
		for i := 0; i+n <= len(tok); i++ {
			if strings.Contains(msg, tok[i:i+n]) {
				t.Fatalf("%d-byte token fragment %q leaked into SourceStatus.Message: %q", n, tok[i:i+n], msg)
			}
		}
	}
	// ...nor anywhere in the marshaled result, which is what actually
	// goes on the wire. Checking Message alone would trust it to be the
	// only field the token could reach.
	b, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("marshal RecallOutput: %v", err)
	}
	for n := len(tok); n >= 8; n-- {
		for i := 0; i+n <= len(tok); i++ {
			if strings.Contains(string(b), tok[i:i+n]) {
				t.Fatalf("%d-byte token fragment %q in the marshaled RecallOutput: %s", n, tok[i:i+n], b)
			}
		}
	}
}
