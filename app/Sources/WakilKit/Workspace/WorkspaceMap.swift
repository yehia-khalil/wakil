import Foundation

// Workspaces, piece 1 (spec, "The agent sees real paths"): the map an agent's instructions carry —
// its workspace's repos (the copy's path, or Main's folder for a repo it has not changed), each
// one's branch and ports, and the other conversations working there. A conversation in Main also
// gets the project's workspaces: where the other work happens, which it reads but never writes.

/// The header of the block that follows the operator's words in a turn when the agent's map changed
/// (`WindowModel.workspaceMapUpdate`).
public let workspaceMapHeader = "[Wakil: where you work. This map replaces any earlier one.]"

/// What `workspaceMapText` draws from: plain values, so the text is tested without a window.
public struct WorkspaceMapInput: Sendable, Equatable {
    /// The conversation the map is for.
    public var conversation: String
    public var project: String
    public var environment: String
    /// Its workspace with holders and live states; nil for Main.
    public var own: WorkspaceListing?
    /// Main's folders of the project's repos, in the roots' order.
    public var mainRoots: [String]
    /// The branch Main's folder of a root is on, where the window knows it.
    public var mainBranches: [String: String]
    /// The project's unarchived workspaces (the map of a conversation in Main lists them).
    public var workspaces: [WorkspaceListing]
    /// Live conversations in Main, with their states (the conversation itself among them or not).
    public var mainLive: [String: ConversationState]
    /// Each live conversation's title.
    public var titles: [String: String]

    public init(conversation: String, project: String, environment: String, own: WorkspaceListing?,
                mainRoots: [String], mainBranches: [String: String] = [:], workspaces: [WorkspaceListing] = [],
                mainLive: [String: ConversationState] = [:], titles: [String: String] = [:]) {
        self.conversation = conversation
        self.project = project
        self.environment = environment
        self.own = own
        self.mainRoots = mainRoots
        self.mainBranches = mainBranches
        self.workspaces = workspaces
        self.mainLive = mainLive
        self.titles = titles
    }
}

/// The map as the agent reads it: real paths, one repo or conversation a line.
public func workspaceMapText(_ input: WorkspaceMapInput) -> String {
    func title(_ id: String) -> String { "‘\(input.titles[id] ?? id)’" }
    func named(_ w: Workspace) -> String { "‘\(w.name.isEmpty ? w.slug : w.name)’" }
    func ports(_ p: PortBlock?) -> String {
        guard let p, p.count > 0 else { return "" }
        return ", ports \(p.first)–\(p.first + p.count - 1)"
    }
    func mainLine(_ root: String) -> String {
        let branch = input.mainBranches[root].map { $0.isEmpty ? "" : " on \($0)" } ?? ""
        return "- \(clean(root)) — Main's folder\(branch)"
    }
    func others(_ live: [String: ConversationState], holders: [String: String]) -> [String] {
        live.keys.filter { $0 != input.conversation }.sorted().map { id in
            let held = holders.filter { $0.value == id }.keys.map { ($0 as NSString).lastPathComponent }.sorted()
            let holds = held.isEmpty ? "" : ", holds \(held.joined(separator: ", "))"
            return "- \(title(id)) (\(live[id]!.rawValue)\(holds))"
        }
    }

    var lines: [String] = []
    if let own = input.own {
        let w = own.workspace
        lines.append("You are in workspace \(named(w)) of project \(input.project) (\(w.environment)). "
            + "Your writes land in its copies; a repo with no copy yet gets one at your first change there.")
        lines.append("Repos:")
        for root in input.mainRoots {
            if let co = w.checkouts.first(where: { $0.repo == root }), let path = co.path, !co.inMain {
                let holder = own.holders[root].map { $0 == input.conversation ? ", held by you" : ", held by \(title($0))" } ?? ""
                lines.append("- \(clean(path)) — copy of \(clean(root)) on \(co.branch)\(ports(co.ports))\(holder)")
            } else {
                lines.append(mainLine(root) + " (no copy yet)")
            }
        }
        let rest = others(own.live, holders: own.holders)
        lines.append(rest.isEmpty ? "No other conversation works in this workspace." : "Other conversations in this workspace:")
        lines.append(contentsOf: rest)
        return lines.joined(separator: "\n")
    }

    lines.append("You are in Main of project \(input.project) (\(input.environment)): the operator's own folders. "
        + "You read here and never write; your first change starts a workspace of your own.")
    lines.append("Repos:")
    lines.append(contentsOf: input.mainRoots.map(mainLine))
    let rest = others(input.mainLive, holders: [:])
    lines.append(rest.isEmpty ? "No other conversation works in Main." : "Other conversations in Main:")
    lines.append(contentsOf: rest)
    let open = input.workspaces.filter { !$0.workspace.archived && $0.workspace.project == input.project }
    guard !open.isEmpty else {
        lines.append("The project has no workspaces yet.")
        return lines.joined(separator: "\n")
    }
    lines.append("The project's workspaces (each one's copies are written only by its own conversations):")
    for listing in open {
        let w = listing.workspace
        let copies = w.checkouts.compactMap { co -> String? in
            guard let path = co.path, !co.inMain else { return nil }
            return "\(clean(path)) on \(co.branch)\(ports(co.ports))"
        }
        let who = listing.live.keys.sorted().map { "\(title($0)) (\(listing.live[$0]!.rawValue))" }
        var line = "- \(named(w)) (\(w.environment))"
        line += copies.isEmpty ? ": no copies yet" : ": " + copies.joined(separator: "; ")
        if !who.isEmpty { line += " · " + who.joined(separator: ", ") }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

private func clean(_ p: String) -> String { (p as NSString).standardizingPath }
