import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import WakilKit

/// A registry with one operator-only action (by audience), one on the `operatorOnlyActions` list
/// with no audience said, and one the agent may run.
private func harnessSurface() async -> MCPSurface {
    let registry = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registry.register(Action(name: "ctx_update_org", description: "t", kind: .control,
                                   audience: .operatorOnly, schema: .object([:])) { _ in .string("ran") })
    await registry.register(Action(name: "ctx_list_orgs", description: "t", kind: .read,
                                   schema: .object([:])) { _ in .string("listed") })
    await registry.register(Action(name: "pane_open", description: "t", kind: .control,
                                   audience: .agentReachable, schema: .object([:])) { _ in .string("opened") })
    return MCPSurface(registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: ConfirmationBroker())
}

private let agentCaller: @Sendable () async -> DispatchCaller = {
    DispatchCaller(place: Place(organization: "initech", project: "api", environment: "staging"),
                   session: "agent-session", conversation: "conv-a")
}

private func call(_ name: String) -> JSONRPCMessage {
    JSONRPCMessage(id: .number(1), method: "tools/call",
                   params: .object(["name": .string(name), "arguments": .object([:])]), result: nil, error: nil)
}

private func toolNames(_ reply: JSONRPCMessage?) -> [String] {
    guard case .object(let r)? = reply?.result, case .array(let tools)? = r["tools"] else { return [] }
    return tools.compactMap { t -> String? in
        if case .object(let o) = t, case .string(let n)? = o["name"] { return n }; return nil
    }.sorted()
}

/// The path literal the Go side pins too (`TestOperatorSocketForMirrorsTheApp`).
@Test func theHarnessSocketSitsBesideTheAgentSocketAndIsShorter() {
    let agent = "/var/folders/ab/T/wakil-6F1C2D3E-0000-4000-8000-000000000001.sock"
    let harness = harnessSocketPath(forAgentSocket: agent)
    #expect(harness == "/var/folders/ab/T/6F1C2D3E-0000-4000-8000-000000000001-e2e.sock")
    #expect(harness.utf8.count < agent.utf8.count, "binds wherever the agent socket does (sun_path)")
    #expect(!URL(fileURLWithPath: harness).lastPathComponent.hasPrefix("wakil-"),
            "never a candidate for the harness's agent channel")
}

/// **The gate.** Only the staged e2e fixture opens the harness channel.
@Test(arguments: [nil, "dev.wakil.app", "dev.wakil", "dev.wakil.e2e.other", ""] as [String?])
func aBundleThatIsNotTheE2EFixtureOpensNothing(bundleIdentifier: String?) async throws {
    let agent = "/tmp/wakil-h\(UUID().uuidString.prefix(8)).sock"
    let path = harnessSocketPath(forAgentSocket: agent)
    #expect(!opensHarnessChannel(bundleIdentifier: bundleIdentifier))
    let server = try await startHarnessSocket(
        bundleIdentifier: bundleIdentifier, agentSocket: agent,
        surface: await harnessSurface(), caller: agentCaller)
    #expect(server == nil)
    #expect(!FileManager.default.fileExists(atPath: path), "nothing bound at \(path)")
}

@Test func theE2EFixtureOpensAnOwnerOnlyHarnessSocket() async throws {
    let agent = "/tmp/wakil-h\(UUID().uuidString.prefix(8)).sock"
    let path = harnessSocketPath(forAgentSocket: agent)
    #expect(opensHarnessChannel(bundleIdentifier: "dev.wakil.e2e"))
    let server = try await startHarnessSocket(
        bundleIdentifier: "dev.wakil.e2e", agentSocket: agent,
        surface: await harnessSurface(), caller: agentCaller)
    #expect(server != nil)
    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & S_IFMT == S_IFSOCK)
    #expect(info.st_mode & 0o777 == 0o600)
    await server?.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}

/// The harness channel advertises exactly the operator-only actions: what the runner routes by.
@Test func theHarnessChannelListsOnlyTheOperatorOnlyActions() async throws {
    let surface = await harnessSurface()
    let list = JSONRPCMessage(id: .number(1), method: "tools/list", params: nil, result: nil, error: nil)
    let harness = await handle(list, surface: surface, caller: agentCaller, channel: .harness)
    #expect(toolNames(harness) == ["ctx_list_orgs", "ctx_update_org"])
    let agent = await handle(list, surface: surface, caller: agentCaller)
    #expect(toolNames(agent).contains("pane_open"), "the agent socket's list is unchanged")
}

/// An operator-only action runs on the harness channel, journalled with origin `.debug` and no
/// agent session; on the agent socket it is still refused.
@Test func anOperatorOnlyActionRunsOnTheHarnessChannelAsDebugAndStaysRefusedToTheAgent() async throws {
    let surface = await harnessSurface()
    let harnessCaller: @Sendable () async -> DispatchCaller = {
        let pinned = await agentCaller()
        return DispatchCaller(place: pinned.place, session: nil, conversation: pinned.conversation)
    }
    let ran = await handle(call("ctx_update_org"), surface: surface, caller: harnessCaller, channel: .harness)
    #expect(ran?.error == nil)

    let refused = await handle(call("ctx_update_org"), surface: surface, caller: agentCaller)
    #expect(refused?.error?.code == -32007)

    let entries = try await surface.registry.journalEntries()
    #expect(entries.map(\.outcome) == ["ok", "refused"])
    #expect(entries.map(\.origin) == [.debug, .agent])
    #expect(entries.first?.session == nil, "not an agent session's call")
}

/// Anything not operator-only is refused on the harness channel before it runs, so the channel
/// cannot stand in for the agent socket: an agent-reachable action, a hand-written tool, an unknown name.
@Test(arguments: ["pane_open", "read_pane", "approve_tool_use", "no_such_action"])
func theHarnessChannelRefusesWhatIsNotOperatorOnly(name: String) async throws {
    let surface = await harnessSurface()
    let reply = await handle(call(name), surface: surface, caller: agentCaller, channel: .harness)
    #expect(reply?.error?.code == -32008)
    #expect(reply?.error?.message.contains("agent socket") == true)
    #expect(try await surface.registry.journalEntries().isEmpty, "nothing dispatched")
}

/// The agent's MCP config never names the harness socket.
@Test func theAgentsConfigNeverNamesTheHarnessSocket() {
    let agent = "/tmp/wakil-AAAA.sock"
    let config = agentMCPConfigJSON(
        shimExecutable: URL(fileURLWithPath: "/Applications/Wakil.app/Contents/MacOS/Wakil"),
        socketPath: agent, binaries: [:], place: nil, provider: nil,
        approvalSocket: approvalSocketPath(forAgentSocket: agent))
    #expect(!config.contains("-e2e.sock"))
    #expect(!config.contains(harnessSocketPath(forAgentSocket: agent)))

    // Nor does the environment the agent itself is started with (review M4).
    let launch = buildLaunch(claudePath: "/c", sessionId: "s", configDir: "/d", oauthToken: "t",
                             mcpConfigJSON: config, allowedTools: [], workingDirectory: "/w")
    for (key, value) in launch.environment {
        #expect(!value.contains("-e2e.sock"), "\(key) names the harness socket")
    }
    #expect(!launch.arguments.contains { $0.contains("-e2e.sock") })
}

/// **A harness socket that would not start is said, not swallowed** (review M3): the window gets
/// the sentence its status shows, as for the approval socket, and no server.
@Test func aHarnessSocketThatWouldNotStartAnswersWhy() async {
    // A directory that does not exist: `bind` fails.
    let agent = "/nonexistent-\(UUID().uuidString.prefix(8))/wakil-h.sock"
    let opened = await openHarnessSocket(
        bundleIdentifier: "dev.wakil.e2e", agentSocket: agent,
        surface: await harnessSurface(), caller: agentCaller)
    #expect(opened.server == nil)
    let failure = try? #require(opened.failure)
    #expect(failure?.contains(harnessSocketPath(forAgentSocket: agent)) == true, "names the path")
    #expect(failure?.contains("operator-only") == true, "says what it costs")
}

/// Outside the fixture nothing is opened and nothing failed: no sentence for a channel this build
/// never opens.
@Test func aBundleThatIsNotTheFixtureOpensNoHarnessSocketAndReportsNoFailure() async {
    let opened = await openHarnessSocket(
        bundleIdentifier: "dev.wakil.app", agentSocket: "/nonexistent/wakil-h.sock",
        surface: await harnessSurface(), caller: agentCaller)
    #expect(opened.server == nil)
    #expect(opened.failure == nil)
}

/// The agent socket's `initialize` carries the harness socket's start failure, so the e2e harness
/// can tell "this build opens none" (no key) from "it failed to start" (the sentence).
@Test func initializeCarriesTheHarnessSocketsStartFailureOnlyWhenThereIsOne() async throws {
    let m = JSONRPCMessage(id: .number(1), method: "initialize", params: .object([:]), result: nil, error: nil)
    func meta(_ failure: String?) async -> [String: JSONValue] {
        let out = await handle(m, surface: await harnessSurface(), caller: agentCaller, harnessFailure: failure)
        guard case .object(let r)? = out?.result, case .object(let meta)? = r["_meta"] else { return [:] }
        return meta
    }
    #expect(await meta("harness socket /x-e2e.sock: bind failed")["wakil/harnessFailure"]
            == .string("harness socket /x-e2e.sock: bind failed"))
    #expect(await meta(nil)["wakil/harnessFailure"] == nil, "absent, never null, when nothing failed")
}
