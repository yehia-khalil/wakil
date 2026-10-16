import Foundation

/// What the window's file lists hold now: what every editor pane's tree draws from.
public struct EditorFileListsState: Sendable, Equatable {
    public var listings: [String: EditorRootListing] = [:]
    /// Folders at or under a heavy folder, loaded one at a time (files_list_dir), by absolute path.
    public var dirs: [String: [EditorDirEntry]] = [:]
    public var loading: Set<String> = []
    public var dirErrors: [String: String] = [:]
    public static let empty = EditorFileListsState()
}

/// The window's one list per root (3b-ii), feeding ⌘P's files source and every editor pane's tree.
/// A `ToolCaller`: `files_list` is answered from the list while the roots are watched; everything
/// else passes through. Unwatched (no editor pane open), every `files_list` is read fresh and kept
/// nowhere — nothing would tell it the disk changed. The tree's state still shows the last read, so
/// a column shown before the watcher starts is not empty.
public actor EditorFileLists: ToolCaller {
    private let files: any ToolCaller
    private var watching = false
    /// The roots `watch(roots:)` last named; `setWatching` alone leaves it empty.
    private var watchedRoots: Set<String> = []
    private var kept: [String: JSONValue] = [:]            // root -> files_list's raw result, while watched
    private var inFlight: [String: Task<JSONValue, Error>] = [:]
    /// Bumped by `invalidate`: a read that started under an older generation is never kept.
    private var generation: [String: Int] = [:]
    /// The folder load each key's result must come from: a load lands only while it is still the
    /// key's own (a collapse, a newer load or a root refresh replaces or drops it).
    private var dirLoads: [String: (serial: Int, task: Task<Void, Never>)] = [:]
    private var dirSerial = 0
    private var current = EditorFileListsState() {
        didSet { for c in changeSubscribers.values { c.yield(()) } }
    }
    private var changeSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(files: any ToolCaller) { self.files = files }

    /// Wakes on every change to `state()`: a root listed, a folder loading or loaded (final review
    /// C1). The window mirrors on it, so a root's "listing" tick and a folder's load tick are drawn
    /// while the action that started them still awaits. `bufferingNewest(1)`: a wake-up, not a log.
    public func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let key = UUID()
            changeSubscribers[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(key) }
            }
        }
    }

    private func unsubscribe(_ key: UUID) { changeSubscribers[key] = nil }

    /// A no-op when unchanged: an unwatched list keeps what it last listed until watching stops.
    public func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        guard !on else { return }
        watchedRoots = []
        // Nothing would tell an unwatched list the disk changed: no folder load lands afterwards.
        for key in Array(dirLoads.keys) { dropLoad(key) }
        kept = [:]; current = EditorFileListsState()
    }

    /// Watches exactly `roots` (none: stops watching, as `setWatching(false)`). A root that leaves
    /// the set — a project switch with an editor pane on both sides — loses its kept list and any
    /// read in flight, since nothing tells it the disk changes now (final review I1). A root that
    /// joins it is re-validated as a wake would (`invalidate`): re-read if it was listed, so ⌘P and
    /// the trees never serve a listing from before the switch. Unchanged, it does nothing.
    ///
    /// Returns once the joining roots are re-read; the task finishes when their folder reloads land.
    @discardableResult
    public func watch(roots: [String]) async -> Task<Void, Never> {
        let next = Set(roots)
        guard !next.isEmpty else {
            watchedRoots = []
            setWatching(false)
            return Task {}
        }
        let left = watchedRoots.subtracting(next)
        let joined = watching ? next.subtracting(watchedRoots) : next
        watchedRoots = next
        setWatching(true)
        for root in left {
            generation[root, default: 0] += 1
            kept[root] = nil
            inFlight[root] = nil
        }
        var reloads: [Task<Void, Never>] = []
        for root in joined.sorted() { reloads.append(await invalidate(root: root)) }
        return Task { for r in reloads { await r.value } }
    }

    /// Drops the root's kept list, bumps its generation so a read already in flight is never kept,
    /// and re-reads the root if it was listed or being listed, so the tree catches up with the wake
    /// that called it. Its loaded folders (and those loading) are reloaded when still under a heavy
    /// folder, keeping their entries on screen until the reload lands; the rest are dropped. A load
    /// in flight never lands.
    ///
    /// **Returns once the root is re-read; the folder reloads are started, not awaited**, so a
    /// watcher's next wake is not held behind them. The returned task finishes when they have all
    /// landed, for a caller that redraws then.
    @discardableResult
    public func invalidate(root: String) async -> Task<Void, Never> {
        let wasListed = current.listings[root] != nil || inFlight[root] != nil
        generation[root, default: 0] += 1
        kept[root] = nil
        inFlight[root] = nil
        func under(_ key: String) -> Bool { key == root || key.hasPrefix(root + "/") }
        let folders = Set(current.dirs.keys.filter(under)).union(dirLoads.keys.filter(under))
        for key in folders { dropLoad(key) }
        guard watching, wasListed else {
            for key in folders { current.dirs[key] = nil; current.dirErrors[key] = nil }
            return Task {}
        }
        let l = await listing(root: root)
        var reload: [String] = []
        for key in folders.sorted() {
            let rel = String(key.dropFirst(root.count + 1))
            if l.error == nil, l.heavy.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                reload.append(rel)
            } else {
                current.dirs[key] = nil
                current.dirErrors[key] = nil
            }
        }
        let loads = reload.map { startDir(root: root, dir: $0) }
        return Task { for load in loads { await load.value } }
    }

    /// Forgets the key's load in flight, so it never lands, and its spinner.
    private func dropLoad(_ key: String) {
        dirLoads[key]?.task.cancel()
        dirLoads[key] = nil
        current.loading.remove(key)
    }

    /// files_list for `root`: kept while watched (one read shared by concurrent callers), fresh otherwise.
    /// A read that an `invalidate` overtook answers its caller but is never kept.
    private func rawList(_ root: String) async throws -> JSONValue {
        if watching, let k = kept[root] { return k }
        if watching, let t = inFlight[root] { return try await t.value }
        let gen = generation[root, default: 0]
        let files = files
        let t = Task { try await files.callTool(name: "files_list", arguments: .object(["root": .string(root)]),
                                                timeout: MCPClient.readReplyTimeout) }
        if watching { inFlight[root] = t }
        defer { if generation[root, default: 0] == gen, inFlight[root] == t { inFlight[root] = nil } }
        let value = try await t.value
        if watching, generation[root, default: 0] == gen { kept[root] = value }
        return value
    }

    public func listing(root: String) async -> EditorRootListing {
        let gen = generation[root, default: 0]
        let l: EditorRootListing
        do {
            let raw = try await rawList(root)
            if case .object(let o) = raw, case .bool(true)? = o["isError"] {
                l = .failed(root: root, mcpErrorText(from: o) ?? "files_list failed for \(root)")
            } else if case .object(let o) = raw, case .object(let content)? = o["structuredContent"] {
                l = EditorRootListing(root: root, content: content)
            } else {
                l = .failed(root: root, "files_list answered with no structuredContent")
            }
        } catch {
            l = .failed(root: root, String(describing: error))
        }
        if generation[root, default: 0] == gen { current.listings[root] = l }
        return l
    }

    /// Loads one folder at or under a heavy folder (files_list_dir), keyed by its absolute path.
    public func loadDir(root: String, dir: String) async {
        await startDir(root: root, dir: dir).value
    }

    /// Starts `loadDir`'s load and returns it, its spinner and serial already recorded.
    private func startDir(root: String, dir: String) -> Task<Void, Never> {
        let key = "\(root)/\(dir)"
        dirLoads[key]?.task.cancel()
        dirSerial += 1
        let serial = dirSerial
        current.loading.insert(key)
        current.dirErrors[key] = nil
        let files = files
        let task = Task { [weak self] in
            let result: Result<JSONValue, Error>
            do {
                result = .success(try await files.callTool(name: "files_list_dir", arguments: .object([
                    "root": .string(root), "dir": .string(dir)]), timeout: MCPClient.readReplyTimeout))
            } catch { result = .failure(error) }
            await self?.finishDir(key, serial: serial, result)
        }
        dirLoads[key] = (serial, task)
        return task
    }

    private func finishDir(_ key: String, serial: Int, _ result: Result<JSONValue, Error>) {
        // Checked on the actor, not before the hop: a collapse or refresh in between is seen.
        guard dirLoads[key]?.serial == serial else { return }
        current.loading.remove(key)
        dirLoads[key] = nil
        let o: [String: JSONValue]
        switch result {
        case .failure(let error):
            current.dirs[key] = nil
            current.dirErrors[key] = String(describing: error)   // whole, for its row (Rule 8)
            return
        case .success(.object(let obj)): o = obj
        case .success:
            current.dirs[key] = nil
            current.dirErrors[key] = "files_list_dir answered with no object for \(key)"
            return
        }
        if case .bool(true)? = o["isError"] {
            current.dirs[key] = nil
            current.dirErrors[key] = mcpErrorText(from: o) ?? "files_list_dir failed"
            return
        }
        guard case .object(let c)? = o["structuredContent"], case .array(let entries)? = c["entries"] else { return }
        current.dirs[key] = entries.compactMap { e in
            guard case .object(let x) = e, case .string(let name)? = x["name"] else { return nil }
            return EditorDirEntry(name: name, isDir: x["kind"] == .string("dir"))
        }
    }

    public func cancelDir(_ path: String) { dropLoad(path) }

    public func state() -> EditorFileListsState { current }

    public func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard name == "files_list", let root = optionalString(arguments, "root") else {
            return try await files.callTool(name: name, arguments: arguments, timeout: timeout)
        }
        return try await rawList(root)
    }
}
