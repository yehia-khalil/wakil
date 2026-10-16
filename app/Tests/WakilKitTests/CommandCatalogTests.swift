import Testing
import Foundation
@testable import WakilKit

private func ctx(_ kind: String? = nil, inFlight: Bool = false, next: Bool = false, prev: Bool = false,
                 envs: Bool = true, projects: Int = 2, providers: Int = 2) -> PaletteContext {
    PaletteContext(focusedPane: kind.map { .init(id: "\($0)-1", kind: $0) }, apiSendInFlight: inFlight,
                   dbPageHasNext: next, dbPageHasPrevious: prev, hasEnvironments: envs,
                   projectCount: projects, providerCount: providers)
}

/// The registry the app ships, built the way `AppWiringTests` builds it: no binaries, so no
/// clients, and every action still registered. A catalog checked against a hand-made registry
/// would guard nothing.
private func shippedRegistry() async throws -> [ActionDescriptor] {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let bin = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let wiring = await WakilWiring.build(
        journalDirectory: dir, sessionId: "catalog", executableDirectory: bin,
        environment: ["HOME": dir.path, "WAKIL_BIN_DIR": bin.path])
    await wiring.shutdown()
    return await wiring.registry.all()
}

private func testRegistryActionNames() async throws -> [String] {
    try await shippedRegistry().map(\.name)
}

/// name → the schema's `required` list.
private func testRegistrySchemas() async throws -> [String: [String]] {
    var out: [String: [String]] = [:]
    for d in try await shippedRegistry() {
        guard case .object(let s) = d.schema, case .array(let req)? = s["required"] else {
            out[d.name] = []; continue
        }
        out[d.name] = req.compactMap { if case .string(let r) = $0 { r } else { nil } }
    }
    return out
}

/// The pane kind a command needs focused to be offered, or nil for a global one.
private func paneKind(_ c: CatalogCommand) -> String? {
    if case .pane(let kind) = c.scope { kind } else { nil }
}

@Test func everyCommandNamesARegisteredAction() async throws {
    let names = Set(try await testRegistryActionNames())
    #expect(names.contains("pane_open"), "the shipped registry was not built")
    for c in CommandCatalog.all where !c.action.hasPrefix("window.") {
        #expect(names.contains(c.action), "\(c.id) → \(c.action) is not registered")
    }
}

@Test func everyCommandSatisfiesItsActionsRequiredParams() async throws {
    let schemas = try await testRegistrySchemas()
    for c in CommandCatalog.all where !c.action.hasPrefix("window.") {
        let p = c.params(ctx(paneKind(c)), c.input == nil ? nil : "value")
        guard case .object(let o) = p else { Issue.record("\(c.id) params not an object"); continue }
        for r in schemas[c.action] ?? [] { #expect(o[r] != nil, "\(c.id) missing \(r)") }
    }
}

/// `window.` names reach no registry; the window runs them. Each one is a deliberate exception
/// to the registered-action guard, so the set is pinned rather than open.
@Test func onlySendIsRoutedThroughTheWindow() {
    #expect(CommandCatalog.all.filter { $0.action.hasPrefix("window.") }.map(\.id) == ["api.send", "editor.reveal"])
}

@Test func paneScopedParamsNameTheFocusedPane() {
    let p = CommandCatalog.command(id: "db.refetch")!.params(ctx("db"), nil)
    #expect(p == .object(["pane": .string("db-1")]))
    let close = CommandCatalog.command(id: "db.close")!.params(ctx("db"), nil)
    #expect(close == .object(["id": .string("db-1")]))
    let curl = CommandCatalog.command(id: "api.curl")!.params(ctx("api"), "curl https://x")
    #expect(curl == .object(["pane": .string("api-1"), "text": .string("curl https://x")]))
}

@Test func idsUniqueAndLabelsUniqueWithinScope() {
    #expect(Set(CommandCatalog.all.map(\.id)).count == CommandCatalog.all.count)
    let byScope = Dictionary(grouping: CommandCatalog.all, by: { "\($0.scope)" })
    for (_, cs) in byScope { #expect(Set(cs.map(\.label)).count == cs.count) }
}

@Test func noAgentInternalsAreCommands() {
    for c in CommandCatalog.all {
        #expect(!["read_pane", "read_layout", "approve_tool_use", "session_record_parent"].contains(c.action))
    }
}

@Test func focusedPaneCommandsComeFirstThenGlobal() {
    let titles = CommandCatalog.entries(for: ctx("db")).map(\.title)
    let firstGlobal = titles.firstIndex(of: "Switch environment…")!
    #expect(titles.firstIndex(of: "Run query again")! < firstGlobal)
    #expect(titles.firstIndex(of: "Close pane")! < firstGlobal)
    #expect(!titles.contains("Send"))   // another pane kind's command
}

@Test func noFocusedPaneShowsOnlyGlobal() {
    let entries = CommandCatalog.entries(for: ctx(nil))
    #expect(!entries.isEmpty)
    #expect(entries.allSatisfy { CommandCatalog.command(id: $0.id)?.scope == .global })
}

@Test func unavailableCommandsAreHiddenNotDisabled() {
    #expect(!CommandCatalog.entries(for: ctx("api", inFlight: false)).map(\.title).contains("Cancel send"))
    #expect(CommandCatalog.entries(for: ctx("api", inFlight: true)).map(\.title).contains("Cancel send"))
    #expect(!CommandCatalog.entries(for: ctx("api", inFlight: true)).map(\.title).contains("Send"))
    #expect(!CommandCatalog.entries(for: ctx("db")).map(\.title).contains("Next page"))
    #expect(CommandCatalog.entries(for: ctx("db", next: true)).map(\.title).contains("Next page"))
    #expect(!CommandCatalog.entries(for: ctx("db")).map(\.title).contains("Previous page"))
    #expect(CommandCatalog.entries(for: ctx("db", prev: true)).map(\.title).contains("Previous page"))
    #expect(!CommandCatalog.entries(for: ctx(nil, projects: 1)).map(\.title).contains("Switch project…"))
    #expect(!CommandCatalog.entries(for: ctx(nil, providers: 1)).map(\.title).contains("Switch provider…"))
    #expect(!CommandCatalog.entries(for: ctx(nil, envs: false)).map(\.title).contains("Switch environment…"))
}

@Test func inputCommandsCarryTheEllipsisAndOthersDoNot() {
    for c in CommandCatalog.all {
        #expect(c.label.hasSuffix("…") == (c.input != nil), "\(c.id)")
    }
}

@Test func entriesCarryRunOrChooseVerbs() {
    for e in CommandCatalog.entries(for: ctx("db")) {
        let c = CommandCatalog.command(id: e.id)!
        #expect(e.verb == (c.input == nil ? "run" : "choose"))
        #expect(e.group == .commands)
        #expect(e.kindLabel == "command")
        if c.input == nil {
            #expect(e.action == .dispatch(action: c.action, params: c.params(ctx("db"), nil)))
        } else {
            #expect(e.action == .pushStep(commandId: c.id))
        }
    }
}

@Test func setLanguageIsOfferedOnlyForAFocusedEditor() async {
    #expect(CommandCatalog.entries(for: ctx("editor")).map(\.title).contains("Set language…"))
    #expect(!CommandCatalog.entries(for: ctx("db")).map(\.title).contains("Set language…"))
    #expect(!CommandCatalog.entries(for: ctx(nil)).map(\.title).contains("Set language…"))
    let c = CommandCatalog.command(id: "editor.language")!
    #expect(c.action == "editor_set_language")
    #expect(c.input == .choice(.languages, placeholder: "Language"))
    #expect(c.params(ctx("editor"), "sql") == .object(["pane": .string("editor-1"), "language": .string("sql")]))
    let rows = await choiceEntries(.languages, readers: ChoiceReaders())
    #expect(rows.map(\.id) == editorLanguageChoices)
    #expect(editorLanguageChoices.first == "plaintext" && editorLanguageChoices.contains("dockerfile"))
}

@Test func revealIsAnEditorCommandOnlyWithAFileInFront() {
    var c = ctx("editor")
    #expect(!CommandCatalog.entries(for: c).map(\.title).contains("Reveal Active File in Tree"))
    c.editorActiveIsFile = true
    #expect(CommandCatalog.entries(for: c).map(\.title).contains("Reveal Active File in Tree"))
}
