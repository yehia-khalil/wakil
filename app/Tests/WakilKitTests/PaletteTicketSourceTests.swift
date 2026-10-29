import Testing
import Foundation
@testable import WakilKit

/// `ticket_open`'s params for a fixture row: the key at its root and branch, with its PR.
func paletteTicketOpen(_ key: String?, root: String, branch: String, pr: Int) -> JSONValue {
    .object(["key": key.map { .string($0) } ?? .null, "root": .string(root), "branch": .string(branch),
             "pr": .integer(Int64(pr))])
}

/// Four tickets in flight, most urgent first, as the window maps them from `ticketNeedsRows`:
/// INI-142 with PR #212, a keyless PR #215, INI-150 with PR #214, and INI-160 whose PR no project
/// holds (no hand-off).
let paletteTicketFixtures: [PaletteTicket] = {
    let open142 = paletteTicketOpen("INI-142", root: "/src/api", branch: "ini-142-login", pr: 212)
    let open215 = paletteTicketOpen(nil, root: "/src/api", branch: "fix-retry", pr: 215)
    let open150 = paletteTicketOpen("INI-150", root: "/src/api", branch: "ini-150-billing", pr: 214)
    func handOff(_ open: JSONValue) -> JSONValue {
        guard case .object(var o) = open else { return open }
        o["from"] = .string("header")
        return .object(o)
    }
    return [
        PaletteTicket(id: "INI-142", title: "INI-142  Login org page", words: "#212 · 3 comments", key: "INI-142",
                      numbers: [142, 212],
                      prs: [PaletteTicketPR(id: "initech/api#212", title: "#212 ini-142-login", words: "#212 · 3 comments",
                                            open: open142)],
                      open: open142, handOff: handOff(open142), tier: 4, activity: "2026-10-27T10:00:00Z"),
        PaletteTicket(id: "initech/api#215", title: "#215 · api", words: "#215 · unit (Linux) failing", key: nil,
                      numbers: [215], prs: [], open: open215, handOff: handOff(open215), tier: 5,
                      activity: "2026-10-27T09:00:00Z"),
        PaletteTicket(id: "INI-150", title: "INI-150  Billing export", words: "#214 · review requested", key: "INI-150",
                      numbers: [150, 214],
                      prs: [PaletteTicketPR(id: "initech/api#214", title: "#214 ini-150-billing",
                                            words: "#214 · review requested", open: open150)],
                      open: open150, handOff: handOff(open150), tier: 6, activity: "2026-10-26T09:00:00Z"),
        PaletteTicket(id: "INI-160", title: "INI-160  Audit login", words: "#230 · review requested", key: "INI-160",
                      numbers: [160, 230], prs: [],
                      open: .object(["key": .string("INI-160"), "repo": .string("umbrella/web"), "pr": .integer(230)]),
                      handOff: nil, tier: 6, activity: "2026-10-25T09:00:00Z"),
    ]
}()

let paletteTicketKeys = ["INI"]

/// The ticket source over the fixtures, for `line`.
func paletteTicketSource(_ line: String) -> TicketSource {
    TicketSource(tickets: { paletteTicketFixtures }, query: { line }, keys: paletteTicketKeys)
}

@Suite struct PaletteTicketSourceTests {
    /// Opened empty, ⌘P is exactly today's list: the ticket source adds nothing.
    @Test func emptyLineListsNoTickets() async {
        let today: [any PaletteSource] = [
            RunningConversationsSource(conversations: { [] }),
            OpenPanesSource(panes: { [PaneSummary(id: "db-1", kind: "db", title: "Database", holds: "core")] }),
            NewPaneSource(),
        ]
        let before = await openModeEntries(today, timeout: .seconds(5))
        let after = await openModeEntries(today + [paletteTicketSource("")], timeout: .seconds(5))
        #expect(!before.isEmpty)
        #expect(after == before)
        #expect(await paletteTicketSource("   ").entries().isEmpty)
    }

    /// A key, in either case, the ticket's number or one of its PRs' puts the ticket and its PRs above
    /// every row — a Running conversation that names the same ticket included.
    @Test func keyQueryPutsTicketAndPRsAboveRunning() async {
        let running = PaletteEntry(
            id: "running:c1", group: .running, title: "INI-142 login 142 212", subtitle: "api · working",
            kindLabel: "conversation", verb: "switch to",
            action: .dispatch(action: "session_switch", params: .object(["conversation": .string("c1")])))
        let file = PaletteEntry(id: "editorfile:/src/api/142.go", group: .resources, title: "142.go", subtitle: "api",
                                kindLabel: "file", verb: "open", action: .openInEditor(path: "/src/api/142.go"))
        for q in ["INI-142", "ini-142", "142", "212"] {
            let tickets = await paletteTicketSource(q).entries()
            let ranked = PaletteSearch.rank([running, file] + tickets, query: q)
            #expect(Array(ranked.prefix(2).map(\.id)) == ["ticket:INI-142", "ticketpr:initech/api#212"], "\(q)")
            #expect(ranked.prefix(2).allSatisfy { $0.tier == .key }, "\(q)")
            #expect(ranked.contains { $0.id == running.id }, "\(q)")
            // The other tickets are below resources, never key-tier.
            #expect(tickets.filter { !$0.id.contains("142") && !$0.id.contains("212") }.allSatisfy { $0.tier == .belowResources }, "\(q)")
        }
        let row = await paletteTicketSource("ini-142").entries().first { $0.id == "ticket:INI-142" }
        #expect(row?.title == "INI-142  Login org page")
        #expect(row?.subtitle == "#212 · 3 comments")
        #expect(row?.kindLabel == "ticket")
        let pr = await paletteTicketSource("ini-142").entries().first { $0.id == "ticketpr:initech/api#212" }
        #expect(pr?.title == "#212 ini-142-login")
        #expect(pr?.kindLabel == "pull request")
        #expect(pr?.action == .dispatch(action: "ticket_open", params: paletteTicketFixtures[0].prs[0].open))
    }

    /// Key-shaped: a project key's pattern, or a bare number that is a ticket's or a PR's.
    @Test func keyShapedWords() {
        let numbers: Set<Int> = [142, 212]
        #expect(paletteKeyShaped("ini-142", projectKeys: ["INI"], numbers: numbers))
        #expect(paletteKeyShaped("ini-999", projectKeys: ["INI"], numbers: numbers))
        #expect(paletteKeyShaped("212", projectKeys: ["INI"], numbers: numbers))
        #expect(!paletteKeyShaped("213", projectKeys: ["INI"], numbers: numbers))
        #expect(!paletteKeyShaped("abc-142", projectKeys: ["INI"], numbers: numbers))
        #expect(!paletteKeyShaped("ini-", projectKeys: ["INI"], numbers: numbers))
        #expect(!paletteKeyShaped("login", projectKeys: ["INI"], numbers: numbers))
    }

    /// A review request on a repository no project holds has no ⌘↩: an agent needs a root.
    @Test func outsideRowHasNoAlternate() async {
        let rows = await paletteTicketSource("#").entries()
        let outside = rows.first { $0.id == "ticket:INI-160" }
        #expect(outside != nil)
        #expect(outside?.altAction == nil)
        #expect(outside?.altVerb == nil)
        let inside = rows.first { $0.id == "ticket:INI-142" }
        #expect(inside?.altVerb == "hand to agent")
        #expect(inside?.altAction != nil)
    }

    /// `#` lists every ticket, most urgent first, and no PR rows; words after it are the model's to filter.
    @Test func hashLineListsEveryTicketInUrgencyOrder() async {
        let rows = await paletteTicketSource("#login").entries()
        #expect(rows.map(\.id) == ["ticket:INI-142", "ticket:initech/api#215", "ticket:INI-150", "ticket:INI-160"])
    }

    /// The window's mapping from a `ticketNeedsRows` row: title `KEY  title`, a keyless PR by its name,
    /// PR rows `#212 branch`, numbers from the key and the PRs, no hand-off for a row no project holds.
    @Test func ticketNeedsRowMapsToAPaletteTicket() {
        let r = InFlightRowState(key: "INI-142", title: "Login org page", root: "/src/api", branch: "ini-142-login",
                                 pr: 212, repo: "initech/api", threads: ["t1", "t2", "t3"], activity: "2026-10-27T10:00:00Z")
        let row = TicketNeedsRow(id: "INI-142", key: "INI-142", title: "Login org page",
                                 urgent: TicketUrgent(tier: 4, words: "#212 · 3 comments"), rows: [r],
                                 activity: "2026-10-27T10:00:00Z", openable: true)
        let t = paletteTicket(row, prWords: { _ in "#212 · 3 comments" })
        #expect(t.title == "INI-142  Login org page")
        #expect(t.numbers == [142, 212])
        #expect(t.prs.map(\.title) == ["#212 ini-142-login"])
        #expect(t.open == ticketOpenParams(row))
        guard case .object(let h)? = t.handOff else { Issue.record("no hand-off"); return }
        #expect(h["from"] == .string("header"))
        #expect(h["key"] == .string("INI-142"))

        let outside = InFlightRowState(key: "", pr: 230, repo: "umbrella/web", review: true)
        let keyless = TicketNeedsRow(id: "umbrella/web#230", key: nil, title: "",
                                     urgent: TicketUrgent(tier: 6, words: "#230 · review requested"), rows: [outside],
                                     activity: "", openable: false)
        let k = paletteTicket(keyless, prWords: { _ in "" })
        #expect(k.title == "#230 · web")
        #expect(k.handOff == nil)
        #expect(k.prs.isEmpty)
        #expect(k.numbers == [230])
    }
}
