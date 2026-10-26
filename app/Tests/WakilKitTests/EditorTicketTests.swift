import Foundation
import Testing
@testable import WakilKit

/// A wakil-ticket that answers from a dictionary and records every call. `slowBranch` parks
/// `ticket_branch` until `release()`, latched; `hangBranch` sleeps until cancelled.
actor FakeTicket: ToolCaller {
    var replies: [String: JSONValue] = [:]       // tool -> structuredContent
    var errors: [String: String] = [:]           // tool -> isError text
    var calls: [(name: String, args: JSONValue)] = []
    var slowBranch = false
    var hangBranch = false
    var slowReply = false
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func set(_ tool: String, _ content: JSONValue) { replies[tool] = content }
    func fail(_ tool: String, _ text: String?) { errors[tool] = text }
    func setSlowBranch(_ on: Bool) { slowBranch = on; released = false }
    func setHangBranch(_ on: Bool) { hangBranch = on }
    func setSlowReply(_ on: Bool) { slowReply = on; released = false }
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
        if (name == "ticket_branch" && slowBranch) || (name == "review_reply" && slowReply) {
            await withCheckedContinuation { c in Task { self.park(c) } }
        }
        if let e = errors[name] {
            return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(e)])])])
        }
        return .object(["structuredContent": replies[name] ?? .object([:])])
    }
}

/// `ticket_branch`'s answer for `ini-142-login` on `/p/api`: INI-142 marked, PR #212 with two open
/// threads, one outdated and one resolved.
func ticketBranchJSON(root: String = "/p/api", branch: String = "ini-142-login") -> JSONValue {
    func thread(_ id: String, _ path: String, _ line: Int, outdated: Bool = false, resolved: Bool = false) -> JSONValue {
        .object(["id": .string(id), "path": .string(path), "line": .integer(Int64(line)),
                 "outdated": .bool(outdated), "resolved": .bool(resolved),
                 "comments": .array([.object(["author": .string("reviewer"), "body": .string("Nit: the error should name the host"),
                                              "createdAt": .string("2026-10-26T09:00:00Z")])])])
    }
    return .object([
        "root": .string(root), "repo": .string("github.com/initech/api"), "branch": .string(branch),
        "viewer": .string("me"), "longLived": .bool(false),
        "tickets": .array([.object(["key": .string("INI-142"), "title": .string("Sign-in keeps the last organization"),
                                    "status": .string("In Progress"), "assignee": .string("me"), "url": .string(""),
                                    "sources": .array([.string("branch")]), "marked": .bool(true),
                                    "record": .object(["key": .string("INI-142"), "seen": .object([:]),
                                                       "branches": .array([]), "prs": .array([]),
                                                       "decisions": .array([]), "notDone": .array([]), "waitingOn": .array([]),
                                                       "verified": .array([]), "rulings": .array([])])])]),
        "looked": .array([]), "linked": .bool(false),
        "prs": .array([.object(["number": .integer(212), "title": .string("Sign-in"), "body": .string(""), "url": .string(""),
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

    @Test func foldLineCounts() {
        let r = TicketRecordState(key: "INI-142", decisions: [line("a"), line("b"), line("c")], notDone: [line("d"), line("e")],
                                  verified: [line("f")])
        #expect(ticketFoldLine(r) == "Decisions 3 · Not done 2 · Verified 1 ▸")
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
        await store.setDraft(thread: "T2", text: "Fixed in the next push")
        let read = Task { try await store.read(root: "/p/api") }
        while await fake.count("ticket_branch") == 0 { await Task.yield() }
        await store.reset()
        await fake.release()
        _ = try? await read.value
        #expect(await store.branch(root: "/p/api") == nil)
        #expect(await store.allDrafts().isEmpty)
        #expect(!(await store.reading(root: "/p/api")))
    }
}
