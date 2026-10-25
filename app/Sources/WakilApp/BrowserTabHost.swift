import AppKit
import Foundation
import Observation
import WakilKit
import WebKit

/// The window's browser web views (3c-i), one per tab, alive for the window.
///
/// **Held by the window's session, not by a view**, so a tab switch, a layout change or a place
/// switch that takes the pane off the canvas never reloads a page: SwiftUI rebuilds the pane and the
/// same web view is put back (`BrowserPageHost`).
///
/// **A web view belongs to a place.** Keyed by the place's `LayoutScope`, pane and tab: pane and
/// tab ids repeat from place to place (`browser-1`, `t1`), so a key without the place would hand one
/// place's page — and its organisation's logins — to another's pane (Invariant 4). Each delegate
/// carries its scope into every seam call, and the window drops the calls of a place not on screen;
/// when the place is shown again its pane asks for a fresh report (`reportAll`).
///
/// At most `limit` live web views: the least recently shown is released, its `interactionState`
/// saved first, and rebuilt from that state when its tab is shown again.
@MainActor
@Observable
final class BrowserTabHost {
    struct Key: Hashable {
        let scope: LayoutScope
        let pane: String
        let tab: String
    }

    static let limit = 20

    @ObservationIgnored weak var model: WindowModel?
    @ObservationIgnored private var views: [Key: BrowserWebView] = [:]
    @ObservationIgnored private var delegates: [Key: BrowserTabDelegate] = [:]
    /// Least recently used first.
    @ObservationIgnored private var recency: [Key] = []
    /// The seq of the last command applied per tab; a command applies only above it.
    @ObservationIgnored private var applied: [Key: Int] = [:]
    /// Tabs a page opened (pop-ups): they arrive without taking the keyboard to the address field.
    @ObservationIgnored private(set) var openedByPage: Set<Key> = []
    /// Keys a pop-up's web view was filed under before the store named its tab: placeholders, the
    /// only views a later filing may replace.
    @ObservationIgnored private var pendingPopups: Set<Key> = []

    /// The icon a page names in its `link rel=icon`, per tab — only a `data:` one, decoded here:
    /// nothing is fetched for it, so no request leaves outside the organisation's own store.
    private(set) var favicons: [Key: NSImage] = [:]
    /// Raised when live web views were dropped under panes that may be on screen (clearing an
    /// organisation's data), so those panes draw again and rebuild their pages.
    private(set) var rebuilds = 0
    /// Stores being deleted (a data clear): no web view is built on one until the clear is done.
    @ObservationIgnored private var clearing: Set<UUID> = []

    init(model: WindowModel) {
        self.model = model
    }

    // MARK: Web views

    /// The tab's web view if it is live, without making one or touching its recency.
    func existing(scope: LayoutScope, pane: String, tab: String) -> BrowserWebView? {
        views[Key(scope: scope, pane: pane, tab: tab)]
    }

    /// The tab's web view, made with `make` when it has none; it becomes the most recently used.
    func webView(scope: LayoutScope, pane: String, tab: String, make: () -> BrowserWebView) -> BrowserWebView {
        let key = Key(scope: scope, pane: pane, tab: tab)
        if let view = views[key] {
            touch(key)
            return view
        }
        let view = make()
        views[key] = view
        touch(key)
        evictBeyondLimit(keeping: key)
        return view
    }

    /// The tab's web view, built on the active organisation's store when it has none, and — for a
    /// tab rebuilt after a relaunch, an eviction or a data clear — restored from its saved state,
    /// else loaded from its address. A restored tab's waiting `.load` is skipped: the restore
    /// already shows that page, with its ‹ › history.
    /// Nil while the organisation's store is being cleared (`beginClear`): the page area is blank
    /// until the clear is done and the pane draws again.
    func page(scope: LayoutScope, pane: String, tab: BrowserTab) -> BrowserWebView? {
        let key = Key(scope: scope, pane: pane, tab: tab.id)
        if let view = views[key] {
            touch(key)
            return view
        }
        // The place's own organisation, read now and never kept — not the context's, which a
        // switch names before the canvas drawn is swapped (`WindowModel.browserOrgFiles(for:)`).
        let files = model?.browserOrgFiles(for: scope)
        if !clearing.isEmpty, let id = try? files?.identifier(), clearing.contains(id) { return nil }
        return webView(scope: scope, pane: pane, tab: tab.id) {
            let view = BrowserWebView(frame: .zero, configuration: Self.configuration(files: files))
            prepare(view)
            let delegate = BrowserTabDelegate(host: self, scope: scope, pane: pane, tab: tab.id, files: files)
            delegate.attach(to: view)
            delegates[key] = delegate
            let waiting = tab.command.map { $0.seq > applied[key] ?? 0 } ?? false
            if restore(view, scope: scope, pane: pane, tab: tab.id, files: files) {
                if waiting, let command = tab.command, case .load = command.verb { applied[key] = command.seq }
            } else if !tab.url.isEmpty, !waiting {
                // Rebuilt with no state to restore: its address is all it kept.
                delegate.requested = tab.url
                if let url = URL(string: tab.url) { view.load(URLRequest(url: url)) }
            }
            return view
        }
    }

    /// A new tab's configuration: the organisation's own store (`WKWebsiteDataStore(forIdentifier:)`),
    /// Safari's user agent, and a page may open a window (a tab) itself — said here rather than left
    /// to WebKit's macOS default. With no organisation, or a profile that cannot be read, an ephemeral
    /// store: a page then keeps nothing, and shares nothing with any organisation.
    private static func configuration(files: BrowserOrgFiles?) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let id = try? files?.identifier() {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        } else {
            configuration.websiteDataStore = .nonPersistent()
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return configuration
    }

    private func prepare(_ view: BrowserWebView) {
        view.isInspectable = true
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = false
        // The page's own element, so a focus read names it (`BrowserPane` names its container too).
        view.setAccessibilityIdentifier("browser.page")
    }

    /// A pop-up's web view, on the configuration WebKit gave (so `window.opener` works and the
    /// pop-up's `window.close()` reaches its tab).
    ///
    /// **Filed at once, under the id the store will give it** — the pane's `nextTab`, `t<n>` — so the
    /// pane can never make a second web view for that tab while the seam is awaited; a view made
    /// under that key in the meantime is replaced by this one. Should the store answer another id
    /// (the cell read was behind), the view moves to it; no id, and it is dropped.
    func adoptPopup(configuration: WKWebViewConfiguration, scope: LayoutScope, pane: String, opener: String,
                    files: BrowserOrgFiles?, url: String) -> BrowserWebView {
        let view = BrowserWebView(frame: .zero, configuration: configuration)
        prepare(view)
        let delegate = BrowserTabDelegate(host: self, scope: scope, pane: pane, tab: "", files: files)
        delegate.requested = url
        delegate.attach(to: view)
        // Filed early only on screen, where the window's cell is this place's (an off-screen pop-up
        // is refused before here, and its cell would be another place's).
        let onScreen = model?.browserScope == scope
        let expected = "t\(model?.browser(pane)?.nextTab ?? 1)"
        let predicted = Key(scope: scope, pane: pane, tab: expected)
        let filedEarly = onScreen && file(view, delegate, under: predicted, placeholder: true)
        Task { [weak self] in
            guard let self else { return }
            let id = await self.model?.browserPageOpenedTab(scope: scope, pane: pane, opener: opener, url: url)
            if filedEarly, self.views[predicted] === view { self.unfile(predicted) }
            guard let id else {
                delegate.detach()
                view.stopLoading()
                return
            }
            let key = Key(scope: scope, pane: pane, tab: id)
            // A real view already under the store's id is never replaced; this pop-up's then goes.
            guard self.file(view, delegate, under: key, placeholder: false) else {
                delegate.detach()
                view.stopLoading()
                return
            }
            delegate.tab = id
            delegate.scheduleReport()
        }
        return view
    }

    /// Puts `view` under `key`. Another view there is replaced only when it is a pop-up's
    /// placeholder (`pendingPopups`); a real tab's view, with its seq and marks, is never taken over.
    /// Answers whether it filed.
    private func file(_ view: BrowserWebView, _ delegate: BrowserTabDelegate, under key: Key, placeholder: Bool) -> Bool {
        if let other = views[key], other !== view {
            guard pendingPopups.contains(key) else { return false }
            unfile(key)   // that pop-up's own adoption files it again once its tab is named
        }
        views[key] = view
        delegates[key] = delegate
        openedByPage.insert(key)
        if placeholder { pendingPopups.insert(key) } else { pendingPopups.remove(key) }
        touch(key)
        evictBeyondLimit(keeping: key)
        return true
    }

    /// Takes a pop-up's view back off a key it was filed under early, leaving the view alive.
    private func unfile(_ key: Key) {
        views[key] = nil
        delegates[key] = nil
        recency.removeAll { $0 == key }
        openedByPage.remove(key)
        pendingPopups.remove(key)
    }

    // MARK: Commands

    /// Applies `command` to the tab's web view when its seq is above the last one applied, and
    /// answers whether it did. `.focusAddress` is the pane's to act on; it is only marked here.
    @discardableResult
    func apply(_ command: BrowserCommand, scope: LayoutScope, pane: String, tab: BrowserTab) -> Bool {
        let key = Key(scope: scope, pane: pane, tab: tab.id)
        guard command.seq > applied[key] ?? 0 else { return false }
        if case .focusAddress = command.verb {
            applied[key] = command.seq
            return true
        }
        // Held while the store is cleared: the command waits, and applies on the rebuild.
        guard let view = page(scope: scope, pane: pane, tab: tab) else { return false }
        // `page` may have restored the tab and so already counted its load.
        guard command.seq > applied[key] ?? 0 else { return false }
        applied[key] = command.seq
        let delegate = delegates[key]
        switch command.verb {
        case .load(let address):
            delegate?.requested = address
            if let url = URL(string: address) { view.load(URLRequest(url: url)) }
        case .back: view.goBack()
        case .forward: view.goForward()
        case .reload:
            // A page that failed has nothing to reload: Try Again asks for the address again.
            if delegate?.failure != nil, let address = delegate?.requested, let url = URL(string: address) {
                view.load(URLRequest(url: url))
            } else {
                view.reload()
            }
        case .stop: view.stopLoading()
        case .zoom(let factor): view.pageZoom = factor
        case .focusAddress: break
        }
        return true
    }

    /// A place's pane is on screen again: each of its live web views reports, since what they said
    /// while the place was off screen was dropped.
    func reportAll(scope: LayoutScope, pane: String) {
        for (key, delegate) in delegates where key.scope == scope && key.pane == pane { delegate.scheduleReport() }
    }

    // MARK: Keyboard

    /// The page takes the keyboard. A web view made this turn may not be in the window yet; it is
    /// waited for, twenty tries a frame apart, as the editor's does.
    func focusPage(scope: LayoutScope, pane: String, tab: String, tries: Int = 20) {
        guard let view = existing(scope: scope, pane: pane, tab: tab) else { return }
        guard let window = view.window else {
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusPage(scope: scope, pane: pane, tab: tab, tries: tries - 1)
            }
            return
        }
        window.makeFirstResponder(view)
    }

    /// The pane gives the keyboard up when one of its web views holds it.
    func resignKeyboard(scope: LayoutScope, pane: String) {
        for (key, view) in views where key.scope == scope && key.pane == pane {
            guard let window = view.window, let responder = window.firstResponder as? NSView else { continue }
            if responder === view || responder.isDescendant(of: view) {
                window.makeFirstResponder(nil)
                return
            }
        }
    }

    // MARK: State

    /// The tab's state file: named by its place as well as its ids (`BrowserOrgFiles.stateKey`).
    private func stateURL(_ files: BrowserOrgFiles, scope: LayoutScope, pane: String, tab: String) -> URL {
        files.stateURL(tab: BrowserOrgFiles.stateKey(scope: scope, pane: pane, tab: tab))
    }

    /// Writes the tab's `interactionState` (its ‹ › history and scroll).
    func saveState(of view: WKWebView, scope: LayoutScope, pane: String, tab: String, files: BrowserOrgFiles?) {
        guard !tab.isEmpty, let files, let state = view.interactionState as? Data else { return }
        let url = stateURL(files, scope: scope, pane: pane, tab: tab)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? state.write(to: url, options: .atomic)
    }

    /// Restores the tab's saved state into a new web view; true when it put a page back.
    private func restore(_ view: WKWebView, scope: LayoutScope, pane: String, tab: String, files: BrowserOrgFiles?) -> Bool {
        guard let files, let data = try? Data(contentsOf: stateURL(files, scope: scope, pane: pane, tab: tab))
        else { return false }
        view.interactionState = data
        return view.backForwardList.currentItem != nil
    }

    /// The page's own `link rel=icon`, read in an isolated world after it loads, kept only when it
    /// is a `data:` URL — decoded here, never fetched. Any other icon is drawn as a globe.
    func readFavicon(of view: WKWebView, scope: LayoutScope, pane: String, tab: String) {
        guard !tab.isEmpty else { return }
        let key = Key(scope: scope, pane: pane, tab: tab)
        let script = "(() => { const l = document.querySelector('link[rel~=\"icon\" i]'); return l ? l.href : ''; })()"
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let href = (try? result.get()) as? String
                self.favicons[key] = href.flatMap(browserDataIcon)
            }
        }
    }

    // MARK: Release

    /// How a web view leaves the host.
    private enum Release {
        /// Evicted for room: its state is saved and its applied seq kept, so it rebuilds as it was.
        case evict
        /// Its store is being deleted: nothing saved (the data is going), applied seq kept, so the
        /// rebuild loads the tab's address and repeats no ‹ › or reload.
        case discard
        /// Its tab is gone: nothing kept.
        case forget
    }

    /// A closed tab: its web view and its saved state go. A later tab never inherits them.
    func release(scope: LayoutScope, pane: String, tab: String) {
        let key = Key(scope: scope, pane: pane, tab: tab)
        let files = delegates[key]?.files
            ?? model?.browserHome.flatMap { try? BrowserOrgFiles(home: $0, org: scope.organization) }
        drop(key, mode: .forget)
        files.map { try? FileManager.default.removeItem(at: stateURL($0, scope: scope, pane: pane, tab: tab)) }
    }

    /// A closed pane: every one of its tabs, the evicted ones' seqs and state files too.
    func release(scope: LayoutScope, pane: String) {
        let tabs = Set(views.keys).union(applied.keys).filter { $0.scope == scope && $0.pane == pane }
        for key in tabs { release(scope: scope, pane: pane, tab: key.tab) }
    }

    /// A data clear begins: every web view on the store `identifier` goes — WebKit refuses to remove
    /// a store a live web view still uses — and none is built on it until `endClear`. Their applied
    /// seqs are kept, so the rebuild repeats no ‹ › or reload.
    func beginClear(onStore identifier: UUID) {
        clearing.insert(identifier)
        for (key, view) in views where view.configuration.websiteDataStore.identifier == identifier {
            drop(key, mode: .discard)
        }
    }

    /// The clear is done — the files deleted, then the store (or its removal failed): the panes
    /// draw again (`rebuilds`), and each shown tab rebuilds on the store and loads its address.
    func endClear(onStore identifier: UUID) {
        clearing.remove(identifier)
        rebuilds += 1
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictBeyondLimit(keeping kept: Key) {
        while views.count > Self.limit, let oldest = recency.first(where: { $0 != kept }) {
            drop(oldest, mode: .evict)
        }
    }

    private func drop(_ key: Key, mode: Release) {
        let view = views.removeValue(forKey: key)
        let delegate = delegates.removeValue(forKey: key)
        recency.removeAll { $0 == key }
        if let view {
            if mode == .evict { saveState(of: view, scope: key.scope, pane: key.pane, tab: key.tab, files: delegate?.files) }
            delegate?.detach()
            view.stopLoading()
            view.removeFromSuperview()
        }
        if mode == .forget {
            applied[key] = nil
            openedByPage.remove(key)
            favicons[key] = nil
        }
    }
}

/// The image in a `data:` URL (`data:[<type>][;base64],<payload>`), at most 64 KB of it; nil for
/// any other URL, or one that does not decode to an image.
func browserDataIcon(_ href: String) -> NSImage? {
    guard href.lowercased().hasPrefix("data:"), href.utf8.count <= 64 * 1024,
          let comma = href.firstIndex(of: ",") else { return nil }
    let header = href[href.index(href.startIndex, offsetBy: 5)..<comma].lowercased()
    let payload = String(href[href.index(after: comma)...])
    let data: Data?
    if header.hasSuffix(";base64") {
        data = Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
    } else {
        data = payload.removingPercentEncoding.map { Data($0.utf8) }
    }
    return data.flatMap(NSImage.init(data:))
}
