import AppKit
import SwiftUI
import WebKit

/// The canvas's mouse-downs, seen before AppKit routes them (3b-v PR 8).
///
/// **Why a monitor and not a gesture.** A pane used to take focus only from a SwiftUI
/// `TapGesture` on it, and most of a pane's surface is AppKit underneath — a `ScrollView`, a
/// `Button` row, a field, Monaco's web view — which takes the mouse-down first, so the tap
/// never fired. Clicking the Settings tree left the editor focused and its keys in the file.
/// A local monitor sees every mouse-down the app receives, whatever will consume it.
///
/// **It never swallows a click**: the event is handed back unchanged, and the pane is told
/// from a `Task`, after AppKit has routed the click — so a field clicked in another pane is
/// first responder before focus moves, and the pane losing focus can tell (`EditorPane`).
///
/// Drawn as a `.background` of the surface it watches, so its bounds ARE that surface and
/// the click converts into it with no coordinate guesswork; it is flipped so `y` grows
/// downward, like `PaneFrame`. It takes no hits of its own. One per surface — the canvas, and
/// the settings pane over the Landing. The two can share the screen for the Landing's fade,
/// so `canvasMouseDown` answers only the one `sessionStarted` says is live.
struct PaneClickWatcher: NSViewRepresentable {
    /// The click in this surface's points, and whether it lands on a text input that will
    /// take the keyboard by itself. **Broad on purpose**: any `NSText` that accepts first responder (a
    /// field editor, every `NSTextView` but a terminal's output, the API pane's editors), any editable `NSTextField`, and any `WKWebView`
    /// — Monaco, Compare and Git's diffs alike, read-only or not.
    let onMouseDown: (CGPoint, Bool) -> Void

    func makeNSView(context: Context) -> WatchView {
        let view = WatchView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ view: WatchView, context: Context) { view.onMouseDown = onMouseDown }

    static func dismantleNSView(_ view: WatchView, coordinator: ()) { view.stop() }

    final class WatchView: NSView {
        var onMouseDown: ((CGPoint, Bool) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.saw(event)
                return event
            }
        }

        isolated deinit { stop() }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func saw(_ event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), !ClickShield.covers(event, in: window) else { return }
            onMouseDown?(point, Self.landsOnInput(event, in: window))
        }

        /// Whether AppKit will hand this click to something that takes the keyboard itself.
        static func landsOnInput(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let frame = window.contentView?.superview else { return false }
            var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
            while let current = view {
                // A terminal's output view selects but never takes the keyboard (it refuses it).
                if (current is NSText && current.acceptsFirstResponder) || current is WKWebView { return true }
                if let field = current as? NSTextField, field.isEditable { return true }
                view = current.superview
            }
            return false
        }
    }
}

/// Marks a surface drawn over the canvas whose clicks belong to it and focus no pane
/// underneath. A `.background` of that surface; it takes no hits of its own.
///
/// **Every surface drawn above the canvas must carry one**, or a click on it also focuses the
/// pane below — which then takes the keyboard from the control just clicked. Today: the
/// thought thread, the composer row (with the capacity cell), the context line's menus. A
/// full-window plane (org, palette, confirmation, unsaved prompt) is covered by
/// `canvasMouseDown`'s own guard instead.
struct ClickShield: NSViewRepresentable {
    func makeNSView(context: Context) -> ShieldView { ShieldView() }
    func updateNSView(_ view: ShieldView, context: Context) {}

    final class ShieldView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Whether a shield in `window` covers the click.
    static func covers(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let shield = view as? ShieldView, !shield.isHiddenOrHasHiddenAncestor,
               shield.bounds.contains(shield.convert(event.locationInWindow, from: nil)) {
                return true
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }
}
