import Foundation

/// The git pane: per-root status, selection and diff (3a-i). Its contents are its snapshot.
///
/// `failure` stays nil: a refusal to read one root is that root's own `error`, not the pane's.
enum GitPaneKind: PaneKind, PaneRestorable {
    static let names = ["git"]
    static var emptyContents: GitSnapshot { .empty }
    static var emptySnapshot: GitSnapshot? { .empty }
    /// Its subject is a read — `git status` per root.
    static let rerunsSubjectOnRestore = true
    /// **A git pane's subject is the project's roots, not a fetch** (3a-i, R6): re-read by its own
    /// action, or a restored pane would list nothing until the first file changed.
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        PaneRestoreStep(action: "git_refresh", params: .object(["pane": .string(pane.id)]), recordsFailure: false)
    }
    static func snapshot(of contents: GitSnapshot, in store: isolated PaneStore) -> GitSnapshot { contents }
    static func readPane(_ snapshot: GitSnapshot, in store: isolated PaneStore) -> [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        object["roots"] = .array(snapshot.roots.map { root in
            .object([
                "root": .string(root.root),
                "name": .string(root.name),
                "branch": .string(root.branch),
                "detached": .string(root.detached),
                "ahead": .number(Double(root.ahead)),
                "behind": .number(Double(root.behind)),
                "error": root.error.map { .string($0) } ?? .null,
                "loading": .bool(root.loading),
                "files": .array(root.files.map { file in
                    .object([
                        "path": .string(file.path),
                        "origPath": file.origPath.map { .string($0) } ?? .null,
                        "group": .string(file.group.rawValue),
                        "status": .string(file.status),
                    ])
                }),
            ])
        })
        object["selection"] = snapshot.selection.map { sel in
            .object([
                "root": .string(sel.root),
                "path": .string(sel.path),
                "group": .string(sel.group.rawValue),
            ])
        } ?? .null
        object["folded"] = .bool(snapshot.folded)
        object["inView"] = snapshot.inView.map { .string($0) } ?? .null
        // The facts about the diff, not its texts: those are large and are
        // read through `git_show`.
        object["diff"] = snapshot.diff.map { diff in
            .object([
                "binary": .bool(diff.binary),
                "bytes": .number(Double(diff.bytes)),
                "lines": .number(Double(diff.lines)),
                "truncated": .bool(diff.truncated),
                "error": diff.error.map { .string($0) } ?? .null,
                "loading": .bool(diff.loading),
                "language": .string(diff.language),
            ])
        } ?? .null
        return object
    }
}

extension PaneSnapshot {
    public var git: GitSnapshot? { contents as? GitSnapshot }
}

extension GitSnapshot: PaneKindSnapshot {}
