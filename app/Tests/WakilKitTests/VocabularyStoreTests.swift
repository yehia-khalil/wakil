import Foundation
import Testing
@testable import WakilKit

private func ctx(_ org: String) -> ContextStore.ActiveContext {
    ContextStore.ActiveContext(org: org, project: "p", environment: "staging")
}

private func table(_ text: String, _ org: String) -> Identifier {
    Identifier(text: text, kind: .table, origin: org, source: .schema)
}

private actor ReportBox {
    var all: [String] = []
    func add(_ source: String, _ message: String) { all.append("\(source): \(message)") }
}

@Test func cachedSourcesAreBuiltOnContextChangeAndLiveOnesOnEveryRead() async {
    let schema = FixedSource(kind: .schema, name: "schema") { [table("edit_quote", $0.org)] }
    let live = FixedSource(kind: .panes, name: "panes") { _ in
        [Identifier(text: "pane_col", kind: .column, origin: "pane", source: .panes)]
    }
    let store = VocabularyStore(live: [live], cached: [schema], report: { _, _ in })
    await store.contextChanged(ctx("initech"))
    await store.waitForRebuild()
    let v = await store.current()
    #expect(!v.names(folded: "editquote").isEmpty)
    #expect(!v.names(folded: "panecol").isEmpty)
}

/// Holds a source until the test lets it go. Ignores cancellation on
/// purpose: that is what makes a late result late.
private actor GateBox {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

@Test func anOrgSwitchDropsTheOldOrgsNamesAtOnceAndALateResultIsDiscarded() async {
    let gate = GateBox()
    let entered = AsyncStream<Void>.makeStream()
    let schema = FixedSource(kind: .schema, name: "schema") { context in
        if context.org == "initech" {
            entered.continuation.yield()
            await gate.wait()   // the old org's build is slow, and ignores cancellation
        }
        return [table(context.org == "initech" ? "old_table" : "new_table", context.org)]
    }
    let store = VocabularyStore(live: [], cached: [schema], report: { _, _ in })
    await store.contextChanged(ctx("initech"))
    for await _ in entered.stream { break }          // the old build is inside its source
    await store.dropAll()
    await store.contextChanged(ctx("umbrella"))
    await store.waitForRebuild()                     // the new org has installed
    #expect(!(await store.current()).names(folded: "newtable").isEmpty)
    await gate.release()                             // only now does the old build finish
    await store.waitForAllBuilds()
    let v = await store.current()
    #expect(v.names(folded: "oldtable").isEmpty)
    #expect(!v.names(folded: "newtable").isEmpty)
}

@Test func anOrgChangeWithoutADropNeverShowsTheOldOrgsNames() async {
    let gate = GateBox()
    let schema = FixedSource(kind: .schema, name: "schema") { context in
        if context.org == "umbrella" { await gate.wait() }
        return [table(context.org == "initech" ? "old_table" : "new_table", context.org)]
    }
    let store = VocabularyStore(live: [], cached: [schema], report: { _, _ in })
    await store.contextChanged(ctx("initech"))
    await store.waitForRebuild()
    #expect(!(await store.current()).names(folded: "oldtable").isEmpty)
    await store.contextChanged(ctx("umbrella"))       // new org's build is held
    #expect((await store.current()).names(folded: "oldtable").isEmpty)
    await gate.release()
    await store.waitForRebuild()
    #expect(!(await store.current()).names(folded: "newtable").isEmpty)
}

@Test func aCancelledBuildReportsNothing() async {
    let reports = ReportBox()
    let entered = AsyncStream<Void>.makeStream()
    let schema = FixedSource(kind: .schema, name: "code") { context in
        if context.org == "initech" {
            entered.continuation.yield()
            try await Task.sleep(for: .seconds(3600))   // throws CancellationError when cancelled
        }
        return []
    }
    let store = VocabularyStore(live: [], cached: [schema], report: { await reports.add($0, $1) })
    await store.contextChanged(ctx("initech"))
    for await _ in entered.stream { break }
    await store.contextChanged(ctx("umbrella"))
    await store.waitForAllBuilds()
    #expect(await reports.all.isEmpty)
}

@Test func aReadThatStraddlesADropAnswersEmpty() async {
    let gate = GateBox()
    let entered = AsyncStream<Void>.makeStream()
    let live = FixedSource(kind: .panes, name: "panes") { _ in
        entered.continuation.yield()
        await gate.wait()
        return [Identifier(text: "pane_col", kind: .column, origin: "pane", source: .panes)]
    }
    let store = VocabularyStore(live: [live], cached: [], report: { _, _ in })
    await store.contextChanged(ctx("initech"))
    await store.waitForRebuild()
    let read = Task { await store.current() }
    for await _ in entered.stream { break }          // current() is suspended in the live source
    await store.dropAll()
    await gate.release()
    let v = await read.value
    #expect(v.count == 0)
}

@Test func aFailingSourceIsReportedAndTheOthersStillResolve() async {
    let reports = ReportBox()
    let bad = FixedSource(kind: .schema, name: "schema") { _ in throw SchemaSourceError(message: "connection refused") }
    let good = FixedSource(kind: .code, name: "code") { _ in
        [Identifier(text: "build_launch", kind: .code, origin: "x", source: .code)]
    }
    let store = VocabularyStore(live: [], cached: [bad, good], report: { await reports.add($0, $1) })
    await store.contextChanged(ctx("initech"))
    await store.waitForRebuild()
    #expect(!(await store.current()).names(folded: "buildlaunch").isEmpty)
    #expect(await reports.all == ["schema: connection refused"])
}

/// A source with several parts (roots, databases) where one part failed:
/// its names are installed and the failed part is reported whole.
private struct PartlyFailingSource: IdentifierSource {
    let kind = IdentifierSourceKind.code
    let name = "code"
    func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier] {
        try await gather(for: context).names
    }
    func gather(for context: ContextStore.ActiveContext) async throws -> IdentifierGathering {
        IdentifierGathering(names: [Identifier(text: "build_launch", kind: .code, origin: "x", source: .code)],
                            failures: ["git rev-parse HEAD in /plain: not a git repository"])
    }
}

@Test func aPartialFailureIsReportedAndTheSourcesOtherNamesStillResolve() async {
    let reports = ReportBox()
    let store = VocabularyStore(live: [], cached: [PartlyFailingSource()], report: { await reports.add($0, $1) })
    await store.contextChanged(ctx("initech"))
    await store.waitForRebuild()
    #expect(!(await store.current()).names(folded: "buildlaunch").isEmpty)
    #expect(await reports.all == ["code: git rev-parse HEAD in /plain: not a git repository"])
}

@Test func readingBeforeTheFirstBuildFinishesAnswersAtOnce() async {
    let never = FixedSource(kind: .code, name: "code") { _ in try await Task.sleep(for: .seconds(3600)); return [] }
    let store = VocabularyStore(live: [], cached: [never], report: { _, _ in })
    await store.contextChanged(ctx("initech"))
    let started = Date()
    _ = await store.current()
    #expect(Date().timeIntervalSince(started) < 1)
    await store.dropAll()   // cancels the sleeping build so it does not outlive the test
}
