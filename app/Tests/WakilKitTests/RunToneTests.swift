import Foundation
import Testing
@testable import WakilKit

// The walk: the home card read "parkour-warriors failed" in the running green. Design-language §5:
// red means failed, green healthy or completed only. Every run state has its colour.

@Test func everyRunStateHasItsColour() {
    let step = RunStepNow(step: "setup", command: "composer install", started: Date())
    let waitingStep = RunStepNow(step: "waiting for ready", command: "http://localhost:41210/up", started: Date())
    #expect(RepoRunState(repo: "api", phase: .starting("setting up")).tone == .working)
    #expect(RepoRunState(repo: "api", phase: .starting("setting up"), step: step).tone == .working)
    #expect(RepoRunState(repo: "api", phase: .building).tone == .working)
    #expect(RepoRunState(repo: "api", phase: .starting("waiting for ready")).tone == .waiting)
    #expect(RepoRunState(repo: "api", phase: .starting("setting up"), step: waitingStep).tone == .waiting)
    #expect(RepoRunState(repo: "api", phase: .running).tone == .ready)
    #expect(RepoRunState(repo: "api", phase: .failed("started but is not ready")).tone == .failed)

    #expect(RunTone.working.colour == VoidPalette.accent, "violet, raised to read as text")
    #expect(RunTone.waiting.colour == HomePalette.amber)
    #expect(RunTone.ready.colour == HomePalette.green)
    #expect(RunTone.failed.colour == HomePalette.red)
    #expect(HomePalette.red == RGB(0.910, 0.361, 0.361), "#e85c5c")
}

@Test func aCardsRunToneIsItsMostUrgentRepos() {
    let running = RepoRunState(repo: "web", phase: .running)
    let failed = RepoRunState(repo: "api", phase: .failed("x"))
    let waiting = RepoRunState(repo: "core", phase: .starting("waiting for ready"))
    let working = RepoRunState(repo: "jobs", phase: .building)
    #expect(runTone([]) == nil)
    #expect(runTone([running]) == .ready)
    #expect(runTone([running, working]) == .working)
    #expect(runTone([working, waiting, running]) == .waiting)
    #expect(runTone([running, waiting, failed]) == .failed)
}
