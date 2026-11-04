import Foundation

/// A workspace's branch name drafted by a quick task (decision 10): the ✨ commit draft's path
/// (Decision 42), from the Branches instructions (organisation, then project), the ticket's key and
/// title or the conversation's first message, and the repo's recent branch names. When there are no
/// instructions, or the draft fails or is slow, the caller falls back to `fallbackBranchName`.
public enum BranchDraft {
    /// The longest a draft is waited for before the fallback is used.
    public static let patience: Duration = .seconds(4)

    public static func request(_ r: BranchNameRequest, instructions: String, recent: [String] = []) -> RespondRequest {
        var text = """
            Name a git branch for the piece of work below: lower case unless the rules say otherwise, words \
            joined by "-", no spaces, under 50 characters, valid for `git check-ref-format --branch`. \
            Answer as JSON: {"branch": "..."}.
            """
        let rules = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rules.isEmpty { text += "\n\nFollow these branch naming rules:\n" + rules }
        let names = recent.prefix(10)
        if !names.isEmpty { text += "\n\nThis repository's recent branches:\n" + names.joined(separator: "\n") }
        var input = ""
        if let key = r.key, !key.isEmpty { input += "Ticket: \(key)\n" }
        input += "Title: \(r.title)"
        if let first = r.firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty, first != r.title {
            input += "\n\nFirst message:\n" + String(first.prefix(2_000))
        }
        return RespondRequest(instructions: text, input: input, jsonSchema: nil, maxTokens: 60)
    }

    /// The branch from the model's reply, made safe for git; throws when there is none.
    public static func parse(_ reply: String) throws -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n").replacingOccurrences(of: "```", with: "")
        }
        guard let data = text.data(using: .utf8),
              case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .string(let raw)? = o["branch"], let name = NormalisedBranch(raw)
        else { throw WorkspaceWriteError(description: "the model's reply was not a branch name: \(reply)") }
        return name
    }
}
