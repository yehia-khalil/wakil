import Foundation

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
}
