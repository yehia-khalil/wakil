import Foundation

/// 3a-iii-a: Wakil fetches each root every five minutes while an editor pane is open and the app is
/// frontmost, so the Changes view's ↑ ↓ are fresh without a press (call 9). Quiet: a failure is a
/// note on the root's header line, never an error under its box. Each fetch is the same
/// `editor_changes_fetch` the ▾ menu dispatches (Invariant 2), and a root with a write in flight is
/// skipped rather than refused.
extension WindowModel {
    public var backgroundFetchRunning: Bool { backgroundFetchTask != nil }

    /// Starts or stops the loop for the window's state now: an editor pane open and the app active.
    public func updateBackgroundFetch() {
        let wanted = appActive && layoutSnapshot.panes.contains { $0.kind == "editor" }
        if wanted { startBackgroundFetch() } else { stopBackgroundFetch() }
    }

    public func setAppActive(_ active: Bool) {
        appActive = active
        updateBackgroundFetch()
    }

    public func startBackgroundFetch() {
        guard backgroundFetchTask == nil else { return }
        backgroundFetchTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                do { try await self.backgroundFetchSleep(self.backgroundFetchInterval) } catch { return }
                if Task.isCancelled { return }
                await self.backgroundFetchOnce()
            }
        }
    }

    public func stopBackgroundFetch() {
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
    }

    /// One fetch of every root that is a repository and has no write running.
    public func backgroundFetchOnce() async {
        let roots = (await gitStatus?.roots ?? []).filter { $0.error == nil && !changesInFlight.contains($0.root) }
        let generation = changesGeneration
        let caller = DispatchCaller(place: place, session: nil)
        for root in roots {
            do {
                _ = try await registry.dispatch(name: "editor_changes_fetch", params: .object(["root": .string(root.root)]),
                                                origin: .ui, caller: caller, confirmation: nil)
                guard generation == changesGeneration else { return }
                changesRemoteNotes[root.root] = nil
            } catch {
                guard generation == changesGeneration else { return }
                changesRemoteNotes[root.root] = statusDescribingFailure("editor_changes_fetch", error)
            }
        }
        await refreshPanes()
    }
}
