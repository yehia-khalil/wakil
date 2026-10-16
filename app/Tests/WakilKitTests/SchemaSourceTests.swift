import Testing
import Foundation
@testable import WakilKit

private func schemaTestContext() -> ContextStore.ActiveContext {
    ContextStore.ActiveContext(org: "initech", project: "wakil-acceptance-2", environment: "staging",
                               rootPaths: [], activeProvider: "p", environmentProduction: .undeclared)
}

@Test func schemaSourceListsEveryDatabasesTablesAndColumns() async throws {
    let db = RecordingToolCaller(reply: { name, arguments in
        switch name {
        case "list_databases":
            return .object(["structuredContent": .object(["databases": .array([
                .object(["name": .string("core"), "driver": .string("mysql")])])])])
        case "list_columns":
            return .object(["structuredContent": .object(["tables": .array([
                .object(["table": .string("edit_quote"),
                         "columns": .array([.string("id"), .string("transaction_read_only")])])])])])
        default:
            throw CancellationError()
        }
    })
    let names = try await SchemaSource(db: db).identifiers(for: schemaTestContext())
    #expect(Set(names) == [
        Identifier(text: "edit_quote", kind: .table, origin: "staging · core db", source: .schema),
        Identifier(text: "id", kind: .column, origin: "staging · core db", source: .schema),
        Identifier(text: "transaction_read_only", kind: .column, origin: "staging · core db", source: .schema),
    ])
    let calls = await db.calls
    #expect(calls.map(\.name) == ["list_databases", "list_columns"])
    #expect(calls[1].arguments == .object(["database": .string("core")]))
}

@Test func anUnreachableDatabaseThrowsWhenItIsTheOnlyOne() async {
    let db = RecordingToolCaller(reply: { name, _ in
        if name == "list_databases" {
            return .object(["structuredContent": .object(["databases": .array([.object(["name": .string("core")])])])])
        }
        return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("wakil-db: connection refused")])])])
    })
    await #expect(throws: (any Error).self) {
        _ = try await SchemaSource(db: db).identifiers(for: schemaTestContext())
    }
}

/// Interaction Rule 8: one unreachable database is reported whole and the
/// reachable one's names are kept.
@Test func anUnreachableDatabaseIsReportedAndTheOthersAreKept() async throws {
    let db = RecordingToolCaller(reply: { name, arguments in
        if name == "list_databases" {
            return .object(["structuredContent": .object(["databases": .array([
                .object(["name": .string("core")]), .object(["name": .string("billing")])])])])
        }
        if arguments == .object(["database": .string("billing")]) {
            return .object(["isError": .bool(true), "content": .array([
                .object(["type": .string("text"), "text": .string("wakil-db: connection refused")])])])
        }
        return .object(["structuredContent": .object(["tables": .array([
            .object(["table": .string("edit_quote"), "columns": .array([.string("id")])])])])])
    })
    let gathered = try await SchemaSource(db: db).gather(for: schemaTestContext())
    #expect(Set(gathered.names.map(\.text)) == ["edit_quote", "id"])
    #expect(gathered.failures == ["list_columns billing: wakil-db: connection refused"])
}

/// Ruling 7: a Mongo database's containers are collections, not tables.
@Test func aMongoDatabasesContainersAreCollections() async throws {
    let db = RecordingToolCaller(reply: { name, arguments in
        if name == "list_databases" {
            return .object(["structuredContent": .object(["databases": .array([
                .object(["name": .string("events"), "driver": .string("mongo")]),
                .object(["name": .string("core"), "driver": .string("mysql")])])])])
        }
        let table = arguments == .object(["database": .string("events")]) ? "audit_log" : "edit_quote"
        return .object(["structuredContent": .object(["tables": .array([
            .object(["table": .string(table), "columns": .array([])])])])])
    })
    let names = try await SchemaSource(db: db).identifiers(for: schemaTestContext())
    #expect(Set(names) == [
        Identifier(text: "audit_log", kind: .collection, origin: "staging · events db", source: .schema),
        Identifier(text: "edit_quote", kind: .table, origin: "staging · core db", source: .schema),
    ])
}
