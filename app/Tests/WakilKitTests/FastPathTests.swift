import Testing
import Foundation
@testable import WakilKit

private let scope = FastPathScope(
    files: ["/p/api/confirm.go", "/p/web/Login.tsx"], roots: ["/p"], projects: ["rafiq", "wakil"],
    environments: ["staging", "qa", "production"], activeEnvironment: "qa",
    tables: ["bookings", "users"],
    panes: [FastPathPane(id: "editor-1", kind: "editor", title: "confirm.go"),
            FastPathPane(id: "db-1", kind: "db", title: "bookings")],
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
