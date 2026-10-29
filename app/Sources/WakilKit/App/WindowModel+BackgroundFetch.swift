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
        updateTicketPoll()
        // The Ticket view reads again when Wakil comes back and its read is over 60 s old, and so
        // does In flight, whatever is on screen.
        if active {
            Task { @MainActor [weak self] in await self?.ticketActivated() }
            Task { @MainActor [weak self] in await self?.ticketNeedsRead(force: false) }
        }
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
        let registry = self.registry
        for root in roots where !changesInFlight.contains(root.root) {
            // Its own task, so a deadline or the operator's write on this root can cancel it: the
            // cancel reaches wakil-git, which stops git and frees the root (review I5).
            let fetch = Task<Result<JSONValue, Error>, Never> { @MainActor in
                do {
                    return .success(try await registry.dispatch(
                        name: "editor_changes_fetch", params: .object(["root": .string(root.root)]),
                        origin: .ui, caller: caller, confirmation: nil))
                } catch { return .failure(error) }
            }
            backgroundFetchCurrent = (root.root, { fetch.cancel() }, Task { _ = await fetch.value })
            let timeout = backgroundFetchTimeout
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { fetch.cancel() }
            }
            let outcome = await fetch.value
            deadline.cancel()
            if backgroundFetchCurrent?.root == root.root { backgroundFetchCurrent = nil }
            guard generation == changesGeneration else { return }
            switch outcome {
            case .success: changesRemoteNotes[root.root] = nil
            case .failure where fetch.isCancelled: break   // given up or pre-empted: nothing to say
            case .failure(let error): changesRemoteNotes[root.root] = statusDescribingFailure("editor_changes_fetch", error)
            }
        }
        await refreshPanes()
    }

    /// Cancels the background fetch running in `root`, if any, and returns once it has let go —
    /// so the operator's own write there runs instead of being refused (Rules 5 and 7).
    func preemptBackgroundFetch(_ root: String) async {
        guard let running = backgroundFetchCurrent, running.root == root else { return }
        backgroundFetchCurrent = nil
        running.cancel()
        await running.done.value
    }
}
