import SwiftUI
import WakilKit

/// Workspaces, piece 2: a project's **Running** settings (decisions 13–15; mockup settings.html).
/// Left, every repo grouped by the recipe it uses; right, the selected repo's recipe — the
/// recipe's fields grey, the repo's own violet, each saved when it is left (Rule 2). **Draft all**
/// and **Detect** propose and save nothing until Save (Rule 9); **Try** shows each step and can
/// be cancelled (Rules 4, 5); every refusal is shown whole (Rule 8). The decisions are
/// `RunningSettings` (WakilKit, tested); this draws them.
struct RunningSettingsForm: View {
    let project: SettingsProject
    let environment: String
    /// Dispatches one action as the operator: its result, or the refusal whole.
    let dispatch: (String, JSONValue) async -> (result: JSONValue?, error: String?)

    @State private var settings: RunningSettings?
    @State private var loadError: String?
    @State private var selected: String?
    @State private var proposal: Proposal?
    @State private var working: String?
    @State private var refusal: String?
    @State private var tryState: TryState?
    @State private var tryTask: Task<Void, Never>?
    @State private var newVariable = ""
    @State private var newValue = ""
    @State private var newSecret = false

    /// What Draft all or Detect proposes, before anything is saved.
    struct Proposal: Equatable {
        var title: String
        var lines: [String]
        var saving: JSONValue
    }

    /// A Try in flight or done: its throwaway workspace, and its report.
    struct TryState: Equatable {
        var repo: String
        var workspace: String?
        var running: Bool
        var passed: Bool?
        var steps: [RunStepResult]
        var ready: RunReadyResult?
        var error: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Running") {
                FormHint("How each repo runs in a workspace's copy, on its own ports ($WAKIL_PORT … +9). A recipe is "
                    + "written once and shared; a repo keeps only what it changes. The agent runs only what is saved here.")
                    .padding(.bottom, 6)
                HStack(spacing: 8) {
                    FormButton(title: working == "draftAll" ? "Drafting…" : "✨ Draft all", tone: SettingsPalette.accent,
                               filled: true, identifier: "settings.running.draftAll") { draftAll() }
                        .disabled(working != nil)
                    if working != nil {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let loadError { errorText(loadError, id: "settings.running.loadError") }
            if let refusal { errorText(refusal, id: "settings.running.error") }
            if let settings, !settings.problems.isEmpty {
                ForEach(settings.problems, id: \.self) { errorText($0, id: "settings.running.problem") }
            }
            if let proposal { proposalBox(proposal) }
            if let settings {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        list(settings).frame(width: 220, alignment: .leading)
                        form(settings).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        list(settings)
                        form(settings)
                    }
                }
                .padding(.top, 8)
            } else if loadError == nil {
                ProgressView().controlSize(.small).padding(.top, 8)
            }
        }
        .task(id: project.path) { await load() }
        .onDisappear {
            tryTask?.cancel()
            endTry()
        }
    }

    // MARK: the list

    private func list(_ s: RunningSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(s.groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title.uppercased())
                        .font(.system(size: SettingsScale.micro, weight: .medium))
                        .tracking(SettingsScale.microTracking)
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(group.repos, id: \.self) { repo in
                        Button { select(repo) } label: {
                            Text(repo)
                                .font(.system(size: SettingsScale.body))
                                .foregroundStyle(selected == repo ? SettingsPalette.accent : SettingsPalette.coolWhite.opacity(0.84))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.running.repo.\(repo)")
                    }
                }
            }
        }
    }

    // MARK: the form

    @ViewBuilder
    private func form(_ s: RunningSettings) -> some View {
        if let name = selected ?? s.repos.first?.repo, let row = s.repo(name) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(row.repo)
                        .font(.system(size: SettingsScale.identifier, weight: .medium))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.92))
                    Text(row.doesNotRun ? "doesn't run" : row.recipeName.map { "uses \($0)" } ?? "no recipe")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("settings.running.form.title")
                recipeChoice(s, row)
                HStack(spacing: 8) {
                    FormButton(title: working == "detect" ? "Detecting…" : "Detect", tone: SettingsPalette.coolWhite,
                               identifier: "settings.running.detect") { detect(row.repo) }
                        .disabled(working != nil)
                    FormButton(title: tryState?.running == true ? "Trying…" : "▶ Try", tone: SettingsPalette.accent,
                               filled: true, identifier: "settings.running.try") { startTry(row) }
                        .disabled(working != nil || tryState?.running == true || row.doesNotRun || row.recipeName == nil)
                    if tryState?.running == true {
                        FormButton(title: "Cancel", tone: SettingsPalette.caution, identifier: "settings.running.tryCancel") {
                            tryTask?.cancel()
                        }
                    }
                }
                if let t = tryState, t.repo == row.repo { tryBox(t) }
                if !row.doesNotRun && row.recipeName != nil {
                    FormHint("Shared fields come from the recipe; change one here to keep it for this repo only.")
                    ForEach(RecipeField.allCases, id: \.self) { f in fieldBox(s, row.repo, f) }
                    envSection(s, row.repo)
                }
            }
            .id(row.repo)
        } else {
            FormHint("This project has no repos to run.")
        }
    }

    private func recipeChoice(_ s: RunningSettings, _ row: RunningRepo) -> some View {
        let names = s.recipes.keys.sorted().filter { !(s.recipes[$0]?.isSharedService ?? false) }
        return SettingsRow("Recipe", wraps: true) {
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    FormButton(title: name, tone: row.recipeName == name ? SettingsPalette.accent : SettingsPalette.coolWhite,
                               filled: row.recipeName == name, identifier: "settings.running.recipe.\(name)") {
                        save(s.savingRecipe(name, of: row.repo))
                    }
                }
                FormButton(title: "Doesn't run", tone: row.doesNotRun ? SettingsPalette.accent : SettingsPalette.coolWhite,
                           filled: row.doesNotRun, identifier: "settings.running.doesntRun") {
                    save(s.savingRecipe(row.doesNotRun ? row.recipeName : nil, doesntRun: !row.doesNotRun, of: row.repo))
                }
            }
        }
    }

    private func fieldBox(_ s: RunningSettings, _ repo: String, _ f: RecipeField) -> some View {
        let field = s.field(f, of: repo)
        return VStack(alignment: .leading, spacing: 1) {
            AgentInstructionBox(
                label: f.label, stored: field.text, placeholder: f.hint,
                identifier: "settings.running.field.\(f.rawValue)",
                save: { text in await saveNow(s.savingField(f, text, of: repo)) })
                .id("\(repo).\(f.rawValue).\(field.text)")
            HStack(spacing: 6) {
                if field.source != .none {
                    Text(field.source.label)
                        .foregroundStyle(field.source == .repo ? SettingsPalette.accent : SettingsPalette.coolWhite.opacity(0.42))
                }
                if let note = field.note { Text("· \(note)").foregroundStyle(SettingsPalette.coolWhite.opacity(0.42)) }
                if field.source == .repo {
                    Button("Use the recipe's") { save(s.clearingField(f, of: repo)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.62))
                        .accessibilityIdentifier("settings.running.field.\(f.rawValue).inherit")
                }
            }
            .font(.system(size: SettingsScale.meta))
            .fixedSize(horizontal: false, vertical: true)
            .underRowValue()
        }
    }

    private func envSection(_ s: RunningSettings, _ repo: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow("Env", wraps: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.env(of: repo), id: \.name) { row in
                        HStack(spacing: 8) {
                            Text(row.name).font(.system(size: SettingsScale.body, design: .monospaced))
                            switch row.value {
                            case .value(let v): Text(v).font(.system(size: SettingsScale.body, design: .monospaced))
                            case .secret: Text("•••••••• 🔒 Keychain").font(.system(size: SettingsScale.body))
                            }
                            Text(row.source.label + (row.value.isSecret ? " · secret" : ""))
                                .font(.system(size: SettingsScale.meta))
                                .foregroundStyle(row.source == .repo ? SettingsPalette.accent : SettingsPalette.coolWhite.opacity(0.42))
                            if row.source == .repo {
                                Button("Remove") { save(s.savingEnv(row.name, nil, of: repo)) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: SettingsScale.meta))
                                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.62))
                                    .accessibilityIdentifier("settings.running.env.\(row.name).remove")
                            }
                        }
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.running.env.\(row.name)")
                    }
                    HStack(spacing: 6) {
                        TextField("VARIABLE", text: $newVariable)
                            .textFieldStyle(.roundedBorder).frame(width: 140)
                            .accessibilityIdentifier("settings.running.env.newName")
                        Group {
                            if newSecret {
                                SecureField("value", text: $newValue)
                            } else {
                                TextField("value, may use $WAKIL_*", text: $newValue)
                            }
                        }
                        .textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 240)
                        .accessibilityIdentifier("settings.running.env.newValue")
                        Toggle("🔒 secret", isOn: $newSecret)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("settings.running.env.newSecret")
                        FormButton(title: "Add", tone: SettingsPalette.accent, identifier: "settings.running.env.add") {
                            addVariable(s, repo)
                        }
                        .disabled(newVariable.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Toggle("Also write to the worktree's .env", isOn: Binding(
                        get: { s.alsoWritesEnvFile(repo) },
                        set: { save(s.savingAlsoWriteEnvFile($0, of: repo)) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: SettingsScale.body))
                        .accessibilityIdentifier("settings.running.env.alsoWrite")
                    FormHint("Applied to every command of this repo in every workspace. A secret goes to the Keychain "
                        + "and is never shown. \".env\" is the copy's own (ignored by git); your folder's is never touched.")
                }
            }
        }
    }

    // MARK: proposals and Try

    private func proposalBox(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.title)
                .font(.system(size: SettingsScale.body, weight: .medium))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.92))
            FormHint("Nothing changes until you save. Each line says what it was based on.")
            ForEach(Array(p.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(line.hasPrefix("Asks you") ? SettingsPalette.caution : SettingsPalette.coolWhite.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                FormButton(title: "Save", tone: SettingsPalette.accent, filled: true, identifier: "settings.running.proposal.save") {
                    let saving = p.saving
                    proposal = nil
                    save(saving)
                }
                FormButton(title: "Discard", tone: SettingsPalette.coolWhite, identifier: "settings.running.proposal.discard") {
                    proposal = nil
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(SettingsPalette.accent.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.running.proposal")
        .padding(.top, 8)
    }

    private func tryBox(_ t: TryState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if t.running {
                Text("Trying \(t.repo) in a throwaway workspace…")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
            }
            if let error = t.error { errorText(error, id: "settings.running.tryError") }
            if let passed = t.passed {
                Text(passed ? "Last Try passed" : "Last Try failed")
                    .font(.system(size: SettingsScale.body, weight: .medium))
                    .foregroundStyle(passed ? SettingsPalette.accent : SettingsPalette.caution)
                    .accessibilityIdentifier("settings.running.tryResult")
            }
            ForEach(Array(t.steps.enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(step.ok ? "✓" : "✗") \(step.phase)\(step.name.isEmpty ? "" : " \(step.name)")"
                        + (step.command.isEmpty ? "" : " — \(step.command)"))
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(step.ok ? SettingsPalette.coolWhite.opacity(0.84) : SettingsPalette.caution)
                    if !step.ok {
                        Text(step.failureText)
                            .font(.system(size: SettingsScale.meta, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let ready = t.ready {
                Text("ready: \(ready.detail)")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(ready.ready ? SettingsPalette.coolWhite.opacity(0.84) : SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.running.tryBox")
    }

    private func errorText(_ text: String, id: String) -> some View {
        Text(text)
            .font(.system(size: SettingsScale.body))
            .foregroundStyle(SettingsPalette.caution)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.vertical, 4)
            .accessibilityIdentifier(id)
    }

    // MARK: actions

    private var projectParam: [String: JSONValue] { ["projectPath": .string(project.path)] }

    private func select(_ repo: String) {
        selected = repo
        newVariable = ""
        newValue = ""
        newSecret = false
    }

    private func load() async {
        let (r, error) = await dispatch("running_read", .object(projectParam))
        if let error { loadError = error; return }
        guard let r, let s = try? RunningSettings.decode(r) else { loadError = "The Running settings could not be read."; return }
        loadError = nil
        settings = s
        if selected == nil || s.repo(selected!) == nil { selected = s.repos.first?.repo }
    }

    private func withProject(_ v: JSONValue) -> JSONValue {
        guard case .object(var o) = v else { return v }
        o["projectPath"] = .string(project.path)
        return .object(o)
    }

    /// Saves and re-reads; answers the refusal whole, or nil.
    private func saveNow(_ params: JSONValue?) async -> String? {
        guard let params else { return nil }
        let (_, error) = await dispatch("running_save", withProject(params))
        refusal = error
        await load()
        return error
    }

    private func save(_ params: JSONValue?) {
        Task { _ = await saveNow(params) }
    }

    private func draftAll() {
        working = "draftAll"
        refusal = nil
        Task {
            defer { working = nil }
            let (r, error) = await dispatch("running_draft_all", .object(projectParam))
            if let error { refusal = error; return }
            guard let r, let d = try? decodeDraftAll(r) else { refusal = "Draft all answered nothing readable."; return }
            proposal = Proposal(title: "Draft all — \(d.groups.count) recipes proposed", lines: d.lines, saving: d.saving)
        }
    }

    private func detect(_ repo: String) {
        working = "detect"
        refusal = nil
        Task {
            defer { working = nil }
            var params = projectParam
            params["repo"] = .string(repo)
            let (r, error) = await dispatch("running_detect", .object(params))
            if let error { refusal = error; return }
            guard let r, let d = try? decodeDetected(r) else { refusal = "Detect answered nothing readable."; return }
            proposal = Proposal(title: "Detect — \(repo)", lines: d.lines, saving: d.saving(existing: settings?.recipes ?? [:]))
        }
    }

    private func addVariable(_ s: RunningSettings, _ repo: String) {
        let name = newVariable.trimmingCharacters(in: .whitespaces)
        let value = newValue
        let secret = newSecret
        Task {
            if secret {
                let ref = runSecretRef(project: project.name, owner: repo, variable: name)
                let (_, error) = await dispatch("running_secret_set", .object([
                    "project": .string(project.name), "owner": .string(repo), "variable": .string(name), "value": .string(value),
                ]))
                if let error { refusal = error; return }
                if await saveNow(s.savingEnv(name, .secret(ref), of: repo)) != nil { return }
            } else if await saveNow(s.savingEnv(name, .value(value), of: repo)) != nil {
                return
            }
            newVariable = ""
            newValue = ""
            newSecret = false
        }
    }

    private func startTry(_ row: RunningRepo) {
        endTry()
        let root = project.roots.first { ($0.path as NSString).lastPathComponent == row.repo }?.path ?? row.path
        tryState = TryState(repo: row.repo, running: true, steps: [])
        tryTask = Task {
            let (r, error) = await dispatch("running_try", .object([
                "repo": .string(row.repo), "root": .string(root), "project": .string(project.name),
                "environment": .string(environment), "projectPath": .string(project.path),
            ]))
            var state = TryState(repo: row.repo, running: false, steps: [])
            if Task.isCancelled { state.error = "Try was cancelled." }
            if let error { state.error = error }
            if case .object(let o)? = r {
                if case .string(let w)? = o["workspace"] { state.workspace = w }
                if let report = try? decodeTry(.object(o)) {
                    state.passed = report.passed
                    state.steps = report.steps
                    state.ready = report.ready
                }
            }
            tryState = state
        }
    }

    /// Try's workspace is archived when the form closes or another Try starts.
    private func endTry() {
        guard let w = tryState?.workspace else { return }
        tryState?.workspace = nil
        Task { _ = await dispatch("running_try_end", .object(["workspace": .string(w)])) }
    }
}

private func decodeDraftAll(_ v: JSONValue) throws -> RunningDraftAll {
    try JSONDecoder().decode(RunningDraftAll.self, from: JSONEncoder().encode(v))
}

private func decodeDetected(_ v: JSONValue) throws -> RunningDetected {
    try JSONDecoder().decode(RunningDetected.self, from: JSONEncoder().encode(v))
}

private func decodeTry(_ v: JSONValue) throws -> RunTryResult {
    try JSONDecoder().decode(RunTryResult.self, from: JSONEncoder().encode(v))
}
