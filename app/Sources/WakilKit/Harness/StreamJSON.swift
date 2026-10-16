import Foundation

/// One decoded event from the `claude` CLI's `--output-format stream-json`
/// wire protocol, as produced by `decodeHarnessEvents` below.
///
/// The six cases are exactly the ones the design spec commits to, and they
/// deliberately cover far less than the wire emits. Task 1's live probe
/// (`docs/wakil/phase-2a-probe.md` §2) recorded the real type set across
/// both fixtures — `system|init`, `system|session_state_changed`,
/// `system|status`, `stream_event`, `assistant`, `user`,
/// `rate_limit_event`, `result|success` — of which only `system|init`,
/// `assistant`, `user` and `result` map to a case at all. `.unknown` is
/// therefore the ordinary path, not a defensive corner: 10 of
/// `basic-turn.jsonl`'s 13 lines take it.
public enum HarnessEvent: Sendable, Equatable {
    /// The session announcing itself at the start of a run, carrying the
    /// session id the CLI is using. Decoded from a `system` frame whose
    /// `"subtype"` is `init` — which, per the fixtures, is *not* the first
    /// line of a session: a `system|session_state_changed` precedes it.
    case systemInit(sessionId: String)
    /// One whole `text` content block of assistant-authored output, decoded
    /// from an `assistant` frame — never a partial chunk. The `stream_event`
    /// frames that `--include-partial-messages` interleaves carry the same
    /// text again as token-level deltas (`basic-turn.jsonl`'s
    /// `content_block_delta` carries the `"ok"` its `assistant` frame then
    /// carries in full), and they are deliberately not decoded, so text is
    /// neither duplicated nor split across events.
    case assistantText(String)
    /// The assistant invoking a tool: its call id, the tool's name, and its
    /// input arguments as a raw JSON tree. Decoded from a `tool_use` content
    /// block inside an `assistant` frame. The name is passed through
    /// verbatim, including the `mcp__<server>__<tool>` namespacing the CLI
    /// applies, and including tools Wakil never configured — probe §4 saw a
    /// `ToolSearch` call the CLI makes on its own to load a deferred schema.
    case toolUse(id: String, name: String, input: JSONValue)
    /// The result of a tool call, matched back to its `toolUse` by id.
    /// Decoded from a `tool_result` content block inside a `user` frame.
    /// `content` is whatever the wire carried, undisturbed: probe §4 saw it
    /// arrive as a JSON *string* from an MCP server and as an array of
    /// `tool_reference` objects from `ToolSearch`, so it must not be assumed
    /// to be an object.
    ///
    /// `isError` is the block's own `is_error` flag, which probe §4 records
    /// the wire carrying only when the call failed — so absent means `false`,
    /// not "unknown". It is decoded because the refusal probe §6 observed
    /// (`is_error=True | Permission for this tool use was denied`) is the
    /// event that shows the write gate's second layer firing at the harness,
    /// and without this flag a refused or failed call is indistinguishable
    /// from a successful one, which spec §7's "a plain list of harness events
    /// with their status" cannot be built on.
    case toolResult(id: String, content: JSONValue, isError: Bool)
    /// The end of a turn: whether it ended in error, and any trailing
    /// summary text. Not the end of the *stream* — probe §3 found a
    /// `system|session_state_changed` after it in both fixtures.
    case result(isError: Bool, text: String?)
    /// A `rate_limit_event` whose `rate_limit_info.unifiedWindows` carried a
    /// usable 5-hour window. Every other field of the frame dies here. A frame
    /// without one stays `.unknown(type: "rate_limit_event")` — abstain, never
    /// guess (provider capacity spec).
    case rateLimit(CapacityWindows)
    /// A frame this decoder does not map. Carries the frame's own top-level
    /// `"type"` string verbatim, so a caller can at least see what arrived
    /// without the decoder having to throw over wire drift. The subtype is
    /// deliberately not folded in: every `system` frame other than `init`
    /// arrives as `.unknown(type: "system")`, whether it was a
    /// `session_state_changed` or a `status`.
    case unknown(type: String)
}

/// The only error `decodeHarnessEvents` throws.
public enum StreamJSONError: Error, Sendable, Equatable {
    /// A line was not a frame of this protocol at all — see
    /// `decodeHarnessEvents` for the exact three conditions. `index` is the
    /// line's zero-based position in the data as split on `\n`, counting
    /// blank lines (which are otherwise skipped).
    case malformedLine(index: Int)
}

/// Decodes newline-delimited stream-json into `HarnessEvent`s, in wire
/// order, built against the fixtures Task 1's live probe recorded
/// (`app/Fixtures/stream-json/`, documented in
/// `docs/wakil/phase-2a-probe.md`) rather than against assumed shapes.
///
/// One line does not mean one event. Per probe §4, tool calls are not their
/// own frame type: `tool_use` blocks arrive inside an `assistant` frame's
/// `message.content` array and `tool_result` blocks inside a `user` frame's,
/// so a single `assistant` line carrying text and two tool calls yields
/// three events. Both fixtures happen to carry exactly one block per frame,
/// but the fan-out is what makes the return type an array.
///
/// **What degrades and what throws.** An unrecognised `"type"`, and a
/// recognised one whose payload is not the shape expected (a `system|init`
/// with no `session_id`, an `assistant` with no decodable blocks), both
/// degrade to `.unknown(type:)` and never throw: stream-json is, per spec
/// §3.4, a weaker contract than an SDK's types, and wire drift must not be
/// able to kill a live session. Every well-formed line therefore yields at
/// least one event — nothing is silently swallowed.
///
/// Throwing is reserved for a line that is not a frame of this protocol at
/// all, which is exactly three conditions: it is not valid JSON; it is valid
/// JSON but not an object; or it is an object with no `"type"` key holding a
/// string. `StreamJSONError.malformedLine(index:)` names the line. Because
/// the throw abandons the whole call, events decoded from earlier lines in
/// the same `data` are lost with it — callers that need per-line resilience
/// (`ClaudeCodeCLIHarness` is one) must hand this one line at a time and
/// decide for themselves what a bad line means. Blank lines are skipped, not
/// malformed.
public func decodeHarnessEvents(_ data: Data) throws -> [HarnessEvent] {
    var events: [HarnessEvent] = []
    for (index, line) in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).enumerated() {
        guard line.contains(where: { !isASCIIWhitespace($0) }) else { continue }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
              case .object(let frame) = value,
              case .string(let type)? = frame["type"]
        else {
            throw StreamJSONError.malformedLine(index: index)
        }
        events.append(contentsOf: decodeFrame(type: type, frame: frame))
    }
    return events
}

private func isASCIIWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
        || byte == UInt8(ascii: "\r") || byte == 0x0B || byte == 0x0C
}

/// Maps one well-formed frame to the events it carries, guaranteeing at
/// least one so that no line can vanish: a frame whose type is known but
/// whose payload yields nothing falls back to `.unknown` with that type.
private func decodeFrame(type: String, frame: [String: JSONValue]) -> [HarnessEvent] {
    switch type {
    case "system":
        if case .string("init")? = frame["subtype"], case .string(let id)? = frame["session_id"] {
            return [.systemInit(sessionId: id)]
        }
    case "assistant", "user":
        let events = contentBlocks(of: frame).compactMap { decodeBlock($0, in: type) }
        if !events.isEmpty { return events }
    case "result":
        var isError = false
        if case .bool(let flag)? = frame["is_error"] { isError = flag }
        var text: String?
        if case .string(let value)? = frame["result"] { text = value }
        return [.result(isError: isError, text: text)]
    case "rate_limit_event":
        if let windows = decodeRateLimit(frame) { return [.rateLimit(windows)] }
    default:
        break
    }
    return [.unknown(type: type)]
}

/// The `message.content` array of an `assistant`/`user` frame, or empty if
/// the frame does not have one in that shape — the Anthropic message format
/// also permits `content` to be a bare string, which carries no block this
/// decoder has a case for.
private func contentBlocks(of frame: [String: JSONValue]) -> [JSONValue] {
    guard case .object(let message)? = frame["message"],
          case .array(let blocks)? = message["content"]
    else {
        return []
    }
    return blocks
}

/// One content block, decoded only if it is the kind its enclosing frame is
/// expected to carry: `tool_use`/`text` from an `assistant`, `tool_result`
/// from a `user`. A `text` block inside a `user` frame is the operator's own
/// prompt echoed back, not assistant output, so it is deliberately not
/// mapped to `.assistantText`.
private func decodeBlock(_ block: JSONValue, in frameType: String) -> HarnessEvent? {
    guard case .object(let fields) = block, case .string(let blockType)? = fields["type"] else {
        return nil
    }
    switch (frameType, blockType) {
    case ("assistant", "text"):
        guard case .string(let text)? = fields["text"] else { return nil }
        return .assistantText(text)
    case ("assistant", "tool_use"):
        guard case .string(let id)? = fields["id"],
              case .string(let name)? = fields["name"],
              let input = fields["input"]
        else {
            return nil
        }
        return .toolUse(id: id, name: name, input: input)
    case ("user", "tool_result"):
        guard case .string(let id)? = fields["tool_use_id"], let content = fields["content"] else {
            return nil
        }
        // Absent means the call did not fail — the wire only carries the flag
        // on failure (probe §4). Read the same way `result`'s `is_error` is
        // above: anything that is not a JSON `true` leaves this `false`.
        var isError = false
        if case .bool(let flag)? = fields["is_error"] { isError = flag }
        return .toolResult(id: id, content: content, isError: isError)
    default:
        return nil
    }
}

func decodeRateLimit(_ frame: [String: JSONValue]) -> CapacityWindows? {
    guard case .object(let info)? = frame["rate_limit_info"],
          case .object(let windows)? = info["unifiedWindows"],
          let five = capacityWindow(windows["five_hour"])
    else { return nil }
    return CapacityWindows(fiveHour: five, sevenDay: capacityWindow(windows["seven_day"]))
}

private func capacityWindow(_ value: JSONValue?) -> CapacityWindow? {
    guard case .object(let w)? = value else { return nil }
    let utilization: Double
    switch w["utilization"] {
    case .number(let d)?: utilization = d
    case .integer(let i)?: utilization = Double(i)
    default: return nil
    }
    let resets: Double
    switch w["resetsAt"] {
    case .integer(let i)?: resets = Double(i)
    case .number(let d)?: resets = d
    default: return nil
    }
    guard (0...1).contains(utilization), resets > 0 else { return nil }
    return CapacityWindow(percentLeft: Int(((1 - utilization) * 100).rounded()),
                          resetsAt: Date(timeIntervalSince1970: resets))
}
