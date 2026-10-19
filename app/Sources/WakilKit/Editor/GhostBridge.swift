import Foundation

/// 3b-viii ghost-text: the caret a page request names, as an index into the text it sent.
/// Monaco counts offsets in UTF-16 units; one that is past the end or splits a character (inside
/// an emoji's surrogate pair) names no caret, and the request answers nothing.
public func ghostCaret(text: String, utf16Offset: Int) -> String.Index? {
    guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
    let index = String.Index(utf16Offset: utf16Offset, in: text)
    return index.samePosition(in: text.unicodeScalars) == nil ? nil : index
}

/// The path and language a ghost request for `tab` carries, or nil for a tab that never asks: a
/// read-only one (a diff, a large file's tail, a binary or over-cap file). A scratch tab asks with
/// no path.
public func ghostTabContext(_ tab: EditorTab) -> (path: String, language: String)? {
    guard !tab.readOnly else { return nil }
    switch tab.subject {
    case .file(let path, _): return (path, tab.language)
    case .scratch: return ("", tab.language)
    case .diff: return nil
    }
}

/// Which of a pane's page requests may still go to the model. Swift builds a request across an
/// await (the schema), so a cancel can land before the request is asked, and two requests can
/// finish building out of order. Page ids only grow; the newest admitted or cancelled id is the
/// floor, and nothing at or under it is asked.
public struct GhostRequestOrder: Sendable, Equatable {
    private var newest = 0

    public init() {}

    /// The page cancelled `id`: it is never asked. True when it may be the request now asked (or
    /// one not yet asked), so the pane's session is released; false for a late cancel of an
    /// older one, which must not drop the newer request.
    public mutating func cancel(_ id: Int) -> Bool {
        defer { newest = max(newest, id) }
        return id >= newest
    }

    /// Whether `id`, built, may be asked now; if so it becomes the newest.
    public mutating func admit(_ id: Int) -> Bool {
        guard id > newest else { return false }
        newest = id
        return true
    }
}
