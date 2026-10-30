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

@Test func theHomeIsTheOrganisationsGroupedByProjectTheCurrentFirst() {
    let a = ws("w1", "Login rate limit", tickets: ["INI-142"])
    let b = ws("w2", "Exception pages", project: "dashboard")
    let screen = homeScreen(HomeInput(
        organization: "initech", project: "estate", environment: "staging", projects: ["dashboard", "estate", "mobile"],
        workspaces: [listing(a), listing(b)],
        live: [conv("c2", "Fix exception pages", .working, place: web, workspace: b, ago: 0)]))
    #expect(screen.title == "Work in initech")
    #expect(screen.sections.map(\.project) == ["estate", "dashboard"], "the current first; a project with nothing is not drawn")
    #expect(screen.sections[0].current && !screen.sections[1].current)
    #expect(screen.pills.map(\.label) == ["All projects", "estate", "dashboard"])
}

@Test func theCurrentProjectIsDrawnEvenWithNothingGoingOn() {
    let b = ws("w2", "Exception pages", project: "dashboard")
    let screen = homeScreen(HomeInput(organization: "initech", project: "estate", environment: "staging",
                                      workspaces: [listing(b)]))
    #expect(screen.sections.map(\.project) == ["estate", "dashboard"])
    #expect(screen.sections[0].summary == "nothing going on")
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
    #expect(s.main?.lines.first?.detail == "idle · read only")
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
    #expect(needs.needs == "‘two’ is waiting for you")
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
    #expect(card.repoCount == "3 repos")
    #expect(card.bringHome.map(\.name) == ["api", "web"], "Bring to Main offers the repos with a copy")
    #expect(card.prs == "2 PRs open · 1 failing")
    #expect(card.lines.first?.detail == "working · holds api")
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
    let card = screen.sections[0].cards.first { $0.id == "w1" }!
    #expect(card.moveCandidates.map(\.title) == ["in Main"], "decision 6: one holding a copy is not moved; another project's never")
}

@Test func ticketsNotStartedHereAreThoseNoWorkspaceCarries() {
    let a = ws("w1", "A", tickets: ["INI-1"])
    let screen = homeScreen(HomeInput(organization: "o", project: "estate", environment: "staging",
                                      workspaces: [listing(a)], tickets: [ticket("INI-1"), ticket("INI-2", tier: 6)]))
    #expect(screen.ticketsNotStarted.map(\.key) == ["INI-2"])
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
    #expect(screen.earlier.line == "Earlier — 1 archived workspace, 3 past conversations")
    #expect(homeScreen(HomeInput(organization: "o", project: "e", environment: "s")).earlier.line == nil)
}

@Test func theHelpLineIsInFullWithThreeCardsOrFewerAndFirstRunWithNothing() {
    let three = (1...3).map { listing(ws("w\($0)", "W\($0)")) }
    #expect(homeScreen(HomeInput(organization: "o", project: "estate", environment: "s", workspaces: three)).helpInFull)
    let four = (1...4).map { listing(ws("w\($0)", "W\($0)")) }
    let busy = homeScreen(HomeInput(organization: "o", project: "estate", environment: "s", workspaces: four))
    #expect(!busy.helpInFull && !busy.firstRun)
    let empty = homeScreen(HomeInput(organization: "o", project: "estate", environment: "s", tickets: [ticket("INI-1")]))
    #expect(empty.firstRun && empty.helpInFull)
    // The current project's header (Main's Open, *Open a pane*) stands on the first run too.
    #expect(empty.sections.map(\.project) == ["estate"] && empty.sections[0].current)
    #expect(empty.ticketsNotStarted.count == 1)
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

@Test func theComposerNamesWhereASendGoes() {
    #expect(homeComposerPlaceholder(staging, choices: 3) == "Ask anything — in estate · staging")
    #expect(homeComposerPlaceholder(staging, choices: 1) == "Ask anything — in estate")
    #expect(homeComposerPlaceholder(Place(organization: "o", project: "", environment: ""), choices: 0)
        == "Ask, or name what to open")
}
