import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import WakilKit

private func reg() async -> ActionRegistry {
    let r = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await r.register(Action(name: "db_run_query", description: "run a query",
                            kind: .read, schema: .object(["type": .string("object")])) { p in p })
    return r
}

/// The pair `handle` and `MCPSocketServer` answer from: that registry, plus
/// a pane store. Defaulted to a fresh, empty one, since only the `read_pane`
/// tests below care what is in it. `layout` is likewise defaulted to a fresh
/// store — only the `read_layout` tests below care what is in it.
private func surface(panes: PaneStore = PaneStore(), layout: LayoutStore = LayoutStore()) async -> MCPSurface {
    MCPSurface(registry: await reg(), panes: panes, layout: layout, confirmations: ConfirmationBroker())
}

@Test func initializeIsAnswered() async throws {
    let m = JSONRPCMessage(id: .number(1), method: "initialize", params: .object([:]), result: nil, error: nil)
    let out = await handle(m, surface: await surface(), caller: { .test("staging") })
    #expect(out?.id == .number(1))
    #expect(out?.error == nil)
}

/// `initialize` names the place every call on this socket is made for, and the place the window
/// shows: what the e2e harness picks its channel by among a window's sockets.
@Test func initializeReportsTheSocketsPlaceAndTheScreens() async throws {
    let m = JSONRPCMessage(id: .number(1), method: "initialize", params: .object([:]), result: nil, error: nil)
    let pinned = Place(organization: "initech", project: "api", environment: "staging")
    let screen = Place(organization: "initech", project: "billing", environment: "qa")
    let out = await handle(
        m, surface: await surface(), caller: { DispatchCaller(place: pinned, session: "s-1") },
        screen: { screen })
    guard case .object(let result)? = out?.result, case .object(let meta)? = result["_meta"] else {
        Issue.record("no _meta: \(String(describing: out?.result))"); return
    }
    #expect(meta["wakil/place"] == .object([
        "organization": .string("initech"), "project": .string("api"), "environment": .string("staging"),
    ]))
    #expect(meta["wakil/screen"] == .object([
        "organization": .string("initech"), "project": .string("billing"), "environment": .string("qa"),
    ]))

    let unknown = await handle(m, surface: await surface(), caller: { .test("staging") })
    guard case .object(let bare)? = unknown?.result, case .object(let bareMeta)? = bare["_meta"] else {
        Issue.record("no _meta without a screen"); return
    }
    #expect(bareMeta["wakil/screen"] == .null, "no screen known: said, not invented")
}

/// Probe §8: the CLI refuses at its first permission check if the name
/// given to `--permission-prompt-tool` is not in this list, and puts that
/// error in front of the agent. So `approve_tool_use`'s presence here is
/// load-bearing, not cosmetic — hiding it to keep it away from the agent
/// was measured and does not work.
@Test func toolsListProjectsTheRegistryPlusBothReadToolsAndTheBridge() async throws {
    let m = JSONRPCMessage(id: .number(2), method: "tools/list", params: nil, result: nil, error: nil)
    let out = await handle(m, surface: await surface(), caller: { .test("staging") })
    guard case .object(let r)? = out?.result, case .array(let tools)? = r["tools"] else {
        Issue.record("no tools array"); return
    }
    let names = tools.compactMap { t -> String? in
        if case .object(let o) = t, case .string(let n)? = o["name"] { return n }; return nil
    }
    #expect(names.sorted() == ["approve_tool_use", "db_run_query", "read_layout", "read_pane"])
}

/// **The kind reaches the wire, or the coverage gate cannot ask what
/// writes** (#256). Outside the process, `tools/list` is the whole of what
/// is knowable about the registry; a list of names says what the app can do
/// and not which of those things change anything, and the gate's parity rule
/// is stated entirely in that difference.
///
/// A `.read` action and a `.control` one are asserted together, because the
/// mistake this pins is not a missing field — it is the tempting reading of
/// `readOnlyHint` under which `.control` counts as read-only because it
/// touches nothing outside Wakil.
@Test func toolsListCarriesEachActionsKindAsReadOnlyHint() async throws {
    let registry = await reg()
    await registry.register(Action(name: "pane_move", description: "move a pane",
                                   kind: .control, schema: .object(["type": .string("object")])) { p in p })
    let surface = MCPSurface(registry: registry, panes: PaneStore(), layout: LayoutStore(),
                             confirmations: ConfirmationBroker())
    let m = JSONRPCMessage(id: .number(2), method: "tools/list", params: nil, result: nil, error: nil)
    let out = await handle(m, surface: surface, caller: { .test("staging") })
    guard case .object(let r)? = out?.result, case .array(let tools)? = r["tools"] else {
        Issue.record("no tools array"); return
    }
    var hints: [String: Bool] = [:]
    for tool in tools {
        guard case .object(let o) = tool, case .string(let name)? = o["name"],
              case .object(let annotations)? = o["annotations"],
              case .bool(let readOnly)? = annotations["readOnlyHint"] else { continue }
        hints[name] = readOnly
    }
    #expect(hints["db_run_query"] == true)
    #expect(hints["pane_move"] == false)
    // The hand-written tools carry it too: a consumer that has to ask
    // whether the key is present before trusting it is back to guessing.
    #expect(hints["read_pane"] == true)
    #expect(hints["read_layout"] == true)
    #expect(hints["approve_tool_use"] == true)
}

@Test func toolsCallDispatchesThroughTheRegistry() async throws {
    let m = JSONRPCMessage(id: .number(3), method: "tools/call",
                           params: .object(["name": .string("db_run_query"),
                                            "arguments": .object(["sql": .string("select 1")])]),
                           result: nil, error: nil)
    let out = await handle(m, surface: await surface(), caller: { .test("staging") })
    #expect(out?.error == nil)
}

@Test func socketDispatchJournalsTheAgentCaller() async throws {
    let surface = await surface()
    let m = JSONRPCMessage(id: .number(3), method: "tools/call",
                           params: .object(["name": .string("db_run_query"),
                                            "arguments": .object([:])]),
                           result: nil, error: nil)
    let place = Place(organization: "initech", project: "api", environment: "staging")
    let out = await handle(m, surface: surface,
                           caller: { DispatchCaller(place: place, session: "s-2") })
    #expect(out?.error == nil)
    let entry = try #require(try await surface.registry.journalEntries().last)
    #expect(entry.origin == .agent)
    #expect(entry.session == "s-2")
    #expect(entry.organization == "initech")
}

@Test func anUnknownToolIsAnErrorNotACrash() async throws {
    let m = JSONRPCMessage(id: .number(4), method: "tools/call",
                           params: .object(["name": .string("nope"), "arguments": .object([:])]),
                           result: nil, error: nil)
    let out = await handle(m, surface: await surface(), caller: { .test("staging") })
    #expect(out?.error != nil)
}

@Test func aNotificationGetsNoReply() async throws {
    let m = JSONRPCMessage(id: nil, method: "notifications/initialized", params: nil, result: nil, error: nil)
    #expect(await handle(m, surface: await surface(), caller: { .test("staging") }) == nil)
}

// MARK: - read_pane
//
// The one hand-written tool (design §2.3), and the whole of Invariant 3's
// "the agent can read any pane's state". These four tests cover the shapes
// `handle` can answer with; `ShimTests.theShimCarriesJSONRPCBetweenStdioAnd
// TheSocket` covers the same tool over the real socket and a real shim
// subprocess, which is the form an agent actually reaches it in.

private func readPane(
    _ arguments: JSONValue, panes: PaneStore, layout: LayoutStore = LayoutStore()
) async -> JSONRPCMessage? {
    let m = JSONRPCMessage(
        id: .number(9), method: "tools/call",
        params: .object(["name": .string("read_pane"), "arguments": arguments]),
        result: nil, error: nil)
    return await handle(m, surface: await surface(panes: panes, layout: layout), caller: { .test("staging") })
}

@Test func readPaneAnswersFromThePaneStore() async throws {
    let panes = PaneStore()
    let layout = LayoutStore()
    let opened = await layout.open(kind: "db", title: "customers")
    await panes.setRows(
        paneId: opened.id, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(7)]], millis: 3, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    let out = await readPane(.object(["paneId": .string(opened.id)]), panes: panes, layout: layout)
    #expect(out?.error == nil)

    let expected = await panes.readPane(paneId: opened.id, kind: "db")
    guard case .object(let result)? = out?.result else {
        Issue.record("read_pane result is not an object: \(String(describing: out?.result))")
        return
    }
    // `structuredContent` is the snapshot verbatim — not a re-shaped copy —
    // so the tool and `WindowModel.refreshPanes` provably serve the same
    // object for the same pane id.
    #expect(result["structuredContent"] == expected)
    guard case .array(let content)? = result["content"], case .object(let block)? = content.first,
        case .string(let text)? = block["text"]
    else {
        Issue.record("read_pane result has no text content block: \(result)")
        return
    }
    #expect(block["type"] == .string("text"))
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == expected)
}

@Test func readPaneOnAPaneNothingHasWrittenIsAnEmptySnapshotNotAnError() async throws {
    // A pane the layout knows about but nothing has written to yet is a
    // pane with nothing in it, which is exactly what the window draws for
    // the same id ("no rows") before its first query. `kind` still comes
    // back "db" here because the layout, not the write, is what supplies
    // the discriminator now (Task 4) — this is the freshly-opened-window
    // case the unknown-pane doc comment on `readPane` argues from, not the
    // "no pane on the canvas at all" case (see
    // `readPaneOnAnIdTheCanvasDoesNotHoldAnswersKindNullRatherThanErroring`
    // for that one).
    let layout = LayoutStore()
    let opened = await layout.open(kind: "db", title: "customers")
    let out = await readPane(.object(["paneId": .string(opened.id)]), panes: PaneStore(kinds: PaneKinds.standard), layout: layout)
    #expect(out?.error == nil)
    guard case .object(let result)? = out?.result else {
        Issue.record("read_pane result is not an object: \(String(describing: out?.result))")
        return
    }
    #expect(result["structuredContent"] == .object([
        "kind": .string("db"),
        "columns": .array([]), "columnTypes": .array([]), "columnTypesInferred": .bool(false),
        "rows": .array([]), "rowCount": .number(0), "millis": .number(0), "truncated": .bool(false),
        "pageable": .bool(false), "offset": .number(0),
        "selection": .object([
            "anchorRow": .null, "anchorColumn": .null, "rows": .array([]),
        ]),
        "sort": .array([]), "scrollTarget": .null, "failure": .null,
        "listsTables": .bool(false), "running": .bool(false), "cancelledAfterMs": .null,
    ]))
}

// D5: every other terminal/pane action spells its target `pane`; `read_pane`
// alone spelled it `paneId`, so an agent that had learned `pane` from the
// other nine tools got `-32602` from this one. Both spellings now resolve
// the same pane.
@Test func readPaneAcceptsPaneAsAnAliasForPaneId() async throws {
    let panes = PaneStore()
    let layout = LayoutStore()
    let opened = await layout.open(kind: "db", title: "customers")
    await panes.setRows(
        paneId: opened.id, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(7)]], millis: 3, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    let viaPaneId = await readPane(.object(["paneId": .string(opened.id)]), panes: panes, layout: layout)
    let viaPane = await readPane(.object(["pane": .string(opened.id)]), panes: panes, layout: layout)

    #expect(viaPaneId?.error == nil)
    #expect(viaPane?.error == nil)
    guard case .object(let a)? = viaPaneId?.result, case .object(let b)? = viaPane?.result else {
        Issue.record("read_pane result is not an object")
        return
    }
    #expect(a["structuredContent"] == b["structuredContent"])
}

@Test func readPaneWithoutAUsablePaneIdIsInvalidParams() async throws {
    for arguments in [JSONValue.object([:]), .object(["paneId": .number(1)]), .array([])] {
        let out = await readPane(arguments, panes: PaneStore())
        #expect(out?.result == nil)
        #expect(out?.error?.code == -32602, "\(arguments)")
    }
}

@Test func readPaneIsNotADispatchAndIsNotJournalled() async throws {
    // read_pane deliberately bypasses `ActionRegistry.dispatch` (design
    // §2.3: it is hand-written, not a projected action), so it reaches
    // neither the write gate nor the journal. That is correct — it changes
    // nothing, and Invariant 2's journal records actions, not reads — but it
    // is worth pinning: if `read_pane` ever became a registered action, this
    // is the assertion that would notice.
    let registry = await reg()
    let panes = PaneStore()
    await panes.setRows(
        paneId: "db", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(7)]], millis: 3, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    let m = JSONRPCMessage(
        id: .number(9), method: "tools/call",
        params: .object(["name": .string("read_pane"), "arguments": .object(["paneId": .string("db")])]),
        result: nil, error: nil)
    let out = await handle(
        m,
        surface: MCPSurface(registry: registry, panes: panes, layout: LayoutStore(), confirmations: ConfirmationBroker()),
        caller: { .test("production") })
    // Answered even in `production`: reading a pane is not a mutation, so
    // there is nothing for the gate to refuse.
    #expect(out?.error == nil)
    #expect(try await registry.journalEntries().isEmpty)
}

@Test func readPaneAdvertisesEverythingItReturns() async throws {
    let m = JSONRPCMessage(id: .number(20), method: "tools/list", params: nil, result: nil, error: nil)
    let out = await handle(m, surface: await surface(), caller: { .test("staging") })
    guard case .object(let r)? = out?.result, case .array(let tools)? = r["tools"] else {
        Issue.record("no tools array"); return
    }
    guard let entry = tools.first(where: {
        if case .object(let o) = $0, case .string("read_pane")? = o["name"] { return true }
        return false
    }), case .object(let o) = entry, case .string(let description)? = o["description"] else {
        Issue.record("read_pane is not in tools/list")
        return
    }
    // Top-level keys only, and derived from a live snapshot rather than
    // hand-typed, so a key a future task adds to `PaneStore.snapshot` and
    // forgets to describe fails this test automatically. Deliberately not
    // recursed into `selection` or `sort`: their nested fields
    // (`anchorRow`, `anchorColumn`, `direction`) are described in prose
    // ("anchor cell") rather than named verbatim, and a description that
    // does that well should not fail here.
    //
    // `kind: "db"` rather than `nil` — a grid snapshot's fifteen keys
    // (fourteen tabular fields plus `kind` itself), not the two-key `.none`
    // shape an unknown pane id would give. `nil` here would make every key
    // this loop can ever check "kind" and "failure", and a future grid
    // field added to `PaneStore.snapshot` and never described would ship
    // silently — exactly the regression this test's own name and comment
    // promise cannot happen. `kind` answering `null` for an unknown id,
    // rather than being silently absent, is `PaneStoreTests.swift`'s
    // `anUnknownPaneIdAnswersWithANullKindRatherThanAnError` to prove, not
    // this test's.
    //
    // **Every registered kind, not only `db`** (#188). The api arm's three
    // regions are nested, and a nested key is exactly the kind a
    // description forgets — so the loop below recurses one level into
    // `request` and `response`, which is where `origin`, `state` and the
    // four region names live. The db arm's own nested objects
    // (`selection`, `sort`) are still not recursed into: their fields are
    // described in prose rather than named verbatim, and that is a
    // deliberate difference rather than an inconsistency, because those
    // are fields of a ROW and these are regions of the pane.
    var keys: Set<String> = []
    for kind in Pane.kinds.sorted() {
        guard case .object(let snapshot) = await PaneStore(kinds: PaneKinds.standard)
            .readPane(paneId: "anything", kind: kind) else {
            Issue.record("PaneStore.snapshot did not return an object for kind \(kind)")
            return
        }
        keys.formUnion(snapshot.keys)
        if kind == "api" {
            for region in ["request", "response"] {
                guard case .object(let nested)? = snapshot[region] else {
                    Issue.record("the api arm has no \(region) object"); return
                }
                keys.formUnion(nested.keys)
            }
        }
    }
    let snapshot = keys
    // Matched as whole words, not bare substrings: `description.contains
    //("sort")` would pass on the word "sorted" whether or not the key
    // `sort` is ever named, and `contains("rows")` would pass on
    // "rowCount". An underscore stays inside a word, so the editor's snake_case keys can match. Splitting into a word set still tolerates ordinary
    // prose edits, punctuation and reordering.
    let words = Set(description.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init))
    for key in snapshot.sorted() {
        #expect(words.contains(key), "read_pane does not mention \(key)")
    }
    // The git pane's roots are the project's declared roots, a folder that is not a
    // repository among them — nothing is discovered (final review, item 5).
    #expect(!description.contains("repositories discovered"))
    #expect(description.contains("the active project's declared roots"))
}

// MARK: - Socket-layer coverage
//
// Everything above exercises `handle()` in isolation — pure, no socket
// involved. That is deliberate (see `handle`'s doc comment), but it means
// none of those five tests can reach a failure mode that only exists once a
// real socket is in the loop: a client that writes a request and vanishes
// before reading the reply. Two real bugs were found in that path during
// review (a `Connection` lifetime bug, since fixed by a strong self-capture;
// and the SIGPIPE crash this test targets, since fixed by
// `ignoreSIGPIPEProcessWide`/`disableSIGPIPE`), and pure-`handle()` tests
// caught neither. This test spawns a real `MCPSocketServer` to close that
// gap.

/// Connects a raw client socket to `path` via the same `sockaddr_un`
/// construction `MCPSocketServer` and `runShim` both use, without going
/// through either of them — this test needs a client it can close on
/// command, not a full shim round trip.
private func connectRawClient(to path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw MCPTransportError.posixFailure(call: "socket", path: path, errnoValue: errno)
    }
    var (addr, len) = try makeUnixSocketAddress(path: path)
    let rc = withUnsafePointer(to: &addr) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard rc == 0 else {
        let failedErrno = errno
        close(fd)
        throw MCPTransportError.posixFailure(call: "connect", path: path, errnoValue: failedErrno)
    }
    return fd
}

private func sendFrame(_ fd: Int32, _ json: String) {
    var data = Data(json.utf8)
    data.append(UInt8(ascii: "\n"))
    data.withUnsafeBytes { raw in
        _ = write(fd, raw.baseAddress, raw.count)
    }
}

/// Reads whatever is available on `fd`, bounded by `SO_RCVTIMEO`. Without
/// this, a regression that made the server stop replying would hang this
/// test (and, under `swift test`, the rest of the suite behind it) instead
/// of failing it — the whole point of "give it a bounded deadline" is that a
/// regression here must show up as a normal test failure, not a stuck CI run.
private func readWithTimeout(_ fd: Int32, seconds: Int) throws -> String {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buffer, buffer.count)
    guard n > 0 else {
        throw MCPTransportError.posixFailure(call: "read", path: "(test client, possible timeout)", errnoValue: errno)
    }
    return String(decoding: buffer[0..<n], as: UTF8.self)
}

@Test func earlyClientDisconnectDoesNotKillTheServerOrOtherConnections() async throws {
    // Deliberately /tmp rather than FileManager's per-user temporary
    // directory: on this machine that resolves to a /var/folders/... path
    // long enough to overflow sockaddr_un's 104-byte sun_path, which
    // `makeUnixSocketAddress` rejects outright rather than truncating.
    let socketPath = "/tmp/wakil-mcpserver-test-\(UUID().uuidString).sock"
    let server = MCPSocketServer(surface: await surface(), socketPath: socketPath, caller: { .test("staging") })
    try await server.start()

    do {
    // First client: send a request, then close immediately, before ever
    // reading a reply. `Connection.ingest` still attempts the write once it
    // decodes and handles that request — writing into an already-vanished
    // peer's socket is exactly the SIGPIPE trigger this test targets.
    let firstFD = try connectRawClient(to: socketPath)
    sendFrame(firstFD, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    close(firstFD)

    // Give the server a moment to read that request and attempt (and, before
    // the SIGPIPE fix, die attempting) the reply write it triggers.
    try await Task.sleep(nanoseconds: 300_000_000)

    // Second client, on a fresh connection: if the process above died, or
    // the accept loop stopped, this either fails to connect or the read
    // below times out instead of returning a reply.
    let secondFD = try connectRawClient(to: socketPath)
    defer { close(secondFD) }
    sendFrame(secondFD, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#)
    let reply = try readWithTimeout(secondFD, seconds: 5)
    #expect(reply.contains("\"id\":2"))
    #expect(reply.contains("\"wakil\""))

    // Awaited here rather than fired off from a `defer { Task { … } }`. That
    // shape does not tear the server down so much as hope to: the test body
    // can (and measured on this machine, roughly once in seven executions,
    // does) finish before the detached `Task` ever runs, leaving the unix
    // socket file behind under /tmp and — worse than the litter — a listening
    // fd and a blocked `accept()` thread alive for the remainder of the
    // suite. There is no early `return` here, but three calls above can
    // throw — both `connectRawClient`s and, most relevantly, the
    // `readWithTimeout` whose 5-second expiry is the very failure this test
    // exists to detect. The `catch` covers those exits, which is the one
    // thing the `defer` did buy; without it a failing run would leak the
    // listener deterministically rather than one time in seven.
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

// MARK: - one connection's frames are answered in order and in full

/// Reads newline-delimited frames off `fd` until `count` of them have
/// arrived or the bounded `SO_RCVTIMEO` deadline passes with nothing more
/// coming. Returns however many it got: a regression that makes the server
/// stop replying must show up as a short list this test can assert on, not
/// as a stuck suite.
private func readFrames(_ fd: Int32, count: Int, seconds: Int) -> [String] {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var accumulated = Data()
    var frames: [String] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while frames.count < count {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        accumulated.append(contentsOf: buffer[0..<n])
        while let i = accumulated.firstIndex(of: UInt8(ascii: "\n")) {
            frames.append(String(decoding: accumulated[accumulated.startIndex..<i], as: UTF8.self))
            accumulated.removeSubrange(accumulated.startIndex...i)
        }
    }
    return frames
}

/// Regression test for the same cross-cutting bug at `Connection`: each chunk
/// the connection's read thread produced used to get its own unstructured
/// `Task { await self.ingest(data) }`. That gave two guarantees the code's
/// comment claimed but did not have.
///
/// The requests here are padded to 60 KB precisely so that one frame always
/// spans several `availableData` reads — `earlyClientDisconnectDoesNotKillThe
/// ServerOrOtherConnections` above sends a single short frame, which arrives
/// in one chunk and so cannot expose either failure.
///
/// Both failures were measured on this machine before the fix, over eight runs
/// of this test body — 4 or 5 of every 5 connections failed in every one of
/// them:
///
/// 1. replies came back out of request order — `1, 2, 4, 3, 5, …` — because
///    `ingest` is `async` and suspends at `caller()`/`handle()`,
///    so a later chunk's `Task` could decode and answer its request while an
///    earlier one was parked mid-await;
/// 2. connections went silent partway through — 0, 2, 4, 18, 19 and 26
///    replies of the 40 expected, across those runs — because two chunks of
///    one frame reached `FrameReader.push` inverted, spliced into JSON that
///    could not decode, and latched the reader dead for the rest of the
///    connection (`FrameReader`'s contract: the error is permanent).
///
/// Asserting the exact ordered id list catches both. After the fix (a serial
/// `AsyncStream` drained by one consumer that awaits each `ingest` before
/// taking the next chunk), 0 of 5 on every run of eight.
@Test(.timeLimit(.minutes(2)))
func manyLargeFramesOnOneConnectionAreAnsweredInOrderAndInFull() async throws {
    let requests = 40
    let pad = String(repeating: "x", count: 60_000)
    var failures = 0
    let iterations = 5
    for _ in 0..<iterations {
        // /tmp rather than FileManager's temporary directory, for the
        // sun_path length reason the test above documents.
        let socketPath = "/tmp/wakil-mcpserver-order-\(UUID().uuidString).sock"
        let server = MCPSocketServer(surface: await surface(), socketPath: socketPath, caller: { .test("staging") })
        try await server.start()
        let fd = try connectRawClient(to: socketPath)
        for id in 1...requests {
            sendFrame(fd, #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"pad":"\#(pad)"}}"#)
        }
        let frames = readFrames(fd, count: requests, seconds: 5)
        close(fd)
        await server.stop()

        // Decoded rather than scanned for the first `"id":`. That scan was
        // correct only by accident: `JSONRPCMessage.encode` writes into a
        // keyed container, and `JSONEncoder` guarantees no ordering for those
        // keys — it randomises per process — so "first occurrence" is this
        // reply's own id only for as long as no result object ever carries a
        // nested `"id"` of its own. `initialize`'s result does not; the day a
        // `tools/call` result echoes one, the scan would quietly read the
        // wrong number and report it as an ordering failure, a false positive
        // in the exact test whose job is to detect reordering.
        let ids = frames.compactMap { frame -> Int? in
            guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: Data(frame.utf8)),
                  case .number(let id)? = message.id else { return nil }
            return id
        }
        if ids != Array(1...requests) { failures += 1 }
    }
    #expect(failures == 0, "\(failures) of \(iterations) connections answered out of order or stopped answering")
}

@Test func readLayoutReportsPanesFramesFocusAndSnaps() async throws {
    let directory = testScratchRoot
        .appendingPathComponent("read-layout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    let layout = LayoutStore()
    let surface = MCPSurface(registry: registry, panes: PaneStore(), layout: layout, confirmations: ConfirmationBroker())

    let a = await layout.open(kind: "db", title: "A")
    let b = await layout.open(kind: "db", title: "B")
    try await layout.snap(id: b.id, to: a.id, edge: .left)

    let reply = await handle(
        JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object(["name": .string("read_layout"), "arguments": .object([:])])),
        surface: surface, caller: { .test("staging") })

    guard case .object(let result)? = reply?.result,
          case .object(let structured)? = result["structuredContent"],
          case .array(let panes)? = structured["panes"]
    else {
        Issue.record("read_layout returned \(String(describing: reply?.result))")
        return
    }
    #expect(panes.count == 2)
    #expect(structured["focusedId"] == .string(b.id))
    #expect(structured["maximizedId"] == .null)
    guard case .array(let links)? = structured["snaps"] else {
        Issue.record("no snaps array")
        return
    }
    #expect(links.count == 1)
}

@Test func readLayoutIsAdvertisedAndJournalsNothing() async throws {
    let directory = testScratchRoot
        .appendingPathComponent("read-layout-list-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    let surface = MCPSurface(registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: ConfirmationBroker())

    let listed = await handle(
        JSONRPCMessage(id: .number(1), method: "tools/list", params: nil),
        surface: surface, caller: { .test("staging") })
    guard case .object(let result)? = listed?.result, case .array(let tools)? = result["tools"] else {
        Issue.record("tools/list returned no tools")
        return
    }
    let names = tools.compactMap { tool -> String? in
        guard case .object(let object) = tool, case .string(let name)? = object["name"] else { return nil }
        return name
    }
    #expect(names.contains("read_layout"))
    #expect(names.contains("read_pane"))

    _ = await handle(
        JSONRPCMessage(
            id: .number(2), method: "tools/call",
            params: .object(["name": .string("read_layout"), "arguments": .object([:])])),
        surface: surface, caller: { .test("staging") })
    // Hand-written like read_pane: a pure read of UI state, so it reaches
    // neither the gate nor the journal.
    #expect(try await registry.journalEntries().isEmpty)
}

@Test func readLayoutOnAnEmptyCanvasIsAnEmptyAnswerNotAnError() async {
    let directory = testScratchRoot
        .appendingPathComponent("read-layout-empty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let surface = MCPSurface(
        registry: ActionRegistry(journalDirectory: directory, sessionId: "s"),
        panes: PaneStore(), layout: LayoutStore(), confirmations: ConfirmationBroker())

    let reply = await handle(
        JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object(["name": .string("read_layout"), "arguments": .object([:])])),
        surface: surface, caller: { .test("staging") })

    #expect(reply?.error == nil)
    guard case .object(let result)? = reply?.result,
          case .object(let structured)? = result["structuredContent"]
    else {
        Issue.record("no structuredContent")
        return
    }
    #expect(structured["panes"] == .array([]))
    #expect(structured["focusedId"] == .null)
}

// MARK: - Dual-drive: an agent's `tools/call` actually moves `LayoutStore`
//
// Every other layout test above either drives `LayoutStore` directly or
// proves `read_layout`'s projection. Nothing before this point sends a
// `pane_*` action through `handle` the way a real agent's `tools/call`
// does and then checks the store moved — the identity check in
// `AppWiringTests` and a runbook row are what stood in for it. This is
// that missing link, headless: `registerLayoutActions` wires the same
// eight actions `WindowModel` dispatches from the UI, `handle` reaches
// them with `origin: .agent` (never `.ui`) exactly as it does for a real
// MCP client, and the assertion reads `LayoutStore` — not the tool's
// reply — so it fails if dispatch ever stops actually reaching the store.

@Test func agentToolsCallMovesLayoutStoreNotJustTheReply() async throws {
    let directory = testScratchRoot
        .appendingPathComponent("agent-layout-dispatch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let surface = MCPSurface(registry: registry, panes: PaneStore(), layout: layout, confirmations: ConfirmationBroker())

    let pane = await layout.open(kind: "db", title: "A")
    let before = try #require(await layout.snapshot().panes.first { $0.id == pane.id })

    let reply = await handle(
        JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object([
                "name": .string("pane_move"),
                "arguments": .object([
                    "id": .string(pane.id), "x": .number(321), "y": .number(654),
                ]),
            ])),
        surface: surface, caller: { .test("staging") })

    #expect(reply?.error == nil)
    let after = try #require(await layout.snapshot().panes.first { $0.id == pane.id })
    #expect(after.frame.x == 321)
    #expect(after.frame.y == 654)
    #expect(after.frame != before.frame)
}

// An agent that opens a pane must be able to read back the id it was
// given. `pane_open`'s description promises "Returns the new pane's id"
// and its handler returns `{"id": "db-1"}` faithfully — but until
// `toolResultEnvelope` existed, `handleToolsCall` put that bare payload
// straight into the JSON-RPC `result`, with no `content` key. That is not
// a `CallToolResult`, so a conforming client renders it as "completed with
// no output" and the id never reaches the agent. One that opened three
// panes and could read none of their ids invented three from the titles it
// had chosen, and every query it then ran wrote rows under keys no pane
// held: three panes reading "no rows" beside three tool results showing the
// rows plainly.
//
// This asserts the envelope AND that the id survives inside it, because
// either half alone would have passed while the defect was live.
@Test func anActionsReturnValueReachesTheAgentInAToolResultEnvelope() async throws {
    let directory = testScratchRoot
        .appendingPathComponent("tool-result-envelope-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: layout,
        confirmations: ConfirmationBroker())

    let reply = await handle(
        JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object([
                "name": .string("pane_open"),
                "arguments": .object(["kind": .string("db"), "title": .string("Customers")]),
            ])),
        surface: surface, caller: { .test("staging") })

    #expect(reply?.error == nil)
    let minted = try #require(await layout.snapshot().panes.first?.id)
    guard case .object(let result)? = reply?.result else {
        Issue.record("pane_open did not return an object result")
        return
    }

    // `content` is the half a conforming client is guaranteed to read, and
    // the half whose absence produced "completed with no output".
    guard case .array(let content)? = result["content"],
          case .object(let block)? = content.first,
          case .string(let text)? = block["text"] else {
        Issue.record("pane_open's result carried no text content block: \(result)")
        return
    }
    #expect(block["type"] == .string("text"))
    #expect(text.contains(minted), "the minted id \"\(minted)\" is not in \"\(text)\"")
    #expect(result["structuredContent"] == .object(["id": .string(minted)]))
}

// MARK: - Parked confirmations

// The agent proposes a mutation, the gate refuses it, it parks, a human
// approves, and the SAME call runs. Read `handle`'s reply and the journal
// together: the journal must carry the gated → ok pair of spec §7, which is
// what makes "proposed, refused, then confirmed" recoverable after the
// fact without any new journal field.
// Finding 3 of the final review: `handleToolsCall` does no schema
// validation before reaching `parkForConfirmation`, so
// `{"name":"db_run_mutation","arguments":{}}` — a shape any socket client
// can send — used to park a proposal with an empty statement: a red plane
// asking a human to confirm nothing, holding the single-flight broker for
// up to 120s. `parkForConfirmation`'s `guard !statement.isEmpty` refuses
// this before the broker is ever touched. Mirrors
// `WindowModelTests.selectingAMutationFromCommandKWithNoArgumentsDoesNotPark`,
// the identical guard on the `.ui` side of the one confirmation mechanism.
@Test func aBlankStatementFromTheAgentIsRefusedRatherThanParked() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }
    ))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        confirmations: broker)

    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object(["name": .string("test_mutate"), "arguments": .object([:])]))

    let reply = await handle(call, surface: surface, caller: { .test("staging") })

    #expect(reply?.error?.code == -32602)
    // Never reached the broker at all -- not parked-then-rejected, refused
    // by `parkForConfirmation` before the single-flight slot was ever
    // occupied.
    #expect(await broker.all().isEmpty)
    // `dispatch` itself still ran first and gated the call normally --
    // `writeGate` has no way to know the statement is blank, only
    // `parkForConfirmation` does -- so exactly one "gated" line is
    // journalled and nothing follows it. There is no "ok", no "error", no
    // second "gated": the guard fires strictly after the gate, never
    // instead of it.
    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["gated"])
}

@Test func anAgentProposedMutationParksAndRunsOnceApproved() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    // A hand-registered mutation so this test needs no wakil-db binary.
    await registry.register(Action(
        name: "test_mutate",
        description: "test",
        kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }
    ))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        confirmations: broker)

    let arguments = JSONValue.object(["statement": .string("DELETE FROM t WHERE id=1")])
    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object(["name": .string("test_mutate"), "arguments": arguments]))

    async let reply = handle(call, surface: surface, caller: { .test("staging") })
    while await broker.all().isEmpty { await Task.yield() }
    let parked = await broker.all().values.first
    #expect(parked?.statement == "DELETE FROM t WHERE id=1")
    #expect(parked?.origin == .agent)
    await broker.approve(id: parked!.id)

    let answered = await reply
    #expect(answered?.error == nil)

    let entries = try await registry.journalEntries()
    let mutationEntries = entries.filter { $0.action == "test_mutate" }
    #expect(mutationEntries.map(\.outcome) == ["gated", "ok"])
    // Pins what `parkForConfirmation`'s doc comment claims matters most: the
    // approved re-dispatch carries the operator's original arguments
    // unchanged, not a projection rebuilt from the parked `PendingMutation`.
    // Nothing here would fail if a later edit reconstructed `arguments` from
    // `statement`/`database` instead of passing the original object through
    // — this assertion is what would.
    #expect(mutationEntries.last?.params == arguments)
}

@Test func cancellingAParkedMutationRefusesTheAgent() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: broker)

    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object([
            "name": .string("test_mutate"),
            "arguments": .object(["statement": .string("DELETE FROM t")]),
        ]))

    async let reply = handle(call, surface: surface, caller: { .test("staging") })
    while await broker.all().isEmpty { await Task.yield() }
    await broker.cancel(id: (await broker.all().values.first)!.id)

    #expect(await reply?.error?.code == -32002)

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["gated"])
}

// R1: an agent's proposal does not expire. Under a broker whose timeout has long passed it is
// still parked, in the caller's place, until the operator cancels it — and a cancel is the
// refusal code, not the old expiry one.
@Test func anAgentsParkedProposalWaitsInItsPlaceUntilAnswered() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .milliseconds(50))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: broker)

    async let reply = handle(
        JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object([
                "name": .string("test_mutate"),
                "arguments": .object(["statement": .string("DELETE FROM t")]),
            ])),
        surface: surface, caller: { .test("staging") })
    while await broker.all().isEmpty { await Task.yield() }
    try await Task.sleep(for: .milliseconds(200))
    let parked = await broker.current(for: DispatchCaller.test("staging").place)
    #expect(parked != nil)
    await broker.cancel(id: parked!.id)

    #expect(await reply?.error?.code == -32002)
}

// Production is blocked, not parked. Nothing reaches the broker, because
// there is no confirmation that could make it run.
@Test func aProductionMutationIsBlockedAndNeverParks() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: broker)

    let reply = await handle(
        JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object([
                "name": .string("test_mutate"),
                "arguments": .object(["statement": .string("DELETE FROM t")]),
            ])),
        surface: surface, caller: { .test("production") })

    #expect(reply?.error?.code == -32003)
    #expect(await broker.all().isEmpty)
}

// `writeGate` gates more than mutations: a `.control` action from the
// agent targeting production also returns `.gate` (WriteGate.swift's
// `.control`/`.agent`/production row — `ctx_set_environment("production")`
// in the shipped action set). That proposal has no SQL statement, so
// `parkForConfirmation` must still hand the surface something a human can
// read rather than a blank `statement`.
@Test func aGatedControlActionParksWithADescriptionNotABlankStatement() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    // A hand-registered .control action with a targetEnvironmentParam, so
    // this test needs no wakil-ctx binary.
    await registry.register(Action(
        name: "test_set_environment",
        description: "test",
        kind: .control,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) },
        targetEnvironmentParam: "name"
    ))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        confirmations: broker)

    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object([
            "name": .string("test_set_environment"),
            "arguments": .object(["name": .string("production")]),
        ]))

    async let reply = handle(call, surface: surface, caller: { .test("staging") })
    while await broker.all().isEmpty { await Task.yield() }
    let parked = await broker.all().values.first
    #expect(parked?.statement.isEmpty == false)
    #expect(parked?.statement.contains("test_set_environment") == true)
    #expect(parked?.statement.contains("production") == true)
    #expect(parked?.affectsEveryRow == false)
    #expect(parked?.origin == .agent)
    await broker.approve(id: parked!.id)

    let answered = await reply
    #expect(answered?.error == nil)

    let entries = try await registry.journalEntries()
    let outcomes = entries.filter { $0.action == "test_set_environment" }.map(\.outcome)
    #expect(outcomes == ["gated", "ok"])
}

/// D10's actual action name, not a stand-in: `parkForConfirmation` must
/// prefer `confirmationDescription`'s human sentence — "switch the active
/// environment to staging" — over `describeProposal`'s machine-shaped
/// `name {"json":"args"}` fallback, because an operator asked to approve a
/// change to the one piece of state that decides whether a mutation is
/// frightening should read a sentence, not parse an argument dump. This is
/// what would go RED if `parkForConfirmation` used `describeProposal`
/// alone: that fallback would still produce a non-empty statement (the
/// action name plus its JSON arguments), so a bare "parks with something
/// non-blank" test cannot tell the two apart — only asserting the exact
/// wording can.
@Test func aGatedEnvironmentSwitchParksWithTheHumanSentenceNotTheJSONForm() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    // Hand-registered under the real name `confirmationDescription`
    // switches on, so this test needs no `wakil-ctx` binary but still
    // exercises the exact string match that function performs.
    await registry.register(Action(
        name: "ctx_set_environment",
        description: "test",
        kind: .control,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) },
        targetEnvironmentParam: "name"
    ))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        confirmations: broker)

    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object([
            "name": .string("ctx_set_environment"),
            "arguments": .object(["name": .string("staging")]),
        ]))

    // Active environment "production", target "staging" — D10's leaving
    // direction.
    async let reply = handle(call, surface: surface, caller: { .test("production") })
    while await broker.all().isEmpty { await Task.yield() }
    let parked = await broker.all().values.first
    #expect(parked?.statement == "switch the active environment to staging")
    #expect(parked?.affectsEveryRow == false)
    await broker.approve(id: parked!.id)

    let answered = await reply
    #expect(answered?.error == nil)
}

/// A mutable string an `environment` closure can read fresh each call, so a
/// test can change the active environment mid-park the way an operator
/// switching contexts in the real window would. `actor`-isolated purely for
/// `Sendable` safety across the `async let reply` below.
private actor EnvironmentBox {
    private var value: String
    init(_ value: String) { self.value = value }
    func set(_ value: String) { self.value = value }
    func current() -> String { value }
}

// Finding 2 of the final review: `Connection.consume` reads its
// `caller` once per `handle` call, but `parkForConfirmation`'s
// park is up to 120 seconds long — long enough for an operator to switch
// the active context to production while a staging proposal sits on the
// plane. If the re-dispatch judged a captured pre-park string, it would
// gate against "staging" forever and run the write the gate exists to stop
// the moment someone is looking at production. `parkForConfirmation` reads
// `environment` afresh after the park (`await environment()` at its own
// re-dispatch, not a value threaded through from before); this test is what
// would fail if a later edit captured it instead.
@Test func parkedMutationJudgesTheEnvironmentAtConfirmationNotAtProposalTime() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }
    ))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        confirmations: broker)
    let env = EnvironmentBox("staging")

    let arguments = JSONValue.object(["statement": .string("DELETE FROM t WHERE id=1")])
    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object(["name": .string("test_mutate"), "arguments": arguments]))

    async let reply = handle(call, surface: surface, caller: { .test(await env.current()) })
    while await broker.all().isEmpty { await Task.yield() }
    let parked = await broker.all().values.first
    #expect(parked?.statement == "DELETE FROM t WHERE id=1")

    // The operator switches to production WHILE the plane is parked, then
    // confirms the proposal that was made against staging.
    await env.set("production")
    await broker.approve(id: parked!.id)

    let answered = await reply
    // Blocked, not run: a stale "staging" reading would have journalled
    // "ok" here and let a production write through the gate that promises
    // to stop it outright.
    #expect(answered?.error?.code == -32003)

    let entries = try await registry.journalEntries()
    let outcomes = entries.filter { $0.action == "test_mutate" }.map(\.outcome)
    #expect(outcomes == ["gated", "blocked"])
}

/// The socket reads the caller afresh after a park, and what it reads is the agent's own
/// place. The screen moving to production while the call is parked changes nothing the
/// agent's call is judged against. `caller` is the one the window started the agent's own
/// socket with (`agentSocketFactory`, what `WindowSession` builds an `MCPSocketServer` from), so
/// this fails if that reads the screen.
@MainActor
@Test func aParkedAgentMutationIsJudgedInTheAgentsPlace() async throws {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }
    ))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        confirmations: broker)
    let sessions = Sessions()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "initech",
        harnessFactory: { _, _ in RecordingHarness() },
        agentSocketFactory: sessions.socketFactory, quickModelFactory: nil)
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: "api", environment: "staging")
    await model.send("hello")
    #expect(model.agentPlaces.first?.environment == "staging")

    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object([
            "name": .string("test_mutate"),
            "arguments": .object(["statement": .string("DELETE FROM t WHERE id=1")]),
        ]))

    let socket = try #require(sessions.issuedSockets.first)
    async let reply = handle(call, surface: surface, caller: socket.caller)
    while await broker.all().isEmpty { await Task.yield() }
    let parked = await broker.all().values.first

    // The operator moves the screen to production while the call is parked.
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: "api", environment: "production")
    #expect(model.place.environment == "production")
    await broker.approve(id: parked!.id)

    let answered = await reply
    #expect(answered?.error == nil)
    let entries = try await registry.journalEntries()
    let last = try #require(entries.last { $0.action == "test_mutate" })
    #expect(last.outcome == "ok")
    #expect(last.environment == "staging")
}

@Test func readPaneReportsThePanesKindFromTheLayoutRatherThanGuessing() async {
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let panes = PaneStore(kinds: PaneKinds.standard)
    let layout = LayoutStore()
    let opened = await layout.open(kind: "db", title: "customers")
    let surface = MCPSurface(registry: registry, panes: panes, layout: layout,
                             confirmations: ConfirmationBroker())

    let reply = await handle(
        JSONRPCMessage(id: .number(1), method: "tools/call", params: .object([
            "name": .string("read_pane"),
            "arguments": .object(["paneId": .string(opened.id)]),
        ])),
        surface: surface, caller: { .test("staging") })

    guard case .object(let result)? = reply?.result,
          case .object(let structured)? = result["structuredContent"] else {
        Issue.record("no structuredContent")
        return
    }
    #expect(structured["kind"] == .string("db"))
    #expect(structured["rowCount"] == .number(0))
    #expect(structured["failure"] == .null)
}

@Test func readPaneOnAnIdTheCanvasDoesNotHoldAnswersKindNullRatherThanErroring() async {
    // A pane can close between the read_layout that named it and the
    // read_pane that asks. An error there turns a correct sequence of
    // calls into a failure.
    let dir = testScratchRoot
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let surface = MCPSurface(
        registry: ActionRegistry(journalDirectory: dir, sessionId: "t"),
        panes: PaneStore(), layout: LayoutStore(), confirmations: ConfirmationBroker())

    let reply = await handle(
        JSONRPCMessage(id: .number(1), method: "tools/call", params: .object([
            "name": .string("read_pane"),
            "arguments": .object(["paneId": .string("db-404")]),
        ])),
        surface: surface, caller: { .test("staging") })

    guard case .object(let result)? = reply?.result,
          case .object(let structured)? = result["structuredContent"] else {
        Issue.record("no structuredContent")
        return
    }
    #expect(reply?.error == nil)
    #expect(structured["kind"] == .null)
    // Not a grid with nothing in it — nothing at all.
    #expect(structured["rows"] == nil)
}
