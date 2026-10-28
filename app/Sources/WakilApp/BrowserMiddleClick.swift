import AppKit
import SwiftUI

/// A middle-click on a vertical-column tab (3d-i walk): the tab closes, as its × does. SwiftUI has no
/// middle-click gesture, so this is a `.background` of the row: an NSView that takes no hits, so a
/// left click, a drag, the pointer's hover and the tooltip reach the row as before.
///
/// **One monitor serves every row** (`Monitor`), installed with the first row on screen and removed with
/// the last; a row answers only an `otherMouseDown` of button 2 that lands in the part of it that is
/// visible (`visibleRect`, so a row scrolled out of the column answers nothing), in its own window,
/// with nothing drawn over the canvas covering the click (`ClickShield`). It consumes the event it
/// takes; every other goes back untouched. The horizontal strip's middle-click is `PaneTabStrip`'s own
/// (`EditorTabStripMiddleClick`).
struct BrowserRowMiddleClick: NSViewRepresentable {
    /// No plane, palette or prompt is in front of the canvas.
    let enabled: Bool
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        update(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { update(view) }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) { Monitor.remove(view) }

    private func update(_ view: CatcherView) {
        view.enabled = enabled
        view.onMiddleClick = onMiddleClick
    }

    final class CatcherView: NSView {
        var enabled = false
        var onMiddleClick: (() -> Void)?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { Monitor.remove(self) } else { Monitor.add(self) }
        }

        /// Whether this row takes the middle-click.
        fileprivate func takes(_ event: NSEvent) -> Bool {
            guard event.buttonNumber == 2, enabled, let window, event.window === window,
                  !isHiddenOrHasHiddenAncestor else { return false }
            let point = convert(event.locationInWindow, from: nil)
            return visibleRect.contains(point) && !ClickShield.covers(event, in: window)
        }
    }

    @MainActor
    private enum Monitor {
        private static let rows = NSHashTable<CatcherView>.weakObjects()
        private static var token: Any?

        static func add(_ row: CatcherView) {
            rows.add(row)
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
                for row in rows.allObjects where row.takes(event) {
                    row.onMiddleClick?()
                    return nil
                }
                return event
            }
        }

        static func remove(_ row: CatcherView) {
            rows.remove(row)
            guard rows.count == 0, let token else { return }
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }
}
