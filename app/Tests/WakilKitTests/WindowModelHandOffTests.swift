import Foundation
import Testing
@testable import WakilKit

// Ticket noticing, Task 9: a handed conversation starts off screen through `send`, and its push,
// sync, publish, merge and rebase ask the operator unless May push.

private let org = "initech"
private let placeA = Place(organization: org, project: "api", environment: "staging")
private let placeB = Place(organization: org, project: "web", environment: "staging")
private let brief = "INI-142 · src/auth/token.go:41 — keep the org\n\nThe reviewer asked for the host in the error."

private let gitWrites = ["editor_changes_push", "editor_changes_sync", "editor_changes_publish",
                         "editor_changes_merge", "editor_changes_rebase"]

@MainActor
private func until(_ done: @MainActor () async -> Bool) async {
    let deadline = Date().addingTimeInterval(2 * testWaitLoadMultiplier)
    while Date() < deadline, !(await done()) { try? await Task.sleep(for: .milliseconds(5)) }
}

/// A window on `placeA`'s Landing, its harnesses scripted, its ticket store over a fake
/// `wakil-ticket`, the five git writes registered as shipped (allow everywhere, Decision 44), and
/// the doubles a resume reads (`session_read`, `session_get`: the parent's lineage root is `root`).
@MainActor
private func handOffWindow(root: @escaping @Sendable () -> String = { "" })
    async -> (WindowModel, Harnesses, FakeTicket) {
    let harnesses = Harnesses()
    let fake = FakeTicket()
    let store = EditorTicketStore(ticket: fake)
    let window = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: org, harnessFactory: { place, _ in harnesses.make(place) },
        ticket: store)
    window.seedForTesting(
        providerId: "test-provider", rootPath: "/p/api", thoughts: 0, project: placeA.project, environment: placeA.environment)
    // Its own connections, so no other test's change restarts its agents mid-test.
    window.agentConnectionsBox = AgentConnectionsBox()
    let registry = window.registryForTesting
    for name in gitWrites + ["editor_changes_commit"] {
        await registry.register(Action(name: name, description: "test", kind: .mutate, audience: .agentReachable,
                                       schema: .object([:]), handler: { _ in .object(["ok": .bool(true)]) },
                                       price: (production: .allow, otherwise: .allow)))
    }
    await registry.register(Action(
        name: "session_read", description: "test double", kind: .read, schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string("/p/api"), "provider": .string("test-provider"), "parent": .string(""),
                "truncated": .bool(false), "entries": .array([]),
            ])])
        }))
    await registry.register(Action(
        name: "session_get", description: "test double", kind: .read, schema: .object(["type": .string("object")]),
        handler: { _ in .object(["structuredContent": .object(["lineageRoot": .string(root())])]) }))
    return (window, harnesses, fake)
}

private func request(place: Place = placeA, root: String = "/p/api", mayPush: Bool = false) -> TicketHandOffRequest {
    TicketHandOffRequest(key: "INI-142", pr: 212, thread: "PRRT_1", brief: brief, harness: "claude-code",
                         provider: "test-provider", place: place, root: root, branch: "ini-142-login", mayPush: mayPush)
}

/// The window's `ticket_handoff_write` calls with `op`, in order.
private func writes(_ fake: FakeTicket, op: String) async -> [[String: JSONValue]] {
    await fake.calls.compactMap { c -> [String: JSONValue]? in
        guard c.name == "ticket_handoff_write", case .object(let o) = c.args, o["op"] == .string(op) else { return nil }
        return o
    }
}

/// Whether an agent of `conversation` gets `name` run unasked (`true`) or gated (`false`).
@MainActor
private func agentRuns(_ window: WindowModel, _ name: String, conversation: String, place: Place = placeA) async throws -> Bool {
    do {
        _ = try await window.registryForTesting.dispatch(
            name: name, params: .object([:]), origin: .agent,
            caller: DispatchCaller(place: place, session: "s-\(conversation)", conversation: conversation), confirmation: nil)
        return true
    } catch ActionError.needsConfirmation {
        return false
    }
}

@Suite @MainActor struct WindowModelHandOffTests {
    @Test func startHandOffLeavesTheScreenAlone() async throws {
        let (window, harnesses, fake) = await handOffWindow()
        // A conversation on screen, then the hand-off beside it.
        #expect(await window.send("hello"))
        let shown = window.currentAgent
        let screens = window.screenConversations
        let panes = window.layoutSnapshot.panes.map(\.id)
        let rows = window.liveConversationRows().count
        let id = try await window.startHandOff(request(mayPush: true))
        #expect(window.currentAgent === shown)
        #expect(window.screenConversations == screens)
        #expect(window.layoutSnapshot.panes.map(\.id) == panes)
        #expect(window.place == placeA)
        let live = window.liveConversationRows()
        #expect(live.count == rows + 1)
        let row = try #require(live.first { $0.id == id })
        #expect(row.title == conversationTitle("INI-142 · src/auth/token.go:41 — keep the org"))
        #expect(!row.onScreen)
        // The one start path: its harness got the brief, in its root.
        let harness = try #require(harnesses.issued.last)
        #expect(harness.log.contains("send:\(brief)"))
        #expect(harness.workingDirectory == "/p/api")
        // Recorded, with the operator's May push, after the send.
        let add = try #require(await writes(fake, op: "add").first)
        #expect(add["key"] == .string("INI-142"))
        #expect(add["mayPush"] == .bool(true))
        guard case .object(let h)? = add["handoff"] else { Issue.record("no handoff in \(add)"); return }
        #expect(h["conversation"] == .string(id))
        #expect(h["thread"] == .string("PRRT_1"))
        #expect(h["provider"] == .string("test-provider"))
        #expect(window.conversation(id: id)?.handoff?.key == "INI-142")
        // Its chip, not on screen, says it works.
        #expect(window.chips.contains { $0.conversation == id && $0.state == .working })
    }

    @Test func startHandOffInAnotherProjectPinsItsPlace() async throws {
        let (window, harnesses, _) = await handOffWindow()
        let id = try await window.startHandOff(request(place: placeB, root: "/p/web"))
        #expect(window.conversation(id: id)?.place == placeB)
        #expect(window.place == placeA)
        #expect(window.currentAgent == nil)
        let harness = try #require(harnesses.in(placeB).first)
        #expect(harness.workingDirectory == "/p/web")
        #expect(harnesses.in(placeA).isEmpty)
    }

    @Test func startHandOffFailureClosesTheConversation() async throws {
        let (window, harnesses, fake) = await handOffWindow()
        struct Refused: Error, CustomStringConvertible { var description: String { "the provider refused the key" } }
        harnesses.startError = Refused()
        do {
            _ = try await window.startHandOff(request())
            Issue.record("a hand-off whose send failed started")
        } catch {
            #expect("\(error)" == "agent: the provider refused the key")
        }
        #expect(window.liveConversationRows().isEmpty)
        #expect(window.chips.isEmpty)
        #expect(await writes(fake, op: "add").isEmpty)
    }

    @Test func cancelHandOffClosesIt() async throws {
        let (window, harnesses, fake) = await handOffWindow()
        var reserved: String?
        let id = try await window.startHandOff(request(), reserved: { reserved = $0 })
        #expect(reserved == id)
        await window.cancelHandOff(id)
        #expect(window.conversation(id: id) == nil)
        #expect(harnesses.issued.last?.stopped == true)
        #expect(await writes(fake, op: "end").last?["conversations"] == .array([.string(id)]))
    }

    @Test func turnEndReadsTheRootThenInFlight() async throws {
        let (window, harnesses, fake) = await handOffWindow()
        await fake.set("ticket_branch", ticketBranchJSON())
        let id = try await window.startHandOff(request())
        let before = await fake.calls.count
        harnesses.issued.last?.emit(.result(isError: false, text: "done"))
        await until { await fake.count("ticket_in_flight") >= 1 }
        let after = await fake.calls.dropFirst(before)
        let names = after.map(\.name)
        let branch = try #require(names.firstIndex(of: "ticket_branch"))
        let inFlight = try #require(names.firstIndex(of: "ticket_in_flight"))
        #expect(branch < inFlight)
        guard case .object(let a) = after[after.startIndex + branch].args else { Issue.record("no args"); return }
        #expect(a["root"] == .string("/p/api"))
        #expect(window.conversation(id: id)?.turnInFlight == false)
    }

    @Test func closingEndsTheHandOff() async throws {
        let (window, harnesses, fake) = await handOffWindow()
        let id = try await window.startHandOff(request())
        harnesses.issued.last?.emit(.result(isError: false, text: "done"))
        await until { window.conversation(id: id)?.turnInFlight == false }
        await window.closeConversation(id)
        #expect(window.conversation(id: id) == nil)
        #expect(await writes(fake, op: "end").last?["conversations"] == .array([.string(id)]))
    }

    /// A failed end is said whole: nothing is left to carry a chip, so the window's status says it.
    @Test func aFailedEndIsSaidWhole() async throws {
        let (window, harnesses, fake) = await handOffWindow()
        let id = try await window.startHandOff(request())
        harnesses.issued.last?.emit(.result(isError: false, text: "done"))
        await until { window.conversation(id: id)?.turnInFlight == false }
        await fake.fail("ticket_handoff_write", "INI-142.json is not readable")
        await window.closeConversation(id)
        #expect(window.status == "hand-off not ended: INI-142.json is not readable")
    }

    @Test func windowReadyEndsHandOffsWithNoLiveConversation() async throws {
        let (window, _, fake) = await handOffWindow()
        let id = try await window.startHandOff(request())
        await window.endStaleHandOffs()
        let end = try #require(await writes(fake, op: "end").last)
        #expect(end["keepLive"] == .bool(true))
        #expect(end["conversations"] == .array([.string(id)]))
        await fake.fail("ticket_handoff_write", "pr-handoffs.json is not readable")
        await window.endStaleHandOffs()
        #expect(window.status == "hand-offs not ended: pr-handoffs.json is not readable")
    }

    /// A hand-off that could not be recorded is said on its chip and in its thread, whole; the
    /// conversation runs on, its May push off.
    @Test func aFailedRecordIsSaidOnTheChip() async throws {
        let (window, _, fake) = await handOffWindow()
        await fake.fail("ticket_handoff_write", "INI-142.json is not readable")
        await fake.set("ticket_handoff_may_push", .object(["mayPush": .bool(true)]))
        let id = try await window.startHandOff(request(mayPush: true))
        let note = "The hand-off was not recorded (INI-142.json is not readable), so this conversation's push and sync ask you."
        #expect(window.conversation(id: id)?.handoffFailure == note)
        #expect(window.chips.first { $0.conversation == id }?.handoffNote == note)
        #expect(window.conversation(id: id)?.thoughts.contains { $0.detail == note && $0.isError } == true)
    }

    @Test func sessionListCarriesHanded() async throws {
        let (window, _, _) = await handOffWindow()
        #expect(await window.send("hello"))
        let id = try await window.startHandOff(request())
        let rows = window.liveConversationRows()
        let handed = try #require(rows.first { $0.id == id })
        guard case .object(let h) = handed.json else { Issue.record("no object"); return }
        #expect(h["handed"] == .bool(true))
        #expect(h["key"] == .string("INI-142"))
        #expect(h["thread"] == .string("PRRT_1"))
        let other = try #require(rows.first { $0.id != id })
        guard case .object(let o) = other.json else { Issue.record("no object"); return }
        #expect(o["handed"] == .bool(false))
        #expect(o["key"] == nil)
    }

    // MARK: - The price, as the window's lookup answers it

    /// May push is the stored hand-off's (`ticket_handoff_may_push`), never the memory's alone: on
    /// only when the store and the Start both say on; a read that fails is off.
    @Test func mayPushIsReadFromTheStore() async throws {
        for (started, stored, error, runs) in [
            (true, true, false, true), (true, false, false, false), (false, true, false, false), (true, true, true, false),
        ] {
            let (window, harnesses, fake) = await handOffWindow()
            let id = try await window.startHandOff(request(mayPush: started))
            harnesses.issued.last?.emit(.result(isError: false, text: "done"))
            await until { window.conversation(id: id)?.turnInFlight == false }
            await fake.set("ticket_handoff_may_push", .object(["mayPush": .bool(stored)]))
            if error { await fake.fail("ticket_handoff_may_push", "INI-150.json is not readable") }
            for name in ["editor_changes_push", "editor_changes_sync"] {
                #expect(try await agentRuns(window, name, conversation: id) == runs, "\(name) \(started) \(stored) \(error)")
            }
            for name in ["editor_changes_publish", "editor_changes_merge", "editor_changes_rebase"] {
                #expect(!(try await agentRuns(window, name, conversation: id)), "\(name)")
            }
            #expect(try await agentRuns(window, "editor_changes_commit", conversation: id))
            // The store is asked when the Start said on; off needs no read to stay off.
            #expect(await fake.args("ticket_handoff_may_push")?["conversation"] == (started ? .string(id) : nil))
        }
    }

    /// Every git write × May push × handed or not: an agent not handed and the operator are
    /// priced as before (allow).
    @Test func gitWritesMatrix() async throws {
        for mayPush in [false, true] {
            let (window, _, fake) = await handOffWindow()
            await fake.set("ticket_handoff_may_push", .object(["mayPush": .bool(mayPush)]))
            #expect(await window.send("hello"))
            let ordinary = try #require(window.currentAgent?.id)
            let id = try await window.startHandOff(request(mayPush: mayPush))
            for name in gitWrites {
                let pushLike = name == "editor_changes_push" || name == "editor_changes_sync"
                #expect(try await agentRuns(window, name, conversation: id) == (pushLike && mayPush), "\(name) \(mayPush)")
                #expect(try await agentRuns(window, name, conversation: ordinary), "\(name) \(mayPush) not handed")
                _ = try await window.registryForTesting.dispatch(
                    name: name, params: .object([:]), origin: .ui,
                    caller: DispatchCaller(place: placeA, session: nil, conversation: id), confirmation: nil)
            }
        }
    }

    /// Invariant 7: a spoken turn in a handed conversation asks before every git write, May push or
    /// not; once it is answered, May push applies again.
    @Test func aSpokenTurnAsksMayPushOrNot() async throws {
        let (window, harnesses, fake) = await handOffWindow()
        await fake.set("ticket_handoff_may_push", .object(["mayPush": .bool(true)]))
        let id = try await window.startHandOff(request(mayPush: true))
        let harness = try #require(harnesses.issued.last)
        harness.emit(.result(isError: false, text: "done"))
        await until { window.conversation(id: id)?.turnInFlight == false }
        let scope = WindowModel.TurnScope(place: placeA, rootPath: "/p/api", providerId: "test-provider", conversation: id)
        #expect(await window.send("push it", via: .voice, scope: scope))
        for name in gitWrites {
            #expect(!(try await agentRuns(window, name, conversation: id)), "\(name) spoken")
        }
        // The session the message went to: a restart for the organisation's connections (another
        // test's change to the shared box) may have replaced the first.
        harnesses.issued.last?.emit(.result(isError: false, text: "done"))
        await until { window.conversation(id: id)?.spoken == false }
        #expect(try await agentRuns(window, "editor_changes_push", conversation: id))
    }

    // MARK: - Resume and fork (F16)

    /// A resume or a fork in its own conversation keeps the id, so the hand-off and the gate stay.
    @Test func resumeAndForkKeepTheHandOff() async throws {
        let (window, harnesses, fake) = await handOffWindow()
        let id = try await window.startHandOff(request())
        let first = try #require(harnesses.issued.last)
        first.emit(.result(isError: false, text: "done"))
        await until { window.conversation(id: id)?.turnInFlight == false }
        // Its process goes away: the next message forks it.
        first.finish()
        await until { window.conversation(id: id)?.sessionEnded == true }
        let scope = WindowModel.TurnScope(place: placeA, rootPath: "/p/api", providerId: "test-provider", conversation: id)
        #expect(await window.send("go on", scope: scope))
        #expect(harnesses.issued.count == 2)
        #expect(window.conversation(id: id)?.handoff?.key == "INI-142")
        #expect(!(try await agentRuns(window, "editor_changes_push", conversation: id)))
        #expect(!(try await agentRuns(window, "editor_changes_publish", conversation: id)))
        // An explicit resume in the same conversation.
        harnesses.issued.last?.emit(.result(isError: false, text: "done"))
        await until { window.conversation(id: id)?.turnInFlight == false }
        await window.resume(sessionId: "s-parent", conversation: id)
        #expect(harnesses.issued.count == 3)
        #expect(window.conversation(id: id)?.handoff?.key == "INI-142")
        #expect(!(try await agentRuns(window, "editor_changes_publish", conversation: id)))
        #expect(await writes(fake, op: "carry").isEmpty)
    }

    /// A handed conversation's session resumed into a new conversation (Continue) carries its
    /// hand-off to the new id, which reads May push from the carried record.
    @Test func resumeIntoANewConversationCarriesTheHandOff() async throws {
        let root = Locked("")
        let (window, harnesses, fake) = await handOffWindow(root: { root.value })
        let handed = try await window.startHandOff(request(mayPush: true))
        harnesses.issued.last?.emit(.result(isError: false, text: "done"))
        await until { window.conversation(id: handed)?.turnInFlight == false }
        await window.closeConversation(handed)
        root.value = handed
        await fake.set("ticket_handoff_write", .object([
            "key": .string("INI-142"),
            "handoff": .object(["id": .string("h2"), "conversation": .string("new"), "thread": .string("PRRT_1"),
                                "mayPush": .bool(true)]),
        ]))
        await fake.set("ticket_handoff_may_push", .object(["mayPush": .bool(true)]))
        await window.resume(sessionId: "s-of-\(handed)")
        let resumed = try #require(window.currentAgent)
        #expect(resumed.id != handed)
        let carry = try #require(await writes(fake, op: "carry").last)
        #expect(carry["from"] == .string(handed))
        #expect(carry["to"] == .string(resumed.id))
        #expect(resumed.handoff?.key == "INI-142")
        #expect(resumed.handoff?.thread == "PRRT_1")
        #expect(resumed.handoff?.mayPush == true)
        #expect(try await agentRuns(window, "editor_changes_push", conversation: resumed.id))
        #expect(!(try await agentRuns(window, "editor_changes_rebase", conversation: resumed.id)))
        #expect(await fake.args("ticket_handoff_may_push")?["conversation"] == .string(resumed.id))
    }

    /// A carry that fails leaves the new conversation handed with May push off — whatever the
    /// store would say — and says why on its chip and in its thread.
    @Test func aFailedCarryReadsMayPushOff() async throws {
        let (window, _, fake) = await handOffWindow(root: { "c-handed-before" })
        await fake.fail("ticket_handoff_write", "INI-150.json is not readable")
        await fake.set("ticket_handoff_may_push", .object(["mayPush": .bool(true)]))
        await window.resume(sessionId: "s-parent")
        let resumed = try #require(window.currentAgent)
        #expect(resumed.handoff?.mayPush == false)
        #expect(resumed.handoffFailure?.contains("INI-150.json is not readable") == true)
        for name in gitWrites {
            #expect(!(try await agentRuns(window, name, conversation: resumed.id)), "\(name)")
        }
    }

    /// A conversation never handed, resumed: the carry finds nothing, and it is priced as any agent.
    @Test func resumingAnOrdinarySessionStaysOrdinary() async throws {
        let (window, _, fake) = await handOffWindow(root: { "c-never-handed" })
        await window.resume(sessionId: "s-parent")
        let resumed = try #require(window.currentAgent)
        #expect(await writes(fake, op: "carry").count == 1)
        #expect(resumed.handoff == nil)
        for name in gitWrites {
            #expect(try await agentRuns(window, name, conversation: resumed.id), "\(name)")
        }
    }
}

/// A value a `@Sendable` closure reads after the test changes it.
private final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
