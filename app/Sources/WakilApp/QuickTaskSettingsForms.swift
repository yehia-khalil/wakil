import SwiftUI
import WakilKit

/// The organisation's local models (3b-viii): one row per `local` provider, and an
/// "Add local model" control at the end of the list. Drawn in the Providers node.
struct LocalProvidersSection: View {
    let providers: [SettingsProvider]
    /// Each provider's last error whole and which have answered (`WindowModel.quickTaskStatus()`).
    /// Nil until the first read lands: no status is drawn before then.
    let status: QuickTaskStatus?
    /// Saves one local provider (id, label, URL, ticked operations); answers the refusal or nil.
    let save: (String, String, String, Set<QuickOperation>) async -> String?

    /// The id of a row being added and not yet saved. A saved row comes back in `providers`.
    @State private var adding: String?

    private var local: [SettingsProvider] { providers.filter { $0.kind == "local" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOCAL MODELS")
                .font(.system(size: SettingsScale.micro, weight: .medium))
                .tracking(SettingsScale.microTracking)
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.32))
            ForEach(local, id: \.id) { provider in
                LocalProviderRow(
                    id: provider.id, label: provider.label, baseURL: provider.baseURL,
                    serves: Set(provider.serves.compactMap(QuickOperation.init(rawValue:))),
                    isNew: false,
                    status: status.map { localProviderStatus(id: provider.id, errors: $0.errors, answered: $0.answered) },
                    failing: status?.errors[provider.id] != nil, save: save, onSaved: {}, onDismiss: {})
            }
            if let adding, !local.contains(where: { $0.id == adding }) {
                LocalProviderRow(
                    id: adding, label: "", baseURL: "", serves: Set(newLocalProviderServes().compactMap(QuickOperation.init(rawValue:))),
                    isNew: true, status: nil, failing: false, save: save,
                    onSaved: { self.adding = nil }, onDismiss: { self.adding = nil })
            }
            Button("Add local model") { adding = firstUnusedId() }
                .buttonStyle(.plain)
                .font(.system(size: SettingsScale.door))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.70))
                .disabled(adding != nil)
                .accessibilityIdentifier("settings.localProvider.add")
        }
        .padding(.top, 10)
    }

    /// `local`, else `local-2`, `local-3`, … the first no provider uses.
    private func firstUnusedId() -> String {
        let used = Set(providers.map(\.id))
        if !used.contains("local") { return "local" }
        var n = 2
        while used.contains("local-\(n)") { n += 1 }
        return "local-\(n)"
    }
}

/// One local model: its URL, what it serves, and whether it answers.
private struct LocalProviderRow: View {
    let id: String
    let label: String
    let baseURL: String
    let serves: Set<QuickOperation>
    let isNew: Bool
    let status: String?
    let failing: Bool
    let save: (String, String, String, Set<QuickOperation>) async -> String?
    let onSaved: () -> Void
    /// An empty new row is dismissed (Esc, or focus leaving it with no URL), so Add comes back.
    let onDismiss: () -> Void

    /// What is typed. Kept when focus leaves, and when a save is refused (Rule 2).
    @State private var draft: String = ""
    @State private var ticked: Set<QuickOperation> = []
    @State private var refusal: String?
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((label.isEmpty ? id : label).uppercased())
                .font(.system(size: SettingsScale.micro, weight: .medium))
                .tracking(SettingsScale.microTracking)
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.32))
            HStack(spacing: 8) {
                Text("URL")
                    .font(.system(size: SettingsScale.meta, weight: .medium)).tracking(0.8)
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.42))
                TextField("http://127.0.0.1:8012", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsScale.identifier, design: .monospaced))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.90))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: 360)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(SettingsPalette.coolWhite.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(SettingsPalette.coolWhite.opacity(0.14), lineWidth: 0.5)))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { if isNew, draft.trimmingCharacters(in: .whitespaces).isEmpty { onDismiss() } }
                    .accessibilityLabel("local model URL")
                    .accessibilityIdentifier("settings.localProvider.\(id).url")
            }
            HStack(spacing: 14) {
                Text("Serves")
                    .font(.system(size: SettingsScale.meta, weight: .medium)).tracking(0.8)
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.42))
                serveToggle("Code completion", .infill, identifier: "settings.localProvider.\(id).serves.infill")
                serveToggle("Instructions", .respond, identifier: "settings.localProvider.\(id).serves.respond")
            }
            if !isNew, let status {
                // The error whole (Rule 8): wrapped, never truncated.
                Text(status)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(failing ? SettingsPalette.caution : SettingsPalette.coolWhite.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.localProvider.\(id).status")
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.localProvider.\(id).refusal")
            }
        }
        .padding(.bottom, 6)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = baseURL
            ticked = serves
            // Rule 3: a new input arrives focused.
            if isNew { focused = true }
        }
        .onChange(of: baseURL) { _, new in if !focused, refusal == nil { draft = new } }
        .onChange(of: serves) { _, new in ticked = new }
        // Rule 2: leaving the field saves what was typed, and keeps it on screen.
        .onChange(of: focused) { _, now in
            guard !now else { return }
            if isNew, draft.trimmingCharacters(in: .whitespaces).isEmpty { onDismiss() } else { commit() }
        }
    }

    private func serveToggle(_ title: String, _ operation: QuickOperation, identifier: String) -> some View {
        Toggle(isOn: Binding(
            get: { ticked.contains(operation) },
            set: { on in
                if on { ticked.insert(operation) } else { ticked.remove(operation) }
                commit()
            })) {
            Text(title)
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.70))
        }
        .toggleStyle(.checkbox)
        // Rule 9: a local model serves something, so the last ticked box cannot be unticked — an
        // empty set would be saved as code completion and snap back. Ticking the other frees it.
        .disabled(ticked == [operation])
        .accessibilityIdentifier(identifier)
    }

    /// Saves when there is something to say: a stored row with a changed URL or ticks, or a new
    /// row with a URL. An empty new row saves nothing (Rule 9: nothing is demanded of it).
    private func commit() {
        let url = draft.trimmingCharacters(in: .whitespaces)
        if isNew, url.isEmpty { return }
        if !isNew, url == baseURL, ticked == serves { return }
        Task {
            refusal = await save(id, label, url, ticked)
            if refusal == nil { onSaved() }
        }
    }
}
