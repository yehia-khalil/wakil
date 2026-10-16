import Foundation

/// What a key does on a focused db grid. Bound by `.onKeyPress` on the surface, never by
/// `.keyboardShortcut` (`DBPane`'s rule: a per-pane shortcut fires the first pane's control).
public enum DataSurfaceKey: Equatable, Sendable {
    /// ⌘C: the anchor cell, or the selected rows as TSV (`GridCopy`).
    case copy
    /// Space: open or close the row detail strip.
    case toggleDetail
    /// Esc with the strip open.
    case closeDetail
    /// ↑ / ↓: move the anchor row through `pane_select_cell` — no new action.
    case move(Int)
}

/// The key rule, kept here so it is tested. A cell being edited owns every key. Esc with the
/// strip closed is not claimed, so it falls through to whatever owns it outside the grid.
public func dataSurfaceKeyClaim(key: String, command: Bool, editing: Bool, detailOpen: Bool) -> DataSurfaceKey? {
    guard !editing else { return nil }
    switch key {
    case "c": return command ? .copy : nil
    case " ": return command ? nil : .toggleDetail
    case "up": return command ? nil : .move(-1)
    case "down": return command ? nil : .move(1)
    case "escape": return detailOpen ? .closeDetail : nil
    default: return nil
    }
}

/// Seconds to one decimal, as the api pane writes them (`apiSeconds`). Kept separate so
/// `Panes/` does not reach into `Api/`.
public func dbSeconds(_ milliseconds: Int) -> String {
    String(format: "%.1f s", Double(milliseconds) / 1000)
}

/// The footer's flight line: `running · 3.2 s` while a read runs, `cancelled after 3.2 s`
/// after a cancel, nothing otherwise.
public func dbFlightLine(runningSince: Date?, cancelledAfterMs: Int?, now: Date) -> String? {
    if let runningSince {
        return "running · " + dbSeconds(max(0, Int(now.timeIntervalSince(runningSince) * 1000)))
    }
    if let cancelledAfterMs { return "cancelled after " + dbSeconds(cancelledAfterMs) }
    return nil
}
