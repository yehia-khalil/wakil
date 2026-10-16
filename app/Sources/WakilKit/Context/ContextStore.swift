import Foundation

/// What a failed `get_context` still knows.
///
/// `wakilcore.PartialResolved` (`internal/wakilcore/resolve.go`) is the Go
/// half of spec §6.1: `Resolve()` needs an active project and a readable
/// `project.json`, but the **org** needs neither — it is in the process's
/// own environment — and the **active provider** is `active.json`'s fourth
/// axis in the org's own directory. So `get_context` answers `isError:
/// true` *and* a `structuredContent` naming both, verified against the real
/// binary:
///
/// ```
/// {"content":[{"type":"text","text":"no active project — run set_project first"}],
///  "structuredContent":{"Org":"initech","ActiveProvider":"main","Environment":"",
///                       "Project":null,"ProjectPath":"","Provider":{"match":false}},
///  "isError":true}
/// ```
///
/// This type is what carries those two fields to the Swift side. Throwing
/// the message alone — which is what this store did until the 2b-viii
/// acceptance walk — discards Go's whole §6.1 change at the last step, and
/// the walk found both halves of the cost: a **launch** into an org with no
/// active project left `WindowModel.organization` empty (nothing assigns it
/// but `refreshContext`'s success path and `setOrganization`, and a launch
/// takes neither), so `WakilWindow` force-opened the org plane over a
/// perfectly good org, undismissable; and `providerId` was cleared even
/// where `active.json` named one, which stops `autoResumeAfterSwitch` at
/// its first guard with no agent and no message (spec §5.3).
///
/// Both fields are best-effort on the Go side and parsed best-effort here:
/// this is already the error path, and a second failure raised while
/// reporting the first one helps nobody. Absent or malformed keys yield
/// `""`, which every caller must treat as "not knowable" — never as an
/// answer.
public struct PartialContext: Equatable, Sendable {
    /// `wakilcore.Resolved.Org`, from `CurrentOrg()` — knowable whenever
    /// the process started at all.
    public let org: String
    /// `wakilcore.Resolved.ActiveProvider`, from the org's own
    /// `active.json`. Empty for an org that has never picked one.
    public let activeProvider: String

    public init(org: String = "", activeProvider: String = "") {
        self.org = org
        self.activeProvider = activeProvider
    }
}

/// Errors `ContextStore` throws itself, as opposed to whatever `MCPClient`
/// throws when the transport itself is broken (those propagate unchanged).
public enum ContextStoreError: Error, Sendable, Equatable {
    /// `wakil-ctx` answered the call but reported `isError: true`. The
    /// associated string is the server's own message, taken verbatim from
    /// the first text content block — never rewritten, summarized, or
    /// swallowed. `get_context` reports "no active project" this way, which
    /// is a real answer about the context and not a transport failure, so
    /// it has to arrive as something the caller can read rather than as a
    /// blank `ActiveContext`.
    ///
    /// **`partial` is the rest of that answer, not a convenience.** An
    /// error here does not mean nothing is known — see `PartialContext`,
    /// whose doc comment carries what the 2b-viii walk found when this
    /// value was dropped. It is empty for every tool that reports no
    /// `Org`/`ActiveProvider`, which is every tool but `get_context`.
    case serverError(String, partial: PartialContext)
    /// The call succeeded (`isError` false or absent) but the result did
    /// not have the shape this store expects.
    case malformedResult(String)
}

/// **The operator reads this, so it must not be a Swift dump.**
///
/// `WindowModel.refreshContext`'s `catch` sets `status = "context: \(error)"`,
/// and string interpolation of an `Error` with no `description` prints the
/// enum's synthesized form. That was merely ugly while the payload was one
/// string — `context: serverError("no active project — run set_project
/// first")` — and became a leak the moment `serverError` carried a struct:
/// the acceptance walk photographed a status line reading `context:
/// serverError("no active project — run set_project first", partial:
/// WakilKit.PartialContext(org: "orga", activeProvider: ""))`, a Swift type
/// name and a memberwise initializer shown to a human being.
///
/// The server's message is the whole answer, and this store's own contract
/// is that it arrives "verbatim — never rewritten, summarized, or
/// swallowed". Printing it alone is that contract, finally honoured at the
/// one place the operator can see. `partial` is for code, not for reading:
/// it is what §6.3's `catch` acts on, and saying it out loud tells the
/// operator nothing they can use.
extension ContextStoreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .serverError(let message, _): return message
        case .malformedResult(let message): return message
        }
    }
}

/// Wraps a `ToolCaller` — in production an `MCPClient` already started
/// against `bin/wakil-ctx` — mapping exactly one of the tools that binary
/// registers, `get_context`, onto Wakil's notion of "the active
/// org/project/environment". (One of `wakil-ctx`'s tools, that is; the
/// port itself has a single method, `callTool`, and this store reaches
/// every tool through it. `cmd/wakil-ctx/main.go`'s `mcp.AddTool` calls
/// are the list.) Does not own the client's lifecycle: starting
/// and stopping the underlying process is the caller's job.
///
/// **Reading only.** This store had `setProject`/`setEnvironment` methods
/// too, and they were removed once nothing in production called them: the
/// two *changes* are registry actions (`ctx_set_project`,
/// `ctx_set_environment` in `registerStandardActions`), because Invariant 2
/// requires the window's buttons and the agent to take the same path, and
/// the registry's `dispatch` is that path — it is where the write gate and
/// the journal are. A second way to switch project, reachable only from
/// this type, would be exactly the "two code paths to the same state"
/// Invariant 2 forbids, and the tests that covered it were evidence for a
/// path the app did not take (they now dispatch the actions instead; see
/// `StandardActionsTests`).
///
/// Reading stays here rather than becoming another `ctx_*` action because
/// it is
/// not a state change: `WindowModel.refreshContext` calls `current()` to
/// re-read Wakil's own selection, there is no `ctx_get_context` action to
/// dispatch, and Invariant 2 governs mutation paths.
public actor ContextStore {
    /// The active org/project/environment, as `wakil-ctx`'s `get_context`
    /// reports it.
    public struct ActiveContext: Equatable, Sendable {
        public let org: String
        public let project: String
        public let environment: String
        /// `Project.Roots` resolved to absolute paths, in declaration
        /// order — `wakilcore.Resolved.RootPaths`, which is
        /// `ProjectRootPaths`' output reported on the wire so Swift never
        /// re-derives it: a root may be declared relative to the project
        /// directory, and resolving that is Go's job, not this store's.
        /// Order matters — it is the operator's declaration, and "first"
        /// means first as declared.
        public let rootPaths: [String]
        /// `wakilcore.Resolved.ActiveProvider` (2b-vi Task 7's fourth
        /// axis) — the persisted, pick-time provider selection from
        /// `active.json`, which a provider switch changes without a
        /// relaunch. Empty before any provider has ever been chosen for
        /// this org (`ActiveProvider`'s `omitempty` tag means the key is
        /// simply absent then), which is a legitimate state — a fresh
        /// install, or an org that has never run a switch — not a parse
        /// failure.
        ///
        /// **Not the same field as `wakilcore.Resolved.Provider`.** That
        /// one is a pre-existing advisory Selected-vs-Running comparison
        /// computed fresh on every `Resolve()` call, whose `Running` half
        /// comes from `CurrentProvider()` reading `WAKIL_PROVIDER` — a
        /// launch-time fact. `activeProvider` here is the live pick
        /// `WindowSession` reads to decide which provider a window opens
        /// under; reading the other field where this one is meant would
        /// compile fine and silently open under the wrong account.
        public let activeProvider: String
        /// Which of the project's environments DECLARE whether they are
        /// production (Decision 26, #182).
        ///
        /// **Free, and that is why it is here.** `get_context` already
        /// carries the whole project, so the flags arrive with the call the
        /// window already makes — no second tool, and no second source of
        /// truth for a safety property. The window hands this to the action
        /// registry and to the void palette, so the gate and the room read
        /// one value rather than two predicates.
        ///
        /// Empty against a project that declares nothing, and against a
        /// `wakil-ctx` built before the flag existed — both mean "read the
        /// name", which is what every build before this one did.
        public let environmentProduction: EnvironmentProduction

        public init(
            org: String, project: String, environment: String, rootPaths: [String] = [],
            activeProvider: String = "",
            environmentProduction: EnvironmentProduction = .undeclared
        ) {
            self.org = org
            self.project = project
            self.environment = environment
            self.rootPaths = rootPaths
            self.activeProvider = activeProvider
            self.environmentProduction = environmentProduction
        }
    }

    private let client: any ToolCaller

    public init(client: any ToolCaller) {
        self.client = client
    }

    /// Reads the active context via `get_context`.
    ///
    /// Verified against the real `bin/wakil-ctx` binary (built via `make
    /// build`, with a scratch `HOME` holding one org and one project): a
    /// successful `get_context` call's `structuredContent` is
    /// `{"Org":"acme","Project":{"name":"widgets",...},"Environment":"dev",
    /// "ProjectPath":"...","Provider":{...},"RootPaths":["..."],
    /// "ActiveProvider":"..."}` — `Org`, `Environment`, `RootPaths` and
    /// `ActiveProvider` are all top-level capitalized keys
    /// (none of `wakilcore.Resolved`'s fields carry a `json` tag of their
    /// own except `RootPaths` and `ActiveProvider`, whose tags are
    /// capitalized deliberately to match the rest), while `Project` is a
    /// nested object whose own
    /// fields DO carry lowercase `json` tags, so the project's name is
    /// reached at `Project.name`, not `Project.Name`.
    public func current() async throws -> ActiveContext {
        let result = try await callChecked("get_context", arguments: .object([:]))
        // `result` is the whole `CallToolResult` — `{"content":[...],
        // "structuredContent":{...},"isError":...}` — so the Resolved
        // fields (Org/Project/Environment/RootPaths) live one level down,
        // inside "structuredContent", not at this object's top level.
        // Verified against the real binary (see this method's other doc
        // comment).
        guard case .object(let obj) = result, case .object(let structured)? = obj["structuredContent"] else {
            throw ContextStoreError.malformedResult("get_context result has no \"structuredContent\" object")
        }
        return try Self.parseActiveContext(.object(structured))
    }

    /// Parses `get_context`'s `structuredContent` object into an
    /// `ActiveContext`, factored out of `current()` so it can be tested
    /// against a literal `JSONValue` without a live `wakil-ctx` process.
    ///
    /// `structured` is exactly `structuredContent` — the caller has
    /// already stripped away the enclosing `CallToolResult`.
    internal static func parseActiveContext(_ structured: JSONValue) throws -> ActiveContext {
        guard case .object(let fields) = structured else {
            throw ContextStoreError.malformedResult("get_context structuredContent is not an object")
        }
        guard case .string(let org)? = fields["Org"] else {
            throw ContextStoreError.malformedResult("get_context result has no string \"Org\"")
        }
        guard case .string(let environment)? = fields["Environment"] else {
            throw ContextStoreError.malformedResult("get_context result has no string \"Environment\"")
        }
        var project = ""
        var declarations: [String: Bool] = [:]
        if case .object(let projectObj)? = fields["Project"] {
            if case .string(let name)? = projectObj["name"] { project = name }
            // `environments` is lower-case here — it is a field of
            // `wakilcore.Project`, which tags its fields, unlike the
            // capitalized top level of `Resolved`. Only environments that
            // DECLARE a flag are recorded: an absent key means "read the
            // name", and writing `false` for it here would be the
            // materialised default `Environment.Production`'s `*bool`
            // exists to avoid.
            if case .object(let environments)? = projectObj["environments"] {
                for (name, value) in environments {
                    guard case .object(let env) = value,
                          case .bool(let declared)? = env["production"] else { continue }
                    declarations[name] = declared
                }
            }
        }
        // "RootPaths", capitalized — matches every other top-level key on
        // `wakilcore.Resolved` (Org, Environment above), and
        // `Resolved.RootPaths` carries an explicit `json:"RootPaths"` tag
        // for exactly that reason (see `internal/wakilcore/resolve.go`).
        // Absent entirely on an older `wakil-ctx` built before this field
        // existed — `bin/` is per-worktree and routinely stale — so a
        // missing key parses to `[]` rather than throwing, and a fresh
        // window still opens against a stale binary.
        var rootPaths: [String] = []
        if case .array(let values)? = fields["RootPaths"] {
            rootPaths = values.compactMap { value -> String? in
                guard case .string(let path) = value else { return nil }
                return path
            }
        }
        // "ActiveProvider", capitalized — the same top-level convention
        // as "RootPaths" above, and `Resolved.ActiveProvider` carries an
        // explicit `json:"ActiveProvider,omitempty"` tag for the same
        // reason (`internal/wakilcore/resolve.go`). Absent on an org that
        // has never picked a provider, or on a `wakil-ctx` built before
        // 2b-vi Task 7 — either way a missing key parses to `""`, "no
        // provider chosen", rather than throwing.
        var activeProvider = ""
        if case .string(let value)? = fields["ActiveProvider"] {
            activeProvider = value
        }
        return ActiveContext(
            org: org, project: project, environment: environment, rootPaths: rootPaths,
            activeProvider: activeProvider,
            environmentProduction: EnvironmentProduction(declarations: declarations))
    }

    /// Calls `name` on the underlying client and translates the MCP
    /// tool-error convention into a thrown `ContextStoreError`.
    ///
    /// `MCPClient.callTool`'s own doc comment is explicit that a
    /// server-side tool failure (wakil-ctx's pattern of returning a
    /// `CallToolResult` with `isError: true`) is still a *successful*
    /// JSON-RPC response — it does not throw on its own. Checking
    /// `isError` here, on every call this store makes, is what turns that
    /// server-side convention into a Swift error instead of a value that
    /// looks like success to an untyped caller.
    ///
    /// `StandardActions.callChecked` does the same translation for the
    /// registry's handlers, into `StandardActionError.serverError`. Two
    /// small implementations rather than one shared function because the
    /// error types differ — an action's carries the action name, so a
    /// dispatch failure says which action failed — and what is genuinely
    /// common between them, pulling the server's message out of the
    /// `content` array, *is* shared, as `mcpErrorText` below.
    private func callChecked(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        // Every tool this store calls is a `wakil-ctx` read or a small
        // JSON write under `~/.wakil`, so the read budget is the right one:
        // nothing here reaches a database, and abandoning any of it changes
        // nothing outside Wakil.
        let result = try await client.callTool(
            name: name, arguments: arguments, timeout: MCPClient.readReplyTimeout)
        guard case .object(let obj) = result else {
            return result
        }
        if case .bool(true)? = obj["isError"] {
            // The error path still carries a `structuredContent` — see
            // `PartialContext`. Parsed here rather than in `current()` so
            // there is exactly one place that turns the MCP tool-error
            // convention into a Swift error, and no caller can construct a
            // `.serverError` that quietly forgot to look.
            throw ContextStoreError.serverError(
                mcpErrorText(from: obj) ?? "\(name) failed with no message",
                partial: Self.parsePartialContext(obj["structuredContent"]))
        }
        return result
    }

    /// Pulls `Org` and `ActiveProvider` out of a failed call's
    /// `structuredContent`.
    ///
    /// **Never throws, by design.** This runs only on the error path, where
    /// the call has already failed and a parse failure raised on top of it
    /// would replace a readable message with an unreadable one. Anything
    /// missing, mistyped or absent yields `""` — "not knowable" — which is
    /// the same answer an older `wakil-ctx` built before spec §6.1 gives,
    /// and leaves callers exactly where they were before this existed.
    internal static func parsePartialContext(_ structured: JSONValue?) -> PartialContext {
        guard case .object(let fields)? = structured else { return PartialContext() }
        var org = ""
        if case .string(let value)? = fields["Org"] { org = value }
        var activeProvider = ""
        if case .string(let value)? = fields["ActiveProvider"] { activeProvider = value }
        return PartialContext(org: org, activeProvider: activeProvider)
    }
}

/// Pulls the human-readable message out of an MCP tool-error result's
/// `content` array: `{"content":[{"type":"text","text":"..."}], ...}`.
/// Shared by `ContextStore` and `StandardActions` since both translate the
/// same wire convention. Returns `nil` if `content` is missing, empty, or
/// its first element isn't a text block with a string `text` — callers
/// fall back to a message of their own in that case rather than throwing
/// something opaque.
func mcpErrorText(from result: [String: JSONValue]) -> String? {
    guard case .array(let content)? = result["content"], case .object(let first)? = content.first,
        case .string(let text)? = first["text"]
    else {
        return nil
    }
    return text
}
