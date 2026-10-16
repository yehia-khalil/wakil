import Foundation
import Testing
@testable import WakilKit

/// A wakil-git that answers from a dictionary and records every call. A root with no
/// status answers the way the real tool does for a non-repo: a successful call with
/// `isError` and the text "not a git repository".
///
/// **`slowShow` parks `git_show` until `release()` or `release(path:)`, and both latch** — the
/// lesson `StallingHTTP` learnt: a release that lands before the call it is meant for
/// has parked would otherwise leave that call parked forever.
actor FakeGit: ToolCaller {
    var status: [String: JSONValue] = [:]       // root -> structuredContent
    var shows: [String: String] = [:]           // "root|path|rev" -> text
    var calls: [String] = []
    var showErrors: [String: String] = [:]      // "root|path|rev" -> isError text
    var absentShows: Set<String> = []           // "root|path|rev" git_show answers `absent` for
    var slowShow = false
    /// `slowStatus` parks every `git_status` under its call number (0, 1, …) until
    /// `releaseStatus(_:)`. The reply is taken when the call arrives, so a parked read
    /// answers with the status as it was then — a stale reply, once released late.
    var slowStatus = false
    private(set) var statusCount = 0
    private var statusParked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var statusReleased: Set<Int> = []
    private var parked: [(path: String, c: CheckedContinuation<Void, Never>)] = []
    private var released = false
    private var releasedPaths: Set<String> = []

    func set(status root: String, files: [(String, String, String)], branch: String = "main") {
        status[root] = .object([
            "root": .string(root), "branch": .string(branch), "detached": .string(""),
            "upstream": .string(""), "ahead": .integer(0), "behind": .integer(0),
            "files": .array(files.map {
                .object(["path": .string($0.0), "group": .string($0.1), "status": .string($0.2)])
            }),
        ])
    }
    func clearStatus(_ root: String) { status[root] = nil }
    func set(show key: String, _ text: String) { shows[key] = text }
    func setSlowShow(_ slow: Bool) { slowShow = slow }
    func setSlowStatus(_ slow: Bool) { slowStatus = slow }
    func set(showError key: String, _ text: String) { showErrors[key] = text }
    func set(showAbsent key: String) { absentShows.insert(key) }
    func releaseStatus(_ call: Int) {
        statusReleased.insert(call)
        statusParked.removeValue(forKey: call)?.resume()
    }
    private func parkStatus(_ call: Int, _ c: CheckedContinuation<Void, Never>) {
        if statusReleased.contains(call) { c.resume() } else { statusParked[call] = c }
    }
    /// `indexedShow` parks every `git_show` under its call number (0, 1, … from the moment it is turned
    /// on) until `releaseShow(_:)`, taking the reply when the call arrives. It lets a test land two shows
    /// of the SAME path in either order.
    private var indexedShow = false
    private var showCount = 0
    private var showParked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var showReleased: Set<Int> = []
    func setIndexedShow(_ on: Bool) { indexedShow = on; showCount = 0; showReleased = [] }
    func releaseShow(_ call: Int) {
        showReleased.insert(call)
        showParked.removeValue(forKey: call)?.resume()
    }
    private func parkShow(_ call: Int, _ c: CheckedContinuation<Void, Never>) {
        if showReleased.contains(call) { c.resume() } else { showParked[call] = c }
    }
    func release() {
        released = true
        parked.forEach { $0.c.resume() }
        parked = []
    }
    /// Releases only `path`'s parked shows (and latches for it), so a test can choose which
    /// reply lands last.
    func release(path: String) {
        releasedPaths.insert(path)
        parked.filter { $0.path == path }.forEach { $0.c.resume() }
        parked.removeAll { $0.path == path }
    }
    private func park(_ path: String, _ c: CheckedContinuation<Void, Never>) {
        if released || releasedPaths.contains(path) { c.resume() } else { parked.append((path, c)) }
    }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let root = optionalString(arguments, "root") ?? ""
        let path = optionalString(arguments, "path") ?? ""
        calls.append("\(name) \(root) \(path)")
        switch name {
        case "git_status":
            let reply: JSONValue = status[root].map { .object(["structuredContent": $0]) }
                ?? .object(["isError": .bool(true), "content": .array([
                    .object(["type": .string("text"), "text": .string("not a git repository")]),
                ])])
            let call = statusCount
            statusCount += 1
            if slowStatus { await withCheckedContinuation { c in Task { self.parkStatus(call, c) } } }
            try Task.checkCancellation()
            return reply
        case "git_show":
            if indexedShow {
                let call = showCount
                showCount += 1
                let key = "\(root)|\(path)|\(optionalString(arguments, "rev") ?? "")"
                let text = shows[key] ?? ""
                await withCheckedContinuation { c in Task { self.parkShow(call, c) } }
                try Task.checkCancellation()
                return .object(["structuredContent": .object([
                    "text": .string(text), "binary": .bool(false),
                    "bytes": .integer(Int64(text.utf8.count)), "truncated": .bool(false),
                ])])
            }
            if slowShow { await withCheckedContinuation { c in Task { self.park(path, c) } } }
            try Task.checkCancellation()
            let key = "\(root)|\(path)|\(optionalString(arguments, "rev") ?? "")"
            if let text = showErrors[key] {
                return .object(["isError": .bool(true), "content": .array([
                    .object(["type": .string("text"), "text": .string(text)]),
                ])])
            }
            return .object(["structuredContent": .object([
                "text": .string(shows[key] ?? ""), "binary": .bool(false),
                "bytes": .integer(Int64((shows[key] ?? "").utf8.count)), "truncated": .bool(false),
                "absent": .bool(absentShows.contains(key)),
            ])])
        default:
            return .object([:])
        }
    }
}
