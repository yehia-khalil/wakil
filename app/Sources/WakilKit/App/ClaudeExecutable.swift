import Foundation

/// Which `claude` a browser sign-in spawns.
///
/// **In order: the operator's override, then this organisation's own
/// records, then this machine** (#322). #271 stopped the login borrowing a
/// path another organisation recorded (Invariant 4), which left an
/// organisation with no accounts with no path at all, so it could never
/// register its first. The machine lookup closes that gap without reading any
/// other organisation's rows. The override is there because the lookup can be
/// wrong: two installs, or a wrapper script.
///
/// Returns `""` when nothing answers. The caller refuses in words rather
/// than spawning a bare `claude`, which `executableURL` would resolve against
/// the working directory (#238).
public func resolveLoginBinary(override: String, ownBinaries: [String], located: String) -> String {
    let typed = override.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return typed }
    if let recorded = ownBinaries.first(where: { !$0.isEmpty }) { return recorded }
    return located
}

/// Finds `claude` on this machine when no record says where it is.
///
/// **A GUI launched from Finder inherits launchd's minimal PATH**, which does
/// not hold `~/.local/bin`, where Anthropic's installer puts it. So the
/// operator's own login shell is asked first, since that is where their PATH
/// is really set. Then the standard install locations are tried, in the order
/// the installers use.
public struct ClaudeExecutableLocator: Sendable {
    public var home: String
    /// What the operator's login shell says `command -v claude` is, or nil.
    public var shellLookup: @Sendable () -> String?
    public var isExecutable: @Sendable (String) -> Bool

    public init(
        home: String, shellLookup: @escaping @Sendable () -> String?,
        isExecutable: @escaping @Sendable (String) -> Bool
    ) {
        self.home = home
        self.shellLookup = shellLookup
        self.isExecutable = isExecutable
    }

    /// The candidates after the shell's answer, in the order tried.
    public var standardLocations: [String] {
        ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    public func locate() -> String {
        // A shell's rc files can print anything; only an absolute path that
        // is executable counts as an answer.
        if let answer = shellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
           answer.hasPrefix("/"), isExecutable(answer) {
            return answer
        }
        return standardLocations.first(where: isExecutable) ?? ""
    }

    /// The real machine: the operator's `$SHELL` as a login, interactive
    /// shell, since `~/.local/bin` is commonly added in `.zshrc` rather than
    /// `.zprofile`, with a timeout so a slow rc file cannot hang the pane.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeExecutableLocator {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return ClaudeExecutableLocator(
            home: home,
            shellLookup: { loginShellAnswer(shell: shell, home: home) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}

/// The last absolute path a login shell prints for `command -v claude`.
private func loginShellAnswer(shell: String, home: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lic", "command -v claude"]
    process.environment = ["HOME": home, "TERM": "dumb"]
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }

    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning {
        process.terminate()
        return nil
    }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return text.split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("/") }
}
