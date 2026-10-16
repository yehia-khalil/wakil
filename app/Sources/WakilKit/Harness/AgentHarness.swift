import Foundation

/// The abstraction Wakil drives an AI coding agent through. Per spec §3.1
/// (Invariant 1), nothing outside an `AgentHarness` implementation may know
/// which underlying agent is actually running — `ClaudeCodeCLIHarness` is
/// this phase's only implementation, and a Node/TypeScript Agent SDK sidecar
/// remains available later as a second one rather than a rewrite of callers.
public protocol AgentHarness: Sendable {
    /// Starts a session under `sessionId`, which the caller always
    /// generates: Wakil mints every agent session id it runs, and that is
    /// what makes the resume list authoritative rather than reconstructed
    /// (charter open question 5).
    ///
    /// `resumingFrom` is the session to continue. `nil` starts fresh.
    /// A non-nil value means a **fork**: the implementation continues that
    /// session's conversation under the new `sessionId`, leaving the
    /// original transcript untouched. Continuing a session in place is not
    /// offered, and the reason is measured rather than stylistic — see
    /// `buildLaunch`.
    ///
    /// `workingDirectory` is the directory the session runs in. It is a
    /// per-session value, not a property of the harness: a fresh session
    /// runs in the project's first declared root and a resumed one in the
    /// directory its own transcript records.
    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws

    /// Sends one turn of user text into the running session.
    func send(_ text: String) async throws

    /// The stream of `HarnessEvent`s this session has decoded from the
    /// agent's output, past and future. Callers consume it with `for await`.
    func events() -> AsyncStream<HarnessEvent>

    /// Asks the agent to stop whatever it is currently doing without ending
    /// the session — the session can still be sent to afterwards.
    func interrupt() async

    /// Ends the session and releases whatever resources the implementation
    /// holds (e.g. terminates a child process). Safe to call more than once.
    func stop() async
}
