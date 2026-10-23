import Foundation
import Testing
@testable import WakilKit

/// A wakil-git answering git_clone with a path, recording what it was asked.
private actor CloneGit: ToolCaller {
    var asked: [JSONValue] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        if name == "git_status" {
            return .object(["structuredContent": .object(["root": .string("/p"), "files": .array([])])])
        }
        asked.append(arguments)
        if case .string(let url)? = (arguments.objectValue)?["url"], url.contains("exists") {
            return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"),
                            "text": .string("the destination already exists: /c/exists")])])])
        }
        return .object(["structuredContent": .object(["path": .string("/c/api"), "summary": .string("cloned")])])
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
}

private actor Recorder { var names: [String] = []; func add(_ n: String) { names.append(n) } }

@MainActor
private func cloneWindow() async -> (WindowModel, CloneGit, Recorder) {
    let git = CloneGit()
    let status = GitStatus(git: git, roots: { ["/p"] })
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, gitStatus: status)
    await registerEditorChangesWrites(into: window.registryForTesting, gitStatus: status, panes: PaneStore(kinds: PaneKinds.standard),
                                      layout: LayoutStore(), writes: GitWriteFlights())
    let created = Recorder()
    await window.registryForTesting.register(Action(
        name: "ctx_create_project", description: "test", kind: .control, audience: .operatorOnly,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await created.add(optionalString(params, "folder") ?? "")
            return .object(["structuredContent": .object(["name": .string("api")])])
        }))
    return (window, git, created)
}

@Suite @MainActor struct EditorCloneTests {
    @Test func theOperatorsCloneBecomesAProject() async {
        let (window, git, created) = await cloneWindow()
        let r = await window.cloneProject(link: "git@github.com:o/api.git", into: "/c")
        #expect(r.error == nil)
        #expect(r.name == "api")
        #expect(await created.names == ["/c/api"])
        #expect(await git.asked.last == .object(["url": .string("git@github.com:o/api.git"), "folder": .string("/c"), "operator": .bool(true)]))
    }

    @Test func theAgentsCloneRegistersNothingAndSaysHowToAddIt() async throws {
        let (window, git, created) = await cloneWindow()
        let reply = try await window.registryForTesting.dispatch(
            name: "editor_clone", params: .object(["url": .string("git@github.com:o/api.git")]), origin: .agent,
            caller: .test("production"), confirmation: nil)
        #expect(await created.names.isEmpty)
        #expect(await git.asked.last == .object(["url": .string("git@github.com:o/api.git"), "operator": .bool(false)]))
        #expect(reply.objectValue?["message"] == .string("Cloned to /c/api — Add as project in Settings → + Add a project"))
        let d = try #require(await window.registryForTesting.descriptor(named: "editor_clone"))
        #expect(d.kind == .mutate)
        #expect(d.audience == .agentReachable)
    }

    @Test func aCloneIntoAnExistingFolderIsRefusedWhole() async {
        let (window, _, created) = await cloneWindow()
        let r = await window.cloneProject(link: "git@github.com:o/exists.git", into: "/c")
        #expect(r.error?.contains("the destination already exists: /c/exists") == true)
        #expect(await created.names.isEmpty)
    }
}
