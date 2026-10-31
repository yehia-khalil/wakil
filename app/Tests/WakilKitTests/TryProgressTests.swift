import Foundation
import Testing
@testable import WakilKit

/// Try's step list and a card's running line (the walk: one line for minutes).
@Suite struct TryProgressTests {
    @Test func aStatusDecodesIntoRowsWithTheirMarksTitlesAndTimes() throws {
        let json = """
        {"steps":[
          {"phase":"prepare","state":"done","seconds":0.2,"output":"copied .env"},
          {"phase":"setup","command":"composer install","state":"done","seconds":64.4},
          {"phase":"setup","command":"npm ci","state":"running","seconds":12.2,"output":"added 1 package\\nadded 2 packages","lastLine":"added 2 packages"},
          {"phase":"process","name":"web","command":"php artisan serve","state":"to come"},
          {"phase":"ready","command":"http://localhost:41200/up","state":"to come"}
        ],"finished":false}
        """
        let p = try JSONDecoder().decode(TryProgressState.self, from: Data(json.utf8))
        #expect(p.steps.map(\.mark) == ["✓", "✓", "●", "○", "○"])
        #expect(p.steps.map(\.title) == ["prepared — copied .env", "setup · composer install", "setup · npm ci",
                                         "web started · php artisan serve", "ready · http://localhost:41200/up"])
        #expect(p.steps.map(\.time) == ["0 s", "1 min 4 s", "12 s", nil, nil])
        #expect(p.shown?.command == "npm ci")
        #expect(p.shown?.lastLine == "added 2 packages")
    }

    @Test func theFailedStepIsTheOneShownWhenNothingRuns() throws {
        let p = TryProgressState(steps: [
            TryStepState(phase: "setup", command: "composer install", state: .failed, output: "Your lock file is out of date."),
            TryStepState(phase: "process", name: "web", command: "php artisan serve", state: .toCome),
        ], finished: true)
        #expect(p.shown?.output == "Your lock file is out of date.")
        #expect(p.steps[0].mark == "✗")
    }

    /// The card: `<step> · <command> · <elapsed>` until ready, then `running on :<port>`.
    @Test func aCardsRunLineNamesTheStepItsCommandAndTheTimeSoFar() {
        let began = Date(timeIntervalSince1970: 1_000)
        var s = RepoRunState(repo: "api", port: 41200, phase: .starting("setting up"),
                             step: RunStepNow(step: "setup", command: "composer install", started: began))
        #expect(s.line(now: began.addingTimeInterval(75)) == "api setup · composer install · 1 min 15 s")
        s.phase = .running
        s.step = nil
        s.processes = [("api", "terminal-2")]
        #expect(s.line(now: began) == "api running on :41200")
    }
}
