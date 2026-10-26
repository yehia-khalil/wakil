package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// The fixture: a temp HOME holding organisation initech with one project (Jira key INI) whose one
// root is a temp git repository with an origin, a GraphQL stub at WAKIL_GITHUB_API, a Jira stub at
// WAKIL_JIRA_BASE, and a fake `security` that answers the Jira and GitHub credentials.

type gqlRequest struct {
	Query     string         `json:"query"`
	Variables map[string]any `json:"variables"`
}

type stubs struct {
	mu   sync.Mutex
	gql  []gqlRequest
	jira []string // each search's jql

	// branch answers BranchPRs' query; nil answers no PRs.
	branch func(gqlRequest) (int, string)
	// search answers MyOpenPRs' query.
	search func(gqlRequest) (int, string)
	// jiraDown makes every Jira search answer 502; jiraHung makes it never answer.
	jiraDown bool
	jiraHung bool
	// issues are the Jira issues by key.
	issues map[string]string // key -> summary
}

func (s *stubs) gqlCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.gql)
}

func (s *stubs) jiraCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.jira)
}

type fixture struct {
	t    *testing.T
	home string
	repo string
	s    *stubs
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=Peter", "-c", "user.email=peter@initech.example", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// newFixture builds the organisation and a repository on main with origin remote, then checks
// out branch (with one commit carrying message) unless branch is "main".
func newFixture(t *testing.T, remote, branch, message string) *fixture {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_IN_WINDOW", "1")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatal(err)
	}

	repo := filepath.Join(t.TempDir(), "api")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "init", "-q", "-b", "main")
	writeFile(t, filepath.Join(repo, "README"), "api\n")
	git(t, repo, "add", "README")
	git(t, repo, "commit", "-q", "-m", "first")
	git(t, repo, "remote", "add", "origin", remote)
	git(t, repo, "update-ref", "refs/remotes/origin/main", "HEAD")
	git(t, repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
	if branch != "main" {
		git(t, repo, "checkout", "-q", "-b", branch)
		writeFile(t, filepath.Join(repo, "login.go"), "package api\n")
		git(t, repo, "add", "login.go")
		git(t, repo, "commit", "-q", "-m", message)
	}

	pp := filepath.Join(home, "proj", ".wakil", "project.json")
	writeFile(t, pp, `{"name":"api","org":"initech","roots":[{"path":`+jsonString(repo)+`}],"scopes":{"pm":{"provider":"jira","projectKey":"INI"}},"environments":{}}`)
	if err := wakilcore.SaveRegistry("initech", map[string]wakilcore.ProjectEntry{"api": {Path: pp}}); err != nil {
		t.Fatal(err)
	}
	if err := wakilcore.AddGitAccount("initech", wakilcore.GitAccount{Host: "github.com", Provider: "github", Method: "token"}); err != nil {
		t.Fatal(err)
	}
	fakeSecurity(t)

	f := &fixture{t: t, home: home, repo: repo, s: &stubs{issues: map[string]string{
		"INI-142": "Sign-in keeps the last organization",
		"INI-150": "Cache the org list",
		"INI-160": "Retry the token refresh",
	}}}
	f.serveGitHub()
	f.serveJira()
	return f
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// fakeSecurity answers the Jira credential as email:token and every git token with one value,
// through the WAKIL_SECURITY_BINARY seam: the real Keychain is never asked.
func fakeSecurity(t *testing.T) {
	t.Helper()
	script := filepath.Join(t.TempDir(), "security")
	body := "#!/bin/sh\ncase \"$*\" in\n" +
		"  *jira:*) printf '%s' 'peter@initech.example:jira-fake-token' ;;\n" +
		"  *git-*) printf '%s' 'ghp_initechFAKEtoken0123456789' ;;\n" +
		"  *) exit 44 ;;\nesac\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_SECURITY_BINARY", script)
}

func (f *fixture) serveGitHub() {
	s := f.s
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req gqlRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			f.t.Errorf("GraphQL body: %v", err)
		}
		s.mu.Lock()
		s.gql = append(s.gql, req)
		s.mu.Unlock()
		code, body := 200, `{"data":{}}`
		switch {
		case strings.Contains(req.Query, "heads: pullRequests"):
			body = `{"data":{"repository":{"heads":{"nodes":[]},"bases":{"nodes":[]}}}}`
			if s.branch != nil {
				code, body = s.branch(req)
			}
		case strings.Contains(req.Query, "search("):
			body = `{"data":{"authored":{"nodes":[]},"requested":{"nodes":[]}}}`
			if s.search != nil {
				code, body = s.search(req)
			}
		case strings.Contains(req.Query, "addPullRequestReviewThreadReply"):
			b, _ := req.Variables["body"].(string)
			body = mustJSON(map[string]any{"data": map[string]any{"addPullRequestReviewThreadReply": map[string]any{
				"comment": map[string]any{"author": map[string]any{"login": "peter"}, "body": b, "createdAt": "2026-10-26T09:00:00Z"}}}})
		case strings.Contains(req.Query, "resolveReviewThread"), strings.Contains(req.Query, "unresolveReviewThread"):
			body = `{"data":{"resolveReviewThread":{"thread":{"id":"T_1","isResolved":true}}}}`
		case strings.Contains(req.Query, "node(id: $id)"):
			body = `{"data":{"node":null}}`
			if req.Variables["id"] == "T_1" {
				body = mustJSON(map[string]any{"data": map[string]any{"node": map[string]any{
					"__typename": "PullRequestReviewThread", "id": "T_1", "path": "src/auth/token.go", "line": 41,
					"isResolved": false, "isOutdated": false,
					"pullRequest": map[string]any{"number": 212, "repository": map[string]any{"nameWithOwner": "initech/api"}},
					"comments":    map[string]any{"nodes": []any{map[string]any{"author": map[string]any{"login": "reviewer"}, "body": "Nit: name the host"}}}}}})
			}
		case strings.Contains(req.Query, "viewer { login }"):
			body = `{"data":{"viewer":{"login":"peter"}}}`
		}
		w.WriteHeader(code)
		fmt.Fprint(w, body)
	}))
	f.t.Cleanup(srv.Close)
	f.t.Setenv("WAKIL_GITHUB_API", srv.URL)
}

// serveJira is a TLS stub (the Jira client takes https only). The process's default transport is
// pointed at the stub's own trust for the test, as both clients use it.
func (f *fixture) serveJira() {
	s := f.s
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			JQL string `json:"jql"`
		}
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &req)
		s.mu.Lock()
		s.jira = append(s.jira, req.JQL)
		s.mu.Unlock()
		if s.jiraHung {
			<-r.Context().Done()
			return
		}
		if s.jiraDown {
			w.WriteHeader(502)
			fmt.Fprint(w, "Jira is down")
			return
		}
		key := strings.TrimPrefix(req.JQL, "key = ")
		issues := []any{}
		if summary, ok := s.issues[key]; ok {
			issues = append(issues, map[string]any{"key": key, "fields": map[string]any{
				"summary": summary, "status": map[string]any{"name": "In Progress"},
				"assignee": map[string]any{"displayName": "Peter Gibbons"}}})
		}
		fmt.Fprint(w, mustJSON(map[string]any{"issues": issues, "isLast": true}))
	}))
	// A client that leaves mid-handshake when the test ends is not news.
	srv.Config.ErrorLog = log.New(io.Discard, "", 0)
	srv.StartTLS()
	f.t.Cleanup(srv.Close)
	f.t.Setenv("WAKIL_JIRA_BASE", srv.URL)
	old := http.DefaultTransport
	http.DefaultTransport = srv.Client().Transport
	f.t.Cleanup(func() { http.DefaultTransport = old })
}

func mustJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// prNode is one PR in GitHub's GraphQL shape.
func prNode(number int, title, head, base string, threads, contexts []any) map[string]any {
	return map[string]any{
		"id": fmt.Sprintf("PR_%d", number), "number": number, "title": title, "body": "",
		"url": fmt.Sprintf("https://github.com/initech/api/pull/%d", number), "state": "OPEN",
		"mergeStateStatus": "CLEAN", "isCrossRepository": false, "headRefName": head, "baseRefName": base,
		"headRefOid": "abc123", "author": map[string]any{"login": "peter"},
		"reviewRequests": map[string]any{"nodes": []any{}},
		"commits": map[string]any{"nodes": []any{map[string]any{"commit": map[string]any{"statusCheckRollup": map[string]any{
			"id": fmt.Sprintf("SCR_%d", number), "contexts": map[string]any{"pageInfo": map[string]any{}, "nodes": contexts}}}}}},
		"reviewThreads": map[string]any{"pageInfo": map[string]any{}, "nodes": threads},
		"baseRef":       nil,
	}
}

func thread(id, path string, line int, authors ...string) map[string]any {
	var comments []any
	for i, a := range authors {
		comments = append(comments, map[string]any{"author": map[string]any{"login": a}, "body": fmt.Sprintf("comment %d", i+1), "createdAt": "2026-10-25T10:00:00Z"})
	}
	return map[string]any{"id": id, "path": path, "line": line, "isOutdated": false, "isResolved": false, "comments": map[string]any{"nodes": comments}}
}

func check(name, conclusion string) map[string]any {
	return map[string]any{"__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion, "detailsUrl": "https://github.com/initech/api/actions/runs/1"}
}

func branchReply(heads, bases []any) func(gqlRequest) (int, string) {
	return func(gqlRequest) (int, string) {
		if heads == nil {
			heads = []any{}
		}
		if bases == nil {
			bases = []any{}
		}
		return 200, mustJSON(map[string]any{"data": map[string]any{"repository": map[string]any{
			"heads": map[string]any{"nodes": heads}, "bases": map[string]any{"nodes": bases}}}})
	}
}

func connect(t *testing.T) *mcp.ClientSession {
	t.Helper()
	ctx := context.Background()
	st, ct := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, st, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "wakil-ticket-test", Version: "0.0.0"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

// call runs a tool and returns its structured output as JSON, failing on a tool error.
func call(t *testing.T, cs *mcp.ClientSession, tool string, args map[string]any) []byte {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", tool, err)
	}
	if res.IsError {
		t.Fatalf("%s: tool error %s", tool, toolText(res))
	}
	b, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func toolText(res *mcp.CallToolResult) string {
	if len(res.Content) == 0 {
		return ""
	}
	if tc, ok := res.Content[0].(*mcp.TextContent); ok {
		return tc.Text
	}
	return ""
}

func callErr(t *testing.T, cs *mcp.ClientSession, tool string, args map[string]any) string {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", tool, err)
	}
	if !res.IsError {
		t.Fatalf("%s answered, want a refusal", tool)
	}
	return toolText(res)
}

func (f *fixture) branch(cs *mcp.ClientSession) (TicketBranch, map[string]any) {
	f.t.Helper()
	b := call(f.t, cs, "ticket_branch", map[string]any{"root": f.repo})
	var out TicketBranch
	if err := json.Unmarshal(b, &out); err != nil {
		f.t.Fatal(err)
	}
	var raw map[string]any
	_ = json.Unmarshal(b, &raw)
	return out, raw
}

func TestTicketBranchJoinsJiraGitHubAndRecord(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org\n\nTicket: INI-142")
	f.s.branch = branchReply([]any{prNode(212, "INI-142 keep the last organization", "ini-142-login", "main",
		[]any{thread("T_1", "src/auth/session.go", 88, "milton", "peter")},
		[]any{check("lint", "SUCCESS"), check("unit (Linux)", "FAILURE")})}, nil)
	if _, err := wakilcore.UpdateTicketRecord("initech", "INI-142", wakilcore.TicketEdit{
		Section: "decisions", Op: "add", Line: wakilcore.TicketLine{Text: "Read the org from the session", Why: "one source"}, By: "operator",
	}, time.Now()); err != nil {
		t.Fatal(err)
	}

	got, raw := f.branch(connect(t))
	if got.Branch != "ini-142-login" || got.Repo != "github.com/initech/api" || got.Viewer != "peter" || got.LongLived {
		t.Errorf("branch = %+v", got)
	}
	if len(got.Tickets) != 1 {
		t.Fatalf("tickets = %+v", got.Tickets)
	}
	tk := got.Tickets[0]
	if tk.Key != "INI-142" || tk.Title != "Sign-in keeps the last organization" || tk.Status != "In Progress" || tk.Assignee != "Peter Gibbons" || !tk.Marked || tk.Error != "" {
		t.Errorf("ticket = %+v", tk)
	}
	if !reflect.DeepEqual(tk.Sources, []string{"branch", "pr", "trailer"}) {
		t.Errorf("sources = %v", tk.Sources)
	}
	if len(tk.Record.Decisions) != 1 || tk.Record.Decisions[0].Why != "one source" {
		t.Errorf("record = %+v", tk.Record)
	}
	if !reflect.DeepEqual(got.Looked, []string{"branch name", "PR #212's title and body", "1 commit's trailers"}) {
		t.Errorf("looked = %v", got.Looked)
	}
	if len(got.PRs) != 1 || got.PRs[0].Number != 212 || len(got.PRs[0].Threads) != 1 || len(got.PRs[0].Threads[0].Comments) != 2 || len(got.PRs[0].Checks) != 2 {
		t.Fatalf("prs = %+v", got.PRs)
	}
	if len(got.Partial) != 0 {
		t.Errorf("partial = %+v", got.Partial)
	}

	// Every list field reaches the window as an array, never null.
	rec := raw["tickets"].([]any)[0].(map[string]any)["record"].(map[string]any)
	for _, k := range []string{"branches", "prs", "decisions", "notDone", "waitingOn", "verified", "rulings"} {
		if _, ok := rec[k].([]any); !ok {
			t.Errorf("record.%s = %#v, want an array", k, rec[k])
		}
	}
	for _, k := range []string{"basePRs", "stack", "partial"} {
		if _, ok := raw[k].([]any); !ok {
			t.Errorf("%s = %#v, want an array", k, raw[k])
		}
	}
	pr := raw["prs"].([]any)[0].(map[string]any)
	if _, ok := pr["requestedReviewers"].([]any); !ok {
		t.Errorf("requestedReviewers = %#v, want an array", pr["requestedReviewers"])
	}

	// The read is written to the record: seen, the branch and the PR.
	r, err := wakilcore.ReadTicketRecord("initech", "INI-142")
	if err != nil {
		t.Fatal(err)
	}
	if r.Seen.Title != "Sign-in keeps the last organization" || len(r.Branches) != 1 || r.Branches[0].Branch != "ini-142-login" || len(r.PRs) != 1 || r.PRs[0].Number != 212 {
		t.Errorf("record after the read = %+v", r)
	}
}

func TestTicketBranchGitHubDownKeepsJira(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	f.s.branch = func(gqlRequest) (int, string) { return 502, "upstream connect error" }
	got, _ := f.branch(connect(t))
	if len(got.Partial) == 0 || got.Partial[0].Source != "github" || got.Partial[0].Message != "GitHub error 502: upstream connect error" {
		t.Fatalf("partial = %+v", got.Partial)
	}
	if len(got.Tickets) != 1 || got.Tickets[0].Title != "Sign-in keeps the last organization" {
		t.Errorf("tickets = %+v", got.Tickets)
	}
}

func TestTicketBranchJiraDownKeepsPRs(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	f.s.jiraDown = true
	f.s.branch = branchReply([]any{prNode(212, "INI-142 keep", "ini-142-login", "main", nil, nil)}, nil)
	got, _ := f.branch(connect(t))
	if len(got.PRs) != 1 || got.PRs[0].Number != 212 {
		t.Fatalf("prs = %+v", got.PRs)
	}
	var jira *SourceNote
	for i := range got.Partial {
		if got.Partial[i].Source == "jira" {
			jira = &got.Partial[i]
		}
	}
	if jira == nil || !strings.Contains(jira.Message, "Jira is down") {
		t.Fatalf("partial = %+v", got.Partial)
	}
	if len(got.Tickets) != 1 || got.Tickets[0].Key != "INI-142" || got.Tickets[0].Error == "" {
		t.Errorf("tickets = %+v", got.Tickets)
	}
}

func TestTicketBranchSSHWithoutAPIAccessSaysSo(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	if err := wakilcore.AddGitAccount("initech", wakilcore.GitAccount{Host: "github.com", Provider: "github", Method: "ssh"}); err != nil {
		t.Fatal(err)
	}
	got, _ := f.branch(connect(t))
	want := SourceNote{Source: "github", Message: "Pull requests not read: this organization's github.com account signs in with SSH, which reads no pull requests. Add API access to the GitHub account in Settings → Organisation → Git."}
	if len(got.Partial) != 1 || got.Partial[0] != want {
		t.Fatalf("partial = %+v", got.Partial)
	}
	if f.s.gqlCount() != 0 {
		t.Errorf("GitHub was asked %d times", f.s.gqlCount())
	}
	if len(got.Tickets) != 1 || got.Tickets[0].Title == "" {
		t.Errorf("tickets = %+v", got.Tickets)
	}
}

func TestTicketBranchNonGitHubRemoteSaysSo(t *testing.T) {
	f := newFixture(t, "git@gitlab.com:initech/api.git", "ini-142-login", "Keep the org")
	if err := wakilcore.AddGitAccount("initech", wakilcore.GitAccount{Host: "gitlab.com", Provider: "gitlab", Method: "token"}); err != nil {
		t.Fatal(err)
	}
	got, _ := f.branch(connect(t))
	if len(got.Partial) != 1 || got.Partial[0] != (SourceNote{Source: "github", Message: "Pull requests are read from GitHub only."}) {
		t.Fatalf("partial = %+v", got.Partial)
	}
	if f.s.gqlCount() != 0 || len(got.Tickets) != 1 {
		t.Errorf("GitHub asked %d times; tickets %+v", f.s.gqlCount(), got.Tickets)
	}
}

func TestTicketBranchDetachedHeadReadsNothingRemote(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	git(t, f.repo, "checkout", "-q", "--detach")
	got, _ := f.branch(connect(t))
	if len(got.Partial) != 1 || got.Partial[0] != (SourceNote{Source: "git", Message: "detached HEAD: no branch to read"}) {
		t.Fatalf("partial = %+v", got.Partial)
	}
	if f.s.gqlCount() != 0 || f.s.jiraCount() != 0 {
		t.Errorf("remote reads: GitHub %d, Jira %d", f.s.gqlCount(), f.s.jiraCount())
	}
	if got.Branch != "" || len(got.Tickets) != 0 {
		t.Errorf("branch = %+v", got)
	}
}

func TestTicketBranchNoTicketLooked(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "fix-utf-8", "Fix UTF-8 names")
	f.s.branch = branchReply([]any{prNode(215, "Fix UTF-8 names", "fix-utf-8", "main", nil, nil)}, nil)
	got, _ := f.branch(connect(t))
	if len(got.Tickets) != 0 || got.Linked {
		t.Errorf("tickets = %+v", got.Tickets)
	}
	if !reflect.DeepEqual(got.Looked, []string{"branch name", "PR #215's title and body", "1 commit's trailers"}) {
		t.Errorf("looked = %v", got.Looked)
	}
	if len(got.PRs) != 1 || got.PRs[0].Number != 215 {
		t.Errorf("the branch's own PRs still show: %+v", got.PRs)
	}
}

// A ticket picked from In flight reads its own branch, named, while the root stays on another:
// the branch is read as if it were current, and nothing is checked out.
func TestTicketBranchReadsANamedBranch(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	git(t, f.repo, "checkout", "-q", "main")
	f.s.branch = branchReply([]any{prNode(212, "INI-142 keep", "ini-142-login", "main", nil, nil)}, nil)
	b := call(t, connect(t), "ticket_branch", map[string]any{"root": f.repo, "branch": "ini-142-login"})
	var got TicketBranch
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got.Branch != "ini-142-login" || got.LongLived || len(got.Tickets) != 1 || got.Tickets[0].Key != "INI-142" {
		t.Errorf("named branch = %+v", got)
	}
	if len(got.PRs) != 1 || got.PRs[0].Number != 212 {
		t.Errorf("prs = %+v", got.PRs)
	}
	if out, _ := exec.Command("git", "-C", f.repo, "branch", "--show-current").Output(); strings.TrimSpace(string(out)) != "main" {
		t.Errorf("the root switched to %q", out)
	}
}

func TestTicketBranchLongLived(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "main", "")
	f.s.branch = branchReply(nil, []any{prNode(212, "INI-142 keep", "ini-142-login", "main", nil, nil)})
	got, _ := f.branch(connect(t))
	if !got.LongLived || len(got.Tickets) != 0 || got.Branch != "main" {
		t.Errorf("main = %+v", got)
	}
	if f.s.jiraCount() != 0 {
		t.Errorf("Jira asked %d times on a long-lived branch", f.s.jiraCount())
	}
}

func TestTicketBranchStackBothWays(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-150-cache", "Cache")
	pr := prNode(216, "INI-150 cache", "ini-150-cache", "ini-142-login", nil, nil)
	pr["baseRef"] = map[string]any{"associatedPullRequests": map[string]any{"nodes": []any{prNode(212, "INI-142 keep", "ini-142-login", "main", nil, nil)}}}
	f.s.branch = branchReply([]any{pr}, []any{prNode(220, "INI-160 retry", "ini-160-retry", "ini-150-cache", nil, nil)})
	got, _ := f.branch(connect(t))
	if !reflect.DeepEqual(got.Stack, []int{212, 216, 220}) {
		t.Errorf("stack = %v", got.Stack)
	}
	if len(got.PRs) != 1 || got.PRs[0].Parent == nil || got.PRs[0].Parent.Number != 212 || len(got.BasePRs) != 1 {
		t.Errorf("prs %+v bases %+v", got.PRs, got.BasePRs)
	}
	var keys []string
	for _, tk := range got.Tickets {
		keys = append(keys, fmt.Sprintf("%s:%v:%v", tk.Key, tk.Sources, tk.Marked))
	}
	if !reflect.DeepEqual(keys, []string{"INI-150:[branch pr]:true", "INI-142:[stack]:false", "INI-160:[stack]:false"}) {
		t.Errorf("tickets = %v", keys)
	}
}

func TestWritesRefusedOutsideTheWindow(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	t.Setenv("WAKIL_IN_WINDOW", "")
	cs := connect(t)
	writes := map[string]map[string]any{
		"ticket_record_write": {"key": "INI-142", "section": "next", "op": "set", "line": map[string]any{"text": "QA deploy"}, "by": "agent"},
		"ticket_link":         {"root": f.repo, "branch": "ini-142-login", "key": "INI-150"},
		"review_reply":        {"root": f.repo, "thread": "T_1", "body": "Done"},
		"review_resolve":      {"root": f.repo, "thread": "T_1", "resolved": true},
	}
	for tool, args := range writes {
		if msg := callErr(t, cs, tool, args); !strings.Contains(msg, "Wakil window") {
			t.Errorf("%s refused with %q, want it to name the Wakil window", tool, msg)
		}
	}
	if f.s.gqlCount() != 0 {
		t.Errorf("a refused write reached GitHub %d times", f.s.gqlCount())
	}
	if _, ok := wakilcore.TicketLinkFor("initech", "github.com/initech/api", "ini-142-login"); ok {
		t.Error("a refused link was written")
	}
	call(t, cs, "ticket_record", map[string]any{"key": "INI-142"})
	call(t, cs, "ticket_branch", map[string]any{"root": f.repo})
	call(t, cs, "ticket_in_flight", map[string]any{})
}

func TestReviewReplyPostsToTheStub(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	b := call(t, connect(t), "review_reply", map[string]any{"root": f.repo, "thread": "T_1", "body": "Fixed in 4f1c: the org comes from the session.\n\nThanks"})
	var out replyResult
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	if out.Comment.Author != "peter" || out.Comment.Body != "Fixed in 4f1c: the org comes from the session.\n\nThanks" {
		t.Errorf("comment = %+v", out.Comment)
	}
	if f.s.gqlCount() != 1 {
		t.Fatalf("requests = %d", f.s.gqlCount())
	}
	req := f.s.gql[0]
	if !strings.Contains(req.Query, "addPullRequestReviewThreadReply") || req.Variables["id"] != "T_1" || req.Variables["body"] != out.Comment.Body {
		t.Errorf("request = %+v", req)
	}
}

func TestReviewResolveSendsTheMutation(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	cs := connect(t)
	call(t, cs, "review_resolve", map[string]any{"root": f.repo, "thread": "T_1", "resolved": true})
	call(t, cs, "review_resolve", map[string]any{"root": f.repo, "thread": "T_1", "resolved": false})
	if f.s.gqlCount() != 2 || !strings.Contains(f.s.gql[0].Query, "resolveReviewThread") || !strings.Contains(f.s.gql[1].Query, "unresolveReviewThread") {
		t.Errorf("requests = %+v", f.s.gql)
	}
}

func TestInFlightBranchesAndMyPRs(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	git(t, f.repo, "branch", "ini-150-cache", "main")
	f.s.search = func(r gqlRequest) (int, string) {
		mine := prNode(212, "INI-142 keep", "ini-142-login", "main",
			[]any{thread("T_1", "a.go", 1, "milton"), thread("T_2", "b.go", 2, "peter")}, []any{check("unit", "SUCCESS")})
		failing := prNode(220, "INI-160 retry", "ini-160-retry", "main", nil, []any{check("unit", "FAILURE")})
		asked := prNode(301, "Speed up the build", "build-speed", "main", nil, nil)
		asked["author"] = map[string]any{"login": "milton"}
		return 200, mustJSON(map[string]any{"data": map[string]any{
			"authored": map[string]any{"nodes": []any{mine, failing}}, "requested": map[string]any{"nodes": []any{asked}}}})
	}
	b := call(t, connect(t), "ticket_in_flight", map[string]any{})
	var got InFlight
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	real, _ := filepath.EvalSymlinks(f.repo)
	wantInFlight := []InFlightRow{
		{Key: "INI-142", Title: "Sign-in keeps the last organization", Status: "In Progress", State: "#212 · open", Root: real, Branch: "ini-142-login", PR: 212},
		{Key: "INI-150", Title: "Cache the org list", Status: "In Progress", State: "local branch", Root: real, Branch: "ini-150-cache"},
		{Key: "INI-160", Title: "Retry the token refresh", Status: "In Progress", State: "#220 · open", Root: real, Branch: "ini-160-retry", PR: 220},
	}
	if !reflect.DeepEqual(got.InFlight, wantInFlight) {
		t.Errorf("in flight =\n%+v\nwant\n%+v", got.InFlight, wantInFlight)
	}
	wantWaiting := []InFlightRow{
		{Key: "INI-142", Title: "Sign-in keeps the last organization", Status: "In Progress", State: "#212 · 1 thread", Root: real, Branch: "ini-142-login", PR: 212},
		{Key: "INI-160", Title: "Retry the token refresh", Status: "In Progress", State: "checks failing", Root: real, Branch: "ini-160-retry", PR: 220},
		{Title: "Speed up the build", State: "review requested", Root: real, Branch: "build-speed", PR: 301},
	}
	if !reflect.DeepEqual(got.WaitingOnYou, wantWaiting) {
		t.Errorf("waiting on you =\n%+v\nwant\n%+v", got.WaitingOnYou, wantWaiting)
	}
	var searches int
	for _, r := range f.s.gql {
		if strings.Contains(r.Query, "search(") {
			searches++
			if a, _ := r.Variables["authored"].(string); !strings.Contains(a, "org:initech") {
				t.Errorf("search not scoped to the organization's owners: %q", a)
			}
		}
	}
	if searches != 1 {
		t.Errorf("searches = %d, want one per host", searches)
	}
	if len(got.Partial) != 0 {
		t.Errorf("partial = %+v", got.Partial)
	}
}

func TestLinkUnknownKeyIsKept(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "fix-utf-8", "Fix UTF-8 names")
	cs := connect(t)
	b := call(t, cs, "ticket_link", map[string]any{"root": f.repo, "branch": "fix-utf-8", "key": "ini-999"})
	var out linkResult
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	if out.Key != "INI-999" || !out.Linked || !out.NotFound || out.Message == "" {
		t.Errorf("link = %+v", out)
	}
	got, _ := f.branch(cs)
	if !got.Linked || len(got.Tickets) != 1 || got.Tickets[0].Key != "INI-999" || !reflect.DeepEqual(got.Tickets[0].Sources, []string{"wakil"}) || got.Tickets[0].Error == "" {
		t.Errorf("after the link: %+v", got)
	}

	b = call(t, cs, "ticket_link", map[string]any{"root": f.repo, "key": "INI-142"})
	_ = json.Unmarshal(b, &out)
	if out.NotFound || out.Key != "INI-142" {
		t.Errorf("a found key: %+v", out)
	}
	call(t, cs, "ticket_link", map[string]any{"root": f.repo, "branch": "fix-utf-8", "key": ""})
	if got, _ := f.branch(cs); got.Linked || len(got.Tickets) != 0 {
		t.Errorf("unlinked: %+v", got)
	}
}

func TestTicketRecordEditKeepsOtherFields(t *testing.T) {
	newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	cs := connect(t)
	call(t, cs, "ticket_record_write", map[string]any{"key": "INI-142", "section": "decisions", "op": "add",
		"line": map[string]any{"text": "Read the org from the session", "why": "one source"}, "by": "operator"})
	call(t, cs, "ticket_record_write", map[string]any{"key": "INI-142", "section": "rulings", "op": "add",
		"line": map[string]any{"text": "No fetch", "why": "local git only"}, "by": "agent", "conversation": "c-7"})
	b := call(t, cs, "ticket_record_write", map[string]any{"key": "INI-142", "section": "decisions", "op": "edit", "id": "d1",
		"line": map[string]any{"text": "Read the org from the session cookie"}, "by": "operator"})
	var r wakilcore.TicketRecord
	if err := json.Unmarshal(b, &r); err != nil {
		t.Fatal(err)
	}
	if d := r.Decisions[0]; d.Text != "Read the org from the session cookie" || d.Why != "one source" {
		t.Errorf("edited line = %+v, want why kept", d)
	}
	if ru := r.Rulings[0]; ru.State != "open" || ru.By != "agent" || ru.Conversation != "c-7" {
		t.Errorf("ruling = %+v", ru)
	}
	b = call(t, cs, "ticket_record", map[string]any{"key": "ini-142"})
	_ = json.Unmarshal(b, &r)
	if r.Key != "INI-142" || len(r.Decisions) != 1 {
		t.Errorf("read = %+v", r)
	}
	if msg := callErr(t, cs, "ticket_record_write", map[string]any{"key": "INI-142", "section": "next", "op": "set",
		"line": map[string]any{"text": "x"}, "by": "someone"}); !strings.Contains(msg, "operator, agent or wakil") {
		t.Errorf("unknown by: %q", msg)
	}
}

func TestTicketBranchLongLivedStagingReadsNoJira(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "staging", "Merge INI-142\n\nTicket: INI-142")
	f.s.branch = branchReply(nil, []any{prNode(212, "INI-142 keep", "ini-142-login", "staging", nil, nil)})
	got, _ := f.branch(connect(t))
	if !got.LongLived || len(got.Tickets) != 0 {
		t.Errorf("staging = %+v", got)
	}
	if f.s.jiraCount() != 0 {
		t.Errorf("Jira asked %d times on a long-lived branch", f.s.jiraCount())
	}
}

func TestTicketBranchStackTicketIsNotMarked(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "fix-utf-8", "Fix UTF-8 names")
	pr := prNode(216, "Fix UTF-8 names", "fix-utf-8", "ini-142-login", nil, nil)
	pr["baseRef"] = map[string]any{"associatedPullRequests": map[string]any{"nodes": []any{prNode(212, "INI-142 keep", "ini-142-login", "main", nil, nil)}}}
	f.s.branch = branchReply([]any{pr}, nil)
	got, _ := f.branch(connect(t))
	if len(got.Tickets) != 1 || got.Tickets[0].Key != "INI-142" || got.Tickets[0].Marked {
		t.Errorf("tickets = %+v, want INI-142 from the stack, unmarked", got.Tickets)
	}
}

func TestTicketBranchJiraHungReturnsWithinTheBudget(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	f.s.jiraHung = true
	f.s.branch = branchReply([]any{prNode(212, "INI-142 keep", "ini-142-login", "main", nil, nil)}, nil)
	if err := wakilcore.RecordTicketSeen("initech", "INI-142", wakilcore.TicketSeen{Title: "Sign-in keeps the last organization", Status: "In Review"}, nil, nil); err != nil {
		t.Fatal(err)
	}
	old := jiraCallTimeout
	jiraCallTimeout = 300 * time.Millisecond
	t.Cleanup(func() { jiraCallTimeout = old })
	start := time.Now()
	got, _ := f.branch(connect(t))
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("the read took %v", d)
	}
	if len(got.PRs) != 1 {
		t.Errorf("prs = %+v", got.PRs)
	}
	if len(got.Tickets) != 1 || got.Tickets[0].Title != "Sign-in keeps the last organization" || got.Tickets[0].Status != "In Review" {
		t.Errorf("tickets = %+v, want the record's last read", got.Tickets)
	}
	want := SourceNote{Source: "jira", Message: "Jira did not answer within 300ms"}
	if len(got.Partial) != 1 || got.Partial[0] != want {
		t.Errorf("partial = %+v", got.Partial)
	}
}

func TestReadBudgetIsUnderTheWindowsCancel(t *testing.T) {
	if readBudget != 15*time.Second || jiraCallTimeout != 5*time.Second {
		t.Errorf("budget %v, Jira call %v; want 15 s and 5 s, under the window's 20 s", readBudget, jiraCallTimeout)
	}
}

// Two writers editing different fields of one line at once: both edits land, because each
// reads, merges and writes under the ticket's lock.
func TestTicketRecordConcurrentEditsOfOneLineKeepBoth(t *testing.T) {
	newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	str := func(s string) *string { return &s }
	for round := 0; round < 10; round++ {
		key := fmt.Sprintf("INI-%d", 500+round)
		if _, err := writeRecord("initech", recordWriteArg{Key: key, Section: "decisions", Op: "add", Line: lineArg{Text: str("t0"), Why: str("w0")}, By: "operator"}, time.Now()); err != nil {
			t.Fatal(err)
		}
		var wg sync.WaitGroup
		for _, a := range []recordWriteArg{
			{Key: key, Section: "decisions", Op: "edit", ID: "d1", Line: lineArg{Text: str("t1")}, By: "operator"},
			{Key: key, Section: "decisions", Op: "edit", ID: "d1", Line: lineArg{Why: str("w1")}, By: "agent"},
		} {
			wg.Add(1)
			go func(a recordWriteArg) {
				defer wg.Done()
				if _, err := writeRecord("initech", a, time.Now()); err != nil {
					t.Error(err)
				}
			}(a)
		}
		wg.Wait()
		r, _ := wakilcore.ReadTicketRecord("initech", key)
		if d := r.Decisions[0]; d.Text != "t1" || d.Why != "w1" {
			t.Fatalf("round %d: line = %+v, want both edits", round, d)
		}
	}
}

// review_thread reads only, so it answers outside the window too: the plane asks it before anything is
// posted.
func TestReviewThreadDescribesTheThreadFromGitHub(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	t.Setenv("WAKIL_IN_WINDOW", "")
	cs := connect(t)
	b := call(t, cs, "review_thread", map[string]any{"root": f.repo, "thread": "T_1"})
	var out threadResult
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	want := threadResult{ID: "T_1", Repo: "initech/api", Number: 212, Path: "src/auth/token.go", Line: 41,
		Author: "reviewer", FirstWords: "Nit: name the host"}
	if out != want {
		t.Errorf("thread = %+v", out)
	}
	if msg := callErr(t, cs, "review_thread", map[string]any{"root": f.repo, "thread": "T_gone"}); !strings.Contains(msg, "T_gone") {
		t.Errorf("unknown thread: %q", msg)
	}
}
