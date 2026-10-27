import Foundation

/// One row under the address field (3c-iii, ruling 7).
public struct BrowserSuggestion: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case tab, bookmark, history, search }
    public var kind: Kind
    public var title: String
    /// The page's URL; the words to search for on a `.search` row.
    public var url: String
    /// The tab's id on a `.tab` row.
    public var tab: String?

    public var id: String { "\(kind.rawValue):\(url)" }

    public init(kind: Kind, title: String, url: String, tab: String?) {
        self.kind = kind; self.title = title; self.url = url; self.tab = tab
    }
}

/// **Ranking and inline completion** for the address field (rulings 7 and 8). Pure.
public enum BrowserSuggestions {
    static let tabLimit = 3
    static let bookmarkLimit = 3
    static let pageLimit = 8  // tabs, bookmarks and history together
    static let searchLimit = 4

    /// `url` without its `scheme://`, a leading `www.` and a trailing `/`.
    public static func bareURL(_ url: String) -> String {
        var bare = Substring(url)
        if let range = bare.range(of: "://") { bare = bare[range.upperBound...] }
        if bare.lowercased().hasPrefix("www.") { bare = bare.dropFirst(4) }
        while bare.hasSuffix("/") { bare = bare.dropLast() }
        return String(bare)
    }

    /// The typed text as a bare URL is read: trimmed, without a leading `http://` or `https://` and
    /// a leading `www.` (case-insensitive), so `https://git` and `www.git` both mean `git`.
    public static func normalised(_ typed: String) -> String {
        var text = Substring(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = text.dropFirst(scheme.count)
            break
        }
        if text.lowercased().hasPrefix("www.") { text = text.dropFirst(4) }
        return String(text)
    }

    /// The typed text trimmed and split on whitespace.
    public static func words(_ typed: String) -> [String] {
        typed.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `tabs` are the open tabs to offer (the caller leaves out the one being edited, whose id
    /// repeats from pane to pane); a tab with no address yet is never offered.
    public static func rank(
        _ typed: String, tabs: [BrowserTab],
        bookmarks: [BrowserBookmark], history: [BrowserHistoryEntry], search: [String]
    ) -> [BrowserSuggestion] {
        let wholeTyped = normalised(typed).lowercased()
        let typedWords = words(wholeTyped)
        guard let first = typedWords.first else { return [] }

        /// nil when a word is missing from both the bare URL and the title.
        func score(url: String, title: String) -> Int? {
            let bare = bareURL(url).lowercased()
            let lowerTitle = title.lowercased()
            guard typedWords.allSatisfy({ bare.contains($0) || lowerTitle.contains($0) }) else { return nil }
            if bare.hasPrefix(wholeTyped) { return 3 }
            let titleWords = lowerTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if titleWords.contains(where: { $0.hasPrefix(first) }) { return 2 }
            return 1
        }

        var seen = Set<String>()
        var rows: [BrowserSuggestion] = []

        // Open tabs: strip order on ties (the sort is stable).
        let tabHits = tabs.enumerated().compactMap { index, tab -> (Int, Int, BrowserTab)? in
            guard !tab.url.isEmpty, let s = score(url: tab.url, title: tab.label) else { return nil }
            return (s, index, tab)
        }.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        for (_, _, tab) in tabHits where rows.count < tabLimit && seen.insert(tab.url).inserted {
            rows.append(BrowserSuggestion(kind: .tab, title: tab.label, url: tab.url, tab: tab.id))
        }

        // Bookmarks: newest first on ties.
        let markHits = bookmarks.compactMap { mark -> (Int, BrowserBookmark)? in
            score(url: mark.url, title: mark.title).map { ($0, mark) }
        }.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.added > $1.1.added }
        var marks = 0
        for (_, mark) in markHits where marks < bookmarkLimit && seen.insert(mark.url).inserted {
            rows.append(BrowserSuggestion(kind: .bookmark, title: mark.title, url: mark.url, tab: nil))
            marks += 1
        }

        // History fills to the page limit: higher score, then count, then last visit.
        let historyHits = history.compactMap { entry -> (Int, BrowserHistoryEntry)? in
            score(url: entry.url, title: entry.title).map { ($0, entry) }
        }.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            if $0.1.count != $1.1.count { return $0.1.count > $1.1.count }
            return $0.1.last > $1.1.last
        }
        for (_, entry) in historyHits where rows.count < pageLimit && seen.insert(entry.url).inserted {
            rows.append(BrowserSuggestion(kind: .history, title: entry.title, url: entry.url, tab: nil))
        }

        // The engine's own order.
        var searches = 0
        for words in search where searches < searchLimit {
            rows.append(BrowserSuggestion(kind: .search, title: words, url: words, tab: nil))
            searches += 1
        }
        return rows
    }

    /// The text to add after what was typed: to the end of the host, or to the end of the whole bare
    /// URL once the typed text holds a `/`. Nil with whitespace or when no page row starts with it.
    public static func completion(_ typed: String, in rows: [BrowserSuggestion]) -> String? {
        guard !typed.contains(where: \.isWhitespace) else { return nil }
        let typed = normalised(typed)
        guard !typed.isEmpty else { return nil }
        let lower = typed.lowercased()
        for row in rows where row.kind != .search {
            let bare = bareURL(row.url)
            guard bare.lowercased().hasPrefix(lower), bare.count > typed.count else { continue }
            let rest = bare.dropFirst(typed.count)
            if typed.contains("/") { return String(rest) }
            let end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
            let suffix = String(rest[..<end])
            return suffix.isEmpty ? nil : suffix
        }
        return nil
    }
}

/// **The search engines' suggestions** (ruling 10): the URL to ask, the reply's parser, and the
/// session that asks. This type never fetches.
public enum BrowserEngineSuggest {
    private static let prefixes: [String: String] = [
        "google": "https://suggestqueries.google.com/complete/search?client=firefox&q=",
        "duckduckgo": "https://duckduckgo.com/ac/?type=list&q=",
        "bing": "https://api.bing.com/osjson.aspx?query=",
    ]

    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Nil for Kagi (its endpoint needs the operator's login) and for an unknown engine.
    public static func url(engine: String, query: String) -> URL? {
        guard let prefix = prefixes[engine],
              let encoded = query.addingPercentEncoding(withAllowedCharacters: queryAllowed)
        else { return nil }
        return URL(string: prefix + encoded)
    }

    /// OpenSearch `[query, [s1, s2, …]]`; anything else gives no rows.
    public static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2, let list = json[1] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    /// Ephemeral: no cookies, no cache, so no organisation's login travels with a keystroke.
    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }
}
