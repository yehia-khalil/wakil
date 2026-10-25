import SwiftUI

/// The Changes view's in-place confirm (Rule 1): the sentence in amber, then **Keep it** and the action's
/// verb. Shown where the operator pressed — under a stash row, the commit bar, a conflicted row or the
/// Merge Changes header — never as a sheet. Both identifiers are required, so no call site ships unnamed.
struct ChangesConfirm: View {
    let text: String
    let verb: String
    let keepId: String
    let confirmId: String
    let keep: () -> Void
    let go: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.910, green: 0.706, blue: 0.353))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Keep it") { keep() }
                .buttonStyle(.plain).font(.system(size: 10.5))
                .accessibilityIdentifier(keepId)
            Button(verb) { keep(); go() }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(red: 0.910, green: 0.706, blue: 0.353))
                .accessibilityIdentifier(confirmId)
        }
        .padding(.vertical, 4)
    }
}
