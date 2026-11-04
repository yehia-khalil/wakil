import Foundation

// Workspaces, piece 2 (the Running comp, 2026-11-02): the page reads as what ▶ does, top to bottom —
// prepare the copy, start, ready, stop — one spine with four stops. A field the recipe and the repo
// leave unset is not a row but a "+ <Field>" chip at the end of its stop; ports leave the spine for
// a table beside the environment; a Try lights each stop by the steps that ran in it. What the page
// decides is here, tested; `RunningSettingsForm` only draws it.

/// One stop on the Running page's spine, in the order ▶ runs them.
public enum RunStop: String, CaseIterable, Sendable {
    case prepare, start, ready, stop

    public var title: String {
        switch self {
        case .prepare: "Prepare a new copy"
        case .start: "Start"
        case .ready: "Ready when"
        case .stop: "Stop"
        }
    }

    /// When the stop runs, beside its title.
    public var when: String {
        switch self {
        case .prepare: "once, on the first ▶ in a new workspace"
        case .start: "every ▶, in this order"
        case .ready: "the run counts as up"
        case .stop: "on ■ Stop or Archive"
        }
    }

    /// The stop's fields, in the order they run. Port mapping is in none: it applies to them all.
    public var fields: [RecipeField] {
        switch self {
        case .prepare: [.copy, .clone, .setup, .build]
        case .start: [.needs, .services, .processes]
        case .ready: [.ready]
        case .stop: [.teardown]
        }
    }

    /// The stop a Try step runs in, by its phase (`wakilcore`'s, and the window's own `copy`).
    public static func of(phase: String) -> RunStop? {
        switch phase {
        case "copy", "prepare", RunPhase.clone, RunPhase.setup, RunPhase.build: .prepare
        case RunPhase.need, RunPhase.service, RunPhase.process: .start
        case "ready": .ready
        case RunPhase.teardown: .stop
        default: nil
        }
    }
}

extension RecipeField {
    /// The chip's word for a field not yet set: `+ Build`.
    public var chipLabel: String {
        switch self {
        case .ready: "Ready"
        case .ports: "Port"
        default: label
        }
    }

    /// What a chip adds after its word, when the word alone does not say it.
    public var chipHint: String? {
        self == .needs ? "start another repo first" : nil
    }

    /// The row's label: the ready check says how it is met — `Answers` a URL, `Prints` a line.
    public func rowLabel(in r: Recipe) -> String {
        guard self == .ready else { return label }
        return r.ready?.url != nil ? "Answers" : r.ready?.output != nil ? "Prints" : "Ready"
    }

    /// The field's text as the page draws it: processes as `name  command`, the names aligned;
    /// every other field as `text(in:)`. `set` reads both forms back.
    public func formText(in r: Recipe) -> String {
        guard self == .processes, let ps = r.processes, !ps.isEmpty else { return text(in: r) }
        let width = ps.map(\.name.count).max() ?? 0
        return ps.map { p in
            p.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + p.command
                + (p.afterReady == true ? afterReadyMark : "")
        }.joined(separator: "\n")
    }
}

/// A stop's fields: the rows drawn, then the chips for the rest.
public struct RunStopFields: Sendable, Equatable {
    public var rows: [RecipeField]
    public var chips: [RecipeField]
    public init(rows: [RecipeField], chips: [RecipeField]) { self.rows = rows; self.chips = chips }
}

/// One port mapping: the repo's variable, the expression it is set to, and the port that is in the
/// first workspace's block when the expression is a plain `$WAKIL_PORT` / `$WAKIL_PORT_n`.
public struct RunPortRow: Sendable, Equatable {
    public var variable: String
    public var expression: String
    public var port: Int?
    public init(variable: String, expression: String, port: Int?) {
        self.variable = variable; self.expression = expression; self.port = port
    }
}

/// The first port of the first workspace's block (`wakilcore.PortBlockStart`), and its size.
public let runPortBlockStart = 41200
public let runPortBlockSize = 10

/// The port `expression` is in the first block: `$WAKIL_PORT` 41200, `$WAKIL_PORT_3` 41203 (braces
/// too); nil for anything else — another repo's port, a URL, a sum — which is shown as written.
public func firstBlockPort(_ expression: String) -> Int? {
    var e = expression.trimmingCharacters(in: .whitespaces)
    guard e.hasPrefix("$") else { return nil }
    e.removeFirst()
    if e.hasPrefix("{") {
        guard e.hasSuffix("}") else { return nil }
        e = String(e.dropFirst().dropLast())
    }
    if e == "WAKIL_PORT" { return runPortBlockStart }
    guard e.hasPrefix("WAKIL_PORT_") else { return nil }
    let n = e.dropFirst("WAKIL_PORT_".count)
    guard n.count == 1, let i = Int(n), i >= 0, i < runPortBlockSize else { return nil }
    return runPortBlockStart + i
}

extension RunningSettings {
    /// The recipe `repo` names, or an empty one.
    private func shared(_ repo: String) -> Recipe {
        self.repo(repo)?.recipeName.flatMap { recipes[$0] } ?? Recipe()
    }

    /// The recipe as `repo` runs it: its own fields over the recipe's.
    public func effectiveRecipe(of repo: String) -> Recipe {
        guard let row = self.repo(repo) else { return Recipe() }
        let own = row.overrides ?? Recipe()
        var r = shared(repo)
        for f in RecipeField.allCases where f.isSet(in: own) {
            switch f {
            case .needs: r.needs = own.needs
            case .copy: r.copy = own.copy
            case .clone: r.clone = own.clone
            case .ports: r.ports = own.ports
            case .services: r.services = own.services
            case .setup: r.setup = own.setup
            case .processes: r.processes = own.processes
            case .build: r.build = own.build
            case .ready: r.ready = own.ready
            case .teardown: r.teardown = own.teardown
            }
        }
        return r
    }

    /// Whether `f` is a row of `repo`'s page: it has a value, or the repo's own empty value hides
    /// the recipe's ("none, here" — drawn, so it can be seen and undone with Use the recipe's).
    public func isDrawn(_ f: RecipeField, of repo: String) -> Bool {
        let field = field(f, of: repo)
        if !field.text.isEmpty { return true }
        return field.source == .repo && f.isSet(in: shared(repo))
    }

    /// A stop's rows and chips for `repo`. `open` holds the fields the operator opened from a chip
    /// or is editing: drawn whatever they hold, so a field emptied while typed in stays put until
    /// it is left.
    public func stopFields(_ stop: RunStop, of repo: String, open: Set<RecipeField> = []) -> RunStopFields {
        var rows: [RecipeField] = []
        var chips: [RecipeField] = []
        for f in stop.fields {
            if isDrawn(f, of: repo) || open.contains(f) { rows.append(f) } else { chips.append(f) }
        }
        return RunStopFields(rows: rows, chips: chips)
    }

    /// The text `f`'s row edits and draws (`formText`), from whichever recipe it comes from.
    public func formText(_ f: RecipeField, of repo: String) -> String {
        guard let row = self.repo(repo) else { return "" }
        let own = row.overrides ?? Recipe()
        if f.isSet(in: own) { return f.formText(in: own) }
        return f.formText(in: shared(repo))
    }

    /// The row's label as `repo` runs it (`rowLabel`).
    public func rowLabel(_ f: RecipeField, of repo: String) -> String {
        f.rowLabel(in: effectiveRecipe(of: repo))
    }

    /// The port mappings `repo` runs with, by variable.
    public func portRows(of repo: String) -> [RunPortRow] {
        (effectiveRecipe(of: repo).ports ?? [:]).sorted { $0.key < $1.key }.map {
            RunPortRow(variable: $0.key, expression: $0.value, port: firstBlockPort($0.value))
        }
    }
}

// MARK: Try on the spine

/// How a stop's node is drawn during or after a Try.
public enum RunStopStatus: Sendable, Equatable {
    /// No Try, or nothing of this stop has run yet: hollow.
    case idle
    /// A step of it is running, or it is part way: violet, breathing.
    case running
    /// Every step of it passed: green.
    case passed
    /// A step of it failed: red.
    case failed
    /// The Try ended before any step of it ran.
    case notReached
}

/// One Try step, as the stop it runs in lists it: its index in the whole list (the row's
/// identifier) and its state.
public struct RunStopStep: Sendable, Equatable {
    public var index: Int
    public var step: TryStepState
    public init(index: Int, step: TryStepState) { self.index = index; self.step = step }
}

/// A stop during or after a Try: its status, its steps, and what its header says in place of when
/// it runs.
public struct RunStopProgress: Sendable, Equatable {
    public var status: RunStopStatus
    public var steps: [RunStopStep]
    public var when: String
    public init(status: RunStopStatus, steps: [RunStopStep], when: String) {
        self.status = status; self.steps = steps; self.when = when
    }

    /// The failed step, whose error the stop shows whole under its fields (Rule 8).
    public var failed: TryStepState? { steps.first { $0.step.state == .failed }?.step }
}

/// A finished Try's report as step rows, the ready check last when the report has no row of its
/// own for it — what the page draws when no live progress was kept.
public func tryStepStates(_ report: RunTryResult) -> [TryStepState] {
    var out = report.steps.map {
        TryStepState(phase: $0.phase, name: $0.name, command: $0.command, state: $0.ok ? .done : .failed,
                     seconds: $0.seconds, output: $0.output, detail: $0.detail)
    }
    if let ready = report.ready, !out.contains(where: { $0.phase == "ready" }) {
        out.append(TryStepState(phase: "ready", state: ready.ready ? .done : .failed, detail: ready.detail))
    }
    return out
}

/// Each stop's progress, from a Try's step rows. `finished`: the Try ended, so a stop none of whose
/// steps ran was not reached. A step of no stop (none today) is left out.
public func runStopProgress(_ steps: [TryStepState], finished: Bool) -> [RunStop: RunStopProgress] {
    var out: [RunStop: RunStopProgress] = [:]
    for stop in RunStop.allCases {
        let mine = steps.enumerated().filter { RunStop.of(phase: $0.element.phase) == stop }
            .map { RunStopStep(index: $0.offset, step: $0.element) }
        let states = mine.map(\.step.state)
        let status: RunStopStatus
        if states.isEmpty {
            status = finished ? .notReached : .idle
        } else if states.contains(.failed) {
            status = .failed
        } else if states.contains(.running) {
            status = .running
        } else if states.allSatisfy({ $0 == .done }) {
            status = .passed
        } else if states.contains(.done) {
            status = finished ? .notReached : .running
        } else {
            status = finished ? .notReached : .idle
        }
        out[stop] = RunStopProgress(status: status, steps: mine, when: stopWhen(stop, status, mine.map(\.step), finished: finished))
    }
    return out
}

private func stopWhen(_ stop: RunStop, _ status: RunStopStatus, _ steps: [TryStepState], finished: Bool) -> String {
    switch status {
    case .passed: return "done in \(runElapsed(steps.reduce(0) { $0 + $1.seconds }))"
    case .failed:
        let s = steps.first { $0.state == .failed }!
        return "\(stepWord(s)) failed"
    case .running:
        let now = steps.first { $0.state == .running }
        return now.map { "\(stepWord($0)) running" } ?? "running"
    case .notReached: return "not reached"
    case .idle: return stop == .stop && !finished ? "runs when the Try ends" : "to come"
    }
}

/// A step in a word or two: a process by its name, anything else by its phase.
private func stepWord(_ s: TryStepState) -> String {
    if s.phase == RunPhase.process, !s.name.isEmpty { return s.name }
    return s.phase == "ready" ? "ready check" : s.phase
}

/// The Try's status line after its title: the stop and step running now and the time so far —
/// `Start · web started · python3 -m http.server · 1 min 12 s`; before any step, the time alone.
public func tryStatusDetail(_ steps: [TryStepState], elapsed: Double) -> String {
    let time = runElapsed(elapsed)
    guard let now = steps.first(where: { $0.state == .running }) else { return time }
    let stop = RunStop.of(phase: now.phase).map { "\($0.title) · " } ?? ""
    return "\(stop)\(now.title) · \(time)"
}
