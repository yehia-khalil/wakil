import AppKit
import WakilKit
import SwiftUI

/// The editor column's fourth view, **Ticket** (Ticket view, piece 2 of Ticket work): the branch's
/// ticket header and **Next**, its pull requests with failing checks and open threads, the record as
/// one list with **+ Add**, the three non-ticket cases, and every source that could not be read,
/// whole. It decides nothing — the case, every line's words and the thread ⌥↓ steps to come from
/// WakilKit (`ticketViewCase`, `ticketPRLine`, `ticketThreadRow`, `reviewStep` …) — and every change
/// is a registry action through `dispatch` (Invariant 2). Its own state is what is being typed, the
/// + Add menu, and the link field's answer.
struct EditorTicketView: View {
    /// Where a link opens (`WakilLinks.open`): Wakil's browser pane, the system browser on ⌥-click.
    var openLink: (String, Bool) -> Void = { _, _ in }
    let state: EditorTicketViewState
    let column: EditorColumnState
    /// The pane's front tab: the view follows its root, else the project's first.
    let tab: EditorTab?
    /// The review boxes as placed: ⌥↓ steps from the thread whose box holds the cursor.
    let reviews: EditorReviewsState
    let dispatch: (String, [String: JSONValue]) async -> Void
    /// `dispatch`, its reply answered and its refusal thrown, so a link's answer and a write's
    /// refusal show here, under what was pressed (Rule 8).
    let dispatchReply: (String, [String: JSONValue]) async throws -> JSONValue
    var focused: FocusState<Bool>.Binding
    /// A field of this view holds the keyboard.
    @Binding var fieldHasKeyboard: Bool
    /// The file a thread row or ⌥↓ opens: browsing, so the keyboard stays in the column (Rule 6).
    @Binding var browsed: String?
    /// The Hand to agent popover is this pane's, from the header: **Hand to agent** anchors it.
    var handOffAnchored = false

    /// The record's **+ Add** menu is open.
    @State private var picking = false
    /// The kind + Add is adding a line of, with its focused field (Rule 3).
    @State private var adding: TicketSection?
    /// What the new line's fields hold so far: it is written once, with both, when the keyboard
    /// leaves the new row (Rule 2) — a decision's why is typed with it, not after (walk, 2026-10-27).
    @State private var addingMain = ""
    @State private var addingSecond = ""
    @State private var linking = false
    @State private var linkNote: String?
    /// A write's refusal, whole (Rule 8), until the next write.
    @State private var writeError: String?
    @FocusState private var fieldFocus: String?
    /// The record line under the pointer, and the one whose ✕ holds the keyboard: where ✕ shows.
    @State private var hoveredLine: String?
    @FocusState private var removeFocus: String?
    /// The Hand to agent popover's field as typed, when **Hand to agent** here anchors it.
    @State private var handOffDraft = TicketHandOffDraft()

    private var root: String? { ticketFollowedRoot(tab: tab, roots: state.roots) }
    private var branch: TicketBranchState? { root.flatMap { state.branches[$0] } }
    private var reading: Bool { root.map { state.reading.contains($0) } ?? false }
    private var failure: String? { root.flatMap { state.failures[$0] } }
    private var viewCase: TicketViewCase { ticketViewCase(state, column: column, root: root) }
    /// A keyless row picked from In flight or the Landing (a PR with no ticket key): where it is.
    private var keylessAt: TicketShownAt? {
        guard column.ticketShown == nil, let at = column.ticketShownAt, !at.root.isEmpty else { return nil }
        return at
    }
    /// The keyless row's own branch, once read; the view draws its case in place of the root's.
    private var keyless: TicketBranchState? { keylessAt.flatMap { state.shownBranches[$0.id] } }
    /// The branch the cases draw: the keyless row's, else the followed root's.
    private var viewed: TicketBranchState? { keylessAt == nil ? branch : keyless }
    /// The project a picked row's branch is in when it is not the screen's: its threads open nothing.
    private var elsewhere: String? {
        if let key = column.ticketShown { return ticketElsewhere(state.inFlightRow(key, at: column.ticketShownAt), roots: state.roots) }
        guard let at = keylessAt else { return nil }
        let row = state.inFlight.flatMap { s in (s.waitingOnYou + s.inFlight).first { $0.root == at.root && $0.branch == at.branch } }
        return ticketElsewhere(row, roots: state.roots)
    }
    /// The PR card `ticket_open` asked to scroll to, once it is drawn.
    private var scrollTarget: String? {
        guard let n = column.ticketScrollPR else { return nil }
        let drawn = [viewed, column.ticketShown.flatMap { state.shownBranches[$0] }].compactMap { $0 }.flatMap(\.prs)
        return drawn.contains { $0.number == n } ? "pr:\(n)" : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Space.m) {
                    topLine
                    switch viewCase {
                    case .loading:
                        backIfPicked
                        Text("Reading the ticket…").dimmed()
                            .accessibilityIdentifier("editor.ticket.loading")
                    case .unread:
                        // Nothing is reading (Rule 8): a root not read, or a first read cancelled.
                        Text(root == nil ? "No project roots to read" : "Not read. ↻ reads the ticket.").dimmed()
                            .accessibilityIdentifier("editor.ticket.unread")
                    case .error(let message):
                        backIfPicked
                        whole(message, id: "editor.ticket.error")
                    case .ticket:
                        if let key = column.ticketShown { shownTicket(key) } else if let b = viewed { backIfPicked; ownTicket(b) }
                    case .several:
                        if let b = viewed { backIfPicked; severalTickets(b) }
                    case .noTicket(let name):
                        if let b = viewed { backIfPicked; noTicket(b, name: name) }
                    case .longLived:
                        longLived
                    case .outside(let url):
                        outside(url)
                    }
                    if branch != nil, let failure { whole(failure, id: "editor.ticket.failure") }
                    if let writeError { whole(writeError, id: "editor.ticket.writeError") }
                    if let drafts = state.draftsFailure { whole(drafts, id: "editor.ticket.draftsFailure") }
                    partialLines
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `ticket_open` with a PR: its card scrolled into view once it is drawn.
            .onChange(of: scrollTarget, initial: true) { _, target in
                if let target { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) } }
            }
        }
        .focusable()
        .focused(focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.downArrow, .upArrow], phases: .down) { press in
            // ⌥↓ / ⌥↑ step the branch's open threads while focus is in the column (spec, decided
            // 2026-10-26); without ⌥ the keys are the scroll view's.
            guard press.modifiers.intersection([.command, .control, .option, .shift]) == .option else { return .ignored }
            step(press.key == .downArrow ? 1 : -1)
            return .handled
        }
        .onKeyPress(.escape) {
            // Esc closes + Add's menu (a field's own Esc drops its new line).
            guard picking else { return .ignored }
            picking = false
            return .handled
        }
        .onChange(of: fieldFocus) { _, now in fieldHasKeyboard = now != nil }
        .font(.system(size: 12))
        .foregroundStyle(EditorPaneStyle.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.ticket")
    }

    // MARK: - The top line: the root followed, and ↻

    private var topLine: some View {
        HStack(spacing: Space.s) {
            // Only with more than one root does the view say which it follows.
            if state.roots.count > 1, let root {
                Text((root as NSString).lastPathComponent).dimmed()
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("editor.ticket.root")
            }
            Spacer()
            if reading {
                EditorBusyTick(label: "reading", identifier: "editor.ticket.reading")
                // ↻ becomes Cancel while a read runs (Rule 4), and cannot be fired twice (Rule 5).
                Button("Cancel") { Task { await dispatch("ticket_refresh", ["cancel": .bool(true)]) } }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .accessibilityIdentifier("editor.ticket.cancel")
            } else {
                Button { Task { await dispatch("ticket_refresh", [:]) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .help("Read the ticket, pull requests and checks again")
                    .accessibilityIdentifier("editor.ticket.refresh")
            }
            handOffButton
        }
    }

    /// **Hand to agent** beside ↻: the popover, prefilled from the header (`ticketHandOffHeaderParams`).
    /// Not drawn where nothing can be handed — a pull request no project holds among them. While a
    /// live hand-off of this ticket works it reads **With agent · working** with the chip's dot, and
    /// **Agent finished · <what it left>** once its turn is done and unseen; either opens that
    /// conversation, as its chip does (walk 2026-10-28).
    @ViewBuilder
    private var handOffButton: some View {
        if let params = ticketHandOffHeaderParams(state, column: column, root: root) {
            let at = ticketHandOffHeader(state, params: params, drafts: reviews.reads.draftRecords)
            Group {
                if let conversation = at.conversation {
                    Button { Task { await dispatch("session_switch", ["conversation": .string(conversation)]) } } label: {
                        HStack(spacing: 5) {
                            ChipDot(colour: handOffDotHue(at.dot), breathes: at.dot == .working)
                            Text(at.label).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                    .help("Open the agent's conversation")
                    .accessibilityLabel(at.label)
                    .accessibilityIdentifier("editor.ticket.handOff.agent")
                } else {
                    Button("Hand to agent") { Task { await dispatch("ticket_hand_off_open", params) } }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(EditorPaneStyle.violet)
                        .help("Hand this ticket to an agent in the background, with a brief you can edit")
                        .accessibilityIdentifier("editor.ticket.handOff")
                }
            }
                .popover(isPresented: Binding(get: { handOffAnchored && state.handoff != nil }, set: { shown in
                    if !shown, state.handoff?.starting == false {
                        let p = handOffDraft.closeParams(state.handoff)
                        Task { await dispatch("ticket_hand_off_close", p) }
                    }
                }), arrowEdge: .bottom) {
                    if let h = state.handoff {
                        TicketHandOffPopover(state: h, dispatch: dispatch, dispatchReply: dispatchReply, draft: handOffDraft)
                            .id(h.subject)
                    }
                }
        }
    }

    /// The chip's hue for a hand-off's state (design A, agent chips): working violet, waiting amber,
    /// done green, failed red.
    private func handOffDotHue(_ live: TicketHandOffLive?) -> Color {
        switch live {
        case .waiting: EditorPaneStyle.amber
        case .done, .idle: Color(TerminalPalette.green)
        case .failed: Color(VoidPalette.red)
        default: EditorPaneStyle.violet
        }
    }

    // MARK: - The cases

    /// **← Back to this branch**, for a keyless row picked from In flight or the Landing.
    @ViewBuilder
    private var backIfPicked: some View {
        if keylessAt != nil { backButton }
    }

    private var backButton: some View {
        Button("← Back to this branch") { Task { await dispatch("ticket_show", ["key": .null]) } }
            .buttonStyle(.plain).foregroundStyle(EditorPaneStyle.violet)
            .accessibilityIdentifier("editor.ticket.back")
    }

    /// A pull request on a repository no project holds: no root to read it in, so no branch, threads
    /// or hand-off here — it opens on GitHub.
    @ViewBuilder
    private func outside(_ url: String) -> some View {
        backButton
        VStack(alignment: .leading, spacing: Space.s) {
            Text(ticketOutsideLine).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("editor.ticket.outside")
            if let link = URL(string: url), !url.isEmpty {
                Button("Open on GitHub ↗") { openLink(link.absoluteString, NSEvent.modifierFlags.contains(.option)) }
                    .buttonStyle(.plain).foregroundStyle(EditorPaneStyle.violet)
                    .help("Opens in Wakil's browser; ⌥-click for your system browser")
                    .accessibilityIdentifier("editor.ticket.outside.github")
            }
        }
    }

    @ViewBuilder
    private func ownTicket(_ b: TicketBranchState) -> some View {
        let t = b.tickets[0]
        TicketBlock(first: true) {
            header(key: t.key, title: t.title, status: t.status, waiting: ticketWaitingOn(b, record: t.record),
                   threads: ticketThreadsWaitingOnViewer(b), linked: b.linked)
            nextField(b)
        }
        pullRequests(b)
        record(t.record)
    }

    /// Each ticket the branch or its stack carries, the branch's own marked; a stack's never is.
    /// Picking one shows it (Rule 9), the branch unchanged.
    @ViewBuilder
    private func severalTickets(_ b: TicketBranchState) -> some View {
        TicketBlock(first: true) {
        Text("Tickets").microLabel(top: 0)
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(b.tickets, id: \.key) { t in
                Button { Task { await dispatch("ticket_show", ["key": .string(t.key)]) } } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Space.s) {
                            Text(t.marked ? "●" : " ").foregroundStyle(EditorPaneStyle.violet)
                            Text(t.key).ticketKey()
                            Text(t.title).lineLimit(1)
                            Spacer()
                            Text(t.status).dimmed()
                        }
                        Text(t.sources.map(ticketSourceLabel).joined(separator: ", ")).dimmed().font(.system(size: 11))
                            .padding(.leading, 14)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editor.ticket.ticket:\(t.key)")
            }
            if b.linked { unlinkButton(b) }
        }
        nextField(b)
        }
        pullRequests(b)
        if let target = ticketNextTarget(b), let t = b.tickets.first(where: { $0.key == target.key }) { record(t.record) }
    }

    @ViewBuilder
    private func noTicket(_ b: TicketBranchState, name: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("No ticket found for `\(name)`")
                .accessibilityIdentifier("editor.ticket.notFound")
            if let looked = ticketLookedLine(b.looked) {
                Text(looked).dimmed().fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("editor.ticket.looked")
            }
            if keylessAt != nil {
                // Linking names the root's current branch, never a picked one (Rule 6): nothing here.
                EmptyView()
            } else if linking {
                // Checked against the PM tool when it is left or Enter is pressed (Rule 2).
                TicketField(value: "", placeholder: "INI-142", id: "editor.ticket.linkField", focus: $fieldFocus,
                            arrivesFocused: true, left: { linking = false }) { key in
                    link(b, key: key)
                }
            } else {
                Button("Link a ticket…") { linkNote = nil; linking = true }
                    .buttonStyle(.plain).foregroundStyle(EditorPaneStyle.violet)
                    .accessibilityIdentifier("editor.ticket.link")
            }
            if let linkNote {
                whole(linkNote, id: "editor.ticket.linkNote")
            }
        }
        pullRequests(b)
    }

    /// The default or a long-lived branch: no header — Waiting on you, then In flight. Picking a row
    /// shows it; the branch never switches (Rule 6).
    @ViewBuilder
    private var longLived: some View {
        if let s = state.inFlight {
            inFlightList("Waiting on you", s.waitingOnYou, id: "waiting")
            inFlightList("In flight", ticketInFlightNotWaiting(s), id: "inflight")
            ForEach(ticketPartialLine(s.partial), id: \.self) { whole($0, id: "editor.ticket.partial") }
        } else {
            Text("Reading In flight…").dimmed().accessibilityIdentifier("editor.ticket.inflightLoading")
        }
    }

    private func inFlightList(_ title: String, _ rows: [InFlightRowState], id: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).microLabel()
            if rows.isEmpty { Text("None").font(.system(size: 11)).dimmed() }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Button {
                    // The row's own root and branch: two rows can carry one key.
                    Task { await dispatch("ticket_show", ["key": .string(r.key), "root": .string(r.root), "branch": .string(r.branch)]) }
                } label: {
                    // Two lines so a narrow column never breaks the key (walk, 2026-10-27): the key
                    // whole and the title truncating, then the status pill and Go's state words.
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Space.s) {
                            Text(ticketInFlightRowLabel(r)).ticketKey().lineLimit(1).fixedSize()
                            Text(r.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        }
                        HStack(spacing: Space.s) {
                            TicketPill(label: r.status, hue: ticketStatusHue(r.status))
                            // Go composes the row's one state in words; it shows as it came.
                            Text(r.state).font(.system(size: 10.5, design: .monospaced)).dimmed()
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editor.ticket.\(id):\(ticketInFlightRowName(r))")
            }
        }
    }

    /// A ticket picked from In flight, Waiting on you or among several: the full ticket view —
    /// header, Next, its pull requests with checks and threads, the record — with **Back to this
    /// branch**. A ticket this branch carries shows this branch's PRs; one from In flight, its own
    /// branch's, read by its row's root and branch. The branch never switches (Rule 6).
    @ViewBuilder
    private func shownTicket(_ key: String) -> some View {
        let at = column.ticketShownAt
        let carried = (branch?.tickets.contains { $0.key == key } ?? false)
            && (at == nil || (at?.root == root && at?.branch == branch?.branch))
        // A picked row's branch, only once the read of that row's branch has landed.
        let shown = state.shownBranches[key].flatMap { b in at == nil || b.branch == at?.branch ? b : nil }
        let own: TicketBranchState? = carried ? branch : shown
        let ref = own?.tickets.first { $0.key == key }
        let row = state.inFlightRow(key, at: at)
        let shownRecord = ticketShownRecord(state, key: key, ref: ref)
        let record: TicketRecordState? = if case .record(let r) = shownRecord { r } else { nil }
        backButton
        TicketBlock(first: true) {
            header(key: key, title: [ref?.title, row?.title, record?.seen.title].compactMap { $0 }.first { !$0.isEmpty } ?? "",
                   status: [ref?.status, row?.status, record?.seen.status].compactMap { $0 }.first { !$0.isEmpty } ?? "",
                   waiting: ticketWaitingOn(own ?? TicketBranchState(root: ""), record: record),
                   threads: own.map(ticketThreadsWaitingOnViewer) ?? 0, linked: false)
            if let record {
                nextLine(key: key, line: record.next, text: record.next?.text ?? "", labelled: false)
            }
        }
        if let own {
            pullRequests(own)
        } else if let failure = state.shownBranchFailures[key] {
            whole(failure, id: "editor.ticket.shownFailure")
        } else if let row, !row.branch.isEmpty {
            Text("Reading \(row.branch)…").dimmed().accessibilityIdentifier("editor.ticket.shownReading")
        }
        switch shownRecord {
        case .record(let r): self.record(r)
        case .failure(let failure):
            // A record that could not be read says so, whole (Rule 8) — never drawn as an empty one.
            whole(failure, id: "editor.ticket.recordFailure")
        case .none: EmptyView()
        }
    }

    // MARK: - The header and Next

    @ViewBuilder
    private func header(key: String, title: String, status: String, waiting: [String], threads: Int, linked: Bool) -> some View {
        Text("Ticket").microLabel(top: 0)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(key).ticketKey()
                Text(title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            }
            let line = ticketWaitingLine(waiting, threads: threads)
            if !status.isEmpty || line != nil {
                HStack(alignment: .center, spacing: 6) {
                    if !status.isEmpty { TicketPill(label: status, hue: ticketStatusHue(status)) }
                    if let line {
                        // The pill is the separator on screen; read aloud, the header stays one line:
                        // "In Progress · waiting on reviewer, you".
                        Text(line).dimmed().font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(status.isEmpty ? line : "· " + line)
                    }
                }
            }
            if linked, let b = branch { unlinkButton(b) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.ticket.header")
    }

    private func unlinkButton(_ b: TicketBranchState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Unlink asks nothing (Rule 7): it returns the branch to inference.
            Button("Unlink") { link(b, key: "") }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(EditorPaneStyle.violet)
                .accessibilityIdentifier("editor.ticket.unlink")
            // Its refusal, whole, under it (Rule 8).
            if let linkNote { whole(linkNote, id: "editor.ticket.unlinkNote") }
        }
    }

    @ViewBuilder
    private func nextField(_ b: TicketBranchState) -> some View {
        if let target = ticketNextTarget(b) {
            nextLine(key: target.key, line: b.tickets.first { $0.key == target.key }?.record.next, text: target.text,
                     labelled: target.labelled)
        }
    }

    /// **Next:** a field — focused on click (Rule 3), kept on blur (Rule 2), Enter a shortcut. It wraps
    /// to as many lines as it holds, never cut (the calmer column, 2026-10-28). Who wrote it and when
    /// is its hover, as every record line's. A Next in the operator's shape (`ticketNextShape`, the
    /// one a handed agent writes) draws its step as the field and its tool and blocker as small dim
    /// chips after it, a blocker other than nothing amber; the operator's own edit of the step is
    /// theirs, plain (walk 2026-10-28).
    private func nextLine(key: String, line: TicketLineState?, text: String, labelled: Bool) -> some View {
        let shape = ticketNextShape(text)
        return HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(labelled ? "Next (\(key))" : "Next").dimmed().fixedSize()
            TicketField(value: shape?.step ?? text, placeholder: "what happens next", id: "editor.ticket.next", focus: $fieldFocus,
                        wraps: true) { now in
                write(["key": .string(key), "section": .string("next"), "op": .string("set"), "text": .string(now)])
            }
            .id("next|\(key)")
            if let shape {
                TicketNextChip(label: shape.tool, amber: false)
                    .accessibilityIdentifier("editor.ticket.next.tool")
                TicketNextChip(label: "Blocked by \(shape.blocker)", amber: shape.blocked)
                    .accessibilityIdentifier("editor.ticket.next.blocker")
            }
        }
        .padding(.top, 2)
        .help(line.map { ticketLineCaption($0) } ?? "")
    }

    // MARK: - Pull requests

    /// **Pull requests** as hairline cards — number and title, the state and checks pills, the base —
    /// each failing check under its card; then **Threads**, every open one across them.
    @ViewBuilder
    private func pullRequests(_ b: TicketBranchState) -> some View {
        if !b.prs.isEmpty {
            TicketBlock {
                Text("Pull requests").microLabel(top: 0)
                ForEach(b.prs, id: \.number) { pr in prCard(pr) }
            }
        }
        let threads = ticketBranchThreads(b.prs)
        if !threads.isEmpty {
            TicketBlock {
                // The label and its count at either end; read aloud as one: "Threads · 2 open".
                HStack(alignment: .firstTextBaseline) {
                    Text("Threads").microLabel(top: 0)
                    Spacer(minLength: Space.s)
                    Text("\(threads.count) open").microLabel(top: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Threads · \(threads.count) open")
                let cursor = editorCursorThread(tab, reviews)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(threads, id: \.id) { t in threadRow(t, selected: t.id == cursor, elsewhere: elsewhere) }
                }
            }
        }
    }

    private func prCard(_ pr: PullRequestState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("#\(pr.number)").font(.system(size: 11, design: .monospaced))
                Text(pr.title.isEmpty ? pr.head : pr.title).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
            }
            // One element read as the PR's whole line: number, branches, state and checks.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ticketPRLine(pr))
            .accessibilityIdentifier("editor.ticket.pr:\(pr.number)")
            HStack(spacing: 6) {
                let state = ticketPRStatePill(pr)
                TicketPill(label: state.label, hue: state.hue)
                if let checks = ticketChecksPill(pr) { TicketPill(label: checks.label, hue: checks.hue) }
                if !pr.base.isEmpty {
                    Text("→ \(pr.base)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.35)).lineLimit(1)
                }
            }
            .accessibilityHidden(true)
            ForEach(Array(ticketFailingChecks(pr).enumerated()), id: \.offset) { _, c in
                HStack(spacing: Space.s) {
                    Text("✗ \(c.name)").foregroundStyle(TicketPill.colour(.red)).lineLimit(1)
                    Spacer()
                    if let s = c.url, let url = URL(string: s) {
                        Button("details ↗") { openLink(url.absoluteString, NSEvent.modifierFlags.contains(.option)) }
                            .buttonStyle(.plain).font(.system(size: 11))
                            .help("Opens in Wakil's browser; ⌥-click for your system browser")
                            .accessibilityIdentifier("editor.ticket.check:\(pr.number):\(c.name)")
                    }
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(EditorPaneStyle.text.opacity(0.08)))
        .id("pr:\(pr.number)")
    }

    /// A thread's row opens its file at its line; the column stays on Ticket, scrolled where it was,
    /// and keeps the keyboard (Rule 6). The thread whose box holds the cursor is tinted: where you are.
    ///
    /// A thread of another project of the organisation opens nothing (one place is on screen,
    /// Invariant 5): its row says which project it is in instead.
    private func threadRow(_ t: ReviewThreadState, selected: Bool, elsewhere: String?) -> some View {
        let row = ticketThreadRow(t, elsewhere: elsewhere)
        return Button {
            guard row.elsewhere == nil else { return }
            browsed = browsedKey(t)
            Task { await dispatch("review_open", ["thread": .string(t.id)]) }
        } label: {
            // Two lines so a narrow column reads the row whole (walk, 2026-10-27): the avatar, the
            // place — cut from the middle, so the line number always shows — and the replies; then
            // the comment's first words, wrapping to two lines.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    TicketAvatar(name: t.comments.first?.author ?? "")
                    Text(row.place).font(.system(size: 10.5, design: .monospaced)).opacity(0.6)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Space.s)
                    // A reply waits in the file's box to be sent, the operator's or an agent's.
                    if reviews.reads.drafts[t.id] != nil {
                        TicketPill(label: "draft", hue: .neutral).fixedSize()
                            .accessibilityIdentifier("editor.ticket.draft:\(t.id)")
                    }
                    if let replies = row.replies { Text(replies).dimmed().font(.system(size: 10.5)).fixedSize() }
                    if let there = row.elsewhere {
                        Text(there).dimmed().font(.system(size: 10.5)).fixedSize()
                            .accessibilityIdentifier("editor.ticket.elsewhere:\(t.id)")
                    }
                }
                Text(row.words).font(.system(size: 11.5)).lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3).padding(.horizontal, 4)
            .modifier(TicketRowTint(selected: selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.ticket.thread:\(t.id)")
    }

    /// ⌥↓ / ⌥↑ from the column: `review_step` from the thread whose box holds the cursor. The file it
    /// opens is browsing, so the keyboard stays here and the next ⌥↓ steps again.
    /// A ticket picked from In flight steps its own branch's threads, opening at its PR's head.
    private func step(_ delta: Int) {
        let picked = steppedPick
        guard let b = picked?.branch ?? branch else { return }
        let from = editorCursorThread(tab, reviews)
        if let to = reviewStep(reviewOpenThreads(b.prs), from: from, delta: delta) { browsed = browsedKey(to) }
        var params: [String: JSONValue] = ["delta": .integer(Int64(delta))]
        if let from { params["from"] = .string(from) }
        if let key = picked?.key { params["ticket"] = .string(key) }
        Task { await dispatch("review_step", params) }
    }

    /// The ticket picked from In flight and its branch, when the view shows one this branch does not carry.
    private var steppedPick: (key: String, branch: TicketBranchState)? {
        guard let key = column.ticketShown, let b = state.shownBranches[key],
              !(branch?.tickets.contains { $0.key == key } ?? false) else { return nil }
        return (key, b)
    }

    /// What a thread's row browses: its file, or — a picked ticket's on another branch — its head tab.
    private func browsedKey(_ t: ReviewThreadState) -> String {
        if case .diff = reviews.subject(t) { return editorTabKey(reviews.subject(t)) }
        return t.root + "/" + t.path
    }

    // MARK: - The record

    /// The record grouped by kind (the calmer column, 2026-10-28): its label, each hand-off, then one
    /// small heading per kind that holds a line (`Decisions 3`) with its lines as bullets under it,
    /// and one **+ Add** that asks which kind. Empty, it says what the record is for instead of
    /// drawing five empty headings.
    private func record(_ r: TicketRecordState) -> some View {
        let groups = ticketRecordGroups(r, including: adding?.rawValue)
        return TicketBlock {
            Text("Record").microLabel(top: 0)
            // Each hand-off as an entry by agent, newest first, above the lines (spec, *The hand-off in the record*).
            ForEach(r.handoffs.sorted { $0.at > $1.at }, id: \.id) { h in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Hand-off").font(.system(size: 9, weight: .semibold)).tracking(1.44).textCase(.uppercase)
                            .foregroundStyle(EditorPaneStyle.violet).lineLimit(1).fixedSize()
                        Spacer(minLength: Space.s)
                        Text("agent").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(EditorPaneStyle.text.opacity(0.45)).lineLimit(1).fixedSize()
                    }
                    Text(ticketHandOffEntry(h, live: state.handOffLive[h.conversation], now: Date()))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("editor.ticket.handoff:\(h.id)")
            }
            if groups.isEmpty && r.handoffs.isEmpty {
                Text("Nothing noted yet. Decisions, open work and checks you or an agent note on this ticket stay here for the next session.")
                    .font(.system(size: 11.5)).dimmed().lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(groups, id: \.kind) { g in
                if let section = TicketSection(rawValue: g.kind) { recordGroup(r, section, g) }
            }
            Button { picking.toggle() } label: {
                Text("+ Add").font(.system(size: 11)).foregroundStyle(TicketKindStyle.addText)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(EditorPaneStyle.violet.opacity(0.5)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Note a decision, open work, a wait, a check or a ruling on this ticket")
            .padding(.top, 4)
            .accessibilityIdentifier("editor.ticket.add")
            if picking { kindMenu }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.ticket.record")
    }

    /// One kind's group: its heading — a dot in its hue only where the kind means something (Not
    /// done and Waiting on amber, Verified green), its name and count — then its lines as bullets,
    /// and the new line + Add is typing when it is of this kind.
    private func recordGroup(_ r: TicketRecordState, _ section: TicketSection, _ g: TicketRecordGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let hue = g.hue { Circle().fill(TicketPill.colour(hue)).frame(width: 6, height: 6) }
                Text(g.heading).foregroundStyle(EditorPaneStyle.text.opacity(0.7))
                Text("\(g.count)").monospacedDigit().dimmed()
            }
            .font(.system(size: 11))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(g.heading) \(g.count)")
            ForEach(section.lines(r), id: \.id) { line in recordLine(r.key, section, line) }
            if adding == section {
                // A new line arrives focused (Rule 3). Its main field and, for a kind that has one,
                // its detail (why, how, what) are typed together; Tab moves between them, and the
                // line is written once when the keyboard leaves the row or on Enter (Rule 2). Left
                // empty it goes, and Esc drops it.
                bullet {
                    TicketField(value: "", placeholder: section.placeholder, id: "editor.ticket.new:\(section.rawValue)",
                                focus: $fieldFocus, wraps: true, arrivesFocused: true, left: { finishAdding(r.key) },
                                submitted: {
                                    // Enter goes on to the why when the kind has one, else writes the line.
                                    if let f = section.secondField?.field {
                                        fieldFocus = "editor.ticket.new:\(section.rawValue):\(f)"
                                    } else { fieldFocus = nil }
                                },
                                cancel: { cancelAdding() }) { text in addingMain = text }
                    if let second = section.secondField {
                        TicketField(value: "", placeholder: second.label,
                                    id: "editor.ticket.new:\(section.rawValue):\(second.field)",
                                    focus: $fieldFocus, wraps: true, left: { finishAdding(r.key) },
                                    submitted: { fieldFocus = nil },
                                    cancel: { cancelAdding() }) { text in addingSecond = text }
                            .font(.system(size: 11))
                            .foregroundStyle(EditorPaneStyle.text.opacity(0.55))
                    }
                } trailing: { EmptyView() }
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The kinds + Add offers; picking one opens its focused field (Rule 3), Esc closes it.
    private var kindMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(TicketSection.allCases, id: \.self) { section in
                Button {
                    picking = false
                    cancelAdding()
                    adding = section
                } label: {
                    Text(section.kind).font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(TicketRowTint(selected: false))
                .accessibilityIdentifier("editor.ticket.add:\(section.rawValue)")
            }
        }
        .padding(.vertical, 4)
        .frame(width: 170, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(TicketKindStyle.menu))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(EditorPaneStyle.text.opacity(0.12)))
        .padding(.top, 2)
    }

    /// One line of a group as a bullet: a small quiet dot, `content` beside it — the line, its detail
    /// dim under it — and `trailing` at the right. The text is one colour; the kind is the heading's.
    private func bullet(@ViewBuilder _ content: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(EditorPaneStyle.text.opacity(0.35)).frame(width: 3, height: 3)
                // Sat on the text's middle rather than its baseline.
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 3 }
                .padding(.leading, 3)
            VStack(alignment: .leading, spacing: 1) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line: its fields editable and kept on blur, removable without a question (Rule 1: the
    /// record's log keeps it). Who wrote it, when, and any edit show under the pointer, as its
    /// tooltip — never drawn. The detail (why, how, what) shows only when it holds something or the
    /// line is being edited, so an empty one never draws a placeholder; ✕ shows under the pointer or
    /// while the line has the keyboard.
    private func recordLine(_ key: String, _ section: TicketSection, _ line: TicketLineState) -> some View {
        let rowID = "editor.ticket.line:\(section.rawValue):\(line.id)"
        let editing = fieldFocus.map { $0 == rowID || $0.hasPrefix(rowID + ":") } ?? false
        let active = editing || hoveredLine == rowID || removeFocus == rowID
        return bullet {
            TicketField(value: line.value(section.mainField), placeholder: section.placeholder,
                        id: rowID, focus: $fieldFocus, wraps: true) { now in
                edit(key, section, line, field: section.mainField, now)
            }
            if let second = section.secondField {
                // Folded away rather than removed while empty, so leaving it still keeps what was
                // typed (Rule 2) and Tab from the line still reaches it.
                TicketField(value: line.value(second.field), placeholder: second.label,
                            id: "\(rowID):\(second.field)", focus: $fieldFocus, wraps: true) { now in
                    edit(key, section, line, field: second.field, now)
                }
                .font(.system(size: 11))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.55))
                .modifier(TicketFolded(folded: !editing && line.value(second.field).isEmpty))
            }
        } trailing: {
            Button { write(["key": .string(key), "section": .string(section.rawValue), "op": .string("remove"),
                            "id": .string(line.id)]) } label: { Image(systemName: "xmark").foregroundStyle(xmark(active)) }
                .buttonStyle(.plain).font(.system(size: 9))
                .focused($removeFocus, equals: rowID)
                .help("Remove this line (the record's log keeps it)")
                .accessibilityIdentifier("editor.ticket.remove:\(section.rawValue):\(line.id)")
        }
        .help(ticketLineCaption(line))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredLine = rowID } else if hoveredLine == rowID { hoveredLine = nil }
        }
    }

    /// ✕'s colour: shown at 0.6, or clear — hidden by colour, not opacity, so it stays in the tree.
    private func xmark(_ shown: Bool) -> Color { EditorPaneStyle.text.opacity(shown ? 0.6 : 0) }

    /// Writes the new line once the keyboard has left both of its fields; a hop from one field
    /// to the other is not a leave. Empty main text drops it.
    private func finishAdding(_ key: String) {
        Task { @MainActor in
            // A turn later: focus has landed on the next field by then.
            if let f = fieldFocus, f.hasPrefix("editor.ticket.new:") { return }
            guard let section = adding else { return }
            let main = addingMain.trimmingCharacters(in: .whitespacesAndNewlines)
            let second = addingSecond.trimmingCharacters(in: .whitespacesAndNewlines)
            cancelAdding()
            guard !main.isEmpty else { return }
            var params: [String: JSONValue] = ["key": .string(key), "section": .string(section.rawValue),
                                               "op": .string("add"), section.mainField: .string(main)]
            if let field = section.secondField?.field, !second.isEmpty { params[field] = .string(second) }
            write(params)
        }
    }

    private func cancelAdding() {
        adding = nil
        addingMain = ""
        addingSecond = ""
    }

    // MARK: - Writes

    private func edit(_ key: String, _ section: TicketSection, _ line: TicketLineState, field: String, _ text: String) {
        guard text != line.value(field) else { return }
        write(["key": .string(key), "section": .string(section.rawValue), "op": .string("edit"), "id": .string(line.id),
               field: .string(text)])
    }

    private func write(_ params: [String: JSONValue]) {
        Task {
            do {
                _ = try await dispatchReply("ticket_record_update", params)
                writeError = nil
            } catch {
                writeError = "\(error)"
            }
        }
    }

    /// A key links the branch (an unfound one is kept and says so, Rule 7); an empty one unlinks.
    private func link(_ b: TicketBranchState, key: String) {
        Task {
            do {
                let reply = try await dispatchReply("ticket_link", ["root": .string(b.root), "key": .string(key)])
                linkNote = ticketLinkNote(reply)
                linking = false
            } catch {
                linkNote = "\(error)"
            }
        }
    }

    // MARK: - Partial sources

    /// Each source that could not be read, whole; the rest still shows (Rule 8).
    @ViewBuilder
    private var partialLines: some View {
        if let b = branch {
            ForEach(ticketPartialLines(b), id: \.self) { whole($0, id: "editor.ticket.partial") }
        }
    }

    private func whole(_ text: String, id: String) -> some View {
        Text(text).foregroundStyle(EditorPaneStyle.text.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .accessibilityIdentifier(id)
    }

    private enum Space {
        static let s: CGFloat = 4, m: CGFloat = 8
    }
}

/// The record's five kinds, with the field each line leads with and the one under it.
enum TicketSection: String, CaseIterable {
    case decisions, notDone, waitingOn, verified, rulings

    /// The kind one line is, as its row and + Add's menu name it.
    var kind: String {
        switch self {
        case .decisions: "Decision"
        case .notDone: "Not done"
        case .waitingOn: "Waiting on"
        case .verified: "Verified"
        case .rulings: "Ruling"
        }
    }

    var placeholder: String {
        switch self {
        case .decisions: "what was decided"
        case .notDone: "what is not done"
        case .waitingOn: "who"
        case .verified: "what was checked"
        case .rulings: "the ruling"
        }
    }

    var mainField: String { self == .waitingOn ? "who" : "text" }

    /// Decisions and rulings say why, Verified how, Waiting on what.
    var secondField: (field: String, label: String)? {
        switch self {
        case .decisions, .rulings: ("why", "why")
        case .verified: ("how", "how")
        case .waitingOn: ("what", "what")
        case .notDone: nil
        }
    }

    func lines(_ r: TicketRecordState) -> [TicketLineState] {
        switch self {
        case .decisions: r.decisions
        case .notDone: r.notDone
        case .waitingOn: r.waitingOn
        case .verified: r.verified
        case .rulings: r.rulings
        }
    }
}

private extension TicketLineState {
    func value(_ field: String) -> String {
        switch field {
        case "why": why
        case "how": how
        case "who": who
        case "what": what
        default: text
        }
    }
}

/// One line of text that keeps what was typed when focus leaves it (Rule 2), Enter a shortcut:
/// `commit` hears the text when it differs from `value`, then `left` that focus went. It follows
/// `value` while not being typed in.
private struct TicketField: View {
    let value: String
    let placeholder: String
    let id: String
    var focus: FocusState<String?>.Binding
    /// A long value wraps at the column's edge instead of scrolling inside the field; Return still
    /// commits, and a line break from Option-Return or a paste never reaches the record.
    var wraps = false
    var arrivesFocused = false
    var left: () -> Void = {}
    /// Enter, after the text is sent: where the keyboard goes next, when the caller says.
    var submitted: () -> Void = {}
    /// Esc drops what was typed, unsent, when given; without it Esc is not the field's.
    var cancel: (() -> Void)?
    let commit: (String) -> Void

    @State private var text = ""
    @State private var commits = TicketFieldCommits()
    @State private var cancelled = false

    var body: some View {
        TextField(placeholder, text: $text, axis: wraps ? .vertical : .horizontal)
            .lineLimit(wraps ? 1...Int.max : 1...1)
            .textFieldStyle(.plain)
            .focused(focus, equals: id)
            .onSubmit { send(leaving: false); submitted() }
            .onKeyPress(.escape) {
                guard let cancel else { return .ignored }
                cancelled = true
                cancel()
                return .handled
            }
            .onChange(of: text) { commits.edited() }
            .onAppear {
                text = value
                if arrivesFocused { Task { @MainActor in focus.wrappedValue = id } }
            }
            .onChange(of: value) { _, now in if focus.wrappedValue != id { text = now } }
            .onChange(of: focus.wrappedValue) { was, now in
                if was == id, now != id { send(leaving: true) }
            }
            .accessibilityIdentifier(id)
    }

    /// Once per edit: Enter then leaving sends the text once (`TicketFieldCommits`).
    private func send(leaving: Bool) {
        guard !cancelled else { return }
        let typed = wraps ? apiSingleLineText(text) : text
        if let now = commits.commit(typed, value: value) { commit(now) }
        if leaving { left() }
    }
}

private extension View {
    func dimmed() -> some View { foregroundStyle(EditorPaneStyle.text.opacity(0.55)) }
}

private extension Text {
    /// §6's micro-label: uppercase, tracked .2em, 9 pt, low opacity — a section's name.
    /// In a `TicketBlock` it sits at the block's top (`top: 0`): the hairline and its space set it off.
    func microLabel(top: CGFloat = 6) -> some View {
        font(.system(size: 9, weight: .semibold)).tracking(1.8).textCase(.uppercase)
            .foregroundStyle(EditorPaneStyle.text.opacity(0.42))
            .padding(.top, top)
    }

    /// A ticket key: an identifier, so mono (§6), in the column's violet tick.
    func ticketKey() -> Text {
        font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(EditorPaneStyle.tick)
    }
}

/// One section of the view as a block (the calmer column, 2026-10-28): a hairline above it, except
/// the first, and room around it, so Ticket, Pull requests, Threads and Record read apart.
private struct TicketBlock<Content: View>: View {
    var first = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, first ? 0 : 10)
            .padding(.bottom, 4)
            .overlay(alignment: .top) {
                if !first { Rectangle().fill(EditorPaneStyle.text.opacity(0.08)).frame(height: 1) }
            }
    }
}

/// A status pill: a dot in its meaning's hue (§5's reserved green, amber, red; grey for none) and
/// its word, in a hairline capsule.
/// A Next's tool or blocker after its step: small, dim, monospaced for the tool; amber when it blocks.
private struct TicketNextChip: View {
    let label: String
    let amber: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(amber ? EditorPaneStyle.amber : EditorPaneStyle.text.opacity(0.55))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder((amber ? EditorPaneStyle.amber : EditorPaneStyle.text).opacity(0.18)))
            .fixedSize()
    }
}

private struct TicketPill: View {
    let label: String
    let hue: TicketHue

    static func colour(_ hue: TicketHue) -> Color {
        switch hue {
        case .green: Color(TerminalPalette.green)
        case .amber: EditorPaneStyle.amber
        case .red: Color(VoidPalette.red)
        case .neutral: EditorPaneStyle.text.opacity(0.4)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Self.colour(hue)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10.5)).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 1)
        .overlay(Capsule().strokeBorder(EditorPaneStyle.text.opacity(0.14)))
        .opacity(0.85)
    }
}

/// + Add's violet text and its menu's surface. The kinds' hues are `ticketRecordGroups`'.
private enum TicketKindStyle {
    static let addText = Color(red: 0xcf / 255, green: 0xc3 / 255, blue: 0xff / 255)
    static let menu = Color(red: 0x0e / 255, green: 0x10 / 255, blue: 0x19 / 255)
}

/// A commenter's initial in a quiet disc.
private struct TicketAvatar: View {
    let name: String
    var body: some View {
        Text(name.first.map(String.init) ?? "?")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color(red: 0x2a / 255, green: 0x2f / 255, blue: 0x44 / 255)))
            .accessibilityHidden(true)
    }
}

/// An empty detail field folded to nothing while its line is not being edited: still there, so
/// its commit on leaving runs and the keyboard can reach it, but drawing no placeholder.
private struct TicketFolded: ViewModifier {
    let folded: Bool
    func body(content: Content) -> some View {
        // One branch, so folding never replaces the field and the keyboard stays in it.
        content.frame(height: folded ? 0 : nil).clipped().opacity(folded ? 0 : 1).accessibilityHidden(folded)
    }
}

/// A thread row's tint: violet at low alpha where the cursor's thread is, and under the pointer.
private struct TicketRowTint: ViewModifier {
    let selected: Bool
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 5).fill(EditorPaneStyle.violet.opacity(selected || hovered ? 0.10 : 0)))
            .onHover { hovered = $0 }
    }
}
