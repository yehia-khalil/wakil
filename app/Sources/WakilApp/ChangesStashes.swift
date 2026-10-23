import SwiftUI
import WakilKit

/// 3a-iv: the stash and branch writes the Changes view reaches, handed in from the window as closures.
struct BranchStashControls {
    var stashes: (String) async -> [GitStashInfo] = { _ in [] }
    var stash: (_ root: String, _ message: String, _ mode: String) async -> String? = { _, _, _ in nil }
    var apply: (_ root: String, _ stash: GitStashInfo, _ pop: Bool) async -> String? = { _, _, _ in nil }
    var drop: (_ root: String, _ stash: GitStashInfo) async -> String? = { _, _ in nil }
    var dropAll: (_ root: String, _ shown: [GitStashInfo]) async -> String? = { _, _ in nil }
    var rename: (_ root: String, _ to: String) async -> String? = { _, _ in nil }
    var create: (_ root: String, _ name: String) async -> ChangesSwitchOutcome = { _, _ in .refused("") }
    var openStashFile: (_ root: String, _ path: String, _ stash: String, _ untracked: Bool) async -> Void = { _, _, _, _ in }
}

/// What the in-place field under a root's header is for.
enum ChangesNameFieldKind: Equatable {
    case create, rename(current: String), stash(mode: String)

    var prompt: String {
        switch self {
        case .create: "New branch name"
        case .rename: "New name for the branch"
        case .stash: "Message (optional)"
        }
    }
    var action: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        case .stash: "Stash"
        }
    }
}

/// The in-place field for Create Branch…, Rename Branch… and Stash (spec call 5): focused when it
/// appears (Rule 3); Return or its button runs it; leaving keeps the text and the field open (Rule 2) —
/// leaving never stashes or renames by accident; Escape closes it.
struct ChangesNameField: View {
    let root: GitRootState
    let kind: ChangesNameFieldKind
    let busy: Bool
    let run: (String) -> Void
    let close: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(kind.prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(EditorPaneStyle.lifted))
                .focused($focused)
                .onSubmit { go() }
                .onExitCommand { close() }
                .disabled(busy)
                .accessibilityIdentifier("editor.changes.\(root.name).nameField")
            Button(kind.action) { go() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                .disabled(busy || (!isStash && text.trimmingCharacters(in: .whitespaces).isEmpty))
                .accessibilityIdentifier("editor.changes.\(root.name).nameField.go")
            Button("Cancel") { close() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.55))
                .accessibilityIdentifier("editor.changes.\(root.name).nameField.cancel")
        }
        .padding(.top, EditorColumn.ChangesSpace.s)
        .task {
            if case .rename(let current) = kind { text = current }
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
        }
    }

    private var isStash: Bool { if case .stash = kind { true } else { false } }

    private func go() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !busy, isStash || !t.isEmpty else { return }
        run(t)
    }
}

/// A root's **Stashes** group (spec call 3): collapsed by default, absent with no stash. Each row reads
/// `message · on branch · age` with Apply, Pop and Drop on hover; a row opens into its files, and a file
/// opens read-only against the stash's base. Drop and Drop All ask in place (Rule 1).
struct ChangesStashesGroup: View {
    let root: GitRootState
    let controls: BranchStashControls
    let busy: Bool
    /// Changes when the root's status does, so the list is read again after a stash or a pop.
    let refreshKey: String

    @State private var stashes: [GitStashInfo] = []
    @State private var open = false
    @State private var expanded: Set<String> = []
    @State private var hovered: String?
    @State private var confirming: String?   // a stash id, or "all"

    var body: some View {
        Group {
            if !stashes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if open { ForEach(stashes) { row($0) } }
                }
                .padding(.top, EditorColumn.ChangesSpace.s)
            }
        }
        .task(id: refreshKey) { stashes = await controls.stashes(root.root) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: EditorColumn.ChangesSpace.s) {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        Text("Stashes").font(.system(size: 10.5, weight: .semibold))
                        Text("\(stashes.count)").font(.system(size: 10.5)).foregroundStyle(EditorPaneStyle.text.opacity(0.5))
                    }
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editor.changes.\(root.name).stashes")
                Spacer(minLength: 0)
                if open {
                    Button("Drop All…") { confirming = "all" }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.5))
                        .disabled(busy)
                        .accessibilityIdentifier("editor.changes.\(root.name).stashes.dropAll")
                }
            }
            if confirming == "all" {
                confirm(dropAllStashesConfirmation(stashes.count),
                        keepId: "editor.changes.\(root.name).stashes.dropAll.keep",
                        confirmId: "editor.changes.\(root.name).stashes.dropAll.confirm") {
                    let shown = stashes
                    Task { _ = await controls.dropAll(root.root, shown); stashes = await controls.stashes(root.root) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ s: GitStashInfo) -> some View {
        let id7 = String(s.id.prefix(7))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { if expanded.contains(s.id) { expanded.remove(s.id) } else { expanded.insert(s.id) } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded.contains(s.id) ? "chevron.down" : "chevron.right").font(.system(size: 7, weight: .semibold))
                        Text(([s.message, s.branch.isEmpty ? "" : "on \(s.branch)", age(s.date)].filter { !$0.isEmpty }).joined(separator: " · "))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.82))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editor.changes.\(root.name).stash.\(id7)")
                Spacer(minLength: 0)
                // Always there, so VoiceOver and the checks reach them; quiet until the row is hovered.
                Group {
                    action("Apply", "editor.changes.\(root.name).stash.\(id7).apply") {
                        Task { _ = await controls.apply(root.root, s, false); stashes = await controls.stashes(root.root) }
                    }
                    action("Pop", "editor.changes.\(root.name).stash.\(id7).pop") {
                        Task { _ = await controls.apply(root.root, s, true); stashes = await controls.stashes(root.root) }
                    }
                    action("Drop", "editor.changes.\(root.name).stash.\(id7).drop") { confirming = s.id }
                }
                .opacity(hovered == s.id || confirming == s.id ? 1 : 0.35)
            }
            .padding(.leading, EditorColumn.ChangesSpace.m)
            .padding(.vertical, 3)
            .onHover { inside in hovered = inside ? s.id : (hovered == s.id ? nil : hovered) }
            if confirming == s.id {
                confirm(dropStashConfirmation(s),
                        keepId: "editor.changes.\(root.name).stash.\(id7).drop.keep",
                        confirmId: "editor.changes.\(root.name).stash.\(id7).drop.confirm") {
                    Task { _ = await controls.drop(root.root, s); stashes = await controls.stashes(root.root) }
                }
                .padding(.leading, EditorColumn.ChangesSpace.m)
            }
            if expanded.contains(s.id) {
                ForEach(s.files, id: \.self) { file in
                    Button {
                        Task { await controls.openStashFile(root.root, file, s.id, s.untracked.contains(file)) }
                    } label: {
                        Text(file)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(EditorPaneStyle.text.opacity(0.7))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, EditorColumn.ChangesSpace.m * 2 + 4)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("editor.changes.\(root.name).stash.\(id7).file:\(file)")
                }
            }
        }
    }

    private func action(_ title: String, _ id: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(EditorPaneStyle.text.opacity(0.75))
            .disabled(busy)
            .accessibilityIdentifier(id)
    }

    private func confirm(_ text: String, keepId: String, confirmId: String, _ go: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.910, green: 0.706, blue: 0.353))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Keep it") { confirming = nil }
                .buttonStyle(.plain).font(.system(size: 10.5))
                .accessibilityIdentifier(keepId)
            Button("Drop") { confirming = nil; go() }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(red: 0.910, green: 0.706, blue: 0.353))
                .accessibilityIdentifier(confirmId)
        }
        .padding(.vertical, 4)
    }

    private func age(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(s / 60) min ago"
        case ..<86_400: return "\(s / 3600) h ago"
        default: return "\(s / 86_400) d ago"
        }
    }
}
