import Foundation

// Workspaces, piece 2, part three (decision 13; spec, *Wakil drafts the recipe*, steps 2 and 3):
// when Detect cannot work out how a repo runs, a conversation in Main drafts the rest from the
// repo's docs, and when Try fails, the same conversation proposes a fix. Each answers through
// `running_draft_propose`, which saves nothing: the recipe lands in the Running settings as a
// proposal with Save / Discard (Rule 9). The window starts the conversations
// (`WindowModel.startRecipeDraft`); what is decided is here, where it is tested.

/// A repo's drafting, by the project file it belongs to and the repo's name.
public struct RecipeDraftKey: Hashable, Sendable {
    public var projectPath: String
    public var repo: String
    public init(projectPath: String, repo: String) {
        self.projectPath = projectPath
        self.repo = repo
    }
}

/// One repo's drafting conversation and what it last proposed.
public struct RecipeDraft: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// The conversation is drafting the recipe (Rule 5).
        case drafting
        /// Try failed at `failedAt`; the conversation is proposing a fix.
        case fixing(failedAt: String)
        /// Its proposal is in the form, unsaved.
        case proposed
        /// Nothing pending: the proposal was saved or discarded.
        case idle
        /// The conversation could not start, or ended its turn without a proposal — said whole.
        case failed(String)
    }

    public var key: RecipeDraftKey
    public var conversation: String
    public var title: String
    /// Detect's kind: the recipe's name when the conversation names none.
    public var kind: String
    public var phase: Phase
    public var proposal: RunningDetected?
    /// Whether the proposal answers a failed Try.
    public var isFix: Bool

    /// The line the form shows for this drafting; nil when there is nothing to say.
    public var line: String? {
        switch phase {
        case .drafting: "Drafting how \(key.repo) runs from its docs in ‘\(title)’, a conversation in Main…"
        case .fixing(let at): "Try failed at \(at). ‘\(title)’ is proposing a fix…"
        case .proposed, .idle: nil
        case .failed(let why): why
        }
    }

    public var inFlight: Bool {
        switch phase {
        case .drafting, .fixing: true
        default: false
        }
    }
}

/// Why a proposal was refused.
public struct RecipeDraftError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Every repo's drafting conversation, kept by the window for the app session.
public struct RecipeDraftBook: Sendable, Equatable {
    public private(set) var drafts: [RecipeDraftKey: RecipeDraft] = [:]

    public init() {}

    public func draft(_ key: RecipeDraftKey) -> RecipeDraft? { drafts[key] }

    public func key(ofConversation conversation: String) -> RecipeDraftKey? {
        drafts.first { $0.value.conversation == conversation }?.key
    }

    /// A conversation started drafting `key`'s recipe; one before it is forgotten.
    public mutating func begin(_ key: RecipeDraftKey, conversation: String, title: String, kind: String, fixing failedAt: String? = nil) {
        drafts[key] = RecipeDraft(
            key: key, conversation: conversation, title: title, kind: kind,
            phase: failedAt.map { .fixing(failedAt: $0) } ?? .drafting, proposal: nil, isFix: failedAt != nil)
    }

    /// Try failed: the same conversation is asked for a fix.
    public mutating func askFix(_ key: RecipeDraftKey, failedAt: String) {
        drafts[key]?.phase = .fixing(failedAt: failedAt)
        drafts[key]?.proposal = nil
        drafts[key]?.isFix = true
    }

    /// The conversation's answer. Only the conversation Wakil started for that repo proposes its
    /// recipe (decision 13): another agent, or the operator, is refused, naming the repo.
    public mutating func propose(conversation: String?, _ proposal: RunningDetected) throws -> RecipeDraftKey {
        guard let conversation,
              let key = drafts.values.first(where: { $0.conversation == conversation && $0.key.repo == proposal.repo })?.key else {
            throw RecipeDraftError(
                "running_draft_propose: only the conversation Wakil started to draft \(proposal.repo)'s recipe proposes it "
                    + "(decision 13: the operator saves what it proposes). Nothing was shown.")
        }
        var p = proposal
        if p.kind.isEmpty { p.kind = drafts[key]!.kind }
        drafts[key]?.proposal = p
        drafts[key]?.phase = .proposed
        return key
    }

    /// The proposal was saved or discarded; the conversation stays for a fix.
    public mutating func settle(_ key: RecipeDraftKey) {
        drafts[key]?.proposal = nil
        drafts[key]?.phase = .idle
    }

    public mutating func fail(_ key: RecipeDraftKey, _ why: String) {
        drafts[key]?.phase = .failed(why)
    }

    /// The conversation's turn ended: one still drafting or fixing proposed nothing, said whole.
    public mutating func turnEnded(conversation: String) {
        guard let key = key(ofConversation: conversation), let d = drafts[key], d.inFlight else { return }
        drafts[key]?.phase = .failed(
            "‘\(d.title)’ ended its turn without proposing a recipe for \(key.repo); its thread says why.")
    }

    /// The conversation ended (Stop, or closed): forgotten.
    public mutating func end(_ key: RecipeDraftKey) {
        drafts[key] = nil
    }
}

extension RunningDetected {
    public init(repo: String, kind: String = "", recipe: Recipe, doesntRun: Bool = false, why: String? = nil, questions: [String] = []) {
        self.repo = repo
        self.kind = kind
        self.recipe = recipe
        self.doesntRun = doesntRun
        self.why = why
        self.questions = questions
    }

    /// Detect could not work out how the repo runs on its own: it runs, and the draft asks
    /// something or starts no process. A conversation drafts the rest.
    public var needsDrafting: Bool {
        !doesntRun && (!questions.isEmpty || (recipe.processes ?? []).isEmpty)
    }
}

/// The drafting conversation's title.
public func recipeDraftTitle(_ repo: String) -> String { "Draft how \(repo) runs" }

private func compactJSON<T: Encodable>(_ v: T) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

/// How to answer, and the recipe's shape: said in both briefs.
private let recipeAnswer = """
Answer by calling running_draft_propose once with {"repo", "recipe", "questions"?, "recipeName"?} — \
or {"repo", "doesntRun": true, "why"} when it has nothing to run. The recipe's fields: needs, copy, \
clone, ports {VAR: "$WAKIL_PORT…"}, env {VAR: value}, services [command], setup [command], \
processes [{name, command}], build "command", ready {url} or {output} with timeoutSeconds, \
teardown [command], and notes {field: where it came from}. Nothing is saved: the operator reads \
your draft in the Running settings and saves it or not.
"""

/// The rules every draft follows (spec, step 2).
private let recipeRules = """
Rules: every port goes through $WAKIL_PORT (and $WAKIL_PORT_1 … $WAKIL_PORT_9), never a fixed one — \
the workspace runs beside others; the repo's own scripts (Makefile, justfile, Taskfile, Procfile, \
bin/dev, scripts/) come before any guess; databases, queues and caches go in services, started \
once per workspace before the app. Change nothing: you are in Main, reading only — a write would \
make a workspace.
"""

/// The drafting conversation's first message: the detected facts whole, the docs to read, the
/// rules and how to answer.
public func recipeDraftingBrief(repo: String, root: String, detected: JSONValue) -> String {
    """
    \(recipeDraftTitle(repo)), for the Running settings. Wakil detected what it could from the files \
    in \(root), without a model, and could not work out the rest:

    \(compactJSON(detected))

    Read the repo's README, CONTRIBUTING and docs/ (and its scripts) to draft the rest: the questions \
    above, and every process the app needs to serve.

    \(recipeRules)

    \(recipeAnswer)
    """
}

/// Where a failed Try stopped: its first failing step, or the ready check.
public func recipeTryFailedAt(_ report: RunTryResult) -> String {
    if let s = report.steps.first(where: { !$0.ok }) {
        return s.command.isEmpty ? s.phase : "\(s.phase) `\(s.command)`"
    }
    if let r = report.ready, !r.ready { return "ready: \(r.detail)" }
    return "an unknown step"
}

/// The message that asks the drafting conversation for a fix: each step, the failing one's output
/// whole (Rule 8), the ready check, and the recipe as tried.
public func recipeFixBrief(repo: String, recipe: Recipe, report: RunTryResult) -> String {
    var steps: [String] = []
    for s in report.steps {
        let what = "\(s.ok ? "✓" : "✗") \(s.phase)\(s.name.isEmpty ? "" : " \(s.name)")\(s.command.isEmpty ? "" : " — \(s.command)")"
        if s.ok {
            steps.append(what)
        } else {
            let out = s.output.trimmingCharacters(in: .whitespacesAndNewlines)
            steps.append(what + " (exit \(s.exitCode))" + (s.detail.isEmpty ? "" : ": \(s.detail)") + (out.isEmpty ? "" : "\n\(out)"))
        }
    }
    if let r = report.ready { steps.append("\(r.ready ? "✓" : "✗") ready — \(r.detail)") }
    return """
    Try of \(repo)'s recipe failed at \(recipeTryFailedAt(report)), in a throwaway workspace. Each step:

    \(steps.joined(separator: "\n"))

    The recipe as tried:

    \(compactJSON(recipe))

    Propose a fix: the whole corrected recipe. If what failed is out of the recipe's reach (a tool \
    missing on this machine, a credential), say why in questions.

    \(recipeRules)

    \(recipeAnswer)
    """
}

extension RunningSettings {
    /// The `running_save` params that keep a drafted (or fixed) recipe for `repo`. A repo on a
    /// shared recipe keeps only what differs, as its own overrides — a fix for one repo never
    /// changes the others; a repo with none gets a new recipe as Detect's draft does.
    public func savingDraft(_ d: RunningDetected, of repo: String) -> JSONValue {
        guard !d.doesntRun, let row = self.repo(repo), let name = row.recipeName, let shared = recipes[name] else {
            return d.saving(existing: recipes)
        }
        var own = Recipe()
        for f in RecipeField.allCases where f.text(in: d.recipe) != f.text(in: shared) || (f == .ready && d.recipe.ready != shared.ready) {
            if f == .ready { own.ready = d.recipe.ready } else { own = f.set(f.text(in: d.recipe), in: own) }
            if let note = d.recipe.notes?[f.rawValue] { own.notes = (own.notes ?? [:]).merging([f.rawValue: note]) { $1 } }
        }
        let env = (d.recipe.env ?? [:]).filter { shared.env?[$0.key] != $0.value }
        if !env.isEmpty { own.env = env }
        if let w = d.recipe.alsoWriteEnvFile, w != (shared.alsoWriteEnvFile ?? false) { own.alsoWriteEnvFile = w }
        var entry: [String: JSONValue] = ["recipe": .string(name)]
        if own != Recipe(), let o = try? encodeRecipe(own) { entry["overrides"] = o }
        return .object(["repos": .object([repo: .object(entry)])])
    }
}

// MARK: the action

/// Where `running_draft_propose` hands a proposal: the window's book (`WindowModel.receiveRecipeDraft`).
public final class RecipeDraftLookup: @unchecked Sendable {
    public typealias Propose = @Sendable (_ conversation: String?, _ proposal: RunningDetected) async throws -> Void
    private let lock = NSLock()
    private var source: Propose?

    public init() {}

    public func use(_ propose: @escaping Propose) {
        lock.withLock { source = propose }
    }

    func propose(_ conversation: String?, _ proposal: RunningDetected) async throws {
        guard let s = lock.withLock({ source }) else { throw RecipeDraftError("running_draft_propose: no window is open to show the draft in") }
        try await s(conversation, proposal)
    }
}

/// `running_draft_propose`: the drafting conversation's answer. Agent-reachable, and `.control`:
/// it writes nothing outside Wakil — the draft shows in the Running settings, unsaved (Rule 9).
public func registerRecipeDraftActions(into registry: ActionRegistry, drafts: RecipeDraftLookup) async {
    let str: JSONValue = .object(["type": .string("string")])
    await registry.register(Action(
        name: "running_draft_propose",
        description: "Propose a repo's recipe in the operator's Running settings, when Wakil asked you to draft it or to fix "
            + "it after a failed Try (decision 13). Nothing is saved: the operator saves it or discards it. Only the "
            + "conversation Wakil started for that repo may call it. recipe is the whole recipe (processes, setup, "
            + "services, ports, env, ready, build, teardown, notes); doesntRun with why when the repo has nothing to run.",
        kind: .control, audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([
            "repo": str, "recipe": .object(["type": .string("object")]), "recipeName": str, "why": str,
            "doesntRun": .object(["type": .string("boolean")]),
            "questions": .object(["type": .string("array"), "items": str]),
        ]), "required": .array([.string("repo")])]),
        handler: { params in
            let repo = try runParam(params, "repo", action: "running_draft_propose")
            var o: [String: JSONValue] = [:]
            if case .object(let p) = params { o = p }
            if let name = o["recipeName"] { o["kind"] = name }
            let proposal: RunningDetected
            do {
                proposal = try JSONDecoder().decode(RunningDetected.self, from: JSONEncoder().encode(JSONValue.object(o)))
            } catch {
                throw RecipeDraftError("running_draft_propose: the recipe is not one Wakil reads (\(error)).")
            }
            let conversation = ActionRegistry.dispatchOrigin == .agent ? ActionRegistry.dispatchCaller?.conversation : nil
            try await drafts.propose(conversation, proposal)
            return .object([
                "repo": .string(repo),
                "text": .string("Your draft for \(repo) is in the operator's Running settings; nothing is saved until they save it."),
            ])
        }))
}
