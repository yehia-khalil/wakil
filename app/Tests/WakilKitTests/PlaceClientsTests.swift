import Foundation
import Testing
@testable import WakilKit

/// What the pool's `start` and `stop` were asked to do, in order.
private actor PoolLog {
    private(set) var starts: [(ClientRole, Place)] = []
    private(set) var stops: [ObjectIdentifier] = []
    private(set) var started: [RecordingToolCaller] = []

    func start(_ role: ClientRole, _ place: Place) -> RecordingToolCaller {
        starts.append((role, place))
        let client = RecordingToolCaller(always: .object(["from": .string("pool")]))
        started.append(client)
        return client
    }

    func stop(_ client: any ToolCaller) {
        stops.append(ObjectIdentifier(client as AnyObject))
    }
}

private func pool(_ log: PoolLog) -> PlaceClients {
    PlaceClients(
        start: { role, place in
            // A pause, so ten concurrent first calls really are in flight together.
            try await Task.sleep(nanoseconds: 20_000_000)
            return await log.start(role, place)
        },
        stop: { client in await log.stop(client) })
}

private let screen = Place(organization: "umbrella", project: "web", environment: "prod")
private let elsewhere = Place(organization: "initech", project: "api", environment: "staging")

/// A call made for `place` by `session`: an agent's when it is set, the operator's when nil.
private func call(
    _ caller: any ToolCaller, as place: Place?, session: String? = "s1"
) async throws -> JSONValue {
    let body = { try await caller.callTool(name: "query", arguments: .object([:]), timeout: 10) }
    guard let place else { return try await body() }
    return try await ActionRegistry.$dispatchCaller.withValue(
        DispatchCaller(place: place, session: session), operation: body)
}

@Suite struct PlaceClientsTests {
    /// Who is calling decides, not whether the places match: an agent on the screen's own place
    /// still goes to the client pinned there.
    @Test func anAgentOnTheScreensPlaceStillUsesItsPinnedClient() async throws {
        let log = PoolLog()
        let window = RecordingToolCaller(always: .object(["from": .string("window")]))
        let routed = PlaceRoutedCaller(role: .database, window: window, pool: pool(log))

        let result = try await call(routed, as: screen)

        #expect(result == .object(["from": .string("pool")]))
        #expect(await window.calls.isEmpty)
        #expect(await log.starts.map(\.1) == [screen])
    }

    /// The operator's own dispatch carries the place it was made in, which can be stale by the
    /// time it reaches a client. It goes to the window's client wherever that place is, and
    /// starts nothing a retain would not know to stop.
    @Test func anOperatorCallerOffTheScreensPlaceUsesTheWindowsClient() async throws {
        let log = PoolLog()
        let window = RecordingToolCaller(always: .object(["from": .string("window")]))
        let routed = PlaceRoutedCaller(role: .database, window: window, pool: pool(log))

        let result = try await call(routed, as: elsewhere, session: nil)
        _ = try await call(routed, as: elsewhere, session: "")

        #expect(result == .object(["from": .string("window")]))
        #expect(await window.calls.count == 2)
        #expect(await log.starts.isEmpty)
    }

    /// The switch race: `setProject`/`switchEnvironment` rewrite `active.json` before the
    /// window's `place` moves. In between, the window's client already answers for the new
    /// place while the screen still reads as the agent's. The agent's call must not land there
    /// — which it cannot now, since the router never asks where the screen is.
    @Test func anAgentMidSwitchStaysOnItsPinnedClient() async throws {
        let log = PoolLog()
        let staging = Place(organization: "umbrella", project: "web", environment: "staging")
        // What the window's own client resolves now that active.json says production.
        let window = RecordingToolCaller(always: .object(["from": .string("production")]))
        let routed = PlaceRoutedCaller(role: .database, window: window, pool: pool(log))

        let result = try await call(routed, as: staging)

        #expect(result == .object(["from": .string("pool")]))
        #expect(await window.calls.isEmpty)
        #expect(await log.starts.map(\.1) == [staging])
    }

    @Test func noCallerUsesTheWindowsClient() async throws {
        let log = PoolLog()
        let window = RecordingToolCaller(always: .object([:]))
        let routed = PlaceRoutedCaller(role: .database, window: window, pool: pool(log))

        _ = try await call(routed, as: nil)

        #expect(await window.calls.count == 1)
        #expect(await log.starts.isEmpty)
    }

    @Test func anIncompleteCallerPlaceUsesTheWindowsClient() async throws {
        let log = PoolLog()
        let window = RecordingToolCaller(always: .object([:]))
        let routed = PlaceRoutedCaller(role: .database, window: window, pool: pool(log))

        _ = try await call(routed, as: Place(organization: "initech", project: "", environment: ""))

        #expect(await window.calls.count == 1)
        #expect(await log.starts.isEmpty)
    }

    @Test func anOffScreenCallerGetsAPinnedClientForItsOwnOrg() async throws {
        let log = PoolLog()
        let window = RecordingToolCaller(always: .object([:]))
        let routed = PlaceRoutedCaller(role: .database, window: window, pool: pool(log))

        let result = try await call(routed, as: elsewhere)

        #expect(result == .object(["from": .string("pool")]))
        #expect(await window.calls.isEmpty)
        let starts = await log.starts
        #expect(starts.count == 1)
        #expect(starts.first?.0 == .database)
        #expect(starts.first?.1 == elsewhere)
        let started = await log.started
        #expect(await started.first?.calls.count == 1)
    }

    @Test func concurrentFirstCallsStartOneClient() async throws {
        let log = PoolLog()
        let clients = pool(log)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try await clients.client(.http, for: elsewhere) }
            }
            try await group.waitForAll()
        }

        #expect(await log.starts.count == 1)
    }

    @Test func retainStopsClientsForPlacesNoLongerInUse() async throws {
        let log = PoolLog()
        let clients = pool(log)
        let first = try await clients.client(.context, for: screen)
        let second = try await clients.client(.context, for: elsewhere)

        await clients.retain([screen])

        #expect(await log.stops == [ObjectIdentifier(second as AnyObject)])
        #expect(!(await log.stops).contains(ObjectIdentifier(first as AnyObject)))
        let again = try await clients.client(.context, for: elsewhere)
        #expect(ObjectIdentifier(again as AnyObject) != ObjectIdentifier(second as AnyObject))
        #expect(await log.starts.count == 3)
    }

    /// A call still in flight when the window closes must not start a client after `stopAll`:
    /// nothing would stop it, and the process would outlive the window.
    @Test func nothingStartsAfterStopAll() async throws {
        let log = PoolLog()
        let clients = pool(log)
        _ = try await clients.client(.context, for: elsewhere)

        await clients.stopAll()

        await #expect(throws: PlaceClientError.self) { try await clients.client(.git, for: elsewhere) }
        #expect(await log.starts.count == 1)
    }

    /// The launch's provider belongs to the launch's org. A client pinned to another org gets
    /// none, as `switchOrg`'s restart does: a provider id from one org must not scope another's.
    @Test func aPinnedClientCarriesTheLaunchProviderOnlyInTheLaunchOrg() {
        let launch = ["HOME": "/tmp/h", "WAKIL_ORG": "umbrella", "WAKIL_PROVIDER": "p1"]

        #expect(WakilWiring.pinnedProvider(for: screen, launch: launch) == "p1")
        #expect(WakilWiring.pinnedProvider(for: elsewhere, launch: launch) == nil)
        #expect(WakilWiring.pinnedProvider(for: screen, launch: ["WAKIL_PROVIDER": "p1"]) == nil)
    }

    @Test func pinnedEnvironmentCarriesTheWholePlaceAndTheWindowMarker() {
        let launch = ["HOME": "/tmp/h", "PATH": "/bin", "WAKIL_ORG": "umbrella"]

        let pinned = WakilWiring.pinnedEnvironment(for: elsewhere, from: launch, provider: "p1")

        #expect(pinned["WAKIL_ORG"] == "initech")
        #expect(pinned["WAKIL_PROJECT"] == "api")
        #expect(pinned["WAKIL_ENVIRONMENT"] == "staging")
        #expect(pinned["WAKIL_IN_WINDOW"] == "1")
        #expect(pinned["WAKIL_PROVIDER"] == "p1")
        #expect(pinned["HOME"] == "/tmp/h")

        let noEnvironment = WakilWiring.pinnedEnvironment(
            for: Place(organization: "initech", project: "api", environment: ""), from: launch, provider: nil)
        #expect(noEnvironment["WAKIL_ENVIRONMENT"] == nil)
        #expect(noEnvironment["WAKIL_PROJECT"] == "api")
    }
}
