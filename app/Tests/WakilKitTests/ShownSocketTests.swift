import Foundation
import Testing
@testable import WakilKit

// The socket a place opens when it is shown (`WindowModel.openShownSocket`): at launch and on
// every switch, before any turn, pinned to that place; the place's first session takes it.

private let initechAPI = Place(organization: "initech", project: "api", environment: "staging")
private let initechBilling = Place(organization: "initech", project: "billing", environment: "staging")
private let initechAPIQA = Place(organization: "initech", project: "api", environment: "qa")
private let umbrellaWeb = Place(organization: "umbrella", project: "web", environment: "staging")

/// A `wakil-ctx` whose active place the test, the org switcher and the two switch actions move,
/// so a switch really changes what `refreshContext` reads.
private actor MovableContext: ToolCaller {
    private(set) var place: Place
    init(_ place: Place) { self.place = place }
    func move(to place: Place) { self.place = place }
    func moveOrg(to org: String) { place = org == umbrellaWeb.organization ? umbrellaWeb : initechAPI }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard name == "get_context" else { return .object(["structuredContent": .object([:])]) }
        return .object(["structuredContent": .object([
            "Org": .string(place.organization), "Environment": .string(place.environment),
            "Project": .object(["name": .string(place.project)]),
            "RootPaths": .array([.string(NSTemporaryDirectory())]),
            "ActiveProvider": .string("test-provider"),
        ])])
    }
}

/// A window launched into initech/api/staging whose project and environment switches move the
/// context as `wakil-ctx`'s own `set_project` and `set_environment` would.
@MainActor
private func launchedWindow(_ sessions: Sessions) async -> (WindowModel, MovableContext) {
    let context = MovableContext(initechAPI)
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: initechAPI.organization,
        harnessFactory: { place, _ in sessions.harnesses.make(place) },
        context: ContextStore(client: context),
        orgSwitcher: { org in
            await context.moveOrg(to: org)
            return []
        },
        agentSocketFactory: sessions.socketFactory)
    let registry = model.registryForTesting
    await registry.register(Action(
        name: "ctx_set_project", description: "test double", kind: .control,
        schema: .object(["type": .string("object")]),
        handler: { params in
            guard case .object(let fields) = params, case .string(let name)? = fields["name"] else {
                return .object([:])
            }
            let now = await context.place
            await context.move(to: Place(organization: now.organization, project: name, environment: "staging"))
            return .object([:])
        }))
    await registry.register(Action(
        name: "ctx_set_environment", description: "test double", kind: .control,
        schema: .object(["type": .string("object")]),
        handler: { params in
            guard case .object(let fields) = params, case .string(let name)? = fields["name"] else {
                return .object([:])
            }
            let now = await context.place
            await context.move(to: Place(organization: now.organization, project: now.project, environment: name))
            return .object([:])
        }))
    await model.refreshContext()
    await model.settleShownSocketsForTesting()
    return (model, context)
}

/// The socket answering for `place`, of those the window opened.
private func socket(for place: Place, in sessions: Sessions) async -> [RecordedSocket] {
    var found: [RecordedSocket] = []
    for socket in sessions.issuedSockets where await socket.caller().place == place {
        found.append(socket)
    }
    return found
}

@MainActor
struct ShownSocketTests {
    @Test func theLaunchPlaceHasASocketBeforeAnyTurn() async throws {
        let sessions = Sessions()
        let (model, _) = await launchedWindow(sessions)

        #expect(model.place == initechAPI)
        let sockets = sessions.issuedSockets
        #expect(sockets.count == 1, "\(sessions.log)")
        let socket = try #require(sockets.first)
        let caller = await socket.caller()
        #expect(caller.place == initechAPI)
        let reserved = try #require(model.shownSocketSessionIdForTesting(initechAPI))
        #expect(caller.session == reserved, "pinned to the session the place will start")
        #expect(socket.path == agentSocketPath(agentSessionId: reserved))
        #expect(sessions.harnesses.issued.isEmpty, "no agent was started for it")
        #expect(!socket.stopped)
        await model.shutdown()
    }

    @Test func everyKindOfSwitchOpensTheSocketOfThePlaceItShows() async throws {
        let sessions = Sessions()
        let (model, _) = await launchedWindow(sessions)

        #expect(await model.setProject("billing"))
        #expect(model.place == initechBilling)
        await model.settleShownSocketsForTesting()
        #expect(await socket(for: initechBilling, in: sessions).count == 1, "a project switch")

        #expect(await model.setEnvironment("qa"))
        await model.settleShownSocketsForTesting()
        let billingQA = Place(organization: "initech", project: "billing", environment: "qa")
        #expect(model.place == billingQA)
        #expect(await socket(for: billingQA, in: sessions).count == 1, "an environment switch")

        await model.requestOrganizationSwitch("umbrella")
        await model.settleShownSocketsForTesting()
        #expect(model.place == umbrellaWeb, "\(model.status)")
        #expect(await socket(for: umbrellaWeb, in: sessions).count == 1, "an organisation switch")

        // Each stays pinned to its own place, wherever the screen went.
        var places: [Place] = []
        for socket in sessions.issuedSockets { places.append(await socket.caller().place) }
        #expect(sessions.issuedSockets.count == 4, "\(places)")
        #expect(await socket(for: initechAPI, in: sessions).count == 1)
        #expect(sessions.issuedSockets.allSatisfy { !$0.stopped }, "a switch stops nothing")
        await model.shutdown()
    }

    @Test func thePlacesFirstTurnTakesItsShownSocketAndId() async throws {
        let sessions = Sessions()
        let (model, _) = await launchedWindow(sessions)
        let shown = try #require(sessions.issuedSockets.first)
        let reserved = try #require(model.shownSocketSessionIdForTesting(initechAPI))

        #expect(await model.send("hello"))

        let agent = try #require(model.agents[initechAPI])
        #expect(agent.sessionId == reserved, "the session starts under the reserved id")
        #expect(agent.assignedSessionId == reserved)
        #expect(agent.socket as? RecordedSocket === shown, "and on the socket already listening")
        #expect(sessions.issuedSockets.count == 1, "no second socket: \(sessions.log)")
        let harness = try #require(sessions.harnesses.in(initechAPI).first)
        #expect(harness.log.first == "start:\(reserved):-")
        #expect(model.shownSocketSessionIdForTesting(initechAPI) == nil, "taken")
        await model.shutdown()
    }

    @Test func aPlaceOpensOneSocketHoweverOftenItIsShown() async throws {
        let sessions = Sessions()
        let (model, _) = await launchedWindow(sessions)

        for _ in 0..<2 {
            #expect(await model.setEnvironment("qa"))
            #expect(await model.setEnvironment("staging"))
        }
        await model.settleShownSocketsForTesting()
        #expect(sessions.issuedSockets.count == 2, "\(sessions.log)")
        #expect(await socket(for: initechAPI, in: sessions).count == 1)
        #expect(await socket(for: initechAPIQA, in: sessions).count == 1)

        // A place whose session is running keeps that session's socket on its return.
        #expect(await model.send("hello"))
        #expect(await model.setEnvironment("qa"))
        #expect(await model.setEnvironment("staging"))
        await model.settleShownSocketsForTesting()
        #expect(sessions.issuedSockets.count == 2, "\(sessions.log)")
        await model.shutdown()
    }

    @Test func shutdownStopsEverySocketTakenOrNot() async throws {
        let sessions = Sessions()
        let (model, _) = await launchedWindow(sessions)
        #expect(await model.send("hello"))
        #expect(await model.setEnvironment("qa"))
        await model.settleShownSocketsForTesting()
        #expect(sessions.issuedSockets.count == 2)

        await model.shutdown()

        #expect(sessions.issuedSockets.allSatisfy { $0.stopped }, "no socket outlives the window")
        await model.refreshContext()
        #expect(sessions.issuedSockets.count == 2, "none opens after shutdown")
    }

    /// Rule 7: a socket that will not start refuses nothing — not the switch, not the turn. The
    /// session tries again, runs without Wakil's own tools, and the status says why.
    @Test func aSocketThatWillNotStartRefusesNothing() async throws {
        let sessions = Sessions()
        sessions.socketError = MCPTransportError.pathTooLong("/too/long")
        let (model, _) = await launchedWindow(sessions)
        #expect(sessions.issuedSockets.isEmpty)
        #expect(model.place == initechAPI)
        #expect(await model.setEnvironment("qa"), "the switch goes")
        #expect(await model.setEnvironment("staging"))

        #expect(await model.send("hello"), "the turn goes")
        let agent = try #require(model.agents[initechAPI])
        #expect(agent.socket == nil)
        #expect(model.status.contains("cannot reach Wakil's own tools"), "\(model.status)")

        // Once the socket can start, the next place shown has one.
        sessions.socketError = nil
        #expect(await model.setEnvironment("qa"))
        await model.settleShownSocketsForTesting()
        #expect(await socket(for: initechAPIQA, in: sessions).count == 1)
        await model.shutdown()
    }

    /// A resume replaces the place's session before any turn took its shown socket: the fork
    /// answers on its own, the reserved one is stopped, and the place has exactly one live socket.
    @Test func aResumeBeforeAnyTurnLeavesThePlaceOneLiveSocket() async throws {
        let sessions = Sessions()
        let (model, _) = await launchedWindow(sessions)
        let shown = try #require(sessions.issuedSockets.first)
        await model.registryForTesting.register(Action(
            name: "session_read", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                .object(["structuredContent": .object([
                    "cwd": .string("/tmp"), "provider": .string("test-provider"), "parent": .string(""),
                    "truncated": .bool(false), "entries": .array([]),
                ])])
            }))

        await model.resume(sessionId: "parent-1")

        let fork = try #require(model.agents[initechAPI]?.sessionId)
        #expect(shown.stopped, "the reserved socket goes with the session that never started")
        let live = sessions.issuedSockets.filter { !$0.stopped }
        #expect(live.count == 1, "\(sessions.log)")
        #expect(await live.first?.caller().session == fork)
        #expect(await live.first?.caller().place == initechAPI)
        await model.shutdown()
    }
}
