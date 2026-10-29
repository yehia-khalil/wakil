import Foundation
import Testing
@testable import WakilKit

/// A context client whose `keyboard` answers `keys`, recording every `set_keys` it is sent.
private actor KeysContext: ToolCaller {
    let keys: [String: String]
    private(set) var writes: [JSONValue] = []

    init(keys: [String: String] = [:]) { self.keys = keys }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "keyboard":
            return .object(["structuredContent": .object([
                "keys": .object(keys.mapValues { .string($0) }), "appError": .string(""),
            ])])
        case "set_keys":
            writes.append(arguments)
            return .object(["structuredContent": .object([:])])
        default:
            return .object(["structuredContent": .object([:])])
        }
    }
}

private func keyboardRegistry(_ context: KeysContext) async -> ActionRegistry {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("keyboard-\(UUID().uuidString)"),
        sessionId: "keyboard")
    await registerKeyboardActions(into: registry, context: context)
    return registry
}

/// A window over the layout and browser actions with a focused browser pane on `https://a.test/`,
/// its tabs horizontal (the defaults).
@MainActor
private func focusedBrowserWindow() async throws -> (WindowModel, String, LayoutStore) {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("keyboard-window-\(UUID().uuidString)"),
        sessionId: "keyboard-window")
    let panes = PaneStore()
    let layout = LayoutStore()
    let fileLists = EditorFileLists(files: FakeFiles())
    await registerLayoutActions(
        into: registry, layout: layout, panes: panes, unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: nil,
        context: ContextStore(client: GitRootsContext(roots: ["/p/api"])),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in EditorWindowLookup() },
        orgSwitcher: { _ in [] },
        rootWatcher: nil, editorRootWatcher: RecordingRootWatcher(), fileLists: fileLists, gitStatus: nil,
        paletteClients: PaletteClients(files: fileLists), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() },
        quickModelFactory: nil)
    await registerBrowserActions(into: registry, panes: panes, layout: layout, settings: { .defaults },
                                 orgFiles: { nil }, removeData: nil, pullRequests: { nil }, copyText: nil)
    await model.refreshContext()
    await model.dispatchFromSurface("browser_open", .object(["url": .string("https://a.test/")]))
    await model.refreshLayout()
    let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "browser" }?.id)
    await model.focusPane(id: pane)
    return (model, pane, layout)
}

@Suite struct KeyboardActionTests {
    @Test func testSetKeySendsWholeMapOnce() async throws {
        let context = KeysContext()
        let registry = await keyboardRegistry(context)
        let reply = try await registry.dispatch(
            name: "ctx_set_key", params: .object(["id": .string("editor.save"), "chord": .string("⌘P")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        let writes = await context.writes
        #expect(writes == [.object(["keys": .object([
            "editor.save": .string("⌘P"), "window.open": .string(""),
        ])])])
        #expect(reply == .object(["tookFrom": .string("window.open")]))
    }

    /// Unknown ids already on disk ride along in the whole map; a null chord clears.
    @Test func testSetKeyKeepsUnknownIdsAndClearsOnNull() async throws {
        let context = KeysContext(keys: ["future.command": "⌃⌘F"])
        let registry = await keyboardRegistry(context)
        let reply = try await registry.dispatch(
            name: "ctx_set_key", params: .object(["id": .string("pane.close"), "chord": .null]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await context.writes == [.object(["keys": .object([
            "future.command": .string("⌃⌘F"), "pane.close": .string(""),
        ])])])
        #expect(reply == .object(["tookFrom": .null]))
    }

    @Test func testSetKeyRefusesDecision50AndWritesNothing() async throws {
        let context = KeysContext()
        let registry = await keyboardRegistry(context)
        do {
            _ = try await registry.dispatch(
                name: "ctx_set_key", params: .object(["id": .string("editor.save"), "chord": .string("⌘Q")]),
                origin: .ui, caller: .test("staging"), confirmation: nil)
            Issue.record("⌘Q was taken")
        } catch {
            #expect("\(error)".contains("Decision 50"))
        }
        #expect(await context.writes.isEmpty)
    }

    @Test func testSetKeyIsOperatorOnly() async throws {
        let registry = await keyboardRegistry(KeysContext())
        let all = await registry.all()
        for name in ["ctx_set_key", "ctx_set_keys"] {
            let action = try #require(all.first { $0.name == name })
            #expect(action.audience == .operatorOnly && action.kind == .control)
            #expect(operatorOnlyActions.contains(name))
            guard case .deny(let reason) = permissionDecision(
                toolName: "mcp__wakil__\(name)", knownActions: all.map(\.name)) else {
                Issue.record("\(name) is not refused for the agent"); continue
            }
            #expect(reason.contains("only the operator"))
        }
    }

    @Test func testKeyboardIsAgentReadable() async throws {
        let registry = await keyboardRegistry(KeysContext(keys: ["pane.close": "⌃⌘W"]))
        let all = await registry.all()
        let read = try #require(all.first { $0.name == "ctx_keyboard" })
        #expect(read.audience == .agentReachable && read.kind == .read)
        #expect(permissionDecision(toolName: "mcp__wakil__ctx_keyboard", knownActions: all.map(\.name)) == .allow)
        let reply = try await registry.dispatch(
            name: "ctx_keyboard", params: .object([:]), origin: .agent, caller: .test("staging"), confirmation: nil)
        #expect(reply == .object(["structuredContent": .object([
            "keys": .object(["pane.close": .string("⌃⌘W")]), "appError": .string(""),
        ])]))
    }

    @Test func testSetKeysWritesTheMapItIsGiven() async throws {
        let context = KeysContext(keys: ["pane.close": "⌃⌘W"])
        let registry = await keyboardRegistry(context)
        _ = try await registry.dispatch(
            name: "ctx_set_keys", params: .object(["keys": .object([:])]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await context.writes == [.object(["keys": .object([:])])])
    }

    @Test @MainActor func testDeclinedPaneCommandFallsThrough() async throws {
        let (model, pane, layout) = try await focusedBrowserWindow()
        model.keymap = Keymap(overrides: ["window.toggleRail": "⌃⌘S"])
        let chord = try #require(KeyChord("⌃⌘S"))
        #expect(model.keymap.resolve(chord, paneKind: "browser") == ["browser.toggleTabColumn", "window.toggleRail"])
        #expect(model.railCollapsed == false)
        #expect(await model.keyPressed(chord))
        #expect(model.browser(pane)?.tabColumnHidden == false, "horizontal tabs: the browser declined")
        #expect(model.railCollapsed == true)
        #expect(await layout.reading().railCollapsed == true, "rail_set reached the layout")
        await model.shutdown()
    }

    /// The pane's command wins while its pane is focused (⌘T is New Tab there).
    @Test @MainActor func testPaneCommandWinsInItsPane() async throws {
        let (model, pane, _) = try await focusedBrowserWindow()
        #expect(model.browser(pane)?.tabs.count == 1)
        #expect(await model.keyPressed(try #require(KeyChord("⌘T"))))
        #expect(model.browser(pane)?.tabs.count == 2)
        await model.shutdown()
    }

    @Test @MainActor func testUnboundChordPassesOn() async throws {
        let (model, _, _) = try await focusedBrowserWindow()
        #expect(await !model.keyPressed(try #require(KeyChord("⌃⌘J"))))
        #expect(await !model.runKeyCommand("no.such.command"))
        await model.shutdown()
    }
}
