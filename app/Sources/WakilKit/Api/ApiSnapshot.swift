import Foundation

/// The **api client pane**'s readable state — `read_pane`'s third arm
/// (#188), and the api kind's `PaneKindSnapshot` (`ApiPaneKind`).
///
/// **Three regions above a flat key set, and the reason is tense.**
/// (*"Region" names two nestings — these three, and the four inside
/// `request` — which is #235's to settle; both spellings are the spec's
/// and are cited across the map, so neither is renamed here.*) A
/// `request` is what is drafted, a `response` is what came back, and
/// `recent` is what has already been done — from this pane and every other api pane of its
/// project and environment (W15). Flattened into one object
/// those three mix future, present and past, and the union's
/// always-present-key rule cannot hold across all three at once: a pane
/// with no response yet would have to publish a `status` and a `body` it
/// does not have. Nested, each region answers for itself.
///
/// **`failure` is ALWAYS null for this kind**, and that is a statement
/// about what `failure` means rather than an omission. It means *this pane
/// could not produce what it was asked for*. A refused send is the pane
/// working correctly — the refusal is the answer — and a send whose fate
/// is unknown is a fact about the world, not about the pane. Both belong
/// in `response.state`, which is why this type has no failure of its own
/// to carry.
///
/// **`read_pane` redacts nothing, because nothing redactable reaches it.**
/// The credential resolves inside Go, at the moment a request leaves, and
/// never enters the app at all; this pane names no ref, and `credentialed`
/// is a boolean derived from whether the entry has one. Stated
/// structurally rather than as a masking rule on purpose: a masking rule
/// over a value the app never holds is theatre, and theatre invites a
/// later reader to plumb the credential in so that there is something to
/// mask.
public struct ApiSnapshot: Sendable, Equatable {
    /// The api entry this pane's draft targets, by NAME — never an
    /// origin. The name is what survives an environment switch, which is
    /// the whole point of naming entries at all.
    ///
    /// Empty for a pane opened where the environment declares no entries,
    /// which is a configuration to fix rather than a failure of the pane.
    public let entry: String
    /// The active environment at the moment this pane was opened.
    public let environment: String
    /// Whether a credential is CONFIGURED for this entry. It means that
    /// and only that — never that the credential is valid, current or
    /// sufficient. `list_apis` publishes the same fact under
    /// `authenticated`, derived from the entry's `authRef`, and a request
    /// may still come back 401. **One fact under two agent-facing
    /// names**, which is the other half of #235.
    public let credentialed: Bool
    public let request: ApiRequestSnapshot
    public let response: ApiResponseSnapshot
    /// The api entries the active environment declares, for the chooser.
    ///
    /// **On the SNAPSHOT rather than on `WindowModel`, and the first
    /// version had it on the model.** The model only learns an action's
    /// result when the OPERATOR dispatches it; a pane the agent opened
    /// left the list empty, so the chooser was disabled in exactly the
    /// case it exists for. The pane store knows, whoever asked — so the
    /// snapshot is the one answer, the way every other thing this pane
    /// draws already is.
    public let entries: [String]
    /// What has been sent from every api pane of this project in this environment — one list
    /// they share (W15), newest first, capped, dead with the session. One row per send with an
    /// outcome.
    public let recent: [ApiRecentRow]
    /// Whether `recent` has been trimmed to its cap. A short history and
    /// a trimmed one must never look alike, which is the rule
    /// `blocksTruncated` and `Rows.Truncated` already carry.
    public let recentTruncated: Bool
    /// The send in flight, or `nil` (W14). **One per pane**: a second send is refused rather
    /// than queued, so two replies can never race for one response. While it is set, Send reads
    /// `Cancel · N s` and `read_pane` publishes `sending: true`.
    public let sending: ApiSending?
    /// The Bound list's rows with their current values (W18), computed at snapshot from the
    /// panes on screen. Screen-only.
    public let bound: [ApiStripRow]
    /// The line the last cURL fill left on this pane (Amendment 11), or `nil`. **Pane state, so
    /// an agent's fill shows the same line the operator's paste does.** Screen-only: `read_pane`
    /// does not publish it.
    public let fillLine: String?
    /// Whether **Undo** is offered: the draft a fill replaced is still kept. Screen-only.
    public let fillUndoable: Bool

    public static let empty = ApiSnapshot(
        entry: "", environment: "", credentialed: false,
        request: .empty, response: .none, recent: [], recentTruncated: false)

    public init(
        entry: String, environment: String, credentialed: Bool,
        request: ApiRequestSnapshot, response: ApiResponseSnapshot,
        entries: [String] = [], recent: [ApiRecentRow], recentTruncated: Bool,
        sending: ApiSending? = nil, bound: [ApiStripRow] = [],
        fillLine: String? = nil, fillUndoable: Bool = false
    ) {
        self.entry = entry
        self.environment = environment
        self.credentialed = credentialed
        self.request = request
        self.response = response
        self.entries = entries
        self.recent = recent
        self.recentTruncated = recentTruncated
        self.sending = sending
        self.bound = bound
        self.fillLine = fillLine
        self.fillUndoable = fillUndoable
    }
}

/// A send in flight on an api pane (W14): when it left, and with which method — the method
/// decides what a cancel will mean, because a cancelled mutation may still have landed.
public struct ApiSending: Sendable, Equatable {
    public let since: Date
    public let method: String

    public init(since: Date, method: String) {
        self.since = since
        self.method = method
    }
}

/// A READ that was cancelled in flight (W14). It changed nothing, so it is plainly cancelled —
/// no status, because nothing came back. A cancelled mutation is never this: it is
/// `ApiResponseSnapshot.unknown`, because the server may already have it.
public struct ApiCancelled: Sendable, Equatable {
    /// How long the send had waited when it was cancelled.
    public let waitedMs: Int
    /// The environment the cancelled send ran against.
    public let environment: String

    public init(waitedMs: Int, environment: String) {
        self.waitedMs = waitedMs
        self.environment = environment
    }
}

/// The request being drafted — the pane's future tense.
///
/// **The four regions are in wire order — path, query, headers, body —**
/// here, in the JSON, and on screen, so that the surface reads in the
/// order the bytes leave.
///
/// **They are TYPED parts as of #190**, where #188 shipped them as
/// `[JSONValue]` and said why: it opened a pane and drew it, with no way
/// to put anything in a region at all, so typing a part would have been
/// that ticket inventing the shape #189 and #190 were charted to rule.
/// Both have ruled, so the placeholder is spent — and the typed form is
/// what lets the surface draw a hole without decoding the JSON it was just
/// encoded into.
///
/// **There is deliberately no `resolvedUrl`.** A draft is unresolved
/// parts; publishing what it WOULD send is a prediction, and a prediction
/// beside a `response.sentUrl` that is a frozen record would be two URLs
/// of different kinds under one pane.
public struct ApiRequestSnapshot: Sendable, Equatable {
    /// The method the draft would be sent with. `GET` for a fresh draft:
    /// the read verb is the safe default, and it is the one the pane can
    /// send without the window's write marker.
    public let method: String
    /// The entry's own resolved base URL, or `nil` when the entry does
    /// not resolve to one — no active project, no environment, no such
    /// entry, or an entry with no `baseUrl` configured. **Null here is a
    /// failure visible before any send**, which is why the pane resolves
    /// at open time rather than at send time.
    ///
    /// **What null does NOT cover, stated so nobody infers it.** A
    /// `baseUrl` that is present but unusable — cleartext `http://`,
    /// userinfo, a query string — publishes a non-null origin here and
    /// is refused at SEND time by `NormalizeHTTPBase`. Running that gate
    /// here too would be a second copy of it in a second language, free
    /// to disagree with the one that actually decides, and the one that
    /// decides is the one the request goes through.
    public let origin: String?
    public let path: [ApiPart]
    public let query: [ApiQueryRow]
    /// **The whole header region, all three classes** (#158) — what the
    /// operator authored, the one the entry supplies, and the one Wakil
    /// derives, name-sorted with Wakil's own last.
    ///
    /// **One list for both readers.** The surface draws every row;
    /// `ApiPaneKind.readPane` publishes the ones whose value the app holds,
    /// which drops `authorization` structurally rather than by a masking
    /// rule. Two lists would be two orderings, free to disagree about the
    /// contract #158 fixed.
    ///
    /// **So the published rows are a SUBSEQUENCE of the drawn ones, not a
    /// copy of them** — the order is identical and the membership is not,
    /// which is #118 ruling 5 rather than a gap in #158's. The one row that
    /// differs is `authorization`, and `credentialed` is what carries it
    /// instead; a `content-type` the draft has not named is the other, and
    /// it is absent for the same reason — the app holds no value to
    /// publish, and predicting the send tool's default would be a second
    /// answer to a question one process already answers.
    public let headers: [ApiHeaderRegionRow]
    public let body: [ApiPart]

    public static let empty = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [],
        // Not `[]`: a pane that has never been written to still has
        // Wakil's own `content-type` row, drawn and unset. The region is
        // always present, with its add affordance, even at zero of the
        // operator's rows — one that vanishes when empty is one the
        // operator cannot find in order to put the first row in it.
        headers: apiWakilHeaderRows(entry: "", contentType: "", credentialed: false),
        body: [])

    public init(
        method: String, origin: String?, path: [ApiPart], query: [ApiQueryRow],
        headers: [ApiHeaderRegionRow], body: [ApiPart]
    ) {
        self.method = method
        self.origin = origin
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// What came back — the pane's present tense, and **a second
/// discriminator**.
///
/// `state` decodes this object exactly as `kind` decodes the pane one
/// level up, and it narrows the always-present-key rule a second time,
/// deliberately: a refusal has no status to report and must not publish a
/// null one, an in-flight send has no body, and `none` has no keys at all.
/// Absence is load-bearing here, and unlike `editable`'s omission — the
/// encoder's first carve-out, which a reader has to infer — this one is
/// announced by the discriminator itself.
///
/// **One case today.** #188 ships a pane that has never sent anything;
/// `inFlight`, `ok`, `transport`, `unknown`, `refused` and `cleared` are
/// the sending tickets' to add, each with the keys the spec fixes for it.
/// The discriminator is published now so that every reader written against
/// this pane reads `state` first, from the first day, rather than learning
/// to read a flat object and being corrected later.
public enum ApiResponseSnapshot: Sendable, Equatable {
    /// Nothing has been sent. **A pane that has sent nothing is not a pane
    /// that failed**, and this says so rather than drawing an empty `ok`.
    case none
    /// A reply came back. The only state that carries one.
    case ok(ApiResponseOK)
    /// The request left, or tried to, and the transport failed.
    case transport(ApiTransportFailure)
    /// **Neither a refusal nor a failure.** The send may have reached the
    /// server and the reply may have been lost; nothing here can tell.
    /// Recording it as either would be stating something unknown.
    case unknown(ApiFateUnknown)
    /// The draft could not be resolved, so nothing was sent. **A refusal
    /// is not a response** — see `status`.
    case refusal(ApiSendRefusal)
    /// The environment switched, so the reply on screen no longer
    /// describes the environment the pane is in. The draft is kept.
    case cleared(environment: String)
    /// A read was cancelled in flight (W14). A cancelled mutation is `unknown` instead.
    case cancelled(ApiCancelled)

    /// The wire value of the discriminator.
    public var state: String {
        switch self {
        case .none: return "none"
        case .ok: return "ok"
        case .transport: return "transport"
        case .unknown: return "unknown"
        case .refusal: return "refusal"
        case .cleared: return "cleared"
        case .cancelled: return "cancelled"
        }
    }

    /// The reply's status code, and `nil` in every other state.
    ///
    /// **A refusal has no status because nothing was sent, and a
    /// transport failure has none because nothing came back.** Both are
    /// structural here rather than conventional: the fields live on the
    /// cases that may carry them, so a refusal that reported a status
    /// would not compile. That is the whole reason this is an enum with
    /// associated values rather than one struct of optionals.
    public var status: Int? {
        guard case .ok(let reply) = self else { return nil }
        return reply.status
    }

    /// How long the send took, and `nil` in every other state. A refusal
    /// took no time because it never went.
    public var durationMs: Int? {
        guard case .ok(let reply) = self else { return nil }
        return reply.durationMs
    }

    /// How many bytes came back, and `nil` in every other state.
    public var byteCount: Int? {
        guard case .ok(let reply) = self else { return nil }
        return reply.byteCount
    }

    /// The environment the record ran against, for every state that ran
    /// against one. **Never inferred from the pane's current
    /// environment** — that is the point of carrying it (spec story 15).
    public var environment: String? {
        switch self {
        case .none, .refusal: return nil
        case .ok(let reply): return reply.environment
        case .transport(let failure): return failure.environment
        case .unknown(let record): return record.environment
        case .cleared(let environment): return environment
        case .cancelled(let cancelled): return cancelled.environment
        }
    }
}

/// One row of the pane's past tense: a send that had an outcome.
///
/// **Rows, never bodies** (#195). The near neighbour is the terminal
/// pane's block history — ephemeral and capped — rather than the db grid,
/// which persists and pages. A strip holding bodies would be a log of
/// every payload the pane ever received, in memory, on a surface that
/// cannot search them.
///
/// **It carries the environment it RAN AGAINST**, never the pane's
/// current one, so a staging record and a production record stay
/// distinguishable after a switch (spec story 15).
///
/// **`status` is optional, and that is the same rule the response states
/// carry**: a transport failure and a fate-unknown have no status,
/// because nothing came back, and inventing a zero would draw a code the
/// server never sent.
public struct ApiRecentRow: Sendable, Equatable, Identifiable {
    /// Stable for the life of the session, so `api_reopen` can name a row
    /// rather than an index — a strip that is newest-first renumbers
    /// every row on every send.
    public let id: String
    public let method: String
    public let entry: String
    public let environment: String
    /// The path as the draft reads it — `<name>` for every bound value.
    /// **Not the resolved path**; that is `sentUrl`'s.
    public let path: String
    /// The URL that actually left, when there was a reply to prove one
    /// did. `nil` for a transport failure or a fate-unknown, because
    /// neither can say what reached the server.
    public let sentUrl: String?
    public let status: Int?
    public let durationMs: Int?
    /// The draft this send was made from, kept so `api_reopen` can put it
    /// back without re-deriving it from a rendered string.
    public let draft: ApiDraft
    /// Whether this send was cancelled in flight (W14). A cancelled READ changed nothing; a
    /// cancelled MUTATION may have landed, and its label says so (`apiRecentRowLabel`).
    public let cancelled: Bool
    /// The path as shown when it was sent — `<name:value>` (W18). Screen-only:
    /// `apiRecentRowJSON` does not publish it.
    public let shownPath: String
    /// Whether the entry it was sent to had a credential configured, AT SEND. Recent is shared
    /// across panes on different entries (W15), so the pane that renders a row's curl line is
    /// not the one that sent it, and only the row can say. Screen-only, like `shownPath`.
    public let credentialed: Bool

    public init(
        id: String = UUID().uuidString, method: String, entry: String, environment: String,
        path: String, sentUrl: String? = nil, status: Int?, durationMs: Int?, draft: ApiDraft,
        cancelled: Bool = false, shownPath: String? = nil, credentialed: Bool = false
    ) {
        self.id = id
        self.method = method
        self.entry = entry
        self.environment = environment
        self.path = path
        self.sentUrl = sentUrl
        self.status = status
        self.durationMs = durationMs
        self.draft = draft
        self.cancelled = cancelled
        self.shownPath = shownPath ?? path
        self.credentialed = credentialed
    }
}

/// A reply that came back.
public struct ApiResponseOK: Sendable, Equatable {
    public let status: Int
    /// The URL that actually left — **on the record, never on the draft**,
    /// where it would be a prediction.
    public let url: String
    /// The environment this ran against, recorded so a staging reply and a
    /// production reply are never confusable after the fact.
    public let environment: String
    public let headers: [String: String]
    /// **Text, and drawn as text.** A JSON body is refused the grid on
    /// §8's rule that a surface which cannot sort, filter or page must not
    /// look like one that can.
    public let body: String
    public let durationMs: Int
    public let byteCount: Int
    /// Whether the body was cut. A short body and a truncated one must
    /// never look alike.
    public let truncated: Bool

    public init(
        status: Int, url: String, environment: String, headers: [String: String],
        body: String, durationMs: Int, byteCount: Int, truncated: Bool
    ) {
        self.status = status
        self.url = url
        self.environment = environment
        self.headers = headers
        self.body = body
        self.durationMs = durationMs
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

/// The transport failed. **It carries no status, no headers and no body**,
/// because there was no reply to take them from.
public struct ApiTransportFailure: Sendable, Equatable {
    /// Where it got to — the operator's first question is how far it got.
    public let stage: String
    public let waitedMs: Int
    public let reason: String
    public let environment: String

    public init(stage: String, waitedMs: Int, reason: String, environment: String) {
        self.stage = stage
        self.waitedMs = waitedMs
        self.reason = reason
        self.environment = environment
    }
}

/// The send's fate is unknown: it may have arrived, and nothing here can
/// say. **Distinct from both a refusal and a failure**, because the
/// remedies differ — a refusal is fixed in the draft, a failure is
/// retried, and this one must not be retried blindly.
public struct ApiFateUnknown: Sendable, Equatable {
    public let reason: String
    public let environment: String

    public init(reason: String, environment: String) {
        self.reason = reason
        self.environment = environment
    }
}
