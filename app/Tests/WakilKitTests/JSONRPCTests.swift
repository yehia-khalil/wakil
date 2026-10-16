import Testing
import Foundation
@testable import WakilKit

@Test func encodeFrameEndsWithExactlyOneNewline() throws {
    let m = JSONRPCMessage(id: .number(1), method: "ping", params: nil, result: nil, error: nil)
    let d = try encodeFrame(m)
    #expect(d.last == UInt8(ascii: "\n"))
    #expect(d.dropLast().contains(UInt8(ascii: "\n")) == false)
}

@Test func frameReaderSplitsOnNewlinesAcrossChunks() throws {
    var r = FrameReader()
    let first = try r.push(Data(#"{"jsonrpc":"2.0","id":1,"method":"a"}"#.utf8))
    #expect(first.isEmpty)                       // no newline yet: nothing emitted
    let second = try r.push(Data("\n".utf8))
    // Guarded, not `#expect`-ed then indexed: `second[0]` on an empty list
    // traps, and a trap takes the whole test process down rather than failing
    // this one test.
    guard second.count == 1 else {
        Issue.record("expected 1 message once the newline arrived, got \(second.count)"); return
    }
    #expect(second[0].method == "a")
}

@Test func frameReaderEmitsTwoMessagesFromOneChunk() throws {
    var r = FrameReader()
    let out = try r.push(Data(#"{"jsonrpc":"2.0","id":1,"method":"a"}\#n{"jsonrpc":"2.0","id":2,"method":"b"}\#n"#.utf8))
    #expect(out.map(\.method) == ["a", "b"])
}

@Test func frameReaderSkipsBlankLinesRatherThanFailing() throws {
    var r = FrameReader()
    let out = try r.push(Data(("\n\n" + #"{"jsonrpc":"2.0","id":1,"method":"a"}"# + "\n").utf8))
    #expect(out.count == 1)
}

@Test func jsonValueRoundTripsNestedStructures() throws {
    let v = JSONValue.object(["a": .array([.number(1), .string("x"), .null, .bool(true)])])
    let data = try JSONEncoder().encode(v)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == v)
}

@Test func jsonrpcMessageDistinguishesExplicitNullResultFromAbsentResult() throws {
    let withNull = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(#"{"id":1,"result":null}"#.utf8))
    #expect(withNull.result == .null)

    let withoutResult = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(#"{"id":1}"#.utf8))
    #expect(withoutResult.result == nil)

    // Round-trip each back through encode/decode: the distinction must survive,
    // not collapse into the other's shape.
    let redecodedWithNull = try JSONDecoder().decode(JSONRPCMessage.self, from: try JSONEncoder().encode(withNull))
    #expect(redecodedWithNull.result == .null)

    let redecodedWithoutResult = try JSONDecoder().decode(JSONRPCMessage.self, from: try JSONEncoder().encode(withoutResult))
    #expect(redecodedWithoutResult.result == nil)

    // And check the actual wire shape, not just round-tripped equality: one
    // encoding must contain a "result" key, the other must not.
    let withNullObject = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(withNull)) as? [String: Any]
    let withoutResultObject = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(withoutResult)) as? [String: Any]
    #expect(withNullObject?.keys.contains("result") == true)
    #expect(withoutResultObject?.keys.contains("result") == false)
}

@Test func jsonrpcErrorDistinguishesExplicitNullDataFromAbsentData() throws {
    let withNull = try JSONDecoder().decode(JSONRPCError.self, from: Data(#"{"code":-1,"message":"m","data":null}"#.utf8))
    #expect(withNull.data == .null)

    let withoutData = try JSONDecoder().decode(JSONRPCError.self, from: Data(#"{"code":-1,"message":"m"}"#.utf8))
    #expect(withoutData.data == nil)

    let withNullObject = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(withNull)) as? [String: Any]
    let withoutDataObject = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(withoutData)) as? [String: Any]
    #expect(withNullObject?.keys.contains("data") == true)
    #expect(withoutDataObject?.keys.contains("data") == false)
}

@Test func frameReaderLatchesOverflowForNextPushWhenUnterminatedFrameExceedsCap() throws {
    // An all-oversized push (nothing valid to preserve) still must not throw
    // on the same call that overflowed -- see
    // frameReaderPreservesPriorMessagesThenLatchesOverflowOnNextPush for why.
    var r = FrameReader()
    let oversized = Data(repeating: UInt8(ascii: "a"), count: FrameReader.maxBufferedFrameBytes + 1)
    let out = try r.push(oversized)
    #expect(out.isEmpty)

    var caught: FrameReaderError?
    do {
        _ = try r.push(Data())
    } catch let error as FrameReaderError {
        caught = error
    }
    #expect(caught == .frameTooLarge(bufferedBytes: FrameReader.maxBufferedFrameBytes + 1, limit: FrameReader.maxBufferedFrameBytes))
}

@Test func frameReaderPreservesPriorMessagesThenLatchesOverflowOnNextPush() throws {
    // Pins the bug found in review: a single push containing one complete,
    // valid line followed by an oversized unterminated remainder must not
    // lose the valid message just because the same call also overflows. A
    // single read() from a live pipe can easily deliver several good frames
    // plus the start of a bad one, and discarding the good frames alongside
    // the throw would silently drop tool results the peer actually sent.
    var r = FrameReader()
    let validLine = Data(#"{"jsonrpc":"2.0","id":1,"method":"a"}"#.utf8) + Data("\n".utf8)
    let oversizedUnterminated = Data(repeating: UInt8(ascii: "a"), count: FrameReader.maxBufferedFrameBytes + 1)

    let out = try r.push(validLine + oversizedUnterminated)
    #expect(out.map(\.method) == ["a"])

    // The stream is now known-corrupt: the reader must not silently resume
    // as if nothing happened. The overflow is latched and reported on the
    // very next call, even if that call carries no new data.
    var caught: FrameReaderError?
    do {
        _ = try r.push(Data())
    } catch let error as FrameReaderError {
        caught = error
    }
    #expect(caught == .frameTooLarge(bufferedBytes: oversizedUnterminated.count, limit: FrameReader.maxBufferedFrameBytes))
}

@Test func frameReaderPreservesPriorMessagesThenLatchesDecodeErrorOnNextPush() throws {
    // Mirrors frameReaderPreservesPriorMessagesThenLatchesOverflowOnNextPush:
    // the reader's contract is that ANY error -- overflow or a malformed
    // frame -- latches the same way. A single push containing one valid
    // line followed by a malformed non-blank line must not lose the valid
    // message, and the malformed line's error must still surface, just on
    // the next call rather than discarding the valid one to report it.
    var r = FrameReader()
    let validLine = Data(#"{"jsonrpc":"2.0","id":1,"method":"a"}"#.utf8) + Data("\n".utf8)
    let malformedLine = Data("not json\n".utf8)

    let out = try r.push(validLine + malformedLine)
    #expect(out.map(\.method) == ["a"])

    // The stream is now known-corrupt: the reader must not silently resume
    // as if nothing happened. The decode error is latched and reported on
    // the very next call, even if that call carries no new data.
    var caught: Error?
    do {
        _ = try r.push(Data())
    } catch {
        caught = error
    }
    #expect(caught is DecodingError)
}

// Regression test for a bug found in review: `JSONRPCMessage.encode` used
// to omit the mandatory JSON-RPC 2.0 "jsonrpc" version tag entirely. Every
// other test in this file feeds `FrameReader`/`JSONDecoder` hand-written
// JSON that already includes the tag, so none of them could have caught an
// encoder that failed to write it back out -- that gap is exactly why a
// real MCP server (the Go SDK-based wakil-ctx) rejected every outgoing
// frame with `invalid message version tag ""; expected "2.0"` before the
// fix, and nothing here noticed until Task 5 drove a client against it.
//
// This asserts on the raw encoded JSON object, not a decode-back-into-
// JSONRPCMessage round trip: JSONRPCMessage has no stored property for
// "jsonrpc" and ignores it entirely on decode (see the type's doc
// comment), so a round trip would pass even if `encode` dropped the tag
// completely.
@Test func encodedRequestNotificationAndErrorResponseAllCarryTheJSONRPCVersionTag() throws {
    func jsonrpcTag(of message: JSONRPCMessage) throws -> String? {
        let data = try JSONEncoder().encode(message)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["jsonrpc"] as? String
    }

    let request = JSONRPCMessage(id: .number(1), method: "tools/list", params: nil, result: nil, error: nil)
    #expect(try jsonrpcTag(of: request) == "2.0")

    // A notification has no `id`; the tag must still be present.
    let notification = JSONRPCMessage(id: nil, method: "notifications/initialized", params: .object([:]), result: nil, error: nil)
    #expect(try jsonrpcTag(of: notification) == "2.0")

    let errorResponse = JSONRPCMessage(id: .number(2), method: nil, params: nil, result: nil,
                                       error: JSONRPCError(code: -32601, message: "unknown method"))
    #expect(try jsonrpcTag(of: errorResponse) == "2.0")
}

// MARK: - FrameReader at git_show scale

/// One `tools/call`-shaped reply whose encoded line is at least `bytes` long,
/// newline-terminated, as `encodeFrame` writes it.
private func largeFrame(atLeast bytes: Int) throws -> Data {
    let text = String(repeating: "x", count: bytes)
    let m = JSONRPCMessage(id: .number(7), method: nil, params: nil,
                           result: .object(["content": .string(text)]), error: nil)
    return try encodeFrame(m)
}

/// Splits `data` into `size`-byte chunks, the way a pipe read delivers it.
private func chunks(of data: Data, size: Int) -> [Data] {
    stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
}

@Test func frameReaderParsesASixMegabyteFrameInSixtyFourKilobyteChunksQuickly() throws {
    // The walk's defect: a 2 MB file's git_show reply is ~4 MB (the text
    // appears twice). `push` re-scanned the whole buffer from the start on
    // every chunk through the generic Collection path, so one big frame
    // pinned the stdout drain thread for seconds. Measured in debug: 6 MB
    // took 1.64 s before the fix and ~3 ms after (3a-i perf report).
    let frame = try largeFrame(atLeast: 6 * 1024 * 1024)
    let parts = chunks(of: frame, size: 64 * 1024)
    var r = FrameReader()
    var messages: [JSONRPCMessage] = []
    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        for p in parts { messages += try r.push(p) }
    }
    print("FrameReader 6 MB frame in 64 KB chunks: \(elapsed)")
    guard messages.count == 1 else {
        Issue.record("expected one message, got \(messages.count)"); return
    }
    if case .object(let o) = messages[0].result, case .string(let s) = o["content"] {
        #expect(s.utf8.count == 6 * 1024 * 1024)
    } else {
        Issue.record("result did not round-trip")
    }
    #expect(elapsed < .seconds(1))
}

@Test func frameReaderReassemblesSmallFramesSplitAtEveryPosition() throws {
    let a = try encodeFrame(JSONRPCMessage(id: .number(1), method: "a", params: nil, result: nil, error: nil))
    let b = try encodeFrame(JSONRPCMessage(id: .number(2), method: "b", params: nil, result: nil, error: nil))
    let stream = a + Data("\n".utf8) + b   // a blank line between, skipped
    for i in 0...stream.count {
        for j in i...stream.count {
            var r = FrameReader()
            var out: [JSONRPCMessage] = []
            out += try r.push(stream.subdata(in: 0..<i))
            out += try r.push(stream.subdata(in: i..<j))
            out += try r.push(stream.subdata(in: j..<stream.count))
            #expect(out.map(\.method) == ["a", "b"], "split at \(i), \(j)")
        }
    }
}

@Test func frameReaderEmitsManyFramesFromOneChunkAndKeepsTheTail() throws {
    var stream = Data()
    for n in 0..<50 {
        stream += try encodeFrame(JSONRPCMessage(id: .number(n), method: "m\(n)", params: nil, result: nil, error: nil))
    }
    let tail = Data(#"{"jsonrpc":"2.0","id":99,"#.utf8)
    var r = FrameReader()
    let out = try r.push(stream + tail)
    #expect(out.map(\.method) == (0..<50).map { "m\($0)" })
    let rest = try r.push(Data(#""method":"z"}"#.utf8) + Data("\n".utf8))
    #expect(rest.map(\.method) == ["z"])
}

@Test func frameReaderCapIsSixteenMebibytesAndStillRefusesAnythingLarger() throws {
    #expect(FrameReader.maxBufferedFrameBytes == 16 * 1024 * 1024)
    // A ~4.2 MB git_show frame (the walk's 2 MB file) now fits.
    let fits = try largeFrame(atLeast: 4_194_544)
    var ok = FrameReader()
    var got: [JSONRPCMessage] = []
    for p in chunks(of: fits, size: 64 * 1024) { got += try ok.push(p) }
    #expect(got.count == 1)

    // An unterminated line past 16 MiB, delivered in chunks, latches.
    let over = Data(repeating: UInt8(ascii: "a"), count: FrameReader.maxBufferedFrameBytes + 1)
    var r = FrameReader()
    for p in chunks(of: over, size: 1024 * 1024) { _ = try r.push(p) }
    var caught: FrameReaderError?
    do { _ = try r.push(Data()) } catch let e as FrameReaderError { caught = e }
    #expect(caught == .frameTooLarge(bufferedBytes: over.count, limit: FrameReader.maxBufferedFrameBytes))
}
