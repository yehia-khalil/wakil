import Foundation

/// The marked block a live agent's next turn opens with when its instructions changed (spec
/// amendment 2026-10-22: a resumed session ignores a new appended prompt).
public let agentInstructionsUpdateHeader =
    "[Wakil: the operator updated your instructions. They replace any earlier ones under the same headings.]"

/// What a resumed session was launched with is not known here; its first turn sends the current text.
let resumedInstructionsUnknown = "\u{0}resumed"

/// 3a-iii-b: the operator's agent instructions (Decision 45). Every Settings read publishes the
/// composed text per project to `AgentInstructionsBox`, which an agent's launch reads.
extension WindowModel {
    func publishAgentInstructions(_ tree: SettingsTree) {
        let org = tree.org
        let orgTexts = AgentTexts(general: org.agentGeneral, commits: org.gitCommitInstructions, pullRequests: org.gitPRInstructions)
        agentInstructionsBox.set(org: org.id, project: nil,
                                 text: agentInstructions(org: org.id, orgTexts: orgTexts, project: nil, projectTexts: nil))
        for p in tree.projects {
            let texts = AgentTexts(general: p.agent.general, commits: p.agent.commits, pullRequests: p.agent.pullRequests)
            agentInstructionsBox.set(org: org.id, project: p.name,
                                     text: agentInstructions(org: org.id, orgTexts: orgTexts, project: p.name, projectTexts: texts))
        }
    }

    /// The ✨ draft's commit rules: the organisation's, then the active project's.
    var commitInstructions: String {
        guard let tree = settings else { return "" }
        let project = tree.projects.first { $0.name == self.project }
        return [tree.org.gitCommitInstructions, project?.agent.commits ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The update block for `agent`'s next turn, or nil when its instructions are what it has. The
    /// first turn of a session records what the launch carried and adds nothing.
    func instructionsUpdate(for agent: PlaceAgent) -> String? {
        let current = agentInstructionsBox.text(org: agent.place.organization, project: agent.place.project)
        guard let had = agent.launchedInstructions else {
            agent.launchedInstructions = current
            return nil
        }
        if had == resumedInstructionsUnknown {
            agent.launchedInstructions = current
            return current.isEmpty ? nil : agentInstructionsUpdateHeader + "\n\n" + current
        }
        guard current != had else { return nil }
        agent.launchedInstructions = current
        let body = current.isEmpty ? "(The operator removed their instructions.)" : current
        return agentInstructionsUpdateHeader + "\n\n" + body
    }
}

extension WindowModel {
    /// The first launch in an organisation can come before anything read its configuration (the
    /// settings read follows the pane opening), so a launch for an organisation the box has never
    /// heard of reads that organisation's tree itself — by id, since the window's active
    /// organisation need not be the launching place's. A read that fails, answers for another
    /// organisation, or takes longer than `agentConnectionsReadTimeout` leaves the box untouched:
    /// the session starts without connections and the next launch asks again.
    func ensureAgentConnections(in place: Place) async {
        let org = place.organization
        guard !agentConnectionsBox.isKnown(org: org) else { return }
        let registry = self.registry
        let read = Task<JSONValue?, Never> {
            try? await registry.dispatch(
                name: "ctx_config_tree_for", params: .object(["id": .string(org)]), origin: .ui,
                caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        }
        let timeout = agentConnectionsReadTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { read.cancel() }
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<JSONValue?, Never>) in
            let once = ResumeOnce(continuation)
            Task { once.resume(await read.value); timer.cancel() }
            Task { _ = await timer.value; once.resume(nil) }
        }
        guard let tree = decodeSettingsTree(fromResult: result), tree.org.id == org else { return }
        agentConnectionsBox.set(org: org, connections: tree.org.connections)
    }
}

/// Resumes a continuation the first time it is asked to and never again.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        let taken = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
