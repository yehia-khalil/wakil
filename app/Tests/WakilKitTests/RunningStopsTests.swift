import Foundation
import Testing
@testable import WakilKit

// The Running page as a run (the comp, 2026-11-02): four stops on one spine, unset fields as
// chips, ports as a table with their first-block numbers, and a Try lighting each stop.

private func settings(_ json: String) throws -> RunningSettings {
    try RunningSettings.decode(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
}

private let sail = """
{"project":"estate","problems":[],
 "recipes":{"laravel-sail":{"copy":[".env"],"setup":["composer install"],
   "services":["sail up -d mysql"],
   "processes":[{"name":"app","command":"sail up laravel.test"},{"name":"queue","command":"sail artisan queue:work"}],
   "ports":{"APP_PORT":"$WAKIL_PORT","FORWARD_DB_PORT":"$WAKIL_PORT_2","VITE_API":"${WAKIL_PORT_1}","WEB":"$WAKIL_PORT_WEB"},
   "ready":{"url":"http://localhost:$WAKIL_PORT/up"},"teardown":["sail down"]}},
 "repos":[
   {"repo":"api","path":"/p/api","recipe":"laravel-sail","overrides":{"setup":[],"build":"npm run build"}},
   {"repo":"web","path":"/p/web","recipe":"laravel-sail"}]}
"""

@Test func theFourStopsHoldEveryFieldButPortsOnceInTheOrderTheyRun() {
    #expect(RunStop.allCases.map(\.title) == ["Prepare a new copy", "Start", "Ready when", "Stop"])
    #expect(RunStop.allCases.map(\.when) == ["once, on the first ▶ in a new workspace", "every ▶, in this order",
                                             "the run counts as up", "on ■ Stop or Archive"])
    #expect(RunStop.prepare.fields == [.copy, .clone, .setup, .build])
    #expect(RunStop.start.fields == [.needs, .services, .processes])
    #expect(RunStop.ready.fields == [.ready])
    #expect(RunStop.stop.fields == [.teardown])
    let all = RunStop.allCases.flatMap(\.fields)
    #expect(all.count == RecipeField.allCases.count - 1)
    #expect(Set(all) == Set(RecipeField.allCases).subtracting([.ports]))
}

@Test func aTryStepRunsInTheStopItsPhaseBelongsTo() {
    #expect(["copy", "prepare", "clone", "setup", "build"].map { RunStop.of(phase: $0) } == Array(repeating: .prepare, count: 5))
    #expect(["need", "service", "process"].map { RunStop.of(phase: $0) } == [.start, .start, .start])
    #expect(RunStop.of(phase: "ready") == .ready)
    #expect(RunStop.of(phase: "teardown") == .stop)
    #expect(RunStop.of(phase: "something") == nil)
}

@Test func anUnsetFieldIsAChipAndAnOpenedOneARow() throws {
    let s = try settings(sail)
    // web: the recipe's copy, setup; no clone, no build.
    #expect(s.stopFields(.prepare, of: "web") == RunStopFields(rows: [.copy, .setup], chips: [.clone, .build]))
    #expect(s.stopFields(.start, of: "web") == RunStopFields(rows: [.services, .processes], chips: [.needs]))
    #expect(s.stopFields(.ready, of: "web") == RunStopFields(rows: [.ready], chips: []))
    // Pressing + Build opens it as a row, empty.
    #expect(s.stopFields(.prepare, of: "web", open: [.build]) == RunStopFields(rows: [.copy, .setup, .build], chips: [.clone]))
}

@Test func aRepoEmptyingTheRecipesFieldKeepsItsRowSoItCanBeUndone() throws {
    let s = try settings(sail)
    // api's own setup is empty over the recipe's: drawn, this repo only.
    #expect(s.isDrawn(.setup, of: "api"))
    #expect(s.field(.setup, of: "api").source == .repo)
    #expect(s.stopFields(.prepare, of: "api") == RunStopFields(rows: [.copy, .setup, .build], chips: [.clone]))
}

@Test func clearingAFieldTheRecipeLeavesUnsetReturnsItToAChip() throws {
    let s = try settings(sail)
    let saved = s.savingField(.build, "", of: "api")
    guard case .object(let o)? = saved, case .object(let repos)? = o["repos"], case .object(let api)? = repos["api"],
          case .object(let own)? = api["overrides"] else { Issue.record("no overrides"); return }
    #expect(own["build"] == nil)
}

@Test func processesAreDrawnNameThenCommandAlignedAndReadBackEitherWay() throws {
    let s = try settings(sail)
    #expect(s.formText(.processes, of: "web") == "app    sail up laravel.test\nqueue  sail artisan queue:work")
    let back = RecipeField.processes.set("app    sail up laravel.test\nqueue  sail artisan queue:work (after ready)", in: Recipe())
    #expect(back.processes == [RecipeProcess(name: "app", command: "sail up laravel.test"),
                               RecipeProcess(name: "queue", command: "sail artisan queue:work", afterReady: true)])
    #expect(RecipeField.processes.set("web: pnpm dev", in: Recipe()).processes == [RecipeProcess(name: "web", command: "pnpm dev")])
    // The same processes typed aligned are what the recipe says: no override is kept.
    let saving = s.savingField(.processes, "app  sail up laravel.test\nqueue  sail artisan queue:work", of: "web")
    guard case .object(let o)? = saving, case .object(let repos)? = o["repos"], case .object(let web)? = repos["web"] else {
        Issue.record("no repo"); return
    }
    #expect(web["overrides"] == nil)
}

@Test func theReadyRowSaysHowItIsMet() throws {
    let s = try settings(sail)
    #expect(s.rowLabel(.ready, of: "web") == "Answers")
    #expect(RecipeField.ready.rowLabel(in: RecipeField.ready.set("Serving HTTP", in: Recipe())) == "Prints")
    #expect(s.rowLabel(.setup, of: "web") == "Setup")
    #expect(RecipeField.needs.chipHint == "start another repo first")
    #expect(RecipeField.ready.chipLabel == "Ready" && RecipeField.build.chipLabel == "Build")
}

@Test func aPortShowsItsFirstBlockNumberOnlyWhenItIsAPlainWakilPort() throws {
    #expect(firstBlockPort("$WAKIL_PORT") == 41200)
    #expect(firstBlockPort("$WAKIL_PORT_1") == 41201)
    #expect(firstBlockPort("${WAKIL_PORT_9}") == 41209)
    #expect(firstBlockPort("$WAKIL_PORT_10") == nil)
    #expect(firstBlockPort("$WAKIL_PORT_WEB") == nil)
    #expect(firstBlockPort("http://localhost:$WAKIL_PORT") == nil)
    #expect(firstBlockPort("8080") == nil)
    let s = try settings(sail)
    #expect(s.portRows(of: "web") == [
        RunPortRow(variable: "APP_PORT", expression: "$WAKIL_PORT", port: 41200),
        RunPortRow(variable: "FORWARD_DB_PORT", expression: "$WAKIL_PORT_2", port: 41202),
        RunPortRow(variable: "VITE_API", expression: "${WAKIL_PORT_1}", port: 41201),
        RunPortRow(variable: "WEB", expression: "$WAKIL_PORT_WEB", port: nil),
    ])
}

private func step(_ phase: String, _ state: TryStepState.State, name: String = "", seconds: Double = 0) -> TryStepState {
    TryStepState(phase: phase, name: name, command: "x", state: state, seconds: seconds)
}

@Test func aRunningTryLightsEachStopByItsSteps() {
    let steps = [step("copy", .done, seconds: 2), step("prepare", .done, seconds: 1), step("service", .done, seconds: 4),
                 step("setup", .done, seconds: 3), step("process", .running, name: "web", seconds: 5),
                 step("ready", .toCome), step("teardown", .toCome)]
    let p = runStopProgress(steps, finished: false)
    #expect(p[.prepare]?.status == .passed && p[.prepare]?.when == "done in 6 s")
    #expect(p[.prepare]?.steps.map(\.index) == [0, 1, 3])
    #expect(p[.start]?.status == .running && p[.start]?.when == "web running")
    #expect(p[.ready]?.status == .idle && p[.ready]?.when == "to come")
    #expect(p[.stop]?.status == .idle && p[.stop]?.when == "runs when the Try ends")
    #expect(tryStatusDetail(steps, elapsed: 72) == "Start · web started · x · 1 min 12 s")
    #expect(tryStatusDetail([], elapsed: 3) == "3 s")
}

@Test func aFailedTryRedsItsStopAndLeavesTheRestNotReached() {
    var failed = step("process", .failed, name: "queue")
    failed.detail = "exited 1"
    let steps = [step("copy", .done), step("prepare", .done), step("process", .done, name: "app"), failed,
                 step("ready", .toCome), step("teardown", .done)]
    let p = runStopProgress(steps, finished: true)
    #expect(p[.start]?.status == .failed && p[.start]?.when == "queue failed")
    #expect(p[.start]?.failed?.detail == "exited 1")
    #expect(p[.ready]?.status == .notReached && p[.ready]?.when == "not reached")
    #expect(p[.stop]?.status == .passed)
}

@Test func aFinishedReportWithoutProgressIsDrawnAsStepsWithItsReadyCheckLast() {
    let report = RunTryResult(passed: false, steps: [RunStepResult(phase: "setup", command: "false", ok: false, detail: "exit 1")],
                              ready: RunReadyResult(ready: false, detail: "never answered"))
    let rows = tryStepStates(report)
    #expect(rows.map(\.phase) == ["setup", "ready"])
    #expect(rows.map(\.state) == [.failed, .failed])
    let p = runStopProgress(rows, finished: true)
    #expect(p[.prepare]?.status == .failed && p[.ready]?.status == .failed)
    #expect(p[.start]?.status == .notReached)
}
