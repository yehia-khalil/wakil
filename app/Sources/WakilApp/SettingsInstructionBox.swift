import AppKit
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
                // Text equal to what is stored is no draft: a field writes its text back when editing
                // ends, and a kept copy would hide a later change to the stored value.
                TextField("", text: Binding(get: { field.draft ?? stored }, set: { field.draft = $0 == stored ? nil : $0 }),
                          prompt: Text(placeholder).foregroundStyle(SettingsPalette.coolWhite.opacity(SettingsInk.secondary)),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...12)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(SettingsInk.primary))
                    .frame(maxWidth: 520, alignment: .leading)
                    .inPlaceField(focused: focused)
                    .focused($focused)
                    .onChange(of: focused) { old, new in
                        if old, !new { autosave.cancel(); commit(field.leave(stored: stored)) }
                        // Focus by keyboard selects the whole text, so the next key would replace it:
                        // the caret goes to the end instead. A click keeps the caret where it landed.
                        if new { Task { @MainActor in caretToEndIfAllSelected() } }
                    }
                    // A box of instructions takes new lines: Return inserts one where the caret is,
                    // rather than ending the edit as a one-line field would.
                    .onKeyPress(.return) {
                        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return .handled
                    }
                    .onChange(of: field.draft) { _, draft in
                        guard draft != nil else { return }
                        autosave.schedule { commit(field.leave(stored: stored)) }
                    }
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(identifier)
            }
            if field.saving {
                Text("Saving…")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(SettingsInk.secondary))
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

    private func caretToEndIfAllSelected() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let length = (editor.string as NSString).length
        if length > 0, editor.selectedRange() == NSRange(location: 0, length: length) {
            editor.setSelectedRange(NSRange(location: length, length: 0))
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
