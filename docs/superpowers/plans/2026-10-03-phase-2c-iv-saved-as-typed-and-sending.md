# Phase 2c-iv — saved as typed, and sending — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** The api pane sends what it shows. What the operator types is saved within a pause and
before any gesture. A send can be watched and cancelled from either channel. GET carries no body.
An empty body's content type is dropped from the wire instead of refused. The plane names the
whole request. An environment switch re-resolves every pane instead of stranding it at
*"no origin"*.

**Architecture:** The rulings live in WakilKit and the view only calls them.
`ApiSaveAsTyped.swift` (new) turns the boxes' typed text into writes and into the request the screen
shows. Decision 27's mark becomes **focus**, held in `PaneStore`. One serial **surface chain**
on `WindowModel` orders every operator write. It awaits each write and never awaits a send, so a
Cancel is never stuck behind the send it cancels. A send runs as a cancellable task whose
cancellation reaches `wakil-http` as MCP `notifications/cancelled`. Go already threads the call's
context into `http.NewRequestWithContext`, and Task 1 proves the abort.
`ApiPaneResolver` (new, returned by `registerApiActions`) re-resolves api panes after an
environment change with one `list_apis`.

**Tech Stack:** SwiftUI (`WakilApp`, no test target, macOS 14.4), `WakilKit` (swift-testing,
`make app-test`), Go (`go test ./...`), JSONL checks under `e2e/checks/seeded/`.

**Spec:** `docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md`, **Amendment 9**:
9a and 9b, and the parts of 9d that belong to them. Read Amendment 8 (8a–8d), the model this
changes. **9c is out**: W4, W7, W10, W11, W16, W2, W5, W6, W8, W15, W18, W19 and W20 are a
separate plan written after this one, and so are 9d's W16 and Backspace checks. Nothing here moves
a box, a chip's `×` or the response's layout, and nothing here fixes a pane's height. 9c needs all
of those free.

## Global Constraints

- **Every ruling goes in `WakilKit`, not in the view.** A string, an `if` choosing an action, a
  parse or a comparison done inline in `ApiPane` is a ruling nothing can pin. `ApiPane.swift`,
  `ApiBodyTextView.swift` and `Canvas.swift` only call WakilKit.
- **Every dispatch in `ApiPane` goes through `operate(_:_:)`, `operateInOrder(_:)` or
  `operateFlushed(_:)` (Task 4).** All three clear the drop's result line, and all three reach
  `WindowModel.enqueueFromSurface` (Task 3). Nothing in the pane calls `dispatch` directly.
- **Identifiers only on an element with an accessibility action**, such as `Button`, `TextField`,
  the body's `NSTextView` or `Menu`, and never on a `Text`. **At the AppKit level an identifier is
  set only when it changes**. `ApiBodyTextView.updateNSView` already guards this: 10 of 10
  `api.recent` presses answered AXError -25200 without the guard. Keep that guard on every new
  AppKit path.
- **No shipped identifier changes.** `api.send` keeps its identifier while a send is in flight,
  and its action becomes `api_cancel`. This plan adds no identifier.
- **One new action, `api_cancel {pane}`**: `.control`, agent-reachable, and a check drives it down
  both channels. Its parity cannot be expressed, for `api_unbind`'s reason, so it takes one line in
  `uncoverable.tsv` §1 (Task 9) and no other line is added there.
- **No new `read_pane` key except `sending`** (a bool, Task 6) and the Recent row's `cancelled`.
  `read_pane` still publishes no keystroke or focus state.
- **Decision 27's refusal wording is unchanged.** Only what marks a field changes.
- **The pause is 300 ms** (`apiTypingPause`). A write happens **at once** on Return in a
  single-line box, when focus leaves the field, and before Send, a drop, `+ query`, `+ header`,
  `+ hole`, `×`, Format, a method press and an entry pick.
- **In the body, Return is a newline and ⌘Return sends.**
- **Spec strings, verbatim**:
  - *"a send is already in flight on this pane"*
  - *"pick an entry first"*
  - *"cancelled after 4.2 s"*
  - *"cancelled after 4.2 s — the server may already have it"*
  - *"Cancel · 1.2 s"*
  - *"\<env\> declares no entry named \<name\> — pick one"*
  - *"k is a VARBINARY column — binary values arrive corrupted, so they can't be bound"*
- **Tests**: `make app-test` for WakilKit and `go test ./...` for Go. Swift tests use
  swift-testing in `app/Tests/WakilKitTests`. `make app-bundle` and `make controls` are headless.
- **GUI runs (`make e2e`, `make e2e-new`, launching the app) need the operator's OK every time.**
  Quit the live Wakil first, and ask the peer sessions before and tell them after (the shared-GUI
  memory). No task runs a GUI target unless its step says so.

## Review Focus

1. **A debounced write racing an agent's write to the same region.** The operator types in a query
   value, then clicks into the body. That focus-out flushes the query region (a whole-region
   write). An agent's query write must not land between the flush leaving and landing, or the
   flush would erase it. Expected: the focus mark is released **after** the flush lands, because
   the release rides the same surface chain, so the agent is refused until then and its retry
   lands on top. *Task 3, `aFocusReleaseWaitsForTheWriteBeforeIt`.*
2. **Focus leaving a field after Send has already flushed it.** The box still holds text the draft
   now holds, or text whose write is still in flight. Expected: no second, different write, and the
   request sent is the one shown. *Task 2, `textTheDraftHoldsWritesNothing` and
   `aBoxWhoseWriteIsInFlightIsKept`.*
3. **A cancel that arrives after the reply.** `api_cancel` lands in the instant between
   `wakil-http` answering and the send finishing. Expected: the reply is kept and drawn, not
   overwritten as cancelled, and Recent records it as a reply. *Task 6,
   `aReplyThatBeatsTheCancelIsKept`.*
4. **An environment switch while a send is in flight.** Staging's reply lands after the pane was
   cleared for production. Expected: the pane keeps *"cleared — the environment is now
   production"*, and Recent records the send under staging, where it went. *Task 6,
   `aSendThatOutlivesItsEnvironmentLandsInRecentOnly`.*
5. **An "unpointed" pane in a single-entry environment.** `api_open {}`, or a pane restored at
   launch with no entry, in an environment declaring exactly one entry. Expected: it points at
   that entry and is never unpointed. Send is not refused. *Task 7,
   `aSingleEntryEnvironmentNeverLeavesAPaneUnpointed`.*

---

### Task 1: Prove `wakil-http` aborts a cancelled call (W14, Go)

The spec says the plan's first task proves the abort. The read for this plan found `ctx` already
threaded: `cmd/wakil-http/main.go:124` and `:141` pass it to `DoRequest` and `DoSend`, and
`internal/wakilcore/httpclient.go:457` builds the request with `http.NewRequestWithContext`. The
`go-sdk` fork's `canceller` (`mcp/transport.go`, `Preempt`) cancels a handler's context on
`notifications/cancelled`. The test below checks all of that end to end. `http.DefaultTransport`'s
10 s `TLSHandshakeTimeout` would close the connection eventually anyway, so the test bounds the
abort at 2 s.

**Files:**
- Create: `cmd/wakil-http/cancel_test.go`

**Interfaces:**
- Consumes: `setupProject`, `connectedClient` (`cmd/wakil-http/main_test.go:20`, `:56`),
  `wakilcore.WindowMarkerEnv`.
- Produces: nothing Swift reads. Task 6 relies on the fact this proves.

- [ ] **Step 1: Write the test.**

```go
package main

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// stallListener accepts TCP connections and never answers. A TLS client's
// handshake waits on it until the client gives up, so a request to it is on
// the wire and going nowhere — the shape of a slow server, with no
// certificate to trust. closed receives the moment the CLIENT closes a
// connection.
func stallListener(t *testing.T) (addr string, closed <-chan time.Time) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	ch := make(chan time.Time, 4)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 4096)
				for {
					if _, err := c.Read(buf); err != nil {
						ch <- time.Now()
						return
					}
				}
			}(conn)
		}
	}()
	return ln.Addr().String(), ch
}

// W14: a call the window stops waiting for must stop the HTTP request too.
// The go-sdk client sends notifications/cancelled when CallTool's context is
// cancelled; the server's canceller cancels the handler's ctx; DoRequest and
// DoSend build the request with that ctx. If any link is missing, the
// stalled connection stays open until the transport's own 10 s handshake
// timeout — which is what this test refuses.
func TestACancelledCallAbortsTheHTTPRequest(t *testing.T) {
	for _, tc := range []struct {
		tool string
		args map[string]any
	}{
		{"request", map[string]any{"method": "GET", "path": "/stall"}},
		{"send", map[string]any{"method": "POST", "path": "/stall", "body": "{}"}},
	} {
		t.Run(tc.tool, func(t *testing.T) {
			addr, closed := stallListener(t)
			setupProject(t,
				`"staging":{"databases":[],"api":[{"name":"slow","baseUrl":"https://`+addr+`"}]}`,
				"staging")
			t.Setenv(wakilcore.WindowMarkerEnv, "1")
			cs := connectedClient(t)

			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan struct{})
			go func() {
				defer close(done)
				_, _ = cs.CallTool(ctx, &mcp.CallToolParams{Name: tc.tool, Arguments: tc.args})
			}()
			// Long enough to dial and send the ClientHello: the request is on the wire.
			time.Sleep(300 * time.Millisecond)
			cancelledAt := time.Now()
			cancel()

			select {
			case at := <-closed:
				if waited := at.Sub(cancelledAt); waited > 2*time.Second {
					t.Fatalf("the stalled connection closed %s after the cancel — that is a timeout, not an abort", waited)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("the stalled connection was still open 5 s after the cancel: wakil-http did not abort the request")
			}
			<-done
		})
	}
}
```

- [ ] **Step 2: Run it.** `go test ./cmd/wakil-http/ -run TestACancelledCallAbortsTheHTTPRequest -v`.
  Expected: **PASS**. This task is a proof, not a change.
- [ ] **Step 3: Prove the test can fail.** In `cmd/wakil-http/main.go`, temporarily change the
  `DoRequest(ctx, …)` at `:124` and the `DoSend(ctx, …)` at `:141` to
  `DoRequest(context.WithoutCancel(ctx), …)` and `DoSend(context.WithoutCancel(ctx), …)`. Run the
  test again. Expected: **FAIL**, *"still open 5 s after the cancel"*, for both subtests. Revert
  the edit and check that `git diff cmd/wakil-http/main.go` is empty.
- [ ] **Step 4: If Step 2 failed instead.** Stop and report. The abort is Go's job and Task 6
  depends on it. Thread `ctx` into whatever link the failure names: the SDK's server options, or a
  helper between the handler and `http.NewRequestWithContext`. Then come back to Step 2.
- [ ] **Step 5: Run `go test ./...`, then commit.**

```bash
git add cmd/wakil-http/cancel_test.go
git commit -m "wakil-http aborts the HTTP request when the window cancels the call (W14, proved)"
```

### Task 2: The saved-as-typed rulings (9a), and Send writes a typed path first (B5)

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiSaveAsTyped.swift`
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`. Replace `apiSendSequence` (`:1923-1943`)
  and delete `apiBodyWrite` (`:1953-1968`). Make `apiPartsRegionWrite` (`:1750`) internal by
  dropping `private`.
- Modify: `app/Sources/WakilApp/ApiPane.swift:1497-1499`, the one call site of `apiSendSequence`.
- Test: `app/Tests/WakilKitTests/ApiSaveAsTypedTests.swift` (create), and
  `app/Tests/WakilKitTests/ApiHandBindTests.swift:532-600` (the Send-sequence tests, rewritten).

**Interfaces:**
- Consumes: `apiPathBoxWrite`, `ApiPathBoxOutcome` (`ApiPathQuery.swift:245`, `:286`), `apiPartsWrite`
  (`ApiActions.swift:1666`), `apiBoxIsUncommitted` (`:2074`), `apiTyped` (`:1721`),
  `apiFieldRows`, `apiFieldParts`, `apiFieldIsTypable`, `apiPathBoxIsTypable`, `apiFieldWrite`,
  `apiContentTypeCommitIsNoOp`, `apiContentTypeText`, `apiSingleLineText`, `apiPathQueryParse`,
  `apiPathQueryView`, `apiPathQueryWrite`, `apiDraftForWrite`, `apiPartJSON`, `apiSendControl`,
  `apiSendParams`.
- Produces (every later task uses these names):
  ```swift
  public let apiTypingPause: Duration                       // .milliseconds(300)
  public enum ApiPendingWrite: Equatable, Sendable { case write(JSONValue), refused(String), unchanged }
  public func apiPendingWrite(_ request: ApiRequestSnapshot, box: ApiFieldRow, typed: [Int: String], pane: String) -> ApiPendingWrite
  public func apiRequestApplying(_ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]], except: ApiFieldRow? = nil) -> ApiRequestSnapshot
  public struct ApiFlush { public let writes: [(String, JSONValue)]; public let refusals: [ApiFieldRow: String] }
  public func apiFlush(_ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]], pane: String) -> ApiFlush
  public func apiFlushedSequence(_ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]], pane: String, then gesture: (ApiRequestSnapshot) -> [(String, JSONValue)]) -> [(String, JSONValue)]
  public func apiBoxesAfterLanding(_ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]], focused: ApiFieldRow?) -> [ApiFieldRow: [Int: String]]
  public struct ApiFocusedField: Equatable, Sendable { public let box: ApiFieldRow; public let request: ApiRequestSnapshot }
  public func apiRestoreWrite(_ focused: ApiFocusedField, current: ApiRequestSnapshot, pane: String) -> JSONValue?
  public func apiSendSequence(draft: ApiRequestSnapshot, pane: String, boxes: [ApiFieldRow: [Int: String]]) -> [(String, JSONValue)]
  ```
  `ApiFieldRow(.contentType)` is a box from here on. Its text is `typed[0]`.

- [ ] **Step 1: Write the failing tests** in `ApiSaveAsTypedTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// Amendment 9a: what the operator types is written within a pause, and before any gesture.
/// Nothing here holds a timer. These are the values the pane's timer and gestures dispatch.

private func req(
    method: String = "POST", path: [ApiPart] = [], query: [ApiQueryRow] = [],
    headers: [ApiHeaderRegionRow] = ApiRequestSnapshot.empty.headers, body: [ApiPart] = []
) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: method, origin: "https://httpbin.org", path: path, query: query,
        headers: headers, body: body)
}

private func q(_ name: String, _ value: [ApiPart]) -> ApiQueryRow { ApiQueryRow(name: name, value: value) }

@Test("A typed path is one write carrying path and query together")
func aTypedPathIsOneWrite() {
    #expect(apiPendingWrite(req(), box: ApiFieldRow(.path), typed: [0: "/test?page=2"], pane: "p")
        == .write(apiPathQueryWrite(
            path: [.literal("/test")], query: [q("page", [.literal("2")])], pane: "p")))
}

@Test("Text the draft already holds writes nothing")
func textTheDraftHoldsWritesNothing() {
    let r = req(path: [.literal("/test")], body: [.literal("{}")])
    #expect(apiPendingWrite(r, box: ApiFieldRow(.path), typed: [0: "/test"], pane: "p") == .unchanged)
    #expect(apiPendingWrite(r, box: ApiFieldRow(.body), typed: [0: "{}"], pane: "p") == .unchanged)
    #expect(apiFlush(r, boxes: [ApiFieldRow(.path): [0: "/test"]], pane: "p").writes.isEmpty)
}

@Test("A path the view cannot parse is refused in its own words, and nothing is written")
func anUnparsablePathIsRefused() {
    let flush = apiFlush(req(), boxes: [ApiFieldRow(.path): [0: "/o?=x"]], pane: "p")
    #expect(flush.writes.isEmpty)
    #expect(flush.refusals[ApiFieldRow(.path)] == ApiPathQueryRefusal.namelessRow.line)
}

@Test("A typed body, query value, header value and content type each write their field")
func eachFieldWritesItself() {
    let r = req(
        query: [q("page", [.literal("1")])],
        headers: ApiRequestSnapshot.empty.headers + [.operatorRow(name: "x-a", value: [.literal("1")])])
    let flush = apiFlush(r, boxes: [
        ApiFieldRow(.body): [0: "{\n}"],
        ApiFieldRow(.query("page")): [0: "2"],
        ApiFieldRow(.header("x-a")): [0: "2"],
        ApiFieldRow(.contentType): [0: "application/json"],
    ], pane: "p")
    // Wire order: query, header, content type, body.
    #expect(flush.writes.count == 4)
    #expect(flush.writes.allSatisfy { $0.0 == "api_set_request" })
    guard case .object(let last) = flush.writes[3].1 else { Issue.record("not an object"); return }
    #expect(last["body"] == .array([.object(["literal": .string("{\n}")])]))
}

@Test("A locked body is never written, whatever its boxes hold")
func aLockedBodyIsNeverWritten() {
    let r = req(body: [.bound(liveBinding(name: "id"))])
    #expect(apiPendingWrite(r, box: ApiFieldRow(.body), typed: [1: "x"], pane: "p") == .unchanged)
}

@Test("The screen's request applies every box, and a parse refusal leaves path and query alone")
func theAppliedRequestIsWhatTheScreenShows() {
    let r = req(path: [.literal("/a")], query: [q("page", [.literal("1")])])
    let applied = apiRequestApplying(r, boxes: [
        ApiFieldRow(.query("page")): [0: "2"],
        ApiFieldRow(.contentType): [0: "text/plain"],
    ])
    #expect(applied.query == [q("page", [.literal("2")])])
    #expect(apiContentTypeText(applied) == "text/plain")
    #expect(apiRequestApplying(r, boxes: [ApiFieldRow(.path): [0: "/o?=x"]]).path == [.literal("/a")])
    // `except` leaves one box out, so a gesture on that field can carry it against the drawn parts.
    #expect(apiRequestApplying(
        r, boxes: [ApiFieldRow(.query("page")): [0: "2"]], except: ApiFieldRow(.query("page"))).query
        == r.query)
}

@Test("A gesture is built on the request the screen shows, after the flush")
func aGestureIsBuiltOnWhatTheScreenShows() {
    let r = req(query: [q("page", [.literal("1")])])
    var seen: ApiRequestSnapshot?
    let sequence = apiFlushedSequence(r, boxes: [ApiFieldRow(.query("page")): [0: "2"]], pane: "p") {
        applied in
        seen = applied
        return [("api_set_request", .object(["pane": .string("p"), "method": .string("PUT")]))]
    }
    #expect(sequence.map(\.0) == ["api_set_request", "api_set_request"])
    #expect(seen?.query == [q("page", [.literal("2")])])
}

@Test("B5: Send writes a typed path first, and its statement names that path")
func sendWritesATypedPathFirst() {
    let sequence = apiSendSequence(draft: req(), pane: "p", boxes: [ApiFieldRow(.path): [0: "/test"]])
    #expect(sequence.map(\.0) == ["api_set_request", "api_send"])
    guard case .object(let send) = sequence[1].1, case .string(let statement)? = send["statement"]
    else { Issue.record("no statement"); return }
    #expect(statement.hasPrefix("Send POST https://httpbin.org/test"), "\(statement)")
}

@Test("With nothing typed, Send is the send alone")
func sendWithNothingTypedIsTheSendAlone() {
    let r = req(path: [.literal("/v1")])
    #expect(apiSendSequence(draft: r, pane: "p", boxes: [:]).map(\.0) == ["api_send"])
    #expect(apiSendSequence(draft: r, pane: "p", boxes: [ApiFieldRow(.path): [0: "/v1"]]).map(\.0)
        == ["api_send"])
}

@Test("A box whose text the draft now holds is let go once the write lands")
func aLandedBoxIsLetGo() {
    let landed = req(path: [.literal("/test")])
    #expect(apiBoxesAfterLanding(landed, boxes: [ApiFieldRow(.path): [0: "/test"]], focused: nil).isEmpty)
}

@Test("A box whose write is still in flight, or that was typed past it, is kept")
func aBoxWhoseWriteIsInFlightIsKept() {
    // The draft still holds the text from before the write; the box holds newer text.
    let r = req(path: [.literal("/te")])
    let boxes = [ApiFieldRow(.path): [0: "/test"]]
    #expect(apiBoxesAfterLanding(r, boxes: boxes, focused: nil) == boxes)
}

@Test("The focused box keeps a trailing ? that writes nothing; an unfocused one lets it go")
func aTrailingQuestionMarkSurvivesWhileTyping() {
    let r = req(path: [.literal("/o")])
    let boxes = [ApiFieldRow(.path): [0: "/o?"]]
    #expect(apiBoxesAfterLanding(r, boxes: boxes, focused: ApiFieldRow(.path)) == boxes)
    #expect(apiBoxesAfterLanding(r, boxes: boxes, focused: nil).isEmpty)
}

@Test("A box typed against parts that changed shape is let go")
func aBoxOnPartsThatMovedIsLetGo() {
    // Box 2 was the literal after a hole; × removed the hole and the literals merged.
    let r = req(path: [.literal("/a//cd")])
    #expect(apiBoxesAfterLanding(r, boxes: [ApiFieldRow(.path): [2: "/cd"]], focused: nil).isEmpty)
}

@Test("Escape writes back what the field held at focus-in, once, and nothing when it is unchanged")
func escapeRestoresTheFieldAtFocusIn() {
    let then = req(path: [.literal("/v1")], query: [q("a", [.literal("1")])])
    let now = req(path: [.literal("/v1x")], query: [q("a", [.literal("1")])])
    let focused = ApiFocusedField(box: ApiFieldRow(.path), request: then)
    #expect(apiRestoreWrite(focused, current: now, pane: "p")
        == apiPathQueryWrite(path: then.path, query: then.query, pane: "p"))
    #expect(apiRestoreWrite(focused, current: then, pane: "p") == nil)
}

@Test("Escape in one query row puts that row back and keeps the others as they are now")
func escapeInARowRestoresOnlyThatRow() {
    let then = req(query: [q("a", [.literal("1")]), q("b", [.literal("x")])])
    let now = req(query: [q("a", [.literal("19")]), q("b", [.literal("y")])])
    let write = apiRestoreWrite(
        ApiFocusedField(box: ApiFieldRow(.query("a")), request: then), current: now, pane: "p")
    guard case .object(let fields)? = write, case .array(let rows)? = fields["query"] else {
        Issue.record("no query write"); return
    }
    #expect(rows == [
        .object(["name": .string("a"), "value": .array([.object(["literal": .string("1")])])]),
        .object(["name": .string("b"), "value": .array([.object(["literal": .string("y")])])]),
    ])
}
```

Also delete the four Send-sequence tests in `ApiHandBindTests.swift`:
`theSendSequenceWritesTheBodyFirst`, `theSendSequenceIsTheSendAlone`,
`aReadSendsThroughApiRequest` and the locked-body Send test at `:578`. The tests above replace
them. Add one more there:

```swift
@Test("A GET sends through api_request, the typed body still written first")
func aReadSendsThroughApiRequest() {
    let draft = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [])
    #expect(apiSendSequence(draft: draft, pane: "p", boxes: [ApiFieldRow(.body): [0: "x"]]).map(\.0)
        == ["api_set_request", "api_request"])
}
```

- [ ] **Step 2: Run and watch them fail.**
  `make app-test 2>&1 | grep -E "ApiSaveAsTyped|error:" | head`. Expect
  `cannot find 'apiPendingWrite' in scope`.
- [ ] **Step 3: Implement `ApiSaveAsTyped.swift`.**

```swift
import Foundation

/// Amendment 9a — **saved as typed.** A typed change is written `apiTypingPause` after the last
/// keystroke, and at once on Return, on focus leaving the field, and before any gesture that
/// reads or rewrites the draft. **Nothing is ever uncommitted**: a box holds text only for the
/// pause, and for as long as the write carrying it is in flight. Every function here is a value
/// function. `ApiPane` holds the timer and calls them.
///
/// What this retires: Ruling 8's cross-field refusal, Ruling 16's drop refusal, and the row `×`'s
/// wait for a twin's typing. Each existed because typed text could be left behind, and none can
/// be now.

public let apiTypingPause: Duration = .milliseconds(300)

/// What one box's typed text would write right now.
public enum ApiPendingWrite: Equatable, Sendable {
    /// One `api_set_request` to dispatch.
    case write(JSONValue)
    /// The text cannot be written as it stands. Only the path box's parse refuses, and this is
    /// its line, drawn in amber under the URL.
    case refused(String)
    /// The draft already holds what the box shows.
    case unchanged
}

public func apiPendingWrite(
    _ request: ApiRequestSnapshot, box: ApiFieldRow, typed: [Int: String], pane: String
) -> ApiPendingWrite {
    switch box.field {
    case .method:
        return .unchanged
    case .contentType:
        guard let text = typed[0].map(apiSingleLineText),
              !apiContentTypeCommitIsNoOp(request, text: text)
        else { return .unchanged }
        return .write(apiFieldWrite(field: .contentType, text: text, pane: pane))
    case .path:
        guard apiPathBoxIsTypable(request),
              let index = typed.keys.sorted().first, let text = typed[index]
        else { return .unchanged }
        switch apiPathBoxWrite(request, edit: .text(index: index, text), typed: typed, pane: pane) {
        case .write(let params): return .write(params)
        case .refused(let line): return .refused(line)
        case .unchanged, .nothing: return .unchanged
        }
    case .query, .header, .body:
        guard apiFieldIsTypable(request, box.field),
              apiBoxIsUncommitted(request, box, typed: typed),
              let index = typed.keys.sorted().first, let text = typed[index],
              let params = apiPartsWrite(
                  draft: request, field: box.field, edit: .text(index: index, text),
                  pane: pane, row: box.row, typed: typed)
        else { return .unchanged }
        return .write(params)
    }
}

/// The request as the screen shows it: the draft with every box's typed text applied.
///
/// **What every gesture is built on**, so a gesture never writes a region back from the draft as
/// it stood before the operator's last keystrokes. `except` leaves one box out. A gesture on that
/// field carries the box itself, against the parts the view drew, so the box's indices stay the
/// view's. A path box whose parse refuses changes neither path nor query. A locked field is
/// never applied.
public func apiRequestApplying(
    _ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]],
    except: ApiFieldRow? = nil
) -> ApiRequestSnapshot {
    var path = request.path
    var query = request.query
    var headers = request.headers
    var body = request.body
    func typedParts(_ parts: [ApiPart], _ typed: [Int: String]) -> [ApiPart] {
        apiTyped(parts, typed).filter { part in
            if case .literal(let text) = part { return !text.isEmpty }
            return true
        }
    }
    for (key, typed) in boxes where key != except {
        switch key.field {
        case .path:
            guard apiPathBoxIsTypable(request),
                  case .success(let parsed) = apiPathQueryParse(
                      apiTyped(apiPathQueryView(path: request.path, query: request.query), typed))
            else { continue }
            path = parsed.path
            query = parsed.query
        case .query(let name):
            guard apiFieldIsTypable(request, key.field) else { continue }
            var seen = 0
            query = query.map { row in
                guard row.name == name else { return row }
                defer { seen += 1 }
                return seen == key.row ? ApiQueryRow(name: name, value: typedParts(row.value, typed)) : row
            }
        case .header(let name):
            guard apiFieldIsTypable(request, key.field) else { continue }
            var seen = 0
            headers = headers.map { row in
                // `apiRowOccurrence`'s own predicate, so the two count the same rows.
                guard row.name == name, row.isEditable, let value = row.value else { return row }
                defer { seen += 1 }
                return seen == key.row
                    ? ApiHeaderRegionRow(
                        name: name, value: typedParts(value, typed),
                        provenance: row.provenance, rowClass: row.rowClass)
                    : row
            }
        case .contentType:
            guard let text = typed[0] else { continue }
            let trimmed = apiSingleLineText(text).trimmingCharacters(in: .whitespacesAndNewlines)
            headers = headers.map { row in
                guard row.rowClass == .derived else { return row }
                return ApiHeaderRegionRow(
                    name: row.name, value: trimmed.isEmpty ? nil : [.literal(trimmed)],
                    provenance: row.provenance, rowClass: .derived)
            }
        case .body:
            guard apiFieldIsTypable(request, .body) else { continue }
            body = typedParts(request.body, typed)
        case .method:
            continue
        }
    }
    return ApiRequestSnapshot(
        method: request.method, origin: request.origin, path: path, query: query,
        headers: headers, body: body)
}

/// The writes that make the draft hold what the boxes show, in wire order, and the path box's
/// parse refusal when there is one.
///
/// **At most one box is dirty in practice.** Focus leaving a field flushes it, so only the field
/// the cursor is in can hold unwritten text. Each write is built against the draft as drawn. Two
/// dirty boxes that write one region (the path box and a query row) are not a state the pane can
/// reach.
public struct ApiFlush {
    public let writes: [(String, JSONValue)]
    public let refusals: [ApiFieldRow: String]
}

public func apiFlush(
    _ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]], pane: String
) -> ApiFlush {
    var writes: [(String, JSONValue)] = []
    var refusals: [ApiFieldRow: String] = [:]
    let ordered = boxes.keys.sorted { left, right in
        left.field != right.field ? left.field < right.field : left.row < right.row
    }
    for key in ordered {
        switch apiPendingWrite(request, box: key, typed: boxes[key] ?? [:], pane: pane) {
        case .write(let params): writes.append(("api_set_request", params))
        case .refused(let line): refusals[key] = line
        case .unchanged: break
        }
    }
    return ApiFlush(writes: writes, refusals: refusals)
}

/// A gesture's calls, preceded by the flush: the flush's writes, then `gesture`'s calls built
/// against the request the screen shows. One sequence, dispatched in order.
public func apiFlushedSequence(
    _ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]], pane: String,
    then gesture: (ApiRequestSnapshot) -> [(String, JSONValue)]
) -> [(String, JSONValue)] {
    apiFlush(request, boxes: boxes, pane: pane).writes
        + gesture(apiRequestApplying(request, boxes: boxes))
}

/// The boxes still worth keeping once a snapshot lands.
///
/// **A box is kept while its write is still owed**: in flight, or typed past the write that
/// landed, or refused (its amber line explains it). It is let go once the draft holds what it
/// shows. **The focused box is kept even when it would write nothing.** `/o?` parses to the same
/// draft as `/o`, and dropping it mid-word would eat the `?`. Text typed against parts that have
/// since changed shape is let go, because its boxes no longer exist. That covers a typed index
/// past the end, or one that now sits on a chip.
public func apiBoxesAfterLanding(
    _ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]], focused: ApiFieldRow?
) -> [ApiFieldRow: [Int: String]] {
    boxes.filter { key, typed in
        let parts: [ApiPart]
        switch key.field {
        case .method:
            return false
        case .contentType:
            return key == focused
                || apiPendingWrite(request, box: key, typed: typed, pane: "") != .unchanged
        case .path:
            parts = apiPathQueryView(path: request.path, query: request.query)
        case .query, .header, .body:
            let rows = apiFieldRows(request, key.field)
            guard rows.indices.contains(key.row) else { return false }
            parts = rows[key.row]
        }
        let fits = typed.keys.allSatisfy { index in
            if index == parts.count { return true }
            guard parts.indices.contains(index), case .literal = parts[index] else { return false }
            return true
        }
        guard fits else { return false }
        return key == focused
            || apiPendingWrite(request, box: key, typed: typed, pane: "") != .unchanged
    }
}

/// The field the cursor is in, and the request as it stood when the cursor arrived — what
/// Escape writes back (9a).
public struct ApiFocusedField: Equatable, Sendable {
    public let box: ApiFieldRow
    public let request: ApiRequestSnapshot

    public init(box: ApiFieldRow, request: ApiRequestSnapshot) {
        self.box = box
        self.request = request
    }
}

/// **Escape writes the field back to what it held when it took focus, as one write.** It is
/// `nil` when the field already holds that. For a row, the whole region is written with that
/// one row put back and every other row as it is now. The other rows are not this Escape's to
/// undo.
public func apiRestoreWrite(
    _ focused: ApiFocusedField, current: ApiRequestSnapshot, pane: String
) -> JSONValue? {
    let then = focused.request
    func json(_ parts: [ApiPart]) -> [JSONValue] { parts.map { apiPartJSON($0, sources: [:]) } }
    switch focused.box.field {
    case .method:
        return nil
    case .path:
        guard then.path != current.path || then.query != current.query else { return nil }
        return apiPathQueryWrite(path: then.path, query: then.query, pane: pane)
    case .body:
        guard then.body != current.body else { return nil }
        return .object(["pane": .string(pane), "body": .array(json(then.body))])
    case .contentType:
        let text = apiContentTypeText(then)
        guard text != apiContentTypeText(current) else { return nil }
        return apiFieldWrite(field: .contentType, text: text, pane: pane)
    case .query(let name), .header(let name):
        let field = focused.box.field
        let was = apiFieldParts(then, field, row: focused.box.row)
        guard was != apiFieldParts(current, field, row: focused.box.row) else { return nil }
        let draft = apiDraftForWrite(current)
        let rows: [(name: String, value: [ApiPart])]
        let key: String
        if case .query = field {
            rows = draft.query.map { ($0.name, $0.value) }
            key = "query"
        } else {
            rows = draft.headers.map { ($0.name, $0.value) }
            key = "headers"
        }
        return .object([
            "pane": .string(pane),
            key: apiPartsRegionWrite(rows, editing: name, row: focused.box.row, written: json(was)),
        ])
    }
}
```

  Replace `apiSendSequence` in `ApiActions.swift:1909-1943`. Keep its doc comment's first
  paragraph and rewrite the second:

```swift
/// What Send dispatches, in order: every box's pending write, then the send (9a; B5).
///
/// **B5:** Send committed a typed body (8c) but not a typed path, so the box showed `/test` while
/// the request went to the bare origin. Now every box is flushed first, and the send's params
/// are built from the request the screen shows. So `api_send`'s statement, read back on the
/// confirmation plane, names what will actually leave.
public func apiSendSequence(
    draft: ApiRequestSnapshot, pane: String, boxes: [ApiFieldRow: [Int: String]]
) -> [(String, JSONValue)] {
    let control = apiSendControl(method: draft.method)
    return apiFlushedSequence(draft, boxes: boxes, pane: pane) { applied in
        [(control.action, apiSendParams(draft: applied, pane: pane, origin: draft.origin))]
    }
}
```

  Delete `apiBodyWrite` (`:1953-1968`). It has no other caller. In `ApiPane.swift:1497` the call
  becomes `apiSendSequence(draft: snapshot.request, pane: pane.id, boxes: boxes)`.
- [ ] **Step 4: Run and watch it pass.**
  `make app-test 2>&1 | grep -E "ApiSaveAsTyped|ApiHandBind|passed|failed" | tail`, then
  `make app-bundle` (headless) to prove the view still compiles.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiSaveAsTyped.swift app/Sources/WakilKit/Api/ApiActions.swift \
  app/Sources/WakilApp/ApiPane.swift app/Tests/WakilKitTests/ApiSaveAsTypedTests.swift \
  app/Tests/WakilKitTests/ApiHandBindTests.swift
git commit -m "Saved as typed: the writes the boxes owe, and Send writes a typed path first (B5)"
```

### Task 3: Decision 27 by focus, and one ordered chain for the operator's calls

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiDraftAuthor.swift`. Delete `ApiFieldEdit` (`:119-140`),
  `ApiSendOutcome` and `apiSendClearsEditMarks` (`:198-237`). Change `apiDraftCollisions`
  (`:184-196`). Add `apiFocusMarks`.
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift`. In `ApiContents` (`:242-250`), replace
  `edits` with `focused` and `focusGeneration`. Replace `noteApiEdit` / `apiEdits` /
  `clearApiEdits` (`:639-679`). In `reopenApiRow` (`:631`), delete `contents.edits = [:]`.
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`. The `api_set_request` handler (`:543-550`)
  and `refuseIfUnderTheOperatorsHand` (`:1105-1116`) read focus. Delete `apiFieldMark`
  (`:1855-1869`). Rewrite `api_set_request`'s description paragraph *"ONE PANE, ONE DRAFT, ONE
  AUTHOR …"* (`:479-487`) from *"while the operator has unsaved edits in a field it names"* to
  *"while the operator's cursor is in a field it names"*.
- Modify: `app/Sources/WakilKit/Api/ApiPathQuery.swift`. Delete `apiPathBoxOwnMark`,
  `apiComposedMark`, `apiPathBoxMarks` and `apiFieldMarks` (`:315-458`, the mark functions only).
  Keep `apiQueryRegionMark` (`:351`).
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`. Replace `noteApiEdit` (`:2911-2924`). Add
  the surface chain beside `dispatchFromSurfaceInOrder` (`:4039-4045`).
  `bindFromSurface` (`:4077`) waits for the chain.
- Modify: `app/Sources/WakilApp/ApiPane.swift`. Replace `noteEdit` with `noteFocus` and
  `releaseFocus`, replace `markField` with `focusChanged`, and give `field(…)` a `focus:` callback.
- Modify: `app/Sources/WakilApp/ApiBodyTextView.swift`. Add a `focusChanged` callback, raised by
  the responder.
- Modify: `app/Sources/WakilApp/Canvas.swift:346-368`. The pane's dispatch closures go through
  `enqueueFromSurface`.
- Modify: `docs/wakil/decisions.md`. Add Decision 27's dated amendment.
- Test: `app/Tests/WakilKitTests/ApiDraftAuthorTests.swift`,
  `app/Tests/WakilKitTests/WindowModelTests.swift`, `app/Tests/WakilKitTests/ApiPathQueryTests.swift`
  and `app/Tests/WakilKitTests/ApiHandBindTests.swift`. The mark tests are deleted (listed in
  Step 1).

**Interfaces:**
- Consumes: `ApiDraftField`, `ApiWriteKey.overwrites`, `apiQueryRegionMark`, `ApiFieldRow`.
- Produces:
  ```swift
  public func apiDraftCollisions(origin: ActionOrigin, writing keys: [ApiWriteKey], focused: Set<ApiDraftField>) -> [ApiDraftField]
  public func apiFocusMarks(_ field: ApiDraftField) -> Set<ApiDraftField>   // .path → [.path, apiQueryRegionMark]
  // PaneStore
  public func setApiFocus(paneId: String, fields: Set<ApiDraftField>, generation: Int)
  public func apiFocus(paneId: String) -> Set<ApiDraftField>
  // WindowModel
  public func noteApiFocus(pane: String, fields: Set<ApiDraftField>, generation: Int) async
  public func enqueueFromSurface(_ calls: [(String, JSONValue)])
  public func enqueueFocusRelease(pane: String, generation: Int)
  func surfaceChainSettled() async                     // tests only
  public func apiSurfaceCallDetaches(_ name: String) -> Bool   // free function, api_request / api_send
  ```

- [ ] **Step 1: Write the failing tests.** In `ApiDraftAuthorTests.swift`, delete
  `typingAndRestoringTheOriginalTextIsClean`,
  `aMarkGoesCleanWhenTheFieldIsRenderedIntoAndNotBecauseAWriteLanded`,
  `addingOneQueryRowLeavesTheMarkOnTheRowTheOperatorIsStillIn` and
  `aSendThatLeavesTheWindowClearsTheMarksAndARefusedSendClearsNothing`. In the tests that remain,
  rewrite each `noteApiEdit(paneId:field:currentText:lastRendered:)` as
  `setApiFocus(paneId:fields:[field], generation: n)` and each `apiEdits(paneId:)` as
  `apiFocus(paneId:)`. Rewrite the policy tests at `:17-90` on `focused:`:

```swift
@Test func anAgentWriteNamingTheFieldTheCursorIsInCollidesWithIt() {
    #expect(apiDraftCollisions(origin: .agent, writing: [.path], focused: [.path]) == [.path])
}

@Test func theOperatorsOwnWriteLandsInTheFieldTheyAreIn() {
    #expect(apiDraftCollisions(origin: .ui, writing: [.path, .body], focused: [.path, .body]).isEmpty)
}

@Test func thePathBoxMarksThePathAndTheWholeQueryRegion() {
    // 8a's view: the path box shows the query, so an agent may write neither under the cursor.
    let marks = apiFocusMarks(.path)
    #expect(marks == [.path, apiQueryRegionMark])
    #expect(apiDraftCollisions(origin: .agent, writing: [.query], focused: marks) == [apiQueryRegionMark])
    #expect(apiDraftCollisions(origin: .agent, writing: [.path, .query], focused: marks).map(\.label)
        == ["Path", "Query"])
}

@Test func aWriteNamingOnlyFieldsTheCursorIsNotInLands() {
    #expect(apiDraftCollisions(origin: .agent, writing: [.method, .body], focused: [.path]).isEmpty)
}

@Test func theStoreHoldsTheFocusAndALateReleaseNeverClearsANewerOne() async {
    let panes = PaneStore()
    await panes.setApiFocus(paneId: "api-1", fields: [.body], generation: 2)
    // A release from an earlier focus arrives late, after the cursor moved on.
    await panes.setApiFocus(paneId: "api-1", fields: [], generation: 1)
    #expect(await panes.apiFocus(paneId: "api-1") == [.body])
    await panes.setApiFocus(paneId: "api-1", fields: [], generation: 3)
    #expect(await panes.apiFocus(paneId: "api-1").isEmpty)
}

@Test func leavingTheFieldReleasesItAndTheAgentsRetryLands() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    await f.panes.setApiFocus(paneId: paneId, fields: apiFocusMarks(.path), generation: 1)
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["path": .array([literal("/agent")])])
    }
    await f.panes.setApiFocus(paneId: paneId, fields: [], generation: 2)
    try await setRequest(f, pane: paneId, ["path": .array([literal("/agent")])])
    #expect(await f.panes.apiDraft(paneId: paneId).path == [.literal("/agent")])
}
```

  `readPanePublishesNoDirtinessKey` becomes `readPanePublishesNoFocusKey`. Its loop sets focus on
  all six fields, asserts `apiFocus(...).count == 6`, and asserts the published JSON is unchanged.

  In `ApiPathQueryTests.swift`, delete the mark tests at `:273`, `:285`, `:312`, `:328`, `:336`,
  `:424`, `:440` and `:463`. In `ApiHandBindTests.swift`, delete `:221`, `:240` and `:487` (the
  `apiFieldMark` tests). Run
  `grep -n "apiFieldMark\|apiPathBoxMarks\|apiComposedMark\|apiFieldMarks\|ApiFieldEdit\|noteApiEdit" app/Tests -r`
  and make it come back empty.

  In `WindowModelTests.swift`, next to `dispatchFromSurfaceInOrderAwaitsEach` (`:1182`):

```swift
// MARK: - the surface chain (2c-iv Amendment 9a)

private actor TestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// Two calls the pane made separately land in the order it made them: a debounced write and the
/// gesture after it are two enqueues, and the gesture must not overtake the write.
@Test @MainActor func surfaceCallsLandInTheOrderThePaneMadeThem() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_first", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            await log.append("first started")
            try await Task.sleep(nanoseconds: 50_000_000)
            await log.append("first returned")
            return .object([:])
        }))
    await registry.register(Action(
        name: "test_second", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await log.append("second started"); return .object([:]) }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    model.enqueueFromSurface([("test_first", .object([:]))])
    model.enqueueFromSurface([("test_second", .object([:]))])
    await model.surfaceChainSettled()

    #expect(await log.entries == ["first started", "first returned", "second started"])
}

/// A send is started and not awaited, so a write typed during it, or a Cancel, is not stuck
/// behind it.
@Test @MainActor func aSendDoesNotHoldTheSurfaceChain() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    let gate = TestGate()
    await registry.register(Action(
        name: "api_request", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await gate.wait(); return .object([:]) }))
    await registry.register(Action(
        name: "test_after", description: "", kind: .read, schema: .object([:]),
        handler: { _ in await log.append("after"); return .object([:]) }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    model.enqueueFromSurface([("api_request", .object([:]))])
    model.enqueueFromSurface([("test_after", .object([:]))])
    await model.surfaceChainSettled()
    #expect(await log.entries == ["after"])
    await gate.release()
}

/// Review Focus 1: the focus mark is released only after the flush queued before it has landed.
/// So an agent's write cannot land between the flush leaving and landing, which would let the
/// flush erase it.
@Test @MainActor func aFocusReleaseWaitsForTheWriteBeforeIt() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let log = OrderLog()
    await registry.register(Action(
        name: "test_flush", description: "", kind: .read, schema: .object([:]),
        handler: { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            await log.append("focus while flushing: \(await panes.apiFocus(paneId: "api-1").count)")
            return .object([:])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", lookup: AlwaysSucceedsCredentialsLookup())

    await model.noteApiFocus(pane: "api-1", fields: apiFocusMarks(.path), generation: 1)
    model.enqueueFromSurface([("test_flush", .object([:]))])
    model.enqueueFocusRelease(pane: "api-1", generation: 2)
    await model.surfaceChainSettled()

    #expect(await log.entries == ["focus while flushing: 2"])
    #expect(await panes.apiFocus(paneId: "api-1").isEmpty)
}

@Test func onlyTheTwoSendsDetachFromTheChain() {
    #expect(apiSurfaceCallDetaches("api_request"))
    #expect(apiSurfaceCallDetaches("api_send"))
    #expect(!apiSurfaceCallDetaches("api_set_request"))
    #expect(!apiSurfaceCallDetaches("api_cancel"))
}
```

- [ ] **Step 2: Run and watch them fail** (`cannot find 'apiFocusMarks' in scope`,
  `… 'enqueueFromSurface' …`).
- [ ] **Step 3: Implement the WakilKit half.**
  - `ApiDraftAuthor.swift`. Rewrite the `ApiFieldEdit` doc block (*"Dirtiness is by CONTENT …
    Focus plays no part"*) into the one below, and delete `ApiFieldEdit`, `ApiSendOutcome` and
    `apiSendClearsEditMarks`:

```swift
/// **The mark is FOCUS** (Decision 27, amended 2026-10-03; Amendment 9a). The pane saves as
/// typed, so "unsaved" no longer exists to be measured. A field is under the operator's hand
/// while the cursor is in it: marked on focus in, released on focus out once that field's last
/// write has landed (`WindowModel.enqueueFocusRelease`).
public func apiFocusMarks(_ field: ApiDraftField) -> Set<ApiDraftField> {
    // 8a: the path box shows the query too, so it marks the whole Query region.
    field == .path ? [.path, apiQueryRegionMark] : [field]
}

public func apiDraftCollisions(
    origin: ActionOrigin, writing keys: [ApiWriteKey], focused: Set<ApiDraftField>
) -> [ApiDraftField] {
    guard origin != .ui else { return [] }
    return focused.filter { field in keys.contains { $0.overwrites(field) } }.sorted()
}
```

  - `PaneStore.swift`. In `ApiContents`, replace `edits` with:

```swift
        /// The fields the operator's cursor is in (Decision 27, amended 2026-10-03), which is
        /// what an agent's write is refused over. **Beside the draft, never published.**
        var focused: Set<ApiDraftField> = []
        /// The surface's count of focus changes. A release that arrives late carries an older
        /// count and never clears a newer focus.
        var focusGeneration = 0
```

  Replace the three mark methods with:

```swift
    /// Records which fields the cursor is in, unless `generation` is older than the last one
    /// recorded. The surface counts its focus changes, and a release queued behind a write can
    /// arrive after the cursor has already moved on.
    public func setApiFocus(paneId: String, fields: Set<ApiDraftField>, generation: Int) {
        var contents = api(paneId)
        guard generation >= contents.focusGeneration else { return }
        contents.focused = fields
        contents.focusGeneration = generation
        setApi(paneId, contents)
    }

    /// What `apiDraftCollisions` reads, and nothing else. **Not published**, because `read_pane`
    /// reports the screen, not where the cursor is.
    public func apiFocus(paneId: String) -> Set<ApiDraftField> { api(paneId).focused }
```

  Delete `contents.edits = [:]` in `reopenApiRow` and the paragraph *"The marks are cleared with
  it"*. Reopening moves no cursor.
  - `ApiActions.swift`. At `:547` and `:1110`, pass `focused: await panes.apiFocus(paneId: paneId)`.
    Delete `apiFieldMark`. If `grep -rn "apiFieldTypedText" app/Sources` then finds no caller,
    delete `apiFieldTypedText` (`:1737`) too.
  - `ApiPathQuery.swift`. Delete the four mark functions.
  - `WindowModel.swift`:

```swift
    /// The fields of an api pane the operator's cursor is in (Decision 27 by focus). **Set at
    /// once on focus in**, not through the chain, so an agent is refused from the first instant.
    public func noteApiFocus(pane: String, fields: Set<ApiDraftField>, generation: Int) async {
        await panes.setApiFocus(paneId: pane, fields: fields, generation: generation)
    }

    /// The operator's calls from an api pane, **in the order the pane made them** (9a). A
    /// debounced write, a focus-out flush and a gesture are separate enqueues, and a later one
    /// must never overtake an earlier one: a gesture writes its region whole, and overtaking would
    /// erase the write before it. Each call is awaited, **except a send**
    /// (`apiSurfaceCallDetaches`). A send is started and left running, so a write typed during
    /// it, or the Cancel that ends it, is not held behind it.
    @ObservationIgnored private var surfaceChain: Task<Void, Never>?

    public func enqueueFromSurface(_ calls: [(String, JSONValue)]) {
        guard !calls.isEmpty else { return }
        let previous = surfaceChain
        surfaceChain = Task { @MainActor [weak self] in
            await previous?.value
            await self?.dispatchFromSurfaceInOrder(calls)
        }
    }

    /// Releases a pane's focus mark **after** every call queued before it has landed (Review
    /// Focus 1). The focus-out flush rides the chain, so the agent stays refused until the
    /// field's last write is on the draft.
    public func enqueueFocusRelease(pane: String, generation: Int) {
        let previous = surfaceChain
        surfaceChain = Task { @MainActor [weak self] in
            await previous?.value
            await self?.panes.setApiFocus(paneId: pane, fields: [], generation: generation)
        }
    }

    /// For tests: waits until everything enqueued so far has landed.
    func surfaceChainSettled() async { await surfaceChain?.value }
```

  In `dispatchFromSurfaceInOrder`, change the loop to:

```swift
        for (name, params) in calls {
            if apiSurfaceCallDetaches(name) {
                // Started, not awaited: see `enqueueFromSurface`.
                Task { @MainActor [weak self] in await self?.dispatchFromSurfaceRan(name, params) }
                continue
            }
            guard await dispatchFromSurfaceRan(name, params) else { return }
        }
```

  Add next to it a free function, public so `ApiPane` can read the same answer:

```swift
/// The surface calls the chain starts and does not await (9a, W14): the two sends.
public func apiSurfaceCallDetaches(_ name: String) -> Bool {
    name == "api_request" || name == "api_send"
}
```

  At the top of `bindFromSurface` (`:4077`), add `await surfaceChain?.value`. A drop lands after
  the flush the pane queued for it (Task 4). Delete `noteApiEdit` and its doc comment.
- [ ] **Step 4: Wire the view.**
  - `ApiPane.swift`. Replace the `noteEdit` property (`:42-47`) and its `init` parameter with:

```swift
    /// Decision 27 by focus: the fields the cursor is now in, and this pane's focus count.
    let noteFocus: (_ fields: Set<ApiDraftField>, _ generation: Int) -> Void
    /// Releases the focus mark once every call queued before it has landed
    /// (`WindowModel.enqueueFocusRelease`).
    let releaseFocus: (_ generation: Int) -> Void
```

  Add state, and `focusChanged`, which replaces `markField` (`:1326-1340`):

```swift
    /// The field the cursor is in and the request at that moment (`ApiFocusedField`).
    @State private var focusedIn: ApiFocusedField?
    /// This pane's count of focus changes, carried on every mark and release.
    @State private var focusGeneration = 0

    /// Focus in marks the field for Decision 27. Focus out releases it, after the field's write.
    /// **Only the field that last took focus may release**, because moving from A to B can
    /// deliver B's focus-in before A's focus-out.
    private func focusChanged(_ box: ApiFieldRow, _ took: Bool) {
        if took {
            focusedIn = ApiFocusedField(box: box, request: snapshot.request)
            focusGeneration += 1
            noteFocus(apiFocusMarks(box.field), focusGeneration)
        } else if focusedIn?.box == box {
            focusedIn = nil
            focusGeneration += 1
            releaseFocus(focusGeneration)
        }
    }
```

  In `field(…)`, `lineBox(…)` and `editorBox(…)`, replace the `mark: (String) -> Void` parameter
  with `focus: @escaping (Bool) -> Void`. In `lineBox`, replace
  `.onChange(of: single.wrappedValue) { _, now in mark(now) }` with
  `.onChange(of: focusedBox == identifier) { _, now in focus(now) }`. In `editorBox`, delete the
  `onChange` and pass `focusChanged: focus` to `ApiBodyTextView`. `literalBox` passes
  `focus: { focusChanged(box, $0) }`. The content-type field passes
  `focus: { focusChanged(ApiFieldRow(.contentType), $0) }`. Delete every remaining `markField(…)`
  call (`:1006`, `:1268`, `:887`, `:810`) and `pathMarkedNames` (`:88`). `forgetContentType`
  loses its `noteEdit` line.
  - `ApiBodyTextView.swift`. Add `let focusChanged: (Bool) -> Void` after `discard`. In
    `BodyNSTextView`, add:

```swift
    /// Decision 27 by focus (9a): the body's cursor arriving and leaving. **Deferred to the next
    /// turn of the main queue**, because a responder change can arrive while SwiftUI is updating
    /// the view, and state must not be written during an update.
    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { DispatchQueue.main.async { [weak self] in self?.coordinator?.parent.focusChanged(true) } }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.coordinator?.parent.focusChanged(false) } }
        return resigned
    }
```

  - `Canvas.swift:346-368`:

```swift
                    dispatch: { name, params in model.enqueueFromSurface([(name, params)]) },
                    // 9a: one ordered chain for every call the pane makes.
                    dispatchInOrder: { calls in model.enqueueFromSurface(calls) },
                    entries: (model.apiSnapshots[pane.id] ?? .empty).entries,
                    noteFocus: { fields, generation in
                        Task {
                            await model.noteApiFocus(
                                pane: pane.id, fields: fields, generation: generation)
                        }
                    },
                    releaseFocus: { generation in
                        model.enqueueFocusRelease(pane: pane.id, generation: generation)
                    },
```

- [ ] **Step 5: Amend Decision 27.** In `docs/wakil/decisions.md`, after the *Reverse if:*
  paragraph of Decision 27 that ends *"…and `term_run` is not."* (`:729`), add:

```markdown
    *(Amended 2026-10-03 by 2c-iv Amendment 9a: **the mark is focus, not unsaved text.** The
    pane now saves as typed. A typed change is written ~300 ms after the last keystroke, and at
    once on Return, on leaving the field and before any gesture, so "unsaved" no longer exists
    to be measured. The content comparison above (`currentText == lastRendered`) is retired
    with `ApiFieldEdit`. **An agent's write to a draft request is refused whole while the
    operator's cursor is in a field it names.** The mark is set on focus in and cleared on focus
    out once that field's last write has landed. The path box marks both the path and the Query
    region, as 8a's keystroke did. The refusal, its aggregation, its origin rule and its wording
    are unchanged, and `read_pane` publishes neither keystroke nor focus. Leaving the field
    releases it, so the agent's retry lands. The clearing-by-send rule above goes with the
    content marks, because a send does not move the cursor. *Reverse if:* the cursor turns out
    to sit in a field for long stretches while nobody is editing. The answer then is an idle
    timeout on the mark, not a return to comparing text.)*
```

- [ ] **Step 6: Run.** `make app-test`, `make app-bundle` and `make controls`, all headless. No
  `make e2e`.
- [ ] **Step 7: Commit.**

```bash
git add app/Sources/WakilKit app/Sources/WakilApp app/Tests/WakilKitTests docs/wakil/decisions.md
git commit -m "Decision 27 by focus, and one ordered chain for every call an api pane makes"
```

Then: `superpowers:requesting-code-review` for Phase 1 (Tasks 1–3).

---

### Task 4: The pane writes on a pause (9a, the view)

**Files:**
- Modify: `app/Sources/WakilApp/ApiPane.swift`. The state (`:60-115`), `operate` /
  `operateInOrder` (`:248-268`), `drop` (`:281`), `methodControl` (`:338`), `chooser` (`:406`),
  `headerValue` (`:542-580`), `addRow` (`:753`), `removeControl` (`:779-830`), `formatControl`
  (`:877`), `fieldFlow` (`:977-1068`), `fieldNotes` (`:1086`), `write` / `holeWrite` /
  `pathWrite` (`:1209-1278`), `literalBox` (`:1300`), `discard` (`:1346`), `lineBox` (`:1402`),
  `editorBox` (`:1444`) and `sendControl` (`:1490`).
- Modify: `app/Sources/WakilApp/ApiBodyTextView.swift`, the Coordinator's Escape and ⌘Return.
- Modify: `app/Sources/WakilKit/Api/ApiPathQuery.swift`. Delete `ApiPathQueryWriter`,
  `apiPathQueryCrossLineQuery`, `apiPathQueryCrossLinePath`, `apiBoxesDiscarding` and
  `apiPathQueryCrossRefusal` (`:386-445`).
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`. Delete `apiDropRefusal` (`:2033-2067`).
  Keep `apiBoxIsUncommitted`, which `apiPendingWrite` uses, and change its doc comment's first
  line to *"Whether one split-field row's boxes hold text the draft does not"*.
- Modify: `app/Sources/WakilKit/Api/ApiRows.swift`. Delete `apiRowRemoveRefusal` (`:187-205`), and
  in `apiBoxesRemovingRow`'s doc comment delete the sentence that names it.
- Test: delete the tests that pin the removed refusals. In `ApiHandBindTests.swift` that is
  `:291`, `:299`, `:306`, `:324`, `:336`, `:477` and `:522`. In `ApiPathQueryTests.swift` it is
  `:300`, `:343`, `:354`, `:390` and `:408`. In `ApiRowsTests.swift` it is every test calling
  `apiRowRemoveRefusal`. Then run
  `grep -rn "apiDropRefusal\|apiPathQueryCrossRefusal\|apiBoxesDiscarding\|apiRowRemoveRefusal" app/`
  and make it come back empty.

**Interfaces:**
- Consumes: everything Task 2 produces. From Task 3: `focusChanged`, `noteFocus`, `releaseFocus`,
  `apiSurfaceCallDetaches`.
- Produces: nothing new in WakilKit. Task 7 uses the view's `send()`.

No WakilKit test is new here, because every ruling the view calls was pinned in Task 2. This task
deletes the tests whose subject it deletes.

- [ ] **Step 1: Delete the three refusals and their tests** (the files above). Run `make app-test`
  and expect the view to fail to compile, naming the deleted functions. That list is the view's
  to-do.
- [ ] **Step 2: Add the state, the pause and the flush.** Delete `crossRefusals`, `rowRefusals` and
  `editors["api.contentType"]`. The content type becomes the box `ApiFieldRow(.contentType)`.
  Add:

```swift
    /// The write the current pause will make, cancelled by the next keystroke (9a).
    @State private var pendingWrite: Task<Void, Never>?

    /// The request as the screen shows it, with every box applied. Every gesture is built on this.
    private var applied: ApiRequestSnapshot { apiRequestApplying(snapshot.request, boxes: boxes) }

    /// A keystroke: the write lands `apiTypingPause` after the LAST one.
    private func keystroke() {
        formatRefusal = nil
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor in
            try? await Task.sleep(for: apiTypingPause)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Writes, at once, whatever the boxes hold that the draft does not. Return, focus out, the
    /// end of a pause.
    private func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        let flush = apiFlush(snapshot.request, boxes: boxes, pane: pane.id)
        pathRefusal = flush.refusals[ApiFieldRow(.path)]
        if !flush.writes.isEmpty { operateInOrder(flush.writes) }
    }

    /// A gesture that reads or rewrites the draft: the flush, then `calls`, as one ordered
    /// sequence. The caller builds `calls` against `applied`, or carries its own field's box.
    private func operateFlushed(_ calls: [(String, JSONValue)]) {
        pendingWrite?.cancel()
        pendingWrite = nil
        let flush = apiFlush(snapshot.request, boxes: boxes, pane: pane.id)
        pathRefusal = flush.refusals[ApiFieldRow(.path)]
        operateInOrder(flush.writes + calls)
    }
```

  `operateInOrder` gains `guard !calls.isEmpty else { return }`, and both `operate` and
  `operateInOrder` stop touching the deleted refusal dictionaries.
- [ ] **Step 3: Keystrokes, Return, focus out and Escape.**
  - `literalBox`'s binding `set` becomes
    `{ boxes[box, default: [:]][index] = $0; keystroke() }`. Its `commit` becomes `{ _ in flush() }`
    for a single-line box and `{ _ in send() }` for the body (⌘Return sends). Its `discard`
    becomes `{ restore(box) }`.
  - The content-type field's text binding is
    `Binding(get: { boxes[ApiFieldRow(.contentType)]?[0] ?? contentType }, set: { boxes[ApiFieldRow(.contentType)] = [0: $0]; keystroke() })`.
    Its `commit` is `{ _ in flush() }`, and its `discard` is `{ restore(ApiFieldRow(.contentType)) }`.
    Delete `forgetContentType` and its `onChange`.
  - `focusChanged` (Task 3): in the `else if` branch, call `flush()` **before** `releaseFocus`.
    The flush is queued first and the release after it, which is Review Focus 1.
  - Replace `discard(_:index:)` (`:1346`) with:

```swift
    /// Escape (9a): the field goes back to what it held when the cursor arrived, as one write,
    /// and the cursor leaves it. **Compared against `applied`**, so a pause still running, or a
    /// write still in flight, is undone too. The restore is queued after that write.
    private func restore(_ box: ApiFieldRow) {
        pendingWrite?.cancel()
        pendingWrite = nil
        if let focused = focusedIn, focused.box == box,
           let write = apiRestoreWrite(focused, current: applied, pane: pane.id)
        {
            operateInOrder([("api_set_request", write)])
        }
        boxes[box] = nil
        if box.field == .path { pathRefusal = nil }
        if holeNaming == apiFieldKey(box.field, row: box.row) { closeHole() }
        focusedBox = nil
    }
```

  - `ApiBodyTextView.Coordinator`. In the `cancelOperation` branch, after `discard()`, add
    `textView.window?.makeFirstResponder(nil)`, because Escape leaves the field. The ⌘Return paths
    (`doCommandBy` and `BodyNSTextView.keyDown` / `performKeyEquivalent`) keep calling
    `parent.commit()`, which the pane now wires to `send()`. Rewrite the struct's doc comment:
    *"⌘Return sends (9a). It used to commit, and saving as typed made that redundant."*
- [ ] **Step 4: Let the boxes go when a write lands.** Delete `fieldFlow`'s
  `.onChange(of: field.parts)` block (`:1043-1068`) and its comment list, which described the
  refusals that are now gone. On the pane's root view, next to `.accessibilityIdentifier("api.pane")`
  (`:215`), add:

```swift
        // 9a: a box is let go once the draft holds what it shows (`apiBoxesAfterLanding`).
        .onChange(of: snapshot.request) { _, now in
            boxes = apiBoxesAfterLanding(now, boxes: boxes, focused: focusedIn?.box)
            if boxes[ApiFieldRow(.path)] == nil { pathRefusal = nil }
        }
```

- [ ] **Step 5: Every gesture flushes first.**
  - `write(_:_:)`. A gesture on a field carries that field's box against the drawn parts, and every
    other box is applied:

```swift
    private func write(_ box: ApiFieldRow, _ edit: ApiPartsEdit) {
        guard let params = apiPartsWrite(
            draft: apiRequestApplying(snapshot.request, boxes: boxes, except: box),
            field: box.field, edit: edit, pane: pane.id, row: box.row, typed: boxes[box] ?? [:])
        else { return }
        operateFlushed([("api_set_request", params)])
    }
```

  - `holeWrite` makes the same change, and its blank-name `nil` still answers `apiHoleNameRefusal`.
  - `pathWrite`. Delete the Ruling 8 guard and call
    `apiPathBoxWrite(apiRequestApplying(snapshot.request, boxes: boxes, except: ApiFieldRow(.path)), edit: edit, typed: boxes[ApiFieldRow(.path)] ?? [:], pane: pane.id)`.
    `.write` goes to `operateFlushed`. `.unchanged` sets `boxes[ApiFieldRow(.path)] = nil`.
  - `addRow`. Delete the Ruling 8 guard. Use `apiRowAdd(draft: applied, …)` and
    `apiRowAddedKey(applied, …)`, and send `.write` through `operateFlushed`.
  - `removeControl`. Delete both refusal branches and `removeRefusal(…)` together with its call
    sites. Use `apiRowRemoveWrite(draft: applied, …)` and keep `apiBoxesRemovingRow`. Dispatch
    through `operateFlushed`.
  - `formatControl`. Build with `apiFormatBodyWrite(draft: snapshot.request, pane: pane.id, typed: boxes[ApiFieldRow(.body)] ?? [:])`
    as today, but dispatch through `operateFlushed`. The no-op branch sets
    `boxes[ApiFieldRow(.body)] = nil` and nothing else.
  - `methodControl`, `chooser` and the bound chip's unbind `×`: `operate(…)` becomes
    `operateFlushed([(…)])`.
  - `drop`. Delete the `apiDropRefusal` guard and call `flush()` before `bindGeneration += 1`.
    `WindowModel.bindFromSurface` waits for the chain (Task 3), so the drop lands after the flush.
  - `sendControl`'s action becomes `send()`:

```swift
    /// Send, and ⌘Return in the body: every box flushed, then the send (`apiSendSequence`).
    private func send() {
        pendingWrite?.cancel()
        pendingWrite = nil
        operateInOrder(apiSendSequence(draft: snapshot.request, pane: pane.id, boxes: boxes))
    }
```

  - `fieldNotes`. Delete the Ruling 8 line (`:1092-1097`). `pathRefusal` is drawn where it is drawn
    today.
- [ ] **Step 6: Run.** `make app-test`, `make app-bundle` and `make controls`, all headless. Run
  `grep -n "dispatch(" app/Sources/WakilApp/ApiPane.swift`. The only hits should be inside
  `operate` and `operateInOrder`.
- [ ] **Step 7: Commit.**

```bash
git add app/Sources/WakilApp app/Sources/WakilKit/Api app/Tests/WakilKitTests
git commit -m "The pane writes on a pause and before every gesture; Escape restores the field, and the 'press Return first' refusals go"
```

### Task 5: What a send carries and says (B1, B2, B3, W13, W17)

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiResolveDraft.swift`. Rewrite the body branch of
  `resolveDraft` (`:44-91`). Make `apiResponse`'s tool-error refusal regionless (`:953-955`).
- Modify: `app/Sources/WakilKit/Api/ApiDraft.swift:335-351`. `ApiSendFailure.region` becomes
  `ApiRegion?`.
- Modify: `app/Sources/WakilKit/Api/ApiParts.swift:317-325`. `region` is omitted when nil.
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`. Change `apiSendStatement` and `apiBodyShape`
  (`:1165-1209`). `apiSendParams` (`:1895`) carries the content type. `apiBind` (`:1389`) refuses a
  binary column. Add `ApiActionError.binaryColumn`. Rewrite `api_set_request`'s description
  sentence *"AN EMPTY BODY SENDS NO BODY AND NO CONTENT TYPE … refused rather than dropped
  quietly."* (`:472-475`).
- Modify: `app/Sources/WakilKit/Api/ApiBodyFormat.swift`. Add `ApiBodyShape` and
  `apiBodyJSONShape`.
- Modify: `app/Sources/WakilKit/Api/ApiPaneLines.swift`. Add `apiFailureLine`, `apiBodyIsSent`
  and `apiContentTypeIsSent`. `apiUnfilledHolesLine` skips a read's body.
- Modify: `app/Sources/WakilApp/ApiPane.swift`. The failure line, wrapping, and the dims.
- Test: `app/Tests/WakilKitTests/ApiResolveDraftTests.swift`, `ApiSendTests.swift`,
  `ApiBindTests.swift`, `ApiPaneLinesTests.swift` and `ApiRequestTests.swift`.

**Interfaces:**
- Produces:
  ```swift
  public struct ApiSendFailure { public let region: ApiRegion?; … }    // init(region: ApiRegion?, message:available:)
  public func apiFailureLine(_ failure: ApiSendFailure) -> String
  public func apiBodyIsSent(_ request: ApiRequestSnapshot) -> Bool
  public func apiContentTypeIsSent(_ request: ApiRequestSnapshot) -> Bool
  public enum ApiBodyShape: Equatable, Sendable { case object([String]), array(Int), value }
  public func apiBodyJSONShape(_ parts: [ApiPart]) -> ApiBodyShape?
  case ApiActionError.binaryColumn(action: String, column: String, declaredType: String)
  ```

- [ ] **Step 1: Write the failing tests.**

  In `ApiResolveDraftTests.swift`, delete `aContentTypeBesideAnEmptyBodyIsRefusedRatherThanDropped`
  (`:448`) and add:

```swift
@Test func aContentTypeBesideAnEmptyBodyIsOmittedNotRefused() throws {
    // B2: the send omits it, as `apiWireArguments` already does; the row dims, and no line is drawn.
    let wire = try resolveDraft(
        draft(method: "DELETE", contentType: "application/json", body: []), sources: [:],
        credentialed: false).get()
    #expect(wire.body == nil)
    #expect(wire.contentType == nil)
}

@Test func aReadSendsNoBodyAndNoContentTypeWhateverTheDraftHolds() throws {
    // B1: the body stays in the draft and is never handed to `request`, whose schema refuses it.
    let wire = try resolveDraft(
        draft(method: "GET", contentType: "application/json", body: [.slot("unfilled")]),
        sources: [:], credentialed: false).get()
    #expect(wire.body == nil)
    #expect(wire.contentType == nil)
    #expect(apiWireArguments(wire) == .object([
        "api": .string("billing"), "method": .string("GET"), "path": .string(""),
    ]))
}
```

  In `ApiRequestTests.swift`:

```swift
@Test("B3: a tool's own refusal names no region")
func aToolRefusalNamesNoRegion() {
    let reply: JSONValue = .object([
        "isError": .bool(true),
        "content": .array([.object(["type": .string("text"), "text": .string("validating…")])]),
    ])
    guard case .refusal(let refusal) = apiResponse(
        from: reply, environment: "staging", started: Date(), url: "")
    else { Issue.record("not a refusal"); return }
    #expect(refusal.failures[0].region == nil)
    #expect(apiFailureLine(refusal.failures[0]) == "validating…")
    #expect(apiFailureLine(ApiSendFailure(region: .body, message: "m")) == "Body · m")
    #expect(apiResponseJSON(.refusal(refusal)) == .object([
        "state": .string("refusal"),
        "failures": .array([.object(["message": .string("validating…")])]),
    ]))
}
```

  In `ApiSendTests.swift`:

```swift
@Test("W13: the plane names the URL that will leave and the body by its shape")
func theStatementNamesTheWholeRequest() {
    var draft = ApiDraft.empty
    draft.entry = "httpbin"
    draft.method = "POST"
    draft.path = [.literal("/test")]
    draft.query = [ApiQueryRow(name: "page", value: [.literal("2")])]
    draft.body = [.literal(#"{"test": 1, "customer_id": "#), .slot("id"), .literal("}")]
    #expect(apiSendStatement(draft: draft, origin: "https://httpbin.org")
        == "Send POST https://httpbin.org/test?page=2 with a JSON body {test, customer_id}")
}

@Test("W13: an array, text, nothing, a hole in the path, a named content type", arguments: [
    ([ApiPart.literal("[1, 2, 3]")], "", "/x", "Send PUT https://h.example/x with a JSON array of 3"),
    ([.literal("[]")], "", "/x", "Send PUT https://h.example/x with a JSON array of 0"),
    ([.literal("not json at all")], "", "/x", "Send PUT https://h.example/x with 15 bytes of text"),
    ([], "", "/x", "Send PUT https://h.example/x with no body"),
    ([.literal(#"{"a":1}"#)], "application/merge-patch+json", "/x",
     "Send PUT https://h.example/x with a JSON body {a} as application/merge-patch+json"),
])
func theStatementShapes(body: [ApiPart], contentType: String, path: String, expected: String) {
    var draft = ApiDraft.empty
    draft.method = "PUT"
    draft.path = [.literal(path)]
    draft.contentType = contentType
    draft.body = body
    #expect(apiSendStatement(draft: draft, origin: "https://h.example") == expected)
}

@Test("A hole in the path is drawn by its name")
func aHoleInThePathIsDrawnByName() {
    var draft = ApiDraft.empty
    draft.method = "DELETE"
    draft.path = [.literal("/c/"), .slot("id")]
    #expect(apiSendStatement(draft: draft, origin: "https://h.example")
        == "Send DELETE https://h.example/c/<id> with no body")
}
```

  In `ApiBindTests.swift` (W17):

```swift
@Test("W17: a binary column is refused at the drop, naming it")
func aBinaryColumnIsRefusedAtTheDrop() {
    let source = ApiDropSource(
        pane: "db-1", table: "t", keyColumns: ["id"], columns: ["id", "k"],
        columnTypes: ["INTEGER", "VARBINARY"], row: [.integer(1), .string("\u{FFFD}")],
        generation: 1, editable: true)
    var draft = ApiDraft.empty
    draft.path = [.literal("/x/"), .slot("k")]
    let thrown = #expect(throws: ApiActionError.self) {
        _ = try apiBind(draft: draft, source: source, holes: ["k"], sources: [:])
    }
    #expect(String(describing: thrown!).contains(
        "k is a VARBINARY column — binary values arrive corrupted, so they can't be bound"))
}

@Test("A binary column no hole names does not stop the drop")
func aBinaryColumnNoHoleNamesIsIgnored() throws {
    let source = ApiDropSource(
        pane: "db-1", table: "t", keyColumns: ["id"], columns: ["id", "k"],
        columnTypes: ["INTEGER", "VARBINARY"], row: [.integer(1), .string("x")],
        generation: 1, editable: true)
    var draft = ApiDraft.empty
    draft.path = [.literal("/x/"), .slot("id")]
    let (bound, missed) = try apiBind(draft: draft, source: source, holes: ["id"], sources: [:])
    #expect(missed.isEmpty)
    guard case .bound = bound.path[1] else { Issue.record("not bound"); return }
}
```

  In `ApiPaneLinesTests.swift`:

```swift
@Test("B1/B2: a read's body is not sent, and a content type beside nothing is not sent")
func whatTheSendCarries() {
    let get = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [], headers: ApiRequestSnapshot.empty.headers,
        body: [.slot("id")])
    #expect(!apiBodyIsSent(get))
    #expect(!apiContentTypeIsSent(get))
    #expect(apiUnfilledHolesLine(get) == nil)  // B1: no line for a body that is not sent
    let post = ApiRequestSnapshot(
        method: "POST", origin: nil, path: [], query: [], headers: ApiRequestSnapshot.empty.headers,
        body: [])
    #expect(apiBodyIsSent(post))
    #expect(!apiContentTypeIsSent(post))
}
```

- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement.**
  - `ApiDraft.swift`. `public let region: ApiRegion?` and `init(region: ApiRegion?, …)`. Update
    its doc comment: *"`nil` when the refusal is not a region's: a tool's or a transport's (B3)."*
  - `ApiResolveDraft.swift`. Replace the body block (`:44-91`) with:

```swift
    // **B1: a read sends no body.** The draft keeps it (a press back to POST restores it to the
    // wire), and `request` is never handed `body` or `contentType`, so `wakil-http`'s schema
    // refusal cannot reach the operator. **B2: an empty body sends no body and no
    // `Content-Type`.** A content type named beside it is omitted, not refused, and the row dims.
    var body: String?
    var contentType: String?
    let namedContentType = draft.contentType.trimmingCharacters(in: .whitespacesAndNewlines)
    if !apiIsReadMethod(draft.method), !draft.body.isEmpty {
        let resolved = resolveRegion(draft.body, .body, sources: sources, into: &failures)
        // (keep the existing comment on validating only a fully-resolved document)
        if resolved.allSatisfy(\.isResolved) {
            let emitted = emitBody(resolved)
            if let failure = bodyFailure(emitted) {
                failures.append(failure)
            } else {
                body = emitted
                contentType = namedContentType.isEmpty ? nil : namedContentType
            }
        }
    }
```

    In `apiResponse` (`:953`): `ApiSendFailure(region: nil, message: text)`.
  - `ApiParts.swift:317`:
    `var entry: [String: JSONValue] = ["message": .string(failure.message)]; if let region = failure.region { entry["region"] = .string(region.label) }`.
  - `ApiPaneLines.swift`:

```swift
/// A refusal or error line as drawn: the region first **only when the refusal is that
/// region's** (B3). The walk saw *"Path · validating…"* on a tool's own error.
public func apiFailureLine(_ failure: ApiSendFailure) -> String {
    failure.region.map { "\($0.label) · \(failure.message)" } ?? failure.message
}

/// B1: whether the body goes on the wire. A read sends none, and its box dims.
public func apiBodyIsSent(_ request: ApiRequestSnapshot) -> Bool { !apiIsReadMethod(request.method) }

/// B2: whether the content type goes on the wire. Only beside a body that is sent.
public func apiContentTypeIsSent(_ request: ApiRequestSnapshot) -> Bool {
    apiBodyIsSent(request) && !request.body.isEmpty
}
```

    `apiUnfilledHolesLine` counts
    `apiSlotNames(in: apiBodyIsSent(request) ? request : ApiRequestSnapshot(method: request.method, origin: request.origin, path: request.path, query: request.query, headers: request.headers, body: []))`.
  - `ApiBodyFormat.swift`, after `apiFormatIsEnabled`:

```swift
/// A body's shape, in the plane's words (W13): an object's top-level keys in the order typed, an
/// array's length, or any other JSON value. A hole is a value.
public enum ApiBodyShape: Equatable, Sendable {
    case object([String])
    case array(Int)
    case value
}

/// The body's JSON shape, or `nil` when it does not tokenize as JSON (`apiFormatBody`'s own test).
public func apiBodyJSONShape(_ parts: [ApiPart]) -> ApiBodyShape? {
    guard apiFormatBody(parts) != nil,
          let tokens = apiBodyTokens(apiMergedLiterals(parts)), let first = tokens.first
    else { return nil }
    guard case .punct(let open) = first, open == "{" || open == "[" else { return .value }
    var depth = 0
    var keys: [String] = []
    var commas = 0
    for (index, token) in tokens.enumerated() {
        switch token {
        case .punct(let p) where p == "{" || p == "[": depth += 1
        case .punct(let p) where p == "}" || p == "]": depth -= 1
        case .punct(",") where depth == 1: commas += 1
        case .string(let quoted) where depth == 1 && open == "{":
            if index + 1 < tokens.count, case .punct(":") = tokens[index + 1] {
                keys.append(String(quoted.dropFirst().dropLast()))
            }
        default: break
        }
    }
    return open == "{" ? .object(keys) : .array(tokens.count == 2 ? 0 : commas + 1)
}
```

  - `ApiActions.swift`. Replace `apiSendStatement` and `apiBodyShape`:

```swift
/// The sentence the confirmation plane shows (W13). **It names the whole request**: the URL that
/// will leave, path and query, with each hole drawn by its name. The body is named by its shape:
/// a JSON object's top-level keys, a JSON array's length, or a count of bytes of text. **No part
/// counts.**
///
/// (Keep the two existing paragraphs: *never its bytes*, and *the request, not the operation*.)
public func apiSendStatement(draft: ApiDraft, origin: String?) -> String {
    let base = origin.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        ?? "the \(draft.entry) entry"
    var url = base + apiStatementText(draft.path)
    if !draft.query.isEmpty {
        url += "?" + draft.query.map { "\($0.name)=\(apiStatementText($0.value))" }
            .joined(separator: "&")
    }
    return "Send \(draft.method.uppercased()) \(url) \(apiStatementBody(draft))"
}

/// Parts as the plane reads them: literals as typed, a hole or bound value as `<name>`.
func apiStatementText(_ parts: [ApiPart]) -> String {
    parts.map { part -> String in
        switch part {
        case .literal(let text): return text
        case .slot(let name): return "<\(name)>"
        case .bound(let bound): return "<\(bound.name)>"
        }
    }.joined()
}

/// The body clause. A named content type other than `application/json` is said after it.
func apiStatementBody(_ draft: ApiDraft) -> String {
    guard !draft.body.isEmpty else { return "with no body" }
    let named = draft.contentType.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = named.isEmpty || named.lowercased() == "application/json" ? "" : " as \(named)"
    switch apiBodyJSONShape(draft.body) {
    case .object(let keys)?: return "with a JSON body {\(keys.joined(separator: ", "))}" + suffix
    case .array(let count)?: return "with a JSON array of \(count)" + suffix
    case .value?: return "with a JSON value" + suffix
    case nil:
        let bytes = draft.body.reduce(0) { total, part in
            if case .literal(let text) = part { return total + text.utf8.count }
            return total
        }
        return "with \(bytes) bytes of text" + suffix
    }
}
```

    Delete `apiBodyShape` once `grep -rn apiBodyShape app/` shows no caller. In `apiSendParams`,
    add `asDraft.contentType = apiContentTypeText(draft)`. In `apiBind`, inside the `for hole`
    loop, right after `let declaredType = source.declaredType(hole)`, add:

```swift
        // W17: refused at the drop, not at Send. A binary cell is corrupted before the pane can
        // read it, so binding one only defers the refusal, and the walk saw its origin garbled.
        guard !isBinaryType(declaredType) else {
            throw ApiActionError.binaryColumn(
                action: "api_bind", column: hole, declaredType: declaredType)
        }
```

    `ApiActionError` gains `case binaryColumn(action: String, column: String, declaredType: String)`,
    described as
    `"\(action): \(column) is a \(declaredType.uppercased()) column — binary values arrive corrupted, so they can't be bound"`.
    `api_set_request`'s description sentence becomes *"AN EMPTY BODY SENDS NO BODY AND NO CONTENT
    TYPE, and a content type left beside an emptied body is omitted from the wire. A GET or HEAD
    sends no body at all; the draft keeps it for a later mutation."*
  - `ApiPane.swift`:
    - The refusal `ForEach` (`:1692-1695`) draws `Text(apiFailureLine(failure.element))`.
    - Add a private modifier
      `private extension View { func wraps() -> some View { lineLimit(nil).fixedSize(horizontal: false, vertical: true) } }`.
      Apply `.wraps()` to that refusal line, to the transport and fate-unknown reasons
      (`:1680`, `:1684`), to `pathRefusal`, to `holeRefusal`, to the bind line, to `formatRefusal`
      and to `unfilledLine`.
    - The body's field box takes `.opacity(apiBodyIsSent(snapshot.request) ? 1 : 0.4)`, and the
      content-type value cell takes `.opacity(apiContentTypeIsSent(snapshot.request) ? 1 : 0.4)`.
      Neither draws a line.
- [ ] **Step 4: Run.** `make app-test`, `make app-bundle` and `make controls`. Run
  `grep -rn "\.region\.label\|region: \.path, message: text" app/` and expect nothing.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources app/Tests/WakilKitTests
git commit -m "A read sends no body, an empty body's content type is dropped, a tool's refusal names no region, the plane names the whole request, and a binary column is refused at the drop"
```

Then: `superpowers:requesting-code-review` for Phase 2 (Tasks 4–5).

---

### Task 6: A send in flight, and `api_cancel` (W14, WakilKit)

**Files:**
- Modify: `app/Sources/WakilKit/MCP/MCPClient.swift:494-526`. `sendRequest` honours task
  cancellation and sends `notifications/cancelled`.
- Modify: `app/Sources/WakilKit/Api/ApiResolveDraft.swift`. `ApiRequestOutcome` gains `cancelled`
  (`:738-748`). `apiRequest` catches `CancellationError` (`:790-835`). Add
  `apiCancelledResponse`.
- Modify: `app/Sources/WakilKit/Panes/ApiSnapshot.swift`. Add `ApiSending`, `ApiSnapshot.sending`,
  `ApiResponseSnapshot.cancelled(ApiCancelled)`, `ApiCancelled` and `ApiRecentRow.cancelled`.
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift`. `ApiContents.flight`, `beginApiSend`,
  `armApiSend`, `cancelApiSend` and `finishApiSend`. `recordApiSend` takes `cancelled`.
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`. The `api_request` and `api_send` handlers
  run through `apiSendInFlight`. Register `api_cancel`. Add `ApiActionError.sendInFlight` and
  `.nothingInFlight`. `apiSendControl` takes `sending`.
- Modify: `app/Sources/WakilKit/Api/ApiParts.swift`. `apiResponseJSON` gets the `.cancelled` arm.
  `apiRecentRowJSON` gets `cancelled`. `apiRecentRowLabel` says *cancelled*.
- Modify: `app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift:111`. Add `object["sending"]`.
- Modify: `app/Sources/WakilKit/Api/ApiPaneLines.swift`. `apiStatusTone` gets `.cancelled → nil`.
  Add `apiSeconds` and `apiCancelledLine`.
- Test: create `app/Tests/WakilKitTests/ApiCancelTests.swift`. Modify `MCPClientTests.swift`,
  `ApiTestSupport.swift` (`StallingHTTP`, `apiEventually`), `AppWiringTests.swift:210` (the action
  list) and `ApiPaneTests.swift:128` (the key list).

**Interfaces:**
- Consumes: Task 1's proof. Task 3's `apiSurfaceCallDetaches` detaches both sends, and `api_cancel`
  is awaited normally.
- Produces:
  ```swift
  public struct ApiSending: Sendable, Equatable { public let since: Date; public let method: String }
  public struct ApiCancelled: Sendable, Equatable { public let waitedMs: Int; public let environment: String }
  // ApiSnapshot.sending: ApiSending?   ApiResponseSnapshot.cancelled(ApiCancelled), state "cancelled"
  // ApiRecentRow.cancelled: Bool       ApiRequestOutcome.cancelled: Bool
  public func apiCancelledResponse(method: String, waitedMs: Int, environment: String) -> ApiResponseSnapshot
  public func apiSeconds(_ milliseconds: Int) -> String            // "4.2 s"
  public func apiCancelledLine(waitedMs: Int) -> String            // "cancelled after 4.2 s"
  public func apiSendControl(method: String, sending: ApiSending? = nil, now: Date = Date()) -> (action: String, label: String)
  // PaneStore
  public func beginApiSend(paneId: String, method: String, at since: Date) -> Bool
  public func armApiSend(paneId: String, cancel: @escaping @Sendable () -> Void)
  public func cancelApiSend(paneId: String) -> Bool
  public func finishApiSend(paneId: String, outcome: ApiRequestOutcome)
  ```

- [ ] **Step 1: Write the failing tests.**

  Add to `ApiTestSupport.swift`:

```swift
/// A `wakil-http` for W14. `list_apis` answers one entry. `request` and `send` wait: until the
/// calling task is cancelled (`honoursCancel`, which is what `MCPClient` does), or until
/// `release()`, answering 200 (the reply that beats a cancel).
actor StallingHTTP: ToolCaller {
    private let honoursCancel: Bool
    private var parked: [CheckedContinuation<Void, Never>] = []
    init(honoursCancel: Bool = true) { self.honoursCancel = honoursCancel }

    func parkedCount() -> Int { parked.count }
    func release() { parked.forEach { $0.resume() }; parked = [] }
    private func park(_ c: CheckedContinuation<Void, Never>) { parked.append(c) }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        if name == "list_apis" {
            return .object(["structuredContent": .object(["apis": .array([.object([
                "name": .string("slow"), "baseUrl": .string("https://slow.example"),
                "authenticated": .bool(false),
            ])])])])
        }
        if honoursCancel {
            try await Task.sleep(nanoseconds: 30_000_000_000)   // throws CancellationError on cancel
            return .null
        }
        await withCheckedContinuation { c in Task { await self.park(c) } }
        return .object(["structuredContent": .object([
            "status": .integer(200), "headers": .object([:]), "body": .string(""),
            "truncated": .bool(false),
        ])])
    }
}

/// Polls `condition` for up to `seconds` × `testWaitLoadMultiplier`.
func apiEventually(_ seconds: Double = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}
```

  `ApiCancelTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// W14: a send in flight, refused a second time, and cancelled from either channel.

private func cancelFixture(
    _ http: StallingHTTP
) async throws -> (registry: ActionRegistry, panes: PaneStore, pane: String) {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(), http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
        throw CancelFixtureFailed()
    }
    return (registry, panes, pane)
}
private struct CancelFixtureFailed: Error {}

private func dispatch(
    _ registry: ActionRegistry, _ name: String, _ params: [String: JSONValue]
) async throws -> JSONValue {
    try await registry.dispatch(
        name: name, params: .object(params), origin: .agent, environment: "staging",
        confirmation: nil)
}

@Test("A cancelled read reads 'cancelled after', and Recent records it as cancelled")
func aCancelledReadIsCancelled() async throws {
    let (registry, panes, pane) = try await cancelFixture(StallingHTTP())
    let send = Task { try await dispatch(registry, "api_request", ["pane": .string(pane)]) }
    #expect(await apiEventually { await panes.apiSnapshot(paneId: pane).sending != nil })
    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    _ = try await send.value
    let snapshot = await panes.apiSnapshot(paneId: pane)
    #expect(snapshot.response.state == "cancelled")
    #expect(snapshot.sending == nil)
    #expect(snapshot.recent.first?.cancelled == true)
}

@Test("A cancelled mutation is fate-unknown: the server may already have it")
func aCancelledMutationIsFateUnknown() async throws {
    let (registry, panes, pane) = try await cancelFixture(StallingHTTP())
    _ = try await dispatch(registry, "api_set_request", [
        "pane": .string(pane), "method": .string("POST"),
        "body": .array([.object(["literal": .string("{}")])]),
    ])
    let send = Task {
        try await dispatch(registry, "api_send", ["pane": .string(pane), "statement": .string("s")])
    }
    #expect(await apiEventually { await panes.apiSnapshot(paneId: pane).sending != nil })
    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    _ = try await send.value
    guard case .unknown(let record) = await panes.apiSnapshot(paneId: pane).response else {
        Issue.record("not fate-unknown"); return
    }
    #expect(record.reason.hasPrefix("cancelled after "))
    #expect(record.reason.hasSuffix(" — the server may already have it"))
}

@Test("A second send on a pane in flight is refused, from either channel")
func aSecondSendIsRefused() async throws {
    let (registry, panes, pane) = try await cancelFixture(StallingHTTP())
    let send = Task { try await dispatch(registry, "api_request", ["pane": .string(pane)]) }
    #expect(await apiEventually { await panes.apiSnapshot(paneId: pane).sending != nil })
    let thrown = await #expect(throws: ApiActionError.self) {
        _ = try await dispatch(registry, "api_request", ["pane": .string(pane)])
    }
    #expect(String(describing: thrown!).contains("a send is already in flight on this pane"))
    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    _ = try await send.value
}

@Test("api_cancel with nothing in flight is refused")
func cancelWithNothingInFlightIsRefused() async throws {
    let (registry, _, pane) = try await cancelFixture(StallingHTTP())
    let thrown = await #expect(throws: ApiActionError.self) {
        _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    }
    #expect(String(describing: thrown!).contains("nothing is in flight"))
}

@Test("Review Focus 3: a reply that beats the cancel is kept, not overwritten as cancelled")
func aReplyThatBeatsTheCancelIsKept() async throws {
    let http = StallingHTTP(honoursCancel: false)
    let (registry, panes, pane) = try await cancelFixture(http)
    let send = Task { try await dispatch(registry, "api_request", ["pane": .string(pane)]) }
    #expect(await apiEventually { await http.parkedCount() == 1 })
    _ = try await dispatch(registry, "api_cancel", ["pane": .string(pane)])
    await http.release()
    _ = try await send.value
    let snapshot = await panes.apiSnapshot(paneId: pane)
    #expect(snapshot.response.status == 200)
    #expect(snapshot.recent.first?.cancelled == false)
}

@Test("Review Focus 4: a send that outlives its environment lands in Recent only")
func aSendThatOutlivesItsEnvironmentLandsInRecentOnly() async {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api-1", entry: "slow", environment: "staging", origin: "https://s", credentialed: false)
    #expect(await panes.beginApiSend(paneId: "api-1", method: "GET", at: Date()))
    await panes.clearApiResponses(to: "production")
    let reply = ApiResponseSnapshot.ok(ApiResponseOK(
        status: 200, url: "https://s/x", environment: "staging", headers: [:], body: "",
        durationMs: 5, byteCount: 0, truncated: false))
    await panes.finishApiSend(
        paneId: "api-1", outcome: ApiRequestOutcome(draft: .empty, response: reply))
    let snapshot = await panes.apiSnapshot(paneId: "api-1")
    #expect(snapshot.response == .cleared(environment: "production"))
    #expect(snapshot.recent.first?.environment == "staging")
    #expect(snapshot.sending == nil)
}

@Test("read_pane says whether a send is in flight")
func readPanePublishesSending() async {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "e", environment: "s", origin: nil, credentialed: false)
    guard case .object(let idle) = paneSnapshotJSON(await panes.snapshot(paneId: "api-1", kind: "api"))
    else { Issue.record("not an object"); return }
    #expect(idle["sending"] == .bool(false))
    _ = await panes.beginApiSend(paneId: "api-1", method: "GET", at: Date())
    guard case .object(let busy) = paneSnapshotJSON(await panes.snapshot(paneId: "api-1", kind: "api"))
    else { Issue.record("not an object"); return }
    #expect(busy["sending"] == .bool(true))
}

@Test("Send becomes Cancel, counting, while a send is in flight")
func sendBecomesCancel() {
    let since = Date(timeIntervalSince1970: 0)
    let control = apiSendControl(
        method: "GET", sending: ApiSending(since: since, method: "GET"),
        now: since.addingTimeInterval(1.23))
    #expect(control.action == "api_cancel")
    #expect(control.label == "Cancel · 1.2 s")
    #expect(apiCancelledLine(waitedMs: 4200) == "cancelled after 4.2 s")
}
```

  In `MCPClientTests.swift`, after `makeEchoServer`:

```swift
/// A fake MCP server that answers `initialize` and nothing else, and writes every frame it reads
/// to the log named in its first argument. A `tools/call` to it waits forever, unless it is
/// cancelled.
private func makeSilentServer(_ dir: URL) throws -> URL {
    let script = dir.appendingPathComponent("silent-server.sh")
    let body = """
    #!/bin/sh
    LOG="$1"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$LOG"
      case "$line" in *'"initialize"'*)
        rest=${line#*\\"id\\":}
        id=${rest%%,*}
        id=${id%%\\}*}
        printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id" ;;
      esac
    done
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

/// W14: cancelling the task that awaits a call stops the wait at once, and tells the server with
/// `notifications/cancelled` for that request's id. Until this, the client could only stop
/// waiting, and the HTTP request ran on to its timeout.
@Test(.timeLimit(.minutes(1)))
func cancellingACallStopsWaitingAndTellsTheServer() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("frames.log")
    let c = MCPClient(
        executable: try makeSilentServer(dir), arguments: [log.path],
        environment: ["PATH": "/usr/bin:/bin"])
    try await c.start()
    let call = Task {
        try await c.callTool(name: "request", arguments: .object([:]), timeout: 30)
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    let cancelled = Date()
    call.cancel()
    await #expect(throws: CancellationError.self) { _ = try await call.value }
    #expect(Date().timeIntervalSince(cancelled) < 2)

    var line: Substring?
    for _ in 0..<50 where line == nil {
        let frames = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        // JSONEncoder escapes "/", so the method arrives as notifications\/cancelled.
        line = frames.split(separator: "\n").first { $0.contains("cancelled") && $0.contains("requestId") }
        if line == nil { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    await c.stop()
    // initialize is id 1, so the call is id 2.
    #expect(try #require(line).contains("\"requestId\":2"))
}
```

  Update `AppWiringTests.swift:210`'s list to include `"api_cancel"`. Update `ApiPaneTests`'s
  `anEmptyApiPaneReadsBackWithEveryKeyOfItsArm` key list to include `"sending"`.
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement.**
  - `MCPClient.swift`. Split the waiting half of `sendRequest` into an actor-isolated helper,
    and wrap it:

```swift
        try Task.checkCancellation()
        let id = nextRequestID
        nextRequestID += 1
        let frame = try encodeFrame(JSONRPCMessage(id: .number(id), method: method, params: params))

        // W14: a caller that stops waiting cancels the call, not just its own wait. The server
        // is told with `notifications/cancelled`, and `wakil-http` aborts the request through
        // the call's context (proved in `cmd/wakil-http/cancel_test.go`).
        let response = try await withTaskCancellationHandler {
            try await awaitReply(id: id, method: method, frame: frame, stdinHandle: stdinHandle, timeout: timeout)
        } onCancel: {
            Task { await self.cancelPending(id: id) }
        }
```

    `awaitReply` is the existing `withCheckedThrowingContinuation { … }` block, unchanged, plus one
    line after `pendingTimeouts[id] = Task { … }`:
    `if Task.isCancelled { cancelPending(id: id) }`. That covers a cancel that arrived before the
    continuation was registered. Add:

```swift
    /// A caller cancelled call `id` (W14). It is resumed with `CancellationError`, and the server
    /// is told. A reply that already arrived has removed the entry, so this does nothing then.
    private func cancelPending(id: Int) {
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CancellationError())
        try? sendNotification(method: "notifications/cancelled", params: .object([
            "requestId": .integer(Int64(id)), "reason": .string("cancelled by the operator"),
        ]))
    }
```

  - `ApiSnapshot.swift`. `ApiResponseSnapshot` gains `case cancelled(ApiCancelled)`. `state` is
    `"cancelled"`, `environment` is the cancelled send's, and `status`, `durationMs` and
    `byteCount` stay nil. Then `grep -rn "case .cleared" app/Sources` and add the arm next to every
    exhaustive switch. `ApiSnapshot` gains `public let sending: ApiSending?`, with an init
    parameter `sending: ApiSending? = nil`. `ApiRecentRow` gains `public let cancelled: Bool`,
    with an init parameter `cancelled: Bool = false`. `ApiRequestOutcome` gains
    `public let cancelled: Bool` with an init default of `false`.
  - `ApiResolveDraft.swift`. In `apiRequest`, before the general `catch`:

```swift
        } catch is CancellationError {
            // W14: the operator or the agent cancelled. A read is cancelled, plainly. A mutation
            // may have landed, so it is the fate-unknown state (`apiCancelledResponse`).
            return ApiRequestOutcome(
                draft: draft,
                response: apiCancelledResponse(
                    method: wire.method,
                    waitedMs: Int(Date().timeIntervalSince(started) * 1000),
                    environment: environment),
                cancelled: true)
```

```swift
public func apiCancelledResponse(method: String, waitedMs: Int, environment: String) -> ApiResponseSnapshot {
    guard apiIsReadMethod(method) else {
        return .unknown(ApiFateUnknown(
            reason: apiCancelledLine(waitedMs: waitedMs) + " — the server may already have it",
            environment: environment))
    }
    return .cancelled(ApiCancelled(waitedMs: waitedMs, environment: environment))
}
```

  - `ApiPaneLines.swift`:

```swift
public func apiSeconds(_ milliseconds: Int) -> String {
    String(format: "%.1f s", Double(milliseconds) / 1000)
}
public func apiCancelledLine(waitedMs: Int) -> String { "cancelled after \(apiSeconds(waitedMs))" }
```

    `apiStatusTone`: `.cancelled` goes in the no-tone list, because grey is the pane's ink.
  - `PaneStore.swift`. `ApiContents` gains:

```swift
        /// The send in flight, if any (W14). One per pane: a second is refused.
        var flight: ApiFlight?
```

    with a private struct
    `ApiFlight { let since: Date; let method: String; let environment: String; var cancel: (@Sendable () -> Void)?; var cancelRequested = false }`.
    `snapshot()` passes `sending: flight.map { ApiSending(since: $0.since, method: $0.method) }`.
    The methods:

```swift
    /// Starts a send on `paneId`, or answers `false` when one is already in flight.
    public func beginApiSend(paneId: String, method: String, at since: Date) -> Bool {
        var contents = api(paneId)
        guard contents.flight == nil else { return false }
        contents.flight = ApiFlight(since: since, method: method, environment: contents.environment)
        setApi(paneId, contents)
        return true
    }

    /// Hands the flight its canceller. A cancel that arrived first is honoured now.
    public func armApiSend(paneId: String, cancel: @escaping @Sendable () -> Void) {
        var contents = api(paneId)
        guard var flight = contents.flight else { return }
        flight.cancel = cancel
        contents.flight = flight
        setApi(paneId, contents)
        if flight.cancelRequested { cancel() }
    }

    /// Cancels the send in flight. `false` when there is none, which `api_cancel` refuses.
    public func cancelApiSend(paneId: String) -> Bool {
        var contents = api(paneId)
        guard var flight = contents.flight else { return false }
        flight.cancelRequested = true
        contents.flight = flight
        setApi(paneId, contents)
        flight.cancel?()
        return true
    }

    /// Ends the flight. The response replaces the pane's **only while the environment is the one
    /// the send left in**. A reply from staging must not sit under a pane cleared for production
    /// (Review Focus 4). The send is recorded either way, under its own environment.
    public func finishApiSend(paneId: String, outcome: ApiRequestOutcome) {
        var contents = api(paneId)
        let flight = contents.flight
        contents.flight = nil
        setApi(paneId, contents)
        if flight?.environment == contents.environment {
            setApiResponse(paneId: paneId, response: outcome.response)
        }
        recordApiSend(
            paneId: paneId, draft: outcome.draft, response: outcome.response,
            cancelled: outcome.cancelled)
    }
```

    `recordApiSend` gains `cancelled: Bool = false`, a `.cancelled(let c)` case (`status = nil`,
    `millis = c.waitedMs`, `environment = c.environment`), and passes `cancelled` to the row.
  - `ApiParts.swift`. `apiResponseJSON`'s `.cancelled(let c)` arm sets `waitedMs` and
    `environment`. `apiRecentRowJSON` adds `"cancelled": .bool(row.cancelled)`.
    `apiRecentRowLabel` appends `row.cancelled ? "cancelled" : (row.status.map { "\($0)" } ?? "no reply")`.
  - `PaneSnapshotJSON.swift:111`: `object["sending"] = .bool(api.sending != nil)`.
  - `ApiActions.swift`. Add the shared runner:

```swift
/// Runs one send as a cancellable task, the pane marked in flight for its whole length (W14).
/// **A second send is refused**, not queued, so two replies can never race for one response.
/// Cancelling cancels the task, `MCPClient` tells `wakil-http`, and `apiRequest` answers the
/// cancelled outcome. A reply that beat the cancel is kept (Review Focus 3).
func apiSendInFlight(
    paneId: String, action: String, method: String, panes: PaneStore,
    send: @escaping @Sendable () async -> ApiRequestOutcome
) async throws -> ApiRequestOutcome {
    guard await panes.beginApiSend(paneId: paneId, method: method, at: Date()) else {
        throw ApiActionError.sendInFlight(action: action)
    }
    let task = Task { await send() }
    await panes.armApiSend(paneId: paneId) { task.cancel() }
    let outcome = await task.value
    await panes.finishApiSend(paneId: paneId, outcome: outcome)
    return outcome
}
```

    In `api_request` (`:858-871`) and `api_send` (`:926-939`), replace the
    `apiRequest` / `setApiResponse` / `recordApiSend` triple with:

```swift
            let draft = await panes.apiDraft(paneId: paneId)
            let outcome = try await apiSendInFlight(
                paneId: paneId, action: action, method: snapshot.request.method, panes: panes
            ) {
                await apiRequest(
                    draft: draft, sources: await panes.apiSources(),
                    environment: snapshot.environment, http: http,
                    credentialed: snapshot.credentialed, origin: snapshot.request.origin)
            }
```

    Register `api_cancel` after `api_send`:

```swift
    await registry.register(Action(
        name: "api_cancel",
        description: "Cancel the send in flight on an api pane, as the operator's Cancel does. "
            + "The HTTP request is aborted. A READ reads 'cancelled after N s'. A MUTATION is "
            + "recorded as fate unknown — 'the server may already have it' — because a "
            + "cancelled write may still have landed, so do not resend it blindly. With "
            + "nothing in flight it is refused. While a send is in flight, read_pane's "
            + "sending is true, and a second api_request or api_send on that pane is refused.",
        // `.control`: it changes Wakil's own state, ending a send it started. It writes nothing
        // the draft holds and is never priced by the gate.
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let action = "api_cancel"
            guard case .object(let fields) = params,
                case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)
            guard await panes.cancelApiSend(paneId: paneId) else {
                throw ApiActionError.nothingInFlight(action: action)
            }
            return .object(["pane": .string(paneId)])
        }
    ))
```

    `ApiActionError` gains `sendInFlight(action:)`, described as
    `"\(action): a send is already in flight on this pane — wait for its reply, or cancel it with api_cancel"`,
    and `nothingInFlight(action:)`, described as
    `"\(action): nothing is in flight on this pane — there is no send to cancel"`.
    `apiSendControl`:

```swift
public func apiSendControl(
    method: String, sending: ApiSending? = nil, now: Date = Date()
) -> (action: String, label: String) {
    if let sending {
        // W14: Send becomes Cancel and counts. `api.send` keeps its identifier.
        let elapsed = max(0, Int(now.timeIntervalSince(sending.since) * 1000))
        return (action: "api_cancel", label: "Cancel · \(apiSeconds(elapsed))")
    }
    return (action: apiIsReadMethod(method) ? "api_request" : "api_send", label: "Send")
}
```

    Update `registerApiActions`' doc comment (*"Four actions"*) to list `api_cancel`.
- [ ] **Step 4: Run.** `make app-test`, then `make app-bundle`. The view still compiles, and its
  response `switch` needs the `.cancelled` arm. Add `case .cancelled(let c): micro("RESPONSE");
  Text(apiCancelledLine(waitedMs: c.waitedMs)).foregroundStyle(ink.opacity(0.45))` now so the
  bundle builds. Task 7 finishes the view.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources app/Tests/WakilKitTests
git commit -m "A send in flight is marked, refused a second time, and cancelled by api_cancel down to wakil-http (W14)"
```

### Task 7: Environments (W12, W1) and the Send control in flight (W14, the view)

**Files:**
- Modify: `app/Sources/WakilKit/Gate/WriteGate.swift:101-137`. Add `environmentSwitchIsNoOp`.
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`. `setEnvironment` (`:2806`), the pump's
  `ctx_set_environment` branch (`:1703-1706`), `restorePaneContents` (`:3624`), and the
  `apiResolver` init parameter (designated `:1518`, org-aware public `:1925-1965`).
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`. Add `apiListing` and `apiOpenEntry`. Delete
  `apiEntryNames` (`:272`). Rewrite the `api_open` handler (`:396-441`) and description
  (`:374-383`). `api_request` and `api_send` refuse an unpointed pane. `registerApiActions`
  returns `ApiPaneResolver`. Add `apiReresolution`, `apiPaneIsUnpointed`, `ApiOriginLine` and
  `apiOriginLine`.
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift`. Add `reresolveApis(environment:listing:)`.
- Modify: `app/Sources/WakilKit/App/AppWiring.swift`. `WakilWiring.apiResolver` (`:299`, `:323`).
- Modify: `app/Sources/WakilApp/WindowSession.swift:254`. Pass `apiResolver: wiring.apiResolver`.
- Modify: `app/Sources/WakilApp/ApiPane.swift`. The origin line (`:983-991`) and `sendControl`
  (`:1489-1500`).
- Modify: `docs/wakil/decisions.md`. Add Decision 8's dated amendment for #183.
- Test: create `app/Tests/WakilKitTests/ApiEnvironmentTests.swift`. Modify `ApiPaneTests.swift:200`
  and `ActionRegistryTests.swift` or whichever file holds the `writeGate` table (find it with
  `grep -ln "writeGate(" app/Tests`).

**Interfaces:**
- Consumes: `ApiEntryListing`, `apiEntries(from:)`, `PaneStore.clearApiResponses`, Task 6's
  `apiSendControl(method:sending:now:)`.
- Produces:
  ```swift
  public func environmentSwitchIsNoOp(from current: String, to requested: String) -> Bool
  public struct ApiPaneResolver: Sendable { public func reresolve(environment: String) async }
  func apiReresolution(entry: String, listing: [ApiEntryListing]) -> (entry: String, origin: String?, credentialed: Bool)
  public func apiPaneIsUnpointed(entry: String, entries: [String]) -> Bool
  public let apiPickAnEntryFirst: String          // "pick an entry first"
  public enum ApiOriginLine: Equatable, Sendable { case origin(String), caution(String) }
  public func apiOriginLine(_ snapshot: ApiSnapshot) -> ApiOriginLine
  ```

- [ ] **Step 1: Write the failing tests** in `ApiEnvironmentTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// 9b W12 and W1: a switch that changes nothing raises nothing, and every api pane re-resolves
/// its entry when the environment does change.

private func listing(_ entries: [(String, String)]) -> [ApiEntryListing] {
    entries.map { ApiEntryListing(name: $0.0, baseURL: $0.1, credentialed: false) }
}

private func listApisReply(_ entries: [(String, String)]) -> JSONValue {
    .object(["structuredContent": .object(["apis": .array(entries.map {
        .object(["name": .string($0.0), "baseUrl": .string($0.1), "authenticated": .bool(false)])
    })])])
}

@Test("W12: the environment already active is a no-op, trimmed")
func aSwitchToTheActiveEnvironmentIsANoOp() {
    #expect(environmentSwitchIsNoOp(from: "production", to: " production "))
    #expect(!environmentSwitchIsNoOp(from: "staging", to: "production"))
    #expect(writeGate(
        environment: "production", kind: .control, origin: .agent,
        targetEnvironment: "production", production: .undeclared) == .allow)
    #expect(writeGate(
        environment: "staging", kind: .control, origin: .agent,
        targetEnvironment: "production", production: .undeclared) == .gate)
}

@Test("W1: an entry the new environment declares takes its origin; one it does not keeps its name")
func reresolution() {
    let qa = listing([("catalog", "https://catalog-qa.example")])
    #expect(apiReresolution(entry: "catalog", listing: qa).origin == "https://catalog-qa.example")
    let missing = apiReresolution(entry: "billing", listing: qa)
    #expect(missing.entry == "billing")
    #expect(missing.origin == nil)
}

@Test("Review Focus 5: a single-entry environment never leaves a pane unpointed")
func aSingleEntryEnvironmentNeverLeavesAPaneUnpointed() async throws {
    let one = listing([("catalog", "https://c.example")])
    #expect(apiReresolution(entry: "", listing: one).entry == "catalog")
    #expect(!apiPaneIsUnpointed(entry: "", entries: ["catalog"]))
    #expect(apiPaneIsUnpointed(entry: "", entries: ["catalog", "billing"]))

    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(),
        http: RecordingToolCaller(always: listApisReply([("catalog", "https://c.example")])),
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let f) = opened else { Issue.record("no result"); return }
    #expect(f["entry"] == .string("catalog"))
}

@Test("W1: api_open naming no entry in an environment of several opens unpointed, with the whole list")
func anOmittedEntryOpensUnpointed() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore()
    let http = RecordingToolCaller(always: listApisReply([
        ("billing", "https://b.example"), ("catalog", "https://c.example"),
    ]))
    await registerApiActions(
        into: registry, panes: panes, layout: LayoutStore(), http: http,
        activeContext: { ("initech", "proj", "staging", "/tmp") })
    let opened = try await registry.dispatch(
        name: "api_open", params: .object([:]), origin: .agent, environment: "staging",
        confirmation: nil)
    guard case .object(let f) = opened, case .string(let pane)? = f["pane"] else {
        Issue.record("no pane"); return
    }
    #expect(f["entry"] == .string(""))
    #expect(f["origin"] == .null)
    #expect(f["entries"] == .array([.string("billing"), .string("catalog")]))
    // One list_apis, not two (the handler used to call it once to pick and once to list).
    #expect(await http.calls.filter { $0.name == "list_apis" }.count == 1)

    // Send from it is refused, as a refusal the pane draws, and nothing reaches wakil-http.
    _ = try await registry.dispatch(
        name: "api_request", params: .object(["pane": .string(pane)]), origin: .agent,
        environment: "staging", confirmation: nil)
    let snapshot = await panes.apiSnapshot(paneId: pane)
    guard case .refusal(let refusal) = snapshot.response else { Issue.record("not refused"); return }
    #expect(refusal.failures.map(\.message) == [apiPickAnEntryFirst])
    #expect(refusal.failures.first?.region == nil)
    #expect(await http.calls.allSatisfy { $0.name == "list_apis" })
}

@Test("W1: the resolver re-resolves every api pane with one list_apis")
func theResolverReResolvesEveryPane() async {
    let panes = PaneStore()
    await panes.openApi(paneId: "api-1", entry: "catalog", environment: "staging",
                        origin: "https://c.example", credentialed: false, entries: ["catalog", "billing"])
    await panes.openApi(paneId: "api-2", entry: "billing", environment: "staging",
                        origin: "https://b.example", credentialed: true, entries: ["catalog", "billing"])
    await panes.clearApiResponses(to: "qa")
    let http = RecordingToolCaller(always: listApisReply([("catalog", "https://catalog-qa.example")]))
    await ApiPaneResolver(panes: panes, http: http).reresolve(environment: "qa")

    let one = await panes.apiSnapshot(paneId: "api-1")
    #expect(one.request.origin == "https://catalog-qa.example")
    #expect(one.entries == ["catalog"])
    let two = await panes.apiSnapshot(paneId: "api-2")
    #expect(two.entry == "billing")
    #expect(two.request.origin == nil)
    #expect(apiOriginLine(two) == .caution("qa declares no entry named billing — pick one"))
    #expect(await http.calls.count == 1)
}

@Test("The URL line says what is missing")
func theOriginLine() {
    func snap(entry: String, origin: String?, entries: [String]) -> ApiSnapshot {
        ApiSnapshot(
            entry: entry, environment: "staging", credentialed: false,
            request: ApiRequestSnapshot(method: "GET", origin: origin, path: [], query: [],
                                        headers: ApiRequestSnapshot.empty.headers, body: []),
            response: .none, entries: entries, recent: [], recentTruncated: false)
    }
    #expect(apiOriginLine(snap(entry: "c", origin: "https://c", entries: ["c"])) == .origin("https://c"))
    #expect(apiOriginLine(snap(entry: "", origin: nil, entries: ["a", "b", "c"]))
        == .caution("pick an entry — staging declares 3"))
    #expect(apiOriginLine(snap(entry: "c", origin: nil, entries: ["c"]))
        == .caution("no origin — this entry does not resolve"))
}
```

  In `ApiPaneTests.swift`, replace `anOmittedEntryIsRefusedRatherThanGuessedWhenSeveralExist`
  (`:200`). It now asserts that a pane opened, with `entry` `""`. The detail is pinned above.
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement the WakilKit half.**
  - `WriteGate.swift`:

```swift
/// Whether a switch asks for the environment already active (W12). It changes nothing, so it
/// prices nothing and refreshes nothing: no plane rises, no reply is cleared.
public func environmentSwitchIsNoOp(from current: String, to requested: String) -> Bool {
    current.trimmingCharacters(in: .whitespacesAndNewlines)
        == requested.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

    At the top of `writeGate`'s `.control` case:
    `if let target = targetEnvironment, environmentSwitchIsNoOp(from: environment, to: target) { return .allow }`.
  - `ApiActions.swift`. Replace `apiEntryNames` with:

```swift
/// Every entry the active environment declares, read with ONE `list_apis` (W1). `nil` when there
/// is no client to ask (`--dispatch`, this module's tests). `[]` when the call failed, because
/// "could not read" and "declares none" are the same pane with no origin.
func apiListing(http: (any ToolCaller)?) async -> [ApiEntryListing]? {
    guard let http else { return nil }
    guard let result = try? await http.callTool(
        name: "list_apis", arguments: .object([:]), timeout: MCPClient.readReplyTimeout)
    else { return [] }
    return apiEntries(from: result)
}

/// The entry `api_open` points at, or `nil` for an **unpointed** pane (W1; #183 amended). A
/// named entry must exist. With no name, one entry is that entry, none is refused, and several
/// is unpointed. **Nothing is guessed**: Send refuses an unpointed pane (`apiPickAnEntryFirst`).
func apiOpenEntry(
    named: String?, from entries: [ApiEntryListing], environment: String
) throws -> ApiEntryListing? {
    if let named, !named.isEmpty {
        guard let match = entries.first(where: { $0.name == named }) else {
            throw ApiActionError.unknownEntry(action: "api_open", entry: named, names: entries.map(\.name))
        }
        return match
    }
    switch entries.count {
    case 0: throw ApiActionError.noEntries(action: "api_open", environment: environment)
    case 1: return entries[0]
    default: return nil
    }
}

public let apiPickAnEntryFirst = "pick an entry first"

/// Unpointed: no entry, in an environment declaring several. A single-entry environment never
/// leaves a pane unpointed (Review Focus 5).
public func apiPaneIsUnpointed(entry: String, entries: [String]) -> Bool {
    entry.isEmpty && entries.count > 1
}

/// What a pane's entry resolves to in an environment's listing (W1).
func apiReresolution(
    entry: String, listing: [ApiEntryListing]
) -> (entry: String, origin: String?, credentialed: Bool) {
    if let match = listing.first(where: { $0.name == entry }) {
        return (match.name, apiPaneOrigin(baseURL: match.baseURL), match.credentialed)
    }
    if entry.isEmpty, listing.count == 1 {
        let only = listing[0]
        return (only.name, apiPaneOrigin(baseURL: only.baseURL), only.credentialed)
    }
    return (entry, nil, false)
}

/// Re-resolves every api pane after the environment changed, or at launch (W1). One
/// `list_apis`, then each pane by name. **Returned by `registerApiActions`**, because the
/// action module is what holds the http client.
public struct ApiPaneResolver: Sendable {
    let panes: PaneStore
    let http: (any ToolCaller)?

    public func reresolve(environment: String) async {
        guard let listing = await apiListing(http: http) else { return }
        await panes.reresolveApis(environment: environment, listing: listing)
    }
}

/// The URL line's lead: the origin, or what is missing, in caution's amber.
public enum ApiOriginLine: Equatable, Sendable {
    case origin(String)
    case caution(String)
}

public func apiOriginLine(_ snapshot: ApiSnapshot) -> ApiOriginLine {
    if let origin = snapshot.request.origin { return .origin(origin) }
    if apiPaneIsUnpointed(entry: snapshot.entry, entries: snapshot.entries) {
        return .caution("pick an entry — \(snapshot.environment) declares \(snapshot.entries.count)")
    }
    if !snapshot.entry.isEmpty, !snapshot.entries.isEmpty, !snapshot.entries.contains(snapshot.entry) {
        return .caution("\(snapshot.environment) declares no entry named \(snapshot.entry) — pick one")
    }
    return .caution("no origin — this entry does not resolve")
}
```

    `api_open`'s handler becomes:

```swift
            let context = await activeContext()
            let named = optionalString(params, "entry")
            let entry: ApiEntryListing?
            let declared: [String]
            if let listing = await apiListing(http: http) {
                entry = try apiOpenEntry(named: named, from: listing, environment: context.environment)
                declared = listing.map(\.name)
            } else {
                // Unwired: whatever was named, with no origin, as before.
                entry = ApiEntryListing(name: named ?? "", baseURL: "", credentialed: false)
                declared = []
            }
            let name = entry?.name ?? ""
            let origin = entry.flatMap { apiPaneOrigin(baseURL: $0.baseURL) }
            let credentialed = entry?.credentialed ?? false
            let resolved = await resolveApiPane(
                explicit: explicit, title: apiPaneTitle(entry: name, path: ""), layout: layout)
            let entries = declared.isEmpty ? [name] : declared
            await panes.openApi(
                paneId: resolved, entry: name, environment: context.environment,
                origin: origin, credentialed: credentialed, entries: entries)
            return .object([
                "pane": .string(resolved),
                "entry": .string(name),
                "origin": origin.map { .string($0) } ?? .null,
                "credentialed": .bool(credentialed),
                "entries": .array(entries.map { .string($0) }),
            ])
```

    Its description's *"with several, naming none is refused rather than guessed at, because the
    entries do not share a credential and a guess would send one backend's token to another
    backend's host"* becomes *"with several, naming none opens the pane UNPOINTED, with every
    entry in the result's entries; Send from an unpointed pane is refused ('pick an entry
    first') until an entry is chosen with api_set_request's entry, because the entries do not
    share a credential and a guess would send one backend's token to another backend's host."*

    In `api_request` and `api_send`, right after the method guard and before `apiSendInFlight`:

```swift
            // W1: an unpointed pane has nowhere to send. Refused as a refusal the pane draws,
            // naming no region. Nothing reaches wakil-http.
            if apiPaneIsUnpointed(entry: snapshot.entry, entries: snapshot.entries) {
                let refusal = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: [
                    ApiSendFailure(region: nil, message: apiPickAnEntryFirst)
                ]))
                await panes.setApiResponse(paneId: paneId, response: refusal)
                return .object([
                    "pane": .string(paneId), "state": .string(refusal.state), "status": .null,
                ])
            }
```

    `registerApiActions` gains `@discardableResult` and `-> ApiPaneResolver`, and ends with
    `return ApiPaneResolver(panes: panes, http: http)`.
  - `PaneStore.swift`, next to `clearApiResponses`:

```swift
    /// Every api pane's entry, re-resolved against a new environment's listing (W1). The draft
    /// is kept and nothing is sent. Re-sending here would put an unattended request on the wire.
    func reresolveApis(environment: String, listing: [ApiEntryListing]) {
        for paneId in panes.keys {
            guard case .api(var contents)? = panes[paneId] else { continue }
            let resolved = apiReresolution(entry: contents.draft.entry, listing: listing)
            contents.environment = environment
            contents.draft.entry = resolved.entry
            contents.origin = resolved.origin
            contents.credentialed = resolved.credentialed
            contents.entries = listing.map(\.name)
            panes[paneId] = .api(contents)
        }
    }
```

    In `clearApiResponses`' comment, replace *"nothing re-resolves an api pane on a switch —
    `restorePaneContents` does not re-run this kind"* with *"`ApiPaneResolver` re-resolves them
    next, in `restorePaneContents`; until it answers, absent is honest where stale is not"*.
  - `AppWiring.swift`. Capture `let apiResolver = await registerApiActions(…)` and add
    `public let apiResolver: ApiPaneResolver?` to `WakilWiring` (init argument
    `apiResolver: apiResolver`).
  - `WindowModel.swift`. Add `apiResolver: ApiPaneResolver? = nil` to the designated init and to
    the org-aware public convenience init, following `providerMintFactory`'s precedent and doc
    sentence. Store it as `@ObservationIgnored private let apiResolver: ApiPaneResolver?`. The
    e2e check `api-env-roundtrip` (Task 9) is what fails if production forgets to pass it. Then:
    - `restorePaneContents()` starts with `await apiResolver?.reresolve(environment: environment)`.
      That covers launch, a switch and an org switch loaded from disk.
    - `setEnvironment(_:)` starts with
      `guard !environmentSwitchIsNoOp(from: environment, to: name) else { return }` (W12).
    - The pump's branch becomes:

```swift
                if name == "ctx_set_environment" {
                    let before = self.environment
                    await self.refreshContext()
                    // W12: a switch to the active environment changes nothing on screen.
                    if !environmentSwitchIsNoOp(from: before, to: self.environment) {
                        // The agent's switch now does what the operator's does, replies included.
                        await self.panes.clearApiResponses(to: self.environment)
                        await self.restorePaneContents()
                    }
                }
```

  - `WindowSession.swift:254`. Pass `apiResolver: wiring.apiResolver` beside `confirmations:`.
- [ ] **Step 4: Wire the view.**
  - `ApiPane.fieldFlow`'s origin lead (`:983-991`):

```swift
                switch apiOriginLine(snapshot) {
                case .origin(let origin): Text(origin).foregroundStyle(ink.opacity(0.45))
                case .caution(let line): Text(line).foregroundStyle(amber)
                }
```

  - `sendControl` (W14). The label counts, and the action is `api_cancel` while in flight:

```swift
    private var sendControl: some View {
        // Redrawn ten times a second only while a send is in flight. The identifier never
        // changes, only the label.
        TimelineView(.periodic(from: .now, by: snapshot.sending == nil ? 3600 : 0.1)) { context in
            let control = apiSendControl(
                method: snapshot.request.method, sending: snapshot.sending, now: context.date)
            FormButton(
                title: control.label, tone: SettingsPalette.accent, filled: true,
                identifier: "api.send"
            ) {
                if snapshot.sending != nil {
                    // Cancel flushes nothing: it ends a send, it does not read the draft.
                    operate("api_cancel", .object(["pane": .string(pane.id)]))
                } else {
                    send()
                }
            }
        }
    }
```

  - ⌘Return in the body while in flight goes through `send()`, which starts with
    `guard snapshot.sending == nil else { return }`. ⌘Return never cancels.
  - The response view's `.cancelled` arm (added in Task 6) gets `.wraps()`.
- [ ] **Step 5: Amend Decision 8 for #183.** In `docs/wakil/decisions.md`, after Decision 8's
  amendment that ends *"…"an environment holds APIs, plural".)*"* (`:143`), add:

```markdown
   *(Amended 2026-10-03 by 2c-iv Amendment 9b, W1: [#183](https://github.com/yehia-khalil/rafiq/issues/183)'s
   ambiguity refusal moves from `api_open` to Send.* An `api_open` naming no entry in an
   environment of several no longer refuses. It opens the pane **unpointed**, from ⌘K and from an
   agent alike, with the whole list in the chooser and in its result's `entries`. **Send from an
   unpointed pane is refused, "pick an entry first"**, before anything reaches `wakil-http`.
   Nothing is guessed, so the reason for refusing (*a guess would send one backend's credential
   to another backend's host*) still holds. It is met by a later refusal instead of an earlier
   one. `PickAPI` keeps its own refusal unchanged, and the window never reaches it without a
   name. Every api pane also re-resolves its entry by name when the environment changes and at
   launch. An entry of that name gives the pane that environment's origin and credential flag.
   No such entry keeps the name, and the URL line says the environment declares none.)*
```

- [ ] **Step 6: Run.** `make app-test`, `make app-bundle` and `make controls`. Run
  `grep -rn "lookupFactory:" app/Tests` and check that every call site still compiles. The new
  parameter is defaulted.
- [ ] **Step 7: Commit.**

```bash
git add app/Sources app/Tests/WakilKitTests docs/wakil/decisions.md
git commit -m "An environment switch re-resolves every api pane and a no-op switch raises nothing; api_open opens unpointed, Send refuses it, and Send becomes Cancel in flight"
```

Then: `superpowers:requesting-code-review` for Phase 3 (Tasks 6–7).

---

### Task 8: The harness: a refused dispatch, a stalling server, and a second environment

**Files:**
- Modify: `e2e/driver/check.go:171-176`. `Dispatch.Refuses`.
- Modify: `e2e/driver/run.go:674-686`. `dispatch` honours `Refuses`.
- Create: `e2e/driver/stall.go`, `e2e/driver/stall_test.go`.
- Modify: `e2e/driver/seed.go`. `SeedSpec.StallOrigin`, `fixtureAPIEntries(stallOrigin:)`, and a
  `qa` environment.
- Modify: `e2e/driver/session.go:160-175`. Start the listener before `Seed`.
- Test: `e2e/driver/runner_test.go`, `e2e/driver/check_test.go`, `e2e/driver/seed_test.go`.

**Why each piece.** First, every refusal this plan adds is the point of a check: Decision 27 by
focus, *"a send is already in flight"*, and `api_cancel` with nothing to cancel. A `dispatch`
that is refused fails its step (`ParseToolResult`, `mcp.go:301`). `refuses` is an optional
**field** on the existing `dispatch` kind, not a new step kind, and the step passes only when the
action is refused in those words. Second, the cancel check needs a send that hangs. The fixture's
`.invalid` hosts fail at DNS in milliseconds, and `wakil-http` requires `https` and trusts only the
system roots, so a local HTTPS server cannot be trusted. A **TCP listener that accepts and never
answers** stalls the TLS handshake instead. Go gives up after `http.DefaultTransport`'s 10 s
`TLSHandshakeTimeout`, which leaves room to cancel at about 1 s. Third, W1's round trip needs a
second environment.

- [ ] **Step 1: Write the failing Go tests.**

```go
// runner_test.go, next to TestRunnerRecordsARefusedDispatch
func TestRunnerPassesARefusalItExpected(t *testing.T) {
	channel := &fakeChannel{errs: map[string]error{
		"api_set_request": fmt.Errorf("the action was refused: api_set_request: the operator is editing Path"),
	}}
	runner, _ := newRunner(t, stateJSON, channel)
	got := runner.Run([]Check{mustParse(t, "r",
		`{"dispatch":{"action":"api_set_request","params":{"pane":"api-1"},"refuses":"the operator is editing Path"}}`)})
	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
}

func TestRunnerFailsARefusesStepWhoseActionRan(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, &fakeChannel{})
	got := runner.Run([]Check{mustParse(t, "r",
		`{"dispatch":{"action":"api_set_request","params":{"pane":"api-1"},"refuses":"editing"}}`)})
	if err := got.Err(); err == nil || !strings.Contains(err.Error(), "and it ran") {
		t.Fatalf("want a failure saying it ran, got %v", err)
	}
}

func TestRunnerFailsARefusalInOtherWords(t *testing.T) {
	channel := &fakeChannel{errs: map[string]error{"api_cancel": fmt.Errorf("the action was refused: no such pane")}}
	runner, _ := newRunner(t, stateJSON, channel)
	got := runner.Run([]Check{mustParse(t, "r",
		`{"dispatch":{"action":"api_cancel","params":{"pane":"api-1"},"refuses":"nothing is in flight"}}`)})
	if err := got.Err(); err == nil || !strings.Contains(err.Error(), "not with") {
		t.Fatalf("want a failure naming the expected words, got %v", err)
	}
}
```

```go
// stall_test.go
package driver

import (
	"net"
	"strings"
	"testing"
	"time"
)

func TestStallListenerAcceptsAndNeverAnswers(t *testing.T) {
	stall, err := StartStallListener()
	if err != nil {
		t.Fatal(err)
	}
	defer stall.Close()
	if !strings.HasPrefix(stall.Origin(), "https://127.0.0.1:") {
		t.Fatalf("origin = %q", stall.Origin())
	}
	conn, err := net.Dial("tcp", strings.TrimPrefix(stall.Origin(), "https://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte("\x16\x03\x01")) // the start of a ClientHello
	conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if n, err := conn.Read(make([]byte, 1)); n != 0 || err == nil {
		t.Fatalf("the listener answered: n=%d err=%v", n, err)
	}
}

func TestStallListenerCloseDropsItsConnections(t *testing.T) {
	stall, err := StartStallListener()
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("tcp", strings.TrimPrefix(stall.Origin(), "https://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	time.Sleep(50 * time.Millisecond)
	stall.Close()
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("the connection outlived Close")
	}
}
```

```go
// seed_test.go
func TestSeedDeclaresASecondEnvironmentForTheSwitchCheck(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)
	resolved, err := wakilcore.Resolve()
	if err != nil {
		t.Fatal(err)
	}
	qa, ok := resolved.Project.Environments["qa"]
	if !ok || len(qa.API) != 1 || qa.API[0].Name != "catalog" ||
		qa.API[0].BaseURL != "https://catalog-qa.e2e-fixture.invalid" {
		t.Fatalf("qa = %+v", qa)
	}
	if wakilcore.EnvironmentIsProduction("qa", qa) {
		t.Fatal("qa reads as production; the switch check would raise a plane")
	}
}

func TestSeedDeclaresTheSlowEntryOnlyWithAStallOrigin(t *testing.T) {
	if names := apiNames(fixtureAPIEntries("")); strings.Contains(names, "slow") {
		t.Fatalf("slow declared with no listener: %s", names)
	}
	entries := fixtureAPIEntries("https://127.0.0.1:4711")
	if last := entries[len(entries)-1]; last.Name != "slow" || last.BaseURL != "https://127.0.0.1:4711" {
		t.Fatalf("slow = %+v", last)
	}
}

func apiNames(entries []wakilcore.ApiConfig) string {
	var names []string
	for _, e := range entries {
		names = append(names, e.Name)
	}
	return strings.Join(names, ",")
}
```

  Add to `check_test.go` that `{"dispatch":{"action":"x","refuses":"y"}}` parses with
  `Refuses == "y"`, and that `"refuses":""` is the same as omitting it.
- [ ] **Step 2: Run and watch them fail.** `go test ./e2e/driver/ -run "Refus|Stall|SecondEnvironment|SlowEntry"`.
- [ ] **Step 3: Implement.**
  - `check.go`:

```go
type Dispatch struct {
	Action string                 `json:"action"`
	Params map[string]interface{} `json:"params,omitempty"`
	// Refuses makes the step pass only when the action is REFUSED, with a refusal carrying
	// this text — and fail when it runs. A refusal is the outcome some checks exist to see
	// (Decision 27's one-author rule, a second send in flight), and without this a refused
	// dispatch could only ever fail its step. A field on dispatch, not a fifth step kind.
	Refuses string `json:"refuses,omitempty"`
}
```

  - `run.go` `dispatch`:

```go
	_, err := r.Channel.Call(step.Action, ExpandParams(step.Params, r.FixtureRoot))
	switch {
	case step.Refuses != "" && err == nil:
		return fmt.Errorf("%q was expected to be refused with %q, and it ran", step.Action, step.Refuses)
	case step.Refuses != "" && !strings.Contains(err.Error(), step.Refuses):
		return fmt.Errorf("%q was refused, but not with %q: %v", step.Action, step.Refuses, err)
	case step.Refuses == "" && err != nil:
		return err
	}
```

  - `stall.go`:

```go
package driver

import (
	"net"
	"sync"
)

// StallListener is a server that accepts connections and never answers: a
// TLS client's handshake waits on it until the client gives up. It is the
// slow server the cancel check sends to (2c-iv W14), with no certificate to
// trust — wakil-http requires https and trusts only the system roots, so a
// local HTTPS server could not be reached at all, while a stalled handshake
// is reached and simply never completes. Go's transport gives up after its
// 10 s TLSHandshakeTimeout, which is the window a check has to cancel in.
type StallListener struct {
	ln    net.Listener
	mu    sync.Mutex
	conns []net.Conn
}

func StartStallListener() (*StallListener, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	s := &StallListener{ln: ln}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			s.mu.Lock()
			s.conns = append(s.conns, conn)
			s.mu.Unlock()
		}
	}()
	return s, nil
}

// Origin is the baseUrl the fixture's `slow` entry carries.
func (s *StallListener) Origin() string { return "https://" + s.ln.Addr().String() }

// Close stops accepting and drops every connection it is holding.
func (s *StallListener) Close() error {
	err := s.ln.Close()
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.conns {
		c.Close()
	}
	s.conns = nil
	return err
}
```

  - `seed.go`. `SeedSpec` gains `StallOrigin string`, documented as *"the baseUrl of the fixture's
    `slow` entry: a `StallListener` the session started. Empty declares no `slow` entry."*
    `fixtureAPIEntries` becomes `fixtureAPIEntries(stallOrigin string)` and appends
    `{Name: "slow", BaseURL: stallOrigin}` when non-empty. Add a paragraph to its doc comment:
    *"`slow` is the third, and the only one whose host answers, by never answering (W14)."*
    `Environments` gains:

```go
			// A second environment, for W1's round-trip switch. It declares catalog under its
			// own origin, and no billing, so a switch shows both re-resolution (a new origin)
			// and the name kept with nothing behind it. Not production by name, and no flag.
			"qa": {
				Databases: []wakilcore.Database{},
				API: []wakilcore.ApiConfig{
					{Name: "catalog", BaseURL: "https://catalog-qa.e2e-fixture.invalid"},
				},
			},
```

    and the staging entry calls `fixtureAPIEntries(spec.StallOrigin)`.
  - `session.go`, inside `if s.Seed {` and before `Seed(fixture, spec)`:

```go
		// The cancel check's slow server (W14). Alive for the whole launch, closed with it.
		stall, err := StartStallListener()
		if err != nil {
			return Result{}, err
		}
		defer stall.Close()
		spec.StallOrigin = stall.Origin()
```

- [ ] **Step 4: Run.** `go test ./e2e/... ./...`. All headless.
- [ ] **Step 5: Commit.**

```bash
git add e2e/driver
git commit -m "The harness can expect a refusal, stall a send, and switch to a second environment"
```

### Task 9: The checks, and the one GUI session

**Files:**
- Create: `e2e/checks/seeded/api-saved-as-typed.jsonl`, `api-one-author-focus.jsonl`,
  `api-cancel.jsonl`, `api-send-what-it-shows.jsonl`, `api-env-roundtrip.jsonl`
- Modify: `e2e/checks/seeded/api-query-sync.jsonl`, `api-body-editor.jsonl`, `api-hole.jsonl`,
  `api-rows.jsonl`, `api-surface.jsonl`
- Modify: `e2e/checks/uncoverable.tsv` §1. Add one line, `api_cancel`.

**Read first:** `docs/agents/e2e.md` and `e2e/driver/check.go`. Two typing facts are inferred from
the shipped checks, not documented. `type` into a single-line `TextField` **replaces** its text:
focus through AXFocused selects it all, which is why `api-query-sync.jsonl` typed `3` over `2` and
read back `3`. `type` into the body's `NSTextView` **appends**. `api-set-request.jsonl` and
`api-bind.jsonl` are on the spec's list, but neither holds a Return, Escape or uncommitted step,
so they stay unchanged. Their behaviour does not change either.

- [ ] **Step 1: Update the shipped checks for 9a.** The model: a typed value is saved without
  Return. A name box (`*.add.name`, `*.hole.name`) still commits on Return. ⌘Return in the body
  sends.
  - `api-hole.jsonl`. Delete the `{"do":{"press":"Return"}}` lines that follow a `type` into
    `api.path` or `api.path.part.0` (lines 3, 9 and 15). Keep the name-box Returns (lines 6 and 25).
  - `api-rows.jsonl`. Delete the Return after `type` into `api.contentType` (line 3) and after
    `type` into `api.header.X-Trace-Id` (line 11). Keep every name-box Return and every Escape on
    a name box.
  - `api-surface.jsonl`. Delete the Returns after `type` into `api.path`, `api.query.expand`,
    `api.header.x-trace` and `api.contentType`. Delete `{"do":{"hotkey":"cmd+Return"}}`, which
    would now send. The `expect` after each one waits for the pause.
  - `api-query-sync.jsonl`. Replace the whole file. The cross refusal it walked is gone.

```
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"do":{"type":{"into":"api.path","text":"/orders?status=open&limit=5"}}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/orders"}}
{"expect":{"pane":"api-1","field":"request.path[1]","present":false}}
{"expect":{"pane":"api-1","field":"request.query[0].name","equals":"status"}}
{"expect":{"pane":"api-1","field":"request.query[0].value[0].literal","equals":"open"}}
{"expect":{"pane":"api-1","field":"request.query[1].name","equals":"limit"}}
{"expect":{"pane":"api-1","field":"request.query[1].value[0].literal","equals":"5"}}
{"do":{"click":"api.query.add"}}
{"do":{"type":{"into":"api.query.add.name","text":"page"}}}
{"do":{"press":"Return"}}
{"expect":{"pane":"api-1","field":"request.query[2].name","equals":"page"}}
{"do":{"type":{"into":"api.query.page","text":"2"}}}
{"expect":{"pane":"api-1","field":"request.query[2].value[0].literal","equals":"2"}}
{"expect":{"tree":"contains","text":"limit=5&page=2"}}
{"do":{"type":{"into":"api.path","text":"/o?=x"}}}
{"expect":{"tree":"contains","text":"a query row needs a name"}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/orders"}}
{"expect":{"pane":"api-1","field":"request.query[3]","present":false}}
{"do":{"press":"Escape"}}
{"expect":{"tree":"absent","text":"a query row needs a name"}}
{"do":{"type":{"into":"api.query.page","text":"3"}}}
{"expect":{"pane":"api-1","field":"request.query[2].value[0].literal","equals":"3"}}
{"expect":{"tree":"contains","text":"limit=5&page=3"}}
```

  - `api-body-editor.jsonl`. Replace the whole file:

```
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"post","path":[{"literal":"/orders"}]}}}
{"expect":{"pane":"api-1","field":"request.body","equals":"[]"}}
{"do":{"type":{"into":"api.body","text":"{\"a\":1,"}}}
{"do":{"press":"Return"}}
{"do":{"keys":"\"b\":2"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\"a\":1,\n\"b\":2"}}
{"do":{"click":"api.body.format"}}
{"expect":{"tree":"contains","text":"not JSON — nothing formatted"}}
{"do":{"keys":"}"}}
{"expect":{"tree":"absent","text":"not JSON — nothing formatted"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\"a\":1,\n\"b\":2}"}}
{"do":{"click":"api.body.format"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\n  \"a\": 1,\n  \"b\": 2\n}"}}
{"do":{"type":{"into":"api.body","text":"x"}}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","contains":"x"}}
{"do":{"press":"Escape"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\n  \"a\": 1,\n  \"b\": 2\n}"}}
{"do":{"click":"api.body.hole"}}
{"do":{"type":{"into":"api.body.hole.name","text":"tail"}}}
{"do":{"press":"Return"}}
{"expect":{"pane":"api-1","field":"request.body[1].slot","equals":"tail"}}
{"do":{"focus":"api.body"}}
{"do":{"press":"Tab"}}
{"do":{"keys":"}"}}
{"do":{"hotkey":"cmd+Return"}}
{"expect":{"pane":"api-1","field":"request.body[2].literal","equals":"  }"}}
{"expect":{"journal":{"contains":"Send POST https://catalog.e2e-fixture.invalid/orders with "}}}
{"expect":{"pane":"api-1","field":"response.state","equals":"refusal"}}
{"expect":{"pane":"api-1","field":"response.failures[0].region","equals":"Body"}}
```

- [ ] **Step 2: Write the five new checks.** Use one api pane wherever `api.send` is clicked, because
  the harness refuses a duplicate identifier.
  - `api-saved-as-typed.jsonl`. A typed path is what Send sends (B5), and path ↔ query follow
    each other live.

```
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"do":{"type":{"into":"api.path","text":"/test"}}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"recent[0].path","equals":"/test"}}
{"do":{"type":{"into":"api.path","text":"/orders?page=2"}}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/orders"}}
{"expect":{"pane":"api-1","field":"request.query[0].value[0].literal","equals":"2"}}
{"do":{"type":{"into":"api.query.page","text":"5"}}}
{"expect":{"pane":"api-1","field":"request.query[0].value[0].literal","equals":"5"}}
{"expect":{"tree":"contains","text":"/orders?page=5"}}
```

  - `api-one-author-focus.jsonl`. Decision 27 by focus, with nothing typed.

```
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","path":[{"literal":"/v1"}]}}}
{"do":{"focus":"api.path"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","path":[{"literal":"/agent"}]},"refuses":"the operator is editing Path"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","query":[{"name":"a","value":[]}]},"refuses":"the operator is editing Query"}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/v1"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"post"}}}
{"expect":{"pane":"api-1","field":"request.method","equals":"POST"}}
{"do":{"focus":"api.body"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","path":[{"literal":"/agent"}]}}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/agent"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","body":[{"literal":"{}"}]},"refuses":"the operator is editing Body"}}
```

  - `api-cancel.jsonl`. `api_cancel` down both channels, each after its own Send, against the
    `slow` entry.

```
{"dispatch":{"action":"api_open","params":{"entry":"slow"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","path":[{"literal":"/stall"}]}}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"sending","equals":"true"}}
{"expect":{"tree":"contains","text":"Cancel ·"}}
{"dispatch":{"action":"api_request","params":{"pane":"api-1"},"refuses":"a send is already in flight on this pane"}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"response.state","equals":"cancelled"}}
{"expect":{"pane":"api-1","field":"sending","equals":"false"}}
{"expect":{"tree":"contains","text":"cancelled after"}}
{"expect":{"pane":"api-1","field":"recent[0].cancelled","equals":"true"}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"sending","equals":"true"}}
{"dispatch":{"action":"api_cancel","params":{"pane":"api-1"}}}
{"expect":{"pane":"api-1","field":"response.state","equals":"cancelled"}}
{"expect":{"pane":"api-1","field":"recent[1].cancelled","equals":"true"}}
{"dispatch":{"action":"api_cancel","params":{"pane":"api-1"},"refuses":"nothing is in flight"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"post","body":[{"literal":"{}"}]}}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"sending","equals":"true"}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"response.state","equals":"unknown"}}
{"expect":{"tree":"contains","text":"the server may already have it"}}
```

  - `api-send-what-it-shows.jsonl`. B1, B2 and B3.

```
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"get","path":[{"literal":"/orders"}],"contentType":"application/json","body":[{"literal":"{\"a\":1}"}]}}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"response.state","equals":"transport"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\"a\":1}"}}
{"expect":{"tree":"absent","text":"unexpected additional properties"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"delete","body":[]}}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"response.state","equals":"transport"}}
{"expect":{"tree":"absent","text":"is set beside an empty body"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","entry":"billing","method":"get"}}}
{"do":{"click":"api.send"}}
{"expect":{"pane":"api-1","field":"response.state","equals":"refusal"}}
{"expect":{"pane":"api-1","field":"response.failures[0].region","present":false}}
```

  - `api-env-roundtrip.jsonl`. W1. Sends by dispatch, because three api panes are open.

```
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_open","params":{"entry":"billing"}}}
{"expect":{"pane":"api-1","field":"request.origin","equals":"https://catalog.e2e-fixture.invalid"}}
{"dispatch":{"action":"ctx_set_environment","params":{"name":"qa"}}}
{"expect":{"pane":"api-1","field":"environment","equals":"qa"}}
{"expect":{"pane":"api-1","field":"request.origin","equals":"https://catalog-qa.e2e-fixture.invalid"}}
{"expect":{"pane":"api-2","field":"entry","equals":"billing"}}
{"expect":{"tree":"contains","text":"qa declares no entry named billing — pick one"}}
{"dispatch":{"action":"ctx_set_environment","params":{"name":"staging"}}}
{"expect":{"pane":"api-1","field":"request.origin","equals":"https://catalog.e2e-fixture.invalid"}}
{"expect":{"pane":"api-2","field":"request.origin","equals":"https://billing.e2e-fixture.invalid"}}
{"expect":{"tree":"absent","text":"declares no entry named"}}
{"dispatch":{"action":"api_open","params":{}}}
{"expect":{"pane":"api-3","field":"entry","equals":""}}
{"expect":{"tree":"contains","text":"pick an entry — staging declares 3"}}
{"dispatch":{"action":"api_request","params":{"pane":"api-3"}}}
{"expect":{"pane":"api-3","field":"response.failures[0].message","equals":"pick an entry first"}}
```

- [ ] **Step 3: Add the parity excuse.** In `e2e/checks/uncoverable.tsv` §1, after the `api_unbind`
  line:

```
api_cancel	its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
```

- [ ] **Step 4: GUI. Ask the operator first, quit the live Wakil, and tell the peers.** Run
  `make e2e-new E2E_NEW_ARGS="--base ed1af70"` and **read each reason, not the count**. The five
  new files must be red against `ed1af70`, for these reasons:
  - `api-saved-as-typed`: `recent[0].path` is `""`.
  - `api-one-author-focus`: the first `refuses` step *"…and it ran"*.
  - `api-cancel`: `slow` exists in the branch's fixture, but nothing in flight is published (no
    `sending` key).
  - `api-send-what-it-shows`: `refusal` where `transport` is expected.
  - `api-env-roundtrip`: the `qa` origin is missing.

  A file red because the window could not be reached proves nothing. Fix it and rerun. Check
  `make e2e-new`'s exit status itself, not a piped `tail`.
- [ ] **Step 5: GUI (same OK). `make e2e`.** Every file must be green and the coverage gate clean.
  The gate's output lists the new `api_cancel` excuse.
- [ ] **Step 6: Commit the checks.**

```bash
git add e2e/checks
git commit -m "The checks for saved-as-typed, the one-author rule by focus, a cancellable send, what a send carries, and the round-trip switch"
```

### Task 10: The runbook

**Files:** Modify `docs/wakil/phase-2c-iv-acceptance.md`.

- [ ] **Step 1: Rewrite check 4** (`:53-80`). Keep the drag-outline and open-hand questions, the
  autocorrect question, the straight-quote question and the closing *"Every step by hand"*
  paragraph as they are. Replace the gesture walk with this:

```markdown
- [ ] **4. A request built entirely by hand reaches a real server.** Against a live
      entry: pick it from the chooser, type `/anything/customers/`, press `+ hole`, type
      `id` and press Return — the amber chip appears — then type `/confirm` after it.
      **Nothing else here needs Return**: what you type is saved as you pause, and at once
      when you leave the field or press anything. Type `?expand=all` at the end of the
      path — within a moment the Query region shows `expand=all` as its own row. Press
      `+ query`, type `page`, press Return (a name box still takes Return), and type `2`
      into its value — the path line follows with `...&page=2`. Press `+ header`, type
      `X-Trace-Id`, press Return, and give it a value. Press `+ header` again, type
      `authorization` and press Return — it is refused, naming `wakil secrets set-api`.
      Press `+ header` once more and type `content-type` — it goes to Wakil's own row.
      (autocorrect question, unchanged.) Open a DB pane on a table whose column matches the
      hole's name and **drag a row's `⋮` grip onto the api pane** — the chip fills, and a
      drop is never refused for what you are typing. Click into a box, type, and press
      Escape — **the field goes back to what it held when you clicked in**. Type a
      multi-line JSON body (Return is a newline), then press **Format** — it re-indents.
      (straight-quote question, unchanged.) Press Send, or ⌘Return in the body. Then point
      the path at something that answers slowly (`/delay/10` on httpbin) and press Send:
      **the button reads `Cancel · 1.2 s` and counts up**. Press it. A `GET` reads
      *"cancelled after N s"* in grey; send it again as a `POST` and cancel — it reads
      *"… — the server may already have it"* in amber. **Does the amber read as "this may
      have happened" rather than "this failed"?** (Every step by hand…, and the two drag
      questions, unchanged.)
```

- [ ] **Step 2: Rewrite check 8** (`:96-99`):

```markdown
- [ ] **8. The one-author rule fires on screen.** Click into the path field and leave the
      cursor there — type nothing. Ask the agent to set the path. **The write must be
      refused, naming the field.** Click out of the field and ask again: **it lands.** The
      rule is now *the cursor is in it*, not *it holds unsaved text* (Decision 27, amended
      2026-10-03), because nothing is ever left unsaved.
```

- [ ] **Step 3: Rewrite check 10** (`:106-109`):

```markdown
- [ ] **10. An environment switch clears the present and nothing else.** With a reply on
      screen and a draft you care about, switch environments. **The reply goes, the draft
      stays, nothing is re-sent**, and the chooser offers the new environment's entries.
      Switch back: **the pane's origin is its entry's own again** — never *no origin*.
      Then choose the environment that is already active: **nothing happens, and no plane
      rises.**
```

  Add one sentence under §0's intro: *"Amendment 9 re-walk: checks 4, 6 and 10."* Change
  *"Twenty-eight check files"* (`:10`) to the count `ls e2e/checks/*/*.jsonl | wc -l` gives.
- [ ] **Step 4: Render with the edits still uncommitted.**
  `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2c-iv-acceptance.md`. This is headless and reads
  Task 9's records. Never edit between the `machine-walk` markers. It must render green, against
  Task 9's build. Then commit the hand edits and the render together.
- [ ] **Step 5: Commit.**

```bash
git add docs/wakil/phase-2c-iv-acceptance.md
git commit -m "2c-iv's runbook: nothing needs Return, Cancel is walked, the one-author rule by focus, and the round-trip switch"
```

Then: `superpowers:requesting-code-review` for the whole branch, and after that the **Walk** rung:
the operator re-walks checks 4, 6 and 10. The 9c plan is written next, with
`superpowers:writing-plans`.

---

## Gate — done when

- [ ] `go test ./...` green, including Task 1's abort proof, which was also seen red with the
      context detached.
- [ ] `make app-test` green. `make app-bundle` and `make controls` clean.
- [ ] `make e2e-new E2E_NEW_ARGS="--base ed1af70"` saw all five new checks red, for the reasons
      Task 9 names. `make e2e` green, gate clean.
- [ ] No shipped identifier changed. `api.send` reads `Cancel · N s` while in flight, under the
      same identifier.
- [ ] `uncoverable.tsv` gained exactly one line: `api_cancel`'s parity.
- [ ] `grep -rn "apiDropRefusal\|apiPathQueryCrossRefusal\|apiBoxesDiscarding\|apiRowRemoveRefusal\|ApiFieldEdit\|noteApiEdit" app/`
      is empty.
- [ ] `decisions.md` carries Decision 27's amendment and Decision 8's #183 amendment.
- [ ] The runbook re-rendered green, and the re-walk is checks 4, 6 and 10.
