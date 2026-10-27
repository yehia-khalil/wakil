import AppKit
import SwiftUI
import WakilKit

/// Terminal output the operator can select, copy and ⌘-click a link in: an `NSTextView`, read-only,
/// drawing the rows' runs as `terminalRunText` draws them in SwiftUI.
///
/// **Why not `Text` with `.textSelection(.enabled)`** (3c-iii walk): SwiftUI's selectable text takes
/// every click on itself, so a link's `openURL` never fires and ⌘-click did nothing. With selection
/// off the click arrived, which proved it. Turning selection off while ⌘ is held would drop the
/// selection the moment ⌘ goes down, before ⌘C. `NSTextView` selects, copies and reports a link
/// click (`textView(_:clickedOnLink:at:)`) at once.
///
/// **It never takes the keyboard**, so typing after a click or a selection still goes to the shell:
/// it refuses first responder, copies its own selection on ⌘C (a key equivalent reaches every view,
/// first responder or not) and from its own menu, and a selection started in one clears the last.
///
/// **A link click goes to the environment's `openURL`**, which in a terminal pane is
/// `TerminalPane.openLinkAction`: ⌘ opens it in Wakil, ⌘⌥ in the system browser, and a plain click
/// is discarded. It reads the modifiers from the click it is called during, as for `Text`'s links.
///
/// `rows` mode keeps each row on one line at `lineHeight` and clips it (the live grid, which the
/// pty already sized to the pane); `wrapping` wraps at the view's width and shows at most
/// `maximumLines` lines, the last cut with `…` (a block's output, as `.lineLimit` did).
struct TerminalSelectableText: NSViewRepresentable {
    enum Layout: Equatable {
        case rows(lineHeight: CGFloat)
        case wrapping(maximumLines: Int)
    }

    let text: NSAttributedString
    let layout: Layout

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = TerminalOutputTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        // Links draw as the runs say (their own colour and faint underline), not the system's blue.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        guard let container = view.textContainer, let storage = view.textStorage else { return }
        switch layout {
        case .rows:
            container.widthTracksTextView = false
            container.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            container.maximumNumberOfLines = 0
        case .wrapping(let maximumLines):
            container.widthTracksTextView = true
            container.maximumNumberOfLines = maximumLines
            container.lineBreakMode = .byTruncatingTail
        }
        if !storage.isEqual(to: text) {
            // A redraw keeps the operator's selection where the text under it is unchanged.
            let selection = view.selectedRanges
            storage.setAttributedString(text)
            let length = storage.length
            view.selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length),
                                              length: min(range.length, length - min(range.location, length))))
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let manager = view.layoutManager else { return nil }
        let width = proposal.width ?? 10_000
        if case .wrapping = layout {
            container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let height: CGFloat
        if case .rows(let lineHeight) = layout {
            height = CGFloat(max(1, text.string.split(separator: "\n", omittingEmptySubsequences: false).count)) * lineHeight
        } else {
            height = ceil(used.height)
        }
        return CGSize(width: proposal.width ?? ceil(used.width), height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url { openURL?(url) }
            // Handled either way: a plain click on a link is the selection's, never the system's.
            return true
        }
    }
}

/// `TerminalSelectableText`'s view: selects and copies without ever holding the keyboard.
final class TerminalOutputTextView: NSTextView {
    /// The view the last selection was made in, cleared when another one starts.
    private static weak var selecting: TerminalOutputTextView?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let last = Self.selecting, last !== self { last.setSelectedRange(NSRange(location: 0, length: 0)) }
        Self.selecting = self
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command, event.charactersIgnoringModifiers == "c", selectedRange().length > 0,
              window?.isKeyWindow == true
        else { return super.performKeyEquivalent(with: event) }
        copy(nil)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = selectedRange().length > 0
        menu.autoenablesItems = false
        menu.addItem(item)
        return menu
    }
}

/// `lines` as one attributed string for `TerminalSelectableText`, a `"\n"` between rows: each row
/// through `TerminalLinks.split`, so a URL carries `.link`, and each run styled as
/// `terminalRunText` styles it — the run's own colour, `dimmedDefault` for a dim run with none,
/// `defaultColor` otherwise, bold and underline; a link in its colour (`linkDefault` with none of
/// its own) with an underline at 0.35 of it. `lineHeight` fixes every line's height (the grid's rows).
func terminalAttributedLines(
    _ lines: [[TerminalStyleRun]], fontSize: CGFloat, lineHeight: CGFloat? = nil,
    defaultColor: Color, dimmedDefault: Color, linkDefault: Color
) -> NSAttributedString {
    let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let paragraph = NSMutableParagraphStyle()
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byClipping
    }
    let result = NSMutableAttributedString()
    for (index, line) in lines.enumerated() {
        if index > 0 {
            result.append(NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: paragraph]))
        }
        for piece in TerminalLinks.split(line) {
            let run = piece.run
            let (foreground, _) = run.style.resolvedColors
            var color: NSColor?
            if let foreground {
                color = NSColor(srgbRed: foreground.r, green: foreground.g, blue: foreground.b, alpha: run.style.dim ? 0.7 : 1)
            } else if run.style.dim {
                color = NSColor(dimmedDefault)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: run.style.bold ? bold : regular, .paragraphStyle: paragraph,
                .foregroundColor: color ?? NSColor(defaultColor),
            ]
            if let link = piece.link {
                let linkColor = color ?? NSColor(linkDefault)
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = linkColor.withAlphaComponent(linkColor.alphaComponent * 0.35)
            } else if run.style.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
    }
    return result
}
