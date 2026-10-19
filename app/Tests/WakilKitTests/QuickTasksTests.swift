import Testing
@testable import WakilKit

private actor FakeModel: QuickModel {
    nonisolated let serves: Set<QuickOperation>
    var replies: [Result<String, QuickModelError>]
    private(set) var calls = 0
    init(serves: Set<QuickOperation>, replies: [Result<String, QuickModelError>]) { self.serves = serves; self.replies = replies }
    func next() throws -> String { calls += 1; return try replies.removeFirst().get() }
    func infill(_ r: InfillRequest) async throws -> String { try next() }
    func respond(_ r: RespondRequest) async throws -> String { try next() }
    func shutdown() async {}
}

private let local = QuickProviderRecord(id: "qwen", kind: "local", baseURL: "http://127.0.0.1:8012", serves: [.infill])
private let claude = QuickProviderRecord(id: "main", kind: "claude-code", baseURL: "", serves: [.infill, .respond])
private let infillReq = InfillRequest(prefix: "b.", suffix: "", path: "a.go", language: "go", extras: [], multiline: false)
private let respondReq = RespondRequest(instructions: "title", input: "x", jsonSchema: nil, maxTokens: 16)

@Suite struct QuickTasksTests {
    @Test func routeTakesQuickProviderThenActiveForEachOperation() {
        let both = QuickTasksConfig(quickProvider: local, active: claude)
        #expect(quickRoute(.infill, both).map(\.id) == ["qwen", "main"])
        #expect(quickRoute(.respond, both).map(\.id) == ["main"])
        #expect(quickRoute(.infill, QuickTasksConfig(quickProvider: nil, active: claude)).map(\.id) == ["main"])
        #expect(quickRoute(.respond, QuickTasksConfig(quickProvider: local, active: nil)).isEmpty)
        let codex = QuickProviderRecord(id: "cx", kind: "codex", baseURL: "", serves: [])
        #expect(quickRoute(.infill, QuickTasksConfig(quickProvider: nil, active: codex)).isEmpty)
    }

    @Test func noProviderThrowsNamedError() async {
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: nil)) { _ in nil }
        await #expect(throws: QuickModelError.noProvider(.infill)) { try await tasks.infill(infillReq) }
    }

    @Test func respondNeverReachesACodeOnlyLocalModel() async throws {
        let localModel = FakeModel(serves: [.infill], replies: [])
        let claudeModel = FakeModel(serves: [.infill, .respond], replies: [.success("Title")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: claude)) { r in
            r.id == "qwen" ? localModel : claudeModel
        }
        #expect(try await tasks.respond(respondReq) == "Title")
        #expect(await localModel.calls == 0)
    }

    @Test func fallsBackOnceThenRetriesEndpointNextCall() async throws {
        let localModel = FakeModel(serves: [.infill], replies: [.failure(.unreachable("connection refused")), .success("i++ {")])
        let claudeModel = FakeModel(serves: [.infill, .respond], replies: [.success("status")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: claude)) { r in
            r.id == "qwen" ? localModel : claudeModel
        }
        #expect(try await tasks.infill(infillReq) == "status")
        #expect(await tasks.endpointErrors() == ["qwen": "connection refused"])
        #expect(try await tasks.infill(infillReq) == "i++ {")
        #expect(await tasks.endpointErrors().isEmpty)
        #expect(await claudeModel.calls == 1)
    }

    @Test func aNonConnectionErrorDoesNotFallBack() async {
        let localModel = FakeModel(serves: [.infill], replies: [.failure(.failed("HTTP 500: boom"))])
        let claudeModel = FakeModel(serves: [.infill, .respond], replies: [.success("x")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: claude)) { r in
            r.id == "qwen" ? localModel : claudeModel
        }
        await #expect(throws: QuickModelError.failed("HTTP 500: boom")) { try await tasks.infill(infillReq) }
        #expect(await claudeModel.calls == 0)
    }

    @Test func modelsAreMadeOncePerProvider() async throws {
        let counter = Counter()
        let model = FakeModel(serves: [.infill, .respond], replies: [.success("a"), .success("b")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: claude)) { _ in await counter.bump(); return model }
        _ = try await tasks.infill(infillReq)
        _ = try await tasks.respond(respondReq)
        #expect(await counter.value == 1)
        #expect(await tasks.routedKind(.infill) == "claude-code")
    }

    @Test func concurrentCallsShareOneModelCreation() async throws {
        let counter = Counter()
        let model = FakeModel(serves: [.infill, .respond], replies: [.success("a"), .success("b")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: claude)) { _ in
            await counter.bump()
            try await Task.sleep(for: .milliseconds(100))
            return model
        }
        async let one = tasks.infill(infillReq)
        async let two = tasks.infill(infillReq)
        _ = try await (one, two)
        #expect(await counter.value == 1)
    }

    @Test func anUnreachableLastCandidateIsRecordedAndRethrown() async {
        let localModel = FakeModel(serves: [.infill], replies: [.failure(.unreachable("connection refused"))])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: nil)) { _ in localModel }
        await #expect(throws: QuickModelError.unreachable("connection refused")) { try await tasks.infill(infillReq) }
        #expect(await tasks.endpointErrors() == ["qwen": "connection refused"])
    }
}

private actor Counter { var value = 0; func bump() { value += 1 } }
