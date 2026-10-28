import AppKit
import CoreServices
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

    /// The icon a page names in its `link rel=icon` (else its `/favicon.ico`), per tab, in memory: a
    /// `data:` one decoded here, an http(s) one fetched with no cookies or credentials
    /// (`BrowserFaviconLoader`).
    private(set) var favicons: [Key: NSImage] = [:]
    /// The network icon each tab last asked for, so a reply for a page it has left is dropped.
    @ObservationIgnored private var faviconSources: [Key: URL] = [:]
    @ObservationIgnored private let faviconLoader = BrowserFaviconLoader()
    /// Raised when live web views were dropped under panes that may be on screen (clearing an
    /// organisation's data), so those panes draw again and rebuild their pages.
    private(set) var rebuilds = 0
    /// Stores being deleted (a data clear): no web view is built on one until the clear is done.
    @ObservationIgnored private var clearing: Set<UUID> = []

    /// The pages' own questions waiting for an answer, oldest first, per tab and place
    /// (`BrowserPrompt`): drawn over that tab's page only. Not store state (spec call 5).
    private(set) var prompts: [Key: [BrowserPrompt]] = [:]
    /// The certificate page's text, per tab whose page's certificate was not trusted.
    private(set) var certificates: [Key: String] = [:]
    /// Tabs whose web content process ended: the crash page is drawn until the tab reloads.
    private(set) var crashed: Set<Key> = []
    /// The operator's sign-in answers, per organisation, host and realm, for the window's life.
    /// Kept here rather than in WebKit's `.forSession` store, which may be process-wide and so
    /// cross organisations (Invariant 4); a later challenge is answered from it.
    @ObservationIgnored private var signIns: [SignInKey: URLCredential] = [:]
    /// Hosts the operator chose Visit Anyway for, per organisation, for the window's life.
    @ObservationIgnored private var certificateAllowed: Set<OrgHost> = []
    /// Camera / microphone answers, per place, host and device, for the window's life.
    @ObservationIgnored private var mediaAnswers: [MediaKey: Bool] = [:]
    /// The system open panel a page's file input raised, per tab, so a dropped view cancels it.
    @ObservationIgnored private var openPanels: [Key: NSOpenPanel] = [:]
    /// Every download this window started, by id; each reports into its own place's pane.
    @ObservationIgnored private var downloads: [String: BrowserDownloadTracker] = [:]
    @ObservationIgnored private var nextDownload = 1
    /// Per pane (`Key` with an empty tab): the find last run, the find wanted next, and whether one
    /// is running — finds run one at a time, the newest wanted next.
    @ObservationIgnored private var findsRun: [Key: FindRun] = [:]
    @ObservationIgnored private var findsWanted: [Key: (BrowserFind?, String?)] = [:]
    @ObservationIgnored private var findsBusy: Set<Key> = []
    /// Places rehomed (`rehome`) whose old name the canvas may still draw for a moment: a pane drawn
    /// under the old name is given the page under the new one, never a fresh one. Let go once the
    /// new name is drawn.
    @ObservationIgnored private var renamed: [LayoutScope: LayoutScope] = [:]
    /// Panes (`Key` with an empty tab) of the drawn place that `rehome` filed under its new name: the
    /// pane drawn under that name is the one already on screen, not an arrival, so it does not take
    /// the keyboard again (Rule 6) — the first turn of a conversation renames the canvas while the
    /// operator is still in the composer. Taken once, by the pane's appearance.
    @ObservationIgnored private var renamedPanes: Set<Key> = []

    struct OrgHost: Hashable {
        let org: String
        let host: String
    }

    struct SignInKey: Hashable {
        let org: String
        let host: String
        let realm: String
    }

    struct MediaKey: Hashable {
        let scope: LayoutScope
        let host: String
        let type: Int
    }

    private struct FindRun {
        let seq: Int
        let query: String
        let tab: String
        var current = 0
        var total = 0
    }

    /// Where Wakil's find script runs: its own world, so the page's script cannot see, call or
    /// spoof it (as the agent's page driver will, 3c-ii).
    static let findWorld = WKContentWorld.world(name: "wakil.find")

    init(model: WindowModel) {
        self.model = model
    }

    // MARK: Web views

    /// The tab's web view if it is live, without making one or touching its recency.
    func existing(scope: LayoutScope, pane: String, tab: String) -> BrowserWebView? {
        views[Key(scope: scope, pane: pane, tab: tab)]
    }

    /// 3c-ii: the tab's live web view for the agent's page driver (`BrowserPageAgent`) — never one
    /// made for it (that would load a page unasked), never a pop-up's placeholder, and its recency
    /// untouched. A place drawn a moment under its old name (`rehome`) answers under the new one.
    func liveView(scope: LayoutScope, pane: String, tab: String) -> BrowserWebView? {
        let key = Key(scope: renamed[scope] ?? scope, pane: pane, tab: tab)
        guard !pendingPopups.contains(key) else { return nil }
        return views[key]
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
        // The canvas still drawn under a place's old name, a moment after `rehome`: its page, or
        // blank — never a second web view under the old name.
        if let moved = renamed[scope] {
            let movedKey = Key(scope: moved, pane: pane, tab: tab.id)
            if views[movedKey] != nil { touch(movedKey) }
            return views[movedKey]
        }
        // The new name is drawn: the old one is let go.
        forgetOldNames(of: scope)
        // The place's own organisation, read now and never kept — not the context's, which a
        // switch names before the canvas drawn is swapped (`WindowModel.browserOrgFiles(for:)`).
        let files = model?.browserOrgFiles(for: scope)
        if !clearing.isEmpty, let id = try? files?.identifier(), clearing.contains(id) { return nil }
        return webView(scope: scope, pane: pane, tab: tab.id) {
            let view = BrowserWebView(frame: .zero, configuration: Self.configuration(files: files))
            prepare(view)
            view.pageZoom = tab.zoom
            let delegate = BrowserTabDelegate(host: self, scope: scope, pane: pane, tab: tab.id, files: files)
            delegate.attach(to: view)
            delegates[key] = delegate
            let waiting = tab.command.map { $0.seq > applied[key] ?? 0 } ?? false
            // Only a tab that had a page before — put back from the saved layout, or evicted and
            // rebuilt — has a state to restore; a new tab never takes one (final review I2).
            let hadPage = tab.fromSavedLayout || applied[key] != nil
            if hadPage, restore(view, scope: scope, pane: pane, tab: tab.id, files: files) {
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
        // 3c-ii: the agent's page script, in its own world, as each main-frame document ends. A
        // pop-up's configuration is WebKit's copy of its opener's, so it carries the script too.
        configuration.userContentController.addUserScript(BrowserAgentScript.userScript())
        // `isInspectable` only lets Safari's Develop menu attach; the page's own right-click
        // **Inspect Element** needs WebKit's developer extras, which have no public setter.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return configuration
    }

    private func prepare(_ view: BrowserWebView) {
        view.isInspectable = true
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = false
        // The page's own element, and the only one with this name: a focus read and a frame
        // read both resolve to it.
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

    // MARK: A place's new name

    /// A place took a new name (a conversation adopted its canvas, or its project or environment was
    /// renamed; `WindowModel.onBrowserRehome`): every page, question, mark, download and find of
    /// `from` is filed under `to`, so the pane drawn under the new name finds its own pages — none
    /// reloads, nothing is stranded off screen. The tab states were moved by the model.
    func rehome(from: LayoutScope, to: LayoutScope) {
        guard from != to else { return }
        func moved(_ key: Key) -> Key { key.scope == from ? Key(scope: to, pane: key.pane, tab: key.tab) : key }
        func move<V>(_ d: [Key: V]) -> [Key: V] { Dictionary(d.map { (moved($0.key), $0.value) }) { new, _ in new } }
        views = move(views)
        delegates = move(delegates)
        recency = recency.map(moved)
        applied = move(applied)
        openedByPage = Set(openedByPage.map(moved))
        pendingPopups = Set(pendingPopups.map(moved))
        favicons = move(favicons)
        faviconSources = move(faviconSources)
        prompts = move(prompts)
        certificates = move(certificates)
        crashed = Set(crashed.map(moved))
        openPanels = move(openPanels)
        findsRun = move(findsRun)
        findsWanted = move(findsWanted)
        // `findsBusy` stays: its running loop reads the old key, ends, and lets it go.
        mediaAnswers = Dictionary(mediaAnswers.map {
            ($0.key.scope == from ? MediaKey(scope: to, host: $0.key.host, type: $0.key.type) : $0.key, $0.value)
        }) { new, _ in new }
        for delegate in delegates.values where delegate.scope == from { delegate.scope = to }
        for tracker in downloads.values where tracker.scope == from { tracker.scope = to }
        renamed = renamed.mapValues { $0 == from ? to : $0 }
        renamed[from] = to
        if let drawn = model?.drawnScope, drawn == from || drawn == to {
            for key in views.keys where key.scope == to { renamedPanes.insert(Key(scope: to, pane: key.pane, tab: "")) }
        }
    }

    /// Whether the pane appearing under `scope` is one `rehome` renamed on screen; answered once.
    func appearsRenamed(scope: LayoutScope, pane: String) -> Bool {
        renamedPanes.remove(Key(scope: scope, pane: pane, tab: "")) != nil
    }

    /// `scope` is drawn under its own name: no pane is drawn under an old name of it any more.
    private func forgetOldNames(of scope: LayoutScope) {
        if renamed.values.contains(scope) { renamed = renamed.filter { $0.value != scope } }
    }

    // MARK: Commands

    /// Applies `command` to the tab's web view when its seq is above the last one applied, and
    /// answers whether it did. `.focusAddress` is the pane's to act on; it is only marked here.
    @discardableResult
    func apply(_ command: BrowserCommand, scope: LayoutScope, pane: String, tab: BrowserTab) -> Bool {
        let key = Key(scope: scope, pane: pane, tab: tab.id)
        // A place's old name, drawn a moment after `rehome`: the pane under the new name applies it.
        guard renamed[scope] == nil else { return false }
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
            crashed.remove(key)
            // A page that failed has nothing to reload: Try Again asks for the address again.
            if delegate?.failure != nil, let address = delegate?.requested, let url = URL(string: address) {
                view.load(URLRequest(url: url))
            } else {
                view.reload()
            }
        case .stop: view.stopLoading()
        case .zoom(let factor):
            // `browser_zoom` changed the store and wrote zoom.json; the page only shows it.
            view.pageZoom = factor
            if let site = view.url.flatMap(BrowserOrgFiles.zoomHost(of:)) { delegate?.zoomHost = site }
        case .focusAddress: break
        case .print:
            // The system's print panel, as a sheet on the window (its own, as the open panel is).
            // A page with no window — its place off screen — prints nothing.
            guard let window = view.window else { break }
            let operation = view.printOperation(with: NSPrintInfo.shared)
            // WKWebView's operation prints blank without its view sized to the page.
            operation.view?.frame = view.bounds
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
        return true
    }

    /// A place's pane is on screen again: each of its live web views reports, since what they said
    /// while the place was off screen was dropped.
    func reportAll(scope: LayoutScope, pane: String) {
        forgetOldNames(of: scope)
        for (key, delegate) in delegates where key.scope == scope && key.pane == pane {
            delegate.reportZoomAgain()
            delegate.scheduleReport()
        }
        // A download keeps running while its place is off screen; what it said then was dropped.
        for tracker in downloads.values where tracker.scope == scope && tracker.pane == pane { tracker.scheduleReport() }
        // So was the find bar's count.
        if let run = findsRun[Key(scope: scope, pane: pane, tab: "")] {
            reportFind(scope: scope, pane: pane, current: run.current, total: run.total)
        }
    }

    // MARK: Keyboard

    /// The page takes the keyboard. A web view made this turn may not be in the window yet; it is
    /// waited for, twenty tries a frame apart, as the editor's does — and before every try the pane
    /// is asked again whether it may still take the keyboard and `tab` is still its active tab
    /// (Rule 6, `browserRetryFocus`); once not, the focus is given up quietly.
    func focusPage(scope: LayoutScope, pane: String, tab: String,
                   mayTakeKeyboard: @escaping @MainActor () -> Bool,
                   activeTab: @escaping @MainActor () -> String?) {
        browserRetryFocus(
            tries: 20,
            stillWanted: { mayTakeKeyboard() && activeTab() == tab },
            attempt: { [weak self] in
                guard let view = self?.existing(scope: scope, pane: pane, tab: tab) else { return true }
                guard let window = view.window else { return false }
                window.makeFirstResponder(view)
                return true
            },
            schedule: { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { next() } })
    }

    /// Whether a page's question arriving in this pane may take the keyboard unasked (Rule 6, final
    /// review I3): yes when the keyboard is on one of the pane's own pages, or on nothing that takes
    /// typing (the window, Wakil's canvas); no while the operator types anywhere else — the composer,
    /// a field, the editor, a terminal, another page — whatever pane the window counts as focused.
    func keyboardIsFreeFor(scope: LayoutScope, pane: String) -> Bool {
        let own = views.filter { $0.key.scope == scope && $0.key.pane == pane }.map(\.value)
        guard let window = own.first(where: { $0.window != nil })?.window ?? NSApp.keyWindow,
              let responder = window.firstResponder as? NSView else { return true }
        if own.contains(where: { responder === $0 || responder.isDescendant(of: $0) }) { return true }
        return !(responder is NSTextInputClient)
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

    /// Writes a live tab's state now — when it leaves the front (a tab switch), say — so the
    /// scroll and the same-document moves since its last load are what a relaunch puts back (I8).
    func saveState(scope: LayoutScope, pane: String, tab: String) {
        let key = Key(scope: scope, pane: pane, tab: tab)
        guard let view = views[key] else { return }
        saveState(of: view, scope: scope, pane: pane, tab: tab, files: delegates[key]?.files)
    }

    /// Every live tab's state, written at quit before the views go (`closeAll`), so each tab comes
    /// back where it was — its scroll and its ‹ › history to the last move (final review I8).
    func saveAll() {
        for (key, view) in views where !pendingPopups.contains(key) {
            saveState(of: view, scope: key.scope, pane: key.pane, tab: key.tab, files: delegates[key]?.files)
        }
    }

    /// Restores the tab's saved state into a new web view; true when it put a page back.
    private func restore(_ view: WKWebView, scope: LayoutScope, pane: String, tab: String, files: BrowserOrgFiles?) -> Bool {
        guard let files, let data = try? Data(contentsOf: stateURL(files, scope: scope, pane: pane, tab: tab))
        else { return false }
        view.interactionState = data
        return view.backForwardList.currentItem != nil
    }

    /// The page's own `link rel=icon` (else `<origin>/favicon.ico`), read in an isolated world after
    /// it loads. A `data:` icon is decoded here; an http(s) one is fetched by `faviconLoader` with no
    /// cookies and no credentials (the page has already contacted that site: see
    /// `BrowserFaviconLoader`). Anything else, or any failure, is drawn as a globe.
    func readFavicon(of view: WKWebView, scope: LayoutScope, pane: String, tab: String) {
        guard !tab.isEmpty else { return }
        let key = Key(scope: scope, pane: pane, tab: tab)
        let script = "(() => { const l = document.querySelector('link[rel~=\"icon\" i]'); return l ? l.href : ''; })()"
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let href = (try? result.get()) as? String
                if let href, BrowserFaviconRules.isData(href) {
                    self.faviconSources[key] = nil
                    self.favicons[key] = browserDataIcon(href)
                    return
                }
                guard let url = BrowserFaviconRules.url(href: href, pageURL: view.url?.absoluteString ?? "") else {
                    self.faviconSources[key] = nil
                    self.favicons[key] = nil
                    return
                }
                self.faviconSources[key] = url
                if let hit = self.faviconLoader.cached(url) {
                    self.favicons[key] = hit
                    return
                }
                // The last page's icon is not this page's while this one's is on its way.
                self.favicons[key] = nil
                Task { @MainActor [weak self] in
                    guard let self, let image = await self.faviconLoader.load(url),
                          self.faviconSources[key] == url else { return }
                    self.favicons[key] = image
                }
            }
        }
    }

    // MARK: The page's questions

    /// A page's question for its tab, drawn over that tab's page until answered. A tab not named
    /// yet (a pop-up waiting for its id) has no page drawn to ask over: the question is dismissed.
    func present(_ prompt: BrowserPrompt, scope: LayoutScope, pane: String, tab: String) {
        guard !tab.isEmpty, views[Key(scope: scope, pane: pane, tab: tab)] != nil else {
            prompt.answer(.withdrawn)
            return
        }
        prompts[Key(scope: scope, pane: pane, tab: tab), default: []].append(prompt)
    }

    /// The operator answered the tab's question: WebKit hears it, and the next one, if any, shows.
    func answer(_ prompt: BrowserPrompt, _ answer: BrowserPrompt.Answer, key: Key) {
        prompts[key]?.removeAll { $0 === prompt }
        if prompts[key]?.isEmpty == true { prompts[key] = nil }
        prompt.answer(answer)
    }

    /// Answers every question the tab's page left open, as Cancel would, and closes its open panel.
    private func dismissPrompts(_ key: Key) {
        let open = prompts.removeValue(forKey: key) ?? []
        open.forEach { $0.answer(.withdrawn) }
        // Its sheet's own handler answers the page (nil: nothing chosen).
        openPanels.removeValue(forKey: key)?.cancel(nil)
    }

    /// A camera / microphone request: answered at once when this place's operator already answered
    /// that host and device this session, else asked over the page and the answer kept.
    func requestMedia(host site: String, type: WKMediaCaptureType, scope: LayoutScope, pane: String, tab: String,
                      decide: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let mediaKey = MediaKey(scope: scope, host: site, type: type.rawValue)
        if let known = mediaAnswers[mediaKey] { return decide(known ? .grant : .deny) }
        let prompt = BrowserPrompt(kind: .media(browserMediaQuestion(host: site, type: type)), origin: site) { [weak self] answer in
            switch answer {
            case .accept:
                self?.mediaAnswers[mediaKey] = true
                decide(.grant)
            case .withdrawn:
                // Its page went before the operator answered: denied, and nothing kept.
                decide(.deny)
            default:
                self?.mediaAnswers[mediaKey] = false
                decide(.deny)
            }
        }
        present(prompt, scope: scope, pane: pane, tab: tab)
    }

    /// A page's file input: the system open panel, as a sheet on the window (the system's own, and
    /// the one window-modal surface the browser raises). A page with no window — its place is off
    /// screen — gets nothing chosen.
    func runOpenPanel(_ parameters: WKOpenPanelParameters, for view: WKWebView, scope: LayoutScope, pane: String,
                      tab: String, completion: @escaping @MainActor ([URL]?) -> Void) {
        let key = Key(scope: scope, pane: pane, tab: tab)
        guard !tab.isEmpty, let window = view.window, openPanels[key] == nil else { return completion(nil) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        openPanels[key] = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if self?.openPanels[key] === panel { self?.openPanels[key] = nil }
                completion(response == .OK ? panel.urls : nil)
            }
        }
    }

    // MARK: Sign-in

    /// The credential the operator gave this organisation, host and realm this session, if any.
    func signIn(for key: SignInKey) -> URLCredential? { signIns[key] }

    func remember(_ credential: URLCredential, for key: SignInKey) { signIns[key] = credential }

    /// The server refused it: the next challenge asks again.
    func forgetSignIn(_ key: SignInKey) { signIns[key] = nil }

    // MARK: Certificate and crash pages

    /// Whether the operator chose Visit Anyway for this organisation and host this session.
    func certificateIsAllowed(org: String, host site: String) -> Bool {
        certificateAllowed.contains(OrgHost(org: org, host: site))
    }

    /// The tab's page was refused for its certificate: the certificate page replaces it.
    func showCertificate(_ text: String, key: Key) {
        certificates[key] = text
    }

    func clearPageMarks(_ key: Key) {
        if certificates[key] != nil { certificates[key] = nil }
        if crashed.contains(key) { crashed.remove(key) }
    }

    /// The operator's Visit Anyway: the host is trusted for this organisation until the window
    /// closes, and the page asked for again. Never an action — the agent cannot reach it.
    func visitAnyway(key: Key) {
        guard let delegate = delegates[key], let view = views[key],
              let address = delegate.requested, let url = URL(string: address), let site = url.host?.lowercased()
        else { return }
        certificateAllowed.insert(OrgHost(org: key.scope.organization, host: site))
        certificates[key] = nil
        view.load(URLRequest(url: url))
    }

    /// The tab's web content process ended: its questions are answered (their page is gone) and
    /// the crash page drawn until the tab reloads.
    func pageCrashed(key: Key) {
        guard views[key] != nil else { return }
        dismissPrompts(key)
        crashed.insert(key)
    }

    // MARK: Downloads

    /// A navigation became a download: tracked under a new id, reporting into its tab's pane.
    func track(_ download: WKDownload, scope: LayoutScope, pane: String) {
        let id = "d\(nextDownload)"
        nextDownload += 1
        let folder = (model?.browserHome ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Downloads", isDirectory: true)
        let tracker = BrowserDownloadTracker(id: id, download: download, scope: scope, pane: pane, folder: folder, host: self)
        downloads[id] = tracker
    }

    /// A download ended and the store holds its final state: its tracker, WKDownload and KVO go.
    func release(download id: String) { downloads[id] = nil }

    /// The pane's list as the store holds it: an ended download no longer in it (cleared with
    /// `browser_downloads_clear`) whose end was reported is let go.
    func prune(_ listed: [BrowserDownload], scope: LayoutScope, pane: String) {
        let ids = Set(listed.map(\.id))
        for (id, tracker) in downloads where tracker.scope == scope && tracker.pane == pane
            && tracker.hasEnded && tracker.hasReported && !ids.contains(id) {
            downloads[id] = nil
        }
    }

    /// The store asked for these downloads to stop (`browser_download_cancel`): each is cancelled,
    /// and reports `.cancelled` once WebKit has stopped it.
    func cancelRequested(_ wanted: [BrowserDownload], scope: LayoutScope, pane: String) {
        for d in wanted where d.cancelRequested && d.state == .running {
            guard let tracker = downloads[d.id], tracker.scope == scope, tracker.pane == pane else { continue }
            tracker.cancel()
        }
    }

    // MARK: Find

    /// The find bar's state for the pane's active tab: run when its `seq` is new or the tab
    /// changed, and its match count reported. Finds run one at a time; a burst (typing) runs the
    /// newest when the one running ends. `nil` — the bar closed — clears the highlight.
    func applyFind(_ find: BrowserFind?, scope: LayoutScope, pane: String, tab: String?) {
        let paneKey = Key(scope: scope, pane: pane, tab: "")
        if let find, let run = findsRun[paneKey], find.seq <= run.seq, run.tab == tab { return }
        if find == nil, findsRun[paneKey] == nil, findsWanted[paneKey] == nil { return }
        findsWanted[paneKey] = (find, tab)
        guard !findsBusy.contains(paneKey) else { return }
        findsBusy.insert(paneKey)
        Task { [weak self] in
            while let self, let wanted = self.findsWanted.removeValue(forKey: paneKey) {
                await self.runFind(wanted.0, tab: wanted.1, paneKey: paneKey)
            }
            self?.findsBusy.remove(paneKey)
        }
    }

    private func runFind(_ find: BrowserFind?, tab: String?, paneKey: Key) async {
        let last = findsRun[paneKey]
        guard let find, let tab, let view = existing(scope: paneKey.scope, pane: paneKey.pane, tab: tab) else {
            if let last, let view = existing(scope: paneKey.scope, pane: paneKey.pane, tab: last.tab) {
                await Self.clearSelection(in: view)
            }
            findsRun[paneKey] = nil
            return
        }
        if let last, find.seq <= last.seq, last.tab == tab { return }
        var run = FindRun(seq: find.seq, query: find.query, tab: tab)
        // A new query (or tab), or a find the store reset (`browser_find`): count, then the first
        // match. Otherwise a step from the match the store last heard of.
        let isNew = last == nil || last?.query != find.query || last?.tab != tab || find.total == 0
        if last?.tab != tab, let last, let old = existing(scope: paneKey.scope, pane: paneKey.pane, tab: last.tab) {
            await Self.clearSelection(in: old)
        }
        if find.query.isEmpty {
            await Self.clearSelection(in: view)
        } else if isNew {
            await Self.clearSelection(in: view)
            run.total = await Self.count(find.query, in: view)
            if run.total > 0, await Self.find(find.query, in: view, backwards: false) { run.current = 1 }
        } else if await Self.find(find.query, in: view, backwards: !find.forward) {
            let total = find.total, at = find.current
            run.total = total
            run.current = find.forward ? at % total + 1 : (at - 2 + total) % total + 1
        } else {
            run.total = await Self.count(find.query, in: view)
        }
        findsRun[paneKey] = run
        reportFind(scope: paneKey.scope, pane: paneKey.pane, current: run.current, total: run.total)
    }

    private func reportFind(scope: LayoutScope, pane: String, current: Int, total: Int) {
        guard let model else { return }
        Task { await model.browserFindDidReport(scope: scope, pane: pane, current: current, total: total) }
    }

    /// The page's matches for `query`, counted by Wakil's script in its own world: what the page
    /// shows as text, case folded as WebKit's find folds it.
    private static func count(_ query: String, in view: WKWebView) async -> Int {
        let body = """
            const q = query.toLowerCase();
            const text = (document.body ? document.body.innerText : '').toLowerCase();
            let n = 0, i = 0;
            while (q && (i = text.indexOf(q, i)) !== -1) { n++; i += q.length; }
            return n;
            """
        return await withCheckedContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: ["query": query], in: nil, in: findWorld) { result in
                let n = ((try? result.get()) as? NSNumber)?.intValue ?? 0
                continuation.resume(returning: n)
            }
        }
    }

    /// WebKit's own find, which selects and scrolls to the match; wraps at either end.
    private static func find(_ query: String, in view: WKWebView, backwards: Bool) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        return await withCheckedContinuation { continuation in
            view.find(query, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
    }

    private static func clearSelection(in view: WKWebView) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.callAsyncJavaScript("document.getSelection()?.removeAllRanges();", arguments: [:], in: nil,
                                     in: findWorld) { _ in continuation.resume() }
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

    /// A closed pane: every one of its tabs, the evicted ones' seqs too, and every state file under
    /// its name — the tabs never shown this launch as well, so a later pane given the same id never
    /// inherits one (final review I2).
    func release(scope: LayoutScope, pane: String) {
        let tabs = Set(views.keys).union(applied.keys).filter { $0.scope == scope && $0.pane == pane }
        for key in tabs { release(scope: scope, pane: pane, tab: key.tab) }
        model?.browserOrgFiles(for: scope)?.removeStates(scope: scope, pane: pane)
        let paneKey = Key(scope: scope, pane: pane, tab: "")
        findsRun[paneKey] = nil
        findsWanted[paneKey] = nil
    }

    /// A data clear begins: every web view on the store `identifier` goes — WebKit refuses to remove
    /// a store a live web view still uses — and none is built on it until `endClear`. Their applied
    /// seqs are kept, so the rebuild repeats no ‹ › or reload.
    func beginClear(onStore identifier: UUID) {
        clearing.insert(identifier)
        // The organisation's sign-ins go with its data.
        if let home = model?.browserHome {
            let orgs = Set(signIns.keys.map(\.org)).filter {
                (try? BrowserOrgFiles(home: home, org: $0).identifier()) == identifier
            }
            signIns = signIns.filter { !orgs.contains($0.key.org) }
        }
        for (key, view) in views where view.configuration.websiteDataStore.identifier == identifier {
            drop(key, mode: .discard)
        }
    }

    /// The window is closing: every page's open question is answered (Cancel) and its open panel
    /// cancelled, and every web view dropped, so no WebKit completion handler is left uncalled.
    /// No state file is deleted; the session writes them first (`saveAll`).
    func closeAll() {
        for key in Array(views.keys) { drop(key, mode: .discard) }
        for key in Array(prompts.keys) { dismissPrompts(key) }
        for key in Array(openPanels.keys) { openPanels.removeValue(forKey: key)?.cancel(nil) }
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
        pendingPopups.remove(key)
        // WebKit asserts on a handler never called: every question the page left open is answered.
        dismissPrompts(key)
        certificates[key] = nil
        crashed.remove(key)
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
            faviconSources[key] = nil
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

/// One download (3c-i): WebKit's `WKDownload`, saved to `~/Downloads` under a name Finder would
/// give, its progress reported into its tab's pane through the seam (`browserDownloadDidChange`),
/// one report in flight at a time, each read when it is sent.
///
/// **The state ends only on WebKit's word**: Cancel asks (`cancel`), and `.cancelled` is reported
/// once WebKit has stopped it. A download keeps running while its place is off screen; what it says
/// then is dropped, and it says it again when the place is shown (`BrowserTabHost.reportAll`).
@MainActor
final class BrowserDownloadTracker: NSObject, WKDownloadDelegate {
    let id: String
    /// Its place; moved by `BrowserTabHost.rehome` when the place takes a new name.
    var scope: LayoutScope
    let pane: String
    private let download: WKDownload
    private let folder: URL
    private weak var host: BrowserTabHost?
    private var filename = ""
    private var destination: URL?
    private var state: BrowserDownload.State = .running
    private var failure: String?
    private var observation: NSKeyValueObservation?
    private var reporting: Task<Void, Never>?
    private var reportAgain = false
    private var cancelling = false
    /// The destination was free when it was chosen: only then is a half-written file there this
    /// download's to delete. A file that was already there is never touched.
    private var reservedFreshPath = false
    private(set) var hasReported = false
    var hasEnded: Bool { state != .running }

    init(id: String, download: WKDownload, scope: LayoutScope, pane: String, folder: URL, host: BrowserTabHost) {
        self.id = id
        self.download = download
        self.scope = scope
        self.pane = pane
        self.folder = folder
        self.host = host
        super.init()
        filename = download.originalRequest?.url?.lastPathComponent ?? "download"
        download.delegate = self
        observation = download.progress.observe(\.completedUnitCount) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleReport() }
        }
    }

    private var snapshot: BrowserDownload {
        let progress = download.progress
        return BrowserDownload(
            id: id, filename: filename, received: max(0, progress.completedUnitCount),
            expected: progress.totalUnitCount, state: state,
            path: state == .finished ? destination?.path : nil, failure: failure)
    }

    func scheduleReport() {
        reportAgain = true
        guard reporting == nil else { return }
        reporting = Task { [weak self] in
            while let self, self.reportAgain {
                self.reportAgain = false
                guard let model = self.host?.model else { break }
                let sent = self.snapshot
                await model.browserDownloadDidChange(scope: self.scope, pane: self.pane, sent)
                self.hasReported = true
                // Ended, and the store on screen holds that end (not dropped as another place's):
                // nothing more to say, so the tracker goes. Dropped, it waits for `reportAll`.
                if sent.state != .running, !self.reportAgain, model.browserScope == self.scope,
                   model.browser(self.pane)?.downloads.first(where: { $0.id == self.id })?.state == sent.state {
                    self.host?.release(download: self.id)
                }
            }
            self?.reporting = nil
        }
    }

    /// Cancel was asked: WebKit stops it, then it reports `.cancelled`. Asked once, however many
    /// times the store's ask is seen.
    func cancel() {
        guard state == .running, !cancelling else { return }
        cancelling = true
        download.cancel { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.cancelled, failure: nil) }
        }
    }

    private func end(_ final: BrowserDownload.State, failure: String?) {
        guard state == .running else { return }
        state = final
        self.failure = failure
        observation?.invalidate()
        observation = nil
        // What a stopped download wrote is not the file: it goes, so `~/Downloads` holds no half file —
        // only when this download reserved that path free, and what is there is no larger than it wrote.
        if final != .finished, reservedFreshPath, let destination, writtenByThisDownload(destination) {
            try? FileManager.default.removeItem(at: destination)
        }
        scheduleReport()
    }

    private func writtenByThisDownload(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return false }
        return size.int64Value <= max(0, download.progress.completedUnitCount)
    }

    /// Gatekeeper must see a web download as one (Ruling): `com.apple.quarantine`, agent Wakil,
    /// type web download, and the address it came from. What WebKit already put there is kept;
    /// these three keys are Wakil's.
    private func quarantine(_ url: URL) throws {
        var target = url
        var properties = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties ?? [:]
        properties[kLSQuarantineAgentNameKey as String] = "Wakil"
        properties[kLSQuarantineTypeKey as String] = kLSQuarantineTypeWebDownload as String
        if let source = download.originalRequest?.url {
            properties[kLSQuarantineDataURLKey as String] = source.absoluteString
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        try target.setResourceValues(values)
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = browserDownloadDestination(in: folder, suggested: suggestedFilename) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        filename = url.lastPathComponent
        destination = url
        reservedFreshPath = !FileManager.default.fileExists(atPath: url.path)
        completionHandler(url)
        scheduleReport()
    }

    func downloadDidFinish(_ download: WKDownload) {
        // A file Gatekeeper cannot tell came from the web is not kept.
        if let destination {
            do {
                try quarantine(destination)
            } catch {
                return end(.failed, failure: "Couldn't mark it as downloaded from the web — \(error.localizedDescription)")
            }
        }
        end(.finished, failure: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
            end(.cancelled, failure: nil)
        } else {
            end(.failed, failure: ns.localizedDescription)
        }
    }
}
