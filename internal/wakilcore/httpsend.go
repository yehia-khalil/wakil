package wakilcore

import (
	"context"
	"os"
	"strconv"
	"strings"
)

// This file is the WRITE half of the HTTP client. The read half
// (httpclient.go) shipped in 2b; everything here is #187.
//
// WHY THE WRITE HALF NEEDED A GATE THE READ HALF DID NOT. The verb
// assertion lives in this package, and this package is linked into
// `wakil-http` — the one binary `scripts/register-provider.sh`
// registers into EVERY provider's config dir. So lifting
// AssertHTTPReadOnly does not arm one process, it arms every copy,
// including the ones running with no window around them, no write gate
// in front of them, and — unlike `wakil-db`'s `mutate`, which refuses on
// a second credential the environment may simply not configure — no
// second credential to refuse on. An api entry has ONE authRef, and it
// is already resolved for reads.
//
// So the mutation verbs are held to the window by a marker only the
// window's own child-process environment sets. THE MARKER IS NOT A KEY:
// it proves nothing to any server, it grants no authority the read
// credential does not already carry, and anyone who can set an
// environment variable on this process can set it. What it does is scope
// WHICH PROCESS may spend a credential every copy can already read —
// which is the actual difference between the window and a config-dir
// registration, and the only difference this package is in a position to
// observe. Invariant 6's HTTP justification is amended accordingly:
// read-only everywhere, writable from the window.

// WindowMarkerEnv is the environment variable the Wakil window sets on
// the MCP servers it spawns. It is exported so the Swift side has a name
// to set rather than a string literal to keep in sync, and so a test can
// name it without repeating it.
const WindowMarkerEnv = "WAKIL_IN_WINDOW"

// windowMarkerValue is the ONE value that counts as set. Not "any
// non-empty value": a variable left over as "0" or "false" in some
// forwarded environment would otherwise arm the write path, and a marker
// that is armed by its own negation is worse than no marker.
const windowMarkerValue = "1"

// InWakilWindow reports whether this process was spawned by the window.
func InWakilWindow() bool { return os.Getenv(WindowMarkerEnv) == windowMarkerValue }

// AssertHTTPWindow refuses a write from a process the window did not
// spawn. The message says which process is refusing and why, because the
// caller most likely to hit it is an agent inside a provider's own
// config dir, where nothing on screen explains the difference.
func AssertHTTPWindow() error {
	if InWakilWindow() {
		return nil
	}
	return UserError("this wakil-http was not started by the Wakil window, so it is read-only: it can issue GET/HEAD through the request tool, and no method that writes. A send runs from a pane in the window, where the request is visible before it leaves and the result is visible after")
}

// httpMutationMethods is the write verb set, as Invariant 6 fixes it.
// An allowlist rather than "not GET/HEAD": a method this project has
// never reasoned about must be refused by default rather than sent
// because it failed to match a denial.
var httpMutationMethods = map[string]bool{"POST": true, "PUT": true, "PATCH": true, "DELETE": true}

// AssertHTTPMutation allows only the four mutation verbs. Matching is
// case-insensitive, via the same strings.ToUpper transform doHTTP uses
// to build the request (controller ruling 9).
//
// A READ verb is refused here by name, pointing at the tool that takes
// it: a caller holding the wrong tool needs the right one, and "only
// POST/PUT/PATCH/DELETE are allowed" would leave it re-reading a schema
// it has already misread once.
func AssertHTTPMutation(method string) error {
	upper := strings.ToUpper(method)
	if httpMutationMethods[upper] {
		return nil
	}
	if err := AssertHTTPReadOnly(method); err == nil {
		return UserError(upper + " does not write — issue it with the request tool, which is read-only and needs no window")
	}
	return UserError("only POST, PUT, PATCH and DELETE may be sent")
}

// httpSendBodyCap bounds the request body a send may carry.
//
// THE ABSENCE WAS THE FINDING. The 2c-iv probe booked a cliff somewhere
// below 64 MiB and found none: a 67 MB call crossed the MCP pipe with no
// refusal, no truncation and no hang, and was held in full in three
// processes at once. Nothing anywhere said no. This is the refusal that
// is owed on the truncation rule's own ground — a limit nobody is told
// about is the failure, and here there was not even a limit.
//
// 1 MiB, and the number is stated in the refusal. It is sixteen times
// the 64 KiB RESPONSE cap and that asymmetry is deliberate: a response
// lands in a model's context, where 64 KiB is already a large fraction
// of the budget, while a request body is composed by the operator or
// resolved from a pane's parts and never lands in context at all. What
// it costs is a file upload, which this tool has never claimed to do and
// which would want a streaming path rather than a bigger number.
//
// A package-level var for the same reason httpBodyCap is one: so a test
// may lower it. Production code never assigns to it, and
// TestHTTPSendBodyCapDefaultIsProductionValue pins the shipped value.
var httpSendBodyCap = 1024 * 1024

// httpSendBodyCapLabel is how the cap is spelled to a human. Derived
// from nothing — it is written out — because a computed "1048576 bytes"
// is a number an operator has to convert before it means anything.
const httpSendBodyCapLabel = "1 MiB"

// defaultSendContentType is what a send WITH A BODY declares when the
// caller names no content type. A body sent with no Content-Type at all
// leaves the server to sniff, and what a write MEANS is the operator's
// statement rather than a guess made downstream; JSON is what every entry
// this tool targets speaks.
//
// It is not defaulted onto an EMPTY body — see httpSend.ContentType.
const defaultSendContentType = "application/json"

// httpSend is the write half of a request: the body, and the content type
// that says what it is. A read passes nil.
//
// **An empty ContentType means send none**, which is how the three wire
// states are represented in two fields: no body and no content type; a
// body with the default content type; a body with the caller's own. A
// `DELETE` with nothing to say is not given a document (#179, story 27).
type httpSend struct {
	Body        string
	ContentType string
}

// doSend is the low-level send primitive, the exact counterpart of
// doRequest: it gates the verb, the window and the body size, and then
// hands everything to the one shared implementation. Like doRequest it
// TRUSTS base was already validated, and like doRequest it is what this
// package's own tests call directly against plain http:// fixtures.
//
// THE ORDER OF THE THREE GATES IS THE ORDER A CALLER CAN ACT ON. The
// verb first, because a read verb here is a caller holding the wrong
// tool and everything after would be answering the wrong question. The
// window second, because outside it no body of any size may leave. The
// cap last, because it is the only one of the three that depends on what
// the caller actually composed.
func doSend(ctx context.Context, base, method, path string, query, headers map[string]string, body, contentType, authRef, authHeader string) (HTTPResult, error) {
	if err := AssertHTTPMutation(method); err != nil {
		return HTTPResult{}, err
	}
	if err := AssertHTTPWindow(); err != nil {
		return HTTPResult{}, err
	}
	if len(body) > httpSendBodyCap {
		// THE EXACT COUNT FIRST, the human label second. Measured on the
		// shipped binary: a body one byte over the cap rendered as "1.0
		// MiB, over this tool's 1 MiB limit", which reads as a refusal
		// of something that is exactly AT the limit — the operator is
		// told the wrong thing about their own request. The rounding is
		// still worth having beside the number, because 1048577 alone
		// asks them to do the division.
		return HTTPResult{}, UserError("request body is " + strconv.Itoa(len(body)) + " bytes (" +
			byteCountLabel(len(body)) + "), over this tool's " + httpSendBodyCapLabel + " limit — nothing was sent. " +
			"A body this size is held in full in three processes and was, until this limit, sent with no refusal and no truncation at all")
	}
	send := httpSend{Body: body, ContentType: strings.TrimSpace(contentType)}
	if body == "" {
		// THE EMPTY WIRE STATE. An empty body sends no body and no
		// Content-Type, so a caller that named one alongside it is
		// contradicting itself — and dropping the value quietly is the
		// silent-overwrite class this tool exists to stop repeating, so
		// it is refused and told which half to remove.
		if send.ContentType != "" {
			return HTTPResult{}, UserError("contentType " + strconv.Quote(send.ContentType) +
				" was given with an empty body — an empty body sends no body and no Content-Type, " +
				"because a request with nothing to say must not be given a document. Send the " +
				"body this content type describes, or drop the content type")
		}
	} else if send.ContentType == "" {
		send.ContentType = defaultSendContentType
	}
	return doHTTP(ctx, base, method, path, query, headers, &send, authRef, authHeader)
}

// DoSend is the production entry point for a write against an api
// entry's baseUrl. It gates on NormalizeHTTPBase FIRST, for the reason
// DoRequest does: a Keychain-held credential must never go out over a
// cleartext connection because a caller forgot to normalize base.
func DoSend(ctx context.Context, base, method, path string, query, headers map[string]string, body, contentType, authRef, authHeader string) (HTTPResult, error) {
	normBase, err := NormalizeHTTPBase(base)
	if err != nil {
		return HTTPResult{}, err
	}
	return doSend(ctx, normBase, method, path, query, headers, body, contentType, authRef, authHeader)
}

// byteCountLabel spells a byte count the way httpSendBodyCapLabel spells
// the cap, so a refusal compares like with like: "1.3 MiB, over this
// tool's 1 MiB limit" is a sentence an operator can act on, where
// "1363149 bytes, over this tool's 1 MiB limit" asks them to do the
// division first.
func byteCountLabel(n int) string {
	switch {
	case n >= 1024*1024:
		return strconv.FormatFloat(float64(n)/(1024*1024), 'f', 1, 64) + " MiB"
	case n >= 1024:
		return strconv.Itoa(n/1024) + " KiB"
	default:
		return strconv.Itoa(n) + " bytes"
	}
}
