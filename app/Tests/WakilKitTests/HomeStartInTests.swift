import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 3 walk: the home composer's *Start in* sets where the next send goes and moves
// nothing; a send goes there; every conversation line on the home opens its conversation.

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2 * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// `wakil-ctx` for one organisation: a project switch keeps the environment when the project has
/// it, else leaves none chosen; `set_environment ""` leaves none chosen.
private actor StartInContext: ToolCaller {
    private let projects: [String: [String]] = ["api": ["staging", "production"], "web": ["staging"], "acc": ["dev"]]
    private var active = (project: "api", environment: "staging")
    private(set) var calls: [String] = []

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        var argument = ""
        if case .object(let fields) = arguments, case .string(let value)? = fields["name"] { argument = value }
        switch name {
        case "get_context":
            return .object(["structuredContent": .object([
                "Org": .string("initech"), "Environment": .string(active.environment),
                "Project": .object(["name": .string(active.project)]), "ProjectKey": .string(active.project),
                "RootPaths": .array([]), "ActiveProvider": .string("test-provider"),
            ])])
        case "set_project":
            calls.append("set_project:\(argument)")
            guard let environments = projects[argument] else { return refusal("no project \(argument)") }
            active = (argument, environments.contains(active.environment) ? active.environment : "")
            return .object([:])
        case "set_environment":
            calls.append("set_environment:\(argument)")
            guard argument.isEmpty || projects[active.project]?.contains(argument) == true else {
                return refusal("no environment \(argument)")
            }
            active = (active.project, argument)
            return .object([:])
        default:
            return refusal("\(name): not faked")
        }
    }

    private func refusal(_ text: String) -> JSONValue {
        .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }
}

private struct Window {
    let model: WindowModel
    let registry: ActionRegistry
    let harnesses: Harnesses
    let ctx: StartInContext
}

@MainActor
private func window() async -> Window {
    let ctx = StartInContext()
    let harnesses = Harnesses()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("home-start-in-\(UUID().uuidString)"),
        sessionId: "home-start-in")
    let panes = PaneStore()
    let layout = LayoutStore()
    let resumes = ResumeBroker()
    let conversations = ConversationBroker()
    await registerStandardActions(
        into: registry, context: ctx, panes: panes, db: nil, resumes: resumes, layout: layout,
        conversationRequests: conversations)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: ContextStore(client: ctx),
        harnessFactory: { place, _, _ in harnesses.make(place) }, resumes: resumes, rootPath: "/tmp",
        providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        conversationRequests: conversations,
        environment: "")
    model.setOrganizationForTesting("initech")
    await model.refreshContext()
    return Window(model: model, registry: registry, harnesses: harnesses, ctx: ctx)
}

private let api = Place(organization: "initech", project: "api", environment: "staging")
private let web = Place(organization: "initech", project: "web", environment: "staging")

@MainActor
struct HomeStartInTests {
    @Test func choosingStartInMovesNothing() async throws {
        let w = await window()
        #expect(w.model.place == api)
        let choices = homeStartChoices(projects: ["api", "web"], current: w.model.place, environments: ["staging", "production"])

        w.model.chooseStartIn(try #require(choices.first { $0.project == "web" }))

        #expect(w.model.place == api, "the screen stays where it was")
        #expect(await w.ctx.calls.isEmpty, "no project or environment switched")
        #expect(!w.model.sessionStarted, "the home is still up")
        #expect(w.model.startInPlace == Place(organization: "initech", project: "web", environment: ""))
        #expect(homeStartSelected(choices, chosen: w.model.homeStartIn)?.project == "web", "the label names the choice")

        w.model.chooseStartIn(try #require(choices.first))
        #expect(w.model.homeStartIn == nil, "the window's own place again")
        #expect(homeStartSelected(choices, chosen: nil) == choices.first)
    }

    @Test func aProjectsNameOnTheHomePointsStartInAtItAndMovesNothing() async {
        let w = await window()
        w.model.chooseStartIn(project: "web")
        #expect(w.model.place == api && w.model.startInPlace.project == "web")
        #expect(await w.ctx.calls.isEmpty)
    }

    @Test func aSendFromTheHomeGoesWhereStartInPoints() async throws {
        let w = await window()
        w.model.chooseStartIn(project: "web")
        let composer = ComposerModel(window: w.model, speech: SpeechRegistry(engines: []), fastPathRunner: { _, _ in .toAgent })

        composer.edited(draft: "hello web", caret: 9)
        await composer.submit()

        #expect(w.model.place == web, "\(w.model.status)")
        #expect(w.model.currentAgent?.place == web)
        #expect(w.harnesses.in(web).count == 1 && w.harnesses.in(api).isEmpty)
        #expect(w.model.homeStartIn == nil, "spent by the send")
        #expect(composer.draft.isEmpty)
    }

    @Test func aSendWhoseStartInPlaceShowsAConversationStartsANewOneInMainThere() async throws {
        let w = await window()
        #expect(await w.model.send("first in api"))
        let first = try #require(w.model.currentAgent)
        await w.model.goTo(web)
        #expect(w.model.place == web && !w.model.sessionStarted)

        w.model.chooseStartIn(HomeStartChoice(project: "api", environment: "staging", current: false, isProduction: false))
        let composer = ComposerModel(window: w.model, speech: SpeechRegistry(engines: []), fastPathRunner: { _, _ in .toAgent })
        composer.edited(draft: "second in api", caret: 13)
        await composer.submit()

        #expect(w.model.place == api)
        let second = try #require(w.model.currentAgent)
        #expect(second !== first, "a new conversation in Main, the one there left running")
        #expect(w.model.conversation(id: first.id) === first)
    }

    @Test func aStartInSwitchRefusedGivesTheLineBack() async {
        let w = await window()
        w.model.chooseStartIn(project: "nosuch")
        let composer = ComposerModel(window: w.model, speech: SpeechRegistry(engines: []), fastPathRunner: { _, _ in .toAgent })
        composer.edited(draft: "hello", caret: 5)
        await composer.submit()

        #expect(w.model.place == api)
        #expect(composer.draft == "hello", "Rule 2")
        #expect(w.model.status.contains("no project nosuch"), "\(w.model.status)")
    }

    // The walk's "Greeting and workspace check-in": started with no environment chosen, then the
    // window's environment chosen — its line did nothing, as no switch reached a place with none.
    @Test func aLineOfAConversationStartedWithNoEnvironmentOpensIt() async throws {
        let w = await window()
        await w.model.goTo(Place(organization: "initech", project: "acc", environment: ""))
        let none = Place(organization: "initech", project: "acc", environment: "")
        #expect(w.model.place == none)
        #expect(await w.model.send("hi"))
        let greeting = try #require(w.model.currentAgent)
        await w.model.setEnvironment("dev")
        #expect(w.model.place.environment == "dev" && !w.model.sessionStarted)

        await w.model.openHomeLine(greeting.id, session: greeting.sessionId)

        #expect(await waitUntil { w.model.currentAgent === greeting }, "\(w.model.status)")
        #expect(w.model.place == none)
    }

    @Test func aLineWhoseConversationEndedOpensItsThreadAsContinueDoes() async throws {
        let w = await window()
        await w.model.openHomeLine("gone", session: "session-7")
        let journal = try await w.registry.journalEntries()
        #expect(journal.contains { $0.action == "session_resume" && $0.origin == .ui })
        #expect(!journal.contains { $0.action == "session_switch" })
    }

    @Test func homeLinesCarryTheirSession() {
        let live = LiveConversation(
            id: "c1", session: "s1", place: api, title: "t", state: .done, onScreen: false, lastActivity: Date())
        let screen = homeScreen(HomeInput(organization: "initech", project: "api", environment: "staging",
                                          projects: ["api"], live: [live]))
        #expect(screen.sections.first?.main?.lines.first?.session == "s1")
    }
}
