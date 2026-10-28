import WakilKit
import SwiftUI

/// One chip per live conversation not on screen — in another place, or backgrounded in this one —
/// top right of the window (background agents 4 of 4; conversations 2 of 3). `WindowModel.chips`
/// decides which have one and in what state; this only draws them, and a click is
/// `session_switch` through the registry (`WindowModel.switchToRunning`): the conversation
/// brought back as it was left, in its own place, no fork.
///
/// **Nothing when there is nothing elsewhere.** No agents elsewhere means an empty `chips`, and
/// this draws nothing at all — not an empty tray — so the window's resting state is what it was
/// before agents could work off screen (`design-language.md` §1: futurism through absence).
///
/// **Light is information (§1.2), and only the dot carries it.** The capsule is a hairline and a
/// near-black fill; the one coloured mark is the dot, in §5's reserved hue for the state:
/// violet while working, amber while waiting on the operator, green when done and unseen, red
/// when failed and unseen. Nothing glows. The working dot breathes on the room's own thinking
/// turnover (`CoreMotion.forState(.thinking).period`), so a chip and the room it stands for
/// move at one rhythm; with reduced motion on, it holds still.
///
/// **The environment is production red whatever the state (Invariant 8)**, as it is in the
/// context line: a waiting chip for a production place reads amber dot, red environment.
///
/// **The interaction rules it meets.** A click asks nothing (Rule 1) and is the only thing here
/// that moves the operator (Rule 6) — the chips appear and change in place and never switch the
/// window themselves. They are Rule 5's work in flight, shown off screen. A waiting chip leads to
/// its place, where the confirmation plane and its Cancel are (Rule 4).
///
/// **At most two in full (`AgentChipTray`).** From the third agent on, the rest fold into one
/// "+N more" chip in the same style, carrying the strongest state among those it hides; its
/// click opens a small popover listing them, each a chip that goes there. So the chips never
/// grow down over the rail's top rows or the canvas's top right, and never need a scroll view.
/// A label is bounded too: the organisation and project truncate in the middle and the title at
/// its end, while the environment and the state never do; the whole label is in the tooltip and
/// read to VoiceOver.
struct AgentChips: View {
    let model: WindowModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// §7: a value materialising is a 250ms fade and a 4pt rise; leaving is the same, reversed.
    /// Under reduced motion, the fade alone.
    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4))
    }

    var body: some View {
        let tray = AgentChipTray(model.chips)
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(tray.shown) { chip in
                AgentChipView(
                    chip: chip, go: { Task { await model.switchToRunning(chip.conversation) } },
                    rename: { model.openRenamePalette(conversation: chip.conversation) })
                    .transition(arrival)
            }
            if let state = tray.hiddenState {
                MoreChip(
                    tray: tray, state: state, go: { chip in Task { await model.switchToRunning(chip.conversation) } },
                    rename: { chip in model.openRenamePalette(conversation: chip.conversation) })
                    .transition(arrival)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.chips)
    }
}

private extension AgentChip.State {
    /// §5's reserved hue for the state.
    var hue: Color {
        switch self {
        case .working: Color(VoidPalette.violet)       // #7c5cff
        case .waiting: Color(TerminalPalette.amber)    // #e8b45a
        case .done: Color(TerminalPalette.green)       // #8be0c8
        case .failed: Color(VoidPalette.red)           // #e85c5c
        }
    }

    /// What VoiceOver says after the place.
    var word: String {
        switch self {
        case .working: "working"
        case .waiting: "waiting on you"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

extension ConversationState {
    /// The dot's hue on a Running row (the Landing's, ⌘P's): the chip's own hue for the state,
    /// and for an idle, seen conversation — which has no chip — §5's text luminance at half, grey.
    var hue: Color {
        switch self {
        case .working: AgentChip.State.working.hue
        case .waiting: AgentChip.State.waiting.hue
        case .done: AgentChip.State.done.hue
        case .failed: AgentChip.State.failed.hue
        case .idle: coolWhite.opacity(0.50)
        }
    }

    /// What VoiceOver says for the row's dot: the chip's word, and "idle".
    var spoken: String {
        switch self {
        case .working: AgentChip.State.working.word
        case .waiting: AgentChip.State.waiting.word
        case .done: AgentChip.State.done.word
        case .failed: AgentChip.State.failed.word
        case .idle: "idle"
        }
    }
}

/// `#e8ecf6`, §5's text luminance, stepped by opacity.
private let coolWhite = Color(EnvironmentBadge.ordinaryColour)

/// The widest a chip's text may draw before it is truncated in the middle.
private let chipTextMaxWidth: CGFloat = 300

/// Hugs its one child, offering it at most `limit` points of width. A flexible
/// `.frame(maxWidth:)` would not do: under the window's wide proposal it takes the whole
/// `limit` itself, so every chip would be as wide as the longest allowed.
private struct CappedWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The capsule every chip is drawn in: the state's dot, then `content`, inside a hairline over
/// the near-black fill the context line's menus use. A plain `Button`, so VoiceOver reads it as
/// one with whatever label the caller gives it.
private struct ChipButton<Content: View>: View {
    let state: AgentChip.State
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ChipDot(colour: state.hue, breathes: state == .working)
                CappedWidth(limit: chipTextMaxWidth) {
                    content
                        .font(.system(size: 11, design: .monospaced))   // §6: identifiers, monospace
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color(red: 0.055, green: 0.063, blue: 0.098)   // #0e1019
                    .opacity(hovered ? 0.92 : 0.78)))
            .overlay(
                Capsule().strokeBorder(coolWhite.opacity(hovered ? 0.16 : 0.08), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.25), value: hovered)
        // It draws over the canvas's top edge: a click on it focuses no pane under it.
        .background(ClickShield())
    }
}

private struct AgentChipView: View {
    let chip: AgentChip
    let go: () -> Void
    /// Names, Calls made 12: the chip draws no title to edit in place, so **Rename…** opens ⌘P on
    /// the name step for its conversation; Esc there closes straight back (Rule 6).
    let rename: () -> Void

    /// `chip.label` in three: the organisation and project, which may be truncated in the
    /// middle; the environment segment, which never is — so a production place's red segment
    /// (Invariant 8) cannot be truncated away; and the title, cut at its end, then the state's
    /// suffix, which never is.
    private var head: String {
        [chip.place.organization, chip.place.project].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The environment segment, in production red when it is production.
    private var environmentSegment: AttributedString {
        let environment = chip.place.environment
        var text = AttributedString()
        if !environment.isEmpty {
            var separator = AttributedString(head.isEmpty ? "" : " · ")
            separator.foregroundColor = coolWhite.opacity(0.82)
            var segment = AttributedString(environment)
            segment.foregroundColor = chip.productionEnvironment
                ? Color(EnvironmentBadge.productionColour) : coolWhite.opacity(0.82)
            text = separator + segment
        }
        return text
    }

    var body: some View {
        ChipButton(state: chip.state, action: go) {
            HStack(spacing: 0) {
                if !head.isEmpty {
                    Text(head).foregroundStyle(coolWhite.opacity(0.82))
                }
                Text(environmentSegment).fixedSize()
                Text(" — ").foregroundStyle(coolWhite.opacity(0.62)).fixedSize()
                Text(chip.title).foregroundStyle(coolWhite.opacity(0.82)).truncationMode(.tail)
                if !chip.state.suffix.isEmpty {
                    Text(chip.state.suffix).foregroundStyle(coolWhite.opacity(0.62)).fixedSize()
                }
            }
        }
            // The place is the label and the state its value, which VoiceOver reads after it — and
            // which is what changes while the chip stays put.
            .accessibilityLabel(chip.label)
            .accessibilityValue(chip.state.word)
            // One per conversation, by its place and ordinal (ruling 2), so a check can press the
            // chip it means — and a place's three parts, joined by `/`, can never spell `more`.
            .accessibilityIdentifier(chip.identifier)
            .help("Switch to \(chip.label)\(chip.state.suffix)")
            .contextMenu {
                Button("Rename…", action: rename)
            }
    }
}

/// The conversations past the first two, as one chip. Its dot is the strongest hidden state; a
/// click opens a popover listing them, each an ordinary chip that switches to it (and closes the list).
private struct MoreChip: View {
    let tray: AgentChipTray
    let state: AgentChip.State
    let go: (AgentChip) -> Void
    let rename: (AgentChip) -> Void

    @State private var open = false

    var body: some View {
        ChipButton(state: state, action: { open.toggle() }) {
            Text(tray.moreLabel).foregroundStyle(coolWhite.opacity(0.82))
        }
        .accessibilityLabel("\(tray.hidden.count) more conversations")
        .accessibilityValue(state.word)
        .accessibilityIdentifier("window.agentChip.more")
        .help(tray.hidden.map { $0.label + $0.state.suffix }.joined(separator: "\n"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(tray.hidden) { chip in
                    AgentChipView(
                        chip: chip,
                        go: {
                            open = false
                            go(chip)
                        },
                        rename: {
                            // The popover goes first: the palette takes the window.
                            open = false
                            rename(chip)
                        })
                }
            }
            .padding(10)
            .background(Color(red: 0.055, green: 0.063, blue: 0.098))   // #0e1019
        }
    }
}

/// The state's hue as a 6pt dot. Breathing, it eases between full and dim over one thinking
/// turnover of the room (`CoreMotion.forState(.thinking).period`); still, it is full.
///
/// **A function of the clock, not a repeating animation.** Its opacity is computed from the
/// time, so a dot that stops breathing — the agent's turn ends, or reduced motion comes on — is
/// simply full on the next frame, with no running animation to unwind. Drawn at 120 frames a
/// cycle, the room's own rule for its cadence (§7: at least 25 a cycle), and paused when still.
/// The Landing's and ⌘P's Running rows draw the same dot, so a conversation reads alike in all three.
struct ChipDot: View {
    let colour: Color
    let breathes: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period = CoreMotion.forState(.thinking).period

    var body: some View {
        let moving = breathes && !reduceMotion
        TimelineView(.animation(minimumInterval: Self.period / 120, paused: !moving)) { context in
            Circle()
                .fill(colour)
                .frame(width: 6, height: 6)
                .opacity(moving ? Self.breath(at: context.date) : 1)
        }
    }

    /// 1 at the top of the cycle, 0.35 at the bottom, eased (a cosine).
    private static func breath(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return 0.675 + 0.325 * cos(2 * .pi * phase)
    }
}
