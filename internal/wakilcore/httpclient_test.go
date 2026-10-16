package wakilcore

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

// TestDoRequestRejectsBackslashPathTraversal pins that a backslash is
// rejected in a request path. A controller attack found "/x\\..\\..\\y"
// ACCEPTED while every forward-slash traversal was correctly rejected:
// backslash is an ordinary path character to RFC 3986 and to Go's url
// package, so that string contains no ".." SEGMENT for the textual scan
// to find. Servers disagree — IIS, some Java stacks and path-normalising
// proxies treat "\\" as a separator and would traverse — and a guard that
// blocks "/../" while passing "\\..\\" is worse than either extreme,
// because a reader reasonably concludes traversal is handled.
//
// MUTATION-VERIFIED: removing the backslash rejection fails this test.
func TestDoRequestRejectsBackslashPathTraversal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("request reached the server; the path should have been rejected before any network call: %q", r.URL.Path)
		w.WriteHeader(200)
	}))
	defer srv.Close()

	for _, path := range []string{
		`/x\..\..\y`,
		`\..\..\y`,
		`/legit\segment`,
	} {
		_, err := doRequest(context.Background(), srv.URL, "GET", path, nil, nil, "", "")
		if err == nil {
			t.Fatalf("path %q was accepted, want rejection", path)
		}
		msg, ok := IsUserError(err)
		if !ok {
			t.Fatalf("path %q: expected UserError, got %T: %v", path, err, err)
		}
		if !strings.Contains(msg, "backslash") {
			t.Fatalf("path %q: error %q does not mention the backslash", path, msg)
		}
	}
}

// TestDoRequestRejectsPercentEncodedBackslashPathTraversal pins
// fix-round Important-2: the controller's OWN commit (4c04aee) added the
// raw-backslash rejection above but its comment claimed a caller could
// route around it by percent-encoding as %5C, "which the decoded-path
// check in containsDotDotSegment still inspects" — that was false.
// containsDotDotSegment only ever matches a path SEGMENT equal to "..";
// a backslash-separated "\.." has no "/"-delimited segment at all, so it
// can never be seen by that function no matter how it arrived. Probed
// directly: "%5C..%5C..%5Cetc%5Cpasswd" was ACCEPTED by the pre-fix code
// and reached the server as "/\..\..\etc\passwd" — byte for byte the
// same string the raw-backslash guard above exists to reject.
//
// MUTATION-VERIFIED: removing the backslash check on the parsed u.Path
// in doRequest (the structural half, alongside containsDotDotSegment)
// fails every case below while leaving the raw-backslash test above
// green — confirming the two guards are independent layers, not the
// same one reporting twice.
func TestDoRequestRejectsPercentEncodedBackslashPathTraversal(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		t.Errorf("request reached the server; the path should have been rejected before any network call: %q", r.URL.Path)
		w.WriteHeader(200)
	}))
	defer srv.Close()

	for _, path := range []string{
		"%5C..%5C..%5Cetc%5Cpasswd", // uppercase, leading position
		"%5c..%5c..%5cetc%5cpasswd", // lowercase, leading position
		"/x%5C..%5C..%5Cy",          // uppercase, mid-path
		"/x%5c..%5c..%5cy",          // lowercase, mid-path
		"/legit%5Csegment",          // no traversal at all, just a bare encoded backslash
	} {
		_, err := doRequest(context.Background(), srv.URL, "GET", path, nil, nil, "", "")
		if err == nil {
			t.Fatalf("path %q was accepted, want rejection", path)
		}
		msg, ok := IsUserError(err)
		if !ok {
			t.Fatalf("path %q: expected UserError, got %T: %v", path, err, err)
		}
		if !strings.Contains(msg, "backslash") {
			t.Fatalf("path %q: error %q does not mention the backslash", path, msg)
		}
	}
	if called {
		t.Fatal("the request must be rejected before any network call is made")
	}
}

func TestDoRequestGuardsAndJoins(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/customers/42" {
			w.WriteHeader(200)
			w.Write([]byte(`{"id":42}`))
			return
		}
		w.WriteHeader(404)
	}))
	defer srv.Close()

	res, err := doRequest(context.Background(), srv.URL, "GET", "/customers/42", nil, nil, "", "")
	if err != nil || res.Status != 200 {
		t.Fatalf("GET failed: %+v %v", res, err)
	}
	if res.Body != `{"id":42}` {
		t.Fatalf("unexpected body: %q", res.Body)
	}
	if _, err := doRequest(context.Background(), srv.URL, "POST", "/customers", nil, nil, "", ""); err == nil {
		t.Fatal("POST must be rejected")
	}
	if _, err := doRequest(context.Background(), srv.URL, "GET", "http://evil.example/x", nil, nil, "", ""); err == nil {
		t.Fatal("absolute path must be rejected")
	}
}

// TestDoRequestRejectsProtocolRelativePath pins the "//" textual guard:
// a caller-supplied path starting with "//" looks like nothing to a
// naive path.Join, but net/url and browsers alike treat a leading "//"
// as protocol-relative — i.e. "escape the host using THIS scheme".
func TestDoRequestRejectsProtocolRelativePath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "//evil.example/x", nil, nil, "", "")
	if err == nil {
		t.Fatal("protocol-relative path (leading //) must be rejected")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

// TestDoRequestRejectsDotDotSegments pins controller ruling 2: a literal
// ".." path segment must be rejected outright, before any network call.
func TestDoRequestRejectsDotDotSegments(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "../../etc/passwd", nil, nil, "", "")
	if err == nil {
		t.Fatal("a \"..\" path segment must be rejected")
	}
	msg, ok := IsUserError(err)
	if !ok || msg == "" {
		t.Fatalf("expected a non-empty UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "..") {
		t.Fatalf("expected the rejection message to mention the offending \"..\" segment, got %q", msg)
	}
	if called {
		t.Fatal("the request must be rejected before any network call is made")
	}
}

// TestDoRequestRejectsEncodedDotDotSegments pins the structural half of
// ruling 2: a percent-encoded "%2e%2e" segment decodes to ".." only
// after url.Parse runs on the FINAL joined URL, so a purely textual scan
// of the caller's raw path argument (which never contains a literal "..")
// would miss it. The guard must catch it anyway.
func TestDoRequestRejectsEncodedDotDotSegments(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "%2e%2e/%2e%2e/etc/passwd", nil, nil, "", "")
	if err == nil {
		t.Fatal("an encoded \"%2e%2e\" path segment must be rejected")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if called {
		t.Fatal("the request must be rejected before any network call is made")
	}
}

// TestDoRequestRejectsFragment pins ruling 2's third new textual
// rejection: a caller path containing "#" would, once concatenated onto
// base and re-parsed as one URL string, silently turn everything after
// the "#" into a URL fragment that is NEVER SENT to the server at all —
// the caller would believe it requested one path and silently receive a
// response for a shorter, truncated one.
func TestDoRequestRejectsFragment(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/customers/42#/../../admin", nil, nil, "", "")
	if err == nil {
		t.Fatal("a path containing a fragment must be rejected")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if called {
		t.Fatal("the request must be rejected before any network call is made")
	}
}

// TestDoRequestRejectsRedirect is the MUTATION-sensitive pin for
// controller ruling 1: a server at baseUrl that tries to 302 elsewhere
// must have that redirect refused outright, and the caller must be told
// enough to know it happened (status + Location), not merely "request
// failed".
func TestDoRequestRejectsRedirect(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte("should never be reached"))
	}))
	defer target.Close()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/elsewhere", http.StatusFound)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "", "")
	if err == nil {
		t.Fatal("expected an error when the server tries to redirect")
	}
	msg, ok := IsUserError(err)
	if !ok || msg == "" {
		t.Fatalf("expected a non-empty UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "302") && !strings.Contains(strings.ToLower(msg), "redirect") {
		t.Fatalf("expected the message to mention the redirect, got %q", msg)
	}
	if !strings.Contains(msg, target.URL) && !strings.Contains(msg, "/elsewhere") {
		t.Fatalf("expected the message to surface the Location target, got %q", msg)
	}
}

// TestDoRequestRejectsRedirectToMetadataHost pins the specific SSRF
// scenario ruling 1 calls out by name: a redirect to a cloud metadata
// address must be refused exactly like any other redirect, never
// followed "just this once" because the target looks well-known.
func TestDoRequestRejectsRedirectToMetadataHost(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "http://169.254.169.254/latest/meta-data/")
		w.WriteHeader(http.StatusFound)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "", "")
	if err == nil {
		t.Fatal("expected an error when the server redirects to a metadata address")
	}
	msg, ok := IsUserError(err)
	if !ok || msg == "" {
		t.Fatalf("expected a non-empty UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "169.254.169.254") {
		t.Fatalf("expected the message to surface the metadata Location target, got %q", msg)
	}
}

// bearerAuthFixture returns a realistic Authorization header value and
// the bare credential inside it. The 192-character token is deliberate:
// it is the shape a real bearer API issues, and — more importantly — it
// makes the two strings DIFFERENT, which is the whole point. The earlier
// version of the body test below stored the token as the ENTIRE
// Authorization value, so "the whole header value" and "the bare
// credential" were the same string and the test could not distinguish a
// scrubber that knew both from one that knew only the first.
func bearerAuthFixture() (full, bare string) {
	bare = strings.Repeat("kGh3vQ2mZp8xLr7TnW1yBd4sJf6UeAc0", 6) // 192 chars
	return "Bearer " + bare, bare
}

// TestDoRequestScrubsEchoedAuthTokenFromBody is the security-critical
// pin for ruling 4: a server that echoes the credential back in its
// response body must never have it reach the caller.
//
// The "bare credential" subtest is a reproduction, not a hypothetical.
// wakil-http stores the WHOLE Authorization header value under one
// secret ref, so for any bearer API that value is "Bearer <token>" —
// and a scrubber built from that whole string alone holds no form that
// matches an echo of the token by itself, which is the ordinary shape of
// an API auth-error body. Measured before the fix, through this same
// doRequest path: all 192 bytes of the credential came back verbatim in
//
//	{"error":"invalid token","token":"kGh3FAKEnotARealCredentialXXXX..."}
//
// Both subtests assert the redaction MARKER actually fired (non-vacuous:
// an absence-only assertion would pass trivially against a scrubber that
// always returned ""), and use longestVerbatimLeak rather than
// strings.Contains so a surviving FRAGMENT of the credential fails too.
func TestDoRequestScrubsEchoedAuthTokenFromBody(t *testing.T) {
	full, bare := bearerAuthFixture()

	cases := map[string]func(sent string) string{
		"server echoes only the bare credential": func(sent string) string {
			return strings.TrimPrefix(sent, "Bearer ")
		},
		"server echoes the whole header value": func(sent string) string {
			return sent
		},
	}
	for name, echo := range cases {
		t.Run(name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(400)
				fmt.Fprintf(w, `{"error":"invalid token","token":%q}`, echo(r.Header.Get("Authorization")))
			}))
			defer srv.Close()

			setupFakeSecretRef(t, "test-http-ref", full)

			res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref", "")
			if err != nil {
				t.Fatalf("DoRequest: %v", err)
			}
			if leak := longestVerbatimLeak(res.Body, bare); leak != 0 {
				t.Fatalf("a %d-byte fragment of the credential survived in the body: %q", leak, res.Body)
			}
			if !strings.Contains(res.Body, "[redacted]") {
				t.Fatalf("expected the scrub marker to fire, got %q", res.Body)
			}
		})
	}
}

// TestAuthHeaderScrubberRespectsMinTokenLen pins the floor on the SECOND
// form NewAuthHeaderScrubber adds. Splitting "Bearer <token>" into a bare
// credential form is only safe while that remainder is long enough to be
// a credential rather than a coincidence: a two-character remainder used
// as a scrub literal would redact every occurrence of those two
// characters anywhere in the response, which is the "wall of [redacted]"
// jiraScrubMinTokenLen's doc comment records. The whole header value is
// still scrubbed in that case — only the bare form is withheld.
func TestAuthHeaderScrubberRespectsMinTokenLen(t *testing.T) {
	s := NewAuthHeaderScrubber("Bearer ab")
	for _, lit := range s.Literals() {
		if lit == "ab" {
			t.Fatal("a 2-byte remainder must not become a scrub form")
		}
		if len(lit) < jiraScrubMinTokenLen {
			t.Fatalf("form %q is shorter than the %d-byte floor", lit, jiraScrubMinTokenLen)
		}
	}
	// The whole value is still a form, so the leak this constructor exists
	// to close is not traded away for the floor.
	if got := s.Scrub("sent Bearer ab upstream"); !strings.Contains(got, "[redacted]") {
		t.Fatalf("the whole header value must still be scrubbed, got %q", got)
	}
	// And an unrelated body containing "ab" must survive untouched.
	if got := s.Scrub("table abacus"); got != "table abacus" {
		t.Fatalf("short remainder shredded unrelated text: %q", got)
	}
}

// TestAuthHeaderScrubberSplitsOnFirstWhitespaceOnly pins the split rule
// itself: RFC 9110's credentials grammar is "auth-scheme 1*SP
// credential", so everything after the FIRST run of whitespace is the
// credential — including any further spaces inside it, which some
// schemes' auth-param forms contain.
func TestAuthHeaderScrubberSplitsOnFirstWhitespaceOnly(t *testing.T) {
	cases := map[string]string{
		"Bearer abcdefghij":           "abcdefghij",
		"Basic dXNlcjpwYXNzd29yZA==":  "dXNlcjpwYXNzd29yZA==",
		"Digest username=\"u\", nc=1": "username=\"u\", nc=1",
		"Bearer\tabcdefghij":          "abcdefghij",
	}
	for value, want := range cases {
		if got := authHeaderCredential(value); got != want {
			t.Errorf("authHeaderCredential(%q) = %q, want %q", value, got, want)
		}
	}
	// No whitespace at all: the whole value IS the credential, and
	// NewAuthHeaderScrubber must not add it a second time.
	const raw = "0123456789abcdef"
	if got := authHeaderCredential(raw); got != raw {
		t.Errorf("authHeaderCredential(%q) = %q, want it unchanged", raw, got)
	}
	single := NewAuthHeaderScrubber(raw).Literals()
	double := NewAuthHeaderScrubber("Bearer " + raw).Literals()
	if len(double) != 2*len(single) {
		t.Fatalf("expected a scheme-prefixed value to yield exactly two form sets, got %d vs %d", len(double), len(single))
	}
	// The raw value must appear exactly once among the forms — twice
	// would mean NewAuthHeaderScrubber added the same string as both the
	// "whole value" and the "bare credential". (The base64 forms are NOT
	// checked for uniqueness: standard and URL-safe base64 coincide for
	// any input whose encoding contains no "+" or "/", so appendSecretForms
	// legitimately produces equal literals there.)
	rawCount := 0
	for _, l := range single {
		if l == raw {
			rawCount++
		}
	}
	if rawCount != 1 {
		t.Fatalf("expected the raw value once among %v, got it %d times", single, rawCount)
	}
}

// TestDoRequestBodyDoesNotLeakPartialTokenBeforeDanglingRune is the
// wakil-http half of the partial-credential ordering fix (jira.go's
// search() has the same shape and the same test). A response body that
// ends with a PREFIX of the credential followed by a dangling UTF-8 lead
// byte used to survive the display pipeline: the strip stage could not
// match, because the partial was not the literal suffix of the string,
// and the rune drop that ran afterwards then removed the dangling bytes
// and re-exposed the partial with nothing left to remove it.
//
// The body is far shorter than httpBodyCap so nothing else in the
// pipeline cuts it; the fragment reaches the final stage untouched,
// which is the case the ordering has to handle.
func TestDoRequestBodyDoesNotLeakPartialTokenBeforeDanglingRune(t *testing.T) {
	full, bare := bearerAuthFixture()
	body := `{"error":"invalid token ` + bare[:12] + "\xe4\xb8"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		w.Write([]byte(body))
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-partial", full)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-partial", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if leak := longestVerbatimLeak(res.Body, bare); leak != 0 {
		t.Fatalf("a %d-byte fragment of the credential survived in the body: %q", leak, res.Body)
	}
	if !utf8.ValidString(res.Body) {
		t.Fatalf("body is not valid UTF-8: %q", res.Body)
	}
	if res.Body != `{"error":"invalid token ` {
		t.Fatalf("got %q, want the partial and the dangling rune removed", res.Body)
	}
}

// TestDoRequestScrubsEchoedAuthTokenFromHeader is ruling 4's other half:
// a server echoing the credential back in a RESPONSE HEADER (not the
// body) must be scrubbed too — headers are just as visible to the MCP
// caller as the body.
func TestDoRequestScrubsEchoedAuthTokenFromHeader(t *testing.T) {
	const token = "sup3r-secret-token-value-0123456789"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Echo-Auth", r.Header.Get("Authorization"))
		w.WriteHeader(200)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-2", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-2", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	got := res.Headers["X-Echo-Auth"]
	if strings.Contains(got, token) {
		t.Fatalf("token leaked into response header: %q", got)
	}
	if !strings.Contains(got, "[redacted]") {
		t.Fatalf("expected the scrub marker to fire in the header value, got %q", got)
	}
}

// longestVerbatimLeak returns the length of the longest contiguous
// substring of secret, of at least jiraScrubMinTokenLen bytes, that
// still appears verbatim anywhere in text — 0 if none does. Fix-round
// tests use this instead of a plain strings.Contains(text, secret) check
// because the controller's own brief asks for the STRONGER property
// "longest surviving verbatim fragment is 0", not merely "the whole
// secret string is absent" — a scrubber that redacted only the FULL
// literal and left any partial fragment (e.g. a straddling cut's
// verbatim prefix) behind would still pass a whole-secret-absence check.
// The jiraScrubMinTokenLen floor is not arbitrary: it is the exact same
// floor this codebase already uses (see that constant's own doc comment)
// to decide a match is credential material rather than coincidence, so a
// helper built for exactly this codebase should use it too rather than
// demanding an impossible literal 0 down to single-character overlaps,
// which recur in any text for reasons having nothing to do with a leak.
func longestVerbatimLeak(text, secret string) int {
	for length := len(secret); length >= jiraScrubMinTokenLen; length-- {
		for i := 0; i+length <= len(secret); i++ {
			if strings.Contains(text, secret[i:i+length]) {
				return length
			}
		}
	}
	return 0
}

// TestDoRequestScrubsTokenFromHeaderNameDigitFirst is Critical-1's own
// named reproduction: a server that echoes the credential back as a
// RESPONSE HEADER NAME (not a value) leaks it in full when the token
// happens to start with a digit — an ordinary shape for a lowercase-hex
// API key. CanonicalMIMEHeaderKey only force-cases letters (uppercase at
// the start of each hyphen-delimited segment, lowercase elsewhere); a
// leading digit has no case to fold, so all 18 of 18 bytes survive
// verbatim in the pre-fix code, which only ever scrubbed
// resp.Header.Get(k) — the VALUE, never the key itself.
//
// MUTATION-VERIFIED below (see TestDoRequestHeaderNameScrubbingIsLoadBearing).
func TestDoRequestScrubsTokenFromHeaderNameDigitFirst(t *testing.T) {
	const token = "0123456789abcdef01" // digit-first: no byte's case can change
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header()[r.Header.Get("Authorization")] = []string{"leaked-in-name"}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-digit", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-digit", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	markerFired := false
	for k := range res.Headers {
		if leak := longestVerbatimLeak(k, token); leak != 0 {
			t.Fatalf("a %d-byte fragment of the token survived verbatim in a header NAME: %q", leak, k)
		}
		if strings.Contains(k, "[redacted]") {
			markerFired = true
		}
	}
	if !markerFired {
		t.Fatalf("expected the scrub marker to fire in a header name, got headers %+v", res.Headers)
	}
}

// TestDoRequestScrubsTokenFromHeaderNameLetterFirst is the OTHER half of
// Critical-1's probe: a letter-first token has its leading byte's case
// forced by CanonicalMIMEHeaderKey, so an exact case-SENSITIVE literal
// match (correct for header VALUES and the body) misses it even though
// 17 of its 18 bytes are unchanged — this is exactly why the fix scrubs
// header names with ScrubHeaderName (case-insensitive), not Scrub.
func TestDoRequestScrubsTokenFromHeaderNameLetterFirst(t *testing.T) {
	const token = "abc123def456ghi789"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header()["X-Echo-"+r.Header.Get("Authorization")] = []string{"ok"}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-letter", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-letter", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	markerFired := false
	for k := range res.Headers {
		if leak := longestVerbatimLeak(k, token); leak != 0 {
			t.Fatalf("a %d-byte fragment of the token survived verbatim in a header NAME: %q", leak, k)
		}
		if strings.Contains(k, "[redacted]") {
			markerFired = true
		}
	}
	if !markerFired {
		t.Fatalf("expected the scrub marker to fire in a header name, got headers %+v", res.Headers)
	}
}

// TestDoRequestHeaderNameScrubbingIsLoadBearing is a direct, minimal
// pin, separate from the two tests above, for the specific one-line
// regression this fix closes: reverting the header-building loop back to
// `hs[k] = scrubber.Scrub(resp.Header.Get(k))` (scrubbing only the
// VALUE, leaving the raw token as the map KEY unchanged) must fail this
// test — the raw token must never appear as a header key in the result.
func TestDoRequestHeaderNameScrubbingIsLoadBearing(t *testing.T) {
	const token = "0123456789abcdef01"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header()[r.Header.Get("Authorization")] = []string{"x"}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-digit-2", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-digit-2", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if _, ok := res.Headers[token]; ok {
		t.Fatalf("the raw token survived as a header key verbatim: %+v", res.Headers)
	}
}

// TestDoRequestMergesCollidingScrubbedHeaderNames pins Critical-1's
// collision ruling: two DIFFERENT wire header names that both scrub down
// to the identical string ("[redacted]", here, since each name IS in its
// entirety one of SecretScrubber's own forms) must have BOTH their
// values preserved (merged), not have one silently overwrite the other
// in the result map — a silent overwrite in a map is data disappearing
// with no trace, exactly the failure mode Truncated exists elsewhere in
// this struct to make explicit instead of silent.
// TestDoRequestCallerHeaderHandlingIsDeterministic pins that the caller
// header loop iterates in a fixed order. Go randomises map iteration, and
// a reviewer measured two effects over 200 identical calls each: with
// several denied headers the rejection message named a random one (Cookie
// 152x, Proxy-Foo 27x, Authorization 21x), and with caller keys that
// canonicalise to the same header it varied WHICH VALUE reached the wire
// (150/27/23). The first is unreproducible text in a model's context; the
// second is unreproducible behaviour.
//
// MUTATION-VERIFIED: ranging over the headers map instead of the sorted
// key slice fails this test.
func TestDoRequestCallerHeaderHandlingIsDeterministic(t *testing.T) {
	var sawValue string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawValue = r.Header.Get("X-Foo")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	// Several denied headers: the reported one must always be the same.
	denied := map[string]string{
		"Cookie":              "a",
		"Proxy-Foo":           "b",
		"Authorization":       "c",
		"Proxy-Authorization": "d",
	}
	var firstMsg string
	for i := 0; i < 40; i++ {
		_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, denied, "", "")
		if err == nil {
			t.Fatalf("run %d: denied headers were accepted", i)
		}
		msg, ok := IsUserError(err)
		if !ok {
			t.Fatalf("run %d: expected UserError, got %T", i, err)
		}
		if i == 0 {
			firstMsg = msg
			continue
		}
		if msg != firstMsg {
			t.Fatalf("rejection message is non-deterministic: run 0 gave %q, run %d gave %q", firstMsg, i, msg)
		}
	}

	// Keys that canonicalise to one header: the value sent must be stable.
	colliding := map[string]string{"X-Foo": "A", "x-foo": "B", "X-FOO": "C"}
	var firstVal string
	for i := 0; i < 40; i++ {
		if _, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, colliding, "", ""); err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
		if i == 0 {
			firstVal = sawValue
			// Guard the premise: all three keys must reach the same header.
			if firstVal != "A" && firstVal != "B" && firstVal != "C" {
				t.Fatalf("unexpected wire value %q — the keys may no longer collide", firstVal)
			}
			continue
		}
		if sawValue != firstVal {
			t.Fatalf("wire value is non-deterministic: run 0 sent %q, run %d sent %q", firstVal, i, sawValue)
		}
	}
}

// TestDoRequestCollidingHeaderMergeIsDeterministic pins that the merged
// value for colliding scrubbed header names is the SAME on every call.
// Go randomises map iteration, so ranging over resp.Header directly made
// this vary: a reviewer issued one request 60 times against a server
// sending three names that all scrub to "[redacted]" and got three
// distinct orderings. The existing merge test only asserts that each
// value is present, so it passes under every ordering and cannot see it.
//
// MUTATION-VERIFIED: ranging over resp.Header instead of the sorted key
// slice fails this test.
func TestDoRequestCollidingHeaderMergeIsDeterministic(t *testing.T) {
	const token = "0123456789abcdef0123456789"
	setupFakeSecretRef(t, "ref", token)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Three DIFFERENT names that all scrub to exactly "[redacted]":
		// the raw token, its raw-URL base64 (whose "-"/"_" alphabet is
		// made of valid RFC 7230 token characters, unlike std base64's
		// "/" and "="), and the token doubled, whose two overlapping
		// spans merge into one. Assigned into the map directly rather
		// than via Header.Set, which would canonicalise them.
		w.Header()[token] = []string{"v1"}
		w.Header()[base64.RawURLEncoding.EncodeToString([]byte(token))] = []string{"v2"}
		w.Header()[token+token] = []string{"v3"}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	var first string
	const runs = 40
	for i := 0; i < runs; i++ {
		res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "ref", "")
		if err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
		got, ok := res.Headers["[redacted]"]
		if !ok {
			t.Fatalf("run %d: no collided key in %v", i, res.Headers)
		}
		// Guard the premise: if the names ever stop colliding, this test
		// would trivially pass while pinning nothing.
		if !strings.Contains(got, "v1") || !strings.Contains(got, "v2") || !strings.Contains(got, "v3") {
			t.Fatalf("run %d: expected all three values merged, got %q", i, got)
		}
		if i == 0 {
			first = got
			continue
		}
		if got != first {
			t.Fatalf("merge order is non-deterministic: run 0 gave %q, run %d gave %q", first, i, got)
		}
	}
}

func TestDoRequestMergesCollidingScrubbedHeaderNames(t *testing.T) {
	const token = "sup3r-secret-token-value-0123456789"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		// Two DIFFERENT wire header names — the raw token, and its
		// RawURLEncoding form (both valid HTTP token characters; base64
		// std/padded encodings are not, since '+' '/' '=' are not all
		// legal header-name bytes) — each of which is, in its entirety,
		// one of SecretScrubber's own scrub forms, so each scrubs down to
		// exactly "[redacted]" with nothing left over.
		w.Header()[auth] = []string{"v1"}
		w.Header()[base64.RawURLEncoding.EncodeToString([]byte(auth))] = []string{"v2"}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-collide", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-collide", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	got, ok := res.Headers["[redacted]"]
	if !ok {
		t.Fatalf("expected both colliding header names to scrub to \"[redacted]\", got headers %+v", res.Headers)
	}
	if !strings.Contains(got, "v1") || !strings.Contains(got, "v2") {
		t.Fatalf("expected both colliding headers' values to be preserved (merged), not one silently dropped, got %q", got)
	}
}

// TestDoRequestTruncatesLargeBody pins ruling 5: a response body far
// larger than the cap must be truncated (never handed whole into the
// model's context) and the truncation must be reported explicitly via
// HTTPResult.Truncated, following the Rows.Truncated / IssuePage.Truncated
// precedent.
func TestDoRequestTruncatesLargeBody(t *testing.T) {
	big := strings.Repeat("x", 2*1024*1024) // 2MiB, far above any sane cap
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte(big))
	}))
	defer srv.Close()

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if !res.Truncated {
		t.Fatal("expected Truncated=true for an oversized body")
	}
	if len(res.Body) >= len(big) {
		t.Fatalf("expected the body to be capped well below %d bytes, got %d", len(big), len(res.Body))
	}
	// Also pin that the cap itself is "far lower" than the brief's 1MiB,
	// not merely lower.
	if len(res.Body) > 512*1024 {
		t.Fatalf("cap looks too high: got %d bytes", len(res.Body))
	}
}

// TestDoRequestNotTruncatedForSmallBody guards against the trivial
// mutation of always reporting Truncated=true.
func TestDoRequestNotTruncatedForSmallBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if res.Truncated {
		t.Fatal("did not expect Truncated=true for a small body")
	}
}

// TestHTTPBodyCapDefaultIsProductionValue pins that httpBodyCap's
// shipped default is unchanged even though it is now a var (fix-round
// Important-1) so the tests below can lower it temporarily. Production
// code must never assign to it.
func TestHTTPBodyCapDefaultIsProductionValue(t *testing.T) {
	if httpBodyCap != 64*1024 {
		t.Fatalf("production httpBodyCap default changed from 64KiB to %d bytes", httpBodyCap)
	}
}

// withLoweredBodyCap temporarily lowers the package-level httpBodyCap
// for a test, restoring the original value in t.Cleanup — see
// httpBodyCap's own doc comment for why it is a var, not a const, at
// all: purely so tests can exercise the cap-straddling / doubled-echo /
// partial-suffix-at-the-cap code paths with small, readable httptest
// fixtures instead of ones tens of kilobytes long.
func withLoweredBodyCap(t *testing.T, n int) {
	t.Helper()
	orig := httpBodyCap
	httpBodyCap = n
	t.Cleanup(func() { httpBodyCap = orig })
}

// TestDoRequestScrubsTokenStraddlingBodyCap pins the Task-14-defect-3
// shape directly (fix-round Important-1): a credential-form occurrence
// that STARTS before httpBodyCap and ENDS after it must be read and
// scrubbed in full, not split at the cap and left with a verbatim
// fragment on display. This is scrubCutPoint's whole reason to exist —
// see "cut := scrubber.CutPoint(body, httpBodyCap)" in DoRequest. The
// naive mutation "cut := min(httpBodyCap, len(body))" (a plain cap-first
// cut, ignoring the credential entirely) cuts the token in half, leaving
// its first half verbatim in the display; that mutation, together with
// deleting either of the two backstop lines right after it, survived the
// FULL test suite before this round — see the report's mutation log.
//
// MUTATION-VERIFIED: see the fix-round report for the verbatim
// before/after output of applying this exact mutation.
func TestDoRequestScrubsTokenStraddlingBodyCap(t *testing.T) {
	withLoweredBodyCap(t, 64)
	const token = "sup3r-secret-token-value-0123456789" // 36 bytes, >= jiraScrubMinTokenLen
	// filler shares no characters with token (no "z" anywhere in token),
	// so any surviving fragment found by longestVerbatimLeak is a real
	// leak, never filler-vs-token coincidence.
	filler := strings.Repeat("z", httpBodyCap-10) // token starts 10 bytes
	// before the cap and, being 36 bytes long, ends 26 bytes after it.
	body := filler + token

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		fmt.Fprint(w, body)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-straddle", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-straddle", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if !strings.Contains(res.Body, "[redacted]") {
		t.Fatalf("expected the redaction marker to fire, got %q", res.Body)
	}
	if leak := longestVerbatimLeak(res.Body, token); leak != 0 {
		t.Fatalf("a %d-byte fragment of the straddling token survived verbatim: body=%q", leak, res.Body)
	}
}

// TestDoRequestScrubsDoubledEchoAcrossBodyCap pins Task-14-defect-3's
// other half (fix-round Important-1): not just a single credential-form
// occurrence straddling httpBodyCap, but TWO OVERLAPPING occurrences — a
// periodic credential shape, the same shape scrubSecrets's own doc
// comment explains is what actually needs the interval-merge/cascading
// logic rather than a single straddle-extension. A period repeated 6
// times contains the (period-repeated-5-times) token literal at exactly
// two overlapping starting offsets, 8 bytes apart — a genuine "doubled
// echo" scrubCutPoint's LOOP (not just its first straddle-extension)
// must capture in full before scrubbing runs.
func TestDoRequestScrubsDoubledEchoAcrossBodyCap(t *testing.T) {
	withLoweredBodyCap(t, 100)
	const period = "ab1cd2ef"          // 8 bytes
	token := strings.Repeat(period, 5) // 40 bytes: the resolved auth token
	run := strings.Repeat(period, 6)   // 48 bytes: contains the 40-byte
	// token literal at two overlapping offsets (0 and 8) within the run —
	// the "doubled echo".
	filler := strings.Repeat("z", 64) // run starts at byte 64, well
	// before the 100-byte cap, so both occurrences straddle it; filler
	// shares no characters with period/token, so any surviving fragment
	// longestVerbatimLeak finds is a real leak.
	body := filler + run // 112 bytes total

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		fmt.Fprint(w, body)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-doubled", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-doubled", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if !strings.Contains(res.Body, "[redacted]") {
		t.Fatalf("expected the redaction marker to fire, got %q", res.Body)
	}
	if leak := longestVerbatimLeak(res.Body, token); leak != 0 {
		t.Fatalf("a %d-byte fragment of the doubled-echo token survived verbatim: body=%q", leak, res.Body)
	}
}

// TestDoRequestStripsPartialCredentialSuffixAtBodyEnd pins
// Task-14-defect-3's third layer (fix-round Important-1): a response
// body that ends with an INCOMPLETE (prefix-only) occurrence of the
// credential form must not leave that trailing fragment on display. The
// body is kept under httpBodyCap so scrubCutPoint itself never
// truncates anything (cut == len(body)) — the ONLY thing that can remove
// the trailing partial is
// "displayed = scrubber.StripPartialSuffix(displayed)". A full, separate
// occurrence earlier in the body proves the redaction marker itself
// still fires independently of that stripping step.
//
// MUTATION-VERIFIED: see the fix-round report for the verbatim
// before/after output of deleting that line.
func TestDoRequestStripsPartialCredentialSuffixAtBodyEnd(t *testing.T) {
	withLoweredBodyCap(t, 100)
	const token = "sup3r-secret-token-value-0123456789" // 36 bytes
	body := fmt.Sprintf("echo1=%s filler more text echo2-partial=%s", token, token[:15])
	if len(body) > httpBodyCap {
		t.Fatalf("test fixture bug: body (%d bytes) must fit under the lowered cap (%d) so scrubCutPoint never truncates it itself — only StripPartialSuffix should be doing the trimming this test pins", len(body), httpBodyCap)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		fmt.Fprint(w, body)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-partial", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-partial", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if !strings.Contains(res.Body, "[redacted]") {
		t.Fatalf("expected the redaction marker to fire, got %q", res.Body)
	}
	if leak := longestVerbatimLeak(res.Body, token); leak != 0 {
		t.Fatalf("a %d-byte fragment of the token survived verbatim at the end of the body: body=%q", leak, res.Body)
	}
	if strings.HasSuffix(res.Body, token[:15]) {
		t.Fatalf("trailing partial credential form was not stripped: body=%q", res.Body)
	}
}

// TestDoRequestDropsTrailingIncompleteRuneAtBodyEnd pins the THIRD
// mutation named in the fix-round report separately from the test above:
// deleting "displayed = dropTrailingIncompleteRune(displayed)". That
// function's job is UNRELATED to credential material specifically — it
// repairs a body ending mid-UTF-8-rune, which the test above (an
// all-ASCII "partial credential form") never exercises, since
// truncateBytesAtRuneBoundary is a no-op whenever the scrubbed body is
// already at or under httpBodyCap (exactly the case constructed here,
// and in the test above) and StripPartialSuffix only strips a suffix
// that matches a CREDENTIAL form's prefix, not an arbitrary stray UTF-8
// lead byte. The body below simulates dropTrailingIncompleteRune's
// documented "mid-stream connection drop" route directly: the server
// writes bytes ending with the first two bytes of a three-byte rune,
// with the third never sent. A full, separate credential occurrence
// earlier in the body proves the redaction marker still fires
// independently.
func TestDoRequestDropsTrailingIncompleteRuneAtBodyEnd(t *testing.T) {
	const token = "sup3r-secret-token-value-0123456789"
	// U+4E00 ("一") encodes as the 3 bytes E4 B8 80; sending only the
	// first two leaves a genuinely incomplete rune at the very end.
	incompleteRune := []byte{0xE4, 0xB8}
	bodyPrefix := fmt.Sprintf("echo=%s trailing-non-ascii-", token)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		fmt.Fprint(w, bodyPrefix)
		w.Write(incompleteRune)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-incomplete-rune", token)

	res, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "test-http-ref-incomplete-rune", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if !strings.Contains(res.Body, "[redacted]") {
		t.Fatalf("expected the redaction marker to fire, got %q", res.Body)
	}
	if !utf8.ValidString(res.Body) {
		t.Fatalf("response body is not valid UTF-8 — a trailing incomplete rune survived: %q", res.Body)
	}
	if leak := longestVerbatimLeak(res.Body, token); leak != 0 {
		t.Fatalf("a %d-byte fragment of the token survived verbatim: body=%q", leak, res.Body)
	}
}

// TestDoRequestRejectsCallerAuthorizationHeader and
// TestDoRequestRejectsCallerCookieHeader pin ruling 6: a caller-supplied
// header must not be able to override Authorization or inject Cookie —
// both would be set on an already-credentialed request with no
// restriction otherwise.
func TestDoRequestRejectsCallerAuthorizationHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, map[string]string{"Authorization": "Bearer forged"}, "", "")
	if err == nil {
		t.Fatal("caller must not be able to set the Authorization header")
	}
	msg, ok := IsUserError(err)
	if !ok || msg == "" {
		t.Fatalf("expected a non-empty UserError, got %T: %v", err, err)
	}
}

func TestDoRequestRejectsCallerCookieHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, map[string]string{"Cookie": "session=x"}, "", "")
	if err == nil {
		t.Fatal("caller must not be able to set the Cookie header")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

func TestDoRequestRejectsCallerProxyHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, map[string]string{"Proxy-Authorization": "Basic x"}, "", "")
	if err == nil {
		t.Fatal("caller must not be able to set a Proxy-* header")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

func TestDoRequestRejectsCallerHostHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, map[string]string{"Host": "evil.example"}, "", "")
	if err == nil {
		t.Fatal("caller must not be able to set the Host header")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

// TestDoRequestAllowsOrdinaryCallerHeader guards against an
// over-broad deny list swallowing legitimate headers too.
func TestDoRequestAllowsOrdinaryCallerHeader(t *testing.T) {
	var gotAccept string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAccept = r.Header.Get("Accept")
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, map[string]string{"Accept": "application/json"}, "", "")
	if err != nil {
		t.Fatalf("DoRequest: %v", err)
	}
	if gotAccept != "application/json" {
		t.Fatalf("expected ordinary header to pass through, got %q", gotAccept)
	}
}

// TestDoRequestPropagatesSecretGetFailure pins ruling 3: a Keychain read
// failure for authRef must be surfaced as an error, not silently
// downgraded to an unauthenticated request that would confuse the human
// with an unexplained 401 from the API.
func TestDoRequestPropagatesSecretGetFailure(t *testing.T) {
	// Pointed at a path that does not exist: the tool is invoked by
	// absolute path now (#201), so "not installed" is a missing file
	// rather than an unresolvable name.
	t.Setenv("WAKIL_SECURITY_BINARY", filepath.Join(t.TempDir(), "security"))
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "some-ref", "")
	if err == nil {
		t.Fatal("expected SecretGet's failure to propagate")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if called {
		t.Fatal("must not send the request unauthenticated when the keychain read fails")
	}
}

// setupFakeSecretRef writes a fake `security` binary to a temp dir,
// prepends it to PATH for the duration of the test, and configures it to
// answer any `find-generic-password ... -w` query with value — the same
// PATH-substitution technique used in dbresolve_test.go's
// fakeSecurityBinary, kept local to this file since here every test
// wants a specific, literal secret value rather than a fixed constant
// DSN.
func setupFakeSecretRef(t *testing.T, ref, value string) string {
	t.Helper()
	t.Setenv("WAKIL_ORG", "testorg")
	dir := t.TempDir()
	script := filepath.Join(dir, "security")
	body := fmt.Sprintf("#!/bin/sh\nprintf '%%s' %q\n", value)
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatalf("write fake security binary: %v", err)
	}
	// **`WAKIL_SECURITY_BINARY`, not PATH** (2e, #201). The product now
	// invokes the Keychain tool by its absolute path, because the ACL on
	// the CLI's own item names `/usr/bin/security` and a bare name
	// resolved off PATH is a different application to that ACL. A
	// PATH-based fake stopped intercepting the moment that landed — and
	// would have pointed this test at the operator's real login keychain
	// while still passing.
	t.Setenv("WAKIL_SECURITY_BINARY", script)
	return dir
}

// TestDoRequestGatesOnNormalizeHTTPBase pins fix-round Minor 4: the
// EXPORTED DoRequest must not accept an arbitrary absolute base. Unlike
// the unexported doRequest (used throughout this file's own tests
// against plain http:// httptest servers, which trusts base was already
// validated), DoRequest IS the operation callers actually reach, so it
// must apply NormalizeHTTPBase's gate itself, first — a Keychain-held
// auth token must never be able to go out over a cleartext http://
// connection just because some future exported caller forgot to
// normalize base before calling DoRequest.
func TestDoRequestGatesOnNormalizeHTTPBase(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := DoRequest(context.Background(), srv.URL, "GET", "/x", nil, nil, "", "")
	if err == nil {
		t.Fatal("expected the exported DoRequest to reject a non-https base URL")
	}
	msg, ok := IsUserError(err)
	if !ok || !strings.Contains(msg, "https") {
		t.Fatalf("expected a UserError mentioning https, got %T: %v", err, err)
	}
	if called {
		t.Fatal("must not reach the network when the base fails NormalizeHTTPBase")
	}
}

// TestNewSecretScrubberFloorExcludesShortSecrets pins fix-round Minor 9:
// NewSecretScrubber's floor is ">= jiraScrubMinTokenLen" (8 bytes), not
// "> 0" — a secret shorter than the floor must produce NO forms at all
// and must not be scrubbed, exactly mirroring JiraClient.scrubForms's own
// token-length gate (see jiraScrubMinTokenLen's doc comment for why: a
// short literal redacts unrelated coincidental text rather than a real
// credential). The mutation "> 0" survived the whole pre-fix suite with
// no test pinning this floor specifically.
func TestNewSecretScrubberFloorExcludesShortSecrets(t *testing.T) {
	const shortSecret = "short12" // 7 bytes: one below jiraScrubMinTokenLen (8)
	s := NewSecretScrubber(shortSecret)
	if len(s.Literals()) != 0 {
		t.Fatalf("expected no forms for a secret shorter than the floor, got %v", s.Literals())
	}
	const msg = "the value short12 appears here coincidentally"
	got := s.Scrub(msg)
	if got != msg {
		t.Fatalf("a sub-floor secret must not be scrubbed at all: got %q, want %q", got, msg)
	}
}

// TestSecretScrubberScrubsRawURLBase64Form pins fix-round Minor 9's other
// mutation: appendSecretForms must still include base64.RawURLEncoding
// among the forms it builds — dropping it survived the whole pre-fix
// suite with no test pinning that specific encoding. A server or proxy
// using unpadded URL-safe base64 (one of the four real-world encodings
// appendSecretForms's own doc comment lists) must still have the
// credential scrubbed.
func TestSecretScrubberScrubsRawURLBase64Form(t *testing.T) {
	const token = "sup3r-secret-token-value-0123456789"
	encoded := base64.RawURLEncoding.EncodeToString([]byte(token))
	s := NewSecretScrubber(token)
	got := s.Scrub("prefix " + encoded + " suffix")
	if strings.Contains(got, encoded) {
		t.Fatalf("RawURLEncoding form of the secret leaked: %q", got)
	}
	if !strings.Contains(got, "[redacted]") {
		t.Fatalf("expected the redaction marker to fire, got %q", got)
	}
}

// --- NormalizeHTTPBase: mirrors normalizeJiraBase's own test suite
// (jira_test.go's TestNewJiraFromEnv* tests), adjusted for the one
// deliberate difference: a path IS allowed here (see NormalizeHTTPBase's
// doc comment).

func TestNormalizeHTTPBaseAcceptsPlainHTTPS(t *testing.T) {
	got, err := NormalizeHTTPBase("https://api.example.com")
	if err != nil {
		t.Fatalf("NormalizeHTTPBase: %v", err)
	}
	if got != "https://api.example.com" {
		t.Fatalf("got %q", got)
	}
}

func TestNormalizeHTTPBaseStripsTrailingSlash(t *testing.T) {
	got, err := NormalizeHTTPBase("https://api.example.com/")
	if err != nil {
		t.Fatalf("NormalizeHTTPBase: %v", err)
	}
	if got != "https://api.example.com" {
		t.Fatalf("got %q", got)
	}
}

// TestNormalizeHTTPBaseAllowsPath pins the deliberate deviation from
// normalizeJiraBase: wakil-http's DoRequest joins the caller's relative
// path onto base, so a base carrying an API-version path prefix is a
// legitimate configuration, unlike Jira's origin-only base.
func TestNormalizeHTTPBaseAllowsPath(t *testing.T) {
	got, err := NormalizeHTTPBase("https://api.example.com/v2")
	if err != nil {
		t.Fatalf("NormalizeHTTPBase: %v", err)
	}
	if got != "https://api.example.com/v2" {
		t.Fatalf("got %q", got)
	}
}

func TestNormalizeHTTPBaseRejectsNonHTTPS(t *testing.T) {
	_, err := NormalizeHTTPBase("http://api.example.com")
	if err == nil {
		t.Fatal("expected rejection of a non-https base URL")
	}
	msg, ok := IsUserError(err)
	if !ok || msg == "" {
		t.Fatalf("expected a non-empty UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "https") {
		t.Fatalf("error %q does not mention https", msg)
	}
}

func TestNormalizeHTTPBaseRejectsRelativeBase(t *testing.T) {
	_, err := NormalizeHTTPBase("api.example.com")
	if err == nil {
		t.Fatal("expected rejection of a relative base URL")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

// TestNormalizeHTTPBaseRejectsUserinfoAndRedactsPassword pins controller
// ruling 8's stated threat directly: a baseUrl carrying userinfo is a
// second credential channel entirely outside the Keychain, and the
// rejection message must not itself leak the password it is rejecting.
func TestNormalizeHTTPBaseRejectsUserinfoAndRedactsPassword(t *testing.T) {
	_, err := NormalizeHTTPBase("https://user:sup3rsecret@api.example.com")
	if err == nil {
		t.Fatal("expected rejection of a base URL containing userinfo")
	}
	msg, ok := IsUserError(err)
	if !ok || msg == "" {
		t.Fatalf("expected a non-empty UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "credentials") {
		t.Fatalf("error %q does not mention credentials", msg)
	}
	if strings.Contains(msg, "sup3rsecret") {
		t.Fatalf("error leaked the password: %q", msg)
	}
}

func TestNormalizeHTTPBaseRejectsQuery(t *testing.T) {
	_, err := NormalizeHTTPBase("https://api.example.com?a=b")
	if err == nil {
		t.Fatal("expected rejection of a base URL containing a query string")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

func TestNormalizeHTTPBaseRejectsFragment(t *testing.T) {
	_, err := NormalizeHTTPBase("https://api.example.com#frag")
	if err == nil {
		t.Fatal("expected rejection of a base URL containing a fragment")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
}

// TestNormalizeHTTPBaseNeverEchoesACredential is the wakil-http half of
// the fix for the leak url.URL.Redacted() left open in normalizeJiraBase
// (see TestNormalizeJiraBaseNeverEchoesACredential — the two functions had
// the identical bug, because this one was written from that one).
//
// Redacted() masks a userinfo PASSWORD and nothing else, so three shapes
// were echoed whole: a bare userinfo username with no colon (the headline
// case — it is a token sitting where a username goes, which is exactly
// what an operator does when they paste an API token into a URL), a query
// string, and a fragment. Only the user:password form was ever redacted,
// which is what made the bug survive a reading of the code.
//
// Every rejection now reports scheme://host via safeBaseHint, which DROPS
// userinfo, path, query and fragment rather than redacting them.
//
// The path case matters on its own here and has no counterpart in the Jira
// test: NormalizeHTTPBase deliberately ALLOWS a path (an API-version
// prefix is a legitimate baseUrl), so a rejection for some OTHER reason
// must still not echo a path that happens to carry a token.
func TestNormalizeHTTPBaseNeverEchoesACredential(t *testing.T) {
	const tok = "ATATT3xFfGF0T4Jj9secretAPItokenVALUE"
	for _, tc := range []struct {
		name, base, wantSays string
	}{
		{"bare userinfo username, no colon", "https://" + tok + "@api.example.com", "must not contain credentials"},
		{"userinfo with password", "https://user:" + tok + "@api.example.com", "must not contain credentials"},
		{"query string", "https://api.example.com?token=" + tok, "must not contain a query string"},
		{"fragment", "https://api.example.com#token=" + tok, "must not contain a fragment"},
		{"token in path, rejected for its query", "https://api.example.com/v2/" + tok + "?x=1", "must not contain a query string"},
		{"token in path, rejected for its scheme", "http://api.example.com/v2/" + tok, "must be an absolute https URL"},
		{"scheme-relative", "//api.example.com/" + tok, "must be an absolute https URL"},
		{"opaque", "mailto:" + tok + "@api.example.com", "must be an absolute https URL"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := NormalizeHTTPBase(tc.base)
			if err == nil {
				t.Fatalf("NormalizeHTTPBase(%q) = %q, want a rejection", tc.base, got)
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("error is not a UserError: %v", err)
			}
			// Assert the guard FIRED with its own sentence, not merely
			// that the token is absent: a dropped message would satisfy
			// the leak check below while telling the operator nothing.
			if !strings.Contains(msg, tc.wantSays) {
				t.Fatalf("message = %q, want it to say %q", msg, tc.wantSays)
			}
			if strings.Contains(msg, tok) {
				t.Fatalf("credential echoed back to the caller: %q", msg)
			}
			// No fragment of it either — safeBaseHint drops these
			// components wholesale, so nothing partial should survive.
			for n := len(tok); n >= 8; n-- {
				for i := 0; i+n <= len(tok); i++ {
					if strings.Contains(msg, tok[i:i+n]) {
						t.Fatalf("%d-byte credential fragment %q echoed back: %q", n, tok[i:i+n], msg)
					}
				}
			}
		})
	}
}

// #183: the entry's CONFIGURED auth header joins the deny list. Wakil
// already won by ordering — the credential is set after the caller's
// headers — but a caller whose header is silently overwritten has a latent
// bug it will never find. Host is the precedent for refusing explicitly
// rather than ignoring quietly.
func TestAConfiguredAuthHeaderIsRefusedToTheCallerByName(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	_, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil,
		map[string]string{"X-API-Key": "forged"}, "", "X-API-Key")
	if err == nil || !strings.Contains(err.Error(), "X-API-Key") {
		t.Fatalf("a caller must be refused the entry's own auth header by name, got %v", err)
	}
	// Case-insensitively, the way every other name in the list matches.
	_, err = doRequest(context.Background(), srv.URL, "GET", "/x", nil,
		map[string]string{"x-api-key": "forged"}, "", "X-API-Key")
	if err == nil {
		t.Fatal("the match must fold case")
	}
	// And a header that is NOT the configured one is still allowed —
	// the list grew by exactly one name, not by everything.
	if _, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil,
		map[string]string{"Accept": "application/json"}, "", "X-API-Key"); err != nil {
		t.Fatalf("an ordinary header must still pass: %v", err)
	}
	// An empty configured header means Authorization, and must not make
	// the empty string a denied name — every header has one of those.
	if _, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil,
		map[string]string{"Accept": "application/json"}, "", ""); err != nil {
		t.Fatalf("an unconfigured header must deny nothing extra: %v", err)
	}
}

// The credential goes in the entry's own header, not always Authorization.
func TestTheCredentialIsSentInTheConfiguredHeader(t *testing.T) {
	var got http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Clone()
		w.WriteHeader(200)
	}))
	defer srv.Close()

	setupFakeSecretRef(t, "test-http-ref-hdr", "k-secret-value")
	if _, err := doRequest(context.Background(), srv.URL, "GET", "/x", nil, nil,
		"test-http-ref-hdr", "X-API-Key"); err != nil {
		t.Fatalf("doRequest: %v", err)
	}
	if got.Get("X-API-Key") != "k-secret-value" {
		t.Errorf("credential not in the configured header: %v", got)
	}
	if got.Get("Authorization") != "" {
		t.Errorf("and not in Authorization: %v", got)
	}
}
