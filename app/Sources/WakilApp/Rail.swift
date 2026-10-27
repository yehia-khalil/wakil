import WakilKit
import SwiftUI

extension WakilWindow {
    // MARK: - The rail

    /// §10: a list of what is open, so that a pane hidden behind another —
    /// or dragged off the visible canvas — is still reachable. *(This cited
    /// §5 until 2026-09-21; §5 is the colour section.)*
    ///
    /// The window's half of the wiring: it binds the two pieces of
    /// `WakilWindow` state the rail cannot derive — the far plane's parallax
    /// offset and whether a pane is maximized — and keeps the call site in
    /// `body` reading like `canvas(model)` beside it. The rail itself is a
    /// view now rather than a function, because it holds the one piece of
    /// state it did not used to have: whether the pointer is on it.
    func rail(_ model: WindowModel) -> some View {
        Rail(model: model, parallax: farOffset, isMaximized: isMaximized)
    }
}

/// §10's list of open panes — "chrome-less, low opacity **until relevant**" —
/// and §3's promotion rule, which until #138 the rail was the one surface to
/// break outright.
///
/// **What was wrong.** The rail applied `Plane.far` permanently and contained
/// no hover or promotion code at all, yet a click on a row dispatched
/// `pane_focus`. §3: *"Far-plane content is never interactive without first
/// being promoted."* It was interactive, and it was never promoted. The only
/// opacity change it had was the other direction — the maximize fade, which
/// is deference. And at 0.30 the pane names composited to ≈2.35:1 against the
/// void, on text that is read in order to pick a pane, against `PRODUCT.md`'s
/// 4.5:1 floor: the same failure `EnvironmentBadge` was built to fix at
/// 1.47:1.
///
/// **Hover is what makes it relevant.** The pointer arriving on the rail is
/// the operator saying they are about to read it, so scale, opacity and blur
/// are released *together* — §3's "never one alone" — over §7's 400–600ms
/// plane transition, and the list becomes the mid plane whole. This is also
/// what makes the click legitimate rather than merely quieter: a click is
/// always preceded by the pointer arriving, so by the time a row can be
/// clicked the rail has already been promoted — the 450ms is the room
/// catching up with a state the pointer set instantly, not a window in which
/// the rail is half-interactive. Nothing is added to the window's resting
/// state, which is the point — §1 is futurism through absence.
///
/// **What this does not reach: an operator who never points at it.** Hover is
/// the only thing that promotes the rail, so a keyboard-driven operator reads
/// pane names at the ambient 2.35:1 or not at all. That is not a regression —
/// it is the state the rail has always been in — and §10's answer to it is
/// that the rail is one of *three* equivalent ways to reach a pane, beside a
/// keystroke and ⌘P. Promoting on keyboard focus would need the rows to be
/// focusable, which is a keyboard model this surface does not have yet; it is
/// recorded here rather than half-built. VoiceOver is unaffected: opacity is
/// not in the accessibility tree, and each row carries its own label.
///
/// The numbers live in `RailTreatment` (`WakilKit/Visual/`), beside
/// `EnvironmentBadge` and for the same reason: `WakilApp` has no test target,
/// and `RailTreatmentTests` asserts both that the promoted state clears the
/// floor and that the ambient state would fail it.
///
/// Drawn in `docs/wakil/screens/Rail.dc.html`, four states.
struct Rail: View {
    let model: WindowModel
    /// The far plane's current parallax offset, passed in rather than
    /// recomputed — `WakilWindow` already derives it once per frame, and a
    /// second derivation here would drift from the context line's.
    let parallax: (x: Double, y: Double)
    let isMaximized: Bool

    @State private var promoted = false
    /// Which row the pointer is on, by pane id. Only drawn once promoted:
    /// at rest there is nothing to point at.
    @State private var hoveredRow: String?

    var body: some View {
        // **A `List`, stripped of its chrome — not a `ScrollView` of rows,
        // which does not receive events here.** This was a `ScrollView` +
        // `VStack` for exactly one build, on the reasoning that §10's rail is
        // "chrome-less" and a `List`'s background, insets and separators are
        // three pieces of chrome to suppress. It shipped dead: the rail never
        // promoted and a row could not be clicked at all.
        //
        // Measured rather than guessed, by hanging an `onHover` probe on each
        // level of this view and sweeping the pointer across the column: the
        // **outer** hover fired over the full 220pt column at every height,
        // and the hover inside the `ScrollView` never fired once. A
        // `ScrollView`'s content stops hit-testing when an ancestor carries
        // this view's transform stack (`scaleEffect` + `opacity` + `blur` +
        // `offset`); a `List`'s rows, and a plain `VStack`'s, both survive it.
        // The `List` is kept over the `VStack` because it keeps scrolling,
        // and a rail that silently hides a pane once there are more than a
        // windowful contradicts the one thing §10 says it is for.
        //
        // The chrome goes by modifier instead: clear row backgrounds, zero
        // insets, no separators, plain style, hidden scroll background.
        List(model.layoutSnapshot.panes) { pane in
            row(pane)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(width: 220)
        // Far plane (§3) at rest, mid plane promoted — the three channels
        // released together, never one alone. Parallax is kept in both
        // states: promotion changes how legible the rail is, not where in the
        // room it sits.
        //
        // No `.animation` on the offset: `farOffset` updates on every
        // pointer-moved event and is already a smooth continuous function of
        // the cursor, so keying an ease on it would restart the curve every
        // event and lag the plane behind the cursor rather than smoothing it.
        //
        // **`anchor: .topLeading`, matching `ContextLine` and the artboard's
        // own `transform-origin: top left`.** A centred anchor would grow the
        // list about its middle, sliding every row a few points under a
        // pointer that has not moved — and the row a click lands on would
        // depend on where in the 450ms ease it arrived.
        .scaleEffect(RailTreatment.scale(promoted: promoted), anchor: .topLeading)
        .opacity(RailTreatment.opacity(promoted: promoted, isMaximized: isMaximized))
        .blur(radius: RailTreatment.blur(promoted: promoted))
        // §10: "the rail and Core fade back" while a pane is maximized — not
        // to zero, which would read as a bug rather than as deference. The
        // room defers too, by a different mechanism (a multiplier on the
        // void's bleeds, eased in Metal) and to a different degree (0.4 there,
        // 0.12 here) — the two were never the same fade, only the same rule.
        //
        // Promotion outranks it: see `RailTreatment.opacity`.
        .animation(.easeOut(duration: RailTreatment.planeTransition), value: isMaximized)
        // §7's plane transition, keyed on the value rather than opened as a
        // transaction at the mutation site.
        //
        // **`withAnimation` in the hover callback is what made the rows
        // twitch.** Re-setting `promoted` to a value it already holds is a
        // no-op for `.animation(value:)` and a *restart* for `withAnimation`:
        // every repeat hover event began a fresh 450ms ease from wherever the
        // last one had got to. Measured on the running app — with the pointer
        // parked and still, the rail's mean luminance was still climbing
        // 2.5 seconds after it should have settled.
        .animation(.easeOut(duration: RailTreatment.planeTransition), value: promoted)
        .offset(x: parallax.x, y: parallax.y)
        // **The promotion's hit region must not move with the promotion.**
        // This modifier is outermost on purpose. `scaleEffect` does not change
        // a view's *layout* size, so attached out here the hover region is a
        // stable 220pt column; attached inside the treatment — where the first
        // build had it — the region is the *rendered* one, so it grew as the
        // rail scaled, re-fired hover under a pointer that had not moved, and
        // fed the animation back into its own trigger. That loop is what the
        // operator saw as rows twitching at the start of every promotion.
        //
        // The parallax `offset` above is inside for the same reason in
        // reverse: it is driven by the cursor rather than by `promoted`, so it
        // cannot close a loop, and a hit region that ignored it would sit
        // up to 8pt from the rail as drawn.
        //
        // **The whole column promotes, not only the rows.** The first build
        // aimed the hover at the rows alone, so that a pointer resting in the
        // empty space below the last row would not promote the rail. That is
        // not reachable from out here, and it is not worth reaching for: the
        // rail's column is 220pt of otherwise empty room at the window's edge,
        // a pointer in it is a fair reading of "until relevant", and deriving
        // promotion from whichever row is hovered flickers on the gap between
        // two rows.
        .contentShape(Rectangle())
        .onHover { isHovering in
            promoted = isHovering
            if !isHovering { hoveredRow = nil }
        }
    }

    // MARK: - A row

    private func row(_ pane: Pane) -> some View {
        let lifted = promoted && hoveredRow == pane.id
        return HStack(spacing: 12) {
            Text(pane.title)
                .font(.system(size: 13))
                .foregroundStyle(Color(RailTreatment.textColour))
            Text(pane.kind)
                .font(.system(size: 10.5, design: .monospaced))
                // §5 steps text down by opacity rather than by hue — but
                // not below the floor, which is why this is 0.55 and not the
                // artboard's 0.46. See `RailTreatment.kindOpacity`.
                .foregroundStyle(
                    Color(RailTreatment.textColour).opacity(RailTreatment.kindOpacity))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        // **The tick is an overlay on the padded row, not a member of the
        // `HStack`.** `Rail.dc.html` positions it against the row's own box
        // (`left: 0; top: 8; bottom: 8`), so it spans the row's vertical
        // padding and sits at its leading edge, outside the 12pt text inset.
        // As an `HStack` member it would instead be sized against the text
        // line alone — 16pt tall, less 8pt of padding at each end, which is
        // no tick at all.
        .overlay(alignment: .leading) { tick(pane) }
        // The row under the pointer, once promoted — which row a click will
        // land on. `Rail.dc.html` state 3.
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    Color(RailTreatment.textColour)
                        .opacity(lifted ? RailTreatment.rowHoverTint : 0)))
        .animation(.easeOut(duration: RailTreatment.rowHoverDuration), value: lifted)
        // Without this only the text is clickable, and a row is mostly not
        // text.
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                hoveredRow = pane.id
            } else if hoveredRow == pane.id {
                hoveredRow = nil
            }
        }
        .onTapGesture {
            Task { await model.focusPane(id: pane.id) }
        }
        // **The tick's meaning, spoken.** Active and working are drawn as
        // hue on a 2pt mark, which VoiceOver cannot read at all — and the
        // word "working" this replaced, wrong as it was on screen, was at
        // least in the accessibility tree. `DataSurface` carries a row-level
        // label for the same reason.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(pane))
        .accessibilityAddTraits(.isButton)
        // **The trait above is a claim, and this is what makes it true.**
        // `onTapGesture` is a pointer gesture: it puts no action on the
        // accessibility element, so the row announced itself as a button and
        // then offered no way to press one. VoiceOver users could read every
        // rail row and focus none of them.
        //
        // Found by the e2e harness on its first real use (#251): pressing
        // `rail.<id>` through AX returned success and changed nothing, while
        // the same press on the window's old *Open terminal* button — a real
        // `Button` — opened a pane. That is the two-code-paths class of defect the harness
        // exists to catch, and no unit test could see it: the trait is
        // present in the tree either way.
        //
        // The default action is what AXPress invokes, so the pointer path and
        // the accessibility path now run the identical call.
        .accessibilityAction {
            Task { await model.focusPane(id: pane.id) }
        }
        // The label above is what the row SAYS and changes as the pane does
        // — "widgets, db, active, working" — so it cannot also be the row's
        // name. The identifier is the name: stable for the life of the pane,
        // and the only thing a check may address the row by.
        .accessibilityIdentifier("rail.\(pane.id)")
    }

    private func label(_ pane: Pane) -> String {
        var parts = [pane.title, pane.kind]
        if model.layoutSnapshot.focusedId == pane.id { parts.append("active") }
        if pane.busy { parts.append("working") }
        return parts.joined(separator: ", ")
    }

    // MARK: - The tick

    /// §10: "the active pane gets a luminous left tick, a working pane glows
    /// green in the periphery."
    ///
    /// **This is where `Text(pane.busy ? "working" : "")` went.** The literal
    /// word, in cool white at 0.30 behind a 1.4px blur, is the least
    /// peripherally legible treatment available — a glyph has to be resolved.
    /// A hue shift on the tick does not, which is precisely why it survives
    /// the far plane, and a luminous tick is the one such mark §8 permits.
    ///
    /// `busy` is `Pane.busy`, set by `WindowModel` around any dispatch naming
    /// a pane — no spinner anywhere, and the window is genuinely brief,
    /// because a layout action is an in-memory actor call.
    ///
    /// **Working outranks active on a pane that is both**, because the tick
    /// is one mark and cannot carry two hues. The operator already knows
    /// which pane they focused; what they do not know is which pane has just
    /// started working, and §10 gives that state the louder signal. A row
    /// with no tick at all is neither.
    @ViewBuilder
    private func tick(_ pane: Pane) -> some View {
        let isActive = model.layoutSnapshot.focusedId == pane.id
        let colour: Color? =
            pane.busy
            ? Color(RailTreatment.workingTickColour)
            : (isActive ? Color(RailTreatment.activeTickColour) : nil)

        // The glow. A working pane keeps it in both states — it is the
        // periphery §10 is talking about, and at 0.30 the fill alone
        // composites to ≈2.05:1, which is a cue and not a reading. The
        // active tick's glow arrives with promotion, matching the
        // artboard: at rest the rail says *what is open*, and which one
        // is focused is the canvas's own news.
        LuminousTick(
            colour: colour,
            glow: pane.busy ? 0.85 : (promoted ? 0.70 : 0),
            glowRadius: pane.busy ? 5 : 4)
            .padding(.vertical, 8)
    }
}

/// The rail's luminous left tick (§10) as one mark: a 2 pt rounded bar in `colour` with its glow, or
/// nothing where `colour` is nil. The rail draws it against a row's height; a pane's own tabs — the
/// editor's strip and the browser's list (3c-i) — draw it at a fixed `height`, so a tab and a rail
/// row read as one kind of thing (`Browser.dc.html`'s `.tab .tick`).
struct LuminousTick: View {
    let colour: Color?
    /// Fixed, for a tab; nil fills the row the rail sizes it to.
    var height: CGFloat?
    var glow: Double = 0.70
    var glowRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(colour ?? .clear)
            .frame(width: 2, height: height)
            .shadow(color: (colour ?? .clear).opacity(glow), radius: glowRadius)
    }
}
