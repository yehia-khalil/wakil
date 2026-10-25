import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The one line `wakil-connect` sends before it runs a gated tool call on a connection
/// (`cmd/wakil-connect/gate.go`'s `approvalRequest`): the agent's own arguments, already
/// canonical JSON, and the gate's flags for the tool. It never carries a credential.
public struct ConnectionCallRequest: Sendable, Equatable, Codable {
    public let connection: String
    public let tool: String
    public let arguments: JSONValue
    public let allowed: Bool
    public let readOnly: Bool
    public let locked: Bool

    public init(connection: String, tool: String, arguments: JSONValue, allowed: Bool, readOnly: Bool, locked: Bool) {
        self.connection = connection
        self.tool = tool
        self.arguments = arguments
        self.allowed = allowed
        self.readOnly = readOnly
        self.locked = locked
    }

    /// The request as the plane's `params` and the journal's: whole, arguments included — they
    /// are the agent's own words, not secrets.
    public var params: JSONValue {
        .object([
            "connection": .string(connection), "tool": .string(tool), "arguments": arguments,
            "allowed": .bool(allowed), "readOnly": .bool(readOnly), "locked": .bool(locked),
        ])
    }
}

/// The app's answer: run the call, or refuse it with the sentence the agent reads.
public enum ConnectionCallDecision: Equatable, Sendable {
    case allow
    case deny(String)
}

/// The rule for one connection call, before anyone is asked: an allowed tool that is not locked
/// runs when it only reads, or when the turn was typed. A spoken turn never runs a write unasked
/// (Invariant 7), and a locked tool — one its server marks destructive — always asks. Nil is
/// "ask the operator"; the rule itself never refuses.
public func connectionCallDecision(_ r: ConnectionCallRequest, spoken: Bool) -> ConnectionCallDecision? {
    r.allowed && !r.locked && (r.readOnly || !spoken) ? .allow : nil
}

/// The approval socket beside an agent socket: `<directory>/<session id>-approval.sock`, for the
/// agent socket `<directory>/wakil-<session id>.sock` (`agentSocketPath`).
///
/// **Not `<agent socket path>-approval.sock`.** That is 14 bytes longer than the agent socket's
/// path, which is the per-user temporary directory (48 characters) plus 48 — 110 of `sun_path`'s
/// 103, so it would never bind. Dropping the `wakil-` prefix and the agent socket's own `.sock`
/// keeps the suffix and costs 3 bytes: 99, under the limit with the directory at up to 52. A path
/// in any other shape keeps its directory and has `-approval.sock` after its name less `.sock`.
public func approvalSocketPath(forAgentSocket path: String) -> String {
    let url = URL(fileURLWithPath: path)
    var name = url.deletingPathExtension().lastPathComponent
    if name.hasPrefix("wakil-") { name.removeFirst("wakil-".count) }
    return url.deletingLastPathComponent().appendingPathComponent("\(name)-approval.sock").path
}

/// Answers `wakil-connect` for one conversation, on a socket of its own: the conversation is the
/// socket the request came on, never anything the request says. One request per connection —
/// one JSON line in, one JSON line back (`{"decision":"allow"}` or
/// `{"decision":"deny","message":"…"}`), then the connection closes.
///
/// A call `connectionCallDecision` lets through is allowed at once; any other is parked on the
/// permission plane (`ConfirmationBroker`) in this conversation's slot, and the operator's answer
/// is the decision. **Nothing a peer sends can approve anything**: the request's flags only ever
/// narrow what runs unasked, and an approval comes only from the broker. Every decision is
/// journalled (`journal`, outcome `allowed`, `asked-approved`, `asked-declined`, `asked-timeout`,
/// `asked-busy`, or `conversation-ended` for a request after `stop`).
///
/// The socket is created owner-only and set to mode 0600 before it listens, after unlinking a
/// stale file at the path. A line over 1 MiB is refused unread.
/// Each connection is read on a thread of its own, so a request waiting on the operator holds
/// nothing else up; two waits in one conversation share its one slot, and the second is refused.
public actor ConnectionApprovalServer {
    /// The longest request line read: an agent's arguments are text, and a megabyte of them is
    /// past anything the operator could read on the plane.
    static let maxLineBytes = 1 << 20
    /// How much of the arguments the plane's statement shows. Display only: the whole request is
    /// in the proposal's `params` and the journal.
    static let statementArgumentsLimit = 300

    private let socketPath: String
    private let place: Place
    private let conversation: String
    private let broker: ConfirmationBroker
    private let spoken: @Sendable () async -> Bool
    private let journal: @Sendable (ConnectionCallRequest, String) async -> Void

    private var listenFD: Int32 = -1
    private var stopped = false

    /// `spoken` is read at each request: whether this conversation's current turn came from
    /// speech. `journal` records each decision with its outcome.
    public init(
        socketPath: String, place: Place, conversation: String, broker: ConfirmationBroker,
        spoken: @escaping @Sendable () async -> Bool,
        journal: @escaping @Sendable (ConnectionCallRequest, String) async -> Void
    ) {
        self.socketPath = socketPath
        self.place = place
        self.conversation = conversation
        self.broker = broker
        self.spoken = spoken
        self.journal = journal
    }

    public func start() async throws {
        _ = ignoreSIGPIPEProcessWide
        unlink(socketPath)   // a stale file from an earlier run; ENOENT is fine

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPTransportError.posixFailure(call: "socket", path: socketPath, errnoValue: errno)
        }
        var (addr, len): (sockaddr_un, socklen_t)
        do {
            (addr, len) = try makeUnixSocketAddress(path: socketPath)
        } catch {
            close(fd)
            throw error
        }
        // Owner-only from the instant the file exists (0700, as `MCPSocketServer.start` binds),
        // then 0600 before anything can connect. Not `umask(0o177)`: the umask is process-wide,
        // and a directory another thread created meanwhile would lose its owner's execute bit.
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
        guard chmod(socketPath, 0o600) == 0 else {
            let failedErrno = errno
            close(fd)
            unlink(socketPath)
            throw MCPTransportError.posixFailure(call: "chmod", path: socketPath, errnoValue: failedErrno)
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

    /// Closes the listening socket and unlinks the path. A request read after this — one already
    /// connected — is refused: its conversation has ended.
    public func stop() {
        stopped = true
        guard listenFD >= 0 else { return }
        close(listenFD)
        unlink(socketPath)
        listenFD = -1
    }

    /// A blocking `accept` loop on a thread of its own (`MCPSocketServer.startAcceptLoop`'s
    /// reason), and a thread per connection to read its one line.
    private nonisolated func startAcceptLoop(fd: Int32) {
        let thread = Thread { [self] in
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { return }   // `stop` closed it
                disableSIGPIPE(onSocket: clientFD)
                let reader = Thread { [self] in serve(clientFD) }
                reader.name = "ConnectionApprovalServer.connection"
                reader.start()
            }
        }
        thread.name = "ConnectionApprovalServer.accept"
        thread.start()
    }

    /// Reads one line from `fd`, answers it, writes the answer and closes. Runs on its
    /// connection's thread; the answer is awaited off it.
    private nonisolated func serve(_ fd: Int32) {
        let line = Self.readLine(fd)
        Task {
            let decision: ConnectionCallDecision
            if let line {
                decision = await answer(line: line)
            } else {
                decision = .deny("The approval request was over 1 MiB, so Wakil did not read it: nothing was sent.")
            }
            Self.write(decision, to: fd)
            close(fd)
        }
    }

    /// Up to the first newline, or the end of the stream; nil past `maxLineBytes`.
    private static func readLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return buffer }
            if let newline = chunk[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(contentsOf: chunk[0..<newline])
                return buffer.count > maxLineBytes ? nil : buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxLineBytes { return nil }
        }
    }

    private static func write(_ decision: ConnectionCallDecision, to fd: Int32) {
        var object: [String: String]
        switch decision {
        case .allow: object = ["decision": "allow"]
        case .deny(let message): object = ["decision": "deny", "message": message]
        }
        guard var bytes = try? JSONEncoder().encode(object) else { return }
        bytes.append(UInt8(ascii: "\n"))
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// One line's decision: a line that is not a request is refused.
    func answer(line: Data) async -> ConnectionCallDecision {
        guard let request = try? JSONDecoder().decode(ConnectionCallRequest.self, from: line) else {
            return .deny("Wakil could not read the approval request: nothing was sent.")
        }
        return await answer(request)
    }

    /// One request's decision, journalled.
    func answer(_ request: ConnectionCallRequest) async -> ConnectionCallDecision {
        let call = "\(request.tool) on connection \(request.connection)"
        let ended = ConnectionCallDecision.deny(
            "This conversation has ended in Wakil, so \(call) was not run: nothing was sent.")
        guard !stopped else {
            await journal(request, "conversation-ended")
            return ended
        }
        if let decision = connectionCallDecision(request, spoken: await spoken()) {
            await journal(request, "allowed")
            return decision
        }
        let proposal = PendingMutation(
            action: "connection_call", params: request.params, database: nil,
            statement: Self.statement(request), affectsEveryRow: false,
            origin: .agent, place: place, conversation: conversation)
        switch await broker.request(proposal) {
        case .approved:
            await journal(request, "asked-approved")
            return .allow
        case .cancelled:
            await journal(request, "asked-declined")
            // A stop cancels what its conversation had parked (`cancelAgentProposal`).
            if stopped { return ended }
            return .deny("The operator declined \(call) in Wakil: nothing was sent.")
        case .expired:
            await journal(request, "asked-timeout")
            return .deny("\(call) timed out waiting for the operator to approve it in Wakil: nothing was sent.")
        case .busy:
            await journal(request, "asked-busy")
            return .deny("Another call in this conversation is already waiting for the operator in Wakil, "
                + "so \(call) was not asked: nothing was sent. Try it again once that one is answered.")
        }
    }

    /// `<connection> · <tool>(<arguments, one line>)`, the arguments cut at
    /// `statementArgumentsLimit` characters. JSON encoding escapes every newline, so it is one line.
    static func statement(_ request: ConnectionCallRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var arguments = (try? encoder.encode(request.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        if arguments.count > statementArgumentsLimit {
            arguments = String(arguments.prefix(statementArgumentsLimit)) + "…"
        }
        return "\(request.connection) · \(request.tool)(\(arguments))"
    }
}
