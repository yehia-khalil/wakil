import WakilKit
import SwiftUI

/// The collapsed rail (§10): a spine of short marks at the window's right edge, and the rail itself
/// coming out over the canvas when the pointer rests there.
///
/// **One view is the zone, the spine and the peeked rail**, as the browser's tab column's is
/// (`BrowserTabColumnPeek`): the pointer that brought the rail out is inside it from the first
/// frame, so nothing has to be crossed to use it. The pointer must rest `RailSpine.peekDelay` (150
/// ms) on the spine or the 6 pt edge zone; the rail leaves `RailSpine.leaveDelay` (300 ms) after
/// the pointer is on none of the three. In goes quickly, out goes slowly: a pointer that overshoots
/// the rail's edge by a few points does not lose it.
///
/// **Out over the canvas, never pushing it.** This is an overlay, and the rail's row slot is already
/// gone (`WakilWindow.rail`), so a peek moves no pane. The rail arrives as the plane releasing —
/// opacity and blur together (§3) — plus a short step from the right (`RailSpine.travel`), over §7's
/// 400-600 ms ease-out. With Reduce Motion it is a crossfade and nothing else.
///
/// **Nothing here takes focus** (Rule 6): no control is focusable and a peek writes no model state.
/// The spine's accessibility action is the one way in for a user who does not point: it dispatches
/// `rail_set`, the same as ⌃⌘R.
struct RailPeek: View {
    let model: WindowModel
    let parallax: (x: Double, y: Double)
    let isMaximized: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var peeking = false
    @State private var over: Set<Zone> = []
    @State private var wait: Task<Void, Never>?

    private enum Zone { case edge, spine, rail }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The edge zone: the whole window's height, 6 pt, so the rail can be summoned from
            // anywhere along the edge without aiming at the marks.
            Color.clear
                .frame(width: CGFloat(RailSpine.edgeZone))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { move(.edge, $0) }
                .accessibilityElement()
                .accessibilityLabel("Panes edge")
                .accessibilityHint("Rest the pointer here to show the open panes")
                .accessibilityIdentifier("rail.edge")
            spine
            if peeking {
                Rail(model: model, parallax: parallax, isMaximized: isMaximized, held: true)
                    .onHover { move(.rail, $0) }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .modifier(active: Arrival(away: true), identity: Arrival(away: false)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: RailTreatment.planeTransition), value: peeking)
        .onDisappear { wait?.cancel() }
    }

    // MARK: - The spine

    private var spine: some View {
        let panes = model.layoutSnapshot.panes
        let focused = model.layoutSnapshot.focusedId
        let marks = RailSpine.marks(panes: panes, focusedId: focused)
        return VStack(alignment: .trailing, spacing: CGFloat(RailSpine.gap)) {
            ForEach(marks) { mark in
                SpineMarkView(mark: mark, isMaximized: isMaximized)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: RailTreatment.planeTransition), value: marks.map(\.id))
        // Clear of the window's edge, and of the parallax's 8 pt either way.
        .padding(.trailing, 10)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(width: CGFloat(RailSpine.hitWidth), alignment: .trailing)
        // The far plane's parallax, kept: it is the rail's distance, whether or not it is out.
        // Outside the hit region for the rail's reason: the region follows what is drawn.
        .offset(x: parallax.x, y: parallax.y)
        .contentShape(Rectangle())
        .onHover { move(.spine, $0) }
        // Out, the rail carries the marks as its own ticks; they would draw twice.
        .opacity(peeking ? 0 : 1)
        // One element, whatever the marks are: colour and length are not in the accessibility tree.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RailSpine.label)
        .accessibilityValue(RailSpine.value(panes: panes, focusedId: focused))
        .accessibilityHint("Shows the rail")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await model.setRailCollapsed(false) } }
        .accessibilityIdentifier("rail.spine")
    }

    // MARK: - The pointer

    private func move(_ zone: Zone, _ now: Bool) {
        if now { over.insert(zone) } else { over.remove(zone) }
        wait?.cancel()
        if !over.isEmpty {
            guard !peeking else { return }
            wait = Task { @MainActor in
                try? await Task.sleep(for: RailSpine.peekDelay)
                guard !Task.isCancelled, !over.isEmpty else { return }
                peeking = true
            }
        } else if peeking {
            wait = Task { @MainActor in
                try? await Task.sleep(for: RailSpine.leaveDelay)
                guard !Task.isCancelled, over.isEmpty else { return }
                peeking = false
            }
        }
    }

    /// The release: the rail comes from a little to the right, out of focus and transparent, to the
    /// mid plane. Never a long swoop — the travel is a few points and the weight is in the release.
    private struct Arrival: ViewModifier {
        let away: Bool
        func body(content: Content) -> some View {
            content
                .offset(x: away ? CGFloat(RailSpine.travel) : 0)
                .opacity(away ? 0 : 1)
                .blur(radius: away ? 6 : 0)
        }
    }
}

/// One pane's mark: 2 pt thick, long if it is the active pane, hued if it is active or working.
private struct SpineMarkView: View {
    let mark: RailSpine.Mark
    let isMaximized: Bool

    private var colour: Color {
        switch mark.tone {
        case .working: Color(RailTreatment.workingTickColour)
        case .active: Color(RailTreatment.activeTickColour)
        case .quiet: Color(RailTreatment.textColour)
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(colour)
            .frame(width: CGFloat(mark.length), height: CGFloat(RailSpine.thickness))
            // The rail's own glow for a working pane (§10: green in the periphery), nothing for
            // the rest: active is said by length and hue.
            .shadow(color: colour.opacity(mark.isWorking ? 0.85 : 0), radius: mark.isWorking ? 5 : 0)
            .opacity(RailTreatment.spineOpacity(
                working: mark.isWorking, active: mark.isActive, isMaximized: isMaximized))
            .animation(.easeOut(duration: RailTreatment.planeTransition), value: mark)
            .animation(.easeOut(duration: RailTreatment.planeTransition), value: isMaximized)
    }
}
