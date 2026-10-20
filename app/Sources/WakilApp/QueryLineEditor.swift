import AppKit
import WakilKit
import SwiftUI

/// The DB pane's query line: one `NSTextView` (TextKit 2) that wraps, grows to six lines,
/// then scrolls, and restyles by `SQLStyle` on every change. Return runs, ⇧Return breaks a
/// line, ⌥⇧F formats. Every substitution is off — a query is bytes.
///
/// The shape is `ApiFieldEditor`'s, with no tokens or attachments: AppKit owns typing, the
/// caret, selection, undo and wrapping. **Restyling is attributes only** — set on the text
/// storage, never through `replaceCharacters` — so it moves no caret and leaves typing's undo
/// grouping alone. Format is one undo step. Outside text (a sort, a page, the agent, a
/// restore) clears this view's undo (Ruling 12). The identifier is set only when it changes
/// (Ruling 15).
struct QueryLineEditor: NSViewRepresentable {
    @Binding var text: String
    let identifier: String
    let dialect: QueryDialect
    let run: (String) -> Void
    /// Called with `.unchanged`'s reason. The pane clears it whenever `text` changes.
    let reportFormat: (String?) -> Void
    /// Bumped by the Format control; each new value formats once.
    let formatRequest: Int
    /// Esc while a read runs on this pane: cancels it and returns true. Otherwise false, and
    /// Esc leaves the line as before.
    var cancel: () -> Bool = { false }
    /// Told when the line gains or loses keyboard focus, so the pane can brighten its field.
    var focusChanged: (Bool) -> Void = { _ in }
    /// Whether a read runs on this pane now: Esc cancels it once no ghost shows.
    var readRunning = false
    /// 3b-viii ghost-text, for THIS pane: whether it is on, the request for the text at a caret
    /// with the quick-tasks generation it was built in, the window's suggestion for it (nil for a
    /// request built in an earlier generation), and the release of a request no longer wanted.
    var ghostTextEnabled = false
    var ghostPrepare: (String, String.Index) async -> (InfillRequest, Int)? = { _, _ in nil }
    var ghostSuggest: (InfillRequest, Int) async -> String? = { _, _ in nil }
    var ghostCancel: () -> Void = {}

    static let maxLines = 6
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let keywordFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    static let commentFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    /// One line's height in `font`, measured once. (Never through the view's `layoutManager`: on a
    /// TextKit 2 view that call drops it to TextKit 1.)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    static let ink = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 1)
    /// What untyped text and a Mongo line are drawn at: the identifier step.
    static let plainOpacity = 0.85
    /// A ghost suggestion and its pending dot: never in the text storage.
    static let ghostInk = NSColor(red: 232 / 255, green: 236 / 255, blue: 246 / 255, alpha: 0.34)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = QueryLineTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        context.coordinator.textView = textView
        textView.isRichText = false
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
        let plain = Self.ink.withAlphaComponent(Self.plainOpacity)
        textView.font = Self.font
        textView.textColor = plain
        textView.insertionPointColor = plain
        textView.typingAttributes = [.font: Self.font, .foregroundColor: plain]
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        Self.applyStyle(to: textView.textStorage, dialect: dialect)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.setAccessibilityIdentifier(identifier)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let dialectChanged = coordinator.parent.dialect != dialect
        coordinator.parent = self
        guard let textView = scroll.documentView as? QueryLineTextView else { return }
        // Ruling 15: only when it changed.
        if textView.accessibilityIdentifier() != identifier {
            textView.setAccessibilityIdentifier(identifier)
        }
        // An outside change: a sort, a page, the agent, a restore. Never mid-composition —
        // half a composition is not yet text the binding has heard about.
        if textView.string != text, !textView.hasMarkedText() {
            let caret = min(textView.selectedRange().location, (text as NSString).length)
            textView.string = text
            Self.applyStyle(to: textView.textStorage, dialect: dialect)
            let focused = textView.window?.firstResponder === textView
            textView.setSelectedRange(
                NSRange(location: focused ? caret : (text as NSString).length, length: 0))
            // Ruling 12: the stack names ranges in the text just replaced.
            textView.clearUndo()
        } else if dialectChanged {
            Self.applyStyle(to: textView.textStorage, dialect: dialect)
        }
        // Ghost-text switched off: drop what shows and what is pending.
        if !ghostTextEnabled { coordinator.refreshGhost() }
        if coordinator.formatSeen != formatRequest {
            coordinator.formatSeen = formatRequest
            // A turn later: formatting writes the binding and the "not formatted" line, and
            // neither may change during this view update.
            DispatchQueue.main.async { [weak coordinator] in coordinator?.format() }
        }
    }

    /// One line empty, then the text's own wrapped height, measured on a styled copy (never the
    /// live view). Capped at six lines; past that the line scrolls.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        let padding = (nsView.documentView as? NSTextView)?.textContainer?.lineFragmentPadding ?? 5
        let line = Self.lineHeight
        let measured = NSMutableAttributedString(
            string: text, attributes: [.font: Self.font])
        Self.applyStyle(to: measured, dialect: dialect)
        // A trailing newline still owns a line.
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
        let cap = line * CGFloat(Self.maxLines)
        return CGSize(width: width, height: ceil(min(max(ceil(wrapped.height), line), cap)))
    }

    /// Font and ink for every token of `storage`'s string, by `SQLStyle`: attributes only, inside
    /// one editing pass, so no character moves and no undo is registered. A Mongo line is
    /// drawn plain at the identifier step.
    static func applyStyle(to storage: NSMutableAttributedString?, dialect: QueryDialect) {
        guard let storage else { return }
        let string = storage.string
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(
            [.font: font, .foregroundColor: ink.withAlphaComponent(plainOpacity)], range: all)
        guard dialect == .sql else { return }
        for token in SQLTokenizer.tokenize(string) where token.kind != .whitespace {
            let style = SQLStyle.style(for: token.kind)
            let face = style.medium ? keywordFont : style.italic ? commentFont : font
            storage.setAttributes(
                [.font: face, .foregroundColor: ink.withAlphaComponent(style.opacity)],
                range: NSRange(token.range, in: string))
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QueryLineEditor
        weak var textView: QueryLineTextView?
        /// The last `formatRequest` acted on; it starts at the first one handed, so appearing
        /// formats nothing.
        var formatSeen: Int

        init(_ parent: QueryLineEditor) {
            self.parent = parent
            formatSeen = parent.formatRequest
        }

        /// Every edit: the binding hears it and the line is restyled (the pane clears the "not
        /// formatted" line off the binding's change). **Not while text is marked**: half a composition is not the query yet, and
        /// restyling would wipe its marked underline. The commit reports it.
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? QueryLineTextView, !view.hasMarkedText()
            else { return }
            parent.text = view.string
            QueryLineEditor.applyStyle(to: view.textStorage, dialect: parent.dialect)
            refreshGhost()
        }

        /// A caret move drops the ghost and may ask anew (typing moves it too; the same text and
        /// caret keep the request already made).
        func textViewDidChangeSelection(_ notification: Notification) {
            refreshGhost()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    // Through the text system, so it is typed: undoable and reported.
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                parent.run(textView.string)
                return true
            case #selector(NSResponder.insertTab(_:)):
                switch queryLineGhostKey(.tab, ghostShowing: ghostShowing, readRunning: parent.readRunning) {
                case .accept:
                    acceptGhost()
                default:
                    // Tab leaves the line, as the TextField it replaced did.
                    textView.window?.selectNextKeyView(nil)
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc drops a ghost first, then cancels a running read, then leaves the line. The
                // text stays either way (Interaction Rule 2). Every Esc also drops what is pending,
                // so no suggestion lands after it (Rule 4).
                let decision = queryLineGhostKey(.escape, ghostShowing: ghostShowing, readRunning: parent.readRunning)
                if queryLineKeyDropsGhost(.escape) { dismissGhost() }
                switch decision {
                case .dismiss:
                    return true
                case .cancelRead:
                    if parent.cancel() { return true }
                default:
                    break
                }
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        // MARK: Ghost-text (3b-viii)

        /// The text and caret (UTF-16) the request in flight, or the ghost showing, was made at.
        private var ghostAt: (text: String, caret: Int)?
        private var ghostTask: Task<Void, Never>?
        private var ghostOrder = GhostRequestOrder()
        private var ghostId = 0
        /// A dismissed ghost stays gone until the text or caret moves.
        private var ghostDismissedAt: (text: String, caret: Int)?
        private var pulseStart: Timer?
        private var pulse: Timer?

        var ghostShowing: Bool { textView?.ghost != nil }

        /// Every text or caret change: a ghost made for other text or another caret goes, a request
        /// for them is released, and the line asks again when the caret ends its line (Ruling R2).
        /// The same text and caret keep what is pending or showing.
        func refreshGhost() {
            guard let textView else { return }
            let range = textView.selectedRange()
            let here = (text: textView.string, caret: range.location)
            let wanted = parent.ghostTextEnabled && range.length == 0 && !textView.hasMarkedText()
                && textView.window?.firstResponder === textView
                && !(ghostDismissedAt.map { $0 == here } ?? false)
                && Self.caret(in: here.text, utf16: here.caret).map {
                    queryLineAsksForGhost(text: here.text, caret: $0)
                } == true
            if wanted, let at = ghostAt, at == here { return }
            dropGhost()
            if ghostDismissedAt.map({ $0 != here }) ?? false { ghostDismissedAt = nil }
            guard wanted, let caret = Self.caret(in: here.text, utf16: here.caret) else { return }
            ask(text: here.text, caret: caret, at: here)
        }

        /// Drops what shows and releases what is pending.
        func dropGhost() {
            if ghostTask != nil {
                ghostTask?.cancel()
                ghostTask = nil
                // A late cancel of an older request must not drop a newer one (`GhostRequestOrder`).
                if ghostOrder.cancel(ghostId) { parent.ghostCancel() }
            }
            ghostAt = nil
            stopPulse()
            if textView?.ghost != nil {
                textView?.ghost = nil
                textView?.needsDisplay = true
            }
        }

        private func ask(text: String, caret: String.Index, at here: (text: String, caret: Int)) {
            ghostId += 1
            let id = ghostId
            ghostAt = here
            let multiline = queryLineGhostIsMultiline(text: text, caret: caret)
            let prepare = parent.ghostPrepare
            let suggest = parent.ghostSuggest
            startPulse()
            ghostTask = Task { @MainActor [weak self] in
                let prepared = await prepare(text, caret)
                guard let self, let prepared, !Task.isCancelled, self.ghostOrder.admit(id) else {
                    // Nothing was asked: the same text and caret may ask again.
                    if let self, id == self.ghostId { self.ghostAt = nil }
                    self?.settle(id)
                    return
                }
                var request = prepared.0
                // Not at the end of the whole text: one line only, asked and shown.
                if !multiline { request.multiline = false }
                let suggestion = await suggest(request, prepared.1)
                // Only onto the text and caret it was asked for: a newer request owns the line.
                guard !Task.isCancelled, id == self.ghostId, let view = self.textView,
                      let at = self.ghostAt, at == here,
                      view.string == here.text, view.selectedRange() == NSRange(location: here.caret, length: 0)
                else { return }
                self.settle(id)
                guard let suggestion, let shown = queryLineGhostShown(suggestion, multiline: multiline)
                else { return }
                view.ghost = shown
                view.needsDisplay = true
            }
        }

        /// The request `id` came back (or never went): no longer pending.
        private func settle(_ id: Int) {
            guard id == ghostId else { return }
            ghostTask = nil
            stopPulse()
        }

        /// Tab: the ghost goes in through the text system at the caret, so it is typed — one undo
        /// step, reported to the binding — and the line may ask again from its end.
        private func acceptGhost() {
            guard let textView, let ghost = textView.ghost else { return }
            dropGhost()
            textView.breakUndoCoalescing()
            textView.insertText(ghost, replacementRange: textView.selectedRange())
            textView.breakUndoCoalescing()
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        /// Esc: the ghost goes and is not asked for again until the text or caret moves.
        private func dismissGhost() {
            guard let textView else { return }
            ghostDismissedAt = (textView.string, textView.selectedRange().location)
            dropGhost()
        }

        /// After 400 ms with no reply, a dot pulses at the caret until the reply or a cancel.
        private func startPulse() {
            stopPulse()
            pulseStart = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.textView else { return }
                    view.pendingDot = true
                    view.needsDisplay = true
                    self.pulse = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak view] _ in
                        MainActor.assumeIsolated {
                            guard let view, let shown = view.pendingDot else { return }
                            view.pendingDot = !shown
                            view.needsDisplay = true
                        }
                    }
                }
            }
        }

        private func stopPulse() {
            pulseStart?.invalidate()
            pulseStart = nil
            pulse?.invalidate()
            pulse = nil
            if textView?.pendingDot != nil {
                textView?.pendingDot = nil
                textView?.needsDisplay = true
            }
        }

        private static func caret(in text: String, utf16: Int) -> String.Index? {
            guard utf16 >= 0, utf16 <= text.utf16.count else { return nil }
            let index = String.Index(utf16Offset: utf16, in: text)
            return index.samePosition(in: text.unicodeScalars) == nil ? nil : index
        }

        /// Format: whitespace only, or nothing and the reason. The whole string is replaced as
        /// ONE undo step, and the caret stays on the token it sat on.
        func format() {
            guard let textView, let storage = textView.textStorage else { return }
            // Half a composition is not the query yet.
            guard !textView.hasMarkedText() else { return }
            let old = textView.string
            switch SQLFormat.format(old, dialect: parent.dialect) {
            case .formatted(let new):
                // Already formatted: nothing to do. The binding's change clears any reason.
                guard new != old else { return }
                let caret = SQLFormat.mapCaret(textView.selectedRange().location, from: old, to: new)
                let all = NSRange(location: 0, length: storage.length)
                textView.breakUndoCoalescing()
                guard textView.shouldChangeText(in: all, replacementString: new) else { return }
                storage.replaceCharacters(in: all, with: new)
                textView.didChangeText()
                textView.breakUndoCoalescing()
                textView.setSelectedRange(
                    NSRange(location: min(caret, (new as NSString).length), length: 0))
                textView.scrollRangeToVisible(textView.selectedRange())
            case .unchanged(let reason):
                parent.reportFormat(reason)
            }
        }
    }
}

/// The text view the query line draws.
final class QueryLineTextView: NSTextView {
    weak var coordinator: QueryLineEditor.Coordinator?
    /// 3b-viii: the suggestion drawn after the caret. Drawn over the text, never in its storage,
    /// so `string`, undo and the agent never see it.
    var ghost: String?
    /// While a suggestion is pending past 400 ms: whether the pulsing dot is lit (nil: no dot).
    var pendingDot: Bool?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard ghost != nil || pendingDot == true, let caret = caretRect() else { return }
        if pendingDot == true {
            QueryLineEditor.ghostInk.setFill()
            NSBezierPath(ovalIn: NSRect(x: caret.maxX + 2, y: caret.midY - 1, width: 2, height: 2)).fill()
        }
        guard let ghost else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: QueryLineEditor.font, .foregroundColor: QueryLineEditor.ghostInk,
        ]
        let lineHeight = QueryLineEditor.lineHeight
        let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        // The first line beside the caret; any further lines below it at the line height.
        for (n, line) in ghost.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let origin = NSPoint(x: n == 0 ? caret.maxX : left, y: caret.minY + CGFloat(n) * lineHeight)
            NSAttributedString(string: String(line), attributes: attributes).draw(at: origin)
        }
    }

    /// The caret's rect in this view's coordinates.
    private func caretRect() -> NSRect? {
        guard let window else { return nil }
        let at = NSRange(location: selectedRange().location, length: 0)
        let screen = firstRect(forCharacterRange: at, actualRange: nil)
        guard screen != .zero else { return nil }
        return convert(window.convertFromScreen(screen), from: nil)
    }

    /// Ruling 12: the text storage is where typing registers its undo, and the view registers
    /// its own. Both go — and nothing else in the window's undo stack.
    func clearUndo() {
        if let storage = textStorage { undoManager?.removeAllActions(withTarget: storage) }
        undoManager?.removeAllActions(withTarget: self)
    }

    /// ⌥⇧F formats, whether it arrives as a key equivalent or as a plain key down. Only the
    /// focused line: `performKeyEquivalent` is offered to every view in the window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isFormatKey(event) {
            coordinator?.format()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.parent.focusChanged(true)
            coordinator?.refreshGhost()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            coordinator?.parent.focusChanged(false)
            // A line without focus shows no ghost and waits on none.
            coordinator?.dropGhost()
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if Self.isFormatKey(event), !hasMarkedText() {
            coordinator?.format()
            return
        }
        super.keyDown(with: event)
    }

    /// By key position, not character, so ⌥⇧F works on non-Latin layouts too.
    private static func isFormatKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags
        return QueryLineKeys.isFormat(keyCode: event.keyCode, option: flags.contains(.option),
                                      shift: flags.contains(.shift), command: flags.contains(.command),
                                      control: flags.contains(.control))
    }
}
