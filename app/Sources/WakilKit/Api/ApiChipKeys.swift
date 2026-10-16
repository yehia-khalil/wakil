import Foundation

/// W4 (Amendment 9c), W16: **a token's `×` and its keys.** Backspace just after a token, or
/// Delete just before one, acts as its `×`: an unfilled hole is removed, and a bound value is
/// unbound back to its hole. Since Amendment 10 the keys are the editor's verdict
/// (`apiEditorVerdict`), not a catcher beside each box. What is left here is what a chip's `×`
/// does (`apiChipAct`) and the `api_unbind` an unbind sends.

/// What a chip's `×` does, and so what its key does.
public enum ApiChipAct: Equatable, Sendable { case remove, unbind }

/// `remove` for a hole, `unbind` for a bound value, `nil` for text.
public func apiChipAct(_ part: ApiPart) -> ApiChipAct? {
    switch part {
    case .literal: return nil
    case .slot: return .remove
    case .bound: return .unbind
    }
}

/// The `api_unbind` a chip's `×` or key sends: **the `ordinal`-th chip of the field, in
/// `request`** — the stored draft at the unbind's turn on the chain, behind the flush it
/// follows (plan B preflight P10). Built there, no write still in flight (a Format, another
/// box's pause) can move it after it was resolved.
///
/// **Only while that chip is still the binding `name` was drawn as.** A gesture ahead of it on
/// the chain may have removed a chip, or already unbound this one: the ordinal then names
/// another part, and nothing is sent, because an unbind built from a guess is worse than none.
/// For the path box the view's index is mapped back to its field and row by
/// `apiPathQueryOrigin`.
public func apiChipUnbindParams(
    _ request: ApiRequestSnapshot, field: ApiDraftField, row: Int, ordinal: Int, name: String,
    pane: String
) -> JSONValue? {
    let parts = apiFieldViewParts(request, field, row: row)
    let chips = parts.indices.filter { apiChipAct(parts[$0]) != nil }
    guard chips.indices.contains(ordinal) else { return nil }
    let at = chips[ordinal]
    guard case .bound(let value) = parts[at], value.name == name else { return nil }
    if field == .path {
        guard let origin = apiPathQueryOrigin(
            path: request.path, query: request.query, viewIndex: at)
        else { return nil }
        return apiUnbindParams(field: origin.field, index: origin.index, pane: pane, row: origin.row)
    }
    return apiUnbindParams(field: field, index: at, pane: pane, row: row)
}
