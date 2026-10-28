import Foundation
import Testing
@testable import WakilKit

// 2d-i Task 9: the window sends the hint, shows a `RESOLVED` row, splits the
// note back out of a rebuilt thread, and feeds and drops the vocabulary.

private let column = Identifier(
    text: "transaction_read_only", kind: .column, origin: "staging · core db", source: .schema)

/// A store whose one live source answers `names` for any context, so a
/// test sees them on the next read without waiting for a cached build.
private func storeWith(_ names: [Identifier]) -> VocabularyStore {
    let source = FixedSource(kind: .schema, name: "fixed") { _ in names }
    return VocabularyStore(live: [source], cached: [], report: { _, _ in })
}

private let testContext = ContextStore.ActiveContext(org: "test-org", project: "p", environment: "staging")

@MainActor
private func modelWith(_ harness: RecordingHarness, vocabulary: VocabularyStore?,
                       context: ContextStore? = nil) -> WindowModel {
    WindowModel.forTesting(
        scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness },
        context: context, vocabulary: vocabulary)
}

@Test @MainActor func aLooseIdentifierReachesTheAgentWithTheNoteAndTheThreadGetsOneRow() async throws {
    let harness = RecordingHarness()
    let store = storeWith([column])
    let model = modelWith(harness, vocabulary: store)
    await store.contextChanged(testContext)

    await model.send("what's in transaction read only")

    let sent = try #require(await harness.sentTexts.last)
    #expect(sent.hasPrefix("what's in transaction read only\n\n" + TurnNote.header))
    #expect(sent.contains("\"transaction read only\" → transaction_read_only (column · staging · core db)"))
    let resolved = model.thoughts.filter { $0.label == "resolved" }
    #expect(resolved.count == 1)
    #expect(resolved.first?.detail == "transaction read only → transaction_read_only")
}

@Test @MainActor func aTurnWithNoIdentifierIsSentByteIdenticalWithNoRow() async throws {
    let harness = RecordingHarness()
    let store = storeWith([column])
    let model = modelWith(harness, vocabulary: store)
    await store.contextChanged(testContext)

    await model.send("hello there")

    let sent = try #require(await harness.sentTexts.last)
    #expect(sent == "hello there")
    #expect(!model.thoughts.contains { $0.label == "resolved" })
}

/// Guards the default: a window built without a store changes nothing.
@Test @MainActor func aWindowWithNoStoreSendsUnchanged() async throws {
    let harness = RecordingHarness()
    let model = modelWith(harness, vocabulary: nil)

    await model.send("what's in transaction read only")

    let sent = try #require(await harness.sentTexts.last)
    #expect(sent == "what's in transaction read only")
    #expect(!model.thoughts.contains { $0.label == "resolved" })
}

/// Invariant 4 for names: after the org-change teardown nothing of the
/// old org resolves, even though the store was never told a new context.
/// Read from the store, not through `send`: the teardown also clears the
/// provider, so no turn could reach an agent here anyway.
@Test @MainActor func anOrgChangeDropsTheVocabulary() async throws {
    let store = storeWith([column])
    let model = modelWith(RecordingHarness(), vocabulary: store)
    await store.contextChanged(testContext)
    #expect(await store.current().count == 1)

    await model.invalidateForOrgChange()

    #expect(await store.current().count == 0)
}

/// A `get_context` double: answers one fixed context, no process involved.
private struct FixedContextCaller: ToolCaller {
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        .object(["structuredContent": .object([
            "Org": .string("test-org"),
            "Environment": .string("staging"),
            "ActiveProvider": .string("test-provider"),
            "Project": .object(["name": .string("p")]),
            "RootPaths": .array([.string("/tmp/wakil-window-identifier-tests")]),
        ])])
    }
}

/// `refreshContext` is what hands the store its context: before it, the
/// store has none and resolves nothing; after it, the same turn resolves.
@Test @MainActor func refreshingTheContextFeedsTheVocabulary() async throws {
    let harness = RecordingHarness()
    let store = storeWith([column])
    let model = modelWith(harness, vocabulary: store, context: ContextStore(client: FixedContextCaller()))
    #expect(await store.current().count == 0)

    await model.refreshContext()

    #expect(await store.current().count == 1)
    await model.send("what's in transaction read only")
    let sent = try #require(await harness.sentTexts.last)
    #expect(sent.contains(TurnNote.header))
}

/// The transcript holds what was sent — typed text plus the note — so a
/// rebuilt thread shows the typed text alone and the `RESOLVED` row after it.
@Test @MainActor func aRebuiltTurnShowsTheTypedTextAndTheResolvedRow() async throws {
    let typed = "what's in transaction read only"
    let resolutions = IdentifierResolver.resolve(typed, in: Vocabulary([column]))
    let note = try #require(TurnNote.render(resolutions))
    let sentText = typed + "\n\n" + note

    let journal = testScratchRoot.appendingPathComponent("window-identifier-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    let registry = ActionRegistry(
        journalDirectory: journal, sessionId: "window-identifier-rebuilt",
        initialActions: [fakeReadSession(cwd: "/tmp/wakil-window-identifier-tests", userText: sentText)])
    let harness = RecordingHarness()
    let model = WindowModel(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: "/tmp/wakil-window-identifier-tests", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookupForIdentifiers(), environment: "staging")

    await model.resume(sessionId: "parent-1")

    // This window has no ticket client, so the resume also notes it cannot tell whether the
    // session was handed (F16); that row is not the rebuilt turn's.
    let rows = model.thoughts.filter { $0.label != "hand-off" }.map { ($0.label, $0.detail) }
    try #require(rows.count == 4, "\(rows)")
    #expect(rows[0] == ("you", typed))
    #expect(rows[1] == ("resolved", TurnNote.row(resolutions)))
    #expect(rows[2] == ("assistant", "on it"))
    #expect(rows[3].0 == "resumed")
}

/// A `session_read` double returning one user turn and one reply — the
/// shape `WindowModelTests.swift`'s private `registerFakeReadSession` uses.
private func fakeReadSession(cwd: String, userText: String) -> Action {
    Action(
        name: "session_read", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string(cwd),
                "provider": .string("main"),
                "parent": .string(""),
                "truncated": .bool(false),
                "entries": .array([
                    .object([
                        "kind": .string("user"), "text": .string(userText),
                        "toolName": .string(""), "isError": .bool(false),
                    ]),
                    .object([
                        "kind": .string("assistant"), "text": .string("on it"),
                        "toolName": .string(""), "isError": .bool(false),
                    ]),
                ]),
            ])])
        })
}

/// Private to this file, like every other copy of it.
private struct AlwaysSucceedsCredentialsLookupForIdentifiers: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

/// The journal holds the note whole — exactly what the agent was sent
/// under the typed text — not `[redacted]`.
@Test @MainActor func aResolvedTurnJournalsTheNoteWhole() async throws {
    let harness = RecordingHarness()
    let store = storeWith([column])
    let model = modelWith(harness, vocabulary: store)
    await store.contextChanged(testContext)

    await model.send("what's in transaction read only")

    let sent = try #require(await harness.sentTexts.last)
    let note = String(sent.dropFirst("what's in transaction read only\n\n".count))
    let entries = try await model.registryForTesting.journalEntries()
    let entry = try #require(entries.last { $0.action == "identifiers_resolved" })
    guard case .object(let params) = entry.params else {
        Issue.record("params is not an object: \(entry.params)")
        return
    }
    #expect(params["note"] == .string(note))
    #expect(note.hasPrefix(TurnNote.header))
    #expect(entry.outcome == "ok")
}

/// A failing source is journalled with its error text intact. The report
/// closure `WakilWiring.build` hands the store is inline there, so this
/// writes the same event through the same registry call and reads it back.
@Test func aFailingSourceJournalsItsErrorWhole() async throws {
    let journal = testScratchRoot.appendingPathComponent("window-identifier-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: journal, sessionId: "window-identifier-source-failed")

    try await registry.journalIdentifierEvent(
        action: "identifier_source_failed",
        params: .object(["source": .string("schema"), "error": .string("list_columns: connection refused")]),
        caller: .test(""), outcome: "error")

    let entry = try #require(try await registry.journalEntries().last)
    #expect(entry.action == "identifier_source_failed")
    #expect(entry.params == .object([
        "source": .string("schema"), "error": .string("list_columns: connection refused"),
    ]))
    #expect(entry.outcome == "error")
}

/// Holds a live source until the test lets it go.
private actor IdentifierGate {
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

/// An org switch that lands while the send is reading the vocabulary: the turn still goes to
/// its own place's agent (nothing is stopped), but the switch has dropped the names (`dropAll`,
/// Invariant 4 for names), so none are attached — no `RESOLVED` row in that agent's thread, and
/// no note journalled.
@Test @MainActor func aSwitchDuringTheVocabularyReadLeavesNoResolvedRow() async throws {
    let gate = IdentifierGate()
    let entered = AsyncStream<Void>.makeStream()
    let source = FixedSource(kind: .schema, name: "fixed") { _ in
        entered.continuation.yield()
        await gate.wait()
        return [column]
    }
    let store = VocabularyStore(live: [source], cached: [], report: { _, _ in })
    let harness = RecordingHarness()
    let model = modelWith(harness, vocabulary: store)
    model.setOrganizationForTesting("test-org")
    let typedIn = model.place
    await store.contextChanged(testContext)

    let sending = Task { await model.send("what's in transaction read only") }
    for await _ in entered.stream { break }          // send is inside vocabulary.current()
    await model.requestOrganizationSwitch("other-org")
    #expect(model.organization == "other-org", "\(model.status)")
    await gate.release()
    await sending.value

    let agent = try #require(model.agents[typedIn])
    #expect(!agent.thoughts.contains { $0.label == "resolved" })
    let sent = try #require(await harness.sentTexts.last)
    #expect(sent == "what's in transaction read only")
    let entries = try await model.registryForTesting.journalEntries()
    #expect(!entries.contains { $0.action == "identifiers_resolved" })
}
