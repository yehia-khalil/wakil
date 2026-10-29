import Foundation

// Workspaces, piece 1: the record `wakilcore` keeps in ~/.wakil/orgs/<org>/workspaces.json
// (`internal/wakilcore/workspaces.go`), as the window reads and writes it through wakil-git's
// `workspaces_read` / `workspaces_write`. Main is not in it: Main is the project's own folders.

/// A checkout's ports (piece 2 hands them out; nil until then).
public struct PortBlock: Codable, Sendable, Equatable, Hashable {
    public var first: Int
    public var count: Int
    public init(first: Int, count: Int) {
        self.first = first
        self.count = count
    }
}

/// One repo of a workspace. `repo` is the project root (Main's folder) it is a checkout of; `path`
/// the worktree, nil while none is made (archived, brought to Main, not yet re-made after Restore);
/// `snapshot` the ref holding its uncommitted work meanwhile; `lastHolder` the lineage root of the
/// conversation that last held it.
public struct WorkspaceCheckout: Codable, Sendable, Equatable, Hashable {
    public var repo: String
    public var path: String?
    public var branch: String
    public var base: String?
    public var ports: PortBlock?
    public var lastHolder: String?
    public var inMain: Bool
    public var snapshot: String?

    public init(repo: String, path: String? = nil, branch: String, base: String? = nil, ports: PortBlock? = nil,
                lastHolder: String? = nil, inMain: Bool = false, snapshot: String? = nil) {
        self.repo = repo
        self.path = path
        self.branch = branch
        self.base = base
        self.ports = ports
        self.lastHolder = lastHolder
        self.inMain = inMain
        self.snapshot = snapshot
    }

    enum CodingKeys: String, CodingKey { case repo, path, branch, base, ports, lastHolder, inMain, snapshot }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(String.self, forKey: .repo)
        path = try c.decodeIfPresent(String.self, forKey: .path).flatMap { $0.isEmpty ? nil : $0 }
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        base = try c.decodeIfPresent(String.self, forKey: .base)
        ports = try c.decodeIfPresent(PortBlock.self, forKey: .ports)
        lastHolder = try c.decodeIfPresent(String.self, forKey: .lastHolder)
        inMain = try c.decodeIfPresent(Bool.self, forKey: .inMain) ?? false
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
    }

    /// The repo's folder name, as cards and thread lines name it.
    public var repoName: String { (repo as NSString).lastPathComponent }
}

/// One piece of work in one project and environment (the glossary's *workspace*). `conversations`
/// are lineage roots, newest last; `view` the key its canvas is filed under; `parent` the workspace
/// a branch-off came from (decision 9).
public struct Workspace: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var slug: String
    public var project: String
    public var environment: String
    public var tickets: [String]
    public var parent: String?
    public var branch: String?
    public var checkouts: [WorkspaceCheckout]
    public var conversations: [String]
    public var view: String?
    public var archived: Bool
    public var created: String?

    public init(id: String, name: String, slug: String, project: String, environment: String,
                tickets: [String] = [], parent: String? = nil, branch: String? = nil,
                checkouts: [WorkspaceCheckout] = [], conversations: [String] = [], view: String? = nil,
                archived: Bool = false, created: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.project = project
        self.environment = environment
        self.tickets = tickets
        self.parent = parent
        self.branch = branch
        self.checkouts = checkouts
        self.conversations = conversations
        self.view = view
        self.archived = archived
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, project, environment, tickets, parent, branch, checkouts, conversations, view, archived, created
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? ""
        tickets = try c.decodeIfPresent([String].self, forKey: .tickets) ?? []
        parent = try c.decodeIfPresent(String.self, forKey: .parent).flatMap { $0.isEmpty ? nil : $0 }
        branch = try c.decodeIfPresent(String.self, forKey: .branch).flatMap { $0.isEmpty ? nil : $0 }
        checkouts = try c.decodeIfPresent([WorkspaceCheckout].self, forKey: .checkouts) ?? []
        conversations = try c.decodeIfPresent([String].self, forKey: .conversations) ?? []
        view = try c.decodeIfPresent(String.self, forKey: .view)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        created = try c.decodeIfPresent(String.self, forKey: .created)
    }

    /// The checkout of `repo`, made or not.
    public func checkout(of repo: String) -> WorkspaceCheckout? { checkouts.first { $0.repo == repo } }

    /// The key its view (canvas) is filed under: `view`, else its id.
    public var viewKey: String { view ?? id }
}

/// The whole record.
public struct WorkspacesFile: Codable, Sendable, Equatable {
    public var workspaces: [Workspace]
    public init(workspaces: [Workspace] = []) { self.workspaces = workspaces }

    enum CodingKeys: String, CodingKey { case workspaces }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
    }
}
