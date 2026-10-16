import Foundation

// MARK: - The unfilled-holes line

/// The amber line under Send: how many holes the draft still holds unfilled, and what fills
/// them — or `nil` when there are none, and nothing is drawn.
///
/// **A ruling rather than a count in the view**, on `apiChooserIsEnabled`'s precedent:
/// `WakilApp` has no test target, and which parts count is a decision.
///
/// **Counted by name, across all four regions** — `apiSlotNames`, the same walk `api_bind`
/// fills from. A drop fills a hole by its name, so `customer_id` in the path and again in the
/// body is one hole to fill, and one drop fills both.
///
/// **A bound value is not counted, resolving or not.** A bound value whose row has gone is
/// not *unfilled* — the operator filled it — and the send's own refusal names it, with its
/// reason, which this line could only guess at. The line says the request is not ready
/// *before* Send is pressed; it never replaces what Send says when it refuses.
public func apiUnfilledHolesLine(_ request: ApiRequestSnapshot) -> String? {
    // B1: a read's body is not sent, so a hole in it is not an unfilled one.
    let counted = apiBodyIsSent(request)
        ? request
        : ApiRequestSnapshot(
            method: request.method, origin: request.origin, path: request.path,
            query: request.query, headers: request.headers, body: [])
    let count = apiSlotNames(in: counted).count
    guard count > 0 else { return nil }
    return count == 1
        ? "1 hole unfilled — drop a row on the pane to fill it"
        : "\(count) holes unfilled — drop a row on the pane to fill them"
}

// MARK: - What a send carries and says

/// A refusal or error line as drawn: the region first **only when the refusal is that
/// region's** (B3). The walk saw *"Path · validating…"* on a tool's own error.
public func apiFailureLine(_ failure: ApiSendFailure) -> String {
    failure.region.map { "\($0.label) · \(failure.message)" } ?? failure.message
}

/// B1: whether the body goes on the wire. A read sends none, and its box dims.
public func apiBodyIsSent(_ request: ApiRequestSnapshot) -> Bool {
    !apiIsReadMethod(request.method)
}

/// B2: whether the content type goes on the wire. Only beside a body that is sent.
public func apiContentTypeIsSent(_ request: ApiRequestSnapshot) -> Bool {
    apiBodyIsSent(request) && !request.body.isEmpty
}

// MARK: - A single-line box's text

/// What a single-line box commits: its text with every line break (`\n`, `\r`, `\r\n`)
/// taken out, and nothing else touched.
///
/// **The boxes wrap now** (`TextField(axis: .vertical)`), and a vertical field takes a line
/// break from Option-Return or a paste. A path, a query or header value and a content type are
/// one line on the wire — a break in one is a malformed request, never what was meant — so it
/// is removed at commit rather than sent. Every other character is bytes on the wire and kept.
public func apiSingleLineText(_ text: String) -> String {
    String(text.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }.map(Character.init))
}

// MARK: - The status chip's tone

/// Which of design-language.md §5's reserved hues the response's status chip takes: green
/// (healthy), amber (caution) or red (failed). **A meaning, not a colour** — the view maps it.
public enum ApiStatusTone: Sendable, Equatable {
    case healthy
    case caution
    case failed
}

/// A reply's status code, banded.
///
/// - **2xx is healthy.** The request did what it asked.
/// - **3xx and 4xx are caution.** A redirect was not followed through to an answer, and a 4xx
///   is the operator's own request to fix: something to look at, and nothing broken.
/// - **5xx is failed.** The server says it failed.
///
/// **Below 200 is caution, and anything else is failed.** A 1xx is never a final reply, so
/// seeing one is something to look at rather than a success; a code at or above 600 is
/// outside the protocol, and calling it healthy or merely cautionary would be guessing in the
/// kind direction.
public func apiStatusTone(status: Int) -> ApiStatusTone {
    switch status {
    case 200..<300: return .healthy
    case ..<200, 300..<500: return .caution
    default: return .failed
    }
}

/// The response's tone, or `nil` where there is no status to colour.
///
/// - **A reply** takes its status's band.
/// - **A transport failure is failed**: the request left, or tried to, and nothing came back.
/// - **Fate unknown is caution**: the send may have arrived, and nothing has been shown to
///   fail — drawing it red would state something nobody knows.
/// - **None, a refusal and a cleared reply have no tone.** Nothing was sent (or what was sent
///   no longer describes this environment), so there is no status: a refusal is not a
///   response, and the pane draws it as "not sent" in amber with its failures beneath,
///   exactly as before.
/// - **A cancelled read has no tone** (W14): grey is the pane's own ink, and nothing failed.
public func apiStatusTone(_ response: ApiResponseSnapshot) -> ApiStatusTone? {
    switch response {
    case .ok(let reply): return apiStatusTone(status: reply.status)
    case .transport: return .failed
    case .unknown: return .caution
    case .none, .refusal, .cleared, .cancelled: return nil
    }
}

/// Milliseconds as seconds to one decimal place — `4200` reads `"4.2 s"` (W14).
public func apiSeconds(_ milliseconds: Int) -> String {
    String(format: "%.1f s", Double(milliseconds) / 1000)
}

/// What a cancelled send says: `"cancelled after 4.2 s"` (W14).
public func apiCancelledLine(waitedMs: Int) -> String { "cancelled after \(apiSeconds(waitedMs))" }

// MARK: - The body heading and the content type's placeholder (W2, W19)

/// Whether a content type names JSON: empty (the send's own default is `application/json`),
/// `application/json`, or any `+json` suffix. Parameters are ignored, and case does not count.
public func apiContentTypeIsJSON(_ contentType: String) -> Bool {
    let media = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    return media.isEmpty || media == "application/json" || media.hasSuffix("+json")
}

/// The Body heading (W2): `BODY · JSON` from the content type the screen shows, `BODY · TEXT`
/// otherwise.
public func apiBodyHeading(_ request: ApiRequestSnapshot) -> String {
    apiContentTypeIsJSON(apiContentTypeText(request)) ? "BODY · JSON" : "BODY · TEXT"
}

/// The content-type box's placeholder (W19): the default an empty box stands for.
public let apiContentTypePlaceholder = "application/json"
