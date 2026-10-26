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
}

/// The Ticket view's readable state, kept store-wide for every editor pane (Invariant 3):
/// `EditorPaneKind.readPane` picks the root a pane follows from its own front tab at read time.
/// Draft text is never in it — only which threads have one.
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
    public var drafts: [String]
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
            "drafts": .array(drafts.map { .string($0) }),
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
    editor: EditorTicketHooks, roots: @escaping @Sendable () async -> [String]
) async {
    @Sendable func mirror() async {
        let rs = await roots()
        var byRoot: [String: EditorTicketMirror.Root] = [:]
        for root in Set(rs).union(await store.roots()) {
            let b = await store.branch(root: root)
            byRoot[root] = EditorTicketMirror.Root(
                branch: b?.branch, tickets: b?.tickets.map(\.key) ?? [], marked: b?.tickets.first(where: \.marked)?.key,
                prs: b?.prs.map { .init(number: $0.number, state: $0.state, openThreads: reviewOpenThreads([$0]).count) } ?? [],
                reading: await store.reading(root: root), error: await store.failure(root: root))
        }
        let drafts = await store.allDrafts().keys.sorted()
        await panes.setEditorTicketMirror(EditorTicketMirror(roots: rs, byRoot: byRoot, drafts: drafts))
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
    /// Whether an agent session made the running dispatch: its reads go through its own place's
    /// client and answer it alone, never the window's cache, which holds the window's organisation.
    @Sendable func pinned() -> Bool { pinnedPlace(of: ActionRegistry.dispatchCaller) != nil }
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
            + "is stopped and says so. With no pane, the focused or first editor pane.",
        kind: .control, audience: .agentReachable,
        schema: schema(["pane": string]),
        handler: { params in
            let pane = try await editor.pane(params, "ticket_refresh")
            if let root = await followed(pane) {
                _ = try await read(root)
            }
            return await editor.reply(pane)
        }))

    await registry.register(Action(
        name: "ticket_show",
        description: "Show a ticket in an editor pane's Ticket view by key (a row of In flight), or null for the "
            + "branch's own. The branch never switches. Shows the column on Ticket.",
        kind: .control, audience: .agentReachable,
        schema: schema(["pane": string, "key": .object(["type": .array([.string("string"), .string("null")])])]),
        handler: { params in
            let pane = try await editor.pane(params, "ticket_show")
            let key = optionalString(params, "key").flatMap { $0.isEmpty ? nil : $0.uppercased() }
            _ = await editor.updateColumn(pane) { c in
                c.ticketShown = key
                c.view = .ticket
                c.shown = true
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
            + "params. Allowed everywhere: the record is Wakil's own store.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["key": string, "section": string, "op": string, "id": string, "text": string, "why": string,
                        "how": string, "who": string, "what": string], required: ["key", "section", "op"]),
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
            let out = try await call("ticket_record_write", args, action: action, timeout: MCPClient.mutationReplyTimeout)
            if let record = try? ticketDecode(TicketRecordState.self, out, tool: "ticket_record_write") {
                await store.setRecord(record)
            }
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
            try await editor.openFile(pane, t.root + "/" + t.path, max(1, t.line))
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
                let s = await panes.editorSnapshot(paneId: pane)
                if let i = s.active, i < s.tabs.count, case .file(let path, _) = s.tabs[i].subject {
                    from = threads.first { $0.root + "/" + $0.path == path && $0.line == s.tabs[i].cursor.line }?.id
                }
            }
            guard let t = reviewStep(threads, from: from, delta: delta) else {
                throw TicketActionError(description: "review_step: the branch has no open review threads")
            }
            try await editor.openFile(pane, t.root + "/" + t.path, max(1, t.line))
            guard case .object(var reply) = await editor.reply(pane) else { return .null }
            reply["thread"] = .string(t.id)
            reply["position"] = .string(reviewPosition(threads, id: t.id))
            return .object(reply)
        }))

    await registry.register(Action(
        name: "review_reply_draft",
        description: "Keep a review thread's reply draft for the window's life; empty or null text drops it. "
            + "Nothing is posted: review_reply_send does that.",
        kind: .control, audience: .agentReachable,
        schema: schema(["thread": string, "text": .object(["type": .array([.string("string"), .string("null")])])],
                       required: ["thread"]),
        handler: { params in
            let thread = try param(params, "thread", "review_reply_draft")
            await store.setDraft(thread: thread, text: optionalString(params, "text"))
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
            await store.setDraft(thread: thread, text: nil)
            await mirror()
            await store.invalidate(root: root)
            return .object(out)
        },
        price: (production: .gate, otherwise: .gate)))

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
        price: (production: .allow, otherwise: .allow), agentPrice: .gate))
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
