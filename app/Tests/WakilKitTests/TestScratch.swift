import Foundation

// Not a `*Tests.swift` file: it holds no tests, only the one helper every
// other file in this target shares, so it lives on its own rather than
// inside whichever test file happened to need it first.

/// This run's scratch directory: `$TMPDIR/wakil-tests/<pid>`. Every test
/// that needs a directory or file on disk makes it under here rather than
/// in the temp dir itself, and the whole root is removed when the process
/// exits (#279).
///
/// **Per run, not per test.** A `defer { removeItem }` at each of ~180
/// sites is a leak each time one is forgotten, and a crash skips every
/// `defer` anyway. One root per process is removed at `exit`, and a root
/// a crashed run left behind is swept by the next run's first use.
///
/// **Under one shared parent, not beside everything else in `$TMPDIR`.**
/// The sweep lists what it sweeps, and listing `$TMPDIR` itself — 180,000
/// entries when #279 was filed — took 7 seconds, inside this lazy
/// initialiser, with every test that reached for the root blocked behind
/// it. The parent holds only other runs' roots.
///
/// **Why not `TMPDIR`.** Foundation ignores it on Darwin: set in the
/// environment or by `setenv`, `NSTemporaryDirectory()` still answers the
/// `confstr` per-user dir. Measured, and the issue measured the same with a
/// full run — so the redirect has to be here, in the tests.
///
/// A global `let` is lazily initialised exactly once, thread-safely, which
/// is what a suite running its tests in parallel needs.
let testScratchRoot: URL = {
    sweepStaleTestScratchRoots(in: testScratchParent)
    try? FileManager.default.createDirectory(at: testScratchRootPath, withIntermediateDirectories: true)
    // `atexit` takes a C function pointer, which cannot capture a local —
    // so the handler reads the path from its own global rather than
    // rebuilding it, and the two can never name different directories.
    atexit { try? FileManager.default.removeItem(at: testScratchRootPath) }
    return testScratchRootPath
}()

/// Where every run's root lives, each named by its pid. The sweep reads the
/// pid back off the name, so nothing else belongs in here.
private let testScratchParent = FileManager.default.temporaryDirectory
    .appendingPathComponent("wakil-tests", isDirectory: true)

/// Where `testScratchRoot` is, without the side effects of making it.
private let testScratchRootPath = testScratchParent
    .appendingPathComponent("\(getpid())", isDirectory: true)

/// Removes every `<pid>` root under `parent` whose pid is no longer running.
/// A live pid's root is kept: another worktree on this machine may be
/// running the suite right now against the same temp dir. A name that is
/// not a pid is not ours and is left alone.
func sweepStaleTestScratchRoots(in parent: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    for name in names {
        guard let pid = pid_t(name), pid > 0 else { continue }
        // EPERM means alive but someone else's; only ESRCH means gone.
        if kill(pid, 0) == 0 || errno != ESRCH { continue }
        try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
    }
}
