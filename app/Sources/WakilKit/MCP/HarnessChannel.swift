import Foundation

/// Which channel an `MCPSocketServer` is.
///
/// - `agent`: the agent socket. `tools/call` dispatches with origin `.agent`, so the registry
///   refuses every operator-only action on it (`ActionError.operatorOnly`), whoever dialled it.
/// - `harness`: the e2e harness's operator channel, opened only by the staged e2e fixture
///   (`startHarnessSocket`). It serves only the operator-only actions and dispatches them with
///   origin `.debug` — a script driving the app, as `--dispatch` is: not the operator's hand
///   (`.ui`) and not an agent (`.agent`), so the journal says truthfully who asked. The harness
///   needs it because its `dispatch` and `parity` steps drive operator-only actions, which the agent
///   socket refuses.
public enum MCPChannel: Sendable, Equatable {
    case agent
    case harness
}

/// The bundle identifier the e2e harness stages its fixture under (`E2EBundleIdentifier`,
/// `e2e/driver/stage.go`). Only an app running under it opens the harness channel.
public let e2eFixtureBundleIdentifier = "dev.wakil.e2e"

/// Whether this app opens the harness channel: only when it is the staged e2e fixture. A
/// production Wakil (`dev.wakil.app`), a dev build with no bundle, anything else: never.
public func opensHarnessChannel(bundleIdentifier: String?) -> Bool {
    bundleIdentifier == e2eFixtureBundleIdentifier
}

/// The harness socket beside an agent socket: `<directory>/<session id>-e2e.sock`, for the agent
/// socket `<directory>/wakil-<session id>.sock`.
///
/// Shaped like `approvalSocketPath(forAgentSocket:)`, for the same `sun_path` reason: the `wakil-`
/// prefix and the agent socket's `.sock` are dropped, so it is 2 bytes SHORTER than the agent
/// socket's path and binds wherever that one does. Not a `wakil-*.sock`, so the harness never
/// mistakes it for an agent socket. It is never named in an agent's `--mcp-config` or environment.
public func harnessSocketPath(forAgentSocket path: String) -> String {
    let url = URL(fileURLWithPath: path)
    var name = url.deletingPathExtension().lastPathComponent
    if name.hasPrefix("wakil-") { name.removeFirst("wakil-".count) }
    return url.deletingLastPathComponent().appendingPathComponent("\(name)-e2e.sock").path
}

/// Whether the descriptor is an action only the operator may run: registered `.operatorOnly`, or
/// named in `operatorOnlyActions` — the registry's own test (`ActionRegistry.dispatch`).
func isOperatorOnly(_ descriptor: ActionDescriptor) -> Bool {
    descriptor.audience == .operatorOnly || operatorOnlyActions.contains(descriptor.name)
}

/// Starts the harness socket beside the agent socket at `agentSocket` when `bundleIdentifier` is the e2e
/// fixture's (`opensHarnessChannel`), and returns it; **nil, with nothing opened and nothing
/// bound, for any other bundle**. The socket answers for the agent socket's place and
/// conversation, but as the operator does: no agent session (`session` nil), so the dispatch is
/// judged with the window's own clients, as a control's is.
public func startHarnessSocket(
    bundleIdentifier: String?,
    agentSocket: String,
    surface: MCPSurface,
    caller: @escaping @Sendable () async -> DispatchCaller,
    screen: (@Sendable () async -> ScreenShown?)? = nil
) async throws -> MCPSocketServer? {
    guard opensHarnessChannel(bundleIdentifier: bundleIdentifier) else { return nil }
    let server = MCPSocketServer(
        surface: surface, socketPath: harnessSocketPath(forAgentSocket: agentSocket),
        caller: {
            let pinned = await caller()
            return DispatchCaller(place: pinned.place, session: nil, conversation: pinned.conversation)
        },
        screen: screen, channel: .harness)
    try await server.start()
    return server
}

/// JSON-RPC error code for a call the harness channel does not serve: an action that is not
/// operator-only goes over the agent socket.
let harnessNotServedCode = -32008

/// `tools/call` on the harness channel. Only an operator-only action runs, with origin `.debug`;
/// anything else — an agent-reachable action, a hand-written tool, a name the registry does not
/// know — is refused before anything runs. **Nothing parks**: a gated action is answered with its
/// refusal, since no operator is asked on this channel.
func handleHarnessToolsCall(
    id: JSONRPCID,
    params: JSONValue?,
    surface: MCPSurface,
    caller: @Sendable () async -> DispatchCaller
) async -> JSONRPCMessage {
    guard case .object(let obj)? = params, case .string(let name)? = obj["name"] else {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32602, message: "Invalid params: \"tools/call\" requires a string \"name\""))
    }
    let arguments = obj["arguments"] ?? .object([:])
    guard let descriptor = await surface.registry.descriptor(named: name), isOperatorOnly(descriptor) else {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: harnessNotServedCode,
            message: "\(name): the harness channel runs only operator-only actions; send it on the agent socket"))
    }
    do {
        let result = try await surface.registry.dispatch(
            name: name, params: arguments, origin: .debug, caller: await caller(), confirmation: nil)
        return JSONRPCMessage(id: id, result: toolResultEnvelope(result))
    } catch let error as ActionError {
        return JSONRPCMessage(id: id, error: jsonRPCError(for: error))
    } catch {
        return JSONRPCMessage(id: id, error: JSONRPCError(code: -32603, message: "\(error)"))
    }
}
