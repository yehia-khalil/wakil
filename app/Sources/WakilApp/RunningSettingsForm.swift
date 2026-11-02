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
    /// Detect's drafting conversation and Try's fix (decision 13): the window's.
    var drafting: RunningDrafting = .none
    /// A Try's progress as Go runs it, by repo (`WindowModel.runningTryProgress`): the step list.
    var tryProgress: (String) -> TryProgressState? = { _ in nil }
    /// Opens a page as other ↗ links do (`WakilLinks.open`: `browser_open`, ⌥ the system browser).
    var openLink: (String, Bool) -> Void = { _, _ in }

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
    @State private var showingTryOutput = false

    /// What Draft all or Detect proposes, before anything is saved.
    struct Proposal: Equatable {
        var title: String
        var lines: [String]
        var saving: JSONValue
        /// The drafting conversation the title names, drawn as a control that opens it.
        var conversation: String? = nil
        var repo: String? = nil
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
        /// The Try's port: a ready Try links its app there.
        var port: Int?
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
                .accessibilityElement(children: .contain)
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
                if let d = drafting.draft(row.repo) { draftBox(s, d) }
                if !row.doesNotRun && row.recipeName != nil {
                    FormHint("Shared fields come from the recipe; change one here to keep it for this repo only.")
                    ForEach(RecipeFieldSection.allCases, id: \.self) { section in
                        SettingsSection(section.title, identifier: "settings.running.section.\(section.rawValue)") {
                            VStack(alignment: .leading, spacing: 6) {
                                FormHint(section.hint)
                                ForEach(section.fields, id: \.self) { f in fieldBox(s, row.repo, f) }
                                if section.holdsEnv { envSection(s, row.repo) }
                            }
                        }
                    }
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
                        // .contain: without it the row's id lands on every child, Remove included,
                        // and the row's own id names four elements (piece 2's e2e run).
                        .accessibilityElement(children: .contain)
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

    private func proposalBox(_ p: Proposal, id: String = "settings.running.proposal", settle: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(linkingConversation(p.title, p.conversation))
                .font(.system(size: SettingsScale.body, weight: .medium))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, openingConversation(p.repo))
                .accessibilityIdentifier("\(id).title")
            FormHint("Nothing changes until you save. Each line says what it was based on.")
            ForEach(Array(p.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(line.hasPrefix("Asks you") ? SettingsPalette.caution : SettingsPalette.coolWhite.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                FormButton(title: "Save", tone: SettingsPalette.accent, filled: true, identifier: "\(id).save") {
                    let saving = p.saving
                    if id == "settings.running.proposal" { proposal = nil }
                    settle()
                    save(saving)
                }
                FormButton(title: "Discard", tone: SettingsPalette.coolWhite, identifier: "\(id).discard") {
                    if id == "settings.running.proposal" { proposal = nil }
                    settle()
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(SettingsPalette.accent.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
        .padding(.top, 8)
    }

    /// The drafting conversation's state (Rule 5, with Stop: Rule 4; a failure whole: Rule 8) and
    /// its proposal, unsaved until Save (Rule 9).
    @ViewBuilder
    private func draftBox(_ s: RunningSettings, _ d: RecipeDraft) -> some View {
        if let line = d.line {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if d.inFlight { ProgressView().controlSize(.small) }
                Text(d.lineParts.map { linkingConversation($0.before + $0.conversation + $0.after, $0.conversation) }
                     ?? AttributedString(line))
                    .environment(\.openURL, openingConversation(d.key.repo))
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(d.inFlight ? SettingsPalette.coolWhite.opacity(0.7) : SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.running.draftLine")
                if d.inFlight {
                    FormButton(title: "Stop", tone: SettingsPalette.caution, identifier: "settings.running.draftStop") {
                        Task { await drafting.stop(d.key.repo) }
                    }
                }
                if d.canAskAgain {
                    FormButton(title: "Ask again", tone: SettingsPalette.accent, identifier: "settings.running.draftAskAgain") {
                        Task { await drafting.askAgain(d.key.repo) }
                    }
                }
            }
        }
        if let p = d.proposal {
            proposalBox(Proposal(
                title: d.isFix ? "Fix proposed by ‘\(d.title)’ — \(d.key.repo)" : "Drafted in ‘\(d.title)’ — \(d.key.repo)",
                lines: p.lines, saving: s.savingDraft(p, of: d.key.repo), conversation: d.title, repo: d.key.repo),
                id: "settings.running.draft", settle: { drafting.settle(d.key.repo) })
        }
    }

    private func tryBox(_ t: TryState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = tryProgress(t.repo) {
                tryStepList(p)
            } else if t.running {
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
            ForEach(Array((tryProgress(t.repo) == nil ? t.steps : []).enumerated()), id: \.offset) { _, step in
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("ready: \(ready.detail)")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(ready.ready ? SettingsPalette.coolWhite.opacity(0.84) : SettingsPalette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    // The app's root on the Try's port, never the ready path (design-language §5).
                    if ready.ready, let port = t.port {
                        Button(WebLink.label(runAppLabel(port: port))) {
                            openLink(runAppAddress(port: port), NSEvent.modifierFlags.contains(.option))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: SettingsScale.body, weight: .medium))
                        .foregroundStyle(WebLink.colour)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Open \(runAppAddress(port: port)) in Wakil's browser; ⌥-click for the system browser")
                        .accessibilityIdentifier("settings.running.tryApp")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.running.tryBox")
    }

    /// Try's steps as they run (the walk): ✓ done with its time, ● running with its time so far and
    /// its last line, ○ to come, ✗ failed with its output whole (Rule 8); Show output opens the
    /// running or failed step's whole output. Every line wraps whole.
    private func tryStepList(_ p: TryProgressState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(p.steps.enumerated()), id: \.offset) { i, step in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(step.mark)
                        Text(step.title).fixedSize(horizontal: false, vertical: true)
                        if let time = step.time { Text(time).foregroundStyle(SettingsPalette.coolWhite.opacity(0.52)) }
                    }
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(step.state == .failed ? SettingsPalette.caution
                        : step.state == .toCome ? SettingsPalette.coolWhite.opacity(0.42) : SettingsPalette.coolWhite.opacity(0.84))
                    if step.state == .running, !step.lastLine.isEmpty {
                        Text(step.lastLine)
                            .font(.system(size: SettingsScale.meta, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.running.tryStep.lastLine")
                    }
                    if step.state == .failed {
                        Text([step.detail, step.output].filter { !$0.isEmpty }.joined(separator: "\n"))
                            .font(.system(size: SettingsScale.meta, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.running.tryStep.\(i)")
            }
            if let shown = p.shown, !shown.output.isEmpty {
                DisclosureGroup(isExpanded: $showingTryOutput) {
                    Text(shown.output)
                        .font(.system(size: SettingsScale.meta, design: .monospaced))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Show output — \(shown.title)").font(.system(size: SettingsScale.body))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("settings.running.tryOutput")
            }
        }
    }

    /// `text` with the conversation's name a link that opens it (the walk: the drafting lines named
    /// a conversation nothing could open); it wraps with the line, whole.
    private func linkingConversation(_ text: String, _ conversation: String?) -> AttributedString {
        var a = AttributedString(text)
        if let conversation, !conversation.isEmpty, let r = a.range(of: conversation) {
            a[r].link = URL(string: "wakil-draft://open")
            a[r].underlineStyle = .single
        }
        return a
    }

    /// Pressing the conversation's name opens it, in Main of the project (the operator asked for the
    /// jump, so Rule 6 allows it).
    private func openingConversation(_ repo: String?) -> OpenURLAction {
        OpenURLAction { url in
            guard url.scheme == "wakil-draft", let repo else { return .systemAction }
            Task { await drafting.open(repo) }
            return .handled
        }
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
            // Detect could not work out the rest: a conversation in Main drafts it from the docs (step 2).
            if d.needsDrafting {
                let root = rootPath(repo)
                Task { await drafting.start(repo, root, r, d.kind) }
            }
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

    private func rootPath(_ repo: String) -> String {
        project.roots.first { ($0.path as NSString).lastPathComponent == repo }?.path ?? settings?.repo(repo)?.path ?? ""
    }

    private func startTry(_ row: RunningRepo) {
        endTry()
        let root = rootPath(row.repo)
        let tried = row.effective?.recipe ?? Recipe()
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
                if case .integer(let port)? = o["port"] { state.port = Int(port) }
                // The Try's workspace went with it; a copy with changes was kept, said whole (Rule 8).
                if case .string(let kept)? = o["kept"] { refusal = kept }
                if let report = try? decodeTry(.object(o)) {
                    state.passed = report.passed
                    state.steps = report.steps
                    state.ready = report.ready
                }
            }
            tryState = state
            // A failed Try asks the drafting conversation for a fix (step 3); a cancelled or
            // refused one does not.
            if state.passed == false, state.error == nil, !Task.isCancelled,
               let report = r.flatMap({ try? decodeTry($0) }) {
                await drafting.fix(row.repo, root, tried, report)
            }
        }
    }

    /// A Try cleans its own workspace when it ends; the form closing or another Try starting
    /// ends one still recorded (a copy kept for its changes).
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

/// The window's drafting conversations, as the Running settings reach them (decision 13).
struct RunningDrafting {
    var draft: (String) -> RecipeDraft? = { _ in nil }
    var start: (_ repo: String, _ root: String, _ detected: JSONValue, _ kind: String) async -> Void = { _, _, _, _ in }
    var fix: (_ repo: String, _ root: String, _ recipe: Recipe, _ report: RunTryResult) async -> Void = { _, _, _, _ in }
    var settle: (String) -> Void = { _ in }
    var stop: (String) async -> Void = { _ in }
    /// Opens the repo's drafting conversation (it lives in Main of the project).
    var open: (String) async -> Void = { _ in }
    /// Ask again: the last request sent once more to the repo's drafting conversation.
    var askAgain: (String) async -> Void = { _ in }

    static var none: RunningDrafting { RunningDrafting() }
}
