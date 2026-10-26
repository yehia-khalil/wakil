import AppKit
import WakilKit
import WebKit

/// The editor pane's Monaco host (3b-i): a `WKWebView` running the bundled host page — one
/// editable Monaco editor, a model per tab, and the diff editor a diff tab shows (3b-iii) — and the
/// one `EditorRenderer` conformance. What to call and when is `editorRenderSteps`' decision (tested); this only
/// carries each call to the page and the page's typing and view reports back.
///
/// **It cannot exist without its network block.** `blockNetwork` is not optional: every request
/// that is not `file:` or `blob:` is refused by the content rule list before the page loads, so no
/// Monaco, no extension and no buffer's or diff's text can reach the network.
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
    /// A mark clicked in `key`'s gutter, on `line`.
    var onMark: ((String, Int) -> Void)?
    /// 3a-v-a: the blame hover's links: (key, "open" | "copy", commit id).
    var onBlame: ((String, String, String) -> Void)?
    /// 3a-v-b: an actions-row press in `key`: (key, the block's `<<<<<<<` line, "current" | "incoming"
    /// | "both" | "compare").
    var onConflict: ((String, Int, String) -> Void)?
    /// One line per page diagnostic and per failed `evaluateJavaScript`.
    var onLog: ((String) -> Void)?
    /// A key the page took from Monaco (`captureKeys`): "up", "down" or "escape".
    var onKey: ((String) -> Void)?
    /// A peek control pressed in `key`: "up", "down", "stage", "revert" or "close".
    var onPeek: ((String, String) -> Void)?
    /// 3b-viii: the page asks for ghost-text in `key`'s model — request `id`, the model's whole text
    /// and the caret as a UTF-16 offset into it. Answered by `resolveGhost(id:text:)`.
    var onGhost: ((String, Int, String, Int) -> Void)?
    /// The page dropped request `id` (Monaco cancelled it: more typing, the caret moved). It has
    /// already resolved it empty; nothing is owed back.
    var onGhostCancel: ((Int) -> Void)?
    /// 3a-ii-b: Stage ("stage") or Unstage ("unstage") Selected Ranges from the diff's right-click
    /// menu in `key`, with every selection the page held.
    var onRanges: ((String, String, [EditorRange]) -> Void)?
    /// Ticket view: a review box's control in `key` — (key, thread, op, text, delta): `reply`,
    /// `discard`, `draft` (+text, on blur), `send` (+text), `resolve`, `unresolve`, `step` (+delta).
    var onReview: ((String, String, String, String?, Int?) -> Void)?
    private var capturing: [String] = []

    /// Held so `tearDown` can reach it from `deinit`, which is not main-actor isolated.
    nonisolated private let contentController: WKUserContentController
    private var tornDown = false

    init(blockNetwork: WKContentRuleList, frame: NSRect = .zero) {
        let config = WKWebViewConfiguration()
        // WebKit throttles timers, requestAnimationFrame and rendering for an inactive view, and
        // Monaco paints its lines from those frames: kept so a pane scrolled off the canvas stays
        // current (3a-i). It cannot help a page WebKit sees as hidden.
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController.add(blockNetwork)
        contentController = config.userContentController
        webView = WKWebView(frame: frame, configuration: config)
        super.init()
        // Through a weak proxy: the controller retains its handlers, and the renderer retains the
        // web view that owns the controller — handed `self`, the two would keep each other alive.
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

    func appendText(key: String, text: String, basis: Int) {
        run("wakilAppendText(\(Self.js(key)),\(Self.js(text)),\(basis))")
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
    func rekeyModel(from: String, to: String) { run("wakilRekey(\(Self.js(from)),\(Self.js(to)))") }

    func focus() { run("wakilFocus()") }

    func showDiff(key: String, original: String, modified: String, language: String, cursor: EditorPosition, scrollTop: Double) {
        let texts = [key, original, modified, language].map(Self.jsString).joined(separator: ",")
        run("wakilShowDiff(\(texts),\(cursor.line),\(cursor.column),\(scrollTop.isFinite ? scrollTop : 0))")
    }

    /// Every selection of the diff's modified side, as the page holds them now (3a-ii-b, ruling R1).
    /// Empty when the page is not ready or the call fails.
    func diffSelections() async -> [EditorRange] {
        guard ready, !tornDown else { return [] }
        let json: String? = await withCheckedContinuation { c in
            webView.evaluateJavaScript("wakilDiffSelections()") { value, _ in c.resume(returning: value as? String) }
        }
        guard let data = json?.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap(Self.selection)
    }

    private static func selection(_ o: [String: Any]) -> EditorRange? {
        guard let l1 = int(o["startLine"]), let c1 = int(o["startColumn"]), let l2 = int(o["endLine"]),
              let c2 = int(o["endColumn"]) else { return nil }
        return EditorRange(start: EditorPosition(line: l1, column: c1), end: EditorPosition(line: l2, column: c2))
    }

    func showPeek(key: String, _ p: EditorPeekView?) {
        guard let p else { run("wakilPeek(\(Self.jsString(key)),null)"); return }
        let old = p.old.map(Self.jsString).joined(separator: ","), new = p.new.map(Self.jsString).joined(separator: ",")
        run("wakilPeek(\(Self.jsString(key)),{title:\(Self.jsString(p.title)),afterLine:\(p.afterLine),old:[\(old)],new:[\(new)]})")
    }

    func captureKeys(_ keys: [String]) {
        guard keys != capturing else { return }
        capturing = keys
        run("wakilCaptureKeys([\(keys.map(Self.jsString).joined(separator: ","))])")
    }

    /// The agent-edit serial `key`'s model now holds. Queued after the steps that applied it, so
    /// the page's posts carry it only once the edit is in the model.
    func setBasis(key: String, serial: Int) { run("wakilSetBasis(\(Self.js(key)),\(serial))") }

    func setMarks(key: String, marks: [EditorGutterMark]) {
        let list = marks.map { "{kind:\(Self.jsString($0.kind.rawValue)),start:\($0.start),end:\($0.end)}" }
        run("wakilSetMarks(\(Self.jsString(key)),[\(list.joined(separator: ","))])")
    }

    /// 3a-v-a: the annotation after `line` of `key`'s model (an empty `text` clears it), its hover
    /// markdown, and the commit its links name.
    func setBlame(key: String, line: Int, text: String, hover: String?, id: String) {
        run("wakilSetBlame(\(Self.jsString(key)),\(line),\(Self.jsString(text)),\(hover.map(Self.jsString) ?? "null"),\(Self.jsString(id)))")
    }

    /// 3a-v-b: `key`'s conflict blocks, tinted with the actions row above each; an empty list clears them.
    func setConflicts(key: String, blocks: [EditorConflictBlock]) {
        let list = blocks.map { "{start:\($0.start),separator:\($0.separator),end:\($0.end)}" }
        run("wakilSetConflicts(\(Self.jsString(key)),[\(list.joined(separator: ","))])")
    }

    /// Ticket view: `key`'s review boxes, as JSON the page parses — every text in them is data, set
    /// with `textContent` there.
    func setReviews(key: String, boxes: [ReviewBox]) {
        let json = (try? JSONEncoder().encode(boxes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        run("wakilSetReviews(\(Self.jsString(key)),JSON.parse(\(Self.jsString(json))))")
    }

    /// Ticket view: after ⌥↓ from a box, the box of `thread` takes the keyboard when it is drawn
    /// (now, or once its file's boxes arrive); nil ends the wait. Meanwhile the text is not focused,
    /// so a second ⌥↓ is never Monaco's Move Line Down.
    func focusReview(thread: String?) { run("wakilFocusReview(\(thread.map(Self.jsString) ?? "null"))") }

    /// The settings' options (3b-v). Queued until the page is ready, like every other call.
    func setOptions(_ o: EditorViewOptions) {
        run("wakilSetOptions({fontSize:\(o.fontSize),wordWrap:\(o.wordWrap),tabSize:\(o.tabSize),insertSpaces:\(o.insertSpaces)})")
    }

    /// Ghost-text on or off: while it is off the page asks nothing and posts no text.
    func setGhostEnabled(_ on: Bool) { run("wakilGhostEnabled(\(on))") }

    /// Answers the page's ghost request `id`: `text` is drawn at the caret it asked from, nil draws
    /// nothing. The page ignores an answer for a request it no longer waits on.
    func resolveGhost(id: Int, text: String?) {
        run("wakilGhostResolve(\(id),\(text.map(Self.jsString) ?? "null"))")
    }

    private static func js(_ s: String) -> String { jsString(s) }

    /// `s` as a JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }

    /// Blocks every request that is not `file:` or `blob:` (the host page starts Monaco's worker
    /// from a blob). WKContentRuleList regexes support no groups or lookahead, so "everything
    /// except" is block-all followed by ignore-previous-rules for each allowed scheme.
    static func compileNetworkBlock() async throws -> WKContentRuleList {
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]"#
        guard let list = try await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "wakil-monaco-offline-v3", encodedContentRuleList: rules)
        else { throw CocoaError(.featureUnsupported) }
        return list
    }

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
        case "key":
            if let key = body["key"] as? String { onKey?(key) }
        case "peek":
            if let key = body["key"] as? String, let op = body["op"] as? String { onPeek?(key, op) }
        case "ranges":
            guard let key = body["key"] as? String, let op = body["op"] as? String else { return }
            onRanges?(key, op, (body["selections"] as? [[String: Any]] ?? []).compactMap(Self.selection))
        case "mark":
            if let key = body["key"] as? String, let line = Self.int(body["line"]) { onMark?(key, line) }
        case "blame":
            if let key = body["key"] as? String, let op = body["op"] as? String, let id = body["id"] as? String { onBlame?(key, op, id) }
        case "conflict":
            guard let key = body["key"] as? String, let block = Self.int(body["block"]),
                  let op = body["op"] as? String else { return }
            onConflict?(key, block, op)
        case "review":
            guard let key = body["key"] as? String, let thread = body["thread"] as? String,
                  let op = body["op"] as? String else { return }
            onReview?(key, thread, op, body["text"] as? String, Self.int(body["delta"]))
        case "ghost":
            guard let key = body["key"] as? String, let id = Self.int(body["id"]),
                  let text = body["text"] as? String, let offset = Self.int(body["offset"]) else { return }
            onGhost?(key, id, text, offset)
        case "ghostCancel":
            if let id = Self.int(body["id"]) { onGhostCancel?(id) }
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

/// The page's message handler, holding the renderer weakly — see `init`.
private final class MonacoEditorMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: MonacoEditorRenderer?

    init(_ target: MonacoEditorRenderer) { self.target = target }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        MainActor.assumeIsolated { target?.receive(body) }
    }
}
