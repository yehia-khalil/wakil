import Foundation
import Observation

/// One place's agent: its harness, its session, its thread and its turn (background agents,
/// 3 of 4). `WindowModel.agents` holds one per `Place`, so an agent keeps working, and its
/// events keep landing in its own thread, while the screen shows another place. The window's
/// `thoughts`, `turnInFlight`, `sessionId`, `sessionStarted` and `lineageRoot` read the
/// on-screen place's entry.
///
/// Plain state: `WindowModel` starts, swaps and stops the harness and runs the pump, as it did
/// when these were its own fields. `@Observable` so a view reading the screen's entry through
/// the window redraws when the entry changes.
@MainActor
@Observable
public final class PlaceAgent {
    /// The place the agent works in, fixed for the entry's life — except that renaming its project
    /// or environment moves an entry with no live session to the new name
    /// (`WindowModel.carryAgents`), so its conversation is not lost with the old one.
    public internal(set) var place: Place
    /// The live session's harness, or nil before the first turn.
    var harness: AgentHarness?
    /// 3a-iii-b: the composed instructions this session last received — at launch, or in a turn
    /// since. nil until the session's first turn records it.
    var launchedInstructions: String?
    /// The id the running child was started with; set and cleared with `harness`.
    public internal(set) var sessionId: String?
    /// The socket the live session's shim reaches Wakil on (background agents 3 of 4, Task 4):
    /// the one the place opened when it was shown (`WindowModel.openShownSocket`), or for a
    /// replacement session one started before its harness; stopped when that harness is
    /// replaced or the entry ends.
    var socket: (any AgentSocket)?
    /// Why the live session has no socket, when it would not start: the session runs without
    /// Wakil's own tools (Rule 7) and the status says so after each of its turns.
    var socketFailure: String?
    /// Set while a first turn starts this place's session; a turn typed meanwhile waits here
    /// and then goes to that session (Rule 5), as a turn typed during a turn goes to the
    /// running harness.
    var startWaiters: [CheckedContinuation<Void, Never>]?
    public internal(set) var thoughts: [ThoughtRow] = []
    /// Monotonic row ids (`WindowModel.thoughts`), per thread.
    var nextThoughtId = 0
    /// True from a successful `send` to the `.result` that ends the turn.
    public internal(set) var turnInFlight = false
    /// A turn ended while the place was off screen, and the operator has not been back since
    /// (background agents 4 of 4): its chip says done. Cleared when the place is activated.
    public internal(set) var unseenResult = false
    /// The session failed — a turn ended in error, or its process went away — while the place
    /// was off screen, and the operator has not been back since. Cleared as `unseenResult` is.
    public internal(set) var unseenFailure = false
    /// Whether the place's environment is production, for its chip: the name rule until its own
    /// project's flags are read (`WindowModel.refreshChipProduction(of:)`).
    public internal(set) var productionEnvironment: Bool
    /// Bumped by every write of `productionEnvironment` and every read started for one, so a
    /// read that lands after a newer one is dropped (`WindowModel.refreshChipProduction(of:)`).
    var productionReads = 0
    /// `productionEnvironment` from the place's own project's flags: its declaration wins once
    /// read, and the name is the default for an environment that declares nothing (Decision 26).
    func showProduction(_ flags: EnvironmentProduction) {
        productionEnvironment = flags.isProduction(place.environment)
    }

    /// The agent's own `Bash` calls, for backfilling a terminal pane opened after them.
    let mirror: TerminalMirrorFeed
    var eventPump: Task<Void, Never>?
    /// Bumped before a harness is stopped, so the pump drops what the old stream still buffers.
    var eventPumpGeneration = 0
    /// The conversation this place is in: what its arrangement is filed under.
    public internal(set) var lineageRoot: String?
    /// The conversation id minted for this place's work, before or with its first session.
    public internal(set) var assignedSessionId: String?
    /// Whether work has begun here: the Landing draws until it has.
    public internal(set) var sessionStarted = false
    /// The provider the running session was built for; the window's `providerId` is the one a
    /// new session starts on.
    public internal(set) var providerId: String

    init(place: Place, providerId: String, mirror: TerminalMirrorFeed) {
        self.place = place
        self.providerId = providerId
        self.mirror = mirror
        self.productionEnvironment = isProductionEnvironment(place.environment)
    }

    /// Whom this agent's calls are for: its own place and session, wherever the screen is.
    public var caller: DispatchCaller { DispatchCaller(place: place, session: sessionId) }

    /// The canvas this agent's dispatches read and write: its place in its conversation. Nil
    /// with no project, which has no arrangement.
    public var layoutScope: LayoutScope? {
        guard !place.project.isEmpty else { return nil }
        return LayoutScope(
            organization: place.organization, project: place.project,
            environment: place.environment, lineageRoot: lineageRoot)
    }

    /// Lets every turn waiting on the session's start go on.
    func releaseStartWaiters() {
        let waiters = startWaiters ?? []
        startWaiters = nil
        for waiter in waiters { waiter.resume() }
    }

    /// Appends one row under the next id.
    func appendRow(label: String, detail: String, isError: Bool = false) {
        thoughts.append(ThoughtRow(id: nextThoughtId, label: label, detail: detail, isError: isError))
        nextThoughtId += 1
    }
}

/// The socket one agent session reaches Wakil's own tools on: an `MCPSocketServer` in the app,
/// a recorder in tests. Stopping it stops new connections; one already open finishes.
public protocol AgentSocket: Sendable {
    func stop() async
}

extension MCPSocketServer: AgentSocket {}

/// Starts the socket at `path`, answering every call for the caller the closure returns. The app
/// builds an `MCPSocketServer` and starts it; a throw is the socket that would not bind.
public typealias AgentSocketFactory =
    @Sendable (String, @escaping @Sendable () async -> DispatchCaller) async throws -> any AgentSocket

/// No socket: the window a test builds when it does not look at sockets.
struct NoAgentSocket: AgentSocket {
    func stop() async {}
}

/// `<tmp>/wakil-<agentSessionId>.sock`: one path per agent session.
///
/// **The whole session id, and nothing else.** A session id is a UUID, unique on its own, so no
/// two sessions share a path: a prefix could collide, and the second `start` would unlink the
/// first's socket and take the calls of a shim that reconnected. Leaving the window's id out
/// is what keeps the path short: `sun_path` is 104 bytes with its terminator, the path is the
/// directory plus 48, so a directory of up to 55 characters fits — the per-user temporary
/// directory is 48 on the machines measured.
public func agentSocketPath(
    agentSessionId: String, directory: URL = FileManager.default.temporaryDirectory
) -> String {
    directory.appendingPathComponent("wakil-\(agentSessionId).sock").path
}
