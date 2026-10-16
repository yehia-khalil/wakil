import Foundation

/// What a mint did. A typed mirror of Go's `wakilcore.MintOutcome`.
///
/// **Three outcomes, not two, and the third is the point.** A credential
/// that WAS created and could not be kept is not a failure — it is a live
/// 365-day credential at Anthropic that Wakil never caught, and the
/// operator must be told that rather than told the mint failed.
///
/// **There is no field a token could travel in**, which is what makes
/// *the token never reaches Swift* a property of this type rather than a
/// promise about the code around it.
public struct ProviderMintOutcome: Sendable, Equatable, Decodable {
    public var stored: Bool
    /// A one-year credential may exist that Wakil never caught.
    public var uncertain: Bool
    /// The sentence the operator reads.
    public var detail: String

    public init(stored: Bool = false, uncertain: Bool = false, detail: String = "") {
        self.stored = stored
        self.uncertain = uncertain
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stored = try container.decodeIfPresent(Bool.self, forKey: .stored) ?? false
        uncertain = try container.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case stored, uncertain, detail }
}

/// Decodes `wakil provider mint`'s one JSON line.
///
/// **Extracted and tested directly**, the phase's standing rule, and it
/// **refuses rather than passing on**: output that is not the outcome
/// JSON becomes an UNCERTAIN outcome, never a clean failure. A verb that
/// ran and whose answer could not be read is precisely the case where
/// Wakil does not know whether a credential exists — and defaulting to
/// "it failed" there would hide a live 365-day credential.
public func decodeProviderMintOutcome(_ raw: String) -> ProviderMintOutcome {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // The verb prints one JSON line, possibly after other output. The
    // last brace-delimited line is the answer.
    let candidate = trimmed
        .split(separator: "\n")
        .last { $0.hasPrefix("{") && $0.hasSuffix("}") }
    guard let candidate, let data = candidate.data(using: .utf8),
          let outcome = try? JSONDecoder().decode(ProviderMintOutcome.self, from: data)
    else {
        return ProviderMintOutcome(
            stored: false, uncertain: true,
            detail: "The credential step ran and Wakil could not read what it did. "
                + "A long-lived credential may have been created. "
                + "Check your Anthropic account before trying again.")
    }
    return outcome
}

/// Spawns `wakil provider mint`, which captures the token and stores it
/// **without ever printing it**.
///
/// **Why Swift spawns a verb rather than dispatching an action.** Three
/// reasons, each independently sufficient, and they mirror the credential
/// READ path (`WakilCLICredentialsLookup`) that has shipped all along:
///
///   - Every `ctx_*` action is a thin proxy on a ten-second reply
///     timeout, and this is a browser trip.
///   - `JournalEntry.params` is written verbatim on every dispatch, so a
///     secret cannot ride in an action's parameters. Go captures and
///     stores; **the token never reaches this process**.
///   - Being a separate process, a `wakil-ctx` restart cannot kill it
///     mid-flight.
public protocol ProviderMinting: Sendable {
    /// Mints and stores, answering only what happened.
    func mint(id: String, configDir: String, binary: String) async -> ProviderMintOutcome
}

/// The shipped conformance. **Nothing in the test suite constructs one.**
public struct WakilCLIProviderMint: ProviderMinting {
    let executable: URL
    let organization: String

    public init(executable: URL, organization: String) {
        self.executable = executable
        self.organization = organization
    }

    public func mint(id: String, configDir: String, binary: String) async -> ProviderMintOutcome {
        let process = Process()
        process.executableURL = executable
        var arguments = ["--org", organization, "provider", "mint", id, "--config-dir", configDir]
        if !binary.isEmpty { arguments += ["--claude-path", binary] }
        process.arguments = arguments

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            // It never started, so nothing was minted. This is the one
            // branch that may claim cleanly.
            return ProviderMintOutcome(
                stored: false, uncertain: false,
                detail: "the credential step could not be started: \(error)")
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let outcome = decodeProviderMintOutcome(String(decoding: stdout, as: UTF8.self))
        guard outcome.detail.isEmpty, !outcome.stored else { return outcome }
        // A non-zero exit with no detail of its own: surface the verb's
        // stderr rather than inventing a sentence.
        let text = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return outcome }
        return ProviderMintOutcome(
            stored: outcome.stored, uncertain: outcome.uncertain, detail: text)
    }
}
