import Foundation

/// Amendment 11 — a cURL command pasted into the path. **Nothing here reads cURL or a shell**:
/// `parse_curl` (Go) has already read the command and `locate_api_url` (Go) has placed its
/// URL. This decides what that means for the pane — fill, switch, or refuse — and words the line.
public struct ApiCurlParsed: Sendable, Equatable {
    public var method: String
    public var url: String
    public var headers: [(name: String, value: String)]
    public var body: String
    public var hasBody: Bool
    /// What `parse_curl` did not carry, by name. Never a value (11d).
    public var dropped: [String]

    init(method: String, url: String, headers: [(name: String, value: String)],
         body: String, hasBody: Bool, dropped: [String]) {
        self.method = method; self.url = url; self.headers = headers
        self.body = body; self.hasBody = hasBody; self.dropped = dropped
    }

    public init(json: JSONValue) throws {
        guard case .object(let o) = json else { throw ApiCurlUnreadable() }
        func string(_ key: String) -> String {
            if case .string(let s)? = o[key] { return s }
            return ""
        }
        method = string("method")
        url = string("url")
        body = string("body")
        if case .bool(let b)? = o["hasBody"] { hasBody = b } else { hasBody = false }
        headers = {
            guard case .array(let items)? = o["headers"] else { return [] }
            return items.compactMap { item in
                guard case .object(let h) = item, case .string(let n)? = h["name"] else { return nil }
                if case .string(let v)? = h["value"] { return (name: n, value: v) }
                return (name: n, value: "")
            }
        }()
        dropped = {
            guard case .array(let items)? = o["dropped"] else { return [] }
            return items.compactMap { item in
                guard case .object(let d) = item, case .string(let n)? = d["name"] else { return nil }
                return n
            }
        }()
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.method == b.method && a.url == b.url && a.body == b.body && a.hasBody == b.hasBody
            && a.dropped == b.dropped && a.headers.count == b.headers.count
            && zip(a.headers, b.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

public struct ApiCurlLocation: Sendable, Equatable {
    public var found: Bool
    public var active: Bool
    public var environment: String
    public var entry: String
    public var path: String
    public var host: String
    public var entries: [String]
    /// The URL has no host to place (scheme-less, or unparsable).
    public var noHost: Bool
    /// Set only when the match forgave a leading `www.`: the host as pasted, and the entry's own.
    public var pastedHost: String
    public var entryHost: String

    init(found: Bool, active: Bool, environment: String, entry: String, path: String,
         host: String, entries: [String], noHost: Bool = false,
         pastedHost: String = "", entryHost: String = "") {
        self.pastedHost = pastedHost; self.entryHost = entryHost
        self.found = found; self.active = active; self.environment = environment
        self.entry = entry; self.path = path; self.host = host; self.entries = entries
        self.noHost = noHost
    }

    public init(json: JSONValue) throws {
        guard case .object(let o) = json else { throw ApiCurlUnreadable() }
        func string(_ key: String) -> String {
            if case .string(let s)? = o[key] { return s }
            return ""
        }
        func flag(_ key: String) -> Bool {
            if case .bool(let b)? = o[key] { return b }
            return false
        }
        found = flag("found"); active = flag("active"); noHost = flag("noHost")
        environment = string("environment"); entry = string("entry")
        path = string("path"); host = string("host")
        pastedHost = string("pastedHost"); entryHost = string("entryHost")
        entries = {
            guard case .array(let items)? = o["entries"] else { return [] }
            return items.compactMap { if case .string(let s) = $0 { return s }; return nil }
        }()
    }
}

struct ApiCurlUnreadable: Error {}

public enum ApiCurlFill: Sendable, Equatable {
    case fill(draft: ApiDraft, switchesEntry: Bool, dropped: [String])
    case refused(String)
}

/// 11a–11c: the whole draft from the command, on the entry its URL names. Refused — and the
/// draft untouched — only when the URL belongs to no entry of this environment.
public func apiCurlFill(_ parsed: ApiCurlParsed, _ location: ApiCurlLocation, current: ApiDraft) -> ApiCurlFill {
    guard !location.noHost else { return .refused("the URL names no host Wakil can read") }
    guard location.found else {
        return .refused("this cURL is for \(location.host); no entry in \(location.environment) "
            + "has that host (entries: \(location.entries.joined(separator: ", ")))")
    }
    guard location.active else {
        return .refused("this cURL is for \(location.entry) in \(location.environment); "
            + "switch environment first")
    }
    var draft = ApiDraft.empty
    draft.entry = location.entry
    draft.method = parsed.method
    // The existing path↔query split. The path stays as pasted; the query is decoded because the
    // send encodes the query map (q.Encode()), so a pasted %20 must not go out as %2520.
    // Form semantics: curl sends `+` verbatim and a server reads it as a space; the send
    // re-encodes the map and would turn `+` into %2B. So `+` is a space BEFORE decoding.
    func decode(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
    switch apiPathQueryParse([.literal(location.path)]) {
    case .failure(let refusal):
        return .refused(refusal.line)
    case .success(let split):
        draft.path = split.path
        draft.query = split.query.map { row in
            ApiQueryRow(name: decode(row.name),
                        value: row.value.map { part in
                            if case .literal(let text) = part {
                                return .literal(decode(text))
                            }
                            return part
                        })
        }
    }
    for header in parsed.headers {
        if header.name.caseInsensitiveCompare("content-type") == .orderedSame {
            draft.contentType = header.value
        } else {
            draft.headers.append(ApiHeaderRow(name: header.name, value: [.literal(header.value)]))
        }
    }
    draft.body = parsed.hasBody && !parsed.body.isEmpty ? [.literal(parsed.body)] : []
    return .fill(draft: draft, switchesEntry: location.entry != current.entry, dropped: parsed.dropped)
}

public func apiCurlFillLine(entry: String, pastedHost: String, entryHost: String, dropped: [String]) -> ApiBindLine {
    var text = "Filled from cURL · \(entry)"
    if !pastedHost.isEmpty && !entryHost.isEmpty { text += " · host \(pastedHost) taken as \(entryHost)" }
    if !dropped.isEmpty { text += " · dropped: " + dropped.joined(separator: ", ") }
    return ApiBindLine(text: text, caution: false)
}

/// 11a: the path editor reads a paste as a cURL command only when, after leading whitespace,
/// it starts with `curl` and a space, tab, newline or `\` line continuation.
public func apiPasteIsCurl(_ text: String) -> Bool {
    // Scalars, not Characters: "\r\n" is one Character equal to neither "\r" nor "\n".
    func blank(_ u: Unicode.Scalar) -> Bool {
        u == "\u{FEFF}" || CharacterSet.whitespacesAndNewlines.contains(u)
    }
    let scalars = Array(text.unicodeScalars.drop(while: blank))
    guard scalars.count > 4, String(String.UnicodeScalarView(scalars[0..<4])) == "curl" else { return false }
    return blank(scalars[4]) || scalars[4] == "\\"
}

/// The line a paste or an Undo leaves behind, from its dispatch outcome: a fill's own line, or
/// the refusal's words in caution's amber.
public func apiCurlFillSummary(_ outcome: ApiBindOutcome) -> ApiBindLine {
    switch outcome {
    case .refused(let message): return ApiBindLine(text: message, caution: true)
    case .result(let value):
        guard case .object(let o) = value, case .string(let line)? = o["line"] else {
            return ApiBindLine(text: "", caution: false)
        }
        return ApiBindLine(text: line, caution: false)
    }
}

/// 11a: whether a paste into the path editor fills the pane rather than landing as text —
/// outside text (`hasClip` is Wakil's own clip, tokens, never a command) that `apiPasteIsCurl`
/// reads as a cURL command.
public func apiPasteFillsFromCurl(hasClip: Bool, plain: String?) -> Bool {
    guard !hasClip, let plain else { return false }
    return apiPasteIsCurl(plain)
}

/// What the pane's result line draws (11a, fix round 1).
public struct ApiPaneResultLines: Sendable, Equatable {
    /// The fill's line (`ApiSnapshot.fillLine`), quiet ink, or none.
    public let fill: String?
    /// Whether **Undo** is drawn beside it.
    public let undo: Bool
    /// The pane's own line — a drop's, or a refused paste's or Undo's — drawn under the fill's.
    public let below: ApiBindLine?

    public init(fill: String?, undo: Bool, below: ApiBindLine?) {
        self.fill = fill
        self.undo = undo
        self.below = below
    }
}

/// **Both draw** (controller ruling, Task 5 fix round 1): the fill's line with its **Undo**, and
/// under it the pane's own line. A refusal forgets nothing, so the fill line still says what the
/// pane holds, and the amber line says why the last act was refused. **Undo** only beside a
/// fill line.
public func apiPaneResultLines(fill: String?, undoable: Bool, bind: ApiBindLine?) -> ApiPaneResultLines {
    ApiPaneResultLines(fill: fill, undo: fill != nil && undoable, below: bind)
}

/// The pane's own line as the snapshot's fill line moves from `old` to `new`: a NEW fill line
/// (an agent's fill, or the operator's) forgets it — it was about a draft the fill replaced.
/// A fill line that stays, or goes, leaves it.
public func apiBindLineAfterFill(_ bind: ApiBindLine?, from old: String?, to new: String?) -> ApiBindLine? {
    guard let new, new != old else { return bind }
    return nil
}

/// Where the path editor's caret goes once it holds a fill (Rule 3): its end, `length`, when a
/// fill owes it and the editor still has the cursor. A cursor the operator moved elsewhere
/// during the fill is left there (Rule 6) — and an editor without the cursor already takes an
/// outside change with the caret at its end (`apiEditorSelection`).
public func apiFillCaret(owed: Bool, focused: Bool, length: Int) -> Range<Int>? {
    guard owed, focused else { return nil }
    return length..<length
}
