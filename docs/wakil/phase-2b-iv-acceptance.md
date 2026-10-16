# Phase 2b-iv acceptance — the void as the Core

**Status:** **MET 2026-09-09** — walked in full; the two rows the walk left half-discharged were confirmed by the operator 2026-09-10 (§4) · **Spec:** `docs/superpowers/specs/2026-09-09-void-as-core-design.md`

2b-ii's lesson, recorded in `north-star.md` §8, is that a phase whose value is a human
judgement gets marked "implemented" and then treated as met. Every check below is
numbered for that reason. **"The code is written" and "the phase is done" are different
claims, and only this runbook closes the second one.**

## 0. Why 2b-ii's runbook could not be walked first, and what that costs

The spec's §0 required `phase-2b-ii-acceptance.md` to be walked *in full* before this
sub-phase started, precisely because deleting the sphere is one-way: once it is gone,
nobody can put it back on screen next to the room it was replaced by. **That gate was
never walked.** The plan that executed this sub-phase never turned the sentence into a
task, and execution ran straight through — `a2dafcc` ("2b-iv Task 4: delete the Core
sphere") landed several commits before `phase-2b-ii-acceptance.md` was even touched. Task
7 corrected that document to record the failure rather than let it stand implied; see its
§2, the paragraph beginning "**The Core-specific checks were never walked, and 2b-iv
landed anyway.**"

**What is and is not recoverable.** `cf50d35` ("2b-iv Task 3: carry the occlusion pause
onto the surviving layer") is the last commit containing `app/Shaders/Core.metal` and
`app/Sources/WakilApp/CoreView.swift`. A worktree checked out at that commit still builds
and runs the sphere, so the four Core-specific checks from `phase-2b-ii-acceptance.md` §2
(volume vs. disc, specular as highlight vs. pearl, tick rings as reactive, legibility at
the corner of the eye) remain individually walkable — at the cost of a `git worktree add`
rather than nothing. **What is gone for good is the comparison, not the object:** nobody
will ever see the sphere and the room in the same running window on the same day, so a
side-by-side judgement of variant B against variant A is not available to whoever walks
this runbook, and no check below should be read as providing one. Checks 1 and 2 in §2
judge the room on its own terms, not against the sphere it replaced.

## 1. Headless, before anything else

| | Check | Command | Expected |
|---|---|---|---|
| H1 | The suite is green | `make app-test` | 294 tests pass |
| H2 | Nothing *executable* references the deleted layer | `grep -rn "CoreView\|core_vertex\|core_fragment\|shaderIndex" app/ Makefile \| grep -vE ':[[:space:]]*(//\|///\|#)'` | no output |
| H3 | The palette was never touched by this sub-phase | `git diff ea7d4b5 -- app/Sources/WakilKit/Visual/VoidPalette.swift app/Tests/WakilKitTests/VoidPaletteTests.swift` | no output — spec §2's proof |
| H4 | The stills render, and show a room rather than an object | `make captures`, then open all six PNGs in `.context/2b-iv/` | six PNGs; each shows a soft field with two blurred bleeds and no discrete circular object anywhere; `room-listening.png` is visibly brighter and its bleeds visibly tighter than `room-idle.png` |
| H5 | The sequences render | `make captures-motion` | 536 frames across five sequences (81 idle + 45 listening + 180 thinking + 50 speaking + 180 thinking-production) |

**On H2's grep.** The command as first drafted (without the second `grep -v`) is not
broken — it deliberately still matches. Run it unnarrowed and it finds four lines, all of
them doc comments explaining, in prose, that `shaderIndex` and `CoreView` were deleted:
`CoreState.swift:9`, `ThoughtThread.swift:12`, and two lines in `VoidView.swift` (132,
200). That is this codebase's convention of leaving a historical note at the point where a
thing used to be, and it is intended — it is not a regression to chase. The check that
actually proves nothing *executable* references the deleted layer is the narrowed form
above, which excludes `//`, `///` and `#` comment lines. If somebody runs the unnarrowed
grep first (as a natural first instinct) and sees those four hits, that is expected; only
the narrowed form's output is the pass/fail signal.

**On H3's baseline.** `ea7d4b5` is this branch's merge-base with `origin/main` — the
commit this whole sub-phase's work sits on top of. Diffing against it, rather than against
whatever `origin/main` happens to point to on the day this is run, is what makes the check
reproducible.

**On H4.** A clean file count and a clean build are not the check — `make captures`
succeeding proves the renderer ran, not that it rendered the right thing. Actually open
`room-idle.png`, `room-listening.png`, `room-thinking.png`, `room-speaking.png`,
`void-staging.png` and `void-production.png` and look for two things: first, that none of
the six shows a discrete circular or spherical object anywhere in the frame — every one
should read as a soft field with two blurred bleeds and nothing else; second, that
`room-listening.png` is visibly brighter overall and its bleeds visibly more contained
(tighter) than `room-idle.png` — §3's table gives listening the higher amplitude range and
the only non-1.0 spread factor, so this difference should be plain at a glance, not a close
read. If `room-listening.png` and `room-idle.png` look interchangeable, or if any of the six
shows a bright circular object, the check has failed — record which.

## 2. The judgement, against `make captures-motion`

Assemble each clip with the `ffmpeg` line the tool prints, or open the frame directory in
QuickTime with *File → Open Image Sequence* at the printed rate. Watch each for at least
thirty seconds.

1. **Are the four states distinguishable in motion?** Watch idle and thinking back to
   back. The probe found them "distinguishable, but only just" in stills and argued that
   *rate* would separate them where amplitude did not. This is where that argument is
   tested. If it fails, the fallback is variant C — the room carries ambient state and a
   small sphere is summoned for listening and speaking only — which was the reviewer's
   preference and is recoverable, since `Core.metal` is in git history rather than gone
   (see §0 above for exactly how).
2. **Does a room in motion read as calm, or as a strobe you cannot look away from?** This
   is the risk B carries that A never did. §1 warns that a single bright object works
   *because* everything else stays quiet. There is no sphere left to compare against on a
   running window (§0), so judge the room on its own terms: watchable for the full thirty
   seconds without needing to look away, not "calmer than the sphere was."
3. **Is speaking's bottom-locality enough containment, at its amplitude?** Watch
   `motion-speaking` specifically, at the edge of vision rather than head-on — the question
   is whether it is bearable in the corner of your eye while you read a pane, not whether
   it looks good when you stare at it.
4. **Does production-and-thinking read as both at once?** Watch
   `motion-thinking-production` against `motion-thinking`. Colour is the only difference
   between them by construction, so if hue and motion do not coexist it shows up as the
   *shape* of the bleeds reading differently, not the colour. **Also walk this in
   `staging`, not only `production`, watching `motion-thinking` itself.** Production sets
   both bleeds to the same red, so thinking's antiphase there collapses to a brightness
   trade and the check as written against production alone cannot see the thing
   `design-language.md` §2 now names: with two *different* colours in the room (staging's
   default violet/blue palette), thinking's 12s cycle swings the room's apparent colour
   *balance* — violet-dominant toward blue-dominant and back — even though no colour value
   ever changes. Judge whether that balance swing reads as agent motion or as an
   unintended hue shift; either answer is useful, but only the staging walk can produce it.

**A known non-issue, so it is not chased as a bug.** In idle, listening and speaking, the
pixel difference between frame 0 and the cycle's midpoint frame is *smaller* than the
difference between frame 0 and either quarter point — unlike thinking, where the midpoint
is the most different frame. This is expected, not a defect: those three states drive
amplitude with `0.5 + 0.5 * sin(phase)` (`Void.metal`, per spec §6), and
`sin(0) = sin(π) = 0`, so frame 0 (phase 0) and the midpoint (phase π) land on the same
amplitude — the visual extremes sit at the quarter points instead.

Thinking's bleed-B phase of 0.5 (antiphase) does **not** break this symmetry — work it
through with `CoreMotion.forState(.thinking)`'s amplitude range (0.30–1.00): at phase 0,
`ampA = ampB = mix(0.30, 1.00, 0.5) = 0.65`; at phase π, `sin(π) = 0` and
`sin(π + π) = sin(2π) = 0` too, so both land back on `mix(0.30, 1.00, 0.5) = 0.65` again.
Antiphase shifts *when* each bleed peaks relative to the other, not whether frame 0 and the
midpoint coincide in amplitude — every state shares that coincidence. **Only thinking's
elliptical drift breaks it,** because at the half-cycle the drift vector points to the
opposite side of the ellipse from where it started (`driftAmplitude * (cos(dphase),
sin(dphase))`, and `dphase` at the half-cycle is π out from its start), so the bleed
centres themselves sit in a different place even though their amplitudes match. That is
what makes thinking's midpoint frame read as the most different one, and it is the only
state with drift at all. If a frame-diff script is used to spot-check motion instead of
eyeballing the clip, do not read the other three states' quieter midpoint as a bug — it is
the same sine construction working as designed.

Record the answer to each, and any number you changed in
`app/Sources/WakilKit/Visual/CoreMotion.swift` as a result. **Checks 1–3 are the tuning
pass**; changing a number here and re-running `make captures-motion` is the expected
workflow, not a failure.

## 3. The running window

Run `cd app && swift run WakilApp`.

5. **Is anything ever occluded?** Open several panes, drag them everywhere, maximize one.
   No *luminous* object should ever be drawn in front of a pane — that is structurally
   guaranteed now, since the room is the bottom-most Metal layer and every other view sits
   above it in the SwiftUI tree; confirm it rather than assume it. Separately, the thought
   thread is not luminous and is permitted to overlap (§3 near plane, "may overlap") — check
   at several window sizes that it never overlaps the message field or the status line. Both
   are reserved a fixed band beneath it (`WakilWindow.threadClearanceReserve`); resize the
   window down toward its 1000×860 minimum and confirm the two never touch.
6. **Does the thread read as rising out of the glow?** Send a message. The bleed should
   lift under the thread while the turn runs and fade with it. Judge whether it reads as
   the room giving birth to the thread or as a smudge — the coupling has no precedent in
   the design language and dialling it toward zero degrades cleanly to a plain bottom-edge
   anchor.
7. **Does the maximize dim read as deference or as a fault?** ⌘⏎ on a pane and back. The
   dim is an exponential approach with a 0.15 s time constant
   (`VoidView.Coordinator.ambientEaseTimeConstant`), not a fixed-duration ramp, so judge it
   against "visually settled by roughly 450 ms" — three time constants, ~95% of the way to
   its target — which is what the `.easeOut(duration: 0.45)` it replaced looked like.
   Watching for a hard stop at exactly half a second is watching for the wrong shape.
8. **Does parallax still read as depth?** Move the pointer in a slow arc. The thread
   should drift opposite the room. No stepping.
9. **Does an unfocused window keep breathing?** Click another app while leaving Wakil
   visible. It must. Visibility, not focus, is the bar.
10. **Does an occluded window stop?** This has two halves, and the first is the one a
    silent regression in the occlusion pause would slip past — a window that keeps
    rendering behind another app looks identical to one that doesn't, unless something
    measures it. With Wakil fully covered by another window, open Activity Monitor's
    **GPU** column (or its Energy tab) and confirm Wakil's usage drops to near zero within
    a few seconds and stays there while covered — that is `observeOcclusion` actually
    pausing the render loop, not just a clean-looking screen. Then bring Wakil back and
    confirm nothing is visibly wrong on return (a stale frame, a flash, a stuck animation)
    and that GPU usage resumes.

## 4. Result

**Walked 2026-09-09 by the operator, on a MacBook Air M3 (60 Hz built-in
display), from the `nicosia` worktree at `515434f`.** The sub-phase passes. Every check
below was answered; the ones that were not are named as not-recorded rather than left to
look answered.

**Status: MET**, with one defect found and fixed during the walk (see "What the walk
found" below).

**The outstanding rows were discharged 2026-09-10 by the operator.** Check
10 and H4's GPU timing line are confirmed as passes and marked below as **confirmed
2026-09-10**, kept distinguishable from the rows the walk itself answered. H4 owed a
*number*; that number was never captured off the terminal and is not invented here.

### Headless

| | Result | Note |
|---|---|---|
| H1 | **PASS** | 295 tests, not the 294 this document expected. The number here predates a test added later in the same squashed PR; 295 is correct for the merged tree. Failed 16/295 on the first attempt purely for want of `make build` — `bin/` is per-worktree and 16 tests shell out to `bin/wakil-ctx`. **This runbook should say `make build` first; it does not.** |
| H2 | **PASS** | Narrowed grep empty. **The command as written needs `--exclude-dir=.build`**: on a tree that has been built, stale `.swiftdoc` artifacts match and are reported as `Binary file … matches`, which no `grep -v` can filter and which reads as a finding. |
| H3 | **PASS** | No output. |
| H4 | **PASS** (GPU line confirmed 2026-09-10) | Six PNGs. No discrete circular object in any of them; `room-listening.png` visibly brighter with tighter bleeds than `room-idle.png`, plain at a glance. The GPU timing line was not captured off the terminal on the walk; the operator confirms the cost as within budget 2026-09-10. **No number is recorded here, because none was taken** — the probe's ~1.1 ms of an 8.33 ms budget remains the only measured figure, and it predates this sub-phase. |
| H5 | **PASS** | 536 frames, 81 / 45 / 180 / 50 / 180. |

### Motion (§2, checks 1–4)

| | Result |
|---|---|
| 1 | **PASS** — the four states are distinguishable in motion. The probe's bet that *rate* would separate what amplitude did not holds. Variant C is not needed. |
| 2 | **PASS** — the room in motion reads as calm, watchable for the full thirty seconds. |
| 3 | **PASS** — speaking's bottom-locality is enough containment at the edge of vision. |
| 4 | **PASS** — production-and-thinking read as both at once, and the staging walk of `motion-thinking` confirmed the colour-*balance* swing reads as agent motion rather than as an unintended hue shift. |

**No numbers in `CoreMotion.swift` were changed.** Checks 1–3 are the tuning pass and it
did not need to be taken — the shipped values were judged right on the first walk.

### The running window (§3, checks 5–10)

| | Result |
|---|---|
| 5 | **PASS** — nothing luminous is ever drawn in front of a pane, and the thread never touches the message field or status line down to the 1000×860 minimum. |
| 6 | **PASS** — the thread reads as rising out of the glow, not as a smudge. |
| 7 | **PASS** — the maximize dim reads as deference. |
| 8 | **PASS** — parallax reads as depth, no stepping. |
| 9 | **PASS** — an unfocused but visible window keeps breathing. |
| 10 | **PASS (confirmed 2026-09-10)** — reported as working on the walk and confirmed by the operator 2026-09-10. This is the one check with a half that cannot be judged by eye (a window still rendering behind another looks identical to one that is not); it is discharged on the operator's confirmation rather than on a recorded Activity Monitor reading. |

### What the walk found — one defect, fixed on the day

**Clicking a pane did not focus it.** Reported by the operator mid-walk: with three panes
open, clicking pane 2 and pressing ⌘⏎ maximized pane 1, and no click anywhere on the
canvas ever moved the active pane.

Root cause: `Canvas.paneView` carried only a `DragGesture` (default `minimumDistance` 10)
and the resize handle, so a click that did not move the pointer dispatched nothing. Focus
moved only as a side effect of `open` and `maximize`, or from the rail, ⌘K, or MCP. The
canvas — the third of `design-language.md`'s three ways to reach a pane — was never wired.

This is **not a 2b-iv regression**; it has been latent since 2b-i, and `LayoutStore.focus`
documents the missing caller in its own doc comment ("this is the one call a click on an
unfocused pane dispatches"). It surfaced here because 2b-iv's check 7 is the first item in
any runbook that asks the operator to click one pane and then act on another.

Fixed the same day: `WindowModel.paneClicked(id:)` (guarded, so a click on the already-
focused pane dispatches nothing and does not fill the journal) plus a `TapGesture` and a
focus-on-first-movement in `Canvas.swift`. Three tests, written failing first. Suite
298/298. Confirmed working by the operator on the rebuilt bundle.

### Outstanding

1. **The `make captures` GPU timing line** (H4) — the 8.33 ms budget number. Re-run
   `make captures` and record it.
2. **`phase-2b-ii-acceptance.md` check 12**, the project-switch timing — still not
   measured.
3. **120 fps on ProMotion** — untestable on this machine, as `operator-todo.md` says.
