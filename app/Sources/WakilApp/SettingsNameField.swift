import AppKit
import SwiftUI

/// The Name row on a project's or an environment's page (2e-ii): edited where it stands, saved
/// when the field is left or Return is pressed, never by a Save button (Rule 2).
///
/// **A refusal is shown whole beneath the field and the typed text stays** (Rule 8) — a name in
/// use, an empty one, one with a `/` — so it can be corrected rather than retyped. While the
/// write is in flight the field says so and a second write is not started (Rule 5). A refusal
/// that lands after the field is gone — left by moving to another page — goes to `unseen`, the
/// window's status, rather than nowhere.
struct LifecycleNameField: View {
    let stored: String
    let identifier: String
    /// True when this page was just created for the operator to name: the field takes the
    /// keyboard with its text selected (Rule 3), then the request is put down.
    @Binding var wantsFocus: Bool
    /// Writes the new name and answers the refusal's own sentence, or nil on success.
    let save: (String) async -> String?
    /// Where a refusal goes when the field is no longer on screen to show it.
    var unseen: (String) -> Void = { _ in }

    @State private var draft: String?
    @State private var refusal: String?
    @State private var saving = false
    @FocusState private var focused: Bool
    /// Whether the field is on screen, read by a write that lands after it may have gone. A
    /// reference, so the write's task reads the live answer rather than a copy taken at commit.
    @State private var presence = Presence()

    private final class Presence {
        var shown = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow("Name") {
                HStack(spacing: 8) {
                    TextField("", text: Binding(get: { draft ?? stored }, set: { draft = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsScale.identifier, design: .monospaced))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.88))
                        .frame(maxWidth: 320)
                        .inPlaceField(focused: focused)
                        .focused($focused)
                        .onSubmit { commit() }
                        .onChange(of: focused) { old, new in
                            if old, !new { commit() }
                        }
                        .accessibilityIdentifier(identifier)
                    if saving {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                            .font(.system(size: SettingsScale.body))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.35))
                    }
                }
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .underRowValue()
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("\(identifier).error")
            }
        }
        .onAppear {
            presence.shown = true
            takeFocusIfAsked()
        }
        .onDisappear { presence.shown = false }
        .onChange(of: wantsFocus) { _, _ in takeFocusIfAsked() }
    }

    private func takeFocusIfAsked() {
        guard wantsFocus else { return }
        wantsFocus = false
        focused = true
        // The field editor exists a beat after focus is granted; selecting before it does nothing.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    /// Leaving the field and Return both land here. A Return that saved already cleared the
    /// draft, so leaving afterwards writes nothing twice.
    private func commit() {
        guard let value = draft, value != stored, !saving else { return }
        saving = true
        refusal = nil
        let presence = presence
        Task {
            let result = await save(value)
            saving = false
            refusal = result
            if result == nil { draft = nil }
            if let result, !presence.shown { unseen(result) }
        }
    }
}
