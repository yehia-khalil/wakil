import Foundation
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

    @Test func aRespondWithoutFallbackAsksOnlyTheRoutedProvider() async {
        // The fast path's call: a local server that is down sends the line to the agent, not to Claude.
        let both = QuickProviderRecord(id: "qwen", kind: "local", baseURL: "http://127.0.0.1:8012", serves: [.infill, .respond])
        let localModel = FakeModel(serves: [.infill, .respond], replies: [.failure(.unreachable("connection refused"))])
        let claudeModel = FakeModel(serves: [.infill, .respond], replies: [.success("{}")])
        let made = Counter()
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: both, active: claude)) { r in
            if r.id == "main" { await made.bump() }
            return r.id == "qwen" ? localModel : claudeModel
        }
        await #expect(throws: QuickModelError.unreachable("connection refused")) {
            try await tasks.respond(respondReq, fallback: false)
        }
        #expect(await claudeModel.calls == 0)
        #expect(await made.value == 0, "the session provider's model is not even made")
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

    /// Every failure but a cancellation is kept whole for its provider (Rule 8) — a failed turn, an
    /// invalid reply, a model that could not be made — and the provider's next success clears it.
    @Test func everyNonCancellationErrorIsRecordedAndClearedOnSuccess() async throws {
        let localModel = FakeModel(serves: [.infill], replies: [
            .failure(.failed("HTTP 500: boom")), .failure(.invalidReply("not JSON")), .success("ok"),
        ])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: nil)) { _ in localModel }
        #expect(await tasks.answered().isEmpty)
        _ = try? await tasks.infill(infillReq)
        #expect(await tasks.endpointErrors() == ["qwen": "HTTP 500: boom"])
        _ = try? await tasks.infill(infillReq)
        #expect(await tasks.endpointErrors() == ["qwen": "not JSON"])
        #expect(try await tasks.infill(infillReq) == "ok")
        #expect(await tasks.endpointErrors().isEmpty)
        #expect(await tasks.answered() == ["qwen"])
    }

    @Test func aModelThatCannotBeMadeIsRecordedWhole() async {
        struct NoCredentials: Error, CustomStringConvertible {
            var description: String { "Keychain: no credentials for main" }
        }
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: claude)) { _ in throw NoCredentials() }
        await #expect(throws: NoCredentials.self) { try await tasks.infill(infillReq) }
        #expect(await tasks.endpointErrors() == ["main": "Keychain: no credentials for main"])
        #expect(await tasks.answered().isEmpty)
    }

    @Test func aCancelledCallRecordsNothing() async {
        struct Cancelled: QuickModel {
            let serves: Set<QuickOperation> = [.infill]
            func infill(_ r: InfillRequest) async throws -> String { throw CancellationError() }
            func respond(_ r: RespondRequest) async throws -> String { throw CancellationError() }
            func shutdown() async {}
        }
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: nil)) { _ in Cancelled() }
        await #expect(throws: CancellationError.self) { try await tasks.infill(infillReq) }
        #expect(await tasks.endpointErrors().isEmpty)
    }

    /// Each error is logged once when it changes, not on every call that repeats it.
    @Test func eachErrorIsLoggedOncePerChange() async {
        let lines = Lines()
        let localModel = FakeModel(serves: [.infill], replies: [
            .failure(.failed("boom")), .failure(.failed("boom")), .failure(.failed("bang")),
            .success("ok"), .failure(.failed("bang")),
        ])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: nil),
                               log: { line in lines.append(line) }) { _ in localModel }
        for _ in 0..<5 { _ = try? await tasks.infill(infillReq) }
        #expect(lines.all == ["quick-tasks: qwen: boom", "quick-tasks: qwen: bang", "quick-tasks: qwen: bang"])
    }

    @Test func theRoutedProviderIsNamedPerOperation() async {
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: claude)) { _ in nil }
        #expect(await tasks.routedId(.infill) == "qwen")
        #expect(await tasks.routedId(.respond) == "main")
    }

    @Test func recordFailureShowsUnderTheRoutedProvider() async {
        let lines = Lines()
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: claude),
                               log: { line in lines.append(line) }) { _ in nil }
        await tasks.recordFailure("the model's reply was not a group name: x", for: .respond)
        #expect(await tasks.endpointErrors() == ["main": "the model's reply was not a group name: x"])
        #expect(lines.all == ["quick-tasks: main: the model's reply was not a group name: x"])
        await tasks.recordFailure("the model's reply was not a group name: x", for: .respond)
        #expect(lines.all.count == 1)
        let none = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: nil)) { _ in nil }
        await none.recordFailure("x", for: .respond)
        #expect(await none.endpointErrors().isEmpty)
    }

    /// Once shut down, no model is made: a dead organisation's credentials are never read.
    @Test func nothingIsMadeAfterShutdown() async {
        let counter = Counter()
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: claude)) { _ in
            await counter.bump()
            return FakeModel(serves: [.infill], replies: [.success("x")])
        }
        await tasks.shutdown()
        await #expect(throws: CancellationError.self) { try await tasks.infill(infillReq) }
        #expect(await counter.value == 0)
    }

    /// A model whose creation finishes after the quick tasks were shut down is shut down itself, and
    /// the call that asked for it ends: nothing outlives a rebuild.
    @Test func aModelMadeAfterShutdownIsShutDownAndTheCallEnds() async throws {
        let gate = Gate()
        let model = ClosingModel()
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: claude)) { _ in
            await gate.wait()
            return model
        }
        let call = Task { try await tasks.infill(infillReq) }
        while await !gate.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
        await tasks.shutdown()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(await model.shutdowns == 1)
        #expect(await model.calls == 0)
    }
}

private actor Counter { var value = 0; func bump() { value += 1 } }

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume(); waiter = nil }
}

private actor ClosingModel: QuickModel {
    nonisolated let serves: Set<QuickOperation> = [.infill, .respond]
    private(set) var calls = 0
    private(set) var shutdowns = 0
    func infill(_ r: InfillRequest) async throws -> String { calls += 1; return "x" }
    func respond(_ r: RespondRequest) async throws -> String { calls += 1; return "x" }
    func shutdown() async { shutdowns += 1 }
}
