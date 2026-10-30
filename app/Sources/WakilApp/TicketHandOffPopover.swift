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
/// Item 8: when a live conversation carries the ticket, **Send to “<title>”** is primary (a ▾ picks
/// another) and **Start another** second; one per repo offers Start alone.
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
            .disabled(state.starting || state.sending)
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
            if state.offersSend {
                sendRow
            }
            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") {
                    // Starting, it stops the start; else it closes, the field's text kept (Rule 2).
                    let p: [String: JSONValue] = state.starting || text == state.brief ? [:] : ["brief": .string(text)]
                    Task { await dispatch(state.starting ? "ticket_hand_off_cancel" : "ticket_hand_off_close", p) }
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.sending)
                    .accessibilityIdentifier("ticket.handoff.cancel")
                if state.offersSend {
                    // Item 8: the second choice beside Send to — a new conversation, numbered.
                    HandOffPress(label: state.startLabel, prominent: false,
                                 enabled: !(state.starting || state.sending)) { start() }
                        .accessibilityIdentifier("ticket.handoff.startAnother")
                } else {
                    Button(state.starting ? state.startLabel : "\(state.startLabel) ⌘↩") { start() }
                        .buttonStyle(.borderedProminent).tint(EditorPaneStyle.violet)
                        .disabled(state.starting || state.sending)
                        .accessibilityIdentifier("ticket.handoff.start")
                }
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
        }
        .task {
            // Only the operator's own open takes the keyboard (Rules 3 and 6) — a beat after the
            // popover appears: focus set as it appears is dropped (BranchPicker's, 3a-iii's sheet fix),
            // which left the keyboard in the editor (piece 5's e2e run).
            guard state.focus else { return }
            try? await Task.sleep(for: .milliseconds(150))
            briefFocused = true
        }
        .onChange(of: state.brief) { _, now in
            // The store's brief — Reset's, an agent's edit — reaches the field unless the operator is typing.
            if !typed || !briefFocused { text = now; typed = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ticket.handoff")
    }

    /// Item 8: a live conversation carries the ticket, so **Send to “<title>”** is the primary
    /// choice — the brief as the operator's own message to it; idle it starts a turn off screen, in a
    /// turn it is queued (Rule 6, Rule 4) — with a ▾ to pick another when several carry it. Its title
    /// wraps whole, never cut. ⌘↩ sends.
    private var sendRow: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Spacer(minLength: Space.m)
            HandOffPress(label: state.sending ? state.sendLabel : "\(state.sendLabel) ⌘↩", prominent: true,
                         enabled: !(state.sending || state.starting)) { send() }
                .accessibilityIdentifier("ticket.handoff.send")
            if state.carriers.count > 1 {
                Menu {
                    ForEach(Array(state.carriers.enumerated()), id: \.element.conversation) { i, c in
                        Button(c.working ? "\(c.title) · working" : c.title) {
                            set(["sendTo": .string(c.conversation)])
                        }
                        .accessibilityIdentifier("ticket.handoff.sendTo:\(i + 1)")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(state.sending || state.starting)
                .help("Send to another conversation carrying this ticket")
                .accessibilityLabel("Send to another conversation")
                .accessibilityIdentifier("ticket.handoff.sendTo")
            }
        }
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
            .disabled(state.starting || state.sending)
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
            .disabled(state.starting || state.sending)
            .accessibilityIdentifier("ticket.handoff.provider")
            Toggle("May push", isOn: Binding(get: { state.mayPush }, set: { set(["mayPush": .bool($0)]) }))
                .toggleStyle(.switch).controlSize(.mini)
                .disabled(state.starting || state.sending)
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
                            .disabled(state.starting || state.sending)
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
        .disabled(state.starting || state.sending)
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
            .disabled(state.starting || state.sending)
            .onChange(of: text) { _, now in
                typed = now != state.brief
                draft.text = now
            }
            .onChange(of: briefFocused) { old, now in
                if old, !now { keep() }
                if now { Task { @MainActor in caretToEnd() } }
            }
            // Return is a new line (the editor's own); ⌘↩ presses the primary choice: Send to when
            // a live conversation carries the ticket, else Start.
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                if state.offersSend { send() } else { start() }
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

    /// Send to: the field's text to the conversation drawn. Not twice (Rule 5); a failure is the
    /// popover's to show, whole (`state.error`).
    private func send() {
        guard !state.sending, !state.starting else { return }
        var params = state.sendParams
        params["brief"] = .string(text)
        Task { _ = try? await dispatchReply("ticket_hand_off_send", params) }
    }

    /// Start (or Start another): exactly what is drawn, the field's text as the brief. Not twice (Rule 5).
    private func start() {
        guard !state.starting, !state.sending else { return }
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

/// Send to and Start another: a pressable element holding its Text, not a Button — a Button's label
/// never reaches the tree the checks read, and they read these by their words (as the home's rows,
/// piece 3). Drawn as the bordered (prominent: violet) button it stands for; disabled, it presses nothing.
private struct HandOffPress: View {
    let label: String
    let prominent: Bool
    let enabled: Bool
    let press: () -> Void

    var body: some View {
        Text(label)
            .font(.system(size: 13))
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(prominent ? Color.white : EditorPaneStyle.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(prominent ? EditorPaneStyle.violet : Color.white.opacity(0.12)))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { press() } }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { if enabled { press() } }
    }
}
