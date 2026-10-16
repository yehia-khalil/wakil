import AppKit
import WakilKit
import WebKit

/// The Monaco host: a `WKWebView` running Monaco's read-only inline diff editor from the
/// bundle, the one `DiffRenderer` conformance (3a-i). The git pane owns one per pane, made
/// on first fold and kept for the pane's life; the editor will reuse it.
///
/// **It cannot exist without its network block.** `blockNetwork` is not optional: every
/// request that is not `file:` or `blob:` is refused by the content rule list before the
/// page loads, so no Monaco, no extension and no diffed file's text can reach the network.
@MainActor
final class MonacoDiffRenderer: NSObject, DiffRenderer {
    let webView: WKWebView
    private(set) var ready = false
    private var onReady: [() -> Void] = []
    /// Called with how `shown` fired: `raf` (diff updated, two frames) or `timeout`.
    var onShown: ((String) -> Void)?
    /// Probe only: the host page's own attempt to reach the network.
    var onNetProbe: ((Bool) -> Void)?
    var onReadyMessage: (() -> Void)?
    /// One line per page diagnostic: `log` messages (errors, warnings, uncaught exceptions),
    /// the probe's `layout` report, and any `evaluateJavaScript` call that failed.
    var onLog: ((String) -> Void)?
    /// ↑, ↓ or Esc pressed while the diff had the keyboard, as `up`, `down` or `escape` —
    /// taken from Monaco only once `captureKeys(true)` has been asked for.
    var onKey: ((String) -> Void)?

    /// The modified side's scroll as the page last reported it.
    private var lastScrollTop: Double = 0
    /// Held so `tearDown` can reach it from `deinit`, which is not main-actor isolated.
    nonisolated private let contentController: WKUserContentController
    private var tornDown = false

    /// `userScripts` run at document start, before the host page's own script — how
    /// `--probe-monaco` sets `window.wakilProbe` (and nothing else does).
    init(blockNetwork: WKContentRuleList, frame: NSRect = .zero, userScripts: [WKUserScript] = []) {
        let config = WKWebViewConfiguration()
        // WebKit throttles timers, requestAnimationFrame and rendering for an
        // inactive view, and Monaco paints its lines from those frames. Kept
        // so a Git pane scrolled off the canvas stays current; its effect is
        // unproven (the blank probe snapshots had another cause, see
        // 3a-i-monaco-probe.md), and it cannot help a page WebKit sees as
        // hidden.
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController.add(blockNetwork)
        for script in userScripts { config.userContentController.addUserScript(script) }
        contentController = config.userContentController
        webView = WKWebView(frame: frame, configuration: config)
        super.init()
        // Through a weak proxy: the controller retains its handlers, and the renderer
        // retains the web view that owns the controller — handed `self`, the two would
        // keep each other alive for good.
        contentController.add(MonacoMessageProxy(self), name: "wakil")
        let root = Bundle.module.resourceURL!
        webView.loadFileURL(root.appendingPathComponent("monaco-host.html"), allowingReadAccessTo: root)
    }

    deinit {
        let controller = contentController
        if Thread.isMainThread {
            MainActor.assumeIsolated { controller.removeScriptMessageHandler(forName: "wakil") }
        }
    }

    /// Removes the page's message handler; the renderer answers nothing after it.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        contentController.removeScriptMessageHandler(forName: "wakil")
        onReady = []
    }

    // MARK: DiffRenderer

    func show(original: String, modified: String, language: String) {
        lastScrollTop = 0   // a new model pair starts at the top
        let args = [original, modified, language].map(MonacoEditorRenderer.jsString).joined(separator: ",")
        run("wakilShowDiff(\(args))")
    }

    func clear() {
        lastScrollTop = 0
        run("wakilClear()")
    }

    var scrollTop: Double {
        get { lastScrollTop }
        set {
            lastScrollTop = newValue
            run("wakilSetScrollTop(\(newValue.isFinite ? newValue : 0))")
        }
    }

    /// Whether ↑↓ and Esc are taken from Monaco and handed to `onKey`.
    func captureKeys(_ on: Bool) {
        run("window.wakilCaptureKeys = \(on)")
    }

    /// The editor font size (3b-v), so a diff reads at the size the operator chose.
    func setFontSize(_ size: Int) { run("wakilSetFontSize(\(size))") }

    /// Runs `js` once the page is ready, in call order, and logs a failure through `onLog`
    /// rather than dropping it.
    private func run(_ js: String) {
        let call = { [weak self] in
            guard let self, !self.tornDown else { return }
            self.webView.evaluateJavaScript(js) { [weak self] _, error in
                guard let error else { return }
                let head = js.prefix(40)
                MainActor.assumeIsolated { self?.onLog?("[js] \(head)…: \(error)") }
            }
        }
        if ready { call() } else { onReady.append(call) }
    }

    // MARK: Messages

    fileprivate func receive(_ body: [String: Any]?) {
        guard !tornDown else { return }
        let type = body?["type"] as? String
        switch type {
        case "log":
            onLog?("[\(body?["level"] as? String ?? "?")] \(body?["text"] as? String ?? "")")
        case "layout":
            onLog?("[layout] " + Self.json(body ?? [:]))
        case "ready":
            ready = true
            onReadyMessage?()
            let queued = onReady
            onReady = []
            queued.forEach { $0() }
        case "shown":
            onShown?(body?["via"] as? String ?? "unknown")
        case "netprobe":
            if let blocked = body?["blocked"] as? Bool { onNetProbe?(blocked) }
        case "scroll":
            if let top = body?["top"] as? Double { lastScrollTop = top }
        case "key":
            if let key = body?["key"] as? String { onKey?(key) }
        default:
            break
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The page's message handler, holding the renderer weakly — see `MonacoDiffRenderer.init`.
private final class MonacoMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: MonacoDiffRenderer?

    init(_ target: MonacoDiffRenderer) { self.target = target }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        MainActor.assumeIsolated { target?.receive(body) }
    }
}
