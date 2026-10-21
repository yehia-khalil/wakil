import Foundation

/// Which branches of the settings tree are open: the PROJECTS heading, each project, each
/// environment.
///
/// **Window-life, never persisted, and changed only by the operator** (Rule 6). The defaults are
/// laid once, when the pane first knows the place on screen: PROJECTS open, the active project
/// open, its active environment open, everything else closed. After that a branch closes only
/// when the operator closes it — selecting another node never collapses the one left — and the
/// only automatic change is an OPENING: reaching a node whose parent is closed opens its
/// ancestors, so nothing the operator was taken to is hidden from them.
public struct SettingsTreeExpansion: Equatable, Sendable {
    /// One environment, by project and environment name.
    public struct EnvironmentKey: Hashable, Sendable {
        public var project: String
        public var environment: String
        public init(project: String, environment: String) {
            self.project = project
            self.environment = environment
        }
    }

    /// Whether the PROJECTS heading is open. Closing it hides every project.
    public var projectsOpen: Bool = true
    public private(set) var projects: Set<String> = []
    public private(set) var environments: Set<EnvironmentKey> = []
    /// Whether the defaults have been laid. Until then nothing is open but the heading.
    public private(set) var seeded: Bool = false

    public init() {}

    /// Lays the defaults once: the active project and its active environment open. A second call
    /// does nothing, so the operator's own closings are never undone by a re-read.
    public mutating func seed(activeProject: String, activeEnvironment: String) {
        guard !seeded, !activeProject.isEmpty else { return }
        seeded = true
        reveal(project: activeProject, environment: activeEnvironment)
    }

    /// Opens the heading, the project and, when one is named, its environment — what it takes to
    /// see a node whose parent that is. Never closes anything. A caller opens a node's ANCESTORS
    /// with it, not the node: a database's environment, an environment's project.
    public mutating func reveal(project: String, environment: String? = nil) {
        guard !project.isEmpty else { return }
        projectsOpen = true
        projects.insert(project)
        if let environment, !environment.isEmpty {
            environments.insert(EnvironmentKey(project: project, environment: environment))
        }
    }

    public func isOpen(project: String) -> Bool { projects.contains(project) }

    public func isOpen(project: String, environment: String) -> Bool {
        environments.contains(EnvironmentKey(project: project, environment: environment))
    }

    public mutating func setOpen(_ open: Bool, project: String) {
        if open { projects.insert(project) } else { projects.remove(project) }
    }

    public mutating func setOpen(_ open: Bool, project: String, environment: String) {
        let key = EnvironmentKey(project: project, environment: environment)
        if open { environments.insert(key) } else { environments.remove(key) }
    }

    /// Forgets everything, for another organisation's tree: the next `seed` lays its defaults.
    public mutating func reset() { self = SettingsTreeExpansion() }
}
