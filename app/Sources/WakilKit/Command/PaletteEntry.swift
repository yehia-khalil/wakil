import Foundation

/// The section a palette row sits under. The raw value is the display
/// order, so sorting by group is sorting by `rawValue`.
public enum PaletteGroup: Int, Sendable, Comparable, CaseIterable {
    /// Live conversations, above everything (conversations 2 of 3): -1, so no other group's
    /// value moves.
    case running = -1
    case openPanes = 0, newPane, resources
    /// Tickets in flight (ticket noticing): after files and tables, before projects.
    case tickets
    case projects, sessions, providers, commands, choices

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The section header the operator reads.
    public var label: String {
        switch self {
        case .running: "Running"
        case .openPanes: "Open panes"
        case .newPane: "New pane"
        case .resources: "Resources"
        case .tickets: "Tickets"
        case .projects: "Projects"
        case .sessions: "Sessions"
        case .providers: "Providers"
        case .commands: "Commands"
        case .choices: "Choices"
        }
    }
}

/// Where a row ranks against the others whatever its score (`PaletteSearch.rank`): a ticket matched
/// by its key or a number above every row, Running included; a ticket matched by words after the
/// last file or table and before projects; every other row by score. Higher first.
public enum PaletteTier: Int, Sendable, Comparable {
    case belowResources = -1, ordinary = 0, key = 1

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What choosing a row does. The palette view switches on this and nothing
/// else, so a new kind of row is a new case here, not a new view.
public enum PaletteAction: Sendable, Equatable {
    case dispatch(action: String, params: JSONValue)
    case focusPane(id: String)
    /// A catalog entry's input step.
    case pushStep(commandId: String)
    /// A row that opens its children, e.g. a database row → its tables.
    case drill(sourceId: String, value: String)
    case setProject(String), setProvider(String), resumeSession(String)
    /// A project file: the window opens it in the focused or first editor pane, or a new one
    /// (`editor_open` with no pane).
    case openInEditor(path: String)
}

/// One row in ⌘P or ⌘K.
///
/// Replaces `PaletteItem` once the callers move over: every row carries its
/// own group, verb and action, so the view needs no per-kind switch to draw
/// or run it.
public struct PaletteEntry: Sendable, Equatable, Identifiable {
    /// Stable, unique within one result set.
    public let id: String
    public let group: PaletteGroup
    public let title: String
    public let subtitle: String
    /// "table", "api", "git", "pane", "project", "session", "provider", "command", …
    public let kindLabel: String
    /// "open", "switch to", "run", "choose".
    public let verb: String
    public let action: PaletteAction
    public var isProduction: Bool
    /// A source's error row: shown, never runnable.
    public var isError: Bool
    /// The subtitle is drawn in §5's amber: a provider row whose capacity is at 20% or
    /// less (`PaletteItem.caution`). Never red — red is production's.
    public var isCaution: Bool
    /// Drawn dimmed and ranked after every undimmed match: a gitignored file (3b-ii), listed so it
    /// can be opened, but below everything the project tracks.
    public var isDimmed: Bool
    /// A live conversation's row draws its state's dot; every other row is nil and draws none.
    public var state: ConversationState?
    /// Ranked by this before score (`PaletteTier`).
    public var tier: PaletteTier
    /// What ⌘↩ runs on this row, and the footer's words for it (`⌘↩ hand to agent`); nil on a row
    /// ⌘↩ does nothing for.
    public var altAction: PaletteAction?
    public var altVerb: String?

    public init(
        id: String, group: PaletteGroup, title: String, subtitle: String, kindLabel: String,
        verb: String, action: PaletteAction, isProduction: Bool = false, isError: Bool = false,
        isCaution: Bool = false, isDimmed: Bool = false, state: ConversationState? = nil,
        tier: PaletteTier = .ordinary, altAction: PaletteAction? = nil, altVerb: String? = nil
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.kindLabel = kindLabel
        self.verb = verb
        self.action = action
        self.isProduction = isProduction
        self.isError = isError
        self.isCaution = isCaution
        self.isDimmed = isDimmed
        self.state = state
        self.tier = tier
        self.altAction = altAction
        self.altVerb = altVerb
    }
}
