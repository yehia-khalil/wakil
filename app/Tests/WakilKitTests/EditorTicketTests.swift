import Foundation
import Testing
@testable import WakilKit

/// A wakil-ticket that answers from a dictionary and records every call. `slowBranch` parks
/// `ticket_branch` until `release()`, latched; `hangBranch` sleeps until cancelled.
actor FakeTicket: ToolCaller {
    var replies: [String: JSONValue] = [:]       // tool -> structuredContent
    var branchReplies: [String: JSONValue] = [:] // "<root>:<branch>" -> ticket_branch's structuredContent
    var branchErrors: [String: String] = [:]     // "<root>:<branch>" -> ticket_branch's isError text
    var errors: [String: String] = [:]           // tool -> isError text
    var calls: [(name: String, args: JSONValue)] = []
    var slowBranch = false
    var hangBranch = false
    var slowReply = false
    var slowDrafts = false
    var slowInFlight = false
    /// The organisation's drafts.json as `ticket_draft_write` keeps it, by thread, unless a reply is set.
    var drafts: [String: JSONValue] = [:]
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func set(_ tool: String, _ content: JSONValue) { replies[tool] = content }
    /// `ticket_branch`'s answer for one root and branch, over `set`'s.
    func setBranch(root: String, branch: String, _ content: JSONValue) { branchReplies["\(root):\(branch)"] = content }
    func failBranch(root: String, branch: String, _ text: String) { branchErrors["\(root):\(branch)"] = text }
    func fail(_ tool: String, _ text: String?) { errors[tool] = text }
    func setSlowBranch(_ on: Bool) { slowBranch = on; released = false }
    func setHangBranch(_ on: Bool) { hangBranch = on }
    func setSlowReply(_ on: Bool) { slowReply = on; released = false }
    func setSlowDrafts(_ on: Bool) { slowDrafts = on; released = false }
    func setSlowInFlight(_ on: Bool) { slowInFlight = on; released = false }
    /// Puts a draft in the file, as another window or a quit-and-relaunch left it.
    func seedDraft(_ thread: String, text: String, by: String, conversation: String = "", replaced: String = "",
                   at: String = "2026-10-28T10:00:00Z") {
        drafts[thread] = .object(["text": .string(text), "by": .string(by), "conversation": .string(conversation),
                                  "root": .string(""), "branch": .string(""), "at": .string(at),
                                  "replaced": .string(replaced)])
    }
    func clearDrafts() { drafts = [:] }
    func release() { released = true; parked.forEach { $0.resume() }; parked = [] }
    private func park(_ c: CheckedContinuation<Void, Never>) { if released { c.resume() } else { parked.append(c) } }
    func count(_ tool: String) -> Int { calls.filter { $0.name == tool }.count }
    func args(_ tool: String) -> [String: JSONValue]? {
        guard case .object(let o)? = calls.last(where: { $0.name == tool })?.args else { return nil }
        return o
    }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        if name == "ticket_branch", hangBranch { try await Task.sleep(for: .seconds(60)) }
        if (name == "ticket_branch" && slowBranch) || (name == "review_reply" && slowReply)
            || (name == "ticket_drafts" && slowDrafts) || (name == "ticket_in_flight" && slowInFlight) {
            await withCheckedContinuation { c in Task { self.park(c) } }
        }
        var at = ""
        if name == "ticket_branch", case .object(let a) = arguments, case .string(let root)? = a["root"],
           case .string(let branch)? = a["branch"] { at = "\(root):\(branch)" }
        if let e = branchErrors[at] ?? errors[name] {
            return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(e)])])])
        }
        if replies[name] == nil, name == "ticket_draft_write" { writeDraft(arguments) }
        if replies[name] == nil, name == "ticket_drafts" || name == "ticket_draft_write" {
            return .object(["structuredContent": .object(["drafts": .object(drafts)])])
        }
        return .object(["structuredContent": branchReplies[at] ?? replies[name] ?? .object([:])])
    }

    /// `WriteTicketDraft`'s rule (internal/wakilcore/ticketdrafts.go): no text removes; an agent's draft
    /// over the operator's keeps the operator's text in `replaced`, an operator's clears it.
    private func writeDraft(_ arguments: JSONValue) {
        guard case .object(let a) = arguments, case .string(let thread)? = a["thread"] else { return }
        func text(_ o: [String: JSONValue]?, _ k: String) -> String { if case .string(let s)? = o?[k] { s } else { "" } }
        let body = text(a, "text"), by = text(a, "by")
        guard !body.isEmpty else { drafts[thread] = nil; return }
        var replaced = ""
        if by == "agent", case .object(let old)? = drafts[thread] {
            replaced = text(old, "by") == "operator" ? text(old, "text") : text(old, "replaced")
        }
        drafts[thread] = .object(["text": .string(body), "by": .string(by), "conversation": .string(text(a, "conversation")),
                                  "root": .string(text(a, "root")), "branch": .string(text(a, "branch")),
                                  "at": .string(ISO8601DateFormatter().string(from: Date())), "replaced": .string(replaced)])
    }
}

/// `ticket_branch`'s answer for `ini-142-login` on `/p/api`: INI-142 marked, PR #212 with two open
/// threads, one outdated and one resolved.
func ticketBranchJSON(root: String = "/p/api", branch: String = "ini-142-login", repo: String = "github.com/initech/api",
                      pr: Int = 212, threads: String = "T") -> JSONValue {
    let prefix = threads
    func thread(_ id: String, _ path: String, _ line: Int, outdated: Bool = false, resolved: Bool = false) -> JSONValue {
        .object(["id": .string(prefix + id.dropFirst()), "path": .string(path), "line": .integer(Int64(line)),
                 "outdated": .bool(outdated), "resolved": .bool(resolved),
                 "comments": .array([.object(["author": .string("reviewer"), "body": .string("Nit: the error should name the host"),
                                              "createdAt": .string("2026-10-26T09:00:00Z")])])])
    }
    return .object([
        "root": .string(root), "repo": .string(repo), "branch": .string(branch),
        "viewer": .string("me"), "longLived": .bool(false),
        "tickets": .array([.object(["key": .string("INI-142"), "title": .string("Sign-in keeps the last organization"),
                                    "status": .string("In Progress"), "assignee": .string("me"), "url": .string(""),
                                    "sources": .array([.string("branch")]), "marked": .bool(true),
                                    "record": .object(["key": .string("INI-142"), "seen": .object([:]),
                                                       "branches": .array([]), "prs": .array([]),
                                                       "decisions": .array([]), "notDone": .array([]), "waitingOn": .array([]),
                                                       "verified": .array([]), "rulings": .array([])])])]),
        "looked": .array([]), "linked": .bool(false),
        "prs": .array([.object(["number": .integer(Int64(pr)), "title": .string("Sign-in"), "body": .string(""), "url": .string(""),
                                "state": .string("open"), "head": .string(branch), "base": .string("main"),
                                "headSHA": .string("abc123"), "author": .string("me"), "checks": .array([]),
                                "threads": .array([thread("T2", "src/auth/token.go", 41), thread("T1", "src/auth/session.go", 88),
                                                   thread("T3", "src/old.go", 3, outdated: true),
                                                   thread("T4", "src/auth/session.go", 10, resolved: true)]),
                                "requestedReviewers": .array([.string("reviewer")])])]),
        "basePRs": .array([]), "stack": .array([]), "partial": .array([]),
    ])
}

private func line(_ text: String, at: String = "", who: String = "") -> TicketLineState {
    TicketLineState(text: text, who: who, at: at)
}

private func thread(_ id: String, _ path: String, _ line: Int, outdated: Bool = false, resolved: Bool = false) -> ReviewThreadState {
    ReviewThreadState(id: id, path: path, line: line, outdated: outdated, resolved: resolved)
}

@Suite struct EditorTicketTests {
    @Test func ticketByMapsEveryOrigin() {
        #expect(ticketBy(.ui) == "operator")
        #expect(ticketBy(.agent) == "agent")
        #expect(ticketBy(.debug) == "wakil")
    }

    @Test func followedRootIsTheFrontFilesElseFirst() {
        #expect(ticketFollowedRoot(front: "/p/web", roots: ["/p/api", "/p/web"]) == "/p/web")
        #expect(ticketFollowedRoot(front: nil, roots: ["/p/api", "/p/web"]) == "/p/api")
        #expect(ticketFollowedRoot(front: nil, roots: []) == nil)
    }

    /// Enter then leaving the field commits once: the record has not echoed the text yet.
    @Test func aFieldCommitsOncePerEdit() {
        var c = TicketFieldCommits()
        #expect(c.commit("  Ship the token fix ", value: "old") == "Ship the token fix")
        #expect(c.commit("Ship the token fix", value: "old") == nil)
        // Typing again is a new edit, even back to the same text.
        c.edited()
        #expect(c.commit("Ship the token fix", value: "old") == "Ship the token fix")
        // The field's own value is never committed back.
        var d = TicketFieldCommits()
        #expect(d.commit("old", value: "old") == nil)
        // An add field (value "") sends its line once.
        var a = TicketFieldCommits()
        #expect(a.commit("INI-142", value: "") == "INI-142")
        #expect(a.commit("INI-142", value: "") == nil)
    }

    @Test func staleAfterSixtySeconds() {
        let t = Date(timeIntervalSince1970: 1000)
        #expect(ticketStale(lastRead: nil, now: t))
        #expect(!ticketStale(lastRead: t, now: t.addingTimeInterval(60)))
        #expect(ticketStale(lastRead: t, now: t.addingTimeInterval(61)))
    }

    @Test func waitingOnDedupesAndOrders() throws {
        var b = try ticketDecode(TicketBranchState.self, { if case .object(let o) = ticketBranchJSON() { o } else { [:] } }(),
                                 tool: "t")
        // A thread on my PR whose last word is the reviewer's: waiting on me too.
        let record = TicketRecordState(key: "INI-142", waitingOn: [line("", who: "QA"), line("", who: "reviewer"), line("", who: "you")])
        #expect(ticketWaitingOn(b, record: record) == ["reviewer", "you", "QA"])
        b.prs[0].state = "merged"
        #expect(ticketWaitingOn(b, record: record) == ["QA", "reviewer", "you"])
    }

    @Test func nextFallsBackToNewestWithItsKey() {
        var marked = TicketRefState(key: "INI-142", marked: true)
        var a = TicketRefState(key: "INI-140"); a.record.next = line("deploy to QA", at: "2026-10-25T10:00:00Z")
        var c = TicketRefState(key: "INI-141"); c.record.next = line("answer the token comments", at: "2026-10-26T10:00:00Z")
        let b = TicketBranchState(root: "/p/api", tickets: [marked, a, c])
        #expect(ticketNext(b)?.text == "answer the token comments")
        #expect(ticketNext(b)?.key == "INI-141")
        marked.record.next = line("ship it")
        let withOwn = TicketBranchState(root: "/p/api", tickets: [marked, a, c])
        #expect(ticketNext(withOwn)?.text == "ship it")
        #expect(ticketNext(withOwn)?.key == nil)
        #expect(ticketNext(TicketBranchState(root: "/p/api", tickets: [TicketRefState(key: "INI-1", marked: true)])) == nil)
    }

    @Test func recordGroupsNameOnlyKindsThatHoldALineWithTheirCountAndMeaningfulHue() {
        let r = TicketRecordState(key: "INI-142", decisions: [line("a"), line("b")], notDone: [line("d")],
                                  verified: [line("f")])
        let groups = ticketRecordGroups(r)
        #expect(groups.map(\.heading) == ["Decisions", "Not done", "Verified"])
        #expect(groups.map(\.count) == [2, 1, 1])
        #expect(groups.map(\.hue) == [nil, .amber, .green])
        let other = ticketRecordGroups(TicketRecordState(key: "INI-142", waitingOn: [line("a"), line("b")], rulings: [line("c")]))
        #expect(other.map(\.kind) == ["waitingOn", "rulings"])
        #expect(other.map(\.hue) == [.amber, nil])
        #expect(ticketRecordGroups(TicketRecordState(key: "INI-142")).isEmpty)
        // The kind + Add is adding a line of shows its heading before it holds one.
        #expect(ticketRecordGroups(TicketRecordState(key: "INI-142"), including: "rulings").map(\.heading) == ["Rulings"])
        #expect(ticketRecordGroups(r, including: "rulings").map(\.count) == [2, 1, 1, 0])
    }

    @Test func openThreadsSkipOutdatedAndResolvedInFileThenLineOrder() {
        let pr = PullRequestState(number: 212, threads: [
            thread("T2", "src/b.go", 41), thread("T1", "src/a.go", 88), thread("T5", "src/a.go", 7),
            thread("T3", "src/old.go", 3, outdated: true), thread("T4", "src/a.go", 10, resolved: true),
        ])
        #expect(reviewOpenThreads([pr, pr]).map(\.id) == ["T5", "T1", "T2"])
    }

    @Test func stepWrapsBothWays() {
        let ts = ["a", "b", "c"].map { thread($0, "f.go", 1) }
        #expect(reviewStep(ts, from: "c", delta: 1)?.id == "a")
        #expect(reviewStep(ts, from: "a", delta: -1)?.id == "c")
        #expect(reviewStep(ts, from: "a", delta: 1)?.id == "b")
        #expect(reviewStep(ts, from: nil, delta: 1)?.id == "a")
        #expect(reviewStep(ts, from: nil, delta: -1)?.id == "c")
        #expect(reviewStep([], from: nil, delta: 1) == nil)
    }

    @Test func positionReadsOneOfFive() {
        let ts = (1...5).map { thread("t\($0)", "f.go", $0) }
        #expect(reviewPosition(ts, id: "t1") == "1 of 5")
        #expect(reviewPosition(ts, id: "t5") == "5 of 5")
        #expect(reviewPosition(ts, id: "x") == "")
    }

    @Test func aReadStampsEachThreadWithItsPullRequest() throws {
        guard case .object(let o) = ticketBranchJSON() else { return }
        let b = try ticketDecode(TicketBranchState.self, o, tool: "t")
        let t = try #require(b.prs.first?.threads.first)
        #expect(t.number == 212 && t.headSHA == "abc123" && t.root == "/p/api" && t.repo == "github.com/initech/api")
        // Encodable too: the review box (Task 7) carries the comments as data.
        let again = try JSONDecoder().decode(TicketBranchState.self, from: JSONEncoder().encode(b))
        #expect(again == b)
    }

    // MARK: The view's rows (Task 8)

    @Test func caseForEachSpecRow() throws {
        guard case .object(let o) = ticketBranchJSON() else { return }
        var b = try ticketDecode(TicketBranchState.self, o, tool: "t")
        #expect(ticketViewCase(b, shown: nil) == .ticket)
        // A key picked from In flight overrides the branch, whatever the branch is.
        b.longLived = true
        #expect(ticketViewCase(b, shown: "INI-140") == .ticket)
        #expect(ticketViewCase(b, shown: nil) == .longLived)
        b.longLived = false
        b.tickets.append(TicketRefState(key: "INI-141", sources: ["stack"]))
        #expect(ticketViewCase(b, shown: nil) == .several)
        // A ticket only the stack carries is never the branch's own: not "a ticket", the several layout.
        b.tickets = [TicketRefState(key: "INI-141", sources: ["stack"])]
        #expect(ticketViewCase(b, shown: nil) == .several)
        b.tickets = []
        b.branch = "fix-utf-8"
        #expect(ticketViewCase(b, shown: nil) == .noTicket(branch: "fix-utf-8"))
        // Reading only while a read is in flight (Rule 8, B2): a root nothing is reading — never read,
        // or its first read cancelled — says it is not read, never "Reading the ticket…".
        #expect(ticketViewCase(nil, shown: nil, reading: true) == .loading)
        #expect(ticketViewCase(nil, shown: nil) == .unread)
        #expect(ticketViewCase(nil, shown: nil, failure: "boom", reading: true) == .error("boom"))
        #expect(ticketViewCase(nil, shown: nil, failure: "Read stopped after 20 s. ↻ reads again.")
                == .error("Read stopped after 20 s. ↻ reads again."))
        // A failed re-read keeps the last read on screen; the failure shows beside it.
        #expect(ticketViewCase(b, shown: nil, failure: "boom") == .noTicket(branch: "fix-utf-8"))
        #expect(ticketViewCase(nil, shown: "INI-140") == .ticket)
    }

    @Test func prLineMatchesTheMockup() {
        let checks = (1...7).map { TicketCheckState(name: "ok \($0)", state: "success") }
            + [TicketCheckState(name: "unit (Linux)", state: "failure", url: "https://ci.example.com/1"),
               TicketCheckState(name: "e2e", state: "pending")]
        let pr = PullRequestState(number: 212, state: "open", head: "ini-142-login", base: "main", checks: checks)
        #expect(ticketPRLine(pr) == "#212  ini-142-login → main      open · checks 7/9 · 1 failing")
        #expect(ticketFailingChecks(pr) == [checks[7]])
        #expect(ticketPRLine(PullRequestState(number: 9, state: "merged", head: "a", base: "main"))
                == "#9  a → main      merged")
    }

    /// Walk 2026-10-29: the first comment whole, its whitespace one space — the column cuts no text.
    @Test func threadRowSaysTheCommentWholeAndCountsReplies() {
        let long = ReviewThreadState(id: "T1", path: "src/auth/session.go", line: 88, comments: [
            ReviewCommentState(author: "reviewer", body: "Should this read the org from the token instead of the session?",
                               createdAt: ""),
            ReviewCommentState(author: "me", body: "Maybe", createdAt: ""),
            ReviewCommentState(author: "reviewer", body: "Yes", createdAt: ""),
        ])
        let row = ticketThreadRow(long)
        #expect(row.place == "src/auth/session.go:88")
        #expect(row.words == "Should this read the org from the token instead of the session?")
        #expect(row.replies == "2 replies")
        let short = ReviewThreadState(id: "T2", path: "src/auth/token.go", line: 41, comments: [
            ReviewCommentState(author: "reviewer", body: "Nit: the error should name the host", createdAt: ""),
            ReviewCommentState(author: "me", body: "Done", createdAt: ""),
        ])
        #expect(ticketThreadRow(short).words == "Nit: the error should name the host")
        #expect(ticketThreadRow(short).replies == "1 reply")
        #expect(ticketThreadRow(ReviewThreadState(id: "T3", path: "a.go", line: 0)).replies == nil)
        #expect(ticketThreadRow(ReviewThreadState(id: "T3", path: "a.go", line: 0)).place == "a.go")
    }

    @Test func outdatedThreadRowSaysOutdated() {
        let t = ReviewThreadState(id: "T3", path: "src/old.go", line: 3, outdated: true,
                                  comments: [ReviewCommentState(author: "r", body: "Why?", createdAt: "")])
        #expect(ticketThreadRow(t).replies == "outdated")
        // The column lists every unresolved thread, outdated ones too; resolved ones go.
        let pr = PullRequestState(number: 1, threads: [t, ReviewThreadState(id: "T4", path: "a.go", line: 1, resolved: true),
                                                       ReviewThreadState(id: "T5", path: "a.go", line: 9)])
        #expect(ticketColumnThreads(pr).map(\.id) == ["T5", "T3"])
    }

    @Test func inFlightStateWords() throws {
        // Go composes the words; the row shows them as they came.
        func row(_ key: String, _ state: String) -> JSONValue {
            .object(["key": .string(key), "title": .string("Sign-in"), "status": .string("In Progress"), "state": .string(state),
                     "root": .string("/p/api"), "branch": .string("ini-142-login"), "pr": .integer(212)])
        }
        let o: [String: JSONValue] = ["waitingOnYou": .array([row("INI-142", "#212 · 2 threads")]),
                                      "inFlight": .array([row("INI-140", "checks failing")]), "partial": .array([])]
        let s = try ticketDecode(InFlightState.self, o, tool: "t")
        #expect(s.waitingOnYou.first?.state == "#212 · 2 threads")
        #expect(s.inFlight.first?.state == "checks failing")
    }

    @Test func inFlightRowCarriesItsNumbers() throws {
        // Piece 3's numbers decode beside piece 2's words; a row from before them decodes as empty.
        let row: JSONValue = .object([
            "key": .string(""), "title": .string("Speed up the build"), "state": .string("#215 · 2 threads"),
            "root": .string(""), "branch": .string("build-speed"), "pr": .integer(215), "project": .string(""),
            "repo": .string("github.com/initech/billing"), "url": .string("https://github.com/initech/billing/pull/215"),
            "threads": .array([.string("T_1"), .string("T_2")]), "failing": .array([.string("unit (Linux)")]),
            "review": .bool(true), "activity": .string("2026-10-26T11:00:00Z"),
            "handoffs": .array([.object(["id": .string("h1"), "conversation": .string("c1"), "thread": .string("T_1")])]),
            "count": .integer(4),
        ])
        let old: JSONValue = .object(["key": .string("INI-142"), "state": .string("local branch")])
        let o: [String: JSONValue] = ["waitingOnYou": .array([row]), "inFlight": .array([old]), "partial": .array([]),
                                      "count": .integer(4)]
        let s = try ticketDecode(InFlightState.self, o, tool: "t")
        #expect(s.count == 4)
        let r = try #require(s.waitingOnYou.first)
        #expect(r.threads == ["T_1", "T_2"] && r.failing == ["unit (Linux)"] && r.review && r.count == 4)
        #expect(r.repo == "github.com/initech/billing" && r.url.hasSuffix("/pull/215") && r.root.isEmpty && r.project.isEmpty)
        #expect(r.activity == "2026-10-26T11:00:00Z" && r.handoffs == [HandoffRefState(id: "h1", conversation: "c1", thread: "T_1")])
        #expect(s.inFlight.first == InFlightRowState(key: "INI-142", state: "local branch"))
    }

    @Test func partialLinesAreWhole() {
        let ssh = "Pull requests not read: this organization's github.com account signs in with SSH, which reads no pull "
            + "requests. Add API access to the GitHub account in Settings → Organisation → Git."
        let notes = [SourceNoteState(source: "github", message: ssh), SourceNoteState(source: "jira", message: "Jira said: 401"),
                     SourceNoteState(source: "jira", message: "Jira said: 401"), SourceNoteState(source: "git", message: " ")]
        #expect(ticketPartialLine(notes) == [ssh, "Jira said: 401"])
        let b = TicketBranchState(root: "/p", tickets: [TicketRefState(key: "INI-142", error: "Jira said: 401"),
                                                        TicketRefState(key: "INI-999", error: "Jira does not know INI-999")],
                                  partial: notes)
        #expect(ticketPartialLines(b) == [ssh, "Jira said: 401", "INI-999: Jira does not know INI-999"])
    }

    @Test func sourcesAndCaptionsInWords() {
        #expect(ticketSourceLabel("stack") == "from the stack")
        #expect(ticketSourceLabel("wakil") == "linked in Wakil")
        #expect(ticketSourceLabel("branch") == "from the branch name")
        #expect(ticketLookedLine(["branch name", "PR #215's title and body", "4 commits' trailers"])
                == "Looked in the branch name, PR #215's title and body, 4 commits' trailers")
        #expect(ticketLookedLine([]) == nil)
        let now = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
        #expect(ticketLineCaption(TicketLineState(by: "operator", at: "2026-10-26T10:00:00Z"), now: now) == "you · 2 hours ago")
        #expect(ticketLineCaption(TicketLineState(by: "agent", at: "2026-10-26T11:59:30Z"), now: now).hasPrefix("agent · "))
        #expect(ticketLineCaption(TicketLineState(by: "wakil", at: ""), now: now) == "Wakil")
        #expect(ticketLineWho(TicketLineState(by: "operator")) == "you")
        #expect(ticketLineWho(TicketLineState(by: "agent")) == "agent")
        #expect(ticketLineWho(TicketLineState(by: "wakil")) == "Wakil")
        #expect(ticketLineCaption(TicketLineState(by: "operator", at: "2026-10-26T10:00:00Z", edited: "agent"), now: now)
                == "you · 2 hours ago · edited by agent")
    }

    @Test func linkNoteKeepsAnUnfoundKey() {
        #expect(ticketLinkNote(.object(["key": .string("INI-999"), "linked": .bool(true), "notFound": .bool(true),
                                        "message": .string("INI-999 was not found in Jira; the link is kept. 404")]))
                == "INI-999 was not found in Jira; kept as typed. 404")
        // Go's error is appended whole (Rule 8), even when Go words its line another way.
        #expect(ticketLinkNote(.object(["key": .string("INI-999"), "notFound": .bool(true),
                                        "message": .string("Jira said: Issue does not exist or you do not have permission to see it.")]))
                == "INI-999 was not found in Jira; kept as typed. Jira said: Issue does not exist or you do not have permission to see it.")
        #expect(ticketLinkNote(.object(["key": .string("INI-142"), "linked": .bool(true), "notFound": .bool(false),
                                        "message": .string("Jira was not asked whether it knows INI-142; the link is kept. timeout")]))
                == "Jira was not asked whether it knows INI-142; the link is kept. timeout")
        #expect(ticketLinkNote(.object(["key": .string("INI-142"), "linked": .bool(true)])) == nil)
    }

    @Test func nextFieldWritesTheTicketItShows() {
        var marked = TicketRefState(key: "INI-142", marked: true)
        var other = TicketRefState(key: "INI-141"); other.record.next = TicketLineState(text: "deploy", at: "2026-10-26T10:00:00Z")
        #expect(ticketNextTarget(TicketBranchState(root: "/p", tickets: [marked, other]))?.key == "INI-141")
        #expect(ticketNextTarget(TicketBranchState(root: "/p", tickets: [marked, other]))?.labelled == true)
        marked.record.next = TicketLineState(text: "ship")
        let t = ticketNextTarget(TicketBranchState(root: "/p", tickets: [marked, other]))
        #expect(t?.key == "INI-142" && t?.text == "ship" && t?.labelled == false)
        let stackOnly = ticketNextTarget(TicketBranchState(root: "/p", tickets: [TicketRefState(key: "INI-1", sources: ["stack"])]))
        #expect(stackOnly?.key == "INI-1" && stackOnly?.labelled == true)
        #expect(ticketNextTarget(TicketBranchState(root: "/p")) == nil)
    }

    // MARK: The store

    @Test(.timeLimit(.minutes(1))) func aSecondReadJoinsTheFirst() async throws {
        let fake = FakeTicket()
        await fake.set("ticket_branch", ticketBranchJSON())
        await fake.setSlowBranch(true)
        let store = EditorTicketStore(ticket: fake)
        async let one = store.read(root: "/p/api")
        while await fake.count("ticket_branch") == 0 { await Task.yield() }
        async let two = store.read(root: "/p/api")
        while !(await store.reading(root: "/p/api")) { await Task.yield() }
        await fake.release()
        let (a, b) = try await (one, two)
        #expect(a == b)
        #expect(await fake.count("ticket_branch") == 1)
        #expect(await store.branch(root: "/p/api")?.branch == "ini-142-login")
        #expect(!(await store.reading(root: "/p/api")))
    }

    @Test(.timeLimit(.minutes(1))) func aReadPastTwentySecondsIsCancelledAndSaysSo() async throws {
        #expect(EditorTicketStore.readLimit == .seconds(20))
        #expect(TicketReadError.stopped(after: .seconds(20)).description == "Read stopped after 20 s. ↻ reads again.")
        let fake = FakeTicket()
        await fake.setHangBranch(true)
        let store = EditorTicketStore(ticket: fake, readLimit: .seconds(1))
        await #expect(throws: TicketReadError(description: "Read stopped after 1 s. ↻ reads again.")) {
            try await store.read(root: "/p/api")
        }
        #expect(await store.failure(root: "/p/api") == "Read stopped after 1 s. ↻ reads again.")
        #expect(!(await store.reading(root: "/p/api")))
    }

    @Test(.timeLimit(.minutes(1))) func aReadFromTheOldOrgIsDropped() async throws {
        let fake = FakeTicket()
        await fake.set("ticket_branch", ticketBranchJSON())
        await fake.setSlowBranch(true)
        let store = EditorTicketStore(ticket: fake)
        try await store.setDraft(thread: "T2", text: "Fixed in the next push", by: "operator", conversation: nil,
                                 root: nil, branch: nil)
        let read = Task { try await store.read(root: "/p/api") }
        while await fake.count("ticket_branch") == 0 { await Task.yield() }
        await store.reset()
        await fake.release()
        _ = try? await read.value
        #expect(await store.branch(root: "/p/api") == nil)
        #expect(await store.allDrafts().isEmpty)
        #expect(!(await store.reading(root: "/p/api")))
    }

    // MARK: A ticket's pull requests across repositories and branches (walk 2026-10-29)

    /// The other branches carrying a shown ticket — any root, any repository — are read, each failure
    /// kept whole by its branch; the branch already shown is not read again; their threads are found.
    @Test(.timeLimit(.minutes(1))) func aTicketsOtherBranchesAreRead() async throws {
        let fake = FakeTicket()
        await fake.set("ticket_in_flight", .object([
            "waitingOnYou": .array([]), "partial": .array([]), "count": .integer(0),
            "inFlight": .array([
                .object(["key": .string("INI-142"), "root": .string("/p/api"), "branch": .string("ini-142-login"), "pr": .integer(212)]),
                .object(["key": .string("INI-142"), "root": .string("/p/web"), "branch": .string("ini-142-web"), "pr": .integer(7)]),
                .object(["key": .string("INI-142"), "root": .string("/p/api"), "branch": .string("ini-142-hotfix")]),
                .object(["key": .string("INI-150"), "root": .string("/p/web"), "branch": .string("ini-150-other")]),
            ]),
        ]))
        await fake.setBranch(root: "/p/web", branch: "ini-142-web",
                             ticketBranchJSON(root: "/p/web", branch: "ini-142-web", repo: "github.com/initech/web", pr: 7, threads: "W"))
        await fake.failBranch(root: "/p/api", branch: "ini-142-hotfix", "GitHub said no")
        let store = EditorTicketStore(ticket: fake)
        _ = try await store.inFlight()
        await store.readTicketBranches(key: "INI-142", except: TicketShownAt(root: "/p/api", branch: "ini-142-login"))
        let also = await store.ticketBranchReads()["INI-142"] ?? []
        #expect(also.map(\.branch) == ["ini-142-web"])
        #expect(also.first?.prs.map(\.number) == [7])
        #expect(await store.ticketBranchFailures()["INI-142"] == ["ini-142-hotfix: GitHub said no"])
        let read = await fake.calls.filter { $0.name == "ticket_branch" }.compactMap { c -> String? in
            guard case .object(let a) = c.args, case .string(let b)? = a["branch"] else { return nil }
            return b
        }
        #expect(read.sorted() == ["ini-142-hotfix", "ini-142-web"])
        #expect(await store.branch(holding: "W2")?.branch == "ini-142-web")
    }

    /// The Pull requests section's groups: one per repository, the shown branch's first, each PR once.
    @Test func aTicketsPullRequestsGroupByRepository() throws {
        func b(_ json: JSONValue) throws -> TicketBranchState {
            guard case .object(let o) = json else { throw TicketReadError(description: "not an object") }
            return try ticketDecode(TicketBranchState.self, o, tool: "t")
        }
        let api = try b(ticketBranchJSON())
        let hotfix = try b(ticketBranchJSON(branch: "ini-142-hotfix", pr: 213, threads: "H"))
        let web = try b(ticketBranchJSON(root: "/p/web", branch: "ini-142-web", repo: "github.com/initech/web", pr: 7, threads: "W"))
        let again = try b(ticketBranchJSON(root: "/p/api-2", branch: "ini-142-login"))
        let groups = ticketPRGroups(primary: api, others: [web, hotfix, again])
        #expect(groups.map(\.name) == ["api", "web"])
        #expect(groups.map { $0.prs.map(\.number) } == [[212, 213], [7]])
        let merged = ticketMergedBranch(primary: api, others: [web, hotfix, again])
        #expect(merged.prs.map(\.number) == [212, 213, 7])
        #expect(merged.viewer == "me")
        #expect(ticketPRGroups(primary: api, others: []).map(\.name) == ["api"])
    }

    // MARK: Cover fixes

    /// B3: a ticket picked from In flight whose record cannot be read shows the failure whole, never
    /// the branch read's empty stand-in for it; a record that was read wins over both.
    @Test func shownRecordFailureIsShownNotAnEmptyRecord() {
        let stand = TicketRecordState(key: "INI-142")
        let ref = TicketRefState(key: "INI-142", record: stand, error: "open INI-142.json: permission denied")
        var v = EditorTicketViewState(recordFailures: ["INI-142": "The record could not be read: permission denied"])
        #expect(ticketShownRecord(v, key: "INI-142", ref: ref) == .failure("The record could not be read: permission denied"))
        // No record read yet and none failed: the branch's own record stands.
        v.recordFailures = [:]
        #expect(ticketShownRecord(v, key: "INI-142", ref: ref) == .record(stand))
        #expect(ticketShownRecord(v, key: "INI-142", ref: nil) == .none)
        let read = TicketRecordState(key: "INI-142", next: TicketLineState(text: "ask Milton"))
        v.records = ["INI-142": read]
        v.recordFailures = ["INI-142": "stale"]
        #expect(ticketShownRecord(v, key: "INI-142", ref: ref) == .record(read))
    }

    /// B4: In flight and Waiting on you rows are named by key, root and branch, so two branches
    /// carrying one key are two names; the root is its last component, stable across runs.
    @Test func inFlightRowNamesAreUniqueAndStable() {
        let a = InFlightRowState(key: "INI-142", root: "/var/folders/x/e2e-api", branch: "ini-142-login")
        let b = InFlightRowState(key: "INI-142", root: "/var/folders/x/e2e-api", branch: "ini-170-ini-142-both")
        let c = InFlightRowState(key: "INI-142", root: "/var/folders/x/e2e-web", branch: "ini-142-login")
        let unkeyed = InFlightRowState(key: "", root: "/p/api", branch: "build-speed", pr: 301)
        #expect(ticketInFlightRowName(a) == "INI-142:e2e-api:ini-142-login")
        #expect(ticketInFlightRowName(unkeyed) == ":api:build-speed")
        #expect(Set([a, b, c].map(ticketInFlightRowName)).count == 3)
        #expect(ticketInFlightRowName(a) == ticketInFlightRowName(a))
    }

    /// Design A's pills carry §5's meanings only: done green, waiting amber, failed red, the rest
    /// neutral — never violet.
    @Test func pillHuesFollowTheReservedMeanings() {
        #expect(ticketStatusHue("Done") == .green)
        #expect(ticketStatusHue("closed") == .green)
        #expect(ticketStatusHue("Backlog") == .amber)
        #expect(ticketStatusHue("To Do") == .amber)
        #expect(ticketStatusHue("In Review") == .amber)
        #expect(ticketStatusHue("Waiting for customer") == .amber)
        #expect(ticketStatusHue("In Progress") == .neutral)
        #expect(ticketStatusHue("") == .neutral)
        #expect(ticketPRStatePill(PullRequestState(number: 1, state: "OPEN")) == ("open", .green))
        #expect(ticketPRStatePill(PullRequestState(number: 1, state: "")) == ("open", .green))
        #expect(ticketPRStatePill(PullRequestState(number: 1, state: "MERGED")) == ("merged", .neutral))
        #expect(ticketPRStatePill(PullRequestState(number: 1, state: "closed")) == ("closed", .neutral))
        #expect(ticketPRStatePill(PullRequestState(number: 1, state: "blocked")) == ("blocked", .amber))
        let ok = TicketCheckState(name: "a", state: "success"), bad = TicketCheckState(name: "b", state: "failure")
        let wait = TicketCheckState(name: "c", state: "pending")
        #expect(ticketChecksPill(PullRequestState(number: 1)) == nil)
        #expect(ticketChecksPill(PullRequestState(number: 1, checks: [ok, ok]))?.label == "checks 2/2")
        #expect(ticketChecksPill(PullRequestState(number: 1, checks: [ok, ok]))?.hue == .green)
        #expect(ticketChecksPill(PullRequestState(number: 1, checks: [ok, wait]))?.hue == .amber)
        #expect(ticketChecksPill(PullRequestState(number: 1, checks: [ok, bad, wait]))?.hue == .red)
    }

    /// The header's waiting line counts the threads that wait on you, only when it names you.
    @Test func waitingLineCountsThreadsWaitingOnYou() {
        let theirs = ReviewThreadState(id: "T1", path: "a", line: 1, comments: [ReviewCommentState(author: "bob", body: "x", createdAt: "")])
        let mine = ReviewThreadState(id: "T2", path: "a", line: 2, comments: [ReviewCommentState(author: "me", body: "x", createdAt: "")])
        let done = ReviewThreadState(id: "T3", path: "a", line: 3, resolved: true, comments: [ReviewCommentState(author: "bob", body: "x", createdAt: "")])
        let pr = PullRequestState(number: 1, state: "OPEN", author: "me", threads: [theirs, mine, done])
        let b = TicketBranchState(root: "/p", viewer: "me", prs: [pr, pr])
        #expect(ticketThreadsWaitingOnViewer(b) == 1)
        #expect(ticketWaitingLine(["reviewer", "you"], threads: 1) == "waiting on reviewer, you · 1 thread")
        #expect(ticketWaitingLine(["you"], threads: 2) == "waiting on you · 2 threads")
        #expect(ticketWaitingLine(["reviewer"], threads: 2) == "waiting on reviewer")
        #expect(ticketWaitingLine(["you"], threads: 0) == "waiting on you")
        #expect(ticketWaitingLine([], threads: 3) == nil)
        #expect(ticketBranchThreads([pr, pr]).map(\.id) == ["T1", "T2"])
    }

    // MARK: Ticket noticing, Task 4 — drafts survive a quit and say who wrote them

    /// A relaunch is a new store: its drafts are read back from the organisation's file, author and
    /// conversation with them; Go's empty strings read as absent.
    @Test func draftsSurviveANewStore() async throws {
        let fake = FakeTicket()
        await fake.seedDraft("T2", text: "Named the host in the error", by: "agent", conversation: "c1")
        let store = EditorTicketStore(ticket: fake)
        try await store.loadDrafts()
        #expect(await store.draft(thread: "T2") == "Named the host in the error")
        #expect(await store.allDrafts() == ["T2": "Named the host in the error"])
        let d = try #require(await store.draftRecord(thread: "T2"))
        #expect(d.by == "agent")
        #expect(d.conversation == "c1")
        #expect(d.root == nil && d.branch == nil && d.replaced == nil)
        #expect(d.at == "2026-10-28T10:00:00Z")
        #expect(await store.allDraftRecords().keys.sorted() == ["T2"])
    }

    /// An org switch during a slow load: the old organisation's drafts never land; the next load
    /// reads the new organisation's.
    @Test(.timeLimit(.minutes(1))) func orgSwitchLoadsTheNewOrgsDrafts() async throws {
        let fake = FakeTicket()
        await fake.seedDraft("T2", text: "initech's draft", by: "operator")
        await fake.setSlowDrafts(true)
        let store = EditorTicketStore(ticket: fake)
        let load = Task { try await store.loadDrafts() }
        while await fake.count("ticket_drafts") == 0 { await Task.yield() }
        await store.reset()
        await fake.clearDrafts()
        await fake.seedDraft("T9", text: "umbrella's draft", by: "operator")
        await fake.release()
        try? await load.value
        #expect(await store.allDrafts()["T2"] == nil)
        try await store.loadDrafts()
        #expect(await store.allDrafts() == ["T9": "umbrella's draft"])
    }

    /// Only an agent's draft carries a caption; only a replaced one says so, with Restore yours.
    @Test func captionForAgentDraftOnly() {
        let now = ISO8601DateFormatter().date(from: "2026-10-28T10:01:00Z")!
        let agent = TicketDraftState(text: "x", by: "agent", at: "2026-10-28T10:00:00Z", conversation: "c1")
        let mine = TicketDraftState(text: "x", by: "operator", at: "2026-10-28T10:00:00Z")
        #expect(ticketDraftCaption(agent, now: now) == "Drafted by agent · 1 min ago")
        #expect(ticketDraftCaption(mine, now: now) == nil)
        #expect(ticketDraftReplacedLine(agent) == nil)
        var replaced = agent
        replaced.replaced = "my words"
        #expect(ticketDraftReplacedLine(replaced) == "Agent replaced your draft · Restore yours")
    }
}

/// No wakil-ticket client: nothing to load, so no load and no drafts-failure line. A window with a
/// client whose load fails still says so (`aFailedDraftsLoadIsShownWhole`).
@Test func noTicketClientLoadsNoDraftsAndSaysNothing() async throws {
    let store = EditorTicketStore(ticket: nil)
    try await store.loadDrafts()
    #expect(await store.draftsFailure() == nil)
    #expect(await store.allDrafts().isEmpty)

    let fake = FakeTicket()
    await fake.fail("ticket_drafts", "drafts are not readable: unexpected end of JSON input")
    let withClient = EditorTicketStore(ticket: fake)
    await #expect { try await withClient.loadDrafts() } throws: { _ in true }
    #expect(await withClient.draftsFailure() == "Reply drafts could not be read: drafts are not readable: unexpected end of JSON input")
}

/// A ticket that needs the operator is listed once, under Waiting on you (walk, 2026-10-28).
@Test func aTicketWaitingOnYouIsNotListedAgainInFlight() {
        let waiting = InFlightRowState(key: "INI-142", root: "/r/api", branch: "ini-142-login")
        let other = InFlightRowState(key: "INI-150", root: "/r/api", branch: "ini-150-search")
        let s = InFlightState(waitingOnYou: [waiting], inFlight: [waiting, other])
        #expect(ticketInFlightNotWaiting(s) == [other])
        // The same key on another branch is another row, and stays.
        let elsewhere = InFlightRowState(key: "INI-142", root: "/r/api", branch: "ini-142-hotfix")
    #expect(ticketInFlightNotWaiting(InFlightState(waitingOnYou: [waiting], inFlight: [elsewhere])) == [elsewhere])
}
