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
/// **No timer.** A read runs when the window asks — an editor pane opens or a root's branch
/// changes (`WindowModel+Ticket`), ↻, a push, Send or Resolve, Wakil coming back after 60 s — and
/// one read per (root, branch) is in flight at a time: a second ask joins the first (Rule 5). One
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
    private var drafts: [String: String] = [:]
    private var sendingThreads: Set<String> = []
    /// What GitHub answered beside a reply it posted, by thread, whole: the reply is posted all the same.
    private var answers: [String: String] = [:]
    private var inFlightRead: InFlightState?
    /// Records of tickets shown from In flight (`ticket_show`), by key, and why one could not be read.
    private var records: [String: TicketRecordState] = [:]
    private var recordFailures: [String: String] = [:]
    /// The branch of a ticket picked from In flight, read by its row's root and branch, by key; and
    /// why one could not be read. The root's own read and current branch are untouched (Rule 6).
    private var shownReads: [String: TicketBranchState] = [:]
    private var shownFailures: [String: String] = [:]
    /// Where each picked ticket's branch is read from, so a resolve, a push or ↻ reads it again.
    private var shownWhere: [String: (root: String, branch: String)] = [:]
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

    /// `ticket_in_flight`: the organisation's tickets in flight and Waiting on you. Kept as the last
    /// such read for the view; not joined, since it is read only for the default branch.
    public func inFlight() async throws -> InFlightState {
        guard let ticket else {
            throw TicketReadError(description: StandardActionError.missingClient(action: "ticket_in_flight", role: "ticket").description)
        }
        let gen = generation
        let limit = readLimit
        // The window's own read, as `start`'s is.
        let content = try await ActionRegistry.$dispatchCaller.withValue(nil) {
            try await ticketCall(ticket, "ticket_in_flight", [:], timeout: limit.seconds)
        }
        let state = try ticketDecode(InFlightState.self, content, tool: "ticket_in_flight")
        if gen == generation {
            inFlightRead = state
            await changed()
        }
        return state
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
            shownFailures[key] = nil
        } catch {
            guard gen == generation else { return }
            shownFailures[key] = String(describing: error)
        }
        await changed()
    }

    /// Reads a picked ticket's branch again (↻, a resolve, a push, a reply); nothing for a key not picked.
    public func refreshShown(key: String) async {
        guard let at = shownWhere[key] else { return }
        await readShown(key: key, root: at.root, branch: at.branch)
    }

    /// Reads again each picked ticket's branch on `root` — on `branch` too, when given — not waited
    /// for: a write that named its place landed there.
    public func refreshShown(root: String, branch: String?) {
        for (key, at) in shownWhere where at.root == root && (branch == nil || at.branch == branch) {
            Task { await self.refreshShown(key: key) }
        }
    }

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
        for state in cache.values.map(\.state) + shownReads.values {
            for pr in state.prs { if let t = pr.threads.first(where: { $0.id == id }) { return t } }
        }
        return nil
    }

    // MARK: Drafts

    public func draft(thread: String) -> String? { drafts[thread] }

    /// Keeps a thread's draft for the window's life (Rule 2); nil or empty text drops it.
    public func setDraft(thread: String, text: String?) {
        if let text, !text.isEmpty { drafts[thread] = text } else { drafts[thread] = nil }
    }

    public func allDrafts() -> [String: String] { drafts }

    public func sending(thread: String) -> Bool { sendingThreads.contains(thread) }

    public func allSending() -> Set<String> { sendingThreads }

    /// Claims the thread for a send; false when one is already being sent (Rule 5).
    func beginSend(thread: String) -> Bool { sendingThreads.insert(thread).inserted }

    func endSend(thread: String) { sendingThreads.remove(thread) }

    public func answer(thread: String) -> String? { answers[thread] }

    public func allAnswers() -> [String: String] { answers }

    /// Keeps what GitHub answered beside the thread's posted reply; nil drops it.
    func setAnswer(thread: String, text: String?) { answers[thread] = text }

    /// An org switch: the outgoing organisation's reads, drafts and flights go, and anything still
    /// running lands on a newer generation and is dropped.
    public func reset() {
        generation += 1
        for f in flights.values { f.task.cancel() }
        flights = [:]
        cache = [:]
        current = [:]
        failures = [:]
        drafts = [:]
        sendingThreads = []
        answers = [:]
        inFlightRead = nil
        records = [:]
        recordFailures = [:]
        shownReads = [:]
        shownFailures = [:]
        shownWhere = [:]
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
