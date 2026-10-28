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

/// What Settings draws for the quick tasks: each provider's last error whole and the providers that
/// have answered (both by id), the provider code completion goes to first, and why the
/// configuration could not be read — kept apart, so no provider id collides with it.
public struct QuickTaskStatus: Sendable, Equatable {
    public var errors: [String: String]
    public var answered: Set<String>
    public var routedInfill: String?
    public var configError: String?

    public init(errors: [String: String] = [:], answered: Set<String> = [], routedInfill: String? = nil, configError: String? = nil) {
        self.errors = errors
        self.answered = answered
        self.routedInfill = routedInfill
        self.configError = configError
    }
}

/// The one entry point every quick task calls (Decision 42). It picks the model per operation,
/// falls back once from an unreachable endpoint to the next candidate, and keeps each provider's
/// last error whole for Settings (Interaction Rule 8) — every failure but a cancellation, including a
/// model that could not be made — logging each to stderr once when it changes. A provider's next
/// success clears its error. A new quick task is a caller of this, nothing more.
public actor QuickTasks {
    private let config: QuickTasksConfig
    private let makeModel: @Sendable (QuickProviderRecord) async throws -> (any QuickModel)?
    private var models: [String: any QuickModel] = [:]
    private var creating: [String: Task<(any QuickModel)?, Error>] = [:]
    private var errors: [String: String] = [:]
    /// The providers that have answered at least once, so Settings never claims one answers
    /// before it has.
    private var succeeded: Set<String> = []
    private let log: @Sendable (String) -> Void
    /// Set by `shutdown()`: a model whose creation lands afterwards is shut down, not kept.
    private var closed = false

    public init(
        config: QuickTasksConfig, log: @escaping @Sendable (String) -> Void = QuickTasks.logToStandardError,
        makeModel: @escaping @Sendable (QuickProviderRecord) async throws -> (any QuickModel)?
    ) {
        self.config = config
        self.log = log
        self.makeModel = makeModel
    }

    public func infill(_ r: InfillRequest) async throws -> String { try await run(.infill) { try await $0.infill(r) } }
    /// `fallback: false` asks the routed provider alone: the fast path's line goes to the agent
    /// rather than wait on the session provider when a local server is down.
    public func respond(_ r: RespondRequest, fallback: Bool = true) async throws -> String {
        try await run(.respond, fallback: fallback) { try await $0.respond(r) }
    }
    public func routedKind(_ op: QuickOperation) -> String? { quickRoute(op, config).first?.kind }
    public func endpointErrors() -> [String: String] { errors }
    public func answered() -> Set<String> { succeeded }
    public func routedId(_ op: QuickOperation) -> String? { quickRoute(op, config).first?.id }
    /// A caller's own failure with a reply the provider gave (one it could not read), kept whole against
    /// the provider `op` routes to, as `run` keeps the provider's own errors.
    public func recordFailure(_ message: String, for op: QuickOperation) {
        guard let id = routedId(op) else { return }
        note(message, for: id)
    }

    /// `quick-tasks:` lines beside the editor's `monaco-editor:` ones.
    public static let logToStandardError: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    public func shutdown() async {
        closed = true
        let open = models.values
        models = [:]
        for model in open { await model.shutdown() }
    }

    private func model(for record: QuickProviderRecord) async throws -> (any QuickModel)? {
        // A shut-down organisation makes nothing: no credentials are read for it.
        if closed { throw CancellationError() }
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

    private func run(
        _ op: QuickOperation, fallback: Bool = true, _ call: (any QuickModel) async throws -> String
    ) async throws -> String {
        let route = quickRoute(op, config)
        let candidates = fallback ? route : Array(route.prefix(1))
        guard !candidates.isEmpty else { throw QuickModelError.noProvider(op) }
        for (index, record) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                guard let m = try await model(for: record), m.serves.contains(op) else { continue }
                let reply = try await call(m)
                errors[record.id] = nil
                succeeded.insert(record.id)
                return reply
            } catch is CancellationError {
                throw CancellationError()
            } catch QuickModelError.unreachable(let why) {
                note("\(QuickModelError.unreachable(why))", for: record.id)
                if index == candidates.count - 1 { throw QuickModelError.unreachable(why) }
            } catch {
                note("\(error)", for: record.id)
                throw error
            }
        }
        throw QuickModelError.noProvider(op)
    }

    /// A reply the model gave but its caller could not use (a name that did not parse): kept under the
    /// provider `op` routes to, like a model's own error, so Settings shows it whole.
    public func recordFailure(_ error: String, for op: QuickOperation) {
        guard let id = routedId(op) else { return }
        note(error, for: id)
    }

    /// Keeps `error` whole as `id`'s last error, logging it when it differs from the one kept. A
    /// failure caused by the shutdown itself (a session ended under its turn) is nobody's to read.
    private func note(_ error: String, for id: String) {
        guard !closed, errors[id] != error else { return }
        errors[id] = error
        log("quick-tasks: \(id): \(error)")
    }
}
