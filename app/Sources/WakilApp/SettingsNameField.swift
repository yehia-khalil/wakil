import AppKit
import SwiftUI
import WakilKit

/// The Name row on a project's or an environment's page (2e-ii): `LeaveSavedTextField` labelled
/// **Name**. Kept as its own name so 2e-ii's call sites and identifiers read as they did.
struct LifecycleNameField: View {
    let stored: String
    let identifier: String
    @Binding var wantsFocus: Bool
    let save: (String) async -> String?
    var unseen: (String) -> Void = { _ in }

    var body: some View {
        LeaveSavedTextField(
            label: "Name", stored: stored, identifier: identifier,
            wantsFocus: $wantsFocus, save: save, unseen: unseen)
    }
}

/// A value edited where it stands (2e-ii's Name field, generalised by 2e-iii for an API entry's
/// name, base URL and auth header and a database's name): saved when the field is left or Return
/// is pressed, never by a Save button (Rule 2).
///
/// **A refusal is shown whole beneath the field and the typed text stays** (Rule 8) — a name in
/// use, an `http://` base URL, a `Host` header — so it can be corrected rather than retyped. While
/// the write is in flight the field says so and a second write is not started (Rule 5).
///
/// **Leaving by moving to another page is leaving too**: the tree click swaps this view out, and
/// the focus change it would have heard is never reported, so its disappearance writes the draft
/// (`LeaveSavedField`). A refusal that lands after it is gone goes to `unseen`, the window's
/// status, rather than nowhere.
///
/// With a `label` it is a whole `SettingsRow`; without one it is the bare field, for a row that
/// draws its own (a database's name beside its chips).
struct LeaveSavedTextField: View {
    let label: String?
    let stored: String
    let identifier: String
    /// Shown, dimmed, while the value is empty — what an empty value means (`Authorization`).
    var prompt: String = ""
    /// Identifiers and URLs are monospace (§6).
    var monospaced: Bool = true
    var maxWidth: CGFloat = 320
    /// True when this page was just created for the operator to name: the field takes the
    /// keyboard with its text selected (Rule 3), then the request is put down.
    var wantsFocus: Binding<Bool> = .constant(false)
    /// Writes the new value and answers the refusal's own sentence, or nil on success.
    let save: (String) async -> String?
    /// Where a refusal goes when the field is no longer on screen to show it.
    var unseen: (String) -> Void = { _ in }

    /// The draft, the write in flight, its refusal and whether the field is on screen. A
    /// reference, so a write that lands after the field went reads the live answer.
    @State private var field = LeaveSavedField()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                SettingsRow(label) { input }
            } else {
                input
            }
            if let refusal = field.refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, label == nil ? 0 : SettingsScale.labelWidth + SettingsScale.columnGap)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("\(identifier).error")
            }
        }
        .onAppear {
            field.appeared()
            takeFocusIfAsked()
        }
        .onDisappear { commit(field.disappeared(stored: stored)) }
        .onChange(of: wantsFocus.wrappedValue) { _, _ in takeFocusIfAsked() }
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField(prompt, text: Binding(get: { field.draft ?? stored }, set: { field.draft = $0 }))
                .textFieldStyle(.plain)
                .font(monospaced
                    ? .system(size: SettingsScale.identifier, design: .monospaced)
                    : .system(size: SettingsScale.body))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(SettingsInk.primary))
                .lineLimit(1)
                // A value longer than its column (a base URL) is shortened in the middle while
                // it is not being edited, rather than cut at the column's edge.
                .truncationMode(.middle)
                .frame(maxWidth: maxWidth)
                .inPlaceField(focused: focused)
                .focused($focused)
                .onSubmit { commit(field.submit(stored: stored)) }
                .onChange(of: focused) { old, new in
                    if old, !new { commit(field.leave(stored: stored)) }
                }
                .accessibilityIdentifier(identifier)
            if field.saving {
                ProgressView().controlSize(.small)
                Text("Saving…")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(SettingsInk.secondary))
                    .fixedSize()
            }
        }
    }

    private func takeFocusIfAsked() {
        guard wantsFocus.wrappedValue else { return }
        wantsFocus.wrappedValue = false
        focused = true
        // The field editor exists a beat after focus is granted; selecting before it does nothing.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    /// Writes what a leave answered — Return, focus moving on, or the field going from screen.
    /// Nil is nothing to write: unchanged, or a write already in flight.
    private func commit(_ value: String?) {
        guard let value else { return }
        let field = field
        Task {
            if let refusal = field.landed(await save(value)) { unseen(refusal) }
        }
    }
}
