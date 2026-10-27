import Foundation

/// A page focus that may have to wait for its web view to join the window (3c-i, Rule 6): `attempt`
/// is tried now and, until it lands, up to `tries` more times, each scheduled by `schedule`. Before
/// **every** attempt `stillWanted` is asked — is the pane still focused, the keyboard still its to
/// take, the tab still the active one — and once it answers no, nothing more is tried or scheduled:
/// a focus asked for a second ago must not take the keyboard from where the operator has gone since.
@MainActor
public func browserRetryFocus(
    tries: Int,
    stillWanted: @escaping @MainActor () -> Bool,
    attempt: @escaping @MainActor () -> Bool,
    schedule: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void
) {
    guard stillWanted() else { return }
    if attempt() { return }
    guard tries > 0 else { return }
    schedule {
        browserRetryFocus(tries: tries - 1, stillWanted: stillWanted, attempt: attempt, schedule: schedule)
    }
}
