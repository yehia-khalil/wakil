import Foundation

extension ApiPaneKind {
    /// **`store.apiSources()` is what a bound value's `preview` is read off** (#192), read here,
    /// inside the store, in the same turn as the snapshot: an omitted lookup would make every
    /// bound value read as from a closed pane, with `resolves: false` and no preview.
    static func readPane(_ snapshot: ApiSnapshot, in store: isolated PaneStore) -> [String: JSONValue] {
        let sources = store.apiSources()
        var object: [String: JSONValue] = [:]
        // The three facts above the three regions. `credentialed` is a
        // boolean and means only that a credential is configured — see
        // `ApiSnapshot` for why nothing here is redacted and why that is
        // stated structurally rather than enforced with a mask.
        object["entry"] = .string(snapshot.entry)
        object["environment"] = .string(snapshot.environment)
        object["credentialed"] = .bool(snapshot.credentialed)
        // Wire order — path, query, headers, body — here as on screen.
        //
        // **`headers` is the region's rows whose value the app HOLDS**, in
        // the region's own order, so the agent's copy and the screen are
        // one sequence produced once. `authorization` drops out here
        // structurally rather than by a masking rule — it has no value to
        // publish, because the credential resolves inside Go and never
        // enters the app — and `credentialed` above takes its place.
        object["request"] = .object([
            "method": .string(snapshot.request.method),
            "origin": snapshot.request.origin.map { .string($0) } ?? .null,
            "path": .array(apiPartsJSON(snapshot.request.path, sources: sources)),
            "query": .array(snapshot.request.query.map {
                apiNamedRowJSON(name: $0.name, value: $0.value, sources: sources)
            }),
            "headers": .array(snapshot.request.headers.compactMap { row in
                row.value.map { apiNamedRowJSON(name: row.name, value: $0, sources: sources) }
            }),
            "body": .array(apiPartsJSON(snapshot.request.body, sources: sources)),
        ])
        // The encoder's SECOND carve-out from "every key of the answered
        // kind is always present", after `editable`'s — and a different
        // species. `editable`'s omission has to be inferred; this one is
        // announced by `state`, which decodes this object exactly as
        // `kind` decodes the pane. `none` has no keys, and publishing a
        // null `status` and an empty `body` beside it would be six lies
        // about a request nobody has sent.
        object["response"] = apiResponseJSON(snapshot.response)
        object["recent"] = .array(snapshot.recent.map(apiRecentRowJSON))
        object["recentTruncated"] = .bool(snapshot.recentTruncated)
        // W14: whether a send is in flight. While it is, a second api_request or api_send on
        // this pane is refused, and api_cancel is the way to end it.
        object["sending"] = .bool(snapshot.sending != nil)
        return object
    }
}
