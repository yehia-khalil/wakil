import Foundation
import Testing
@testable import WakilKit

/// The running app's address as a link (the walk): the app's root on its port, never the ready path.
@Suite struct RunAddressTests {
    @Test func theAddressIsTheAppsRootOnItsPort() {
        #expect(runAppAddress(port: 41220) == "http://localhost:41220/")
        #expect(runAppLabel(port: 41220) == ":41220")
    }

    @Test func onlyAReadyRepoWithAPortIsLinked() {
        let began = Date(timeIntervalSince1970: 1_000)
        let states = [
            RepoRunState(repo: "api", port: 41200, processes: [("app", "terminal-2")], phase: .running, ready: "answered 200"),
            RepoRunState(repo: "web", port: 41210, processes: [("dev", "terminal-3")], phase: .starting("waiting for ready"),
                         step: .readyCheck("http://localhost:41210/up", started: began)),
            RepoRunState(repo: "queue", processes: [("work", "terminal-4")], phase: .running),
            RepoRunState(repo: "core", port: 41230, phase: .failed("boom")),
            RepoRunState(repo: "db", port: 41240, phase: .running),
        ]
        #expect(runAppPorts(states) == [41200])
    }
}
