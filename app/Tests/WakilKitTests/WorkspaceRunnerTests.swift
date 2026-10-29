import Foundation
import Testing
@testable import WakilKit

// Run, Stop and Build (workspaces, piece 2): the order of a run, what runs once, port blocks in
// the record, a failure whole, and the agent's reach.

private actor FakeTerminals: RunTerminals {
    var started: [(title: String, dir: String, env: [String: String], command: String)] = []
    var stopped: [String] = []
    var screens: [String: String] = [:]
    var failStart = false
    func start(title: String, workspace: Workspace, dir: String, environment: [String: String], command: String) async throws -> String {
        if failStart { throw RunError("no terminal") }
        started.append((title, dir, environment, command))
        let pane = "terminal-\(started.count)"
        screens[pane] = "  VITE ready\n  Local: http://localhost:\(environment["WAKIL_PORT"] ?? "")"
        return pane
    }
    func stop(pane: String, workspace: Workspace) async { stopped.append(pane) }
    func output(pane: String, workspace: Workspace) async -> String { screens[pane] ?? "" }
}

private struct PlanSpec: Sendable {
    var services: [String] = []
    var setup: [String] = []
    var processes: [(String, String)] = [("dev", "pnpm dev --port $WAKIL_PORT")]
    var needs: [(String, String)] = []
    var ready: JSONValue? = .object(["output": .string("Local:"), "timeoutSeconds": .integer(2)])
    var failPhase: String?
    var build: String? = "pnpm build"
}

private func plan(_ repo: String, _ spec: PlanSpec, port: Int) -> JSONValue {
    var steps: [JSONValue] = spec.needs.map { .object(["phase": .string("need"), "target": .string($0.0), "targetKind": .string($0.1), "once": .string("workspace")]) }
    steps += spec.services.map { .object(["phase": .string("service"), "command": .string($0), "once": .string("workspace")]) }
    steps += spec.setup.map { .object(["phase": .string("setup"), "command": .string($0), "once": .string("checkout")]) }
    steps += spec.processes.map { .object(["phase": .string("process"), "name": .string($0.0), "command": .string($0.1), "longRunning": .bool(true)]) }
    var o: [String: JSONValue] = [
        "repo": .string(repo), "dir": .string("/h/ws/estate/fix/\(repo)"),
        "env": .object(["WAKIL_PORT": .string("\(port)")]), "secrets": .object(["STRIPE": .string("wakil:initech:s")]),
        "steps": .array(steps), "teardown": .array([.object(["phase": .string("teardown"), "command": .string("docker compose down")])]),
        "warnings": .array([]),
    ]
    if let r = spec.ready { o["ready"] = r }
    if let b = spec.build { o["build"] = .object(["phase": .string("build"), "command": .string(b)]) }
    return .object(o)
}

private func fakeCtx(_ specs: [String: PlanSpec]) -> RecordingToolCaller {
    RecordingToolCaller(reply: { name, args in
        guard case .object(let a) = args else { return .object([:]) }
        func s(_ k: String) -> String { if case .string(let v)? = a[k] { v } else { "" } }
        switch name {
        case "ports_allocate":
            guard case .array(let want)? = a["want"] else { return .object([:]) }
            var blocks: [String: JSONValue] = [:]
            for (i, k) in want.enumerated() { if case .string(let key) = k { blocks[key] = .integer(Int64(41200 + 10 * i)) } }
            return .object(["blocks": .object(blocks), "taken": .array([])])
        case "recipe_prepare":
            var port = 0
            if case .array(let cos)? = a["checkouts"] {
                for c in cos { if case .object(let co) = c, co["repo"] == .string(s("repo")), case .integer(let p)? = co["port"] { port = Int(p) } }
            }
            return .object(["plan": plan(s("repo"), specs[s("repo")] ?? PlanSpec(), port: port),
                            "prepared": .object(["copied": .array([.string(".env")]), "cloned": .array([])]),
                            "secretEnv": .object(["STRIPE": .string("sk_live")])])
        case "recipe_run_steps":
            guard case .array(let phases)? = a["phases"], case .string(let phase)? = phases.first else { return .object([:]) }
            let spec = specs[s("repo")] ?? PlanSpec()
            if spec.failPhase == phase {
                return .object(["ok": .bool(false), "steps": .array([.object([
                    "phase": .string(phase), "command": .string("composer install"), "ok": .bool(false), "exitCode": .integer(1),
                    "output": .string("Your lock file is out of date."), "detail": .string("composer install exited with 1."),
                ])])])
            }
            let commands: [String] = phase == "service" ? spec.services : phase == "setup" ? spec.setup
                : phase == "build" ? (spec.build.map { [$0] } ?? []) : ["docker compose down"]
            return .object(["ok": .bool(true), "steps": .array(commands.map {
                .object(["phase": .string(phase), "command": .string($0), "ok": .bool(true), "output": .string("done")])
            })])
        case "recipe_ready_wait":
            return .object(["ready": .bool(true), "detail": .string("\(s("url")) answered 200")])
        default:
            return .object([:])
        }
    })
}

private func runner(_ specs: [String: PlanSpec], checkouts: [WorkspaceCheckout] = [
    WorkspaceCheckout(repo: "/p/web", path: "/h/ws/estate/fix/web", branch: "fix"),
    WorkspaceCheckout(repo: "/p/api", path: "/h/ws/estate/fix/api", branch: "fix"),
], saved: SavedFiles = SavedFiles()) async -> (WorkspaceRunner, RecordingToolCaller, FakeTerminals) {
    let store = WorkspaceStore()
    let file = WorkspacesFile(workspaces: [
        Workspace(id: "w1", name: "Fix OTP", slug: "fix", project: "estate", environment: "staging", branch: "fix",
                  checkouts: checkouts, conversations: ["root-c1"]),
        Workspace(id: "w0", name: "Older", slug: "older", project: "estate", environment: "staging",
                  checkouts: [WorkspaceCheckout(repo: "/p/web", path: "/h/ws/estate/older/web", branch: "older",
                                                ports: PortBlock(first: 41300, count: 10))]),
    ])
    await store.use(load: { file }, save: { f in await saved.add(f) })
    await store.ensure(org: "initech")
    let router = WorkspaceRouter(store: store)
    let ctx = fakeCtx(specs)
    await router.use(ctx: ctx)
    let terms = FakeTerminals()
    let r = WorkspaceRunner(router: router, ctx: ctx, terminals: terms)
    await r.setPollInterval(.milliseconds(10))
    return (r, ctx, terms)
}

actor SavedFiles {
    var files: [WorkspacesFile] = []
    func add(_ f: WorkspacesFile) { files.append(f) }
}

@Test func runGivesTheCheckoutAPortBlockKeepingOthersAndRecordsIt() async throws {
    let saved = SavedFiles()
    let (r, ctx, _) = await runner(["web": PlanSpec()], saved: saved)
    let report = try await r.run("w1", repo: "web")
    #expect(report.port == 41200)
    let allocate = await ctx.calls.first { $0.name == "ports_allocate" }
    #expect(allocate?.arguments == .object([
        "existing": .object(["w0/web": .integer(41300)]),
        "want": .array([.string("w1/web"), .string("w1/api")]),
    ]))
    let last = await saved.files.last
    let co = last?.workspaces.first { $0.id == "w1" }?.checkout(of: "/p/web")
    #expect(co?.ports == PortBlock(first: 41200, count: 10))
    #expect(co?.setUp == true)
    // A second run allocates nothing.
    _ = try await r.stop("w1", repo: "web")
    _ = try await r.run("w1", repo: "web")
    #expect(await ctx.calls.filter { $0.name == "ports_allocate" }.count == 1)
}

@Test func runStartsNeedsAndServicesOnceSetupOnceThenEachProcessInATerminal() async throws {
    let specs = [
        "web": PlanSpec(services: [], setup: ["pnpm install"], processes: [("dev", "pnpm dev")], needs: [("api", "repo")]),
        "api": PlanSpec(services: ["docker compose up -d mysql"], setup: ["composer install"],
                        processes: [("app", "php artisan serve"), ("queue", "php artisan queue:work")],
                        ready: .object(["url": .string("http://localhost:41210/up"), "timeoutSeconds": .integer(5)])),
    ]
    let (r, ctx, terms) = await runner(specs)
    let report = try await r.run("w1", repo: "web")
    #expect(report.ready?.ready == true)
    let order = await ctx.calls.compactMap { call -> String? in
        guard call.name == "recipe_run_steps" || call.name == "recipe_prepare",
              case .object(let a) = call.arguments, case .string(let repo)? = a["repo"] else { return nil }
        if case .array(let p)? = a["phases"], case .string(let ph)? = p.first { return "\(repo):\(ph)" }
        return "\(repo):prepare"
    }
    #expect(order == ["web:prepare", "api:prepare", "api:service", "api:setup", "web:setup"])
    let titles = await terms.started.map(\.title)
    #expect(titles == ["api · app", "api · queue", "web · dev"])
    // The secrets reach the process's terminal, and nothing else.
    #expect(await terms.started.last?.env["STRIPE"] == "sk_live")
    #expect(await terms.started.last?.env["WAKIL_PORT"] == "41200")
    // Running again starts nothing new: the services and setup ran, the processes run.
    _ = try await r.run("w1", repo: "web")
    #expect(await terms.started.count == 3)
    #expect(await ctx.calls.filter { $0.name == "recipe_run_steps" }.count == 3)
    let line = runStatusLine(await r.state(of: "w1"))
    #expect(line == "api app running on :41210 · queue running · web dev running on :41200")
}

@Test func aProcessFilterStartsOnlyThatProcessAndAnUnknownOneIsNamed() async throws {
    let (r, _, terms) = await runner(["api": PlanSpec(processes: [("app", "serve"), ("queue", "work")], ready: nil)])
    _ = try await r.run("w1", repo: "api", process: "queue")
    #expect(await terms.started.map(\.title) == ["api · queue"])
    await #expect(throws: RunError("api's recipe has no process mail; it has app, queue.")) {
        try await r.run("w1", repo: "api", process: "mail")
    }
}

@Test func aFailingSetupIsAnsweredWholeTheStateSaysFailedAndTheThreadIsTold() async throws {
    let (r, _, terms) = await runner(["api": PlanSpec(setup: ["composer install"], failPhase: "setup")])
    let said = Lines()
    await r.use(say: { c, t, e in await said.add(c, t, e) })
    do {
        _ = try await r.run("w1", repo: "api", conversation: "c1")
        Issue.record("expected a failure")
    } catch {
        #expect("\(error)" == "setup `composer install`: composer install exited with 1.\nYour lock file is out of date.")
    }
    #expect(await terms.started.isEmpty)
    #expect(runStatusLine(await r.state(of: "w1")) == "api failed")
    let told = await said.lines.first
    #expect(told?.0 == "c1" && told?.2 == true)
    #expect(told?.1.hasSuffix("Your lock file is out of date.") == true)
}

@Test func runRefusesARepoWithNoCopyNamingDecision12() async throws {
    let (r, _, _) = await runner([:], checkouts: [WorkspaceCheckout(repo: "/p/web", path: "/h/ws/estate/fix/web", branch: "fix")])
    await #expect(throws: RunError("‘Fix OTP’ has no copy of api yet, so it cannot run there: the app runs in its workspace's "
        + "copy (decision 12), made at the first change to it.")) {
        try await r.run("w1", repo: "api")
    }
}

@Test func aReadyLineThatNeverShowsFailsAndKeepsTheTerminalsOpen() async throws {
    let (r, _, terms) = await runner(["web": PlanSpec(ready: .object(["output": .string("/Listening on \\d+/"), "timeoutSeconds": .integer(0)]))])
    do {
        _ = try await r.run("w1", repo: "web")
        Issue.record("expected not ready")
    } catch {
        #expect("\(error)".contains("did not show /Listening on \\d+/"))
    }
    #expect(await terms.stopped.isEmpty)
}

@Test func stopClosesTheTerminalsAndStoppingTheWorkspaceRunsTeardown() async throws {
    let (r, ctx, terms) = await runner(["api": PlanSpec(services: ["docker compose up -d"], ready: nil)])
    _ = try await r.run("w1", repo: "api")
    let stopped = try await r.stop("w1")
    #expect(stopped == ["api · dev"])
    #expect(await terms.stopped == ["terminal-1"])
    let teardown = await ctx.calls.last { $0.name == "recipe_run_steps" }
    if case .object(let a)? = teardown?.arguments { #expect(a["phases"] == .array([.string("teardown")])) } else { Issue.record("no teardown") }
    #expect(await r.state(of: "w1").isEmpty)
}

@Test func buildAnswersTheStepAndAMissingBuildIsNamed() async throws {
    let (r, _, _) = await runner(["web": PlanSpec(), "api": PlanSpec(build: nil)])
    let step = try await r.build("w1", repo: "web")
    #expect(step.ok && step.command == "pnpm build")
    await #expect(throws: RunError("api's recipe has no build; add one in the project's Running settings.")) {
        try await r.build("w1", repo: "api")
    }
}

@Test func readyOutputMatchesASubstringOrARegexp() {
    #expect(readyOutputMatches("Local:", in: "  Local: http://x"))
    #expect(readyOutputMatches("/listening on \\d+/", in: "listening on 41200"))
    #expect(!readyOutputMatches("/listening on \\d+/", in: "listening on port"))
}

@Test func theStatusLineNamesEachRepoAndItsFirstPort() {
    #expect(runStatusLine([
        RepoRunState(repo: "api", port: 41200, processes: [("app", "t1"), ("queue", "t2")], phase: .running),
        RepoRunState(repo: "web", phase: .starting("setting up")),
    ]) == "api app running on :41200 · queue running · web setting up")
}

private actor Lines {
    var lines: [(String, String, Bool)] = []
    func add(_ c: String, _ t: String, _ e: Bool) { lines.append((c, t, e)) }
}

// The actions: an agent runs only in its own workspace, never from Main; the operator names one.

private func registryWithRun(_ specs: [String: PlanSpec]) async -> (ActionRegistry, WorkspaceRunner, FakeTerminals) {
    let (r, _, terms) = await runner(specs)
    await r.router.install(WorkspaceRouterHooks(
        conversation: { id in
            WorkspaceConversationFacts(id: id, lineageRoot: "root-\(id)", title: "t", organization: "initech",
                                       project: "estate", environment: "staging", mainRoots: ["/p/web", "/p/api"])
        },
        states: { [:] }))
    await r.router.store.move("c1", root: "root-c1", to: "w1")
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    await registerRunActions(into: registry, runner: r, organization: { "initech" })
    return (registry, r, terms)
}

private func agentDispatch(_ registry: ActionRegistry, _ name: String, _ params: JSONValue, conversation: String) async throws -> JSONValue {
    let caller = DispatchCaller(place: Place(organization: "initech", project: "estate", environment: "staging"),
                                session: "s-\(conversation)", conversation: conversation)
    return try await registry.dispatch(name: name, params: params, origin: .agent, caller: caller, confirmation: nil)
}

@Test func anAgentRunsInItsOwnWorkspaceOnlyAndNotFromMain() async throws {
    let (registry, _, terms) = await registryWithRun(["web": PlanSpec(ready: nil)])
    let out = try await agentDispatch(registry, "workspace_run", .object(["repo": .string("web")]), conversation: "c1")
    if case .object(let o) = out { #expect(o["port"] == .integer(41200)) } else { Issue.record("\(out)") }
    #expect(await terms.started.map(\.title) == ["web · dev"])
    await #expect(throws: RunError("workspace_run: you run only in your own workspace, ‘Fix OTP’ (decision 12).")) {
        _ = try await agentDispatch(registry, "workspace_run", .object(["repo": .string("web"), "workspace": .string("w0")]), conversation: "c1")
    }
    do {
        _ = try await agentDispatch(registry, "workspace_run", .object(["repo": .string("web")]), conversation: "c9")
        Issue.record("an agent in Main ran")
    } catch {
        #expect("\(error)".contains("you are in Main, where nothing runs"))
    }
    let running = try await agentDispatch(registry, "workspace_running", .object([:]), conversation: "c1")
    if case .object(let o) = running { #expect(o["line"] == .string("web dev running on :41200")) } else { Issue.record("\(running)") }
}

@Test func theRunActionsAreAgentReachableMutations() async throws {
    let (registry, _, _) = await registryWithRun([:])
    for name in ["workspace_run", "workspace_stop", "workspace_build", "workspace_running"] {
        let a = try #require(await registry.all().first { $0.name == name })
        #expect(a.audience == .agentReachable)
        #expect(a.kind == (name == "workspace_running" ? .read : .mutate))
    }
}
