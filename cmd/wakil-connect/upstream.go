package main

import (
	"context"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
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
// nears expiry. A secret field's value comes from the Keychain, any other from the record.
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

	switch c.Transport {
	case "stdio":
		cmd := exec.Command(c.Command, c.Args...)
		cmd.Env = upstreamEnv()
		for _, f := range fields {
			if v := value(f); f.Env != "" && v != "" {
				cmd.Env = append(cmd.Env, f.Env+"="+v)
			}
		}
		return &mcp.CommandTransport{Command: cmd}, nil
	case "http":
		address := wakilcore.ResolvedConnectionURL(c)
		headers := http.Header{}
		for _, f := range fields {
			if v := value(f); f.Header != "" && v != "" {
				name, prefix := headerOf(f.Header)
				headers.Set(name, prefix+v)
			}
		}
		browser := c.SignIn == "browser"
		if (browser || len(headers) > 0) && !safeForCredentials(address) {
			return nil, wakilcore.UserError("connection " + c.Name + "'s address " + address +
				" is not https: Wakil does not send its credentials in the clear")
		}
		rt := &credentialTransport{base: http.DefaultTransport, headers: headers}
		if browser {
			rt.token = func(ctx context.Context) (string, error) { return wakilcore.BrowserToken(ctx, org, c.Name) }
		}
		return &mcp.StreamableClientTransport{Endpoint: address, HTTPClient: &http.Client{Transport: rt}}, nil
	}
	return nil, wakilcore.UserError("connection " + c.Name + " has no transport Wakil knows (" + c.Transport + ")")
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

// safeForCredentials is whether address may be sent a secret: https, or http to this machine.
func safeForCredentials(address string) bool {
	u, err := url.Parse(address)
	if err != nil {
		return false
	}
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
// on every request to the real server.
type credentialTransport struct {
	base    http.RoundTripper
	headers http.Header
	token   func(context.Context) (string, error)
}

func (t *credentialTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	for name, values := range t.headers {
		req.Header[name] = values
	}
	if t.token != nil {
		tok, err := t.token(req.Context())
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	return t.base.RoundTrip(req)
}
