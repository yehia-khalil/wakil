import Foundation
import Testing

/// Polls `flag` for up to five seconds. A gate that loses its release never
/// answers at all, so the guard has to observe the waiter from outside rather
/// than `await` it — awaiting a lost wakeup is the hang this file guards.
private func passes(_ waiting: Task<Void, Never>, flag: PassedFlag) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if flag.value { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return flag.value
}

private final class PassedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return passed }
    func set() { lock.lock(); passed = true; lock.unlock() }
}

/// **The hang of 2026-10-09, in its smallest form.** The test releases on a
/// signal the model raises before the double reaches its gate, so the release
/// can land first. A bare continuation dropped it and the waiter parked
/// forever; the gate keeps it.
@Test func aReleaseThatLandsBeforeTheWaiterStillLetsItThrough() async {
    let gate = HoldGate()
    gate.arm()
    gate.release()
    let flag = PassedFlag()
    let waiting = Task { await gate.wait(); flag.set() }
    #expect(await passes(waiting, flag: flag), "the early release was lost; the waiter is parked for good")
}

@Test func anArmedGateHoldsUntilReleased() async {
    let gate = HoldGate()
    gate.arm()
    let flag = PassedFlag()
    let waiting = Task { await gate.wait(); flag.set() }
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(!flag.value, "an armed gate let the waiter through unreleased")
    gate.release()
    #expect(await passes(waiting, flag: flag))
}

/// A release with no hold asked for changes nothing later: the next arm holds.
@Test func aReleaseOfAnUnarmedGateIsNotKeptForTheNextHold() async {
    let gate = HoldGate()
    gate.release()
    gate.arm()
    let flag = PassedFlag()
    let waiting = Task { await gate.wait(); flag.set() }
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(!flag.value, "a stray release before the arm let the hold through")
    gate.release()
    #expect(await passes(waiting, flag: flag))
}
