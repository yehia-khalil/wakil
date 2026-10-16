import Foundation

// **Format** (Amendment 8c) re-indents a body and changes nothing else.
//
// It rewrites only the whitespace *between* JSON tokens, at two spaces. Every string and every
// bare scalar is copied byte for byte, and keys keep their order, so `{"z":1,"a":2}` stays in
// that order and `9007199254740993` stays that integer. `JSONSerialization` would lose both,
// which is why it is not used here.
//
// **A chip is one opaque value token.** A hole or a bound value stands where a JSON value
// stands, so a body with holes formats around them. A chip can't be a key, because a key is
// a string, and it can't sit inside a string either: the string would be unterminated in its
// literal.

/// The amber refusal shown when a body does not tokenize as JSON. The body is left unchanged.
public let apiNotJSONLine = "not JSON — nothing formatted"

/// The deepest nesting Format accepts. No body a person writes gets near it, and a deeper one is
/// refused as not JSON, so a pathological body costs bounded work and never takes the app down.
let apiFormatMaxDepth = 512

/// The body re-indented at two spaces, or nil when it does not tokenize as JSON.
public func apiFormatBody(_ parts: [ApiPart]) -> [ApiPart]? {
    guard let tokens = apiBodyTokens(apiMergedLiterals(parts)), !tokens.isEmpty else { return nil }
    return apiFormatTokens(tokens).map(apiMergedLiterals)
}

/// A body's shape, in the plane's words (W13): an object's top-level keys in the order typed, an
/// array's length, or any other JSON value. A hole is a value.
public enum ApiBodyShape: Equatable, Sendable {
    case object([String])
    case array(Int)
    case value
}

/// The body's JSON shape, or `nil` when it does not tokenize as JSON (`apiFormatBody`'s own test).
public func apiBodyJSONShape(_ parts: [ApiPart]) -> ApiBodyShape? {
    guard apiFormatBody(parts) != nil,
          let tokens = apiBodyTokens(apiMergedLiterals(parts)), let first = tokens.first
    else { return nil }
    guard case .punct(let open) = first, open == "{" || open == "[" else { return .value }
    var depth = 0
    var keys: [String] = []
    var commas = 0
    for (index, token) in tokens.enumerated() {
        switch token {
        case .punct(let p) where p == "{" || p == "[": depth += 1
        case .punct(let p) where p == "}" || p == "]": depth -= 1
        case .punct(",") where depth == 1: commas += 1
        case .string(let quoted) where depth == 1 && open == "{":
            if index + 1 < tokens.count, case .punct(":") = tokens[index + 1] {
                keys.append(String(quoted.dropFirst().dropLast()))
            }
        default: break
        }
    }
    return open == "{" ? .object(keys) : .array(tokens.count == 2 ? 0 : commas + 1)
}

// MARK: - Tokens

private enum ApiBodyToken {
    /// One of `{ } [ ] : ,`.
    case punct(Unicode.Scalar)
    /// A string with its quotes, exactly as typed.
    case string(String)
    /// `true`, `false`, `null` or a JSON number, exactly as typed.
    case scalar(String)
    /// A hole or a bound value.
    case chip(ApiPart)
}

private let apiJSONNumber = try! NSRegularExpression(
    pattern: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#)

private func apiIsJSONScalar(_ text: String) -> Bool {
    if text == "true" || text == "false" || text == "null" { return true }
    let range = NSRange(text.startIndex..., in: text)
    return apiJSONNumber.firstMatch(in: text, range: range) != nil
}

private func apiIsScalarRun(_ c: Unicode.Scalar) -> Bool {
    switch c {
    case "A"..."Z", "a"..."z", "0"..."9", "+", "-", ".": return true
    default: return false
    }
}

/// The token stream, or nil on any text that is not a JSON token. The parts must already be
/// merged, so a string can't be cut by a box boundary. Only a chip can cut it, and that is
/// refused.
private func apiBodyTokens(_ parts: [ApiPart]) -> [ApiBodyToken]? {
    var tokens: [ApiBodyToken] = []
    for part in parts {
        guard case .literal(let text) = part else {
            tokens.append(.chip(part))
            continue
        }
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case " ", "\t", "\n", "\r":
                i += 1
            case "{", "}", "[", "]", ":", ",":
                tokens.append(.punct(c))
                i += 1
            case "\"":
                var j = i + 1
                while j < scalars.count, scalars[j] != "\"" {
                    j += scalars[j] == "\\" ? 2 : 1
                }
                guard j < scalars.count else { return nil }  // unterminated in its literal
                tokens.append(.string(String(String.UnicodeScalarView(scalars[i...j]))))
                i = j + 1
            default:
                var j = i
                while j < scalars.count, apiIsScalarRun(scalars[j]) { j += 1 }
                guard j > i else { return nil }
                let run = String(String.UnicodeScalarView(scalars[i..<j]))
                guard apiIsJSONScalar(run) else { return nil }
                tokens.append(.scalar(run))
                i = j
            }
        }
    }
    return tokens
}

// MARK: - Grammar and emit

/// What the walk expects next.
private enum ApiBodyExpect {
    case value
    case key
    /// A value just ended: a comma, the enclosing close bracket, or the end of the body.
    case afterValue
}

/// Checks the grammar and writes the formatted parts in the same pass:
///
///     value  := object | array | string | scalar | chip
///     object := "{" ( string ":" value ( "," string ":" value )* )? "}"
///     array  := "[" ( value ( "," value )* )? "]"
///
/// **It walks with an explicit stack of open brackets rather than recursing.** A recursive
/// descent costs a few frames per level, and the 2c-iv fix round measured it overflowing a
/// 512 KB cooperative-pool thread at under 400 levels in a debug build, so whether Format
/// crashed would depend on the thread that called it. The walk's memory is heap memory, and
/// `apiFormatMaxDepth` bounds it.
private func apiFormatTokens(_ tokens: [ApiBodyToken]) -> [ApiPart]? {
    var out: [ApiPart] = []
    var text = ""  // the running literal, flushed when a chip arrives
    var open: [Unicode.Scalar] = []  // the close bracket each open container is waiting for
    var position = 0
    var expect = ApiBodyExpect.value

    func punct(at index: Int) -> Unicode.Scalar? {
        guard index < tokens.count, case .punct(let p) = tokens[index] else { return nil }
        return p
    }
    func newline() { text += "\n" + String(repeating: " ", count: open.count * 2) }

    while true {
        switch expect {
        case .value:
            guard position < tokens.count else { return nil }
            switch tokens[position] {
            case .string(let s), .scalar(let s):
                text += s
                expect = .afterValue
            case .chip(let part):
                if !text.isEmpty { out.append(.literal(text)) }
                text = ""
                out.append(part)
                expect = .afterValue
            case .punct(let p) where p == "{" || p == "[":
                guard open.count < apiFormatMaxDepth else { return nil }  // an empty one counts too
                let close: Unicode.Scalar = p == "{" ? "}" : "]"
                text.unicodeScalars.append(p)
                if punct(at: position + 1) == close {
                    text.unicodeScalars.append(close)
                    position += 1
                    expect = .afterValue
                } else {
                    open.append(close)
                    newline()
                    expect = p == "{" ? .key : .value
                }
            case .punct:
                return nil
            }
            position += 1
        case .key:
            guard position < tokens.count, case .string(let key) = tokens[position],
                  punct(at: position + 1) == ":" else { return nil }
            text += key + ": "
            position += 2
            expect = .value
        case .afterValue:
            guard let close = open.last else {
                guard position == tokens.count else { return nil }  // trailing tokens
                if !text.isEmpty { out.append(.literal(text)) }
                return out
            }
            switch punct(at: position) {
            case ","?:
                text += ","
                newline()
                expect = close == "}" ? .key : .value
            case close?:
                open.removeLast()
                newline()
                text.unicodeScalars.append(close)
            default:
                return nil
            }
            position += 1
        }
    }
}

/// Whether a refused `Format`'s line (`apiNotJSONLine`) is still drawn: **while the body the
/// screen shows is the one that was refused.** `refused` is that body as shown at the press,
/// `body` the body as shown now (`apiRequestApplying`). A keystroke or an agent's write
/// changes it, and the line goes with the text it was about. The flush of that same text
/// landing does not, so a pause that was running at the press never wipes the line.
public func apiFormatRefusalShows(refused: [ApiPart]?, body: [ApiPart]) -> Bool {
    refused == body
}

// MARK: - Amendment 10a: Format over the held body

/// `Format` over the body as its editor holds it (10a): re-indented, tokens in place, or `nil`
/// when that does not tokenize as JSON. Format is a write, committed like ⌘Return (8c), so
/// the operator formats what they see.
///
/// **A binding the body no longer holds is formatted as its hole** (Review Focus 2, preflight
/// M7; `apiHeldAsWritten`): undo can bring a bound token back after its unbind landed, and
/// `api_set_request` refuses a write that names it, off-screen. A binding the body holds is
/// carried as published (W16).
public func apiFormatBodyWrite(
    draft: ApiRequestSnapshot, pane: String, holding: [ApiPart]
) -> JSONValue? {
    guard let formatted = apiFormatBody(apiHeldAsWritten(draft, ApiFieldRow(.body), holding))
    else { return nil }
    let written: [JSONValue] = formatted.compactMap { part in
        if case .literal(let text) = part, text.isEmpty { return nil }
        return apiPartJSON(part, sources: [:])
    }
    return .object(["pane": .string(pane), "body": .array(written)])
}

/// Whether `Format` over the held body would write the body the draft already holds (final
/// review M7, per field): the pane lets the body go itself and dispatches nothing. Otherwise
/// the body is let go only once Format's write lands: let go at the press, it showed the old
/// draft until then, and lost the text outright had the write been refused.
public func apiFormatIsNoOp(draft: ApiRequestSnapshot, holding: [ApiPart]) -> Bool {
    guard let formatted = apiFormatBody(apiHeldAsWritten(draft, ApiFieldRow(.body), holding))
    else { return false }
    return formatted == apiMergedLiterals(draft.body)
}

/// Whether `Format` is live over the held body: something to format, in a typable body.
public func apiFormatIsEnabled(draft: ApiRequestSnapshot, holding: [ApiPart]) -> Bool {
    apiFieldIsTypable(draft, .body) && !apiDroppingEmptyLiterals(holding).isEmpty
}
