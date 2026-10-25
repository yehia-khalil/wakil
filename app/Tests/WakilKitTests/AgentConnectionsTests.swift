import Foundation
import Testing
@testable import WakilKit

private let shim = URL(fileURLWithPath: "/Apps/Wakil.app/Contents/MacOS/Wakil")
private let connect = URL(fileURLWithPath: "/Apps/Wakil.app/Contents/Resources/wakil-connect")

private func answerBinaries(withConnect: Bool = true) -> [String: URL] {
    var binaries = Dictionary(uniqueKeysWithValues: agentFacingServers.map { ($0, URL(fileURLWithPath: "/bin/\($0)")) })
    if withConnect { binaries[wakilConnectBinaryName] = connect }
    return binaries
}

private func servers(
    _ place: Place, binaries: [String: URL] = answerBinaries(), connections: [AgentConnection] = [],
    approval: String? = nil
) throws -> [String: JSONValue] {
    let json = agentMCPConfigJSON(
        shimExecutable: shim, socketPath: "/tmp/wakil-1.sock", binaries: binaries, place: place,
        provider: "primary", connections: connections, approvalSocket: approval)
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    guard case .object(let root) = value, case .object(let servers)? = root["mcpServers"] else {
        Issue.record("not an mcpServers object: \(json)")
        return [:]
    }
    return servers
}

private func env(_ servers: [String: JSONValue], _ name: String) -> [String: JSONValue] {
    guard case .object(let entry)? = servers[name], case .object(let env)? = entry["env"] else {
        Issue.record("no env for \(name)")
        return [:]
    }
    return env
}

private let initech = Place(organization: "initech", project: "api", environment: "staging")

@Test func noConnectionsLeavesConfigUnchanged() throws {
    // Decoded, not compared as text: the encoder does not order a dictionary's keys.
    let plain = try servers(initech)
    let withDefaults = try servers(initech, connections: [], approval: "/tmp/1-approval.sock")
    #expect(plain == withDefaults)
    #expect(plain.count == agentFacingServers.count + 1)
}

@Test func eachConnectionIsAServerOfWakilConnect() throws {
    let all = try servers(initech, connections: [AgentConnection(name: "tracker"), AgentConnection(name: "wiki")])
    for name in ["tracker", "wiki"] {
        guard case .object(let entry)? = all[name] else {
            Issue.record("no server \(name)")
            continue
        }
        #expect(entry["command"] == .string(connect.path))
        #expect(entry["args"] == .array([.string("--connection"), .string(name)]))
    }
    #expect(all.count == agentFacingServers.count + 1 + 2)
}

@Test func approvalSocketOnlyOnConnections() throws {
    let all = try servers(initech, connections: [AgentConnection(name: "tracker")], approval: "/tmp/1-approval.sock")
    #expect(env(all, "tracker")["WAKIL_APPROVAL_SOCKET"] == .string("/tmp/1-approval.sock"))
    // The connection has the place env exactly as the others do.
    for key in ["WAKIL_ORG", "WAKIL_PROJECT", "WAKIL_ENVIRONMENT", "WAKIL_PROVIDER"] {
        #expect(env(all, "tracker")[key] == env(all, "wakil-pm")[key], "\(key)")
    }
    for name in all.keys where name != "tracker" {
        #expect(env(all, name)["WAKIL_APPROVAL_SOCKET"] == nil, "\(name)")
    }
    #expect(env(all, "wakil")["WAKIL_APPROVAL_SOCKET"] == nil)
    #expect(env(all, "wakil-pm")["WAKIL_APPROVAL_SOCKET"] == nil)
}

@Test func connectionsAreAllowedServerWide() {
    let allowed = agentAllowedTools(actions: [], connections: [AgentConnection(name: "tracker")])
    #expect(allowed.contains("mcp__tracker"))
    #expect(allowed == agentAllowedTools(actions: []) + ["mcp__tracker"])
}

@Test func connectionsFollowThePlace() throws {
    let umbrella = Place(organization: "umbrella", project: "", environment: "")
    let a = try servers(initech, connections: [AgentConnection(name: "tracker")])
    let b = try servers(umbrella, connections: [AgentConnection(name: "wiki")])
    #expect(a["tracker"] != nil && a["wiki"] == nil)
    #expect(b["wiki"] != nil && b["tracker"] == nil)
    #expect(env(a, "tracker")["WAKIL_ORG"] == .string("initech"))
    #expect(env(b, "wiki")["WAKIL_ORG"] == .string("umbrella"))
    #expect(env(b, "wiki")["WAKIL_PROJECT"] == nil)
}

@Test func missingWakilConnectBinaryDropsConnections() throws {
    let all = try servers(
        initech, binaries: answerBinaries(withConnect: false), connections: [AgentConnection(name: "tracker")],
        approval: "/tmp/1-approval.sock")
    #expect(all["tracker"] == nil)
    #expect(Set(all.keys) == Set(["wakil"] + agentFacingServers))
}

@Test func aConnectionNeverReplacesAWakilServer() throws {
    let names = ["wakil", "wakil-pm", "wakil-git"]
    let all = try servers(initech, connections: names.map(AgentConnection.init(name:)), approval: "/tmp/1-approval.sock")
    let plain = try servers(initech)
    #expect(all["wakil"] == plain["wakil"])
    #expect(all["wakil-pm"] == plain["wakil-pm"])
    #expect(all["wakil-git"] == plain["wakil-git"])
    #expect(env(all, "wakil-pm")["WAKIL_APPROVAL_SOCKET"] == nil)
    let allowed = agentAllowedTools(actions: [], connections: names.map(AgentConnection.init(name:)))
    #expect(allowed == agentAllowedTools(actions: []))
}

// MARK: - The first launch in an organisation

@Suite @MainActor struct AgentConnectionsLaunchTests {
    private actor Reads {
        var count = 0
        func add() { count += 1 }
    }

    @Test func aLaunchReadsTheOrganisationsConnectionsOnceWhenNothingHas() async throws {
        let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in RecordingHarness() })
        let box = AgentConnectionsBox()
        model.agentConnectionsBox = box
        let org = model.place.organization
        let reads = Reads()
        await model.registryForTesting.register(Action(
            name: "ctx_config_tree", description: "", kind: .read, schema: .object([:]),
            handler: { _ in
                await reads.add()
                return .object(["structuredContent": .object([
                    "org": .object(["id": .string(org), "connections": .array([.object(["name": .string("tracker")])])]),
                    "providers": .array([]), "projects": .array([]),
                ])])
            }))
        #expect(!box.isKnown(org: org))
        await model.send("hi")
        #expect(box.connections(org: org) == [AgentConnection(name: "tracker")])
        await model.send("again")
        #expect(await reads.count == 1)
    }
}
