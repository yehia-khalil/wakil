package wakilcore

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// inWindow puts the marker in this test's environment. Every send test
// that expects to reach a server calls it; every test that expects the
// gate to fire deliberately does not.
func inWindow(t *testing.T) {
	t.Helper()
	t.Setenv(WindowMarkerEnv, "1")
}

// recordedRequest is what the fixture server actually received — asserted
// on instead of on how doSend built it, per the spec's own rule that a
// test asserts on what a caller can observe.
type recordedRequest struct {
	method      string
	body        string
	contentType string
	header      http.Header
	// The server's own view of how long the body was. Go moves
	// Content-Length off r.Header and onto r.ContentLength, so a header
	// assertion for it can never fire — and a body-less send is exactly
	// what would otherwise slip past one. -1 means no body was announced.
	contentLength int64
	hits          int
}

func sendFixture(t *testing.T, handle func(w http.ResponseWriter, r *http.Request)) (*httptest.Server, *recordedRequest) {
	t.Helper()
	got := &recordedRequest{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got.hits++
		got.method = r.Method
		got.body = string(b)
		got.contentType = r.Header.Get("Content-Type")
		got.header = r.Header.Clone()
		got.contentLength = r.ContentLength
		if handle != nil {
			handle(w, r)
			return
		}
		w.WriteHeader(200)
		w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(srv.Close)
	return srv, got
}

// The four mutation verbs each carry their body and content type to the
// server, and the response comes back through the same capped, scrubbed
// path the read tool uses.
func TestDoSendCarriesMethodBodyAndContentType(t *testing.T) {
	inWindow(t)
	for _, method := range []string{"POST", "PUT", "PATCH", "DELETE"} {
		t.Run(method, func(t *testing.T) {
			srv, got := sendFixture(t, nil)
			out, err := doSend(context.Background(), srv.URL, method, "/things",
				nil, map[string]string{"X-Request-Id": "abc"},
				`{"name":"x"}`, "application/json", "", "")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.method != method {
				t.Fatalf("server saw method %q, want %q", got.method, method)
			}
			if got.body != `{"name":"x"}` {
				t.Fatalf("server saw body %q, want the JSON document", got.body)
			}
			if got.contentType != "application/json" {
				t.Fatalf("server saw Content-Type %q, want application/json", got.contentType)
			}
			if got.header.Get("X-Request-Id") != "abc" {
				t.Fatalf("server saw X-Request-Id %q, want abc", got.header.Get("X-Request-Id"))
			}
			if out.Status != 200 || out.Body != `{"ok":true}` {
				t.Fatalf("result = %+v, want the server's 200 and body", out)
			}
		})
	}
}

// A send from a process the window did not spawn is refused — that is
// the whole gate, because AssertHTTPReadOnly lives in wakilcore and
// lifting it would otherwise arm the copy register-provider.sh puts in
// every provider's config dir, where there is no window, no gate and no
// second credential to refuse on.
func TestDoSendRefusedWithoutTheWindowMarker(t *testing.T) {
	srv, got := sendFixture(t, nil)
	for _, marker := range []string{"", "0", "no", "true"} {
		t.Run("marker="+marker, func(t *testing.T) {
			if marker == "" {
				t.Setenv(WindowMarkerEnv, "")
			} else {
				t.Setenv(WindowMarkerEnv, marker)
			}
			_, err := doSend(context.Background(), srv.URL, "POST", "/things", nil, nil, "{}", "application/json", "", "")
			if err == nil {
				t.Fatal("a send outside the window was accepted")
			}
			msg, ok := IsUserError(err)
			if !ok || !strings.Contains(msg, "window") {
				t.Fatalf("error %v does not name the window", err)
			}
		})
	}
	if got.hits != 0 {
		t.Fatalf("server was reached %d times; the gate must refuse before any network call", got.hits)
	}
}

// The read tool is unaffected by the marker: it is read-only wherever it
// runs, and the gate scopes which process may WRITE, never which may read.
func TestDoRequestIsUnaffectedByTheWindowMarker(t *testing.T) {
	t.Setenv(WindowMarkerEnv, "")
	srv, got := sendFixture(t, nil)
	if _, err := doRequest(context.Background(), srv.URL, "GET", "/things", nil, nil, "", ""); err != nil {
		t.Fatalf("a read outside the window was refused: %v", err)
	}
	if got.hits != 1 || got.method != "GET" {
		t.Fatalf("server saw %d hits, last method %q; want one GET", got.hits, got.method)
	}
}

// The two verb sets do not overlap, in either direction: a read verb on
// the send path is refused naming the read tool, and a mutation verb on
// the read path stays refused exactly as it was.
func TestVerbSetsDoNotOverlap(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	for _, method := range []string{"GET", "HEAD", "", "TRACE", "OPTIONS", "CONNECT"} {
		if _, err := doSend(context.Background(), srv.URL, method, "/x", nil, nil, "{}", "application/json", "", ""); err == nil {
			t.Fatalf("send accepted method %q", method)
		}
	}
	for _, method := range []string{"POST", "PUT", "PATCH", "DELETE"} {
		if _, err := doRequest(context.Background(), srv.URL, method, "/x", nil, nil, "", ""); err == nil {
			t.Fatalf("request accepted method %q", method)
		}
	}
	if got.hits != 0 {
		t.Fatalf("server was reached %d times; every verb above is refused before the network", got.hits)
	}
}

// A read verb's refusal names the tool that does take it, because a
// caller holding the wrong tool needs the right one, not a restatement.
func TestDoSendRefusalNamesTheReadTool(t *testing.T) {
	inWindow(t)
	srv, _ := sendFixture(t, nil)
	_, err := doSend(context.Background(), srv.URL, "GET", "/x", nil, nil, "", "", "", "")
	msg, ok := IsUserError(err)
	if !ok || !strings.Contains(msg, "request") {
		t.Fatalf("error %v does not name the request tool", err)
	}
}

// The redirect refusal is unconditional, and it is load-bearing on this
// path in a way it never was on the read path: a 307 preserves the
// method AND the body, so a followed redirect would repeat the write
// against a host the operator never reviewed.
func TestDoSendRefusesRedirectWithMethodAndBodyIntact(t *testing.T) {
	inWindow(t)
	target, targetGot := sendFixture(t, nil)
	srv, got := sendFixture(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/elsewhere", http.StatusTemporaryRedirect)
	})

	_, err := doSend(context.Background(), srv.URL, "POST", "/things", nil, nil, `{"charge":1}`, "application/json", "", "")
	if err == nil {
		t.Fatal("a 307 away from the entry's base URL was followed")
	}
	msg, ok := IsUserError(err)
	if !ok || (!strings.Contains(msg, "307") && !strings.Contains(strings.ToLower(msg), "redirect")) {
		t.Fatalf("error %v does not name the redirect", err)
	}
	if targetGot.hits != 0 {
		t.Fatalf("the redirect target received %d requests, want 0 — a 307 carries the method and body with it", targetGot.hits)
	}
	// The original request DID leave, with its method and body: the
	// refusal is of the second hop, not of the first.
	if got.hits != 1 || got.method != "POST" || got.body != `{"charge":1}` {
		t.Fatalf("origin saw %d hits, method %q, body %q; want one POST carrying the body", got.hits, got.method, got.body)
	}
}

// The probe booked a cliff below 64 MiB and found none: a 67 MB call
// crossed the pipe with no refusal, no truncation and no hang, held in
// full in three processes. The absence was the finding, and this is the
// limit that closes it — refusing, never hanging and never truncating,
// with the number in the message.
func TestDoSendRefusesABodyOverTheCap(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	body := strings.Repeat("x", httpSendBodyCap+1)
	_, err := doSend(context.Background(), srv.URL, "POST", "/things", nil, nil, body, "application/json", "", "")
	if err == nil {
		t.Fatal("a body over the cap was accepted")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %T: %v", err, err)
	}
	// A limit nobody is told about is the failure this closes, so the
	// message carries the number rather than merely saying "too large".
	if !strings.Contains(msg, "1 MiB") {
		t.Fatalf("refusal %q does not name the limit", msg)
	}
	// And it carries the EXACT size, not only a rounded one. Measured on
	// the shipped binary: one byte over the cap rounds to "1.0 MiB",
	// which beside a "1 MiB limit" reads as a refusal of something that
	// is exactly at the limit — telling the operator the wrong thing
	// about their own request.
	if !strings.Contains(msg, strconv.Itoa(httpSendBodyCap+1)) {
		t.Fatalf("refusal %q does not carry the exact byte count", msg)
	}
	if got.hits != 0 {
		t.Fatalf("server was reached %d times; an over-cap body is refused before the network", got.hits)
	}
	// Exactly at the cap is accepted: the refusal is of what exceeds it.
	if _, err := doSend(context.Background(), srv.URL, "POST", "/things", nil, nil,
		strings.Repeat("x", httpSendBodyCap), "application/json", "", ""); err != nil {
		t.Fatalf("a body exactly at the cap was refused: %v", err)
	}
}

func TestHTTPSendBodyCapDefaultIsProductionValue(t *testing.T) {
	if httpSendBodyCap != 1024*1024 {
		t.Fatalf("httpSendBodyCap = %d, want 1 MiB — a test that lowered it must restore it", httpSendBodyCap)
	}
}

// Everything the read tool refuses a caller, the send tool refuses too:
// the connection and authentication headers are Wakil's, and the entry's
// own configured auth header joins them dynamically.
func TestDoSendRefusesTheSameCallerHeaders(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	cases := []struct {
		header, authHeader string
	}{
		{"Authorization", ""},
		{"authorization", ""},
		{"Cookie", ""},
		{"Host", ""},
		{"Proxy-Authorization", ""},
		{"X-API-Key", "X-API-Key"},
	}
	for _, tc := range cases {
		t.Run(tc.header, func(t *testing.T) {
			_, err := doSend(context.Background(), srv.URL, "POST", "/things", nil,
				map[string]string{tc.header: "v"}, "{}", "application/json", "", tc.authHeader)
			msg, ok := IsUserError(err)
			if !ok || !strings.Contains(msg, tc.header) {
				t.Fatalf("header %q: error %v does not refuse it by name", tc.header, err)
			}
		})
	}
	if got.hits != 0 {
		t.Fatalf("server was reached %d times on refused headers", got.hits)
	}
}

// Content-Type has its own parameter on this path, so it is refused in
// headers rather than silently overwritten — Host's precedent, and the
// same silent-overwrite class this ticket closes two of by design.
func TestDoSendRefusesACallerContentTypeHeader(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	_, err := doSend(context.Background(), srv.URL, "POST", "/things", nil,
		map[string]string{"Content-Type": "text/plain"}, "{}", "application/json", "", "")
	msg, ok := IsUserError(err)
	if !ok || !strings.Contains(msg, "contentType") {
		t.Fatalf("error %v does not point at the contentType parameter", err)
	}
	if got.hits != 0 {
		t.Fatalf("server was reached %d times on a refused header", got.hits)
	}
}

// A send with no content type of its own still declares one rather than
// leaving net/http to sniff, because what a write means to a server is
// the operator's statement and not a guess made downstream.
func TestDoSendDefaultsTheContentType(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	if _, err := doSend(context.Background(), srv.URL, "POST", "/things", nil, nil, `{"a":1}`, "", "", ""); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.contentType != "application/json" {
		t.Fatalf("server saw Content-Type %q, want the application/json default", got.contentType)
	}
}

// ---------------------------------------------------------------------
// The two silent overwrites, pinned as the behaviour they still are
// ---------------------------------------------------------------------

// Both are closed BY DESIGN one region up rather than by a patch here,
// and this test states which region closes which so that a later reader
// finds the reason rather than only the behaviour.
//
//   - A "?" in the path is not rejected: it becomes a query string, and
//     a caller that meant a literal "?" in a path segment gets a
//     different request than it wrote. THE PANE'S QUERY REGION removes
//     it (#190): a query typed as rows never travels through the path.
//   - An explicit query param silently overwrites a path-borne one of
//     the same name. THE MAP'S OWN RULING removes it one region up: the
//     draft holds the query as parts, so there is no second channel for
//     the same name to arrive through.
//
// Patching either here would refuse a request the pane can no longer
// build, while leaving every other caller of this package guessing.
func TestSendQueryHandlingIsTheBehaviourTheRegionsRemove(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)

	// A "?" in the path is accepted and read as a query string.
	if _, err := doSend(context.Background(), srv.URL, "POST", "/things?kind=a", nil, nil, "{}", "application/json", "", ""); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if q := got.header; q == nil {
		t.Fatal("no request recorded")
	}

	// And an explicit param of the same name overwrites the path-borne
	// one rather than joining it or refusing the collision.
	var sawURL string
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawURL = r.URL.String()
		w.WriteHeader(200)
	}))
	defer srv2.Close()
	if _, err := doSend(context.Background(), srv2.URL, "POST", "/things?kind=a",
		map[string]string{"kind": "b"}, nil, "{}", "application/json", "", ""); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(sawURL, "kind=b") || strings.Contains(sawURL, "kind=a") {
		t.Fatalf("server saw %q, want the explicit kind=b to have replaced the path-borne kind=a", sawURL)
	}
}

// The exported entry point gates on NormalizeHTTPBase FIRST, exactly as
// DoRequest does: a Keychain-held credential must never go out over a
// cleartext connection because a future caller forgot to normalize.
func TestDoSendGatesOnNormalizeHTTPBase(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	_, err := DoSend(context.Background(), srv.URL, "POST", "/x", nil, nil, "{}", "application/json", "", "")
	msg, ok := IsUserError(err)
	if !ok || !strings.Contains(msg, "https") {
		t.Fatalf("expected a UserError mentioning https, got %T: %v", err, err)
	}
	if got.hits != 0 {
		t.Fatal("must not reach the network when the base fails NormalizeHTTPBase")
	}
}

// The path guards are the read path's, unchanged and shared rather than
// re-derived: one join, one set of refusals, for both verbs.
func TestDoSendKeepsThePathGuards(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	for _, path := range []string{"/x/../../y", `/x\..\..\y`, "//evil.example.com/x", "/x#frag", "/x/%2e%2e/y"} {
		if _, err := doSend(context.Background(), srv.URL, "POST", path, nil, nil, "{}", "application/json", "", ""); err == nil {
			t.Fatalf("path %q was accepted on the send path", path)
		}
	}
	if got.hits != 0 {
		t.Fatalf("server was reached %d times; every path above is refused before the network", got.hits)
	}
}

// A credentialed send carries the entry's own header, and the response
// is scrubbed through the same machinery the read path uses.
func TestDoSendCredentialsAndScrubsLikeTheReadPath(t *testing.T) {
	inWindow(t)
	full, bare := bearerAuthFixture()
	setupFakeSecretRef(t, "api:billing", full)
	var sawAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAuth = r.Header.Get("Authorization")
		w.WriteHeader(401)
		w.Write([]byte("rejected credential " + bare))
	}))
	defer srv.Close()

	out, err := doSend(context.Background(), srv.URL, "POST", "/things", nil, nil, "{}", "application/json", "api:billing", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sawAuth != full {
		t.Fatalf("server saw Authorization %q, want the stored header value", sawAuth)
	}
	if strings.Contains(out.Body, bare) {
		t.Fatalf("body %q echoed the credential back unscrubbed", out.Body)
	}
	if out.Status != 401 {
		t.Fatalf("status = %d, want the server's 401", out.Status)
	}
}

// ---------------------------------------------------------------------
// The three wire states (#179, story 27)
// ---------------------------------------------------------------------

// An empty body sends NO body and NO Content-Type. A `DELETE` with
// nothing to say must not be given a document: a zero-length body
// announced as `application/json` is a document that fails to parse.
func TestDoSendWithAnEmptyBodySendsNoBodyAndNoContentType(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	if _, err := doSend(context.Background(), srv.URL, "DELETE", "/things/1", nil, nil, "", "", "", ""); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.method != "DELETE" {
		t.Fatalf("server saw method %q, want DELETE", got.method)
	}
	if got.body != "" {
		t.Fatalf("server saw body %q, want none", got.body)
	}
	if got.contentType != "" {
		t.Fatalf("server saw Content-Type %q, want none at all", got.contentType)
	}
	// The length is asserted, and what it can and cannot prove is stated
	// rather than assumed. MEASURED on this tree (go1.27.1, httptest):
	// a nil body and a strings.Reader over "" arrive IDENTICALLY — both
	// give the handler ContentLength 0, an absent Content-Length header
	// and an empty TransferEncoding. So this assertion pins that no
	// document was announced; it does NOT distinguish "no body" from "a
	// body of length zero", and no server-side assertion can. The
	// OBSERVABLE half of story 27 is the Content-Type above, which is
	// why that is the one the mutation test turns red.
	if got.contentLength != 0 {
		t.Fatalf("server saw contentLength %d, want no document announced", got.contentLength)
	}
}

// The other two states, beside the empty one, so all three are pinned in
// one place: a body with the default type, and a body with the caller's.
func TestTheThreeWireStates(t *testing.T) {
	inWindow(t)
	cases := []struct {
		name        string
		body        string
		contentType string
		wantBody    string
		wantType    string
	}{
		{"nothing to say", "", "", "", ""},
		{"a body, typed by default", `{"a":1}`, "", `{"a":1}`, "application/json"},
		{"a body, typed by the caller", "a=1", "application/x-www-form-urlencoded", "a=1", "application/x-www-form-urlencoded"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, got := sendFixture(t, nil)
			if _, err := doSend(context.Background(), srv.URL, "POST", "/things", nil, nil,
				tc.body, tc.contentType, "", ""); err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.body != tc.wantBody || got.contentType != tc.wantType {
				t.Fatalf("server saw body %q type %q, want %q / %q",
					got.body, got.contentType, tc.wantBody, tc.wantType)
			}
		})
	}
}

// A content type named alongside an empty body is a caller contradicting
// itself. Dropping it quietly is the silent-overwrite class this tool
// exists to stop repeating, so it is refused and told which half to drop.
func TestDoSendRefusesAContentTypeWithNoBody(t *testing.T) {
	inWindow(t)
	srv, got := sendFixture(t, nil)
	_, err := doSend(context.Background(), srv.URL, "DELETE", "/things/1", nil, nil,
		"", "application/json", "", "")
	msg, ok := IsUserError(err)
	if !ok || !strings.Contains(msg, "empty body") {
		t.Fatalf("error %v does not explain the empty body", err)
	}
	if got.hits != 0 {
		t.Fatalf("server was reached %d times on a refusal", got.hits)
	}
}
