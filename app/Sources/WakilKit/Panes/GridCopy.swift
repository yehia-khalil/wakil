import Foundation

/// What the DB grid's Copy puts on the pasteboard. View-only, like the terminal's Copy: it
/// changes no Wakil state, so it is no action — the agent reads the same values with
/// `read_pane`. Only the rows on screen are copied; nothing re-runs the query.

/// One cell, as plain text. NULL is empty, as a spreadsheet shows it.
public func gridCopyCell(_ cell: PaneCell) -> String {
    cell.isNull ? "" : cell.text
}

/// Rows as tab-separated text with a header row, columns in result order — what Sheets,
/// Numbers and Jira paste as a table. A field holding a tab, newline, carriage return or `"`
/// is quoted Excel-style, inner `"` doubled, so the pasted table keeps its shape.
public func gridCopyText(columns: [PaneColumn], rows: [PaneRow]) -> String {
    func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    let header = columns.map { field($0.name) }.joined(separator: "\t")
    let lines = rows.map { row in
        columns.indices.map { index in
            index < row.cells.count ? field(gridCopyCell(row.cells[index])) : ""
        }.joined(separator: "\t")
    }
    return ([header] + lines).joined(separator: "\n")
}

/// Rows as a JSON array of objects keyed by column name — an array even for one row. Values
/// keep their types (`PaneCell.value`): numbers stay numbers, NULL is `null`, a nested document
/// stays an object. Keys are sorted so the output is stable. Repeated column names (a join's
/// `a.id, b.id`) are kept apart in column order: the first keeps its name, the second becomes
/// `id (2)`, the third `id (3)`.
public func gridCopyJSON(columns: [PaneColumn], rows: [PaneRow]) -> String {
    var seen: [String: Int] = [:]
    let keys = columns.map { column -> String in
        let count = (seen[column.name] ?? 0) + 1
        seen[column.name] = count
        return count == 1 ? column.name : "\(column.name) (\(count))"
    }
    let array = JSONValue.array(rows.map { row in
        var object: [String: JSONValue] = [:]
        for (index, key) in keys.enumerated() {
            object[key] = index < row.cells.count ? row.cells[index].value : .null
        }
        return .object(object)
    })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(array), let text = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return text
}

/// Which rows a copy takes, in display order. A right-click on a row inside the selection
/// copies the selection; on a row outside it, that row alone. With no click (⌘C), the
/// selection. Indexes past the rows on screen are dropped.
public func gridCopyRows(selection: PaneSelection, clickedRow: Int?, rowCount: Int) -> [Int] {
    let chosen: Set<Int>
    if let clickedRow, !selection.rows.contains(clickedRow) {
        chosen = [clickedRow]
    } else {
        chosen = selection.rows
    }
    return chosen.filter { $0 >= 0 && $0 < rowCount }.sorted()
}
