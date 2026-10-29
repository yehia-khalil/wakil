import Foundation

// Workspaces, piece 2: the run plan Go builds (`recipe_plan`, `recipe_prepare`;
// `internal/wakilcore/recipeplan.go`), as the window reads it to run a repo.

/// One step of a plan: `need` (start `target` first), `copy` / `clone` (Go's, on a first run),
/// `service`, `setup` (one-shot, Go's), `process` (a terminal of its own), `build`, `teardown`.
public struct RunPlanStep: Decodable, Sendable, Equatable {
    public var phase: String
    public var name: String
    public var command: String
    public var dir: String
    public var longRunning: Bool
    /// `workspace` (needs, services), `checkout` (copy, clone, setup) or empty (every run).
    public var once: String
    public var target: String
    /// `repo` or `service`, for a need.
    public var targetKind: String

    public init(phase: String, name: String = "", command: String = "", dir: String = "", longRunning: Bool = false,
                once: String = "", target: String = "", targetKind: String = "") {
        self.phase = phase
        self.name = name
        self.command = command
        self.dir = dir
        self.longRunning = longRunning
        self.once = once
        self.target = target
        self.targetKind = targetKind
    }

    enum CodingKeys: String, CodingKey { case phase, name, command, dir, longRunning, once, target, targetKind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(String.self, forKey: .phase)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        longRunning = try c.decodeIfPresent(Bool.self, forKey: .longRunning) ?? false
        once = try c.decodeIfPresent(String.self, forKey: .once) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        targetKind = try c.decodeIfPresent(String.self, forKey: .targetKind) ?? ""
    }
}

/// How Wakil knows the app is up: a URL that answers, or a line in the output.
public struct RunReady: Decodable, Sendable, Equatable {
    public var url: String?
    public var output: String?
    public var timeoutSeconds: Int
    public init(url: String? = nil, output: String? = nil, timeoutSeconds: Int = 120) {
        self.url = url
        self.output = output
        self.timeoutSeconds = timeoutSeconds
    }
    enum CodingKeys: String, CodingKey { case url, output, timeoutSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url).flatMap { $0.isEmpty ? nil : $0 }
        output = try c.decodeIfPresent(String.self, forKey: .output).flatMap { $0.isEmpty ? nil : $0 }
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 120
    }
}

/// Everything the window needs to run a repo (or a shared service) in a workspace.
public struct RunPlan: Decodable, Sendable, Equatable {
    public var repo: String
    public var recipe: String
    public var dir: String
    public var env: [String: String]
    /// Variable to Keychain service; the values come back from `recipe_prepare` as `secretEnv`.
    public var secrets: [String: String]
    public var steps: [RunPlanStep]
    public var build: RunPlanStep?
    public var ready: RunReady?
    public var teardown: [RunPlanStep]
    public var warnings: [String]

    public init(repo: String, recipe: String = "", dir: String, env: [String: String] = [:], secrets: [String: String] = [:],
                steps: [RunPlanStep] = [], build: RunPlanStep? = nil, ready: RunReady? = nil,
                teardown: [RunPlanStep] = [], warnings: [String] = []) {
        self.repo = repo
        self.recipe = recipe
        self.dir = dir
        self.env = env
        self.secrets = secrets
        self.steps = steps
        self.build = build
        self.ready = ready
        self.teardown = teardown
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey { case repo, recipe, dir, env, secrets, steps, build, ready, teardown, warnings }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        recipe = try c.decodeIfPresent(String.self, forKey: .recipe) ?? ""
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        secrets = try c.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:]
        steps = try c.decodeIfPresent([RunPlanStep].self, forKey: .steps) ?? []
        build = try c.decodeIfPresent(RunPlanStep.self, forKey: .build)
        ready = try c.decodeIfPresent(RunReady.self, forKey: .ready)
        teardown = try c.decodeIfPresent([RunPlanStep].self, forKey: .teardown) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    public func steps(_ phase: String) -> [RunPlanStep] { steps.filter { $0.phase == phase } }
    /// The plan's processes (each a terminal of its own).
    public var processes: [RunPlanStep] { steps(RunPhase.process) }
}

/// Plan phase names, as Go writes them.
public enum RunPhase {
    public static let need = "need"
    public static let copy = "copy"
    public static let clone = "clone"
    public static let service = "service"
    public static let setup = "setup"
    public static let process = "process"
    public static let build = "build"
    public static let teardown = "teardown"
}

/// One step run headless (`recipe_run_steps`, `recipe_try`): its output whole (Rule 8).
public struct RunStepResult: Decodable, Sendable, Equatable {
    public var phase: String
    public var name: String
    public var command: String
    public var ok: Bool
    public var exitCode: Int
    public var output: String
    public var seconds: Double
    public var detail: String

    public init(phase: String, name: String = "", command: String = "", ok: Bool, exitCode: Int = 0,
                output: String = "", seconds: Double = 0, detail: String = "") {
        self.phase = phase
        self.name = name
        self.command = command
        self.ok = ok
        self.exitCode = exitCode
        self.output = output
        self.seconds = seconds
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case phase, name, command, ok, exitCode, output, seconds, detail }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }

    /// The step's failure, whole: what ran, why it stopped, and everything it printed.
    public var failureText: String {
        let what = phase.isEmpty ? command : "\(phase) `\(command)`"
        let why = detail.isEmpty ? "\(what) failed." : "\(what): \(detail)"
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? why : "\(why)\n\(out)"
    }
}

/// Whether the app came up.
public struct RunReadyResult: Decodable, Sendable, Equatable {
    public var ready: Bool
    public var detail: String
    public init(ready: Bool, detail: String) {
        self.ready = ready
        self.detail = detail
    }
}

/// Try's report (decision 13): every step in order, and the ready check.
public struct RunTryResult: Decodable, Sendable, Equatable {
    public var passed: Bool
    public var steps: [RunStepResult]
    public var ready: RunReadyResult?
    public init(passed: Bool, steps: [RunStepResult], ready: RunReadyResult? = nil) {
        self.passed = passed
        self.steps = steps
        self.ready = ready
    }
    enum CodingKeys: String, CodingKey { case passed, steps, ready }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passed = try c.decodeIfPresent(Bool.self, forKey: .passed) ?? false
        steps = try c.decodeIfPresent([RunStepResult].self, forKey: .steps) ?? []
        ready = try c.decodeIfPresent(RunReadyResult.self, forKey: .ready)
    }
}

/// `value` (a tool's structured result) decoded as `T`.
func decodeRun<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
    var v = value
    if case .object(let o) = value, let s = o["structuredContent"] { v = s }
    let data = try JSONEncoder().encode(v)
    return try JSONDecoder().decode(T.self, from: data)
}

/// Whether `text` holds the ready line: a substring, or `/a regexp/` (as Go's `MatchReadyOutput`).
public func readyOutputMatches(_ pattern: String, in text: String) -> Bool {
    if pattern.count >= 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
        let body = String(pattern.dropFirst().dropLast())
        guard let re = try? NSRegularExpression(pattern: body) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    return text.contains(pattern)
}
