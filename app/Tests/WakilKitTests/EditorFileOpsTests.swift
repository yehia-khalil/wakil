import Foundation
import Testing
@testable import WakilKit

private func tab(_ path: String, text: String = "t", saved: String = "t") -> EditorTab {
    var t = EditorTab.file(path: path, root: "/p/api", text: saved, mtime: 1, language: editorLanguage(forPath: path))
    t.text = text
    return t
}

@Test func repointMovesAFileTabAndRemembersItsKey() {
    let out = editorRepointTabs([tab("/p/api/a.go")], from: "/p/api/a.go", to: "/p/api/b.go", root: "/p/api")
    #expect(out[0].path == "/p/api/b.go")
    #expect(out[0].formerKeys == ["file:/p/api/a.go"])
}

@Test func repointMovesEveryTabUnderAFolderAndKeepsEdits() {
    let tabs = [tab("/p/api/d/x.go", text: "dirty"), tab("/p/api/dx.go"), tab("/p/api/d/e/y.go")]
    let out = editorRepointTabs(tabs, from: "/p/api/d", to: "/p/web/z", root: "/p/web")
    #expect(out.map(\.path) == ["/p/web/z/x.go", "/p/api/dx.go", "/p/web/z/e/y.go"])
    #expect(out[0].text == "dirty" && out[0].dirty)
    var root0: String?
    if case .file(_, let root) = out[0].subject { root0 = root }
    #expect(root0 == "/p/web")
}

@Test func repointRelabelsTheLanguageOnlyWhenItWasDerived() {
    var manual = tab("/p/api/a.txt")
    manual.language = "sql"
    let out = editorRepointTabs([tab("/p/api/a.txt"), manual], from: "/p/api/a.txt", to: "/p/api/a.go", root: "/p/api")
    #expect(out[0].language == "go")
    // The second tab shares the path only in this test; a real pane never holds two.
    #expect(out[1].language == "sql")
}

@Test func repointDropsDiffTabsAtOrUnder() {
    let diff = EditorTab.diff(root: "/p/api", path: "d/x.go", group: .changed)
    let out = editorRepointTabs([diff, tab("/p/api/k.go")], from: "/p/api/d", to: "/p/api/e", root: "/p/api")
    #expect(out.map(\.path) == ["/p/api/k.go"])
}

@Test func trashClosesCleanTabsAndMarksDirtyOnesDeleted() {
    let tabs = [tab("/p/api/d/a.go"), tab("/p/api/d/b.go", text: "edit"), tab("/p/api/c.go")]
    let out = editorTabsAfterTrash(tabs, path: "/p/api/d")
    #expect(out.map(\.path) == ["/p/api/d/b.go", "/p/api/c.go"])
    #expect(out[0].diskState == .deleted && out[0].text == "edit")
}

@Test func activeFollowsItsTabOrFallsToANeighbour() {
    let old = [tab("/p/api/a.go"), tab("/p/api/b.go"), tab("/p/api/c.go")]
    let gone = editorTabsAfterTrash(old, path: "/p/api/b.go")
    #expect(editorActiveAfter(old, active: 1, new: gone) == 1)   // c.go, the neighbour
    #expect(editorActiveAfter(old, active: 2, new: gone) == 1)   // c.go itself
    let moved = editorRepointTabs(old, from: "/p/api/c.go", to: "/p/api/z.go", root: "/p/api")
    #expect(editorActiveAfter(old, active: 2, new: moved) == 2)
    #expect(editorActiveAfter(old, active: 0, new: []) == nil)
}

@Test func renameTargetResolvesAgainstTheItemsFolder() {
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "b.go") == "/p/api/d/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "sub/b.go") == "/p/api/d/sub/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "../b.go") == "/p/api/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "/b.go") == "/p/api/d/b.go")
}

@Test func aDoubleRepointKeepsBothFormerKeysOldestFirst() {
    let once = editorRepointTabs([tab("/p/api/a.go")], from: "/p/api/a.go", to: "/p/api/b.go", root: "/p/api")
    let twice = editorRepointTabs(once, from: "/p/api/b.go", to: "/p/api/c.go", root: "/p/api")
    #expect(twice[0].formerKeys == ["file:/p/api/a.go", "file:/p/api/b.go"])
}

@Test func activeAfterIgnoresAFormerKeyWhoseOldTabStillExists() {
    // old: a.go and b.go; a.go renamed to c.go then b.go renamed to a.go would leave stale keys, but a
    // tab whose own key is still in `new` is matched by that key only.
    let old = [tab("/p/api/a.go"), tab("/p/api/b.go")]
    var moved = tab("/p/api/c.go")
    moved.formerKeys = ["file:/p/api/b.go"]
    let new = [tab("/p/api/b.go"), moved]
    #expect(editorActiveAfter(old, active: 1, new: new) == 0)
}
