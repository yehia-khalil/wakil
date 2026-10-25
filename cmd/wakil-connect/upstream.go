package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"sort"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// dialFunc makes the transport to a connection's real server. Production is upstreamTransport;
// the tests hand in an in-memory one.
type dialFunc func(ctx context.Context, org string, c wakilcore.MCPConnection) (mcp.Transport, error)

// upstreamTransport is the transport to c's real server with org's credentials in place: each
// catalog field with an Env goes into a stdio server's environment, each with a Header onto every
// HTTP request, and a browser sign-in's access token as a Bearer Authorization, refreshed as it
// nears expiry. A secret field's value comes from the Keychain, any other from the record. Any
// connection, custom ones especially, may also keep Keychain keys env:<NAME> (a stdio server's
// environment variable NAME) and header:<Name> (an HTTP header, sent with that exact case).
func upstreamTransport(ctx context.Context, org string, c wakilcore.MCPConnection) (mcp.Transport, error) {
	secrets, err := wakilcore.ConnectionSecrets(org, c.Name)
	if err != nil {
		return nil, err
	}
	var fields []wakilcore.ConnectionField
	for _, k := range wakilcore.ConnectionCatalog {
		if k.ID == c.Kind {
			fields = k.Fields
		}
	}
	value := func(f wakilcore.ConnectionField) string {
		if f.Secret {
			return secrets[f.ID]
		}
		return c.Values[f.ID]
	}
	// prefixed is the secrets kept under prefix, by the name after it, in a stable order.
	prefixed := func(prefix string) [][2]string {
		var out [][2]string
		for k, v := range secrets {
			if name, ok := strings.CutPrefix(k, prefix); ok && name != "" && v != "" {
				out = append(out, [2]string{name, v})
			}
		}
		sort.Slice(out, func(i, j int) bool { return out[i][0] < out[j][0] })
		return out
	}

	switch c.Transport {
	case "stdio":
		cmd := exec.Command(c.Command, c.Args...)
		cmd.Env = upstreamEnv()
		for _, f := range fields {
			if v := value(f); f.Env != "" && v != "" {
				cmd.Env = append(cmd.Env, f.Env+"="+v)
			}
		}
		for _, kv := range prefixed("env:") {
			cmd.Env = append(cmd.Env, kv[0]+"="+kv[1])
		}
		return &mcp.CommandTransport{Command: cmd}, nil
	case "http":
		address := wakilcore.ResolvedConnectionURL(c)
		u, err := url.Parse(address)
		if err != nil || u.Host == "" {
			return nil, wakilcore.UserError("connection " + c.Name + "'s address " + address + " is not a URL")
		}
		// Map assignment, not Set: a header goes out with the case its owner wrote.
		headers := http.Header{}
		for _, f := range fields {
			if v := value(f); f.Header != "" && v != "" {
				name, prefix := headerOf(f.Header)
				headers[name] = []string{prefix + v}
			}
		}
		for _, kv := range prefixed("header:") {
			headers[kv[0]] = []string{kv[1]}
		}
		browser := c.SignIn == "browser"
		if (browser || len(headers) > 0) && !safeForCredentials(u) {
			return nil, wakilcore.UserError("connection " + c.Name + "'s address " + address +
				" is not https: Wakil does not send its credentials in the clear")
		}
		rt := &credentialTransport{base: http.DefaultTransport, origin: origin(u), headers: headers}
		if browser {
			rt.token = func(ctx context.Context) (string, error) { return wakilcore.BrowserToken(ctx, org, c.Name) }
		}
		client := &http.Client{Transport: rt, CheckRedirect: sameOriginRedirect}
		return &mcp.StreamableClientTransport{Endpoint: address, HTTPClient: client}, nil
	}
	return nil, wakilcore.UserError("connection " + c.Name + " has no transport Wakil knows (" + c.Transport + ")")
}

// origin is u's scheme and host: where the credentials may go.
func origin(u *url.URL) string { return u.Scheme + "://" + strings.ToLower(u.Host) }

// sameOriginRedirect refuses a redirect that leaves the server's origin, so neither the call nor
// the credentials follow it somewhere else.
func sameOriginRedirect(req *http.Request, via []*http.Request) error {
	if len(via) >= 10 {
		return errors.New("stopped after 10 redirects")
	}
	if origin(req.URL) != origin(via[0].URL) {
		return errors.New("the server redirected to " + origin(req.URL) + ", another address: Wakil does not follow it")
	}
	return nil
}

// upstreamEnv is this process's environment for a stdio server, less the approval socket: the
// socket is wakil-connect's alone, and the server it starts is someone else's code.
func upstreamEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "WAKIL_APPROVAL_SOCKET=") {
			env = append(env, kv)
		}
	}
	return env
}

// headerOf reads a catalog field's Header: a bare name ("DD_API_KEY") carries the value as it
// is; "Authorization: Bearer" names the header and the word before the value.
func headerOf(spec string) (name, prefix string) {
	name, scheme, ok := strings.Cut(spec, ":")
	if !ok {
		return spec, ""
	}
	if scheme = strings.TrimSpace(scheme); scheme != "" {
		scheme += " "
	}
	return strings.TrimSpace(name), scheme
}

// safeForCredentials is whether u may be sent a secret: https, or http to this machine.
func safeForCredentials(u *url.URL) bool {
	if u.Scheme == "https" {
		return true
	}
	if u.Scheme != "http" {
		return false
	}
	host := u.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// credentialTransport puts the connection's headers, and a fresh browser token when it has one,
// on every request to the real server's origin, and on no other.
type credentialTransport struct {
	base    http.RoundTripper
	origin  string
	headers http.Header
	token   func(context.Context) (string, error)
}

func (t *credentialTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if origin(req.URL) != t.origin {
		return t.base.RoundTrip(req)
	}
	req = req.Clone(req.Context())
	for name, values := range t.headers {
		req.Header[name] = values
	}
	if t.token != nil {
		tok, err := t.token(req.Context())
		if err != nil {
			return nil, err
		}
		req.Header["Authorization"] = []string{"Bearer " + tok}
	}
	return t.base.RoundTrip(req)
}
