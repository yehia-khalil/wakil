import Foundation
import Testing
@testable import WakilKit

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var lastPath = ""
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { s in
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            return d
        } ?? Data()
        Self.lastPath = request.url?.path ?? ""
        Self.lastBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        guard let (status, data) = Self.handler?(request, body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LocalEndpointQuickModelTests {
    func model(_ serves: Set<QuickOperation> = [.infill, .respond]) -> LocalEndpointQuickModel {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return LocalEndpointQuickModel(baseURL: URL(string: "http://127.0.0.1:8012")!, serves: serves, session: URLSession(configuration: c))
    }

    @Test func infillPostsTheLlamaShape() async throws {
        StubProtocol.handler = { _, _ in (200, Data(#"{"content":"ConfirmedAt = time.Now()"}"#.utf8)) }
        let r = InfillRequest(prefix: "b.", suffix: "\n}", path: "a.go", language: "go",
                              extras: [QuickExtra(name: "schema.sql", text: "CREATE TABLE bookings (id);")], multiline: false)
        #expect(try await model().infill(r) == "ConfirmedAt = time.Now()")
        #expect(StubProtocol.lastPath == "/infill")
        let b = StubProtocol.lastBody
        #expect(b["input_prefix"] as? String == "b.")
        #expect(b["input_suffix"] as? String == "\n}")
        #expect(b["n_predict"] as? Int == 64)
        #expect(b["cache_prompt"] as? Bool == true)
        #expect(b["stop"] as? [String] == ["\n"])
        #expect((b["input_extra"] as? [[String: String]])?.first?["filename"] == "schema.sql")
    }

    @Test func multilineAsksForMoreAndDoesNotStopAtNewline() async throws {
        StubProtocol.handler = { _, _ in (200, Data(#"{"content":"x"}"#.utf8)) }
        _ = try await model().infill(InfillRequest(prefix: "", suffix: "", path: "a.go", language: "go", extras: [], multiline: true))
        #expect(StubProtocol.lastBody["n_predict"] as? Int == 128)
        #expect(StubProtocol.lastBody["stop"] == nil)
    }

    @Test func respondUsesChatCompletionsWithSchema() async throws {
        StubProtocol.handler = { _, _ in (200, Data(#"{"choices":[{"message":{"content":"{\"a\":1}"}}]}"#.utf8)) }
        let out = try await model().respond(RespondRequest(instructions: "pick", input: "open a.go",
                                                           jsonSchema: #"{"type":"object"}"#, maxTokens: 32))
        #expect(out == #"{"a":1}"#)
        #expect(StubProtocol.lastPath == "/v1/chat/completions")
        let msgs = StubProtocol.lastBody["messages"] as? [[String: String]]
        #expect(msgs?.map { $0["role"] ?? "" } == ["system", "user"])
        #expect((StubProtocol.lastBody["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func respondRejectsNonJSONWhenSchemaSet() async {
        StubProtocol.handler = { _, _ in (200, Data(#"{"choices":[{"message":{"content":"sure!"}}]}"#.utf8)) }
        await #expect(throws: QuickModelError.self) {
            try await model().respond(RespondRequest(instructions: "", input: "", jsonSchema: #"{"type":"object"}"#, maxTokens: 8))
        }
    }

    @Test func connectionFailureIsUnreachableAndHTTPErrorIsFailedWhole() async {
        StubProtocol.handler = nil
        await #expect(throws: QuickModelError.self) { try await model().infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false)) }
        do { _ = try await model().infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false)) }
        catch let e as QuickModelError { if case .unreachable = e {} else { Issue.record("want unreachable, got \(e)") } }
        catch { Issue.record("\(error)") }
        StubProtocol.handler = { _, _ in (500, Data("model not loaded".utf8)) }
        await #expect(throws: QuickModelError.failed("HTTP 500: model not loaded")) {
            try await model().infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false))
        }
    }

    @Test func anOperationItDoesNotServeThrowsUnsupported() async {
        await #expect(throws: QuickModelError.unsupported(.respond)) {
            try await model([.infill]).respond(RespondRequest(instructions: "", input: "", jsonSchema: nil, maxTokens: 8))
        }
    }
}
