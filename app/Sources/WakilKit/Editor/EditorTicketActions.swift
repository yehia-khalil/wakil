import Foundation

/// A ticket or review action's refusal, whole (Rule 8).
struct TicketActionError: Error, Sendable, CustomStringConvertible { let description: String }

/// What the ticket actions borrow from the editor's own (`registerEditorActions`): which pane an
/// action means, its reply, the one serial way a column changes, and opening a file at a line.
struct EditorTicketHooks: Sendable {
    /// The named pane, else the focused editor pane, else the first, else a new one.
    let pane: @Sendable (JSONValue, String) async throws -> String
    /// The pane's `read_pane` plus its id.
    let reply: @Sendable (String) async -> JSONValue
    let updateColumn: @Sendable (String, @escaping @Sendable (inout EditorColumnState) -> Void) async -> EditorColumnState
    /// Opens `path` in `pane` at `line` (`editor_open`'s body), the column untouched.
    let openFile: @Sendable (_ pane: String, _ path: String, _ line: Int) async throws -> Void
    /// Reads these head texts into the panes' review state now (`git_show` rev `commit:<sha>`), so a
    /// thread's box can be placed before its file opens at it.
    var readHeads: @Sendable ([EditorReviewHead]) async -> Void = { _ in }
}

/// The Ticket view's readable state, kept store-wide for every editor pane (Invariant 3):
/// `EditorPaneKind.readPane` picks the root a pane follows from its own front tab at read time.
/// Draft text is never in it — only which threads have one, and who wrote it.
public struct EditorTicketMirror: Sendable, Equatable {
    public struct PR: Sendable, Equatable { public let number: Int; public let state: String; public let openThreads: Int }
    public struct Root: Sendable, Equatable {
        public let branch: String?
        public let tickets: [String]
        public let marked: String?
        public let prs: [PR]
        public let reading: Bool
        public let error: String?
    }
    /// The project's roots in order: the view follows the first when no file is in front.
    public var roots: [String]
    public var byRoot: [String: Root]
    /// Which threads have a draft and who wrote it (`operator` or `agent`), by thread id; never the text.
    public struct Draft: Sendable, Equatable { public let thread: String; public let by: String }
    public var drafts: [Draft]
    public static let empty = EditorTicketMirror(roots: [], byRoot: [:], drafts: [])

    /// The `ticket` key of a pane whose front tab is in `front`.
    func json(front: String?) -> JSONValue {
        guard let root = ticketFollowedRoot(front: front, roots: roots) else { return .null }
        let r = byRoot[root]
        return .object([
            "root": .string(root),
            "branch": r?.branch.map { .string($0) } ?? .null,
            "tickets": .array((r?.tickets ?? []).map { .string($0) }),
            "marked": r?.marked.map { .string($0) } ?? .null,
            "prs": .array((r?.prs ?? []).map { p in
                .object(["number": .integer(Int64(p.number)), "state": .string(p.state),
                         "openThreads": .integer(Int64(p.openThreads))]) }),
            "drafts": .array(drafts.map { .object(["thread": .string($0.thread), "by": .string($0.by)]) }),
            "reading": .bool(r?.reading ?? false),
            "error": r?.error.map { .string($0) } ?? .null,
        ])
    }
}

/// The root of an editor snapshot's front tab: a file's, or a diff's; nil for a scratch.
func editorFrontRoot(_ s: EditorSnapshot) -> String? {
    guard let i = s.active, i < s.tabs.count else { return nil }
    switch s.tabs[i].subject {
    case .file(_, let root): return root
    case .diff(let root, _, _, _): return root
    case .scratch: return nil
    }
}

/// Registers the Ticket view's eleven actions (spec, *Actions*). Every write — a record line, a link,
/// a draft, a reply, a resolve — is one of these, for the operator and the agent alike (Invariant 2).
/// `by` on a record line comes from who dispatched (`ticketBy`), never from params.
func registerTicketActions(
    into registry: ActionRegistry, store: EditorTicketStore, panes: PaneStore, layout: LayoutStore?,
    editor: EditorTicketHooks, roots: @escaping @Sendable () async -> [String],
    organization: @escaping @Sendable () async -> String? = { nil }
) async {
    @Sendable func mirror() async {
        let rs = await roots()
        var byRoot: [String: EditorTicketMirror.Root] = [:]
        var reviews: [String: EditorReviewsState.Root] = [:]
        for root in Set(rs).union(await store.roots()) {
            let b = await store.branch(root: root)
            byRoot[root] = EditorTicketMirror.Root(
                branch: b?.branch, tickets: b?.tickets.map(\.key) ?? [], marked: b?.tickets.first(where: \.marked)?.key,
                prs: b?.prs.map { .init(number: $0.number, state: $0.state, openThreads: reviewOpenThreads([$0]).count) } ?? [],
                reading: await store.reading(root: root), error: await store.failure(root: root))
            if let b { reviews[root] = .init(viewer: b.viewer, threads: b.prs.flatMap(\.threads)) }
        }
        let records = await store.allDraftRecords()
        let drafts = records.mapValues(\.text)
        var branches: [String: TicketBranchState] = [:]
        for root in byRoot.keys { if let b = await store.branch(root: root) { branches[root] = b } }
        let view = EditorTicketViewState(roots: rs, branches: branches, reading: await store.readingRoots(),
                                         failures: await store.allFailures(), inFlight: await store.lastInFlight(),
                                         records: await store.shownRecords(),
                                         recordFailures: await store.shownRecordFailures(),
                                         shownBranches: await store.shownBranches(),
                                         shownBranchFailures: await store.shownBranchFailures(),
                                         draftsFailure: await store.draftsFailure())
        await panes.setEditorTicketMirror(
            EditorTicketMirror(roots: rs, byRoot: byRoot,
                               drafts: records.keys.sorted().map { .init(thread: $0, by: records[$0]?.by ?? "") }),
            reviews: EditorReviewsState.Reads(byRoot: reviews, drafts: drafts, sending: await store.allSending(),
                                              answers: await store.allAnswers(), draftRecords: records),
            view: view)
    }
    await store.setOnChange { await mirror() }

    @Sendable func param(_ params: JSONValue, _ key: String, _ action: String) throws -> String {
        guard let v = optionalString(params, key) else { throw StandardActionError.missingParam(action: action, param: key) }
        return v
    }
    @Sendable func projectRoot(_ params: JSONValue, _ action: String) async throws -> String {
        let root = try param(params, "root", action)
        let all = await roots()
        guard all.contains(root) else { throw GitActionError.notAProjectRoot(action: action, root: root, roots: all) }
        return root
    }
    /// The place a draft or a record line names: `root`, checked as `projectRoot` checks it, with
    /// its `branch`. A branch without a root names no place and is dropped (Rule 7); nil without a root.
    @Sendable func namedPlace(_ params: JSONValue, _ action: String) async throws -> (root: String, branch: String?)? {
        guard optionalString(params, "root")?.isEmpty == false else { return nil }
        let root = try await projectRoot(params, action)
        return (root, optionalString(params, "branch").flatMap { $0.isEmpty ? nil : $0 })
    }
    /// A write named its place: the window's read of that root takes it with no editor pane on
    /// screen — read again for the window's own caller; for an agent session's, only a ticket shown
    /// at that root, since its root is its place's and the window's cache is the window's (Invariant 4).
    @Sendable func landed(at place: (root: String, branch: String?)) async {
        if pinned() { await store.refreshShown(root: place.root, branch: place.branch) } else { await store.invalidate(root: place.root) }
    }
    @Sendable func followed(_ pane: String) async -> String? {
        ticketFollowedRoot(front: editorFrontRoot(await panes.editorSnapshot(paneId: pane)), roots: await roots())
    }
    @Sendable func call(_ tool: String, _ args: [String: JSONValue], action: String,
                        timeout: TimeInterval = MCPClient.readReplyTimeout) async throws -> [String: JSONValue] {
        guard let ticket = store.ticket else { throw StandardActionError.missingClient(action: action, role: "ticket") }
        do {
            return try await ticketCall(ticket, tool, args, timeout: timeout)
        } catch let e as TicketReadError {
            throw StandardActionError.serverError(action: action, message: e.description)
        }
    }
    /// The line a thread's file opens at in `pane`: its box's, when the file is open there and placed;
    /// GitHub's otherwise.
    @Sendable func placedLine(_ t: ReviewThreadState, pane: String) async -> Int {
        let path = t.root + "/" + t.path
        let tab = await panes.editorSnapshot(paneId: pane).tabs.first { $0.path == path && $0.diffState == nil }
        return editorReviewLine(t, tab: tab, await panes.editorReviews())
    }
    /// Opens a thread's file at its box: a file not placed yet (not open, or its head text not read)
    /// has its head text read here, and the cursor moved onto the box once it is placed — so the
    /// box ⌥↓ steps to is on the cursor's line, never a line the box is not on.
    @Sendable func openThread(_ t: ReviewThreadState, pane: String) async throws {
        let path = t.root + "/" + t.path
        try await editor.openFile(pane, path, await placedLine(t, pane: pane))
        guard let tab = await panes.editorSnapshot(paneId: pane).tabs.first(where: { $0.path == path && $0.diffState == nil })
        else { return }
        let wanted = editorReviewHeadsWanted(tab, await panes.editorReviews())
        guard !wanted.isEmpty else { return }
        await editor.readHeads(wanted)
        let line = await placedLine(t, pane: pane)
        if line != tab.cursor.line { try await editor.openFile(pane, path, line) }
    }
    /// Whether an agent session made the running dispatch: its reads go through its own place's
    /// client and answer it alone, never the window's cache, which holds the window's organisation.
    @Sendable func pinned() -> Bool { pinnedPlace(of: ActionRegistry.dispatchCaller) != nil }
    /// Writes a thread's draft (nil text removes it), `by` from who dispatched and an agent's
    /// conversation, never params. Into the window's store, through the window's own client, unless an
    /// agent session of another organisation than the window's asked: then into its organisation's
    /// drafts only, through its own place's wakil-ticket, the window's store untouched (Invariant 4).
    @Sendable func writeDraft(thread: String, text: String?, place: (root: String, branch: String?)?,
                              action: String) async throws {
        let origin = ActionRegistry.dispatchOrigin
        let by = ticketDraftBy(origin)
        let conversation = origin == .agent ? ActionRegistry.dispatchCaller?.conversation : nil
        if let away = pinnedPlace(of: ActionRegistry.dispatchCaller), away.organization != (await organization()) {
            var args: [String: JSONValue] = ["thread": .string(thread), "by": .string(by)]
            if let text, !text.isEmpty { args["text"] = .string(text) }
            if let conversation, !conversation.isEmpty { args["conversation"] = .string(conversation) }
            if let place {
                args["root"] = .string(place.root)
                if let b = place.branch { args["branch"] = .string(b) }
            }
            _ = try await call("ticket_draft_write", args, action: action, timeout: MCPClient.mutationReplyTimeout)
            return
        }
        do {
            try await store.setDraft(thread: thread, text: text, by: by, conversation: conversation,
                                     root: place?.root, branch: place?.branch)
        } catch let e as TicketReadError {
            throw StandardActionError.serverError(action: action, message: e.description)
        }
    }
    /// The focused editor pane, else the first; nil when none is open (a read opens no pane).
    @Sendable func frontPane() async -> String? {
        guard let snap = await layout?.snapshot() else { return nil }
        let editors = snap.panes.filter { $0.kind == "editor" }
        if let focused = snap.focusedId, editors.contains(where: { $0.id == focused }) { return focused }
        return editors.first?.id
    }
    /// The root's read: the view's branch, joined to one in flight; the default branch reads In
    /// flight too.
    @Sendable func read(_ root: String) async throws -> TicketBranchState {
        let state = try await store.read(root: root)
        if state.longLived { _ = try? await store.inFlight() }
        return state
    }
    /// Where a review thread is, as GitHub says: the plane names a reply's or a resolve's place
    /// from this, never from the caller's params (Invariants 6 and 7). The operator's own write may
    /// take a thread the window has already read; an agent's is always asked of GitHub, through its
    /// own place's client.
    struct ThreadPlace { let repo: String; let number: Int; let path: String; let line: Int }
    @Sendable func threadPlace(root: String, thread: String, action: String) async throws -> ThreadPlace {
        if !pinned(), let t = await store.thread(thread), t.root == root {
            return ThreadPlace(repo: ticketRepoName(t.repo), number: t.number, path: t.path, line: t.line)
        }
        let out = try await call("review_thread", ["root": .string(root), "thread": .string(thread)], action: action)
        guard case .string(let repo)? = out["repo"], let number = out["number"]?.intValue else {
            throw TicketActionError(description: "\(action): GitHub did not say where review thread \(thread) is; nothing was asked")
        }
        let path: String = if case .string(let p)? = out["path"] { p } else { "" }
        return ThreadPlace(repo: repo, number: number, path: path, line: out["line"]?.intValue ?? 0)
    }
    /// Refuses when the caller named another PR than the thread's own.
    @Sendable func checkNamed(_ params: JSONValue, _ t: ThreadPlace, thread: String, action: String) throws {
        guard case .object(let o) = params else { return }
        let repo = optionalString(params, "repo").map(ticketRepoName)
        let pr = o["pr"]?.intValue
        if (repo != nil && repo != t.repo) || (pr != nil && pr != t.number) {
            throw TicketActionError(description: "\(action): review thread \(thread) is on \(t.repo)#\(t.number) · "
                + "\(t.path):\(t.line), not on \(repo ?? t.repo)#\(pr.map(String.init) ?? "?") as named; nothing was asked or posted")
        }
    }

    func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) })])
    }
    let string: JSONValue = .object(["type": .string("string")])
    let integer: JSONValue = .object(["type": .string("integer")])
    let boolean: JSONValue = .object(["type": .string("boolean")])

    await registry.register(Action(
        name: "ticket_read",
        description: "Read the Ticket view's state: with key, that ticket's record (next, decisions, not done, "
            + "waiting on, verified, rulings, each line with who wrote it); else a root's branch — its tickets "
            + "with their PM status and record, its pull requests with review threads and checks, the stack, and "
            + "every source that could not be read, whole. root defaults to the focused editor's front file's root, "
            + "else the project's first. The last read is answered when there is one; ticket_refresh reads again.",
        kind: .read, audience: .agentReachable,
        schema: schema(["root": string, "key": string]),
        handler: { params in
            if let key = optionalString(params, "key"), !key.isEmpty {
                return .object(try await call("ticket_record", ["key": .string(key)], action: "ticket_read"))
            }
            let root: String
            if optionalString(params, "root") != nil {
                root = try await projectRoot(params, "ticket_read")
            } else {
                let front = await frontPane().asyncFlatMap { editorFrontRoot(await panes.editorSnapshot(paneId: $0)) }
                guard let r = ticketFollowedRoot(front: front, roots: await roots()) else {
                    throw TicketActionError(description: "ticket_read: the project has no root to read a branch of")
                }
                root = r
            }
            if pinned() {
                let out = try await call("ticket_branch", ["root": .string(root)], action: "ticket_read",
                                         timeout: EditorTicketStore.readLimit.timeInterval)
                return ticketJSON(try ticketDecode(TicketBranchState.self, out, tool: "ticket_branch"))
            }
            if let cached = await store.branch(root: root) { return ticketJSON(cached) }
            return ticketJSON(try await read(root))
        }))

    await registry.register(Action(
        name: "ticket_refresh",
        description: "Read the Ticket view's branch again now: the root the editor pane follows (its front file's "
            + "root, else the project's first). A read already running is joined, never fired twice; one past 20 s "
            + "is stopped and says so. cancel true stops the read running instead (↻'s Cancel). With no pane, the "
            + "focused or first editor pane.",
        kind: .control, audience: .agentReachable,
        schema: schema(["pane": string, "cancel": boolean]),
        handler: { params in
            let pane = try await editor.pane(params, "ticket_refresh")
            guard let root = await followed(pane) else { return await editor.reply(pane) }
            if case .object(let o) = params, o["cancel"] == .bool(true) {
                await store.cancel(root: root)
                await mirror()
                return await editor.reply(pane)
            }
            // A ticket picked from In flight is read again with it: its branch is the view's too.
            let shown = await panes.editorSnapshot(paneId: pane).column?.ticketShown
            let picked = Task { if let shown { await store.refreshShown(key: shown) } }
            do {
                _ = try await read(root)
            } catch {
                await picked.value
                // A read stopped by ↻'s Cancel (Rule 4) failed nothing: the store keeps no failure for
                // it. Any other failure is kept, whole, and answered.
                if await store.failure(root: root) != nil { throw error }
            }
            await picked.value
            return await editor.reply(pane)
        }))

    await registry.register(Action(
        name: "ticket_show",
        description: "Show a ticket in an editor pane's Ticket view by key (a row of In flight), or null for the "
            + "branch's own. root and branch pick the In flight or Waiting on you row a key is on, since two "
            + "branches can carry one ticket; without them the key's first row. The branch never switches. "
            + "Shows the column on Ticket.",
        kind: .control, audience: .agentReachable,
        schema: schema(["pane": string, "key": .object(["type": .array([.string("string"), .string("null")])]),
                        "root": string, "branch": string]),
        handler: { params in
            let pane = try await editor.pane(params, "ticket_show")
            let key = optionalString(params, "key").flatMap { $0.isEmpty ? nil : $0.uppercased() }
            // A row named by its root and branch; either alone names no row and is ignored (Rule 7).
            var named: TicketShownAt?
            if key != nil, optionalString(params, "root")?.isEmpty == false,
               let b = optionalString(params, "branch"), !b.isEmpty {
                named = TicketShownAt(root: try await projectRoot(params, "ticket_show"), branch: b)
            }
            let s = await store.lastInFlight()
            let rows = ((s?.waitingOnYou ?? []) + (s?.inFlight ?? [])).filter { $0.key == key }
            let row = named.map { at in rows.first { $0.root == at.root && $0.branch == at.branch } } ?? rows.first
            // Where the shown ticket's branch is read: the named row's, else the key's first row's.
            let at = named ?? row.flatMap { r in r.root.isEmpty || r.branch.isEmpty ? nil : TicketShownAt(root: r.root, branch: r.branch) }
            _ = await editor.updateColumn(pane) { c in
                c.ticketShown = key
                c.ticketShownAt = key == nil ? nil : at
                c.view = .ticket
                c.shown = true
            }
            // The shown ticket's record, for its header and lists, and — for a ticket the branch does not
            // carry — its own branch, read by its In flight row's root and branch, for its pull
            // requests and threads. Nothing is checked out (Rule 6); a failed read is kept whole for
            // the view (Rule 8), so the show itself does not fail.
            if let key {
                // The followed root's own read carries it — unless a row on another branch was named.
                let followedRoot = await followed(pane)
                let own = await followedRoot.asyncFlatMap { await store.branch(root: $0) }
                let carried = (own?.tickets.contains { $0.key == key } ?? false)
                    && (named == nil || (named?.root == followedRoot && named?.branch == own?.branch))
                async let record: Void = { _ = try? await store.readRecord(key: key) }()
                if !carried, let at {
                    await store.readShown(key: key, root: at.root, branch: at.branch)
                }
                await record
            }
            return await editor.reply(pane)
        }))

    await registry.register(Action(
        name: "ticket_in_flight",
        description: "Read the organization's tickets in flight (a local branch in any of its roots, or an open PR "
            + "of yours) and Waiting on you (threads on your open PRs whose last word is not yours, PRs asking for "
            + "your review, your PRs with a failing check), each with one state in words.",
        kind: .read, audience: .agentReachable,
        schema: schema([:]),
        handler: { _ in
            if pinned() {
                return .object(try await call("ticket_in_flight", [:], action: "ticket_in_flight",
                                              timeout: EditorTicketStore.readLimit.timeInterval))
            }
            do { return ticketJSON(try await store.inFlight()) } catch let e as TicketReadError {
                throw StandardActionError.serverError(action: "ticket_in_flight", message: e.description)
            }
        }))

    await registry.register(Action(
        name: "ticket_link",
        description: "Link a root's current branch to a ticket key, overriding what Wakil inferred; an empty key "
            + "unlinks, which returns the branch to inference. A key Jira cannot find is kept and says so. "
            + "Allowed everywhere: the link is Wakil's own store.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["root": string, "key": string], required: ["root", "key"]),
        handler: { params in
            let root = try await projectRoot(params, "ticket_link")
            let key = try param(params, "key", "ticket_link")
            let out = try await call("ticket_link", ["root": .string(root), "key": .string(key)], action: "ticket_link",
                                     timeout: MCPClient.mutationReplyTimeout)
            await store.invalidate(root: root)
            return .object(out)
        },
        price: (production: .allow, otherwise: .allow)))

    let lineFields = ["text", "why", "how", "who", "what"]
    await registry.register(Action(
        name: "ticket_record_update",
        description: "Write a ticket's record: section next with op set, or one line of decisions, notDone, "
            + "waitingOn, verified or rulings with op add, edit (by id; only the fields given change) or remove "
            + "(by id; the old line stays in the record's log). Who wrote it is set from who asked, never from "
            + "params. root and branch name where the ticket is worked on: the record gains that branch, and the "
            + "window takes the line with no editor pane open; a branch without a root is ignored. Allowed "
            + "everywhere: the record is Wakil's own store.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["key": string, "section": string, "op": string, "id": string, "text": string, "why": string,
                        "how": string, "who": string, "what": string, "root": string, "branch": string],
                       required: ["key", "section", "op"]),
        handler: { params in
            let action = "ticket_record_update"
            var args: [String: JSONValue] = [
                "key": .string(try param(params, "key", action)),
                "section": .string(try param(params, "section", action)),
                "op": .string(try param(params, "op", action)),
            ]
            if let id = optionalString(params, "id") { args["id"] = .string(id) }
            var line: [String: JSONValue] = [:]
            for f in lineFields { if let v = optionalString(params, f) { line[f] = .string(v) } }
            args["line"] = .object(line)
            let origin = ActionRegistry.dispatchOrigin
            args["by"] = .string(ticketBy(origin))
            if origin == .agent, let c = ActionRegistry.dispatchCaller?.conversation { args["conversation"] = .string(c) }
            let place = try await namedPlace(params, action)
            if let place {
                args["root"] = .string(place.root)
                if let b = place.branch { args["branch"] = .string(b) }
            }
            let out = try await call("ticket_record_write", args, action: action, timeout: MCPClient.mutationReplyTimeout)
            // An agent session's write went through its own place's client: the window's cache keeps
            // the window's organisation, and takes the line on its next read (Invariant 4).
            if !pinned(), let record = try? ticketDecode(TicketRecordState.self, out, tool: "ticket_record_write") {
                await store.setRecord(record)
            }
            if let place { await landed(at: place) }
            return .object(out)
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "review_open",
        description: "Open a review thread's file at its line in an editor pane; the column stays where it was. "
            + "thread is the thread's id from ticket_read. With no pane, the focused or first editor pane.",
        kind: .control, audience: .agentReachable,
        schema: schema(["thread": string, "pane": string], required: ["thread"]),
        handler: { params in
            let id = try param(params, "thread", "review_open")
            guard let t = await store.thread(id) else {
                throw TicketActionError(description: "review_open: no review thread \(id) in the ticket reads; ticket_refresh reads them again")
            }
            let pane = try await editor.pane(params, "review_open")
            try await openThread(t, pane: pane)
            return await editor.reply(pane)
        }))

    await registry.register(Action(
        name: "review_step",
        description: "Open the next (delta 1) or previous (delta -1) open review thread of the branch the editor "
            + "pane follows, across files, wrapping; from is the thread to step from, else the one under the "
            + "cursor, else the start. The column stays where it was.",
        kind: .control, audience: .agentReachable,
        schema: schema(["delta": integer, "from": string, "pane": string], required: ["delta"]),
        handler: { params in
            guard case .object(let o) = params, let delta = o["delta"]?.intValue else {
                throw StandardActionError.missingParam(action: "review_step", param: "delta")
            }
            let pane = try await editor.pane(params, "review_step")
            let threads = await followed(pane).asyncFlatMap { await store.branch(root: $0) }.map { reviewOpenThreads($0.prs) } ?? []
            var from = optionalString(params, "from")
            if from == nil {
                // The thread whose box is on the cursor's line, as placed.
                let s = await panes.editorSnapshot(paneId: pane)
                from = editorCursorThread(s.active.flatMap { $0 < s.tabs.count ? s.tabs[$0] : nil }, await panes.editorReviews())
            }
            guard let t = reviewStep(threads, from: from, delta: delta) else {
                throw TicketActionError(description: "review_step: the branch has no open review threads")
            }
            try await openThread(t, pane: pane)
            guard case .object(var reply) = await editor.reply(pane) else { return .null }
            reply["thread"] = .string(t.id)
            reply["position"] = .string(reviewPosition(threads, id: t.id))
            return .object(reply)
        }))

    await registry.register(Action(
        name: "review_reply_draft",
        description: "Keep a review thread's reply draft in the organization's drafts, kept across quits; empty "
            + "or null text drops it. Who wrote it is set from who asked, never from params; an agent's draft "
            + "over the operator's keeps theirs for Restore yours. root and branch name the thread's place, so "
            + "the draft lands with no editor pane open; a branch without a root is ignored. Nothing is posted: "
            + "review_reply_send does that.",
        kind: .control, audience: .agentReachable,
        schema: schema(["thread": string, "text": .object(["type": .array([.string("string"), .string("null")])]),
                        "root": string, "branch": string],
                       required: ["thread"]),
        handler: { params in
            let action = "review_reply_draft"
            let thread = try param(params, "thread", action)
            let place = try await namedPlace(params, action)
            let text = optionalString(params, "text")
            try await writeDraft(thread: thread, text: text, place: place, action: action)
            await mirror()
            if let place { await landed(at: place) }
            return .object(["thread": .string(thread), "draft": .bool(!(text ?? "").isEmpty)])
        }))

    await registry.register(Action(
        name: "review_reply_draft_restore",
        description: "Restore yours: put back the operator's reply draft on a review thread that an agent's "
            + "draft replaced, as the operator's. Refused when no draft of theirs was replaced. Nothing is posted.",
        kind: .control, audience: .agentReachable,
        schema: schema(["thread": string], required: ["thread"]),
        handler: { params in
            let action = "review_reply_draft_restore"
            let thread = try param(params, "thread", action)
            // The store holds the window's organisation's drafts alone (Invariant 4): an agent session
            // of another organisation restores nothing in it.
            if let away = pinnedPlace(of: ActionRegistry.dispatchCaller), away.organization != (await organization()) {
                throw TicketActionError(description: "\(action): this window shows another organisation than "
                    + "\(away.organization); nothing was written")
            }
            do {
                try await store.restoreDraft(thread: thread)
            } catch let e as TicketReadError {
                throw TicketActionError(description: "\(action): \(e.description); nothing was written")
            }
            await mirror()
            return .object(["thread": .string(thread), "draft": .bool(await store.draft(thread: thread) != nil)])
        }))

    await registry.register(Action(
        name: "review_reply_send",
        description: "Post body, verbatim, as a reply in a review thread with the organization's GitHub account for "
            + "root's remote. repo (initech/api) and pr name where it goes on the confirmation plane, with path and "
            + "line when given. Gated for every channel: the plane shows the exact text. The thread's draft stays "
            + "until the post succeeds; a reply already being sent to the thread is not sent twice.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["root": string, "repo": string, "pr": integer, "thread": string, "body": string,
                        "path": string, "line": integer],
                       required: ["root", "repo", "pr", "thread", "body"]),
        handler: { params in
            let action = "review_reply_send"
            let root = try await projectRoot(params, action)
            let repo = try param(params, "repo", action)
            guard case .object(let o) = params, let pr = o["pr"]?.intValue else {
                throw StandardActionError.missingParam(action: action, param: "pr")
            }
            let thread = try param(params, "thread", action)
            let body = try param(params, "body", action)
            // The plane named repo, pr, path and line from these params: a thread Wakil has read must be
            // where they say, or the operator confirmed a different place from the one posted to.
            if let t = await store.thread(thread) {
                let path = optionalString(params, "path"), line = o["line"]?.intValue
                if t.root != root || t.number != pr || ticketRepoName(t.repo) != ticketRepoName(repo)
                    || (path != nil && path != t.path) || (line != nil && line != t.line) {
                    throw TicketActionError(description: "\(action): thread \(thread) is on "
                        + "\(ticketRepoName(t.repo))#\(t.number) · \(t.path):\(t.line) in \(t.root), not where this reply names")
                }
            }
            guard await store.beginSend(thread: thread) else {
                throw TicketActionError(description: "\(action): a reply to this thread is already being sent")
            }
            await store.setAnswer(thread: thread, text: nil)
            await mirror()
            let out: [String: JSONValue]
            do {
                out = try await call("review_reply", ["root": .string(root), "thread": .string(thread), "body": .string(body)],
                                     action: action, timeout: MCPClient.mutationReplyTimeout)
            } catch {
                await store.endSend(thread: thread)
                await mirror()
                throw error
            }
            await store.endSend(thread: thread)
            // GitHub's errors beside the posted comment: posted all the same, the errors shown whole.
            var said: [String] = []
            if case .array(let errs)? = out["errors"] {
                for case .string(let e) in errs { said.append(e) }
            }
            var answer = said.isEmpty ? nil : "Posted. GitHub also answered: " + said.joined(separator: "; ")
            // Posted: the thread's entry leaves the organisation's file. A removal that fails is said
            // beside the posted reply, whole, and the store forgets the draft all the same, so no box
            // offers to send it twice.
            do {
                try await writeDraft(thread: thread, text: nil, place: nil, action: action)
            } catch {
                await store.forgetDraft(thread: thread)
                answer = (answer ?? "Posted.") + " The draft could not be removed: \(error)"
            }
            await store.setAnswer(thread: thread, text: answer)
            await mirror()
            await store.invalidate(root: root)
            return .object(out)
        },
        price: (production: .gate, otherwise: .gate),
        describe: { params in
            let action = "review_reply_send"
            let root = try await projectRoot(params, action)
            let thread = try param(params, "thread", action)
            let body = try param(params, "body", action)
            let t = try await threadPlace(root: root, thread: thread, action: action)
            try checkNamed(params, t, thread: thread, action: action)
            return reviewReplyStatement(repo: t.repo, pr: t.number, path: t.path, line: t.line, body: body)
        }))

    await registry.register(Action(
        name: "review_resolve",
        description: "Resolve (resolved true) or unresolve (false) a review thread with the organization's GitHub "
            + "account for root's remote. The operator's click runs it; the agent's ask raises the confirmation "
            + "plane. Unresolve undoes it.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["root": string, "thread": string, "resolved": boolean, "repo": string, "pr": integer,
                        "path": string, "line": integer], required: ["root", "thread", "resolved"]),
        handler: { params in
            let action = "review_resolve"
            let root = try await projectRoot(params, action)
            let thread = try param(params, "thread", action)
            guard case .object(let o) = params, case .bool(let resolved)? = o["resolved"] else {
                throw StandardActionError.missingParam(action: action, param: "resolved")
            }
            let out = try await call("review_resolve", ["root": .string(root), "thread": .string(thread),
                                                        "resolved": .bool(resolved)],
                                     action: action, timeout: MCPClient.mutationReplyTimeout)
            await store.setResolved(thread: thread, resolved: resolved)
            await store.invalidate(root: root)
            return .object(out)
        },
        price: (production: .allow, otherwise: .allow), agentPrice: .gate,
        describe: { params in
            let action = "review_resolve"
            let root = try await projectRoot(params, action)
            let thread = try param(params, "thread", action)
            let t = try await threadPlace(root: root, thread: thread, action: action)
            try checkNamed(params, t, thread: thread, action: action)
            guard case .object(let o) = params else { return "" }
            let verb = o["resolved"] == .bool(false) ? "unresolve" : "resolve"
            return "\(verb) the review thread at \(t.path):\(t.line) on \(t.repo)#\(t.number) in \((root as NSString).lastPathComponent)"
        }))
}

private extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

private extension Optional {
    func asyncFlatMap<T>(_ f: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await f(self)
    }
}
