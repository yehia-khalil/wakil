import Testing
import Foundation
@testable import WakilKit

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)          // app/Tests/WakilKitTests/ContextStoreTests.swift
        .deletingLastPathComponent()          // WakilKitTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // app
        .deletingLastPathComponent()          // repo root
}

/// Writes a minimal `~/.wakil` fixture directly to a fresh scratch `HOME`
/// — one org directory, one project ("widgets") registered under it, and
/// that project's own `project.json` — without ever spawning the `wakil`
/// CLI or touching the real `~/.wakil`. This is enough for `wakil-ctx`:
/// `OrgDirFor` (verified by reading `internal/wakilcore/paths.go`) only
/// requires the org's directory to exist, not an `org.json` inside it, and
/// `Resolve`'s `providerReport` tolerates a missing `org.json` the same
/// way (`LoadOrgFor`'s error is ignored there).
///
/// `projectOrg` lets a test register the project under `org`'s registry
/// while the project.json itself declares a *different* org, to reach
/// `SetProjectChecked`'s cross-org refusal without needing two real orgs.
func makeFixture(org: String, projectOrg: String, environments: [String]) throws -> URL {
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let orgDir = home.appendingPathComponent(".wakil/orgs/\(org)")
    try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)

    let projectDir = home.appendingPathComponent("proj")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let projectPath = projectDir.appendingPathComponent("project.json")

    let envsJSON = environments.map { "\"\($0)\":{\"databases\":[]}" }.joined(separator: ",")
    let projectJSON = """
    {"name":"widgets","org":"\(projectOrg)","roots":[{"path":"/tmp/widgets"}],"scopes":{},"environments":{\(envsJSON)}}
    """
    try projectJSON.write(to: projectPath, atomically: true, encoding: .utf8)

    let registryJSON = "{\"widgets\":{\"path\":\"\(projectPath.path)\"}}"
    try registryJSON.write(to: orgDir.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)

    return home
}

/// A scratch `HOME` holding one org and **two** projects with different
/// environment sets, for testing what `set_project` does to the active
/// environment.
///
/// Distinct from `makeFixture` above rather than a parameter on it:
/// `makeFixture`'s single `widgets` project is depended on by name in
/// several tests, and widening it would churn all of them for one caller.
func makeTwoProjectFixture(
    org: String, projects: [(name: String, environments: [String])]
) throws -> URL {
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let orgDir = home.appendingPathComponent(".wakil/orgs/\(org)")
    try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)

    var registryEntries: [String] = []
    for project in projects {
        let projectDir = home.appendingPathComponent("proj-\(project.name)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let projectPath = projectDir.appendingPathComponent("project.json")
        let envsJSON = project.environments
            .map { "\"\($0)\":{\"databases\":[]}" }
            .joined(separator: ",")
        let projectJSON = """
        {"name":"\(project.name)","org":"\(org)","roots":[{"path":"/tmp/\(project.name)"}],\
        "scopes":{},"environments":{\(envsJSON)}}
        """
        try projectJSON.write(to: projectPath, atomically: true, encoding: .utf8)
        registryEntries.append("\"\(project.name)\":{\"path\":\"\(projectPath.path)\"}")
    }

    let registryJSON = "{\(registryEntries.joined(separator: ","))}"
    try registryJSON.write(
        to: orgDir.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
    return home
}

func startedClient(bin: URL, home: URL, org: String) async throws -> MCPClient {
    let client = MCPClient(executable: bin, arguments: [],
                           environment: ["HOME": home.path, "WAKIL_ORG": org, "PATH": "/usr/bin:/bin"])
    try await client.start()
    return client
}

/// `current()` is the whole of what `ContextStore` still does, and the only
/// part of it the app calls (`WindowModel.refreshContext`). The two changes
/// it reads back are made the way the window makes them — by dispatching
/// `ctx_set_project` and `ctx_set_environment` through the registry — so
/// this test exercises the reader against state the production path wrote,
/// rather than against state a method only this file called had written.
@Test func currentReflectsProjectAndEnvironmentAfterTheActionsSetThem() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "acme", projectOrg: "acme", environments: ["dev"])

    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let registry = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "ctx-store")
    await registerStandardActions(into: registry, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    let store = ContextStore(client: client)

    _ = try await registry.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("dev")]),
        origin: .ui, caller: .test("dev"), confirmation: nil)
    let ctx = try await store.current()

    await client.stop()

    // `makeFixture`'s project.json declares one root, "/tmp/widgets", already
    // absolute — so `ProjectRootPaths` (Go) resolves it to itself, and it
    // comes back on `RootPaths` unchanged.
    #expect(ctx == ContextStore.ActiveContext(
        org: "acme", project: "widgets", environment: "dev", rootPaths: ["/tmp/widgets"]))
}

/// `get_context`'s `structuredContent` reports `RootPaths` capitalized, like
/// every other top-level key on `wakilcore.Resolved` (`Org`, `Environment`;
/// see `current()`'s doc comment) — `Resolved.RootPaths` carries an explicit
/// `json:"RootPaths,omitempty"` tag precisely to match that convention
/// (`internal/wakilcore/resolve.go`). Swift must not re-derive root paths
/// itself: a root may be declared relative to the project directory, and
/// resolving that is `ProjectRootPaths`' job in Go.
@Test func activeContextCarriesTheResolvedRootPaths() throws {
    let structured = JSONValue.object([
        "Org": .string("acme"),
        "Project": .object(["name": .string("widgets")]),
        "Environment": .string("dev"),
        "RootPaths": .array([.string("/Users/x/widgets"), .string("/Users/x/widgets/src")]),
    ])
    let parsed = try ContextStore.parseActiveContext(structured)
    #expect(parsed.rootPaths == ["/Users/x/widgets", "/Users/x/widgets/src"])
}

/// An older `bin/wakil-ctx` built before `RootPaths` existed on the wire
/// reports `structuredContent` with no such key at all — `bin/` is
/// per-worktree and routinely stale relative to the Swift source tree. That
/// must parse to `[]`, not throw, so a fresh window still opens against a
/// stale binary rather than crashing on launch.
@Test func activeContextDefaultsRootPathsToEmptyWhenAbsent() throws {
    let structured = JSONValue.object([
        "Org": .string("acme"),
        "Project": .object(["name": .string("widgets")]),
        "Environment": .string("dev"),
    ])
    let parsed = try ContextStore.parseActiveContext(structured)
    #expect(parsed.rootPaths == [])
}

/// `WindowSession` (2b-vi Task 6) reads exactly this key to decide which
/// provider a window opens under — see `ActiveContext.activeProvider`'s
/// doc comment for why it is not the pre-existing `Provider` field.
@Test func activeContextCarriesTheActiveProvider() throws {
    let structured = JSONValue.object([
        "Org": .string("acme"),
        "Project": .object(["name": .string("widgets")]),
        "Environment": .string("dev"),
        "ActiveProvider": .string("work"),
    ])
    let parsed = try ContextStore.parseActiveContext(structured)
    #expect(parsed.activeProvider == "work")
}

/// Absent on an org that has never picked a provider (`omitempty` on the
/// wire) or on a stale `wakil-ctx` built before this key existed — either
/// way this must parse to `""`, "no provider chosen yet", not throw.
@Test func activeContextDefaultsActiveProviderToEmptyWhenAbsent() throws {
    let structured = JSONValue.object([
        "Org": .string("acme"),
        "Project": .object(["name": .string("widgets")]),
        "Environment": .string("dev"),
    ])
    let parsed = try ContextStore.parseActiveContext(structured)
    #expect(parsed.activeProvider == "")
}

/// What `ContextStore` puts on the wire was previously observable only
/// with a live `wakil-ctx` or a stub script. `current()` is the store's
/// one public call, and its private `callChecked` gives every call the
/// read budget — a fact nothing asserted until now.
@Test func theStoreCallsGetContextWithTheReadBudget() async throws {
    let client = RecordingToolCaller(always: .object([
        "content": .array([.object(["type": .string("text"), "text": .string("{}")])]),
        "structuredContent": .object([
            "Org": .string("initech"),
            "Environment": .string("staging"),
        ]),
    ]))
    let store = ContextStore(client: client)

    // Whether that result satisfies `parseActiveContext` is not this
    // test's subject — that mapping already has its own tests against a
    // literal `JSONValue`. What is new, and was untestable before the
    // port, is what reached the wire.
    _ = try? await store.current()

    let calls = await client.calls
    #expect(calls.count == 1)
    #expect(calls.first?.name == "get_context")
    #expect(calls.first?.arguments == .object([:]))
    #expect(calls.first?.timeout == MCPClient.readReplyTimeout)
}

/// `ProjectKey` is the registry key `WAKIL_PROJECT` pins by, reported beside
/// `Project.name` because the two are written independently and can differ.
@Test func activeContextCarriesTheProjectKeyBesideTheName() throws {
    let parsed = try ContextStore.parseActiveContext(.object([
        "Org": .string("acme"),
        "Project": .object(["name": .string("Widgets Display")]),
        "ProjectKey": .string("widgets"),
        "Environment": .string("dev"),
    ]))
    #expect(parsed.project == "Widgets Display")
    #expect(parsed.projectKey == "widgets")
}

/// A `wakil-ctx` built before `ProjectKey` existed reports none; the name is
/// what every build before it pinned by, so it stands in.
@Test func activeContextFallsBackToTheNameWhenTheProjectKeyIsAbsent() throws {
    let parsed = try ContextStore.parseActiveContext(.object([
        "Org": .string("acme"),
        "Project": .object(["name": .string("widgets")]),
        "Environment": .string("dev"),
    ]))
    #expect(parsed.projectKey == "widgets")
}

/// The project's Jira project (`scopes.pm.projectKey`) comes with `get_context`'s project: the
/// window scopes its Ticket tab by it. A project with no pm scope reads as "".
@Test func activeContextCarriesTheProjectsJiraProject() throws {
    let scoped = JSONValue.object([
        "Org": .string("acme"), "Environment": .string("dev"),
        "Project": .object(["name": .string("widgets"),
                            "scopes": .object(["pm": .object(["provider": .string("jira"), "projectKey": .string("INI")])])]),
    ])
    #expect(try ContextStore.parseActiveContext(scoped).pmProjectKey == "INI")
    let none = JSONValue.object([
        "Org": .string("acme"), "Environment": .string("dev"),
        "Project": .object(["name": .string("widgets"), "scopes": .object([:])]),
    ])
    #expect(try ContextStore.parseActiveContext(none).pmProjectKey == "")
}
