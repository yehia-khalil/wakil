import Foundation

/// The browser pane (3c-i): tabs of web pages. Its contents are its snapshot. The store owns each
/// tab's address, title and state; a WebKit view per tab applies the tab's `command` and reports
/// back through `PaneStore.browserPageDidReport`.
enum BrowserPaneKind: PaneKind {
    static let names = ["browser"]
    static var emptyContents: BrowserSnapshot { .empty }
    static var emptyShared: Void { () }
    static var emptySnapshot: BrowserSnapshot? { .empty }
    static func snapshot(of contents: BrowserSnapshot, in store: isolated PaneStore) -> BrowserSnapshot { contents }
    static func failure(of contents: BrowserSnapshot) -> String? { contents.activeTab?.failure }

    /// Every key always present. **Never page text**: the agent reads what the operator sees by
    /// address and title, not the page's contents. No key may be `kind` or `failure` (the envelope's).
    static func readPane(_ s: BrowserSnapshot, in store: isolated PaneStore) -> [String: JSONValue] {
        let tab = s.activeTab
        return [
            "tabs": .array(s.tabs.map { t in .object([
                "id": .string(t.id), "url": .string(t.url), "title": .string(t.title),
                "loading": .bool(t.isLoading), "active": .bool(t.id == s.active),
            ]) }),
            "active": tab.map { .string($0.id) } ?? .null,
            "url": tab.map { .string($0.url) } ?? .null,
            "title": tab.map { .string($0.title) } ?? .null,
            "loading": tab.map { .bool($0.isLoading) } ?? .null,
            "canGoBack": tab.map { .bool($0.canGoBack) } ?? .null,
            "canGoForward": tab.map { .bool($0.canGoForward) } ?? .null,
            "zoom": tab.map { .number($0.zoom) } ?? .null,
            "find": s.find.map { f in .object([
                "query": .string(f.query), "current": .number(Double(f.current)), "total": .number(Double(f.total)),
            ]) } ?? .null,
            "downloads": .array(s.downloads.map { d in .object([
                "id": .string(d.id), "filename": .string(d.filename), "state": .string(d.state.rawValue),
                "received": .number(Double(d.received)), "expected": .number(Double(d.expected)),
            ]) }),
        ]
    }
}

extension PaneSnapshot {
    public var browser: BrowserSnapshot? { contents as? BrowserSnapshot }
}

extension BrowserSnapshot: PaneKindSnapshot {}

extension BrowserPaneKind: PaneRestorable {
    /// A browser's subject is its saved tabs, reopened by its own action (only the active one
    /// fetches). Nothing to restore when the layout saved no tabs.
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        guard !(pane.browserTabs ?? []).isEmpty else { return nil }
        return PaneRestoreStep(action: "browser_restore", params: .object(["pane": .string(pane.id)]), recordsFailure: false)
    }
}
