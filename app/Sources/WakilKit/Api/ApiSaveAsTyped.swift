import Foundation

/// Amendment 9a — **saved as typed.** A typed change is written `apiTypingPause` after the last
/// keystroke, and at once on Return, on focus leaving the field, and before any gesture that
/// reads or rewrites the draft. **Nothing is ever uncommitted**: a box holds text only for the
/// pause, and for as long as the write carrying it is in flight. Every function here is a value
/// function. `ApiPane` holds the timer and calls them.
///
/// What this retires: Ruling 8's cross-field refusal, Ruling 16's drop refusal, and the row `×`'s
/// wait for a twin's typing. Each existed because typed text could be left behind, and none can
/// be now.

public let apiTypingPause: Duration = .milliseconds(300)

/// What one box's typed text would write right now.
public enum ApiPendingWrite: Equatable, Sendable {
    /// One `api_set_request` to dispatch.
    case write(JSONValue)
    /// The text cannot be written as it stands. Only the path box's parse refuses, and this is
    /// its line, drawn in amber under the URL.
    case refused(String)
    /// The draft already holds what the box shows.
    case unchanged
}

/// The field the cursor is in, and the request as it stood when the cursor arrived — what
/// Escape writes back (9a).
public struct ApiFocusedField: Equatable, Sendable {
    public let box: ApiFieldRow
    public let request: ApiRequestSnapshot

    public init(box: ApiFieldRow, request: ApiRequestSnapshot) {
        self.box = box
        self.request = request
    }
}

/// **Escape writes the field back to what it held when it took focus, as one write.** It is
/// `nil` when the field already holds that. `current` is the stored draft
/// (`apiRestoreCalls`). For a row, the whole region is written with that one row put back and
/// every other row as it is now. The other rows are not this Escape's to undo.
///
/// **A binding is restored only while the region still holds it** (preflight P5). Under W16 a
/// field holding a chip can hold the cursor, and the chip can be unbound while it does. A
/// restore naming that binding would be refused whole (`api_set_request` carries a binding
/// its region holds, never makes one), and Escape would silently do nothing. So a binding the
/// region no longer holds comes back as its hole: Escape restores the text and the hole, and
/// only a drop makes a binding.
public func apiRestoreWrite(
    _ focused: ApiFocusedField, current: ApiRequestSnapshot, pane: String
) -> JSONValue? {
    let then = focused.request
    func json(_ parts: [ApiPart]) -> [JSONValue] { parts.map { apiPartJSON($0, sources: [:]) } }
    switch focused.box.field {
    case .method:
        return nil
    case .path:
        var heldPath = ApiHeldBindings(current.path)
        var heldQuery = ApiHeldBindings(current.query.flatMap(\.value))
        let path = apiKeepingHeld(then.path, &heldPath)
        let query = then.query.map {
            ApiQueryRow(name: $0.name, value: apiKeepingHeld($0.value, &heldQuery))
        }
        guard path != current.path || query != current.query else { return nil }
        return apiPathQueryWrite(path: path, query: query, pane: pane)
    case .body:
        var held = ApiHeldBindings(current.body)
        let body = apiKeepingHeld(then.body, &held)
        guard body != current.body else { return nil }
        return .object(["pane": .string(pane), "body": .array(json(body))])
    case .contentType:
        let text = apiContentTypeText(then)
        guard text != apiContentTypeText(current) else { return nil }
        return apiFieldWrite(field: .contentType, text: text, pane: pane)
    case .query(let name), .header(let name):
        let field = focused.box.field
        let draft = apiDraftForWrite(current)
        let rows: [(name: String, value: [ApiPart])]
        let key: String
        if case .query = field {
            rows = draft.query.map { ($0.name, $0.value) }
            key = "query"
        } else {
            rows = draft.headers.map { ($0.name, $0.value) }
            key = "headers"
        }
        // The region's pool less what the other rows carry back, written as they are now: what
        // this row holds now.
        let now = apiFieldParts(current, field, row: focused.box.row)
        var held = ApiHeldBindings(now)
        let was = apiKeepingHeld(apiFieldParts(then, field, row: focused.box.row), &held)
        guard was != now else { return nil }
        return .object([
            "pane": .string(pane),
            key: apiPartsRegionWrite(rows, editing: name, row: focused.box.row, written: json(was)),
        ])
    }
}

/// `parts` with each binding `held` can still give back kept, and every other binding written as
/// its hole (preflight P5): a restore never names a binding its region no longer holds.
func apiKeepingHeld(_ parts: [ApiPart], _ held: inout ApiHeldBindings) -> [ApiPart] {
    var kept: [ApiPart] = []
    for part in parts {
        guard case .bound(let bound) = part else { kept.append(part); continue }
        kept.append(held.take(ApiBoundIdentity(bound)) != nil ? part : .slot(bound.name))
    }
    return kept
}

/// What Escape in `box` dispatches (9a): **built at its turn on the chain, against the stored
/// draft** (`draft`), never against the boxes. Escape cancels the pause and lets the box go, so
/// the only text that can still differ from the focus-in request is text a write already put
/// on the draft, landed or in flight ahead of this batch.
///
/// Compared against the screen instead (the draft with the boxes applied), a box typed back to
/// its focus-in text hid an earlier write: path `/a`, type X, the pause writes `/aX`, backspace,
/// Escape. The screen read `/a`, so nothing was written, and the draft kept `/aX` for the next
/// Send (final review, Important 1).
///
/// Nothing when the cursor is not in `box`, or the draft already holds the focus-in text.
public func apiRestoreCalls(
    _ focused: ApiFocusedField?, box: ApiFieldRow, draft: ApiRequestSnapshot, pane: String
) -> [(String, JSONValue)] {
    guard let focused, focused.box == box,
          let write = apiRestoreWrite(focused, current: draft, pane: pane)
    else { return [] }
    return [("api_set_request", write)]
}

// MARK: - Amendment 10a: one held part list per field

/// Each field's parts as its editor holds them, while the draft may not hold them yet (9a, 10a).
/// **One entry per field, never per box**: a flush writes the field whole, in one
/// `api_set_request`. Focus marks, `queued`, `takenOver`, Escape's focus-in baseline, the pause
/// and the surface chain stay as 9a has them, one box per field. Every rule below keeps the
/// intent of the index-keyed rule it replaced (9a's per-box text, deleted with Amendment 10's
/// Task 7), and its doc comment names the bug it answers.
public typealias ApiHeld = [ApiFieldRow: [ApiPart]]

/// The held fields in wire order, field then row (preflight D2), so neither the flush's writes
/// nor the applied request depend on a dictionary's hashing.
func apiHeldInWireOrder(_ held: ApiHeld) -> [ApiFieldRow] {
    held.keys.sorted { left, right in
        left.field != right.field ? left.field < right.field : left.row < right.row
    }
}

/// What a field's editor shows when nothing is held: the path view (8a) for the path, a row's
/// value for a query or header row, the body, and the content type's text as one literal.
public func apiHeldView(_ request: ApiRequestSnapshot, _ box: ApiFieldRow) -> [ApiPart] {
    switch box.field {
    case .contentType:
        let text = apiContentTypeText(request)
        return text.isEmpty ? [] : [.literal(text)]
    case .method:
        return []
    case .path, .query, .header, .body:
        return apiFieldViewParts(request, box.field, row: box.row)
    }
}

/// `parts` as a write of `box` would carry them: empty literals dropped, and **each binding the
/// field's region no longer holds written as its hole** (Review Focus 2, preflight M7;
/// `apiKeepingHeld`). Undo can bring a bound token back into an editor after its unbind landed,
/// and a write may carry a binding but never make one (W16), so a second copy of one binding is
/// a hole too.
///
/// **The one place this holds**, so every write path that carries held parts agrees: the
/// pending write, Format (`apiFormatBodyWrite(holding:)`), the request the screen shows (Send's
/// statement) and the path view (`apiPathViewParsed`). The path view's pool is path and query
/// together; a binding carried across its `?` is still refused there (`boundMoved`). A row's
/// pool is that row's own parts, as Escape's restore counts it (`apiRestoreWrite`).
func apiHeldAsWritten(
    _ request: ApiRequestSnapshot, _ box: ApiFieldRow, _ parts: [ApiPart]
) -> [ApiPart] {
    let pool: [ApiPart]
    switch box.field {
    case .path:
        pool = request.path + request.query.flatMap(\.value)
    case .query, .header, .body:
        pool = apiFieldParts(request, box.field, row: box.row)
    case .method, .contentType:
        return apiDroppingEmptyLiterals(parts)
    }
    var held = ApiHeldBindings(pool)
    return apiKeepingHeld(apiDroppingEmptyLiterals(parts), &held)
}

/// Whether `box` names a field the request still has: a query or header row past the last of
/// its name is nobody's (a row removed elsewhere). Its held parts are let go, never written.
private func apiHeldFieldExists(_ request: ApiRequestSnapshot, _ box: ApiFieldRow) -> Bool {
    switch box.field {
    case .query, .header: return apiFieldRows(request, box.field).indices.contains(box.row)
    case .method, .path, .contentType, .body: return true
    }
}

/// What one held field would write right now (9a, one field at a time): `.write` with the
/// field whole, `.refused` for a path view the parse refuses (its amber line), or `.unchanged`
/// when the draft already holds it, up to merging literals.
public func apiPendingWrite(
    _ request: ApiRequestSnapshot, box: ApiFieldRow, holding parts: [ApiPart], pane: String
) -> ApiPendingWrite {
    switch box.field {
    case .method:
        return .unchanged
    case .contentType:
        let text = apiSingleLineText(apiPlainLiteral(parts))
        guard !apiContentTypeCommitIsNoOp(request, text: text) else { return .unchanged }
        return .write(apiFieldWrite(field: .contentType, text: text, pane: pane))
    case .path:
        guard apiPathBoxIsTypable(request) else { return .unchanged }
        switch apiPathViewWrite(request, view: parts, pane: pane) {
        case .write(let params): return .write(params)
        case .refused(let line): return .refused(line)
        case .unchanged: return .unchanged
        }
    case .query, .header, .body:
        guard apiFieldIsTypable(request, box.field), apiHeldFieldExists(request, box) else {
            return .unchanged
        }
        let current = apiFieldParts(request, box.field, row: box.row)
        let written = apiMergedLiterals(apiHeldAsWritten(request, box, parts))
        guard written != apiMergedLiterals(current),
              let params = apiHeldWrite(
                  draft: request, field: box.field, parts: written, pane: pane, row: box.row)
        else { return .unchanged }
        return .write(params)
    }
}

/// The request as the screen shows it: the draft with every held field applied, as written
/// (`apiHeldAsWritten`). **What every gesture and Send's statement are built on.** `except`
/// leaves one field out. A path view the parse refuses, or one that would move a binding across
/// its `?`, applies nothing; nor does a locked path view (8d), nor a row the request lost.
public func apiRequestApplying(
    _ request: ApiRequestSnapshot, held: ApiHeld, except: ApiFieldRow? = nil
) -> ApiRequestSnapshot {
    var path = request.path
    var query = request.query
    var headers = request.headers
    var body = request.body
    for key in apiHeldInWireOrder(held) where key != except {
        let raw = held[key] ?? []
        switch key.field {
        case .path:
            guard apiPathBoxIsTypable(request),
                  case .success(let parsed) = apiPathViewParsed(request, view: raw)
            else { continue }
            path = parsed.path
            query = parsed.query
        case .query(let name):
            let parts = apiHeldAsWritten(request, key, raw)
            var seen = 0
            query = query.map { row in
                guard row.name == name else { return row }
                defer { seen += 1 }
                return seen == key.row ? ApiQueryRow(name: name, value: parts) : row
            }
        case .header(let name):
            let parts = apiHeldAsWritten(request, key, raw)
            var seen = 0
            headers = headers.map { row in
                // `apiRowOccurrence`'s own predicate, so the two count the same rows.
                guard row.name == name, row.isEditable, row.value != nil else { return row }
                defer { seen += 1 }
                return seen == key.row
                    ? ApiHeaderRegionRow(
                        name: name, value: parts, provenance: row.provenance, rowClass: row.rowClass)
                    : row
            }
        case .contentType:
            let text = apiSingleLineText(apiPlainLiteral(raw))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers = headers.map { row in
                guard row.rowClass == .derived else { return row }
                return ApiHeaderRegionRow(
                    name: row.name, value: text.isEmpty ? nil : [.literal(text)],
                    provenance: row.provenance, rowClass: .derived)
            }
        case .body:
            body = apiHeldAsWritten(request, key, raw)
        case .method:
            continue
        }
    }
    return ApiRequestSnapshot(
        method: request.method, origin: request.origin, path: path, query: query,
        headers: headers, body: body)
}

/// One flush's writes, its refusals, and what it wrote.
///
/// **A field whose write is in flight is skipped** (preflight F23). `queued[key]` is the field's
/// parts as the pane dispatched them, **held only while that dispatch is on the chain**: set
/// when the write is dispatched and cleared when that dispatch completes, whatever the outcome
/// (landed, refused, failed). While it is held, a field still at exactly those parts owes
/// nothing new, so a second flush (focus-out just after Send, say) does not put the same write
/// in the journal twice. Once it is cleared, a write that was refused or failed is owed again,
/// and a stale entry can never block parts retyped after an agent's change.
public struct ApiHeldFlush {
    public let writes: [(String, JSONValue)]
    public let refusals: [ApiFieldRow: String]
    /// Each field in `writes`, at the parts it was written with: what the pane adds to `queued`
    /// when it dispatches them, and hands `apiQueuedSettled` when that dispatch completes.
    public let written: ApiHeld
}

/// The writes that make the draft hold what the editors show, in wire order (9a, per field),
/// and each refusal.
///
/// **One write per REGION, never per held field** (Task 4 review, fix round 1). A row's write
/// carries its whole region, so two held rows of one region written one by one, each from the
/// stored draft, overwrote each other: held `a=A′`, `b=B′` over `A`, `B` wrote `[a=A′, b=B]` then
/// `[a=A, b=B′]`, and `A′` was reverted (lost for good once a landing let its field go). The
/// regions (`apiHeldRegion`): the path view with every query row (both write `query`), the
/// header rows, the content type, the body. Each region's write is the stored draft with every
/// held field of it applied as written (`apiRequestApplying`), and records each of them.
///
/// Per field still:
/// - **In flight at exactly these parts** (F23): not recorded, and owes nothing alone. Inside
///   its region's write it is carried at those queued parts, so this write never reverts the
///   one in flight.
/// - **Taken over by a gesture at these parts**: carried at its STORED value, never at the
///   parts the gesture carried, and not recorded.
/// - **Refused** (only the path view's parse): refused alone. The query rows held beside it
///   still write, the query region alone, built on the stored query.
public func apiFlush(
    _ request: ApiRequestSnapshot, held: ApiHeld, pane: String,
    queued: ApiHeld = [:], takenOver: [ApiFieldRow: ApiHeldTakeover] = [:]
) -> ApiHeldFlush {
    var writes: [(String, JSONValue)] = []
    var refusals: [ApiFieldRow: String] = [:]
    var written: ApiHeld = [:]
    var owed: [ApiHeldRegion: ApiHeld] = [:]
    var carried: [ApiHeldRegion: ApiHeld] = [:]
    for key in apiHeldInWireOrder(held) {
        guard let region = apiHeldRegion(key.field), let parts = held[key] else { continue }
        if takenOver[key]?.held == parts { continue }
        // Each owed field's own verdict: a write, a refusal, or nothing to write.
        switch apiPendingWrite(request, box: key, holding: parts, pane: pane) {
        case .write:
            if queued[key] == parts {
                carried[region, default: [:]][key] = parts
            } else {
                owed[region, default: [:]][key] = parts
            }
        case .refused(let line):
            if queued[key] != parts { refusals[key] = line }
        case .unchanged:
            break
        }
    }
    for region in ApiHeldRegion.allCases {
        guard let fields = owed[region], !fields.isEmpty else { continue }
        let together = fields.merging(carried[region] ?? [:]) { owedParts, _ in owedParts }
        let applied = apiRequestApplying(request, held: together.mapValues(apiMergedLiterals))
        writes.append(("api_set_request", apiHeldRegionWrite(
            region, applied: applied, request: request, held: together, pane: pane)))
        written.merge(fields) { _, new in new }
    }
    return ApiHeldFlush(writes: writes, refusals: refusals, written: written)
}

/// The region one held field's write carries whole (fix round 1). The path view writes path
/// and query together, so it shares the query rows' region. `nil` for the method.
enum ApiHeldRegion: CaseIterable {
    case pathQuery, headers, contentType, body
}

func apiHeldRegion(_ field: ApiDraftField) -> ApiHeldRegion? {
    switch field {
    case .path, .query: return .pathQuery
    case .header: return .headers
    case .contentType: return .contentType
    case .body: return .body
    case .method: return nil
    }
}

/// One region's write, from the request with its held fields applied: path and query together
/// when the path view is among them, the query region alone otherwise (as a row's own write).
private func apiHeldRegionWrite(
    _ region: ApiHeldRegion, applied: ApiRequestSnapshot, request: ApiRequestSnapshot,
    held: ApiHeld, pane: String
) -> JSONValue {
    switch region {
    case .pathQuery:
        if held[ApiFieldRow(.path)] != nil {
            return apiPathQueryWrite(path: applied.path, query: applied.query, pane: pane)
        }
        return .object([
            "pane": .string(pane),
            "query": .array(applied.query.map { apiNamedRowJSON(name: $0.name, value: $0.value, sources: [:]) }),
        ])
    case .headers:
        return .object([
            "pane": .string(pane),
            "headers": .array(apiDraftForWrite(applied).headers.map {
                apiNamedRowJSON(name: $0.name, value: $0.value, sources: [:])
            }),
        ])
    case .contentType:
        // One field, so its own write: the single-line text as typed (`apiPendingWrite`).
        let parts = held[ApiFieldRow(.contentType)] ?? []
        return apiFieldWrite(
            field: .contentType, text: apiSingleLineText(apiPlainLiteral(parts)), pane: pane)
    case .body:
        return .object([
            "pane": .string(pane),
            "body": .array(apiDroppingEmptyLiterals(applied.body).map { apiPartJSON($0, sources: [:]) }),
        ])
    }
}

/// `queued` once the dispatch that carried `written` completed, whatever its outcome (F23).
/// **Only at the parts it carried**: a later dispatch of the same field at newer parts is still
/// in flight, and its entry stays.
public func apiQueuedSettled(_ queued: ApiHeld, written: ApiHeld) -> ApiHeld {
    queued.filter { key, parts in written[key] != parts }
}

/// The held fields still worth keeping once a snapshot lands (9a; round 5; A-B-A; F7).
///
/// - Taken over by a gesture still in flight: **kept, whatever landed** (round 3). Only that
///   gesture's own dispatch settles it (`apiGestureSettled`).
/// - A row the request no longer has: let go, its key now names nobody.
/// - **A field whose editor shows what the view now draws is let go, focused or not** (round 5),
///   so a change from elsewhere (the Query region, an agent) redraws it — unless it is focused
///   and a write of OTHER parts is still in flight for it (A-B-A). "Shows" is up to merging, and
///   as written: a held binding the region no longer holds, whose hole has landed, is shown.
/// - Otherwise it is kept while focused (`/o?` over `/o`, mid-word), or while it owes a write.
///   At focus-out the pane passes `focused: nil` (F7), so a focused no-op goes then.
public func apiHeldAfterLanding(
    _ request: ApiRequestSnapshot, held: ApiHeld, focused: ApiFieldRow?,
    takenOver: [ApiFieldRow: ApiHeldTakeover] = [:], queued: ApiHeld = [:]
) -> ApiHeld {
    held.filter { key, parts in
        if takenOver[key]?.held == parts { return true }
        if key.field == .method || !apiHeldFieldExists(request, key) { return false }
        let shown = apiMergedLiterals(apiHeldAsWritten(request, key, parts))
            == apiMergedLiterals(apiHeldView(request, key))
        if shown {
            return key == focused && queued[key].map { $0 != parts } == true
        }
        return key == focused
            || apiPendingWrite(request, box: key, holding: parts, pane: "") != .unchanged
    }
}

/// One gesture's hold on a field (Task 9 fix rounds 2–4): the parts it carried, and **the token
/// of the dispatch that carried them**.
///
/// **A gesture that writes a field takes that field over** (round 2). Format writes the body
/// with its held parts folded in, and the field is kept while focused. Without the hold, once
/// Format's write landed, the field still held the parts from before it, and the focus-out
/// flush wrote them back over it: a Format came undone the moment the cursor left the body.
/// While the gesture is in flight, a field still at the carried parts is never flushed or sent,
/// and no landing lets it go.
///
/// **Settled by token, not by parts** (round 4): two quick gestures at the same parts are two
/// entries, and only the dispatch whose token the entry holds settles it.
public struct ApiHeldTakeover: Equatable, Sendable {
    public let held: [ApiPart]
    public let token: Int

    public init(held: [ApiPart], token: Int) {
        self.held = held
        self.token = token
    }
}

/// `takenOver` once `held` has moved on: an entry is spent when its field is let go or typed
/// past the parts the gesture carried.
public func apiTakenOverSettled(
    _ takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld
) -> [ApiFieldRow: ApiHeldTakeover] {
    takenOver.filter { key, entry in held[key] == entry.held }
}

/// A gesture's dispatch completed (round 3, by token round 4): only what THAT dispatch carried
/// is settled. Landed, a field still at the carried parts is let go. Refused or failed, the
/// entry goes and the field stays, **owing** its write again (`owed`: the pane restarts the
/// pause, final review Minor 4).
public func apiGestureSettled(
    takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld,
    carried: [ApiFieldRow: ApiHeldTakeover], landed: Bool
) -> (takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld, owed: Bool) {
    var takenOver = takenOver
    var held = held
    var owed = false
    for (key, entry) in carried where takenOver[key] == entry {
        takenOver[key] = nil
        if landed, held[key] == entry.held { held[key] = nil }
        if !landed, held[key] != nil { owed = true }
    }
    return (takenOver, held, owed)
}

/// Round 6, per field — **a set that changes nothing types nothing.** An editor (a SwiftUI
/// `TextField`, an `NSTextView` handed new parts) re-sets what it shows whether or not a key
/// was pressed. The held fields after the editor reported `parts`, or `nil` when they are what
/// it shows already (its held parts, or `rendered` when none), up to merging literals. `nil`
/// means no hold and no pause.
public func apiHeldTyping(
    _ held: ApiHeld, box: ApiFieldRow, parts: [ApiPart], rendered: [ApiPart]
) -> ApiHeld? {
    guard apiMergedLiterals(parts) != apiMergedLiterals(held[box] ?? rendered) else { return nil }
    var next = held
    next[box] = parts
    return next
}
