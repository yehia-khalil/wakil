import Foundation
import Testing
@testable import WakilKit

private func editorStore() async -> (PaneStore, String) {
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    return (PaneStore(kinds: PaneKinds.standard), pane)
}

@Test func typingMarksTheTabDirtyAndUndoingTheTypingCleansIt() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        s.tabs = [.file(path: "/p/a.go", root: "/p", text: "abc", mtime: 1, language: "go")]; s.active = 0
    }
    await store.editorBufferDidChange(paneId: pane, tab: 0, text: "abcd", basis: 0)
    #expect(await store.editorSnapshot(paneId: pane).tabs[0].dirty)
    await store.editorBufferDidChange(paneId: pane, tab: 0, text: "abc", basis: 0)
    #expect(await !store.editorSnapshot(paneId: pane).tabs[0].dirty)
}

@Test func typingIntoATabThatNoLongerExistsIsDropped() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in s.tabs = []; s.active = nil }
    await store.editorBufferDidChange(paneId: pane, tab: 3, text: "x", basis: 0)
    #expect(await store.editorSnapshot(paneId: pane).tabs.isEmpty)
}

@Test func typingIntoAReadOnlyTabIsDropped() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        var t = EditorTab.file(path: "/p/l.txt", root: "/p", text: "", mtime: 1, language: "plaintext")
        t.readOnly = true
        s.tabs = [t]; s.active = 0
    }
    await store.editorBufferDidChange(paneId: pane, tab: 0, text: "x", basis: 0)
    #expect(await store.editorSnapshot(paneId: pane).tabs[0].text == "")
}

@Test func theViewsReportMovesCursorAndScrollWithoutDirtying() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        s.tabs = [.file(path: "/p/a.go", root: "/p", text: "a\nb", mtime: 1, language: "go")]; s.active = 0
    }
    await store.editorViewDidReport(paneId: pane, tab: 0, cursor: EditorPosition(line: 2, column: 1),
                                    selection: nil, visibleRange: 1...2, scrollTop: 10)
    let t = await store.editorSnapshot(paneId: pane).tabs[0]
    #expect(t.cursor == EditorPosition(line: 2, column: 1))
    #expect(t.visibleRange == 1...2 && t.scrollTop == 10 && !t.dirty)
}

@Test func aReportWithNoVisibleLinesKeepsTheLastViewAndScroll() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        s.tabs = [.file(path: "/p/a.go", root: "/p", text: "a\nb", mtime: 1, language: "go")]; s.active = 0
    }
    await store.editorViewDidReport(paneId: pane, tab: 0, cursor: EditorPosition(line: 1, column: 1),
                                    selection: nil, visibleRange: 1...2, scrollTop: 10)
    await store.editorViewDidReport(paneId: pane, tab: 0, cursor: EditorPosition(line: 2, column: 1),
                                    selection: nil, visibleRange: nil, scrollTop: 0)
    let t = await store.editorSnapshot(paneId: pane).tabs[0]
    #expect(t.cursor == EditorPosition(line: 2, column: 1))
    #expect(t.visibleRange == 1...2 && t.scrollTop == 10)
}

@Test func savedTabsSurviveALayoutRoundTripAndAnOldLayoutDecodes() throws {
    let pane = Pane(id: "e", kind: "editor", title: "Editor", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1),
                    editorTabs: [EditorSavedTab(path: "/p/a.go", cursor: EditorPosition(line: 3, column: 2), scrollTop: 9)])
    let back = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
    #expect(back.editorTabs == pane.editorTabs)
    let old = #"{"id":"e","kind":"editor","title":"Editor","frame":{"x":0,"y":0,"width":1,"height":1}}"#
    #expect(try JSONDecoder().decode(Pane.self, from: Data(old.utf8)).editorTabs == nil)
}

@Test func aWholeTextPostMadeBeforeAnAgentEditIsDroppedAndOneMadeAfterItLands() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        var t = EditorTab.file(path: "/p/a.go", root: "/p", text: "abc", mtime: 1, language: "go")
        t.text = "abcE"
        t.lastAgentEdit = EditorAgentEdit(serial: 1, range: EditorRange(start: .init(line: 1, column: 4),
                                                                         end: .init(line: 1, column: 4)), text: "E")
        s.tabs = [t]; s.active = 0
    }
    await store.editorBufferDidChange(paneId: pane, tab: 0, text: "abcx", basis: 0)
    #expect(await store.editorSnapshot(paneId: pane).tabs[0].text == "abcE")
    await store.editorBufferDidChange(paneId: pane, tab: 0, text: "abcEx", basis: 1)
    #expect(await store.editorSnapshot(paneId: pane).tabs[0].text == "abcEx")
}

/// Final review I1: the view's post is addressed by subject. A tab before it closing meanwhile
/// moves every position; the post still lands on its own file, never on the one now at its index.
@Test func aTypingPostAfterAnEarlierTabClosedLandsOnItsOwnTab() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        s.tabs = [.file(path: "/p/a.go", root: "/p", text: "a", mtime: 1, language: "go"),
                  .file(path: "/p/b.go", root: "/p", text: "b", mtime: 1, language: "go")]
        s.active = 1
    }
    // The view saw b.go at index 1; the agent closes a.go before the post lands.
    await store.updateEditor(paneId: pane) { s in s.tabs.remove(at: 0); s.active = 0 }
    await store.editorBufferDidChange(paneId: pane, subject: .file(path: "/p/b.go", root: "/p"), text: "b!", basis: 0)
    let tabs = await store.editorSnapshot(paneId: pane).tabs
    #expect(tabs.map(\.text) == ["b!"] && tabs[0].path == "/p/b.go")
}

@Test func aTypingPostForAClosedTabIsDroppedAndNeverLandsOnAnotherFile() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        s.tabs = [.file(path: "/p/a.go", root: "/p", text: "a", mtime: 1, language: "go"),
                  .file(path: "/p/b.go", root: "/p", text: "b", mtime: 1, language: "go")]
        s.active = 0
    }
    await store.updateEditor(paneId: pane) { s in s.tabs.remove(at: 0); s.active = 0 }
    await store.editorBufferDidChange(paneId: pane, subject: .file(path: "/p/a.go", root: "/p"), text: "a!", basis: 0)
    await store.editorViewDidReport(paneId: pane, subject: .file(path: "/p/a.go", root: "/p"),
                                    cursor: EditorPosition(line: 9, column: 9), selection: nil, visibleRange: nil, scrollTop: 50)
    let t = await store.editorSnapshot(paneId: pane).tabs[0]
    #expect(t.path == "/p/b.go" && t.text == "b" && !t.dirty)
    #expect(t.cursor == EditorPosition(line: 1, column: 1) && t.scrollTop == 0)
}

@Test func typingIntoAPreviewTabKeepsIt() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    var tab = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "a", mtime: 1, language: "go")
    tab.preview = true
    let t = tab
    await panes.updateEditor(paneId: "editor-1", create: true) { s in s.tabs = [t]; s.active = 0 }
    await panes.editorBufferDidChange(paneId: "editor-1", subject: t.subject, text: "ab", basis: 0)
    #expect(await panes.editorSnapshot(paneId: "editor-1").tabs[0].preview == false)
}

@Test func aFindReportIsAViewReportNotATextChange() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    let tab = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "a", mtime: 1, language: "go")
    await panes.updateEditor(paneId: "editor-1", create: true) { s in s.tabs = [tab]; s.active = 0 }
    let r = EditorFindReport(query: "a", caseSensitive: false, wholeWord: false, regex: false, count: 1, shown: true)
    await panes.editorFindDidReport(paneId: "editor-1", report: r)
    let s = await panes.editorSnapshot(paneId: "editor-1")
    #expect(s.findReport == r && s.tabs[0].edits == 0)
}
