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
    /// Whether an environment of a project is production (Invariant 8).
    public var isProduction: @Sendable (_ project: String, _ environment: String) -> Bool

    public init(organization: String, project: String, environment: String, projects: [String] = [],
                workspaces: [WorkspaceListing] = [], live: [LiveConversation] = [], tickets: [TicketNeedsRow] = [],
                past: [HomePastConversation] = [], filter: String? = nil,
                branchPRs: [HomeBranch: [PullRequestState]] = [:],
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
        self.isProduction = isProduction
    }
}

/// One live conversation's line: its state's dot, title, what it does, the repos it holds.
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
    /// `working · holds api, web`; `idle · read only` in Main.
    public var detail: String {
        if holds.isEmpty { return "\(state.rawValue) · read only" }
        return "\(state.rawValue) · holds \(holds.joined(separator: ", "))"
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
    public var words: String { inMain ? "in Main" : branch }
}

/// A conversation the card's *Move a conversation here…* offers.
public struct HomeMoveCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
}

/// One workspace's card (decision 20): everything about it, nothing capped.
public struct HomeCard: Sendable, Equatable, Identifiable {
    public let id: String
    /// `INI-142 Login rate limit`'s two halves: the first ticket key (nil with none) and the name.
    public let key: String?
    public let name: String
    public let project: String
    public let environment: String
    public let isProduction: Bool
    public let repos: [HomeRepo]
    /// `2 PRs open · 1 failing`; nil with no PR.
    public let prs: String?
    /// What needs the operator, in amber; nil when nothing does.
    public let needs: String?
    public var lines: [HomeConversationLine]
    public var children: [HomeCard]
    /// The parent's name, for a child drawn on its own (its parent archived or elsewhere).
    public let branchedFrom: String?
    public let needsYou: Bool
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
    /// `1 repo` / `7 repos`.
    public var repoCount: String { repos.count == 1 ? "1 repo" : "\(repos.count) repos" }
}

/// Main of a project, while a conversation is in it.
public struct HomeMain: Sendable, Equatable {
    public var lines: [HomeConversationLine]
    public static let words = "your folders · asking and reading"
}

/// One project's section.
public struct HomeSection: Sendable, Equatable, Identifiable {
    public var id: String { project }
    public let project: String
    /// The current project: *you are here*.
    public let current: Bool
    public var main: HomeMain?
    public var cards: [HomeCard]
    public let latest: Date
    /// `2 workspaces · Main`, `1 workspace`, `Main`, `nothing going on`.
    public var summary: String {
        var parts: [String] = []
        let n = cards.reduce(0) { $0 + 1 + $1.children.count }
        if n > 0 { parts.append(n == 1 ? "1 workspace" : "\(n) workspaces") }
        if main != nil { parts.append("Main") }
        return parts.isEmpty ? "nothing going on" : parts.joined(separator: " · ")
    }
}

/// A pill: All projects (nil) or one project, with its needs-you count.
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
        return parts.isEmpty ? nil : "Earlier — " + parts.joined(separator: ", ")
    }
}

/// The home screen, decided.
public struct HomeScreen: Sendable, Equatable {
    public let title: String
    /// Drawn only with two projects or more.
    public let pills: [HomePill]
    public let sections: [HomeSection]
    public let ticketsNotStarted: [TicketNeedsRow]
    public let earlier: HomeEarlier
    /// The help line in full (three cards or fewer), else an ⓘ beside the title (decision 21).
    public let helpInFull: Bool
    /// Nothing live and no workspace: the help line, the tickets and *Open a pane* (decision 26).
    public let firstRun: Bool

    public static let help = "A conversation is one agent and its thread. It starts in Main, your own folders, "
        + "where it can read and answer. When it changes something it gets a workspace: a copy Wakil makes for "
        + "that piece of work, so your folders stay as you left them."

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

/// Builds the home screen (spec, piece 3).
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
                             isProduction: c.isProduction, lastActivity: c.lastActivity)
    }
    func card(_ l: WorkspaceListing) -> HomeCard {
        let w = l.workspace
        let mine = live.filter { $0.workspace?.id == w.id || l.live[$0.id] != nil }
            .sorted { $0.lastActivity > $1.lastActivity }
        let rows = homeTicketRows(of: w, in: input.tickets)
        let waiting = mine.filter { $0.state == .waiting || $0.state == .failed }
        var needs: [String] = []
        for c in waiting { needs.append("‘\(c.title)’ \(c.state == .waiting ? "is waiting for you" : "failed")") }
        for r in rows where r.urgent.needsYou { needs.append(r.urgent.words) }
        let repos = w.checkouts.map {
            HomeRepo(repo: $0.repo, name: $0.repoName, branch: $0.branch, inMain: $0.inMain, made: $0.path != nil)
        }
        let latest = ([iso(w.created)] + mine.map(\.lastActivity) + rows.map { iso($0.activity) })
            .compactMap { $0 }.max() ?? distantPast
        let candidates = live.filter {
            $0.place.project == w.project && $0.workspace?.id != w.id && l.live[$0.id] == nil && holding[$0.id] == nil
        }.map { HomeMoveCandidate(id: $0.id, title: $0.title) }
        let parent = w.parent.flatMap { byId[$0] }
        return HomeCard(
            id: w.id, key: w.tickets.first, name: w.name, project: w.project, environment: w.environment,
            isProduction: input.isProduction(w.project, w.environment), repos: repos, prs: homePRLine(rows),
            needs: needs.isEmpty ? nil : needs.joined(separator: " · "), lines: mine.map(line), children: [],
            branchedFrom: parent?.name, needsYou: !needs.isEmpty, working: mine.contains { $0.state == .working },
            latest: latest, opens: mine.first?.id, moveCandidates: candidates,
            archiveAsks: mine.contains { $0.state == .waiting }, merged: homeMergedLine(w, input.branchPRs))
    }
    func ordered(_ cards: [HomeCard]) -> [HomeCard] {
        func rank(_ c: HomeCard) -> Int { c.needsYou ? 0 : c.working ? 1 : 2 }
        return cards.sorted { (rank($0), $1.latest, $0.id) < (rank($1), $0.latest, $1.id) }
    }

    // Projects: each with something going on, the current one always (its header holds Main's Open).
    var projects: [String] = []
    for p in [input.project] + input.projects + open.map(\.workspace.project) + live.map(\.place.project)
    where !p.isEmpty && !projects.contains(p) { projects.append(p) }

    var sections: [HomeSection] = []
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
        let mainLines = live.filter { c in c.place.project == p && c.workspace == nil && !open.contains { $0.live[c.id] != nil } }
            .sorted { $0.lastActivity > $1.lastActivity }.map(line)
        let main = mainLines.isEmpty ? nil : HomeMain(lines: mainLines)
        guard p == input.project || main != nil || !cards.isEmpty else { continue }
        let latest = (cards.map(\.latest) + mainLines.map(\.lastActivity)).max() ?? distantPast
        sections.append(HomeSection(project: p, current: p == input.project, main: main,
                                    cards: ordered(top).map(nest), latest: latest))
    }
    let current = sections.filter(\.current)
    sections = current + sections.filter { !$0.current }.sorted { ($0.latest, $1.project) > ($1.latest, $0.project) }

    // Pills, before the filter narrows anything.
    func needsYou(_ s: HomeSection) -> Int {
        func count(_ c: HomeCard) -> Int { (c.needsYou ? 1 : 0) + c.children.reduce(0) { $0 + count($1) } }
        return s.cards.reduce(0) { $0 + count($1) }
            + (s.main?.lines.filter { $0.state == .waiting || $0.state == .failed }.count ?? 0)
    }
    let filter = input.filter.flatMap { f in sections.contains { $0.project == f } ? f : nil }
    let pills = sections.count < 2 ? [] :
        [HomePill(project: nil, needsYou: sections.reduce(0) { $0 + needsYou($1) }, selected: filter == nil)]
        + sections.map { HomePill(project: $0.project, needsYou: needsYou($0), selected: $0.project == filter) }
    if let filter { sections = sections.filter { $0.project == filter } }

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

    // Tickets not started here: no workspace carries their key or works on their branch.
    let notStarted = input.tickets.filter { row in
        !all.contains { w in !homeTicketRows(of: w, in: [row]).isEmpty }
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

    let cardCount = sections.reduce(0) { n, s in
        func count(_ c: HomeCard) -> Int { 1 + c.children.reduce(0) { $0 + count($1) } }
        return n + s.cards.reduce(0) { $0 + count($1) } + (s.main == nil ? 0 : 1)
    }
    return HomeScreen(
        title: "Work in \(org)", pills: pills, sections: sections, ticketsNotStarted: notStarted,
        earlier: HomeEarlier(archived: archived, past: groups), helpInFull: cardCount <= 3,
        firstRun: live.isEmpty && open.isEmpty)
}
