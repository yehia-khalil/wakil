import Foundation

/// How a subprocess is run, so that every test in this phase can drive the
/// login states without spawning a browser.
///
/// **The seam is here rather than at `ProviderLogin`** because the states
/// are what need testing and the spawn is what must not run. A fake
/// `ProviderLogin` would test the session against a stand-in for the thing
/// under test; a fake spawner tests the real conformance — its argument
/// list, its environment, its decode — against a stand-in for the browser.
public protocol ProviderLoginSpawning: Sendable {
    /// Runs `binary` with `arguments` under `environment`, and answers its
    /// exit status with whatever it wrote.
    func run(
        binary: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> ProviderLoginSpawnResult

    /// Runs it with a TERMINAL for its standard streams.
    ///
    /// **Only the interactive verbs want this** (#244). `claude auth
    /// login` and `claude setup-token` render a console UI and emit
    /// nothing at all to a pipe; `claude auth status --json` is a
    /// machine-readable read that a terminal only damages, since a
    /// console UI is free to decorate what it prints once it believes a
    /// human is watching.
    func runOnTerminal(
        binary: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> ProviderLoginSpawnResult
}

extension ProviderLoginSpawning {
    /// Defaulted to the pipe, so a test double states only what it cares
    /// about — none of them is testing terminal allocation.
    public func runOnTerminal(
        binary: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> ProviderLoginSpawnResult {
        try await run(
            binary: binary, arguments: arguments, environment: environment, timeout: timeout)
    }
}

public struct ProviderLoginSpawnResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    /// Whether the run was stopped because it ran out of time. **Carried
    /// rather than inferred from the status**, because a killed process
    /// and a process that failed on its own report alike — and the whole
    /// point of a timeout is that it may not claim what a refusal may.
    public var timedOut: Bool

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Claude Code's conformance, and the only one this phase ships
/// (Decision 31).
public struct ClaudeCodeProviderLogin: ProviderLogin {
    public static let kind = "claude-code"

    /// How long a browser trip may take before the trip is abandoned.
    ///
    /// Generous, because the operator is signing in by hand and a person
    /// reading a consent screen is not a hung process. What bounds it at
    /// all is that an abandoned trip must eventually release the band the
    /// pane is showing.
    public static let signInTimeout: TimeInterval = 5 * 60

    /// A liveness read, which is a fast local operation and not a browser
    /// trip.
    static let identityTimeout: TimeInterval = 10

    let spawn: ProviderLoginSpawning

    public init(spawn: ProviderLoginSpawning = SubprocessProviderLoginSpawner()) {
        self.spawn = spawn
    }

    public func signIn(configDir: String, binary: String) async throws -> ProviderLoginResult {
        let result: ProviderLoginSpawnResult
        do {
            result = try await spawn.runOnTerminal(
                binary: binary.isEmpty ? "claude" : binary,
                arguments: ["auth", "login"],
                environment: Self.childEnvironment(configDir: configDir),
                timeout: Self.signInTimeout)
        } catch {
            throw ProviderLoginError.couldNotStart(
                "the sign-in could not be started: \(error)")
        }

        if result.timedOut { return .timedOut }
        guard result.status == 0 else {
            // **A refusal may claim what a timeout may not**, and this is
            // the branch that may: the process ran and ended badly, which
            // is an observed fact about the trip rather than an absence
            // of one. Its own message is surfaced verbatim — it names
            // what the operator declined.
            let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .refused(text.isEmpty ? "the sign-in was declined" : text)
        }

        // Identity comes from the config dir afterwards, never from the
        // login's own output: the login prints nothing an identity can be
        // read out of, and `auth status --json` is the one thing that
        // answers.
        return .signedIn(await identity(configDir: configDir, binary: binary))
    }

    public func identity(configDir: String, binary: String) async -> ProviderLoginIdentity {
        guard let result = try? await spawn.run(
            binary: binary.isEmpty ? "claude" : binary,
            arguments: ["auth", "status", "--json"],
            environment: Self.childEnvironment(configDir: configDir),
            timeout: Self.identityTimeout)
        else { return ProviderLoginIdentity() }
        guard result.status == 0, !result.timedOut else { return ProviderLoginIdentity() }
        return decodeProviderLoginIdentity(result.stdout)
    }

    /// The child's environment: the config dir pinned, and the OAuth token
    /// **removed**.
    ///
    /// **Without the removal this is worthless**, and that is measured
    /// rather than argued (2026-09-22). A genuinely logged-out directory
    /// reports `loggedIn: false`; the same directory read with
    /// `CLAUDE_CODE_OAUTH_TOKEN` set to a literal garbage string reports
    /// `loggedIn: true, authMethod: "oauth_token"`. `auth status --json`
    /// reports that a token is PRESENT; it does not validate one. Wakil's
    /// own harness exports that variable, so a child inheriting this
    /// process's environment would report every account alive, always.
    ///
    /// Built key by key rather than passed through wholesale, the same
    /// convention `buildLaunch` and `childProcessEnvironment` follow: what
    /// a spawned process sees should be a decision this code made.
    static func childEnvironment(configDir: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        // Verbatim — see `ProviderLogin.signIn`. The CLI hashes the
        // literal string it is handed.
        environment["CLAUDE_CONFIG_DIR"] = configDir
        return environment
    }
}

/// Decodes `claude auth status --json`.
///
/// **Extracted and tested directly**, this phase's standing rule for a
/// decoder, and it **refuses rather than passing on**: output that is not
/// JSON, or that carries no `loggedIn`, yields a not-logged-in identity
/// with no name — which is what the surface draws as "could not
/// establish", never as a confident "this is somebody else".
public func decodeProviderLoginIdentity(_ raw: String) -> ProviderLoginIdentity {
    guard let data = raw.data(using: .utf8), !data.isEmpty else { return ProviderLoginIdentity() }
    struct Wire: Decodable {
        let loggedIn: Bool?
        let email: String?
        let orgName: String?
    }
    guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
          let loggedIn = wire.loggedIn
    else { return ProviderLoginIdentity() }
    return ProviderLoginIdentity(
        loggedIn: loggedIn, email: wire.email ?? "", orgName: wire.orgName ?? "")
}

/// Runs the login as a real subprocess. **Nothing in the test suite
/// constructs one**, which is what keeps a browser out of the suite.
public struct SubprocessProviderLoginSpawner: ProviderLoginSpawning {
    public init() {}

    /// Records whether the deadline fired, across the two tasks that care.
    ///
    /// An actor rather than a captured `var`: the timer task writes it and
    /// the caller reads it, and the whole reason the flag exists is that
    /// a terminated process and a process that failed on its own report
    /// the same exit status — so a race here would turn a timeout into a
    /// refusal, which is precisely the claim a timeout may not make.
    private actor Expiry {
        private var fired = false
        func markFired() { fired = true }
        func hasFired() -> Bool { fired }
    }

    public func run(
        binary: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> ProviderLoginSpawnResult {
        try await spawn(
            binary: binary, arguments: arguments, environment: environment,
            timeout: timeout, onTerminal: false)
    }

    public func runOnTerminal(
        binary: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> ProviderLoginSpawnResult {
        try await spawn(
            binary: binary, arguments: arguments, environment: environment,
            timeout: timeout, onTerminal: true)
    }

    private func spawn(
        binary: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval, onTerminal: Bool
    ) async throws -> ProviderLoginSpawnResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment

        // **On a terminal, not a pipe (#244).** `claude auth login` is a
        // console program: given pipes it renders nothing at all, so the
        // URL it opens, its progress and its `Paste code here if prompted`
        // prompt were all invisible until the process was killed and the
        // buffer flushed. Measured on 2.1.280, and the same finding the
        // mint needed (`runOnPTY` in Go, #240).
        //
        // The slave is stdin as well as stdout, so a read blocks rather
        // than returning EOF instantly — a console program handed a closed
        // stdin can decide it has no operator at all.
        let terminal = onTerminal ? try PseudoTerminal() : nil
        let out = Pipe(), err = Pipe()
        if let terminal {
            process.standardInput = terminal.childHandle
            process.standardOutput = terminal.childHandle
            process.standardError = terminal.childHandle
        } else {
            process.standardOutput = out
            process.standardError = err
        }
        try process.run()
        // Closed here once the child holds it, or the master never sees
        // the end of output.
        terminal?.closeChildSide()

        // The timeout TERMINATES the child rather than abandoning it: a
        // browser login that outlives the pane showing it is a process
        // nothing will ever reap.
        let expiry = Expiry()
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await expiry.markFired()
            if process.isRunning { process.terminate() }
        }
        // Cancelled on every exit from this function, including a throw:
        // otherwise a fast login leaves a timer holding a reference to a
        // finished process for the whole timeout.
        defer { deadline.cancel() }

        // A terminal has ONE stream, so what would have been stderr
        // arrives interleaved. A pipe keeps them apart, and the refusal
        // path prefers stderr when it has one.
        let stdoutText: String, stderrText: String
        if let terminal {
            stdoutText = terminal.readAllFromParent()
            stderrText = ""
        } else {
            stdoutText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self)
            stderrText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self)
        }
        process.waitUntilExit()

        return ProviderLoginSpawnResult(
            status: process.terminationStatus,
            stdout: stdoutText,
            stderr: stderrText,
            timedOut: await expiry.hasFired())
    }
}
