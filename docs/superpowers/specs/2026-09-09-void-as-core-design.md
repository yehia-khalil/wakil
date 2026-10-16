# Wakil Phase 2b-iv — The void as the Core

**Status:** draft for review · **Created:** 2026-09-09 · Conforms to
`docs/wakil/north-star.md` and `docs/wakil/design-language.md`

2b-ii shipped `design-language.md` §4's Core as an iridescent sphere. Its first hands-on
run put that sphere on top of an open pane, and the fix — bottom-centre, small — prompted
the operator's better question: *why not make the void be the Core?* That question was
probed the same day (`docs/wakil/void-as-core-probe.md`, twelve renders) and the operator
chose variant B. This spec is variant B.

**The sphere is deleted.** The room carries Wakil's presence, and there is no bright
object in front of the panes at all.

## 0. Where 2b-iv sits

| | Delivers | Exit |
|---|---|---|
| ~~2b-i~~ | Pane model, magnetic canvas, the rail, ⌘P/⌘K | **Met 2026-09-08** |
| ~~2b-ii~~ | The void, planes, the Core, motion, the thought thread | Implemented 2026-09-09; **acceptance outstanding** |
| ~~*probe*~~ | Is the void a better Core than a sphere? | **Answered 2026-09-09** — `docs/wakil/void-as-core-probe.md` |
| 2b-iii | Write-gate UI and first `.mutate`, session resume, provider picker, signing | 2a's acceptance checks 5 and 6 finally run |
| **2b-iv (this spec)** | The void as the Core; the sphere deleted; one Metal layer | §4 realised without an object, at lower idle cost than 2b-ii |
| 2c | DB pane in full, API client pane, terminal pane, session browser | Each fully dual-driven |
| 2d | Push-to-talk, pluggable STT, live transcription | The charter's Phase 2 exit criterion |

**2b-ii's acceptance runbook is walked in full first, before this sub-phase starts.**
Decided by the operator on 2026-09-09. Most of its thirteen checks — the void as depth,
the planes, parallax, the thought thread, the project switch, the production treatment —
survive 2b-iv untouched, and walking them validates the layers this sub-phase keeps. The
Core-specific checks are walked knowing the object is on death row: what they are worth
is a recorded human judgement of variant A, which is the only baseline anyone will ever
have to compare B against.

**Two things are settled by the probe and this spec does not re-open them.** The choice
of B over C (a summoned sphere for listening and speaking) was the operator's, against the
reviewer's preference, and is final. And the idle state **breathes** rather than sitting
still — also the operator's, and it is what makes the frame-rate question in §5 exist at
all.

---

## 1. Scope

**In:** `CoreMotion`, the parameter table that turns `CoreState` into numbers; `Void.metal`
rewritten to take those numbers and animate; the collapse from two Metal layers to one;
state-derived frame rates; the occlusion pause carried over; §9's thought thread
re-anchored to the bottom edge and coupled to the bleed; the capture harness reworked and
extended to emit motion; the deletion of `CoreView`, `Core.metal` and `CoreState
.shaderIndex`; the amendments to `design-language.md` §§1, 2, 3, 4, 7, 9, 12, 13, 15 and
to `north-star.md` §7 and §8.

**Out, and each has an owner:** §12's listening waveform and live transcription — this
spec writes the sentence that says where they attach and builds no waveform (2d) · the
two Core states voice drives, which are rendered here and never entered (2d) · §8's
substance (2c) · the write-gate UI, session resume, the provider picker, signing
(2b-iii).

**One judgement call made on the operator's behalf**, flagged here so it is easy to
reverse: §10 says *"the rail and Core fade back"* when a pane is maximized, implemented in
2b-ii as `.opacity(isMaximized ? 0.12 : 1)` on `CoreView`. With no Core there is nothing
to fade, so §7 below dims the room's **bleeds** to 0.4 while a pane is maximized, with the
motion continuing underneath. The alternative — maximize stops touching the void at all,
and §10 loses that clause — is a one-line change if the operator prefers it. Presented in
the design review on 2026-09-09 and not answered either way; the dimming is the default
because it preserves §10's sentence rather than deleting it.

---

## 2. The rule the whole sub-phase rests on

**Hue belongs to the environment. Motion and intensity belong to agent state.**

This is the objection that could have killed variant B, and the probe answered it.
`design-language.md` §5 already spends the void on environment — violet normally, red on
production — so making the void also carry agent state puts two independent variables on
one surface. Wakil speaking while pointed at production would have to be green and red at
once.

Splitting the channels resolves it. The environment owns the hue; the agent owns the
movement. A red room that breathes faster is production-and-thinking, unambiguously, and
`B-void-thinking-production-high.png` is the probe's evidence that the two read as two.

**The design's proof that the split holds is a negative one: `VoidPalette` is not
modified by this sub-phase at all, and `VoidPaletteTests` passes untouched.** No task
below has permission to reach into the palette to express a state. If a later change
needs to, the split has broken and this spec's central claim with it.

One consequence follows immediately: **the four states must be distinguishable without
colour**, because the environment has already spent it. That is
what makes rate — 5.4s against 1.5s against 0.42s — load-bearing rather than decorative,
and it is the risk §13 records.

---

## 3. `CoreMotion` — where the numbers live

New value type in `app/Sources/WakilKit/Visual/`, beside `CoreState` and `VoidPalette`. It
maps a `CoreState` to every number the room needs.

**Why a Swift type and not shader constants.** `Core.metal` today branches on an integer
state uniform and carries its periods as literals inside the fragment function. Repeating
that shape here would put all five of the probe's *admittedly invented* numbers into a
file where nothing is testable, no test can assert they match §7's table, and the tuning
pass §13 requires would edit Metal source with no safety net. `VoidPalette`'s own doc
comment states the codebase's rule — WakilKit stays free of AppKit **so that every
question with a right answer can be tested without a display** — and "does idle breathe at
the period §7 gives" is exactly such a question.

| State | Period | Amplitude | Spread | Drift | Bleed-B phase | Upper coupling | Resting fps |
|---|---|---|---|---|---|---|---|
| idle | 5.4 s | 0.55 – 0.67 | 1.0 | — | 0 | 1 | 15 |
| listening | 1.5 s | 0.95 – 1.25 | 1.35 | — | 0 | 1 | 30 |
| thinking | 12 s | 0.30 – 1.00 | 1.0 | 0.04 uv, 12 s | 0.5 | 1 | 15 |
| speaking | 0.42 s | 0.85 – 1.00 | 1.0 | — | 0 | **0** | 120 |

**Where each column comes from.** *Period*: idle's 5.4 s and listening's 1.5 s are §7's
own table, unchanged — the room inherits the sphere's cadences rather than inventing new
ones. Speaking's 0.42 s is `Core.metal`'s shipped pulse period. Thinking's 12 s is the one
period with no precedent: `Core.metal` spins at ~28.6 s, which the probe found too slow to
read as motion at all once translated from a rotating gradient on a small object to a
brightness swing across two large bleeds.

*Amplitude* is a multiplier on the bleeds' existing strength, where 1.0 is the void
exactly as it ships today. Idle is deliberately the dimmest of the four and listening the
brightest — "present but asleep" against "attending".

*Spread* multiplies the Gaussian exponent, so a larger number is a **tighter** bleed.
Listening is the only state that changes it, which is what §4's word "tighten" means for a
room rather than for a ring.

*Drift* is thinking's alone: a slow elliptical displacement of both bleed centres, so
thinking reads as turnover rather than as a brightness pulse.

**Two columns carry decisions taken in the 2026-09-09 design review**, and both exist to
express something structural as a scalar so the shader stays branchless:

- **Bleed-B phase 0.5** is thinking's antiphase. The two bleeds trade dominance rather
  than brightening together, which is the difference between a room turning something over
  and a room breathing faster. Every other state leaves it at 0.
- **Upper coupling 0** is speaking's bottom-locality, and it is the answer to the strobe
  risk. §4 gives speaking a 0.42 s pulse; applied to a whole peripheral field that is
  precisely what §1 warns against, and the probe's own notes call this "the single
  parameter most worth the operator's own judgment call". Rather than hold it down with a
  small constant and hope, the pulse is **contained by geometry**: it modulates only
  `fa`, the violet bleed already centred at `(0.5, 1.18)` below the frame, while the upper
  bleed holds steady. The room speaks from the place the voice is coming from — the same
  bottom edge §9's thread and §12's waveform now attach to — and no large peripheral area
  ever flickers at speech rate. This costs no new geometry: `Void.metal` already has
  exactly the region required.

**`CoreState.shaderIndex` is deleted, along with the test that pins it.** It is a wire
format for a wire that no longer exists — with `CoreMotion` resolving state to numbers in
Swift, the enum never reaches Metal again and the shader has no `state` uniform to branch
on. `CoreStateTests`' other two tests survive unchanged.

---

## 4. The layer stack collapses to one

Two layers, back to front:

    VoidView    (Metal)   the room, which is now the Core
    canvas      (SwiftUI) panes, the rail, the palettes, the context line,
                          and the thought thread anchored to the bottom edge

**Both arguments for a second Metal layer evaporate together, and that is worth stating
because 2b-ii made them separately.** Its spec §2.1 justified two layers because the Core
sits in *front* of the panes while the void sits behind, and SwiftUI cannot nest a view
inside one `MTKView`'s draw call. `north-star.md`'s frame-rate section justified them
again, independently, because the Core wants a clock and the void does not. Under B there
is no object in front of the panes, and there is exactly one cadence and it belongs to the
surviving layer. One layer is now not merely sufficient but correct.

**The occlusion problem stops being possible rather than being solved.** Across all eight
of the probe's B renders the mock pane is never touched, at any state, at either extreme
of the animation — because nothing is drawn in front of a pane at all. §1's fourth
principle (*data is never low-contrast behind a data surface*) becomes structurally
guaranteed instead of a placement constant that has to be re-tuned every time a pane
moves. This is B's real win, and it is structural rather than aesthetic.

### `Plane.near` is rescued rather than orphaned

`WakilWindow.nearOffset` has exactly one consumer today — `CoreView`, at
`WakilWindow.swift:143`. Deleting the Core would leave §3's near plane with no user
anywhere in the codebase. Meanwhile `ThoughtThread`'s own doc comment says it is "on the
near plane" and it applies **no** plane treatment at all: no scale, no opacity, no blur, no
offset. The claim is currently unbacked.

§7 below backs it. The thread takes the near plane's parallax, which is what §3 always
said it had, and the plane keeps a consumer. `Plane` itself is unmodified.

---

## 5. Frame rate, and why B is cheaper than what ships

**The probe doc's ledger is wrong on this point and this spec corrects it.** `void-as-core
-probe.md` §5 lists the breathing idle as a cost — *"the void can no longer be paused …
2b-ii's §2.2 makes 'a still window draws zero void frames' the phase's real battery
saving, and a breathing idle spends it."* That compares the void layer against itself and
ignores the layer beside it. `CoreView` is `preferredFramesPerSecond = 120` and
continuous; it is paused only on window occlusion. So an idle 2b-ii window draws **zero
void frames and a full-rate Core** — 60 fps on this machine — of a materially heavier
fragment shader: iridescence, two tick rings, a specular, rim occlusion.

An idle 2b-iv window draws **15 fps of one cheap shader and nothing else.** B is roughly a
four-fold idle saving, not a cost. Deleting the second layer pays for the breath outright,
with change.

### Cadence sets the cap

`preferredFramesPerSecond` is `CoreMotion.restingFrameRate(for:)`. Each state buys the
smoothness its own period needs and no more.

| State | Period | Resting fps | Frames per cycle |
|---|---|---|---|
| idle | 5.4 s | 15 | 81 |
| thinking | 12 s | 15 | 180 |
| listening | 1.5 s | 30 | 45 |
| speaking | 0.42 s | 120 | 50 (25 on a 60 Hz panel) |

The rule the tests assert is **at least 25 frames per cycle, and never above 120**.
Speaking is the tight one, and honestly so: on this machine's 60 Hz displays it lands at
25.2 frames per pulse, exactly at the floor. That is a real constraint on how much
speaking's period can be shortened later, and it is recorded rather than discovered.

Idle at 15 fps is safe on a slow luminance ramp because the per-frame delta of a 5.4 s sine
is far below an 8-bit quantisation step, and because `Void.metal`'s grain is a hash of
**position only** with no time term — it does not shimmer between frames and so cannot
alias against a low rate.

### The one place B could regress against 2b-ii, and the refinement that prevents it

The surviving layer also carries the far plane's parallax, which follows the pointer.
Today `VoidView` is `isPaused` with `enableSetNeedsDisplay`, so parallax redraws at
pointer-event rate; under a flat 15 fps cap it would visibly step against §7's
"weightless".

So the rate is state-derived **at rest** and bumps to 120 for a short window (250 ms)
after any parallax change. A moving cursor means somebody is looking at the window; a
still cursor over a still window is the idle case worth saving. This is set in
`updateNSView`, where the parallax already arrives and where 2b-ii's final-review Finding 4
already compares against the coordinator's held value to detect real change — the same
comparison, driving a rate instead of a `needsDisplay`.

### The occlusion pause carries over

`CoreView.Coordinator.observeOcclusion` — 2b-ii's final-review Finding 3 — moves onto
`VoidView` unchanged, including its reasoning: the signal is `NSWindow.occlusionState`,
not app-activation, because a visible-but-unfocused window is exactly the case where a
frozen room would read as "Wakil stopped" rather than as deliberate power saving.

**This is carried against the operator's stated pick.** The design review offered
cadence-sets-the-cap with and without the occlusion pause and the operator chose without.
It is carried anyway because dropping it would delete a working, shipped power-saving fix
as collateral damage of deleting the file it happens to live in, which is not a decision
anybody made. Reversing it is deleting one method.

---

## 6. The shader

`Void.metal` keeps its field, its two bleeds, its vignette and its grain. What changes is
that the bleeds' amplitude, spread and position are now driven, and one local term is
added.

### Uniforms

    struct VoidUniforms {
        float2 resolution;
        float3 bleedA;          // environment — never touched by state
        float3 bleedB;          // environment — never touched by state
        float2 parallax;
        float  time;
        float  period;
        float  amplitudeLow;
        float  amplitudeHigh;
        float  spreadFactor;
        float  driftAmplitude;
        float  driftPeriod;
        float  bleedBPhase;
        float  upperCoupling;
        float  threadAnchorX;
        float  threadLift;
        float  ambientScale;    // §1's maximize dimming
    };

**A layout hazard, named because `setFragmentBytes` is a raw memory copy with no schema**
(`VoidView`'s own comment says so). Metal's `float3` is 16-byte aligned and 16 bytes long;
Swift's `SIMD3<Float>` matches, which is why today's four-field struct works. The rule
this spec imposes so it keeps working: **every `float3` comes first, and every field after
the last one is a plain `float` or `float2`.** A `float3` appended after a run of floats
would silently repad the struct on one side only and corrupt everything after it. A
`#expect` on `MemoryLayout<VoidUniforms>.stride` guards the Swift side against a field
added without thought.

### Motion

    float phase = 6.28318 * u.time / max(u.period, 1e-4);
    float ampA  = mix(u.amplitudeLow, u.amplitudeHigh, 0.5 + 0.5 * sin(phase));
    float ampB  = mix(u.amplitudeLow, u.amplitudeHigh,
                      0.5 + 0.5 * sin(phase + 6.28318 * u.bleedBPhase));
    ampB = mix(1.0, ampB, u.upperCoupling);        // speaking: upper bleed holds still

    float dphase = 6.28318 * u.time / max(u.driftPeriod, 1e-4);
    float2 drift = u.driftAmplitude * float2(cos(dphase), sin(dphase));

    float2 a = (uv - float2(0.5, 1.18) - drift) * float2(aspect, 1.0);
    float2 b = (uv - float2(1.10, -0.10) + drift) * float2(aspect, 1.0);
    float fa = exp(-dot(a, a) * 3.2 * u.spreadFactor) * 0.55 * ampA;
    float fb = exp(-dot(b, b) * 4.0 * u.spreadFactor) * 0.38 * ampB;

Both `max(…, 1e-4)` guards matter: a state with no drift passes `driftPeriod = 0`, and a
division by zero in a fragment shader is a NaN that blanks the frame rather than an error
anybody sees.

The bleeds drift in **opposite** directions, which doubles the apparent turnover for a
given displacement and keeps the field's centre of mass still — a room turning over rather
than a room sliding.

### The coupling, and the maximize dim

    float2 t = (uv - float2(u.threadAnchorX, 1.06)) * float2(aspect, 1.0);
    fa += exp(-dot(t, t) * 26.0) * 0.30 * u.threadLift;

    float3 colour = field + u.bleedA * fa + u.bleedB * fb;
    colour = mix(field, colour, u.ambientScale);   // dims bleeds, never the field

`ambientScale` is 1.0 normally and 0.4 while a pane is maximized. It multiplies the
**bleeds only** — the field, the vignette and the grain are untouched, so a maximized
window still reads as the same room with the lights down rather than as a different,
flatter surface.

---

## 7. The anchor: §9's thread, §12's waveform, and the coupling

§9's thought thread rises *out of the Core* and §12's waveform and live transcription sit
*beneath it*. With no sphere, both need somewhere to attach. The operator chose the bottom
edge **and** the reactive coupling.

**The bottom edge is not an invented anchor.** §2's violet bleed already rises from below
the frame, centred at `(0.5, 1.18)` — off-canvas, so only its upper arc shows. The thread
rises out of that glow and the waveform sits in it, which keeps both sections' spatial
language literally true: "out of" and "beneath" still mean something.

**The thread moves out of the window's `VStack` flow.** Today `ThoughtThread(rows:)` is one
more row in `WakilWindow.loaded`, laid out between the message field and the status line.
It becomes a bottom-anchored overlay in the window's `ZStack`, above the void, and takes
`Plane.near`'s parallax and plane treatment — backing the doc comment that already claims
it (§4 above). This is a contained change: one view moves from one container to another
and gains three modifiers. **The rest of `WakilWindow`'s deliberately-unstyled layout is
not touched** — restyling that window is 2c's job against real content, not this
sub-phase's.

**The coupling runs both ways.** The room does not merely host the thread; the bleed
brightens locally where the thread meets the edge, so the room visibly gives birth to it.
Two uniforms carry it:

- **`threadAnchorX`** — where the lift is centred, in uv. **Measured, not assumed:** a
  `GeometryReader` on the thread overlay reports its own horizontal centre, converted by
  the window width. A constant would silently drift the glow away from the thread the
  first time anybody changes the window's padding.
- **`threadLift`** — 0…1. A pure function of `(hasRows, isTurnInFlight,
  secondsSinceLastRow)`, computed in `WakilKit` and unit-tested: 1.0 while a turn is in
  flight, decaying to 0 over 600 ms after the last row arrives, and 0 flat when there are
  no rows. It lives in Swift for the same reason §3's table does — it is a question with a
  right answer, and a decay curve buried in a shader is a decay curve nobody can test.

**This is the most invented thing in the sub-phase and the spec says so plainly.** Nothing
in `design-language.md` describes a locally-modulated bleed; §2 describes both bleeds as
uniform and wide, and §1's second principle ("if something glows, it is alive") is the only
warrant for making one of them react. It is included because the operator chose it over
the plain bottom-edge anchor, and §13 records it as the item most likely to be dialled back
at acceptance — reducing `0.30` toward zero degrades gracefully to the plain anchor with no
structural change.

**§12 is spec text only.** Voice is 2d. This sub-phase writes the sentences that say the
waveform and live transcription attach to the bottom edge and share the thread's coupling,
and builds no waveform. What 2d inherits is an anchor that already exists and a room whose
listening and speaking states are already rendered.

---

## 8. What is deleted

| Deleted | Why it existed |
|---|---|
| `app/Sources/WakilApp/CoreView.swift` (196 lines) | The second Metal layer |
| `app/Shaders/Core.metal` (126 lines) | The sphere |
| `WakilWindow`'s `CoreView` block, `.allowsHitTesting(false)`, `.opacity(isMaximized ? …)` | Keeping a front-layer object out of the way |
| `CoreState.shaderIndex` and `theShaderIndexIsStable` | A Swift↔Metal wire format with no wire |
| `core_vertex` / `core_fragment` from `make shaders` and its symbol check | — |

Every one of these exists **only** to keep a luminous object in front of the panes from
getting in the way. `CoreState` itself survives untouched in name and in shape — the
operator's naming decision on 2026-09-09 was that "the Core" stops meaning an object and
starts meaning Wakil's presence, which the void now carries. That keeps §4's title, keeps
`CoreState`/`coreState`/`CoreMotion` coherent, and means **zero rename churn**: every
existing cross-reference in `north-star.md`, the four prior specs and the acceptance
runbooks still resolves.

### The capture harness is reworked, and gains the thing the probe was missing

`Capture.swift` builds two pipelines and renders the Core over the void; it reaches
directly into `CoreView.Coordinator.CoreUniforms` and uses `shaderIndex`. All three go
away. It collapses to one pipeline, and its per-state PNGs become captures of the room in
each state.

**And it gains `--capture-motion`.** The probe's §6 says its central question — *whether
four states are distinguishable in motion, and whether a whole field in motion reads as
calm or as a strobe* — cannot be answered by stills and wants a screen recording. That
recording does not need a running app: the harness already renders offscreen at an
arbitrary `time`, so emitting a numbered frame sequence per state at that state's own
period and frame rate is about thirty lines on top of what exists. Assembled into a clip,
it answers the strobe question **before** the acceptance run rather than during it, and it
answers it reproducibly.

This is deliberately in scope. It is the cheapest possible route to the one judgement this
sub-phase cannot make headlessly, and building it is strictly less work than scheduling a
second human sitting.

---

## 9. Documentation

Charter-level change, so the paper trail is part of the deliverable rather than a
follow-up.

**`design-language.md`:**

- **§4 rewritten, not amended**, under its kept title. Four states, one *room*, no text
  labels. §3's table replaces the sphere's behaviour column. The "single permitted
  ornament" — the tick rings — goes with the sphere, which **strengthens** §1's first
  principle rather than weakening it: there are now no ornaments at all.
- **§1 principle 3 rewritten.** *"One bright object. The Core is the only genuinely
  luminous thing on screen"* loses its mechanism, because under B nothing is an object.
  The goal it served — a living interface that stays calm — is better served, not worse:
  the room is the only luminous thing, and a room cannot get in front of the data. The
  principle must say so.
- **§2** gains a pointer to §4: the void is no longer only environment.
- **§3** — the near plane's contents lose the Core and keep the thought thread and the
  current utterance.
- **§7's motion table** gains the room's periods and the frames-per-cycle rule from §5.
- **§9** — the thread rises out of the bottom edge's glow, and the glow answers it.
- **§12** — "the Core's four states *are* the voice indicator" becomes literally true, and
  the waveform's anchor is named.
- **§13** — two Metal layers become one; the idle cost is corrected downward.
- **§15** — a new open item: five of §3's constants are starting values awaiting the
  tuning pass.

**`north-star.md`:**

- **§7 question 11 closed and dated** — "should the void itself be the Core" is answered
  yes, with this spec as the record.
- **§8** gains a 2b-iv row and updates 2b-ii's.
- **The "cap the frame rate, but cap the right thing" section** gets a second dated
  amendment: its point 3 — *"the Core and the void want different cadences"*, answered on
  2026-09-09 by two Metal layers — is superseded. There is one cadence and one layer, and
  the prediction was right about the *reason* (deliberate, not inherited) while its answer
  had a shelf life of one sub-phase.

**`void-as-core-probe.md`** §7 moves from "a direction, not a decision" to a decision,
pointing here. Its §5 ledger gains the correction in §5 above.

**`phase-2b-ii-acceptance.md`** gains a note that its Core-specific checks are still to be
walked, and why (§0 above).

---

## 10. Verification

**Headless, in `WakilKitTests`** — the questions with right answers:

- `CoreMotionTests`: idle's period is §7's 5.4 s and listening's is §7's 1.5 s; idle is the
  dimmest state and listening the brightest; listening is the only state with a spread
  other than 1.0; thinking is the only state with drift and the only one with a non-zero
  bleed-B phase; speaking is the only state with upper coupling 0; every state's resting
  frame rate yields at least 25 frames per cycle and none exceeds 120.
- `threadLift` is 0 with no rows, 1.0 in flight, and monotonically decreasing to 0 across
  its 600 ms decay.
- `MemoryLayout<VoidUniforms>.stride` matches its expected value, guarding §6's layout
  rule.
- `CoreStateTests` loses `theShaderIndexIsStable` and keeps its other two.
- **`VoidPaletteTests` is unchanged and must stay unchanged** — §2's proof.

**Offscreen, via `make captures`:** one PNG per state per palette, as today, now of the
room; and `--capture-motion`'s frame sequences.

**Human, in a new `docs/wakil/phase-2b-iv-acceptance.md`**, because none of the above
touches what the sub-phase is actually for:

1. Are the four states distinguishable **in motion**? (The probe could not test this.
   `--capture-motion` is how it gets tested.)
2. Does a whole field in motion read as **calm**, or as a strobe you cannot look away
   from? This is the risk B carries that A never did.
3. Is speaking's bottom-locality enough containment, at its amplitude?
4. Does the coupling read as the room giving birth to the thread, or as a smudge?
5. Does production-and-thinking read as both at once, on a real window rather than a
   render?
6. Is anything ever occluded? (It should be structurally impossible. Confirm it.)
7. Does the maximize dim read as deference or as a fault?

Checks 1–3 are the tuning pass. **The acceptance runbook must number them, not footnote
them** — 2b-ii's lesson was that a phase whose value is a human judgement gets marked
"implemented" and then treated as met.

---

## 11. What 2b-iv does not change

`VoidPalette` and its tests. `Plane` and its tests. `CoreState`'s name, cases, raw values
and `forTurn`. The action registry, the canvas, magnetism, the rail, ⌘P/⌘K, the panes, the
density toggle, the project-switch transition, the window's title bar, and every one of
`WakilWindow`'s deliberately-unstyled controls apart from the one line where the thought
thread used to sit.

**Still two states of four are ever set.** `CoreState.forTurn` returns idle or thinking and
nothing else; listening and speaking belong to 2d. The room renders all four for the same
reason the sphere did — so 2d wires a microphone into a renderer that already exists.

---

## 12. File structure

**New**

    app/Sources/WakilKit/Visual/CoreMotion.swift
    app/Tests/WakilKitTests/CoreMotionTests.swift
    docs/wakil/phase-2b-iv-acceptance.md

**Modified**

    app/Shaders/Void.metal                       motion, coupling, ambient scale
    app/Sources/WakilApp/VoidView.swift          continuous; rate from CoreMotion;
                                                 occlusion pause; new uniforms
    app/Sources/WakilApp/WakilWindow.swift       CoreView block removed; thread
                                                 re-anchored; anchor measured
    app/Sources/WakilApp/ThoughtThread.swift     near-plane treatment; reports its anchor
    app/Sources/WakilApp/Capture.swift           one pipeline; --capture-motion
    app/Sources/WakilKit/Visual/CoreState.swift  shaderIndex removed
    app/Tests/WakilKitTests/CoreStateTests.swift pinning test removed
    Makefile                                     shaders target; captures target
    docs/wakil/design-language.md                §§1, 2, 3, 4, 7, 9, 12, 13, 15
    docs/wakil/north-star.md                     §7 q11, §8, frame-rate section
    docs/wakil/void-as-core-probe.md             §5 correction, §7 status
    docs/wakil/phase-2b-ii-acceptance.md         note on the Core-specific checks

**Deleted**

    app/Sources/WakilApp/CoreView.swift
    app/Shaders/Core.metal

---

## 13. Risks

**Calm versus strobe is untested and stays untested until somebody watches it.** This is
the one risk B carries that A never did, and it is the whole reason §8 puts
`--capture-motion` in scope. §1 warns that a single bright object works *because*
everything else stays quiet; a whole field in motion could be a strobe. Mitigation:
speaking's containment is structural (§3) rather than a tuned constant, and every
amplitude in §3's table degrades gracefully toward 1.0, which is the void exactly as it
ships today.

**Five of §3's constants are guesses.** Thinking's 12 s period and drift magnitude,
listening's 1.35 spread, and idle's and listening's amplitude floors and ceilings have no
precedent in `design-language.md` — the probe's own notes say so. They are starting
values. `CoreMotion` exists so that tuning them is a one-file edit with tests around it
rather than a shader hunt.

**The coupling has no warrant in the design language.** §7 says so. Dialling `0.30` toward
zero degrades to the plain bottom-edge anchor with no structural change, so the fallback
costs one constant.

**Four states on one channel.** With hue spoken for by the environment, brightness and rate
carry all four states between them. The probe found idle and thinking "distinguishable, but
only just" in stills, and argued rate would separate them in motion. If it does not, the
honest fallback is variant C — the room carries ambient state and a small sphere is
summoned for listening and speaking only — which was the reviewer's preference and remains
recoverable, since `Core.metal` is in git history rather than gone.

**Losing variant A's baseline.** Once the sphere is deleted, nobody can compare B against
A on a running window. This is why §0 has 2b-ii's acceptance walked in full **first**: it
is the only opportunity to record a human judgement of A, and it will not come again.

---

## 14. Open questions

1. **The maximize treatment** (§1). The room's bleeds dim to 0.4 by default; the operator
   may prefer maximize to stop touching the void at all. One line either way.
2. **Whether the thought thread should also fade on maximize.** §10's sentence covers "the
   rail and Core"; the thread was never named, and under B it now sits in the room's glow.
   Left as-is (no fade) pending the acceptance run.
3. **Does anything ever want the near plane besides the thread?** §3 lists "the Core, the
   thought thread, current utterance"; the first is gone and the third is 2d. If 2d's
   transcription does not take it either, §3's third row is one view wide.
