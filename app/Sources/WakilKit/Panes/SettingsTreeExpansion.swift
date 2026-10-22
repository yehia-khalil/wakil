import Foundation

/// Which branches of the settings tree are open: the PROJECTS heading, each project, each
/// environment.
///
/// **Window-life, never persisted, and changed only by the operator** (Rule 6). The defaults are
/// laid once, when the pane first knows the place on screen: PROJECTS open, the active project
/// open, its active environment open, everything else closed. After that a branch closes only
/// when the operator closes it — selecting another node never collapses the one left — and the
/// only automatic change is an OPENING: navigating to a node whose parent is closed opens its
/// ancestors, so nothing the operator was taken to is hidden from them. A place change, a rebuild
/// or a reopened pane opens nothing: `seed` is the only thing they call, and it lays once.
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

extension SettingsTreeExpansion {
    /// Moves a renamed project's open state, and its environments', to the new name, so a rename
    /// closes nothing the operator had open (Rule 6). A closed project stays closed.
    public mutating func renamed(project old: String, to new: String) {
        guard old != new else { return }
        if setOpenProjects(remove: old) { setOpen(true, project: new) }
        for key in environmentKeys(of: old) {
            setOpen(false, project: old, environment: key.environment)
            setOpen(true, project: new, environment: key.environment)
        }
    }

    /// Moves a renamed environment's open state to the new name.
    public mutating func renamed(project: String, environment old: String, to new: String) {
        guard old != new, isOpen(project: project, environment: old) else { return }
        setOpen(false, project: project, environment: old)
        setOpen(true, project: project, environment: new)
    }

    private mutating func setOpenProjects(remove name: String) -> Bool {
        let wasOpen = isOpen(project: name)
        setOpen(false, project: name)
        return wasOpen
    }

    private func environmentKeys(of project: String) -> [EnvironmentKey] {
        environments.filter { $0.project == project }
    }
}

/// Where the tree selects after a project or environment is created, renamed or removed.
///
/// A create or a rename lands on the node itself, under its new name. A removal has no node to
/// stay on, so it lands on the parent: the PROJECTS heading for a project, the project for an
/// environment.
public enum SettingsLanding: Equatable, Sendable {
    case projects
    case project(String)
    case environment(project: String, environment: String)

    public static func afterCreatingProject(_ name: String) -> SettingsLanding { .project(name) }
    public static func afterCreatingEnvironment(project: String, name: String) -> SettingsLanding {
        .environment(project: project, environment: name)
    }
    public static func afterRenamingProject(to name: String) -> SettingsLanding { .project(name) }
    public static func afterRenamingEnvironment(project: String, to name: String) -> SettingsLanding {
        .environment(project: project, environment: name)
    }
    public static func afterRemovingProject() -> SettingsLanding { .projects }
    public static func afterRemovingEnvironment(project: String) -> SettingsLanding { .project(project) }
}
