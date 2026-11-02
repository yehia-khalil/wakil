import Foundation

/// The settings tree's keyboard rules (settings revamp, 2026-11-02). Pure, so the pane only says
/// which rows are visible; neither move opens or closes a branch (Rule 6).
public enum SettingsTreeKeys {
    /// The row `by` steps from `from` among `rows`, stopping at either end. From nothing, or from
    /// a row no longer visible, the first row.
    public static func step<N: Hashable>(_ rows: [N], from: N?, by offset: Int) -> N? {
        guard !rows.isEmpty else { return nil }
        guard let from, let index = rows.firstIndex(of: from) else { return rows.first }
        return rows[min(max(index + offset, 0), rows.count - 1)]
    }

    /// The first row after `after` whose label starts with `prefix`, wrapping once to the rows
    /// before it and finally the current row itself — so typing more of the selected row's name
    /// keeps it. Case and diacritics are ignored.
    public static func find<N: Hashable>(
        _ rows: [(node: N, label: String)], prefix: String, after: N?
    ) -> N? {
        let wanted = fold(prefix)
        guard !wanted.isEmpty else { return nil }
        let start = after.flatMap { current in rows.firstIndex { $0.node == current } }
        let order: [(node: N, label: String)]
        if let start {
            order = Array(rows[(start + 1)...]) + Array(rows[...start])
        } else {
            order = rows
        }
        return order.first { fold($0.label).hasPrefix(wanted) }?.node
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Letters typed into the tree, joined while they come within a second of each other.
public struct TypeAhead: Sendable {
    public static let reset: TimeInterval = 1
    private var typed = ""
    private var last: Date?

    public init() {}

    public mutating func append(_ character: Character, at now: Date) -> String {
        if let last, now.timeIntervalSince(last) <= Self.reset {
            typed.append(character)
        } else {
            typed = String(character)
        }
        last = now
        return typed
    }
}
