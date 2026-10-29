import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The unix-socket plumbing every local socket in WakilKit shares: the MCP socket and its shim
// (`MCP/`) and the connection approval socket (`Gate/`). In `Core/` so neither folder reaches
// into the other for it.

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
