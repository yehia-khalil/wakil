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
                .foregroundStyle(SettingsPalette.coolWhite.opacity(adding == nil ? SettingsInk.secondary : SettingsInk.disabled))
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
    /// The row's width, measured, so a column too narrow for one line puts the URL under the name.
    @State private var width: CGFloat = 0

    private var coolWhite: Color { SettingsPalette.coolWhite }

    /// One line needs the label, a URL field wide enough to read a URL (200pt), whether it
    /// answers and REMOVE. The settings pane's 640pt default leaves its subject column about 350.
    private static let oneLineWidth: CGFloat = 520
    /// Before the first measurement the row draws on one line, as it always did.
    private var stacked: Bool { width > 0 && width < Self.oneLineWidth }

    var body: some View {
        // **The URL field is never rebuilt by the switch** (Rule 2, Rule 3): it sits at the same
        // place in the same HStack either way, and only the name and the verb move — above it in a
        // narrow column, beside it in a wide one — so focus and what is typed survive a resize.
        VStack(alignment: .leading, spacing: 6) {
            if stacked {
                HStack(alignment: .firstTextBaseline, spacing: SettingsScale.columnGap) {
                    nameText
                    Spacer(minLength: 0)
                    rowAction
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: SettingsScale.columnGap) {
                if !stacked {
                    nameText.frame(width: SettingsScale.labelWidth, alignment: .leading)
                }
                valueColumn
                Spacer(minLength: 0)
                if !stacked { rowAction }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: SettingsScale.rowHeight, alignment: .leading)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: LocalProviderRowWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(LocalProviderRowWidthKey.self) { width = $0 }
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

    private var nameText: some View {
        Text(isNew ? "New model" : (label.isEmpty ? id : label))
            .font(.system(size: SettingsScale.body, weight: .medium))
            .foregroundStyle(coolWhite.opacity(isNew ? SettingsInk.secondary : SettingsInk.primary))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The URL, whether it answers, and the error or refusal under it, whole.
    private var valueColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                urlField
                if !isNew, let status, !failing {
                    HStack(spacing: 5) {
                        Circle().fill(coolWhite.opacity(status == "reachable" ? 0.70 : 0.25))
                            .frame(width: 5, height: 5)
                        Text(status)
                            .font(.system(size: SettingsScale.meta))
                            .foregroundStyle(coolWhite.opacity(status == "reachable" ? SettingsInk.secondary : SettingsInk.secondary))
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
    }

    /// Plain monospace text that is edited where it stands; the box shows only on hover or focus.
    private var urlField: some View {
        TextField("http://127.0.0.1:8012", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: SettingsScale.identifier, design: .monospaced))
            .foregroundStyle(coolWhite.opacity(SettingsInk.primary))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: SettingsScale.radiusField, style: .continuous)
                    .fill(coolWhite.opacity(focused || hovering ? 0.05 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsScale.radiusField, style: .continuous)
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
        .foregroundStyle(coolWhite.opacity(SettingsInk.secondary))
        .fixedSize(horizontal: false, vertical: true)
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

/// A local model row's measured width (`LocalProviderRow.stacked`). A preference rather than
/// `onGeometryChange`, which is macOS 15 while this app targets 14.4.
private struct LocalProviderRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
