import Foundation

/// Amendment 10b — **the editor's one custom key rule, and what may happen to a token.**
///
/// Typing, the caret, selection, arrows, undo, input methods and wrapping are AppKit's. The
/// editor asks this file before any change that touches a token, and does what it answers.

public enum ApiEditorKey: Sendable, Equatable { case backspace, delete }

public enum ApiEditorVerdict: Sendable, Equatable {
    /// AppKit applies the change.
    case allow
    /// Nothing changes and nothing is said: a held key's repeat, a key the input method owns, or
    /// the source half of a drag out of a selection that holds a binding.
    case ignore
    /// Nothing changes, and this line is drawn under the field.
    case refuse(String)
    /// The key reached a bound value: `api_unbind` it (W4), by its place among the tokens.
    case unbind(ordinal: Int, name: String)
    /// A single-line field: insert this instead (the line breaks taken out).
    case substitute(String)
}

/// Drawn under a field when a selection holding a bound value would be deleted, replaced or cut.
public let apiBoundSelectionLine =
    "a selection holding a bound value can't be deleted or replaced — use the value's × to unbind it"

/// What a change to `text` may do (10b).
///
/// - **A key on exactly one token** (Backspace just after it, Delete just before it): a hole goes
///   as one character, and a bound value is unbound to its hole (W4, W16). A held key's repeat
///   (P8) and a key while text is marked (the input method's) do nothing.
/// - **`key` is the plain Backspace or Delete only** (`deleteBackward:`/`deleteForward:`). Every
///   other delete — Option-Backspace's word, ⌘-Backspace's line, a menu's Delete — comes with
///   `key == nil` and is a range like any selection: a bound value in it is **refused**, never
///   unbound (preflight M17). The unbind is the token's own key, or its `×`.
/// - **A range holding a bound value** is refused, typed over, deleted or cut alike, because a
///   write can neither drop nor make a binding (W16). The one exception is a drag out to another
///   field (`draggingOut`): the destination got the hole, and the source stays whole, silently.
/// - **An insertion carrying a bound value** is refused (W16, fix round 1): a write can carry a
///   binding but never MAKE one, so a native drop, a stale undo record, or an undo of a move after
///   the value was unbound cannot put a binding in the field. `insertedTokens` are the tokens the
///   inserted attributed string carries, in order — the editor reads them off its attachments.
///   **Required, with no default** (Task 5): a call site that forgot it would re-open the gap.
///   `apiEditorMoving` is the one sanctioned bound-carrying write and does not come here. A hole
///   inserted (Wakil's own paste) is allowed.
/// - **A single-line field** takes no line break, and its substitute carries no U+FFFC: a plain
///   string has no attachment, so the character would draw as a token that lost what it was.
/// - **A plain insert carrying a U+FFFC** (no `insertedTokens`, not `replaying`) is substituted
///   without it, in every field, or ignored when nothing is left (final review I1): the Character
///   Viewer, an accessibility value set. A bare U+FFFC in storage is dropped by `editorText`, so
///   every storage offset after it would stop being the model's offset, and a key after a bound
///   value would check the wrong unit and let AppKit drop the binding (W16). **`replaying` is an
///   undo or redo**, required with no default: its string carries U+FFFC for the attachments it
///   restores, and `apiEditorMadeBinding` checks it once made.
public func apiEditorVerdict(
    _ text: ApiEditorText, replacing range: Range<Int>, with inserted: String,
    insertedTokens: [ApiEditorToken], replaying: Bool,
    key: ApiEditorKey? = nil, isRepeat: Bool = false, composing: Bool = false,
    draggingOut: Bool = false, singleLine: Bool
) -> ApiEditorVerdict {
    if insertedTokens.contains(where: \.isBound) { return .refuse(apiBoundSelectionLine) }
    let touched = text.tokens(in: range)
    if key != nil, inserted.isEmpty, range.count == 1, let token = touched.first {
        if composing || isRepeat { return .ignore }
        guard case .bound(let value) = token else { return .allow }
        guard let ordinal = text.ordinal(ofTokenAt: range.lowerBound) else { return .ignore }
        return .unbind(ordinal: ordinal, name: value.name)
    }
    if touched.contains(where: \.isBound) {
        return draggingOut ? .ignore : .refuse(apiBoundSelectionLine)
    }
    if singleLine, inserted.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
        return .substitute(apiSingleLineText(inserted).replacingOccurrences(of: "\u{FFFC}", with: ""))
    }
    if !replaying, insertedTokens.isEmpty, inserted.unicodeScalars.contains("\u{FFFC}") {
        let stripped = inserted.replacingOccurrences(of: "\u{FFFC}", with: "")
        return stripped.isEmpty ? .ignore : .substitute(stripped)
    }
    return .allow
}

/// Wakil's own pasteboard type: a clip of one field's text with its holes, so a hole moves
/// between Wakil's fields while text pasted from outside stays literal (10b). **The only way a
/// token crosses fields**: the spike measured a native drag between two editors delivering a
/// bare U+FFFC with its attachment lost, which `ApiEditorText` drops.
public let apiEditorPasteboardType = "com.wakil.api.editor-text"

/// What a copy, a cut or a drag carries. **Text and holes only**: a bound value is carried as
/// its HOLE, so no pasteboard ever carries a binding (10b, W16).
public struct ApiEditorClip: Codable, Sendable, Equatable {
    public enum Run: Codable, Sendable, Equatable {
        case text(String)
        case hole(String)
    }

    public let runs: [Run]

    public init(runs: [Run]) { self.runs = runs }

    public init(_ text: ApiEditorText, range: Range<Int>) {
        runs = text.slice(range).runs.map { run in
            switch run {
            case .text(let string): return .text(string)
            case .token(let token): return .hole(token.name)
            }
        }
    }

    /// What another app reads: each hole as `<name>`.
    public var plain: String {
        runs.map { run in
            switch run {
            case .text(let string): return string
            case .hole(let name): return "<\(name)>"
            }
        }.joined()
    }

    public var text: ApiEditorText {
        ApiEditorText(parts: runs.map { run in
            switch run {
            case .text(let string): return .literal(string)
            case .hole(let name): return .slot(name)
            }
        })
    }
}

/// What a paste inserts. **Wakil's own clip** gives its tokens back as holes. **Outside text
/// stays literal**: `<id>` is not parsed into a hole, and a bare U+FFFC is dropped (10b; the
/// spike). A single-line field drops line breaks. `nil` when the pasteboard holds neither.
public func apiEditorPasted(
    clip: ApiEditorClip?, plain: String?, singleLine: Bool
) -> ApiEditorText? {
    let pasted: ApiEditorText
    if let clip {
        pasted = clip.text
    } else if let plain {
        pasted = ApiEditorText(parts: [.literal(plain)])
    } else {
        return nil
    }
    guard singleLine else { return pasted }
    return ApiEditorText(parts: pasted.parts.map { part in
        if case .literal(let string) = part { return .literal(apiSingleLineText(string)) }
        return part
    })
}

/// A drag inside one field: `range` moved to `offset`, an offset in the text before the move.
/// **The one way a bound value moves** (10b, operator 2026-10-04: within its own FIELD): one
/// write carries it, so the binding is never dropped. `nil` for an empty range or a drop inside
/// or at the edge of the range itself, which moves nothing, and for a range or an offset outside
/// the text (fix round 1).
public func apiEditorMoving(
    _ text: ApiEditorText, range: Range<Int>, to offset: Int
) -> (text: ApiEditorText, selection: Range<Int>)? {
    guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= text.length,
          (0...text.length).contains(offset),
          offset < range.lowerBound || offset > range.upperBound else { return nil }
    let moved = text.slice(range)
    let removed = text.replacing(range, with: ApiEditorText(parts: []))
    let at = offset > range.upperBound ? offset - range.count : offset
    return (removed.replacing(at..<at, with: moved), at..<(at + range.count))
}

/// Where `+ hole` lands (10b; W7 generalised to every field). It lands **at the caret**, or at
/// the selection's end, replacing nothing, because a gesture never deletes text. `selection` is
/// `nil` for a field the caret has not been in, and the hole then lands **at the end**. In the
/// path view that is the end of the path, before the first `?` of its text (final review I4):
/// appended to the view, it fell into the last query value. Walks runs, not units (M6); a `?`
/// in a hole's name is not text.
public func apiEditorHoleOffset(
    _ text: ApiEditorText, selection: Range<Int>?, isPathView: Bool
) -> Int {
    if let selection { return min(max(selection.upperBound, 0), text.length) }
    guard isPathView else { return text.length }
    var position = 0
    for run in text.runs {
        switch run {
        case .token:
            position += 1
        case .text(let string):
            if let mark = string.utf16.firstIndex(of: UInt16(UInt8(ascii: "?"))) {
                return position + string.utf16.distance(from: string.utf16.startIndex, to: mark)
            }
            position += string.utf16.count
        }
    }
    return text.length
}

/// `apiHoleNameRefusal` for a blank name, else `nil`. A name is taken exactly as typed (spec §1).
public func apiHoleNameRefused(_ name: String) -> String? {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiHoleNameRefusal : nil
}

/// Whether a token's `×` is drawn (C4: the token view asks, it holds no rule). **A bound
/// value's always is** (spec §3): its `×` is the one way to change it, and it locks only itself
/// (W16). **A hole's only where the field is editable**: not on the `&`-locked path (8d).
public func apiTokenCloseShown(editable: Bool, isBound: Bool) -> Bool {
    isBound || editable
}

/// Where the selection goes when the editor takes an outside change (C4, plan ambiguity 5).
/// **While the editor has the cursor**, it is mapped across the change (`apiEditorSelection`,
/// Review Focus 4). **Without it**, the caret goes to the end, so a later `+ hole` lands there,
/// matching P14's stale-caret fallback.
public func apiEditorSelection(
    from old: ApiEditorText, to new: ApiEditorText, selection: Range<Int>, focused: Bool
) -> Range<Int> {
    guard focused else { return new.length..<new.length }
    return apiEditorSelection(from: old, to: new, selection: selection)
}

/// Whether a change from `old` to `new` MADE a binding (W16): some binding appears more times
/// after it than before. **The editor's backstop for the text system's own replays** (Task 5):
/// an undo or redo hands the delegate only a string, so the verdict cannot see which token a
/// replayed U+FFFC carries. The editor checks the change once it is made, and a change that made
/// a binding is taken back. A move, typing, a hole and an unbind make none.
public func apiEditorMadeBinding(from old: ApiEditorText, to new: ApiEditorText) -> Bool {
    func bindings(_ text: ApiEditorText) -> [ApiBoundValue] {
        text.runs.compactMap { run in
            if case .token(.bound(let value)) = run { return value }
            return nil
        }
    }
    let before = bindings(old)
    let after = bindings(new)
    guard !after.isEmpty else { return false }
    return after.contains { value in
        after.filter { $0 == value }.count > before.filter { $0 == value }.count
    }
}

/// `+ hole` reached a field the editor could not insert into (not drawn yet, or not editable):
/// said beside the name box, which stays open (preflight M8 — not the blank-name line).
public let apiEditorHoleNotPlaced = "this field can't take a hole right now — click into it and try again"

/// Whether a same-field move (`apiEditorMoving`) may stay on the undo stack (Task 5 review).
/// **Its undo replaces the whole field**, so a bound value anywhere in it — the moved text or
/// not — puts the replay over a range holding a binding, which the verdict refuses; a refused
/// replay leaves every record after it stale (Ruling 12), and ⌘Z would show a confusing
/// refusal. Such a move clears the stack instead. `moved` is the field after the move.
public func apiEditorMoveIsUndoable(_ moved: ApiEditorText) -> Bool {
    !moved.runs.contains { run in
        if case .token(let token) = run { return token.isBound }
        return false
    }
}

/// #342: an accessibility client that sets the field's whole value (Orca's `type-text`, other
/// automation) hands over one plain string, where each token reads as U+FFFC. Applied whole,
/// that drops every hole and is refused outright beside a bound value. Narrowed instead to the
/// one range it changed — the common prefix and suffix, each mark in them matched to the token
/// it stands for — it is an edit like any typed one, asked of `apiEditorVerdict` as one. A mark
/// in the changed middle names no token and is dropped, as a pasted one is. Never splits a
/// surrogate pair. `nil` when the value is the text as it stands.
public func apiEditorNarrowed(
    _ text: ApiEditorText, to value: String, singleLine: Bool
) -> (range: Range<Int>, inserted: ApiEditorText)? {
    let old = text.units.map { unit -> UInt16 in
        if case .code(let code) = unit { return code }
        return apiEditorAttachmentCode
    }
    let new = Array(value.utf16)
    let limit = min(old.count, new.count)
    var prefix = 0
    while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
    if prefix > 0, prefix < limit, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
    var suffix = 0
    while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
        suffix += 1
    }
    if suffix > 0, suffix < limit - prefix, UTF16.isTrailSurrogate(old[old.count - suffix]) {
        suffix -= 1
    }
    let range = prefix..<(old.count - suffix)
    let middle = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
    guard !range.isEmpty || !middle.isEmpty else { return nil }
    return (range, ApiEditorText(parts: [.literal(singleLine ? apiSingleLineText(middle) : middle)]))
}
