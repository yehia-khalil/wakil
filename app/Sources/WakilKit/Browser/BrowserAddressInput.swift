import Foundation

/// **The address field while it is edited** (3c-iii, rulings 8 and 9): what was typed, the rows
/// under it, the highlighted row and the inline completion — and so what the field shows. Pure: the
/// pane feeds it the field's edits, its keys and the rows as they arrive, and draws `shown`.
public struct BrowserAddressInput: Equatable, Sendable {
    /// What Return or a click on a row opens.
    public enum Choice: Equatable, Sendable {
        /// An open tab: `browser_select_tab`.
        case tab(id: String, url: String)
        /// `browser_navigate {input}`: a page's URL, a search row's words, or what the field shows.
        case navigate(String)
    }

    /// What the operator typed (the URL the field opened with, until the first edit).
    public private(set) var typed: String
    public private(set) var rows: [BrowserSuggestion] = []
    /// The row ↓ and ↑ moved to; nil while the field shows what was typed.
    public private(set) var highlight: Int?
    /// The inline completion after `typed`, selected in the field so the next keystroke replaces it.
    public private(set) var completion: String?
    /// Whether the last edit inserted at the end of the field: a completion is offered only then.
    private var completes = false
    /// Whether the operator has edited since the field opened: rows are asked only after an edit.
    private var edited = false
    /// Esc hid the rows: none come back until the next edit.
    private var dismissed = false

    public init(_ text: String = "") { typed = text }

    /// What the field shows: the highlighted row's URL (a search row's words), else what was typed
    /// and its completion.
    public var shown: String {
        if let highlight { return rows[highlight].url }
        return typed + (completion ?? "")
    }

    /// The completed part of `shown`, in UTF-16 units: what the field editor selects.
    public var completionRange: NSRange? {
        guard highlight == nil, let completion else { return nil }
        return NSRange(location: typed.utf16.count, length: completion.utf16.count)
    }

    /// The text to ask rows for: nil until the operator edits, and after Esc hid them.
    public var query: String? { edited && !dismissed ? typed : nil }

    /// The field's text is now `text`. The text this put there (`shown`) is not an edit; anything
    /// else is the operator's: the highlight goes, and a completion is offered (from the rows already
    /// shown, until the new ones arrive) only when it was an insertion at the end — the caret ends
    /// there and the edit was not a deletion from the end (the text is not what was there, cut
    /// short). Typing over the whole selected URL counts: what is typed ends at the end.
    public mutating func fieldChanged(to text: String, caretAtEnd: Bool) {
        guard text != shown else { return }
        let before = highlight.map { rows[$0].url } ?? typed
        completes = caretAtEnd && !text.isEmpty && !before.hasPrefix(text)
        typed = text
        highlight = nil
        edited = true
        dismissed = false
        completion = completes ? BrowserSuggestions.completion(text, in: rows) : nil
    }

    /// The caret or selection left the end while a completion was showing (ruling 8): the completion
    /// is dropped and what the field shows stays, as typed.
    public mutating func caretLeftEnd() {
        guard highlight == nil, completion != nil else { return }
        typed = shown
        completion = nil
        completes = false
    }

    /// Rows answered for `text`; dropped when the operator has typed on since, or Esc hid them.
    public mutating func rowsArrived(_ new: [BrowserSuggestion], for text: String) {
        guard query == text else { return }
        let kept = highlight.map { rows[$0].id }
        rows = new
        highlight = kept.flatMap { id in new.firstIndex { $0.id == id } }
        if highlight == nil { completion = completes ? BrowserSuggestions.completion(typed, in: new) : nil }
    }

    /// ↓ (`down`) or ↑ through the rows; ↑ from the first row brings back what was typed. Moving
    /// drops the completion. False with no rows, so the key keeps its meaning.
    public mutating func move(down: Bool) -> Bool {
        guard !rows.isEmpty else { return false }
        completion = nil
        completes = false
        if down {
            highlight = min((highlight ?? -1) + 1, rows.count - 1)
        } else if let h = highlight {
            highlight = h == 0 ? nil : h - 1
        }
        return true
    }

    /// Esc with rows showing hides them and puts back what was typed. False with none, so Esc keeps
    /// its meaning.
    public mutating func escape() -> Bool {
        guard !rows.isEmpty else { return false }
        rows = []
        highlight = nil
        completion = nil
        completes = false
        dismissed = true
        return true
    }

    /// Return: the highlighted row, else what the field shows.
    public var choice: Choice {
        if let highlight { return Self.choice(rows[highlight]) }
        return .navigate(shown)
    }

    /// A row chosen by Return or a click.
    public static func choice(_ row: BrowserSuggestion) -> Choice {
        if row.kind == .tab, let id = row.tab { return .tab(id: id, url: row.url) }
        return .navigate(row.url)
    }
}

/// **The ★ menu** (ruling 12): whether the active tab's page is bookmarked, the toggle's words, and
/// the organisation's bookmarks, newest first. Pure.
public struct BrowserBookmarkChoices: Equatable, Sendable {
    public static let add = "Bookmark This Page"
    public static let remove = "Remove Bookmark"
    public static let none = "No bookmarks yet"

    /// The active tab's URL is in the list (matched exactly, ruling 4).
    public let bookmarked: Bool
    /// Off for a page that can't be bookmarked (a blank tab, `about:`) and isn't.
    public let canToggle: Bool
    public let entries: [BrowserBookmark]

    public var toggleTitle: String { bookmarked ? Self.remove : Self.add }

    public init(url: String?, bookmarks: [BrowserBookmark]) {
        let bookmarked = url.map { u in bookmarks.contains { $0.url == u } } ?? false
        self.bookmarked = bookmarked
        canToggle = bookmarked || url.map(BrowserBookmark.isBookmarkable) == true
        entries = bookmarks.sorted { $0.added > $1.added }
    }
}

extension BrowserBookmark {
    /// Only web pages: `http`, `https` and `file` (ruling 5).
    public static func isBookmarkable(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }
}
