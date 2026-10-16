import Foundation
import Testing
@testable import WakilKit

/// The second adapter at the `ToolCaller` seam, and the one that makes the
/// seam real rather than hypothetical: the first is `MCPClient` over a
/// subprocess, this one answers from memory. It records every call so a
/// test can assert what reached the wire, which is what the stub server's
/// request log used to be for.
actor RecordingToolCaller: ToolCaller {
    struct Call: Equatable, Sendable {
        let name: String
        let arguments: JSONValue
        let timeout: TimeInterval
    }

    private(set) var calls: [Call] = []
    private let reply: @Sendable (String, JSONValue) throws -> JSONValue

    /// `reply` receives the tool name and arguments, so a test can vary the
    /// result per tool — which the stub script could not do at all.
    init(reply: @escaping @Sendable (String, JSONValue) throws -> JSONValue) {
        self.reply = reply
    }

    /// Answers every tool with the same result.
    init(always result: JSONValue) {
        self.reply = { _, _ in result }
    }

    func callTool(
        name: String, arguments: JSONValue, timeout: TimeInterval
    ) async throws -> JSONValue {
        calls.append(Call(name: name, arguments: arguments, timeout: timeout))
        return try reply(name, arguments)
    }

    /// Drops every recorded call, so a later read reports only what the
    /// dispatch under test sent — not a setup call the test made to get
    /// the harness into position (opening a pane, seeding a fetch).
    func reset() {
        calls.removeAll()
    }
}

@Suite struct ToolCallerTests {
    @Test func theRecordingAdapterReturnsItsCannedResultAndRecordsTheCall() async throws {
        let caller = RecordingToolCaller(always: .object(["ok": .bool(true)]))

        let result = try await caller.callTool(
            name: "query", arguments: .object(["sql": .string("select 1")]), timeout: 10)

        #expect(result == .object(["ok": .bool(true)]))
        let calls = await caller.calls
        #expect(calls == [RecordingToolCaller.Call(
            name: "query", arguments: .object(["sql": .string("select 1")]), timeout: 10)])
    }

    @Test func theReplyClosureCanVaryTheResultPerToolName() async throws {
        let caller = RecordingToolCaller(reply: { name, _ in
            name == "list_tables" ? .array([.string("users")]) : .object([:])
        })

        #expect(try await caller.callTool(
            name: "list_tables", arguments: .object([:]), timeout: 10) == .array([.string("users")]))
        #expect(try await caller.callTool(
            name: "query", arguments: .object([:]), timeout: 10) == .object([:]))
    }

    /// The conformance that makes the seam load-bearing: production's
    /// adapter satisfies the port without a line of adaptation.
    @Test func theLiveClientIsAToolCaller() async throws {
        let client = MCPClient(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        let asPort: any ToolCaller = client
        #expect(asPort is MCPClient)
    }
}
