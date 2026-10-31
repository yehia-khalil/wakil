import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 3: the home's comp (amendment 2026-10-30, "the home, as the comp draws it") —
// NEEDS YOU, the compact card, quiet projects, the explainer, expansion kept, and Start in's plane.

private let api = Place(organization: "initech", project: "api", environment: "local")
private let web = Place(organization: "initech", project: "web", environment: "local")

private func ws(_ id: String, _ name: String, project: String = "api", tickets: [String] = [], parent: String? = nil,
                branch: String = "b", repos: [String] = ["/p/api"], environment: String = "local",
                created: String? = nil) -> Workspace {
    Workspace(id: id, name: name, slug: id, project: project, environment: environment, tickets: tickets,
              parent: parent, branch: branch,
              checkouts: repos.map { WorkspaceCheckout(repo: $0, path: "/w/\(id)/\(($0 as NSString).lastPathComponent)", branch: branch) },
              conversations: [], archived: false, created: created)
}

private func listing(_ w: Workspace, live: [String: ConversationState] = [:]) -> WorkspaceListing {
    WorkspaceListing(workspace: w, holders: [:], live: live)
}

private func conv(_ id: String, _ title: String, _ state: ConversationState = .idle, place: Place = api,
                  workspace: Workspace? = nil, ago: TimeInterval = 0) -> LiveConversation {
    var c = LiveConversation(id: id, session: "s-\(id)", place: place, title: title, state: state, onScreen: false,
                             lastActivity: Date(timeIntervalSince1970: 1_000_000 - ago))
    if let workspace { c.workspace = (workspace.id, workspace.name) }
    return c
}

private func ticket(_ key: String, branch: String = "", pr: Int = 0, failing: [String] = [], review: Bool = false,
                    threads: [String] = [], status: String = "", url: String = "", project: String = "api") -> TicketNeedsRow {
    let row = InFlightRowState(key: key, title: "Title of \(key)", status: status, branch: branch, pr: pr,
                               project: project, repo: "api", url: url, threads: threads, failing: failing, review: review)
    return TicketNeedsRow(id: key, key: key, title: "Title of \(key)", urgent: ticketUrgentState(row, handoffs: [:], drafts: 0),
                          rows: [row], activity: "", openable: true)
}

private func screen(_ workspaces: [WorkspaceListing] = [], live: [LiveConversation] = [], tickets: [TicketNeedsRow] = [],
                    projects: [String] = ["api", "web"], filter: String? = nil,
                    running: [String: String] = [:]) -> HomeScreen {
    homeScreen(HomeInput(organization: "initech", project: "api", environment: "local", projects: projects,
                         workspaces: workspaces, live: live, tickets: tickets, filter: filter, running: running))
}

// MARK: NEEDS YOU

@Test func needsYouListsEachWhyStrongestFirstOneRowPerWorkspaceOrMainConversation() {
    let waiting = ws("w1", "Retry webhook deliveries", tickets: ["INI-142"])
    let checks = ws("w2", "Rate-limit the partner API", tickets: ["INI-138"], branch: "ini-138")
    let flaky = ws("w3", "Fix the flaky checkout e2e", project: "web")
    let split = ws("w4", "Split the session store", project: "web", tickets: ["INI-151"])
    let s = screen(
        [listing(waiting), listing(checks), listing(flaky), listing(split)],
        live: [conv("c1", "Move the signer", .waiting, workspace: waiting, ago: 50),
               conv("c3", "Run the e2e", .failed, place: web, workspace: flaky, ago: 40),
               conv("c4", "Split it", .done, place: web, workspace: split, ago: 1),
               conv("m1", "Why is the queue backing up?", .working)],
        tickets: [ticket("INI-138", branch: "ini-138", pr: 9, failing: ["lint", "unit"], review: true,
                         url: "https://github.com/initech/api/pull/9")])
    #expect(s.needs.map(\.title) == ["Retry webhook deliveries", "Fix the flaky checkout e2e",
                                     "Rate-limit the partner API", "Split the session store"],
            "waiting › failed › checks › done; a working conversation needs nothing")
    #expect(s.needs.map(\.why) == ["waiting on you", "failed", "checks failing 2 · review requested", "done, unseen"],
            "review requested rides on the checks row: the same workspace, one row")
    #expect(s.needs.map(\.hue) == [.waiting, .failed, .failed, .done])
    #expect(s.needs.map(\.key) == ["INI-142", nil, "INI-138", "INI-151"])
    #expect(s.needs.map(\.project) == ["api", "web", "api", "web"])
}

@Test func aNeedsRowsActionIsItsStrongestReasons() {
    let waiting = ws("w1", "A")
    let checks = ws("w2", "B", tickets: ["INI-2"], branch: "ini-2")
    let s = screen([listing(waiting), listing(checks)],
                   live: [conv("c1", "one", .waiting, workspace: waiting),
                          conv("m1", "in Main", .failed), conv("m2", "finished", .done)],
                   tickets: [ticket("INI-2", branch: "ini-2", pr: 4, failing: ["lint"],
                                    url: "https://github.com/initech/api/pull/4")])
    let byTitle = Dictionary(uniqueKeysWithValues: s.needs.map { ($0.title, $0) })
    #expect(byTitle["A"]?.action == .review(conversation: "c1", session: "s-c1"))
    #expect(byTitle["A"]?.action.label == "Review")
    #expect(byTitle["B"]?.action == .link(url: "https://github.com/initech/api/pull/4/checks"))
    #expect(byTitle["B"]?.action.label == "checks ↗")
    #expect(byTitle["B"]?.opens == .workspace("w2"), "the row itself opens the workspace")
    #expect(byTitle["in Main"]?.action == .open(conversation: "m1", session: "s-m1"))
    #expect(byTitle["in Main"]?.action.label == "Open")
    #expect(byTitle["in Main"]?.workspace == nil, "a Main conversation is its own row")
    #expect(byTitle["finished"]?.why == "done, unseen")
}

@Test func aChecksRowWithNoPRLinkOpensItsWorkspace() {
    let checks = ws("w2", "B", tickets: ["INI-2"], branch: "ini-2")
    let s = screen([listing(checks)], tickets: [ticket("INI-2", branch: "ini-2", pr: 4, failing: ["lint"])])
    #expect(s.needs.first?.why == "checks failing 1")
    #expect(s.needs.first?.action == .openWorkspace("w2"))
    #expect(s.needs.first?.action.label == "Open")
}

@Test func commentsAndAReviewAloneAreNeedsToo() {
    let w = ws("w1", "A", tickets: ["INI-1"], branch: "ini-1")
    let s = screen([listing(w)], tickets: [ticket("INI-1", branch: "ini-1", pr: 3, review: true, threads: ["t1", "t2"],
                                                  url: "https://github.com/initech/api/pull/3")])
    #expect(s.needs.first?.why == "review requested · 2 comments")
    #expect(s.needs.first?.hue == .waiting, "a review asked is amber; only failing checks are red")
    #expect(s.needs.first?.action == .link(url: "https://github.com/initech/api/pull/3"))
    #expect(s.needs.first?.action.label == "review ↗")
}

@Test func aPillCountsItsProjectsNeedsRowsAndTheFilterNarrowsNeedsYou() {
    let a = ws("w1", "A"), b = ws("w2", "B"), c = ws("w3", "C", project: "web")
    let live = [conv("c1", "one", .waiting, workspace: a), conv("c2", "two", .failed, workspace: b),
                conv("c3", "three", .done, place: web, workspace: c)]
    let all = screen([listing(a), listing(b), listing(c)], live: live)
    #expect(all.pills.map(\.label) == ["All projects", "api", "web"])
    #expect(all.pills.map(\.needsYou) == [3, 2, 1])
    let narrowed = screen([listing(a), listing(b), listing(c)], live: live, filter: "web")
    #expect(narrowed.needs.map(\.title) == ["C"])
}

// MARK: the compact card

@Test func aCompactCardCountsWhatNeedsYouTicketReasonsOnce() {
    let w = ws("w1", "A", tickets: ["INI-1"], branch: "ini-1")
    let s = screen([listing(w)], live: [conv("c1", "one", .waiting, workspace: w), conv("c2", "two", .done, workspace: w)],
                   tickets: [ticket("INI-1", branch: "ini-1", pr: 3, failing: ["lint"], review: true)])
    let card = s.sections[0].cards[0]
    #expect(card.needCount == 3, "two conversations, and the ticket's reasons as one")
    #expect(card.hue == .waiting, "the dot takes its strongest need")
    let quiet = screen([listing(ws("w2", "B"))]).sections[0].cards[0]
    #expect(quiet.needCount == 0 && quiet.hue == .idle)
    let working = screen([listing(ws("w3", "C"))], live: [conv("c3", "go", .working, workspace: ws("w3", "C"))])
    #expect(working.sections[0].cards[0].hue == .working)
}

@Test func aCompactCardTagsItsEnvironmentOnlyWhenItDiffersFromTheProjectsOrIsProduction() {
    func card(_ env: String, defaults: [String: String] = [:], project: String = "api") -> HomeCard {
        homeScreen(HomeInput(organization: "initech", project: "api", environment: "local", projects: ["api", "web"],
                             workspaces: [listing(ws("w1", "A", project: project, environment: env))],
                             defaultEnvironments: defaults)).sections[0].cards[0]
    }
    #expect(card("local").environmentTag == nil, "the window's environment is the current project's default")
    #expect(card("staging").environmentTag == "staging")
    #expect(card("production").environmentTag == "production", "production always shows, red (Invariant 8)")
    #expect(card("staging", project: "web").environmentTag == nil, "no default known for another project: no claim")
    #expect(card("staging", defaults: ["web": "local"], project: "web").environmentTag == "staging")
}

@Test func aCompactCardShowsItsPortsWhileSomethingRunsAndRunWhileNothingDoes() {
    let w = ws("w1", "A")
    let running = screen([listing(w)], running: ["w1": "api running on :41200 · queue running"]).sections[0].cards[0]
    #expect(running.runningCompact == ":41200")
    #expect(!running.offersRun, "Stop, not ▶, while something runs")
    let idle = screen([listing(w)]).sections[0].cards[0]
    #expect(idle.runningCompact == nil && idle.offersRun)
    var none = ws("w2", "B")
    none.checkouts[0].path = nil
    #expect(!screen([listing(none)]).sections[0].cards[0].offersRun, "no copy on disk: nothing to run")
    #expect(homeRunningPorts("api running on :41200 · web running on :41201") == ":41200 :41201")
    #expect(homeRunningPorts("queue running") == "running", "something runs with no port: said so")
    // The walk: a run getting going reads its step, its command and the time so far, whole.
    #expect(homeRunningPorts("api setup · composer install · 1 min 4 s") == "api setup · composer install · 1 min 4 s")
}

@Test func aChildIsDrawnAsItsOwnRowAfterItsParentBranchedOffItsKey() {
    let parent = ws("p", "Move webhook signing", tickets: ["INI-140"])
    let child = ws("c", "Try HMAC-SHA512", tickets: ["INI-140"], parent: "p")
    let s = screen([listing(parent), listing(child)])
    #expect(s.sections[0].cards.map(\.id) == ["p"])
    #expect(s.sections[0].cards[0].children.map(\.branchedOff) == ["INI-140"])
}

@Test func aProjectsCountSaysWorkspacesAndMainOrConversationsInMain() {
    let w = ws("w1", "A")
    #expect(screen([listing(w)], live: [conv("m", "q")]).sections[0].summary == "1 workspace · Main")
    #expect(screen(live: [conv("m", "q")]).sections[0].summary == "1 conversation in Main")
    #expect(screen(live: [conv("m", "q"), conv("n", "r")]).sections[0].summary == "2 conversations in Main")
}

@Test func aConversationLineSaysItsStateInWords() {
    let w = ws("w1", "A")
    let s = screen([listing(w)], live: [conv("c1", "one", .waiting, workspace: w), conv("c2", "two", .done, workspace: w),
                                        conv("m", "three", .working)])
    #expect(s.sections[0].main?.lines.map(\.words) == ["working"])
    #expect(s.sections[0].cards[0].lines.map(\.words).sorted() == ["done", "waiting on you"])
}

// MARK: quiet projects, the explainer

@Test func projectsWithNothingGoingOnFoldIntoOneLineThatNamesThem() {
    let s = screen(live: [conv("m", "q")], projects: ["api", "web", "portal"])
    #expect(s.sections.map(\.project) == ["api"])
    #expect(s.quiet == ["web", "portal"])
    #expect(s.quietCount == "2 quiet projects")
    #expect(s.pills.isEmpty, "one project on the page: a filter would do nothing")
    let one = screen(projects: ["api"])
    #expect(one.sections.isEmpty && one.quiet == ["api"] && one.quietCount == "1 quiet project")
    #expect(!one.firstRun, "a project exists: not the first run")
}

@Test func theExplainerShowsOnTheFirstRunOnly() {
    let first = screen(projects: [])
    #expect(first.firstRun)
    #expect(HomeScreen.explainer.count == 2)
    #expect(!screen(live: [conv("m", "q")], projects: []).firstRun, "something live: not the first run")
    #expect(!screen(projects: ["api"]).firstRun)
}

// MARK: tickets

@Test func aTicketIsStartedOnceAWorkspaceOrALiveConversationCarriesIt() {
    let w = ws("w1", "A", tickets: ["INI-1"])
    let rows = [ticket("INI-1"), ticket("INI-2"), ticket("INI-3")]
    #expect(homeTicketStarted(rows[0], workspaces: [w], live: []))
    #expect(!homeTicketStarted(rows[1], workspaces: [w], live: []))
    #expect(homeTicketStarted(rows[2], workspaces: [], live: [conv("c", "INI-3 · go")]))
    let s = screen([listing(w)], tickets: rows)
    #expect(s.ticketsNotStarted.map(\.key) == ["INI-2", "INI-3"])
}

@Test func aTicketRowSaysItsTrackersStatusElseItsState() {
    #expect(homeTicketStatus(ticket("INI-1", status: "In progress")) == "In progress")
    #expect(homeTicketStatus(ticket("INI-2", pr: 4)) == "#4 · open")
}

// MARK: expansion, kept across relaunch (Rule 6)

@Test func aCardsExpansionIsKeptPerWorkspaceAcrossRelaunch() throws {
    let suite = "home-expansion-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HomeExpansionStore(defaults: defaults)
    #expect(!store.isExpanded("w1"), "compact by default")
    store.toggle("w1")
    store.toggle("w2")
    store.toggle("w2")
    let relaunched = HomeExpansionStore(defaults: defaults)
    #expect(relaunched.isExpanded("w1") && !relaunched.isExpanded("w2"))
}

// MARK: Start in, Wakil's own plane

@Test func startInsRowsAreGroupedByProjectAndTagNowAndProduction() {
    let choices = homeStartChoices(projects: ["api", "web", "portal"], current: api, environments: ["local", "staging", "production"],
                                   lastEnvironment: ["web": "local", "portal": "staging"])
    #expect(homeStartGroups(choices).map { $0.map(\.label) } ==
            [["api · local", "api · staging", "api · production"], ["web · local"], ["portal · staging"]])
    #expect(choices.map(\.tag) == ["now", nil, "production", nil, nil])
    #expect(homeStartMove(0, by: -1, count: 5) == 0 && homeStartMove(4, by: 1, count: 5) == 4)
    #expect(homeStartMove(1, by: 1, count: 5) == 2)
}
