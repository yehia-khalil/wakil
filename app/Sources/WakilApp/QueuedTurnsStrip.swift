import WakilKit
import SwiftUI

/// Item 8 (2026-10-30): the operator's messages queued for the conversation on screen — a **Send to**
/// that came while it was in a turn — over its thread, each whole (UI text is never cut) with its
/// **Cancel** (Rule 4: it is taken back until its turn ends; nothing asks, Rule 1). Each goes as the
/// operator's own turn when the one before ends. It decides nothing: Cancel is
/// `conversation_queued_cancel`.
struct QueuedTurnsStrip: View {
    let conversation: String
    let queued: [QueuedTurn]
    let dispatch: (String, JSONValue) async -> JSONValue?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(queued.enumerated()), id: \.element.id) { i, q in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Queued — goes as your message when this turn ends")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 0.655, green: 0.545, blue: 0.980))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(q.text)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("window.queued.text:\(i + 1)")
                    }
                    Spacer(minLength: 8)
                    Button("Cancel") {
                        Task {
                            _ = await dispatch("conversation_queued_cancel",
                                               .object(["conversation": .string(conversation), "id": .string(q.id)]))
                        }
                    }
                    .help("Take this message back; it is not sent")
                    .accessibilityIdentifier("window.queued.cancel:\(i + 1)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.055, green: 0.063, blue: 0.098).opacity(0.92)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.queued")
    }
}
