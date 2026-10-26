import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Wire-setup errors this transport layer throws itself — socket
/// creation/bind/listen failures on the `MCPSocketServer` side, and the
/// equivalent connect-side failures `runShim` (in `Shim.swift`) surfaces to
/// stderr. Never sent as a JSON-RPC error object: these happen before any
/// JSON-RPC frame could be exchanged at all.
public enum MCPTransportError: Error, Sendable, CustomStringConvertible {
    case pathTooLong(String)
    case posixFailure(call: String, path: String, errnoValue: Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let path):
            return "socket path too long for sockaddr_un: \(path)"
        case .posixFailure(let call, let path, let errnoValue):
            return "\(call)(\(path)) failed: \(String(cString: strerror(errnoValue)))"
        }
    }
}

/// Fills in a `sockaddr_un` for `path`. Shared by `MCPSocketServer` (binding)
/// and `runShim` (connecting) so the two sides of this transport agree on one
/// way to build the address. `sun_path` is a fixed-size byte buffer on Darwin
/// (its exact size is read via `MemoryLayout.size(ofValue:)` below rather
/// than hard-coded), so a path that does not fit is rejected here rather than
/// silently truncated.
/// Ignores SIGPIPE process-wide. A write to a socket whose peer already
/// closed its read side raises SIGPIPE, and the default disposition for that
/// signal terminates the process outright — before `write(2)` ever returns
/// control (let alone an error) to Swift, so a `try?` around
/// `FileHandle.write` cannot catch it; there is nothing for `try?` to catch
/// until the signal itself stops being fatal. Reproduced directly on this
/// machine: a client that sent a request and closed its socket before
/// reading the reply killed the whole process with exit code 141 (128 +
/// SIGPIPE) the moment `Connection.ingest` tried to write the reply back,
/// twice in a row, before this fix.
///
/// Declared as a top-level `let`: Swift initializes a global exactly once,
/// the first time it is read, and that initialization is synchronized
/// against concurrent readers — so calling `_ = ignoreSIGPIPEProcessWide`
/// from both `MCPSocketServer.start()` and `runShim` still only calls
/// `signal` once per process. Ignoring SIGPIPE process-wide has no effect on
/// any other signal or any other descriptor's behaviour beyond turning a
/// write to a dead peer into an ordinary `EPIPE` error return.
let ignoreSIGPIPEProcessWide: Void = {
    signal(SIGPIPE, SIG_IGN)
}()

/// Sets `SO_NOSIGPIPE` on `fd`: a second, narrower guard against the same
/// failure `ignoreSIGPIPEProcessWide` already covers process-wide, applied
/// per-socket. Belt-and-suspenders — either mechanism alone is sufficient on
/// Darwin — so a `setsockopt` failure here is not treated as fatal; the
/// process-wide signal disposition is still in effect regardless.
func disableSIGPIPE(onSocket fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

func makeUnixSocketAddress(path: String) throws -> (sockaddr_un, socklen_t) {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < capacity else {
        throw MCPTransportError.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let buffer = raw.bindMemory(to: UInt8.self)
        for (index, byte) in pathBytes.enumerated() {
            buffer[index] = byte
        }
        buffer[pathBytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
    return (addr, length)
}

/// The application state Wakil's MCP surface serves: the action set
/// `tools/list` projects and `tools/call` dispatches into, and the panes
/// `read_pane` reads back out.
///
/// These two travel together rather than as separate parameters because
/// they are only meaningful *as a pair*. The actions in `registry` are what
/// write into `panes` — `db_run_query`'s handler calls `PaneStore.setRows`
/// for the pane the operator named (2c-i Task 11b; before that it was
/// hardcoded to a single `"db"` pane the window drew itself), and the
/// `pane_*` content actions write the selection, the sort and the scroll
/// target. So a server handed one assembly's registry and another's pane
/// store would answer `tools/call` correctly and `read_pane` from a store
/// nothing it dispatches ever writes to — a silent, permanently-empty pane
/// rather than any kind of error.
///
/// **What is enforced, and by what.** The memberwise initialiser is
/// `internal`, and `WakilWiring.mcpSurface` is the only `public` way to
/// obtain one — so outside this module the mismatch is not merely
/// discouraged, it cannot be written: `MCPSocketServer(surface:…)` has no
/// pair to be handed but the one a `WakilWiring` built for itself. That is
/// what `WakilApp` is held to; `WakilWindow` names neither half.
///
/// **What is still only conventional.** Inside `WakilKit` — and inside the
/// test target, since `@testable import` lifts `internal` to `public` by
/// design — the initialiser is reachable and can be handed any two values.
/// `MCPServerTests` and `ShimTests` do exactly that, deliberately, to build
/// a registry and a pane store that suit one assertion. The compiler cannot
/// tell those apart from a mistake, so within the module the pairing rests
/// on `WakilWiring.build` being the only place a shipped assembly is made.
public struct MCPSurface: Sendable {
    public let registry: ActionRegistry
    public let panes: PaneStore
    public let layout: LayoutStore
    /// Where a refused mutation waits for a human. Paired here with the
    /// registry for the same reason `panes` and `layout` are: a server
    /// given this registry and some other assembly's broker would park
    /// proposals nobody is watching.
    public let confirmations: ConfirmationBroker

    /// Reads the active organisation's configuration from disk — the same
    /// read `ctx_config_tree` performs, through the same function
    /// (`readConfigTree`).
    ///
    /// **It is on the surface rather than reached through `dispatch`**
    /// because `read_pane` is not an action. It changes nothing and
    /// observes nothing the journal wants, and routing it through the
    /// registry would put a row in the audit log every time the agent
    /// looked at a pane — which is the reason all three hand-written tools
    /// are intercepted before `handleToolsCall` reaches the registry at
    /// all.
    ///
    /// **A closure rather than a stored tree**, because the settings pane
    /// caches nothing: every `read_pane` on it is a fresh read of disk,
    /// which is what makes staleness structurally impossible rather than
    /// merely unlikely.
    ///
    /// Throws when no context client is available, which a test assembly
    /// and a half-installed tree both produce; `read_pane` turns that into
    /// the snapshot's own `failure` string rather than a protocol error,
    /// exactly as a pane that could not be filled reports one.
    public let settings: @Sendable () async throws -> JSONValue

    init(
        registry: ActionRegistry, panes: PaneStore, layout: LayoutStore,
        confirmations: ConfirmationBroker,
        settings: @escaping @Sendable () async throws -> JSONValue = {
            // The default is the honest answer for a surface assembled
            // without a context client — a test's, and a half-installed
            // tree's. `read_pane` turns it into the snapshot's own
            // `failure` string, which is what every other pane that could
            // not be filled reports. Defaulting to an EMPTY tree instead
            // would have `read_pane` tell the agent this machine has no
            // projects, which is a sentence about the operator's machine
            // that nothing checked.
            throw StandardActionError.missingClient(action: "ctx_config_tree", role: "context")
        }
    ) {
        self.registry = registry
        self.panes = panes
        self.layout = layout
        self.confirmations = confirmations
        self.settings = settings
    }
}

/// Answers one JSON-RPC message against `surface`, without any socket
/// involved — this is the entire MCP protocol surface Wakil serves, and it is
/// deliberately pure enough to test that way (see `MCPServerTests.swift`).
///
/// - `initialize` gets a fixed capabilities/serverInfo reply.
/// - `tools/list` projects `surface.registry.all()` — one MCP tool per
///   registered action, name and schema taken straight from the descriptor —
///   plus the two hand-written tools, `read_pane` (design doc §2.3: "That
///   leaves exactly one hand-written tool: read_pane") and its 2b-i sibling
///   `read_layout`.
/// - `tools/call` dispatches through `registry.dispatch(..., origin: .agent)`
///   for every tool name except `read_pane` and `read_layout`, which are
///   answered from `surface.panes` and `surface.layout` respectively, and
///   turns whatever `ActionRegistry` throws into a JSON-RPC error object
///   rather than crashing this actor's caller.
/// - Any other method (or a message with a method but no matching case)
///   becomes a "Method not found" JSON-RPC error.
/// - A message with no `id` is a JSON-RPC notification: the protocol defines
///   no reply for one, so this returns `nil` and sends nothing. Answering a
///   notification would itself be a protocol violation.
///
/// **`caller` is a closure, not a value, and that is a correctness
/// requirement rather than a convenience.** The caller's place (and so its
/// environment) is what `writeGate` judges, and it changes while this server is up —
/// `ctx_set_environment`, or an operator pressing ⌘K, moves it. A gated
/// proposal parks until the operator answers it (an agent's never expires) before it
/// is re-dispatched, so a value captured when the request was *read* can
/// be stale by the time the gate re-reads it. The reachable direction is
/// the dangerous one: a proposal can only park when the environment is
/// *not* production (production is `.block`, which never parks), so a stale
/// capture can only ever be more permissive than the truth. Taking a
/// closure means there is no captured value to go stale, and it makes this
/// path agree with `WindowModel.parkAndAwait`, which reads its `environment`
/// property afresh at re-dispatch — the spec's "one confirmation mechanism,
/// not two" has to mean the two agree about the one input the gate reads.
///
/// **`screen` is what the window shows** — its place and conversation — read only by
/// `initialize`, which reports it beside the caller's own under `_meta` (`initializeMeta`). Nil
/// where nothing has a screen — a test's server — and the reply says `null`.
public func handle(
    _ message: JSONRPCMessage,
    surface: MCPSurface,
    caller: @Sendable () async -> DispatchCaller,
    screen: (@Sendable () async -> ScreenShown?)? = nil
) async -> JSONRPCMessage? {
    guard let id = message.id else {
        return nil
    }
    guard let method = message.method else {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32600, message: "Invalid Request: missing \"method\""))
    }

    switch method {
    case "initialize":
        let own = await caller()
        let shown = await screen?()
        return JSONRPCMessage(id: id, result: .object([
            // Deliberately not bumped in 2a. Note that `structuredContent`,
            // which `readPane` below returns, postdates this revision — see
            // that function's doc comment for why the text `content` block
            // is the half that has to carry the answer regardless.
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string("wakil"),
                "version": .string("2a"),
            ]),
            "_meta": initializeMeta(
                place: own.place, screen: shown?.place,
                conversation: own.conversation, screenConversation: shown?.conversation),
        ]))

    case "tools/list":
        var tools = await surface.registry.all().map(toolListEntry)
        tools.append(readPaneToolListEntry)
        tools.append(readLayoutToolListEntry)
        // Not optional. Probe §8: a `tools/list` without this makes the CLI
        // refuse at its first permission check, with an error the agent reads.
        tools.append(permissionPromptToolListEntry)
        return JSONRPCMessage(id: id, result: .object(["tools": .array(tools)]))

    case "tools/call":
        return await handleToolsCall(id: id, params: message.params, surface: surface, caller: caller)

    default:
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32601, message: "Method not found: \(method)"))
    }
}

/// What a window shows, for a socket's `initialize`: the place, and the conversation in it — the
/// one on screen, or the one its Landing reserves (`WindowModel.screenConversation`), nil when
/// there is none yet.
public struct ScreenShown: Sendable, Equatable {
    public let place: Place
    public let conversation: String?

    public init(place: Place, conversation: String?) {
        self.place = place
        self.conversation = conversation
    }
}

/// What `initialize` says about this socket beyond the protocol: `wakil/place`, the place every
/// call on it is made for — an agent session's socket is pinned to its own place for life — and
/// `wakil/screen`, the place the window shows as it answers, or null when unknown; and
/// `wakil/conversation` and `wakil/screenConversation`, the same two for the conversation
/// (conversations 2 of 3), each null when unknown. MCP's `_meta` is the result's room for
/// exactly this, and a client that does not read it ignores it.
///
/// **What the e2e harness picks its channel by** (`e2e/driver/socket.go`): a window holds one
/// socket per conversation it has shown, and the one to drive is the one whose place — and
/// conversation — is the screen's: after ⌘N a place holds the backgrounded conversation's
/// socket and its Landing's, and only the second is the screen's. All four answers come from
/// the window that knows them. `project` is the registry key, the one `WAKIL_PROJECT` pins by.
func initializeMeta(
    place: Place, screen: Place?, conversation: String?, screenConversation: String?
) -> JSONValue {
    func object(_ place: Place) -> JSONValue {
        .object([
            "organization": .string(place.organization),
            "project": .string(place.project),
            "environment": .string(place.environment),
        ])
    }
    return .object([
        "wakil/place": object(place),
        "wakil/screen": screen.map(object) ?? .null,
        "wakil/conversation": conversation.map(JSONValue.string) ?? .null,
        "wakil/screenConversation": screenConversation.map(JSONValue.string) ?? .null,
    ])
}

/// Projects one registered action into the shape `tools/list` advertises.
/// The field name is `inputSchema`, not `schema` — matching what
/// `MCPClient.parseToolDescriptor` (Task 5) reads from a real server's
/// `tools/list` reply, so this server and that client agree on the wire
/// shape for the same field.
///
/// **`annotations.readOnlyHint` carries the action's `kind` out of the
/// process** (#256). `ActionRegistry`'s description is, by its own doc
/// comment, the only way to enumerate registered actions from outside this
/// actor — but until this field existed it enumerated their names and not
/// what they do, so anything outside asking *which of these write?* had to
/// answer it by reading Swift source across six registrars. That is a second
/// answer to a question the running app already knows, and the coverage gate
/// rests on the answer: every write action owes a parity check, and an action
/// wrongly read as a read owes nothing and is never noticed.
///
/// `readOnlyHint` is MCP's own field for this, added in protocol 2025-03-26.
/// This server advertises 2024-11-05, where an unknown key in a tool entry is
/// ignored, so nothing that reads this list today can be broken by it and
/// anything that understands the later revision gets the truth.
///
/// **`.read` alone is read-only.** `.control` does not touch the world
/// outside Wakil, but it changes Wakil — a pane moves, the active context
/// switches — and `readOnlyHint` asks whether the tool modifies its
/// environment, not whether it is dangerous. `destructiveHint` is the field
/// that asks the second question, and it is deliberately not emitted here:
/// `ActionKind` does not answer it, `Action.price` does, and a hint invented
/// from the kind would be a guess wearing the protocol's clothes.
private func toolListEntry(_ descriptor: ActionDescriptor) -> JSONValue {
    .object([
        "name": .string(descriptor.name),
        "description": .string(descriptor.description),
        "inputSchema": descriptor.schema,
        "annotations": .object(["readOnlyHint": .bool(descriptor.kind == .read)]),
    ])
}

/// The name of the one hand-written tool Wakil's MCP surface serves (design
/// §2.3). A named constant rather than three string literals because the
/// session's `--allowedTools` list has to spell it identically — an allow
/// entry that says `read_pane` while this said something else would deny the
/// one tool Invariant 3 depends on, and nothing in the app would look wrong.
/// See `agentAllowedTools` in `App/AgentMCPConfig.swift`.
public let readPaneToolName = "read_pane"

/// `read_pane`'s `tools/list` entry. Its schema takes a `paneId` string —
/// the id of a pane on the canvas, as `read_layout` reports it and as
/// `pane_open` returns it. (Through 2a there was exactly one such id,
/// `"db"`, hardcoded by `db_run_query`'s handler and drawn by the window
/// rather than by any pane; 2c-i moved contents into the panes, so there is
/// now one id per open pane.) The schema does not
/// enumerate the valid ids: pane ids are chosen by whatever writes them
/// (`PaneStore`'s own contract), there is no registry of them, and an enum
/// here would be a second place to keep in step with the first.
///
/// **`pane` is also honoured, silently, alongside the declared `paneId`**
/// (walk-defects D5). Every other terminal and pane-content action —
/// `term_open`, `term_propose`, `term_run`, `term_scroll`,
/// `pane_select_cell`, `db_run_query`'s own target and the rest —  spells
/// the same argument `pane`. An agent that has learned that shape from the
/// other nine tools and calls `read_pane {"pane": …}` used to get
/// `-32602`; it now resolves the same as `paneId` would. `paneId` stays the
/// one name in the schema — the one already documented above, and the one
/// an agent reads from `tools/list` — because renaming it would break an
/// agent that already learned *that* spelling instead. `paneId` wins when a
/// caller sends both.
private let readPaneToolListEntry = JSONValue.object([
    "name": .string(readPaneToolName),
    // Read-only, like every registered `.read` action and for the same
    // reason: it observes a pane and changes nothing. See `toolListEntry`.
    "annotations": .object(["readOnlyHint": .bool(true)]),
    "description": .string(
        "Read what a Wakil UI pane is currently showing. The result is a UNION keyed by "
        + "kind: read kind first, then only the keys belonging to that kind. kind is always "
        + "present, and is null when no pane on the canvas holds that id — which is not an "
        + "error, because a pane can close between the read_layout that named it and this "
        + "call. failure is the one key present for every kind: the error from whatever the "
        + "pane last tried to do, or null.\n"
        + "\n"
        + "kind \"db\" — a data surface. columns and, when the driver could say, columnTypes "
        + "alongside them (columnTypesInferred is true when those types were worked out from "
        + "the values rather than declared, which only happens for Mongo); rows and rowCount; "
        + "millis, how long the query behind them took; truncated, true when more rows matched "
        + "than were returned — treat a truncated pane as a partial answer, never as the whole "
        + "one; pageable, whether this pane can be asked for another page at all; listsTables, "
        + "true when a row's first cell names a table in this pane's own database and can be "
        + "opened as one — declared by the driver, never guessed from the shape of the rows, "
        + "so it can be false even when the rows plainly look like a table list; "
        + "running, true while a read is in flight on this pane (a second read is refused until "
        + "it ends; db_cancel stops it); cancelledAfterMs, how long the last read ran before it "
        + "was cancelled, or null if it was not; "
        + "offset, how many rows were skipped to produce the page currently shown; selection, "
        + "the operator's anchor cell and selected rows; sort, an ORDERED LIST of "
        + "{column, direction} terms — never null, empty when unsorted — where index 0 is the "
        + "primary key and each later term only breaks ties among rows already equal on every "
        + "earlier one; use pane_sort to add, flip, drop, or clear a term rather than writing "
        + "ORDER BY into a query; and scrollTarget, the row the pane was last asked to scroll "
        + "into view, or null. Every row index — in selection, in scrollTarget, and in rows "
        + "itself — is an index into the order currently DISPLAYED, and sort is what changes "
        + "that order. rows and rowCount are the pane's last GOOD result and are left alone by "
        + "a failed refetch, so a non-null failure beside non-empty rows means the fetch failed "
        + "and what is shown is stale, not that the query returned nothing.\n"
        + "\n"
        + "kind \"terminal\" — an interactive shell. BOTH of its surfaces are returned, always: "
        + "screen says which one the operator is actually looking at (\"blocks\" or \"grid\"), "
        + "and the other is still readable — a pager holding the screen is exactly when you are "
        + "most likely to be asked what went wrong in the build behind it. blocks is the "
        + "history of finished commands, each with id, command, origin, exitCode, durationMs, "
        + "output and heldTheGrid (true when the command REPAINTED its screen rather than "
        + "PRINTING a transcript — either by taking the alternate screen, like vim, or by "
        + "redrawing in place on the ordinary screen, like a full TUI that never touches the "
        + "alternate screen at all — so output is empty on purpose, not because capture failed). "
        + "origin is \"operator\" for a command the operator submitted, \"agent\" for "
        + "one Wakil ran in its OWN bare-environment shell and is mirroring here, and "
        + "\"proposed\" for one you proposed that has not been accepted yet — which is how you "
        + "tell whether a proposal was taken, discarded, or is still sitting there. "
        + "blocksTruncated is true when the history has been trimmed to its cap: a short "
        + "history and a trimmed one must never be read alike. grid is the VISIBLE SCREEN ONLY, "
        + "never scrollback, bounded by cols and rows. cwd is the shell's live working "
        + "directory and shell is which shell is running. scrollTarget is the id of the block "
        + "term_scroll last asked to be brought into view, or null — a block id, never a row "
        + "index, because this history has no sort for a row to index into. backfilledAt is "
        + "when this pane's mirror was last reconstructed from the transcript — a pane opened "
        + "after you had already run commands is filled in with them — or null if it never "
        + "was: an \"agent\" block that started at or before that moment is replayed history, "
        + "not something that just happened. promptRow is the row (into grid, same coordinates) "
        + "the operator's current prompt began on, or null before the first one; cursorRow and "
        + "cursorCol are the pty's own cursor in the same coordinates, or null. Both are what "
        + "the pane draws its own live prompt and cursor from, and either can be null on a pane "
        + "with no shell yet. commandRunning is whether a command is executing in this pane "
        + "RIGHT NOW: true means the rows under the block history are a running program's own "
        + "screen rather than the operator's prompt, so what you read there is mid-flight and "
        + "will be replaced, not a finished result.\n"
        + "\n"
        + "kind \"api\" — an API client pane, pointed at ONE named entry of the active "
        + "environment. entry is that name and environment is the environment it was opened "
        + "against; credentialed says a credential is CONFIGURED for the entry and nothing "
        + "more — never that it is valid, current or sufficient, and a send may still come "
        + "back 401. Nothing here is redacted, because nothing redactable reaches this pane: "
        + "the credential resolves inside the capability layer at the moment a request "
        + "leaves, and this pane never holds it or names its ref.\n"
        + "Three regions, by tense. request is what is DRAFTED and has not been sent: its "
        + "method, its origin — the entry's resolved base URL, or null when the entry does "
        + "not resolve, which is a configuration failure to read BEFORE sending rather than "
        + "after — and the four regions in wire order, path, query, headers and body. "
        + "Each is a SEQUENCE OF PARTS and never a string with delimiters in it, so that "
        + "nothing a database cell holds can be read back as markup; query and headers carry "
        + "a name and a value of parts APART, for the same reason. A part is one of three. "
        + "{\"literal\"} is text someone typed. {\"slot\"} is a NAMED HOLE — sourceless, never "
        + "on the wire, and a draft holding one refuses to send until a row is dropped on it. "
        + "A bound value carries name, binding (live or captured), source (the pane, table, "
        + "key columns, key values and column it reads), preview, resolves and available. "
        + "PREVIEW, NEVER VALUE: it is what that cell holds right now, not what will be "
        + "sent — resolution happens at send, and the draft is deliberately unresolved, so "
        + "there is no resolvedUrl on it to read. resolves false means the send WILL be "
        + "refused, with preview null and available listing the columns the source grid "
        + "still has; that is the one thing here you cannot learn from the screen, and "
        + "reading it beats learning the same fact from a refusal. "
        + "request.headers carries the rows whose value this app holds — what the operator "
        + "authored plus content-type, name-sorted with Wakil's own rows last, the same "
        + "order they are drawn in. authorization is NOT a row: the credential resolves "
        + "inside the capability layer and never enters the app, so credentialed above "
        + "carries that fact instead. An absent content-type row means the draft names none "
        + "and the send tool applies its own default when there is a body. "
        + "response is what CAME BACK, and it is keyed by its own discriminator: read state "
        + "first and then only the keys belonging to that state, exactly as you read kind "
        + "first here. state \"none\" means nothing has been sent from this pane and it has "
        + "no other keys at all. recent is what has ALREADY been sent from every api pane of "
        + "this project in this environment — one list they share — one row per send "
        + "with an outcome, and recentTruncated says whether that history has been trimmed "
        + "to its cap. failure is always null for this kind: a refused request is this pane "
        + "working correctly and the refusal is the answer, so it is reported in response, "
        + "never here.\n"
        + "\n"
        + "kind \"git\" — a Git repository browser. roots is the active project's declared "
        + "roots in project order, a folder that is not a repository among them (its error "
        + "says so), each with its branch name, detached state, how many commits it is "
        + "ahead of and behind its tracking branch, any error loading it, whether it is "
        + "currently loading, and its files grouped by status (staged, changed, untracked). "
        + "selection is the currently selected file, or null when nothing is selected, "
        + "holding the root, its path within that root and its group. folded is true when "
        + "the file list is collapsed into the spine while the diff is visible. inView is "
        + "the root the unfolded list was scrolled to because a refresh took the selected "
        + "file's root's last file away, or null. diff "
        + "contains metadata about the selected file's diff — whether it is binary, its "
        + "size in bytes and lines, whether it was truncated, any error reading it, "
        + "whether it is currently loading, and the detected language for syntax "
        + "highlighting — but never the diff text itself, which git_show returns.\n"
        + "\n"
        + "kind \"editor\" — the code editor. tabs lists the open tabs, each a file (path and "
        + "root) or a scratch buffer (scratch is its number) with its language, whether it "
        + "is dirty, its disk_state, any notice and whether it is saving. active is the "
        + "index of the active tab, or null. cursor, selection and visible_range describe "
        + "the active tab; visible_text is the lines on screen and selected_text the "
        + "selected text — never the whole file, which the agent reads itself. hunks is the "
        + "active file tab's changes against git's index — each a kind (added, changed or "
        + "deleted), the line it starts on and its count of lines — or null when the tab has "
        + "no baseline. peek is the open peek — index of the change it shows, count of changes and the "
        + "line it sits under — or null when none is open (editor_peek opens it, editor_peek_step "
        + "moves it, editor_peek_close closes it). A tab's "
        + "preview is true while it is a preview tab, one a click replaces. column is the "
        + "side column — shown, view (which view it holds), width, and open, the folders "
        + "expanded in the tree — or null. find is the active tab's find — query and its "
        + "switches case, word and regex, count of matches (null until counted) and "
        + "shown — or null when no find is open. search is the project search — query and "
        + "its switches case, word and regex; in_flight while it runs; truncated when it "
        + "stopped at the match cap; files_truncated when a root had too many files and was "
        + "searched only in part; skipped_large, the files over 2 MB it did not search; changed_since when a searched file has changed since the "
        + "results were taken; cancelled when it was stopped before it finished; error, "
        + "any error; and results, each match's root, path, "
        + "line, column and preview; replace is the Replace field's text, or null while it is closed; "
        + "replace_in_flight while a replace runs; last_replace is the latest replace — replaced, files, "
        + "failures (each path and error), undoable, undone, restored and cancelled — or null.\n"
        + "\n"
        + "kind \"browser\" — a web browser. tabs lists the open tabs in order, each its id, url, "
        + "title, whether it is loading and whether it is the active one. active is the active "
        + "tab's id, or null. url, title, loading, canGoBack, canGoForward and zoom describe the "
        + "active tab, or are null when there is none. find is the find bar — query, current "
        + "match and total — or null while it is closed. downloads lists this pane's downloads "
        + "in the order they began, each its id, filename, state (running, finished, failed or "
        + "cancelled), bytes received and bytes expected. Never the page's text. failure is the "
        + "active tab's load failure, or null.\n"
        + "\n"
        + "The grid-only actions (pane_select_cell, pane_select_rows, pane_set_column_width, "
        + "pane_scroll_to_row, pane_scroll_clear) refuse a terminal pane and an api pane by "
        + "name. Use term_scroll for a terminal pane's history."),
    "inputSchema": .object([
        "type": .string("object"),
        "properties": .object(["paneId": .object(["type": .string("string")])]),
        "required": .array([.string("paneId")]),
    ]),
])

/// The second of the two hand-written tools on Wakil's MCP surface.
///
/// Hand-written for the same reason `read_pane` is: it is a pure read of
/// UI state, so it changes nothing for the gate to refuse and records
/// nothing for the journal to hold. Registering it as an action would put
/// a no-op entry in the journal every time an agent looked at the screen.
///
/// **It is the other half of Invariant 3.** `read_pane` answers *what is
/// in that pane*; `read_layout` answers *what is on screen, and where*.
/// Neither alone lets an agent resolve a phrase like "the pane next to the
/// terminal".
public let readLayoutToolName = "read_layout"

private let readLayoutToolListEntry = JSONValue.object([
    "name": .string(readLayoutToolName),
    "annotations": .object(["readOnlyHint": .bool(true)]),
    "description": .string(
        "Read the arrangement of Wakil's panes: each pane's id, kind, title, position and size, "
        + "whether it is busy, which pane is focused, which (if any) fills the canvas, and which "
        + "pane edges are snapped together. Use it with read_pane to resolve references like "
        + "\"the pane next to the results\"."),
    "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
])

/// Projects a `LayoutSnapshot` into `read_layout`'s wire shape.
///
/// `focusedId` and `maximizedId` are always present, `.null` when unset,
/// for the reason `PaneStore.snapshot` always emits `truncated`: this
/// object is read by an LLM, and an absent key is something a reader must
/// know to interpret while an explicit null is an answer.
/// `internal` rather than `private` so `SettingsPaneTests` can put the
/// `overlay` key under test directly. The alternative is driving a whole
/// JSON-RPC round trip to assert one field of one payload.
func layoutPayload(_ snapshot: LayoutSnapshot) -> JSONValue {
    .object([
        "panes": .array(snapshot.panes.map { pane in
            .object([
                "id": .string(pane.id),
                "kind": .string(pane.kind),
                "title": .string(pane.title),
                "x": .number(pane.frame.x),
                "y": .number(pane.frame.y),
                "width": .number(pane.frame.width),
                "height": .number(pane.frame.height),
                "busy": .bool(pane.busy),
            ])
        }),
        "focusedId": snapshot.focusedId.map { JSONValue.string($0) } ?? .null,
        "maximizedId": snapshot.maximizedId.map { JSONValue.string($0) } ?? .null,
        "snaps": .array(snapshot.graph.links.map { link in
            .object([
                "paneId": .string(link.paneId),
                "edge": .string(link.edge.rawValue),
                "otherPaneId": .string(link.otherPaneId),
            ])
        }),
        // **`overlay` is the ruling that lost the settings surface its
        // case for being a plane** (Decision 30, #198), and it is a
        // measurement rather than a preference: a plane emits no key here
        // at all, so an agent would read back a perfectly normal layout
        // while the canvas sat inert behind one — or while no organisation
        // was open and there was no canvas to speak of.
        //
        // A settings pane IS in `panes` above, because it is a pane on the
        // canvas and Invariant 3 wants every pane observable. This key
        // says the second thing about it that the `panes` entry cannot:
        // that it is an overlay — at most one, never written to the layout
        // file, and not drivable by the reader.
        //
        // `null` when there is none, not an absent key. An agent that
        // cannot distinguish "no overlay" from "this build does not report
        // overlays" has to guess, and the guess that matters is the wrong
        // one.
        "overlay": overlayPayload(snapshot),
    ])
}

/// The `overlay` half of `read_layout`: which overlay pane is on the
/// canvas, or `null`.
///
/// One key per overlay kind rather than a bare id, so that a second
/// overlay kind — if one is ever ruled in — adds a key instead of changing
/// this one's type under a reader that already parses it.
private func overlayPayload(_ snapshot: LayoutSnapshot) -> JSONValue {
    guard let settings = snapshot.panes.first(where: { $0.kind == Pane.settingsKind }) else {
        return .null
    }
    return .object(["settings": .string(settings.id)])
}

private func readLayout(id: JSONRPCID, layout: LayoutStore) async -> JSONRPCMessage {
    let payload = layoutPayload(await layout.snapshot())
    let text = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return JSONRPCMessage(id: id, result: .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "structuredContent": payload,
    ]))
}

/// Wraps an action's own return value in the MCP `CallToolResult` envelope
/// — a `content` array, plus `structuredContent` when the payload is an
/// object — which is the same shape `readPane` and `readLayout` build by
/// hand, and the shape a conforming client will actually read.
///
/// **Without this, every journalled action was silent to the agent.**
/// `ActionRegistry.dispatch` returns the handler's bare payload, and
/// `handleToolsCall` put that straight into the JSON-RPC `result`. A
/// `tools/call` result with no `content` key is not a `CallToolResult`, so
/// a client renders it as "completed with no output" — which is exactly
/// what `pane_open` did, despite its description promising "Returns the new
/// pane's id" and its handler returning `{"id": "db-1"}` faithfully. An
/// agent that opened three panes and could not read back a single id
/// invented three from the titles it had chosen (`core.customers`,
/// `events.customers`, `events.events`), and every query it then ran wrote
/// its rows under a key no pane on the canvas had. That is DEFECT X again,
/// reached through the explicit `pane` parameter rather than through the
/// default — and its first cause is here, not in `db_run_query`: the agent
/// was never told the answer it asked for.
///
/// **`structuredContent` only for an object payload.** MCP declares that
/// field an object; a handler returning `.null` or a bare array would make
/// this an invalid envelope, so those travel in `content` alone. `content`
/// is the half a conforming client is guaranteed to read either way, which
/// is the same argument `readPane`'s doc comment makes.
func toolResultEnvelope(_ payload: JSONValue) -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let text = (try? encoder.encode(payload))
        .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    var envelope: [String: JSONValue] = [
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
    ]
    if case .object = payload { envelope["structuredContent"] = payload }
    return .object(envelope)
}

private func handleToolsCall(
    id: JSONRPCID,
    params: JSONValue?,
    surface: MCPSurface,
    caller: @Sendable () async -> DispatchCaller
) async -> JSONRPCMessage {
    guard case .object(let obj)? = params, case .string(let name)? = obj["name"] else {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32602, message: "Invalid params: \"tools/call\" requires a string \"name\""))
    }
    let arguments = obj["arguments"] ?? .object([:])

    // read_pane is the one tool that does not go through
    // `ActionRegistry.dispatch` (design §2.3: it is hand-written rather than
    // a projected action), so it reaches neither the write gate nor the
    // journal. Both omissions are deliberate: reading a pane changes
    // nothing, there is no mutation for the gate to refuse — a pane is
    // readable in `production` exactly as in `staging` — and the journal
    // records actions taken, not state observed.
    if name == readPaneToolName {
        return await readPane(id: id, arguments: arguments,
                              panes: surface.panes, layout: surface.layout,
                              settings: surface.settings)
    }
    if name == readLayoutToolName {
        return await readLayout(id: id, layout: surface.layout)
    }
    // The third hand-written tool, intercepted here for the reason the two
    // above are: it is not an action. It changes nothing, so there is
    // nothing for the gate to refuse, and it observes nothing, so there is
    // nothing for the journal to record — registering it would put a row in
    // the journal every time the agent reached for a tool.
    if name == permissionPromptToolName {
        return permissionPromptReply(
            id: id, arguments: arguments,
            knownActions: await surface.registry.all().map(\.name))
    }

    var confirmation: String?
    if case .string(let c)? = obj["confirmation"] {
        confirmation = c
    }

    // Bound once and reused below rather than awaited twice: the `"error"`
    // and `"uncertain"` lines the `StandardActionError` branch writes are
    // read as a pair, and `caller()` is a fresh read of mutable state
    // that could answer differently the second time.
    let judged = await caller()
    do {
        let result = try await surface.registry.dispatch(
            name: name, params: arguments, origin: .agent,
            caller: judged, confirmation: confirmation)
        return JSONRPCMessage(id: id, result: toolResultEnvelope(result))
    } catch let error as StandardActionError {
        // A mutation Wakil stopped waiting for, reached without ever
        // parking — the `confirmation` sibling was already present, which
        // today only `--dispatch`-shaped callers and tests can do. Same
        // record, same wording, same reason: see `recordUncertainMutation`.
        await recordUncertainMutation(
            error, registry: surface.registry, action: name, params: arguments, origin: .agent,
            caller: judged)
        return JSONRPCMessage(id: id, error: JSONRPCError(code: -32603, message: "\(error)"))
    } catch ActionError.needsConfirmation {
        // The gate refused for want of a confirmation the agent cannot
        // supply — `confirmation` is a sibling of `name`/`arguments` that
        // no conforming MCP client sends, and Invariant 7 means it must
        // stay that way. So the proposal parks and a human decides.
        //
        // This request is held open while that happens, which is
        // deliberate: it is the same shape as the CLI's own permission
        // prompts, and it means the agent gets the real result of the real
        // call rather than a "pending" it has to learn to poll.
        return await parkForConfirmation(
            id: id, name: name, arguments: arguments,
            surface: surface, caller: caller)
    } catch let error as ActionError {
        return JSONRPCMessage(id: id, error: jsonRPCError(for: error))
    } catch {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32603, message: "\(error)"))
    }
}

/// JSON-RPC error codes for the two outcomes that are neither a refusal nor
/// a success. Both are distinct from `-32002` ("requires confirmation") on
/// purpose: an agent told it was refused, when the truth is that nobody was
/// at the keyboard, will go looking for a permission to ask for instead of
/// simply trying again later.
private let confirmationExpiredCode = -32004
private let confirmationBusyCode = -32005

/// Parks a refused proposal, waits for a human, and re-dispatches the
/// *same* call on approval.
///
/// "Refused" is not only a mutation. `writeGate` also returns `.gate` for a
/// `.control` action from the agent targeting production
/// (`WriteGate.swift`'s `.control`/`.agent`/production row) — today, that
/// is `ctx_set_environment("production")`. Both paths land here, and both
/// must produce a `PendingMutation` the surface can render honestly: a
/// `.mutate` action's `statement` is the SQL it proposed, but a `.control`
/// action has none, so `describeProposal` renders its name and params
/// instead. `PendingMutation.statement` must never be blank — a blank
/// confirmation reads as a bug to whoever is asked to approve it, not as
/// "there was nothing to show."
///
/// **Nothing blank ever gets as far as the broker, and this is where that
/// is enforced.** `describeProposal` guarantees a non-empty string for the
/// `.control` branch; the `.mutate` branch has no such guarantee, because
/// its statement is read straight out of the caller's `arguments` and
/// `handleToolsCall` does no schema validation before dispatching. A
/// `tools/call` of `{"name":"db_run_mutation","arguments":{}}` — which any
/// socket client can send — would otherwise park a proposal with an empty
/// statement: a red plane asking a human to confirm nothing, holding its
/// place's slot in the broker until answered while every other proposal there is told
/// `.busy`. It is refused as invalid params instead, before the broker is
/// touched. `WindowModel.parkAndAwait` refuses the identical shape from ⌘K;
/// the two paths agree because the one confirmation mechanism has to.
///
/// The re-dispatch passes `arguments` unchanged rather than rebuilding them
/// from the parked projection: the operator confirmed a specific statement,
/// and anything reconstructed could differ from what they read.
///
/// **`caller` is re-read after the park, never captured across it.**
/// The gate must judge the environment as it stands at the moment of
/// confirmation, not as it stood when the proposal was made, and the park
/// is up to 120 seconds long. Only the non-production environments park at
/// all — production is `.block` — so a captured string could only ever be
/// the more permissive of the two readings: propose at `staging`, switch
/// the active context to `production` while the plane is up (⌘K still
/// works; the plane's dimming overlay does not block key equivalents),
/// confirm, and a stale `"staging"` would let a mutation run against the
/// production database that `writeGate` promises is blocked outright —
/// `wakil-db` resolves its connection from `active.json`, which by then
/// says production. Re-reading closes that: `writeGate` returns `.block`,
/// `dispatch` journals `"blocked"`, and the agent is told so.
///
/// `origin` stays `.agent` on both dispatches, and that is correct rather
/// than a compromise — the agent is who asked. The human's participation is
/// recorded by the transition itself: the journal's `gated` → `ok` pair for
/// one action cannot be produced by an agent retrying, because an agent has
/// no way to send a confirmation.
///
/// **Residual risk: a client that gives up first still gets the write.**
/// The park holds this request open until the operator answers (an agent's
/// proposal has no timeout, R1), and `Connection.consume` awaits each `handle` call to
/// completion before reading the connection's next frame (see that type's
/// doc comment) — so a `notifications/cancelled` the CLI sends after its
/// own tool-call timeout cannot even be read until this one resolves. If
/// that happens and a human approves anyway, the mutation still runs: what
/// executes is the operator's own confirmed intent, read in full and acted
/// on deliberately, so running it is not wrong. What is lost is narrower —
/// the agent that proposed it already moved on believing the call failed,
/// so it never learns the write it asked for actually happened. Restoring
/// that notice would mean this connection reading ahead of a parked
/// request, which is out of scope here; the risk is recorded rather than
/// closed.
private func parkForConfirmation(
    id: JSONRPCID,
    name: String,
    arguments: JSONValue,
    surface: MCPSurface,
    caller: @Sendable () async -> DispatchCaller
) async -> JSONRPCMessage {
    let isMutation = await surface.registry.all().first(where: { $0.name == name })?.kind == .mutate
    // A gated `.control` action (D10: `ctx_set_environment` on either side
    // of production) prefers `confirmationDescription`'s human sentence —
    // "switch the active environment to staging" — over `describeProposal`'s
    // machine-shaped `name {"json":"args"}` fallback, which is what an
    // operator asked to approve a change to the one piece of state that
    // decides whether a mutation is frightening should not have to parse.
    // `describeProposal` still answers for any action `confirmationDescription`
    // doesn't recognise, so nothing not yet named there loses its
    // description.
    // A mutation's own statement (SQL, an HTTP request) when it has one; a git write the agent price
    // gates (3a-iv) has none, and is described in a sentence instead.
    // 3c-ii: an action's own proposal comes first — its statement and what the plane asks —
    // read in the parker's own canvas (ruling C5b). Without one, nothing below changes.
    let parker = await caller()
    let own = await surface.registry.proposal(name: name, params: arguments, caller: parker)
    let ownStatement = own == nil && isMutation ? stringArgument(arguments, "statement") : nil
    let statement = own?.statement ?? ownStatement
        ?? (isMutation ? (confirmationDescription(action: name, params: arguments) ?? "")
            : (confirmationDescription(action: name, params: arguments)
                ?? describeProposal(action: name, arguments: arguments)))
    guard !statement.isEmpty else {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32602,
            message: "\(name): no statement to confirm — nothing was parked and nothing ran. "
                + "Send a non-empty \"statement\" argument."))
    }
    let ask = own?.ask ?? .change
    let proposal = PendingMutation(
        action: name,
        params: arguments,
        database: stringArgument(arguments, "database"),
        statement: statement,
        affectsEveryRow: ownStatement.map(mutationAffectsEveryRow) ?? false,
        origin: .agent,
        // The session's own place, so it waits there beside other places' proposals.
        place: parker.place,
        conversation: parker.conversation,
        ask: ask)

    switch await surface.confirmations.request(proposal) {
    case .approved:
        // Read afresh, not captured before the park — see this function's
        // doc comment for the production case that makes the difference —
        // and then bound, so the `"error"`/`"uncertain"` pair below cannot
        // disagree about which environment was judged.
        let judged = await caller()
        do {
            let result = try await surface.registry.dispatch(
                name: name, params: arguments, origin: .agent,
                caller: judged, confirmation: "confirm")
            return JSONRPCMessage(id: id, result: toolResultEnvelope(result))
        } catch let error as ActionError {
            return JSONRPCMessage(id: id, error: jsonRPCError(for: error))
        } catch {
            await recordUncertainMutation(
                error, registry: surface.registry, action: name, params: arguments, origin: .agent,
                caller: judged)
            return JSONRPCMessage(id: id, error: JSONRPCError(code: -32603, message: "\(error)"))
        }
    case .cancelled:
        // Don't Allow on a site question is about the site, not this one change: say so, so the
        // agent stops asking there rather than retrying the act.
        if case .site(let site) = ask {
            return JSONRPCMessage(id: id, error: JSONRPCError(
                code: -32002,
                message: "\(name): the operator did not allow the agent on \(site) — "
                    + "don't act there again unless they ask."))
        }
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32002, message: "\(name) requires confirmation"))
    case .expired:
        // Unreachable while an agent's proposal has no timeout (R1); kept so the switch
        // stays exhaustive and the code means one thing if that ever changes.
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: confirmationExpiredCode,
            message: "\(name): the operator did not confirm in time — propose it again"))
    case .busy:
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: confirmationBusyCode,
            message: "\(name): another confirmation is already waiting — try again once it is answered"))
    }
}

private func stringArgument(_ arguments: JSONValue, _ key: String) -> String? {
    guard case .object(let object) = arguments, case .string(let value)? = object[key] else {
        return nil
    }
    return value
}

/// Renders a gated non-mutation proposal for the confirmation surface,
/// since it has no SQL statement to show: the action name, followed by its
/// params as compact JSON — e.g. `ctx_set_environment {"name":"production"}`.
/// `.sortedKeys` so the same proposal renders identically twice running.
/// Falls back to the bare action name for empty params rather than
/// appending `{}`, which would read as a rendering bug rather than "no
/// params". Never returns an empty string: that is the one property
/// `parkForConfirmation` depends on this function for.
private func describeProposal(action: String, arguments: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard case .object(let object) = arguments, !object.isEmpty,
        let encoded = try? encoder.encode(arguments),
        let text = String(data: encoded, encoding: .utf8)
    else {
        return action
    }
    return "\(action) \(text)"
}

/// Answers `read_pane` from `panes` — the whole of Invariant 3 ("the agent
/// can read any pane's state") and of Decision 19's "the agent reaches panes
/// only through Wakil's own MCP surface".
///
/// Three decisions are recorded here, because each had a plausible
/// alternative.
///
/// **The result is an MCP tool-result envelope, not the bare snapshot.**
/// `PaneStore.snapshot` returns
/// `{"columns":…,"rows":…,"rowCount":N,"truncated":Bool}`, and
/// returning that as the JSON-RPC `result` would be shorter — but the peer
/// on the other end of this socket is a real MCP client (the `claude` CLI,
/// via the shim), and what it expects back from `tools/call` is a
/// `CallToolResult`: a `content` array, optionally `structuredContent`, and
/// `isError` when something went wrong. Every other tool in the shipped
/// action set already has that shape without this file doing anything: each
/// of `registerStandardActions`' eight returns the Go server's own
/// `CallToolResult` unchanged — the shape `callChecked` and `ContextStore`
/// both read (`structuredContent` for the typed payload, `content[0].text`
/// for the message) — and `handle` passes a dispatch result straight into
/// the JSON-RPC `result`. `read_pane` matching them means one convention
/// across the whole surface rather than one tool with a private one.
///
/// Both halves are populated rather than just one, and they are not
/// co-equal: `content` is the half that is guaranteed to be read.
/// `structuredContent` is the snapshot **verbatim**, so the tool and
/// `WindowModel.refreshPanes` demonstrably serve the same object for the same
/// pane id — no re-shaping that could drift from what the window draws. That
/// claim is now true of the row *order* too, which it was not until the 2c-i
/// final review: `PaneStore.snapshot` applies the recorded sort itself, so
/// the rows here and the rows on screen are one sequence produced once
/// rather than two sorted in two places (Finding 1).
/// `content` carries the same snapshot as JSON text for two independent
/// reasons, either of which alone would be enough. First, it is what a model
/// actually sees: the probe (`docs/wakil/phase-2a-probe.md` §4) recorded MCP
/// `tool_result` content arriving in the transcript as a **JSON string**, so
/// a result with `structuredContent` alone and an empty `content` would
/// reach the model as nothing at all. Second, `handle`'s `initialize` reply
/// above advertises `protocolVersion: "2024-11-05"`, and `structuredContent`
/// was introduced in the 2025-06-18 revision — so at the version this server
/// declares on the wire, `content` is the only half a conforming client is
/// obliged to read at all. Sending the newer field anyway is harmless (MCP
/// clients ignore fields they do not know) and a client that does understand
/// it gets the typed payload; what it must not become is the *only* place
/// the answer lives. `.sortedKeys` so the same pane serialises identically
/// twice running. `isError` is omitted rather than set to `false`: the MCP
/// convention is that its absence means success, `callChecked` and
/// `ContextStore` both test only for `true`, and a field no reader branches
/// on is one more thing to keep true.
///
/// **An unknown `paneId` answers `kind: null`, not an error, and the
/// argument for that is not the one that used to be here.** The old
/// reasoning was that `PaneStore` has no registry of ids, so "unknown" and
/// "written to, then empty" are genuinely the same state. That is true of
/// `PaneStore` and **false of the window**: `LayoutStore` is a registry of
/// open panes and has been since 2b-i, which is why this function now
/// takes it. What was actually missing was never an error but a
/// discriminator, and `kind: null` supplies it without making `read_pane`
/// fail on the honest case the original reasoning protected — a freshly
/// launched window whose `db` pane draws "no rows" before any query, which
/// answers `kind: "db"` with an empty payload.
///
/// **Erroring is now genuinely available and is still declined**, on two
/// grounds. An MCP `isError` costs the agent a turn and teaches it nothing
/// the field does not. And a pane can close between the `read_layout` that
/// named it and the `read_pane` that asks — a race that would turn a
/// correct sequence of calls into a failure.
///
/// **`truncated` travels with the snapshot** and is the reason it is worth
/// serving one at all rather than letting the agent re-run the query
/// itself. `wakil-db` caps a query at 500 rows unless the caller names a
/// limit of its own between 1 and 1000 (`wakilcore.clampReadLimit`), and the
/// window's *Run query* control names none — so a pane holding 500 rows of
/// a 5,000-row table is the ordinary case, not an exotic one. Without the
/// flag, an agent asked "how many customers are there?" reads
/// `rowCount: 500` and answers 500.
///
/// **A missing or non-string `paneId` is `-32602`**, the JSON-RPC
/// invalid-params code this file already uses for a `tools/call` with no
/// string `name`. That is a malformed request rather than a pane that
/// happens to be empty, and the two must not answer alike: an agent that
/// sent `{}` and got an empty pane back would read it as "the pane is
/// empty".
private func readPane(
    id: JSONRPCID, arguments: JSONValue, panes: PaneStore, layout: LayoutStore,
    settings: @Sendable () async throws -> JSONValue
) async -> JSONRPCMessage {
    // `paneId` is the declared, documented spelling; `pane` is honoured
    // silently for the agent that learned it from every other terminal and
    // pane-content tool (D5). `paneId` wins if both are present.
    guard case .object(let obj) = arguments,
        case .string(let paneId)? = obj["paneId"] ?? obj["pane"]
    else {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32602, message: "Invalid params: \"read_pane\" requires a string \"paneId\""))
    }

    // The discriminator, read off the registry that actually holds one.
    let kind = await layout.snapshot().panes.first { $0.id == paneId }?.kind

    // **The settings pane's contents are not in `PaneStore`**, and that is
    // the ruling rather than an omission: it caches nothing at all, so
    // there is nothing to store. Every read of it is a fresh read of disk
    // (Decision 30), which is what makes staleness structurally impossible
    // instead of merely unlikely — and it is why an answer here can fail
    // in a way a `PaneStore` lookup never does.
    //
    // **Agent-readable, operator-driven.** This is the whole of the
    // asymmetry 2e introduces: the snapshot stays whole — the agent sees
    // exactly the configuration the operator sees — while every action
    // that changes any of it is operator-only.
    let payload: JSONValue
    if kind == Pane.settingsKind {
        payload = await settingsPaneSnapshotJSON(settings)
    } else {
        // **Api's `readPane` reads `apiSources()` itself, inside the store,
        // and #192 is why it must.** An omitted lookup would make every
        // bound value read as from a closed pane — `read_pane` would tell
        // the agent that the value it had just bound came from a closed
        // pane, with `resolves: false` and no preview.
        payload = await panes.readPane(paneId: paneId, kind: kind)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let encoded = try? encoder.encode(payload) else {
        // Not reachable from any snapshot a real pane can hold — every
        // value in one came from decoded JSON — but the alternative to
        // saying so is a fabricated or truncated `content` block, which is
        // the failure mode this whole tool exists to avoid.
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32603, message: "read_pane could not encode pane \"\(paneId)\" as JSON"))
    }

    return JSONRPCMessage(id: id, result: .object([
        "content": .array([.object([
            "type": .string("text"),
            "text": .string(String(decoding: encoded, as: UTF8.self)),
        ])]),
        "structuredContent": payload,
    ]))
}

/// A settings pane's snapshot, in the shape every other pane's snapshot
/// takes: a `kind`, a `failure` that is `null` when there is none, and the
/// keys of that kind.
///
/// **A failure is reported in `failure` rather than as a JSON-RPC error**,
/// for the reason every other pane's is: a pane that could not be filled
/// is a pane, and an agent that gets a protocol error back cannot tell it
/// apart from a malformed request. `configuration` is `null` beside it, so
/// there is no half-read tree to mistake for a complete one.
private func settingsPaneSnapshotJSON(
    _ settings: @Sendable () async throws -> JSONValue
) async -> JSONValue {
    do {
        let tree = try await settings()
        return .object([
            "kind": .string(Pane.settingsKind),
            "failure": .null,
            // Under its own key rather than spread across the top level,
            // unlike the data surface's arm: this is one nested document
            // read whole from `wakil-ctx`, not a set of pane properties,
            // and flattening it would put `org`, `projects` and
            // `providers` in the same namespace as `kind` and `failure`.
            "configuration": tree,
        ])
    } catch {
        return .object([
            "kind": .string(Pane.settingsKind),
            "failure": .string("settings could not be read (\(error))"),
            "configuration": .null,
        ])
    }
}

/// Maps each case `ActionRegistry.dispatch` can throw to a distinct JSON-RPC
/// error code, so a caller (or a test) can tell "no such action" apart from
/// "this action exists but was refused" without parsing the message string —
/// mirroring the same distinction `ActionError`'s own doc comment draws.
private func jsonRPCError(for error: ActionError) -> JSONRPCError {
    switch error {
    case .unknown(let name):
        return JSONRPCError(code: -32601, message: "Unknown action: \(name)")
    case .needsConfirmation(let name):
        return JSONRPCError(code: -32002, message: "\(name) requires confirmation")
    case .blockedInProduction(let name):
        return JSONRPCError(code: -32003, message: "\(name) is blocked in production")
    case .callerGone(_, let reason):
        return JSONRPCError(code: -32006, message: reason)
    }
}

/// Listens on a unix domain socket and answers every JSON-RPC frame it reads
/// with `handle`. This is the process-local end of the transport
/// `--mcp-shim` (in `Shim.swift`) pipes stdio to and from; see the design's
/// §2.2 for why the split exists (the CLI's MCP client only ever spawns a
/// stdio server, never connects out to one already running, and Wakil.app is
/// already running).
///
/// The socket is created at mode `0700` — filesystem permissions are this
/// design's entire access control, replacing a bearer token (§2.2: "There is
/// no secret to generate, pass, or compare") — after unlinking any stale file
/// left at `socketPath` by a previous run, since `bind` fails with
/// `EADDRINUSE` on a path that already exists.
public actor MCPSocketServer {
    private let surface: MCPSurface
    private let socketPath: String
    private let caller: @Sendable () async -> DispatchCaller
    /// What the window shows, for `initialize`'s `_meta` (`initializeMeta`).
    private let screen: (@Sendable () async -> ScreenShown?)?

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?

    /// `surface` rather than a `registry` plus a `panes` parameter, and set
    /// once here rather than passed per call: what this server answers from
    /// cannot change between one frame and the next, so it is construction
    /// data, not request data. `caller` is the deliberate
    /// exception — the caller's place *does* change while the server is
    /// up (`ctx_set_environment`), so it is a closure read at each point
    /// the gate needs it rather than a string captured once. It is passed
    /// down to `handle` still as a closure, and for a gated request it is
    /// read twice: once for the first dispatch, and again after the park,
    /// because the operator may have moved the active context in between.
    public init(
        surface: MCPSurface,
        socketPath: String,
        caller: @escaping @Sendable () async -> DispatchCaller,
        screen: (@Sendable () async -> ScreenShown?)? = nil
    ) {
        self.surface = surface
        self.socketPath = socketPath
        self.caller = caller
        self.screen = screen
    }

    public func start() async throws {
        _ = ignoreSIGPIPEProcessWide

        unlink(socketPath)   // best-effort: ENOENT (nothing was there) is fine

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPTransportError.posixFailure(call: "socket", path: socketPath, errnoValue: errno)
        }

        var (addr, len) = try makeUnixSocketAddress(path: socketPath)
        // `bind()` creates the socket file at whatever mode the process
        // umask yields (commonly 0644/0755) — a separate `chmod(0700)` after
        // the fact leaves a window in which another local user could connect
        // before the tightened mode lands, and filesystem permissions are
        // this design's *entire* access control (§2.2: "There is no secret
        // to generate, pass, or compare"). Narrowing the umask around the
        // `bind()` call instead makes the file's permissions 0700 from the
        // instant it exists, not retrofitted. Verified directly on this
        // machine: `stat` on the socket immediately after this block reports
        // mode 0700 with no separate `chmod` call. There is no `await`
        // between `umask(0o077)` and restoring it, so this actor-isolated
        // method never yields while the process-wide umask is narrowed —
        // the remaining exposure is only to file creation on *other*
        // threads racing this exact syscall, an inherent limitation of
        // `umask` being process-wide rather than a defect specific to this
        // code.
        let previousUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        umask(previousUmask)
        guard bindResult == 0 else {
            let failedErrno = errno
            close(fd)
            throw MCPTransportError.posixFailure(call: "bind", path: socketPath, errnoValue: failedErrno)
        }

        guard listen(fd, 16) == 0 else {
            let failedErrno = errno
            close(fd)
            unlink(socketPath)
            throw MCPTransportError.posixFailure(call: "listen", path: socketPath, errnoValue: failedErrno)
        }

        listenFD = fd
        startAcceptLoop(fd: fd)
    }

    /// Spawns a dedicated `Thread` blocking on `accept()` — the same reason
    /// `MCPClient`'s drain threads are plain `Thread`s and not `Task`s (see
    /// that type's `startStdoutDrainThread` doc comment): a blocking syscall
    /// on the Swift concurrency cooperative pool risks starving every
    /// actor-isolated and unstructured `Task` in the process. Each accepted
    /// connection gets its own `Connection` actor and its own read thread,
    /// spawned via `Task` so accepting the next connection is never blocked
    /// on serving this one.
    private func startAcceptLoop(fd: Int32) {
        let surface = self.surface
        let caller = self.caller
        let screen = self.screen
        let thread = Thread {
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 {
                    // Either `stop()` closed the listening socket (the
                    // expected shutdown path) or a transient accept()
                    // failure. Either way there is nothing more this loop
                    // can do but stop; it never retries on the same fd.
                    return
                }
                disableSIGPIPE(onSocket: clientFD)
                let connection = Connection(fd: clientFD, surface: surface, caller: caller, screen: screen)
                Task { await connection.run() }
            }
        }
        thread.name = "MCPSocketServer.accept"
        thread.start()
        acceptThread = thread
    }

    /// Closes the listening socket and unlinks the path, which is what makes
    /// the blocked `accept()` in `startAcceptLoop`'s thread return and that
    /// thread exit. Connections already accepted are not interrupted: they
    /// keep running until their own peer reaches EOF.
    public func stop() async {
        guard listenFD >= 0 else { return }
        close(listenFD)
        unlink(socketPath)
        listenFD = -1
    }
}

/// One accepted MCP client connection. Owns the file descriptor and the
/// `FrameReader` that reassembles frames from it. A dedicated `Thread` blocks
/// on reads — mirroring `MCPClient`'s stdout-drain thread, for the same
/// blocking-call-off-the-cooperative-pool reason — and yields each chunk into
/// a serial `AsyncStream` that `consume` drains one at a time, so
/// `FrameReader.push` (mutating, and latching per its own doc comment) sees
/// the chunks in the order they were read, and every request is answered in
/// that same order: one `ingest` call runs to completion before the next
/// begins, so no two of them can ever interleave at an `await`.
///
/// Not "each request is answered before the next is decoded", which an
/// earlier version of this comment claimed and this code has never done:
/// `ingest` calls `reader.push` once per chunk, which decodes *every*
/// complete message in that chunk, and only then walks the resulting array
/// answering them. Two short requests arriving in a single read are therefore
/// both decoded before either is answered. What holds is the weaker and
/// sufficient property above — read order is answer order, and nothing
/// interleaves — not an alternation of decoding and answering.
///
/// The chunks used to go over one unstructured `Task { await self.ingest(data) }`
/// apiece, which guaranteed neither. Two failures followed, both measured
/// directly on this machine against a client sending 40 requests of 60 KB each
/// (large enough that a single frame always spans several reads) — 4 or 5 of
/// every 5 such connections failed, in every one of eight runs: replies came
/// back out of request order (`…, 2, 4, 3, 5, …`), because `ingest` is `async`
/// and a second chunk's `Task` could run while the first was suspended
/// awaiting `caller`/`handle`; and, more destructively, whole
/// connections went silent partway through — 0, 2, 4, 18 and 26 replies of
/// the 40 expected — because two chunks of one frame arrived at `FrameReader`
/// inverted, spliced into JSON that could not decode, and latched the reader
/// dead for the rest of the connection.
///
/// Nothing outside this type holds a reference to it — `startAcceptLoop`
/// creates one per accepted connection and does not keep it in any array — so
/// the `Task` `run()` starts to consume that stream captures `self`
/// *strongly*, not weakly, to keep the actor (and its `fh`, whose
/// `closeOnDealloc: true` would close the socket the moment this actor
/// deallocates) alive for exactly as long as there are chunks left to serve.
/// That consuming task's own strong reference is the only thing keeping this
/// actor alive; it is released when the stream finishes (peer EOF) and its
/// backlog has been drained, which is also the only point at which this
/// connection is done being useful. Measured directly on this machine, back
/// when the read thread itself was the strong reference: with a weak capture
/// there, the very next write after the first successful exchange raised
/// SIGPIPE and killed the whole process (exit code 141) — the accepted socket
/// had already been closed by `fh`'s deinit before a second message was even
/// sent, because nothing else was keeping this actor alive past the end of
/// the `Task` that called `run()`.
///
/// **One request can now hold the whole connection open far longer than any
/// of the above envisioned.** `handle` (via `handleToolsCall` →
/// `parkForConfirmation`) suspends until the operator answers — an agent's
/// proposal has no timeout (R1) — while a gated proposal waits for a human.
/// Because `ingest` runs to completion before `consume` reads this
/// connection's next chunk, nothing on this connection — not a `ping`, not
/// a `notifications/cancelled` for the very request that is parked — can be
/// read until that one resolves. A client that gives up first and closes
/// or moves on cannot retract what it already sent; see
/// `parkForConfirmation`'s doc comment for what that costs.
private actor Connection {
    private let fh: FileHandle
    private let surface: MCPSurface
    private let caller: @Sendable () async -> DispatchCaller
    private let screen: (@Sendable () async -> ScreenShown?)?
    private var reader = FrameReader()
    private var poisoned = false

    init(
        fd: Int32, surface: MCPSurface, caller: @escaping @Sendable () async -> DispatchCaller,
        screen: (@Sendable () async -> ScreenShown?)?
    ) {
        self.fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.surface = surface
        self.caller = caller
        self.screen = screen
    }

    func run() {
        let fh = self.fh
        // `.unbounded` for the reason the other two chunk streams in this
        // package use it (`MCPClient.startStdoutDrainThread`,
        // `ClaudeCodeCLIHarness.startStdoutDrainThread`): every bounded
        // `AsyncStream` policy drops elements once full, and a dropped chunk
        // here is not a lost message but a hole punched in the middle of a
        // byte stream `FrameReader` is reassembling — it would splice one
        // frame into another and latch the reader dead.
        //
        // Unlike those two, though, this site keeps a residual the shared
        // argument does not cover. There, the backlog is self-limiting: the
        // harness's consumer only parses, and `MCPClient`'s only pushes into
        // a `FrameReader` whose own buffer is capped. Here `ingest` awaits a
        // *caller-supplied* `caller` closure and `handle()`, so a fast
        // local peer facing a slow provider accumulates raw socket bytes with
        // no bound at all — "a session's worth of events" is not the ceiling
        // it is for the harness. Accepted as-is rather than papered over: the
        // only peers are local, the alternative (dropping bytes) is strictly
        // worse than growing memory, and back-pressure would have to be
        // applied by not reading the socket rather than by a buffering
        // policy. Recorded so the next reader does not mistake the shared
        // reasoning above for a complete one.
        let (chunks, chunkSink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        // See this type's doc comment for why this capture is strong, and for
        // the two failures the per-chunk `Task` this replaces produced.
        Task { await self.consume(chunks) }
        let thread = Thread {
            while true {
                let data = fh.availableData
                if data.isEmpty {
                    // Peer EOF. Finishing rather than abandoning the stream is
                    // what lets `consume` serve the requests still queued
                    // behind this read before it lets go of the connection.
                    chunkSink.finish()
                    return
                }
                chunkSink.yield(data)
            }
        }
        thread.name = "MCPSocketServer.connection"
        thread.start()
    }

    /// Drains the chunk stream in yield order, one `ingest` at a time. Being
    /// its single consumer, and awaiting each `ingest` to completion before
    /// taking the next chunk, is what keeps `reader.push` in read order and
    /// keeps two overlapping `ingest` calls from interleaving their replies at
    /// an `await`.
    private func consume(_ chunks: AsyncStream<Data>) async {
        for await chunk in chunks {
            await ingest(chunk)
        }
    }

    private func ingest(_ data: Data) async {
        guard !poisoned else { return }
        let messages: [JSONRPCMessage]
        do {
            messages = try reader.push(data)
        } catch {
            // FrameReader latches on error (see its doc comment): every
            // subsequent push on this same reader would throw the identical
            // error, so this connection stops reading rather than calling
            // push again — exactly the "treat a push throw as fatal for
            // that connection" rule this task's brief states.
            poisoned = true
            return
        }
        for message in messages {
            // The provider is handed to `handle` rather than read here into
            // a string: a gated proposal parks inside `handle` for up to
            // 120 seconds, and the environment the gate judges on the way
            // out must be the one that is active *then*. See `handle`'s doc
            // comment.
            guard let reply = await handle(message, surface: surface, caller: caller, screen: screen)
            else { continue }
            if let frame = try? encodeFrame(reply) {
                try? fh.write(contentsOf: frame)
            }
        }
    }
}
