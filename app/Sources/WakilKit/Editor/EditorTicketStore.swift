import Foundation

/// Why a ticket read did not come back: it ran past the window's limit (Rule 4), or `wakil-ticket`
/// is missing or said why, whole (Rule 8).
public struct TicketReadError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String

    /// A read stopped by the window's limit: it says so, and how to read again.
    static func stopped(after limit: Duration) -> TicketReadError {
        TicketReadError(description: "Read stopped after \(Int(limit.components.seconds)) s. ↻ reads again.")
    }
}

/// The window's ticket reads (spec, *When it reads*): one per (root, branch), kept in memory while
/// an editor pane is open, as the window's git status is, with the review drafts beside them.
///
/// A read runs when the window asks — an editor pane opens or a root's branch changes
/// (`WindowModel+Ticket`), ↻, a push, Send or Resolve, Wakil coming back after 60 s, the 2-minute
/// read while Wakil is in front (`WindowModel+TicketNoticing`) — and one read per (root, branch),
/// and one of In flight, is in flight at a time: a second ask joins the first (Rule 5). One
/// that runs past 20 s is cancelled and says so (Rule 4); Go's own read gives up at 15 s, so its
/// partial answer reaches the operator first.
///
/// **An org switch empties it** (Invariant 4, `reset`): cache, drafts and flights go, and a read
/// still running from the old organisation lands on a newer generation and is dropped.
public actor EditorTicketStore {
    private struct ReadKey: Hashable { let root: String; let branch: String }
    private struct Flight { let id: UUID; let task: Task<TicketBranchState, Error> }

    /// `wakil-ticket`, routed to an agent caller's own place (`PlaceRoutedCaller`).
    nonisolated let ticket: (any ToolCaller)?
    private let now: @Sendable () -> Date
    private let readLimit: Duration

    private var cache: [ReadKey: (state: TicketBranchState, at: Date)] = [:]
    /// The branch each root was last seen on: the git status's, else the last read's.
    private var current: [String: String] = [:]
    private var flights: [ReadKey: Flight] = [:]
    private var failures: [String: String] = [:]
    /// The window's organisation's reply drafts, as its `tickets/drafts.json` last answered them.
    private var drafts: [String: TicketDraftState] = [:]
    private var draftsLoadFailure: String?
    private var sendingThreads: Set<String> = []
    /// What GitHub answered beside a reply it posted, by thread, whole: the reply is posted all the same.
    private var answers: [String: String] = [:]
    private var inFlightRead: InFlightState?
    private var inFlightReadAt: Date?
    private var inFlightFailureText: String?
    private var inFlightFlight: (id: UUID, task: Task<InFlightState, Error>)?
    /// Records of tickets shown from In flight (`ticket_show`), by key, and why one could not be read.
    private var records: [String: TicketRecordState] = [:]
    private var recordFailures: [String: String] = [:]
    /// The branch of a ticket picked from In flight, read by its row's root and branch, by key; and
    /// why one could not be read. The root's own read and current branch are untouched (Rule 6).
    private var shownReads: [String: TicketBranchState] = [:]
    /// Each shown ticket's other branches — every In flight row of its key, any root or repository, but
    /// the one shown — by key, then by `<root>:<branch>`; and why one could not be read, whole (walk
    /// 2026-10-29: the Pull requests section is the ticket's, not one branch's).
    private var alsoReads: [String: [String: TicketBranchState]] = [:]
    private var alsoFailures: [String: [String]] = [:]
    /// The branch each key's other branches were read beside, so In flight landing can read them again.
    private var alsoExcept: [String: TicketShownAt?] = [:]
    /// When each picked ticket's branch last came back, by the store's clock.
    private var shownReadAt: [String: Date] = [:]
    private var shownFailures: [String: String] = [:]
    /// Where each picked ticket's branch is read from, so a resolve, a push or ↻ reads it again.
    private var shownWhere: [String: (root: String, branch: String)] = [:]
    /// The Hand to agent popover while it is open, and each brief as edited, by subject and source
    /// (`handOffBriefKey`), for the window's life (Rule 2). `handOffStart` is the Start in flight;
    /// `handOffCancelled` the one its Cancel stopped. An org switch drops all four (Invariant 4).
    private var handOffShown: TicketHandOffState?
    /// A kept brief: its text, whether an agent wrote it last, and the operator's first line.
    struct KeptBrief: Equatable { let text: String; let byAgent: Bool; let title: String }
    private var briefs: [String: KeptBrief] = [:]
    /// The harness, provider and May push the popover last showed, for the window's life: an agent's
    /// reopen takes these, never the last Start's (it can never switch May push on).
    private var handOffChoices: (harness: String, provider: String, mayPush: Bool, subject: String)?
    private var handOffOpens = 0
    private var handOffStart: UUID?
    private var handOffCancelled: UUID?
    private var generation = 0
    private var onChange: (@Sendable () async -> Void)?

    /// The window's limit on one read (Global Constraints: 20 s).
    public static let readLimit: Duration = .seconds(20)

    public init(ticket: (any ToolCaller)?, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(ticket: ticket, now: now, readLimit: Self.readLimit)
    }

    /// A shorter limit, for a test that cannot wait 20 s.
    init(ticket: (any ToolCaller)?, now: @escaping @Sendable () -> Date = Date.init, readLimit: Duration) {
        self.ticket = ticket
        self.now = now
        self.readLimit = readLimit
    }

    /// Called after anything readable changes — a read starting or landing, a draft, a record line —
    /// so the editor panes' readable state follows (`registerTicketActions`).
    public func setOnChange(_ f: (@Sendable () async -> Void)?) { onChange = f }

    private func changed() async { await onChange?() }

    // MARK: Reads

    /// The root's branch as last read, for the branch the root is on now; nil before a read.
    public func branch(root: String) -> TicketBranchState? {
        cache[ReadKey(root: root, branch: current[root] ?? "")]?.state
    }

    /// When the root's current branch was last read.
    public func lastRead(root: String) -> Date? { cache[ReadKey(root: root, branch: current[root] ?? "")]?.at }

    /// Whether a read of the root's current branch is running (↻ shows it, Rule 5).
    public func reading(root: String) -> Bool { flights[ReadKey(root: root, branch: current[root] ?? "")] != nil }

    /// Why the root's last read failed, whole; nil after one that came back.
    public func failure(root: String) -> String? { failures[root] }

    /// Every root read so far, in no order.
    public func roots() -> [String] { Array(Set(cache.keys.map(\.root)).union(flights.keys.map(\.root))) }

    /// The git status says the root is on `branch` now: reads key on it from here.
    public func follow(root: String, branch: String) { current[root] = branch }

    /// Reads the root's branch, joining a read already in flight for it.
    public func read(root: String) async throws -> TicketBranchState {
        let key = ReadKey(root: root, branch: current[root] ?? "")
        let flight = flights[key] ?? start(key)
        return try await flight.task.value
    }

    /// Stops the root's read in flight, if one is (↻'s Cancel).
    public func cancel(root: String) {
        for (key, f) in flights where key.root == root {
            f.task.cancel()
            flights[key] = nil
        }
    }

    /// Something Wakil did changed what the root reads — a push, a reply, a resolve, a link: a read
    /// in flight is stale, so it is replaced by a new one, which this does not wait for. A root
    /// nothing has read yet is left alone: nothing shows it.
    public func invalidate(root: String) async {
        // A picked ticket's branch on that root is stale with it: read again, not waited for.
        for (key, at) in shownWhere where at.root == root { Task { await self.refreshShown(key: key) } }
        guard cache.keys.contains(where: { $0.root == root }) || flights.keys.contains(where: { $0.root == root }) else { return }
        cancel(root: root)
        _ = start(ReadKey(root: root, branch: current[root] ?? ""))
    }

    private func start(_ key: ReadKey) -> Flight {
        let id = UUID()
        let gen = generation
        let (ticket, limit) = (self.ticket, self.readLimit)
        let task = Task<TicketBranchState, Error> {
            defer { Task { await self.land(key, id: id) } }
            do {
                // The window's own read, whoever asked for it: a task inherits the dispatch's caller,
                // and an agent's would route this read through its place's client into the window's
                // cache (Invariant 4). The window's client reads the window's organisation.
                let state = try await ActionRegistry.$dispatchCaller.withValue(nil) {
                    try await Self.readBranch(ticket, root: key.root, branch: nil, limit: limit)
                }
                self.store(state, key: key, id: id, generation: gen)
                return state
            } catch {
                self.fail(key, id: id, generation: gen, error)
                throw error
            }
        }
        let flight = Flight(id: id, task: task)
        flights[key] = flight
        Task { await changed() }
        return flight
    }

    private func store(_ state: TicketBranchState, key: ReadKey, id: UUID, generation gen: Int) {
        guard gen == generation, flights[key]?.id == id else { return }
        let branch = state.branch
        cache[ReadKey(root: key.root, branch: branch)] = (state, now())
        current[key.root] = branch
        failures[key.root] = nil
        flights[key] = nil
        // The tickets it carries: their other branches, for the Pull requests section.
        for t in state.tickets {
            let at = TicketShownAt(root: key.root, branch: branch)
            Task { await self.readTicketBranches(key: t.key, except: at) }
        }
    }

    private func fail(_ key: ReadKey, id: UUID, generation gen: Int, _ error: Error) {
        guard gen == generation, flights[key]?.id == id else { return }
        if !(error is CancellationError) { failures[key.root] = String(describing: error) }
        flights[key] = nil
    }

    private func land(_ key: ReadKey, id: UUID) async {
        if flights[key]?.id == id { flights[key] = nil }
        await changed()
    }

    /// `ticket_branch` for one root — its current branch, or `branch` — cancelled past `limit`.
    private static func readBranch(_ ticket: (any ToolCaller)?, root: String, branch: String?,
                                   limit: Duration) async throws -> TicketBranchState {
        guard let ticket else {
            throw TicketReadError(description: StandardActionError.missingClient(action: "ticket_branch", role: "ticket").description)
        }
        let content = try await withThrowingTaskGroup(of: [String: JSONValue]?.self) { group in
            group.addTask {
                var args: [String: JSONValue] = ["root": .string(root)]
                if let branch { args["branch"] = .string(branch) }
                return try await ticketCall(ticket, "ticket_branch", args, timeout: limit.seconds + 5)
            }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            guard let content = first else { throw TicketReadError.stopped(after: limit) }
            return content
        }
        return try ticketDecode(TicketBranchState.self, content, tool: "ticket_branch")
    }

    /// `ticket_in_flight`: the organisation's tickets in flight and Waiting on you, kept as the last
    /// such read. One read at a time: a second ask joins the one in flight (Rule 5). A failed read
    /// keeps the last one and says why (`inFlightFailure`), whole.
    public func inFlight() async throws -> InFlightState {
        guard let ticket else {
            throw TicketReadError(description: StandardActionError.missingClient(action: "ticket_in_flight", role: "ticket").description)
        }
        let flight = inFlightFlight ?? startInFlight(ticket)
        return try await flight.task.value
    }

    private func startInFlight(_ ticket: any ToolCaller) -> (id: UUID, task: Task<InFlightState, Error>) {
        let (id, gen, limit) = (UUID(), generation, readLimit)
        let task = Task<InFlightState, Error> {
            do {
                // The window's own read, as `start`'s is.
                let content = try await ActionRegistry.$dispatchCaller.withValue(nil) {
                    try await ticketCall(ticket, "ticket_in_flight", [:], timeout: limit.seconds)
                }
                let state = try ticketDecode(InFlightState.self, content, tool: "ticket_in_flight")
                await self.landInFlight(.success(state), id: id, generation: gen)
                return state
            } catch {
                await self.landInFlight(.failure(error), id: id, generation: gen)
                throw error
            }
        }
        inFlightFlight = (id, task)
        return (id, task)
    }

    private func landInFlight(_ outcome: Result<InFlightState, Error>, id: UUID, generation gen: Int) async {
        guard gen == generation, inFlightFlight?.id == id else { return }
        inFlightFlight = nil
        switch outcome {
        case .success(let state):
            let rowsBefore = inFlightRead.map { Self.branchRows($0) }
            inFlightRead = state
            inFlightReadAt = now()
            inFlightFailureText = nil
            // A ticket whose rows changed has its other branches read again.
            for (key, except) in alsoExcept where rowsBefore?[key] != Self.branchRows(state)[key] {
                Task { await self.readTicketBranches(key: key, except: except) }
            }
        case .failure(let error) where error is CancellationError: break
        case .failure(let error): inFlightFailureText = String(describing: error)
        }
        await changed()
    }

    /// When In flight last came back; nil before a read.
    public func inFlightAt() -> Date? { inFlightReadAt }

    /// Whether In flight is old enough that Wakil becoming the active app reads it again: none yet, or
    /// over 60 s, by the store's clock.
    public func inFlightStale() -> Bool { ticketStale(lastRead: inFlightReadAt, now: now()) }

    /// Why the last In flight read failed, whole; nil after one that came back.
    public func inFlightFailure() -> String? { inFlightFailureText }

    /// A write from Wakil landed on `root` — Send, Resolve, a push, a sync or a publish: its branch is
    /// read again, then In flight, neither waited for (spec, *When it reads*).
    public func wrote(root: String) async {
        await invalidate(root: root)
        let flight = flights[ReadKey(root: root, branch: current[root] ?? "")]
        Task {
            _ = try? await flight?.task.value
            _ = try? await self.inFlight()
        }
    }

    /// Ends the window's organisation's hand-offs whose conversation is not in `live`
    /// (`ticket_handoff_write` `end`, `keepLive`): a quit or a switch left them with no conversation.
    public func endStaleHandoffs(live: [String]) async throws {
        guard ticket != nil else { return }
        _ = try await windowCall("ticket_handoff_write", ["op": .string("end"), "conversations": .array(live.map { .string($0) }),
                                                          "keepLive": .bool(true)], timeout: MCPClient.mutationReplyTimeout)
    }

    // MARK: - A handed conversation's hand-off (ticket noticing, Task 9)
    //
    // Each is the conversation's own organisation's (`caller`, routed to its place's process), not
    // the window's: a hand-off outlives an organisation switch (Invariant 4).

    /// Keeps a started hand-off (`ticket_handoff_write` `add`) under `key` — a ticket key, or
    /// `pr:<repo>#<n>` for a PR with no key — with the operator's May push.
    public func addHandoff(key: String, handoff: JSONValue, mayPush: Bool, as caller: DispatchCaller) async throws {
        _ = try await routedCall("ticket_handoff_write", ["op": .string("add"), "key": .string(key), "handoff": handoff,
                                                          "mayPush": .bool(mayPush)], as: caller, timeout: MCPClient.mutationReplyTimeout)
    }

    /// Ends one conversation's hand-off (`ticket_handoff_write` `end`): it closed.
    public func endHandoff(conversation: String, as caller: DispatchCaller) async throws {
        _ = try await routedCall("ticket_handoff_write", ["op": .string("end"), "conversations": .array([.string(conversation)])],
                                 as: caller, timeout: MCPClient.mutationReplyTimeout)
    }

    /// Carries the hand-off of conversation `from` to `to` (`ticket_handoff_write` `carry`): the
    /// key it is kept by and the carried hand-off, or nil when the answer says explicitly
    /// (`carried: false`) that `from` was never handed. Any other shape throws.
    public func carryHandoff(from: String, to: String, as caller: DispatchCaller) async throws
        -> (key: String, handoff: [String: JSONValue])? {
        let content = try await routedCall("ticket_handoff_write", ["op": .string("carry"), "from": .string(from), "to": .string(to)],
                                           as: caller, timeout: MCPClient.mutationReplyTimeout)
        // Only an explicit `carried: false` is "nothing to carry"; any other shape is an error.
        switch content["carried"] {
        case .bool(false)?: return nil
        case .bool(true)?:
            guard case .object(let h)? = content["handoff"], case .string(let key)? = content["key"], !key.isEmpty else {
                throw TicketReadError(description: "ticket_handoff_write answered a carry with no hand-off or no key")
            }
            return (key, h)
        default:
            throw TicketReadError(description: "ticket_handoff_write answered a carry without saying whether it carried one")
        }
    }

    /// The conversation's May push as its stored hand-off says (`ticket_handoff_may_push`): on only
    /// when the answer says exactly that; a failed read, or any other answer, is off.
    public func handoffMayPush(conversation: String, as caller: DispatchCaller) async -> Bool {
        let content = try? await routedCall("ticket_handoff_may_push", ["conversation": .string(conversation)],
                                            as: caller, timeout: MCPClient.readReplyTimeout)
        return content?["mayPush"] == .bool(true)
    }

    private func routedCall(_ tool: String, _ args: [String: JSONValue], as caller: DispatchCaller,
                            timeout: TimeInterval) async throws -> [String: JSONValue] {
        guard let ticket else {
            throw TicketReadError(description: StandardActionError.missingClient(action: tool, role: "ticket").description)
        }
        return try await ActionRegistry.$dispatchCaller.withValue(caller) {
            try await ticketCall(ticket, tool, args, timeout: timeout)
        }
    }

    /// The organisation's last Start's harness, provider and May push (`ticket_handoff_defaults`),
    /// the window's own: nil when none was kept, or the read failed — a default only suggests (Rule 9).
    public func handoffDefaults() async -> (harness: String, provider: String, mayPush: Bool)? {
        guard ticket != nil, let content = try? await windowCall("ticket_handoff_defaults", [:], timeout: MCPClient.readReplyTimeout),
              content["found"] == .bool(true), case .object(let d)? = content["defaults"] else { return nil }
        func text(_ k: String) -> String { if case .string(let v)? = d[k] { v } else { "" } }
        return (text("harness"), text("provider"), d["mayPush"] == .bool(true))
    }

    /// The last In flight read, for the view.
    public func lastInFlight() -> InFlightState? { inFlightRead }

    /// Reads one ticket's record, for a ticket shown from In flight: the window's own read, as
    /// `start`'s is, kept by key for the view.
    public func readRecord(key: String) async throws -> TicketRecordState {
        guard let ticket else {
            throw TicketReadError(description: StandardActionError.missingClient(action: "ticket_record", role: "ticket").description)
        }
        let gen = generation
        do {
            let content = try await ActionRegistry.$dispatchCaller.withValue(nil) {
                try await ticketCall(ticket, "ticket_record", ["key": .string(key)], timeout: MCPClient.readReplyTimeout)
            }
            let record = try ticketDecode(TicketRecordState.self, content, tool: "ticket_record")
            if gen == generation {
                records[key] = record
                recordFailures[key] = nil
                await changed()
            }
            return record
        } catch {
            // Said whole where the record would be (Rule 8), never drawn as an empty record.
            if gen == generation {
                recordFailures[key] = String(describing: error)
                await changed()
            }
            throw error
        }
    }

    /// Reads the branch of a ticket picked from In flight by its row's root and branch — the
    /// window's own read, as `start`'s is, past 20 s stopped — kept by the ticket's key. A failure
    /// is kept, whole, for the view.
    public func readShown(key: String, root: String, branch: String) async {
        let (ticket, limit, gen) = (self.ticket, self.readLimit, generation)
        shownWhere[key] = (root, branch)
        do {
            let state = try await ActionRegistry.$dispatchCaller.withValue(nil) {
                try await Self.readBranch(ticket, root: root, branch: branch, limit: limit)
            }
            guard gen == generation else { return }
            shownReads[key] = state
            shownReadAt[key] = now()
            Task { await self.readTicketBranches(key: key, except: TicketShownAt(root: root, branch: branch)) }
            shownFailures[key] = nil
        } catch {
            guard gen == generation else { return }
            shownFailures[key] = String(describing: error)
        }
        await changed()
    }

    /// `readShown` for a keyless row (a PR with no ticket key): its branch is kept by `at.id`, where a
    /// ticket's is kept by its key.
    public func readShown(at: TicketShownAt) async {
        await readShown(key: at.id, root: at.root, branch: at.branch)
    }

    /// Reads a picked ticket's branch again (↻, a resolve, a push, a reply); nothing for a key not picked.
    public func refreshShown(key: String) async {
        guard let at = shownWhere[key] else { return }
        // Its record too, when it is a ticket's (a keyless row's key is `<root>:<branch>`): an agent's
        // Next or notes show without reopening the ticket (walk 2026-10-29). A failure is kept by readRecord.
        async let record: Void = { if !key.contains(":"), !key.contains("#") { _ = try? await self.readRecord(key: key) } }()
        await readShown(key: key, root: at.root, branch: at.branch)
        await record
    }

    /// Reads again each picked ticket's branch on `root` — on `branch` too, when given — not waited
    /// for: a write that named its place landed there.
    public func refreshShown(root: String, branch: String?) {
        for (key, at) in shownWhere where at.root == root && (branch == nil || at.branch == branch) {
            Task { await self.refreshShown(key: key) }
        }
    }

    /// Reads every branch In flight holds for `key` — any root, any repository — but `except`, the one
    /// already shown, all at once, and keeps each by `<root>:<branch>`; one that fails is kept whole,
    /// named by its branch (Rule 8). Not a key In flight holds: nothing is read.
    public func readTicketBranches(key: String, except: TicketShownAt?) async {
        let wanted = (Self.branchRows(inFlightRead ?? InFlightState())[key] ?? []).filter { $0 != except }
        alsoExcept[key] = except
        guard !wanted.isEmpty || alsoReads[key] != nil else { return }
        let (ticket, limit, gen) = (self.ticket, self.readLimit, generation)
        var got: [String: TicketBranchState] = [:]
        var failed: [String] = []
        await withTaskGroup(of: (TicketShownAt, Result<TicketBranchState, Error>).self) { group in
            for at in wanted {
                group.addTask {
                    do {
                        let state = try await ActionRegistry.$dispatchCaller.withValue(nil) {
                            try await Self.readBranch(ticket, root: at.root, branch: at.branch, limit: limit)
                        }
                        return (at, .success(state))
                    } catch { return (at, .failure(error)) }
                }
            }
            for await (at, outcome) in group {
                switch outcome {
                case .success(let state): got[at.id] = state
                case .failure(let error): failed.append("\(at.branch): \(error)")
                }
            }
        }
        guard gen == generation else { return }
        alsoReads[key] = got
        alsoFailures[key] = failed.isEmpty ? nil : failed.sorted()
        await changed()
    }

    /// A shown ticket's other branches, by key, in `<root>:<branch>` order.
    public func ticketBranchReads() -> [String: [TicketBranchState]] {
        alsoReads.mapValues { m in m.keys.sorted().compactMap { m[$0] } }
    }

    /// Why a shown ticket's other branch could not be read, whole, by key.
    public func ticketBranchFailures() -> [String: [String]] { alsoFailures }

    /// Each key's branches In flight holds, once each, in the order first seen.
    private static func branchRows(_ s: InFlightState) -> [String: [TicketShownAt]] {
        var out: [String: [TicketShownAt]] = [:]
        for r in s.waitingOnYou + s.inFlight where !r.key.isEmpty && !r.root.isEmpty && !r.branch.isEmpty {
            let at = TicketShownAt(root: r.root, branch: r.branch)
            if !(out[r.key] ?? []).contains(at) { out[r.key, default: []].append(at) }
        }
        return out
    }

    /// Whether a picked ticket's branch is old enough that Wakil coming back reads it again: never
    /// read, or over 60 s, by the store's clock.
    public func shownStale(key: String) -> Bool { ticketStale(lastRead: shownReadAt[key], now: now()) }

    /// How long ago In flight last came back, by the store's clock; nil before a read.
    public func inFlightAge() -> TimeInterval? { inFlightReadAt.map { now().timeIntervalSince($0) } }

    /// The branches read for tickets picked from In flight, by key, and why one was not.
    public func shownBranches() -> [String: TicketBranchState] { shownReads }
    public func shownBranchFailures() -> [String: String] { shownFailures }
    public func shownRecordFailures() -> [String: String] { recordFailures }

    /// The records read for tickets shown from In flight, by key.
    public func shownRecords() -> [String: TicketRecordState] { records }

    /// The roots whose read is running now.
    public func readingRoots() -> Set<String> { Set(flights.keys.map(\.root)) }

    /// Each root's last failure, whole.
    public func allFailures() -> [String: String] { failures }

    // MARK: Writes the store answers for

    /// A record line was written: every cached read showing that ticket takes the new record, so
    /// the view needs no new read of GitHub for it.
    /// A picked ticket's branch takes it too.
    public func setRecord(_ record: TicketRecordState) async {
        if records[record.key] != nil { records[record.key] = record }
        for (key, entry) in cache { if let s = Self.with(record, entry.state) { cache[key] = (s, entry.at) } }
        for (key, state) in shownReads { if let s = Self.with(record, state) { shownReads[key] = s } }
        await changed()
    }

    /// A thread was resolved or unresolved: the cached read, and a picked ticket's branch, say so at
    /// once, `by` the branch's viewer.
    public func setResolved(thread: String, resolved: Bool) async {
        for (key, entry) in cache {
            if let s = Self.with(thread: thread, resolved: resolved, entry.state) { cache[key] = (s, entry.at) }
        }
        for (key, state) in shownReads {
            if let s = Self.with(thread: thread, resolved: resolved, state) { shownReads[key] = s }
        }
        await changed()
    }

    /// The read with the ticket's record replaced; nil when it does not carry the ticket.
    private static func with(_ record: TicketRecordState, _ state: TicketBranchState) -> TicketBranchState? {
        var s = state
        var hit = false
        for i in s.tickets.indices where s.tickets[i].key == record.key {
            s.tickets[i].record = record
            hit = true
        }
        return hit ? s : nil
    }

    /// The read with the thread resolved or not; nil when it does not hold the thread.
    private static func with(thread: String, resolved: Bool, _ state: TicketBranchState) -> TicketBranchState? {
        var s = state
        var hit = false
        for p in s.prs.indices {
            for t in s.prs[p].threads.indices where s.prs[p].threads[t].id == thread {
                s.prs[p].threads[t].resolved = resolved
                s.prs[p].threads[t].resolvedBy = resolved ? (s.viewer.isEmpty ? nil : s.viewer) : nil
                hit = true
            }
        }
        return hit ? s : nil
    }

    /// The thread by its id, in any cached read.
    public func thread(_ id: String) -> ReviewThreadState? {
        for state in cache.values.map(\.state) + shownReads.values + alsoReads.values.flatMap(\.values) {
            for pr in state.prs { if let t = pr.threads.first(where: { $0.id == id }) { return t } }
        }
        return nil
    }

    // MARK: Hand to agent (ticket noticing, Task 10)

    /// The popover while it is open; nil when it is closed.
    public func handOff() -> TicketHandOffState? { handOffShown }

    /// Opens (or changes) the popover; its brief is kept for its subject and source.
    func showHandOff(_ s: TicketHandOffState) async {
        handOffShown = s
        briefs[handOffBriefKey(key: s.key, pr: s.pr, repo: s.repo, source: s.source)]
            = KeptBrief(text: s.brief, byAgent: s.agentBrief, title: s.titleLine)
        handOffChoices = (s.harness, s.provider, s.mayPush, handOffBriefKey(key: s.key, pr: s.pr, repo: s.repo, source: s.source))
        await changed()
    }

    /// The brief kept for a subject and source, as last edited; nil before one was.
    func keptBrief(_ key: String) -> KeptBrief? { briefs[key] }

    /// What the popover last showed for harness, provider and May push, and for which subject
    /// (`handOffBriefKey`); nil before it opened.
    func lastHandOffChoices() -> (harness: String, provider: String, mayPush: Bool, subject: String)? { handOffChoices }

    /// A new open of a subject: its number.
    func nextHandOffOpen() -> Int {
        handOffOpens += 1
        return handOffOpens
    }

    /// Closes the popover; its brief stays kept (Rule 2).
    func closeHandOff() async {
        handOffShown = nil
        await changed()
    }

    /// A Start begins: the popover reads Starting…, its last failure goes. Answers the start's token.
    func beginHandOffStart() async -> UUID {
        let token = UUID()
        handOffStart = token
        handOffShown?.starting = true
        handOffShown?.error = nil
        handOffShown?.conversation = nil
        await changed()
        return token
    }

    /// The start reserved its conversation: kept so Cancel can name it. False when that start was
    /// cancelled meanwhile — its conversation is then ended by the caller.
    func reserveHandOff(_ conversation: String, token: UUID) async -> Bool {
        guard handOffCancelled != token else { return false }
        if handOffStart == token { handOffShown?.conversation = conversation }
        await changed()
        return true
    }

    /// How a start ended, for its own state: it is the popover's still (`current`), Cancel stopped it,
    /// or an org switch dropped the popover (`gone`).
    enum HandOffStartEnd { case current, cancelled, gone }

    /// A start came back: on success the popover closes (its brief stays kept); a failure leaves it
    /// open with the message whole and the brief intact (Rule 8). A start Cancel stopped, or an org
    /// switch dropped, changes nothing here.
    func finishHandOffStart(_ token: UUID, error: String?) async -> HandOffStartEnd {
        if handOffCancelled == token { handOffCancelled = nil; return .cancelled }
        guard handOffStart == token else { return .gone }
        handOffStart = nil
        if let error {
            handOffShown?.starting = false
            handOffShown?.conversation = nil
            handOffShown?.error = error
        } else {
            handOffShown = nil
        }
        await changed()
        return .current
    }

    /// Cancel while starting (Rule 4): the popover stays open, no longer starting; answers the
    /// conversation the start reserved, if it reserved one yet, for the caller to end.
    func cancelHandOffStart() async -> String? {
        guard let token = handOffStart else { return nil }
        handOffCancelled = token
        handOffStart = nil
        let reserved = handOffShown?.conversation
        handOffShown?.starting = false
        handOffShown?.conversation = nil
        await changed()
        return reserved
    }

    /// The read that holds a thread: the root's current branch first, then a picked ticket's branch.
    public func branch(holding thread: String) -> TicketBranchState? {
        let reads = cache.filter { current[$0.key.root] == $0.key.branch }.map(\.value.state)
            + cache.filter { current[$0.key.root] != $0.key.branch }.map(\.value.state) + shownReads.values
            + alsoReads.values.flatMap(\.values)
        return reads.first { $0.prs.contains { $0.threads.contains { $0.id == thread } } }
    }

    // MARK: Drafts

    /// A thread's draft text; nil when it has none.
    public func draft(thread: String) -> String? { drafts[thread]?.text }

    /// Every draft's text, by thread.
    public func allDrafts() -> [String: String] { drafts.mapValues(\.text) }

    /// A thread's draft whole: who wrote it, when, and the operator's text it replaced.
    public func draftRecord(thread: String) -> TicketDraftState? { drafts[thread] }

    public func allDraftRecords() -> [String: TicketDraftState] { drafts }

    /// Why the last drafts load failed, whole (Rule 8); nil after one that came back.
    public func draftsFailure() -> String? { draftsLoadFailure }

    /// Reads the window's organisation's drafts (`ticket_drafts`), as a relaunch or an org switch
    /// finds them. A load from before an org switch lands on a newer generation and is dropped.
    public func loadDrafts() async throws {
        // No wakil-ticket client: there is nothing to load, so no load and no failure to say.
        guard ticket != nil else { return }
        let gen = generation
        let read: TicketDraftsState
        do {
            let content = try await windowCall("ticket_drafts", [:], timeout: MCPClient.readReplyTimeout)
            read = try ticketDecode(TicketDraftsState.self, content, tool: "ticket_drafts")
        } catch {
            // Said whole where the Ticket view says its reads' errors (Rule 8), never drawn as no drafts.
            if gen == generation {
                draftsLoadFailure = "Reply drafts could not be read: \(error)"
                await changed()
            }
            throw error
        }
        guard gen == generation else { return }
        drafts = read.drafts
        draftsLoadFailure = nil
        await changed()
    }

    /// Writes a thread's draft to the window's organisation's file (`ticket_draft_write`); nil or
    /// empty text removes it. The store then holds what the file answered — an agent's draft over
    /// the operator's comes back with the operator's text as `replaced`. A refusal is thrown whole
    /// and the store keeps what it had. `by` is the dispatcher's (`ticketDraftBy`), never params.
    public func setDraft(thread: String, text: String?, by: String, conversation: String?, root: String?,
                         branch: String?) async throws {
        // The text the thread's draft already holds is not an edit: nothing is written, so a Send of
        // an agent's words, declined or failed, leaves them the agent's and the operator's replaced
        // text restorable (spec: "an operator's later edit simply wins" — a Send is not one).
        if let text, !text.isEmpty, drafts[thread]?.text == text { return }
        var args: [String: JSONValue] = ["thread": .string(thread), "by": .string(by)]
        if let text, !text.isEmpty { args["text"] = .string(text) }
        for (k, v) in [("conversation", conversation), ("root", root), ("branch", branch)] {
            if let v, !v.isEmpty { args[k] = .string(v) }
        }
        let gen = generation
        let content = try await windowCall("ticket_draft_write", args, timeout: MCPClient.mutationReplyTimeout)
        let written = try ticketDecode(TicketDraftsState.self, content, tool: "ticket_draft_write")
        guard gen == generation else { return }
        drafts = written.drafts
        await changed()
    }

    /// **Restore yours**: the operator's text an agent's draft replaced is written back, by
    /// `operator`, which clears `replaced`. Refused, nothing written, when nothing was replaced.
    public func restoreDraft(thread: String) async throws {
        guard let d = drafts[thread], let mine = d.replaced, !mine.isEmpty else {
            throw TicketReadError(description: "there is no draft of yours to restore on review thread \(thread)")
        }
        try await setDraft(thread: thread, text: mine, by: "operator", conversation: nil, root: d.root, branch: d.branch)
    }

    /// A posted reply whose file entry could not be removed: the store forgets it all the same, so
    /// no box offers to send it again.
    func forgetDraft(thread: String) { drafts[thread] = nil }

    /// One `wakil-ticket` call on the window's own client, whoever dispatched: an agent's caller would
    /// route it to its place's process, and the store holds the window's organisation (Invariant 4).
    private func windowCall(_ tool: String, _ args: [String: JSONValue], timeout: TimeInterval) async throws -> [String: JSONValue] {
        guard let ticket else {
            throw TicketReadError(description: StandardActionError.missingClient(action: tool, role: "ticket").description)
        }
        return try await ActionRegistry.$dispatchCaller.withValue(nil) {
            try await ticketCall(ticket, tool, args, timeout: timeout)
        }
    }

    public func sending(thread: String) -> Bool { sendingThreads.contains(thread) }

    public func allSending() -> Set<String> { sendingThreads }

    /// Claims the thread for a send; false when one is already being sent (Rule 5).
    func beginSend(thread: String) -> Bool { sendingThreads.insert(thread).inserted }

    func endSend(thread: String) { sendingThreads.remove(thread) }

    public func answer(thread: String) -> String? { answers[thread] }

    public func allAnswers() -> [String: String] { answers }

    /// Keeps what GitHub answered beside the thread's posted reply; nil drops it.
    func setAnswer(thread: String, text: String?) { answers[thread] = text }

    /// An org switch: the outgoing organisation's reads, drafts and flights go, the Hand to agent
    /// popover closes and its kept briefs go, and anything still running lands on a newer generation
    /// and is dropped.
    public func reset() {
        generation += 1
        for f in flights.values { f.task.cancel() }
        flights = [:]
        cache = [:]
        current = [:]
        failures = [:]
        drafts = [:]
        draftsLoadFailure = nil
        sendingThreads = []
        answers = [:]
        inFlightRead = nil
        inFlightReadAt = nil
        inFlightFailureText = nil
        inFlightFlight?.task.cancel()
        inFlightFlight = nil
        records = [:]
        recordFailures = [:]
        shownReads = [:]
        shownReadAt = [:]
        alsoReads = [:]
        alsoFailures = [:]
        alsoExcept = [:]
        shownFailures = [:]
        shownWhere = [:]
        handOffShown = nil
        briefs = [:]
        handOffChoices = nil
        handOffStart = nil
        handOffCancelled = nil
    }
}

private extension Duration {
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// One `wakil-ticket` call: its `structuredContent`, or its error whole.
func ticketCall(_ ticket: any ToolCaller, _ tool: String, _ args: [String: JSONValue],
                timeout: TimeInterval) async throws -> [String: JSONValue] {
    let result = try await ticket.callTool(name: tool, arguments: .object(args), timeout: timeout)
    guard case .object(let o) = result else { throw TicketReadError(description: "\(tool) answered with no object") }
    if case .bool(true)? = o["isError"] {
        throw TicketReadError(description: mcpErrorText(from: o) ?? "\(tool) failed with no message")
    }
    guard case .object(let content)? = o["structuredContent"] else {
        throw TicketReadError(description: "\(tool) answered with no structuredContent")
    }
    return content
}

func ticketDecode<T: Decodable>(_ type: T.Type, _ content: [String: JSONValue], tool: String) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(JSONValue.object(content)))
    } catch {
        throw TicketReadError(description: "\(tool) answered a shape Wakil cannot read: \(error)")
    }
}

/// A value as the JSON an action answers.
func ticketJSON<T: Encodable>(_ value: T) -> JSONValue {
    guard let data = try? JSONEncoder().encode(value), let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return .null
    }
    return v
}
