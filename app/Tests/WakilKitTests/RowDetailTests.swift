import Foundation
import Testing
@testable import WakilKit

private func fields(_ values: [(String, JSONValue)]) -> [RowDetailField] {
    rowDetailFields(
        columns: values.map { PaneColumn(name: $0.0, type: "") },
        row: PaneRow(id: 0, cells: values.map { PaneCell($0.1) }))
}

struct RowDetailTests {
    @Test func everyColumnIsAFieldInResultOrder() {
        let result = fields([("id", .integer(4102)), ("guest", .string("Omar K."))])
        #expect(result.map(\.name) == ["id", "guest"])
        #expect(result.map(\.display) == ["4102", "Omar K."])
    }

    @Test func nullIsMarkedAndHasNoText() {
        let field = fields([("notes", .null)])[0]
        #expect(field.isNull)
        #expect(field.display == "")
        #expect(!field.isJSON)
    }

    @Test func aNestedDocumentIsPrettyPrinted() {
        let field = fields([("payload", .object(["nights": .integer(3), "addons": .array([.string("parking")])]))])[0]
        #expect(field.isJSON)
        #expect(field.display == "{\n  \"addons\" : [\n    \"parking\"\n  ],\n  \"nights\" : 3\n}")
    }

    @Test func aTextValueHoldingAnObjectOrArrayIsPrettyPrinted() {
        let field = fields([("payload", .string("  {\"b\":1,\"a\":[2]} "))])[0]
        #expect(field.isJSON)
        #expect(field.display == "{\n  \"a\" : [\n    2\n  ],\n  \"b\" : 1\n}")
    }

    @Test func textThatOnlyLooksLikeJSONStaysText() {
        for raw in ["42", "true", "\"quoted\"", "[oops", "{not json}", "null"] {
            let field = fields([("v", .string(raw))])[0]
            #expect(!field.isJSON, "\(raw) should stay text")
            #expect(field.display == raw)
        }
    }

    @Test func unicodeIsKeptAsIs() {
        #expect(fields([("note", .string("قهوة ☕ — late"))])[0].display == "قهوة ☕ — late")
    }

    @Test func aRowShorterThanItsColumnsGivesEmptyFields() {
        let result = rowDetailFields(
            columns: [PaneColumn(name: "a", type: ""), PaneColumn(name: "b", type: "")],
            row: PaneRow(id: 0, cells: [PaneCell(.integer(1))]))
        #expect(result.map(\.display) == ["1", ""])
    }

    @Test func repeatedColumnNamesGiveDistinctFields() {
        let result = rowDetailFields(
            columns: [PaneColumn(name: "id", type: ""), PaneColumn(name: "id", type: "")],
            row: PaneRow(id: 0, cells: [PaneCell(.integer(1)), PaneCell(.integer(2))]))
        #expect(result.map(\.name) == ["id", "id"])
        #expect(result.map(\.id) == [0, 1])
        #expect(result.map(\.display) == ["1", "2"])
    }
}
