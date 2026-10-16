import Foundation

/// One column of the row detail strip: its name and its whole value. Read-only — editing
/// stays in the grid's double-click path, so a surface keeps one cell editor and one
/// confirmation plane (2c-ii-b check 22).
public struct RowDetailField: Sendable, Equatable, Identifiable {
    public let name: String
    /// The column's position. Names can repeat (`SELECT a.id, b.id`), so this is the identity.
    public let index: Int
    /// The whole value: pretty-printed when `isJSON`, else the cell's text. Never truncated.
    public let display: String
    public let isNull: Bool
    public let isJSON: Bool
    public var id: Int { index }
}

/// The strip's fields for `row`, in result order. A JSON object or array — a nested Mongo
/// document, or a text value that parses as one after trimming whitespace — is pretty-printed
/// with sorted keys. Only objects and arrays count: `"42"`, `"true"` and `"null"` are text a
/// person typed, and reformatting them would show something the cell does not hold.
public func rowDetailFields(columns: [PaneColumn], row: PaneRow) -> [RowDetailField] {
    columns.enumerated().map { index, column in
        guard index < row.cells.count else {
            return RowDetailField(name: column.name, index: index, display: "", isNull: false, isJSON: false)
        }
        let cell = row.cells[index]
        if cell.isNull {
            return RowDetailField(name: column.name, index: index, display: "", isNull: true, isJSON: false)
        }
        if let pretty = rowDetailPrettyJSON(cell.value) {
            return RowDetailField(name: column.name, index: index, display: pretty, isNull: false, isJSON: true)
        }
        return RowDetailField(name: column.name, index: index, display: cell.text, isNull: false, isJSON: false)
    }
}

private func rowDetailPrettyJSON(_ value: JSONValue) -> String? {
    let structured: JSONValue
    switch value {
    case .object, .array:
        structured = value
    case .string(let text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
        else { return nil }
        switch parsed {
        case .object, .array: structured = parsed
        default: return nil
        }
    default:
        return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(structured) else { return nil }
    return String(data: data, encoding: .utf8)
}
