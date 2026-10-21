# Wakil — Design Language

**Status:** v0, living · **Created:** 2026-09-03 · Conforms to `north-star.md`

Derived from concept-art references (Dribbble "jarvis ui"), not from generic sci-fi
convention. Direction approved 2026-09-03.

---

## 1. Principles

1. **Futurism through absence, not addition.** No window chrome, borders, sidebars, or
   tab bars. What makes it read as future is what has been removed.
   One sidebar is sanctioned, inside a pane: the editor's left column (3b-ii, §11), which is
   shown and hidden only by the operator or the agent — ⌘B, ⌘⇧F, ⌘⇧G, its toggle,
   `editor_tree` — and never by width. (It was the second of two until 3b-iii folded the Git
   pane, and its width-gated column of file names, into the editor: Decision 40.)
   **The background-agent chips are the first always-on chrome outside the context line**
   *(2026-10-17, background agents 4 of 4; Decision 41)*. One chip per agent in another
   place, top right of the window, reading `<org> · <project> · <environment>`; a click goes
   there. They are justified because they exist only while there is work elsewhere: no agents
   elsewhere means no chips, and the window at rest is unchanged. At most two are drawn in
   full; the rest fold into one "+N more" chip carrying the strongest hidden state, whose
   click opens a list. Only the 6pt dot carries a hue, from §5's table; the capsule is a
   hairline over a near-black fill and nothing glows.

   | State | Dot | Text suffix | Wins over |
   |---|---|---|---|
   | Working — a turn in flight | violet `#7c5cff`, breathing on the Core's thinking rhythm (motionless under Reduce Motion) | none | done |
   | Waiting — a proposal parked for the operator | amber `#e8b45a` | ` — waiting` | everything |
   | Done — finished off screen, not yet seen | green `#8be0c8` | ` — done` | — |
   | Failed — the session failed off screen, not yet seen | red `#e85c5c` | ` — failed` | working, done |

   A production place's environment segment is production red whatever the dot (Invariant 8),
   and is never truncated: only the org · project part is. Visiting the place clears *done*
   and *failed*. The view is `app/Sources/WakilApp/AgentChips.swift`; the states are
   `AgentChip` (`WakilKit`).
2. **Light is information.** Luminance is never decorative. If something glows, it is
   alive, active, or asking for attention.
3. **One luminous surface.** The room is the only genuinely luminous thing — and it is
   behind everything, so nothing luminous is ever in front of what you are reading. Nothing
   else glows; the near plane may still hold non-luminous content in front of it (§3's
   thought thread "may overlap"). *(Rewritten 2026-09-09 by 2b-iv. This principle used to
   read "One bright object.
   The Core is the only genuinely luminous thing on screen." Its goal — a living interface
   that stays calm — survives; its mechanism does not, because there is no object any more.
   The goal is served better, not worse: a bright object had to be placed somewhere, and on
   2b-ii's first hands-on run it was placed on top of an open pane.)*
4. **Two registers.** *Chrome* may be atmospheric. *Data* must be ruthlessly legible.
   Never translucent, never glowing, never low-contrast behind a data surface.
5. **Calm over dense.** Information appears when relevant, not permanently.

## 2. The void

Near-black field (`#030408`–`#070812`) with two faint radial bleeds: violet from below,
cool blue from upper right. Fine grain overlay at ~14% to prevent gradient banding and
add material. Nothing fills the frame — content floats within it.

Panels are **slabs**: rounded, near-opaque dark surfaces, defined by drop shadow and a
half-pixel luminous edge rather than a border. No panel has a visible outline.

**Since 2026-09-09 the void is also §4's Core.** Its two bleeds carry Wakil's four states
in their amplitude, spread and drift. **No state selects or alters a colour value** — the
environment alone owns which two colours are in the room, and `VoidPalette` is never
touched by state (proven negatively: it is not modified by this sub-phase at all, and its
tests pass untouched). That is narrower than "the two channels never mix" reads: thinking
modulates its two bleeds' amplitudes independently and out of phase, by design (§4, "the
two bleeds trade dominance"), so the room's apparent colour *balance* — which of the two
existing colours currently reads stronger — does move with state even though no colour
value does. With the default palette this is a violet-dominant ↔ blue-dominant swing over
thinking's cycle; in production, where both bleeds are the same red, the same mechanism
collapses to a brightness trade instead, because there is only one colour to swing between.

## 3. Depth model

Three planes. Depth is expressed through scale, opacity, and blur together — never one
alone.

| Plane | Treatment | Holds |
|-------|-----------|-------|
| **Far** | `scale(.94)`, `opacity .30`, `blur(1.4px)` | Ambient context: sessions, roots, status |
| **Mid** | Full scale, opaque, full contrast, crisp | The active data surface |
| **Near** | Full scale, brightest, may overlap | The thought thread, current utterance |

Planes parallax against cursor and window motion. Far-plane content is never
interactive without first being promoted.

**The environment badge is exempt from opacity and blur, 2026-09-14.** It is the one
piece of far-plane content that exists to be *read* at the moment it matters, and "never
one alone" cost it exactly that. Riding the far plane whole, the badge composited to
**1.47:1 in production and 2.35:1 out of it** against WCAG's 4.5:1 body-text floor — and
inverted, because `#e85c5c` carries less luminance than `#e8ecf6`, so one dimming
multiplier made the state Invariant 8 calls *unmissable* the fainter of the two. It now
draws at full opacity with no blur and keeps the far plane's scale and parallax, so it
still sits at the rail's distance and moves with it; only the two channels that decide
whether it can be resolved are lifted. The treatment lives in `EnvironmentBadge`
(`WakilKit/Visual/`), and `EnvironmentBadgeTests` asserts both that it clears the floor
and that the far plane's own treatment would fail it, so the exemption cannot be quietly
undone.

**The exemption widened to the whole context line, 2026-09-20.** This paragraph
used to end "Nothing else on the far plane is exempt: nothing else on it is
being read." The second clause was false about the line the badge sits on. An
organisation and a project are read — they are how the operator knows which
credentials and which roots are in play — and riding the far plane whole they
composite to roughly **2.4:1**, against the 4.5:1 floor `PRODUCT.md` binds for
text that is read. The badge's exemption had rescued one third of that line and
left the rest failing, which is the same defect stated one element narrower.

So the treatment governs the line: the far plane's **scale and parallax kept**,
its **opacity and blur lifted**, and the quieting done by hierarchy instead —
19pt organisation, 11pt monospace project, a chip. `ContextLine` (`WakilApp`)
draws it, and it is the first surface in the app to spend this section's own
promotion rule: ambient at rest, the segmented control under the pointer.

**The rail takes this section's other remedy, 2026-09-21.** This paragraph used
to end "the rail is **not** covered by this and still carries the plane whole,
which is what [#138](https://github.com/yehia-khalil/rafiq/issues/138) records:
it is interactive in that state, which §3 forbids without promotion first." It
is fixed, and not by a second exemption. The badge and the line are exempt
*permanently* because Invariant 8 gives them no moment at which they may be
unreadable; the rail has such moments — most of them — because at rest it is
genuinely ambient furniture and nothing on it is being read. So the rail stays
on the far plane and is **promoted to the mid plane whole under the pointer**,
which is §10's own "low opacity *until relevant*" finally made to mean
something: scale, opacity and blur released together over §7's 400–600ms
ease-out. That is also what makes the click legitimate — a click is always
preceded by the pointer arriving, so a row can never be clicked from the far
plane. `RailTreatment` (`WakilKit/Visual/`) holds the numbers and
`RailTreatmentTests` asserts both ends of them: **2.35:1 ambient against
16.9:1 promoted** for a pane name, and **5.4:1 for the kind beside it** —
which is stepped down by opacity, §5's way of quieting text, but at 0.55
rather than the 0.46 `Rail.dc.html` drew, because 0.46 composites to 4.09:1
*even promoted*. The floor is measured on what a reader gets, so it applies to
everything on the row that is read, not only to the brightest thing on it.

Two of §10's other promises land with it. A working pane's green tick replaces
the word "working" — a glyph at 0.30 behind a 1.4px blur is the least
peripherally legible mark available, and a hue shift survives the far plane
because noticing it requires resolving nothing. And **promotion outranks the
maximize fade**: while a pane is maximized every other pane is hidden behind it,
so the rail is the only way back to them, and a rail held at 0.12 under the
pointer would be interactive far-plane content again at 1.28:1 — half the
2.35:1 this section already forbids. `Rail.dc.html` draws the deferred state
with no pointer on it and so does not rule on this; it was settled here.

**The Core left this plane on 2026-09-09** and the thought thread is what keeps it. Under
§4's rewrite the room is behind everything, so the near plane holds only what rises out of
it.

## 4. The Core

Wakil's presence. **Not an object: the room.** The void of §2 carries the four states, and
nothing luminous is drawn in front of the panes at all — structurally guaranteed, since the
room is the bottom-most layer. The thought thread (§3, §9) does sit in front of the canvas,
but it is not the room and it does not glow.

**Hue belongs to the environment. Motion and intensity belong to agent state.** §5 already
spends the void's colour on environment — violet normally, red on production — so the two
channels are split rather than shared: no state selects or alters a colour value, ever. A
red room that breathes faster is production-and-thinking, unambiguously. (§2 narrows this
further: with two *different* colours in the room, as the default palette has, thinking's
antiphase can still swing which of them currently reads stronger — a balance change, not a
value change. Production's single-colour palette has nothing to swing between, so this
does not apply there.)

| State | Behaviour |
|-------|-----------|
| **Idle** | The lowest ceiling of the four — its amplitude never rises as high as the other three's — on a 5.4s breath. Present but asleep. |
| **Listening** | Brightest, and the bleeds tighten; breath quickens to 1.5s. |
| **Thinking** | The two bleeds trade dominance on a 12s turnover and drift slowly — the room turning something over. |
| **Speaking** | The lower bleed alone pulses on a 0.42s speech cadence. The upper field holds still. |

Four states, one room, **no text labels**. Peripheral legibility is the goal: knowing what
Wakil is doing from the corner of the eye.

**Speaking is contained by geometry, not by a small number.** A 0.42s pulse across a whole
peripheral field is precisely what §1's first principle warns against, so it is confined to
the lower bleed — the same bottom edge §9's thread and §12's live transcription attach to.
The room speaks from where the voice is coming from. *(This clause read "§12's waveform"
until 2026-09-15; the geometry it describes is unchanged — only one of the two things
attached there is gone.)*

**There are no ornaments.** The tick rings — previously "the single permitted ornament" —
went with the sphere. No reticles, brackets, scan lines, or grid overlays anywhere in the
application, and now no rings either.

**Rewritten 2026-09-09, not amended** (charter open question 11, now closed). This section
described an iridescent sphere with a specular highlight and rotating tick rings. 2b-ii's
first hands-on run put that sphere on top of an open pane — because this section stated the
goal and never turned it into a position or a size — and the operator asked whether the void
should be the Core instead. Probed the same day (`void-as-core-probe.md`, twelve renders),
specified as
`docs/superpowers/specs/2026-09-09-void-as-core-design.md`. The occlusion problem is not
solved by the rewrite; it stops being possible.

## 5. Colour

**Luminance is violet-indigo** (`#7c5cff` primary, through `#4fb9e8` in the void's blue
bleed and `#8be0c8` in the reserved green below). Chosen over cyan deliberately: cyan is
the dated Tron/Jarvis default, violet reads contemporary, and it leaves the semantic hues
free. *(Amended 2026-09-09 by 2b-iv: this used to say "in the Core's iridescence" — the
sphere's four-hue gradient is gone with the sphere.)*

**Reserved semantics — never decorative, anywhere:**

| Hue | Meaning |
|-----|---------|
| Green `#8be0c8` | Local / staging · healthy · completed |
| Amber `#e8b45a` | Pending · caution |
| Red `#e85c5c` | **Production** · destructive · failed |

**Red's value was assigned 2026-09-09**, during 2b-ii's implementation — this table named
the hue and never gave it a number. `#e85c5c` sits at the same weight as the amber and
green beside it; a pure `#ff0000` on a near-black field reads as a fault in the display
rather than as a warning.

Text is cool white (`#e8ecf6`) stepped down by opacity, never by a different hue.

The background-agent chips (§1, 2026-10-17) use these hues in these meanings — amber
waiting, green completed, red failed — and luminance violet for an agent at work.

**The terminal pane's carve-out, added 2026-09-18 by 2c-iii.** Everything
above governs Wakil's OWN voice — its chrome, its labels, its status hues.
A shell's stdout is not Wakil's voice; it is quoted material, and until
this carve-out the pane threw every SGR colour a program emitted away,
rendering it in one flat cool white regardless of what the program said.
That is its own kind of dishonesty: `structuredOutput`'s own doc comment
(`TerminalPaneSupport.swift`) already refuses to guess at output a build
has never seen, on the grounds that guessing is "how a terminal starts
telling the operator a program printed something it did not" — and
rendering everything in one hue is guessing in the opposite direction,
telling the operator a program printed nothing distinguishable when it
did.

The rule this carve-out states: **quoted program output carries the
program's own colour, but mapped onto THIS table's own values** — never
raw web colour. A program's `SGR 31` (red) and Wakil's own reserved red
are the same `#e85c5c`, so the two cannot compete for the hue; a
program's green is the same `#8be0c8` "healthy" already means elsewhere
in this app, on the reasoning that agreement reads calmer than two reds
that almost match. The anchors:

| ANSI | Maps to | Note |
|------|---------|------|
| 1 / 9 (red / bright red) | `#e85c5c` | §5's own red |
| 2 / 10 (green / bright green) | `#8be0c8` | §5's own green |
| 3 / 11 (yellow / bright yellow) | `#e8b45a` | §5's own amber |
| 4 / 12 (blue / bright blue) | `#4fb9e8` | §2's void-blue bleed |
| 5 / 13 (magenta / bright magenta) | `#7c5cff` | §5's luminance violet |
| 6 / 14 (cyan / bright cyan) | blend of blue and green, 2:1 toward blue | no anchor of its own; leaning blue keeps it from reading as a fourth status colour beside the real green |
| 0 / 8 (black / bright black) | the pane's own text colour, dimmed | never a hue — a near-black glyph on §2's near-black field is the exact illegibility this whole table exists to avoid, so black rides THIS section's own dimming rule instead of inventing a colour |
| 7 / default (white) | the pane's own text colour, unchanged | |

Bright variants are the same hue lifted toward white, never a different
hue. 256-colour and 24-bit truecolour are pulled toward this table's own
saturation and luminance band (a ceiling and a floor, sized off the five
anchors' own HSL) rather than rendered raw — a saturated `#00ff00` reads
as a display fault against a near-black field for the same reason a raw
`#ff0000` does, and pulling it in is the truecolour analogue of red
being `#e85c5c` instead of `#ff0000` two paragraphs up.

**What this carve-out does not reach.** Wakil's own chrome — status
chips, the environment badge, every label this app draws itself — stays
bound by this section exactly as written: reserved semantics, never
decorative, anywhere. The carve-out widens who may use colour (a quoted
program, alongside Wakil), not what the reserved hues mean once used.
Implementation: `TerminalAnsiColor.swift` (`WakilKit`), asserted in
`TerminalAnsiColorTests.swift`.

**A log in the editor (3b-vii).** Red marks a log's error levels and amber its warnings — the same
meanings, applied to text Wakil draws — while timestamps and stack traces are dimmed, so each
entry's first line carries the eye.

## 6. Typography

- **Micro-labels:** uppercase, `letter-spacing: .16–.22em`, 8–9.5px, low opacity. These
  carry most of the futuristic feel.
- **Body and data:** neutral system sans at normal tracking.
- **Numerics and identifiers:** monospace with tabular figures, always.
- **Explicitly rejected:** Eurostile and its lineage — reads 1979, not future.

## 7. Motion

Weightless. Slow, eased, never snappy. Nothing appears instantly; nothing bounces.

| Motion | Duration |
|--------|----------|
| Room breath | 5.4s idle · 1.5s listening |
| Room turnover | 12s thinking |
| Room speech pulse | 0.42s speaking, lower bleed only |
| Plane transition | 400–600ms, ease-out |
| Value materialising | 250ms fade + 4px rise |

**The room's frame rate follows its own cadence.** Each state is drawn at the rate its
period needs and no faster — at least 25 frames per cycle, never above 120 — so an idle
window costs a fraction of a speaking one. *(The Core bob, 6.5s, is gone: it was the
sphere's vertical drift and there is no sphere.)*

## 8. Data surfaces

The one place the aesthetic yields to utility. Opaque slab, full-contrast text, no
translucency, no glow. Row separation by whitespace, not rules. Status as chips, explicit
`null` rendering, column type annotations, hover-revealed row actions, and a footer
carrying row count, timing, and read-only state.

**Density toggle** (⌘⇧D), airy 40px default, dense 23px on demand, remembered per pane.
Airy is chosen for beauty and for the secondary line it affords; dense exists because
scanning a large result set is the pane's real job.

The only luminous element permitted inside a data surface is the **anchor** row's left
edge. **Amended 2026-09-12** by 2c-i, which needed a word for "the selected row the
selection is anchored on" once selection stopped being a single row: the anchor is a
(row, column) pair, because §11 has the API client pane consuming *values* from other
panes and a value lives in a cell. Other selected rows get a **lifted background** —
opaque, non-luminous — so that this rule stays literally true rather than being
contradicted by the code.

**Sort is intent, not action, and the footer says which it got.** A click on a header of
a 500-row result truncated from 50,000 that sorts client-side orders the rows on screen
and *looks* like it ordered the table — the same class of dishonesty `truncated` exists
to prevent, one layer up. A pane that can re-query re-queries; one that cannot sorts
what it holds and the footer reads "sorted by X within the N returned". **Amended
2026-09-12:** a pane that re-queries may still owe that admission. An outer
`ORDER BY` cannot see past an inner bound, so a statement the operator
capped at 5,000 rows, capped again at 500, and then re-queried with a
pushed sort is a sort over 5,000 rows showing 500 of them — still a subset.
The rule that covers both causes without telling them apart: **a sorted
result that is still truncated admits it.**

**A `NULL` is drawn as a dimmed `NULL`**, never as an empty cell — an empty string is
also an empty cell, and until 2c-i the two were indistinguishable on screen.

**A paged result says which rows are on screen, and no total.** The footer
reads `rows 501–1,000 · more remain`, and on the last page `rows
1,001–1,006 · end`. It reports no total, deliberately: a total needs a
second full scan of the same statement, which on a large table is the
expensive half of the operation and which can honestly disagree with the
page beside it because the two ran at different instants. "More remain" is
what the engine tells us for free. **Added 2026-09-12** by 2c-ii.

**Some reads cannot be paged, and say so rather than offering the
control.** An `EXPLAIN` and a `SHOW` are reads the read-only gate permits
and neither survives the subquery paging wraps a statement in — measured
on SQLite and MySQL in `phase-2c-ii-probe.md` §2. The page controls are
absent on such a result and the footer says "this result cannot be paged",
because a control that returns a syntax error is worse than no control.

**Status chips draw only on a declared type.** A chip is drawn only on a column whose
declared type is boolean, never inferred from the cell's text — a `VARCHAR` holding the
string "true" gets no chip, and neither does a MySQL `TINYINT` column, because a
`TINYINT` is also how MySQL spells a small integer and a missing chip is the correct way
to fail that ambiguity.

## 9. Visible work

Agent progress renders as a **thought thread** rising out of the bottom edge's glow —
where §2's violet bleed rises, and where §4's Core lives since 2026-09-09. The glow
answers it: the bleed lifts locally beneath the thread while work is in flight, and fades
with it. Completed steps fade to dim green, the live step pulses. This replaces spinners
and progress bars entirely. Watching a plan execute is the honest UI for tool-chaining.

**Amended 2026-09-09, during the 2b-ii design.** This section previously ended its first
sentence with *"upcoming steps sit near-invisible"*. It is removed because it cannot be
drawn honestly: harness events arrive one at a time and nothing in the stream announces
what the agent intends to do next, so an upcoming step could only be invented — a promise
the interface has no standing to make, and wrong every time the agent changes its mind
mid-turn. Asking the agent to announce a plan before acting is a protocol rather than a
rendering; it is recorded as an open question in the 2b-ii spec rather than closed here.

**Also settled there:** the thread draws only events that describe work — assistant text,
tool calls, tool results, turn end. The probe found 10 of 13 lines in a real turn to be
`stream_event` / `rate_limit_event` / `session_state_changed` traffic, and a thread that
holds six lines cannot bury four meaningful ones under eleven meaningless ones without
defeating the claim this section makes.

*Amended 2026-10-07 (2d-ii): the thread overlaps the panes, which now take the full height.
It is four compact rows, resting at 32% opacity and rising to full on hover; a click
expands a row in place (an open row toggles closed from its label), and the thread folds
1.2 s after the pointer leaves unless a mouse button is held. Each sent turn is a `you`
row. The bottom edge is one flow: the thread, then status and notes, then the composer bar
beside the account indicator.*

## 10. Layout model

Approved 2026-09-03. Resolves the tension between layout D (tabs + columns) and the void
(no chrome): **D is the information architecture, the void is the presentation.**

**Free-floating canvas with magnetic edges.** Panes float anywhere the user drags them —
not a fixed tiling grid.

- **Magnetism.** Dragging a pane within a few pixels of another pane's edge (or the void
  edge) shows a violet snap-line; releasing locks it flush and matches height.
- **Shared borders.** Once two panes are snapped, their shared edge is coordinated —
  dragging it resizes *both*, so snapped panes never gap or overlap. Pulling a pane away
  unlinks it back to free-floating. (macOS-style snapping, but snapped edges stay
  coordinated like a tiling manager.)
- **Maximize** (⌘⏎) fills the void with the focused pane; the rail and Core fade back.
  ⌘⏎ again restores.
- **The Landing** — what the canvas draws before this session has done anything:
  the organisation's sessions to continue, and the pane kinds to open. **Gated on
  the session, not on the pane count** (settled 2026-09-20). It goes the moment
  work starts — a resumed session, a pane, or a spoken turn — and does *not*
  return when the last pane closes, because a pane-less window mid-session is not
  empty: §4's room carries the four states and §9's thread is at the bottom edge.
  Drawing a session list over that would offer to start work on top of work in
  flight. Owed: nothing mints a fresh session in-window, so there is no way back
  to it without relaunching.
- **The rail** — a chrome-less floating list of open panes (glyph + label + shortcut, low
  opacity until relevant). It answers "what is open"; the active pane gets a luminous left
  tick, a working pane glows green in the periphery. It exists because floating panes can
  hide behind each other. **"Until relevant" means under the pointer** (2026-09-21, #138):
  the rail promotes to the mid plane on hover, and both ticks are the same 2pt mark in two
  hues — `#9e82ff` active, §5's green `#8be0c8` working, which wins on a pane that is
  both. See §3.

**One plane, two front doors.** ⌘P and ⌘K open the same plane (§4.3's geometry, no sheet,
no buttons); they differ in what they list and what Return does. Pressing the other chord
while it is open switches mode rather than stacking a second plane, and a leading `>` in ⌘P
is the same switch, undone by deleting it. `Palette.dc.html` is the artboard.

- **⌘P — open or switch to.** Ordered by group, none drawn as a header and the right-hand label being the row's kind: open panes, new panes (built
  from `Pane.kinds`), **resources** (database tables, API entries and changed files — each
  has a pane to land in), the current organisation's projects, sessions, providers.
- **⌘K — a curated catalog of operator verbs.** Each label is pinned to one registered
  action, the focused pane's commands first, then global; what cannot run now is hidden,
  not disabled. Raw registry actions never appear. A command ending in `…` pushes an
  **input step** into the same plane — a choice among what exists (environments,
  projects, providers, pane kinds) or text only where the value is open (a cURL command).
  The header names the step; Esc pops one step, then closes. Production is red wherever it
  is a choice.
- **Search is words, not syntax:** every word must hit the title, subtitle or kind label,
  in any order (`catalog api`, `catalog db`). The only special character is `>`.
- **After a run** the plane closes and focus goes to the pane acted on. A failure stays
  open with the whole error and the input intact. The operator's own environment switch is
  not confirmed: the gate prices the agent's switch, not this one.

Three ways to reach anything, all equivalent: the rail / a keystroke / ⌘P or ⌘K / voice.

## 11. Panes

Every pane is dual-driven (Invariant 2) except the editor's text surface. Some pane
*types* hold multiple tabs internally; the app itself has no tab bar.

| Pane | Multi-tab? | Notes |
|------|-----------|-------|
| **Editor** | Yes (files, ⌘T) | Native, Monaco-based — see below. The one partial exception to dual-drive. ⌘T opens a scratch tab; files open from ⌘P (Resources) or the left column (⌘B, 3b-ii). Unsaved edits ask before anything drops them. A file in a repository shows gutter marks against the index — a green bar for added lines, amber for changed, a muted triangle where lines were deleted — and a click on one opens the peek: the change's old lines over its new, with ↑ ↓, Revert (an undoable buffer edit) and ×. The Files tree shows a changed file's status letter. |
| **Git** | No | Folded into the editor (3b-iii, Decision 40): the editor's left column's **Changes** view (⌘⇧G) — one header per root, Staged / Changes / Untracked, status letters in §5's tones — opens read-only inline diff tabs in the editor. No pane of its own. |
| **Browser** | Yes (⌘T) | Embedded web view; agent can read the active tab. |
| **Terminal** | No | One shell, on one PTY, opened **at a path** — not per-root. A second shell is a second pane, exactly as for the database pane below; §10's canvas is what running two of them is for. **Corrected 2026-09-16** — this row read *"Yes (sessions) · Per-root shells"*, and both halves were wrong. `Terminal.dc.html:127` had forbidden a tab bar all along (§1's first principle names tab bars in what has been removed), and the operator ruled the roots out on the same day: sub-phase 2c-iii. |
| **Database** | No | The canonical data surface (§8), above it the pane's own query — the database it runs against and the statement, editable, run with Return. A second query is a second pane; §10's canvas is what comparing two of them is for. |
| **API client** | No | Request/response; consumes values from other panes. |
| **PM** | No | Kanban over the active project's issues, scoped to the active `(org, project)`. Columns are the Jira board's own; a card is §8's row drawn small, on §8's surface rather than a second grid. Dual-driven; the one write it carries is a status transition (Invariant 6, amended 2026-09-14). **Added 2026-09-14** — this row used to read *"PM · Recall — surfaced through the agent, not (yet) standalone panes"*, and the parenthetical *(yet)* is what this change spends. Sub-phase 2c-vi. |
| Recall | — | Surfaced through the agent, not a standalone pane. Unchanged. |

**The database pane has no schema browser and no sidebar,** and §1 is why.
A table list is one row per table and a column list is one row per column
— both are result sets, so both draw on §8's own surface, in a database
pane, reached by the same actions as any query. Hovering a row of a table
list reveals the one row action §8 has always permitted and never had: it
opens that table in a new pane.

**The editor is native, not embedded VS Code.** Decision recorded in `north-star.md`
(Decision 17 updated). Rationale: a native Monaco-based editor can be *dual-driven* — Wakil
operates it as actions ("rename to `bookingId`", "open the confirm method") like every
other pane — which embedded VS Code (a black box) cannot. Cost: no extension marketplace,
no full debugger.

- **The left column** (3b-ii) — a column inside the pane, §1's one sanctioned sidebar,
  with three views: **Files** (⌘B), **Search** (⌘⇧F) and **Changes** (⌘⇧G, 3b-iii). Nothing hides it at any width; ⌘B,
  ⌘⇧F, ⌘⇧G, its toggle or the agent show and hide it. Its edge drags from 160 pt to half the
  pane, and each pane keeps its own column — shown, view, width and open folders — across
  a relaunch; a new pane starts as the last one was left. Only the operator's own keys and
  buttons move the keyboard into it; the agent's actions never do.
  - **Files** — the project's roots as top-level folders (VS Code multi-root style), with a
    root that holds repositories showing each as a node. Gitignored files are dimmed, not
    hidden; heavy folders (`node_modules`, `vendor`, …) are one dimmed row, loaded when
    opened. The tree follows the disk live and keeps open folders open. 3b-iv (Decision 41)
    makes it writable: each root row shows a **+** on hover or selection, a menu of New File and
    New Folder, and a new item, or a rename (F2), is an inline name field in the row's own
    indent, monospaced 11 pt, with a refusal shown whole beneath it. A reveal button in its
    header (and ⌘K's *Reveal Active File in Tree*) opens the folders above the active file and
    selects its row; the tree never follows the active file by itself.
    3b-iv-b gives file rows, Changes rows and editor tabs a single-colour Seti glyph for the
    file's language, in the name's own colour; folders keep their chevron.
  - **The preview tab** — a single click opens a file in one italic tab that the next
    single click replaces; a double-click or an edit keeps it. Tabs move by dragging along
    their own strip (a violet line marks the drop) and close on a middle-click, as ⌘W closes
    them.
  - **Search** — across the project's files, literal or regex, with case and whole-word
    switches; it runs on a pause in typing, groups results by root and file (groups
    collapse), marks each match, and offers Cancel while it runs. A result opens with its
    match selected; the find bar stays shut (⌘F opens it). An invalid pattern is shown whole and nothing
    runs; a change on disk offers *Re-run*.
  - **Replace** (3b-ii-b) — a ▸ beside the query opens a Replace field; each result line then shows
    its match struck through and the replacement in violet. *Replace All* and a file group's *Replace
    in this file* ask nothing (Decision 39): a file open in a tab is edited in its buffer, the rest are
    written, and one line — *Replaced 37 in 12 files · Undo replace* — offers the undo, which leaves
    any file changed since.
  - **Changes** (3b-iii, Decision 40) — one block per root, a hairline between them: a header
    (`api  main ↑2 ↓1`, the branch dimmed; a header collapses its root), and only while the root has
    changes its message box and Commit, then Staged / Changes / Untracked, each collapsible. A clean
    root is one line (`web  main · clean`); a root that is not a git repository is not drawn. Rows read
    the file name, its folder dimmed, and the status letter in §5's tones (never red) at the far right. A click or Return
    opens a read-only inline diff tab under the preview-tab rule; ⌘⏎ in a diff opens the file at that
    line. It follows git live, with no refresh control.
  - **Find in file** — Monaco's own find and replace bar (⌘F, ⌥⌘F) in Wakil's colours,
    closed with Esc; the agent opens it with `editor_find`.
  ⌘P stays the faster path to a file whose name you know, and lists ignored files dimmed,
  ranked last.
- **Compare** (3b-i) — when a file changes on disk under unsaved edits, *Compare* draws the
  buffer against the disk's text as a diff **inside the pane**, closed with Esc. It is not a
  tab: the spec had it as one, and the build keeps the tab strip to files and scratch buffers.
- **Autocomplete, three tiers:**
  1. Basic — Monaco built-in (word/snippet), free, v1.
  2. Type-aware — per-language LSP (Intelephense, tsserver, …); real per-language work
     Wakil owns; added on demand starting with PHP/Laravel and TS.
  3. AI ghost-text — runs on the org's quick-tasks provider: its Claude account by default,
     a local model when the operator adds one (Decision 42). Context: the file and the
     active environment's schema. Wakil's edge over generic Copilot.
- **Change indicators** in the editor gutter and the peek shipped in 3b-iii (Decision 40); see
  the Editor row above. A file past 10,000 lines shows no marks.

## 12. Voice

Approved 2026-09-03. Voice is a transport, not a command language (Invariant 10):
speech-to-text produces the exact string the ⌘K box would send, through one code path.

- **Push-to-talk** (hold ⌥), no wake word. **The Core's four states *are* the voice
  indicator** — literally, since 2026-09-09: there is no separate object and no separate
  mic UI, the room itself listens and speaks. Listening: the room brightens and its bleeds
  tighten; the live transcription appears at the bottom edge, in the glow, beside §9's
  thread; release to land it in the composer.

  ***Release lands, it does not send. Amended 2026-10-07*** *— 2d-ii, on the operator's
  instruction. An allow-priced write can run from a mistranscribed spoken turn (2d-i,
  `2d-stt-probe.md` §10), so releasing ⌥ puts the transcript in the composer unsent, at the
  caret, and Return sends it. The silence case is answered in words in the composer bar —
  "Hearing nothing from <device>" after 1.5 s with no sound — never a meter. Spec:
  `docs/superpowers/specs/2026-10-07-2d-ii-voice-capture-design.md`.*

  ***There is no waveform. Amended 2026-09-15*** *— on the operator's instruction, at the
  2d artboards, and this bullet is where the contradiction was: it asserted "no separate
  object and no separate mic UI" in one sentence and put a bar meter on screen two clauses
  later. A waveform is a separate mic UI. It also spends a second channel restating, worse,
  what §4's four states already carry — the room brightens and tightens when it is
  listening, and a meter beside it is the same fact drawn twice.*

  *Why the transcription is not struck with it: it is not an indicator. The room can say
  that Wakil is listening; it cannot say **what it heard**, and on-device STT is exactly
  the component that will get that wrong. Cutting the transcription would remove the only
  evidence the operator has before release-to-send commits the string. §1's "light is
  information" cuts the same way — the waveform's amplitude carries no information the
  operator acts on, and the transcription's text is nothing but.*

  *What this costs, recorded honestly: **the silence case.** A dead microphone, a muted
  input or an STT engine that has not started all look identical to a room that is
  listening and a transcription that has not begun — the waveform would have moved. 2d
  owns answering that, and the answer must not be a meter; the transcription's own
  behaviour (a cursor that never advances) is the candidate, and it is untested. Recorded
  as 2d's to solve rather than waved away.*
- **On-device STT** (Apple / Whisper) — audio never leaves the machine. Engine is
  per-organization (charter Decision 18).
- **You watch it work.** A spoken command's plan renders as the same thought thread
  (§9) that typed commands use.
- **Results land in panes, not the voice bubble.** Wakil speaks a one-line confirmation;
  the substance (rows, response, diff) appears in the relevant pane.
- **Write gate (Invariant 7).** In a chain, read steps run automatically; the chain
  *stops* at any mutation and shows a typed-confirmation gate. The user types `confirm` —
  saying "yes" does nothing. Voice may propose a write, never execute one.
- **Environment governs the gate.** Staging: confirm and proceed. Production: the gate
  turns red and **costs a typed confirmation**; it is not a refusal. The environment badge
  is always visible so the target world is known before speaking. **Corrected 2026-09-20**
  by 2c-iv's map ([#110](https://github.com/yehia-khalil/rafiq/issues/110)) — this read
  *"Production: blocked outright in v1 (read-only, no override)"*, written when no write
  had earned in at all. Three since have, each declaring its own price (Invariant 6,
  Decision 25), and [#107](https://github.com/yehia-khalil/rafiq/issues/107) ruled the
  HTTP send's to be `(production: .gate, otherwise: .allow)`. #107 corrected `phase-log.md`
  and handed `ApiClient.dc.html` to the redraw; it did not reach this line, which is the
  one titled for the claim.
- **Hands-free mode: deferred.** A wake-word/toggle mode was considered and declined for
  v1 — it collides with the typed write gate. If added later, hands-free permits reads
  only.

## 13. Performance budget

Approved 2026-09-03. Snappiness is a requirement, not a hope — and it is what settles the
native-Swift decision (charter open question 1, now closed: **Swift/SwiftUI + Metal**, not
Tauri). Native is *necessary but not sufficient*: it removes the Electron/web-runtime
ceiling on the always-animating shell, but the felt speed then depends on engineering the
async boundaries below.

**Targets:**
- **120fps shell** on ProMotion — pane motion, magnetic drag, plane transitions, the Core.
- **Project/org switch < ~400ms to interactive**, and the latency is *covered by motion* —
  the outgoing pane recedes while the incoming rises (~500ms), hiding the reconnect. State
  is kept warm; panes are never torn down and rebuilt on switch.
- **The room is a Metal/GPU shader**, never CPU — it animates continuously, so CPU would
  jitter and drain battery. **One layer, not two** (2026-09-09): 2b-ii ran a paused void
  behind the panes and a continuous Core in front of them, and deleting the Core left one
  cadence on one layer. An idle window went from a continuous 60fps sphere to a 15fps room
  and got *cheaper*, not dearer.
- **Web-view pooling.** Editor (Monaco), browser, and any embedded view are separate web
  content processes with real startup/memory cost. Hidden panes suspend; instances are
  reused, not recreated. Cap concurrent live web contexts.
- **Data-grid virtualization.** Grids render only visible rows. **Amended 2026-09-12**
  — this bullet used to end "on very dense tabular data, prefer AppKit over SwiftUI for
  the grid specifically". That advice predated the two measurements that contradict it,
  and as written it could not be followed without breaking §8: 2b-ii measured that
  `NSTableView` floors its row height at the platform default of 24pt, putting §8's 23pt
  dense row out of reach inside AppKit's table entirely. `phase-2c-i-probe.md` then
  measured the alternative in release, on 50,000 rows: a SwiftUI `LazyVStack` of
  fixed-height rows holds **23.0000 pt/row exactly**, builds **1,086** row bodies for
  50,000 rows, and scrolls at a **0.574ms median** with **1 step in 300** over the
  8.33ms budget. The `Grid` it replaced missed the budget on **300 steps out of 300** at
  5,000 rows. So: a virtualizing SwiftUI `LazyVStack`, fixed row heights, and **no
  `Section`** — a `Section` under-reports the scroll view's document height by 2.8%,
  pinned or not, which is a scrollbar of the wrong size and a scroll-to-row that lands
  in the wrong place.

**The honest boundary:** Swift makes the *container* fast; it does nothing for how fast
Monaco boots or a staging query returns. Content latency (agent subprocess, DB/HTTP I/O,
web-view startup) is handled by keeping things warm and letting motion mask it — not by the
choice of language.

## 14. Settings (Phase 2 UI)

Three scopes, mirroring the architecture — each setting lives at the level of the thing it
governs, and **credentials attach at the level where the resource lives.**

| Scope | Holds |
|-------|-------|
| **Wakil** (app-wide) | STT engine default, theme, density default, keybindings, global behavior. |
| **Organization** | The **set of providers** registered under it — each provider one Claude account, with its own config dir, its own agent binary and its own OAuth token; org-level connections + auth shared across all its projects — Jira site, Slack workspace, mailbox. |
| **Project** | Roots; scopes (Jira key, channels); environments, each with its DB and API config **including credentials**. |

The **Wakil** scope is stored in `~/.wakil/settings.json` (3b-v, Decision 38). Its settings: the editor's font size, word wrap, autosave and whether gitignored files
are shown.

Rationale: a Jira account is one login serving every project → Organization. A database
belongs to a specific project's specific environment → Project → environment. This is why
the DB user/password fields sit under Project, and Jira auth under Organization.

**Why the provider row reads as a set, and why the running account is not in this table
(amended 2026-09-11 by 2b-vi).** This row said *"Claude account / config dir"*, singular,
and it was written before the 2026-09-06 org/provider decoupling. An org holds *several*
providers — `wakil provider add <id> --kind claude-code --config-dir <dir> --org <org>`
can be run more than once against the same org, and `~/.wakil/orgs/<org>/providers/`
is a directory, not a file. What the org owns is therefore the **set**: which accounts
exist under this org, where each one's config dir is, which agent binary each launches,
and which Keychain ref holds its token. What the org does **not** own is which of them is
running right now. That is a per-session fact, picked in the window and switchable
mid-session with no relaunch (2b-vi's `session_set_provider`), persisted as a fourth axis
on `active.json` beside org, project and environment so the pick survives a quit — the
same shape the environment already has, and for the same reason: a setting the operator
changes several times a day does not belong in a registration record. The running account
is shown permanently at the bottom-trailing edge of the window in luminance violet
(§5, §14's own colour constraint: green, amber and red are the environment's and are
never decorative), independently readable from the environment badge, because the pair
that matters is *which account, against which environment*.

**Credential handling (both phases):** every credential entered in Settings is stored in
the **macOS Keychain**, referenced from config by a `ref` — never written to
`project.json` (committable) or any plaintext file. A provider's OAuth token follows the
same rule as every other credential as of 2b-vi: its ref is derived from the provider id
(`provider:<id>`, org-scoped by `secrets.go` into the Keychain service
`wakil:<org>:provider:<id>`) rather than stored as a field, so a provider record can be
read, listed and copied without ever carrying the secret it names. Wakil transmits a credential only to
the service it belongs to. Storage mechanism is Phase 1 (`wakil secrets set` CLI); the
Settings UI is Phase 2 and writes the same Keychain entries.

**Settings forms share one vocabulary (added 2026-09-29, #327).** Every form in the
settings pane (the database form now, API entries when they land) is drawn from
`SettingsForm.swift`, and each piece comes from something already drawn here rather than
a new idea: a form sits in a **`FormCard`**, a slab with §2's half-pixel luminous edge and
no outline; fields are **`LabelledField`**, the boxed `.field` under a `.micro` label;
one-of-a-few choices are **`SegmentedChoice`**, joined buttons with the chosen one in
luminance violet (§5: light marks what is active), never a menu, because a menu's items
are not in the accessibility tree until it opens; tags are **`Chip`**, the environment
chip's shape; actions are **`FormButton`**, filled for the primary one. A new form that
needs a piece this list lacks adds it there, not inline. **`FormHint`** (3b-v part 2) is the
artboard's `.note`: one or two plain sentences under a setting saying what it does, beside the
setting it explains and never pooled in a footnote; a footnote keeps only where the setting is
stored. A field that sits in a list (a project's heavy folders) takes the same boxed `.field`
through `fieldBox`, and the list's add gesture is a `FormButton`.

**A page with more than one group is drawn in sections (added 2026-10-21).** The operator found
the pages bland, with nothing separating one group from the next. Each group is a
**`SettingsSection`**: a hairline above it, a micro header in QUICK TASKS' style, and 12pt of
rhythm; inside it, each setting is a **`SettingsRow`** — the label left at a fixed width
(`SettingsScale.labelWidth`), the value right, on one line, as QUICK TASKS' rows were first drawn.
An empty value reads `—` until it is typed in; a field is edited where it stands, its box drawn
only on hover or focus (`inPlaceField`). The Organisation page is Identity · Accounts · Jira ·
Git; Providers is Accounts · Local models · Quick tasks; the Editor pages are Editing · Files and
Indentation · Heavy folders; a project is Project · Roots; each API entry is its own section.
A page of one group (an environment) draws its rows without a header. **A page never draws wider than its pane:**
the pane holds the width it is given, and what does not fit moves under its label rather than past
the edge — the accounts table, whose four columns are wider than the subject column at the pane's
640pt default, draws each account as its identity and then KIND, CREDENTIAL and SIGN-IN as labelled
lines there, and a local model puts its URL under its name.

**The tree's projects and environments open and close (2026-10-21).** Each is a branch with its
own chevron, pressed apart from the row so opening never selects and selecting never opens; → and
← on the selected branch do the same, and the PROJECTS heading closes them all. The heading, the
active project and its active environment start open and everything else closed; the state is
the window's, never persisted, and changes only by the operator (Rule 6) — the one change made
for them is that reaching a node inside a closed parent opens its ancestors.

## 15. Open items

**Settled by 2b-ii (2026-09-09):** ~~Final palette values~~ — red was the one hue in §5's
table without a hex; it is now `#e85c5c`, assigned during 2b-ii's implementation. Violet,
blue, green and amber already had values. Nothing in the reserved-semantics table is
unassigned any longer.

**Still open — 2b-ii did not touch these, and says so explicitly in its own spec (§15):**

- **Exact typeface.** System sans is still only assumed; a distinctive display face for
  micro-labels remains unresolved. 2b-ii's spec defers it again, on the grounds that
  judging a display face wants a full window of real content, which arrives with 2c.
- **A light-environment variant, if ever needed.** Untouched. `VoidPalette` — the type
  2b-ii built to answer environment → colour — is the seam it would arrive through, but
  no light variant exists today; only the dark treatment does.
- **Full-working-day density test.** The pane density toggle (⌘⇧D, airy 40px / dense
  23px) shipped this phase and is real code, not just a design intent — but nobody has
  yet worked a full day against it. Validating it against real use before Phase 2
  hardens is still owed.
- ~~Editor gutter change-indicators + inline diff (vs Git pane only)~~ — settled by 3b-iii (Decision 40)
- Commit-history / branch graph in the editor's Changes (deferred)
- Side-by-side diff in the editor's Changes (deferred by 3a-i; inline only)
- ~~Whether a standalone dual-driven project-explorer pane is ever needed~~ — **settled by
  3b-ii (2026-10-13):** no. The editor's left column (§11) is the explorer, dual-driven
  through `editor_tree`, and ⌘P sits beside it.
- Grid snapping in addition to pane-to-pane magnetism
- **The room's motion numbers are untuned.** Thinking's 12s turnover and drift magnitude,
  listening's spread factor, and all four amplitude ranges were invented by 2b-iv's spec
  and have no precedent here. They live in one file (`WakilKit/Visual/CoreMotion.swift`)
  precisely so the tuning pass is a one-file edit. Whether a whole field in motion reads as
  calm rather than as a strobe is the open question underneath them.
  *(2026-10-08, 2d-ii: **listening's numbers are approved by the operator**, unchanged,
  against the running room: period 1.5 s, amplitude 0.95–1.25, spread 1.35, a 0.25 s ease.
  Measured in that session: the bottom glow sits at 27 idle and breathes 29–35 listening
  (about +19%, the top-right bleed +32%), returning without a jump on release. Thinking's
  turnover and the other states' ranges stay untuned.)*
