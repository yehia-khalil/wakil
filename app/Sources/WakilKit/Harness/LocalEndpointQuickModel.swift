import Foundation

/// Checks a model's JSON reply against the top-level `type` of the schema it was asked to follow.
/// Shared by every `QuickModel` that takes a schema; it is a shape check, not a full validator.
enum QuickJSON {
    static func validate(_ reply: String, schema: String) throws -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(reply.utf8), options: [.fragmentsAllowed]) else {
            throw QuickModelError.invalidReply("reply is not JSON: \(reply)")
        }
        let wanted = (try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])?["type"] as? String
        switch wanted {
        case "object" where !(value is [String: Any]),
             "array" where !(value is [Any]),
             "string" where !(value is String):
            throw QuickModelError.invalidReply("reply is not a JSON \(wanted ?? ""): \(reply)")
        case "boolean", "number", "integer":
            guard let n = value as? NSNumber else {
                throw QuickModelError.invalidReply("reply is not a JSON \(wanted ?? ""): \(reply)")
            }
            let isBool = CFGetTypeID(n) == CFBooleanGetTypeID()
            if wanted == "boolean", !isBool { throw QuickModelError.invalidReply("reply is not a JSON boolean: \(reply)") }
            if wanted != "boolean", isBool { throw QuickModelError.invalidReply("reply is not a JSON \(wanted ?? ""): \(reply)") }
            if wanted == "integer", n.doubleValue != n.doubleValue.rounded() {
                throw QuickModelError.invalidReply("reply is not a JSON integer: \(reply)")
            }
        default: break
        }
        return reply
    }
}

/// A `QuickModel` that speaks HTTP to an operator-run local server: llama.cpp-style `/infill`
/// and the OpenAI chat shape at `/v1/chat/completions`.
public final class LocalEndpointQuickModel: QuickModel, Sendable {
    public let serves: Set<QuickOperation>
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, serves: Set<QuickOperation>, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.serves = serves
        self.session = session
    }

    public func infill(_ request: InfillRequest) async throws -> String {
        guard serves.contains(.infill) else { throw QuickModelError.unsupported(.infill) }
        var body: [String: Any] = [
            "input_prefix": request.prefix,
            "input_suffix": request.suffix,
            "input_extra": request.extras.map { ["filename": $0.name, "text": $0.text] },
            "n_predict": request.multiline ? 128 : 64,
            "temperature": 0,
            "cache_prompt": true,
        ]
        if !request.multiline { body["stop"] = ["\n"] }
        let data = try await post("infill", body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? String
        else { throw QuickModelError.invalidReply(String(decoding: data, as: UTF8.self)) }
        return content
    }

    public func respond(_ request: RespondRequest) async throws -> String {
        guard serves.contains(.respond) else { throw QuickModelError.unsupported(.respond) }
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": request.instructions],
                ["role": "user", "content": request.input],
            ],
            "max_tokens": request.maxTokens,
            "temperature": 0,
        ]
        if let schema = request.jsonSchema {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) else {
                throw QuickModelError.invalidReply("schema is not JSON: \(schema)")
            }
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "schema": parsed]]
        }
        let data = try await post("v1/chat/completions", body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let content = (choice["message"] as? [String: Any])?["content"] as? String
        else { throw QuickModelError.invalidReply(String(decoding: data, as: UTF8.self)) }
        if let schema = request.jsonSchema { return try QuickJSON.validate(content, schema: schema) }
        return content
    }

    public func shutdown() async {}

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError {
            switch e.code {
            case .cancelled: throw CancellationError()
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                throw QuickModelError.unreachable(e.localizedDescription)
            default: throw QuickModelError.failed(e.localizedDescription)
            }
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuickModelError.failed("HTTP \(http.statusCode): \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }
}
