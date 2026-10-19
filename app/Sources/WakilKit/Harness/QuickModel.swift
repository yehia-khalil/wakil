import Foundation

/// The harness axis's second seam (Decision 16, amended 3b-viii): one-shot quick tasks.
/// `AgentHarness` is for sessions.

/// What a quick task asks of a model.
public enum QuickOperation: String, Sendable, CaseIterable, Codable { case infill, respond }

/// A named piece of context handed to an infill (an open file's head, a neighbouring symbol).
public struct QuickExtra: Sendable, Equatable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// Fill the gap between `prefix` and `suffix`.
public struct InfillRequest: Sendable, Equatable {
    public var prefix: String
    public var suffix: String
    public var path: String
    public var language: String
    public var extras: [QuickExtra]
    public var multiline: Bool

    public init(prefix: String, suffix: String, path: String, language: String, extras: [QuickExtra], multiline: Bool) {
        self.prefix = prefix
        self.suffix = suffix
        self.path = path
        self.language = language
        self.extras = extras
        self.multiline = multiline
    }
}

/// Answer `input` under `instructions`, optionally shaped by a JSON schema.
public struct RespondRequest: Sendable, Equatable {
    public var instructions: String
    public var input: String
    public var jsonSchema: String?
    public var maxTokens: Int

    public init(instructions: String, input: String, jsonSchema: String?, maxTokens: Int) {
        self.instructions = instructions
        self.input = input
        self.jsonSchema = jsonSchema
        self.maxTokens = maxTokens
    }
}

public enum QuickModelError: Error, Equatable, CustomStringConvertible {
    case unsupported(QuickOperation)
    case noProvider(QuickOperation)
    case unreachable(String)
    case invalidReply(String)
    case failed(String)

    public var description: String {
        switch self {
        case .unsupported(let op), .noProvider(let op): return "no quick-tasks provider serves \(op.rawValue)"
        case .unreachable(let why), .invalidReply(let why), .failed(let why): return why
        }
    }
}

public protocol QuickModel: Sendable {
    var serves: Set<QuickOperation> { get }
    func infill(_ request: InfillRequest) async throws -> String
    func respond(_ request: RespondRequest) async throws -> String
    func shutdown() async
}
