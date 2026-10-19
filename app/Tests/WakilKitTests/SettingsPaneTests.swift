import Testing
import Foundation
@testable import WakilKit

/// **The settings pane: a singleton, never saved, readable by the agent
/// and drivable by nobody but the operator** (Decision 30, #198).
///
/// Everything pinned here is in `WakilKit`, which has a test target; the
/// drawn tree lives in `WakilApp`, which does not, and is the runbook's.
/// That split is itself one of the two arguments that made settings a pane
/// rather than a plane — a plane's state would be pinned only by a walk.

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func registryWithLayoutActions(_ layout: LayoutStore) async throws -> ActionRegistry {
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "settings")
    await registerLayoutActions(into: registry, layout: layout, panes: PaneStore(), terminals: nil)
    return registry
}

// MARK: - One pane, never two

/// ⌘, opens exactly one. Pressing it again focuses that pane rather than
/// littering the canvas with a second — and says which happened, so a
/// caller does not have to compare pane counts to find out.
@Test func settingsOpenOpensOnePaneAndThenFocusesIt() async throws {
    let layout = LayoutStore()
    let first = await layout.openSettings()
    #expect(first.opened)

    let second = await layout.openSettings()
    #expect(!second.opened, "the second open must report that it opened nothing")
    #expect(second.pane.id == first.pane.id)

    let panes = await layout.snapshot().panes
    #expect(panes.filter { $0.kind == Pane.settingsKind }.count == 1)
    #expect(await layout.snapshot().focusedId == first.pane.id, "the existing pane is focused, not ignored")
}

/// The singleton lives in the store rather than in the keystroke, so
/// `--dispatch` and a menu item get the same answer. Driven through the
/// action, which is the path ⌘, actually takes.
@Test func dispatchingSettingsOpenTwiceStillLeavesOnePane() async throws {
    let layout = LayoutStore()
    let registry = try await registryWithLayoutActions(layout)

    let first = try await registry.dispatch(
        name: "settings_open", params: .object([:]), origin: .ui,
        caller: .test("staging"), confirmation: nil)
    let second = try await registry.dispatch(
        name: "settings_open", params: .object([:]), origin: .ui,
        caller: .test("staging"), confirmation: nil)

    guard case .object(let firstFields) = first, case .object(let secondFields) = second else {
        Issue.record("settings_open must return an object"); return
    }
    #expect(firstFields["opened"] == .bool(true))
    #expect(secondFields["opened"] == .bool(false))
    #expect(firstFields["id"] == secondFields["id"])
    #expect(await layout.snapshot().panes.count == 1)
}

/// `pane_open` refuses this kind, and it is not a permission check —
/// `pane_open` is agent-reachable and stays so. Its whole contract
/// describes the other kinds: cascade a frame, take a title, join the snap
/// graph, be saved. `settings_open` is the one way in.
@Test func paneOpenRefusesTheSettingsKind() async throws {
    let layout = LayoutStore()
    let registry = try await registryWithLayoutActions(layout)

    await #expect(throws: (any Error).self) {
        try await registry.dispatch(
            name: "pane_open", params: .object(["kind": .string(Pane.settingsKind)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }
    #expect(await layout.snapshot().panes.isEmpty)
}

// MARK: - Never saved

/// **The pane is excluded from the layout file entirely.** Excluding
/// rather than handling is the point: the hole this closes is a layout
/// restoring a settings pane into a window with no organisation open,
/// where the pane has nothing to draw, and a file that never holds one
/// cannot restore one into anything.
@Test func aSavedLayoutNeverHoldsASettingsPane() async throws {
    let directory = try scratch()
    let persistence = LayoutPersistence(directory: directory)
    let scope = LayoutScope(organization: "acme", project: "orders", environment: "dev")

    let layout = LayoutStore()
    let db = await layout.open(kind: "db", title: "orders")
    _ = await layout.openSettings()

    try persistence.save(await layout.snapshot(), for: scope)
    let loaded = persistence.load(for: scope)

    guard let snapshot = loaded.snapshot else {
        Issue.record("expected a saved layout, got \(String(describing: loaded.note))"); return
    }
    #expect(snapshot.panes.map(\.id) == [db.id])
    #expect(!snapshot.panes.contains { $0.kind == Pane.settingsKind })
}

/// A canvas holding NOTHING but a settings pane is an empty canvas as far
/// as the layout file is concerned. The strip happens before the emptiness
/// guard, deliberately: writing it as a one-pane-strong seed would make
/// the next new conversation here open on a pane that cannot be restored.
@Test func aCanvasOfOnlyASettingsPaneSavesAsAnEmptyOne() async throws {
    let directory = try scratch()
    let persistence = LayoutPersistence(directory: directory)
    let scope = LayoutScope(organization: "acme", project: "orders", environment: "dev")

    let layout = LayoutStore()
    _ = await layout.openSettings()
    try persistence.save(await layout.snapshot(), for: scope)

    let loaded = persistence.load(for: scope)
    #expect(loaded.snapshot?.panes.isEmpty ?? true)
    #expect(loaded.snapshot?.focusedId == nil)
}

/// Stripped on the way IN as well as on the way out. This build is not the
/// only thing that writes these files — an operator hand-editing
/// configuration is the product, and a file written before this ruling
/// landed is already on disk.
@Test func aHandWrittenLayoutHoldingASettingsPaneDoesNotRestoreIt() async throws {
    let directory = try scratch()
    let persistence = LayoutPersistence(directory: directory)
    let scope = LayoutScope(organization: "acme", project: "orders", environment: "dev")

    // Written by hand, the way an operator or an older build would.
    var snapshot = LayoutSnapshot()
    let db = Pane(id: "db-1", kind: "db", title: "orders",
                  frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
    let settings = Pane(id: "settings-2", kind: Pane.settingsKind, title: "Settings",
                        frame: PaneFrame(x: 40, y: 40, width: 640, height: 420))
    snapshot.panes = [db, settings]
    snapshot.focusedId = settings.id
    snapshot.maximizedId = settings.id
    try persistence.writeUnstripped(snapshot, for: scope)

    let loaded = persistence.load(for: scope)
    guard let restored = loaded.snapshot else {
        Issue.record("expected a layout"); return
    }
    #expect(restored.panes.map(\.id) == ["db-1"])
    // The dangling references matter as much as the pane. A `maximizedId`
    // pointing at a pane that is not there leaves the canvas showing one
    // maximized pane that does not exist — an empty screen with no way
    // back.
    #expect(restored.maximizedId == nil)
    #expect(restored.focusedId == "db-1")
    // No note: a settings pane in a file is not a stale pane kind the
    // operator needs telling about. This build draws that kind perfectly
    // well; it just never restores one.
    #expect(loaded.note == nil, "\(String(describing: loaded.note))")
}

// MARK: - read_layout's overlay

/// **`overlay` is the ruling that lost the settings surface its case for
/// being a plane**, and it is a measurement rather than a preference: a
/// plane emits no key here at all, so an agent would read back a perfectly
/// normal layout while the canvas sat inert behind one.
@Test func readLayoutNamesTheSettingsPaneUnderOverlay() async throws {
    let layout = LayoutStore()
    _ = await layout.open(kind: "db", title: "orders")
    let settings = await layout.openSettings()

    let payload = layoutPayload(await layout.snapshot())
    guard case .object(let fields) = payload else {
        Issue.record("layout payload must be an object"); return
    }
    guard case .object(let overlay)? = fields["overlay"] else {
        Issue.record("overlay = \(String(describing: fields["overlay"]))"); return
    }
    #expect(overlay["settings"] == .string(settings.pane.id))

    // It is in `panes` too. It IS a pane on the canvas and Invariant 3
    // wants every pane observable; `overlay` says the second thing the
    // `panes` entry cannot — that it is an overlay, at most one, never
    // saved, and not drivable by the reader.
    guard case .array(let panes)? = fields["panes"] else {
        Issue.record("panes missing"); return
    }
    #expect(panes.count == 2)
}

/// `null`, not an absent key. An agent that cannot distinguish "no
/// overlay" from "this build does not report overlays" has to guess, and
/// the guess that matters is the wrong one.
@Test func readLayoutReportsOverlayNullWhenThereIsNoSettingsPane() async throws {
    let layout = LayoutStore()
    _ = await layout.open(kind: "db", title: "orders")

    let payload = layoutPayload(await layout.snapshot())
    guard case .object(let fields) = payload else {
        Issue.record("layout payload must be an object"); return
    }
    #expect(fields["overlay"] == .null, "\(String(describing: fields["overlay"]))")
}

// MARK: - Readable by the agent, drivable by the operator

/// The new asymmetry, stated as a test: the agent may READ settings and
/// drive nothing on it.
@Test func theAgentMayReadSettingsAndMayNotOpenThePane() async throws {
    #expect(operatorOnlyActions.contains("settings_open"))
    #expect(!operatorOnlyActions.contains("ctx_config_tree"),
            "reading the configuration is not refused; driving the pane is")

    let decision = permissionDecision(
        toolName: "mcp__wakil__settings_open",
        knownActions: ["settings_open", "ctx_config_tree"])
    guard case .deny(let reason) = decision else {
        Issue.record("settings_open must be denied, got \(decision)"); return
    }
    // The sentence says what the agent MAY do instead, not only what it
    // may not — the four-families rule `operatorOnlyDenialMessage`
    // already follows.
    #expect(reason.contains("read"))
    #expect(reason.contains("ctx_config_tree"))

    #expect(permissionDecision(
        toolName: "mcp__wakil__ctx_config_tree",
        knownActions: ["settings_open", "ctx_config_tree"]) == .allow)
}

/// A refused dispatch is journalled, so an attempt is visible rather than
/// silent. The refusal the agent actually meets is
/// `permissionDecision`'s — this is the second gate, for the case where
/// the CLI asks anyway.
@Test func anAgentsSettingsOpenIsJournalled() async throws {
    let layout = LayoutStore()
    let journal = try scratch()
    let registry = ActionRegistry(journalDirectory: journal, sessionId: "settings")
    await registerLayoutActions(into: registry, layout: layout, panes: PaneStore(), terminals: nil)

    _ = try await registry.dispatch(
        name: "settings_open", params: .object([:]), origin: .agent,
        caller: .test("staging"), confirmation: nil)

    let entries = try await registry.journalEntries()
    guard let entry = entries.first(where: { $0.action == "settings_open" }) else {
        Issue.record("settings_open left no journal entry: \(entries)"); return
    }
    #expect(entry.origin == .agent)
}

// MARK: - The decoder

/// Extracted and tested directly, which is this phase's standing rule for
/// a decoder. The tree is four levels of nested objects, and the
/// alternative — a hand-written walk in the view — has a silently empty
/// pane as its failure mode.
@Test func decodingAConfigTreeKeepsAllFourLevels() throws {
    let reply = JSONValue.object([
        "structuredContent": .object([
            "org": .object([
                "id": .string("acme"), "displayName": .string("Acme"),
                "jiraBase": .string("https://acme.atlassian.net"),
                "defaultProvider": .string("main"),
            ]),
            "providers": .array([
                .object([
                    "id": .string("main"), "kind": .string("claude-code"),
                    "label": .string("Main"), "configDir": .string("/home/.claude-main"),
                ]),
            ]),
            "projects": .array([
                .object([
                    "name": .string("orders"), "path": .string("/src/orders/project.json"),
                    "roots": .array([.object(["path": .string("/src/orders"), "role": .string("service")])]),
                    "environments": .array([
                        .object([
                            "name": .string("staging"),
                            "databases": .array([
                                .object([
                                    "name": .string("core"), "driver": .string("mysql"),
                                    "ref": .string("db:core"), "writable": .bool(false),
                                ]),
                            ]),
                            "api": .array([.object([
                                "name": .string("core"),
                                "baseUrl": .string("https://api.test"),
                                "authRef": .string("api:staging"),
                            ])]),
                        ]),
                    ]),
                ]),
            ]),
        ]),
    ])

    guard let tree = decodeSettingsTree(fromResult: reply) else {
        Issue.record("the tree did not decode"); return
    }
    #expect(tree.org.label == "Acme")
    #expect(tree.providers.map(\.id) == ["main"])
    // Four deep: tree → project → environment → databases.
    #expect(tree.projects[0].environments[0].databases[0].name == "core")
    // A LIST since 2c-iv, and the entry carries a NAME — which is what a
    // request records, so one request runs against staging and then
    // production.
    #expect(tree.projects[0].environments[0].api.count == 1)
    #expect(tree.projects[0].environments[0].api.first?.baseUrl == "https://api.test")
    #expect(!tree.hasResidue)
}

/// The three partiality lists are omitted by Go when empty, so a decoder
/// that treated an absent key as malformed would make the ordinary case —
/// a healthy organisation — the one that draws nothing.
@Test func aTreeWithNoResidueDecodesWithTheOmittedKeysEmpty() throws {
    let reply = JSONValue.object([
        "structuredContent": .object([
            "org": .object(["id": .string("empty")]),
            "providers": .array([]),
            "projects": .array([]),
        ]),
    ])
    guard let tree = decodeSettingsTree(fromResult: reply) else {
        Issue.record("the tree did not decode"); return
    }
    // An organisation with no display name falls back to its id — the
    // same rule the org picker follows, so the two name it the same way.
    #expect(tree.org.label == "empty")
    #expect(tree.misfiled.isEmpty && tree.unreadable.isEmpty && tree.providersSkipped.isEmpty)
    #expect(!tree.hasResidue)
}

/// Residue is carried, so the pane can say what it could not read. An
/// empty projects list beside a non-empty `unreadable` means "could not
/// look", never "there are none".
@Test func residueSurvivesTheDecodeAndIsVisible() throws {
    let reply = JSONValue.object([
        "structuredContent": .object([
            "org": .object(["id": .string("acme")]),
            "projects": .array([]),
            "unreadable": .array([.string("gone")]),
            "misfiled": .array([.object([
                "name": .string("elsewhere"), "path": .string("/p.json"),
                "filedUnder": .string("acme"), "declaredOrg": .string("other"),
            ])]),
        ]),
    ])
    guard let tree = decodeSettingsTree(fromResult: reply) else {
        Issue.record("the tree did not decode"); return
    }
    #expect(tree.projects.isEmpty)
    #expect(tree.unreadable == ["gone"])
    #expect(tree.misfiled.first?.declaredOrg == "other")
    #expect(tree.hasResidue, "the pane must be able to say it could not look")
}

/// **It refuses rather than passing a half-read tree on.** A decoder that
/// answered with an empty tree for a malformed reply would draw an
/// organisation with no projects — a sentence about the operator's machine
/// that may be false.
@Test func aReplyThatIsNotAConfigTreeDecodesToNil() throws {
    #expect(decodeSettingsTree(fromResult: nil) == nil)
    #expect(decodeSettingsTree(fromResult: .object([:])) == nil)
    #expect(decodeSettingsTree(fromResult: .object(["structuredContent": .object([:])])) == nil,
            "a structuredContent with no org is not a config tree")
    #expect(decodeSettingsTree(fromResult: .string("nope")) == nil)
}

// MARK: - Quick tasks and ghost-text (3b-viii)

/// The quick-tasks keys Go publishes: the org's quick provider, a local provider's URL and what it
/// serves, and the operator's ghost-text switch.
@Test func theQuickTaskKeysDecode() throws {
    let reply = JSONValue.object([
        "structuredContent": .object([
            "org": .object(["id": .string("initech"), "quickProvider": .string("qwen")]),
            "providers": .array([.object([
                "id": .string("qwen"), "kind": .string("local"),
                "baseURL": .string("http://127.0.0.1:8012"), "serves": .array([.string("infill")]),
            ])]),
            "projects": .array([]),
            "editor": .object(["ghostText": .bool(false)]),
        ]),
    ])
    let tree = try #require(decodeSettingsTree(fromResult: reply))
    #expect(tree.org.quickProvider == "qwen")
    #expect(tree.providers.first?.baseURL == "http://127.0.0.1:8012")
    #expect(tree.providers.first?.serves == ["infill"])
    #expect(tree.editor.ghostText == false)
}

/// An older `wakil-ctx` publishes none of them: no quick provider, no URL, serving nothing, and
/// ghost-text on.
@Test func absentQuickTaskKeysDecodeToTheirDefaults() throws {
    let reply = JSONValue.object([
        "structuredContent": .object([
            "org": .object(["id": .string("initech")]),
            "providers": .array([.object(["id": .string("main"), "kind": .string("claude-code")])]),
            "projects": .array([]),
            "editor": .object(["fontSize": .integer(13)]),
        ]),
    ])
    let tree = try #require(decodeSettingsTree(fromResult: reply))
    #expect(tree.org.quickProvider == "")
    #expect(tree.providers.first?.baseURL == "")
    #expect(tree.providers.first?.serves == [])
    #expect(tree.editor.ghostText == true)
    #expect(SettingsEditor.defaults.ghostText == true)
}
