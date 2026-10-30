import Foundation

// Invariant 8 beyond the screen's project: the home's cards, ⌘P's Running group and Start in draw
// environments of every project, so each must be judged by its own project's declarations — not by
// its name alone, which is all a project other than the screen's had before (the scenario audit).

/// Every project's environments as the organisation's configuration declares them (`config_tree`),
/// each with its production flag.
public struct OrgEnvironments: Sendable, Equatable {
    public struct Environment: Sendable, Equatable {
        public let name: String
        /// The Go side's `EnvironmentIsProduction` (the flag, else the name); nil from a `wakil-ctx`
        /// that predates the field, which leaves the name to answer.
        public let production: Bool?
        public init(name: String, production: Bool?) {
            self.name = name
            self.production = production
        }
    }

    /// Project (registry key) → its environments, in the tree's order.
    public let projects: [String: [Environment]]

    /// Nothing read: every environment answers by its name, as before.
    public static let unread = OrgEnvironments(projects: [:])

    public init(projects: [String: [Environment]]) {
        self.projects = projects
    }

    /// Each project's environment names, for Start in.
    public var names: [String: [String]] { projects.mapValues { $0.map(\.name) } }

    /// Whether an environment of a project is production: the screen's project (`current`) by the
    /// window's own flags — the gate's — and any other by its declaration here, else by its name.
    public func judge(current: String, flags: EnvironmentProduction) -> @Sendable (String, String) -> Bool {
        let projects = projects
        return { project, environment in
            if project == current { return flags.isProduction(environment) }
            let folded = foldEnvironmentName(environment)
            let declared = projects[project]?.first { foldEnvironmentName($0.name) == folded }?.production
            return isProductionEnvironment(environment, declared: declared)
        }
    }
}
