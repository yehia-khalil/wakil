import Foundation

/// 3a-v-a: a file's history and blame, read through `editor_timeline` and `editor_blame` as the
/// operator (`origin: .ui`), and a commit's change opened through `editor_open_commit_diff`.
extension WindowModel {
    private func historyRead(_ name: String, _ params: [String: JSONValue]) async -> [String: JSONValue]? {
        let reply = try? await registry.dispatch(name: name, params: .object(params), origin: .ui,
                                                 caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        guard case .object(let o)? = reply else { return nil }
        return o
    }

    private func decodedList<T: Decodable>(_ value: JSONValue?) -> [T]? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode([T].self, from: data)
    }

    /// One page of `path`'s commits in `root` (relative path), newest first; nil when git could not read it.
    public func editorTimeline(root: String, path: String, skip: Int) async -> [GitCommitInfo]? {
        guard let o = await historyRead("editor_timeline", ["root": .string(root), "path": .string(path),
                                                             "skip": .integer(Int64(skip))]) else { return nil }
        return decodedList(o["commits"])
    }

    /// Who last changed each line of `path` in `root`; `text` is the tab's unsaved buffer, blamed in
    /// place of the file. Nil when git could not blame it (untracked, binary, past the deadline).
    public func editorBlame(root: String, path: String, text: String?) async -> [GitBlameInfo]? {
        var p: [String: JSONValue] = ["root": .string(root), "path": .string(path)]
        if let text { p["text"] = .string(text) }
        guard let o = await historyRead("editor_blame", p) else { return nil }
        return decodedList(o["lines"])
    }

    /// Opens `commit`'s change to `path` (its name at that commit) in the focused editor pane.
    public func editorOpenCommitDiff(root: String, path: String, commit: String, parentPath: String?) async {
        var p: [String: JSONValue] = ["root": .string(root), "path": .string(path), "commit": .string(commit)]
        if let parentPath { p["parentPath"] = .string(parentPath) }
        _ = await historyRead("editor_open_commit_diff", p)
    }
}
