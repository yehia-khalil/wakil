package wakilcore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// httpBodyCap bounds how much of an HTTP response body is ever handed
// back in an MCP tool result — i.e. straight into the model's context.
// This follows the Rows.Truncated / IssuePage.Truncated precedent
// (dbdriver.go, jira.go): a struct-typed result carries an explicit
// Truncated flag rather than silently trusting a fixed-size read as
// though it were the whole response.
//
// 64KiB, not the 1MiB a naive implementation might use: 1MiB of text
// landing in a single tool result is not a body cap, it is the entire
// context budget of a small model in one call. 64KiB is still generous
// for the JSON API responses this tool exists to fetch, while being far
// below the point where a single tool call can dominate a conversation's
// context window.
//
// This is a package-level VAR, not a const (fix-round Important-1):
// solely so this file's own tests can lower it temporarily — save the
// old value, assign a small one, t.Cleanup to restore — and exercise the
// cap-straddling / doubled-echo / partial-suffix-at-the-cap code paths
// with small, readable httptest fixtures instead of ones tens of
// kilobytes long. Production code never assigns to this var;
// TestHTTPBodyCapDefaultIsProductionValue pins that the shipped default
// is still exactly 64KiB.
var httpBodyCap = 64 * 1024

// HTTPResult is what the "request" MCP tool returns.
type HTTPResult struct {
	Status int `json:"status"`
	// Headers maps each SCRUBBED response header name to its SCRUBBED
	// value. Two distinct wire header names that scrub to the same
	// string (or a single header sent with multiple values on the wire)
	// have ALL of their values joined with ", " here, rather than one
	// silently overwriting the other in this map or Header.Get silently
	// keeping only the first — see the header-building comment in
	// doRequest for why both would otherwise be a silent, undetectable
	// loss of exactly the kind Truncated exists to avoid.
	Headers map[string]string `json:"headers,omitempty"`
	Body    string            `json:"body"`
	// Truncated is true when the response body was cut short of its full
	// length, or when a read error left us unable to confirm it wasn't —
	// see the "fail toward assume more" posture IssuePage.Truncated
	// documents for the identical asymmetry: a spuriously-true Truncated
	// costs one harmless extra look, a spuriously-false one is a
	// silently incomplete answer trusted as complete.
	Truncated bool `json:"truncated,omitempty"`
}

// NormalizeHTTPBase validates an environment's API.BaseURL the way
// normalizeJiraBase (jira.go) validates a Jira base URL, whether it came
// from WAKIL_JIRA_BASE, org.json's jiraBase, or the --jira-base flag:
// absolute, https, no userinfo, no query string, no fragment.
//
// No rejection echoes the raw input, or url.URL.Redacted() of it. An
// earlier version used Redacted() on the stated grounds that a baseUrl
// carrying userinfo — a second credential channel entirely outside the
// Keychain — must never be echoed back to whatever reads the error. That
// was the right goal and the wrong tool: Redacted() masks ONLY a userinfo
// PASSWORD, so "https://<token>@host" (no colon, hence no password to
// mask), "https://host?token=<token>" and "https://host#token=<token>"
// were all echoed WHOLE. Measured on all three, plus the scheme-relative
// and opaque-URL forms. Every message now reports scheme://host via
// safeBaseHint (jira.go), which DROPS userinfo, path, query and fragment
// rather than redacting them — see that function for the full reasoning.
//
// The path is dropped from the HINT even though a path is legal in the
// value itself (see below): "https://host/v2/<token>?x=1" rejects for its
// query string, and echoing the path back to explain that would hand over
// a token an operator had put somewhere else in the same URL. The host is
// what identifies which baseUrl was misconfigured; the rest is the part
// being complained about.
//
// Unlike normalizeJiraBase, a PATH is allowed and preserved: doRequest
// (below) joins the caller's relative path onto base, so a base carrying
// an API-version path prefix (e.g. "https://api.example.com/v2") is a
// legitimate configuration this generic HTTP server must support, where
// Jira's base never carries one (jira.go hardcodes its own fixed API
// paths onto an origin-only base).
//
// The exported DoRequest (below) calls this itself, FIRST, before doing
// anything else — fix-round Minor 4: the gate lives on the operation,
// not merely on cmd/wakil-http's caller, so DoRequest can never be
// invoked (now, or by some future caller that forgets to normalize
// first) with an unvalidated base and put the Keychain-held auth token
// on a cleartext http:// connection. The unexported doRequest is the
// low-level primitive that TRUSTS base was already validated (mirroring
// JiraClient.search, which trusts BaseURL was already validated by
// normalizeJiraBase at construction time), and it is what this file's
// tests call directly, against a plain http:// httptest server — exactly
// as JiraClient's own tests construct a JiraClient directly, bypassing
// NewJiraFromEnv's https requirement, to test the request machinery in
// isolation.
func NormalizeHTTPBase(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", UserError("this environment's API baseUrl must be an absolute https URL")
	}
	if !u.IsAbs() || u.Scheme != "https" || u.Host == "" {
		return "", UserError("this environment's API baseUrl must be an absolute https URL" + safeBaseHint(u))
	}
	if u.User != nil {
		return "", UserError("this environment's API baseUrl must not contain credentials — store the auth token in the Keychain, not the baseUrl" + safeBaseHint(u))
	}
	if u.RawQuery != "" {
		return "", UserError("this environment's API baseUrl must not contain a query string" + safeBaseHint(u))
	}
	if u.Fragment != "" {
		return "", UserError("this environment's API baseUrl must not contain a fragment" + safeBaseHint(u))
	}
	return strings.TrimRight(u.String(), "/"), nil
}

// validateRelativePath rejects, textually, on the caller's raw path
// argument, before any concatenation or network call:
//
//   - an absolute URL ("://") or a protocol-relative path (leading "//")
//     — either would try to escape the environment's baseUrl to an
//     arbitrary host if this code ever changed to use URL-reference
//     resolution instead of plain string concatenation, and rejecting
//     them outright costs nothing today while keeping that invariant
//     independent of how the join is implemented;
//   - a "#" character — once concatenated onto base and re-parsed as one
//     URL string, everything after a "#" becomes a fragment and is
//     NEVER SENT to the server at all, so the caller would believe it
//     requested one path while silently receiving a response for a
//     shorter, truncated one;
//   - a backslash — an ordinary path character to RFC 3986 and to Go's
//     url package, so "/x\..\..\y" has no ".." SEGMENT and slips past
//     the scan below, but plenty of servers (IIS, some Java stacks,
//     path-normalising proxies) treat "\" as a separator and would
//     traverse. Percent-encoding it as %5C/%5c is NOT an escape hatch:
//     that is rejected too, structurally, against the DECODED path in
//     doRequest (see the backslash check next to containsDotDotSegment
//     there) — an earlier version of this comment claimed
//     containsDotDotSegment itself already covered that case, which was
//     false (that function only ever matches a segment equal to "..",
//     never a "\.." shape) and has been corrected;
//   - a literal ".." path segment — a same-host path traversal past
//     whatever prefix baseUrl's own path carries (unlike Jira's base,
//     this one may legitimately carry a path — see NormalizeHTTPBase).
//
// This is layer one of two (see the structural, decoded-path checks in
// doRequest below, which additionally catch a percent-encoded "%2e%2e"
// or "%5c" that this textual scan cannot see, since the caller's raw
// text never contains a literal ".." or "\" in either of those cases).
// Both layers are kept, on the standing project rule that a textual
// guard on caller input can be talked around but a structural check on
// the final, resolved destination cannot.
func validateRelativePath(path string) error {
	if strings.Contains(path, "://") || strings.HasPrefix(path, "//") {
		return UserError("only relative paths are allowed; requests are bound to the environment's baseUrl")
	}
	if strings.ContainsRune(path, '#') {
		return UserError("path must not contain a fragment (\"#\") — it would silently truncate the request")
	}
	// A backslash is an ordinary path character to RFC 3986 and to Go's
	// url package, so "/x\..\..\y" has no ".." SEGMENT and slips past the
	// scan below — but plenty of servers (IIS, some Java stacks,
	// path-normalising proxies) treat "\" as a separator and would
	// traverse. Rejecting the character outright makes our reading and
	// theirs agree, which is the same move that settled the JQL escape in
	// wakil-pm: do not try to model the other parser, remove the
	// construct that makes the two disagree. Percent-encoding the
	// backslash (%5C/%5c) is NOT an escape hatch: it is rejected too,
	// structurally, against the DECODED path — see the backslash check
	// next to containsDotDotSegment in doRequest.
	if strings.ContainsRune(path, '\\') {
		return UserError("path must not contain a backslash — not even percent-encoded (%5C/%5c); no path component may use one")
	}
	for _, seg := range strings.Split(path, "/") {
		if seg == ".." {
			return UserError("path must not contain \"..\" segments")
		}
	}
	return nil
}

// containsDotDotSegment reports whether urlPath (a DECODED url.URL.Path,
// not the raw wire-encoded form) contains a literal ".." segment. Run
// against the final joined-and-parsed URL's Path, this catches a
// percent-encoded "%2e%2e" the caller supplied — url.Parse decodes it to
// ".." in Path — even though validateRelativePath's textual scan of the
// caller's raw, still-encoded path argument never sees a literal ".." to
// reject.
//
// This guard is SINGLE-decode by design, not double-decode: url.Parse
// decodes exactly one level of percent-encoding, so a DOUBLY-encoded
// "%252e%252e" decodes here to the literal, inert segment "%2e%2e" — not
// "..". That form reaches the upstream server as that same literal
// "%2e%2e" segment; only a server that itself percent-decodes twice
// would ever traverse on it, and modelling that second decode here is
// out of scope (see validateRelativePath's doc comment for the project
// rule this follows: match the server's actual parsing, don't try to
// out-guess every possible one). A reader should not assume
// "%252e%252e" is rejected here — it isn't, and is not meant to be.
func containsDotDotSegment(urlPath string) bool {
	for _, seg := range strings.Split(urlPath, "/") {
		if seg == ".." {
			return true
		}
	}
	return false
}

// deniedCallerHeaderNames is the set of header names a caller must never
// be allowed to set on this tool's request, keyed lowercase for
// case-insensitive comparison. Every request doRequest sends is already
// credentialed (an Authorization header, once authRef resolves); letting
// a caller set headers with no restriction at all would let it override
// Authorization outright, inject a Cookie, or steer the request through
// a proxy of its choosing via Proxy-*.
//
// **The entry's CONFIGURED auth header joins this set dynamically** (#183).
// An entry may authenticate through `X-API-Key` rather than Authorization,
// and Wakil already wins by ordering — the credential is set after the
// caller's headers, so a collision is overwritten rather than honoured. But
// a caller whose header is silently overwritten has a latent bug it will
// never find, and `Host` is the precedent for refusing explicitly rather
// than ignoring quietly: it is refused even though net/http ignores it
// anyway, because a caller believing it worked is the failure.
var deniedCallerHeaderNames = map[string]bool{
	"authorization": true,
	"cookie":        true,
	"host":          true,
}

// rejectedCallerHeader reports whether name is a header doRequest must
// refuse to let a caller set. Host is included even though Go's
// net/http silently ignores a Host set via Header.Set (the wire Host
// comes only from Request.Host) — a caller believing it worked is its
// own latent bug, and rejecting it explicitly is more honest than
// quietly ignoring it.
func rejectedCallerHeader(name, authHeader string) bool {
	n := strings.ToLower(strings.TrimSpace(name))
	if deniedCallerHeaderNames[n] {
		return true
	}
	// The entry's configured header, resolved the same way doRequest
	// resolves it — so the name refused here and the name written there
	// cannot drift. An unconfigured authHeader resolves to Authorization,
	// which the static map already holds, so this adds no name in that
	// case rather than making the empty string a denied one.
	if n == strings.ToLower(ResolveAuthHeader(authHeader)) {
		return true
	}
	return strings.HasPrefix(n, "proxy-")
}

// redirectRefusedError is returned by the http.Client's CheckRedirect
// hook (see noRedirectClient) to refuse every redirect outright, exactly
// as JiraClient's errJiraRedirect does (jira.go) — a read-only GET/HEAD
// API has no legitimate reason to redirect, and Go's default client
// policy follows up to 10 redirects to whatever host the server names,
// which would let a server at the environment's own baseUrl redirect a
// request to an arbitrary host (an internal service, or a cloud
// metadata address such as 169.254.169.254), defeating the "requests
// are bound to the environment's baseUrl" guarantee this tool's
// description makes. Unlike errJiraRedirect, this carries the 3xx status
// and Location header the server sent, because surfacing THAT is more
// informative to a human than a bare "refusing to follow" — obtained via
// req.Response, which net/http populates with the redirect response that
// caused CheckRedirect to be invoked (CheckRedirect's own req parameter
// is the NEXT request it is considering, not a response, so this is the
// only way to recover the 3xx status/Location from inside the hook).
type redirectRefusedError struct {
	status   int
	location string
}

func (e *redirectRefusedError) Error() string {
	loc := e.location
	if loc == "" {
		// Defensive, like the structural host/scheme check in doRequest:
		// every real 3xx response that reaches this path carries a
		// Location header (that's what makes it a redirect at all), so
		// this branch has no known live trigger — but Header.Get returns
		// "" on a missing key without erroring, so a malformed or
		// adversarial server that omits Location on a 3xx must still get
		// a clear message here instead of an empty, confusing one.
		loc = "(no Location header)"
	}
	return fmt.Sprintf("server returned %d and tried to redirect to %s; refusing to follow", e.status, loc)
}

// noRedirectClient is a shared *http.Client that refuses every redirect
// (see redirectRefusedError). http.Client is documented safe for
// concurrent use by multiple goroutines, so one package-level instance —
// mirroring JiraClient.client()'s lazily-built, per-instance client — is
// safe to share across every doRequest call.
var noRedirectClient = &http.Client{
	Timeout: 20 * time.Second,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		status := 0
		loc := ""
		// Defensive: net/http only invokes CheckRedirect while following
		// a redirect, i.e. exactly when req.Response — the response that
		// triggered this call — is non-nil; there is no known way to
		// reach this hook with a nil Response. Kept anyway, the same way
		// the structural host/scheme check in doRequest is kept despite
		// being unreachable via that function's own join strategy: it is
		// cheap insurance against a future net/http behavior change,
		// not a guarantee this package owns enough to assert on.
		if req.Response != nil {
			status = req.Response.StatusCode
			loc = req.Response.Header.Get("Location")
		}
		return &redirectRefusedError{status: status, location: loc}
	},
}

// doHTTP is the low-level primitive shared by the read and the send: it
// issues ONE request against base, joining path onto it, and returns a
// scrubbed, capped HTTPResult. A nil send is a read — no body, no
// content type; a non-nil one carries both.
//
// **The verb gate is the CALLER'S**, and deliberately so. doRequest
// asserts read-only, doSend asserts a mutation verb and the window
// marker, and this function asserts neither: one function that took a
// "may write" boolean would be one place where a future edit could
// arm the write path for the read caller. Everything below this line
// is identical for both, which is the point — the join, the escape
// guards, the header denials, the redirect refusal and the scrubbing
// are one implementation, not two that must be kept in agreement.
//
// It TRUSTS base was already validated (see
// NormalizeHTTPBase) — it only requires base to parse as an absolute
// URL — which is deliberate: it is what this file's tests call directly
// against a plain http:// httptest server, exactly as JiraClient.search
// trusts BaseURL was already validated by normalizeJiraBase and is
// tested the same way.
//
// Production code must never call this directly. Call the exported
// DoRequest or DoSend, which gate on NormalizeHTTPBase first (fix-round
// Minor 4) — that is what makes it safe for doRequest itself to trust
// base unconditionally.
func doHTTP(ctx context.Context, base, method, path string, query, headers map[string]string, send *httpSend, authRef, authHeader string) (HTTPResult, error) {
	if err := validateRelativePath(path); err != nil {
		return HTTPResult{}, err
	}

	baseURL, err := url.Parse(base)
	if err != nil || !baseURL.IsAbs() {
		return HTTPResult{}, UserError("this environment's API baseUrl is not a valid absolute URL")
	}

	joined := strings.TrimRight(base, "/") + "/" + strings.TrimLeft(path, "/")
	u, err := url.Parse(joined)
	if err != nil {
		return HTTPResult{}, UserError("bad path: " + err.Error())
	}
	// Structural check (controller ruling 2): verify the FINAL, resolved
	// destination, not words in the caller's input. A textual guard on
	// caller input can be talked around; requiring the joined URL's
	// scheme and host to still equal base's cannot, because nothing the
	// caller writes into path can change what this comparison inspects.
	//
	// MUTATION-TESTED AND FOUND UNREACHABLE VIA path, HONESTLY REPORTED:
	// breaking this check (replacing the condition with `false`) does not
	// turn any test in this file red. That is a real, verified property
	// of THIS join strategy, not a coverage gap being hidden: joined is
	// built by plain string concatenation
	// (TrimRight(base)+"/"+TrimLeft(path)), never by URL-reference
	// resolution, so url.Parse always terminates authority parsing at
	// the literal "/" this code itself inserts, immediately after base's
	// own host — no byte sequence in path (whatever validateRelativePath
	// does or doesn't reject) can ever be re-tokenized as a new
	// scheme/host by url.Parse. This check is kept anyway, exactly as
	// jira.go keeps its own deliberately-untested nested-span-merge
	// guard (see scrubSecrets's doc comment in secretscrub.go): it is
	// cheap, and it is the one thing standing between a future
	// refactor — e.g. switching to url.Parse(base).ResolveReference(...)
	// for cleaner query-string handling, which DOES resolve ".." and DOES
	// treat a leading "//" in a relative reference as protocol-relative —
	// and a real host-escape bug. Removing it because it looks
	// "unreachable today" would remove the only thing protecting that
	// future change.
	if u.Scheme != baseURL.Scheme || u.Host != baseURL.Host {
		return HTTPResult{}, UserError("path escaped the environment's baseUrl")
	}
	// Structural, decoded-path backstop for validateRelativePath's
	// textual ".." rejection — see containsDotDotSegment's doc comment
	// for why a percent-encoded "%2e%2e" needs this second layer.
	if containsDotDotSegment(u.Path) {
		return HTTPResult{}, UserError("path must not contain \"..\" segments")
	}
	// Fix-round Important-2: this guard is THIS FILE'S OWN defect,
	// introduced alongside validateRelativePath's textual backslash
	// rejection in commit 4c04aee. That commit's own comment claimed a
	// caller needing a backslash "can percent-encode it as %5C, which the
	// decoded-path check in containsDotDotSegment still inspects" — that
	// was false: containsDotDotSegment only ever matches a segment equal
	// to "..", so it can never see a "\.." shape no matter how it
	// arrived. A probe confirmed the bypass directly: path
	// "%5C..%5C..%5Cetc%5Cpasswd" was ACCEPTED by the old code and
	// arrived at the server as "/\..\..\etc\passwd" — byte for byte the
	// same string the textual guard exists to reject. This is
	// structurally identical to the "%2e%2e" gap containsDotDotSegment
	// itself already closes: a textual guard on caller input was added
	// with no matching structural guard on the decoded destination.
	// Checking the PARSED u.Path (not the caller's raw, still-encoded
	// path argument) closes it the same way: %5C and %5c both decode to
	// "\" here regardless of case or position.
	if strings.ContainsRune(u.Path, '\\') {
		return HTTPResult{}, UserError("path must not contain a backslash — not even percent-encoded (%5C/%5c); no path component may use one")
	}

	q := u.Query()
	for k, v := range query {
		q.Set(k, v)
	}
	u.RawQuery = q.Encode()

	// The SAME strings.ToUpper(method) transform the verb gates use
	// (controller ruling 9): AssertHTTPReadOnly and AssertHTTPMutation
	// both upper-case internally for their own comparison, so the gated
	// string and the sent string are provably the same transform of the
	// same input rather than two independently-computed strings that
	// could drift apart.
	verb := strings.ToUpper(method)
	// nil for a read AND for a send with nothing to say. It is a
	// strings.Reader rather than a stream because the body arrived as a
	// value — resolved from the pane's parts, or written by an agent —
	// and because a sized body lets net/http set Content-Length, which
	// is what makes a server's own limit fire before the bytes rather
	// than after them.
	//
	// **An empty body sends no body, and no Content-Type below** — three
	// wire states, not two (#179, story 27). A `DELETE` with nothing to
	// say must not be given a document: a zero-length body announced as
	// `application/json` is a document that fails to parse, and a server
	// entitled to reject it would be rejecting something Wakil invented.
	//
	// **The nil is not the observable half, honestly reported.** Measured
	// on this tree: a nil body and a strings.Reader over "" reach a
	// handler identically — ContentLength 0, no Content-Length header,
	// no transfer encoding — so breaking this line alone turns no test
	// red. It is written this way because it is what the ruling says and
	// because a future body that is a stream rather than a string would
	// make the difference real; the Content-Type below is what actually
	// carries story 27 on the wire, and its own test does go red.
	var bodyReader io.Reader
	if send != nil && send.Body != "" {
		bodyReader = strings.NewReader(send.Body)
	}
	req, err := http.NewRequestWithContext(ctx, verb, u.String(), bodyReader)
	if err != nil {
		return HTTPResult{}, UserError("could not build request: " + err.Error())
	}
	// Sorted for the same reason the response-header merge below is: Go
	// randomises map iteration, so ranging directly made two things vary
	// between identical calls. Measured over 200 runs each: with several
	// denied headers the rejection message named a random one (Cookie
	// 152x, Proxy-Foo 27x, Authorization 21x), and with caller keys that
	// canonicalise to the same header ("X-Foo"/"x-foo"/"X-FOO") it varied
	// WHICH VALUE went on the wire (150/27/23). The first is unreproducible
	// text in a model's context; the second is unreproducible behaviour.
	callerNames := make([]string, 0, len(headers))
	for k := range headers {
		callerNames = append(callerNames, k)
	}
	sort.Strings(callerNames)

	for _, k := range callerNames {
		if rejectedCallerHeader(k, authHeader) {
			return HTTPResult{}, UserError("header " + k + " is not allowed on this tool's requests")
		}
		// Content-Type is refused on a SEND only, and only because the
		// send has its own contentType parameter for it. Two channels
		// for one value is the silent-overwrite class this path exists
		// to stop repeating: Wakil sets the header after the caller's,
		// so a caller's would be overwritten and never complained
		// about. Host is the precedent for refusing rather than
		// ignoring quietly. On the READ path there is no second
		// channel, so nothing here narrows what 2b already shipped.
		if send != nil && strings.EqualFold(strings.TrimSpace(k), "Content-Type") {
			return HTTPResult{}, UserError("header " + k + " is not allowed on this tool's requests — set the contentType parameter instead, which is the one channel for it")
		}
		req.Header.Set(k, headers[k])
	}
	// The third wire state, and the empty one: no body means no
	// Content-Type. doSend clears it for that case — see the body reader
	// above, and httpSend.ContentType.
	if send != nil && send.ContentType != "" {
		req.Header.Set("Content-Type", send.ContentType)
	}

	// Controller ruling 3: a Keychain read failure must be surfaced, not
	// silently downgraded to an unauthenticated request — the latter
	// would show the human a confusing 401 from the API instead of a
	// clear re-auth sentence.
	var scrubber *SecretScrubber
	if authRef != "" {
		tok, err := SecretGet(authRef)
		if err != nil {
			return HTTPResult{}, err
		}
		// The entry's configured header, resolved through the one helper
		// that owns the Authorization default (ApiConfig.Header reads the
		// same one). Set AFTER the caller's headers so Wakil wins by
		// ordering, and the caller was refused this name above so the two
		// guarantees agree rather than one silently covering for the other.
		req.Header.Set(ResolveAuthHeader(authHeader), tok)
		// NewAuthHeaderScrubber, not NewSecretScrubber: tok is the WHOLE
		// header value the operator stored, which for any bearer API is
		// "Bearer <token>". A scrubber built from that string alone never
		// holds the bare token as a form, and a server echoing back only
		// the credential (the ordinary shape of an API auth-error body)
		// then goes unredacted — measured, 192 bytes verbatim. See that
		// constructor's doc comment.
		scrubber = NewAuthHeaderScrubber(tok)
	} else {
		scrubber = NewSecretScrubber("")
	}

	resp, err := noRedirectClient.Do(req)
	if err != nil {
		var rre *redirectRefusedError
		if errors.As(err, &rre) {
			return HTTPResult{}, UserError(scrubber.Scrub(rre.Error()))
		}
		return HTTPResult{}, UserError(scrubber.Scrub("request failed: " + err.Error()))
	}
	defer resp.Body.Close()

	// Controller ruling 4: scrub the body AND every response header
	// value, exactly the same threat JiraClient's search() answers for
	// Jira specifically (a server echoing the Authorization header back
	// hands the credential to whatever reads the MCP tool result) — see
	// secretscrub.go for the interval-merge scrub, the raw-coordinate
	// cut, and the partial-suffix backstop this reuses unchanged.
	// readLimit is sized to httpBodyCap+longestForm+1: the "+1" is what
	// lets len(raw) > httpBodyCap actually distinguish "the upstream body
	// is longer than the cap" from "it isn't" — reading exactly cap
	// bytes (the degenerate longestForm==0 case, no authRef at all)
	// would otherwise never be able to exceed cap no matter how large
	// the real body is. The "+longestForm" is the separate, pre-existing
	// guarantee this shares with jira.go's search(): any credential-form
	// occurrence STARTING within [0,httpBodyCap) is read in full before
	// scrubbing ever sees it (see scrubCutPoint's doc comment).
	readLimit := httpBodyCap + scrubber.LongestForm() + 1
	raw, readErr := io.ReadAll(io.LimitReader(resp.Body, int64(readLimit)))
	truncated := readErr != nil || len(raw) > httpBodyCap
	body := strings.TrimSpace(string(raw))
	cut := scrubber.CutPoint(body, httpBodyCap)
	scrubbed := scrubber.Scrub(body[:cut])
	if len(scrubbed) > httpBodyCap {
		// A short (8-9 byte) matched secret can grow slightly when
		// replaced by the 10-byte "[redacted]" marker — see
		// jiraScrubMinTokenLen's history for the identical, measured
		// case. The final truncateBytesAtRuneBoundary below always caps
		// display regardless, but the flag must reflect that growth
		// pushed content past the cap too.
		truncated = true
	}
	displayed := truncateBytesAtRuneBoundary(scrubbed, httpBodyCap)
	// One call, not "strip then drop": the two-step order let a dangling
	// UTF-8 byte block the strip and then be dropped, re-exposing the
	// credential partial it had been shielding. See
	// stripPartialCredentialTail for the measured case and for why the
	// obvious two-line swap has a mirror-image bug of its own.
	displayed = scrubber.StripPartialTail(displayed)

	// Fix-round Critical-1: the header NAME must be scrubbed too, not
	// only its value. Go's textproto accepts a header name made of token
	// characters — exactly what an API key is made of — and
	// CanonicalMIMEHeaderKey only forces case (uppercase at the start of
	// each hyphen-delimited segment, lowercase everywhere else); it never
	// changes which bytes are present. A server setting
	// w.Header()["X-Echo-"+token] — or, worse, w.Header()[token] directly
	// — hands the credential back almost byte-for-byte in the key, where
	// the old code (scrubbing only resp.Header.Get(k)) never looked at
	// all. Probed: a digit-first token ("0123456789abcdef01", an
	// ordinary lowercase-hex API key shape) survives canonicalization
	// completely unchanged — 18 of 18 bytes verbatim in the key.
	//
	// scrubber.ScrubHeaderName, not scrubber.Scrub, is used for the key
	// specifically because canonicalization's case-folding means an
	// exact, case-sensitive literal match (what Scrub uses, correctly,
	// for values and the body) can miss a credential in a NAME entirely
	// — see scrubHeaderName's doc comment for the letter-first probe that
	// demonstrates this.
	//
	// Scrubbing the key can make two distinct wire header names collide
	// (e.g. two different credentials that both happen to scrub down to
	// "[redacted]", or the same credential appearing in two differently
	// prefixed names). This map is built by MERGING onto an existing
	// scrubbed key rather than overwriting it, so a collision joins
	// values instead of silently dropping one of them — a silent drop in
	// a map is how data disappears with no trace, which is exactly the
	// failure mode Truncated exists elsewhere in this struct to make
	// explicit instead of silent.
	//
	// Multi-value response headers are also joined here (fix-round
	// Minor-7): resp.Header.Get only ever returns the FIRST value,
	// silently discarding the rest — probed with "X-Multi: harmless" +
	// "X-Multi: <token>" on the wire, where the old code reported only
	// "harmless". Values are joined with ", ", per RFC 7230 §3.2.2's own
	// rule that multiple header lines with the same name are
	// semantically equivalent to one line with the values comma-joined.
	//
	// The key order is sorted before merging, and that is not cosmetic.
	// Two DIFFERENT header names can scrub to the SAME string — most
	// obviously when both contain the credential — and their values are
	// then joined. Go randomises map iteration, so ranging over
	// resp.Header directly made that joined value differ between
	// identical requests: a reviewer issued the same request 60 times
	// against a server sending three colliding names and got three
	// distinct orderings ("v2, v1, v3" 48 times, "v1, v3, v2" 10, "v3,
	// v2, v1" twice). Non-reproducible output is bad in any tool result
	// and worse in one whose consumer is a model reading it as context.
	names := make([]string, 0, len(resp.Header))
	for k := range resp.Header {
		names = append(names, k)
	}
	sort.Strings(names)

	hs := map[string]string{}
	for _, k := range names {
		scrubbedKey := scrubber.ScrubHeaderName(k)
		scrubbedVal := scrubber.Scrub(strings.Join(resp.Header[k], ", "))
		if existing, ok := hs[scrubbedKey]; ok {
			hs[scrubbedKey] = existing + ", " + scrubbedVal
		} else {
			hs[scrubbedKey] = scrubbedVal
		}
	}

	return HTTPResult{Status: resp.StatusCode, Headers: hs, Body: displayed, Truncated: truncated}, nil
}

// doRequest is the read-only half of doHTTP: it gates the verb and sends
// no body at all. It keeps its own name, signature and tests because
// every caller and every test of the read path predates the send, and a
// nil-body argument threaded through them would have been churn that
// proved nothing.
func doRequest(ctx context.Context, base, method, path string, query, headers map[string]string, authRef, authHeader string) (HTTPResult, error) {
	if err := AssertHTTPReadOnly(method); err != nil {
		return HTTPResult{}, err
	}
	return doHTTP(ctx, base, method, path, query, headers, nil, authRef, authHeader)
}

// DoRequest is the production entry point for issuing a GET/HEAD request
// against an environment's API baseUrl. Fix-round Minor 4: the previous
// shape had this name exported and unguarded (the current body lived
// directly under it) — cmd/wakil-http's tool handler happened to
// validate base via NormalizeHTTPBase before ever calling it, confirmed
// by grep to be the only production caller, so there was no LIVE bypass
// — but the gate lived on the CALLER, not on the operation, so any
// future exported caller of DoRequest could put the Keychain-held auth
// token on a cleartext http:// connection just by forgetting to
// normalize base first. DoRequest now closes that gap itself: it
// validates base before doing anything else, then delegates to
// doRequest (above), which is what this file's own tests call directly
// to exercise the request machinery against plain http:// httptest
// servers.
func DoRequest(ctx context.Context, base, method, path string, query, headers map[string]string, authRef, authHeader string) (HTTPResult, error) {
	normBase, err := NormalizeHTTPBase(base)
	if err != nil {
		return HTTPResult{}, err
	}
	return doRequest(ctx, normBase, method, path, query, headers, authRef, authHeader)
}
