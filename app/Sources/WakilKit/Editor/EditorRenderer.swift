import Foundation

/// The seam between the editor store and Monaco. WakilApp implements it; `editorRenderSteps` decides
/// what to call, so the untested view only applies steps.
@MainActor public protocol EditorRenderer: AnyObject {
    /// Show `tab`'s model, creating it with `text` if this key is new; switching keeps each model's undo.
    func showModel(key: String, text: String, language: String, readOnly: Bool)
    func setLanguage(key: String, language: String)
    func setReadOnly(key: String, readOnly: Bool)
    /// Replace a model's whole text (a reload) — keeps cursor and scroll where they fit. `basis` is
    /// the agent-edit serial the model then holds, set in the same call.
    func resetText(key: String, text: String, basis: Int)
    /// Apply one edit as an undoable step (an agent edit) — **only onto `before`**. A model that is
    /// not `before` holds keystrokes the store has not seen, and the range would land at shifted
    /// columns; it, or a result that is not `after`, is replaced whole by `after` instead (the
    /// keystroke is lost, the agent's edit never misplaced). `basis` is set in the same call, so no
    /// keystroke can fall between the edit and the serial its post carries.
    func applyEdit(key: String, range: EditorRange, text: String, before: String, after: String, basis: Int)
    func reveal(key: String, cursor: EditorPosition, selection: EditorRange?)
    func setScrollTop(key: String, top: Double)
    func disposeModel(key: String)
    func focus()
    /// Open Monaco's find bar on `key`'s model with the query and its switches (`editor_find`).
    func find(key: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool)
}

/// What the renderer was last told, per tab key.
public struct EditorRendered: Sendable, Equatable {
    public var text: String
    public var language: String
    public var readOnly: Bool
    public var agentSerial: Int
    public var cursor: EditorPosition
    public var selection: EditorRange?
    public init(text: String, language: String, readOnly: Bool, agentSerial: Int,
                cursor: EditorPosition, selection: EditorRange?) {
        self.text = text
        self.language = language
        self.readOnly = readOnly
        self.agentSerial = agentSerial
        self.cursor = cursor
        self.selection = selection
    }
}

public enum EditorRenderStep: Sendable, Equatable {
    case show(key: String, text: String, language: String, readOnly: Bool)
    case language(key: String, String)
    case readOnly(key: String, Bool)
    case reset(key: String, text: String, basis: Int)
    case edit(key: String, range: EditorRange, text: String, before: String, after: String, basis: Int)
    case reveal(key: String, cursor: EditorPosition, selection: EditorRange?)
    case scroll(key: String, top: Double)
    case dispose(key: String)
    case find(key: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool)
}

/// "file:<path>" or "scratch:<n>".
public func editorTabKey(_ tab: EditorTab) -> String {
    switch tab.subject {
    case .file(let path, _): "file:\(path)"
    case .scratch(let n): "scratch:\(n)"
    case .diff(let root, let path, let group): "diff:\(group.rawValue):\(root)/\(path)"
    }
}

/// `findShown` is the pane's last opened find serial, kept by the view beside `rendered` (not on a
/// tab's entry, which goes when its tab closes): `editorFindShownAfter`, seeded by `editorFindShownSeed`.
public func editorRenderSteps(rendered: [String: EditorRendered], active: String?, snapshot: EditorSnapshot,
                              findShown: Int = 0) -> [EditorRenderStep]
{
    var steps: [EditorRenderStep] = []
    let keys = Set(snapshot.tabs.map(editorTabKey))
    if let i = snapshot.active, i < snapshot.tabs.count {
        let t = snapshot.tabs[i], key = editorTabKey(t)
        if let r = rendered[key] {
            if key != active { steps.append(.show(key: key, text: t.text, language: t.language, readOnly: t.readOnly)) }
            if t.text != r.text {
                let serial = t.lastAgentEdit?.serial ?? 0
                if let e = t.lastAgentEdit, e.serial > r.agentSerial,
                    editorReplacing(r.text, e.range, with: e.text) == t.text
                {
                    steps.append(.edit(key: key, range: e.range, text: e.text, before: r.text, after: t.text, basis: serial))
                } else {
                    steps.append(.reset(key: key, text: t.text, basis: serial))
                }
            }
            if t.language != r.language { steps.append(.language(key: key, t.language)) }
            if t.readOnly != r.readOnly { steps.append(.readOnly(key: key, t.readOnly)) }
            if t.cursor != r.cursor || t.selection != r.selection {
                steps.append(.reveal(key: key, cursor: t.cursor, selection: t.selection))
            }
        } else {
            steps.append(.show(key: key, text: t.text, language: t.language, readOnly: t.readOnly))
            steps.append(.reveal(key: key, cursor: t.cursor, selection: t.selection))
            steps.append(.scroll(key: key, top: t.scrollTop))
        }
        // Once per find serial, for the pane: a tab first shown after it never replays it.
        if let f = snapshot.find, f.serial > findShown {
            steps.append(.find(key: key, query: f.query, caseSensitive: f.caseSensitive, wholeWord: f.wholeWord, regex: f.regex))
        }
    }
    for key in rendered.keys.sorted() where !keys.contains(key) { steps.append(.dispose(key: key)) }
    return steps
}

/// What the renderer holds after `steps`: every shown key at the snapshot's state.
public func editorRenderedAfter(_ steps: [EditorRenderStep], rendered: [String: EditorRendered],
                                snapshot: EditorSnapshot) -> [String: EditorRendered] {
    var out = rendered
    for step in steps { if case .dispose(let key) = step { out[key] = nil } }
    if let i = snapshot.active, i < snapshot.tabs.count {
        let t = snapshot.tabs[i]
        out[editorTabKey(t)] = EditorRendered(text: t.text, language: t.language, readOnly: t.readOnly,
                                              agentSerial: t.lastAgentEdit?.serial ?? 0, cursor: t.cursor,
                                              selection: t.selection)
    }
    return out
}

/// The pane's find serial after `steps`: the snapshot's once its `.find` step was applied.
public func editorFindShownAfter(_ steps: [EditorRenderStep], findShown: Int, snapshot: EditorSnapshot) -> Int {
    guard let f = snapshot.find, steps.contains(where: { if case .find = $0 { true } else { false } }) else { return findShown }
    return max(findShown, f.serial)
}

/// Where a newly made view starts its find record. A find the bar has reported on was opened by a
/// view before this one (`editor_find` clears the report with each new request), so it is not
/// replayed; one never reported (a new pane's first find) is still opened.
public func editorFindShownSeed(_ snapshot: EditorSnapshot) -> Int {
    snapshot.findReport == nil ? 0 : (snapshot.find?.serial ?? 0)
}

@MainActor public func editorApply(_ steps: [EditorRenderStep], to renderer: any EditorRenderer) {
    for step in steps {
        switch step {
        case .show(let key, let text, let language, let readOnly):
            renderer.showModel(key: key, text: text, language: language, readOnly: readOnly)
        case .language(let key, let language): renderer.setLanguage(key: key, language: language)
        case .readOnly(let key, let on): renderer.setReadOnly(key: key, readOnly: on)
        case .reset(let key, let text, let basis): renderer.resetText(key: key, text: text, basis: basis)
        case .edit(let key, let range, let text, let before, let after, let basis):
            renderer.applyEdit(key: key, range: range, text: text, before: before, after: after, basis: basis)
        case .reveal(let key, let cursor, let selection):
            renderer.reveal(key: key, cursor: cursor, selection: selection)
        case .scroll(let key, let top): renderer.setScrollTop(key: key, top: top)
        case .dispose(let key): renderer.disposeModel(key: key)
        case .find(let key, let query, let caseSensitive, let wholeWord, let regex):
            renderer.find(key: key, query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex)
        }
    }
}

/// What the view should render from `snapshot` while the operator's own writes are on their way to
/// the store, or nil to hold it until they land.
///
/// - **Held** only when the active tab differs from what is rendered by text the operator sent
///   (`typed`, while `typingInFlight`): the snapshot predates their later keystrokes, and rendering
///   it would put older text back under their hands.
/// - **Never held** when it carries an agent edit newer than rendered, or text the operator did not
///   send (a reload, a disk refresh): those are applied at once, so a whole-text post cannot erase
///   them (the store also drops a post whose basis is older, `editorBufferDidChange`).
/// - While a view report is in flight (`viewInFlight`), the active tab's cursor and selection are
///   the rendered ones: an older report's echo must not move the cursor back mid-gesture.
public func editorSnapshotToRender(
    _ snapshot: EditorSnapshot, rendered: [String: EditorRendered], active: String?,
    typed: Set<String>, typingInFlight: Bool, viewInFlight: Bool
) -> EditorSnapshot? {
    guard let i = snapshot.active, i < snapshot.tabs.count else { return snapshot }
    let t = snapshot.tabs[i], key = editorTabKey(t)
    guard key == active, let r = rendered[key] else { return snapshot }
    if (t.lastAgentEdit?.serial ?? 0) > r.agentSerial { return snapshot }
    if typingInFlight, t.text != r.text, typed.contains(t.text) { return nil }
    guard viewInFlight else { return snapshot }
    var out = snapshot
    out.tabs[i].cursor = r.cursor
    out.tabs[i].selection = r.selection
    return out
}

/// What the view does with one of the page's whole-text posts (final review I1, I2).
public enum EditorTypingPost: Sendable, Equatable {
    /// To the store, addressed by the tab's subject — never by its position.
    case send(EditorTabSubject)
    /// Made before an agent edit reached the page (`basis` older than rendered): the store would
    /// drop it, so the page is put back on the store's text and serial instead of drifting from it.
    case resync(text: String, basis: Int)
    /// The key is no longer a tab of this pane: nothing to write.
    case drop
}

/// Decides `EditorTypingPost` for a post from `key` carrying `basis`, against the last snapshot's
/// subjects by key and what the renderer holds.
public func editorTypingPost(
    key: String, basis: Int, subjects: [String: EditorTabSubject], rendered: [String: EditorRendered]
) -> EditorTypingPost {
    guard let subject = subjects[key] else { return .drop }
    if let r = rendered[key], basis < r.agentSerial { return .resync(text: r.text, basis: r.agentSerial) }
    return .send(subject)
}
