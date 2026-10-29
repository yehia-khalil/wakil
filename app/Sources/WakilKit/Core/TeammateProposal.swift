import Foundation

// Workspaces piece 5: a teammate proposal, in Core so `LiveConversation` (`session_list`) can carry
// the proposals a conversation made. The rest of crews is `Workspace/Crews.swift`.

/// One teammate proposal: `from` (a live conversation) suggests a conversation for `repo` (Main's
/// folder of one of the project's repos) in its workspace (`workspace`: piece 4's
/// `MessageWorkspace` key — a workspace id, or `main/<org>/<project>/<env>`).
public struct TeammateProposal: Sendable, Equatable, Identifiable {
    public let id: String
    public let from: String
    public let fromTitle: String
    public let workspace: String
    public let repo: String
    public var brief: String

    public init(id: String, from: String, fromTitle: String, workspace: String, repo: String, brief: String) {
        self.id = id
        self.from = from
        self.fromTitle = fromTitle
        self.workspace = workspace
        self.repo = repo
        self.brief = brief
    }

    /// The repo's folder name: `web`.
    public var repoName: String { (repo as NSString).lastPathComponent }

    /// The readable part (`session_list`, the actions' answers).
    public var json: JSONValue {
        .object([
            "proposal": .string(id), "from": .string(from), "fromTitle": .string(fromTitle),
            "repo": .string(repo), "repoName": .string(repoName), "brief": .string(brief),
        ])
    }
}
