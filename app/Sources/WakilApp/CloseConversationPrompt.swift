import SwiftUI
import WakilKit

/// Close Conversation's one question (conversations 3 of 3), asked when the conversation's turn is
/// running or its agent has a write waiting — Rule 1: closing stops work in flight. Worn as the
/// window-wide unsaved prompt is (`UnsavedPromptBar`): the slab, a hairline edge, the sentence in
/// the pane's monospaced voice, two plain buttons. Not §5's red: nothing here is production.
///
/// **The sentence is whole** (Rule 8): it wraps, never truncates, within a card no wider than the
/// window leaves it (`maxWidth`, and the caller's padding).
///
/// **Keep it is the default** — the answer that loses nothing. It takes the keyboard when the
/// question appears (Rule 3), so Return and Esc both keep (Rule 4: the question can always be
/// backed out of). **Close it** is the one press that closes, in the amber Don't Save wears.
struct CloseConversationPrompt: View {
    let close: () -> Void
    let keep: () -> Void
    /// Whether Esc is this prompt's: false while the org plane draws above it (one live
    /// `.cancelAction` per window — `ConfirmationPlane.ownsEscape`).
    let ownsEscape: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CloseConversationQuestion.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier("window.closeConversation.message")
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Button(CloseConversationQuestion.closeLabel, action: close)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorPaneStyle.amber)
                    .accessibilityIdentifier("window.closeConversation.close")
                Button(CloseConversationQuestion.keepLabel, action: keep)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EditorPaneStyle.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(EditorPaneStyle.lifted, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(EditorPaneStyle.text.opacity(focused ? 0.32 : 0.14)))
                    .keyboardShortcut(ownsEscape ? KeyboardShortcut.cancelAction : nil)
                    .accessibilityIdentifier("window.closeConversation.keep")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(EditorPaneStyle.slab, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorPaneStyle.text.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.return) {
            keep()
            return .handled
        }
        .onKeyPress(.escape) {
            keep()
            return .handled
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.closeConversation")
    }
}
