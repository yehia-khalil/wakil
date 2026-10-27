import Testing
@testable import WakilKit

/// Rule 6 (Task 10 fix round 1): a page focus that waits for its web view to join the window asks
/// again, on every attempt, whether the pane may still take the keyboard and the tab is still the
/// active one — and gives up quietly when not.
@MainActor
@Suite struct BrowserFocusRetryTests {
    /// Runs scheduled attempts by hand, one at a time.
    final class Later {
        var queued: [() -> Void] = []
        func run() { let next = queued.removeFirst(); next() }
    }

    @Test func itKeepsTryingWhileWantedAndStopsOnceItLands() {
        let later = Later()
        var attempts = 0
        browserRetryFocus(tries: 5, stillWanted: { true }, attempt: { attempts += 1; return attempts == 3 },
                          schedule: { later.queued.append($0) })
        #expect(attempts == 1)
        later.run(); later.run()
        #expect(attempts == 3)
        #expect(later.queued.isEmpty, "landed: nothing more scheduled")
    }

    @Test func itGivesUpQuietlyTheMomentTheKeyboardIsNoLongerItsToTake() {
        let later = Later()
        var wanted = true
        var attempts = 0
        browserRetryFocus(tries: 5, stillWanted: { wanted }, attempt: { attempts += 1; return false },
                          schedule: { later.queued.append($0) })
        #expect(attempts == 1)
        wanted = false   // the operator opened ⌘K, or another tab came to the front
        later.run()
        #expect(attempts == 1, "not attempted once unwanted")
        #expect(later.queued.isEmpty, "and nothing more scheduled")
    }

    @Test func itIsNotAttemptedAtAllWhenUnwantedFromTheStart() {
        let later = Later()
        var attempts = 0
        browserRetryFocus(tries: 5, stillWanted: { false }, attempt: { attempts += 1; return true },
                          schedule: { later.queued.append($0) })
        #expect(attempts == 0 && later.queued.isEmpty)
    }

    @Test func itStopsAfterItsTries() {
        let later = Later()
        var attempts = 0
        browserRetryFocus(tries: 2, stillWanted: { true }, attempt: { attempts += 1; return false },
                          schedule: { later.queued.append($0) })
        while !later.queued.isEmpty { later.run() }
        #expect(attempts == 3, "the first try and two more")
    }
}
