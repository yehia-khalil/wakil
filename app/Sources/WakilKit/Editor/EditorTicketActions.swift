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
    /// Opens a new editor pane — focused or not — and answers its id (`ticket_open` with none open).
    var openEditorPane: @Sendable (_ focus: Bool) async throws -> String = { _ in
        throw TicketActionError(description: "ticket_open: no canvas to open an editor pane on")
    }
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
    /// The Hand to agent popover while it is open: its readable part (`TicketHandOffState.json`).
    public var handoff: TicketHandOffState?
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
            "handoff": handoff?.json ?? .object(["open": .bool(false)]),
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

/// Registers the Ticket view's actions (spec, *Actions*), Hand to agent's five among them. Every write — a record line, a link,
/// a draft, a reply, a resolve — is one of these, for the operator and the agent alike (Invariant 2).
/// `by` on a record line comes from who dispatched (`ticketBy`), never from params.
func registerTicketActions(
    into registry: ActionRegistry, store: EditorTicketStore, panes: PaneStore, layout: LayoutStore?,
    editor: EditorTicketHooks, roots: @escaping @Sendable () async -> [String],
    organization: @escaping @Sendable () async -> String? = { nil },
    handOff: TicketHandOffLookup? = nil
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
                                         draftsFailure: await store.draftsFailure(), handoff: await store.handOff())
        await panes.setEditorTicketMirror(
            EditorTicketMirror(roots: rs, byRoot: byRoot,
                               drafts: records.keys.sorted().map { .init(thread: $0, by: records[$0]?.by ?? "") },
                               handoff: await store.handOff()),
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
    /// A root `ticket_open` or `ticket_show` names (F7): one of `roots()` — the caller's own
    /// project's (an agent session's are its own place's, `gitRootPaths(forCaller:)`) — or another
    /// project's of the window's organisation: any root its last In flight read names, since
    /// wakil-ticket read those from the organisation's projects (and reads a branch in no other).
    /// Read only: nothing is switched or written there. That read is of the window's organisation,
    /// so an agent session of another one is checked against its own project's roots only, and
    /// refused as any root param is (Invariant 4). A refusal says which rule refused it (Rule 7).
    @Sendable func orgRoot(_ params: JSONValue, _ action: String) async throws -> String {
        let root = try param(params, "root", action)
        let own = await roots()
        if own.contains(root) { return root }
        let windowOrg = await organization()
        if let away = pinnedPlace(of: ActionRegistry.dispatchCaller), away.organization != windowOrg {
            throw GitActionError.notAProjectRoot(action: action, root: root, roots: own)
        }
        var all = own
        if let s = await store.lastInFlight() {
            for r in s.waitingOnYou + s.inFlight where !r.root.isEmpty && !all.contains(r.root) { all.append(r.root) }
        }
        guard all.contains(root) else {
            let org = windowOrg.map { $0.isEmpty ? "this organisation" : $0 } ?? "this organisation"
            throw TicketActionError(description: "\(action): \(root) is not a root of any project of \(org) "
                + "(roots: \(all.joined(separator: ", "))); nothing was shown")
        }
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
            let column = await panes.editorSnapshot(paneId: pane).column
            let shown = column?.ticketShown ?? column?.ticketShownAt.flatMap { $0.root.isEmpty ? nil : $0.id }
            let picked = Task { if let shown { await store.refreshShown(key: shown) } }
            // The view's read, then In flight (spec, *When it reads*), whichever branch the view follows.
            do {
                _ = try await store.read(root: root)
            } catch {
                _ = try? await store.inFlight()
                await picked.value
                // A read stopped by ↻'s Cancel (Rule 4) failed nothing: the store keeps no failure for
                // it. Any other failure is kept, whole, and answered.
                if await store.failure(root: root) != nil { throw error }
            }
            _ = try? await store.inFlight()
            await picked.value
            return await editor.reply(pane)
        }))

    /// Shows `key` in `pane`'s Ticket view — the row at `named`'s root and branch when given (two
    /// rows can carry one key), else the key's first — or, with no key, the keyless row at `named` (a
    /// PR with no ticket key: its own branch's read, Go's no-ticket case for it; one no project holds
    /// has no root and nothing is read), else the followed branch's own. The column goes to Ticket,
    /// scrolled nowhere; the branch never switches (Rule 6).
    @Sendable func show(_ pane: String, key: String?, named: TicketShownAt?) async {
        let followedRoot = await followed(pane)
        let own = await followedRoot.asyncFlatMap { await store.branch(root: $0) }
        guard let key else {
            // A keyless row on the followed root's current branch is the branch's own.
            let at = named.flatMap { at in at.root == followedRoot && at.branch == own?.branch ? nil : at }
            _ = await editor.updateColumn(pane) { c in
                c.ticketShown = nil
                c.ticketShownAt = at
                c.ticketScrollPR = nil
                c.view = .ticket
                c.shown = true
            }
            if let at, !at.root.isEmpty { await store.readShown(at: at) }
            return
        }
        let s = await store.lastInFlight()
        let rows = ((s?.waitingOnYou ?? []) + (s?.inFlight ?? [])).filter { $0.key == key }
        let row = named.map { at in rows.first { $0.root == at.root && $0.branch == at.branch } } ?? rows.first
        // Where the shown ticket's branch is read: the named row's, else the key's first row's.
        let at = named ?? row.flatMap { r in r.root.isEmpty || r.branch.isEmpty ? nil : TicketShownAt(root: r.root, branch: r.branch) }
        _ = await editor.updateColumn(pane) { c in
            c.ticketShown = key
            c.ticketShownAt = at
            c.ticketScrollPR = nil
            c.view = .ticket
            c.shown = true
        }
        // The shown ticket's record, for its header and lists, and — for a ticket the branch does not
        // carry — its own branch, read by its In flight row's root and branch, for its pull
        // requests and threads. Nothing is checked out (Rule 6); a failed read is kept whole for
        // the view (Rule 8), so the show itself does not fail.
        // The followed root's own read carries it — unless a row on another branch was named.
        let carried = (own?.tickets.contains { $0.key == key } ?? false)
            && (named == nil || (named?.root == followedRoot && named?.branch == own?.branch))
        async let record: Void = { _ = try? await store.readRecord(key: key) }()
        if !carried, let at, !at.root.isEmpty {
            await store.readShown(key: key, root: at.root, branch: at.branch)
        }
        await record
    }

    await registry.register(Action(
        name: "ticket_show",
        description: "Show a ticket in an editor pane's Ticket view by key (a row of In flight), or null for the "
            + "branch's own. root and branch pick the In flight or Waiting on you row a key is on, since two "
            + "branches can carry one ticket; without them the key's first row. With key null, root and branch "
            + "pick a pull request with no ticket key: that branch's own read shows. root may be any project's "
            + "of the organization. The branch never switches. Shows the column on Ticket.",
        kind: .control, audience: .agentReachable,
        schema: schema(["pane": string, "key": .object(["type": .array([.string("string"), .string("null")])]),
                        "root": string, "branch": string]),
        handler: { params in
            let pane = try await editor.pane(params, "ticket_show")
            let key = optionalString(params, "key").flatMap { $0.isEmpty ? nil : $0.uppercased() }
            // A row named by its root and branch; either alone names no row and is ignored (Rule 7).
            var named: TicketShownAt?
            if optionalString(params, "root")?.isEmpty == false,
               let b = optionalString(params, "branch"), !b.isEmpty {
                named = TicketShownAt(root: try await orgRoot(params, "ticket_show"), branch: b)
            }
            await show(pane, key: key, named: named)
            return await editor.reply(pane)
        }))

    await registry.register(Action(
        name: "ticket_open",
        description: "Open a ticket in flight: the focused editor pane, else the first, else a new one, its column on "
            + "Ticket showing key — the followed branch's own when key is null or absent. root and branch name the "
            + "row (any project's root of the organization, read only); with key null they name a pull request with "
            + "no ticket key, shown as that branch's no-ticket case. pr scrolls that pull request into view; with no "
            + "key and no root, pr and repo name a pull request no project holds, which the view opens on GitHub. "
            + "The branch never switches. Answers the pane.",
        kind: .control, audience: .agentReachable,
        schema: schema(["key": .object(["type": .array([.string("string"), .string("null")])]),
                        "root": string, "branch": string, "pr": integer, "repo": string]),
        handler: { params in
            let action = "ticket_open"
            var key = optionalString(params, "key").flatMap { $0.isEmpty ? nil : $0.uppercased() }
            let pr: Int? = if case .object(let o) = params, let n = o["pr"]?.intValue, n > 0 { n } else { nil }
            var named: TicketShownAt?
            let rooted = optionalString(params, "root")?.isEmpty == false
            if rooted {
                // Checked before any pane opens: a refused root shows nothing (Rule 7).
                let root = try await orgRoot(params, action)
                if let b = optionalString(params, "branch"), !b.isEmpty { named = TicketShownAt(root: root, branch: b) }
            } else if key == nil, let pr, let s = await store.lastInFlight() {
                // A PR no project holds, as the last In flight read has it; else pr is the followed branch's.
                let repo = optionalString(params, "repo") ?? ""
                if let r = (s.waitingOnYou + s.inFlight).first(where: { $0.root.isEmpty && $0.pr == pr && (repo.isEmpty || $0.repo == repo) }) {
                    named = TicketShownAt(root: "", branch: "", repo: r.repo, pr: pr)
                }
            }
            // The operator's own open takes the keyboard to the pane; an agent's shows the ticket there
            // and leaves the keyboard where the operator was (Rule 6).
            let focus = ActionRegistry.dispatchOrigin != .agent
            let pane: String
            if let front = await frontPane() {
                if focus { try? await layout?.focus(id: front) }
                pane = front
            } else {
                pane = try await editor.openEditorPane(focus)
            }
            // The followed branch's own ticket shows as the branch's, not as a pick.
            if let k = key, let root = await followed(pane), let own = await store.branch(root: root),
               ticketViewCase(own, shown: nil) == .ticket, own.tickets.first?.key == k,
               named == nil || (named?.root == root && named?.branch == own.branch) {
                key = nil
                named = nil
            }
            await show(pane, key: key, named: named)
            if let pr { _ = await editor.updateColumn(pane) { $0.ticketScrollPR = pr } }
            return await editor.reply(pane)
        }))

    await registry.register(Action(
        name: "ticket_in_flight",
        description: "Read the organization's tickets in flight (a local branch in any of its roots, or an open PR "
            + "of yours) and Waiting on you (threads on your open PRs whose last word is not yours, PRs asking for "
            + "your review, your PRs with a failing check), each with one state in words. count is the items waiting "
            + "on you, one per review thread, per PR with a failing check, per review request; needs lists them.",
        kind: .read, audience: .agentReachable,
        schema: schema([:]),
        handler: { _ in
            if pinned() {
                let out = try await call("ticket_in_flight", [:], action: "ticket_in_flight",
                                         timeout: EditorTicketStore.readLimit.timeInterval)
                return ticketInFlightReply(try ticketDecode(InFlightState.self, out, tool: "ticket_in_flight"))
            }
            do { return ticketInFlightReply(try await store.inFlight()) } catch let e as TicketReadError {
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
            await store.wrote(root: root)
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
            await store.wrote(root: root)
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

    // MARK: - Hand to agent (ticket noticing, Task 10)

    /// What a hand-off is handed from, read from the store (never from params beyond naming it): the
    /// ticket (nil for a PR with no key), its PR, root and branch, and the fresh brief. A row no project
    /// holds is refused: an agent needs a root (spec, *After the builder check*).
    struct HandOffSubject {
        let key: String?, pr: Int?, repo: String?, source: TicketHandOffSource
        let root, branch: String, brief: String
    }
    @Sendable func outsideRefusal(_ name: String) -> TicketActionError {
        TicketActionError(description: "ticket_hand_off_open: \(name) is \(ticketOutsideLine.lowercased()) — an agent "
            + "needs a root to work in, so it is not handed; nothing was opened")
    }
    /// The ticket of a read: the one named, else the branch's marked, else its first.
    @Sendable func ticketOf(_ b: TicketBranchState, key: String?) -> TicketRefState? {
        if let key { return b.tickets.first { $0.key == key } }
        return b.tickets.first(where: \.marked) ?? b.tickets.first
    }
    @Sendable func handOffSubject(_ params: JSONValue) async throws -> HandOffSubject {
        let action = "ticket_hand_off_open"
        let key = optionalString(params, "key").flatMap { $0.isEmpty ? nil : $0.uppercased() }
        let prParam: Int? = if case .object(let o) = params, let n = o["pr"]?.intValue, n > 0 { n } else { nil }
        if let id = optionalString(params, "thread"), !id.isEmpty {
            guard let t = await store.thread(id), let b = await store.branch(holding: id),
                  let pr = b.prs.first(where: { $0.number == t.number }) else {
                throw TicketActionError(description: "\(action): no review thread \(id) in the ticket reads; ticket_refresh reads them again")
            }
            let ticket = ticketOf(b, key: key)
            return HandOffSubject(key: ticket?.key, pr: pr.number, repo: ticket == nil && !b.repo.isEmpty ? b.repo : nil,
                                  source: .thread(id),
                                  root: t.root, branch: b.branch,
                                  brief: handOffThreadBrief(ticket: ticket, pr: pr, thread: t, root: t.root, branch: b.branch))
        }
        // From the header (or ⌘P): the named row's root and branch, else the key's first row's, else
        // the followed root's own branch.
        let s = await store.lastInFlight()
        let rows = (s?.waitingOnYou ?? []) + (s?.inFlight ?? [])
        var root = optionalString(params, "root").flatMap { $0.isEmpty ? nil : $0 }
        var branchName = optionalString(params, "branch").flatMap { $0.isEmpty ? nil : $0 }
        if let r = root { _ = try await orgRoot(.object(["root": .string(r)]), action) }
        let own = await roots()
        if root == nil, let key {
            let keyed = rows.filter { $0.key == key }
            if !keyed.isEmpty, keyed.allSatisfy({ $0.root.isEmpty }) { throw outsideRefusal(key) }
            // The key on a root of this project, as read: the followed branch's own ticket.
            var found: TicketBranchState?
            for r in own { if let b = await store.branch(root: r), b.tickets.contains(where: { $0.key == key }) { found = b; break } }
            if let found { root = found.root; branchName = found.branch }
            else if let row = keyed.first(where: { !$0.root.isEmpty }) { root = row.root; branchName = row.branch }
        }
        if root == nil, key == nil {
            if let prParam, rows.contains(where: { $0.root.isEmpty && $0.pr == prParam }) {
                throw outsideRefusal("#\(prParam)")
            }
            if let r = own.first { root = r; branchName = await store.branch(root: r)?.branch }
        }
        guard let root else {
            throw TicketActionError(description: "\(action): no root to hand \(key ?? prParam.map { "#\($0)" } ?? "this branch") "
                + "from — open it in the Ticket view first; nothing was opened")
        }
        // The read: the root's current branch's when it is the one named, else a picked ticket's or row's.
        var read: TicketBranchState?
        if let b = await store.branch(root: root), branchName == nil || b.branch == branchName { read = b }
        let shown = await store.shownBranches()
        if read == nil, let key, let b = shown[key], branchName == nil || b.branch == branchName { read = b }
        if read == nil, let branchName, let b = shown[TicketShownAt(root: root, branch: branchName).id] { read = b }
        let branch = read?.branch ?? branchName ?? ""
        var ticket = read.flatMap { ticketOf($0, key: key) }
        if ticket == nil, let key {
            // Not read yet: what In flight says of it.
            let row = rows.first { $0.key == key && $0.root == root } ?? rows.first { $0.key == key }
            ticket = TicketRefState(key: key, title: row?.title ?? "", status: row?.status ?? "")
        }
        if let t = ticket, let record = await store.shownRecords()[t.key] { ticket?.record = record }
        let prs = (read?.prs ?? []).filter { $0.state.lowercased() == "open" }
        let pr = prParam.flatMap { n in read?.prs.first { $0.number == n } } ?? prs.first ?? read?.prs.first
        guard ticket != nil || pr != nil || prParam != nil else {
            throw TicketActionError(description: "\(action): \(branch.isEmpty ? "this branch" : branch) has no ticket and no "
                + "pull request to hand to an agent; nothing was opened")
        }
        let waiting = read.map(handOffWaitingThreads) ?? []
        let failing = prs.flatMap(ticketFailingChecks)
        let brief = handOffHeaderBrief(ticket: ticket, pr: pr, waiting: waiting, failing: failing,
                                       notDone: ticket?.record.notDone ?? [], root: root, branch: branch)
        // A PR with no ticket key is kept by its repository (`pr:<repo>#<n>`); unread, it has none to name.
        let repo = ticket == nil ? read.flatMap { $0.repo.isEmpty ? nil : $0.repo } : nil
        return HandOffSubject(key: ticket?.key, pr: pr?.number ?? prParam, repo: repo,
                              source: .header, root: root, branch: branch, brief: brief)
    }
    /// A popover action's answer: its pane's `read_pane` (the `ticket` key carries the popover), else
    /// the popover's readable part alone.
    @Sendable func handOffReply(_ pane: String?) async -> JSONValue {
        if let pane, !pane.isEmpty { return await editor.reply(pane) }
        return .object(["handoff": await store.handOff()?.json ?? .object(["open": .bool(false)])])
    }
    /// The place a subject starts in (`handOffPlace`), and whether its environment is production.
    @Sendable func handOffWhere(root: String, context ctx: TicketHandOffContext) async -> (Place, Bool) {
        var project = ctx.screen.project
        if !(await roots()).contains(root) {
            let rows = (await store.lastInFlight()).map { $0.waitingOnYou + $0.inFlight } ?? []
            let row = rows.first { $0.root == root }
            project = row.map { $0.project.isEmpty ? ($0.root as NSString).lastPathComponent : $0.project } ?? project
        }
        let envs = ctx.environments[project] ?? []
        let place = handOffPlace(project: project, screen: ctx.screen, environments: envs.map { ($0.name, $0.production) },
                                 remembered: ctx.remembered[project])
        let production = envs.first { $0.name == place.environment }?.production
            ?? isProductionEnvironment(place.environment)
        return (place, production)
    }

    await registry.register(Action(
        name: "ticket_hand_off_open",
        description: "Open the Hand to agent popover, prefilled: from a review thread (thread), or from the Ticket "
            + "header for a key (with root and branch naming its row; key null with root, branch and pr for a pull "
            + "request with no ticket key). The brief kept for that ticket and thread or header comes back as edited; "
            + "reset true refills it from the source. Harness, provider and May push default to the organization's "
            + "last Start. It only opens the popover: the operator's Start hands it to an agent. Not offered for a "
            + "pull request no project holds.",
        kind: .control, audience: .agentReachable,
        schema: schema(["key": .object(["type": .array([.string("string"), .string("null")])]), "pr": integer,
                        "thread": string, "root": string, "branch": string, "reset": boolean, "from": string,
                        "pane": string]),
        handler: { params in
            let action = "ticket_hand_off_open"
            if await store.handOff()?.starting == true {
                throw TicketActionError(description: "\(action): a hand-off is starting; Cancel stops it first")
            }
            guard let handOff, let ctx = await handOff.context() else {
                throw TicketActionError(description: "\(action): no window to hand off from")
            }
            let pane = try await editor.pane(params, action)
            let subject = try await handOffSubject(params)
            let briefKey = handOffBriefKey(key: subject.key, pr: subject.pr, repo: subject.repo, source: subject.source)
            let reset = { if case .object(let o) = params { o["reset"] == .bool(true) } else { false } }()
            let byAgent = ActionRegistry.dispatchOrigin == .agent
            let open = await store.handOff()
            let same = open.map { handOffBriefKey(key: $0.key, pr: $0.pr, repo: $0.repo, source: $0.source) == briefKey } ?? false
            // An agent never replaces the operator's own popover (Rules 2 and 6): another subject is
            // refused whole, and the same one changes nothing — no reset, no focus.
            if byAgent, let open, open.focus {
                guard same else {
                    throw TicketActionError(description: "\(action): the operator is writing a hand-off for \(open.name); nothing was opened")
                }
                return await editor.reply(open.pane ?? pane)
            }
            let kept = reset ? nil : await store.keptBrief(briefKey)
            // Reopened on the same hand-off: what the operator set stays. Else the operator's open takes
            // the last Start's (Rule 9). An agent's never changes what the popover showed: on the subject
            // it last showed, its choices; on any other, May push off — only the operator ticks it.
            let d: (String, String, Bool)
            if let open, same {
                d = (open.harness, open.provider, open.mayPush)
            } else if byAgent {
                let stored = handOffDefaults(stored: await store.handoffDefaults(), current: ctx.provider)
                let last = await store.lastHandOffChoices()
                d = (last?.harness ?? stored.harness, last?.provider ?? stored.provider,
                     last?.subject == briefKey ? last?.mayPush ?? false : false)
            } else {
                d = handOffDefaults(stored: await store.handoffDefaults(), current: ctx.provider)
            }
            let (place, production) = await handOffWhere(root: subject.root, context: ctx)
            await store.showHandOff(TicketHandOffState(
                key: subject.key, pr: subject.pr, repo: subject.repo, source: subject.source, brief: kept?.text ?? subject.brief,
                harness: d.0, provider: d.1, mayPush: d.2, place: place, production: production,
                root: subject.root, branch: subject.branch, providers: ctx.providers, pane: pane,
                // The keyboard is the operator's open's only (Rules 3 and 6).
                focus: same ? (open?.focus ?? false) || !byAgent : !byAgent,
                agentBrief: kept?.byAgent ?? false, titleLine: kept?.title,
                opened: same ? open?.opened ?? 0 : await store.nextHandOffOpen()))
            return await editor.reply(pane)
        }))

    await registry.register(Action(
        name: "ticket_hand_off_brief",
        description: "Keep the open Hand to agent popover's edits (its field dispatches on blur): brief, its text. "
            + "harness, provider and mayPush are the operator's alone: an agent may edit the brief's text and nothing "
            + "else, and a call from one that names any of the three is refused whole.",
        kind: .control, audience: .agentReachable,
        schema: schema(["brief": string, "harness": string, "provider": string, "mayPush": boolean]),
        handler: { params in
            let action = "ticket_hand_off_brief"
            guard var s = await store.handOff() else {
                throw TicketActionError(description: "\(action): no Hand to agent popover is open")
            }
            guard !s.starting else { throw TicketActionError(description: "\(action): the hand-off is starting; nothing was changed") }
            guard case .object(let o) = params else { return await handOffReply(s.pane) }
            // F2: who runs it and whether it may push are the operator's (Invariant 7) — never an agent's.
            let operatorsOnly = ["harness", "provider", "mayPush"].filter { o[$0] != nil }
            if ActionRegistry.dispatchOrigin == .agent, !operatorsOnly.isEmpty {
                throw TicketActionError(description: "\(action): only the operator sets "
                    + operatorsOnly.joined(separator: ", ") + " — an agent may edit the brief's text alone; nothing was changed")
            }
            if case .string(let h)? = o["harness"] {
                guard ticketHandOffHarnesses.contains(where: { $0.id == h }) else {
                    throw TicketActionError(description: "\(action): Wakil has no harness \(h); nothing was changed")
                }
                s.harness = h
            }
            if case .string(let p)? = o["provider"], !p.isEmpty { s.provider = p }
            if case .bool(let m)? = o["mayPush"] { s.mayPush = m }
            // An agent's words are marked as its own; the operator's become the title's source.
            if case .string(let b)? = o["brief"], b != s.brief { s.write(brief: b, byAgent: ActionRegistry.dispatchOrigin == .agent) }
            s.error = nil
            await store.showHandOff(s)
            return await handOffReply(s.pane)
        }))

    await registry.register(Action(
        name: "ticket_hand_off",
        description: "Start: hand the popover's ticket to an agent in a new background conversation, with exactly "
            + "the popover's brief, harness, provider, place, root, branch and May push. The operator's only.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["key": .object(["type": .array([.string("string"), .string("null")])]), "pr": integer,
                        "repo": string, "thread": string, "brief": string, "harness": string, "provider": string,
                        "mayPush": boolean, "root": string, "branch": string, "pane": string, "opened": integer,
                        "place": .object(["type": .string("object")])],
                       required: ["brief", "harness", "provider", "mayPush", "place", "root", "branch"]),
        handler: { params in
            let action = "ticket_hand_off"
            guard let s = await store.handOff() else {
                throw TicketActionError(description: "\(action): no Hand to agent popover is open; nothing was started")
            }
            guard !s.starting else {
                throw TicketActionError(description: "\(action): the hand-off is already starting; nothing was started twice")
            }
            guard let handOff else { throw TicketActionError(description: "\(action): no window to start the hand-off in") }
            guard case .object(let o) = params, case .object(let p)? = o["place"], case .bool(let mayPush)? = o["mayPush"] else {
                throw StandardActionError.missingParam(action: action, param: "place")
            }
            let brief = try param(params, "brief", action)
            func text(_ k: String) -> String { if case .string(let v)? = p[k] { v } else { "" } }
            let key = optionalString(params, "key").flatMap { $0.isEmpty ? nil : $0 }
            let thread = optionalString(params, "thread").flatMap { $0.isEmpty ? nil : $0 }
            // The popover the operator pressed Start on: the same hand-off, or nothing starts.
            // …and the same open of it: a brief typed for one subject never starts another.
            let opened = o["opened"]?.intValue
            guard key == s.key, thread == s.thread, o["pr"]?.intValue == s.pr, opened == nil || opened == s.opened,
                  optionalString(params, "root") == s.root, optionalString(params, "branch") == s.branch else {
                throw TicketActionError(description: "\(action): the popover shows \(s.name), not what this Start names; nothing was started")
            }
            let request = TicketHandOffRequest(
                key: key, pr: o["pr"]?.intValue, thread: thread, brief: s.startBrief(brief), harness: try param(params, "harness", action),
                provider: try param(params, "provider", action),
                place: Place(organization: text("organization"), project: text("project"), environment: text("environment")),
                root: try param(params, "root", action), branch: try param(params, "branch", action), mayPush: mayPush,
                repo: optionalString(params, "repo").flatMap { $0.isEmpty ? nil : $0 })
            let token = await store.beginHandOffStart()
            do {
                let id = try await handOff.start(request, reserved: { id in
                    Task { if !(await store.reserveHandOff(id, token: token)) { await handOff.cancel(id) } }
                })
                if await store.finishHandOffStart(token, error: nil) == .cancelled { await handOff.cancel(id) }
                return .object(["conversation": .string(id)])
            } catch {
                let said = "\(error)"
                guard await store.finishHandOffStart(token, error: said) == .current else {
                    return .object(["cancelled": .bool(true)])
                }
                throw TicketActionError(description: "\(action): \(said)")
            }
        }))

    await registry.register(Action(
        name: "ticket_hand_off_cancel",
        description: "Cancel the Hand to agent popover: while a Start runs, stop it and end the conversation it "
            + "reserved (the popover stays, its brief kept); else close the popover. The operator's only.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["pane": string]),
        handler: { _ in
            guard let s = await store.handOff() else { return .object(["handoff": .object(["open": .bool(false)])]) }
            if s.starting {
                if let id = await store.cancelHandOffStart() { await handOff?.cancel(id) }
            } else {
                await store.closeHandOff()
            }
            return await handOffReply(s.pane)
        }))

    await registry.register(Action(
        name: "ticket_hand_off_close",
        description: "Close the Hand to agent popover. Its brief is kept — brief, when given, is the field's text "
            + "as it closed — and reopening it shows the edited text. Refused while a Start runs: Cancel stops that.",
        kind: .control, audience: .agentReachable,
        schema: schema(["brief": string, "pane": string]),
        handler: { params in
            guard var s = await store.handOff() else { return .object(["handoff": .object(["open": .bool(false)])]) }
            guard !s.starting else {
                throw TicketActionError(description: "ticket_hand_off_close: the hand-off is starting; Cancel stops it")
            }
            if let brief = optionalString(params, "brief"), brief != s.brief {
                s.write(brief: brief, byAgent: ActionRegistry.dispatchOrigin == .agent)
                await store.showHandOff(s)
            }
            await store.closeHandOff()
            return await handOffReply(s.pane)
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
