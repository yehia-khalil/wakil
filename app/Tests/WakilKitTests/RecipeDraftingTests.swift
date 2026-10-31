import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 2, part three: Detect's drafting conversation and Try's fix proposal — the
// book that keeps each repo's drafting conversation and its proposal, the briefs, and how a
// proposal is saved.

private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

private func detected(_ s: String) -> RunningDetected {
    try! JSONDecoder().decode(RunningDetected.self, from: Data(s.utf8))
}

private let key = RecipeDraftKey(projectPath: "/p/project.json", repo: "api")

@Test func aDraftNeedsAConversationWhenItAsksOrRunsNothing() {
    #expect(detected(#"{"repo":"api","kind":"unknown","recipe":{},"questions":["Write its processes by hand."]}"#).needsDrafting)
    #expect(detected(#"{"repo":"api","kind":"go","recipe":{"setup":["go mod download"]}}"#).needsDrafting)
    #expect(!detected(#"{"repo":"api","kind":"go","recipe":{"processes":[{"name":"app","command":"go run ."}]}}"#).needsDrafting)
    #expect(!detected(#"{"repo":"lib","kind":"php-library","recipe":{},"doesntRun":true,"why":"a library"}"#).needsDrafting)
}

@Test func onlyTheDraftingConversationProposesAndItsProposalLandsUnsaved() throws {
    var book = RecipeDraftBook()
    book.begin(key, conversation: "c1", title: "Draft how api runs", kind: "unknown")
    #expect(book.draft(key)?.phase == .drafting)
    let proposal = detected(#"{"repo":"api","recipe":{"processes":[{"name":"web","command":"make serve"}]}}"#)

    #expect(throws: RecipeDraftError.self) { _ = try book.propose(conversation: "c2", proposal) }
    #expect(throws: RecipeDraftError.self) { _ = try book.propose(conversation: nil, proposal) }
    let other = detected(#"{"repo":"web","recipe":{}}"#)
    #expect(throws: RecipeDraftError.self) { _ = try book.propose(conversation: "c1", other) }

    let k = try book.propose(conversation: "c1", proposal)
    #expect(k == key)
    let d = try #require(book.draft(key))
    #expect(d.phase == .proposed && !d.isFix)
    // Detect's kind names the recipe when the conversation names none.
    #expect(d.proposal?.kind == "unknown" && d.proposal?.recipe.processes?.first?.command == "make serve")
}

@Test func theRefusalNamesDecisionThirteenAndTheRepo() {
    var book = RecipeDraftBook()
    let proposal = detected(#"{"repo":"api","recipe":{}}"#)
    do {
        _ = try book.propose(conversation: "c9", proposal)
        Issue.record("an agent that is not drafting api proposed")
    } catch {
        #expect("\(error)".contains("decision 13") && "\(error)".contains("api"))
    }
}

@Test func aFixIsAskedOfTheSameConversationAndSaidAsAFix() throws {
    var book = RecipeDraftBook()
    book.begin(key, conversation: "c1", title: "Draft how api runs", kind: "go")
    _ = try book.propose(conversation: "c1", detected(#"{"repo":"api","recipe":{"processes":[{"name":"a","command":"x"}]}}"#))
    book.settle(key)
    #expect(book.draft(key)?.phase == .idle && book.draft(key)?.proposal == nil)
    book.askFix(key, failedAt: "setup `composer install`")
    #expect(book.draft(key)?.phase == .fixing(failedAt: "setup `composer install`"))
    _ = try book.propose(conversation: "c1", detected(#"{"repo":"api","recipe":{"processes":[{"name":"a","command":"y"}]}}"#))
    #expect(book.draft(key)?.isFix == true && book.draft(key)?.phase == .proposed)
}

@Test func aTurnThatEndsWithoutAProposalIsSaidWhole() {
    var book = RecipeDraftBook()
    book.begin(key, conversation: "c1", title: "Draft how api runs", kind: "")
    book.turnEnded(conversation: "c1")
    #expect(book.draft(key)?.phase == .noProposal)
    let why = book.draft(key)?.line ?? ""
    #expect(why.contains("‘Draft how api runs’") && why.contains("without proposing"))
    // A turn that ends after its proposal leaves the proposal.
    book.begin(key, conversation: "c1", title: "Draft how api runs", kind: "")
    _ = try? book.propose(conversation: "c1", detected(#"{"repo":"api","recipe":{}}"#))
    book.turnEnded(conversation: "c1")
    #expect(book.draft(key)?.phase == .proposed)
    #expect(book.key(ofConversation: "c1") == key)
    book.end(key)
    #expect(book.draft(key) == nil && book.key(ofConversation: "c1") == nil)
}

@Test func theDraftingBriefCarriesTheFactsTheRulesAndTheAnswer() {
    let facts = json(#"{"repo":"api","kind":"unknown","questions":["Wakil found nothing it knows how to run in api."]}"#)
    let brief = recipeDraftingBrief(repo: "api", root: "/code/api", detected: facts)
    #expect(brief.hasPrefix("Draft how api runs"))
    #expect(brief.contains("/code/api"))
    #expect(brief.contains("\"kind\":\"unknown\""))
    #expect(brief.contains("$WAKIL_PORT"))
    #expect(brief.contains("services"))
    #expect(brief.contains("README"))
    #expect(brief.contains("Change nothing"))
    #expect(brief.contains("running_draft_propose"))
    // A process that needs the app up is marked to start after ready; a first run's image build is setup's.
    #expect(brief.contains("\"afterReady\": true"))
    #expect(brief.contains("docker compose build") && brief.contains("in setup"))
}

@Test func theFixBriefCarriesTheFailingStepWholeAndTheRecipeAsTried() {
    var r = Recipe()
    r.setup = ["composer install"]
    let long = String(repeating: "x", count: 5000) + "END"
    let report = RunTryResult(passed: false, steps: [
        RunStepResult(phase: "service", command: "docker compose up -d", ok: true),
        RunStepResult(phase: "setup", command: "composer install", ok: false, exitCode: 2, output: long),
    ])
    let brief = recipeFixBrief(repo: "api", recipe: r, report: report)
    #expect(brief.hasPrefix("Try of api's recipe failed"))
    #expect(brief.contains("✓ service — docker compose up -d"))
    #expect(brief.contains("✗ setup — composer install"))
    #expect(brief.contains(long))
    #expect(brief.contains("\"setup\":[\"composer install\"]"))
    #expect(brief.contains("running_draft_propose"))
    #expect(recipeTryFailedAt(report) == "setup `composer install`")
    let notReady = RunTryResult(passed: false, steps: [], ready: RunReadyResult(ready: false, detail: "timed out after 120s"))
    #expect(recipeTryFailedAt(notReady) == "ready: timed out after 120s")
}

private let onRecipe: JSONValue = json("""
{"project":"estate","problems":[],
 "recipes":{"laravel":{"setup":["composer install"],"processes":[{"name":"app","command":"php artisan serve"}],
                       "env":{"APP_ENV":"local"}}},
 "repos":[{"repo":"api","path":"/p/api","recipe":"laravel"},{"repo":"web","path":"/p/web"}]}
""")

@Test func aProposalForARepoOnASharedRecipeSavesOnlyWhatDiffersAsItsOwn() throws {
    let s = try RunningSettings.decode(onRecipe)
    let fix = detected("""
    {"repo":"api","kind":"laravel","recipe":{"setup":["composer install --ignore-platform-reqs"],
      "processes":[{"name":"app","command":"php artisan serve"}],"env":{"APP_ENV":"local","DB_HOST":"127.0.0.1"}}}
    """)
    let saving = s.savingDraft(fix, of: "api")
    #expect(saving == json("""
    {"repos":{"api":{"recipe":"laravel","overrides":{"setup":["composer install --ignore-platform-reqs"],
      "env":{"DB_HOST":"127.0.0.1"}}}}}
    """))
}

@Test func aProposalForARepoWithNoRecipeSavesANewRecipeItNames() throws {
    let s = try RunningSettings.decode(onRecipe)
    let d = detected(#"{"repo":"web","kind":"node","recipe":{"processes":[{"name":"dev","command":"npm run dev"}]}}"#)
    #expect(s.savingDraft(d, of: "web") == json("""
    {"recipes":{"node":{"processes":[{"name":"dev","command":"npm run dev"}]}},"repos":{"web":{"recipe":"node"}}}
    """))
}

private actor Seen {
    var call: (String?, String)?
    func set(_ c: String?, _ r: String) { call = (c, r) }
}

@Test func theProposeActionForwardsTheAgentsCall() async throws {
    let registry = ActionRegistry(journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "t")
    let lookup = RecipeDraftLookup()
    let seen = Seen()
    lookup.use { conversation, proposal in
        await seen.set(conversation, proposal.repo)
    }
    await registerRecipeDraftActions(into: registry, drafts: lookup)
    let d = try #require(await registry.descriptor(named: "running_draft_propose"))
    #expect(d.audience == .agentReachable && d.kind == .control)
    let params = json(#"{"repo":"api","recipe":{"processes":[{"name":"web","command":"make serve"}]}}"#)
    let caller = DispatchCaller(place: Place(organization: "o", project: "p", environment: "e"), session: "s", conversation: "c1")
    let r = try await registry.dispatch(name: "running_draft_propose", params: params, origin: .agent, caller: caller, confirmation: nil)
    let call = await seen.call
    #expect(call?.0 == "c1" && call?.1 == "api")
    #expect("\(r)".contains("nothing is saved"))
}

@Test func theProposeActionWithNoWindowSaysSo() async throws {
    let registry = ActionRegistry(journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "t")
    await registerRecipeDraftActions(into: registry, drafts: RecipeDraftLookup())
    let caller = DispatchCaller(place: Place(organization: "o", project: "p", environment: "e"), session: "s", conversation: "c1")
    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(name: "running_draft_propose", params: json(#"{"repo":"api","recipe":{}}"#),
                                        origin: .agent, caller: caller, confirmation: nil)
    }
}

/// The walk: "‘Draft how parkour-warriors runs’ ended its turn without proposing a recipe …" with
/// nothing pressable. The conversation's name in every drafting line is its own part, drawn as a
/// control that opens it; a turn that ended without a proposal offers Ask again, which sends the
/// same request again and puts the drafting back in flight.
@Test func aDraftingLineNamesItsConversationAsAPartAndATurnWithNoProposalCanBeAskedAgain() throws {
    var book = RecipeDraftBook()
    book.begin(key, conversation: "c1", title: "Draft how api runs", kind: "")
    book.asked(key, "the drafting brief")
    #expect(book.draft(key)?.lineParts?.conversation == "Draft how api runs")
    #expect(book.draft(key)?.lineParts?.before == "Drafting how api runs from its docs in ‘")
    #expect(book.draft(key)?.canAskAgain == false, "nothing to ask again while it drafts")
    book.askFix(key, failedAt: "setup `composer install`")
    book.asked(key, "the fix brief")
    #expect(book.draft(key)?.lineParts.map { $0.before + $0.conversation + $0.after }
        == "Try failed at setup `composer install`. ‘Draft how api runs’ is proposing a fix…")
    book.turnEnded(conversation: "c1")
    let parts = try #require(book.draft(key)?.lineParts)
    #expect(parts.conversation == "Draft how api runs")
    #expect(parts.after == "’ ended its turn without proposing a recipe for api; its thread says why.")
    #expect(book.draft(key)?.canAskAgain == true)
    #expect(book.askAgain(key) == "the fix brief")
    #expect(book.draft(key)?.phase == .fixing(failedAt: "setup `composer install`"))
    // A conversation that never started has nothing to ask again.
    book.fail(key, "could not start")
    #expect(book.draft(key)?.canAskAgain == false)
    #expect(book.draft(key)?.lineParts == nil)
}
