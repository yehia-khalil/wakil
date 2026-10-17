import CoreServices
import Foundation

/// Tells the window that something under one of the project's roots changed.
///
/// A protocol so the window can be handed a fake: `WindowModel` starts, restarts and stops
/// one of these as editor panes open and close and the project changes, and a test checks that
/// lifecycle without touching the file system.
public protocol RootWatcher: Sendable {
    /// Watches `roots`, replacing whatever was watched before. Calls `changed(root)` once per
    /// burst of events under that root: `window` after they stop, or at most a second after
    /// the burst's first event when they never do (R12).
    func watch(roots: [String], window: Duration, changed: @escaping @Sendable (String) async -> Void) async
    /// As `watch(roots:window:changed:)`, also handing over the burst's paths that woke it, under
    /// the root as named (final review I4); nil when the watcher cannot say which.
    func watch(roots: [String], window: Duration,
               changedPaths: @escaping @Sendable (String, [String]?) async -> Void) async
    /// Watches nothing. Nothing is called after this returns.
    func stop() async
}

extension RootWatcher {
    /// A watcher that cannot name paths reports none: the caller treats the whole root as changed.
    public func watch(roots: [String], window: Duration,
                      changedPaths: @escaping @Sendable (String, [String]?) async -> Void) async {
        await watch(roots: roots, window: window) { root in await changedPaths(root, nil) }
    }
}

/// Pure: whether an FSEvents path under `root` should wake a refresh.
///
/// `.git/objects/` and `.git/logs/` change on every commit, fetch and gc without changing
/// what `git status` says on their own; a `*.lock` is git mid-write, and the rename that
/// ends it is the event worth waking for. `.git/HEAD`, `.git/index` and `.git/refs/` do
/// wake, so a branch switch or a `git add` made in a terminal reaches the pane.
///
/// **Ignored files still wake, and `git check-ignore` was dropped (ruling R12).** Filtering
/// ignored paths would need a `git check-ignore` spawn per event batch — a process on the
/// hot path of every build or `npm install` writing into `node_modules` — to save a
/// `git status` that costs about the same. The bounded debounce caps what an ignored
/// directory under constant writes costs instead: at most one `git status` a second.
///
/// **`.git/worktrees/` is skipped too** (fix round 1, R8): it holds every linked worktree's
/// own index and HEAD, so a `git add` in a sibling worktree would otherwise wake this one.
public func gitWatchWakes(_ path: String, root: String) -> Bool {
    let relative = relativePath(path, under: root) ?? path
    if relative.hasSuffix(".lock") { return false }
    for ignored in [".git/objects", ".git/logs", ".git/worktrees"] {
        if relative == ignored || relative.hasPrefix(ignored + "/") { return false }
    }
    return true
}

/// `path` relative to `dir`, or nil when it is not under it.
private func relativePath(_ path: String, under dir: String) -> String? {
    let prefix = dir.hasSuffix("/") ? dir : dir + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
}

/// Where one root's git state lives, and which of its events wake (fix round 1, R8).
///
/// **A linked worktree keeps its git state outside itself.** Its `.git` is a file naming a
/// gitdir (`<main>/.git/worktrees/<name>`) holding its own index and HEAD, and the branches
/// it can move live in the common dir's `refs/` and `packed-refs`. Watching only the root
/// missed every `git add`, commit and checkout made in one — the operator's normal case. So
/// the stream for such a root also watches the common dir (which holds the gitdir), and an
/// event there wakes only for what is this worktree's: its gitdir's `index`, `HEAD` and
/// `refs/`, and the common `refs/` and `packed-refs`. The main checkout's index and HEAD,
/// its objects and every sibling's gitdir stay quiet.
///
/// All paths are real paths (`realpath`), because that is how FSEvents reports them.
public struct GitWatchPaths: Sendable, Equatable {
    public let root: String
    /// A linked worktree's own gitdir; nil for a main checkout or a non-repository.
    public let gitDir: String?
    /// That worktree's common dir; nil when `gitDir` is.
    public let commonDir: String?

    public init(root: String, gitDir: String?, commonDir: String?) {
        self.root = root
        self.gitDir = gitDir
        self.commonDir = commonDir
    }

    /// Reads `<root>/.git`: a file means a linked worktree, whose `gitdir:` line (relative to
    /// the root) and `<gitdir>/commondir` (relative to the gitdir) name the other two.
    /// Anything unreadable leaves them nil, and the root is watched as before.
    public static func resolve(root: String) -> GitWatchPaths {
        let real = realPath(root)
        var isDirectory: ObjCBool = false
        let dotGit = real + "/.git"
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return GitWatchPaths(root: real, gitDir: nil, commonDir: nil) }
        let named = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = realPath(named.hasPrefix("/") ? named : real + "/" + named)
        var commonDir: String?
        if let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty { commonDir = realPath(c.hasPrefix("/") ? c : gitDir + "/" + c) }
        }
        return GitWatchPaths(root: real, gitDir: gitDir, commonDir: commonDir)
    }

    /// What the one stream for this root watches. FSEvents takes several paths per stream.
    public var streamPaths: [String] {
        var paths = [root]
        if let commonDir { paths.append(commonDir) } else if let gitDir { paths.append(gitDir) }
        return paths
    }

    /// Whether an event at `path` should wake this root. The gitdir is checked first because
    /// it sits inside the common dir.
    public func wakes(_ path: String) -> Bool {
        if let gitDir, let relative = relativePath(path, under: gitDir) {
            return !relative.hasSuffix(".lock")
                && (relative == "index" || relative == "HEAD" || relative.hasPrefix("refs/"))
        }
        if let commonDir, let relative = relativePath(path, under: commonDir) {
            return !relative.hasSuffix(".lock")
                && (relative == "packed-refs" || relative.hasPrefix("refs/"))
        }
        if gitDir != nil, path == gitDir || path == commonDir { return false }
        return gitWatchWakes(path, root: root)
    }
}

/// One FSEvents stream per root, on a private queue, coalesced per root.
///
/// Each wake that passes `gitWatchWakes` restarts that root's debounce: `changed(root, paths)` runs
/// once the root has been quiet for `window` — **or `maxWait` after the burst's first event,
/// whichever comes first** (R12). Quiet alone would never fire under continuous writes (a
/// build, a log), and the pane would show nothing new until they stopped. A `watch` or
/// `stop` bumps the generation, so a debounce or a delivery from a stream already torn down
/// calls nothing.
public actor FSEventsRootWatcher: RootWatcher {
    private let queue = DispatchQueue(label: "wakil.git-watcher")
    private var streams: [FSEventsStreamBox] = []
    private var debounces: [String: Task<Void, Never>] = [:]
    /// When each root's current burst began; cleared when its refresh fires.
    private var burstStarts: [String: ContinuousClock.Instant] = [:]
    private let maxWait: Duration
    private var generation = 0
    private var window: Duration = .milliseconds(300)
    private var changed: (@Sendable (String, [String]?) async -> Void)?
    /// Each root's current burst's paths that woke it, under the root as named; nil once the burst
    /// passed `burstPathCap` (a build or an install), when the whole root is reported changed.
    private var burstPaths: [String: Set<String>?] = [:]
    /// The most paths one burst names before it reports the whole root.
    static let burstPathCap = 2_000

    public init(maxWait: Duration = .seconds(1)) { self.maxWait = maxWait }

    public func watch(
        roots: [String], window: Duration, changed: @escaping @Sendable (String) async -> Void
    ) async {
        await watch(roots: roots, window: window) { root, _ in await changed(root) }
    }

    public func watch(
        roots: [String], window: Duration, changedPaths: @escaping @Sendable (String, [String]?) async -> Void
    ) async {
        tearDown()
        self.window = window
        self.changed = changedPaths
        let current = generation
        for root in roots {
            // FSEvents reports real paths (`/private/tmp/…` for `/tmp/…`), so a root — and a
            // linked worktree's gitdir and common dir — is matched in its real form.
            // `realpath`, not `resolvingSymlinksInPath`: Foundation's strips `/private` back off
            // (measured — a `/var/folders` root then matched no event and every path woke).
            // Every event maps back to `root`, the name the caller knows it by.
            let paths = GitWatchPaths.resolve(root: root)
            let box = FSEventsStreamBox { [weak self] events in
                let woke = events.filter(paths.wakes)
                guard !woke.isEmpty, let self else { return }
                // Named back under `root`: the caller matches them against its own paths.
                let named = woke.map { p in relativePath(p, under: paths.root).map { root + "/" + $0 } ?? p }
                Task { await self.wake(root, paths: named, generation: current) }
            }
            if box.start(paths: paths.streamPaths, queue: queue) { streams.append(box) }
        }
    }

    public func stop() async {
        tearDown()
    }

    private func tearDown() {
        generation += 1
        // Synchronously on the streams' own queue, so no callback is mid-flight once this
        // returns and the boxes can be released.
        let old = streams
        streams = []
        queue.sync { old.forEach { $0.invalidate() } }
        debounces.values.forEach { $0.cancel() }
        debounces = [:]
        burstStarts = [:]
        burstPaths = [:]
        changed = nil
    }

    private func wake(_ root: String, paths: [String], generation woken: Int) {
        guard woken == generation, changed != nil else { return }
        switch burstPaths[root] {
        case .none:
            burstPaths[root] = Set(paths)
        case .some(.some(var seen)):
            seen.formUnion(paths)
            burstPaths[root] = seen.count > Self.burstPathCap ? .some(nil) : seen
        case .some(.none):
            break   // past the cap: the whole root
        }
        debounces[root]?.cancel()
        let now = ContinuousClock.now
        let start = burstStarts[root] ?? now
        burstStarts[root] = start
        let deadline = min(now + window, start + maxWait)
        debounces[root] = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.fire(root, generation: woken)
        }
    }

    /// The debounce's end: the burst is over, so the next event starts a new one. A debounce
    /// a later wake cancelled after its sleep ended does nothing; that wake's own fires.
    private func fire(_ root: String, generation woken: Int) async {
        guard woken == generation, !Task.isCancelled, let changed else { return }
        burstStarts[root] = nil
        debounces[root] = nil
        let paths = burstPaths.removeValue(forKey: root) ?? nil
        await changed(root, paths.map { $0.sorted() })
    }
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// One FSEvents stream and the closure its C callback calls. Touched only from the actor
/// (start, under `queue.sync` for invalidate) and from the stream's own queue (deliver).
private final class FSEventsStreamBox: @unchecked Sendable {
    private let deliver: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(deliver: @escaping @Sendable ([String]) -> Void) { self.deliver = deliver }

    func start(paths: [String], queue: DispatchQueue) -> Bool {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, fsEventsCallback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    /// Must run on the stream's queue.
    func invalidate() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func receive(_ paths: [String]) {
        guard stream != nil else { return }
        deliver(paths)
    }
}

private let fsEventsCallback: FSEventStreamCallback = { _, info, _, paths, _, _ in
    guard let info else { return }
    let box = Unmanaged<FSEventsStreamBox>.fromOpaque(info).takeUnretainedValue()
    let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
    box.receive(list)
}
