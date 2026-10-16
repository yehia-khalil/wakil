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

/// A dialect-tolerant SQL lexer: MySQL backticks, SQLite/Postgres double quotes, `--` and `#`
/// comments to the next `\n`, and `/* */` comments. It does not parse; it only labels.
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
                // Ends only at a Character holding U+000A (`\n` or `\r\n`): SQLite and MySQL
                // end a line comment there and nowhere else. A lone `\r`, U+2028, U+2029 or
                // U+0085 stays inside it.
                emit(.comment, scan(while: { !$0.unicodeScalars.contains("\n") }, from: i))
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
                // The run stops before a `--` or `/*` so the comment branch takes it.
                var j = text.index(after: i)
                while j < text.endIndex, "=<>!+-*/%|&^~:".contains(text[j]) {
                    let n = next(j)
                    if (text[j] == "-" && n == "-") || (text[j] == "/" && n == "*") { break }
                    j = text.index(after: j)
                }
                emit(.op, j)
            }
        }
        return tokens
    }
}
