import Foundation
import Testing
@testable import WakilKit

/// 3a-ii-b final review M1: a press names the pane it was made in, so its selected lines are never
/// paired with another (focused) pane's diff tab.
@Suite @MainActor struct WindowModelRangesTests {
    @Test func stageRangesUsesThePressedPanesTab() async throws {
        let window = WindowModel.forTesting(scratchRoot: testScratchRoot)
        let asked = ParamsRecorder()
        await window.registryForTesting.register(Action(
            name: "editor_changes_stage_ranges", description: "test", kind: .mutate, audience: .agentReachable,
            schema: .object(["type": .string("object")]),
            handler: { params in await asked.record(params); return .object([:]) },
            price: (production: .allow, otherwise: .allow)))
        #expect(await window.openPane(kind: "editor"))
        #expect(await window.openPane(kind: "editor"))
        await window.refreshLayout()
        let ids = window.layoutSnapshot.panes.filter { $0.kind == "editor" }.map(\.id)
        try #require(ids.count == 2)
        for (id, path) in zip(ids, ["a.go", "b.go"]) {
            await window.panesForTesting.updateEditor(paneId: id, create: true) { s in
                s.tabs = [EditorTab(subject: .diff(root: "/p", path: path, group: .changed), text: "", savedText: "",
                                    language: "go", diskState: .inSync, mtime: 1, cursor: EditorPosition(line: 1, column: 1),
                                    selection: nil, visibleRange: nil, scrollTop: 0, notice: nil, readOnly: true,
                                    saving: false, edits: 0, lastAgentEdit: nil)]
                s.active = 0
            }
        }
        await window.refreshPanes()
        // The layout focuses the last pane opened; the press is in the other one.
        let pressed = ids[0] == window.layoutSnapshot.focusedId ? ids[1] : ids[0]
        let file = window.editor(pressed)?.tabs.first.flatMap { tab -> String? in
            if case .diff(_, let p, _, _) = tab.subject { p } else { nil }
        }
        await window.changesStageRanges(pane: pressed, [EditorLineSpan(start: 2, end: 2)])
        let params = try #require(await asked.last)
        #expect(optionalString(params, "pane") == pressed)
        #expect(optionalString(params, "path") == "/p/" + (file ?? "?"))
    }
}

private actor ParamsRecorder {
    var last: JSONValue?
    func record(_ p: JSONValue) { last = p }
}
