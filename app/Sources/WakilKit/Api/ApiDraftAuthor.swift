import Foundation

/// **One pane, one draft, one author** (#191, Decision 27) — the policy an
/// api pane's draft write is admitted or refused by.
///
/// A draft request has nothing underneath it: it *is* what goes on the
/// wire. Gate the agent's write and the agent's request does not exist;
/// let it land and the operator's edit is gone. One writer has to lose,
/// and this file is where that is decided — in one function, on values,
/// so that the rule can be read and tested without dispatching an action
/// or drawing a pane.
///
/// **Why the DB pane's rule does not transfer.** `shouldAdoptSubject`
/// gates the query line's *text* while `db_run_query` writes the pane's
/// rows regardless, so what it protects is a **description** over a
/// subject that changed anyway, and its worst case is a line that lags.
/// There is no description here, so the same shape would protect nothing.
///
/// **Why not `operatorOnlyActions`.** That list looks like the precedent
/// and cannot be used: it is a static set of names denied at the MCP
/// permission layer, so an action in it is never offered to an agent at
/// all. Nothing in this pane is operator-only — the whole point of #190 is
/// that one action serves both writers — and what is being decided here is
/// about the *state of the draft* at the moment of one call, which no name
/// list can see.

/// One editable field of an api pane's draft — the unit the operator's
/// focus is marked in, and the unit a refusal names.
///
/// **Not `ApiRegion`**, which answers a different question: where a *send*
/// failure is, for the surface to mark. The two disagree exactly at
/// `contentType`, which `api_set_request` names with a key of its own but
/// which `resolveDraft` reports failures against under `.body` — so one
/// type serving both would have to be wrong about one of them.
///
/// **`method` is here and no SURFACE marks it today.** The verb is chosen
/// rather than typed, and a chooser holds no cursor: clicking it *is* the
/// write. It is a case anyway so that the map from a write's
/// keys to the fields they overwrite is total — a key with no field to
/// collide with would be a silent hole in the rule rather than a stated
/// one.
public enum ApiDraftField: Sendable, Equatable, Hashable {
    case method
    case path
    /// One query row, by the name it carries.
    case query(String)
    /// One header row, by name — the operator's own rows only. The entry's
    /// `authorization` row is not editable and cannot be marked
    /// (`ApiHeaderRegionRow.isEditable`).
    case header(String)
    /// Wakil's own `content-type` row, which is free text and the one
    /// field on the draft that admits no parts (#116).
    case contentType
    case body

    /// How the field is named to the agent whose write it refused.
    ///
    /// **Four of the six DELEGATE to `ApiRegion.label`** rather than
    /// re-spelling it. The two types answer different questions and stay
    /// apart for that reason, but an agent reading a write refusal and a
    /// send refusal reads one vocabulary, and one spelling of it is what
    /// keeps that true when either sentence is reworded.
    public var label: String {
        switch self {
        case .path: return ApiRegion.path.label
        // `.query("")` is no row — names are never empty — but the whole region, the key the
        // path box marks while the cursor is in it (`apiQueryRegionMark`, Ruling 7).
        case .query(""): return "Query"
        case .query(let name): return ApiRegion.query(name).label
        case .header(let name): return ApiRegion.header(name).label
        case .body: return ApiRegion.body.label
        // The two `ApiRegion` has no case for, which is the whole of why
        // these are two types: the verb is not a region a send can fail
        // in, and a content type's own send failure is reported against
        // the body it describes.
        case .method: return "Method"
        case .contentType: return "Content type"
        }
    }
}

/// **Wire order — method, path, query, headers, content type, body** —
/// which is the order this pane draws in, publishes in, and refuses a send
/// in, with the row name breaking the tie inside a region.
///
/// A `Comparable` conformance rather than a sort predicate at the one call
/// site: the order is a property of the field, every refusal that names
/// several is owed it, and a refusal that named them in dictionary order
/// would name them differently on every call.
extension ApiDraftField: Comparable {
    public static func < (left: ApiDraftField, right: ApiDraftField) -> Bool {
        left.wireOrder != right.wireOrder
            ? left.wireOrder < right.wireOrder
            : left.rowName.lowercased() < right.rowName.lowercased()
    }

    private var wireOrder: Int {
        switch self {
        case .method: return 0
        case .path: return 1
        case .query: return 2
        case .header: return 3
        case .contentType: return 4
        case .body: return 5
        }
    }

    /// The row name inside a region, empty for the fields that are one.
    private var rowName: String {
        switch self {
        case .query(let name), .header(let name): return name
        case .method, .path, .contentType, .body: return ""
        }
    }
}

/// **The mark is FOCUS** (Decision 27, amended 2026-10-03; Amendment 9a). The pane saves as
/// typed, so "unsaved" no longer exists to be measured. A field is under the operator's hand
/// while the cursor is in it: marked on focus in, released on focus out once that field's last
/// write has landed (`WindowModel.enqueueFocusRelease`).
public func apiFocusMarks(_ field: ApiDraftField) -> Set<ApiDraftField> {
    // 8a: the path box shows the query too, so it marks the whole Query region.
    field == .path ? [.path, apiQueryRegionMark] : [field]
}

/// Which box the operator's cursor is in, **by the box's identifier** (preflight F5). A value
/// the pane holds and feeds its focus events to.
///
/// **It counts no generations** (fix round 1). A view's state restarts when SwiftUI rebuilds
/// the pane, while the store keeps its high-water mark for the pane's life, so a count kept
/// here would fall behind it and every later mark would be dropped. The window issues them
/// (`WindowModel.focusFromSurface`).
///
/// **By the box, not the field**: the path boxes around a hole, and the body boxes around a
/// chip, share one field. Moving from one to the next can deliver the second's focus-in before
/// the first's focus-out, and a focus-out matched by field would then release the mark while
/// the cursor is still in the field. So only the box that last took focus may release it. The
/// marks themselves stay per field (`apiFocusMarks`): a field is marked while any of its boxes
/// holds the cursor.
public struct ApiFocusTracker: Equatable, Sendable {
    /// The field the cursor is in, and the request when it arrived (Escape's restore point).
    public private(set) var focused: ApiFocusedField?
    /// The accessibility identifier of the box holding the cursor.
    public private(set) var identifier: String?

    public init() {}

    /// The fields the cursor's box marks, or `nil` when no box holds it. **What the pane
    /// re-notes when it appears**: a view SwiftUI kept (a lazy re-appear) still holds a live
    /// cursor, whose mark must not be released; a fresh view holds nothing, and releases
    /// whatever a torn-down one left.
    public var held: Set<ApiDraftField>? { focused.map { apiFocusMarks($0.box.field) } }

    public enum Change: Equatable, Sendable {
        /// The cursor arrived: note `fields`. `left` is the field it came from
        /// when that field's focus-out has not arrived yet (preflight F6). The pane flushes it
        /// first, and `left` stays marked until that flush has landed, because the new marks
        /// are set at once but only replace the old ones on the chain, behind the flush.
        case arrived(fields: Set<ApiDraftField>, left: ApiFocusedField?)
        /// The cursor left `left`'s box: flush it, then release, on the chain.
        case released(left: ApiFocusedField)
        /// A focus-out of a box that no longer holds the cursor, or a repeated focus-in.
        case ignored
    }

    public mutating func took(
        _ box: ApiFieldRow, identifier: String, request: ApiRequestSnapshot
    ) -> Change {
        guard self.identifier != identifier else { return .ignored }
        let left = focused
        focused = ApiFocusedField(box: box, request: request)
        self.identifier = identifier
        return .arrived(fields: apiFocusMarks(box.field), left: left)
    }

    /// **The Escape baseline, taken again on the chain** (plan B preflight P7). `took` reads the
    /// stored draft at focus-in, before the field the cursor came from has flushed, so Escape in
    /// the path box (which writes path and query together) would undo that field's last edit.
    /// The pane queues an empty batch on every arrival whose builder calls this with the draft
    /// as it stands at that turn: behind the left field's write, ahead of any edit in this one.
    ///
    /// It replaces the baseline **only while `identifier`'s box still holds the cursor**, and
    /// answers whether it did. A rebase that comes to its turn after the cursor moved on or
    /// left changes nothing.
    public mutating func rebased(identifier: String, request: ApiRequestSnapshot) -> Bool {
        guard self.identifier == identifier, let focused else { return false }
        self.focused = ApiFocusedField(box: focused.box, request: request)
        return true
    }

    public mutating func lost(identifier: String) -> Change {
        guard self.identifier == identifier, let left = focused else { return .ignored }
        focused = nil
        self.identifier = nil
        return .released(left: left)
    }
}

/// A key `api_set_request` names, as the fields it would overwrite.
///
/// **`entry` is deliberately absent.** Re-pointing a draft at another
/// `api[]` entry keeps every region — it moves the origin, the credential
/// and the `authorization` row, and overwrites nothing the operator can
/// have typed in — so it names no field and can collide with none.
public enum ApiWriteKey: String, Sendable, Equatable, CaseIterable {
    case method
    case path
    case query
    case headers
    case contentType
    case body

    /// Whether a write naming this key would overwrite `field`.
    ///
    /// `query` and `headers` each replace their whole region — absent
    /// means unchanged, but a named region is written entire (#190) — so
    /// they collide with *any* row in it, not only one of the same name.
    func overwrites(_ field: ApiDraftField) -> Bool {
        switch (self, field) {
        case (.method, .method), (.path, .path), (.contentType, .contentType),
             (.body, .body):
            return true
        case (.query, .query), (.headers, .header):
            return true
        default:
            return false
        }
    }
}

/// The fields a write may not land on — empty when it may land whole.
///
/// **Whole, never field by field.** A write is admitted or refused
/// entirely, so that a request neither writer composed can never sit on
/// the screen, and so that fixing it is one pass rather than four calls —
/// the same aggregation #158 and #116 set for the send's own refusal.
///
/// **Keyed to the write's ORIGIN, and it is the operator it protects
/// rather than the draft.** The operator's own writes always land — every
/// write the pane saves as they type into the field they are in, and the
/// whole-draft gestures that reopen a `Recent` row or change the entry.
///
/// **`.debug` contends, like an agent.** `--dispatch` runs with no window
/// and therefore no focus, so the branch is unreachable there; where it
/// were reachable, a developer's scripted write is not the hand the rule
/// protects, and the safe side of that guess is the one that refuses.
public func apiDraftCollisions(
    origin: ActionOrigin, writing keys: [ApiWriteKey], focused: Set<ApiDraftField>
) -> [ApiDraftField] {
    guard origin != .ui else { return [] }
    return focused.filter { field in keys.contains { $0.overwrites(field) } }.sorted()
}
