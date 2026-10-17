import Foundation

/// What ⌘W closes in a focused editor pane: its active tab while any is open, else the pane.
public enum EditorCloseTarget: Sendable, Equatable { case tab, pane }

public func editorCloseTarget(tabs: Int) -> EditorCloseTarget { tabs > 0 ? .tab : .pane }

/// The tab focused after closing `index` of `count` (Rule 6: a neighbour, not the first).
public func editorTabAfterClosing(_ index: Int, count: Int) -> Int? {
    let remaining = count - 1
    guard remaining > 0 else { return nil }
    return min(index, remaining - 1)
}

/// Tab titles: the file name, or `parent/name` where two open files share a name; `Untitled-N`.
public func editorTabTitles(_ tabs: [EditorTab]) -> [String] {
    var counts: [String: Int] = [:]
    for tab in tabs { if let p = tab.path { counts[(p as NSString).lastPathComponent, default: 0] += 1 } }
    return tabs.map { tab in
        switch tab.subject {
        case .scratch(let n): return "Untitled-\(n)"
        case .file(let path, _):
            let name = (path as NSString).lastPathComponent
            guard counts[name, default: 0] > 1 else { return name }
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return "\(parent)/\(name)"
        case .diff(_, let path, let group):
            return "\((path as NSString).lastPathComponent) (\(editorDiffGroupTitle(group)))"
        }
    }
}

public func editorNextScratchNumber(_ tabs: [EditorTab]) -> Int {
    var high = 0
    for tab in tabs { if case .scratch(let n) = tab.subject { high = max(high, n) } }
    return high + 1
}

/// Monaco's language id for a path, by extension or well-known name.
public func editorLanguage(forPath path: String) -> String {
    let name = (path as NSString).lastPathComponent.lowercased()
    switch name {
    case "dockerfile": return "dockerfile"
    case "makefile": return "plaintext"
    case ".env", ".env.local", ".env.example": return "ini"
    default: break
    }
    switch (name as NSString).pathExtension {
    case "go": return "go"
    case "swift": return "swift"
    case "php": return "php"
    case "ts", "tsx": return "typescript"
    case "js", "jsx", "mjs", "cjs": return "javascript"
    case "json": return "json"
    case "yml", "yaml": return "yaml"
    case "sql": return "sql"
    case "md": return "markdown"
    case "html", "vue": return "html"
    case "css": return "css"
    case "scss": return "scss"
    case "py": return "python"
    case "sh", "zsh", "bash": return "shell"
    case "xml": return "xml"
    case "ini", "toml", "env": return "ini"
    default: return "plaintext"
    }
}

/// The tabs a layout keeps: files only, with cursor and scroll. Scratch tabs and unsaved text
/// are never persisted (spec, Restore).
public func editorSavedTabs(_ s: EditorSnapshot) -> [EditorSavedTab] {
    s.tabs.compactMap { tab in
        tab.path.map { EditorSavedTab(path: $0, cursor: tab.cursor, scrollTop: tab.scrollTop) }
    }
}

/// Lines `range` (1-based, inclusive) of `text`, joined by "\n". Lines past the end are dropped.
public func editorLines(_ text: String, _ range: ClosedRange<Int>) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let lo = max(range.lowerBound, 1) - 1, hi = min(range.upperBound, lines.count) - 1
    guard lo <= hi else { return "" }
    return lines[lo...hi].joined(separator: "\n")
}

/// The UTF-16 offset of a 1-based position, clamped to the text.
public func editorOffset(_ text: String, _ p: EditorPosition) -> Int {
    let u = Array(text.utf16)
    var line = 1, i = 0
    while line < p.line, i < u.count { if u[i] == 10 { line += 1 }; i += 1 }
    var col = 1
    while col < p.column, i < u.count, u[i] != 10 { i += 1; col += 1 }
    return i
}

/// The text inside `range`.
public func editorText(_ text: String, in range: EditorRange) -> String {
    let u = Array(text.utf16)
    let a = editorOffset(text, range.start), b = editorOffset(text, range.end)
    return String(decoding: u[min(a, b)..<max(a, b)], as: UTF16.self)
}

/// `text` with `range` replaced by `insert`.
public func editorReplacing(_ text: String, _ range: EditorRange, with insert: String) -> String {
    let u = Array(text.utf16)
    let a = editorOffset(text, range.start), b = editorOffset(text, range.end)
    return String(decoding: Array(u[..<min(a, b)]) + Array(insert.utf16) + Array(u[max(a, b)...]), as: UTF16.self)
}

/// What the scratch save-as field's Save came to (`WindowModel.saveScratch`).
public enum EditorSaveAsResult: Sendable, Equatable {
    case saved
    /// The path names a file that exists; nothing was written. The field asks "Replace <name>?".
    case exists(name: String)
    /// The failure text, whole (Rule 8).
    case failed(String)
}

/// `s` with tab `from` moved to `to` (0-based, strip order), the active tab still the same tab
/// (Review Focus 5). nil when either index is outside the strip, or nothing moves.
public func editorMovingTab(_ s: EditorSnapshot, from: Int, to: Int) -> EditorSnapshot? {
    guard s.tabs.indices.contains(from), s.tabs.indices.contains(to), from != to else { return nil }
    var out = s
    let active = s.active.flatMap { s.tabs.indices.contains($0) ? s.tabs[$0].subject : nil }
    out.tabs.insert(out.tabs.remove(at: from), at: to)
    out.active = active.flatMap { a in out.tabs.firstIndex { $0.subject == a } }
    return out
}

/// The index tab `from` moves to when dropped at (`x`, `y`) in the strip, or nil for no move.
/// Over a tab k: k, wherever on it — the usual tab-strip rule, so a drop needs no exact point
/// (ruling 14, pre-flight F4). In a gap or past an end: the slot there (before the first tab right
/// of `x`, else the count), as the index `from` ends at; its own place is nil. nil off the strip.
public func editorTabDropTarget(from: Int, x: Double, y: Double, spans: [ClosedRange<Double>], height: Double) -> Int? {
    guard y >= 0, y < height, spans.indices.contains(from) else { return nil }
    if let k = spans.firstIndex(where: { $0.contains(x) }) { return k == from ? nil : k }
    let slot = spans.firstIndex { $0.lowerBound > x } ?? spans.count
    guard slot != from, slot != from + 1 else { return nil }
    return slot > from ? slot - 1 : slot
}

/// A drag's current target: tab `from` would move to index `to`.
public struct EditorTabDrop: Sendable, Equatable {
    public var from: Int
    public var to: Int
    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// The x the violet drop line draws at: just past the right edge of tab `to` when the dragged tab
/// moves right, just before its left edge when it moves left — the side away from where it came from.
public func editorTabDropX(_ drop: EditorTabDrop, spans: [ClosedRange<Double>]) -> Double {
    guard spans.indices.contains(drop.to) else { return 0 }
    return drop.to > drop.from ? spans[drop.to].upperBound + 1 : spans[drop.to].lowerBound - 1
}

/// The params that name `subject`'s tab to `editor_close` (and every action that takes a tab): path,
/// scratch, or a diff's root, path and group.
public func editorTabParams(_ subject: EditorTabSubject) -> [String: JSONValue] {
    switch subject {
    case .file(let path, _): ["path": .string(path)]
    case .scratch(let n): ["scratch": .integer(Int64(n))]
    case .diff(let root, let path, let group):
        ["diff": .object(["root": .string(root), "path": .string(path), "group": .string(group.rawValue)])]
    }
}

/// `path` is `base` or under it.
private func editorAtOrUnder(_ path: String, _ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }

/// Tabs after `from` became `to` (3b-iv): file tabs at or under it follow, edits and all, keeping
/// their old key for the renderer (ruling R2); diff tabs at or under it close, Changes relists them.
public func editorRepointTabs(_ tabs: [EditorTab], from: String, to: String, root: String) -> [EditorTab] {
    tabs.compactMap { t in
        switch t.subject {
        case .file(let path, _) where editorAtOrUnder(path, from):
            var n = t
            let moved = to + path.dropFirst(from.count)
            n.formerKeys = Array((t.formerKeys + [editorTabKey(t)]).suffix(4))
            n.subject = .file(path: moved, root: root)
            if t.language == editorLanguage(forPath: path) { n.language = editorLanguage(forPath: moved) }
            return n
        case .diff(let r, let p, _) where editorAtOrUnder(r + "/" + p, from):
            return nil
        default:
            return t
        }
    }
}

/// Tabs after `path` went to the Trash (3b-iv): clean file tabs close, dirty ones stay marked
/// deleted (a save recreates the file), diff tabs close.
public func editorTabsAfterTrash(_ tabs: [EditorTab], path: String) -> [EditorTab] {
    tabs.compactMap { t in
        switch t.subject {
        case .file(let p, _) where editorAtOrUnder(p, path):
            guard t.dirty else { return nil }
            var n = t
            n.diskState = .deleted
            return n
        case .diff(let r, let p, _) where editorAtOrUnder(r + "/" + p, path):
            return nil
        default:
            return t
        }
    }
}

/// The active index after `old` became `new`: the same tab if it survived (by subject, or by the
/// key it had before a rename), else the neighbour `editorTabAfterClosing` picks (Rule 6).
public func editorActiveAfter(_ old: [EditorTab], active: Int?, new: [EditorTab]) -> Int? {
    guard !new.isEmpty else { return nil }
    guard let a = active, a < old.count else { return active.map { min($0, new.count - 1) } }
    func survives(_ o: EditorTab, as n: EditorTab) -> Bool {
        let key = editorTabKey(o)
        return editorTabKey(n) == key || (!new.contains { editorTabKey($0) == key } && n.formerKeys.contains(key))
    }
    if let i = new.firstIndex(where: { survives(old[a], as: $0) }) { return i }
    // Survivors before the active one keep their order, so its neighbour sits at the same index.
    let before = old[..<a].filter { o in new.contains { survives(o, as: $0) } }.count
    return min(before, new.count - 1)
}

/// Where a rename typed as `typed` lands: relative to `path`'s folder, standardized, so `sub/x`
/// moves down and `../x` up; a leading "/" is still the folder's (never the disk's root).
public func editorRenameTarget(of path: String, typed: String) -> String {
    let folder = (path as NSString).deletingLastPathComponent
    let rel = typed.drop { $0 == "/" }
    return ((folder as NSString).appendingPathComponent(String(rel)) as NSString).standardizingPath
}

/// Whether the tab now in front of a pane arrived there — opened (⌘T, New File, an open) or picked
/// (⌘P, a tab click) — and so takes the keyboard (Rule 3). A preview tab is browsing: never. A tab
/// that comes forward only because the one in front went (⌘W, Move to Trash, the agent's
/// `editor_trash` or `editor_close`) did not arrive: the keyboard stays where the operator was
/// (Rule 6), in the tree or wherever it is. A tab is the same tab across a rename (its former keys).
public func editorFrontTabArrived(old: EditorSnapshot, now: EditorSnapshot) -> Bool {
    guard let n = now.active, now.tabs.indices.contains(n), !now.tabs[n].preview else { return false }
    let front = now.tabs[n], key = editorTabKey(front)
    guard let o = old.active, old.tabs.indices.contains(o) else { return true }
    let was = editorTabKey(old.tabs[o])
    guard key != was else { return false }
    let frontWent = !now.tabs.contains { editorTabKey($0) == was || $0.formerKeys.contains(was) }
    let wasOpen = old.tabs.contains { editorTabKey($0) == key || front.formerKeys.contains(editorTabKey($0)) }
    return !(frontWent && wasOpen)
}
