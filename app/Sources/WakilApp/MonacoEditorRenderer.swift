import AppKit
import WakilKit
import WebKit

/// The editor pane's Monaco host (3b-i): a `WKWebView` running the bundled host page in editor
/// mode — one editable Monaco editor, a model per tab — and the one `EditorRenderer`
/// conformance. What to call and when is `editorRenderSteps`' decision (tested); this only
/// carries each call to the page and the page's typing and view reports back.
///
/// **It cannot exist without its network block**, for `MonacoDiffRenderer`'s reason: no Monaco,
/// no extension and no buffer's text may reach the network.
@MainActor
final class MonacoEditorRenderer: NSObject, EditorRenderer {
    let webView: WKWebView
    private(set) var ready = false
    private var onReady: [() -> Void] = []
    /// The operator typed in `key`'s model: its whole text (posted at most once a frame) and the
    /// agent-edit serial the page had applied then (`setBasis`).
    var onText: ((String, String, Int) -> Void)?
    /// `key`'s cursor, selection, visible lines and scroll, as Monaco last reported them.
    var onView: ((String, EditorPosition, EditorRange?, ClosedRange<Int>?, Double) -> Void)?
    /// Monaco's find bar: its query, switches, match count and whether it is open, on every change.
    var onFind: ((EditorFindReport) -> Void)?
    /// One line per page diagnostic and per failed `evaluateJavaScript`.
    var onLog: ((String) -> Void)?

    /// Held so `tearDown` can reach it from `deinit`, which is not main-actor isolated.
    nonisolated private let contentController: WKUserContentController
    private var tornDown = false

    init(blockNetwork: WKContentRuleList, frame: NSRect = .zero) {
        let config = WKWebViewConfiguration()
        // See `MonacoDiffRenderer.init`: a pane scrolled off the canvas keeps painting.
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController.add(blockNetwork)
        // Editor mode, set before the host page's own script reads it.
        config.userContentController.addUserScript(WKUserScript(
            source: "window.wakilMode = 'editor';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        contentController = config.userContentController
        webView = WKWebView(frame: frame, configuration: config)
        super.init()
        // Through a weak proxy, for `MonacoDiffRenderer`'s retain-cycle reason.
        contentController.add(MonacoEditorMessageProxy(self), name: "wakil")
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

    // MARK: EditorRenderer

    func showModel(key: String, text: String, language: String, readOnly: Bool) {
        run("wakilShowModel(\([key, text, language].map(Self.js).joined(separator: ",")),\(readOnly))")
    }

    func setLanguage(key: String, language: String) { run("wakilSetLanguage(\(Self.js(key)),\(Self.js(language)))") }

    func setReadOnly(key: String, readOnly: Bool) { run("wakilSetReadOnly(\(Self.js(key)),\(readOnly))") }

    func resetText(key: String, text: String, basis: Int) {
        run("wakilResetText(\(Self.js(key)),\(Self.js(text)),\(basis))")
    }

    /// One `evaluateJavaScript`: the page checks `before`, applies, checks `after`, and sets the
    /// basis in the same turn (final review I2).
    func applyEdit(key: String, range r: EditorRange, text: String, before: String, after: String, basis: Int) {
        run("wakilApplyEdit(\(Self.js(key)),\(r.start.line),\(r.start.column),\(r.end.line),\(r.end.column),"
            + "\(Self.js(text)),\(Self.js(before)),\(Self.js(after)),\(basis))")
    }

    func reveal(key: String, cursor: EditorPosition, selection: EditorRange?) {
        let sel = selection.map { "[\($0.start.line),\($0.start.column),\($0.end.line),\($0.end.column)]" } ?? "null"
        run("wakilReveal(\(Self.js(key)),\(cursor.line),\(cursor.column),\(sel))")
    }

    /// Opens Monaco's find bar on `key`'s model with the query and its switches, the first match revealed.
    func find(key: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool) {
        run("wakilFind(\(Self.js(key)),\(Self.js(query)),\(caseSensitive),\(wholeWord),\(regex))")
    }

    func setScrollTop(key: String, top: Double) { run("wakilSetScrollTop(\(Self.js(key)),\(top.isFinite ? top : 0))") }

    func disposeModel(key: String) { run("wakilDispose(\(Self.js(key)))") }

    func focus() { run("wakilFocus()") }

    /// The agent-edit serial `key`'s model now holds. Queued after the steps that applied it, so
    /// the page's posts carry it only once the edit is in the model.
    func setBasis(key: String, serial: Int) { run("wakilSetBasis(\(Self.js(key)),\(serial))") }

    /// The settings' options (3b-v). Queued until the page is ready, like every other call.
    func setOptions(_ o: EditorViewOptions) {
        run("wakilSetOptions({fontSize:\(o.fontSize),wordWrap:\(o.wordWrap),tabSize:\(o.tabSize),insertSpaces:\(o.insertSpaces)})")
    }

    private static func js(_ s: String) -> String { MonacoDiffRenderer.jsString(s) }

    /// Runs `js` once the page is ready, in call order; a failure goes to `onLog`.
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
        guard !tornDown, let body else { return }
        switch body["type"] as? String {
        case "log":
            onLog?("[\(body["level"] as? String ?? "?")] \(body["text"] as? String ?? "")")
        case "ready":
            ready = true
            let queued = onReady
            onReady = []
            queued.forEach { $0() }
        case "text":
            guard let key = body["key"] as? String, let text = body["text"] as? String else { return }
            onText?(key, text, Self.int(body["basis"]) ?? 0)
        case "view":
            guard let key = body["key"] as? String, let cursor = Self.position(body["cursor"]) else { return }
            let selection: EditorRange? = {
                guard let s = body["selection"] as? [String: Any], let a = Self.position(s["start"]),
                      let b = Self.position(s["end"]) else { return nil }
                return EditorRange(start: a, end: b)
            }()
            let visible: ClosedRange<Int>? = {
                guard let v = body["visible"] as? [String: Any], let first = Self.int(v["first"]),
                      let last = Self.int(v["last"]), first <= last else { return nil }
                return first...last
            }()
            let top = (body["scrollTop"] as? NSNumber)?.doubleValue ?? 0
            onView?(key, cursor, selection, visible, top)
        case "find":
            onFind?(EditorFindReport(query: body["query"] as? String ?? "",
                                     caseSensitive: (body["matchCase"] as? NSNumber)?.boolValue ?? false,
                                     wholeWord: (body["wholeWord"] as? NSNumber)?.boolValue ?? false,
                                     regex: (body["isRegex"] as? NSNumber)?.boolValue ?? false,
                                     count: Self.int(body["count"]) ?? 0,
                                     shown: (body["shown"] as? NSNumber)?.boolValue ?? false))
        default:
            break
        }
    }

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    private static func position(_ v: Any?) -> EditorPosition? {
        guard let o = v as? [String: Any], let line = int(o["line"]), let column = int(o["column"]) else { return nil }
        return EditorPosition(line: line, column: column)
    }
}

/// The page's message handler, holding the renderer weakly — see `MonacoDiffRenderer.init`.
private final class MonacoEditorMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: MonacoEditorRenderer?

    init(_ target: MonacoEditorRenderer) { self.target = target }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        MainActor.assumeIsolated { target?.receive(body) }
    }
}
