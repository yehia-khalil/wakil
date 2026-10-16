import Foundation
import Testing
@testable import WakilKit

/// **The test that was missing, and whose absence let four criticals
/// through.**
///
/// Every send test stubs `ToolCaller` with a struct that ignores both the
/// tool name and the arguments and returns a hand-built reply. So Swift
/// could call the read-only `request` tool for a POST, send `entry` where
/// Go declares `api`, send arrays where Go declares `map[string]string`,
/// and match `.number` against an integer — and all four passed green,
/// because nothing anywhere compared the two sides.
///
/// **These read `cmd/wakil-http/main.go` and `httpclient.go` directly.** A
/// contract between two languages in one repo has one source of truth, and
/// it is the side that enforces it.

private func goSource(_ relative: String) throws -> String {
    // The REPO root: this file is at app/Tests/WakilKitTests/, so four
    // levels up, not three. `app/` is not the root — the Go the contract
    // belongs to lives beside it.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WakilKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app
        .deletingLastPathComponent()  // the repo
    return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}

@Test("A mutation method goes to the send tool, and a read to request")
func theRightToolForTheMethod() throws {
    // `request` runs AssertHTTPReadOnly and refuses a mutation outright;
    // `send` is the only tool with body and contentType fields at all.
    #expect(ApiSendTool.forMethod("GET") == .request)
    #expect(ApiSendTool.forMethod("HEAD") == .request)
    for method in ["POST", "PUT", "PATCH", "DELETE", "post"] {
        #expect(ApiSendTool.forMethod(method) == .send)
    }

    let main = try goSource("cmd/wakil-http/main.go")
    #expect(main.contains("Name: \"request\""))
    #expect(main.contains("Name: \"send\""))
}

@Test("Every argument key Swift sends is one the Go tool declares")
func theArgumentKeysMatchTheTool() throws {
    var draft = ApiDraft.empty
    draft.entry = "billing"
    draft.method = "POST"
    draft.path = [.literal("/bookings/41/confirm")]
    draft.query = [ApiQueryRow(name: "dry", value: [.literal("true")])]
    draft.headers = [ApiHeaderRow(name: "x-trace", value: [.literal("abc")])]
    draft.contentType = "application/json"
    draft.body = [.literal("{}")]

    guard case .success(let wire) = resolveDraft(draft, sources: [:], credentialed: false) else {
        Issue.record("the fixture draft did not resolve"); return
    }
    guard case .object(let arguments) = apiWireArguments(wire) else {
        Issue.record("arguments are not an object"); return
    }

    // `sendArg`'s json tags, read off the Go source rather than retyped.
    let main = try goSource("cmd/wakil-http/main.go")
    for key in arguments.keys {
        #expect(
            main.contains("json:\"\(key)\"") || main.contains("json:\"\(key),omitempty\""),
            "wakil-http declares no field for the argument \(key)")
    }

    // The three that were wrong, named individually so a failure says
    // which.
    #expect(arguments["api"] == .string("billing"))
    #expect(arguments["entry"] == nil)
    // Maps, not arrays of {name, value}.
    #expect(arguments["query"] == .object(["dry": .string("true")]))
    #expect(arguments["headers"] == .object(["x-trace": .string("abc")]))
}

@Test("An omitted entry is omitted, because that is what resolves a single-entry environment")
func anEmptyEntryIsNotSentAsEmpty() {
    var draft = ApiDraft.empty
    draft.method = "GET"
    draft.path = [.literal("/x")]
    guard case .success(let wire) = resolveDraft(draft, sources: [:], credentialed: false),
        case .object(let arguments) = apiWireArguments(wire)
    else { Issue.record("did not resolve"); return }
    // Go's `omitempty` branch is what resolves the single entry; sending
    // `"api": ""` would take the named branch with a name nothing has.
    #expect(arguments["api"] == nil)
}

@Test("A status off the wire is an integer, and the decoder reads integers")
func aStatusOffTheWireIsRead() throws {
    // Exactly what `HTTPResult` encodes: a Go int.
    let reply = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(#"{"structuredContent":{"status":200,"body":"{}","truncated":false}}"#.utf8))
    guard case .object(let envelope) = reply,
        case .object(let content)? = envelope["structuredContent"]
    else { Issue.record("not an object"); return }
    // The premise: it is `.integer`, which is why a `.number` pattern
    // made `ok` unreachable in production.
    guard case .integer = content["status"] else {
        Issue.record("status decoded as \(String(describing: content["status"]))"); return
    }

    let response = apiResponse(
        from: reply, environment: "staging", started: Date(), url: "https://x.example.com/y")
    guard case .ok(let ok) = response else {
        Issue.record("a real reply did not read as ok: \(response.state)"); return
    }
    #expect(ok.status == 200)
    #expect(ok.url == "https://x.example.com/y")
}

@Test("A tool-side refusal is a refusal, not a fate unknown")
func isErrorIsARefusal() throws {
    // `mcpx.ToolErr` answers a refusal as a SUCCESSFUL call carrying
    // isError — so a reader that only looked for structuredContent
    // recorded "it may have reached the server" for a request Go declined
    // to send, and added a recent row for it.
    let reply = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(#"{"isError":true,"content":[{"type":"text","text":"no api entry named billing"}]}"#.utf8))

    let response = apiResponse(
        from: reply, environment: "staging", started: Date(), url: "")
    guard case .refusal(let refusal) = response else {
        Issue.record("a tool refusal read as \(response.state)"); return
    }
    #expect(refusal.failures.first?.message.contains("no api entry named billing") == true)
    #expect(response.status == nil)
}

@Test("HTTPResult carries no url, which is why the sender composes one")
func theReplyCarriesNoURL() throws {
    let client = try goSource("internal/wakilcore/httpclient.go")
    // If this ever gains a url field, `apiSentURL` should be deleted in
    // favour of it — the sender composing one is second best.
    #expect(!client.contains("Url string `json:\"url\"`"))
    #expect(!client.contains("URL string `json:\"url\"`"))

    var draft = ApiDraft.empty
    draft.method = "GET"
    draft.path = [.literal("/bookings/41")]
    draft.query = [ApiQueryRow(name: "expand", value: [.literal("guest")])]
    guard case .success(let wire) = resolveDraft(draft, sources: [:], credentialed: false) else {
        Issue.record("did not resolve"); return
    }
    let url = apiSentURL(wire, origin: "https://billing.example.com/")
    #expect(url == "https://billing.example.com/bookings/41?expand=guest")
    // With no origin known the path stands alone rather than being
    // prefixed with a guess.
    #expect(apiSentURL(wire, origin: nil) == "/bookings/41?expand=guest")
}


@Test("A tool error that carries Go's transport marker is a transport failure, not a refusal")
func aTransportFailureIsNotARefusal() throws {
    // The marker is Go's, written in one place. If it moves, Swift
    // silently reclassifies every dial failure as "nothing was sent" —
    // so it is pinned against the source rather than retyped.
    let client = try goSource("internal/wakilcore/httpclient.go")
    #expect(
        client.contains("UserError(scrubber.Scrub(\"\(apiTransportFailureMarker)\" + err.Error()))"),
        "httpclient.go no longer prefixes a transport failure with \(apiTransportFailureMarker)")

    let failed = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(#"{"isError":true,"content":[{"type":"text","text":"request failed: dial tcp: no such host"}]}"#.utf8))
    guard case .transport(let failure) = apiResponse(
        from: failed, environment: "staging", started: Date(), url: "")
    else {
        Issue.record("a dial failure did not read as a transport failure"); return
    }
    #expect(failure.reason.contains("no such host"))

    // And a refusal Go authored before sending is still a refusal.
    let refused = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(#"{"isError":true,"content":[{"type":"text","text":"path must not contain \"..\" segments"}]}"#.utf8))
    guard case .refusal = apiResponse(
        from: refused, environment: "staging", started: Date(), url: "")
    else {
        Issue.record("a path refusal did not read as a refusal"); return
    }
}
