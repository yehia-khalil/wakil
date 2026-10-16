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

    /// Words that may lead a JOIN form; they break only when the run ends in `JOIN`.
    static let joinModifiers: Set<String> = ["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL"]

    public static func format(_ text: String, dialect: QueryDialect) -> SQLFormatResult {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unchanged(reason: "there is nothing to format")
        }
        if dialect == .mongo { return formatJSON(text) }
        if let reason = graphemeDisagreement(text) { return .unchanged(reason: reason) }
        let tokens = SQLTokenizer.tokenize(text)
        if let reason = disagreement(tokens) { return .unchanged(reason: reason) }
        if let open = tokens.first(where: \.unterminated) {
            let at = text.utf16.distance(from: text.startIndex, to: open.range.lowerBound) + 1
            let what = open.kind == .string ? "a string" : open.kind == .comment ? "a comment" : "a quoted name"
            return .unchanged(reason: "\(what) opened at character \(at) never closes")
        }
        let out = layout(tokens)
        let strip = { (s: String) in SQLTokenizer.tokenize(s).filter { $0.kind != .whitespace }.map { "\($0.kind)|\($0.text)" } }
        guard strip(out) == strip(text) else {
            return .unchanged(reason: "formatting would have changed the statement, so it was left as typed")
        }
        return .formatted(out)
    }

    /// Ruling 7: the safety rule is only as strong as the tokenizer's agreement with every
    /// engine Wakil ships. Where they could read the text differently, Format declines.
    /// - A backslash in a quoted token: MySQL reads it as an escape, SQLite as a character.
    /// - `[` outside a string or comment: SQLite reads `[…]` as a quoted name.
    /// - `--` not followed by whitespace or the end: MySQL reads it as two minuses.
    static func disagreement(_ tokens: [SQLToken]) -> String? {
        if tokens.contains(where: { ($0.kind == .string || $0.kind == .quotedIdentifier) && $0.text.contains("\\") }) {
            return "a backslash inside quotes is read differently by MySQL and SQLite, so the line was left as typed"
        }
        if tokens.contains(where: { $0.kind != .string && $0.kind != .quotedIdentifier && $0.kind != .comment
                                    && $0.text.contains("[") }) {
            return "square-bracket names are read differently across databases, so the line was left as typed"
        }
        // A `--` comment runs to `\n` or the end, so a bare `--` is followed by one of those.
        // Otherwise the next scalar must be what MySQL takes: whitespace or a control character.
        if tokens.contains(where: { token in
            guard token.kind == .comment, token.text.hasPrefix("--") else { return false }
            let scalars = token.text.unicodeScalars.dropFirst(2)
            guard let after = scalars.first else { return false }
            return after.value > 0x20
        }) {
            return "MySQL needs a space after -- for a comment, so the line was left as typed"
        }
        return nil
    }

    /// Ruling 7, before tokenizing: a combining or prepend mark merges with ASCII punctuation
    /// (`-`, `#`, `/`, `*`, a quote) into one Swift Character, so the tokenizer misses a
    /// comment or string start that SQLite and MySQL, which lex bytes, see. Any multi-scalar
    /// Character holding an ASCII scalar declines, except `\r\n`.
    static func graphemeDisagreement(_ text: String) -> String? {
        let joined = text.contains { c in
            c != "\r\n" && c.unicodeScalars.count > 1 && c.unicodeScalars.contains(where: \.isASCII)
        }
        return joined
            ? "a combining mark is joined to SQL punctuation, which databases read differently, so the line was left as typed"
            : nil
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
    ///
    /// What sits between two tokens in the source decides what may change there:
    /// - **Touching:** nothing is ever inserted, so `@@session.x`, `COUNT(*)`, `$1` and
    ///   `SELECT*FROM` stay as typed, and a touching clause word or `AND`/`OR` neither breaks
    ///   nor changes the clause. The one exception is the subquery break after `(` and
    ///   before `)`, which is safe in every dialect.
    /// - **Exotic whitespace** (anything but space, tab, `\n`, `\r` — NBSP, `\f`, U+2028):
    ///   kept byte-exact and treated like touching; Postgres reads NBSP as part of a name.
    /// - **A newline between two strings** stays a newline: Postgres continues a string
    ///   literal only across one.
    /// A keyword right after `.` is a name (`t.from`), never a clause start.
    /// Leading and trailing whitespace is trimmed.
    static func layout(_ all: [SQLToken]) -> String {
        var tokens: [SQLToken] = []
        var gaps: [String] = []       // the source whitespace before each token
        var pending = ""
        for token in all {
            if token.kind == .whitespace { pending += token.text; continue }
            tokens.append(token); gaps.append(pending); pending = ""
        }
        /// One subquery level. `parens` counts the plain parentheses open inside it.
        struct Level {
            var clause: String?
            var parens = 0
            var longList = false
            var betweenOpen = false
        }
        let words = tokens.map { $0.kind == .keyword ? $0.text.uppercased() : "" }
        var levels = [Level()]
        var out = ""
        var continuation = 0          // tokens left in a multi-word clause start
        var breakNext = false         // set after a line comment

        func indent(_ extra: Int = 0) -> String {
            String(repeating: " ", count: 2 * (levels.count - 1) + extra)
        }

        var openedSubquery = false    // the previous token was a subquery's `(`

        for (k, token) in tokens.enumerated() {
            let word = words[k]
            let gap = gaps[k]
            let exotic = gap.unicodeScalars.contains { !isLayoutSpace($0) }
            // May a break go here? Not between touching tokens, not across exotic whitespace,
            // and not after a `.`.
            let breakable = k > 0 && !gap.isEmpty && !exotic && tokens[k - 1].text != "."
            var lineBreak: String? = breakNext && breakable ? "\n" + indent(2) : nil
            breakNext = false
            var openSubquery = false
            let subqueryHead = openedSubquery && !exotic
            openedSubquery = false

            if continuation > 0 {
                continuation -= 1
            } else if levels[levels.count - 1].parens == 0, breakable || subqueryHead || k == 0,
                      let n = clauseStartLength(at: k, words) {
                continuation = n - 1
                lineBreak = "\n" + indent()
                levels[levels.count - 1].clause = word
                levels[levels.count - 1].betweenOpen = false
                levels[levels.count - 1].longList = word == "SELECT"
                    && indent().count + inlineSelect(tokens, words, from: k).count > 80
            } else if token.text == "(" {
                if k + 1 < tokens.count, words[k + 1] == "SELECT" {
                    openSubquery = true
                } else {
                    levels[levels.count - 1].parens += 1
                }
            } else if token.text == ")" {
                if levels[levels.count - 1].parens > 0 {
                    levels[levels.count - 1].parens -= 1
                } else if levels.count > 1 {
                    levels.removeLast()
                    if !exotic { lineBreak = "\n" + indent() }
                }   // a stray `)` with nothing open stays inline
            } else if levels[levels.count - 1].parens == 0 {
                let level = levels[levels.count - 1]
                if word == "BETWEEN" {
                    levels[levels.count - 1].betweenOpen = true
                } else if word == "AND" || word == "OR",
                          level.clause == "WHERE" || level.clause == "HAVING" {
                    if word == "AND", level.betweenOpen {
                        levels[levels.count - 1].betweenOpen = false
                    } else if breakable {
                        lineBreak = "\n" + indent(2)
                    }
                } else if token.text == ";" {
                    levels[levels.count - 1] = Level()
                }
            }

            // A long select list: its first item, and each item after a top-level comma.
            if lineBreak == nil, breakable, levels[levels.count - 1].longList, levels[levels.count - 1].parens == 0 {
                if tokens[k - 1].text == "," || words[k - 1] == "SELECT" { lineBreak = "\n" + indent(2) }
            }

            if !out.isEmpty {
                if exotic {
                    out += gap
                } else if let lineBreak {
                    out += lineBreak
                } else if gap.contains(where: \.isNewline), tokens[k - 1].kind == .string, token.kind == .string {
                    out += "\n" + indent()
                } else if !gap.isEmpty, !noSpaceBetween(tokens[k - 1], token) {
                    out += " "
                }
            }
            out += token.text

            if openSubquery { levels.append(Level()); openedSubquery = true }
            if token.kind == .comment, token.text.hasPrefix("--") || token.text.hasPrefix("#") {
                breakNext = true
            }
        }
        return out
    }

    /// How many tokens the clause start at `k` spans, or nil if `k` does not start a clause.
    private static func clauseStartLength(at k: Int, _ words: [String]) -> Int? {
        let word = words[k]
        guard !word.isEmpty else { return nil }
        let next = k + 1 < words.count ? words[k + 1] : ""
        if joinModifiers.contains(word) {
            var j = k + 1
            while j < words.count, joinModifiers.contains(words[j]) || words[j] == "OUTER" { j += 1 }
            return j < words.count && words[j] == "JOIN" ? j - k + 1 : nil
        }
        for start in clauseStarts where start[0] == word {
            if start.count == 1 { return word == "UNION" && next == "ALL" ? 2 : 1 }
            if start[1] == next { return 2 }
        }
        return nil
    }

    /// The SELECT clause from `k` to its end, on one line with token-only spacing — used to
    /// measure it. It ignores the source's touching tokens so the measure, and with it the
    /// layout, comes out the same on a second Format.
    private static func inlineSelect(_ tokens: [SQLToken], _ words: [String], from k: Int) -> String {
        var out = tokens[k].text
        var parens = 0
        var j = k + 1
        while j < tokens.count {
            let t = tokens[j]
            if parens == 0, t.text == ")" || t.text == ";" || clauseStartLength(at: j, words) != nil { break }
            if t.text == "(" { parens += 1 } else if t.text == ")" { parens -= 1 }
            if !noSpaceBetween(tokens[j - 1], t) { out += " " }
            out += t.text
            j += 1
        }
        return out
    }

    private static func isLayoutSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    private static func noSpaceBetween(_ a: SQLToken, _ b: SQLToken) -> Bool {
        (b.kind == .punctuation && [",", ")", ".", ";"].contains(b.text))
            || (a.kind == .punctuation && (a.text == "(" || a.text == "."))
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
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var depth = 0
        var inString = false
        var escaped = false
        func newline() {
            out.append("\n")
            out.append(contentsOf: String(repeating: "  ", count: depth).unicodeScalars)
        }
        func nextSignificant(after i: Int) -> Unicode.Scalar? {
            var j = i + 1
            while j < scalars.count, isJSONSpace(scalars[j]) { j += 1 }
            return j < scalars.count ? scalars[j] : nil
        }
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            defer { i += 1 }
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                out.append(c)
                let close: Unicode.Scalar = c == "{" ? "}" : "]"
                if nextSignificant(after: i) == close {
                    while scalars[i] != close { i += 1 }
                    out.append(close)
                } else {
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth = max(0, depth - 1)
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(contentsOf: ": ".unicodeScalars)
            default:
                if !isJSONSpace(c) { out.append(c) }
            }
        }
        return String(out)
    }

    private static func isJSONSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    /// Maps a caret offset (UTF-16) in `old` to the same token in `new`. Counts the
    /// non-whitespace UTF-16 units before `offset` in `old`, then walks `new` until the same
    /// count is reached. Whitespace is what the tokenizer calls whitespace
    /// (`Character.isWhitespace`), so trimmed NBSP never shifts the caret. Whitespace is the
    /// only thing Format changes, so this lands on the same token and the same position in it.
    public static func mapCaret(_ offset: Int, from old: String, to new: String) -> Int {
        var target = 0
        var pos = 0
        for ch in old where pos < offset {
            let n = ch.utf16.count
            if !ch.isWhitespace { target += min(n, offset - pos) }
            pos += n
        }
        var seen = 0
        pos = 0
        for ch in new {
            let n = ch.utf16.count
            if !ch.isWhitespace {
                if seen + n > target { return pos + (target - seen) }
                seen += n
            }
            pos += n
        }
        return new.utf16.count
    }
}
