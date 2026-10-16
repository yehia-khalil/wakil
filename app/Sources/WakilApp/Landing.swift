import WakilKit
import SwiftUI

/// What the window draws before this session has done anything —
/// `LandingStates.dc.html`, and `WindowModel.sessionStarted`'s own doc
/// comment for why the axis is the session rather than the pane count.
///
/// **Two columns, and neither is chrome.** *Continue* is the org's sessions,
/// which is the one thing an operator opening Wakil most often wants and the
/// only place in the app that offers them outside ⌘P. *Open* is ⌘K's own
/// expanded rows — `pane_open`'s schema already declares `kind` as an enum of
/// `Pane.kinds`, so one action yields one row per kind and a third kind adds
/// its row for free. Both are gone the moment work starts, which is why
/// naming the pane kinds here costs §1 nothing: there is nothing yet to
/// occlude.
///
/// **What is deliberately absent.** The artboard draws a *This week* block of
/// session, turn and hour counts; nothing computes any of them, so it is not
/// drawn. A zeroed stat row is a claim that nothing happened, and three large
/// numerals reading 0 are worse than the space they take.
///
/// **Invariant 2.** Every control dispatches through `WindowModel` — a
/// Continue row through `continueSession` (`session_resume`), an Open row through
/// `openPane`/`openTerminalPane` — the same actions ⌘P's rows run.
struct Landing: View {
    let model: WindowModel

    @State private var sessions: [PaletteItem] = []
    @State private var projects: [WindowModel.ProjectListing] = []
    @State private var loaded = false
    @State private var hovered: String?

    /// With no project there is no environment, so a database pane cannot
    /// resolve a database to open against — and the one thing to do is pick
    /// a project. `LandingStates.dc.html` state 2 rules this; the first walk
    /// found the window offering "Database pane" in an org with no project,
    /// which is a row that can only refuse.
    private var hasProject: Bool { !model.project.isEmpty }

    private var coolWhite: Color { Color(red: 0.910, green: 0.925, blue: 0.965) }

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            if hasProject {
                column("Continue · newest first", width: 620) { continueRows }
                column("Open", width: 380) { openRows }
            } else {
                // The empty workspace's one job is to get you a project.
                column("Projects", width: 620) { projectRows }
                column("Continue · newest first", width: 380) { continueRows }
            }
            Spacer(minLength: 0)
        }
        // **Top-aligned, and greedy.** Without this the window's own `VStack`
        // sizes to the Landing's content and the whole thing floats in the
        // middle of the void — found on the first walk, in an org whose
        // Continue column was a single empty row. The canvas is greedy by way
        // of its `GeometryReader`; this branch has to say so itself.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(model.organization)/\(model.project)") {
            // Re-read on an org or project change: `session_list` filters to
            // the active project's roots and `ctx_list_projects` is
            // org-scoped, so neither list survives a switch.
            loaded = false
            // Projects first: `listProjects`' success clears `status`, and `landingSessions`
            // writes what any read could not answer, so it goes last.
            projects = await model.listProjects()
            sessions = await model.landingSessions()
            loaded = true
        }
    }

    // MARK: - Scaffolding

    /// How tall a column's slab may get before it scrolls.
    ///
    /// **Derived from the window's own minimum, not picked.** `WakilWindow`
    /// floors the window at 860pt. Above a column sit its padding (16), the
    /// context line (~50), the palette buttons (~30), this view's own top
    /// inset (34) and the column label (~23); below it the canvas's 48pt
    /// bottom padding (the composer bar plus its gap). That leaves ~530,
    /// and 460 keeps a margin so the slab never reaches the message field on
    /// the smallest window Wakil will open.
    ///
    /// Whoever changes the canvas's bottom padding or the Landing's top inset
    /// should recompute this — it is not derived automatically.
    private static let columnMaxHeight: CGFloat = 460

    private func column<Content: View>(
        _ label: String, width: CGFloat, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(coolWhite.opacity(0.52))
            // **Scrolls past the cap rather than growing.** An org with
            // thirty sessions ran the column off the top AND bottom of the
            // window and pushed the context line off-screen entirely — found
            // on the first walk against a real transcript store. The slab
            // still sizes to its content below the cap, so a short list does
            // not sit in a tall empty box.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(width: width, alignment: .leading)
            }
            .frame(width: width)
            .frame(maxHeight: Self.columnMaxHeight)
            // `.fixedSize` on the vertical axis only: the ScrollView is
            // greedy by nature and would otherwise take the whole cap even
            // for two rows.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
            .background(slab)
        }
    }

    /// §2: a slab — near-opaque, rounded, defined by a drop shadow and a
    /// half-pixel luminous edge rather than a border. No panel has an outline.
    private var slab: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(red: 0.055, green: 0.063, blue: 0.098))
            .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: - Continue

    @ViewBuilder
    private var continueRows: some View {
        if !loaded {
            note("Reading sessions…")
        } else if sessions.isEmpty {
            // **"None" and "could not read" must not look alike.** `landingSessions`
            // puts a partial listing's reason in `status`, which the window
            // draws — so this says only what it knows, and does not claim the
            // org has no sessions.
            note("Nothing to continue in this project")
        } else {
            ForEach(sessions) { item in
                row(id: item.id, title: item.title, subtitle: item.subtitle) {
                    Task { await model.continueSession(item.payload) }
                }
            }
        }
    }

    // MARK: - Projects

    @ViewBuilder
    private var projectRows: some View {
        if !loaded {
            note("Reading projects…")
        } else if projects.isEmpty {
            note("No projects in \(model.organization.isEmpty ? "this organisation" : model.organization) yet")
        } else {
            ForEach(projects) { project in
                row(
                    id: "project:\(project.name)",
                    title: project.name,
                    // A project has 1..n roots (Decision 7), so the registry
                    // entry's own recorded path is what this is — not "the"
                    // root, and named as the provider when there is one.
                    subtitle: project.provider ?? project.path ?? ""
                ) {
                    Task { await model.setProject(project.name) }
                }
            }
        }
    }

    // MARK: - Open

    /// One row per pane kind this build can draw, read from `Pane.kinds`
    /// rather than listed here — the set that governs `pane_open`'s own enum
    /// governs this too, so a third kind cannot arrive with a row missing.
    @ViewBuilder
    private var openRows: some View {
        ForEach(Pane.kinds.sorted(), id: \.self) { kind in
            row(id: "open:\(kind)", title: Self.label(for: kind), subtitle: "pane_open · \(kind)") {
                Task {
                    // `term_open` both opens the pane AND starts its shell;
                    // `pane_open` alone would leave a dead pane with no
                    // shell, which is walk-defect B2. Same split
                    // `WakilWindow`'s buttons already make.
                    if kind == "terminal" {
                        await model.openTerminalPane()
                    } else {
                        await model.openPane(kind: kind)
                    }
                }
            }
        }
    }

    /// The operator-facing name of a pane kind. `kind` is the wire word and
    /// stays it; this is the only place the two differ, and an unknown kind
    /// falls back to the wire word rather than being hidden — a pane this
    /// build can open should never be unreachable because nobody wrote it a
    /// label.
    private static func label(for kind: String) -> String {
        switch kind {
        case "db": return "Database pane"
        case "terminal": return "Terminal pane"
        case "git": return "Git"
        default: return kind
        }
    }

    // MARK: - One row

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(coolWhite.opacity(0.46))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
    }

    private func row(
        id: String, title: String, subtitle: String, action: @escaping () -> Void
    ) -> some View {
        let isHovered = hovered == id
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(coolWhite.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !subtitle.isEmpty {
                // §6: identifiers are monospace, always.
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.50))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .background(coolWhite.opacity(isHovered ? 0.04 : 0))
        .contentShape(Rectangle())
        .onHover { hovering in
            // §7, and the artboards' own `transition: background 240ms
            // ease-out` on a palette row.
            withAnimation(.easeOut(duration: 0.24)) { hovered = hovering ? id : nil }
        }
        .onTapGesture(perform: action)
        // **A tappable `VStack` is not a button to anybody but a mouse.**
        // Before this, every landing row — including the one that opens the
        // terminal pane — reached the accessibility tree as two loose
        // `Text`s with no trait, no activation and no name: unreachable by
        // VoiceOver, and unaddressable by a check. `.combine` keeps the
        // title and subtitle as the row's spoken text, which is what an
        // operator recognises it by.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // Without this the trait is a claim the row cannot honour: a tap
        // gesture is not an accessibility action, so VoiceOver would
        // announce a button that does nothing when activated.
        .accessibilityAction(.default, action)
        // `id` is already unique across the landing's three sections —
        // "project:wakil", "open:terminal", a session id — and is what the
        // hover state keys on, so it is the row's name here too.
        .accessibilityIdentifier("landing.row.\(id)")
    }
}
