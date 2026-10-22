import Foundation

/// The commit box's ✨ (3a-ii-b): a quick task (Decision 42), so a prompt and a parser over
/// `QuickTasks.respond` and nothing more. It reads what the Commit button would commit — the staged
/// diff, or every change and the untracked files' names for Commit All — and answers one message the
/// operator edits and commits. It never commits.
public enum CommitDraft {
    /// The most diff lines the model reads; past it every file is still named by its stat line.
    public static let lineCap = 1_500
    public static let replySchema = #"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}"#

    /// `diff` is `git_diff`'s text for the whole root; `truncated` says git_diff cut it already.
    /// `files` are the paths git status puts in the commit (final review I5): each is named, with its
    /// counts where the diff reached it, so none is lost to a cut or an empty diff.
    /// `examples` are the root's messages committed from Wakil, newest first; at most five are used.
    public static func request(diff: String, truncated: Bool, files: [String], untracked: [String],
                               examples: [String], commitInstructions: String = "") -> RespondRequest {
        var instructions = """
            Write a git commit message for the change below. A subject line in the imperative mood, under \
            72 characters; then, only if the change needs explaining, a blank line and a short body. \
            Describe what changed and why, not which files. Answer as JSON: {"message": "..."}.
            """
        // 3a-iii-b: the organisation's and the project's commit rules, as the operator wrote them.
        let rules = commitInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rules.isEmpty { instructions += "\n\nFollow these commit rules:\n" + rules }
        let style = examples.prefix(5)
        if !style.isEmpty {
            instructions += "\n\nMatch the style of this repository's recent messages:\n"
                + style.map { "---\n\($0)" }.joined(separator: "\n")
        }
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.last == "" ? lines.dropLast() : lines[...]
        let cut = truncated || body.count > lineCap
        var listed = stats(diff)
        for f in files where !listed.contains(where: { $0.hasPrefix(f + " ") || $0.contains("→ \(f) ") }) {
            listed.append(f)
        }
        var input = "Files:\n" + listed.joined(separator: "\n")
        if !untracked.isEmpty {
            input += "\n\nNew files (contents not shown):\n" + untracked.joined(separator: "\n")
        }
        input += "\n\nDiff:\n" + body.prefix(lineCap).joined(separator: "\n")
        if cut { input += "\n(The diff was cut at \(lineCap.formatted(.number.locale(Locale(identifier: "en_US")))) lines; every file is listed above.)" }
        return RespondRequest(instructions: instructions, input: input, jsonSchema: replySchema, maxTokens: 300)
    }

    /// One `path +a −d` line per file of a unified diff; a binary file is `path binary`, a rename
    /// `old → new`.
    static func stats(_ diff: String) -> [String] {
        var out: [String] = []
        var name = "", from: String?, to: String?, added = 0, removed = 0, binary = false, open = false
        func flush() {
            guard open else { return }
            let shown = from.flatMap { f in to.map { "\(f) → \($0)" } } ?? name
            out.append(binary ? "\(shown) binary" : "\(shown) +\(added) −\(removed)")
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                open = true
                added = 0; removed = 0; binary = false; from = nil; to = nil
                // "diff --git a/x b/y": the b side names the file now.
                if let r = line.range(of: " b/", options: .backwards) { name = String(line[r.upperBound...]) }
            } else if line.hasPrefix("rename from ") {
                from = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                to = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files ") {
                binary = true
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                removed += 1
            }
        }
        flush()
        return out
    }

    /// The reply's `message`, trimmed. A reply in a code fence is read inside it.
    public static func parse(_ reply: String) throws -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n").replacingOccurrences(of: "```", with: "")
        }
        guard let data = text.data(using: .utf8),
              case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw QuickModelError.invalidReply("the model's reply was not a message: \(reply)")
        }
        guard case .string(let m)? = o["message"] else { throw QuickModelError.failed("the model returned no message") }
        let message = m.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw QuickModelError.failed("the model returned no message") }
        return message
    }
}

/// Where `editor_changes_draft_message` reaches the window (3a-ii-b, ruling R2): actions are registered
/// before any window exists, so the window binds its draft here when its session starts.
public actor CommitDraftSink {
    private var draft: (@Sendable (String) async throws -> String)?
    public init() {}
    public func bind(_ f: (@Sendable (String) async throws -> String)?) { draft = f }
    func run(root: String) async throws -> String {
        guard let draft else { throw QuickModelError.noProvider(.respond) }
        return try await draft(root)
    }
}

/// `editor_changes_draft_message`: fills a root's commit box with a drafted message and answers it.
/// Kind `.control` — it changes Wakil's own box and nothing outside Wakil.
func registerCommitDraftAction(into registry: ActionRegistry, drafts: CommitDraftSink) async {
    await registry.register(Action(
        name: "editor_changes_draft_message",
        description: "Draft a commit message for one root (absolute) with the organisation's quick model, from what "
            + "Commit would commit (the staged changes, else every change). The draft fills the root's commit box for the "
            + "operator to edit and commit; this never commits. Answers message.",
        kind: .control, audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object(["root": .object(["type": .string("string")])]),
                         "required": .array([.string("root")])]),
        handler: { params in
            guard let root = optionalString(params, "root") else {
                throw StandardActionError.missingParam(action: "editor_changes_draft_message", param: "root")
            }
            return .object(["message": .string(try await drafts.run(root: root))])
        }))
}
