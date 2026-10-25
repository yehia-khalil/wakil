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

    /// K P N T W L , and 1–9.
    private static let commandKeys: Set<UInt16> = [40, 35, 45, 17, 13, 37, 43, 18, 19, 20, 21, 23, 22, 26, 28, 25]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isWakilKey(event), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
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
    /// those whose place is not on screen (pane and tab ids repeat from place to place).
    let scope: LayoutScope
    let pane: String
    /// Empty while a pop-up waits for the store to name its tab (`BrowserTabHost.adoptPopup`).
    var tab: String
    /// The organisation's files, for the tab's state; never the store's id (Invariant 4).
    let files: BrowserOrgFiles?
    /// The address last asked for, which a failed first load has no `url` to report.
    var requested: String?
    private(set) var failure: String?
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
                let report = BrowserPageReport(
                    // A failed load reads as the address that failed, not the page left showing.
                    url: (self.failure != nil ? self.requested : nil) ?? view.url?.absoluteString
                        ?? self.requested ?? "",
                    title: view.title ?? "",
                    isLoading: view.isLoading, progress: view.estimatedProgress,
                    canGoBack: view.canGoBack, canGoForward: view.canGoForward, failure: self.failure)
                await model.browserPageDidReport(scope: self.scope, pane: self.pane, tab: self.tab, report)
            }
            self?.reporting = nil
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
        // A link, ‹ › or a redirect is the address now: what a failure names, and Try Again asks for.
        if let url = webView.url?.absoluteString { requested = url }
        scheduleReport()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
        host?.saveState(of: webView, scope: scope, pane: pane, tab: tab, files: files)
        scheduleReport()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        guard let text = browserLoadFailure(error, url: requested.flatMap(URL.init(string:)) ?? webView.url) else {
            scheduleReport()
            return
        }
        failure = text
        scheduleReport()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        // Rule 7: a scheme a page cannot show is the Mac's (`mailto:` opens Mail).
        if let scheme = url.scheme?.lowercased(),
           !["http", "https", "file", "about", "data", "blob"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        if navigationAction.navigationType == .linkActivated, opensInBackground(navigationAction) {
            openInBackground(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
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

    func webViewDidClose(_ webView: WKWebView) {
        guard let model = host?.model, !tab.isEmpty else { return }
        let scope = self.scope, pane = self.pane, tab = self.tab
        Task { await model.browserPageClosed(scope: scope, pane: pane, tab: tab) }
    }
}
