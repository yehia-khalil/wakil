import AppKit
import WakilKit
import SwiftUI

/// The editor column's fourth view, **Ticket** (Ticket view, piece 2 of Ticket work): the branch's
/// ticket header and **Next**, its pull requests with failing checks and open threads, the record's
/// lists folded under one line, the three non-ticket cases, and every source that could not be read,
/// whole. It decides nothing — the case, every line's words and the thread ⌥↓ steps to come from
/// WakilKit (`ticketViewCase`, `ticketPRLine`, `ticketThreadRow`, `reviewStep` …) — and every change
/// is a registry action through `dispatch` (Invariant 2). Its own state is what is being typed, the
/// fold, and the link field's answer.
struct EditorTicketView: View {
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

    /// The record's lists, open under their fold line: the pane's, for the column's life.
    @State private var recordOpen = false
    /// The list whose **+** is adding a line, with its focused field (Rule 3).
    @State private var adding: TicketSection?
    @State private var linking = false
    @State private var linkNote: String?
    /// A write's refusal, whole (Rule 8), until the next write.
    @State private var writeError: String?
    @FocusState private var fieldFocus: String?

    private var root: String? { ticketFollowedRoot(tab: tab, roots: state.roots) }
    private var branch: TicketBranchState? { root.flatMap { state.branches[$0] } }
    private var reading: Bool { root.map { state.reading.contains($0) } ?? false }
    private var failure: String? { root.flatMap { state.failures[$0] } }
    private var viewCase: TicketViewCase {
        ticketViewCase(branch, shown: column.ticketShown, failure: failure, reading: reading)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.m) {
                topLine
                switch viewCase {
                case .loading:
                    Text("Reading the ticket…").dimmed()
                        .accessibilityIdentifier("editor.ticket.loading")
                case .unread:
                    // Nothing is reading (Rule 8): a root not read, or a first read cancelled.
                    Text(root == nil ? "No project roots to read" : "Not read. ↻ reads the ticket.").dimmed()
                        .accessibilityIdentifier("editor.ticket.unread")
                case .error(let message):
                    whole(message, id: "editor.ticket.error")
                case .ticket:
                    if let key = column.ticketShown { shownTicket(key) } else if let b = branch { ownTicket(b) }
                case .several:
                    if let b = branch { severalTickets(b) }
                case .noTicket(let name):
                    if let b = branch { noTicket(b, name: name) }
                case .longLived:
                    longLived
                }
                if branch != nil, let failure { whole(failure, id: "editor.ticket.failure") }
                if let writeError { whole(writeError, id: "editor.ticket.writeError") }
                partialLines
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        }
    }

    // MARK: - The cases

    @ViewBuilder
    private func ownTicket(_ b: TicketBranchState) -> some View {
        let t = b.tickets[0]
        header(key: t.key, title: t.title, status: t.status, waiting: ticketWaitingOn(b, record: t.record), linked: b.linked)
        nextField(b)
        pullRequests(b)
        record(t.record)
    }

    /// Each ticket the branch or its stack carries, the branch's own marked; a stack's never is.
    /// Picking one shows it (Rule 9), the branch unchanged.
    @ViewBuilder
    private func severalTickets(_ b: TicketBranchState) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(b.tickets, id: \.key) { t in
                Button { Task { await dispatch("ticket_show", ["key": .string(t.key)]) } } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Space.s) {
                            Text(t.marked ? "●" : " ").foregroundStyle(EditorPaneStyle.violet)
                            Text(t.key).bold()
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
            if linking {
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
            inFlightList("In flight", s.inFlight, id: "inflight")
            ForEach(ticketPartialLine(s.partial), id: \.self) { whole($0, id: "editor.ticket.partial") }
        } else {
            Text("Reading In flight…").dimmed().accessibilityIdentifier("editor.ticket.inflightLoading")
        }
    }

    private func inFlightList(_ title: String, _ rows: [InFlightRowState], id: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).sectionTitle()
            if rows.isEmpty { Text("None").dimmed() }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Button {
                    // The row's own root and branch: two rows can carry one key.
                    Task { await dispatch("ticket_show", ["key": .string(r.key), "root": .string(r.root), "branch": .string(r.branch)]) }
                } label: {
                    HStack(spacing: Space.s) {
                        Text(r.key).bold()
                        Text(r.title).lineLimit(1)
                        Spacer(minLength: Space.s)
                        Text(r.status).dimmed()
                        // Go composes the row's one state in words; it shows as it came.
                        Text(r.state).foregroundStyle(EditorPaneStyle.amber).lineLimit(1)
                    }
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
        Button("← Back to this branch") { Task { await dispatch("ticket_show", ["key": .null]) } }
            .buttonStyle(.plain).foregroundStyle(EditorPaneStyle.violet)
            .accessibilityIdentifier("editor.ticket.back")
        header(key: key, title: [ref?.title, row?.title, record?.seen.title].compactMap { $0 }.first { !$0.isEmpty } ?? "",
               status: [ref?.status, row?.status, record?.seen.status].compactMap { $0 }.first { !$0.isEmpty } ?? "",
               waiting: ticketWaitingOn(own ?? TicketBranchState(root: ""), record: record), linked: false)
        if let record {
            nextLine(key: key, text: record.next?.text ?? "", labelled: false)
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
    private func header(key: String, title: String, status: String, waiting: [String], linked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(key).bold()
                Text(title).fixedSize(horizontal: false, vertical: true)
            }
            let line = ([status].filter { !$0.isEmpty } + (waiting.isEmpty ? [] : ["waiting on " + waiting.joined(separator: ", ")]))
                .joined(separator: " · ")
            if !line.isEmpty { Text(line).dimmed() }
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
        if let target = ticketNextTarget(b) { nextLine(key: target.key, text: target.text, labelled: target.labelled) }
    }

    /// **Next:** a field — focused on click (Rule 3), kept on blur (Rule 2), Enter a shortcut.
    private func nextLine(key: String, text: String, labelled: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(labelled ? "Next (\(key)):" : "Next:").bold()
            TicketField(value: text, placeholder: "what happens next", id: "editor.ticket.next", focus: $fieldFocus) { now in
                write(["key": .string(key), "section": .string("next"), "op": .string("set"), "text": .string(now)])
            }
            .id("next|\(key)")
        }
    }

    // MARK: - Pull requests

    @ViewBuilder
    private func pullRequests(_ b: TicketBranchState) -> some View {
        ForEach(b.prs, id: \.number) { pr in
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 3) {
                Text(ticketPRLine(pr)).font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("editor.ticket.pr:\(pr.number)")
                ForEach(Array(ticketFailingChecks(pr).enumerated()), id: \.offset) { _, c in
                    HStack(spacing: Space.s) {
                        Text("✗ \(c.name)").foregroundStyle(EditorPaneStyle.amber).lineLimit(1)
                        Spacer()
                        if let s = c.url, let url = URL(string: s) {
                            Link("details ↗", destination: url).font(.system(size: 11))
                                .accessibilityIdentifier("editor.ticket.check:\(pr.number):\(c.name)")
                        }
                    }
                    .padding(.leading, Space.m)
                }
                ForEach(ticketColumnThreads(pr), id: \.id) { t in threadRow(t) }
            }
        }
        if !b.prs.isEmpty { Divider().opacity(0.3) }
    }

    /// A thread's row opens its file at its line; the column stays on Ticket, scrolled where it was,
    /// and keeps the keyboard (Rule 6).
    private func threadRow(_ t: ReviewThreadState) -> some View {
        let row = ticketThreadRow(t)
        return Button {
            browsed = t.root + "/" + t.path
            Task { await dispatch("review_open", ["thread": .string(t.id)]) }
        } label: {
            HStack(spacing: Space.s) {
                Text(row.place).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Text("\u{201C}\(row.words)\u{201D}").lineLimit(1).dimmed()
                Spacer(minLength: Space.s)
                if let replies = row.replies { Text(replies).dimmed().font(.system(size: 11)) }
            }
            .padding(.leading, Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.ticket.thread:\(t.id)")
    }

    /// ⌥↓ / ⌥↑ from the column: `review_step` from the thread whose box holds the cursor. The file it
    /// opens is browsing, so the keyboard stays here and the next ⌥↓ steps again.
    private func step(_ delta: Int) {
        guard let b = branch else { return }
        let from = editorCursorThread(tab, reviews)
        if let to = reviewStep(reviewOpenThreads(b.prs), from: from, delta: delta) { browsed = to.root + "/" + to.path }
        var params: [String: JSONValue] = ["delta": .integer(Int64(delta))]
        if let from { params["from"] = .string(from) }
        Task { await dispatch("review_step", params) }
    }

    // MARK: - The record

    @ViewBuilder
    private func record(_ r: TicketRecordState) -> some View {
        Button {
            recordOpen.toggle()
        } label: {
            Text(recordOpen ? ticketFoldLine(r).replacingOccurrences(of: "▸", with: "▾") : ticketFoldLine(r))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.ticket.fold")
        if recordOpen {
            ForEach(TicketSection.allCases, id: \.self) { section in recordList(r, section) }
        }
    }

    private func recordList(_ r: TicketRecordState, _ section: TicketSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(section.title).sectionTitle()
                Button { adding = section } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).font(.system(size: 10))
                    .help("Add a line to \(section.title)")
                    .accessibilityIdentifier("editor.ticket.add:\(section.rawValue)")
            }
            ForEach(section.lines(r), id: \.id) { line in recordLine(r.key, section, line) }
            if adding == section {
                // A new line arrives focused (Rule 3) and is kept when focus leaves it (Rule 2); left
                // empty, it goes.
                TicketField(value: "", placeholder: section.placeholder, id: "editor.ticket.new:\(section.rawValue)",
                            focus: $fieldFocus, arrivesFocused: true, left: { adding = nil }) { text in
                    adding = nil
                    write(["key": .string(r.key), "section": .string(section.rawValue), "op": .string("add"),
                           section.mainField: .string(text)])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.ticket.list:\(section.rawValue)")
    }

    /// One line: its fields editable and kept on blur, removable without a question (Rule 1: the
    /// record's log keeps it), and who wrote it when.
    private func recordLine(_ key: String, _ section: TicketSection, _ line: TicketLineState) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                TicketField(value: line.value(section.mainField), placeholder: section.placeholder,
                            id: "editor.ticket.line:\(section.rawValue):\(line.id)", focus: $fieldFocus) { now in
                    edit(key, section, line, field: section.mainField, now)
                }
                Button { write(["key": .string(key), "section": .string(section.rawValue), "op": .string("remove"),
                                "id": .string(line.id)]) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 9)).opacity(0.6)
                    .help("Remove this line (the record's log keeps it)")
                    .accessibilityIdentifier("editor.ticket.remove:\(section.rawValue):\(line.id)")
            }
            if let second = section.secondField {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(second.label).dimmed().font(.system(size: 11))
                    TicketField(value: line.value(second.field), placeholder: second.label,
                                id: "editor.ticket.line:\(section.rawValue):\(line.id):\(second.field)", focus: $fieldFocus) { now in
                        edit(key, section, line, field: second.field, now)
                    }
                }
                .padding(.leading, Space.m)
            }
            Text(ticketLineCaption(line)).dimmed().font(.system(size: 10))
                .accessibilityIdentifier("editor.ticket.by:\(section.rawValue):\(line.id)")
        }
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

/// The record's five lists, with the field each line leads with and the one under it.
enum TicketSection: String, CaseIterable {
    case decisions, notDone, waitingOn, verified, rulings

    var title: String {
        switch self {
        case .decisions: "Decisions"
        case .notDone: "Not done"
        case .waitingOn: "Waiting on"
        case .verified: "Verified"
        case .rulings: "Rulings"
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
    var arrivesFocused = false
    var left: () -> Void = {}
    let commit: (String) -> Void

    @State private var text = ""
    @State private var commits = TicketFieldCommits()

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused(focus, equals: id)
            .onSubmit { send(leaving: false) }
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
        if let now = commits.commit(text, value: value) { commit(now) }
        if leaving { left() }
    }
}

private extension View {
    func dimmed() -> some View { foregroundStyle(EditorPaneStyle.text.opacity(0.55)) }
    func sectionTitle() -> some View {
        font(.system(size: 10, weight: .semibold)).foregroundStyle(EditorPaneStyle.text.opacity(0.55)).textCase(.uppercase)
    }
}
