import Foundation

/// What needs the operator, and in what order (spec, *State in words, and the urgency order*): pure
/// functions over the last `ticket_in_flight` read, the live handed conversations and the drafts.
/// The rail, the Ticket label, the Landing and ⌘P all draw from these.

/// A handed conversation's state, as its chip shows it; a hand-off whose conversation ended is not
/// live. `idle` is a finished turn the operator has seen (no chip): it reads as done everywhere but
/// the Ticket header, which says "Agent finished" only until the operator opens it.
public enum TicketHandOffLive: String, Sendable { case working, waiting, done, failed, idle }

/// A ticket's single most urgent state: its tier (1 most urgent) and its words.
public struct TicketUrgent: Sendable, Equatable {
    public let tier: Int
    public let words: String
    /// Tiers 1–6 wait on the operator; 7–9 are only in flight.
    public var needsYou: Bool { tier <= 6 }
    public init(tier: Int, words: String) { self.tier = tier; self.words = words }
}

/// Every reason a row holds, tiers 1–7, unordered; tiers 8 and 9 are what a row with none reads.
/// Words for a PR's tier come from the row's numbers, never from its `state`.
private func ticketReasons(_ row: InFlightRowState, handoffs: [String: TicketHandOffLive], drafts: Int) -> [TicketUrgent] {
    var out: [TicketUrgent] = []
    let live = Set(row.handoffs.compactMap { handoffs[$0.conversation] })
    if live.contains(.failed) { out.append(TicketUrgent(tier: 1, words: "agent failed")) }
    if live.contains(.waiting) { out.append(TicketUrgent(tier: 2, words: "agent waiting")) }
    if drafts > 0 { out.append(TicketUrgent(tier: 3, words: drafts == 1 ? "1 draft to send" : "\(drafts) drafts to send")) }
    // A drafted thread reads as its draft, not a second time as a comment.
    let comments = row.threads.count - drafts
    if comments > 0 {
        out.append(TicketUrgent(tier: 4, words: "#\(row.pr) · " + (comments == 1 ? "1 comment" : "\(comments) comments")))
    }
    if let only = row.failing.first {
        out.append(TicketUrgent(tier: 5, words: row.failing.count == 1 ? "#\(row.pr) · \(only) failing"
            : "#\(row.pr) · \(row.failing.count) checks failing"))
    }
    if row.review { out.append(TicketUrgent(tier: 6, words: "#\(row.pr) · review requested")) }
    if live.contains(.working) { out.append(TicketUrgent(tier: 7, words: "agent working")) }
    return out
}

/// The most urgent of `reasons`, ` · +N more` after it for the others; with none, the first open
/// PR among `rows` (`#209 · open`), else `local branch`.
private func ticketUrgent(_ reasons: [TicketUrgent], rows: [InFlightRowState]) -> TicketUrgent {
    let sorted = reasons.sorted { $0.tier < $1.tier }
    guard let first = sorted.first else {
        if let pr = rows.first(where: { $0.pr > 0 })?.pr { return TicketUrgent(tier: 8, words: "#\(pr) · open") }
        return TicketUrgent(tier: 9, words: "local branch")
    }
    return sorted.count == 1 ? first : TicketUrgent(tier: first.tier, words: "\(first.words) · +\(sorted.count - 1) more")
}

/// One row's most urgent state. `handoffs` are the live handed conversations' states by conversation
/// id (an ended one is absent, so ignored); `drafts` the drafts on the row's waiting threads.
public func ticketUrgentState(_ row: InFlightRowState, handoffs: [String: TicketHandOffLive], drafts: Int) -> TicketUrgent {
    ticketUrgent(ticketReasons(row, handoffs: handoffs, drafts: drafts), rows: [row])
}

/// One ticket in flight — or a PR with no ticket key — with its PRs and branches and its most urgent state.
public struct TicketNeedsRow: Sendable, Equatable, Identifiable {
    /// The ticket's key, else `<repo>#<pr>`.
    public let id: String
    public let key: String?
    public let title: String
    public let urgent: TicketUrgent
    /// Its PRs and branches, Waiting on you's rows first.
    public let rows: [InFlightRowState]
    /// The newest of its rows' `activity` (RFC 3339).
    public let activity: String
    /// False when no project of the organisation holds any of its rows' repositories.
    public let openable: Bool
    /// A live handed conversation of this ticket finished its turn (done, or idle once seen): the
    /// Landing says "agent finished" when nothing more urgent holds (`landingTicketState`).
    public var agentFinished: Bool = false
}

/// A row's `activity` as a time; nil when it is not one.
private func ticketActivityDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

/// The tickets in flight, one row per ticket key (a keyless PR by its PR), ordered by tier, then
/// newest `activity`. Drafts count toward a row when their thread is one it waits on.
public func ticketNeedsRows(_ s: InFlightState, handoffs: [String: TicketHandOffLive],
                            drafts: [String: TicketDraftState]) -> [TicketNeedsRow] {
    var order: [String] = []
    var grouped: [String: [InFlightRowState]] = [:]
    for r in s.waitingOnYou + s.inFlight {
        let id = r.key.isEmpty ? "\(r.repo)#\(r.pr)" : r.key
        // A row Go lists under both Waiting on you and In flight is one row: its reasons count once.
        if grouped[id]?.contains(where: { $0.root == r.root && $0.branch == r.branch && $0.repo == r.repo && $0.pr == r.pr }) == true {
            continue
        }
        if grouped[id] == nil { order.append(id) }
        grouped[id, default: []].append(r)
    }
    let rows = order.map { id -> TicketNeedsRow in
        let rs = grouped[id] ?? []
        var reasons: [TicketUrgent] = []
        for r in rs {
            let drafted = r.threads.filter { drafts[$0] != nil }.count
            // An agent's state is the conversation's, carried by every row of its ticket: said once.
            for reason in ticketReasons(r, handoffs: handoffs, drafts: drafted)
            where !([1, 2, 7].contains(reason.tier) && reasons.contains(reason)) {
                reasons.append(reason)
            }
        }
        let activity = rs.map(\.activity).max { (ticketActivityDate($0) ?? .distantPast) < (ticketActivityDate($1) ?? .distantPast) } ?? ""
        let finished = rs.contains { r in r.handoffs.contains { [.done, .idle].contains(handoffs[$0.conversation]) } }
        return TicketNeedsRow(id: id, key: rs.first?.key.isEmpty == false ? rs.first?.key : nil,
                              title: rs.first { !$0.title.isEmpty }?.title ?? "", urgent: ticketUrgent(reasons, rows: rs),
                              rows: rs, activity: activity, openable: rs.contains { !$0.root.isEmpty },
                              agentFinished: finished)
    }
    return rows.sorted { a, b in
        if a.urgent.tier != b.urgent.tier { return a.urgent.tier < b.urgent.tier }
        let da = ticketActivityDate(a.activity) ?? .distantPast, db = ticketActivityDate(b.activity) ?? .distantPast
        if da != db { return da > db }
        return a.id < b.id
    }
}

/// The Landing's **Tickets in flight**: at most five rows, most urgent first as given, and
/// `All 7 in ⌘P` when there are more (it opens ⌘P with `#` typed); nil at five or fewer.
public func landingTicketRows(_ rows: [TicketNeedsRow]) -> (shown: [TicketNeedsRow], allLine: String?) {
    (Array(rows.prefix(5)), rows.count > 5 ? "All \(rows.count) in ⌘P" : nil)
}

/// A Landing ticket row's state line (walk 2026-10-29): the row's most urgent state, except that a
/// handed agent that finished, with no reason of tiers 1–7 holding, reads "agent finished" in place
/// of the PR's "open" or "local branch". The row never names the conversation: Running lists that.
public func landingTicketState(_ row: TicketNeedsRow) -> TicketUrgent {
    guard row.agentFinished, row.urgent.tier >= 8 else { return row.urgent }
    return TicketUrgent(tier: row.urgent.tier, words: "agent finished")
}

/// A row's name where its key goes: the key, else `#215 · api` (`ticketRowName`).
public func ticketNeedsRowName(_ row: TicketNeedsRow) -> String {
    let first = row.rows.first
    return ticketRowName(key: row.key ?? "", repo: first?.repo ?? "", pr: first?.pr ?? 0)
}

/// What choosing a row dispatches, `ticket_open`'s params: the ticket's key at its first row's root
/// and branch (its most urgent: Waiting on you's come first) with that row's PR to scroll to; a
/// keyless row with `key` null, by its root and branch; a row no project holds by its PR and
/// repository, since it has no root.
public func ticketOpenParams(_ row: TicketNeedsRow) -> JSONValue {
    var o: [String: JSONValue] = ["key": row.key.map { .string($0) } ?? .null]
    let first = row.rows.first { !$0.root.isEmpty } ?? row.rows.first
    if let first {
        if !first.root.isEmpty {
            o["root"] = .string(first.root)
            if !first.branch.isEmpty { o["branch"] = .string(first.branch) }
        } else if row.key == nil {
            o["repo"] = .string(first.repo)
        }
        if first.pr > 0 { o["pr"] = .integer(Int64(first.pr)) }
    }
    return .object(o)
}

/// The items waiting on the operator: the reply's own `count`; 0 before a read.
public func ticketNeedsCount(_ s: InFlightState?) -> Int { s?.count ?? 0 }

/// The rail's tooltip and accessibility label: `4 waiting on you: 3 review threads, 1 failing check`,
/// a kind with none left out; nil when nothing waits.
public func ticketNeedsLabel(_ s: InFlightState?) -> String? {
    guard let s, s.count > 0 else { return nil }
    func part(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
    let parts = [
        part(s.waitingOnYou.reduce(0) { $0 + $1.threads.count }, "review thread", "review threads"),
        part(s.waitingOnYou.filter { !$0.failing.isEmpty }.count, "failing check", "failing checks"),
        part(s.waitingOnYou.filter(\.review).count, "review request", "review requests"),
    ].compactMap { $0 }
    return parts.isEmpty ? "\(s.count) waiting on you" : "\(s.count) waiting on you: " + parts.joined(separator: ", ")
}

/// The editor's Ticket label counts only what its body can show for this project (piece 3 walk): a
/// project whose roots are read and none is a git repository has no branch to show a ticket on, so
/// it counts nothing. Roots not read yet, or any repository among them: the organisation's count.
public func ticketNeedsCount(_ s: InFlightState?, roots: [GitRootState]) -> Int {
    ticketCountShowable(roots) ? ticketNeedsCount(s) : 0
}

/// `ticketNeedsLabel` for the editor's Ticket label, by `ticketNeedsCount(_:roots:)`'s rule.
public func ticketNeedsLabel(_ s: InFlightState?, roots: [GitRootState]) -> String? {
    ticketCountShowable(roots) ? ticketNeedsLabel(s) : nil
}

private func ticketCountShowable(_ roots: [GitRootState]) -> Bool {
    roots.isEmpty || roots.contains(where: gitRootIsRepository)
}

/// Whether the 2-minute read runs: Wakil is the active app, the screen is unlocked, and an
/// organisation is open.
public func ticketPollWanted(appActive: Bool, screenLocked: Bool, organization: String) -> Bool {
    appActive && !screenLocked && !organization.isEmpty
}

/// `ticket_in_flight`'s reply: the read, and `needs`, one entry per item the count counts — each
/// waiting review thread, each PR with failing checks, each review request.
func ticketInFlightReply(_ s: InFlightState) -> JSONValue {
    guard case .object(var o) = ticketJSON(s) else { return .null }
    var needs: [JSONValue] = []
    for r in s.waitingOnYou {
        let at: [String: JSONValue] = ["key": .string(r.key), "repo": .string(r.repo), "pr": .integer(Int64(r.pr))]
        for t in r.threads { needs.append(.object(at.merging(["kind": .string("review thread"), "thread": .string(t)]) { $1 })) }
        if !r.failing.isEmpty {
            needs.append(.object(at.merging(["kind": .string("failing check"), "checks": .array(r.failing.map { .string($0) })]) { $1 }))
        }
        if r.review { needs.append(.object(at.merging(["kind": .string("review request")]) { $1 })) }
    }
    o["needs"] = .array(needs)
    return .object(o)
}

/// The project a window shows, for scoping what its Ticket tab, its count and ⌘P's tickets hold
/// (the walk, 2026-10-31: "when a project is selected we scope stuff"): its registry key, which Go's
/// rows name as `project`, and its Jira project (`scopes.pm.projectKey`), empty when it has none.
/// No scope is the organisation's whole list — the home's NEEDS YOU.
public struct TicketScope: Sendable, Equatable {
    public var project: String
    public var pmKey: String
    public init(project: String, pmKey: String) { self.project = project; self.pmKey = pmKey }

    /// Whether `key` is a ticket of the project's Jira project (INI-142 of INI).
    func holdsKey(_ key: String) -> Bool {
        !pmKey.isEmpty && key.uppercased().hasPrefix(pmKey.uppercased() + "-")
    }
}

/// The read held to `scope`: a ticket is the project's when its key is in the project's Jira project
/// or any of its branches or PRs is on one of the project's repos — then every row of it stays; a
/// PR with no ticket by its own repo. `count` is the kept Waiting on you rows' items. Nil scope: as read.
public func ticketScoped(_ s: InFlightState?, to scope: TicketScope?) -> InFlightState? {
    guard let s, let scope else { return s }
    let all = s.waitingOnYou + s.inFlight
    let keys = Set(all.filter { !$0.key.isEmpty && ($0.project == scope.project || scope.holdsKey($0.key)) }.map(\.key))
    func kept(_ r: InFlightRowState) -> Bool { r.key.isEmpty ? r.project == scope.project : keys.contains(r.key) }
    let waiting = s.waitingOnYou.filter(kept)
    return InFlightState(waitingOnYou: waiting, inFlight: s.inFlight.filter(kept), partial: s.partial,
                         count: waiting.reduce(0) { $0 + $1.count })
}

/// The project's Ticket tab with nothing to show and no Jira project set: the one plain line it
/// reads, beside a way to set it in Settings. Nil otherwise.
public func ticketScopeEmptyLine(_ s: InFlightState?, scope: TicketScope?) -> String? {
    guard let s, let scope, scope.pmKey.isEmpty, s.waitingOnYou.isEmpty, s.inFlight.isEmpty else { return nil }
    return "No Jira project is set for this project"
}
