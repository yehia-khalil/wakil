import AppKit
import WakilKit
import SwiftUI

/// The composer (2d-ii, prototype variant A): one slim bar on the bottom
/// edge. Typed and spoken text land in the same field; Return sends,
/// ⇧Return breaks a line; the hints live inside the bar. No Send button.
struct ComposerBar: View {
    let composer: ComposerModel
    /// Esc that listening did not consume goes here (the thread's fold).
    let onEscapeUnconsumed: () -> Bool

    @State private var host: NSWindow?

    private let coolWhite = Color(red: 0.910, green: 0.925, blue: 0.965)
    private let violet = Color(red: 0.620, green: 0.510, blue: 1.0)

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 1).fill(violet).frame(width: 1.5, height: 18)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            hint
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.02, green: 0.024, blue: 0.047).opacity(0.82)))
        .accessibilityElement(children: .contain)   // keep the id off the children
        .accessibilityIdentifier("window.composer.bar")
        .background(WindowReader(window: $host))
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
        .task {
            while !Task.isCancelled {
                if composer.machine.phase != .idle { composer.tick() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The field stays mounted through a hold (its undo stack and focus
    /// survive); the hearing/notice text is drawn over it.
    @ViewBuilder private var content: some View {
        let listening: Bool = { if case .draft = composer.bar { return false }; return true }()
        ZStack(alignment: .leading) {
            // The id `window.composer` is set on the NSTextView inside the field,
            // not here: a second copy on the scroll view makes the id ambiguous.
            ComposerField(composer: composer)
                .opacity(listening ? 0 : 1)
                .allowsHitTesting(!listening)
                .accessibilityHidden(listening)
            if !listening && composer.draft.isEmpty {
                Text("Ask, or name what to open")
                    .font(.system(size: 14))
                    .foregroundStyle(coolWhite.opacity(0.32))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            switch composer.bar {
            case .draft:
                EmptyView()
            case .hearing(let settled, let volatile, _):
                (Text(settled).foregroundColor(coolWhite.opacity(0.90))
                 + Text(settled.isEmpty || volatile.isEmpty ? volatile : " " + volatile)
                    .foregroundColor(coolWhite.opacity(0.45)))
                    .font(.system(size: 14))
                    .lineLimit(6)
                    .accessibilityIdentifier("window.composer.heard")
            case .notice(let sentence, _):
                Text(sentence)
                    .font(.system(size: 14))
                    .foregroundStyle(coolWhite.opacity(0.62))
                    .accessibilityIdentifier("window.composer.heard")
            }
        }
    }

    private var hint: some View {
        let text: String
        switch composer.bar {
        case .draft(let h), .hearing(_, _, let h), .notice(_, let h): text = h
        }
        let landed = text == ComposerBarContent.landedHint
        return Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.7)
            .foregroundStyle(landed ? violet.opacity(0.85) : coolWhite.opacity(0.50))
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("window.composer.hint")
    }

    // MARK: - ⌥, other input, Esc, deactivation

    @State private var monitor: Any?
    @State private var resignObserver: Any?
    @State private var resignKeyObserver: Any?
    /// The monitor's own bookkeeping: the modifiers at the last flagsChanged,
    /// and whether this ⌥ hold has been spoiled by a chord, key or click.
    /// A reference box, because the monitor closure outlives this struct value.
    private final class HoldState: @unchecked Sendable { var flags: NSEvent.ModifierFlags = []; var spoiled = false }
    @State private var hold = HoldState()

    /// True when the key window's first responder is the composer's field, or
    /// nothing in particular (no responder, the window, or its content view).
    private func escapeBelongsToComposer(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return true }
        if responder === window || responder === window.contentView { return true }
        if let text = responder as? NSTextView,
           text.accessibilityIdentifier() == "window.composer" { return true }
        return false
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let hold = self.hold
        // Both the monitor closure and the observers run on the main thread;
        // `MainActor.assumeIsolated` states that to Swift 6 so the `@MainActor`
        // model can be called.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            // `NSEvent` is not `Sendable`, so the closure hands back only
            // whether Esc was consumed and returns the event itself outside.
            let swallowed: Bool = MainActor.assumeIsolated {
                // Review focus 1: only the key window's composer listens.
                guard let host, event.window === host, host.isKeyWindow else { return false }
                switch event.type {
                case .flagsChanged:
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                    let previous = hold.flags
                    hold.flags = flags
                    if flags.isEmpty {
                        hold.spoiled = false
                        composer.optionUp()
                    } else if flags == .option, previous.isEmpty, !hold.spoiled {
                        composer.optionDown()          // arm only on empty -> ⌥
                    } else if flags != .option || previous != .option {
                        hold.spoiled = true            // a chord: spoiled until all are released
                        composer.otherInput()
                    }
                    return false
                case .keyDown:
                    if !hold.flags.isEmpty { hold.spoiled = true }
                    if event.keyCode == 53 {   // Esc
                        if composer.escape() { return true }
                        // The thread folds on any unconsumed Esc, but the event is
                        // swallowed only when focus is the composer or nowhere:
                        // otherwise another surface (org plane, palette, API pane,
                        // terminal) owns Esc and must still receive it (rule 6).
                        let folded = onEscapeUnconsumed()
                        return folded && escapeBelongsToComposer(host)
                    }
                    // Words already heard: this key must not type into the field
                    // behind the bar. Nothing heard yet: the hold is cancelled
                    // and the key passes through.
                    return composer.otherInput()
                default:
                    // A click: never swallowed.
                    if !hold.flags.isEmpty { hold.spoiled = true }
                    composer.otherInput()
                    return false
                }
            }
            return swallowed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { hold.flags = []; hold.spoiled = false; composer.resigned() } }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { note in
            // `Notification` is not `Sendable`: take the window's identity out
            // before entering the isolated block.
            let resigned = note.object as? NSWindow
            let id = resigned.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let host, id == ObjectIdentifier(host) else { return }
                hold.flags = []; hold.spoiled = false
                composer.resigned()
            }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        monitor = nil
        resignObserver = nil
        resignKeyObserver = nil
        hold.flags = []
        hold.spoiled = false
        composer.resigned()
    }
}

/// Finds the hosting `NSWindow`, so a key monitor can ignore other windows — the composer's,
/// and the palette's (`PalettePlane`).
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    /// Reports its window whenever it actually moves into one. Reading
    /// `view.window` once, a run loop after `makeNSView`, sometimes read it
    /// before the view was in a window, and nothing read it again — so the
    /// bar never knew its host and its key-window guard refused every ⌥
    /// (measured on the 2d-ii walk: `host == nil` on a launch where ⌥ was dead).
    final class ReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindow = { [binding = $window] found in
            DispatchQueue.main.async { if binding.wrappedValue !== found { binding.wrappedValue = found } }
        }
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        if window !== nsView.window, let found = nsView.window { DispatchQueue.main.async { window = found } }
    }
}

/// The editable line: an `NSTextView` that wraps, grows to six lines,
/// sends on Return and breaks a line on ⇧Return, and reports its caret in
/// UTF-16 so speech lands where the operator left it.
struct ComposerField: NSViewRepresentable {
    let composer: ComposerModel

    private static let font = NSFont.systemFont(ofSize: 14)
    private static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    func makeCoordinator() -> Coordinator { Coordinator(composer: composer) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let text = scroll.documentView as! NSTextView
        text.delegate = context.coordinator
        text.font = Self.font
        text.textColor = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 0.92)
        text.insertionPointColor = NSColor(red: 0.620, green: 0.510, blue: 1.0, alpha: 1)
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        // No Writing Tools affordance. A selection in a stock NSTextView
        // (⌘A, say) raises it as a separate panel window, which then is the
        // app's first accessibility window: tree readers and resolvers that
        // read windows.first see only "Writing Tools", and every control on
        // the canvas goes missing (api-paste-curl-hotkey: api.path matched
        // nothing). The composer is a command line; the TextField it replaced
        // never offered one.
        if #available(macOS 15.0, *) { text.writingToolsBehavior = .none }
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.setAccessibilityPlaceholderValue("Ask, or name what to open")
        text.setAccessibilityIdentifier("window.composer")   // the editable view itself, for AXFocused/AXValue
        context.coordinator.text = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = context.coordinator.text else { return }
        if text.string != composer.draft {
            // One undoable edit, not an assignment to `string`, which would
            // drop the undo stack and leave stale undo ranges.
            let whole = NSRange(location: 0, length: (text.string as NSString).length)
            if text.shouldChangeText(in: whole, replacementString: composer.draft) {
                context.coordinator.applying = true
                text.replaceCharacters(in: whole, with: composer.draft)
                text.didChangeText()
                context.coordinator.applying = false
            }
            let length = (composer.draft as NSString).length
            text.setSelectedRange(NSRange(location: min(max(composer.caret, 0), length), length: 0))
        }
        if context.coordinator.focused != composer.focusToken {
            context.coordinator.focused = composer.focusToken
            text.window?.makeFirstResponder(text)            // rule 3: landed input arrives focused
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let text = context.coordinator.text, let container = text.textContainer,
              let layout = text.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let lines = max(1, min(6, Int(ceil(used / Self.lineHeight))))
        return CGSize(width: proposal.width ?? 400, height: CGFloat(lines) * Self.lineHeight)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let composer: ComposerModel
        weak var text: NSTextView?
        var focused = 0
        /// True while `updateNSView` applies the model's own draft, so the
        /// resulting delegate callbacks do not echo it back as an edit.
        var applying = false
        init(composer: ComposerModel) { self.composer = composer }

        func textDidChange(_ notification: Notification) { report() }
        func textViewDidChangeSelection(_ notification: Notification) { report() }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // An IME composition's Return confirms the composition; it is not a send.
            guard !textView.hasMarkedText() else { return false }
            if NSEvent.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // `submit()` clears the model's draft before its first await;
            // `updateNSView` then applies "" through the undoable path.
            let composer = composer
            Task { await composer.submit() }
            return true
        }

        private func report() {
            guard let text, !applying else { return }
            composer.edited(draft: text.string, caret: text.selectedRange().location)
        }
    }
}
