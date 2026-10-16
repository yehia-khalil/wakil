import Foundation

/// Amendment 8b — `+ query`, `+ header` and `×`, and the header deny list refused at the
/// gesture rather than only at Send.
///
/// **No new action.** Both the add and the remove gesture write the region whole, through the
/// same `api_set_request` a row edit already uses — `apiRowAdd` and `apiRowRemoveWrite` are
/// pure rulings about what to write, never a dispatch of their own.
///
/// **Per 8d, the entry's own `authHeader` is NOT refused here.** `list_apis` deliberately
/// publishes neither `authRef` nor `authHeader` (#179), so this window cannot know it; Go's
/// existing dynamic deny list refuses it at Send, inside the one aggregated refusal.

/// Which region a row gesture targets.
public enum ApiRowRegion: Sendable, Equatable {
    case query, header
}

/// What `+ query` / `+ header` decided.
public enum ApiRowAdd: Equatable {
    /// Dispatch this `api_set_request`.
    case write(JSONValue)
    /// The name was `content-type`: go to Wakil's own row instead of adding a second one.
    case focusContentType
    /// Refused on screen. Nothing dispatched.
    case refused(String)
}

/// What `authorization` is refused with — the honest route, named so the operator is not left
/// to guess where a credential actually comes from.
public let apiAuthorizationRefusal =
    "authorization comes from the API entry's credential (wakil secrets set-api), not from a "
    + "typed header"

/// What a blank header name is refused with — the header twin of `ApiPathQueryRefusal.namelessRow`.
private let apiHeaderNameRefusal = "a header needs a name"

/// `+ query` / `+ header`: adds a row with an empty value, or refuses before anything is typed.
///
/// **The name is kept exactly as typed** (the hole rule) — trimming is only to test whether it
/// is blank; the row itself carries what the operator wrote. Header names compare
/// case-insensitively against the deny list alone — the deny list is a fixed vocabulary, not a
/// count of the operator's own rows. `apiRowOccurrence` and `apiRowRemoveWrite`, by contrast,
/// count rows by their **exact** name (fix round 1, Important); the case-insensitive comparison
/// stays where Go applies it, in the duplicate refusal at Send.
public func apiRowAdd(
    draft: ApiRequestSnapshot, region: ApiRowRegion, name: String, pane: String
) -> ApiRowAdd {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        switch region {
        case .query: return .refused(ApiPathQueryRefusal.namelessRow.line)
        case .header: return .refused(apiHeaderNameRefusal)
        }
    }

    switch region {
    case .header:
        let lower = name.lowercased()
        if lower == "content-type" { return .focusContentType }
        if lower == "authorization" { return .refused(apiAuthorizationRefusal) }
        if lower == "cookie" || lower == "host" || lower.hasPrefix("proxy-") {
            return .refused(
                "\(name) is never set by hand: wakil-http refuses authorization, cookie, "
                + "host and proxy-* headers")
        }
    case .query:
        if let forbidden = name.first(where: { apiQueryNameForbidden.contains($0) }) {
            return .refused(ApiPathQueryRefusal.forbiddenInName(forbidden).line)
        }
    }

    let built = apiDraftForWrite(draft)
    switch region {
    case .query:
        var rows = built.query.map { apiNamedRowJSON(name: $0.name, value: $0.value, sources: [:]) }
        rows.append(.object(["name": .string(name), "value": .array([])]))
        return .write(.object(["pane": .string(pane), "query": .array(rows)]))
    case .header:
        var rows = built.headers.map { apiNamedRowJSON(name: $0.name, value: $0.value, sources: [:]) }
        rows.append(.object(["name": .string(name), "value": .array([])]))
        return .write(.object(["pane": .string(pane), "headers": .array(rows)]))
    }
}

/// `×`: the write that drops one occurrence of `name` and carries every other row through, or
/// `nil` when there is no such occurrence to drop — which is also the answer for Wakil's own
/// rows, because `apiDraftForWrite` never holds them.
///
/// `row` picks among rows sharing a name, counted the way `apiRowOccurrence` counts them:
/// **exact name, for both regions** (fix round 1, Important — the brief's "case-insensitive for
/// headers" was wrong about `apiRowOccurrence`, whose own test says "that exact name"). The
/// case-insensitive comparison stays where Go applies it: the duplicate refusal at Send.
public func apiRowRemoveWrite(
    draft: ApiRequestSnapshot, region: ApiRowRegion, name: String, row: Int, pane: String
) -> JSONValue? {
    let built = apiDraftForWrite(draft)
    switch region {
    case .query:
        var occurrence = -1
        var removed = false
        var rows: [ApiQueryRow] = []
        for candidate in built.query {
            if candidate.name == name {
                occurrence += 1
                if occurrence == row, !removed {
                    removed = true
                    continue
                }
            }
            rows.append(candidate)
        }
        guard removed else { return nil }
        let json = rows.map { apiNamedRowJSON(name: $0.name, value: $0.value, sources: [:]) }
        return .object(["pane": .string(pane), "query": .array(json)])
    case .header:
        var occurrence = -1
        var removed = false
        var rows: [ApiHeaderRow] = []
        for candidate in built.headers {
            if candidate.name == name {
                occurrence += 1
                if occurrence == row, !removed {
                    removed = true
                    continue
                }
            }
            rows.append(candidate)
        }
        guard removed else { return nil }
        let json = rows.map { apiNamedRowJSON(name: $0.name, value: $0.value, sources: [:]) }
        return .object(["pane": .string(pane), "headers": .array(json)])
    }
}

// MARK: - What the row controls draw (Task 5)

/// The field a region's rows are, for the region-wide rulings below.
private func apiRowField(_ region: ApiRowRegion, _ name: String) -> ApiDraftField {
    switch region {
    case .query: return .query(name)
    case .header: return .header(name)
    }
}

/// Whether `+ query` / `+ header` is live.
///
/// Live over a bound row too, since W16: the add carries the binding back.
public func apiRowAddIsEnabled(_ request: ApiRequestSnapshot, _ region: ApiRowRegion) -> Bool {
    apiFieldIsTypable(request, apiRowField(region, ""))
}

/// Whether the row at `index` of the snapshot's region draws a `×` (8b).
///
/// **The operator's own rows only** — a header row of class `.authored`, never Wakil's
/// `content-type` or the entry's `authorization` — and **not a row that holds a binding of
/// its own** (8b): that row's chip unbinds first. Since W16 a binding no longer locks its
/// neighbours: `×` writes the region whole, and that write carries their bindings back.
public func apiRowDrawsRemove(
    _ request: ApiRequestSnapshot, _ region: ApiRowRegion, at index: Int
) -> Bool {
    switch region {
    case .query:
        guard request.query.indices.contains(index) else { return false }
        // W16: a neighbour of a binding is removable; the bound row itself unbinds first (8b).
        return apiRowIsTypable(request.query[index].value)
    case .header:
        guard request.headers.indices.contains(index),
              request.headers[index].rowClass == .authored
        else { return false }
        return apiRowIsTypable(request.headers[index].value ?? [])
    }
}

/// The key (`apiFieldKey`, without the `api.` surface) the row `+ query` / `+ header` adds will
/// be drawn under — where focus goes once it lands.
///
/// **It is the next occurrence of that exact name**, counted as `apiRowOccurrence` counts, so a
/// duplicate's box is `query[1].t` and focus lands in the row just added, not its twin.
public func apiRowAddedKey(
    _ request: ApiRequestSnapshot, _ region: ApiRowRegion, name: String
) -> String {
    let field = apiRowField(region, name)
    let end = region == .query ? request.query.count : request.headers.count
    return apiFieldKey(field, row: apiRowOccurrence(request, field, at: end))
}

/// A row's `×`, per field (10a): every held field of that region at or after the removed row
/// goes, because their rows shift and each of those keys now names a different row.
public func apiBoxesRemovingRow(
    _ held: ApiHeld, region: ApiRowRegion, name: String, row: Int
) -> ApiHeld {
    let field = apiRowField(region, name)
    return held.filter { key, _ in !(key.field == field && key.row >= row) }
}
