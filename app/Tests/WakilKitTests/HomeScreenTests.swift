import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 3: the home screen, decided (spec, piece 3; decisions 18–26).

private let staging = Place(organization: "initech", project: "estate", environment: "staging")
private let web = Place(organization: "initech", project: "dashboard", environment: "staging")

private func ws(_ id: String, _ name: String, project: String = "estate", tickets: [String] = [],
                parent: String? = nil, branch: String = "b", repos: [String] = ["/p/api"], archived: Bool = false,
                conversations: [String] = [], created: String? = nil, environment: String = "staging") -> Workspace {
    Workspace(id: id, name: name, slug: id, project: project, environment: environment, tickets: tickets,
              parent: parent, branch: branch,
              checkouts: repos.map { WorkspaceCheckout(repo: $0, path: "/w/\(id)/\(($0 as NSString).lastPathComponent)", branch: branch) },
              conversations: conversations, archived: archived, created: created)
}

private func listing(_ w: Workspace, holders: [String: String] = [:], live: [String: ConversationState] = [:]) -> WorkspaceListing {
    WorkspaceListing(workspace: w, holders: holders, live: live)
}

private func conv(_ id: String, _ title: String, _ state: ConversationState = .idle, place: Place = staging,
                  workspace: Workspace? = nil, ago: TimeInterval = 0) -> LiveConversation {
    var c = LiveConversation(id: id, session: "s-\(id)", place: place, title: title, state: state, onScreen: false,
                             lastActivity: Date(timeIntervalSince1970: 1_000_000 - ago))
    if let workspace { c.workspace = (workspace.id, workspace.name) }
    return c
}

private func ticket(_ key: String, branch: String = "", pr: Int = 0, failing: [String] = [], review: Bool = false,
                    project: String = "estate", tier: Int = 8) -> TicketNeedsRow {
    TicketNeedsRow(id: key, key: key, title: "Title of \(key)",
                   urgent: TicketUrgent(tier: tier, words: tier <= 6 ? "#\(pr) · review requested" : "#\(pr) · open"),
                   rows: [InFlightRowState(key: key, branch: branch, pr: pr, project: project, repo: "api",
                                           failing: failing, review: review)],
                   activity: "", openable: true)
}

/// Amendment 2026-10-30 — the home is the organisation's: no project is selected on it, so none is
/// pinned first or marked; projects go by latest activity, and one with nothing going on is not drawn.
@Test func theHomeIsTheOrganisationsGroupedByProjectByLatestActivity() {
    let a = ws("w1", "Login rate limit", tickets: ["INI-142"])
    let b = ws("w2", "Exception pages", project: "dashboard")
    let screen = homeScreen(HomeInput(
        organization: "initech", project: "estate", environment: "staging", projects: ["dashboard", "estate", "mobile"],
        workspaces: [listing(a), listing(b)],
        live: [conv("c2", "Fix exception pages", .working, place: web, workspace: b, ago: 0)]))
    #expect(screen.sections.map(\.project) == ["dashboard", "estate"], "the latest first; a project with nothing is not drawn")
    #expect(screen.pills.map(\.label) == ["All projects", "dashboard", "estate"])
    #expect(screen.quiet == ["mobile"], "folded into the quiet line, by name")
}

@Test func aProjectWithNothingGoingOnIsNotDrawnOnceSomethingIsGoingOnElsewhere() {
    let b = ws("w2", "Exception pages", project: "dashboard")
    let screen = homeScreen(HomeInput(organization: "initech", project: "estate", environment: "staging",
                                      projects: ["dashboard", "estate"], workspaces: [listing(b)]))
    #expect(screen.sections.map(\.project) == ["dashboard"])
}

@Test func aPillFiltersTheSameScreenAndKeepsEveryPill() {
    let a = ws("w1", "A")
    let b = ws("w2", "B", project: "dashboard")
    var input = HomeInput(organization: "initech", project: "estate", environment: "staging",
                          workspaces: [listing(a), listing(b)])
    input.filter = "dashboard"
    let screen = homeScreen(input)
    #expect(screen.sections.map(\.project) == ["dashboard"])
    #expect(screen.pills.count == 3 && screen.pills.first { $0.selected }?.project == "dashboard")
}

@Test func onlyOneProjectDrawsNoPills() {
    let screen = homeScreen(HomeInput(organization: "o", project: "estate", environment: "staging",
                                      workspaces: [listing(ws("w1", "A"))]))
    #expect(screen.pills.isEmpty)
}

@Test func mainIsDrawnWhileAConversationIsInItWithItsLinesFirst() {
    let a = ws("w1", "A")
    let screen = homeScreen(HomeInput(
        organization: "initech", project: "estate", environment: "staging", workspaces: [listing(a, live: ["c2": .working])],
        live: [conv("c1", "Why is OTP capped at 5?", ago: 10), conv("c2", "Rebase", .working, workspace: a)]))
    let s = screen.sections[0]
    #expect(s.main?.lines.map(\.title) == ["Why is OTP capped at 5?"])
    #expect(s.main?.lines.first?.words == "idle", "no read only, no holds (walk)")
    #expect(s.cards.first?.lines.map(\.title) == ["Rebase"])
    #expect(screen.lines.map(\.index) == [0, 1], "lines are numbered in drawing order")
    #expect(s.summary == "1 workspace · Main")
}

@Test func cardsThatNeedTheOperatorComeFirstThenWorkingThenTheRestNewestFirst() {
    let quiet = ws("q", "Quiet", created: "2026-10-29T10:00:00Z")
    let newer = ws("n", "Newer quiet", created: "2026-10-29T11:00:00Z")
    let busy = ws("b", "Busy")
    let needy = ws("x", "Needs you")
    let screen = homeScreen(HomeInput(
        organization: "initech", project: "estate", environment: "staging",
        workspaces: [listing(quiet), listing(newer), listing(busy, live: ["c1": .working]), listing(needy, live: ["c2": .waiting])],
        live: [conv("c1", "one", .working, workspace: busy), conv("c2", "two", .waiting, workspace: needy)]))
    #expect(screen.sections[0].cards.map(\.name) == ["Needs you", "Busy", "Newer quiet", "Quiet"])
    let needs = screen.sections[0].cards[0]
    #expect(needs.needCount == 1 && screen.needs.map(\.why) == ["waiting on you"])
    #expect(needs.archiveAsks, "Archive asks only with a conversation waiting (Rule 1)")
    #expect(!screen.sections[0].cards[1].archiveAsks)
}

@Test func aCardShowsEveryRepoWithItsBranchOrInMainAndItsPRs() {
    var a = ws("w1", "Stop persisting logs", tickets: ["INI-1728"], branch: "INI-1728-logs",
               repos: ["/p/api", "/p/web", "/p/core"])
    a.checkouts[2].inMain = true
    a.checkouts[2].path = nil
    let screen = homeScreen(HomeInput(
        organization: "initech", project: "estate", environment: "staging",
        workspaces: [listing(a, holders: ["/p/api": "c1"], live: ["c1": .working])],
        live: [conv("c1", "Rebase all", .working, workspace: a)],
        tickets: [ticket("INI-1728", pr: 7, failing: ["lint"], tier: 5), ticket("INI-1", branch: "INI-1728-logs", pr: 8)]))
    let card = screen.sections[0].cards[0]
    #expect(card.key == "INI-1728" && card.name == "Stop persisting logs")
    #expect(card.repos.map(\.words) == ["INI-1728-logs", "INI-1728-logs", "in Main"])
    a.checkouts[1].path = nil
    #expect(homeScreen(HomeInput(organization: "initech", project: "estate", environment: "staging",
                                 workspaces: [listing(a)])).sections[0].cards[0].repos[1].words == "INI-1728-logs · not copied",
            "a repo never copied stays listed")
    #expect(card.repoCount == "3 repos")
    #expect(card.bringHome.map(\.name) == ["api", "web"], "Bring to Main offers the repos with a copy")
    #expect(card.prs == "2 PRs open · 1 failing")
    #expect(card.lines.first?.words == "working")
    #expect(card.opens == "c1")
    #expect(screen.ticketsNotStarted.isEmpty, "both tickets are this workspace's: by key, and by branch")
}

@Test func aChildIsDrawnUnderItsParentAndOnItsOwnOnceTheParentIsArchived() {
    let parent = ws("p", "Exception handling")
    let child = ws("c", "Try a shared layout", parent: "p")
    var screen = homeScreen(HomeInput(organization: "o", project: "estate", environment: "staging",
                                      workspaces: [listing(parent), listing(child)]))
    #expect(screen.sections[0].cards.map(\.name) == ["Exception handling"])
    #expect(screen.sections[0].cards[0].children.map(\.name) == ["Try a shared layout"])
    var gone = parent
    gone.archived = true
    screen = homeScreen(HomeInput(organization: "o", project: "estate", environment: "staging",
                                  workspaces: [listing(gone), listing(child)]))
    #expect(screen.sections[0].cards.map(\.name) == ["Try a shared layout"])
    #expect(screen.sections[0].cards[0].branchedFrom == "Exception handling")
    #expect(screen.earlier.archived.map(\.name) == ["Exception handling"])
}

@Test func moveOffersTheProjectsConversationsElsewhereHoldingNoCopy() {
    let a = ws("w1", "A")
    let b = ws("w2", "B")
    let screen = homeScreen(HomeInput(
        organization: "initech", project: "estate", environment: "staging",
        workspaces: [listing(a), listing(b, holders: ["/p/api": "held"], live: ["held": .idle])],
        live: [conv("main", "in Main"), conv("held", "holds one", workspace: b), conv("other", "elsewhere", place: web)]))
    let card = screen.sections.first { $0.project == "estate" }!.cards.first { $0.id == "w1" }!
    #expect(card.moveCandidates.map(\.title) == ["in Main"], "decision 6: one holding a copy is not moved; another project's never")
}

@Test func ticketsNotStartedHereAreThoseNoWorkspaceCarries() {
    let a = ws("w1", "A", tickets: ["INI-1"])
    let screen = homeScreen(HomeInput(organization: "o", project: "estate", environment: "staging",
                                      workspaces: [listing(a)], tickets: [ticket("INI-1"), ticket("INI-2", tier: 6)]))
    #expect(screen.ticketsNotStarted.map(\.key) == ["INI-2"])
}

/// The walk: AQ247-141 stayed under *not started* while "AQ247-141 · Work toward Next." worked in Main.
@Test func aTicketALiveConversationCarriesIsStarted() {
    var handed = conv("c2", "Rebase the walk", .working)
    handed = LiveConversation(id: handed.id, session: handed.session, place: handed.place, title: handed.title,
                              state: .working, onScreen: false, lastActivity: handed.lastActivity,
                              handoff: PlaceAgentHandoff(key: nil, pr: 3, thread: nil, root: "/r", branch: "ini-3-walk",
                                                         mayPush: false))
    let screen = homeScreen(HomeInput(
        organization: "initech", project: "estate", environment: "staging",
        live: [conv("c1", "INI-1 · Work toward Next.", .working), handed, conv("c3", "about MINI-20 notes")],
        tickets: [ticket("INI-1"), ticket("INI-2"), ticket("INI-3", branch: "ini-3-walk"), ticket("INI-20")]))
    #expect(screen.ticketsNotStarted.map(\.key) == ["INI-2", "INI-20"],
            "its key in the title, or the branch a hand-off works on; MINI-20 is not INI-20")
}

@Test func earlierGroupsPastConversationsByWorkspaceAndCountsThem() {
    var a = ws("w1", "Login rate limit", conversations: ["root-1"])
    a.archived = true
    let screen = homeScreen(HomeInput(
        organization: "o", project: "estate", environment: "staging", workspaces: [listing(a)],
        past: [HomePastConversation(id: "s3", title: "asked", subtitle: "", chain: ["s3"]),
               HomePastConversation(id: "s2", title: "rate limit", subtitle: "", chain: ["s2", "root-1"]),
               HomePastConversation(id: "s1", title: "older", subtitle: "", chain: ["s1"])]))
    #expect(screen.earlier.past.map(\.name) == ["Main", "Login rate limit"])
    #expect(screen.earlier.past[0].conversations.map(\.title) == ["asked", "older"])
    #expect(screen.earlier.line == "Earlier — 1 archived workspace · 3 past conversations")
    #expect(homeScreen(HomeInput(organization: "o", project: "e", environment: "s")).earlier.line == nil)
}

@Test func productionStaysRedOnACard() {
    let prod = ws("w1", "Hotfix", environment: "production")
    let screen = homeScreen(HomeInput(organization: "o", project: "estate", environment: "staging",
                                      workspaces: [listing(prod)]))
    #expect(screen.sections[0].cards[0].isProduction)
    let flagged = homeScreen(HomeInput(organization: "o", project: "estate", environment: "staging",
                                       workspaces: [listing(ws("w2", "Live", environment: "live"))],
                                       isProduction: { _, e in e == "live" }))
    #expect(flagged.sections[0].cards[0].isProduction, "the project's own flag wins over the name")
}

// MARK: the composer's picker (decision 19)

@Test func thePickerOffersTheCurrentPlaceFirstThenItsEnvironmentsThenOtherProjects() {
    let choices = homeStartChoices(
        projects: ["dashboard", "estate", "mobile"], current: staging, environments: ["staging", "production"],
        lastEnvironment: ["mobile": "local"])
    #expect(choices.map(\.label) == ["estate · staging", "estate · production", "dashboard", "mobile · local"])
    #expect(choices.map(\.current) == [true, false, false, false], "pre-set to where the operator is (Rule 9)")
    #expect(choices[1].isProduction, "production stays red in the picker (Invariant 8)")
}

/// Amendment 2026-10-30: Start in shows where a send goes, so the placeholder names no place.
@Test func theHomesComposerSaysAskOrNameWhatToOpen() {
    #expect(homeComposerPlaceholder == "Ask, or name what to open")
}

// Decision 11: the card offers Archive once every PR of the workspace is merged.

private func pr(_ number: Int, _ state: String, head: String = "logs") -> PullRequestState {
    PullRequestState(number: number, state: state, head: head)
}

@Test func aCardOffersArchiveOnceEveryPROfItsBranchesIsMerged() {
    let a = ws("w1", "Stop persisting logs", branch: "logs", repos: ["/p/api", "/p/web"])
    func card(_ reads: [HomeBranch: [PullRequestState]]) -> HomeCard {
        homeScreen(HomeInput(organization: "initech", project: "estate", environment: "staging",
                             workspaces: [listing(a)], branchPRs: reads)).sections[0].cards[0]
    }
    let api = HomeBranch(root: "/p/api", branch: "logs"), web = HomeBranch(root: "/p/web", branch: "logs")

    #expect(card([:]).merged == nil, "nothing read: no offer")
    #expect(card([api: [pr(7, "merged")], web: []]).merged == "1 PR merged", "a repo with no PR is not one of its PRs")
    #expect(card([api: [pr(7, "merged")], web: [pr(8, "merged")]]).merged == "2 PRs merged")
    #expect(card([api: [pr(7, "merged")], web: [pr(8, "open")]]).merged == nil, "one still open")
    #expect(card([api: [pr(7, "merged")], web: [pr(8, "closed")]]).merged == nil, "closed is not merged")
    #expect(card([api: [pr(7, "merged")]]).merged == nil, "web's branch not read yet")
    #expect(card([api: [], web: []]).merged == nil, "no PR at all: nothing merged to offer on")

    let b = ws("w2", "Older", branch: "older", repos: ["/p/api"], created: "2026-01-01T00:00:00Z")
    let screen = homeScreen(HomeInput(
        organization: "initech", project: "estate", environment: "staging", workspaces: [listing(a), listing(b)],
        branchPRs: [api: [pr(7, "merged")], web: [], HomeBranch(root: "/p/api", branch: "older"): [pr(3, "open", head: "older")]]))
    #expect(screen.mergedOffers == ["w1"], "numbered in drawing order, only the cards offering")
}

@Test func theBranchesAHomeReadsForTheOfferAreItsOpenWorkspacesCheckouts() {
    var a = ws("w1", "Logs", branch: "logs", repos: ["/p/api", "/p/web"])
    a.checkouts[1].branch = ""
    let gone = ws("w2", "Old", branch: "old", repos: ["/p/api"], archived: true)
    #expect(homeMergedReads([a, gone]) == [HomeBranch(root: "/p/api", branch: "logs")])
}

// Piece 2's Run on the card (spec, piece 3's card and piece 2's Run, Stop, Build): the PRs line
// carries what runs, `· Stop` beside it; ▶ Run offers each repo with a copy.

@Test func aCardsLineCarriesWhatRunsAndRunOffersEachCopy() {
    var a = ws("w1", "Login", tickets: ["INI-142"], branch: "INI-142-login", repos: ["/p/api", "/p/web", "/p/core"])
    a.checkouts[2].path = nil
    a.checkouts[1].inMain = true
    let rows = [ticket("INI-142", branch: "INI-142-login", pr: 7)]
    func card(_ running: [String: String]) -> HomeCard {
        homeScreen(HomeInput(organization: "initech", project: "estate", environment: "staging",
                             workspaces: [listing(a)], tickets: rows, running: running)).sections[0].cards[0]
    }
    #expect(card([:]).running == nil)
    #expect(card([:]).prs == "1 PR open")
    let running = card(["w1": "api running on :41200 · queue running"])
    #expect(running.running == "api running on :41200 · queue running")
    #expect(card(["w1": ""]).running == nil, "nothing runs: no line, no Stop")
    #expect(card([:]).runnable.map(\.name) == ["api"], "a copy on disk, not one brought to Main or not made")

    let b = ws("w2", "Quiet", repos: ["/p/api"])
    let quiet = homeScreen(HomeInput(organization: "initech", project: "estate", environment: "staging",
                                     workspaces: [listing(b)], running: ["w2": "api running on :41210"])).sections[0].cards[0]
    #expect(quiet.prs == nil && quiet.runningCompact == ":41210", "no PR: the compact row still says what runs")
}

// The walk: a ready run's card links its app (`:41210 ↗`), the root on the repo's port, never `/up`.
@Test func aReadyRunsCardLinksItsAppsRootOnEachPort() {
    let b = ws("w2", "Quiet", repos: ["/p/api"])
    func card(_ ports: [String: [Int]]) -> HomeCard {
        homeScreen(HomeInput(organization: "initech", project: "estate", environment: "staging",
                             workspaces: [listing(b)], running: ["w2": "api running on :41210"],
                             runningPorts: ports)).sections[0].cards[0]
    }
    #expect(card([:]).appLinks.isEmpty, "still getting going: no link")
    let ready = card(["w2": [41210, 41220]])
    #expect(ready.appLinks.map(\.label) == [":41210", ":41220"])
    #expect(ready.appLinks.map(\.url) == ["http://localhost:41210/", "http://localhost:41220/"])
}

// Invariant 8 beyond the screen's project: Start in lists every project's real environments, each
// judged production by its own declaration.

@Test func startInListsEachProjectsEnvironmentsJudgedByItsOwnDeclaration() {
    let envs = OrgEnvironments(projects: [
        "dashboard": [.init(name: "live", production: true), .init(name: "local", production: false)],
        "mobile": [.init(name: "production", production: false)],
    ])
    let judge = envs.judge(current: "estate", flags: EnvironmentProduction(declarations: ["staging": false]))
    let choices = homeStartChoices(
        projects: ["dashboard", "estate", "mobile", "spare"], current: staging, environments: ["staging", "production"],
        otherEnvironments: envs.names, lastEnvironment: ["dashboard": "local"], isProduction: judge)
    #expect(choices.map(\.label) ==
            ["estate · staging", "estate · production", "dashboard · local", "dashboard · live", "mobile · production", "spare"],
            "the environment last in first, then the rest; a project with none read keeps its one row")
    #expect(choices.map(\.isProduction) == [false, true, false, true, false, false])
    #expect(choices.map(\.tag) == ["now", "production", nil, "production", nil, nil])
}

@Test func anEnvironmentAnswersByItsProjectsDeclarationElseByItsName() {
    let envs = OrgEnvironments(projects: ["web": [.init(name: "Live ", production: true), .init(name: "old", production: nil)]])
    let judge = envs.judge(current: "api", flags: EnvironmentProduction(declarations: ["live": false]))
    #expect(judge("web", "live"), "folded like every other environment name")
    #expect(!judge("api", "live"), "the screen's project by the window's own flags")
    #expect(!judge("web", "old") && judge("web", "production"), "nothing declared: the name")
    #expect(judge("unknown", "production") && !judge("unknown", "prod"))
    #expect(!OrgEnvironments.unread.judge(current: "api", flags: .undeclared)("web", "live"))
}

/// The scenario audit: a card's Run, Stop and run error carried its workspace's generated id, so no
/// check could address them. They carry the card's number on the home, in drawing order — each
/// project's cards, a child straight after its parent.
@Test func cardsAreNumberedInDrawingOrderAChildAfterItsParent() {
    let screen = homeScreen(HomeInput(
        organization: "o", project: "estate", environment: "staging", projects: ["estate", "dashboard"],
        workspaces: [listing(ws("p", "Exception handling", created: "2026-10-01T00:00:00Z")),
                     listing(ws("c", "Try a shared layout", parent: "p")),
                     listing(ws("d", "Charts", project: "dashboard"))]))
    let drawn = screen.sections.flatMap { s in s.cards.flatMap { [$0.id] + $0.children.map(\.id) } }
    #expect(screen.cardOrder == drawn)
    #expect(screen.cardOrder.count == 3 && screen.cardOrder.firstIndex(of: "c") == screen.cardOrder.firstIndex(of: "p")! + 1)
}
