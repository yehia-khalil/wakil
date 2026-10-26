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

/// A ticket's record (spec, *The ticket record*): `next` and the five lists. Its `branches` and `prs`
/// are Wakil's cache of reads and are not mirrored here.
public struct TicketRecordState: Sendable, Equatable, Codable {
    public var key: String
    public var seen: TicketSeenState
    public var next: TicketLineState?
    public var decisions, notDone, waitingOn, verified, rulings: [TicketLineState]

    public init(key: String, seen: TicketSeenState = TicketSeenState(), next: TicketLineState? = nil,
                decisions: [TicketLineState] = [], notDone: [TicketLineState] = [], waitingOn: [TicketLineState] = [],
                verified: [TicketLineState] = [], rulings: [TicketLineState] = []) {
        self.key = key; self.seen = seen; self.next = next; self.decisions = decisions; self.notDone = notDone
        self.waitingOn = waitingOn; self.verified = verified; self.rulings = rulings
    }

    private enum CodingKeys: String, CodingKey { case key, seen, next, decisions, notDone, waitingOn, verified, rulings }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: c.text(.key), seen: ((try? c.decodeIfPresent(TicketSeenState.self, forKey: .seen)) ?? nil) ?? TicketSeenState(),
                  next: (try? c.decodeIfPresent(TicketLineState.self, forKey: .next)) ?? nil,
                  decisions: c.list(.decisions), notDone: c.list(.notDone), waitingOn: c.list(.waitingOn),
                  verified: c.list(.verified), rulings: c.list(.rulings))
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

/// One row of In flight or Waiting on you. `state` is the row's one state in words, composed by Go.
public struct InFlightRowState: Sendable, Equatable, Codable {
    public var key, title, status, state, root, branch: String
    public var pr: Int
    public init(key: String, title: String = "", status: String = "", state: String = "", root: String = "",
                branch: String = "", pr: Int = 0) {
        self.key = key; self.title = title; self.status = status; self.state = state; self.root = root
        self.branch = branch; self.pr = pr
    }
}

public struct InFlightState: Sendable, Equatable, Codable {
    public var waitingOnYou, inFlight: [InFlightRowState]
    public var partial: [SourceNoteState]
    public init(waitingOnYou: [InFlightRowState] = [], inFlight: [InFlightRowState] = [], partial: [SourceNoteState] = []) {
        self.waitingOnYou = waitingOnYou; self.inFlight = inFlight; self.partial = partial
    }
}

// MARK: - Pure decisions

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

/// The folded section's one line.
public func ticketFoldLine(_ r: TicketRecordState) -> String {
    "Decisions \(r.decisions.count) · Not done \(r.notDone.count) · Verified \(r.verified.count) ▸"
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
