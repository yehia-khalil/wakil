import Foundation
import Testing
@testable import WakilKit

/// Final review I3: a project or conversation switch keeps each scope's dirty editor tabs in memory,
/// so quitting or switching organisation must ask about them too — not only the scope on screen.
/// Save writes hidden file tabs in place; a hidden scratch tab (or another project's file) is listed
/// with Don't Save and Cancel only, and the window never jumps to its scope (Rule 6).
@Suite @MainActor struct WindowModelUnsavedScopesTests {
    private struct Window {
        let model: WindowModel
        let panes: PaneStore
        let layout: LayoutStore
        let files: FakeFiles
    }

    private func window() async -> Window {
        let registry = ActionRegistry(
            journalDirectory: testScratchRoot.appendingPathComponent("unsaved-scopes-\(UUID().uuidString)"),
            sessionId: "unsaved-scopes")
        let panes = PaneStore()
        let layout = LayoutStore()
        let files = FakeFiles()
        await registerLayoutActions(
            into: registry, layout: layout, panes: panes, unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
        let model = WindowModel(
            registry: registry, panes: panes, layout: layout,
            context: ContextStore(client: GitRootsContext(roots: ["/p/api", "/p/portal"])),
            harnessFactory: { _, _ in nil }, resumes: ResumeBroker(),
            rootPath: "/tmp", providerId: "",
            lookupFactory: { _ in EditorWindowLookup() },
            rootWatcher: nil, editorRootWatcher: RecordingRootWatcher(), fileLists: nil, gitStatus: nil, paletteClients: PaletteClients(files: files))
        await registerEditorActions(
            into: registry, panes: panes, layout: layout, files: files, fileLists: nil,
            roots: { [weak model] in await model?.gitRootPaths ?? [] })
        await model.refreshContext()
        return Window(model: model, panes: panes, layout: layout, files: files)
    }

    /// Leaves the scope on screen for `scope`, as a project or conversation switch does: both
    /// stores keep the outgoing scope's contents.
    private func leave(_ w: Window, for scope: LayoutScope) async {
        await w.layout.switchScope(to: scope)
        await w.panes.switchScope(to: scope)
        await w.model.refreshLayout()
        await w.model.refreshPanes()
    }

    /// An editor pane with `/p/api/a.go` typed dirty ("b" over "a") and a dirty Untitled-1, then
    /// left for another conversation of the same project. Answers that conversation's scope.
    private func dirtyTabsLeftBehind(_ w: Window) async throws -> LayoutScope {
        await w.files.put("/p/api/a.go", "a")
        await w.model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await w.model.refreshLayout()
        let pane = try #require(w.model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await w.model.dispatchFromSurface("editor_new_scratch", .object(["pane": .string(pane)]))
        await w.model.refreshPanes()
        await w.model.editorBufferDidChange(pane: pane, tab: 0, text: "b", basis: 0)
        await w.model.editorBufferDidChange(pane: pane, tab: 1, text: "draft", basis: 0)
        let home = await w.panes.activeScope
        await leave(w, for: LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2"))
        #expect(w.model.layoutSnapshot.panes.isEmpty)
        return home
    }

    @Test func quitAsksAboutDirtyTabsInAScopeNotOnScreen() async throws {
        let w = await window()
        _ = try await dirtyTabsLeftBehind(w)
        #expect(await !w.model.requestQuit())
        #expect(w.model.unsavedPrompt == UnsavedPrompt(
            intent: .quit, files: ["a.go (another conversation)", "Untitled-1 (another conversation)"], canSave: false))
    }

    @Test func saveWritesOnlyTheTabsOnScreenAndReasksForTheHiddenOnes() async throws {
        let w = await window()
        let home = try await dirtyTabsLeftBehind(w)
        await w.files.put("/p/api/c.go", "c")
        await w.model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/c.go")]))
        await w.model.refreshLayout()
        let pane = try #require(w.model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await w.model.editorBufferDidChange(pane: pane, tab: 0, text: "d", basis: 0)
        #expect(await !w.model.requestQuit())
        #expect(w.model.unsavedPrompt?.canSave == true)
        await w.model.resolveUnsaved(.save)
        #expect(await w.files.text(of: "/p/api/c.go") == "d")
        // Invariant 2: a hidden tab is never written outside an action, and Rule 6: the window
        // never jumps to its scope to save it. Asked again, alone, with Save left out.
        #expect(await w.files.text(of: "/p/api/a.go") == "a")
        #expect(w.model.unsavedPrompt == UnsavedPrompt(
            intent: .quit, files: ["a.go (another conversation)", "Untitled-1 (another conversation)"], canSave: false))
        #expect(w.model.quitApproved == 0 && w.model.quitCancelled == 0)
        let a = await w.panes.updateEditor(in: home, paneId: "editor-1") { s in s.tabs.first }
        #expect(a?.dirty == true)
        await w.model.resolveUnsaved(.dontSave)
        #expect(w.model.unsavedPrompt == nil && w.model.quitApproved == 1)
    }

    @Test func aHiddenScratchAloneOffersNoSave() async throws {
        let w = await window()
        await w.model.newScratch()
        let pane = try #require(w.model.layoutSnapshot.focusedId)
        await w.model.editorBufferDidChange(pane: pane, tab: 0, text: "draft", basis: 0)
        let home = await w.panes.activeScope
        await leave(w, for: LayoutScope(organization: home.organization, project: "billing"))
        #expect(await !w.model.requestQuit())
        #expect(w.model.unsavedPrompt == UnsavedPrompt(intent: .quit, files: ["Untitled-1 (\(home.project))"],
                                                       canSave: false))
        await w.model.resolveUnsaved(.cancel)
        #expect(w.model.quitCancelled == 1)
    }

    @Test func anotherProjectsFileIsNamedByItsProjectAndSaveCannotReachIt() async throws {
        let w = await window()
        let home = await w.panes.activeScope
        await w.panes.switchScope(to: LayoutScope(organization: home.organization, project: "billing"))
        await w.panes.updateEditor(paneId: "editor-9", create: true) { s in
            var t = EditorTab.file(path: "/q/billing/confirm.go", root: "/q/billing", text: "x", mtime: 1, language: "go")
            t.text = "y"
            s.tabs = [t]; s.active = 0
        }
        await w.panes.switchScope(to: home)
        await w.model.requestOrganizationSwitch("beta")
        #expect(w.model.unsavedPrompt == UnsavedPrompt(
            intent: .switchOrganisation("beta"), files: ["confirm.go (billing)"], canSave: false))
        await w.model.resolveUnsaved(.cancel)
        #expect(await w.files.text(of: "/q/billing/confirm.go") == nil)
    }

    @Test func anOrgSwitchListsHiddenTabsAndDontSaveDropsThem() async throws {
        let w = await window()
        _ = try await dirtyTabsLeftBehind(w)
        await w.model.requestOrganizationSwitch("beta")
        #expect(w.model.unsavedPrompt?.files == ["a.go (another conversation)", "Untitled-1 (another conversation)"])
        await w.model.resolveUnsaved(.dontSave)
        #expect(w.model.unsavedPrompt == nil)
        #expect(await w.panes.editorDirtyTabsInHiddenScopes().isEmpty)
        #expect(await w.files.text(of: "/p/api/a.go") == "a")
    }
}
