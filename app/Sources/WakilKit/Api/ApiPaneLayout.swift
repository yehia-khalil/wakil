import Foundation

/// W10, W11 (Amendment 9c): **the pane splits.** The request sits above and the response
/// below, each scrolling on its own, and nothing draws outside the pane. The walk saw a 200 KB
/// reply push the request under the window's toolbar.

/// The request half's share of the pane, once something has come back.
public let apiRequestShare = 0.55

public enum ApiPaneSplit: Equatable, Sendable {
    /// Request and response, each this tall, in points.
    case shared(request: Double, response: Double)
    /// The response is one line, drawn at its own height. The request takes the rest.
    case responseLine

    /// The request half's fixed height, or `nil` when it takes whatever the response leaves.
    ///
    /// **The view reads its frames off these and never branches around the request half**
    /// (plan B preflight P17): two arms each holding the request would be two views to SwiftUI,
    /// and the first reply, an environment switch or a cancel would rebuild every box in it —
    /// the cursor lost, and a focused body torn down without its focus-out.
    public var requestHeight: Double? {
        if case .shared(let request, _) = self { return request }
        return nil
    }

    /// The response half's fixed height, or `nil` when it is drawn at its own height.
    public var responseHeight: Double? {
        if case .shared(_, let response) = self { return response }
        return nil
    }

    /// Whether the response's body scrolls under its pinned head: only when the half has a
    /// height to scroll in.
    public var responseScrolls: Bool { responseHeight != nil }
}

/// Whether the response says one line: nothing sent, cleared by a switch, or cancelled. That
/// half then shrinks to the line and Recent below it.
public func apiResponseIsOneLine(_ response: ApiResponseSnapshot) -> Bool {
    switch response {
    case .none, .cleared, .cancelled: return true
    case .ok, .transport, .unknown, .refusal: return false
    }
}

/// How a pane `total` points tall splits for this response.
public func apiPaneSplit(total: Double, response: ApiResponseSnapshot) -> ApiPaneSplit {
    if apiResponseIsOneLine(response) { return .responseLine }
    let height = max(total, 0)
    let request = (height * apiRequestShare).rounded(.down)
    return .shared(request: request, response: height - request)
}

/// Recent's height cap, in rows (W11): unfolded, it scrolls past this.
public let apiRecentStripMaxRows = 4

/// How many rows tall Recent is drawn, for `count` rows: all of them up to the cap.
public func apiRecentStripRows(count: Int) -> Int { min(max(count, 0), apiRecentStripMaxRows) }

// MARK: - Re-walk #1 (2026-10-04)

/// The split's two dividers — request | response, and the one above Recent (re-walk #1a).
///
/// **A hairline a person can see, and nothing more** (design language §1: no chrome borders,
/// hairlines and spacing only). They were half a point at 0.08, which on the dark slab read as
/// no divider at all: the walk could not tell where the request ended. One point at 0.14, the
/// pane's whole width, with a little room either side.
public enum ApiPaneDivider {
    public static let weight = 1.0
    public static let opacity = 0.14
    /// Points above and below the line.
    public static let spacing = 6.0
}

/// How far a scroll region fades where it meets an edge, in points (re-walk #1b): the cue that
/// content is cut there — the request half's foot, the body sliced under the pinned head. A mask
/// on the scroll container, never a shadow on the data (§8). The region is padded by the same
/// length inside, so at rest nothing but padding sits under the fade.
public let apiScrollEdgeFade = 10.0

/// The lines the response body keeps before Recent's rows take any of the half (re-walk #1c).
public let apiResponseBodyMinLines = 6

/// How many of Recent's rows are drawn (re-walk #1c). The walk saw the pinned head and Recent
/// leave the body two or three lines.
///
/// `bodyRoom` is what the body and Recent's rows share once the head, Recent's own header line,
/// the dividers and the body's fade padding are drawn; `nil` when the half is drawn at its own
/// height and nothing scrolls, so the rows cost the body nothing. `bodyLines` is how many lines
/// the body actually is.
///
/// **The body keeps its lines first — `apiResponseBodyMinLines` at most, fewer when it is
/// shorter** — and Recent takes whole rows from what is left, up to its cap. **The operator's
/// unfold wins** (review I1): with nothing left, an unfolded Recent still takes one row from the
/// body rather than drawing nothing, so Recent is reachable at the default pane size and the
/// fold is never a control that does nothing.
public func apiRecentShownRows(
    count: Int, unfolded: Bool, bodyRoom: Double?, bodyLines: Int,
    rowHeight: Double, lineHeight: Double
) -> Int {
    guard unfolded else { return 0 }
    let capped = apiRecentStripRows(count: count)
    guard capped > 0 else { return 0 }
    guard let bodyRoom else { return capped }
    let reserved = Double(min(apiResponseBodyMinLines, max(bodyLines, 0))) * lineHeight
    let fit = rowHeight > 0 ? Int(((bodyRoom - reserved) / rowHeight).rounded(.down)) : 0
    return min(capped, max(1, fit))
}

/// W20: what the response half shows under its pinned head. Body by default.
public enum ApiResponseShows: String, CaseIterable, Sendable {
    case body = "Body"
    case headers = "Headers"

    /// The identifier's last segment: `api.response.body`, `api.response.headers`.
    public var key: String { rawValue.lowercased() }
}

/// Whether the response has headers to show. **Only a reply.** A refusal, a transport failure,
/// a fate-unknown and a cancelled send had no reply to take them from, so they draw no choice.
public func apiResponseOffersHeaders(_ response: ApiResponseSnapshot) -> Bool {
    if case .ok = response { return true }
    return false
}

public struct ApiResponseHeaderRow: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The reply's headers **in byte order of the name** (UTF-8). `wakil-http` returns them as a Go
/// map, which carries no wire order, and Go's JSON encoder writes map keys in byte order; so this
/// is the order `wakil-http` hands them, not necessarily the server's.
/// Uncoloured: §5's hues are spent on the status chip alone.
public func apiResponseHeaderRows(_ reply: ApiResponseOK) -> [ApiResponseHeaderRow] {
    reply.headers
        .map { ApiResponseHeaderRow(name: $0.key, value: $0.value) }
        .sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
}

/// The quiet line the Headers choice draws for a reply that carried **no** headers, in place of
/// a `HEADER | VALUE` table with nothing under it (Task 7 carry). `nil` when there are rows.
public func apiResponseHeadersEmptyLine(_ reply: ApiResponseOK) -> String? {
    reply.headers.isEmpty ? "no headers" : nil
}
