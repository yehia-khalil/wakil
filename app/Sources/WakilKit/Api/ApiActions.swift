import Foundation

/// The refusals the api pane's actions owe a caller.
///
/// **The first two are `PickAPI`'s sentences, deliberately**
/// (`apiresolve.go`). The Go resolver already refuses an unknown entry
/// name and an environment with none, in words the agent has been reading
/// since #183; a second vocabulary for the same refusals at the Swift layer
/// would teach an agent that "no api entry named billing" and whatever this
/// file invented were different problems. `PickAPI`'s third, an omitted
/// name among several, is not refused here any more: `api_open` opens the
/// pane unpointed and Send refuses it (9b W1, #183 amended).
///
/// **The rest are `api_set_request`'s, and every one of them is about the
/// SHAPE of the call rather than the content of the draft** (#190). A
/// duplicate header name, an unparseable field name and a control
/// character in a value are all things the operator can see on the row
/// they are wrong on, so they are marked and join the one aggregated send
/// refusal instead of being eaten a keystroke at a time. What is refused
/// here is a call that could not be read as a draft at all.
public enum ApiActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case noEntries(action: String, environment: String)
    case unknownEntry(action: String, entry: String, names: [String])
    case missingPane(action: String)
    case notAnApiPane(action: String, pane: String, kind: String)
    case badMethod(action: String, found: String)
    case notAPartList(action: String, region: String)
    case notAPart(action: String, region: String, index: Int, found: String)
    case unnamedSlot(action: String, region: String, index: Int)
    case boundValueIsAGesture(action: String, region: String, index: Int)
    case notARowList(action: String, region: String)
    case notARow(action: String, region: String, index: Int)
    case notFreeText(action: String, region: String, found: String)
    case badEntry(action: String, found: String)
    /// The one refusal here that is about the DRAFT rather than the shape
    /// of the call (#191, Decision 27): the operator's cursor is in a
    /// field it names, so the write is refused whole. **Its wording is
    /// unchanged by Amendment 9a's focus rule.**
    case underTheOperatorsHand(action: String, fields: [String])
    /// `api_unbind`'s three, and all of them say the pane and the draft
    /// disagree about the shape of a region rather than that the operator
    /// did something wrong.
    case unbindOutOfRange(action: String, region: String, index: Int)
    case unbindNotABinding(action: String, region: String, index: Int)
    case unbindNoSuchRegion(action: String, region: String)
    /// `api_bind`'s three, all about the drop rather than the draft.
    case bindNoSource(action: String)
    case bindNoRow(action: String)
    case bindNoSuchRow(action: String, source: String, row: Int)
    case notAReadMethod(action: String, method: String)
    case notAMutationMethod(action: String, method: String)
    case sendNeedsAStatement(action: String)
    case reopenNoRow(action: String)
    case reopenNoSuchRow(action: String, row: String)
    case unbindNoIndex(action: String)
    case unbindNoRowName(action: String, region: String)
    /// W17: a hole's column is binary, refused at the drop rather than at Send.
    case binaryColumn(action: String, column: String, declaredType: String)
    /// W14: one send per pane. A second is refused rather than queued, so two replies never race
    /// for one response.
    case sendInFlight(action: String)
    /// W14: `api_cancel` with nothing to cancel.
    case nothingInFlight(action: String)
    /// Amendment 11: a cURL fill or its Undo refused. The description is exactly `line` — the
    /// words the pane's line shows, which are already a sentence about the paste.
    case curlRefused(action: String, line: String)

    public var description: String {
        switch self {
        case .curlRefused(_, let line):
            return line
        case .sendInFlight(let action):
            return "\(action): a send is already in flight on this pane — wait for its reply, or "
                + "cancel it with api_cancel"
        case .nothingInFlight(let action):
            return "\(action): nothing is in flight on this pane — there is no send to cancel"
        case .noEntries(let action, let environment):
            let env = environment.isEmpty ? "this environment" : "environment \"\(environment)\""
            return "\(action): no api configured for \(env) — an api pane sends to a named "
                + "api[] entry of the active environment, and there is none to name."
        case .binaryColumn(let action, let column, let declaredType):
            return "\(action): \(column) is a \(declaredType.uppercased()) column — binary "
                + "values arrive corrupted, so they can't be bound"
        case .unknownEntry(let action, let entry, let names):
            return "\(action): no api entry named \(entry) in this environment. It declares: "
                + names.joined(separator: ", ")
        case .missingPane(let action):
            return "\(action): name the pane to write. This action writes a draft into an api "
                + "pane that is already open; api_open is what makes one."
        case .notAnApiPane(let action, let pane, let kind):
            return "\(action): pane \"\(pane)\" is a \"\(kind)\" pane, and this action writes an "
                + "HTTP request draft. Read the pane to see what it is showing, or open an api "
                + "pane with api_open."
        case .badMethod(let action, let found):
            return "\(action): method is \(found). A draft always has a method, and it is the "
                + "verb the request is sent with — leave the key out to keep the one the draft "
                + "already has."
        case .notAPartList(let action, let region):
            return "\(action): \(region) must be a list of parts. A request field is a SEQUENCE "
                + "of parts and never a string with delimiters in it, so that nothing a database "
                + "cell holds can be read back as markup."
        case .notAPart(let action, let region, let index, let found):
            return "\(action): \(region) part \(index) is \(found). A part is "
                + "{\"literal\": \"text\"} or {\"slot\": \"name\"}, and nothing else."
        case .unnamedSlot(let action, let region, let index):
            return "\(action): \(region) part \(index) is a slot with no name. A hole is named "
                + "so that the request still reads the way the API's own docs write it, and so "
                + "that a refusal can say which hole is empty."
        case .boundValueIsAGesture(let action, let region, let index):
            return "\(action): \(region) part \(index) is a bound value this region does not "
                + "hold. A binding is made by dropping a row on a hole — never by writing one: "
                + "it pins the source column's declared type and the source pane's generation "
                + "at the moment of the drop, and read_pane publishes neither. A write may "
                + "carry back a binding the same region already holds, exactly as read_pane "
                + "published it and once; to make a new one, write a slot here and fill it "
                + "with api_bind."
        case .notARowList(let action, let region):
            return "\(action): \(region) must be a list of {\"name\", \"value\"} rows. The name "
                + "and the value are carried apart so that no one types a delimiter and hopes "
                + "Wakil finds the boundary."
        case .notARow(let action, let region, let index):
            return "\(action): \(region) row \(index) has no name. A row is "
                + "{\"name\": \"…\", \"value\": [parts]}; value may be omitted and means empty."
        case .badEntry(let action, let found):
            return "\(action): entry is \(found). This draft already targets an entry, so an "
                + "unnamed one cannot mean “the only one there is” the way it does on api_open — "
                + "it would silently re-point the request at a different backend. Name the entry "
                + "to move the draft, or leave the key out to keep the one it has."
        case .reopenNoRow(let action):
            return "\(action): name which past send to reopen, as row — the id of a row in "
                + "the pane's recent, which read_pane publishes."
        case .reopenNoSuchRow(let action, let row):
            return "\(action): Recent for this pane's project and environment holds no row "
                + "\(row). It may have been trimmed off the end — the list is capped, or it may "
                + "belong to another environment's list — and a missing row is refused rather "
                + "than approximated by its neighbour."
        case .notAMutationMethod(let action, let method):
            return "\(action) sends the mutation methods, and this draft's method is "
                + "\(method). A read is api_request's, which costs nothing in any "
                + "environment — nothing was sent."
        case .sendNeedsAStatement(let action):
            return "\(action): name what is being sent, as statement. It is shown to the "
                + "operator verbatim when the send is confirmed, so a gated send with nothing "
                + "to show would raise a plane that could not say what it was confirming."
        case .unbindNoIndex(let action):
            return "\(action): name which position to unbind, as index — counting from zero "
                + "within the region's parts."
        case .unbindNoRowName(let action, let region):
            return "\(action): the \(region) region has rows, so name which one, as name. The "
                + "request does have a \(region); what is missing is which row of it."
        case .notAReadMethod(let action, let method):
            return "\(action) sends GET and HEAD, and this draft's method is \(method). A "
                + "mutation method is api_send's, which is gated in production — nothing was "
                + "sent."
        case .bindNoSource(let action):
            return "\(action): name the database pane the row was dragged from, as source."
        case .bindNoRow(let action):
            return "\(action): name which row was dropped, as row — its position on screen, "
                + "counting from zero, in the order the grid is currently sorted."
        case .bindNoSuchRow(let action, let source, let row):
            return "\(action): pane \(source) has no row \(row) on screen. It may hold no "
                + "result yet, or fewer rows than that — nothing was bound."
        case .unbindOutOfRange(let action, let region, let index):
            return "\(action): \(region) has no part at position \(index). The pane and the "
                + "draft disagree about the shape of this region; nothing was unbound, because "
                + "guessing which is right would remove a different part."
        case .unbindNotABinding(let action, let region, let index):
            return "\(action): \(region) position \(index) is not a bound value — only a "
                + "binding can be unbound. A hole is already unbound, and a literal was typed "
                + "rather than dropped."
        case .unbindNoSuchRegion(let action, let region):
            return "\(action): this request has no \(region)."
        case .underTheOperatorsHand(let action, let fields):
            // Every colliding field in ONE sentence, and the escape named
            // in it. The escape is what makes this cost a turn rather
            // than the request, so an agent that reads only the first
            // line still knows what to do next.
            let named = fields.count == 1 ? "it" : "them"
            return "\(action): the operator is editing \(fields.joined(separator: ", ")) on this "
                + "pane, and has not saved \(named) yet. A draft request has ONE author — it is "
                + "what goes on the wire, with nothing underneath it — so a write that would "
                + "land under the operator's hand is refused whole rather than field by field, "
                + "and no part of this call was applied. Write the fields they are not in, or "
                + "read the pane back and work from what it now holds. An api_open that names "
                + "no pane opens one of your own, and a draft nobody else is holding cannot "
                + "collide at all."
        case .notFreeText(let action, let region, let found):
            return "\(action): \(region) is \(found), and it is free text. It is the one field "
                + "on this draft that admits no parts, so nothing can be bound into it — a "
                + "content type is what the bytes claim to be, not data the request carries."
        }
    }
}

/// One api entry, as `list_apis` publishes it.
///
/// **Read from the capability layer rather than from a file.** The app
/// does not parse `project.json` — Invariant 10 puts configuration behind
/// the capability processes — so the pane learns which entries exist by
/// asking `wakil-http`, which is the same process that will later send
/// the request. One reader, one answer.
struct ApiEntryListing: Sendable, Equatable {
    let name: String
    let baseURL: String
    /// `list_apis`' `authenticated`, verbatim: whether a credential is
    /// CONFIGURED. Published to the pane as `credentialed`, renamed for
    /// the one reason a rename is ever worth it — `authenticated` reads,
    /// to an agent, as *the request will authenticate*, which is exactly
    /// what this boolean does not promise.
    let credentialed: Bool
}

/// Reads `list_apis`' result into entries. A result that is not the shape
/// this expects yields no entries rather than throwing: the caller's
/// answer to "no entries could be read" and to "the environment declares
/// none" is the same pane with a null origin, and inventing a distinct
/// failure for a malformed reply would be a third state nobody can act on
/// differently.
func apiEntries(from result: JSONValue) -> [ApiEntryListing] {
    guard case .object(let obj) = result,
          case .object(let structured)? = obj["structuredContent"],
          case .array(let apis)? = structured["apis"]
    else { return [] }
    return apis.compactMap { entry in
        guard case .object(let e) = entry, case .string(let name)? = e["name"] else { return nil }
        var baseURL = ""
        if case .string(let b)? = e["baseUrl"] { baseURL = b }
        var credentialed = false
        if case .bool(let a)? = e["authenticated"] { credentialed = a }
        return ApiEntryListing(name: name, baseURL: baseURL, credentialed: credentialed)
    }
}

/// Every entry the active environment declares, read with ONE `list_apis` (W1). `nil` when there
/// is no client to ask (`--dispatch`, this module's tests). `[]` when the call failed, because
/// "could not read" and "declares none" are the same pane with no origin.
func apiListing(http: (any ToolCaller)?) async -> [ApiEntryListing]? {
    guard let http else { return nil }
    return (try? await apiListingRead(http: http)) ?? []
}

/// `list_apis`, **with a failure kept apart from an answer** (fix round 1, item 3): a call that
/// threw, or a result marked `isError`, throws here. The resolver leaves every pane as it was
/// on a failure, where an empty successful answer still means "declares none".
func apiListingRead(http: any ToolCaller) async throws -> [ApiEntryListing] {
    let result = try await http.callTool(
        name: "list_apis", arguments: .object([:]), timeout: MCPClient.readReplyTimeout)
    if case .object(let obj) = result, obj["isError"] == .bool(true) {
        throw ApiListingFailed()
    }
    return apiEntries(from: result)
}

struct ApiListingFailed: Error {}

/// A `wakil-http` tool's `structuredContent`, or its refusal: a result marked `isError` throws
/// `curlRefused` in the tool's own words (Amendment 11 — `parse_curl`'s refusal is the fill's).
func apiToolStructured(_ result: JSONValue, tool: String, action: String) throws -> JSONValue {
    guard case .object(let obj) = result else {
        throw ApiActionError.curlRefused(action: action, line: "\(tool) answered nothing")
    }
    if obj["isError"] == .bool(true) {
        throw ApiActionError.curlRefused(
            action: action, line: mcpErrorText(from: obj) ?? "\(tool) failed with no message")
    }
    guard let structured = obj["structuredContent"] else {
        throw ApiActionError.curlRefused(action: action, line: "\(tool) answered nothing")
    }
    return structured
}

/// The entry `api_open` points at, or `nil` for an **unpointed** pane (W1; #183 amended). A
/// named entry must exist. With no name, one entry is that entry, none is refused, and several
/// is unpointed. **Nothing is guessed**: Send refuses an unpointed pane (`apiPickAnEntryFirst`),
/// because the entries do not share a credential and a guess would send one backend's token to
/// another backend's host.
func apiOpenEntry(
    named: String?, from entries: [ApiEntryListing], environment: String
) throws -> ApiEntryListing? {
    if let named, !named.isEmpty {
        guard let match = entries.first(where: { $0.name == named }) else {
            throw ApiActionError.unknownEntry(action: "api_open", entry: named, names: entries.map(\.name))
        }
        return match
    }
    switch entries.count {
    case 0: throw ApiActionError.noEntries(action: "api_open", environment: environment)
    case 1: return entries[0]
    default: return nil
    }
}

/// The NAMED entry `api_set_request` re-points a draft at, resolved against what the environment
/// declares. **Always a name**: the handler refuses an empty one before it gets here, so there
/// is no omitted branch to be ambiguous in.
///
/// **An unwired client is `--dispatch` and this module's own tests**: the call resolves to the
/// entry named, with no origin. That is the same answer an environment whose entries cannot be
/// read gives, and for the caller it is the same situation — nothing to send to yet.
func apiEntry(
    named: String, action: String, http: (any ToolCaller)?
) async throws -> ApiEntryListing {
    guard let listing = await apiListing(http: http) else {
        return ApiEntryListing(name: named, baseURL: "", credentialed: false)
    }
    guard let match = listing.first(where: { $0.name == named }) else {
        throw ApiActionError.unknownEntry(action: action, entry: named, names: listing.map(\.name))
    }
    return match
}

/// Send's refusal from an unpointed pane (W1). It names no region: the entry is not one.
public let apiPickAnEntryFirst = "pick an entry first"

/// Unpointed: no entry, in an environment declaring several. A single-entry environment never
/// leaves a pane unpointed (Review Focus 5).
public func apiPaneIsUnpointed(entry: String, entries: [String]) -> Bool {
    entry.isEmpty && entries.count > 1
}

/// What a pane's entry resolves to in an environment's listing (W1). **By name**: an entry of
/// that name gives this environment's origin and credential flag; none keeps the name with no
/// origin, so the URL line can say the environment declares none. An unpointed pane in a
/// single-entry environment takes that entry.
func apiReresolution(
    entry: String, listing: [ApiEntryListing]
) -> (entry: String, origin: String?, credentialed: Bool) {
    if let match = listing.first(where: { $0.name == entry }) {
        return (match.name, apiPaneOrigin(baseURL: match.baseURL), match.credentialed)
    }
    if entry.isEmpty, listing.count == 1 {
        let only = listing[0]
        return (only.name, apiPaneOrigin(baseURL: only.baseURL), only.credentialed)
    }
    return (entry, nil, false)
}

/// Re-resolves every api pane after the environment changed, or at launch (W1). One
/// `list_apis`, then each pane by name. **Returned by `registerApiActions`**, because the
/// action module is what holds the http client.
public struct ApiPaneResolver: Sendable {
    let panes: PaneStore
    let http: (any ToolCaller)?
    /// W8: a pane the re-resolve points at another entry is retitled. `nil` in tests that only
    /// read the store.
    var layout: LayoutStore? = nil

    /// `restored`: api panes on the canvas the store may not hold yet (`reresolveApis`).
    ///
    /// **Fix round 1.** The store's generation is captured BEFORE `list_apis` is asked, so an
    /// answer overtaken by a later switch writes nothing; and a failed `list_apis` writes
    /// nothing either, rather than blanking every origin.
    public func reresolve(environment: String, restored: [String] = []) async {
        guard let http else { return }
        let generation = await panes.apiResolutionMark()
        guard let listing = try? await apiListingRead(http: http) else { return }
        guard let changed = await panes.reresolveApis(
            environment: environment, listing: listing, restored: restored, generation: generation)
        else { return }
        for (paneId, entry) in changed {
            await layout?.retitle(id: paneId, to: apiPaneTitle(entry: entry))
        }
    }
}

/// The URL line's lead: the origin, or what is missing, in caution's amber.
public enum ApiOriginLine: Equatable, Sendable {
    case origin(String)
    case caution(String)
}

public func apiOriginLine(_ snapshot: ApiSnapshot) -> ApiOriginLine {
    if let origin = snapshot.request.origin { return .origin(origin) }
    if apiPaneIsUnpointed(entry: snapshot.entry, entries: snapshot.entries) {
        return .caution("pick an entry — \(snapshot.environment) declares \(snapshot.entries.count)")
    }
    if !snapshot.entry.isEmpty, !snapshot.entries.isEmpty, !snapshot.entries.contains(snapshot.entry) {
        return .caution("\(snapshot.environment) declares no entry named \(snapshot.entry) — pick one")
    }
    return .caution("no origin — this entry does not resolve")
}

/// Refuses a pane the canvas says is not an api pane.
///
/// **A layout that does not hold the pane is not refused**, on
/// `requireDataSurfacePane`'s own terms: `--dispatch` and this module's
/// tests register against a `LayoutStore` holding nothing, and
/// `requireOpenPane` is what refuses an id no pane holds.
func requireApiPane(_ paneId: String, action: String, layout: LayoutStore?) async throws {
    guard let pane = await layout?.snapshot().panes.first(where: { $0.id == paneId }),
          pane.kind != "api"
    else { return }
    throw ApiActionError.notAnApiPane(action: action, pane: paneId, kind: pane.kind)
}

/// The origin an api pane draws, or `nil` when the entry does not resolve
/// to one.
///
/// **Not a second `NormalizeHTTPBase`.** That gate lives in `wakilcore`
/// and runs on every send; re-implementing its rules here would be two
/// answers to "is this base usable", free to disagree, and the one that
/// decides is the one the request goes through. What this does is the
/// narrower thing the surface needs: show the origin when there is one,
/// and show nothing when there is not.
func apiPaneOrigin(baseURL: String) -> String? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// An api pane's title: its entry, or `api` while it has none.
///
/// **Derived from the entry, and re-derived whenever the entry changes**
/// (W8): `api_open`, `api_set_request`'s `entry`, `api_reopen` and a
/// re-resolve. Never stored and never edited. There is no operator-owned
/// pane name to protect here (the gap where one would go is #131), so a
/// title that drifts from what the pane is actually pointed at has nothing
/// to protect and nothing to gain.
///
/// **No path segment** (final review): the title is retitled only when the
/// entry moves, so a segment would go stale the first time the path was typed.
func apiPaneTitle(entry: String) -> String {
    entry.isEmpty ? "api" : entry
}

/// The pane an api request belongs in, opening one when none was named —
/// and retitling it when it was.
///
/// **The third sibling of `resolvePane`, not `resolvePane` itself**, for
/// the reason `resolveTerminalPane` is the second: that helper's "open a
/// new one" branch hardcodes `kind: "db"`, so inheriting it literally
/// would open a **db** pane for an HTTP request. Generalising the three
/// into one is #177's, and is a real design question rather than a
/// mechanical extract — each sibling records a different second fact.
///
/// **This one's second fact is the ENTRY**, where the terminal's is its
/// path — and it is recorded on the draft in `PaneStore` rather than on
/// `Pane`, because one pane sends to `billing` and then to `auth` without
/// a second pane being opened.
///
/// Returns the literal `"api"` when there is no layout to open a pane in
/// — `--dispatch` and tests — mirroring both siblings' own fallback.
func resolveApiPane(explicit: String?, title: String, layout: LayoutStore?) async -> String {
    if let named = queryTargetPane(explicit: explicit, layout: nil) {
        await layout?.retitle(id: named, to: title)
        return named
    }
    guard let layout else { return "api" }
    return await layout.open(kind: "api", title: title).id
}

/// Registers the api client pane's actions.
///
/// **The pane's actions** (#188, #190, #192, W14): `api_open`, `api_set_request`,
/// `api_bind` and `api_unbind` write the draft; `api_request` and `api_send` send it, one
/// send in flight per pane; `api_cancel` ends that send; `api_reopen` and `api_render_curl`
/// read the pane's past tense and its draft; `api_fill_from_curl` writes the whole draft from a
/// pasted cURL command and `api_undo_fill` puts back what it replaced (Amendment 11).
///
/// `.control`, not `.read`: opening a pane changes Wakil's own state and
/// reaches nothing outside it. The `list_apis` call it makes to resolve
/// the entry does leave the process, but it reads the active project's own
/// configuration — the same call `db_list_databases` makes as a `.read`
/// without touching a database. What must not happen is for opening a pane
/// to be gated in production: being pointed at production is no reason to
/// be unable to look at what an entry is.
@discardableResult
public func registerApiActions(
    into registry: ActionRegistry,
    panes: PaneStore,
    layout: LayoutStore? = nil,
    http: (any ToolCaller)? = nil,
    activeContext: @escaping @Sendable () async
        -> (org: String, project: String, environment: String, rootPath: String)
        = { ("", "", "", "") }
) async -> ApiPaneResolver {
    await registry.register(Action(
        name: "api_open",
        description: "Open an API client pane, pointed at one named api entry of the active "
            + "environment. entry is OPTIONAL: with one entry, naming none points at it; "
            + "with several, naming none opens the pane UNPOINTED, with every entry in the "
            + "result's entries; Send from an unpointed pane is refused ('pick an entry "
            + "first') until an entry is chosen with api_set_request's entry, because the "
            + "entries do not share a credential and a guess would send one backend's token "
            + "to another backend's host. Naming no pane opens a "
            + "new one; naming an open pane re-points that pane at this entry instead, which "
            + "is what the chooser in its URL line does. The pane opens EMPTY: no request "
            + "built, nothing bound, nothing sent. Read it to see what it is pointed at — "
            + "origin is null when the entry does not resolve to a base URL, which is the "
            + "configuration failure showing before any request leaves rather than after.",
        kind: .control,
        // 2e (#196). Agent-reachable: opening an api pane and pointing
        // it at a named entry is a READ of the environment's own
        // configuration, and 2c-iv's design is that this pane is
        // dual-driven. `api_send` is `.mutate` and reaches the gate
        // instead, which is where the asymmetry actually lives.
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "entry": .object(["type": .string("string")]),
                "pane": .object(["type": .string("string")]),
            ]),
            // No `required`: a bare `api_open {}` is the single-entry
            // environment's whole invocation, and ⌘K dispatches exactly
            // that. `term_open` dropped its own required param for the
            // same reason (walk defect B1).
        ]),
        handler: { params in
            let explicit = optionalString(params, "pane")
            try await requireOpenPane(explicit, action: "api_open", layout: layout)
            let context = await activeContext()

            let named = optionalString(params, "entry")
            // Fix round 1, item 4: re-opening a pane that is already pointed, naming no entry,
            // keeps its entry rather than silently unpointing it — re-resolved by name, exactly
            // as an environment switch would (`apiReresolution`).
            var kept: String?
            if named?.isEmpty ?? true, let explicit {
                let current = await panes.apiSnapshot(paneId: explicit).entry
                if !current.isEmpty { kept = current }
            }
            // **One `list_apis`**, read for both the entry and the chooser's list, so the two
            // cannot disagree about what exists.
            let entry: ApiEntryListing?
            let declared: [String]
            if let listing = await apiListing(http: http) {
                if let kept {
                    let again = apiReresolution(entry: kept, listing: listing)
                    entry = listing.first { $0.name == again.entry }
                        ?? ApiEntryListing(name: again.entry, baseURL: "", credentialed: false)
                } else {
                    entry = try apiOpenEntry(named: named, from: listing, environment: context.environment)
                }
                declared = listing.map(\.name)
            } else {
                // Unwired: whatever was named (or kept), with no origin, as before.
                entry = ApiEntryListing(name: kept ?? named ?? "", baseURL: "", credentialed: false)
                declared = []
            }
            let name = entry?.name ?? ""
            let origin = entry.flatMap { apiPaneOrigin(baseURL: $0.baseURL) }
            let credentialed = entry?.credentialed ?? false
            let resolved = await resolveApiPane(
                explicit: explicit,
                // A fresh draft has no path, so the title is the entry
                // alone until a request is built.
                title: apiPaneTitle(entry: name),
                layout: layout)
            let entries = declared.isEmpty ? [name] : declared
            await panes.openApi(
                paneId: resolved, entry: name, environment: context.environment,
                origin: origin, credentialed: credentialed, entries: entries)
            return .object([
                "pane": .string(resolved),
                "entry": .string(name),
                "origin": origin.map { .string($0) } ?? .null,
                "credentialed": .bool(credentialed),
                // **The whole list, because the window needs it and this
                // call already has it.** The chooser offers the
                // environment's entries, and the alternative was either a
                // second action listing what this one already read, or an
                // http client on `WindowModel` — a defaulted injectable
                // production could forget to pass, which is a defect shape
                // this repo has paid for and which only running the app
                // finds. An agent reading this key learns what it could
                // re-point to without a second call — and, for an unpointed
                // pane, what it must choose between.
                "entries": .array(entries.map { .string($0) }),
            ])
        }
    ))

    await registry.register(Action(
        name: "api_set_request",
        description: "Write a request into an api pane's draft. EVERY REGION IS OPTIONAL AND "
            + "ABSENT MEANS UNCHANGED, never cleared — so this one action is both the "
            + "operator's edit of a single region and an agent's build of a whole request. "
            + "Clear a region by naming it with an empty list. Nothing is sent: api_send and "
            + "api_request are what put a request on the wire.\n"
            + "A request field is a SEQUENCE OF PARTS, never a string with delimiters in it, "
            + "and there is no template syntax anywhere in Wakil — so a database cell holding "
            + "braces, a slash or a template tag is inert by construction rather than by "
            + "escaping, and braces you write in a JSON body stay literal text. A part is "
            + "{\"literal\": \"text\"} or {\"slot\": \"name\"}, and nothing else. A slot is a "
            + "NAMED HOLE: sourceless, never on the wire, and a draft holding one refuses to "
            + "send until a row is dropped on it with api_bind — the name you give it is the "
            + "label the chip keeps once it is filled, so the request still reads the way the "
            + "API's own docs write it. There is no separate add-slot action, because a slot "
            + "is a part. A bound value cannot be MADE here: it pins provenance recorded at the "
            + "moment a row was dropped. A write may CARRY one the same region already holds — "
            + "name, binding and source exactly as read_pane published them — anywhere in that "
            + "region, so the text around a chip can be rewritten; each held binding once, and "
            + "any other bound part is refused (api_bind is the gesture). A write naming a "
            + "region that OMITS a binding it held drops that binding, as api_unbind and the "
            + "operator's × or Backspace do.\n"
            + "The regions are the four the request has, in wire order. path is parts, and you "
            + "author the slashes — a bound value in it is escaped as ONE segment at send. "
            + "query is a list of {name, value} rows carrying the name and the value APART, so "
            + "nobody types a ? or an & and hopes Wakil finds the boundary. headers is the same "
            + "row shape; the region is a MAP, so a name already on the request is refused as a "
            + "duplicate when the request is sent — including authorization, which the entry "
            + "supplies and this pane never holds, and content-type, which is Wakil's own row. "
            + "A malformed header name or a control character in a value is marked on its row "
            + "and joins that same one aggregated refusal, rather than being eaten as you type. "
            + "contentType is that row: free text, literal-only, the one field on the draft "
            + "that admits no parts. body is JSON, ruled rather than unimplemented — form "
            + "encoding and raw text are not offered, and curl in a terminal pane is the hatch. "
            + "AN EMPTY BODY SENDS NO BODY AND NO CONTENT TYPE, and a content type left beside "
            + "an emptied body is omitted from the wire. A GET or HEAD sends no body at all; "
            + "the draft keeps it for a later mutation.\n"
            + "ONE PANE, ONE DRAFT, ONE AUTHOR: this write is REFUSED WHOLE, with every "
            + "colliding field named at once, while the operator's cursor is in a field "
            + "it names — a draft request is what goes on the wire, with nothing underneath "
            + "it, so a request neither writer composed must never be able to sit on the "
            + "screen. Fields they are not in are unaffected, and a refusal applies no part "
            + "of the call. The way past it is a pane of your own: api_open naming no pane "
            + "opens one, which is why contending is opt-in and costs a turn rather than the "
            + "request. Nothing here reports whether a field is being edited — read_pane "
            + "publishes the screen, not keystrokes or the cursor.\n"
            + "entry re-points the draft at another api[] entry of the active environment, by "
            + "name, keeping every region — an unknown name is refused rather than guessed at. "
            + "method is the verb the request is sent with, upper-cased. Read the pane to see "
            + "the whole draft back; this result answers only what the pane is now pointed at.",
        kind: .control,
        // 2e (#196). Agent-reachable, and this registration's own
        // description is the argument: "this one action is both the
        // operator's edit of a single region and an agent's build of a
        // whole request". Nothing is sent by it.
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "entry": .object(["type": .string("string")]),
                "method": .object(["type": .string("string")]),
                "path": .object([
                    "type": .string("array"), "items": .object(["type": .string("object")]),
                ]),
                "query": .object([
                    "type": .string("array"), "items": .object(["type": .string("object")]),
                ]),
                "headers": .object([
                    "type": .string("array"), "items": .object(["type": .string("object")]),
                ]),
                "contentType": .object(["type": .string("string")]),
                "body": .object([
                    "type": .string("array"), "items": .object(["type": .string("object")]),
                ]),
            ]),
            // `pane` alone is required, and it is required for the reason
            // `api_open`'s is not: this action writes into a draft that
            // already exists, so there is no "open one" branch for an
            // omitted id to fall into.
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let action = "api_set_request"
            guard case .object(let fields) = params,
                  case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)

            // **One pane, one draft, one author** (#191, Decision 27). The
            // rule itself is `apiDraftCollisions`, beside the draft it is
            // about; what is here is the call to it and the refusal it
            // produces.
            //
            // **Before any region is decoded, and beside the pane-kind
            // refusal rather than after it**, because this asks the same
            // species of question: whether this caller may write this pane
            // at all. Nothing but the call's own key names is needed to
            // answer it, and a write that is going to be refused whole
            // should not first cost a round trip to `list_apis` to resolve
            // an entry it will not keep.
            let named = fields.keys.compactMap(ApiWriteKey.init(rawValue:))
            let collisions = apiDraftCollisions(
                origin: ActionRegistry.dispatchOrigin,
                writing: named,
                focused: await panes.apiFocus(paneId: paneId))
            guard collisions.isEmpty else {
                throw ApiActionError.underTheOperatorsHand(
                    action: action, fields: collisions.map(\.label))
            }

            // **Every region is decoded before any of them is written.** A
            // draft half-written from a call that turned out to be
            // malformed is a request neither writer composed, which is the
            // thing Decision 27 exists to make impossible from the other
            // direction.
            var draft = await panes.apiDraft(paneId: paneId)
            if let method = fields["method"] {
                guard case .string(let text) = method else {
                    throw ApiActionError.badMethod(
                        action: action, found: "a \(apiJSONTypeName(method))")
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ApiActionError.badMethod(action: action, found: "empty")
                }
                // Upper-cased here and nowhere else. Go matches the verb
                // case-insensitively, so this changes no refusal — what it
                // buys is that the pane draws the method it will send
                // rather than a second spelling of it. **No allow-list**:
                // `AssertHTTPReadOnly` and `httpMutationMethods` are the
                // one policy pair, in Go, on the same ground that keeps
                // `rejectedCallerHeader` there.
                draft.method = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            }
            // W16: each region may carry back the bindings it already holds, once each, and
            // only its own — the pool is built from the draft BEFORE this call wrote anything.
            if let path = fields["path"] {
                var held = ApiHeldBindings(draft.path)
                draft.path = try apiParts(path, action: action, region: "path", held: &held)
            }
            if let query = fields["query"] {
                var held = ApiHeldBindings(draft.query.flatMap(\.value))
                draft.query = try apiNamedRows(query, action: action, region: "query", held: &held)
                    .map { ApiQueryRow(name: $0.name, value: $0.value) }
            }
            if let headers = fields["headers"] {
                var held = ApiHeldBindings(draft.headers.flatMap(\.value))
                draft.headers = try apiNamedRows(
                    headers, action: action, region: "headers", held: &held)
                    .map { ApiHeaderRow(name: $0.name, value: $0.value) }
            }
            if let contentType = fields["contentType"] {
                guard case .string(let text) = contentType else {
                    throw ApiActionError.notFreeText(
                        action: action, region: "contentType",
                        found: "a \(apiJSONTypeName(contentType))")
                }
                draft.contentType = text
            }
            if let body = fields["body"] {
                var held = ApiHeldBindings(draft.body)
                draft.body = try apiParts(body, action: action, region: "body", held: &held)
            }

            // The entry is resolved LAST of the things that can refuse, so
            // that a malformed region is refused without a round trip to
            // `list_apis` — and written first, because re-pointing the
            // draft also moves the origin and the credential the region
            // above is drawn against.
            var entry: ApiEntryListing?
            if let named = fields["entry"] {
                // **An empty name is refused here where `api_open` admits
                // it.** There it means *the only entry there is*, which is
                // the single-entry environment's whole invocation; here the
                // draft already targets one, so the same value would be an
                // omitted name, and silently re-point the request at
                // whatever the environment happens to declare.
                guard case .string(let text) = named else {
                    throw ApiActionError.badEntry(
                        action: action, found: "a \(apiJSONTypeName(named))")
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ApiActionError.badEntry(action: action, found: "empty")
                }
                let resolved = try await apiEntry(named: text, action: action, http: http)
                draft.entry = resolved.name
                entry = resolved
            }

            await panes.setApiDraft(
                paneId: paneId, draft: draft,
                resolution: entry.map { (apiPaneOrigin(baseURL: $0.baseURL), $0.credentialed) })
            // W8: the title follows the entry, and only a write naming one moves it.
            if entry != nil {
                await layout?.retitle(id: paneId, to: apiPaneTitle(entry: draft.entry))
            }
            let api = await panes.apiSnapshot(paneId: paneId)
            // Not a second copy of the draft: `read_pane` is where a draft
            // is read, and publishing one here would be two answers to one
            // question, free to disagree. What this answers is what the
            // pane is now POINTED at, which is the part of the write a
            // caller cannot predict from its own params.
            return .object([
                "pane": .string(paneId),
                "entry": .string(api.entry),
                "method": .string(api.request.method),
                "origin": api.request.origin.map { .string($0) } ?? .null,
                "credentialed": .bool(api.credentialed),
            ])
        }
    ))

    await registry.register(Action(
        name: "api_fill_from_curl",
        description: "Replace an api pane's WHOLE draft with the request a cURL command describes "
            + "— what the operator's paste of `curl …` into the path does. text is the command, "
            + "POSIX shell quoting. Its URL must belong to an entry of the active environment: "
            + "another entry switches the pane to it; an entry only in another environment, or "
            + "no entry, is refused and nothing is written. Credentials, cookies, -F, a body "
            + "from a file, -k, unknown flags, a body on a GET and a #fragment are dropped and "
            + "named in dropped. The replaced draft is kept once for api_undo_fill. text is "
            + "journalled redacted. Refused like api_set_request while the operator is in a "
            + "field of this pane.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "text": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("text")]),
        ]),
        handler: { params in
            let action = "api_fill_from_curl"
            guard case .object(let fields) = params,
                  case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            guard case .string(let text)? = fields["text"] else {
                throw ApiActionError.notFreeText(action: action, region: "text", found: "missing")
            }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)
            // A fill writes every region (Decision 27, as api_set_request names them) — refused
            // before parse_curl is asked, so a refused fill sends the text nowhere.
            let collisions = apiDraftCollisions(
                origin: ActionRegistry.dispatchOrigin,
                writing: ApiWriteKey.allCases,
                focused: await panes.apiFocus(paneId: paneId))
            guard collisions.isEmpty else {
                throw ApiActionError.underTheOperatorsHand(
                    action: action, fields: collisions.map(\.label))
            }
            guard let http else {
                throw ApiActionError.curlRefused(action: action, line: "wakil-http is not running")
            }
            let parsedResult = try await http.callTool(
                name: "parse_curl", arguments: .object(["text": .string(text)]),
                timeout: MCPClient.readReplyTimeout)
            let parsed: ApiCurlParsed
            do {
                parsed = try ApiCurlParsed(
                    json: try apiToolStructured(parsedResult, tool: "parse_curl", action: action))
            } catch is ApiCurlUnreadable {
                throw ApiActionError.curlRefused(
                    action: action, line: "parse_curl answered something Wakil could not read")
            }
            let located = try await http.callTool(
                name: "locate_api_url", arguments: .object(["url": .string(parsed.url)]),
                timeout: MCPClient.readReplyTimeout)
            let location: ApiCurlLocation
            do {
                location = try ApiCurlLocation(
                    json: try apiToolStructured(located, tool: "locate_api_url", action: action))
            } catch is ApiCurlUnreadable {
                throw ApiActionError.curlRefused(
                    action: action, line: "locate_api_url answered something Wakil could not read")
            }
            let current = await panes.apiDraft(paneId: paneId)
            switch apiCurlFill(parsed, location, current: current) {
            case .refused(let line):
                // C1: a refusal sets no pane state; the operator reads it from the outcome.
                throw ApiActionError.curlRefused(action: action, line: line)
            case .fill(let draft, let switches, let dropped):
                let entry = try await apiEntry(named: draft.entry, action: action, http: http)
                let line = apiCurlFillLine(
                    entry: draft.entry, pastedHost: location.pastedHost, entryHost: location.entryHost,
                    dropped: dropped).text
                // One write, then the keep: `setApiDraft` forgets what was kept before.
                await panes.setApiDraft(
                    paneId: paneId, draft: draft,
                    resolution: (apiPaneOrigin(baseURL: entry.baseURL), entry.credentialed))
                await panes.keepApiDraft(paneId: paneId, current, line: line)
                if switches {
                    await layout?.retitle(id: paneId, to: apiPaneTitle(entry: draft.entry))
                }
                return .object([
                    "pane": .string(paneId), "entry": .string(draft.entry),
                    "switched": .bool(switches),
                    "dropped": .array(dropped.map { .string($0) }),
                    "line": .string(line),
                ])
            }
        },
        secretParams: ["text"]
    ))

    await registry.register(Action(
        name: "api_undo_fill",
        description: "Put back the draft the last api_fill_from_curl on this pane replaced — its "
            + "bindings included — and forget it. Refused ('nothing to undo') when there is none: "
            + "any other write to the draft, or a Send, forgets it. Refused like api_set_request "
            + "while the operator is in a field of this pane.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let action = "api_undo_fill"
            guard case .object(let fields) = params,
                  case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)
            // Undo writes the whole draft back, so an agent's is held to Decision 27 too.
            let collisions = apiDraftCollisions(
                origin: ActionRegistry.dispatchOrigin,
                writing: ApiWriteKey.allCases,
                focused: await panes.apiFocus(paneId: paneId))
            guard collisions.isEmpty else {
                throw ApiActionError.underTheOperatorsHand(
                    action: action, fields: collisions.map(\.label))
            }
            guard let kept = await panes.apiKeptDraft(paneId: paneId) else {
                throw ApiActionError.curlRefused(action: action, line: "nothing to undo")
            }
            // Re-resolved by name, as a reopen or a switch is: the entry's origin and credential
            // in the environment active NOW. Written by the store directly, so a binding comes
            // back exactly — api_set_request would refuse one it does not hold.
            let listing = await apiListing(http: http) ?? []
            let resolved = apiReresolution(entry: kept.entry, listing: listing)
            await panes.setApiDraft(
                paneId: paneId, draft: kept, resolution: (resolved.origin, resolved.credentialed))
            await layout?.retitle(id: paneId, to: apiPaneTitle(entry: kept.entry))
            return .object(["pane": .string(paneId), "entry": .string(kept.entry)])
        }
    ))

    await registry.register(Action(
        name: "api_bind",
        description: "Bind values into an api pane's draft by dropping ONE ROW of a database "
            + "pane on it. Every named hole whose name EXACTLY matches a column of that row is "
            + "filled, in one action — a hole named id never takes booking_id, because a "
            + "near-miss that guessed would build a request nobody meant. Holes that match no "
            + "column stay holes and are named once, together, in the result.\n"
            + "THE SAME DROP RE-BINDS every value in the draft that does not currently "
            + "resolve — a capture whose source has re-fetched, a live value whose row has "
            + "left the result — and overwrites none that does. So re-binding after a refresh "
            + "is the same one gesture rather than an unbind and a drop.\n"
            + "A value binds LIVE when the source pane is editable, and is re-read from it by "
            + "the row's key column values at every send, so re-sorting or re-running that "
            + "query cannot make a POST confirm a different row. It binds CAPTURED when the "
            + "pane is not — a join has no stable row identity — and a capture lives exactly "
            + "as long as the rows it came from: when that pane re-fetches the value is dead "
            + "and says so. Wakil never states a captured value's age.\n"
            + "row is the row's position ON SCREEN, counting from zero, in the order the grid "
            + "is currently sorted. This is the only way a bound value is made: a binding pins "
            + "provenance recorded at the moment of the drop, so api_set_request refuses to "
            + "write one.",
        // **`.control`, not `.read`.** `ActionKind.read` is "Observes
        // state. Changes nothing." — and this writes the draft, exactly as
        // `api_set_request` does, which is `.control` for that reason. It
        // still reaches no gate: nothing leaves the process and nothing is
        // sent.
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "source": .object(["type": .string("string")]),
                "row": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("pane"), .string("source"), .string("row")]),
        ]),
        handler: { params in
            let action = "api_bind"
            guard case .object(let fields) = params,
                case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)

            guard case .string(let sourceId)? = fields["source"], !sourceId.isEmpty else {
                throw ApiActionError.bindNoSource(action: action)
            }
            // **`intValue`, never `case .number`.** `JSONValue.init(from:)`
            // decodes `Int64` before `Double`, so `{"row": 0}` off the wire
            // is `.integer(0)` and a `.number` pattern never matches it —
            // which made this action unreachable from any MCP client while
            // its tests, which hand-built `.number(0)`, passed. `intValue`
            // is the repo's own answer and it also refuses `1e30`, where
            // `Int(_:)` would trap and take the window with it.
            guard let row = fields["row"]?.intValue, row >= 0 else {
                throw ApiActionError.bindNoRow(action: action)
            }
            guard let drop = await panes.dropSource(paneId: sourceId, row: row) else {
                throw ApiActionError.bindNoSuchRow(action: action, source: sourceId, row: row)
            }

            // **Decision 27 applies to this door too** (#191). `api_bind`
            // writes the whole draft, so an agent's drop while the operator's
            // cursor is in a field would rewrite it under their hand exactly
            // as a blind `api_set_request` would. The rule is not about which
            // action writes; it is about there being one author.
            try await refuseIfUnderTheOperatorsHand(
                paneId: paneId, action: action, origin: ActionRegistry.dispatchOrigin,
                panes: panes,
                writing: ApiWriteKey.allCases)

            // **The holes are the draft's own, never the caller's.** A drop
            // fills what is there; letting a caller list them would let it
            // name one the draft does not hold, and the aggregate would
            // then report a miss about a hole the operator cannot see.
            let draft = await panes.apiDraft(paneId: paneId)
            let holes = apiSlotNames(in: draft)
            let before = draft
            let (bound, missed) = try apiBind(
                draft: draft, source: drop, holes: holes, sources: await panes.apiSources())
            await panes.setApiDraft(paneId: paneId, draft: bound)

            // **`rebound` is reported because the re-bind half is
            // invisible otherwise.** A draft with no holes left and three
            // dead captures returns `filled: 0, unmatched: []` — identical
            // to a call that did nothing — while the draft changed under
            // the caller. `filled` counts POSITIONS rather than names, so
            // one hole in three places reads as three.
            let counts = apiBindChanges(before: before, after: bound)
            return .object([
                "pane": .string(paneId),
                "filled": .number(Double(counts.filled)),
                "rebound": .number(Double(counts.rebound)),
                // Named once, together — one drop is one report.
                "unmatched": .array(missed.map { .string($0) }),
                "columns": .array(drop.columns.map { .string($0) }),
                // Re-walk #6: what was filled, and from where — the result line names them.
                "filledNames": .array(counts.names.map { .string($0) }),
                "source": .string(sourceId),
                // The source pane's title, which names a join that has no table.
                "sourceTitle": .string(
                    await layout?.snapshot().panes.first { $0.id == sourceId }?.title ?? ""),
                "table": .string(drop.table),
                "row": .number(Double(row)),
            ])
        }
    ))

    await registry.register(Action(
        name: "api_unbind",
        description: "Return one bound position of an api pane's draft to what it was before "
            + "the drop. A binding that filled a NAMED HOLE becomes that hole again, keeping "
            + "the name, so the request still reads the way the API's own docs write it. A "
            + "binding made by dropping on an empty position had no hole to return to and is "
            + "removed outright.\n"
            + "region is path, body, or query/header with name naming the row — the same four "
            + "regions the request has. index is the position within that region's parts, "
            + "counting from zero. A position holding a literal or a hole is refused rather "
            + "than quietly accepted: only a binding can be unbound, and the refusal says the "
            + "pane and the draft disagree about the region rather than removing a different "
            + "part.",
        // `.control` for the same reason as `api_bind`: it writes the
        // draft.
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "region": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "index": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("pane"), .string("region"), .string("index")]),
        ]),
        handler: { params in
            let action = "api_unbind"
            guard case .object(let fields) = params,
                case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)

            guard case .string(let regionName)? = fields["region"] else {
                throw ApiActionError.unbindNoSuchRegion(action: action, region: "none named")
            }
            // Same trap as `api_bind`'s `row`, and it was worse here: an
            // index off the wire fell into the `else` and reported "this
            // request has no <region>", telling a caller its region was
            // missing when the region was fine.
            guard let index = fields["index"]?.intValue, index >= 0 else {
                throw ApiActionError.unbindNoIndex(action: action)
            }
            var rowName: String?
            if case .string(let name)? = fields["name"] { rowName = name }
            // **A named region with no name is its own refusal**, not a
            // missing region: the request does have a query, and what the
            // caller left out is which row.
            if rowName == nil, apiRegionNeedsARow(regionName) {
                throw ApiActionError.unbindNoRowName(action: action, region: regionName)
            }
            guard let region = apiRegion(named: regionName, row: rowName) else {
                throw ApiActionError.unbindNoSuchRegion(action: action, region: regionName)
            }

            try await refuseIfUnderTheOperatorsHand(
                paneId: paneId, action: action, origin: ActionRegistry.dispatchOrigin,
                panes: panes,
                writing: ApiWriteKey.allCases)

            let draft = try apiUnbind(
                draft: await panes.apiDraft(paneId: paneId), region: region,
                index: index, row: fields["row"]?.intValue)
            await panes.setApiDraft(paneId: paneId, draft: draft)
            return .object(["pane": .string(paneId), "region": .string(region.label)])
        }
    ))

    await registry.register(Action(
        name: "api_request",
        description: "Send the api pane's draft with a READ method — GET or HEAD — and land the "
            + "reply at the bottom of that pane's own surface. A GET COSTS NOTHING, in any "
            + "environment: this action never reaches the write gate and never asks for a "
            + "confirmation, because reading is not priced like writing. api_send is the "
            + "mutation methods' action and it is gated in production.\n"
            + "Every bound value in the draft is resolved first, against the panes on screen "
            + "right now — a live value is re-read from its source row by that row's key "
            + "column values, so what leaves is what the grid is showing. IF ANYTHING CANNOT "
            + "BE RESOLVED THE SEND IS REFUSED AND NOTHING LEAVES, with every failure named at "
            + "once rather than the first: an unfilled hole, a bound value whose row is gone, a "
            + "control character in a header, a duplicate header name. A refusal clears "
            + "nothing — the draft still holds what you built.\n"
            + "A refusal is NOT a response: it carries no status, no timing and no size, "
            + "because nothing was sent. A transport failure carries no status, headers or "
            + "body, because nothing came back. And a send whose fate cannot be established is "
            + "recorded as exactly that, distinct from both — it may have reached the server, "
            + "so it must not be retried blindly. Read the pane to see which of the five "
            + "states the response is in.",
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let action = "api_request"
            guard case .object(let fields) = params,
                case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)

            let snapshot = await panes.apiSnapshot(paneId: paneId)
            // **The method is checked here and not inside the send**, so
            // the refusal names the action a caller should have used
            // rather than reporting a gate it never reached.
            guard apiIsReadMethod(snapshot.request.method) else {
                throw ApiActionError.notAReadMethod(
                    action: action, method: snapshot.request.method)
            }

            // W1: an unpointed pane has nowhere to send. Refused as a refusal the pane draws,
            // naming no region, before the flight begins. Nothing reaches wakil-http.
            if apiPaneIsUnpointed(entry: snapshot.entry, entries: snapshot.entries) {
                let refusal = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: [
                    ApiSendFailure(region: nil, message: apiPickAnEntryFirst)
                ]))
                await panes.setApiResponse(paneId: paneId, response: refusal)
                return .object([
                    "pane": .string(paneId), "state": .string(refusal.state), "status": .null,
                ])
            }

            // W14: one send per pane, in flight for its whole length and cancellable from
            // either channel. `finishApiSend` sets the response and adds the row — the present
            // and the past, in that order; `recordApiSend` ignores a refusal on its own, so no
            // caller decides what counts as past tense.
            let draft = await panes.apiDraft(paneId: paneId)
            let outcome = try await apiSendInFlight(
                paneId: paneId, action: action, method: snapshot.request.method, panes: panes
            ) {
                await apiRequest(
                    draft: draft, sources: await panes.apiSources(),
                    environment: snapshot.environment, http: http,
                    credentialed: snapshot.credentialed, origin: snapshot.request.origin)
            }

            return .object([
                "pane": .string(paneId),
                "state": .string(outcome.response.state),
                "status": outcome.response.status.map { .number(Double($0)) } ?? .null,
            ])
        }
    ))
    await registry.register(Action(
        name: "api_send",
        description: "Send the api pane's draft with a MUTATION method — POST, PUT, PATCH, "
            + "DELETE and the rest. This is the gated half of the send: OUTSIDE PRODUCTION it "
            + "goes on one call, and IN PRODUCTION it costs a typed confirmation that names "
            + "what is being sent. api_request is the read half and costs nothing anywhere.\n"
            + "statement is REQUIRED and is shown to the operator verbatim. Write it to name "
            + "THE REQUEST YOU ARE SENDING — method, host, path — and the body's SHAPE rather "
            + "than its bytes: a large document makes the confirmation unreadable, and an "
            + "operator who scrolls a payload to find the button is one who has stopped "
            + "reading it. Do not describe what the endpoint will DO; Wakil cannot know that, "
            + "and a method-override header means the verb on the wire is not always the "
            + "operation.\n"
            + "Everything api_request does before sending, this does too: every bound value is "
            + "resolved against the panes on screen, and if anything cannot be resolved the "
            + "send is refused whole with every failure named at once. A refusal clears "
            + "nothing.",
        kind: .mutate,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "statement": .object(["type": .string("string")]),
            ]),
            // **`statement` is required.** A gated `.mutate` with nothing
            // to show would raise a confirmation plane that could not say
            // what it was confirming.
            "required": .array([.string("pane"), .string("statement")]),
        ]),
        handler: { params in
            let action = "api_send"
            guard case .object(let fields) = params,
                case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)

            guard case .string(let statement)? = fields["statement"],
                !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ApiActionError.sendNeedsAStatement(action: action) }

            let snapshot = await panes.apiSnapshot(paneId: paneId)
            // **The mirror of `api_request`'s check**, and it has to be
            // here rather than in the send: a GET reaching this action
            // would be priced at the gate, which is the inversion the two
            // actions exist to prevent.
            guard !apiIsReadMethod(snapshot.request.method) else {
                throw ApiActionError.notAMutationMethod(
                    action: action, method: snapshot.request.method)
            }

            // W1: an unpointed pane has nowhere to send. Refused as a refusal the pane draws,
            // naming no region, before the flight begins. Nothing reaches wakil-http.
            if apiPaneIsUnpointed(entry: snapshot.entry, entries: snapshot.entries) {
                let refusal = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: [
                    ApiSendFailure(region: nil, message: apiPickAnEntryFirst)
                ]))
                await panes.setApiResponse(paneId: paneId, response: refusal)
                return .object([
                    "pane": .string(paneId), "state": .string(refusal.state), "status": .null,
                ])
            }

            // W14: one send per pane, in flight for its whole length and cancellable from
            // either channel. `finishApiSend` sets the response and adds the row — the present
            // and the past, in that order; `recordApiSend` ignores a refusal on its own, so no
            // caller decides what counts as past tense.
            let draft = await panes.apiDraft(paneId: paneId)
            let outcome = try await apiSendInFlight(
                paneId: paneId, action: action, method: snapshot.request.method, panes: panes
            ) {
                await apiRequest(
                    draft: draft, sources: await panes.apiSources(),
                    environment: snapshot.environment, http: http,
                    credentialed: snapshot.credentialed, origin: snapshot.request.origin)
            }

            // **The second line, and only when something left.** The
            // gated `statement` was written before resolution, so the
            // dispatch line names a pane and a sentence and nothing that
            // reached the wire. A refusal writes nothing here: there is no
            // URL, and claiming one would record a request that never was.
            if case .ok(let reply) = outcome.response {
                try? await registry.journalSentRequest(
                    action: action, params: params, origin: ActionRegistry.dispatchOrigin,
                    environment: snapshot.environment, url: reply.url, outcome: "sent")
            }

            return .object([
                "pane": .string(paneId),
                "state": .string(outcome.response.state),
                "status": outcome.response.status.map { .number(Double($0)) } ?? .null,
            ])
        },
        // **The registry's second `.mutate`, and the first action anywhere
        // to declare its own price.** The default pair is
        // `(production: .block, otherwise: .gate)`; this is the reverse
        // shape, and it is Decision 25's whole content — production costs
        // a typed confirmation that staging does not, rather than being
        // forbidden outright.
        price: (production: .gate, otherwise: .allow)
    ))
    await registry.register(Action(
        name: "api_cancel",
        description: "Cancel the send in flight on an api pane, as the operator's Cancel does. "
            + "The HTTP request is aborted. A READ reads 'cancelled after N s'. A MUTATION is "
            + "recorded as fate unknown — 'the server may already have it' — because a "
            + "cancelled write may still have landed, so do not resend it blindly. With "
            + "nothing in flight it is refused. While a send is in flight, read_pane's "
            + "sending is true, and a second api_request or api_send on that pane is refused.",
        // `.control`: it changes Wakil's own state, ending a send it started. It writes nothing
        // the draft holds and is never priced by the gate.
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let action = "api_cancel"
            guard case .object(let fields) = params,
                case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)
            guard await panes.cancelApiSend(paneId: paneId) else {
                throw ApiActionError.nothingInFlight(action: action)
            }
            return .object(["pane": .string(paneId)])
        }
    ))
    await registry.register(Action(
        name: "api_reopen",
        description: "Put a past send's request back, by ROW ID from Recent — one list per "
            + "project and environment, shared by every api pane in it, read from any of them "
            + "with read_pane — into THIS pane's draft. The list is newest "
            + "first and capped, so a row's POSITION changes on every send and an index would "
            + "reopen whatever had moved into that slot. A row that has been trimmed off the "
            + "end is refused rather than approximated by its neighbour.\n"
            + "The whole draft is replaced — method, entry, path, query, headers, content type "
            + "and body — with what was actually sent, bound values and all. A row sent to "
            + "another entry re-points the pane at that entry, its origin and credential with "
            + "it, as api_set_request's entry does. Nothing is sent: "
            + "api_request and api_send are what put a request on the wire.",
        // `.control`: it writes the draft, exactly as the other three do.
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "row": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("row")]),
        ]),
        handler: { params in
            let action = "api_reopen"
            guard case .object(let fields) = params,
                case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)

            guard case .string(let rowId)? = fields["row"], !rowId.isEmpty else {
                throw ApiActionError.reopenNoRow(action: action)
            }
            // **No collision check, and that is deliberate.** Reopening is
            // a whole-draft gesture and it always lands; `api_bind` and
            // `api_unbind` are refused under the operator's hand precisely
            // because they can be an agent's mid-edit write, and this one
            // replaces the draft wholesale with something the operator
            // picked off their own screen.
            // **A row sent to another entry re-points the pane at it** (final review I1), as
            // `api_set_request`'s `entry` does: one `list_apis`, read only when the entries
            // differ, under the resolver's own guards — the generation taken before the read,
            // so a switch that overtakes it writes no resolution, and a failed read writes none
            // either. Without it the pane drew no origin and no `authorization` row, and a send
            // recorded `credentialed: false`, so Copy as cURL looked runnable.
            let before = await panes.apiSnapshot(paneId: paneId)
            var listing: [ApiEntryListing]?
            var generation: Int?
            if let row = before.recent.first(where: { $0.id == rowId }),
               row.draft.entry != before.entry, let http
            {
                generation = await panes.apiResolutionMark()
                listing = try? await apiListingRead(http: http)
            }
            guard let draft = await panes.reopenApiRow(
                paneId: paneId, rowId: rowId, listing: listing, generation: generation)
            else {
                throw ApiActionError.reopenNoSuchRow(action: action, row: rowId)
            }
            // W8: the row brings its entry, and the title follows it.
            await layout?.retitle(id: paneId, to: apiPaneTitle(entry: draft.entry))
            return .object([
                "pane": .string(paneId),
                "method": .string(draft.method),
                "entry": .string(draft.entry),
            ])
        }
    ))
    await registry.register(Action(
        name: "api_render_curl",
        description: "Render one PAST send of an api pane as a curl line, by row id from "
            + "Recent — one list per project and environment, shared by every api pane in it, "
            + "read from any of them with read_pane. It works on a row and never on the draft: a draft has no "
            + "sent URL, and a resolved URL on one would be a prediction rather than a "
            + "record.\n"
            + "THE LINE IS NOT RUNNABLE AS RENDERED when the entry supplied a credential, and "
            + "it says so in a comment rather than quietly omitting the header. Wakil never "
            + "holds the credential — it resolves inside the send tool and never enters this "
            + "process — so a runnable line was never available, and one that looked runnable "
            + "would 401 and send you debugging the endpoint instead of the copy. It names no "
            + "scheme and no ref, because neither is published anywhere.\n"
            + "A value bound from a grid appears as <name>. The Recent strip on screen shows "
            + "the value sent beside the name; the curl line keeps <name> only.",
        // `.read`, on the db render-update precedent: it composes text
        // from state already on screen and changes nothing.
        kind: .read,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "row": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("row")]),
        ]),
        handler: { params in
            let action = "api_render_curl"
            guard case .object(let fields) = params,
                case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)

            guard case .string(let rowId)? = fields["row"], !rowId.isEmpty else {
                throw ApiActionError.reopenNoRow(action: action)
            }
            let snapshot = await panes.apiSnapshot(paneId: paneId)
            guard let row = snapshot.recent.first(where: { $0.id == rowId }) else {
                throw ApiActionError.reopenNoSuchRow(action: action, row: rowId)
            }
            return .object([
                "pane": .string(paneId),
                "curl": .string(apiRenderCurl(
                    row: row,
                    // **What actually left, when there is one.** A row
                    // whose send never got a reply has no URL to render,
                    // and its path alone is a path — the line then has no
                    // host, which the refusal below names rather than
                    // letting the operator discover by pasting it.
                    url: row.sentUrl ?? row.path,
                    // The ROW's, recorded at send: Recent is shared (W15), and this pane
                    // may be on another entry than the one the row was sent to.
                    credentialed: row.credentialed)),
            ])
        }
    ))
    return ApiPaneResolver(panes: panes, http: http, layout: layout)
}

/// Whether a method is one `api_request` will send.
///
/// **The two that cost nothing.** Everything else is `api_send`'s, which
/// is `.mutate` and reaches the gate — the split exists because
/// `ActionKind` is fixed per action, so one send would price a `GET` at
/// `.gate`.
public func apiIsReadMethod(_ method: String) -> Bool {
    ["GET", "HEAD"].contains(method.uppercased())
}

/// Which of the rows sharing a name to act on.
///
/// **`nil` is the first, and an out-of-range row is nobody's** — refusing
/// beats silently editing the first, which is the behaviour this replaced.
func apiNamedRow(_ matching: [Int], row: Int?) -> Int? {
    guard !matching.isEmpty else { return nil }
    guard let row else { return matching.first }
    guard matching.indices.contains(row) else { return nil }
    return matching[row]
}

/// Refuses a whole-draft write while the operator's cursor is in a field it would rewrite.
///
/// **Decision 27 is about there being ONE AUTHOR, not about one action.**
/// `api_set_request` checks its own named keys; `api_bind` and
/// `api_unbind` rewrite the draft entire, so they check every key — a drop
/// that landed while the operator's cursor was in a field would rewrite it
/// under their hand exactly as a blind write would, and #191 exists to make that
/// impossible from every direction rather than one.
func refuseIfUnderTheOperatorsHand(
    paneId: String, action: String, origin: ActionOrigin, panes: PaneStore,
    writing keys: [ApiWriteKey]
) async throws {
    let collisions = apiDraftCollisions(
        origin: origin, writing: keys, focused: await panes.apiFocus(paneId: paneId))
    guard collisions.isEmpty else {
        throw ApiActionError.underTheOperatorsHand(
            action: action, fields: collisions.map(\.label))
    }
}

/// What one drop changed: holes filled, and dead bindings repointed.
///
/// **Counted over POSITIONS rather than names**, because a hole named
/// three times is three positions on the operator's screen and reporting
/// it as one would understate what moved.
func apiBindCounts(before: ApiDraft, after: ApiDraft) -> (filled: Int, rebound: Int) {
    let (filled, rebound, _) = apiBindChanges(before: before, after: after)
    return (filled, rebound)
}

/// `apiBindCounts`, plus the NAMES of the holes the drop filled — once each, in the order they
/// appear (re-walk #6: the result line says what was filled, not only how many).
func apiBindChanges(
    before: ApiDraft, after: ApiDraft
) -> (filled: Int, rebound: Int, names: [String]) {
    func positions(_ draft: ApiDraft) -> [ApiPart] {
        var parts = draft.path
        draft.query.forEach { parts += $0.value }
        draft.headers.forEach { parts += $0.value }
        parts += draft.body
        return parts
    }
    var filled = 0
    var rebound = 0
    var names: [String] = []
    for (was, now) in zip(positions(before), positions(after)) where was != now {
        switch (was, now) {
        case (.slot(let name), .bound):
            filled += 1
            if !names.contains(name) { names.append(name) }
        case (.bound, .bound): rebound += 1
        default: break
        }
    }
    return (filled, rebound, names)
}

/// Whether a region name addresses one of several rows.
func apiRegionNeedsARow(_ name: String) -> Bool {
    ["query", "header", "headers"].contains(name.lowercased())
}

/// The sentence the confirmation plane shows (W13). **It names the whole request**: the URL that
/// will leave, path and query, with each hole drawn by its name. The body is named by its shape:
/// a JSON object's top-level keys, a JSON array's length, or a count of bytes of text. **No part
/// counts.**
///
/// **It names the body's SHAPE, never its content** (#194). A large document would make the
/// plane unreadable, and an operator scrolling a payload to find the Confirm button is an
/// operator who stops reading it.
///
/// **It names the REQUEST Wakil puts on the wire, not the operation the server performs**, and
/// that distinction carries the weight. Wakil cannot know what a `POST` does at the other end; a
/// `X-HTTP-Method-Override` header means the verb on the wire is not always the operation, and no
/// guard here can see through one. So the sentence promises only what Wakil is sending — which
/// is the thing Wakil can actually stand behind.
public func apiSendStatement(draft: ApiDraft, origin: String?) -> String {
    let base = origin.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        ?? "the \(draft.entry) entry"
    var url = base + apiStatementText(draft.path)
    if !draft.query.isEmpty {
        url += "?" + draft.query.map { "\($0.name)=\(apiStatementText($0.value))" }
            .joined(separator: "&")
    }
    return "Send \(draft.method.uppercased()) \(url) \(apiStatementBody(draft))"
}

/// Parts as the plane reads them: literals as typed, a hole or bound value as `<name>`.
func apiStatementText(_ parts: [ApiPart]) -> String {
    parts.map { part -> String in
        switch part {
        case .literal(let text): return text
        case .slot(let name): return "<\(name)>"
        case .bound(let bound): return "<\(bound.name)>"
        }
    }.joined()
}

/// The body clause. A named content type other than `application/json` is said after it.
func apiStatementBody(_ draft: ApiDraft) -> String {
    guard !draft.body.isEmpty else { return "with no body" }
    let named = draft.contentType.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = named.isEmpty || named.lowercased() == "application/json" ? "" : " as \(named)"
    switch apiBodyJSONShape(draft.body) {
    case .object(let keys)?: return "with a JSON body {\(keys.joined(separator: ", "))}" + suffix
    case .array(let count)?: return "with a JSON array of \(count)" + suffix
    case .value?: return "with a JSON value" + suffix
    case nil:
        let bytes = draft.body.reduce(0) { total, part in
            if case .literal(let text) = part { return total + text.utf8.count }
            return total
        }
        return "with \(bytes) bytes of text" + suffix
    }
}

/// Every named hole in a draft, in wire order and without repeats.
///
/// **The draft's own holes are what a drop fills**, which is why
/// `api_bind` takes no list of them.
func apiSlotNames(in draft: ApiDraft) -> [String] {
    apiSlotNames(
        inRegions: [draft.path] + draft.query.map(\.value) + draft.headers.map(\.value)
            + [draft.body])
}

/// `apiSlotNames` over the request the pane draws — the same walk, so the pane's
/// unfilled-holes line counts exactly the names a drop would fill.
public func apiSlotNames(in request: ApiRequestSnapshot) -> [String] {
    apiSlotNames(
        inRegions: [request.path] + request.query.map(\.value)
            + request.headers.map { $0.value ?? [] } + [request.body])
}

/// The one walk: every slot's name across `regions`, given in wire order, without repeats.
private func apiSlotNames(inRegions regions: [[ApiPart]]) -> [String] {
    var names: [String] = []
    for parts in regions {
        for part in parts {
            guard case .slot(let name) = part, !names.contains(name) else { continue }
            names.append(name)
        }
    }
    return names
}

/// The region a caller named, or `nil` when it named none of the four.
func apiRegion(named name: String, row: String?) -> ApiRegion? {
    switch name.lowercased() {
    case "path": return .path
    case "body": return .body
    case "query": return row.map { ApiRegion.query($0) }
    case "header", "headers": return row.map { ApiRegion.header($0) }
    default: return nil
    }
}

/// Whether a refusal the window's own controls met is kept off the status line (final review,
/// Minor 5). **Only `api_cancel`'s "nothing is in flight"**: the operator pressed Cancel just
/// as the reply landed, and the reply on screen already answers the press. A line saying there
/// was nothing to cancel, under a response that just arrived, reads as a fault. An agent's
/// `api_cancel` is still refused in those words, since this is read only by `WindowModel`'s
/// `.ui` dispatch.
public func apiSurfaceRefusalIsSilent(_ error: Error) -> Bool {
    if case ApiActionError.nothingInFlight = error { return true }
    return false
}

/// Whether the URL line's entry chooser is interactive. **It always offers the active
/// environment's entries** (spec), so it is enabled whenever there is one to pick that the pane
/// is not already on.
///
/// - **More than one entry**: enabled.
/// - **One entry, and the pane is not on it** (final review, W1): enabled. A pane keeping an
///   entry the environment lacks reads "<env> declares no entry named <name> — pick one", and
///   an unpointed pane reads "pick an entry". Disabled, either was a dead end.
/// - **One entry, and the pane is on it**: disabled, never hidden. Hidden would make that pane
///   look like one that cannot be re-pointed at all, and an operator would have no way to learn
///   that declaring a second `api[]` entry in the project is what makes the control do
///   something. Disabled says both things at once: this is where the entry is chosen, and there
///   is nothing else to choose.
/// - **None**: disabled. There is nothing to offer.
///
/// A function rather than a `disabled(…)` in the view, because `WakilApp` has no test target
/// and this is a ruling rather than a layout detail.
public func apiChooserIsEnabled(entry: String, entries: [String]) -> Bool {
    entries.count > 1 || (!entries.isEmpty && !entries.contains(entry))
}

// MARK: - The drop

/// One row, dropped on the api pane — the payload of the bind gesture.
///
/// **Named for the gesture, not for a pane kind.** What happened is *a row
/// was dropped*; that the row came from a database pane is incidental, and
/// a second source kind later should not need a second bind.
///
/// **It is a composition of three shipped types rather than a new fact.**
/// `ApiSourcePane` carries `columns`, `rows` and `generation`;
/// `PaneEditable` carries `table` and `keyColumns`; `PaneSnapshot` carries
/// `columnTypes`. A binding needs all three and no one of them is enough,
/// so the drop carries the slice of each that `ApiValueSource` requires.
///
/// **`editable` is what decides `.live` against `.captured`**, and it is
/// the same flag the source pane draws in its footer. A pane that cannot
/// be written back to cannot be re-read by key either — its rows have no
/// stable identity — so a value taken out of one is held rather than
/// re-resolved.
public struct ApiDropSource: Sendable, Equatable {
    /// The source pane's id, recorded so a live value can find it again.
    public let pane: String
    /// The table the source pane was showing, for the refusal's sentence.
    public let table: String
    public let keyColumns: [String]
    public let columns: [String]
    /// Positionally aligned with `columns`, as `PaneSnapshot` publishes it.
    public let columnTypes: [String]
    /// The dropped row's cells, positionally aligned with `columns`.
    public let row: [JSONValue]
    /// The source pane's generation at the moment of the drop.
    public let generation: Int
    /// Whether the source pane draws `editable` in its footer.
    public let editable: Bool

    public init(
        pane: String, table: String, keyColumns: [String], columns: [String],
        columnTypes: [String], row: [JSONValue], generation: Int, editable: Bool
    ) {
        self.pane = pane
        self.table = table
        self.keyColumns = keyColumns
        self.columns = columns
        self.columnTypes = columnTypes
        self.row = row
        self.generation = generation
        self.editable = editable
    }

    /// The dropped row's cell for `column`, or `nil` when the source has
    /// no such column. **`nil` is the whole of the miss test** — a hole
    /// matches a column by name and by nothing else.
    func cell(_ column: String) -> JSONValue? {
        guard let index = columns.firstIndex(of: column), index < row.count else { return nil }
        return row[index]
    }

    /// The declared type for `column`, or `""` when the driver declares
    /// none — which Mongo's all-NULL columns do, and which
    /// `ApiHeldCell.declaredType` already documents as legitimate.
    func declaredType(_ column: String) -> String {
        guard let index = columns.firstIndex(of: column), index < columnTypes.count else {
            return ""
        }
        return columnTypes[index]
    }

    /// One text value per `keyColumns` entry, in the same order.
    ///
    /// **Read off the ROW, never off `rowKeys`.** A `rowKey` is an opaque
    /// `WHERE` predicate the driver rendered, and `PaneEditable` is
    /// explicit that Swift may only store, reorder and hand one back. A
    /// key *value* is a different fact and the row holds it.
    ///
    /// **Text, for #242's reason**, which is `ApiValueSource.keyValues`'
    /// own: a key above 2^53 cannot cross as a number, and the comparison
    /// at resolve time has to agree with the form recorded here.
    var keyValues: [String] {
        keyColumns.map { column in
            guard let cell = cell(column) else { return "" }
            return PaneCell(cell).text
        }
    }
}

/// Fills every hole whose name exactly matches a column of the dropped
/// row, and reports the ones that matched nothing.
///
/// **Exact match, no fuzzy, no proposal** (#192). A hole named `id` never
/// silently takes `booking_id`: a near-miss that guessed would produce a
/// request the operator did not mean, and the aggregate refusal exists so
/// that the miss is *said* rather than papered over.
///
/// **One drop is one action.** Every region is walked — path, every query
/// row's value, every header row's value, and the body — so filling three
/// holes and missing one is one call, one journal line and one report.
///
/// **The drop's own column is discarded; each hole names its own.** The
/// gesture lands on a row, and which cell the pointer happened to be over
/// says nothing about which column a hole wants.
///
/// **The same drop re-binds every binding that does not resolve, and
/// overwrites none that does** (#192). #137 prices a capture's short life
/// at *"the operator re-binds, one click on a row that is on screen"*, and
/// #112 rules that a bound value whose row is gone keeps its origin rather
/// than degrading into a hole. Those two hold together only if the drop
/// repoints a dead binding — otherwise re-binding is *unbind, then drop*,
/// two gestures and two journal lines, and #137's accepted cost is
/// understated by half.
///
/// **Deadness is the resolver's answer, not a second opinion.**
/// `resolvePart` already decides it — a closed pane, a pane that has not
/// re-fetched, no row for the key, an absent column, a NULL cell — and
/// asking it here keeps one definition rather than two that can drift.
/// `sources` is what it needs, and it takes no default: an empty lookup
/// makes every binding unresolved, so a caller that forgot to pass the
/// panes would silently repoint the whole draft.
///
/// **A resolving binding is never touched.** Silently repointing a working
/// binding is the opposite failure and a worse one — the operator sees the
/// value they bound and sends a different row's.
///
/// **A dead binding the dropped row cannot fill is left exactly as it
/// was**, origin and all, rather than cleared. That is #112 in full: what
/// was lost stays visible and nameable in the refusal, and the miss is not
/// reported, because the operator asked to fill holes rather than to
/// account for this binding.
public func apiBind(
    draft: ApiDraft, source: ApiDropSource, holes: [String],
    sources: [String: ApiSourcePane]
) throws -> (ApiDraft, [String]) {
    var matched: [String: ApiBoundValue] = [:]
    var missed: [String] = []

    for hole in holes where matched[hole] == nil && !missed.contains(hole) {
        guard let cell = source.cell(hole) else {
            missed.append(hole)
            continue
        }
        let declaredType = source.declaredType(hole)
        // W17: refused at the drop, not at Send. A binary cell is corrupted before the pane can
        // read it, so binding one only defers the refusal, and the walk saw its origin garbled.
        // **Single-value cells only** (F11): Mongo's lossless binary arrives as a document
        // token, and "arrive corrupted" is the wrong sentence for it (#184); the shape refusal
        // at send names it correctly.
        guard !(cell.isScalar && isBinaryType(declaredType)) else {
            throw ApiActionError.binaryColumn(
                action: "api_bind", column: hole, declaredType: declaredType)
        }
        matched[hole] = ApiBoundValue(
            name: hole,
            binding: source.editable
                ? .live
                : .captured(ApiHeldCell(token: cell, declaredType: declaredType)),
            source: ApiValueSource(
                pane: source.pane, table: source.table, keyColumns: source.keyColumns,
                keyValues: source.keyValues, column: hole, declaredType: declaredType,
                generation: source.generation))
    }

    /// The binding a dead part should be repointed to, or `nil` when the
    /// dropped row has no column for it.
    func repointed(_ bound: ApiBoundValue) -> ApiBoundValue? {
        guard let cell = source.cell(bound.name) else { return nil }
        let declaredType = source.declaredType(bound.name)
        return ApiBoundValue(
            name: bound.name,
            binding: source.editable
                ? .live
                : .captured(ApiHeldCell(token: cell, declaredType: declaredType)),
            source: ApiValueSource(
                pane: source.pane, table: source.table, keyColumns: source.keyColumns,
                keyValues: source.keyValues, column: bound.name, declaredType: declaredType,
                generation: source.generation),
            // **Carried, not defaulted.** A repoint replaces where a value
            // comes from and nothing else; losing this would turn a
            // fill-first binding into a named hole, and a later unbind
            // would then insert a hole the operator never authored instead
            // of removing the part.
            namedHole: bound.namedHole)
    }

    func fill(_ parts: [ApiPart]) -> [ApiPart] {
        parts.map { part in
            switch part {
            case .slot(let name):
                guard let value = matched[name] else { return part }
                return .bound(value)
            case .bound(let existing):
                guard !resolvePart(part, sources: sources).isResolved,
                    let value = repointed(existing)
                else { return part }
                return .bound(value)
            case .literal:
                return part
            }
        }
    }

    var filled = draft
    filled.path = fill(draft.path)
    filled.query = draft.query.map { ApiQueryRow(name: $0.name, value: fill($0.value)) }
    filled.headers = draft.headers.map { ApiHeaderRow(name: $0.name, value: fill($0.value)) }
    filled.body = fill(draft.body)
    return (filled, missed)
}

/// Returns one bound position to what it was before the drop.
///
/// **A named hole comes back as a hole; a fill-first binding is removed**
/// (#192). The two are not the same gesture reversed — a binding that
/// filled a `.slot` has a name to return to, and one made by dropping on
/// an empty position has nothing there to return to. `ApiBoundValue.name`
/// cannot tell them apart, because a fill-first binding carries the column
/// it reads as its name; only the gesture knew, which is why
/// `ApiBoundValue.namedHole` records it at bind time.
///
/// **It refuses rather than no-opping.** An index the region does not
/// hold, or a position holding a literal or a hole, means the pane and the
/// draft disagree about the shape of the region — and the safe reading of
/// a disagreement is not to guess which is right and remove something. A
/// silent success would leave the operator's gesture unexplained and the
/// draft not as they see it.
/// - Parameter row: which row of a repeated query or header name to act
///   on, counting from zero among the rows of that name. `nil` means the
///   first, which is the only behaviour available before this parameter
///   existed — and `apiHeaderRowsSorted` is explicit that two rows may
///   share a name and are refused only at send, so without it the second
///   `accept` row could never be unbound and the first would be edited in
///   its place.
public func apiUnbind(
    draft: ApiDraft, region: ApiRegion, index: Int, row: Int? = nil
) throws -> ApiDraft {
    func unbound(_ parts: [ApiPart]) throws -> [ApiPart] {
        guard parts.indices.contains(index) else {
            throw ApiActionError.unbindOutOfRange(
                action: "api_unbind", region: region.label, index: index)
        }
        guard case .bound(let value) = parts[index] else {
            throw ApiActionError.unbindNotABinding(
                action: "api_unbind", region: region.label, index: index)
        }
        var parts = parts
        if value.namedHole {
            parts[index] = .slot(value.name)
        } else {
            parts.remove(at: index)
        }
        return parts
    }

    var draft = draft
    switch region {
    case .path:
        draft.path = try unbound(draft.path)
    case .body:
        draft.body = try unbound(draft.body)
    case .query(let name):
        let matching = draft.query.indices.filter { draft.query[$0].name == name }
        guard let target = apiNamedRow(matching, row: row) else {
            throw ApiActionError.unbindNoSuchRegion(action: "api_unbind", region: region.label)
        }
        draft.query[target] = ApiQueryRow(
            name: draft.query[target].name, value: try unbound(draft.query[target].value))
    case .header(let name):
        let matching = draft.headers.indices.filter { draft.headers[$0].name == name }
        guard let target = apiNamedRow(matching, row: row) else {
            throw ApiActionError.unbindNoSuchRegion(action: "api_unbind", region: region.label)
        }
        draft.headers[target] = ApiHeaderRow(
            name: draft.headers[target].name, value: try unbound(draft.headers[target].value))
    }
    return draft
}

// MARK: - The surface

/// Which action the pane's Send control dispatches, and what it says.
///
/// **A ruling rather than an expression in the view**, on
/// `apiChooserIsEnabled`'s precedent: `WakilApp` has no test target, and
/// this decides which of two differently-priced actions a press reaches.
/// Getting it wrong is not cosmetic — a `GET` routed to `api_send` is a
/// read priced at the gate, and a `POST` routed to `api_request` is a
/// write that never reaches one, which is exactly the inversion Decision
/// 25 exists to prevent.
///
/// **An unrecognised method takes the gated path.** The worst case of
/// that default is a refusal the operator can read, because `api_send`
/// names a read method rather than sending it; the worst case of the
/// other default is an unpriced write.
///
/// **The label promises nothing about the price.** Whether a send costs a
/// typed confirmation depends on the environment, which the gate reads
/// and the button does not — a button that said "Send (confirm)" would be
/// wrong in staging and redundant where the plane already asks.
///
/// **While a send is in flight, Send becomes Cancel and counts** (W14). `api.send` keeps its
/// identifier; what changes is the action a press reaches and the label.
public func apiSendControl(
    method: String, sending: ApiSending? = nil, now: Date = Date()
) -> (action: String, label: String) {
    if let sending {
        let elapsed = max(0, Int(now.timeIntervalSince(sending.since) * 1000))
        return (action: "api_cancel", label: "Cancel · \(apiSeconds(elapsed))")
    }
    return (action: apiIsReadMethod(method) ? "api_request" : "api_send", label: "Send")
}

/// What pressing Send does (W14; preflight F9): send the draft, dispatch the call `apiSendControl`
/// names while a send is in flight, or nothing.
public enum ApiSendPress: Equatable, Sendable {
    /// Flush the held fields and send (`apiSendPlan`).
    case send
    /// One call, flushing nothing: Cancel ends a send, it does not read the draft.
    case dispatch(name: String, params: JSONValue)
    /// ⌘Return while a send is in flight.
    case nothing
}

/// **The ruling for Send's press, and ⌘Return's.** At rest both send. In flight the button
/// presses `apiSendControl`'s action, `api_cancel`, on this pane; **⌘Return never cancels**,
/// because a key the operator presses to send must not end the send it just started.
public func apiSendPress(
    pane: String, sending: ApiSending?, fromKeyboard: Bool = false
) -> ApiSendPress {
    guard let sending else { return .send }
    if fromKeyboard { return .nothing }
    let control = apiSendControl(method: sending.method, sending: sending)
    return .dispatch(name: control.action, params: .object(["pane": .string(pane)]))
}

/// Runs one send as a cancellable task, the pane marked in flight for its whole length (W14).
/// **A second send is refused**, not queued, so two replies can never race for one response.
/// Cancelling cancels the task, `MCPClient` tells `wakil-http`, and `apiRequest` answers the
/// cancelled outcome. A reply that beat the cancel is kept (Review Focus 3).
///
/// **The send runs in its own `Task`, not the dispatch's.** The canceller has to reach it from
/// another dispatch — the operator's Cancel or the agent's `api_cancel` — and that call cannot
/// cancel the task a different caller is awaiting in.
func apiSendInFlight(
    paneId: String, action: String, method: String, panes: PaneStore,
    send: @escaping @Sendable () async -> ApiRequestOutcome
) async throws -> ApiRequestOutcome {
    guard let token = await panes.beginApiSend(paneId: paneId, method: method, at: Date()) else {
        throw ApiActionError.sendInFlight(action: action)
    }
    let task = Task { await send() }
    await panes.armApiSend(paneId: paneId, token: token) { task.cancel() }
    // A dispatch that is itself cancelled (an agent's `tools/call` withdrawn) still cancels its
    // send, as it did while the send ran inline.
    let outcome = await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
    await panes.finishApiSend(paneId: paneId, token: token, outcome: outcome)
    return outcome
}

/// The `api_set_request` params one typed field commits.
///
/// **One region, and every other absent.** `api_set_request` takes every
/// region optional with absent meaning unchanged — so a path field writes
/// `path` alone. An empty array would CLEAR a region, which is not what
/// typing in a different one means, and that distinction is the whole
/// reason the action has three states per region rather than two.
///
/// **A typed value is one LITERAL part, and never a hole.** #112 rules
/// that a binding is made by a gesture and never by writing one, and
/// there is no template syntax anywhere in Wakil: `{{id}}` typed into the
/// path is literal text. This is the one surface where somebody might
/// expect otherwise, so it is stated here rather than left to the parts
/// model to imply.
public func apiFieldWrite(field: ApiDraftField, text: String, pane: String) -> JSONValue {
    var params: [String: JSONValue] = ["pane": .string(pane)]
    switch field {
    case .method:
        params["method"] = .string(text)
    case .path:
        params["path"] = .array(apiLiteralParts(text))
    case .body:
        params["body"] = .array(apiLiteralParts(text))
    case .contentType:
        // #116: free text, and the one field on the draft that admits no
        // parts.
        params["contentType"] = .string(text)
    case .query, .header:
        // A row belongs to a region written entire — `apiRowWrite` is
        // what carries its neighbours.
        break
    }
    return .object(params)
}

/// The `api_set_request` params one typed ROW commits.
///
/// **Kept for the add-row path; no control uses it yet.** The split field writes a row through
/// `apiHeldWrite` (10a), and no control adds a row — which is the case this one exists
/// for: a row the draft does not hold yet is appended. Its tests hold that behaviour.
///
/// **The whole region, carrying the rows it did not touch.** `query` and
/// `headers` are written entire (#190), so a write built from the edited
/// row alone would clear every other row in that region. A row the draft
/// does not hold yet is appended rather than lost.
public func apiRowWrite(
    draft: ApiDraft, field: ApiDraftField, text: String, pane: String
) -> JSONValue {
    var params: [String: JSONValue] = ["pane": .string(pane)]
    func rowsJSON(_ rows: [(name: String, value: [ApiPart])], editing: String) -> JSONValue {
        var written = rows
        if !written.contains(where: { $0.name == editing }) {
            written.append((name: editing, value: []))
        }
        return .array(written.map { row in
            .object([
                "name": .string(row.name),
                "value": .array(
                    row.name == editing
                        ? apiLiteralParts(text)
                        : row.value.map { apiPartJSON($0, sources: [:]) }),
            ])
        })
    }
    switch field {
    case .query(let name):
        params["query"] = rowsJSON(
            draft.query.map { (name: $0.name, value: $0.value) }, editing: name)
    case .header(let name):
        params["headers"] = rowsJSON(
            draft.headers.map { (name: $0.name, value: $0.value) }, editing: name)
    default:
        return apiFieldWrite(field: field, text: text, pane: pane)
    }
    return .object(params)
}

/// The parts with every empty literal dropped: an emptied box is no part.
func apiDroppingEmptyLiterals(_ parts: [ApiPart]) -> [ApiPart] {
    parts.filter { part in
        if case .literal(let text) = part { return !text.isEmpty }
        return true
    }
}

/// A region write with one row's value replaced, the rest carried as-is.
///
/// **Shares `apiRowWrite`'s shape** — every row present, the edited one
/// swapped — but takes the new value already computed rather than a typed
/// string, since a held field's write (`apiHeldWrite`) carries a part list
/// and not text.
///
/// **Only the `row`-th row of that name is replaced**, never every row carrying it: two rows
/// that share a name are two rows (#158), and a write to one is not a write to both.
func apiPartsRegionWrite(
    _ rows: [(name: String, value: [ApiPart])], editing: String, row target: Int,
    written: [JSONValue]
) -> JSONValue {
    var seen = 0
    return .array(rows.map { row in
        var replaced = false
        if row.name == editing {
            replaced = seen == target
            seen += 1
        }
        return .object([
            "name": .string(row.name),
            "value": replaced
                ? .array(written)
                : .array(row.value.map { apiPartJSON($0, sources: [:]) }),
        ])
    })
}

/// The parts a field holds in the snapshot — path, body, or one row's value.
///
/// **`row` picks among rows sharing a name**, counting from zero among the rows of that exact
/// name (`apiRowOccurrence`); a row past the last is nobody's and holds nothing. The path and
/// the body are one field each and have only row 0.
public func apiFieldParts(
    _ request: ApiRequestSnapshot, _ field: ApiDraftField, row: Int = 0
) -> [ApiPart] {
    let rows = apiFieldRows(request, field)
    return rows.indices.contains(row) ? rows[row] : []
}

/// Every row's parts a field names, in the snapshot's order: one for the path and the body,
/// every row of that exact name for a query or header field, none for a partless field.
///
/// **A header row counts only when it is the operator's own and holds a value** — the rows
/// the split field draws and `apiDraftForWrite` writes, so the three agree on which is which.
func apiFieldRows(_ request: ApiRequestSnapshot, _ field: ApiDraftField) -> [[ApiPart]] {
    switch field {
    case .path: return [request.path]
    case .body: return [request.body]
    case .query(let name): return request.query.filter { $0.name == name }.map(\.value)
    case .header(let name):
        return request.headers.compactMap { row in
            row.name == name && row.isEditable ? row.value : nil
        }
    case .method, .contentType: return []
    }
}

/// Which of the rows sharing its name the region's row at `index` is — the `row` every
/// same-named-row function here takes, and `api_unbind`'s.
///
/// **Counts the rows of that exact name before it**, so the first is 0 and an ordinary row,
/// whose name nothing else carries, is always 0. For headers only the operator's own rows
/// count (`apiFieldRows`). `index` is the row's position in the snapshot's region.
public func apiRowOccurrence(
    _ request: ApiRequestSnapshot, _ field: ApiDraftField, at index: Int
) -> Int {
    switch field {
    case .query(let name):
        return request.query.prefix(index).filter { $0.name == name }.count
    case .header(let name):
        return request.headers.prefix(index).filter {
            $0.name == name && $0.isEditable && $0.value != nil
        }.count
    case .path, .body, .method, .contentType:
        return 0
    }
}

/// One split field's row: which field, and which of the rows sharing its name. The key the
/// view keeps a row's box text under, so two same-named rows never share a box.
public struct ApiFieldRow: Sendable, Hashable {
    public let field: ApiDraftField
    public let row: Int

    public init(_ field: ApiDraftField, row: Int = 0) {
        self.field = field
        self.row = row
    }
}

/// The identifier a split field's controls are built on, without the `api.` surface.
///
/// **Row 0 is the shipped identifier, unchanged** — `path`, `body`, `query.<name>`,
/// `header.<name>` — so every shipped check still types where it typed. **A later row of the
/// same name is `query[<row>].<name>` / `header[<row>].<name>`**: every row-0 key starts
/// `query.` or `header.` and every later one `query[` or `header[`, so the two families are
/// disjoint whatever a name contains, and inside the bracketed one the row is the digits up to
/// the first `]`, so `(row, name)` reads back unambiguously. Two same-named rows therefore
/// never carry one identifier, which the harness refuses to resolve.
public func apiFieldKey(_ field: ApiDraftField, row: Int) -> String {
    switch field {
    case .path: return "path"
    case .body: return "body"
    case .query(let name): return row == 0 ? "query.\(name)" : "query[\(row)].\(name)"
    case .header(let name): return row == 0 ? "header.\(name)" : "header[\(row)].\(name)"
    case .method: return "method"
    case .contentType: return "contentType"
    }
}

/// A typed string as parts: one literal, or none when it is empty.
///
/// **Empty is an empty region rather than a part holding "".** A region
/// of one empty literal and a cleared region are different wire states,
/// and the operator clearing a field means the second.
func apiLiteralParts(_ text: String) -> [JSONValue] {
    text.isEmpty ? [] : [.object(["literal": .string(text)])]
}

/// The params the Send control dispatches with.
///
/// **`api_send` REQUIRES a statement, and a press that omitted one sent
/// nothing.** The first version of the Send control passed `pane` alone;
/// `api_request` was content with that, so a `GET` worked and every
/// mutation was refused by `sendNeedsAStatement` — the button looked
/// live, the pane never changed, and nothing said why. The e2e parity
/// step found it, which is what a UI channel is for: no unit test in
/// `WakilKit` presses a button.
///
/// **The operator's statement is composed rather than typed.** They are
/// about to be shown it on the confirmation plane; asking them to write
/// the sentence that will be read back to them is asking them to confirm
/// their own paraphrase. `apiSendStatement` names the request and the
/// body's shape, which is what the plane needs.
public func apiSendParams(
    draft: ApiRequestSnapshot, pane: String, origin: String?
) -> JSONValue {
    var params: [String: JSONValue] = ["pane": .string(pane)]
    guard !apiIsReadMethod(draft.method) else { return .object(params) }
    var asDraft = ApiDraft.empty
    asDraft.method = draft.method
    asDraft.path = draft.path
    asDraft.query = draft.query
    asDraft.body = draft.body
    asDraft.contentType = apiContentTypeText(draft)
    params["statement"] = .string(apiSendStatement(draft: asDraft, origin: origin))
    return .object(params)
}

/// Whether a row's value holds no bound value of its own.
///
/// **A bound value is unmade by `api_unbind` and never by writing over
/// it** (#112). A binding pins a declared type and a generation recorded
/// at the moment of the drop, which a caller cannot author. Since W16 the
/// text beside it stays typable (every write carries the chip back), so
/// this rules only what acts on the row as a whole: its `×`
/// (`apiRowDrawsRemove`), which waits for the chip's own unbind.
///
/// A hole does not count: it carries nothing, and removing it is how an
/// operator abandons one they no longer want.
public func apiRowIsTypable(_ parts: [ApiPart]) -> Bool {
    parts.allSatisfy { part in
        if case .bound = part { return false }
        return true
    }
}

/// Whether a field can be typed into. **Always, since W16** (Amendment 9c): a bound value
/// locks only itself. It is drawn as a chip, which is not a box, and every write carries it
/// back (`ApiHeldBindings` admits it). Amendment 2's region lock is superseded. Kept as the
/// one place the rule is stated, because the view and `ApiSaveAsTyped` ask it.
public func apiFieldIsTypable(_ request: ApiRequestSnapshot, _ field: ApiDraftField) -> Bool {
    true
}

/// What the name box says when `+ hole` is committed blank (spec §1).
///
/// **Said on screen, because nothing is dispatched to say it.** A blank name inserts no hole
/// (`apiHoleNameRefused`), so no action runs and no refusal comes back — this line is the only
/// answer the operator's Return gets.
public let apiHoleNameRefusal = "a hole needs a name"

/// The `region` a field is to `api_unbind` — the name its handler's `apiRegion(named:row:)`
/// reads back.
///
/// **`nil` for the two fields that hold no parts**, because there is no position in them to
/// unbind and naming one would be a refusal waiting to be sent.
public func apiRegionName(_ field: ApiDraftField) -> String? {
    switch field {
    case .path: return "path"
    case .body: return "body"
    case .query: return "query"
    case .header: return "header"
    case .method, .contentType: return nil
    }
}

/// What a bound chip's `×` dispatches (spec §3).
///
/// **A row's region carries the row's name**, because `api_unbind` refuses a query or header
/// region without one (`unbindNoRowName`) rather than guessing which row was meant. **A later
/// row of a shared name carries `row` too** (Important 2): `api_unbind` without one acts on the
/// first, which is not the row whose `×` was pressed. Row 0 sends none, as it always has.
public func apiUnbindParams(
    field: ApiDraftField, index: Int, pane: String, row: Int = 0
) -> JSONValue? {
    guard let region = apiRegionName(field) else { return nil }
    var params: [String: JSONValue] = [
        "pane": .string(pane), "region": .string(region), "index": .integer(Int64(index)),
    ]
    switch field {
    case .query(let name), .header(let name):
        params["name"] = .string(name)
        if row > 0 { params["row"] = .integer(Int64(row)) }
    default: break
    }
    return .object(params)
}

/// The draft a region write carries its untouched neighbours from.
///
/// **Built from the SNAPSHOT, which is what the operator is looking at.**
/// `apiRowWrite` writes a region entire, so it needs every row — and the
/// rows it must not send are the entry's own: `api_set_request` refuses
/// `authorization` by name, and a write carrying it would be refused
/// whole, taking the operator's edit down with a refusal about a row they
/// never touched.
///
/// **Only `.authored` rows, never `.derived`** (fix round 1, Critical).
/// `content-type` is `rowClass: .derived` and `isEditable` (`rowClass !=
/// .supplied`) is true for it — so once the operator has named a content
/// type, `row.value` is non-nil too, and a check of `isEditable` alone let
/// it through as if it were an operator's own row: `apiRowAdd` and
/// `apiRowRemoveWrite` would write it a second time as a header, and
/// a held header's write (`apiHeldWrite`) would carry it along with every
/// other header write. The draft's own `contentType` is the one place
/// that row lives; a region write is never where it is set.
public func apiDraftForWrite(_ request: ApiRequestSnapshot) -> ApiDraft {
    var draft = ApiDraft.empty
    draft.method = request.method
    draft.path = request.path
    draft.query = request.query
    draft.headers = request.headers.compactMap { row in
        guard row.rowClass == .authored, let value = row.value else { return nil }
        return ApiHeaderRow(name: row.name, value: value)
    }
    draft.body = request.body
    return draft
}

// MARK: - The drop's rulings

/// One database row, on its way from the grid to an api pane — the drag
/// gesture's own payload, carried while the drop is still in flight.
///
/// **`Codable`, not `Transferable`.** `Transferable` needs `UniformTypeIdentifiers`
/// and `CoreTransferable`, which belong to the app target that draws the
/// drag; this type is the fact the drag carries, and WakilKit can state
/// and test that fact without either import.
///
/// **`cells`, not `PaneRow` itself.** A drop lands after the grid may have
/// re-sorted, re-fetched, or deleted the row out from under the gesture —
/// `apiDropRow` exists to tell the two cases apart, and it needs the
/// values as they were AT PICKUP to compare against the values the index
/// now holds. Carrying `PaneRow` would carry `PaneCell.text` twice, once
/// live and once frozen, with no name to tell them apart by.
public struct ApiDragPayload: Sendable, Equatable, Codable {
    public let pane: String
    public let index: Int
    /// `PaneCell.text`, positionally aligned with the row's columns —
    /// `nil` where the cell was `isNull`, so a real NULL and an empty
    /// string picked up together do not compare equal to each other.
    public let cells: [String?]

    public init(pane: String, row: PaneRow) {
        self.pane = pane
        self.index = row.id
        self.cells = row.cells.map { $0.isNull ? nil : $0.text }
    }
}

/// Whether the row `picked` names is still, right now, the row it was
/// picked up from — and if so, its index in `current`.
///
/// **Position AND content, not either alone.** A drag can outlive a
/// re-sort, and `current`'s row at `picked.index` may by then be a
/// different row entirely; comparing by index alone would bind whatever
/// row happens to have slid into that slot. Comparing by content alone
/// would accept a row that scrolled to a new index, which is not the
/// mistake this guards against — `read_pane`'s own indices are positional
/// (`PaneContents.swift`), so a drop that moved with its row is exactly as
/// valid as one that never moved.
///
/// `nil` is the one answer for both an index the grid no longer has and a
/// row the grid no longer shows there — `apiDropMovedRefusal` is the one
/// sentence a caller draws for either.
public func apiDropRow(_ picked: ApiDragPayload, current: [PaneRow]) -> Int? {
    guard current.indices.contains(picked.index) else { return nil }
    let now = current[picked.index]
    let cells = now.cells.map { $0.isNull ? nil : $0.text }
    return cells == picked.cells ? picked.index : nil
}

/// Said when a drop's row has moved out from under it between pickup and
/// release (`apiDropRow` returning `nil`) — one sentence, so the refusal
/// reads the same wherever the drop lands.
public let apiDropMovedRefusal = "the grid changed while the row was being dragged — drop it again"

/// What `api_bind` decided, on its way to the caller: a result object it
/// returned, or a refusal it threw before ever calling the tool.
public enum ApiBindOutcome: Sendable, Equatable {
    case result(JSONValue)
    case refused(String)
}

/// The one line a drop leaves behind: what to say, and whether to say it
/// with caution's colour.
public struct ApiBindLine: Sendable, Equatable {
    public let text: String
    public let caution: Bool

    public init(text: String, caution: Bool) {
        self.text = text
        self.caution = caution
    }
}

/// The line a drop whose row moved leaves behind (`apiDropRow` answering `nil`).
///
/// **Caution, not failure**: nothing was dispatched and nothing has gone wrong — the grid
/// changed under the operator's hand, and dropping again is the whole remedy.
public let apiDropMovedLine = ApiBindLine(text: apiDropMovedRefusal, caution: true)

/// Renders `api_bind`'s outcome as the one line the operator reads after
/// letting go.
///
/// **A refusal is drawn in its own words**, unedited — `ApiActionError`
/// already composes the sentence a caller should read, and reformatting
/// it here would be a second author for the same message.
///
/// **`filled`/`rebound` are read through `intValue`, never `case
/// .number`** — `api_bind`'s own handler documents why: its result is
/// built with `.number(Double(...))`, and `JSONValue.init(from:)` would
/// still decode a value that came back off the wire as `.integer` first.
///
/// **Zero filled and zero rebound is the caution line**, regardless of
/// `unmatched` — a drop that changed nothing is the one outcome the
/// operator must not mistake for a quiet success. Otherwise: `Filled N`,
/// then ` · re-bound N` when re-binding happened, then ` · no column for
/// ` the misses, joined by `", "`, when any hole went unfilled.
public func apiBindSummary(_ outcome: ApiBindOutcome) -> ApiBindLine {
    switch outcome {
    case .refused(let message):
        return ApiBindLine(text: message, caution: false)
    case .result(let value):
        guard case .object(let fields) = value else {
            return ApiBindLine(text: "", caution: false)
        }
        let filled = fields["filled"]?.intValue ?? 0
        let rebound = fields["rebound"]?.intValue ?? 0
        let unmatched: [String] = {
            guard case .array(let items)? = fields["unmatched"] else { return [] }
            return items.compactMap { item -> String? in
                guard case .string(let name) = item else { return nil }
                return name
            }
        }()

        guard filled != 0 || rebound != 0 else {
            return ApiBindLine(text: "No hole matches a column of this row", caution: true)
        }
        var text = "Filled \(filled)"
        // Re-walk #6: "Filled 1" said how many and not what, nor from where. The holes by name,
        // the source by its table (the pane, for a join, which names none), and the row as the
        // grid numbers it for a person — one-based.
        let names: [String] = {
            guard case .array(let items)? = fields["filledNames"] else { return [] }
            return items.compactMap { item -> String? in
                guard case .string(let name) = item else { return nil }
                return name
            }
        }()
        if filled != 0, !names.isEmpty {
            text = "Filled " + names.joined(separator: ", ")
        }
        // A drop that only re-bound says that, not "Filled 0" (review minor).
        if filled == 0 { text = "Re-bound \(rebound)" }
        // The table, else the source pane's title (a join names no table), else its id.
        let table: String? = {
            for key in ["table", "sourceTitle", "source"] {
                if case .string(let value)? = fields[key], !value.isEmpty { return value }
            }
            return nil
        }()
        if let table {
            text += " from \(table)"
            if let row = fields["row"]?.intValue { text += " · row \(row + 1)" }
        }
        if rebound != 0, filled != 0 {
            text += " · re-bound \(rebound)"
        }
        if !unmatched.isEmpty {
            text += " · no column for " + unmatched.joined(separator: ", ")
        }
        return ApiBindLine(text: text, caution: false)
    }
}

// MARK: - Amendment 10a: a held field's write, and Send per field

/// What a held field writes (10a): **the field whole**, its holes as `{"slot":}`, a binding as
/// published (W16), and a row's region with every other row carried (`apiPartsRegionWrite`).
/// `parts` are already as written (`apiHeldAsWritten`): this only shapes the params. `nil` for
/// a field that holds no parts (the method, the content type).
///
/// **One field alone, built from the STORED draft's region**: every other row is carried at its
/// stored value. So this is what ONE held field writes (`apiPendingWrite`), never a flush's
/// write. **A flush writes once per region** (`apiFlush`, Task 4 fix round 1): two held rows
/// of one region written one by one each carried the other's stored value and reverted it.
public func apiHeldWrite(
    draft: ApiRequestSnapshot, field: ApiDraftField, parts: [ApiPart], pane: String, row: Int = 0
) -> JSONValue? {
    let written = apiDroppingEmptyLiterals(parts).map { apiPartJSON($0, sources: [:]) }
    var params: [String: JSONValue] = ["pane": .string(pane)]
    switch field {
    case .path:
        params["path"] = .array(written)
    case .body:
        params["body"] = .array(written)
    case .query(let name):
        let rows = apiDraftForWrite(draft).query.map { (name: $0.name, value: $0.value) }
        params["query"] = apiPartsRegionWrite(rows, editing: name, row: row, written: written)
    case .header(let name):
        let rows = apiDraftForWrite(draft).headers.map { (name: $0.name, value: $0.value) }
        params["headers"] = apiPartsRegionWrite(rows, editing: name, row: row, written: written)
    case .method, .contentType:
        return nil
    }
    return .object(params)
}

/// What Send dispatches, in order: every held field's pending write, then the send (9a; B5).
///
/// **B5:** Send committed a typed body (8c) but not a typed path, so the box showed `/test` while
/// the request went to the bare origin. Now every field is flushed first, and the send's params
/// are built from the request the screen shows, so `api_send`'s statement, read back on the
/// confirmation plane, names what will actually leave.
///
/// The plan carries those calls, and from the **same** flush the fields they write (held in
/// `queued` until they complete) and the refusal that left them empty (drawn under the URL, so
/// a refused Send is never silent).
public struct ApiHeldSendPlan {
    public let calls: [(String, JSONValue)]
    public let refusals: [ApiFieldRow: String]
    /// Each held field in `calls`, at the parts it was written with: `queued` until done.
    public let written: ApiHeld
    /// The pane's own refusal, which is no field's: `apiPickAnEntryFirst` for an unpointed pane.
    public var refusal: String? = nil
}

/// Send's plan (10a). **Built at Send's turn on the chain** (Task 9 fix round 4), against the
/// stored draft: `api_send` sends the STORED draft, so a plan built at the press, with a
/// gesture still in flight, put a statement on the confirmation plane naming a request other
/// than the one that left. Every held field's write comes first, then the send, its statement
/// built on the request the screen shows (`apiRequestApplying(_:held:)`, B5), which names no
/// binding its region no longer holds (M7). **Nothing is sent while a write is refused** (F8).
/// A field a gesture took over is that gesture's to write. Unpointed, the fields are still
/// written and only the send is withheld (fix round 1, item 2).
public func apiSendPlan(
    draft: ApiRequestSnapshot, pane: String, held: ApiHeld, queued: ApiHeld = [:],
    unpointed: Bool = false, takenOver: [ApiFieldRow: ApiHeldTakeover] = [:]
) -> ApiHeldSendPlan {
    let control = apiSendControl(method: draft.method)
    let flush = apiFlush(draft, held: held, pane: pane, queued: queued, takenOver: takenOver)
    guard flush.refusals.isEmpty else {
        return ApiHeldSendPlan(calls: [], refusals: flush.refusals, written: [:])
    }
    if unpointed {
        return ApiHeldSendPlan(
            calls: flush.writes, refusals: [:], written: flush.written, refusal: apiPickAnEntryFirst)
    }
    let calls = flush.writes + [(
        control.action,
        apiSendParams(draft: apiRequestApplying(draft, held: held), pane: pane, origin: draft.origin)
    )]
    return ApiHeldSendPlan(calls: calls, refusals: [:], written: flush.written)
}
