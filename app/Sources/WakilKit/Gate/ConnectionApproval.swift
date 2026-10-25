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


/// The sentence a conversation's status shows when its approval socket would not start.
public func approvalSocketFailure(path: String, error: any Error) -> String {
    "approval socket \(path): \(error) — connection calls that need the operator's approval are refused this session"
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
/// `asked-busy`, or `conversation-ended` for a request the server's `stop` overtook).
///
/// The socket is created owner-only and set to mode 0600 before it listens, after unlinking a
/// stale file at the path. A line over 1 MiB, or one not sent within `readTimeout`, is refused.
/// Each connection is read on a thread of its own, so a request waiting on the operator holds
/// nothing else up; past `maxConnections` open at once, a new one is closed unread. Two waits in
/// one conversation share its one slot, and the second is refused.
///
/// **`stop` ends everything the server holds**: what it parked on the broker is cancelled (and
/// answered "ended"), and every open connection's read side is shut, so a peer still sending is
/// answered and closed rather than read for ever.
public actor ConnectionApprovalServer {
    /// The longest request line read: an agent's arguments are text, and a megabyte of them is
    /// past anything the operator could read on the plane.
    static let maxLineBytes = 1 << 20
    /// How long a connection has to send its line: `wakil-connect` writes it at once.
    static let readTimeout: TimeInterval = 10
    /// Connections open at once; `wakil-connect` opens one per call.
    static let maxConnections = 16
    /// How much of the arguments the plane's statement shows. Display only: the whole request is
    /// in the proposal's `params` and the journal.
    static let statementArgumentsLimit = 300

    private let socketPath: String
    private let place: Place
    private let conversation: String
    private let broker: ConfirmationBroker
    private let spoken: @Sendable () async -> Bool
    private let journal: @Sendable (ConnectionCallRequest, String) async -> Void
    private nonisolated let connections = OpenConnections(
        limit: ConnectionApprovalServer.maxConnections, readTimeout: ConnectionApprovalServer.readTimeout)

    private var listenFD: Int32 = -1
    private var stopped = false
    /// The ids of the proposals this server has parked and not yet had answered.
    private var waiting: Set<String> = []

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

    /// TEST-ONLY: a shorter wait for the request line.
    nonisolated func setReadTimeoutForTesting(_ seconds: TimeInterval) { connections.readTimeout = seconds }

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

    /// Closes the listening socket and unlinks the path; cancels what this server parked, and
    /// shuts the read side of every open connection. Anything answered after this is refused:
    /// its conversation has ended.
    public func stop() {
        stopped = true
        connections.shutAll()
        for id in waiting {
            Task { await self.cancelUntilAnswered(id) }
        }
        guard listenFD >= 0 else { return }
        close(listenFD)
        unlink(socketPath)
        listenFD = -1
    }

    /// Cancels proposal `id` until its request returns. Once is not enough: `stop` can run after
    /// `answer` has suspended on its way into `broker.request` but before the broker parked it,
    /// and a cancel that lands first finds nothing — the proposal would then park with no server
    /// left to answer for it.
    private func cancelUntilAnswered(_ id: String) async {
        while waiting.contains(id) {
            await broker.cancel(id: id)
            if waiting.contains(id) { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    /// A blocking `accept` loop on a thread of its own (`MCPSocketServer.startAcceptLoop`'s
    /// reason), and a thread per connection to read its one line.
    private nonisolated func startAcceptLoop(fd: Int32) {
        let thread = Thread { [self] in
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { return }   // `stop` closed it
                guard connections.admit(clientFD) else {
                    close(clientFD)   // over the limit, or stopping
                    continue
                }
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
        let read = Self.readLine(fd, timeout: connections.readTimeout)
        Task {
            let decision: ConnectionCallDecision
            switch read {
            case .line(let line):
                decision = await answer(line: line)
            case .tooLong:
                decision = .deny("The approval request was over 1 MiB, so Wakil did not read it: nothing was sent.")
            case .timedOut:
                decision = .deny("The approval request did not arrive within \(Int(connections.readTimeout)) seconds, "
                    + "so Wakil did not read it: nothing was sent.")
            }
            Self.write(decision, to: fd)
            connections.release(fd)
            close(fd)
        }
    }

    enum LineRead { case line(Data), tooLong, timedOut }

    /// Up to the first newline, or the end of the stream; refused past `maxLineBytes` or once
    /// `timeout` has passed since the read began.
    private static func readLine(_ fd: Int32, timeout: TimeInterval) -> LineRead {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return .timedOut }
            var wait = timeval(tv_sec: Int(left), tv_usec: Int32((left - Double(Int(left))) * 1_000_000))
            if wait.tv_sec == 0 && wait.tv_usec == 0 { wait.tv_usec = 1 }
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return .line(buffer)
            }
            if n == 0 { return .line(buffer) }
            if let newline = chunk[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(contentsOf: chunk[0..<newline])
                return buffer.count > maxLineBytes ? .tooLong : .line(buffer)
            }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxLineBytes { return .tooLong }
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

    /// One request's decision, journalled. `stopped` is read again after every suspension: a
    /// stop that lands during one decides the request, whatever else said.
    func answer(_ request: ConnectionCallRequest) async -> ConnectionCallDecision {
        let call = "\(request.tool) on connection \(request.connection)"
        let ended = ConnectionCallDecision.deny(
            "This conversation has ended in Wakil, so \(call) was not run: nothing was sent.")
        guard !stopped else {
            await journal(request, "conversation-ended")
            return ended
        }
        let spoken = await spoken()
        guard !stopped else {
            await journal(request, "conversation-ended")
            return ended
        }
        if let decision = connectionCallDecision(request, spoken: spoken) {
            await journal(request, "allowed")
            return decision
        }
        let proposal = PendingMutation(
            action: "connection_call", params: request.params, database: nil,
            statement: Self.statement(request), affectsEveryRow: false,
            origin: .agent, place: place, conversation: conversation)
        waiting.insert(proposal.id)
        let outcome = await broker.request(proposal)
        waiting.remove(proposal.id)
        if stopped {
            await journal(request, "conversation-ended")
            return ended
        }
        switch outcome {
        case .approved:
            await journal(request, "asked-approved")
            return .allow
        case .cancelled:
            await journal(request, "asked-declined")
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
    /// `statementArgumentsLimit` characters. JSON encoding escapes every newline, so it is one
    /// line; `displayEscaped` then spells out anything that would not show as itself.
    static func statement(_ request: ConnectionCallRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var arguments = (try? encoder.encode(request.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        if arguments.count > statementArgumentsLimit {
            arguments = String(arguments.prefix(statementArgumentsLimit)) + "…"
        }
        return "\(displayEscaped(request.connection)) · \(displayEscaped(request.tool))(\(displayEscaped(arguments)))"
    }

    /// `s` with every control, format (bidi overrides and isolates, zero-width marks), line- and
    /// paragraph-separator scalar written as `\u{XXXX}`: what the operator reads on the plane is
    /// what the text holds, never text reordered or hidden by it.
    static func displayEscaped(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                out.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// The connections a server has open: how many it admits, and what `stop` shuts. Read from the
/// accept and connection threads, so it locks.
private final class OpenConnections: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var open: Set<Int32> = []
    private var shut = false
    private var timeout: TimeInterval

    init(limit: Int, readTimeout: TimeInterval) {
        self.limit = limit
        self.timeout = readTimeout
    }

    var readTimeout: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return timeout }
        set { lock.lock(); timeout = newValue; lock.unlock() }
    }

    /// Whether `fd` may be served: under the limit, and not stopping.
    func admit(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !shut, open.count < limit else { return false }
        open.insert(fd)
        return true
    }

    /// `fd` is about to be closed by its owner.
    func release(_ fd: Int32) {
        lock.lock(); open.remove(fd); lock.unlock()
    }

    /// Shuts the read side of every open connection, so a read in progress ends; its owner then
    /// answers and closes it. Not `close`: the owner still holds the descriptor, and a number
    /// closed under it could be reused by anything before it closed it again.
    func shutAll() {
        lock.lock(); defer { lock.unlock() }
        shut = true
        for fd in open { _ = shutdown(fd, SHUT_RD) }
    }
}
