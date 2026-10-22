import Foundation

/// Which agent is running in a project or an environment of it, asked live (2e-ii).
///
/// `registerStandardActions` runs before the window exists, so the pin check on renaming and
/// removing a project or environment (Invariant 5) cannot capture `WindowModel.agents`. It
/// captures this box instead; `WakilWiring.useActiveContext(of:)` points it at the window, as
/// it does `ActiveShellContext`. Unwired — `--dispatch` has no window and so no agent — it
/// answers nil.
public final class ActiveAgentLookup: @unchecked Sendable {
    public typealias Source = @Sendable (_ project: String, _ environment: String?) async -> String?

    private let lock = NSLock()
    private var source: Source?

    public init() {}

    public func use(_ source: @escaping Source) {
        lock.lock()
        self.source = source
        lock.unlock()
    }

    /// The running agent's name, or nil. A synchronous helper takes the lock: Swift 6 forbids
    /// holding an `NSLock` across a suspension (see `ActiveShellContext.current`).
    public func agent(in project: String, environment: String?) async -> String? {
        guard let source = installedSource() else { return nil }
        return await source(project, environment)
    }

    private func installedSource() -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }
}
