package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// TestMain points the Keychain tool at a stand-in that accepts every write and finds nothing,
// so no test here can reach the operator's login keychain. A test that wants items to stay
// (memorySecurity) sets its own over this.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "wakil-connect-security")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	script := filepath.Join(dir, "security")
	body := "#!/bin/sh\ncase \"$1\" in add-generic-password|delete-generic-password) exit 0;; esac\nexit 44\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Setenv("WAKIL_SECURITY_BINARY", script)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// memorySecurity points the Keychain tool at a script that keeps each item in a file.
func memorySecurity(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	body := `#!/bin/sh
d="` + dir + `"
cmd=$1; shift
svc=""; val=""; mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc=$2; shift;;
    -w) if [ "$cmd" = add-generic-password ]; then val=$2; shift; else mode=w; fi;;
  esac
  shift
done
f="$d/$(printf '%s' "$svc" | tr '/:' '__')"
case $cmd in
  add-generic-password) printf '%s' "$val" > "$f"; exit 0;;
  delete-generic-password) rm -f "$f"; exit 0;;
  find-generic-password) [ -f "$f" ] || exit 44; if [ "$mode" = w ]; then cat "$f"; echo; fi; exit 0;;
esac
exit 1
`
	script := filepath.Join(t.TempDir(), "security")
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_SECURITY_BINARY", script)
}

func setupOrg(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_APPROVAL_SOCKET", "")
	if err := wakilcore.CreateOrg("initech", wakilcore.Org{}); err != nil {
		t.Fatal(err)
	}
}

func addConn(t *testing.T, c wakilcore.MCPConnection) {
	t.Helper()
	if _, err := wakilcore.AddConnection("initech", c); err != nil {
		t.Fatal(err)
	}
}

func setSecrets(t *testing.T, name string, values map[string]string) {
	t.Helper()
	if err := wakilcore.SetConnectionSecrets("initech", name, values); err != nil {
		t.Fatal(err)
	}
}

func connFor(t *testing.T, name string) wakilcore.MCPConnection {
	t.Helper()
	c, ok := wakilcore.ConnectionFor("initech", name)
	if !ok {
		t.Fatalf("no connection %s", name)
	}
	return c
}

func ptr(b bool) *bool { return &b }

// upstreamTools is the fake server's list: one of each hint, and one with no annotations.
var upstreamTools = []*mcp.Tool{
	{Name: "read_doc", Description: "Read a document.", Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{"id": map[string]any{"type": "string"}}}},
	{Name: "list_things", Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}, InputSchema: map[string]any{"type": "object"}},
	{Name: "create_issue", Annotations: &mcp.ToolAnnotations{DestructiveHint: ptr(false)},
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{"title": map[string]any{"type": "string"}}}},
	{Name: "delete_repo", Annotations: &mcp.ToolAnnotations{DestructiveHint: ptr(true)}, InputSchema: map[string]any{"type": "object"}},
	{Name: "plain", InputSchema: map[string]any{"type": "object"}},
}

// fakeUpstream is the real server's stand-in: each tool answers "ran <name> <arguments>" and
// records that it ran.
type fakeUpstream struct {
	mu    sync.Mutex
	calls []string
	args  []string
}

func (f *fakeUpstream) ran() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func (f *fakeUpstream) server() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "fake-upstream", Version: "0.0.0"}, nil)
	for _, tool := range upstreamTools {
		s.AddTool(tool, func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			f.mu.Lock()
			f.calls = append(f.calls, req.Params.Name)
			f.args = append(f.args, string(req.Params.Arguments))
			f.mu.Unlock()
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "ran " + req.Params.Name + " " + string(req.Params.Arguments)}}}, nil
		})
	}
	return s
}

func (f *fakeUpstream) dial(t *testing.T) dialFunc {
	return func(ctx context.Context, _ string, _ wakilcore.MCPConnection) (mcp.Transport, error) {
		serverT, clientT := mcp.NewInMemoryTransports()
		ss, err := f.server().Connect(ctx, serverT, nil)
		if err != nil {
			return nil, err
		}
		t.Cleanup(func() { ss.Close() })
		return clientT, nil
	}
}

// fakeSocket is the app's approval socket: it records each request line and answers answer.
type fakeSocket struct {
	path string
	mu   sync.Mutex
	asks []string
}

func (s *fakeSocket) requests() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.asks...)
}

func listenSocket(t *testing.T, answer string) *fakeSocket {
	t.Helper()
	// A unix socket path is limited to about a hundred bytes; t.TempDir is too deep.
	dir, err := os.MkdirTemp("", "wc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	s := &fakeSocket{path: filepath.Join(dir, "a.sock")}
	l, err := net.Listen("unix", s.path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			line, _ := bufio.NewReader(c).ReadString('\n')
			s.mu.Lock()
			s.asks = append(s.asks, strings.TrimSpace(line))
			s.mu.Unlock()
			fmt.Fprintln(c, answer)
			c.Close()
		}
	}()
	t.Setenv("WAKIL_APPROVAL_SOCKET", s.path)
	return s
}

// fronted connects a client to wakil-connect for connection name, fronting up.
func fronted(t *testing.T, name string, dial dialFunc) (context.Context, *mcp.ClientSession) {
	t.Helper()
	ctx := context.Background()
	srv, closeUpstream := newServer(ctx, "initech", name, os.Getenv("WAKIL_APPROVAL_SOCKET"), dial)
	t.Cleanup(closeUpstream)
	serverT, clientT := mcp.NewInMemoryTransports()
	ss, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "agent", Version: "0.0.0"}, nil).Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cs.Close() })
	return ctx, cs
}

func call(t *testing.T, ctx context.Context, cs *mcp.ClientSession, tool string, args map[string]any) (string, bool) {
	t.Helper()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", tool, err)
	}
	var text []string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text = append(text, tc.Text)
		}
	}
	return strings.Join(text, "\n"), res.IsError
}

func github() wakilcore.MCPConnection {
	return wakilcore.MCPConnection{Name: "github", Kind: "github", Transport: "http", URL: "https://api.githubcopilot.com/mcp/", SignIn: "token"}
}

func TestToolsPassThrough(t *testing.T) {
	setupOrg(t)
	addConn(t, github())
	up := &fakeUpstream{}
	ctx, cs := fronted(t, "github", up.dial(t))

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Tools) != len(upstreamTools) {
		t.Fatalf("tools = %d, want %d", len(res.Tools), len(upstreamTools))
	}
	byName := map[string]*mcp.Tool{}
	for _, tool := range res.Tools {
		byName[tool.Name] = tool
	}
	for _, want := range upstreamTools {
		got := byName[want.Name]
		if got == nil {
			t.Fatalf("%s missing", want.Name)
		}
		g, _ := json.Marshal(got)
		w, _ := json.Marshal(want)
		var gm, wm map[string]any
		if err := json.Unmarshal(g, &gm); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(w, &wm); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(gm, wm) {
			t.Fatalf("%s changed on the way through:\n got %s\nwant %s", want.Name, g, w)
		}
	}
}

func TestAllowedReadOnlyForwardsWithoutAsking(t *testing.T) {
	setupOrg(t)
	addConn(t, github())
	sock := listenSocket(t, `{"decision":"deny","message":"should not be asked"}`)
	up := &fakeUpstream{}
	ctx, cs := fronted(t, "github", up.dial(t))

	text, isErr := call(t, ctx, cs, "read_doc", map[string]any{"id": "d-1"})
	if isErr || !strings.Contains(text, `ran read_doc {"id":"d-1"}`) {
		t.Fatalf("read_doc = %q (error %v)", text, isErr)
	}
	if got := sock.requests(); len(got) != 0 {
		t.Fatalf("asked %v", got)
	}
}

type approval struct {
	Connection string         `json:"connection"`
	Tool       string         `json:"tool"`
	Arguments  map[string]any `json:"arguments"`
	Allowed    bool           `json:"allowed"`
	ReadOnly   bool           `json:"readOnly"`
	Locked     bool           `json:"locked"`
}

func TestEveryOtherCallAsks(t *testing.T) {
	setupOrg(t)
	memorySecurity(t)
	c := github()
	c.Allow = map[string]bool{"list_things": false, "create_issue": true}
	addConn(t, c)
	setSecrets(t, "github", map[string]string{"token": "ghp-secret-1"})
	sock := listenSocket(t, `{"decision":"allow"}`)
	up := &fakeUpstream{}
	ctx, cs := fronted(t, "github", up.dial(t))

	cases := []struct {
		tool string
		want approval
	}{
		{"list_things", approval{Allowed: false, ReadOnly: true, Locked: false}},
		{"create_issue", approval{Allowed: true, ReadOnly: false, Locked: false}},
		{"delete_repo", approval{Allowed: false, ReadOnly: false, Locked: true}},
	}
	for i, tc := range cases {
		text, isErr := call(t, ctx, cs, tc.tool, map[string]any{"title": "t-" + tc.tool})
		if isErr || !strings.Contains(text, "ran "+tc.tool) {
			t.Fatalf("%s after allow = %q (error %v)", tc.tool, text, isErr)
		}
		asks := sock.requests()
		if len(asks) != i+1 {
			t.Fatalf("after %s: %d requests, want %d", tc.tool, len(asks), i+1)
		}
		line := asks[i]
		if strings.Contains(line, "ghp-secret-1") {
			t.Fatalf("the request carried a secret: %s", line)
		}
		var got approval
		if err := json.Unmarshal([]byte(line), &got); err != nil {
			t.Fatalf("request %q: %v", line, err)
		}
		want := tc.want
		want.Connection, want.Tool, want.Arguments = "github", tc.tool, map[string]any{"title": "t-" + tc.tool}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("request = %+v, want %+v", got, want)
		}
	}
}

func TestDenyReturnsTheMessageAsToolError(t *testing.T) {
	setupOrg(t)
	addConn(t, github())
	listenSocket(t, `{"decision":"deny","message":"Refused by the operator."}`)
	up := &fakeUpstream{}
	ctx, cs := fronted(t, "github", up.dial(t))

	text, isErr := call(t, ctx, cs, "create_issue", map[string]any{"title": "x"})
	if !isErr || !strings.Contains(text, "Refused by the operator.") {
		t.Fatalf("create_issue = %q (error %v)", text, isErr)
	}
	if got := up.ran(); len(got) != 0 {
		t.Fatalf("a denied call reached the server: %v", got)
	}
}

func TestHeadlessRefusesUnticked(t *testing.T) {
	setupOrg(t)
	c := github()
	c.Allow = map[string]bool{"create_issue": true}
	addConn(t, c)
	up := &fakeUpstream{}
	ctx, cs := fronted(t, "github", up.dial(t))

	if text, isErr := call(t, ctx, cs, "create_issue", map[string]any{"title": "x"}); isErr || !strings.Contains(text, "ran create_issue") {
		t.Fatalf("ticked create_issue = %q (error %v)", text, isErr)
	}
	text, isErr := call(t, ctx, cs, "plain", nil)
	if !isErr || !strings.Contains(text, "Allow agent") || !strings.Contains(text, "github") {
		t.Fatalf("unticked plain = %q (error %v)", text, isErr)
	}
	text, isErr = call(t, ctx, cs, "delete_repo", nil)
	if !isErr || !strings.Contains(text, "github") {
		t.Fatalf("locked delete_repo = %q (error %v)", text, isErr)
	}
	if got := up.ran(); !reflect.DeepEqual(got, []string{"create_issue"}) {
		t.Fatalf("ran %v", got)
	}
}

func TestUnseenToolFollowsItsHint(t *testing.T) {
	setupOrg(t)
	c := github()
	// What the page saw earlier: read_doc was not there, delete_repo was read-only, plain was
	// read-only. The live list wins for every tool on it: plain is listed with no annotations, so
	// it has no hint, and its stored readOnly does not let it through unasked.
	c.Hints = map[string]string{"delete_repo": "readOnly", "plain": "readOnly", "create_issue": "readOnly"}
	addConn(t, c)
	sock := listenSocket(t, `{"decision":"deny","message":"no"}`)
	up := &fakeUpstream{}
	ctx, cs := fronted(t, "github", up.dial(t))

	if text, isErr := call(t, ctx, cs, "read_doc", nil); isErr {
		t.Fatalf("unseen read-only read_doc = %q", text)
	}
	if len(sock.requests()) != 0 {
		t.Fatalf("asked %v", sock.requests())
	}
	call(t, ctx, cs, "plain", nil)
	call(t, ctx, cs, "create_issue", nil)
	call(t, ctx, cs, "delete_repo", nil)
	asks := sock.requests()
	if len(asks) != 3 {
		t.Fatalf("asks = %v", asks)
	}
	var plain, issue, repo approval
	if err := json.Unmarshal([]byte(asks[0]), &plain); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(asks[1]), &issue); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(asks[2]), &repo); err != nil {
		t.Fatal(err)
	}
	if plain.ReadOnly || plain.Allowed || plain.Locked {
		t.Fatalf("plain, listed without annotations, stored readOnly = %+v", plain)
	}
	if issue.ReadOnly || issue.Allowed || issue.Locked {
		t.Fatalf("create_issue, now writes = %+v", issue)
	}
	if !repo.Locked || repo.Allowed || repo.ReadOnly {
		t.Fatalf("delete_repo, now destructive = %+v", repo)
	}
}

func TestFailsClosedWhenTheSocketCannotAnswer(t *testing.T) {
	for _, tc := range []struct{ name, answer string }{
		{"unreachable", ""},
		{"malformed", `{"decision":`},
		{"unknown decision", `{"decision":"maybe"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setupOrg(t)
			addConn(t, github())
			if tc.answer == "" {
				t.Setenv("WAKIL_APPROVAL_SOCKET", filepath.Join(t.TempDir(), "nobody.sock"))
			} else {
				listenSocket(t, tc.answer)
			}
			up := &fakeUpstream{}
			ctx, cs := fronted(t, "github", up.dial(t))
			text, isErr := call(t, ctx, cs, "create_issue", nil)
			if !isErr || !strings.Contains(text, "github") {
				t.Fatalf("create_issue = %q (error %v)", text, isErr)
			}
			if got := up.ran(); len(got) != 0 {
				t.Fatalf("forwarded without an answer: %v", got)
			}
		})
	}
}

func TestUpstreamDownServesNoToolsAndSaysWhy(t *testing.T) {
	setupOrg(t)
	addConn(t, github())
	down := func(context.Context, string, wakilcore.MCPConnection) (mcp.Transport, error) {
		return nil, wakilcore.UserError("dial tcp 127.0.0.1:9: connection refused")
	}
	for _, name := range []string{"github", "nosuch"} {
		ctx, cs := fronted(t, name, down)
		res, err := cs.ListTools(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(res.Tools) != 0 {
			t.Fatalf("%s: tools = %v", name, res.Tools)
		}
		why := cs.InitializeResult().Instructions
		if !strings.Contains(why, name) {
			t.Fatalf("%s: instructions = %q", name, why)
		}
		if name == "github" && !strings.Contains(why, "connection refused") {
			t.Fatalf("instructions = %q", why)
		}
	}
}

// recordingServer is a real streamable HTTP MCP server that keeps the headers of each request.
func recordingServer(t *testing.T) (*httptest.Server, func() http.Header) {
	t.Helper()
	up := &fakeUpstream{}
	h := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return up.server() }, nil)
	var mu sync.Mutex
	var last http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		last = r.Header.Clone()
		mu.Unlock()
		h.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv, func() http.Header {
		mu.Lock()
		defer mu.Unlock()
		return last
	}
}

func dialAndList(t *testing.T, name string) {
	t.Helper()
	ctx := context.Background()
	tr, err := upstreamTransport(ctx, "initech", connFor(t, name))
	if err != nil {
		t.Fatal(err)
	}
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "t", Version: "0"}, nil).Connect(ctx, tr, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	if _, err := cs.ListTools(ctx, nil); err != nil {
		t.Fatal(err)
	}
}

func TestCredentialsInjected(t *testing.T) {
	t.Run("http token, prefixed as its field says", func(t *testing.T) {
		setupOrg(t)
		memorySecurity(t)
		srv, header := recordingServer(t)
		c := github()
		c.URL = srv.URL
		addConn(t, c)
		setSecrets(t, "github", map[string]string{"token": "ghp-1"})
		dialAndList(t, "github")
		if got := header().Get("Authorization"); got != "Bearer ghp-1" {
			t.Fatalf("Authorization = %q", got)
		}
	})
	t.Run("http fields, bare headers", func(t *testing.T) {
		setupOrg(t)
		memorySecurity(t)
		srv, header := recordingServer(t)
		addConn(t, wakilcore.MCPConnection{Name: "datadog", Kind: "datadog", Transport: "http", URL: srv.URL, SignIn: "fields", Values: map[string]string{"site": "datadoghq.eu"}})
		setSecrets(t, "datadog", map[string]string{"apiKey": "api-1", "appKey": "app-1"})
		dialAndList(t, "datadog")
		h := header()
		if h.Get("DD_API_KEY") != "api-1" || h.Get("DD_APPLICATION_KEY") != "app-1" {
			t.Fatalf("headers = %v", h)
		}
	})
	t.Run("browser sign-in, bearer token", func(t *testing.T) {
		setupOrg(t)
		memorySecurity(t)
		srv, header := recordingServer(t)
		addConn(t, wakilcore.MCPConnection{Name: "atlassian", Kind: "atlassian", Transport: "http", URL: srv.URL, SignIn: "browser"})
		setSecrets(t, "atlassian", map[string]string{"access": "bt-1"})
		dialAndList(t, "atlassian")
		if got := header().Get("Authorization"); got != "Bearer bt-1" {
			t.Fatalf("Authorization = %q", got)
		}
	})
	t.Run("stdio env", func(t *testing.T) {
		setupOrg(t)
		memorySecurity(t)
		was := wakilcore.ConnectionCatalog
		wakilcore.ConnectionCatalog = append(append([]wakilcore.ConnectionKind(nil), was...), wakilcore.ConnectionKind{
			ID: "localwiki", Transport: "stdio", Command: "wiki-mcp", SignIn: "fields",
			Fields: []wakilcore.ConnectionField{
				{ID: "space", Label: "Space", Env: "WIKI_SPACE"},
				{ID: "token", Label: "Token", Secret: true, Env: "WIKI_TOKEN"},
			},
		})
		t.Cleanup(func() { wakilcore.ConnectionCatalog = was })
		t.Setenv("WAKIL_APPROVAL_SOCKET", "/somewhere/a.sock")
		addConn(t, wakilcore.MCPConnection{Name: "wiki", Kind: "localwiki", Transport: "stdio", Command: "wiki-mcp", Args: []string{"--serve"}, SignIn: "fields", Values: map[string]string{"space": "eng"}})
		setSecrets(t, "wiki", map[string]string{"token": "wt-1"})
		c := connFor(t, "wiki")
		tr, err := upstreamTransport(context.Background(), "initech", c)
		if err != nil {
			t.Fatal(err)
		}
		cmd := tr.(*mcp.CommandTransport).Command
		env := strings.Join(cmd.Env, "\n")
		if !strings.Contains(env, "WIKI_TOKEN=wt-1") || !strings.Contains(env, "WIKI_SPACE=eng") {
			t.Fatalf("env lacks the fields: %v", cmd.Env)
		}
		if strings.Contains(env, "WAKIL_APPROVAL_SOCKET") {
			t.Fatal("the upstream server was handed the approval socket")
		}
		if !reflect.DeepEqual(cmd.Args, []string{"wiki-mcp", "--serve"}) {
			t.Fatalf("args = %v", cmd.Args)
		}
	})
}

func TestCredentialsNeverSentInTheClear(t *testing.T) {
	setupOrg(t)
	memorySecurity(t)
	c := github()
	c.URL = "http://mcp.example.test/mcp"
	addConn(t, c)
	setSecrets(t, "github", map[string]string{"token": "ghp-1"})
	c = connFor(t, "github")
	_, err := upstreamTransport(context.Background(), "initech", c)
	if msg, ok := wakilcore.IsUserError(err); !ok || !strings.Contains(msg, "https") || strings.Contains(msg, "ghp-1") {
		t.Fatalf("err = %v", err)
	}
}

// TestFrontsARealHTTPServer dials the way main does, so a call made after start-up proves the
// upstream session outlives the start-up limit's context.
func TestFrontsARealHTTPServer(t *testing.T) {
	setupOrg(t)
	memorySecurity(t)
	srv, header := recordingServer(t)
	c := github()
	c.URL = srv.URL
	addConn(t, c)
	setSecrets(t, "github", map[string]string{"token": "ghp-2"})
	ctx, cs := fronted(t, "github", upstreamTransport)
	text, isErr := call(t, ctx, cs, "read_doc", map[string]any{"id": "d-2"})
	if isErr || !strings.Contains(text, "ran read_doc") {
		t.Fatalf("read_doc = %q (error %v)", text, isErr)
	}
	if got := header().Get("Authorization"); got != "Bearer ghp-2" {
		t.Fatalf("Authorization = %q", got)
	}
}

// sentHeaders swaps the bottom of name's HTTP transport for one that keeps each request's headers
// exactly as Wakil built them (a server would see them canonicalised) and answers 200.
func sentHeaders(t *testing.T, name string) (*credentialTransport, *[]*http.Request) {
	t.Helper()
	tr, err := upstreamTransport(context.Background(), "initech", connFor(t, name))
	if err != nil {
		t.Fatal(err)
	}
	rt := tr.(*mcp.StreamableClientTransport).HTTPClient.Transport.(*credentialTransport)
	var sent []*http.Request
	rt.base = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		sent = append(sent, r)
		return &http.Response{StatusCode: 200, Body: http.NoBody, Header: http.Header{}, Request: r}, nil
	})
	return rt, &sent
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestCredentialsStayOnTheServersOrigin(t *testing.T) {
	setupOrg(t)
	memorySecurity(t)
	var elsewhere int
	var mu sync.Mutex
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		elsewhere++
		mu.Unlock()
		if r.Header.Get("Authorization") != "" {
			t.Errorf("the other server got Authorization %q", r.Header.Get("Authorization"))
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(other.Close)
	redirecting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+r.URL.Path, http.StatusTemporaryRedirect)
	}))
	t.Cleanup(redirecting.Close)
	c := github()
	c.URL = redirecting.URL + "/mcp"
	addConn(t, c)
	setSecrets(t, "github", map[string]string{"token": "ghp-3"})

	ctx, cs := fronted(t, "github", upstreamTransport)
	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Tools) != 0 || !strings.Contains(cs.InitializeResult().Instructions, "redirected") {
		t.Fatalf("tools %v, instructions %q", res.Tools, cs.InitializeResult().Instructions)
	}
	mu.Lock()
	defer mu.Unlock()
	if elsewhere != 0 {
		t.Fatalf("the redirect was followed %d times", elsewhere)
	}

	// And the transport itself never puts them on a request for another origin.
	rt, sent := sentHeaders(t, "github")
	req, _ := http.NewRequest("POST", other.URL+"/mcp", nil)
	if _, err := rt.RoundTrip(req); err != nil {
		t.Fatal(err)
	}
	if got := (*sent)[0].Header.Get("Authorization"); got != "" {
		t.Fatalf("another origin got Authorization %q", got)
	}
}

func TestServeClosesTheUpstream(t *testing.T) {
	for _, tc := range []struct {
		name string
		run  func(t *testing.T, dial dialFunc) error
	}{
		{"Run fails", func(t *testing.T, dial dialFunc) error {
			return serve(context.Background(), "github", "", dial, brokenTransport{})
		}},
		{"stopped", func(t *testing.T, dial dialFunc) error {
			ctx, cancel := context.WithCancel(context.Background())
			serverT, _ := mcp.NewInMemoryTransports()
			done := make(chan error, 1)
			go func() { done <- serve(ctx, "github", "", dial, serverT) }()
			time.Sleep(50 * time.Millisecond)
			cancel()
			select {
			case err := <-done:
				return err
			case <-time.After(5 * time.Second):
				t.Fatal("serve did not return when stopped")
				return nil
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setupOrg(t)
			addConn(t, github())
			up := &fakeUpstream{}
			sessions := make(chan *mcp.ServerSession, 1)
			dial := func(ctx context.Context, _ string, _ wakilcore.MCPConnection) (mcp.Transport, error) {
				serverT, clientT := mcp.NewInMemoryTransports()
				ss, err := up.server().Connect(ctx, serverT, nil)
				if err != nil {
					return nil, err
				}
				sessions <- ss
				return clientT, nil
			}
			tc.run(t, dial)
			ss := <-sessions
			closed := make(chan struct{})
			go func() { ss.Wait(); close(closed) }()
			select {
			case <-closed:
			case <-time.After(5 * time.Second):
				t.Fatal("the upstream session is still open")
			}
		})
	}
}

type brokenTransport struct{}

func (brokenTransport) Connect(context.Context) (mcp.Connection, error) {
	return nil, errors.New("stdin is gone")
}

func TestOneArgumentsBytesForTheAppAndTheServer(t *testing.T) {
	setupOrg(t)
	addConn(t, github())
	sock := listenSocket(t, `{"decision":"allow"}`)
	up := &fakeUpstream{}
	ctx, cs := fronted(t, "github", up.dial(t))

	if text, isErr := callRaw(t, ctx, cs, "create_issue", json.RawMessage(`{"repo":"a","repo":"b","n":12345678901234567890}`)); isErr {
		t.Fatalf("create_issue = %q", text)
	}
	if text, isErr := callRaw(t, ctx, cs, "create_issue", json.RawMessage(`null`)); isErr {
		t.Fatalf("create_issue with null = %q", text)
	}
	asks := sock.requests()
	ran := up.ran()
	if len(asks) != 2 || len(ran) != 2 {
		t.Fatalf("asks %v, ran %v", asks, ran)
	}
	up.mu.Lock()
	sentArgs := append([]string(nil), up.args...)
	up.mu.Unlock()
	for i, want := range []string{`{"n":12345678901234567890,"repo":"b"}`, `{}`} {
		var line map[string]json.RawMessage
		if err := json.Unmarshal([]byte(asks[i]), &line); err != nil {
			t.Fatal(err)
		}
		if string(line["arguments"]) != want || sentArgs[i] != want {
			t.Fatalf("call %d: the app saw %s, the server ran %s, want both %s", i, line["arguments"], sentArgs[i], want)
		}
	}
}

func callRaw(t *testing.T, ctx context.Context, cs *mcp.ClientSession, tool string, args json.RawMessage) (string, bool) {
	t.Helper()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", tool, err)
	}
	var text []string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text = append(text, tc.Text)
		}
	}
	return strings.Join(text, "\n"), res.IsError
}

func TestCustomSecretsInjected(t *testing.T) {
	t.Run("http header, exact case", func(t *testing.T) {
		setupOrg(t)
		memorySecurity(t)
		addConn(t, wakilcore.MCPConnection{Name: "wiki", Kind: "custom", Transport: "http", URL: "https://wiki.example.test/mcp", SignIn: "token"})
		setSecrets(t, "wiki", map[string]string{"header:X-API-Key": "xk-1", "env:IGNORED": "e-1"})
		rt, sent := sentHeaders(t, "wiki")
		req, _ := http.NewRequest("POST", "https://wiki.example.test/mcp", nil)
		if _, err := rt.RoundTrip(req); err != nil {
			t.Fatal(err)
		}
		h := (*sent)[0].Header
		if got := h["X-API-Key"]; len(got) != 1 || got[0] != "xk-1" {
			t.Fatalf("headers = %v", h)
		}
		if len(h) != 1 {
			t.Fatalf("headers beyond the one kept: %v", h)
		}
	})
	t.Run("stdio env", func(t *testing.T) {
		setupOrg(t)
		memorySecurity(t)
		addConn(t, wakilcore.MCPConnection{Name: "wiki", Kind: "custom", Transport: "stdio", Command: "wiki-mcp", SignIn: "none"})
		setSecrets(t, "wiki", map[string]string{"env:WIKI_TOKEN": "wt-2", "header:X-Ignored": "h-1"})
		tr, err := upstreamTransport(context.Background(), "initech", connFor(t, "wiki"))
		if err != nil {
			t.Fatal(err)
		}
		env := strings.Join(tr.(*mcp.CommandTransport).Command.Env, "\n")
		if !strings.Contains(env, "\nWIKI_TOKEN=wt-2") || strings.Contains(env, "h-1") {
			t.Fatalf("env = %s", env)
		}
	})
}

func TestUnauthorizedUpstreamSaysWhy(t *testing.T) {
	setupOrg(t)
	memorySecurity(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad credentials", http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)
	c := github()
	c.URL = srv.URL
	addConn(t, c)
	setSecrets(t, "github", map[string]string{"token": "ghp-4"})
	ctx, cs := fronted(t, "github", upstreamTransport)
	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	why := cs.InitializeResult().Instructions
	if len(res.Tools) != 0 || !strings.Contains(why, "github") || !strings.Contains(strings.ToLower(why), "unauthorized") {
		t.Fatalf("tools %v, instructions %q", res.Tools, why)
	}
}

func TestDialErrorsNeverCarryASecret(t *testing.T) {
	setupOrg(t)
	memorySecurity(t)
	addConn(t, github())
	setSecrets(t, "github", map[string]string{"token": "ghp-leaky-5"})
	echo := func(context.Context, string, wakilcore.MCPConnection) (mcp.Transport, error) {
		return nil, errors.New("server said: token ghp-leaky-5 is revoked")
	}
	_, cs := fronted(t, "github", echo)
	why := cs.InitializeResult().Instructions
	if strings.Contains(why, "ghp-leaky-5") || !strings.Contains(why, "is revoked") {
		t.Fatalf("instructions = %q", why)
	}
}

// A custom key Wakil reserves, already in the Keychain item from before the write-time refusal,
// is skipped when the transport is built; the ordinary ones still go.
func TestReservedCustomSecretsSkipped(t *testing.T) {
	t.Run("http", func(t *testing.T) {
		setupOrg(t)
		memorySecurity(t)
		addConn(t, wakilcore.MCPConnection{Name: "wiki", Kind: "custom", Transport: "http", URL: "https://wiki.example.test/mcp", SignIn: "token"})
		raw := `{"header:X-API-Key":"xk-1","header:authorization":"a-1","header:Host":"h-1","header:Content-Type":"c-1","header:Mcp-Session-Id":"m-1"}`
		if err := wakilcore.SecretSetFor("initech", "conn:wiki", raw); err != nil {
			t.Fatal(err)
		}
		rt, sent := sentHeaders(t, "wiki")
		req, _ := http.NewRequest("POST", "https://wiki.example.test/mcp", nil)
		if _, err := rt.RoundTrip(req); err != nil {
			t.Fatal(err)
		}
		h := (*sent)[0].Header
		if len(h) != 1 || h["X-API-Key"][0] != "xk-1" {
			t.Fatalf("headers = %v", h)
		}
	})
	t.Run("stdio", func(t *testing.T) {
		setupOrg(t)
		memorySecurity(t)
		addConn(t, wakilcore.MCPConnection{Name: "wiki", Kind: "custom", Transport: "stdio", Command: "wiki-mcp", SignIn: "none"})
		raw := `{"env:WIKI_TOKEN":"wt-2","env:WAKIL_ORG":"umbrella","env:DYLD_INSERT_LIBRARIES":"d-1","env:NODE_OPTIONS":"n-1","env:Path":"p-1"}`
		if err := wakilcore.SecretSetFor("initech", "conn:wiki", raw); err != nil {
			t.Fatal(err)
		}
		tr, err := upstreamTransport(context.Background(), "initech", connFor(t, "wiki"))
		if err != nil {
			t.Fatal(err)
		}
		env := strings.Join(tr.(*mcp.CommandTransport).Command.Env, "\n")
		if !strings.Contains(env, "WIKI_TOKEN=wt-2") {
			t.Fatalf("env = %s", env)
		}
		for _, v := range []string{"umbrella", "d-1", "n-1", "p-1"} {
			if strings.Contains(env, v) {
				t.Fatalf("reserved value %s injected: %s", v, env)
			}
		}
	})
}

// An organization whose configuration cannot be read is said so, at the start and on a call,
// rather than reported as having no such connection.
func TestUnreadableOrgSaysSo(t *testing.T) {
	setupOrg(t)
	addConn(t, github())
	up := &fakeUpstream{}
	ctx, cs := fronted(t, "github", up.dial(t))
	dir, err := wakilcore.OrgDirFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "org.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	text, isErr := call(t, ctx, cs, "read_doc", nil)
	if !isErr || !strings.Contains(text, "could not read") || strings.Contains(text, "no longer") {
		t.Fatalf("call = %q (error %v)", text, isErr)
	}
	if got := up.ran(); len(got) != 0 {
		t.Fatalf("forwarded: %v", got)
	}
	_, cs2 := fronted(t, "github", up.dial(t))
	why := cs2.InitializeResult().Instructions
	if !strings.Contains(why, "could not read") || strings.Contains(why, "has no connection") {
		t.Fatalf("instructions = %q", why)
	}
}

// A server that never answers is given 20 seconds to start, then the session goes on without it.
func TestStartLimitIsTwentySeconds(t *testing.T) {
	if startLimit != 20*time.Second {
		t.Fatalf("startLimit = %v", startLimit)
	}
}

// Spec amendment 2026-10-26: a connection removed while a session runs refuses at once, even a
// ticked read-only tool, and the app is told — so it journals the refusal — whatever it answers.
// With no app to tell, it is refused all the same.
func TestARemovedConnectionRefusesAndTellsTheApp(t *testing.T) {
	setupOrg(t)
	addConn(t, github())
	up := &fakeUpstream{}
	// One session started with no app to ask, one with the app, both before the removal.
	ctx2, cs2 := fronted(t, "github", up.dial(t))
	sock := listenSocket(t, `{"decision":"allow"}`)
	ctx, cs := fronted(t, "github", up.dial(t))
	if err := wakilcore.RemoveConnection("initech", "github"); err != nil {
		t.Fatal(err)
	}

	text, isErr := call(t, ctx, cs, "read_doc", map[string]any{"id": "d-1"})
	if !isErr || !strings.Contains(text, "no longer") {
		t.Fatalf("read_doc on a removed connection = %q (error %v)", text, isErr)
	}
	asks := sock.requests()
	if len(asks) != 1 {
		t.Fatalf("asked %d times, want 1: %v", len(asks), asks)
	}
	var told struct {
		Connection string `json:"connection"`
		Tool       string `json:"tool"`
		Removed    bool   `json:"removed"`
	}
	if err := json.Unmarshal([]byte(asks[0]), &told); err != nil || !told.Removed || told.Connection != "github" || told.Tool != "read_doc" {
		t.Fatalf("the app was told %q (%v)", asks[0], err)
	}

	if text, isErr := call(t, ctx2, cs2, "read_doc", nil); !isErr || !strings.Contains(text, "no longer") {
		t.Fatalf("headless read_doc on a removed connection = %q (error %v)", text, isErr)
	}
	if got := up.ran(); len(got) != 0 {
		t.Fatalf("a removed connection's call reached the server: %v", got)
	}
}
