import SwiftUI
import WakilKit

/// The organisation's local models (3b-viii): one table row per `local` provider, as the
/// database rows are drawn, and a "+ Add local model" door after the list. Drawn in the
/// Providers node.
struct LocalProvidersSection: View {
    let providers: [SettingsProvider]
    /// Each provider's last error whole and which have answered (`WindowModel.quickTaskStatus()`).
    /// Nil until the first read lands: no status is drawn before then.
    let status: QuickTaskStatus?
    /// Saves one local provider (id, label, URL); answers the refusal or nil.
    let save: (String, String, String) async -> String?
    /// Removes one local provider by id; answers the refusal or nil.
    let remove: (String) async -> String?

    /// The id of a row being added and not yet saved. A saved row comes back in `providers`.
    @State private var adding: String?

    private var local: [SettingsProvider] { providers.filter { $0.kind == "local" } }

    var body: some View {
        // Headed by the page's LOCAL MODELS section (`SettingsSection`), not by itself.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(local, id: \.id) { provider in
                LocalProviderRow(
                    id: provider.id, label: provider.label, baseURL: provider.baseURL,
                    isNew: false,
                    status: status.map { localProviderStatus(id: provider.id, errors: $0.errors, answered: $0.answered) },
                    failing: status?.errors[provider.id] != nil, save: save,
                    remove: { await remove(provider.id) }, onSaved: {}, onDismiss: {})
            }
            if let adding, !local.contains(where: { $0.id == adding }) {
                LocalProviderRow(
                    id: adding, label: "", baseURL: "", isNew: true, status: nil, failing: false, save: save, remove: { nil },
                    onSaved: { self.adding = nil }, onDismiss: { self.adding = nil })
            }
            Button("+ Add local model") { adding = firstUnusedId() }
                .buttonStyle(.plain)
                .font(.system(size: SettingsScale.door))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(adding == nil ? 0.70 : 0.30))
                .disabled(adding != nil)
                .padding(.top, 10)
                .accessibilityIdentifier("settings.localProvider.add")
        }
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

/// One local model, as a table row: its name, its URL edited in place with whether it answers
/// beside it, and REMOVE (CANCEL while it is not yet saved).
private struct LocalProviderRow: View {
    let id: String
    let label: String
    let baseURL: String
    let isNew: Bool
    let status: String?
    let failing: Bool
    let save: (String, String, String) async -> String?
    let remove: () async -> String?
    let onSaved: () -> Void
    /// An empty new row is dismissed (Esc, CANCEL, or focus leaving it with no URL), so Add comes back.
    let onDismiss: () -> Void

    /// What is typed. Kept when focus leaves, and when a save is refused (Rule 2).
    @State private var draft: String = ""
    @State private var refusal: String?
    @State private var loaded = false
    @State private var hovering = false
    /// Set by CANCEL, so a focus change on the way out saves nothing.
    @State private var cancelled = false
    @FocusState private var focused: Bool

    private var coolWhite: Color { SettingsPalette.coolWhite }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsScale.columnGap) {
            Text(isNew ? "New model" : (label.isEmpty ? id : label))
                .font(.system(size: SettingsScale.body, weight: .medium))
                .foregroundStyle(coolWhite.opacity(isNew ? 0.45 : 0.86))
                .lineLimit(1)
                .frame(width: SettingsScale.labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    urlField
                    if !isNew, let status, !failing {
                        HStack(spacing: 5) {
                            Circle().fill(coolWhite.opacity(status == "reachable" ? 0.70 : 0.25))
                                .frame(width: 5, height: 5)
                            Text(status)
                                .font(.system(size: SettingsScale.meta))
                                .foregroundStyle(coolWhite.opacity(status == "reachable" ? 0.62 : 0.38))
                                .lineLimit(1).fixedSize()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.localProvider.\(id).status")
                    }
                }
                if !isNew, failing, let status {
                    // The error whole (Rule 8): wrapped, never truncated.
                    Text(status)
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.caution)
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
            Spacer(minLength: 0)
            rowAction
        }
        .padding(.vertical, 10)
        .frame(minHeight: SettingsScale.rowHeight, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(coolWhite.opacity(0.06)).frame(height: 0.5) }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = baseURL
            // Rule 3, one turn late: set in the update that inserts the row, the field has no
            // AppKit view yet and the keyboard stays on the settings tree.
            if isNew { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: baseURL) { _, new in if !focused, refusal == nil { draft = new } }
        // Rule 2: leaving the field saves what was typed, and keeps it on screen.
        .onChange(of: focused) { _, now in
            guard !now, !cancelled else { return }
            if isNew, draft.trimmingCharacters(in: .whitespaces).isEmpty { onDismiss() } else { commit() }
        }
    }

    /// Plain monospace text that is edited where it stands; the box shows only on hover or focus.
    private var urlField: some View {
        TextField("http://127.0.0.1:8012", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: SettingsScale.identifier, design: .monospaced))
            .foregroundStyle(coolWhite.opacity(0.90))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(coolWhite.opacity(focused || hovering ? 0.05 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(coolWhite.opacity(focused ? 0.18 : hovering ? 0.10 : 0), lineWidth: 0.5)))
            .padding(.horizontal, -6)
            .onHover { hovering = $0 }
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { if isNew, draft.trimmingCharacters(in: .whitespaces).isEmpty { onDismiss() } }
            .accessibilityLabel("local model URL")
            .accessibilityIdentifier("settings.localProvider.\(id).url")
    }

    /// REMOVE on a saved model, with no confirmation (Rule 1: it holds no credential and adding it
    /// again restores it); CANCEL on one being added, which saves nothing.
    private var rowAction: some View {
        Button(isNew ? "CANCEL" : "REMOVE") {
            if isNew {
                cancelled = true
                onDismiss()
            } else {
                refusal = nil
                Task { refusal = await remove() }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: SettingsScale.micro, weight: .medium))
        .tracking(SettingsScale.microTracking)
        .foregroundStyle(coolWhite.opacity(0.52))
        .lineLimit(1)
        .fixedSize()
        .accessibilityIdentifier("settings.localProvider.\(id).\(isNew ? "cancel" : "remove")")
    }

    /// Saves when there is something to say: a stored row with a changed URL, or a new
    /// row with a URL. An empty new row saves nothing (Rule 9: nothing is demanded of it).
    private func commit() {
        guard !cancelled else { return }
        let url = draft.trimmingCharacters(in: .whitespaces)
        if isNew, url.isEmpty { return }
        if !isNew, url == baseURL { return }
        Task {
            refusal = await save(id, label, url)
            if refusal == nil { onSaved() }
        }
    }
}
