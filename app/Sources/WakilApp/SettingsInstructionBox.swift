import SwiftUI
import WakilKit

/// 3a-iii-b: one box of agent instructions — the organisation's General, Commits or Pull requests,
/// or a project's. Multi-line, so Return is a new line and the box saves when it is left: focus
/// moving on, or its page going (Rule 2). The agent has the saved text from its next turn.
struct AgentInstructionBox: View {
    let label: String
    let stored: String
    let placeholder: String
    let identifier: String
    /// Writes the text and answers the refusal's own sentence, or nil on success.
    let save: (String) async -> String?
    /// Where a refusal goes when the box is no longer on screen to show it.
    var unseen: (String) -> Void = { _ in }

    @State private var field = LeaveSavedField()
    /// Saves a second after typing stops, as well as when the box is left.
    @State private var autosave = EditorDebounce(delay: .seconds(1))
    @FocusState private var focused: Bool

    var body: some View {
        let text = field.draft ?? stored
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(label, wraps: true) {
                // A hidden copy of the text sizes the box to it — one line empty, up to twelve — and
                // the editor lies over it, so there is no scroll bar until the text outgrows that.
                Text(text.isEmpty ? placeholder : text + "\n")
                    .font(.system(size: SettingsScale.body))
                    .lineLimit(12)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .hidden()
                    .overlay(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: Binding(get: { field.draft ?? stored }, set: { field.draft = $0 }))
                                .font(.system(size: SettingsScale.body))
                                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.88))
                                .scrollContentBackground(.hidden)
                                .scrollIndicators(.never)
                                .focused($focused)
                                .onChange(of: focused) { old, new in
                                    if old, !new { autosave.cancel(); commit(field.leave(stored: stored)) }
                                }
                                .onChange(of: field.draft) { _, draft in
                                    guard draft != nil else { return }
                                    autosave.schedule { commit(field.leave(stored: stored)) }
                                }
                                .accessibilityLabel(label)
                                .accessibilityIdentifier(identifier)
                            if text.isEmpty {
                                // The text view insets its first line by its line-fragment padding.
                                Text(placeholder)
                                    .font(.system(size: SettingsScale.body))
                                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.30))
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(maxWidth: 520)
                    .inPlaceField(focused: focused)
            }
            if field.saving {
                Text("Saving…")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.35))
                    .underRowValue()
            }
            if let hint = agentInstructionsSizeHint(text) {
                FormHint(hint)
                    .underRowValue()
                    .accessibilityIdentifier("\(identifier).size")
            }
            if let refusal = field.refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .underRowValue()
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("\(identifier).error")
            }
        }
        .onAppear { field.appeared() }
        .onDisappear {
            autosave.cancel()
            commit(field.disappeared(stored: stored))
        }
    }

    /// Writes what a leave answered. Nil is nothing to write: unchanged, or a write in flight.
    private func commit(_ value: String?) {
        guard let value else { return }
        let field = field
        Task {
            if let refusal = field.landed(await save(value)) { unseen(refusal) }
            // Typed on while it saved: that is the next save.
            if field.draft != nil, field.refusal == nil { autosave.schedule { commit(field.leave(stored: value)) } }
        }
    }
}
