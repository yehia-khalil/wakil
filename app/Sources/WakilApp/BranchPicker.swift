import SwiftUI
import WakilKit

/// What the branch picker does with the window (3a-iv), handed in as closures like the panes' writes.
struct BranchPickerActions {
    var load: (String) async -> GitBranchesInfo? = { _ in nil }
    var switchTo: (_ root: String, _ branch: String, _ carry: String?, _ track: String?) async -> ChangesSwitchOutcome = { _, _, _, _ in .refused("") }
    var create: (_ root: String, _ name: String, _ from: String?) async -> ChangesSwitchOutcome = { _, _, _ in .refused("") }
    var fetch: (String) async -> Void = { _ in }
    /// Delete Branch…: the root, the branch, and force (it has commits no other branch has).
    var delete: (_ root: String, _ branch: String, _ force: Bool) async -> String? = { _, _, _ in nil }
    /// 3a-v-b: Merge Branch… and Rebase Branch… — nil when done or stopped on conflicts (the note is left
    /// under the root's box), else git's refusal.
    var merge: (_ root: String, _ branch: String) async -> String? = { _, _ in nil }
    var rebase: (_ root: String, _ onto: String) async -> String? = { _, _ in nil }
}

/// What the picker is for: switching (the default), choosing the base of a new branch (▾ Create
/// Branch From…), choosing the branch to delete (▾ Delete Branch…), or the branch to merge in or
/// rebase onto (▾ Merge Branch…, Rebase Branch…, 3a-v-b).
enum BranchPickerMode { case switchBranch, createFrom, delete, merge, rebase }

/// The branch picker — VS Code's Quick Pick (spec, calls 1–2, 5): a filter field that takes the
/// keyboard, the roots as tabs when there are several, **Create branch "…"**, **Create branch from…**,
/// the local branches, the remote ones, and **Fetch**. ↑↓ move, Return picks, Escape closes. A switch
/// git refuses for changes in the way offers Stash and Switch, Bring Them Along, or Cancel, in place.
struct BranchPicker: View {
    let roots: [GitRootState]
    let startRoot: String
    let actions: BranchPickerActions
    var mode: BranchPickerMode = .switchBranch
    let close: () -> Void

    @State private var root = ""
    @State private var filter = ""
    @State private var branches: GitBranchesInfo?
    @State private var selected = 0
    @State private var working: Task<Void, Never>?
    @State private var message: String?
    /// A switch refused for changes in the way: what to switch to, and the paths.
    @State private var blocked: (branch: String, track: String?, paths: [String])?
    /// Create branch from…: the base chosen, then the name typed into the filter field.
    @State private var choosingBase = false
    /// The branch a switch in flight is for, and the remote branch it tracks: a refusal names it.
    @State private var target: (branch: String, track: String?)?
    /// Delete Branch…: the branch picked, asking in place before it goes (Rule 1).
    @State private var deleting: GitBranchInfo?
    @State private var base: String?
    @FocusState private var filterFocused: Bool

    private var rows: [BranchPickerRow] {
        guard let branches else { return [] }
        if mode == .delete {
            return branches.local.filter { !$0.current && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
                .map(BranchPickerRow.local)
        }
        // Merge and Rebase: the local branches but the current one, then the remote ones.
        if mode == .merge || mode == .rebase {
            func matches(_ name: String) -> Bool { filter.isEmpty || name.localizedCaseInsensitiveContains(filter) }
            return branches.local.filter { !$0.current && matches($0.name) }.map(BranchPickerRow.local)
                + branches.remote.filter(matches).map(BranchPickerRow.remote)
        }
        if choosingBase { return branches.local.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.map(BranchPickerRow.local) }
        if base != nil { return normaliseBranchName(filter).isEmpty ? [] : [.create(normaliseBranchName(filter))] }
        return branchPickerRows(branches, filter: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if roots.count > 1 { rootTabs }
            TextField(prompt, text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .focused($filterFocused)
                .onSubmit { pick(selected) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                // Escape steps back out of Create branch from… before it closes the picker.
                .onExitCommand {
                    if mode == .switchBranch, choosingBase || base != nil { reset(); selected = defaultSelection } else { close() }
                }
                .onChange(of: filter) { _, _ in selected = defaultSelection }
                .disabled(working != nil || blocked != nil || deleting != nil)
                .accessibilityIdentifier("branch.picker.filter")
            Rectangle().fill(SettingsPalette.coolWhite.opacity(0.08)).frame(height: 0.5)
            if let blocked {
                blockedChoice(blocked)
            } else if let deleting {
                deleteChoice(deleting)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in rowView(row, index: i) }
                        // A base chosen and no name yet: say so rather than show an empty list.
                        if let base, rows.isEmpty {
                            Text("Type the new branch's name; it starts from \(base). Escape cancels.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.5))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }
                // A definite height: in a popover a ScrollView has no ideal height of its own, and the
                // rows drew nothing (3a-iv e2e audit).
                .frame(height: min(CGFloat(max(rows.count, 1)) * 27, 320))
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityIdentifier("branch.picker.message")
            }
        }
        .frame(width: 340)
        .task {
            if root.isEmpty { root = startRoot }
            if mode == .createFrom { choosingBase = true }
            branches = await actions.load(root)
            selected = defaultSelection
            // A beat after appearing: focus set as the field appears is dropped (3a-iii's sheet fix).
            try? await Task.sleep(for: .milliseconds(150))
            filterFocused = true
        }
        .onDisappear { working?.cancel() }
    }

    /// The current branch with nothing typed (Return then closes); the first row once typing.
    private var defaultSelection: Int {
        guard mode == .switchBranch, !choosingBase, base == nil else { return 0 }
        return branchPickerDefaultSelection(rows, filter: filter)
    }

    private var prompt: String {
        if mode == .delete { return "Choose the branch to delete" }
        if mode == .merge { return "Choose the branch to merge in" }
        if mode == .rebase { return "Choose the branch to rebase onto" }
        if choosingBase { return "Choose the branch to start from" }
        if let base { return "Name the new branch (from \(base))" }
        return "Switch to a branch, or type a new name"
    }

    private var rootTabs: some View {
        HStack(spacing: 4) {
            ForEach(roots, id: \.root) { r in
                Button {
                    root = r.root
                    reset()
                    Task { branches = await actions.load(r.root) }
                } label: {
                    Text("\(r.name) · \(r.branch.isEmpty ? r.detached : r.branch)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(root == r.root ? 0.95 : 0.55))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(SettingsPalette.coolWhite.opacity(root == r.root ? 0.09 : 0)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("branch.picker.root.\(r.name)")
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func rowView(_ row: BranchPickerRow, index: Int) -> some View {
        let (title, detail, id) = describe(row)
        Button { pick(index) } label: {
            HStack(spacing: 8) {
                if case .local(let b) = row, b.current {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(SettingsPalette.accent)
                } else {
                    Color.clear.frame(width: 10)
                }
                Text(title)
                    .font(.system(size: 12.5, design: row.isBranch ? .monospaced : .default))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if case .fetch = row, working != nil { ProgressView().controlSize(.mini) }
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.45))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == index ? SettingsPalette.accent.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working != nil)
        .accessibilityIdentifier(id)
    }

    private func describe(_ row: BranchPickerRow) -> (String, String, String) {
        switch row {
        case .create(let name):
            return (base == nil ? "Create branch \u{201C}\(name)\u{201D}" : "Create \u{201C}\(name)\u{201D} from \(base ?? "")", "", "branch.picker.create")
        case .createFrom: return ("Create branch from…", "", "branch.picker.createFrom")
        case .local(let b):
            let track = [b.ahead > 0 ? "↑\(b.ahead)" : "", b.behind > 0 ? "↓\(b.behind)" : ""].filter { !$0.isEmpty }.joined(separator: " ")
            return (b.name, track.isEmpty ? b.upstream : track, "branch.picker.row.\(b.name)")
        case .remote(let r): return (r, "remote", "branch.picker.row.\(r)")
        case .fetch: return ("Fetch", working != nil ? "Fetching…" : "", "branch.picker.fetch")
        }
    }

    private func move(_ by: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + by, 0), rows.count - 1)
    }

    private func reset() {
        filter = ""
        selected = 0
        message = nil
        blocked = nil
        choosingBase = false
        base = nil
    }

    private func pick(_ index: Int) {
        guard working == nil, rows.indices.contains(index) else { return }
        switch rows[index] {
        case .createFrom:
            choosingBase = true
            filter = ""
        case .local(let b) where mode == .delete:
            deleting = b
        case .local(let b) where mode == .merge || mode == .rebase:
            operate(b.name)
        case .remote(let r) where mode == .merge || mode == .rebase:
            operate(r)
        case .local(let b) where choosingBase:
            choosingBase = false
            base = b.name
            filter = ""
        case .local(let b):
            if b.current { close(); return }
            target = (b.name, nil)
            run { await actions.switchTo(root, b.name, nil, nil) }
        case .remote(let r):
            let local = r.split(separator: "/", maxSplits: 1).last.map(String.init) ?? r
            target = (local, r)
            run { await actions.switchTo(root, local, nil, r) }
        case .create(let name):
            let from = base
            run { await actions.create(root, name, from) }
        case .fetch:
            working = Task {
                await actions.fetch(root)
                branches = await actions.load(root)
                working = nil
            }
        }
    }

    /// Runs a switch as the picker's work in flight (Rule 5); a pick closes the picker on success and
    /// leaves the operator where they were (Rule 6).
    private func run(_ body: @escaping @MainActor () async -> ChangesSwitchOutcome) {
        message = nil
        working = Task {
            let outcome = await body()
            working = nil
            handle(outcome)
        }
    }

    /// Merges `branch` in, or rebases onto it, as the picker's work in flight (Rules 4, 5): the picker
    /// closes once git is done or stopped on conflicts — the Changes list then shows them (Rule 6) — and
    /// stays with git's refusal, whole (Rule 8).
    private func operate(_ branch: String) {
        let rebase = mode == .rebase
        message = nil
        working = Task {
            let refusal = rebase ? await actions.rebase(root, branch) : await actions.merge(root, branch)
            working = nil
            if let refusal, !refusal.isEmpty { message = refusal } else { close() }
        }
    }

    private func handle(_ outcome: ChangesSwitchOutcome) {
        switch outcome {
        case .switched: close()
        case .refused(let why): message = why.isEmpty ? nil : why
        case .blocked(let paths):
            if let target { blocked = (target.branch, target.track, paths) }
        }
    }

    private func deleteChoice(_ b: GitBranchInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(deleteBranchConfirmation(b, current: branches?.current ?? "HEAD"))
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.caution)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("branch.picker.delete.confirmation")
            HStack(spacing: 6) {
                FormButton(title: "Keep it", tone: SettingsPalette.coolWhite, identifier: "branch.picker.delete.keep") {
                    deleting = nil
                }
                FormButton(title: "Delete", tone: SettingsPalette.caution, filled: true, identifier: "branch.picker.delete.confirm") {
                    let force = b.unmerged > 0
                    deleting = nil
                    working = Task {
                        let refusal = await actions.delete(root, b.name, force)
                        working = nil
                        if let refusal, !refusal.isEmpty { message = refusal } else { close() }
                    }
                }
            }
        }
        .padding(12)
    }

    private func blockedChoice(_ b: (branch: String, track: String?, paths: [String])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your changes to \(b.paths.joined(separator: ", ")) would be overwritten by \(b.branch).")
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("branch.picker.blocked")
            HStack(spacing: 6) {
                FormButton(title: "Stash and Switch", tone: SettingsPalette.accent, filled: true, identifier: "branch.picker.blocked.stash") {
                    blocked = nil
                    run { await actions.switchTo(root, b.branch, "stash", b.track) }
                }
                FormButton(title: "Bring Them Along", tone: SettingsPalette.coolWhite, identifier: "branch.picker.blocked.bring") {
                    blocked = nil
                    run { await actions.switchTo(root, b.branch, "bring", b.track) }
                }
                FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "branch.picker.blocked.cancel") {
                    blocked = nil
                }
            }
        }
        .padding(12)
    }
}

private extension BranchPickerRow {
    var isBranch: Bool {
        switch self {
        case .local, .remote: true
        default: false
        }
    }
}
