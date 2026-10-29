import WakilKit
import SwiftUI

/// The active `(org, project, environment)` triple — Invariant 5's whole
/// state — drawn as one line that promotes under the pointer.
///
/// **This is `design-language.md` §3's promotion rule being spent for the
/// first time.** That section has always said *"far-plane content is never
/// interactive without first being promoted"*, and until now nothing in the
/// application promoted anything: the context line was a `Text` with the far
/// plane's scale, opacity and parallax baked in, and the only way to change
/// the triple was two raw `TextField`s below it that the operator typed a
/// guess into. So the window could *switch* to a project or an environment
/// and could not *enumerate* either. `ctx_list_environments` (added beside
/// this) is the missing half of the second one.
///
/// **Resting is ambient; hovering is the control.** At rest this is the
/// §3 far-plane line it has always been — no slab, no chevrons, nothing
/// claiming to be pressable. Bring the pointer to it and scale, opacity and
/// blur are released *together* — §3's "never one alone" — over §7's
/// 400-600ms ease-out, and the three segments appear. Nothing is added to
/// the window's resting state at all, which is the point: §1 is futurism
/// through absence, and a permanent slab holding three words the operator
/// already knows is the chrome it removes.
///
/// **The environment is exempt from the resting treatment, not from the
/// promotion.** Invariant 8 puts the active environment on screen *at all
/// times* and `EnvironmentBadge` exists because the far plane's own opacity
/// and blur composited it to 1.47:1 in production. So the chip keeps that
/// exemption while org and project ride the plane whole: at rest the two
/// names are ambient and the environment is readable. Promotion lifts the
/// other two to meet it rather than lifting it at all.
///
/// **Organisation escalates; it does not open a menu.** The three axes are
/// one invariant and three different events. Switching environment
/// invalidates pane *contents*; switching organisation ends the session,
/// closes every pane, respawns the servers a session carries and crosses a
/// credential boundary (Invariant 4). Handing the rare destructive one the
/// same one-click menu as the daily one is how an operator lands in the
/// wrong org, so this segment carries a *trailing* chevron rather than a
/// disclosure one and opens ⌘⇧O's plane — the surface that already owns
/// creation, adoption, the queued-switch state and the cancel. 2b-viii's
/// machinery is reused rather than rebuilt at a second entrance.
///
/// **Invariant 2.** Nothing here mutates context except by calling a
/// `WindowModel` method that itself dispatches through the registry
/// (`listProjects`, `listEnvironments`, `setProject`, `setEnvironment`), and
/// `showOrgPlane` is the same presentation flag ⌘⇧O already sets. Which
/// segment is open is view state, exactly as `OrgPlane`'s own `phase` is.
struct ContextLine: View {
    let model: WindowModel
    /// The far plane's current parallax offset, passed in rather than
    /// recomputed: `WakilWindow` already derives it once per frame from the
    /// cursor, and a second derivation here would drift from the rail's.
    let parallax: (x: Double, y: Double)

    private enum Segment: Hashable, Sendable { case none, project, environment, branch }

    /// This view's own coordinate space, so a segment's measured frame is
    /// relative to the line rather than to the window — the offsets below
    /// stay correct wherever `WakilWindow` puts this.
    private static let space = "contextline"

    /// §7's plane transition, taken at the bottom of its 400-600ms band:
    /// this is a control the operator crosses dozens of times a day, not the
    /// room breathing. One constant so the hover and the segment toggle
    /// cannot drift into two different speeds.
    private static let promote: Animation = .easeOut(duration: 0.40)

    /// §7 again, and the artboards' own `transition: background 240ms
    /// ease-out` on a palette row. A row highlight is not a plane move and
    /// should not borrow a plane move's duration.
    private static let rowHover: Animation = .easeOut(duration: 0.24)

    @State private var open: Segment = .none
    @State private var hovering = false
    @State private var segmentFrames: [Segment: CGRect] = [:]
    /// Which menu row the pointer is on, by title — the rows of one menu are
    /// distinct by name (a project name and an environment name are both
    /// unique within their listing), and only one menu is open at a time.
    @State private var hoveredRow: String?
    @State private var projects: [WindowModel.ProjectListing] = []
    @State private var environments: [EnvironmentListing] = []

    /// §5's cool white, and the two hues this file is allowed to spend.
    /// Green, amber and red belong to the environment and are never
    /// decorative, so nothing below reaches for one except the environment
    /// chip itself — which is the one thing here that *is* an environment.
    private var coolWhite: Color { Color(red: 0.910, green: 0.925, blue: 0.965) }   // #e8ecf6
    private var accent: Color { Color(VoidPalette.accent) }  // #9e82ff

    /// Promoted whenever the pointer is on the line or a segment is open —
    /// the menu must not evaporate the instant the pointer leaves the line
    /// to travel into it.
    private var isPromoted: Bool { hovering || open != .none }

    /// Whether a segment has anything to open.
    ///
    /// **`ContextStates.dc.html`: "No chevron, because there is nothing to
    /// open."** The segment still draws — Invariant 8 puts the environment on
    /// screen at all times, and "only one" is not "none". What goes is the
    /// affordance that would promise a menu and then show a list of one.
    ///
    /// Applied to Project on the same reasoning, with one dated caveat: the
    /// artboard rules this for Environment, where there is no create path at
    /// all, and the project menu is a list of one only because creating a
    /// project is unbuilt. When a "New project" row lands the menu stops
    /// being a list of one and the chevron comes back — this predicate is
    /// where that change belongs, not a second rule somewhere else.
    private func hasChoice(_ segment: Segment) -> Bool {
        switch segment {
        case .project: return projects.count > 1
        case .environment: return environments.count > 1
        // 3a-iv: the picker always has something to offer (create, fetch) when there is a git root.
        case .branch: return model.branchSegment != nil
        case .none: return false
        }
    }

    private var isProduction: Bool {
        VoidPalette.forEnvironment(model.environment, production: model.environmentProduction).isProduction
    }

    var body: some View {
        Group {
            if isPromoted {
                promoted.transition(.opacity)
            } else {
                resting.transition(.opacity)
            }
        }
        // **The menu is an overlay anchored under the segment that opened
        // it, not a row in a `VStack` under the line.** It was the latter on
        // the first operator walk (2026-09-20) and landed at the line's
        // leading edge whichever segment was open — a menu that forgets which
        // control opened it is a modal wearing a dropdown's clothes, which is
        // what `Context.dc.html` says in so many words and what the
        // implementation was quietly not doing.
        //
        // An overlay rather than a `ZStack` member because an overlay does
        // not participate in the parent's sizing: the menu is ~170pt tall and
        // a `ZStack` would have made the context line that tall, pushing the
        // canvas down whenever a segment was open. `.offset` is a render-time
        // transform for the same reason.
        //
        // Positions come from `segmentFrames`, measured in this view's own
        // coordinate space — segments are content-sized, so there is no
        // arithmetic over fixed widths and gaps that could be right today and
        // wrong the first time an organisation has a longer name.
        .overlay(alignment: .topLeading) {
            if let frame = segmentFrames[open] {
                // It hangs over the canvas: its clicks focus no pane under it (3b-v PR 8).
                menu.background(ClickShield()).offset(x: frame.minX, y: frame.maxY + 9)
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SegmentFrameKey.self) { frames in
            // Merged, not replaced: the Branch segment drops out for a moment while a switch re-reads
            // its root, and a replaced map left its menu nowhere to hang until the line was drawn
            // again (3a-iv walk). A segment's last place stands until it reports a new one.
            segmentFrames.merge(frames) { _, new in new }
        }
        // **No opacity and no blur, in either state.** This line was filed on
        // §3's far plane, and `EnvironmentBadge` was then created to exempt
        // one third of it — because 0.30 behind a 1.4px blur put the badge at
        // 1.47:1 in the state Invariant 8 calls unmissable. The other two
        // thirds were never exempted and land near 2.4:1, which is the same
        // defect the rail carried (#138, fixed 2026-09-21 — by promotion
        // rather than by an exemption, because the rail has moments when it
        // genuinely is not being read and this line does not). PRODUCT.md
        // binds 4.5:1 against the actual composite for anything being *read*,
        // and an organisation and a project are read.
        //
        // So the badge's treatment governs the whole line rather than one
        // element of it: the far plane's scale and parallax kept, its opacity
        // and blur lifted. **Hierarchy does the quieting** — 19pt against
        // 11pt monospace against a chip — which is what §5 means by stepping
        // text down by opacity rather than by hue, without stepping it below
        // the floor.
        .scaleEffect(
            isPromoted ? Plane.mid.scale : EnvironmentBadge.scale, anchor: .topLeading)
        // §7's plane transition, 400-600ms ease-out, taken at the bottom of
        // the band because this is a control the operator crosses dozens of
        // times a day rather than the room breathing.
        //
        // **The two states are different view trees, so this is a crossfade
        // and not a tween** — and that has to be said out loud, because the
        // first build of this file animated by accident. Resting and promoted
        // shared their subviews then and differed only in modifier values, so
        // SwiftUI interpolated them for free. Once resting became a cluster
        // and promoted a slab of labelled segments, the `if` became an
        // insertion and a removal, which do not interpolate: the control
        // snapped. The explicit `.transition(.opacity)` on each branch above
        // is what restores it. Found on the first operator walk, 2026-09-20.

        // The far plane's drift, kept in both states: promotion changes how
        // legible the line is, not where in the room it sits. No `.animation`
        // on this one — `farOffset` is already a smooth function of the
        // cursor, and keying an ease on it would lag the plane behind.
        .offset(x: parallax.x, y: parallax.y)
        // **`withAnimation` at the mutation site, not `.animation(value:)`
        // on the container.** The container form drives property changes but
        // is unreliable for a structural `if` — resting and promoted are
        // different view trees, so the change is an insertion and a removal,
        // and the transaction has to be animated where the state actually
        // moves. Two walks were spent on this: the first restored the
        // transitions and still snapped, because nothing was animating the
        // transaction that carried them.
        .onHover { isHovering in
            withAnimation(Self.promote) { hovering = isHovering }
        }
        // Named as a whole, so a check can hold what draws at the top right — the agent chips —
        // clear of it at a narrow window. Its segments stay their own elements inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.contextLine")
        // **Read at rest, not only on click** — `ContextStates.dc.html` rules
        // that a segment with one option gets no chevron ("a control that
        // offers a choice of one is a lie"), and the count is not knowable
        // from the active value alone. So both listings load when the context
        // changes rather than when a menu opens. Two actor hops on a project
        // switch, off the frame path; the menus keep re-reading on open,
        // because a project added on disk between the two should still show.
        .task(id: "\(model.organization)/\(model.project)") {
            projects = await model.listProjects()
            environments = model.project.isEmpty ? [] : await model.listEnvironments()
        }
    }

    // MARK: - Resting

    /// One cluster, one fact: *where I am*. Not a dimmed copy of the control
    /// below — three equal-weight values in fixed-width segment boxes read as
    /// three separate controls and take three times the width to say less.
    private var resting: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ORGANISATION")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(coolWhite.opacity(0.52))
            HStack(alignment: .firstTextBaseline, spacing: 15) {
                Text(model.organization.isEmpty ? "unknown" : model.organization)
                    .font(.system(size: 19))
                    .foregroundStyle(coolWhite)
                // §6: identifiers are monospace, always.
                Text(model.project.isEmpty ? "no project" : model.project)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.50))
                // Absent with no project, for the reason the segment is: an
                // environment lives inside a project's own map, so there is
                // nothing here to be unset from.
                if !model.project.isEmpty { chip }
                // 3a-iv: the active root's branch, an identifier, so monospace (§6).
                if let branch = model.branchSegment {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(0.50))
                        .lineLimit(1).truncationMode(.middle)
                }
                // Workspaces, piece 1: the view's workspace (Main names none), whole.
                if let workspace = model.workspaceOnScreen {
                    Text("› \(workspace.name)")
                        .font(.system(size: 11))
                        .foregroundStyle(coolWhite.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("window.contextLine.workspace")
                }
            }
        }
    }

    /// The environment, as a filled token. Drawn identically at rest and
    /// promoted: Invariant 8's treatment does not change because the pointer
    /// arrived, and only the chevron is added.
    private var chip: some View {
        Text(model.environmentLabel.uppercased())
            .font(.system(size: 8.5, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Color(EnvironmentBadge.chipColour(isProduction: isProduction)))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(EnvironmentBadge.chipColour(isProduction: isProduction))
                        .opacity(EnvironmentBadge.chipTintOpacity(isProduction: isProduction))))
    }

    // MARK: - Promoted

    private var promoted: some View {
        HStack(alignment: .top, spacing: 28) {
            organisation
            project
            environment
            branch
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        // §2: a slab — near-opaque, rounded, a half-pixel luminous edge in
        // place of a border and a drop shadow. No panel has an outline.
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.055, green: 0.063, blue: 0.098))
                .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private var organisation: some View {
        segment(label: "Organisation", chevron: .trailing, isOpen: false) {
            Text(model.organization.isEmpty ? "unknown" : model.organization)
                .font(.system(size: 14.5))
                .foregroundStyle(coolWhite.opacity(0.82))
        } action: {
            withAnimation(Self.promote) { open = .none }
            model.showOrgPlane = true
        }
    }

    private var project: some View {
        segment(
            label: "Project",
            chevron: hasChoice(.project) ? .disclosure(up: open == .project) : .none,
            isOpen: open == .project
        ) {
            Text(model.project.isEmpty ? "no project" : model.project)
                .font(.system(size: 14.5))
                .foregroundStyle(coolWhite.opacity(open == .project ? 1 : 0.82))
        } action: {
            toggle(.project)
        }
        .background(reporting(.project))
    }

    /// 3a-iv: the Branch segment, opening the branch picker for the active root.
    @ViewBuilder
    private var branch: some View {
        if let text = model.branchSegment {
            segment(label: "Branch", chevron: .disclosure(up: open == .branch), isOpen: open == .branch) {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(open == .branch ? 1 : 0.82))
                    .lineLimit(1).truncationMode(.middle)
            } action: {
                toggle(.branch)
            }
            .background(reporting(.branch))
            .accessibilityIdentifier("window.contextLine.branch")
        }
    }

    @ViewBuilder
    private var environment: some View {
        if !model.project.isEmpty {
            segment(
                label: "Environment",
                chevron: hasChoice(.environment)
                    ? .disclosure(up: open == .environment) : .none,
                isOpen: open == .environment
            ) {
                chip
            } action: {
                toggle(.environment)
            }
            .background(reporting(.environment))
        }
    }

    // MARK: - One segment

    private enum Chevron: Equatable {
        case none
        case trailing
        case disclosure(up: Bool)
    }

    private func segment<Value: View>(
        label: String,
        chevron: Chevron,
        isOpen: Bool,
        @ViewBuilder value: () -> Value,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // §6: micro-labels are uppercase, .16-.22em at 8-9.5px. They exist
            // only once promoted — at rest the cluster carries one label, not
            // three, because three labels over three words is the density §1
            // spends its first principle on.
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(coolWhite.opacity(0.52))
            HStack(spacing: 8) {
                value()
                chevronView(chevron, isOpen: isOpen)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    /// Carries each segment's frame up to the line, so an open menu can be
    /// offset to sit under the control that opened it.
    ///
    /// **Merges rather than replacing**, unlike a scalar preference: the two
    /// segments report independently and each must survive the other's
    /// update. Taking `nextValue()` wholesale would leave only whichever
    /// reported last, and the menu would jump to the wrong column on
    /// alternate layout passes.
    ///
    /// Keyed by `Segment` rather than `AnyHashable`: the erased form is not
    /// `Sendable`, and a `PreferenceKey`'s `defaultValue` is a static that
    /// Swift 6 checks.
    private struct SegmentFrameKey: PreferenceKey {
        private static let empty: [Segment: CGRect] = [:]
        static var defaultValue: [Segment: CGRect] { empty }
        static func reduce(value: inout [Segment: CGRect], nextValue: () -> [Segment: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    /// Where each segment sits, so its menu can hang under it. Measured
    /// rather than computed: `.background` of a `GeometryReader` is the
    /// established idiom in this window (`AccountWidthKey`, and the thought
    /// thread's own anchor), and it costs nothing on the frame path because
    /// it only fires when the layout actually changes.
    private func reporting(_ segment: Segment) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: SegmentFrameKey.self,
                value: [segment: geometry.frame(in: .named(Self.space))])
        }
    }

    @ViewBuilder
    private func chevronView(_ chevron: Chevron, isOpen: Bool) -> some View {
        switch chevron {
        case .none:
            EmptyView()
        case .trailing:
            // Drawn, not a glyph: §4 permits no ornaments and the rest of
            // this app's marks are authored paths at a consistent stroke.
            Path { path in
                path.move(to: CGPoint(x: 3.5, y: 1))
                path.addLine(to: CGPoint(x: 7.5, y: 5))
                path.addLine(to: CGPoint(x: 3.5, y: 9))
            }
            .stroke(coolWhite.opacity(0.42), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 11, height: 10)
        case .disclosure(let up):
            Path { path in
                path.move(to: CGPoint(x: 1, y: up ? 6.5 : 2.5))
                path.addLine(to: CGPoint(x: 5, y: up ? 2.5 : 6.5))
                path.addLine(to: CGPoint(x: 9, y: up ? 6.5 : 2.5))
            }
            .stroke(
                isOpen ? accent : coolWhite.opacity(0.42),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: 10, height: 9)
        }
    }

    // MARK: - The menu

    /// The branch picker's writes, through the window's `editor_changes_*` actions (Invariant 2).
    private var branchActions: BranchPickerActions {
        let model = model
        return BranchPickerActions(
            load: { await model.changesBranches(root: $0) },
            switchTo: { root, branch, carry, track in await model.changesSwitch(root: root, branch: branch, carry: carry, track: track) },
            create: { root, name, from in await model.changesBranchCreate(root: root, name: name, from: from) },
            fetch: { await model.changesFetch(root: $0) })
    }

    @ViewBuilder
    private var menu: some View {
        // §2: a slab — near-opaque, rounded, defined by a drop shadow and a
        // half-pixel luminous edge rather than a border. No outline.
        VStack(alignment: .leading, spacing: 0) {
            switch open {
            case .project:
                if projects.isEmpty {
                    emptyRow("No projects in this organisation")
                } else {
                    ForEach(projects) { row in
                        menuRow(
                            title: row.name,
                            subtitle: row.provider ?? row.path ?? "",
                            isCurrent: row.name == model.project,
                            tint: nil
                        ) {
                            withAnimation(Self.promote) { open = .none }
                            Task { await model.setProject(row.name) }
                        }
                    }
                }
            case .environment:
                if environments.isEmpty {
                    // "None" and "could not read" must not look alike, and
                    // this row cannot yet tell them apart: `structuredResult`
                    // puts the failure in `status`, where the window draws it.
                    emptyRow("No environments in this project")
                } else {
                    ForEach(environments) { row in
                        menuRow(
                            title: row.name,
                            subtitle: row.isReadOnly ? "nothing writable" : "writable",
                            // #182: a `prod` with no production flag, or a
                            // `production` declaring false, drawn ON its own
                            // row. They were heaped above the list, which
                            // truncated them and put the warning nowhere near
                            // the name it was about.
                            notice: row.notice,
                            isCurrent: row.name == model.environment,
                            // §5's red is the environment's own, and
                            // Invariant 8 wants production unmissable at the
                            // moment it is chosen — a list is the last one
                            // before the room turns.
                            tint: row.isProduction
                                ? Color(red: 0.910, green: 0.361, blue: 0.361) : nil
                        ) {
                            withAnimation(Self.promote) { open = .none }
                            Task { await model.setEnvironment(row.name) }
                        }
                    }
                }
            case .branch:
                if let active = model.activeBranchRoot {
                    BranchPicker(roots: model.gitRoots, startRoot: active.root, actions: branchActions) {
                        withAnimation(Self.promote) { open = .none }
                    }
                }
            case .none:
                EmptyView()
            }
        }
        .padding(.vertical, 6)
        .frame(width: open == .branch ? 340 : 302, alignment: .leading)
        // Clear on open, so a row the pointer left while the menu was closed
        // does not come back still lit.
        .onAppear { hoveredRow = nil }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.055, green: 0.063, blue: 0.098))            // #0e1019
                .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(coolWhite.opacity(0.46))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private func menuRow(
        title: String,
        subtitle: String,
        notice: String? = nil,
        isCurrent: Bool,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredRow == title
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(tint ?? coolWhite.opacity(isCurrent ? 1 : 0.82))
                if !subtitle.isEmpty {
                    // §6: identifiers and measurements are monospace, always.
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle((tint ?? coolWhite).opacity(tint == nil ? 0.50 : 0.66))
                }
                if let notice, !notice.isEmpty {
                    // §5's amber is "pending · caution", which is exactly
                    // what this is. NOT red: red is reserved for
                    // production, and every environment carrying a notice
                    // is one the flag says is NOT production — colouring
                    // the warning red would assert the thing it exists to
                    // deny. Prose rather than monospace, and wrapped
                    // rather than truncated: it is a sentence, not an
                    // identifier.
                    Text(notice)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 0.910, green: 0.706, blue: 0.353))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        // Three states, stepped rather than switched: the row you are ON
        // sits highest, the row you are POINTING AT is lifted a little, and
        // the rest are the slab. Both are the same cool white at different
        // opacities — §5 steps text and surface down by opacity, never by a
        // different hue, and a hover that introduced a colour would be the
        // one decorative use of one in this file.
        .background(
            coolWhite.opacity(isCurrent ? 0.06 : (isHovered ? 0.04 : 0)))
        .onHover { hovering in
            withAnimation(Self.rowHover) { hoveredRow = hovering ? title : nil }
        }
        // §8's anchor mark — the one luminous element permitted inside a
        // surface, and the same tick the rail gives the focused pane and the
        // palette gives the selected row. It means "this is the one you are
        // on", a fact about the cursor and not about production, so it stays
        // violet even on a red row.
        //
        // **An overlay, not an `HStack` sibling, and that is the bug this
        // fixes.** A `RoundedRectangle` with `.frame(width: 2)` is constrained
        // in one axis only: it stays greedy vertically, accepts whatever
        // height the parent offers, and drags the whole row up to it. The
        // window's `VStack` offers a lot, so every menu row rendered about
        // 125pt tall instead of 48 — found on the first operator walk,
        // 2026-09-20. An overlay is proposed the row's *own* size, so the
        // inset here is bounded by the content the way the artboard's
        // `top: 7px; bottom: 7px` always was.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(isCurrent ? accent : .clear)
                .frame(width: 2)
                .shadow(color: isCurrent ? accent.opacity(0.7) : .clear, radius: 4)
                .padding(.vertical, 7)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    // MARK: - Opening a segment

    /// Opens `segment`, closing whatever was open, and refreshes its rows.
    ///
    /// **Read on open, not cached at launch.** Both listings change under
    /// the window — a project added on disk, an org switch replacing the set
    /// wholesale — and a menu drawn from a snapshot taken at startup is how
    /// an operator comes to pick a project that is no longer there. The cost
    /// is one actor hop on a click, which is not on a frame path.
    private func toggle(_ segment: Segment) {
        // A segment with nothing to open does not open. Checked here as well
        // as on the chevron so the two cannot disagree — a row that draws no
        // affordance and still responds to a click is the same lie told
        // quietly.
        guard hasChoice(segment) else { return }
        guard open != segment else {
            withAnimation(Self.promote) { open = .none }
            return
        }
        withAnimation(Self.promote) { open = segment }
        Task {
            switch segment {
            case .project: projects = await model.listProjects()
            case .environment: environments = await model.listEnvironments()
            case .branch, .none: break
            }
        }
    }
}
