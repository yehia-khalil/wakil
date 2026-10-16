import Foundation
import Testing
@testable import WakilKit

@Suite struct GitWatcherTests {
    @Test func watchWakesOnSourceAndIndexButNotObjects() {
        #expect(gitWatchWakes("/p/api/app/Booking.php", root: "/p/api"))
        #expect(gitWatchWakes("/p/api/.git/index", root: "/p/api"))
        #expect(gitWatchWakes("/p/api/.git/HEAD", root: "/p/api"))
        #expect(gitWatchWakes("/p/api/.git/refs/heads/main", root: "/p/api"))
        #expect(!gitWatchWakes("/p/api/.git/objects/ab/cdef", root: "/p/api"))
        #expect(!gitWatchWakes("/p/api/.git/logs/HEAD", root: "/p/api"))
        #expect(!gitWatchWakes("/p/api/.git/index.lock", root: "/p/api"))
    }

    /// A burst is one refresh — **while it is one burst by the debounce's own rule**: no gap of
    /// `window` (300 ms) between its writes, and all of them inside `maxWait` (1 s) of the first.
    /// The writes are spaced 40 ms apart, past FSEvents' 50 ms latency often enough that every
    /// few writes is a delivery of its own, so a watcher that refreshed per delivery counts
    /// several. Under load the writes can stretch: a burst longer than 1 s legitimately fires
    /// once a second, and a stall of 300 ms legitimately ends one burst and starts another. So
    /// the test measures the burst it actually wrote and allows exactly what the rule allows —
    /// one refresh for a clean burst, one more per second it ran and per stall — which a
    /// watcher without the debounce still overshoots.
    @Test(.timeLimit(.minutes(1))) func aBurstOfWritesIsOneRefresh() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.resolvingSymlinksInPath().path
        let count = GitWatchCounter()
        let w = FSEventsRootWatcher()
        await w.watch(roots: [root], window: .milliseconds(300)) { _ in await count.bump() }
        let clock = ContinuousClock()
        let first = clock.now
        var last = first
        var stalls = 0
        for i in 0..<12 {
            let now = clock.now
            // A margin under the 300 ms window: FSEvents' own delivery jitter rides on top.
            if now - last > .milliseconds(150) { stalls += 1 }
            last = now
            try "x\(i)".write(toFile: root + "/f\(i).txt", atomically: false, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(40))
        }
        let span = last - first
        try await Task.sleep(for: .seconds(2))
        await w.stop()
        let refreshes = await count.value
        // A margin under `maxWait` too, for the same jitter.
        let seconds = Int((span + .milliseconds(300)) / .seconds(1))
        let allowed = 1 + seconds + stalls
        #expect(refreshes >= 1, "the burst refreshed nothing")
        #expect(refreshes <= allowed,
                "\(refreshes) refreshes for a burst of \(span) with \(stalls) stall(s); the rule allows \(allowed)")
    }

    /// Final review I4: a burst reports the paths that woke it, under the root as the caller
    /// named it — not FSEvents' real path (`/private/var/…` for `/var/…`).
    @Test(.timeLimit(.minutes(1))) func aWakeReportsTheBurstsPathsUnderTheRootAsNamed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.path
        let seen = GitWatchPathsSeen()
        let w = FSEventsRootWatcher()
        await w.watch(roots: [root], window: .milliseconds(300)) { r, paths in await seen.add(r, paths) }
        try await Task.sleep(for: .milliseconds(200))
        try "x".write(toFile: root + "/a.txt", atomically: false, encoding: .utf8)
        try "y".write(toFile: root + "/b.txt", atomically: false, encoding: .utf8)
        var spins = 0
        while await !seen.paths.isSuperset(of: [root + "/a.txt", root + "/b.txt"]), spins < 50 {
            spins += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        await w.stop()
        let paths = await seen.paths
        #expect(await seen.roots == [root])
        #expect(paths.isSuperset(of: [root + "/a.txt", root + "/b.txt"]), "\(paths)")
    }

    /// R12: the debounce is bounded. Writes every 100 ms for 3 s never go quiet for 300 ms,
    /// so a debounce that only waits for quiet would refresh nothing until they stop; one
    /// that also fires 1 s after a burst's first event refreshes during it.
    @Test(.timeLimit(.minutes(1))) func continuousWritesStillRefreshEverySecond() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.resolvingSymlinksInPath().path
        let count = GitWatchCounter()
        let w = FSEventsRootWatcher()
        await w.watch(roots: [root], window: .milliseconds(300)) { _ in await count.bump() }
        try await Task.sleep(for: .milliseconds(500))
        let settled = await count.value
        for i in 0..<30 {
            try "x\(i)".write(toFile: root + "/f.txt", atomically: false, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(100))
        }
        let during = await count.value - settled
        await w.stop()
        #expect(during >= 2, "refreshes during 3 s of continuous writes: \(during)")
    }

    /// A write that lands only under `.git/objects/` wakes nothing, and a watcher that was
    /// stopped calls nothing afterwards.
    @Test(.timeLimit(.minutes(1))) func objectsAloneAndAStoppedWatcherWakeNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git/objects/ab"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.resolvingSymlinksInPath().path
        let count = GitWatchCounter()
        let w = FSEventsRootWatcher()
        await w.watch(roots: [root], window: .milliseconds(300)) { _ in await count.bump() }
        // FSEvents can hand a new stream the directories created just before it started
        // (measured: `kFSEventStreamEventIdSinceNow` still delivered them), so the count is
        // taken once those have settled and the writes are measured against it.
        try await Task.sleep(for: .seconds(1))
        let settled = await count.value
        try "o".write(toFile: root + "/.git/objects/ab/cdef", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))
        #expect(await count.value == settled)
        await w.stop()
        try "x".write(toFile: root + "/after-stop.txt", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))
        #expect(await count.value == settled)
    }
}

actor GitWatchCounter { var value = 0; func bump() { value += 1 } }

// MARK: - Linked worktrees (fix round 1, R8)

/// Runs git with no global or system config, so the operator's hooks, fsmonitor or
/// signing settings cannot change what a test sees.
@discardableResult
private func runGit(_ args: [String], in dir: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.environment = [
        "PATH": "/usr/bin:/bin", "HOME": dir, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    ]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard p.terminationStatus == 0 else {
        throw NSError(domain: "git", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "git \(args): \(text)"])
    }
    return text
}

/// A main checkout with one commit and a linked worktree beside it, both real paths.
private func repoWithWorktree() throws -> (main: String, worktree: String, cleanup: URL) {
    let top = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let main = top.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    let mainPath = realpathForTest(main.path)
    try runGit(["init", "-q", "-b", "main"], in: mainPath)
    try "one\n".write(toFile: mainPath + "/a.txt", atomically: true, encoding: .utf8)
    try runGit(["add", "a.txt"], in: mainPath)
    try runGit(["commit", "-q", "-m", "one"], in: mainPath)
    try runGit(["worktree", "add", "-q", "-b", "side", "../wt"], in: mainPath)
    return (mainPath, realpathForTest(top.appendingPathComponent("wt").path), top)
}

private func realpathForTest(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
}

extension GitWatcherTests {
    @Test func aLinkedWorktreesGitDirWakesOnlyOnIndexHeadAndRefs() {
        let paths = GitWatchPaths(
            root: "/w/wt", gitDir: "/w/main/.git/worktrees/wt", commonDir: "/w/main/.git")
        #expect(paths.wakes("/w/wt/src/a.php"))
        #expect(paths.wakes("/w/main/.git/worktrees/wt/index"))
        #expect(paths.wakes("/w/main/.git/worktrees/wt/HEAD"))
        #expect(paths.wakes("/w/main/.git/refs/heads/side"))
        #expect(paths.wakes("/w/main/.git/packed-refs"))
        #expect(!paths.wakes("/w/main/.git/worktrees/wt/index.lock"))
        #expect(!paths.wakes("/w/main/.git/worktrees/wt/logs/HEAD"))
        #expect(!paths.wakes("/w/main/.git/objects/ab/cdef"))
        #expect(!paths.wakes("/w/main/.git/index"), "the main checkout's index is not this root's")
        #expect(!paths.wakes("/w/main/.git/HEAD"), "nor is its HEAD")
        #expect(!paths.wakes("/w/main/.git/worktrees/other/index"), "nor a sibling's index")
        #expect(!paths.wakes("/w/main/.git/refs/heads/x.lock"))
    }

    @Test func aMainCheckoutIgnoresItsWorktreesIndexes() {
        #expect(!gitWatchWakes("/p/api/.git/worktrees/wt/index", root: "/p/api"))
        #expect(gitWatchWakes("/p/api/.git/index", root: "/p/api"))
    }

    @Test func resolvingALinkedWorktreeFindsItsGitDirAndCommonDir() throws {
        let (main, wt, top) = try repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: top) }
        let paths = GitWatchPaths.resolve(root: wt)
        #expect(paths.root == wt)
        #expect(paths.gitDir == main + "/.git/worktrees/wt")
        #expect(paths.commonDir == main + "/.git")
        #expect(GitWatchPaths.resolve(root: main) == GitWatchPaths(root: main, gitDir: nil, commonDir: nil))
    }

    @Test(.timeLimit(.minutes(1))) func gitAddInsideALinkedWorktreeWakesItOnce() async throws {
        let (_, wt, top) = try repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: top) }
        // The edit comes first and settles: what is measured is the `git add`, which writes
        // only outside the worktree's own directory.
        try "two\n".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        let count = GitWatchCounter()
        let w = FSEventsRootWatcher()
        await w.watch(roots: [wt], window: .milliseconds(300)) { _ in await count.bump() }
        try await Task.sleep(for: .seconds(1))
        let settled = await count.value
        try runGit(["add", "a.txt"], in: wt)
        try await Task.sleep(for: .seconds(1.5))
        await w.stop()
        #expect(await count.value == settled + 1)
    }

    @Test(.timeLimit(.minutes(1))) func gitAddInASiblingWorktreeDoesNotWakeTheMainCheckout() async throws {
        let (main, wt, top) = try repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: top) }
        try "two\n".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        let count = GitWatchCounter()
        let w = FSEventsRootWatcher()
        await w.watch(roots: [main], window: .milliseconds(300)) { _ in await count.bump() }
        try await Task.sleep(for: .seconds(1))
        let settled = await count.value
        try runGit(["add", "a.txt"], in: wt)
        try await Task.sleep(for: .seconds(1.5))
        await w.stop()
        #expect(await count.value == settled)
    }
}

actor GitWatchPathsSeen {
    private(set) var roots: Set<String> = []
    private(set) var paths: Set<String> = []
    func add(_ root: String, _ p: [String]?) {
        roots.insert(root)
        paths.formUnion(p ?? [])
    }
}
