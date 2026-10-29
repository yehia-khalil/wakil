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
        description: "Change one command's chord: id is the command; chord is its new chord (⌃⌘W), "
            + "\"\" for none, or null to restore its default. A command in the same place that held "
            + "the chord loses it, and the reply's tookFrom names it. Decision 50's chords are "
            + "refused. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "chord": .object(["type": .array([.string("string"), .string("null")])]),
            ]),
            "required": .array([.string("id"), .string("chord")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_key", role: "context")
            }
            guard case .object(let fields) = params, case .string(let id)? = fields["id"] else {
                throw StandardActionError.missingParam(action: "ctx_set_key", param: "id")
            }
            guard let chordParam = fields["chord"] else {
                throw StandardActionError.missingParam(action: "ctx_set_key", param: "chord")
            }
            guard let command = KeyCommand.byID[id] else {
                throw StandardActionError.serverError(action: "ctx_set_key", message: unknownCommand(id))
            }
            // Parsed before the read, so a malformed chord costs no round trip.
            var chord: KeyChord?
            switch chordParam {
            // Restoring is giving the command its default: a command holding it loses it.
            case .null: chord = command.defaultChord
            case .string(""): chord = nil
            case .string(let text): chord = try parsedChord(text, action: "ctx_set_key")
            default:
                throw StandardActionError.missingParam(action: "ctx_set_key", param: "chord")
            }
            let keymap = Keymap(overrides: try await readStoredKeys(context, action: "ctx_set_key"))
            let overrides: [String: String]
            let tookFrom: String?
            switch keymap.assign(id, chord) {
            case .success(let next): (overrides, tookFrom) = (next.overrides, next.tookFrom)
            case .failure(let refusal):
                throw StandardActionError.serverError(action: "ctx_set_key", message: refusal.message)
            }
            // The whole map in one write: a move is the chord given and the chord taken, together.
            _ = try await callCheckedTool(
                context, tool: "set_keys",
                arguments: .object(["keys": .object(overrides.mapValues { .string($0) })]),
                action: "ctx_set_key", timeout: MCPClient.readReplyTimeout)
            return .object(["tookFrom": tookFrom.map { .string($0) } ?? .null])
        }
    ))

    // Undo and Restore All: the map before a change, or an empty one, written back whole. Ids this
    // build doesn't know are kept from disk, so an older build can't wipe a newer one's binding.
    await registry.register(Action(
        name: "ctx_set_keys",
        description: "Replace the keymap's override map: keys maps a command id to its chord, "
            + "\"\" for none; an id left out keeps its default. Overrides for ids this build "
            + "doesn't know are kept. Decision 50's chords are refused. Operator-only.",
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
            guard case .object(let fields) = params, case .object(let given)? = fields["keys"] else {
                throw StandardActionError.missingParam(action: "ctx_set_keys", param: "keys")
            }
            var keys: [String: String] = [:]
            for id in given.keys.sorted() {
                guard case .string(let text)? = given[id] else {
                    throw StandardActionError.missingParam(action: "ctx_set_keys", param: "keys")
                }
                if KeyCommand.byID[id] != nil, !text.isEmpty,
                   try parsedChord(text, action: "ctx_set_keys").isRefused {
                    throw StandardActionError.serverError(action: "ctx_set_keys", message: KeyChord.refusedReason)
                }
                keys[id] = text
            }
            for (id, chord) in try await readStoredKeys(context, action: "ctx_set_keys")
            where KeyCommand.byID[id] == nil && keys[id] == nil {
                keys[id] = chord
            }
            return try await callCheckedTool(
                context, tool: "set_keys", arguments: .object(["keys": .object(keys.mapValues { .string($0) })]),
                action: "ctx_set_keys", timeout: MCPClient.readReplyTimeout)
        }
    ))
}

private func unknownCommand(_ id: String) -> String { "\(id) is not a command this build knows." }

/// A chord's text parsed, or the sentence `ctx_set_key` and `ctx_set_keys` refuse it with.
private func parsedChord(_ text: String, action: String) throws -> KeyChord {
    guard let chord = KeyChord(text) else {
        throw StandardActionError.serverError(action: action, message: "\(text) is not a shortcut.")
    }
    return chord
}

/// The stored overrides, for a write that sends the whole map back. A read that didn't decode, or
/// a settings.json Wakil couldn't read, refuses the write: that is the data-loss case.
private func readStoredKeys(_ context: any ToolCaller, action: String) async throws -> [String: String] {
    let read = try await callCheckedTool(
        context, tool: "keyboard", arguments: .object([:]), action: action, timeout: MCPClient.readReplyTimeout)
    guard let stored = decodeKeyboard(fromResult: read) else {
        throw StandardActionError.serverError(action: action, message: "keyboard answered no keys")
    }
    if let appError = stored.appError {
        throw StandardActionError.serverError(action: action, message: appError)
    }
    return stored.keys
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
