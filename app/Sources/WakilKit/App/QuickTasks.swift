import Foundation

/// A quick-tasks provider as the router sees it: what it is and which operations it serves.
public struct QuickProviderRecord: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var baseURL: String
    public var serves: Set<QuickOperation>

    public init(id: String, kind: String, baseURL: String, serves: Set<QuickOperation>) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.serves = serves
    }
}

public struct QuickTasksConfig: Sendable, Equatable {
    public var quickProvider: QuickProviderRecord?
    public var active: QuickProviderRecord?

    public init(quickProvider: QuickProviderRecord?, active: QuickProviderRecord?) {
        self.quickProvider = quickProvider
        self.active = active
    }
}

public func quickRoute(_ op: QuickOperation, _ config: QuickTasksConfig) -> [QuickProviderRecord] {
    var out: [QuickProviderRecord] = []
    for record in [config.quickProvider, config.active].compactMap({ $0 })
    where record.serves.contains(op) && !out.contains(where: { $0.id == record.id }) {
        out.append(record)
    }
    return out
}

/// The one entry point every quick task calls (Decision 42). It picks the model per operation,
/// falls back once from an unreachable endpoint to the next candidate, and keeps each endpoint's
/// last error whole for Settings (Interaction Rule 8). A new quick task is a caller of this, nothing more.
public actor QuickTasks {
    private let config: QuickTasksConfig
    private let makeModel: @Sendable (QuickProviderRecord) async throws -> (any QuickModel)?
    private var models: [String: any QuickModel] = [:]
    private var creating: [String: Task<(any QuickModel)?, Error>] = [:]
    private var errors: [String: String] = [:]
    /// Set by `shutdown()`: a model whose creation lands afterwards is shut down, not kept.
    private var closed = false

    public init(config: QuickTasksConfig, makeModel: @escaping @Sendable (QuickProviderRecord) async throws -> (any QuickModel)?) {
        self.config = config
        self.makeModel = makeModel
    }

    public func infill(_ r: InfillRequest) async throws -> String { try await run(.infill) { try await $0.infill(r) } }
    public func respond(_ r: RespondRequest) async throws -> String { try await run(.respond) { try await $0.respond(r) } }
    public func routedKind(_ op: QuickOperation) -> String? { quickRoute(op, config).first?.kind }
    public func endpointErrors() -> [String: String] { errors }

    public func shutdown() async {
        closed = true
        let open = models.values
        models = [:]
        for model in open { await model.shutdown() }
    }

    private func model(for record: QuickProviderRecord) async throws -> (any QuickModel)? {
        if let m = models[record.id] { return m }
        // Concurrent callers share one creation, so no model is made twice and leaked.
        let task: Task<(any QuickModel)?, Error>
        if let inFlight = creating[record.id] {
            task = inFlight
        } else {
            let make = makeModel
            task = Task { try await make(record) }
            creating[record.id] = task
        }
        defer { creating[record.id] = nil }
        guard let m = try await task.value else { return nil }
        // Shut down while it was being made: nobody would ever stop it, so it stops now.
        if closed {
            if models[record.id] == nil, creating[record.id] != nil {
                creating[record.id] = nil
                await m.shutdown()
            }
            throw CancellationError()
        }
        models[record.id] = m
        return m
    }

    private func run(_ op: QuickOperation, _ call: (any QuickModel) async throws -> String) async throws -> String {
        let candidates = quickRoute(op, config)
        guard !candidates.isEmpty else { throw QuickModelError.noProvider(op) }
        for (index, record) in candidates.enumerated() {
            try Task.checkCancellation()
            guard let m = try await model(for: record), m.serves.contains(op) else { continue }
            do {
                let reply = try await call(m)
                errors[record.id] = nil
                return reply
            } catch QuickModelError.unreachable(let why) {
                errors[record.id] = why
                if index == candidates.count - 1 { throw QuickModelError.unreachable(why) }
            }
        }
        throw QuickModelError.noProvider(op)
    }
}
