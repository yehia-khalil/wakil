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
                     notRepositories: Set<String> = [], renames: [String: String] = [:],
                     discardFails: String? = nil, missingBases: Set<String> = []) -> RecordingToolCaller {
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
            if missingBases.contains(s("base")) {
                throw WorkspaceWriteError(description: "There is no branch \(s("base")) here nor on the remote (origin/\(s("base"))), so no copy was made")
            }
            // wakil-git picks the next free names (newName); `renames` stands in for what it found taken.
            let slug = renames[s("slug")] ?? s("slug"), branch = renames[s("branch")] ?? s("branch")
            return .object(["path": .string("/h/ws/\(s("project"))/\(slug)/\((s("root") as NSString).lastPathComponent)"),
                            "slug": .string(slug), "branch": .string(branch), "head": .string("abc"), "created": .bool(true)])
        case "git_worktree_discard":
            if let discardFails { throw WorkspaceWriteError(description: discardFails) }
            return .object([:])
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

/// Whether the record's next save fails, and how (the walk's sticky read failure).
private final class SaveSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    func fail(_ why: String?) { lock.lock(); failure = why; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw WorkspaceWriteError(description: failure) }
    }
}

private func router(
    git: RecordingToolCaller, states: [String: ConversationState] = [:], said: Said, titles: [String: String] = [:],
    saves: SaveSwitch = SaveSwitch(), tickets: [String: String] = [:]
) async -> WorkspaceRouter {
    let store = WorkspaceStore()
    await store.use(load: { WorkspacesFile() }, save: { _ in try saves.check() })
    await store.ensure(org: "initech")
    let r = WorkspaceRouter(store: store, git: git)
    let counter = IdCounter()
    await r.setIds { counter.next() }
    await r.setFolderExists { !$0.contains("/gone/") }
    await r.install(WorkspaceRouterHooks(
        conversation: { id in facts(id, title: titles[id] ?? "Fix OTP guard order", ticket: tickets[id]) },
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
        "newName": .bool(true), "takenSlugs": .array([]), "takenBranches": .array([]),
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

/// Decision 28: the window hears of the change once the record is saved, with the environment it
/// had, so its data panes follow; setting the environment it already has tells it nothing. The
/// workspace is named by its id or its slug.
@Test func anEnvironmentChangeTellsTheWindowWhatItWas() async throws {
    let git = gitWithSnapshot()
    let r = await router(git: git, said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let id = try #require(await r.store.workspace(ofConversation: "c1")?.id)
    let heard = Said()
    await r.install(WorkspaceRouterHooks(
        conversation: { facts($0) }, states: { [:] },
        environmentChanged: { w, from in await heard.move("env", from, w.environment) }))
    _ = try await r.setEnvironment(id, to: "qa")
    _ = try await r.setEnvironment(id, to: "qa")
    // Named by its slug, the folder name the operator sees.
    let slug = try #require(await r.store.workspace(id)?.slug)
    #expect(try await r.setEnvironment(slug, to: "staging").id == id)
    let moves = await heard.moves
    #expect(moves.map { "\($0.1 ?? "")→\($0.2)" } == ["staging→qa", "qa→staging"])
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

// MARK: the walk: no orphan copies, no name collisions

private let unsaved = "workspaces.json: CancellationError() — nothing was saved over it"

/// Step 0 made a copy and then could not save the record (the walk's sticky read failure): the copy
/// and the branch it made are taken back, the conversation stays in Main, and the refusal says so
/// whole (Rule 8). Nothing was written in the copy yet, so nothing is lost.
@Test func step0ACopyWhoseRecordCannotBeSavedIsTakenBackWithItsBranch() async throws {
    let git = fakeGit()
    let said = Said()
    let saves = SaveSwitch()
    saves.fail(unsaved)
    let r = await router(git: git, said: said, saves: saves)
    await #expect {
        try await asAgent("c1") { try await r.routePath("/p/core/a.go", action: "editor_save") }
    } throws: { error in
        let text = "\(error)"
        return text.contains("taken back") && text.contains(unsaved) && text.contains("core")
    }
    let discard = try #require(await git.calls.first { $0.name == "git_worktree_discard" })
    #expect(discard.arguments == .object([
        "root": .string("/p/core"), "project": .string("estate"), "slug": .string("fix-otp-guard-order"),
        "branch": .string("fix-otp-guard-order"),
    ]))
    #expect(await r.store.all().isEmpty)
    #expect(await r.store.workspace(ofConversation: "c1") == nil)
    #expect(await r.store.holders().isEmpty)
    #expect(await said.moves.isEmpty)
    #expect(await said.lines.map(\.1) == [.recordFailed(repo: "core", reason: unsaved, leftAt: nil)])
    // Once the record saves again, the next write starts the workspace afresh.
    saves.fail(nil)
    #expect(try await asAgent("c1") { try await r.routePath("/p/core/a.go", action: "editor_save") }
        == "/h/ws/estate/fix-otp-guard-order/core/a.go")
}

/// A copy that cannot be taken back either (something was written in it) is left where it is, and
/// the refusal names where.
@Test func aCopyThatCannotBeTakenBackIsNamedWhole() async throws {
    let git = fakeGit(discardFails: "fatal: contains modified files")
    let said = Said()
    let saves = SaveSwitch()
    saves.fail(unsaved)
    let r = await router(git: git, said: said, saves: saves)
    await #expect {
        try await asAgent("c1") { try await r.routePath("/p/core/a.go", action: "editor_save") }
    } throws: { error in
        let text = "\(error)"
        return text.contains("/h/ws/estate/fix-otp-guard-order/core") && text.contains("contains modified files")
    }
    #expect(await r.store.all().isEmpty)
}

@Test func aBranchOffWhoseRecordCannotBeSavedIsTakenBack() async throws {
    let git = fakeGit()
    let saves = SaveSwitch()
    let r = await router(git: git, states: ["c1": .working], said: Said(), titles: ["c1": "backend"], saves: saves)
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let parent = try #require(await r.store.workspace(ofConversation: "c1"))
    await r.store.move("c2", root: "root-c2", to: parent.id)
    saves.fail(unsaved)
    await #expect(throws: WorkspaceWriteError.self) {
        try await asAgent("c2") { try await r.routePath("/p/core/a", action: "editor_save") }
    }
    let discard = try #require(await git.calls.first { $0.name == "git_worktree_discard" })
    guard case .object(let a) = discard.arguments else { Issue.record("no args"); return }
    #expect(a["branch"] == .string("backend--c2"))
    #expect(await r.store.all().map(\.id) == [parent.id])
    #expect(await r.store.workspace(ofConversation: "c2")?.id == parent.id)
}

@Test func aLazilyMadeCheckoutWhoseRecordCannotBeSavedIsTakenBack() async throws {
    let git = fakeGit()
    let saves = SaveSwitch()
    let r = await router(git: git, said: Said(), saves: saves)
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    saves.fail(unsaved)
    await #expect(throws: WorkspaceWriteError.self) {
        try await asAgent("c1") { try await r.routePath("/p/web/b", action: "editor_save") }
    }
    let discard = try #require(await git.calls.first { $0.name == "git_worktree_discard" })
    guard case .object(let a) = discard.arguments else { Issue.record("no args"); return }
    #expect(a["root"] == .string("/p/web"))
    #expect(a["slug"] == .string("fix-otp-guard-order"))
    let w = try #require(await r.store.workspace(ofConversation: "c1"))
    #expect(w.checkouts.map(\.repo) == ["/p/core"])
    #expect(await r.store.holder(of: WorkspaceHold(workspace: w.id, repo: "/p/web")) == nil)
}

/// A new workspace's names are minted by wakil-git, stepping past the record's and the repo's
/// (`newName`); the workspace records the ones it used. Two conversations with the same title get
/// two workspaces.
@Test func twoConversationsWithTheSameTitleGetTwoWorkspacesWithTheNextFreeNames() async throws {
    let git = fakeGit(renames: ["fix-otp-guard-order": "fix-otp-guard-order-2"])
    let r = await router(git: git, said: Said())
    await r.store.add(Workspace(id: "old", name: "Fix OTP guard order", slug: "fix-otp-guard-order", project: "estate",
                                environment: "staging", branch: "fix-otp-guard-order"))
    let path = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    #expect(path == "/h/ws/estate/fix-otp-guard-order-2/core/a")
    let add = try #require(await git.calls.first { $0.name == "git_worktree_add" })
    guard case .object(let a) = add.arguments else { Issue.record("no args"); return }
    #expect(a["newName"] == .bool(true))
    #expect(a["takenSlugs"] == .array([.string("fix-otp-guard-order")]))
    #expect(a["takenBranches"] == .array([.string("fix-otp-guard-order")]))
    let w = try #require(await r.store.workspace(ofConversation: "c1"))
    #expect(w.slug == "fix-otp-guard-order-2")
    #expect(w.branch == "fix-otp-guard-order-2")
    #expect(w.checkouts.first?.branch == "fix-otp-guard-order-2")
}

/// A lazily made checkout asks for the workspace's branch, stepping past it only where another
/// folder holds it (`freeBranch`), and records the branch it got.
@Test func aLazilyMadeCheckoutRecordsTheBranchItGot() async throws {
    let git = fakeGit()
    let r = await router(git: git, said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    _ = try await asAgent("c1") { try await r.routePath("/p/web/b", action: "editor_save") }
    let add = try #require(await git.calls.last { $0.name == "git_worktree_add" })
    guard case .object(let a) = add.arguments else { Issue.record("no args"); return }
    #expect(a["freeBranch"] == .bool(true))
    #expect(a["newName"] == nil)
}

// MARK: workspace_start (amendment 2026-10-30, decision 10 refined): the agent chooses its copy's base

/// In Main: the workspace is made with its first copy from the chosen base, on the chosen branch
/// with the ticket's key once; the record keeps the base and the thread names it.
@Test func workspaceStartInMainMakesTheWorkspaceFromTheChosenBase() async throws {
    let git = fakeGit()
    let said = Said()
    let r = await router(git: git, said: said, tickets: ["c1": "INI-1637"])
    let started = try await asAgent("c1") {
        try await r.start(repo: "web", base: "production", branch: "from-production/INI-1637-ini-1637-full-jwt")
    }
    let branch = "from-production/INI-1637-full-jwt"
    #expect(started.path == "/h/ws/estate/from-production-ini-1637-full-jwt/web")
    #expect(started.branch == branch && started.base == "production")
    let add = try #require(await git.calls.first { $0.name == "git_worktree_add" })
    guard case .object(let a) = add.arguments else { Issue.record("no args"); return }
    #expect(a["root"] == .string("/p/web") && a["base"] == .string("production") && a["branch"] == .string(branch))
    #expect(a["newName"] == .bool(true) && a["from"] == nil)
    let w = try #require(await r.store.workspace(ofConversation: "c1"))
    #expect(w.branch == branch && w.tickets == ["INI-1637"])
    #expect(w.checkouts == [WorkspaceCheckout(repo: "/p/web", path: started.path, branch: branch, base: "production",
                                              lastHolder: "root-c1")])
    #expect(await said.lines.map(\.1) == [.startedFrom(name: "Fix OTP guard order", repo: "web", base: "production", branch: branch)])
    #expect(await said.moves.map(\.2) == [w.id])
    // The first change lands in that copy: nothing new is made.
    #expect(try await asAgent("c1") { try await r.routePath("/p/web/a.ts", action: "editor_save") } == started.path + "/a.ts")
    #expect(await git.calls.filter { $0.name == "git_worktree_add" }.count == 1)
}

/// In a workspace with no copy of the repo: the copy is made there from the chosen base, on the
/// workspace's branch when none is named.
@Test func workspaceStartInAWorkspaceMakesTheRepositoryCopyFromTheChosenBase() async throws {
    let git = fakeGit()
    let said = Said()
    let r = await router(git: git, said: said)
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    let started = try await asAgent("c1") { try await r.start(repo: "/p/web", base: "staging", branch: nil) }
    #expect(started.path == "/h/ws/estate/fix-otp-guard-order/web" && started.branch == "fix-otp-guard-order")
    let add = try #require(await git.calls.last { $0.name == "git_worktree_add" })
    guard case .object(let a) = add.arguments else { Issue.record("no args"); return }
    #expect(a["base"] == .string("staging") && a["fromIsBase"] == nil && a["slug"] == .string("fix-otp-guard-order"))
    let w = try #require(await r.store.workspace(ofConversation: "c1"))
    #expect(w.checkout(of: "/p/web")?.base == "staging")
    #expect(await r.store.holder(of: WorkspaceHold(workspace: w.id, repo: "/p/web")) == "c1")
    #expect(await said.lines.last?.1 == .madeFrom(repo: "web", base: "staging", branch: "fix-otp-guard-order"))
}

/// A conversation whose workspace already has a copy of the repo: refused whole, naming why.
@Test func workspaceStartIsRefusedWholeWhenTheWorkspaceHasACopyOfTheRepo() async throws {
    let git = fakeGit()
    let r = await router(git: git, said: Said())
    _ = try await asAgent("c1") { try await r.routePath("/p/core/a", action: "editor_save") }
    await #expect {
        try await asAgent("c1") { try await r.start(repo: "core", base: "production", branch: "hotfix") }
    } throws: { error in
        let text = "\(error)"
        return text.contains("workspace_start: workspace ‘Fix OTP guard order’ already has a copy of core, on `fix-otp-guard-order`")
            && text.contains("editor_changes_branch_create")
    }
    #expect(await git.calls.filter { $0.name == "git_worktree_add" }.count == 1)
}

/// A base the repo does not have, locally or on the remote: refused whole, and nothing is made —
/// no workspace, no move, no thread line.
@Test func workspaceStartFromABaseThatDoesNotExistMakesNothing() async throws {
    let git = fakeGit(missingBases: ["production"])
    let said = Said()
    let r = await router(git: git, said: said)
    await #expect {
        try await asAgent("c1") { try await r.start(repo: "web", base: "production", branch: "hotfix") }
    } throws: { error in "\(error)".contains("workspace_start: There is no branch production here nor on the remote") }
    #expect(await r.store.all().isEmpty)
    #expect(await r.store.workspace(ofConversation: "c1") == nil)
    #expect(await said.lines.isEmpty)
    #expect(await said.moves.isEmpty)
}

/// Only an agent's conversation starts its copy; a repo that is not one of the project's roots, and a
/// branch git would not take, are refused naming them.
@Test func workspaceStartIsRefusedForTheOperatorAnUnknownRepoAndABadBranch() async throws {
    let git = fakeGit()
    let r = await router(git: git, said: Said())
    await #expect { try await r.start(repo: "web", base: "main", branch: nil) } throws: {
        "\($0)".contains("workspace_start: only an agent's conversation")
    }
    await #expect { try await asAgent("c1") { try await r.start(repo: "mobile", base: "main", branch: nil) } } throws: {
        "\($0)".contains("mobile is not one of this project's repos") && "\($0)".contains("core, web")
    }
    await #expect { try await asAgent("c1") { try await r.start(repo: "web", base: "main", branch: "-x") } } throws: {
        "\($0)".contains("is not a branch name git takes")
    }
    #expect(await git.calls.allSatisfy { $0.name != "git_worktree_add" })
}

@Test func theStartedLinesNameTheBase() {
    #expect(WorkspaceLine.madeFrom(repo: "web", base: "production", branch: "from-production/INI-1637-full-jwt").text
        == "Made a copy of web from `production` on `from-production/INI-1637-full-jwt`.")
    #expect(WorkspaceLine.startedFrom(name: "Full JWT", repo: "web", base: "production", branch: "from-production/INI-1637-full-jwt").text
        == "Started workspace ‘Full JWT’ — a copy of web from `production` on `from-production/INI-1637-full-jwt`. Your folder is untouched.")
}

@Test func aChosenBranchHasTheTicketsKeyOnce() {
    #expect(branchWithKeyOnce("from-production/INI-1637-ini-1637-full-jwt", key: "INI-1637") == "from-production/INI-1637-full-jwt")
    #expect(branchWithKeyOnce("INI-1637-INI-1637", key: "INI-1637") == "INI-1637")
    #expect(branchWithKeyOnce("hotfix/INI-1637-otp", key: "INI-1637") == "hotfix/INI-1637-otp")
    #expect(branchWithKeyOnce("hotfix/otp", key: nil) == "hotfix/otp")
}
