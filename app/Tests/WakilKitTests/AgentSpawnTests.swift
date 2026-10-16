import Foundation
import Testing

@testable import WakilKit

/// Does a turn actually spawn the agent the provider record names?
///
/// **#284's symptom, at the only seam below the window server.** The e2e
/// harness reports *the window never launched the scripted agent* by the
/// absence of a file the agent writes on startup, and that check can only run
/// with an unlocked Mac, a staged bundle and thirty seconds of polling. Every
/// layer it crosses — Orca, the accessibility tree, a click, a composer — is a
/// layer that can fail and be mistaken for this. These tests cross none of
/// them: they call `WindowModel.send` directly, with the REAL
/// `ClaudeCodeCLIHarness`, and ask the one question the harness asks.
///
/// **A script, not `e2e/bin/wakil-e2e-agent`.** `make app-test` does not build
/// Go (the Swift suite runs against whatever `bin/` holds), so depending on
/// the stub would make this skip on a fresh clone — an assertion that cannot
/// fail, which is the one thing `docs/agents/e2e.md` forbids outright. What is
/// under test is that a turn spawns the recorded executable with
/// `CLAUDE_CONFIG_DIR` set, and eight lines of `sh` answer that exactly as
/// well as fourteen megabytes of Go.
private struct SpawnFixture {
    let root: URL
    let agent: URL
    let configDir: URL
    var log: URL { configDir.appendingPathComponent("spawned.txt") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-spawn-\(UUID().uuidString)", isDirectory: true)
        configDir = root.appendingPathComponent("config", isDirectory: true)
        agent = root.appendingPathComponent("agent.sh")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Records that it ran, and what it was told — then exits. It never
        // answers the turn: what is asserted here is the spawn, and a stub
        // that spoke stream-json would be asserting the protocol too.
        try """
        #!/bin/sh
        printf 'spawned cwd=%s config=%s token=%s\\n' \
            "$PWD" "$CLAUDE_CONFIG_DIR" "$CLAUDE_CODE_OAUTH_TOKEN" \
            > "$CLAUDE_CONFIG_DIR/spawned.txt"
        exit 0
        """.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
    }

    func harness() -> ClaudeCodeCLIHarness {
        ClaudeCodeCLIHarness(
            claudePath: agent.path,
            configDir: configDir.path,
            oauthToken: "spawn-test-not-a-real-token",
            mcpConfigJSON: "{\"mcpServers\":{}}",
            allowedTools: [])
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// What the agent recorded, or nil if it never ran. Polled rather than
    /// read once: `Process.run()` returns as soon as the child is spawned, and
    /// the child writing its file is a separate thing that happens after.
    func spawnRecord(within seconds: Double = 10) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let body = try? String(contentsOf: log, encoding: .utf8) { return body }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try? String(contentsOf: log, encoding: .utf8)
    }
}

private struct SpawnCredentialsLookup: ProviderCredentialsLookup {
    let agentPath: String
    let configDir: String
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(
            claudePath: agentPath, configDir: configDir,
            oauthToken: "spawn-test-not-a-real-token")
    }
}

/// **The regression test #284 never had.** A turn that reaches `send` must
/// leave a running agent behind it; the harness could only observe that
/// through a window, and a window is exactly what was unavailable while the
/// symptom was live.
@Test @MainActor func aTurnSpawnsTheAgentTheProviderRecordNames() async throws {
    let fixture = try SpawnFixture()
    defer { fixture.cleanUp() }
    let (registry, panes, layout) = try makeSpawnRegistry()
    let harness = fixture.harness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in harness }, resumes: ResumeBroker(),
        rootPath: fixture.root.path, providerId: "spawn",
        lookup: SpawnCredentialsLookup(
            agentPath: fixture.agent.path, configDir: fixture.configDir.path))

    await model.send("propose a command that prints hello")

    let record = await fixture.spawnRecord()
    #expect(record != nil, """
        the turn returned but nothing spawned the agent at \(fixture.agent.path). \
        This is #284's symptom — "the window never launched the scripted agent" — \
        reached without a window, a bundle or Orca. status was "\(model.status)"
        """)
    // The environment is asserted too, because a child spawned WITHOUT
    // `CLAUDE_CONFIG_DIR` writes no log at all and is indistinguishable, from
    // outside, from a child that never spawned. That ambiguity is half of why
    // #284 took as long as it did.
    #expect(record?.contains("config=\(fixture.configDir.path)") == true, "\(record ?? "nil")")
}

/// **Repeated, because the bug was reported as *sometimes*.** A single green
/// run says nothing about an intermittent spawn; the reproduction rate is the
/// measurement. Twenty is what fits in a suite that runs on every commit —
/// enough to catch anything that fails as often as #284 did when it was
/// reproducing, and cheap because each turn is a process that exits at once.
@Test @MainActor func twentyConsecutiveTurnsEachSpawnTheirOwnAgent() async throws {
    var failures: [Int] = []
    for attempt in 1...20 {
        let fixture = try SpawnFixture()
        defer { fixture.cleanUp() }
        let (registry, panes, layout) = try makeSpawnRegistry()
        let harness = fixture.harness()
        let model = WindowModel(
            registry: registry, panes: panes, layout: layout, context: nil,
            harnessFactory: { _ in harness }, resumes: ResumeBroker(),
            rootPath: fixture.root.path, providerId: "spawn",
            lookup: SpawnCredentialsLookup(
                agentPath: fixture.agent.path, configDir: fixture.configDir.path))

        await model.send("propose a command that prints hello")
        if await fixture.spawnRecord(within: 10) == nil { failures.append(attempt) }
    }
    #expect(failures.isEmpty, """
        \(failures.count) of 20 turns spawned no agent (attempts \(failures)). \
        An intermittent spawn is #284; the rate is the thing to report on the issue.
        """)
}

private func makeSpawnRegistry() throws -> (ActionRegistry, PaneStore, LayoutStore) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-spawn-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (ActionRegistry(journalDirectory: dir, sessionId: "agent-spawn"), PaneStore(), LayoutStore())
}

/// **The status must be on screen before the turn's FIRST suspension.**
///
/// #284's nine recorded failures captured a tree twenty seconds after the
/// Send click carrying the typed prompt, the focused composer and the Send
/// button — and no status element at all. Every path below `enterConversation()`
/// writes `status`, so an empty one puts the stall above them, where the only
/// await is the layout scope swap: a disk write and a hop to the `LayoutStore`
/// actor. Until this test, the sentence was written after that await, so a
/// turn that stalled in it said nothing at all.
///
/// **How the ordering is observed.** `send` runs on the main actor, and so
/// does this test, so a `Task.yield()` hands it the actor and takes it back at
/// its first real suspension. A project is seeded because `activateLayout`
/// returns immediately without one — with an empty project there is no
/// suspension to be on the wrong side of, and the test would pass either way.
@Test @MainActor func theWindowSaysItIsStartingBeforeTheLayoutSwapCanStall() async throws {
    let fixture = try SpawnFixture()
    defer { fixture.cleanUp() }
    let (registry, panes, layout) = try makeSpawnRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in fixture.harness() }, resumes: ResumeBroker(),
        rootPath: fixture.root.path, providerId: "spawn",
        lookup: SpawnCredentialsLookup(
            agentPath: fixture.agent.path, configDir: fixture.configDir.path))
    model.seedForTesting(
        providerId: "spawn", rootPath: fixture.root.path, thoughts: 0,
        project: "e2e-project", environment: "staging")

    let turn = Task { @MainActor in await model.send("propose a command that prints hello") }
    await Task.yield()

    #expect(!model.status.isEmpty, """
        the turn suspended with nothing on screen to say it had begun. The first await in \
        `send` is `enterConversation()` — a scope swap that writes to disk and hops to the \
        LayoutStore actor — and a stall there is what #284's nine silent trees look like.
        """)
    _ = await turn.value
}

/// **The cross-language contract nothing tested: what the scripted agent
/// emits is what the thought thread renders.**
///
/// `e2e/stub/main.go` writes two frames and no others — `system/init`, then a
/// `result` carrying the answer. There is no `assistant` frame in between.
/// Every Swift test of the thread until now drove `StubHarness`, which hands
/// `HarnessEvent`s straight over and so never parses a byte; every Go test of
/// the stub checks what it wrote and never renders it. The two halves agreed
/// only by inspection.
///
/// #284, run 20260924-184944: the stub's own log reads `started`, `socket`,
/// `prompt`, `answered` — and the tree captured twenty seconds later does not
/// contain the reply. Nothing asserted it, because the only tree assertion in
/// that check file had been replaced by a bad `SESSION` guess, so the run
/// passed where it should have failed. This is that assertion, at a seam that
/// needs no window.
@Test @MainActor func theFramesTheScriptedAgentEmitsReachTheThoughtThread() async throws {
    let fixture = try SpawnFixture()
    defer { fixture.cleanUp() }
    // Exactly the two frames `e2e/stub/main.go` emits, in its order, one JSON
    // object per line and flushed per frame.
    try """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"S"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"your last command printed: one-two-three"}'
    sleep 5
    """.write(to: fixture.agent, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fixture.agent.path)

    let (registry, panes, layout) = try makeSpawnRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in fixture.harness() }, resumes: ResumeBroker(),
        rootPath: fixture.root.path, providerId: "spawn",
        lookup: SpawnCredentialsLookup(
            agentPath: fixture.agent.path, configDir: fixture.configDir.path))

    await model.send("what did my last command print?")

    let rendered = await waitForThought(model, containing: "your last command printed: one-two-three")
    #expect(rendered, """
        the agent's answer never reached the thought thread. The stub emits its reply as a \
        `result` frame and nothing else — no `assistant` frame — so a thread that renders only \
        assistant text shows an answered turn as an empty one. Thoughts were: \
        \(model.thoughts.map { "\($0.label)/\($0.detail)" })
        """)
}

@MainActor private func waitForThought(
    _ model: WindowModel, containing text: String, seconds: Double = 10
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if model.thoughts.contains(where: { $0.detail.contains(text) }) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return model.thoughts.contains(where: { $0.detail.contains(text) })
}
