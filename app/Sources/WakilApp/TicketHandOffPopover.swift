import AppKit
import WakilKit
import SwiftUI

/// **Hand to agent**'s popover (ticket noticing, spec *Hand to agent*): the brief, focused with the
/// caret at its end (Rule 3) — Return a new line, ⌘↩ Start, a long one scrolling inside the field —
/// kept on blur and when the popover
/// closes (Rule 2); the harness and provider menus and **May push**, defaulting to the last Start
/// (Rule 9); the place line, a production environment red (Invariant 8); **Reset**, **Cancel** and
/// **Start**. It decides nothing: the state is `EditorTicketViewState.handoff`, and every change is
/// a `ticket_hand_off_*` action. Start sends exactly what is drawn (`startParams`, the field's text
/// as the brief), and reads `Starting…`, disabled, while it runs (Rule 5); Cancel then stops it
/// (Rule 4). A failure shows here, whole, the brief intact (Rule 8). **Similar before** is not drawn.
struct TicketHandOffPopover: View {
    let state: TicketHandOffState
    /// A `ticket_hand_off_*` action on the pane, its refusal on the status line.
    let dispatch: (String, [String: JSONValue]) async -> Void
    /// The same, its refusal thrown here: Start's failure is the popover's to show (`state.error`).
    let dispatchReply: (String, [String: JSONValue]) async throws -> JSONValue
    /// The field's text as typed, for the anchor's close when the popover is dismissed (Rule 2).
    let draft: TicketHandOffDraft

    @State private var text = ""
    /// The field holds typing not yet kept: an echo of the store does not overwrite it.
    @State private var typed = false
    @FocusState private var briefFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("ticket.handoff.title")
            if state.agentBrief {
                // An agent wrote the brief as it stands: Start sends it marked as the agent's.
                Text(handOffAgentEdited)
                    .font(.system(size: 11)).foregroundStyle(EditorPaneStyle.amber)
                    .accessibilityIdentifier("ticket.handoff.agentEdited")
            }
            briefField
            Button("Reset") {
                typed = false
                var p = state.openParams
                p["reset"] = .bool(true)
                Task { await dispatch("ticket_hand_off_open", p) }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(EditorPaneStyle.violet)
            .disabled(state.starting)
            .help("Refill the brief from where it was handed from")
            .accessibilityIdentifier("ticket.handoff.reset")
            choices
            if !state.crewRepos.isEmpty { crew }
            if let error = state.error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(VoidPalette.red))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("ticket.handoff.error")
            }
            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") {
                    // Starting, it stops the start; else it closes, the field's text kept (Rule 2).
                    let p: [String: JSONValue] = state.starting || text == state.brief ? [:] : ["brief": .string(text)]
                    Task { await dispatch(state.starting ? "ticket_hand_off_cancel" : "ticket_hand_off_close", p) }
                }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("ticket.handoff.cancel")
                Button(state.starting ? state.startLabel : "\(state.startLabel) ⌘↩") { start() }
                    .buttonStyle(.borderedProminent).tint(EditorPaneStyle.violet)
                    .disabled(state.starting)
                    .accessibilityIdentifier("ticket.handoff.start")
            }
        }
        .padding(Space.m)
        .frame(width: 520)
        .background(Color(red: 0.055, green: 0.063, blue: 0.098))   // #0e1019
        .foregroundStyle(EditorPaneStyle.text)
        .onAppear {
            text = state.brief
            draft.text = state.brief
            typed = false
            // Only the operator's own open takes the keyboard (Rules 3 and 6).
            if state.focus { briefFocused = true }
        }
        .onChange(of: state.brief) { _, now in
            // The store's brief — Reset's, an agent's edit — reaches the field unless the operator is typing.
            if !typed || !briefFocused { text = now; typed = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ticket.handoff")
    }

    /// The harness and provider menus, **May push** and the place line.
    private var choices: some View {
        HStack(spacing: Space.m) {
            Menu {
                ForEach(ticketHandOffHarnesses, id: \.id) { h in
                    Button(h.label) { set(["harness": .string(h.id)]) }
                        .accessibilityIdentifier("ticket.handoff.harness:\(h.id)")
                }
            } label: {
                Text(ticketHandOffHarnesses.first { $0.id == state.harness }?.label ?? state.harness)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(state.starting)
            .accessibilityIdentifier("ticket.handoff.harness")
            Menu {
                ForEach(providerRows, id: \.id) { p in
                    Button(p.shown) { set(["provider": .string(p.id)]) }
                        .accessibilityIdentifier("ticket.handoff.provider:\(p.id)")
                }
            } label: {
                Text(providerRows.first { $0.id == state.provider }?.shown ?? state.provider)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(state.starting)
            .accessibilityIdentifier("ticket.handoff.provider")
            Toggle("May push", isOn: Binding(get: { state.mayPush }, set: { set(["mayPush": .bool($0)]) }))
                .toggleStyle(.switch).controlSize(.mini)
                .disabled(state.starting)
                .help("On, the agent's push and sync run as any agent's; publish, merge and rebase still ask you")
                .accessibilityIdentifier("ticket.handoff.mayPush")
            Spacer(minLength: Space.s)
            placeLine
        }
        .font(.system(size: 11.5))
    }

    /// Workspaces piece 5 (decision 17): **Agents: one / one per repo**, one by default (Rule 9); one
    /// per repo lists the project's repos as toggles, the ticket's pre-ticked. Each change is kept at
    /// once (`ticket_hand_off_brief`), so nothing waits on Enter (Rule 2). Names wrap, never cut.
    private var crew: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            // Two buttons drawn as one segmented choice, each its own identifier: a segmented
            // Picker's segments carry none, so neither a check nor VoiceOver could name one.
            HStack(spacing: Space.s) {
                Text("Agents")
                HStack(spacing: 0) {
                    agentsChoice("One", .one)
                    agentsChoice("One per repo", .perRepo)
                }
                .background(RoundedRectangle(cornerRadius: 5).fill(EditorPaneStyle.text.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(EditorPaneStyle.text.opacity(0.18)))
            }
            if state.agents == .perRepo {
                HStack(alignment: .top, spacing: Space.m) {
                    ForEach(state.crewRepos, id: \.root) { repo in
                        Toggle(repo.name, isOn: Binding(
                            get: { repo.ticked },
                            set: { on in
                                var ticked = Set(state.crewRoots)
                                if on { ticked.insert(repo.root) } else { ticked.remove(repo.root) }
                                set(["repos": .array(state.crewRepos.map(\.root).filter(ticked.contains).map { .string($0) })])
                            }))
                            .toggleStyle(.checkbox)
                            .fixedSize(horizontal: false, vertical: true)
                            .disabled(state.starting)
                            .accessibilityIdentifier("ticket.handoff.repo:\(repo.name)")
                    }
                }
                Text("One agent per ticked repo, in one workspace; each is told who holds what, and they talk through messages.")
                    .font(.system(size: 11)).foregroundStyle(EditorPaneStyle.text.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11.5))
    }

    /// One segment of **Agents**: the chosen one filled, and said selected to VoiceOver.
    private func agentsChoice(_ label: String, _ agents: TicketHandOffAgents) -> some View {
        let chosen = state.agents == agents
        return Button { if !chosen { set(["agents": .string(agents.rawValue)]) } } label: {
            Text(label)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(chosen ? EditorPaneStyle.violet.opacity(0.45) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.starting)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("ticket.handoff.agents:\(agents.rawValue)")
    }

    /// The brief — the operator's words only; Wakil appends the record and its actions at Start,
    /// out of view (walk 2026-10-28): Return a new line, ⌘↩ Start, kept when it is left. A long
    /// brief scrolls inside the field, which stops growing at `briefMaxHeight`, so the popover
    /// keeps a sensible height (walk 2026-10-28: it clipped).
    private var briefField: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: Self.briefMinHeight, maxHeight: Self.briefMaxHeight)
            .padding(Space.s)
            .background(RoundedRectangle(cornerRadius: 6).fill(EditorPaneStyle.lifted))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(EditorPaneStyle.text.opacity(briefFocused ? 0.3 : 0.12)))
            .focused($briefFocused)
            .disabled(state.starting)
            .onChange(of: text) { _, now in
                typed = now != state.brief
                draft.text = now
            }
            .onChange(of: briefFocused) { old, now in
                if old, !now { keep() }
                if now { Task { @MainActor in caretToEnd() } }
            }
            // Return is a new line (the editor's own); ⌘↩ starts.
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                start()
                return .handled
            }
            .accessibilityLabel("Brief")
            .accessibilityIdentifier("ticket.handoff.brief")
    }

    /// The provider menu's rows: the organisation's bindings, the chosen one always among them.
    private var providerRows: [TicketHandOffProvider] {
        state.providers.contains { $0.id == state.provider } || state.provider.isEmpty
            ? state.providers : [TicketHandOffProvider(id: state.provider)] + state.providers
    }

    /// `initech · api · local`, a production environment's segment red (Invariant 8).
    private var placeLine: some View {
        let line = state.placeLine
        let env = line.environment.isEmpty ? "no environment" : line.environment
        return (Text(line.head + " · ").foregroundStyle(EditorPaneStyle.text.opacity(0.7))
            + Text(env).foregroundStyle(state.production ? Color(VoidPalette.red) : EditorPaneStyle.text.opacity(0.7)))
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
            .accessibilityIdentifier("ticket.handoff.place")
    }

    /// The field's text, kept (Rule 2) when it differs from the store's.
    private func keep() {
        guard text != state.brief else { typed = false; return }
        let now = text
        Task {
            await dispatch("ticket_hand_off_brief", ["brief": .string(now)])
            typed = false
        }
    }

    private func set(_ params: [String: JSONValue]) {
        Task { await dispatch("ticket_hand_off_brief", params) }
    }

    /// Start: exactly what is drawn, the field's text as the brief. Not twice (Rule 5).
    private func start() {
        guard !state.starting else { return }
        var params = state.startParams
        params["brief"] = .string(text)
        let keepFirst = text != state.brief
        let now = text
        Task {
            if keepFirst { await dispatch("ticket_hand_off_brief", ["brief": .string(now)]) }
            // A failure is the popover's to show, whole (`state.error`), not the status line's.
            _ = try? await dispatchReply("ticket_hand_off", params)
        }
    }

    /// Focus by keyboard selects the whole text; the caret goes to its end instead (Rule 3).
    private func caretToEnd() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let length = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: length, length: 0))
    }

    private enum Space {
        static let s: CGFloat = 6, m: CGFloat = 12
    }

    /// About eight lines of the brief at least, about twenty-two at most; past that it scrolls.
    private static let briefMinHeight: CGFloat = 130, briefMaxHeight: CGFloat = 340
}

/// What the popover's field holds as typed, held by the view that anchors it: a dismissal (a click
/// outside, Esc) closes with it, so text not yet kept on blur is kept all the same (Rule 2).
final class TicketHandOffDraft {
    var text: String?

    /// `ticket_hand_off_close`'s params for `state`: the typed text when it differs from the kept brief.
    func closeParams(_ state: TicketHandOffState?) -> [String: JSONValue] {
        guard let text, let state, text != state.brief else { return [:] }
        return ["brief": .string(text)]
    }
}
