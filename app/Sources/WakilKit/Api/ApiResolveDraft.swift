import Foundation

/// Turns a draft request into a wire request, or into **one refusal
/// naming every failure** (#189).
///
/// **The only new seam 2c-iv adds, and it was chosen deliberately.**
/// Resolution is a read, so this needs no actor, no store and no I/O —
/// the source panes' rows arrive as an argument. Everything #112, #116,
/// #122, #137, #150 and #158 ruled is therefore a table test over typed
/// values rather than a dispatch with a fixture pane per case.
///
/// **`credentialed` is the entry's, and it has NO DEFAULT** (#190). It is
/// not a field of the draft — it is what `list_apis` said about the entry
/// the draft targets, and the pane holds it beside the draft — and the
/// only thing resolution does with it is decide whether there is an
/// `authorization` row for an authored one to collide with.
///
/// **A default was written first and is the bug this parameter exists to
/// prevent.** The header region the operator READS is composed from the
/// pane's `credentialed`; a resolution that defaulted would compose its
/// reserved names from `false` and disagree with the screen about whether
/// the row exists — two lists free to disagree, which is exactly what
/// `ApiRequestSnapshot.headers` is one list to prevent. A caller that does
/// not know cannot silently guess; it has to go and ask the pane, which is
/// the one place that knows.
public func resolveDraft(
    _ draft: ApiDraft, sources: [String: ApiSourcePane], credentialed: Bool
) -> Result<ApiWireRequest, ApiSendRefusal> {
    var failures: [ApiSendFailure] = []

    let pathParts = resolveRegion(draft.path, .path, sources: sources, into: &failures)
    let path = emitPath(pathParts, into: &failures)

    let query = draft.query.map { row in
        ApiWireQueryItem(
            name: row.name,
            value: emitQueryValue(
                resolveRegion(row.value, .query(row.name), sources: sources, into: &failures)))
    }

    let headers = resolveHeaders(
        draft.headers, sources: sources,
        reserved: apiReservedHeaderRefusals(entry: draft.entry, credentialed: credentialed),
        into: &failures)

    // **The body is a field of parts Wakil never parses** (#116). It is never read to find where
    // a part sits — the part decides its own literal — so there is no template, no delimiter and
    // nothing to escape out of.
    //
    // **B1: a read sends no body.** The draft keeps it (a press back to POST restores it to the
    // wire), and `request` is never handed `body` or `contentType`, so `wakil-http`'s schema
    // refusal cannot reach the operator. **B2: an empty body sends no body and no
    // `Content-Type`**: three wire states, not two. A content type named beside it is omitted,
    // not refused, and the row dims.
    var body: String?
    var contentType: String?
    let namedContentType = draft.contentType.trimmingCharacters(in: .whitespacesAndNewlines)
    if !apiIsReadMethod(draft.method), !draft.body.isEmpty {
        let resolved = resolveRegion(draft.body, .body, sources: sources, into: &failures)
        // **The emitted document is validated only when every part of it resolved**, and this is
        // the aggregate's own rule rather than a shortcut. An unresolved part leaves a GAP, so
        // validating unconditionally reported "the document this emits is not JSON" beside every
        // body failure — a second entry that is a consequence of the first and that the operator
        // cannot act on.
        if resolved.allSatisfy(\.isResolved) {
            let emitted = emitBody(resolved)
            if let failure = bodyFailure(emitted) {
                failures.append(failure)
            } else {
                body = emitted
                // Empty leaves the default to the send tool, which applies `application/json`
                // itself. Deciding it here would be a second answer to a question one process
                // already answers.
                contentType = namedContentType.isEmpty ? nil : namedContentType
            }
        }
    }

    guard failures.isEmpty else { return .failure(ApiSendRefusal(failures: failures)) }
    return .success(ApiWireRequest(
        entry: draft.entry, method: draft.method, path: path, query: query,
        headers: headers, body: body, contentType: contentType))
}

// MARK: - The header region

/// Resolves the header rows into the map they are.
///
/// **A map, not a list** (#158) — a name already present is refused rather
/// than added, and that refusal is what lets the drawn `authorization`
/// row be honest with no copy of the send tool's deny list here to go
/// stale.
///
/// **Every row is resolved before it is judged**, so a row refused for its
/// name still reports the unresolved parts in its value: an operator
/// fixing one thing is not sent back for the rest.
/// **The map already holds Wakil's own rows before the first authored one
/// is read**, which is #158's payoff rather than a second check: the
/// region draws `authorization` and `content-type`, so an operator who
/// types either hits the duplicate rule and is told what already holds the
/// name. That is the deny list's load-bearing entry enforced by the
/// display being honest, with no copy of `rejectedCallerHeader` here to go
/// stale.
func resolveHeaders(
    _ rows: [ApiHeaderRow], sources: [String: ApiSourcePane],
    reserved: [String: String] = [:],
    into failures: inout [ApiSendFailure]
) -> [ApiWireHeader] {
    var headers: [ApiWireHeader] = []
    var taken: Set<String> = Set(reserved.keys)
    for row in rows {
        let region = ApiRegion.header(row.name)
        let value = emitHeaderValue(
            resolveRegion(row.value, region, sources: sources, into: &failures))
        guard isFieldName(row.name) else {
            failures.append(ApiSendFailure(
                region: region,
                message: "“\(row.name)” is not a field name. A header name is letters, digits "
                    + "and !#$%&'*+-.^_`|~ — no spaces, no colon, and not empty."))
            continue
        }
        guard taken.insert(row.name.lowercased()).inserted else {
            failures.append(ApiSendFailure(
                region: region,
                // A row Wakil itself draws gets its own sentence, because
                // the remedy differs: *you already typed this* and *the
                // billing entry supplies this* are not the same problem,
                // which is the rule the aggregate already follows for an
                // unresolved value.
                message: reserved[row.name.lowercased()]
                    ?? ("“\(row.name)” is already on this request. A header region is a map, "
                        + "not a list — one of the two would be silently lost.")))
            continue
        }
        // **Checked even when a part of the value did not resolve**, and
        // that is not the body's rule inverted. A gap contributes the
        // empty string, and an empty string carries no control character —
        // so this can only ever report one that a RESOLVED part actually
        // holds, which is an independent failure rather than a derived
        // one. JSON is the opposite: a gap breaks the document by itself.
        if let control = value.unicodeScalars.first(where: isControlScalar) {
            failures.append(ApiSendFailure(
                region: region,
                message: "The value carries \(nameOfControl(control)). There is no escape for "
                    + "one in a header, so Wakil refuses rather than mangling it."))
            continue
        }
        headers.append(ApiWireHeader(name: row.name, value: value))
    }
    // Order is a contract — name-sorted, case-insensitively — so that a
    // redraw or a re-resolve never reorders what the operator is reading.
    //
    // **It discards the drafted order, where `query` keeps it**, and the
    // asymmetry is the regions' own: a header region is a MAP, so its
    // order carries nothing and a stable one is worth more than the order
    // rows happened to be typed in. A query region is a list, and its
    // order is the operator's.
    return headers.sorted { $0.name.lowercased() < $1.name.lowercased() }
}

// MARK: - Resolution

/// What one part resolved to, or why it did not.
///
/// **A literal is carried apart from a resolved value**, because the path
/// emits the two differently: the operator authors the slashes, and a cell
/// may not.
enum ApiResolvedPart: Equatable {
    case authored(String)
    /// A bound value that resolved, carrying the **name** the operator
    /// sees alongside it — so a refusal decided at emit, where the part is
    /// gone, can still say which one it is about.
    case value(name: String, cell: ApiHeldCell)
    /// **The region is not here.** A part does not know which region it
    /// sits in, and threading one through resolution so that it could be
    /// stamped on a failure would be a second answer to a question the
    /// caller already has. `resolveRegion` stamps it once.
    case unresolved(message: String, available: [String]? = nil)

    var isResolved: Bool {
        if case .unresolved = self { return false }
        return true
    }
}

/// Resolves one part against the source panes currently on screen.
///
/// **What counts as unresolved, stated so nothing re-derives it** (#179):
/// the source pane is closed; it has not re-fetched yet; no row matches
/// the key; the column is absent from the current result. The fifth is the
/// cell that is there and is `NULL`, which #184 ruled for Mongo and which
/// holds everywhere for the same reason — a NULL has no value to send, and
/// emitting it as an empty path segment or an empty query value would be
/// exactly the silent hole the aggregate exists to prevent. A body that
/// genuinely wants the literal `null` says so with a literal part.
func resolvePart(_ part: ApiPart, sources: [String: ApiSourcePane]) -> ApiResolvedPart {
    switch part {
    case .literal(let text):
        return .authored(text)

    case .slot(let name):
        return .unresolved(message: "“\(name)” has never been bound. Drop a row on it, "
            + "or type a literal in its place.")

    case .bound(let bound):
        let source = bound.source
        let origin = describeOrigin(source)

        guard let pane = sources[source.pane] else {
            return .unresolved(message: "“\(bound.name)” came from a pane that is closed "
                + "(\(origin)). Re-bind it from a grid that is open.")
        }

        if case .captured(let held) = bound.binding {
            // A capture lives exactly as long as the rows it was taken
            // from (#137 ruling 2). A pane that has re-fetched is a pane
            // whose rows are gone, whatever they came back as — so this
            // compares generations rather than values, and a closed pane
            // and a re-run query are ONE failure mode rather than two.
            //
            // **No `available` here, deliberately.** The columns a capture
            // could have read are not the remedy: re-binding is, and the
            // discriminator already carries the reason. Listing columns
            // would offer a choice that does not exist.
            guard pane.generation == source.generation else {
                return .unresolved(message: "“\(bound.name)” was captured from \(origin). "
                    + "Those rows are gone, so the value is too. Re-bind it.")
            }
            return admit(held, name: bound.name, origin: origin)
        }

        // Live. Rows are never persisted, so a pane that holds no result
        // at all has not re-fetched yet — after a relaunch or an
        // environment switch a live value genuinely has nothing to read.
        // No new machinery: the empty result IS the state.
        guard !pane.columns.isEmpty else {
            return .unresolved(message: "“\(bound.name)” reads \(origin), and that grid has "
                + "not re-fetched yet. Send again once it lands.")
        }
        guard let row = pane.row(keyColumns: source.keyColumns, keyValues: source.keyValues) else {
            return .unresolved(
                message: "“\(bound.name)” reads \(origin), and no row matches that key "
                    + "any more.",
                available: pane.columns)
        }
        guard let index = pane.columns.firstIndex(of: source.column) else {
            return .unresolved(
                message: "“\(bound.name)” reads a column \(source.column) that the grid no "
                    + "longer has.",
                available: pane.columns)
        }
        // The cell is read from the pane; the TYPE is the one pinned at
        // bind. See `ApiValueSource.declaredType` — an inferred type is a
        // property of the page, so re-reading it here would let paging the
        // source pane change how the same cell is quoted.
        return admit(
            ApiHeldCell(token: row[index], declaredType: source.declaredType),
            name: bound.name, origin: origin)
    }
}

/// The two refusals a cell itself can earn, once it has been found.
private func admit(_ cell: ApiHeldCell, name: String, origin: String) -> ApiResolvedPart {
    if case .null = cell.token {
        return .unresolved(message: "“\(name)” reads \(origin), and that cell is NULL. "
            + "There is nothing to send in its place.")
    }
    guard cell.token.isScalar else {
        // Mongo's arrays, sub-documents and `bson.Binary` arrive as JSON
        // objects and arrays, and an object cannot fill a scalar position.
        // Refused on the TOKEN's shape rather than on a list of type names
        // (#184), which is why this needs no driver branch.
        return .unresolved(message: "“\(name)” reads \(origin), and that cell is not a single "
            + "value — a document or a list cannot be put in a request field.")
    }
    guard !isBinaryType(cell.declaredType) else {
        // A binary column is CORRUPTED before the pane ever sees it: the
        // JSON encoder must emit valid UTF-8, so `DE AD BE EF` crosses as
        // eight bytes for four, unrecoverably. That is the db pane's
        // defect and is filed rather than repaired here — but a bound
        // value makes it reachable by a SEND, so this refuses rather than
        // putting eight bytes on the wire for four.
        return .unresolved(message: "“\(name)” reads \(origin), a \(cell.declaredType) column. "
            + "Binary cells are already corrupted by the time a pane can read them, so Wakil "
            + "will not send one.")
    }
    return .value(name: name, cell: cell)
}

/// A bound value's origin, for the refusal that names it.
private func describeOrigin(_ source: ApiValueSource) -> String {
    let key = zip(source.keyColumns, source.keyValues)
        .map { "\($0) \($1)" }
        .joined(separator: " · ")
    return [source.table, key.isEmpty ? "no key" : key, source.column].joined(separator: " · ")
}

/// Resolves one region's parts and stamps its own name on every failure.
private func resolveRegion(
    _ parts: [ApiPart], _ region: ApiRegion, sources: [String: ApiSourcePane],
    into failures: inout [ApiSendFailure]
) -> [ApiResolvedPart] {
    let resolved = parts.map { resolvePart($0, sources: sources) }
    for part in resolved {
        guard case .unresolved(let message, let available) = part else { continue }
        failures.append(
            ApiSendFailure(region: region, message: message, available: available))
    }
    return resolved
}

// MARK: - Emit

/// **The position decides the escape, and Wakil escapes at emit** (#122).
/// No position's safety depends on the cell's content.
///
/// In the **path**, literals pass through unescaped — the operator authors
/// the slashes — and every resolved value is percent-encoded as ONE
/// segment, so nothing a cell holds can open a second segment and climb.
///
/// **A part resolving to `.` or `..` is refused by name**, and it is the
/// one narrow case Swift adds. Percent-encoding cannot reach a dot
/// segment: `..` survives it intact. There is no Swift copy of the Go
/// traversal guard beside it — `doHTTP` already checks the final joined
/// URL, the stake here is the *message*, and a second copy would drift.
///
/// **What the encoding does NOT buy, measured rather than assumed.** One
/// inert segment is not the same as a sent one: `url.Parse` decodes a
/// single level into `u.Path`, so `..%2Fetc%2Fpasswd` reaches
/// `containsDotDotSegment` as `../etc/passwd` and the send is refused — in
/// Go's words, about a path the operator never typed. Nothing unsafe
/// happens and this ticket does not widen the one narrow case above, which
/// is the ruling #179 closed; the gap is filed as
/// [#262](https://github.com/yehia-khalil/rafiq/issues/262).
func emitPath(_ resolved: [ApiResolvedPart], into failures: inout [ApiSendFailure]) -> String {
    var out = ""
    for part in resolved {
        switch part {
        case .authored(let text):
            out += text
        case .value(let name, let cell):
            let text = ApiCellText.of(cell)
            guard text != ".", text != ".." else {
                failures.append(ApiSendFailure(
                    region: .path,
                    message: "“\(name)” resolves to “\(text)”, which is a path segment that "
                        + "climbs. Wakil will not put it on the wire."))
                continue
            }
            out += percentEncodedSegment(text)
        case .unresolved:
            continue
        }
    }
    return out
}

/// **A query value is NOT escaped here, and that settles the asymmetry the
/// prototype flagged rather than smuggling it.**
///
/// The prototype escaped the whole resolved value, literals included,
/// because it composed a URL string itself. This seam does not: the send
/// tool takes `query` as a map of decoded names and values and runs
/// `url.Values.Encode` over it (`httpclient.go`), so escaping here would
/// percent-encode the percent signs and put `%252Fetc` on the wire. The
/// region already carries name and value apart, so no operator ever
/// authors a delimiter in one — which is why the *rule* the asymmetry was
/// reaching for still holds, and holds for free.
///
/// The path is escaped here for the opposite reason: it crosses as ONE
/// pre-joined string, so this is the last place that can tell a cell's
/// slash from an operator's.
func emitQueryValue(_ resolved: [ApiResolvedPart]) -> String { joinedText(resolved) }

/// **A header value has no escape at all**, so there is nothing to apply
/// here — the refusal in `resolveDraft` is what carries #158 instead.
func emitHeaderValue(_ resolved: [ApiResolvedPart]) -> String { joinedText(resolved) }

/// The two positions above take their parts verbatim, for two different
/// reasons — so they stay two named emitters with two doc comments, and
/// share the one line that is genuinely the same.
private func joinedText(_ resolved: [ApiResolvedPart]) -> String {
    resolved.map(\.emittedText).joined()
}

extension ApiResolvedPart {
    /// The text this part contributes to a region that takes it verbatim.
    /// An unresolved part contributes nothing and has already been
    /// reported, so the gap it leaves is never a second failure.
    var emittedText: String {
        switch self {
        case .authored(let text): return text
        case .value(_, let cell): return ApiCellText.of(cell)
        case .unresolved: return ""
        }
    }
}

/// A cell's text, **as the pane drew it**.
///
/// One function, and it is `PaneCell`'s — the same projection the grid
/// renders with. That is the whole of the `DATE` rule: a date cell arrives
/// as a full RFC 3339 timestamp on sqlite and as `2026-09-22` on MySQL
/// (#184), and Wakil emits whichever one the operator was looking at
/// rather than inventing a third spelling it never showed them.
enum ApiCellText {
    static func of(_ cell: ApiHeldCell) -> String { PaneCell(cell.token).text }
}

/// Percent-encodes one path segment.
///
/// The unreserved set is `encodeURIComponent`'s — alphanumerics plus
/// `-_.!~*'()` — so `/`, `:` and every other delimiter is escaped and the
/// result is a single segment. Measured against it: a `DATE` bound into a
/// path emits `2026-09-22T00%3A00%3A00Z`.
func percentEncodedSegment(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: pathSegmentUnreserved) ?? text
}

private let pathSegmentUnreserved: CharacterSet = {
    var set = CharacterSet(charactersIn: "A"..."Z")
    set.insert(charactersIn: "a"..."z")
    set.insert(charactersIn: "0"..."9")
    set.insert(charactersIn: "-_.!~*'()")
    return set
}()

// MARK: - The body

/// The outbound body cap, in bytes.
///
/// **A mirror of `httpSendBodyCap` in `internal/wakilcore/httpsend.go`,
/// and the duplication is deliberate.** That one refuses at the wire; this
/// one has to refuse *before* the write gate, so that an operator is never
/// asked to confirm a production send that cannot work. Go's number is not
/// reachable from Swift, so the drift is guarded by a test that pins both
/// to the same value rather than by a shared constant that does not exist.
///
/// **The absence was the finding.** The 2c-iv probe booked a cliff
/// somewhere below 64 MiB and found none: a 67 MB `tools/call` crossed the
/// pipe with no refusal, no truncation and no hang, held in full in three
/// processes. The refusal is owed on the truncation rule's own ground — a
/// limit nobody is told about is the failure, and here there was not even
/// a limit.
public let apiOutboundBodyCap = 1024 * 1024

/// How the cap is spelled to a human. Written out rather than computed,
/// exactly as `httpSendBodyCapLabel` is, so the two refusals read alike —
/// and internal rather than private so a test can pin it against Go's.
let apiOutboundBodyCapLabel = "1 MiB"

/// **The part decides its own literal, from the DECLARED type.**
///
/// The token decides the digits and the declared type decides the
/// position, which is what makes one rule cover three engines with no
/// driver branch: a `DECIMAL` is the number `19.9` on sqlite and the
/// string `"19.90"` on MySQL, and both emit unquoted into a number
/// position as their own engine's truth.
func emitBody(_ resolved: [ApiResolvedPart]) -> String {
    resolved.map { part in
        switch part {
        case .authored(let text): return text
        case .value(_, let cell): return jsonLiteral(cell)
        case .unresolved: return ""
        }
    }.joined()
}

func jsonLiteral(_ cell: ApiHeldCell) -> String {
    let text = ApiCellText.of(cell)
    if isNumericType(cell.declaredType) {
        // Unquoted, verbatim. A cell that is not a number after all emits
        // as one anyway and the DOCUMENT says so — one refusal, in the one
        // place that validates, rather than a second guess per cell that
        // would quietly quote a value the column says is a number.
        return text
    }
    if isBooleanType(cell.declaredType) { return booleanLiteral(cell.token) ? "true" : "false" }
    let encoded = try? JSONSerialization.data(
        withJSONObject: text, options: [.fragmentsAllowed])
    return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

/// A `BOOLEAN` arrives as the JSON number 1 on sqlite and as a real
/// boolean on Mongo; MySQL erases the spelling to `TINYINT` at DDL, so
/// there this rule has nothing to key on and the cell emits as the number
/// it declared (#184). That cost is named rather than papered over.
///
/// **It is the one thing the driver kind would buy, and the driver kind
/// is deferred.** #184 ruled that the pane must additionally publish which
/// engine a result came from, because `columnTypes` alone cannot tell a
/// real `TINYINT` from an erased `BOOLEAN`; `Rows` has no such field and
/// adding one is a Go change outside #189. Everything else here is
/// driverless by construction — the TOKEN carries the difference — so this
/// is the whole of what is owed, stated rather than left to be
/// rediscovered.
private func booleanLiteral(_ token: JSONValue) -> Bool {
    switch token {
    case .bool(let flag): return flag
    case .integer(let value): return value != 0
    case .number(let value): return value != 0
    case .string(let text): return text.lowercased() == "true" || text == "1"
    default: return false
    }
}

/// The cap, then the document — and never both.
///
/// **The cap first**, because the operator's next act on an over-cap body
/// is to shrink it, and the document that emits after they do is a
/// different document. Reporting a syntax error in bytes that are not
/// going to be sent is the derived failure in another shape.
func bodyFailure(_ emitted: String) -> ApiSendFailure? {
    let bytes = emitted.utf8.count
    if bytes > apiOutboundBodyCap {
        // The exact count first, the human label second: measured on the
        // shipped binary, a body one byte over the cap rendered as "1.0
        // MiB, over the 1 MiB limit", which reads as a refusal of
        // something that is exactly AT the limit.
        return ApiSendFailure(
            region: .body,
            message: "The body this emits is \(bytes) bytes (\(apiByteCountLabel(bytes))), over "
                + "the \(apiOutboundBodyCapLabel) the send tool accepts — nothing would be sent. "
                + "A body this size is held in full in three processes.")
    }
    do {
        // **Wakil validates the EMITTED document, never the operator's
        // text.** Forced by the send's price: on the unconfirmed path
        // nobody reads it before it leaves, so a bad body's only account
        // of itself would be a silent 400.
        // `Data(_:)` over the string's own UTF-8 view rather than
        // `data(using:)`, which cannot fail for a Swift string and would
        // leave an unreachable branch to account for.
        _ = try JSONSerialization.jsonObject(
            with: Data(emitted.utf8), options: [.fragmentsAllowed])
        return nil
    } catch {
        let excerpt = emitted.count > 160 ? String(emitted.prefix(160)) + "…" : emitted
        return ApiSendFailure(
            region: .body,
            message: "The document this emits is not JSON: "
                + "\((error as NSError).localizedDescription) Emitted: \(excerpt)")
    }
}

/// Spells a byte count the way the cap is spelled, so a refusal compares
/// like with like. The counterpart of `byteCountLabel` in `httpsend.go`.
func apiByteCountLabel(_ count: Int) -> String {
    if count >= 1024 * 1024 {
        return String(format: "%.1f MiB", Double(count) / (1024 * 1024))
    }
    if count >= 1024 { return "\(count / 1024) KiB" }
    return "\(count) bytes"
}

// MARK: - The header field-name grammar

/// Whether `name` is an RFC 9110 field name.
///
/// **The pane owns the grammar and copies no deny list** (#158).
/// `Authorization`, `Cookie`, `Host`, `Proxy-*`, `Content-Type` and the
/// entry's own configured auth header are `rejectedCallerHeader`'s to
/// refuse, in Go, where the one policy list lives — a second copy here
/// would be free to disagree with the one that actually decides, and the
/// entry's configured header is deliberately not published to the app at
/// all.
func isFieldName(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    let punctuation = Set("!#$%&'*+-.^_`|~")
    return name.allSatisfy { character in
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1, scalar.isASCII
        else { return false }
        return character.isLetter || character.isNumber || punctuation.contains(character)
    }
}

/// Every C0 control and DEL — **tab included**, which is wider than Go,
/// where a tab and a space both pass verbatim. A space is legal here too;
/// a tab is not, because a header value carrying one is a value whose
/// meaning depends on which parser reads it.
func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value <= 0x1F || scalar.value == 0x7F
}

/// How a control character is named to the operator. Spelled out for the
/// four that are typed by accident, and by code point for the rest — a
/// refusal naming "U+0001" is one a reader can look up, where an invisible
/// character quoted back is one they cannot see.
func nameOfControl(_ scalar: Unicode.Scalar) -> String {
    switch scalar.value {
    case 0x0A: return "a newline"
    case 0x0D: return "a carriage return"
    case 0x09: return "a tab"
    case 0x00: return "a NUL"
    default:
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "a control character (U+\(String(repeating: "0", count: max(0, 4 - hex.count)))\(hex))"
    }
}

// MARK: - Types a cell carries

/// The type names whose cells refuse rather than emit.
///
/// **Matched on the normalised NAME, never on a substring**, and two
/// measured over-matches are why: a substring scan for `BINARY` refuses
/// MySQL's `VARCHAR(20) BINARY` collation modifier — a text column — and
/// Oracle's `BINARY_FLOAT`, which is a number. Neither driver is in the
/// tree today, which is exactly when a rule like this is cheapest to get
/// right.
private let binaryTypeNames: Set<String> = [
    "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB",
    "BINARY", "VARBINARY", "BYTEA", "IMAGE", "RAW", "LONG RAW",
]

/// Whether a declared type names a binary column.
///
/// Mongo's `bson.Binary` normalises to `BINARY` and lands here too, though
/// the token-shape check upstream reaches it first — and must, because
/// Mongo's binary crosses LOSSLESSLY and "already corrupted" would be the
/// wrong sentence for it (#184).
func isBinaryType(_ declared: String) -> Bool {
    binaryTypeNames.contains(normalisedTypeName(declared))
}

/// The type names whose cells emit UNQUOTED into a JSON value position.
///
/// **A set of names rather than a prefix match**, because `INTERVAL`
/// starts with `INT` and a `DECIMAL` is not the only thing that begins
/// with `DEC`. The spelling is normalised first — a declared type arrives
/// as `DECIMAL(10,2)` on sqlite, scale-dropped `DECIMAL` on MySQL,
/// `bson.Decimal128` on Mongo and `int`/`double` from Mongo's inference —
/// so the parenthesised part, the MySQL modifiers and the `bson.` prefix
/// come off before the lookup.
private let numericTypeNames: Set<String> = [
    "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
    "INT2", "INT4", "INT8", "INT32", "INT64", "LONG", "SERIAL", "BIGSERIAL",
    "DECIMAL", "DECIMAL128", "NUMERIC", "NUMBER", "MONEY", "SMALLMONEY",
    "FLOAT", "FLOAT32", "FLOAT64", "DOUBLE", "DOUBLE PRECISION", "REAL",
]

private let booleanTypeNames: Set<String> = ["BOOL", "BOOLEAN"]

func isNumericType(_ declared: String) -> Bool { numericTypeNames.contains(normalisedTypeName(declared)) }

func isBooleanType(_ declared: String) -> Bool { booleanTypeNames.contains(normalisedTypeName(declared)) }

/// `DECIMAL(10,2)` → `DECIMAL`; `INT UNSIGNED` → `INT`; `bson.Decimal128`
/// → `DECIMAL128`.
private func normalisedTypeName(_ declared: String) -> String {
    var name = declared.uppercased()
    if let paren = name.firstIndex(of: "(") { name = String(name[name.startIndex..<paren]) }
    if name.hasPrefix("BSON.") { name = String(name.dropFirst("BSON.".count)) }
    for modifier in [" UNSIGNED", " ZEROFILL", " SIGNED"] {
        while name.hasSuffix(modifier) { name = String(name.dropLast(modifier.count)) }
    }
    return name.trimmingCharacters(in: .whitespaces)
}

extension JSONValue {
    /// Whether this token can fill a single request field.
    ///
    /// An object or an array cannot: a Mongo sub-document, a Mongo array
    /// and a `bson.Binary` all arrive as one, and #184 ruled the refusal
    /// on the token's shape precisely so that no list of type names has to
    /// be kept.
    var isScalar: Bool {
        switch self {
        case .object, .array: return false
        default: return true
        }
    }
}

/// The source pane's rows, as resolution reads them.
///
/// **Not `DataSurfaceSnapshot` itself**, although §*The new seam*'s
/// signature names it — a deviation recorded on
/// [#179](https://github.com/yehia-khalil/rafiq/issues/179) rather than
/// quietly matched. Two differences, each load-bearing. It carries
/// `generation`, which a snapshot does not and should not: a counter that
/// exists only so a capture can tell "these rows" from "rows that replaced
/// them" is not a fact an agent should be reading. And it carries no
/// `columnTypes`, because a part's type is pinned at bind time
/// (`ApiValueSource.declaredType`) and resolution never asks the pane.
public struct ApiSourcePane: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[JSONValue]]
    /// Bumped whenever the pane replaces its rows. A captured value
    /// records the generation it was taken at and dies when this moves.
    public let generation: Int

    public init(columns: [String], rows: [[JSONValue]], generation: Int) {
        self.columns = columns
        self.rows = rows
        self.generation = generation
    }

    /// The row whose key columns hold these values, or `nil`.
    ///
    /// **Compared as text**, which is what `keyValues` already are: a key
    /// above 2^53 cannot cross as a number, and the comparison has to
    /// agree with the form the binding recorded.
    func row(keyColumns: [String], keyValues: [String]) -> [JSONValue]? {
        guard keyColumns.count == keyValues.count, !keyColumns.isEmpty else { return nil }
        let indices = keyColumns.map { columns.firstIndex(of: $0) }
        guard indices.allSatisfy({ $0 != nil }) else { return nil }
        return rows.first { row in
            zip(indices, keyValues).allSatisfy { index, expected in
                guard let index, index < row.count else { return false }
                return PaneCell(row[index]).text == expected
            }
        }
    }
}

// MARK: - The read send

/// What one send left behind: the draft as it now stands, and the response.
public struct ApiRequestOutcome: Sendable, Equatable {
    public let draft: ApiDraft
    public let response: ApiResponseSnapshot
    /// Whether the send was cancelled in flight (W14). Recent records it so: a read as
    /// cancelled, a mutation as cancelled and possibly landed.
    public let cancelled: Bool
    /// The path as it was sent, each bound value beside its name (`apiShownPath`, W18), taken
    /// when the send resolved. Recent's row draws it. `nil` only for an outcome built by hand.
    public let shownPath: String?

    public init(
        draft: ApiDraft, response: ApiResponseSnapshot, cancelled: Bool = false,
        shownPath: String? = nil
    ) {
        self.draft = draft
        self.response = response
        self.cancelled = cancelled
        self.shownPath = shownPath
    }
}

/// A value in a shown path or a Bound row, shortened past 24 characters (W18): 23 and `…`, so
/// a JSON blob or a token-length key keeps a row on one line.
public func apiShortened(_ text: String) -> String {
    text.count > 24 ? String(text.prefix(23)) + "…" : text
}

/// The path as it was sent, for Recent (W18): literals as typed, each bound value as
/// `<name:value>` with the value it resolved to at send, and `<name>` for a hole or a value
/// that did not resolve. **Screen-only.** `read_pane`'s `path` stays the draft as written, and
/// `sentUrl` already carries the URL that left.
public func apiShownPath(_ path: [ApiPart], sources: [String: ApiSourcePane]) -> String {
    path.map { part -> String in
        switch part {
        case .literal(let text): return text
        case .slot(let name): return "<\(name)>"
        case .bound(let bound):
            guard case .value(_, let cell) = resolvePart(part, sources: sources) else {
                return "<\(bound.name)>"
            }
            return "<\(bound.name):\(apiShortened(ApiCellText.of(cell)))>"
        }
    }.joined()
}

/// What a send cancelled in flight left on the pane (W14).
///
/// **A read is cancelled, plainly** — it changed nothing. **A mutation is fate-unknown**: the
/// cancel aborts the request, but the server may already have had it, so the pane says so
/// rather than implying nothing happened.
public func apiCancelledResponse(method: String, waitedMs: Int, environment: String) -> ApiResponseSnapshot {
    guard apiIsReadMethod(method) else {
        return .unknown(ApiFateUnknown(
            reason: apiCancelledLine(waitedMs: waitedMs) + " — the server may already have it",
            environment: environment))
    }
    return .cancelled(ApiCancelled(waitedMs: waitedMs, environment: environment))
}

/// Sends a `GET`, or refuses without sending.
///
/// **A thin caller over the resolver.** Resolution already decides whether
/// a draft can be sent and says why when it cannot; this adds the wire and
/// nothing else. Two answers to "is this request ready" would be one too
/// many, and `read_pane`'s `resolves` is computed by the same call, so the
/// pane and the send cannot disagree.
///
/// **It consults no gate, in any environment** (#193). A `GET` costs
/// nothing and reading is never priced like writing — that is `api_send`'s
/// job, and the reason the two are separate actions at all is that
/// `ActionKind` is fixed per action, so one send would price a `GET` at
/// `.gate`.
///
/// **A refused send clears nothing.** The draft still holds the only copy
/// of what the operator meant, and a send that wiped it on refusal would
/// cost them the request to tell them it was not ready.
///
/// **No `wakil-http` is fate-unknown rather than a failure.** A window
/// with no client cannot say whether anything left; calling that a
/// transport failure would state something it does not know, and calling
/// it a refusal would blame the draft, which resolved.
/// Which `wakil-http` tool a send goes to.
///
/// **Two tools, not one, and the split is Go's rather than Swift's.**
/// `request` runs `AssertHTTPReadOnly` and refuses a mutation method
/// outright; `send` is the write counterpart and is the only one with
/// `body` and `contentType` fields at all. Calling `request` for a POST
/// does not fail loudly — `mcpx.ToolErr` answers with `isError: true`
/// rather than a protocol error — so the mistake reads as fate-unknown
/// and tells an operator their write *may* have landed when nothing left.
public enum ApiSendTool: String, Sendable {
    case request
    case send

    /// The tool a method belongs to, which is the same split
    /// `api_request` and `api_send` make one level up.
    public static func forMethod(_ method: String) -> ApiSendTool {
        apiIsReadMethod(method) ? .request : .send
    }
}

public func apiRequest(
    draft: ApiDraft, sources: [String: ApiSourcePane], environment: String,
    http: (any ToolCaller)?, credentialed: Bool = false, origin: String? = nil,
    timeout: TimeInterval = 30
) async -> ApiRequestOutcome {
    // W18: the values as they stand at send, so Recent shows what this send carried.
    let shown = apiShownPath(draft.path, sources: sources)
    switch resolveDraft(draft, sources: sources, credentialed: credentialed) {
    case .failure(let refusal):
        return ApiRequestOutcome(draft: draft, response: .refusal(refusal), shownPath: shown)

    case .success(let wire):
        guard let http else {
            return ApiRequestOutcome(draft: draft, response: .unknown(ApiFateUnknown(
                reason: "this window has no wakil-http client, so nothing can say whether the "
                    + "request left. It was not refused: the draft resolved.",
                environment: environment)), shownPath: shown)
        }
        let started = Date()
        do {
            let reply = try await http.callTool(
                name: ApiSendTool.forMethod(wire.method).rawValue,
                arguments: apiWireArguments(wire), timeout: timeout)
            return ApiRequestOutcome(
                draft: draft,
                response: apiResponse(
                    from: reply, environment: environment, started: started,
                    // **The URL that left, built here.** `HTTPResult`
                    // carries status, headers, body and truncated and no
                    // URL, so nothing downstream can learn it from the
                    // reply — and #194's journal line exists to record
                    // exactly this.
                    url: apiSentURL(wire, origin: origin)),
                shownPath: shown)
        } catch is CancellationError {
            // W14: the operator or the agent cancelled. A read is cancelled, plainly. A mutation
            // may have landed, so it is the fate-unknown state (`apiCancelledResponse`).
            return ApiRequestOutcome(
                draft: draft,
                response: apiCancelledResponse(
                    method: wire.method,
                    waitedMs: Int(Date().timeIntervalSince(started) * 1000),
                    environment: environment),
                cancelled: true, shownPath: shown)
        } catch {
            return ApiRequestOutcome(draft: draft, response: .transport(ApiTransportFailure(
                stage: "send",
                waitedMs: Int(Date().timeIntervalSince(started) * 1000),
                reason: "\(error)",
                environment: environment)), shownPath: shown)
        }
    }
}

/// The arguments `wakil-http`'s `request` and `send` tools take.
///
/// **Written against `reqArg` and `sendArg` in `cmd/wakil-http/main.go`,
/// field by field, and `ApiWireArgumentsTests` pins each name.** The first
/// version of this function invented three of them — `entry` for what Go
/// calls `api`, and arrays of `{name, value}` for what Go declares as
/// `map[string]string`. None of it failed loudly: an unknown field is
/// ignored by Go's unmarshal, so the entry silently became "", and a
/// single-entry environment resolved anyway. The stub in the tests
/// ignored both the tool name and the arguments, so nothing anywhere
/// compared the two sides.
func apiWireArguments(_ wire: ApiWireRequest) -> JSONValue {
    var arguments: [String: JSONValue] = [
        // `api`, not `entry`. Omitted-when-empty, because Go's
        // `omitempty` branch is what resolves a single-entry environment.
        "method": .string(wire.method),
        "path": .string(wire.path),
    ]
    if !wire.entry.isEmpty { arguments["api"] = .string(wire.entry) }
    // **Maps, because that is what the tool declares** — and what
    // `ApiWireRequest.query`'s own doc comment already said it would need.
    if !wire.query.isEmpty {
        var query: [String: JSONValue] = [:]
        for item in wire.query { query[item.name] = .string(item.value) }
        arguments["query"] = .object(query)
    }
    if !wire.headers.isEmpty {
        var headers: [String: JSONValue] = [:]
        for header in wire.headers { headers[header.name] = .string(header.value) }
        arguments["headers"] = .object(headers)
    }
    // **An empty body sends no body and no content type** — three wire
    // states rather than two, so a content type left beside an emptied
    // body is not smuggled through here. `contentType` is also the ONLY
    // channel for it: `sendArg` refuses a Content-Type in `headers`.
    if let body = wire.body {
        arguments["body"] = .string(body)
        if let contentType = wire.contentType { arguments["contentType"] = .string(contentType) }
    }
    return .object(arguments)
}

/// The URL that left, composed from what was sent.
///
/// **Built here because the reply does not carry one.** `HTTPResult`
/// declares `status`, `headers`, `body` and `truncated` — no URL — so a
/// reader of the reply alone cannot say where the request went, and
/// #194's journal line is precisely a record of that. When the pane knows
/// no origin the path stands alone rather than being prefixed with a
/// guess.
func apiSentURL(_ wire: ApiWireRequest, origin: String?) -> String {
    var url = (origin.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? "") + wire.path
    if !wire.query.isEmpty {
        let pairs = wire.query.map { item -> String in
            let name = item.name.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? item.name
            let value = item.value.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? item.value
            return "\(name)=\(value)"
        }
        url += "?" + pairs.joined(separator: "&")
    }
    return url
}

/// Reads `wakil-http`'s reply into a response.
///
/// **Numbers are read with `intValue`, never by matching `.number`.**
/// `HTTPResult.Status` is a Go `int`, so it arrives as a JSON integer and
/// `JSONValue.init(from:)` decodes `Int64` before `Double` — a `.number`
/// pattern never matches it. The first version of this function used one,
/// which made `ok` unreachable in production: every successful reply
/// became fate-unknown. That is the same defect the Phase 1 review found
/// in `api_bind`'s `row`, in a second place, and the tests missed it
/// again for the same reason — they hand-built `.number(200)`, which the
/// wire never sends.
///
/// **`isError` is checked first, and it is a REFUSAL rather than an
/// unknown.** A tool-side refusal — a non-https base URL, a `..` segment,
/// a rejected `Authorization` header, an unknown entry — comes back as a
/// successful call carrying `isError: true`. Recording that as
/// fate-unknown would tell an operator their write may have reached the
/// server when Go refused to send it, and would add a `recent` row for a
/// request that never happened.
///
/// **A reply with no status is fate-unknown, not an `ok` with a zero.**
/// The tool answered, but not with something that says what happened, and
/// a `0` drawn beside a URL reads as a status the server sent.
func apiResponse(
    from reply: JSONValue, environment: String, started: Date, url: String
) -> ApiResponseSnapshot {
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    guard case .object(let envelope) = reply else {
        return .unknown(ApiFateUnknown(
            reason: "wakil-http answered with something that is not a result object, so what "
                + "reached the server is unknown.",
            environment: environment))
    }
    if case .bool(true)? = envelope["isError"] {
        let text = apiToolErrorText(envelope)
        // **A tool error is a refusal OR a transport failure, and the two
        // must not be collapsed.** `mcpx.ToolErr` answers both as a
        // successful call carrying `isError`, with a sentence and no
        // discriminator — so the first version of this made every one a
        // refusal, which said "nothing was sent" about a request that had
        // left and failed on the wire.
        //
        // **`request failed: ` is the marker, and Go writes it in exactly
        // one place** — `doRequest`'s `client.Do` branch
        // (`httpclient.go`). Every other `UserError` there is a refusal
        // Go authored before sending: a bad path, a disallowed header, an
        // unknown entry. `ApiWireContractTests` pins the prefix against
        // that source, because a marker matched on one side and written
        // on the other is two answers to one question.
        if text.contains(apiTransportFailureMarker) {
            return .transport(ApiTransportFailure(
                stage: "send",
                waitedMs: elapsed,
                reason: text,
                environment: environment))
        }
        return .refusal(ApiSendRefusal(failures: [
            ApiSendFailure(region: nil, message: text)
        ]))
    }
    guard case .object(let content)? = envelope["structuredContent"] else {
        return .unknown(ApiFateUnknown(
            reason: "wakil-http answered with no structured content, so what reached the server "
                + "is unknown.",
            environment: environment))
    }
    guard let status = content["status"]?.intValue else {
        return .unknown(ApiFateUnknown(
            reason: "wakil-http answered without a status, so whether the request arrived is "
                + "unknown.",
            environment: environment))
    }
    var headers: [String: String] = [:]
    if case .object(let fields)? = content["headers"] {
        for (name, value) in fields {
            if case .string(let text) = value { headers[name] = text }
        }
    }
    var body = ""
    if case .string(let text)? = content["body"] { body = text }
    var truncated = false
    if case .bool(let flag)? = content["truncated"] { truncated = flag }

    return .ok(ApiResponseOK(
        status: status,
        // Composed by the caller from what was sent: `HTTPResult` carries
        // no URL.
        url: url,
        environment: environment, headers: headers, body: body,
        // `HTTPResult` reports no timing either, so this is Wakil's own
        // measurement and is named as elapsed rather than server time.
        durationMs: elapsed,
        byteCount: body.utf8.count,
        truncated: truncated))
}

/// What `wakil-http` prefixes a transport failure with, written in one
/// place in `doRequest` and matched here. Pinned against the Go source by
/// `ApiWireContractTests`.
let apiTransportFailureMarker = "request failed: "

/// The sentence a tool-side refusal carried, or a stand-in.
func apiToolErrorText(_ envelope: [String: JSONValue]) -> String {
    if case .array(let content)? = envelope["content"] {
        for item in content {
            if case .object(let entry) = item, case .string(let text)? = entry["text"] {
                return text
            }
        }
    }
    return "wakil-http refused the request and gave no reason."
}

