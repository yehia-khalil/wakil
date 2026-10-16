package wakilcore

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

// jiraSearchBody mirrors the JSON body wakil-pm's Jira client sends to
// POST /rest/api/3/search/jql, so tests can decode and assert on it
// directly rather than pattern-matching a URL query string — the dead
// GET .../search?jql=... endpoint this replaces would have made that
// possible, but the live endpoint takes JQL, fields, and pagination in a
// JSON POST body instead (confirmed against developer.atlassian.com and
// community.developer.atlassian.com; see jira-report for citations).
type jiraSearchBody struct {
	JQL           string   `json:"jql"`
	Fields        []string `json:"fields"`
	MaxResults    int      `json:"maxResults,omitempty"`
	NextPageToken string   `json:"nextPageToken,omitempty"`
}

// newJiraTestServer builds an httptest server that asserts the method and
// path on every request, decodes the JSON body into a jiraSearchBody, and
// hands it to check before responding with body (or a default success
// payload if body is empty). Failing on method/path/decode keeps a wrong
// guess about the live endpoint shape loud instead of silently green.
//
// The body-decode failure uses t.Errorf + return, not t.Fatalf: this
// handler runs on the httptest server's own goroutine, and FailNow
// (which Fatalf calls) only Goexits THAT goroutine rather than failing
// the test in a way the client waiting on the HTTP response can make
// sense of — the client would just see a confusing EOF instead of a
// clear assertion failure.
func newJiraTestServer(t *testing.T, check func(t *testing.T, b jiraSearchBody), respond string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method = %s, want POST", r.Method)
		}
		if r.URL.Path != "/rest/api/3/search/jql" {
			t.Errorf("path = %s, want /rest/api/3/search/jql", r.URL.Path)
		}
		var b jiraSearchBody
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			t.Errorf("decode request body: %v", err)
			return
		}
		if check != nil {
			check(t, b)
		}
		if respond == "" {
			respond = `{"issues":[{"key":"RAF-1","fields":{"summary":"Fix","status":{"name":"To Do"},"assignee":{"displayName":"Ada"}}}]}`
		}
		w.Write([]byte(respond))
	}))
}

func TestJiraMyIssuesScoped(t *testing.T) {
	srv := newJiraTestServer(t, func(t *testing.T, b jiraSearchBody) {
		if !strings.Contains(b.JQL, "project = RAF") || !strings.Contains(b.JQL, "assignee = currentUser()") {
			t.Errorf("jql not scoped: %q", b.JQL)
		}
		wantFields := []string{"summary", "status", "assignee"}
		if len(b.Fields) != len(wantFields) {
			t.Fatalf("fields = %v, want %v", b.Fields, wantFields)
		}
		for i, f := range wantFields {
			if b.Fields[i] != f {
				t.Fatalf("fields = %v, want %v", b.Fields, wantFields)
			}
		}
	}, "")
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	page, err := c.MyIssues(context.Background(), "RAF")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Issues) != 1 || page.Issues[0].Key != "RAF-1" || page.Issues[0].Summary != "Fix" {
		t.Fatalf("bad issues: %+v", page.Issues)
	}
	if page.Issues[0].Status != "To Do" || page.Issues[0].Assignee != "Ada" {
		t.Fatalf("bad issues: %+v", page.Issues)
	}
	if page.Issues[0].URL != srv.URL+"/browse/RAF-1" {
		t.Fatalf("bad URL: %q", page.Issues[0].URL)
	}
	// Ruling Important-3: with neither isLast nor nextPageToken present,
	// completeness cannot be demonstrated, so Truncated must fail toward
	// "assume more" (true), not silently assert completeness from
	// missing evidence.
	if !page.Truncated {
		t.Fatalf("expected Truncated=true for a response with no nextPageToken/isLast/warnings (fail toward assume-more, not assume-complete)")
	}
}

func TestJiraGetIssueRequestsSingleKey(t *testing.T) {
	srv := newJiraTestServer(t, func(t *testing.T, b jiraSearchBody) {
		if b.JQL != "key = RAF-142" {
			t.Errorf("jql = %q, want %q", b.JQL, "key = RAF-142")
		}
	}, `{"issues":[{"key":"RAF-142","fields":{"summary":"Widget","status":{"name":"Done"},"assignee":{"displayName":"A"}}}]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	issue, err := c.GetIssue(context.Background(), "RAF", "RAF-142")
	if err != nil {
		t.Fatal(err)
	}
	if issue.Key != "RAF-142" || issue.Summary != "Widget" {
		t.Fatalf("bad issue: %+v", issue)
	}
}

func TestJiraGetIssueRejectsInvalidKey(t *testing.T) {
	// No server is created at all: a rejected key must never reach the
	// network. c.BaseURL is deliberately garbage so a stray HTTP call
	// would fail loudly rather than silently succeeding.
	c := &JiraClient{BaseURL: "http://127.0.0.1:1", Email: "e", Token: "t"}

	cases := []string{"raf-1", "RAF", "RAF-", "RAF-1; DROP", "RAF -1", "-1"}
	for _, key := range cases {
		t.Run(key, func(t *testing.T) {
			_, err := c.GetIssue(context.Background(), "RAF", key)
			if err == nil {
				t.Fatalf("expected rejection for invalid key %q", key)
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected UserError, got %T: %v", err, err)
			}
			if !strings.Contains(msg, "key") {
				t.Fatalf("error %q does not name the field", msg)
			}
		})
	}
}

// TestJiraGetIssueRejectsCrossProjectKey pins ruling Important-3: get_issue
// must enforce project scope itself (format validation alone is not
// enough), because otherwise a caller blocked from searching another
// project could simply ask get_issue for a specific key in it instead,
// making SearchIssues's scoping moot as a confidentiality control.
//
// MUTATION-VERIFIED: removing GetIssue's
// `if !strings.HasPrefix(key, projectKey+"-") { ... }` check made this
// test fail — the call fell through to search() against the deliberately
// unroutable http://127.0.0.1:1 and failed with a dial/connection-refused
// error instead of the expected "not in the active project" message.
// Restored via the original file content; diff confirmed byte-identical;
// re-ran green.
func TestJiraGetIssueRejectsCrossProjectKey(t *testing.T) {
	// No server is created: the rejection must happen before any network
	// call, so a deliberately unroutable BaseURL makes a bypass loud.
	c := &JiraClient{BaseURL: "http://127.0.0.1:1", Email: "e", Token: "t"}

	_, err := c.GetIssue(context.Background(), "RAF", "OTHER-1")
	if err == nil {
		t.Fatal("expected rejection of a key from a different project")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "not in the active project") {
		t.Fatalf("error %q does not explain the project-scope rejection", msg)
	}
}

func TestJiraSearchIssuesRejectsProjectScopeEscape(t *testing.T) {
	// The exact injection payload from the controller ruling: because AND
	// binds tighter than OR, "project = RAF AND (x) OR (1=1)" parses as
	// (project=RAF AND x) OR (1=1), leaking every project the credential
	// can see. A balanced-paren validator rejects this outright since the
	// caller's fragment alone has an extra unmatched ")" before its "(".
	c := &JiraClient{BaseURL: "http://127.0.0.1:1", Email: "e", Token: "t"}

	_, err := c.SearchIssues(context.Background(), "RAF", "x) OR (1=1")
	if err == nil {
		t.Fatal("expected the scope-escape payload to be rejected")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "parenthes") {
		t.Fatalf("error %q does not mention unbalanced parentheses", msg)
	}
}

// TestJiraSearchIssuesRejectsBackslashScopeEscape pins Critical-1(a): the
// backslash-based scope escape the adversarial reviewer verified against
// this code. Because "'" in an unquoted position toggles our scanner's
// quote state exactly the same way a real string opener would, a
// backslash immediately before it (`x\'`) desynchronizes our scanner from
// Jira's lexer, which treats `x\'` as a single unquoted token whose value
// is `x'` — so the ")" that follows is a REAL paren-close in Jira's
// parser even though our (old) scanner thought it was still inside a
// string. Both the single- and double-quote variants must be rejected.
//
// MUTATION-VERIFIED: deleting the
// `if strings.ContainsRune(jql, '\\') { return UserError(...) }` guard in
// validateBalancedJQL made this test fail for the right reason — both
// payloads are "balanced" under the plain paren/quote scanner alone (that
// is the entire point of the exploit), so with the guard gone they fell
// through to an actual network attempt against the deliberately
// unroutable http://127.0.0.1:1 and failed with a dial error instead of
// the expected "backslash" message. Restored via the original file
// content; diff confirmed byte-identical; re-ran green.
func TestJiraSearchIssuesRejectsBackslashScopeEscape(t *testing.T) {
	c := &JiraClient{BaseURL: "http://127.0.0.1:1", Email: "e", Token: "t"}

	payloads := map[string]string{
		"single-quote": `summary ~ x\') OR (project = SECRET AND summary ~ 'a\'b'`,
		"double-quote": `summary ~ x\") OR (summary ~ "a\"b"`,
	}
	for name, payload := range payloads {
		t.Run(name, func(t *testing.T) {
			_, err := c.SearchIssues(context.Background(), "RAF", payload)
			if err == nil {
				t.Fatalf("expected rejection of backslash-based scope escape, payload %q", payload)
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected UserError, got %T: %v", err, err)
			}
			if !strings.Contains(msg, "backslash") {
				t.Fatalf("error %q does not mention the backslash rejection", msg)
			}
		})
	}
}

// TestJiraSearchIssuesPostFiltersOutOfProjectIssues pins Critical-1(b):
// even when Jira's server returns an issue from a project other than the
// one this search was scoped to, SearchIssues must drop it before
// returning — independent of whatever caused it to come back (a JQL
// grammar edge case, a Jira bug, anything). It also pins ruling
// Important-4: the drop must not be silent — IssuePage.Filtered must
// report exactly how many issues were dropped, so a non-zero count is
// visible as a signal worth investigating (a probe found the pre-fix
// code reported this exact scenario as a complete, unremarkable page:
// "issues=1 truncated=false keys=[RAF-1]", with no trace that SECRET-9
// was ever there).
//
// MUTATION-VERIFIED: removing the
// `page.Issues = filterToProject(page.Issues, projectKey)` line in
// SearchIssues made this test fail — both RAF-1 and SECRET-99 came back
// (len(page.Issues) == 2) instead of only RAF-1. Restored via the
// original file content; diff confirmed byte-identical; re-ran green.
//
// MUTATION-VERIFIED (Filtered): changed
// `page.Issues, page.Filtered = filterToProject(...)` to
// `page.Issues, _ = filterToProject(...)` (dropping the count on the
// floor, leaving page.Filtered at its zero value). Result: RED —
// `jira_test.go: Filtered = 0, want 1`. Restored via `cp` from the
// pre-mutation backup; `diff` confirmed byte-identical; re-ran — green.
func TestJiraSearchIssuesPostFiltersOutOfProjectIssues(t *testing.T) {
	srv := newJiraTestServer(t, nil, `{"issues":[`+
		`{"key":"RAF-1","fields":{"summary":"In scope","status":{"name":"To Do"},"assignee":{"displayName":"A"}}},`+
		`{"key":"SECRET-99","fields":{"summary":"Leaked","status":{"name":"To Do"},"assignee":{"displayName":"B"}}}`+
		`]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	page, err := c.SearchIssues(context.Background(), "RAF", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Issues) != 1 || page.Issues[0].Key != "RAF-1" {
		t.Fatalf("expected only RAF-1 to survive the project post-filter, got %+v", page.Issues)
	}
	for _, i := range page.Issues {
		if !strings.HasPrefix(i.Key, "RAF-") {
			t.Fatalf("post-filter leaked an out-of-project issue: %+v", i)
		}
	}
	if page.Filtered != 1 {
		t.Fatalf("Filtered = %d, want 1", page.Filtered)
	}
}

// TestJiraMyIssuesPostFiltersAndReportsFilteredCount pins round-3 Minor-4:
// MyIssues's own `page.Issues, page.Filtered = filterToProject(...)`
// assignment (jira.go) was untested — only SearchIssues's identical line
// had a pinning test. Mutating MyIssues's assignment to discard the count
// (`page.Issues, _ = filterToProject(...)`) left the entire suite green
// before this test existed, because SearchIssues's test only exercises
// SearchIssues.
//
// MUTATION-VERIFIED: changed MyIssues's
// `page.Issues, page.Filtered = filterToProject(page.Issues, projectKey)`
// to `page.Issues, _ = filterToProject(page.Issues, projectKey)`. Result:
// RED — `jira_test.go: Filtered = 0, want 1`. Restored via `cp` from a
// pre-mutation backup; `diff` confirmed byte-identical; re-ran — green.
func TestJiraMyIssuesPostFiltersAndReportsFilteredCount(t *testing.T) {
	srv := newJiraTestServer(t, nil, `{"issues":[`+
		`{"key":"RAF-1","fields":{"summary":"In scope","status":{"name":"To Do"},"assignee":{"displayName":"A"}}},`+
		`{"key":"SECRET-99","fields":{"summary":"Leaked","status":{"name":"To Do"},"assignee":{"displayName":"B"}}}`+
		`]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	page, err := c.MyIssues(context.Background(), "RAF")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Issues) != 1 || page.Issues[0].Key != "RAF-1" {
		t.Fatalf("expected only RAF-1 to survive the project post-filter, got %+v", page.Issues)
	}
	if page.Filtered != 1 {
		t.Fatalf("Filtered = %d, want 1", page.Filtered)
	}
}

func TestJiraSearchIssuesAllowsBalancedNestedJQL(t *testing.T) {
	const callerJQL = `status = "Open" OR (labels = urgent)`
	wantJQL := `project = RAF AND (` + callerJQL + `)`

	srv := newJiraTestServer(t, func(t *testing.T, b jiraSearchBody) {
		if b.JQL != wantJQL {
			t.Errorf("jql = %q, want %q", b.JQL, wantJQL)
		}
	}, `{"issues":[]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	if _, err := c.SearchIssues(context.Background(), "RAF", callerJQL); err != nil {
		t.Fatalf("balanced JQL should be accepted: %v", err)
	}
}

// TestJiraSearchIssuesRejectsProbedScopeEscapePayloads pins the payload
// battery a reviewer's fuzz probe (zz_probe_test.go, mined for these
// permanent assertions then deleted) ran against SearchIssues, to keep
// the record of what the scope boundary actually withstands — losing
// these payloads on deletion would lose the evidence. None of these
// contains a backslash (that class is pinned separately by
// TestJiraSearchIssuesRejectsBackslashScopeEscape, which includes the
// probe's "backslash-single" payload verbatim), so validateBalancedJQL's
// plain paren/quote scan is what rejects every one here: each either
// leaves an unbalanced/unmatched paren or an unterminated quote. The
// comment-attempt payloads in particular rely on a false premise — JQL
// has no comment syntax, so "--", "/* */", and "#" are ordinary
// characters to the scanner, not comment openers, and the ")" the
// payload assumed would be suppressed is instead a real, unmatched
// close-paren.
func TestJiraSearchIssuesRejectsProbedScopeEscapePayloads(t *testing.T) {
	c := &JiraClient{BaseURL: "http://127.0.0.1:1", Email: "e", Token: "t"}
	cases := []struct {
		name    string
		payload string
		wantMsg string
	}{
		{"backslash-single-quote-escape", `summary ~ x\') OR (project = SECRET AND summary ~ 'a\'b'`, "backslash"},
		{"dashdash-comment-attempt", "status = Open -- ) OR (project = SECRET", "parenthes"},
		{"slashstar-comment-attempt", "status = Open /* ) OR (project = SECRET */", "parenthes"},
		{"hash-comment-attempt", "status = Open # ) OR (project = SECRET", "parenthes"},
		{"order-by-escape", "status = Open) ORDER BY key", "parenthes"},
		{"quote-then-paren", `summary ~ 'a')(project = SECRET`, "parenthes"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := c.SearchIssues(context.Background(), "RAF", tc.payload)
			if err == nil {
				t.Fatalf("expected rejection of payload %q", tc.payload)
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected UserError, got %T: %v", err, err)
			}
			if !strings.Contains(msg, tc.wantMsg) {
				t.Fatalf("error %q does not mention %q", msg, tc.wantMsg)
			}
		})
	}
}

// TestJiraSearchIssuesAllowsProbedNestedJQL pins the accepted side of the
// same probe battery: legitimate multiply-nested JQL with balanced
// parentheses must still pass through, wrapped in the project scope, not
// rejected as collateral damage from the scope-escape defenses above.
// This is a distinct payload shape (two independently parenthesized
// groups joined by AND) from
// TestJiraSearchIssuesAllowsBalancedNestedJQL's single OR-inside-parens
// case.
func TestJiraSearchIssuesAllowsProbedNestedJQL(t *testing.T) {
	const callerJQL = `(a = 1 OR b = 2) AND (c = 3)`
	wantJQL := `project = RAF AND (` + callerJQL + `)`

	srv := newJiraTestServer(t, func(t *testing.T, b jiraSearchBody) {
		if b.JQL != wantJQL {
			t.Errorf("jql = %q, want %q", b.JQL, wantJQL)
		}
	}, `{"issues":[]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	if _, err := c.SearchIssues(context.Background(), "RAF", callerJQL); err != nil {
		t.Fatalf("balanced nested JQL should be accepted: %v", err)
	}
}

func TestJiraSearchIssuesRejectsUnterminatedQuote(t *testing.T) {
	c := &JiraClient{BaseURL: "http://127.0.0.1:1", Email: "e", Token: "t"}
	_, err := c.SearchIssues(context.Background(), "RAF", `summary ~ "unterminated`)
	if err == nil {
		t.Fatal("expected rejection of unterminated quote")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "quote") {
		t.Fatalf("error %q does not mention the unterminated quote", msg)
	}
}

func TestJiraSearchIssuesValidatesProjectKey(t *testing.T) {
	c := &JiraClient{BaseURL: "http://127.0.0.1:1", Email: "e", Token: "t"}
	cases := []string{"raf", "RAF-1", "RAF; DROP", ""}
	for _, key := range cases {
		t.Run(key, func(t *testing.T) {
			_, err := c.SearchIssues(context.Background(), key, "")
			if err == nil {
				t.Fatalf("expected rejection for invalid projectKey %q", key)
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected UserError, got %T: %v", err, err)
			}
			if !strings.Contains(msg, "projectKey") {
				t.Fatalf("error %q does not name the field", msg)
			}
		})
	}
}

func TestJiraMyIssuesValidatesProjectKey(t *testing.T) {
	c := &JiraClient{BaseURL: "http://127.0.0.1:1", Email: "e", Token: "t"}
	_, err := c.MyIssues(context.Background(), "raf")
	if err == nil {
		t.Fatal("expected rejection for invalid projectKey")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "projectKey") {
		t.Fatalf("error %q does not name the field", msg)
	}
}

// TestJiraSearchMarksTruncatedWhenNextPageTokenPresent pins Important-2:
// a nextPageToken in the response means more results exist beyond this
// page, and that must surface as IssuePage.Truncated rather than being
// silently dropped on the floor (as it was before: decoded but never
// read).
func TestJiraSearchMarksTruncatedWhenNextPageTokenPresent(t *testing.T) {
	srv := newJiraTestServer(t, nil, `{"issues":[{"key":"RAF-1","fields":{"summary":"Fix","status":{"name":"To Do"},"assignee":{"displayName":"A"}}}],"nextPageToken":"tok"}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	page, err := c.MyIssues(context.Background(), "RAF")
	if err != nil {
		t.Fatal(err)
	}
	if !page.Truncated {
		t.Fatal("expected Truncated=true when nextPageToken is present")
	}
}

// TestJiraSearchMarksTruncatedFromWarnings pins the other half of
// Important-2: Atlassian uses `warnings` to report ingestion-limit
// truncation of the current page even when nextPageToken is absent and
// isLast is true, so warnings must also mark the page as incomplete.
func TestJiraSearchMarksTruncatedFromWarnings(t *testing.T) {
	srv := newJiraTestServer(t, nil, `{"issues":[],"isLast":true,"warnings":["fields limit exceeded"]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	page, err := c.MyIssues(context.Background(), "RAF")
	if err != nil {
		t.Fatal(err)
	}
	if !page.Truncated {
		t.Fatal("expected Truncated=true when the response carries warnings")
	}
}

// TestJiraSearchHandlesObjectShapedWarnings pins ruling Important-2's
// core fix: real Jira sends `warnings` as an array of OBJECTS (e.g.
// {"type":"CLAUSE_LIMIT_EXCEEDED","message":"..."}), not bare strings.
// The old `[]string`-typed field made the whole decode fail with a
// non-UserError ("json: cannot unmarshal object into
// jiraSearchResponse.warnings.0 of type string") — a hard failure that
// fired precisely in the case warnings exist to report: ingestion-limit
// truncation. This exact response body is the one a fuzz probe used to
// demonstrate the bug.
func TestJiraSearchHandlesObjectShapedWarnings(t *testing.T) {
	srv := newJiraTestServer(t, nil, `{"issues":[{"key":"RAF-1","fields":{"summary":"s"}}],"isLast":true,`+
		`"warnings":[{"type":"CLAUSE_LIMIT_EXCEEDED","message":"too many"}]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	page, err := c.MyIssues(context.Background(), "RAF")
	if err != nil {
		t.Fatalf("object-shaped warnings must not break the decode: %v", err)
	}
	if len(page.Issues) != 1 || page.Issues[0].Key != "RAF-1" {
		t.Fatalf("bad issues: %+v", page.Issues)
	}
	if !page.Truncated {
		t.Fatal("expected Truncated=true when the response carries object-shaped warnings")
	}
}

// TestJiraSearchHandlesNonArrayWarningsShapes pins round-3 Important-2:
// []json.RawMessage fixed the ELEMENT shape of `warnings`, but the field
// was still a SLICE, so any non-array VALUE for `warnings` itself still
// broke the decode the same way the original []string bug did. A probe
// found three such shapes reachable from a real (if noncompliant) server:
// a bare object, a bare string, and a bare number, none wrapped in an
// array. Each must decode without error and, per hasWarnings, count as
// "has warnings" (Truncated=true) since none of them is JSON null or [].
//
// MUTATION-VERIFIED: reverted jiraSearchResponse.Warnings from
// json.RawMessage back to []json.RawMessage. Result: RED for all three
// subtests — `json: cannot unmarshal object/string/number into Go struct
// field jiraSearchResponse.warnings of type []json.RawMessage`. Restored
// via `cp` from a pre-mutation backup; `diff` confirmed byte-identical;
// re-ran — green.
func TestJiraSearchHandlesNonArrayWarningsShapes(t *testing.T) {
	cases := map[string]string{
		"bare-object": `{"issues":[],"isLast":true,"warnings":{"type":"CLAUSE_LIMIT_EXCEEDED"}}`,
		"bare-string": `{"issues":[],"isLast":true,"warnings":"fields limit exceeded"}`,
		"bare-number": `{"issues":[],"isLast":true,"warnings":42}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			srv := newJiraTestServer(t, nil, body)
			defer srv.Close()

			c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
			page, err := c.MyIssues(context.Background(), "RAF")
			if err != nil {
				t.Fatalf("non-array warnings shape %q must not break the decode: %v", name, err)
			}
			if !page.Truncated {
				t.Fatalf("expected Truncated=true for non-array warnings shape %q", name)
			}
		})
	}
}

// TestJiraSearchWarningsNullOrEmptyDoesNotForceTruncated confirms
// hasWarnings's fix didn't overcorrect into treating "field is present at
// all" as the truncation signal: JSON null and an empty array are the two
// shapes that explicitly mean "no warnings", and paired with an explicit
// isLast:true and no nextPageToken, must still report Truncated=false.
func TestJiraSearchWarningsNullOrEmptyDoesNotForceTruncated(t *testing.T) {
	cases := map[string]string{
		"null":  `{"issues":[],"isLast":true,"warnings":null}`,
		"empty": `{"issues":[],"isLast":true,"warnings":[]}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			srv := newJiraTestServer(t, nil, body)
			defer srv.Close()

			c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
			page, err := c.MyIssues(context.Background(), "RAF")
			if err != nil {
				t.Fatal(err)
			}
			if page.Truncated {
				t.Fatalf("expected Truncated=false for warnings=%s with isLast=true and no other signal", name)
			}
		})
	}
}

// TestJiraSearchTruncatedWhenNoCompletionSignalPresent pins ruling
// Important-3: when neither of Jira's completeness signals (isLast,
// nextPageToken) is present at all — an older or proxied Jira, per the
// probe battery's exact "both-absent" and "token-null" cases — the code
// must not report Truncated=false, because that asserts completeness it
// cannot demonstrate. It must fail toward "assume more" instead.
func TestJiraSearchTruncatedWhenNoCompletionSignalPresent(t *testing.T) {
	cases := map[string]string{
		"both-absent": `{"issues":[]}`,
		"token-null":  `{"issues":[],"nextPageToken":null}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			srv := newJiraTestServer(t, nil, body)
			defer srv.Close()

			c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
			page, err := c.MyIssues(context.Background(), "RAF")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !page.Truncated {
				t.Fatal("expected Truncated=true when neither isLast nor nextPageToken is present")
			}
		})
	}
}

// TestJiraSearchNotTruncatedWhenIsLastTrueAndNoOtherSignal confirms
// Important-3's fix didn't overcorrect: an explicit isLast=true with no
// nextPageToken and no warnings IS a real completeness signal (unlike the
// both-absent/token-null cases above) and must still report
// Truncated=false.
func TestJiraSearchNotTruncatedWhenIsLastTrueAndNoOtherSignal(t *testing.T) {
	srv := newJiraTestServer(t, nil, `{"issues":[],"isLast":true}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	page, err := c.MyIssues(context.Background(), "RAF")
	if err != nil {
		t.Fatal(err)
	}
	if page.Truncated {
		t.Fatal("expected Truncated=false when isLast is explicitly true and no other signal contradicts it")
	}
}

func TestJiraReauthOn401(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error on 401")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.HasPrefix(msg, "re-auth initech") {
		t.Fatalf("error %q does not start with the expected re-auth sentence", msg)
	}
}

func TestJiraErrorBodyCapped(t *testing.T) {
	hugeBody := strings.Repeat("<html>this is a giant error page</html>", 50) // >200 chars
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(hugeBody))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error on 500")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if len(msg) > 260 { // "Jira error 500: " prefix + capped 200-char body, with slack
		t.Fatalf("error message not capped, len=%d: %q", len(msg), msg)
	}
	if strings.Contains(msg, strings.Repeat("<html>this is a giant error page</html>", 50)) {
		t.Fatalf("error message contains the full uncapped body: %q", msg)
	}
}

// TestJiraErrorBodyCapDoesNotSplitARune pins that the error-body cap cuts
// on a rune boundary. jiraErrorBodyCap is a BYTE cap, and a plain s[:cap]
// slice lands mid-rune whenever the body is non-ASCII — which is ordinary,
// not exotic, since Jira instances are localised. Invalid UTF-8 in an MCP
// tool error degrades rather than fails (encoding/json substitutes U+FFFD
// when marshalling), but it is not something to emit on purpose.
//
// The body here is 300 U+D55C runes; 200 bytes lands two bytes into the
// 67th, so a byte-slice cap produces invalid UTF-8 and this test fails.
func TestJiraErrorBodyCapDoesNotSplitARune(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(strings.Repeat("\ud55c", 300)))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "person@example.com", Token: strings.Repeat("t", 40)}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 400 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !utf8.ValidString(msg) {
		t.Fatalf("cap split a multi-byte rune: message is not valid UTF-8: %q", msg)
	}
	// Guard the premise: if the body ever stopped being truncated, the
	// test would pass without exercising the boundary at all.
	if len(msg) < jiraErrorBodyCap/2 {
		t.Fatalf("message %q is too short to have exercised the cap", msg)
	}
}

// TestJiraScrubsShortTokenPairFromEchoedAuthHeader pins the half of
// Critical-1 that the first fix left open. scrubSecrets gates substring
// replacement on a minimum token length, because replacing a very short
// token shreds unrelated diagnostic text. The original guard returned
// early for the WHOLE function, so a short token disabled every form of
// scrubbing — including the email:token pair, whose length is dominated
// by the email address and which is precisely what an echoed
// Authorization header contains.
//
// A controller probe confirmed the leak was live: with Token "short" the
// surfaced message was `Jira error 500: echo: Basic
// cGVyc29uQGV4YW1wbGUuY29tOnNob3J0`, decoding to "person@example.com:short".
// Nothing constrains a stored credential's length — NewJiraFromEnv splits
// on the first colon and accepts whatever follows — so this is reachable
// with a real, if misconfigured, keychain entry.
// TestScrubSecretsMergesDisjointOutOfOrderSpans pins that scrubSecrets
// sorts its spans before merging. Spans are collected per form, so a
// later-enumerated form routinely yields one starting BEFORE a span
// already in the slice; the merge only compares against the last element,
// so on unsorted input it silently drops spans and emits a credential
// verbatim.
//
// The existing periodic-token tests do NOT catch this: all their spans
// mutually overlap, so an unsorted merge happens to produce the right
// answer anyway. The shape that discriminates is DISJOINT out-of-order
// spans — here the bare token appears before the pair, while scrubForms
// enumerates the pair first.
//
// MUTATION-VERIFIED: deleting the sort.Slice call fails this test with
// the raw token surviving verbatim.
func TestScrubSecretsMergesDisjointOutOfOrderSpans(t *testing.T) {
	const email = "person@example.com"
	token := strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6)
	c := &JiraClient{Email: email, Token: token}

	// Bare token first, pair second, separated so the spans are disjoint.
	got := c.scrubSecrets(token + " filler " + email + ":" + token)

	if strings.Contains(got, token) {
		t.Fatalf("raw token survived scrubbing: %q", got)
	}
	if strings.Contains(got, email+":"+token) {
		t.Fatalf("pair survived scrubbing: %q", got)
	}
	if want := "[redacted] filler [redacted]"; got != want {
		t.Fatalf("scrubSecrets = %q, want %q", got, want)
	}
}

func TestJiraScrubsShortTokenPairFromEchoedAuthHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("echo: " + r.Header.Get("Authorization")))
	}))
	defer srv.Close()

	const email = "person@example.com"
	// Deliberately shorter than jiraScrubMinTokenLen.
	const token = "short"
	if len(token) >= jiraScrubMinTokenLen {
		t.Fatalf("test token %q is no longer below the scrub floor (%d) — pick a shorter one, or this test proves nothing", token, jiraScrubMinTokenLen)
	}

	c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 500 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}

	pair := email + ":" + token
	forbidden := map[string]string{
		"email:token pair":           pair,
		"base64 (std) of pair":       base64.StdEncoding.EncodeToString([]byte(pair)),
		"base64 (raw/unpadded) pair": base64.RawStdEncoding.EncodeToString([]byte(pair)),
	}
	for label, needle := range forbidden {
		if strings.Contains(msg, needle) {
			t.Fatalf("error leaked the %s: %q (message: %q)", label, needle, msg)
		}
	}
	// Round-4 fix: this test can PASS VACUOUSLY if scrubSecrets is
	// mutated to `return ""` (or any no-op that happens to produce a
	// message without the pair) — an absence-only assertion, with no
	// "the sanitiser actually fired" check and no non-empty guard, is
	// satisfied by an empty message just as well as by a correctly
	// scrubbed one. Require both: a non-empty message, and the
	// "[redacted]" marker actually present in place of the credential.
	if msg == "" {
		t.Fatal("message is empty — this test would pass vacuously against a scrubSecrets that always returns \"\"")
	}
	if !strings.Contains(msg, "[redacted]") {
		t.Fatalf("expected a [redacted] marker in place of the scrubbed credential, got %q", msg)
	}
}

// TestJiraScrubsTokenFromEchoedAuthHeader pins Critical-1: WAKIL_JIRA_BASE
// is env-controlled, so a hostile, buggy, or misconfigured-proxy Jira
// instance is reachable, and one that echoes the Authorization header
// into an error body hands the Keychain-held API token to the MCP
// caller. A fuzz probe found exactly this construction and produced,
// verbatim: `Jira error 500: echo: Basic
// cGVyc29uQGV4YW1wbGUuY29tOnN1cDNyc2VjcmV0`, which base64-decodes to
// "person@example.com:sup3rsecret" — the credential, in full, in an MCP
// tool error. This asserts the token never appears in the surfaced
// message in ANY form: raw, as the "email:token" pair, or base64-encoded
// (standard padded or raw unpadded).
//
// MUTATION-VERIFIED: replaced the body of scrubSecrets with `return msg`
// (a no-op passthrough). Result: RED —
// `error leaked the raw token: "wakil-pm... Jira error 500: echo: Basic
// cGVyc29uQGV4YW1wbGUuY29tOnN1cDNyc2VjcmV0"` (see report for full output).
// Restored via `cp` from the pre-mutation backup; `diff` confirmed
// byte-identical; re-ran — green.
func TestJiraScrubsTokenFromEchoedAuthHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("echo: " + r.Header.Get("Authorization")))
	}))
	defer srv.Close()

	const email = "person@example.com"
	const token = "sup3rsecret"
	c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 500 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}

	pair := email + ":" + token
	forbidden := map[string]string{
		"raw token":                  token,
		"email:token pair":           pair,
		"base64 (std) of pair":       base64.StdEncoding.EncodeToString([]byte(pair)),
		"base64 (raw/unpadded) pair": base64.RawStdEncoding.EncodeToString([]byte(pair)),
		"base64 (std) of token":      base64.StdEncoding.EncodeToString([]byte(token)),
		"base64 (raw) of token":      base64.RawStdEncoding.EncodeToString([]byte(token)),
	}
	for label, needle := range forbidden {
		if strings.Contains(msg, needle) {
			t.Fatalf("error leaked the %s: %q (message: %q)", label, needle, msg)
		}
	}
	if !strings.Contains(msg, "[redacted]") {
		t.Fatalf("expected a [redacted] marker in place of the scrubbed credential, got %q", msg)
	}
}

// assertNoCredentialPrefixSurvives fails t if msg contains, verbatim, any
// substring of length >= minLen that is a PREFIX of one of forms. This is
// deliberately stronger than "the complete form is absent": a
// cap-then-scrub ordering bug does not leak the complete form (that IS
// absent), it leaks a PREFIX of it — the truncation boundary cuts the
// form's tail off before scrubSecrets ever runs, so ReplaceAll's
// whole-substring match never fires and the leading portion survives
// verbatim. Checking only "is the complete form present" cannot detect
// that; TestJiraScrubsTokenFromEchoedAuthHeader's 11-character token
// couldn't have caught it either way, since the whole blob fit under the
// cap regardless of ordering.
func assertNoCredentialPrefixSurvives(t *testing.T, msg string, minLen int, forms map[string]string) {
	t.Helper()
	for label, f := range forms {
		for n := minLen; n <= len(f); n++ {
			prefix := f[:n]
			if strings.Contains(msg, prefix) {
				t.Fatalf("message contains a %d-char prefix of the %s: %q (message: %q)", n, label, prefix, msg)
			}
		}
	}
}

// TestJiraScrubsRealisticLongTokenFromEchoedAuthHeader pins Critical-1
// round 3: the adversarial re-review found that jira.go's error-body
// handling capped the response body to jiraErrorBodyCap (200) bytes
// BEFORE calling scrubSecrets, not after. strings.ReplaceAll requires a
// WHOLE-substring match, so a 200-byte cap slicing a base64 credential
// blob mid-string left a surviving PREFIX that matched none of
// scrubSecrets's forms and passed through verbatim — and a base64 PREFIX
// decodes to a plaintext PREFIX of "email:token". The reviewer's exact
// repro, changing only the token to a realistic 192-character Atlassian
// shape: 188 of 284 base64 chars survived, recovering the full email plus
// 122 of the token's 192 characters (64%).
//
// This is exactly the scenario TestJiraScrubsTokenFromEchoedAuthHeader
// already covers, with one change that matters: a token long enough
// (150+ chars, well past jiraErrorBodyCap on its own) that the old
// cap-then-scrub order provably leaks a prefix of it, where the existing
// test's 11-character token fits entirely under the cap either way and
// therefore cannot distinguish the two orderings. It asserts two things
// the existing test does not: (1) no prefix of length >= 16 of ANY
// credential form survives — not merely that the COMPLETE form is
// absent, which is exactly the assertion shape that let this through
// undetected; (2) the scrub actually fired (the "[redacted]" marker is
// present), so this cannot pass vacuously if the body ever came back
// empty or the message shape changed.
//
// MUTATION-VERIFIED: restored the cap-then-scrub order (io.ReadAll capped
// to jiraErrorBodyCap FIRST, c.scrubSecrets applied to the capped string
// SECOND — the exact code shape this test exists to catch). Result: RED
// — see report for verbatim output. Restored via `cp` from a
// pre-mutation backup; `diff` confirmed byte-identical; re-ran — green.
func TestJiraScrubsRealisticLongTokenFromEchoedAuthHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("echo: " + r.Header.Get("Authorization")))
	}))
	defer srv.Close()

	const email = "person@example.com"
	// A realistic Atlassian API token shape: long, base62-ish, well past
	// jiraErrorBodyCap (200) once base64-encoded together with email.
	token := strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6) // 192 chars
	if len(token) < 150 {
		t.Fatalf("test token len=%d is shorter than the required 150 — this test proves nothing below that length", len(token))
	}

	c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 500 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}

	if !strings.Contains(msg, "[redacted]") {
		t.Fatalf("expected the scrub to have fired (missing [redacted] marker) — message: %q", msg)
	}

	pair := email + ":" + token
	forms := map[string]string{
		"raw token":                  token,
		"email:token pair":           pair,
		"base64 (std) of pair":       base64.StdEncoding.EncodeToString([]byte(pair)),
		"base64 (raw/unpadded) pair": base64.RawStdEncoding.EncodeToString([]byte(pair)),
		"base64 (std) of token":      base64.StdEncoding.EncodeToString([]byte(token)),
		"base64 (raw) of token":      base64.RawStdEncoding.EncodeToString([]byte(token)),
	}
	assertNoCredentialPrefixSurvives(t, msg, 16, forms)
}

// credentialForms builds the full set of representations scrubForms()
// produces for email/token, for use by tests that need to assert no
// prefix of ANY of them survives — kept independent of scrubForms()
// itself (not calling the production function) so a bug that mutates
// scrubForms() to omit a form can't also blind the test that checks for
// it.
func credentialForms(email, token string) map[string]string {
	pair := email + ":" + token
	return map[string]string{
		"raw token":                     token,
		"email:token pair":              pair,
		"base64 (std) of pair":          base64.StdEncoding.EncodeToString([]byte(pair)),
		"base64 (raw/unpadded) pair":    base64.RawStdEncoding.EncodeToString([]byte(pair)),
		"base64 (urlsafe) of pair":      base64.URLEncoding.EncodeToString([]byte(pair)),
		"base64 (urlsafe/raw) of pair":  base64.RawURLEncoding.EncodeToString([]byte(pair)),
		"base64 (std) of token":         base64.StdEncoding.EncodeToString([]byte(token)),
		"base64 (raw) of token":         base64.RawStdEncoding.EncodeToString([]byte(token)),
		"base64 (urlsafe) of token":     base64.URLEncoding.EncodeToString([]byte(token)),
		"base64 (urlsafe/raw) of token": base64.RawURLEncoding.EncodeToString([]byte(token)),
	}
}

// assertScrubFiredAndClean is the shared assertion for every round-4
// doubled-echo-style probe: the sanitiser must actually have fired
// ([redacted] present, never a vacuous absence check per item 4's
// discipline), and no prefix of length >= 16 of any credential form may
// survive anywhere in msg.
func assertScrubFiredAndClean(t *testing.T, label, msg string, forms map[string]string) {
	t.Helper()
	if !strings.Contains(msg, "[redacted]") {
		t.Fatalf("%s: expected the scrub to have fired (missing [redacted] marker) — message: %q", label, msg)
	}
	assertNoCredentialPrefixSurvives(t, msg, 16, forms)
}

// TestJiraScrubsDoubledEchoAcrossPadSweep pins Critical-1 round 4: the
// window math in the pre-round-4 code (jiraErrorBodyCap +
// longestScrubForm) is provably wide enough for a SINGLE credential
// occurrence, but scrubbing SHRINKS the string — every ReplaceAll
// collapses a matched form down to the 10-byte "[redacted]" marker. If
// the same credential form appears a SECOND time later in the body, the
// first replacement drags bytes that originally sat beyond the cap into
// the visible prefix, and the naive "cut to cap AFTER a fixed-size scrub
// pass" still surfaces a verbatim prefix of that second occurrence.
//
// The server here echoes the raw Authorization header it received
// TWICE, with a variable amount of padding between the two copies — an
// ordinary proxy/gateway dumping the request twice (original + retried)
// produces exactly this shape by accident, it is not a contrived
// construction. Sweeping pad from 0 up past the point where the second
// occurrence falls entirely outside the read window exercises every
// relative position the second occurrence can take against the cut.
func TestJiraScrubsDoubledEchoAcrossPadSweep(t *testing.T) {
	const email = "person@example.com"
	token := strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6) // 192 chars
	forms := credentialForms(email, token)

	for _, pad := range []int{0, 1, 50, 100, 150, 178, 185, 190, 199, 200, 250} {
		pad := pad
		t.Run(fmt.Sprintf("pad=%d", pad), func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				auth := r.Header.Get("Authorization")
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte(auth + strings.Repeat("P", pad) + auth))
			}))
			defer srv.Close()

			c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
			_, err := c.MyIssues(context.Background(), "RAF")
			if err == nil {
				t.Fatal("expected an error from the 500 response")
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected UserError, got %T: %v", err, err)
			}
			assertScrubFiredAndClean(t, fmt.Sprintf("pad=%d", pad), msg, forms)
		})
	}
}

// TestJiraScrubsRepeatedEchoNTimes extends the doubled-echo probe to 3,
// 5, and 10 repetitions of the same credential in one body (pad=0
// between each), confirming the fix isn't merely tuned for "exactly
// two" occurrences.
func TestJiraScrubsRepeatedEchoNTimes(t *testing.T) {
	const email = "person@example.com"
	token := strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6)
	forms := credentialForms(email, token)

	for _, n := range []int{2, 3, 5, 10} {
		n := n
		t.Run(fmt.Sprintf("n=%d", n), func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				auth := r.Header.Get("Authorization")
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte(strings.Repeat(auth, n)))
			}))
			defer srv.Close()

			c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
			_, err := c.MyIssues(context.Background(), "RAF")
			if err == nil {
				t.Fatal("expected an error from the 500 response")
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected UserError, got %T: %v", err, err)
			}
			assertScrubFiredAndClean(t, fmt.Sprintf("n=%d", n), msg, forms)
		})
	}
}

// TestJiraScrubsRealisticProxyGatewayEcho pins the "not contrived" claim
// directly: an ordinary proxy/gateway error page that dumps the request
// headers for both the original request AND a retried request is exactly
// the threat scrubSecrets documents itself as answering (an ACCIDENTAL
// echo), and it independently reproduces the doubled-occurrence shape
// above without any test-only padding construction.
func TestJiraScrubsRealisticProxyGatewayEcho(t *testing.T) {
	const email = "person@example.com"
	token := strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6)
	forms := credentialForms(email, token)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		body := `{"errorMessages":["Gateway error"],"request":{"headers":{"Authorization":"` + auth +
			`","Accept":"application/json"}},"retry":{"headers":{"Authorization":"` + auth + `"}}}`
		w.WriteHeader(http.StatusBadGateway)
		w.Write([]byte(body))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 502 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	assertScrubFiredAndClean(t, "proxy-gateway-json", msg, forms)
}

// TestJiraScrubSkipsDegeneratePairForms pins Minor-6: a directly
// constructed JiraClient with both Email and Token empty produces a
// degenerate "email:token" pair (":"), whose base64 encodings ("Og==",
// "Og") are short enough to appear coincidentally in ordinary diagnostic
// text. The old guard skipped only the literal "" and ":" forms, not
// their base64 encodings, so scrubSecrets would ReplaceAll "Og" across
// the entire error body. Not reachable via NewJiraFromEnv (which rejects
// empty halves), but scrubForms must not manufacture short, unrelated-
// text-shredding forms from a degenerate pair regardless.
func TestJiraScrubSkipsDegeneratePairForms(t *testing.T) {
	c := &JiraClient{Email: "", Token: ""}
	msg := c.scrubSecrets("diagnostic text mentioning Og and Ogre, not a credential")
	if strings.Contains(msg, "[redacted]") {
		t.Fatalf("degenerate empty pair scrubbed unrelated text: %q", msg)
	}
	if msg != "diagnostic text mentioning Og and Ogre, not a credential" {
		t.Fatalf("degenerate empty pair altered unrelated text: %q", msg)
	}
}

// TestTruncateBytesAtRuneBoundaryNegativeMaxDoesNotPanic pins Minor-5: a
// negative max previously reached s[:max] unguarded (len(s) <= max is
// false, and the max > 0 loop is skipped), panicking with "slice bounds
// out of range". Unreachable today — the only call site passes a
// positive constant — but defence in depth costs nothing here.
func TestTruncateBytesAtRuneBoundaryNegativeMaxDoesNotPanic(t *testing.T) {
	got := truncateBytesAtRuneBoundary("hello", -1)
	if got != "" {
		t.Fatalf("expected empty string for a negative max, got %q", got)
	}
}

// TestJiraRefusesRedirect pins Minor-7: a search API never legitimately
// redirects, and Go's default client policy would otherwise follow up to
// 10 redirects and preserve the Authorization header across a
// same-hostname redirect. sawAuth proves the request to the redirect
// target never happened at all (not merely that the response looked like
// an error).
func TestJiraRefusesRedirect(t *testing.T) {
	sawAuth := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, _, ok := r.BasicAuth(); ok {
			sawAuth = true
		}
		w.Write([]byte(`{"issues":[]}`))
	}))
	defer target.Close()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/rest/api/3/search/jql", http.StatusFound)
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error when the Jira server tries to redirect")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if sawAuth {
		t.Fatal("client followed the redirect and leaked the Authorization header to a different host")
	}
}

// TestNewJiraFromEnvMissingBaseAndOrg pins the actual current behaviour
// when nothing at all is configured. NewJiraFromEnv resolves the org
// FIRST, unconditionally, via the single CurrentOrg() call at the top of
// the function — before it ever reads WAKIL_JIRA_BASE or org.json — so
// with WAKIL_ORG unset the error is CurrentOrg's own "WAKIL_ORG is not
// set", not a Jira-specific one. There is exactly one CurrentOrg() call
// in the function (org.json is read via LoadOrgFor(org), not LoadOrg(),
// precisely so the org already in hand is reused instead of re-resolved
// internally), so there is no ambiguity about which call this test
// trips on. This test used to assert an "WAKIL_JIRA_BASE not set"
// message, which described the OLD, env-only behaviour and is no longer
// what happens.
func TestNewJiraFromEnvMissingBaseAndOrg(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "")
	t.Setenv("WAKIL_ORG", "")
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected an error when WAKIL_JIRA_BASE and WAKIL_ORG are both unset")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "WAKIL_ORG") {
		t.Fatalf("error %q does not mention WAKIL_ORG", msg)
	}
}

// TestNewJiraFromEnvRejectsNonHTTPS, and the six tests that follow it
// down to TestNewJiraFromEnvRejectsPath, all set WAKIL_ORG: NewJiraFromEnv
// resolves the org first, unconditionally, before it ever looks at
// WAKIL_JIRA_BASE, so a run with WAKIL_ORG unset would fail on
// CurrentOrg's own error instead of exercising normalizeJiraBase, which
// is what each of these tests exists to pin.
func TestNewJiraFromEnvRejectsNonHTTPS(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "http://example.atlassian.net")
	t.Setenv("WAKIL_ORG", "initech")
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected rejection of a non-https base URL")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "https") {
		t.Fatalf("error %q does not mention https", msg)
	}
}

func TestNewJiraFromEnvRejectsRelativeBase(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "example.atlassian.net")
	t.Setenv("WAKIL_ORG", "initech")
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected rejection of a relative base URL")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

// TestNewJiraFromEnvRedactsPasswordInError pins Minor-5: the exact
// scenario from the controller ruling
// (WAKIL_JIRA_BASE=http://user:sup3rsecret@x.atlassian.net) must not hand
// the password to whatever reads the resulting UserError — in
// particular, an MCP tool caller.
func TestNewJiraFromEnvRedactsPasswordInError(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "http://user:sup3rsecret@x.atlassian.net")
	t.Setenv("WAKIL_ORG", "initech")
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected rejection of a non-https base URL with embedded credentials")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if strings.Contains(msg, "sup3rsecret") {
		t.Fatalf("error leaked the password: %q", msg)
	}
}

// TestNewJiraFromEnvRejectsUserinfo pins Minor-6: userinfo in
// WAKIL_JIRA_BASE would create a second credential channel through an
// env var, directly against the standing constraint that secrets live
// only in the Keychain.
func TestNewJiraFromEnvRejectsUserinfo(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "https://user:sup3rsecret@example.atlassian.net")
	t.Setenv("WAKIL_ORG", "initech")
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected rejection of a base URL containing userinfo")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if strings.Contains(msg, "sup3rsecret") {
		t.Fatalf("error leaked the password: %q", msg)
	}
}

// TestNewJiraFromEnvRejectsQuery pins Minor-6: a query string would ride
// along into the concatenated request URL (see search), e.g.
// "https://x/?a=b" would send the API path itself into the query string.
func TestNewJiraFromEnvRejectsQuery(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "https://example.atlassian.net?a=b")
	t.Setenv("WAKIL_ORG", "initech")
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected rejection of a base URL containing a query string")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

// TestNewJiraFromEnvRejectsFragment pins Minor-6.
func TestNewJiraFromEnvRejectsFragment(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "https://example.atlassian.net#frag")
	t.Setenv("WAKIL_ORG", "initech")
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected rejection of a base URL containing a fragment")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

// TestNewJiraFromEnvRejectsPath pins Minor-6: a path would compound into
// the concatenated request URL the same way a query string would (see
// search), building a request against the wrong endpoint entirely.
func TestNewJiraFromEnvRejectsPath(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "https://example.atlassian.net/some/path")
	t.Setenv("WAKIL_ORG", "initech")
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected rejection of a base URL containing a path")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

// fakeJiraSecurityBinary writes a fake `security` executable to a fresh
// temp dir and points PATH at it, so SecretGet resolves to a script under
// the test's control instead of the real macOS Keychain. If exitCode is 0
// the script prints value and exits 0; otherwise it prints nothing to
// stdout and exits exitCode (simulating either "not found", exit 44, or
// any other real failure such as a locked keychain).
func fakeJiraSecurityBinary(t *testing.T, value string, exitCode int) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "security")
	var body string
	if exitCode == 0 {
		body = fmt.Sprintf("#!/bin/sh\nprintf '%%s' %q\n", value)
	} else {
		body = fmt.Sprintf("#!/bin/sh\necho 'fake diagnostic stderr text' >&2\nexit %d\n", exitCode)
	}
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatalf("write fake security binary: %v", err)
	}
	// **`WAKIL_SECURITY_BINARY`, not PATH** (2e, #201). The product now
	// invokes the Keychain tool by its absolute path, because the ACL on
	// the CLI's own item names `/usr/bin/security` and a bare name
	// resolved off PATH is a different application to that ACL. A
	// PATH-based fake stopped intercepting the moment that landed — and
	// would have pointed this test at the operator's real login keychain
	// while still passing.
	t.Setenv("WAKIL_SECURITY_BINARY", script)
}

func TestNewJiraFromEnvStripsTrailingSlashAndReadsCreds(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "https://example.atlassian.net/")
	t.Setenv("WAKIL_ORG", "initech")
	fakeJiraSecurityBinary(t, "person@example.com:tok123", 0)

	c, err := NewJiraFromEnv()
	if err != nil {
		t.Fatalf("NewJiraFromEnv: %v", err)
	}
	if c.BaseURL != "https://example.atlassian.net" {
		t.Fatalf("BaseURL = %q, want no trailing slash", c.BaseURL)
	}
	if c.Email != "person@example.com" || c.Token != "tok123" {
		t.Fatalf("bad creds: email=%q token=%q", c.Email, c.Token)
	}
}

// TestNewJiraFromEnvDistinguishesNotFoundFromRealError pins the fix for
// the controller's ruling 5 defect: a genuine keychain failure (locked
// keychain, non-44 exit code) must NOT be reported with the same
// "not authenticated" text as an actual missing credential, because the
// remedy differs (unlock the keychain vs. run `wakil secrets set`).
func TestNewJiraFromEnvDistinguishesNotFoundFromRealError(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "https://example.atlassian.net")
	t.Setenv("WAKIL_ORG", "initech")

	fakeJiraSecurityBinary(t, "", 1) // exit 1: NOT the "not found" code (44)
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected an error")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if strings.Contains(msg, "not authenticated") {
		t.Fatalf("real keychain error was misreported as an auth problem: %q", msg)
	}
	if !strings.Contains(msg, "keychain") {
		t.Fatalf("expected the real diagnostic to surface, got %q", msg)
	}
}

func TestNewJiraFromEnvReportsMissingCredentialDistinctly(t *testing.T) {
	t.Setenv("WAKIL_JIRA_BASE", "https://example.atlassian.net")
	t.Setenv("WAKIL_ORG", "initech")

	fakeJiraSecurityBinary(t, "", 44) // exit 44: the real "not found" code
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("expected an error")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "no credential stored") {
		t.Fatalf("expected the not-found message, got %q", msg)
	}
}

// ============================================================
// Round 5
// ============================================================

// assertNoVerbatimCredentialSubstring fails t if msg contains, verbatim,
// any substring of length >= minLen that is itself a substring (not
// merely a prefix — start, middle, OR end) of one of forms. This is
// deliberately stronger than assertNoCredentialPrefixSurvives: a
// periodic-form overlap leak (Important-1) does not necessarily leave a
// clean PREFIX of a form behind, it can leave any contiguous ROTATION of
// it, because the surviving fragment is whatever a naive per-form
// strings.ReplaceAll pass failed to consume when a second occurrence of
// a periodic form started inside the first one's span.
func assertNoVerbatimCredentialSubstring(t *testing.T, msg string, minLen int, forms map[string]string) {
	t.Helper()
	for label, f := range forms {
		if len(f) < minLen {
			continue
		}
		for i := 0; i+minLen <= len(msg); i++ {
			cand := msg[i : i+minLen]
			if strings.Contains(f, cand) {
				t.Fatalf("message contains a %d-byte verbatim substring of the %s: %q (message: %q)", minLen, label, cand, msg)
			}
		}
	}
}

// TestJiraScrubsPeriodicTokenNoOverlapLeak pins Important-1: scrubSecrets
// used to scrub each form with a single strings.ReplaceAll pass, which
// only ever matches non-overlapping occurrences left-to-right — it
// silently skips any occurrence that starts inside one it has already
// consumed. A PERIODIC form produces exactly that shape. A real
// Atlassian API token is high-entropy and never periodic, but this
// file's OWN fixtures stand a token in with a literal strings.Repeat,
// which the base64 alphabet then turns into an internally-periodic
// encoded string too (see the debug trail in this round's report): here,
// base64(token) itself has a repeating 128-byte block, so body (that
// block repeated twice, back to back) contains a SECOND full occurrence
// of the base64(token) form starting inside the first one's span.
//
// Before this fix, this exact repro reproduced verbatim what a reviewer
// found: "[redacted]QVRBVFQzeEZmR0YwYUI5elE3d0UyclQ1eVU4aU8xcExB…" — a
// long run of raw base64 characters (a verbatim fragment of the token)
// surviving right next to the first "[redacted]" marker.
func TestJiraScrubsPeriodicTokenNoOverlapLeak(t *testing.T) {
	const email = "person@example.com"
	token := strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6)
	c := &JiraClient{Email: email, Token: token}

	b64 := base64.StdEncoding.EncodeToString([]byte(token))
	body := b64 + b64
	msg := c.scrubSecrets(body)

	if !strings.Contains(msg, "[redacted]") {
		t.Fatalf("expected the scrub to have fired, got %q", msg)
	}
	assertNoVerbatimCredentialSubstring(t, msg, 16, credentialForms(email, token))
}

// TestJiraScrubsPeriodicTokenThroughFullPipeline extends the periodic-
// overlap repro through the FULL search() pipeline (scrubCutPoint +
// scrubSecrets + display truncation), using a second, independently-
// verified repro: a short period-8 token whose repeated form leaves a
// non-overlapping 16-byte residue when only a SINGLE strings.ReplaceAll
// pass is used, confirmed against the pre-fix code as
// "Jira error 400: [redacted]0123456701234567 — Jira rejected field
// 'summary'" (16 verbatim token characters surviving after the
// "[redacted]" marker).
func TestJiraScrubsPeriodicTokenThroughFullPipeline(t *testing.T) {
	const email = "person@example.com"
	cases := []struct {
		name  string
		token string
		body  string
	}{
		{
			name:  "doubled-base64-of-192char-token",
			token: strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6),
			body: func() string {
				b64 := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6)))
				return b64 + b64
			}(),
		},
		{
			name:  "period-8-token-with-trailing-diagnostic",
			token: strings.Repeat("01234567", 5),
			body:  strings.Repeat("01234567", 7) + " — Jira rejected field 'summary'",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusBadRequest)
				w.Write([]byte(tc.body))
			}))
			defer srv.Close()

			c := &JiraClient{BaseURL: srv.URL, Email: email, Token: tc.token}
			_, err := c.MyIssues(context.Background(), "RAF")
			if err == nil {
				t.Fatal("expected an error from the 400 response")
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected UserError, got %T: %v", err, err)
			}
			if !strings.Contains(msg, "[redacted]") {
				t.Fatalf("expected the scrub to have fired, got %q", msg)
			}
			assertNoVerbatimCredentialSubstring(t, msg, 16, credentialForms(email, tc.token))
		})
	}
}

// TestJiraScrubsURLSafeBase64OfPairAndToken pins Important-2's mutations
// 2 and 3: removing the URL-safe base64 forms (pair or token) from
// scrubForms left the whole suite green, because every existing scrub
// test only ever echoes a credential encoded with the STANDARD base64
// alphabet (Go's http Basic Auth always uses base64.StdEncoding). The
// token bytes here are deliberately chosen so the standard and URL-safe
// alphabets actually diverge (std contains '+'/'/' where url-safe has
// '-'/'_') — otherwise this test could pass even with the URL-safe forms
// disabled, proving nothing. The email is deliberately non-ASCII too,
// covering Minor-2's fix in the same pass.
func TestJiraScrubsURLSafeBase64OfPairAndToken(t *testing.T) {
	const email = "pérson@example.com"
	token := string([]byte{0xFF, 0xFF, 0xFF, 0xFB, 0xEF, 0xBE, 0xFF, 0xFF, 0xFF, 0xFF})
	pair := email + ":" + token

	stdPairB64 := base64.StdEncoding.EncodeToString([]byte(pair))
	urlPairB64 := base64.URLEncoding.EncodeToString([]byte(pair))
	stdTokenB64 := base64.StdEncoding.EncodeToString([]byte(token))
	urlTokenB64 := base64.URLEncoding.EncodeToString([]byte(token))
	if stdPairB64 == urlPairB64 || stdTokenB64 == urlTokenB64 {
		t.Fatalf("test token/email do not exercise the std/url-safe alphabet difference — pick different bytes")
	}

	c := &JiraClient{Email: email, Token: token}

	t.Run("pair", func(t *testing.T) {
		msg := c.scrubSecrets("diagnostic echo: " + urlPairB64 + " end")
		if !strings.Contains(msg, "[redacted]") {
			t.Fatalf("expected the scrub to have fired, got %q", msg)
		}
		if strings.Contains(msg, urlPairB64) {
			t.Fatalf("URL-safe base64 of the pair survived: %q", msg)
		}
	})
	t.Run("token", func(t *testing.T) {
		msg := c.scrubSecrets("diagnostic echo: " + urlTokenB64 + " end")
		if !strings.Contains(msg, "[redacted]") {
			t.Fatalf("expected the scrub to have fired, got %q", msg)
		}
		if strings.Contains(msg, urlTokenB64) {
			t.Fatalf("URL-safe base64 of the token survived: %q", msg)
		}
	})
}

// TestJiraScrubsBareTokenWithoutPairContext pins Important-2's mutation
// 7 (and the note explaining it): every existing scrub test echoes the
// PAIR (email:token), never the bare token in isolation, so a mutation
// disabling the token-only forms entirely left every one of those tests
// green. This constructs a body containing ONLY the bare token, never
// combined with the email.
func TestJiraScrubsBareTokenWithoutPairContext(t *testing.T) {
	const email = "person@example.com"
	const token = "sup3rBareTokenOnly123456"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("upstream diagnostic: token=" + token))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 500 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "[redacted]") {
		t.Fatalf("expected the scrub to have fired, got %q", msg)
	}
	if strings.Contains(msg, token) {
		t.Fatalf("bare token (no email/pair context) survived: %q", msg)
	}
}

// TestScrubCutPointExcludesOccurrenceStartingExactlyAtCap pins
// Important-2's mutation 5: flipping scrubCutPoint's `start < cut` to
// `start <= cut` would treat an occurrence starting EXACTLY at the
// current cut as straddling it, when in fact — per scrubCutPoint's own
// doc comment — such an occurrence lies entirely OUTSIDE body[:cut] and
// must be excluded, not extended into.
func TestScrubCutPointExcludesOccurrenceStartingExactlyAtCap(t *testing.T) {
	const form = "SECRETFORM"
	body := strings.Repeat("x", 20) + form // form starts exactly at position 20
	cut := scrubCutPoint(body, 20, []string{form})
	if cut != 20 {
		t.Fatalf("cut = %d, want 20 (an occurrence starting exactly at cap must be excluded, not straddling)", cut)
	}
}

// TestScrubCutPointLoopsToFixedPointAcrossCascadingOccurrences pins
// Important-2's mutation 6: collapsing scrubCutPoint's fixed-point loop
// to a single pass would miss a SECOND occurrence that only starts
// straddling the cut once a FIRST occurrence has already pushed the cut
// forward. Constructed so a single pass extends the cut from 10 to 15
// (formA straddles the original cap), and only a second pass discovers
// formB, which starts at position 14 — inside formA's span, but not
// before the ORIGINAL cut(10) — straddling the NEW cut(15) and pushing
// it all the way to the end of the body.
func TestScrubCutPointLoopsToFixedPointAcrossCascadingOccurrences(t *testing.T) {
	const formA = "1234567890" // 10 chars, occupies body[5:15]
	const formB = "0ABCDEFGHI" // 10 chars, occupies body[14:24] (overlaps formA's last byte)
	body := "xxxxx" + "1234567890" + "ABCDEFGHI"
	if len(body) != 24 {
		t.Fatalf("test body construction is wrong, len=%d", len(body))
	}

	cut := scrubCutPoint(body, 10, []string{formA, formB})
	if cut != len(body) {
		t.Fatalf("cut = %d, want %d (a cascading straddle must extend across multiple iterations, not stop after the first)", cut, len(body))
	}
}

// TestStripPartialCredentialSuffixRespectsPerFormMinLen is a direct unit
// test of stripPartialCredentialSuffix, pinning Important-2's mutation 4
// (raising the flat n>=8 floor to n>=200) at the exact boundary: a
// 7-character suffix match must survive (below minLen), an 8-character
// one must be stripped (at minLen).
func TestStripPartialCredentialSuffixRespectsPerFormMinLen(t *testing.T) {
	forms := []scrubForm{{lit: "0123456789ABCDEF", minLen: 8}}

	if got := stripPartialCredentialSuffix("hello 0123456", forms); got != "hello 0123456" {
		t.Fatalf("7-char match below minLen was stripped: got %q", got)
	}
	if got := stripPartialCredentialSuffix("hello 01234567", forms); got != "hello " {
		t.Fatalf("8-char match at minLen was not stripped: got %q", got)
	}
}

// TestJiraSearchStripsCoincidentalPartialTokenPrefixAtDisplayEdge pins
// Important-2's mutation 1 (deleting the stripPartialCredentialSuffix
// call in search()) together with mutation 4 (raising its floor to 200):
// constructed so NO complete credential form ever appears anywhere in
// the body — scrubCutPoint and scrubSecrets are both no-ops here — and
// the trailing 8 characters of the diagnostic text happen, by ordinary
// bad luck rather than any real credential echo, to equal the token's
// own first 8 bytes. The ONLY thing that can remove them is
// stripPartialCredentialSuffix actually being wired into search() with
// its 8-byte floor intact.
func TestJiraSearchStripsCoincidentalPartialTokenPrefixAtDisplayEdge(t *testing.T) {
	const email = "person@example.com"
	const token = "XYZABCDErestOfTheRealToken0123456789"
	prefix := "Jira rejected value "
	body := prefix + token[:8] // "XYZABCDE" — exactly jiraScrubMinTokenLen bytes

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(body))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: email, Token: token}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 400 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	want := "Jira error 400: " + prefix
	if msg != want {
		t.Fatalf("got %q, want %q (the coincidental 8-byte token-prefix suffix must be stripped)", msg, want)
	}
}

// TestStripPartialCredentialSuffixSurvivesEmailOnlyText pins Minor-1: the
// pair form's length is dominated by the (non-secret) email address, so
// a flat minLen floor low enough to catch a short partial TOKEN is also
// low enough to fire on an ordinary diagnostic sentence that merely
// happens to end with the account's own email. Both exact false-positive
// sentences from the ruling must survive completely unaltered.
func TestStripPartialCredentialSuffixSurvivesEmailOnlyText(t *testing.T) {
	c := &JiraClient{Email: "person@example.com", Token: strings.Repeat("t", 20)}
	forms := c.scrubForms()

	cases := []string{
		"Unauthorized for user person@example.com",
		"field 'reporter' is invalid for person@example.com",
	}
	for _, s := range cases {
		if got := stripPartialCredentialSuffix(s, forms); got != s {
			t.Fatalf("legitimate diagnostic naming only the email was altered: got %q, want %q", got, s)
		}
	}
}

// TestStripPartialCredentialSuffixStripsGenuineTokenBearingPartial pins
// the other half of Minor-1's ruling: the per-form minimum must not
// overcorrect into never firing on the pair form at all — a partial that
// DOES include actual token bytes past the email and its separating
// colon must still be stripped.
func TestStripPartialCredentialSuffixStripsGenuineTokenBearingPartial(t *testing.T) {
	c := &JiraClient{Email: "person@example.com", Token: strings.Repeat("t", 20)}
	forms := c.scrubForms()

	prefix := "Authorization failed for "
	partial := c.Email + ":" + c.Token[:5] // includes 5 real token bytes
	s := prefix + partial

	got := stripPartialCredentialSuffix(s, forms)
	if got != prefix {
		t.Fatalf("got %q, want %q (a partial that reveals real token bytes must be fully stripped)", got, prefix)
	}
}

// TestJiraGetIssueFailsClosedWhenNotFound pins Minor-3: GetIssue must
// return an error — not a zero-value Issue with a nil error — when Jira
// reports no issue matching the requested key. Before this test, the
// literal string "issue not found" appeared in no test file, and
// mutating GetIssue's not-found path to `return Issue{}, nil` left the
// whole suite green.
func TestJiraGetIssueFailsClosedWhenNotFound(t *testing.T) {
	srv := newJiraTestServer(t, nil, `{"issues":[]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	issue, err := c.GetIssue(context.Background(), "RAF", "RAF-999")
	if err == nil {
		t.Fatalf("expected an error for a missing issue, got issue=%+v", issue)
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "issue not found") {
		t.Fatalf("error %q does not mention issue not found", msg)
	}
	if issue != (Issue{}) {
		t.Fatalf("expected a zero-value Issue alongside the error, got %+v", issue)
	}
}

// TestJiraGetIssueFailsClosedWhenSearchReturnsWrongProjectIssue pins the
// other half of Minor-3: even if Jira's search for "key = X" returns an
// issue whose key does NOT belong to projectKey, GetIssue's post-filter
// (filterToProject) must drop it and report not-found, rather than
// returning the out-of-project issue. A mutation removing that filter
// call left this unguarded.
func TestJiraGetIssueFailsClosedWhenSearchReturnsWrongProjectIssue(t *testing.T) {
	srv := newJiraTestServer(t, nil, `{"issues":[{"key":"OTHER-1","fields":{"summary":"s","status":{"name":"x"},"assignee":{"displayName":"a"}}}]}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	issue, err := c.GetIssue(context.Background(), "RAF", "RAF-999")
	if err == nil {
		t.Fatalf("expected rejection of an out-of-project result, got issue=%+v", issue)
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "issue not found") {
		t.Fatalf("error %q does not mention issue not found", msg)
	}
}

// TestJiraDropsTrailingIncompleteRuneAfterWhitespaceTrim pins
// Important-3's first route: leading whitespace trimmed by
// strings.TrimSpace can pull an otherwise-oversized (and therefore
// window-truncated, mid-rune) body under jiraErrorBodyCap, so
// scrubCutPoint's own snap-to-rune-boundary logic (guarded by
// `cut < len(body)`) never runs, and truncateBytesAtRuneBoundary is a
// no-op once the string is already at or under its cap. Only
// dropTrailingIncompleteRune catches this. Numbers are chosen (not
// copied from the ruling verbatim) so that, with this file's usual
// short "e"/"t" test credential, the read window truncates the network
// stream inside the hangul run at a byte offset that both (a) lands
// mid-rune and (b) is under jiraErrorBodyCap once the leading spaces are
// trimmed — see this round's report for the arithmetic.
func TestJiraDropsTrailingIncompleteRuneAfterWhitespaceTrim(t *testing.T) {
	body := strings.Repeat(" ", 10) + strings.Repeat("한", 100)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(body))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 400 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !utf8.ValidString(msg) {
		t.Fatalf("message ends mid-rune: not valid UTF-8: %q", msg)
	}
	// Guard the premise: the message must actually have been long enough
	// to exercise the whitespace-then-mid-rune path, not merely be short
	// (e.g. empty) by coincidence.
	if len(msg) < 100 {
		t.Fatalf("message %q is too short to have exercised the intended path", msg)
	}
}

// TestJiraSurfacesReadErrorInsteadOfPretendingReadSucceeded pins
// Important-3's second route: raw, _ := io.ReadAll(...) discarded the
// read error, so a mid-stream connection drop silently produced a
// byte-truncated body that went out as if it were a normal, complete
// read. This hijacks the connection to announce a Content-Length far
// larger than what is actually sent, then closes immediately — the
// client's Read must then return before the announced length arrives,
// giving io.ReadAll a non-nil error alongside whatever partial bytes it
// did read.
func TestJiraSurfacesReadErrorInsteadOfPretendingReadSucceeded(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Fatal("ResponseWriter does not support hijacking")
		}
		conn, buf, err := hj.Hijack()
		if err != nil {
			t.Fatalf("hijack: %v", err)
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 400 Bad Request\r\nContent-Length: 5000\r\n\r\n")
		buf.WriteString("Jira rejected the request: partial diagnostic before the connection drops")
		buf.Flush()
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the truncated 400 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "read error") {
		t.Fatalf("expected the message to disclose that the read did not complete cleanly, got %q", msg)
	}
	if !strings.Contains(msg, "Jira rejected the request") {
		t.Fatalf("expected the partial body that WAS read to still be surfaced, got %q", msg)
	}
}

// TestScrubCutPointHandlesNonASCIIEmailWithoutMidRuneCut pins Minor-2:
// the comment previously justified rune-alignment by assuming every
// scrubForms() entry is pure ASCII, which nothing enforces (Email/Token
// come from the Keychain). This sweeps 400 cap offsets against a body
// built from a non-ASCII email, confirming scrubCutPoint never returns a
// cut that splits a rune — the real reason being that UTF-8 is
// self-synchronising, not that the form happens to be ASCII.
func TestScrubCutPointHandlesNonASCIIEmailWithoutMidRuneCut(t *testing.T) {
	const email = "pérsön@éxample.com"
	token := strings.Repeat("ATATT3xFfGF0aB9zQ7wE2rT5yU8iO1pL", 6)
	c := &JiraClient{Email: email, Token: token}
	forms := literalsOf(c.scrubForms())

	body := strings.Repeat(email+" filler text ", 30)
	for cap := 0; cap < 400; cap++ {
		cut := scrubCutPoint(body, cap, forms)
		if cut < 0 || cut > len(body) {
			t.Fatalf("cap=%d: cut=%d out of range [0,%d]", cap, cut, len(body))
		}
		if cut < len(body) && !utf8.RuneStart(body[cut]) {
			t.Fatalf("cap=%d: cut=%d splits a rune", cap, cut)
		}
	}
}

// TestJiraSearchHandles400WithDegenerateEmptyClient pins the
// self-attack's degenerate-empty-client case end to end: an empty
// Email/Token must not corrupt an unrelated diagnostic body (see
// TestJiraScrubSkipsDegeneratePairForms for the scrubSecrets-level pin;
// this exercises the same case through the full search() pipeline).
func TestJiraSearchHandles400WithDegenerateEmptyClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("some ordinary diagnostic text with no credential in it"))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "", Token: ""}
	_, err := c.MyIssues(context.Background(), "RAF")
	if err == nil {
		t.Fatal("expected an error from the 400 response")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "ordinary diagnostic text") {
		t.Fatalf("degenerate empty client corrupted an unrelated diagnostic body: %q", msg)
	}
}

// jiraOperatorToken is a stand-in for an Atlassian API token at realistic
// scale — 192 characters, the length Atlassian's own tokens run to.
// Standing lesson 4: an 11-character token once hid a leak that a real
// one exposed instantly, because short strings hide off-by-one truncation
// and because a display cap that a short token fits under never fires.
const jiraOperatorToken = "ATATT3xFAKE0T1yQq7Zk2Wm9Bv4Nc6Xs8Ld0Ph3Rj5Tg7Yu1Ie3Oa5Sd7Fg9Hj1Kl3Zx5Cv7Bn9Mq1Wr3Ey5Ti7Uo9Ip1As3Df5Gh7Jk9Lz1Xc3Vb5Nm7Qw9Er1Ty3Ui5Op7As9Df1Gh3Jk5Lz7Xc9Vb1Nm3Qw5Er7Ty9Ui1Op3"

// TestNormalizeJiraBaseNeverEchoesACredential is the direct, function-level
// half of the fix for the leak Redacted() left open.
//
// url.URL.Redacted() masks a userinfo PASSWORD and nothing else, so three
// of the four ways an operator can paste an API token into WAKIL_JIRA_BASE
// survived it verbatim: a bare userinfo USERNAME (no colon — the likeliest
// paste of all, and precisely what the "must not contain credentials"
// message is complaining about), a query string, and a fragment. Those
// messages are UserErrors, and wakilcore.Recall relays a UserError verbatim
// into SourceStatus.Message, a field of a SUCCESSFUL tool result — so each
// of these was a token landing in an LLM transcript.
//
// Every case asserts the EXACT sentence, not merely that the token is
// absent: per standing lesson 3, an absence check alone would stay green if
// the message degraded to "" or lost the origin that tells an operator
// which of several Atlassian sites they misconfigured. The n-gram sweep
// afterwards is the belt-and-braces half, and names the actual harm.
func TestNormalizeJiraBaseNeverEchoesACredential(t *testing.T) {
	tok := jiraOperatorToken
	for _, tc := range []struct {
		name string
		base string
		want string
	}{
		{
			// The headline case: no colon, so Redacted() left it whole.
			name: "bare userinfo username is the token itself",
			base: "https://" + tok + "@acme.atlassian.net",
			want: "WAKIL_JIRA_BASE must not contain credentials — store the Jira token in the Keychain, not the base URL, got https://acme.atlassian.net",
		},
		{
			// The one shape Redacted() did handle. It must still be
			// rejected, and the username half must go too.
			name: "userinfo password",
			base: "https://operator@example.com:" + tok + "@acme.atlassian.net",
			want: "WAKIL_JIRA_BASE must not contain credentials — store the Jira token in the Keychain, not the base URL, got https://acme.atlassian.net",
		},
		{
			name: "query string",
			base: "https://acme.atlassian.net?token=" + tok,
			want: "WAKIL_JIRA_BASE must not contain a query string, got https://acme.atlassian.net",
		},
		{
			name: "fragment",
			base: "https://acme.atlassian.net#token=" + tok,
			want: "WAKIL_JIRA_BASE must not contain a fragment, got https://acme.atlassian.net",
		},
		{
			name: "path",
			base: "https://acme.atlassian.net/" + tok,
			want: "WAKIL_JIRA_BASE must not contain a path, got https://acme.atlassian.net",
		},
		{
			// Wrong scheme AND userinfo: this reaches the FIRST branch,
			// which never even looks at u.User, so it has to be safe on
			// its own rather than by falling through to the credentials
			// check. The origin keeps the wrong scheme, which is the
			// thing the operator has to fix.
			name: "non-https with userinfo hits the absolute-URL branch",
			base: "http://" + tok + "@acme.atlassian.net",
			want: "WAKIL_JIRA_BASE must be an absolute https URL, got http://acme.atlassian.net",
		},
		{
			// No scheme at all: url.Parse puts the WHOLE string in
			// u.Path and leaves Host empty, so there is no origin to
			// name and safeBaseHint must add nothing. Echoing u.Path
			// here would hand back the entire paste, token included.
			name: "no scheme leaves no host to name",
			base: tok + "@acme.atlassian.net",
			want: "WAKIL_JIRA_BASE must be an absolute https URL",
		},
		{
			// Same, via u.Opaque rather than u.Path.
			name: "opaque URL leaves no host to name",
			base: "mailto:" + tok + "@acme.atlassian.net",
			want: "WAKIL_JIRA_BASE must be an absolute https URL",
		},
		{
			// Scheme-relative: a host worth naming, but no scheme.
			// "://acme.atlassian.net" would be meaningless.
			name: "scheme-relative names the host alone",
			base: "//" + tok + "@acme.atlassian.net/x",
			want: "WAKIL_JIRA_BASE must be an absolute https URL, got acme.atlassian.net",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := normalizeJiraBase(tc.base, "WAKIL_JIRA_BASE")
			if err == nil {
				t.Fatalf("normalizeJiraBase(%q) = %q, want a rejection", tc.base, got)
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected a UserError, got %T: %v", err, err)
			}
			if msg != tc.want {
				t.Fatalf("message = %q, want %q", msg, tc.want)
			}
			// No verbatim run of the token may survive anywhere in the
			// sentence. The 8-byte floor mirrors
			// TestRecallDoesNotLeakACredentialFromAFailingJira: shorter
			// runs occur by chance in ordinary prose.
			for n := len(tok); n >= 8; n-- {
				for i := 0; i+n <= len(tok); i++ {
					if strings.Contains(msg, tok[i:i+n]) {
						t.Fatalf("%d-byte token fragment %q leaked into the rejection message: %q", n, tok[i:i+n], msg)
					}
				}
			}
		})
	}
}

// TestSafeBaseHintDropsEveryCredentialCarrier is the measurement
// safeBaseHint's doc comment cites, run as a test so the comment cannot
// go stale silently — this repo treats an inaccurate comment as a hard
// failure, and "Redacted() masks only a password" is a claim about the
// standard library, not about this code.
//
// The Redacted() assertions are deliberately two-sided: if a future Go
// release starts masking a bare userinfo username, a query or a fragment,
// this test goes RED. That is the correct outcome. Do not repair it by
// deleting the assertion — update safeBaseHint's doc comment to say what
// the library now does, and keep the drop-everything behaviour anyway,
// since dropping is what these messages actually want.
func TestSafeBaseHintDropsEveryCredentialCarrier(t *testing.T) {
	tok := jiraOperatorToken
	for _, tc := range []struct {
		name          string
		base          string
		redactedLeaks bool
	}{
		{"bare userinfo username", "https://" + tok + "@acme.atlassian.net", true},
		{"userinfo password", "https://user:" + tok + "@acme.atlassian.net", false},
		{"query string", "https://acme.atlassian.net?t=" + tok, true},
		{"fragment", "https://acme.atlassian.net#t=" + tok, true},
		{"path", "https://acme.atlassian.net/" + tok, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			u, err := url.Parse(tc.base)
			if err != nil {
				t.Fatalf("url.Parse(%q): %v", tc.base, err)
			}
			if leaks := strings.Contains(u.Redacted(), tok); leaks != tc.redactedLeaks {
				t.Fatalf("url.URL.Redacted() leak of %q = %v, want %v (got %q) — safeBaseHint's doc comment cites this measurement and is now stale",
					tc.name, leaks, tc.redactedLeaks, u.Redacted())
			}
			if hint := safeBaseHint(u); strings.Contains(hint, tok) {
				t.Fatalf("safeBaseHint leaked the token: %q", hint)
			}
			if want := ", got https://acme.atlassian.net"; safeBaseHint(u) != want {
				t.Fatalf("safeBaseHint = %q, want %q", safeBaseHint(u), want)
			}
		})
	}
}

// --- Fix round: the display pipeline's partial-credential ordering. ---

// TestStripPartialCredentialTailOrdering is the isolated proof for the
// three-step order in stripPartialCredentialTail. Both cases below fail
// under a two-step pipeline — in OPPOSITE directions, which is why the
// function has three steps and not two.
func TestStripPartialCredentialTailOrdering(t *testing.T) {
	// Case 1: the bug this fix round closed. The old order (strip then
	// drop) is blocked by the dangling UTF-8 bytes sitting after the
	// credential partial: the suffix test fails, the strip does nothing,
	// and the drop then removes those bytes and re-exposes the partial
	// with nothing left to strip it.
	t.Run("dangling rune after a credential partial", func(t *testing.T) {
		c := &JiraClient{Email: "person@example.com", Token: "sup3rsecrettoken000"}
		forms := c.scrubForms()
		const in = "prefix sup3rsecrett\xe4\xb8"

		// The old two-step order, spelled out so this test states the
		// failure it is pinning rather than merely asserting the fix.
		old := dropTrailingIncompleteRune(stripPartialCredentialSuffix(in, forms))
		if !strings.Contains(old, "sup3rsecrett") {
			t.Fatalf("fixture no longer reproduces the old leak (%q); it proves nothing in this shape", old)
		}

		got := stripPartialCredentialTail(in, forms)
		if strings.Contains(got, "sup3rsecrett") {
			t.Fatalf("a 12-byte credential partial survived: %q", got)
		}
		if got != "prefix " {
			t.Fatalf("got %q, want %q", got, "prefix ")
		}
	})

	// Case 2: the MIRROR bug in the naive two-line swap (drop then strip,
	// with no trailing drop). stripPartialCredentialSuffix cuts at a
	// boundary in the FORM, which need not be a rune boundary in s, so it
	// can leave invalid UTF-8 behind — exactly what the trailing drop
	// existed to prevent. Reaching it needs a form whose first byte is a
	// UTF-8 continuation byte, which is why the token here is not ASCII.
	t.Run("strip cutting mid-rune needs the trailing drop", func(t *testing.T) {
		c := &JiraClient{Email: "p@e.com", Token: "\xb8abcdefgh"}
		forms := c.scrubForms()
		const in = "hello \xe4\xb8abcdefgh"

		twoStep := stripPartialCredentialSuffix(dropTrailingIncompleteRune(in), forms)
		if utf8.ValidString(twoStep) {
			t.Fatalf("fixture no longer reproduces the mirror bug (%q); it proves nothing in this shape", twoStep)
		}

		got := stripPartialCredentialTail(in, forms)
		if !utf8.ValidString(got) {
			t.Fatalf("result is not valid UTF-8: %q", got)
		}
		if got != "hello " {
			t.Fatalf("got %q, want %q", got, "hello ")
		}
	})
}

// TestJiraErrorBodyDoesNotLeakPartialTokenBeforeDanglingRune is the
// end-to-end half: the same shape, arriving as a real Jira error body,
// must not put a credential fragment into the UserError.
//
// This is not just a diagnostic string. recall.go's sourceFailureMessage
// relays a UserError VERBATIM into SourceStatus.Message, a field of a
// SUCCESSFUL wakil-recall tool result whose own description tells the
// model to read it — so a fragment that survives here is handed to an
// LLM as ordinary output.
//
// The body is deliberately shorter than jiraErrorBodyCap: that is the
// case where nothing else in the pipeline cuts the string, so the
// trailing partial reaches the final stage untouched. A mid-stream
// connection drop (search()'s io.ReadAll error path) produces the same
// shape against a body of any size.
func TestJiraErrorBodyDoesNotLeakPartialTokenBeforeDanglingRune(t *testing.T) {
	token := strings.Repeat("aB3", 64) // 192 chars, a realistic API token
	body := "Jira rejected token " + token[:12] + "\xe4\xb8"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(body))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "person@example.com", Token: token}
	_, err := c.SearchIssues(context.Background(), "RAF", "")
	if err == nil {
		t.Fatal("expected an error on 400")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if leak := longestVerbatimLeak(msg, token); leak != 0 {
		t.Fatalf("a %d-byte fragment of the token survived in %q", leak, msg)
	}
	if !utf8.ValidString(msg) {
		t.Fatalf("message is not valid UTF-8: %q", msg)
	}
	if msg != "Jira error 400: Jira rejected token " {
		t.Fatalf("got %q, want the body with the partial and the dangling rune removed", msg)
	}
}

// TestJiraBaseComesFromOrgRecord pins the new source of truth: the Jira
// base URL comes from the current org's org.json, not from an env var
// baked into each provider's registration. If NewJiraFromEnv still only
// consulted WAKIL_JIRA_BASE (which this test leaves empty), it would
// fail with "no Jira site configured" instead of returning a client.
func TestJiraBaseComesFromOrgRecord(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_JIRA_BASE", "")
	// NewJiraFromEnv also needs Jira credentials to build a complete
	// client; fakeJiraSecurityBinary keeps SecretGet off the real login
	// keychain (see the standing constraint against touching it in
	// tests) — without this, PATH would resolve to the real `security`
	// binary and this test would depend on, and potentially probe, the
	// machine's actual Keychain.
	fakeJiraSecurityBinary(t, "person@example.com:tok123", 0)
	if err := CreateOrg("initech", Org{JiraBase: "https://from-org.atlassian.net"}); err != nil {
		t.Fatal(err)
	}
	c, err := NewJiraFromEnv()
	if err != nil {
		t.Fatalf("NewJiraFromEnv() error = %v", err)
	}
	if c.BaseURL != "https://from-org.atlassian.net" {
		t.Errorf("BaseURL = %q; want the value from org.json", c.BaseURL)
	}
}

// TestJiraBaseEnvOverridesOrgRecord pins the precedence: WAKIL_JIRA_BASE
// wins over org.json when both are set. This is the escape hatch for
// when org.json is wrong and a Jira call is needed to diagnose it — see
// NewJiraFromEnv's doc comment. This is the mutation-tested case: a
// build that swapped the precedence (org.json checked first, env only
// as fallback) would return the org.json value here instead of the
// override and fail.
func TestJiraBaseEnvOverridesOrgRecord(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_JIRA_BASE", "https://override.atlassian.net")
	// See TestJiraBaseComesFromOrgRecord: keeps SecretGet off the real
	// login keychain.
	fakeJiraSecurityBinary(t, "person@example.com:tok123", 0)
	if err := CreateOrg("initech", Org{JiraBase: "https://from-org.atlassian.net"}); err != nil {
		t.Fatal(err)
	}
	c, err := NewJiraFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if c.BaseURL != "https://override.atlassian.net" {
		t.Errorf("BaseURL = %q; want the environment override", c.BaseURL)
	}
}

// TestJiraUnsetBaseNamesTheOrgAndTheFix pins that the "no Jira site
// configured" error is actionable: it must name the specific org (so a
// multi-org operator knows which one is broken) and the exact command
// that fixes it. If NewJiraFromEnv still returned the old
// "configure WAKIL_JIRA_BASE for this org" message, or any message
// missing the org id or the fix, this test fails.
func TestJiraUnsetBaseNamesTheOrgAndTheFix(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_JIRA_BASE", "")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("NewJiraFromEnv succeeded with no Jira site configured")
	}
	if !strings.Contains(err.Error(), "initech") || !strings.Contains(err.Error(), "--jira-base") {
		t.Errorf("the error must name the org and the command that fixes it; got %q", err)
	}
}
