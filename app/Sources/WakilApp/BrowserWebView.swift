import AppKit
import Foundation
import WakilKit
import WebKit

/// One browser tab's web view (3c-i).
///
/// **The always-Wakil keys reach the window first.** A focused `WKWebView` takes every key
/// equivalent for the page and hands back only what the page left alone, so ⌘K pressed on a page
/// that listens for it would never open the palette. These keys are offered to the main menu
/// before the page sees them; every other key is the page's, as Safari does it.
final class BrowserWebView: WKWebView {
    /// Esc while the page loads: the tab's `browser_stop` (Rule 4). Answers whether it was used.
    var stopOnEscape: (@MainActor () -> Bool)?

    /// ⌘K, ⌘P, ⌘N, ⌘T, ⌘W, ⌘L, ⌘1–9, ⌘, and ⌘⇧W (global constraints), **by physical key**
    /// (`kVK_ANSI_*`), so they are Wakil's on every keyboard layout — a character match fails on a
    /// non-Latin one (`QueryLineKeys`' note).
    static func isWakilKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command { return commandKeys.contains(event.keyCode) }
        if mods == [.command, .shift] { return event.keyCode == 13 }   // W
        return false
    }

    /// K P N T W L , D and 1–9.
    private static let commandKeys: Set<UInt16> = [40, 35, 45, 17, 13, 37, 43, 2, 18, 19, 20, 21, 23, 22, 26, 28, 25]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isWakilKey(event), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// When the operator last pressed a key, clicked or scrolled in this page (3c-ii): the agent's
    /// acts wait until it is a quiet second old (`browserIdleWait`), so none lands under their hands.
    private(set) var lastOperatorInput: Date?

    /// While the agent acts in this page (3c-ii), the page cannot take the keyboard (Rule 6).
    ///
    /// A script's `element.focus()` — Wakil's own in its `wakil.agent` world as much as the page's —
    /// makes WebKit's web process ask the window to make this view first responder
    /// (`Widget::setFocus` → `WebPageProxy::MakeFirstResponder`), which ends the operator's editing in
    /// the composer and sends their next keys to the page. WebKit's one switch for that request is
    /// `_setShouldSuppressFirstResponderChanges:`, which drops it and leaves the element focused in
    /// the page, so the act still types where it aimed. The operator's own click still takes the
    /// keyboard: AppKit gives it on the mouse-down, not through that request.
    ///
    /// Counted, so two acts in one page overlap safely; the switch is off again when the last ends.
    private var agentActs = 0
    private static let suppressSelector = NSSelectorFromString("_setShouldSuppressFirstResponderChanges:")

    func agentActBegan() {
        agentActs += 1
        if agentActs == 1 { suppressFirstResponderChanges(true) }
    }

    func agentActEnded() {
        guard agentActs > 0 else { return }
        agentActs -= 1
        if agentActs == 0 { suppressFirstResponderChanges(false) }
    }

    private func suppressFirstResponderChanges(_ on: Bool) {
        let selector = Self.suppressSelector
        guard responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: selector), to: Setter.self)(self, selector, on)
    }

    override func mouseDown(with event: NSEvent) {
        lastOperatorInput = Date()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        lastOperatorInput = Date()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        lastOperatorInput = Date()
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, mods.isEmpty, isLoading, stopOnEscape?() == true { return }
        super.keyDown(with: event)
    }
}

/// What a web view's failure reads as (global constraints' copy):
/// `Couldn't reach <host> — <localizedDescription> (<NSURLError code name>)`. Nil for the failures
/// that are not failures to the operator: a load replaced by another, or turned into a download.
func browserLoadFailure(_ error: Error, url: URL?) -> String? {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return nil }
    // WebKitErrorFrameLoadInterruptedByPolicyChange: the response became a download.
    if ns.domain == "WebKitErrorDomain", ns.code == 102 { return nil }
    let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
    let host = failing.map(BrowserAddress.displayHost) ?? "the page"
    let code = ns.domain == NSURLErrorDomain
        ? (urlErrorNames[ns.code] ?? "NSURLError \(ns.code)") : "\(ns.domain) \(ns.code)"
    return "Couldn't reach \(host) — \(ns.localizedDescription) (\(code))"
}

private let urlErrorNames: [Int: String] = [
    NSURLErrorUnknown: "NSURLErrorUnknown",
    NSURLErrorBadURL: "NSURLErrorBadURL",
    NSURLErrorTimedOut: "NSURLErrorTimedOut",
    NSURLErrorUnsupportedURL: "NSURLErrorUnsupportedURL",
    NSURLErrorCannotFindHost: "NSURLErrorCannotFindHost",
    NSURLErrorCannotConnectToHost: "NSURLErrorCannotConnectToHost",
    NSURLErrorNetworkConnectionLost: "NSURLErrorNetworkConnectionLost",
    NSURLErrorDNSLookupFailed: "NSURLErrorDNSLookupFailed",
    NSURLErrorHTTPTooManyRedirects: "NSURLErrorHTTPTooManyRedirects",
    NSURLErrorResourceUnavailable: "NSURLErrorResourceUnavailable",
    NSURLErrorNotConnectedToInternet: "NSURLErrorNotConnectedToInternet",
    NSURLErrorRedirectToNonExistentLocation: "NSURLErrorRedirectToNonExistentLocation",
    NSURLErrorBadServerResponse: "NSURLErrorBadServerResponse",
    NSURLErrorUserCancelledAuthentication: "NSURLErrorUserCancelledAuthentication",
    NSURLErrorUserAuthenticationRequired: "NSURLErrorUserAuthenticationRequired",
    NSURLErrorZeroByteResource: "NSURLErrorZeroByteResource",
    NSURLErrorCannotDecodeRawData: "NSURLErrorCannotDecodeRawData",
    NSURLErrorCannotDecodeContentData: "NSURLErrorCannotDecodeContentData",
    NSURLErrorCannotParseResponse: "NSURLErrorCannotParseResponse",
    NSURLErrorAppTransportSecurityRequiresSecureConnection: "NSURLErrorAppTransportSecurityRequiresSecureConnection",
    NSURLErrorFileDoesNotExist: "NSURLErrorFileDoesNotExist",
    NSURLErrorFileIsDirectory: "NSURLErrorFileIsDirectory",
    NSURLErrorNoPermissionsToReadFile: "NSURLErrorNoPermissionsToReadFile",
    NSURLErrorDataLengthExceedsMaximum: "NSURLErrorDataLengthExceedsMaximum",
    NSURLErrorSecureConnectionFailed: "NSURLErrorSecureConnectionFailed",
    NSURLErrorServerCertificateHasBadDate: "NSURLErrorServerCertificateHasBadDate",
    NSURLErrorServerCertificateUntrusted: "NSURLErrorServerCertificateUntrusted",
    NSURLErrorServerCertificateHasUnknownRoot: "NSURLErrorServerCertificateHasUnknownRoot",
    NSURLErrorServerCertificateNotYetValid: "NSURLErrorServerCertificateNotYetValid",
    NSURLErrorClientCertificateRejected: "NSURLErrorClientCertificateRejected",
    NSURLErrorClientCertificateRequired: "NSURLErrorClientCertificateRequired",
    NSURLErrorCannotLoadFromNetwork: "NSURLErrorCannotLoadFromNetwork",
]

/// One tab's navigation and UI delegate: everything its web view tells Wakil goes through the
/// window's seam (`WindowModel.browserPageDidReport` and its neighbours), never through the store.
@MainActor
final class BrowserTabDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var host: BrowserTabHost?
    /// The place this tab's web view belongs to: every seam call carries it, and the window drops
    /// those whose place is not on screen (pane and tab ids repeat from place to place). Moved by
    /// `BrowserTabHost.rehome` when the place takes a new name.
    var scope: LayoutScope
    let pane: String
    /// Empty while a pop-up waits for the store to name its tab (`BrowserTabHost.adoptPopup`).
    var tab: String
    /// The organisation's files, for the tab's state; never the store's id (Invariant 4).
    let files: BrowserOrgFiles?
    /// The address last asked for, which a failed first load has no `url` to report.
    var requested: String?
    private(set) var failure: String?
    /// Whether a load has ended here, finished or failed (3c-ii): a read waits for the page to
    /// arrive, and a first load that failed leaves no `url` — this says the wait is over anyway.
    private(set) var loadEnded = false
    /// The host whose remembered zoom the page took (`zoom.json`); a page arriving on another host
    /// takes that one's.
    var zoomHost: String?
    /// The zoom the next report tells the store: set only when the page took a host's zoom, so a
    /// report read before a `browser_zoom` applied never undoes it.
    private var pendingZoom: Double?
    private var observations: [NSKeyValueObservation] = []
    private var reporting: Task<Void, Never>?
    private var reportAgain = false

    init(host: BrowserTabHost, scope: LayoutScope, pane: String, tab: String, files: BrowserOrgFiles?) {
        self.host = host
        self.scope = scope
        self.pane = pane
        self.tab = tab
        self.files = files
    }

    /// Wires the delegates and watches the six properties a report carries.
    func attach(to webView: BrowserWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let report: @Sendable (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReport() }
        }
        observations = [
            webView.observe(\.url) { view, _ in report(view) },
            webView.observe(\.title) { view, _ in report(view) },
            webView.observe(\.estimatedProgress) { view, _ in report(view) },
            webView.observe(\.canGoBack) { view, _ in report(view) },
            webView.observe(\.canGoForward) { view, _ in report(view) },
            webView.observe(\.isLoading) { view, _ in report(view) },
        ]
        webView.stopOnEscape = { [weak self] in
            guard let self, !self.tab.isEmpty, self.isShown else { return false }
            self.dispatch("browser_stop")
            return true
        }
    }

    func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        reporting?.cancel()
    }

    private var key: BrowserTabHost.Key { BrowserTabHost.Key(scope: scope, pane: pane, tab: tab) }

    /// The place is shown again: the zoom the page took is said again, with the rest of its report.
    func reportZoomAgain() {
        guard zoomHost != nil, let view = host?.existing(scope: scope, pane: pane, tab: tab) else { return }
        pendingZoom = view.pageZoom
    }

    /// Whether this tab's place is the one on screen, which is the only place its ids mean this tab.
    var isShown: Bool { host?.model?.browserScope == scope }

    private func dispatch(_ action: String, _ extra: [String: JSONValue] = [:]) {
        guard let model = host?.model, !tab.isEmpty, isShown else { return }
        var params = extra
        params["pane"] = .string(pane)
        params["tab"] = .string(tab)
        Task { await model.dispatchFromSurface(action, .object(params)) }
    }

    /// One report in flight at a time, each read from the web view when it is sent, so a burst of
    /// changes lands as the newest state and never out of order.
    func scheduleReport() {
        reportAgain = true
        guard reporting == nil else { return }
        reporting = Task { [weak self] in
            while let self, self.reportAgain, !Task.isCancelled {
                self.reportAgain = false
                guard let model = self.host?.model, !self.tab.isEmpty,
                      let view = self.host?.existing(scope: self.scope, pane: self.pane, tab: self.tab) else { break }
                let zoom = self.pendingZoom
                self.pendingZoom = nil
                let report = BrowserPageReport(
                    // A failed load reads as the address that failed, not the page left showing.
                    url: (self.failure != nil ? self.requested : nil) ?? view.url?.absoluteString
                        ?? self.requested ?? "",
                    title: view.title ?? "",
                    isLoading: view.isLoading, progress: view.estimatedProgress,
                    canGoBack: view.canGoBack, canGoForward: view.canGoForward, failure: self.failure, zoom: zoom)
                await model.browserPageDidReport(scope: self.scope, pane: self.pane, tab: self.tab, report)
            }
            self?.reporting = nil
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
        if !tab.isEmpty { host?.clearPageMarks(key) }
        // A link, ‹ › or a redirect is the address now: what a failure names, and Try Again asks for.
        if let url = webView.url?.absoluteString { requested = url }
        scheduleReport()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
        // 3d-iv: the old document's login field is gone with it; a sent form's bar stays.
        if !tab.isEmpty {
            host?.passwordPageCommitted(key, site: webView.url.flatMap { BrowserPasswords.siteKey($0.absoluteString) })
        }
        host?.saveState(of: webView, scope: scope, pane: pane, tab: tab, files: files)
        // A page on another host takes that host's remembered zoom, and the store hears it.
        if let site = webView.url.flatMap(BrowserOrgFiles.zoomHost(of:)), site != zoomHost {
            zoomHost = site
            let factor = files?.zoom(host: site) ?? 1.0
            if webView.pageZoom != factor { webView.pageZoom = factor }
            pendingZoom = factor
        }
        scheduleReport()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadEnded = true
        // Again once loaded (I8): the state at commit holds the page as it began, not as it ended.
        host?.saveState(of: webView, scope: scope, pane: pane, tab: tab, files: files)
        scheduleReport()
        host?.readFavicon(of: webView, scope: scope, pane: pane, tab: tab)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error, webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error, webView)
    }

    private func failed(_ error: Error, _ webView: WKWebView) {
        loadEnded = true
        // A refused certificate shows its own page, not the load error under it.
        if !tab.isEmpty, host?.certificates[key] != nil {
            scheduleReport()
            return
        }
        guard let text = browserLoadFailure(error, url: requested.flatMap(URL.init(string:)) ?? webView.url) else {
            scheduleReport()
            return
        }
        failure = text
        scheduleReport()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A link with `download`: saved, not shown.
        if navigationAction.shouldPerformDownload { return decisionHandler(.download) }
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        // Rule 7: a scheme a page cannot show is an app's (`mailto:` is Mail's) — **asked in place
        // first, never opened unasked** (final review I4, as Safari asks). Only the page itself
        // asks; a frame inside it (`<iframe src="zoommtg:…">`) opens nothing.
        if !BrowserAddress.opensInPage(url) {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false { askToOpen(url, webView) }
            return
        }
        if navigationAction.navigationType == .linkActivated, opensInBackground(navigationAction) {
            openInBackground(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    /// A response the page cannot show, or one the server says is an attachment, is a download.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        host?.track(download, scope: scope, pane: pane)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        host?.track(download, scope: scope, pane: pane)
    }

    /// Server trust and HTTP sign-in. A certificate the system does not trust is refused and the
    /// certificate page shown, unless the operator chose Visit Anyway for this organisation and
    /// host this session. Basic and digest sign-in is asked over the page; the credential is the
    /// system's, kept for the session (`.forSession`). Anything else is WebKit's default.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let site = space.host.lowercased()
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
            // Evaluated off the main thread (it may reach the network); answered back on it.
            SecTrustEvaluateAsyncWithError(trust, .main) { [weak self] trust, trusted, error in
                MainActor.assumeIsolated {
                    guard let self, !trusted else { return completionHandler(.performDefaultHandling, nil) }
                    if self.host?.certificateIsAllowed(org: self.scope.organization, host: site) == true {
                        return completionHandler(.useCredential, URLCredential(trust: trust))
                    }
                    // Only the page's own host gets the page; another host's resource is refused quietly.
                    let pageHost = (self.requested.flatMap(URL.init(string:)) ?? webView.url)?.host?.lowercased()
                    if !self.tab.isEmpty, pageHost == site {
                        let reason = error.map { ($0 as Error).localizedDescription } ?? "the system does not trust it"
                        self.host?.showCertificate("\(site)'s certificate isn't trusted — \(reason)", key: self.key)
                    }
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            guard let host, !tab.isEmpty else { return completionHandler(.cancelAuthenticationChallenge, nil) }
            // Answered from the host's own memory of this organisation's sign-ins, never WebKit's
            // `.forSession` store, which may be shared by every organisation (Invariant 4).
            let signInKey = BrowserTabHost.SignInKey(org: scope.organization, host: site, realm: space.realm ?? "")
            if let known = host.signIn(for: signInKey) {
                if challenge.previousFailureCount == 0 { return completionHandler(.useCredential, known) }
                host.forgetSignIn(signInKey)   // refused: asked again
            }
            let prompt = BrowserPrompt(kind: .signIn(host: site, realm: space.realm ?? ""), origin: site) { [weak host] answer in
                if case .credential(let user, let password) = answer {
                    let credential = URLCredential(user: user, password: password, persistence: .none)
                    host?.remember(credential, for: signInKey)
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
            host.present(prompt, scope: scope, pane: pane, tab: tab)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// The page's process ended: the crash page, until the tab reloads.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !tab.isEmpty else { return }
        host?.pageCrashed(key: key)
        scheduleReport()
    }

    /// `Open in <app>?` over the page, with Open · Cancel; Open hands the link to the Mac. One such
    /// question per tab at a time — a page asking again while one waits is not asked twice. With no
    /// app for the scheme, the tab says so.
    private func askToOpen(_ url: URL, _ webView: WKWebView) {
        guard let host, !tab.isEmpty else { return }
        if host.prompts[key]?.contains(where: { if case .openApp = $0.kind { true } else { false } }) == true { return }
        let origin = webView.url.map(BrowserAddress.displayHost) ?? "This page"
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            let line = BrowserAddress.noAppLine(scheme: url.scheme?.lowercased() ?? "")
            return host.present(BrowserPrompt(kind: .alert(line), origin: origin) { _ in }, scope: scope, pane: pane, tab: tab)
        }
        let bundle = Bundle(url: app)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let prompt = BrowserPrompt(kind: .openApp(BrowserAddress.openInAppQuestion(app: name)), origin: origin) { answer in
            if case .accept = answer { NSWorkspace.shared.open(url) }
        }
        host.present(prompt, scope: scope, pane: pane, tab: tab)
    }

    /// ⌘-click and middle-click: a new tab behind this one.
    private func opensInBackground(_ action: WKNavigationAction) -> Bool {
        action.modifierFlags.contains(.command) || action.buttonNumber == 2
    }

    private func openInBackground(_ url: URL) {
        guard let model = host?.model, !tab.isEmpty, isShown else { return }
        let pane = self.pane, opener = self.tab
        Task {
            _ = await model.dispatchFromSurfaceInOrder([
                ("browser_new_tab", .object(["pane": .string(pane), "url": .string(url.absoluteString)])),
                ("browser_select_tab", .object(["pane": .string(pane), "tab": .string(opener)])),
            ])
        }
    }

    // MARK: UI

    /// `window.open` and `target=_blank`: a tab beside this one, on the configuration WebKit gave,
    /// so `window.opener` works and the pop-up's `window.close()` closes the tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A page in a place not on screen opens nothing: its new tab would land in this place's pane
        // of the same id. Its own pop-up flow sees the window refused, as a blocker does.
        guard let host, !tab.isEmpty, isShown else { return nil }
        if let url = navigationAction.request.url, opensInBackground(navigationAction) {
            openInBackground(url)
            return nil
        }
        return host.adoptPopup(configuration: configuration, scope: scope, pane: pane, opener: tab, files: files,
                               url: navigationAction.request.url?.absoluteString ?? "")
    }

    // MARK: The page's questions

    /// The asking page's host, shown over its question.
    private func origin(_ frame: WKFrameInfo, _ webView: WKWebView) -> String {
        let origin = frame.securityOrigin
        if !origin.host.isEmpty { return origin.host }
        return webView.url.map(BrowserAddress.displayHost) ?? "This page"
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        ask(.alert(message), frame, webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        ask(.confirm(message), frame, webView) { answer in
            if case .accept = answer { completionHandler(true) } else { completionHandler(false) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        ask(.text(prompt, defaultText: defaultText ?? ""), frame, webView) { answer in
            if case .text(let text) = answer { completionHandler(text) } else { completionHandler(nil) }
        }
    }

    private func ask(_ kind: BrowserPrompt.Kind, _ frame: WKFrameInfo, _ webView: WKWebView,
                     reply: @escaping @MainActor @Sendable (BrowserPrompt.Answer) -> Void) {
        let prompt = BrowserPrompt(kind: kind, origin: origin(frame, webView), reply: reply)
        guard let host else { return prompt.answer(.withdrawn) }
        host.present(prompt, scope: scope, pane: pane, tab: tab)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        guard let host, !tab.isEmpty else { return decisionHandler(.deny) }
        let site = origin.host.isEmpty ? (webView.url.map(BrowserAddress.displayHost) ?? "This page") : origin.host
        host.requestMedia(host: site, type: type, scope: scope, pane: pane, tab: tab, decide: decisionHandler)
    }

    /// Location is denied to every page, silently (no usage string is in the bundle).
    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let host else { return completionHandler(nil) }
        host.runOpenPanel(parameters, for: webView, scope: scope, pane: pane, tab: tab, completion: completionHandler)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let model = host?.model, !tab.isEmpty else { return }
        let scope = self.scope, pane = self.pane, tab = self.tab
        Task { await model.browserPageClosed(scope: scope, pane: pane, tab: tab) }
    }
}
