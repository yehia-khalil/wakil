import Foundation

// Workspaces, piece 2 (the walk): Try read "Trying … in a throwaway workspace…" for minutes while it
// copied, prepared, ran services and setup, started the processes and waited for ready. Try is now
// a job Go runs and the window follows (`recipe_try_start`, `recipe_try_status`, `recipe_try_cancel`):
// every step listed before it runs — ✓ done with its time, ● running with its time so far and last
// line, ○ to come, ✗ failed with its output whole (Rule 8). The views only draw this.

/// One row of Try's progress, as `wakilcore.TryStep` answers it.
public struct TryStepState: Decodable, Sendable, Equatable {
    public enum State: String, Sendable { case toCome = "to come", running, done, failed }
    public var phase: String
    public var name: String
    public var command: String
    public var state: State
    public var seconds: Double
    public var output: String
    public var lastLine: String
    public var detail: String

    public init(phase: String, name: String = "", command: String = "", state: State, seconds: Double = 0,
                output: String = "", lastLine: String = "", detail: String = "") {
        self.phase = phase; self.name = name; self.command = command; self.state = state
        self.seconds = seconds; self.output = output; self.lastLine = lastLine; self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case phase, name, command, state, seconds, output, lastLine, detail }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        state = State(rawValue: try c.decodeIfPresent(String.self, forKey: .state) ?? "") ?? .toCome
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        lastLine = try c.decodeIfPresent(String.self, forKey: .lastLine) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }

    /// What the row says: `copy made`, `prepared — copied .env`, `setup · composer install`,
    /// `web started · pnpm dev`, `ready · http://localhost:41200/up`.
    public var title: String {
        switch phase {
        case "copy": return "copy made"
        case "prepare":
            let what = state == .done ? output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return what.isEmpty ? "prepared" : "prepared — \(what)"
        case RunPhase.process: return "\(name.isEmpty ? "process" : name) started · \(command)"
        default: return command.isEmpty ? phase : "\(phase) · \(command)"
        }
    }

    /// The row's mark: ✓ ● ○ ✗.
    public var mark: String {
        switch state {
        case .done: "✓"
        case .running: "●"
        case .toCome: "○"
        case .failed: "✗"
        }
    }

    /// Its time: taken when done or failed, so far while it runs; nothing to come.
    public var time: String? { state == .toCome ? nil : runElapsed(seconds) }
}

/// Try's progress at one moment, as `recipe_try_status` answers it (the window's own copy row first).
public struct TryProgressState: Decodable, Sendable, Equatable {
    public var steps: [TryStepState]
    public var finished: Bool
    public var result: RunTryResult?

    public init(steps: [TryStepState], finished: Bool = false, result: RunTryResult? = nil) {
        self.steps = steps; self.finished = finished; self.result = result
    }

    private enum CodingKeys: String, CodingKey { case steps, finished, result }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decodeIfPresent([TryStepState].self, forKey: .steps) ?? []
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        result = try c.decodeIfPresent(RunTryResult.self, forKey: .result)
    }

    /// The step whose output "Show output" opens: the running one, else the failed one.
    public var shown: TryStepState? {
        steps.first { $0.state == .running } ?? steps.first { $0.state == .failed }
    }
}

/// `4 s`, `1 min 5 s`: a step's time, whole seconds.
public func runElapsed(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
}

/// A card's Run, while it gets going (the walk): the step it is on, its command and when it began.
public struct RunStepNow: Sendable, Equatable {
    public var step: String
    public var command: String
    public var started: Date
    public init(step: String, command: String, started: Date) {
        self.step = step; self.command = command; self.started = started
    }
}

/// The key a Try's progress is kept under: its project's registry key and the repo.
public func runningTryKey(project: String, repo: String) -> String { "\(project)/\(repo)" }
