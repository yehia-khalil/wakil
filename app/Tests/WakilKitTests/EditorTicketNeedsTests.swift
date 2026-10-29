import Foundation
import Testing
@testable import WakilKit

/// A Waiting on you or In flight row with the numbers the urgency reads; everything else empty.
private func row(key: String = "INI-142", pr: Int = 0, threads: [String] = [], failing: [String] = [], review: Bool = false,
                 conversations: [String] = [], root: String = "/p/api", repo: String = "github.com/initech/api",
                 activity: String = "", title: String = "") -> InFlightRowState {
    InFlightRowState(key: key, title: title, root: root, branch: "ini-142-login", pr: pr, repo: repo,
                     threads: threads, failing: failing, review: review, activity: activity,
                     handoffs: conversations.map { HandoffRefState(id: "h-\($0)", conversation: $0) },
                     count: threads.count + (failing.isEmpty ? 0 : 1) + (review ? 1 : 0))
}

@Suite struct EditorTicketNeedsTests {
    /// The spec's table, one fixture per tier, and the highest tier wins on a row holding several.
    @Test func urgencyOrderIsTheSpecsTable() {
        let cases: [(InFlightRowState, [String: TicketHandOffLive], Int, Int, String)] = [
            (row(conversations: ["c1"]), ["c1": .failed], 0, 1, "agent failed"),
            (row(conversations: ["c1"]), ["c1": .waiting], 0, 2, "agent waiting"),
            (row(pr: 212, threads: ["T1", "T2"]), [:], 2, 3, "2 drafts to send"),
            (row(pr: 212, threads: ["T1"]), [:], 1, 3, "1 draft to send"),
            (row(pr: 212, threads: ["T1", "T2", "T3"]), [:], 0, 4, "#212 · 3 comments"),
            (row(pr: 212, threads: ["T1"]), [:], 0, 4, "#212 · 1 comment"),
            (row(pr: 215, failing: ["unit (Linux)"]), [:], 0, 5, "#215 · unit (Linux) failing"),
            (row(pr: 215, failing: ["unit (Linux)", "lint"]), [:], 0, 5, "#215 · 2 checks failing"),
            (row(pr: 214, review: true), [:], 0, 6, "#214 · review requested"),
            (row(conversations: ["c1"]), ["c1": .working], 0, 7, "agent working"),
            (row(pr: 209), [:], 0, 8, "#209 · open"),
            (row(), [:], 0, 9, "local branch"),
        ]
        for (r, handoffs, drafts, tier, words) in cases {
            let u = ticketUrgentState(r, handoffs: handoffs, drafts: drafts)
            #expect(u == TicketUrgent(tier: tier, words: words), "\(words)")
            #expect(u.needsYou == (tier <= 6))
        }
        // Several reasons on one row: the highest tier wins, the rest counted after it.
        let several = row(pr: 212, threads: ["T1"], failing: ["unit (Linux)"], review: true, conversations: ["c1", "c2"])
        #expect(ticketUrgentState(several, handoffs: ["c1": .working, "c2": .waiting], drafts: 0)
            == TicketUrgent(tier: 2, words: "agent waiting · +4 more"))
        #expect(ticketUrgentState(several, handoffs: ["c1": .working], drafts: 0)
            == TicketUrgent(tier: 4, words: "#212 · 1 comment · +3 more"))
    }

    @Test func plusMoreCountsTheOtherReasons() {
        let r = row(pr: 212, threads: ["T1", "T2"], failing: ["unit (Linux)"])
        #expect(ticketUrgentState(r, handoffs: [:], drafts: 0).words == "#212 · 2 comments · +1 more")
        // A lone reason has no "+N more"; an open PR is not a reason beside a real one.
        #expect(ticketUrgentState(row(pr: 212, threads: ["T1", "T2"]), handoffs: [:], drafts: 0).words == "#212 · 2 comments")
    }

    /// A draft on a waiting thread is not a second item: the thread reads as a draft to send, and only
    /// the threads with no draft still read as comments.
    @Test func draftsOutrankComments() {
        let r = row(pr: 212, threads: ["T1", "T2", "T3"])
        #expect(ticketUrgentState(r, handoffs: [:], drafts: 1) == TicketUrgent(tier: 3, words: "1 draft to send · +1 more"))
        #expect(ticketUrgentState(r, handoffs: [:], drafts: 3) == TicketUrgent(tier: 3, words: "3 drafts to send"))
        // Through the rows: only the drafts whose thread the row holds count.
        let s = InFlightState(waitingOnYou: [r], count: 3)
        let drafts = ["T2": TicketDraftState(text: "Fixed.", by: "agent"), "T9": TicketDraftState(text: "Elsewhere.", by: "operator")]
        #expect(ticketNeedsRows(s, handoffs: [:], drafts: drafts).first?.urgent.words == "1 draft to send · +1 more")
    }

    /// A hand-off whose conversation ended (not live) is not in the map, and a done one is no reason.
    @Test func endedHandOffIgnored() {
        let r = row(pr: 209, conversations: ["gone", "c2"])
        #expect(ticketUrgentState(r, handoffs: [:], drafts: 0) == TicketUrgent(tier: 8, words: "#209 · open"))
        #expect(ticketUrgentState(r, handoffs: ["c2": .done], drafts: 0) == TicketUrgent(tier: 8, words: "#209 · open"))
        #expect(ticketUrgentState(r, handoffs: ["c2": .working], drafts: 0) == TicketUrgent(tier: 7, words: "agent working"))
    }

    @Test func rowsSortByTierThenActivity() {
        let s = InFlightState(
            waitingOnYou: [
                row(key: "INI-131", pr: 131, threads: ["A"], activity: "2026-10-27T09:00:00Z"),
                row(key: "INI-150", pr: 150, threads: ["B"], activity: "2026-10-28T09:00:00Z"),
            ],
            inFlight: [
                row(key: "INI-160", pr: 160, activity: "2026-10-28T11:00:00Z"),
                row(key: "INI-131", pr: 0, activity: "2026-10-26T09:00:00Z"),
            ],
            count: 2)
        let rows = ticketNeedsRows(s, handoffs: [:], drafts: [:])
        #expect(rows.map(\.id) == ["INI-150", "INI-131", "INI-160"])
        // One row per ticket, holding its PRs and branches, with its newest activity.
        #expect(rows[1].rows.count == 2)
        #expect(rows[1].activity == "2026-10-27T09:00:00Z")
    }

    @Test func keylessRowIsIdentifiedByPR() {
        let s = InFlightState(waitingOnYou: [row(key: "", pr: 215, failing: ["unit (Linux)"], title: "Build speed")], count: 1)
        let r = ticketNeedsRows(s, handoffs: [:], drafts: [:]).first
        #expect(r?.id == "github.com/initech/api#215")
        #expect(r?.key == nil)
        #expect(r?.title == "Build speed")
        #expect(r?.urgent.words == "#215 · unit (Linux) failing")
    }

    @Test func outsideRepoRowIsNotOpenable() {
        let s = InFlightState(waitingOnYou: [
            row(key: "INI-170", pr: 214, review: true, root: "", repo: "github.com/initech/billing"),
            row(key: "INI-142", pr: 212, threads: ["T1"]),
        ], count: 2)
        let rows = ticketNeedsRows(s, handoffs: [:], drafts: [:])
        #expect(rows.first { $0.id == "INI-170" }?.openable == false)
        #expect(rows.first { $0.id == "INI-142" }?.openable == true)
    }

    @Test func countIsTheReplysCount() {
        #expect(ticketNeedsCount(InFlightState(waitingOnYou: [row(pr: 212, threads: ["T1"])], count: 4)) == 4)
        #expect(ticketNeedsCount(nil) == 0)
    }

    @Test func labelSaysEachKind() {
        let four = InFlightState(waitingOnYou: [row(pr: 212, threads: ["T1", "T2", "T3"]), row(key: "", pr: 215, failing: ["unit (Linux)"])],
                                 count: 4)
        #expect(ticketNeedsLabel(four) == "4 waiting on you: 3 review threads, 1 failing check")
        let singles = InFlightState(waitingOnYou: [row(pr: 212, threads: ["T1"]), row(pr: 214, review: true)], count: 2)
        #expect(ticketNeedsLabel(singles) == "2 waiting on you: 1 review thread, 1 review request")
        let plural = InFlightState(waitingOnYou: [
            row(pr: 215, failing: ["a"]), row(pr: 216, failing: ["b", "c"]), row(pr: 214, review: true), row(pr: 217, review: true),
        ], count: 4)
        #expect(ticketNeedsLabel(plural) == "4 waiting on you: 2 failing checks, 2 review requests")
        #expect(ticketNeedsLabel(InFlightState(inFlight: [row(pr: 209)], count: 0)) == nil)
        #expect(ticketNeedsLabel(nil) == nil)
    }

    @Test func pollWantedOnlyActiveAndUnlocked() {
        #expect(ticketPollWanted(appActive: true, screenLocked: false, organization: "initech"))
        #expect(!ticketPollWanted(appActive: false, screenLocked: false, organization: "initech"))
        #expect(!ticketPollWanted(appActive: true, screenLocked: true, organization: "initech"))
        #expect(!ticketPollWanted(appActive: true, screenLocked: false, organization: ""))
    }

    // MARK: Task 7 — the Landing's Tickets in flight, and opening a row

    /// `n` rows of the read, each its own ticket (INI-101, INI-102, …), oldest last.
    private func needsRows(_ n: Int) -> [TicketNeedsRow] {
        let s = InFlightState(inFlight: (1...n).map { i in
            row(key: "INI-\(100 + i)", pr: 200 + i, activity: "2026-10-28T09:\(String(format: "%02d", 60 - i)):00Z")
        })
        return ticketNeedsRows(s, handoffs: [:], drafts: [:])
    }

    @Test func landingShowsFiveThenAll() {
        let rows = needsRows(7)
        let landing = landingTicketRows(rows)
        #expect(landing.shown.map(\.id) == Array(rows.prefix(5)).map(\.id))
        #expect(landing.allLine == "All 7 in ⌘P")
    }

    @Test func landingAllLineAbsentAtFive() {
        let landing = landingTicketRows(needsRows(5))
        #expect(landing.shown.count == 5)
        #expect(landing.allLine == nil)
        #expect(landingTicketRows([]).shown.isEmpty)
        #expect(landingTicketRows([]).allLine == nil)
    }

    /// A row's name where a key goes: the key, else the PR and its repository's last part (never empty).
    @Test func keylessRowIsNamedByItsPR() {
        let s = InFlightState(waitingOnYou: [row(key: "", pr: 215, failing: ["unit (Linux)"])], count: 1)
        let r = ticketNeedsRows(s, handoffs: [:], drafts: [:]).first
        #expect(r.map(ticketNeedsRowName) == "#215 · api")
        #expect(ticketNeedsRowName(needsRows(1)[0]) == "INI-101")
        #expect(ticketInFlightRowLabel(row(key: "", pr: 215)) == "#215 · api")
        #expect(ticketInFlightRowLabel(row(key: "INI-142", pr: 212)) == "INI-142")
    }

    /// What a Landing or ⌘P row dispatches: a ticket by key at its row's root and branch, with its PR;
    /// a keyless one by its root and branch; one no project holds by its PR and repository.
    @Test func openParamsNameTheRow() {
        let keyed = ticketNeedsRows(InFlightState(waitingOnYou: [row(key: "INI-142", pr: 212, threads: ["T1"])], count: 1),
                                    handoffs: [:], drafts: [:])[0]
        #expect(ticketOpenParams(keyed) == .object(["key": .string("INI-142"), "root": .string("/p/api"),
                                                    "branch": .string("ini-142-login"), "pr": .integer(212)]))
        let keyless = ticketNeedsRows(InFlightState(waitingOnYou: [row(key: "", pr: 215, failing: ["x"])], count: 1),
                                      handoffs: [:], drafts: [:])[0]
        #expect(ticketOpenParams(keyless) == .object(["key": .null, "root": .string("/p/api"),
                                                      "branch": .string("ini-142-login"), "pr": .integer(215)]))
        let outside = ticketNeedsRows(InFlightState(waitingOnYou: [row(key: "", pr: 300, review: true, root: "",
                                                                         repo: "github.com/umbrella/web")], count: 1),
                                      handoffs: [:], drafts: [:])[0]
        #expect(ticketOpenParams(outside) == .object(["key": .null, "pr": .integer(300),
                                                      "repo": .string("github.com/umbrella/web")]))
    }

    /// A ticket of another project of the organisation shows its PRs and record; its thread rows open
    /// nothing there and say which project they are in (Invariant 5).
    @Test func threadRowsOfAnotherProjectSayWhere() {
        let t = ReviewThreadState(id: "T1", path: "src/export.go", line: 12)
        #expect(ticketThreadRow(t).elsewhere == nil)
        #expect(ticketThreadRow(t, elsewhere: "umbrella").elsewhere == "in project umbrella")
        var other = row(key: "INI-150", pr: 215, root: "/q/billing")
        other.project = "umbrella"
        #expect(ticketElsewhere(other, roots: ["/p/api", "/p/web"]) == "umbrella")
        #expect(ticketElsewhere(row(key: "INI-142"), roots: ["/p/api", "/p/web"]) == nil)
        #expect(ticketElsewhere(nil, roots: ["/p/api"]) == nil)
    }

    /// Walk 2026-10-29: a Landing ticket row says its state, never its conversation (that is Running's).
    /// Its words are the most urgent state; a handed agent that finished, with nothing more urgent,
    /// reads "agent finished" rather than the PR's "open".
    @Test func landingStateSaysTheAgentFinished() {
        let r = row(pr: 209, conversations: ["c2"])
        func state(_ live: [String: TicketHandOffLive], drafts: Int = 0) -> TicketUrgent {
            landingTicketState(ticketNeedsRows(InFlightState(inFlight: [r]), handoffs: live, drafts: [:])[0])
        }
        #expect(state([:]) == TicketUrgent(tier: 8, words: "#209 · open"))
        #expect(state(["c2": .working]) == TicketUrgent(tier: 7, words: "agent working"))
        #expect(state(["c2": .done]) == TicketUrgent(tier: 8, words: "agent finished"))
        #expect(state(["c2": .idle]) == TicketUrgent(tier: 8, words: "agent finished"))
        // Something more urgent still wins: a waiting thread is the operator's.
        let waiting = row(pr: 209, threads: ["T1"], conversations: ["c2"])
        let rows = ticketNeedsRows(InFlightState(waitingOnYou: [waiting], count: 1), handoffs: ["c2": .done], drafts: [:])
        #expect(landingTicketState(rows[0]).words == "#209 · 1 comment")
    }
}
