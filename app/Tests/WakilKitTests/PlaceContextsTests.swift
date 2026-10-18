import Foundation
import Testing
@testable import WakilKit

/// A `wakil-ctx` pinned to one place: answers `get_context` with that place's roots and
/// production declarations, or fails, and counts what it was asked.
private actor PinnedContext: ToolCaller {
    private let place: Place
    private let roots: [String]
    private var declarations: [String: Bool]
    private let fails: Bool
    private(set) var calls = 0

    init(place: Place, roots: [String] = [], declarations: [String: Bool] = [:], fails: Bool = false) {
        self.place = place
        self.roots = roots
        self.declarations = declarations
        self.fails = fails
    }

    /// The operator editing the project's declarations on disk.
    func declare(_ declarations: [String: Bool]) { self.declarations = declarations }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls += 1
        struct Unreachable: Error {}
        if fails { throw Unreachable() }
        let environments = declarations.mapValues { JSONValue.object(["production": .bool($0)]) }
        return .object(["structuredContent": .object([
            "Org": .string(place.organization), "Environment": .string(place.environment),
            "ProjectKey": .string(place.project),
            "Project": .object(["name": .string(place.project), "environments": .object(environments)]),
            "RootPaths": .array(roots.map { .string($0) }),
        ])])
    }
}

private let billing = Place(organization: "acme", project: "billing", environment: "staging")
private let api = Place(organization: "acme", project: "api", environment: "live")

/// A pool whose context client for every place is `context`, counting its starts.
private actor StartCount {
    private(set) var count = 0
    func bump() { count += 1 }
}

private func pool(_ context: any ToolCaller, starts: StartCount = StartCount()) -> PlaceClients {
    PlaceClients(start: { _, _ in await starts.bump(); return context }, stop: { _ in })
}

/// A window on `billing`, routing through `pool`, with the wiring's readers pointed at it the
/// way `WindowSession.start` points them — over a wiring with no binaries, so nothing spawns.
/// The wiring holds the window weakly: a test keeps the model in hand while it reads.
@MainActor
private func window(pool: PlaceClients) async throws -> (WindowModel, WakilWiring) {
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "acme", placeClients: pool)
    model.seedForTesting(
        providerId: "p", rootPath: "/billing/web", thoughts: 0,
        project: billing.project, environment: billing.environment)
    let empty = testScratchRoot.appendingPathComponent("place-contexts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let wiring = await WakilWiring.build(
        journalDirectory: empty, sessionId: "s1", executableDirectory: empty,
        environment: ["HOME": empty.path, "WAKIL_BIN_DIR": empty.path])
    wiring.useActiveContext(of: model)
    return (model, wiring)
}

/// `body` run as a dispatch made for `place` by `session`: an agent's, or the operator's when nil.
private func asCaller<T: Sendable>(
    _ place: Place, session: String? = "s1", _ body: @Sendable () async throws -> T
) async rethrows -> T {
    try await ActionRegistry.$dispatchCaller.withValue(DispatchCaller(place: place, session: session), operation: body)
}

/// A mutation priced like `db_run_mutation` in production and free elsewhere, so the only
/// thing that can refuse it is the gate deciding the caller's environment is production.
private func registerMutation(_ registry: ActionRegistry) async {
    await registry.register(Action(
        name: "test_mutate", description: "a mutation", kind: .mutate,
        schema: .object(["type": .string("object")]),
        handler: { _ in .object([:]) },
        price: (production: .block, otherwise: .allow)))
}

@MainActor
@Suite struct PlaceContextsTests {
    @Test func anOffScreenCallerSeesItsOwnRoots() async throws {
        let context = PinnedContext(place: api, roots: ["/api/server", "/api/worker"])
        let (model, wiring) = try await window(pool: pool(context))

        let roots = await asCaller(api) { await wiring.gitRoots.current() }

        #expect(roots == ["/api/server", "/api/worker"])
        #expect(model.gitRootPaths != roots, "the window's own roots are billing's")
        await wiring.shutdown()
    }

    @Test func anOffScreenCallersTerminalOpensInItsOwnPlace() async throws {
        let context = PinnedContext(place: api, roots: ["/api/server", "/api/worker"])
        let (model, wiring) = try await window(pool: pool(context))

        let shell = await asCaller(api) { await wiring.shellContext.current() }
        #expect(model.activeShellContext.project == "billing", "the window itself stays on billing")

        #expect(shell.org == "acme")
        #expect(shell.project == "api")
        #expect(shell.environment == "live")
        #expect(shell.rootPath == "/api/server")
        await wiring.shutdown()
    }

    /// The operator's dispatch reads the window's values whatever place it carries: that place
    /// can be stale by the time it is read, and the window is what the operator is looking at.
    @Test func anOperatorCallerSeesTheWindowsValuesWhereverItsPlace() async throws {
        let context = PinnedContext(place: api, roots: ["/api/server"])
        let starts = StartCount()
        let (model, wiring) = try await window(pool: pool(context, starts: starts))

        let shell = await asCaller(api, session: nil) { await wiring.shellContext.current() }
        let roots = await asCaller(api, session: nil) { await wiring.gitRoots.current() }

        #expect(shell.org == "acme")
        #expect(shell.project == "billing")
        #expect(shell.environment == "staging")
        #expect(shell.rootPath == "/billing/web")
        #expect(roots == model.gitRootPaths)
        #expect(await context.calls == 0)
        #expect(await starts.count == 0)
        await wiring.shutdown()
    }

    /// An agent reads its own place's values even while the screen shows that same place: mid
    /// switch, the screen's place is the old one while the window's values already move.
    @Test func anAgentOnTheScreensPlaceSeesItsOwnPlacesValues() async throws {
        let context = PinnedContext(place: billing, roots: ["/pinned/billing"])
        let (model, wiring) = try await window(pool: pool(context))

        let shell = await asCaller(billing) { await wiring.shellContext.current() }
        let roots = await asCaller(billing) { await wiring.gitRoots.current() }

        #expect(model.place == billing)
        #expect(roots == ["/pinned/billing"])
        #expect(shell.rootPath == "/pinned/billing")
        #expect(shell.project == "billing")
        await wiring.shutdown()
    }

    @Test func theContextIsReadOncePerPlaceAndAgainAfterRetainDropsIt() async throws {
        let context = PinnedContext(place: api, roots: ["/api/server"])
        let contexts = PlaceContexts(clients: pool(context))

        _ = try await contexts.context(for: api)
        _ = try await contexts.context(for: api)
        #expect(await context.calls == 1)

        await contexts.retain([])
        _ = try await contexts.context(for: api)
        #expect(await context.calls == 2)
    }

    @Test func aFailedResolveIsNotKept() async throws {
        let context = PinnedContext(place: api, fails: true)
        let contexts = PlaceContexts(clients: pool(context))

        await #expect(throws: (any Error).self) { try await contexts.context(for: api) }
        await #expect(throws: (any Error).self) { try await contexts.context(for: api) }

        #expect(await context.calls == 2)
    }
}

// MARK: - The gate prices by the caller's own place

@MainActor
@Test func theGateUsesTheAgentsPlacesProductionFlags() async throws {
    // `live` is production only because api's project says so; the window on billing has
    // declared nothing, so by its flags (the name rule) `live` is not production.
    let context = PinnedContext(place: api, roots: ["/api/server"], declarations: ["live": true])
    let (model, wiring) = try await window(pool: pool(context))
    let registry = model.registryForTesting
    await registerMutation(registry)

    await #expect(throws: ActionError.blockedInProduction("test_mutate")) {
        try await registry.dispatch(
            name: "test_mutate", params: .object([:]), origin: .agent,
            caller: DispatchCaller(place: api, session: "s1"), confirmation: nil)
    }
    _ = try await registry.dispatch(
        name: "test_mutate", params: .object([:]), origin: .agent,
        caller: DispatchCaller(place: billing, session: "s1"), confirmation: nil)
    await wiring.shutdown()
}

/// An agent on the screen's own place is still priced by its place's own flags, read through
/// its pinned client — not the window's, which a switch in flight may already have moved.
@MainActor
@Test func anAgentOnTheScreensPlaceIsPricedByItsOwnFlags() async throws {
    // billing's own project declares `staging` production; the window has declared nothing,
    // so by its flags (the name rule) `staging` is not.
    let context = PinnedContext(place: billing, declarations: ["staging": true])
    let (model, wiring) = try await window(pool: pool(context))
    let registry = model.registryForTesting
    await registerMutation(registry)

    await #expect(throws: ActionError.blockedInProduction("test_mutate")) {
        try await registry.dispatch(
            name: "test_mutate", params: .object([:]), origin: .agent,
            caller: DispatchCaller(place: billing, session: "s1"), confirmation: nil)
    }
    await wiring.shutdown()
}

/// The operator's dispatch is priced by the window's flags whatever place it carries.
@MainActor
@Test func anOperatorCallerIsPricedByTheWindowsFlags() async throws {
    let context = PinnedContext(place: api, declarations: ["live": true])
    let starts = StartCount()
    let (model, wiring) = try await window(pool: pool(context, starts: starts))
    let registry = model.registryForTesting
    await registerMutation(registry)

    _ = try await registry.dispatch(
        name: "test_mutate", params: .object([:]), origin: .ui,
        caller: DispatchCaller(place: api, session: nil), confirmation: nil)

    #expect(await starts.count == 0)
    await wiring.shutdown()
}

@MainActor
@Test func aFailedResolveFallsBackToTheNameRule() async throws {
    let production = Place(organization: "acme", project: "api", environment: "production")
    let context = PinnedContext(place: production, fails: true)
    let (model, wiring) = try await window(pool: pool(context))
    let registry = model.registryForTesting
    await registerMutation(registry)
    // The screen's project disarms `production`. Those are billing's declarations, not api's.
    await registry.setEnvironmentProduction(EnvironmentProduction(declarations: ["production": false]))

    await #expect(throws: ActionError.blockedInProduction("test_mutate")) {
        try await registry.dispatch(
            name: "test_mutate", params: .object([:]), origin: .agent,
            caller: DispatchCaller(place: production, session: "s1"), confirmation: nil)
    }
    await wiring.shutdown()
}

/// The agent stays in api; the operator visits it, its environment is declared production
/// while they are there, and they leave again. The window's own read of api is newer than the
/// one kept for the agent, so the agent's next mutation must be priced by it.
@MainActor
@Test func aWindowReadOfThePlaceReplacesTheAgentsKeptFlags() async throws {
    let context = PinnedContext(place: api, roots: ["/api/server"], declarations: ["live": false])
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "acme", context: ContextStore(client: context),
        placeClients: pool(context))
    model.seedForTesting(
        providerId: "p", rootPath: "/billing/web", thoughts: 0,
        project: billing.project, environment: billing.environment)
    let registry = model.registryForTesting
    await registerMutation(registry)
    func mutateAsAgent() async throws {
        _ = try await registry.dispatch(
            name: "test_mutate", params: .object([:]), origin: .agent,
            caller: DispatchCaller(place: api, session: "s1"), confirmation: nil)
    }
    try await mutateAsAgent()   // kept: `live` is not production

    await context.declare(["live": true])
    await model.refreshContext()   // the operator is on api now, and the window reads it
    #expect(model.place == api)
    model.seedForTesting(
        providerId: "p", rootPath: "/billing/web", thoughts: 0,
        project: billing.project, environment: billing.environment)

    await #expect(throws: ActionError.blockedInProduction("test_mutate")) { try await mutateAsAgent() }
}

// MARK: - The editor's file lists never answer one place from another's cache

/// A files client that answers `files_list` with where it is, after `delay`.
private actor NamedFiles: ToolCaller {
    private let name: String
    private let delay: UInt64
    private(set) var calls = 0

    init(_ name: String, delay: UInt64 = 0) {
        self.name = name
        self.delay = delay
    }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return .object(["structuredContent": .object(["from": .string(self.name)])])
    }
}

private func routedLists(window: NamedFiles, pinned: NamedFiles) -> EditorFileLists {
    let pool = PlaceClients(start: { _, _ in pinned }, stop: { _ in })
    let routed = PlaceRoutedCaller(role: .files, window: window, pool: pool)
    return EditorFileLists(files: routed)
}

private func list(_ lists: EditorFileLists, _ root: String) async throws -> JSONValue {
    try await lists.callTool(name: "files_list", arguments: .object(["root": .string(root)]), timeout: 10)
}

private func from(_ value: JSONValue) -> String? {
    guard case .object(let o) = value, case .object(let s)? = o["structuredContent"],
          case .string(let from)? = s["from"] else { return nil }
    return from
}

@Test func anOffScreenListingReachesThePoolEvenWithTheWindowsListKept() async throws {
    let windowFiles = NamedFiles("window")
    let pinned = NamedFiles("pool")
    let lists = routedLists(window: windowFiles, pinned: pinned)
    await lists.watch(roots: ["/shared"])
    #expect(from(try await list(lists, "/shared")) == "window")

    let agents = try await asCaller(api) { try await list(lists, "/shared") }

    #expect(from(agents) == "pool")
    #expect(await pinned.calls == 1)
    // And the window's kept list is still the window's.
    #expect(from(try await list(lists, "/shared")) == "window")
}

@Test func anOperatorListingNeverSharesAnAgentsReadInFlight() async throws {
    let windowFiles = NamedFiles("window")
    let pinned = NamedFiles("pool", delay: 200_000_000)
    let lists = routedLists(window: windowFiles, pinned: pinned)
    await lists.watch(roots: ["/shared"])

    let agent = Task { try await asCaller(api) { try await list(lists, "/shared") } }
    try await Task.sleep(nanoseconds: 50_000_000)
    let operators = try await list(lists, "/shared")

    #expect(from(operators) == "window")
    #expect(from(try await agent.value) == "pool")
    #expect(await windowFiles.calls >= 1)
}
