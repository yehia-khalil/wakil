import Foundation

/// The keymap's three actions. The read is the agent's too; both writes are operator-only, as the
/// editor's and the browser's settings writes are (Decisions 30 and 38): the agent can read the
/// keymap but can't rebind keys. `wakil-ctx` stores the overrides and checks their shape; the
/// move and Decision 50 are `Keymap.assign`'s, so they hold however `ctx_set_key` is reached.
public func registerKeyboardActions(into registry: ActionRegistry, context: (any ToolCaller)?) async {
    await registry.register(Action(
        name: "ctx_keyboard",
        description: "Read the keymap's overrides from settings.json: keys maps a command id "
            + "(pane.close, browser.reload, …) to its chord (⌃⌘W); an empty chord is a command with "
            + "none, and an id absent keeps its default. appError carries settings.json's error, "
            + "whole, when it cannot be read; the defaults are then in force.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_keyboard", role: "context")
            }
            return try await callCheckedTool(
                context, tool: "keyboard", arguments: .object([:]),
                action: "ctx_keyboard", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_set_key",
        description: "Give one command a chord: id is the command, chord its new chord (⌃⌘W) or "
            + "null for none. A command in the same place that held the chord loses it, and the "
            + "reply's tookFrom names it. Decision 50's chords are refused. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "chord": .object(["type": .array([.string("string"), .string("null")])]),
            ]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_key", role: "context")
            }
            guard case .object(let fields) = params, case .string(let id)? = fields["id"] else {
                throw StandardActionError.missingParam(action: "ctx_set_key", param: "id")
            }
            var chord: KeyChord?
            if case .string(let text)? = fields["chord"] {
                guard let parsed = KeyChord(text) else {
                    throw StandardActionError.serverError(
                        action: "ctx_set_key", message: "\(text) is not a shortcut.")
                }
                chord = parsed
            }
            let read = try await callCheckedTool(
                context, tool: "keyboard", arguments: .object([:]),
                action: "ctx_set_key", timeout: MCPClient.readReplyTimeout)
            // The whole map is written back, so a read that did not decode writes nothing.
            guard let stored = decodeKeyboard(fromResult: read) else {
                throw StandardActionError.serverError(action: "ctx_set_key", message: "keyboard answered no keys")
            }
            // A file Wakil could not read is not written over: that is the data-loss case.
            if let appError = stored.appError {
                throw StandardActionError.serverError(action: "ctx_set_key", message: appError)
            }
            let assignment: Keymap.Assignment
            switch Keymap(overrides: stored.keys).assign(id, chord) {
            case .success(let next): assignment = next
            case .failure(let refusal):
                throw StandardActionError.serverError(action: "ctx_set_key", message: refusal.message)
            }
            // The whole map in one write: a move is the chord given and the chord taken, together.
            _ = try await callCheckedTool(
                context, tool: "set_keys",
                arguments: .object(["keys": .object(assignment.overrides.mapValues { .string($0) })]),
                action: "ctx_set_key", timeout: MCPClient.readReplyTimeout)
            return .object(["tookFrom": assignment.tookFrom.map { .string($0) } ?? .null])
        }
    ))

    // Undo and Restore All: the map before a change, or an empty one, written back whole.
    await registry.register(Action(
        name: "ctx_set_keys",
        description: "Replace the keymap's whole override map: keys maps a command id to its "
            + "chord, an empty chord for none; an id left out keeps its default. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "keys": .object([
                    "type": .string("object"),
                    "additionalProperties": .object(["type": .string("string")]),
                ]),
            ]),
            "required": .array([.string("keys")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_keys", role: "context")
            }
            guard case .object(let fields) = params, case .object(let keys)? = fields["keys"],
                  keys.values.allSatisfy({ if case .string = $0 { return true } else { return false } })
            else {
                throw StandardActionError.missingParam(action: "ctx_set_keys", param: "keys")
            }
            return try await callCheckedTool(
                context, tool: "set_keys", arguments: .object(["keys": .object(keys)]),
                action: "ctx_set_keys", timeout: MCPClient.readReplyTimeout)
        }
    ))
}

/// `keyboard`'s answer: the stored overrides, and settings.json's error (nil when it read).
public struct StoredKeys: Equatable, Sendable {
    public var keys: [String: String]
    public var appError: String?
}

/// Decodes `ctx_keyboard`'s result; nil when it is not the tool's shape.
public func decodeKeyboard(fromResult result: JSONValue?) -> StoredKeys? {
    guard case .object(let object)? = result, case .object(let content)? = object["structuredContent"],
          case .object(let keys)? = content["keys"] else { return nil }
    var stored: [String: String] = [:]
    for (id, value) in keys {
        guard case .string(let chord) = value else { return nil }
        stored[id] = chord
    }
    var appError: String?
    if case .string(let text)? = content["appError"], !text.isEmpty { appError = text }
    return StoredKeys(keys: stored, appError: appError)
}
