import Foundation

/// The thought thread's disclosure state (2d-ii): four rows, faded at rest,
/// full on hover, rows expanded on click, folded 1.2 s after the pointer
/// leaves. Pure; the view passes time in.
public struct ThreadDisclosure: Sendable, Equatable {
    public static let visibleCount = 4
    public static let foldAfter: Double = 1.2
    public static let restOpacity: Double = 0.32

    public private(set) var open: Set<Int> = []
    public private(set) var showAll = false
    public private(set) var hovering = false
    private var leftAt: Double?

    public init() {}

    public var pinned: Bool { !open.isEmpty || showAll }
    /// True while a departure is waiting to fold: lets the view poll without
    /// mutating (and so re-rendering) when nothing is due.
    public var foldPending: Bool { leftAt != nil && !hovering }
    public var opacity: Double { hovering || pinned ? 1 : Self.restOpacity }

    public func visible(_ rows: [ThoughtRow]) -> (rows: [ThoughtRow], earlier: Int) {
        guard !showAll, rows.count > Self.visibleCount else { return (rows, 0) }
        return (Array(rows.suffix(Self.visibleCount)), rows.count - Self.visibleCount)
    }

    public mutating func toggle(_ id: Int) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }

    public mutating func showEarlier() { showAll = true }

    public mutating func pointerEntered() {
        hovering = true
        leftAt = nil
    }

    public mutating func pointerLeft(at now: Double) {
        hovering = false
        leftAt = now
    }

    public mutating func tick(at now: Double, mouseHeld: Bool) {
        guard let left = leftAt, !hovering else { return }
        // A drag-selection in progress is not a departure; the wait
        // resumes, unrestarted, once the button is up.
        if mouseHeld { return }
        // The epsilon absorbs float error: 11.2 - 10 is 1.1999999999999993.
        if now - left >= Self.foldAfter - 1e-9 { fold() }
    }

    /// True when there was something to fold.
    public mutating func escape() -> Bool {
        let had = pinned
        fold()
        return had
    }

    private mutating func fold() {
        open = []
        showAll = false
        leftAt = nil
    }
}
