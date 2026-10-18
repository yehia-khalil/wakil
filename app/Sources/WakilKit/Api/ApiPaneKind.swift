import Foundation

/// What an api client pane holds.
///
/// **The draft is the whole of it** — which entry the request targets,
/// where that entry resolved to, whether it has a credential
/// configured, and since #190 the four regions themselves. The
/// response and the `Recent` strip are the sending tickets' to fill —
/// see `ApiRequestSnapshot` for why #188 published their keys and
/// invented none of their shapes.
///
/// **The entry lives HERE, on the draft, and not on `Pane`.** One
/// pane sends to `billing` and then to `auth` without a second pane
/// being opened, which it could not do if the entry were part of the
/// pane's identity. `Pane.terminalPath` is the near neighbour and is
/// deliberately not the precedent: a terminal's path is where its
/// shell was spawned and cannot change without a new shell.
///
/// **There is no `failure` field**, unlike both siblings above, and
/// that is `ApiSnapshot`'s rule made structural rather than a
/// discipline someone has to keep: a refusal is the pane working
/// correctly, so there is nowhere here to put one.
struct ApiContents {
    var draft = ApiDraft.empty
    var environment = ""
    var credentialed = false
    var origin: String?
    /// The fields the operator's cursor is in (Decision 27, amended 2026-10-03), which is
    /// what an agent's write is refused over. **Beside the draft, never published.** As the
    /// surface chain has set them: `setApiFocus`, in the order the pane made its calls.
    var focused: Set<ApiDraftField> = []
    /// The surface's count of focus changes. A release that arrives late carries an older
    /// count and never clears a newer focus.
    var focusGeneration = 0
    /// Focus-ins noted at once (`addApiFocus`) that the chain has not set yet, by their
    /// generation (preflight F6). Each is dropped when the chain sets a generation at or past
    /// it, so the field being left stays marked until its flush has landed, while the field
    /// arriving is marked from the first instant.
    var arriving: [Int: Set<ApiDraftField>] = [:]
    /// The last send's outcome, or `.none` before the first.
    ///
    /// **Replaced on every send, never appended to.** The response is
    /// the bottom of the request's own surface rather than a log —
    /// one request, one reply, always the current one.
    var response: ApiResponseSnapshot = .none
    /// What the environment declares, learned at open. Whoever
    /// opened the pane, the chooser can count them.
    var entries: [String] = []
    /// The send in flight, if any (W14). One per pane: a second is refused.
    var flight: ApiFlight?
    /// Amendment 11a: the draft a cURL fill replaced, kept once for **Undo**, and the line
    /// that fill left. **Beside the draft, never published by `read_pane`**; forgotten
    /// together (`forgetFill`) by every other write to the draft and by a Send.
    var kept: ApiDraft?
    var fillLine: String?

    mutating func forgetFill() {
        kept = nil
        fillLine = nil
    }

    /// **The four regions are published as PARTS, unresolved** (#118
    /// ruling 3): resolution happens at send, so publishing a resolved
    /// draft would publish a prediction. `response.sentUrl` is where
    /// the resolved line goes, frozen, once there is one.
    ///
    /// **The header region is composed HERE and not at the encoder**,
    /// because it needs `credentialed` — which is the entry's fact and
    /// lives beside the draft rather than in it — to know whether
    /// there is an `authorization` row to draw at all.
    ///
    /// **Recent is not the pane's** (W15): the store hands in the list for this pane's
    /// project and environment, and the Bound rows resolved against the panes on screen.
    func snapshot(
        recent: [ApiRecentRow], recentTruncated: Bool,
        bound: (ApiRequestSnapshot) -> [ApiStripRow]
    ) -> ApiSnapshot {
        let request = ApiRequestSnapshot(
            method: draft.method, origin: origin,
            path: draft.path, query: draft.query,
            headers: apiHeaderRegion(draft: draft, credentialed: credentialed),
            body: draft.body)
        return ApiSnapshot(
            entry: draft.entry, environment: environment, credentialed: credentialed,
            request: request, response: response, entries: entries, recent: recent,
            recentTruncated: recentTruncated,
            sending: flight.map { ApiSending(since: $0.since, method: $0.method) },
            bound: bound(request),
            fillLine: fillLine, fillUndoable: kept != nil)
    }
}

/// One send in flight on an api pane (W14). **Beside the draft, and published only as
/// `ApiSending`**: the canceller and the environment the send left in are the store's.
struct ApiFlight {
    /// This flight's own name (fix round 1). Pane ids are per scope — `LayoutStore` restores
    /// them — so the id alone cannot say which pane a reply or a canceller belongs to.
    let token: UUID
    let since: Date
    let method: String
    /// The environment the send left in. Its reply replaces the response only while the
    /// pane is still in it (Review Focus 4).
    let environment: String
    /// Whether the entry had a credential when the send left. An environment switch clears
    /// the pane's own `credentialed` until re-resolve, so the row takes it from here.
    let credentialed: Bool
    /// Whether an agent session made it, through the client pinned to its own place
    /// (`pinnedPlace(of:)`). An org switch cancels only the operator's
    /// (`PaneStore.cancelOperatorApiSends`), as it does their db reads.
    var byAgent = false
    /// Cancels the send's task. `nil` until `armApiSend`.
    var cancel: (@Sendable () -> Void)?
    /// A cancel that arrived before the canceller did, honoured when it arrives.
    var cancelRequested = false
}

/// Recent's key (W15): **one list per organisation, project and environment**, shared by
/// every api pane in it. Not the conversation (`LayoutScope.lineageRoot`): a project's
/// sends are the project's, whichever conversation made them.
struct ApiRecentKey: Hashable {
    let organization: String
    let project: String
    let environment: String
}

struct ApiRecentList {
    var rows: [ApiRecentRow] = []
    var truncated = false
}

/// What the api kind keeps for the whole store.
struct ApiShared: Sendable {
    /// Each scope's resolution generation, bumped when its environment switches, so a listing
    /// read begun before one cannot land after it (`reresolveApis(generation:)`). **Per scope,
    /// and a screen switch bumps none** (background agents 3 of 4): every place stays alive, so
    /// an agent's listing in flight in its own place lands there wherever the operator goes. A
    /// listing for the scope left behind still cannot land on the new one — its mark is never
    /// another scope's value.
    var resolutionGenerations: [LayoutScope: Int] = [:]
    /// Where every generation is drawn from, store-wide and never reset — not even by an org
    /// switch — so no two scopes, and no scope before and after a clear, share a value: a mark
    /// taken in one can never pass for another's.
    var resolutionCounter = 0
    /// `scope`'s generation, drawn fresh on first touch.
    mutating func resolutionGeneration(in scope: LayoutScope) -> Int {
        if let generation = resolutionGenerations[scope] { return generation }
        bumpResolution(in: scope)
        return resolutionCounter
    }
    mutating func bumpResolution(in scope: LayoutScope) {
        resolutionCounter += 1
        resolutionGenerations[scope] = resolutionCounter
    }
    var flightSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]
    /// Recent sends per organisation, project and environment (W15); memory only.
    var recent: [ApiRecentKey: ApiRecentList] = [:]
}

/// The api pane: a request draft, its response and its recent sends (9a).
///
/// `failure` stays nil, and structurally so: `ApiContents` has no field to hold one, because a
/// refusal is this pane working correctly — see `ApiSnapshot`.
enum ApiPaneKind: PaneKind {
    static let names = ["api"]
    static var emptyContents: ApiContents { ApiContents() }
    static var emptyShared: ApiShared { ApiShared() }
    static var emptySnapshot: ApiSnapshot? { .empty }
    // `rerunsSubjectOnRestore` stays false: an api pane's subject is a REQUEST, and the one it last
    // held may have been a `POST`; re-running it would put an unattended write on the wire at launch.
    // `failure` stays nil: a refusal is this pane working correctly — see `ApiSnapshot`.
    static func snapshot(of contents: ApiContents, in store: isolated PaneStore) -> ApiSnapshot {
        store.apiSnapshot(of: contents)
    }
    /// The same panes under a new key keep their generation: a listing in flight still lands.
    static func sharedAfterAdoptingScope(
        _ shared: ApiShared, from outgoing: LayoutScope, to incoming: LayoutScope
    ) -> ApiShared {
        var next = shared
        next.resolutionGenerations[incoming] = next.resolutionGenerations.removeValue(forKey: outgoing)
        return next
    }
}

extension PaneSnapshot {
    public var api: ApiSnapshot? { contents as? ApiSnapshot }
}

extension ApiSnapshot: PaneKindSnapshot {}
