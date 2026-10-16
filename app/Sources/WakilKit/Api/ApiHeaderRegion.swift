import Foundation

/// The header region's **three classes of row** (#158, #116) — one true
/// list of what goes on the wire as a header, rather than an editor of the
/// operator's rows with Wakil's own two hidden somewhere else.
///
/// | Class | Example | Editable |
/// |---|---|---|
/// | **authored** | `x-tenant-id` | yes |
/// | **supplied** | `authorization`, *supplied by the billing entry* | no |
/// | **derived** | `content-type` | **yes**, free text, literal-only |
///
/// **The `authorization` row is what makes the deny list enforceable with
/// no copy of it here.** An operator who types `authorization` hits the
/// duplicate rule and is told *the billing entry supplies this* — so
/// `rejectedCallerHeader`'s load-bearing entry is enforced by the display
/// being honest, and `rejectedCallerHeader` stays the one policy list, in
/// Go, where it can be changed in one place.
public enum ApiHeaderRowClass: Sendable, Equatable {
    /// The operator's own row. Bindable, because #122 made a header value
    /// one of the four data positions.
    case authored
    /// The entry's. Drawn with **no value and no ref named** — the
    /// credential resolves inside Go at the moment the request leaves and
    /// never enters the app, so there is nothing here to draw and nothing
    /// to mask.
    case supplied
    /// Wakil's. `content-type` is the one derived row that is **editable**
    /// (#116) and the one field on the draft that admits no parts. A fixed
    /// `+json` list was proposed and declined as a fence:
    /// `application/merge-patch+json` and `application/vnd.api+json` are
    /// not enumerable in advance.
    case derived
}

/// One row of the header region, as the surface draws it and as
/// `read_pane` publishes it — **one list, so the two orderings cannot
/// disagree**.
public struct ApiHeaderRegionRow: Sendable, Equatable {
    public let name: String
    /// `nil` for a row whose value the app does not hold: `authorization`
    /// always, and `content-type` while the draft names none and the send
    /// tool's own default is what would apply. A `nil` row is drawn and is
    /// **not** published — `read_pane` carries the rows that have values.
    public let value: [ApiPart]?
    /// The sentence drawn in place of a value, for a row the operator did
    /// not author. It **names no ref**, by #118's redaction rule.
    public let provenance: String?
    public let rowClass: ApiHeaderRowClass

    public init(
        name: String, value: [ApiPart]?, provenance: String?, rowClass: ApiHeaderRowClass
    ) {
        self.name = name
        self.value = value
        self.provenance = provenance
        self.rowClass = rowClass
    }

    /// Whether the operator may type in this row. Everything but the
    /// entry's own — which is why `authorization` is the only row that is
    /// not editable, a property with a reason behind it rather than the
    /// default.
    public var isEditable: Bool { rowClass != .supplied }
}

/// Every row of the header region, in the order it is drawn **and** the
/// order `read_pane` publishes.
///
/// **Name-sorted with Wakil's rows last** (#158 ruling 4). A map has no
/// order, so any order Wakil shows is one Wakil chose; a sorted one is
/// reproducible across a re-render and puts a would-be duplicate adjacent
/// to the row it collides with. **Accepted cost, stated:** a row does not
/// stay where the operator typed it, which is the other way round from
/// every client #111 measured.
public func apiHeaderRegion(draft: ApiDraft, credentialed: Bool) -> [ApiHeaderRegionRow] {
    let authored = apiHeaderRowsSorted(draft.headers.map {
        ApiHeaderRegionRow(name: $0.name, value: $0.value, provenance: nil, rowClass: .authored)
    })
    return authored + apiWakilHeaderRows(
        entry: draft.entry, contentType: draft.contentType, credentialed: credentialed)
}

/// Name-sorted, case-insensitively, and **totally ordered**.
///
/// `Swift.sorted(by:)` is introsort and is **not stable**, so a
/// case-insensitive comparison alone leaves two rows named `Accept` and
/// `accept` free to swap between renders — which is the one thing this
/// ordering exists to prevent. The exact spelling breaks the first tie and
/// the drafted position breaks the second, so two rows are only ever
/// interchangeable when they are the same row.
///
/// **Two rows that collide are still both drawn.** The duplicate is
/// refused at SEND, by `resolveHeaders`, and #158 is explicit that a
/// would-be duplicate should sit *adjacent to the row it collides with*
/// rather than be swallowed — so the order has to be defined for a case
/// the region deliberately keeps.
func apiHeaderRowsSorted(_ rows: [ApiHeaderRegionRow]) -> [ApiHeaderRegionRow] {
    rows.enumerated()
        .sorted { left, right in
            let (a, b) = (left.element.name, right.element.name)
            let (lowerA, lowerB) = (a.lowercased(), b.lowercased())
            if lowerA != lowerB { return lowerA < lowerB }
            if a != b { return a < b }
            return left.offset < right.offset
        }
        .map(\.element)
}

/// The rows Wakil itself puts on the wire, sorted among themselves.
///
/// **`content-type` is always here and `authorization` only when the entry
/// has a credential.** An entry with no `authRef` sends no `Authorization`,
/// so drawing the row would be the region claiming something that is not
/// true — and an operator who then types `authorization` themselves falls
/// through to `rejectedCallerHeader` in Go, which refuses every caller's.
/// That is the intended split: the display enforces what the display can
/// see, and the policy list stays where it is.
func apiWakilHeaderRows(
    entry: String, contentType: String, credentialed: Bool
) -> [ApiHeaderRegionRow] {
    var rows: [ApiHeaderRegionRow] = []
    if credentialed {
        rows.append(ApiHeaderRegionRow(
            name: "authorization", value: nil,
            provenance: "supplied by the \(entry.isEmpty ? "api" : entry) entry",
            rowClass: .supplied))
    }
    let named = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
    rows.append(ApiHeaderRegionRow(
        name: "content-type", value: named.isEmpty ? nil : [.literal(named)],
        // No provenance sentence: an empty content type is not Wakil
        // supplying something, it is the draft naming none — and what
        // happens then is the send tool's to decide, not this pane's to
        // predict.
        provenance: nil, rowClass: .derived))
    return apiHeaderRowsSorted(rows)
}

/// The names Wakil already occupies, and the sentence each owes an
/// operator who types it again.
///
/// **Built by the same function that draws them**, so the refusal and the
/// display cannot disagree about which rows exist — which is the whole of
/// why #158 made the `authorization` row honest instead of copying the
/// deny list.
///
/// It passes an empty `contentType` because reservation does not depend on
/// the value: `content-type` is Wakil's row on every draft, named or not,
/// and a second one for it would be lost whichever way. `credentialed` is
/// the opposite and is the caller's to supply — an entry with no
/// credential draws no `authorization` row, so there is nothing to collide
/// with and the refusal is `rejectedCallerHeader`'s to make, in Go.
func apiReservedHeaderRefusals(entry: String, credentialed: Bool) -> [String: String] {
    var refusals: [String: String] = [:]
    for row in apiWakilHeaderRows(entry: entry, contentType: "", credentialed: credentialed) {
        switch row.rowClass {
        case .supplied:
            refusals[row.name] = "“\(row.name)” is \(row.provenance ?? "supplied by the entry"). "
                + "The credential resolves inside the capability layer at the moment the "
                + "request leaves and this pane never holds it, so there is nothing here to "
                + "override."
        case .derived:
            refusals[row.name] = "“\(row.name)” is Wakil's own row on this draft. A header "
                + "region is a map, not a list, so set the draft's content type rather than "
                + "adding a second row for it."
        case .authored:
            continue
        }
    }
    return refusals
}

// MARK: - Final review I3: the content-type field follows the draft

/// The content-type field's text as the draft holds it: the derived row's value, `""` while
/// the draft names none — what the box draws, and what its Decision 27 mark is noted against.
///
/// **The pane watches this**: when it changes — the operator's commit landing, or an agent's
/// write — the box's editor is forgotten and its mark re-noted clean from the new value, as a
/// split field does on `onChange(of: parts)`. Noted only on keystrokes, the mark stayed dirty
/// after the operator's own commit and refused the agent's next content-type write; and an
/// editor never cleared kept the operator's old text over the agent's value.
public func apiContentTypeText(_ request: ApiRequestSnapshot) -> String {
    let row = request.headers.first { $0.rowClass == .derived }
    return apiRenderedPath(row?.value ?? [])
}

/// Whether committing `text` leaves the content type as the field draws it — the region trims
/// the draft's value, so `application/json ` over `application/json` changes nothing on screen.
///
/// **No write would change `apiContentTypeText`**, so nothing would forget the box; the pane
/// forgets it and notes it clean itself, dispatching nothing (I2's rule for the path box).
public func apiContentTypeCommitIsNoOp(_ request: ApiRequestSnapshot, text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines) == apiContentTypeText(request)
}
