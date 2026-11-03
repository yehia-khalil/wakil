import Foundation

/// The three scopes the settings tree is grouped under (design-language §14): what is the
/// app's, what is the organisation's, and the projects.
public enum SettingsScope: Sendable {
    case wakil, organisation, projects
}

/// Where the operator is standing in the config tree.
///
/// Keyed by NAME rather than by index, for the reason a pane's column
/// widths are: the tree is re-read from disk on every read, so an index
/// into it survives a read that reordered or removed something and points
/// at a different subject afterwards. A name that is gone is gone, and the
/// subject column says so.
public enum SettingsNode: Hashable, Sendable {
    /// The PROJECTS heading: where a removed project leaves the operator, with nothing of its
    /// own to show but the receipt.
    case projects
    case organisation
    /// Labelled "Accounts" (settings revamp); the case and its fragment keep the old name so
    /// every e2e check still reaches it.
    case providers
    case quickTasks
    case browsingData
    case speech
    case editor
    case browser
    case keyboard
    case projectEditor(String)
    case project(String)
    case environment(project: String, environment: String)
    case databases(project: String, environment: String)
    case api(project: String, environment: String)

    /// The pages a scope's heading lists, in order. PROJECTS is drawn from the tree's projects.
    public static func topLevel(_ scope: SettingsScope) -> [SettingsNode] {
        switch scope {
        case .wakil: return [.editor, .browser, .keyboard]
        case .organisation: return [.organisation, .providers, .quickTasks, .browsingData, .speech]
        case .projects: return []
        }
    }

    /// The tree label of a top-level page. A project's nodes are labelled by their names.
    public var label: String {
        switch self {
        case .projects: return "Projects"
        case .organisation: return "Organisation"
        case .providers: return "Accounts"
        case .quickTasks: return "Quick tasks"
        case .browsingData: return "Browsing data"
        case .speech: return "Speech"
        case .editor, .projectEditor: return "Editor"
        case .browser: return "Browser"
        case .keyboard: return "Keyboard"
        case .project(let name): return name
        case .environment(_, let environment): return environment
        case .databases: return "Databases"
        case .api: return "API"
        }
    }

    /// A stable fragment for this node's accessibility identifier.
    ///
    /// **Not derived from the label**, which is the organisation's display
    /// name and changes the moment the pane's own form edits it — an
    /// identifier that moves when the thing it names is edited is no
    /// identifier at all.
    public var identifierFragment: String {
        switch self {
        case .organisation: return "organisation"
        case .providers: return "providers"
        case .quickTasks: return "quickTasks"
        case .browsingData: return "browsingData"
        case .speech: return "speech"
        case .projects: return "projects"
        case .editor: return "editor"
        case .browser: return "browser"
        case .keyboard: return "keyboard"
        case .projectEditor(let name): return "projectEditor.\(name)"
        case .project(let name): return "project.\(name)"
        case .environment(let project, let environment):
            return "environment.\(project).\(environment)"
        case .databases(let project, let environment):
            return "databases.\(project).\(environment)"
        case .api(let project, let environment):
            return "api.\(project).\(environment)"
        }
    }

    /// This node after a project is renamed: the same place under the new name, so a rename
    /// never throws the operator to a page that says the node is gone.
    public func renaming(project old: String, to new: String) -> SettingsNode {
        switch self {
        case .project(old): return .project(new)
        case .projectEditor(old): return .projectEditor(new)
        case .environment(old, let e): return .environment(project: new, environment: e)
        case .databases(old, let e): return .databases(project: new, environment: e)
        case .api(old, let e): return .api(project: new, environment: e)
        default: return self
        }
    }

    /// This node after an environment is renamed.
    public func renaming(project: String, environment old: String, to new: String) -> SettingsNode {
        switch self {
        case .environment(project, old): return .environment(project: project, environment: new)
        case .databases(project, old): return .databases(project: project, environment: new)
        case .api(project, old): return .api(project: project, environment: new)
        default: return self
        }
    }

    /// The breadcrumb for this node: the scope, then the page. Four levels down needs one to say
    /// where you are.
    public func breadcrumb(in tree: SettingsTree?) -> [String] {
        let organisation = tree?.org.label ?? "Organisation"
        switch self {
        case .organisation, .providers, .quickTasks, .browsingData, .speech, .projects:
            return [organisation, label]
        case .editor, .browser, .keyboard:
            return ["Wakil", label]
        case .projectEditor(let name):
            return [organisation, "Projects", name, "Editor"]
        case .project(let name):
            return [organisation, "Projects", name]
        case .environment(let project, let environment):
            return [organisation, "Projects", project, environment]
        case .databases(let project, let environment):
            return [organisation, "Projects", project, environment, "Databases"]
        case .api(let project, let environment):
            return [organisation, "Projects", project, environment, "API"]
        }
    }
}
