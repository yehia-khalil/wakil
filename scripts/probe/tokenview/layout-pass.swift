// scripts/probe/tokenview/layout-pass.swift — why a token's chip was not drawn (live look at
// 242802f: the space reserved, no chip). No GUI: a borderless window at (-10000, -10000), never
// ordered in, activation policy `.prohibited`.
//
//   swiftc -parse-as-library -o "$OUT/layout-pass" scripts/probe/tokenview/layout-pass.swift && "$OUT/layout-pass"
//
// TextKit 2 asks for an attachment's view provider while DRAWING the line, and loads the view
// only in that line view's `layout()`, which nothing re-runs after the draw. Each pass below is
// a display cycle (layout, then draw). Without a nudge no view is ever placed; with the text
// view marked for layout once (what `ApiTokenAttachment.viewProvider` does), it is placed on the
// next pass. Exit 0 when exactly that holds.
import AppKit

final class Attachment: NSTextAttachment {
    var nudge = false
    var asked = 0
    init() {
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        bounds = CGRect(x: 0, y: -4, width: 40, height: 16)
    }
    required init?(coder: NSCoder) { nil }
    // IMG=clear: answer a clear image without asking super — no provider is ever asked, no chip.
    // IMG=super: ask super, then answer clear — the provider is asked and the chip placed
    // (ApiTokenAttachment). Unset: the stock image (a white document icon).
    static let clear = NSImage(size: CGSize(width: 1, height: 1))
    override func image(for b: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?) -> NSImage? {
        let mode = ProcessInfo.processInfo.environment["IMG"] ?? "none"
        if mode == "none" { return super.image(for: b, attributes: attributes, location: location, textContainer: textContainer) }
        if mode == "super" { _ = super.image(for: b, attributes: attributes, location: location, textContainer: textContainer) }
        return Self.clear
    }
    override func viewProvider(
        for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        asked += 1
        let provider = Provider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        if nudge {
            let parent = parentView
            DispatchQueue.main.async { parent?.needsLayout = true }
        }
        return provider
    }
}

final class Chip: NSView {}

final class Provider: NSTextAttachmentViewProvider {
    override func loadView() { view = Chip(frame: CGRect(x: 0, y: 0, width: 40, height: 16)) }
}

@MainActor func placed(nudge: Bool) -> (asked: Int, views: [Int]) {
    let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 100),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
    window.contentView = content
    let text = NSTextView(usingTextLayoutManager: true)
    text.frame = CGRect(x: 0, y: 40, width: 400, height: 40)
    text.isRichText = true
    content.addSubview(text)
    func pass() {
        content.layoutSubtreeIfNeeded()
        content.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    func chips(_ view: NSView) -> Int { (view is Chip ? 1 : 0) + view.subviews.map(chips).reduce(0, +) }
    // The window is up before the token arrives, as an outside take or `+ hole` is.
    pass()
    let attachment = Attachment()
    attachment.nudge = nudge
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let string = NSMutableAttributedString(string: "/a/", attributes: [.font: font])
    string.append(NSAttributedString(attachment: attachment))
    string.append(NSAttributedString(string: "/b", attributes: [.font: font]))
    text.textStorage?.setAttributedString(string)
    var views: [Int] = []
    for _ in 0..<3 {
        pass()
        views.append(chips(text))
    }
    return (attachment.asked, views)
}

@main enum LayoutPass {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let bare = placed(nudge: false)
        let nudged = placed(nudge: true)
        print("without the nudge: provider asked \(bare.asked)x, chips placed per pass \(bare.views)")
        print("with the nudge:    provider asked \(nudged.asked)x, chips placed per pass \(nudged.views)")
        let ok = bare.asked > 0 && bare.views.allSatisfy { $0 == 0 } && nudged.views.allSatisfy { $0 == 1 }
        print(ok
            ? "PASS: the provider is asked during draw, and only a layout pass after it places the view"
            : "CHANGED: TextKit 2 no longer behaves as measured on 2026-10-05; re-check the nudge")
        exit(ok ? 0 : 1)
    }
}
