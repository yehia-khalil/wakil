import SwiftUI
import WakilKit

/// Workspaces, piece 2: a project's **Running** settings (decisions 13–15), drawn as the comp of
/// 2026-11-02: one column that reads as what ▶ does — a repo switch when there are two or more,
/// the head (the repo, its recipe as one menu, Detect · ✨ Draft · ▶ Try), then one spine of four
/// stops (Prepare a new copy, Start, Ready when, Stop) whose fields edit in place and save when
/// left (Rule 2), an unset field a "+ <Field>" chip that opens it focused (Rules 3, 9); then Ports
/// and environment. **Draft** and **Detect** propose and save nothing until Save (Rule 9); **Try**
/// lights each stop's node and can be cancelled (Rules 4, 5); every failure is shown whole under
/// its stop (Rule 8). The decisions are `RunningSettings` and `RunStop` (WakilKit, tested).
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
    /// Fields drawn as rows whatever they hold: opened from a chip, or being edited.
    @State private var open: Set<RecipeField> = []
    /// The field a chip just opened, focused as it appears (Rule 3).
    @State private var focusRequest: RecipeField?
    @State private var addingEnv = false
    @FocusState private var envNameFocused: Bool

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
        var started = Date()
        var ended: Date?
        /// The recipe tried and Go's report: what a fix is asked from.
        var tried = Recipe()
        var report: RunTryResult?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError { errorText(loadError, id: "settings.running.loadError") }
            if let settings {
                page(settings)
            } else if loadError == nil {
                ProgressView().controlSize(.small).padding(.top, 8)
            }
        }
        .padding(.top, 4)
        .task(id: project.path) { await load() }
        .onDisappear {
            tryTask?.cancel()
            endTry()
        }
    }

    // MARK: the page

    /// One column (the comp): the repo switch when there are two or more, the head, one lede line,
    /// the Try's status, the spine of four stops, then ports and environment.
    @ViewBuilder
    private func page(_ s: RunningSettings) -> some View {
        let single = s.repos.count < 2
        VStack(alignment: .leading, spacing: 0) {
            if !single { repoSwitch(s).padding(.bottom, 20) }
            if let name = selected ?? s.repos.first?.repo, let row = s.repo(name) {
                VStack(alignment: .leading, spacing: 0) {
                    head(s, row, single: single).padding(.bottom, 18)
                    Text("What ▶ does in a workspace's own copy, on its own ports. The agent runs only what is saved "
                        + "here. A field you change is kept for this repo; the rest follows the recipe.")
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .foregroundStyle(RunInk.text(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                        .padding(.bottom, 22)
                    if let refusal { errorText(refusal, id: "settings.running.error") }
                    ForEach(s.problems, id: \.self) { errorText($0, id: "settings.running.problem") }
                    if let proposal { proposalBox(proposal).padding(.bottom, 18) }
                    if let t = tryState, t.repo == row.repo { tryLine(t).padding(.bottom, 24) }
                    if let d = drafting.draft(row.repo), fixStop(row.repo, d) == nil {
                        draftBox(s, d).padding(.bottom, 18)
                    }
                    if row.doesNotRun {
                        stateLine("\(row.repo) doesn't run: ▶ starts nothing for it. Pick a recipe under Recipe to run it.")
                    } else if row.recipeName == nil {
                        stateLine("\(row.repo) has no recipe yet: Detect or Draft one, or pick one under Recipe.")
                    } else {
                        spine(s, row)
                        portsAndEnv(s, row.repo).padding(.top, 36)
                    }
                }
                .id(row.repo)
            } else {
                if single { RunButton(title: draftAllTitle, kind: .plain, identifier: "settings.running.draftAll") { draftAll() }
                    .disabled(working != nil).padding(.bottom, 12) }
                FormHint("This project has no repos to run.")
            }
        }
        .padding(.bottom, 40)
    }

    private var draftAllTitle: String { working == "draftAll" ? "Drafting…" : "✨ Draft all" }

    private func stateLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(RunInk.text(0.72))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520, alignment: .leading)
    }

    /// The repo switch, only with two or more repos: each repo and its recipe; Draft all beside it.
    private func repoSwitch(_ s: RunningSettings) -> some View {
        ApiFlow(spacing: 12, lineSpacing: 8) {
            ApiFlow(spacing: 4, lineSpacing: 4) {
                ForEach(s.repos, id: \.repo) { row in
                    let on = (selected ?? s.repos.first?.repo) == row.repo
                    Button { select(row.repo) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.repo).font(.system(size: 12.5)).foregroundStyle(on ? RunInk.text(1) : RunInk.text(0.72))
                            Text(row.doesNotRun ? "doesn't run" : row.recipeName ?? "no recipe")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(RunInk.text(0.58))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? RunInk.slab2 : .clear)
                                .shadow(color: on ? .black.opacity(0.4) : .clear, radius: 1.5, y: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("settings.running.repo.\(row.repo)")
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(RunInk.text(0.035)))
            RunButton(title: draftAllTitle, kind: .quiet, identifier: "settings.running.draftAll") { draftAll() }
                .disabled(working != nil)
        }
    }

    /// The repo, its recipe as one menu, and Detect · ✨ Draft · ▶ Try — under the name when they do
    /// not fit beside it, never cut.
    private func head(_ s: RunningSettings, _ row: RunningRepo, single: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                repoTitle(row)
                recipeMenu(s, row)
                Spacer(minLength: 18)
                actions(row, single: single)
            }
            VStack(alignment: .leading, spacing: 12) {
                ApiFlow(spacing: 18, lineSpacing: 8) {
                    repoTitle(row)
                    recipeMenu(s, row)
                }
                actions(row, single: single)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.running.form.title")
    }

    private func repoTitle(_ row: RunningRepo) -> some View {
        Text(row.repo)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(RunInk.text(1))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Each recipe, then Doesn't run: what used to be a row of buttons. The chosen one is ticked.
    private func recipeMenu(_ s: RunningSettings, _ row: RunningRepo) -> some View {
        let names = s.recipes.keys.sorted().filter { !(s.recipes[$0]?.isSharedService ?? false) }
        let current = row.doesNotRun ? "doesn't run" : row.recipeName ?? "none"
        return Menu {
            ForEach(names, id: \.self) { name in
                Button { save(s.savingRecipe(name, of: row.repo)) } label: {
                    if !row.doesNotRun && row.recipeName == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
                .accessibilityIdentifier("settings.running.recipe.\(name)")
            }
            Divider()
            Button { save(s.savingRecipe(nil, doesntRun: true, of: row.repo)) } label: {
                if row.doesNotRun { Label("Doesn't run", systemImage: "checkmark") } else { Text("Doesn't run") }
            }
            .accessibilityIdentifier("settings.running.doesntRun")
        } label: {
            (Text("Recipe ").foregroundColor(RunInk.text(0.72))
                + Text(current).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(RunInk.text(0.92)))
                .font(.system(size: 12.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(RunInk.edge, lineWidth: 0.5))
        .accessibilityIdentifier("settings.running.recipeMenu")
    }

    private func actions(_ row: RunningRepo, single: Bool) -> some View {
        ApiFlow(spacing: 8, lineSpacing: 8) {
            RunButton(title: working == "detect" ? "Detecting…" : "Detect", kind: .quiet, identifier: "settings.running.detect") {
                detect(row.repo)
            }
            .disabled(working != nil)
            // One repo: its Draft is Draft all, which drafts that repo (the comp). With more, Draft
            // all sits beside the switch.
            if single {
                RunButton(title: working == "draftAll" ? "Drafting…" : "✨ Draft", kind: .plain, identifier: "settings.running.draftAll") {
                    draftAll()
                }
                .disabled(working != nil)
            }
            RunButton(title: tryState?.running == true ? "Trying…" : "▶ Try", kind: .primary, identifier: "settings.running.try") {
                startTry(row)
            }
            .disabled(working != nil || tryState?.running == true || row.doesNotRun || row.recipeName == nil)
            if working != nil { ProgressView().controlSize(.small) }
        }
    }

    // MARK: the spine

    /// The Try's rows for the page: Go's live progress, else the finished report.
    private func tryRows(_ t: TryState) -> (steps: [TryStepState], finished: Bool) {
        if let p = tryProgress(t.repo) { return (p.steps, p.finished || !t.running) }
        return (tryStepStates(RunTryResult(passed: t.passed ?? false, steps: t.steps, ready: t.ready)), !t.running)
    }

    private func stopProgress(_ repo: String) -> [RunStop: RunStopProgress]? {
        guard let t = tryState, t.repo == repo else { return nil }
        let rows = tryRows(t)
        return runStopProgress(rows.steps, finished: rows.finished)
    }

    /// The stop under which a fix drafted after a failed Try is drawn: the one that failed.
    private func fixStop(_ repo: String, _ d: RecipeDraft) -> RunStop? {
        guard d.isFix, let p = stopProgress(repo) else { return nil }
        return RunStop.allCases.first { p[$0]?.status == .failed }
    }

    private func spine(_ s: RunningSettings, _ row: RunningRepo) -> some View {
        let progress = stopProgress(row.repo)
        return VStack(alignment: .leading, spacing: 30) {
            ForEach(RunStop.allCases, id: \.self) { stop in
                stopView(s, row, stop, progress?[stop])
            }
        }
        .padding(.leading, 28)
        .background(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(stops: [.init(color: RunInk.edge, location: 0), .init(color: RunInk.hair, location: 0.85),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
                .padding(.vertical, 10)
                .padding(.leading, 5)
        }
    }

    private func stopView(_ s: RunningSettings, _ row: RunningRepo, _ stop: RunStop, _ p: RunStopProgress?) -> some View {
        let layout = s.stopFields(stop, of: row.repo, open: open)
        let dimmed = p?.status == .notReached
        return VStack(alignment: .leading, spacing: 0) {
            ApiFlow(spacing: 12, lineSpacing: 4) {
                Text(stop.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RunInk.text(dimmed ? 0.62 : 1))
                    .fixedSize(horizontal: false, vertical: true)
                Text(p?.when ?? stop.when)
                    .font(.system(size: 12))
                    .foregroundStyle(p?.status == .failed ? RunInk.redText : RunInk.text(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, layout.rows.isEmpty ? 4 : 8)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(layout.rows.enumerated()), id: \.element) { i, f in
                    fieldRow(s, row.repo, f, first: i == 0)
                }
            }
            if let p, !p.steps.isEmpty { stepList(p) }
            if let p, let failed = p.failed { failure(s, row, failed) }
            if let t = tryState, t.repo == row.repo, let shown = tryProgress(t.repo)?.shown,
               RunStop.of(phase: shown.phase) == stop, !shown.output.isEmpty {
                outputDisclosure(shown)
            }
            if !layout.chips.isEmpty {
                ApiFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(layout.chips, id: \.self) { f in
                        RunChip(word: f.chipLabel, hint: f.chipHint, identifier: "settings.running.add.\(f.rawValue)") {
                            openField(f)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) { RunNode(status: p?.status ?? .idle).offset(x: -28, y: 4) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.running.stop.\(stop.rawValue)")
    }

    private func fieldRow(_ s: RunningSettings, _ repo: String, _ f: RecipeField, first: Bool) -> some View {
        let field = s.field(f, of: repo)
        let text = s.formText(f, of: repo)
        return RecipeFieldRow(
            label: s.rowLabel(f, of: repo), stored: text, placeholder: f.hint,
            identifier: "settings.running.field.\(f.rawValue)", source: field.source, note: field.note, first: first,
            inherit: field.source == .repo ? { save(s.clearingField(f, of: repo)) } : nil,
            inheritIdentifier: "settings.running.field.\(f.rawValue).inherit",
            focusOnAppear: focusRequest == f,
            save: { text in await saveNow(s.savingField(f, text, of: repo)) },
            focusChanged: { on, text in fieldFocus(f, on, text) })
            .id("\(repo).\(f.rawValue).\(text)")
    }

    private func openField(_ f: RecipeField) {
        focusRequest = f
        open.insert(f)
    }

    /// A field being edited stays a row; left empty, it goes back to its chip (Rule 9).
    private func fieldFocus(_ f: RecipeField, _ on: Bool, _ text: String) {
        if on {
            open.insert(f)
        } else {
            if focusRequest == f { focusRequest = nil }
            // Ports go back to their table once left; a spine field left empty goes back to its chip.
            if f == .ports || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { open.remove(f) }
        }
    }

    // MARK: Try on the spine

    /// What runs now, the time so far, and Cancel (Rule 4); once it ended, how it went.
    private func tryLine(_ t: TryState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ApiFlow(spacing: 14, lineSpacing: 6) {
                if t.running {
                    Text("Trying \(t.repo) in a throwaway workspace")
                        .foregroundStyle(RunInk.text(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: t.started, by: 1)) { context in
                        Text("· " + tryStatusDetail(tryRows(t).steps, elapsed: context.date.timeIntervalSince(t.started)))
                            .foregroundStyle(RunInk.text(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    RunButton(title: "Cancel", kind: .plain, identifier: "settings.running.tryCancel") { tryTask?.cancel() }
                } else {
                    if let passed = t.passed {
                        Text(passed ? "Last Try passed" : "Last Try failed")
                            .fontWeight(.medium)
                            .foregroundStyle(passed ? RunInk.green : RunInk.redText)
                            .accessibilityIdentifier("settings.running.tryResult")
                    }
                    if let ended = t.ended {
                        Text("· took \(runElapsed(ended.timeIntervalSince(t.started)))").foregroundStyle(RunInk.text(0.62))
                    }
                    // The app's root on the Try's port, never the ready path (design-language §5).
                    if t.ready?.ready == true, let port = t.port {
                        Button(WebLink.label(runAppLabel(port: port))) {
                            openLink(runAppAddress(port: port), NSEvent.modifierFlags.contains(.option))
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.medium)
                        .foregroundStyle(WebLink.colour)
                        .help("Open \(runAppAddress(port: port)) in Wakil's browser; ⌥-click for the system browser")
                        .accessibilityIdentifier("settings.running.tryApp")
                    }
                }
            }
            .font(.system(size: 12.5))
            if let error = t.error { errorText(error, id: "settings.running.tryError") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(RunInk.text(0.03)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.running.tryBox")
    }

    /// A stop's steps as they run: ✓ done with its time, ● running with its time so far and its
    /// last line, ○ to come, ✗ failed. Every line wraps whole.
    private func stepList(_ p: RunStopProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(p.steps, id: \.index) { row in
                let step = row.step
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(step.mark).foregroundStyle(markColour(step.state))
                        Text(step.title)
                            .foregroundStyle(step.state == .toCome ? RunInk.text(0.58) : RunInk.text(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                        if let time = step.time { Text(time).foregroundStyle(RunInk.text(0.58)) }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    if step.state == .running, !step.lastLine.isEmpty {
                        Text(step.lastLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(RunInk.text(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 18)
                            .accessibilityIdentifier("settings.running.tryStep.lastLine")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.running.tryStep.\(row.index)")
            }
        }
        .padding(.top, 8)
    }

    private func markColour(_ state: TryStepState.State) -> Color {
        switch state {
        case .done: RunInk.green
        case .running: RunInk.act
        case .failed: RunInk.red
        case .toCome: RunInk.text(0.58)
        }
    }

    /// The failed step's error whole, under its stop's fields (Rule 8), then the fix: the drafting
    /// conversation's state or proposal, or the action that asks it again.
    @ViewBuilder
    private func failure(_ s: RunningSettings, _ row: RunningRepo, _ step: TryStepState) -> some View {
        let what = step.phase == RunPhase.process && !step.name.isEmpty ? step.name : step.title
        VStack(alignment: .leading, spacing: 4) {
            Text("\(what) failed" + (step.time.map { " after \($0)" } ?? ""))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RunInk.red)
            let body = [step.detail, step.output].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            if !body.isEmpty {
                Text(body)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(RunInk.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(RunInk.red.opacity(0.07)))
        .padding(.top, 10)
        if let d = drafting.draft(row.repo), fixStop(row.repo, d) != nil, d.inFlight || d.proposal != nil || d.line != nil {
            draftBox(s, d).padding(.top, 10)
        } else if let t = tryState, t.repo == row.repo, !t.running, t.passed == false, let report = t.report {
            RunButton(title: "Ask the drafting conversation to fix", kind: .primary, identifier: "settings.running.tryFix") {
                let root = rootPath(row.repo)
                Task { await drafting.fix(row.repo, root, t.tried, report) }
            }
            .padding(.top, 10)
        }
    }

    /// Show output: the step's whole output, opened and closed in place — the page's own
    /// disclosure, a quiet line with ▸ / ▾, not a stock DisclosureGroup.
    private func outputDisclosure(_ shown: TryStepState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showingTryOutput.toggle() } label: {
                Text("\(showingTryOutput ? "▾" : "▸") Show output — \(shown.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(RunInk.text(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.running.tryOutput")
            if showingTryOutput {
                Text(shown.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RunInk.text(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(RunInk.text(0.03)))
            }
        }
        .padding(.top, 8)
    }

    // MARK: ports and environment

    /// Below the spine, past a hairline: not a step, they apply to all of them.
    private func portsAndEnv(_ s: RunningSettings, _ repo: String) -> some View {
        let ports = s.portRows(of: repo)
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(RunInk.hair).frame(height: 0.5)
                .accessibilityElement()
                .accessibilityIdentifier("settings.running.portsAndEnv")
            Text("Ports and environment")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RunInk.text(1))
                .padding(.top, 22)
                .padding(.bottom, 4)
            Text("Each workspace gets ten ports from \(String(runPortBlockStart)). These map the repo's own variables onto "
                + "them, so its files are never rewritten.")
                .font(.system(size: 12))
                .foregroundStyle(RunInk.text(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.bottom, 14)
            RunTwoColumns {
                portsColumn(s, repo, ports)
                envColumn(s, repo)
            }
            if ports.contains(where: { $0.port != nil }) {
                Text("“\(String(runPortBlockStart))” is the first workspace's block; the next one running gets "
                    + "\(String(runPortBlockStart + runPortBlockSize)).")
                    .font(.system(size: 12))
                    .foregroundStyle(RunInk.text(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(RunInk.text(0.72)).padding(.bottom, 6)
    }

    /// The ports as a table — variable → expression → its port in the first block — edited as the
    /// spine's rows are, a line a mapping, from Edit (or + Port when there are none).
    private func portsColumn(_ s: RunningSettings, _ repo: String, _ ports: [RunPortRow]) -> some View {
        let field = s.field(.ports, of: repo)
        return VStack(alignment: .leading, spacing: 0) {
            columnTitle("Ports")
            if open.contains(.ports) {
                fieldRow(s, repo, .ports, first: true)
            } else {
                if !ports.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 0) {
                        ForEach(ports, id: \.variable) { p in
                            GridRow {
                                Text(p.variable).font(.system(size: 12, design: .monospaced)).foregroundStyle(RunInk.text(0.86))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("→").font(.system(size: 12)).foregroundStyle(RunInk.text(0.58))
                                Text(p.expression).font(.system(size: 12, design: .monospaced)).foregroundStyle(RunInk.text(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(p.port.map { String($0) } ?? "").font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(RunInk.text(0.58))
                                    .gridColumnAlignment(.trailing)
                            }
                            .padding(.vertical, 6)
                            GridRow { Rectangle().fill(RunInk.hair).frame(height: 0.5).gridCellColumns(4) }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.running.ports")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if field.source != .none {
                        Text(field.source.label).foregroundStyle(field.source == .repo ? RunInk.act : RunInk.text(0.58))
                    }
                    if let note = field.note { Text(note).foregroundStyle(RunInk.text(0.58)).fixedSize(horizontal: false, vertical: true) }
                    if field.source == .repo {
                        Button("Use the recipe's") { save(s.clearingField(.ports, of: repo)) }
                            .buttonStyle(.plain)
                            .font(.system(size: SettingsScale.body))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.70))
                            .accessibilityIdentifier("settings.running.field.ports.inherit")
                    }
                }
                .font(.system(size: 10.5))
                .padding(.top, ports.isEmpty ? 0 : 6)
                if ports.isEmpty {
                    Text("None mapped.").font(.system(size: 12)).foregroundStyle(RunInk.text(0.62)).padding(.bottom, 4)
                    RunChip(word: "Port", identifier: "settings.running.add.ports") { openField(.ports) }
                } else {
                    RunButton(title: "Edit ports", kind: .quiet, identifier: "settings.running.ports.edit") { openField(.ports) }
                        .padding(.leading, -12)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// The repo's variables, then + Variable and + Secret; a secret goes to the Keychain.
    private func envColumn(_ s: RunningSettings, _ repo: String) -> some View {
        let rows = s.env(of: repo)
        return VStack(alignment: .leading, spacing: 4) {
            columnTitle("Environment")
            if rows.isEmpty {
                Text("None set. Values may use $WAKIL_*; a secret goes to the Keychain.")
                    .font(.system(size: 12))
                    .foregroundStyle(RunInk.text(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows, id: \.name) { row in
                ApiFlow(spacing: 8, lineSpacing: 2) {
                    Text(row.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(RunInk.text(0.86))
                    switch row.value {
                    case .value(let v): Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(RunInk.text(0.92))
                    case .secret: Text("•••••••• 🔒 Keychain").font(.system(size: 12)).foregroundStyle(RunInk.text(0.72))
                    }
                    Text(row.source.label + (row.value.isSecret ? " · secret" : ""))
                        .font(.system(size: 10.5))
                        .foregroundStyle(row.source == .repo ? RunInk.act : RunInk.text(0.58))
                    if row.source == .repo {
                        Button("Remove") { save(s.savingEnv(row.name, nil, of: repo)) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(RunInk.text(0.72))
                            .accessibilityIdentifier("settings.running.env.\(row.name).remove")
                    }
                }
                .padding(.vertical, 4)
                // .contain: without it the row's id lands on every child, Remove included,
                // and the row's own id names four elements (piece 2's e2e run).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.running.env.\(row.name)")
            }
            if addingEnv {
                ApiFlow(spacing: 6, lineSpacing: 6) {
                    TextField("VARIABLE", text: $newVariable)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .fieldBox(width: 150)
                        .focused($envNameFocused)
                        .accessibilityIdentifier("settings.running.env.newName")
                    Group {
                        if newSecret {
                            SecureField("value", text: $newValue)
                        } else {
                            TextField("value, may use $WAKIL_*", text: $newValue)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .fieldBox(width: 190)
                    .accessibilityIdentifier("settings.running.env.newValue")
                    Toggle("🔒 secret", isOn: $newSecret)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings.running.env.newSecret")
                    FormButton(title: "Add", tone: RunInk.act, identifier: "settings.running.env.add") {
                        addVariable(s, repo)
                    }
                    .disabled(newVariable.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 4)
            } else {
                ApiFlow(spacing: 6, lineSpacing: 6) {
                    RunChip(word: "Variable", identifier: "settings.running.env.addVariable") { startAddingEnv(secret: false) }
                    RunChip(word: "Secret", identifier: "settings.running.env.addSecret") { startAddingEnv(secret: true) }
                }
                .padding(.top, 4)
            }
            Toggle("Also write to the worktree's .env", isOn: Binding(
                get: { s.alsoWritesEnvFile(repo) },
                set: { save(s.savingAlsoWriteEnvFile($0, of: repo)) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(RunInk.text(0.86))
                .padding(.top, 8)
                .accessibilityIdentifier("settings.running.env.alsoWrite")
            Text("Applied to every command of this repo in every workspace. \".env\" is the copy's own (ignored by "
                + "git); your folder's is never touched.")
                .font(.system(size: 11.5))
                .foregroundStyle(RunInk.text(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// + Variable / + Secret: the new variable's row, its name focused (Rule 3).
    private func startAddingEnv(secret: Bool) {
        newSecret = secret
        addingEnv = true
        Task { @MainActor in envNameFocused = true }
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
        open = []
        focusRequest = nil
        addingEnv = false
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
            addingEnv = false
        }
    }

    private func rootPath(_ repo: String) -> String {
        project.roots.first { ($0.path as NSString).lastPathComponent == repo }?.path ?? settings?.repo(repo)?.path ?? ""
    }

    private func startTry(_ row: RunningRepo) {
        endTry()
        let root = rootPath(row.repo)
        let tried = row.effective?.recipe ?? Recipe()
        let began = Date()
        tryState = TryState(repo: row.repo, running: true, steps: [], started: began, tried: tried)
        tryTask = Task {
            let (r, error) = await dispatch("running_try", .object([
                "repo": .string(row.repo), "root": .string(root), "project": .string(project.name),
                "environment": .string(environment), "projectPath": .string(project.path),
            ]))
            var state = TryState(repo: row.repo, running: false, steps: [], started: began, ended: Date(), tried: tried)
            if Task.isCancelled { state.error = "Try was cancelled." }
            if let error { state.error = error }
            if case .object(let o)? = r {
                if case .string(let w)? = o["workspace"] { state.workspace = w }
                if case .integer(let port)? = o["port"] { state.port = Int(port) }
                // The Try's workspace went with it; a copy with changes was kept, said whole (Rule 8).
                if case .string(let kept)? = o["kept"] { refusal = kept }
                if let report = try? decodeTry(.object(o)) {
                    state.report = report
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
