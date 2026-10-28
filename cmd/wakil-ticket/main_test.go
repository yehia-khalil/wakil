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
	// replyErrors are GraphQL errors answered beside the posted reply.
	replyErrors []string
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
			answer := map[string]any{"data": map[string]any{"addPullRequestReviewThreadReply": map[string]any{
				"comment": map[string]any{"author": map[string]any{"login": "peter"}, "body": b, "createdAt": "2026-10-26T09:00:00Z"}}}}
			if len(s.replyErrors) > 0 {
				var errs []any
				for _, m := range s.replyErrors {
					errs = append(errs, map[string]any{"message": m})
				}
				answer["errors"] = errs
			}
			body = mustJSON(answer)
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

// A root given through a symlink comes back as given: the window keeps its roots as written and
// compares them by string (Link a ticket…, a thread row's tab), so a resolved root is not one of its own.
func TestTicketBranchRootComesBackAsGiven(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	link := filepath.Join(t.TempDir(), "api-link")
	if err := os.Symlink(f.repo, link); err != nil {
		t.Fatal(err)
	}
	for _, root := range []string{f.repo, link} {
		b := call(t, connect(t), "ticket_branch", map[string]any{"root": root})
		var got TicketBranch
		if err := json.Unmarshal(b, &got); err != nil {
			t.Fatal(err)
		}
		if got.Root != root {
			t.Errorf("root = %q, want %q as given", got.Root, root)
		}
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

func TestReviewReplyPostedBesideErrorsAnswersTheCommentAndTheErrors(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	f.s.replyErrors = []string{"Could not notify subscribers", "Rate limit nearly spent"}
	b := call(t, connect(t), "review_reply", map[string]any{"root": f.repo, "thread": "T_1", "body": "Fixed in 4f1c"})
	var out replyResult
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	if out.Comment.Author != "peter" || out.Comment.Body != "Fixed in 4f1c" {
		t.Errorf("comment = %+v", out.Comment)
	}
	if !reflect.DeepEqual(out.Errors, []string{"Could not notify subscribers", "Rate limit nearly spent"}) {
		t.Errorf("errors = %#v", out.Errors)
	}
	f.s.replyErrors = nil
	var plain map[string]any
	if err := json.Unmarshal(call(t, connect(t), "review_reply", map[string]any{"root": f.repo, "thread": "T_1", "body": "clean"}), &plain); err != nil {
		t.Fatal(err)
	}
	if errs, ok := plain["errors"].([]any); !ok || len(errs) != 0 {
		t.Errorf("a clean post answers errors %#v, want []", plain["errors"])
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
	// Rows carry the root as the project names it, never with its symlinks resolved: the window
	// matches them against its own roots (macOS's temp dir is under the /var -> /private/var link).
	real := f.repo
	none, refs := []string{}, []wakilcore.HandoffRef{}
	at := func(r InFlightRow) InFlightRow {
		r.Root, r.Project, r.Repo = real, "api", "github.com/initech/api"
		if r.PR != 0 {
			r.URL = fmt.Sprintf("https://github.com/initech/api/pull/%d", r.PR)
		}
		if r.Threads == nil {
			r.Threads = none
		}
		if r.Failing == nil {
			r.Failing = none
		}
		r.Handoffs = refs
		return r
	}
	wantInFlight := []InFlightRow{
		at(InFlightRow{Key: "INI-142", Title: "Sign-in keeps the last organization", Status: "In Progress", State: "#212 · open", Branch: "ini-142-login", PR: 212}),
		at(InFlightRow{Key: "INI-150", Title: "Cache the org list", Status: "In Progress", State: "local branch", Branch: "ini-150-cache"}),
		at(InFlightRow{Key: "INI-160", Title: "Retry the token refresh", Status: "In Progress", State: "#220 · open", Branch: "ini-160-retry", PR: 220}),
	}
	if !reflect.DeepEqual(got.InFlight, wantInFlight) {
		t.Errorf("in flight =\n%+v\nwant\n%+v", got.InFlight, wantInFlight)
	}
	wantWaiting := []InFlightRow{
		at(InFlightRow{Key: "INI-142", Title: "Sign-in keeps the last organization", Status: "In Progress", State: "#212 · 1 thread", Branch: "ini-142-login", PR: 212,
			Threads: []string{"T_1"}, Activity: "2026-10-25T10:00:00Z", Count: 1}),
		at(InFlightRow{Key: "INI-160", Title: "Retry the token refresh", Status: "In Progress", State: "checks failing", Branch: "ini-160-retry", PR: 220,
			Failing: []string{"unit"}, Count: 1}),
		at(InFlightRow{Title: "Speed up the build", State: "review requested", Branch: "build-speed", PR: 301, Review: true, Count: 1}),
	}
	if !reflect.DeepEqual(got.WaitingOnYou, wantWaiting) {
		t.Errorf("waiting on you =\n%+v\nwant\n%+v", got.WaitingOnYou, wantWaiting)
	}
	if got.Count != 3 {
		t.Errorf("count = %d, want 3", got.Count)
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

// A record line written with a root and branch names where the ticket is worked on: the record
// gains that branch, by Wakil, beside the ones reads found, and drops none.
func TestRecordWriteWithRootAddsTheBranch(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	read := wakilcore.TicketBranchRef{Repo: "github.com/initech/api", Branch: "ini-142-login", Source: "branch"}
	if err := wakilcore.RecordTicketSeen("initech", "INI-142", wakilcore.TicketSeen{}, []wakilcore.TicketBranchRef{read}, nil); err != nil {
		t.Fatal(err)
	}
	cs := connect(t)
	b := call(t, cs, "ticket_record_write", map[string]any{"key": "INI-142", "section": "next", "op": "set",
		"line": map[string]any{"text": "answer the review"}, "by": "agent", "conversation": "c1",
		"root": f.repo, "branch": "ini-142-review"})
	var r wakilcore.TicketRecord
	if err := json.Unmarshal(b, &r); err != nil {
		t.Fatal(err)
	}
	want := []wakilcore.TicketBranchRef{read, {Repo: "github.com/initech/api", Branch: "ini-142-review", Source: "wakil"}}
	if !reflect.DeepEqual(r.Branches, want) {
		t.Errorf("branches = %+v, want %+v", r.Branches, want)
	}
	if r.Next == nil || r.Next.Text != "answer the review" {
		t.Errorf("next = %+v", r.Next)
	}

	// A branch without a root names no place: the line lands, the branches stay as they were.
	b = call(t, cs, "ticket_record_write", map[string]any{"key": "INI-142", "section": "next", "op": "set",
		"line": map[string]any{"text": "ship it"}, "by": "agent", "branch": "ini-142-other"})
	_ = json.Unmarshal(b, &r)
	if len(r.Branches) != 2 || r.Next == nil || r.Next.Text != "ship it" {
		t.Errorf("branch alone: %+v", r)
	}

	// A root outside the organisation's projects is refused, and nothing is written.
	if msg := callErr(t, cs, "ticket_record_write", map[string]any{"key": "INI-142", "section": "next", "op": "set",
		"line": map[string]any{"text": "elsewhere"}, "by": "agent", "root": t.TempDir(), "branch": "x"}); msg == "" {
		t.Error("an outside root was not refused")
	}
	b = call(t, cs, "ticket_record", map[string]any{"key": "INI-142"})
	_ = json.Unmarshal(b, &r)
	if r.Next == nil || r.Next.Text != "ship it" || len(r.Branches) != 2 {
		t.Errorf("after the refusal: %+v", r)
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

// readInFlightTool calls ticket_in_flight and returns its reply decoded and raw.
func readInFlightTool(t *testing.T) (InFlight, map[string]any) {
	t.Helper()
	b := call(t, connect(t), "ticket_in_flight", map[string]any{})
	var got InFlight
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	_ = json.Unmarshal(b, &raw)
	return got, raw
}

// searchReply answers MyOpenPRs' search with authored and requested.
func searchReply(authored, requested []any) func(gqlRequest) (int, string) {
	return func(gqlRequest) (int, string) {
		if authored == nil {
			authored = []any{}
		}
		if requested == nil {
			requested = []any{}
		}
		return 200, mustJSON(map[string]any{"data": map[string]any{
			"authored": map[string]any{"nodes": authored}, "requested": map[string]any{"nodes": requested}}})
	}
}

// threadAt is a thread whose comments are given as author, createdAt pairs.
func threadAt(id string, pairs ...string) map[string]any {
	var comments []any
	for i := 0; i+1 < len(pairs); i += 2 {
		comments = append(comments, map[string]any{"author": map[string]any{"login": pairs[i]}, "body": "comment", "createdAt": pairs[i+1]})
	}
	return map[string]any{"id": id, "path": "a.go", "line": 1, "isOutdated": false, "isResolved": false, "comments": map[string]any{"nodes": comments}}
}

// A PR with two threads waiting and a failing check is one row that counts 3: the rail counts
// per item, the row carries every reason, and its words are its most urgent one.
func TestInFlightOneRowPerPRCarriesEveryReason(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	f.s.search = searchReply([]any{prNode(212, "INI-142 keep", "ini-142-login", "main",
		[]any{thread("T_1", "a.go", 1, "milton"), thread("T_2", "b.go", 2, "peter", "milton")},
		[]any{check("unit (Linux)", "FAILURE"), check("lint", "SUCCESS")})}, nil)
	got, raw := readInFlightTool(t)
	if len(got.WaitingOnYou) != 1 {
		t.Fatalf("waiting on you = %+v, want one row", got.WaitingOnYou)
	}
	row := got.WaitingOnYou[0]
	if !reflect.DeepEqual(row.Threads, []string{"T_1", "T_2"}) || !reflect.DeepEqual(row.Failing, []string{"unit (Linux)"}) || row.Review {
		t.Errorf("reasons = threads %v failing %v review %v", row.Threads, row.Failing, row.Review)
	}
	if row.Count != 3 || got.Count != 3 {
		t.Errorf("count = row %d reply %d, want 3", row.Count, got.Count)
	}
	if row.State != "#212 · 2 threads" || row.Key != "INI-142" || row.PR != 212 {
		t.Errorf("row = %+v", row)
	}
	if row.Root != f.repo || row.Project != "api" || row.Repo != "github.com/initech/api" || row.URL != "https://github.com/initech/api/pull/212" {
		t.Errorf("place = root %q project %q repo %q url %q", row.Root, row.Project, row.Repo, row.URL)
	}
	w := raw["waitingOnYou"].([]any)[0].(map[string]any)
	if h, ok := w["handoffs"].([]any); !ok || len(h) != 0 {
		t.Errorf("handoffs = %#v, want []", w["handoffs"])
	}
	if _, ok := raw["count"].(float64); !ok {
		t.Errorf("reply has no count: %v", raw)
	}
}

// A PR whose branch, title and body carry no ticket key still waits on the operator: it is a row
// named by its PR, and it counts.
func TestInFlightKeylessPRIsARow(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "main", "")
	f.s.search = searchReply([]any{prNode(215, "Speed up the build", "build-speed", "main", nil, []any{check("unit (Linux)", "FAILURE")})}, nil)
	got, _ := readInFlightTool(t)
	if len(got.WaitingOnYou) != 1 {
		t.Fatalf("waiting on you = %+v", got.WaitingOnYou)
	}
	row := got.WaitingOnYou[0]
	if row.Key != "" || row.PR != 215 || row.Title != "Speed up the build" || row.Branch != "build-speed" || row.State != "checks failing" {
		t.Errorf("row = %+v", row)
	}
	if !reflect.DeepEqual(row.Failing, []string{"unit (Linux)"}) || row.Count != 1 || got.Count != 1 {
		t.Errorf("failing %v count %d reply %d", row.Failing, row.Count, got.Count)
	}
	if row.Repo != "github.com/initech/api" || row.URL == "" || row.Root != f.repo {
		t.Errorf("place = %+v", row)
	}
}

// A review asked of the operator on a repository no project holds counts and shows, with no
// root: it is opened on GitHub, by its URL.
func TestInFlightReviewRequestOutsideEveryProject(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "main", "")
	asked := prNode(7, "INI-142 bill the token", "ini-142-bill", "main", nil, nil)
	asked["url"] = "https://github.com/initech/billing/pull/7"
	asked["author"] = map[string]any{"login": "milton"}
	f.s.search = searchReply(nil, []any{asked})
	got, _ := readInFlightTool(t)
	if len(got.WaitingOnYou) != 1 {
		t.Fatalf("waiting on you = %+v", got.WaitingOnYou)
	}
	row := got.WaitingOnYou[0]
	if row.Root != "" || row.Project != "" || row.URL != "https://github.com/initech/billing/pull/7" || row.Repo != "github.com/initech/billing" {
		t.Errorf("place = root %q project %q url %q repo %q", row.Root, row.Project, row.URL, row.Repo)
	}
	if !row.Review || row.Count != 1 || got.Count != 1 || row.State != "review requested" || row.Key != "INI-142" {
		t.Errorf("row = %+v, reply count %d", row, got.Count)
	}
	if row.Threads == nil || row.Failing == nil {
		t.Errorf("lists are not arrays: %+v", row)
	}
}

// A thread whose last comment is the operator's waits on someone else: not counted, not listed.
func TestInFlightThreadLastWordMineNotCounted(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	f.s.search = searchReply([]any{
		prNode(212, "INI-142 keep", "ini-142-login", "main",
			[]any{thread("T_1", "a.go", 1, "milton", "peter"), thread("T_2", "b.go", 2, "milton")}, nil),
		prNode(213, "INI-150 cache", "ini-150-cache", "main", []any{thread("T_3", "c.go", 3, "milton", "peter")}, nil),
	}, nil)
	got, _ := readInFlightTool(t)
	if len(got.WaitingOnYou) != 1 {
		t.Fatalf("waiting on you = %+v, want only #212", got.WaitingOnYou)
	}
	if row := got.WaitingOnYou[0]; !reflect.DeepEqual(row.Threads, []string{"T_2"}) || row.Count != 1 || got.Count != 1 {
		t.Errorf("row = %+v, reply count %d", row, got.Count)
	}
}

// Two worktrees of one repository are two roots on github.com/initech/api: the PR they share is
// one row, counted once.
func TestInFlightTwoWorktreesCountOnce(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	second := filepath.Join(t.TempDir(), "api-review")
	git(t, f.repo, "worktree", "add", "-q", "-b", "ini-150-cache", second, "main")
	pp := filepath.Join(f.home, "proj", ".wakil", "project.json")
	writeFile(t, pp, `{"name":"api","org":"initech","roots":[{"path":`+jsonString(f.repo)+`},{"path":`+jsonString(second)+`}],"scopes":{"pm":{"provider":"jira","projectKey":"INI"}},"environments":{}}`)
	f.s.search = searchReply([]any{prNode(212, "INI-142 keep", "ini-142-login", "main",
		[]any{thread("T_1", "a.go", 1, "milton"), thread("T_2", "b.go", 2, "milton")},
		[]any{check("unit (Linux)", "FAILURE")})}, nil)
	got, _ := readInFlightTool(t)
	if len(got.WaitingOnYou) != 1 || got.Count != 3 {
		t.Fatalf("waiting on you = %+v, count %d, want one row counting 3", got.WaitingOnYou, got.Count)
	}
	if row := got.WaitingOnYou[0]; row.Root != f.repo {
		t.Errorf("root = %q, want the first root on the repository", row.Root)
	}
}

// A row's activity is the newest of the PR's own last change and its waiting threads' last
// comments; a thread the operator answered last is not activity waiting on them.
func TestInFlightActivityIsNewest(t *testing.T) {
	f := newFixture(t, "git@github.com:initech/api.git", "main", "")
	commented := prNode(212, "INI-142 keep", "ini-142-login", "main", []any{
		threadAt("T_1", "milton", "2026-10-26T11:00:00Z"),
		threadAt("T_2", "milton", "2026-10-26T12:00:00Z", "peter", "2026-10-27T15:00:00Z"),
	}, nil)
	commented["updatedAt"] = "2026-10-25T08:00:00Z"
	pushed := prNode(215, "INI-150 cache", "ini-150-cache", "main",
		[]any{threadAt("T_3", "milton", "2026-10-25T09:00:00Z")}, nil)
	pushed["updatedAt"] = "2026-10-27T12:00:00Z"
	asked := prNode(301, "Speed up the build", "build-speed", "main", nil, nil)
	asked["author"] = map[string]any{"login": "milton"}
	asked["updatedAt"] = "2026-10-24T07:00:00Z"
	f.s.search = searchReply([]any{commented, pushed}, []any{asked})
	got, _ := readInFlightTool(t)
	want := map[int]string{212: "2026-10-26T11:00:00Z", 215: "2026-10-27T12:00:00Z", 301: "2026-10-24T07:00:00Z"}
	if len(got.WaitingOnYou) != 3 {
		t.Fatalf("waiting on you = %+v", got.WaitingOnYou)
	}
	for _, row := range got.WaitingOnYou {
		if row.Activity != want[row.PR] {
			t.Errorf("#%d activity = %q, want %q", row.PR, row.Activity, want[row.PR])
		}
	}
}

func handedTo(conversation string) wakilcore.TicketHandoff {
	return wakilcore.TicketHandoff{Conversation: conversation, Title: "INI-142 · keep the org", Thread: "T_1", Harness: "claude-code",
		Provider: "anthropic", Place: wakilcore.Place{Organization: "initech", Project: "api", Environment: "local"}}
}

// A row carries its ticket's open hand-offs, not the ended ones.
func TestInFlightCarriesOpenHandoffs(t *testing.T) {
	newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	now := time.Now()
	if _, err := wakilcore.AddTicketHandoff("initech", "INI-142", handedTo("c1"), false, now); err != nil {
		t.Fatal(err)
	}
	if _, err := wakilcore.AddTicketHandoff("initech", "INI-142", handedTo("c2"), false, now); err != nil {
		t.Fatal(err)
	}
	if err := wakilcore.EndTicketHandoffs("initech", []string{"c1"}, false, now); err != nil {
		t.Fatal(err)
	}
	got, _ := readInFlightTool(t)
	if len(got.InFlight) != 1 || got.InFlight[0].Key != "INI-142" || got.InFlight[0].State != "local branch" {
		t.Fatalf("in flight = %+v", got.InFlight)
	}
	want := []wakilcore.HandoffRef{{ID: "h2", Conversation: "c2", Thread: "T_1"}}
	if !reflect.DeepEqual(got.InFlight[0].Handoffs, want) {
		t.Errorf("handoffs = %+v, want %+v", got.InFlight[0].Handoffs, want)
	}
}

// A ticket whose only sign of life is a live handed conversation is in flight, in state "agent";
// so is a PR with no ticket key handed to an agent.
func TestInFlightHandoffOnlyTicketIsInFlight(t *testing.T) {
	newFixture(t, "git@github.com:initech/api.git", "main", "")
	now := time.Now()
	if _, err := wakilcore.AddTicketHandoff("initech", "INI-160", handedTo("c1"), false, now); err != nil {
		t.Fatal(err)
	}
	if _, err := wakilcore.AddTicketHandoff("initech", wakilcore.PRHandoffKey("github.com/initech/api", 215), handedTo("c2"), false, now); err != nil {
		t.Fatal(err)
	}
	got, raw := readInFlightTool(t)
	if len(got.InFlight) != 2 {
		t.Fatalf("in flight = %+v", got.InFlight)
	}
	row := got.InFlight[0]
	if row.Key != "INI-160" || row.State != "agent" || row.Title != "Retry the token refresh" || row.Project != "api" ||
		len(row.Handoffs) != 1 || row.Handoffs[0].Conversation != "c1" {
		t.Errorf("ticket row = %+v", row)
	}
	pr := got.InFlight[1]
	if pr.Key != "" || pr.PR != 215 || pr.Repo != "github.com/initech/api" || pr.State != "agent" || len(pr.Handoffs) != 1 ||
		pr.Handoffs[0].Conversation != "c2" {
		t.Errorf("PR row = %+v", pr)
	}
	if got.Count != 0 {
		t.Errorf("a hand-off counts %d, want 0", got.Count)
	}
	r := raw["inFlight"].([]any)[0].(map[string]any)
	if _, ok := r["handoffs"].([]any)[0].(map[string]any)["conversation"]; !ok {
		t.Errorf("row = %v", r)
	}
}

func TestDraftAndHandoffWritesRefusedOutsideTheWindow(t *testing.T) {
	newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	t.Setenv("WAKIL_IN_WINDOW", "")
	cs := connect(t)
	writes := map[string]map[string]any{
		"ticket_draft_write":   {"thread": "T_1", "text": "Fixed", "by": "agent", "conversation": "c1"},
		"ticket_handoff_write": {"op": "add", "key": "INI-142", "handoff": map[string]any{"conversation": "c1", "harness": "claude-code", "provider": "anthropic"}},
	}
	for tool, args := range writes {
		if msg := callErr(t, cs, tool, args); !strings.Contains(msg, "Wakil window") {
			t.Errorf("%s refused with %q, want it to name the Wakil window", tool, msg)
		}
	}
	if m, _ := wakilcore.ReadTicketDrafts("initech"); len(m) != 0 {
		t.Errorf("a refused draft was written: %+v", m)
	}
	if r, _ := wakilcore.ReadTicketRecord("initech", "INI-142"); len(r.Handoffs) != 0 {
		t.Errorf("a refused hand-off was written: %+v", r.Handoffs)
	}
	call(t, cs, "ticket_drafts", map[string]any{})
	call(t, cs, "ticket_handoff_defaults", map[string]any{})
}

func TestDraftToolsWriteReadAndRemove(t *testing.T) {
	newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	cs := connect(t)
	call(t, cs, "ticket_draft_write", map[string]any{"thread": "T_1", "text": "Will fix", "by": "operator"})
	call(t, cs, "ticket_draft_write", map[string]any{"thread": "T_1", "text": "Fixed in 4f1c", "by": "agent", "conversation": "c1",
		"root": "/r/api", "branch": "ini-142-login"})
	var got struct {
		Drafts map[string]wakilcore.TicketDraft `json:"drafts"`
	}
	if err := json.Unmarshal(call(t, cs, "ticket_drafts", map[string]any{}), &got); err != nil {
		t.Fatal(err)
	}
	d := got.Drafts["T_1"]
	if d.Text != "Fixed in 4f1c" || d.By != "agent" || d.Replaced != "Will fix" || d.Conversation != "c1" || d.Branch != "ini-142-login" {
		t.Errorf("draft = %+v", d)
	}
	call(t, cs, "ticket_draft_write", map[string]any{"thread": "T_1", "by": "operator"})
	b := call(t, cs, "ticket_drafts", map[string]any{})
	if !strings.Contains(string(b), `"drafts":{}`) {
		t.Errorf("after removing = %s", b)
	}
}

func TestHandoffToolsAddEndAndDefaults(t *testing.T) {
	newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	cs := connect(t)
	b := call(t, cs, "ticket_handoff_defaults", map[string]any{})
	if !strings.Contains(string(b), `"found":false`) {
		t.Errorf("defaults before any = %s", b)
	}
	b = call(t, cs, "ticket_handoff_write", map[string]any{"op": "add", "key": "INI-142", "mayPush": true,
		"handoff": map[string]any{"conversation": "c1", "title": "INI-142 · keep the org", "thread": "T_1", "harness": "claude-code",
			"provider": "anthropic", "place": map[string]any{"organization": "initech", "project": "api", "environment": "local"}}})
	var added struct {
		Handoff wakilcore.TicketHandoff `json:"handoff"`
	}
	if err := json.Unmarshal(b, &added); err != nil {
		t.Fatal(err)
	}
	if added.Handoff.ID != "h1" || !added.Handoff.MayPush || added.Handoff.Place.Project != "api" {
		t.Errorf("added = %+v", added.Handoff)
	}
	var def struct {
		Defaults wakilcore.HandoffDefaults `json:"defaults"`
		Found    bool                      `json:"found"`
	}
	if err := json.Unmarshal(call(t, cs, "ticket_handoff_defaults", map[string]any{}), &def); err != nil {
		t.Fatal(err)
	}
	if !def.Found || def.Defaults.Harness != "claude-code" || def.Defaults.Provider != "anthropic" || !def.Defaults.MayPush {
		t.Errorf("defaults = %+v", def)
	}
	call(t, cs, "ticket_handoff_write", map[string]any{"op": "end", "conversations": []string{}, "keepLive": true})
	if r, _ := wakilcore.ReadTicketRecord("initech", "INI-142"); len(r.Handoffs) != 1 || r.Handoffs[0].Ended == nil {
		t.Errorf("after ending the stale = %+v", r.Handoffs)
	}
	if msg := callErr(t, cs, "ticket_handoff_write", map[string]any{"op": "move"}); !strings.Contains(msg, "move") {
		t.Errorf("unknown op refused with %q", msg)
	}
}

// May push reads from the stored hand-off, anywhere; a carry gives a resumed conversation the
// hand-off and its May push, and only from the window.
func TestHandoffMayPushAndCarryTools(t *testing.T) {
	newFixture(t, "git@github.com:initech/api.git", "ini-142-login", "Keep the org")
	cs := connect(t)
	if b := call(t, cs, "ticket_handoff_may_push", map[string]any{"conversation": "c1"}); !strings.Contains(string(b), `"mayPush":false`) {
		t.Errorf("before any hand-off = %s", b)
	}
	call(t, cs, "ticket_handoff_write", map[string]any{"op": "add", "key": "INI-142", "mayPush": true,
		"handoff": map[string]any{"conversation": "c1", "thread": "T_1", "harness": "claude-code", "provider": "anthropic"}})
	if b := call(t, cs, "ticket_handoff_may_push", map[string]any{"conversation": "c1"}); !strings.Contains(string(b), `"mayPush":true`) {
		t.Errorf("handed with May push = %s", b)
	}
	b := call(t, cs, "ticket_handoff_write", map[string]any{"op": "carry", "from": "c1", "to": "c2"})
	var carried struct {
		Key     string                   `json:"key"`
		Handoff *wakilcore.TicketHandoff `json:"handoff"`
	}
	if err := json.Unmarshal(b, &carried); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"carried":true`) || carried.Key != "INI-142" || carried.Handoff == nil || carried.Handoff.Conversation != "c2" || carried.Handoff.Thread != "T_1" {
		t.Errorf("carried = %s", b)
	}
	if b := call(t, cs, "ticket_handoff_may_push", map[string]any{"conversation": "c2"}); !strings.Contains(string(b), `"mayPush":true`) {
		t.Errorf("carried May push = %s", b)
	}
	if b := call(t, cs, "ticket_handoff_write", map[string]any{"op": "carry", "from": "c-never", "to": "c3"}); strings.Contains(string(b), `"handoff"`) || !strings.Contains(string(b), `"carried":false`) {
		t.Errorf("a carry from a conversation never handed = %s", b)
	}
	t.Setenv("WAKIL_IN_WINDOW", "")
	cs = connect(t)
	if msg := callErr(t, cs, "ticket_handoff_write", map[string]any{"op": "carry", "from": "c1", "to": "c4"}); !strings.Contains(msg, "Wakil window") {
		t.Errorf("a carry outside the window = %q", msg)
	}
	call(t, cs, "ticket_handoff_may_push", map[string]any{"conversation": "c1"})
}
