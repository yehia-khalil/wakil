import Foundation

/// The active organisation, project, environment and project root path a
/// shell is opened with — read **at dispatch time**, from whoever
/// actually knows.
///
/// **Why a box and not a value.** `term_open` folds
/// `WAKIL_ORG`/`WAKIL_PROJECT`/`WAKIL_ENVIRONMENT` into the shell's own
/// environment — those three and `TERM`, and no secret of its own — which
/// is the context a credentialed command is run against, and is exactly
/// why the agent may not run there. `rootPath` rides alongside them for a
/// different reason (walk-defects B1): it is `term_open`'s default `path`
/// when the caller names none, so ⌘K's param-less dispatch has somewhere
/// to open. The actions are registered once, in
/// `WakilWiring.build`, before any `WindowModel` exists; the active context changes for the
/// whole life of the app after that. A value captured at registration
/// would therefore be the launch context forever, which is the same
/// reasoning `MCPSocketServer`'s `caller` already follows for
/// the environment string the write gate judges.
///
/// **Why it has a source rather than being assigned to.** The window is
/// the authority on its own active context and already keeps it current
/// (`refreshContext`, `setOrganization`, `setEnvironment`); a second copy
/// here would be a second place the answer lives and a second thing to
/// forget to update. So this holds a closure back to the window and asks
/// it, every time.
///
/// **Empty until a source is installed, and empty members stay absent.**
/// `--dispatch` and most tests never install one, and
/// `terminalChildEnvironment` omits an empty member rather than exporting
/// it as an empty string. What an unwired shell gets is what it got before
/// this type existed.
///
/// A lock rather than an actor: `terminalActions` needs to be buildable
/// from `WindowModel.forTesting`, which is synchronous for the reason
/// `ActionRegistry.init`'s `initialActions:` doc comment gives, so
/// installing a source must not require an `await`.
public final class ActiveShellContext: @unchecked Sendable {
    public typealias Source =
        @Sendable () async -> (org: String, project: String, environment: String, rootPath: String)

    private let lock = NSLock()
    private var source: Source?

    public init() {}

    /// Installs (or replaces) the source. Called once per window, from the
    /// assembly, as soon as there is a window to ask.
    public func use(_ source: @escaping Source) {
        lock.lock()
        self.source = source
        lock.unlock()
    }

    /// The context as of right now. `("", "", "", "")` when no source has
    /// been installed — never a stale answer, and never a guess. Unlike
    /// the other three members, an installed source's `rootPath` is not
    /// actually empty in practice — `WindowModel.activeShellContext`
    /// already falls back to the operator's home directory — but this box
    /// answers `""` here too when unwired, and `term_open`'s own handler
    /// falls back to home a second time for that case.
    ///
    /// The lock is taken and released in a synchronous helper, never held
    /// across the `await`: Swift 6 makes `NSLock.lock()` unavailable from
    /// an async context precisely because holding one across a suspension
    /// is how a task that resumes on another thread deadlocks.
    public func current() async -> (org: String, project: String, environment: String, rootPath: String) {
        guard let source = installedSource() else { return ("", "", "", "") }
        return await source()
    }

    private func installedSource() -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }
}
