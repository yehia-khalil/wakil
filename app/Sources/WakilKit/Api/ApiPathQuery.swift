import Foundation

/// Amendment 8a — the path box is a VIEW of two regions the draft keeps apart.
///
/// **The draft never stores a `?`.** Path parts and query rows stay separate, so the wire,
/// `read_pane` and every action are unchanged; this file only draws the two as one string of
/// parts and reads that string back. Splitting happens inside literal text alone, so a chip is
/// never cut and always lands in the value it was drawn in.

/// The path box's parts: path, then `?`, then `name=value` rows joined by `&`.
public func apiPathQueryView(path: [ApiPart], query: [ApiQueryRow]) -> [ApiPart] {
    var parts = path
    if !query.isEmpty {
        parts.append(.literal("?"))
        for (index, row) in query.enumerated() {
            parts.append(.literal((index == 0 ? "" : "&") + row.name + "="))
            parts.append(contentsOf: row.value)
        }
    }
    return apiMergedLiterals(parts)
}

/// Adjacent literals join, and empty ones vanish, so the view has one box per run of text.
func apiMergedLiterals(_ parts: [ApiPart]) -> [ApiPart] {
    var out: [ApiPart] = []
    for part in parts {
        if case .literal(let text) = part {
            if text.isEmpty { continue }
            if case .literal(let previous)? = out.last {
                out[out.count - 1] = .literal(previous + text)
                continue
            }
        }
        out.append(part)
    }
    return out
}

let apiQueryNameForbidden: Set<Character> = ["=", "&", "?", "#"]

/// Whether every query row can be shown in the view and parsed back unchanged — **on the wire**,
/// up to empty literals.
///
/// **An empty literal and no part are the same value, so this does not lock on the difference.**
/// `apiMergedLiterals` drops an empty literal while drawing the view, and both put identical
/// bytes on the wire; a row holding `[.literal("")]` round-trips even though `apiPathQueryParse`
/// hands back `[]` rather than that same empty literal. Locking the path box over an invisible
/// part would be wrong — ruling 3.
public func apiPathQueryRoundTrips(_ query: [ApiQueryRow]) -> Bool {
    query.allSatisfy { row in
        !row.name.isEmpty && row.name.allSatisfy { !apiQueryNameForbidden.contains($0) }
            && row.value.allSatisfy { part in
                if case .literal(let text) = part { return !text.contains("&") }
                return true
            }
    }
}

public enum ApiPathQueryRefusal: Error, Equatable {
    case holeInName, namelessRow, forbiddenInName(Character), boundMoved

    /// Operator-facing sentence.
    public var line: String {
        switch self {
        case .holeInName: return "a hole can sit only in a query value"
        case .namelessRow: return "a query row needs a name"
        case .forbiddenInName(let c): return "a query name may not contain \(c)"
        case .boundMoved:
            return "a bound value stays in the region it was dropped in — unbind it to move it"
        }
    }
}

public func apiPathQueryParse(_ parts: [ApiPart])
    -> Result<(path: [ApiPart], query: [ApiQueryRow]), ApiPathQueryRefusal>
{
    enum State { case path, name, value }
    var state = State.path
    var path: [ApiPart] = []
    var rows: [ApiQueryRow] = []
    var name = ""
    var value: [ApiPart] = []
    var pending = ""   // literal text accumulating in the current position

    func flushPending() {
        guard !pending.isEmpty else { return }
        switch state {
        case .path: path.append(.literal(pending))
        case .value: value.append(.literal(pending))
        case .name: break
        }
        pending = ""
    }
    func finishRow() -> ApiPathQueryRefusal? {
        if state == .name { name = pending; pending = "" } else { flushPending() }
        defer { name = ""; value = []; state = .name }
        if name.isEmpty { return value.isEmpty ? nil : .namelessRow }
        rows.append(ApiQueryRow(name: name, value: apiMergedLiterals(value)))
        return nil
    }

    for part in parts {
        guard case .literal(let text) = part else {
            switch state {
            case .path: flushPending(); path.append(part)
            case .value: flushPending(); value.append(part)
            case .name: return .failure(.holeInName)
            }
            continue
        }
        for character in text {
            switch (state, character) {
            case (.path, "?"):
                flushPending(); state = .name
            case (.name, "="):
                name = pending; pending = ""
                if name.isEmpty { return .failure(.namelessRow) }
                state = .value
            case (.name, "&"), (.value, "&"):
                if let refusal = finishRow() { return .failure(refusal) }
            case (.name, let c) where apiQueryNameForbidden.contains(c):
                return .failure(.forbiddenInName(c))
            default:
                pending.append(character)
            }
        }
    }
    if state == .path { flushPending() } else if let refusal = finishRow() { return .failure(refusal) }
    return .success((path: apiMergedLiterals(path), query: rows))
}

/// The one api_set_request a path-box commit sends: path AND query together.
///
/// A bound part is carried as published (W16); `apiPathBoxKeepsItsBindings` has already kept it
/// in its own region.
public func apiPathQueryWrite(path: [ApiPart], query: [ApiQueryRow], pane: String) -> JSONValue {
    .object([
        "pane": .string(pane),
        "path": .array(path.map { apiPartJSON($0, sources: [:]) }),
        "query": .array(query.map { row in
            .object([
                "name": .string(row.name),
                "value": .array(row.value.map { apiPartJSON($0, sources: [:]) }),
            ])
        }),
    ])
}

// MARK: - The path box on screen (Task 4)

/// Whether the path box can be typed into: every query row survives the view's round trip.
///
/// **A bound value no longer locks it** (W16): its chip is not a box, and a commit carries it
/// back in its own region (`apiPathBoxKeepsItsBindings`). Amendment 2's lock is superseded.
/// **An `&` in a query value locks it** (Amendment 8d): the parse would split the value in two.
///
/// **A `?` in a path literal does NOT lock it** (Ruling 23, revising final review M6): the path
/// is edited nowhere else, so a lock would leave the operator no way to fix it. The view already
/// draws what follows that `?` as query, so a commit does what is drawn; `apiPathBoxNote` says so.
public func apiPathBoxIsTypable(_ request: ApiRequestSnapshot) -> Bool {
    // W16: a binding no longer locks the box. Only an `&` in a query value does (8d).
    apiPathQueryRoundTrips(request.query)
}

/// Whether any literal of the path holds a `?` — text the box would read as a query's start.
func apiPathHoldsQuestionMark(_ path: [ApiPart]) -> Bool {
    path.contains { part in
        if case .literal(let text) = part { return text.contains("?") }
        return false
    }
}

/// What the path box says, in amber, while a path literal holds a `?` (Ruling 23).
///
/// **The box stays typable**, and the view already draws the text after the first `?` as query,
/// so the note tells the operator what a commit there will do rather than forbidding it. Only an
/// agent writes such a path — the box's own commit splits at the first `?`.
public let apiPathQuestionNote =
    "the path itself holds a ? — committing here moves what follows it into the Query region"

/// What a read-only path box says when an `&` is why (Amendment 8d).
public let apiPathQueryAmpersandNote = "a query value holds & — edit it in the Query region"

/// The note drawn under the path box, or nothing.
///
/// **The `&` note when an `&` is the one reason the box is locked** — it outranks the `?` note,
/// because it is why nothing can be typed. **The `?` note when a path literal holds one**
/// (Ruling 23), over a box that stays typable.
public func apiPathBoxNote(_ request: ApiRequestSnapshot) -> String? {
    let ampersand = request.query.contains { row in
        row.value.contains { part in
            if case .literal(let text) = part { return text.contains("&") }
            return false
        }
    }
    if ampersand { return apiPathQueryAmpersandNote }
    return apiPathHoldsQuestionMark(request.path) ? apiPathQuestionNote : nil
}

/// Where the view's part at `viewIndex` came from: its field, which of the rows sharing that
/// name, and its index in that row's OWN parts — `api_unbind`'s `region`, `name`, `row` and
/// `index`. `nil` for a literal, which the view merges, and for a position past the end.
///
/// **The draft's index, not the view's.** The view merges literals and drops empty ones, so a
/// chip's position there says nothing about where it sits in its row; an empty literal before
/// a chip still counts here, because `api_unbind` indexes the draft.
public func apiPathQueryOrigin(
    path: [ApiPart], query: [ApiQueryRow], viewIndex: Int
) -> (field: ApiDraftField, row: Int, index: Int)? {
    var origins: [(field: ApiDraftField, row: Int, index: Int)?] = []
    var lastWasLiteral = false
    func add(_ part: ApiPart, _ origin: (field: ApiDraftField, row: Int, index: Int)) {
        if case .literal(let text) = part {
            if text.isEmpty { return }
            if !lastWasLiteral { origins.append(nil) }
            lastWasLiteral = true
        } else {
            origins.append(origin)
            lastWasLiteral = false
        }
    }
    for (index, part) in path.enumerated() { add(part, (.path, 0, index)) }
    if !query.isEmpty {
        add(.literal("?"), (.path, 0, 0))
        var seen: [String: Int] = [:]
        for (rowIndex, row) in query.enumerated() {
            let occurrence = seen[row.name, default: 0]
            seen[row.name] = occurrence + 1
            add(.literal((rowIndex == 0 ? "" : "&") + row.name + "="), (.path, 0, 0))
            for (index, part) in row.value.enumerated() {
                add(part, (.query(row.name), occurrence, index))
            }
        }
    }
    guard origins.indices.contains(viewIndex) else { return nil }
    return origins[viewIndex]
}

/// What one path-box gesture comes to.
public enum ApiPathBoxOutcome: Equatable, Sendable {
    /// The one `api_set_request` to dispatch, path and query together.
    case write(JSONValue)
    /// Refused on screen, in these words, and nothing is dispatched.
    case refused(String)
    /// A commit that parses back to the draft it was typed over (`apiPathBoxWriteIsNoOp`):
    /// nothing to dispatch, and the box's text is the draft's, so the pane forgets it and
    /// re-notes its marks clean — no write lands to do that for it (final review I2).
    case unchanged
}

/// Whether a path-box commit's parse is the draft it was typed over, **on the wire**: equal up
/// to empty literals and adjacent literals, which put the same bytes in the URL.
///
/// **The parse normalises by design** — a trailing `?` is no rows, `&&` is dropped, `a` is
/// `a=` — so `/o?` typed over `/o` writes the draft it already holds. Dispatched, that write
/// changes no part, the view's `onChange(of: parts)` never fires, and the box keeps `/o?` as
/// uncommitted text for ever, refusing every drop, agent write and Query-region write.
public func apiPathBoxWriteIsNoOp(
    request: ApiRequestSnapshot, path: [ApiPart], query: [ApiQueryRow]
) -> Bool {
    func rows(_ rows: [ApiQueryRow]) -> [ApiQueryRow] {
        rows.map { ApiQueryRow(name: $0.name, value: apiMergedLiterals($0.value)) }
    }
    return apiMergedLiterals(path) == apiMergedLiterals(request.path)
        && rows(query) == rows(request.query)
}

/// Whether a path-box parse keeps every binding in the region it came from (W16): the path's
/// in the path, the query's in the query. `api_set_request` refuses a binding its region does
/// not hold, so a parse that moved one is refused here, on screen, rather than as a dispatch
/// error the operator never sees (Review Focus 1).
public func apiPathBoxKeepsItsBindings(
    _ request: ApiRequestSnapshot, path: [ApiPart], query: [ApiQueryRow]
) -> Bool {
    func stay(_ written: [ApiPart], within held: [ApiPart]) -> Bool {
        var pool = ApiHeldBindings(held)
        return written.allSatisfy { part in
            guard case .bound(let bound) = part else { return true }
            return pool.take(ApiBoundIdentity(bound)) != nil
        }
    }
    return stay(path, within: request.path)
        && stay(query.flatMap(\.value), within: request.query.flatMap(\.value))
}

/// The mark that stands for the whole Query region (Ruling 7).
///
/// **No row is named `""`** — `+ query` and the view's parse both refuse a nameless row — so this
/// key never collides with a row's own mark, and `ApiWriteKey.query.overwrites` matches it like
/// any `.query`. **The path box marks it while the cursor is in it** (`apiFocusMarks`, 8a): the
/// path box shows the query and its writes write the query whole, so an agent's query write
/// under the cursor would change the view under the operator's typing.
public let apiQueryRegionMark = ApiDraftField.query("")

// MARK: - Amendment 10a: the path view as its editor holds it

/// The path view, as its editor holds it, parsed back to path and query (8a, 10a).
///
/// **A binding no region holds any more is its hole** (Review Focus 2, preflight M7, ruled):
/// undo can bring a bound token back after its unbind landed, and a write carries a binding but
/// never makes one (W16). The view is taken through `apiHeldAsWritten` first, against the pool
/// of path and query together, so a second copy of one binding is a hole too.
///
/// **A binding carried across the `?` is still refused**, in `boundMoved`'s words: the other
/// region holds it, so it was moved, not unbound, and a move between regions is refused on
/// screen rather than turned silently into a hole the operator did not ask for.
func apiPathViewParsed(
    _ request: ApiRequestSnapshot, view: [ApiPart]
) -> Result<(path: [ApiPart], query: [ApiQueryRow]), ApiPathQueryRefusal> {
    switch apiPathQueryParse(apiHeldAsWritten(request, ApiFieldRow(.path), view)) {
    case .success(let parsed):
        guard apiPathBoxKeepsItsBindings(request, path: parsed.path, query: parsed.query) else {
            return .failure(.boundMoved)
        }
        return .success(parsed)
    case .failure(let refusal):
        return .failure(refusal)
    }
}

/// What the path view's editor writes (8a, 10a): one write of path and query together,
/// refused in the parse's own words (or `boundMoved`'s), or `.unchanged` for a view that
/// parses to the draft it was typed over (`apiPathBoxWriteIsNoOp`).
public func apiPathViewWrite(
    _ request: ApiRequestSnapshot, view: [ApiPart], pane: String
) -> ApiPathBoxOutcome {
    switch apiPathViewParsed(request, view: view) {
    case .success(let parsed):
        if apiPathBoxWriteIsNoOp(request: request, path: parsed.path, query: parsed.query) {
            return .unchanged
        }
        return .write(apiPathQueryWrite(path: parsed.path, query: parsed.query, pane: pane))
    case .failure(let refusal):
        return .refused(refusal.line)
    }
}
