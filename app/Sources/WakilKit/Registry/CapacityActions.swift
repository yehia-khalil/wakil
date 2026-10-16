import Foundation

/// Provider capacity's two actions. Recording is operator-only — the agent
/// must not be able to forge a reading the operator chooses accounts by —
/// and goes through the registry rather than straight to `wakil-ctx`
/// because actions are the only mutation path (Invariant 2), as
/// `session_record_parent` already does. Reading is agent-reachable: "which
/// account has room?" is a fair question for the agent to answer.
public func registerCapacityActions(into registry: ActionRegistry, context: (any ToolCaller)?) async {
    await registry.register(Action(
        name: "capacity_record",
        description: "Record how much of a claude-code account's 5-hour and weekly windows is left, "
            + "as read from the agent's own stream.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "provider": .object(["type": .string("string")]),
                "fiveHour": .object(["type": .string("object")]),
                "sevenDay": .object(["type": .string("object")]),
                "asOf": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("provider"), .string("fiveHour"), .string("asOf")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "capacity_record", role: "context")
            }
            return try await callCheckedTool(context, tool: "record_capacity", arguments: params,
                                         action: "capacity_record", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_capacity",
        description: "How much of each provider account's 5-hour and weekly (or monthly) rate-limit window is left "
            + "in the active organisation, with reset times and when each was read."
            + " With refresh (operator only), stale Claude accounts are probed first.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([
            "refresh": .object(["type": .string("boolean")]),
        ])]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_capacity", role: "context")
            }
            // The agent cannot spend the operator's limit: refresh is a
            // 1-token request per account, honoured only for the operator.
            var arguments: [String: JSONValue] = [:]
            if ActionRegistry.dispatchOrigin != .agent,
               case .object(let fields) = params, fields["refresh"] == .bool(true) {
                arguments["refresh"] = .bool(true)
            }
            return try await callCheckedTool(context, tool: "capacity", arguments: .object(arguments),
                                         action: "ctx_capacity", timeout: MCPClient.readReplyTimeout)
        }
    ))
}
