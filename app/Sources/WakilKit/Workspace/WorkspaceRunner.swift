import Foundation

// Workspaces, piece 2: Run, Stop and Build (decision 12). A repo's saved recipe runs in its
// workspace's checkout on the checkout's ports: needs and services once per workspace, copy,
// clone and setup once per checkout, then each process in a terminal pane of the workspace's view
// (the operator and the agent read it with `read_pane`), then the ready check. One-shot steps run
// headless in Go (`recipe_run_steps`), so a failure comes back whole (Rule 8).

/// Where a run's processes live: the window opens a terminal pane in the workspace's view at the
/// checkout, with the plan's environment, and runs the process's command in it.
public protocol RunTerminals: Sendable {
    /// Opens the pane and runs `command`; answers the pane's id.
    func start(title: String, workspace: Workspace, dir: String, environment: [String: String],
               command: String) async throws -> String
    /// Closes the pane, ending its shell and what runs in it.
    func stop(pane: String, workspace: Workspace) async
    /// What the pane shows, for a ready line.
    func output(pane: String, workspace: Workspace) async -> String
}

/// What one repo of a workspace is doing (the card's line, piece 3; `workspace_list`).
public struct RepoRunState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Wakil is getting it going: "setting up", "starting services", "waiting for ready".
        case starting(String)
        case running
        case failed(String)
        case building
    }
    public var repo: String
    public var port: Int?
    /// Process name to its terminal pane, in the recipe's order.
    public var processes: [(name: String, pane: String)]
    public var phase: Phase
    /// The ready check's sentence, once it answered.
    public var ready: String?

    public init(repo: String, port: Int? = nil, processes: [(name: String, pane: String)] = [], phase: Phase,
                ready: String? = nil) {
        self.repo = repo
        self.port = port
        self.processes = processes
        self.phase = phase
        self.ready = ready
    }

    public static func == (a: RepoRunState, b: RepoRunState) -> Bool {
        a.repo == b.repo && a.port == b.port && a.phase == b.phase && a.ready == b.ready
            && a.processes.map(\.name) == b.processes.map(\.name) && a.processes.map(\.pane) == b.processes.map(\.pane)
    }

    /// `api running on :41200 · queue running`; `api setting up`; `api failed`.
    public var line: String {
        switch phase {
        case .starting(let what): return "\(repo) \(what)"
        case .building: return "\(repo) building"
        case .failed: return "\(repo) failed"
        case .running:
            guard !processes.isEmpty else { return "\(repo) services up" }
            return processes.enumerated().map { i, p in
                let name = processes.count == 1 && p.name == repo ? repo : (i == 0 ? "\(repo) \(p.name)" : p.name)
                return i == 0 && port != nil ? "\(name) running on :\(port!)" : "\(name) running"
            }.joined(separator: " · ")
        }
    }
}

/// The card's run line for a workspace: each repo's, joined.
public func runStatusLine(_ states: [RepoRunState]) -> String {
    states.map(\.line).joined(separator: " · ")
}

/// What `workspace_run` answers.
public struct RunReport: Sendable, Equatable {
    public var repo: String
    public var port: Int?
    public var processes: [String: String]
    public var ready: RunReadyResult?
    public var warnings: [String]
    public var prepared: String?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "repo": .string(repo),
            "processes": .object(processes.mapValues { .string($0) }),
            "warnings": .array(warnings.map { .string($0) }),
        ]
        if let port { o["port"] = .integer(Int64(port)) }
        if let ready { o["ready"] = .object(["ready": .bool(ready.ready), "detail": .string(ready.detail)]) }
        if let prepared { o["prepared"] = .string(prepared) }
        return .object(o)
    }
}

/// A run's failure, said whole (Rule 8).
public struct RunError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Runs repos' saved recipes in workspaces. One run, stop or build at a time per workspace.
public actor WorkspaceRunner {
    public let router: WorkspaceRouter
    private var ctx: (any ToolCaller)?
    private var terminals: (any RunTerminals)?
    /// The project.json of a project registry key, so Go reads the workspace's project even when
    /// another is on screen; nil lets Go use the active one.
    private var projectPath: @Sendable (String) async -> String? = { _ in nil }
    /// The thread of the conversation that started a run: a failure is said there (Rule 8).
    private var say: @Sendable (_ conversation: String, _ text: String, _ isError: Bool) async -> Void = { _, _, _ in }
    /// Per workspace id, per repo name.
    private(set) var states: [String: [String: RepoRunState]] = [:]
    /// Per workspace id: the needs and services already started (once per workspace).
    private var started: [String: Set<String>] = [:]
    /// Per workspace id: repos whose services ran, so Stop runs their teardown.
    private var withServices: [String: [String]] = [:]
    /// Try's throwaway workspaces still open.
    private var tries: Set<String> = []
    /// Ready polling cadence, for tests.
    var pollInterval: Duration = .milliseconds(500)
    /// Long one-shot steps (setup, build) may take minutes.
    static let stepTimeout: TimeInterval = 60 * 60

    public init(router: WorkspaceRouter, ctx: (any ToolCaller)? = nil, terminals: (any RunTerminals)? = nil) {
        self.router = router
        self.ctx = ctx
        self.terminals = terminals
    }

    public func use(ctx: (any ToolCaller)?) { self.ctx = ctx }
    public func use(terminals: (any RunTerminals)?) { self.terminals = terminals }
    public func use(projectPath: @escaping @Sendable (String) async -> String?) { self.projectPath = projectPath }
    public func use(say: @escaping @Sendable (String, String, Bool) async -> Void) { self.say = say }
    func setPollInterval(_ d: Duration) { pollInterval = d }

    /// Every repo's state in workspace `id`, in the order runs started.
    public func state(of id: String) -> [RepoRunState] {
        (states[id] ?? [:]).values.sorted { $0.repo < $1.repo }
    }

    // MARK: Run

    /// Runs `repo` (a folder name or Main's path of a repo the workspace has a copy of) in
    /// workspace `id`: every process, or only `process`. `conversation` is the one that asked,
    /// told of a failure.
    public func run(_ id: String, repo: String, process: String? = nil, conversation: String? = nil) async throws -> RunReport {
        do {
            return try await runRepo(id, repo: repo, process: process, depth: 0)
        } catch {
            let text = "\(error)"
            if let conversation { await say(conversation, "Could not run \(repoLabel(repo)):\n\(text)", true) }
            throw error
        }
    }

    private func runRepo(_ id: String, repo: String, process: String?, depth: Int) async throws -> RunReport {
        guard depth < 16 else { throw RunError("\(repo)'s needs go round in a circle; fix them in the project's Running settings.") }
        var w = try await workspace(id)
        guard let co = checkout(of: repo, in: w) else {
            throw RunError("‘\(w.name)’ has no copy of \(repoLabel(repo)) yet, so it cannot run there: the app runs in its "
                + "workspace's copy (decision 12), made at the first change to it.")
        }
        guard co.path != nil else {
            throw RunError("‘\(w.name)’'s copy of \(co.repoName) is not on disk (archived, or brought to Main); it is re-made at its next change.")
        }
        w = try await router.ensurePorts(id)
        let checkout = w.checkout(of: co.repo) ?? co
        let name = checkout.repoName
        let alreadyRunning = states[id]?[name]?.processes ?? []
        setState(id, name, RepoRunState(repo: name, port: checkout.ports?.first, processes: alreadyRunning, phase: .starting("setting up")))
        do {
            let (plan, secretEnv, prepared) = try await prepare(w, repo: name, firstRun: !checkout.setUp)
            for need in plan.steps(RunPhase.need) where !(started[id] ?? []).contains(need.target) {
                started[id, default: []].insert(need.target)
                if need.targetKind == "service" {
                    try await runService(w, service: need.target)
                } else {
                    _ = try await runRepo(id, repo: need.target, process: nil, depth: depth + 1)
                }
            }
            if !plan.steps(RunPhase.service).isEmpty, !(started[id] ?? []).contains("services:\(name)") {
                setState(id, name, RepoRunState(repo: name, port: checkout.ports?.first, processes: alreadyRunning, phase: .starting("starting services")))
                try await oneShot(w, repo: name, phases: [RunPhase.service])
                started[id, default: []].insert("services:\(name)")
                if !(withServices[id] ?? []).contains(name) { withServices[id, default: []].append(name) }
            }
            if !checkout.setUp {
                if !plan.steps(RunPhase.setup).isEmpty {
                    setState(id, name, RepoRunState(repo: name, port: checkout.ports?.first, processes: alreadyRunning, phase: .starting("setting up")))
                    try await oneShot(w, repo: name, phases: [RunPhase.setup])
                }
                await router.markSetUp(id, repo: checkout.repo)
            }
            var procs = plan.processes
            if let process {
                procs = procs.filter { $0.name == process }
                if procs.isEmpty {
                    let names = plan.processes.map(\.name).joined(separator: ", ")
                    throw RunError("\(name)'s recipe has no process \(process); it has \(names.isEmpty ? "none" : names).")
                }
            }
            var running = alreadyRunning
            let env = plan.env.merging(secretEnv) { _, s in s }
            for p in procs where !running.contains(where: { $0.name == p.name }) {
                guard let terminals else { throw RunError("Run needs the window's terminals; none are open.") }
                let pane = try await terminals.start(
                    title: "\(name) · \(p.name)", workspace: w, dir: p.dir.isEmpty ? plan.dir : p.dir,
                    environment: env, command: p.command)
                running.append((p.name, pane))
            }
            var report = RunReport(repo: name, port: checkout.ports?.first,
                                   processes: Dictionary(running.map { ($0.name, $0.pane) }, uniquingKeysWith: { a, _ in a }),
                                   warnings: plan.warnings, prepared: prepared)
            setState(id, name, RepoRunState(repo: name, port: checkout.ports?.first, processes: running,
                                             phase: plan.ready == nil ? .running : .starting("waiting for ready")))
            if let ready = plan.ready, !running.isEmpty {
                let r = try await waitReady(ready, w: w, panes: running.map(\.pane))
                report.ready = r
                guard r.ready else {
                    setState(id, name, RepoRunState(repo: name, port: checkout.ports?.first, processes: running,
                                                     phase: .failed(r.detail), ready: r.detail))
                    throw RunError("\(name) started but is not ready: \(r.detail). Its terminals stay open to read.")
                }
                setState(id, name, RepoRunState(repo: name, port: checkout.ports?.first, processes: running,
                                                 phase: .running, ready: r.detail))
            }
            return report
        } catch {
            if case .failed = states[id]?[name]?.phase {} else {
                var s = states[id]?[name] ?? RepoRunState(repo: name, port: checkout.ports?.first, phase: .failed(""))
                s.phase = .failed("\(error)")
                setState(id, name, s)
            }
            throw error
        }
    }

    /// A shared service (a recipe with only services), started once per workspace in the repo
    /// it names (`in`), which must have a copy here.
    private func runService(_ w: Workspace, service: String) async throws {
        try await oneShot(w, repo: service, phases: [RunPhase.service])
        if !(withServices[w.id] ?? []).contains(service) { withServices[w.id, default: []].append(service) }
    }

    // MARK: Stop

    /// Stops `repo`'s processes in workspace `id` (closing their terminals), or, with no repo,
    /// every process and then each started service's teardown.
    @discardableResult
    public func stop(_ id: String, repo: String? = nil) async throws -> [String] {
        let w = try await workspace(id)
        var stopped: [String] = []
        let names: [String]
        if let repo {
            guard let co = checkout(of: repo, in: w) else {
                throw RunError("‘\(w.name)’ has no copy of \(repoLabel(repo)), so nothing of it is running.")
            }
            names = [co.repoName]
        } else {
            names = Array((states[id] ?? [:]).keys).sorted()
        }
        for name in names {
            for p in states[id]?[name]?.processes ?? [] {
                await terminals?.stop(pane: p.pane, workspace: w)
                stopped.append("\(name) · \(p.name)")
            }
            states[id]?[name] = nil
        }
        if repo == nil {
            var problems: [String] = []
            for owner in (withServices[id] ?? []).reversed() {
                do { try await oneShot(w, repo: owner, phases: [RunPhase.teardown]) } catch { problems.append("\(error)") }
            }
            withServices[id] = nil
            started[id] = nil
            if !problems.isEmpty { throw RunError("Stopped, but teardown failed:\n" + problems.joined(separator: "\n")) }
        }
        return stopped
    }

    /// Archive's run hook: everything stopped, teardown run; a failure does not stop Archive.
    public func archiving(_ w: Workspace) async {
        guard states[w.id] != nil || withServices[w.id] != nil else { return }
        _ = try? await stop(w.id)
    }

    // MARK: Build

    /// Runs `repo`'s one-shot build in its copy; answers the step, output whole.
    public func build(_ id: String, repo: String, conversation: String? = nil) async throws -> RunStepResult {
        let w0 = try await workspace(id)
        guard let co = checkout(of: repo, in: w0), co.path != nil else {
            throw RunError("‘\(w0.name)’ has no copy of \(repoLabel(repo)) to build in; the copy is made at the first change to it.")
        }
        let w = try await router.ensurePorts(id)
        let before = states[id]?[co.repoName]
        setState(id, co.repoName, RepoRunState(repo: co.repoName, port: co.ports?.first, processes: before?.processes ?? [], phase: .building))
        defer {
            if let before { setState(id, co.repoName, before) } else { states[id]?[co.repoName] = nil }
        }
        do {
            let steps = try await oneShot(w, repo: co.repoName, phases: [RunPhase.build])
            guard let step = steps.first else {
                throw RunError("\(co.repoName)'s recipe has no build; add one in the project's Running settings.")
            }
            return step
        } catch {
            if let conversation { await say(conversation, "Could not build \(co.repoName):\n\(error)", true) }
            throw error
        }
    }

    // MARK: Try

    /// Try (decision 13): a throwaway workspace with a copy of `root` from its folder's commit and
    /// its own ports; Go runs services, setup, the processes headless and the ready check, then
    /// stops them and runs teardown. Answers the workspace (for `endTry`) and the report.
    public func tryRecipe(repo: String, root: String, project: String, environment: String,
                          projectPath: String?) async throws -> (String, RunTryResult) {
        let all = await router.store.all()
        let slug = uniqueSlug("try-" + branchSlug(repo), taken: Set(all.filter { $0.project == project }.map(\.slug)))
        let branch = "wakil-try/\(slug)"
        let made = try await router.call("git_worktree_add", [
            "root": .string(root), "project": .string(project), "slug": .string(slug),
            "branch": .string(branch), "create": .bool(true), "from": .string("HEAD"),
        ])
        guard let path = router.string(made, "path"), !path.isEmpty else { throw RunError("Try: no copy of \(repo) was made") }
        let w = Workspace(id: "try-" + UUID().uuidString.lowercased(), name: "Try \(repo)", slug: slug, project: project,
                          environment: environment, branch: branch,
                          checkouts: [WorkspaceCheckout(repo: root, path: path, branch: branch)],
                          created: ISO8601DateFormatter().string(from: Date()))
        await router.store.add(w)
        try await router.store.save()
        tries.insert(w.id)
        let ready = try await router.ensurePorts(w.id)
        // The project is named (by key, and by path when Settings has it): Go plans that project's
        // recipe, never the screen's (the walk).
        var args: [String: JSONValue] = ["repo": .string(repo), "workspace": .string(slug), "checkouts": checkoutsArg(ready),
                                         "project": .string(project)]
        if let projectPath { args["projectPath"] = .string(projectPath) }
        let r = try await call("recipe_try", args, timeout: Self.stepTimeout)
        return (w.id, try decodeRun(RunTryResult.self, r))
    }

    /// Ends a Try: its workspace archived (the copy removed; its `wakil-try/` branch stays, as
    /// Archive keeps branches) and forgotten.
    public func endTry(_ id: String) async throws {
        guard tries.contains(id) else { throw RunError("\(id) is not a Try workspace") }
        _ = try await router.archive(id, confirmed: true)
        await router.store.remove(id)
        try await router.store.save()
        tries.remove(id)
    }

    // MARK: Go

    private func checkoutsArg(_ w: Workspace) -> JSONValue {
        .array(w.checkouts.compactMap { co in
            guard let path = co.path else { return nil }
            var o: [String: JSONValue] = ["repo": .string(co.repoName), "path": .string(path)]
            if let p = co.ports { o["port"] = .integer(Int64(p.first)) }
            return .object(o)
        })
    }

    private func planArgs(_ w: Workspace, repo: String) async -> [String: JSONValue] {
        // The workspace's project by key, so a card of a project other than the screen's never
        // plans the screen's recipe when its project.json path is not read yet.
        var args: [String: JSONValue] = ["repo": .string(repo), "workspace": .string(w.slug), "checkouts": checkoutsArg(w),
                                         "project": .string(w.project)]
        if let path = await projectPath(w.project) { args["projectPath"] = .string(path) }
        return args
    }

    private func call(_ tool: String, _ args: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
        guard let ctx else { throw RunError("\(tool): wakil-ctx is not running") }
        do {
            return try await callCheckedTool(ctx, tool: tool, arguments: .object(args), action: tool, timeout: timeout)
        } catch let e as RunError {
            throw e
        } catch {
            throw RunError(runErrorText(error))
        }
    }

    private func prepare(_ w: Workspace, repo: String, firstRun: Bool) async throws -> (RunPlan, [String: String], String?) {
        var args = await planArgs(w, repo: repo)
        args["firstRun"] = .bool(firstRun)
        let r = try await call("recipe_prepare", args, timeout: MCPClient.mutationReplyTimeout)
        var value = r
        if case .object(let o) = r, let s = o["structuredContent"] { value = s }
        guard case .object(let o) = value, let planValue = o["plan"] else { throw RunError("recipe_prepare answered no plan") }
        let plan = try decodeRun(RunPlan.self, planValue)
        var secrets: [String: String] = [:]
        if case .object(let s)? = o["secretEnv"] {
            for (k, v) in s { if case .string(let str) = v { secrets[k] = str } }
        }
        var summary: String?
        if case .object(let p)? = o["prepared"] {
            var parts: [String] = []
            for key in ["copied", "cloned"] {
                if case .array(let a)? = p[key], !a.isEmpty {
                    parts.append("\(key) " + a.compactMap { if case .string(let s) = $0 { s } else { nil } }.joined(separator: ", "))
                }
            }
            if !parts.isEmpty { summary = parts.joined(separator: "; ") }
        }
        return (plan, secrets, summary)
    }

    @discardableResult
    private func oneShot(_ w: Workspace, repo: String, phases: [String]) async throws -> [RunStepResult] {
        var args = await planArgs(w, repo: repo)
        args["phases"] = .array(phases.map { .string($0) })
        let r = try await call("recipe_run_steps", args, timeout: Self.stepTimeout)
        var value = r
        if case .object(let o) = r, let s = o["structuredContent"] { value = s }
        var steps: [RunStepResult] = []
        var ok = true
        if case .object(let o) = value {
            if case .array(let a)? = o["steps"] { steps = try a.map { try decodeRun(RunStepResult.self, $0) } }
            if case .bool(let b)? = o["ok"] { ok = b }
        }
        if !ok, let failed = steps.last(where: { !$0.ok }) { throw RunError(failed.failureText) }
        return steps
    }

    private func waitReady(_ ready: RunReady, w: Workspace, panes: [String]) async throws -> RunReadyResult {
        if let url = ready.url {
            let r = try await call("recipe_ready_wait", ["url": .string(url), "timeoutSeconds": .integer(Int64(ready.timeoutSeconds))],
                                   timeout: TimeInterval(ready.timeoutSeconds + 15))
            return try decodeRun(RunReadyResult.self, r)
        }
        guard let line = ready.output else { return RunReadyResult(ready: true, detail: "no ready check") }
        let deadline = ContinuousClock.now + .seconds(ready.timeoutSeconds)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            for pane in panes {
                if readyOutputMatches(line, in: await terminals?.output(pane: pane, workspace: w) ?? "") {
                    return RunReadyResult(ready: true, detail: "the output shows \(line)")
                }
            }
            try await Task.sleep(for: pollInterval)
        }
        return RunReadyResult(ready: false, detail: "the output did not show \(line) within \(ready.timeoutSeconds) s")
    }

    // MARK: helpers

    private func workspace(_ id: String) async throws -> Workspace {
        guard let w = await router.store.workspace(id) else { throw RunError("There is no workspace \(id)") }
        guard !w.archived else { throw RunError("‘\(w.name)’ is archived; restore it to run it.") }
        return w
    }

    private func checkout(of repo: String, in w: Workspace) -> WorkspaceCheckout? {
        w.checkouts.first { $0.repo == repo || $0.repoName == repo }
    }

    private func setState(_ id: String, _ repo: String, _ s: RepoRunState) {
        states[id, default: [:]][repo] = s
    }

    nonisolated private func repoLabel(_ repo: String) -> String { (repo as NSString).lastPathComponent }
}

/// A tool failure's text, without the action prefix noise where it is plain.
func runErrorText(_ error: Error) -> String { "\(error)" }
