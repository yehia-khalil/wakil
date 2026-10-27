import Testing
@testable import WakilKit

/// Rule 6 (3c-ii review I2): a plane that has gone retries giving the keyboard back for up to a
/// second — and a newer plane that rises meanwhile stops that retry, taking over what was owed, so
/// the composer never ends up holding the keyboard under a question on screen.
@MainActor
@Suite struct PlaneKeyboardHandoffTests {
    final class Responder {}

    @Test func aReturnStaysCurrentUntilAPlaneRises() {
        let handoff = PlaneKeyboardHandoff()
        let window = ObjectIdentifier(Responder())
        let composer = Responder()
        let turn = handoff.owe(composer, leaving: nil, in: window)
        #expect(handoff.isCurrent(turn, in: window))
        _ = handoff.rise(in: window)
        #expect(!handoff.isCurrent(turn, in: window), "the newer plane ended the older plane's retry")
    }

    @Test func theRisingPlaneTakesOverWhatWasOwedAndTheLeavingField() {
        let handoff = PlaneKeyboardHandoff()
        let window = ObjectIdentifier(Responder())
        let composer = Responder(), field = Responder()
        _ = handoff.owe(composer, leaving: field, in: window)
        let handed = handoff.rise(in: window)
        #expect(handed.owed === composer)
        #expect(handed.leaving === field)
        let next = handoff.rise(in: window)
        #expect(next.owed == nil && next.leaving == nil, "handed over once")
    }

    @Test func nothingIsOwedOnceTheReturnSettles() {
        let handoff = PlaneKeyboardHandoff()
        let window = ObjectIdentifier(Responder())
        let composer = Responder()
        let turn = handoff.owe(composer, leaving: nil, in: window)
        handoff.settle(turn, in: window)
        #expect(handoff.rise(in: window).owed == nil)
    }

    @Test func aStaleReturnSettlingDoesNotClearANewerOne() {
        let handoff = PlaneKeyboardHandoff()
        let window = ObjectIdentifier(Responder())
        let composer = Responder()
        let old = handoff.owe(composer, leaving: nil, in: window)
        _ = handoff.rise(in: window)
        _ = handoff.owe(composer, leaving: nil, in: window)
        handoff.settle(old, in: window)
        #expect(handoff.rise(in: window).owed === composer)
    }

    @Test func windowsAreSeparate() {
        let handoff = PlaneKeyboardHandoff()
        let first = Responder(), second = Responder()   // both alive, so their identities differ
        let a = ObjectIdentifier(first), b = ObjectIdentifier(second)
        let composer = Responder()
        let turn = handoff.owe(composer, leaving: nil, in: a)
        _ = handoff.rise(in: b)
        #expect(handoff.isCurrent(turn, in: a), "a plane in another window does not stop this return")
        withExtendedLifetime((first, second)) {}
    }

    @Test func aNewerPlaneStopsTheReturnEvenWhenTheKeyboardLooksFree() {
        // The review's scenario: the newer plane, with no field, cleared the keyboard to the window.
        #expect(planeKeyboardReturnStep(current: false, free: true, stillLeaving: false, triesLeft: 15) == .stop)
        #expect(planeKeyboardReturnStep(current: false, free: false, stillLeaving: true, triesLeft: 15) == .stop)
    }

    @Test func theCurrentReturnGivesWaitsAndGivesUp() {
        #expect(planeKeyboardReturnStep(current: true, free: true, stillLeaving: false, triesLeft: 20) == .give)
        #expect(planeKeyboardReturnStep(current: true, free: false, stillLeaving: true, triesLeft: 20) == .wait)
        #expect(planeKeyboardReturnStep(current: true, free: false, stillLeaving: true, triesLeft: 1) == .stop,
                "out of tries")
        #expect(planeKeyboardReturnStep(current: true, free: false, stillLeaving: false, triesLeft: 20) == .stop,
                "the operator moved: their field keeps the keyboard")
    }
}
