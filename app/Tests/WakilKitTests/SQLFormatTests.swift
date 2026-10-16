import Foundation
import Testing
@testable import WakilKit

private func f(_ s: String) -> String? {
    if case .formatted(let out) = SQLFormat.format(s, dialect: .sql) { return out }
    return nil
}

@Test func clausesBreakOntoTheirOwnLines() {
    #expect(f("select a, b from t where c = 1 order by a limit 5") == """
    select a, b
    from t
    where c = 1
    order by a
    limit 5
    """)
}

@Test func joinsBreakAndKeepTheirOn() {
    #expect(f("SELECT * FROM a LEFT JOIN b ON a.id = b.a_id INNER JOIN c ON c.id = b.c_id") == """
    SELECT *
    FROM a
    LEFT JOIN b ON a.id = b.a_id
    INNER JOIN c ON c.id = b.c_id
    """)
}

@Test func topLevelAndOrIndentUnderWhere() {
    #expect(f("SELECT * FROM t WHERE a = 1 AND b = 2 OR c IN (1, 2)") == """
    SELECT *
    FROM t
    WHERE a = 1
      AND b = 2
      OR c IN (1, 2)
    """)
}

@Test func aLongSelectListGoesOneItemPerLine() {
    let cols = (1...12).map { "column_number_\($0)" }.joined(separator: ", ")
    let out = f("SELECT \(cols) FROM t")!
    #expect(out.hasPrefix("SELECT\n  column_number_1,\n  column_number_2,"))
    #expect(out.hasSuffix("  column_number_12\nFROM t"))
}

@Test func subqueriesIndentTwoSpacesPerLevel() {
    #expect(f("SELECT * FROM t WHERE id IN (SELECT a_id FROM a WHERE x = 1)") == """
    SELECT *
    FROM t
    WHERE id IN (
      SELECT a_id
      FROM a
      WHERE x = 1
    )
    """)
}

@Test func keywordsInsideAStringAreNotBroken() {
    #expect(f("SELECT * FROM t WHERE note = 'SELECT FROM where'") == """
    SELECT *
    FROM t
    WHERE note = 'SELECT FROM where'
    """)
}

@Test func aLineCommentEndsItsLine() {
    let out = f("SELECT a -- the a\nFROM t")!
    #expect(out == "SELECT a -- the a\nFROM t")
}

@Test func formattingIsIdempotentAndKeepsEveryToken() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sql-corpus.txt")
    let corpus = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    for sql in corpus {
        guard let once = f(sql) else { continue }   // unterminated corpus lines are .unchanged
        #expect(f(once) == once)
        let strip = { (s: String) in SQLTokenizer.tokenize(s).filter { $0.kind != .whitespace }.map { "\($0.kind)|\($0.text)" } }
        #expect(strip(once) == strip(sql))
    }
}

@Test func anAgentsMultiLineQueryIsNormalised() {
    #expect(f("SELECT a,\n   b\n\nFROM   t") == "SELECT a, b\nFROM t")
}

@Test func unterminatedInputIsLeftWithAReason() {
    #expect(SQLFormat.format("SELECT 'abc", dialect: .sql)
            == .unchanged(reason: "a string opened at character 8 never closes"))
    #expect(SQLFormat.format("", dialect: .sql) == .unchanged(reason: "there is nothing to format"))
}

@Test func mongoJSONPrettyPrintsInKeyOrder() {
    #expect(SQLFormat.format(#"{"find":"events","filter":{"kind":"a"}}"#, dialect: .mongo) == .formatted("""
    {
      "find": "events",
      "filter": {
        "kind": "a"
      }
    }
    """))
    if case .unchanged(let reason) = SQLFormat.format("{oops", dialect: .mongo) {
        #expect(reason.hasPrefix("not valid JSON"))
    } else { Issue.record("bad JSON must be .unchanged") }
}

@Test func theCaretStaysOnItsToken() {
    let old = "select a from t where b = 1"
    let new = f(old)!
    let caretOnB = (old as NSString).range(of: "b =").location
    let mapped = SQLFormat.mapCaret(caretOnB, from: old, to: new)
    #expect((new as NSString).substring(with: NSRange(location: mapped, length: 3)) == "b =")
}

// Fix round 1 — Ruling 3: touching tokens are never split (only the subquery break after
// `(` and before `)` may insert a newline). Ruling 4: exotic whitespace is byte-exact, and a
// newline between two strings survives (Postgres string continuation).

@Test func aKeywordAfterADotIsNeverAClauseStart() {
    #expect(f("SELECT t.from, t.order FROM t") == "SELECT t.from, t.order\nFROM t")
}

@Test func touchingTokensAreNeverSplit() {
    #expect(f("SELECT*FROM t") == "SELECT*FROM t")
    #expect(f("SELECT $1, @@session.x, COUNT(*), x::text FROM t")
            == "SELECT $1, @@session.x, COUNT(*), x::text\nFROM t")
    #expect(f("SELECT * FROM t WHERE (a=1)AND b=2") == "SELECT *\nFROM t\nWHERE (a=1)AND b=2")
}

@Test func aNewlineBetweenTwoStringsSurvives() {
    #expect(f("SELECT 'a'\n'b' AS x FROM t") == "SELECT 'a'\n'b' AS x\nFROM t")
}

@Test func exoticWhitespaceIsKeptByteExact() {
    #expect(f("SELECT a\u{00A0}b FROM t") == "SELECT a\u{00A0}b\nFROM t")
}

@Test func theCaretIgnoresTrimmedExoticWhitespace() {
    let old = "\u{00A0}select a from t where b = 1"
    let new = f(old)!
    let caretOnB = (old as NSString).range(of: "b =").location
    let mapped = SQLFormat.mapCaret(caretOnB, from: old, to: new)
    #expect((new as NSString).substring(with: NSRange(location: mapped, length: 3)) == "b =")
}

// Final review, item 1: a lone `\r` does not end a line comment, so the text after it stays
// comment text and Format never lays it out as code.

@Test func aCarriageReturnInsideALineCommentIsNotCode() {
    let sql = "DELETE FROM t WHERE id = 5 -- note\rOR 1 = 1"
    let out = f(sql)
    #expect(out == "DELETE FROM t\nWHERE id = 5 -- note\rOR 1 = 1")
    #expect(out?.contains("\n  OR 1 = 1") == false)
}

// Final review, item 2 — Ruling 7: where Wakil's lexing and an engine's could disagree, Format
// leaves the line as typed.

private let backslashReason = "a backslash inside quotes is read differently by MySQL and SQLite, so the line was left as typed"
private let bracketReason = "square-bracket names are read differently across databases, so the line was left as typed"
private let dashReason = "MySQL needs a space after -- for a comment, so the line was left as typed"

@Test func aBackslashInsideQuotesLeavesTheLineAsTyped() {
    #expect(SQLFormat.format("SELECT 'a\\b' FROM t", dialect: .sql) == .unchanged(reason: backslashReason))
    #expect(SQLFormat.format("SELECT `a\\b` FROM t", dialect: .sql) == .unchanged(reason: backslashReason))
    #expect(SQLFormat.format("SELECT 'C:\\', '  two  spaces  ' -- it's", dialect: .sql)
            == .unchanged(reason: backslashReason))
    #expect(SQLFormat.format("SELECT \"a\\\"  b\" -- \"", dialect: .sql) == .unchanged(reason: backslashReason))
    // A backslash in a comment or outside quotes is read alike everywhere.
    #expect(f("SELECT a FROM t -- C:\\") == "SELECT a\nFROM t -- C:\\")
}

@Test func aSquareBracketOutsideQuotesLeavesTheLineAsTyped() {
    #expect(SQLFormat.format("SELECT [a b] FROM t", dialect: .sql) == .unchanged(reason: bracketReason))
    #expect(SQLFormat.format("SELECT [a\"b] ,  c FROM t", dialect: .sql) == .unchanged(reason: bracketReason))
    // Inside a string or a comment it is just a character.
    #expect(f("SELECT '[a]' FROM t -- [b]") == "SELECT '[a]'\nFROM t -- [b]")
}

@Test func aDoubleDashWithoutASpaceLeavesTheLineAsTyped() {
    #expect(SQLFormat.format("SELECT 5--'\n  x  \n' -- '", dialect: .sql) == .unchanged(reason: dashReason))
    #expect(SQLFormat.format("SELECT 5--'\\n  x  \\n' -- '", dialect: .sql) == .unchanged(reason: dashReason))
    #expect(SQLFormat.format("SELECT 1--1 FROM t", dialect: .sql) == .unchanged(reason: dashReason))
    // Followed by whitespace, a line feed or the end of the text, it is a comment everywhere.
    #expect(f("SELECT a -- c\nFROM t") == "SELECT a -- c\nFROM t")
    #expect(f("SELECT a --\tc\nFROM t") == "SELECT a --\tc\nFROM t")
    #expect(f("SELECT a --\nFROM t") == "SELECT a --\nFROM t")
    #expect(f("SELECT a FROM t --") == "SELECT a\nFROM t --")
}

/// Ruling 7: a combining mark merges with ASCII punctuation into one Swift Character, so the
/// tokenizer misses a comment or string start that SQLite and MySQL, lexing bytes, see.
@Test func aCombiningMarkJoinedToPunctuationIsLeftAsTyped() {
    let graphemeReason = "a combining mark is joined to SQL punctuation, which databases read differently, so the line was left as typed"
    #expect(SQLFormat.format("DELETE FROM t WHERE id = 5 -\u{301}- x\nOR 1 = 1", dialect: .sql)
            == .unchanged(reason: graphemeReason))
    // Verified on SQLite: deletes one row as typed, every row once Format moved `OR` off the comment.
    #expect(SQLFormat.format("DELETE FROM t WHERE id = 5 --\u{301} x OR 1 = 1", dialect: .sql)
            == .unchanged(reason: graphemeReason))
    #expect(SQLFormat.format("DELETE FROM t WHERE id = 5 #\u{301} x\nOR 1 = 1", dialect: .sql)
            == .unchanged(reason: graphemeReason))
    #expect(SQLFormat.format("SELECT a FROM t WHERE b = '\u{301}x  y' OR c = 1", dialect: .sql)
            == .unchanged(reason: graphemeReason))
    #expect(SQLFormat.format("DELETE FROM t WHERE id = 5 /\u{301}* x  */ OR 1 = 1", dialect: .sql)
            == .unchanged(reason: graphemeReason))
}

@Test func multiScalarCharactersWithoutAsciiPunctuationStillFormat() {
    #expect(f("SELECT a\r\nFROM t") == "SELECT a\nFROM t")
    #expect(f("SELECT '👨‍👩‍👧' FROM t") == "SELECT '👨‍👩‍👧'\nFROM t")
}
