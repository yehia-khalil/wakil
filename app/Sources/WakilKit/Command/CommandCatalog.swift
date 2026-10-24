import Foundation

/// The pane ⌘K was opened over: its id, which pane-scoped commands dispatch against, and its
/// kind, which picks the commands offered. A struct rather than a tuple so the context stays
/// `Equatable`.
public struct FocusedPane: Sendable, Equatable {
    public var id: String
    public var kind: String

    public init(id: String, kind: String) {
        self.id = id
        self.kind = kind
    }
}

/// The focused editor pane's diff tab in front (3a-ii-b): its file, absolute, and its group.
public struct EditorActiveDiff: Sendable, Equatable {
    public var path: String
    public var group: GitGroup
    public init(path: String, group: GitGroup) {
        self.path = path
        self.group = group
    }
}

/// A snapshot of the window state the catalog's predicates and params read. Built by the
/// window when ⌘K opens and again whenever that state moves, so a command appears or goes
/// while the palette is open (a send starts → Cancel appears).
public struct PaletteContext: Sendable, Equatable {
    public var focusedPane: FocusedPane?
    public var apiSendInFlight: Bool
    /// The focused editor pane has a file tab in front (not a scratch): *Reveal Active File in Tree* is offered.
    public var editorActiveIsFile: Bool
    /// The focused editor pane has a diff tab in front: Stage / Unstage Selected Ranges are offered.
    public var editorActiveDiff: EditorActiveDiff?
    public var dbPageHasNext: Bool
    public var dbPageHasPrevious: Bool
    public var hasEnvironments: Bool
    public var projectCount: Int
    public var providerCount: Int
    /// The organisation and project the palette was opened in. The window refuses to run an
    /// entry once either has moved (Review Focus 3): a row built for one project must not act
    /// on another.
    public var organisation: String
    public var project: String
    /// The screen shows a conversation, not its place's Landing: *New conversation* is offered.
    public var conversationOnScreen: Bool
    /// 3a-iv: the root the Branch segment is about (`WindowModel.activeBranchRoot`); nil with no git root.
    public var activeGitRoot: String?

    public init(
        focusedPane: FocusedPane? = nil, apiSendInFlight: Bool = false,
        dbPageHasNext: Bool = false, dbPageHasPrevious: Bool = false,
        hasEnvironments: Bool = false, projectCount: Int = 0, providerCount: Int = 0,
        editorActiveIsFile: Bool = false, organisation: String = "", project: String = "",
        editorActiveDiff: EditorActiveDiff? = nil, conversationOnScreen: Bool = false,
        activeGitRoot: String? = nil
    ) {
        self.activeGitRoot = activeGitRoot
        self.focusedPane = focusedPane
        self.apiSendInFlight = apiSendInFlight
        self.editorActiveIsFile = editorActiveIsFile
        self.editorActiveDiff = editorActiveDiff
        self.dbPageHasNext = dbPageHasNext
        self.dbPageHasPrevious = dbPageHasPrevious
        self.hasEnvironments = hasEnvironments
        self.projectCount = projectCount
        self.providerCount = providerCount
        self.organisation = organisation
        self.project = project
        self.conversationOnScreen = conversationOnScreen
    }
}

/// Where a choice step's list comes from. The palette's sources answer each; the catalog
/// only names which.
public enum ChoiceSource: String, Sendable {
    case environments, projects, providers, paneKinds
    /// Monaco's languages the editor offers (`editorLanguageChoices`).
    case languages
    /// 3a-iv: the active root's local branches.
    case branches
}

/// The languages *Set language…* offers (⌘K), Monaco ids, plaintext first.
public let editorLanguageChoices = [
    "plaintext", "sql", "json", "go", "typescript", "javascript", "php", "yaml", "markdown", "shell",
    "html", "css", "python", "swift", "ini", "dockerfile", "xml",
]

/// The step a `…` command pushes before it runs.
public enum CommandInput: Sendable, Equatable {
    /// Pick one of the values that exist — you cannot pick one that does not.
    case choice(ChoiceSource, placeholder: String)
    /// A genuinely open value. `recentKey` names this window's recent entries, shown as
    /// suggestions and never as a restriction (rule 9).
    case text(placeholder: String, recentKey: String)
}

/// Which commands a command sits among: the focused pane's kind's, or the global ones.
public enum CommandScope: Sendable, Equatable {
    case pane(String)
    case global
}

/// One operator verb in ⌘K: a label pinned to one registered action.
public struct CatalogCommand: Sendable {
    /// Stable: "db.refetch", "global.env", …
    public let id: String
    /// What the operator reads. Ends in `…` exactly when the command takes an input step.
    public let label: String
    public let scope: CommandScope
    /// The registry action's name. A `window.` name reaches no registry: the window runs it,
    /// because what it does needs window state the catalog cannot see (`api.send`).
    public let action: String
    public let input: CommandInput?
    /// The dispatch params given the context and the step's value (nil when no input).
    public let params: @Sendable (PaletteContext, String?) -> JSONValue
    public let available: @Sendable (PaletteContext) -> Bool
}

/// The curated ⌘K list. **Raw registry actions never appear**: each row is a verb the
/// operator would say, pinned to a registered action so a renamed action fails the build
/// (`CommandCatalogTests`) instead of leaving a dead row.
///
/// **Hidden, not disabled.** A command that cannot run now is not in `entries(for:)` at all —
/// Cancel exists only while a send is in flight.
///
/// **Left out because the registry has no action for it:** *Format query* (the query line's
/// own `SQLFormat`, run in the editor, dispatches nothing).
public enum CommandCatalog {
    public static let all: [CatalogCommand] = [
        pane("db.refetch", "Run query again", "db", "db_refetch"),
        pane("db.next", "Next page", "db", "db_page", extra: ["to": .string("next")],
             available: { $0.dbPageHasNext }),
        pane("db.previous", "Previous page", "db", "db_page", extra: ["to": .string("previous")],
             available: { $0.dbPageHasPrevious }),
        close("db"),

        // **Send is the window's**, not one dispatch: it flushes the held fields first, then
        // picks `api_request` or `api_send` by method and composes `api_send`'s statement
        // (`apiSendPlan`). None of that is in the context, so the window runs it.
        pane("api.send", "Send", "api", "window.apiSend", available: { !$0.apiSendInFlight }),
        pane("api.cancel", "Cancel send", "api", "api_cancel", available: { $0.apiSendInFlight }),
        CatalogCommand(
            id: "api.curl", label: "Fill from cURL…", scope: .pane("api"),
            action: "api_fill_from_curl",
            input: .text(placeholder: "cURL command", recentKey: "api.curl"),
            params: { c, value in
                .object(["pane": .string(c.focusedPane?.id ?? ""), "text": .string(value ?? "")])
            },
            available: { _ in true }),
        close("api"),

        close("terminal"),

        CatalogCommand(
            id: "editor.language", label: "Set language…", scope: .pane("editor"),
            action: "editor_set_language",
            input: .choice(.languages, placeholder: "Language"),
            params: { c, value in
                .object(["pane": .string(c.focusedPane?.id ?? ""), "language": .string(value ?? "")])
            },
            available: { _ in true }),

        // 3b-ii-b. The window's: it shows Files, opens the folders and selects the row, which no one
        // dispatch does (`WindowModel.revealActiveFileInTree`). Hidden without a file tab in front.
        pane("editor.reveal", "Reveal Active File in Tree", "editor", "window.editorReveal",
             available: { $0.editorActiveIsFile }),

        // 3a-ii-b. The diff tab in front, with its selection (or its caret's line) as the ranges.
        diffRanges("editor.stageRanges", "Stage Selected Ranges", "editor_changes_stage_ranges", .changed),
        diffRanges("editor.unstageRanges", "Unstage Selected Ranges", "editor_changes_unstage_ranges", .staged),

        choice("global.env", "Switch environment…", "ctx_set_environment",
               .environments, "Environment", available: { $0.hasEnvironments }),
        // The window switches project and provider through `WindowModel.setProject` /
        // `setProvider`, which do more than these writes; the action named is the registered
        // one each path ends in.
        choice("global.project", "Switch project…", "ctx_set_project",
               .projects, "Project", available: { $0.projectCount > 1 }),
        choice("global.provider", "Switch provider…", "ctx_set_provider",
               .providers, "Provider", available: { $0.providerCount > 1 }),
        // 3a-iv (spec call 1): the active root's branches, as the Branch segment's picker lists them.
        CatalogCommand(
            id: "global.branch", label: "Switch branch…", scope: .global, action: "editor_changes_switch",
            input: .choice(.branches, placeholder: "Branch"),
            params: { c, value in .object(["root": .string(c.activeGitRoot ?? ""), "branch": .string(value ?? "")]) },
            available: { $0.activeGitRoot != nil }),
        CatalogCommand(
            id: "global.settings", label: "Open settings", scope: .global,
            action: "settings_open", input: nil,
            params: { _, _ in .object([:]) }, available: { _ in true }),
        CatalogCommand(
            id: "global.newpane", label: "New pane…", scope: .global, action: "pane_open",
            input: .choice(.paneKinds, placeholder: "Pane kind"),
            params: { _, value in .object(["kind": .string(value ?? "")]) },
            available: { _ in true }),
        // Conversations 2 of 3: ⌘N's verb. Hidden on a Landing, where it would do nothing.
        CatalogCommand(
            id: "global.newConversation", label: "New conversation", scope: .global,
            action: "session_new", input: nil,
            params: { _, _ in .object([:]) }, available: { $0.conversationOnScreen }),
    ]

    /// Focused pane's commands first (catalog order), then global; unavailable ones dropped.
    public static func entries(for context: PaletteContext) -> [PaletteEntry] {
        let kind = context.focusedPane?.kind
        let paneCommands = all.filter { $0.scope == .pane(kind ?? "") && kind != nil }
        let globalCommands = all.filter { $0.scope == .global }
        return (paneCommands + globalCommands).filter { $0.available(context) }.map { c in
            PaletteEntry(
                id: c.id, group: .commands, title: c.label, subtitle: "", kindLabel: "command",
                verb: c.input == nil ? "run" : "choose",
                action: c.input == nil
                    ? .dispatch(action: c.action, params: c.params(context, nil))
                    : .pushStep(commandId: c.id))
        }
    }

    public static func command(id: String) -> CatalogCommand? {
        all.first { $0.id == id }
    }

    /// A command on the focused pane whose params are `pane` plus `extra`.
    private static func pane(
        _ id: String, _ label: String, _ kind: String, _ action: String,
        extra: [String: JSONValue] = [:],
        available: @escaping @Sendable (PaletteContext) -> Bool = { _ in true }
    ) -> CatalogCommand {
        CatalogCommand(
            id: id, label: label, scope: .pane(kind), action: action, input: nil,
            params: { c, _ in
                .object(extra.merging(["pane": .string(c.focusedPane?.id ?? "")]) { a, _ in a })
            },
            available: available)
    }

    /// Stage / Unstage Selected Ranges, offered on a diff of `group` in front.
    private static func diffRanges(_ id: String, _ label: String, _ action: String, _ group: GitGroup) -> CatalogCommand {
        CatalogCommand(
            id: id, label: label, scope: .pane("editor"), action: action, input: nil,
            params: { c, _ in
                .object(["pane": .string(c.focusedPane?.id ?? ""), "path": .string(c.editorActiveDiff?.path ?? "")])
            },
            available: { $0.editorActiveDiff?.group == group })
    }

    /// Close pane, one per kind the spec offers it on. `pane_close` names its pane `id`.
    private static func close(_ kind: String) -> CatalogCommand {
        CatalogCommand(
            id: "\(kind).close", label: "Close pane", scope: .pane(kind), action: "pane_close",
            input: nil, params: { c, _ in .object(["id": .string(c.focusedPane?.id ?? "")]) },
            available: { $0.focusedPane != nil })
    }

    /// A global command that switches to the chosen value, sent as `name`.
    private static func choice(
        _ id: String, _ label: String, _ action: String, _ source: ChoiceSource,
        _ placeholder: String, available: @escaping @Sendable (PaletteContext) -> Bool
    ) -> CatalogCommand {
        CatalogCommand(
            id: id, label: label, scope: .global, action: action,
            input: .choice(source, placeholder: placeholder),
            params: { _, value in .object(["name": .string(value ?? "")]) },
            available: available)
    }
}
