package wakilcore

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// failingSearch is a jiraSearchFn that always fails with err and records
// that it ran. Tests that assert a source was NEVER consulted use the
// called flag as a canary: without it, "no group was emitted" would pass
// just as well when the search ran and returned nothing.
func failingSearch(err error, called *bool) jiraSearchFn {
	return func(_ context.Context, _, _ string) (IssuePage, error) {
		if called != nil {
			*called = true
		}
		return IssuePage{}, err
	}
}

// okSearch is a jiraSearchFn that returns page and records the jql it was
// handed, so a test can assert on the query actually built.
func okSearch(page IssuePage, gotJQL *string) jiraSearchFn {
	return func(_ context.Context, _, jql string) (IssuePage, error) {
		if gotJQL != nil {
			*gotJQL = jql
		}
		return page, nil
	}
}

// wantRecallUserError fails t unless err is a UserError whose message is
// exactly want. Exact equality, not Contains: these are the messages a
// caller reads instead of a Jira syntax error, and an assertion that only
// checked for a substring would stay green if the sentence degraded into
// something unactionable around it.
func wantRecallUserError(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected UserError %q, got nil", want)
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
	if msg != want {
		t.Fatalf("error message = %q, want %q", msg, want)
	}
}

func TestGroupIssuesToResults(t *testing.T) {
	issues := []Issue{{Key: "RAF-1", Summary: "Date picker bug", Status: "Open", URL: "http://j/RAF-1"}}
	out := issuesToResults(issues)
	if len(out) != 1 {
		t.Fatalf("len = %d, want 1: %+v", len(out), out)
	}
	got := out[0]
	want := RecallResult{Source: "jira", Title: "RAF-1: Date picker bug", Snippet: "Open", Link: "http://j/RAF-1"}
	if got != want {
		t.Fatalf("mapping = %+v, want %+v", got, want)
	}
}

// TestIssuesToResultsAlwaysReturnsNonNil pins the chosen invariant:
// issuesToResults returns an EMPTY, NON-NIL slice for nil and for an
// empty input, never a nil slice. That is what makes a group of a source
// that answered with nothing marshal as `[]` rather than `null` — see
// TestRecallOutputEmptyGroupMarshalsAsArray, which pins the wire form
// this invariant exists to produce.
func TestIssuesToResultsAlwaysReturnsNonNil(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   []Issue
	}{
		{"nil", nil},
		{"empty", []Issue{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			out := issuesToResults(tc.in)
			if out == nil {
				t.Fatal("issuesToResults returned a nil slice; it must return an empty non-nil slice so the wire carries [] and not null")
			}
			if len(out) != 0 {
				t.Fatalf("len = %d, want 0: %+v", len(out), out)
			}
		})
	}
}

// TestIssuesToResultsPreservesOrder pins that the projection does not
// reorder: recall does no ranking of its own (spec §4.5, "no unified
// ranking"), so whatever order the source returned must survive.
func TestIssuesToResultsPreservesOrder(t *testing.T) {
	issues := []Issue{
		{Key: "RAF-3", Summary: "third", Status: "Done", URL: "http://j/RAF-3"},
		{Key: "RAF-1", Summary: "first", Status: "Open", URL: "http://j/RAF-1"},
		{Key: "RAF-2", Summary: "second", Status: "In Progress", URL: "http://j/RAF-2"},
	}
	out := issuesToResults(issues)
	if len(out) != 3 {
		t.Fatalf("len = %d, want 3: %+v", len(out), out)
	}
	wantTitles := []string{"RAF-3: third", "RAF-1: first", "RAF-2: second"}
	for i, want := range wantTitles {
		if out[i].Title != want {
			t.Fatalf("out[%d].Title = %q, want %q (order not preserved: %+v)", i, out[i].Title, want, out)
		}
	}
}

// TestRecallRejectsEmptyQuery pins that an empty or whitespace-only query
// is a WHOLE-CALL error, and that no source is consulted at all: sending
// `text ~ ""` to Jira asks it to match on nothing, and doing so would
// also spend a Keychain read and a network round trip on a call the
// caller never meant to make.
func TestRecallRejectsEmptyQuery(t *testing.T) {
	const want = "recall needs something to search for"
	for _, q := range []string{"", " ", "\t\n  ", "\u00a0"} {
		t.Run(strings.ReplaceAll(q, "\n", "\\n"), func(t *testing.T) {
			called := false
			out, err := fanOut(context.Background(), q, "RAF", failingSearch(errors.New("must not be called"), &called))
			wantRecallUserError(t, err, want)
			if called {
				t.Fatal("the Jira source was consulted despite an empty query")
			}
			if out.Groups != nil || out.Sources != nil {
				t.Fatalf("a whole-call error must return the zero RecallOutput, got %+v", out)
			}
		})
	}
}

// TestRecallRejectsUnquotableQuery pins every rejection jiraJQL's safety
// argument depends on. Each case asserts the SPECIFIC sentence the guard
// produces — an assertion that merely checked "an error happened", or
// that the payload did not appear in some output, would pass just as
// well if the guard were deleted and the query failed one layer down in
// validateBalancedJQL with a message about JQL that the caller cannot
// act on (or, for a quote, did not fail at all).
//
// The "double quote closing the JQL string" case is the reason the quote
// rejection is a security control and not a nicety. Deleting the guard
// was tried: that payload builds
// `text ~ "x" OR project = SECRET AND text ~ "y"`, which has balanced
// quotes and no parentheses and so passes validateBalancedJQL untouched,
// and SearchIssues' wrapper then reads as
// `(project = RAF AND text ~ "x") OR (project = SECRET AND text ~ "y")`
// because JQL's AND binds tighter than its OR. Only filterToProject's
// response-side filter still contains it at that point. Rejecting the
// quote here is what stops the request being sent at all.
func TestRecallRejectsUnquotableQuery(t *testing.T) {
	const (
		wantQuote   = `recall query must not contain a quote character (" or ') — search for the same words without quotes`
		wantSlash   = "recall query must not contain a backslash — search for the same words without it"
		wantControl = "recall query must not contain control characters — search for the same words as plain text"
	)
	cases := []struct {
		name  string
		query string
		want  string
	}{
		{"double quote", `say "hello"`, wantQuote},
		{"double quote closing the JQL string", `x" OR project = SECRET AND text ~ "y`, wantQuote},
		{"single quote", "it's broken", wantQuote},
		{"backslash", `C:\Users`, wantSlash},
		{"backslash escaping a quote", `x\" OR 1=1`, wantQuote},
		{"interior newline", "line one\nline two", wantControl},
		{"interior tab", "a\tb", wantControl},
		{"NUL byte", "a\x00b", wantControl},
		// The three cases below pin the SCAN BOUNDARIES of
		// validateRecallQuery's control-character loop, each of which
		// survived as a mutant while every case above stayed green.
		//
		// Every earlier case puts its control character strictly
		// INSIDE the string, so narrowing the loop to skip either end
		// (`i := 1`, or `i < len(q)-1`) changed nothing, and neither
		// did tightening the threshold from `< 0x20` to `< 0x1f`.
		// FuzzRecallQueryCannotEscapeJQL cannot reach them either: its
		// property is that an accepted query stays inert inside the
		// JQL string, and a leaked NUL or U+001F disturbs neither the
		// quote balance nor validateBalancedJQL, so a query that
		// wrongly got through would still satisfy the fuzz property.
		//
		// NUL is the right character for the position cases
		// specifically because strings.TrimSpace does not strip it:
		// unicode.IsSpace(0) is false, so "\x00abc" trims to itself
		// and the control character really does land at index 0 of the
		// string the loop scans. A leading "\n" would be trimmed away
		// and prove nothing.
		{"leading NUL, first byte scanned", "\x00date picker", wantControl},
		{"trailing NUL, last byte scanned", "date picker\x00", wantControl},
		{"U+001F, the boundary of the < 0x20 threshold", "date\x1fpicker", wantControl},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			called := false
			_, err := fanOut(context.Background(), tc.query, "RAF", failingSearch(errors.New("must not be called"), &called))
			wantRecallUserError(t, err, tc.want)
			if called {
				t.Fatalf("the Jira source was consulted despite an unusable query %q", tc.query)
			}
		})
	}
}

// TestRecallAcceptsAwkwardButSafeQuery is the other half of the
// rejection tests: a query containing characters that LOOK dangerous in
// JQL — parentheses, a colon, a tilde, non-ASCII text — must be accepted
// and passed through untouched, and the JQL it produces must still
// satisfy validateBalancedJQL, the layer below. Without this, tightening
// the rejection into "reject everything" would leave the suite green.
func TestRecallAcceptsAwkwardButSafeQuery(t *testing.T) {
	for _, q := range []string{
		"date picker (mobile)",
		"error: timeout ~ 30s",
		"réservation annulée",
		"a) OR (b",
	} {
		t.Run(q, func(t *testing.T) {
			var gotJQL string
			out, err := fanOut(context.Background(), q, "RAF", okSearch(IssuePage{}, &gotJQL))
			if err != nil {
				t.Fatalf("query %q was rejected: %v", q, err)
			}
			if want := `text ~ "` + q + `"`; gotJQL != want {
				t.Fatalf("jql = %q, want %q", gotJQL, want)
			}
			// The layer below must accept what this layer built; that
			// is the composition jiraJQL's doc comment claims.
			if err := validateBalancedJQL(gotJQL); err != nil {
				t.Fatalf("validateBalancedJQL rejected the JQL recall built for %q: %v", q, err)
			}
			if len(out.Sources) != 1 || !out.Sources[0].OK {
				t.Fatalf("sources = %+v, want one OK entry", out.Sources)
			}
		})
	}
}

// TestRecallTrimsQueryBeforeSearching pins that the text sent to Jira is
// the trimmed query, not the raw one — the same string validateRecallQuery
// checked. If the two ever diverged, a character rejected by the
// validator could still reach the JQL.
func TestRecallTrimsQueryBeforeSearching(t *testing.T) {
	var gotJQL string
	if _, err := fanOut(context.Background(), "  date picker \n", "RAF", okSearch(IssuePage{}, &gotJQL)); err != nil {
		t.Fatal(err)
	}
	if want := `text ~ "date picker"`; gotJQL != want {
		t.Fatalf("jql = %q, want %q", gotJQL, want)
	}
}

// TestRecallFailedSourceIsVisibleNotSilent is the central rule of this
// package (see RecallOutput's doc comment): a bound source that fails
// must contribute a group AND an OK=false status carrying the source's
// own diagnostic. A caller must never be able to read a broken Jira as
// "Jira has no matching issues".
func TestRecallFailedSourceIsVisibleNotSilent(t *testing.T) {
	const want = "Jira base URL not set — configure WAKIL_JIRA_BASE for this org"
	out, err := fanOut(context.Background(), "date picker", "RAF", failingSearch(UserError(want), nil))
	if err != nil {
		t.Fatalf("a failing source must not fail the whole call: %v", err)
	}

	group, ok := out.Groups["jira"]
	if !ok {
		t.Fatalf("no \"jira\" group for a bound-but-failing source; a missing group is indistinguishable from an unbound source: %+v", out)
	}
	if group == nil {
		t.Fatal("the \"jira\" group is nil; a failing source must contribute an empty NON-NIL slice so the wire carries []")
	}
	if len(group) != 0 {
		t.Fatalf("the \"jira\" group has %d results, want 0: %+v", len(group), group)
	}

	if len(out.Sources) != 1 {
		t.Fatalf("sources = %+v, want exactly one entry", out.Sources)
	}
	got := out.Sources[0]
	if got.Source != "jira" || got.OK {
		t.Fatalf("sources[0] = %+v, want source \"jira\" with OK=false", got)
	}
	if got.Message != want {
		t.Fatalf("sources[0].Message = %q, want the source's own diagnostic %q", got.Message, want)
	}
}

// TestRecallDoesNotRelayNonUserError pins ruling 3's fail-closed rule: a
// non-UserError has not been through jira.go's credential-scrubbing
// pipeline, and this Message lands in an LLM transcript as part of a
// SUCCESSFUL result, so only the fixed sentence may appear.
//
// The assertion is on the exact replacement sentence, not merely on the
// secret's absence: per standing lesson 3, `!Contains(got, secret)` would
// pass just as well on an empty Message, or if the whole SourceStatus
// were dropped.
func TestRecallDoesNotRelayNonUserError(t *testing.T) {
	const secret = "person@example.com:sup3rsecrettoken"
	raw := errors.New("Post \"https://jira.example.com/rest/api/3/search/jql\": echoed credential " + secret)

	out, err := fanOut(context.Background(), "date picker", "RAF", failingSearch(raw, nil))
	if err != nil {
		t.Fatalf("a failing source must not fail the whole call: %v", err)
	}
	if len(out.Sources) != 1 {
		t.Fatalf("sources = %+v, want exactly one entry", out.Sources)
	}
	if got, want := out.Sources[0].Message, "jira: request failed"; got != want {
		t.Fatalf("sources[0].Message = %q, want the fixed sentence %q — a non-UserError must never be relayed verbatim", got, want)
	}
	// Belt and braces: with the exact-equality assertion above already
	// passing, this can only fail if "jira: request failed" itself ever
	// grows the payload, but it names the actual harm being prevented.
	if strings.Contains(out.Sources[0].Message, secret) {
		t.Fatalf("credential-shaped text leaked into a source message: %q", out.Sources[0].Message)
	}
}

// TestRecallUnboundSourceEmitsNothing pins the "not bound" vs "bound but
// broken" distinction: a project with no Jira project key configured
// emits no group and no status, and never consults the source — which is
// also what keeps an unbound project from reaching NewJiraFromEnv and
// therefore the real login Keychain.
func TestRecallUnboundSourceEmitsNothing(t *testing.T) {
	called := false
	out, err := fanOut(context.Background(), "date picker", "", failingSearch(errors.New("must not be called"), &called))
	if err != nil {
		t.Fatal(err)
	}
	if called {
		t.Fatal("the Jira source was consulted for a project with no Jira scope")
	}
	if _, ok := out.Groups["jira"]; ok {
		t.Fatalf("an unbound source must contribute no group at all, got %+v", out.Groups)
	}
	if len(out.Sources) != 0 {
		t.Fatalf("an unbound source must contribute no status at all, got %+v", out.Sources)
	}
	// Non-nil even with nothing bound, so the wire carries {} and [].
	if out.Groups == nil || out.Sources == nil {
		t.Fatalf("Groups/Sources must be non-nil even when nothing is bound: %#v", out)
	}
}

// TestRecallPropagatesTruncated pins ruling 6. IssuePage.Truncated is
// jira.go's answer to "was this page the whole answer?" — including the
// case where Jira gave no way to confirm completeness at all — and
// dropping it here would let a partial answer be read as a complete one,
// exactly the failure IssuePage's doc comment exists to prevent.
func TestRecallPropagatesTruncated(t *testing.T) {
	for _, truncated := range []bool{true, false} {
		name := "complete"
		if truncated {
			name = "truncated"
		}
		t.Run(name, func(t *testing.T) {
			page := IssuePage{
				Issues:    []Issue{{Key: "RAF-1", Summary: "Fix", Status: "Open", URL: "http://j/RAF-1"}},
				Truncated: truncated,
			}
			out, err := fanOut(context.Background(), "fix", "RAF", okSearch(page, nil))
			if err != nil {
				t.Fatal(err)
			}
			if len(out.Sources) != 1 {
				t.Fatalf("sources = %+v, want exactly one entry", out.Sources)
			}
			if !out.Sources[0].OK {
				t.Fatalf("sources[0] = %+v, want OK=true", out.Sources[0])
			}
			if out.Sources[0].Truncated != truncated {
				t.Fatalf("sources[0].Truncated = %v, want %v (IssuePage.Truncated was %v)", out.Sources[0].Truncated, truncated, truncated)
			}
		})
	}
}

// TestRecallSucceedingSourceCarriesResults is the happy path end to end
// through fanOut: results grouped under the source's own name, and an
// OK=true status beside them.
func TestRecallSucceedingSourceCarriesResults(t *testing.T) {
	page := IssuePage{Issues: []Issue{
		{Key: "RAF-1", Summary: "Date picker bug", Status: "Open", URL: "http://j/RAF-1"},
		{Key: "RAF-9", Summary: "Date picker polish", Status: "Done", URL: "http://j/RAF-9"},
	}}
	out, err := fanOut(context.Background(), "date picker", "RAF", okSearch(page, nil))
	if err != nil {
		t.Fatal(err)
	}
	group := out.Groups["jira"]
	if len(group) != 2 {
		t.Fatalf("groups[\"jira\"] = %+v, want 2 results", group)
	}
	if group[0].Link != "http://j/RAF-1" || group[1].Link != "http://j/RAF-9" {
		t.Fatalf("results are not cited in source order: %+v", group)
	}
	if len(out.Sources) != 1 || !out.Sources[0].OK || out.Sources[0].Message != "" {
		t.Fatalf("sources = %+v, want one OK entry with no message", out.Sources)
	}
}

// TestRecallOutputEmptyGroupMarshalsAsArray pins the wire form, not just
// the Go value: `[]` and `{}`, never `null`. This is the observable an
// MCP client actually sees, and it is the difference between "Jira
// answered with nothing" and a field a schema-strict client rejects.
func TestRecallOutputEmptyGroupMarshalsAsArray(t *testing.T) {
	out, err := fanOut(context.Background(), "date picker", "RAF", failingSearch(UserError("Jira unreachable"), nil))
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("marshal RecallOutput: %v", err)
	}
	got := string(b)
	if !strings.Contains(got, `"groups":{"jira":[]}`) {
		t.Fatalf("marshaled output = %s, want groups.jira to be [] (an empty array, not null or absent)", got)
	}

	empty, err := fanOut(context.Background(), "date picker", "", okSearch(IssuePage{}, nil))
	if err != nil {
		t.Fatal(err)
	}
	b, err = json.Marshal(empty)
	if err != nil {
		t.Fatalf("marshal RecallOutput: %v", err)
	}
	if want := `{"groups":{},"sources":[]}`; string(b) != want {
		t.Fatalf("marshaled output with nothing bound = %s, want %s", b, want)
	}
}

// TestRecallSendsUnorderedScopedJQL runs fanOut against a real
// JiraClient pointed at an httptest server and asserts the EXACT JQL
// that reaches the wire, composed with SearchIssues' own scoping.
//
// The absence of "ORDER BY updated DESC" is the point (see jiraJQL's doc
// comment): SearchIssues wraps the fragment in parentheses, and JQL's
// ORDER BY is a top-level clause that cannot appear inside a
// parenthesised sub-clause, so adding one back — as both the plan and
// the task brief specified — would turn every recall call into a Jira
// 400. This test cannot prove that claim against a live Jira; it pins
// the string so the claim and the code cannot drift apart silently.
func TestRecallSendsUnorderedScopedJQL(t *testing.T) {
	const wantJQL = `project = RAF AND (text ~ "date picker")`
	srv := newJiraTestServer(t, func(t *testing.T, b jiraSearchBody) {
		if b.JQL != wantJQL {
			t.Errorf("jql = %q, want %q", b.JQL, wantJQL)
		}
	}, `{"issues":[{"key":"RAF-1","fields":{"summary":"Date picker bug","status":{"name":"Open"}}}],"isLast":true}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	out, err := fanOut(context.Background(), "  date picker  ", "RAF", c.SearchIssues)
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Sources) != 1 || !out.Sources[0].OK {
		t.Fatalf("sources = %+v, want one OK entry", out.Sources)
	}
	group := out.Groups["jira"]
	if len(group) != 1 || group[0].Title != "RAF-1: Date picker bug" || group[0].Link != srv.URL+"/browse/RAF-1" {
		t.Fatalf("groups[\"jira\"] = %+v, want the one cited issue the server returned", group)
	}
}

// TestRecallSurfacesJiraErrorBodyThroughSourceStatus proves the two
// halves fit together on the path that matters most in practice: a Jira
// 4xx becomes a scrubbed UserError inside jira.go, and that message
// reaches the caller through SourceStatus.Message rather than being
// swallowed. The 400 here is the shape a malformed text-search query
// would produce, which is the one class of bad query recall deliberately
// does NOT pre-validate (JQL's text-search operand grammar is not
// something this codebase can enumerate correctly) — so it must be
// visible instead.
func TestRecallSurfacesJiraErrorBodyThroughSourceStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"errorMessages":["Error in the JQL Query: expecting operand but got ')'."]}`))
	}))
	defer srv.Close()
	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}

	out, err := fanOut(context.Background(), "date picker", "RAF", c.SearchIssues)
	if err != nil {
		t.Fatalf("a failing source must not fail the whole call: %v", err)
	}
	if len(out.Sources) != 1 || out.Sources[0].OK {
		t.Fatalf("sources = %+v, want one failed entry", out.Sources)
	}
	got := out.Sources[0].Message
	if !strings.Contains(got, "Jira error 400") || !strings.Contains(got, "expecting operand") {
		t.Fatalf("sources[0].Message = %q, want jira.go's own scrubbed \"Jira error 400: <body>\" diagnostic", got)
	}
	if group, ok := out.Groups["jira"]; !ok || group == nil || len(group) != 0 {
		t.Fatalf("groups[\"jira\"] = %+v (present=%v), want an empty non-nil slice", group, ok)
	}
}

// TestRecallEmptySuccessfulGroupIsPresentAndEmpty pins the case this
// whole type exists for, and the one case no other test covered: Jira
// ANSWERED, and nothing matched.
//
// Every other "empty but present group" assertion in this file is on the
// failure path (TestRecallFailedSourceIsVisibleNotSilent,
// TestRecallOutputEmptyGroupMarshalsAsArray) or the unbound path
// (TestRecallUnboundSourceEmitsNothing), all of which reach a DIFFERENT
// line: `out.Groups[sourceJira] = []RecallResult{}` in the error branch,
// not `= issuesToResults(page.Issues)` in the success branch. Guarding
// the success assignment with `if len(page.Issues) > 0` therefore left
// the entire suite green, while turning a genuine zero-match into an
// absent group — indistinguishable on the wire from a source that was
// never bound at all, which is exactly the confusion RecallOutput's doc
// comment exists to prevent.
//
// The assertion is on the EXACT marshaled bytes rather than on the Go
// value: the wire form is what an MCP client sees, and `{}`/`[]`/absent
// are three different answers there that a Go-value check can blur.
func TestRecallEmptySuccessfulGroupIsPresentAndEmpty(t *testing.T) {
	out, err := fanOut(context.Background(), "date picker", "RAF", okSearch(IssuePage{}, nil))
	if err != nil {
		t.Fatal(err)
	}
	group, ok := out.Groups["jira"]
	if !ok {
		t.Fatalf("no \"jira\" group after a SUCCESSFUL search that matched nothing; an absent group is indistinguishable from an unbound source: %+v", out)
	}
	if group == nil {
		t.Fatal("the \"jira\" group is nil; a source that answered with nothing must contribute an empty NON-NIL slice so the wire carries []")
	}
	if len(group) != 0 {
		t.Fatalf("the \"jira\" group has %d results, want 0: %+v", len(group), group)
	}
	b, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("marshal RecallOutput: %v", err)
	}
	if want := `{"groups":{"jira":[]},"sources":[{"source":"jira","ok":true}]}`; string(b) != want {
		t.Fatalf("marshaled output = %s, want %s", b, want)
	}
}

// TestRecallSuccessJoinsGroupsAndSourcesByName pins sourceJira's stated
// invariant on the SUCCESS path: the name in SourceStatus.Source is the
// SAME string as the Groups key, so a caller can join the two by name.
//
// Only the Groups half of that was guarded. Changing the success
// branch's `Source: sourceJira` to a desynchronized literal such as
// "JIRA" left the suite green — every existing success test reads
// out.Groups["jira"] and out.Sources[0] independently and never checks
// that one names the other — while producing a result in which the
// status line and the results it describes can no longer be associated.
// The failure branch's half of the same desync IS caught, by
// TestRecallFailedSourceIsVisibleNotSilent's explicit Source check.
//
// The assertion is written as a set join rather than as
// `out.Sources[0].Source == "jira"` on purpose: the invariant is about
// the two collections agreeing, and it must keep holding when a second
// fan-out target is added.
func TestRecallSuccessJoinsGroupsAndSourcesByName(t *testing.T) {
	page := IssuePage{Issues: []Issue{{Key: "RAF-1", Summary: "Date picker bug", Status: "Open", URL: "http://j/RAF-1"}}}
	out, err := fanOut(context.Background(), "date picker", "RAF", okSearch(page, nil))
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Sources) != 1 {
		t.Fatalf("sources = %+v, want exactly one entry", out.Sources)
	}
	if !out.Sources[0].OK {
		t.Fatalf("sources[0] = %+v, want OK=true; this test must exercise the SUCCESS branch", out.Sources[0])
	}
	// Every status names a group...
	for _, s := range out.Sources {
		if _, ok := out.Groups[s.Source]; !ok {
			t.Fatalf("sources entry %+v names %q, which is not a key of groups %v — the two can no longer be joined by name", s, s.Source, out.Groups)
		}
	}
	// ...and every group is named by a status.
	named := map[string]bool{}
	for _, s := range out.Sources {
		named[s.Source] = true
	}
	for name := range out.Groups {
		if !named[name] {
			t.Fatalf("groups has key %q with no matching sources entry %+v — the two can no longer be joined by name", name, out.Sources)
		}
	}
	// And the results inside the group carry the same name again, which
	// is what lets a flattened or singly-quoted result keep its citation.
	if got := out.Groups[out.Sources[0].Source][0].Source; got != out.Sources[0].Source {
		t.Fatalf("result.Source = %q, sources[0].Source = %q; all three names must be the same string", got, out.Sources[0].Source)
	}
}

// TestRecallSurfacesFilteredAfterAProjectKeyRename is the reversal of an
// earlier ruling that IssuePage.Filtered should not be surfaced. That
// ruling rested on Filtered being "0 in all normal operation" and "not
// something a recall caller can act on"; a Jira PROJECT KEY RENAME
// falsifies both, and this test is that event.
//
// Atlassian keeps a renamed project's OLD key working as a JQL alias, so
// the scoped search "project = OLD AND (...)" still MATCHES — but every
// issue comes back keyed NEW-nnn, and filterToProject, which compares the
// literal "OLD-" prefix, drops all of them. The fixture reproduces
// exactly that: the server is asked about OLD and answers with NEW-1 and
// NEW-2.
//
// Without Filtered on SourceStatus the result is
// {"groups":{"jira":[]},"sources":[{"source":"jira","ok":true}]} — BYTE
// IDENTICAL to a genuine zero-match, so an LLM reports "there are no
// matching issues" with full confidence while the operator's real
// problem is a stale projectKey in .wakil/project.json. That is the
// failure RecallOutput's doc comment exists to prevent, arriving through
// a different door than an unconfigured source.
//
// This runs against a real JiraClient rather than a stub jiraSearchFn on
// purpose: the count has to survive the whole chain — search() -> and
// SearchIssues's `page.Issues, page.Filtered = filterToProject(...)` ->
// fanOut — and a stub returning a hand-set Filtered would pin only the
// last link of it.
func TestRecallSurfacesFilteredAfterAProjectKeyRename(t *testing.T) {
	const wantJQL = `project = OLD AND (text ~ "date picker")`
	srv := newJiraTestServer(t, func(t *testing.T, b jiraSearchBody) {
		if b.JQL != wantJQL {
			t.Errorf("jql = %q, want %q — the search must still be scoped to the CONFIGURED (old) key", b.JQL, wantJQL)
		}
	}, `{"issues":[
		{"key":"NEW-1","fields":{"summary":"Date picker bug","status":{"name":"Open"}}},
		{"key":"NEW-2","fields":{"summary":"Date picker polish","status":{"name":"Done"}}}
	],"isLast":true}`)
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	out, err := fanOut(context.Background(), "date picker", "OLD", c.SearchIssues)
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Sources) != 1 {
		t.Fatalf("sources = %+v, want exactly one entry", out.Sources)
	}
	got := out.Sources[0]
	// The source really did answer, and really did answer completely —
	// so neither ok nor truncated carries this signal. Asserting them
	// here is what makes the point: filtered is the ONLY field that can.
	if !got.OK {
		t.Fatalf("sources[0] = %+v, want OK=true — Jira answered; the rename is not a source failure", got)
	}
	if got.Truncated {
		t.Fatalf("sources[0] = %+v, want Truncated=false — the page was complete", got)
	}
	if got.Filtered != 2 {
		t.Fatalf("sources[0].Filtered = %d, want 2 — both NEW-keyed issues were dropped by filterToProject and the caller has no other way to learn that the answer is empty for a reason", got.Filtered)
	}
	if group := out.Groups["jira"]; len(group) != 0 {
		t.Fatalf("groups[\"jira\"] = %+v, want 0 results — filterToProject must still drop every out-of-project key", group)
	}

	// The wire form is the observable that matters: this must NOT be
	// byte-identical to a genuine zero-match.
	b, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("marshal RecallOutput: %v", err)
	}
	if want := `{"groups":{"jira":[]},"sources":[{"source":"jira","ok":true,"filtered":2}]}`; string(b) != want {
		t.Fatalf("marshaled output = %s, want %s", b, want)
	}

	empty, err := fanOut(context.Background(), "date picker", "RAF", okSearch(IssuePage{}, nil))
	if err != nil {
		t.Fatal(err)
	}
	eb, err := json.Marshal(empty)
	if err != nil {
		t.Fatalf("marshal RecallOutput: %v", err)
	}
	if string(b) == string(eb) {
		t.Fatalf("a stale project key is indistinguishable from a genuine zero-match on the wire: both marshal to %s", b)
	}
}
