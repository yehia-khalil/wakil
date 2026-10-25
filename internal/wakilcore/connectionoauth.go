package wakilcore

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/oauthex"
	"golang.org/x/oauth2"
)

// Browser sign-in for a connection: the MCP authorization flow (protected resource metadata,
// server metadata, dynamic client registration or the operator's own app, PKCE) with the
// redirect on a loopback listener. Start and Wait are two tool calls of the long-lived wakil-ctx
// process, so the pending flow lives in memory between them. Nothing reaches the Keychain until
// Wait has the tokens; they go into the connection's conn:<name> item under access, refresh,
// expiry and client.

var connectionHTTP = &http.Client{Timeout: 30 * time.Second}

// signInLifetime is how long a started sign-in waits for the browser before it closes.
const signInLifetime = 10 * time.Minute

// refreshMargin is how close to expiry a token is refreshed before use.
const refreshMargin = 60 * time.Second

// connectionClient is the client the tokens were issued to: what a refresh needs. It is the
// "client" key of the Keychain item, as JSON.
type connectionClient struct {
	ID        string           `json:"id"`
	Secret    string           `json:"secret,omitempty"`
	TokenURL  string           `json:"tokenUrl"`
	AuthStyle oauth2.AuthStyle `json:"authStyle"`
}

type signInResult struct {
	code, state, iss, err string
}

type signInFlow struct {
	conn     MCPConnection
	cfg      oauth2.Config
	client   connectionClient
	verifier string
	state    string
	resource string
	issuer   string
	checkIss bool
	listener net.Listener
	result   chan signInResult
	done     chan struct{}
	endOnce  sync.Once
	timer    *time.Timer
	timedOut atomic.Bool
}

type signInKey struct{ org, name string }

var (
	signInMu    sync.Mutex
	signInFlows = map[signInKey]*signInFlow{}
)

// end closes the flow's listener, wakes its Wait and forgets it. Safe to call more than once.
func (f *signInFlow) end(key signInKey) {
	f.endOnce.Do(func() {
		f.timer.Stop()
		f.listener.Close()
		close(f.done)
	})
	signInMu.Lock()
	if signInFlows[key] == f {
		delete(signInFlows, key)
	}
	signInMu.Unlock()
}

// StartConnectionSignIn begins org's browser sign-in for connection name and answers the page
// to open. It opens nothing itself: the app opens the browser. A second Start for the same
// connection replaces the first.
func StartConnectionSignIn(ctx context.Context, org, name string) (string, error) {
	c, ok := ConnectionFor(org, name)
	if !ok {
		return "", UserError("no connection " + name + " in " + org)
	}
	if c.SignIn != "browser" || c.Transport != "http" {
		return "", UserError("connection " + name + " does not sign in with the browser")
	}
	preset, err := preregisteredClient(org, c)
	if err != nil {
		return "", err
	}
	prm, err := discoverResource(ctx, c.URL)
	if err != nil {
		return "", err
	}
	issuer := prm.AuthorizationServers[0]
	asm, err := auth.GetAuthServerMetadata(ctx, issuer, connectionHTTP)
	if err != nil {
		return "", UserError("could not read " + name + "'s sign-in details: " + err.Error())
	}
	if asm == nil {
		// The 2025-03-26 MCP spec's default endpoints, when the server publishes no metadata.
		asm = &oauthex.AuthServerMeta{Issuer: issuer, AuthorizationEndpoint: issuer + "/authorize",
			TokenEndpoint: issuer + "/token", RegistrationEndpoint: issuer + "/register"}
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	redirect := fmt.Sprintf("http://127.0.0.1:%d/callback", ln.Addr().(*net.TCPAddr).Port)
	client, err := resolveClient(ctx, name, asm, preset, redirect)
	if err != nil {
		ln.Close()
		return "", err
	}
	f := &signInFlow{
		conn: c, client: client, resource: prm.Resource, issuer: asm.Issuer,
		checkIss: asm.AuthorizationResponseIssParameterSupported,
		verifier: oauth2.GenerateVerifier(), state: randomState(), listener: ln,
		result: make(chan signInResult, 1), done: make(chan struct{}),
		cfg: oauth2.Config{
			ClientID: client.ID, ClientSecret: client.Secret, RedirectURL: redirect, Scopes: prm.ScopesSupported,
			Endpoint: oauth2.Endpoint{AuthURL: asm.AuthorizationEndpoint, TokenURL: asm.TokenEndpoint, AuthStyle: client.AuthStyle},
		},
	}
	key := signInKey{org, name}
	f.timer = time.AfterFunc(signInLifetime, func() {
		f.timedOut.Store(true)
		f.end(key)
	})
	go http.Serve(ln, http.HandlerFunc(f.callback))

	signInMu.Lock()
	old := signInFlows[key]
	signInFlows[key] = f
	signInMu.Unlock()
	if old != nil {
		old.end(key)
	}
	return f.cfg.AuthCodeURL(f.state, oauth2.S256ChallengeOption(f.verifier),
		oauth2.SetAuthURLParam("resource", f.resource)), nil
}

// callback is the loopback redirect: it hands the first answer to Wait and tells the operator
// to go back to Wakil.
func (f *signInFlow) callback(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/callback" {
		http.NotFound(w, r)
		return
	}
	q := r.URL.Query()
	res := signInResult{code: q.Get("code"), state: q.Get("state"), iss: q.Get("iss"), err: q.Get("error")}
	if d := q.Get("error_description"); d != "" {
		res.err += ": " + d
	}
	select {
	case f.result <- res:
	default:
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if res.err != "" {
		fmt.Fprint(w, "<p>Sign-in did not finish. You can close this tab and return to Wakil.</p>")
		return
	}
	fmt.Fprint(w, "<p>Signed in. You can close this tab and return to Wakil.</p>")
}

// WaitConnectionSignIn blocks until the browser comes back to the flow Start began, then keeps
// the tokens and answers the account signed in as. If ctx is cancelled first the flow ends and
// nothing is stored.
func WaitConnectionSignIn(ctx context.Context, org, name string) (string, error) {
	key := signInKey{org, name}
	signInMu.Lock()
	f := signInFlows[key]
	signInMu.Unlock()
	if f == nil {
		return "", UserError("no sign-in to " + name + " is in progress: start it again")
	}
	defer f.end(key)
	var res signInResult
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case <-f.done:
		if f.timedOut.Load() {
			return "", UserError("the sign-in to " + name + " timed out: start it again")
		}
		return "", UserError("the sign-in to " + name + " was replaced by a newer one")
	case res = <-f.result:
	}
	if res.err != "" {
		return "", UserError(name + " refused the sign-in: " + res.err)
	}
	if res.state != f.state {
		return "", UserError("the sign-in to " + name + " came back with the wrong state: nothing was kept")
	}
	if f.checkIss && res.iss != f.issuer {
		return "", UserError("the sign-in to " + name + " came back from the wrong server: nothing was kept")
	}
	tok, err := f.cfg.Exchange(context.WithValue(ctx, oauth2.HTTPClient, connectionHTTP), res.code,
		oauth2.VerifierOption(f.verifier), oauth2.SetAuthURLParam("resource", f.resource))
	if err != nil {
		return "", UserError("could not finish the sign-in to " + name + ": " + err.Error())
	}
	account := tokenAccount(ctx, tok, f.issuer, f.conn.URL)
	client, err := json.Marshal(f.client)
	if err != nil {
		return "", err
	}
	if err := SetConnectionSecrets(org, name, tokenSecrets(tok, string(client))); err != nil {
		return "", err
	}
	return account, nil
}

// BrowserToken is the access token for org's connection name, refreshed first when it expires
// within a minute. A failed refresh leaves the item as it is and asks for a new sign-in.
func BrowserToken(ctx context.Context, org, name string) (string, error) {
	s, err := ConnectionSecrets(org, name)
	if err != nil {
		return "", err
	}
	if s["access"] == "" {
		return "", UserError("connection " + name + " is not signed in: sign in from Settings → Connections")
	}
	if s["expiry"] == "" {
		return s["access"], nil
	}
	expiry, err := time.Parse(time.RFC3339, s["expiry"])
	if err == nil && time.Until(expiry) > refreshMargin {
		return s["access"], nil
	}
	again := UserError("the sign-in to " + name + " has lapsed: sign in again from Settings → Connections")
	var client connectionClient
	if s["refresh"] == "" || json.Unmarshal([]byte(s["client"]), &client) != nil || client.TokenURL == "" {
		return "", again
	}
	cfg := oauth2.Config{ClientID: client.ID, ClientSecret: client.Secret,
		Endpoint: oauth2.Endpoint{TokenURL: client.TokenURL, AuthStyle: client.AuthStyle}}
	tok, err := cfg.TokenSource(context.WithValue(ctx, oauth2.HTTPClient, connectionHTTP),
		&oauth2.Token{RefreshToken: s["refresh"], Expiry: time.Unix(1, 0)}).Token()
	if err != nil {
		return "", again
	}
	if tok.RefreshToken == "" {
		tok.RefreshToken = s["refresh"]
	}
	if err := SetConnectionSecrets(org, name, tokenSecrets(tok, s["client"])); err != nil {
		return "", err
	}
	return tok.AccessToken, nil
}

// SignOutConnection forgets the connection's tokens, keeping the operator's own app credentials.
func SignOutConnection(org, name string) error {
	if _, ok := ConnectionFor(org, name); !ok {
		return UserError("no connection " + name + " in " + org)
	}
	s, err := ConnectionSecrets(org, name)
	if err != nil {
		return err
	}
	for _, k := range []string{"access", "refresh", "expiry", "client"} {
		delete(s, k)
	}
	if len(s) == 0 {
		return SecretDelete(org, connectionRef(name))
	}
	raw, err := json.Marshal(s)
	if err != nil {
		return err
	}
	return SecretSetFor(org, connectionRef(name), string(raw))
}

func tokenSecrets(tok *oauth2.Token, client string) map[string]string {
	out := map[string]string{"access": tok.AccessToken, "refresh": tok.RefreshToken, "expiry": "", "client": client}
	if !tok.Expiry.IsZero() {
		out["expiry"] = tok.Expiry.UTC().Format(time.RFC3339)
	}
	return out
}

// preregisteredClient is the operator's own app for a kind whose catalog entry asks for one
// (Slack): its clientId and clientSecret, from the record's values or the Keychain item. A kind
// that asks for none answers nil and registers itself.
func preregisteredClient(org string, c MCPConnection) (*connectionClient, error) {
	var wants []string
	for _, k := range ConnectionCatalog {
		if k.ID != c.Kind {
			continue
		}
		for _, f := range k.Fields {
			if f.ID == "clientId" || f.ID == "clientSecret" {
				wants = append(wants, f.ID)
			}
		}
	}
	if len(wants) == 0 {
		return nil, nil
	}
	secrets, err := ConnectionSecrets(org, c.Name)
	if err != nil {
		return nil, err
	}
	value := func(id string) string {
		if v := secrets[id]; v != "" {
			return v
		}
		return c.Values[id]
	}
	var missing []string
	for _, id := range wants {
		if value(id) == "" {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		return nil, UserError("connection " + c.Name + " signs in with your own app: fill in " + strings.Join(missing, " and ") + " first")
	}
	return &connectionClient{ID: value("clientId"), Secret: value("clientSecret")}, nil
}

// discoverResource finds the server's protected resource metadata at the two well-known places
// the MCP spec names; with none, the server's own origin is its authorization server (the
// 2025-03-26 spec).
func discoverResource(ctx context.Context, serverURL string) (*oauthex.ProtectedResourceMetadata, error) {
	u, err := url.Parse(serverURL)
	if err != nil || u.Host == "" {
		return nil, UserError("the address " + serverURL + " is not a URL")
	}
	root := *u
	root.Path, root.RawQuery = "", ""
	tries := []struct{ meta, resource string }{
		{root.String() + "/.well-known/oauth-protected-resource/" + strings.TrimLeft(u.Path, "/"), serverURL},
		{root.String() + "/.well-known/oauth-protected-resource", root.String()},
	}
	for _, t := range tries {
		prm, err := oauthex.GetProtectedResourceMetadata(ctx, t.meta, t.resource, connectionHTTP)
		if err != nil || prm == nil {
			continue
		}
		if len(prm.AuthorizationServers) == 0 {
			return nil, UserError("the server at " + serverURL + " names no sign-in server")
		}
		return prm, nil
	}
	return &oauthex.ProtectedResourceMetadata{Resource: serverURL, AuthorizationServers: []string{root.String()}}, nil
}

// resolveClient is the operator's own app when there is one, else a client registered for this
// sign-in (dynamic client registration, RFC 7591).
func resolveClient(ctx context.Context, name string, asm *oauthex.AuthServerMeta, preset *connectionClient, redirect string) (connectionClient, error) {
	if preset != nil {
		preset.TokenURL = asm.TokenEndpoint
		preset.AuthStyle = oauth2.AuthStyleInParams
		for _, m := range asm.TokenEndpointAuthMethodsSupported {
			if m == "client_secret_basic" {
				preset.AuthStyle = oauth2.AuthStyleInHeader
			}
		}
		return *preset, nil
	}
	if asm.RegistrationEndpoint == "" {
		return connectionClient{}, UserError(name + "'s sign-in server does not let Wakil register itself")
	}
	reg, err := oauthex.RegisterClient(ctx, asm.RegistrationEndpoint, &oauthex.ClientRegistrationMetadata{
		RedirectURIs: []string{redirect}, ClientName: "Wakil", ApplicationType: "native",
		GrantTypes: []string{"authorization_code", "refresh_token"}, ResponseTypes: []string{"code"},
		TokenEndpointAuthMethod: "none",
	}, connectionHTTP)
	if err != nil {
		return connectionClient{}, UserError("could not register Wakil with " + name + "'s sign-in server: " + err.Error())
	}
	client := connectionClient{ID: reg.ClientID, Secret: reg.ClientSecret, TokenURL: asm.TokenEndpoint, AuthStyle: oauth2.AuthStyleInParams}
	if reg.ClientSecret != "" && (reg.TokenEndpointAuthMethod == "" || reg.TokenEndpointAuthMethod == "client_secret_basic") {
		client.AuthStyle = oauth2.AuthStyleInHeader
	}
	return client, nil
}

func randomState() string {
	b := make([]byte, 24)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// tokenAccount is who the sign-in is for, as the server reports it: the id token's claims, then
// the OpenID userinfo endpoint; with neither, the server's host. Never the token.
func tokenAccount(ctx context.Context, tok *oauth2.Token, issuer, serverURL string) string {
	if idt, _ := tok.Extra("id_token").(string); idt != "" {
		if parts := strings.Split(idt, "."); len(parts) == 3 {
			if raw, err := base64.RawURLEncoding.DecodeString(parts[1]); err == nil {
				var claims map[string]any
				if json.Unmarshal(raw, &claims) == nil {
					if a := accountClaim(claims); a != "" {
						return a
					}
				}
			}
		}
	}
	if a := userinfoAccount(ctx, tok.AccessToken, issuer); a != "" {
		return a
	}
	if u, err := url.Parse(serverURL); err == nil {
		return u.Host
	}
	return serverURL
}

func accountClaim(claims map[string]any) string {
	for _, k := range []string{"email", "preferred_username", "name", "login"} {
		if v, _ := claims[k].(string); v != "" {
			return v
		}
	}
	return ""
}

func userinfoAccount(ctx context.Context, access, issuer string) string {
	getJSON := func(endpoint, bearer string) map[string]any {
		ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if err != nil {
			return nil
		}
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		resp, err := connectionHTTP.Do(req)
		if err != nil {
			return nil
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil
		}
		var out map[string]any
		if json.NewDecoder(http.MaxBytesReader(nil, resp.Body, 1<<20)).Decode(&out) == nil {
			return out
		}
		return nil
	}
	conf := getJSON(strings.TrimRight(issuer, "/")+"/.well-known/openid-configuration", "")
	endpoint, _ := conf["userinfo_endpoint"].(string)
	if endpoint == "" {
		return ""
	}
	if u, err := url.Parse(endpoint); err != nil || (u.Scheme != "https" && !isLoopbackHost(u.Hostname())) {
		return ""
	}
	return accountClaim(getJSON(endpoint, access))
}

func isLoopbackHost(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
