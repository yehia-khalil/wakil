import Foundation
import Testing
@testable import WakilKit

/// A wakil-files over an in-memory disk. Records calls; `slowWrite` parks `files_write` until
/// `releaseWrite()`, latched (FakeGit's lesson).
actor FakeFiles: ToolCaller {
    var disk: [String: (text: String, mtime: Int64)] = [:]
    var listing: [String: [String]] = [:]
    var calls: [String] = []
    var overCap: [String: Int] = [:]
    var writeError: String?
    var listErrors: [String: String] = [:]
    var slowWrite = false
    var slowRead = false
    private var readReleased = false
    private var parkedReads: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var clock: Int64 = 100

    func put(_ path: String, _ text: String) { clock += 1; disk[path] = (text, clock); overCap[path] = nil; tails[path] = nil }
    /// A large file's tail (3b-vii): `files_read` answers it as Go does over the cap.
    var tails: [String: (text: String, start: Int, size: Int)] = [:]
    func putTail(_ path: String, text: String, start: Int, size: Int) { clock += 1; tails[path] = (text, start, size); disk[path] = nil }
    func remove(_ path: String) { disk[path] = nil }
    func setListing(_ root: String, _ files: [String]) { listing[root] = files }
    func setListError(_ root: String, _ text: String) { listErrors[root] = text }
    var truncatedRoots: Set<String> = []
    func setTruncated(_ root: String) { truncatedRoots.insert(root) }
    var ignoredListing: [String: [String]] = [:]
    var heavyListing: [String: [String]] = [:]
    func setIgnored(_ root: String, _ paths: [String]) { ignoredListing[root] = paths }
    func setHeavy(_ root: String, _ paths: [String]) { heavyListing[root] = paths }
    /// `files_list_dir`'s entries, keyed `"<root>/<dir>"`: (name, isDir).
    var dirListing: [String: [(String, Bool)]] = [:]
    func setDir(_ key: String, _ entries: [(String, Bool)]) { dirListing[key] = entries }
    /// Parks `files_list_dir` AFTER it has read its entries, until `releaseDir()`, latched.
    var slowDir = false
    private var dirReleased = false
    private var parkedDirs: [CheckedContinuation<Void, Never>] = []
    func setSlowDir(_ on: Bool) { slowDir = on; dirReleased = false }
    func releaseDir() { dirReleased = true; parkedDirs.forEach { $0.resume() }; parkedDirs = [] }
    private func parkDir(_ c: CheckedContinuation<Void, Never>) {
        if dirReleased { c.resume() } else { parkedDirs.append(c) }
    }
    /// Parks `files_list` AFTER the reply is computed, so a parked read answers what the disk held
    /// when it started.
    var slowList = false
    private var listReleased = false
    private var parkedLists: [CheckedContinuation<Void, Never>] = []
    func setSlowList(_ on: Bool) { slowList = on; listReleased = false }
    func releaseList() { listReleased = true; parkedLists.forEach { $0.resume() }; parkedLists = [] }
    private func parkList(_ c: CheckedContinuation<Void, Never>) {
        if listReleased { c.resume() } else { parkedLists.append(c) }
    }
    func putOverCap(_ path: String, size: Int) {
        overCap[path] = size
    }
    func text(of path: String) -> String? { disk[path]?.text }
    func mtime(of path: String) -> Int64? { disk[path]?.mtime }
    /// Parks `files_read` AFTER it has read the disk, so the caller gets what the disk held then.
    func setSlowRead(_ on: Bool) { slowRead = on; readReleased = false }
    func releaseRead() { readReleased = true; parkedReads.forEach { $0.resume() }; parkedReads = [] }
    private func parkRead(_ c: CheckedContinuation<Void, Never>) {
        if readReleased { c.resume() } else { parkedReads.append(c) }
    }
    /// `files_search`'s answer: (root, path, line, column, preview) per match, or `searchError` whole.
    var searchMatches: [(String, String, Int, Int, String)] = []
    var searchError: String?
    var searchFilesTruncated = false
    /// Parks `files_search` until `releaseSearch()`, latched. A parked search cancelled while it
    /// waited records "files_search cancelled" and throws `CancellationError` once released; one
    /// that was not records "files_search returned".
    var slowSearch = false
    private var searchReleased = false
    private var parkedSearches: [CheckedContinuation<Void, Never>] = []
    func setSearch(_ m: [(String, String, Int, Int, String)]) { searchMatches = m; searchError = nil }
    func setSearchError(_ e: String?) { searchError = e }
    func setSearchFilesTruncated(_ on: Bool) { searchFilesTruncated = on }
    func setSlowSearch(_ on: Bool) { slowSearch = on; searchReleased = false }
    func releaseSearch() { searchReleased = true; parkedSearches.forEach { $0.resume() }; parkedSearches = [] }
    private func parkSearch(_ c: CheckedContinuation<Void, Never>) {
        if searchReleased { c.resume() } else { parkedSearches.append(c) }
    }
    /// `files_replace`: a write that fails for a path, with its text.
    var replaceFailures: [String: String] = [:]
    /// Both replace tools answer this as `isError`, as Go answers an invalid regex.
    var replaceError: String?
    /// Files one `files_replace` call writes before it answers `next` (Go's `max_files` and 250 ms).
    var replaceBatch = 50
    /// Parks `files_replace` AFTER it has written, until `releaseReplace()`, latched. A call cancelled
    /// while parked throws `CancellationError`, dropping its reply as the MCP client would.
    var slowReplace = false
    private var replaceReleased = false
    private var parkedReplaces: [CheckedContinuation<Void, Never>] = []
    /// Parks `files_replace_text` before it answers, until `releaseReplaceText()`, latched.
    var slowReplaceText = false
    private var replaceTextReleased = false
    private var parkedReplaceTexts: [CheckedContinuation<Void, Never>] = []
    /// The active project's roots as Go resolves them on every call (final review C1): nil leaves
    /// every call unconfined. When set, `files_replace` refuses a `roots` entry outside them, as Go
    /// does, and with no `roots` it walks these — the next project's, after a switch.
    var activeRoots: [String]?
    func setActiveRoots(_ r: [String]?) { activeRoots = r }
    /// Parks the fixture's `roots` closure (recording "roots parked") until `releaseRoots()`, latched:
    /// holds a replace between its claim and its first batch.
    var slowRoots = false
    private var rootsReleased = false
    private var parkedRoots: [CheckedContinuation<Void, Never>] = []
    func setSlowRoots(_ on: Bool) { slowRoots = on; rootsReleased = false }
    func releaseRoots() { rootsReleased = true; parkedRoots.forEach { $0.resume() }; parkedRoots = [] }
    private func parkRoots(_ c: CheckedContinuation<Void, Never>) {
        if rootsReleased { c.resume() } else { parkedRoots.append(c) }
    }
    /// What the fixture's `roots` closure answers: `activeRoots`, after the park when one is set.
    func fixtureRoots() async -> [String]? {
        if slowRoots {
            calls.append("roots parked")
            await withCheckedContinuation { c in Task { self.parkRoots(c) } }
        }
        return activeRoots
    }
    /// `files_replace`'s `truncated_files`: a root had more than 50,000 files.
    var replaceFilesTruncated = false
    func setReplaceFilesTruncated(_ on: Bool) { replaceFilesTruncated = on }
    func setReplaceFailure(_ path: String, _ text: String) { replaceFailures[path] = text }
    func setReplaceError(_ e: String?) { replaceError = e }
    func setReplaceBatch(_ n: Int) { replaceBatch = n }
    func setSlowReplace(_ on: Bool) { slowReplace = on; replaceReleased = false }
    func releaseReplace() { replaceReleased = true; parkedReplaces.forEach { $0.resume() }; parkedReplaces = [] }
    private func parkReplace(_ c: CheckedContinuation<Void, Never>) {
        if replaceReleased { c.resume() } else { parkedReplaces.append(c) }
    }
    /// Runs before each `files_replace_text` answers — a test types into a buffer here.
    var onReplaceText: (@Sendable () async -> Void)?
    func setOnReplaceText(_ h: (@Sendable () async -> Void)?) { onReplaceText = h }
    func setSlowReplaceText(_ on: Bool) { slowReplaceText = on; replaceTextReleased = false }
    func releaseReplaceText() { replaceTextReleased = true; parkedReplaceTexts.forEach { $0.resume() }; parkedReplaceTexts = [] }
    private func parkReplaceText(_ c: CheckedContinuation<Void, Never>) {
        if replaceTextReleased { c.resume() } else { parkedReplaceTexts.append(c) }
    }
    private func strings(_ arguments: JSONValue, _ key: String) -> [String] {
        guard case .object(let o) = arguments, case .array(let items)? = o[key] else { return [] }
        return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }
    /// `files_list_dir` throws this text (keyed `"<root>/<dir>"`), as a dropped connection would.
    var dirThrows: [String: String] = [:]
    func setDirThrows(_ key: String, _ text: String) { dirThrows[key] = text }
    func setSlowWrite(_ on: Bool) { slowWrite = on }
    func setWriteError(_ e: String?) { writeError = e }
    /// Folders `files_create` made (the disk holds files only); `files_move` answers `moveError` whole.
    var madeDirs: Set<String> = []
    var moveError: String?
    func setMoveError(_ e: String?) { moveError = e }
    func releaseWrite() { released = true; parked.forEach { $0.resume() }; parked = [] }
    private func park(_ c: CheckedContinuation<Void, Never>) { if released { c.resume() } else { parked.append(c) } }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        if name == "files_replace_text", slowReplaceText {
            calls.append("files_replace_text parked")
            await withCheckedContinuation { c in Task { self.parkReplaceText(c) } }
        }
        if name == "files_replace_text", let onReplaceText { await onReplaceText() }
        let result = try await perform(name: name, arguments: arguments)
        if name == "files_read", slowRead { await withCheckedContinuation { c in Task { self.parkRead(c) } } }
        if name == "files_list", slowList { await withCheckedContinuation { c in Task { self.parkList(c) } } }
        if name == "files_list_dir", slowDir { await withCheckedContinuation { c in Task { self.parkDir(c) } } }
        if name == "files_search", slowSearch {
            await withCheckedContinuation { c in Task { self.parkSearch(c) } }
            if Task.isCancelled { calls.append("files_search cancelled"); throw CancellationError() }
            calls.append("files_search returned")
        }
        if name == "files_replace", slowReplace {
            await withCheckedContinuation { c in Task { self.parkReplace(c) } }
            // As the MCP client does: a call cancelled while in flight has its reply dropped, though
            // its files were written.
            if Task.isCancelled { calls.append("files_replace reply dropped"); throw CancellationError() }
        }
        return result
    }

    private func perform(name: String, arguments: JSONValue) async throws -> JSONValue {
        let path = optionalString(arguments, "path") ?? optionalString(arguments, "root") ?? ""
        calls.append("\(name) \(path)")
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        switch name {
        case "files_read":
            if let tl = tails[path] {
                return ok(["path": .string(path), "exists": .bool(true), "text": .string(tl.text), "utf8": .bool(true),
                           "binary": .bool(false), "over_cap": .bool(true), "tail": .bool(true),
                           "start": .integer(Int64(tl.start)), "end": .integer(Int64(tl.size)),
                           "size": .integer(Int64(tl.size)), "mtime": .integer(clock)])
            }
            if case .object(let a) = arguments, let from = a["from"]?.intValue {
                calls[calls.count - 1] += " from \(from)"
                guard let f = disk[path] else { return ok(["path": .string(path), "exists": .bool(false), "text": .string(""),
                                                          "utf8": .bool(true), "size": .integer(0), "mtime": .integer(0)]) }
                let bytes = Array(f.text.utf8)
                func flag(_ key: String) -> JSONValue {
                    ok(["exists": .bool(true), key: .bool(true), "text": .string(""), "utf8": .bool(true),
                        "size": .integer(Int64(bytes.count)), "mtime": .integer(f.mtime)])
                }
                if bytes.count < from { return flag("shrunk") }
                if bytes.count - from > 2 << 20 { return flag("too_far") }
                var chunk = Array(bytes[from...])
                chunk = Array(chunk[..<((chunk.lastIndex(of: 0x0A) ?? -1) + 1)])
                let binary = chunk.contains(0)
                return ok(["exists": .bool(true), "text": .string(binary ? "" : String(decoding: chunk, as: UTF8.self)),
                           "utf8": .bool(true), "binary": .bool(binary), "start": .integer(Int64(from)),
                           "end": .integer(Int64(from + chunk.count)), "size": .integer(Int64(bytes.count)),
                           "mtime": .integer(f.mtime)])
            }
            if let size = overCap[path] {
                return ok(["path": .string(path), "exists": .bool(true), "text": .string(""), "utf8": .bool(true),
                           "binary": .bool(false), "over_cap": .bool(true), "size": .integer(Int64(size)), "mtime": .integer(1)])
            }
            guard let f = disk[path] else { return ok(["path": .string(path), "exists": .bool(false), "text": .string(""),
                                                      "utf8": .bool(true), "binary": .bool(false), "over_cap": .bool(false),
                                                      "size": .integer(0), "mtime": .integer(0)]) }
            return ok(["path": .string(path), "exists": .bool(true), "text": .string(f.text), "utf8": .bool(true),
                       "binary": .bool(false), "over_cap": .bool(false), "size": .integer(Int64(f.text.utf8.count)),
                       "mtime": .integer(f.mtime)])
        case "files_write":
            if slowWrite { await withCheckedContinuation { c in Task { self.park(c) } } }
            try Task.checkCancellation()
            if let writeError {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(writeError)])])])
            }
            if case .object(let a) = arguments, case .bool(false)? = a["create"], disk[path] == nil {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("\(path) does not exist")])])])
            }
            put(path, optionalString(arguments, "text") ?? "")
            return ok(["path": .string(path), "size": .integer(Int64(disk[path]!.text.utf8.count)), "mtime": .integer(disk[path]!.mtime)])
        case "files_create":
            let kind = optionalString(arguments, "kind") ?? "file"
            if disk[path] != nil || madeDirs.contains(path) {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("\(path) already exists")])])])
            }
            if kind == "dir" { madeDirs.insert(path) } else { put(path, "") }
            return ok(["path": .string(path), "root": .string(""), "kind": .string(kind)])
        case "files_move":
            let from = optionalString(arguments, "from") ?? "", to = optionalString(arguments, "to") ?? ""
            calls.append("files_move \(from) -> \(to)")
            if let moveError { return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(moveError)])])]) }
            for (k, v) in disk where k == from || k.hasPrefix(from + "/") { disk[k] = nil; disk[to + k.dropFirst(from.count)] = v }
            return ok(["from": .string(from), "to": .string(to), "kind": .string(disk[to] == nil ? "dir" : "file")])
        case "files_trash":
            for k in disk.keys where k == path || k.hasPrefix(path + "/") { disk[k] = nil }
            return ok(["path": .string(path), "root": .string(""), "kind": .string("file")])
        case "files_list":
            if let text = listErrors[path] {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
            }
            return ok(["root": .string(path), "files": .array((listing[path] ?? []).map { .string($0) }),
                       "ignored": .array((ignoredListing[path] ?? []).map { .string($0) }),
                       "heavy": .array((heavyListing[path] ?? []).map { .string($0) }),
                       "repos": .array([]), "truncated": .bool(truncatedRoots.contains(path))])
        case "files_list_dir":
            let dir = optionalString(arguments, "dir") ?? ""
            if let text = dirThrows["\(path)/\(dir)"] { throw FakeFilesError(description: text) }
            let entries = (dirListing["\(path)/\(dir)"] ?? []).map { name, isDir in
                JSONValue.object(["name": .string(name), "kind": .string(isDir ? "dir" : "file")])
            }
            return ok(["root": .string(path), "dir": .string(dir), "entries": .array(entries)])
        case "files_search":
            if let searchError {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(searchError)])])])
            }
            return ok(["matches": .array(searchMatches.map { m in .object([
                "root": .string(m.0), "path": .string(m.1), "line": .integer(Int64(m.2)),
                "column": .integer(Int64(m.3)), "preview": .string(m.4)]) }),
                "truncated": .bool(false), "files_truncated": .bool(searchFilesTruncated)])
        case "files_replace_text":
            if let replaceError { return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(replaceError)])])]) }
            let query = optionalString(arguments, "query") ?? "", with = optionalString(arguments, "replacement") ?? ""
            return ok(["results": .array(strings(arguments, "texts").map { t in
                let ns = t as NSString
                var edits: [JSONValue] = []
                var at = 0
                while !query.isEmpty, at < ns.length {
                    let r = ns.range(of: query, options: [], range: NSRange(location: at, length: ns.length - at))
                    if r.location == NSNotFound { break }
                    edits.append(.object(["start": .integer(Int64(r.location)), "end": .integer(Int64(r.location + r.length)), "text": .string(with)]))
                    at = r.location + r.length
                }
                let text = query.isEmpty ? t : t.replacingOccurrences(of: query, with: with)
                return .object(["text": .string(text), "count": .integer(Int64(edits.count)), "edits": .array(edits)])
            })])
        case "files_replace":
            if let replaceError { return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(replaceError)])])]) }
            let query = optionalString(arguments, "query") ?? "", with = optionalString(arguments, "replacement") ?? ""
            let only = optionalString(arguments, "only"), after = optionalString(arguments, "after") ?? ""
            let skip = strings(arguments, "skip")
            let given = strings(arguments, "roots")
            if let activeRoots, let outside = given.first(where: { !activeRoots.contains($0) }) {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(
                    "\(outside) is outside the active project's roots; editor writes and reads are confined to them")])])])
            }
            let walked = given.isEmpty ? activeRoots : given
            func covered(_ p: String) -> Bool { walked?.contains { p.hasPrefix($0 + "/") } ?? true }
            var files: [JSONValue] = [], failures: [JSONValue] = [], skipped: [JSONValue] = []
            var written = 0, last = "", stopped = false
            for path in disk.keys.sorted() where path > after && (only == nil || path == only) && covered(path) {
                if written >= replaceBatch { stopped = true; break }
                last = path
                if skip.contains(path) { skipped.append(.string(path)); continue }
                let old = disk[path]!.text
                let count = query.isEmpty ? 0 : old.components(separatedBy: query).count - 1
                guard count > 0 else { continue }
                if let f = replaceFailures[path] { failures.append(.object(["path": .string(path), "error": .string(f)])); continue }
                put(path, old.replacingOccurrences(of: query, with: with))
                files.append(.object(["path": .string(path), "count": .integer(Int64(count)), "original": .string(old),
                                      "mtime": .integer(disk[path]!.mtime)]))
                written += 1
            }
            return ok(["files": .array(files), "failures": .array(failures), "skipped": .array(skipped),
                       "truncated_files": .bool(replaceFilesTruncated), "cancelled": .bool(false), "next": .string(stopped ? last : "")])
        default:
            throw StandardActionError.missingClient(action: name, role: "files")
        }
    }
}

struct FakeFilesError: Error, CustomStringConvertible { let description: String }

struct EditorFixture {
    let registry: ActionRegistry
    let panes: PaneStore
    let layout: LayoutStore
    let files: FakeFiles
    var pane: String
    let git: FakeGit
    let status: GitStatus

    @discardableResult
    func dispatch(_ name: String, _ params: [String: JSONValue] = [:], origin: ActionOrigin = .agent,
                  environment: String = "staging") async throws -> JSONValue {
        var p = params
        if p["pane"] == nil { p["pane"] = .string(pane) }
        return try await registry.dispatch(name: name, params: .object(p), origin: origin,
                                           caller: .test(environment), confirmation: nil)
    }
    func snapshot() async -> EditorSnapshot { await panes.editorSnapshot(paneId: pane) }

    /// Waits until `path`'s tab holds `baseline`. A baseline lands after the action that opened the
    /// tab has returned (final review 2), so a test reads it only once it is there. Callers carry
    /// `.timeLimit`.
    func baselineLands(_ path: String, _ baseline: String?) async {
        // Ends on the suite's time limit too, as a failure: `try?` alone swallowed the cancellation
        // and a baseline that never landed spun forever.
        while await snapshot().tabs.first(where: { $0.path == path })?.baseline != baseline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await snapshot().tabs.first(where: { $0.path == path })?.baseline == baseline)
    }
}

func editorFixture(roots: [String] = ["/p/api", "/p/web"]) async throws -> EditorFixture {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    let panes = PaneStore(kinds: PaneKinds.standard)
    let files = FakeFiles()
    let git = FakeGit()
    let status = GitStatus(git: git, roots: { await files.fixtureRoots() ?? roots })
    await registerEditorActions(into: registry, panes: panes, layout: layout, files: files, fileLists: nil,
                                gitStatus: status, roots: { await files.fixtureRoots() ?? roots })
    return EditorFixture(registry: registry, panes: panes, layout: layout, files: files, pane: pane,
                         git: git, status: status)
}

func range(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int) -> JSONValue {
    .object(["start": .object(["line": .integer(Int64(l1)), "column": .integer(Int64(c1))]),
             "end": .object(["line": .integer(Int64(l2)), "column": .integer(Int64(c2))])])
}

// Tests type by position for brevity. The subject is read in the same actor turn (or on the main
// actor, for the window) as the write, so no hop separates the two; production code never has a
// position to pass — the view addresses tabs by subject (final review I1).
extension PaneStore {
    func editorBufferDidChange(paneId: String, tab: Int, text: String, basis: Int) {
        let tabs = editorSnapshot(paneId: paneId).tabs
        guard tab >= 0, tab < tabs.count else { return }
        editorBufferDidChange(paneId: paneId, subject: tabs[tab].subject, text: text, basis: basis)
    }

    func editorViewDidReport(paneId: String, tab: Int, cursor: EditorPosition, selection: EditorRange?,
                             visibleRange: ClosedRange<Int>?, scrollTop: Double) {
        let tabs = editorSnapshot(paneId: paneId).tabs
        guard tab >= 0, tab < tabs.count else { return }
        editorViewDidReport(paneId: paneId, subject: tabs[tab].subject, cursor: cursor, selection: selection,
                            visibleRange: visibleRange, scrollTop: scrollTop)
    }
}

extension WindowModel {
    func editorBufferDidChange(pane: String, tab: Int, text: String, basis: Int) async {
        guard let tabs = editor(pane)?.tabs, tab >= 0, tab < tabs.count else { return }
        await editorBufferDidChange(pane: pane, subject: tabs[tab].subject, text: text, basis: basis)
    }

    func editorViewDidReport(pane: String, tab: Int, cursor: EditorPosition, selection: EditorRange?,
                             visibleRange: ClosedRange<Int>?, scrollTop: Double) async {
        guard let tabs = editor(pane)?.tabs, tab >= 0, tab < tabs.count else { return }
        await editorViewDidReport(pane: pane, subject: tabs[tab].subject, cursor: cursor, selection: selection,
                                  visibleRange: visibleRange, scrollTop: scrollTop)
    }
}
