import AppKit
import WakilKit

/// Amendment 10a — **a token is one attachment character, and its chip is a real view.** Amber
/// on an amber tint for a hole. Ink on a cool-white tint for a bound value. Its `×` sits inside
/// the chip at its right edge (9c W4), carrying the shipped identifiers
/// `api.<key>.part.<i>.remove` / `….unbind`.
///
/// **In the accessibility tree once** (the spike, run 3). TextKit 2 leaves attachment views out
/// of the tree, so the text view lists the token views as its children (`ApiFieldTextView`),
/// each token is a group, and the group's one child is its `×`. An `NSButton` there showed up
/// TWICE — the button view as an `AXUnknown` and its cell as the `AXButton`, both carrying the
/// identifier, so a press was ambiguous. The `×` is therefore `ApiTokenClose`: one plain view
/// that is itself the button, with no cell under it.
///
/// **No identifier on the chip itself** (preflight R7, ruled after the spike): its one use was a
/// drag, and the harness cannot drag from inside a text view. A check reaches a token by
/// focusing the field and moving the caret.
final class ApiTokenAttachment: NSTextAttachment {
    let token: ApiEditorToken
    weak var editor: ApiFieldTextView?
    /// The latest view TextKit 2 made for this attachment: the one exposed (M10).
    weak var tokenView: ApiTokenView?
    private(set) var key = ""
    private(set) var index = 0
    private(set) var editable = true

    init(token: ApiEditorToken) {
        self.token = token
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        bounds = ApiTokenView.frame(for: token)
    }

    required init?(coder: NSCoder) { nil }

    @MainActor func apply(key: String, index: Int, editable: Bool) {
        self.key = key
        self.index = index
        self.editable = editable
        tokenView?.apply()
    }

    override func viewProvider(
        for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = ApiTokenProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        // **One more layout pass, or the chip is never placed** (the live look at 242802f: the
        // token's space reserved, no chip). TextKit 2 asks for this provider while DRAWING the
        // line (`_NSTextViewportElementView drawRect:` → `NSTextAttachment imageForBounds:`), and
        // from then on draws no image there. It loads the provider's view and adds it only in
        // that line view's `layout()` — and nothing marks the line for layout after the draw. So
        // a token that arrives in a window already on screen (an outside take, `+ hole`, a paste)
        // stays a blank gap until something else lays the line out. (The spike's token was in
        // the text before its window appeared, and presumably the window's showing and
        // activation laid the line out again.) Measured off-screen by
        // `scripts/probe/tokenview/layout-pass.swift`: no views after any number of passes
        // without this, one view on the next pass with it.
        //
        // Asking the text view for layout lays out its viewport, and with it the line, which
        // then loads and places the view. Next turn, because this runs inside a draw.
        let parent = parentView
        DispatchQueue.main.async { parent?.needsLayout = true }
        return provider
    }

    /// **Nothing drawn under the chip** (the live look at 88208f5: a white cover over the hole).
    /// An attachment with no contents answers the stock `public.data` document icon — a white
    /// page — and the line draws it stretched to `bounds`, where it shows through the chip's
    /// tint. The chip is the view; the image is clear. **`super` is still asked**: TextKit 2
    /// asks for the view provider from inside it, and without that call no chip is ever made
    /// (measured, `scripts/probe/tokenview/layout-pass.swift`).
    override func image(
        for imageBounds: CGRect, attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSImage? {
        _ = super.image(for: imageBounds, attributes: attributes, location: location, textContainer: textContainer)
        return Self.clear
    }

    override func image(
        forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int
    ) -> NSImage? {
        _ = super.image(forBounds: imageBounds, textContainer: textContainer, characterIndex: charIndex)
        return Self.clear
    }

    private static let clear = NSImage(size: CGSize(width: 1, height: 1))
}

final class ApiTokenProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let found = textAttachment as? ApiTokenAttachment else {
            super.loadView()
            return
        }
        // TextKit 2 asks for the view on the main thread, laying out the text view's viewport,
        // and the attachment is only ever touched there.
        nonisolated(unsafe) let attachment = found
        view = MainActor.assumeIsolated {
            let view = ApiTokenView(attachment: attachment)
            attachment.tokenView = view
            attachment.editor?.tokenViews.add(view)
            return view
        }
    }
}

final class ApiTokenView: NSView {
    static let amber = NSColor(red: 0.910, green: 0.706, blue: 0.353, alpha: 1)
    static let coolWhite = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 1)
    nonisolated static let closeWidth: CGFloat = 12

    /// The chip's size: its name, 6 leading, 4 between, the `×`, 4 trailing. Its baseline sits
    /// on the line's.
    nonisolated static func frame(for token: ApiEditorToken) -> CGRect {
        let font = ApiFieldEditor.font
        let name = ceil((token.name as NSString).size(withAttributes: [.font: font]).width)
        let height = ceil(font.ascender - font.descender) + 2
        return CGRect(x: 0, y: font.descender - 1, width: 6 + name + 4 + closeWidth + 4, height: height)
    }

    let attachment: ApiTokenAttachment
    private let label: NSTextField
    private let close: ApiTokenClose

    init(attachment: ApiTokenAttachment) {
        self.attachment = attachment
        let tone = attachment.token.isBound ? Self.coolWhite.withAlphaComponent(0.85) : Self.amber
        label = NSTextField(labelWithString: attachment.token.name)
        label.font = ApiFieldEditor.font
        label.textColor = tone
        // Drawn, not read: the group's label says the name once.
        label.setAccessibilityElement(false)
        close = ApiTokenClose(tone: tone.withAlphaComponent(0.55))
        super.init(frame: Self.frame(for: attachment.token))
        close.press = { [weak self] in
            guard let self else { return }
            self.attachment.editor?.tokenAct(self.attachment)
        }
        label.frame = CGRect(
            x: 6, y: 1, width: bounds.width - 6 - 4 - Self.closeWidth - 4, height: bounds.height - 2)
        close.frame = CGRect(
            x: bounds.width - 4 - Self.closeWidth, y: 1, width: Self.closeWidth, height: bounds.height - 2)
        addSubview(label)
        addSubview(close)
        apply()
    }

    required init?(coder: NSCoder) { nil }

    /// The `×`'s identifier, set only when it changes (Ruling 15) — a view keeps it for its life
    /// (M10). A hole's `×` is not drawn on the `&`-locked path (8d); a bound value's always is
    /// (`apiTokenCloseShown`).
    func apply() {
        let key = attachment.key
        let index = attachment.index
        let closeId = attachment.token.isBound
            ? "api.\(key).part.\(index).unbind" : "api.\(key).part.\(index).remove"
        if close.accessibilityIdentifier() != closeId { close.setAccessibilityIdentifier(closeId) }
        let hidden = !apiTokenCloseShown(editable: attachment.editable, isBound: attachment.token.isBound)
        if close.isHidden != hidden { close.isHidden = hidden }
    }

    // A group named for its token, whose one child is its `×` (when drawn). Its parent is the
    // text view that lists it; nothing here asks the text view back (the spike's run-2 loop).
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { attachment.token.name }
    override func accessibilityChildren() -> [Any]? { close.isHidden ? [] : [close] }
    override func accessibilityParent() -> Any? { attachment.editor ?? super.accessibilityParent() }

    override func mouseDown(with event: NSEvent) { attachment.editor?.selectToken(attachment) }

    override func mouseDragged(with event: NSEvent) {
        _ = attachment.editor?.dragSelection(with: event, offset: .zero, slideBack: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = attachment.token.isBound
            ? Self.coolWhite.withAlphaComponent(0.10) : Self.amber.withAlphaComponent(0.10)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

/// A token's `×`: **one view that is the button**, so the accessibility tree holds it once and
/// `AXPress` reaches it (the spike, run 3: an `NSButton` here was two elements). A click is a
/// press released inside it.
final class ApiTokenClose: NSView {
    var press: () -> Void = {}
    private let tone: NSColor
    private var armed = false

    init(tone: NSColor) {
        self.tone = tone
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "×" }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { armed = true }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        defer { armed = false }
        guard armed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let glyph = NSAttributedString(string: "×", attributes: [.font: font, .foregroundColor: tone])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

