# DB Query Line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The DB pane's query line shows a long query whole (wrapped, up to six lines), structures it by brightness, and formats it on ⌥⇧F or a Format control, without ever changing what runs.

**Architecture:** Three pure units in `WakilKit`: `SQLTokenizer` (lossless), `SQLStyle` (kind → opacity/weight), and `SQLFormat` (whitespace-only reflow guarded by a token-identity check, plus Mongo JSON pretty-print and caret mapping). `WindowModel` learns each database's driver, to choose the dialect. `WakilApp` gains `QueryLineEditor`, an `NSTextView` after `ApiFieldEditor`'s pattern, which replaces the `TextField` in `DBPane.queryLine()`.

**Tech Stack:** Swift 6, SwiftUI plus AppKit (`NSViewRepresentable`, TextKit 2), and swift-testing (`@Test`, `#expect`) in `app/Tests/WakilKitTests`.

**Spec:** `docs/superpowers/specs/2026-10-07-db-query-line-design.md`. Read it before any task.

## Global Constraints

- **No hue.** Styling is opacity steps on the text colour `#e8ecf6` (`Color(red: 0.910, green: 0.925, blue: 0.965)`), plus weight and italic. The table is copied from the spec:

  | Kind | Opacity | Weight | Italic |
  |---|---|---|---|
  | keyword | 1.0 | medium | no |
  | identifier, quotedIdentifier | 0.85 | regular | no |
  | string, number, operator, punctuation | 0.6 | regular | no |
  | comment | 0.4 | regular | yes |

- **Format moves whitespace only.** It never changes keyword case, quoting, comments or literals. Unless the whitespace-free token sequences (kind and text) are identical before and after, the result is `.unchanged`.
- **Keys:** Return runs; ⇧Return inserts a newline; ⌥⇧F formats; Escape leaves the field and keeps the text.
- **Height:** the editor grows from one line to six, then scrolls.
- **Accessibility identifiers:** the editor is `db.<paneId>.queryLine`; the Format control is `db.<paneId>.format`.
- **The "not formatted" line** reads `not formatted: <reason>`, in the refusal line's style. It clears on the next edit and blocks nothing.
- **Unchanged:** `shouldAdoptSubject`, `QueryLineRestore`, the refusal line, the database chooser and `run(text)`.
- **Format is not a registered action** and runs nothing.
- **Commits** carry no `Co-Authored-By` trailer and no "Generated with" line.
- **Tests:** `cd app && swift test --filter <Name>`. The controller alone runs `make app-test`, `make test` and `make e2e`.

## Review Focus

1. **A query containing a string with SQL keywords inside it**, e.g. `WHERE note = 'SELECT FROM x'`. Format must not break inside the string. Pinned in Task 3.
2. **A query the agent wrote with newlines already in it.** Format must normalise it, and formatting twice must equal formatting once. Pinned in Task 3.
3. **A sort or page rewriting the line while the operator has unsaved edits.** The edits must be kept, as today. Pinned in Task 5 by not touching `shouldAdoptSubject`, and covered by the e2e walk.
4. **A Mongo database chosen on the line.** Format must pretty-print JSON and must not apply SQL clause rules. Pinned in Tasks 3 and 4.
5. **A very long single-line query (2,000+ characters).** Restyling on each keystroke must stay responsive. Pinned in Task 1 with a 2,000-token tokenizer test under 50 ms.

---

### Task 1: `SQLTokenizer`

**Files:**
- Create: `app/Sources/WakilKit/Query/SQLTokenizer.swift`
- Create: `app/Tests/WakilKitTests/Fixtures/sql-corpus.txt`
- Test: `app/Tests/WakilKitTests/SQLTokenizerTests.swift`

**Interfaces:**
- Produces:
  - `public enum SQLTokenKind: Equatable, Sendable { case keyword, identifier, quotedIdentifier, string, number, comment, op, punctuation, whitespace }`
  - `public struct SQLToken: Equatable, Sendable { kind: SQLTokenKind; text: String; range: Range<String.Index>; unterminated: Bool }`
  - `public enum SQLTokenizer { static func tokenize(_ text: String) -> [SQLToken]; static let keywords: Set<String> }`. Keywords are stored uppercased and matched case-insensitively.

- [ ] **Step 1: Build the corpus.** Collect at least 30 real SQL statements, one per line, into `sql-corpus.txt`:

```bash
cd /Users/operator/orca/workspaces/wakil/burrfish
grep -rhoE "\"(SELECT|select|INSERT|UPDATE|DELETE|WITH)[^\"]{10,}\"" app/Tests internal cmd e2e/checks --include=*.swift --include=*.go --include=*.jsonl | sed 's/^"//; s/"$//' | sort -u | head -60
```

Paste the useful ones, unescaped, one per line. Add these hand-written edge cases:

```
SELECT `order`, "user" FROM t WHERE note = 'it''s' AND path = 'a\'b' -- trailing
SELECT * FROM t # mysql comment
SELECT /* block */ id FROM t
SELECT 1.5e-3, 42, .5 FROM dual
SELECT 'unterminated
```

- [ ] **Step 2: Write the failing tests**

```swift
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
    #expect(Date().timeIntervalSince(start) < 0.05)
}
```

- [ ] **Step 3: Run and see them fail**

Run: `cd app && swift test --filter SQLTokenizerTests`
Expected: FAIL to compile, with `cannot find 'SQLTokenizer'`.

- [ ] **Step 4: Implement** `SQLTokenizer.swift`:

```swift
import Foundation

public enum SQLTokenKind: Equatable, Sendable {
    case keyword, identifier, quotedIdentifier, string, number, comment, op, punctuation, whitespace
}

/// One lexical piece of a query line, with its exact source text. Joining every token's
/// `text` gives the input back byte for byte — the property Format's safety check and the
/// editor's styling both rest on.
public struct SQLToken: Equatable, Sendable {
    public let kind: SQLTokenKind
    public let text: String
    public let range: Range<String.Index>
    /// A string, quoted identifier or block comment that never closed; it runs to the end.
    public let unterminated: Bool
}

/// A dialect-tolerant SQL lexer: MySQL backticks, SQLite/Postgres double quotes, `--`, `#`
/// and `/* */` comments. It does not parse; it only labels.
public enum SQLTokenizer {
    public static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "BY", "HAVING", "ORDER", "LIMIT", "OFFSET",
        "UNION", "ALL", "INTERSECT", "EXCEPT", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
        "DELETE", "RETURNING", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS",
        "NATURAL", "ON", "USING", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "BETWEEN",
        "EXISTS", "AS", "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END", "ASC", "DESC",
        "WITH", "TRUE", "FALSE", "EXPLAIN", "SHOW", "DESCRIBE", "CREATE", "TABLE", "DROP",
        "ALTER", "INDEX", "PRIMARY", "KEY", "DEFAULT", "COUNT", "SUM", "AVG", "MIN", "MAX",
    ]

    public static func tokenize(_ text: String) -> [SQLToken] {
        var tokens: [SQLToken] = []
        var i = text.startIndex
        func emit(_ kind: SQLTokenKind, _ end: String.Index, unterminated: Bool = false) {
            tokens.append(SQLToken(kind: kind, text: String(text[i..<end]), range: i..<end,
                                   unterminated: unterminated))
            i = end
        }
        func scan(while predicate: (Character) -> Bool, from start: String.Index) -> String.Index {
            var j = start
            while j < text.endIndex, predicate(text[j]) { j = text.index(after: j) }
            return j
        }
        func next(_ j: String.Index) -> Character? {
            let k = text.index(after: j)
            return k < text.endIndex ? text[k] : nil
        }
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace {
                emit(.whitespace, scan(while: { $0.isWhitespace }, from: i))
            } else if (c == "-" && next(i) == "-") || c == "#" {
                emit(.comment, scan(while: { $0 != "\n" }, from: i))
            } else if c == "/", next(i) == "*" {
                if let close = text.range(of: "*/", range: text.index(i, offsetBy: 2)..<text.endIndex) {
                    emit(.comment, close.upperBound)
                } else {
                    emit(.comment, text.endIndex, unterminated: true)
                }
            } else if c == "'" || c == "\"" || c == "`" {
                var j = text.index(after: i)
                var closed = false
                while j < text.endIndex {
                    let d = text[j]
                    if c == "'", d == "\\", next(j) != nil { j = text.index(j, offsetBy: 2); continue }
                    if d == c {
                        if next(j) == c { j = text.index(j, offsetBy: 2); continue }   // doubled quote
                        j = text.index(after: j); closed = true; break
                    }
                    j = text.index(after: j)
                }
                emit(c == "'" ? .string : .quotedIdentifier, closed ? j : text.endIndex, unterminated: !closed)
            } else if c.isNumber || (c == "." && next(i)?.isNumber == true) {
                var j = scan(while: { $0.isNumber || $0 == "." }, from: i)
                if j < text.endIndex, text[j] == "e" || text[j] == "E" {
                    var k = text.index(after: j)
                    if k < text.endIndex, text[k] == "-" || text[k] == "+" { k = text.index(after: k) }
                    if k < text.endIndex, text[k].isNumber { j = scan(while: { $0.isNumber }, from: k) }
                }
                emit(.number, j)
            } else if c.isLetter || c == "_" {
                let end = scan(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }, from: i)
                emit(keywords.contains(text[i..<end].uppercased()) ? .keyword : .identifier, end)
            } else if "(),;.".contains(c) {
                emit(.punctuation, text.index(after: i))
            } else {
                emit(.op, scan(while: { "=<>!+-*/%|&^~:".contains($0) }, from: i).max(text.index(after: i)))
            }
        }
        return tokens
    }
}

private extension String.Index {
    func max(_ other: String.Index) -> String.Index { self > other ? self : other }
}
```

- [ ] **Step 5: Run and see them pass**

Run: `cd app && swift test --filter SQLTokenizerTests`
Expected: PASS. If `kindsAreAssigned` fails on `,` (punctuation) or `=` (op), fix the implementation, not the expectation.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Query/SQLTokenizer.swift app/Tests/WakilKitTests/SQLTokenizerTests.swift app/Tests/WakilKitTests/Fixtures/sql-corpus.txt
git commit -m "Query line: a lossless SQL tokenizer"
```

---

### Task 2: `SQLStyle`

**Files:**
- Create: `app/Sources/WakilKit/Query/SQLStyle.swift`
- Test: `app/Tests/WakilKitTests/SQLStyleTests.swift`

**Interfaces:**
- Consumes: `SQLTokenKind`.
- Produces:
  - `public struct SQLTokenStyle: Equatable, Sendable { opacity: Double; medium: Bool; italic: Bool }`
  - `public enum SQLStyle { static func style(for kind: SQLTokenKind) -> SQLTokenStyle }`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import WakilKit

@Test func eachKindMapsToTheSpecsTable() {
    #expect(SQLStyle.style(for: .keyword) == SQLTokenStyle(opacity: 1.0, medium: true, italic: false))
    for kind: SQLTokenKind in [.identifier, .quotedIdentifier] {
        #expect(SQLStyle.style(for: kind) == SQLTokenStyle(opacity: 0.85, medium: false, italic: false))
    }
    for kind: SQLTokenKind in [.string, .number, .op, .punctuation] {
        #expect(SQLStyle.style(for: kind) == SQLTokenStyle(opacity: 0.6, medium: false, italic: false))
    }
    #expect(SQLStyle.style(for: .comment) == SQLTokenStyle(opacity: 0.4, medium: false, italic: true))
    #expect(SQLStyle.style(for: .whitespace).opacity == 1.0)
}
```

- [ ] **Step 2: Run and see it fail**

Run: `cd app && swift test --filter SQLStyleTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement** `SQLStyle.swift`:

```swift
/// How a query-line token looks: an opacity step on the one text colour, plus weight and
/// italic. **No colour value lives here** — `design-language.md` §5 forbids decorative hue,
/// so structure is carried by brightness alone (operator, 2026-10-07).
public struct SQLTokenStyle: Equatable, Sendable {
    public let opacity: Double
    public let medium: Bool
    public let italic: Bool
    public init(opacity: Double, medium: Bool, italic: Bool) {
        self.opacity = opacity
        self.medium = medium
        self.italic = italic
    }
}

public enum SQLStyle {
    public static func style(for kind: SQLTokenKind) -> SQLTokenStyle {
        switch kind {
        case .keyword: return SQLTokenStyle(opacity: 1.0, medium: true, italic: false)
        case .identifier, .quotedIdentifier: return SQLTokenStyle(opacity: 0.85, medium: false, italic: false)
        case .string, .number, .op, .punctuation: return SQLTokenStyle(opacity: 0.6, medium: false, italic: false)
        case .comment: return SQLTokenStyle(opacity: 0.4, medium: false, italic: true)
        case .whitespace: return SQLTokenStyle(opacity: 1.0, medium: false, italic: false)
        }
    }
}
```

- [ ] **Step 4: Run and see it pass**

Run: `cd app && swift test --filter SQLStyleTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Query/SQLStyle.swift app/Tests/WakilKitTests/SQLStyleTests.swift
git commit -m "Query line: token kinds styled by brightness, never hue"
```

---

### Task 3: `SQLFormat`

**Files:**
- Create: `app/Sources/WakilKit/Query/SQLFormat.swift`
- Test: `app/Tests/WakilKitTests/SQLFormatTests.swift`

**Interfaces:**
- Consumes: `SQLTokenizer`, `SQLToken`, `SQLTokenKind`.
- Produces:
  - `public enum QueryDialect: Equatable, Sendable { case sql, mongo }`
  - `public enum SQLFormatResult: Equatable, Sendable { case formatted(String), unchanged(reason: String) }`
  - `public enum SQLFormat { static func format(_ text: String, dialect: QueryDialect) -> SQLFormatResult; static func mapCaret(_ offset: Int, from old: String, to new: String) -> Int }`
  - Offsets are UTF-16 counts, as `NSTextView` uses.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run and see them fail**

Run: `cd app && swift test --filter SQLFormatTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement** `SQLFormat.swift`. The rules are the spec's §"Format: SQL". Use this structure:

```swift
import Foundation

public enum QueryDialect: Equatable, Sendable { case sql, mongo }

public enum SQLFormatResult: Equatable, Sendable {
    case formatted(String)
    case unchanged(reason: String)
}

/// Whitespace-only reflow of a query line. **The safety rule:** unless the non-whitespace
/// token sequence is identical before and after, the result is `.unchanged` — so Format can
/// never alter what runs (spec, "The safety rule").
public enum SQLFormat {
    static let clauseStarts: [[String]] = [
        ["SELECT"], ["FROM"], ["WHERE"], ["GROUP", "BY"], ["HAVING"], ["ORDER", "BY"],
        ["LIMIT"], ["OFFSET"], ["UNION"], ["INTERSECT"], ["EXCEPT"], ["INSERT", "INTO"],
        ["VALUES"], ["UPDATE"], ["SET"], ["DELETE", "FROM"], ["RETURNING"],
        ["LEFT"], ["RIGHT"], ["INNER"], ["FULL"], ["CROSS"], ["NATURAL"], ["JOIN"],
    ]

    public static func format(_ text: String, dialect: QueryDialect) -> SQLFormatResult {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unchanged(reason: "there is nothing to format")
        }
        if dialect == .mongo { return formatJSON(text) }
        let tokens = SQLTokenizer.tokenize(text)
        if let open = tokens.first(where: \.unterminated) {
            let at = text.utf16.distance(from: text.startIndex, to: open.range.lowerBound) + 1
            let what = open.kind == .string ? "a string" : open.kind == .comment ? "a comment" : "a quoted name"
            return .unchanged(reason: "\(what) opened at character \(at) never closes")
        }
        let out = layout(tokens.filter { $0.kind != .whitespace })
        let strip = { (s: String) in SQLTokenizer.tokenize(s).filter { $0.kind != .whitespace }.map { "\($0.kind)|\($0.text)" } }
        guard strip(out) == strip(text) else {
            return .unchanged(reason: "formatting would have changed the statement, so it was left as typed")
        }
        return .formatted(out)
    }

    /// Lays out non-whitespace tokens:
    /// - a newline before each clause start at the current depth (a `JOIN` form breaks once,
    ///   at its first word; `ON` stays on the line);
    /// - `AND`/`OR` at the top level of WHERE/HAVING get a newline and two extra spaces;
    /// - a SELECT list longer than 80 characters goes one item per line, indented two;
    /// - `(` followed by SELECT opens a subquery: newline, depth + 1, and `)` on its own line
    ///   at the outer depth; any other parenthesis stays inline;
    /// - a `--` or `#` comment is followed by a newline;
    /// - otherwise one space between tokens, none before `,` `)` `.` `;` and none after `(` `.`.
    static func layout(_ tokens: [SQLToken]) -> String {
        // Implement exactly the rules above. Track: depth (Int), a stack of booleans for
        // "this paren is a subquery", the current clause keyword at each depth, and the
        // start index of the current SELECT list so its rendered width can be measured
        // before deciding inline vs one-per-line (render the list inline first; if longer
        // than 80, re-render it with "\n" + indent + "  " before each item).
        // Indentation is two spaces per depth level.
        fatalError("implement per the rules in the doc comment")
    }

    static func formatJSON(_ text: String) -> SQLFormatResult {
        guard let data = text.data(using: .utf8) else { return .unchanged(reason: "not valid JSON") }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            _ = object
        } catch {
            return .unchanged(reason: "not valid JSON: \(error.localizedDescription)")
        }
        // JSONSerialization does not preserve key order, so pretty-print by re-indenting the
        // original text's own tokens: walk the characters, tracking string state, and emit a
        // newline + indent after `{`, `[` and `,`, a newline before `}`/`]`, ": " after a
        // colon, and drop whitespace outside strings. Empty `{}` and `[]` stay on one line.
        return .formatted(reindentJSON(text))
    }

    static func reindentJSON(_ text: String) -> String {
        fatalError("implement per formatJSON's comment")
    }

    /// Maps a caret offset (UTF-16) in `old` to the same token in `new`. Counts the
    /// non-whitespace UTF-16 units before `offset` in `old`, then walks `new` until the same
    /// count is reached. Whitespace is the only thing Format changes, so this lands on the
    /// same token and the same position inside it.
    public static func mapCaret(_ offset: Int, from old: String, to new: String) -> Int {
        let oldUnits = Array(old.utf16)
        let target = oldUnits.prefix(offset).filter { !isSpace($0) }.count
        var seen = 0
        for (i, unit) in new.utf16.enumerated() {
            if seen == target, !isSpace(unit) { return i }
            if !isSpace(unit) { seen += 1 }
        }
        return new.utf16.count
    }

    private static func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }
}
```

Replace both `fatalError` bodies with real implementations that satisfy every test in Step 1. **The tests are the contract.** If a test's expected text seems to conflict with the rules in the doc comment, the spec's §"Format: SQL" decides. Report any such conflict as DONE_WITH_CONCERNS; don't change the expectation silently.

- [ ] **Step 4: Run and see them pass**

Run: `cd app && swift test --filter SQLFormatTests`
Expected: PASS, including the corpus idempotence and token-identity test.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Query/SQLFormat.swift app/Tests/WakilKitTests/SQLFormatTests.swift
git commit -m "Query line: Format reflows whitespace only, and refuses anything else"
```

---

### Task 4: The dialect for a pane's chosen database

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneFetch.swift:181` (beside `databaseNames(fromListResult:)`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`:
  - `public private(set) var databases` near line 1106: add the driver map beside it;
  - `refreshDatabases()` near line 3002;
  - the reset near line 2553 (`databases = []`);
  - `seedForTesting` near line 2218.
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift`, the `orgDerived` set near line 30.
- Test: `app/Tests/WakilKitTests/QueryDialectTests.swift`

**Interfaces:**
- Consumes: `QueryDialect` (Task 3).
- Produces:
  - `public func databaseDrivers(fromListResult result: JSONValue?) -> [String: String]` (name → driver)
  - `WindowModel.databaseDrivers: [String: String]` (`public private(set)`)
  - `WindowModel.queryDialect(pane: Pane) -> QueryDialect`: `.mongo` when the driver of `databaseForQueryLine(pane:)` is `"mongo"`, otherwise `.sql`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

@Test func driversAreReadFromTheListResult() {
    let result: JSONValue = .object(["structuredContent": .object(["databases": .array([
        .object(["name": .string("core"), "driver": .string("mysql")]),
        .object(["name": .string("docs"), "driver": .string("mongo")]),
        .object(["name": .string(""), "driver": .string("sqlite")]),
    ])])])
    #expect(databaseDrivers(fromListResult: result) == ["core": "mysql", "docs": "mongo"])
    #expect(databaseDrivers(fromListResult: nil).isEmpty)
}
```

Then a `WindowModel` test. Use `WindowModel.forTesting` and `seedForTesting(… databases: ["docs"], …)`. Extend `seedForTesting` with `databaseDrivers: [String: String] = [:]`. Seed `["docs": "mongo"]`, open a db pane whose chosen database is `docs` (follow how `QueryTargetPaneTests` or `WindowModelTests` seed a db pane and a database choice), and assert `model.queryDialect(pane:) == .mongo`. A pane on a sqlite database asserts `.sql`.

- [ ] **Step 2: Run and see them fail**

Run: `cd app && swift test --filter QueryDialectTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement.** In `PaneFetch.swift`:

```swift
/// Each listed database's driver, by name — the query line's dialect source.
public func databaseDrivers(fromListResult result: JSONValue?) -> [String: String] {
    guard case .object(let object)? = result,
          case .object(let structured)? = object["structuredContent"],
          case .array(let entries)? = structured["databases"]
    else { return [:] }
    var out: [String: String] = [:]
    for case .object(let fields) in entries {
        guard case .string(let name)? = fields["name"], !name.isEmpty,
              case .string(let driver)? = fields["driver"] else { continue }
        out[name] = driver
    }
    return out
}
```

In `WindowModel`:
- add `public private(set) var databaseDrivers: [String: String] = [:]` next to `databases`;
- set it in `refreshDatabases()` with `databaseDrivers = databaseDrivers(fromListResult: result)`. Use `WakilKit.databaseDrivers(...)` if the property name shadows the function;
- reset it to `[:]` wherever `databases = []` is reset;
- add:

```swift
    /// The query line's dialect: Mongo's JSON spec, or SQL for every other driver.
    public func queryDialect(pane: Pane) -> QueryDialect {
        guard let name = databaseForQueryLine(pane: pane) else { return .sql }
        return databaseDrivers[name] == "mongo" ? .mongo : .sql
    }
```

Add `"databaseDrivers"` to `orgDerived` in `InvalidationContractTests.swift`. It is reset in the same place as `databases`.

- [ ] **Step 4: Run and see them pass**

Run: `cd app && swift test --filter 'QueryDialectTests|InvalidationContractTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneFetch.swift app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/QueryDialectTests.swift app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "Query line: the chosen database's driver picks SQL or Mongo"
```

---

### Task 5: `QueryLineEditor` in the DB pane

**Files:**
- Create: `app/Sources/WakilApp/QueryLineEditor.swift`
- Modify: `app/Sources/WakilApp/DBPane.swift`:
  - `queryLine()` near lines 187-210;
  - add `@State private var notFormatted: String?`;
  - draw the not-formatted line beside the refusal line, near line 80;
  - a new `dialect: QueryDialect` property.
- Modify: `app/Sources/WakilApp/Canvas.swift` near line 275, to pass `dialect: model.queryDialect(pane: pane)`.

**Interfaces:**
- Consumes: `SQLTokenizer`, `SQLStyle`, `SQLFormat`, `QueryDialect`, `WindowModel.queryDialect(pane:)`.
- Produces: no new `WakilKit` API. `WakilApp` has no test target, so the pure logic lives in Tasks 1–4 and this task is checked by `swift build` and the Cover rung.

- [ ] **Step 1: Read the pattern.** Read `app/Sources/WakilApp/ApiFieldEditor.swift` in full, especially:
  - `makeNSView` and `updateNSView`;
  - the `Coordinator` (`textDidChange`, and `textView(_:doCommandBy:)` near line 268);
  - how it sets the identifier only on change (Ruling 15);
  - how it clears undo when outside text is taken (Ruling 12);
  - how it sizes and grows (the body grows to 16 lines, then scrolls).

  `QueryLineEditor` follows the same shape, with no tokens or attachments.

- [ ] **Step 2: Implement `QueryLineEditor`:**

```swift
import AppKit
import WakilKit
import SwiftUI

/// The DB pane's query line: one `NSTextView` (TextKit 2) that wraps, grows to six lines,
/// then scrolls, and restyles by `SQLStyle` on every change. Return runs, ⇧Return breaks a
/// line, ⌥⇧F formats. Every substitution is off — a query is bytes.
struct QueryLineEditor: NSViewRepresentable {
    @Binding var text: String
    let identifier: String
    let dialect: QueryDialect
    let run: (String) -> Void
    /// Called with `.unchanged`'s reason, or `nil` after a successful format or any edit.
    let reportFormat: (String?) -> Void
    /// Bumped by the Format control; each new value formats once.
    let formatRequest: Int

    static let maxLines = 6
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let keywordFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    static let commentFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    static let ink = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 1)

    // makeNSView: an NSScrollView holding an NSTextView built with TextKit 2, as in
    //   ApiFieldEditor — drawsBackground false, isRichText false, allowsUndo true,
    //   isAutomaticQuoteSubstitutionEnabled / DashSubstitution / TextReplacement /
    //   SpellingCorrection / LinkDetection all false, textContainer widthTracksTextView true,
    //   setAccessibilityIdentifier(identifier).
    // updateNSView: if textView.string != text (an outside change: sort, page, agent,
    //   restore), set the string, restyle, and removeAllActions on the undo manager
    //   (Ruling 12). If formatRequest changed since last seen, call coordinator.format().
    //   Set the identifier only when it changed (Ruling 15).
    // sizeThatFits / intrinsic height: line height × min(lines used, maxLines); scroll
    //   beyond that.
    // Coordinator.textDidChange: parent.text = textView.string; restyle; reportFormat(nil).
    // Coordinator.restyle: for each SQLTokenizer token, set font (keywordFont when
    //   style.medium, commentFont when style.italic, else font) and
    //   foregroundColor ink.withAlphaComponent(style.opacity) over the token's NSRange,
    //   preserving the selection. For dialect .mongo, style everything at 0.85.
    // Coordinator.doCommandBy:
    //   insertNewline → if NSApp.currentEvent has .shift: insert "\n" and return true;
    //                   else parent.run(textView.string), return true.
    //   cancelOperation (Escape) → window?.makeFirstResponder(nil), return true.
    // Coordinator.format(): switch SQLFormat.format(textView.string, dialect:) {
    //   .formatted(new): caret = SQLFormat.mapCaret(selectedRange.location, from: old, to: new);
    //       replace the whole string through shouldChangeText/replaceCharacters/didChangeText
    //       so it is ONE undo step; select NSRange(location: caret, length: 0); reportFormat(nil)
    //   .unchanged(reason): reportFormat(reason) }
    // ⌥⇧F: a local NSEvent monitor is NOT used; instead override performKeyEquivalent in a
    //   small NSTextView subclass: if event.modifierFlags ⊇ [.option, .shift] and
    //   event.charactersIgnoringModifiers?.lowercased() == "f" → coordinator.format(), true.
}
```

Write the full implementation that the comments describe. Every behaviour named there is required.

- [ ] **Step 3: Wire it into `DBPane`.**
  - Add `let dialect: QueryDialect`, plus `@State private var notFormatted: String?` and `@State private var formatRequest = 0`.
  - In `queryLine()`, replace the `TextField` with:

```swift
            QueryLineEditor(
                text: $text,
                identifier: "db.\(pane.id).queryLine",
                dialect: dialect,
                run: { submitted in
                    lastRendered = submitted
                    run(submitted)
                },
                reportFormat: { notFormatted = $0 },
                formatRequest: formatRequest)
            Button("Format") { formatRequest += 1 }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
                .accessibilityIdentifier("db.\(pane.id).format")
```

  - Keep the database chooser and the `▸` before it, unchanged.
  - Under the refusal line in `body`, add:

```swift
            if let notFormatted {
                Text("not formatted: \(notFormatted)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
            }
```

  The refusal line uses the reserved red, because it is a refusal. "not formatted" is not a failure of the statement, so it uses the dim text colour.
  - Leave the `.onAppear`, `.onChange(of: pane.fetch)` and `.onChange(of: restore)` blocks unchanged. They keep driving `text` and `lastRendered`.

- [ ] **Step 4: Pass the dialect** in `Canvas.swift`'s `DBPane(` call: `dialect: model.queryDialect(pane: pane),`.

- [ ] **Step 5: Build**

Run: `cd app && swift build`
Expected: `Build complete!` with no new warnings in the touched files.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp/QueryLineEditor.swift app/Sources/WakilApp/DBPane.swift app/Sources/WakilApp/Canvas.swift
git commit -m "Query line: a wrapping, brightness-structured editor with Format"
```

---

### Task 6: The controller's gates

Not for a subagent. The controller runs, in order:

- [ ] `make build`, then `make test`, then `make app-test`. All must be green. The known flakes #312 and #328 are re-run alone and cited.
- [ ] The **Cover** rung (`docs/agents/e2e.md`): the e2e auditor writes checks for a long query shown whole, Return runs, ⇧Return adds a line, ⌥⇧F formats, an outside sort still rewrites the line, and the not-formatted line. Each check is proven red against the merge-base and green on the branch, after the operator confirms the screen is free.
- [ ] Then the operator walks the spec's exit criterion.

---

## Self-review

- **Spec coverage:**
  - Tokenizer: Task 1.
  - Style table: Task 2.
  - Format rules, the safety rule, Mongo, unterminated input, idempotence and caret: Task 3.
  - Dialect from the driver: Task 4.
  - Editor (keys, growth to 6 lines, undo, Ruling 12, identifiers, the not-formatted line, unchanged state logic): Task 5.
  - Interaction Rules: Task 5 plus Cover.
  - Exit criterion: the walk after Task 6.
- **Types:** the same names are used in every task:
  - `SQLToken(kind:text:range:unterminated:)` and `SQLTokenKind`, including `.op`;
  - `SQLTokenStyle(opacity:medium:italic:)`;
  - `SQLFormatResult.formatted` / `.unchanged(reason:)`;
  - `QueryDialect.sql` / `.mongo`;
  - `SQLFormat.mapCaret(_:from:to:)`;
  - `WindowModel.queryDialect(pane:)`.
- **Left to the implementer, deliberately:**
  - `SQLFormat.layout` and `reindentJSON`, which are specified by rules and pinned by eleven tests;
  - `QueryLineEditor`'s AppKit body, which is specified behaviour by behaviour, with `ApiFieldEditor` as the working pattern.

  Each is a contract, not a gap.
