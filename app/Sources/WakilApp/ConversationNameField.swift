import AppKit
import SwiftUI
import WakilKit

/// A Running row's title as a field (names, spec §2): it arrives focused with the name selected
/// (Rule 3), Return or focus leaving commits through `RenameDraft.decide` — a name that cleans to
/// the shown one changes nothing, nothing left clears (Rule 2) — and Esc puts the name back and
/// ends editing. It commits once: Return then the focus loss it causes is one commit.
///
/// **It dispatches `conversation_rename` with the row's own conversation id** through the one
/// surface path (Invariant 2) and does not call the setter; the refusal, if any, is in `status`.
struct ConversationNameField: View {
    let conversation: String
    let shown: String
    let identifier: String
    let size: CGFloat
    let colour: Color
    let model: WindowModel
    /// Ends editing; the row draws its title again.
    let done: () -> Void

    @State private var typed: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        conversation: String, shown: String, identifier: String, size: CGFloat, colour: Color,
        model: WindowModel, done: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.shown = shown
        self.identifier = identifier
        self.size = size
        self.colour = colour
        self.model = model
        self.done = done
        _typed = State(initialValue: shown)
    }

    var body: some View {
        TextField("", text: $typed)
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .foregroundStyle(colour)
            .lineLimit(1)
            .inPlaceField(focused: focused)
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { revert() }
            .onChange(of: focused) { old, new in
                if old, !new { commit() }
            }
            .onAppear {
                focused = true
                // The field editor exists a beat after focus is granted; selecting before it does nothing.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
            .accessibilityIdentifier(identifier)
    }

    private func commit() {
        guard !finished else { return }
        finished = true
        let name = RenameDraft.decide(typed: typed, shown: shown).name
        done()
        guard let name else { return }
        let model = model
        let conversation = conversation
        Task {
            await model.dispatchFromSurface(
                "conversation_rename", .object(["conversation": .string(conversation), "name": .string(name)]))
        }
    }

    private func revert() {
        guard !finished else { return }
        finished = true
        done()
    }
}
