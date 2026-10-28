import Foundation

/// The free function, which the property of the same name hides inside the extension.
private let ticketNeedsRowsOf: @Sendable (InFlightState, [String: TicketHandOffLive], [String: TicketDraftState])
    -> [TicketNeedsRow] = { ticketNeedsRows($0, handoffs: $1, drafts: $2) }

/// Ticket noticing: what needs the operator, read when (spec, *When it reads*). The window keeps the
/// active organisation's last `ticket_in_flight` read (`ticketNeeds`); it is read when the window is
/// ready and after an org switch, when Wakil comes back and the read is over 60 s old, after a write
/// from Wakil (the store's `wrote`), and every 2 minutes while Wakil is the active app and the screen
/// is unlocked — nothing for a window nobody is looking at. One read at a time: the store joins a
/// second ask to the one in flight (Rule 5); its 20 s limit and copy are piece 2's.
extension WindowModel {
    /// The tickets in flight, one row each, most urgent first: from `ticketNeeds`, the live handed
    /// conversations' states and the organisation's drafts.
    public var ticketNeedsRows: [TicketNeedsRow] {
        guard let ticketNeeds else { return [] }
        return ticketNeedsRowsOf(ticketNeeds, ticketHandOffLive, editorReviews.reads.draftRecords)
    }

    /// The live handed conversations' states, by conversation id.
    private var ticketHandOffLive: [String: TicketHandOffLive] {
        var live: [String: TicketHandOffLive] = [:]
        for c in liveConversationRows() {
            live[c.id] = switch c.state {
            case .working: .working
            case .waiting: .waiting
            case .failed: .failed
            case .done, .idle: .done
            }
        }
        return live
    }

    // MARK: - ⌘P

    /// ⌘P's tickets in flight, most urgent first, from the last In flight read (`ticketNeedsRows`); a PR
    /// row's words are its own most urgent state.
    func paletteTickets() -> [PaletteTicket] {
        let live = ticketHandOffLive, drafts = editorReviews.reads.draftRecords
        return ticketNeedsRows.map { row in
            paletteTicket(row, prWords: { r in
                ticketUrgentState(r, handoffs: live, drafts: r.threads.filter { drafts[$0] != nil }.count).words
            })
        }
    }

    /// The ticket source for `line` as typed (`#` included), over the last In flight read. Its keys are
    /// the projects' keys the read holds (`INI` of INI-142).
    func paletteTicketSource(line: String) -> TicketSource {
        let tickets = paletteTickets()
        return TicketSource(tickets: { tickets }, query: { line }, keys: paletteTicketKeys(tickets))
    }

    private func paletteTicketKeys(_ tickets: [PaletteTicket]) -> [String] {
        var keys: [String] = []
        for k in tickets.compactMap(\.key) {
            guard let dash = k.lastIndex(of: "-") else { continue }
            let prefix = String(k[..<dash])
            if !keys.contains(prefix) { keys.append(prefix) }
        }
        return keys
    }

    /// Whether `line` reads In flight when its read is over 60 s old (spec, *When it reads*): it starts
    /// with `#`, or holds a key-shaped word.
    func paletteLineReadsTickets(_ line: String) -> Bool {
        if line.hasPrefix("#") { return true }
        let tickets = paletteTickets()
        let keys = paletteTicketKeys(tickets), numbers = Set(tickets.flatMap(\.numbers))
        return PaletteSearch.words(line).contains { paletteKeyShaped($0, projectKeys: keys, numbers: numbers) }
    }

    /// ⌘P's ticket rows for an open-mode line just typed, from the last read — at once, so typing never
    /// waits. A `#` or key-shaped line whose read is over 60 s old reads In flight (joined to a read in
    /// flight), and `landed` gets the line's rows again when that read changed them.
    public func paletteTicketsTyped(line: String, landed: @escaping @MainActor ([PaletteEntry]) -> Void) -> [PaletteEntry] {
        let rows = paletteTicketSource(line: line).entries(paletteTickets())
        guard paletteLineReadsTickets(line) else { return rows }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.ticketNeedsRead(force: false)
            let fresh = self.paletteTicketSource(line: line).entries(self.paletteTickets())
            if fresh != rows { landed(fresh) }
        }
        return rows
    }

    /// The Mac's screen locked or unlocked (`com.apple.screenIsLocked` / `…Unlocked`): the 2-minute
    /// read stops for a locked screen and starts again on unlock.
    public func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        updateTicketPoll()
    }

    /// Starts or stops the 2-minute read for the window's state now.
    func updateTicketPoll() {
        if ticketPollWantedNow { startTicketPoll() } else { stopTicketPoll() }
    }

    /// Whether the 2-minute read is wanted now: a store, Wakil in front, the screen unlocked, an organisation.
    private var ticketPollWantedNow: Bool {
        ticket != nil && ticketPollWanted(appActive: appActive, screenLocked: screenLocked, organization: organization)
    }

    private func startTicketPoll() {
        guard ticketPollTask == nil else { return }
        ticketPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                do { try await self.ticketPollSleep(self.ticketPollInterval) } catch { return }
                // A resign or a lock that landed during the sleep reads nothing, cancelled or not.
                guard !Task.isCancelled, self.ticketPollWantedNow else { return }
                // In flight, and each shown Ticket view's branch, with no staleness check.
                let roots = await self.ticketViewRoots()
                guard !Task.isCancelled, self.ticketPollWantedNow else { return }
                for root in roots { self.ticketRead(root) }
                await self.ticketNeedsRead(force: true)
            }
        }
    }

    func stopTicketPoll() {
        ticketPollTask?.cancel()
        ticketPollTask = nil
    }

    /// Reads In flight — `force`, or when the last read is over 60 s old — joined to a read in flight.
    /// A failed read keeps the last needs; the store keeps why, whole.
    public func ticketNeedsRead(force: Bool) async {
        guard let ticket, !organization.isEmpty else { return }
        if !force, !(await ticket.inFlightStale()) { return }
        _ = try? await ticket.inFlight()
        await mirrorTicketNeeds()
    }

    /// The window is ready in an organisation, or a switch landed in one: its hand-offs whose
    /// conversation is not live end (a quit or the switch left them with none), then its In flight is
    /// read. Started, not awaited.
    func ticketOrganizationReady() {
        guard ticket != nil else { return }
        Task { @MainActor [weak self] in
            // A failed end is said whole in the status (`endStaleHandOffs`); the read runs all the same.
            await self?.endStaleHandOffs()
            await self?.ticketNeedsRead(force: true)
        }
    }
}

/// One `ticketNeedsRows` row as ⌘P reads it: title `INI-142  Login org page` (a keyless PR by its name,
/// `#215 · api`), its number and its PRs' for a bare-number match, PR rows `#212 ini-142-login` under a
/// keyed ticket, `ticket_open`'s params (`ticketOpenParams`), and ⌘↩'s hand-off from the header — none
/// when no project holds its branch, since an agent needs a root. The PR rows carry no `→ base`: the In
/// flight read does not name a PR's base.
public func paletteTicket(_ row: TicketNeedsRow, prWords: (InFlightRowState) -> String) -> PaletteTicket {
    let name = ticketNeedsRowName(row)
    let title = row.title.isEmpty ? name : "\(name)  \(row.title)"
    var numbers: [Int] = []
    if let key = row.key, let dash = key.lastIndex(of: "-"), let n = Int(key[key.index(after: dash)...]) { numbers.append(n) }
    var prs: [PaletteTicketPR] = []
    for r in row.rows where r.pr > 0 {
        if !numbers.contains(r.pr) { numbers.append(r.pr) }
        let id = "\(r.repo)#\(r.pr)"
        guard row.key != nil, !prs.contains(where: { $0.id == id }) else { continue }
        let one = TicketNeedsRow(id: row.id, key: row.key, title: row.title, urgent: row.urgent, rows: [r],
                                 activity: r.activity, openable: !r.root.isEmpty)
        prs.append(PaletteTicketPR(
            id: id, title: r.branch.isEmpty ? ticketRowName(key: "", repo: r.repo, pr: r.pr) : "#\(r.pr) \(r.branch)",
            words: prWords(r), open: ticketOpenParams(one)))
    }
    let open = ticketOpenParams(row)
    var handOff: JSONValue?
    if row.openable, case .object(var o) = open {
        o["from"] = .string("header")
        handOff = .object(o)
    }
    return PaletteTicket(id: row.id, title: title, words: row.urgent.words, key: row.key, numbers: numbers, prs: prs,
                         open: open, handOff: handOff, tier: row.urgent.tier, activity: row.activity)
}
