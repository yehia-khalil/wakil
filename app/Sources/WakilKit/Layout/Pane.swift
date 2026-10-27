import Foundation

/// One pane's rectangle on the canvas, in canvas points.
///
/// A plain value type rather than `CGRect` so that `LayoutStore` and
/// `SnapSolver` — where all the geometry actually happens — stay free of
/// CoreGraphics and AppKit, and can therefore be exercised in
/// `WakilKitTests` without a display. The view layer converts to `CGRect`
/// at the boundary and nowhere else.
///
/// `y` grows **downward**, matching SwiftUI's coordinate space, so `minY`
/// is the top edge. Getting this backwards is the obvious way to write a
/// snap solver that works in tests and is upside down on screen.
public struct PaneFrame: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    /// The top edge — `y` grows downward.
    public var minY: Double { y }
    /// The bottom edge.
    public var maxY: Double { y + height }

    /// Whether the two rectangles overlap in **both** axes.
    ///
    /// Touching is deliberately not intersecting: two snapped panes sit
    /// exactly flush, so a `<=` here would report every snapped pair as
    /// overlapping and make "is this arrangement valid?" permanently
    /// false.
    public func intersects(_ other: PaneFrame) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }
}

/// Which side of a pane a snap relates to.
public enum SnapEdge: String, Sendable, Codable, CaseIterable {
    case left, right, top, bottom

    /// The edge that meets this one when two panes snap: a pane's `right`
    /// sits against its neighbour's `left`.
    public var opposite: SnapEdge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    /// True for `left` and `right` — the edges that move along the x axis.
    /// A horizontal edge's snap matches *height*; a vertical one's matches
    /// *width*.
    public var isHorizontal: Bool { self == .left || self == .right }
}

/// How tall a data surface's rows are — `design-language.md` §8's density
/// toggle, remembered per pane.
///
/// Airy is the default, chosen for beauty and for the secondary line it
/// affords; dense exists because scanning a large result set is the pane's
/// real job.
public enum PaneDensity: String, Sendable, Codable, CaseIterable {
    case airy, dense

    public var rowHeight: Double {
        switch self {
        case .airy: return 40
        case .dense: return 23
        }
    }

    public var toggled: PaneDensity { self == .airy ? .dense : .airy }
}

/// One pane on the canvas: what it is, what it is called, and where it sits.
///
/// **Contents are not here.** What is *inside* a pane — columns, rows,
/// `truncated` — stays in `PaneStore`, which the agent reads through
/// `read_pane` and which 2c rewrites when the real data surface lands.
/// Geometry has a different writer, a different lifetime and different
/// persistence, so merging the two would put 2c's churn on top of this
/// phase's layout invariants.
///
/// `kind` is a string rather than an enum because 2b-i ships exactly one
/// kind (`"db"`) and 2c is where the real pane types arrive. An enum with
/// one case would be a decision made before its requirements exist.
public struct Pane: Sendable, Equatable, Identifiable, Codable {
    /// The narrowest a pane may ever end up, in canvas points.
    ///
    /// Shared by the view's own resize clamp (the pane under the pointer
    /// must not shrink past a size its own handle can no longer be
    /// grabbed at) and by `LayoutStore.resize`'s neighbour clamp (a
    /// snapped neighbour dragged by the *other* pane's border must not be
    /// driven to zero or negative). One number in one place so the two
    /// clamps cannot drift apart.
    public static let minimumWidth: Double = 120
    /// The shortest a pane may ever end up, in canvas points. See
    /// `minimumWidth`.
    public static let minimumHeight: Double = 80

    /// Every pane kind this build can draw and route to.
    ///
    /// **2b-i's acceptance runbook set the trigger for this explicitly**
    /// ("Stale pane kinds are not validated"): the check must land in 2c,
    /// before 2c adds its second kind, because the moment there are two a
    /// layout saved under a version that had a third becomes loadable and
    /// a pane the app cannot draw goes on the canvas. It arrived earlier
    /// than that, and from the other direction — an agent opened panes
    /// with `kind: "database"`, which nothing rejected and nothing
    /// recognises, and then every query it ran without naming a pane went
    /// nowhere: `queryTargetPane` looks for a pane whose kind is exactly
    /// `"db"`, found none among three open database panes, and fell
    /// through to the `"db"` key no pane on the canvas holds. Three panes
    /// reading "no rows" again, from a third cause.
    ///
    /// **2c-iii adds the second kind**, beside the view that can draw it
    /// (`WakilApp/TerminalPane.swift`) — which is the rule this set has
    /// always stated and could not demonstrate with one member. **2c-iv
    /// adds the third the same way** (#188), beside `WakilApp/ApiPane.swift`.
    /// `"board"` arrives with 2c-vi on the same terms; listing it now would
    /// be the decision-before-requirements this type's `kind`-is-a-String
    /// comment already refuses.
    /// The settings pane's kind, named rather than spelled at each of its
    /// call sites because more code branches on this one string than on
    /// either of the others.
    ///
    /// **It is a pane, and it is not like the other panes.** Three
    /// properties separate it, all of them 2e rulings (Decision 30):
    ///
    /// - **Singleton.** ⌘, opens exactly one. `LayoutStore.openSettings`
    ///   is the only way to open one and returns the existing pane rather
    ///   than a second.
    /// - **Never saved.** It is stripped from the layout file on write and
    ///   on read (`layoutWithoutOverlayPanes`), which REMOVES the
    ///   projectless-organisation hole rather than handling it: a layout
    ///   cannot restore a pane that must not be restored if the layout
    ///   never held one.
    /// - **Readable by the agent, drivable by nobody but the operator.**
    ///   The asymmetry is new, and the snapshot stays whole: `read_pane`
    ///   answers for it and `read_layout` names it under `overlay`, while
    ///   every action that drives it is operator-only.
    ///
    /// **Why a pane and not a plane, which is what the artboards drew.**
    /// The plane lost on a measurement, not a preference: `read_layout`
    /// emits no key for a plane at all, so an agent would read back a
    /// perfectly normal layout while the canvas was inert behind an
    /// overlay — or while no organisation was open at all. A second,
    /// independent argument is that `WakilApp` has no test target and
    /// `WakilKit` does, so a plane's state is pinned only by a runbook.
    public static let settingsKind = SettingsPaneKind.names[0]

    /// 2e (#198) adds the fourth, `settings`. Unlike the other three it is
    /// a SINGLETON and is never saved — `layoutWithoutOverlayPanes` strips
    /// it before persistence — but it is a registered kind all the same,
    /// so it is listed here like any other, and each name is served by a
    /// `PaneKind` in `App/PaneKinds.swift`.
    /// 3b-iii removes `git`: the Git pane folded into the editor, and a saved one is migrated
    /// (`layoutMigratingGitPanes`).
    public static let kinds: Set<String> = ["db", "terminal", "api", settingsKind, "editor", "browser"]

    /// The title a pane opened with none is given: the kind's wire word, except where the
    /// operator reads a name — `Editor` (3b-i).
    public static func defaultTitle(kind: String) -> String {
        switch kind {
        case "editor": "Editor"
        case "browser": "Browser"
        default: kind
        }
    }

    public let id: String
    public let kind: String
    public var title: String
    public var frame: PaneFrame
    /// True while a dispatched action naming this pane is in flight. The
    /// rail reads it; nothing else does. Set and cleared by `WindowModel`
    /// around a dispatch, which is the whole of §9's "a working pane glows
    /// green in the periphery" — there is no spinner and none is wanted.
    ///
    /// **Runtime state, and deliberately absent from `CodingKeys` below**,
    /// so it is neither written by `LayoutPersistence` nor restored by it.
    /// A dispatch that was in flight when the app quit is not in flight
    /// when it reopens; persisting the flag would restore a pane that
    /// glows for a call nobody is waiting on, and nothing would ever clear
    /// it. `read_layout` reports it to the agent by hand
    /// (`MCPServer.layoutPayload`), which is live state and so is correct.
    public var busy: Bool = false

    /// This pane's row density (§8), remembered per pane.
    ///
    /// **In `CodingKeys`, unlike `busy`**, and the distinction is the point: a
    /// dispatch that was in flight when the app quit is not in flight when it
    /// reopens, but a pane the operator made dense is still meant to be dense.
    /// Runtime state is dropped on save; settings are kept. The default value
    /// is what lets a layout written before this field existed decode as airy
    /// rather than fail.
    public var density: PaneDensity = .airy

    /// Each column's width in canvas points, by column name, for the
    /// columns the operator has resized. A column absent from this
    /// dictionary is laid out by `paneColumnWidth`'s even division of the
    /// space available; one present overrides it.
    ///
    /// **Keyed by name rather than by index**, because a query that returns
    /// the same columns in a different order — or one more of them — must
    /// not hand column 2's width to a different column. An index would
    /// silently do exactly that.
    ///
    /// **In `CodingKeys`, like `density` and unlike `busy`.** A width the
    /// operator dragged is a setting, not runtime state.
    public var columnWidths: [String: Double] = [:]

    /// What this pane is looking at, or `nil` for a pane nothing has
    /// queried yet.
    ///
    /// **In `CodingKeys`, like `density` and `columnWidths`.** A pane's
    /// subject is the most settled thing about it — it is what makes the
    /// pane that pane, what a re-query re-queries, and what routing means
    /// by "the same question". The rows it produced are NOT persisted and
    /// must not be: redrawing yesterday's result would show a database
    /// state that may no longer exist, the exact dishonesty `truncated`
    /// and the sort footer exist to prevent. On relaunch the pane re-runs
    /// this instead (`WindowModel.restorePaneContents`).
    public var fetch: PaneFetch?

    /// Where a **terminal** pane's shell was last opened — `nil` for a
    /// `"db"` pane, and `nil` for a terminal pane an older saved layout
    /// left with none (see `init(from:)`).
    ///
    /// **This is the fix for walk-defects B2.** `title` used to be the
    /// only trace of the path `term_open` opened at — `terminalPaneTitle
    /// (forPath:)` derives a display name from it and then the path
    /// itself was discarded — so a terminal pane restored after
    /// `clearForOrgSwitch` (every shell killed, deliberately) had a name
    /// but nowhere to reopen at. This is the pane's own memory of that
    /// path, set the same two places `title` already is
    /// (`resolveTerminalPane`): opened fresh, or updated when `term_open`
    /// names an existing pane and points it somewhere else.
    ///
    /// **In `CodingKeys`, like `density` and `columnWidths`.** A terminal
    /// pane's path is exactly the kind of setting those two are already
    /// arguing for: it is what makes a dead pane's Reopen control (walk-
    /// defects B2, `TerminalPane.swift`) know where to start the new shell
    /// rather than falling back to the active project's root every time.
    public var terminalPath: String?

    /// An **editor** pane's open files with cursor and scroll (3b-i) — `nil` for every other kind.
    /// **In `CodingKeys`**: which files were open is a setting, like `terminalPath`. Unsaved text and
    /// scratch tabs are never here (spec, Restore); `try?` for `fetch`'s reason.
    public var editorTabs: [EditorSavedTab]?

    /// An **editor** pane's left column (3b-ii) — `nil` for every other kind, and for an editor pane
    /// that has never had it set. **In `CodingKeys`**, and decoded with `try?` for `editorTabs`'s reason.
    public var editorColumn: EditorColumnState?

    /// A **browser** pane's tabs (3c-i) — `nil` for every other kind, and for a browser pane that has
    /// saved none. **In `CodingKeys`**, decoded with `try?` for `editorTabs`'s reason.
    public var browserTabs: [BrowserSavedTab]?

    /// A **browser** pane's selected tab id (3c-i). Same keeping and tolerance as `browserTabs`.
    public var browserActiveTab: String?

    /// A **browser** pane's groups (3d-i), in the order they were made — the pull-request group's
    /// `collapsed` among them, never its tabs. `nil` for a pane that saved none. **In `CodingKeys`**,
    /// decoded with `try?` as `browserTabs` is.
    public var browserGroups: [BrowserGroup]?

    /// A **browser** pane's tab column is hidden (3d-i, ruling 20) — per pane, so in the layout;
    /// `nil` means shown. Same keeping and tolerance as `browserTabs`.
    public var browserColumnHidden: Bool?

    /// Everything about a pane except `busy`. Omitting a key entirely is
    /// what makes the synthesized *encoder* skip it, and what makes a
    /// hand-rolled decoder unnecessary for `busy` — nothing ever asks the
    /// container for a key that is not here, so a file with no `"busy"` in
    /// it (every file, since this type never writes one) decodes exactly as
    /// a file that omitted it on purpose would. `density` *is* listed,
    /// because it must reach the file — see its own doc comment — which is
    /// exactly why `Pane` needs the custom `init(from:)` below: the
    /// synthesized decoder would treat a listed, non-optional key as
    /// required and reject a layout written before `density` existed,
    /// which is the one thing this field must not do.
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, frame, density, columnWidths, fetch, terminalPath, editorTabs, editorColumn
        case browserTabs, browserActiveTab, browserGroups, browserColumnHidden
    }

    public init(
        id: String, kind: String, title: String, frame: PaneFrame, busy: Bool = false,
        density: PaneDensity = .airy,
        columnWidths: [String: Double] = [:],
        fetch: PaneFetch? = nil,
        terminalPath: String? = nil,
        editorTabs: [EditorSavedTab]? = nil,
        editorColumn: EditorColumnState? = nil,
        browserTabs: [BrowserSavedTab]? = nil,
        browserActiveTab: String? = nil,
        browserGroups: [BrowserGroup]? = nil,
        browserColumnHidden: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.frame = frame
        self.busy = busy
        self.density = density
        self.columnWidths = columnWidths
        self.fetch = fetch
        self.terminalPath = terminalPath
        self.editorTabs = editorTabs
        self.editorColumn = editorColumn
        self.browserTabs = browserTabs
        self.browserActiveTab = browserActiveTab
        self.browserGroups = browserGroups
        self.browserColumnHidden = browserColumnHidden
    }

    /// Tolerant of a missing `density`, the same way `LayoutSnapshot`'s own
    /// `init(from:)` is tolerant of a missing `preMaximizeFrames` — both
    /// exist so that a field added after some layout was last saved
    /// decodes with its default rather than taking the whole file down.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        frame = try container.decode(PaneFrame.self, forKey: .frame)
        density = try container.decodeIfPresent(PaneDensity.self, forKey: .density) ?? .airy
        columnWidths = try container.decodeIfPresent([String: Double].self, forKey: .columnWidths) ?? [:]
        // `try?`, not `try`, and the difference matters. `decodeIfPresent`
        // tolerates a MISSING key but rethrows on a key that is present
        // and undecodable — which is exactly what a layout written by a
        // later build holding a subject case this one does not know would
        // be. Rethrowing there would take the whole layout file down over
        // one pane's subject, when the honest degradation is a pane that
        // comes back empty and waits for the operator. Same tolerance
        // `density` established, one step further.
        fetch = (try? container.decodeIfPresent(PaneFetch.self, forKey: .fetch)) ?? nil
        // A layout saved before this field existed has no `terminalPath`
        // key at all — `decodeIfPresent` tolerates that exactly like
        // `density`'s own missing-key case above — and `term_open`'s
        // Reopen path (walk-defects B2) already falls back to its own
        // default (the active project's root, else home) for a `nil`
        // here, so there is no second fallback to write.
        terminalPath = try container.decodeIfPresent(String.self, forKey: .terminalPath)
        editorTabs = (try? container.decodeIfPresent([EditorSavedTab].self, forKey: .editorTabs)) ?? nil
        editorColumn = (try? container.decodeIfPresent(EditorColumnState.self, forKey: .editorColumn)) ?? nil
        browserTabs = (try? container.decodeIfPresent([BrowserSavedTab].self, forKey: .browserTabs)) ?? nil
        browserActiveTab = (try? container.decodeIfPresent(String.self, forKey: .browserActiveTab)) ?? nil
        browserGroups = (try? container.decodeIfPresent([BrowserGroup].self, forKey: .browserGroups)) ?? nil
        browserColumnHidden = (try? container.decodeIfPresent(Bool.self, forKey: .browserColumnHidden)) ?? nil
    }
}

/// A 1-based line and column, columns counted in UTF-16 units as Monaco counts them. Lives here,
/// not in `Editor/`, because `Pane` keeps it (`Layout/` must not use `Editor/`).
public struct EditorPosition: Sendable, Equatable, Codable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// One file tab as a layout keeps it: where it was and how far it was scrolled (3b-i).
public struct EditorSavedTab: Sendable, Equatable, Codable {
    public var path: String
    public var cursor: EditorPosition
    public var scrollTop: Double
    public init(path: String, cursor: EditorPosition, scrollTop: Double) {
        self.path = path
        self.cursor = cursor
        self.scrollTop = scrollTop
    }
}

/// One browser tab as a layout keeps it (3c-i): which page, and the title it last showed. `Layout/`
/// may not use `Browser/`, so the type lives here beside `EditorSavedTab`.
public struct BrowserSavedTab: Codable, Sendable, Equatable {
    public var id: String
    public var url: String
    public var title: String
    /// The group it is in (3d-i): a `BrowserGroup.id`, nil when loose.
    public var group: String?
    /// The tab it was opened from, kept while it sits in that tab's group (ruling 8).
    public var opener: String?
    /// The entry in `pins/<project>.json` it is pinned as (ruling 3), nil when not pinned.
    public var pin: String?
    /// The operator took it out of a group: the site rule never groups it again (ruling 10).
    public var keptLoose: Bool

    public init(
        id: String, url: String, title: String, group: String? = nil, opener: String? = nil,
        pin: String? = nil, keptLoose: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.group = group
        self.opener = opener
        self.pin = pin
        self.keptLoose = keptLoose
    }

    private enum CodingKeys: String, CodingKey { case id, url, title, group, opener, pin, keptLoose }

    /// Tolerant of a 3c layout, which has none of the 3d-i fields: an absent `keptLoose` is false.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        opener = try c.decodeIfPresent(String.self, forKey: .opener)
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
        keptLoose = try c.decodeIfPresent(Bool.self, forKey: .keptLoose) ?? false
    }
}

/// What made a browser group (3d-i): the grouping rules (`automatic`), the operator (`own` — an
/// automatic group becomes one when the operator changes it, ruling 11), or the pull-request read
/// (`pullRequests`, id `pr`). **An unknown kind decodes as `.own`**: a layout from a later build keeps
/// its group, and the rules leave it alone.
public enum BrowserGroupKind: String, Codable, Sendable {
    case automatic, own, pullRequests

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BrowserGroupKind(rawValue: raw) ?? .own
    }
}

/// A browser group's swatch (3d-i, ruling 5): six, in this order, none green, violet, amber or red.
/// **An unknown colour decodes as `.blue`.**
public enum BrowserGroupColour: String, Codable, Sendable, CaseIterable {
    case blue, steel, teal, sand, stone, smoke

    /// `0xRRGGBB`.
    public var hex: UInt32 {
        switch self {
        case .blue: return 0x7f97b2
        case .steel: return 0x8d98a8
        case .teal: return 0x77a0a3
        case .sand: return 0xad9f86
        case .stone: return 0xa0938b
        case .smoke: return 0x9b9da6
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BrowserGroupColour(rawValue: raw) ?? .blue
    }
}

/// One group of tabs in a browser pane (3d-i). Lives here, not in `Browser/`, because the layout
/// saves it (ruling 2); the snapshot and the layout share the one type. A tab names its group by
/// `id` (`g<n>`, or `pr` for the pull-request group).
public struct BrowserGroup: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var colour: BrowserGroupColour
    public var collapsed: Bool
    /// The tab a collapsed group shows (ruling 21).
    public var lastOpen: String?
    public var kind: BrowserGroupKind
    /// The site key an automatic group gathers (ruling 9); nil for a group formed by opener.
    public var siteKey: String?
    /// The name is settled — by the model or the operator — and is never asked for again (ruling 12).
    public var named: Bool
    /// The entry in `pins/<project>.json` it is pinned as (ruling 3).
    public var pin: String?

    public init(
        id: String, name: String, colour: BrowserGroupColour, collapsed: Bool = false, lastOpen: String? = nil,
        kind: BrowserGroupKind, siteKey: String? = nil, named: Bool = false, pin: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colour = colour
        self.collapsed = collapsed
        self.lastOpen = lastOpen
        self.kind = kind
        self.siteKey = siteKey
        self.named = named
        self.pin = pin
    }

    private enum CodingKeys: String, CodingKey { case id, name, colour, collapsed, lastOpen, kind, siteKey, named, pin }

    /// Only `id` and `name` are required; every other field takes its default when absent.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colour = try c.decodeIfPresent(BrowserGroupColour.self, forKey: .colour) ?? .blue
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        lastOpen = try c.decodeIfPresent(String.self, forKey: .lastOpen)
        kind = try c.decodeIfPresent(BrowserGroupKind.self, forKey: .kind) ?? .own
        siteKey = try c.decodeIfPresent(String.self, forKey: .siteKey)
        named = try c.decodeIfPresent(Bool.self, forKey: .named) ?? false
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
    }
}

public enum EditorColumnView: String, Sendable, Equatable, Codable {
    case files, search, changes

    /// **An unknown view decodes as `.files`** (3b-iii, R1): a layout written by a later build keeps
    /// its column, and `LayoutSnapshot.editorColumnDefault` — decoded with `try` — does not take the
    /// whole file down with it.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EditorColumnView(rawValue: raw) ?? .files
    }
}

/// One row of the editor's Changes view (3b-iii): a file in one group of one root. `group` is a
/// `GitGroup` raw value, spelt out because `Layout/` may not use `Git/`.
public struct EditorChangesRow: Sendable, Equatable, Hashable, Codable {
    public var root: String
    public var path: String
    public var group: String
    public init(root: String, path: String, group: String) {
        self.root = root
        self.path = path
        self.group = group
    }
}

/// One group (staged, changed, untracked) of one root in the editor's Changes view (3a-ii).
public struct EditorChangesGroup: Sendable, Hashable {
    public var root: String
    public var group: String
    public init(root: String, group: String) {
        self.root = root
        self.group = group
    }
}

/// An editor pane's left column as a layout keeps it (3b-ii). `open` holds absolute paths.
public struct EditorColumnState: Sendable, Equatable, Codable {
    public var shown: Bool
    public var view: EditorColumnView
    public var width: Double
    public var open: [String]
    /// Roots collapsed in the Changes view (3b-iii): per pane, apart from `open` (Decision 37).
    public var changesClosed: Set<String>
    /// The Changes view's highlighted row; nil before one is chosen.
    public var changesHighlight: EditorChangesRow?
    /// Groups collapsed in the Changes view (3a-ii): the window's life, changed only by
    /// `editor_changes_group_collapse` / `_expand`, and never saved — not in `CodingKeys`.
    public var changesClosedGroups: Set<EditorChangesGroup> = []
    public static let initial = EditorColumnState(shown: false, view: .files, width: 240, open: [])
    public init(shown: Bool, view: EditorColumnView, width: Double, open: [String],
                changesClosed: Set<String> = [], changesHighlight: EditorChangesRow? = nil) {
        self.shown = shown
        self.view = view
        self.width = width
        self.open = open
        self.changesClosed = changesClosed
        self.changesHighlight = changesHighlight
    }

    private enum CodingKeys: String, CodingKey { case shown, view, width, open, changesClosed, changesHighlight }

    /// A column saved before 3b-iii has neither Changes field: they decode as empty, not as a failure.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shown = try c.decode(Bool.self, forKey: .shown)
        view = try c.decode(EditorColumnView.self, forKey: .view)
        width = try c.decode(Double.self, forKey: .width)
        open = try c.decode([String].self, forKey: .open)
        changesClosed = (try? c.decodeIfPresent(Set<String>.self, forKey: .changesClosed)) ?? []
        changesHighlight = (try? c.decodeIfPresent(EditorChangesRow.self, forKey: .changesHighlight)) ?? nil
    }
}

/// Where the canvas draws a pane: its frame, moved by a live drag only while
/// that frame is still the one the drag was measured from (#353).
///
/// The drop publishes the new frame while `commitDrag` is still awaiting, and
/// the view clears its offset only after that. Adding the offset to the new
/// frame for those few frames drew the pane past where it landed, by the
/// whole drag, and then it jumped back. Keyed to the starting frame, the
/// offset stops applying in the same render the new frame arrives in, however
/// long the commit takes — and a snap moves the pane once, from the release
/// point to where it snapped.
public func paneDrawOrigin(
    frame: PaneFrame, dragFrom: PaneFrame?, translation: (width: Double, height: Double)?
) -> (x: Double, y: Double) {
    guard let dragFrom, let translation, dragFrom == frame else { return (frame.x, frame.y) }
    return (frame.x + translation.width, frame.y + translation.height)
}

/// The pane a click at `(x, y)` lands in, in canvas points, or nil for none (3b-v PR 8).
///
/// **Top-most first, the way the canvas draws them**: the focused pane draws in front
/// (`zIndex` 1), then the rest in array order, a later one over an earlier one. A maximized
/// pane is no special case — it fills the void and holds focus, so it wins by that rule, and
/// once focus moves on the canvas draws the newly focused pane over it, as this does.
/// `panes` carry the frames as DRAWN, a live drag or resize included, because that is where
/// the pointer saw them.
///
/// `overLanding`: the Landing has replaced the canvas, and only the settings pane is drawn,
/// over it (`WakilWindow.settingsPaneOverlay`) — every other pane is in the layout and on no
/// screen, so a click can land in none of them.
///
/// Edges: the leading and top ones are in, the trailing and bottom ones out, so two snapped
/// panes sharing an edge never both claim the point on it.
public func paneAt(x: Double, y: Double, panes: [Pane], focusedId: String?, overLanding: Bool = false) -> String? {
    let drawn = overLanding ? panes.filter { $0.kind == Pane.settingsKind } : panes
    func holds(_ pane: Pane) -> Bool {
        x >= pane.frame.minX && x < pane.frame.maxX && y >= pane.frame.minY && y < pane.frame.maxY
    }
    if let focusedId, let focused = drawn.first(where: { $0.id == focusedId }), holds(focused) {
        return focusedId
    }
    return drawn.last(where: holds)?.id
}

/// Which pane a mouse-down asks to focus (`WindowModel.paneClicked`), or nil for none.
///
/// **A pane that is not focused is always asked**, wherever in it the click lands: a tree
/// row, a scroll view's background, a field. That is the whole of the 3b-v walk's defect —
/// the canvas used to hear only clicks SwiftUI's own tap could see, and AppKit-backed
/// controls (a `ScrollView`, a `Button`, a field) take the mouse-down before it does.
///
/// **The focused pane is asked only when the click lands outside a text input.** Asking it
/// is #284's focus request: the keyboard may be in the composer while `focusedId` stays,
/// and the click must bring it back. But a click on a field or an editor in the focused
/// pane puts the keyboard there by itself, and a request would have the pane re-take it
/// for its own container (`TerminalPane`, `GitPane`) — away from the field just clicked.
public func paneClickFocusTarget(target: String?, focusedId: String?, landsOnInput: Bool) -> String? {
    guard let target else { return nil }
    if target != focusedId { return target }
    return landsOnInput ? nil : target
}
