import Foundation
import Testing
@testable import WakilKit

/// Shared fixtures for a bound value — moved out of `ApiBindTests.swift` so
/// that `ApiHandBindTests.swift` can build one too, without a second copy
/// (Task 3, the locking rule).

func valueSource(
    name: String, keyValues: [String] = ["99"], generation: Int
) -> ApiValueSource {
    ApiValueSource(
        pane: "p3", table: "bookings", keyColumns: ["id"], keyValues: keyValues,
        column: name, declaredType: "TEXT", generation: generation)
}

/// A live binding whose key values still find a row. Its generation is
/// deliberately NOT the pane's: a live binding does not consult one, so
/// the generation is a clean marker for "was this repointed?".
func liveBinding(name: String, generation: Int = 3) -> ApiBoundValue {
    ApiBoundValue(name: name, binding: .live, source: valueSource(name: name, generation: generation))
}

/// An operator's own header row, built the way `apiHeaderRegion` builds one — editable, value
/// present — for tests that need a header row without going through a full draft (Task 2, the
/// hand bind).
extension ApiHeaderRegionRow {
    static func operatorRow(name: String, value: [ApiPart]) -> ApiHeaderRegionRow {
        ApiHeaderRegionRow(name: name, value: value, provenance: nil, rowClass: .authored)
    }
}

/// A `wakil-http` for W14. `list_apis` answers one entry. `request` and `send` wait: until the
/// calling task is cancelled (`honoursCancel`, which is what `MCPClient` does), or until
/// `release()`, answering 200 (the reply that beats a cancel).
///
/// **`release()` latches** (fix round 1): `park` runs on a `Task` of its own, so a release can
/// land before the call it is meant for has parked. A release that resumed only what was
/// already parked would leak that later continuation, and `await send.value` on an
/// unstructured `Task` ignores cancellation, so `.timeLimit` could not end the hang.
actor StallingHTTP: ToolCaller {
    private let honoursCancel: Bool
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = false
    init(honoursCancel: Bool = true) { self.honoursCancel = honoursCancel }

    func parkedCount() -> Int { parked.count }
    func release() {
        released = true
        parked.forEach { $0.resume() }
        parked = []
    }
    private func park(_ c: CheckedContinuation<Void, Never>) {
        if released { c.resume() } else { parked.append(c) }
    }

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

/// Polls `condition` for up to `seconds` × `testWaitLoadMultiplier`. It runs on the caller's
/// actor, so a `@MainActor` test can poll the window's own state.
func apiEventually(
    _ seconds: Double = 2, isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}
