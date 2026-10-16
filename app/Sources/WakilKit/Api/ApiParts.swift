import Foundation

/// The parts model **on the wire**, in both directions (#190).
///
/// `read_pane` publishes parts and `api_set_request` writes them, and
/// #118's hand-over says why that has to be one model rather than two:
/// *"An action that builds a draft writes parts; `read_pane` publishes
/// parts; they are one model, which is Invariant 2 holding at the data
/// level rather than only at the dispatch level."* So the encoder and the
/// decoder sit in one file, against one comment, and a key added to one
/// half is a key the other half is read beside.
///
/// **Decoded by key presence, never by a `kind` discriminator.** That is
/// #112's shape and it is the one an agent can write without being told a
/// vocabulary: `{ "literal": … }`, `{ "slot": … }`, and a bound value by
/// its `name`/`binding`/`source` triple.

// MARK: - Publishing

/// One part, as `read_pane` publishes it.
///
/// **`preview`, never `value`** (#118 ruling 4): it is what the source
/// holds *now*, not what will be sent. A live value that does not resolve
/// right now publishes `preview: null`, `resolves: false` and the columns
/// that **were** available — the one key in this arm that exists for the
/// agent rather than mirroring the operator's screen, because under
/// #107's `.allow` an agent that cannot see it learns a send will be
/// refused by making it.
func apiPartJSON(_ part: ApiPart, sources: [String: ApiSourcePane]) -> JSONValue {
    switch part {
    case .literal(let text):
        return .object(["literal": .string(text)])
    case .slot(let name):
        return .object(["slot": .string(name)])
    case .bound(let bound):
        // Resolution is the one reader of what a bound value holds right
        // now, and it is the same call the send makes — so a `resolves`
        // this publishes and a refusal the send produces cannot disagree.
        let resolved = resolvePart(part, sources: sources)
        var preview: JSONValue = .null
        var available: JSONValue = .null
        if case .value(_, let cell) = resolved {
            preview = .string(ApiCellText.of(cell))
        }
        if case .unresolved(_, let columns) = resolved, let columns {
            available = .array(columns.map { .string($0) })
        }
        return .object([
            "name": .string(bound.name),
            "binding": .string(bound.binding.wireName),
            // **No `declaredType` and no `generation`.** Both are pinned
            // at bind time for resolution's own use (#184, #137); neither
            // is on the operator's screen, and publishing them would
            // invite a reader to write them back.
            "source": .object([
                "pane": .string(bound.source.pane),
                "table": .string(bound.source.table),
                "keyColumns": .array(bound.source.keyColumns.map { .string($0) }),
                "keyValues": .array(bound.source.keyValues.map { .string($0) }),
                "column": .string(bound.source.column),
            ]),
            "preview": preview,
            "resolves": .bool(resolved.isResolved),
            "available": available,
        ])
    }
}

func apiPartsJSON(_ parts: [ApiPart], sources: [String: ApiSourcePane]) -> [JSONValue] {
    parts.map { apiPartJSON($0, sources: sources) }
}

/// One `(name, value-parts)` row, as both the query and the header region
/// publish it. #122 generalised *"structure is never text"* one level out
/// and made both regions the same object; this is that object.
func apiNamedRowJSON(
    name: String, value: [ApiPart], sources: [String: ApiSourcePane]
) -> JSONValue {
    .object(["name": .string(name), "value": .array(apiPartsJSON(value, sources: sources))])
}

extension ApiBinding {
    /// `live` or `captured` — #112's identity, and the word the operator
    /// reads on the chip.
    var wireName: String {
        switch self {
        case .live: return "live"
        case .captured: return "captured"
        }
    }
}

// MARK: - Writing

/// A bound value as `read_pane` publishes it, and so as a write may carry it back (W16): its
/// name, its binding's kind and its source's published fields. **Not** the pinned declared
/// type or generation, which are never published and therefore never compared. The binding
/// that lands is the one the region already held, so those two survive untouched.
struct ApiBoundIdentity: Equatable {
    let name: String
    let binding: String
    let pane: String
    let table: String
    let keyColumns: [String]
    let keyValues: [String]
    let column: String

    init(_ bound: ApiBoundValue) {
        name = bound.name
        binding = bound.binding.wireName
        pane = bound.source.pane
        table = bound.source.table
        keyColumns = bound.source.keyColumns
        keyValues = bound.source.keyValues
        column = bound.source.column
    }

    /// The identity a written part claims, or `nil` when it is not shaped like one.
    init?(json object: [String: JSONValue]) {
        guard case .string(let name)? = object["name"],
              case .string(let binding)? = object["binding"],
              case .object(let source)? = object["source"],
              case .string(let pane)? = source["pane"],
              case .string(let table)? = source["table"],
              case .string(let column)? = source["column"],
              let keyColumns = Self.strings(source["keyColumns"]),
              let keyValues = Self.strings(source["keyValues"])
        else { return nil }
        self.name = name
        self.binding = binding
        self.pane = pane
        self.table = table
        self.keyColumns = keyColumns
        self.keyValues = keyValues
        self.column = column
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let text) = item else { return nil }
            out.append(text)
        }
        return out
    }
}

/// The bindings one region already holds: what a write to that region may carry back (W16).
///
/// **Each one once.** A write that names a held binding twice is MAKING the second one, which
/// only a drop may do (Review Focus 2). **Per region**, so a binding cannot move between the
/// path and the body by being written out of one and into the other.
struct ApiHeldBindings {
    private var remaining: [ApiBoundValue]

    init(_ parts: [ApiPart]) {
        remaining = parts.compactMap { part in
            if case .bound(let bound) = part { return bound }
            return nil
        }
    }

    static var none: ApiHeldBindings { ApiHeldBindings([]) }

    /// The held binding this identity names, removed from the pool, or `nil`.
    mutating func take(_ identity: ApiBoundIdentity) -> ApiBoundValue? {
        guard let index = remaining.firstIndex(where: { ApiBoundIdentity($0) == identity })
        else { return nil }
        return remaining.remove(at: index)
    }
}

/// Reads one part out of an action's params.
///
/// **A bound value is refused here rather than decoded**, and that is
/// #112's *"a slot never converts to a bound value or back except by a
/// gesture"* enforced at the registry. A binding pins two facts a caller
/// cannot author — the column's declared type and the source pane's
/// generation, both recorded at the moment a row was dropped (#184, #137)
/// — and `read_pane` deliberately publishes neither, so a part read out of
/// a snapshot and written straight back would be a binding with invented
/// provenance. `api_bind` is the gesture.
///
/// (W16) A binding the region already holds may be carried back — see `ApiHeldBindings`.
func apiPart(
    _ json: JSONValue, action: String, region: String, index: Int,
    held: inout ApiHeldBindings
) throws -> ApiPart {
    guard case .object(let object) = json else {
        throw ApiActionError.notAPart(
            action: action, region: region, index: index,
            found: "a \(apiJSONTypeName(json))")
    }
    if case .string(let text)? = object["literal"], object.count == 1 {
        return .literal(text)
    }
    if case .string(let name)? = object["slot"], object.count == 1 {
        guard !name.isEmpty else {
            throw ApiActionError.unnamedSlot(action: action, region: region, index: index)
        }
        return .slot(name)
    }
    if object["binding"] != nil || object["source"] != nil {
        // W16: a write may CARRY a binding this region already holds — the same name, kind
        // and source, wherever the text around it moved it — and never MAKE one.
        if let identity = ApiBoundIdentity(json: object), let kept = held.take(identity) {
            return .bound(kept)
        }
        throw ApiActionError.boundValueIsAGesture(
            action: action, region: region, index: index)
    }
    throw ApiActionError.notAPart(
        action: action, region: region, index: index,
        found: "the keys \(object.keys.sorted().joined(separator: ", "))")
}

/// A region's parts, refusing every bound part: nothing is held to carry.
func apiParts(_ json: JSONValue, action: String, region: String) throws -> [ApiPart] {
    var none = ApiHeldBindings.none
    return try apiParts(json, action: action, region: region, held: &none)
}

/// A region's parts, carrying back each binding `held` still holds, once (W16).
func apiParts(
    _ json: JSONValue, action: String, region: String, held: inout ApiHeldBindings
) throws -> [ApiPart] {
    guard case .array(let items) = json else {
        throw ApiActionError.notAPartList(action: action, region: region)
    }
    // A loop, not `map`: an `inout` cannot be captured.
    var parts: [ApiPart] = []
    for (index, item) in items.enumerated() {
        parts.append(try apiPart(item, action: action, region: region, index: index, held: &held))
    }
    return parts
}

/// Reads the `(name, value-parts)` rows of the query or the header region.
///
/// **The name is a literal and admits no parts** (#122): a query name
/// selects what the server reads the value as, and a header name is the
/// field name itself, so both carry structure rather than data.
///
/// **A malformed row is refused; a badly-NAMED one is not.** The
/// difference is the line this action draws and #158 ruled: the shape of
/// the request is the caller's to get right, and the *content* of it joins
/// the one aggregated send refusal — a duplicate name, an unparseable
/// field name and a control character are all marked on their row and
/// reported together when the request is sent, rather than eaten a
/// keystroke at a time.
func apiNamedRows(
    _ json: JSONValue, action: String, region: String
) throws -> [(name: String, value: [ApiPart])] {
    var none = ApiHeldBindings.none
    return try apiNamedRows(json, action: action, region: region, held: &none)
}

/// The rows of a region, carrying back each binding `held` still holds, once, in whichever row
/// it now sits (W16): the pool is the REGION's, not a row's.
func apiNamedRows(
    _ json: JSONValue, action: String, region: String, held: inout ApiHeldBindings
) throws -> [(name: String, value: [ApiPart])] {
    guard case .array(let items) = json else {
        throw ApiActionError.notARowList(action: action, region: region)
    }
    var rows: [(name: String, value: [ApiPart])] = []
    for (index, item) in items.enumerated() {
        guard case .object(let row) = item, case .string(let name)? = row["name"] else {
            throw ApiActionError.notARow(action: action, region: region, index: index)
        }
        rows.append((name, try apiParts(
            row["value"] ?? .array([]), action: action, region: region, held: &held)))
    }
    return rows
}

/// How a JSON token is named back to a caller that sent the wrong one.
func apiJSONTypeName(_ value: JSONValue) -> String {
    switch value {
    case .string: return "string"
    case .number: return "number"
    case .integer: return "integer"
    case .bool: return "boolean"
    case .array: return "array"
    case .object: return "object"
    case .null: return "null"
    }
}

// MARK: - Drawing

/// How a part reads on screen.
///
/// **A rule rather than a `switch` in the view**, because `WakilApp` has
/// no test target and this is the one half of #150's chip that #190 can
/// assert: *a hole the operator named keeps that name as the chip's label
/// once filled*, so the request still reads the way the API's own docs
/// write it. A slot and the bound value that fills it therefore draw under
/// the **same** label, and `filled` is the only thing that changes.
public enum ApiPartDrawing: Sendable, Equatable {
    /// A literal, drawn as the operator typed it. Never marked up and
    /// never parsed back — braces in a JSON body are text.
    case text(String)
    /// A named hole, or the value that filled it, under its own name.
    case chip(String, filled: Bool)
}

public func apiPartDrawing(_ part: ApiPart) -> ApiPartDrawing {
    switch part {
    case .literal(let text): return .text(text)
    case .slot(let name): return .chip(name, filled: false)
    case .bound(let bound): return .chip(bound.name, filled: true)
    }
}

// MARK: - The bound-values strip

/// One row of the bound-values strip.
public struct ApiStripRow: Sendable, Equatable {
    /// The name the operator gave the hole, and the chip's label.
    public let name: String
    /// `live` or `captured` — #112's identity, and the word on the chip.
    public let kind: String
    /// The region the value sits in. Drawn only when two rows share a name (`apiBoundLines`),
    /// so two holes of one name read apart.
    public let region: String
    /// The hole's value NOW, shortened (W18), or `nil` when it does not resolve now — never a
    /// remembered one (Review Focus 5).
    public let value: String?
    /// The table the value comes from, `a result` when the grid named none (W18).
    public let table: String

    public init(
        name: String, kind: String, region: String,
        value: String? = nil, table: String = ""
    ) {
        self.name = name
        self.kind = kind
        self.region = region
        self.value = value
        self.table = table
    }
}

/// Every bound value in a request, in wire order, as the strip draws them.
///
/// **A function in `WakilKit` rather than a loop in the view**, on
/// `apiChooserIsEnabled`'s own precedent: `WakilApp` has no test target,
/// and which values appear in the index and what each one says about its
/// origin are rulings rather than layout details.
///
/// **It reads the four regions in wire order**, which is what makes the
/// strip an index of the request rather than a second list free to
/// disagree with it.
///
/// **Each row carries the hole's value now** (W18), resolved against `sources` — the panes on
/// screen — exactly as a send would resolve it. A value that does not resolve has none.
public func apiBoundValues(
    in request: ApiRequestSnapshot, sources: [String: ApiSourcePane] = [:]
) -> [ApiStripRow] {
    var rows: [ApiStripRow] = []
    func collect(_ parts: [ApiPart], region: String) {
        for part in parts {
            guard case .bound(let bound) = part else { continue }
            let value: String?
            if case .value(_, let cell) = resolvePart(part, sources: sources) {
                value = apiShortened(ApiCellText.of(cell))
            } else {
                value = nil
            }
            rows.append(ApiStripRow(
                name: bound.name,
                kind: bound.binding.wireName,
                region: region,
                value: value,
                table: bound.source.table.isEmpty ? "a result" : bound.source.table))
        }
    }
    collect(request.path, region: "Path")
    request.query.forEach { collect($0.value, region: "Query · \($0.name)") }
    request.headers.forEach { row in
        collect(row.value ?? [], region: "Header · \(row.name)")
    }
    collect(request.body, region: "Body")
    return rows
}

/// One Bound row as drawn (W18): `id = 3 · live · events.customers` — the hole's name, its
/// value now, the binding's kind, and the table. A value that does not resolve now reads
/// `no value now`, never a remembered one (Review Focus 5).
public func apiBoundLine(_ row: ApiStripRow) -> String {
    apiBoundLine(row, withRegion: false)
}

/// Every Bound row as drawn, in order. **A name used by two or more rows carries its region**
/// (`· Query · x`), so two holes of one name never read alike; a name used once carries none.
public func apiBoundLines(_ rows: [ApiStripRow]) -> [String] {
    let counts = Dictionary(rows.map { ($0.name, 1) }, uniquingKeysWith: +)
    return rows.map { apiBoundLine($0, withRegion: (counts[$0.name] ?? 0) > 1) }
}

private func apiBoundLine(_ row: ApiStripRow, withRegion: Bool) -> String {
    var line = row.value.map { "\(row.name) = \($0) · \(row.kind) · \(row.table)" }
        ?? "\(row.name) · \(row.kind) · \(row.table) · no value now"
    if withRegion { line += " · \(row.region)" }
    return line
}

/// Whether any region of `request` holds a bound part — `PaneStore` skips reading the grids
/// on screen when none does.
func apiHasBoundPart(_ request: ApiRequestSnapshot) -> Bool {
    let isBound: (ApiPart) -> Bool = { if case .bound = $0 { return true } else { return false } }
    return request.path.contains(where: isBound)
        || request.query.contains { $0.value.contains(where: isBound) }
        || request.headers.contains { ($0.value ?? []).contains(where: isBound) }
        || request.body.contains(where: isBound)
}

// MARK: - The response and the past tense

/// The response on the wire.
///
/// **The carve-out this comment has always described, now with five
/// states to carve.** `state` announces the shape exactly as `kind`
/// announces the pane's, and **each state publishes only the keys it can
/// hold**: a refusal has no status because nothing was sent, a transport
/// failure has no body because nothing came back, and `none` has no keys
/// at all — publishing a null status and an empty body beside it would be
/// six lies about a request nobody has sent.
///
/// This is the same absence-is-load-bearing rule that made
/// `ApiResponseSnapshot` an enum rather than a struct of optionals,
/// carried out to the wire so a reader sees it too.
func apiResponseJSON(_ response: ApiResponseSnapshot) -> JSONValue {
    var object: [String: JSONValue] = ["state": .string(response.state)]
    switch response {
    case .none:
        break
    case .ok(let reply):
        object["status"] = .number(Double(reply.status))
        object["url"] = .string(reply.url)
        object["environment"] = .string(reply.environment)
        object["headers"] = .object(reply.headers.mapValues { .string($0) })
        object["body"] = .string(reply.body)
        object["millis"] = .number(Double(reply.durationMs))
        object["bytes"] = .number(Double(reply.byteCount))
        object["truncated"] = .bool(reply.truncated)
    case .transport(let failure):
        object["stage"] = .string(failure.stage)
        object["waitedMs"] = .number(Double(failure.waitedMs))
        object["reason"] = .string(failure.reason)
        object["environment"] = .string(failure.environment)
    case .unknown(let record):
        object["reason"] = .string(record.reason)
        object["environment"] = .string(record.environment)
    case .refusal(let refusal):
        // Every failure at once, so an agent fixing the request makes one
        // pass rather than four sends.
        object["failures"] = .array(refusal.failures.map { failure in
            var entry: [String: JSONValue] = ["message": .string(failure.message)]
            if let region = failure.region { entry["region"] = .string(region.label) }
            if let available = failure.available {
                entry["available"] = .array(available.map { .string($0) })
            }
            return .object(entry)
        })
    case .cleared(let environment):
        object["environment"] = .string(environment)
    case .cancelled(let cancelled):
        // W14. Two keys other states already publish, so no new key reaches read_pane.
        object["waitedMs"] = .number(Double(cancelled.waitedMs))
        object["environment"] = .string(cancelled.environment)
    }
    return .object(object)
}

/// One `recent` row on the wire.
///
/// **No body, and no resolved URL beyond the path.** The strip is rows; a
/// reader that wants what came back reads the response, which holds
/// exactly one reply — the current one.
///
/// **`status` and `millis` are `null` rather than absent when there is
/// none.** A row is one shape whose numbers can be unknown, where the
/// response states carve on presence — two different rules because a row
/// has no discriminator to announce a second shape with.
func apiRecentRowJSON(_ row: ApiRecentRow) -> JSONValue {
    .object([
        "id": .string(row.id),
        "method": .string(row.method),
        "entry": .string(row.entry),
        "environment": .string(row.environment),
        "path": .string(row.path),
        "status": row.status.map { .number(Double($0)) } ?? .null,
        "millis": row.durationMs.map { .number(Double($0)) } ?? .null,
        "cancelled": .bool(row.cancelled),
    ])
}

/// A path rendered for a human: literals as typed, and every hole or
/// binding as its name in angle brackets.
///
/// **For reading, never for parsing back.** `api_reopen` restores the
/// draft that was sent rather than this string — a rendered path cannot
/// be turned back into parts, and turning one back would be exactly the
/// delimiter this pane is built without.
public func apiRenderedPath(_ parts: [ApiPart]) -> String {
    parts.map { part in
        switch part {
        case .literal(let text): return text
        case .slot(let name): return "<\(name)>"
        case .bound(let bound): return "<\(bound.name)>"
        }
    }.joined()
}

// MARK: - Copy as cURL

/// Renders a past send as a `curl` line.
///
/// **On a recent row, never on the draft** (#195). A draft has no sent
/// URL, and a resolved URL on one is forbidden as a published prediction
/// — `read_pane` will not publish it and neither will this. What is
/// rendered is what actually left.
///
/// **It names the credential it is missing rather than omitting it.** A
/// line that quietly dropped the `authorization` header would be a
/// second, false read-back: it would 401, and the operator would debug
/// the endpoint instead of the copy. Wakil never holds the credential, so
/// a runnable line was never available — saying so is the honest version.
///
/// **And it names no scheme and no ref.** Neither is this surface's to
/// show (#118's redaction rule), and a guessed `Bearer` would be a scheme
/// Wakil never confirmed.
///
/// **The pasteboard is a fifth emit position with its own rule, not an
/// exception to the no-delimiter ruling.** This quotes for a shell;
/// nothing anywhere reads it back, so no parse can be fooled by what a
/// body happens to contain.
/// - Parameter url: the URL to render. Callers pass `row.sentUrl` when
///   there is one; `row.path` alone is a PATH and renders a line with no
///   host, which is a third reason the line is not runnable and one the
///   comment cannot explain away.
public func apiRenderCurl(row: ApiRecentRow, url: String, credentialed: Bool = true) -> String {
    var parts = ["curl", "-X \(row.method.uppercased())"]
    parts.append(shellQuoted(url))

    for header in row.draft.headers {
        // **`apiRenderedPath`'s mapping, and deliberately the same one.**
        // A bound value appears as `<name>`, exactly as it does in the
        // strip's path: the row records what left, and a value taken out
        // of a grid is named here rather than printed.
        parts.append("-H \(shellQuoted("\(header.name): \(apiRenderedPath(header.value))"))")
    }
    let body = apiRenderedPath(row.draft.body)
    if !body.isEmpty {
        // **The content type rides with the body, and only with it.** An
        // empty body sends no body AND no content type — the rule this
        // pane enforces at the wire, in the statement, and here. A copied
        // line advertising a header that never left is a line that
        // behaves differently from the send it claims to reproduce.
        if !row.draft.contentType.isEmpty {
            parts.append("-H \(shellQuoted("content-type: \(row.draft.contentType)"))")
        }
        parts.append("--data \(shellQuoted(body))")
    }

    var line = parts.joined(separator: " ")
    if credentialed {
        line += "\n# credential not included — Wakil never holds it, so this line is not "
            + "runnable as pasted"
    }
    return line
}

/// Single-quotes a value for a POSIX shell, closing and reopening around
/// any quote it contains. Emission only — nothing parses this back.
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// One recent row, as the strip draws it.
///
/// **Method, path, status, duration — the four an operator scans for.**
/// Not the URL: the strip sits under a pane already showing the entry and
/// the origin, and repeating the host on every row buries the path that
/// distinguishes them.
///
/// **A send with no reply says "no reply" rather than drawing a zero.** A
/// transport failure and a fate-unknown have no status, and a `0` beside
/// a path reads as a code the server sent — the same rule the response
/// states carry, applied to the row. It still reports how long it waited
/// when it waited, because that is the operator's first question about a
/// failure.
///
/// **A cancelled send says so (W14), and a cancelled MUTATION says it may have landed.** A read
/// that was cancelled changed nothing. A write that was cancelled may have reached the server
/// before the cancel did, so its row carries the same fate-unknown its response does.
///
/// **A row sent to another entry than the pane's names that entry first** (final review I1):
/// Recent is shared by every pane of the environment (W15), so the entry the pane names above
/// is not always the row's, and Reopen re-points the pane at the row's.
///
/// **A send to the root reads `/`** (re-walk #3): an empty path left `POST  · 405`, a double
/// space where the path goes. The URL line draws an empty path as the root for the same reason.
public func apiRecentRowLabel(_ row: ApiRecentRow, paneEntry: String? = nil) -> String {
    var parts = ["\(row.method) \(row.shownPath.isEmpty ? "/" : row.shownPath)"]
    if let paneEntry, !row.entry.isEmpty, row.entry != paneEntry { parts.insert(row.entry, at: 0) }
    if row.cancelled {
        parts.append(apiIsReadMethod(row.method) ? "cancelled" : "cancelled — may have landed")
    } else {
        parts.append(row.status.map { "\($0)" } ?? "no reply")
    }
    if let millis = row.durationMs { parts.append("\(millis) ms") }
    return parts.joined(separator: " · ")
}

/// The strip's folded summary.
///
/// **Folded behind a count, so the log costs nothing until it is
/// wanted** (#195). The count is the whole of what a folded strip owes:
/// how much is there, and whether it has been trimmed — because a short
/// history and a trimmed one must never look alike.
public func apiRecentSummary(count: Int, truncated: Bool) -> String {
    guard count > 0 else { return "none yet" }
    var summary = "\(count) send" + (count == 1 ? "" : "s")
    if truncated { summary += " · trimmed" }
    return summary
}
