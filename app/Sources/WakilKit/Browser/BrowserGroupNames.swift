import Foundation

/// 3d-i, ruling 12: naming an automatic browser group with the `respond` quick task (Decision 42), so
/// a prompt and a parser and nothing more. The model sees the tabs' titles, never their URLs. Which
/// groups are due, what is sent and how the reply is read are pure; the window asks, and applies the
/// name only if the group is still automatic and unnamed.
public enum BrowserGroupNames {
    public static let replySchema = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#

    /// The ids of the groups to ask about: automatic, not yet `named`, with at least two titled tabs.
    public static func due(_ s: BrowserSnapshot) -> [String] {
        s.groups.filter { $0.kind == .automatic && !$0.named && titles(of: $0.id, in: s).count >= 2 }.map(\.id)
    }

    /// Up to five non-empty names of the group's tabs, in the order they were opened (`t<n>` ascending).
    /// A tab's operator-given name is sent where it has one, else its page title.
    public static func titles(of group: String, in s: BrowserSnapshot) -> [String] {
        let members = s.tabs.filter { $0.group == group }.sorted { number($0.id) < number($1.id) }
        let titled = members.map { tab -> String in
            let name = tab.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? tab.title.trimmingCharacters(in: .whitespacesAndNewlines) : name
        }.filter { !$0.isEmpty }
        return Array(titled.prefix(5))
    }

    private static func number(_ id: String) -> Int { Int(id.dropFirst()) ?? Int.max }

    public static func request(titles: [String]) -> RespondRequest {
        RespondRequest(
            instructions: """
                Name this group of browser tabs from their titles. Answer with at most three words \
                and no punctuation, as JSON: {"name": "..."}.
                """,
            input: titles.joined(separator: "\n"), jsonSchema: replySchema, maxTokens: 20)
    }

    /// The reply's `name`: quotes and punctuation dropped, the first three words kept. A reply in a
    /// code fence is read inside it. A reply that is not a name throws `invalidReply`, whole.
    public static func parse(_ reply: String) throws -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n").replacingOccurrences(of: "```", with: "")
        }
        let invalid = QuickModelError.invalidReply("the model's reply was not a group name: \(reply)")
        guard let data = text.data(using: .utf8),
              case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .string(let raw)? = o["name"] else { throw invalid }
        let bare = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet(charactersIn: "\"'“”‘’`").contains($0)
        }))
        let words = bare.split(whereSeparator: \.isWhitespace).prefix(3)
        guard !words.isEmpty else { throw invalid }
        return words.joined(separator: " ")
    }
}
