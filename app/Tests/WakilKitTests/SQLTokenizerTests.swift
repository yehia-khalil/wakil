import Foundation
import Testing
@testable import WakilKit

private let corpus: [String] = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sql-corpus.txt")
    return ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
}()

@Test func joiningTheTokensGivesTheInputBack() {
    #expect(corpus.count >= 30)
    for sql in corpus {
        #expect(SQLTokenizer.tokenize(sql).map(\.text).joined() == sql)
    }
}

@Test func kindsAreAssigned() {
    let tokens = SQLTokenizer.tokenize("SELECT `order`, \"user\" FROM t WHERE n = 'it''s' -- c")
        .filter { $0.kind != .whitespace }
    #expect(tokens.map(\.kind) == [.keyword, .quotedIdentifier, .punctuation, .quotedIdentifier,
                                   .keyword, .identifier, .keyword, .identifier, .op, .string, .comment])
    #expect(tokens[9].text == "'it''s'")
}

@Test func keywordsMatchWhateverCaseWasTyped() {
    #expect(SQLTokenizer.tokenize("select").first?.kind == .keyword)
    #expect(SQLTokenizer.tokenize("SeLeCt").first?.kind == .keyword)
    #expect(SQLTokenizer.tokenize("selector").first?.kind == .identifier)
}

@Test func commentsOfAllThreeShapes() {
    let kinds = { (s: String) in SQLTokenizer.tokenize(s).filter { $0.kind == .comment }.map(\.text) }
    #expect(kinds("a -- x\nb") == ["-- x"])
    #expect(kinds("a # x\nb") == ["# x"])
    #expect(kinds("a /* x\ny */ b") == ["/* x\ny */"])
}

@Test func numbersInEveryForm() {
    let nums = SQLTokenizer.tokenize("1 1.5 .5 1e3 1.5e-3").filter { $0.kind == .number }.map(\.text)
    #expect(nums == ["1", "1.5", ".5", "1e3", "1.5e-3"])
}

@Test func anUnterminatedStringRunsToTheEndAndIsMarked() {
    let tokens = SQLTokenizer.tokenize("SELECT 'abc")
    #expect(tokens.last?.kind == .string)
    #expect(tokens.last?.text == "'abc")
    #expect(tokens.last?.unterminated == true)
    #expect(SQLTokenizer.tokenize("a /* open").last?.unterminated == true)
    #expect(SQLTokenizer.tokenize("a `open").last?.unterminated == true)
}

@Test func emptyInputHasNoTokens() {
    #expect(SQLTokenizer.tokenize("").isEmpty)
}

@Test func aLongQueryTokenizesQuickly() {
    let long = Array(repeating: "SELECT a, b FROM t WHERE c = 'x' AND d > 1", count: 200).joined(separator: " UNION ALL ")
    let start = Date()
    #expect(SQLTokenizer.tokenize(long).count > 2000)
    #expect(Date().timeIntervalSince(start) < 0.5)
}

private func shape(_ s: String) -> [(SQLTokenKind, String)] {
    SQLTokenizer.tokenize(s).map { ($0.kind, $0.text) }
}

@Test func aLineCommentEndsAtCRLF() {
    let tokens = SQLTokenizer.tokenize("x -- c\r\nSELECT 1")
    #expect(tokens.map(\.text).joined() == "x -- c\r\nSELECT 1")
    let kept = tokens.filter { $0.kind != .number && !($0.kind == .whitespace && $0.text == " ") }
    #expect(kept.map(\.kind) == [.identifier, .comment, .whitespace, .keyword])
    #expect(kept.map(\.text) == ["x", "-- c", "\r\n", "SELECT"])
}

@Test func aCommentOpenerIsNeverGluedIntoAnOperator() {
    let a = shape("a=-- c\nb")
    #expect(a.map(\.1) == ["a", "=", "-- c", "\n", "b"])
    #expect(a[1].0 == .op && a[2].0 == .comment)
    let b = SQLTokenizer.tokenize("a>/* c */ 1")
    #expect(b[1].kind == .op && b[1].text == ">")
    #expect(b[2].kind == .comment && b[2].text == "/* c */")
}

@Test func tokensJoinBackForAwkwardInputs() {
    for sql in ["SELECT 'a\\", "a\r\nb", "SELECT '\u{1F600}' FROM t", "SELECT e\u{301} FROM t",
                "a=-- c\nb", "a>/* c */ 1", "a--b", "a=/*", "x -- c\r\nSELECT 1"] {
        #expect(SQLTokenizer.tokenize(sql).map(\.text).joined() == sql)
    }
}

// Final review, item 1: SQLite and MySQL end a `--` or `#` comment only at `\n`. A lone `\r`,
// U+2028, U+2029 or U+0085 stays inside the comment, or Format turns comment text into code.

@Test func aLineCommentEndsOnlyAtALineFeed() {
    let sql = "DELETE FROM t WHERE id = 5 -- note\rOR 1 = 1"
    let tokens = SQLTokenizer.tokenize(sql)
    #expect(tokens.last?.kind == .comment)
    #expect(tokens.last?.text == "-- note\rOR 1 = 1")
    #expect(tokens.last?.range.upperBound == sql.endIndex)
    for end in ["\r", "\u{2028}", "\u{2029}", "\u{0085}"] {
        #expect(SQLTokenizer.tokenize("a -- c\(end)b").last?.text == "-- c\(end)b")
        #expect(SQLTokenizer.tokenize("a # c\(end)b").last?.text == "# c\(end)b")
    }
    #expect(SQLTokenizer.tokenize("a # c\nb").last?.text == "b")
}
