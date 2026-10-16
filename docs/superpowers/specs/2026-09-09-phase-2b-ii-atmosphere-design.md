# Wakil Phase 2b-ii — Atmosphere

**Status:** draft for review · **Created:** 2026-09-09 · Conforms to
`docs/wakil/north-star.md` and `docs/wakil/design-language.md`

2b-i built the structure — panes that coexist, snap, and are reachable three ways — and
shipped it deliberately ugly. This spec is where the design language is applied to it:
the void, the Core, the three planes, motion, the thought thread, and the treatment that
makes production look like production.

## 0. Where 2b-ii sits

| | Delivers | Exit |
|---|---|---|
| ~~2a~~ | Harness, action registry, agent bridge, write gate, context switcher, one crude pane | **Met 2026-09-08** |
| ~~*probe*~~ | Metal feasibility and frame cost | **Done** — `docs/wakil/phase-2b-probe.md` |
| ~~2b-i~~ | Third action kind, pane model, magnetic canvas, the rail, ⌘P/⌘K | **Met 2026-09-08** — `docs/wakil/phase-2b-i-acceptance.md` |
| **2b-ii (this spec)** | The void, planes, the Core, motion, the thought thread, production treatment | `design-language.md` §1–9 realised at budget |
| 2b-iii | The write-gate UI and first `.mutate`, session resume, the provider picker, signing | 2a's acceptance checks 5 and 6 finally run |
| 2c | DB pane in full (§8's substance), API client pane, terminal pane, session browser | Each fully dual-driven |
| 2d | Push-to-talk, pluggable STT, live transcription | The charter's Phase 2 exit criterion |

**Three things are already settled and this spec does not re-open them.** The probe
(`phase-2b-probe.md`) fixed the build route — `xcrun metal` prebuild into
`default.metallib`, 0.6 ms to load against 168 ms for runtime compilation — priced the
Core at 1.090 ms p50 of the 8.33 ms frame budget, and established that 120 fps cannot be
observed on this machine at all. §2.4 below inherits the first, §10 the second, and §11
the third.

**One thing the probe found is a task here, not a footnote.** Its capture showed three
defects in the Core: a seam where the conic gradient wraps at ±π, a specular too large
and too hot to read as anything but pearl, and rim occlusion too weak for the sphere to
feel like a volume. All three are shader craft and §5 owns them.

---

## 1. Scope

**In:** the void and its two bleeds and grain; the environment-governed production
treatment; the Core as a second Metal layer with all four states rendered and two driven;
the three planes with parallax; the thought thread as §9 describes it, minus one clause;
panes as §8 slabs with a density toggle; §7's motion including the project-switch
transition; a window with no title bar.

**Out, and each has an owner:** voice and the two Core states it drives (2d) · §8's
substance — status chips, explicit `null`, column type annotations, hover row actions,
the footer, virtualization (2c) · new pane kinds (2c) · the write-gate UI, session
resume, the provider picker, signing (2b-iii).

**One deliberate non-decision.** `design-language.md` §15 leaves the display face for
micro-labels unresolved. 2b-ii ships system sans throughout with §6's tracking and
sizing, and leaves the question open: a typeface is a choice to make against a full
window of real content, which does not exist until 2c.

### Why §8 is split rather than deferred whole

§8 sits inside "§1–9 realised", but it describes the database pane, which 2c owns in
full. The line falls between treatment and substance: **2b-ii does how a data surface
looks, 2c does what it contains.**

The reason is §1's fourth principle — *chrome may be atmospheric, data must be ruthlessly
legible* — which is a statement about two registers being on screen at once. It is not
testable with only one of them built. Styling the void without settling how a data
surface sits inside it is the same mistake in a third form: Decision 9 records that
dual-drive cannot be retrofitted, 2b-i's ordering records that a pane built before its
architecture gets rebuilt, and a slab designed after the room it sits in is finished
would join them.

What stays in 2c is everything that needs a second data source to prove itself. Status
chips, `null` rendering and column type annotations designed against one query's result
are designed against one query's result.

---

## 2. The layer stack

Three layers, back to front:

    CoreView    (Metal)   the Core, and the thought thread rising from it
    canvas      (SwiftUI) panes, the rail, the palettes, the context line
    VoidView    (Metal)   the void: bleeds, grain, vignette

### 2.1 Why two Metal layers and not one

The probe drew the void and the Core in a single fragment shader, and the obvious
inheritance is a single full-window `MTKView` behind everything. It is wrong for a
reason that is structural rather than aesthetic: **§3 puts the Core on the near plane,
in front of the panes, and puts the void behind them.** SwiftUI views cannot be
sandwiched inside one `MTKView`, so one layer means the Core is occluded by whatever
pane the user drags over it — and §10's *"maximize fills the void; the rail and Core
fade back"* becomes meaningless, because the Core was never in front to begin with.

Two layers cost one extra drawable and one extra shader file. The alternative costs the
depth model.

### 2.2 The two layers want different cadences, and that is the frame-rate answer

`north-star.md` §8 records the operator's question — *"can we cap it at 120 fps and not
more, if this would save resources"* — and records that 2b-i had nothing running at
frame rate to cap. 2b-ii does, and the honest answer is the one that document
anticipated: the cap is not where the saving is.

| Layer | Policy | Idle cost |
|---|---|---|
| `VoidView` | `isPaused = true`, `enableSetNeedsDisplay = true` | **zero frames** |
| `CoreView` | continuous, `preferredFramesPerSecond = 120` | 1.090 ms of GPU per frame (probe §3) |

The void is static. It redraws when something actually changes it: the environment
(§3.2), the window's size, the parallax offset (§6), or a project-switch transition
(§8.1). A still window with the cursor at rest draws no void frames at all, which is a
larger saving than any rate cap on a layer that would otherwise redraw an unchanged
image sixty times a second.

**2026-09-09 correction (final review Finding 4).** "Zero frames" above is only true once
`VoidView.updateNSView` compares what it is about to draw against what the coordinator
already holds and marks `needsDisplay` only on an actual change to `palette` or
`parallax`. Before this fix it marked `needsDisplay` unconditionally on every call, and
`updateNSView` fires on every `WakilWindow` body re-evaluation — which includes a
`.result` event landing, a `status` change, or a `layoutSnapshot` refresh, none of which
touch what the void draws, because the body reads `session?.model`, an `@Observable`. So
the "still window" the table's "zero frames" row described was narrower than it read: a
window with an unchanging *model* as well as an unchanging cursor. A window that is
visually still but whose session is mid-turn — which is most of the time one is running —
was redrawing an unchanged image on every one of those, not zero frames. The comparison
this fix added is what makes the claim true of an idle window regardless of what the
model underneath it is doing.

The cap is set on the Core anyway, as `north-star.md` asks — a statement of intent and a
guard on future hardware — while noting that both displays here are 60 Hz, so it clamps
nothing today.

**2026-09-09 addition (final review Finding 3).** The cap bounds the Core's *rate*, not
whether it renders at all — and nothing in this section, when first written, asked
whether it should render when nobody can see it. `CoreView.Coordinator` now observes
`NSWindow.occlusionState` (via `didChangeOcclusionStateNotification`, the signal that
covers minimised, fully-covered-by-another-window, and other-space in one flag rather than
three separate checks) and sets the `MTKView`'s `isPaused` from it: paused whenever the
window is not visible, running whenever it is. **Deliberately not gated on app-active
state as well.** The Core is a presence indicator, not a decoration — it is answering "is
the agent here, and in what state" — and a window that is fully visible but merely not
focused (an editor in front, Wakil visible beside it) is exactly the case where freezing
the sphere would misrepresent a live session as a stopped one. Visibility is the bar this
phase chose; focus is not.

### 2.3 Drawing lives in `WakilApp`, decisions live in `WakilKit`

`phase-2b-i-acceptance.md` §6 records a gap it could not close: `Pane.busy`'s publishing
order is untested "because the window is not reachable from a test target". A visual
phase written carelessly inherits that gap for everything it builds.

So every question with a right answer is a pure value in `WakilKit`, and `WakilApp` only
draws it:

| Type | Answers | Tested |
|---|---|---|
| `CoreState` | which of four states, from whether a turn is in flight | unit |
| `VoidPalette` | environment → the void's colours | unit |
| `Plane` | the three planes' scale/opacity/blur, and cursor → parallax offset | unit |
| `thoughtRow(id:for:)` | which harness events become rows, and which do not | unit |

None of these needs a window, a display, or a GPU. What is left for the runbook is
whether it *looks* right, which no test was ever going to answer.

### 2.4 The build gains a shader step

Two `.metal` files compile into one `default.metallib`, per the probe's finding that
SwiftPM does not compile `.metal` at all — declaring one as a resource copies the source
into the bundle and produces no library:

```make
shaders:
	xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal app/Shaders/Core.metal

app-build: shaders
	cd app && swift build
```

`default.metallib` is generated, gitignored, and declared `.copy("default.metallib")` on
the `WakilApp` target so `makeDefaultLibrary(bundle:)` finds it by name.

Two consequences to accept openly. `make app-build` acquires a hard dependency on the
separately-downloaded Metal Toolchain, which is why `operator-todo.md` records that
download as a step distinct from installing Xcode. And a bare `swift build` in `app/`
now fails on a clean tree until `make shaders` has run once — the Makefile is the
supported entry point, and `app-build` depends on `shaders` so the supported path never
hits it.

**The runtime fallback is not built, but is recorded.** `makeLibrary(source:)` from a
bundled `.metal` needs no build-time toolchain and costs 168 ms per launch. It is the
only route that survives a machine without the toolchain. It is written down here rather
than implemented, because implementing it would mean maintaining two shader-loading
paths of which one is never exercised.

---

## 3. The void

### 3.1 What it draws

`design-language.md` §2, unchanged: a near-black field (`#030408`–`#070812`), a violet
radial bleed from below, a cool blue one from the upper right, and a fine grain overlay
at ~14%. The grain is not decoration — it exists to stop the two gradients banding, and
a void without it bands visibly on a dark panel.

The probe drew all of this and measured it inside the 1.090 ms that also contained the
Core, so the void's own cost is a fraction of that and is not discussed further.

### 3.2 The environment governs it — the production treatment

`phase-2b-i-acceptance.md` §6 lists *"production looks alarming is still unmet — plain
text, no treatment"* as a known gap, and assigns it here.

**The treatment is the badge plus the room, and nothing else.** The environment label
turns red, and the void's bleeds turn red in place of violet. Panes do not change. The
Core does not change.

| Environment | Void bleeds | Label |
|---|---|---|
| local, staging, anything else | violet from below, cool blue upper right | cool white |
| **production** | red | **red** |

Two rules from the design language settle this shape against the louder alternatives.
§1's *one bright object* means the Core is the only luminous thing on screen; a
production treatment that lights every pane edge puts a dozen bright objects beside it
and the Core stops reading as special. And §5's *reserved semantics, never decorative*
cuts the other way too — if red is everywhere, red is wallpaper, and the one moment it
needs to stop you (2b-iii's write gate, on production) it will not.

A badge alone was the other candidate and is too quiet to be called alarming. Changing
the colour of the room is the smallest change that is impossible not to notice, and it
degrades honestly: it is one uniform in a shader that is already drawing.

`VoidPalette` is a pure function of the environment string, so this is unit-testable
without a GPU, and 2b-iii inherits a palette rather than inventing one for its gate.

---

## 4. The Core

### 4.1 Four states rendered, two driven

The shader takes the state as a uniform and renders all four of §4's states. The app
only ever sets two of them:

| State | Set when | In 2b-ii |
|---|---|---|
| **Idle** | no turn in flight | **driven** |
| **Thinking** | a turn is in flight | **driven** |
| Listening | ⌥ held, audio capturing | rendered, never set — 2d |
| Speaking | Wakil speaking | rendered, never set — 2d |

*Turn in flight* has an exact meaning in existing code: true from a successful
`WindowModel.send`, false on the `.result` harness event. That is one stored `Bool` and a
derived `CoreState`, both testable without a window.

**Why render four when two are reachable.** The probe already captured all four
offscreen, so the marginal cost is near zero, and the alternative is writing the same
four-state shader twice — once now and once in 2d. Driving listening and speaking from
proxies available today (assistant text arriving is not speech; a focused prompt field is
not listening) would invent semantics 2d then has to unpick.

**No registry action sets the state, and none is added.** An earlier draft proposed a
`core_set_state` `.control` action so the acceptance runbook could reach all four. It is
unnecessary: the probe captured four states offscreen with no app involved at all, and
§11's capture tool does the same. Adding a debug-shaped action would put it one fuzzy
match away in ⌘K for no gain.

### 4.2 The three defects the probe found

- **The conic seam.** `atan2` wraps at ±π and the four-stop palette does not close
  across the wrap, leaving a hard radial line. The fix is a palette that closes — the
  first stop repeated at the end, interpolated in a space that does not shortcut through
  grey.
- **The specular.** Placement at 34%/26% is right; radius and intensity are not, and the
  sphere reads pearl rather than §4's *iridescent volumetric*.
- **Rim occlusion.** Too weak for the sphere to read as a volume rather than a disc.

These are the visible difference between "the Core is renderable" and "the Core is the
one bright object", and they are the part of this phase least amenable to a test. §11
captures them for eyeball review and says so.

### 4.3 The ornament rule holds

§4 permits exactly one ornament — the thin rotating tick rings, and only because they
are reactive. They tighten and accelerate on listening, which 2b-ii renders and never
triggers. Nothing else is added: no reticles, brackets, scan lines or grid overlays.

---

## 5. Panes as slabs — §8 as treatment

Per §1 above, 2b-ii does the look and 2c does the contents.

**In:** the pane as a §2 slab — rounded, near-opaque, defined by drop shadow and a
half-pixel luminous edge, never an outline. §6's typography: uppercase micro-labels at
8–9.5 px and .16–.22em tracking, neutral system sans for body, monospace with tabular
figures for every numeric and identifier. Row separation by whitespace, not rules. The
active row's left edge as the only luminous element permitted inside a data surface.

**And the rule that governs all of it:** §1's second register. Never translucent, never
glowing, never low-contrast behind a data surface. The atmosphere stops at the slab's
edge.

> **Amendment, dated 2026-09-09 (Task 14, closing the phase).** The active row's left
> edge, named above as shipping this phase, **did not ship**. Task 9's implementation
> found no selection model anywhere in the codebase — nothing tracks which row is
> "active" — and building one to support a single visual flourish would have been
> inventing a data-surface feature that belongs to 2c with the rest of the grid's
> substance, not to 2b-ii's atmosphere pass (`progress.md`, Task 9). The bullet above is
> left as the design intent this phase was written against, not as a record of what was
> delivered; the deferral is tracked as an open discrepancy in
> `docs/wakil/phase-2b-ii-acceptance.md` ("A discrepancy the spec does not admit to,
> carried from Task 9") and 2c now names it as inherited work in `north-star.md` §8.

### 5.1 Density is an action, not a preference

§8's density toggle — airy 40 px default, dense 23 px, remembered per pane — is a
`pane_set_density` `.control` action in the registry, dispatched by ⌘⇧D and persisted
with the pane in `LayoutStore`.

Invariant 2 does not stop at layout. A toggle wired directly to a `@State` would be the
first thing in the window that the agent cannot do and the journal cannot see, and
2b-i's whole §4 exists to prevent exactly that.

> **Amendment, dated 2026-09-09 (Task 14).** This section did not anticipate what the
> toggle would end up dispatched *against*. 2b-i built the pane's data grid on SwiftUI's
> `Table`, and this spec assumed it as the surface density would apply to. Task 10
> measured, headlessly and not from documentation, that `Table` on macOS is backed by an
> `NSTableView` with `usesAutomaticRowHeights = true`, which floors drawn row height at
> the 24 px platform default — content can grow a row taller, but nothing shrinks it
> below 24 px. The 23 px dense row two sentences above promises is therefore physically
> unreachable inside `Table`. `Table` was replaced with a hand-built `Grid` in a
> two-axis `ScrollView`, which has no `NSTableView` underneath and honours
> `.frame(height:)` exactly. This is the single most consequential thing 2b-ii did that
> this spec did not call for: the replacement forecloses column resizing,
> header-driven sorting, and built-in laziness/virtualization for large result sets —
> none of which 2b-i had wired up either, so these are options closed off rather than
> regressions, but 2c inherits a hand-built grid rather than a platform `Table` and
> should plan accordingly. Full measurement and consequences:
> `docs/wakil/phase-2b-ii-acceptance.md`, check 13, and `progress.md`, Task 10.

---

## 6. Planes and parallax

§3's three planes, expressed through scale, opacity and blur together — never one alone:

| Plane | Treatment | Holds, in 2b-ii |
|---|---|---|
| **Far** | `scale(.94)`, `opacity .30`, `blur(1.4px)` | the rail, the context line |
| **Mid** | full scale, opaque, full contrast, crisp | panes |
| **Near** | full scale, brightest | the Core, the thought thread |

**Parallax moves the void and the far plane. It never moves a pane.**

§3 says the planes parallax against cursor and window motion, and the temptation is to
include the mid plane because that is where the visible content is. It is exactly the
wrong place: moving a data surface under the cursor while it is being read fights §1's
legibility register and makes table text shimmer against the pixel grid. Far-plane
content is already blurred and dimmed — it can move freely because nothing there is being
read.

Parallax is a pure function of cursor position within the window, and `Plane` owns it, so
the offsets are unit-testable and the magnitude is one constant to tune rather than a
number embedded in a view.

---

## 7. The thought thread

### 7.1 What it shows

§9's treatment: rising out of the Core, completed steps faded to dim green, the live step
pulsing. It replaces spinners and progress bars entirely.

**What produces a row changes.** Today `thoughtRow(id:for:)` is total over `HarnessEvent`
and every case yields a row — deliberately, because 2a's §7 asked for "a plain list of
harness events with their status". The probe found that 10 of `basic-turn.jsonl`'s 13
lines decode to `.unknown` (`stream_event`, `rate_limit_event`, `session_state_changed`),
so a real turn is mostly noise. A plain list can carry that. A thread rising out of the
Core holds perhaps six lines before the live step is pushed off the end, and burying four
meaningful lines under eleven meaningless ones defeats the only claim §9 makes — that
watching a plan execute is the honest UI for tool-chaining.

So `thoughtRow` returns `ThoughtRow?`, and `.unknown` returns `nil`. The rows that remain
are the ones that describe work: assistant text, tool calls, tool results, turn end.

### 7.2 §9 loses one clause

§9 currently reads *"upcoming steps sit near-invisible"*. **This cannot be drawn
honestly and the design language changes rather than the code.**

Harness events arrive one at a time and nothing in the stream announces what the agent
intends to do next. Upcoming steps could only be invented, and an invented step is worse
than an absent one: it is a promise the interface has no standing to make, and it would
be wrong every time the agent changed its mind mid-turn.

The alternative — asking the agent for a plan before it acts — is a new agreement with
the agent about announcing steps, is a protocol rather than a rendering, and is not what
this phase is. It is recorded as an open question (§14) rather than closed.

`design-language.md` §9 gets a dated amendment saying this.

---

## 8. Motion

§7's durations, unchanged: Core breath 5.4 s idle and 1.5 s listening, Core bob 6.5 s,
plane transitions 400–600 ms ease-out, a value materialising as a 250 ms fade with a 4 px
rise. Weightless, slow, eased; nothing appears instantly and nothing bounces.

### 8.1 The project-switch transition

§13 asks for a project or org switch under ~400 ms to interactive, *with the latency
covered by motion* — the outgoing panes recede while the incoming ones rise, about
500 ms, hiding the reconnect underneath.

2b-i measured the swap alone and `phase-2b-i-acceptance.md` §5 records that the 400 ms
figure was never measured at all. 2b-ii builds the motion and takes the measurement.

**Why now rather than in 2c**, where there would be more to look at: the transition is
pure motion, which is this phase's remit, and the ordering matters. If 2c builds four
pane kinds against a switch that flickers, all four get reworked when the transition
lands. Building it now sets a budget while switching is still cheap, and 2c inherits a
line to stay under.

State is not torn down. `LayoutStore` already keeps every visited project's panes in
memory (2b-i §3.3), so the transition animates a swap, never a rebuild.

### 8.2 Maximize learns what §10 asked for

§10: *"Maximize (⌘⏎) fills the void with the focused pane; the rail and Core fade
back."* 2b-i's maximize fills the canvas and nothing fades, because there was nothing to
fade. Both now exist, so both fade — on the same 400–600 ms plane transition, since that
is what this is.

---

## 9. The window loses its title bar

§1's first principle is *futurism through absence* — no window chrome. Today Wakil is a
standard macOS window and the void would be a rectangle inside a title bar, which is the
principle stated and not delivered.

The title bar hides (`titlebarAppearsTransparent`, `titleVisibility = .hidden`,
`.fullSizeContentView`) and the traffic lights stay. The void then reaches all four
edges, which is the actual claim §2 makes.

Fully borderless was the alternative and is rejected: it buys purity and costs the
ability to close the window, plus every macOS behaviour built on a standard window —
Mission Control, tiling, window restoration — which would have to be rebuilt by hand for
an aesthetic gain of three small circles.

---

## 10. Performance

The probe settled the only number that was in doubt. Restating the budget rather than
re-deriving it:

| | Cost | Budget |
|---|---|---|
| Core, per frame (probe §3, p50) | 1.090 ms | 8.33 ms |
| Void, idle | zero frames | — |
| `default.metallib` load at launch | 0.6 ms | — |

The frame budget in 2b is therefore not spent on Metal. Where it can still be lost is
SwiftUI layout and, later, the data grid — which is why §13 of the design language
already says to prefer AppKit for the grid specifically, and why that decision belongs to
2c and not here.

2b-i's own budget rule carries forward unchanged: **no `await` on the pointer-moved
path.** Parallax is computed from cursor position on the main actor into local state, the
same shape as 2b-i's drag offsets, and dispatches nothing.

---

## 11. Verification

**Headless, in `WakilKitTests`:**

- `CoreState`: idle before a turn, thinking from a successful `send`, idle again on
  `.result`, and idle on a `send` that failed — a turn that never started is not a turn
  in flight.
- `VoidPalette`: production yields the red bleeds, every other environment the violet
  ones, and an empty or unknown environment string does **not** yield production. A
  treatment that fails open into "looks safe" is the correct failure direction here, and
  the test pins it.
- `Plane`: the three planes' constants; parallax offset at the window's centre is zero,
  at each corner is bounded by the configured maximum, and is continuous across the
  window.
- `thoughtRow`: each meaningful case yields a row; `.unknown` yields `nil`; the existing
  tests are updated to the optional return rather than deleted.
- `pane_set_density` dispatches, journals with the right origin, appears in `all()`,
  round-trips through persistence, and is per-pane.

**The capture tool, and what it is not.** A small offscreen renderer — the probe's, kept
— writes a PNG per Core state and per environment into `.context/`. **It is not a
pixel-diff gate.** A golden-image test over a shader containing grain, a conic gradient
and a time-varying breath is a test that fails on a toolchain update and gets disabled
within a week, and a disabled test is worse than an honest runbook line. The captures
exist to be looked at, and the acceptance document records what was seen.

**Frame cost**, from the probe's timing harness, re-run against the two-layer stack:
p50/p95/max GPU per frame with the Core drawing, and the void's frame count while idle —
which should be zero and is the direct test of §2.2.

**Project switch**, timed from dispatch to interactive and recorded as a number.

**Operator runbook, because no machine can check them:** that the void reads as depth
rather than as a gradient; that the Core reads as a volume and no longer as pearl; that
the seam is gone; that production is alarming without being exhausting; that parallax
adds depth without inducing motion sickness; that the thought thread is readable during a
real turn; and that dense mode is genuinely scannable.

### What 2b-ii cannot verify, and why

**120 fps.** Both displays on this machine are 60 Hz (probe §4). No document produced by
this phase may claim the target was observed. Frame cost against the 8.33 ms budget is
the honest proxy and is what this section records.

**Listening and speaking as *states of the application*.** The shader renders them and
the capture tool photographs them; nothing sets them, because nothing can until 2d. A
PASS on the captures means the renderer is right, not that the states work.

**2a's acceptance checks 5 and 6, still.** They need a `.mutate` action and 2b-ii
registers none — `pane_set_density` is `.control`, because changing a row height changes
Wakil and nothing else. They remain 2b-iii's, and the scripts are already written down in
`phase-2a-acceptance.md`.

---

## 12. What 2b-ii does not change

**One window.** ⌘N stays absent, and the reason is now literal rather than anticipated:
§1's *one bright object* is violated by a second Core before anything technical goes
wrong.

**The harness, the shim, the MCP transport, `PaneStore`, `read_pane`, the snap graph and
solver, persistence.** Untouched. This phase adds a look, and the one behavioural change
it makes to existing code — `thoughtRow` returning an optional — is covered by §11.

**The write gate.** Unchanged, including the row 2b-i added for an agent re-pointing the
active context at production. 2b-ii makes production *look* different; what it *permits*
is 2b-iii's.

---

## 13. File structure

New, in `WakilKit`:

    Visual/CoreState.swift       four states; the turn-in-flight derivation
    Visual/VoidPalette.swift     environment → the void's colours (§3.2)
    Visual/Plane.swift           plane constants; cursor → parallax offset (§6)

New, outside any target — SwiftPM would report a `.metal` file inside `Sources` as an
unhandled resource, and the shaders are a build input rather than a Swift one:

    app/Shaders/Void.metal       the void, split from the probe's shader
    app/Shaders/Core.metal       the Core, with §4.2's three fixes

New, in `WakilApp`:

    VoidView.swift               paused MTKView; redraws on change only
    CoreView.swift               continuous MTKView; 120fps cap
    ThoughtThread.swift          §7's rendering, on the near plane

Changed, in `WakilKit`:

    App/WindowModel.swift        turn-in-flight; thoughtRow's optional return
    Layout/Pane.swift            density, persisted
    Layout/LayoutActions.swift   pane_set_density

Changed, in `WakilApp`:

    main.swift                   the window's chrome (§9)

### The split `WakilWindow.swift` needs first

`WakilWindow.swift` is 883 lines and this phase would push it past 1200. It is split
along its own existing `// MARK` boundaries, before any new drawing is added:

    WindowSession.swift          the session (currently lines 31–193)
    AppScene.swift               the scene and app delegate (193–327)
    WakilWindow.swift            the shell: the three-layer ZStack
    Canvas.swift                 the pane canvas and its gestures (566–803)
    Rail.swift                   the rail (803–832)
    Palettes.swift               ⌘P and ⌘K (832–883)

This is not a refactor for its own sake and nothing moves between types — the boundaries
already exist as comments, and the new layers land in the shell file, which has to be
readable before they do.

---

## 14. Risks

**The look is the deliverable and the look has no test.** Every other phase could be
judged by a passing suite; this one is judged by whether a room feels right. The
mitigation is honesty about which parts are which: §11 splits what a machine checks from
what the operator checks, and does not pretend a golden image would have covered the
difference.

**Parallax is the most likely thing to be wrong.** The magnitude that reads as depth and
the magnitude that reads as instability are close together, and the operator is the only
instrument. It is one constant in `Plane`, deliberately, so tuning it is not a code
change.

**The production treatment can be tuned into invisibility, or into noise.** Both failure
modes are one constant apart. The runbook asks the question directly rather than leaving
it to be noticed later.

**The Metal toolchain becomes a hard build dependency.** A machine with Xcode but without
the separately-downloaded component fails at `make shaders` with an error that names the
fix (probe §1), and `operator-todo.md` records both steps. The runtime-compilation
fallback stays documented and unbuilt (§2.4).

**`thoughtRow` returning `nil` hides events during debugging.** The rows dropped are the
ones the probe found to be most of a turn, and a stalled session now looks like an empty
thread rather than a scrolling one.

**2026-09-09 correction (final review Finding 1).** The mitigation this paragraph
originally claimed — "the events still arrive and the harness still logs them" — was
false: as of that review, `grep -rE 'print|FileHandle.standardError|NSLog|os_log|Logger|
journal' app/Sources/WakilKit/Harness/` found zero hits, and `WindowModel.append` simply
discarded every event `thoughtRow` mapped to `nil` with no artefact left anywhere. A
session stalled mid-turn — between a `tool_use` and its `tool_result` — looked like a
frozen, empty thread with nothing to inspect. The actual mitigation as of this fix: events
still *arrive* (the harness's `AsyncStream` carries every one of them, dropped or not, to
`WindowModel.append`), but nothing logged them until this fix added exactly one route —
`WindowModel.append` now writes every event, unknowns included, to stderr as one line each
when `WAKIL_DEBUG_EVENTS` is set in the process environment, gated so it costs nothing
(not even the check beyond one dictionary lookup) when unset. That is a debug route the
operator must opt into, not an always-on transcript or journal — an operator who has not
set the variable is in exactly the position this paragraph used to wrongly claim they
were not.

---

## 15. Open questions

1. **Should the agent announce its plan?** §7.2 drops "upcoming steps" because nothing in
   the stream carries intent. If the harness ever surfaces one — Claude Code's own todo
   mechanism is the obvious candidate — the clause could return honestly. Not this phase,
   and not a rendering question.
2. **The display face for micro-labels**, carried over from `design-language.md` §15,
   still unresolved and now deliberately so: it wants a full window of real content to
   judge against, which arrives in 2c.
3. **Whether the void should respond to window motion as well as the cursor.** §3 says
   both. 2b-ii implements the cursor only, because window motion on macOS is a drag the
   app does not own and sampling it cheaply is its own question.
4. **A light-environment variant**, from §15. Untouched, and no work here forecloses it —
   `VoidPalette` is the seam it would arrive through.
