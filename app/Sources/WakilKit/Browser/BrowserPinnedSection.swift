import Foundation

/// 3d-i walk: the pinned section at the head of a pane's tab list. Pinned tabs are drawn as tiles —
/// a grid of square favicons in the vertical column, favicon-only entries in the strip — then the
/// pinned groups' pills and members, then a line, then everything else. An unpinned tab is never
/// drawn above the line. Counted over `stripEntries`, whose head these always are (`arrange()`
/// ranks pinned tabs, then pinned groups, first).
public struct BrowserPinnedSection: Equatable, Sendable {
    /// The leading entries that are pinned tabs: the tiles.
    public let tiles: Int
    /// The leading entries above the line: the tiles, then the pinned groups' headers and members.
    public let count: Int

    public init(tiles: Int, count: Int) {
        self.tiles = tiles
        self.count = count
    }

    /// Nothing pinned: no section, and no line.
    public var isEmpty: Bool { count == 0 }

    /// Whether a drop in `gap` is above the line: before it, or in the line's own gap on its side.
    public func isAbove(gap: Int, inSection: Bool) -> Bool {
        gap < count || (gap == count && inSection && !isEmpty)
    }

    /// Whether a drop in `gap` is on the tiles.
    public func onTiles(gap: Int, inSection: Bool) -> Bool {
        isAbove(gap: gap, inSection: inSection) && gap <= tiles
    }
}

/// What a drop in a tab list does: one `browser_*` action (Invariant 2) — `browser_move_tab` to
/// reorder or regroup, `browser_pin` for a tab dropped on the tiles, `browser_unpin` for a pinned tab
/// dropped below the line.
public struct BrowserTabDrop: Equatable, Sendable {
    public let action: String
    public let params: [String: JSONValue]

    public init(action: String, params: [String: JSONValue]) {
        self.action = action
        self.params = params
    }
}

extension BrowserSnapshot {
    /// The section's extent in `stripEntries`.
    public var pinnedSection: BrowserPinnedSection {
        let entries = stripEntries
        let tiles = entries.prefix { if case .tab(let t) = $0 { t.pin != nil } else { false } }.count
        let count = entries.prefix { entry in
            switch entry {
            case .chip(let g): g.pin != nil
            case .tab(let t): isPinned(t)
            }
        }.count
        return BrowserPinnedSection(tiles: tiles, count: count)
    }

    /// The drop of entry `from` in `gap` (0…`stripEntries.count`: before the entry now there, the
    /// dragged one counted), `inSection` when it is drawn on the section's side of the line — which
    /// only the line's own gap needs; elsewhere the gap says. Nil where the drop would change nothing:
    /// a group's header, a tab back in its place, a pinned tab among the pinned groups, a pinned
    /// group's member on the tiles (it is pinned with its group). On the tiles a tab is pinned there
    /// and a tile moves; below the line a tile is unpinned and lands there, joining the group it lands
    /// in, as any tab does.
    public func drop(_ from: Int, gap: Int, inSection: Bool) -> BrowserTabDrop? {
        let entries = stripEntries
        guard entries.indices.contains(from), case .tab(let moving) = entries[from], (0...entries.count).contains(gap)
        else { return nil }
        let section = pinnedSection
        let above = section.isAbove(gap: gap, inSection: inSection)
        let to = gap > from ? gap - 1 : gap
        let tab = JSONValue.string(moving.id)
        if section.onTiles(gap: gap, inSection: inSection) {
            if moving.pin != nil {
                guard to != from else { return nil }
                return BrowserTabDrop(action: "browser_move_tab", params: ["tab": tab, "to": .integer(Int64(to))])
            }
            guard !isPinned(moving) else { return nil }
            // The tiles are `tabs`' head, and the tab comes from after them: `gap` is its place.
            return BrowserTabDrop(action: "browser_pin", params: ["tab": tab, "to": .integer(Int64(gap))])
        }
        if above {
            guard moving.pin == nil else { return nil }
            return stripMove(from: from, to: to).map { BrowserTabDrop(action: "browser_move_tab", params: $0) }
        }
        if moving.pin != nil {
            let (at, group) = landing(from: from, to: to)
            return BrowserTabDrop(action: "browser_unpin",
                                  params: ["tab": tab, "to": .integer(Int64(at)), "into": .string(group ?? "")])
        }
        return stripMove(from: from, to: to).map { BrowserTabDrop(action: "browser_move_tab", params: $0) }
    }

    /// The `browser_move_tab` a drag of entry `from` to index `to` (counted without it) makes, or nil
    /// when it would change nothing — a chip, a drop into the pull-request group, a tab back in its
    /// place: no line is drawn for a drop that would do nothing. The tab lands before the entry now
    /// at `to`, in that entry's group (`dropGroup`); before a chip or at the end, loose.
    public func stripMove(from: Int, to: Int) -> [String: JSONValue]? {
        let entries = stripEntries
        guard entries.indices.contains(from), case .tab(let moving) = entries[from] else { return nil }
        let (at, group) = landing(from: from, to: to)
        // Only a drop that changes something is offered.
        var after = self
        after.moveTab(moving.id, into: group, at: at)
        guard after.tabs.map(\.id) != tabs.map(\.id) || after.tabs.map(\.group) != tabs.map(\.group)
        else { return nil }
        return ["tab": .string(moving.id), "to": .integer(Int64(at)), "group": .string(group ?? "")]
    }

    /// Where entry `from` dropped at index `to` (counted without it) lands: its index in `tabs` once
    /// taken out — before the next shown tab, or before the first tab of the group whose header is
    /// next — and the group it joins there.
    private func landing(from: Int, to: Int) -> (at: Int, group: String?) {
        var others = stripEntries
        let moving = others.remove(at: from)
        let rest = tabs.filter { $0.id != moving.id }
        let at: Int = {
            for entry in others.dropFirst(to) {
                switch entry {
                case .tab(let t): if let i = rest.firstIndex(where: { $0.id == t.id }) { return i }
                case .chip(let g): if let i = rest.firstIndex(where: { $0.group == g.id }) { return i }
                }
            }
            return rest.count
        }()
        var group: String?
        if to < others.count, case .tab = others[to] { group = dropGroup(moving: moving.id, before: at) }
        return (at, group)
    }
}

/// The vertical column's geometry (3d-i walk), in its rows' space — the column's width, its top at
/// the first row: the tiles' grid, the pinned groups' rows, the line's band, the other rows. The view
/// draws by these numbers and a drag reads its drop from them, so the two cannot disagree.
public struct BrowserColumnLayout: Equatable, Sendable {
    public static let rowHeight = 28.0
    /// A row's and the grid's inset from the column's edges.
    public static let inset = 6.0
    /// Between two tiles, either way, and under the grid.
    public static let tileSpacing = 6.0
    /// The narrowest a tile gets before a row holds one fewer: four to a row at the default 220 pt,
    /// three at 160, seven at 360.
    public static let minTile = 40.0
    /// The band the section's line is centred in.
    public static let band = 9.0

    public let section: BrowserPinnedSection
    /// `stripEntries.count`.
    public let entries: Int
    /// The column's width, clamped 160–360.
    public let width: Double

    public init(section: BrowserPinnedSection, entries: Int, width: Double) {
        self.section = section
        self.entries = entries
        self.width = BrowserTabColumnRules.clamp(width)
    }

    /// Tiles to a row: as many as fit at `minTile` or wider.
    public static func perRow(width: Double) -> Int {
        let inner = BrowserTabColumnRules.clamp(width) - 2 * inset
        return max(1, Int((inner + tileSpacing) / (minTile + tileSpacing)))
    }

    public var perRow: Int { Self.perRow(width: width) }

    /// A tile's side: the row's room shared evenly, so the grid meets both insets.
    public var tileSide: Double {
        let n = Double(perRow)
        return (width - 2 * Self.inset - (n - 1) * Self.tileSpacing) / n
    }

    public var tileRows: Int { (section.tiles + perRow - 1) / perRow }

    /// The grid with the space under it; 0 with no tiles.
    public var gridHeight: Double {
        guard tileRows > 0 else { return 0 }
        return Double(tileRows) * (tileSide + Self.tileSpacing)
    }

    /// Tile `k`'s top-left corner.
    public func tileOrigin(_ k: Int) -> (x: Double, y: Double) {
        (Self.inset + Double(k % perRow) * (tileSide + Self.tileSpacing),
         Double(k / perRow) * (tileSide + Self.tileSpacing))
    }

    /// The line's band, under the pinned groups' rows; nil with nothing pinned.
    public var bandTop: Double? {
        section.isEmpty ? nil : gridHeight + Double(section.count - section.tiles) * Self.rowHeight
    }

    /// Where the rows below the line start.
    public var restTop: Double { bandTop.map { $0 + Self.band } ?? 0 }

    /// The top of entry `i`'s row (`i` at or past the tiles).
    public func rowTop(_ i: Int) -> Double {
        i < section.count
            ? gridHeight + Double(i - section.tiles) * Self.rowHeight
            : restTop + Double(i - section.count) * Self.rowHeight
    }

    public var height: Double { rowTop(entries) }

    /// The drop under a point: a tile slot (the gap before tile k, or after the last), a row's gap,
    /// or the line's own gap — on its upper half the section's, on its lower half the rest's.
    public func target(x: Double, y: Double) -> (gap: Int, inSection: Bool) {
        let tiles = section.tiles, count = section.count
        if tiles > 0, y < gridHeight {
            let step = tileSide + Self.tileSpacing
            let row = max(0, min(tileRows - 1, Int((y / step).rounded(.down))))
            let column = max(0, min(perRow, Int(((x - Self.inset - tileSide / 2) / step).rounded(.down)) + 1))
            return (min(row * perRow + column, tiles), true)
        }
        if let band = bandTop, y < band + Self.band {
            if y >= band { return (count, y < band + Self.band / 2) }
            let gap = tiles + Int(((y - gridHeight) / Self.rowHeight).rounded())
            return (max(tiles, min(count, gap)), true)
        }
        let gap = count + Int(((y - restTop) / Self.rowHeight).rounded())
        return (max(count, min(entries, gap)), false)
    }

    /// The y a row gap's drop line is drawn at: the line's own gap above the band on the section's
    /// side, under it on the rest's.
    public func lineY(gap: Int, inSection: Bool) -> Double {
        if gap == section.count, inSection, let band = bandTop { return band }
        return rowTop(gap)
    }

    /// Where a tile slot's drop line stands: in the spacing before tile `slot`, or after the tile
    /// before it at a row's end and after the last.
    public func tileLine(_ slot: Int) -> (x: Double, y: Double) {
        let half = Self.tileSpacing / 2
        if slot > 0, slot % perRow == 0 || slot == section.tiles {
            let o = tileOrigin(slot - 1)
            return (o.x + tileSide + half, o.y)
        }
        let o = tileOrigin(slot)
        return (o.x - half, o.y)
    }
}

/// The strip's drop (3d-i walk): its entries left to right with the section's line after the first
/// `section`. Over an entry a drop takes its place, as the strip always has; in a space, the space.
public enum BrowserStripDrop {
    /// The gap a drag of entry `from` at (`x`, `y`) drops in, and whether it is left of the line
    /// (`section` entries before it; 0, none). Nil off the strip and over the dragged entry.
    public static func target(from: Int, x: Double, y: Double, spans: [ClosedRange<Double>], height: Double,
                              section: Int) -> (gap: Int, inSection: Bool)? {
        guard y >= 0, y < height, spans.indices.contains(from) else { return nil }
        let gap: Int
        if let k = spans.firstIndex(where: { $0.contains(x) }) {
            guard k != from else { return nil }
            gap = k < from ? k : k + 1
        } else {
            gap = spans.firstIndex { $0.lowerBound > x } ?? spans.count
        }
        return (gap, x < lineX(section: section, spans: spans))
    }

    /// The middle of the space the line stands in; -∞ with no section.
    public static func lineX(section: Int, spans: [ClosedRange<Double>]) -> Double {
        guard section > 0, spans.indices.contains(section - 1) else { return -.infinity }
        let left = spans[section - 1].upperBound
        let right = spans.indices.contains(section) ? spans[section].lowerBound : left
        return (left + right) / 2
    }

    /// The x a drop line is drawn at: beside the entry on the side the drag came from — at the line,
    /// on the line's side the drop is on.
    public static func dropX(from: Int, gap: Int, inSection: Bool, section: Int,
                             spans: [ClosedRange<Double>]) -> Double {
        guard !spans.isEmpty else { return 0 }
        let after = gap == section && section > 0 ? inSection : gap > from
        if after || gap >= spans.count {
            return spans[max(0, min(spans.count, gap) - 1)].upperBound + 1
        }
        return spans[gap].lowerBound - 1
    }
}
