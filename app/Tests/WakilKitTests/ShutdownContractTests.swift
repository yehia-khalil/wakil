import Foundation
import Testing
@testable import WakilKit

/// Every long-lived pump `WindowModel` starts is cancelled by `shutdown()`.
///
/// **Behavioural, not a naming test.** `InvalidationContractTests` is the
/// other shape — it proves every stored property has been *classified* for
/// an org switch, and says so about itself. That test does catch a new
/// pump, but it catches it as *a property nobody classified*, and you
/// satisfy it by adding the name to `orgIndependent` one line below
/// `providerSwitchPump` — which asserts nothing about cancellation. This
/// test asserts the cancellation itself, so a sixth pump that `shutdown()`
/// forgets fails here rather than passing there.
///
/// **Keyed on the `Pump` suffix, not on being a `Task`.** `pendingSave` is
/// also a `Task` and must NOT be cancelled: it is the most recent layout
/// write, and cancelling it on the way out is how you lose the layout the
/// operator just arranged. `shutdown()`'s subjects are the long-lived
/// loops, which this codebase already names `…Pump` without exception.
///
/// **A `nil` pump is not a failure.** `eventPump` starts in `send`,
/// `resume` and `setProvider` rather than in `init`, so a model that never
/// ran a turn holds `nil` there. What is checked is every pump that was
/// actually started.
@MainActor
@Test func shutdownCancelsEveryPumpTheWindowStarted() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")

    await model.shutdown()

    var found: [String] = []
    var stillRunning: [String] = []

    for child in Mirror(reflecting: model).children {
        // `@Observable` rewrites stored properties into `_`-prefixed
        // backing storage and adds a `$`-bearing registrar — the same
        // normalisation, and the same reasoning, as
        // `InvalidationContractTests`.
        guard var label = child.label else { continue }
        if label.contains("$") { continue }
        if label.hasPrefix("_") { label.removeFirst() }
        guard label.hasSuffix("Pump") else { continue }

        found.append(label)
        // Fails the cast exactly when the pump is `nil`, i.e. never
        // started.
        guard let pump = child.value as? Task<Void, Never> else { continue }
        if !pump.isCancelled { stillRunning.append(label) }
    }

    #expect(
        !found.isEmpty,
        """
        No `…Pump` properties found on WindowModel at all. This test keys \
        on that suffix, so a rename has made it vacuous rather than \
        failing. Rename the pumps back, or re-key this test.
        """)

    #expect(
        stillRunning.isEmpty,
        """
        WindowModel.shutdown() left pump(s) running: \
        \(stillRunning.sorted().joined(separator: ", ")).

        shutdown() is awaited from applicationShouldTerminate, which \
        returns .terminateLater and waits on the whole chain. Its contract \
        is to stop the window's own work before the wiring below it goes \
        away, so every pump it started is cancelled here — add the missing \
        `?.cancel()` to shutdown() rather than exempting it.
        """)
}

/// `shutdown()`'s fifth line — `terminals.shutdownAll()` — is app quit's
/// kill point. Two panes, not one, because this is the one test whose
/// whole point is that shutdown reaps EVERY shell, not just the one it
/// happens to try first (Task 14).
@MainActor
@Test func quittingKillsEveryShell() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    var pids: [pid_t] = []
    for _ in 0..<2 {
        let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
        pids.append(await model.terminals.pidForTesting(paneId: pane)!)
    }

    await model.shutdown()

    for pid in pids { #expect(kill(pid, 0) == -1) }
}

/// Quit stops every place's agent, not just the one on screen (background agents 3 of 4,
/// Task 7). Three agents in three places: each one's harness, the socket its shim reaches
/// Wakil on, and its event pump all end with the window, however the screen has moved since
/// they started — an agent left running would outlive the app.
@MainActor
@Test func quittingStopsEveryPlacesAgent() async throws {
    let org = "initech"
    let places = ["api", "billing", "ledger"].map {
        Place(organization: org, project: $0, environment: "staging")
    }
    let sessions = Sessions()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: org,
        harnessFactory: { place, _ in sessions.harnesses.make(place) },
        agentSocketFactory: sessions.socketFactory)
    for place in places {
        model.seedForTesting(
            providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
            project: place.project, environment: place.environment)
        #expect(await model.send("hello \(place.project)"))
    }
    try #require(model.agents.count == 3)
    let pumps = try places.map { try #require(model.agents[$0]?.eventPump, "\($0.project) has no pump") }
    #expect(sessions.harnesses.issued.allSatisfy { !$0.stopped })
    #expect(sessions.issuedSockets.allSatisfy { !$0.stopped })

    await model.shutdown()

    #expect(sessions.harnesses.issued.count == 3)
    #expect(sessions.harnesses.issued.allSatisfy { $0.stopped }, "every harness stopped")
    #expect(sessions.issuedSockets.count == 3)
    #expect(sessions.issuedSockets.allSatisfy { $0.stopped }, "every agent's socket stopped")
    #expect(pumps.allSatisfy { $0.isCancelled }, "every agent's event pump cancelled")
}
