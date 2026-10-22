import AppKit
import Foundation
import WakilKit
import SwiftUI

/// The window: one plain SwiftUI scene, deliberately unstyled.
///
/// 2a's half of it is the context labels, the query field, the database
/// table and the thought thread. The magnetic canvas — added in 2b-i — is
/// *structure*; 2b-ii is where `design-language.md` is applied to it,
/// adding the void, the planes, the Core and the thought thread. 2b-iv then
/// deleted the Core as an object and gave its four states to the room, so
/// there is one Metal layer here rather than two and nothing luminous is
/// drawn in front of a pane at all — the thought thread does sit in front
/// of the canvas (§3's near plane "may overlap"), but it does not glow.
///
/// **No colours, no motion, no custom fonts, and no styling modifiers of any
/// kind.** That is a decision, not an omission. This phase's job is to prove
/// the spine — that registry-owned state renders, that a UI control and the
/// agent reach the same action set, that the environment is on screen
/// (Invariant 8) — and every visual choice made now would be a choice 2b's
/// real design has to undo. Spec §7 says the same of the pane: "no
/// virtualization, no density toggle, no chips, no type annotations — 2c
/// builds the real §8 data surface".
///
/// Everything this file does that is *not* drawing lives in `WindowModel`
/// (`WakilKit/App/WindowModel.swift`) and is unit-tested there. A test target
/// cannot import an executable target, so what remains here — the layout, the
/// scene, the termination hook, the gestures — is covered by the operator
/// runbooks in `docs/wakil/phase-2a-acceptance.md` and
/// `docs/wakil/phase-2b-i-acceptance.md`, and by nothing else. Keeping this
/// file thin is what keeps that uncovered surface small.

// MARK: - The window

struct WakilWindow: View {
    let delegate: WakilAppDelegate

    /// The window's undo, where a landed commit-message draft registers its ⌘Z (3a-ii-b).
    @Environment(\.undoManager) private var undoManager
    @State private var session: WindowSession?
    /// 2d-ii: Task 13 binds this into the thread view; the composer bar's
    /// Esc that listening did not consume folds it.
    @State private var threadDisclosure = ThreadDisclosure()

    /// How far each pane has been dragged since its gesture began, and how
    /// much each has been stretched since its resize gesture began.
    ///
    /// **These are what keeps the drawing off the actor.** A gesture updates
    /// the entry here on every pointer-moved event — local `@State`, no
    /// dispatch — so the pane follows the pointer at frame rate and no frame
    /// ever waits on `LayoutStore` to know where to draw it. The store
    /// learns where the pane landed exactly once, from
    /// `commitDrag`/`commitResize` in `onEnded`: a 400-frame drag journals
    /// one entry, not four hundred, which is §4.1's commit granularity and
    /// the half of §7 that is a code property rather than a benchmark.
    ///
    /// **They are not the whole of §7's "no await on the drag path", and the
    /// pointer-moved path does await.** `previewDrag` dispatches nothing —
    /// it only asks what a release *would* snap to — but `LayoutStore` is an
    /// actor, so asking costs a hop per event, and there is no way to draw a
    /// snap line without asking. What the rule can therefore mean is what is
    /// true here: no action is dispatched per event, and no *frame* blocks
    /// on the answer, because the offset above is already on screen by the
    /// time the answer arrives. The hop itself is made from one coalescing
    /// task (`schedulePreview`) rather than an unstructured `Task` per
    /// event, so a later preview cannot land before an earlier one.
    @State var dragOffsets: [String: CGSize] = [:]
    /// The frame each live drag was measured from (#353): its offset is drawn
    /// only while the pane still has this frame (`paneDrawOrigin`).
    @State var dragFrom: [String: PaneFrame] = [:]
    @State var resizeOffsets: [String: CGSize] = [:]
    /// Where the operator stands in the settings tree. **Held here, not in
    /// the pane,** so it outlives the pane: a provider switch swaps the
    /// canvas's layout and the settings pane is rebuilt, and pane-local state
    /// sent the operator back to the organisation node after every USE.
    /// Reset when the organisation changes, whose tree has other nodes.
    @State var settingsSelection: SettingsNode = .organisation
    /// Which branches of the settings tree are open (2026-10-21). Held here for the same reason,
    /// window-life and never persisted; forgotten with the organisation, whose tree it described.
    @State var settingsExpansion = SettingsTreeExpansion()

    /// The single in-flight snap preview, and the position it should ask
    /// about next. See `schedulePreview`.
    @State var previewTask: Task<Void, Never>?
    @State var pendingPreview: (id: String, x: Double, y: Double)?

    /// The open palette, or none. Made by ⌘P / ⌘K (`openPalette`), dropped on its close.
    @State private var palette: PaletteController?

    /// What the operator has typed into the confirmation plane so far.
    /// Not `private`: `Canvas.swift` (a separate file, `extension
    /// WakilWindow`) is where the plane is actually drawn, for the same
    /// reason `dragOffsets`/`cursor` above are widened past `private`.
    /// Cleared whenever `model.pending` becomes `nil` — see `canvas(_:)` —
    /// so a previous proposal's half-typed word never carries into the
    /// next one.
    @State var typedConfirmation = ""

    /// The cursor's position in the window, and the window's size — the two
    /// inputs `Plane.parallaxOffset` needs.
    ///
    /// Local `@State`, updated on every pointer-moved event, exactly as
    /// `dragOffsets` is and for the same reason: §10's rule is that nothing
    /// on the frame path awaits. A parallax that dispatched an action per
    /// event would journal thousands of entries and put an actor hop
    /// between the pointer and the frame.
    ///
    /// Not `private`: `Rail.swift` is a separate file (`extension
    /// WakilWindow`), and Swift's `private` is file-scoped, so `rail(_:)`
    /// needs `cursor` and `farOffset` at `internal` visibility to read
    /// them — the same reason `dragOffsets`/`resizeOffsets` were widened.
    @State var cursor: CGPoint = .zero
    @State var windowSize: CGSize = .zero

    /// Where §9's thread meets the bottom edge, in uv — what the void's
    /// local bleed lift is centred on.
    ///
    /// **Measured, never assumed.** A constant would silently drift the glow
    /// away from the thread the first time anybody changed this window's
    /// padding, and the drift would be invisible in a still.
    @State private var threadAnchorX: Double = 0.5
    /// When the thread last gained a row. Drives `ThreadLift`'s decay, so
    /// the glow fades with the thread rather than snapping off with it.
    @State private var lastRowAt: Date?
    @State private var lastRowCount = 0

    /// The far plane's offset for the current cursor and window size —
    /// computed once and shared by the void, the rail and the context line.
    ///
    /// Not `private`: `Rail.swift` reads this too (see `cursor`'s doc
    /// comment).
    var farOffset: (x: Double, y: Double) {
        Plane.far.parallaxOffset(
            cursor: (x: cursor.x, y: cursor.y),
            in: (width: windowSize.width, height: windowSize.height))
    }

    /// The near plane's offset for the current cursor and window size.
    /// Opposes `farOffset` at half the distance (`Plane.near.parallaxFactor`
    /// is -0.5 against `Plane.far`'s +1).
    ///
    /// **Consumed by the thought thread.** This was the Core's parallax
    /// until 2b-iv deleted the Core as an object; 2b-iv Task 5 hands it to
    /// `ThoughtThread` instead, passed in `body` as its `parallax`. The
    /// offset itself (the near plane opposing the far one) never depended
    /// on who was drawing it, which is why it survived the Core's deletion
    /// unchanged.
    ///
    /// Not `private`, matching `farOffset` — see `cursor`'s doc comment.
    var nearOffset: (x: Double, y: Double) {
        Plane.near.parallaxOffset(
            cursor: (x: cursor.x, y: cursor.y),
            in: (width: windowSize.width, height: windowSize.height))
    }

    /// §10: "the rail and Core fade back" when a pane is maximized — the
    /// operator's attention is on the one pane filling the void, and the
    /// chrome around it should defer rather than compete.
    ///
    /// Not `private`: `Rail.swift` reads this too (see `cursor`'s doc
    /// comment).
    var isMaximized: Bool { session?.model.layoutSnapshot.maximizedId != nil }

    /// Whether a session exists AND has an organisation open — Task 14,
    /// spec §8.5. `false` before `session` exists (the plain "starting…"
    /// launch text) and `false` again for an org-less window, which is the
    /// one surface in the app that belongs to no organisation: no canvas, no
    /// rail, no thread, no account indicator, and (below) no bleeds in the
    /// void either. The org plane itself is the only thing drawn in that
    /// case, and it is drawn unconditionally rather than gated on this.
    var hasOpenOrg: Bool { !(session?.model.organization.isEmpty ?? true) }

    /// Converts the thread's laid-out frame into the uv the shader wants.
    /// Clamped, because a thread wider than the window — a long tool name in
    /// a narrow window — would otherwise centre the glow off-canvas.
    ///
    /// **Layout position, not rendered position.** `ThoughtThread` applies
    /// the near plane's parallax with `.offset`, which is a render-time
    /// transform SwiftUI layout never sees — `geometry.frame(in:)` reports
    /// where the thread would sit with no offset applied. That is
    /// deliberate, not a gap: the glow should track where the thread lives,
    /// not jitter ±4pt with every cursor move the parallax makes.
    ///
    /// Guards two zero cases, both reachable: `windowSize.width` is `.zero`
    /// until the window's own `GeometryReader` has fired once, and the
    /// thread's own frame is zero-width while `rows` is empty (nothing laid
    /// out yet) — in the latter case `frame.midX` sits at the leading
    /// padding, which would park the glow at the window's left edge were it
    /// not guarded here. `threadLift` is separately gated on `hasRows`, so
    /// an unreported `threadAnchorX` is never visible on its own, but a
    /// wrong value left in the uniform to be saved by a second condition
    /// elsewhere is not a property worth relying on.
    private func reportThreadAnchor(_ geometry: GeometryProxy) {
        let frame = geometry.frame(in: .named("window"))
        guard windowSize.width > 0, frame.width > 0 else { return }
        threadAnchorX = min(max(frame.midX / windowSize.width, 0), 1)
    }

    /// Task 10: the running account. `label` is `WindowModel.providerLabel`
    /// — already the honest "unset" rather than an empty string, so this
    /// view never has to decide what a blank provider id means.
    ///
    /// **Violet, not white — deliberately, and only here.** Every other
    /// piece of text in this file is cool white per §5 ("text is cool white
    /// stepped down by opacity, never by a different hue"), stepped down
    /// only in *opacity*. The account indicator cannot follow that rule
    /// verbatim: §5 also reserves green/amber/red for environment semantics
    /// ("never decorative, anywhere"), which rules out the one device this
    /// file otherwise has for a second axis of meaning (the environment
    /// badge above turns red for production). What is left is §5's other
    /// named hue — luminance violet, `#7c5cff`, the app's own accent rather
    /// than an environment colour — carried at low opacity for the label
    /// and higher for the value, which is exactly "stepped down by opacity"
    /// applied to a hue §5 permits being decorative with, unlike the three
    /// it does not.
    ///
    /// **Typography from §6, not invented.** The micro-label ("ACCOUNT") is
    /// uppercase, `.16em` tracking at 8.5px — identical to `ThoughtThread`'s
    /// row labels, which is the established bottom-edge idiom rather than a
    /// new one. The value is monospace: §6 says "numerics and identifiers:
    /// monospace with tabular figures, always", and a provider id ("main",
    /// "work") is an identifier by that rule regardless of how short it is.
    /// How wide the account indicator is drawing, so the thread on the same
    /// bottom edge can stop short of it. `0` until measured.
    @State private var accountWidth: CGFloat = 0

    @State private var capacityHovered = false
    @FocusState private var capacityFocused: Bool
    private var capacityCardOpen: Bool { capacityHovered || capacityFocused }

    private func accountIndicator(_ label: String, model: WindowModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("ACCOUNT")
                .font(.system(size: 8.5, weight: .medium))
                .tracking(1.6)                                        // §6: .16–.22em at 8.5px
                .foregroundStyle(Color(red: 0.486, green: 0.361, blue: 1.0).opacity(0.55))  // #7c5cff
            Text(label)
                .font(.system(size: 11, design: .monospaced))         // §6: identifiers, always monospace
                .foregroundStyle(Color(red: 0.486, green: 0.361, blue: 1.0).opacity(0.9))   // #7c5cff
            CapacityHairlines(reading: model.capacity.reading(for: model.providerId), now: Date())
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
        }
        .contentShape(Rectangle())
        .onHover { capacityHovered = $0 }
        .focusable(interactions: .activate)
        .focused($capacityFocused)
        // The cell keyboard focus lands on to open the card: a container,
        // so ACCOUNT, the id and the hairlines stay readable inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.capacity")
        .overlay(alignment: .bottomTrailing) {
            if capacityCardOpen {
                CapacityHoverCard(organisation: model.organization, readings: model.capacity.readings,
                                  inUse: model.providerId, now: Date())
                    .offset(y: -28)
                    .allowsHitTesting(false)          // Rule 6: it takes no focus and moves nothing
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: capacityCardOpen)   // §7: 250 ms fade
        // Reports its own width so the thread can reserve room for it. The
        // label is a provider id of unknown length ("main", "work", or the
        // "unset" placeholder), so this is measured rather than assumed —
        // a hardcoded reserve would be right for one account and wrong for
        // the next.
        .background(GeometryReader { geometry in
            Color.clear.preference(key: AccountWidthKey.self, value: geometry.size.width)
        })
    }

    var body: some View {
        ZStack {
            VoidView(
                // `nil` whenever there is no organisation open (Task 14,
                // spec §8.5) — the honest render of "nothing owns a hue
                // yet" is the bare field, vignette and grain, never a
                // guessed or default colour. See `VoidUniforms.init`'s own
                // doc comment.
                palette: hasOpenOrg
                    ? VoidPalette.forEnvironment(session?.model.environment ?? "",
                                                 production: session?.model.environmentProduction ?? .undeclared) : nil,
                state: session?.model.coreState ?? .idle,
                parallax: CGSize(width: farOffset.x, height: farOffset.y),
                isMaximized: isMaximized,
                threadAnchorX: threadAnchorX,
                hasRows: !(session?.model.thoughts.isEmpty ?? true),
                // `WindowModel.turnInFlight` directly, not re-derived from
                // `coreState == .thinking` — `coreState` is
                // `CoreState.forTurn(inFlight: turnInFlight)`, so re-deriving
                // from it is redundant today and would quietly break once 2d
                // starts setting `.speaking`: a turn can still be in flight
                // while the rendered state is speaking, and the re-derived
                // form would read that as not-in-flight and let the thread's
                // glow decay mid-turn.
                isTurnInFlight: session?.model.turnInFlight ?? false,
                lastRowAt: lastRowAt)
                .ignoresSafeArea()
            if let session {
                if hasOpenOrg {
                    VStack(alignment: .leading) {
                        loaded(session)
                    }
                    .padding()
                    // 2d-ii: the composer bar owns the bottom edge now, so the
                    // old thread-clearance reserve is gone. A pane ends 48pt
                    // above the window's bottom — the bar's height plus its gap.
                    // The status line and notes that used to be this `VStack`'s
                    // last rows moved to the bottom-anchored stack below, above
                    // the bar (rule 8: an error is never clipped).
                    .padding(.bottom, 48)   // 2d-ii: the bar's height plus its gap — a pane ends above it

                    // 2d-ii: ONE bottom-anchored flow, so nothing on the bottom edge
                    // can overprint anything else however tall the bar grows (rule 8:
                    // an error is never clipped). In order, bottom-up: the thread
                    // (§9, rising out of the glow; `threadLift` brightens the bleed
                    // at `threadAnchorX`), the status line / launch notes / no-
                    // provider sentence (the old last rows of `loaded(_:)`, wrapping
                    // and never truncated), then the composer bar with the account
                    // indicator on its row. Panes end 48pt above the window's bottom
                    // (the canvas padding above), a bar's height plus its gap.
                    VStack(alignment: .leading, spacing: 6) {
                        ThoughtThread(
                            rows: session.model.thoughts,
                            parallax: CGSize(width: nearOffset.x, height: nearOffset.y),
                            disclosure: $threadDisclosure)
                            // Measured here, directly on the thread, before the padding
                            // and the expanding `.frame` below — attaching this
                            // `.background` any later would size the reader to
                            // whatever it is attached to at that point, which by the
                            // time `.frame(maxWidth: .infinity, maxHeight: .infinity)`
                            // has run is the whole `ZStack`, not the thread. That
                            // reports the window's own centre on every call — always
                            // ~0.5, indistinguishable from `threadAnchorX`'s default —
                            // and the glow would never move. `.coordinateSpace(.named(
                            // "window"))` is declared on the enclosing `ZStack` below,
                            // an ancestor of this reader, which is what makes
                            // `geometry.frame(in: .named("window"))` resolve at all.
                            .background(GeometryReader { geometry in
                                Color.clear
                                    .onAppear { reportThreadAnchor(geometry) }
                                    .onChange(of: geometry.frame(in: .named("window"))) { _, _ in
                                        reportThreadAnchor(geometry)
                                    }
                            })
                            // It draws over the canvas: its clicks focus no pane under it.
                            .background(ClickShield())
                            // The account indicator sits in the bar's row below, so the
                            // thread needs no trailing reserve. Rows take hits; the empty
                            // space around them does not (no content shape outside rows).
                            .frame(maxWidth: 640, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            if !session.model.status.isEmpty {
                                Text(session.model.status)
                            }
                            // Indexed rather than keyed by the string itself: nothing
                            // guarantees two notes differ, and `id: \.self` would silently draw
                            // only one of a duplicated pair.
                            ForEach(Array(session.notes.enumerated()), id: \.offset) { _, note in
                                Text(note)
                            }
                            // Drawn from the model rather than from `session.notes` so it can
                            // go when it stops being true: `notes` is fixed at launch and this
                            // sentence used to live there, which is how it came to be on screen
                            // beside an account indicator naming the provider it claimed was
                            // unset (`shared-accounts-acceptance.md` D3).
                            if let note = session.model.noActiveProviderNote {
                                Text(note)
                            }
                            if let note = session.model.noProjectRootNote {
                                Text(note)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)

                        HStack(alignment: .bottom, spacing: 20) {
                            ComposerBar(
                                composer: session.composer,
                                onEscapeUnconsumed: { threadDisclosure.escape() })
                            // Task 10: the running account, always on screen — the same
                            // standing Invariant 8 already gives the environment, for the
                            // reason this task exists at all: "work account against a
                            // personal project" is the same class of mistake as "production
                            // database", and the environment badge above already answers
                            // that class of mistake with a permanent treatment rather than
                            // a warning at the point of use. The account gets the same
                            // treatment rather than a confirmation dialog nobody reads.
                            //
                            // **Anchored opposite the thread on the same bottom edge, not
                            // merged with it or with the environment badge.** §9's thread
                            // and §12's future waveform both attach to this edge, so this
                            // reuses that edge rather than inventing a second one — but the
                            // pair that matters is "which account, against which
                            // environment", and a treatment that blended the two into one
                            // label would make that dangerous combination *harder* to read,
                            // not easier. Two distinct elements: the environment badge sits
                            // at the top of `loaded(_:)`, on the far plane, in white-or-red;
                            // this sits at the bottom-trailing corner, sharing the thread's
                            // edge but not its corner or its colour.
                            accountIndicator(session.model.providerLabel, model: session.model)
                                .padding(.bottom, 6)   // the bar's own vertical padding
                        }
                        // The composer grows to six lines, over the panes' bottom edge: its clicks
                        // (and the capacity cell's) focus no pane under it (3b-v PR 8).
                        .background(ClickShield())
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 24)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                    // Background agents 4 of 4: a chip per agent in another place, top right.
                    // Chrome, so here in the window's own layer — above the canvas, not inside the
                    // context line's `VStack` — and declared before the palette and the org plane
                    // so both draw over it. The confirmation and unsaved-changes planes live on the
                    // canvas's own overlay, below this layer, so while one is up the chips go inert
                    // under it as the canvas does behind the org plane: still in view, not
                    // clickable.
                    let planeUp = session.model.showOrgPlane || session.model.paletteShowing
                        || session.model.pending != nil || session.model.unsavedPrompt != nil
                    AgentChips(model: session.model)
                        .opacity(planeUp ? 0.22 : 1)
                        .blur(radius: planeUp ? 0.6 : 0)
                        .allowsHitTesting(!planeUp)
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                // ⌘P / ⌘K: the palette's plane, over everything but the org plane
                // (which closes it — see the `onChange`s below).
                if let palette {
                    PalettePlane(controller: palette)
                }
                // Task 14, spec §8.5: the org plane itself. Forced open —
                // regardless of `showOrgPlane` — whenever no organisation is
                // open: there is nothing else this window can show, and
                // nothing above this point in the `ZStack` drew anything for
                // that case. When an organisation IS open, it is an ordinary
                // toggle the operator opens with ⌘⇧O and (usually) dismisses
                // with Esc.
                if session.model.showOrgPlane || !hasOpenOrg {
                    OrgPlane(model: session.model)
                }
            } else {
                Text("starting…")
            }
        }
        .onPreferenceChange(AccountWidthKey.self) { width in
            accountWidth = width ?? 0
        }
        .coordinateSpace(.named("window"))
        // Larger than 2a's 700×500 because the canvas is now in here and a
        // pane opens 640×420 (`LayoutStore.open`). A window that could not
        // show one whole pane would make every check in the 2b-i runbook a
        // scrolling exercise.
        .frame(minWidth: 1000, minHeight: 860)
        .onContinuousHover { phase in
            if case .active(let location) = phase { cursor = location }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { windowSize = geometry.size }
                .onChange(of: geometry.size) { _, new in windowSize = new }
        })
        // 3a-ii-b (final review I4): every draft that replaced a commit box's text — ✨, the agent or
        // voice — is one ⌘Z away, registered here once for the window.
        .onChange(of: session?.model.changesLastDraft) { _, landed in
            guard let landed, let model = session?.model else { return }
            undoManager?.registerUndo(withTarget: ChangesDraftUndo.shared) { _ in
                model.changesMessageEdited(root: landed.root, text: landed.replaced)
            }
            undoManager?.setActionName("Draft Message")
        }
        .onChange(of: session?.model.organization ?? "") { _, _ in
            settingsSelection = .organisation
            settingsExpansion.reset()
        }
        // ⌘P and ⌘K are menu commands (`AppScene`); they reach here as a token.
        .onChange(of: session?.model.paletteKeyPress) { _, press in
            guard let press else { return }
            if let palette {
                palette.modeKey(press.mode)
            } else {
                openPalette(press.mode)
            }
        }
        // A plane that takes the window closes the palette and keeps the keyboard for its own
        // field: the org plane, a confirmation a palette run raised (spec §7), an org switch.
        .onChange(of: session?.model.showOrgPlane ?? false) { _, shown in
            if shown { palette?.close(restoringFocus: false) }
        }
        .onChange(of: session?.model.pending != nil) { _, pending in
            if pending { palette?.close(restoringFocus: false) }
        }
        .modifier(UnsavedPromptWatch(
            model: session?.model,
            closePalette: { palette?.close(restoringFocus: false) },
            finishQuit: { approved in delegate.finishQuit(approved: approved) }))
        // The window moving under an open palette reaches its list (`refresh`): panes opened or
        // closed, focus, organisation, project, environment. **Except when it leaves no
        // organisation open** — a failed or queued org switch empties `organization`, and the org
        // plane then draws over everything without `showOrgPlane` — or the org plane is up: the
        // palette closes (its monitor would take the plane's Return, Esc and arrows) and the
        // plane keeps the keyboard.
        .onChange(of: paletteWatch) { _, _ in
            guard let palette else { return }
            if !hasOpenOrg || session?.model.showOrgPlane == true {
                palette.close(restoringFocus: false)
            } else {
                palette.refresh()
            }
        }
        .onChange(of: session?.model.thoughts.count ?? 0) { _, new in
            if new > lastRowCount { lastRowAt = Date() }
            lastRowCount = new
        }
        .task {
            guard session == nil else { return }
            // The delegate is handed the startup *task*, and is handed it
            // before anything is awaited — so it knows how to reach the
            // session before `start()` has created a single thing to tear
            // down. `WindowSession.start()` is `@MainActor` and so is this
            // closure, which holds the main actor until it suspends at the
            // `await` below; the assignment happens before that. There is
            // therefore no interleaving in which a child process exists and
            // `delegate.startup` is still `nil`.
            //
            // Reused rather than re-created when one is already there.
            // `.task` re-runs if this view's identity changes, and starting
            // a second `WindowSession` for the same window would be the
            // same leak ⌘N was removed to prevent.
            let startup: Task<WindowSession, Never>
            if let existing = delegate.startup {
                startup = existing
            } else {
                startup = Task { await WindowSession.start() }
                delegate.startup = startup
            }
            let started = await startup.value
            session = started
            await started.model.refreshContext(probe: true)
            // 3b-viii: the quick tasks this organisation routes to, once its context is known.
            await started.model.rebuildQuickTasks()
            await started.model.refreshPanes()
            // `refreshContext` already refreshes the canvas through
            // `activateLayout`, but only once it has an active project to
            // switch to. With no `wakil-ctx` — the documented degraded
            // launch — it returns before that, and the canvas would then
            // draw nothing until the first dispatch. One read costs
            // nothing and makes the view independent of that path.
            await started.model.refreshLayout()
            // Every restored pane re-runs its own query, once, now that the
            // layout is in hand — there is nothing to restore before that.
            // It goes in this same detached startup task, after the first
            // `refreshLayout()`, rather than blocking window construction:
            // `restorePaneContents` walks `layoutSnapshot.panes`, which this
            // call is what populates.
            await started.model.restorePaneContents()
        }
    }

    /// What an open palette's list is read from, as one value to watch.
    private var paletteWatch: String {
        guard let model = session?.model else { return "" }
        let snapshot = model.layoutSnapshot
        return [model.organization, model.project, model.environment, snapshot.focusedId ?? "",
                snapshot.panes.map(\.id).joined(separator: ",")].joined(separator: "\u{0}")
    }

    /// Opens the palette in `mode` — only over an open organisation, and not over the org
    /// plane or a confirmation, each of which owns the window while it is up.
    private func openPalette(_ mode: PaletteMode) {
        guard let model = session?.model, hasOpenOrg, !model.showOrgPlane, model.pending == nil else { return }
        let controller = PaletteController(model: model, mode: mode)
        controller.onClose = { palette = nil }
        palette = controller
    }

    @ViewBuilder
    private func loaded(_ session: WindowSession) -> some View {
        let model = session.model

        // Invariant 5's whole triple, and Invariant 8's standing requirement
        // that the active environment be on screen at all times — now one
        // control instead of a label plus two `TextField`s.
        //
        // **What this replaced, and why.** Until 2026-09-20 this was a
        // `Text` carrying all three values, with `EnvironmentBadge`'s
        // exemption applied to the whole line, and beneath it a bare
        // `TextField("project")` / `TextField("environment")` pair. That
        // pair was the only way to change either, and it could not be
        // anything better: `ctx_set_environment` has taken a free-string
        // `name` since 2a and NOTHING in `app/` could enumerate
        // environments, because the action wrapping `wakil-ctx`'s
        // `list_environments` did not exist. The window could switch to an
        // environment it could not list, so the operator typed a guess and
        // read the refusal in the status line.
        //
        // `ContextLine` is §3's promotion rule spent for the first time —
        // ambient at rest, the control under the pointer — and the badge's
        // exemption moved with it, onto the environment segment alone, where
        // Invariant 8 actually applies. See that file's own comment.
        ContextLine(model: model, parallax: farOffset)
            // **Above every later sibling in this `VStack`.** The context
            // line's menus are drawn as an overlay that deliberately extends
            // past its own bounds, and SwiftUI paints siblings in order — so
            // what came below it composited straight over an open menu,
            // which reads as the menu being transparent and is not.
            // Found on the first operator walk, 2026-09-20.
            .zIndex(1)

        // **The Landing, before this session has done anything.** Gated on
        // `sessionStarted` and NOT on `panes.isEmpty` — the axis is the
        // session, so closing the last pane returns to the room and its
        // thought thread, never here. See that property's doc comment and
        // `LandingStates.dc.html`.
        //
        // It replaces the canvas rather than floating over it: there is no
        // arrangement to see behind it yet, and dimming an empty canvas to
        // put a surface on top would be the org plane's treatment borrowed
        // for a case that does not need it.
        if !model.sessionStarted {
            Landing(model: model)
                .padding(.top, 34)
                .transition(.opacity)
                // **The settings pane draws OVER the Landing**, because
                // the Landing REPLACES the canvas rather than floating
                // above it — and a pane on a canvas nobody is showing is
                // a pane nobody can see.
                //
                // That state is not an edge case here: it is exactly
                // where an operator adding their FIRST account stands. A
                // fresh organisation has no session, so the Landing is
                // up, ⌘, opened the pane, the journal recorded
                // `settings_open -> ok`, and the screen did not change.
                // Found by running the app rather than by any test — no
                // test in this repo draws a window.
                //
                // `overlay` rather than a third branch, so the Landing
                // keeps its own transition and this composes on top of
                // it. It is also what `read_layout` already calls this
                // pane: an overlay (#198).
                .overlay {
                    if let pane = model.layoutSnapshot.panes.first(where: {
                        $0.kind == Pane.settingsKind
                    }) {
                        settingsPaneOverlay(model, pane)
                    }
                }
        } else {
        HStack(alignment: .top) {
            // The canvas reports its own size to `LayoutStore`, which is
            // what every canvas-edge snap is measured against and what
            // `maximize` fills. Without this the void stays at its 1440×900
            // default while the canvas is a fraction of that, and the right
            // and bottom snap edges sit outside the window — reachable by a
            // `--dispatch` script and by nothing a pointer can do.
            GeometryReader { geometry in
                // The mid plane: full scale, opaque, crisp, and **still**.
                // Plane.mid's parallax factor is zero (§6), so there is
                // deliberately no `.offset` here — these two modifiers are
                // both no-ops by value (scale 1.0, opacity 1.0), applied
                // anyway so the rule reads from the code rather than from
                // its absence.
                //
                // The project the canvas is currently drawing. Changing it
                // is what triggers §13's transition — the outgoing
                // arrangement recedes while the incoming one rises, so the
                // ~400ms reconnect happens behind motion rather than behind
                // a frozen window.
                //
                // `.id(model.project)` is what makes SwiftUI treat the two
                // arrangements as different views rather than as one view
                // whose contents changed; without it there is no insertion
                // or removal to transition.
                canvas(model)
                    .scaleEffect(Plane.mid.scale)
                    .opacity(Plane.mid.opacity)
                    .id(model.project)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.04)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))))
                    .animation(.easeOut(duration: 0.5), value: model.project)
                    .task(id: geometry.size) {
                        await model.setCanvasSize(
                            width: geometry.size.width, height: geometry.size.height)
                    }
            }
            // A click anywhere in a pane focuses it (3b-v PR 8). On the reader, not inside
            // `canvas(model)`: that is re-made per project under `.id`, and during §13's
            // transition two canvases — and two watchers — would answer one click.
            .background(PaneClickWatcher { point, landsOnInput in
                canvasMouseDown(model, at: point, landsOnInput: landsOnInput)
            })
            rail(model)
        }
        // Task 14, `OrgPlane.dc.html`: the canvas behind the org plane is
        // visibly inert, not hidden — the operator must still be able to
        // see what they are leaving. Untouched when the plane is closed
        // (`showOrgPlane == false` is both this modifier's identity values).
        // The palette's plane reuses it (`Palette.dc.html`): the canvas you are choosing
        // against stays in view, inert.
        .opacity(model.showOrgPlane || model.paletteShowing ? 0.22 : 1)
        .blur(radius: model.showOrgPlane || model.paletteShowing ? 0.6 : 0)
        .allowsHitTesting(!model.showOrgPlane)
        }

        // The data surface lives in the pane now, not here. Until 2c-i this
        // was a window-level table bound to one flattened columns/rows pair
        // read under a paneId that defaulted to "db" and was never anything
        // else — which is why "every pane is dual-driven" was unreachable in
        // that shape. See Canvas.paneView.
    }
}

/// Carries the account indicator's width to the thread that must not draw
/// under it.
///
/// **Optional, with `reduce` keeping the last real value** — the same shape
/// `DataSurface.HorizontalOffsetKey` was fixed into, and for the same
/// reason: with a non-optional default, every view in the subtree that does
/// not set the key still contributes it, and a `reduce` taking `nextValue()`
/// unconditionally lets one of those defaults overwrite the single
/// measurement that meant anything.
private struct AccountWidthKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

extension WakilWindow {
    /// The settings pane over the Landing, in the same clothes it wears
    /// on the canvas.
    ///
    /// It calls `paneView` — the canvas's own pane renderer — rather than
    /// re-dressing the content here, so the §2 slab, the luminous edge
    /// and the tracked title bar have exactly one definition. What this
    /// adds is only what the canvas would otherwise have supplied: a
    /// frame, and room around it.
    ///
    /// No drag or resize gesture is attached, and that is deliberate: the
    /// Landing has no canvas coordinate space to drag within, and the
    /// pane is never persisted anyway (`layoutWithoutOverlayPanes`).
    @ViewBuilder
    func settingsPaneOverlay(_ model: WindowModel, _ pane: Pane) -> some View {
        // **The height is given, not asked for.** On the canvas a pane is
        // always framed to `pane.width`/`pane.height` before `paneView`
        // ever runs, so its content fits by construction. Here there is no
        // such frame, and `maxHeight: .infinity` does not supply one — it
        // offers space without clamping intrinsic size, so a subject taller
        // than the window (the account table, which is the longest there
        // is) grows past the Landing at both ends: over the Open/Actions
        // row above and into the message field below.
        //
        // A `GeometryReader` inside an `overlay` reads the OVERLAID view's
        // frame — the Landing's, exactly — so this is the available space
        // and nothing needs to guess at it. The interior then scrolls,
        // which is what the subject column is already built to do.
        GeometryReader { geometry in
            let size = CGSize(width: max(geometry.size.width - 48, 0), height: max(geometry.size.height - 22, 0))
            paneView(model, pane)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                // A click on it focuses it, as on the canvas (3b-v PR 8): its watcher is the
                // only one on screen, since the Landing replaces the canvas.
                .background(PaneClickWatcher { point, landsOnInput in
                    canvasMouseDown(model, at: point, landsOnInput: landsOnInput, overLanding: size)
                })
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 8)
        }
    }
}

/// 3b-i Task 9, the window's half of the unsaved prompt. A modifier of its own because the
/// window's chain is already as long as the type checker will take.
private struct UnsavedPromptWatch: ViewModifier {
    let model: WindowModel?
    let closePalette: () -> Void
    let finishQuit: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            // The prompt takes the keyboard, as a confirmation does, and one the canvas draws (a
            // pane, an org switch, a quit) must not sit under the org plane.
            .onChange(of: model?.unsavedPrompt) { _, prompt in
                guard let prompt, let model else { return }
                closePalette()
                if case .closeTab = prompt.intent { return }
                model.showOrgPlane = false
            }
            // A quit the prompt was holding (`applicationShouldTerminate` answered
            // `.terminateLater`): Save or Don't Save quits, Cancel stays.
            .onChange(of: model?.quitApproved ?? 0) { _, _ in finishQuit(true) }
            .onChange(of: model?.quitCancelled ?? 0) { _, _ in finishQuit(false) }
    }
}
