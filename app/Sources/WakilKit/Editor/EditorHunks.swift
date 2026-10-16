import Foundation

// The gutter's change marks, the peek and Revert (3b-iii), pure. A file tab's text is compared with
// its baseline — the file's index text (`git_show` rev index) — line by line with Swift's
// `CollectionDifference`. Nothing is diffed in JavaScript and no Go tool is involved.

/// A text's lines as hunks compare them: split at "\n", without the empty line after a final newline,
/// so a missing final newline is no change (R9). "" has no lines.
public func editorHunkLines(_ t: String) -> [String] {
    if t.isEmpty { return [] }
    var lines = editorRawLines(t)
    if t.unicodeScalars.last == "\n" { lines.removeLast() }
    return lines
}

/// `t` split at every "\n", the empty line after a final newline included. Split on scalars, not
/// Characters: Swift reads "\r\n" as one Character, so a Character split would never see a CRLF break.
private func editorRawLines(_ t: String) -> [String] {
    t.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
}

/// One change between a baseline and a text: lines added, changed (old and new), or deleted.
public struct EditorHunk: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case added, changed, deleted }
    public var kind: Kind
    /// The first new line, 1-based. For `deleted`, the line the removed lines sat before — one past
    /// the text's last line when they were at the end.
    public var newStart: Int
    /// How many new lines; 0 for `deleted`.
    public var newCount: Int
    /// The baseline's lines the hunk replaced; empty for `added`. All Revert needs.
    public var oldLines: [String]

    public init(kind: Kind, newStart: Int, newCount: Int, oldLines: [String]) {
        self.kind = kind
        self.newStart = newStart
        self.newCount = newCount
        self.oldLines = oldLines
    }
}

/// The most lines either side of a comparison may have. `CollectionDifference` costs about O(N·D),
/// and measured with every line differing 10,000 lines take about 1.3 s (40,000 would take ~20 s), so
/// a longer file gets no marks and no peek rather than a stalled editor.
public let editorHunksLineCap = 10_000

/// `text`'s hunks against `base`, in line order. Adjacent removals and insertions are one hunk.
/// Empty when either side is over `editorHunksLineCap` lines.
public func editorHunks(base: String, text: String) -> [EditorHunk] {
    let old = editorHunkLines(base), new = editorHunkLines(text)
    guard old.count <= editorHunksLineCap, new.count <= editorHunksLineCap else { return [] }
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in new.difference(from: old) {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }
    var hunks: [EditorHunk] = []
    var i = 0, j = 0
    while i < old.count || j < new.count {
        guard removed.contains(i) || inserted.contains(j) else {
            i += 1
            j += 1
            continue
        }
        let start = j
        var gone: [String] = []
        while removed.contains(i) || inserted.contains(j) {
            while removed.contains(i) { gone.append(old[i]); i += 1 }
            while inserted.contains(j) { j += 1 }
        }
        let count = j - start
        let kind: EditorHunk.Kind = gone.isEmpty ? .added : (count == 0 ? .deleted : .changed)
        hunks.append(EditorHunk(kind: kind, newStart: start + 1, newCount: count, oldLines: gone))
    }
    return hunks
}

/// One gutter mark: a bar beside lines `start`…`end`, or a deletion's triangle on one line — below
/// it, or above line 1 when the deleted lines were at the very start.
public struct EditorGutterMark: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case added, changed, deletedBelow, deletedAbove }
    public var kind: Kind
    public var start: Int
    public var end: Int
    public init(kind: Kind, start: Int, end: Int) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

/// The marks the gutter draws, one per hunk, in hunk order (so a mark's index is its hunk's).
public func editorGutterMarks(_ hunks: [EditorHunk]) -> [EditorGutterMark] {
    hunks.map { h in
        switch h.kind {
        case .added: EditorGutterMark(kind: .added, start: h.newStart, end: h.newStart + h.newCount - 1)
        case .changed: EditorGutterMark(kind: .changed, start: h.newStart, end: h.newStart + h.newCount - 1)
        case .deleted:
            h.newStart > 1 ? EditorGutterMark(kind: .deletedBelow, start: h.newStart - 1, end: h.newStart - 1)
                           : EditorGutterMark(kind: .deletedAbove, start: 1, end: 1)
        }
    }
}

/// The hunk whose mark is on `line`, or nil.
public func editorHunkIndex(at line: Int, in hunks: [EditorHunk]) -> Int? {
    editorGutterMarks(hunks).firstIndex { $0.start <= line && line <= $0.end }
}

/// The buffer edit that puts `hunk` back to its baseline lines, against `text` as it is (Revert):
/// a range and what replaces it, for `editor_replace_range`. Positions are 1-based, UTF-16 columns,
/// over `text`'s raw lines (the line after a final newline included).
public func editorRevertEdit(_ hunk: EditorHunk, text: String) -> (range: EditorRange, text: String) {
    let raw = editorRawLines(text)
    func head(_ line: Int) -> EditorPosition { EditorPosition(line: line, column: 1) }
    func tail(_ line: Int) -> EditorPosition { EditorPosition(line: line, column: raw[line - 1].utf16.count + 1) }
    let s = hunk.newStart, e = hunk.newStart + hunk.newCount - 1
    let old = hunk.oldLines.joined(separator: "\n")
    switch hunk.kind {
    case .changed:
        return (EditorRange(start: head(s), end: tail(e)), old)
    case .added:
        if e < raw.count { return (EditorRange(start: head(s), end: head(e + 1)), "") }      // with the newline after
        if s > 1 { return (EditorRange(start: tail(s - 1), end: tail(e)), "") }            // the newline before
        return (EditorRange(start: head(1), end: tail(e)), "")
    case .deleted:
        if s <= raw.count { return (EditorRange(start: head(s), end: head(s)), old + "\n") }
        let last = raw.count
        return (EditorRange(start: tail(last), end: tail(last)), "\n" + old)              // after a last line with no newline
    }
}

/// What the peek draws for a tab: its hunk's old lines over its new ones, under line `afterLine`
/// (0: above the first line), and its header's title — `2 of 5 changes`.
public struct EditorPeekView: Sendable, Equatable {
    public var index: Int
    public var count: Int
    public var afterLine: Int
    public var title: String
    public var old: [String]
    public var new: [String]
}

public func editorPeekView(_ tab: EditorTab) -> EditorPeekView? {
    guard let i = tab.peek, let base = tab.baseline, !tab.readOnly else { return nil }
    let hunks = editorHunks(base: base, text: tab.text)
    guard hunks.indices.contains(i) else { return nil }
    let h = hunks[i], lines = editorHunkLines(tab.text)
    let new = h.newCount == 0 ? [] : Array(lines[(h.newStart - 1)..<(h.newStart - 1 + h.newCount)])
    let after = h.kind == .deleted ? h.newStart - 1 : h.newStart + h.newCount - 1
    let title = "\(i + 1) of \(hunks.count) change\(hunks.count == 1 ? "" : "s")"
    return EditorPeekView(index: i, count: hunks.count, afterLine: after, title: title, old: h.oldLines, new: new)
}

/// Whether `line` has a change mark in `tab`: what the view asks before it dispatches `editor_peek`,
/// since a click anywhere in the gutter strip posts, marked or not.
public func editorPeekLineHasMark(_ tab: EditorTab, line: Int) -> Bool {
    guard let base = tab.baseline, !tab.readOnly else { return false }
    return editorHunkIndex(at: line, in: editorHunks(base: base, text: tab.text)) != nil
}

/// Revert's `editor_replace_range`, for the active tab's open peek: its path, the range, the old lines,
/// and `expect` — the text in the range now, the hunk's new text the operator saw. The store refuses
/// the edit when the range no longer holds it (a second press, or a buffer changed since this
/// snapshot), so Revert never reverts a hunk the operator did not see.
public func editorPeekRevert(_ s: EditorSnapshot) -> (path: String, range: EditorRange, text: String, expect: String)? {
    guard let a = s.active, a < s.tabs.count, let path = s.tabs[a].path, let i = s.tabs[a].peek,
          let base = s.tabs[a].baseline else { return nil }
    let text = s.tabs[a].text
    let hunks = editorHunks(base: base, text: text)
    guard hunks.indices.contains(i) else { return nil }
    let e = editorRevertEdit(hunks[i], text: text)
    return (path, e.range, e.text, editorText(text, in: e.range))
}

/// The peek index after `text` changed under it (R12): clamped to the hunks there are, nil when none.
public func editorPeekClamped(_ peek: Int?, baseline: String?, text: String) -> Int? {
    guard let peek, let baseline else { return nil }
    let n = editorHunks(base: baseline, text: text).count
    return n == 0 ? nil : min(peek, n - 1)
}

/// `range` as an action's `range` param.
public func editorRangeParam(_ r: EditorRange) -> JSONValue {
    func p(_ x: EditorPosition) -> JSONValue {
        .object(["line": .integer(Int64(x.line)), "column": .integer(Int64(x.column))])
    }
    return .object(["start": p(r.start), "end": p(r.end)])
}
