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
        var live: [String: TicketHandOffLive] = [:]
        for c in liveConversationRows() {
            live[c.id] = switch c.state {
            case .working: .working
            case .waiting: .waiting
            case .failed: .failed
            case .done, .idle: .done
            }
        }
        return ticketNeedsRowsOf(ticketNeeds, live, editorReviews.reads.draftRecords)
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
    func ticketNeedsRead(force: Bool) async {
        guard let ticket, !organization.isEmpty else { return }
        if !force, !(await ticket.inFlightStale()) { return }
        _ = try? await ticket.inFlight()
        await mirrorTicketNeeds()
    }

    /// The window is ready in an organisation, or a switch landed in one: its hand-offs whose
    /// conversation is not live end (a quit or the switch left them with none), then its In flight is
    /// read. Started, not awaited.
    func ticketOrganizationReady() {
        guard let ticket else { return }
        let live = liveConversations().map(\.id)
        Task { @MainActor [weak self] in
            try? await ticket.endStaleHandoffs(live: live)
            await self?.ticketNeedsRead(force: true)
        }
    }
}
