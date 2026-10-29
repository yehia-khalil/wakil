import Foundation

/// The names phase's quick task (spec, "Calls made for the operator" item 5): the prompt that names a
/// conversation from its first message and the start of its first reply, and the parser that reads the
/// answer. A prompt and a parser over `QuickModel.respond`, as `CommitDraft` is; it never sees a tool
/// call, a result, a pane or a file path.
public enum ConversationNames {
    /// The operator's first message, cut to its first characters before it is sent.
    public static let messageLimit = 1_000
    /// The agent's first reply, cut to its first characters before it is sent.
    public static let replyLimit = 600
    /// The longest name the parser keeps, in characters, once whole words are joined.
    static let nameLimit = 48
    /// The most words a name keeps.
    static let wordLimit = 5
    public static let replySchema = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#

    static let instructions = "Name this conversation from its opening message and the start of the reply. "
        + #"Answer with at most five words, no quotes, as JSON: {"name": "..."}."#

    /// `firstMessage` is the operator's first message as typed; `replyStart` is the agent's text of the
    /// first turn, joined. Each is cut to its limit, and `REPLY:` is sent empty when there is no reply yet.
    public static func request(firstMessage: String, replyStart: String) -> RespondRequest {
        let message = String(firstMessage.prefix(messageLimit))
        let reply = String(replyStart.prefix(replyLimit))
        return RespondRequest(instructions: instructions,
                              input: "MESSAGE: " + message + "\n\nREPLY: " + reply,
                              jsonSchema: replySchema, maxTokens: 24)
    }

    /// The name in the model's reply. A reply in a code fence is read inside it. What is left after the
    /// cleanup is cut to five words and then to whole words within 48 characters; a single first word
    /// longer than 48 is kept and cut to 48. A reply that leaves no name throws `invalidReply` with the
    /// whole reply.
    public static func parse(_ reply: String) throws -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n").replacingOccurrences(of: "```", with: "")
        }
        guard let data = text.data(using: .utf8),
              case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .string(let raw)? = o["name"] else {
            throw notAName(reply)
        }
        let name = cleaned(raw)
        guard !name.isEmpty else { throw notAName(reply) }
        return name
    }

    private static let quotes: Set<Character> = ["\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "`"]
    private static let trailing: Set<Character> = [".", "!", "?", ":", ";", ","]

    /// Drops surrounding quotes and trailing punctuation until stable, collapses whitespace, then keeps
    /// the first five words and the whole words that fit in 48 characters.
    private static func cleaned(_ raw: String) -> String {
        var s = raw
        while true {
            let before = s
            s = String(s.drop(while: { quotes.contains($0) || $0.isWhitespace }))
            while let last = s.last, quotes.contains(last) || trailing.contains(last) || last.isWhitespace {
                s.removeLast()
            }
            if s == before { break }
        }
        let words = s.split(whereSeparator: { $0.isWhitespace }).prefix(wordLimit)
        var kept = ""
        for word in words {
            let candidate = kept.isEmpty ? String(word) : kept + " " + word
            if candidate.count > nameLimit {
                if kept.isEmpty { kept = String(word.prefix(nameLimit)) }
                break
            }
            kept = candidate
        }
        return kept
    }

    private static func notAName(_ reply: String) -> QuickModelError {
        .invalidReply("the model's reply was not a conversation name: \(reply)")
    }
}
