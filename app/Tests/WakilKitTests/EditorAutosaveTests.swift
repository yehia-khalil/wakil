import Testing
@testable import WakilKit

private func file(_ path: String, text: String = "x", saved: String = "x", edits: Int = 0) -> EditorTab {
    var t = EditorTab.file(path: path, root: "/p", text: saved, mtime: 1, language: "go")
    t.text = text
    t.edits = edits
    return t
}

@Suite struct EditorAutosaveTests {
    @Test func onlyADirtyInSyncWritableFileTabIsEligible() {
        #expect(editorAutosaveEligible(file("/p/a", text: "y")))
        #expect(!editorAutosaveEligible(file("/p/a")))                       // clean
        var scratch = EditorTab.scratch(number: 1, language: "go"); scratch.text = "y"
        #expect(!editorAutosaveEligible(scratch))
        var changed = file("/p/a", text: "y"); changed.diskState = .changedOnDisk
        #expect(!editorAutosaveEligible(changed))
        var deleted = file("/p/a", text: "y"); deleted.diskState = .deleted
        #expect(!editorAutosaveEligible(deleted))
        var saving = file("/p/a", text: "y"); saving.saving = true
        #expect(!editorAutosaveEligible(saving))
        var readOnly = file("/p/a", text: "y"); readOnly.readOnly = true
        #expect(!editorAutosaveEligible(readOnly))
    }

    @Test func pauseArmsOnEachEditAndNotOnTheFirstLook() {
        var a = EditorAutosave()
        let clean = EditorSnapshot(tabs: [file("/p/a")], active: 0)
        #expect(a.observe(pane: "e1", snapshot: clean, mode: .pause) == EditorAutosaveStep(arm: [], saveNow: []))
        let typed = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 1)], active: 0)
        #expect(a.observe(pane: "e1", snapshot: typed, mode: .pause).arm == ["/p/a"])
        // The same snapshot again (a refresh with no edit) does not re-arm.
        #expect(a.observe(pane: "e1", snapshot: typed, mode: .pause).arm.isEmpty)
        let again = EditorSnapshot(tabs: [file("/p/a", text: "yy", edits: 2)], active: 0)
        #expect(a.observe(pane: "e1", snapshot: again, mode: .pause).arm == ["/p/a"])
    }

    @Test func offAndFocusNeverArm() {
        for mode in [EditorAutosaveMode.off, .focus] {
            var a = EditorAutosave()
            _ = a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: [file("/p/a")], active: 0), mode: mode)
            let typed = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 1)], active: 0)
            #expect(a.observe(pane: "e1", snapshot: typed, mode: mode).arm.isEmpty)
        }
    }

    @Test func focusSavesTheTabSwitchedAwayFrom() {
        var a = EditorAutosave()
        let onA = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 1), file("/p/b")], active: 0)
        _ = a.observe(pane: "e1", snapshot: onA, mode: .focus)
        let onB = EditorSnapshot(tabs: onA.tabs, active: 1)
        #expect(a.observe(pane: "e1", snapshot: onB, mode: .focus).saveNow == ["/p/a"])
        // Switching away from a clean tab saves nothing.
        let backToA = EditorSnapshot(tabs: onA.tabs, active: 0)
        #expect(a.observe(pane: "e1", snapshot: backToA, mode: .focus).saveNow.isEmpty)
    }

    @Test func pauseDoesNotSaveOnATabSwitch() {
        var a = EditorAutosave()
        let onA = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 1), file("/p/b")], active: 0)
        _ = a.observe(pane: "e1", snapshot: onA, mode: .pause)
        #expect(a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: onA.tabs, active: 1), mode: .pause).saveNow.isEmpty)
    }

    @Test func focusLeftAnswersEveryEligibleTabOnlyInFocusMode() {
        let s = EditorSnapshot(tabs: [file("/p/a", text: "y"), file("/p/b"), file("/p/c", text: "z")], active: 0)
        #expect(EditorAutosave.focusLeft(s, mode: .focus) == ["/p/a", "/p/c"])
        #expect(EditorAutosave.focusLeft(s, mode: .pause).isEmpty)
        #expect(EditorAutosave.focusLeft(s, mode: .off).isEmpty)
    }

    @Test func panesAreTrackedApart() {
        var a = EditorAutosave()
        _ = a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: [file("/p/a")], active: 0), mode: .pause)
        // e2's first look at a dirty tab is its first look: nothing to compare, no arm.
        let e2 = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 3)], active: 0)
        #expect(a.observe(pane: "e2", snapshot: e2, mode: .pause).arm.isEmpty)
        a.forget(pane: "e1")
        #expect(a.observe(pane: "e1", snapshot: e2, mode: .pause).arm.isEmpty)
    }

    /// An edit made while a save is in flight still arms: the timer re-checks eligibility when it fires.
    @Test func anEditDuringASaveStillArms() {
        var a = EditorAutosave()
        var t = file("/p/a", text: "y", edits: 1); t.saving = true
        _ = a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: [t], active: 0), mode: .pause)
        t.text = "yz"; t.edits = 2
        #expect(a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: [t], active: 0), mode: .pause).arm == ["/p/a"])
    }
}
