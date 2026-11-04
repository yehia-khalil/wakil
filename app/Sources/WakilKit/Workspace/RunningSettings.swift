import Foundation

// Workspaces, piece 2: a project's Running settings (decisions 13–15; mockup settings.html) —
// what the form decides, kept here because WakilApp has no tests. The list groups every repo by
// the recipe it uses; a repo's form shows each field with where it came from (the recipe's, grey;
// the repo's own, violet); an edit there becomes the repo's override.

/// An env value: plain, or a secret kept in the Keychain by its ref.
public enum RecipeEnvValue: Codable, Sendable, Equatable {
    case value(String)
    case secret(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .value(s); return }
        struct Secret: Codable { var secret: String }
        self = .secret(try c.decode(Secret.self).secret)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .value(let s): try c.encode(s)
        case .secret(let ref): try c.encode(["secret": ref])
        }
    }

    public var isSecret: Bool { if case .secret = self { true } else { false } }
}

public struct RecipeProcess: Codable, Sendable, Equatable {
    public var name: String
    public var command: String
    /// Starts only once the ready check passed (a queue worker that needs the app up); nil is false.
    public var afterReady: Bool?
    public init(name: String, command: String, afterReady: Bool = false) {
        self.name = name
        self.command = command
        self.afterReady = afterReady ? true : nil
    }
}

/// How the Processes box marks a process that starts once the app is ready.
let afterReadyMark = " (after ready)"

public struct RecipeReady: Codable, Sendable, Equatable {
    public var url: String?
    public var output: String?
    public var timeoutSeconds: Int?
    public init(url: String? = nil, output: String? = nil, timeoutSeconds: Int? = nil) {
        self.url = url
        self.output = output
        self.timeoutSeconds = timeoutSeconds
    }
}

/// A recipe as `project.json` keeps it (Go's `wakilcore.Recipe`). A repo's overrides are a recipe
/// whose absent (nil) fields inherit; an empty list is "none, here".
public struct Recipe: Codable, Sendable, Equatable {
    public var needs: [String]?
    public var ports: [String: String]?
    public var env: [String: RecipeEnvValue]?
    public var alsoWriteEnvFile: Bool?
    public var copy: [String]?
    public var clone: [String]?
    public var services: [String]?
    public var setup: [String]?
    public var processes: [RecipeProcess]?
    public var build: String?
    public var ready: RecipeReady?
    public var teardown: [String]?
    public var `in`: String?
    public var notes: [String: String]?

    public init() {}

    /// A recipe with only services (and teardown, `in`): run once per workspace for the repos
    /// that need it.
    public var isSharedService: Bool {
        !(services ?? []).isEmpty && (processes ?? []).isEmpty && (setup ?? []).isEmpty && build == nil && ready == nil
    }
}

/// One repo's row of the Running settings.
public struct RunningRepo: Decodable, Sendable, Equatable {
    public struct Effective: Decodable, Sendable, Equatable {
        public var recipeName: String?
        public var doesntRun: Bool?
        public var recipe: Recipe
        public var from: [String: String]?
    }
    public var repo: String
    public var path: String
    public var recipe: String?
    public var doesntRun: Bool?
    public var overrides: Recipe?
    public var effective: Effective?

    public var doesNotRun: Bool { doesntRun ?? false }
    public var recipeName: String? { recipe.flatMap { $0.isEmpty ? nil : $0 } }
}

/// `running_read`'s answer.
public struct RunningSettings: Decodable, Sendable, Equatable {
    public var project: String
    public var recipes: [String: Recipe]
    public var repos: [RunningRepo]
    public var problems: [String]

    public init(project: String, recipes: [String: Recipe] = [:], repos: [RunningRepo] = [], problems: [String] = []) {
        self.project = project
        self.recipes = recipes
        self.repos = repos
        self.problems = problems
    }

    public static func decode(_ value: JSONValue) throws -> RunningSettings { try decodeRun(RunningSettings.self, value) }

    /// One group of the list, in the order the mockup draws them.
    public struct Group: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case sharedServices, recipe(String), noRecipe }
        public var kind: Kind
        public var title: String
        public var repos: [String]
        public var id: String { title }
    }

    /// Shared services first, then each recipe with the repos that name it, then the repos with
    /// none (or marked doesn't run). A group with no repos is still listed when it is a recipe.
    public var groups: [Group] {
        var out: [Group] = []
        let services = recipes.filter { $0.value.isSharedService }.keys.sorted()
        if !services.isEmpty { out.append(Group(kind: .sharedServices, title: "Shared services", repos: services)) }
        for name in recipes.keys.sorted() where !(recipes[name]?.isSharedService ?? false) {
            out.append(Group(kind: .recipe(name), title: "Recipe · \(name)",
                             repos: repos.filter { $0.recipeName == name && !$0.doesNotRun }.map(\.repo)))
        }
        let none = repos.filter { $0.doesNotRun || $0.recipeName == nil || recipes[$0.recipeName!] == nil }.map(\.repo)
        if !none.isEmpty { out.append(Group(kind: .noRecipe, title: "No recipe", repos: none)) }
        return out
    }

    public func repo(_ name: String) -> RunningRepo? { repos.first { $0.repo == name } }
}

// MARK: the form's fields

/// A field of the form, as one editable text: lists one item a line, maps `KEY=value` a line,
/// processes `name: command` a line, ready a URL or an output line.
public enum RecipeField: String, CaseIterable, Sendable {
    case needs, copy, clone, ports, services, setup, processes, build, ready, teardown

    public var label: String {
        switch self {
        case .needs: "Needs"
        case .copy: "Copy"
        case .clone: "Clone"
        case .ports: "Port mapping"
        case .services: "Services"
        case .setup: "Setup"
        case .processes: "Processes"
        case .build: "Build"
        case .ready: "Ready when"
        case .teardown: "Teardown"
        }
    }

    public var hint: String {
        switch self {
        case .needs: "Other repos or shared services started first, one a line."
        case .copy: "Ignored files copied from your folder, one glob a line (default .env*)."
        case .clone: "Heavy ignored folders cloned copy-on-write, one a line."
        case .ports: "VARIABLE=$WAKIL_PORT… a line, so the repo's own files are not rewritten."
        case .services: "Started once per workspace before the app, one command a line."
        case .setup: "Run once in a new copy, one command a line."
        case .processes: "name: command, one a line; each runs in its own terminal."
        case .build: "One command."
        case .ready: "A URL that answers, or a line the output shows (/a regexp/ too)."
        case .teardown: "Run when services stop or the workspace is archived."
        }
    }

    /// Whether the recipe (or overrides) sets this field at all.
    public func isSet(in r: Recipe) -> Bool {
        switch self {
        case .needs: r.needs != nil
        case .copy: r.copy != nil
        case .clone: r.clone != nil
        case .ports: r.ports != nil
        case .services: r.services != nil
        case .setup: r.setup != nil
        case .processes: r.processes != nil
        case .build: r.build != nil
        case .ready: r.ready != nil
        case .teardown: r.teardown != nil
        }
    }

    public func text(in r: Recipe) -> String {
        switch self {
        case .needs: (r.needs ?? []).joined(separator: "\n")
        case .copy: (r.copy ?? []).joined(separator: "\n")
        case .clone: (r.clone ?? []).joined(separator: "\n")
        case .services: (r.services ?? []).joined(separator: "\n")
        case .setup: (r.setup ?? []).joined(separator: "\n")
        case .teardown: (r.teardown ?? []).joined(separator: "\n")
        case .ports: (r.ports ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        case .processes: (r.processes ?? []).map { "\($0.name): \($0.command)\($0.afterReady == true ? afterReadyMark : "")" }.joined(separator: "\n")
        case .build: r.build ?? ""
        case .ready: r.ready?.url ?? r.ready?.output ?? ""
        }
    }

    /// `r` with this field set from `text`; an empty text sets "none, here" (an empty list, no
    /// build), never a refusal (Rule 7). A process line without a name is named `app`, `app-2`…
    public func set(_ text: String, in r: Recipe) -> Recipe {
        var r = r
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch self {
        case .needs: r.needs = lines
        case .copy: r.copy = lines
        case .clone: r.clone = lines
        case .services: r.services = lines
        case .setup: r.setup = lines
        case .teardown: r.teardown = lines
        case .ports:
            var m: [String: String] = [:]
            for l in lines {
                let parts = l.contains("=") ? l.split(separator: "=", maxSplits: 1) : l.split(separator: "→", maxSplits: 1)
                guard parts.count == 2 else { continue }
                m[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            r.ports = m
        case .processes:
            var out: [RecipeProcess] = []
            for var l in lines {
                let late = l.hasSuffix(afterReadyMark)
                if late { l = String(l.dropLast(afterReadyMark.count)).trimmingCharacters(in: .whitespaces) }
                defer { if late, !out.isEmpty { out[out.count - 1].afterReady = true } }
                if let colon = l.firstIndex(of: ":"), !l[..<colon].contains(" "), !l[..<colon].isEmpty {
                    out.append(RecipeProcess(name: String(l[..<colon]), command: l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                } else if let gap = l.range(of: "  "), !l[..<gap.lowerBound].isEmpty, !l[..<gap.lowerBound].contains(" "),
                          !l[gap.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                    // The form draws a process as `name  command`, its names aligned (formText).
                    out.append(RecipeProcess(name: String(l[..<gap.lowerBound]), command: l[gap.upperBound...].trimmingCharacters(in: .whitespaces)))
                } else {
                    var name = "app"
                    var n = 2
                    while out.contains(where: { $0.name == name }) { name = "app-\(n)"; n += 1 }
                    out.append(RecipeProcess(name: name, command: l))
                }
            }
            r.processes = out
        case .build:
            r.build = lines.joined(separator: " && ")
        case .ready:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { r.ready = nil } else if t.hasPrefix("http://") || t.hasPrefix("https://") {
                r.ready = RecipeReady(url: t, timeoutSeconds: r.ready?.timeoutSeconds)
            } else {
                r.ready = RecipeReady(output: t, timeoutSeconds: r.ready?.timeoutSeconds)
            }
        }
        return r
    }

    /// The same field cleared, so it inherits the recipe's again.
    public func clear(in r: Recipe) -> Recipe {
        var r = r
        switch self {
        case .needs: r.needs = nil
        case .copy: r.copy = nil
        case .clone: r.clone = nil
        case .ports: r.ports = nil
        case .services: r.services = nil
        case .setup: r.setup = nil
        case .processes: r.processes = nil
        case .build: r.build = nil
        case .ready: r.ready = nil
        case .teardown: r.teardown = nil
        }
        return r
    }
}

/// Where a field of a repo's form comes from.
public enum FieldSource: Sendable, Equatable {
    /// The shared recipe's (grey).
    case recipe
    /// This repo's own override (violet).
    case repo
    /// Set nowhere.
    case none

    public var label: String {
        switch self {
        case .recipe: "recipe"
        case .repo: "this repo only"
        case .none: ""
        }
    }
}

extension RunningSettings {
    /// The field of `repo`'s form: its text as it runs, and where it came from.
    public func field(_ f: RecipeField, of repo: String) -> (text: String, source: FieldSource, note: String?) {
        guard let row = self.repo(repo) else { return ("", .none, nil) }
        let own = row.overrides ?? Recipe()
        let shared = row.recipeName.flatMap { recipes[$0] } ?? Recipe()
        let note = own.notes?[f.rawValue] ?? shared.notes?[f.rawValue]
        if f.isSet(in: own) { return (f.text(in: own), .repo, note) }
        if f.isSet(in: shared) { return (f.text(in: shared), .recipe, note) }
        return ("", .none, note)
    }

    /// The env rows of `repo` as it runs: each variable, its value (a secret never has one), and
    /// where it came from.
    public func env(of repo: String) -> [(name: String, value: RecipeEnvValue, source: FieldSource)] {
        guard let row = self.repo(repo) else { return [] }
        let own = row.overrides?.env ?? [:]
        let shared = row.recipeName.flatMap { recipes[$0]?.env } ?? [:]
        return Set(own.keys).union(shared.keys).sorted().map { k in
            own[k].map { (k, $0, FieldSource.repo) } ?? (k, shared[k]!, FieldSource.recipe)
        }
    }

    /// The `running_save` params that make `text` this repo's own value of `f`; when `text` is
    /// what the recipe already says, the override is cleared instead (it inherits again).
    public func savingField(_ f: RecipeField, _ text: String, of repo: String) -> JSONValue? {
        guard let row = self.repo(repo) else { return nil }
        let shared = row.recipeName.flatMap { recipes[$0] } ?? Recipe()
        var own = row.overrides ?? Recipe()
        let normalised = f.text(in: f.set(text, in: Recipe()))
        if row.recipeName != nil, f.isSet(in: shared), f.text(in: shared) == normalised {
            own = f.clear(in: own)
        } else if row.recipeName != nil, !f.isSet(in: shared), normalised.isEmpty {
            own = f.clear(in: own)
        } else {
            own = f.set(text, in: own)
        }
        return repoPatch(row, overrides: own)
    }

    /// The params that clear `repo`'s own value of `f`, so the recipe's applies again.
    public func clearingField(_ f: RecipeField, of repo: String) -> JSONValue? {
        guard let row = self.repo(repo) else { return nil }
        return repoPatch(row, overrides: f.clear(in: row.overrides ?? Recipe()))
    }

    /// The params that set (or, with nil, remove) one env variable of `repo`'s own.
    public func savingEnv(_ name: String, _ value: RecipeEnvValue?, of repo: String) -> JSONValue? {
        guard let row = self.repo(repo) else { return nil }
        var own = row.overrides ?? Recipe()
        var env = own.env ?? [:]
        env[name] = value
        own.env = env.isEmpty ? nil : env
        return repoPatch(row, overrides: own)
    }

    /// The params that switch "Also write to the worktree's .env" for `repo`.
    public func savingAlsoWriteEnvFile(_ on: Bool, of repo: String) -> JSONValue? {
        guard let row = self.repo(repo) else { return nil }
        var own = row.overrides ?? Recipe()
        own.alsoWriteEnvFile = on
        return repoPatch(row, overrides: own)
    }

    /// The params that point `repo` at recipe `name` (nil: none), or mark it doesn't run.
    public func savingRecipe(_ name: String?, doesntRun: Bool = false, of repo: String) -> JSONValue? {
        guard let row = self.repo(repo) else { return nil }
        var r = row
        r.recipe = doesntRun ? nil : name
        r.doesntRun = doesntRun
        // Go refuses a repo marked doesn't run that names a recipe or an override: the mark goes alone.
        return repoPatch(r, overrides: doesntRun ? Recipe() : row.overrides ?? Recipe())
    }

    /// Whether "Also write to .env" is on for `repo`.
    public func alsoWritesEnvFile(_ repo: String) -> Bool {
        guard let row = self.repo(repo) else { return false }
        return row.overrides?.alsoWriteEnvFile ?? row.recipeName.flatMap { recipes[$0]?.alsoWriteEnvFile } ?? false
    }

    private func repoPatch(_ row: RunningRepo, overrides: Recipe) -> JSONValue {
        var entry: [String: JSONValue] = [:]
        if let name = row.recipeName { entry["recipe"] = .string(name) }
        if row.doesNotRun { entry["doesntRun"] = .bool(true) }
        if overrides != Recipe(), let o = try? encodeRecipe(overrides) { entry["overrides"] = o }
        return .object(["repos": .object([row.repo: .object(entry)])])
    }
}

/// A recipe as the JSON `running_save` takes.
public func encodeRecipe(_ r: Recipe) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(r))
}

/// The Keychain ref a Running settings secret is kept under (Go's `RunSecretRef`).
public func runSecretRef(project: String, owner: String, variable: String) -> String {
    "run:\(project):\(owner):\(variable)"
}

/// Draft all's proposal, as the form shows it before anything is saved (Rule 9).
public struct RunningDraftAll: Decodable, Sendable, Equatable {
    public struct Group: Decodable, Sendable, Equatable {
        public var recipe: String
        public var repos: [String]
        public var differences: [String: [String]]?
    }
    public struct SharedService: Decodable, Sendable, Equatable {
        public var name: String
        public var host: String?
        public var `in`: String?
        public var repos: [String]?
        public var from: String?
    }
    public struct NothingToRun: Decodable, Sendable, Equatable {
        public var repo: String
        public var why: String
    }
    public var recipes: [String: Recipe]
    public var repos: [String: JSONValue]
    public var groups: [Group]
    public var sharedServices: [SharedService]
    public var nothingToRun: [NothingToRun]
    public var questions: [String]

    enum CodingKeys: String, CodingKey { case recipes, repos, groups, sharedServices, nothingToRun, questions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try c.decodeIfPresent([String: Recipe].self, forKey: .recipes) ?? [:]
        repos = try c.decodeIfPresent([String: JSONValue].self, forKey: .repos) ?? [:]
        groups = try c.decodeIfPresent([Group].self, forKey: .groups) ?? []
        sharedServices = try c.decodeIfPresent([SharedService].self, forKey: .sharedServices) ?? []
        nothingToRun = try c.decodeIfPresent([NothingToRun].self, forKey: .nothingToRun) ?? []
        questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
    }

    /// One line per proposal: what it is and what it was based on.
    public var lines: [String] {
        var out: [String] = []
        for s in sharedServices {
            out.append("Shared service \(s.name) — runs in \(s.in ?? "?") once per workspace for \((s.repos ?? []).joined(separator: ", "))"
                + (s.from.map { ". From: \($0)" } ?? ""))
        }
        for g in groups {
            let own = (g.differences ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) keeps \($0.value.joined(separator: ", "))" }
            out.append("Recipe \(g.recipe) → \(g.repos.joined(separator: ", "))" + (own.isEmpty ? "" : ". " + own.joined(separator: "; ")))
        }
        for n in nothingToRun { out.append("Nothing to run: \(n.repo) — \(n.why)") }
        for q in questions { out.append("Asks you: \(q)") }
        return out
    }

    /// The `running_save` params that save every proposal.
    public var saving: JSONValue {
        var recipes: [String: JSONValue] = [:]
        for (k, r) in self.recipes { recipes[k] = (try? encodeRecipe(r)) ?? .null }
        return .object(["recipes": .object(recipes), "repos": .object(repos)])
    }
}

/// Detect's draft for one repo, saved as a recipe named for its kind (unless one of that name
/// exists) that the repo names.
public struct RunningDetected: Decodable, Sendable, Equatable {
    public var repo: String
    public var kind: String
    public var recipe: Recipe
    public var doesntRun: Bool
    public var why: String?
    public var questions: [String]

    enum CodingKeys: String, CodingKey { case repo, kind, recipe, doesntRun, why, questions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        recipe = try c.decodeIfPresent(Recipe.self, forKey: .recipe) ?? Recipe()
        doesntRun = try c.decodeIfPresent(Bool.self, forKey: .doesntRun) ?? false
        why = try c.decodeIfPresent(String.self, forKey: .why)
        questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
    }

    /// One line per field the draft sets, then its questions: what Save would keep.
    public var lines: [String] {
        if doesntRun { return ["\(repo) — nothing to run" + (why.map { ": \($0)" } ?? "")] }
        var out: [String] = ["Recipe \(kind.isEmpty ? repo : kind) for \(repo)"]
        for f in RecipeField.allCases where f.isSet(in: recipe) {
            let note = recipe.notes?[f.rawValue].map { "  (\($0))" } ?? ""
            out.append("\(f.label): \(f.text(in: recipe).replacingOccurrences(of: "\n", with: " · "))\(note)")
        }
        for q in questions { out.append("Asks you: \(q)") }
        return out
    }

    /// The name the draft is saved under: its kind, or `<kind>-<repo>` when a different recipe
    /// already has that name.
    public func recipeName(existing: [String: Recipe]) -> String {
        let base = kind.isEmpty ? repo : kind
        if let other = existing[base], other != recipe { return "\(base)-\(repo)" }
        return base
    }

    public func saving(existing: [String: Recipe]) -> JSONValue {
        if doesntRun {
            return .object(["repos": .object([repo: .object(["doesntRun": .bool(true)])])])
        }
        let name = recipeName(existing: existing)
        return .object([
            "recipes": .object([name: (try? encodeRecipe(recipe)) ?? .null]),
            "repos": .object([repo: .object(["recipe": .string(name)])]),
        ])
    }
}
