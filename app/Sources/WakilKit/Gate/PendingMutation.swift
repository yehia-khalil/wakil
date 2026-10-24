import Foundation

/// One mutation that `writeGate` refused for want of a confirmation, held
/// while a human decides.
///
/// It carries the `params` it was dispatched with, verbatim, because the
/// approval path re-dispatches *this* call rather than reconstructing one
/// from the fields below. A reconstruction could differ from what was
/// refused, which would mean the operator confirmed one statement and
/// another ran.
///
/// `statement` and `database` are projections of `params` for the surface
/// to render, not the source of truth. `affectsEveryRow` likewise: it comes
/// from `wakilcore.MutationAffectsEveryRow`'s advisory scan, is used only to
/// render a warning line, and never decides anything.
public struct PendingMutation: Sendable, Equatable, Identifiable {
    public let id: String
    public let action: String
    public let params: JSONValue
    public let database: String?
    public let statement: String
    public let affectsEveryRow: Bool
    /// Who proposed it. Both origins park in the same broker and are
    /// confirmed through the same surface — one confirmation mechanism,
    /// not two — but the surface says which, because "the agent wants to
    /// delete these rows" and "you asked to delete these rows" are
    /// different things to be reading at 6pm.
    public let origin: ActionOrigin
    /// Where it waits: the agent's own place, or the screen's for the operator's. The broker
    /// holds one proposal per slot (`slot`), and the plane draws only the screen's.
    public let place: Place
    /// The conversation within `place` that proposed it; nil when none is named.
    public let conversation: String?

    /// Where the broker parks it: an agent's proposal in its conversation's slot, the
    /// operator's in the place's own slot (conversation nil), whatever conversation is named.
    public var slot: ProposalSlot {
        assert(origin != .agent || conversation != nil, "an agent's proposal names its conversation")
        return ProposalSlot(place: place, conversation: origin == .agent ? conversation : nil)
    }

    public init(
        id: String = UUID().uuidString,
        action: String,
        params: JSONValue,
        database: String?,
        statement: String,
        affectsEveryRow: Bool,
        origin: ActionOrigin,
        place: Place,
        conversation: String? = nil
    ) {
        self.id = id
        self.action = action
        self.params = params
        self.database = database
        self.statement = statement
        self.affectsEveryRow = affectsEveryRow
        self.origin = origin
        self.place = place
        self.conversation = conversation
    }
}

/// How a parked proposal ended.
///
/// `.expired` is deliberately distinct from `.cancelled`: "you were
/// refused" and "nobody was at the keyboard" are different facts, and an
/// agent told the first when the second is true will go looking for a
/// permission to ask for instead of simply trying again.
public enum ConfirmationDecision: Sendable, Equatable {
    case approved
    case cancelled
    /// Only an operator's proposal can expire; an agent's waits until answered (R1).
    case expired
    /// Another proposal was already parked in the same place. The new one was never shown to
    /// anyone and never ran.
    case busy
}

/// Whether an `UPDATE` or `DELETE` carries no `WHERE`, and so touches every
/// row. A Swift mirror of `wakilcore.MutationAffectsEveryRow`, duplicated
/// deliberately: it exists only to render a warning line, and reaching
/// across the MCP boundary for that would mean a round trip before the
/// confirmation plane could appear.
///
/// **Advisory only, and nothing may make it otherwise.** A wrong answer
/// produces a missing or a spurious warning beside a statement the operator
/// is reading in full anyway — never a blocked legitimate write. The Go
/// gate is what refuses statements; this only decorates one.
///
/// **Comments are stripped before the scan, exactly as the Go original
/// strips them, and that is not a detail.** `DELETE FROM t -- WHERE id=1`
/// is a statement that really does delete every row: the `WHERE` is
/// commented out and the engine never sees it. A scan of the raw text finds
/// the word, concludes there is a `WHERE`, and suppresses the warning on
/// the one statement shape most in need of it —
/// `internal/wakilcore/mutation_test.go` singles that case out for exactly
/// this reason. `MutationAffectsEveryRowTests` ports that test's whole
/// fixture table so the two implementations cannot drift apart in silence
/// again.
///
/// A `WHERE` inside a STRING LITERAL still suppresses the warning
/// (`UPDATE t SET note='WHERE'` → `false`), and Go agrees. That is an
/// UNDER-warning, and under-warning is the safe direction here: the
/// operator is shown the full statement either way, so the cost is a
/// missing decoration, while over-warning on ordinary statements would
/// train them to dismiss the warning that matters.
public func mutationAffectsEveryRow(_ statement: String) -> Bool {
    let clean = stripSQLComments(statement).uppercased()
    let verb = clean.drop(while: { $0.isWhitespace }).prefix(while: { $0.isLetter })
    guard verb == "UPDATE" || verb == "DELETE" else { return false }
    return clean.range(of: #"\bWHERE\b"#, options: .regularExpression) == nil
}

/// Removes dead SQL comment spans in one left-to-right pass that tracks
/// quoted-span state. A Swift mirror of `wakilcore.stripSQLComments`,
/// duplicated for the reason `mutationAffectsEveryRow` is: it exists so the
/// confirmation plane can decorate a statement without a round trip to Go.
///
/// **It is NOT a gate and must never become one.** The Go original is Phase
/// 1's read-gate scanner, hardened across five documented engine
/// disagreements, each found by making a real engine do something. This
/// copy reproduces those five rules — where the target engines lex the same
/// bytes differently, it copies the entire remainder verbatim and strips
/// nothing more — but it is checked by nothing except the fixture table
/// ported from `mutation_test.go`, and no security decision rests on it.
/// The bias is the same as the original's, and lands the same way here:
/// leaving text visible can only make a `WHERE` easier to find, i.e. can
/// only under-warn, which is the safe direction for an advisory.
///
/// Every replaced span becomes a single space, so two tokens can never fuse
/// and hide a keyword from the `\b`-anchored scan above.
func stripSQLComments(_ s: String) -> String {
    let bytes = Array(s.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0

    /// Copies everything from `i` to the end and stops. The answer to all
    /// five engine disagreements.
    func giveUp() {
        out.append(contentsOf: bytes[i...])
        i = bytes.count
    }

    while i < bytes.count {
        let c = bytes[i]
        // Quoted spans, whose contents stay VISIBLE to the scan: literal
        // awareness here decides only where a comment starts, and must
        // never become a licence to hide text.
        if c == UInt8(ascii: "'") || c == UInt8(ascii: "\"") || c == UInt8(ascii: "`") {
            let end = scanQuotedSpan(bytes, from: i, backslashEscapes: false)
            guard scanQuotedSpan(bytes, from: i, backslashEscapes: true) == end else {
                // The two readings disagree about where this literal ends,
                // so every byte after it is of unknown status. (Go's third
                // disagreement: MySQL's default `sql_mode` escapes with a
                // backslash and SQLite does not.)
                giveUp()
                continue
            }
            out.append(contentsOf: bytes[i..<end])
            i = end
            continue
        }
        // "#" is a dead comment to MySQL and live text to SQLite/Postgres
        // (Go's second disagreement); "[ ... ]" is a SQLite identifier span
        // MySQL does not have at all (Go's fourth).
        if c == UInt8(ascii: "#") || c == UInt8(ascii: "[") {
            giveUp()
            continue
        }
        if startsLineComment(bytes, at: i) {
            out.append(UInt8(ascii: " "))
            i = scanToLineEnd(bytes, from: i)
            continue
        }
        if c == UInt8(ascii: "-"), i + 2 < bytes.count,
           bytes[i + 1] == UInt8(ascii: "-"), bytes[i + 2] != UInt8(ascii: "\n") {
            // `startsLineComment` said no, so MySQL reads this as
            // arithmetic while SQLite and Postgres read the rest of the
            // line as a comment. Go's first disagreement.
            giveUp()
            continue
        }
        if c == UInt8(ascii: "/"), i + 2 < bytes.count,
           bytes[i + 1] == UInt8(ascii: "*"), bytes[i + 2] == UInt8(ascii: "!") {
            // MySQL parses an executable comment's content as LIVE SQL and
            // honours literals inside it, so a "*/" within a literal does
            // not close it; SQLite closes at the first "*/". Go's fifth.
            giveUp()
            continue
        }
        if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
            // An ordinary block comment is dead to every engine and closes
            // at the FIRST "*/" — comments do not nest. An unterminated one
            // leaves the remainder untouched rather than discarding text of
            // unknown intent.
            guard let close = findBlockCommentEnd(bytes, from: i + 2) else {
                giveUp()
                continue
            }
            out.append(UInt8(ascii: " "))
            i = close
            continue
        }
        out.append(c)
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

/// Whether a `--` line comment opens at `i`. Mirrors
/// `wakilcore.startsLineComment`, newline deliberately excluded from the
/// introducer class: for MySQL a `--` comment closes at end of line and the
/// NEXT line is live SQL, so letting `--\n` introduce one would swallow it.
private func startsLineComment(_ bytes: [UInt8], at i: Int) -> Bool {
    guard i + 1 < bytes.count,
          bytes[i] == UInt8(ascii: "-"), bytes[i + 1] == UInt8(ascii: "-") else { return false }
    if i + 2 == bytes.count { return true }
    let c = bytes[i + 2]
    return c <= 0x20 && c != UInt8(ascii: "\n")
}

/// The index of the newline ending the line containing `i`, or the end of
/// input. The newline itself is not consumed, so the text keeps its line
/// structure.
private func scanToLineEnd(_ bytes: [UInt8], from i: Int) -> Int {
    var j = i
    while j < bytes.count, bytes[j] != UInt8(ascii: "\n") { j += 1 }
    return j
}

/// The index just past the quoted span starting at `i`, under one of the
/// two readings of a backslash. `backslashEscapes: false` is SQLite's (and
/// Postgres's standard-conforming) reading; `true` is MySQL's default. A
/// doubled quote closes and reopens under both, which every engine Wakil
/// targets agrees on. An unterminated span runs to end of input.
private func scanQuotedSpan(_ bytes: [UInt8], from i: Int, backslashEscapes: Bool) -> Int {
    let quote = bytes[i]
    var j = i + 1
    while j < bytes.count {
        if backslashEscapes, bytes[j] == UInt8(ascii: "\\") {
            j += 2
            continue
        }
        if bytes[j] != quote {
            j += 1
            continue
        }
        if j + 1 < bytes.count, bytes[j + 1] == quote {
            j += 2   // doubled quote: consume both, stay inside
            continue
        }
        return j + 1
    }
    return bytes.count
}

/// The index just past the first `*/` at or after `from`, or `nil` if there
/// is none.
private func findBlockCommentEnd(_ bytes: [UInt8], from: Int) -> Int? {
    var j = from
    while j + 1 < bytes.count {
        if bytes[j] == UInt8(ascii: "*"), bytes[j + 1] == UInt8(ascii: "/") { return j + 2 }
        j += 1
    }
    return nil
}
