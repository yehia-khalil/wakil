import AppKit
import WakilKit
import SwiftUI

// MARK: - Layout

/// The verbs this pane draws as text — `+ QUERY`, `+ HEADER`, `+ HOLE`, `FORMAT` on a heading,
/// `+ hole`, `Reopen`, `Copy as cURL` in a row: luminance violet (§5: what can be acted on
/// now), dimmed while it cannot be.
struct Verb: ViewModifier {
    let heading: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: heading ? 10 : 10.5, weight: .semibold))
            .tracking(heading ? 0.8 : 0.5)
            .foregroundStyle(SettingsPalette.accent.opacity(enabled ? 0.9 : 0.35))
    }
}

/// Marks the one flow item that takes what is left of its line — the path's editor, after the
/// origin on the URL line.
struct ApiFlowGrows: LayoutValueKey {
    static let defaultValue = false
}

/// Lays its items out left to right and **wraps at the edge**, an item never split across
/// lines: one that does not fit moves whole to the next. Since every field became one editor
/// (Amendment 10) it draws two things: the URL line's origin and path editor, and the read-only
/// `parts(_:)` (Wakil's rows, the Bound list). There is no typing box any more; wrapping inside a
/// field is its text view's.
///
/// - An item is as wide as it wants (its unproposed width), capped at the line, and one
///   wider than the line is offered the line's width and wraps inside it — a `Text`.
/// - **The item marked `ApiFlowGrows` takes the rest of its line**, or the whole of the next
///   when less than `minimumGrowth` is left — the path editor, so there is always room to type.
/// - Items in a line are centred on each other vertically.
struct ApiFlow: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 4
    var minimumGrowth: CGFloat = 80

    private struct Item {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(proposal.width, subviews)
        let height = lines.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(lines.count - 1, 0))
        let natural = lines.map(\.width).max() ?? 0
        let width = proposal.width.flatMap { $0.isFinite ? max($0, natural) : nil } ?? natural
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in arrange(bounds.width, subviews) {
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(
                        x: bounds.minX + item.x,
                        y: y + (line.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size))
            }
            y += line.height + lineSpacing
        }
    }

    private func arrange(_ width: CGFloat?, _ subviews: Subviews) -> [Line] {
        let limit = width.flatMap { $0.isFinite ? max($0, 1) : nil }
        var lines = [Line()]
        for index in subviews.indices {
            let subview = subviews[index]
            var size = subview.sizeThatFits(.unspecified)
            if let limit {
                let line = lines[lines.count - 1]
                let gap = line.items.isEmpty ? 0 : spacing
                if subview[ApiFlowGrows.self] {
                    var room = limit - line.width - gap
                    if room < min(minimumGrowth, limit), !line.items.isEmpty {
                        lines.append(Line())
                        room = limit
                    }
                    size = subview.sizeThatFits(ProposedViewSize(width: room, height: nil))
                    size.width = room
                } else {
                    if size.width > limit {
                        size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                        size.width = min(size.width, limit)
                    }
                    if line.width + gap + size.width > limit, !line.items.isEmpty {
                        lines.append(Line())
                    }
                }
            }
            var line = lines[lines.count - 1]
            let x = line.items.isEmpty ? 0 : line.width + spacing
            line.items.append(Item(index: index, x: x, size: size))
            line.width = x + size.width
            line.height = max(line.height, size.height)
            lines[lines.count - 1] = line
        }
        return lines.filter { !$0.items.isEmpty }
    }
}

/// A table row's three cells: the name ≈30% of the width (it wraps), the value the rest (it
/// wraps), and the row's controls at its right end at their own width — capped, so an amber
/// line in a name box never squeezes the value out. Every cell is top-aligned.
///
/// **Exactly three subviews**, each one view — the call sites wrap every cell in a stack.
struct ApiRowColumns: Layout {
    var nameShare: CGFloat = 0.30
    var gap: CGFloat = 10

    private struct Widths {
        let name: CGFloat
        let value: CGFloat
        let actions: CGFloat
    }

    private func widths(_ width: CGFloat?, _ subviews: Subviews) -> Widths? {
        guard subviews.count == 3, let width, width.isFinite else { return nil }
        let name = (width * nameShare).rounded(.down)
        let actionsIdeal = subviews[2].sizeThatFits(.unspecified).width
        let actions = min(actionsIdeal, width * 0.45)
        let value = max(width - name - actions - gap * (actions > 0 ? 2 : 1), 40)
        return Widths(name: name, value: value, actions: actions)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let widths = widths(proposal.width, subviews) else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(
                width: sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(sizes.count - 1, 0)),
                height: sizes.map(\.height).max() ?? 0)
        }
        let heights = [widths.name, widths.value, widths.actions].enumerated().map { index, w in
            subviews[index].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        }
        return CGSize(width: proposal.width ?? 0, height: heights.max() ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let widths = widths(bounds.width, subviews) else {
            var x = bounds.minX
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
                x += size.width + gap
            }
            return
        }
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: widths.name, height: nil))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + widths.name + gap, y: bounds.minY),
            proposal: ProposedViewSize(width: widths.value, height: nil))
        subviews[2].place(
            at: CGPoint(x: bounds.maxX - widths.actions, y: bounds.minY),
            proposal: ProposedViewSize(width: widths.actions, height: nil))
    }
}

extension View {
    /// A line that wraps to the pane's width instead of truncating.
    func wraps() -> some View { lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
}
