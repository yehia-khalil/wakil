import Foundation
import Testing
@testable import WakilKit

/// Records what it was told, in order.
private actor RecordingWatcher: RootWatcher {
    private(set) var calls: [String] = []
    func watch(roots: [String], window: Duration, changed: @escaping @Sendable (String) async -> Void) async {
        calls.append("watch " + roots.joined(separator: ","))
    }
    func stop() async { calls.append("stop") }
}

@MainActor
@Test func theSameRootsTwiceStartOneWatch() async {
    let recorder = RecordingWatcher()
    let watcher = GitRootWatcher(watcher: recorder)
    #expect(await watcher.sync(to: ["/a", "/b"], changed: { _ in }) == .started)
    #expect(await watcher.sync(to: ["/a", "/b"], changed: { _ in }) == .unchanged)
    #expect(await recorder.calls == ["watch /a,/b"])
    #expect(watcher.watchedRoots == ["/a", "/b"])
}

@MainActor
@Test func noRootsStopsAndForgetsThem() async {
    // The org-switch reset: `invalidateForOrgChange` ends in a sync to [].
    let recorder = RecordingWatcher()
    let watcher = GitRootWatcher(watcher: recorder)
    _ = await watcher.sync(to: ["/a"], changed: { _ in })
    #expect(await watcher.sync(to: [], changed: { _ in }) == .stopped)
    #expect(await recorder.calls == ["watch /a", "stop"])
    #expect(watcher.watchedRoots.isEmpty)
}

@MainActor
@Test func noRootsWhenNothingIsWatchedTellsTheWatcherNothing() async {
    let recorder = RecordingWatcher()
    let watcher = GitRootWatcher(watcher: recorder)
    #expect(await watcher.sync(to: [], changed: { _ in }) == .unchanged)
    #expect(await recorder.calls.isEmpty)
}

/// Holds its first `watch` until released, so later syncs queue behind one still in flight.
private actor GatedWatcher: RootWatcher {
    private(set) var calls: [String] = []
    private var held = true
    private var gate: CheckedContinuation<Void, Never>?
    func watch(roots: [String], window: Duration, changed: @escaping @Sendable (String) async -> Void) async {
        calls.append("watch " + roots.joined(separator: ","))
        // Only the first call waits: a second one arriving early (a broken chain) must
        // fail the order assertion, not overwrite the gate and hang the test.
        guard held, calls.count == 1 else { return }
        await withCheckedContinuation { continuation in
            if held { gate = continuation } else { continuation.resume() }
        }
    }
    func stop() async { calls.append("stop") }
    func release() {
        held = false
        gate?.resume()
        gate = nil
    }
}

@MainActor
@Test func overlappingSyncsReachTheWatcherInOrder() async {
    // Each sync is started only once the one before it has made its decision, so the
    // order they START in is fixed; what the test asserts is that the watcher hears
    // them in that order even though the first is still in flight when the others start.
    let recorder = GatedWatcher()
    let watcher = GitRootWatcher(watcher: recorder)
    let first = Task { await watcher.sync(to: ["/p"], changed: { _ in }) }
    while await recorder.calls.isEmpty { await Task.yield() }
    let second = Task { await watcher.sync(to: ["/q"], changed: { _ in }) }
    while watcher.watchedRoots != ["/q"] { await Task.yield() }
    let third = Task { await watcher.sync(to: [], changed: { _ in }) }
    while !watcher.watchedRoots.isEmpty { await Task.yield() }
    #expect(await recorder.calls == ["watch /p"])
    await recorder.release()
    #expect(await first.value == .started)
    #expect(await second.value == .started)
    #expect(await third.value == .stopped)
    #expect(await recorder.calls == ["watch /p", "watch /q", "stop"])
}
