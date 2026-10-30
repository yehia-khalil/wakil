import Foundation

// Workspaces, piece 3: the home screen (spec, piece 3; decisions 18–26), decided here and drawn by
// `WakilApp/Home.swift`. One home per organisation, grouped by project; a card per workspace.

/// A past conversation, as Earlier lists it: a session row, and the chain it folds (its own id and
/// every ancestor), which names its workspace by lineage.
public struct HomePastConversation: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let chain: Set<String>
    public init(id: String, title: String, subtitle: String, chain: Set<String> = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.chain = chain.isEmpty ? [id] : chain
    }
}

/// A workspace branch whose PRs decision 11's offer reads: Main's root (the repository
/// `ticket_branch` reads PRs from) and the branch.
public struct HomeBranch: Sendable, Hashable {
    public let root: String
    public let branch: String
    public init(root: String, branch: String) {
        self.root = root
        self.branch = branch
    }
}

/// What the home is built from: the window reads it (`WindowModel.homeInput`).
public struct HomeInput: Sendable {
    public var organization: String
    /// The current place's project (registry key) and environment.
    public var project: String
    public var environment: String
    /// Every project of the organisation (registry keys).
    public var projects: [String]
    /// Every workspace of the organisation, with holders and live states.
    public var workspaces: [WorkspaceListing]
    /// Every live conversation of the organisation, its workspace named (`LiveConversation.workspace`).
    public var live: [LiveConversation]
    /// The tickets in flight, most urgent first (`ticketNeedsRows`).
    public var tickets: [TicketNeedsRow]
    /// Ended conversations, newest first.
    public var past: [HomePastConversation]
    /// The pill chosen: a project, or nil for All projects.
    public var filter: String?
    /// The PRs each workspace branch heads, by Main's root and the branch (`ticket_branch`, read by
    /// the window for `homeMergedReads`): what decision 11's Archive offer is decided on.
    public var branchPRs: [HomeBranch: [PullRequestState]]
    /// What runs in each workspace, by id: piece 2's `runStatusLine` (`api running on :41200 · queue
    /// running`); absent or empty when nothing does.
    public var running: [String: String]
    /// Each project's default environment, where known: a card in another environment tags it. The
    /// window's own project defaults to the window's environment.
    public var defaultEnvironments: [String: String]
    /// Whether an environment of a project is production (Invariant 8).
    public var isProduction: @Sendable (_ project: String, _ environment: String) -> Bool

    public init(organization: String, project: String, environment: String, projects: [String] = [],
                workspaces: [WorkspaceListing] = [], live: [LiveConversation] = [], tickets: [TicketNeedsRow] = [],
                past: [HomePastConversation] = [], filter: String? = nil,
                branchPRs: [HomeBranch: [PullRequestState]] = [:], running: [String: String] = [:],
                defaultEnvironments: [String: String] = [:],
                isProduction: @escaping @Sendable (String, String) -> Bool = { _, e in e.lowercased() == "production" }) {
        self.organization = organization
        self.project = project
        self.environment = environment
        self.projects = projects
        self.workspaces = workspaces
        self.live = live
        self.tickets = tickets
        self.past = past
        self.filter = filter
        self.branchPRs = branchPRs
        self.running = running
        self.defaultEnvironments = defaultEnvironments
        self.isProduction = isProduction
    }
}

/// One live conversation's line: its state's dot, title, and its state in words.
public struct HomeConversationLine: Sendable, Equatable, Identifiable {
    public let id: String
    /// Its place in drawing order over the whole home: `landing.row.running:<index>`.
    public var index: Int
    public let title: String
    public let state: ConversationState
    /// The repos (folder names) whose checkout it holds.
    public let holds: [String]
    public let place: Place
    public let isProduction: Bool
    public let lastActivity: Date
    /// Its session, when it has one: what a click resumes should the conversation have ended
    /// meanwhile (`WindowModel.openHomeLine`).
    public var session: String? = nil
    /// Drawn in Main's block.
    public var inMain = false
    /// Its state in words, as the comp draws it at the right: *working*, *idle*, *done*, *failed*,
    /// *waiting on you*. Nothing about holds or *read only* (the home's walk).
    public var words: String { homeStateWords(state) }
}

/// A state as a line says it.
public func homeStateWords(_ state: ConversationState) -> String {
    switch state {
    case .waiting: "waiting on you"
    case .working, .done, .failed, .idle: state.rawValue
    }
}

/// One repo of a card: its folder name and branch, or *in Main* after Bring to Main.
public struct HomeRepo: Sendable, Equatable, Identifiable {
    public var id: String { repo }
    /// Main's folder (the project root) it is a checkout of.
    public let repo: String
    public let name: String
    public let branch: String
    public let inMain: Bool
    /// Whether a copy is made on disk (Bring to Main moves one).
    public let made: Bool
    /// `ini-140-move-…`, `in Main`, or `main · not copied` for a repo the workspace never copied,
    /// so the repo list stays complete.
    public var words: String {
        if inMain { return "in Main" }
        if !made { return "\(branch.isEmpty ? "main" : branch) · not copied" }
        return branch
    }
}

/// A conversation the card's *Move a conversation here…* offers.
public struct HomeMoveCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
}

/// One workspace's card (decision 20): a compact row, and everything else one expand away.
public struct HomeCard: Sendable, Equatable, Identifiable {
    public let id: String
    /// `INI-142 Login rate limit`'s two halves: the first ticket key (nil with none) and the name.
    public let key: String?
    public let name: String
    public let project: String
    public let environment: String
    public let isProduction: Bool
    /// The compact row's environment tag: drawn only when the workspace's environment differs from
    /// its project's default, or is production (Invariant 8); nil otherwise.
    public let environmentTag: String?
    public let repos: [HomeRepo]
    /// `2 PRs open · 1 failing`; nil with no PR.
    public let prs: String?
    /// The first PR's page (`…/pull/7`), for the expanded card's *checks ↗*; nil with none.
    public let prURL: String?
    /// What runs in it (piece 2's `runStatusLine`); nil when nothing does, so no **Stop**.
    public let running: String?
    public var lines: [HomeConversationLine]
    public var children: [HomeCard]
    /// The parent's name, for a child drawn on its own (its parent archived or elsewhere).
    public let branchedFrom: String?
    /// What a child row says it branched off: the parent's ticket key, else its name.
    public let branchedOff: String?
    /// How many things in it need the operator — each conversation waiting, failed or done unseen,
    /// and its tickets' reasons as one: the compact row's amber `● n`. 0 draws nothing.
    public let needCount: Int
    /// The compact row's dot: its strongest need's hue, else working, else idle.
    public let hue: ConversationState
    public var needsYou: Bool { needCount > 0 }
    public let working: Bool
    public let latest: Date
    /// The most recent live conversation: what a click on the card opens.
    public let opens: String?
    /// Bring to Main…'s repos: those with a copy on disk.
    public var bringHome: [HomeRepo] { repos.filter { $0.made && !$0.inMain } }
    /// Move a conversation here…'s rows: the project's live conversations elsewhere holding no copy.
    public let moveCandidates: [HomeMoveCandidate]
    /// Archive asks first (Rule 1): a conversation in it waits on the operator.
    public let archiveAsks: Bool
    /// Decision 11's offer: every PR of the workspace is merged — `2 PRs merged`, drawn with
    /// **Archive** on the card. Nil otherwise (Archive stays in ⋯).
    public let merged: String?
    /// ▶ Run…'s repos: those with a copy on disk, where the app runs (decision 12).
    public var runnable: [HomeRepo] { repos.filter { $0.made && !$0.inMain } }
    /// The compact row's running token: its ports (`:41200`), else `running`; nil while nothing runs.
    public var runningCompact: String? { running.map(homeRunningPorts) }
    /// The compact row offers ▶ while nothing runs and a copy is on disk to run in.
    public var offersRun: Bool { running == nil && !runnable.isEmpty }
    /// `1 repo` / `7 repos`.
    public var repoCount: String { repos.count == 1 ? "1 repo" : "\(repos.count) repos" }
}

/// The ports a running line names (`api running on :41200 · web running on :41201` → `:41200 :41201`),
/// else `running`: the compact card's token.
public func homeRunningPorts(_ line: String) -> String {
    let ports = line.split(whereSeparator: { $0 == " " || $0 == "·" || $0 == "," })
        .filter { $0.hasPrefix(":") && $0.count > 1 && $0.dropFirst().allSatisfy(\.isNumber) }
    return ports.isEmpty ? "running" : ports.joined(separator: " ")
}

/// Main of a project, while a conversation is in it.
public struct HomeMain: Sendable, Equatable {
    public var lines: [HomeConversationLine]
}

/// One project's section.
public struct HomeSection: Sendable, Equatable, Identifiable {
    public var id: String { project }
    public let project: String
    public var main: HomeMain?
    public var cards: [HomeCard]
    public let latest: Date
    /// The header's micro count: `2 workspaces · Main`, `1 workspace`, `1 conversation in Main`.
    public var summary: String {
        let n = cards.reduce(0) { $0 + 1 + $1.children.count }
        let m = main?.lines.count ?? 0
        if n == 0 { return m == 1 ? "1 conversation in Main" : "\(m) conversations in Main" }
        let w = n == 1 ? "1 workspace" : "\(n) workspaces"
        return main == nil ? w : "\(w) · Main"
    }
}

/// A pill: All projects (nil) or one project, with its NEEDS YOU rows counted.
public struct HomePill: Sendable, Equatable, Identifiable {
    public var id: String { project ?? "" }
    public let project: String?
    public let needsYou: Int
    public let selected: Bool
    public var label: String { project ?? "All projects" }
}

/// Past conversations of one workspace (or Main), newest first.
public struct HomePastGroup: Sendable, Equatable, Identifiable {
    public var id: String { workspace ?? "main" }
    /// The workspace id; nil for Main.
    public let workspace: String?
    public let name: String
    public let conversations: [HomePastConversation]
}

/// Earlier (decision 25): archived workspaces and past conversations.
public struct HomeEarlier: Sendable, Equatable {
    public let archived: [Workspace]
    public let past: [HomePastGroup]
    /// The folded line's words, or nil when there is nothing earlier.
    public var line: String? {
        var parts: [String] = []
        if !archived.isEmpty { parts.append(archived.count == 1 ? "1 archived workspace" : "\(archived.count) archived workspaces") }
        let n = past.reduce(0) { $0 + $1.conversations.count }
        if n > 0 { parts.append(n == 1 ? "1 past conversation" : "\(n) past conversations") }
        return parts.isEmpty ? nil : "Earlier — " + parts.joined(separator: " · ")
    }
}

/// The home screen, decided.
public struct HomeScreen: Sendable, Equatable {
    /// NEEDS YOU, strongest first; empty draws no section.
    public let needs: [HomeNeed]
    /// Drawn only with two project sections or more: with one, a filter would do nothing.
    public let pills: [HomePill]
    public let sections: [HomeSection]
    /// The projects with nothing going on, folded into one line that names them.
    public let quiet: [String]
    public let ticketsNotStarted: [TicketNeedsRow]
    public let earlier: HomeEarlier
    /// No project, nothing live, no workspace: the explainer and *Add a project*, and only then.
    public let firstRun: Bool

    /// `2 quiet projects`; the line names them after it.
    public var quietCount: String { quiet.count == 1 ? "1 quiet project" : "\(quiet.count) quiet projects" }

    /// The first run's explainer, two paragraphs; never drawn on a working home.
    public static let explainer = [
        "Wakil works in projects. Each project has Main, which is your own folders as they are on disk. "
            + "A conversation there reads them and changes nothing.",
        "When a conversation changes something, it gets a workspace of its own: a copy on its own branch. "
            + "Main stays untouched, and several pieces of work can run side by side.",
    ]

    /// The cards offering Archive because every PR is merged (decision 11), by id, in drawing order:
    /// what numbers their Archive (`landing.archive.offer:<n>`), as a card's own id is generated.
    public var mergedOffers: [String] {
        var out: [String] = []
        func walk(_ c: HomeCard) {
            if c.merged != nil { out.append(c.id) }
            c.children.forEach(walk)
        }
        sections.forEach { $0.cards.forEach(walk) }
        return out
    }

    /// Every card's id in drawing order, a child straight after its parent: what numbers a card's
    /// controls (`landing.card:<n>.run`), as a card's own id is generated.
    public var cardOrder: [String] {
        var out: [String] = []
        func walk(_ c: HomeCard) {
            out.append(c.id)
            c.children.forEach(walk)
        }
        sections.forEach { $0.cards.forEach(walk) }
        return out
    }

    /// Every conversation line, in drawing order.
    public var lines: [HomeConversationLine] {
        var out: [HomeConversationLine] = []
        func walk(_ c: HomeCard) {
            out += c.lines
            c.children.forEach(walk)
        }
        for s in sections {
            out += s.main?.lines ?? []
            s.cards.forEach(walk)
        }
        return out
    }
}

private let distantPast = Date(timeIntervalSince1970: 0)

private func iso(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

/// The in-flight rows of `w`'s work: its tickets' keys, else a row on one of its branches.
func homeTicketRows(of w: Workspace, in tickets: [TicketNeedsRow]) -> [TicketNeedsRow] {
    let branches = Set(w.checkouts.map(\.branch).filter { !$0.isEmpty } + [w.branch].compactMap { $0 })
    return tickets.filter { row in
        if let key = row.key, w.tickets.contains(key) { return true }
        return row.rows.contains { !$0.branch.isEmpty && branches.contains($0.branch) }
    }
}

/// The workspace a ticket in flight is worked in, for ⌘P's `#` (decision 27): an open one carrying
/// its key or working on one of its branches (`homeTicketRows`), a parent before its child, then the
/// newest. Nil when none is open: an archived workspace is Earlier's, and the ticket opens instead.
public func homeTicketWorkspace(_ row: TicketNeedsRow, in workspaces: [Workspace]) -> Workspace? {
    workspaces.filter { !$0.archived && !homeTicketRows(of: $0, in: [row]).isEmpty }
        .enumerated()
        .min { a, b in
            let pa = a.element.parent == nil ? 0 : 1, pb = b.element.parent == nil ? 0 : 1
            if pa != pb { return pa < pb }
            let da = iso(a.element.created) ?? distantPast, db = iso(b.element.created) ?? distantPast
            if da != db { return da > db }
            return a.offset < b.offset
        }?.element
}

/// The branches decision 11's offer reads: each open workspace's checkouts with a branch, by Main's
/// root (the repository `ticket_branch` reads PRs from) and the branch, once each.
public func homeMergedReads(_ workspaces: [Workspace]) -> [HomeBranch] {
    var out: [HomeBranch] = []
    for w in workspaces where !w.archived {
        for c in w.checkouts where !c.branch.isEmpty {
            let at = HomeBranch(root: c.repo, branch: c.branch)
            if !out.contains(at) { out.append(at) }
        }
    }
    return out
}

/// `2 PRs merged` when every PR `w`'s branches head is merged — each branch read, at least one PR
/// among them — else nil (decision 11). A repo with no PR is not one of its PRs; a closed one is
/// not merged.
func homeMergedLine(_ w: Workspace, _ reads: [HomeBranch: [PullRequestState]]) -> String? {
    var prs: [PullRequestState] = []
    for at in homeMergedReads([w]) {
        guard let read = reads[at] else { return nil }
        prs += read.filter { $0.head.isEmpty || $0.head == at.branch }
    }
    guard !prs.isEmpty, prs.allSatisfy({ $0.state == "merged" }) else { return nil }
    return prs.count == 1 ? "1 PR merged" : "\(prs.count) PRs merged"
}

/// The PRs line of a card: `2 PRs open · 1 failing`; nil with no PR.
func homePRLine(_ rows: [TicketNeedsRow]) -> String? {
    var prs = Set<String>()
    var failing = Set<String>()
    for r in rows.flatMap(\.rows) where r.pr > 0 {
        let id = "\(r.repo)#\(r.pr)"
        prs.insert(id)
        if !r.failing.isEmpty { failing.insert(id) }
    }
    guard !prs.isEmpty else { return nil }
    var line = prs.count == 1 ? "1 PR open" : "\(prs.count) PRs open"
    if !failing.isEmpty { line += " · \(failing.count) failing" }
    return line
}

/// Builds the home screen (spec, piece 3; amendment 2026-10-30, "the home, as the comp draws it").
public func homeScreen(_ input: HomeInput) -> HomeScreen {
    let org = input.organization
    let live = input.live.filter { $0.place.organization == org || org.isEmpty }
    let all = input.workspaces.map(\.workspace)
    let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let open = input.workspaces.filter { !$0.workspace.archived }
    // Who holds a copy anywhere: Move is for a conversation holding none (decision 6).
    var holding: [String: [String]] = [:]
    for l in open {
        for (repo, c) in l.holders { holding[c, default: []].append((repo as NSString).lastPathComponent) }
    }
    func line(_ c: LiveConversation) -> HomeConversationLine {
        HomeConversationLine(id: c.id, index: 0, title: c.title, state: c.state,
                             holds: (holding[c.id] ?? []).sorted(), place: c.place,
                             isProduction: c.isProduction, lastActivity: c.lastActivity, session: c.session)
    }
    func defaultEnvironment(_ project: String) -> String? {
        input.defaultEnvironments[project] ?? (project == input.project ? input.environment : nil)
    }
    var needs: [HomeNeed] = []
    func card(_ l: WorkspaceListing) -> HomeCard {
        let w = l.workspace
        let mine = live.filter { $0.workspace?.id == w.id || l.live[$0.id] != nil }
            .sorted { $0.lastActivity > $1.lastActivity }
        let rows = homeTicketRows(of: w, in: input.tickets)
        let repos = w.checkouts.map {
            HomeRepo(repo: $0.repo, name: $0.repoName, branch: $0.branch, inMain: $0.inMain, made: $0.path != nil)
        }
        let latest = ([iso(w.created)] + mine.map(\.lastActivity) + rows.map { iso($0.activity) })
            .compactMap { $0 }.max() ?? distantPast
        let candidates = live.filter {
            $0.place.project == w.project && $0.workspace?.id != w.id && l.live[$0.id] == nil && holding[$0.id] == nil
        }.map { HomeMoveCandidate(id: $0.id, title: $0.title) }
        let parent = w.parent.flatMap { byId[$0] }
        let need = homeWorkspaceNeed(w, mine: mine, rows: rows, latest: latest)
        if let need { needs.append(need) }
        let working = mine.contains { $0.state == .working }
        let production = input.isProduction(w.project, w.environment)
        let tag = production || (defaultEnvironment(w.project).map { $0 != w.environment } ?? false) ? w.environment : nil
        return HomeCard(
            id: w.id, key: w.tickets.first, name: w.name, project: w.project, environment: w.environment,
            isProduction: production, environmentTag: tag, repos: repos, prs: homePRLine(rows),
            prURL: rows.flatMap(\.rows).first { !$0.url.isEmpty && $0.pr > 0 }?.url,
            running: input.running[w.id].flatMap { $0.isEmpty ? nil : $0 },
            lines: mine.map(line), children: [],
            branchedFrom: parent?.name, branchedOff: parent.map { $0.tickets.first ?? $0.name },
            needCount: homeNeedCount(mine: mine, rows: rows),
            hue: need?.hue ?? (working ? .working : .idle), working: working,
            latest: latest, opens: mine.first?.id, moveCandidates: candidates,
            archiveAsks: mine.contains { $0.state == .waiting }, merged: homeMergedLine(w, input.branchPRs))
    }
    func ordered(_ cards: [HomeCard]) -> [HomeCard] {
        func rank(_ c: HomeCard) -> Int { c.needsYou ? 0 : c.working ? 1 : 2 }
        return cards.sorted { (rank($0), $1.latest, $0.id) < (rank($1), $0.latest, $1.id) }
    }

    // Projects: each with something going on is a section; the rest are quiet, named on one line.
    var projects: [String] = []
    for p in input.projects + open.map(\.workspace.project) + live.map(\.place.project)
    where !p.isEmpty && !projects.contains(p) { projects.append(p) }
    let firstRun = projects.isEmpty && live.isEmpty && open.isEmpty

    var sections: [HomeSection] = []
    var quiet: [String] = []
    for p in projects {
        let cards = open.filter { $0.workspace.project == p }.map(card)
        let ids = Set(cards.map(\.id))
        // A child under its parent while the parent is drawn; on its own otherwise.
        var top: [HomeCard] = []
        var children: [String: [HomeCard]] = [:]
        for c in cards {
            if let parent = byId[c.id]?.parent, ids.contains(parent) { children[parent, default: []].append(c) }
            else { top.append(c) }
        }
        func nest(_ c: HomeCard) -> HomeCard {
            var c = c
            c.children = ordered(children[c.id] ?? []).map(nest)
            return c
        }
        let mainLive = live.filter { c in c.place.project == p && c.workspace == nil && !open.contains { $0.live[c.id] != nil } }
            .sorted { $0.lastActivity > $1.lastActivity }
        needs += mainLive.compactMap(homeMainNeed)
        let mainLines = mainLive.map(line).map { l in var l = l; l.inMain = true; return l }
        let main = mainLines.isEmpty ? nil : HomeMain(lines: mainLines)
        guard main != nil || !cards.isEmpty else {
            quiet.append(p)
            continue
        }
        let latest = (cards.map(\.latest) + mainLines.map(\.lastActivity)).max() ?? distantPast
        sections.append(HomeSection(project: p, main: main, cards: ordered(top).map(nest), latest: latest))
    }
    sections.sort { ($0.latest, $1.project) > ($1.latest, $0.project) }
    needs = homeNeedsOrdered(needs)

    // Pills, before the filter narrows anything: each counts its project's NEEDS YOU rows.
    func needsYou(_ project: String?) -> Int { needs.filter { project == nil || $0.project == project }.count }
    let filter = input.filter.flatMap { f in sections.contains { $0.project == f } ? f : nil }
    let pills = sections.count < 2 ? [] :
        [HomePill(project: nil, needsYou: needsYou(nil), selected: filter == nil)]
        + sections.map { HomePill(project: $0.project, needsYou: needsYou($0.project), selected: $0.project == filter) }
    if let filter {
        sections = sections.filter { $0.project == filter }
        needs = needs.filter { $0.project == filter }
        quiet = []
    }

    // Number every conversation line in drawing order.
    var index = 0
    func number(_ lines: inout [HomeConversationLine]) {
        for i in lines.indices { lines[i].index = index; index += 1 }
    }
    func number(_ c: inout HomeCard) {
        number(&c.lines)
        for i in c.children.indices { number(&c.children[i]) }
    }
    for s in sections.indices {
        if sections[s].main != nil { number(&sections[s].main!.lines) }
        for c in sections[s].cards.indices { number(&sections[s].cards[c]) }
    }

    let notStarted = input.tickets.filter { row in
        !homeTicketStarted(row, workspaces: all, live: live)
            && (filter == nil || row.rows.contains { $0.project == filter } || row.rows.allSatisfy { $0.project.isEmpty })
    }

    // Earlier: archived workspaces, past conversations grouped by workspace.
    let archived = all.filter { $0.archived && (filter == nil || $0.project == filter) }
    var groups: [HomePastGroup] = []
    var order: [String] = []
    var grouped: [String: [HomePastConversation]] = [:]
    for p in input.past {
        let w = all.last { !$0.conversations.filter(p.chain.contains).isEmpty }
        if let filter, let w, w.project != filter { continue }
        let key = w?.id ?? ""
        if grouped[key] == nil { order.append(key) }
        grouped[key, default: []].append(p)
    }
    for key in order {
        groups.append(HomePastGroup(workspace: key.isEmpty ? nil : key, name: key.isEmpty ? "Main" : byId[key]?.name ?? key,
                                    conversations: grouped[key] ?? []))
    }

    return HomeScreen(needs: needs, pills: pills, sections: sections, quiet: quiet, ticketsNotStarted: notStarted,
                      earlier: HomeEarlier(archived: archived, past: groups), firstRun: firstRun)
}

/// Whether a ticket in flight is started, so it leaves *Tickets*: a workspace (open or archived)
/// carries its key or works on one of its branches, or a live conversation carries it — its key in
/// the title, or a hand-off's key or branch (piece 3 walk).
public func homeTicketStarted(_ row: TicketNeedsRow, workspaces: [Workspace], live: [LiveConversation]) -> Bool {
    workspaces.contains { !homeTicketRows(of: $0, in: [row]).isEmpty } || live.contains { homeConversationCarries($0, row) }
}

/// A Tickets row's state: the tracker's status (`In progress`), else its most urgent state in words.
public func homeTicketStatus(_ row: TicketNeedsRow) -> String {
    row.rows.first { !$0.status.isEmpty }?.status ?? landingTicketState(row).words
}

/// Whether live conversation `c` carries ticket `row`: the ticket's key in its title as a word, or a
/// hand-off on the ticket's key or one of its branches.
func homeConversationCarries(_ c: LiveConversation, _ row: TicketNeedsRow) -> Bool {
    if let h = c.handoff {
        if let key = h.key, key == row.key { return true }
        if !h.branch.isEmpty, row.rows.contains(where: { $0.branch == h.branch }) { return true }
    }
    guard let key = row.key, !key.isEmpty else { return false }
    let words = c.title.uppercased().split { !($0.isLetter || $0.isNumber || $0 == "-") }
    return words.contains { $0 == Substring(key.uppercased()) }
}

