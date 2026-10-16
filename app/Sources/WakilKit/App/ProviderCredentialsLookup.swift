import Foundation

/// What one `claude` invocation needs, formerly four environment
/// variables.
///
/// WHY SWIFT DOES NOT READ THE KEYCHAIN. `internal/wakilcore/secrets.go`
/// does not use Security.framework — it shells out to the `security` CLI,
/// and it encodes measured knowledge a second implementation would have to
/// re-derive: exit 44 for a missing item, the `wakil:<org>:<ref>` service
/// name as the ONLY place org scoping can live, and a deliberate refusal
/// to fall back to unscoped names. A Swift copy that drifted from that
/// scheme would not fail loudly; it would return the wrong org's
/// credential, which is the cross-org sharing the 2026-09-06 decoupling
/// ended. So Go reads, and this asks Go.
public enum ProviderCredentialsLookupError: Error, Equatable {
    case refused(String)
}

/// The associated string is Go's own refusal, already a full sentence —
/// "no credential stored for ref provider:main in org test-org — store it
/// with: ..." — so this prints it and adds nothing. Without the
/// conformance, `WindowModel`'s `status = "agent: \(error)"` would wrap
/// that readable sentence in `refused("...")`.
extension ProviderCredentialsLookupError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .refused(let message): return message
        }
    }
}

public protocol ProviderCredentialsLookup: Sendable {
    func credentials(forProvider id: String) async throws -> ProviderCredentials
}

/// Decodes the command's stdout, refusing an empty field rather than
/// passing it on. An empty config dir or token would launch `claude` into
/// whatever default account it finds — the cross-account confusion
/// Invariant 4 exists to prevent — and an empty claude path would resolve
/// through `PATH` instead of naming one pinned binary.
public func decodeProviderCredentials(_ data: Data) throws -> ProviderCredentials {
    struct Wire: Decodable { let configDir: String; let claudePath: String; let oauthToken: String }
    let wire: Wire
    do {
        wire = try JSONDecoder().decode(Wire.self, from: data)
    } catch {
        throw ProviderCredentialsLookupError.refused(
            "could not read the provider credentials response: \(error)")
    }
    for (name, value) in [
        ("configDir", wire.configDir), ("claudePath", wire.claudePath), ("oauthToken", wire.oauthToken),
    ] where value.isEmpty {
        throw ProviderCredentialsLookupError.refused("the provider record is missing \(name)")
    }
    return ProviderCredentials(
        claudePath: wire.claudePath, configDir: wire.configDir, oauthToken: wire.oauthToken)
}

/// Runs `wakil provider credentials <id> --org <org>` and decodes it.
///
/// The token is on this process's stdout pipe and nowhere else: it is
/// never logged, never journalled and never put in an error. On a refusal
/// the command's own stderr is surfaced verbatim, because it names the fix
/// (the exact `wakil secrets set` to run) and rewording it here would lose
/// that.
public struct WakilCLICredentialsLookup: ProviderCredentialsLookup {
    let executable: URL
    let organization: String

    public init(executable: URL, organization: String) {
        self.executable = executable
        self.organization = organization
    }

    public func credentials(forProvider id: String) async throws -> ProviderCredentials {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--org", organization, "provider", "credentials", id]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // **Both pipes are drained AT ONCE, and that is not a style choice.**
        // #284: this read stdout to EOF and only then looked at stderr. A pipe
        // holds 64 KiB on this machine; a command that wrote more than that to
        // stderr blocked there, and a child blocked writing never exits and
        // never closes stdout — so `readDataToEndOfFile` waited for an EOF
        // that could not come, and the two sides held each other forever with
        // no timeout on either.
        //
        // **What that cost.** `WindowModel.send` awaits this before it spawns
        // anything, and — until 72ad932 — before it wrote any status at all.
        // A turn that landed here left no agent, no status, no error and no
        // trace: the window looked like it had ignored the click, which is
        // exactly how #284 was reported. It is intermittent because it depends
        // on how much the CLI happens to say, which is why it survived so long.
        let errData = readConcurrently(err.fileHandleForReading)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errBody = errData.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errBody, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderCredentialsLookupError.refused(
                text.isEmpty ? "wakil provider credentials \(id) failed" : text)
        }
        return try decodeProviderCredentials(data)
    }
}

/// A pipe being drained on another thread, so its writer can never block the
/// reader of a sibling pipe. See `WakilCLICredentialsLookup.credentials`.
///
/// **A thread, not a `Task`.** `readDataToEndOfFile` blocks, and blocking a
/// cooperative-pool thread is the thing that pool exists to forbid — under
/// enough concurrent lookups it would starve the very executor that is meant
/// to resume this one.
final class ConcurrentRead: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    /// Blocks until the pipe reaches EOF, then hands back everything it held.
    /// Safe to read `data` here without further synchronisation: the semaphore
    /// is the happens-before edge between the write above and this read.
    func wait() -> Data {
        done.wait()
        return data
    }
}

func readConcurrently(_ handle: FileHandle) -> ConcurrentRead { ConcurrentRead(handle) }
