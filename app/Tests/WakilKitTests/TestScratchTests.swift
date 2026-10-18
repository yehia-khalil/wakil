import Foundation
import Testing
@testable import WakilKit

/// A root left by a run that died is swept; a root a live run is still
/// using is not. The second half is the one that matters: other worktrees
/// on this machine run this suite against the same `$TMPDIR`, and a sweep
/// that removed their root would break their run mid-flight (#279).
@Test func theSweepRemovesADeadRunsScratchRootAndLeavesALiveOnesAlone() throws {
    let parent = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    // A pid that is certainly dead: a child we started, and reaped.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    let dead = parent.appendingPathComponent("\(child.processIdentifier)")
    let live = parent.appendingPathComponent("\(getpid())")
    let unrelated = parent.appendingPathComponent("not-a-pid")
    for dir in [dead, live, unrelated] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    sweepStaleTestScratchRoots(in: parent)

    #expect(!FileManager.default.fileExists(atPath: dead.path))
    #expect(FileManager.default.fileExists(atPath: live.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

/// A pane's rc directory lands under the root its store was given, not in
/// the process temp dir. A pane a test never closes skips the teardown
/// that removes it — 1,241 of them sat in `$TMPDIR` when #279 was filed —
/// so where it is made is what decides whether the run's exit clears it.
@Test func aTerminalStoresRcDirectoryLandsUnderTheScratchRootItWasGiven() async throws {
    let root = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let store = TerminalStore(scratchRoot: root)
    _ = try await store.open(
        paneId: "t", path: home.path, shell: "/bin/bash", environment: ["HOME": home.path])

    let made = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    #expect(made.contains { $0.hasPrefix("wakil-terminal-") })

    await store.shutdownAll()
}
