import AppKit
import Foundation
import Observation
import WakilKit
import WebKit

/// The window's browser web views (3c-i), one per tab, alive for the window.
///
/// **Held by the window's session, not by a view**, so a tab switch, a layout change or an
/// organisation switch that takes the pane off the canvas never reloads a page: SwiftUI rebuilds
/// the pane and the same web view is put back (`BrowserPageHost`). Keyed by organisation, pane and
/// tab, because two organisations' panes can carry the same ids and must never share a web view —
/// each is built on its own organisation's data store (Invariant 4).
///
/// At most `limit` live web views: the least recently shown is released, its `interactionState`
/// saved first, and rebuilt from that state when its tab is shown again.
@MainActor
@Observable
final class BrowserTabHost {
    struct Key: Hashable {
        let org: String
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
    /// Pop-ups WebKit has been handed a web view for, waiting for the store to name their tab.
    @ObservationIgnored private var pendingPopups: [BrowserTabDelegate: BrowserWebView] = [:]
    /// Tabs a page opened (pop-ups): they arrive without taking the keyboard to the address field.
    @ObservationIgnored private(set) var openedByPage: Set<Key> = []

    /// The icon a page names in its `link rel=icon`, per tab, when it names one.
    private(set) var favicons: [Key: URL] = [:]

    init(model: WindowModel) {
        self.model = model
    }

    // MARK: Web views

    /// The tab's web view if it is live, without making one or touching its recency.
    func existing(org: String, pane: String, tab: String) -> BrowserWebView? {
        views[Key(org: org, pane: pane, tab: tab)]
    }

    /// The tab's web view, made with `make` when it has none; it becomes the most recently used.
    func webView(org: String, pane: String, tab: String, make: () -> BrowserWebView) -> BrowserWebView {
        let key = Key(org: org, pane: pane, tab: tab)
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
    /// tab rebuilt after a relaunch or an eviction — restored from its saved state. A restored tab's
    /// waiting `.load` is skipped: the restore already shows that page, with its ‹ › history.
    func page(org: String, pane: String, tab: BrowserTab) -> BrowserWebView {
        let key = Key(org: org, pane: pane, tab: tab.id)
        if let view = views[key] {
            touch(key)
            return view
        }
        // Read now, never kept: a tab built after an organisation switch must get the new
        // organisation's store (`WindowModel.browserOrgFiles`).
        let files = model?.browserOrgFiles
        return webView(org: org, pane: pane, tab: tab.id) {
            let view = BrowserWebView(frame: .zero, configuration: Self.configuration(files: files))
            prepare(view)
            let delegate = BrowserTabDelegate(host: self, org: org, pane: pane, tab: tab.id, files: files)
            delegate.attach(to: view)
            delegates[key] = delegate
            let waiting = tab.command.map { $0.seq > applied[key] ?? 0 } ?? false
            if restore(view, tab: tab.id, files: files) {
                if waiting, let command = tab.command, case .load = command.verb { applied[key] = command.seq }
            } else if !tab.url.isEmpty, !waiting {
                // Rebuilt after an eviction with no state to restore: its address is all it kept.
                delegate.requested = tab.url
                if let url = URL(string: tab.url) { view.load(URLRequest(url: url)) }
            }
            return view
        }
    }

    /// A new tab's configuration: the organisation's own store (`WKWebsiteDataStore(forIdentifier:)`),
    /// Safari's user agent. With no organisation, or a profile that cannot be read, an ephemeral
    /// store: a page then keeps nothing, and shares nothing with any organisation.
    private static func configuration(files: BrowserOrgFiles?) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let id = try? files?.identifier() {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        } else {
            configuration.websiteDataStore = .nonPersistent()
        }
        return configuration
    }

    private func prepare(_ view: BrowserWebView) {
        view.isInspectable = true
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = false
        // The page's own element, so a focus read names it (`BrowserPane` names its container too).
        view.setAccessibilityIdentifier("browser.page")
    }

    /// A pop-up's web view, on the configuration WebKit gave (so `window.opener` works). It is
    /// returned to WebKit at once; the store names its tab beside the opener, and the web view is
    /// filed under that tab before the pane redraws (the seam runs on the main actor throughout).
    func adoptPopup(configuration: WKWebViewConfiguration, org: String, pane: String, opener: String,
                    files: BrowserOrgFiles?, url: String) -> BrowserWebView {
        let view = BrowserWebView(frame: .zero, configuration: configuration)
        prepare(view)
        let delegate = BrowserTabDelegate(host: self, org: org, pane: pane, tab: "", files: files)
        delegate.requested = url
        delegate.attach(to: view)
        pendingPopups[delegate] = view
        Task { [weak self] in
            guard let self else { return }
            let id = await self.model?.browserPageOpenedTab(pane: pane, opener: opener, url: url)
            self.pendingPopups[delegate] = nil
            guard let id else {
                delegate.detach()
                view.stopLoading()
                return
            }
            let key = Key(org: org, pane: pane, tab: id)
            delegate.tab = id
            self.delegates[key] = delegate
            self.openedByPage.insert(key)
            _ = self.webView(org: org, pane: pane, tab: id) { view }
            delegate.scheduleReport()
        }
        return view
    }

    // MARK: Commands

    /// Applies `command` to the tab's web view when its seq is above the last one applied, and
    /// answers whether it did. `.focusAddress` is the pane's to act on; it is only marked here.
    @discardableResult
    func apply(_ command: BrowserCommand, org: String, pane: String, tab: BrowserTab) -> Bool {
        let key = Key(org: org, pane: pane, tab: tab.id)
        guard command.seq > applied[key] ?? 0 else { return false }
        if case .focusAddress = command.verb {
            applied[key] = command.seq
            return true
        }
        let view = page(org: org, pane: pane, tab: tab)
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

    // MARK: Keyboard

    /// The page takes the keyboard. A web view made this turn may not be in the window yet; it is
    /// waited for, twenty tries a frame apart, as the editor's does.
    func focusPage(org: String, pane: String, tab: String, tries: Int = 20) {
        guard let view = existing(org: org, pane: pane, tab: tab) else { return }
        guard let window = view.window else {
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusPage(org: org, pane: pane, tab: tab, tries: tries - 1)
            }
            return
        }
        window.makeFirstResponder(view)
    }

    /// The pane gives the keyboard up when one of its web views holds it.
    func resignKeyboard(org: String, pane: String) {
        for (key, view) in views where key.org == org && key.pane == pane {
            guard let window = view.window, let responder = window.firstResponder as? NSView else { continue }
            if responder === view || responder.isDescendant(of: view) {
                window.makeFirstResponder(nil)
                return
            }
        }
    }

    // MARK: State

    /// Writes the tab's `interactionState` (its ‹ › history and scroll) to `tabs/<tab>.state`.
    func saveState(of view: WKWebView, tab: String, files: BrowserOrgFiles?) {
        guard !tab.isEmpty, let files, let state = view.interactionState as? Data else { return }
        let url = files.stateURL(tab: tab)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? state.write(to: url, options: .atomic)
    }

    /// Restores the tab's saved state into a new web view; true when it put a page back.
    private func restore(_ view: WKWebView, tab: String, files: BrowserOrgFiles?) -> Bool {
        guard let files, let data = try? Data(contentsOf: files.stateURL(tab: tab)) else { return false }
        view.interactionState = data
        return view.backForwardList.currentItem != nil
    }

    /// The page's own `link rel=icon`, read in an isolated world after it loads. Nothing is
    /// fetched to find it: a page that names none is drawn with a globe.
    func readFavicon(of view: WKWebView, org: String, pane: String, tab: String) {
        guard !tab.isEmpty else { return }
        let key = Key(org: org, pane: pane, tab: tab)
        let script = "(() => { const l = document.querySelector('link[rel~=\"icon\" i]'); return l ? l.href : ''; })()"
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let href = (try? result.get()) as? String
                let url = href.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                if self.favicons[key] != url { self.favicons[key] = url }
            }
        }
    }

    // MARK: Release

    /// A closed tab: its web view and its saved state go. A later tab never inherits them.
    func release(org: String, pane: String, tab: String) {
        let key = Key(org: org, pane: pane, tab: tab)
        let files = delegates[key]?.files ?? model?.browserHome.flatMap { try? BrowserOrgFiles(home: $0, org: org) }
        drop(key, saving: false)
        files?.removeState(tab: tab)
    }

    /// A closed pane: every one of its tabs.
    func release(org: String, pane: String) {
        // Evicted tabs too: they have no web view, but a seq and a state file.
        let tabs = Set(views.keys).union(applied.keys).filter { $0.org == org && $0.pane == pane }
        for key in tabs { release(org: org, pane: pane, tab: key.tab) }
    }

    /// Every web view on the store `identifier`, before that store is deleted: WebKit refuses to
    /// remove a store a live web view still uses. Their tabs rebuild, on a fresh store, when shown.
    func releaseAll(onStore identifier: UUID) {
        for (key, view) in views where view.configuration.websiteDataStore.identifier == identifier {
            drop(key, saving: false)
        }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictBeyondLimit(keeping kept: Key) {
        while views.count > Self.limit, let oldest = recency.first(where: { $0 != kept }) {
            drop(oldest, saving: true)
        }
    }

    private func drop(_ key: Key, saving: Bool) {
        guard let view = views.removeValue(forKey: key) else {
            if !saving { applied[key] = nil }
            return
        }
        let delegate = delegates.removeValue(forKey: key)
        if saving { saveState(of: view, tab: key.tab, files: delegate?.files) }
        delegate?.detach()
        view.stopLoading()
        view.removeFromSuperview()
        recency.removeAll { $0 == key }
        // An evicted tab keeps its applied seq, so its rebuild never repeats a ‹ or a load it
        // already did; only a tab that is gone forgets it.
        if !saving {
            applied[key] = nil
            openedByPage.remove(key)
            favicons[key] = nil
        }
    }
}
