import Foundation
import Testing
@testable import WakilKit

/// Task 9: unsaved edits are never dropped silently. Closing a dirty tab, closing a pane with
/// dirty tabs, switching organisation and quitting each ask Save / Don't Save / Cancel first.
@Suite @MainActor struct WindowModelUnsavedTests {
    private let aGo = EditorTabSubject.file(path: "/p/api/a.go", root: "/p/api")

    /// An editor pane holding `/p/api/a.go` ("a" on disk), focused, its buffer typed to "b".
    private func dirtyFileWindow() async throws -> (WindowModel, FakeFiles, String) {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.focusPane(id: pane)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "b", basis: 0)
        return (model, files, pane)
    }

    @Test func closingADirtyTabAsksAndDontSaveDiscards() async throws {
        let (model, files, pane) = try await dirtyFileWindow()
        await model.closeFocusedTabOrPane()
        #expect(model.unsavedPrompt == UnsavedPrompt(intent: .closeTab(pane: pane, subject: aGo), files: ["a.go"]))
        #expect(model.editor(pane)?.tabs.count == 1)
        await model.resolveUnsaved(.dontSave)
        #expect(model.unsavedPrompt == nil && model.editor(pane)?.tabs.isEmpty == true)
        #expect(await files.text(of: "/p/api/a.go") == "a")
    }

    @Test func saveWritesThenCloses() async throws {
        let (model, files, pane) = try await dirtyFileWindow()
        await model.closeFocusedTabOrPane()
        #expect(model.unsavedPrompt == UnsavedPrompt(intent: .closeTab(pane: pane, subject: aGo), files: ["a.go"]))
        await model.resolveUnsaved(.save)
        #expect(model.unsavedPrompt == nil && model.editor(pane)?.tabs.isEmpty == true)
        #expect(await files.text(of: "/p/api/a.go") == "b")
    }

    @Test func aFailedSaveKeepsTheTab() async throws {
        let (model, files, pane) = try await dirtyFileWindow()
        await files.setWriteError("disk full")
        await model.closeFocusedTabOrPane()
        await model.resolveUnsaved(.save)
        let tab = try #require(model.editor(pane)?.tabs.first)
        #expect(tab.dirty && tab.text == "b")
        #expect(await files.text(of: "/p/api/a.go") == "a")
    }

    @Test func cancelKeepsEverything() async throws {
        let (model, files, pane) = try await dirtyFileWindow()
        await model.closeFocusedTabOrPane()
        #expect(model.unsavedPrompt != nil)
        await model.resolveUnsaved(.cancel)
        #expect(model.unsavedPrompt == nil)
        let tab = try #require(model.editor(pane)?.tabs.first)
        #expect(tab.dirty && tab.text == "b")
        #expect(await files.text(of: "/p/api/a.go") == "a")
    }

    @Test func closingAPaneWithDirtyTabsListsThemOnce() async throws {
        let (model, files, pane) = try await dirtyFileWindow()
        await files.put("/p/api/b.go", "b")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/b.go"), "pane": .string(pane)]))
        await model.refreshPanes()
        #expect(model.editor(pane)?.tabs.count == 2)
        await model.editorBufferDidChange(pane: pane, tab: 1, text: "bb", basis: 0)
        #expect(await !model.closePane(id: pane))
        #expect(model.unsavedPrompt == UnsavedPrompt(intent: .closePane(pane: pane), files: ["a.go", "b.go"]))
        #expect(model.layoutSnapshot.panes.contains { $0.id == pane })
        await model.resolveUnsaved(.dontSave)
        #expect(model.unsavedPrompt == nil)
        #expect(!model.layoutSnapshot.panes.contains { $0.id == pane })
        #expect(await files.text(of: "/p/api/a.go") == "a")
    }

    @Test func closingAPaneWithNothingUnsavedClosesAtOnce() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        #expect(await model.closePane(id: pane))
        #expect(model.unsavedPrompt == nil && model.layoutSnapshot.panes.isEmpty)
    }

    @Test func aDirtyScratchTabIsNamedAndAnEmptyOneIsNot() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        #expect(model.editor(pane)?.tabs.count == 2)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "select 1", basis: 0)
        await model.closePane(id: pane)
        #expect(model.unsavedPrompt == UnsavedPrompt(intent: .closePane(pane: pane), files: ["Untitled-1"]))
    }

    @Test func savingADirtyScratchTabAsksForItsPathAndClosesNothing() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "select 1", basis: 0)
        await model.closePane(id: pane)
        await model.resolveUnsaved(.save)
        #expect(model.unsavedPrompt == nil && model.editorSaveAsRequest == pane)
        #expect(model.editor(pane)?.tabs.first?.dirty == true)
    }

    /// The fake context answers `acme` whatever the window switched to, so the switch is read
    /// from what it does: it tears the outgoing organisation's panes down.
    @Test func switchingOrganisationWithDirtyTabsAsksFirst() async throws {
        let (model, _, pane) = try await dirtyFileWindow()
        await model.requestOrganizationSwitch("beta")
        #expect(model.unsavedPrompt == UnsavedPrompt(intent: .switchOrganisation("beta"), files: ["a.go"]))
        #expect(model.editor(pane)?.tabs.first?.dirty == true && !model.switching)
        await model.resolveUnsaved(.dontSave)
        #expect(model.unsavedPrompt == nil)
        #expect(model.layoutSnapshot.panes.isEmpty && model.editor(pane) == nil)
    }

    @Test func cancellingAnOrganisationSwitchStaysPut() async throws {
        let (model, _, pane) = try await dirtyFileWindow()
        await model.requestOrganizationSwitch("beta")
        await model.resolveUnsaved(.cancel)
        #expect(model.layoutSnapshot.panes.contains { $0.id == pane })
        #expect(model.editor(pane)?.tabs.first?.dirty == true)
    }

    @Test func quitWithNothingUnsavedQuitsAndWithDirtyTabsAsks() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        #expect(await model.requestQuit())
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "x", basis: 0)
        #expect(await !model.requestQuit())
        #expect(model.unsavedPrompt?.intent == .quit)
        await model.resolveUnsaved(.cancel)
        #expect(model.quitCancelled == 1 && model.quitApproved == 0)
        #expect(await !model.requestQuit())
        await model.resolveUnsaved(.dontSave)
        #expect(model.quitApproved == 1 && model.quitCancelled == 1)
    }

    @Test func aQuitWhoseSaveCannotFinishIsCancelled() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "x", basis: 0)
        #expect(await !model.requestQuit())
        await model.resolveUnsaved(.save)
        #expect(model.quitApproved == 0 && model.quitCancelled == 1)
        #expect(model.editorSaveAsRequest == pane)
    }

    // MARK: Fix round 1

    /// A switch queued while the tabs were clean asks when it fires, once they are dirty.
    @Test func aQueuedSwitchFiringOverDirtyTabsAsksFirst() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.beginTurnForTesting()
        await model.requestOrganizationSwitch("beta")
        #expect(model.queuedOrgSwitch == "beta" && model.unsavedPrompt == nil)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "x", basis: 0)
        await model.endTurnForTesting()
        #expect(model.unsavedPrompt == UnsavedPrompt(intent: .switchOrganisation("beta"), files: ["Untitled-1"]))
        #expect(model.queuedOrgSwitch == nil && model.layoutSnapshot.panes.contains { $0.id == pane })
        await model.resolveUnsaved(.dontSave)
        #expect(model.layoutSnapshot.panes.isEmpty)
    }

    /// Don't Save while a turn runs queues the switch; the queue firing does not ask again.
    @Test func aSwitchApprovedWhileATurnRunsFiresWithoutAskingAgain() async throws {
        let (model, _, pane) = try await dirtyFileWindow()
        await model.beginTurnForTesting()
        await model.requestOrganizationSwitch("beta")
        await model.resolveUnsaved(.dontSave)
        #expect(model.queuedOrgSwitch == "beta" && model.unsavedPrompt == nil)
        #expect(model.editor(pane)?.tabs.first?.dirty == true)
        await model.endTurnForTesting()
        #expect(model.unsavedPrompt == nil && model.layoutSnapshot.panes.isEmpty)
    }

    @Test func stopAndSwitchNowOverDirtyTabsCutsTheTurnThenAsks() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.beginTurnForTesting()
        await model.requestOrganizationSwitch("beta")
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "x", basis: 0)
        await model.stopTurnAndSwitchNow()
        #expect(!model.turnInFlight && model.queuedOrgSwitch == nil)
        #expect(model.unsavedPrompt?.intent == .switchOrganisation("beta"))
        #expect(model.layoutSnapshot.panes.contains { $0.id == pane })
        await model.resolveUnsaved(.dontSave)
        #expect(model.layoutSnapshot.panes.isEmpty)
    }

    /// A prompt up is never replaced: ⌘W on a dirty tab under a quit prompt leaves the quit asking.
    @Test func aQuitPromptIsNotReplacedByALaterAsk() async throws {
        let (model, _, _) = try await dirtyFileWindow()
        #expect(await !model.requestQuit())
        await model.closeFocusedTabOrPane()
        #expect(model.unsavedPrompt?.intent == .quit)
        await model.resolveUnsaved(.cancel)
        #expect(model.quitCancelled == 1 && model.unsavedPrompt == nil)
    }

    @Test func dontSaveClosesTheAskedScratchTabNotTheActiveOne() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "one", basis: 0)
        await model.editorBufferDidChange(pane: pane, tab: 1, text: "two", basis: 0)
        #expect(model.editor(pane)?.active == 1)
        await model.closeFocusedTabOrPane()
        #expect(model.unsavedPrompt?.intent == .closeTab(pane: pane, subject: .scratch(number: 2)))
        await model.dispatchFromSurface("editor_focus_tab", .object(["pane": .string(pane), "index": .integer(0)]))
        await model.refreshPanes()
        #expect(model.editor(pane)?.active == 0)
        await model.resolveUnsaved(.dontSave)
        let tabs = try #require(model.editor(pane)?.tabs)
        #expect(tabs.map(\.subject) == [.scratch(number: 1)])
        #expect(tabs.first?.dirty == true && tabs.first?.text == "one")
    }

    @Test func savingAnInactiveScratchTabMakesItActiveForThePathField() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "select 1", basis: 0)
        await files.put("/p/api/a.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go"), "pane": .string(pane)]))
        await model.refreshPanes()
        #expect(model.editor(pane)?.active == 1)
        await model.closePane(id: pane)
        #expect(model.unsavedPrompt?.files == ["Untitled-1"])
        await model.resolveUnsaved(.save)
        #expect(model.editorSaveAsRequest == pane && model.editor(pane)?.active == 0)
        #expect(await model.saveScratch(pane: pane, as: "/p/api/q.sql") == .saved)
        #expect(await files.text(of: "/p/api/q.sql") == "select 1")
        #expect(await files.text(of: "/p/api/a.go") == "a")
    }

    /// The agent's (and any registry caller's) `pane_close` refuses dirty tabs unless it says
    /// `discard`, naming them, as `editor_close` does.
    @Test func paneCloseRefusesUnsavedTabsUnlessDiscarded() async throws {
        let (model, _, pane) = try await dirtyFileWindow()
        await model.dispatchFromSurface("pane_close", .object(["id": .string(pane)]))
        await model.refreshLayout()
        #expect(model.layoutSnapshot.panes.contains { $0.id == pane })
        #expect(model.status.contains("unsaved edits in /p/api/a.go"), "\(model.status)")
        #expect(model.unsavedPrompt == nil)
        await model.dispatchFromSurface("pane_close", .object(["id": .string(pane), "discard": .bool(true)]))
        await model.refreshLayout()
        #expect(!model.layoutSnapshot.panes.contains { $0.id == pane })
    }

    // MARK: Fix round 2

    /// The approval covers what the operator saw: typing after it means the queue asks again.
    @Test func editsAfterApprovingAQueuedSwitchAreAskedAboutAgain() async throws {
        let (model, _, pane) = try await dirtyFileWindow()
        await model.beginTurnForTesting()
        await model.requestOrganizationSwitch("beta")
        await model.resolveUnsaved(.dontSave)
        #expect(model.queuedOrgSwitch == "beta")
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "bc", basis: 0)
        await model.endTurnForTesting()
        #expect(model.unsavedPrompt == UnsavedPrompt(intent: .switchOrganisation("beta"), files: ["a.go"]))
        #expect(model.layoutSnapshot.panes.contains { $0.id == pane })
        #expect(model.editor(pane)?.tabs.first?.text == "bc")
    }

    /// A quit approved over a held queued switch does not fire the switch on its way out.
    @Test func approvingAQuitDoesNotFireAHeldSwitch() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.beginTurnForTesting()
        await model.requestOrganizationSwitch("beta")   // clean: queues
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "x", basis: 0)
        #expect(await !model.requestQuit())
        await model.endTurnForTestingWithoutFiring()
        await model.resolveUnsaved(.dontSave)
        #expect(model.quitApproved == 1 && model.unsavedPrompt == nil)
        #expect(model.queuedOrgSwitch == "beta" && model.layoutSnapshot.panes.contains { $0.id == pane })
    }
}

/// Final review I1: Don't Save closes the tab the prompt named, by its subject, in one dispatch —
/// even when another tab became active while the prompt waited.
@Suite @MainActor struct WindowModelUnsavedSubjectTests {
    @Test func dontSaveClosesTheNamedTabWhenAnotherBecameActiveMeanwhile() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        await files.put("/p/api/b.go", "b")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.focusPane(id: pane)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "a!", basis: 0)
        await model.closeFocusedTabOrPane()
        #expect(model.unsavedPrompt?.intent == .closeTab(pane: pane, subject: .file(path: "/p/api/a.go", root: "/p/api")))
        // The agent opens b.go (now active, and dirty) while the prompt waits.
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/b.go"), "pane": .string(pane)]))
        await model.editorBufferDidChange(pane: pane, tab: 1, text: "b!", basis: 0)
        await model.refreshPanes()
        #expect(model.editor(pane)?.active == 1)
        await model.resolveUnsaved(.dontSave)
        let tabs = try #require(model.editor(pane)?.tabs)
        #expect(tabs.map(\.path) == ["/p/api/b.go"] && tabs[0].text == "b!")
    }

    @Test func dontSaveOnAScratchClosesThatScratchNotTheActiveTab() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "one", basis: 0)
        await model.closeFocusedTabOrPane()
        await model.dispatchFromSurface("editor_new_scratch", .object(["pane": .string(pane)]))
        await model.editorBufferDidChange(pane: pane, tab: 1, text: "two", basis: 0)
        await model.refreshPanes()
        await model.resolveUnsaved(.dontSave)
        #expect(model.editor(pane)?.tabs.map(\.subject) == [.scratch(number: 2)])
    }
}
