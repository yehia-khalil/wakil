import AppKit
import SwiftUI

/// The tab strip's middle-click (3b-ii-b): ONE local monitor for the strip, not a view over every tab,
/// so nothing sits between a tab and its single click, double click (keep preview), drag or tooltip.
///
/// Drawn as a `.background` of the strip's scroll view, as `PaneClickWatcher` is of the canvas: its
/// bounds ARE the visible strip, and a click converts into it with no coordinate guesswork. Flipped,
/// so `y` grows downward like SwiftUI's. It takes no hits of its own. The monitor is installed when the
/// view joins a window and removed when it leaves or is dismantled, so a re-render never adds a second.
///
/// It acts only on a `buttonNumber == 2` mouse-down in this view's window, inside the visible strip and
/// inside a tab's span (`spans`, in the `editor.tabs` space the drop line uses, whose origin in this
/// view is `contentOrigin`); then it consumes the event. Every other event goes back untouched.
struct EditorTabStripMiddleClick: NSViewRepresentable {
    let spans: [ClosedRange<Double>]
    /// The tabs' `HStack` origin in this view's space: it moves as the strip scrolls.
    let contentOrigin: CGPoint
    /// The tabs' own height: the band a middle-click must land in.
    let height: Double
    /// No plane, palette or prompt is in front of the canvas.
    let enabled: Bool
    /// The tab at this index was middle-clicked.
    let onMiddleClick: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        update(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { update(view) }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) { view.stop() }

    private func update(_ view: CatcherView) {
        view.spans = spans
        view.contentOrigin = contentOrigin
        view.height = height
        view.enabled = enabled
        view.onMiddleClick = onMiddleClick
    }

    final class CatcherView: NSView {
        var spans: [ClosedRange<Double>] = []
        var contentOrigin: CGPoint = .zero
        var height: Double = 30
        var enabled = false
        var onMiddleClick: ((Int) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, let index = self.tab(at: event) else { return event }
                self.onMiddleClick?(index)
                return nil
            }
        }

        isolated deinit { stop() }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The tab a middle-click lands on, or nil when it is not this strip's to take.
        private func tab(at event: NSEvent) -> Int? {
            guard event.buttonNumber == 2, enabled, let window, event.window === window,
                  !isHiddenOrHasHiddenAncestor else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), !ClickShield.covers(event, in: window) else { return nil }
            let x = Double(point.x - contentOrigin.x), y = Double(point.y - contentOrigin.y)
            guard y >= 0, y < height else { return nil }
            return spans.firstIndex { $0.contains(x) }
        }
    }
}
