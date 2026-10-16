import Testing
import Foundation
@testable import WakilKit

private func sourceTestAction(_ name: String, _ kind: ActionKind) -> Action {
    Action(name: name, description: "test", kind: kind, schema: .object([:])) { params in
        .object(["echo": params])
    }
}

private func sourceTestContext() -> ContextStore.ActiveContext {
    ContextStore.ActiveContext(org: "initech", project: "wakil-acceptance-2", environment: "staging",
                               rootPaths: [], activeProvider: "p", environmentProduction: .undeclared)
}

@Test func wakilSourceNamesActionsAndTheActiveContext() async throws {
    let registry = ActionRegistry(journalDirectory: testScratchRoot
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registry.register(sourceTestAction("pane_move", .read))
    let names = try await WakilSource(registry: registry).identifiers(for: sourceTestContext())
    #expect(names.contains(Identifier(text: "pane_move", kind: .action, origin: "wakil", source: .wakil)))
    #expect(names.contains(Identifier(text: "wakil-acceptance-2", kind: .project, origin: "initech", source: .wakil)))
    #expect(names.contains(Identifier(text: "staging", kind: .environment, origin: "initech · wakil-acceptance-2", source: .wakil)))
    #expect(names.contains(Identifier(text: "initech", kind: .org, origin: "wakil", source: .wakil)))
}

@Test func paneSourceNamesWhatIsOnScreen() async throws {
    let layout = LayoutStore()
    let panes = PaneStore()
    let db = await layout.open(kind: "db", title: "Quotes")
    await panes.setRows(
        paneId: db.id, columns: ["id", "transaction_read_only"], columnTypes: [],
        columnTypesInferred: false, rows: [], millis: 1, truncated: false, pageable: true,
        offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(table: "edit_quote", keyColumns: ["id"],
                               columns: ["transaction_read_only"], rowKeys: []))
    let term = await layout.open(kind: "terminal", title: "Shell")
    await panes.setTerminalLiveState(
        paneId: term.id, cwd: "/work/wakil", shell: "zsh", cols: 80, rows: 24,
        screen: .blocks, grid: [])
    let api = await layout.open(kind: "api", title: "Orders API")
    await panes.openApi(paneId: api.id, entry: "orders", environment: "staging",
                        origin: nil, credentialed: false)
    var draft = ApiDraft.empty
    draft.entry = "orders"
    draft.path = [.literal("/v1/orders")]
    await panes.setApiDraft(paneId: api.id, draft: draft)

    let names = try await PaneSource(layout: layout, panes: panes).identifiers(for: sourceTestContext())
    let dbOrigin = "pane · Quotes"
    #expect(names.contains(Identifier(text: "edit_quote", kind: .table, origin: dbOrigin, source: .panes)))
    #expect(names.contains(Identifier(text: "transaction_read_only", kind: .column, origin: dbOrigin, source: .panes)))
    #expect(names.contains(Identifier(text: "/work/wakil", kind: .path, origin: "pane · Shell", source: .panes)))
    #expect(names.contains(Identifier(text: "orders", kind: .endpoint, origin: "pane · Orders API", source: .panes)))
    #expect(names.contains(Identifier(text: "/v1/orders", kind: .endpoint, origin: "pane · Orders API", source: .panes)))
}
