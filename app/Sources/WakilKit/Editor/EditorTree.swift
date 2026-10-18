import Foundation

/// One root's `files_list` reply (or the error that replaced it).
public struct EditorRootListing: Sendable, Equatable {
    public var root: String
    public var files: [String]
    public var ignored: [String]
    public var heavy: [String]
    public var repos: [String]
    /// Folders holding nothing (3b-iv), relative: a created folder has no file to list it by.
    public var empty: [String]
    public var truncated: Bool
    public var error: String?

    public init(root: String, files: [String], ignored: [String], heavy: [String], repos: [String],
                truncated: Bool, error: String?, empty: [String] = []) {
        self.root = root
        self.files = files
        self.ignored = ignored
        self.heavy = heavy
        self.repos = repos
        self.empty = empty
        self.truncated = truncated
        self.error = error
    }

    /// From `files_list`'s structuredContent.
    public init(root: String, content: [String: JSONValue]) {
        func strings(_ key: String) -> [String] {
            guard case .array(let items)? = content[key] else { return [] }
            return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        self.init(root: root, files: strings("files"), ignored: strings("ignored"), heavy: strings("heavy"),
                  repos: strings("repos"), truncated: content["truncated"] == .bool(true), error: nil,
                  empty: strings("empty"))
    }

    public static func failed(root: String, _ error: String) -> EditorRootListing {
        EditorRootListing(root: root, files: [], ignored: [], heavy: [], repos: [], truncated: false, error: error)
    }
}

public struct EditorDirEntry: Sendable, Equatable {
    public var name: String
    public var isDir: Bool
    public init(name: String, isDir: Bool) {
        self.name = name
        self.isDir = isDir
    }
}

public enum EditorTreeRowKind: String, Sendable, Equatable { case root, repo, folder, file, note }

public struct EditorTreeRow: Sendable, Equatable, Identifiable {
    public var id: String          // absolute path; a note row is "note:<root>"
    public var root: String
    public var relative: String    // "" for a root
    public var name: String
    public var depth: Int
    public var kind: EditorTreeRowKind
    public var dimmed: Bool        // ignored, or a heavy folder
    public var heavy: Bool
    public var open: Bool
    public var loading: Bool
    public var error: String?      // a root's listing error or a heavy folder's, whole (Rule 8)
}

public enum EditorTreeMove: Sendable { case up, down }

private final class TreeNode {
    var children: [String: TreeNode] = [:]
    var isDir = false
    var ignored = false
    var heavy = false
}

private func insert(_ rel: String, into root: TreeNode, dir: Bool = false, ignored: Bool = false, heavy: Bool = false) {
    var node = root
    let parts = rel.split(separator: "/").map(String.init)
    for (i, part) in parts.enumerated() {
        let next = node.children[part] ?? TreeNode()
        node.children[part] = next
        if i < parts.count - 1 { next.isDir = true }
        node = next
    }
    // git names a nested repository "name/" (final review I3): a trailing slash is a folder.
    node.isDir = node.isDir || dir || rel.hasSuffix("/")
    node.ignored = node.ignored || ignored
    node.heavy = node.heavy || heavy
}

/// `showIgnored` false (3b-v part 2) leaves gitignored files out; heavy folders stay, because
/// the tree is how one is opened.
public func editorTreeRows(_ listings: [EditorRootListing], open: Set<String>,
                           dirs: [String: [EditorDirEntry]], loading: Set<String>,
                           dirErrors: [String: String], showIgnored: Bool = true) -> [EditorTreeRow] {
    var rows: [EditorTreeRow] = []
    for l in listings {
        let rootOpen = open.contains(l.root)
        rows.append(EditorTreeRow(id: l.root, root: l.root, relative: "", name: (l.root as NSString).lastPathComponent,
                                  depth: 0, kind: .root, dimmed: false, heavy: false, open: rootOpen,
                                  loading: false, error: l.error))
        guard rootOpen, l.error == nil else { continue }
        if l.truncated {
            rows.append(EditorTreeRow(id: "note:\(l.root)", root: l.root, relative: "", name: "only the first 50,000 files are listed",
                                      depth: 1, kind: .note, dimmed: false, heavy: false, open: false, loading: false, error: nil))
        }
        let trie = TreeNode()
        for f in l.files { insert(f, into: trie) }
        if showIgnored { for f in l.ignored { insert(f, into: trie, ignored: true) } }
        for h in l.heavy { insert(h, into: trie, dir: true, heavy: true) }
        for e in l.empty { insert(e, into: trie, dir: true) }   // a folder node with nothing under it
        for r in l.repos { insert(r, into: trie, dir: true) }   // a node even when it lists nothing
        let repos = Set(l.repos)
        func emit(_ node: TreeNode, prefix: String, depth: Int, dimmed: Bool) {
            let sorted = node.children.sorted { a, b in
                a.value.isDir != b.value.isDir ? a.value.isDir : a.key < b.key
            }
            for (name, child) in sorted {
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let id = "\(l.root)/\(rel)"
                let dim = dimmed || child.ignored || child.heavy
                let isOpen = child.isDir && open.contains(id)
                let kind: EditorTreeRowKind = repos.contains(rel) ? .repo : (child.isDir ? .folder : .file)
                rows.append(EditorTreeRow(id: id, root: l.root, relative: rel, name: name, depth: depth, kind: kind,
                                          dimmed: dim, heavy: child.heavy, open: isOpen,
                                          loading: loading.contains(id), error: dirErrors[id]))
                guard isOpen else { continue }
                if let loaded = dirs[id] {
                    for e in loaded { insert(e.name, into: child, dir: e.isDir) }
                }
                emit(child, prefix: rel, depth: depth + 1, dimmed: dim)
            }
        }
        emit(trie, prefix: "", depth: 1, dimmed: false)
    }
    return rows
}

public func editorTreeSelection(after selected: String?, previous: [EditorTreeRow], now: [EditorTreeRow]) -> String? {
    guard let selected else { return nil }
    if now.contains(where: { $0.id == selected }) { return selected }
    guard let at = previous.firstIndex(where: { $0.id == selected }) else { return now.first?.id }
    // A note row is never selected (Task 8 ruling 6): the fallback passes over it.
    let survivors = Set(now.filter { $0.kind != .note }.map(\.id))
    if let next = previous[(at + 1)...].first(where: { survivors.contains($0.id) }) { return next.id }
    return previous[..<at].last(where: { survivors.contains($0.id) })?.id ?? now.first?.id
}

/// One row up or down, passing over a note row, which is never selected; at either end it stays.
public func editorTreeStep(_ rows: [EditorTreeRow], selected: String?, _ move: EditorTreeMove) -> String? {
    guard let i = selected.flatMap({ s in rows.firstIndex { $0.id == s } }) else {
        return rows.first { $0.kind != .note }?.id
    }
    let next: EditorTreeRow?
    switch move {
    case .up: next = rows[..<i].last { $0.kind != .note }
    case .down: next = rows[(i + 1)...].first { $0.kind != .note }
    }
    return next?.id ?? rows[i].id
}

public func editorTreeTypeAhead(_ rows: [EditorTreeRow], selected: String?, prefix: String) -> String? {
    let p = prefix.lowercased()
    let start = selected.flatMap { s in rows.firstIndex { $0.id == s } }.map { $0 + 1 } ?? 0
    let order = Array(rows[start...]) + Array(rows[..<start])
    return order.first { $0.kind != .note && $0.name.lowercased().hasPrefix(p) }?.id
}

public func editorTreeLeft(_ rows: [EditorTreeRow], selected: String) -> (collapse: String?, select: String?) {
    guard let row = rows.first(where: { $0.id == selected }) else { return (nil, nil) }
    if row.kind == .note { return (nil, row.root) }   // its id is not a path: its row is its root
    if row.open { return (row.id, nil) }
    guard row.kind != .root else { return (nil, nil) }
    let parent = (row.id as NSString).deletingLastPathComponent
    return (nil, parent)
}

public func editorColumnWidth(_ width: Double, paneWidth: Double) -> Double {
    max(160, min(width, paneWidth / 2))
}

public func editorPruneOpen(_ open: [String], listings: [EditorRootListing]) -> [String] {
    open.filter { path in
        for l in listings where path == l.root || path.hasPrefix(l.root + "/") {
            if path == l.root { return true }
            let rel = String(path.dropFirst(l.root.count + 1))
            let all = l.files + l.ignored
            // At or under a heavy folder; a folder holding files; or a folder holding only heavy
            // folders (`web` with just `web/node_modules`), which still exists.
            return l.heavy.contains { rel == $0 || rel.hasPrefix($0 + "/") || $0.hasPrefix(rel + "/") }
                || all.contains { $0.hasPrefix(rel + "/") }
        }
        return false
    }
}

public func editorFolder(of row: EditorTreeRow) -> String {
    row.kind == .file ? (row.id as NSString).deletingLastPathComponent : row.id
}

/// A file operation the tree's keys start (3b-iv): ⌘⌫ moves the selection to the Trash, F2 renames it.
public enum EditorTreeKeyCommand: Sendable, Equatable { case trash, rename }

/// The tree's file-operation key, by the characters the key press carries. The Delete key sends
/// U+007F (DEL), not U+0008: SwiftUI's `KeyEquivalent.delete` is U+0008, so matching it never saw ⌘⌫
/// (3b-iv Cover). Both are taken, as the terminal takes them. F2 has no `KeyEquivalent`: its
/// character is `NSF2FunctionKey` (U+F705). ⌘⌫ is ⌘ alone; F2 takes any modifiers, as before.
public func editorTreeKeyCommand(characters: String, command: Bool, otherChord: Bool) -> EditorTreeKeyCommand? {
    switch characters {
    case "\u{7F}", "\u{8}": return command && !otherChord ? .trash : nil
    case "\u{F705}": return .rename
    default: return nil
    }
}

/// A refusal shown under the tree's name field, its absolute paths written from their root's name
/// (`/var/…/walk/api/src/b.ts` → `api/src/b.ts`): the root is the row above, and a temp root's path
/// would otherwise fill the column. Every path stays whole from the root down (Rule 8).
public func editorTreeShortError(_ message: String, roots: [String]) -> String {
    var out = message
    for root in roots.sorted(by: { $0.count > $1.count }) {
        let name = (root as NSString).lastPathComponent
        out = out.replacingOccurrences(of: root + "/", with: name + "/")
    }
    return out
}
