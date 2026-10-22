import Foundation

/// The marked block a live agent's next turn opens with when its instructions changed (spec
/// amendment 2026-10-22: a resumed session ignores a new appended prompt).
public let agentInstructionsUpdateHeader =
    "[Wakil: the operator updated your instructions. They replace any earlier ones under the same headings.]"

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
        guard current != had else { return nil }
        agent.launchedInstructions = current
        let body = current.isEmpty ? "(The operator removed their instructions.)" : current
        return agentInstructionsUpdateHeader + "\n\n" + body
    }
}
