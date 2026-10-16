import AppKit
import WakilKit
import SwiftUI

/// Amendment 10 — **one editor per field.** The path view, each query value, each header value
/// and the body are each ONE `NSTextView` on TextKit 2. A literal is characters, and a hole or a
/// bound value is one attachment character drawn by `ApiTokenView`.
///
/// **AppKit owns typing, the caret, selection, arrows, undo, input methods and wrapping**
/// (10b). Nothing here moves the caret except taking an outside change, which maps it across
/// (`apiEditorSelection`). **No ruling lives here.** Before a change touches a token, this view
/// asks `apiEditorVerdict` and does what it answers. It reports every change as the field's
/// parts, and the pane decides what to write.
///
/// Kept from the old body text view (Ruling 11): every substitution is off, because a value is
/// bytes on the wire. The identifier is set only when it changes (Ruling 15). Escape restores the
/// field and leaves it. The text storage is the undo target that gets cleared when outside text
/// is taken (Ruling 12). In the body Tab inserts two spaces and ⌘Return sends (9a). The body
/// grows to 16 lines, then scrolls.
struct ApiFieldEditor: NSViewRepresentable {
    let identifier: String
    /// `apiFieldKey`: what the tokens' identifiers are built on.
    let key: String
    /// What the field shows: its held parts, or the view's.
    let parts: [ApiPart]
    let singleLine: Bool
    /// `false` only for the path view over an `&` (8d).
    let editable: Bool
    let isPathView: Bool
    let handle: ApiEditorHandle
    let actions: ApiEditorActions
    /// 11a: moves on each fill the pane made from this editor's paste. The update that carries a
    /// new value carries the filled parts too (the surface door returns once the snapshot is
    /// published), so the caret goes to the end of the fill — tied to that take, never a timer
    /// (`apiFillCaret`). `0` for every field but the path.
    var caretToEnd = 0

    /// The one editor face, shared with `ApiTokenView`, which sizes attachments off the main
    /// actor's reach. `NSFont` is not marked `Sendable` but is immutable once made (AppKit
    /// documents fonts as thread-safe), hence `nonisolated(unsafe)`.
    nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// The pane's ink at 0.85.
    static let ink = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 0.85)
    static let maxBodyLines = 16

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ApiFieldTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        // Rich, because attachments live in the storage. What a paste inserts is ours
        // (`readSelection`), so no foreign style or image ever arrives.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Self.font
        textView.textColor = Self.ink
        textView.insertionPointColor = Self.ink
        textView.typingAttributes = [.font: Self.font, .foregroundColor: Self.ink]
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = editable
        textView.key = key
        textView.takeOutside(ApiEditorText(parts: parts))
        textView.refreshTokens(editable: editable)
        textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
        textView.setAccessibilityIdentifier(identifier)
        // The drag types are ours (`acceptableDragTypes`): never RTFD, never a file.
        textView.updateDragTypeRegistration()
        handle.textView = textView
        handle.isPathView = isPathView

        let scroll = ApiFieldScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = !singleLine
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // A single-line field grows to its text and never scrolls itself: no rubber band, and a
        // wheel over it scrolls the request half (Task 6 carry). The body, capped at 16 lines,
        // keeps scrolling itself.
        scroll.forwardsScrollWheel = singleLine
        scroll.verticalScrollElasticity = singleLine ? .none : .automatic
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scroll.documentView as? ApiFieldTextView else { return }
        handle.textView = textView
        handle.isPathView = isPathView
        textView.key = key
        // 11a: once this update has taken (or already showed) the fill, the caret owed goes to
        // its end — only while this editor still has the cursor (Rule 6).
        defer {
            let owed = coordinator.caretSeen != caretToEnd
            coordinator.caretSeen = caretToEnd
            if let caret = apiFillCaret(
                owed: owed, focused: textView.window?.firstResponder === textView,
                length: textView.editorText.length)
            {
                textView.setSelectedRange(NSRange(location: caret.lowerBound, length: 0))
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }
        // Ruling 15: only when it changed.
        if textView.accessibilityIdentifier() != identifier {
            textView.setAccessibilityIdentifier(identifier)
        }
        if textView.isEditable != editable { textView.isEditable = editable }
        let showing = textView.editorText
        if showing == ApiEditorText(parts: parts) { coordinator.typedSinceTaken = [] }
        let focused = textView.window?.firstResponder === textView
        // Review Focus 4: never an echo of its own typing, and never what it already shows.
        guard apiEditorTakesParts(
            parts, showing: showing.parts, typedSinceTaken: coordinator.typedSinceTaken,
            focused: focused)
        else {
            textView.refreshTokens(editable: editable)
            return
        }
        coordinator.typedSinceTaken = []
        let incoming = ApiEditorText(parts: parts)
        let selected = textView.selectedRange()
        // Mapped across the change while it has the cursor; at the end otherwise (C4).
        let next = apiEditorSelection(
            from: showing, to: incoming, selection: selected.location..<NSMaxRange(selected),
            focused: focused)
        textView.takeOutside(incoming)
        textView.refreshTokens(editable: editable)
        textView.setSelectedRange(NSRange(location: next.lowerBound, length: next.count))
        // Ruling 12, and W16: the undo stack names ranges in the text just replaced, and an
        // undo must never bring back a token an outside change took away (an unbind landing).
        textView.clearUndo()
    }

    /// One line empty, then the text's own height, measured on a copy (never the live view).
    /// The body is capped at 16 lines; a single-line field wraps and grows.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        let padding = (nsView.documentView as? NSTextView)?.textContainer?.lineFragmentPadding ?? 5
        let line = NSLayoutManager().defaultLineHeight(for: Self.font)
        let measured = NSMutableAttributedString(
            attributedString: apiEditorAttributed(ApiEditorText(parts: parts), editor: nil))
        measured.append(NSAttributedString(string: " ", attributes: [.font: Self.font]))
        let natural = measured.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        var width = natural.width + 2 * padding + 2
        if let proposed = proposal.width, proposed.isFinite { width = proposed }
        width = max(width, 60)
        let wrapped = measured.boundingRect(
            with: NSSize(width: max(width - 2 * padding, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let cap = singleLine ? CGFloat.greatestFiniteMagnitude : line * CGFloat(Self.maxBodyLines)
        return CGSize(width: width, height: ceil(min(max(ceil(wrapped.height), line), cap)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ApiFieldEditor
        /// Every part list this editor reported since it last matched what it was handed.
        var typedSinceTaken: [[ApiPart]] = []
        /// Whether the caret has ever been here: where `+ hole` lands (`apiEditorHoleOffset`).
        var hadCaret = false
        /// The last `caretToEnd` this editor acted on; it starts at the first one it is handed,
        /// so appearing moves nothing.
        var caretSeen: Int

        init(_ parent: ApiFieldEditor) {
            self.parent = parent
            caretSeen = parent.caretToEnd
        }

        /// Every change the text system is about to make, asked of `apiEditorVerdict` first.
        ///
        /// **The inserted tokens are always passed** (W16): this view's own insertions (a paste,
        /// a drop, `+ hole`) name theirs (`pendingInsertedTokens`). A change the text system
        /// makes on its own hands over only a string, and a string carries no attachment — typing
        /// none, and an undo or redo replay is checked once made (`textDidChange`'s backstop).
        func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
        ) -> Bool {
            guard let view = textView as? ApiFieldTextView, !view.bypassVerdict,
                  let replacementString
            else { return true }
            let replaying = view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true
            let verdict = apiEditorVerdict(
                view.editorText, replacing: range.location..<NSMaxRange(range),
                with: replacementString, insertedTokens: view.pendingInsertedTokens ?? [],
                replaying: replaying, key: view.pendingKey, isRepeat: view.pendingKeyRepeats,
                composing: view.hasMarkedText(), draggingOut: view.draggingOut,
                singleLine: parent.singleLine)
            if verdict != .allow, replaying {
                // A replay the verdict stopped leaves every record after it naming ranges in a
                // text that never came to be (Ruling 12): the stack goes.
                DispatchQueue.main.async { [weak view] in view?.clearUndo() }
            }
            switch verdict {
            case .allow:
                return true
            case .ignore:
                return false
            case .refuse(let line):
                parent.actions.refused(line)
                return false
            case .unbind(let ordinal, let name):
                parent.actions.unbind(ordinal, name)
                return false
            case .substitute(let text):
                // One turn later, so the range may be stale: clamped to the storage as it then
                // stands, and skipped past its end (no `NSRangeException`). Drawing, not a ruling.
                DispatchQueue.main.async { [weak view] in
                    guard let view, let length = view.textStorage?.length, range.location <= length
                    else { return }
                    let clamped = NSRange(location: range.location,
                                          length: min(range.length, length - range.location))
                    view.insertText(text, replacementRange: clamped)
                }
                return false
            }
        }

        /// Every change, reported as the field's parts. **Not while text is marked** (Review
        /// Focus 1): half a composition is no part list. The commit reports it.
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ApiFieldTextView, !view.settingOutside,
                  !view.hasMarkedText()
            else { return }
            let text = view.editorText
            // W16's backstop: a replay the verdict could not see (an undo, a redo) that left the
            // field with a binding it did not hold is taken back, and said.
            if apiEditorMadeBinding(from: view.lastText, to: text) {
                let selection = view.selectedRange()
                view.takeOutside(view.lastText)
                view.refreshTokens(editable: parent.editable)
                let length = view.lastText.length
                view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                DispatchQueue.main.async { [weak view] in view?.clearUndo() }
                parent.actions.refused(apiBoundSelectionLine)
                return
            }
            view.lastText = text
            view.refreshTokens(editable: parent.editable)
            let parts = text.parts
            typedSinceTaken.append(parts)
            parent.actions.refused(nil)
            parent.actions.typed(parts)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.singleLine {
                    parent.actions.commit()
                    return true
                }
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    parent.actions.commit()
                    return true
                }
                return false
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // Option-Return: a single-line field takes no break at all.
                return parent.singleLine
            case #selector(NSResponder.insertTab(_:)):
                if parent.singleLine {
                    textView.window?.selectNextKeyView(nil)
                } else {
                    textView.insertText("  ", replacementRange: textView.selectedRange())
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                guard let discard = parent.actions.discard else { return false }
                discard()
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// What the pane hands an editor, and what the editor calls back. No ruling in any of them.
struct ApiEditorActions {
    /// Every change the operator made, as the field's parts: the pause starts (9a).
    var typed: ([ApiPart]) -> Void
    /// A token's `×` on a hole, a move, or `+ hole`: the field writes at once (9a).
    var gesture: () -> Void
    /// Return in a single-line field (write now); ⌘Return in the body (Send).
    var commit: () -> Void
    var discard: (() -> Void)?
    /// Decision 27 by focus: the cursor arrived (`true`) or left (`false`).
    var focusChanged: (Bool) -> Void
    /// Backspace, Delete or `×` on a bound value: `api_unbind`, by its place among the tokens.
    var unbind: (_ ordinal: Int, _ name: String) -> Void
    /// The field's line (`apiBoundSelectionLine`), or `nil` to clear it.
    var refused: (String?) -> Void
    /// Amendment 11a: a paste whose text `apiPasteIsCurl` reads as a cURL command — the path
    /// field only (`nil` everywhere else, where a paste stays text). The editor never
    /// dispatches: the pane does, through its surface door.
    var pastedCurl: ((String) -> Void)? = nil
}

/// The pane's way to reach one field's text view: `+ hole` inserts at its caret, and a row
/// `+ query` / `+ header` adds hands it the cursor.
@MainActor final class ApiEditorHandle {
    weak var textView: ApiFieldTextView?
    var isPathView = false

    /// `+ hole` (10b): at the caret, or at the end of a field the caret has not been in
    /// (`apiEditorHoleOffset`). The insertion is the text system's, so ⌘Z takes it back. Then the
    /// cursor returns to the field, just after the hole, so typing carries on.
    func insertHole(_ name: String) -> Bool {
        guard let textView, let coordinator = textView.coordinator else { return false }
        let selected = textView.selectedRange()
        let offset = apiEditorHoleOffset(
            textView.editorText,
            selection: coordinator.hadCaret ? selected.location..<NSMaxRange(selected) : nil,
            isPathView: isPathView)
        guard textView.insertHole(name, at: offset) else { return false }
        textView.window?.makeFirstResponder(textView)
        return true
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

/// One handle per field, kept for the pane's life.
@MainActor final class ApiEditorRegistry {
    private var handles: [ApiFieldRow: ApiEditorHandle] = [:]

    func handle(_ box: ApiFieldRow) -> ApiEditorHandle {
        if let handle = handles[box] { return handle }
        let handle = ApiEditorHandle()
        handles[box] = handle
        return handle
    }
}

extension NSPasteboard.PasteboardType {
    static let apiEditor = NSPasteboard.PasteboardType(apiEditorPasteboardType)
}

/// The editor's attributed text for `text`: characters in the field's font and ink, and each
/// token an `ApiTokenAttachment`.
@MainActor func apiEditorAttributed(_ text: ApiEditorText, editor: ApiFieldTextView?) -> NSAttributedString {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: ApiFieldEditor.font, .foregroundColor: ApiFieldEditor.ink,
    ]
    let out = NSMutableAttributedString()
    for run in text.runs {
        switch run {
        case .text(let string):
            out.append(NSAttributedString(string: string, attributes: attributes))
        case .token(let token):
            let attachment = ApiTokenAttachment(token: token)
            attachment.editor = editor
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
            out.append(piece)
        }
    }
    return out
}

/// The editor's text read back, **attachment run by attachment run** (M6), never one attribute
/// per character: a U+FFFC carrying an `ApiTokenAttachment` is a token, and every stretch
/// between them is text — in which a U+FFFC with no attachment of ours is dropped
/// (`ApiEditorText`, the spike).
func apiEditorText(of storage: NSAttributedString) -> ApiEditorText {
    let string = storage.string as NSString
    var runs: [ApiEditorText.Run] = []
    storage.enumerateAttribute(
        .attachment, in: NSRange(location: 0, length: storage.length)
    ) { value, range, _ in
        if let attachment = value as? ApiTokenAttachment {
            // One U+FFFC per attachment; a longer run (never made here) is one token per unit.
            for _ in 0..<range.length { runs.append(.token(attachment.token)) }
        } else {
            runs.append(.text(string.substring(with: range)))
        }
    }
    return ApiEditorText(runs: runs)
}

/// The tokens an attributed string carries, in order: what an insertion hands the verdict.
func apiEditorTokens(of attributed: NSAttributedString) -> [ApiEditorToken] {
    var tokens: [ApiEditorToken] = []
    attributed.enumerateAttribute(
        .attachment, in: NSRange(location: 0, length: attributed.length)
    ) { value, _, _ in
        if let attachment = value as? ApiTokenAttachment { tokens.append(attachment.token) }
    }
    return tokens
}

/// An editor's scroll view. **A single-line field hands the wheel on** (`forwardsScrollWheel`):
/// it never has anything of its own to scroll, and an `NSScrollView` takes every wheel event
/// over it, so the request half under the cursor stopped scrolling there.
final class ApiFieldScrollView: NSScrollView {
    var forwardsScrollWheel = false

    override func scrollWheel(with event: NSEvent) {
        if forwardsScrollWheel {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The text view an editor draws.
final class ApiFieldTextView: NSTextView {
    weak var coordinator: ApiFieldEditor.Coordinator?
    var key = ""
    /// Taking outside text: neither asked of the verdict nor reported as typing.
    private(set) var settingOutside = false
    /// The one sanctioned bound-carrying write, a move within the field (`apiEditorMoving`):
    /// not asked of the verdict, which would refuse it (10b, W16).
    private(set) var bypassVerdict = false
    /// The tokens this view's own insertion carries, while it asks the verdict (W16). `nil`
    /// for a change the text system makes on its own.
    private(set) var pendingInsertedTokens: [ApiEditorToken]?
    /// The key being handled, so the verdict can tell a key from a selection delete. **Only the
    /// plain `deleteBackward:` / `deleteForward:`** (M17): a word or line delete is a range.
    private(set) var pendingKey: ApiEditorKey?
    private(set) var pendingKeyRepeats = false
    /// Set from a drag out of this view until the drag ends, or the next mouse or key event here
    /// (ambiguity 6): the only change a source sees in that window is the drag-out's own delete.
    private(set) var draggingOut = false
    /// The text as it stood after the last change or take: what `apiEditorMadeBinding` compares.
    var lastText = ApiEditorText(parts: [])
    private var focusedThrough: ((Bool) -> Void)?
    /// Every token view a provider made for this view. Weak: TextKit 2 makes and drops them as it
    /// lays out (the spike), and only the ones drawn now are exposed.
    let tokenViews = NSHashTable<ApiTokenView>.weakObjects()

    var editorText: ApiEditorText { apiEditorText(of: textStorage ?? NSTextStorage()) }

    /// Outside parts (a landing, Format, Escape, an agent): replaced whole, not undoable.
    func takeOutside(_ text: ApiEditorText) {
        settingOutside = true
        defer { settingOutside = false }
        textStorage?.setAttributedString(apiEditorAttributed(text, editor: self))
        lastText = text
    }

    /// Ruling 12: the text storage is where typing registers its undo, and the view registers
    /// its own. Both go.
    func clearUndo() {
        if let storage = textStorage { undoManager?.removeAllActions(withTarget: storage) }
        undoManager?.removeAllActions(withTarget: self)
    }

    /// One of this view's own insertions: asked of the verdict with the tokens it carries,
    /// undoable, reported.
    private func insertOwn(_ attributed: NSAttributedString, in range: NSRange) -> Bool {
        pendingInsertedTokens = apiEditorTokens(of: attributed)
        defer { pendingInsertedTokens = nil }
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return false }
        textStorage?.replaceCharacters(in: range, with: attributed)
        didChangeText()
        return true
    }

    func insertHole(_ name: String, at offset: Int) -> Bool {
        let attributed = apiEditorAttributed(ApiEditorText(parts: [.slot(name)]), editor: self)
        guard insertOwn(attributed, in: NSRange(location: offset, length: 0)) else { return false }
        setSelectedRange(NSRange(location: offset + 1, length: 0))
        coordinator?.parent.actions.gesture()
        return true
    }

    /// Re-numbers every token (its `<i>` among the parts) and sets each token view's
    /// identifiers, only where they changed.
    func refreshTokens(editable: Bool) {
        guard let storage = textStorage else { return }
        let text = editorText
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let attachment = value as? ApiTokenAttachment,
                  let index = text.partIndex(ofTokenAt: range.location)
            else { return }
            attachment.editor = self
            attachment.apply(key: key, index: index, editable: editable)
        }
    }

    func range(of attachment: ApiTokenAttachment) -> NSRange? {
        guard let storage = textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if (value as AnyObject) === attachment {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// A press on the token (a click): the cursor here, the token selected.
    @discardableResult
    func selectToken(_ attachment: ApiTokenAttachment) -> Bool {
        guard let range = range(of: attachment) else { return false }
        window?.makeFirstResponder(self)
        setSelectedRange(range)
        return true
    }

    /// The token's `×` (spec §3): a hole is removed as one character, through the verdict, so
    /// ⌘Z brings it back. A bound value is unbound.
    func tokenAct(_ attachment: ApiTokenAttachment) {
        guard let range = range(of: attachment) else { return }
        switch attachment.token {
        case .hole:
            guard insertOwn(NSAttributedString(), in: range) else { return }
            coordinator?.parent.actions.gesture()
        case .bound(let value):
            guard let ordinal = editorText.ordinal(ofTokenAt: range.location) else { return }
            coordinator?.parent.actions.unbind(ordinal, value.name)
        }
    }

    // MARK: Accessibility (the spike, M1)

    /// The token views drawn now, each exposed ONCE: TextKit 2 may make a new view for an
    /// attachment as it lays out, so only the attachment's latest view counts (M10).
    var exposedTokens: [ApiTokenView] {
        tokenViews.allObjects
            .filter { $0.superview != nil && $0.attachment.tokenView === $0 }
            .sorted { $0.attachment.index < $1.attachment.index }
    }

    // TextKit 2 draws attachment views but leaves them out of the AX tree (spike run 1), so this
    // view lists them itself: its AX children are the token groups and nothing else.
    //
    // **Neither entry point calls super, and neither calls the other** (spike run 2 crashed on
    // the two recursing through NSTextView's legacy path). Run 1 measured the text area with no
    // children of its own, so dropping super's list loses nothing. Parents point up only.
    override func accessibilityChildren() -> [Any]? { exposedTokens }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        // AppKit asks on the main thread.
        if attribute == .children { return MainActor.assumeIsolated { exposedTokens } }
        return super.accessibilityAttributeValue(attribute)
    }

    // #342: a client that sets the whole value (Orca's `type-text`, other automation) is
    // narrowed to the range it changed and inserted as this view's own edit, so the verdict
    // sees an edit, not a replacement of every token. Both entry points, as for the children
    // above, and again neither calls the other.
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let value = accessibilityValue as? String else { return }
        takeWholeValue(value)
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard attribute == .value else { return super.accessibilitySetValue(value, forAttribute: attribute) }
        guard let string = value as? String else { return }
        // AppKit asks on the main thread.
        MainActor.assumeIsolated { takeWholeValue(string) }
    }

    private func takeWholeValue(_ value: String) {
        guard isEditable, !hasMarkedText(),
              let narrowed = apiEditorNarrowed(
                editorText, to: value, singleLine: coordinator?.parent.singleLine ?? true)
        else { return }
        let range = NSRange(location: narrowed.range.lowerBound, length: narrowed.range.count)
        let attributed = apiEditorAttributed(narrowed.inserted, editor: self)
        guard insertOwn(attributed, in: range) else { return }
        setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
    }

    // MARK: Focus (Decision 27 by focus), deferred a turn as the old body text view did (F5).

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took {
            coordinator?.hadCaret = true
            draggingOut = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let changed = self.coordinator?.parent.actions.focusChanged else { return }
                self.focusedThrough = changed
                changed(true)
            }
        }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let changed = self.focusedThrough ?? self.coordinator?.parent.actions.focusChanged
                self.focusedThrough = nil
                changed?(false)
            }
        }
        return resigned
    }

    // MARK: Keys

    override func deleteBackward(_ sender: Any?) { keyed(.backspace) { super.deleteBackward(sender) } }
    override func deleteForward(_ sender: Any?) { keyed(.delete) { super.deleteForward(sender) } }

    private func keyed(_ key: ApiEditorKey, _ body: () -> Void) {
        pendingKey = key
        // `isARepeat` raises on anything but a key event (a menu's Delete, say).
        pendingKeyRepeats = NSApp.currentEvent.map { $0.type == .keyDown && $0.isARepeat } ?? false
        defer {
            pendingKey = nil
            pendingKeyRepeats = false
        }
        body()
    }

    override func keyDown(with event: NSEvent) {
        draggingOut = false
        if Self.isCommandReturn(event), coordinator?.parent.singleLine == false {
            coordinator?.parent.actions.commit()
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘Return before the menu's Maximize Pane takes it, in the body (9a).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isCommandReturn(event),
           coordinator?.parent.singleLine == false
        {
            coordinator?.parent.actions.commit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isCommandReturn(_ event: NSEvent) -> Bool {
        // 36 is Return, 76 the keypad's Enter.
        (event.keyCode == 36 || event.keyCode == 76)
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    // MARK: Copy, cut, paste (10b)

    /// **Wakil's clip and plain text, nothing else**: never RTFD, so an attachment from outside
    /// (or a bare U+FFFC, the spike's native drag) never arrives.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.apiEditor, .string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.apiEditor, .string] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.apiEditor, .string] }

    /// A copy, a cut or a drag carries text and holes, and a bound value as its hole.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        let clip = ApiEditorClip(editorText, range: range.location..<NSMaxRange(range))
        guard let data = try? JSONEncoder().encode(clip) else { return false }
        pboard.declareTypes([.apiEditor, .string], owner: nil)
        return pboard.setData(data, forType: .apiEditor) && pboard.setString(clip.plain, forType: .string)
    }

    /// A paste or a drop: Wakil's clip as tokens, outside text as literal text.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // 11a: outside text that reads as a cURL command fills the pane instead of landing as
        // text — only where the pane asked for it (the path), and never Wakil's own clip.
        if let pastedCurl = coordinator?.parent.actions.pastedCurl {
            let plain = pboard.string(forType: .string)
            if apiPasteFillsFromCurl(hasClip: pboard.data(forType: .apiEditor) != nil, plain: plain),
               let plain {
                pastedCurl(plain)
                return true
            }
        }
        let clip = pboard.data(forType: .apiEditor).flatMap {
            try? JSONDecoder().decode(ApiEditorClip.self, from: $0)
        }
        guard let pasted = apiEditorPasted(
            clip: clip, plain: pboard.string(forType: .string),
            singleLine: coordinator?.parent.singleLine ?? true)
        else { return false }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound else { return false }
        let attributed = apiEditorAttributed(pasted, editor: self)
        // Through the verdict with its tokens: pasting over a selection that holds a bound
        // value is refused.
        guard insertOwn(attributed, in: range) else { return false }
        setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
        return true
    }

    /// W16: a cut is a delete, refused as one when it holds a bound value. **Never with
    /// `draggingOut` set** (Task 3 carry): a stale drag would turn the refusal into silence.
    override func cut(_ sender: Any?) {
        draggingOut = false
        let range = selectedRange()
        if case .refuse(let line) = apiEditorVerdict(
            editorText, replacing: range.location..<NSMaxRange(range), with: "",
            insertedTokens: [], replaying: false, singleLine: coordinator?.parent.singleLine ?? true)
        {
            coordinator?.parent.actions.refused(line)
            return
        }
        super.cut(sender)
    }

    // MARK: Drag (10b)

    override func mouseDown(with event: NSEvent) {
        draggingOut = false
        super.mouseDown(with: event)
    }

    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        draggingOut = true
        return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    /// The drag is over: the source's own delete, if it was a move, has run inside `super`.
    override func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        draggingOut = false
    }

    /// **Inside this editor a drag is a COPY to AppKit**, so its own source never deletes; the
    /// move is ours (`performDragOperation`), carrying a bound value as itself — AppKit's
    /// delete-then-insert would be refused by the verdict. **From another Wakil field it is a
    /// MOVE** (preflight M2): the clip lands here as holes and text, and the source deletes what
    /// it sent through its verdict with `draggingOut` set, so a bound value stays where it was.
    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        if movesWithin(dragInfo) { return .copy }
        if dragInfo.draggingSource is ApiFieldTextView, carriesClip(dragInfo) { return .move }
        return super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard movesWithin(sender) else { return super.performDragOperation(sender) }
        let to = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let range = selectedRange()
        guard let moved = apiEditorMoving(
            editorText, range: range.location..<NSMaxRange(range), to: to)
        else { return false }
        let all = NSRange(location: 0, length: textStorage?.length ?? 0)
        let attributed = apiEditorAttributed(moved.text, editor: self)
        bypassVerdict = true
        let changed = shouldChangeText(in: all, replacementString: attributed.string)
        if changed {
            textStorage?.replaceCharacters(in: all, with: attributed)
            didChangeText()
        }
        bypassVerdict = false
        guard changed else { return false }
        setSelectedRange(NSRange(location: moved.selection.lowerBound, length: moved.selection.count))
        draggingOut = false
        // Its undo replaces the whole field, and would be refused over a bound value anywhere
        // in it (moved or not); a refused replay leaves the stack stale (Ruling 12).
        if !apiEditorMoveIsUndoable(moved.text) { clearUndo() }
        coordinator?.parent.actions.gesture()
        return true
    }

    private func movesWithin(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as AnyObject?) === self && carriesClip(info)
    }

    private func carriesClip(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.types?.contains(.apiEditor) == true
    }
}
