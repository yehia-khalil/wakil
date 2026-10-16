import Foundation

/// Amendment 10a — **a field is one editor's text, and a hole is a token inside it.**
///
/// A literal is characters. A hole or a bound value is ONE attachment character (U+FFFC) that
/// carries which part it is. This file maps a field's parts to that text and back, **exactly**:
/// adjacent literals merge and empty ones drop (`apiMergedLiterals`), and a token keeps its
/// identity. Offsets are UTF-16 units, as `NSTextView` counts them, and a token is one unit, so
/// an offset here is an `NSRange` location in the editor unchanged. The editor holds no rule of
/// its own (10a): what it may do to a token is `ApiEditorRules.swift`'s.
///
/// **A U+FFFC that is not a token is dropped** (the Task 1 spike): a native drag between two
/// editors delivers the attachment character without its attachment, so a bare U+FFFC is a
/// token that lost what it was. It is never read as a token and never kept as text — one rule,
/// on every way in (`init(parts:)`, `init(units:)`, `init(runs:)`), so the text always
/// round-trips.
///
/// **Everything here walks runs, not units** (preflight M6): a body is free text, and a pasted
/// 200 KB literal is one run, so a keystroke's lookups cost the number of runs, and only
/// `units`, `slice` and `replacing` touch the characters — once each.

/// A token: an unfilled hole, or a bound value under its hole's name.
public enum ApiEditorToken: Sendable, Equatable {
    case hole(String)
    case bound(ApiBoundValue)

    public var name: String {
        switch self {
        case .hole(let name): return name
        case .bound(let value): return value.name
        }
    }

    public var isBound: Bool {
        if case .bound = self { return true }
        return false
    }

    public var part: ApiPart {
        switch self {
        case .hole(let name): return .slot(name)
        case .bound(let value): return .bound(value)
        }
    }
}

/// One unit of the editor's text: a UTF-16 code unit, or a token.
public enum ApiEditorUnit: Sendable, Equatable {
    case code(UInt16)
    case token(ApiEditorToken)
}

/// The attachment character a token is drawn as.
let apiEditorAttachmentCode: UInt16 = 0xFFFC

public struct ApiEditorText: Sendable, Equatable {
    public enum Run: Sendable, Equatable {
        case text(String)
        case token(ApiEditorToken)
    }

    /// Never two text runs side by side, never an empty one, never a U+FFFC inside one.
    public let runs: [Run]
    /// The text's length in UTF-16 units, a token counting one.
    public let length: Int

    private init(normalized runs: [Run]) {
        self.runs = runs
        self.length = runs.reduce(0) { total, run in
            switch run {
            case .text(let text): return total + text.utf16.count
            case .token: return total + 1
            }
        }
    }

    public init(parts: [ApiPart]) {
        var builder = Builder()
        for part in parts {
            switch part {
            case .literal(let text): builder.append(text)
            case .slot(let name): builder.append(.hole(name))
            case .bound(let value): builder.append(.bound(value))
            }
        }
        self.init(normalized: builder.finish())
    }

    /// The text read off an editor's storage run by run — each attachment run's tokens, and each
    /// stretch of characters between them (M6: the editor reads attachment RUNS, not one
    /// attribute per character). Runs are normalized here, so the reader need not merge them.
    public init(runs: [Run]) {
        var builder = Builder()
        for run in runs {
            switch run {
            case .text(let text): builder.append(text)
            case .token(let token): builder.append(token)
            }
        }
        self.init(normalized: builder.finish())
    }

    /// The text an editor holds, unit by unit. A `.code(0xFFFC)` is a token whose attachment was
    /// lost, and is dropped. Only a `.token` unit is one.
    public init(units: [ApiEditorUnit]) {
        var builder = Builder()
        for unit in units {
            switch unit {
            case .code(let code): builder.append(code: code)
            case .token(let token): builder.append(token)
            }
        }
        self.init(normalized: builder.finish())
    }

    /// The field's parts, as the editor shows them: `apiMergedLiterals` of what it was made from.
    public var parts: [ApiPart] {
        runs.map { run in
            switch run {
            case .text(let text): return .literal(text)
            case .token(let token): return token.part
            }
        }
    }

    public var units: [ApiEditorUnit] {
        var out: [ApiEditorUnit] = []
        out.reserveCapacity(length)
        for run in runs {
            switch run {
            case .text(let text): out.append(contentsOf: text.utf16.lazy.map { .code($0) })
            case .token(let token): out.append(.token(token))
            }
        }
        return out
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        return lower..<upper
    }

    /// Each token with its offset, its index among `runs` (= `parts`) and among the tokens, in
    /// order. Walks runs only.
    private func forEachToken(
        _ body: (_ offset: Int, _ partIndex: Int, _ ordinal: Int, _ token: ApiEditorToken) -> Bool
    ) {
        var position = 0
        var ordinal = 0
        for (index, run) in runs.enumerated() {
            switch run {
            case .text(let text):
                position += text.utf16.count
            case .token(let token):
                if !body(position, index, ordinal, token) { return }
                position += 1
                ordinal += 1
            }
        }
    }

    private func locate(_ offset: Int) -> (partIndex: Int, ordinal: Int, token: ApiEditorToken)? {
        guard offset >= 0, offset < length else { return nil }
        var found: (Int, Int, ApiEditorToken)?
        forEachToken { position, index, ordinal, token in
            if position == offset { found = (index, ordinal, token) }
            return position < offset
        }
        return found
    }

    /// The token at `offset`, or `nil` for a character or a position past the end.
    public func token(at offset: Int) -> ApiEditorToken? {
        locate(offset)?.token
    }

    /// Every token inside `range`, in order.
    public func tokens(in range: Range<Int>) -> [ApiEditorToken] {
        let range = clamped(range)
        var out: [ApiEditorToken] = []
        forEachToken { position, _, _, token in
            if range.contains(position) { out.append(token) }
            return position < range.upperBound
        }
        return out
    }

    /// The token at `offset`'s place among the tokens: what `apiChipUnbindParams` takes.
    public func ordinal(ofTokenAt offset: Int) -> Int? {
        locate(offset)?.ordinal
    }

    /// The token at `offset`'s index among `parts`: the `<i>` of `api.<key>.part.<i>.remove`.
    public func partIndex(ofTokenAt offset: Int) -> Int? {
        locate(offset)?.partIndex
    }

    public func slice(_ range: Range<Int>) -> ApiEditorText {
        var builder = Builder()
        append(clamped(range), to: &builder)
        return ApiEditorText(normalized: builder.finish())
    }

    public func replacing(_ range: Range<Int>, with inserted: ApiEditorText) -> ApiEditorText {
        let range = clamped(range)
        var builder = Builder()
        append(0..<range.lowerBound, to: &builder)
        inserted.append(0..<inserted.length, to: &builder)
        append(range.upperBound..<length, to: &builder)
        return ApiEditorText(normalized: builder.finish())
    }

    /// Appends the units in `range` (already clamped). A run wholly inside goes in whole; a run
    /// cut by an end goes in as code units, so a surrogate pair cut by one edit and joined by
    /// the next comes back together.
    private func append(_ range: Range<Int>, to builder: inout Builder) {
        guard !range.isEmpty else { return }
        var position = 0
        for run in runs {
            guard position < range.upperBound else { return }
            switch run {
            case .token(let token):
                if range.contains(position) { builder.append(token) }
                position += 1
            case .text(let text):
                let count = text.utf16.count
                let lower = max(range.lowerBound - position, 0)
                let upper = min(range.upperBound - position, count)
                if lower == 0, upper == count {
                    builder.append(text)
                } else if lower < upper {
                    let utf16 = text.utf16
                    let start = utf16.index(utf16.startIndex, offsetBy: lower)
                    let end = utf16.index(start, offsetBy: upper - lower)
                    builder.append(codes: utf16[start..<end])
                }
                position += count
            }
        }
    }

    /// The text as another app reads it: each token as `<name>` (10b, copying outside Wakil).
    public var plain: String {
        runs.map { run in
            switch run {
            case .text(let text): return text
            case .token(let token): return "<\(token.name)>"
            }
        }.joined()
    }

    /// The text flat, as UTF-16 with each token as U+FFFC, and the tokens in order. A text run
    /// never holds a U+FFFC, so the pair is the whole text.
    fileprivate var flat: (codes: [UInt16], tokens: [ApiEditorToken]) {
        var codes: [UInt16] = []
        codes.reserveCapacity(length)
        var tokens: [ApiEditorToken] = []
        for run in runs {
            switch run {
            case .text(let text): codes.append(contentsOf: text.utf16)
            case .token(let token):
                codes.append(apiEditorAttachmentCode)
                tokens.append(token)
            }
        }
        return (codes, tokens)
    }

    /// Builds normalized runs: text merges, empties vanish, a bare U+FFFC is dropped.
    private struct Builder {
        var runs: [Run] = []
        /// Code units not yet decoded, so that a surrogate pair split across appends rejoins.
        var pending: [UInt16] = []

        mutating func append(code: UInt16) {
            if code != apiEditorAttachmentCode { pending.append(code) }
        }

        mutating func append<C: Collection>(codes: C) where C.Element == UInt16 {
            pending.append(contentsOf: codes.lazy.filter { $0 != apiEditorAttachmentCode })
        }

        mutating func append(_ text: String) {
            guard !text.isEmpty else { return }
            if !pending.isEmpty || text.utf16.first.map(UTF16.isTrailSurrogate) == true {
                append(codes: text.utf16)
                return
            }
            mergeText(apiEditorDroppingAttachments(text))
        }

        mutating func append(_ token: ApiEditorToken) {
            flush()
            runs.append(.token(token))
        }

        private mutating func flush() {
            guard !pending.isEmpty else { return }
            let text = String(decoding: pending, as: UTF16.self)
            pending = []
            mergeText(text)
        }

        private mutating func mergeText(_ text: String) {
            guard !text.isEmpty else { return }
            if case .text(let previous)? = runs.last {
                runs[runs.count - 1] = .text(previous + text)
            } else {
                runs.append(.text(text))
            }
        }

        mutating func finish() -> [Run] {
            flush()
            return runs
        }
    }
}

/// `text` without its U+FFFCs — a token that lost its attachment is not text (the spike).
private func apiEditorDroppingAttachments(_ text: String) -> String {
    guard text.utf16.contains(apiEditorAttachmentCode) else { return text }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: text.unicodeScalars.lazy.filter { $0.value != 0xFFFC })
    return String(scalars)
}

/// Whether the editor takes the parts it is handed (Review Focus 4; the SwiftUI re-set lesson,
/// Task 9 fix's rule for a box's text, here for parts).
///
/// **Not when it already shows them**, up to merging, so the caret never resets under a
/// keystroke. **Not, while it has the cursor, when they are an earlier state of its own
/// typing.** An echo of a pause write from before the latest keystrokes would drop them.
/// Anything else is a change from outside the editor and is taken: an unbind landing, Format,
/// Escape's restore, an agent's write, or the Query region rewriting the path view.
public func apiEditorTakesParts(
    _ incoming: [ApiPart], showing: [ApiPart], typedSinceTaken: [[ApiPart]], focused: Bool
) -> Bool {
    // Compared as the editor would show each (Task 2 carry): merged, and a bare U+FFFC
    // dropped, so an agent's literal U+FFFC is not taken again on every refresh.
    let shown = ApiEditorText(parts: incoming)
    if shown == ApiEditorText(parts: showing) { return false }
    if focused, typedSinceTaken.contains(where: { ApiEditorText(parts: $0) == shown }) { return false }
    return true
}

/// Where the selection goes when the editor takes an outside change (Review Focus 4): mapped
/// across it, never thrown to the end. A position in the unchanged head stays (so does one
/// exactly where something was inserted). One in the unchanged tail moves by the change in
/// length. One inside the changed middle goes to the end of what replaced it. A token replaced
/// in place (an unbind landing) is a one-unit middle, so a caret just after it stays just after
/// it. A selection past the old end is clamped to it first.
public func apiEditorSelection(
    from old: ApiEditorText, to new: ApiEditorText, selection: Range<Int>
) -> Range<Int> {
    let (a, aTokens) = old.flat
    let (b, bTokens) = new.flat
    // Two units are equal when their codes are, and, for a token, when the tokens are: the
    // ordinal counters index the token lists as each scan passes a U+FFFC.
    var prefix = 0
    var ordinal = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
        if a[prefix] == apiEditorAttachmentCode {
            guard aTokens[ordinal] == bTokens[ordinal] else { break }
            ordinal += 1
        }
        prefix += 1
    }
    var suffix = 0
    var aOrdinal = aTokens.count - 1
    var bOrdinal = bTokens.count - 1
    while suffix < a.count - prefix, suffix < b.count - prefix {
        let x = a[a.count - 1 - suffix]
        guard x == b[b.count - 1 - suffix] else { break }
        if x == apiEditorAttachmentCode {
            guard aTokens[aOrdinal] == bTokens[bOrdinal] else { break }
            aOrdinal -= 1
            bOrdinal -= 1
        }
        suffix += 1
    }
    func map(_ position: Int) -> Int {
        let position = min(max(position, 0), a.count)
        if position <= prefix { return min(position, b.count) }
        if position >= a.count - suffix { return position + (b.count - a.count) }
        return b.count - suffix
    }
    let lower = map(selection.lowerBound)
    return lower..<max(lower, map(selection.upperBound))
}

/// The text of a part list's literals, joined, a token dropped (10a; preflight D1): the content
/// type's field, which holds no token. **The one copy of this join**: the held write, the
/// applied request and the content type's `TextField` binding all read it.
public func apiPlainLiteral(_ parts: [ApiPart]) -> String {
    parts.compactMap { part -> String? in
        if case .literal(let text) = part { return text }
        return nil
    }.joined()
}

/// The parts a split field draws: **the path box draws path and query as one view** (Amendment
/// 8a); every other field its own row's parts.
public func apiFieldViewParts(
    _ request: ApiRequestSnapshot, _ field: ApiDraftField, row: Int = 0
) -> [ApiPart] {
    field == .path
        ? apiPathQueryView(path: request.path, query: request.query)
        : apiFieldParts(request, field, row: row)
}

/// Whether a split field draws boxes — the path box by its own rule (`apiPathBoxIsTypable`).
public func apiFieldViewIsTypable(_ request: ApiRequestSnapshot, _ field: ApiDraftField) -> Bool {
    field == .path ? apiPathBoxIsTypable(request) : apiFieldIsTypable(request, field)
}
