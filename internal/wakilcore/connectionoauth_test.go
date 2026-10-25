package wakilcore

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAuthServer is an MCP server's authorization side: protected resource metadata, server
// metadata, dynamic registration, an authorize page that answers at once, a token endpoint that
// checks PKCE, and a userinfo endpoint.
type fakeAuthServer struct {
	srv       *httptest.Server
	mu        sync.Mutex
	challenge string
	resource  string
	clientID  string // what /token was called with
	refreshes int
	refuse    bool // /token refuses a refresh
	idToken   string
	expiresIn int
}

// seen is what the server was last called with, read under its lock.
func (f *fakeAuthServer) seen() (resource, clientID string, refreshes int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.resource, f.clientID, f.refreshes
}

func (f *fakeAuthServer) refuseRefresh() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.refuse = true
}

func newFakeAuthServer(t *testing.T) *fakeAuthServer {
	t.Helper()
	f := &fakeAuthServer{expiresIn: 3600}
	mux := http.NewServeMux()
	writeJSON := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(v)
	}
	mux.HandleFunc("/.well-known/oauth-protected-resource/mcp", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"resource": f.srv.URL + "/mcp", "authorization_servers": []string{f.srv.URL}})
	})
	meta := func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"issuer": f.srv.URL, "authorization_endpoint": f.srv.URL + "/authorize",
			"token_endpoint": f.srv.URL + "/token", "registration_endpoint": f.srv.URL + "/register",
			"userinfo_endpoint": f.srv.URL + "/userinfo", "jwks_uri": f.srv.URL + "/jwks",
			"response_types_supported": []string{"code"}, "code_challenge_methods_supported": []string{"S256"},
		})
	}
	mux.HandleFunc("/.well-known/oauth-authorization-server", meta)
	mux.HandleFunc("/.well-known/openid-configuration", meta)
	mux.HandleFunc("/register", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		writeJSON(w, map[string]any{"client_id": "dyn-client", "redirect_uris": body["redirect_uris"]})
	})
	mux.HandleFunc("/authorize", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		f.mu.Lock()
		f.challenge, f.resource = q.Get("code_challenge"), q.Get("resource")
		f.mu.Unlock()
		back := q.Get("redirect_uri") + "?code=code-1&state=" + url.QueryEscape(q.Get("state"))
		http.Redirect(w, r, back, http.StatusFound)
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		f.mu.Lock()
		defer f.mu.Unlock()
		f.clientID = r.Form.Get("client_id")
		if id, _, ok := r.BasicAuth(); ok {
			f.clientID = id
		}
		switch r.Form.Get("grant_type") {
		case "authorization_code":
			sum := sha256.Sum256([]byte(r.Form.Get("code_verifier")))
			if r.Form.Get("code") != "code-1" || base64.RawURLEncoding.EncodeToString(sum[:]) != f.challenge {
				http.Error(w, `{"error":"invalid_grant"}`, http.StatusBadRequest)
				return
			}
			out := map[string]any{"access_token": "at-1", "refresh_token": "rt-1", "token_type": "Bearer", "expires_in": f.expiresIn}
			if f.idToken != "" {
				out["id_token"] = f.idToken
			}
			writeJSON(w, out)
		case "refresh_token":
			if f.refuse || r.Form.Get("refresh_token") != "rt-1" {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				w.Write([]byte(`{"error":"invalid_grant"}`))
				return
			}
			f.refreshes++
			writeJSON(w, map[string]any{"access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer", "expires_in": 3600})
		}
	})
	mux.HandleFunc("/userinfo", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer at-1" {
			http.Error(w, "no", http.StatusUnauthorized)
			return
		}
		writeJSON(w, map[string]any{"sub": "u-1", "email": "ann@initech.test"})
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

// browserConnection records a browser sign-in connection for the fake server under initech.
func browserConnection(t *testing.T, f *fakeAuthServer, kind string) string {
	t.Helper()
	localOrg(t)
	fakeKeychain(t)
	c, err := AddConnection("initech", MCPConnection{Name: "wiki", Kind: kind, Transport: "http", URL: f.srv.URL + "/mcp", SignIn: "browser"})
	if err != nil {
		t.Fatal(err)
	}
	return c.Name
}

// openInBrowser plays the operator's browser: follow the sign-in page to the loopback redirect.
func openInBrowser(t *testing.T, authURL string) {
	t.Helper()
	resp, err := http.Get(authURL)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("redirect page answered %d", resp.StatusCode)
	}
}

func signIn(t *testing.T, name string) string {
	t.Helper()
	ctx := context.Background()
	authURL, err := StartConnectionSignIn(ctx, "initech", name)
	if err != nil {
		t.Fatal(err)
	}
	openInBrowser(t, authURL)
	account, err := WaitConnectionSignIn(ctx, "initech", name)
	if err != nil {
		t.Fatal(err)
	}
	return account
}

func TestSignInStoresTokens(t *testing.T) {
	f := newFakeAuthServer(t)
	name := browserConnection(t, f, "custom")
	account := signIn(t, name)
	if account != "ann@initech.test" {
		t.Fatalf("account = %q", account)
	}
	s, err := ConnectionSecrets("initech", name)
	if err != nil {
		t.Fatal(err)
	}
	if s["access"] != "at-1" || s["refresh"] != "rt-1" || s["client"] == "" {
		t.Fatalf("stored %v", s)
	}
	if exp, err := time.Parse(time.RFC3339, s["expiry"]); err != nil || time.Until(exp) < 50*time.Minute {
		t.Fatalf("expiry %q %v", s["expiry"], err)
	}
	if strings.Contains(s["client"], "at-1") {
		t.Fatal("the client record holds the token")
	}
	if resource, client, _ := f.seen(); resource != f.srv.URL+"/mcp" || client != "dyn-client" {
		t.Fatalf("resource %q client %q", resource, client)
	}
	if _, err := WaitConnectionSignIn(context.Background(), "initech", name); err == nil {
		t.Fatal("the flow outlived its end")
	}
}

func TestSignInAccountFromIDToken(t *testing.T) {
	f := newFakeAuthServer(t)
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"u-2","email":"bob@initech.test"}`))
	f.idToken = "eyJhbGciOiJub25lIn0." + payload + "."
	name := browserConnection(t, f, "custom")
	if account := signIn(t, name); account != "bob@initech.test" {
		t.Fatalf("account = %q", account)
	}
}

func TestBrowserTokenRefreshesWhenExpired(t *testing.T) {
	f := newFakeAuthServer(t)
	f.expiresIn = 30 // inside the 60-second margin
	name := browserConnection(t, f, "custom")
	signIn(t, name)
	tok, err := BrowserToken(context.Background(), "initech", name)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, n := f.seen(); tok != "at-2" || n != 1 {
		t.Fatalf("token %q after %d refreshes", tok, n)
	}
	s, _ := ConnectionSecrets("initech", name)
	if s["access"] != "at-2" || s["refresh"] != "rt-2" {
		t.Fatalf("stored %v", s)
	}
	// Fresh now: no second refresh.
	tok, err = BrowserToken(context.Background(), "initech", name)
	if _, _, n := f.seen(); err != nil || tok != "at-2" || n != 1 {
		t.Fatalf("token %q %v after %d refreshes", tok, err, n)
	}
}

func TestBrowserTokenFailedRefreshSaysSignInAgain(t *testing.T) {
	f := newFakeAuthServer(t)
	f.expiresIn = 30
	name := browserConnection(t, f, "custom")
	signIn(t, name)
	f.refuseRefresh()
	before, _ := ConnectionSecrets("initech", name)
	_, err := BrowserToken(context.Background(), "initech", name)
	if msg, ok := IsUserError(err); !ok || !strings.Contains(msg, "sign in again") {
		t.Fatalf("err = %v", err)
	}
	after, _ := ConnectionSecrets("initech", name)
	if after["access"] != before["access"] || after["refresh"] != before["refresh"] {
		t.Fatalf("item changed: %v", after)
	}
}

func TestSignInCancelledLeavesNothing(t *testing.T) {
	f := newFakeAuthServer(t)
	name := browserConnection(t, f, "custom")
	authURL, err := StartConnectionSignIn(context.Background(), "initech", name)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := WaitConnectionSignIn(ctx, "initech", name); done <- err }()
	cancel()
	if err := <-done; err == nil {
		t.Fatal("a cancelled wait succeeded")
	}
	if s, _ := ConnectionSecrets("initech", name); len(s) != 0 {
		t.Fatalf("stored %v", s)
	}
	redirect, _ := url.Parse(authURL)
	if resp, err := http.Get(redirect.Query().Get("redirect_uri") + "?code=code-1&state=" + redirect.Query().Get("state")); err == nil {
		resp.Body.Close()
		t.Fatal("the loopback listener is still open")
	}
	if _, err := WaitConnectionSignIn(context.Background(), "initech", name); err == nil {
		t.Fatal("the flow was not forgotten")
	}
}

func TestSignInRefusesAMismatchedState(t *testing.T) {
	f := newFakeAuthServer(t)
	name := browserConnection(t, f, "custom")
	authURL, err := StartConnectionSignIn(context.Background(), "initech", name)
	if err != nil {
		t.Fatal(err)
	}
	// The server answers with a good code; only the state is forged on the way back.
	noFollow := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := noFollow.Get(authURL)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	back, _ := url.Parse(resp.Header.Get("Location"))
	q := back.Query()
	q.Set("state", "forged")
	back.RawQuery = q.Encode()
	if resp, err = http.Get(back.String()); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if _, err := WaitConnectionSignIn(context.Background(), "initech", name); err == nil {
		t.Fatal("a forged state was accepted")
	}
	if s, _ := ConnectionSecrets("initech", name); len(s) != 0 {
		t.Fatalf("stored %v", s)
	}
}

func TestSignInWithoutAFlowIsAUserError(t *testing.T) {
	f := newFakeAuthServer(t)
	name := browserConnection(t, f, "custom")
	if _, err := WaitConnectionSignIn(context.Background(), "initech", name); err == nil {
		t.Fatal("no error")
	} else if _, ok := IsUserError(err); !ok {
		t.Fatalf("not a UserError: %v", err)
	}
}

func TestSignInPreregisteredClientNeedsItsFields(t *testing.T) {
	f := newFakeAuthServer(t)
	name := browserConnection(t, f, "slack")
	_, err := StartConnectionSignIn(context.Background(), "initech", name)
	if msg, ok := IsUserError(err); !ok || !strings.Contains(msg, "clientId") || !strings.Contains(msg, "clientSecret") {
		t.Fatalf("err = %v", err)
	}
	if err := SetConnectionSecrets("initech", name, map[string]string{"clientId": "slack-app", "clientSecret": "cs-1"}); err != nil {
		t.Fatal(err)
	}
	signIn(t, name)
	if _, client, _ := f.seen(); client != "slack-app" {
		t.Fatalf("token endpoint saw client %q", client)
	}
}

func TestSignOutForgetsTokens(t *testing.T) {
	f := newFakeAuthServer(t)
	name := browserConnection(t, f, "slack")
	if err := SetConnectionSecrets("initech", name, map[string]string{"clientId": "slack-app", "clientSecret": "cs-1"}); err != nil {
		t.Fatal(err)
	}
	signIn(t, name)
	if err := SignOutConnection("initech", name); err != nil {
		t.Fatal(err)
	}
	s, _ := ConnectionSecrets("initech", name)
	for _, k := range []string{"access", "refresh", "expiry", "client"} {
		if _, ok := s[k]; ok {
			t.Fatalf("%s kept: %v", k, s)
		}
	}
	if s["clientId"] != "slack-app" || s["clientSecret"] != "cs-1" {
		t.Fatalf("app credentials lost: %v", s)
	}
	if _, err := BrowserToken(context.Background(), "initech", name); err == nil {
		t.Fatal("a token after sign-out")
	}
}
