import Foundation

// Workspaces, piece 3: the home's NEEDS YOU (amendment 2026-10-30, "the home, as the comp draws it").
// One row per workspace, or per conversation in Main, that needs the operator: every why it has,
// strongest first, in its strongest why's hue, with that why's one action. Decided here; drawn by
// `WakilApp/Home.swift`.

/// One reason something needs the operator, strongest first by `rank`.
public enum HomeNeedReason: Sendable, Equatable {
    /// A conversation waits on the operator (a question, a permission, a proposal parked).
    case waiting
    /// A conversation's turn failed, unseen.
    case failed
    /// A PR of its ticket has failing checks.
    case checksFailing(Int)
    /// A PR of its ticket asks the operator's review.
    case reviewRequested
    /// Review threads on its PRs wait on a reply.
    case comments(Int)
    /// A conversation finished a turn the operator has not seen.
    case done

    /// Waiting › failed › checks › review › comments › done.
    public var rank: Int {
        switch self {
        case .waiting: 0
        case .failed: 1
        case .checksFailing: 2
        case .reviewRequested: 3
        case .comments: 4
        case .done: 6
        }
    }

    public var words: String {
        switch self {
        case .waiting: "waiting on you"
        case .failed: "failed"
        case .checksFailing(let n): "checks failing \(n)"
        case .reviewRequested: "review requested"
        case .comments(let n): n == 1 ? "1 comment" : "\(n) comments"
        case .done: "done, unseen"
        }
    }

    /// The reserved hue it is drawn in: amber waits, red failed, green done unseen.
    public var hue: ConversationState {
        switch self {
        case .waiting, .reviewRequested, .comments: .waiting
        case .failed, .checksFailing: .failed
        case .done: .done
        }
    }

    /// Whether it comes from the ticket's PRs, which a card's `● n` counts once.
    var fromTicket: Bool {
        switch self {
        case .checksFailing, .reviewRequested, .comments: true
        case .waiting, .failed, .done: false
        }
    }
}

/// What a NEEDS YOU row's one action does.
public enum HomeNeedAction: Sendable, Equatable {
    /// **Review**: the waiting conversation, brought back (`openHomeLine`).
    case review(conversation: String, session: String?)
    /// **Open**: the conversation that failed or finished.
    case open(conversation: String, session: String?)
    /// **Open**: the workspace's view (`workspace_open`).
    case openWorkspace(String)
    /// **checks ↗** / **review ↗**: the PR's page, in Wakil's browser (`browser_open`).
    case link(url: String)

    public var label: String {
        switch self {
        case .review: "Review"
        case .open, .openWorkspace: "Open"
        case .link(let url): url.hasSuffix("/checks") ? "checks ↗" : "review ↗"
        }
    }
}

/// What a click on the row itself opens.
public enum HomeNeedOpen: Sendable, Equatable {
    case conversation(String, session: String?)
    case workspace(String)
}

/// One NEEDS YOU row.
public struct HomeNeed: Sendable, Equatable, Identifiable {
    /// The workspace's id, else the Main conversation's.
    public let id: String
    public let project: String
    /// The workspace's first ticket key, mono before the title; nil with none.
    public let key: String?
    public let title: String
    /// The workspace the row is about; nil for a conversation in Main.
    public let workspace: String?
    /// Every why, strongest first.
    public let reasons: [HomeNeedReason]
    public let action: HomeNeedAction
    public let opens: HomeNeedOpen
    public let latest: Date

    /// `waiting on you · 2 messages`: every why, strongest first.
    public var why: String { reasons.map(\.words).joined(separator: " · ") }
    /// The strongest why's hue: the dot's and the why's.
    public var hue: ConversationState { reasons.first?.hue ?? .idle }
    var rank: Int { reasons.first?.rank ?? .max }
}

/// The ticket reasons of a workspace's rows: failing checks, review asked, threads to answer — each
/// once, summed over its PRs.
func homeTicketReasons(_ rows: [TicketNeedsRow]) -> [HomeNeedReason] {
    let prs = rows.flatMap(\.rows)
    var out: [HomeNeedReason] = []
    let failing = prs.reduce(0) { $0 + $1.failing.count }
    if failing > 0 { out.append(.checksFailing(failing)) }
    if prs.contains(where: \.review) { out.append(.reviewRequested) }
    let threads = prs.reduce(0) { $0 + $1.threads.count }
    if threads > 0 { out.append(.comments(threads)) }
    return out
}

/// A PR page's checks: `…/pull/7/checks`; the page itself for anything else.
public func homeChecksURL(_ url: String) -> String {
    url.contains("/pull/") ? url + "/checks" : url
}

/// A conversation's own reason, if its state is one.
func homeConversationReason(_ state: ConversationState) -> HomeNeedReason? {
    switch state {
    case .waiting: .waiting
    case .failed: .failed
    case .done: .done
    case .working, .idle: nil
    }
}

/// A workspace's NEEDS YOU row: its conversations' reasons and its tickets', strongest first; nil
/// when nothing in it needs the operator. `mine` is newest first.
func homeWorkspaceNeed(_ w: Workspace, mine: [LiveConversation], rows: [TicketNeedsRow], latest: Date) -> HomeNeed? {
    var reasons: [HomeNeedReason] = []
    var by: [Int: LiveConversation] = [:]
    for c in mine {
        guard let r = homeConversationReason(c.state) else { continue }
        if by[r.rank] == nil { by[r.rank] = c; reasons.append(r) }
    }
    reasons += homeTicketReasons(rows)
    reasons.sort { $0.rank < $1.rank }
    guard let first = reasons.first else { return nil }
    let url = rows.flatMap(\.rows).first { !$0.url.isEmpty && $0.pr > 0 }?.url
    let action: HomeNeedAction
    let opens: HomeNeedOpen
    if let c = by[first.rank] {
        action = first == .waiting ? .review(conversation: c.id, session: c.session) : .open(conversation: c.id, session: c.session)
        opens = .conversation(c.id, session: c.session)
    } else {
        switch first {
        case .checksFailing: action = url.map { .link(url: homeChecksURL($0)) } ?? .openWorkspace(w.id)
        default: action = url.map { .link(url: $0) } ?? .openWorkspace(w.id)
        }
        opens = .workspace(w.id)
    }
    return HomeNeed(id: w.id, project: w.project, key: w.tickets.first, title: w.name, workspace: w.id,
                    reasons: reasons, action: action, opens: opens, latest: latest)
}

/// A Main conversation's NEEDS YOU row; nil when its state needs nothing.
func homeMainNeed(_ c: LiveConversation) -> HomeNeed? {
    guard let r = homeConversationReason(c.state) else { return nil }
    return HomeNeed(id: c.id, project: c.place.project, key: nil, title: c.title, workspace: nil, reasons: [r],
                    action: r == .waiting ? .review(conversation: c.id, session: c.session) : .open(conversation: c.id, session: c.session),
                    opens: .conversation(c.id, session: c.session), latest: c.lastActivity)
}

/// NEEDS YOU's order: strongest why first, then the newest, then by id.
func homeNeedsOrdered(_ needs: [HomeNeed]) -> [HomeNeed] {
    needs.sorted { ($0.rank, $1.latest, $0.id) < ($1.rank, $0.latest, $1.id) }
}

/// A card's `● n`: its conversations' reasons, each conversation once, and its tickets' as one.
func homeNeedCount(mine: [LiveConversation], rows: [TicketNeedsRow]) -> Int {
    mine.filter { homeConversationReason($0.state) != nil }.count + (homeTicketReasons(rows).isEmpty ? 0 : 1)
}
