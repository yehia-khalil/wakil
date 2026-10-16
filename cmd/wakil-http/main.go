package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// reqArg is the "request" tool's input. Method/Path are required; Query
// and Headers are optional maps. jsonschema tags on Headers spell out the
// deny list up front (wakilcore.rejectedCallerHeader enforces it), so a
// caller sees the restriction in the tool's own schema instead of
// discovering it only by trial and error.
type reqArg struct {
	// Api names which of the environment's API entries to send against.
	//
	// **Additive and backward compatible** (#183): omitted resolves the
	// single entry of a single-entry environment, exactly as this tool
	// behaved when an environment could hold only one — so a live caller
	// that predates the array keeps working. With several entries an
	// omitted name is ambiguous and is refused rather than guessed at,
	// because guessing would send one backend's credential to another
	// backend's host.
	Api     string            `json:"api,omitempty" jsonschema:"which API entry of the active environment to call; may be omitted only when the environment declares exactly one"`
	Method  string            `json:"method" jsonschema:"GET or HEAD"`
	Path    string            `json:"path" jsonschema:"relative path, joined onto the selected api entry's baseUrl; must not be absolute/protocol-relative, contain \"..\" segments (including percent-encoded, e.g. %2e%2e), contain a backslash (including percent-encoded, e.g. %5C/%5c), or contain a \"#\" fragment"`
	Query   map[string]string `json:"query,omitempty" jsonschema:"query string parameters to add/override"`
	Headers map[string]string `json:"headers,omitempty" jsonschema:"extra request headers; Authorization, Cookie, Host, any Proxy-* header, and the selected api entry's own configured auth header when it is not Authorization, are all rejected — this tool manages authentication and connection headers itself. The refusal names the header, which is the only channel for the configured one: list_apis deliberately does not publish it"`
}

// sendArg is the "send" tool's input. It is reqArg plus the two fields
// that make a write a write — Body and ContentType — and minus nothing:
// an entry is chosen, a path is joined and headers are restricted on
// exactly the same terms, because a send that resolved its target
// differently from a read would be a second set of rules to get right.
//
// Method is its own field rather than four tools, for the reason
// wakil-db has one `mutate` and not one tool per statement kind: the
// verb is data about the request, and a caller choosing between four
// near-identical tools chooses wrong more often than it mistypes a verb
// the gate then names.
type sendArg struct {
	Api         string            `json:"api,omitempty" jsonschema:"which API entry of the active environment to send to; may be omitted only when the environment declares exactly one"`
	Method      string            `json:"method" jsonschema:"POST, PUT, PATCH or DELETE — a read verb is refused and named: GET and HEAD belong to the request tool"`
	Path        string            `json:"path" jsonschema:"relative path, joined onto the selected api entry's baseUrl; the same restrictions the request tool documents apply unchanged"`
	Query       map[string]string `json:"query,omitempty" jsonschema:"query string parameters to add/override"`
	Headers     map[string]string `json:"headers,omitempty" jsonschema:"extra request headers; Authorization, Cookie, Host, any Proxy-* header, Content-Type (use contentType), and the selected api entry's own configured auth header when it is not Authorization, are all rejected"`
	Body        string            `json:"body,omitempty" jsonschema:"the request body, sent verbatim; capped at 1 MiB, and a body over that is refused rather than truncated"`
	ContentType string            `json:"contentType,omitempty" jsonschema:"the body's media type; defaults to application/json. This is the ONLY channel for it — a Content-Type in headers is refused rather than silently overwritten"`
}

// empty is list_apis' argument-less input.
//
// Named for its shape rather than its purpose, as wakil-ctx spells it —
// and NOT as wakil-db does. `listDatabasesArg`'s own doc argues for a
// purpose-named empty type so a later argument has somewhere obvious to
// go; that argument is real, and it is declined here only because
// list_apis mirrors list_databases' OUTPUT rather than its input and this
// server has exactly one such tool. A second one is the moment to rename.
type empty struct{}

// targetEntry resolves the api entry a call names, or returns the tool
// result that refuses it.
//
// **One resolver for both tools, not a test pinning two copies.** request
// and send must agree about which entry a name resolves to, what an
// omitted name means in a multi-entry environment, and what an entry with
// no baseUrl is — and until this existed they agreed only because the two
// handlers had been written the same way on the same afternoon. A change
// to entry resolution that fixed one and forgot the other would have sent
// a write somewhere a read would have refused to go.
//
// It returns the refusal as a *mcp.CallToolResult rather than an error
// because that is what both handlers hand back: a server-side tool
// failure is a successful CALL carrying isError, and only a transport
// failure is an error here.
func targetEntry(name string) (wakilcore.ApiConfig, *mcp.CallToolResult) {
	env, err := wakilcore.ResolveEnvironment()
	if err != nil {
		return wakilcore.ApiConfig{}, mcpx.ToolErr("wakil-http", err)
	}
	entry, err := wakilcore.PickAPI(env, name)
	if err != nil {
		return wakilcore.ApiConfig{}, mcpx.ToolErr("wakil-http", err)
	}
	if entry.BaseURL == "" {
		return wakilcore.ApiConfig{}, mcpx.ToolErr("wakil-http",
			wakilcore.UserError("api entry "+entry.Name+" has no baseUrl configured"))
	}
	return entry, nil
}

// newServer builds the wakil-http MCP server with its three tools
// registered — request, send and list_apis. Extracted from main so it
// (and the tools it wires up) is reachable from tests, mirroring
// cmd/wakil-db and cmd/wakil-pm's newServer.
//
// request and send are the read/write pair wakil-db's query and mutate
// already are, with one difference that belongs to this server alone:
// mutate refuses on a SECOND CREDENTIAL the environment may or may not
// configure, and an api entry has only one. So send's gate is the window
// marker instead — see wakilcore's httpsend.go for why the difference is
// forced rather than chosen.
func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-http", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "request", Description: "GET/HEAD against the active environment's API baseUrl (relative paths only — no absolute/protocol-relative paths, no \"#\" fragment, and no \"..\" segment or backslash, including percent-encoded (single-decode only: a double-encoded %252e is passed through as an inert literal); every request is bound to that origin, and any server-side redirect elsewhere is refused). The response body is capped and may be truncated (see the truncated field); Authorization, Cookie, Host and Proxy-* request headers cannot be set by the caller — this tool manages authentication itself from the environment's configured credential."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a reqArg) (*mcp.CallToolResult, wakilcore.HTTPResult, error) {
			entry, fail := targetEntry(a.Api)
			if fail != nil {
				return fail, wakilcore.HTTPResult{}, nil
			}
			// Controller ruling 8, enforced by DoRequest itself
			// (fix-round Minor 4): DoRequest validates the entry's
			// baseUrl via NormalizeHTTPBase — absolute, https, no
			// userinfo/query/fragment — before ever building a request
			// from it, so this handler needs no separate call; the gate
			// lives on the operation rather than on this one caller. A
			// baseUrl carrying userinfo would be a second credential
			// channel entirely outside the Keychain.
			out, err := wakilcore.DoRequest(ctx, entry.BaseURL, a.Method, a.Path, a.Query, a.Headers, entry.AuthRef, entry.Header())
			if err != nil {
				return mcpx.ToolErr("wakil-http", err), wakilcore.HTTPResult{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "send", Description: "POST/PUT/PATCH/DELETE with a body against the active environment's chosen api entry — the write counterpart of request, which stays read-only. ONLY AVAILABLE INSIDE THE WAKIL WINDOW: a wakil-http registered into a provider's own config dir answers request and refuses every send, because outside the window there is no pane showing the request before it leaves or the result after. The body is sent verbatim, defaults to application/json, and is capped at 1 MiB — a larger one is refused, naming the limit, and never truncated or silently sent. Everything request refuses is refused here too: relative paths only (no absolute/protocol-relative path, no \"#\" fragment, no \"..\" segment or backslash, including percent-encoded), every request bound to the entry's own origin with any server-side redirect refused rather than followed (a 307 or 308 carries this method and this body with it, so following one would repeat the write against a host nobody reviewed), and Authorization, Cookie, Host, Proxy-* and Content-Type headers managed by this tool rather than set by the caller. The response is capped and may be truncated (see the truncated field)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a sendArg) (*mcp.CallToolResult, wakilcore.HTTPResult, error) {
			entry, fail := targetEntry(a.Api)
			if fail != nil {
				return fail, wakilcore.HTTPResult{}, nil
			}
			// DoSend, not doSend: the exported entry point validates
			// the base itself before anything else, exactly as
			// DoRequest does above, so this handler cannot be the
			// place a cleartext connection is introduced.
			out, err := wakilcore.DoSend(ctx, entry.BaseURL, a.Method, a.Path, a.Query, a.Headers, a.Body, a.ContentType, entry.AuthRef, entry.Header())
			if err != nil {
				return mcpx.ToolErr("wakil-http", err), wakilcore.HTTPResult{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_apis", Description: "List the named API entries of the active environment, under an apis key. Each entry carries its name, its baseUrl, and authenticated: whether a credential is configured for it. authenticated true means only that a credential is CONFIGURED — never that it is valid or sufficient; a request may still come back 401. The list is always complete — it is read whole from the active project's configuration, never paged or capped — so an empty apis array means the environment declares no API entries. Pass a name to request's api field to choose between them."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.ApiList, error) {
			env, err := wakilcore.ResolveEnvironment()
			if err != nil {
				return mcpx.ToolErr("wakil-http", err), wakilcore.NewApiList(nil), nil
			}
			return nil, wakilcore.NewApiList(env.API), nil
		})

	type parseCurlArg struct {
		Text string `json:"text" jsonschema:"the pasted text, starting with curl"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "parse_curl", Description: "Read a cURL command (POSIX shell quoting, as a browser's Copy as cURL (bash) writes it) and answer the request curl would send: method, url, headers, body. READ-ONLY and pure: no network, no configuration, no file read, nothing sent. What Wakil does not carry — a credential or cookie header, -u, -b, -F, a body read from a file, -k, an unknown flag, a body on a GET, a #fragment — is listed in dropped BY NAME with a reason, and its value is never returned. Flags that only change curl (-s, -v, -L, --compressed, -o, …) are listed in ignored."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a parseCurlArg) (*mcp.CallToolResult, wakilcore.CurlRequest, error) {
			r, err := wakilcore.ParseCurl(a.Text)
			if err != nil {
				return mcpx.ToolErr("wakil-http", err), wakilcore.CurlRequest{}, nil
			}
			return nil, r, nil
		})

	type locateArg struct {
		URL string `json:"url" jsonschema:"an absolute URL"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "locate_api_url", Description: "Say which API entry an absolute URL belongs to: the same origin (scheme, host, port) and a path at or under the entry's base path, the longest base path winning. The active environment is searched first (active true), then the project's other environments by name (active false, environment names where). found false means no entry in the project has that origin and path; entries then lists the active environment's entry names. READ-ONLY: reads the project configuration and nothing else."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a locateArg) (*mcp.CallToolResult, wakilcore.APILocation, error) {
			r, err := wakilcore.Resolve()
			if err != nil {
				return mcpx.ToolErr("wakil-http", err), wakilcore.APILocation{}, nil
			}
			return nil, wakilcore.LocateAPIURL(*r.Project, r.Environment, a.URL), nil
		})

	return s
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
