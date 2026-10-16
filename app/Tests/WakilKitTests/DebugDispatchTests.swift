import Testing
import Foundation
@testable import WakilKit

/// A dispatch that actually *ran* — not merely one that was attempted.
///
/// The line count and `origin: .debug` alone cannot tell those apart: an
/// unknown action name also produces exactly one output line and also
/// journals with `origin: .debug` (outcome `"unknown"`), so this test as
/// the plan wrote it passed with the `register` call deleted. The two
/// assertions that close that hole are the journalled outcome (`"ok"` is
/// written only after the handler returns) and the output line's content —
/// the registered handler is `{ $0 }`, so success means the params come
/// back, where a failure of any kind would be an `{"error": ...}` object.
@Test func debugScriptDispatchesAndJournalsWithDebugOrigin() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(Action(name: "a.b", description: "t", kind: .read, schema: .object([:])) { $0 })
    let out = await runDebugScript([#"{"action":"a.b","params":{"x":1}}"#],
                                   registry: r, environment: "staging")
    #expect(out.count == 1)

    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(out.first).utf8))
    #expect(decoded == .object(["x": .number(1)]), "expected the handler's echoed params, got \(out)")

    let entries = try await r.journalEntries()
    #expect(entries.map(\.origin) == [.debug])
    #expect(entries.map(\.outcome) == ["ok"])
    #expect(entries.map(\.action) == ["a.b"])
}

/// `runDebugScriptReportingFailures` is what `--dispatch` turns into an
/// exit code, so the count it reports has to be the count of error lines
/// — decided where each failure happens rather than by searching the
/// output text, which would miscount a successful result that merely
/// contains the word "error".
@Test func debugScriptReportsTheNumberOfFailedLines() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(Action(name: "a.b", description: "t", kind: .read, schema: .object([:])) {
        _ in .string("this result mentions an error but did not fail")
    })

    let allGood = await runDebugScriptReportingFailures(
        [#"{"action":"a.b","params":{}}"#], registry: r, environment: "staging")
    #expect(allGood.failureCount == 0)

    let mixed = await runDebugScriptReportingFailures(
        [#"{"action":"missing","params":{}}"#, #"{"action":"a.b","params":{}}"#, "not json at all"],
        registry: r, environment: "staging")
    #expect(mixed.failureCount == 2)
    #expect(mixed.lines.count == 3)
}

@Test func debugScriptReportsAFailureWithoutAbortingLaterLines() async throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let r = ActionRegistry(journalDirectory: dir, sessionId: "s1")
    await r.register(Action(name: "a.b", description: "t", kind: .read, schema: .object([:])) { $0 })
    let out = await runDebugScript([#"{"action":"missing","params":{}}"#,
                                    #"{"action":"a.b","params":{}}"#],
                                   registry: r, environment: "staging")
    // Guarded, not `#expect`-ed then indexed: `out[1]` on a short list traps,
    // and a trap kills the whole test process rather than failing this test.
    guard out.count == 2 else {
        Issue.record("expected 2 output lines, got \(out.count): \(out)"); return
    }
    #expect(out[0].contains("error"))
    #expect(out[1].contains("error") == false)
}
