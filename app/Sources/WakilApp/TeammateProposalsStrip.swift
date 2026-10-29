import WakilKit
import SwiftUI

/// Workspaces piece 5 (decision 17): the teammates an agent of the workspace on screen proposed,
/// over the thread — each its violet line (`teammateProposalLine`, whole: UI text is never cut), its
/// brief editable (kept on blur, Rule 2), **Start** and **Dismiss**. Nothing asks (Rule 1): both are
/// the operator's own click. Start leaves the screen where it is (Rule 6) and reads `Starting…`,
/// disabled, while it runs (Rule 5). It decides nothing: every change is a `conversation_teammate_*`
/// action. Piece 3's card draws the same line from `session_list`'s `proposals`.
struct TeammateProposalsStrip: View {
    let proposals: [TeammateProposal]
    let dispatch: (String, JSONValue) async -> JSONValue?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(proposals) { p in
                TeammateProposalRow(proposal: p, dispatch: dispatch)
            }
        }
        .padding(10)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.055, green: 0.063, blue: 0.098).opacity(0.92)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.teammates")
    }
}

private struct TeammateProposalRow: View {
    let proposal: TeammateProposal
    let dispatch: (String, JSONValue) async -> JSONValue?

    @State private var text = ""
    @State private var starting = false
    @FocusState private var focused: Bool

    private static let violet = Color(red: 0.655, green: 0.545, blue: 0.980)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("‘\(proposal.fromTitle)’ suggests a teammate for \(proposal.repoName):")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Self.violet)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("window.teammates.line.\(proposal.repoName)")
            TextEditor(text: $text)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44, maxHeight: 160)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .focused($focused)
                .disabled(starting)
                .onChange(of: focused) { was, now in if was, !now { keep() } }
                .accessibilityLabel("Teammate brief")
                .accessibilityIdentifier("window.teammates.brief.\(proposal.repoName)")
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss") {
                    Task { _ = await dispatch("conversation_teammate_dismiss", .object(["proposal": .string(proposal.id)])) }
                }
                .disabled(starting)
                .help("No teammate for \(proposal.repoName); it is not proposed again in this workspace")
                .accessibilityIdentifier("window.teammates.dismiss.\(proposal.repoName)")
                Button(starting ? "Starting…" : "Start") { start() }
                    .buttonStyle(.borderedProminent).tint(Self.violet)
                    .disabled(starting)
                    .accessibilityIdentifier("window.teammates.start.\(proposal.repoName)")
            }
        }
        .onAppear { text = proposal.brief }
        .onChange(of: proposal.brief) { _, now in if !focused { text = now } }
    }

    private func keep() {
        guard text != proposal.brief else { return }
        let now = text
        Task { _ = await dispatch("conversation_teammate_brief", .object(["proposal": .string(proposal.id), "brief": .string(now)])) }
    }

    /// Start: exactly the field's text as the brief; not twice (Rule 5).
    private func start() {
        guard !starting else { return }
        starting = true
        let now = text
        Task {
            _ = await dispatch("conversation_teammate_start", .object(["proposal": .string(proposal.id), "brief": .string(now)]))
            starting = false
        }
    }
}
