import Foundation

/// How many files one `files_replace` call may write before it answers `next` (Go also ends a call
/// after 250 ms). Cancel lands between calls (3b-ii-b ruling 1).
let editorReplaceBatchFiles = 50

/// One replacement in a text: the UTF-16 span [start, end) it replaces, and what goes there.
public struct EditorReplaceEdit: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var text: String
    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One file a replace wrote: what its undo puts back, and the mtime it must still have.
public struct EditorReplaceUndoRecord: Sendable, Equatable {
    public var path: String
    public var count: Int
    public var original: String
    public var mtime: Int64
    public init(path: String, count: Int, original: String, mtime: Int64) {
        self.path = path
        self.count = count
        self.original = original
        self.mtime = mtime
    }
}

/// A file a replace or its undo could not change, with why, whole (Rule 8). An empty `path` is the
/// run's own failure after some of it landed (a refused batch), listed with it.
public struct EditorReplaceFailure: Sendable, Equatable {
    public var path: String
    public var error: String
    public static let changedSince = "changed since the replace — left as it is"
    public static let stopped = "the undo stopped before this file; it was left as it is"
    /// The undo never writes a file open in a tab (Decision 39; final review M5).
    public static let openInTab = "open in a tab — left as it is"
    /// An open tab the replace could not edit (final review M8): read-only, or typed in during each
    /// of its three tries.
    public static let readOnlyTab = "read-only tab — left as it is"
    public static let typedDuring = "typed in while it was being replaced — left as it is"
    public init(path: String, error: String) {
        self.path = path
        self.error = error
    }
}

/// The pane's latest replace: what the result line says, and its one undo (spec: one, in memory).
public struct EditorReplaceResult: Sendable, Equatable {
    public var replaced: Int
    /// Files changed: written, or edited in an open tab's buffer.
    public var files: Int
    public var failures: [EditorReplaceFailure]
    /// The files written, never the buffers (those are ⌘Z's in their tab).
    public var undo: [EditorReplaceUndoRecord]
    public var cancelled: Bool
    public var undone: Bool
    public var restored: Int
    /// A root had more than 50,000 files: only those listed were replaced (final review M6).
    public var filesTruncated: Bool
    public static let filesTruncatedNote = "only the first 50,000 files were replaced"
    public var undoable: Bool { !undone && !undo.isEmpty }
    public init(replaced: Int, files: Int, failures: [EditorReplaceFailure] = [], undo: [EditorReplaceUndoRecord] = [],
                cancelled: Bool = false, undone: Bool = false, restored: Int = 0, filesTruncated: Bool = false) {
        self.replaced = replaced
        self.files = files
        self.failures = failures
        self.undo = undo
        self.cancelled = cancelled
        self.undone = undone
        self.restored = restored
        self.filesTruncated = filesTruncated
    }
}

/// The Search view's Replace (3b-ii-b): the field, its toggle, the run in flight, the latest result
/// and the preview of each shown line.
public struct EditorReplaceState: Sendable, Equatable {
    /// The field's text, kept while the toggle is closed (Rule 2).
    public var text: String
    public var shown: Bool
    public var inFlight: Bool
    /// The run in flight is an undo (`inFlight` is true too): the view says "undoing" (pre-flight F6).
    public var undoing: Bool
    /// Cancel was pressed: the run stops before its next `files_replace` call, or the undo before its
    /// next file.
    public var cancelRequested: Bool
    public var last: EditorReplaceResult?
    /// Each shown result line's replacements, keyed by the line's preview text.
    public var preview: [String: [EditorReplaceEdit]]
    /// Bumps per preview asked for; an older answer is dropped.
    public var previewSerial: Int
    public static let closed = EditorReplaceState(text: "", shown: false, inFlight: false, undoing: false,
                                                  cancelRequested: false, last: nil, preview: [:], previewSerial: 0)
    public init(text: String, shown: Bool, inFlight: Bool, undoing: Bool, cancelRequested: Bool, last: EditorReplaceResult?,
                preview: [String: [EditorReplaceEdit]], previewSerial: Int) {
        self.text = text
        self.shown = shown
        self.inFlight = inFlight
        self.undoing = undoing
        self.cancelRequested = cancelRequested
        self.last = last
        self.preview = preview
        self.previewSerial = previewSerial
    }
}

/// A result line's pieces: kept text, the match struck through, and its replacement in violet.
public enum EditorReplaceSpan: Sendable, Equatable { case kept(String), removed(String), inserted(String) }

public func editorReplacePreviewSpans(_ preview: String, edits: [EditorReplaceEdit]) -> [EditorReplaceSpan] {
    let u = Array(preview.utf16)
    func piece(_ r: Range<Int>) -> String { String(decoding: u[r], as: UTF16.self) }
    var out: [EditorReplaceSpan] = []
    var at = 0
    for e in edits where e.start >= at && e.start <= e.end && e.end <= u.count {
        if e.start > at { out.append(.kept(piece(at..<e.start))) }
        if e.end > e.start { out.append(.removed(piece(e.start..<e.end))) }
        if !e.text.isEmpty { out.append(.inserted(e.text)) }
        at = e.end
    }
    if at < u.count { out.append(.kept(piece(at..<u.count))) }
    return out
}

/// The preview's one call: each shown line once, in order.
public func editorReplacePreviewTexts(_ results: [EditorSearchMatch]) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for m in results where seen.insert(m.preview).inserted { out.append(m.preview) }
    return out
}

/// The 1-based position (UTF-16 column) of a UTF-16 offset.
public func editorPosition(_ text: String, utf16Offset offset: Int) -> EditorPosition {
    var line = 1, column = 1, i = 0
    for u in text.utf16 {
        if i == offset { break }
        if u == 10 { line += 1; column = 1 } else { column += 1 }
        i += 1
    }
    return EditorPosition(line: line, column: column)
}

/// The one agent edit that turns `old` into `new`: the smallest span that differs, never inside a
/// surrogate pair. nil when they are the same.
public func editorReplaceChange(old: String, new: String) -> (range: EditorRange, text: String)? {
    guard old != new else { return nil }
    let a = Array(old.utf16), b = Array(new.utf16)
    var p = 0
    while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
    if p > 0, (p < a.count && UTF16.isTrailSurrogate(a[p])) || (p < b.count && UTF16.isTrailSurrogate(b[p])) { p -= 1 }
    var s = 0
    while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
    if s > 0, UTF16.isTrailSurrogate(a[a.count - s]) { s -= 1 }
    let text = String(decoding: b[p..<(b.count - s)], as: UTF16.self)
    return (EditorRange(start: editorPosition(old, utf16Offset: p), end: editorPosition(old, utf16Offset: a.count - s)), text)
}

public func editorReplaceSummary(_ r: EditorReplaceResult) -> String {
    func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
    if r.undone { return "Undid the replace in \(files(r.restored))" }
    let what = "\(r.replaced) in \(files(r.files))"
    let line = r.cancelled ? "Replace cancelled · replaced \(what)" : "Replaced \(what)"
    return r.filesTruncated ? "\(line) · \(EditorReplaceResult.filesTruncatedNote)" : line
}

/// Replace All and Replace in this file are pressable: a query with results, no error, no replace
/// running and no search running — results a search in flight is about to replace are stale (final
/// review M3).
public func editorReplaceAvailable(_ s: EditorSearchState) -> Bool {
    !s.query.isEmpty && s.error == nil && !s.replace.inFlight && !s.inFlight && !s.results.isEmpty
}

// MARK: - Replies (internal)

struct EditorReplacedText: Sendable, Equatable {
    var text: String
    var count: Int
    var edits: [EditorReplaceEdit]
}

private func editorStrings(_ v: JSONValue?) -> [String] {
    guard case .array(let items)? = v else { return [] }
    return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
}

private func editorEdits(_ v: JSONValue?) -> [EditorReplaceEdit] {
    guard case .array(let items)? = v else { return [] }
    return items.compactMap { item in
        guard case .object(let e) = item, let start = e["start"]?.intValue, let end = e["end"]?.intValue,
              case .string(let text)? = e["text"] else { return nil }
        return EditorReplaceEdit(start: start, end: end, text: text)
    }
}

/// `files_replace_text`'s `results`, in order.
func editorReplacedTexts(from o: [String: JSONValue]) -> [EditorReplacedText] {
    guard case .array(let items)? = o["results"] else { return [] }
    return items.compactMap { item in
        guard case .object(let r) = item, case .string(let text)? = r["text"] else { return nil }
        return EditorReplacedText(text: text, count: r["count"]?.intValue ?? 0, edits: editorEdits(r["edits"]))
    }
}

/// One `files_replace` reply.
struct EditorReplaceBatch: Sendable, Equatable {
    var written: [EditorReplaceUndoRecord]
    var failures: [EditorReplaceFailure]
    var skipped: [String]
    var next: String
    var filesTruncated = false
}

func editorReplaceBatch(from o: [String: JSONValue]) -> EditorReplaceBatch {
    var written: [EditorReplaceUndoRecord] = []
    if case .array(let items)? = o["files"] {
        for item in items {
            guard case .object(let f) = item, case .string(let path)? = f["path"],
                  case .string(let original)? = f["original"] else { continue }
            written.append(EditorReplaceUndoRecord(path: path, count: f["count"]?.intValue ?? 0, original: original,
                                                   mtime: Int64(f["mtime"]?.intValue ?? 0)))
        }
    }
    var failures: [EditorReplaceFailure] = []
    if case .array(let items)? = o["failures"] {
        for item in items {
            guard case .object(let f) = item, case .string(let path)? = f["path"], case .string(let error)? = f["error"] else { continue }
            failures.append(EditorReplaceFailure(path: path, error: error))
        }
    }
    let next: String = { if case .string(let n)? = o["next"] { n } else { "" } }()
    return EditorReplaceBatch(written: written, failures: failures, skipped: editorStrings(o["skipped"]), next: next,
                              filesTruncated: o["truncated_files"] == .bool(true))
}

/// What a replace run has done so far, batch by batch, then its buffers.
struct EditorReplaceRun: Sendable {
    var undo: [EditorReplaceUndoRecord] = []
    var failures: [EditorReplaceFailure] = []
    var skipped: Set<String> = []
    var replaced = 0
    var paths: Set<String> = []
    var cancelled = false
    var filesTruncated = false

    mutating func add(_ b: EditorReplaceBatch) {
        undo += b.written
        filesTruncated = filesTruncated || b.filesTruncated
        failures += b.failures
        skipped.formUnion(b.skipped)
        for r in b.written { replaced += r.count; paths.insert(r.path) }
    }

    mutating func addBuffers(count: Int, paths edited: Set<String>) {
        replaced += count
        paths.formUnion(edited)
    }

    var result: EditorReplaceResult {
        EditorReplaceResult(replaced: replaced, files: paths.count, failures: failures, undo: undo, cancelled: cancelled,
                            filesTruncated: filesTruncated)
    }
}

func editorReplaceFailuresJSON(_ failures: [EditorReplaceFailure]) -> JSONValue {
    .array(failures.map { .object(["path": .string($0.path), "error": .string($0.error)]) })
}

/// `read_pane`'s `last_replace`.
func editorReplaceJSON(_ r: EditorReplaceResult) -> JSONValue {
    .object(["replaced": .number(Double(r.replaced)), "files": .number(Double(r.files)),
             "failures": editorReplaceFailuresJSON(r.failures), "undoable": .bool(r.undoable),
             "undone": .bool(r.undone), "restored": .number(Double(r.restored)), "cancelled": .bool(r.cancelled),
             "files_truncated": .bool(r.filesTruncated)])
}
