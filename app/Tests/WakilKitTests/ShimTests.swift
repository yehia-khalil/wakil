import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import WakilKit

@Test func shimModeIsDetectedBeforeAnyUISetup() throws {
    // The built WakilApp binary must run headlessly in shim mode. If it initialised
    // AppKit it would fail or hang with no display session.
    let exe = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/WakilApp")
    try #require(FileManager.default.isExecutableFile(atPath: exe.path), "run `swift build` first")

    let sock = "/tmp/wakil-test-\(UUID().uuidString).sock"     // deliberately absent
    let p = Process()
    p.executableURL = exe
    p.arguments = ["--mcp-shim", "--socket", sock]
    p.standardError = Pipe()
    p.standardOutput = Pipe()
    try p.run()
    p.waitUntilExit()
    // No socket to connect to, so it must exit non-zero promptly rather than hang or open a window.
    #expect(p.terminationStatus != 0)
}

// MARK: - The shim's round trip

/// Reads newline-delimited output from `fd` until `count` lines have arrived
/// or `seconds` elapse.
///
/// `poll` rather than a blocking `read`, and a deadline rather than none,
/// for the reason `MCPServerTests.readWithTimeout` gives: a regression that
/// stopped the shim replying must fail this test, not hang the rest of the
/// suite behind it. `SO_RCVTIMEO` is not available here — that is a socket
/// option and this is a pipe.
private func readLines(_ fd: Int32, count: Int, seconds: Int) -> [String] {
    var text = ""
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while text.split(separator: "\n").count < count, Date() < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 200) > 0 else { continue }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        text += String(decoding: buffer[0..<n], as: UTF8.self)
    }
    return text.split(separator: "\n").map(String.init)
}

/// The whole transport the window's agent path depends on, end to end:
/// a real `MCPSocketServer`, a real `--mcp-shim` subprocess, JSON-RPC in
/// through the shim's stdin and back out through its stdout.
///
/// This is the link nothing else covered. `MCPServerTests` drives the server
/// with a raw client socket and never involves the shim; `ShimTests`'
/// other test only proves the shim exits when there is nothing to connect
/// to. The design's §8 listed "JSON-RPC framing, both client and shim
/// directions" and the plan recorded the shim direction as covered by the
/// operator runbook alone — but the runbook's version of this check also
/// spends a real Claude turn, so a failure here would have been discovered
/// with the most expensive instrument available. Nothing in this test runs
/// the `claude` CLI; the shim does not know or care what is on the other
/// end of its stdio.
@Test func theShimCarriesJSONRPCBetweenStdioAndTheSocket() async throws {
    let exe = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/WakilApp")
    try #require(FileManager.default.isExecutableFile(atPath: exe.path), "run `swift build` first")

    // /tmp, not FileManager's per-user temporary directory, for the reason
    // MCPServerTests documents: that path plus this name overflows
    // sockaddr_un's 104-byte sun_path.
    let socketPath = "/tmp/wakil-shim-\(UUID().uuidString).sock"
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString),
        sessionId: "shim-roundtrip")
    await registry.register(Action(
        name: "test.echo", description: "echo the params back",
        kind: .read, schema: .object(["type": .string("object")])) { $0 })
    // The pane an agent on the far end of this transport must be able to
    // read (Invariant 3). Written here through `PaneStore.setRows` — the
    // same call `db_run_query`'s handler makes — rather than through a
    // dispatch, so this test needs no database and no Go binary.
    let panes = PaneStore()
    let layout = LayoutStore()
    // `read_pane` now reads its discriminator off the layout (Task 4), not
    // a hardcoded kind, so the pane has to be opened there too — not just
    // written to in `panes` — for this end-to-end round trip to answer
    // `kind: "db"` rather than `kind: null`.
    let opened = await layout.open(kind: "db", title: "customers")
    await panes.setRows(
        paneId: opened.id,
        columns: ["id", "email"],
        columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false,
        rows: [[.number(1), .string("ada@example.com")], [.number(2), .null]],
        millis: 0,
        truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    let server = MCPSocketServer(
        surface: MCPSurface(registry: registry, panes: panes, layout: layout, confirmations: ConfirmationBroker()),
        socketPath: socketPath,
        caller: { .test("staging") })
    try await server.start()

    let process = Process()
    process.executableURL = exe
    process.arguments = ["--mcp-shim", "--socket", socketPath]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()

    let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test.echo","arguments":{"hello":"world"}}}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_pane","arguments":{"paneId":"\#(opened.id)"}}}"#,
    ]
    try input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()

    let lines = readLines(output.fileHandleForReading.fileDescriptor, count: 3, seconds: 10)
    process.terminate()
    process.waitUntilExit()
    await server.stop()

    try #require(lines.count == 3, "\(lines)")
    let replies = try lines.map { try JSONDecoder().decode(JSONRPCMessage.self, from: Data($0.utf8)) }
    #expect(replies[0].id == .number(1))
    #expect(replies[0].error == nil)
    #expect(replies[1].id == .number(2))
    // The `CallToolResult` envelope, not the handler's bare payload: an
    // action's return value reaches the agent only if it is wrapped, and a
    // result with no `content` renders as "completed with no output" — the
    // defect that left `pane_open` unable to tell an agent the id it had
    // just minted.
    #expect(replies[1].result == .object([
        "content": .array([.object([
            "type": .string("text"), "text": .string(#"{"hello":"world"}"#),
        ])]),
        "structuredContent": .object(["hello": .string("world")]),
    ]))

    // `read_pane` over the real transport: the columns and the rows — cell
    // types included, `.number` and `.null` among them — arrive on the far
    // side of a socket and a subprocess exactly as `setRows` left them.
    // Asserting this in-process against `handle` would not have covered the
    // shim, the framing or the JSON round trip, which is where a pane
    // snapshot could plausibly lose its shape.
    #expect(replies[2].id == .number(3))
    #expect(replies[2].error == nil)
    let expectedSnapshot = JSONValue.object([
        "kind": .string("db"),
        "columns": .array([.string("id"), .string("email")]),
        "columnTypes": .array([.string("INTEGER"), .string("TEXT")]),
        "columnTypesInferred": .bool(false),
        "rows": .array([
            .array([.number(1), .string("ada@example.com")]),
            .array([.number(2), .null]),
        ]),
        "rowCount": .number(2),
        "millis": .number(0),
        "truncated": .bool(false),
        "pageable": .bool(true),
        "offset": .number(0),
        "selection": .object([
            "anchorRow": .null, "anchorColumn": .null, "rows": .array([]),
        ]),
        "sort": .array([]), "scrollTarget": .null, "failure": .null,
        "listsTables": .bool(false),
        "running": .bool(false), "cancelledAfterMs": .null,
    ])
    guard case .object(let paneResult)? = replies[2].result else {
        Issue.record("read_pane result is not an object: \(String(describing: replies[2].result))")
        return
    }
    #expect(paneResult["structuredContent"] == expectedSnapshot)
    // The text block carries the same snapshot, since that is the only part
    // of a tool result a model that cannot read `structuredContent` sees.
    guard case .array(let content)? = paneResult["content"], case .object(let block)? = content.first,
        case .string(let text)? = block["text"]
    else {
        Issue.record("read_pane result has no text content block: \(paneResult)")
        return
    }
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == expectedSnapshot)

    // The agent reaching an action through the shim is an `origin: .agent`
    // dispatch, journalled like any other — the property Invariant 2 turns
    // on, observed here across two processes rather than asserted of
    // `handle` in isolation.
    let entries = try await registry.journalEntries()
    #expect(entries.map(\.action) == ["test.echo"])
    #expect(entries.map(\.origin) == [.agent])
}
