import AppKit
import QuartzCore
import WakilKit
import SwiftUI

/// Hosts `DataSurface` offscreen over a synthetic result and prints what it
/// costs: first-layout time, document height against the exact value, a
/// 10pt-per-step scroll pass against the 8.33ms a 120fps frame allows, and a
/// deep scroll pass that reaches the bottom of the document.
///
/// **Row-body count is not reported, deliberately.** The probe
/// (`docs/wakil/phase-2c-i-probe.md` §2) counted row bodies with a counter
/// bumped from each row's `onAppear`. That counter lived in the probe's own
/// throwaway construction, not in anything that ships; putting the
/// equivalent into `DataSurface` would mean instrumenting the shipping view
/// for the sake of a bench, and this bench does not do that. First-layout
/// time is reported instead, and does the same job: the probe's loudest
/// signal of eager construction was not a row count, it was `Grid` taking
/// 5.3 seconds to lay out 5,000 rows, against a `LazyVStack` indistinguishable
/// from zero at every size up to 50,000. A regression to eager construction
/// shows up there whether or not anything is counting rows.
///
/// **Not a gate.** See the task note and the 2b-ii spec §11: a wall-clock
/// assertion fails on a toolchain update and gets disabled. This is read,
/// not asserted on. What it protects against is the failure it was written
/// after — `Grid` shipping in 2b-ii over budget on every step at 5,000
/// rows, with nothing anywhere to say so.
///
/// **Creates `NSApplication.shared` itself, unlike `--capture`.** `--capture`
/// (`Capture.swift`) needs only a Metal device and can run as top-level code
/// before any application object exists. This bench hosts an
/// `NSHostingView` inside a real `NSWindow`, and SwiftUI's window-backed
/// hosting path — layout, `onAppear`, and the view hierarchy this function
/// walks for the row scroll view — depends on an `NSApplication` existing
/// first, the same way the interactive launch path
/// (`WakilApplication.main()` in `WakilWindow.swift`) has one running before
/// it ever builds a window. `.accessory` keeps it out of the Dock and off
/// the menu bar for a process that never shows a real window to a user.
///
/// Returns `0` on success, `1` when no `NSScrollView` was found in the
/// hosted hierarchy (the construction changed shape) — mirroring how
/// `runCapture` and `runCaptureMotion` report failure, so `--bench-surface`
/// can be wired the same way at its call site: `exit(runSurfaceBench(rows:))`.
@MainActor
func runSurfaceBench(rows rowCount: Int) -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let columns = (0..<8).map { PaneColumn(name: "column_\($0)", type: "TEXT") }
    let paneRows = (0..<rowCount).map { i in
        PaneRow(id: i, cells: (0..<8).map { c in PaneCell(.string("r\(i)c\(c)")) })
    }
    let table = PaneTable(
        columns: columns, columnTypesInferred: false, rows: paneRows, millis: 12,
        truncated: false, selection: .empty, sort: [], scrollTarget: nil,
        pageable: false, offset: 0, failure: nil, listsTables: false)
    var pane = Pane(
        id: "bench", kind: "db", title: "Bench",
        frame: PaneFrame(x: 0, y: 0, width: 900, height: 400))
    pane.density = .dense

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    let hosting = NSHostingView(
        rootView: DataSurface(
            table: table, pane: pane, dispatch: { _, _ in }, isFocusedPane: false,
            keyboardFocusRequests: 0))
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
    window.contentView = hosting
    // Offscreen, but ordered in: SwiftUI neither lays out nor runs onAppear
    // for a window that was never brought on screen, so a bench that skips
    // this measures nothing and reports zero.
    window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
    // Timed bracket ends the instant layout settles, before the fixed
    // settle wait below — the wait is a hand-off to the run loop for
    // deferred work, not part of the cost being measured.
    let firstLayoutStart = CFAbsoluteTimeGetCurrent()
    window.orderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    let firstLayoutMs = (CFAbsoluteTimeGetCurrent() - firstLayoutStart) * 1000
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))

    guard let scroll = firstScrollView(hosting) else {
        print("bench-surface: no NSScrollView found — the construction changed shape")
        window.orderOut(nil)
        return 1
    }
    let documentHeight = Double(scroll.documentView?.frame.height ?? 0)
    let expected = Double(rowCount) * pane.density.rowHeight
    print(String(format: "  rows              %d at %.0fpt", rowCount, pane.density.rowHeight))
    print(String(format: "  first layout      %.3f ms", firstLayoutMs))
    print(String(format: "  document height   %.0f pt (exact would be %.0f, %+.2f%%)",
                 documentHeight, expected, (documentHeight - expected) / expected * 100))

    // 10pt per step — how a scroll actually moves. A teleport across a
    // fraction of the document makes every row new and measures the worst
    // case rather than the case the budget is about.
    var times: [Double] = []
    for i in 1...300 {
        let t = CFAbsoluteTimeGetCurrent()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 10 * Double(i)))
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()
        times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
    }
    times.sort()
    let over = times.filter { $0 > 8.33 }.count
    print(String(format: "  scroll step       median %.3f ms   p95 %.3f ms   worst %.3f ms",
                 times[times.count / 2], times[Int(Double(times.count) * 0.95)], times.last!))
    print(String(format: "  over 8.33ms       %d / 300   %@", over,
                 over > 15 ? "<-- OVER BUDGET" : "ok"))

    // A sixtieth of the scrollable span per step — a teleport, not a scroll.
    // Every step lands on rows the 10pt pass above never got near, and the
    // last step reaches the bottom of the document. This is the worst case
    // (a scrollbar dragged the length of the pane in one gesture), not the
    // case the 8.33ms budget is about; the probe recorded a worst step of
    // about 48ms at 50,000 rows for the equivalent pass.
    let viewportHeight = Double(scroll.contentView.bounds.height)
    let scrollableSpan = max(0, documentHeight - viewportHeight)
    var deepTimes: [Double] = []
    for i in 1...60 {
        let target = scrollableSpan * Double(i) / 60
        let t = CFAbsoluteTimeGetCurrent()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()
        deepTimes.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
    }
    deepTimes.sort()
    print(String(
        format: "  deep scroll (worst case, scrollbar dragged length of pane)   median %.3f ms"
            + "   p95 %.3f ms   worst %.3f ms   (probe: ~48ms worst at 50,000 rows)",
        deepTimes[deepTimes.count / 2], deepTimes[Int(Double(deepTimes.count) * 0.95)],
        deepTimes.last!))

    window.orderOut(nil)
    return 0
}

@MainActor
private func firstScrollView(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for sub in view.subviews {
        if let scroll = firstScrollView(sub) { return scroll }
    }
    return nil
}
