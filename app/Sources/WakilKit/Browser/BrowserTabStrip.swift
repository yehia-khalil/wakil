import Foundation

/// **The browser's tab strip when its tabs do not fit** (3c-i, the overflow ruling of
/// 2026-10-26): entries shrink evenly before the strip scrolls, a faded edge with a count says
/// how many are out of sight on that side, and the active entry is always brought into view.
///
/// Pure: the strip's measurements in, widths, counts and scroll targets out. Every x here is in
/// the strip's content coordinates — the first entry's left edge is 0 — and `offset` is how far
/// the content is scrolled, so what the strip shows is `offset ... offset + viewport`.
public enum BrowserTabStrip {
    /// A whole entry's width while every entry fits (`BrowserPaneStyle.tabWidth`).
    public static let fullWidth: Double = 200
    /// The narrowest an entry shrinks to before the strip scrolls: the tick, the favicon and a
    /// few letters of the title.
    public static let minWidth: Double = 96
    /// The narrowest the active entry shrinks to: 88 pt of title after its tick, favicon and
    /// padding, about fourteen characters at the strip's 12 pt — enough to read which page it is.
    public static let activeMinWidth: Double = 140
    /// How far past an edge an entry may reach and still count as shown: the rounding of a
    /// laid-out frame, not a part of an entry.
    public static let tolerance: Double = 1

    /// Each entry's width, and whether at that width the entries still overflow `available`.
    public struct Widths: Equatable, Sendable {
        public var active: Double
        public var other: Double
        public var overflows: Bool
        public init(active: Double, other: Double, overflows: Bool) {
            self.active = active
            self.other = other
            self.overflows = overflows
        }
    }

    /// The widths for `count` entries in `available` points, `separator` points between each
    /// two: the full width while they fit; then all shrink evenly; below the active minimum the
    /// active entry stays at it and the others share what is left; below the minimum they stay
    /// at it and the strip overflows.
    public static func widths(count: Int, available: Double, separator: Double) -> Widths {
        guard count > 0 else { return Widths(active: fullWidth, other: fullWidth, overflows: false) }
        let separators = Double(count - 1) * separator
        let even = (available - separators) / Double(count)
        if even >= fullWidth { return Widths(active: fullWidth, other: fullWidth, overflows: false) }
        if even >= activeMinWidth { return Widths(active: even, other: even, overflows: false) }
        guard count > 1 else {
            return Widths(active: activeMinWidth, other: activeMinWidth, overflows: activeMinWidth > available + tolerance)
        }
        let other = (available - separators - activeMinWidth) / Double(count - 1)
        if other >= minWidth { return Widths(active: activeMinWidth, other: other, overflows: false) }
        return Widths(active: activeMinWidth, other: minWidth, overflows: true)
    }

    /// Whether `count` entries of one fixed `width` (a folded strip's) overflow `available`.
    public static func overflows(count: Int, width: Double, available: Double, separator: Double) -> Bool {
        guard count > 0 else { return false }
        return Double(count) * width + Double(count - 1) * separator > available + tolerance
    }

    /// How many entries are out of sight on each side: an entry cut by an edge counts as hidden
    /// on that side, since pressing its count is what brings it in.
    public struct Hidden: Equatable, Sendable {
        public var left: Int
        public var right: Int
        public init(left: Int, right: Int) {
            self.left = left
            self.right = right
        }
        public static let none = Hidden(left: 0, right: 0)
    }

    /// The hidden counts for entries at `spans`, scrolled to `offset` in a `viewport` that wide.
    public static func hidden(spans: [ClosedRange<Double>], offset: Double, viewport: Double) -> Hidden {
        guard viewport > 0 else { return .none }
        let start = offset - tolerance, end = offset + viewport + tolerance
        return Hidden(left: spans.filter { $0.lowerBound < start }.count,
                      right: spans.filter { $0.upperBound > end }.count)
    }

    /// A side of the strip.
    public enum Side: Sendable { case left, right }

    /// The entry a press on `side`'s count scrolls to — a page toward the hidden ones. Right:
    /// the first entry not wholly shown, brought to the left edge. Left: the last entry not
    /// wholly shown on the left, brought to the right edge. nil when nothing is hidden there.
    public static func pageTarget(_ side: Side, spans: [ClosedRange<Double>], offset: Double,
                                  viewport: Double) -> Int? {
        switch side {
        case .right: spans.firstIndex { $0.upperBound > offset + viewport + tolerance }
        case .left: spans.lastIndex { $0.lowerBound < offset - tolerance }
        }
    }

    /// Whether an entry at `span` needs scrolling to be seen: any part of it outside the strip,
    /// or under the `margin` the faded edges take. An entry already in view is left where it is,
    /// so a click on one never moves the strip (Rule 6).
    public static func needsReveal(_ span: ClosedRange<Double>, offset: Double, viewport: Double,
                                   margin: Double) -> Bool {
        guard viewport > 0 else { return false }
        let inner = min(margin, max(0, (viewport - (span.upperBound - span.lowerBound)) / 2))
        return span.lowerBound < offset + inner - tolerance
            || span.upperBound > offset + viewport - inner + tolerance
    }
}
