import Foundation

/// A JSON-RPC 2.0 request/response/notification, framed as newline-delimited
/// JSON when sent over a pipe. Used by both the MCP client (talking to child
/// server processes) and the MCP server (talking to a parent client) so the
/// two directions share one wire representation.
///
/// `params`, `result`, and `error.data` use a custom `Codable`
/// implementation (below) rather than the synthesized one. Swift's
/// synthesized `Codable` decodes `T?` fields with `decodeIfPresent`, which
/// short-circuits to `nil` as soon as `decodeNil()` is true — so an absent
/// key and an explicit JSON `null` both become `nil`, and both re-encode to
/// "key absent". That collapses "success, no result" (`"result": null`,
/// meaningful in JSON-RPC) into the same shape as "no result field at all".
/// The custom implementation keeps those two states distinct: `nil` means
/// the key was absent, `.some(.null)` means the key was present and `null`.
public struct JSONRPCMessage: Codable, Sendable {
    public var id: JSONRPCID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: JSONRPCError?

    public init(
        id: JSONRPCID? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONRPCError? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // "jsonrpc" is read by nothing: this type has no stored property for
        // it, so an incoming message's version tag (whatever it says) is
        // accepted without being checked. It is still written back out on
        // encode, below — see that comment for why.
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeJSONValuePreservingNull(forKey: .params)
        result = try container.decodeJSONValuePreservingNull(forKey: .result)
        error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The literal "2.0" is not optional: JSON-RPC 2.0 requires every
        // message to carry this tag, and a real peer enforces it. Verified
        // against the real wakil-ctx binary (built via `make build`, an
        // MCP Go SDK server): a frame encoded without this field was
        // rejected outright with `invalid message version tag ""; expected
        // "2.0"` before this line was added, and the same frame was
        // accepted once it was.
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeJSONValuePreservingNull(params, forKey: .params)
        try container.encodeJSONValuePreservingNull(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// JSON-RPC request/response identifiers are either a number or a string.
public enum JSONRPCID: Codable, Sendable, Hashable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Int.self) {
            self = .number(n)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }
}

/// A JSON-RPC error object: `{"code": ..., "message": ..., "data": ...}`.
/// `data` uses the same absent-vs-explicit-null-preserving encode/decode as
/// `JSONRPCMessage.params`/`.result` — see that type's doc comment.
public struct JSONRPCError: Codable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        data = try container.decodeJSONValuePreservingNull(forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeJSONValuePreservingNull(data, forKey: .data)
    }
}

/// Encodes a message as a single line of JSON terminated by exactly one
/// `\n`, ready to append to a byte stream framed by newlines.
public func encodeFrame(_ m: JSONRPCMessage) throws -> Data {
    var d = try JSONEncoder().encode(m)
    d.append(UInt8(ascii: "\n"))
    return d
}

/// Thrown by `FrameReader.push` when a buffered, not-yet-newline-terminated
/// frame grows past `FrameReader.maxBufferedFrameBytes`.
public enum FrameReaderError: Error, Sendable, Equatable {
    case frameTooLarge(bufferedBytes: Int, limit: Int)
}

/// Reassembles newline-delimited JSON-RPC frames out of arbitrarily-chunked
/// byte data, such as arrives from a pipe read. Buffers any trailing partial
/// line across calls until it is completed by a subsequent newline.
///
/// Contract: a successfully decoded message is never lost. Any error —
/// overflow of the unterminated-line buffer, or a non-empty line that fails
/// to decode as a `JSONRPCMessage` — is latched: the messages decoded before
/// it are returned from that call, and every subsequent `push` throws the
/// latched error unconditionally, without buffering or decoding further
/// input. A malformed frame is not silently dropped (that would hide
/// protocol drift from a real MCP peer), and a stream that has hit either
/// error is treated as permanently untrustworthy rather than silently
/// resuming. Recovery means constructing a new `FrameReader`, which callers
/// would naturally do when they tear down and restart the underlying
/// connection.
///
/// Blank or whitespace-only lines are the one exception: they are skipped
/// silently and never latch anything, since they carry no content to lose
/// and are not malformed.
public struct FrameReader {
    /// Upper bound on how large a single buffered, not-yet-terminated line
    /// may grow before `push` gives up and throws. This reader sits on a
    /// live subprocess pipe; without a cap, a peer that never sends a
    /// newline would grow this buffer without bound. 16 MiB because of a
    /// measured payload: wakil-git's `git_show` reply carries the file text
    /// twice (`content` and `structuredContent`), so a 2 MB file is a
    /// 4,194,544-byte frame — just over the earlier 4 MiB cap, which refused
    /// it and latched the whole client. 16 MiB leaves room for that doubling
    /// on files up to ~8 MB.
    public static let maxBufferedFrameBytes = 16 * 1024 * 1024

    private var buffer = Data()
    /// Offset into `buffer` already searched for a newline without finding
    /// one. Each `push` searches only the bytes after it, so a large frame
    /// arriving in many chunks is scanned once in total, not once per chunk.
    private var scannedBytes = 0
    private var latchedError: Error?

    public init() {}

    /// Offset of the first `\n` in `buffer` at or after `from`, or nil.
    /// `memchr` over contiguous bytes: the generic `Collection.firstIndex`
    /// path on `Data` costs a witness call per byte.
    private func newlineOffset(from: Int) -> Int? {
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.baseAddress, from < raw.count else { return nil }
            guard let hit = memchr(base + from, Int32(UInt8(ascii: "\n")), raw.count - from) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    public mutating func push(_ d: Data) throws -> [JSONRPCMessage] {
        if let latchedError {
            throw latchedError
        }

        buffer.append(d)

        var messages: [JSONRPCMessage] = []
        // Start of the first unconsumed line. Consumed lines are dropped from
        // `buffer` once, at the end of this call, rather than shifting the
        // remainder down after every line.
        var lineStart = 0
        defer {
            if lineStart > 0 {
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + lineStart))
                scannedBytes = max(0, scannedBytes - lineStart)
            }
        }
        while let newline = newlineOffset(from: max(lineStart, scannedBytes)) {
            let lineRange = (buffer.startIndex + lineStart)..<(buffer.startIndex + newline)
            lineStart = newline + 1
            scannedBytes = lineStart

            let line = buffer[lineRange]
            let isBlank = line.allSatisfy { byte in
                byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
            }
            if isBlank { continue }

            do {
                let message = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(line))
                messages.append(message)
            } catch {
                // Do not throw yet: `messages` may already hold complete
                // frames decoded earlier in this same call, and those must
                // not be lost. Latch the decode error and return what we
                // have; the error surfaces on the next call instead.
                latchedError = error
                return messages
            }
        }
        scannedBytes = buffer.count

        let bufferedBytes = buffer.count - lineStart
        if bufferedBytes > Self.maxBufferedFrameBytes {
            buffer.removeAll()
            scannedBytes = 0
            lineStart = 0
            // Same reasoning as the decode-error case above: return the
            // messages already decoded in this call, latch the overflow for
            // the next one.
            latchedError = FrameReaderError.frameTooLarge(bufferedBytes: bufferedBytes, limit: Self.maxBufferedFrameBytes)
        }

        return messages
    }
}
