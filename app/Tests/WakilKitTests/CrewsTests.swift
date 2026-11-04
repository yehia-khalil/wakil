import Foundation
import Testing
@testable import WakilKit

// Workspaces piece 5: crews — a teammate proposed (decision 17), the refusals, the proposals a
// workspace holds, who holds what in a brief, and nothing to do.

private let roots = ["/src/api", "/src/web", "/src/core"]
private let key = "w-1"

private func sender(_ id: String = "a", title: String = "backend") -> LiveConversation {
    LiveConversation(
        id: id, session: "s-\(id)", place: Place(organization: "initech", project: "estate", environment: "staging"),
        title: title, state: .working, onScreen: true, lastActivity: Date())
}

private func refusal(
    repo: String, brief: String = "Build the login form against POST /login.", sender s: LiveConversation? = sender(),
    own: [String] = [], held: [String: String] = [:], proposals: TeammateProposals = TeammateProposals()
) -> String? {
    do {
        _ = try checkTeammateProposal(
            repo: repo, brief: brief, sender: s, roots: roots, workspace: key, ownRepos: own, heldBy: held,
            proposals: proposals)
        return nil
    } catch {
        return "\(error)"
    }
}

@Test func aRepoIsNamedByItsPathOrItsFolderName() throws {
    let f = { (r: String) in
        try checkTeammateProposal(repo: r, brief: "x", sender: sender(), roots: roots, workspace: key,
                                  ownRepos: [], heldBy: [:], proposals: TeammateProposals())
    }
    #expect(try f("/src/web") == "/src/web")
    #expect(try f("web") == "/src/web")
    #expect(try f("/src/web/") == "/src/web")
}

@Test func eachProposalRefusalIsAWholeSentence() {
    #expect(refusal(repo: "web", brief: "  ")?.contains("the brief is empty") == true)
    #expect(refusal(repo: "web", brief: String(repeating: "x", count: 4_001))?
        .contains("the brief is 4001 characters; at most 4,000 go") == true)
    #expect(refusal(repo: "web", brief: String(repeating: "x", count: 4_000)) == nil)
    #expect(refusal(repo: "web", sender: nil)?.contains("this call names none") == true)
    let unknown = refusal(repo: "billing")
    #expect(unknown?.contains("billing is not a repo of this project") == true)
    #expect(unknown?.contains("api, web, core") == true, "the project's repos are named")
    #expect(refusal(repo: "web", own: ["/src/web"])?.contains("you hold web yourself") == true)
    let held = refusal(repo: "web", held: ["/src/web": "frontend"])
    #expect(held?.contains("‘frontend’ already works in web") == true)
    #expect(held?.contains("conversation_message") == true)
    var dismissed = TeammateProposals()
    let p = dismissed.propose(from: "a", fromTitle: "backend", workspace: key, repo: "/src/web", brief: "b").proposal
    _ = dismissed.dismiss(p.id)
    let again = refusal(repo: "web", proposals: dismissed)
    #expect(again?.contains("the operator dismissed a teammate for web in this workspace") == true)
    #expect(again?.contains("decision 17") == true)
    #expect(refusal(repo: "api", proposals: dismissed) == nil, "dismissed for web only")
}

@Test func aDismissalHoldsOnlyInItsWorkspace() throws {
    var proposals = TeammateProposals()
    let p = proposals.propose(from: "a", fromTitle: "backend", workspace: key, repo: "/src/web", brief: "b").proposal
    _ = proposals.dismiss(p.id)
    #expect(proposals.isDismissed(workspace: key, repo: "/src/web"))
    #expect(!proposals.isDismissed(workspace: "w-2", repo: "/src/web"))
    _ = try checkTeammateProposal(repo: "web", brief: "x", sender: sender(), roots: roots, workspace: "w-2",
                                  ownRepos: [], heldBy: [:], proposals: proposals)
}

@Test func aSecondProposalForTheSameRepoReplacesTheFirst() {
    var proposals = TeammateProposals()
    let first = proposals.propose(from: "a", fromTitle: "backend", workspace: key, repo: "/src/web", brief: "one")
    #expect(!first.replaced)
    let second = proposals.propose(from: "a", fromTitle: "backend", workspace: key, repo: "/src/web", brief: "two")
    #expect(second.replaced)
    #expect(proposals.pending(in: key).map(\.brief) == ["two"])
    _ = proposals.propose(from: "a", fromTitle: "backend", workspace: key, repo: "/src/core", brief: "three")
    _ = proposals.propose(from: "b", fromTitle: "other", workspace: "w-2", repo: "/src/web", brief: "four")
    #expect(proposals.pending(in: key).map(\.brief) == ["two", "three"])
    #expect(proposals.pending(from: "b").map(\.brief) == ["four"])
}

@Test func startTakesAProposalAndDismissForgetsItButRemembers() {
    var proposals = TeammateProposals()
    let p = proposals.propose(from: "a", fromTitle: "backend", workspace: key, repo: "/src/web", brief: "b").proposal
    #expect(proposals.proposal(p.id) == p)
    #expect(proposals.take(p.id) == p)
    #expect(proposals.take(p.id) == nil)
    #expect(!proposals.isDismissed(workspace: key, repo: "/src/web"), "a started one may be proposed again")
    let q = proposals.propose(from: "a", fromTitle: "backend", workspace: key, repo: "/src/web", brief: "b").proposal
    #expect(proposals.dismiss(q.id) == q)
    #expect(proposals.pending(in: key).isEmpty)
    #expect(proposals.isDismissed(workspace: key, repo: "/src/web"))
}

@Test func aProposersClosingDropsItsProposals() {
    var proposals = TeammateProposals()
    _ = proposals.propose(from: "a", fromTitle: "backend", workspace: key, repo: "/src/web", brief: "b")
    _ = proposals.propose(from: "c", fromTitle: "ops", workspace: key, repo: "/src/core", brief: "c")
    proposals.drop(from: "a")
    #expect(proposals.pending(in: key).map(\.from) == ["c"])
}

@Test func aProposalReadsAsTheCardsLine() {
    let p = TeammateProposal(id: "p", from: "a", fromTitle: "backend", workspace: key, repo: "/src/web",
                             brief: "Build the login form.\nAgainst POST /login.")
    #expect(teammateProposalLine(p) == "‘backend’ suggests a teammate for web: Build the login form.\nAgainst POST /login.")
    #expect(p.repoName == "web")
}

@Test func theCrewLinesSayWhoHoldsWhat() {
    let text = crewBriefLines(
        repo: "/src/web", teammates: [CrewMember(title: "INI-142 · api", repo: "/src/api")])
    #expect(text.contains("You work in web (/src/web)"))
    #expect(text.contains("- ‘INI-142 · api’ works in api (/src/api)."))
    #expect(text.contains("conversation_message"))
    #expect(text.contains("information only"))
    #expect(text.contains("Agents woken by messages"))
    #expect(text.contains("If there is nothing to do in web"))
    #expect(text.contains("conversation_nothing_to_do"))
    let alone = crewBriefLines(repo: "/src/web", teammates: [])
    #expect(alone.contains("No teammate is working beside you yet"))
}

@Test func nothingToDoReadsAsDone() {
    #expect(nothingToDoWords(repo: "web", why: nil) == "done · nothing to do in web")
    #expect(nothingToDoWords(repo: nil, why: "the API already answers that") == "done · nothing to do: the API already answers that")
    #expect(nothingToDoWords(repo: nil, why: nil) == "done · nothing to do")
}

@Test func aTeammateWithNoRepoYetIsNamedPlainly() {
    let text = crewBriefLines(repo: "/src/web", teammates: [CrewMember(title: "backend", repo: "")])
    #expect(text.contains("- ‘backend’, with no repo of its own yet."))
}

@Test func aConversationsProposalsAreInItsSessionListRow() {
    var row = LiveConversation(
        id: "a", session: "s", place: Place(organization: "initech", project: "estate", environment: "staging"),
        title: "backend", state: .idle, onScreen: false, lastActivity: Date())
    row.proposals = [TeammateProposal(id: "teammate-1", from: "a", fromTitle: "backend", workspace: key,
                                      repo: "/src/web", brief: "b")]
    row.nothingToDo = "done · nothing to do in web"
    guard case .object(let o) = row.json, case .array(let ps)? = o["proposals"] else {
        Issue.record("no proposals"); return
    }
    #expect(ps.count == 1)
    #expect(o["nothingToDo"] == .string("done · nothing to do in web"))
    #expect(row.stateWords == "done · nothing to do in web")
    row.state = .working
    #expect(row.stateWords == "working", "a new turn is not nothing to do")
}
