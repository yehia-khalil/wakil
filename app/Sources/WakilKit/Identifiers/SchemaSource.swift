import Foundation

/// The active environment's tables and columns, through `wakil-db`:
/// `list_databases`, then one `list_columns` per database. A database
/// that fails is reported and the rest are kept (Interaction Rule 8);
/// it throws only when `list_databases` fails or every database did.
public struct SchemaSource: IdentifierSource {
    public let kind = IdentifierSourceKind.schema
    public let name = "schema"
    let db: any ToolCaller

    public init(db: any ToolCaller) { self.db = db }

    public func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier] {
        try await gather(for: context).names
    }

    public func gather(for context: ContextStore.ActiveContext) async throws -> IdentifierGathering {
        let listed = try await structured(db.callTool(
            name: "list_databases", arguments: .object([:]), timeout: MCPClient.readReplyTimeout))
        guard case .array(let databases)? = listed["databases"] else { return IdentifierGathering(names: []) }
        var out: [Identifier] = []
        var failures: [String] = []
        var attempted = 0
        for case .object(let database) in databases {
            guard case .string(let dbName)? = database["name"] else { continue }
            attempted += 1
            let origin = "\(context.environment) · \(dbName) db"
            // Ruling 7: Mongo's containers are collections.
            let containerKind: IdentifierKind = database["driver"] == .string("mongo") ? .collection : .table
            let columns: [String: JSONValue]
            do {
                columns = try await structured(db.callTool(
                    name: "list_columns", arguments: .object(["database": .string(dbName)]),
                    timeout: MCPClient.readReplyTimeout))
            } catch let error as CancellationError {
                throw error
            } catch {
                failures.append("list_columns \(dbName): \(error)")
                continue
            }
            guard case .array(let tables)? = columns["tables"] else { continue }
            for case .object(let table) in tables {
                guard case .string(let tableName)? = table["table"] else { continue }
                out.append(Identifier(text: tableName, kind: containerKind, origin: origin, source: .schema))
                if case .array(let names)? = table["columns"] {
                    for case .string(let column) in names {
                        out.append(Identifier(text: column, kind: .column, origin: origin, source: .schema))
                    }
                }
            }
        }
        if !failures.isEmpty, failures.count == attempted {
            throw SchemaSourceError(message: failures.joined(separator: "; "))
        }
        return IdentifierGathering(names: out, failures: failures)
    }

    /// A tool result's `structuredContent`, or a thrown error carrying the
    /// tool's own text when it answered `isError`. (`StandardActions`'
    /// `callChecked` does the same check but is private to that file.)
    private func structured(_ result: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let object) = result else { throw SchemaSourceError(message: "wakil-db answered with no object") }
        if case .bool(true)? = object["isError"] {
            var text = "wakil-db answered isError"
            if case .array(let content)? = object["content"], case .object(let first)? = content.first,
               case .string(let message)? = first["text"] { text = message }
            throw SchemaSourceError(message: text)
        }
        guard case .object(let structured)? = object["structuredContent"] else { return [:] }
        return structured
    }
}

public struct SchemaSourceError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
