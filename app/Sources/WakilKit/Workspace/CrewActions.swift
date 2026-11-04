import Foundation

/// Workspaces piece 5: the window's side of the crew actions (`WindowModel+Crews.swift`), for the
/// actions registered before any window exists; pointed at the window by
/// `WakilWiring.useActiveContext(of:)`, as `TicketHandOffLookup` is. With no window, each refuses.
public final class CrewLookup: @unchecked Sendable {
    public struct Window: Sendable {
        /// `from` proposes a teammate for `repo` with `brief`: the proposal and whether it replaced one.
        public var propose: @Sendable (_ from: String?, _ repo: String, _ brief: String) async throws
            -> (TeammateProposal, Bool)
        /// The operator's Start: the new conversation's id.
        public var start: @Sendable (_ proposal: String, _ brief: String?) async throws -> String
        /// The operator's Dismiss: the proposal dismissed.
        public var dismiss: @Sendable (_ proposal: String) async throws -> TeammateProposal
        /// The operator's edit of a proposal's brief (the strip's field, on blur).
        public var edit: @Sendable (_ proposal: String, _ brief: String) async throws -> TeammateProposal
        /// `conversation` says it has nothing to do: its state's words.
        public var nothingToDo: @Sendable (_ conversation: String?, _ why: String?) async throws -> String

        public init(
            propose: @escaping @Sendable (String?, String, String) async throws -> (TeammateProposal, Bool),
            start: @escaping @Sendable (String, String?) async throws -> String,
            dismiss: @escaping @Sendable (String) async throws -> TeammateProposal,
            edit: @escaping @Sendable (String, String) async throws -> TeammateProposal,
            nothingToDo: @escaping @Sendable (String?, String?) async throws -> String
        ) {
            self.propose = propose
            self.start = start
            self.dismiss = dismiss
            self.edit = edit
            self.nothingToDo = nothingToDo
        }
    }

    private let lock = NSLock()
    private var window: Window?

    public init() {}

    public func use(_ window: Window) {
        lock.lock()
        self.window = window
        lock.unlock()
    }

    func current(_ action: String) throws -> Window {
        lock.lock()
        defer { lock.unlock() }
        guard let window else { throw TeammateProposalRefusal(description: "\(action): no window to act in") }
        return window
    }
}

/// Workspaces piece 5 (decision 17): an agent proposes a teammate; the operator starts it or
/// dismisses it. No confirmation: proposing changes Wakil's own state only (`.control`), and Start
/// and Dismiss are the operator's own click (Rule 1).
public func registerCrewActions(into registry: ActionRegistry, crew: CrewLookup) async {
    @Sendable func string(_ params: JSONValue, _ key: String) -> String? {
        if case .object(let o) = params, case .string(let s)? = o[key] { return s }
        return nil
    }
    @Sendable func required(_ params: JSONValue, _ key: String, _ action: String) throws -> String {
        guard let v = string(params, key), !v.isEmpty else { throw StandardActionError.missingParam(action: action, param: key) }
        return v
    }
    @Sendable func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map { .string($0) })])
    }
    let text: JSONValue = .object(["type": .string("string")])

    await registry.register(Action(
        name: "conversation_propose_teammate",
        description: "Propose a teammate: a new conversation for repo (a repo of your project, by folder name or "
            + "path) in your workspace, starting from brief (what it should do there; at most 4,000 characters). "
            + "The operator starts it with one click, brief editable, or dismisses it; you never start one. A second "
            + "proposal for the same repo replaces the first; a dismissed one is not repeated in this workspace. "
            + "Once started, it is in session_list beside you and you talk through conversation_message.",
        kind: .control, audience: .agentReachable,
        schema: schema(["repo": text, "brief": text], required: ["repo", "brief"]),
        handler: { params in
            let action = "conversation_propose_teammate"
            let repo = try required(params, "repo", action)
            guard let brief = string(params, "brief") else {
                throw StandardActionError.missingParam(action: action, param: "brief")
            }
            let (p, replaced) = try await crew.current(action).propose(
                ActionRegistry.dispatchCaller?.conversation, repo, brief)
            guard case .object(var o) = p.json else { return p.json }
            o["replaced"] = .bool(replaced)
            o["said"] = .string("Proposed: the operator starts it or dismisses it.")
            return .object(o)
        }))

    await registry.register(Action(
        name: "conversation_teammate_start",
        description: "Start a proposed teammate: a new conversation in the proposer's workspace, place and provider, "
            + "for the proposal's repo, with brief (the proposal's when omitted) and who holds what. A handed proposer's "
            + "teammate is handed on its ticket with May push off. The screen stays where it is. The operator's only.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["proposal": text, "brief": text], required: ["proposal"]),
        handler: { params in
            let action = "conversation_teammate_start"
            let id = try required(params, "proposal", action)
            let conversation = try await crew.current(action).start(id, string(params, "brief"))
            return .object(["proposal": .string(id), "conversation": .string(conversation)])
        }))

    await registry.register(Action(
        name: "conversation_teammate_dismiss",
        description: "Dismiss a proposed teammate: it goes, and no teammate for that repo is proposed again in that "
            + "workspace (decision 17). The operator's only.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["proposal": text], required: ["proposal"]),
        handler: { params in
            let action = "conversation_teammate_dismiss"
            let p = try await crew.current(action).dismiss(try required(params, "proposal", action))
            return .object(["proposal": .string(p.id), "dismissed": .bool(true), "repo": .string(p.repo)])
        }))

    await registry.register(Action(
        name: "conversation_teammate_brief",
        description: "Keep the operator's edit of a proposed teammate's brief (its field, on blur). The operator's only.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["proposal": text, "brief": text], required: ["proposal", "brief"]),
        handler: { params in
            let action = "conversation_teammate_brief"
            let id = try required(params, "proposal", action)
            guard let brief = string(params, "brief") else { throw StandardActionError.missingParam(action: action, param: "brief") }
            return try await crew.current(action).edit(id, brief).json
        }))

    await registry.register(Action(
        name: "conversation_nothing_to_do",
        description: "Say your repo needs nothing from you: your conversation reads \"done · nothing to do in <repo>\" "
            + "until the operator's next message, and the operator closes it. why: one line, optional. Then stop.",
        kind: .control, audience: .agentReachable,
        schema: schema(["why": text]),
        handler: { params in
            let action = "conversation_nothing_to_do"
            let words = try await crew.current(action).nothingToDo(
                ActionRegistry.dispatchCaller?.conversation, string(params, "why"))
            return .object(["state": .string(words)])
        }))
}
