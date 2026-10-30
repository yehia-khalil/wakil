import WakilKit
import SwiftUI

/// The home screen (workspaces, piece 3; the comp of 2026-10-30): the organisation's, needs first.
/// NEEDS YOU, the pills, one slab per project with something going on (Main, then compact cards that
/// expand in place), the quiet projects on one line, Tickets not started, Earlier. Everything it
/// shows is decided in WakilKit (`homeScreen`, `HomeNeeds.swift`, `HomePalette`,
/// `HomeExpansionStore`); this file only draws it and dispatches through `WindowModel`
/// (Invariant 2): a line through `openHomeLine` (`session_switch`, else `session_resume`), a card, a
/// project's name and a NEEDS YOU row through `workspace_open`, a PR link through `browser_open`.
///
/// **One scroll for the page, nothing capped** (decision 20): no column has a height, no text a
/// line limit; a long title, branch or why wraps whole.
struct Home: View {
    let model: WindowModel

    @State private var screen: HomeScreen?
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
    /// A card's ▶ Run or Stop that failed, whole (Rule 8), until its next Run or Stop.
    @State private var runErrors: [String: String] = [:]
    /// Which cards are expanded, kept across relaunch (Rule 6); `expansionTick` redraws after a toggle.
    @State private var expansion = HomeExpansionStore()
    @State private var expansionTick = 0
    /// Piece 5: the proposal whose Start opened its brief in a popover, and where (`need:` or `line:`).
    @State private var startingProposal: String?

    private let ink = Color(HomePalette.ink)
    private let action = Color(HomePalette.action)
    private let amber = Color(HomePalette.amber)
    private let green = Color(HomePalette.green)
    private let red = Color(HomePalette.red)
    private let link = Color(HomePalette.link)

    /// What the page depends on: the place, every live conversation's state and title, the tickets read.
    private var readKey: String {
        let live = model.liveConversationRows().map { "\($0.id):\($0.state.rawValue):\($0.title):\($0.workspace?.id ?? "")" }
        // Decision 11's offer: a workspace branch's PRs landing redraws the page.
        let merged = model.homeBranchPRs.map { "\($0.key.root):\($0.key.branch)=\($0.value.map(\.state))" }.sorted()
        return "\(model.organization)/\(model.projectKey)/\(model.environment)|\(live.joined(separator: ","))|"
            + "\(model.ticketNeedsRows.count)|\(filter ?? "")|\(revision)|\(merged.joined(separator: ","))|"
            + model.homeRunLines.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") + "|"
            + model.homeRunPorts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") + "|"
            + model.homeRunTones.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") + "|"
            + model.homeRecipeRepos.map { "\($0.key)=\($0.value.sorted())" }.sorted().joined(separator: ",") + "|"
            + model.teammateProposals.all.map { "\($0.id):\($0.brief.count)" }.joined(separator: ",")
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                if let screen {
                    if screen.firstRun { firstRun(screen) } else { page(screen) }
                } else {
                    Text("Reading workspaces…").font(.system(size: 12.5)).foregroundStyle(ink.opacity(HomePalette.quiet))
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // On the scroll area, not the page's stack: a `.contain` group whose only child is another
        // (the quiet line alone, on a home with nothing else) folds that child into itself, so
        // landing.quiet never reached the tree; the scroll area folds nothing.
        .accessibilityIdentifier("landing")
        // The page scrolls under the composer, fading over its last 28 pt.
        .mask(VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: readKey) {
            let projects = await model.listProjects()
            past = await model.landingSessions()
            screen = await model.readHomeScreen(
                projects: projects.map(\.name), past: past, filter: filter,
                projectPaths: Dictionary(projects.compactMap { p in p.path.map { (p.name, $0) } }, uniquingKeysWith: { a, _ in a }))
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

    // MARK: - The page

    @ViewBuilder
    private func page(_ screen: HomeScreen) -> some View {
        if !screen.needs.isEmpty { needsSection(screen.needs) }
        if !screen.pills.isEmpty { pills(screen.pills) }
        ForEach(screen.sections) { section in sectionView(section) }
        if !screen.quiet.isEmpty { quietLine(screen) }
        tickets(screen.ticketsNotStarted)
        if let line = screen.earlier.line { earlier(screen.earlier, line: line) }
    }

    // MARK: - NEEDS YOU

    private func needsSection(_ needs: [HomeNeed]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Needs you", count: "\(needs.count)")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(needs.enumerated()), id: \.element.id) { n, need in
                    if n > 0 { hairline }
                    needRow(need, n: n)
                }
            }
            .padding(.vertical, 4)
            .background(slab)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("landing.needs")
    }

    /// One sentence — dot, project (mono), the workspace or conversation, the why in its hue — and one
    /// action at the right. The row itself opens what it is about.
    private func needRow(_ need: HomeNeed, n: Int) -> some View {
        let key = "need:\(need.id)"
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                StateDot(state: need.hue)
                Text(need.project)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(ink.opacity(HomePalette.quiet))
                    .fixedSize()
                (keyText(need.key) + Text(need.title).foregroundColor(ink.opacity(HomePalette.title))
                    + Text(" — ").foregroundColor(ink.opacity(HomePalette.micro))
                    + Text(need.why).foregroundColor(hue(need.hue)))
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { open(need.opens) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { open(need.opens) }
            .accessibilityIdentifier("landing.needs:\(n)")
            needAction(need, n: n)
        }
        .padding(.vertical, 8)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .background(RoundedRectangle(cornerRadius: 7).fill(ink.opacity(hovered == key ? 0.04 : 0)))
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
    }

    @ViewBuilder
    private func needAction(_ need: HomeNeed, n: Int) -> some View {
        if case .teammate(let id) = need.action, let p = screen?.proposal(id) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                proposalStart(p, key: "need:\(p.id)", base: "landing.needs:\(n)")
                    .accessibilityIdentifier("landing.needs:\(n).act")
                proposalDismiss(p).accessibilityIdentifier("landing.needs:\(n).dismiss")
            }
            .fixedSize()
        } else {
            plainNeedAction(need, n: n)
        }
    }

    private func plainNeedAction(_ need: HomeNeed, n: Int) -> some View {
        Button(need.action.label) {
            switch need.action {
            case .review(let c, let s), .open(let c, let s): Task { await model.openHomeLine(c, session: s) }
            case .openWorkspace(let w): Task { await model.openWorkspace(w) }
            case .link(let url): Task { await model.openLinkInWakil(url) }
            case .teammate: break
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isLink(need.action) ? link : action)
        .fixedSize()
        .accessibilityIdentifier("landing.needs:\(n).act")
    }

    private func isLink(_ a: HomeNeedAction) -> Bool { if case .link = a { return true }; return false }

    private func open(_ target: HomeNeedOpen) {
        switch target {
        case .conversation(let c, let s): Task { await model.openHomeLine(c, session: s) }
        case .workspace(let w): Task { await model.openWorkspace(w) }
        }
    }

    // MARK: - Pills (filter only; never select a place)

    private func pills(_ pills: [HomePill]) -> some View {
        WrappingRow(spacing: 8) {
            ForEach(pills) { pill in
                let key = pill.project ?? "all"
                Button { filter = pill.project } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(pill.label).font(.system(size: 12))
                        if pill.project != nil, pill.needsYou > 0 {
                            Text("● \(pill.needsYou)").font(.system(size: 11, design: .monospaced)).foregroundStyle(amber)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(ink.opacity(pill.selected ? HomePalette.pillOn.ground : HomePalette.pillOff)))
                    .foregroundStyle(ink.opacity(pill.selected ? HomePalette.pillOn.text : HomePalette.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("landing.pill.\(key)")
                .accessibilityValue(pill.selected ? "selected" : "")
            }
        }
    }

    // MARK: - A project

    /// One slab per project: Main first, then its workspaces, divided by hairlines. The name is the
    /// door to Main's view; no separate Open.
    private func sectionView(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                projectName(section.project, size: 15)
                micro(section.summary)
                rule
            }
            VStack(alignment: .leading, spacing: 0) {
                if let main = section.main {
                    VStack(alignment: .leading, spacing: 0) {
                        micro("Main").padding(.horizontal, 18).padding(.top, 11).padding(.bottom, 2)
                        ForEach(main.lines) { conversationLine($0, inset: 18) }
                        ForEach(main.proposals) { proposalLine($0).padding(.horizontal, 18).padding(.vertical, 7) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("landing.main")
                    if !section.cards.isEmpty { hairline.padding(.vertical, 4) }
                }
                ForEach(Array(section.cards.enumerated()), id: \.element.id) { n, card in
                    if n > 0 && !expanded(section.cards[n - 1]) && !expanded(card) { hairline }
                    cardBlock(card, depth: 0)
                }
            }
            .padding(.top, section.main == nil ? 4 : 0)
            .padding(.bottom, 4)
            .background(slab)
        }
    }

    /// A project's name: Main's view of it (`workspace_open`, Main), underlined under the pointer.
    private func projectName(_ project: String, size: CGFloat, mono: Bool = false) -> some View {
        let key = "project:\(project)"
        let open = { Task { await model.openWorkspace(nil, project: project, environment: project == model.projectKey ? model.environment : nil) } }
        // A pressable element holding its Text, not a Button: a Button's label is not in the tree the
        // checks read, and the name is what they read the home by.
        return Text(project)
            .font(.system(size: size, weight: mono ? .regular : .semibold, design: mono ? .monospaced : .default))
            .foregroundStyle(ink.opacity(mono ? HomePalette.secondary : HomePalette.title))
            .underline(hovered == key, color: ink.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { _ = open() }
            .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
            .help("Open Main's view of \(project): your own folders, with panes")
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { _ = open() }
            .accessibilityIdentifier("landing.project.\(project)")
    }

    // MARK: - A card

    /// The card's number on the home, in drawing order (`HomeScreen.cardOrder`): what its Run, Stop
    /// and run error are addressed by, as its own id is generated.
    /// Each card's number by its id, for the `landing.card:<n>.…` identifiers: an interpolation
    /// with no parenthesis inside, so the e2e harvester reads the family (`landing.card:<…>.run`)
    /// as the checks press it; a call inside the interpolation harvested as `landing.card:<…>).run`.
    private var cardNumbers: [String: Int] {
        Dictionary((screen?.cardOrder ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func expanded(_ card: HomeCard) -> Bool {
        _ = expansionTick
        return expansion.isExpanded(card.id)
    }

    private func toggle(_ card: HomeCard) {
        expansion.toggle(card.id)
        expansionTick += 1
    }

    /// A compact row, its body when expanded (lifted 0.035 with a hairline, not a new slab), and its
    /// children: each its own row under it while closed, ↳ lines inside the body while open.
    private func cardBlock(_ card: HomeCard, depth: Int) -> AnyView {
        let open = expanded(card)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                compactRow(card, depth: depth, open: open)
                if let merged = card.merged {
                    mergedOffer(card, merged, offer: screen?.mergedOffers.firstIndex(of: card.id) ?? 0)
                }
                if let error = runErrors[card.id] {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.leading, 37 + CGFloat(depth) * 20).padding(.trailing, 16).padding(.bottom, 6)
                        .accessibilityIdentifier("landing.card:\(cardNumbers[card.id] ?? 0).runError")
                }
                if open { cardBody(card) }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(ink.opacity(open ? 0.035 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ink.opacity(open ? 0.08 : 0), lineWidth: 0.5))
            if !open {
                ForEach(card.children) { child in
                    hairline
                    cardBlock(child, depth: depth + 1)
                }
            }
        })
    }

    /// One line: dot · key and title · the environment tag when it differs · at the right `● n`,
    /// `:41200 ■`, ▶ and ⌄. Only the right-hand cluster keeps to one line: its tokens are short.
    private func compactRow(_ card: HomeCard, depth: Int, open: Bool) -> some View {
        let key = "card:\(card.id)"
        let disabled = busy == card.id
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if depth > 0 {
                    Text("↳").font(.system(size: 13)).foregroundStyle(ink.opacity(HomePalette.micro))
                        .accessibilityHidden(true)
                }
                StateDot(state: card.hue, spoken: card.needsYou ? "\(card.needCount) need you" : card.hue.spoken)
                cardTitle(card, showsBranch: depth > 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { Task { await model.openWorkspace(card.id) } }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { Task { await model.openWorkspace(card.id) } }
            .accessibilityIdentifier("landing.card.\(card.id)")
            HStack(alignment: .center, spacing: 12) {
                if card.needCount > 0 {
                    Text("● \(card.needCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(amber)
                        .help("\(card.needCount) need you")
                        .accessibilityLabel("\(card.needCount) need you")
                        .accessibilityIdentifier("landing.card.\(card.id).needs")
                }
                if let ports = card.runningCompact {
                    HStack(spacing: 7) {
                        if card.appLinks.isEmpty {
                            Text(ports)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(runColour(card))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(card.running ?? ports)
                                .accessibilityIdentifier("landing.card.\(card.id).running")
                        } else {
                            // Ready: each port is its app's link, `:41210 ↗` (design-language §5).
                            ForEach(Array(card.appLinks.enumerated()), id: \.offset) { i, app in
                                appLink(app, size: 11)
                                    .accessibilityIdentifier("landing.card:\(cardNumbers[card.id] ?? 0).app:\(i)")
                            }
                        }
                        Button { runOnCard(card) { await model.stopOnCard(card.id) } } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(ink.opacity(HomePalette.secondary))
                                .frame(width: 18, height: 18)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ink.opacity(0.14), lineWidth: 0.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .help("Stop what runs in it: \(card.running ?? "")")
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("landing.card:\(cardNumbers[card.id] ?? 0).stop")
                    }
                }
                if card.offersRun { runControl(card, disabled: disabled) }
                if card.offersSetUpRunning { setUpRunningControl(card) }
                Button { toggle(card) } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ink.opacity(HomePalette.quiet))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Collapse" : "Expand: repos, PRs, every conversation")
                .accessibilityLabel(open ? "Collapse" : "Expand")
                .accessibilityIdentifier("landing.card:\(cardNumbers[card.id] ?? 0).expand")
            }
            .fixedSize()
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .padding(.vertical, 7)
        .padding(.leading, 18 + CGFloat(depth) * 20)
        .padding(.trailing, 12)
        .background(RoundedRectangle(cornerRadius: 7).fill(ink.opacity(hovered == key && !open ? 0.04 : 0)))
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
    }

    /// A ready app's `:41210 ↗` in the void's blue: Wakil's browser pane (`browser_open`), ⌥-click
    /// the system browser, as every ↗ link (`WakilLinks`). Its root, never the ready check's path.
    private func appLink(_ app: HomeAppLink, size: CGFloat) -> some View {
        Button(WebLink.label(app.label)) { WakilLinks.open(app.url, systemBrowser: NSEvent.modifierFlags.contains(.option), model: model) }
            .buttonStyle(.plain)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(WebLink.colour)
            .fixedSize(horizontal: false, vertical: true)
            .help("Open \(app.url) in Wakil's browser; ⌥-click for the system browser")
            .accessibilityLabel("Open \(app.url)")
    }

    /// `INI-140 Move webhook signing to the vault staging`, wrapping whole; a child row adds
    /// `· branched off INI-140`.
    private func cardTitle(_ card: HomeCard, showsBranch: Bool) -> some View {
        var text = keyText(card.key) + Text(card.name).foregroundColor(ink.opacity(HomePalette.title))
        if let tag = card.environmentTag {
            text = text + Text("  \(tag)").font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(card.isProduction ? red : ink.opacity(HomePalette.quiet))
        }
        if showsBranch, let from = card.branchedOff {
            text = text + Text("  · branched off \(from)").font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(ink.opacity(HomePalette.quiet))
        }
        return text.font(.system(size: 13.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }

    /// ▶ on the compact row: the one copy's saved recipe, or a menu of the copies (decision 12).
    @ViewBuilder
    private func runControl(_ card: HomeCard, disabled: Bool) -> some View {
        let glyph = Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(action)
            .frame(width: 22, height: 22).contentShape(Rectangle())
        if card.runnable.count == 1, let repo = card.runnable.first {
            Button { runOnCard(card) { await model.runOnCard(card.id, repo: repo.repo) } } label: { glyph }
                .buttonStyle(.plain)
                .disabled(disabled)
                .help("Run \(repo.name)'s saved recipe in this workspace's copy")
                .accessibilityLabel("Run \(repo.name)")
                .accessibilityIdentifier("landing.card:\(cardNumbers[card.id] ?? 0).run")
        } else {
            Menu {
                ForEach(card.runnable) { repo in
                    Button(repo.name) { runOnCard(card) { await model.runOnCard(card.id, repo: repo.repo) } }
                }
            } label: { glyph }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(disabled)
                .help("Run a repo's saved recipe in this workspace's copy")
                .accessibilityLabel("Run")
                .accessibilityIdentifier("landing.card:\(cardNumbers[card.id] ?? 0).run")
        }
    }

    /// Where ▶ would be when no copy's repo has a recipe: Settings → the project → Running, where
    /// one is drafted or chosen. A navigation the operator asked for by pressing it (Rule 6 is about
    /// what an action does after; this one's action is going there), never a refusal after the fact.
    private func setUpRunningControl(_ card: HomeCard) -> some View {
        Button { Task { await model.openRunningSettings(project: card.project) } } label: {
            Text("Set up running…")
                .font(.system(size: 11.5))
                .foregroundStyle(action)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("No repo of \(card.name) has a recipe yet: open \(card.project)'s Running settings to draft or choose one")
        .accessibilityIdentifier("landing.card:\(cardNumbers[card.id] ?? 0).setUpRunning")
    }

    /// The expanded card, in the brief's order: repos and their whole branches · PRs, checks ↗ and
    /// what runs · each conversation · the child ↳ · the footer.
    private func cardBody(_ card: HomeCard) -> some View {
        let disabled = busy == card.id
        return VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(card.repos) { repo in
                    GridRow {
                        Text(repo.name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.opacity(HomePalette.secondary))
                            .fixedSize()
                        Text(repo.words).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(repo.inMain ? action : ink.opacity(HomePalette.quiet))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if card.prs != nil || card.running != nil {
                WrappingRow(spacing: 8) {
                    if let prs = card.prs {
                        Text(prs).font(.system(size: 12)).foregroundStyle(ink.opacity(HomePalette.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("landing.card.\(card.id).prs")
                        if let url = card.prURL {
                            dotSeparator
                            Button("checks ↗") { Task { await model.openLinkInWakil(homeChecksURL(url)) } }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(link)
                                .accessibilityIdentifier("landing.card.\(card.id).checks")
                        }
                    }
                    if let running = card.running {
                        if card.prs != nil { dotSeparator }
                        Text(running).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(runColour(card))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(card.appLinks.enumerated()), id: \.offset) { i, app in
                            appLink(app, size: 11.5)
                                .accessibilityIdentifier("landing.card:\(cardNumbers[card.id] ?? 0).bodyApp:\(i)")
                        }
                    }
                }
            }
            if !card.lines.isEmpty || (!card.children.isEmpty) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(card.lines) { conversationLine($0, inset: 19) }
                    ForEach(card.children) { childLine($0) }
                }
                .padding(.leading, -19)
                .padding(.trailing, -16)
            }
            ForEach(card.proposals) { proposalLine($0) }
            HStack(alignment: .center, spacing: 18) {
                Button { Task { await model.newConversation(inWorkspace: card.id) } } label: {
                    Label("New conversation here", systemImage: "plus")
                        .labelStyle(FootLabelStyle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(action)
                .disabled(disabled)
                .accessibilityIdentifier("landing.card.\(card.id).new")
                runMenu(card).disabled(disabled)
                Spacer(minLength: 8)
                menu(card).disabled(disabled)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { hairline }
        }
        .padding(.leading, 37)
        .padding(.trailing, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    /// A child inside its expanded parent: `↳ ● INI-140 Try HMAC — branched off INI-140 · working`,
    /// opening the child's workspace.
    private func childLine(_ child: HomeCard) -> some View {
        let state = child.hue == .idle ? "idle" : homeStateWords(child.hue)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("↳").font(.system(size: 13)).foregroundStyle(ink.opacity(HomePalette.micro)).accessibilityHidden(true)
            StateDot(state: child.hue)
            (keyText(child.key) + Text(child.name).foregroundColor(ink.opacity(HomePalette.title))
                + Text("  — branched off \(child.branchedOff ?? "") · \(state)")
                .font(.system(size: 10.5, design: .monospaced)).foregroundColor(ink.opacity(HomePalette.quiet)))
                .font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.leading, 19)
        .padding(.trailing, 16)
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.openWorkspace(child.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { Task { await model.openWorkspace(child.id) } }
        .accessibilityIdentifier("landing.card.\(child.id)")
    }

    /// ▶ Run… in the footer: each repo with a copy runs its saved recipe (`workspace_run`, decision 12).
    /// With no copy yet it says why rather than offering nothing.
    private func runMenu(_ card: HomeCard) -> some View {
        Menu {
            if card.runnable.isEmpty {
                Text("No copy to run yet: the app runs in a workspace's copy, made at its first change")
            }
            ForEach(card.runnable) { repo in
                Button(repo.name) { runOnCard(card) { await model.runOnCard(card.id, repo: repo.repo) } }
            }
        } label: {
            Label("Run…", systemImage: "play.fill").labelStyle(FootLabelStyle()).foregroundStyle(action)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("landing.card.\(card.id).runMenu")
    }

    /// Runs a card's Run or Stop: the card is disabled meanwhile (Rule 5), and a refusal or failure
    /// is drawn on the card whole (Rule 8).
    private func runOnCard(_ card: HomeCard, _ body: @escaping () async -> String?) {
        runErrors[card.id] = nil
        run(card.id) {
            let error = await body()
            if let error { runErrors[card.id] = error }
            return error == nil
        }
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
            Button("Archive") { archive(card) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(ink.opacity(HomePalette.quiet))
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More: Bring to Main…, Move a conversation here…, Archive")
        .accessibilityLabel("More")
        .accessibilityIdentifier("landing.card.\(card.id).menu")
    }

    /// Decision 11's offer, under the compact row whether or not the card is open: every PR merged,
    /// and **Archive** — asking only with a conversation waiting (Rule 1), disabled while a card
    /// action runs (Rule 5).
    private func mergedOffer(_ card: HomeCard, _ merged: String, offer: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(merged) — this work is done")
                .font(.system(size: 12))
                .foregroundStyle(green)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("landing.card.\(card.id).merged")
            Button("Archive") { archive(card) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(action)
                .disabled(busy == card.id)
                // Numbered in drawing order (`HomeScreen.mergedOffers`): a card's own id is generated.
                .accessibilityIdentifier("landing.archive.offer:\(offer)")
        }
        .padding(.leading, 37)
        .padding(.trailing, 16)
        .padding(.bottom, 7)
    }

    /// Archive, from ⋯ or the merged offer: asks only with a conversation waiting (Rule 1).
    private func archive(_ card: HomeCard) {
        if card.archiveAsks { confirmingArchive = card } else {
            run(card.id) { await model.archiveWorkspace(card.id, confirm: false) }
        }
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

    // MARK: - A teammate proposal (piece 5)

    /// `● Suggests a teammate for web — <brief>`, whole, with **Start** — the brief in a popover,
    /// editable, its field focused (Rule 3) — and **Dismiss**, which asks nothing (Rule 1: it destroys
    /// nothing; it is not proposed again for that repo there). Numbered in drawing order
    /// (`HomeScreen.teammateOffers`), as a card's own id is generated.
    private func proposalLine(_ p: TeammateProposal) -> some View {
        let n = screen?.teammateOffers.firstIndex(of: p.id) ?? 0
        let words = homeProposalWords(p)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            StateDot(state: .waiting)
            (Text(words.lead).fontWeight(.medium).foregroundColor(amber)
                + Text(words.rest).foregroundColor(ink.opacity(HomePalette.strong)))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("landing.teammate:\(n)")
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                proposalStart(p, key: "line:\(p.id)", base: "landing.teammate:\(n)")
                    .accessibilityIdentifier("landing.teammate:\(n).start")
                proposalDismiss(p).accessibilityIdentifier("landing.teammate:\(n).dismiss")
            }
            .fixedSize()
        }
    }

    /// Start: the proposal's brief in a popover (piece 5's own row), its field focused.
    private func proposalStart(_ p: TeammateProposal, key: String, base: String) -> some View {
        Button("Start") { startingProposal = key }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(action)
            .popover(isPresented: Binding(get: { startingProposal == key },
                                          set: { if !$0, startingProposal == key { startingProposal = nil } })) {
                TeammateProposalRow(
                    proposal: p,
                    dispatch: { name, params in await model.dispatchFromSurfaceReply(name, params) },
                    focusOnAppear: true, identifierBase: base,
                    done: { startingProposal = nil; revision += 1 })
                    .padding(12)
                    .frame(width: 420)
            }
    }

    private func proposalDismiss(_ p: TeammateProposal) -> some View {
        Button("Dismiss") {
            Task {
                _ = await model.dispatchFromSurfaceReply("conversation_teammate_dismiss", .object(["proposal": .string(p.id)]))
                revision += 1
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink.opacity(HomePalette.quiet))
    }

    // MARK: - A conversation line

    /// State dot, title, its state in words. The id keeps the Landing's `landing.row.running:<n>`,
    /// numbered in drawing order (`HomeConversationLine.index`).
    private func conversationLine(_ line: HomeConversationLine, inset: CGFloat) -> some View {
        let id = "running:\(line.index)"
        let editing = renaming == line.id
        // Every line opens its conversation, a Main line's and a card's alike (piece 3 walk).
        let action = { Task { await model.openHomeLine(line.id, session: line.session) } }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            StateDot(state: line.state, spoken: line.state.spoken)
            if editing {
                ConversationNameField(
                    conversation: line.id, shown: line.title, identifier: "landing.row.\(id).name",
                    size: 13.5, colour: ink.opacity(HomePalette.title), model: model, done: { renaming = nil })
            } else {
                Text(line.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(ink.opacity(HomePalette.title))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(line.words)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(line.isProduction ? red : stateWordColour(line.state))
                .fixedSize()
        }
        .padding(.leading, inset)
        .padding(.trailing, 16)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(ink.opacity(hovered == id ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture { if !editing { _ = action() } }
        .contextMenu { Button("Rename…") { renaming = line.id } }
        .accessibilityElement(children: .contain)
        // Named as its title: a `.contain` row's own label is empty, so VoiceOver announced a button
        // with no name, and a check reading the row by label read "" (the Landing's rows were
        // `.combine`, whose label is the title). Its Text stays a child, for the tree's text.
        .accessibilityLabel(editing ? "" : line.title)
        .accessibilityAddTraits(editing ? [] : .isButton)
        .accessibilityAction(.default) { if !editing { _ = action() } }
        .accessibilityIdentifier("landing.row.\(id)")
    }

    /// The run line's colour by its state (`RunTone`, design-language §5): failed reads red.
    private func runColour(_ card: HomeCard) -> Color { Color(card.runTone?.colour ?? HomePalette.green) }

    private func stateWordColour(_ state: ConversationState) -> Color {
        switch state {
        case .waiting: amber
        case .done: green
        case .failed: red
        case .working, .idle: ink.opacity(HomePalette.quiet)
        }
    }

    // MARK: - Quiet projects, Tickets, Earlier

    /// `2 quiet projects — web · portal`: each name is the door to its Main view.
    private func quietLine(_ screen: HomeScreen) -> some View {
        WrappingRow(spacing: 6) {
            Text("\(screen.quietCount) —").font(.system(size: 12.5)).foregroundStyle(ink.opacity(HomePalette.quiet))
            ForEach(Array(screen.quiet.enumerated()), id: \.element) { n, project in
                if n > 0 { dotSeparator }
                projectName(project, size: 11.5, mono: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("landing.quiet")
    }

    @ViewBuilder
    private func tickets(_ rows: [TicketNeedsRow]) -> some View {
        let partial = ticketPartialLine(model.ticketNeeds?.partial ?? [])
        if !rows.isEmpty || !partial.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Tickets · in flight, not started here", count: nil)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { n, row in
                        if n > 0 { hairline }
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(ticketNeedsRowName(row))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ink.opacity(HomePalette.strong))
                                .fixedSize()
                            Text(row.title)
                                .font(.system(size: 13))
                                .foregroundStyle(ink.opacity(HomePalette.strong))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(homeTicketStatus(row))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(row.urgent.needsYou ? amber : ink.opacity(HomePalette.quiet))
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Start") { Task { await model.openTicket(ticketOpenParams(row)) } }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(action)
                                .fixedSize()
                                .accessibilityIdentifier("landing.tickets.\(n)")
                        }
                        .padding(.vertical, 9)
                        .padding(.leading, 18)
                        .padding(.trailing, 16)
                    }
                    ForEach(partial, id: \.self) { line in
                        Text(line).font(.system(size: 11.5)).foregroundStyle(ink.opacity(HomePalette.quiet))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 18).padding(.vertical, 6)
                            .accessibilityIdentifier("landing.tickets.partial")
                    }
                }
                .padding(.vertical, 4)
                .background(slab)
            }
        }
    }

    private func earlier(_ earlier: HomeEarlier, line: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: earlierOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.opacity(HomePalette.micro))
                    .accessibilityHidden(true)
                micro(line)
            }
            .contentShape(Rectangle())
            .onTapGesture { earlierOpen.toggle() }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { earlierOpen.toggle() }
            .accessibilityIdentifier("landing.earlier")
            if earlierOpen {
                ForEach(Array(earlier.archived.enumerated()), id: \.element.id) { index, w in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        (keyText(w.tickets.first) + Text(w.name).foregroundColor(ink.opacity(HomePalette.strong)))
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("archived · \(w.project) · \(w.environment)")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(ink.opacity(HomePalette.quiet))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Restore") { run(w.id) { await model.restoreWorkspace(w.id) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(action)
                            .disabled(busy == w.id)
                            .accessibilityIdentifier("landing.earlier.archived.\(index).restore")
                    }
                    .padding(.leading, 17)
                }
                ForEach(earlier.past) { group in
                    micro(group.name).padding(.leading, 17).padding(.top, 6)
                    ForEach(group.conversations) { c in
                        // A pressable element holding its texts, not a Button: a Button's label is not
                        // in the tree the checks read (projectName's case), and the title is what they
                        // find a past conversation by.
                        let resume = { Task { await model.continueSession(c.id) } }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(c.title).font(.system(size: 13)).foregroundStyle(ink.opacity(HomePalette.strong))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(c.subtitle).font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(ink.opacity(HomePalette.quiet))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { _ = resume() }
                        .padding(.leading, 27)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(c.title)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(.default) { _ = resume() }
                        .accessibilityIdentifier("landing.row.\(c.id)")
                    }
                }
            }
        }
    }

    // MARK: - First run

    /// No project yet: the explainer — shown here and never on a working home — and *Add a project*
    /// (Settings' own, `settings_open`). A sentence in the composer still works.
    @ViewBuilder
    private func firstRun(_ screen: HomeScreen) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(HomeScreen.explainer, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.system(size: 14.5))
                        .lineSpacing(5)
                        .foregroundStyle(ink.opacity(HomePalette.strong))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("landing.explainer")
            Button { Task { await model.openSettings() } } label: {
                Text("Add a project")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.043, green: 0.047, blue: 0.078))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(action))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("landing.addProject")
            (Text("Or say it below: ").foregroundColor(ink.opacity(HomePalette.quiet))
                + Text("add the project at ~/code/api").font(.system(size: 12, design: .monospaced))
                .foregroundColor(ink.opacity(HomePalette.strong)))
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.top, 38)
        if let line = screen.earlier.line { earlier(screen.earlier, line: line) }
    }

    // MARK: - Pieces

    /// A ticket key, mono and bold before a title; empty with none.
    private func keyText(_ key: String?) -> Text {
        guard let key else { return Text("") }
        return Text(key + "  ").font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(ink.opacity(HomePalette.strong))
    }

    private func hue(_ state: ConversationState) -> Color {
        switch state {
        case .waiting: amber
        case .failed: red
        case .done: green
        case .working: Color(VoidPalette.violet)
        case .idle: ink.opacity(HomePalette.quiet)
        }
    }

    /// Uppercase, wide tracking, the floor's opacity: section names and counts.
    private func micro(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.7)
            .foregroundStyle(ink.opacity(HomePalette.micro))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHeader(_ title: String, count: String?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            micro(title)
            if let count {
                Text(count).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.6)
                    .foregroundStyle(ink.opacity(HomePalette.micro))
            }
            rule
        }
    }

    private var rule: some View {
        Rectangle().fill(ink.opacity(0.08)).frame(height: 0.5).frame(minWidth: 24)
    }

    private var hairline: some View {
        Rectangle().fill(ink.opacity(0.08)).frame(height: 0.5).frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private var dotSeparator: some View {
        Text("·").font(.system(size: 12)).foregroundStyle(ink.opacity(HomePalette.micro)).accessibilityHidden(true)
    }

    /// §2: a slab — near-opaque, rounded, a drop shadow and a half-pixel luminous edge.
    private var slab: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(HomePalette.slab))
            .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// A state's dot: hue only, no glow (§1). Working breathes, and holds still under Reduce Motion
/// (`ChipDot`); idle is a ring.
private struct StateDot: View {
    let state: ConversationState
    /// The row's state in words, when the dot speaks for its row: an element of its own, so the row
    /// keeps its texts as children (a value on the row itself hides them from the tree the checks
    /// read). Nil for a dot that only colours.
    var spoken: String? = nil
    var body: some View {
        let dot = Group {
            if state == .idle {
                Circle().strokeBorder(Color(HomePalette.ink).opacity(0.5), lineWidth: 1.2).frame(width: 7, height: 7)
            } else {
                ChipDot(colour: state.hue, breathes: state == .working).frame(width: 7, height: 7)
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        if let spoken {
            dot.accessibilityElement()
                .accessibilityLabel("State")
                .accessibilityValue(spoken)
                .accessibilityAddTraits(.isImage)
        } else {
            dot.accessibilityHidden(true)
        }
    }
}

/// The card footer's actions: a small glyph and the words, in the action's colour.
private struct FootLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title.font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
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
