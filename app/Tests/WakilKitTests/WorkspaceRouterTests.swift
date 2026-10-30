import Foundation
import Testing
@testable import WakilKit

// The write rule carried out (workspaces, piece 1): what reaches wakil-git, where the write lands,
// and what the thread says.

private actor Said {
    var lines: [(String, WorkspaceLine)] = []
    var moves: [(String, String?, String)] = []
    func add(_ c: String, _ l: WorkspaceLine) { lines.append((c, l)) }
    func move(_ c: String, _ from: String?, _ to: String) { moves.append((c, from, to)) }
}

private func fakeGit(mainBranch: String = "main", uncommitted: Int = 2, addFails: String? = nil,
                     notRepositories: Set<String> = []) -> RecordingToolCaller {
    RecordingToolCaller(reply: { name, args in
        guard case .object(let a) = args else { return .object([:]) }
        func s(_ k: String) -> String { if case .string(let v)? = a[k] { v } else { "" } }
        if notRepositories.contains(s("root")) {
            throw WorkspaceWriteError(description: "\(name): not a git repository")
        }
        switch name {
        case "git_status":
            let files: [JSONValue] = (0..<uncommitted).map { .object(["path": .string("f\($0)"), "group": .string("changed")]) }
            return .object(["branch": .string(mainBranch), "files": .array(files)])
        case "git_worktree_add":
            if let addFails { throw WorkspaceWriteError(description: addFails) }
            return .object(["path": .string("/h/ws/\(s("project"))/\(s("slug"))/\((s("root") as NSString).lastPathComponent)"),
                            "branch": .string(s("branch")), "head": .string("abc")])
        case "git_take_from_main":
            return .object(["path": .string("/h/ws/\(s("project"))/\(s("slug"))/\((s("root") as NSString).lastPathComponent)"),
                            "carried": .bool(true), "head": .string("abc")])
        default:
            return .object([:])
        }
    })
}

private func facts(_ id: String, title: String = "Fix OTP guard order", ticket: String? = nil) -> WorkspaceConversationFacts {
    WorkspaceConversationFacts(id: id, lineageRoot: "root-\(id)", title: title, ticket: ticket, organization: "initech",
                               project: "estate", environment: "staging", mainRoots: ["/p/core", "/p/web"])
}

private final class IdCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return "w\(n)"
    }
}

private func router(
    git: RecordingToolCaller, states: [String: ConversationState] = [:], said: Said, titles: [String: String] = [:]
) async -> WorkspaceRouter {
    let store = WorkspaceStore()
    await store.use(load: { WorkspacesFile() }, save: { _ in })
    await store.ensure(org: "initech")
    let r = WorkspaceRouter(store: store, git: git)
    let counter = IdCounter()
    await r.setIds { counter.next() }
    await r.setFolderExists { !$0.contains("/gone/") }
    await r.install(WorkspaceRouterHooks(
        conversation: { id in facts(id, title: titles[id] ?? "Fix OTP guard order") },
        states: { states },
        say: { c, l in await said.add(c, l) },
        moved: { c, from, to in await said.move(c, from?.id, to.id) }))
    return r
}

private func asAgent<T: Sendable>(_ conversation: String, _ body: @Sendable () async throws -> T) async rethrows -> T {
    let caller = DispatchCaller(place: Place(organization: "initech", project: "estate", environment: "staging"),
                                session: "s-\(conversation)", conversation: conversation)
    return try await ActionRegistry.$dispatchOrigin.withValue(.agent) {
        try await ActionRegistry.$dispatchCaller.withValue(caller) { try await body() }
    }
}

@Test func theOperatorsWriteGoesWhereItWasAimedAndRunsNoRule() async throws {
    let git = fakeGit()
    let r = await router(git: git, said: Said())
    #expect(try await r.routePath("/p/core/a.go", action: "editor_save") == "/p/core/a.go")
    #expect(try await r.routeRoot("/p/core", action: "editor_changes_commit") == "/p/core")
    #expect(await git.calls.isEmpty)
}

/// A conversation whose agent never started (no harness, no start in flight) holds no checkout and
/// is moved nowhere: no agent made the write. The seeded e2e checks dispatch on such a place's
/// shown socket, and their writes — like the operator's — land where they were aimed
/// (amendment 2026-10-30).
@Test func aConversationWhoseAgentNeverStartedRunsNoRule() async throws {
    let git = fakeGit()
    let store = WorkspaceStore()
    await store.use(load: { WorkspacesFile() }, save: { _ in })
    let r = WorkspaceRouter(store: store, git: git)
    await r.install(WorkspaceRouterHooks(
        conversation: { id in
            WorkspaceConversationFacts(id: id, lineageRoot: id, title: "", organization: "initech", project: "estate",
                                       environment: "staging", mainRoots: ["/p/core"], agentRuns: false)
        },
        states: { [:] }))
    #expect(try await asAgent("c1") { try await r.routePath("/p/core/a.go", action: "editor_save") } == "/p/core/a.go")
    #expect(try await asAgent("c1") { try await r.routeRoot("/p/core", action: "editor_changes_stage") } == "/p/core")
    let sw = try await asAgent("c1") { try await r.routeSwitch(root: "/p/core", branch: "topic", action: "editor_changes_switch") }
    #expect(sw == RoutedSwitch(root: "/p/core", branch: "topic"))
    #expect(await asAgent("c1") { await r.callerCheckouts() } == nil)
    #expect(await git.calls.isEmpty)
    #expect(await store.all().isEmpty)
}

/// A root that is not a git repository has no copy to make, and no agent writes in Main (decision 7):
/// the agent's write there is refused whole, naming why, before any workspace is made
/// (amendment 2026-10-30).
@Test func anAgentsWriteInARootThatIsNotARepositoryIsRefusedNamingDecision7() async throws {
    let git = fakeGit(notRepositories: ["/p/core"])
    let said = Said()
    let r = await router(git: git, said: said)
    await #expect {
        try await asAgent("c1") { try await r.routePath("/p/core/notes.txt", action: "editor_save") }
    } throws: { error in
        let text = "\(error)"
        return text.contains("editor_save: core is not a git repository") && text.contains("decision 7")
    }
    #expect(await git.calls.allSatisfy { $0.name != "git_worktree_add" })
    #expect(await r.store.all().isEmpty)
    #expect(await r.store.workspace(ofConversation: "c1") == nil)
    #expect(await said.moves.isEmpty)
}

@Test func step0AnAgentInMainGetsAWorkspaceAndItsWriteLandsInTheCopy() async throws {
    let git = fakeGit(uncommitted: 2)
    let said = Said()
    let r = await router(git: git, said: said)
    let path = try await asAgent("c1") { try await r.routePath("/p/core/src/a.go", action: "editor_save") }
    #expect(path == "/h/ws/estate/fix-otp-guard-order/core/src/a.go")
    let add = try #require(await git.calls.first { $0.name == "git_worktree_add" })
    #expect(add.arguments == .object([
        "root": .string("/p/core"), "project": .string("estate"), "slug": .string("fix-otp-guard-order"),
        "branch": .string("fix-otp-guard-order"), "create": .bool(true), "from": .string("HEAD"),
    ]))
    let w = try #require(await r.store.workspace(ofConversation: "c1"))
    #expect(w.name == "Fix OTP guard order")
    #expect(w.environment == "staging")
    #expect(w.conversations == ["root-c1"])
    #expect(w.checkouts.first?.lastHolder == "root-c1")
    #expect(await r.store.holder(of: WorkspaceHold(workspace: w.id, repo: "/p/core")) == "c1")
    let lines = await said.lines
    #expect(lines.map(\.1) == [.started(name: "Fix OTP guard order", repo: "core", branch: "fix-otp-guard-order", uncommitted: 2)])
    #expect(await said.moves.map(\.2) == [w.id])
    // The next write in the same repo needs nothing new.
    #expect(try await asAgent("c1") { try await r.routeRoot("/p/core", action: "editor_changes_stage") }
        == "/h/ws/estate/fix-otp-guard-order/core")
    #expect(await git.calls.filter { $0.name == "git_worktree_add" }.count == 1)
}

@Test func step2ASecondRepoIsAddedToTheSameWorkspaceFromItsBase() async throws {
    let git = fakeGit()
    let r = await router(git: git, said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let web = try await asAgent("c1") { try await r.routePath("/p/web/b", action: "editor_save") }
    #expect(web == "/h/ws/estate/fix-otp-guard-order/web/b")
    let adds = await git.calls.filter { $0.name == "git_worktree_add" }
    #expect(adds.count == 2)
    guard case .object(let a) = adds[1].arguments else { Issue.record("no args"); return }
    #expect(a["fromIsBase"] == .bool(true))
    #expect(a["from"] == nil)
    #expect(await r.store.workspace(ofConversation: "c1")?.checkouts.count == 2)
}

@Test func step1AnIdleHoldersCheckoutIsTakenOverAndTheThreadSaysSo() async throws {
    let git = fakeGit()
    let said = Said()
    let r = await router(git: git, states: ["c1": .idle, "c2": .working], said: said, titles: ["c1": "backend"])
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let w = try #require(await r.store.workspace(ofConversation: "c1"))
    await r.store.move("c2", root: "root-c2", to: w.id)
    let path = try await asAgent("c2") { try await r.routePath("/p/core/a", action: "editor_save") }
    #expect(path == "/h/ws/estate/backend/core/a")
    #expect(await r.store.holder(of: WorkspaceHold(workspace: w.id, repo: "/p/core")) == "c2")
    #expect(await said.lines.last?.1 == .tookOver(repo: "core", from: "backend"))
}

@Test func step1AWorkingHolderMakesTheWriterBranchOffIntoAChildWorkspace() async throws {
    let git = fakeGit()
    let said = Said()
    let r = await router(git: git, states: ["c1": .working], said: said, titles: ["c1": "backend", "c2": "Try a token bucket"])
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let parent = try #require(await r.store.workspace(ofConversation: "c1"))
    await r.store.move("c2", root: "root-c2", to: parent.id)
    let path = try await asAgent("c2") { try await r.routePath("/p/core/a", action: "editor_save") }
    let child = try #require(await r.store.workspace(ofConversation: "c2"))
    #expect(child.parent == parent.id)
    #expect(child.tickets == parent.tickets)
    #expect(child.branch == "backend--c2")
    #expect(path == "/h/ws/estate/\(child.slug)/core/a")
    let add = try #require(await git.calls.last { $0.name == "git_worktree_add" })
    guard case .object(let a) = add.arguments else { Issue.record("no args"); return }
    #expect(a["from"] == .string("backend"))
    #expect(await said.lines.last?.1 == .branchedOff(name: "Try a token bucket", repo: "core", branch: "backend--c2", holder: "backend"))
}

@Test func aPathInAnotherWorkspacesCopyIsRefusedNamingIt() async throws {
    let git = fakeGit()
    let r = await router(git: git, said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    await #expect(throws: WorkspaceWriteError.self) {
        try await asAgent("c2") { try await r.routePath("/h/ws/estate/fix-otp-guard-order/core/a", action: "editor_save") }
    }
    do {
        _ = try await asAgent("c2") { try await r.routePath("/h/ws/estate/fix-otp-guard-order/core/a", action: "editor_save") }
    } catch {
        #expect("\(error)".contains("is in workspace ‘Fix OTP guard order’"))
    }
}

@Test func aWorktreeThatCannotBeMadeStopsTheWriteAndTheThreadGetsGitsWordsWhole() async throws {
    let git = fakeGit(addFails: "fatal: '/h/x' already exists\nsecond line")
    let said = Said()
    let r = await router(git: git, said: said)
    await #expect(throws: WorkspaceWriteError.self) {
        try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    }
    #expect(await r.store.all().isEmpty)
    #expect(await r.store.workspace(ofConversation: "c1") == nil)
    #expect(await said.lines.map(\.1) == [.addFailed(repo: "core", message: "fatal: '/h/x' already exists\nsecond line")])
}

@Test func aTicketsBranchCheckedOutInMainIsTakenFromMain() async throws {
    let git = fakeGit(mainBranch: "INI-142-login")
    let said = Said()
    let r = await router(git: git, said: said)
    await r.store.add(Workspace(id: "t", name: "INI-142 Login", slug: "ini-142", project: "estate", environment: "staging",
                                tickets: ["INI-142"], branch: "INI-142-login"))
    await r.store.move("c1", root: "root-c1", to: "t")
    let path = try await asAgent("c1") { try await r.routeRoot("/p/core", action: "editor_changes_commit") }
    #expect(path == "/h/ws/estate/ini-142/core")
    #expect(await git.calls.contains { $0.name == "git_take_from_main" })
    if case .tookFromMain(let repo, let branch, _, let carried)? = await said.lines.last?.1 {
        #expect(repo == "core" && branch == "INI-142-login" && carried)
    } else {
        Issue.record("no take-from-Main line")
    }
}

@Test func aSwitchToABranchAWorkingConversationHoldsBecomesANewBranchOffItsTip() async throws {
    let git = fakeGit()
    let said = Said()
    let r = await router(git: git, states: ["c2": .working], said: said, titles: ["c2": "frontend"])
    await r.store.add(Workspace(id: "other", name: "Other", slug: "other", project: "estate", environment: "staging",
                                checkouts: [WorkspaceCheckout(repo: "/p/core", path: "/h/ws/estate/other/core", branch: "feature")]))
    await r.store.move("c2", root: "root-c2", to: "other")
    await r.store.hold(WorkspaceHold(workspace: "other", repo: "/p/core"), by: "c2", root: "root-c2")
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let routed = try await asAgent("c1") { try await r.routeSwitch(root: "/p/core", branch: "feature", action: "editor_changes_switch") }
    #expect(routed == RoutedSwitch(root: "/h/ws/estate/fix-otp-guard-order/core", branch: "feature--c1", create: true, from: "feature"))
    #expect(await said.lines.last?.1 == .switchBranchedOff(branch: "feature", holder: "frontend", fresh: "feature--c1"))
}

@Test func aSwitchToABranchAnIdleCheckoutHoldsReleasesItThere() async throws {
    let git = fakeGit()
    let r = await router(git: git, states: ["c2": .idle], said: Said())
    await r.store.add(Workspace(id: "other", name: "Other", slug: "other", project: "estate", environment: "staging",
                                checkouts: [WorkspaceCheckout(repo: "/p/core", path: "/h/ws/estate/other/core", branch: "feature")]))
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let routed = try await asAgent("c1") { try await r.routeSwitch(root: "/p/core", branch: "feature", action: "editor_changes_switch") }
    #expect(routed == RoutedSwitch(root: "/h/ws/estate/fix-otp-guard-order/core", branch: "feature"))
    let release = try #require(await git.calls.first { $0.name == "git_release_branch" })
    #expect(release.arguments == .object(["root": .string("/h/ws/estate/other/core")]))
}

@Test func aConversationsCheckoutRootsAreItsOwnWorkspacesOnly() async throws {
    let git = fakeGit()
    let r = await router(git: git, said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    #expect(await asAgent("c1") { await r.callerCheckoutRoots() } == ["/h/ws/estate/fix-otp-guard-order/core"])
    #expect(await asAgent("c2") { await r.callerCheckoutRoots() } == [])
    #expect(await r.callerCheckoutRoots() == [])
}

@Test func anUnreadableRecordIsNeverSavedOver() async throws {
    let store = WorkspaceStore()
    let saved = Said()
    await store.use(load: { throw WorkspaceWriteError(description: "/h/.wakil/orgs/initech/workspaces.json is not readable") },
                    save: { _ in await saved.add("", .moved(name: "saved")) })
    let failure = await store.reload()
    #expect(failure?.contains("is not readable") == true)
    await #expect(throws: WorkspaceWriteError.self) { try await store.save() }
    #expect(await saved.lines.isEmpty)
}

// MARK: archive, restore, Bring to Main, Move

private func gitWithSnapshot() -> RecordingToolCaller {
    RecordingToolCaller(reply: { name, args in
        guard case .object(let a) = args else { return .object([:]) }
        func s(_ k: String) -> String { if case .string(let v)? = a[k] { v } else { "" } }
        switch name {
        case "git_status": return .object(["branch": .string("main"), "files": .array([])])
        case "git_worktree_add":
            return .object(["path": .string("/h/ws/\(s("project"))/\(s("slug"))/\((s("root") as NSString).lastPathComponent)"),
                            "branch": .string(s("branch"))])
        case "git_worktree_remove": return .object(["snapshot": .string("abc123")])
        default: return .object([:])
        }
    })
}

@Test func archiveSnapshotsAndRemovesEveryCopyAndRestoreRemakesItAtTheNextWrite() async throws {
    let git = gitWithSnapshot()
    let r = await router(git: git, states: ["c1": .idle], said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let id = try #require(await r.store.workspace(ofConversation: "c1")?.id)
    let archived = try await r.archive(id, confirmed: false)
    #expect(archived.archived)
    #expect(archived.checkouts.first?.path == nil)
    #expect(archived.checkouts.first?.snapshot == "refs/wakil/snapshots/fix-otp-guard-order/core")
    let rm = try #require(await git.calls.first { $0.name == "git_worktree_remove" })
    #expect(rm.arguments == .object(["root": .string("/p/core"), "path": .string("/h/ws/estate/fix-otp-guard-order/core"),
                                     "snapshot": .string("refs/wakil/snapshots/fix-otp-guard-order/core")]))
    let restored = try await r.restore(id)
    #expect(!restored.archived)
    // The conversation left with the archive; put back in, its next write re-makes the copy and applies the snapshot.
    await r.store.move("c1", root: "root-c1", to: id)
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let apply = try #require(await git.calls.first { $0.name == "git_snapshot_apply" })
    #expect(apply.arguments == .object(["root": .string("/h/ws/estate/fix-otp-guard-order/core"),
                                        "ref": .string("refs/wakil/snapshots/fix-otp-guard-order/core")]))
}

@Test func archiveIsRefusedWhileAConversationInItWorksAndAsksWhenOneWaits() async throws {
    let git = gitWithSnapshot()
    let r = await router(git: git, states: ["c1": .working], said: Said(), titles: ["c1": "backend"])
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let id = try #require(await r.store.workspace(ofConversation: "c1")?.id)
    await #expect(throws: WorkspaceWriteError(description: "‘backend’ is working in ‘backend’; archive it once it stops")) {
        try await r.archive(id, confirmed: false)
    }
    let waiting = await router(git: git, states: ["c1": .waiting], said: Said())
    _ = try await asAgent("c1") { try await waiting.routePath("/p/core/a", action: "editor_save") }
    let wid = try #require(await waiting.store.workspace(ofConversation: "c1")?.id)
    await #expect(throws: WorkspaceWriteError.self) { try await waiting.archive(wid, confirmed: false) }
    #expect(try await waiting.archive(wid, confirmed: true).archived)
}

@Test func bringToMainSwitchesMainsFolderToTheBranchWithTheCopysWork() async throws {
    let git = gitWithSnapshot()
    let r = await router(git: git, states: ["c1": .idle], said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let id = try #require(await r.store.workspace(ofConversation: "c1")?.id)
    let w = try await r.bringHome(id, repo: "core")
    #expect(w.checkouts.first?.inMain == true)
    #expect(w.checkouts.first?.path == nil)
    let names = await git.calls.map(\.name)
    #expect(Array(names.suffix(3)) == ["git_worktree_remove", "git_switch", "git_snapshot_apply"])
    #expect(await r.store.holder(of: WorkspaceHold(workspace: id, repo: "/p/core")) == nil)
}

@Test func moveIsRefusedForAConversationHoldingACopyAndAllowedOtherwise() async throws {
    let git = gitWithSnapshot()
    let said = Said()
    let r = await router(git: git, said: said)
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let id = try #require(await r.store.workspace(ofConversation: "c1")?.id)
    await #expect(throws: WorkspaceWriteError.self) { try await r.move("c1", to: nil) }
    let moved = try await r.move("c2", to: id)
    #expect(moved?.id == id)
    #expect(await r.store.workspace(ofConversation: "c2")?.id == id)
    #expect(await said.lines.last?.1 == .moved(name: "Fix OTP guard order"))
    let rows = await r.listing(project: "estate")
    #expect(rows.count == 1)
    #expect(rows.first?.holders["/p/core"] == "c1")
    #expect(Set(rows.first?.live.keys.map { $0 } ?? []) == ["c1", "c2"])
}

@Test func aWorkspacesEnvironmentIsItsOwnAndCanBeChanged() async throws {
    let git = gitWithSnapshot()
    let r = await router(git: git, said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let id = try #require(await r.store.workspace(ofConversation: "c1")?.id)
    #expect(await r.store.workspace(id)?.environment == "staging")
    #expect(try await r.setEnvironment(id, to: "qa").environment == "qa")
    await #expect(throws: WorkspaceWriteError.self) { try await r.setEnvironment(id, to: " ") }
}

@Test func aResumedConversationGoesBackToItsWorkspaceByItsLineageRoot() async throws {
    let git = gitWithSnapshot()
    let said = Said()
    let r = await router(git: git, said: said)
    await r.store.add(Workspace(id: "w", name: "Earlier work", slug: "earlier", project: "estate", environment: "staging",
                                branch: "earlier", checkouts: [WorkspaceCheckout(repo: "/p/core", path: "/h/ws/estate/earlier/core", branch: "earlier")],
                                conversations: ["root-c9"]))
    let path = try await asAgent("c9") { try await r.routePath("/p/core/a", action: "editor_save") }
    #expect(path == "/h/ws/estate/earlier/core/a")
    #expect(await r.store.isMember("c9"))
    #expect(await said.moves.map(\.2) == ["w"])
    #expect(await git.calls.filter { $0.name == "git_worktree_add" }.isEmpty)
}

@Test func aClosedConversationHoldsNothing() async throws {
    let git = gitWithSnapshot()
    let r = await router(git: git, said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    #expect(await r.store.holdsAny("c1"))
    await r.store.release("c1")
    #expect(!(await r.store.holdsAny("c1")))
}

@Test func aCopyDeletedOutsideWakilIsPrunedAndRemadeAtTheNextWrite() async throws {
    let git = gitWithSnapshot()
    let r = await router(git: git, said: Said())
    await r.store.add(Workspace(id: "w", name: "Gone", slug: "gone", project: "estate", environment: "staging",
                                branch: "gone", checkouts: [WorkspaceCheckout(repo: "/p/core", path: "/h/ws/estate/gone/core", branch: "gone")]))
    await r.store.move("c1", root: "root-c1", to: "w")
    let path = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    #expect(path == "/h/ws/estate/gone/core/a")
    let names = await git.calls.map(\.name)
    #expect(names.contains("git_worktree_prune"))
    #expect(names.contains("git_worktree_add"))
}
