import Foundation
import Testing
@testable import WakilKit

/// The editor actions with a ticket store over `FakeTicket`, on roots `/p/api` and `/p/web`.
private struct TicketFixture {
    let editor: EditorFixture
    let ticket: FakeTicket
    let store: EditorTicketStore

    @discardableResult
    func dispatch(_ name: String, _ params: [String: JSONValue] = [:], origin: ActionOrigin = .agent,
                  caller: DispatchCaller = .test("staging"), confirmation: String? = "confirm") async throws -> JSONValue {
        try await editor.registry.dispatch(name: name, params: .object(params), origin: origin, caller: caller,
                                           confirmation: confirmation)
    }
}

/// `organization` is the window's on screen; `editorPane` false leaves the canvas with none.
private func ticketFixture(organization: String = "org", editorPane: Bool = true) async throws -> TicketFixture {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let layout = LayoutStore()
    let pane = editorPane ? await layout.open(kind: "editor", title: "Editor").id : ""
    let panes = PaneStore(kinds: PaneKinds.standard)
    let files = FakeFiles()
    let git = FakeGit()
    let roots = ["/p/api", "/p/web"]
    let status = GitStatus(git: git, roots: { roots })
    let ticket = FakeTicket()
    await ticket.set("ticket_branch", ticketBranchJSON())
    let store = EditorTicketStore(ticket: ticket)
    await registerEditorActions(into: registry, panes: panes, layout: layout, files: files, fileLists: nil,
                                gitStatus: status, roots: { roots }, ticket: store, organization: { organization })
    let editor = EditorFixture(registry: registry, panes: panes, layout: layout, files: files, pane: pane, git: git, status: status)
    return TicketFixture(editor: editor, ticket: ticket, store: store)
}

private let replyParams: [String: JSONValue] = [
    "root": .string("/p/api"), "repo": .string("github.com/initech/api"), "pr": .integer(212),
    "thread": .string("T2"), "body": .string("Thanks, fixed."),
    "path": .string("src/auth/token.go"), "line": .integer(41),
]

private func isNeedsConfirmation(_ error: any Error) -> Bool {
    if case ActionError.needsConfirmation = error { return true }
    return false
}

@Suite struct EditorTicketActionsTests {
    @Test func recordUpdateCarriesOriginNotParams() async throws {
        let f = try await ticketFixture()
        await f.ticket.set("ticket_record_write", .object(["key": .string("INI-142")]))
        let params: [String: JSONValue] = ["key": .string("INI-142"), "section": .string("decisions"), "op": .string("add"),
                                           "text": .string("Keep the org in the token"), "why": .string("one read"),
                                           "by": .string("operator")]
        try await f.dispatch("ticket_record_update", params, caller: .test("staging", conversation: "c1"))
        let agent = try #require(await f.ticket.args("ticket_record_write"))
        #expect(agent["by"] == .string("agent"))
        #expect(agent["conversation"] == .string("c1"))
        #expect(agent["line"] == .object(["text": .string("Keep the org in the token"), "why": .string("one read")]))

        try await f.dispatch("ticket_record_update", params, origin: .ui, caller: .test("production"), confirmation: nil)
        let operatorArgs = try #require(await f.ticket.args("ticket_record_write"))
        #expect(operatorArgs["by"] == .string("operator"))
        #expect(operatorArgs["conversation"] == nil)
    }

    @Test func replyKeepsTheDraftWhenThePostFails() async throws {
        let f = try await ticketFixture()
        try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed.")])
        await f.ticket.fail("review_reply", "GitHub said: Resource not accessible by integration")
        await #expect { try await f.dispatch("review_reply_send", replyParams) } throws: { error in
            "\(error)".contains("Resource not accessible by integration")
        }
        #expect(await f.store.draft(thread: "T2") == "Thanks, fixed.")
        #expect(!(await f.store.sending(thread: "T2")))

        await f.ticket.fail("review_reply", nil)
        try await f.dispatch("review_reply_send", replyParams)
        #expect(await f.store.draft(thread: "T2") == nil)
        #expect(await f.ticket.args("review_reply") == ["root": .string("/p/api"), "thread": .string("T2"),
                                                        "body": .string("Thanks, fixed.")])
    }

    /// GitHub posted the reply and answered errors beside it: the reply is posted (the draft goes, so a
    /// second Send cannot post it twice), and the errors are kept whole for the thread's box.
    @Test func replyPostedBesideErrorsIsPostedAndKeepsTheErrors() async throws {
        let f = try await ticketFixture()
        try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed.")])
        let comment: JSONValue = .object(["author": .string("peter"), "body": .string("Thanks, fixed."),
                                          "createdAt": .string("2026-10-26T09:00:00Z")])
        await f.ticket.set("review_reply", .object([
            "comment": comment,
            "errors": .array([.string("Could not notify subscribers"), .string("Rate limit nearly spent")]),
        ]))
        let out = try await f.dispatch("review_reply_send", replyParams)
        guard case .object(let o) = out else { Issue.record("reply \(out)"); return }
        #expect(o["comment"] == comment)
        #expect(await f.store.draft(thread: "T2") == nil)
        #expect(await f.store.answer(thread: "T2")
            == "Posted. GitHub also answered: Could not notify subscribers; Rate limit nearly spent")

        await f.ticket.set("review_reply", .object(["comment": comment, "errors": .array([])]))
        try await f.dispatch("review_reply_send", replyParams)
        #expect(await f.store.answer(thread: "T2") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func replyCannotBeSentTwice() async throws {
        let f = try await ticketFixture()
        await f.ticket.setSlowReply(true)
        let first = Task { try await f.dispatch("review_reply_send", replyParams) }
        while !(await f.store.sending(thread: "T2")) { await Task.yield() }
        await #expect { try await f.dispatch("review_reply_send", replyParams) } throws: { error in
            "\(error)".contains("a reply to this thread is already being sent")
        }
        await f.ticket.release()
        _ = try await first.value
        #expect(await f.ticket.count("review_reply") == 1)
    }

    @Test func resolveAllowsTheOperatorAndGatesTheAgent() async throws {
        let f = try await ticketFixture()
        let params: [String: JSONValue] = ["root": .string("/p/api"), "thread": .string("T2"), "resolved": .bool(true)]
        try await f.dispatch("review_resolve", params, origin: .ui, confirmation: nil)
        #expect(await f.ticket.count("review_resolve") == 1)
        await #expect { try await f.dispatch("review_resolve", params, origin: .agent, confirmation: nil) } throws: { isNeedsConfirmation($0) }
        #expect(await f.ticket.count("review_resolve") == 1)
        #expect(confirmationDescription(action: "review_resolve", params: .object(params)) == "resolve review thread T2 in api")
    }

    @Test @MainActor func replySendIsGateForTheOperatorToo() async throws {
        // The registry refuses the operator's own send without the plane...
        let f = try await ticketFixture()
        await #expect { try await f.dispatch("review_reply_send", replyParams, origin: .ui, confirmation: nil) } throws: { isNeedsConfirmation($0) }
        #expect(await f.ticket.count("review_reply") == 0)

        // ...and the window parks it there, showing where it goes and its exact text.
        let confirmations = ConfirmationBroker()
        let model = WindowModel.forTesting(scratchRoot: testScratchRoot, confirmations: confirmations)
        let ticket = FakeTicket()
        await describes(ticket)
        let store = EditorTicketStore(ticket: ticket)
        await registerTicketActions(
            into: model.registryForTesting, store: store, panes: PaneStore(kinds: PaneKinds.standard), layout: nil,
            editor: EditorTicketHooks(pane: { _, _ in "editor-1" }, reply: { _ in .null },
                                      updateColumn: { _, _ in .initial }, openFile: { _, _, _ in }),
            roots: { ["/p/api"] })
        let send = Task { @MainActor in await model.dispatchFromSurface("review_reply_send", .object(replyParams)) }
        var parked: PendingMutation?
        for _ in 0..<2_000 where parked == nil {
            parked = await confirmations.all().values.first
            if parked == nil { try await Task.sleep(for: .milliseconds(1)) }
        }
        let proposal = try #require(parked)
        #expect(proposal.action == "review_reply_send")
        #expect(proposal.statement == "Reply on initech/api#212 · src/auth/token.go:41\n\nThanks, fixed.")
        #expect(await ticket.count("review_reply") == 0)
        await confirmations.cancel(id: proposal.id)
        await send.value
        #expect(await ticket.count("review_reply") == 0)
    }

    @Test func aStatementCannotNameAnotherThreadThanTheOneRead() async throws {
        let f = try await ticketFixture()
        _ = try await f.store.read(root: "/p/api")
        var wrong = replyParams
        wrong["path"] = .string("src/auth/session.go")
        await #expect { try await f.dispatch("review_reply_send", wrong) } throws: { error in
            "\(error)".contains("is on initech/api#212 · src/auth/token.go:41")
        }
        #expect(await f.ticket.count("review_reply") == 0)
    }

    @Test func editorTreeAcceptsTicket() async throws {
        let f = try await ticketFixture()
        try await f.dispatch("editor_tree", ["pane": .string(f.editor.pane), "view": .string("ticket")])
        let c = try #require(await f.editor.snapshot().column)
        #expect(c.view == .ticket && c.shown)
        // The view is saved; the ticket picked from In flight is not.
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("ini-140")])
        #expect(await f.editor.snapshot().column?.ticketShown == "INI-140")
        let saved = try JSONDecoder().decode(EditorColumnState.self, from: JSONEncoder().encode(try #require(await f.editor.snapshot().column)))
        #expect(saved.view == .ticket && saved.ticketShown == nil)
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .null])
        #expect(await f.editor.snapshot().column?.ticketShown == nil)
    }

    /// Task 8: ↻ becomes Cancel while a read runs (Rule 4): `ticket_refresh {cancel: true}` stops
    /// the followed root's read, and the ↻ that started it answers, not fails.
    @Test(.timeLimit(.minutes(1))) func refreshCancelStopsTheReadInFlight() async throws {
        let f = try await ticketFixture()
        await f.ticket.setHangBranch(true)
        let refresh = Task { try await f.dispatch("ticket_refresh", ["pane": .string(f.editor.pane)], origin: .ui, confirmation: nil) }
        while !(await f.store.reading(root: "/p/api")) { await Task.yield() }
        try await f.dispatch("ticket_refresh", ["pane": .string(f.editor.pane), "cancel": .bool(true)], origin: .ui, confirmation: nil)
        #expect(!(await f.store.reading(root: "/p/api")))
        _ = try await refresh.value
        #expect(await f.store.failure(root: "/p/api") == nil)
        #expect(await f.ticket.count("ticket_branch") == 1)
    }

    /// Task 8: the view draws from one mirror of the store — each root's read, which roots are
    /// reading, each failure whole, In flight and the records of tickets shown from it.
    @Test func theViewStateFollowsTheStore() async throws {
        let f = try await ticketFixture()
        await f.ticket.set("ticket_record", .object(["key": .string("INI-140"), "next": .object(["text": .string("deploy to QA")])]))
        _ = try await f.store.read(root: "/p/api")
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("ini-140")], origin: .ui, confirmation: nil)
        #expect(await f.ticket.args("ticket_record") == ["key": .string("INI-140")])
        var v = await f.editor.panes.editorTicketView()
        for _ in 0..<1_000 where v.records["INI-140"] == nil || v.branches["/p/api"] == nil {
            try await Task.sleep(for: .milliseconds(1))
            v = await f.editor.panes.editorTicketView()
        }
        #expect(v.roots == ["/p/api", "/p/web"])
        #expect(v.branches["/p/api"]?.branch == "ini-142-login")
        #expect(v.records["INI-140"]?.next?.text == "deploy to QA")
        #expect(v.reading.isEmpty)
    }

    /// Fix round 1: a ticket picked from In flight shows the full ticket view — its own branch is
    /// read by the row's root and branch through the window's client, the root's own read and
    /// current branch untouched (Rule 6) — and its threads open like the branch's own.
    @Test func aPickFromInFlightReadsItsBranch() async throws {
        let f = try await ticketFixture()
        _ = try await f.store.read(root: "/p/api")
        await f.ticket.set("ticket_in_flight", .object([
            "waitingOnYou": .array([]), "partial": .array([]),
            "inFlight": .array([.object(["key": .string("INI-140"), "title": .string("Deploy"), "status": .string("To Do"),
                                         "state": .string("#212 · open"), "root": .string("/p/api"),
                                         "branch": .string("ini-140-deploy"), "pr": .integer(212)])]),
        ]))
        _ = try await f.store.inFlight()
        await f.ticket.set("ticket_record", .object(["key": .string("INI-140")]))
        let before = await f.ticket.count("ticket_branch")
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("INI-140")], origin: .ui, confirmation: nil)
        #expect(await f.ticket.count("ticket_branch") == before + 1)
        #expect(await f.ticket.args("ticket_branch") == ["root": .string("/p/api"), "branch": .string("ini-140-deploy")])
        var v = await f.editor.panes.editorTicketView()
        for _ in 0..<1_000 where v.shownBranches["INI-140"] == nil {
            try await Task.sleep(for: .milliseconds(1))
            v = await f.editor.panes.editorTicketView()
        }
        #expect(v.shownBranches["INI-140"]?.prs.first?.number == 212)
        // The root's own read is the one it was.
        #expect(await f.store.lastRead(root: "/p/api") != nil)
        #expect(v.branches["/p/api"] == (await f.store.branch(root: "/p/api")))
        #expect(await f.store.thread("T2") != nil)

        // A ticket the branch itself carries (the several pick) reads no other branch.
        let after = await f.ticket.count("ticket_branch")
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("INI-142")], origin: .ui, confirmation: nil)
        #expect(await f.ticket.count("ticket_branch") == after)
    }

    /// Two In flight rows carry one key on different branches: picking the second by its root and
    /// branch reads and shows the second's branch, never the first's; the key alone picks the first.
    @Test func aPickedRowShowsItsOwnBranch() async throws {
        let f = try await ticketFixture()
        _ = try await f.store.read(root: "/p/api")
        func row(_ branch: String, pr: Int) -> JSONValue {
            .object(["key": .string("INI-140"), "title": .string("Deploy"), "status": .string("To Do"),
                     "state": .string("#\(pr) · open"), "root": .string("/p/api"), "branch": .string(branch), "pr": .integer(Int64(pr))])
        }
        await f.ticket.set("ticket_in_flight", .object([
            "waitingOnYou": .array([]), "partial": .array([]),
            "inFlight": .array([row("ini-140-deploy", pr: 212), row("ini-140-hotfix", pr: 213)]),
        ]))
        _ = try await f.store.inFlight()
        await f.ticket.set("ticket_record", .object(["key": .string("INI-140")]))
        await f.ticket.set("ticket_branch", ticketBranchJSON(branch: "ini-140-hotfix"))
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("INI-140"),
                                             "root": .string("/p/api"), "branch": .string("ini-140-hotfix")],
                             origin: .ui, confirmation: nil)
        #expect(await f.ticket.args("ticket_branch") == ["root": .string("/p/api"), "branch": .string("ini-140-hotfix")])
        let c = await f.editor.snapshot().column
        #expect(c?.ticketShown == "INI-140")
        #expect(c?.ticketShownAt == TicketShownAt(root: "/p/api", branch: "ini-140-hotfix"))
        #expect(await f.store.shownBranches()["INI-140"]?.branch == "ini-140-hotfix")
        let v = await f.editor.panes.editorTicketView()
        #expect(v.inFlightRow("INI-140", at: c?.ticketShownAt)?.branch == "ini-140-hotfix")
        #expect(v.inFlightRow("INI-140", at: c?.ticketShownAt)?.pr == 213)
        let read = await f.editor.panes.readPane(paneId: f.editor.pane, kind: "editor")
        guard case .object(let o) = read, case .object(let col)? = o["column"] else { Issue.record("no column"); return }
        #expect(col["ticket_shown_at"] == .object(["root": .string("/p/api"), "branch": .string("ini-140-hotfix")]))

        // The key alone (the several pick, an agent naming a key) picks the first row, as before.
        await f.ticket.set("ticket_branch", ticketBranchJSON(branch: "ini-140-deploy"))
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("INI-140")], origin: .ui, confirmation: nil)
        #expect(await f.ticket.args("ticket_branch") == ["root": .string("/p/api"), "branch": .string("ini-140-deploy")])
        #expect(await f.editor.snapshot().column?.ticketShownAt == TicketShownAt(root: "/p/api", branch: "ini-140-deploy"))
    }

    /// Fix round 2: the fixture with INI-140 picked from In flight, its branch (`ini-140-deploy`, the
    /// same PR and threads, keyed INI-140) read beside the root's own.
    private func pickedFixture() async throws -> TicketFixture {
        let f = try await ticketFixture()
        _ = try await f.store.read(root: "/p/api")
        await f.ticket.set("ticket_in_flight", .object([
            "waitingOnYou": .array([]), "partial": .array([]),
            "inFlight": .array([.object(["key": .string("INI-140"), "title": .string("Deploy"), "status": .string("To Do"),
                                         "state": .string("#212 · open"), "root": .string("/p/api"),
                                         "branch": .string("ini-140-deploy"), "pr": .integer(212)])]),
        ]))
        _ = try await f.store.inFlight()
        await f.ticket.set("ticket_record", .object(["key": .string("INI-140")]))
        await f.ticket.set("ticket_branch", try pickedBranchJSON(resolved: false))
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("INI-140")], origin: .ui, confirmation: nil)
        #expect(await f.store.shownBranches()["INI-140"] != nil)
        return f
    }

    /// `ticketBranchJSON` as INI-140's branch, its thread T2 resolved or not.
    private func pickedBranchJSON(resolved: Bool) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var text = String(decoding: try encoder.encode(ticketBranchJSON(branch: "ini-140-deploy")), as: UTF8.self)
            .replacingOccurrences(of: "INI-142", with: "INI-140")
        if resolved {
            let open = #""id":"T2","line":41,"outdated":false,"path":"src/auth/token.go","resolved":false"#
            precondition(text.contains(open), "the fixture's T2 is not where this rewrite looks")
            text = text.replacingOccurrences(of: open, with: open.replacingOccurrences(of: #""resolved":false"#, with: #""resolved":true"#))
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// How many reads of the picked branch `ini-140-deploy` wakil-ticket was asked for.
    private func pickedReads(_ f: TicketFixture) async -> Int {
        await f.ticket.calls.filter { c in
            guard c.name == "ticket_branch", case .object(let o) = c.args else { return false }
            return o["branch"] == .string("ini-140-deploy")
        }.count
    }

    private func shownThread(_ f: TicketFixture, _ id: String) async -> ReviewThreadState? {
        await f.store.shownBranches()["INI-140"]?.prs.flatMap(\.threads).first { $0.id == id }
    }

    @Test(.timeLimit(.minutes(1))) func aResolveFromAPickedViewUpdatesItsThread() async throws {
        let f = try await pickedFixture()
        #expect(await shownThread(f, "T2")?.resolved == false)
        // GitHub now says T2 is resolved; the picked view says so at once, and after its re-read.
        await f.ticket.set("ticket_branch", try pickedBranchJSON(resolved: true))
        try await f.dispatch("review_resolve", ["root": .string("/p/api"), "thread": .string("T2"), "resolved": .bool(true)],
                             origin: .ui, confirmation: nil)
        #expect(await shownThread(f, "T2")?.resolved == true)
        // A resolve re-reads the root, and the picked view on it with it.
        for _ in 0..<1_000 where await pickedReads(f) < 2 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await pickedReads(f) == 2)
        #expect(await shownThread(f, "T2")?.resolved == true)
    }

    @Test func aRecordWriteUpdatesThePickedTicketsRecord() async throws {
        let f = try await pickedFixture()
        await f.ticket.set("ticket_record_write", .object(["key": .string("INI-140"), "next": .object(["text": .string("ship it")])]))
        try await f.dispatch("ticket_record_update", ["key": .string("INI-140"), "section": .string("next"), "op": .string("set"),
                                                      "text": .string("ship it")], origin: .ui, confirmation: nil)
        let shown = await f.store.shownBranches()["INI-140"]?.tickets.first { $0.key == "INI-140" }
        #expect(shown?.record.next?.text == "ship it")
        #expect(await f.store.shownRecords()["INI-140"]?.next?.text == "ship it")
    }

    @Test func refreshRereadsThePickedView() async throws {
        let f = try await pickedFixture()
        let before = await pickedReads(f)
        try await f.dispatch("ticket_refresh", ["pane": .string(f.editor.pane)], origin: .ui, confirmation: nil)
        #expect(await pickedReads(f) == before + 1)
    }

    /// Fix round 1: a shown ticket whose record cannot be read says so whole (Rule 8), never an
    /// empty record.
    @Test func aFailedRecordReadIsShownWhole() async throws {
        let f = try await ticketFixture()
        await f.ticket.fail("ticket_record", "The record could not be read: permission denied")
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("INI-140")], origin: .ui, confirmation: nil)
        var v = await f.editor.panes.editorTicketView()
        for _ in 0..<1_000 where v.recordFailures["INI-140"] == nil {
            try await Task.sleep(for: .milliseconds(1))
            v = await f.editor.panes.editorTicketView()
        }
        #expect(v.recordFailures["INI-140"] == "The record could not be read: permission denied")
        #expect(v.records["INI-140"] == nil)
    }

    @Test func reviewOpenLeavesTheColumnOnTicket() async throws {
        let f = try await ticketFixture()
        await f.editor.files.put("/p/api/src/auth/token.go", (1...50).map { "line \($0)" }.joined(separator: "\n"))
        // The PR's head commit is not local: the threads open at GitHub's lines.
        await f.editor.git.set(showAbsent: "/p/api|src/auth/token.go|commit:abc123")
        await f.editor.git.set(showAbsent: "/p/api|src/auth/session.go|commit:abc123")
        _ = try await f.store.read(root: "/p/api")
        try await f.dispatch("editor_tree", ["pane": .string(f.editor.pane), "view": .string("ticket")])
        let before = await f.editor.snapshot().column
        try await f.dispatch("review_open", ["pane": .string(f.editor.pane), "thread": .string("T2")])
        let s = await f.editor.snapshot()
        #expect(s.column == before)
        let tab = try #require(s.active.map { s.tabs[$0] })
        #expect(tab.path == "/p/api/src/auth/token.go")
        #expect(tab.cursor.line == 41)

        // ⌥↓ from it: the next open thread across files, wrapping, the column still on Ticket.
        await f.editor.files.put("/p/api/src/auth/session.go", (1...100).map { "line \($0)" }.joined(separator: "\n"))
        let step = try await f.dispatch("review_step", ["pane": .string(f.editor.pane), "delta": .integer(1)])
        guard case .object(let o) = step else { Issue.record("no reply"); return }
        #expect(o["thread"] == .string("T1"))
        #expect(o["position"] == .string("1 of 2"))
        #expect(await f.editor.snapshot().column == before)
    }

    /// B1: a thread whose file is already open reuses its tab — the read hands back the root as the
    /// window knows it, so the tab's path and the thread's match — and its box is placed.
    @Test func reviewOpenOnAnOpenFileReusesItsTab() async throws {
        let f = try await ticketFixture()
        let head = (1...50).map { "line \($0)" }
        await f.editor.files.put("/p/api/src/auth/token.go", head.joined(separator: "\n"))
        await f.editor.git.set(show: "/p/api|src/auth/token.go|commit:abc123", head.joined(separator: "\n"))
        let state = try await f.store.read(root: "/p/api")
        #expect(state.root == "/p/api")
        #expect(state.prs.flatMap(\.threads).allSatisfy { $0.root == "/p/api" })
        try await f.dispatch("editor_open", ["pane": .string(f.editor.pane), "path": .string("/p/api/src/auth/token.go")])
        try await f.dispatch("review_open", ["pane": .string(f.editor.pane), "thread": .string("T2")])
        try await f.dispatch("review_open", ["pane": .string(f.editor.pane), "thread": .string("T2")], origin: .ui, confirmation: nil)
        let s = await f.editor.snapshot()
        #expect(s.tabs.filter { $0.path == "/p/api/src/auth/token.go" }.count == 1)
        #expect(s.active.map { s.tabs[$0].cursor.line } == 41)
    }

    /// Task 7: a thread opens at its box's line — GitHub's line mapped through the head commit's
    /// text to the buffer — and the box under the cursor is `read_pane`'s `cursorThread` and where
    /// `review_step` steps from.
    @Test func aThreadOpensAtItsPlacedLineAndTheCursorNamesIt() async throws {
        let f = try await ticketFixture()
        let head = (1...50).map { "line \($0)" }
        await f.editor.files.put("/p/api/src/auth/token.go", (["new a", "new b", "new c"] + head).joined(separator: "\n"))
        _ = try await f.store.read(root: "/p/api")
        while await f.editor.panes.editorReviews().reads.byRoot["/p/api"] == nil { try await Task.sleep(for: .milliseconds(1)) }
        let h = EditorReviewHead(root: "/p/api", path: "src/auth/token.go", sha: "abc123")
        #expect(await f.editor.panes.claimEditorReviewHeads([h, h]) == [h])
        #expect(await f.editor.panes.claimEditorReviewHeads([h]).isEmpty)   // read once
        await f.editor.panes.landEditorReviewHead(h, text: head.joined(separator: "\n"))
        try await f.dispatch("editor_open", ["pane": .string(f.editor.pane), "path": .string("/p/api/src/auth/token.go")])

        try await f.dispatch("review_open", ["pane": .string(f.editor.pane), "thread": .string("T2")])
        let s = await f.editor.snapshot()
        #expect(s.active.map { s.tabs[$0].cursor.line } == 44)
        let read = await f.editor.panes.readPane(paneId: f.editor.pane, kind: "editor")
        guard case .object(let o) = read, case .object(let t)? = o["ticket"] else { Issue.record("no ticket key"); return }
        #expect(t["cursorThread"] == .string("T2"))

        // Back one from the box under the cursor (T2) is T1; from no thread it would be the last, T2.
        await f.editor.files.put("/p/api/src/auth/session.go", (1...100).map { "line \($0)" }.joined(separator: "\n"))
        let step = try await f.dispatch("review_step", ["pane": .string(f.editor.pane), "delta": .integer(-1)])
        guard case .object(let r) = step else { Issue.record("no reply"); return }
        #expect(r["thread"] == .string("T1"))
    }

    /// Fix round 1: a thread in a file not open yet, edited since the PR's head, opens on its box's
    /// line — the action reads the head text itself — so ⌥↓'s next press finds the box.
    @Test func aThreadInAFileNotOpenYetOpensAtItsPlacedLine() async throws {
        let f = try await ticketFixture()
        let head = (1...50).map { "line \($0)" }
        await f.editor.files.put("/p/api/src/auth/token.go", (["new a", "new b", "new c"] + head).joined(separator: "\n"))
        await f.editor.git.set(show: "/p/api|src/auth/token.go|commit:abc123", head.joined(separator: "\n"))
        _ = try await f.store.read(root: "/p/api")
        let deadline = Date().addingTimeInterval(2)
        while await f.editor.panes.editorReviews().reads.byRoot["/p/api"] == nil {
            guard Date() < deadline else { Issue.record("the reads never reached the panes"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
        let step = try await f.dispatch("review_step", ["pane": .string(f.editor.pane), "delta": .integer(1),
                                                        "from": .string("T1")])
        guard case .object(let r) = step else { Issue.record("no reply"); return }
        #expect(r["thread"] == .string("T2"))
        let s = await f.editor.snapshot()
        #expect(s.active.map { s.tabs[$0].path } == "/p/api/src/auth/token.go")
        #expect(s.active.map { s.tabs[$0].cursor.line } == 44)
        let h = EditorReviewHead(root: "/p/api", path: "src/auth/token.go", sha: "abc123")
        #expect(await f.editor.panes.editorReviews().fetched.contains(h))
    }

    @Test func readPaneListsDraftAuthorsWithoutText() async throws {
        let f = try await ticketFixture()
        _ = try await f.store.read(root: "/p/api")
        try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("a secret-looking draft")])
        try await f.dispatch("review_reply_draft", ["thread": .string("T1"), "text": .string("mine, also secret")],
                             origin: .ui, confirmation: nil)
        let read = await f.editor.panes.readPane(paneId: f.editor.pane, kind: "editor")
        guard case .object(let o) = read, case .object(let t)? = o["ticket"] else { Issue.record("no ticket key: \(read)"); return }
        #expect(t["root"] == .string("/p/api"))
        #expect(t["branch"] == .string("ini-142-login"))
        #expect(t["tickets"] == .array([.string("INI-142")]))
        #expect(t["marked"] == .string("INI-142"))
        #expect(t["prs"] == .array([.object(["number": .integer(212), "state": .string("open"), "openThreads": .integer(2)])]))
        #expect(t["drafts"] == .array([.object(["thread": .string("T1"), "by": .string("operator")]),
                                       .object(["thread": .string("T2"), "by": .string("agent")])]))
        #expect(!"\(read)".contains("a secret-looking draft"))
        #expect(!"\(read)".contains("mine, also secret"))
    }

    @Test(.timeLimit(.minutes(1))) func pushInvalidatesTheRootsRead() async throws {
        let f = try await ticketFixture()
        await f.editor.git.set(status: "/p/api", files: [])
        _ = try await f.store.read(root: "/p/api")
        #expect(await f.ticket.count("ticket_branch") == 1)
        for name in ["editor_changes_push", "editor_changes_sync", "editor_changes_publish"] {
            let before = await f.ticket.count("ticket_branch")
            try await f.dispatch(name, ["root": .string("/p/api")])
            while await f.ticket.count("ticket_branch") == before { try await Task.sleep(for: .milliseconds(1)) }
        }
        // A fetch moves nothing on GitHub: no read.
        while await f.store.reading(root: "/p/api") { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await f.ticket.count("ticket_branch")
        try await f.dispatch("editor_changes_fetch", ["root": .string("/p/api")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await f.ticket.count("ticket_branch") == settled)
    }

    @Test func everyTicketActionIsAgentReachableWithItsPrice() async throws {
        let f = try await ticketFixture()
        let all = await f.editor.registry.all()
        let kinds: [String: ActionKind] = [
            "ticket_read": .read, "ticket_refresh": .control, "ticket_show": .control, "ticket_in_flight": .read,
            "ticket_link": .mutate, "ticket_record_update": .mutate, "review_open": .control, "review_step": .control,
            "review_reply_draft": .control, "review_reply_draft_restore": .control, "review_reply_send": .mutate,
            "review_resolve": .mutate,
        ]
        for (name, kind) in kinds {
            let d = try #require(all.first { $0.name == name }, "\(name) is not registered")
            #expect(d.kind == kind, "\(name)")
            #expect(d.audience == .agentReachable, "\(name)")
        }
        // Link and record lines are allowed everywhere, production included, for every channel.
        try await f.dispatch("ticket_link", ["root": .string("/p/api"), "key": .string("INI-142")],
                             caller: .test("production"), confirmation: nil)
        #expect(await f.ticket.count("ticket_link") == 1)
    }
}

/// Invariant 4: an agent session's read goes through its own place's client and answers it alone;
/// the window's cache, which holds the window's organisation, is never filled from it.
@Test func aPinnedAgentsReadNeverFillsTheWindowsCache() async throws {
    let f = try await ticketFixture()
    let agent = DispatchCaller(place: Place(organization: "umbrella", project: "api", environment: "staging"), session: "s1")
    let reply = try await f.dispatch("ticket_read", ["root": .string("/p/api")], caller: agent, confirmation: nil)
    guard case .object(let o) = reply else { Issue.record("no reply"); return }
    #expect(o["branch"] == .string("ini-142-login"))
    #expect(await f.store.branch(root: "/p/api") == nil)
    #expect(await f.ticket.count("ticket_branch") == 1)
}

// MARK: Fix round 1 — the plane names the thread GitHub says it is

/// `review_thread`'s answer: T2 is on initech/api#212 at src/auth/token.go:41 (or `pr`).
private func describes(_ ticket: FakeTicket, pr: Int = 212) async {
    await ticket.set("review_thread", .object([
        "id": .string("T2"), "repo": .string("initech/api"), "number": .integer(Int64(pr)),
        "path": .string("src/auth/token.go"), "line": .integer(41), "resolved": .bool(false), "outdated": .bool(false),
        "author": .string("reviewer"), "firstWords": .string("Nit: the error should name the host"),
    ]))
}

private actor FinishedFlag {
    var done = false
    func set() { done = true }
}

private let agentInSession = DispatchCaller.test("staging", session: "s1", conversation: "c1")

/// An agent's tools/call, parked: the proposal the plane would show, then cancelled.
private func parkedByTheAgent(_ registry: ActionRegistry, _ name: String, _ args: [String: JSONValue]) async throws
    -> (proposal: PendingMutation?, reply: JSONRPCMessage?) {
    let confirmations = ConfirmationBroker()
    let surface = MCPSurface(registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: confirmations)
    let finished = FinishedFlag()
    let call = Task {
        let r = await handle(JSONRPCMessage(id: .number(1), method: "tools/call",
                                            params: .object(["name": .string(name), "arguments": .object(args)])),
                             surface: surface, caller: { agentInSession })
        await finished.set()
        return r
    }
    while !(await finished.done) {
        if let p = await confirmations.all().values.first {
            await confirmations.cancel(id: p.id)
            return (p, await call.value)
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    return (nil, await call.value)
}

@Test(.timeLimit(.minutes(1))) func anAgentReplyToAThreadOfAnotherPRIsRefused() async throws {
    let f = try await ticketFixture()
    await describes(f.ticket, pr: 215)
    let (proposal, reply) = try await parkedByTheAgent(f.editor.registry, "review_reply_send", replyParams)
    #expect(proposal == nil, "parked: \(String(describing: proposal?.statement))")
    #expect("\(String(describing: reply?.error))".contains("initech/api#215"))
    #expect(await f.ticket.count("review_reply") == 0)
    #expect(await f.ticket.count("review_thread") == 1)
}

@Test(.timeLimit(.minutes(1))) func anAgentsPlaneNamesTheThreadGitHubDescribes() async throws {
    let f = try await ticketFixture()
    await describes(f.ticket)
    // The caller's path and line, and a stray statement, never reach the plane: GitHub's do.
    var args = replyParams
    args["path"] = .string("README.md")
    args["line"] = .integer(1)
    args["statement"] = .string("harmless")
    let reply = try await parkedByTheAgent(f.editor.registry, "review_reply_send", args)
    #expect(reply.proposal?.statement == "Reply on initech/api#212 · src/auth/token.go:41\n\nThanks, fixed.")

    let resolve = try await parkedByTheAgent(f.editor.registry, "review_resolve",
                                             ["root": .string("/p/api"), "thread": .string("T2"), "resolved": .bool(true),
                                              "statement": .string("harmless")])
    #expect(resolve.proposal?.statement == "resolve the review thread at src/auth/token.go:41 on initech/api#212 in api")
    #expect(await f.ticket.count("review_reply") == 0)
    #expect(await f.ticket.count("review_resolve") == 0)
}

/// Important 3: one order on both sides — Wakil's own description first, a caller's statement only
/// for an action with none. A gated git write carrying a stray statement shows its description.
@Test(.timeLimit(.minutes(1))) func anAgentsStrayStatementNeverReplacesTheDescription() async throws {
    let f = try await ticketFixture()
    let (proposal, _) = try await parkedByTheAgent(f.editor.registry, "editor_changes_branch_delete",
                                                   ["root": .string("/p/api"), "branch": .string("old"),
                                                    "statement": .string("harmless")])
    #expect(proposal?.statement == "delete branch old in api")
}

@Test(.timeLimit(.minutes(1))) @MainActor func theOperatorsStrayStatementNeverReplacesTheDescription() async throws {
    let confirmations = ConfirmationBroker()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, confirmations: confirmations)
    let ticket = FakeTicket()
    await describes(ticket)
    await registerTicketActions(
        into: model.registryForTesting, store: EditorTicketStore(ticket: ticket), panes: PaneStore(kinds: PaneKinds.standard),
        layout: nil,
        editor: EditorTicketHooks(pane: { _, _ in "editor-1" }, reply: { _ in .null },
                                  updateColumn: { _, _ in .initial }, openFile: { _, _, _ in }),
        roots: { ["/p/api"] })
    var args = replyParams
    args["statement"] = .string("harmless")
    let send = Task { @MainActor in await model.dispatchFromSurface("review_reply_send", .object(args)) }
    var parked: PendingMutation?
    for _ in 0..<2_000 where parked == nil {
        parked = await confirmations.all().values.first
        if parked == nil { try await Task.sleep(for: .milliseconds(1)) }
    }
    #expect(parked?.statement == "Reply on initech/api#212 · src/auth/token.go:41\n\nThanks, fixed.")
    if let parked { await confirmations.cancel(id: parked.id) }
    await send.value
}

/// Important 2: an agent's record write goes to its own place's client; the window's cache keeps
/// the window's organisation and re-reads on its next trigger.
@Test func aPinnedAgentsRecordWriteStaysOutOfTheWindowsCache() async throws {
    let f = try await ticketFixture()
    _ = try await f.store.read(root: "/p/api")
    await f.ticket.set("ticket_record_write", .object([
        "key": .string("INI-142"), "next": .object(["id": .string("x1"), "text": .string("from another org"),
                                                    "by": .string("agent"), "at": .string("2026-10-26T10:00:00Z")]),
    ]))
    try await f.dispatch("ticket_record_update", ["key": .string("INI-142"), "section": .string("next"), "op": .string("set"),
                                                  "text": .string("from another org")],
                         caller: agentInSession, confirmation: nil)
    #expect(await f.ticket.count("ticket_record_write") == 1)
    #expect(await f.store.branch(root: "/p/api")?.tickets.first?.record.next == nil)

    // The operator's own write is the window's, and lands in its cache.
    try await f.dispatch("ticket_record_update", ["key": .string("INI-142"), "section": .string("next"), "op": .string("set"),
                                                  "text": .string("from another org")],
                         origin: .ui, confirmation: nil)
    #expect(await f.store.branch(root: "/p/api")?.tickets.first?.record.next?.text == "from another org")
}

// MARK: Ticket noticing, Task 1 — a draft and a record line name their place

private let draftText: JSONValue = .string("Thanks, fixed.")

/// A root the caller's place does not hold is refused as every root param is, naming the roots.
@Test func draftNamesARootOutsideThePlaceRefused() async throws {
    let f = try await ticketFixture()
    await #expect {
        try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": draftText,
                                                    "root": .string("/elsewhere"), "branch": .string("ini-142-login")],
                             caller: agentInSession)
    } throws: { error in
        guard case GitActionError.notAProjectRoot(_, let root, let roots) = error else { return false }
        return root == "/elsewhere" && roots == ["/p/api", "/p/web"] && "\(error)".contains("/p/api")
    }
    #expect(await f.store.draft(thread: "T2") == nil)
}

/// A branch without a root names no place (Rule 7): the draft is kept, no read is started for it,
/// and a record line passes no branch.
@Test func draftBranchWithoutRootIsDropped() async throws {
    let f = try await ticketFixture()
    _ = try await f.store.read(root: "/p/api")
    let reads = await f.ticket.count("ticket_branch")
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": draftText, "branch": .string("ini-142-login")],
                         origin: .ui, confirmation: nil)
    #expect(await f.store.draft(thread: "T2") == "Thanks, fixed.")
    try await Task.sleep(for: .milliseconds(50))
    #expect(await f.ticket.count("ticket_branch") == reads)

    await f.ticket.set("ticket_record_write", .object(["key": .string("INI-142")]))
    try await f.dispatch("ticket_record_update", ["key": .string("INI-142"), "section": .string("next"), "op": .string("set"),
                                                  "text": .string("ship it"), "branch": .string("ini-142-login")],
                         caller: agentInSession)
    let args = try #require(await f.ticket.args("ticket_record_write"))
    #expect(args["branch"] == nil)
    #expect(args["root"] == nil)
}

/// A handed agent works in the background: with no editor pane on screen, its draft for its own
/// root and branch lands in the window's store, the window showing its organisation.
@Test func draftFromAPinnedAgentWithNoPaneIsKept() async throws {
    let f = try await ticketFixture(organization: "org", editorPane: false)
    #expect(await f.editor.layout.snapshot().panes.allSatisfy { $0.kind != "editor" })
    let out = try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": draftText,
                                                          "root": .string("/p/api"), "branch": .string("ini-142-login")],
                                   caller: agentInSession)
    #expect(await f.store.draft(thread: "T2") == "Thanks, fixed.")
    #expect(out == .object(["thread": .string("T2"), "draft": .bool(true)]))
}

/// Invariant 4: an agent of another organisation than the window's drafting writes to its own
/// organisation's drafts, through its own place's wakil-ticket (the routed caller), and leaves the
/// window's store untouched.
@Test func draftFromAnotherOrganisationLeavesTheWindowsStore() async throws {
    let f = try await ticketFixture(organization: "initech", editorPane: false)
    let umbrella = DispatchCaller(place: Place(organization: "umbrella", project: "api", environment: "staging"),
                                  session: "s1", conversation: "c1")
    let out = try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": draftText,
                                                          "root": .string("/p/api"), "branch": .string("ini-142-login")],
                                   caller: umbrella)
    #expect(out == .object(["thread": .string("T2"), "draft": .bool(true)]))
    let args = try #require(await f.ticket.args("ticket_draft_write"))
    #expect(args == ["thread": .string("T2"), "text": draftText, "by": .string("agent"), "conversation": .string("c1"),
                     "root": .string("/p/api"), "branch": .string("ini-142-login")])
    #expect(await f.store.draft(thread: "T2") == nil)
    #expect(await f.store.allDrafts().isEmpty)
}

/// A record line names its root and branch to wakil-ticket; the operator's re-reads that root.
@Test(.timeLimit(.minutes(1))) func recordUpdatePassesRootAndBranch() async throws {
    let f = try await ticketFixture()
    await f.ticket.set("ticket_record_write", .object(["key": .string("INI-142")]))
    let params: [String: JSONValue] = ["key": .string("INI-142"), "section": .string("next"), "op": .string("set"),
                                       "text": .string("answer the review"),
                                       "root": .string("/p/api"), "branch": .string("ini-142-login")]
    try await f.dispatch("ticket_record_update", params, caller: agentInSession)
    let args = try #require(await f.ticket.args("ticket_record_write"))
    #expect(args["root"] == .string("/p/api"))
    #expect(args["branch"] == .string("ini-142-login"))
    #expect(args["conversation"] == .string("c1"))

    _ = try await f.store.read(root: "/p/api")
    let reads = await f.ticket.count("ticket_branch")
    try await f.dispatch("ticket_record_update", params, origin: .ui, confirmation: nil)
    while await f.ticket.count("ticket_branch") == reads { try await Task.sleep(for: .milliseconds(1)) }

    var outside = params
    outside["root"] = .string("/elsewhere")
    let writes = await f.ticket.count("ticket_record_write")
    await #expect { try await f.dispatch("ticket_record_update", outside, caller: agentInSession) } throws: { error in
        if case GitActionError.notAProjectRoot = error { return true }
        return false
    }
    #expect(await f.ticket.count("ticket_record_write") == writes)
}

// MARK: Ticket noticing, Task 4 — drafts survive a quit and say who wrote them

/// `by` comes from who dispatched, never from params; an agent's names its conversation.
@Test func draftByComesFromOriginNotParams() async throws {
    let f = try await ticketFixture()
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": draftText, "by": .string("operator"),
                                                "conversation": .string("forged")],
                         caller: .test("staging", conversation: "c1"))
    let args = try #require(await f.ticket.args("ticket_draft_write"))
    #expect(args["by"] == .string("agent"))
    #expect(args["conversation"] == .string("c1"))
    #expect(await f.store.draftRecord(thread: "T2")?.by == "agent")

    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed in abc123."),
                                                "by": .string("agent")],
                         origin: .ui, caller: .test("staging", conversation: "c1"), confirmation: nil)
    let mine = try #require(await f.ticket.args("ticket_draft_write"))
    #expect(mine["by"] == .string("operator"))
    #expect(mine["conversation"] == nil)
}

/// An agent's draft replaces the operator's (Rule 7) and the operator's text is kept as replaced.
@Test func agentDraftOverOperatorsKeepsReplaced() async throws {
    let f = try await ticketFixture()
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("my words")],
                         origin: .ui, confirmation: nil)
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("the agent's words")],
                         caller: agentInSession)
    #expect(await f.store.draft(thread: "T2") == "the agent's words")
    let d = try #require(await f.store.draftRecord(thread: "T2"))
    #expect(d.by == "agent")
    #expect(d.conversation == "c1")
    #expect(d.replaced == "my words")
}

/// Restore yours: one click, the operator's text back as the operator's, replaced cleared.
@Test func restorePutsTheOperatorsBack() async throws {
    let f = try await ticketFixture()
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("my words")],
                         origin: .ui, confirmation: nil)
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("the agent's words")],
                         caller: agentInSession)
    let out = try await f.dispatch("review_reply_draft_restore", ["thread": .string("T2")], origin: .ui, confirmation: nil)
    #expect(out == .object(["thread": .string("T2"), "draft": .bool(true)]))
    let args = try #require(await f.ticket.args("ticket_draft_write"))
    #expect(args["text"] == .string("my words"))
    #expect(args["by"] == .string("operator"))
    #expect(await f.store.draft(thread: "T2") == "my words")
    let d = try #require(await f.store.draftRecord(thread: "T2"))
    #expect(d.by == "operator")
    #expect(d.replaced == nil)

    // Nothing replaced: nothing to restore, said whole, nothing written.
    let writes = await f.ticket.count("ticket_draft_write")
    await #expect { try await f.dispatch("review_reply_draft_restore", ["thread": .string("T2")], origin: .ui, confirmation: nil) }
        throws: { "\($0)".contains("no draft of yours") }
    #expect(await f.ticket.count("ticket_draft_write") == writes)
}

/// A posted reply removes the thread's entry from the organisation's file, not only from memory.
@Test func sendSuccessRemovesTheDraftEntry() async throws {
    let f = try await ticketFixture()
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": draftText], caller: agentInSession)
    #expect(await f.ticket.drafts["T2"] != nil)
    try await f.dispatch("review_reply_send", replyParams)
    #expect(await f.ticket.drafts["T2"] == nil)
    #expect(await f.store.draft(thread: "T2") == nil)
    #expect(await f.store.draftRecord(thread: "T2") == nil)
    let args = try #require(await f.ticket.args("ticket_draft_write"))
    #expect(args["thread"] == .string("T2"))
    #expect(args["text"] == nil)
}

/// A failed post keeps the draft in the file too: a quit after it loses nothing.
@Test func sendFailureKeepsTheDraft() async throws {
    let f = try await ticketFixture()
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": draftText], caller: agentInSession)
    await f.ticket.fail("review_reply", "GitHub said: Resource not accessible by integration")
    await #expect { try await f.dispatch("review_reply_send", replyParams) } throws: { _ in true }
    #expect(await f.store.draft(thread: "T2") == "Thanks, fixed.")
    #expect(await f.ticket.drafts["T2"] != nil)
    let relaunched = EditorTicketStore(ticket: f.ticket)
    try await relaunched.loadDrafts()
    #expect(await relaunched.draftRecord(thread: "T2")?.by == "agent")
}

/// A write wakil-ticket refuses is said whole, and the store keeps what it had.
@Test func aRefusedDraftWriteIsSaidWhole() async throws {
    let f = try await ticketFixture()
    await f.ticket.fail("ticket_draft_write", "drafts are not readable: unexpected end of JSON input")
    await #expect { try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": draftText], origin: .ui,
                                         confirmation: nil) }
        throws: { "\($0)".contains("unexpected end of JSON input") }
    #expect(await f.store.draft(thread: "T2") == nil)
}

// MARK: Task 4 fix round 1

/// The agent's draft over the operator's, as Send finds it: the box's field holds the agent's words.
private func agentOverMine(_ f: TicketFixture) async throws {
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("my words")],
                         origin: .ui, confirmation: nil)
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed.")],
                         caller: agentInSession)
}

/// Send writes the field's text as the draft first (EditorPane): unchanged text is not an edit, so a
/// Send declined at the gate keeps the agent's draft as the agent's, and the operator's replaced one.
@Test func aDeclinedSendKeepsTheAgentsDraftAndYourReplacedOne() async throws {
    let f = try await ticketFixture()
    try await agentOverMine(f)
    let writes = await f.ticket.count("ticket_draft_write")
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed.")],
                         origin: .ui, confirmation: nil)
    #expect(await f.ticket.count("ticket_draft_write") == writes)
    await #expect { try await f.dispatch("review_reply_send", replyParams, origin: .ui, confirmation: nil) }
        throws: { isNeedsConfirmation($0) }
    let d = try #require(await f.store.draftRecord(thread: "T2"))
    #expect(d.by == "agent")
    #expect(d.replaced == "my words")
    #expect(await f.ticket.count("review_reply") == 0)
}

/// Likewise when GitHub refuses the post.
@Test func aFailedSendKeepsTheAgentsDraftAndYourReplacedOne() async throws {
    let f = try await ticketFixture()
    try await agentOverMine(f)
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed.")],
                         origin: .ui, confirmation: nil)
    await f.ticket.fail("review_reply", "GitHub said: Resource not accessible by integration")
    await #expect { try await f.dispatch("review_reply_send", replyParams, origin: .ui) } throws: { _ in true }
    let d = try #require(await f.store.draftRecord(thread: "T2"))
    #expect(d.by == "agent")
    #expect(d.replaced == "my words")
    #expect(await f.ticket.drafts["T2"] != nil)
}

/// The operator Sending the agent's words unchanged posts them and clears the draft; the post is the
/// operator's own account's on GitHub, the draft's author untouched until then.
@Test func anUnchangedSendPostsAndClearsTheDraft() async throws {
    let f = try await ticketFixture()
    try await agentOverMine(f)
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed.")],
                         origin: .ui, confirmation: nil)
    try await f.dispatch("review_reply_send", replyParams, origin: .ui)
    #expect(await f.ticket.args("review_reply")?["body"] == .string("Thanks, fixed."))
    #expect(await f.store.draftRecord(thread: "T2") == nil)
    #expect(await f.ticket.drafts["T2"] == nil)
}

/// An operator's edit to the agent's words is the operator's draft: by operator, replaced cleared.
@Test func aChangedTextThenSendWritesByOperator() async throws {
    let f = try await ticketFixture()
    try await agentOverMine(f)
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed in abc123.")],
                         origin: .ui, confirmation: nil)
    let d = try #require(await f.store.draftRecord(thread: "T2"))
    #expect(d.by == "operator")
    #expect(d.replaced == nil)
    var params = replyParams
    params["body"] = .string("Thanks, fixed in abc123.")
    await #expect { try await f.dispatch("review_reply_send", params, origin: .ui, confirmation: nil) }
        throws: { isNeedsConfirmation($0) }
    #expect(await f.store.draftRecord(thread: "T2")?.text == "Thanks, fixed in abc123.")
}

/// Invariant 4: an agent session of another organisation cannot restore a draft in the window's
/// organisation's file; nothing is written.
@Test func restoreFromAnotherOrganisationIsRefused() async throws {
    let f = try await ticketFixture(organization: "initech")
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("my words")],
                         origin: .ui, confirmation: nil)
    try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("the agent's words")],
                         caller: .test("staging", conversation: "c1"))
    let umbrella = DispatchCaller(place: Place(organization: "umbrella", project: "api", environment: "staging"),
                                  session: "s1", conversation: "c9")
    let writes = await f.ticket.count("ticket_draft_write")
    await #expect { try await f.dispatch("review_reply_draft_restore", ["thread": .string("T2")], caller: umbrella) }
        throws: { "\($0)".contains("umbrella") && "\($0)".contains("nothing was written") }
    #expect(await f.ticket.count("ticket_draft_write") == writes)
    #expect(await f.store.draftRecord(thread: "T2")?.replaced == "my words")
}

/// Rule 8: a drafts load that fails is said whole where the Ticket view shows its read errors, and
/// a load that comes back clears it.
@Test func aFailedDraftsLoadIsShownWhole() async throws {
    let f = try await ticketFixture()
    await f.ticket.fail("ticket_drafts", "drafts /h/.wakil/orgs/org/tickets/drafts.json are not readable: unexpected end of JSON input")
    await #expect { try await f.store.loadDrafts() } throws: { _ in true }
    let line = "Reply drafts could not be read: drafts /h/.wakil/orgs/org/tickets/drafts.json are not readable: unexpected end of JSON input"
    #expect(await f.store.draftsFailure() == line)
    var v = await f.editor.panes.editorTicketView()
    for _ in 0..<1_000 where v.draftsFailure == nil {
        try await Task.sleep(for: .milliseconds(1))
        v = await f.editor.panes.editorTicketView()
    }
    #expect(v.draftsFailure == line)

    await f.ticket.fail("ticket_drafts", nil)
    try await f.store.loadDrafts()
    #expect(await f.store.draftsFailure() == nil)
    await f.store.reset()
    #expect(await f.store.draftsFailure() == nil)
}

/// Waits, a bounded while, for the fake to have been called `n` times with `tool`.
private func awaitCalls(_ f: TicketFixture, _ tool: String, _ n: Int) async {
    for _ in 0..<500 where await f.ticket.count(tool) < n { try? await Task.sleep(for: .milliseconds(10)) }
}

/// The calls' names in order, for "the root, then In flight".
private func names(_ f: TicketFixture) async -> [String] { await f.ticket.calls.map(\.name) }

/// Send reads its root's branch again, then In flight (spec, *When it reads*).
@Test func sendThenInFlightIsRead() async throws {
    let f = try await ticketFixture()
    try await f.dispatch("ticket_read", ["root": .string("/p/api")])
    #expect(await f.ticket.count("ticket_in_flight") == 0)
    try await f.dispatch("review_reply_send", replyParams, origin: .ui)
    await awaitCalls(f, "ticket_in_flight", 1)
    #expect(await f.ticket.count("ticket_in_flight") == 1)
    let calls = await names(f)
    #expect(calls.lastIndex(of: "ticket_branch")! < calls.lastIndex(of: "ticket_in_flight")!)
    #expect(calls.firstIndex(of: "review_reply")! < calls.lastIndex(of: "ticket_branch")!)
}

@Test func resolveThenInFlightIsRead() async throws {
    let f = try await ticketFixture()
    try await f.dispatch("ticket_read", ["root": .string("/p/api")])
    try await f.dispatch("review_resolve", ["root": .string("/p/api"), "thread": .string("T2"), "resolved": .bool(true)],
                         origin: .ui, confirmation: nil)
    await awaitCalls(f, "ticket_in_flight", 1)
    let calls = await names(f)
    #expect(calls.filter { $0 == "ticket_branch" }.count == 2)
    #expect(calls.lastIndex(of: "ticket_branch")! < calls.lastIndex(of: "ticket_in_flight")!)
}

/// ↻ reads the view's branch, then In flight, even off the default branch.
@Test func refreshThenInFlightIsRead() async throws {
    let f = try await ticketFixture()
    try await f.dispatch("ticket_refresh", ["pane": .string(f.editor.pane)], origin: .ui)
    #expect(await f.ticket.count("ticket_in_flight") == 1)
    let calls = await names(f)
    #expect(calls.lastIndex(of: "ticket_branch")! < calls.lastIndex(of: "ticket_in_flight")!)
}

/// A push from Wakil reads its root again, then In flight.
@Test func pushThenInFlightIsRead() async throws {
    let f = try await ticketFixture()
    await registerEditorChangesWrites(into: f.editor.registry, gitStatus: f.editor.status, panes: f.editor.panes,
                                      layout: f.editor.layout, writes: GitWriteFlights(), ticket: f.store)
    try await f.dispatch("ticket_read", ["root": .string("/p/api")])
    try await f.dispatch("editor_changes_push", ["root": .string("/p/api")], origin: .ui)
    await awaitCalls(f, "ticket_in_flight", 1)
    let calls = await names(f)
    #expect(calls.filter { $0 == "ticket_branch" }.count == 2)
    #expect(calls.lastIndex(of: "ticket_branch")! < calls.lastIndex(of: "ticket_in_flight")!)
}

/// `ticket_in_flight` answers the count and its items (`needs`), one per item, beside the rows.
@Test func inFlightReplyCarriesCountAndNeeds() async throws {
    let f = try await ticketFixture()
    func row(_ key: String, _ pr: Int, threads: [String] = [], failing: [String] = [], review: Bool = false) -> JSONValue {
        .object(["key": .string(key), "repo": .string("github.com/initech/api"), "pr": .integer(Int64(pr)),
                 "threads": .array(threads.map { .string($0) }), "failing": .array(failing.map { .string($0) }),
                 "review": .bool(review), "count": .integer(Int64(threads.count + (failing.isEmpty ? 0 : 1) + (review ? 1 : 0)))])
    }
    await f.ticket.set("ticket_in_flight", .object([
        "waitingOnYou": .array([row("INI-142", 212, threads: ["T1", "T2"], failing: ["unit (Linux)"]), row("", 214, review: true)]),
        "inFlight": .array([]), "partial": .array([]), "count": .integer(4),
    ]))
    // The window's read, and an agent session's through its own place's client.
    for (origin, caller) in [(ActionOrigin.ui, DispatchCaller.test("staging")),
                             (.agent, DispatchCaller.test("staging", session: "s1", conversation: "c1"))] {
        let out = try await f.dispatch("ticket_in_flight", origin: origin, caller: caller)
        guard case .object(let o) = out else { Issue.record("reply \(out)"); return }
        #expect(o["count"] == .integer(4))
        #expect(o["needs"] == .array([
            .object(["kind": .string("review thread"), "key": .string("INI-142"), "repo": .string("github.com/initech/api"),
                     "pr": .integer(212), "thread": .string("T1")]),
            .object(["kind": .string("review thread"), "key": .string("INI-142"), "repo": .string("github.com/initech/api"),
                     "pr": .integer(212), "thread": .string("T2")]),
            .object(["kind": .string("failing check"), "key": .string("INI-142"), "repo": .string("github.com/initech/api"),
                     "pr": .integer(212), "checks": .array([.string("unit (Linux)")])]),
            .object(["kind": .string("review request"), "key": .string(""), "repo": .string("github.com/initech/api"),
                     "pr": .integer(214)]),
        ]))
        #expect(o["waitingOnYou"] != nil)
    }
}
