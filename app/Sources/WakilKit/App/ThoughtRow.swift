import Foundation

/// One line of the thought thread: what the agent did, and whether it
/// failed. Spec §7 asks for exactly this and no more — "a plain list of
/// harness events with their status"; §9's rising-from-the-Core treatment is
/// 2b's.
public struct ThoughtRow: Identifiable, Sendable, Equatable {
    public let id: Int
    /// A short kind name (`assistant`, `tool`, `result`, …), drawn as plain
    /// text beside the detail.
    public let label: String
    public let detail: String
    /// True when this event *is* a failure — a tool call the agent was
    /// refused or that errored, or a turn that ended in error. Nothing here
    /// colours it; the view draws the word, per Task 11's "no colours".
    public let isError: Bool

    public init(id: Int, label: String, detail: String, isError: Bool) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isError = isError
    }

    /// The agent's note that a page's text came from the site. The thread draws
    /// it amber so the operator sees which lines carry untrusted text.
    public var isUntrustedNotice: Bool {
        label == "browser" && detail.hasPrefix("1 page · untrusted text from ")
    }
}

/// The `thread` line of a browser action's reply, or nil when the tool result
/// is not one. `content` is a string or an array of `{type: text, text}`; the
/// text is a JSON object whose `thread` is a string.
public func threadLine(fromToolResult content: JSONValue) -> String? {
    var texts: [String] = []
    switch content {
    case .string(let s):
        texts = [s]
    case .array(let items):
        for item in items {
            if case .object(let o) = item, case .string("text")? = o["type"], case .string(let t)? = o["text"] {
                texts.append(t)
            }
        }
    default:
        return nil
    }
    for text in texts {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let o) = value, case .string(let line)? = o["thread"] else { continue }
        return line
    }
    return nil
}

/// Projects one `HarnessEvent` into a thought-thread row, or into nothing.
///
/// **`.unknown` yields `nil`, and that changed in 2b-ii** (spec §7.1). 2a
/// drew every case, because §7 asked for a plain list of harness events and
/// a list can carry noise. §9's thread rises out of the Core and holds
/// perhaps six lines; the probe measured 10 of a turn's 13 events as
/// `.unknown`, so drawing them buries the lines that describe work under
/// the ones that do not.
public func thoughtRow(id: Int, for event: HarnessEvent) -> ThoughtRow? {
    switch event {
    case .systemInit(let sessionId):
        return ThoughtRow(id: id, label: "session", detail: sessionId, isError: false)
    case .assistantText(let text):
        return ThoughtRow(id: id, label: "assistant", detail: text, isError: false)
    case .toolUse(_, let name, let input):
        // The name keeps the CLI's `mcp__<server>__<tool>` prefix verbatim
        // (probe §4), because that is what was actually called — including
        // for tools Wakil never configured, which the CLI loads on its own.
        return ThoughtRow(id: id, label: "tool", detail: "\(name) \(PaneCell(input).text)", isError: false)
    case .toolResult(_, let content, let isError):
        if let line = threadLine(fromToolResult: content) {
            return ThoughtRow(id: id, label: "browser", detail: line, isError: isError)
        }
        return ThoughtRow(id: id, label: "tool result", detail: PaneCell(content).text, isError: isError)
    case .result(let isError, let text):
        return ThoughtRow(id: id, label: "turn", detail: text ?? "", isError: isError)
    case .unknown, .rateLimit:
        return nil
    }
}
