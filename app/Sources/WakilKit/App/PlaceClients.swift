import Foundation

/// The six Wakil-owned Go clients a handler can be routed through, named by binary.
public enum ClientRole: String, Sendable, CaseIterable {
    case context = "wakil-ctx", database = "wakil-db", http = "wakil-http", git = "wakil-git",
         files = "wakil-files", ticket = "wakil-ticket"
}

/// Clients pinned to an agent session's own place, used for its calls wherever the screen is.
/// Each is its own process, started with `WAKIL_ORG`,
/// `WAKIL_PROJECT` and `WAKIL_ENVIRONMENT` set to that place (`WakilWiring.pinnedEnvironment`),
/// so org A's credentials are reached only by a process launched for org A (Invariant 4). The
/// window's own clients are never re-pointed for an agent.
///
/// Lazy, at most one per (role, place): the first call starts it and concurrent first calls
/// share that one start. A start that fails is forgotten, so the next call tries again.
/// `WindowModel` calls `retain` with the places still in use whenever `agentPlace` changes.
/// After `stopAll` it starts nothing more: a call still in flight as the window closes would
/// otherwise start a process nothing is left to stop.
public actor PlaceClients {
    private struct PinnedKey: Hashable {
        let role: ClientRole
        let place: Place
    }

    private let start: @Sendable (ClientRole, Place) async throws -> any ToolCaller
    private let stop: @Sendable (any ToolCaller) async -> Void
    private var clients: [PinnedKey: Task<any ToolCaller, Error>] = [:]
    private var stopped = false

    public init(
        start: @escaping @Sendable (ClientRole, Place) async throws -> any ToolCaller,
        stop: @escaping @Sendable (any ToolCaller) async -> Void
    ) {
        self.start = start
        self.stop = stop
    }

    public func client(_ role: ClientRole, for place: Place) async throws -> any ToolCaller {
        if stopped { throw PlaceClientError.stopped(role.rawValue) }
        let key = PinnedKey(role: role, place: place)
        let task: Task<any ToolCaller, Error>
        if let running = clients[key] {
            task = running
        } else {
            let start = start
            task = Task { try await start(role, place) }
            clients[key] = task
        }
        do {
            return try await task.value
        } catch {
            // Only this start's own entry: a retain may have replaced it meanwhile.
            if clients[key] == task { clients[key] = nil }
            throw error
        }
    }

    /// Stops and forgets every client whose place is not in `places`. A start still in flight
    /// is waited for and stopped once it lands, so it cannot outlive its place.
    public func retain(_ places: Set<Place>) async {
        let dropped = clients.filter { !places.contains($0.key.place) }
        for key in dropped.keys { clients[key] = nil }
        await stopEach(Array(dropped.values))
    }

    /// The roles with a client kept (started or starting) for `place`.
    func startedRoles(for place: Place) -> Set<ClientRole> {
        Set(clients.keys.filter { $0.place == place }.map(\.role))
    }

    public func stopAll() async {
        stopped = true
        let all = Array(clients.values)
        clients = [:]
        await stopEach(all)
    }

    private func stopEach(_ tasks: [Task<any ToolCaller, Error>]) async {
        for task in tasks {
            if let client = try? await task.value { await stop(client) }
        }
    }
}

/// The client a handler is registered with: the pool's client pinned to the caller's place when
/// an agent session made the dispatch it runs in (`pinnedPlace(of:)`), even while the screen
/// shows that place; the window's own for anything else — the operator's dispatches, a place
/// with no organisation, or no caller at all (a read the window makes outside a dispatch). Read per
/// call from `ActionRegistry.dispatchCaller`, so the agent's tool schemas need no project or
/// environment argument (Invariant 5).
public struct PlaceRoutedCaller: ToolCaller {
    let role: ClientRole
    let window: any ToolCaller
    let pool: PlaceClients

    public init(role: ClientRole, window: any ToolCaller, pool: PlaceClients) {
        self.role = role
        self.window = window
        self.pool = pool
    }

    public func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        if let place = pinnedPlace(of: ActionRegistry.dispatchCaller) {
            return try await pool.client(role, for: place)
                .callTool(name: name, arguments: arguments, timeout: timeout)
        }
        return try await window.callTool(name: name, arguments: arguments, timeout: timeout)
    }
}
