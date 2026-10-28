import Foundation
import WakilKit
import WebKit

/// The window's `BrowserPasswordPage` (3d-iv): puts a saved or a suggested password in a tab's page,
/// through the passwords' script (`BrowserPasswordScript`) in its `wakil.passwords` world.
///
/// **Made before the wiring, its host set after** (`WindowSession`), as `BrowserPageAgent` is: the
/// actions are registered by `WakilWiring.build`, and the web views are the window's
/// `BrowserTabHost`, which needs the model the wiring makes. Until the host is set, every call is
/// refused as not shown.
///
/// It is called only by `browser_password_fill` and `browser_password_suggest`, and it refuses:
/// - `.notShown` unless the screen's place is one of `org`'s and the tab has a live web view there;
/// - `.siteChanged` unless the live view's URL has the asked site key;
/// - `.failed(noPressReason)` unless the key's list is open on that tab — no fill without a press;
/// - and, in the page, `moved` when `location.origin` is not the origin of the field the key was
///   pressed in (ruling 13), `nofield` when there is no field.
///
/// The values travel as `callAsyncJavaScript` arguments, never in the script's source. A refusal is
/// built from Wakil's fixed words and the tab's site key only — never the page's answer or a value.
final class BrowserPasswordAgent: BrowserPasswordPage, @unchecked Sendable {
    @MainActor weak var host: BrowserTabHost?

    static let callTimeout: TimeInterval = 10

    func fill(pane: String, tab: String, org: String, site: String, username: String, password: String) async throws {
        let (view, origin, _) = try await MainActor.run { try self.target(pane: pane, tab: tab, org: org, site: site) }
        try await run(view, BrowserPasswordScript.fillCall,
                      ["origin": origin, "username": username, "password": password])
    }

    func suggest(pane: String, tab: String, org: String, site: String, password: String) async throws {
        let (view, origin, key) = try await MainActor.run { try self.target(pane: pane, tab: tab, org: org, site: site) }
        try await run(view, BrowserPasswordScript.suggestCall, ["origin": origin, "password": password])
        // A form sent with it is saved with no bar (ruling 7).
        await MainActor.run { self.host?.pendingSuggestion[key] = password }
    }

    /// The tab's live web view on the screen's place, on `site`, with the key's list open: the view,
    /// the origin the key was pressed on, and the tab's key.
    @MainActor
    private func target(pane: String, tab: String, org: String, site: String)
        throws -> (BrowserWebView, String, BrowserTabHost.Key) {
        guard let host, let scope = host.model?.browserScope, scope.organization == org,
              let view = host.liveView(scope: scope, pane: pane, tab: tab)
        else { throw BrowserPasswordPageError.notShown }
        let now = Self.site(of: view)
        guard now == site else { throw BrowserPasswordPageError.siteChanged(now: now) }
        let key = BrowserTabHost.Key(scope: scope, pane: pane, tab: tab)
        guard let origin = host.passwordPress[key] else {
            throw BrowserPasswordPageError.failed(BrowserPasswordPageAnswer.noPressReason)
        }
        // The press was on another site's document: the page has moved since.
        guard BrowserPasswords.siteKey(origin) == site else { throw BrowserPasswordPageError.siteChanged(now: now) }
        return (view, origin, key)
    }

    /// The tab's site key as Wakil reads it from the view's URL, or the URL itself when it has none.
    @MainActor
    private static func site(of view: WKWebView) -> String {
        let url = view.url?.absoluteString ?? ""
        return BrowserPasswords.siteKey(url) ?? (url.isEmpty ? "a blank tab" : url)
    }

    /// Runs a fixed call in the page's `wakil.passwords` world with `arguments` as values; answered by
    /// the page or, after 10 s, by the timeout.
    private func run(_ view: BrowserWebView, _ call: String, _ arguments: [String: any Sendable]) async throws {
        let answer: String? = await withCheckedContinuation { continuation in
            Task { @MainActor in
                let once = AnswerOnce(continuation)
                view.callAsyncJavaScript(BrowserPasswordScript.body(call), arguments: arguments, in: nil,
                                         in: BrowserPasswordScript.world) { result in
                    switch result {
                    case .success(let value as String): once.answer(value)
                    case .success, .failure: once.answer(nil)
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.callTimeout))
                    once.answer(Self.timedOut)
                }
            }
        }
        if answer == Self.timedOut { throw BrowserPasswordPageError.failed(BrowserPasswordPageAnswer.noAnswerReason) }
        let now = await MainActor.run { Self.site(of: view) }
        if let error = BrowserPasswordPageAnswer.error(answer, now: now) { throw error }
    }

    /// The timeout's own answer, which the script never gives.
    private static let timedOut = "\u{0}timeout"

    /// A continuation resumed by whichever answers first, the page or the timeout.
    @MainActor
    private final class AnswerOnce {
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        func answer(_ value: String?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
