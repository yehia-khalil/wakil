import Foundation

/// Errors a layout action's handler throws for reasons of its own.
public enum LayoutActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingParam(action: String, param: String)
    case badParam(action: String, param: String, value: String)

    public var description: String {
        switch self {
        case .missingParam(let action, let param):
            return "\(action): missing required param \"\(param)\""
        case .badParam(let action, let param, let value):
            // `pane_open`'s `kind` is the one bad param whose message can
            // say what a good one looks like, and an agent that has just
            // been refused is exactly who needs to know.
            if action == "pane_open", param == "kind" {
                return "pane_open: param \"kind\" cannot be \"\(value)\" — this build draws "
                    + Pane.kinds.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                    + " and nothing else"
            }
            return "\(action): param \"\(param)\" cannot be \"\(value)\""
        }
    }
}

/// Registers the nine layout actions into `registry`, all `.control`.
///
/// **Why these are actions at all.** Invariant 2 says every pane is
/// dual-driven, and arranging panes is part of driving them: "put the
/// query results next to the terminal" is a thing to say out loud, and an
/// agent that cannot see or change geometry can only answer half of
/// "what's on screen?". Registering them is also what puts them in ⌘K for
/// free, since the palette is `registry.all()`.
///
/// **Why they are `.control` and carry no `targetEnvironmentParam`.**
/// Moving a pane changes Wakil and nothing else, so the write gate's
/// production rule must not apply — being pointed at a production database
/// is no reason to be unable to drag a window. And since no layout action
/// changes which environment is active, none of them can be an agent
/// walking into production, so none names a target for the gate to read.
///
/// **Commit granularity.** These take absolute positions and sizes, not
/// deltas, because a drag dispatches exactly once — on release, with the
/// final rect — while the pointer-down path updates SwiftUI state at frame
/// rate and dispatches nothing. A 400-frame drag therefore journals one
/// entry saying where the pane ended up, not four hundred saying it moved
/// a point. Without that rule either the journal is unreadable or there is
/// an `await` on the frame path, and §7's 8.33ms budget does not survive
/// the latter.
///
/// - Parameter panes: Where the closing pane's contents are dropped.
///   Optional, and `nil` in the tests here that exercise geometry alone —
///   a `LayoutStore` with no `PaneStore` beside it is a real configuration
///   (`--dispatch` builds both, but a test need not), and a pane that
///   closes with no contents store to tell has nothing to forget. Every
///   shipped assembly passes one: `WakilWiring.build` is the only place a
///   real registry is populated.
/// - Parameter unsavedEditorTabs: Asked by `pane_close`: the titles of the pane's unsaved editor
///   tabs, empty for any other pane. Layout does not know editors; the assembly (`App/`) does, and
///   passes the answer in. The default answers none, for geometry-only tests.
/// - Parameter openBrowserTab: `browser_new_tab`'s handler, which `pane_open` runs on a new browser
///   pane (3c-i), so it arrives with its first tab. Nil leaves a browser pane opened empty.
/// - Parameter openTerminal: `term_open`'s handler, which `pane_open` runs for a terminal (#1):
///   a terminal pane is its shell, and one opened bare drew "no shell" for good. Nil for
///   geometry-only tests, which open a bare terminal pane as before.
/// - Parameter terminals: Whose shell dies when the pane does. Optional
///   for the same reason `panes` is — a geometry-only test has no shell to
///   kill either — but every shipped assembly passes one: a closed pane
///   that held a shell must leave nothing running (Task 14).
public func registerLayoutActions(
    into registry: ActionRegistry, layout: LayoutStore, panes: PaneStore? = nil,
    terminals: TerminalStore? = nil,
    unsavedEditorTabs: @escaping @Sendable (String) async -> [String] = { _ in [] },
    openTerminal: (@Sendable (JSONValue) async throws -> JSONValue)? = nil,
    openBrowserTab: (@Sendable (JSONValue) async throws -> JSONValue)? = nil
) async {
    for action in layoutActions(
        layout: layout, panes: panes, terminals: terminals, unsavedEditorTabs: unsavedEditorTabs,
        openTerminal: openTerminal, openBrowserTab: openBrowserTab)
    {
        await registry.register(action)
    }
}

/// The nine layout actions themselves, built synchronously so
/// `WindowModel.forTesting` — itself synchronous, for the reason
/// `ActionRegistry.init`'s `initialActions:` doc comment gives — can hand
/// them to that parameter without ever needing an `await`.
/// `registerLayoutActions` above is the async, production shape: it
/// registers each one into a live registry, which is the only thing a real
/// assembly (`WakilWiring.build`) or a test with its own registry needs.
func layoutActions(
    layout: LayoutStore, panes: PaneStore? = nil, terminals: TerminalStore? = nil,
    unsavedEditorTabs: @escaping @Sendable (String) async -> [String] = { _ in [] },
    openTerminal: (@Sendable (JSONValue) async throws -> JSONValue)? = nil,
    openBrowserTab: (@Sendable (JSONValue) async throws -> JSONValue)? = nil
) -> [Action] {
    [
        // 2e (#198). ⌘, reaches the canvas through this and through
        // nothing else — Invariant 2 admits no second path to a state
        // change, and a menu item that opened a pane by touching
        // `LayoutStore` directly would be exactly that.
        //
        // **Operator-only, and it is the weakest member of that set by
        // design.** Opening a pane damages nothing and moves no boundary.
        // What it is here for is that every OTHER settings action — the
        // organisation's three strings, the browser login, the mint, the
        // unlink, the DSN — is operator-only on four separate reasons, and
        // an agent that could open the pane but drive none of it would be
        // holding a surface it cannot use. The refusal is journalled, so
        // the attempt is visible rather than silent.
        //
        // `.control`: nothing outside Wakil is touched, so `price` is
        // never consulted and this never reaches the gate's gating branch.
        Action(
            name: "settings_open",
            description: "Open the settings pane, or focus the one already open. There is at most "
                + "one: this returns the existing pane's id rather than opening a second. The pane "
                + "is never written to the layout file, so it is never restored by one. You may "
                + "READ it — read_pane answers for it and read_layout names it under overlay — but "
                + "you may not open or drive it; this call is refused for you and the refusal is "
                + "journalled. Ask the operator to press ⌘, instead.",
            kind: .control,
            audience: .operatorOnly,
            schema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in
                let result = await layout.openSettings()
                // Settings opens full screen, each time it opens or comes forward (3a-iii walk).
                try? await layout.maximize(id: result.pane.id)
                return .object([
                    "id": .string(result.pane.id),
                    // False means "you already had one, and it is now
                    // focused". A caller that cannot tell the two apart
                    // has to compare pane counts to find out, which races
                    // with every other dispatch.
                    "opened": .bool(result.opened),
                ])
            }
        ),

        Action(
            name: "pane_open",
            description: "Open a new pane of the given kind and focus it. Returns the new pane's id, "
                + "which is what every other pane-taking tool wants — not the title.",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array(Pane.kinds.sorted().map { .string($0) }),
                    ]),
                    "title": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("kind")]),
            ]),
            handler: { params in
                let kind = try requireString(params, "kind", action: "pane_open")
                // A kind nothing can draw is a pane that goes on the canvas
                // and then does nothing — and, worse, one that silently opts
                // out of every route keyed on kind. `queryTargetPane` is the
                // one that bit: it looks for `kind == "db"`, so three panes
                // opened as `"database"` left it finding none and falling
                // through to a key no pane holds. See `Pane.kinds`.
                guard Pane.kinds.contains(kind) else {
                    throw LayoutActionError.badParam(
                        action: "pane_open", param: "kind", value: kind)
                }
                // **The settings pane is not openable through here**, and
                // that is not a permission check — `pane_open` is
                // agent-reachable and stays so. It is that this action's
                // whole contract describes the other kinds: it cascades a
                // frame, takes a title, joins the snap graph, and produces
                // a pane the layout file will save. A settings pane is a
                // singleton, is titled by the product, and is stripped
                // from that file. `settings_open` is the one way in, and
                // it is operator-only.
                guard kind != Pane.settingsKind else {
                    throw LayoutActionError.badParam(
                        action: "pane_open", param: "kind", value: kind)
                }
                // **A terminal opens with its shell (#1).** `term_open` at its default path — the
                // project's root, else home — exactly as ⌘P and the Landing open one; a title the
                // caller gave replaces the one it takes from that path.
                if kind == "terminal", let openTerminal,
                   case .object(let opened) = try await openTerminal(.object([:])),
                   case .string(let id)? = opened["pane"]
                {
                    if let title = optionalString(params, "title") { await layout.retitle(id: id, to: title) }
                    return .object(["id": .string(id)])
                }
                let title = optionalString(params, "title") ?? Pane.defaultTitle(kind: kind)
                let pane = await layout.open(kind: kind, title: title)
                // **A browser opens with its first tab (3c-i)**, as a terminal opens with its shell:
                // `browser_new_tab` on the new pane — the start page, or a blank tab with the
                // address field focused.
                if kind == "browser", let openBrowserTab {
                    _ = try await openBrowserTab(.object(["pane": .string(pane.id)]))
                }
                return .object(["id": .string(pane.id)])
            }
        ),

        Action(
            name: "pane_close",
            description: "Close a pane, releasing any snapped edges it held. An editor pane with "
                + "unsaved tabs closes only with discard true; otherwise this answers which tabs "
                + "have unsaved edits.",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "discard": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ]),
            handler: { params in
                let id = try requireString(params, "id", action: "pane_close")
                // 3b-i Task 9: `editor_close`'s rule, for the whole pane. Unsaved work is never
                // dropped by a call that did not say so.
                let discard: Bool = { if case .object(let o) = params { o["discard"] == .bool(true) } else { false } }()
                if !discard {
                    let dirty = await unsavedEditorTabs(id)
                    if !dirty.isEmpty { throw PaneCloseError.unsavedEdits(pane: id, tabs: dirty) }
                }
                try await layout.close(id: id)
                // Contents go with the pane, and so does the shell. This used
                // to end at the dictionary removal below — which releases
                // rows and cannot release a file descriptor. A closed pane
                // must leave nothing running (Task 14).
                await terminals?.close(paneId: id)
                await panes?.drop(paneId: id)
                return .object([:])
            }
        ),

        Action(
            name: "pane_focus",
            description: "Make a pane the focused one.",
            kind: .control,
            audience: .agentReachable,
            schema: idOnlySchema,
            handler: { params in
                try await layout.focus(id: try requireString(params, "id", action: "pane_focus"))
                return .object([:])
            }
        ),

        Action(
            name: "pane_move",
            description: "Move a pane to an absolute position on the canvas, unsnapping every edge it held.",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("id"), .string("x"), .string("y")]),
            ]),
            handler: { params in
                try await layout.move(
                    id: try requireString(params, "id", action: "pane_move"),
                    x: try requireNumber(params, "x", action: "pane_move"),
                    y: try requireNumber(params, "y", action: "pane_move"))
                return .object([:])
            }
        ),

        Action(
            name: "pane_resize",
            description: "Resize a pane, dragging any coordinated shared border with it.",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "width": .object(["type": .string("number")]),
                    "height": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("id"), .string("width"), .string("height")]),
            ]),
            handler: { params in
                try await layout.resize(
                    id: try requireString(params, "id", action: "pane_resize"),
                    width: try requireNumber(params, "width", action: "pane_resize"),
                    height: try requireNumber(params, "height", action: "pane_resize"))
                return .object([:])
            }
        ),

        Action(
            name: "pane_snap",
            description:
                "Snap one of a pane's edges flush against another pane's opposite edge, matching its "
                + "extent, and coordinate the shared border. Omit toPaneId to snap to the canvas edge.",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "toPaneId": .object(["type": .string("string")]),
                    "edge": .object([
                        "type": .string("string"),
                        "enum": .array(SnapEdge.allCases.map { .string($0.rawValue) }),
                    ]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("id"), .string("edge")]),
            ]),
            handler: { params in
                let raw = try requireString(params, "edge", action: "pane_snap")
                guard let edge = SnapEdge(rawValue: raw) else {
                    throw LayoutActionError.badParam(action: "pane_snap", param: "edge", value: raw)
                }
                // `x`/`y` are the origin the pane was *released* at, which the
                // window sends because a drag never moves the stored frame —
                // see `LayoutStore.snap`. Both or neither: half an origin is a
                // caller error, not something to guess the other axis for.
                let x = optionalNumber(params, "x")
                let y = optionalNumber(params, "y")
                if (x == nil) != (y == nil) {
                    throw LayoutActionError.badParam(
                        action: "pane_snap", param: x == nil ? "x" : "y",
                        value: "absent — x and y must be given together")
                }
                try await layout.snap(
                    id: try requireString(params, "id", action: "pane_snap"),
                    to: optionalString(params, "toPaneId"),
                    edge: edge,
                    from: zip([x].compactMap { $0 }, [y].compactMap { $0 })
                        .map { (x: $0, y: $1) }.first)
                return .object([:])
            }
        ),

        Action(
            name: "pane_maximize",
            description: "Fill the canvas with one pane. pane_restore puts it back.",
            kind: .control,
            audience: .agentReachable,
            schema: idOnlySchema,
            handler: { params in
                try await layout.maximize(id: try requireString(params, "id", action: "pane_maximize"))
                return .object([:])
            }
        ),

        Action(
            name: "pane_restore",
            description: "Un-maximize whichever pane is filling the canvas. Does nothing if none is.",
            kind: .control,
            audience: .agentReachable,
            schema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in
                await layout.restore()
                return .object([:])
            }
        ),

        Action(
            name: "pane_set_density",
            description: "Set a pane's row density: \"airy\" (40pt rows) or \"dense\" (23pt).",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "density": .object([
                        "type": .string("string"),
                        "enum": .array([.string("airy"), .string("dense")]),
                    ]),
                ]),
                "required": .array([.string("id"), .string("density")]),
            ]),
            handler: { params in
                let id = try requireString(params, "id", action: "pane_set_density")
                let raw = try requireString(params, "density", action: "pane_set_density")
                guard let density = PaneDensity(rawValue: raw) else {
                    throw LayoutActionError.badParam(action: "pane_set_density", param: "density", value: raw)
                }
                try await layout.setDensity(density, id: id)
                return .object([:])
            }
        ),
    ]
}

private let idOnlySchema = JSONValue.object([
    "type": .string("object"),
    "properties": .object(["id": .object(["type": .string("string")])]),
    "required": .array([.string("id")]),
])

/// Reads a required string param, throwing rather than defaulting.
///
/// A default would turn a caller's typo into a silent no-op against some
/// other pane, which is precisely the class of bug the journal exists to
/// make visible.
func requireString(_ params: JSONValue, _ key: String, action: String) throws -> String {
    guard case .object(let object) = params, case .string(let value)? = object[key] else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    return value
}

private func requireNumber(_ params: JSONValue, _ key: String, action: String) throws -> Double {
    guard case .object(let object) = params, let value = object[key]?.doubleValue else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    return value
}

/// A number param that may be absent. Absent and non-numeric both read as
/// `nil`; the caller decides whether that is legal.
private func optionalNumber(_ params: JSONValue, _ key: String) -> Double? {
    guard case .object(let object) = params else { return nil }
    return object[key]?.doubleValue
}

func optionalString(_ params: JSONValue, _ key: String) -> String? {
    guard case .object(let object) = params, case .string(let value)? = object[key] else {
        return nil
    }
    return value
}

/// `pane_close` refused: an editor pane holds unsaved tabs and the call did not say `discard`.
enum PaneCloseError: Error, CustomStringConvertible {
    case unsavedEdits(pane: String, tabs: [String])

    var description: String {
        switch self {
        case .unsavedEdits(let pane, let tabs):
            "pane_close: \(pane) has unsaved edits in \(tabs.joined(separator: ", ")); save them, "
                + "or close with discard true to drop them"
        }
    }
}
