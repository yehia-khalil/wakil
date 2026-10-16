import Foundation

/// The **parts model** (#189) — what an api pane's draft request is made
/// of, and what resolving it produces.
///
/// **A request field is a sequence of parts, and there is no delimiter
/// anywhere in Wakil.** Nothing is marked up as text and nothing is parsed
/// back, so a database cell containing `{{`, `../` or a template tag is
/// inert *by construction* rather than by escaping. That is the whole
/// reason this is an enum of three cases rather than a string with a
/// syntax: a syntax has a parser, a parser has a quoting rule, and a
/// quoting rule has a bypass.
///
/// **A slot never converts to a bound value or back except by a gesture**,
/// so a binding whose row is gone keeps its origin — the operator is told
/// *which* row went missing — rather than degrading into a clean hole that
/// looks like it was never bound at all.
public enum ApiPart: Sendable, Equatable {
    /// Text the operator authored. It is emitted verbatim in the path —
    /// the operator authors the slashes — and never escaped anywhere.
    case literal(String)
    /// A named hole: sourceless, and never on the wire. A draft holding
    /// one refuses to send, by name.
    case slot(String)
    /// A value taken from a grid on screen.
    case bound(ApiBoundValue)
}

/// Whether a bound value is re-read at send, or holds what it was given.
///
/// **Both ship** (#112): six of nineteen measured SQL shapes qualify as
/// live, so a single gate would refuse every `JOIN`.
public enum ApiBinding: Sendable, Equatable {
    /// Re-resolved against the source pane at every send, by the row's
    /// **key column values** and never by its position — so re-sorting or
    /// re-running the source query cannot make a `POST` confirm a
    /// different booking.
    case live
    /// Holds the cell it was given. It lives exactly as long as the rows
    /// it came from (#137 ruling 2) — a re-fetch or a closed pane kills
    /// it, and Wakil never states its age.
    case captured(ApiHeldCell)
}

/// A cell as the pane received it: the JSON token, and the column's
/// declared type.
///
/// **This pair replaces "declared type and exact lexical form"**, which
/// the 2c-iv probe falsified (`2c-iv-probe.md` §5, #184). A `DECIMAL`
/// does not arrive as a string on sqlite — it arrives as `float64 19.9`,
/// whether it was stored as `'19.90'` or as `19.90`, because `DECIMAL`
/// carries NUMERIC affinity and the engine converts at INSERT, two
/// processes before any Wakil code runs. There is no lexical form left to
/// carry. What the pane *does* receive is a JSON token — a number for the
/// numeric affinities on sqlite, the string `"19.90"` on MySQL and Mongo —
/// and `columnTypes` carries `DECIMAL(10,2)` truthfully whatever the value
/// became.
///
/// **The token is what makes the emit rule driverless.** Writing the
/// token's own text into a JSON number position unquoted produces each
/// engine's own truth with no per-driver branch: `19.9` on sqlite,
/// `19.90` on MySQL. What is given up is the promise that a `DECIMAL`
/// reaches the wire with its trailing zero on sqlite; that promise was
/// never keepable there.
public struct ApiHeldCell: Sendable, Equatable {
    /// The JSON token the pane received, untouched.
    public let token: JSONValue
    /// The source column's declared type, as `columnTypes` published it —
    /// empty when the driver declares none (Mongo's all-NULL columns
    /// report `""`).
    public let declaredType: String

    public init(token: JSONValue, declaredType: String) {
        self.token = token
        self.declaredType = declaredType
    }
}

/// Where a bound value came from, and how to find it again.
///
/// **Keyed, never positional.** The identity of a live value is its row's
/// key column *values*; `keyValues` cross as **text** for the same reason
/// `rowKeys` do — a key above 2^53 cannot cross as a number.
public struct ApiValueSource: Sendable, Equatable {
    /// The source pane's id.
    public let pane: String
    /// The table the source pane was showing, for the refusal's sentence.
    public let table: String
    public let keyColumns: [String]
    /// One text value per `keyColumns` entry, in the same order.
    public let keyValues: [String]
    /// The column this part reads.
    public let column: String
    /// The column's declared type, **pinned at bind time**.
    ///
    /// **Pinned rather than re-read, and #184 is why.** Mongo declares no
    /// type and infers one, and the inferred type is a property of the
    /// PAGE rather than of the column: the same column reports `""` at
    /// `limit 1` and `"string"` at `limit 2`. A live binding that re-read
    /// the type at send would therefore emit the same cell quoted or
    /// unquoted depending on how far the source pane happened to be
    /// paged. The type the operator bound is the type that emits.
    ///
    /// A captured part carries its own in `ApiHeldCell` and never reads
    /// this one — the two are the same fact recorded at the same moment,
    /// kept apart because a captured part has no pane left to read.
    public let declaredType: String
    /// The source pane's `generation` at the moment the value was bound.
    ///
    /// **A generation, not a sweep** (#137): the value lives on the
    /// *consuming* pane, so a source pane's re-fetch must not reach across
    /// and write into another pane's draft. A captured value whose source
    /// has moved on is dead, and this is how resolution learns it without
    /// anything having been notified.
    public let generation: Int

    public init(
        pane: String, table: String, keyColumns: [String], keyValues: [String],
        column: String, declaredType: String, generation: Int
    ) {
        self.pane = pane
        self.table = table
        self.keyColumns = keyColumns
        self.keyValues = keyValues
        self.column = column
        self.declaredType = declaredType
        self.generation = generation
    }
}

/// A value bound from a grid on screen.
public struct ApiBoundValue: Sendable, Equatable {
    /// The name the operator sees, and the name every refusal about this
    /// part uses. It is the hole's name when the binding filled one.
    public let name: String
    public let binding: ApiBinding
    public let source: ApiValueSource
    /// Whether this binding filled a **named hole**, and therefore has a
    /// name to give back.
    ///
    /// **`api_unbind` is the only reader, and it is why this is carried
    /// rather than derived** (#192). A binding that filled a `.slot` returns
    /// to that slot; a **fill-first** binding — one made by dropping on an
    /// empty position — filled no hole, so unbinding removes the part
    /// outright rather than inventing a name for it. `name` cannot tell the
    /// two apart, because a fill-first binding has one too: the column it
    /// reads. Only the gesture knew, so the gesture records it.
    ///
    /// **It defaults to `true`, and the default is the common case rather
    /// than a guess.** Filling a named hole is the only way `apiBind`
    /// makes a binding today; the fill-first gesture does not exist yet and
    /// will say `false` at the one place it is built.
    public let namedHole: Bool

    public init(
        name: String, binding: ApiBinding, source: ApiValueSource, namedHole: Bool = true
    ) {
        self.name = name
        self.binding = binding
        self.source = source
        self.namedHole = namedHole
    }
}

/// One row of the query region: a name, and a value of parts.
///
/// **The name is a literal and admits no parts** — a query *name* selects
/// what the server reads the value as, so it carries structure rather than
/// data (#122).
public struct ApiQueryRow: Sendable, Equatable {
    public let name: String
    public let value: [ApiPart]

    public init(name: String, value: [ApiPart]) {
        self.name = name
        self.value = value
    }
}

/// One row of the header region: a name, and a value of parts. The name is
/// a literal for the same reason a query name is.
public struct ApiHeaderRow: Sendable, Equatable {
    public let name: String
    public let value: [ApiPart]

    public init(name: String, value: [ApiPart]) {
        self.name = name
        self.value = value
    }
}

/// The request an api pane is drafting.
///
/// **The four regions are in wire order — path, query, headers, body —**
/// for the reason `ApiRequestSnapshot` records once and this does not
/// restate: the surface reads in the order the bytes leave.
///
/// **There is no `origin` and no `resolvedUrl`.** The entry's base URL is
/// resolved by `wakil-http`, which is also the process that normalises and
/// gates it; the pane draws the origin it learned at open time for the
/// operator's benefit, and resolution has no business predicting a URL it
/// does not compose.
///
/// **Every region is a `var`, because one action writes any subset of
/// them** (#190). `api_set_request` takes the pane and then every region
/// optional, absent meaning unchanged, so the operator's one-region edit
/// and the agent's whole-request build are literally the same call rather
/// than an approximation of it. Ten setters would have been ten places to
/// enforce one whole-draft rule that is about none of them.
public struct ApiDraft: Sendable, Equatable {
    /// Which `api[]` entry of the active environment this sends to, by
    /// name. Never an origin — the name is what survives an environment
    /// switch.
    public var entry: String
    public var method: String
    public var path: [ApiPart]
    public var query: [ApiQueryRow]
    public var headers: [ApiHeaderRow]
    /// Wakil's own row: free text, **literal-only**, and the one field on
    /// the draft that admits no parts (#116). Empty means *let the send
    /// tool apply its default*, which it only does when there is a body.
    public var contentType: String
    public var body: [ApiPart]

    public static let empty = ApiDraft(
        entry: "", method: "GET", path: [], query: [], headers: [], contentType: "", body: [])

    public init(
        entry: String, method: String, path: [ApiPart], query: [ApiQueryRow],
        headers: [ApiHeaderRow], contentType: String, body: [ApiPart]
    ) {
        self.entry = entry
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.contentType = contentType
        self.body = body
    }
}

/// One resolved query parameter.
public struct ApiWireQueryItem: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One resolved request header.
public struct ApiWireHeader: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// What a resolved draft sends — exactly the fields `wakil-http`'s `send`
/// and `request` tools take, and nothing else.
///
/// **No `Authorization` row and no `content-type` header.** The credential
/// resolves inside Go, at the moment the request leaves, and the pane
/// names no ref; `Content-Type` is `contentType`'s own field, because the
/// send tool refuses a `Content-Type` in `headers` rather than silently
/// overwriting it. Both absences are the shipped tool's shape, not a
/// redaction.
public struct ApiWireRequest: Sendable, Equatable {
    public let entry: String
    public let method: String
    /// The joined path, already escaped. **Not** a URL: the send tool
    /// joins it onto the entry's own base and is the one place that
    /// decides whether the result stays on the entry's origin.
    public let path: String
    /// In the operator's own order. The send tool takes a map, so order
    /// does not reach the wire; keeping it here keeps the value a faithful
    /// picture of the draft it came from.
    public let query: [ApiWireQueryItem]
    /// Name-sorted, case-insensitively — a contract rather than an
    /// accident, so a re-render never reorders them.
    public let headers: [ApiWireHeader]
    /// `nil` when the body region is empty, which is the wire state where
    /// **no body and no `Content-Type`** are sent. A request with nothing
    /// to say must not be given a document.
    public let body: String?
    /// `nil` whenever `body` is, and `nil` when the draft named none — in
    /// which case the send tool applies `application/json` itself.
    public let contentType: String?

    public init(
        entry: String, method: String, path: String, query: [ApiWireQueryItem],
        headers: [ApiWireHeader], body: String?, contentType: String?
    ) {
        self.entry = entry
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }
}

/// Which region a failure is in, for the surface to mark and for a test to
/// assert on without matching prose.
///
/// *"Region" names two nestings in this pane — `ApiSnapshot`'s three, and
/// the four inside `request` — which is
/// [#235](https://github.com/yehia-khalil/rafiq/issues/235)'s to settle.
/// Both spellings are the spec's and are cited across the map, so this
/// reuses the word rather than inventing a third.*
public enum ApiRegion: Sendable, Equatable {
    case path
    case query(String)
    case header(String)
    case body

    /// How the region is named to the operator.
    public var label: String {
        switch self {
        case .path: return "Path"
        case .query(let name): return "Query · \(name)"
        case .header(let name): return "Header · \(name)"
        case .body: return "Body"
        }
    }
}

/// One thing wrong with a draft.
public struct ApiSendFailure: Sendable, Equatable {
    /// The region this refusal is about, or `nil` when it is not a region's: a tool's or a
    /// transport's (B3).
    public let region: ApiRegion?
    /// The sentence the operator reads. **Two messages where the
    /// remedies differ**: *nothing bound yet* and *the row is gone* are
    /// not the same problem and must not share a sentence.
    public let message: String
    /// The columns that **were** available, when the failure is a bound
    /// value that no longer resolves and the source pane is still there to
    /// list them. `nil` otherwise.
    public let available: [String]?

    public init(region: ApiRegion?, message: String, available: [String]? = nil) {
        self.region = region
        self.message = message
        self.available = available
    }
}

/// Every reason this draft cannot be sent — never only the first.
///
/// **The aggregate exists so that fixing the request is one pass rather
/// than four sends.** It follows that it must carry no *derived* failure:
/// an entry the operator cannot act on is that same failure in a smaller
/// shape. See `resolveDraft`, where the body document is validated only
/// once every part of it resolved.
public struct ApiSendRefusal: Error, Sendable, Equatable {
    public let failures: [ApiSendFailure]

    public init(failures: [ApiSendFailure]) {
        self.failures = failures
    }
}
