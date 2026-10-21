import Testing
import Foundation
@testable import WakilKit

private let scope = FastPathScope(
    files: ["/p/api/confirm.go", "/p/web/Login.tsx"], roots: ["/p"], projects: ["rafiq", "wakil"],
    environments: ["staging", "qa", "production"], activeEnvironment: "qa",
    databases: ["core", "audit"], tables: ["bookings", "users"],
    panes: [FastPathPane(id: "editor-1", kind: "editor", title: "confirm.go"),
            FastPathPane(id: "db-1", kind: "db", title: "bookings"),
            FastPathPane(id: "terminal-1", kind: "terminal", title: "zsh")],
    apiEntries: ["billing"])

private let schemas: [String: JSONValue] = [
    "ctx_set_environment": .object(["type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]), "required": .array([.string("name")])]),
    "editor_goto": .object(["type": .string("object"),
        "properties": .object(["line": .object(["type": .string("integer")])]), "required": .array([.string("line")])]),
    "editor_open": .object(["type": .string("object"),
        "properties": .object(["path": .object(["type": .string("string")]), "line": .object(["type": .string("integer")])])]),
    "pane_close": .object(["type": .string("object"),
        "properties": .object(["id": .object(["type": .string("string")]), "discard": .object(["type": .string("boolean")])]),
        "required": .array([.string("id")])]),
    "editor_changes_select": .object(["type": .string("object"),
        "properties": .object(["root": .object(["type": .string("string")]), "path": .object(["type": .string("string")]),
                               "group": .object(["type": .string("string")])]),
        "required": .array([.string("root"), .string("path"), .string("group")])]),
    "pane_focus": .object(["type": .string("object"),
        "properties": .object(["id": .object(["type": .string("string")])]), "required": .array([.string("id")])]),
    "pane_open": .object(["type": .string("object"),
        "properties": .object(["kind": .object(["type": .string("string"),
                                                "enum": .array([.string("db"), .string("editor"), .string("terminal")])])]),
        "required": .array([.string("kind")])]),
    "pane_sort": .object(["type": .string("object"),
        "properties": .object(["pane": .object(["type": .string("string")]), "column": .object(["type": .string("string")]),
                               "direction": .object(["type": .string("string"),
                                                     "enum": .array([.string("asc"), .string("desc"), .string("drop")])])]),
        "required": .array([.string("pane")])]),
    "term_open": .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])]),
    "db_list_tables": .object(["type": .string("object"),
        "properties": .object(["database": .object(["type": .string("string")]), "pane": .object(["type": .string("string")])])]),
    "db_read_table": .object(["type": .string("object"),
        "properties": .object(["table": .object(["type": .string("string")]), "database": .object(["type": .string("string")])]),
        "required": .array([.string("table")])]),
    "db_page": .object(["type": .string("object"),
        "properties": .object(["pane": .object(["type": .string("string")]), "to": .object(["type": .string("string")])]),
        "required": .array([.string("pane"), .string("to")])]),
]

@Test func aValidReplyRunsItsAction() {
    let r = FastPath.check(reply: #"{"action":"ctx_set_environment","params":{"name":"staging"}}"#, scope: scope, schemas: schemas)
    #expect(r == .action(name: "ctx_set_environment", params: .object(["name": .string("staging")])))
}

@Test func agentAndEveryFailedCheckGoToTheAgent() {
    for reply in [
        #"{"action":"agent","params":{}}"#,
        #"not json"#,
        #"{"action":"db_run_mutation","params":{}}"#,                      // not on the list
        #"{"action":"ctx_set_environment","params":{}}"#,                   // required param missing
        #"{"action":"ctx_set_environment","params":{"name":"prod"}}"#,      // not in scope
        #"{"action":"editor_open","params":{"path":"/p/api/orders.go"}}"#,  // invented file
        #"{"action":"editor_goto","params":{"line":"twelve"}}"#,           // wrong type
    ] {
        #expect(FastPath.check(reply: reply, scope: scope, schemas: schemas) == .agent, "\(reply)")
    }
}

@Test func aNumberSentAsAStringIsConverted() {
    let r = FastPath.check(reply: #"{"action":"editor_goto","params":{"line":"120"}}"#, scope: scope, schemas: schemas)
    #expect(r == .action(name: "editor_goto", params: .object(["line": .integer(120)])))
}

@Test func discardAndParamsOffTheListAreDropped() {
    let r = FastPath.check(reply: #"{"action":"pane_close","params":{"id":"db-1","discard":true,"extra":1}}"#,
                           scope: scope, schemas: schemas)
    #expect(r == .action(name: "pane_close", params: .object(["id": .string("db-1")])))
}

@Test func aChangesSelectPathBecomesRootRelativeAndChanged() {
    let r = FastPath.check(reply: #"{"action":"editor_changes_select","params":{"path":"/p/api/confirm.go"}}"#,
                           scope: scope, schemas: schemas)
    #expect(r == .action(name: "editor_changes_select", params: .object([
        "root": .string("/p"), "path": .string("api/confirm.go"), "group": .string("changed")])))
}

@Test func aLateAnswerGoesToTheAgent() async {
    let r = await FastPath.route("switch to staging", scope: scope, schemas: schemas, deadline: .milliseconds(50)) { _ in
        try await Task.sleep(for: .milliseconds(500))
        return #"{"action":"ctx_set_environment","params":{"name":"staging"}}"#
    }
    #expect(r == .agent)
}

@Test func aModelErrorGoesToTheAgent() async {
    let r = await FastPath.route("switch to staging", scope: scope, schemas: schemas, deadline: .seconds(1)) { _ in
        throw QuickModelError.unreachable("down")
    }
    #expect(r == .agent)
}

@Test func theInstructionsDoNotDependOnTheLineOrTheScope() {
    // The prompt cache holds them: everything that varies goes in `input`.
    let a = FastPath.instructions(actions: schemas)
    #expect(a == FastPath.instructions(actions: schemas))
    #expect(!a.contains("staging"))
    #expect(FastPath.input("switch to staging", scope: scope).contains("staging"))
}

@Test func everyAllowedActionExistsIsNotAMutationAndTakesItsParams() async throws {
    let dir = testScratchRoot.appendingPathComponent("fast-path-pin-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "fast-path-pin")
    let panes = PaneStore(kinds: PaneKinds.standard)
    let layout = LayoutStore()
    let context = GitRootsContext(roots: ["/p"])
    await registerStandardActions(
        into: registry, context: context, panes: panes, db: nil, resumes: ResumeBroker(), layout: layout)
    await registerLayoutActions(
        into: registry, layout: layout, panes: panes, terminals: TerminalStore(panes: panes),
        unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    await registerTerminalActions(
        into: registry, terminals: TerminalStore(panes: panes), panes: panes, layout: layout,
        activeContext: { ("", "", "", "") })
    _ = await registerApiActions(into: registry, panes: panes, layout: layout)
    await registerEditorActions(
        into: registry, panes: panes, layout: layout, files: nil, fileLists: nil, gitStatus: nil,
        roots: { ["/p"] })
    for (name, action) in FastPath.allowed {
        let d = try #require(await registry.descriptor(named: name), "\(name) is not registered")
        #expect(d.kind != .mutate, "\(name) is a mutation")
        guard case .object(let s) = d.schema, case .object(let props)? = s["properties"] else {
            #expect(action.params.isEmpty, "\(name) has no properties but allows params")
            continue
        }
        for key in action.params.keys {
            #expect(props[key] != nil, "\(name) has no param \(key)")
        }
    }
    #expect(FastPath.allowed.count == 26)
}

/// A model that never answers and never looks at cancellation: it parks until the test lets it go.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        await withCheckedContinuation { c in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiting = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }
    func open() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { waiting = nil }
            return waiting
        }
        c?.resume()
    }
}

@Test func aModelThatIgnoresCancellationStillLosesAtTheDeadline() async {
    let gate = Gate()
    let started = ContinuousClock.now
    let r = await FastPath.route("switch to staging", scope: scope, schemas: schemas, deadline: .milliseconds(50)) { _ in
        await gate.wait()
        return #"{"action":"ctx_set_environment","params":{"name":"staging"}}"#
    }
    let waited = ContinuousClock.now - started
    gate.open()
    #expect(r == .agent)
    // Returning at all is the proof (the model never answers until the gate opens); the bound is
    // loose so a loaded full-suite run does not flake on the timer's scheduling.
    #expect(waited < .seconds(10), "route waited \(waited) for a model that ignores cancellation")
}

@Test func aTerminalPaneIsNeverClosedButCanBeFocused() {
    #expect(FastPath.check(reply: #"{"action":"pane_close","params":{"id":"terminal-1"}}"#,
                           scope: scope, schemas: schemas) == .agent)
    #expect(FastPath.check(reply: #"{"action":"pane_focus","params":{"id":"terminal-1"}}"#, scope: scope, schemas: schemas)
            == .action(name: "pane_focus", params: .object(["id": .string("terminal-1")])))
    // The worked example teaches closing a table pane, not a terminal.
    let instructions = FastPath.instructions(actions: schemas)
    #expect(!instructions.contains(#""pane_close", "params": {"id": "terminal"#))
    #expect(instructions.contains(#""pane_close", "params": {"id": "db-1"}"#))
}

@Test func aValueOutsideItsEnumGoesToTheAgent() {
    #expect(FastPath.check(reply: #"{"action":"pane_open","params":{"kind":"database"}}"#, scope: scope, schemas: schemas) == .agent)
    #expect(FastPath.check(reply: #"{"action":"pane_open","params":{"kind":"db"}}"#, scope: scope, schemas: schemas)
            == .action(name: "pane_open", params: .object(["kind": .string("db")])))
    #expect(FastPath.check(reply: #"{"action":"pane_sort","params":{"pane":"db-1","column":"id","direction":"up"}}"#,
                           scope: scope, schemas: schemas) == .agent)
    #expect(FastPath.check(reply: #"{"action":"pane_sort","params":{"pane":"db-1","column":"id","direction":"desc"}}"#,
                           scope: scope, schemas: schemas)
            == .action(name: "pane_sort", params: .object(["pane": .string("db-1"), "column": .string("id"), "direction": .string("desc")])))
}

@Test func aNumberForAStringParamBecomesItsString() {
    // "page 3": the model answers the page as a number; db_page takes it as a string.
    #expect(FastPath.check(reply: #"{"action":"db_page","params":{"pane":"db-1","to":3}}"#, scope: scope, schemas: schemas)
            == .action(name: "db_page", params: .object(["pane": .string("db-1"), "to": .string("3")])))
    #expect(FastPath.conform(.number(3), to: "string") == .string("3"))
}

@Test func aWholeNumberArrivingAsANumberIsAnInteger() {
    #expect(FastPath.conform(.number(40), to: "integer") == .integer(40))
    #expect(FastPath.conform(.number(40.5), to: "integer") == nil)
}

@Test func aChangesSelectPathOutsideEveryRootGoesToTheAgent() {
    let wide = FastPathScope(files: ["/elsewhere/a.go"], roots: ["/p"])
    #expect(FastPath.check(reply: #"{"action":"editor_changes_select","params":{"path":"/elsewhere/a.go"}}"#,
                           scope: wide, schemas: schemas) == .agent)
}

// 3b-ix walk: "show tables in core" ran with no database and wakil-db refused, because an
// environment with several databases needs one named and the fast path could not name it.
@Test func aDatabaseInScopeIsPassedOnAndOneOutsideItGoesToTheAgent() {
    #expect(FastPath.check(reply: #"{"action":"db_list_tables","params":{"database":"core"}}"#, scope: scope, schemas: schemas)
            == .action(name: "db_list_tables", params: .object(["database": .string("core")])))
    #expect(FastPath.check(reply: #"{"action":"db_read_table","params":{"table":"users","database":"audit"}}"#,
                           scope: scope, schemas: schemas)
            == .action(name: "db_read_table", params: .object(["table": .string("users"), "database": .string("audit")])))
    #expect(FastPath.check(reply: #"{"action":"db_list_tables","params":{"database":"billing"}}"#, scope: scope, schemas: schemas)
            == .agent)
    #expect(FastPath.input("tables in core", scope: scope).contains(#""databases":["core","audit"]"#))
}

// 3b-ix walk, the real 1.5B: "open confirm.go" came back with the path in `line` as well.
@Test func anOptionalParamOfTheWrongTypeIsDroppedAndTheRestRuns() {
    let r = FastPath.check(reply: #"{"action":"editor_open","params":{"line":"api/confirm.go","path":"api/confirm.go"}}"#,
                           scope: scope, schemas: schemas)
    #expect(r == .action(name: "editor_open", params: .object(["path": .string("/p/api/confirm.go")])))
}

// 3b-ix walk, the real 1.5B: "delete the draft bookings" came back as closing the bookings pane.
@Test func aLineThatAsksToDeleteGoesToTheAgentWithoutAskingTheModel() async {
    let asked = Counter()
    for line in ["delete the draft bookings", "Drop the old refunds", "please remove bookings 12"] {
        let r = await FastPath.route(line, scope: scope, schemas: schemas, deadline: .seconds(1)) { _ in
            await asked.bump(); return #"{"action":"pane_close","params":{"id":"db-1"}}"#
        }
        #expect(r == .agent, "\(line)")
    }
    #expect(await asked.count == 0)
    #expect(!FastPath.asksToDelete("open delete_user.go"))
    #expect(!FastPath.asksToDelete("close the db pane"))
}

// 3b-ix walk, the real 1.5B: "open a terminal" came back with `path: "zsh"`.
@Test func aTerminalPathThatIsNotARootIsDropped() {
    #expect(FastPath.check(reply: #"{"action":"term_open","params":{"path":"zsh"}}"#, scope: scope, schemas: schemas)
            == .action(name: "term_open", params: .object([:])))
    #expect(FastPath.check(reply: #"{"action":"term_open","params":{"path":"/p"}}"#, scope: scope, schemas: schemas)
            == .action(name: "term_open", params: .object(["path": .string("/p")])))
}

private actor Counter { var count = 0; func bump() { count += 1 } }
