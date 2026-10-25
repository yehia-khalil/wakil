import Foundation

// 3a-v-b: the conflict blocks in a conflicted file's text, and what each Accept writes in place of one.
// Pure, so WakilApp's decorations and the actions read the same blocks; the Accept goes through
// `editor_replace_range`'s own path (R2), so the page makes it one undo step.

/// One complete conflict block: the 1-based lines of its `<<<<<<<`, `=======` and `>>>>>>>` markers,
/// and the names the markers give the two sides (`HEAD`, `feature/search`).
public struct EditorConflictBlock: Sendable, Equatable {
    public var start: Int
    public var separator: Int
    public var end: Int
    public var currentLabel: String
    public var incomingLabel: String

    public init(start: Int, separator: Int, end: Int, currentLabel: String, incomingLabel: String) {
        (self.start, self.separator, self.end) = (start, separator, end)
        (self.currentLabel, self.incomingLabel) = (currentLabel, incomingLabel)
    }
}

/// Which side an Accept keeps: Accept Current Change, Accept Incoming Change, Accept Both Changes.
public enum EditorConflictTake: String, Sendable, CaseIterable { case current, incoming, both }

/// `text`'s lines by UTF-16 offset. Lines end at `\n`; a `\r` before it belongs to the ending, so a
/// CRLF file's lines read as an LF file's (a Swift `Character` would take `\r\n` as one).
private struct EditorTextLines {
    let u: [UInt16]
    /// The offset each line starts at; `starts.count` is the number of lines.
    let starts: [Int]

    init(_ text: String) {
        u = Array(text.utf16)
        var s = [0]
        for (i, c) in u.enumerated() where c == 10 { s.append(i + 1) }
        starts = s
    }

    var count: Int { starts.count }

    /// Line `n` (1-based) without its ending.
    func line(_ n: Int) -> String {
        let a = starts[n - 1]
        var b = n < count ? starts[n] - 1 : u.count
        if b > a, u[b - 1] == 13 { b -= 1 }
        return String(decoding: u[a..<b], as: UTF16.self)
    }

    /// Lines `from..<to` (1-based) with their endings, as the text has them.
    func chunk(_ from: Int, _ to: Int) -> String {
        guard from < to else { return "" }
        return String(decoding: u[starts[from - 1]..<starts[to - 1]], as: UTF16.self)
    }
}

/// The label after `marker` when `line` is that marker at its start, followed by a space or nothing.
private func conflictMarker(_ line: String, _ marker: String) -> String? {
    if line == marker { return "" }
    guard line.hasPrefix(marker + " ") else { return nil }
    return String(line.dropFirst(marker.count + 1))
}

/// Every complete block in `text`, in order. A marker counts only at a line's start followed by a
/// space or the line's end; a `=======` or `>>>>>>>` outside an open block is text, and a block that
/// opens again before it closes starts over from the new `<<<<<<<`.
public func editorConflictBlocks(_ text: String) -> [EditorConflictBlock] {
    let lines = EditorTextLines(text)
    var out: [EditorConflictBlock] = []
    var open: (start: Int, label: String)?
    var separator: Int?
    for n in 1...lines.count {
        let line = lines.line(n)
        if let label = conflictMarker(line, "<<<<<<<") {
            open = (n, label)
            separator = nil
        } else if open != nil, separator == nil, conflictMarker(line, "=======") != nil {
            separator = n
        } else if let o = open, let sep = separator, let label = conflictMarker(line, ">>>>>>>") {
            out.append(EditorConflictBlock(start: o.start, separator: sep, end: n, currentLabel: o.label, incomingLabel: label))
            open = nil
            separator = nil
        }
    }
    return out
}

/// What replaces `b` for `take`: the range from its `<<<<<<<` line through its `>>>>>>>` line's
/// ending, and the side (or both, current first) kept, each line with the ending it had. A diff3
/// `|||||||` base section is dropped. A block on the last line ends without an ending, as it did.
public func editorConflictAccept(_ text: String, _ b: EditorConflictBlock,
                                 take: EditorConflictTake) -> (range: EditorRange, text: String) {
    let lines = EditorTextLines(text)
    let base = (b.start + 1..<b.separator).first { conflictMarker(lines.line($0), "|||||||") != nil }
    let current = lines.chunk(b.start + 1, base ?? b.separator)
    let incoming = lines.chunk(b.separator + 1, b.end)
    var kept = switch take {
    case .current: current
    case .incoming: incoming
    case .both: current + incoming
    }
    let from = EditorPosition(line: b.start, column: 1)
    guard b.end == lines.count else { return (EditorRange(start: from, end: EditorPosition(line: b.end + 1, column: 1)), kept) }
    // One `Character`, whether the ending is `\n` or `\r\n`.
    if kept.hasSuffix("\r\n") || kept.hasSuffix("\n") { kept.removeLast() }
    let width = lines.u.count - lines.starts[b.end - 1]
    return (EditorRange(start: from, end: EditorPosition(line: b.end, column: width + 1)), kept)
}

/// Whether `tab` is a file its root lists in the Merge Changes group (Task 5), or as staged with
/// conflict markers (spec call 4): the tabs the conflict actions and ⌘K's Next / Previous Conflict
/// work on. Markers in a file in neither are text git did not write.
public func editorConflicted(_ tab: EditorTab?, roots: [GitRootState]) -> Bool {
    guard case .file(let path, let root)? = tab?.subject, path.hasPrefix(root + "/"),
          let state = roots.first(where: { $0.root == root }) else { return false }
    let rel = String(path.dropFirst(root.count + 1))
    return state.files.contains { $0.path == rel && ($0.group == .conflicts || ($0.group == .staged && $0.markers)) }
}

/// The block Next (`forward`) or Previous Conflict moves the cursor on `line` to: the first starting
/// after it (or the last before it), wrapping round the file. Nil with no blocks.
public func editorConflictStep(_ blocks: [EditorConflictBlock], from line: Int, forward: Bool) -> EditorConflictBlock? {
    forward ? blocks.first { $0.start > line } ?? blocks.first
            : blocks.last { $0.start < line } ?? blocks.last
}
