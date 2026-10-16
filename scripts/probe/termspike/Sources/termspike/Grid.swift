import Foundation
import SwiftUI
import AppKit

/// One screenful of terminal cells. The grid is redrawn from this, and the
/// identity of the value is what SwiftUI diffs on — so the frame cost is the
/// cost of a whole new screen, which is what output scrolling produces.
struct Screen: Equatable {
    var cols: Int
    var rows: Int
    var lines: [String]
    /// A colour run per row, standing in for SGR attributes without pretending
    /// to model them: enough that the row cannot be one flat `Text`.
    var accent: [Int]

    static func make(cols: Int, rows: Int, seed: Int) -> Screen {
        var lines = [String]()
        var accent = [Int]()
        for r in 0..<rows {
            let s = "[\(seed + r)/4821] compiling object file for target WakilKit, \((seed + r) % 97) left"
            lines.append(String(s.prefix(cols)).padding(toLength: cols, withPad: " ", startingAt: 0))
            accent.append((seed + r) % 5)
        }
        return Screen(cols: cols, rows: rows, lines: lines, accent: accent)
    }
}

let palette: [Color] = [.primary, .green, .yellow, .red, .cyan]
let cellFont = Font.system(size: 12, weight: .regular, design: .monospaced)

/// A — a `Text` per cell. The literal reading of "a custom grid renderer":
/// every cell addressable, every cell independently attributable.
struct CellGrid: View {
    let screen: Screen
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<screen.rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<screen.cols, id: \.self) { c in
                        Text(String(Array(screen.lines[r])[c]))
                            .font(cellFont)
                            .foregroundStyle(palette[screen.accent[r]])
                            .frame(width: 7.2, height: 15)
                    }
                }
            }
        }
    }
}

/// B — a `Text` per row, carrying an `AttributedString` so a row can still
/// hold several colours. One view per row instead of one per cell.
struct RowGrid: View {
    let screen: Screen
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<screen.rows, id: \.self) { r in
                Text(attributed(r))
                    .font(cellFont)
                    .frame(height: 15, alignment: .leading)
            }
        }
    }
    func attributed(_ r: Int) -> AttributedString {
        let line = screen.lines[r]
        let split = line.index(line.startIndex, offsetBy: min(12, line.count))
        var head = AttributedString(String(line[line.startIndex..<split]))
        head.foregroundColor = palette[screen.accent[r]]
        var tail = AttributedString(String(line[split...]))
        tail.foregroundColor = .primary
        return head + tail
    }
}

/// C — one `Canvas`, drawing every row itself. No view per cell and no view
/// per row; SwiftUI's diff sees one node.
struct CanvasGrid: View {
    let screen: Screen
    var body: some View {
        Canvas { ctx, _ in
            for r in 0..<screen.rows {
                var text = Text(screen.lines[r]).font(cellFont)
                text = text.foregroundColor(palette[screen.accent[r]])
                ctx.draw(text, at: CGPoint(x: 0, y: Double(r) * 15), anchor: .topLeading)
            }
        }
    }
}

struct Host: View {
    @ObservedObject var model: GridModel
    var body: some View {
        Group {
            switch model.kind {
            case 0: CellGrid(screen: model.screen)
            case 1: RowGrid(screen: model.screen)
            default: CanvasGrid(screen: model.screen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

final class GridModel: ObservableObject {
    @Published var screen: Screen
    let kind: Int
    init(kind: Int, screen: Screen) { self.kind = kind; self.screen = screen }
}

/// The method is 2c-i's, deliberately: an offscreen `NSWindow` ordered in
/// (SwiftUI neither lays out nor fires `onAppear` for a window that was never
/// brought on screen), then per step `layoutSubtreeIfNeeded` + a flushed
/// `CATransaction`, timed.
@MainActor
func measureGrid(kind: Int, name: String, cols: Int, rows: Int, frames: Int) -> (median: Double, worst: Double, fps: Double) {
    let model = GridModel(kind: kind, screen: Screen.make(cols: cols, rows: rows, seed: 0))
    let hosting = NSHostingView(rootView: Host(model: model))
    // The window is sized to the grid rather than fixed at 2c-i's 900x400.
    // At 900x400 a 132x36 grid of 7.2x15 cells overflows in both axes and
    // SwiftUI culls what falls outside, which made construction A's 200x50
    // median *faster* than its own 132x36 across repeated runs — the larger
    // grid was simply having more of itself thrown away. Sizing to content is
    // what makes the three sizes comparable to each other.
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Double(cols) * 7.2 + 20, height: Double(rows) * 15 + 20),
                     styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = hosting
    w.orderBack(nil)
    hosting.layoutSubtreeIfNeeded()
    CATransaction.flush()

    var samples = [Double]()
    for f in 1...frames {
        model.screen = Screen.make(cols: cols, rows: rows, seed: f * rows)
        let t = now()
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()
        samples.append(now() - t)
    }
    w.orderOut(nil)
    samples.sort()
    let median = samples[samples.count / 2]
    let worst = samples[samples.count - 1]
    return (median, worst, 1.0 / median)
}

@MainActor
func runGrid() {
    print("## Measurement 5 — drawing the live grid in SwiftUI\n")
    print("Offscreen `NSWindow` sized to the grid + `NSHostingView`, ordered in; per frame a whole")
    print("new screen, then `layoutSubtreeIfNeeded` + `CATransaction.flush()`, timed. Release build.\n")
    print("| construction | grid | median frame | worst | sustainable |")
    print("|---|---|---|---|---|")
    for (cols, rows) in [(80, 24), (132, 36), (200, 50)] {
        for (kind, name) in [(0, "A — `Text` per cell"), (1, "B — `Text` per row"), (2, "C — one `Canvas`")] {
            // One frame count for every cell, so the three constructions and
            // the three sizes are comparable. An earlier draft cut A's frames
            // at the larger sizes and produced a 200x50 median *faster* than
            // its own 132x36 — an artefact of the sample count, not a result.
            let frames = 30
            let r = measureGrid(kind: kind, name: name, cols: cols, rows: rows, frames: frames)
            print("| \(name) | \(cols)x\(rows) | \(String(format: "%.2f ms", r.median * 1000)) | \(String(format: "%.2f ms", r.worst * 1000)) | \(String(format: "%.0f fps", r.fps)) |")
        }
    }
    print("")
}
