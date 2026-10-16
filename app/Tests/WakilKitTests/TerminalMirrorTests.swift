import Foundation
import Testing
@testable import WakilKit

/// Task 15's mirror — the agent's own `Bash` calls, drawn into every open
/// terminal pane. Every test here is a pure decode or a `PaneStore` call:
/// none spawns a real shell, per the brief's own hazard note two tasks
/// ago, where surplus real-process load turned a pre-existing
/// load-sensitive race from intermittent into deterministic and reddened
/// the whole gate.
@Test func aBashToolCallBecomesAMirroredBlockAndItsResultFillsItIn() {
    let events: [MirrorEvent] = [
        MirrorEvent(.toolUse(id: "t1", name: "Bash", input: .object(["command": .string("rg TODO")])), at: Date()),
        MirrorEvent(.toolResult(id: "t1", content: .string("src/a.swift:4:TODO\n"), isError: false), at: Date()),
    ]

    let blocks = mirroredBlocks(from: events, cap: TerminalBlock.historyCap)

    #expect(blocks.count == 1)
    #expect(blocks[0].command == "rg TODO")
    #expect(blocks[0].origin == .agent)
    #expect(blocks[0].output == ["src/a.swift:4:TODO"])
    #expect(blocks[0].exitCode == 0)
}

@Test func aToolCallWhoseResultHasNotArrivedIsARunningBlockWithNoExitCode() {
    // toolUse arrives the instant the agent issues the call, BEFORE the
    // command runs; toolResult arrives whole when it finishes. So the
    // block appears immediately and fills in on completion — and
    // characters never scroll as they are produced, and cannot, because
    // those Bash calls never reach Wakil while they run. Realtime is true
    // of WHAT it is running, not of watching it scroll. Hence an elapsed
    // counter and no progress bar: Wakil has no idea how far along it is.
    let blocks = mirroredBlocks(
        from: [MirrorEvent(
            .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("make")])), at: Date())],
        cap: TerminalBlock.historyCap)

    #expect(blocks.count == 1)
    #expect(blocks[0].exitCode == nil)
    #expect(blocks[0].durationMs == nil)
}

@Test func aFailedToolResultIsANonZeroExitRatherThanASuccess() {
    let blocks = mirroredBlocks(from: [
        MirrorEvent(.toolUse(id: "t1", name: "Bash", input: .object(["command": .string("false")])), at: Date()),
        MirrorEvent(.toolResult(id: "t1", content: .string("exit 1"), isError: true), at: Date()),
    ], cap: TerminalBlock.historyCap)
    #expect(blocks[0].exitCode == 1)
}

@Test func onlyBashIsMirrored() {
    // A terminal is a shell surface. File reads and edits belong to the
    // thought thread now and the editor pane in Phase 3; mirroring every
    // tool turns the terminal into a second, worse thought thread.
    let blocks = mirroredBlocks(from: [
        MirrorEvent(.toolUse(id: "t1", name: "Read", input: .object(["file_path": .string("/tmp/x")])), at: Date()),
        MirrorEvent(.toolUse(id: "t2", name: "mcp__wakil__read_pane", input: .object([:])), at: Date()),
        MirrorEvent(.toolUse(id: "t3", name: "Bash", input: .object(["command": .string("ls")])), at: Date()),
    ], cap: TerminalBlock.historyCap)

    #expect(blocks.map(\.command) == ["ls"])
}

@Test func aMirroredBlocksStartedAtIsTheArrivalTimeItWasGivenNotASynthesizedOne() {
    // Fix round 1 (Critical). The first cut gave every mirrored block an
    // index-derived `startedAt` (`Date(timeIntervalSince1970:
    // Double(order.count))` — epoch 1970 plus a few seconds), computed
    // INSIDE this pure decode because `HarnessEvent` itself carries no
    // timestamp. `PaneStore.recordTerminal` inserts by `startedAt`, so
    // that synthetic value sorted every mirrored block ahead of every real
    // operator block, unconditionally. The fix: `mirroredBlocks` reads the
    // arrival time it is HANDED, in `MirrorEvent.at`, rather than
    // computing one — this pins that it does, at real operator-block
    // magnitude, not near epoch 1970.
    let arrival = Date(timeIntervalSince1970: 1_700_000_000)
    let blocks = mirroredBlocks(from: [
        MirrorEvent(
            .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")])), at: arrival),
    ], cap: TerminalBlock.historyCap)

    #expect(blocks[0].startedAt == arrival)
}

@Test func mirroredAndOperatorBlocksInterleaveChronologicallyAcrossBothOrigins() async {
    // The thing that was actually broken: a history that filed every
    // mirrored block before every operator block, regardless of when each
    // one really ran. `PaneStore.recordTerminal` and `.appendMirrored` are
    // exercised directly — no real shell needed to prove ordering, since
    // an operator block is simulated the same way `TerminalSession`'s own
    // publisher would produce one.
    let panes = PaneStore()
    let early = Date(timeIntervalSince1970: 1_700_000_000)
    let middle = Date(timeIntervalSince1970: 1_700_000_500)
    let late = Date(timeIntervalSince1970: 1_700_001_000)

    await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
        id: "op-early", command: "ls", origin: .operatorTyped, exitCode: 0,
        durationMs: 1, output: [], heldTheGrid: false, startedAt: early))
    await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
        id: "op-late", command: "pwd", origin: .operatorTyped, exitCode: 0,
        durationMs: 1, output: [], heldTheGrid: false, startedAt: late))

    let mirrored = mirroredBlocks(from: [
        MirrorEvent(
            .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("rg TODO")])),
            at: middle),
    ], cap: TerminalBlock.historyCap)
    await panes.appendMirrored(paneId: "terminal-1", block: mirrored[0])

    let order = await panes.terminalBlocks(paneId: "terminal-1").map(\.id)
    #expect(order == ["op-early", "t1", "op-late"])
}

@Test @MainActor func theMirrorIsBackfilledWhenThePaneOpensRatherThanStartingEmpty() async {
    // "Not always open a terminal, but when it is open I would like to see
    // it" — a pane opened BECAUSE you want to see what Wakil is doing must
    // not be empty until its next command. The record predates the pane:
    // it is reconstructed from the transcript Wakil already holds.
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    await model.receiveForTesting(
        .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("git status")])))
    await model.receiveForTesting(.toolResult(id: "t1", content: .string("clean"), isError: false))

    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())

    let blocks = await model.panesForTesting.terminalBlocks(paneId: pane)
    #expect(blocks.contains { $0.command == "git status" && $0.origin == .agent })
    await model.shutdown()
}

@Test @MainActor func everyOpenTerminalPaneCarriesTheMirror() async {
    // The alternative was a nearest-cwd heuristic: a rule the operator has
    // to learn and cannot predict with two panes open. The mirror is a
    // VIEW on one record, and a view that appears in one pane and not
    // another is the worse failure. Duplication is what a view is for.
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let first = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    let second = await model.openTerminalForTesting(path: NSTemporaryDirectory())

    await model.receiveForTesting(
        .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("docker ps")])))

    for pane in [first, second] {
        #expect(await model.panesForTesting.terminalBlocks(paneId: pane)
            .contains { $0.command == "docker ps" })
    }
    await model.shutdown()
}

@Test func theMirrorReachesTheSnapshotUnderAFullScreenProgramAndOnlyItsDrawingPauses() async {
    // Two-axis review, Spec 6. This used to assert the opposite — that a
    // mirrored block arriving under `vim` was withheld from `blocks`
    // entirely until the program exited — which made `read_pane` hide the
    // agent's own commands for the length of a `vim` session. Story 46 is
    // explicit that it must not: "mirrored blocks present individually in
    // the snapshot even when the screen groups them, so that a rendering
    // choice never changes what I can read." The pause survives as a
    // DRAWING decision, in `parkedHistoryBlocks`, asserted below.
    let panes = PaneStore()
    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/tmp", shell: "zsh", cols: 80, rows: 24,
        screen: .grid, grid: ["vim"])

    await panes.appendMirrored(paneId: "terminal-1", block: TerminalBlock(
        id: "m1", command: "rg TODO", origin: .agent, exitCode: 0, durationMs: 4,
        output: [], heldTheGrid: false, startedAt: Date()))

    // Readable immediately — through the snapshot the agent actually gets,
    // not only through the store's own accessor.
    guard let underTheProgram =
        (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).terminal
    else { Issue.record("no snapshot"); return }
    #expect(underTheProgram.blocks.map(\.id) == ["m1"])

    // And withheld from the strip drawn above the program's own screen,
    // which is the only thing that ever pauses.
    #expect(parkedHistoryBlocks(underTheProgram.blocks).isEmpty)

    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/tmp", shell: "zsh", cols: 80, rows: 24,
        screen: .blocks, grid: [])

    // Nothing to catch up: it was never held back.
    #expect(await panes.terminalBlocks(paneId: "terminal-1").count == 1)
}

@Test func groupingIsARenderingAndTheSnapshotStillReturnsEveryBlock() async {
    // Consecutive agent blocks collapse into one expandable group on
    // screen, so a turn of six greps does not bury the operator's history
    // in someone else's. The group is a RENDERING, not state.
    let panes = PaneStore()
    for index in 0..<6 {
        await panes.appendMirrored(paneId: "terminal-1", block: TerminalBlock(
            id: "m\(index)", command: "rg \(index)", origin: .agent, exitCode: 0,
            durationMs: 1, output: [], heldTheGrid: false,
            startedAt: Date(timeIntervalSince1970: Double(index))))
    }

    guard let snapshot = (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).terminal
    else { Issue.record("no snapshot"); return }
    #expect(snapshot.blocks.count == 6)
    #expect(snapshot.blocks.allSatisfy { $0.origin == .agent })
}
