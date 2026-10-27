import Foundation

/// The keyboard a confirmation plane owes back, per window (3c-ii, Rule 6).
///
/// A plane that goes gives the keyboard back to what held it as it rose (the composer the operator
/// asked in) — but not at once: its own field holds the keyboard for a few turns more, so the return
/// is retried for up to a second. A newer plane that rises meanwhile is where the keyboard belongs
/// now, so it **ends** that return (`rise`): an older plane's retry must never put the composer under
/// a newer plane, where a Return would go to the composer rather than to the question on screen.
/// The newer plane takes over what was owed instead, and gives it back when it goes.
///
/// Keyed by the window's identity; the owed responder is held weakly.
@MainActor
public final class PlaneKeyboardHandoff {
    public static let shared = PlaneKeyboardHandoff()

    private struct Entry {
        var turn = 0
        weak var owed: AnyObject?
        weak var leaving: AnyObject?
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    /// A plane rises in `window`: any return still pending there stops, and what it owed is handed
    /// to this plane — with the going plane's own field (`leaving`), which may still hold the
    /// keyboard as this one rises and is no place to give it back to. Both nil when nothing was owed.
    public func rise(in window: ObjectIdentifier) -> (owed: AnyObject?, leaving: AnyObject?) {
        var entry = entries[window] ?? Entry()
        entry.turn += 1
        let handed = (owed: entry.owed, leaving: entry.owed == nil ? nil : entry.leaving)
        entry.owed = nil
        entry.leaving = nil
        entries[window] = entry
        return handed
    }

    /// A plane goes and owes `responder` back, its own field `leaving` still holding the keyboard (or
    /// nil): the return's turn, current until a plane rises.
    public func owe(_ responder: AnyObject, leaving: AnyObject?, in window: ObjectIdentifier) -> Int {
        var entry = entries[window] ?? Entry()
        entry.owed = responder
        entry.leaving = leaving
        entries[window] = entry
        return entry.turn
    }

    /// Whether the return made at `turn` may still give the keyboard.
    public func isCurrent(_ turn: Int, in window: ObjectIdentifier) -> Bool {
        entries[window]?.turn == turn
    }

    /// The return made at `turn` is over (given, or given up): nothing is owed any more.
    public func settle(_ turn: Int, in window: ObjectIdentifier) {
        guard isCurrent(turn, in: window) else { return }
        entries[window]?.owed = nil
        entries[window]?.leaving = nil
    }
}

/// One try of a plane's keyboard return.
public enum PlaneKeyboardReturnStep: Equatable, Sendable {
    /// Give the keyboard back now.
    case give
    /// The plane's own field still holds it: try again a frame later.
    case wait
    /// Give up: a newer plane rose, the operator moved, or the tries ran out.
    case stop
}

/// What a plane's keyboard return does on one try. `current`: no newer plane has risen since
/// (`PlaneKeyboardHandoff.isCurrent`). `free`: nothing holds the keyboard (or only a field editor
/// whose field has left the window). `stillLeaving`: what holds it is the plane's own field, not yet
/// gone. `triesLeft`: this try included.
public func planeKeyboardReturnStep(current: Bool, free: Bool, stillLeaving: Bool, triesLeft: Int)
    -> PlaneKeyboardReturnStep
{
    guard current else { return .stop }
    if free { return .give }
    return stillLeaving && triesLeft > 1 ? .wait : .stop
}
