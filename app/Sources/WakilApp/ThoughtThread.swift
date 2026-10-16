import AppKit
import WakilKit
import SwiftUI

/// §9's thought thread, on the near plane: agent progress rising out of the
/// bottom edge's glow, which is where §4's Core lives since 2b-iv. Completed
/// steps fade to dim green, the live step is brightest. This replaces
/// spinners and progress bars entirely.
///
/// **The plane treatment is applied here rather than claimed and skipped.**
/// Until 2b-iv this comment said "on the near plane" while the view carried
/// no scale, opacity, blur or offset, and `Plane.near`'s only real consumer
/// was `CoreView`. Deleting the Core would have orphaned the plane outright;
/// the thread takes it instead, which is what §3 always said it had.
///
/// **No upcoming steps**, and `design-language.md` §9 was amended on
/// 2026-09-09 to remove them: harness events arrive one at a time and
/// nothing announces what the agent will do next, so an upcoming step could
/// only be invented.
struct ThoughtThread: View {
    let rows: [ThoughtRow]
    /// The near plane's offset — `WakilWindow.nearOffset`. Opposes the
    /// void's own parallax (`Plane.near.parallaxFactor` is -0.5), which is
    /// what makes the thread and the room it rises from read as two depths.
    let parallax: CGSize
    @Binding var disclosure: ThreadDisclosure

    var body: some View {
        let (shown, earlier) = disclosure.visible(rows)
        VStack(alignment: .leading, spacing: 0) {
            if earlier > 0 {
                Text("\(earlier) earlier · show".uppercased())
                    .font(.system(size: 7.5, weight: .medium))
                    .tracking(1.3)
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.40))
                    .padding(.leading, 72)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { disclosure.showEarlier() }
                    // The words stay a plain text element and the press is a
                    // control beside them (`disclosureControl`): SwiftUI makes
                    // any element carrying an action a button, and a button's
                    // words go to AXDescription, which tree readers that print
                    // only AXTitle/AXValue (Orca's) never show, so
                    // "N EARLIER · SHOW" left the tree.
                    .background(disclosureControl(
                        label: "Show earlier rows", value: nil,
                        id: "window.thread.earlier") { disclosure.showEarlier() })
            }
            ForEach(shown) { row in
                rowView(row)
            }
        }
        .animation(.easeOut(duration: 0.25), value: rows.count)   // §7: 250 ms + 4 px rise
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.02, green: 0.024, blue: 0.047).opacity(0.85))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                // Not hit-testable: clicks on the padding reach the pane
                // beneath; hits come only from rows and the "earlier" line.
                // `.onHover` below is on the panel and is not a hit test.
                .allowsHitTesting(false))
        .frame(maxWidth: 640, alignment: .leading)
        .opacity(rows.isEmpty ? 0 : disclosure.opacity)
        .animation(.easeOut(duration: 0.16), value: disclosure.opacity)   // spec: 160 ms
        .onHover { inside in
            if inside { disclosure.pointerEntered() }
            else { disclosure.pointerLeft(at: ProcessInfo.processInfo.systemUptime) }
        }
        .task {
            while !Task.isCancelled {
                // Only when a fold is waiting: an idle tick would mutate the
                // binding and re-render the window at 10 Hz for nothing.
                if disclosure.foldPending {
                    disclosure.tick(at: ProcessInfo.processInfo.systemUptime,
                                    mouseHeld: NSEvent.pressedMouseButtons != 0)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.thread")
        // `Plane.near`'s scale and blur are identity; applied so the rule
        // reads from the code. `.offset` carries the near plane's parallax.
        .scaleEffect(Plane.near.scale)
        .blur(radius: Plane.near.blur)
        .offset(x: parallax.width, y: parallax.height)
    }

    private func rowView(_ row: ThoughtRow) -> some View {
        let open = disclosure.open.contains(row.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label.uppercased())
                .font(.system(size: 7.5, weight: .medium))
                .tracking(1.3)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(colour(for: row).opacity(0.55))
                // The label column toggles in both states. Open, it is the only
                // toggle, so double/triple-click in the text selects instead
                // of folding the row.
                .contentShape(Rectangle())
                .onTapGesture { disclosure.toggle(row.id) }
            Group {
                if open {
                    Text(row.detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(row.detail)
                        .font(.system(size: 10.5))
                        .italic(row.label == "resumed")
                        // Errors are shown whole (interaction rule 8).
                        .lineLimit(row.isError ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: row.isError)
                        .foregroundStyle(colour(for: row))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(open ? Color.white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { if !open { disclosure.toggle(row.id) } }
        // The row's two texts stay plain text elements, readable by any
        // accessibility client, and the disclosure is one control beside them
        // carrying the row's id, its state and the toggle. Not the row itself
        // as a button (6a04e39): SwiftUI folds a button's children into
        // AXDescription, so the tree showed "button, Value: collapsed" and
        // none of the thread's words. A tap gesture is not an accessibility
        // action (#251), so the control's action is what AXPress invokes.
        .accessibilityElement(children: .contain)
        .background(disclosureControl(
            label: "\(row.label): \(open ? "collapse" : "expand") row",
            value: open ? "expanded" : "collapsed",
            id: "window.thread.row.\(row.id)") { disclosure.toggle(row.id) })
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    /// An invisible accessibility-only button behind a thread line: the
    /// press, identifier and (for a row) expanded/collapsed state, kept off
    /// the text so the text stays readable. Not hit-testable: the pointer
    /// keeps the line's own tap gestures.
    private func disclosureControl(
        label: String, value: String?, id: String, action: @escaping () -> Void
    ) -> some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityIdentifier(id)
    }

    private func colour(for row: ThoughtRow) -> Color {
        if row.isError { return Color(red: 0.910, green: 0.361, blue: 0.361) }   // #e85c5c
        if row.id == rows.last?.id { return Color(red: 0.910, green: 0.925, blue: 0.965) }
        if row.label == "you" { return Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.70) }
        return Color(red: 0.545, green: 0.878, blue: 0.784).opacity(0.45)        // #8be0c8
    }
}
