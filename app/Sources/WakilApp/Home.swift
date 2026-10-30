import WakilKit
import SwiftUI

/// The home screen (workspaces, piece 3; mockup `home.html`): one per organisation, grouped by
/// project, a card per workspace. Everything it shows is decided by `homeScreen` in WakilKit
/// (`Workspace/HomeScreen.swift`); this file only draws it and dispatches through `WindowModel`
/// (Invariant 2): a line through `switchToRunning` (`session_switch`), a card, a project's Open and
/// Earlier's rows through `workspace_open`, `workspace_restore` and `session_resume`.
///
/// **One scroll for the page, nothing capped** (decision 20): no column has a height, no text a
/// line limit; a long branch or title wraps whole.
struct Home: View {
    let model: WindowModel
    /// Opens ⌘P in open mode with `#` typed: every ticket in flight.
    let openTicketsPalette: () -> Void

    @State private var screen: HomeScreen?
    @State private var projects: [WindowModel.ProjectListing] = []
    @State private var past: [PaletteItem] = []
    @State private var filter: String?
    @State private var earlierOpen = false
    @State private var hovered: String?
    @State private var renaming: String?
    /// Bumped after a card action, so the page re-reads what it changed.
    @State private var revision = 0
    /// A card action in flight (Rule 5): its card's controls are disabled meanwhile.
    @State private var busy: String?
    /// Archive with a conversation waiting on the operator asks first (Rule 1).
    @State private var confirmingArchive: HomeCard?

    private var coolWhite: Color { Color(red: 0.910, green: 0.925, blue: 0.965) }
    private var violet: Color { Color(red: 0.620, green: 0.510, blue: 1.0) }
    private var amber: Color { Color(TerminalPalette.amber) }
    private var red: Color { Color(EnvironmentBadge.productionColour) }
    private var hasProject: Bool { !model.project.isEmpty }

    /// What the page depends on: the place, every live conversation's state and title, the tickets read.
    private var readKey: String {
        let live = model.liveConversationRows().map { "\($0.id):\($0.state.rawValue):\($0.title):\($0.workspace?.id ?? "")" }
        return "\(model.organization)/\(model.projectKey)/\(model.environment)|\(live.joined(separator: ","))|"
            + "\(model.ticketNeedsRows.count)|\(filter ?? "")|\(revision)"
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                if hasProject, let screen {
                    header(screen)
                    if screen.firstRun { firstRun(screen) } else { page(screen) }
                } else if hasProject {
                    note("Reading workspaces…")
                } else {
                    projectRows
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: readKey) {
            projects = await model.listProjects()
            past = await model.landingSessions()
            screen = await model.readHomeScreen(projects: projects.map(\.name), past: past, filter: filter)
        }
        .task(id: model.organization) { await model.ticketNeedsRead(force: false) }
        .confirmationDialog(
            confirmingArchive.map { "Archive ‘\($0.name)’?" } ?? "",
            isPresented: Binding(get: { confirmingArchive != nil }, set: { if !$0 { confirmingArchive = nil } })
        ) {
            if let card = confirmingArchive {
                Button("Archive") { run(card.id) { await model.archiveWorkspace(card.id, confirm: true) } }
                    .accessibilityIdentifier("landing.archive.confirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("landing.archive.cancel")
            }
        } message: {
            Text("A conversation in it is waiting for you. Its uncommitted work is kept as a snapshot and the copies are removed; Restore brings it back.")
        }
    }

    // MARK: - Header and help

    private func header(_ screen: HomeScreen) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(screen.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(coolWhite.opacity(0.94))
                    .accessibilityIdentifier("landing.title")
                if !screen.helpInFull {
                    Image(systemName: "info.circle")
                        .foregroundStyle(coolWhite.opacity(0.5))
                        .help(HomeScreen.help)
                        .accessibilityLabel(HomeScreen.help)
                        .accessibilityIdentifier("landing.help.info")
                }
                Spacer(minLength: 8)
                Text("⌘N new conversation in Main of \(model.project)")
                    .font(.system(size: 11))
                    .foregroundStyle(coolWhite.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if screen.helpInFull {
                Text(HomeScreen.help)
                    .font(.system(size: 12.5))
                    .foregroundStyle(coolWhite.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("landing.help")
            }
            if !screen.pills.isEmpty { pills(screen.pills) }
        }
        .padding(.top, 8)
    }

    private func pills(_ pills: [HomePill]) -> some View {
        WrappingRow(spacing: 8) {
            ForEach(pills) { pill in
                let key = pill.project ?? "all"
                Button { filter = pill.project } label: {
                    HStack(spacing: 6) {
                        Text(pill.label).font(.system(size: 12))
                        if pill.needsYou > 0 {
                            Text("● \(pill.needsYou)").font(.system(size: 11)).foregroundStyle(amber)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(coolWhite.opacity(pill.selected ? 0.16 : 0.05)))
                    .foregroundStyle(coolWhite.opacity(pill.selected ? 0.95 : 0.7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("landing.pill.\(key)")
                .accessibilityValue(pill.selected ? "selected" : "")
            }
        }
    }

    // MARK: - The page

    @ViewBuilder
    private func page(_ screen: HomeScreen) -> some View {
        ForEach(screen.sections) { section in sectionView(section) }
        if !screen.ticketsNotStarted.isEmpty { tickets(screen.ticketsNotStarted, title: "Tickets not started here") }
        if let line = screen.earlier.line { earlier(screen.earlier, line: line) }
    }

    private func sectionView(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { Task { await model.setProject(section.project) } } label: {
                    Text(section.project)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(coolWhite.opacity(0.92))
                }
                .buttonStyle(.plain)
                .disabled(section.current)
                .accessibilityIdentifier("landing.project.\(section.project)")
                if section.current {
                    Text("you are here").font(.system(size: 11)).foregroundStyle(violet.opacity(0.9))
                }
                Text(section.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(coolWhite.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open") {
                    Task { await model.openWorkspace(nil, project: section.project, environment: section.current ? model.environment : nil) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(coolWhite.opacity(0.75))
                .help("Open Main's view: your own folders, with panes and no agent")
                .accessibilityIdentifier("landing.project.\(section.project).open")
            }
            if section.current { openAPane }
            if let main = section.main { mainBlock(main) }
            ForEach(section.cards) { card in cardView(card, depth: 0) }
        }
    }

    // MARK: - Main

    private func mainBlock(_ main: HomeMain) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Main").font(.system(size: 14, weight: .semibold)).foregroundStyle(coolWhite.opacity(0.9))
                Text(HomeMain.words).font(.system(size: 11)).foregroundStyle(coolWhite.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 4)
            ForEach(main.lines) { conversationLine($0) }
        }
        .padding(.bottom, 8)
        .background(slab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("landing.main")
    }

    // MARK: - A card

    private func cardView(_ card: HomeCard, depth: Int) -> AnyView {
        let key = "card:\(card.id)"
        let disabled = busy == card.id
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if depth > 0 { Text("↳").foregroundStyle(coolWhite.opacity(0.45)) }
                    if let k = card.key {
                        Text(k).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(coolWhite.opacity(0.86))
                    }
                    Text(card.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(coolWhite.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.environment)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(card.isProduction ? red : coolWhite.opacity(0.5))
                    Spacer(minLength: 8)
                    if hovered == key || disabled {
                        Button("New conversation here") { Task { await model.newConversation(inWorkspace: card.id) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(violet)
                            .accessibilityIdentifier("landing.card.\(card.id).new")
                    }
                    menu(card).disabled(disabled)
                }
                if let from = card.branchedFrom, depth == 0 {
                    Text("branched off ‘\(from)’").font(.system(size: 11)).foregroundStyle(coolWhite.opacity(0.5))
                }
                WrappingRow(spacing: 10) {
                    Text(card.repoCount).font(.system(size: 11)).foregroundStyle(coolWhite.opacity(0.5))
                    ForEach(card.repos) { repo in
                        HStack(spacing: 5) {
                            Text(repo.name).font(.system(size: 11, weight: .medium)).foregroundStyle(coolWhite.opacity(0.8))
                            Text(repo.words).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(repo.inMain ? violet : coolWhite.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let prs = card.prs {
                    Text(prs).font(.system(size: 11)).foregroundStyle(coolWhite.opacity(0.6))
                        .accessibilityIdentifier("landing.card.\(card.id).prs")
                }
                if let needs = card.needs {
                    Text(needs).font(.system(size: 12)).foregroundStyle(amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("landing.card.\(card.id).needs")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .contentShape(Rectangle())
            .onTapGesture { Task { await model.openWorkspace(card.id) } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { Task { await model.openWorkspace(card.id) } }
            .accessibilityIdentifier("landing.card.\(card.id)")
            .accessibilityValue(card.needsYou ? "needs you" : "")
            VStack(alignment: .leading, spacing: 0) { ForEach(card.lines) { conversationLine($0) } }
            ForEach(card.children) { child in cardView(child, depth: depth + 1).padding(.leading, 18) }
        }
        .padding(.bottom, 10)
        .background(slab)
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) })
    }

    /// ⋯: Bring to Main…, Move a conversation here…, Archive (spec, piece 3).
    private func menu(_ card: HomeCard) -> some View {
        Menu {
            if !card.bringHome.isEmpty {
                Menu("Bring to Main…") {
                    ForEach(card.bringHome) { repo in
                        Button("\(repo.name) — switch your folder to \(repo.branch)") {
                            run(card.id) { await model.bringToMain(card.id, repo: repo.repo) }
                        }
                    }
                }
            }
            Menu("Move a conversation here…") {
                if card.moveCandidates.isEmpty {
                    Text("No conversation of \(card.project) is free to move")
                }
                ForEach(card.moveCandidates) { c in
                    Button(c.title) { run(card.id) { await model.moveConversation(c.id, toWorkspace: card.id) } }
                }
            }
            Divider()
            Button("Archive") {
                if card.archiveAsks { confirmingArchive = card } else {
                    run(card.id) { await model.archiveWorkspace(card.id, confirm: false) }
                }
            }
        } label: {
            Text("⋯").font(.system(size: 14, weight: .semibold)).foregroundStyle(coolWhite.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("landing.card.\(card.id).menu")
    }

    /// Runs a card action; the page re-reads after it, and its card is disabled meanwhile (Rule 5).
    private func run(_ id: String, _ body: @escaping () async -> Bool) {
        busy = id
        Task {
            _ = await body()
            busy = nil
            revision += 1
        }
    }

    // MARK: - A conversation line

    /// State dot, title, what it does and the repos it holds. The id keeps the Landing's
    /// `landing.row.running:<n>`, numbered in drawing order (`HomeConversationLine.index`).
    private func conversationLine(_ line: HomeConversationLine) -> some View {
        let id = "running:\(line.index)"
        let editing = renaming == line.id
        let action = { Task { await model.switchToRunning(line.id) } }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            ChipDot(colour: line.state.hue, breathes: line.state == .working)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            if editing {
                ConversationNameField(
                    conversation: line.id, shown: line.title, identifier: "landing.row.\(id).name",
                    size: 13.5, colour: coolWhite.opacity(0.92), model: model, done: { renaming = nil })
            } else {
                Text(line.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(coolWhite.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(line.detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(line.isProduction ? red : coolWhite.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(coolWhite.opacity(hovered == id ? 0.04 : 0))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture { if !editing { _ = action() } }
        .contextMenu { Button("Rename…") { renaming = line.id } }
        .accessibilityElement(children: editing ? .contain : .combine)
        .accessibilityAddTraits(editing ? [] : .isButton)
        .accessibilityAction(.default) { if !editing { _ = action() } }
        .accessibilityIdentifier("landing.row.\(id)")
        .accessibilityValue(line.state.spoken)
    }

    // MARK: - Tickets

    private func tickets(_ rows: [TicketNeedsRow], title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(coolWhite.opacity(0.85))
                .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let state = landingTicketState(row)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ticketNeedsRowName(row))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(0.86))
                    Text(row.title)
                        .font(.system(size: 13))
                        .foregroundStyle(coolWhite.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(state.words)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(state.needsYou ? amber : coolWhite.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Start") { Task { await model.openTicket(ticketOpenParams(row)) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(violet)
                        .accessibilityIdentifier("landing.tickets.\(index)")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            if rows.count > 0 {
                Button("All tickets in ⌘P  #", action: openTicketsPalette)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(coolWhite.opacity(0.55))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("landing.tickets.all")
            }
            ForEach(ticketPartialLine(model.ticketNeeds?.partial ?? []), id: \.self) { line in
                Text(line).font(.system(size: 11)).foregroundStyle(coolWhite.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .accessibilityIdentifier("landing.tickets.partial")
            }
        }
        .padding(.bottom, 6)
        .background(slab)
    }

    // MARK: - Earlier

    private func earlier(_ earlier: HomeEarlier, line: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { earlierOpen.toggle() } label: {
                Text("\(earlierOpen ? "▾" : "▸") \(line)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(coolWhite.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("landing.earlier")
            if earlierOpen {
                ForEach(Array(earlier.archived.enumerated()), id: \.element.id) { index, w in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(w.tickets.first.map { "\($0) \(w.name)" } ?? w.name)
                            .font(.system(size: 13)).foregroundStyle(coolWhite.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("archived · \(w.project) · \(w.environment)")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(coolWhite.opacity(0.45))
                        Spacer(minLength: 8)
                        Button("Restore") { run(w.id) { await model.restoreWorkspace(w.id) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(violet)
                            .disabled(busy == w.id)
                            .accessibilityIdentifier("landing.earlier.archived.\(index).restore")
                    }
                    .padding(.leading, 14)
                }
                ForEach(earlier.past) { group in
                    Text(group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(coolWhite.opacity(0.55))
                        .padding(.leading, 14).padding(.top, 6)
                    ForEach(group.conversations) { c in
                        Button { Task { await model.continueSession(c.id) } } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(c.title).font(.system(size: 13)).foregroundStyle(coolWhite.opacity(0.8))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(c.subtitle).font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(coolWhite.opacity(0.45))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 24)
                        .accessibilityIdentifier("landing.row.\(c.id)")
                    }
                }
            }
        }
    }

    // MARK: - First run

    /// The current project's header stays (piece 3's amendment: its Open and *Open a pane* stand on
    /// every day, not only once something runs); the note below it says nothing runs yet.
    @ViewBuilder
    private func firstRun(_ screen: HomeScreen) -> some View {
        ForEach(screen.sections) { section in sectionView(section) }
        Text("Nothing running. Type below to start a conversation in Main, your own folders. It reads them as they are; "
             + "the moment it changes something, it gets a workspace of its own and your folders stay untouched.")
            .font(.system(size: 12.5))
            .foregroundStyle(coolWhite.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
        if !screen.ticketsNotStarted.isEmpty { tickets(screen.ticketsNotStarted, title: "Tickets in flight") }
        if screen.sections.isEmpty { openAPane }
        if let line = screen.earlier.line { earlier(screen.earlier, line: line) }
    }

    /// *Open a pane: Database · Terminal · Browser* — each opens Main's view with that pane
    /// (decision 26). Drawn on first run and under the current project's header.
    private var openAPane: some View {
        HStack(spacing: 6) {
            Text("Open a pane:").font(.system(size: 12)).foregroundStyle(coolWhite.opacity(0.5))
            ForEach(Array(["db", "terminal", "browser"].filter(Pane.kinds.contains).enumerated()), id: \.element) { i, kind in
                if i > 0 { Text("·").foregroundStyle(coolWhite.opacity(0.35)) }
                Button(paneKindTitle(kind: kind)) { Task { await model.openMainView(withPane: kind) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(coolWhite.opacity(0.8))
                    .accessibilityIdentifier("landing.row.open:\(kind)")
            }
        }
    }

    // MARK: - No project

    @ViewBuilder
    private var projectRows: some View {
        Text("Projects").font(.system(size: 13, weight: .semibold)).foregroundStyle(coolWhite.opacity(0.85))
            .padding(.top, 8)
        if projects.isEmpty {
            note("No projects in \(model.organization.isEmpty ? "this organisation" : model.organization) yet")
        }
        ForEach(projects) { project in
            Button { Task { await model.setProject(project.name) } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.system(size: 15)).foregroundStyle(coolWhite.opacity(0.92))
                    Text(project.provider ?? project.path ?? "").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("landing.row.project:\(project.name)")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(coolWhite.opacity(0.46))
    }

    /// §2: a slab — near-opaque, rounded, a drop shadow and a half-pixel luminous edge.
    private var slab: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(red: 0.055, green: 0.063, blue: 0.098))
            .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// Lays its children out left to right, wrapping onto more lines rather than cutting any
/// (decision 20: every repo and branch, no "+N more").
struct WrappingRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
