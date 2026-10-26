import Foundation
import Testing
@testable import WakilKit

@Test func readPaneForAnEditorIsTheGoldenShape() async {
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.updateEditor(paneId: pane, create: true) { s in
        var a = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "l1\nl2\nl3\nl4", mtime: 7, language: "go")
        a.text = "l1\nl2 edited\nl3\nl4"
        a.cursor = EditorPosition(line: 2, column: 4)
        a.selection = EditorRange(start: EditorPosition(line: 2, column: 1), end: EditorPosition(line: 2, column: 3))
        a.visibleRange = 2...3
        s.tabs = [a, .scratch(number: 1, language: "sql")]
        s.active = 0
    }
    let read = await store.readPane(paneId: pane, kind: "editor")
    #expect(read == .object([
        "kind": .string("editor"),
        "failure": .null,
        "active": .number(0),
        "tabs": .array([
            .object(["path": .string("/p/api/a.go"), "scratch": .null, "root": .string("/p/api"),
                     "language": .string("go"), "dirty": .bool(true), "disk_state": .string("inSync"),
                     "notice": .null, "saving": .bool(false), "preview": .bool(false), "diff": .null]),
            .object(["path": .null, "scratch": .number(1), "root": .null,
                     "language": .string("sql"), "dirty": .bool(false), "disk_state": .string("inSync"),
                     "notice": .null, "saving": .bool(false), "preview": .bool(false), "diff": .null]),
        ]),
        "cursor": .object(["line": .number(2), "column": .number(4)]),
        "selection": .object(["start": .object(["line": .number(2), "column": .number(1)]),
                              "end": .object(["line": .number(2), "column": .number(3)])]),
        "visible_range": .object(["first": .number(2), "last": .number(3)]),
        "hunks": .null,
        "peek": .null,
        "visible_text": .string("l2 edited\nl3"),
        "selected_text": .string("l2"),
        "column": .null,
        // The Ticket view follows the front file's root; nothing read of it yet.
        "ticket": .object(["root": .string("/p/api"), "branch": .null, "tickets": .array([]), "marked": .null,
                           "prs": .array([]), "drafts": .array([]), "reading": .bool(false), "error": .null]),
        "find": .null,
        "search": .object(["query": .string(""), "case": .bool(false), "word": .bool(false), "regex": .bool(false),
                           "in_flight": .bool(false), "truncated": .bool(false), "files_truncated": .bool(false), "skipped_large": .array([]),
                           "changed_since": .bool(false), "cancelled": .bool(false), "error": .null, "results": .array([]),
                           "replace": .null, "replace_in_flight": .bool(false), "last_replace": .null]),
    ]))
}

@Test func readPaneForANeverWrittenEditorHasEveryKeyEmpty() async {
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    let read = await PaneStore(kinds: PaneKinds.standard).readPane(paneId: pane, kind: "editor")
    guard case .object(let o) = read else { Issue.record("not an object"); return }
    for key in ["active", "tabs", "cursor", "selection", "visible_range", "peek", "visible_text", "selected_text", "column", "ticket", "find", "search"] {
        #expect(o[key] != nil, "missing \(key)")
    }
    #expect(o["tabs"] == .array([]) && o["active"] == .null)
}

@Test func readPaneForAnEditorCarriesColumnSearchAndFind() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    await panes.updateEditor(paneId: "editor-1", create: true) { s in
        s.tabs = [.file(path: "/p/api/a.go", root: "/p/api", text: "x", mtime: 1, language: "go")]
        s.active = 0
        s.column = EditorColumnState(shown: true, view: .search, width: 300, open: ["/p/api"])
        s.search.query = "foo"
        s.search.filesTruncated = true
        s.search.results = [EditorSearchMatch(root: "/p/api", path: "a.go", line: 3, column: 5, preview: "foo()")]
        s.findReport = EditorFindReport(query: "x", caseSensitive: true, wholeWord: false, regex: false, count: 4, shown: true)
    }
    let read = await panes.readPane(paneId: "editor-1", kind: "editor")
    guard case .object(let o) = read, case .object(let col)? = o["column"], case .object(let search)? = o["search"],
          case .object(let find)? = o["find"], case .array(let tabs)? = o["tabs"], case .object(let t0)? = tabs.first,
          case .array(let results)? = search["results"], case .object(let r0)? = results.first else {
        Issue.record("shape: \(read)"); return
    }
    #expect(col["shown"] == .bool(true) && col["view"] == .string("search"))
    #expect(col["width"] == .number(300) && col["open"] == .array([.string("/p/api")]))
    #expect(r0["path"] == .string("a.go") && r0["line"] == .number(3))
    #expect(search["files_truncated"] == .bool(true) && search["truncated"] == .bool(false))
    #expect(find["count"] == .number(4) && find["case"] == .bool(true))
    #expect(t0["preview"] == .bool(false))
}

@Test func readPaneFindFromTheRequestHasANullCount() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    await panes.updateEditor(paneId: "editor-1", create: true) { s in
        s.find = EditorFindRequest(query: "q", caseSensitive: false, wholeWord: true, regex: false, serial: 1)
    }
    guard case .object(let o) = await panes.readPane(paneId: "editor-1", kind: "editor"), case .object(let f)? = o["find"] else {
        Issue.record("no find"); return
    }
    #expect(f["count"] == .null && f["word"] == .bool(true) && f["shown"] == .bool(true))
}
