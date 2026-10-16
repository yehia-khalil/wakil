import Testing
import Foundation
@testable import WakilKit

/// The fixtures recorded by Task 1's live probe — the only record of what
/// the real CLI emits, and the reason this task ran last. Every assertion
/// below is against what these files actually contain (verified by reading
/// them), never against what the plan assumed they would contain.
private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stream-json/\(name)")
    return try Data(contentsOf: url)
}

/// A one-word label per event, used to pin whole fixtures as an ordered
/// sequence. Comparing sequences (rather than only spot-checking a few
/// events) is what makes these tests fail if the decoder ever silently
/// drops, duplicates, or reorders an event.
private func tag(_ event: HarnessEvent) -> String {
    switch event {
    case .systemInit: return "systemInit"
    case .assistantText: return "assistantText"
    case .toolUse: return "toolUse"
    case .toolResult: return "toolResult"
    case .result: return "result"
    case .rateLimit: return "rateLimit"
    case .unknown(let type): return "unknown(\(type))"
    }
}

// MARK: - basic-turn.jsonl

/// `basic-turn.jsonl` is 13 lines; this pins all 13 in order. Note what the
/// sequence shows: only three of the thirteen lines map to a case, and the
/// very first line is *not* `system|init` — it is a `system|
/// session_state_changed`, which has no case and so arrives as
/// `.unknown(type: "system")`.
@Test func basicTurnDecodesAsTheThirteenLinesTheFixtureActuallyHas() throws {
    let events = try decodeHarnessEvents(try fixture("basic-turn.jsonl"))
    #expect(events.map(tag) == [
        "unknown(system)",            // session_state_changed
        "rateLimit",
        "systemInit",
        "unknown(system)",            // status
        "unknown(stream_event)",
        "unknown(stream_event)",
        "unknown(stream_event)",
        "assistantText",
        "unknown(stream_event)",
        "unknown(stream_event)",
        "unknown(stream_event)",
        "result",
        "unknown(system)",            // session_state_changed
    ])
    // The sequence comparison above already carries the diagnostic value, so
    // this bails out rather than indexing into a list a regression has
    // shortened: an unguarded `events[11]` traps, and a trap in one test
    // kills the whole test process — measured, it took 81 of the suite's
    // other tests down with it, turning a precise failure into a signal 5.
    guard events.count == 13 else {
        Issue.record("expected 13 events, got \(events.count) — see the sequence above"); return
    }
    #expect(events[2] == .systemInit(sessionId: "7ca5c477-a62b-4253-af52-994849889d95"))
    #expect(events[7] == .assistantText("ok"))
    #expect(events[11] == .result(isError: false, text: "ok"))
}

/// Probe §3: `result|success` is followed by a `system|session_state_changed`
/// in *both* fixtures, so `result` marks "the turn is over" wherever it
/// appears rather than terminating the stream. The plan's Task 6 test
/// asserted `events.last` is `.result`; that assertion is wrong, and this is
/// the corrected form of it.
@Test func resultAppearsButIsNotTheLastEventInEitherFixture() throws {
    for name in ["basic-turn.jsonl", "tool-call.jsonl"] {
        let events = try decodeHarnessEvents(try fixture(name))
        #expect(events.contains { if case .result = $0 { return true }; return false },
                "\(name) has no .result")
        // `events.last!` on an empty list traps, and a trap takes the whole
        // test process down with it rather than failing this one test.
        guard let last = events.last else {
            Issue.record("\(name) decoded to no events at all"); continue
        }
        #expect(tag(last) == "unknown(system)",
                "\(name) unexpectedly ends with \(tag(last))")
    }
}

// MARK: - tool-call.jsonl

/// The 11 lines of `tool-call.jsonl`, in order. Two tool calls happen here,
/// and neither arrives as its own event type: probe §4's `tool_use` blocks
/// live inside `assistant` events and `tool_result` blocks inside `user`
/// events, which is why lines 4–7 decode to alternating uses and results.
@Test func toolCallDecodesAsTheElevenLinesTheFixtureActuallyHas() throws {
    let events = try decodeHarnessEvents(try fixture("tool-call.jsonl"))
    #expect(events.map(tag) == [
        "unknown(system)",            // session_state_changed
        "systemInit",
        "rateLimit",
        "assistantText",
        "toolUse",                    // ToolSearch
        "toolResult",                 // its tool_reference list
        "toolUse",                    // mcp__wakil-ctx__get_context
        "toolResult",                 // its JSON *string* payload
        "assistantText",
        "result",
        "unknown(system)",            // session_state_changed
    ])
    // Same reason as the 13-line test above: never index past a list a
    // regression may have shortened.
    guard events.count == 11 else {
        Issue.record("expected 11 events, got \(events.count) — see the sequence above"); return
    }
    #expect(events[1] == .systemInit(sessionId: "97af6bd1-d07d-4e04-aedb-c0cb21aab389"))
}

@Test func toolCallFixtureYieldsToolUsesAndResultsThatMatchByID() throws {
    let events = try decodeHarnessEvents(try fixture("tool-call.jsonl"))
    let uses = events.compactMap { if case .toolUse(let id, _, _) = $0 { return id } else { return nil } }
    let results = events.compactMap { if case .toolResult(let id, _, _) = $0 { return id } else { return nil } }
    #expect(uses == ["toolu_01RPjUBy66gZQsFtmHvbM6ZP", "toolu_01HcLFrFZ3tTbkh2z24wVzvQ"])
    #expect(Set(results) == Set(uses))
}

/// Probe §4: tool names are namespaced `mcp__<server>__<tool>`, and anything
/// matching on a tool name (or building `--allowedTools`) needs the prefixed
/// form. The decoder must therefore hand the name through byte-for-byte
/// rather than stripping the prefix.
@Test func aNamespacedMCPToolNameSurvivesIntact() throws {
    let events = try decodeHarnessEvents(try fixture("tool-call.jsonl"))
    let names = events.compactMap { if case .toolUse(_, let name, _) = $0 { return name } else { return nil } }
    #expect(names.contains("mcp__wakil-ctx__get_context"))
}

/// Probe §4: a `ToolSearch` `tool_use` precedes the MCP call, because the
/// CLI defers tool schemas and loads them on demand. Wakil never configured
/// `ToolSearch`, so this pins that the decoder does not assume every
/// `tool_use` is one of ours — it decodes an unrecognised tool name and its
/// input just like any other.
@Test func aToolUseForAToolWakilNeverConfiguredStillDecodes() throws {
    let events = try decodeHarnessEvents(try fixture("tool-call.jsonl"))
    guard case .toolUse(let id, let name, let input)? = events.first(
        where: { if case .toolUse(_, let n, _) = $0 { return n == "ToolSearch" }; return false }
    ) else {
        Issue.record("no ToolSearch tool_use decoded"); return
    }
    #expect(id == "toolu_01RPjUBy66gZQsFtmHvbM6ZP")
    #expect(name == "ToolSearch")
    guard case .object(let arguments) = input else {
        Issue.record("ToolSearch input was \(input), not an object"); return
    }
    #expect(arguments["query"] == .string("select:mcp__wakil-ctx__get_context"))
}

/// Probe §4: the MCP `tool_result` content came back as a **JSON string**,
/// not a decoded object. A consumer that assumed `content` was an object
/// would mis-type it; this pins that it arrives as `.string` and that the
/// string is the untouched payload (re-parsing it here proves nothing was
/// mangled). The `ToolSearch` result in the same fixture is an *array* of
/// `tool_reference` blocks, so both shapes are exercised.
@Test func aToolResultWhoseContentIsAJSONStringStaysAString() throws {
    let events = try decodeHarnessEvents(try fixture("tool-call.jsonl"))
    let contents = events.compactMap { if case .toolResult(_, let c, _) = $0 { return c } else { return nil } }
    // Guarded, not `#expect`-ed then indexed: the same trap-kills-the-process
    // reasoning as the two sequence tests above.
    guard contents.count == 2 else {
        Issue.record("expected 2 tool results, got \(contents.count)"); return
    }

    // Neither call in this fixture failed, and neither block carries an
    // `is_error` key at all — so both must read as successful, which is the
    // real-fixture half of the synthetic flag test further down.
    let flags = events.compactMap { if case .toolResult(_, _, let e) = $0 { return e } else { return nil } }
    #expect(flags == [false, false])

    guard case .array(let referenceBlocks) = contents[0] else {
        Issue.record("the ToolSearch result was \(contents[0]), not an array"); return
    }
    #expect(referenceBlocks.count == 1)

    guard case .string(let json) = contents[1] else {
        Issue.record("the MCP result was \(contents[1]), not a string"); return
    }
    let reparsed = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    guard case .object(let context) = reparsed else {
        Issue.record("the MCP result string did not re-parse as an object"); return
    }
    #expect(context["Environment"] == .string("production"))
    #expect(context["Org"] == .string("personal"))
}

// MARK: - nothing is dropped

/// The drop detector. Both fixtures happen to contain exactly one decodable
/// unit per line — no assistant event in them carries more than one content
/// block — so every non-blank line must produce exactly one event. If the
/// decoder ever swallowed a type it did not recognise instead of tagging it
/// `.unknown`, these counts would fall short even though every other
/// assertion in this file would still pass.
@Test func everyFixtureLineProducesExactlyOneEvent() throws {
    for (name, expected) in [("basic-turn.jsonl", 13), ("tool-call.jsonl", 11)] {
        let data = try fixture(name)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == expected, "\(name) is no longer \(expected) lines")
        #expect(try decodeHarnessEvents(data).count == expected,
                "\(name) decoded to a different number of events than it has lines")
    }
}

/// Probe §2 enumerates the real type set; four of its members
/// (`session_state_changed` and `status`, both `system` subtypes;
/// `stream_event`; `rate_limit_event`) have no `HarnessEvent` case. This
/// pins that each really does surface as `.unknown` carrying the wire's own
/// `"type"` value — and, via the counts, that the three system frames other
/// than `init` are all present rather than collapsed into one.
@Test func everyTypeWithoutACaseSurfacesAsUnknownWithItsWireTag() throws {
    let basic = try decodeHarnessEvents(try fixture("basic-turn.jsonl"))
    let basicTags = basic.compactMap { if case .unknown(let t) = $0 { return t } else { return nil } }
    #expect(Set(basicTags) == ["system", "stream_event"])
    #expect(basicTags.filter { $0 == "system" }.count == 3)        // 2 × state change, 1 × status
    #expect(basicTags.filter { $0 == "stream_event" }.count == 6)

    let toolCall = try decodeHarnessEvents(try fixture("tool-call.jsonl"))
    let toolCallTags = toolCall.compactMap { if case .unknown(let t) = $0 { return t } else { return nil } }
    #expect(Set(toolCallTags) == ["system"])
    #expect(toolCallTags.filter { $0 == "system" }.count == 2)     // 2 × state change, no status
}

// MARK: - synthetic lines: shapes the fixtures do not contain

@Test func anUnrecognisedTypeBecomesUnknownRatherThanThrowing() throws {
    let events = try decodeHarnessEvents(Data((#"{"type":"a_type_that_does_not_exist"}"# + "\n").utf8))
    #expect(events == [.unknown(type: "a_type_that_does_not_exist")])
}

/// Neither fixture has an `assistant` event carrying more than one content
/// block, but the wire format allows it, and the whole reason
/// `decodeHarnessEvents` returns an *array* is that one line can be several
/// events. This pins that fan-out, in block order.
@Test func oneAssistantLineWithSeveralBlocksYieldsSeveralEvents() throws {
    let line = #"""
    {"type":"assistant","message":{"content":[{"type":"text","text":"calling both"},{"type":"tool_use","id":"a","name":"mcp__wakil-ctx__get_context","input":{}},{"type":"tool_use","id":"b","name":"mcp__wakil-db__query","input":{"sql":"select 1"}}]}}
    """#
    let events = try decodeHarnessEvents(Data((line + "\n").utf8))
    // Guarded rather than `#expect`-ed then indexed, for the same reason as
    // the sequence tests above: `events[2]` on a shortened list traps, and a
    // trap is not a failed test but a dead test *process*.
    guard events.count == 3 else {
        Issue.record("expected 3 events from one assistant line, got \(events.count): \(events)"); return
    }
    #expect(events[0] == .assistantText("calling both"))
    #expect(events[1] == .toolUse(id: "a", name: "mcp__wakil-ctx__get_context", input: .object([:])))
    #expect(events[2] == .toolUse(id: "b", name: "mcp__wakil-db__query",
                                  input: .object(["sql": .string("select 1")])))
}

/// Blank lines are structural padding in newline-delimited JSON, not
/// frames of it, so they are skipped rather than reported as malformed.
/// (That they still advance the index a `malformedLine` error reports is
/// pinned by the third case of the malformed-line test below.)
@Test func blankLinesAreSkippedRatherThanTreatedAsMalformed() throws {
    let data = Data("\n\n{\"type\":\"stream_event\"}\n\n".utf8)
    #expect(try decodeHarnessEvents(data) == [.unknown(type: "stream_event")])
}

// MARK: - malformed lines

/// The line this decoder draws: an unrecognised `"type"` is *wire drift* and
/// degrades to `.unknown`, but a line that is not a JSON object with a
/// string `"type"` at all is not a frame of this protocol, and throws. Three
/// inputs trigger it, each checked here with the index of the offending line.
@Test func onlyStructurallyBrokenLinesThrowAndTheyReportTheirIndex() throws {
    let cases: [(String, Int)] = [
        ("not json at all\n", 0),                                   // not JSON
        ("{\"type\":\"stream_event\"}\n[1,2,3]\n", 1),               // JSON, but not an object
        ("{\"type\":\"stream_event\"}\n\n{\"no\":\"type\"}\n", 2),   // object, no "type"
        ("{\"type\":42}\n", 0),                                      // "type" is not a string
    ]
    for (text, index) in cases {
        #expect(throws: StreamJSONError.malformedLine(index: index)) {
            _ = try decodeHarnessEvents(Data(text.utf8))
        }
    }
}

/// The other half of that line: a *recognised* type whose payload is not
/// what this decoder expects degrades to `.unknown` rather than throwing —
/// the same reasoning as an unrecognised type. Nothing about a missing
/// `session_id` or an empty content array should be able to kill a live
/// session, and every well-formed line still yields at least one event so
/// the thought thread can show that something arrived.
@Test func aRecognisedTypeWithAnUnexpectedPayloadDegradesInsteadOfThrowing() throws {
    let lines = [
        #"{"type":"system","subtype":"init"}"#,                      // init with no session_id
        #"{"type":"assistant","message":{"content":[]}}"#,           // no blocks at all
        #"{"type":"user","message":{"content":"just a string"}}"#,   // content is not an array
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"x","input":{}}]}}"#,  // no id
    ]
    let events = try decodeHarnessEvents(Data((lines.joined(separator: "\n") + "\n").utf8))
    #expect(events == [
        .unknown(type: "system"),
        .unknown(type: "assistant"),
        .unknown(type: "user"),
        .unknown(type: "assistant"),
    ])
}

/// `result` is the one case carrying a flag the UI must not get wrong, and
/// neither fixture contains a failing turn (probe §6 saw one, but it was not
/// recorded), so this pins the error path synthetically.
@Test func aFailedResultDecodesAsAnErrorAndAMissingTextIsNil() throws {
    let lines = [
        #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}"#,
        #"{"type":"result","subtype":"success","is_error":false}"#,
    ]
    let events = try decodeHarnessEvents(Data((lines.joined(separator: "\n") + "\n").utf8))
    #expect(events == [.result(isError: true, text: "boom"), .result(isError: false, text: nil)])
}

/// The `tool_result` twin of the test above, and for the same reason: probe
/// §4 records that a `tool_result` block carries `is_error` when the call
/// failed, and probe §6's permission denial — the observation that *proves*
/// the write gate's second layer fires at the harness — arrives exactly this
/// way. Neither fixture contains a failing call, so the flag is pinned
/// synthetically: present-and-true, present-and-false, and absent (which
/// must read as `false`, not as "unknown"). Without this, a refused tool call
/// would be indistinguishable from a successful one at the event level.
@Test func aFailedToolResultCarriesItsErrorFlagAndAMissingOneIsFalse() throws {
    let lines = [
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"Permission for this tool use was denied.","is_error":true}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"ok","is_error":false}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c","content":"ok"}]}}"#,
    ]
    let events = try decodeHarnessEvents(Data((lines.joined(separator: "\n") + "\n").utf8))
    #expect(events == [
        .toolResult(id: "a", content: .string("Permission for this tool use was denied."), isError: true),
        .toolResult(id: "b", content: .string("ok"), isError: false),
        .toolResult(id: "c", content: .string("ok"), isError: false),
    ])
}

// MARK: - rate_limit_event

private func rateLine(_ fiveHourUtil: String, _ sevenDay: String = #","seven_day":{"utilization":0.41,"resetsAt":1788854400}"#) -> Data {
    Data(#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":\#(fiveHourUtil),"resetsAt":1788818400}\#(sevenDay)}}}"#.utf8)
}

@Test func rateLimitEventDecodesBothWindowsAsPercentLeft() throws {
    let events = try decodeHarnessEvents(rateLine("0.01"))
    guard case .rateLimit(let w)? = events.first else { Issue.record("got \(events)"); return }
    #expect(w.fiveHour.percentLeft == 99)
    #expect(w.fiveHour.resetsAt == Date(timeIntervalSince1970: 1788818400))
    #expect(w.sevenDay?.percentLeft == 59)
}

// Review Focus 3: 0 and 1 arrive as JSON integers.
@Test func rateLimitUtilizationZeroAndOneDecode() throws {
    for (util, left) in [("0", 100), ("1", 0)] {
        let events = try decodeHarnessEvents(rateLine(util))
        guard case .rateLimit(let w)? = events.first else { Issue.record("\(util): \(events)"); continue }
        #expect(w.fiveHour.percentLeft == left)
    }
}

@Test func rateLimitWithABadFiveHourWindowStaysUnknown() throws {
    for bad in ["1.3", "-0.1", #""half""#] {
        let events = try decodeHarnessEvents(rateLine(bad))
        #expect(events == [.unknown(type: "rate_limit_event")], "utilization \(bad)")
    }
}

@Test func rateLimitWithABadWeekKeepsTheFiveHourWindow() throws {
    let events = try decodeHarnessEvents(rateLine("0.5", #","seven_day":{"utilization":7,"resetsAt":1788854400}"#))
    guard case .rateLimit(let w)? = events.first else { Issue.record("got \(events)"); return }
    #expect(w.fiveHour.percentLeft == 50)
    #expect(w.sevenDay == nil)
}

@Test func aBareRateLimitEventStaysUnknown() throws {
    #expect(try decodeHarnessEvents(Data(#"{"type":"rate_limit_event"}"#.utf8)) == [.unknown(type: "rate_limit_event")])
}
