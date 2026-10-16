import Foundation
import Testing
@testable import WakilKit

private let columns = [PaneColumn(name: "id", type: "int"), PaneColumn(name: "note", type: "text")]
private func row(_ id: Int, _ values: [JSONValue]) -> PaneRow {
    PaneRow(id: id, cells: values.map(PaneCell.init))
}

struct GridCopyTests {
    @Test func aCellKeepsTheValueItWasBuiltFrom() {
        let nested: JSONValue = .object(["a": .integer(1)])
        #expect(PaneCell(nested).value == nested)
        #expect(PaneCell(.null).value == .null)
    }

    @Test func oneCellCopiesAsItsTextAndNullAsEmpty() {
        #expect(gridCopyCell(PaneCell(.string("Omar"))) == "Omar")
        #expect(gridCopyCell(PaneCell(.null)) == "")
    }

    @Test func rowsCopyAsTabSeparatedWithAHeaderInColumnOrder() {
        let text = gridCopyText(columns: columns, rows: [
            row(0, [.integer(1), .string("a")]),
            row(1, [.integer(2), .null]),
        ])
        #expect(text == "id\tnote\n1\ta\n2\t")
    }

    @Test func aFieldWithATabNewlineOrQuoteIsQuotedExcelStyle() {
        let text = gridCopyText(columns: columns, rows: [
            row(0, [.integer(1), .string("a\tb")]),
            row(1, [.integer(2), .string("line1\nline2")]),
            row(2, [.integer(3), .string("say \"hi\"")]),
        ])
        #expect(text == "id\tnote\n1\t\"a\tb\"\n2\t\"line1\nline2\"\n3\t\"say \"\"hi\"\"\"")
    }

    @Test func unicodeAndALargeIntegerSurviveTSV() {
        let text = gridCopyText(columns: columns, rows: [row(0, [.integer(9_007_199_254_740_993), .string("قهوة ☕")])])
        #expect(text == "id\tnote\n9007199254740993\tقهوة ☕")
    }

    @Test func jsonIsAnArrayEvenForOneRowAndKeepsTypes() throws {
        let json = gridCopyJSON(columns: columns, rows: [row(0, [.integer(9_007_199_254_740_993), .null])])
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(parsed == .array([.object(["id": .integer(9_007_199_254_740_993), "note": .null])]))
    }

    @Test func jsonKeepsANestedDocumentAsAnObject() throws {
        let doc: JSONValue = .object(["nights": .integer(3), "addons": .array([.string("parking")])])
        let json = gridCopyJSON(columns: columns, rows: [row(0, [.integer(1), doc])])
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(parsed == .array([.object(["id": .integer(1), "note": doc])]))
    }

    @Test func jsonKeepsEveryColumnWhenNamesRepeat() throws {
        let twin = [PaneColumn(name: "id", type: "int"), PaneColumn(name: "id", type: "int")]
        let json = gridCopyJSON(columns: twin, rows: [row(0, [.integer(1), .integer(2)])])
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(parsed == .array([.object(["id": .integer(1), "id (2)": .integer(2)])]))
    }

    @Test func theRowsCopiedAreTheSelectionWhenTheClickedRowIsInIt() {
        let selection = PaneSelection(anchorRow: 3, anchorColumn: "id", rows: [1, 3])
        #expect(gridCopyRows(selection: selection, clickedRow: 1, rowCount: 5) == [1, 3])
        #expect(gridCopyRows(selection: selection, clickedRow: 4, rowCount: 5) == [4])
        #expect(gridCopyRows(selection: selection, clickedRow: nil, rowCount: 5) == [1, 3])
        #expect(gridCopyRows(selection: .empty, clickedRow: nil, rowCount: 5) == [])
        #expect(gridCopyRows(selection: PaneSelection(anchorRow: 9, anchorColumn: nil, rows: [9]), clickedRow: nil, rowCount: 5) == [])
    }
}
