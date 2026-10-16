import Foundation

/// The window's git watcher, told which roots to watch (3a-i; extracted from
/// `WindowModel` in PR 3 of the split).
///
/// **Chained, not merely awaited.** Two syncs can overlap — a refresh landing
/// during a project switch — and each hops to the watcher's actor; chaining is
/// what keeps the watcher's last instruction the last sync's decision.
///
/// **Returning means the watcher has been told.** A sync that finds its
/// decision already made still waits for that instruction to land.
@MainActor
final class GitRootWatcher {
    enum Outcome: Equatable { case unchanged, started, stopped }

    let watcher: any RootWatcher
    /// The roots the watcher was last asked to watch; empty when it is stopped.
    private(set) var watchedRoots: [String] = []
    private var chain: Task<Void, Never>?

    init(watcher: any RootWatcher) {
        self.watcher = watcher
    }

    func sync(to wanted: [String], changed: @escaping @Sendable (String) async -> Void) async -> Outcome {
        await sync(to: wanted, changedPaths: { root, _ in await changed(root) })
    }

    /// As `sync(to:changed:)`, handing each burst's paths through (final review I4).
    func sync(to wanted: [String], changedPaths: @escaping @Sendable (String, [String]?) async -> Void) async -> Outcome {
        guard wanted != watchedRoots else {
            await chain?.value
            return .unchanged
        }
        watchedRoots = wanted
        let previous = chain
        let watcher = watcher
        let next = Task {
            await previous?.value
            if wanted.isEmpty {
                await watcher.stop()
            } else {
                await watcher.watch(roots: wanted, window: .milliseconds(300), changedPaths: changedPaths)
            }
        }
        chain = next
        await next.value
        return wanted.isEmpty ? .stopped : .started
    }
}
