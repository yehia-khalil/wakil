import Foundation
import Testing
@testable import WakilKit

/// A clock a test moves by hand: the store's staleness reads it, never the wall.
private final class NeedsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

/// `ticket_in_flight`'s answer: one Waiting on you row, PR #212 with `threads` waiting threads.
private func inFlightJSON(threads: Int) -> JSONValue {
    .object([
        "waitingOnYou": .array([.object([
            "key": .string("INI-142"), "title": .string("Sign-in keeps the last organization"), "root": .string("/p/api"),
            "branch": .string("ini-142-login"), "repo": .string("github.com/initech/api"), "pr": .integer(212),
            "threads": .array((1...max(threads, 1)).prefix(threads).map { .string("T\($0)") }),
            "failing": .array([]), "review": .bool(false), "activity": .string("2026-10-28T09:00:00Z"),
            "handoffs": .array([]), "count": .integer(Int64(threads)),
        ])]),
        "inFlight": .array([]), "partial": .array([]), "count": .integer(Int64(threads)),
    ])
}

@MainActor
private func noticingWindow(organization: String = "initech", context: ContextStore? = nil)
    async -> (WindowModel, FakeTicket, EditorTicketStore, NeedsClock) {
    let fake = FakeTicket()
    await fake.set("ticket_in_flight", inFlightJSON(threads: 3))
    let clock = NeedsClock()
    let store = EditorTicketStore(ticket: fake, now: { clock.now })
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: organization, context: context, ticket: store)
    // No tick unless a test says: a sleep that only a cancel ends.
    window.ticketPollSleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    return (window, fake, store, clock)
}

/// Waits, a bounded while, for `done`; the condition is checked, never assumed.
@MainActor
private func until(_ done: @MainActor () async -> Bool) async {
    for _ in 0..<500 where !(await done()) { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite @MainActor struct WindowModelTicketNoticingTests {
    @Test func pollReadsEveryTwoMinutes() async {
        let (window, fake, _, _) = await noticingWindow()
        #expect(window.ticketPollInterval == .seconds(120))
        var slept: [Duration] = []
        window.ticketPollSleep = { d in
            slept.append(d)
            if slept.count > 2 { try await Task.sleep(for: .seconds(3600)) }
        }
        window.updateTicketPoll()
        await until { await fake.count("ticket_in_flight") == 2 }
        #expect(await fake.count("ticket_in_flight") == 2)
        #expect(Array(slept.prefix(2)) == [.seconds(120), .seconds(120)])
        await until { window.ticketNeeds?.count == 3 }
        #expect(window.ticketNeeds?.count == 3)
        window.stopTicketPoll()
    }

    /// Walk 2026-10-29: the 2-minute clock runs from the last read, not from Wakil coming back — a
    /// focus change no longer puts the next read off by a whole interval.
    @Test func pollWaitsOnlyWhatIsLeftOfTheInterval() async {
        let (window, _, _, clock) = await noticingWindow()
        await window.ticketNeedsRead(force: true)
        clock.advance(90)
        var slept: [Duration] = []
        window.ticketPollSleep = { d in
            slept.append(d)
            try await Task.sleep(for: .seconds(3600))
        }
        window.updateTicketPoll()
        await until { !slept.isEmpty }
        #expect(slept.first == .seconds(30))
        window.stopTicketPoll()
    }

    @Test func pollStopsOnResignAndLock() async {
        let (window, _, _, _) = await noticingWindow()
        window.updateTicketPoll()
        #expect(window.ticketPollTask != nil)
        window.setAppActive(false)
        #expect(window.ticketPollTask == nil)
        window.setAppActive(true)
        #expect(window.ticketPollTask != nil)
        window.setScreenLocked(true)
        #expect(window.ticketPollTask == nil)
        // Active again while locked: still nothing read.
        window.setAppActive(false)
        window.setAppActive(true)
        #expect(window.ticketPollTask == nil)
        window.setScreenLocked(false)
        #expect(window.ticketPollTask != nil)
        window.stopTicketPoll()
    }

    /// A resign or a lock landing during the sleep: the tick that sleep ends reads nothing.
    @Test func aResignOrLockDuringTheSleepReadsNothing() async {
        for lock in [false, true] {
            let (window, fake, _, _) = await noticingWindow()
            var ticks = 0
            window.ticketPollSleep = { _ in
                ticks += 1
                guard ticks == 1 else { try await Task.sleep(for: .seconds(3600)); return }
                if lock { window.setScreenLocked(true) } else { window.setAppActive(false) }
            }
            window.updateTicketPoll()
            await until { ticks >= 1 }
            for _ in 0..<50 { await Task.yield() }
            #expect(ticks == 1)
            #expect(await fake.count("ticket_in_flight") == 0, "lock \(lock)")
            #expect(window.ticketPollTask == nil)
            window.stopTicketPoll()
        }
    }

    /// A window shut down stops its 2-minute read: no tick reads after.
    @Test func shutdownStopsThePoll() async {
        let (window, fake, _, _) = await noticingWindow()
        var ticks = 0
        var released = false
        window.ticketPollSleep = { _ in
            ticks += 1
            guard ticks == 1 else { try await Task.sleep(for: .seconds(3600)); return }
            // Parked until the test lets go, then returns as a sleep ends: a loop the shutdown left
            // running would read now.
            while !released { await Task.yield() }
        }
        window.updateTicketPoll()
        await until { ticks >= 1 }
        await window.shutdown()
        #expect(window.ticketPollTask == nil)
        released = true
        for _ in 0..<50 { await Task.yield() }
        #expect(await fake.count("ticket_in_flight") == 0)
        #expect(ticks == 1)
    }

    /// Wakil coming back reads In flight when the last read is over 60 s old, with no editor pane open.
    @Test func activationReadsWhenStaleWhateverIsOnScreen() async {
        let (window, fake, _, clock) = await noticingWindow()
        #expect(!window.layoutSnapshot.panes.contains { $0.kind == "editor" })
        await window.ticketNeedsRead(force: true)
        #expect(await fake.count("ticket_in_flight") == 1)
        clock.advance(59)
        await window.ticketNeedsRead(force: false)
        #expect(await fake.count("ticket_in_flight") == 1)
        clock.advance(2)
        window.setAppActive(false)
        window.setAppActive(true)
        await until { await fake.count("ticket_in_flight") == 2 }
        #expect(await fake.count("ticket_in_flight") == 2)
        window.stopTicketPoll()
    }

    @Test(.timeLimit(.minutes(1))) func aSecondTriggerJoinsTheRead() async {
        let (window, fake, _, _) = await noticingWindow()
        await fake.setSlowInFlight(true)
        let first = Task { await window.ticketNeedsRead(force: true) }
        await until { await fake.count("ticket_in_flight") == 1 }
        let second = Task { await window.ticketNeedsRead(force: true) }
        for _ in 0..<50 { await Task.yield() }
        await fake.release()
        await first.value
        await second.value
        #expect(await fake.count("ticket_in_flight") == 1)
        #expect(window.ticketNeeds?.count == 3)
    }

    @Test func aFailedReadKeepsTheLastNeeds() async {
        let (window, fake, store, _) = await noticingWindow()
        await window.ticketNeedsRead(force: true)
        #expect(window.ticketNeeds?.count == 3)
        await fake.fail("ticket_in_flight", "GitHub said: Bad credentials")
        await window.ticketNeedsRead(force: true)
        #expect(window.ticketNeeds?.count == 3)
        #expect(await store.lastInFlight()?.count == 3)
        #expect(await store.inFlightFailure()?.contains("Bad credentials") == true)
        // The next read that comes back clears the failure.
        await fake.fail("ticket_in_flight", nil)
        await window.ticketNeedsRead(force: true)
        #expect(await store.inFlightFailure() == nil)
    }

    /// An org switch empties the needs at once (Invariant 4), ends the new org's stale hand-offs, then
    /// reads the new org's In flight.
    @Test(.timeLimit(.minutes(1))) func orgSwitchEmptiesNeedsAndReadsTheNewOrg() async {
        let (window, fake, _, _) = await noticingWindow()
        await window.ticketNeedsRead(force: true)
        #expect(window.ticketNeeds?.count == 3)
        await fake.set("ticket_in_flight", inFlightJSON(threads: 1))
        await fake.setSlowInFlight(true)
        await window.setOrganization("umbrella")
        #expect(window.organization == "umbrella")
        #expect(window.ticketNeeds == nil)
        await until { await fake.count("ticket_in_flight") == 2 }
        #expect(await fake.count("ticket_handoff_write") == 1)
        #expect(await fake.args("ticket_handoff_write")
            == ["op": .string("end"), "conversations": .array([]), "keepLive": .bool(true)])
        // Ended before the read, so the read counts no conversation the quit or the switch left behind.
        let calls = await fake.calls.map(\.name)
        #expect(calls.lastIndex(of: "ticket_handoff_write")! < calls.lastIndex(of: "ticket_in_flight")!)
        await fake.release()
        await until { window.ticketNeeds?.count == 1 }
        #expect(window.ticketNeeds?.count == 1)
        window.stopTicketPoll()
    }

    /// The window being ready (the first context read with an organisation) ends stale hand-offs and
    /// reads In flight, once: a later context read (a project switch) does not read again.
    @Test func windowReadyEndsStaleHandoffsAndReads() async {
        let (window, fake, _, _) = await noticingWindow(
            organization: "", context: ContextStore(client: GitRootsContext(roots: [])))
        await window.refreshContext()
        #expect(!window.organization.isEmpty)
        await until { await fake.count("ticket_in_flight") == 1 }
        #expect(await fake.count("ticket_handoff_write") == 1)
        #expect(await fake.args("ticket_handoff_write")
            == ["op": .string("end"), "conversations": .array([]), "keepLive": .bool(true)])
        #expect(await fake.count("ticket_in_flight") == 1)
        #expect(window.ticketPollTask != nil)
        await until { window.ticketNeeds != nil }
        await window.refreshContext()
        for _ in 0..<50 { await Task.yield() }
        #expect(await fake.count("ticket_in_flight") == 1)
        #expect(await fake.count("ticket_handoff_write") == 1)
        window.stopTicketPoll()
    }

    /// The window's rows take each live handed conversation's state; one not live is ignored.
    @Test func rowsTakeTheLiveConversationsStates() async {
        let (window, fake, _, _) = await noticingWindow()
        await fake.set("ticket_in_flight", .object([
            "waitingOnYou": .array([]), "partial": .array([]), "count": .integer(0),
            "inFlight": .array([.object(["key": .string("INI-138"), "state": .string("agent"),
                                         "handoffs": .array([.object(["id": .string("h1"), "conversation": .string("gone")])])])]),
        ]))
        await window.ticketNeedsRead(force: true)
        #expect(window.ticketNeedsRows.map(\.urgent) == [TicketUrgent(tier: 9, words: "local branch")])
    }
}

/// A window with the editor, ticket and browser actions over one pane store and layout, In flight's
/// INI-142 row read, and one editor pane open.
@MainActor
private func pickWindow(clock: NeedsClock? = nil) async throws -> (WindowModel, String) {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("ticket-pick-\(UUID().uuidString)"), sessionId: "t")
    let panes = PaneStore(kinds: PaneKinds.standard)
    let layout = LayoutStore()
    await registerLayoutActions(
        into: registry, layout: layout, panes: panes, unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
    let fake = FakeTicket()
    await fake.set("ticket_in_flight", inFlightJSON(threads: 3))
    let store = clock.map { c in EditorTicketStore(ticket: fake, now: { c.now }) } ?? EditorTicketStore(ticket: fake)
    let roots = ["/p/api"]
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: nil,
        context: ContextStore(client: GitRootsContext(roots: roots)),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in EditorWindowLookup() },
        rootWatcher: nil, editorRootWatcher: nil, fileLists: nil, gitStatus: nil, ticket: store,
        paletteClients: PaletteClients(), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() }, quickModelFactory: nil)
    model.ticketPollSleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    model.setOrganizationForTesting("initech")
    await registerEditorActions(into: registry, panes: panes, layout: layout, files: FakeFiles(), fileLists: nil,
                                gitStatus: nil, roots: { roots }, ticket: store, organization: { "initech" })
    await registerBrowserActions(into: registry, panes: panes, layout: layout,
                                 settings: { SettingsBrowser(searchEngine: "google", startPage: "") })
    await model.ticketNeedsRead(force: true)
    _ = await model.openPane(kind: "editor")
    let editor = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
    return (model, editor)
}

/// Walk 2026-10-29: a ticket picked from Waiting on you stays shown while a link in it opens Wakil's
/// browser (focus moves there) and the operator comes back to the editor — by a click on the pane, or
/// by its rail row, which shows the Ticket view as it was left (spec, Rule 6 row: "the column scrolled
/// where it was"), not the branch's own.
@Suite @MainActor struct WindowModelTicketPickSurvivesTests {
    @Test func aPickedTicketStaysShownWhenALinkOpensTheBrowserAndFocusComesBack() async throws {
        let (window, editor) = try await pickWindow()
        await window.dispatchFromSurface("ticket_show", .object(["pane": .string(editor), "key": .string("INI-142")]))
        #expect(await window.editorSnapshot(pane: editor).column?.ticketShown == "INI-142")

        await window.openLinkInWakil("https://github.com/initech/api/pull/212")
        let browser = try #require(window.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
        #expect(window.layoutSnapshot.focusedId == browser)
        #expect(window.editor(editor)?.column?.ticketShown == "INI-142")

        // Back by a click on the pane.
        _ = await window.focusPane(id: editor)
        #expect(window.editor(editor)?.column?.ticketShown == "INI-142")

        // Away again, then back by the rail's row, the needs-you tick on it.
        await window.openLinkInWakil("https://github.com/initech/api/pull/212/checks")
        #expect(window.ticketNeeds?.count == 3)
        await window.railRowPressed(pane: editor)
        #expect(window.layoutSnapshot.focusedId == editor)
        let c = try #require(window.editor(editor)?.column)
        #expect(c.ticketShown == "INI-142" && c.view == .ticket && c.shown)
        #expect(c.ticketShownAt == TicketShownAt(root: "/p/api", branch: "ini-142-login"))
        window.stopTicketPoll()
    }

    /// Walk 2026-10-29: the 2-minute read reads a picked ticket's own branch again too, as ↻ does —
    /// a PR retitled on GitHub shows without a click.
    @Test func thePollReadsAPickedTicketsBranch() async throws {
        let (window, editor) = try await pickWindow()
        await window.dispatchFromSurface("ticket_show", .object(["pane": .string(editor), "key": .string("INI-142")]))
        let fake = try #require(window.ticket?.ticket as? FakeTicket)
        let picked: @Sendable () async -> Int = {
            await fake.calls.filter { c in
                guard c.name == "ticket_branch", case .object(let a) = c.args else { return false }
                return a["branch"] == .string("ini-142-login")
            }.count
        }
        await until { await picked() >= 1 }
        let before = await picked()
        var ticks = 0
        window.ticketPollSleep = { _ in
            ticks += 1
            if ticks > 1 { try await Task.sleep(for: .seconds(3600)) }
        }
        window.updateTicketPoll()
        await until { await picked() > before }
        #expect(await picked() == before + 1)
        window.stopTicketPoll()
    }

    /// Walk 2026-10-29: Wakil coming back reads a picked ticket's branch again when its read is over
    /// 60 s old, as it does the branch's own — the operator retitled the PR in Terminal and came back.
    @Test func comingBackReadsAPickedTicketWhenStale() async throws {
        let clock = NeedsClock()
        let (window, editor) = try await pickWindow(clock: clock)
        await window.dispatchFromSurface("ticket_show", .object(["pane": .string(editor), "key": .string("INI-142")]))
        let fake = try #require(window.ticket?.ticket as? FakeTicket)
        let picked: @Sendable () async -> Int = {
            await fake.calls.filter { c in
                guard c.name == "ticket_branch", case .object(let a) = c.args else { return false }
                return a["branch"] == .string("ini-142-login")
            }.count
        }
        await until { await picked() >= 1 }
        let before = await picked()
        window.setAppActive(false)
        window.setAppActive(true)
        for _ in 0..<50 { await Task.yield() }
        #expect(await picked() == before, "a fresh read is not read again")
        clock.advance(61)
        window.setAppActive(false)
        window.setAppActive(true)
        await until { await picked() > before }
        #expect(await picked() == before + 1)
        window.stopTicketPoll()
    }

    /// The rail's row on a pane showing Files: the column goes to Ticket, the branch's own.
    @Test func theRailRowShowsTheTicketView() async throws {
        let (window, editor) = try await pickWindow()
        await window.dispatchFromSurface("editor_tree", .object(["pane": .string(editor), "view": .string("files")]))
        await window.railRowPressed(pane: editor)
        let c = try #require(window.editor(editor)?.column)
        #expect(c.view == .ticket && c.shown && c.ticketShown == nil)
        window.stopTicketPoll()
    }
}
