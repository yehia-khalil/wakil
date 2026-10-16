import Foundation

/// The seam between a pane and whatever draws a two-sided diff. The git pane is its first
/// user; the editor (Decision 17) reuses it. One conformance today, `MonacoDiffRenderer`
/// in WakilApp, a `WKWebView` hosting Monaco's diff editor.
///
/// `scrollTop` is the modified side's vertical scroll, in points. Reading it answers the
/// last position the renderer knows of — a web view cannot be asked synchronously — and
/// writing it applies once the diff being shown has laid out.
@MainActor public protocol DiffRenderer: AnyObject {
    func show(original: String, modified: String, language: String)
    func clear()
    var scrollTop: Double { get set }
}

/// What a diff host was last told to show: the file, and the texts it was shown with.
public struct GitDiffShown: Sendable, Equatable {
    public var selection: GitSelection
    public var original: String
    public var modified: String
    public var language: String

    public init(selection: GitSelection, original: String, modified: String, language: String) {
        self.selection = selection
        self.original = original
        self.modified = modified
        self.language = language
    }
}

/// What to tell the diff host when a snapshot lands.
public enum GitDiffUpdate: Sendable, Equatable {
    /// Leave it as it is.
    case keep
    /// Empty it: no selection, an error or a binary file (drawn beside it), or another file
    /// still loading — the last file's diff must not sit under the new file's name.
    case clear
    /// Show this. `keepScroll` when it is the same file re-delivered by a refresh (Rule 6).
    case show(GitDiffShown, keepScroll: Bool)
}

/// The decision behind `GitDiffUpdate`, given what the host shows now.
///
/// A refresh marks the diff loading but keeps its texts, so the same file loading is left
/// alone and lands as a `show` that keeps the scroll — or as nothing, when the file did not
/// change. A select writes empty texts while it loads, so another file loading clears.
public func gitDiffUpdate(shown: GitDiffShown?, snapshot: GitSnapshot) -> GitDiffUpdate {
    let emptied: GitDiffUpdate = shown == nil ? .keep : .clear
    guard let selection = snapshot.selection, let diff = snapshot.diff else { return emptied }
    if diff.loading { return shown?.selection == selection ? .keep : emptied }
    if diff.error != nil || diff.binary { return emptied }
    let next = GitDiffShown(selection: selection, original: diff.original, modified: diff.modified,
                            language: diff.language)
    if next == shown { return .keep }
    return .show(next, keepScroll: shown?.selection == selection)
}

/// Applies `update` to `renderer` and answers what it now shows. A kept scroll is read
/// before the new texts replace the old and written back after them.
@MainActor
public func gitApply(_ update: GitDiffUpdate, to renderer: any DiffRenderer, shown: GitDiffShown?)
    -> GitDiffShown?
{
    switch update {
    case .keep:
        return shown
    case .clear:
        renderer.clear()
        return nil
    case .show(let next, let keepScroll):
        let top = renderer.scrollTop
        renderer.show(original: next.original, modified: next.modified, language: next.language)
        if keepScroll { renderer.scrollTop = top }
        return next
    }
}
