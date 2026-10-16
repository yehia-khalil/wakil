import Foundation
import SwiftUI
import AppKit

/// The *other* surface, and the one that is actually unbounded.
///
/// The live grid is capped by the pane's own dimensions — measurement 5 draws
/// the whole of it every frame and it is still cheap. The block history is not
/// capped by anything the pane owns; the spec bounds it "in blocks, not lines,
/// with a line cap inside each" and leaves both numbers unset. These are the
/// numbers.
struct Block: Identifiable, Equatable {
    let id: Int
    let command: String
    let lines: [String]
    let exitCode: Int32
    let origin: Int   // 0 operator, 1 agent-mirrored, 2 proposed
}

func makeBlocks(count: Int, linesEach: Int) -> [Block] {
    (0..<count).map { i in
        Block(id: i,
              command: "swift build -c release --target WakilKit",
              lines: (0..<linesEach).map { "[\($0)/\(linesEach)] compiling object file for target WakilKit, \(($0 * 7) % 97) remaining" },
              exitCode: Int32(i % 3 == 0 ? 1 : 0),
              origin: i % 5 == 0 ? 1 : 0)
    }
}

struct BlockView: View {
    let block: Block
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(block.command)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(block.exitCode == 0 ? "0" : "\(block.exitCode)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(block.exitCode == 0 ? Color.secondary : Color.red)
            }
            .frame(height: 18)
            ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 15, alignment: .leading)
            }
        }
        .padding(.leading, block.origin == 1 ? 12 : 0)
        .opacity(block.origin == 1 ? 0.7 : 1.0)
    }
}

struct HistoryView: View {
    let blocks: [Block]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { BlockView(block: $0) }
            }
        }
    }
}

/// Measures the first layout (2c-i's 5.3-second finding is the reason this is
/// measured at all) and then a scroll step, over a history of a given size.
@MainActor
func measureHistory(blocks: Int, linesEach: Int) -> (firstLayout: Double, scrollMedian: Double, rows: Int, bytes: UInt64) {
    let before = footprintBytes()
    let data = makeBlocks(count: blocks, linesEach: linesEach)
    let held = footprintBytes()
    let hosting = NSHostingView(rootView: HistoryView(blocks: data))
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 540),
                     styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = hosting
    w.orderBack(nil)

    let t0 = now()
    hosting.layoutSubtreeIfNeeded()
    CATransaction.flush()
    let first = now() - t0

    var samples = [Double]()
    if let scroll = firstScrollView(in: hosting) {
        let doc = scroll.documentView
        for i in 1...20 {
            let t = now()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: Double(i) * 540))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
            CATransaction.flush()
            samples.append(now() - t)
            if let d = doc, Double(i) * 540 > d.frame.height { break }
        }
    }
    w.orderOut(nil)
    samples.sort()
    return (first, samples.isEmpty ? 0 : samples[samples.count / 2], blocks * (linesEach + 1), held > before ? held - before : 0)
}

func firstScrollView(in view: NSView) -> NSScrollView? {
    if let s = view as? NSScrollView { return s }
    for sub in view.subviews { if let s = firstScrollView(in: sub) { return s } }
    return nil
}

@MainActor
func runHistory() {
    print("## Measurement 6 — drawing the block history\n")
    print("`ScrollView` + `LazyVStack` of blocks, each block a header row plus its output")
    print("lines. Window 950x540. First layout, then 20 scroll steps of one screen each.\n")
    print("| blocks | lines each | total rows | held in memory | first layout | median scroll step |")
    print("|---|---|---|---|---|---|")
    for (b, l) in [(50, 40), (200, 40), (500, 40), (1000, 40), (200, 500), (500, 1000)] {
        let r = measureHistory(blocks: b, linesEach: l)
        print("| \(b) | \(l) | \(r.rows) | \(mb(r.bytes)) | \(String(format: "%.0f ms", r.firstLayout * 1000)) | \(String(format: "%.2f ms", r.scrollMedian * 1000)) |")
    }
    print("")
}
