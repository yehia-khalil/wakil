# Phase 2b-ii acceptance run

**Status: MET 2026-09-10.** Walked 2026-09-09 by the operator; the six rows the walk left
half-discharged were confirmed by the operator 2026-09-10. See §2 for the per-check record
and for which rows are walk results versus later confirmations.

The 2b-ii design spec's §11 exit criteria, as a runbook. Most of what this phase built —
the void, the Core, motion, the production treatment, the two operator-facing gaps carried
out of Task 9 and Task 10 — is judged by eye, and **you execute the standing checks in §2**.
No agent ran them. Everything that could be established without a person looking at a
screen has been, and §3 says exactly what that was.

Written 2026-09-09, at the end of Task 13 of
`docs/superpowers/plans/2026-09-09-phase-2b-ii-atmosphere.md`. A check with an empty result
is a check that was not run, and that is worth knowing later, so unrun items say so rather
than being quietly dropped — the same convention `phase-2b-i-acceptance.md` used.

Companion documents: `docs/wakil/phase-2b-i-acceptance.md` (2b-i's own standing checks,
three of which are still unrun there and are not this document's job to re-run),
`docs/wakil/phase-2b-probe.md` (why 120fps cannot be observed on this machine, and the
probe's three visible shader defects — §2 check 2 below asks you to confirm they are
gone), `docs/wakil/operator-todo.md` (the Metal toolchain dependency, now load-bearing for
`make app-build` itself), `docs/superpowers/specs/2026-09-09-phase-2b-ii-atmosphere-design.md`
§11, and `.superpowers/sdd/2026-09-09-phase-2b-ii-atmosphere/progress.md` (the ledger this
document's §2 items 9–13 are transcribed from — every ruling that created an operator check
is cited by task number below rather than re-argued).

---

## 0. Why this list is short

2b-ii's headless surface is real but narrow: `CoreState`'s transitions, `VoidPalette`'s
environment matching, `Plane`'s parallax bounds, `thoughtRow`'s optional return, and
`pane_set_density`'s dispatch/journal/persistence — all in `WakilKitTests`, run by
`make app-test`. The capture tool (Task 13, this task) adds a second headless artifact: six
PNGs and a GPU timing line, produced by `make captures`.

Neither proves what this phase is actually for. A shader that compiles and returns the
right pixel values row-for-row could still look like a gradient instead of depth, or a
disc instead of a sphere — nothing in `WakilKitTests` or the capture tool can tell those
apart, because "reads as depth" is not a predicate. That is what §2 exists to check, and it
is why this document is short rather than automated: every item in it was tried and found
to have no honest machine equivalent, not skipped for convenience.

Three of §2's items (9, 10, 11) are not new to this task — they are operator checks that
Tasks 9, 10, 11 and 12 created and could not close themselves, carried forward here because
this is the document whose job is to hand them to a person. They are not re-derivations;
each cites the ruling that produced it.

---

## 1. Before you start

```bash
make app-build && make app-test && make captures
open .context/2b-ii
```

`make app-build` now depends on `make shaders`, which needs the Metal Toolchain component
(`docs/wakil/operator-todo.md`, "Phase 2b toolchain" — **no longer advisory as of 2b-ii**,
see §5 below). `make app-test` is expected to print **276 tests, all passing**. `make
captures` writes six PNGs into `.context/2b-ii/` and prints the GPU timing line recorded in
§5.

**The launch command** for the standing checks is unchanged from 2b-i's §1 — build the
bundle and run it:

```bash
make app-bundle
WAKIL_ORG=personal \
WAKIL_PROVIDER=<your claude-code provider id for that org> \
WAKIL_CLAUDE_PATH="$(command -v claude)" \
CLAUDE_CONFIG_DIR="$HOME/.claude-personal" \
CLAUDE_CODE_OAUTH_TOKEN='<the token for that account>' \
app/Wakil.app/Contents/MacOS/Wakil
```

Everything 2b-i's §1 said about this command still holds: the three `claude` variables may
be omitted for anything in §2 that does not need a real turn (only check 5, the thought
thread, does); the window may open behind Terminal.

### What the window looks like now, that did not before

2b-i's window drew unstyled boxes on the window's own background. 2b-ii is where
`design-language.md` actually ships: the void fills the whole frame (the title bar is
gone — see check 9 below), a violet-and-blue atmospheric bleed rises from the bottom and
upper right, the Core floats above the panes as a small iridescent sphere with two tick
rings, panes are slabs with a drop shadow rather than outlined boxes, and the environment
label turns the whole room red when the active project's environment is production. The
rail and the pane grid gained a density toggle (⌘⇧D) and, per Task 10's discovery, the
pane's data grid is no longer a SwiftUI `Table` — see check 13.

---

## 2. The standing checks

**Walked 2026-09-09 by the operator, MacBook Air M3, from the `nicosia`
worktree at `515434f`, alongside `phase-2b-iv-acceptance.md`.** Results are in the rows
below.

**Discharged 2026-09-10 by the operator.** Four rows read "PASS, pending
confirmation" and two read "NOT RECORDED"/"NOT MEASURED" — checks the walk reported as
working but which needed a specific tool (Activity Monitor, VoiceOver, a stopwatch, a real
quit-and-relaunch) that was not separately confirmed at the time. The operator has since
confirmed all six as passes. They are recorded below as **PASS (confirmed 2026-09-10)** so
that a reader can still tell them apart from a row discharged by the walk itself; where a
row owed a *number* rather than a judgement, the number was never taken and is not
invented here — the row says so.

**Check 2 is void.** It judges the Core sphere, which 2b-iv deleted. It remains walkable
only in a worktree at `cf50d35`; `phase-2b-iv-acceptance.md` §0 has the procedure and says
what is unrecoverable.

**One defect was found during this walk and fixed the same day: clicking a pane did not
focus it.** Latent since 2b-i, surfaced by 2b-iv's check 7. Full write-up in
`phase-2b-iv-acceptance.md` §4, "What the walk found". Checks 7 and 9 above were re-walked
after the fix, since it touched the same gesture surface.

Run all of these after any change to `Void.metal`, `Core.metal`, `Plane.swift`,
`VoidPalette.swift`, the pane grid, or the window chrome. Record the result and the date; a
re-run replaces the row rather than appending to it.

### Check 1 — the void reads as depth, not a gradient

*Spec §2, §11: "the void reads as depth rather than as a gradient; no banding where the
bleeds meet."*

**Look for:** the near-black field should not look like two circular gradients pasted onto
flat colour — it should read as a dim, receding room with two weak light sources bleeding
in from off-frame. Look specifically at the boundary where the violet bleed (rising from
below) and the blue bleed (upper right) overlap, and at the field itself away from both:
no visible 8-bit banding rings. `Void.metal`'s grain term exists to break banding up
(`docs/superpowers/sdd/.../progress.md` Task 3: "grain is ±1.07 LSB at 8-bit — above the
textbook dithering minimum but only provable by eye").

`.context/2b-ii/void-staging.png` and `void-production.png` are static references for this
check, not a substitute for it — motion and viewing-angle effects (a real display's
dithering, subpixel rendering) do not survive a PNG.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-09 | Reads as depth, not two gradients on flat colour. No banding rings where the bleeds overlap. Confirmed on the running window as well as on `void-staging.png`. |

### Check 2 — the Core reads as a volume, not a disc

*Spec §4, §11; the probe's three defects (`phase-2b-probe.md` §5) are the specific things
to look for being gone.*

**Look for:**
1. **No seam at any angle.** The probe's original conic gradient had a hard radial line
   where `atan2` wraps at ±π; `Core.metal`'s `iridescence()` was rewritten as a sum of
   cosines specifically to close that wrap (see the comment above it, "Probe §5 defect 1,
   fixed here"). Rotate your attention around the sphere — thinking state spins it, so
   watch `core-thinking.png` or the running Core in the thinking state — and confirm no
   line crosses it anywhere.
2. **A highlight, not pearl.** The specular in the probe was too large and too hot; it was
   reduced to a quarter the radius and half the intensity (`Core.metal`, "Probe §5 defect
   2"). Confirm the bright spot near the upper-left of the sphere reads as a highlight on a
   coloured surface, not as a second light source washing it out.
3. **A volume, not a disc.** Rim occlusion was too weak in the probe for the sphere to
   read as round; it now falls off as a power of the surface normal's z-component rather
   than a flat radial ramp (`Core.metal`, "Probe §5 defect 3"). Confirm the edge of the
   sphere darkens the way a lit ball's would, rather than staying uniformly bright to a
   hard edge.

**Compare against `.context/core-probe-states.png`** if it exists on your machine — it was
the probe's own capture, made outside this repository (`/tmp/coreprobe`,
`phase-2b-probe.md` §0) and is not checked in, so it will not exist on a fresh clone. **On
this machine, at the time of writing, it does not exist** — `.context/` here holds only
this task's `2b-ii/` captures. If you have it from an earlier session, the three defects
listed above should be visibly gone by comparison; if you do not, judge against the
description above instead.

`.context/2b-ii/core-idle.png`, `core-listening.png`, `core-thinking.png`,
`core-speaking.png` are this task's captures, one per state, all at `time = 2.0` seconds so
idle is not caught at a zero-crossing of its breath.

| Result | Date | Notes |
|---|---|---|
| **VOID — not walkable on HEAD** | 2026-09-09 | 2b-iv deleted `Core.metal` and `CoreView.swift`, so there is no sphere to judge. Still individually walkable in a worktree at `cf50d35` (`phase-2b-iv-acceptance.md` §0); the side-by-side comparison against the room is gone for good. The controller's PNG review below flagged the specular and the tick rings as looking *unfixed*, and that reading now has no way to be confirmed or overturned on a running window. |

### Check 3 — production is alarming without being exhausting

*Spec §3.2, §11.*

**Setup.** Switch the active project's environment to one whose name lowercases to
`production` (via ⌘K's `ctx_set_environment`, or by editing the project's environment
list) and back to a non-production one.

**Look for:** the whole room turns red — both void bleeds — and the environment label
reads it too, so the badge and the room agree. It should register immediately (this is the
one reserved, non-decorative use of red in the design language) without becoming
uncomfortable to work in for an extended session. Switch back and confirm the room returns
to the violet/blue staging treatment cleanly, with no residual red tint or flash.

`.context/2b-ii/void-production.png` is the static reference; the "exhausting" half of
this check specifically cannot be judged from a still image and needs you to sit with it.

| Result | Date | Notes |
|---|---|---|
| **PASS (confirmed 2026-09-10)** | 2026-09-09 | Reported as working on the walk; confirmed by the operator 2026-09-10. The controller's PNG review had flagged this as reading 'warm rather than alarming' — that reading is **overturned**, and the 'exhausting over a long session' half is confirmed as sat with rather than glanced at. |

### Check 4 — parallax adds depth without motion sickness

*Spec §6, §11; Task 5's ruling on `.animation` removal (progress.md Task 5) is what this
check is verifying held up in practice.*

**Look for:** move the pointer around the window and watch the void, the Core, and the
panes each drift by a different, small amount (the layered-plane parallax `Plane.swift`
defines). It should read as depth — near things moving more than far things — track the
pointer smoothly with no lag, stepping, or rubber-banding, and should not feel disorienting
or nauseating over a sustained session. Task 5's ledger entry recorded a specific risk here
(a 400ms ease on a continuously-updating value would have caused exactly this) and removed
it; this check is where that removal gets confirmed by a person rather than by reasoning
about the code.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-09 | Depth, not nausea. Task 5's `.animation` removal holds up in practice — no lag, stepping or rubber-banding. |

### Check 5 — the thought thread is readable during a real turn, and carries no `stream_event` rows

*Spec §11; Task 8's dropped `.unknown` case (progress.md Task 8) is what this checks.*

**Setup.** This is the one check in this section that needs the three `claude` variables
from §1 — send a real query and let a turn run to completion.

**Look for:** the thought thread updates as the turn progresses, and every row is one of
the meaningful cases `thoughtRow` maps events to — never a raw `stream_event`/`.unknown`
row leaking through. Confirm the thread stays legible (not a wall of raw JSON, not
scrolling faster than it can be read) for an ordinary turn.

**A known open question, not a defect:** Task 8's reviewer could not find where a developer
debugging a stalled session would see the dropped raw events instead — the spec's risk
section claims "the events still arrive and the harness still logs them," which was never
substantiated and should either be verified or corrected (progress.md Task 8, second minor
finding). Not this check's job to fix; flagging it here so it is not lost.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-09 | A real turn ran to completion. Thread rows are all meaningful cases; no raw `stream_event`/`.unknown` leaked; legible rather than a JSON wall. The open question about where a developer would see the dropped raw events is untouched and still open. |

### Check 6 — ⌘⇧D tightens the rows, survives a quit, and appears in ⌘K

*Spec §8, §11 (`pane_set_density`); Task 10's Table→grid replacement (progress.md Task 10)
is what makes 23pt reachable at all — see check 13.*

**Look for:**
1. Focus a pane with the `db` grid and press ⌘⇧D (also reachable via the Window menu's
   *Toggle Density*, and via ⌘K as `pane_set_density`). Row height visibly tightens from
   the airy default to the dense 23pt. Toggle again and it returns to airy.
2. Quit the app and relaunch with the same project active. The pane's density should be
   restored to whatever it was left at — `pane_set_density` round-trips through
   persistence per-pane (progress.md, Task 13 brief's Step 5 wording; `LayoutPersistence`
   tests pin the write/read but not that a *real* quit-and-relaunch preserves it).
3. Open ⌘K and confirm `pane_set_density` is listed with its description as the subtitle,
   the same way every other registered action is (2b-i standing check 3's method applies
   unchanged).

| Result | Date | Notes |
|---|---|---|
| **PASS (confirmed 2026-09-10)** | 2026-09-09 | ⌘⇧D tightening and the ⌘K listing reported working on the walk. The quit-and-relaunch half — that per-pane density survives a real restart, which `LayoutPersistence`'s tests do not cover — was not separately recorded at the time and is **confirmed by the operator 2026-09-10**. |

### Check 7 — ⌘⏎ fills the void with the rail and Core fading back

*Spec §8.2, §11: "Maximize (⌘⏎) fills the void with the focused pane; the rail and Core
fade back."*

**Look for:** press ⌘⏎ on a focused pane. It expands to fill the canvas on the same
400–600ms ease-out plane transition the spec names for all motion in this phase (§8), and
—new in 2b-ii, where 2b-i's maximize "filled the canvas and nothing faded, because there
was nothing to fade" (spec §8.2) — the rail and the Core visibly recede/fade rather than
staying at full presence while a pane owns the whole frame. Press ⌘⏎ again and confirm it
returns to exactly its prior rectangle, with the rail and Core fading back in.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-09 | Pane fills the canvas and returns to its exact prior rectangle. The rail recedes further than its resting far-plane treatment. The Core half of this check is void — 2b-iv deleted it. |

### Check 8 — switching project moves rather than flickers

*Spec §8.1, §11.*

**Look for:** switch to a different project (⌘P, or `ctx_set_project`) with panes open in
both. The outgoing panes should visibly recede while the incoming ones rise — a single
continuous motion masking the reconnect underneath — rather than a hard cut or a visible
blank/flash frame. `WakilWindow.swift` drives this off `.id(model.project)` with a 0.5s
ease-out (line ~324–328).

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-09 | Walked against a second project (`wakil-acceptance-2`, registered 2026-09-09 for this purpose). Outgoing panes recede while incoming rise; no hard cut, no blank frame. |

### Check 9 — dragging the void moves the window; dragging a pane moves the pane

*Not in spec §11's list; created by Task 12's ruling on `isMovableByWindowBackground`
(progress.md, Task 12: "keep, and Task 13's runbook must make it an explicit operator
check — drag the void, the window moves; drag a pane, the pane moves.").* With the title
bar gone (§9 below), the void itself became the window's drag handle — in 2b-i, dragging
empty canvas space did nothing.

**Look for:**
1. Press on an empty area of the void (no pane under the pointer) and drag. **The whole
   window moves**, the way dragging a normal title bar would.
2. Press on a pane and drag. **Only the pane moves** — the window stays put, and the
   pane's own drag/snap behaviour from 2b-i (`phase-2b-i-acceptance.md` standing check 1)
   is unaffected.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-09 | Dragging the void moves the window; dragging a pane moves only the pane. Task 12's `isMovableByWindowBackground` ruling holds. **Re-walked after the pane-focus fix below, which touched the same gesture surface.** |

### Check 10 — a truncated cell's full value appears on hover

*Created by Task 10's ruling (progress.md, Task 10: "`.help()` tooltip rendering could not
be verified in a headless NSHostingView harness... Ruling: Task 13's acceptance runbook
must carry 'hover a truncated cell and confirm the full value appears' as an operator
check.").* The code passes the untruncated string to `.help()` and the API is documented to
show it on hover; nothing headless could confirm SwiftUI actually bridges it to
`NSView.toolTip` in this view.

**Setup.** Open a `db` pane with a query result containing at least one long cell value —
wide enough to be tail-truncated by the pane's column-width cap (Task 10's fix,
progress.md fix round 1).

**Look for:** hover the truncated cell. A tooltip should appear showing the full,
untruncated value.

**If it does not:** this is not a cosmetic miss. Per Task 10's ruling, truncated values are
otherwise **unrecoverable** — there is no expand-on-click or other fallback — so a failure
here is a real defect requiring a visible alternative recovery path, not a note to carry
forward.

| Result | Date | Notes |
|---|---|---|
| **PASS (confirmed 2026-09-10)** | 2026-09-09 | Reported as working on the walk; **confirmed by the operator 2026-09-10**. A failure here would have been a real defect rather than cosmetic — truncated values have no other recovery path — which is why it was held open until confirmed. |

### Check 11 — VoiceOver reads the grid's rows and columns

*Created by Task 10's ruling (progress.md, Task 10: "the accessibility labels likewise
could not be confirmed against a live VoiceOver session... Same disposition — the
modifiers are applied correctly per review, and the runbook gets a VoiceOver check.").*
When `Table` was replaced with a hand-built grid, the row/column accessibility labels
`Table` gave for free had to be restored by hand; they could not be confirmed against a
real assistive-technology client in a headless harness.

**Setup.** Turn on VoiceOver (⌘F5) and navigate to a `db` pane's grid.

**Look for:** VoiceOver announces each cell's row and column context — the same shape of
announcement `NSTableView`-backed content would give — not silence, not a single
undifferentiated blob of text for the whole grid.

| Result | Date | Notes |
|---|---|---|
| **PASS (confirmed 2026-09-10)** | 2026-09-10 | VoiceOver (⌘F5) over a `db` grid was not separately confirmed on the walk; **confirmed by the operator 2026-09-10**. This is the check that proves the hand-built grid actually restored the accessibility semantics it took from `Table`. |

### Check 12 (operator step, not a pass/fail check) — the project-switch timing

*Spec §8.1, §13: "a project or org switch under ~400ms to interactive." Never measured —
`progress.md`, Task 11: "MEASUREMENT NOT TAKEN — the project-switch timing. Only one
project (wakil-acceptance, org personal) is registered on this machine and the implementer
was told not to register a second or invent a number... This number is owed to Task 13's
runbook and must be recorded there as an OPERATOR step, not as a result."*

This step is carried forward unmeasured, deliberately. Register a second project so there
is somewhere to switch to:

```bash
./bin/wakil project add <second-project-name> \
  --path /abs/path/to/<second-project>/.wakil/project.json --org personal
```

Then, with the app running and both projects' panes open at least once (so `LayoutStore`
holds a real arrangement for each — 2b-i §3.3, spec §8.1's "state is not torn down"), switch
between them via ⌘P and time from the keypress that commits the switch to the moment the
incoming panes are interactive (clickable/draggable), by eye or stopwatch. Record the
number below — it is a measurement to add, not a check to pass or fail, since no number has
ever been recorded here before.

| Measurement | Date | Notes |
|---|---|---|
| **PASS (confirmed 2026-09-10)** | 2026-09-10 | A second project (`wakil-acceptance-2`) was registered 2026-09-09 so the switch could be walked at all, and check 8 above was walked against it. The operator confirms the switch as within budget 2026-09-10. **No number was ever put to a stopwatch and none is invented here** — this row is a judgement that the glide is fast enough, not a measurement of 400ms. |

### Check 13 (informational, not pass/fail) — what replacing `Table` with a hand-built grid forecloses

*Not a check to run — a fact to carry, per progress.md Task 10's measurement: SwiftUI
`Table` on macOS floors row height at 24pt (`usesAutomaticRowHeights = true` on the
backing `NSTableView`), which made the design language's 23pt dense row unreachable inside
`Table`. It was replaced with a `Grid`/`ScrollView` construction that honours
`.frame(height:)` exactly.*

Record, so a later phase does not rediscover this by surprise: the replacement has no
`NSTableView` underneath, which means **column resizing, header-driven sorting, and
built-in laziness/virtualization for very large result sets are not available** the way
they would have been on `Table` — none of these were wired up in 2b-i either, so they are
options foreclosed rather than regressions, but they are foreclosed now in a way a future
task inheriting this pane should know before reaching for them. Truncation recovery (check
10) and VoiceOver semantics (check 11) were rebuilt by hand specifically because the
replacement does not provide them automatically; both needed two fix rounds
(progress.md, Task 10) to reach parity with what `Table` gave for free.

### A discrepancy the spec does not admit to, carried from Task 9

*Progress.md, Task 9: "the active row's luminous left edge is DEFERRED, not implemented...
Ruling: the deferral stands and Task 14 must record it — the spec claims this element ships
in 2b-ii."*

`design-language.md` §8 and the phase spec describe a violet luminous left edge on the data
grid's active/selected row as part of this phase's deliverable. **It does not exist.** No
selection model exists anywhere in the codebase (confirmed by grep during Task 9's review),
and building one to support a single visual flourish was judged to be inventing a data-
surface feature that belongs to 2c with the rest of the grid's substance. There is nothing
to check for in §2 above because there is nothing rendered — this is recorded here as an
open discrepancy between what the spec promises and what shipped, not as a check with a
result row.

### The controller's visual review of the six PNGs — flagged, not passed

*`progress.md`, "CONTROLLER VISUAL REVIEW of .context/2b-ii/*.png — the first time
anything in this phase was looked at."* Written 2026-09-09, before this document existed
in its current form. **This is not an operator run and does not discharge checks 1, 2, or
3 above** — a still PNG cannot show motion, a real display's dithering, or sustained
viewing, and §3 row 7's spot-check already says the same about the implementing session's
own cursory look. It is included here, faithfully, because it is the only pair of eyes
that has been on this phase's output so far, and observations from it are worth more than
nothing while the standing checks above sit unrun. Treat every line below as a flag for
the operator to confirm or overturn, not as a result.

- **The void (relates to check 1).** `void-staging.png` and `void-production.png` read as
  described: near-black field, violet bleeding in from below, cool blue upper right,
  corners falling away, no banding detected by eye at this compression.
- **Production (relates to check 3).** Reads **warm rather than alarming** — a dark
  maroon glow, clearly distinct from the violet staging treatment, but closer to "warm"
  than to "warning." Flagged for the operator; it may need to be pushed further before it
  satisfies §3's "should register immediately."
- **The specular (relates to check 2, probe defect 2).** Still reads as a broad, hot bloom
  upper-left — closer to pearl or a glass bead than to §4's "iridescent volumetric."
  This is one of the two probe defects 2b-ii was specifically meant to fix, and by this
  reading it looks unfixed at capture size. Needs the operator's eye to confirm or
  overturn — code review already traced the shader change algebraically and found no
  halo, so this may be a magnitude question rather than a correctness one.
- **The tick rings (relates to check 2, the ornament rule, §4.3).** Read as a **thick
  sunburst corona** carrying a large share of the sphere's visual weight, where the
  design language calls them "thin" and permits them as the *single* ornament precisely
  because they are meant to be restrained. In `core-idle.png` they compete with the
  sphere rather than sitting quietly on it. This is the second of the two probe defects
  2b-ii was meant to fix and, by this reading, also looks unfixed at capture size.
- **A possible ±π seam (relates to check 2, probe defect 1) — recorded WITH its
  uncertainty, not as a finding.** `core-thinking.png` may show a harder magenta/blue
  boundary at roughly eight o'clock against otherwise smooth transitions elsewhere, which
  is the visual signature a wrap discontinuity would leave. **This is genuinely
  uncertain.** Both a code reviewer (Task 7) and the controller independently verified
  that `iridescence()`'s cosine palette is periodic by construction — mathematically
  there is no wrap left to close, so there should be no seam to see. The observation may
  simply be misreading a smooth transition as a hard edge at this image's compression and
  size. This needs the operator looking at the actual running Core, rotating it, at full
  size — exactly what check 2 above already asks for — before it can be called either a
  real defect or a false alarm.

**The Core-specific checks were never walked, and 2b-iv landed anyway.** Whether the
sphere read as a volume rather than a disc, whether its specular read as a highlight
rather than as pearl, whether the tick rings read as reactive, and whether it was legible
from the corner of the eye are judgements nobody made. The spec
(`docs/superpowers/specs/2026-09-09-void-as-core-design.md` §0) said 2b-ii's acceptance
runbook is walked in full *before* this sub-phase starts; the plan that executed it never
turned that sentence into a task, and execution ran straight through. Recorded here as a
process failure, not elided: `a2dafcc` ("2b-iv Task 4: delete the Core sphere") landed
several commits before this document was touched.

**The baseline is not lost, only moved.** `cf50d35` ("2b-iv Task 3: carry the occlusion
pause onto the surviving layer") is the last commit containing `app/Shaders/Core.metal`
and `app/Sources/WakilApp/CoreView.swift`. A worktree checked out at that commit still
builds and runs the sphere, so these four checks remain walkable — they now cost a
`git worktree add` rather than nothing. What is genuinely gone is the comparison, not the
object: nobody will ever see the sphere and the room in the same running window on the
same day, so a judgement of the room *against* the sphere, side by side, is no longer
available even though each is individually still reachable.

---

## 3. What was verified headlessly

None of this needed a display session or a person. All observed 2026-09-09 on the machine
described in `phase-2b-probe.md` (MacBook Air M3, `Mac15,12`, macOS 26.6.2).

| # | Observation |
|---|---|
| 1 | `make app-build` is clean: `xcrun metal` compiles `Void.metal` and `Core.metal` into one `default.metallib`, and `swift build` succeeds against it. |
| 2 | `make app-test` — **276 tests, all passing**, including `CoreState`'s transition tests, `VoidPalette`'s environment-matching tests, `Plane`'s parallax-bound tests, `thoughtRow`'s optional-return tests, and `pane_set_density`'s dispatch/journal/persistence/per-pane tests (spec §11's headless list, in full). |
| 3 | `make captures` runs cleanly and writes six PNGs — `core-idle.png`, `core-listening.png`, `core-thinking.png`, `core-speaking.png`, `void-staging.png`, `void-production.png` — all `900×620` 8-bit RGBA, into `.context/2b-ii/`. |
| 4 | The GPU timing line printed by `make captures` (§5 below) completed without a Metal validation error or a dropped frame in the offscreen loop. |
| 5 | Both attached displays report 60Hz: `Built-in Retina Display` at `1470×956`, `LF22T35` at `1920×1080`, both `NSScreen.maximumFramesPerSecond == 60` — read live via a throwaway `NSScreen.screens` probe, matching `phase-2b-i-acceptance.md` §4 row 7 exactly (same machine, same result). |
| 6 | The `VoidUniforms` and `CoreUniforms` structs the capture tool declares match `Void.metal`/`Core.metal`'s current definitions and `VoidView`/`CoreView`'s own private copies field-for-field — checked by reading all four declarations side by side before writing the capture tool, per this task's brief. No drift was found; the brief's own re-declaration was already correct against the shaders as they stand today. |
| 7 | A cursory look at all six captured PNGs (not a substitute for §2's checks, which need motion, a real display, and sustained attention): the Core's sphere in `core-thinking.png` shows no visible seam at the angle captured, a small cool-white highlight rather than a large hot one, and rim darkening toward the edge; `void-production.png` shows the red bleed from both sources with no visible banding at this compression. This is a spot-check by the implementing session, offered as a sanity signal only — it does not discharge check 1, 2, or 3. |

---

## 4. What 2b-ii cannot verify, and why

### 120fps was not observed, and no 2b document may claim it was

`NSScreen.maximumFramesPerSecond` reports **60** on both attached displays — the Built-in
Retina Display and the LF22T35 (§3 row 5). Neither can display a 120fps frame, so the
north-star's *"120fps shell on ProMotion"* remains unfalsifiable on this machine, exactly
as `phase-2b-i-acceptance.md` §5 and `phase-2b-probe.md` §4 already recorded for 2b-i and
the probe. **The honest proxy is GPU frame cost against the 8.33ms budget**, recorded in §5
below. Verifying the target itself needs ProMotion hardware and is deferred to whoever has
some.

### Listening and speaking are rendered and photographed, never set by the app

`CoreState.listening` and `.speaking` exist in the shader, the enum, and this task's
capture (`core-listening.png`, `core-speaking.png`) — but nothing in the running app ever
sets the Core to either state. `CoreState.forTurn(inFlight:)` only ever returns `.idle` or
`.thinking` (`CoreState.swift`'s own doc comment: "listening and speaking belong to voice,
which is 2d... driving them from proxies available today... would invent semantics 2d then
has to unpick"). A PASS on check 2 above, or on the captures, proves the *renderer* is
right for all four states — it says nothing about whether the *application* will ever
correctly enter listening or speaking, because it cannot yet.

### 2a's acceptance checks 5 and 6 remain unrun

The write gate and *production blocked*, from `phase-2a-acceptance.md`. Both need a
`.mutate` action; 2b-ii registers none — `pane_set_density` is `.control` (changing a row
height changes Wakil and nothing else), same as every 2b-i layout action. This is the same
gap `phase-2b-i-acceptance.md` §5 recorded for 2b-i, restated because it is still true: they
belong to 2b-iii, which is where the write-gate UI and the first `.mutate` action land. The
scripts to run on that day are already written down in `phase-2a-acceptance.md` §§*Check 5*
and *Check 6*; this document does not re-derive them.

### Everything named in §2 — why no agent walked it

*Written before the walk. The checks were walked by the operator on 2026-09-09 and the six
rows they left half-discharged were confirmed 2026-09-10; §2 has the results. This section
is kept for why an agent could not do it.*

Every standing check in §2 needs a person with a mouse and a screen. None of them was
walked by this session, for the same structural reason `phase-2b-i-acceptance.md` §0 gives:
an automated harness has no Accessibility or Screen Recording grant, cannot post a
synthetic keystroke or click, and cannot take a screenshot the way `screencapture -x` would.
Whether the void reads as depth, the Core as a volume, production as alarming-not-
exhausting, parallax as depth-not-nausea, the thought thread as readable, density and
maximize as smooth, a project switch as a glide rather than a flicker, and the void/pane
drag split as correct, are eleven judgements a machine has no way to make, and this
document does not pretend otherwise.

---

## 5. Recorded measurements

### GPU frame cost, from `make captures` (2026-09-09, this machine)

**Fix round 1 correction.** The first version of this section reported one number, taken
at a hardcoded `900×620` *raw-pixel* texture, and called it "comparable with the probe's"
figure of p50 1.090ms without checking what the probe actually rendered. That comparison
was not established. `phase-2b-probe.md` §3 states only a **"900×620 window"** — it never
states a drawable size, and a window's point size and its drawable's pixel size are not the
same thing on a Retina display. `CoreView.swift`'s own measured comment records this
machine's backing scale factor as **2.0** (`bounds {1470, 923}` vs. `drawableSize {2940,
1846}`), and the probe ran in an `MTKView`, whose `drawableSize` defaults to `bounds.size ×
backingScaleFactor` — so the probe was very likely rendering `1800×1240`, four times the
pixel count of the number this document first reported. **The probe's true pixel count is
not recorded anywhere and cannot now be confirmed, only inferred** — so the two figures
were never provably comparable in the first place, which is itself worth having written
down rather than silently assumed.

`1800×1240` is `900×620` doubled on both axes — the resolution this app actually renders
at on this machine's 2.0-backing-scale display, and the figure the budget comparison below
should be read against.

**Final review correction (Finding 8, 2026-09-09).** This section previously took the
three-out-of-four consistent reading as the figures, treated the fourth as a single
"outlier" caused "plausibly" by system load from a just-finished build, and built a
gap-to-the-probe argument on the low reading those three agreed on — the load claim was
never checked, and picking the majority reading from a sample of four was not, by itself,
evidence that the minority reading would stay rare. The final reviewer re-ran
`make captures` once and got the high reading again (p50 0.289ms / 0.461ms), which is what
prompted this section to be re-measured properly rather than patched with one more run
chosen after the fact.

**Seven fresh runs, back to back, `make captures` each time (2026-09-09):**

```
run 1: core gpu (900x620) p50=0.078ms p95=0.293ms max=0.648ms   (1800x1240, 2x) p50=0.275ms p95=0.278ms max=0.845ms
run 2: core gpu (900x620) p50=0.078ms p95=0.293ms max=0.638ms   (1800x1240, 2x) p50=0.275ms p95=0.279ms max=0.859ms
run 3: core gpu (900x620) p50=0.079ms p95=0.291ms max=0.648ms   (1800x1240, 2x) p50=0.275ms p95=0.279ms max=0.840ms
run 4: core gpu (900x620) p50=0.289ms p95=0.293ms max=1.967ms   (1800x1240, 2x) p50=0.461ms p95=0.465ms max=1.436ms
run 5: core gpu (900x620) p50=0.079ms p95=0.292ms max=0.652ms   (1800x1240, 2x) p50=0.275ms p95=0.279ms max=0.843ms
run 6: core gpu (900x620) p50=0.079ms p95=0.290ms max=0.999ms   (1800x1240, 2x) p50=0.275ms p95=0.279ms max=0.798ms
run 7: core gpu (900x620) p50=0.078ms p95=0.288ms max=0.634ms   (1800x1240, 2x) p50=0.275ms p95=0.279ms max=0.860ms
budget 8.33ms at 120fps; this display reports 60Hz (all seven runs)
```

**The spread, reported rather than collapsed to one figure:**

| | `900×620` p50 | `900×620` max | `1800×1240` p50 | `1800×1240` max |
|---|---|---|---|---|
| Typical (6 of 7 runs) | 0.078–0.079ms | 0.634–0.999ms | 0.275ms | 0.798–0.860ms |
| High reading (1 of 7 runs) | 0.289ms | 1.967ms | 0.461ms | 1.436ms |

Combined with the five runs already on record from earlier in this document — the original
section's four (three typical, one high at p50 0.289ms/0.459ms) and the final reviewer's
one re-run (high again, 0.289ms/0.461ms) — the honest count across **twelve** runs taken on
three separate occasions is **three high readings, nine typical: one in four, not one in
five and not a single unrepeated outlier.** The high reading is not rare and it is not a
fluke of any one run; it is a second, less frequent mode this measurement lands in, and it
recurs at effectively the same magnitude (p50 ≈ 0.289ms / 0.461ms) each time, which is
itself informative — a true one-off system hiccup would not be expected to reproduce the
same number three times.

**The "system load from the build that had just finished" explanation is dropped, not
downgraded — it is contradicted by this run.** Every one of these seven runs was produced
by `make captures`, which depends on `app-build`, which always re-invokes `shaders` and
`swift build`; every run in this sample was therefore taken "just after a build" in exactly
the sense the original claim meant, and six of the seven were still typical. If a
just-finished build were what caused the high reading, most or all of these seven runs
should have shown it; instead only one did. Build recency does not distinguish the two
modes in this sample, so it is not asserted as the cause here. What actually causes the
bimodality is not established by this document and is left **unexplained** — consistent
with this fix round's own instruction not to replace one unchecked theory with another.

**The gap-to-the-probe reasoning is downgraded to "typical reading only" — it does
not hold at the high reading.** At the typical reading, p50 at `1800×1240` (0.275ms) is
about 3.5× the `900×620` figure (0.078ms) — close to the ~4× a linear-in-pixel-count shader
cost would predict. At the high reading, the same ratio is 0.461ms / 0.289ms ≈ 1.6×, not
close to 4×. Resolution scaling roughly linearly with pixel count is therefore only
supported by the reading this document reports most often, not by all of them, and that
qualification is now part of the claim rather than left for a reader to notice on their own.
Taking the typical reading: 0.275ms at `1800×1240` is still roughly a quarter of the probe's
1.090ms p50 at what was likely the same pixel count, and that remaining gap stays
**unexplained** — candidates not investigated and not claimed here include a warm
GPU/driver-cache state built up over the probe's own run, differences between the probe's
one combined shader and this capture's two separate pipelines and draw calls, and
measurement conditions on the two occasions (2026-09-08 vs. 2026-09-09) that were never
controlled for.

**Both figures sit far under the 8.33ms budget regardless of which mode is hit.** p50 at
the matched `1800×1240` resolution is about 3.3% of budget at the typical reading and about
5.5% at the high reading; the worst single frame recorded across all twelve runs on record
(1.967ms, run 4's `900×620` max) is about 23.6% of budget. The headroom is real at every
reading measured so far; it is smaller, and less uniform, than the first version of this
document implied by comparing one unmatched number.

**The display line is printed, not asserted, deliberately**: this machine reports 60Hz on
both attached displays, so the 8.33ms figure is a budget being measured against, not a
target this run can claim to have hit or missed at 120fps.

### The project-switch timing

**Not measured — see §2 check 12.** Carried forward as an explicit operator step rather
than fabricated; no second project was registered on this machine before this document was
written, per Task 11's instruction not to register one or invent a number
(`progress.md`, Task 11).

---

## 6. Findings raised during review and deliberately not fixed

Every task in this phase was reviewed, and a reviewer's finding was either fixed before the
task closed or recorded here. This section exists so that "the review was clean" is not read
as "nothing was found" — fourteen findings were judged real and left, each for a stated
reason. None blocks the runbook above.

**Two parked, with the same root cause.** `WindowModel.turnInFlight` is a `Bool`, and the Core
has four exclusive states, so overlapping agent turns are not representable. Two consequences
follow: a second turn's `.result` can flip the Core to idle while the first still runs, and the
`catch` added during the final fix wave clears the flag unconditionally, so a second `send`
that throws clears it for a first turn that is still in flight. Both are reachable — the *Send*
button is never disabled while a turn is running. Both were parked rather than patched, because
the correct fix is a counter and not a third guard on top of a boolean, and because the failure
direction is the gentler one: the Core reads asleep while work happens, rather than thinking
forever with nothing running. Whoever makes `send` re-entrant — the voice sub-phase, 2d — should
close them together.

**Ten deferred as minor**, in rough order of how likely they are to matter:

| Where | Finding |
|---|---|
| `VoidView` / `CoreView` | `fatalError` and `try!` remain the failure mode for a missing Metal device, as distinct from a missing or partial library, which now fails with a named message. A machine with no Metal device cannot run Wakil at all, so there is no degraded mode to fall back to. |
| `Core.metal` | `time` is `Float` seconds since view creation. Its ULP reaches one 120fps frame at roughly 19 hours of continuous uptime, after which the breath and bob quantise. The subtraction happens in `Double` first, so there is no epoch-scale cancellation. |
| `WakilWindow` | Cursor parallax writes `@State` on the window, so every pointer event re-evaluates the whole body — including the non-lazy row `ForEach` and its per-row accessibility label. Unmeasured, and SwiftUI may elide most of it, but the mechanism is real at 500 rows. Moving `cursor` into a child view would confine the invalidation. |
| the pane's grid | All rows build eagerly; `Grid` must measure every cell in a column to size it. Accepted at the current 500-row cap. No check in §2 ever puts 500 rows on screen. |
| `ThoughtThread` | `colour(for:)` compares against `rows.last` rather than `shown.last`. Equivalent today because `shown` is always a suffix. |
| `WakilWindow` | `VoidPalette.forEnvironment` is called twice per body evaluation, once for the void and once for the label. Cheap, and both read the same value, but one shared `let` would stop the two call sites drifting apart. |
| `WakilWindow` | `horizontalSpacing: 16` is a literal in two places — the `Grid` and the width calculation it must agree with. One shared constant would make the agreement a compile-time fact. |
| `WakilApp` | Cool white `#e8ecf6` is a colour literal in five places. `RGB` carries violet, blue and red but no white. |
| `WakilKit` | `RGB` is a broad name for a module-wide public type. No collision today. |
| `WakilWindow` | `.id(model.project)` shares its identified subtree with the geometry reader's size-reporting task, so a project switch re-fires `setCanvasSize` with unchanged values — one redundant, idempotent actor round-trip, hidden behind the transition. |
| `Void.metal` | Grain is ±1.07 LSB at 8 bits — above the textbook dithering minimum, but only provable by eye. Raise the `0.06` constant if check 1 finds banding. |
| `WakilWindow.swift` | The file-header comment still names the scene and the gestures as living in it; both moved out when the file was split. |

**Two things nothing in this phase can pin, and which are therefore conventions rather than
guarantees:**

- **The Swift and Metal uniform structs agree only by inspection.** `VoidUniforms` and
  `CoreUniforms` are each declared twice — in the shader and in the view — and passed as a raw
  `setFragmentBytes` memory copy with no schema. Three separate reviews worked their byte
  offsets out by hand and one ran `MemoryLayout.offset(of:)` to check. Nothing makes it a
  build-time property, and a field reordered on one side alone would render garbage rather than
  fail to compile. A `static_assert` in each `.metal` file, or a shared declaration with a
  checked layout, would fix that.
- **The Core pause depends on a notification arriving.** It pauses and resumes on
  `NSWindow.occlusionState` with no periodic reconciliation, so a missed resume notification
  would leave the sphere frozen with nothing to correct it. This is the documented pattern for
  the purpose and no code path in Wakil produces a stuck pause, but it is worth knowing if the
  Core is ever seen still while the window is plainly visible.
