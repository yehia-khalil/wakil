import Foundation
import Testing
@testable import WakilKit

/// A context client whose `keyboard` answers `keys`, recording every `set_keys` it is sent.
private actor KeysContext: ToolCaller {
    let keys: [String: String]
    /// settings.json's error as `keyboard` answers it; "" when it reads.
    private(set) var appError: String
    private(set) var writes: [JSONValue] = []

    init(keys: [String: String] = [:], appError: String = "") {
        self.keys = keys
        self.appError = appError
    }

    /// The file fixed by hand: `keyboard` reads it again.
    func fix() { appError = "" }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        switch name {
        case "keyboard":
            return .object(["structuredContent": .object([
                "keys": .object(keys.mapValues { .string($0) }), "appError": .string(appError),
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
private func focusedBrowserWindow(keys: KeysContext = KeysContext()) async throws -> (WindowModel, String, LayoutStore) {
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
    await registerKeyboardActions(into: registry, context: keys)
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

    /// `""` clears the chord; unknown ids already on disk ride along in the whole map.
    @Test func testSetKeyEmptyChordClearsAndKeepsUnknownIds() async throws {
        let context = KeysContext(keys: ["future.command": "⌃⌘F"])
        let registry = await keyboardRegistry(context)
        let reply = try await registry.dispatch(
            name: "ctx_set_key", params: .object(["id": .string("pane.close"), "chord": .string("")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await context.writes == [.object(["keys": .object([
            "future.command": .string("⌃⌘F"), "pane.close": .string(""),
        ])])])
        #expect(reply == .object(["tookFrom": .null]))
    }

    /// null restores the default: the command's override goes, every other entry stays.
    @Test func testSetKeyNullRestoresTheDefault() async throws {
        let context = KeysContext(keys: ["future.command": "⌃⌘F", "pane.close": "", "editor.save": "⌃⌘S"])
        let registry = await keyboardRegistry(context)
        let reply = try await registry.dispatch(
            name: "ctx_set_key", params: .object(["id": .string("pane.close"), "chord": .null]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await context.writes == [.object(["keys": .object([
            "future.command": .string("⌃⌘F"), "editor.save": .string("⌃⌘S"),
        ])])])
        #expect(reply == .object(["tookFrom": .null]))
    }

    /// null runs `assign` with the default: a command that took the default meanwhile loses it,
    /// and the reply names it, as a recorded chord's would.
    @Test func testSetKeyNullTakesTheDefaultBack() async throws {
        let context = KeysContext(keys: ["editor.save": "⌃⌘S", "conversation.new": "⌘S"])
        let registry = await keyboardRegistry(context)
        let reply = try await registry.dispatch(
            name: "ctx_set_key", params: .object(["id": .string("editor.save"), "chord": .null]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await context.writes == [.object(["keys": .object(["conversation.new": .string("")])])])
        #expect(reply == .object(["tookFrom": .string("conversation.new")]))
    }

    /// An absent chord is a missing param, not a restore; an unknown id writes nothing.
    @Test func testSetKeyNeedsAChordAndAKnownId() async throws {
        let context = KeysContext()
        let registry = await keyboardRegistry(context)
        await #expect(throws: StandardActionError.missingParam(action: "ctx_set_key", param: "chord")) {
            _ = try await registry.dispatch(
                name: "ctx_set_key", params: .object(["id": .string("pane.close")]),
                origin: .ui, caller: .test("staging"), confirmation: nil)
        }
        await #expect(throws: StandardActionError.self) {
            _ = try await registry.dispatch(
                name: "ctx_set_key", params: .object(["id": .string("no.such"), "chord": .null]),
                origin: .ui, caller: .test("staging"), confirmation: nil)
        }
        #expect(await context.writes.isEmpty)
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

    /// Restore All sends `{}`: every known override goes, and an id this build doesn't know survives.
    @Test func testSetKeysKeepsUnknownIds() async throws {
        let context = KeysContext(keys: ["pane.close": "⌃⌘W", "future.command": "⌃⌘F"])
        let registry = await keyboardRegistry(context)
        _ = try await registry.dispatch(
            name: "ctx_set_keys", params: .object(["keys": .object([:])]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        #expect(await context.writes == [.object(["keys": .object(["future.command": .string("⌃⌘F")])])])
    }

    /// A Decision 50 chord or a malformed one for a known id is refused, and nothing is written.
    @Test func testSetKeysRefusesDecision50AndMalformedChords() async throws {
        let context = KeysContext()
        let registry = await keyboardRegistry(context)
        for (chord, sentence) in [("⌘Q", "Decision 50"), ("⌘⌘R", "is not a shortcut")] {
            do {
                _ = try await registry.dispatch(
                    name: "ctx_set_keys", params: .object(["keys": .object(["editor.save": .string(chord)])]),
                    origin: .ui, caller: .test("staging"), confirmation: nil)
                Issue.record("\(chord) was written")
            } catch {
                #expect("\(error)".contains(sentence))
            }
        }
        #expect(await context.writes.isEmpty)
    }

    /// The window's three changes reach `ctx_set_key` as a chord, `""` and null.
    @Test @MainActor func testSetKeySendsEachChange() async throws {
        let keys = KeysContext(keys: ["pane.close": "⌃⌘W"])
        let (model, _, _) = try await focusedBrowserWindow(keys: keys)
        #expect(await model.setKey("editor.save", .chord(try #require(KeyChord("⌘P")))) == .took("window.open"))
        #expect(await model.setKey("editor.save", .clear) == .took(nil))
        #expect(await model.setKey("pane.close", .restoreDefault) == .took(nil))
        #expect(await model.setKey("editor.save", .chord(try #require(KeyChord("⌘Q"))))
            == .refused(KeyChord.refusedReason))
        let writes = await keys.writes
        #expect(writes == [
            .object(["keys": .object(["pane.close": .string("⌃⌘W"), "editor.save": .string("⌘P"), "window.open": .string("")])]),
            .object(["keys": .object(["pane.close": .string("⌃⌘W"), "editor.save": .string("")])]),
            .object(["keys": .object([:])]),
        ])
        #expect(model.keymap.chord("pane.close") == KeyChord("⌃⌘W"), "re-read after each change")
        await model.shutdown()
    }

    /// A settings.json fixed by hand clears the error at the next settings refresh (opening
    /// Settings, or any write there), with no relaunch: the keymap is read again with the tree.
    @Test @MainActor func testSettingsRefreshReadsTheKeymapAgain() async throws {
        let keys = KeysContext(keys: ["editor.save": "⌃⌘J"], appError: "settings.json: unexpected end of JSON input")
        let (model, _, _) = try await focusedBrowserWindow(keys: keys)
        await model.refreshKeymap()
        #expect(model.keymapError == "settings.json: unexpected end of JSON input")
        #expect(model.keymap.chord("editor.save") == KeyChord("⌘S"), "the defaults while it can't be read")
        await keys.fix()
        await model.refreshSettings()
        #expect(model.keymapError == nil)
        #expect(model.keymap.chord("editor.save") == KeyChord("⌃⌘J"))
        await model.shutdown()
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

    /// Amendment 2026-10-30: ⇧⌘H is Home — the organisation's home, through `session_new` as ⌘N.
    @Test @MainActor func testHomeIsAKeyCommandAndItsChordIsFree() async throws {
        let (model, _, _) = try await focusedBrowserWindow()
        #expect(await model.runKeyCommand("window.home"))
        #expect(Keymap(overrides: [:]).resolve(try #require(KeyChord("⇧⌘H")), paneKind: "browser") == ["window.home"])
        await model.shutdown()
    }

    @Test @MainActor func testUnboundChordPassesOn() async throws {
        let (model, _, _) = try await focusedBrowserWindow()
        #expect(await !model.keyPressed(try #require(KeyChord("⌃⌘J"))))
        #expect(await !model.runKeyCommand("no.such.command"))
        await model.shutdown()
    }
}
