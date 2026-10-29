package wakilcore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// fakeGraphQL is an httptest GitHub GraphQL endpoint: answer picks the reply per request and
// every request's query and variables are kept for the test to read.
type fakeGraphQL struct {
	mu       sync.Mutex
	requests []gqlRequest
	auth     []string
}

type gqlRequest struct {
	Query     string         `json:"query"`
	Variables map[string]any `json:"variables"`
}

func (f *fakeGraphQL) serve(t *testing.T, answer func(r gqlRequest) (int, string)) *GitHubClient {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req gqlRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("request body: %v", err)
		}
		f.mu.Lock()
		f.requests = append(f.requests, req)
		f.auth = append(f.auth, r.Header.Get("Authorization"))
		f.mu.Unlock()
		code, body := answer(req)
		w.WriteHeader(code)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	return &GitHubClient{Endpoint: srv.URL, Token: "ghp_initechFAKEtoken0123456789"}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func checkRun(name, status, conclusion, url string) map[string]any {
	return map[string]any{"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion, "detailsUrl": url}
}

func threadNode(id string, n int) map[string]any {
	return map[string]any{
		"id": id, "path": "api/handler.go", "line": n, "isOutdated": false, "isResolved": false,
		"comments": map[string]any{"nodes": []any{map[string]any{"author": map[string]any{"login": "milton"}, "body": "c", "createdAt": "2026-10-20T10:00:00Z"}}},
	}
}

func prNode(number int, head, base string, threads []any, threadsMore bool, contexts []any, contextsMore bool) map[string]any {
	return map[string]any{
		"id": fmt.Sprintf("PR_%d", number), "number": number, "title": "INI-142 add the TPS cover sheet",
		"body": "Ticket: INI-142", "url": fmt.Sprintf("https://github.com/initech/api/pull/%d", number),
		"state": "OPEN", "mergeStateStatus": "BLOCKED", "isCrossRepository": false,
		"headRefName": head, "baseRefName": base, "headRefOid": "abc123", "author": map[string]any{"login": "peter"},
		"reviewRequests": map[string]any{"nodes": []any{
			map[string]any{"requestedReviewer": map[string]any{"login": "bill"}},
			map[string]any{"requestedReviewer": map[string]any{"name": "platform"}},
		}},
		"commits": map[string]any{"nodes": []any{map[string]any{"commit": map[string]any{"statusCheckRollup": map[string]any{
			"id": fmt.Sprintf("SCR_%d", number),
			"contexts": map[string]any{
				"pageInfo": map[string]any{"hasNextPage": contextsMore, "endCursor": "ctx1"},
				"nodes":    contexts,
			},
		}}}}},
		"reviewThreads": map[string]any{
			"pageInfo": map[string]any{"hasNextPage": threadsMore, "endCursor": "thr1"},
			"nodes":    threads,
		},
	}
}

func TestBranchPRsDecodesThreadsAndChecks(t *testing.T) {
	var contexts []any
	for i := 0; i < 7; i++ {
		contexts = append(contexts, checkRun(fmt.Sprintf("lint-%d", i), "COMPLETED", "SUCCESS", ""))
	}
	contexts = append(contexts, checkRun("unit", "COMPLETED", "FAILURE", "https://github.com/initech/api/actions/runs/9"))
	contexts = append(contexts, map[string]any{"__typename": "StatusContext", "context": "deploy/preview", "state": "PENDING", "targetUrl": ""})
	threads := []any{
		map[string]any{
			"id": "T_1", "path": "api/handler.go", "line": 42, "isOutdated": false, "isResolved": false,
			"comments": map[string]any{"nodes": []any{
				map[string]any{"author": map[string]any{"login": "milton"}, "body": "first", "createdAt": "2026-10-20T10:00:00Z"},
				map[string]any{"author": map[string]any{"login": "peter"}, "body": "second", "createdAt": "2026-10-20T11:00:00Z"},
			}},
		},
		map[string]any{
			"id": "T_2", "path": "api/old.go", "line": nil, "originalLine": 7, "isOutdated": true, "isResolved": true,
			"resolvedBy": map[string]any{"login": "bill"},
			"comments":   map[string]any{"nodes": []any{}},
		},
	}
	child := prNode(216, "ini-143-cover", "ini-142-tps", nil, false, nil, false)
	child["state"] = "OPEN"
	child["mergeStateStatus"] = "CLEAN"
	merged := prNode(200, "ini-142-tps", "main", nil, false, nil, false)
	merged["state"] = "MERGED"
	fork := prNode(201, "ini-142-tps", "main", nil, false, nil, false)
	fork["isCrossRepository"] = true
	reply := map[string]any{"data": map[string]any{"repository": map[string]any{
		"heads": map[string]any{"nodes": []any{prNode(215, "ini-142-tps", "main", threads, false, contexts, false), fork, merged}},
		"bases": map[string]any{"nodes": []any{child}},
	}}}

	f := &fakeGraphQL{}
	c := f.serve(t, func(gqlRequest) (int, string) { return 200, mustJSON(t, reply) })
	heads, bases, err := c.BranchPRs(context.Background(), "initech", "api", "ini-142-tps")
	if err != nil {
		t.Fatal(err)
	}
	if len(f.requests) != 1 {
		t.Fatalf("requests = %d, want one query", len(f.requests))
	}
	q := f.requests[0]
	for _, want := range []string{"headRefName: $branch", "first: 20", "CREATED_AT", "DESC", "[OPEN, MERGED, CLOSED]", "baseRefName: $branch", "states: OPEN", "commits(last: 1)", "contexts(first: 100)", "reviewThreads(first: 100)", "comments(first: 50)"} {
		if !strings.Contains(q.Query, want) {
			t.Errorf("query lacks %q", want)
		}
	}
	if q.Variables["owner"] != "initech" || q.Variables["repo"] != "api" || q.Variables["branch"] != "ini-142-tps" {
		t.Errorf("variables = %v", q.Variables)
	}
	if f.auth[0] != "bearer ghp_initechFAKEtoken0123456789" {
		t.Errorf("authorization = %q", f.auth[0])
	}

	if len(heads) != 2 || heads[0].Number != 215 || heads[1].Number != 200 {
		t.Fatalf("heads = %+v (the fork's PR is not matched)", heads)
	}
	pr := heads[0]
	if pr.State != "blocked" || heads[1].State != "merged" || bases[0].State != "open" {
		t.Errorf("states = %q %q %q", pr.State, heads[1].State, bases[0].State)
	}
	if pr.Head != "ini-142-tps" || pr.Base != "main" || pr.HeadSHA != "abc123" || pr.Author != "peter" || pr.URL != "https://github.com/initech/api/pull/215" || pr.Body != "Ticket: INI-142" {
		t.Errorf("pr = %+v", pr)
	}
	if strings.Join(pr.RequestedReviewers, ",") != "bill,platform" {
		t.Errorf("requested = %v", pr.RequestedReviewers)
	}
	if len(pr.Threads) != 2 {
		t.Fatalf("threads = %+v", pr.Threads)
	}
	t1, t2 := pr.Threads[0], pr.Threads[1]
	if t1.ID != "T_1" || t1.Path != "api/handler.go" || t1.Line != 42 || t1.Outdated || t1.Resolved {
		t.Errorf("thread 1 = %+v", t1)
	}
	if len(t1.Comments) != 2 || t1.Comments[0].Body != "first" || t1.Comments[1].Body != "second" || t1.Comments[0].Author != "milton" || t1.Comments[1].CreatedAt != "2026-10-20T11:00:00Z" {
		t.Errorf("comments = %+v", t1.Comments)
	}
	if !t2.Outdated || !t2.Resolved || t2.ResolvedBy != "bill" || t2.Line != 7 {
		t.Errorf("thread 2 = %+v", t2)
	}
	if len(pr.Checks) != 9 {
		t.Fatalf("checks = %d", len(pr.Checks))
	}
	count := map[string]int{}
	var failed CheckRun
	for _, ch := range pr.Checks {
		count[ch.State]++
		if ch.State == "failure" {
			failed = ch
		}
	}
	if count["success"] != 7 || count["failure"] != 1 || count["pending"] != 1 {
		t.Errorf("states = %v", count)
	}
	if failed.Name != "unit" || failed.URL != "https://github.com/initech/api/actions/runs/9" {
		t.Errorf("failure = %+v", failed)
	}
	if len(bases) != 1 || bases[0].Number != 216 || bases[0].Base != "ini-142-tps" {
		t.Errorf("bases = %+v", bases)
	}
}

func TestBranchPRsPagesThreadsPast100(t *testing.T) {
	var first, second []any
	for i := 0; i < 100; i++ {
		first = append(first, threadNode(fmt.Sprintf("T_%d", i), i+1))
	}
	for i := 100; i < 120; i++ {
		second = append(second, threadNode(fmt.Sprintf("T_%d", i), i+1))
	}
	f := &fakeGraphQL{}
	c := f.serve(t, func(r gqlRequest) (int, string) {
		if strings.Contains(r.Query, "node(id: $id)") {
			if r.Variables["id"] != "PR_215" || r.Variables["after"] != "thr1" {
				t.Errorf("page variables = %v", r.Variables)
			}
			if strings.Contains(r.Query, "headRefName") || strings.Contains(r.Query, "contexts") {
				t.Errorf("the page asks for more than the threads: %s", r.Query)
			}
			return 200, mustJSON(t, map[string]any{"data": map[string]any{"node": map[string]any{"reviewThreads": map[string]any{
				"pageInfo": map[string]any{"hasNextPage": false, "endCursor": "thr2"},
				"nodes":    second,
			}}}})
		}
		return 200, mustJSON(t, map[string]any{"data": map[string]any{"repository": map[string]any{
			"heads": map[string]any{"nodes": []any{prNode(215, "ini-142-tps", "main", first, true, nil, false)}},
			"bases": map[string]any{"nodes": []any{}},
		}}})
	})
	heads, _, err := c.BranchPRs(context.Background(), "initech", "api", "ini-142-tps")
	if err != nil {
		t.Fatal(err)
	}
	if len(f.requests) != 2 {
		t.Fatalf("requests = %d, want the query and one threads page", len(f.requests))
	}
	got := heads[0].Threads
	if len(got) != 120 || got[0].ID != "T_0" || got[99].ID != "T_99" || got[100].ID != "T_100" || got[119].ID != "T_119" {
		t.Fatalf("threads = %d", len(got))
	}
}

func TestBranchPRsPagesChecksPast100(t *testing.T) {
	var first []any
	for i := 0; i < 100; i++ {
		first = append(first, checkRun(fmt.Sprintf("c-%d", i), "COMPLETED", "SUCCESS", ""))
	}
	f := &fakeGraphQL{}
	c := f.serve(t, func(r gqlRequest) (int, string) {
		if strings.Contains(r.Query, "node(id: $id)") {
			if r.Variables["id"] != "SCR_215" || r.Variables["after"] != "ctx1" || strings.Contains(r.Query, "reviewThreads") {
				t.Errorf("checks page = %v %s", r.Variables, r.Query)
			}
			return 200, mustJSON(t, map[string]any{"data": map[string]any{"node": map[string]any{"contexts": map[string]any{
				"pageInfo": map[string]any{"hasNextPage": false},
				"nodes":    []any{checkRun("late", "IN_PROGRESS", "", "")},
			}}}})
		}
		return 200, mustJSON(t, map[string]any{"data": map[string]any{"repository": map[string]any{
			"heads": map[string]any{"nodes": []any{prNode(215, "ini-142-tps", "main", nil, false, first, true)}},
			"bases": map[string]any{"nodes": []any{}},
		}}})
	})
	heads, _, err := c.BranchPRs(context.Background(), "initech", "api", "ini-142-tps")
	if err != nil {
		t.Fatal(err)
	}
	if got := heads[0].Checks; len(got) != 101 || got[100].Name != "late" || got[100].State != "pending" {
		t.Fatalf("checks = %d", len(got))
	}
}

func TestEndpointRules(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	for _, host := range []string{"github.com", "ghe.initech.example"} {
		if err := AddGitAccount("initech", GitAccount{Host: host, Provider: "github", Method: "token"}); err != nil {
			t.Fatal(err)
		}
		if err := SetGitToken("initech", host, "tok-"+host); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("WAKIL_GITHUB_API", "")
	for host, want := range map[string]string{
		"github.com":          "https://api.github.com/graphql",
		"GitHub.com":          "https://api.github.com/graphql",
		"ghe.initech.example": "https://ghe.initech.example/api/graphql",
	} {
		c, err := NewGitHubFor("initech", host)
		if err != nil {
			t.Fatalf("%s: %v", host, err)
		}
		if c.Endpoint != want || c.Token != "tok-"+strings.ToLower(host) {
			t.Errorf("%s: %q %q", host, c.Endpoint, c.Token)
		}
	}
	t.Setenv("WAKIL_GITHUB_API", "http://127.0.0.1:9/graphql")
	if c, err := NewGitHubFor("initech", "github.com"); err != nil || c.Endpoint != "http://127.0.0.1:9/graphql" {
		t.Errorf("override: %+v %v", c, err)
	}
	if _, err := NewGitHubFor("initech", "gitlab.com"); err == nil {
		t.Error("no account for gitlab.com, yet a client")
	}
}

func TestReplySendsTheBodyVerbatim(t *testing.T) {
	body := "  Fixed in abc123 — see `TPS()`.\n\n<b>not html</b> \"quoted\"\n"
	f := &fakeGraphQL{}
	c := f.serve(t, func(r gqlRequest) (int, string) {
		return 200, mustJSON(t, map[string]any{"data": map[string]any{"addPullRequestReviewThreadReply": map[string]any{"comment": map[string]any{
			"author": map[string]any{"login": "peter"}, "body": r.Variables["body"], "createdAt": "2026-10-26T09:00:00Z",
		}}}})
	})
	got, err := c.ReplyToThread(context.Background(), "T_1", body)
	if err != nil {
		t.Fatal(err)
	}
	r := f.requests[0]
	if !strings.Contains(r.Query, "addPullRequestReviewThreadReply") || r.Variables["id"] != "T_1" || r.Variables["body"] != body {
		t.Errorf("request = %s %#v", r.Query, r.Variables)
	}
	if strings.Contains(r.Query, "Fixed in") {
		t.Error("the body is spliced into the query text, not sent as a variable")
	}
	if got.Author != "peter" || got.Body != body || got.CreatedAt != "2026-10-26T09:00:00Z" {
		t.Errorf("comment = %+v", got)
	}
}

func TestReplyPostedBesideErrorsKeepsTheComment(t *testing.T) {
	f := &fakeGraphQL{}
	c := f.serve(t, func(r gqlRequest) (int, string) {
		return 200, mustJSON(t, map[string]any{
			"data": map[string]any{"addPullRequestReviewThreadReply": map[string]any{"comment": map[string]any{
				"author": map[string]any{"login": "peter"}, "body": "Fixed", "createdAt": "2026-10-26T09:00:00Z"}}},
			"errors": []any{map[string]any{"message": "Could not notify subscribers"}},
		})
	})
	got, err := c.ReplyToThread(context.Background(), "T_1", "Fixed")
	var ge *GraphQLError
	if !errors.As(err, &ge) || !reflect.DeepEqual(ge.Messages, []string{"Could not notify subscribers"}) {
		t.Fatalf("err = %v, want the GraphQL errors whole", err)
	}
	if got.Author != "peter" || got.Body != "Fixed" {
		t.Errorf("the posted comment is dropped: %+v", got)
	}
	c = f.serve(t, func(r gqlRequest) (int, string) {
		return 200, `{"data":{"addPullRequestReviewThreadReply":null},"errors":[{"message":"Thread is locked"}]}`
	})
	_, err = c.ReplyToThread(context.Background(), "T_1", "Fixed")
	if err == nil || errors.As(err, &ge) || err.Error() != "GitHub: Thread is locked" {
		t.Errorf("errors with no comment: err = %#v, want a plain error, not posted", err)
	}
}

func TestResolveAndUnresolveMutations(t *testing.T) {
	f := &fakeGraphQL{}
	c := f.serve(t, func(r gqlRequest) (int, string) {
		name := "resolveReviewThread"
		resolved := true
		if strings.Contains(r.Query, "unresolveReviewThread") {
			name, resolved = "unresolveReviewThread", false
		}
		return 200, mustJSON(t, map[string]any{"data": map[string]any{name: map[string]any{"thread": map[string]any{"id": r.Variables["id"], "isResolved": resolved}}}})
	})
	if err := c.SetThreadResolved(context.Background(), "T_1", true); err != nil {
		t.Fatal(err)
	}
	if err := c.SetThreadResolved(context.Background(), "T_2", false); err != nil {
		t.Fatal(err)
	}
	if q := f.requests[0]; !strings.Contains(q.Query, "resolveReviewThread(input: {threadId: $id})") || strings.Contains(q.Query, "unresolve") || q.Variables["id"] != "T_1" {
		t.Errorf("resolve = %s %v", q.Query, q.Variables)
	}
	if q := f.requests[1]; !strings.Contains(q.Query, "unresolveReviewThread(input: {threadId: $id})") || q.Variables["id"] != "T_2" {
		t.Errorf("unresolve = %s %v", q.Query, q.Variables)
	}
}

func TestGraphQLErrorsBesideDataAreKeptWhole(t *testing.T) {
	long := "Resource not accessible by integration: " + strings.Repeat("x", 400)
	f := &fakeGraphQL{}
	c := f.serve(t, func(gqlRequest) (int, string) {
		return 200, mustJSON(t, map[string]any{
			"data": map[string]any{"repository": map[string]any{
				"heads": map[string]any{"nodes": []any{prNode(215, "ini-142-tps", "main", nil, false, nil, false)}},
				"bases": map[string]any{"nodes": []any{}},
			}},
			"errors": []any{
				map[string]any{"message": long, "path": []any{"repository", "heads"}},
				map[string]any{"message": "Could not resolve to a User with the login of 'ghost'."},
			},
		})
	})
	heads, _, err := c.BranchPRs(context.Background(), "initech", "api", "ini-142-tps")
	if len(heads) != 1 || heads[0].Number != 215 {
		t.Errorf("data not returned beside the errors: %+v", heads)
	}
	var ge *GraphQLError
	if !errors.As(err, &ge) {
		t.Fatalf("err = %v, want a GraphQLError", err)
	}
	if len(ge.Messages) != 2 || ge.Messages[0] != long || ge.Messages[1] != "Could not resolve to a User with the login of 'ghost'." {
		t.Errorf("messages = %q", ge.Messages)
	}
	if !strings.Contains(err.Error(), long) || !strings.Contains(err.Error(), "'ghost'") {
		t.Errorf("Error() = %q", err.Error())
	}
}

func TestHTTPErrorShownWholeWithoutToken(t *testing.T) {
	f := &fakeGraphQL{}
	var c *GitHubClient
	body := `{"message":"Bad credentials","documentation_url":"https://docs.github.com/graphql","echo":"bearer TOKEN","tail":"` + strings.Repeat("y", 500) + `"}`
	c = f.serve(t, func(gqlRequest) (int, string) { return 401, strings.Replace(body, "TOKEN", c.Token, 1) })
	_, err := c.Viewer(context.Background())
	if err == nil {
		t.Fatal("no error on a 401")
	}
	msg := err.Error()
	if strings.Contains(msg, c.Token) || strings.Contains(msg, c.Token[:12]) {
		t.Fatalf("the token reached the error: %q", msg)
	}
	if !strings.Contains(msg, "401") || !strings.Contains(msg, "Bad credentials") || !strings.Contains(msg, strings.Repeat("y", 500)+`"}`) {
		t.Errorf("error not whole: %q", msg)
	}
}

func TestViewerReadsTheLogin(t *testing.T) {
	f := &fakeGraphQL{}
	c := f.serve(t, func(gqlRequest) (int, string) {
		return 200, `{"data":{"viewer":{"login":"peter"}}}`
	})
	if got, err := c.Viewer(context.Background()); err != nil || got != "peter" {
		t.Errorf("viewer = %q %v", got, err)
	}
}

func TestMyOpenPRsScopedToOwners(t *testing.T) {
	f := &fakeGraphQL{}
	c := f.serve(t, func(r gqlRequest) (int, string) {
		pr := prNode(215, "ini-142-tps", "main", nil, false, nil, false)
		other := prNode(301, "ini-150-fix", "main", nil, false, nil, false)
		return 200, mustJSON(t, map[string]any{"data": map[string]any{
			"authored":  map[string]any{"nodes": []any{pr, map[string]any{}}},
			"requested": map[string]any{"nodes": []any{other}},
		}})
	})
	authored, requested, err := c.MyOpenPRs(context.Background(), []string{"initech", "umbrella"})
	if err != nil {
		t.Fatal(err)
	}
	r := f.requests[0]
	a, _ := r.Variables["authored"].(string)
	q, _ := r.Variables["requested"].(string)
	for _, s := range []string{a, q} {
		if !strings.Contains(s, "is:open is:pr") || !strings.Contains(s, "org:initech") || !strings.Contains(s, "org:umbrella") {
			t.Errorf("search = %q", s)
		}
	}
	if !strings.Contains(a, "author:@me") || !strings.Contains(q, "review-requested:@me") {
		t.Errorf("searches = %q / %q", a, q)
	}
	if len(authored) != 1 || authored[0].Number != 215 || len(requested) != 1 || requested[0].Number != 301 {
		t.Errorf("authored %+v requested %+v", authored, requested)
	}

	before := len(f.requests)
	if a, q, err := c.MyOpenPRs(context.Background(), nil); err != nil || a != nil || q != nil || len(f.requests) != before {
		t.Errorf("no owners searched all of GitHub: %v %v %v", a, q, err)
	}
}

func TestBranchPRsReadsTheParentPRInTheSameQuery(t *testing.T) {
	pr := prNode(216, "ini-143-cover", "ini-142-tps", nil, false, nil, false)
	parent := prNode(215, "ini-142-tps", "main", nil, false, nil, false)
	fork := prNode(214, "ini-142-tps", "main", nil, false, nil, false)
	fork["isCrossRepository"] = true
	pr["baseRef"] = map[string]any{"associatedPullRequests": map[string]any{"nodes": []any{fork, parent}}}
	orphan := prNode(190, "ini-143-cover", "main", nil, false, nil, false)
	orphan["state"] = "CLOSED"
	orphan["baseRef"] = nil
	f := &fakeGraphQL{}
	c := f.serve(t, func(gqlRequest) (int, string) {
		return 200, mustJSON(t, map[string]any{"data": map[string]any{"repository": map[string]any{
			"heads": map[string]any{"nodes": []any{pr, orphan}},
			"bases": map[string]any{"nodes": []any{}},
		}}})
	})
	heads, _, err := c.BranchPRs(context.Background(), "initech", "api", "ini-143-cover")
	if err != nil {
		t.Fatal(err)
	}
	if len(f.requests) != 1 {
		t.Fatalf("requests = %d, want the parent in the one query", len(f.requests))
	}
	if q := f.requests[0].Query; !strings.Contains(q, "baseRef") || !strings.Contains(q, "associatedPullRequests(states: OPEN, first: 5)") {
		t.Errorf("query lacks the parent: %s", q)
	}
	p := heads[0].Parent
	if p == nil || p.Number != 215 || p.Head != "ini-142-tps" || p.Base != "main" || p.State != "blocked" || p.Title == "" || p.URL == "" {
		t.Fatalf("parent = %+v", p)
	}
	if p.Threads != nil || p.Checks != nil || p.Parent != nil {
		t.Errorf("the parent carries more than its summary: %+v", p)
	}
	if heads[1].Parent != nil {
		t.Errorf("a PR with no open parent has one: %+v", heads[1].Parent)
	}
}

// Waiting on you needs, for each of the viewer's own PRs, who spoke last in each thread and
// whether a check fails: the one search carries both, so no PR is read twice.
func TestMyOpenPRsCarryLastCommentsAndChecks(t *testing.T) {
	f := &fakeGraphQL{}
	c := f.serve(t, func(r gqlRequest) (int, string) {
		pr := prNode(212, "ini-142-login", "main", []any{threadNode("T_1", 88)}, false,
			[]any{checkRun("unit", "COMPLETED", "FAILURE", "")}, false)
		return 200, mustJSON(t, map[string]any{"data": map[string]any{
			"authored":  map[string]any{"nodes": []any{pr}},
			"requested": map[string]any{"nodes": []any{}},
		}})
	})
	authored, _, err := c.MyOpenPRs(context.Background(), []string{"initech"})
	if err != nil {
		t.Fatal(err)
	}
	q := f.requests[0].Query
	for _, want := range []string{"reviewThreads(first: 100)", "comments(last: 1)", "statusCheckRollup", "contexts(first: 100)"} {
		if !strings.Contains(q, want) {
			t.Errorf("search lacks %q", want)
		}
	}
	if len(authored) != 1 || len(authored[0].Threads) != 1 || authored[0].Threads[0].Comments[0].Author != "milton" {
		t.Fatalf("authored = %+v", authored)
	}
	if len(authored[0].Checks) != 1 || authored[0].Checks[0].State != "failure" {
		t.Errorf("checks = %+v", authored[0].Checks)
	}
}

func TestReviewThreadDescribesTheThreadByItsID(t *testing.T) {
	f := &fakeGraphQL{}
	c := f.serve(t, func(r gqlRequest) (int, string) {
		if r.Variables["id"] != "T_9" {
			return 200, `{"data":{"node":null}}`
		}
		return 200, mustJSON(t, map[string]any{"data": map[string]any{"node": map[string]any{
			"__typename": "PullRequestReviewThread", "id": "T_9", "path": "src/auth/token.go", "line": 41,
			"isResolved": false, "isOutdated": false,
			"pullRequest": map[string]any{"number": 212, "repository": map[string]any{"nameWithOwner": "initech/api"}},
			"comments":    map[string]any{"nodes": []any{map[string]any{"author": map[string]any{"login": "peter"}, "body": "Nit: the error should name the host, and the port too"}}},
		}}})
	})
	got, err := c.ReviewThread(context.Background(), "T_9")
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != "T_9" || got.Repo != "initech/api" || got.Number != 212 || got.Path != "src/auth/token.go" || got.Line != 41 ||
		got.Resolved || got.Author != "peter" || got.FirstWords != "Nit: the error should name the host, and…" {
		t.Errorf("thread = %+v", got)
	}
	if !strings.Contains(f.requests[0].Query, "node(id: $id)") {
		t.Errorf("query = %s", f.requests[0].Query)
	}
	if _, err := c.ReviewThread(context.Background(), "T_missing"); err == nil || !strings.Contains(err.Error(), "T_missing") {
		t.Errorf("an unknown id answered %v", err)
	}
}

func TestReviewThreadErrorKeepsNoToken(t *testing.T) {
	f := &fakeGraphQL{}
	var c *GitHubClient
	c = f.serve(t, func(gqlRequest) (int, string) { return 403, `{"message":"no, bearer ` + c.Token + `"}` })
	_, err := c.ReviewThread(context.Background(), "T_9")
	if err == nil || strings.Contains(err.Error(), c.Token) || !strings.Contains(err.Error(), "403") {
		t.Fatalf("err = %v", err)
	}
}
