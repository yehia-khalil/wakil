import WakilKit
import SwiftUI

/// The typed-confirmation surface Invariant 7 has required since the
/// charter and that nothing could render until Phase 2b-iii gave the gate a
/// subject.
///
/// A plane above the canvas (design-language §3's depth model), edged in
/// §5's reserved destructive red — deliberately NOT an `NSAlert`. A system
/// modal is off-language, and it spins its own run loop, which the void's
/// `CAMetalLayer` and 2b-iv's motion are not written to survive.
///
/// The statement is shown VERBATIM AND UNELIDED. An operator confirming a
/// statement they cannot entirely see is not confirming it, so this scrolls
/// rather than truncating.
struct ConfirmationPlane: View {
    let pending: PendingMutation
    let environment: String
    @Binding var typed: String
    let confirm: () -> Void
    let cancel: () -> Void
    /// Whether this plane is the front-most thing Escape should reach.
    ///
    /// **A window may hold exactly one live `.cancelAction` at a time.**
    /// AppKit resolves a key equivalent by searching the view tree and
    /// taking the first match, which is an arbitrary winner rather than the
    /// front-most one: two planes both claiming Escape is a bug whichever
    /// way it lands. `OrgPlane` claims it too (spec §8.5), and `OrgPlane`
    /// draws *above* this one — so when both are on screen, Escape belongs
    /// to the org plane and this must stand down.
    ///
    /// Found on the 2b-viii acceptance walk: with a mutation parked and the
    /// org plane opened over it, Escape cancelled the mutation behind the
    /// plane the operator was actually looking at. Cancelling an unrelated,
    /// invisible confirmation is the worst available outcome for a key
    /// pressed to dismiss something else.
    let ownsEscape: Bool

    /// Whether the typed-confirmation field holds first responder. There
    /// is no other `@FocusState` anywhere in `WakilApp`, and this plane's
    /// one job is a typed word — without this, first responder is
    /// whatever the window had focused before the plane appeared (the
    /// agent composer, most likely), so an operator who sees the plane
    /// and types "confirm" would type it somewhere else entirely.
    @FocusState private var confirmationFieldFocused: Bool

    /// §5's reserved destructive red. Not `Color(hex:)` — there is no such
    /// helper in this target — but the idiom every other `#e85c5c` site in
    /// `WakilApp` already uses (`ThoughtThread.swift`, `WakilWindow.swift`).
    private var destructive: Color { Color(red: 0.910, green: 0.361, blue: 0.361) }   // #e85c5c

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(pending.origin == .agent ? "The agent proposes a change" : "Confirm this change")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Text(environment.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(destructive)
            }

            if let database = pending.database {
                Text(database).font(.system(size: 12, design: .monospaced)).opacity(0.7)
            }

            ScrollView {
                Text(pending.statement)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            if pending.affectsEveryRow {
                Text("No WHERE clause — this affects every row.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(destructive)
            }

            HStack(spacing: 12) {
                TextField("type confirm", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($confirmationFieldFocused)
                    .onSubmit(confirm)
                // The button itself never goes away — Cancel stays
                // clickable under the org plane's dimmer for an operator
                // who dismisses that plane first. Only the *key
                // equivalent* is surrendered. See `ownsEscape`.
                Button("Cancel", action: cancel)
                    .keyboardShortcut(ownsEscape ? KeyboardShortcut.cancelAction : nil)
                Button("Run", action: confirm).disabled(typed != "confirm")
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(.black.opacity(0.86))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(destructive, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 30)
        // Fires when this view is inserted into the hierarchy — i.e. when
        // the plane appears, since `Canvas.swift` only ever includes it
        // conditionally (`if let pending = model.pending`).
        .onAppear { confirmationFieldFocused = true }
    }
}
