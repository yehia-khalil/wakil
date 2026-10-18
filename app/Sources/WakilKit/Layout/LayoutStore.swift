import Foundation

/// What went wrong in a `LayoutStore` call.
public enum LayoutError: Error, Equatable, Sendable {
    /// No pane with that id exists in the active scope's arrangement.
    case unknownPane(String)
    /// The pane exists but holds no link on the edge the caller named.
    case notSnapped(String)
}

/// One `LayoutScope`'s whole arrangement, as a value.
///
/// This is what `snapshot()` returns, what `read_layout` projects, and what
/// `LayoutPersistence` writes. Being `Codable` and `Equatable` is what lets
/// a test assert a round trip and a restore in one expression.
public struct LayoutSnapshot: Sendable, Equatable, Codable {
    public var panes: [Pane]
    public var focusedId: String?
    public var maximizedId: String?
    public var graph: SnapGraph
    /// The frames `restore()` puts back, keyed by pane id.
    ///
    /// **Part of the snapshot, and therefore of what is saved**, rather
    /// than a side table on the actor. Maximizing sets a pane's frame to
    /// the whole canvas, so the rectangle it had before is the only record
    /// of where it actually lives; a saved layout that carried
    /// `maximizedId` without it would reopen with the pane filling the
    /// canvas and `restore()` unable to put it anywhere — the arrangement
    /// silently flattened to one pane's worth. Keeping it here also means
    /// `switchScope` and `load(_:for:)` carry it automatically, instead
    /// of a per-scope filter on the way out and a merge on the way back.
    public var preMaximizeFrames: [String: PaneFrame]
    /// What a new editor pane's column starts as (3b-ii): the last state the operator left any editor
    /// pane in, without its open folders. `nil` until one is set.
    public var editorColumnDefault: EditorColumnState?

    private enum CodingKeys: String, CodingKey {
        case panes, focusedId, maximizedId, graph, preMaximizeFrames, editorColumnDefault
    }

    public init(
        panes: [Pane] = [], focusedId: String? = nil, maximizedId: String? = nil,
        graph: SnapGraph = SnapGraph(), preMaximizeFrames: [String: PaneFrame] = [:],
        editorColumnDefault: EditorColumnState? = nil
    ) {
        self.panes = panes
        self.focusedId = focusedId
        self.maximizedId = maximizedId
        self.graph = graph
        self.preMaximizeFrames = preMaximizeFrames
        self.editorColumnDefault = editorColumnDefault
    }

    /// Tolerant of a missing `preMaximizeFrames`, which files written
    /// before it existed do not carry. The synthesized decoder would
    /// demand the key and reject the whole file — reporting a layout as
    /// corrupt because the app that wrote it was older is exactly the
    /// silent data loss `LayoutPersistence`'s note channel exists to avoid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panes = try container.decode([Pane].self, forKey: .panes)
        focusedId = try container.decodeIfPresent(String.self, forKey: .focusedId)
        maximizedId = try container.decodeIfPresent(String.self, forKey: .maximizedId)
        graph = try container.decode(SnapGraph.self, forKey: .graph)
        preMaximizeFrames =
            try container.decodeIfPresent([String: PaneFrame].self, forKey: .preMaximizeFrames) ?? [:]
        editorColumnDefault = try container.decodeIfPresent(EditorColumnState.self, forKey: .editorColumnDefault)
    }

    /// The same arrangement with every pane's transient `busy` flag
    /// cleared.
    ///
    /// `WindowModel` gates its layout write on this rather than on `==`.
    /// `busy` is set and cleared around every dispatch, so two snapshots
    /// differing only in it describe the same canvas — and a gate that
    /// could not tell the difference would rewrite the file whenever one
    /// pane's dispatch happened to observe another pane mid-flight.
    /// Normalising rather than hand-comparing the fields that do matter
    /// keeps it correct as `Pane` grows: a new field is compared unless it
    /// is deliberately cleared here.
    public var withoutTransientState: LayoutSnapshot {
        var copy = self
        for index in copy.panes.indices { copy.panes[index].busy = false }
        return copy
    }
}

/// Which pane a query's rows belong in, or `nil` for "a new one".
///
/// **Naming a pane means "this belongs in that pane"; naming none means
/// "this is a different question".** That is the whole rule, it needs no
/// parameter beyond the one that already existed, and it is what makes
/// the operator's flow work: *query A, add a filter, add a filter, sort*
/// is one subject being refined and names `db-1` every time, because the
/// agent has just read that id off the previous result; *query B* is a
/// different subject and names nothing.
///
/// **This inverts 2c-i's rule, which resolved an unnamed query to the
/// focused database pane.** Both defaults fail an agent that forgets, so
/// the choice is which failure is cheaper. A stray pane is closable and
/// costs nothing; a clobbered pane destroys the filter chain the operator
/// built, the subject as well as the rows. The likelihood runs the same
/// way — an agent refining has the id in hand, an agent starting fresh
/// does not.
///
/// **Wakil never infers which it is.** The neighbouring temptation was
/// refused during 2c-i's walk in the operator's own words: the
/// implementation must not parse the SQL and guess the table, because a
/// join names two tables and an aggregate names none usefully. Guessing
/// from a query string is that mistake in a different hat.
///
/// `layout` is unused now and kept only so callers need not change; an
/// explicit id does not depend on focus, and there is no non-explicit
/// answer left to look up.
public func queryTargetPane(explicit: String?, layout: LayoutSnapshot?) -> String? {
    guard let explicit, !explicit.isEmpty else { return nil }
    return explicit
}

/// Drops every pane whose `kind` this build cannot draw, and everything
/// that referred to it — snap links, focus, the maximized pane, its
/// pre-maximize frame — returning a note naming what went and why, or
/// `nil` when the layout was already clean.
///
/// **This is spec §4.3's "dropped with a note", finally checkable.**
/// `LayoutPersistence.load` declined to do it while `Pane.kind` had no
/// validity set to check against, and said so: the set "belongs to
/// whatever registers pane kinds". `Pane.kinds` is now that set, so the
/// check can be made honestly rather than by hardcoding `["db"]` inside
/// the persistence layer.
///
/// **A pane is dropped, not repaired.** There is no sensible kind to
/// substitute: the pane was opened to be a terminal, or an API client, or
/// something a later build had and this one does not, and drawing it as a
/// database pane would put a surface on the canvas that lies about what it
/// is. The note is what makes the loss visible rather than silent.
public func layoutDroppingUnknownPaneKinds(
    _ snapshot: LayoutSnapshot
) -> (snapshot: LayoutSnapshot, note: String?) {
    let unknown = snapshot.panes.filter { !Pane.kinds.contains($0.kind) }
    guard !unknown.isEmpty else { return (snapshot, nil) }

    var cleaned = snapshot
    let ids = Set(unknown.map(\.id))
    cleaned.panes.removeAll { ids.contains($0.id) }
    for id in ids {
        cleaned.graph.removeAll(for: id)
        cleaned.preMaximizeFrames.removeValue(forKey: id)
    }
    if let focused = cleaned.focusedId, ids.contains(focused) {
        cleaned.focusedId = cleaned.panes.last?.id
    }
    if let maximized = cleaned.maximizedId, ids.contains(maximized) {
        cleaned.maximizedId = nil
    }

    let described = unknown
        .map { "\"\($0.title)\" (kind \"\($0.kind)\")" }
        .joined(separator: ", ")
    let plural = unknown.count == 1 ? "pane" : "panes"
    return (cleaned, "dropped \(unknown.count) \(plural) this build cannot draw: \(described)")
}

/// `snapshot` with every saved Git pane turned into an editor pane showing Changes (3b-iii, Decision
/// 40): the Git pane folded into the editor, so the pane comes back as the editor on the same list.
///
/// **The first kind migration.** Every other kind this build does not know is still dropped with a
/// note (`layoutDroppingUnknownPaneKinds`), which runs after this. Same id and frame, so the snap
/// graph, focus and maximize still name the pane (R8). No tabs: a Git pane saved none, and diff tabs
/// are never saved (R7). The column takes the layout's default width.
public func layoutMigratingGitPanes(_ snapshot: LayoutSnapshot) -> LayoutSnapshot {
    var out = snapshot
    let width = snapshot.editorColumnDefault?.width ?? EditorColumnState.initial.width
    out.panes = snapshot.panes.map { p in
        guard p.kind == "git" else { return p }
        return Pane(id: p.id, kind: "editor", title: Pane.defaultTitle(kind: "editor"), frame: p.frame,
                    density: p.density, columnWidths: p.columnWidths,
                    editorColumn: EditorColumnState(shown: true, view: .changes, width: width, open: []))
    }
    return out
}

/// `snapshot` with every overlay pane removed — today, every settings
/// pane — together with any reference the rest of the snapshot held to
/// one.
///
/// **This is the whole of "the settings pane is excluded from the layout
/// file"** (Decision 30), and it is applied on BOTH sides of the file:
/// `LayoutPersistence` strips before it writes and strips again after it
/// reads. Writing alone would be enough for files this build produces and
/// not for the ones it does not — a file hand-edited by an operator, or
/// one written by a build where this ruling had not landed — and the pane
/// exists precisely so an operator can hand-edit configuration.
///
/// **Excluding rather than handling is the point.** The hole this closes
/// is a layout restoring a settings pane into a window that has no
/// organisation open, where the pane has nothing to draw; a pane the file
/// never holds cannot be restored into anything.
///
/// The dangling references matter as much as the pane. `focusedId` and
/// `maximizedId` pointing at a pane that is not in `panes` is a snapshot
/// that describes a canvas nothing can render — and `maximizedId` in
/// particular would leave the canvas showing one maximized pane that does
/// not exist, which is an empty screen with no way back.
public func layoutWithoutOverlayPanes(_ snapshot: LayoutSnapshot) -> LayoutSnapshot {
    let overlays = snapshot.panes.filter { $0.kind == Pane.settingsKind }
    guard !overlays.isEmpty else { return snapshot }

    var cleaned = snapshot
    let ids = Set(overlays.map(\.id))
    cleaned.panes.removeAll { ids.contains($0.id) }
    for id in ids {
        cleaned.graph.removeAll(for: id)
        cleaned.preMaximizeFrames.removeValue(forKey: id)
    }
    if let focused = cleaned.focusedId, ids.contains(focused) {
        cleaned.focusedId = cleaned.panes.last?.id
    }
    if let maximized = cleaned.maximizedId, ids.contains(maximized) {
        cleaned.maximizedId = nil
    }
    return cleaned
}

/// Where the panes are, per `LayoutScope`.
///
/// An actor, for the reason `PaneStore` is one: a drag commit from the
/// window and a `pane_snap` from an in-flight agent turn arrive on
/// different tasks and must not race.
///
/// **It holds every visited scope's arrangement, not just the active
/// one.** `design-language.md` §13 requires that panes are "never torn
/// down and rebuilt on switch" and that state is kept warm, so a switch
/// swaps which `LayoutSnapshot` is active and discards nothing. Coming
/// back to a scope finds it as it was left.
///
/// **Contents are not here** — `PaneStore` holds those. See `Pane`'s doc
/// comment for why the two are separate.
public actor LayoutStore {
    /// The canvas a pane is placed and maximized into, until the window
    /// reports its real size via `setVoid`. A fixed default rather than an
    /// optional so that `LayoutStore()` in a test behaves exactly as it
    /// does in the app, with no display involved.
    public static let defaultVoid = PaneFrame(x: 0, y: 0, width: 1440, height: 900)

    private var void: PaneFrame
    /// The scope on screen: what `switchScope` installs.
    private var screen: LayoutScope
    /// The scope every implicit-current-scope method below reads and writes: the dispatching
    /// caller's own (`ScopeRouting.home`, background agents 3 of 4), else the one on screen. An
    /// agent working in a place the operator has left arranges that place's canvas, not this one.
    private var scope: LayoutScope { ScopeRouting.home ?? screen }
    private var byScope: [LayoutScope: LayoutSnapshot]
    private var nextPaneNumber: Int

    /// How many times anything has asked for a pane to be focused, counting
    /// the requests that named the pane already focused.
    ///
    /// **Here because this is where the two channels meet (#284, Invariant
    /// 2).** `focus(id:)` is reached by the operator's rail click and `⌘K`
    /// — through `dispatchLayout("pane_focus")` — and by the agent's own
    /// `pane_focus`, through the same registry action. A counter raised in
    /// `WindowModel.focusPane` instead was raised on two of those three and
    /// not the agent's, so a pane took the keyboard back when the operator
    /// asked and did not when the agent did. UI controls and the agent
    /// dispatch the same actions; this is what makes the *effect* the same
    /// too.
    ///
    /// **Not in `LayoutSnapshot`**, which is persisted and served by
    /// `read_layout`: a counter in it would be written into every saved
    /// arrangement and would make a `parity` check's two channels disagree
    /// by construction. It describes something that happened, not an
    /// arrangement.
    ///
    /// **Not in `byScope` either**, so no scope's arrangement carries it.
    /// Nothing reads its value — a view reacts to it DIFFERING from the last
    /// one it saw — so a reset to zero is a difference, and a switch would
    /// end by pulling first responder into a pane nobody asked for.
    private var focusRequests: Int

    public init(voidSize: PaneFrame = LayoutStore.defaultVoid) {
        void = voidSize
        screen = .initial
        byScope = [.initial: LayoutSnapshot()]
        nextPaneNumber = 1
        focusRequests = 0
    }

    // MARK: - Reading

    /// The active scope's current arrangement — every pane, which is
    /// focused, which is maximized, and the snap graph between them.
    ///
    /// Falls back to an empty snapshot rather than force-unwrapping:
    /// `byScope` is seeded with `LayoutScope.initial` in `init`, so this
    /// only matters after `switchScope` is given a scope that has somehow
    /// been evicted, which cannot happen today but costs nothing to guard
    /// against.
    public func snapshot() -> LayoutSnapshot {
        byScope[scope] ?? LayoutSnapshot()
    }

    /// The arrangement AND the focus-request count, in one hop.
    ///
    /// **One call because the two always travel together**, everywhere the
    /// window re-reads the store: the snapshot says which pane is focused
    /// and the count says whether anything just asked for one, and a view
    /// deciding whether a request was for it needs both to be of the same
    /// moment. Two `await`s would let a `pane_focus` land between them and
    /// hand the window a count from after a snapshot from before — the pane
    /// named by the old `focusedId` would answer a request meant for the new
    /// one.
    public func reading() -> LayoutReading {
        LayoutReading(snapshot: snapshot(), focusRequests: focusRequests)
    }

    /// Records that an operator asked for the keyboard where it already is.
    ///
    /// **The canvas click, and the one focus request that moves nothing
    /// (#284).** `WindowModel.paneClicked` refuses to dispatch `pane_focus`
    /// for the pane that already holds focus, because every dispatch
    /// journals and a click is the most repeated gesture there is. But the
    /// keyboard may not be in that pane — typing to the agent is what takes
    /// it away without touching `focusedId` — so the click still has to be
    /// answerable. This raises the count without a dispatch, a journal entry
    /// or a change to the arrangement.
    public func noteFocusRequest() {
        focusRequests += 1
    }

    /// Tells the store how big the canvas is. Called by the window on
    /// resize; a maximized pane follows.
    public func setVoid(_ frame: PaneFrame) {
        void = frame
        guard var current = byScope[scope], let maximizedId = current.maximizedId else { return }
        guard let index = current.panes.firstIndex(where: { $0.id == maximizedId }) else { return }
        current.panes[index].frame = frame
        byScope[scope] = current
    }

    // MARK: - Panes

    /// Opens a new pane, focuses it, and returns it.
    ///
    /// Ids are `"<kind>-<n>"` with `n` counting up across the whole store,
    /// not per scope — an id is a handle an agent may hold across a
    /// context switch, and reusing `db-1` in a second scope would make
    /// two different panes answer to one name in one journal.
    ///
    /// `terminalPath` is `Pane.terminalPath` verbatim — `nil` for every
    /// `"db"` pane, and for a `"terminal"` one it is `resolveTerminalPane`'s
    /// own `path`, threaded through so the pane remembers where its shell
    /// was opened (walk-defects B2) rather than only the title derived
    /// from it.
    @discardableResult
    public func open(kind: String, title: String, terminalPath: String? = nil) -> Pane {
        var current = snapshot()
        let id = "\(kind)-\(nextPaneNumber)"
        nextPaneNumber += 1

        // Cascade from the last pane rather than stacking exactly, so a
        // second pane is visible instead of hidden behind the first. §12's
        // open question 3 records that this is a placeholder for whatever
        // the full-working-day density test says.
        let offset = Double(current.panes.count % 8) * 28
        let pane = Pane(
            id: id, kind: kind, title: title,
            frame: PaneFrame(x: 60 + offset, y: 60 + offset, width: 640, height: 420),
            terminalPath: terminalPath)

        current.panes.append(pane)
        current.focusedId = id
        byScope[scope] = current
        return pane
    }

    /// Opens the settings pane, or focuses the one already open.
    ///
    /// **⌘, opens exactly one** (Decision 30), and this is where that is
    /// true rather than in the command that calls it: a singleton enforced
    /// at the keystroke would be a singleton per keystroke, and
    /// `settings_open` is dispatchable from `--dispatch` and from a menu
    /// item alike. `opened` is false when an existing pane was focused, so
    /// a caller can tell "opened one" from "you already had one" without
    /// comparing pane counts.
    ///
    /// **It focuses rather than doing nothing.** Pressing ⌘, while a
    /// settings pane sits behind three others and having nothing happen
    /// reads as a broken shortcut. `focus` also recovers a pane dragged
    /// outside the void, which is the other way a settings pane can be
    /// open and invisible.
    ///
    /// Nothing else may open one: `pane_open` refuses this kind outright
    /// (`LayoutActions`), because its contract — cascade a frame, take a
    /// title, join the snap graph, be saved — describes the other two
    /// kinds and not this one.
    public func openSettings() -> (pane: Pane, opened: Bool) {
        if let existing = snapshot().panes.first(where: { $0.kind == Pane.settingsKind }) {
            try? focus(id: existing.id)
            // Re-read: `focus` can move the pane back inside the void, and
            // the caller is handed what is now on the canvas.
            let refreshed = snapshot().panes.first { $0.id == existing.id } ?? existing
            return (refreshed, false)
        }
        return (open(kind: Pane.settingsKind, title: "Settings"), true)
    }

    /// Renames an existing pane to the subject it is now showing.
    ///
    /// **2c-ii-b walk defect D3, and it is 2c-i's complaint still standing.**
    /// `title` used to be written once, by `open` above, and never again —
    /// so a pane born from a Mongo collection and then pointed at a SQL
    /// table by the query line kept drawing `DOCS` over `events` rows
    /// forever, and the rail listed it under that name too. `DBPane`'s own
    /// doc comment records 2c-i's walk raising exactly this — *"a pane
    /// titled EVENTS showing customer rows has a lying title"* — and the fix
    /// then was to add the query line beneath the title. That made the
    /// second line true and left the first one lying, one line above it.
    ///
    /// **Not a guess at a better name.** The title written here is the same
    /// value the pane would have been born with had the current subject
    /// opened it — `resolvePane`'s caller computes it once, for both paths.
    /// Wakil still never parses SQL to infer a table (`queryTargetPane`'s
    /// own comment refuses that, in the operator's words, because a join
    /// names two and an aggregate names none usefully).
    ///
    /// Silent when the pane is gone: `resolvePane` reaches this before the
    /// dispatch that would refuse an unknown pane, and a rename is not the
    /// place to raise that error a second time.
    public func retitle(id: String, to title: String) {
        guard var current = byScope[scope],
            let index = current.panes.firstIndex(where: { $0.id == id }),
            current.panes[index].title != title
        else { return }
        current.panes[index].title = title
        byScope[scope] = current
    }

    /// Records where a terminal pane's shell was last opened —
    /// `retitle`'s own analogue for `Pane.terminalPath` (walk-defects B2),
    /// called alongside it from `resolveTerminalPane` so a `term_open`
    /// that names an existing pane and points it somewhere else updates
    /// both facts about it together.
    ///
    /// Silent on an unknown id, matching `retitle`: a pane closed between
    /// `term_open` resolving it and this call is an ordinary race, not an
    /// error worth failing a dispatch over.
    public func setTerminalPath(id: String, to path: String) {
        guard var current = byScope[scope],
            let index = current.panes.firstIndex(where: { $0.id == id }),
            current.panes[index].terminalPath != path
        else { return }
        current.panes[index].terminalPath = path
        byScope[scope] = current
    }

    /// The editor pane `id`'s saved tabs (3b-i). A no-op when unchanged, so the window does not
    /// persist a layout for a cursor report that moved nothing.
    public func setEditorTabs(id: String, to tabs: [EditorSavedTab]) {
        guard var current = byScope[scope],
            let index = current.panes.firstIndex(where: { $0.id == id }),
            current.panes[index].editorTabs != tabs
        else { return }
        current.panes[index].editorTabs = tabs
        byScope[scope] = current
    }

    public func editorTabs(id: String) -> [EditorSavedTab]? {
        byScope[scope]?.panes.first(where: { $0.id == id })?.editorTabs
    }

    /// The editor pane `id`'s column (3b-ii), and the window's default for a new pane: what the
    /// operator last left any editor pane in, without its open folders. A no-op when unchanged.
    /// `asDefault` false keeps the default as it is: a restore puts back a column, it does not leave one.
    public func setEditorColumn(id: String, to column: EditorColumnState, asDefault: Bool = true) {
        guard var current = byScope[scope],
            let index = current.panes.firstIndex(where: { $0.id == id })
        else { return }
        let fallback = asDefault
            ? EditorColumnState(shown: column.shown, view: column.view, width: column.width, open: [])
            : current.editorColumnDefault
        guard current.panes[index].editorColumn != column || current.editorColumnDefault != fallback else { return }
        current.panes[index].editorColumn = column
        current.editorColumnDefault = fallback
        byScope[scope] = current
    }

    public func editorColumn(id: String) -> EditorColumnState? {
        byScope[scope]?.panes.first(where: { $0.id == id })?.editorColumn
    }

    public func editorColumnDefault() -> EditorColumnState {
        byScope[scope]?.editorColumnDefault ?? .initial
    }

    /// Closes a pane: drops it, drops every link it held, and refocuses the
    /// pane that was last in the list — or clears focus entirely if that
    /// was the last pane. A pane held back by `maximize` for restoring is
    /// forgotten too, since there is nothing left to restore it onto.
    public func close(id: String) throws {
        var current = try requirePane(id)
        current.panes.removeAll { $0.id == id }
        current.graph.removeAll(for: id)
        if current.focusedId == id { current.focusedId = current.panes.last?.id }
        if current.maximizedId == id { current.maximizedId = nil }
        current.preMaximizeFrames[id] = nil
        byScope[scope] = current
    }

    /// Makes `id` the focused pane. Focus is otherwise only ever moved as a
    /// side effect — of `open` and of `maximize` — so this is the one call
    /// a click on an unfocused pane dispatches.
    public func focus(id: String) throws {
        var current = try requirePane(id)
        current.focusedId = id
        // **Raised before the pane is even known to exist? No — after.**
        // `requirePane` throws for an unknown id, and a refused focus is not
        // a request anything should answer: a view that took the keyboard on
        // one would be reacting to an action that did not happen.
        //
        // **Nor for a canvas that is not on screen** (Rule 6): an agent focusing a pane in a
        // place the operator has left moves that place's focus and never takes the keyboard.
        if scope == screen { focusRequests += 1 }

        // Focusing also *recovers*. A pane can be outside the void without
        // `move` having put it there — a layout saved on a large canvas and
        // restored on a small one, or a window the operator shrank — and
        // the rail is the only handle such a pane has left. Raising its
        // z-order would find it in the sense of "it is now in front of
        // nothing you can see". So a focus pulls it back to the nearest
        // position that shows a grabbable slice, which is what
        // `WakilWindow`'s canvas comment promises the rail does.
        //
        // A pane already inside is untouched: `boundedOrigin` returns its
        // own origin, so an ordinary focus moves nothing.
        if let index = current.panes.firstIndex(where: { $0.id == id }) {
            let frame = current.panes[index].frame
            let bounded = boundedOrigin(x: frame.x, y: frame.y, size: frame)
            current.panes[index].frame.x = bounded.x
            current.panes[index].frame.y = bounded.y
        }

        byScope[scope] = current
    }

    /// Sets the busy hint the rail reads while a dispatched action naming
    /// this pane is in flight, per `Pane.busy`'s doc comment.
    ///
    /// An unknown id is ignored rather than throwing. This is set from a
    /// dispatch completion handler, not from user intent, and by the time
    /// the dispatch resolves the pane it named may already have been
    /// closed — an ordinary race, not an error worth surfacing.
    public func setBusy(_ busy: Bool, id: String) {
        guard var current = byScope[scope],
              let index = current.panes.firstIndex(where: { $0.id == id })
        else { return }
        current.panes[index].busy = busy
        byScope[scope] = current
    }

    /// Sets one column's width on pane `id`, or does nothing if no such
    /// pane is open.
    ///
    /// Silent on an unknown id, matching `setBusy`: a pane closed between a
    /// drag starting and finishing is an ordinary race, not an error worth
    /// failing a dispatch over.
    public func setColumnWidth(id: String, column: String, width: Double) {
        guard var current = byScope[scope],
              let index = current.panes.firstIndex(where: { $0.id == id })
        else { return }
        current.panes[index].columnWidths[column] = width
        byScope[scope] = current
    }

    /// Records what pane `id` is looking at, or does nothing if no such
    /// pane is open.
    ///
    /// Silent on an unknown id, matching `setColumnWidth` and `setBusy`: a
    /// pane closed between a query being sent and its rows arriving is an
    /// ordinary race, not an error worth failing a dispatch over — and the
    /// rows have already been fetched by then, so failing would change
    /// nothing except the journal.
    public func setFetch(_ fetch: PaneFetch?, id: String) {
        guard var current = byScope[scope],
              let index = current.panes.firstIndex(where: { $0.id == id })
        else { return }
        current.panes[index].fetch = fetch
        byScope[scope] = current
    }

    /// What pane `id` is looking at, or `nil` for an unknown pane or one
    /// nothing has queried.
    public func fetch(id: String) -> PaneFetch? {
        byScope[scope]?.panes.first(where: { $0.id == id })?.fetch
    }

    /// Sets one pane's row density (§8's toggle). Throws on an unknown id,
    /// like every other id-taking method here — unlike `setBusy`, which is
    /// driven by the dispatch machinery itself rather than by a caller
    /// naming a pane, so a race against a closed pane is ordinary there and
    /// an error here.
    public func setDensity(_ density: PaneDensity, id: String) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }
        current.panes[index].density = density
        byScope[scope] = current
    }

    // MARK: - Geometry

    /// Moves a pane to an absolute origin, and **unlinks every edge it
    /// held**.
    ///
    /// Absolute rather than a delta because §8's `--dispatch` scripts must
    /// be able to state an outcome, and because a drag dispatches once on
    /// release (spec §4.1) with the final position rather than a stream of
    /// increments.
    ///
    /// The unlink is what makes "pulling a pane away returns it to
    /// free-floating" true. A move that kept its links would leave a pane
    /// coordinating a border it is no longer touching.
    public func move(id: String, x: Double, y: Double) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }
        let bounded = boundedOrigin(
            x: x, y: y, size: current.panes[index].frame)
        current.panes[index].frame.x = bounded.x
        current.panes[index].frame.y = bounded.y
        current.graph.removeAll(for: id)
        byScope[scope] = current
    }

    /// `origin` moved the least distance that leaves a grabbable slice of a
    /// pane of `size` inside the void.
    ///
    /// **Why a pane may not be moved entirely off the canvas.** The canvas
    /// clips, so a pane pushed past an edge simply vanishes; and a pane
    /// with nothing on screen has nothing to press, so the pointer can
    /// never get it back. `WakilWindow`'s canvas comment claims the rail is
    /// what "makes a pane that has gone off the edge findable again", and
    /// `focus` now makes that true — but *findable* is a recovery, and a
    /// layout that cannot lose a pane in the first place is better than one
    /// that can and offers a remedy.
    ///
    /// A pane may still hang off an edge; what it may not do is leave less
    /// than `Pane.minimumWidth` × `Pane.minimumHeight` showing. That is the
    /// same figure the resize floor uses, and it is deliberately the *whole*
    /// pane's minimum rather than a title-bar strip, because in 2b-i every
    /// part of a pane is draggable.
    ///
    /// This binds the agent too. `pane_move` from an agent is clamped
    /// exactly as a drag is: a pane the operator can neither see nor reach
    /// is not an arrangement, and an agent that puts one there has not
    /// rearranged the workspace, it has hidden part of it.
    private func boundedOrigin(x: Double, y: Double, size: PaneFrame) -> (x: Double, y: Double) {
        let minVisibleX = Swift.min(Pane.minimumWidth, size.width)
        let minVisibleY = Swift.min(Pane.minimumHeight, size.height)
        return (
            x: Swift.min(Swift.max(x, void.minX + minVisibleX - size.width), void.maxX - minVisibleX),
            y: Swift.min(Swift.max(y, void.minY + minVisibleY - size.height), void.maxY - minVisibleY)
        )
    }

    /// Resizes a pane, dragging any coordinated neighbour's shared border
    /// with it so that snapped panes never gap or overlap.
    ///
    /// **The named pane's own frame is never clamped here** — a
    /// `--dispatch` script is entitled to state any rectangle for the
    /// pane it named, per the note on `resizeGesture` in `WakilWindow`.
    /// **A propagated neighbour is different: no caller ever asked for
    /// it to shrink at all**, let alone past usability, so its width and
    /// height are floored at `Pane.minimumWidth`/`minimumHeight` — the
    /// same floors the view clamps the dragged pane to — rather than
    /// left to go to zero or negative, persist that way, and be reported
    /// to the agent as a pane with no usable size.
    public func resize(id: String, width: Double, height: Double) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }

        let before = current.panes[index].frame
        current.panes[index].frame.width = width
        current.panes[index].frame.height = height
        let after = current.panes[index].frame

        // A neighbour on the right rides the moved border: its left edge
        // follows, and it absorbs the difference so its own far edge stays
        // put — unless that would take it below the floor, in which case
        // its width is floored instead and its far edge moves. Same
        // below, vertically.
        for neighbourId in current.graph.neighbours(of: id, along: .right) {
            guard let n = current.panes.firstIndex(where: { $0.id == neighbourId }) else { continue }
            let delta = after.maxX - before.maxX
            current.panes[n].frame.x += delta
            current.panes[n].frame.width = max(Pane.minimumWidth, current.panes[n].frame.width - delta)
        }
        for neighbourId in current.graph.neighbours(of: id, along: .bottom) {
            guard let n = current.panes.firstIndex(where: { $0.id == neighbourId }) else { continue }
            let delta = after.maxY - before.maxY
            current.panes[n].frame.y += delta
            current.panes[n].frame.height = max(Pane.minimumHeight, current.panes[n].frame.height - delta)
        }

        byScope[scope] = current
    }

    /// Snaps `id` flush against `otherPaneId`'s opposite edge — or against
    /// the void's own `edge` when `otherPaneId` is `nil` — and records the
    /// link.
    ///
    /// `edge` names the *dragged* pane's edge. Snapping b's `.left` to a
    /// puts b to the right of a.
    public func snap(
        id: String, to otherPaneId: String?, edge: SnapEdge,
        from released: (x: Double, y: Double)? = nil
    ) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }

        var neighbourFrame: PaneFrame?
        if let otherPaneId {
            guard let other = current.panes.first(where: { $0.id == otherPaneId }) else {
                throw LayoutError.unknownPane(otherPaneId)
            }
            neighbourFrame = other.frame
        }

        // The frame the snap is computed *from*. A drag commits on release,
        // and until that moment the movement lives in the view's own state
        // — `panes[index].frame` is still where the pane was when the drag
        // began. Flushing from that stale origin is what made a snap land
        // somewhere the preview never showed: `candidate(forDragging:to:)`
        // builds its proposal from the released origin, so the two
        // disagreed by exactly the drag distance. A caller that names no
        // origin (an agent dispatching `pane_snap`, which means "snap this
        // pane from wherever it is") keeps the stored frame.
        var base = current.panes[index].frame
        if let released {
            base.x = released.x
            base.y = released.y
        }

        let target = neighbourFrame.map { edgeValue($0, edge.opposite) } ?? edgeValue(void, edge)
        current.panes[index].frame = flush(
            base, edge: edge, to: target, matching: neighbourFrame)

        current.graph.unlink(id, edge)
        if let otherPaneId { current.graph.link(id, edge, to: otherPaneId) }
        byScope[scope] = current
    }

    /// Maximizes `id` into the void, remembering its frame so `restore` can
    /// put it back.
    ///
    /// Maximizing while another pane is already maximized restores that
    /// one first, so only ever one frame is being held back at a time —
    /// there is exactly one `maximizedId` per scope, so there could
    /// never be two frames to restore anyway.
    ///
    /// Maximizing an already-maximized `id` is a no-op. Without this
    /// guard, a second call would overwrite `preMaximizeFrames[id]` with
    /// `void` — the frame the first call already set — destroying the
    /// pane's true original geometry and making `restore()` put it back
    /// at the void's size instead. `pane_maximize` is a dispatchable
    /// action (Task 8), and an agent sending it twice must not corrupt
    /// state that a single call handles correctly.
    public func maximize(id: String) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }
        guard current.maximizedId != id else { return }

        if let previous = current.maximizedId,
           let previousIndex = current.panes.firstIndex(where: { $0.id == previous }),
           let frame = current.preMaximizeFrames[previous] {
            current.panes[previousIndex].frame = frame
            current.preMaximizeFrames[previous] = nil
        }

        current.preMaximizeFrames[id] = current.panes[index].frame
        current.panes[index].frame = void
        current.maximizedId = id
        current.focusedId = id
        byScope[scope] = current
    }

    /// Puts the maximized pane back to the frame it held before
    /// `maximize`, and clears `maximizedId`. A no-op when nothing is
    /// maximized — `restore` is the safe default a window can call
    /// without first checking whether there is anything to restore.
    public func restore() {
        guard var current = byScope[scope], let id = current.maximizedId else { return }
        if let index = current.panes.firstIndex(where: { $0.id == id }), let frame = current.preMaximizeFrames[id] {
            current.panes[index].frame = frame
        }
        current.preMaximizeFrames[id] = nil
        current.maximizedId = nil
        byScope[scope] = current
    }

    /// The snap the view should preview while `id` is being dragged to
    /// `origin`, or `nil` for none.
    ///
    /// Read-only: previewing must not commit. The dragged pane is excluded
    /// from its own neighbour list, or every drag would snap to where the
    /// pane already was.
    public func candidate(
        forDragging id: String, to origin: (x: Double, y: Double)
    ) -> SnapCandidate? {
        let current = snapshot()
        guard let pane = current.panes.first(where: { $0.id == id }) else { return nil }
        var proposed = pane.frame
        proposed.x = origin.x
        proposed.y = origin.y
        let neighbours = current.panes
            .filter { $0.id != id }
            .map { (id: $0.id, frame: $0.frame) }
        return snapCandidate(for: proposed, neighbours: neighbours, void: void)
    }

    // MARK: - Scopes

    /// Makes `scope` the active arrangement, keeping the outgoing one.
    public func switchScope(to scope: LayoutScope) {
        screen = scope
        if byScope[scope] == nil { byScope[scope] = LayoutSnapshot() }
    }

    /// Makes `scope` the active arrangement, MOVING `outgoing`'s into it (re-walk finding #4):
    /// a conversation minted over the canvas on screen takes that canvas as it is. `outgoing` is
    /// left empty, so one pane is never filed under two scopes in memory.
    public func switchScope(to scope: LayoutScope, adoptingFrom outgoing: LayoutScope) {
        let carried = byScope[outgoing] ?? LayoutSnapshot()
        byScope[outgoing] = nil
        byScope[scope] = carried
        screen = scope
    }

    /// Puts `pane` into the current scope's arrangement exactly as it is:
    /// same id, same frame.
    ///
    /// **For a pane that belongs to the window rather than to an
    /// arrangement**, which today is the settings pane: it is never saved in
    /// a layout, so a scope switch would otherwise drop it. Carrying it
    /// across, rather than reopening it, is what keeps the view the same view,
    /// so nothing on screen closes, redraws or moves. Refuses (returns false)
    /// when the incoming arrangement already holds that id, so a caller can
    /// fall back rather than overwrite a pane.
    @discardableResult
    public func carry(_ pane: Pane) -> Bool {
        var current = snapshot()
        guard !current.panes.contains(where: { $0.id == pane.id }) else { return false }
        current.panes.append(pane)
        byScope[scope] = current
        if let suffix = pane.id.split(separator: "-").last, let n = Int(suffix) {
            nextPaneNumber = max(nextPaneNumber, n + 1)
        }
        return true
    }

    /// Replaces `scope`'s arrangement wholesale — what
    /// `WindowModel` calls after `LayoutPersistence` reads one off disk.
    ///
    /// Wholesale includes `preMaximizeFrames`, which is why that lives on
    /// `LayoutSnapshot`: a restored layout whose pane is maximized comes
    /// back knowing where to put it again.
    public func load(_ snapshot: LayoutSnapshot, for scope: LayoutScope) {
        byScope[scope] = snapshot
        // Keep ids unique against whatever was restored: a persisted
        // `db-7` must not be handed out again this session.
        for pane in snapshot.panes {
            guard let suffix = pane.id.split(separator: "-").last, let n = Int(suffix) else { continue }
            nextPaneNumber = max(nextPaneNumber, n + 1)
        }
    }

    // MARK: - Private

    private func requirePane(_ id: String) throws -> LayoutSnapshot {
        let current = snapshot()
        guard current.panes.contains(where: { $0.id == id }) else {
            throw LayoutError.unknownPane(id)
        }
        return current
    }
}


/// One read of the store: the arrangement, and how many focus requests have
/// been made by the moment it was taken.
///
/// **A type rather than a tuple, and rather than two calls.** The two values
/// are only meaningful together — see `LayoutStore.reading()` — and a pair of
/// `await`s could interleave a `pane_focus` between them.
public struct LayoutReading: Sendable {
    public let snapshot: LayoutSnapshot
    public let focusRequests: Int

    public init(snapshot: LayoutSnapshot, focusRequests: Int) {
        self.snapshot = snapshot
        self.focusRequests = focusRequests
    }
}
