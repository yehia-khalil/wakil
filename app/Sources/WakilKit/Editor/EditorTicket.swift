import Foundation

// The Ticket view's values and pure decisions (Ticket view, piece 2 of Ticket work). The values
// mirror `wakil-ticket`'s camelCase output (`cmd/wakil-ticket/branch.go`); every list Go writes is
// an array, and a field Go leaves out decodes as empty. The store that holds them is
// `EditorTicketStore`; the actions are `EditorTicketActions.swift`.

private extension KeyedDecodingContainer {
    func text(_ key: Key) -> String { ((try? decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
    func flag(_ key: Key) -> Bool { ((try? decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false }
    func number(_ key: Key) -> Int { ((try? decodeIfPresent(Int.self, forKey: key)) ?? nil) ?? 0 }
    func list<T: Decodable>(_ key: Key) -> [T] { ((try? decodeIfPresent([T].self, forKey: key)) ?? nil) ?? [] }
}

/// A source that could not be read, and why, whole (Rule 8). `source` is `github`, `jira` or `git`.
public struct SourceNoteState: Sendable, Equatable, Codable {
    public var source: String
    public var message: String
    public init(source: String, message: String) { self.source = source; self.message = message }
}

/// One line of a ticket record's list, or its `next`. `by` is `operator`, `agent` or `wakil`.
public struct TicketLineState: Sendable, Equatable, Codable {
    public var id, text, why, how, who, what, state, by, conversation, at, edited: String

    public init(id: String = "", text: String = "", why: String = "", how: String = "", who: String = "",
                what: String = "", state: String = "", by: String = "", conversation: String = "",
                at: String = "", edited: String = "") {
        self.id = id; self.text = text; self.why = why; self.how = how; self.who = who; self.what = what
        self.state = state; self.by = by; self.conversation = conversation; self.at = at; self.edited = edited
    }

    private enum CodingKeys: String, CodingKey { case id, text, why, how, who, what, state, by, conversation, at, edited }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.text(.id), text: c.text(.text), why: c.text(.why), how: c.text(.how), who: c.text(.who),
                  what: c.text(.what), state: c.text(.state), by: c.text(.by), conversation: c.text(.conversation),
                  at: c.text(.at), edited: c.text(.edited))
    }
}

/// What Wakil last read of the ticket from the PM tool.
public struct TicketSeenState: Sendable, Equatable, Codable {
    public var title, status, assignee, url, at: String

    public init(title: String = "", status: String = "", assignee: String = "", url: String = "", at: String = "") {
        self.title = title; self.status = status; self.assignee = assignee; self.url = url; self.at = at
    }

    private enum CodingKeys: String, CodingKey { case title, status, assignee, url, at }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: c.text(.title), status: c.text(.status), assignee: c.text(.assignee), url: c.text(.url),
                  at: c.text(.at))
    }
}

/// A ticket's record (spec, *The ticket record*): `next` and the five lists, and the hand-offs Wakil
/// wrote (`handoffs`, ticket noticing). Its `branches` and `prs` are Wakil's cache of reads and are
/// not mirrored here.
public struct TicketRecordState: Sendable, Equatable, Codable {
    public var key: String
    public var seen: TicketSeenState
    public var next: TicketLineState?
    public var decisions, notDone, waitingOn, verified, rulings: [TicketLineState]
    public var handoffs: [TicketHandOffEntryState]

    public init(key: String, seen: TicketSeenState = TicketSeenState(), next: TicketLineState? = nil,
                decisions: [TicketLineState] = [], notDone: [TicketLineState] = [], waitingOn: [TicketLineState] = [],
                verified: [TicketLineState] = [], rulings: [TicketLineState] = [], handoffs: [TicketHandOffEntryState] = []) {
        self.key = key; self.seen = seen; self.next = next; self.decisions = decisions; self.notDone = notDone
        self.waitingOn = waitingOn; self.verified = verified; self.rulings = rulings; self.handoffs = handoffs
    }

    private enum CodingKeys: String, CodingKey { case key, seen, next, decisions, notDone, waitingOn, verified, rulings, handoffs }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: c.text(.key), seen: ((try? c.decodeIfPresent(TicketSeenState.self, forKey: .seen)) ?? nil) ?? TicketSeenState(),
                  next: (try? c.decodeIfPresent(TicketLineState.self, forKey: .next)) ?? nil,
                  decisions: c.list(.decisions), notDone: c.list(.notDone), waitingOn: c.list(.waitingOn),
                  verified: c.list(.verified), rulings: c.list(.rulings), handoffs: c.list(.handoffs))
    }
}

/// One ticket of a branch. `sources` are where it was found, in linking order (`wakil`, `branch`,
/// `pr`, `trailer`), or `stack`. `error` is why its Jira read failed; the title and status are then
/// the record's last read.
public struct TicketRefState: Sendable, Equatable, Codable {
    public var key, title, status, assignee, url: String
    public var sources: [String]
    public var marked: Bool
    public var record: TicketRecordState
    public var error: String?

    public init(key: String, title: String = "", status: String = "", assignee: String = "", url: String = "",
                sources: [String] = [], marked: Bool = false, record: TicketRecordState? = nil, error: String? = nil) {
        self.key = key; self.title = title; self.status = status; self.assignee = assignee; self.url = url
        self.sources = sources; self.marked = marked; self.record = record ?? TicketRecordState(key: key); self.error = error
    }

    private enum CodingKeys: String, CodingKey { case key, title, status, assignee, url, sources, marked, record, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = c.text(.key)
        self.init(key: key, title: c.text(.title), status: c.text(.status), assignee: c.text(.assignee), url: c.text(.url),
                  sources: c.list(.sources), marked: c.flag(.marked),
                  record: (try? c.decodeIfPresent(TicketRecordState.self, forKey: .record)) ?? nil,
                  error: (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil)
    }
}

/// One comment of a review thread, as GitHub wrote it. Its body is other people's text: it reaches
/// the page as data and is set as text, never as HTML.
public struct ReviewCommentState: Sendable, Equatable, Codable {
    public var author, body, createdAt: String
    public init(author: String, body: String, createdAt: String) { self.author = author; self.body = body; self.createdAt = createdAt }
}

/// A review thread, with its pull request's `number`, `headSHA`, `repo` and the `root` it was read
/// from — filled in by the read (`TicketBranchState`), not by Go — so a thread alone says where to
/// reply and which commit its line is on.
public struct ReviewThreadState: Sendable, Equatable, Codable {
    public var id, path: String
    public var line: Int
    public var outdated, resolved: Bool
    public var comments: [ReviewCommentState]
    public var resolvedBy: String?
    public var number: Int
    public var headSHA, repo, root: String

    public init(id: String, path: String, line: Int, outdated: Bool = false, resolved: Bool = false,
                comments: [ReviewCommentState] = [], resolvedBy: String? = nil, number: Int = 0,
                headSHA: String = "", repo: String = "", root: String = "") {
        self.id = id; self.path = path; self.line = line; self.outdated = outdated; self.resolved = resolved
        self.comments = comments; self.resolvedBy = resolvedBy; self.number = number; self.headSHA = headSHA
        self.repo = repo; self.root = root
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, line, outdated, resolved, comments, resolvedBy, number, headSHA, repo, root
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.text(.id), path: c.text(.path), line: c.number(.line), outdated: c.flag(.outdated),
                  resolved: c.flag(.resolved), comments: c.list(.comments),
                  resolvedBy: (try? c.decodeIfPresent(String.self, forKey: .resolvedBy)) ?? nil,
                  number: c.number(.number), headSHA: c.text(.headSHA), repo: c.text(.repo), root: c.text(.root))
    }
}

/// One CI check of a pull request's last commit.
public struct TicketCheckState: Sendable, Equatable, Codable {
    public var name, state: String
    public var url: String?
    public init(name: String, state: String, url: String? = nil) { self.name = name; self.state = state; self.url = url }
}

/// The pull request this branch's PR is based on, one step down the stack.
public struct PullRequestSummaryState: Sendable, Equatable, Codable {
    public var number: Int
    public var title, url, state, head, base, author: String
    public init(number: Int, title: String = "", url: String = "", state: String = "", head: String = "",
                base: String = "", author: String = "") {
        self.number = number; self.title = title; self.url = url; self.state = state; self.head = head
        self.base = base; self.author = author
    }
}

public struct PullRequestState: Sendable, Equatable, Codable {
    public var number: Int
    public var title, body, url, state, head, base, headSHA, author: String
    public var checks: [TicketCheckState]
    public var threads: [ReviewThreadState]
    public var requestedReviewers: [String]
    public var parent: PullRequestSummaryState?

    public init(number: Int, title: String = "", body: String = "", url: String = "", state: String = "open",
                head: String = "", base: String = "", headSHA: String = "", author: String = "",
                checks: [TicketCheckState] = [], threads: [ReviewThreadState] = [], requestedReviewers: [String] = [],
                parent: PullRequestSummaryState? = nil) {
        self.number = number; self.title = title; self.body = body; self.url = url; self.state = state
        self.head = head; self.base = base; self.headSHA = headSHA; self.author = author; self.checks = checks
        self.threads = threads; self.requestedReviewers = requestedReviewers; self.parent = parent
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, body, url, state, head, base, headSHA, author, checks, threads, requestedReviewers, parent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(number: c.number(.number), title: c.text(.title), body: c.text(.body), url: c.text(.url),
                  state: c.text(.state), head: c.text(.head), base: c.text(.base), headSHA: c.text(.headSHA),
                  author: c.text(.author), checks: c.list(.checks), threads: c.list(.threads),
                  requestedReviewers: c.list(.requestedReviewers),
                  parent: (try? c.decodeIfPresent(PullRequestSummaryState.self, forKey: .parent)) ?? nil)
    }
}

/// One root's branch as `ticket_branch` read it. `repo` is `<host>/<owner>/<repo>`, empty without a
/// readable remote. Decoding stamps each thread with its PR and the root.
public struct TicketBranchState: Sendable, Equatable, Codable {
    public var root, repo, branch, viewer: String
    public var longLived: Bool
    public var tickets: [TicketRefState]
    public var looked: [String]
    public var linked: Bool
    public var prs, basePRs: [PullRequestState]
    public var stack: [Int]
    public var partial: [SourceNoteState]

    public init(root: String, repo: String = "", branch: String = "", viewer: String = "", longLived: Bool = false,
                tickets: [TicketRefState] = [], looked: [String] = [], linked: Bool = false,
                prs: [PullRequestState] = [], basePRs: [PullRequestState] = [], stack: [Int] = [],
                partial: [SourceNoteState] = []) {
        self.root = root; self.repo = repo; self.branch = branch; self.viewer = viewer; self.longLived = longLived
        self.tickets = tickets; self.looked = looked; self.linked = linked; self.prs = prs; self.basePRs = basePRs
        self.stack = stack; self.partial = partial
        stampThreads()
    }

    private enum CodingKeys: String, CodingKey {
        case root, repo, branch, viewer, longLived, tickets, looked, linked, prs, basePRs, stack, partial
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(root: c.text(.root), repo: c.text(.repo), branch: c.text(.branch), viewer: c.text(.viewer),
                  longLived: c.flag(.longLived), tickets: c.list(.tickets), looked: c.list(.looked),
                  linked: c.flag(.linked), prs: c.list(.prs), basePRs: c.list(.basePRs), stack: c.list(.stack),
                  partial: c.list(.partial))
    }

    /// Each thread carries its PR's number and head commit, and the repo and root it was read from.
    private mutating func stampThreads() {
        for p in prs.indices {
            for t in prs[p].threads.indices {
                prs[p].threads[t].number = prs[p].number
                prs[p].threads[t].headSHA = prs[p].headSHA
                prs[p].threads[t].repo = repo
                prs[p].threads[t].root = root
            }
        }
    }
}

/// One open hand-off of a row's ticket.
public struct HandoffRefState: Sendable, Equatable, Codable {
    public var id, conversation, thread: String
    public init(id: String = "", conversation: String = "", thread: String = "") {
        self.id = id; self.conversation = conversation; self.thread = thread
    }

    private enum CodingKeys: String, CodingKey { case id, conversation, thread }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.text(.id), conversation: c.text(.conversation), thread: c.text(.thread))
    }
}

/// One row of In flight or Waiting on you. `state` is the row's one state in words, composed by Go.
/// A Waiting on you row is one PR, with the numbers behind its words: `threads` (the waiting thread
/// ids), `failing` (failing check names), `review`, `activity` (RFC 3339) and `count` (its items).
/// `key` is empty for a PR with no ticket; `root` and `project` are empty for a repository no project
/// holds, which `url` opens on GitHub.
public struct InFlightRowState: Sendable, Equatable, Codable {
    public var key, title, status, state, root, branch, project, repo, url: String
    public var pr: Int
    public var threads, failing: [String]
    public var review: Bool
    public var activity: String
    public var handoffs: [HandoffRefState]
    public var count: Int
    public init(key: String, title: String = "", status: String = "", state: String = "", root: String = "",
                branch: String = "", pr: Int = 0, project: String = "", repo: String = "", url: String = "",
                threads: [String] = [], failing: [String] = [], review: Bool = false, activity: String = "",
                handoffs: [HandoffRefState] = [], count: Int = 0) {
        self.key = key; self.title = title; self.status = status; self.state = state; self.root = root
        self.branch = branch; self.pr = pr; self.project = project; self.repo = repo; self.url = url
        self.threads = threads; self.failing = failing; self.review = review; self.activity = activity
        self.handoffs = handoffs; self.count = count
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, status, state, root, branch, project, repo, url, pr, threads, failing, review, activity, handoffs, count
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: c.text(.key), title: c.text(.title), status: c.text(.status), state: c.text(.state),
                  root: c.text(.root), branch: c.text(.branch), pr: c.number(.pr), project: c.text(.project),
                  repo: c.text(.repo), url: c.text(.url), threads: c.list(.threads), failing: c.list(.failing),
                  review: c.flag(.review), activity: c.text(.activity), handoffs: c.list(.handoffs), count: c.number(.count))
    }
}

/// `count` is Waiting on you's items: the sum of its rows' counts.
public struct InFlightState: Sendable, Equatable, Codable {
    public var waitingOnYou, inFlight: [InFlightRowState]
    public var partial: [SourceNoteState]
    public var count: Int
    public init(waitingOnYou: [InFlightRowState] = [], inFlight: [InFlightRowState] = [], partial: [SourceNoteState] = [],
                count: Int = 0) {
        self.waitingOnYou = waitingOnYou; self.inFlight = inFlight; self.partial = partial; self.count = count
    }

    private enum CodingKeys: String, CodingKey { case waitingOnYou, inFlight, partial, count }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(waitingOnYou: c.list(.waitingOnYou), inFlight: c.list(.inFlight), partial: c.list(.partial),
                  count: c.number(.count))
    }
}

/// One review thread's reply draft, as the organisation's `tickets/drafts.json` keeps it
/// (`wakilcore.TicketDraft`). `by` is `operator` or `agent`; `replaced` is the operator's text an
/// agent's draft replaced, kept for **Restore yours**. Go's empty strings read as nil.
public struct TicketDraftState: Sendable, Equatable, Codable {
    public var text, by, at: String
    public var conversation, root, branch, replaced: String?

    public init(text: String, by: String, at: String = "", conversation: String? = nil, root: String? = nil,
                branch: String? = nil, replaced: String? = nil) {
        self.text = text; self.by = by; self.at = at
        self.conversation = conversation; self.root = root; self.branch = branch; self.replaced = replaced
    }

    private enum CodingKeys: String, CodingKey { case text, by, at, conversation, root, branch, replaced }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func some(_ k: CodingKeys) -> String? { let v = c.text(k); return v.isEmpty ? nil : v }
        self.init(text: c.text(.text), by: c.text(.by), at: c.text(.at), conversation: some(.conversation),
                  root: some(.root), branch: some(.branch), replaced: some(.replaced))
    }
}

/// `ticket_drafts` and `ticket_draft_write` answer every draft of the organisation, by thread.
struct TicketDraftsState: Decodable {
    var drafts: [String: TicketDraftState]
    private enum CodingKeys: String, CodingKey { case drafts }
    init(from decoder: any Decoder) throws {
        drafts = (try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([String: TicketDraftState].self, forKey: .drafts)) ?? [:]
    }
}

// MARK: - Pure decisions

/// Who wrote a draft, from who dispatched the write: an agent's is `agent`; the operator's and the
/// window's own channel (`.debug`, the e2e driver) are `operator` — a draft has no third author.
public func ticketDraftBy(_ origin: ActionOrigin) -> String { origin == .agent ? "agent" : "operator" }

/// An agent's draft's caption in its box: `Drafted by agent · 1 min ago`; nil for the operator's.
public func ticketDraftCaption(_ d: TicketDraftState, now: Date) -> String? {
    guard d.by == "agent" else { return nil }
    let when = ticketDraftAge(d.at, now: now)
    return when.isEmpty ? "Drafted by agent" : "Drafted by agent · \(when)"
}

/// The line over an agent's draft that replaced the operator's; its last words are **Restore yours**.
public func ticketDraftReplacedLine(_ d: TicketDraftState) -> String? {
    d.replaced == nil ? nil : "Agent replaced your draft · Restore yours"
}

/// How long ago a draft was written, short: `just now`, `1 min ago`, `5 min ago`, else as
/// `editorRelativeAge` says it; empty when `at` is not a time.
func ticketDraftAge(_ at: String, now: Date) -> String {
    guard let date = ISO8601DateFormatter().date(from: at) else { return "" }
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s >= 60, s < 3600 { return "\(s / 60) min ago" }
    return editorRelativeAge(at, now: now)
}

/// Who wrote a record line, from who dispatched the write: never from the caller's params.
public func ticketBy(_ origin: ActionOrigin) -> String {
    switch origin {
    case .ui: "operator"
    case .agent: "agent"
    case .debug: "wakil"
    }
}

/// The root the view follows: the front file's root, else the project's first.
public func ticketFollowedRoot(front: String?, roots: [String]) -> String? {
    if let front, !front.isEmpty { return front }
    return roots.first
}

/// How long a read stays fresh for Wakil becoming the active app (spec, *When it reads*).
public let ticketFreshFor: TimeInterval = 60

/// Whether a read is old enough that Wakil becoming the active app reads again: none yet, or over 60 s.
public func ticketStale(lastRead: Date?, now: Date) -> Bool {
    guard let lastRead else { return true }
    return now.timeIntervalSince(lastRead) > ticketFreshFor
}

/// Who the ticket is waiting on: first from the pull requests — each open PR's requested reviewers,
/// then `you` when a thread on one of your open PRs ends on someone else's word — then the record's
/// own `waitingOn` lines. An exact duplicate is shown once; nothing is ranked.
public func ticketWaitingOn(_ b: TicketBranchState, record: TicketRecordState?) -> [String] {
    var out: [String] = []
    func add(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !out.contains(t) { out.append(t) }
    }
    let open = b.prs.filter { $0.state.lowercased() == "open" }
    for pr in open { pr.requestedReviewers.forEach(add) }
    if !b.viewer.isEmpty, open.contains(where: { pr in
        pr.author == b.viewer && pr.threads.contains { !$0.resolved && ($0.comments.last.map { $0.author != b.viewer } ?? false) }
    }) { add("you") }
    for line in record?.waitingOn ?? [] {
        add(!line.who.isEmpty ? line.who : !line.what.isEmpty ? line.what : line.text)
    }
    return out
}

/// **Next:** the marked ticket's; when it has none, the newest among the others (by when it was
/// written), labelled with that ticket's key. Nil when no ticket has one.
public func ticketNext(_ b: TicketBranchState) -> (text: String, key: String?)? {
    if let marked = b.tickets.first(where: \.marked), let n = marked.record.next, !n.text.isEmpty {
        return (n.text, nil)
    }
    let others = b.tickets.filter { !$0.marked }
        .compactMap { t -> (key: String, line: TicketLineState)? in
            guard let n = t.record.next, !n.text.isEmpty else { return nil }
            return (t.key, n)
        }
    guard let newest = others.max(by: { $0.line.at < $1.line.at }) else { return nil }
    return (newest.line.text, newest.key)
}

/// One kind of the record as its group heading draws it (the calmer column, 2026-10-28): the
/// record's key for the kind, its plural name and how many lines it holds, and a hue only where the
/// kind means something — Not done and Waiting on wait (§5's amber), Verified is done (green).
public struct TicketRecordGroup: Equatable, Sendable {
    public let kind: String
    public let heading: String
    public let count: Int
    public let hue: TicketHue?
}

/// The record's groups in the record's order: each kind that holds a line, plus `including` (the kind
/// + Add is adding a line of) though it holds none yet. Empty, the record says so in words instead.
public func ticketRecordGroups(_ r: TicketRecordState, including: String? = nil) -> [TicketRecordGroup] {
    let kinds: [TicketRecordGroup] = [
        .init(kind: "decisions", heading: "Decisions", count: r.decisions.count, hue: nil),
        .init(kind: "notDone", heading: "Not done", count: r.notDone.count, hue: .amber),
        .init(kind: "waitingOn", heading: "Waiting on", count: r.waitingOn.count, hue: .amber),
        .init(kind: "verified", heading: "Verified", count: r.verified.count, hue: .green),
        .init(kind: "rulings", heading: "Rulings", count: r.rulings.count, hue: nil),
    ]
    return kinds.filter { $0.count > 0 || $0.kind == including }
}

/// The branch's open threads — unresolved and not outdated — in file order, then line order. A
/// thread read twice (a PR and the stack) is counted once.
public func reviewOpenThreads(_ prs: [PullRequestState]) -> [ReviewThreadState] {
    var seen: Set<String> = []
    var out: [ReviewThreadState] = []
    for pr in prs {
        for t in pr.threads where !t.resolved && !t.outdated && seen.insert(t.id).inserted { out.append(t) }
    }
    return out.sorted { ($0.path, $0.line, $0.id) < ($1.path, $1.line, $1.id) }
}

/// The thread `delta` steps from `from`, wrapping both ways. From none (or one no longer open), a
/// step forward lands on the first and a step back on the last.
public func reviewStep(_ threads: [ReviewThreadState], from: String?, delta: Int) -> ReviewThreadState? {
    guard !threads.isEmpty else { return nil }
    let n = threads.count
    let target: Int
    if let from, let i = threads.firstIndex(where: { $0.id == from }) {
        target = i + delta
    } else {
        target = delta > 0 ? delta - 1 : delta
    }
    return threads[((target % n) + n) % n]
}

/// "1 of 5": where the thread stands among the open threads; empty when it is not one of them.
public func reviewPosition(_ threads: [ReviewThreadState], id: String) -> String {
    guard let i = threads.firstIndex(where: { $0.id == id }) else { return "" }
    return "\(i + 1) of \(threads.count)"
}

// MARK: - The view's rows (Task 8): the view draws these and decides nothing

/// Which of the spec's cases the Ticket view shows (*What the operator gets* 1 and 5).
/// `loading` is a read in flight; `unread` is no read and none running — a root the window did not
/// read (not a repository), or a first read cancelled — which ↻ reads.
public enum TicketViewCase: Equatable {
    case ticket, several, noTicket(branch: String), longLived, loading, unread, error(String)
    /// A pull request on a repository no project of the organisation holds: there is no root to
    /// read it in, so the view says so and opens it on GitHub (`url`).
    case outside(url: String)
}

/// What the outside case says.
public let ticketOutsideLine = "Not open in any project of this organisation"

/// The case for a pane's column: a row no project holds is `outside`; a keyless row picked from In
/// flight or the Landing is its own branch's read — reading, failed, or its case (no ticket, as Go
/// found none); else the followed root's (`ticketViewCase(_:shown:failure:reading:)`).
public func ticketViewCase(_ state: EditorTicketViewState, column: EditorColumnState, root: String?) -> TicketViewCase {
    if let key = column.ticketShown, !key.isEmpty {
        let rows = state.inFlight.map { ($0.waitingOnYou + $0.inFlight).filter { $0.key == key } } ?? []
        if let first = rows.first, rows.allSatisfy({ $0.root.isEmpty }) { return .outside(url: first.url) }
        return .ticket
    }
    if let at = column.ticketShownAt {
        if at.root.isEmpty {
            let row = state.inFlight.flatMap { s in
                (s.waitingOnYou + s.inFlight).first { $0.root.isEmpty && $0.pr == at.pr && (at.repo.isEmpty || $0.repo == at.repo) }
            }
            return .outside(url: row?.url ?? (at.repo.isEmpty ? "" : "https://\(at.repo)/pull/\(at.pr)"))
        }
        if let b = state.shownBranches[at.id] { return ticketViewCase(b, shown: nil) }
        if let f = state.shownBranchFailures[at.id], !f.isEmpty { return .error(f) }
        return .loading
    }
    let b = root.flatMap { state.branches[$0] }
    return ticketViewCase(b, shown: nil, failure: root.flatMap { state.failures[$0] },
                          reading: root.map { state.reading.contains($0) } ?? false)
}

/// The case for a root's read. A key picked from In flight (`shown`) overrides the branch. One
/// ticket is the branch's own only when it is marked: a ticket only the stack carries is never the
/// branch's, so it shows the several layout, unmarked. A failed re-read keeps the last read on screen
/// (Rule 8); with no read yet, the failure is the case, and "reading" only while one runs.
public func ticketViewCase(_ b: TicketBranchState?, shown: String?, failure: String? = nil,
                           reading: Bool = false) -> TicketViewCase {
    if let shown, !shown.isEmpty { return .ticket }
    guard let b else {
        if let failure, !failure.isEmpty { return .error(failure) }
        return reading ? .loading : .unread
    }
    if b.longLived { return .longLived }
    if b.tickets.isEmpty { return .noTicket(branch: b.branch) }
    if b.tickets.count == 1, b.tickets[0].marked { return .ticket }
    return .several
}

/// A ticket's source in words, for the several layout.
public func ticketSourceLabel(_ source: String) -> String {
    switch source {
    case "wakil": "linked in Wakil"
    case "branch": "from the branch name"
    case "pr": "from the PR"
    case "trailer": "from a commit trailer"
    case "stack": "from the stack"
    default: source
    }
}

/// Where Wakil looked for a ticket, under "No ticket found": `Looked in the branch name, PR #215's
/// title and body, 4 commits' trailers`. Nil when Go named nowhere.
public func ticketLookedLine(_ looked: [String]) -> String? {
    looked.isEmpty ? nil : "Looked in the " + looked.joined(separator: ", ")
}

/// A pull request's line: `#212  ini-142-login → main      open · checks 7/9 · 1 failing`.
/// Checks show only when it has some: passed of all, then the failing.
public func ticketPRLine(_ pr: PullRequestState) -> String {
    var state = pr.state.isEmpty ? "open" : pr.state.lowercased()
    if !pr.checks.isEmpty {
        let passed = pr.checks.filter { $0.state == "success" }.count
        state += " · checks \(passed)/\(pr.checks.count)"
        let failing = ticketFailingChecks(pr).count
        if failing > 0 { state += " · \(failing) failing" }
    }
    return "#\(pr.number)  \(pr.head) → \(pr.base)      \(state)"
}

/// The checks the PR block lists, each with its `details ↗`.
public func ticketFailingChecks(_ pr: PullRequestState) -> [TicketCheckState] { pr.checks.filter { $0.state == "failure" } }

/// The threads a PR block lists: every unresolved one, outdated too (its row says so), in file
/// order, then line order.
public func ticketColumnThreads(_ pr: PullRequestState) -> [ReviewThreadState] {
    pr.threads.filter { !$0.resolved }.sorted { ($0.path, $0.line, $0.id) < ($1.path, $1.line, $1.id) }
}

/// The longest first words of a thread's row.
public let ticketThreadWordsLimit = 40

/// A thread's row: where it is, the first comment's first words (at most 40 characters, cut at a
/// word and ended with "…"), and its replies counted — or `outdated` for a thread GitHub calls so.
///
/// `elsewhere` names the project of the organisation the thread's branch is in, when that is not the
/// project on screen: the row opens nothing there (one place is on screen, Invariant 5) and says
/// `in project umbrella`.
public func ticketThreadRow(_ t: ReviewThreadState, elsewhere: String? = nil)
    -> (place: String, words: String, replies: String?, elsewhere: String?) {
    let place = t.line > 0 ? "\(t.path):\(t.line)" : t.path
    let body = (t.comments.first?.body ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    var words = body
    if body.count > ticketThreadWordsLimit {
        let head = String(body.prefix(ticketThreadWordsLimit + 1))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? String(body.prefix(ticketThreadWordsLimit))
        words = cut + "…"
    }
    let n = max(0, t.comments.count - 1)
    let replies: String? = t.outdated ? "outdated" : n == 0 ? nil : n == 1 ? "1 reply" : "\(n) replies"
    return (place, words, replies, elsewhere.map { "in project \($0)" })
}

/// The project an In flight row's branch is in, when it is not the screen's (its root is none of
/// `roots`): its project's name, else its root's last part; nil for the screen's own or a row no
/// project holds.
public func ticketElsewhere(_ row: InFlightRowState?, roots: [String]) -> String? {
    guard let row, !row.root.isEmpty, !roots.contains(row.root) else { return nil }
    return row.project.isEmpty ? (row.root as NSString).lastPathComponent : row.project
}

/// What stands where a row's key goes: the key, else its PR and repository's last part
/// (`#215 · api`) — a keyless row is never drawn with an empty key.
public func ticketRowName(key: String, repo: String, pr: Int) -> String {
    if !key.isEmpty { return key }
    let name = repo.split(separator: "/").last.map(String.init) ?? repo
    return name.isEmpty ? "#\(pr)" : "#\(pr) · \(name)"
}

/// `ticketRowName` for an In flight or Waiting on you row.
public func ticketInFlightRowLabel(_ r: InFlightRowState) -> String { ticketRowName(key: r.key, repo: r.repo, pr: r.pr) }

// MARK: - The column's pills (design A, "cards with state")

/// A pill's hue, by §5's reserved meanings only: green done or healthy, amber waiting or pending,
/// red failed, neutral otherwise. Violet is where the operator is, never a status.
public enum TicketHue: Equatable, Sendable { case green, amber, red, neutral }

/// A PM status's hue: a done-like status green, a waiting or not-started one amber, any other —
/// "In Progress" among them — neutral. Matched on the words, case and spacing aside.
public func ticketStatusHue(_ status: String) -> TicketHue {
    let s = status.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
    let done = ["done", "closed", "resolved", "complete", "completed", "merged", "released", "shipped", "deployed", "fixed"]
    let waiting = ["backlog", "to do", "todo", "open", "new", "pending", "waiting", "blocked", "on hold", "in review",
                   "review", "ready for review", "needs review", "awaiting review", "selected for development"]
    if done.contains(s) { return .green }
    if waiting.contains(s) || s.hasPrefix("waiting") || s.hasPrefix("awaiting") || s.hasPrefix("blocked") { return .amber }
    return .neutral
}

/// A pull request's state pill: its word and hue — open green, blocked amber, merged and closed
/// (and anything else) neutral.
public func ticketPRStatePill(_ pr: PullRequestState) -> (label: String, hue: TicketHue) {
    let state = pr.state.isEmpty ? "open" : pr.state.lowercased()
    switch state {
    case "open": return (state, .green)
    case "blocked": return (state, .amber)
    default: return (state, .neutral)
    }
}

/// A pull request's checks pill, nil with no checks: `checks 7/9`, red while one fails, green when
/// all passed, amber while any is still pending.
public func ticketChecksPill(_ pr: PullRequestState) -> (label: String, hue: TicketHue)? {
    guard !pr.checks.isEmpty else { return nil }
    let passed = pr.checks.filter { $0.state == "success" }.count
    let label = "checks \(passed)/\(pr.checks.count)"
    if !ticketFailingChecks(pr).isEmpty { return (label, .red) }
    return (label, passed == pr.checks.count ? .green : .amber)
}

/// The threads the column lists across the branch's pull requests — each PR's
/// `ticketColumnThreads`, a thread read twice (a PR and the stack) once.
public func ticketBranchThreads(_ prs: [PullRequestState]) -> [ReviewThreadState] {
    var seen: Set<String> = []
    return prs.flatMap { ticketColumnThreads($0) }.filter { seen.insert($0.id).inserted }
}

/// The open threads that wait on the viewer: on their own open PRs, ending on someone else's word
/// (the threads behind `ticketWaitingOn`'s `you`).
public func ticketThreadsWaitingOnViewer(_ b: TicketBranchState) -> Int {
    guard !b.viewer.isEmpty else { return 0 }
    var seen: Set<String> = []
    return b.prs.filter { $0.state.lowercased() == "open" && $0.author == b.viewer }.flatMap(\.threads).filter { t in
        !t.resolved && (t.comments.last.map { $0.author != b.viewer } ?? false) && seen.insert(t.id).inserted
    }.count
}

/// The header's line after the status pill: `waiting on reviewer, you · 2 threads` — the thread
/// count only when it waits on you and some do. Nil when it waits on nobody.
public func ticketWaitingLine(_ waiting: [String], threads: Int) -> String? {
    guard !waiting.isEmpty else { return nil }
    var line = "waiting on " + waiting.joined(separator: ", ")
    if waiting.contains("you"), threads > 0 { line += " · \(threads) thread" + (threads == 1 ? "" : "s") }
    return line
}

/// The sources that could not be read, each message whole (Rule 8), an exact repeat once.
public func ticketPartialLine(_ notes: [SourceNoteState]) -> [String] {
    var out: [String] = []
    for n in notes {
        let m = n.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty, !out.contains(m) { out.append(m) }
    }
    return out
}

/// A branch's lines for what could not be read: its sources', then each ticket's own error (a key
/// Jira does not know, a record not updated) named by its key, a message already said once.
public func ticketPartialLines(_ b: TicketBranchState) -> [String] {
    var out = ticketPartialLine(b.partial)
    for t in b.tickets {
        guard let e = t.error?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty, !out.contains(e) else { continue }
        out.append("\(t.key): \(e)")
    }
    return out
}

/// Who wrote a record line, as its row names it: `you`, `agent`, `Wakil`.
public func ticketLineWho(_ l: TicketLineState) -> String {
    switch l.by {
    case "operator": "you"
    case "wakil": "Wakil"
    default: l.by
    }
}

/// Who wrote a record line and when: `you · 2 hours ago`, `agent · …`, `Wakil`, and
/// `edited by agent` when an agent changed the operator's line.
public func ticketLineCaption(_ l: TicketLineState, now: Date = Date()) -> String {
    var parts = [ticketLineWho(l)].filter { !$0.isEmpty }
    let when = editorRelativeAge(l.at, now: now)
    if !when.isEmpty { parts.append(when) }
    if !l.edited.isEmpty { parts.append("edited by \(l.edited)") }
    return parts.joined(separator: " · ")
}

/// What `ticket_link` answered, as the line under **Link a ticket…**: a key Jira cannot find is
/// kept and says so (Rule 7), with Jira's error whole (Rule 8); any other message whole; nothing for
/// a link Jira knows.
public func ticketLinkNote(_ reply: JSONValue) -> String? {
    guard case .object(let o) = reply else { return nil }
    if o["notFound"] == .bool(true), case .string(let key)? = o["key"] {
        // Go's error, whole (Rule 8), without Go's own words for what this line already says.
        var detail = ""
        if case .string(let m)? = o["message"] {
            let goLine = "\(key) was not found in Jira; the link is kept."
            detail = (m.hasPrefix(goLine) ? String(m.dropFirst(goLine.count)) : m).trimmingCharacters(in: .whitespaces)
        }
        return "\(key) was not found in Jira; kept as typed." + (detail.isEmpty ? "" : " " + detail)
    }
    if case .string(let m)? = o["message"], !m.isEmpty { return m }
    return nil
}

/// The ticket **Next:** shows and writes: `ticketNext`'s, labelled when it is another ticket's;
/// with none, the marked ticket's with no text yet, else the first's, labelled (it is not the
/// branch's own). Nil with no ticket.
public func ticketNextTarget(_ b: TicketBranchState) -> (key: String, text: String, labelled: Bool)? {
    if let n = ticketNext(b) {
        if let key = n.key { return (key, n.text, true) }
        if let marked = b.tickets.first(where: \.marked) { return (marked.key, n.text, false) }
    }
    guard let t = b.tickets.first(where: \.marked) ?? b.tickets.first else { return nil }
    return (t.key, t.record.next?.text ?? "", !t.marked)
}

/// The Ticket view's state for every editor pane, mirrored from `EditorTicketStore`: each root's
/// last read, which roots are reading, each failure whole, In flight, and the records of tickets
/// shown from it (`ticket_show`).
public struct EditorTicketViewState: Sendable, Equatable {
    public var roots: [String]
    public var branches: [String: TicketBranchState]
    public var reading: Set<String>
    public var failures: [String: String]
    public var inFlight: InFlightState?
    public var records: [String: TicketRecordState]
    /// Why a shown ticket's record could not be read, whole, by key.
    public var recordFailures: [String: String]
    /// The branch of a ticket picked from In flight, by key, and why one could not be read.
    public var shownBranches: [String: TicketBranchState]
    public var shownBranchFailures: [String: String]
    /// A shown ticket's other branches — any root or repository — by key, and why one could not be
    /// read, whole (walk 2026-10-29: the Pull requests section is the ticket's).
    public var ticketBranches: [String: [TicketBranchState]]
    public var ticketBranchFailures: [String: [String]]
    /// Why the organisation's reply drafts could not be read, whole; nil after a load that came back.
    public var draftsFailure: String?
    /// The Hand to agent popover, while it is open (ticket noticing, Task 10).
    public var handoff: TicketHandOffState?
    /// The live handed conversations' states, by conversation id, for the record's hand-off entries:
    /// the window's (`WindowModel.ticketHandOffLive`), set where the view is drawn.
    public var handOffLive: [String: TicketHandOffLive]
    /// The live handed conversations with what they were handed (`WindowModel.ticketLiveHandOffs`),
    /// set where the view is drawn: the header's **With agent** reads them.
    public var liveHandOffs: [TicketLiveHandOff]

    public init(roots: [String] = [], branches: [String: TicketBranchState] = [:], reading: Set<String> = [],
                failures: [String: String] = [:], inFlight: InFlightState? = nil, records: [String: TicketRecordState] = [:],
                recordFailures: [String: String] = [:], shownBranches: [String: TicketBranchState] = [:],
                shownBranchFailures: [String: String] = [:], ticketBranches: [String: [TicketBranchState]] = [:],
                ticketBranchFailures: [String: [String]] = [:], draftsFailure: String? = nil,
                handoff: TicketHandOffState? = nil, handOffLive: [String: TicketHandOffLive] = [:],
                liveHandOffs: [TicketLiveHandOff] = []) {
        self.roots = roots; self.branches = branches; self.reading = reading; self.failures = failures
        self.inFlight = inFlight; self.records = records; self.recordFailures = recordFailures
        self.shownBranches = shownBranches; self.shownBranchFailures = shownBranchFailures
        self.ticketBranches = ticketBranches; self.ticketBranchFailures = ticketBranchFailures
        self.draftsFailure = draftsFailure; self.handoff = handoff; self.handOffLive = handOffLive
        self.liveHandOffs = liveHandOffs
    }
    public static let empty = EditorTicketViewState()

    /// The In flight or Waiting on you row of `key`, for a ticket shown from it: the one at `at`'s
    /// root and branch when given (two rows can carry one key), else the first.
    public func inFlightRow(_ key: String, at: TicketShownAt? = nil) -> InFlightRowState? {
        guard let s = inFlight else { return nil }
        let rows = (s.waitingOnYou + s.inFlight).filter { $0.key == key }
        guard let at else { return rows.first }
        return rows.first { $0.root == at.root && $0.branch == at.branch }
    }
}

/// What a ticket shown from In flight draws for its record: the record read for it (`ticket_record`),
/// else why that read failed, whole (Rule 8) — never the branch read's stand-in for a record it
/// could not read either — else the branch's own record of it; `none` before anything is read.
public enum TicketShownRecord: Equatable { case record(TicketRecordState), failure(String), none }

public func ticketShownRecord(_ state: EditorTicketViewState, key: String, ref: TicketRefState?) -> TicketShownRecord {
    if let r = state.records[key] { return .record(r) }
    if let f = state.recordFailures[key], !f.isEmpty { return .failure(f) }
    if let r = ref?.record { return .record(r) }
    return .none
}

/// An In flight or Waiting on you row's name, for its accessibility identifier: `<key>:<root>:<branch>`,
/// the root by its last component. A key alone is not one row — two branches can carry one ticket —
/// and the root's last component, unlike its path, is the same on every run.
/// In flight without what Waiting on you already lists: a ticket that needs the operator is drawn
/// once, under Waiting on you, not again under In flight (walk, 2026-10-28). A row is the same one
/// when its key, root, branch, repository and PR all match.
public func ticketInFlightNotWaiting(_ s: InFlightState) -> [InFlightRowState] {
    func same(_ a: InFlightRowState, _ b: InFlightRowState) -> Bool {
        a.key == b.key && a.root == b.root && a.branch == b.branch && a.repo == b.repo && a.pr == b.pr
    }
    return s.inFlight.filter { row in !s.waitingOnYou.contains { same($0, row) } }
}

public func ticketInFlightRowName(_ r: InFlightRowState) -> String {
    "\(r.key):\((r.root as NSString).lastPathComponent):\(r.branch)"
}

/// The root a pane's Ticket view follows from its front tab: the tab's root, else the project's first.
public func ticketFollowedRoot(tab: EditorTab?, roots: [String]) -> String? {
    let front: String? = switch tab?.subject {
    case .file(_, let root)?: root
    case .diff(let root, _, _, _)?: root
    default: nil
    }
    return ticketFollowedRoot(front: front, roots: roots)
}

/// What a Ticket view field commits: once per edit. Enter commits, and leaving the field then would
/// commit the same text again before the record echoes it, writing a second entry into the
/// append-only log (or a second link). The text last sent is kept until the operator types again.
public struct TicketFieldCommits: Sendable, Equatable {
    private var sent: String?
    public init() {}

    /// The operator typed: the next Enter or leave is a new edit.
    public mutating func edited() { sent = nil }

    /// The text to commit for `text` against the field's shown `value`, nil when nothing is new.
    public mutating func commit(_ text: String, value: String) -> String? {
        let now = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard now != (sent ?? value) else { return nil }
        sent = now
        return now
    }
}

/// One repository's pull requests in a ticket's Pull requests section (walk 2026-10-29): the
/// repository's key and its name as drawn (`api` of `github.com/initech/api`).
public struct TicketPRGroup: Sendable, Equatable {
    public let repo: String
    public let name: String
    public let prs: [PullRequestState]
}

/// A ticket's pull requests by repository: the shown branch's repository first, then each other in the
/// order its branches come; a PR two branches or roots both read (one repository, one number) once.
public func ticketPRGroups(primary: TicketBranchState?, others: [TicketBranchState]) -> [TicketPRGroup] {
    var order: [String] = []
    var prs: [String: [PullRequestState]] = [:]
    for b in [primary].compactMap { $0 } + others {
        if prs[b.repo] == nil { order.append(b.repo); prs[b.repo] = [] }
        for pr in b.prs where !(prs[b.repo] ?? []).contains(where: { $0.number == pr.number }) {
            prs[b.repo, default: []].append(pr)
        }
    }
    return order.compactMap { repo in
        guard let list = prs[repo], !list.isEmpty || repo == primary?.repo else { return nil }
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return TicketPRGroup(repo: repo, name: name.isEmpty ? repo : name, prs: list)
    }
}

/// The shown branch with every pull request of the ticket in it (`ticketPRGroups`' order): what the
/// section's waiting-on line and threads count over.
public func ticketMergedBranch(primary: TicketBranchState, others: [TicketBranchState]) -> TicketBranchState {
    var merged = primary
    merged.prs = ticketPRGroups(primary: primary, others: others).flatMap(\.prs)
    return merged
}
