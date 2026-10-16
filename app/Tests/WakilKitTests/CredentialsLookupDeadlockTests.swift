import Foundation
import Testing

@testable import WakilKit

/// **A turn that hangs forever in the credential lookup. #284.**
///
/// `WakilCLICredentialsLookup` drained `wakil provider credentials` one pipe
/// at a time — stdout to EOF, and only then stderr. A child that writes more
/// than the pipe buffer holds (64 KiB on this machine) to *stderr* blocks
/// there; blocked, it never exits and never closes stdout; and the parent
/// waits on a `readDataToEndOfFile` that can never return. Neither side can
/// move, and neither ever times out.
///
/// **Why this is #284's shape and not merely a latent bug.** The deadlock sits
/// inside `await resolveCredentials(...)`, which `WindowModel.send` reaches
/// before it spawns anything and — until 72ad932, which post-dates every
/// observed occurrence — before it wrote any status at all. A turn that landed
/// here produced exactly what was reported: no agent process, no status text,
/// no error, and a window that looked like it had ignored the click. It is
/// intermittent for the reason that makes intermittency so expensive here —
/// it depends on how much the CLI happens to say on a given run.
private func writeFakeCLI(stderrBytes: Int) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("creds-deadlock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("wakil")
    // stderr FIRST, then stdout: the order that deadlocks a reader draining
    // stdout to EOF before it ever looks at stderr.
    //
    // **The watchdog is what makes a regression FAIL rather than hang.** The
    // bug is a genuine two-sided block with no timeout on either side, so a
    // reader that reintroduced it would wait forever and take the whole suite
    // with it. Killing the child after twenty seconds closes the pipes, the
    // reader unblocks with no stdout to decode, and the lookup throws — which
    // this test reports as the failure it is.
    try """
    #!/bin/sh
    ( sleep 20; kill -9 $$ ) >/dev/null 2>&1 &
    yes 'the CLI had a great deal to say on this occasion' | head -c \(stderrBytes) >&2
    printf '{"configDir":"/tmp/cfg","claudePath":"/tmp/claude","oauthToken":"t"}'
    exit 0
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

/// Runs the lookup with a deadline, so a deadlock FAILS rather than hanging
/// the suite forever — which is what it would otherwise do, this being a
/// genuine two-sided block with no timeout on either side.
private func credentialsWithDeadline(
    _ lookup: WakilCLICredentialsLookup, seconds: Double
) async -> ProviderCredentials? {
    await withTaskGroup(of: ProviderCredentials?.self) { group in
        group.addTask { try? await lookup.credentials(forProvider: "main") }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// **256 KiB, four times the buffer**, so this cannot pass by happening to fit.
@Test func aTalkativeCredentialsCommandDoesNotDeadlockTheTurn() async throws {
    let executable = try writeFakeCLI(stderrBytes: 256 * 1024)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let lookup = WakilCLICredentialsLookup(executable: executable, organization: "test-org")

    let credentials = await credentialsWithDeadline(lookup, seconds: 15)

    #expect(credentials != nil, """
        the credential lookup never returned: the command wrote 256 KiB to stderr, and a reader \
        that drains stdout to EOF first blocks until the child exits while the child blocks \
        writing stderr. `WindowModel.send` awaits this before it spawns the agent, so a turn \
        that lands here starts nothing and says nothing — #284.
        """)
    #expect(credentials?.claudePath == "/tmp/claude")
}

/// The quiet case, which always worked and must keep working: the fix must not
/// buy the talkative case at the cost of the ordinary one.
@Test func aQuietCredentialsCommandStillReturnsItsCredentials() async throws {
    let executable = try writeFakeCLI(stderrBytes: 0)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let lookup = WakilCLICredentialsLookup(executable: executable, organization: "test-org")

    let credentials = await credentialsWithDeadline(lookup, seconds: 15)

    #expect(credentials?.configDir == "/tmp/cfg")
    #expect(credentials?.oauthToken == "t")
}

/// **A refusal must still carry the command's own words.** The fix rearranges
/// how stderr is read, and stderr is exactly what a refusal's message comes
/// from — `ProviderCredentialsLookup`'s doc comment says that text names the
/// `wakil secrets set` to run, and losing it would be a quiet regression the
/// deadlock tests above would not notice.
@Test func aRefusalStillSurfacesTheCommandsOwnStderr() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("creds-refusal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("wakil")
    try """
    #!/bin/sh
    echo 'no credential stored for ref provider:main — store it with: wakil secrets set ...' >&2
    exit 44
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let lookup = WakilCLICredentialsLookup(executable: executable, organization: "test-org")
    await #expect(throws: ProviderCredentialsLookupError.self) {
        _ = try await lookup.credentials(forProvider: "main")
    }
    do {
        _ = try await lookup.credentials(forProvider: "main")
    } catch {
        #expect("\(error)".contains("wakil secrets set"), "\(error)")
    }
}
