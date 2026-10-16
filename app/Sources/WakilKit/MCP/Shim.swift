import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Copies bytes between this process's stdio and the unix domain socket
/// `MCPSocketServer` is listening on at `socketPath`, until either direction
/// reaches EOF, then returns 0. **It parses nothing** — no JSON-RPC frame is
/// ever decoded here; that only happens on the other end of the socket, in
/// `handle`.
///
/// This is `--mcp-shim`'s entire job. Per the design
/// (docs/superpowers/specs/2026-09-07-phase-2a-spine-design.md §2.2): the
/// `claude` CLI's MCP client only knows how to spawn a stdio server, never to
/// connect out to one already running, and Wakil.app is already running when
/// a session starts — so Wakil's own executable is invoked a second time,
/// with `--mcp-shim`, purely to bridge that gap. `WakilApp/main.swift` must
/// detect that mode before touching AppKit, since this shim runs headlessly
/// with no display session.
///
/// If the connection itself cannot be established — `socket()`, address
/// construction, or `connect()` fails — this writes the reason to stderr and
/// returns a non-zero exit code without touching stdio at all. Verified by
/// `ShimTests.shimModeIsDetectedBeforeAnyUISetup`, which points this at a
/// socket path that deliberately does not exist.
public func runShim(socketPath: String) -> Int32 {
    // See `ignoreSIGPIPEProcessWide`'s doc comment in MCPServer.swift: this
    // shim writes to both the socket and its own stdout, and either peer
    // (the server, or the `claude` subprocess machinery reading our stdout)
    // can vanish mid-session. Without this, that write kills the shim
    // process outright via SIGPIPE rather than failing the one write.
    _ = ignoreSIGPIPEProcessWide

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        writeShimError("socket() failed: \(String(cString: strerror(errno)))")
        return 1
    }
    disableSIGPIPE(onSocket: fd)

    let address: (sockaddr_un, socklen_t)
    do {
        address = try makeUnixSocketAddress(path: socketPath)
    } catch {
        close(fd)
        writeShimError("\(error)")
        return 1
    }
    var (addr, len) = address

    let connectResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connectResult == 0 else {
        let failedErrno = errno
        close(fd)
        writeShimError("connect(\(socketPath)) failed: \(String(cString: strerror(failedErrno)))")
        return 1
    }

    let socketHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let stdinHandle = FileHandle.standardInput
    let stdoutHandle = FileHandle.standardOutput
    let group = DispatchGroup()

    // stdin -> socket: bytes the parent process (the `claude` subprocess
    // machinery, treating this shim as "the MCP server") writes to this
    // process's stdin are forwarded verbatim to the socket, where
    // `MCPSocketServer`'s `Connection` reads them.
    group.enter()
    let toSocket = Thread {
        while true {
            let data = stdinHandle.availableData
            if data.isEmpty { break }
            do { try socketHandle.write(contentsOf: data) } catch { break }
        }
        // Half-close the write side so the far end's read loop observes EOF
        // instead of waiting forever once our stdin is exhausted.
        shutdown(fd, Int32(SHUT_WR))
        group.leave()
    }
    toSocket.name = "wakil-mcp-shim.stdin-to-socket"
    toSocket.start()

    // socket -> stdout: whatever `Connection` writes back is forwarded
    // verbatim to this process's stdout.
    group.enter()
    let fromSocket = Thread {
        while true {
            let data = socketHandle.availableData
            if data.isEmpty { break }
            do { try stdoutHandle.write(contentsOf: data) } catch { break }
        }
        group.leave()
    }
    fromSocket.name = "wakil-mcp-shim.socket-to-stdout"
    fromSocket.start()

    group.wait()
    return 0
}

private func writeShimError(_ message: String) {
    FileHandle.standardError.write(Data("wakil --mcp-shim: \(message)\n".utf8))
}
