import Testing
import Foundation
@testable import WakilKit

private actor CapacityCaller: ToolCaller {
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        return .object(["structuredContent": .object(["readings": .array([])])])
    }
    func recorded() -> [(tool: String, arguments: JSONValue)] { calls }
}

private func capacityRegistry() async throws -> (ActionRegistry, CapacityCaller) {
    let caller = CapacityCaller()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "capacity")
    await registerCapacityActions(into: registry, context: caller)
    return (registry, caller)
}

@Test func capacityRecordSendsTheReadingToRecordCapacity() async throws {
    let (registry, caller) = try await capacityRegistry()
    let params: JSONValue = .object(["provider": .string("main"),
        "fiveHour": .object(["percentLeft": .integer(28), "resetsAt": .string("2026-10-10T17:20:00Z")]),
        "asOf": .string("2026-10-10T16:18:00Z")])
    _ = try await registry.dispatch(name: "capacity_record", params: params, origin: .ui,
                                    caller: .test("local"), confirmation: nil)
    let calls = await caller.recorded()
    #expect(calls.map(\.tool) == ["record_capacity"])
    #expect(calls.first?.arguments == params)
}

@Test func ctxCapacityReadsTheCapacityTool() async throws {
    let (registry, caller) = try await capacityRegistry()
    _ = try await registry.dispatch(name: "ctx_capacity", params: .object([:]), origin: .agent,
                                    caller: .test("local"), confirmation: nil)
    #expect(await caller.recorded().map(\.tool) == ["capacity"])
}

@Test func theAgentCannotRecordAReading() {
    #expect(operatorOnlyActions.contains("capacity_record"))
    #expect(!operatorOnlyActions.contains("ctx_capacity"))
}

@Test func agentOriginRefreshIsDropped() async throws {
    let (registry, caller) = try await capacityRegistry()
    let params: JSONValue = .object(["refresh": .bool(true)])
    _ = try await registry.dispatch(name: "ctx_capacity", params: params, origin: .agent,
                                    caller: .test("local"), confirmation: nil)
    _ = try await registry.dispatch(name: "ctx_capacity", params: params, origin: .ui,
                                    caller: .test("local"), confirmation: nil)
    let calls = await caller.recorded()
    #expect(calls.count == 2)
    #expect(calls[0].arguments == .object([:]))
    #expect(calls[1].arguments == .object(["refresh": .bool(true)]))
}
