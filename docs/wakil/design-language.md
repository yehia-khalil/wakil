# Wakil — Design Language

**Status:** v0, living · **Created:** 2026-09-03 · Conforms to `north-star.md`

---

## 1. Principles

1. **Futurism through absence, not addition.** No window chrome, borders, sidebars, or
   tab bars. What makes it read as future is what has been removed.
   One sidebar is sanctioned, inside a pane: the editor's left column (§11), shown and
   hidden only by the operator or the agent — ⌘B, ⌘⇧F, ⌘⇧G, its toggle, `editor_tree` —
   and never by width.
   **The background-agent chips are the only always-on chrome outside the context line**
   (Decision 41). One chip per agent in another place, top right of the window, reading
   `<org> · <project> · <environment>`; a click goes there. They exist only while there is
   work elsewhere: no agents elsewhere, no chips. At most two are drawn in full; the rest
   fold into one "+N more" chip carrying the strongest hidden state, whose click opens a
   list. Only the 6pt dot carries a hue, from §5's table; the capsule is a hairline over a
   near-black fill and nothing glows.

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
   thought thread "may overlap").
4. **Two registers.** *Chrome* may be atmospheric. *Data* must be ruthlessly legible.
   Never translucent, never glowing, never low-contrast behind a data surface.
5. **Calm over dense.** Information appears when relevant, not permanently.

## 2. The void

Near-black field (`#030408`–`#070812`) with two faint radial bleeds: violet from below,
cool blue from upper right. Fine grain overlay at ~14% to prevent gradient banding and
add material. Nothing fills the frame — content floats within it.

Panels are **slabs**: rounded, near-opaque dark surfaces, defined by drop shadow and a
half-pixel luminous edge rather than a border. No panel has a visible outline.

**The void is §4's Core.** Its two bleeds carry Wakil's four states in their amplitude,
spread and drift. **No state selects or alters a colour value** — the environment alone
owns which two colours are in the room, and `VoidPalette` is never touched by state.
Thinking modulates the two bleeds' amplitudes independently and out of phase, so the
room's colour *balance* — which existing colour reads stronger — does move with state: a
violet ↔ blue swing on the default palette, a brightness trade in production, where both
bleeds are the same red.

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

**The context line is exempt from opacity and blur** — the environment badge, the
organisation and the project, because they are read (Invariant 8 gives them no moment at
which they may be unreadable). Riding the far plane whole, the badge composited to 1.47:1
in production and 2.35:1 out of it, and the line to about 2.4:1, against the 4.5:1 floor
`PRODUCT.md` binds for read text. The far plane's **scale and parallax are kept**, its
**opacity and blur lifted**, and the quieting done by hierarchy instead — 19pt
organisation, 11pt monospace project, a chip. `ContextLine` (`WakilApp`) draws it, ambient
at rest with the segmented control promoted under the pointer. The badge's treatment lives
in `EnvironmentBadge` (`WakilKit/Visual/`); `EnvironmentBadgeTests` asserts both that it
clears the floor and that the far plane's own treatment would fail it, so the exemption
cannot be quietly undone.

**The rail is promoted, not exempt.** At rest it is ambient and nothing on it is read, so
it stays on the far plane and is **promoted to the mid plane whole under the pointer**:
scale, opacity and blur released together over §7's 400–600ms ease-out. A click is always
preceded by the pointer arriving, so a row is never clicked from the far plane.
`RailTreatment` (`WakilKit/Visual/`) holds the numbers and `RailTreatmentTests` asserts both
ends: **2.35:1 ambient against 16.9:1 promoted** for a pane name, and **5.4:1 for the kind
beside it**, stepped down by opacity at 0.55 (0.46 composites to 4.09:1 even promoted). The
floor applies to everything on the row that is read, not only the brightest thing on it.
A working pane's green tick replaces the word "working": a hue shift survives the far
plane. **Promotion outranks the maximize fade**: while a pane is maximized the rail is the
only way back to the others, so under the pointer it promotes regardless.

**The rail collapses.** ⌃⌘R, or the sidebar glyph at the rail's top right (tooltip *Hide
Panes ⌃⌘R*), puts the rail away to a *spine*: a row of 3 pt horizontal marks laid across
in the context line's band at the top right, above the panes and clear of their corner
controls, one per open pane in the rail's order, with no label. The active pane's mark is
longer and `#9e82ff`; a working pane's is §5's green and wins, as the ticks do; the rest
sit at 60%, brighter than the far plane so the spine is found at a glance. A click on the
spine shows the rail (*Show Panes ⌃⌘R*); on a peeked rail the glyph keeps it out. Resting
the pointer on the spine or the 6 pt edge for 150 ms slides the rail out *over* the canvas,
never pushing a pane, promoted to the mid plane as hover does; it leaves 300 ms after the
pointer does. The entrance is the plane releasing, opacity and blur together, plus a few
points of travel from the right over §7's 400–600 ms; with Reduce Motion it is a
crossfade. While a pane is maximized the spine fades as the rail does, and promotion
outranks the fade. Out over the canvas the rail sits on a void-coloured slab. Neither
peeking nor toggling takes focus (Rule 6). The state is the window's, kept across
relaunches, and moves only through `rail_set` (Invariant 2).

The Core is not on this plane: the room is behind everything, so the near plane holds
only what rises out of it.

## 4. The Core

Wakil's presence. **Not an object: the room.** The void of §2 carries the four states, and
nothing luminous is drawn in front of the panes at all — structurally guaranteed, since the
room is the bottom-most layer. The thought thread (§3, §9) does sit in front of the canvas,
but it is not the room and it does not glow.

**Hue belongs to the environment. Motion and intensity belong to agent state.** No state
selects or alters a colour value, ever (§2 for the balance swing). A red room that breathes
faster is production-and-thinking, unambiguously.

| State | Behaviour |
|-------|-----------|
| **Idle** | The lowest ceiling of the four — its amplitude never rises as high as the other three's — on a 5.4s breath. Present but asleep. |
| **Listening** | Brightest, and the bleeds tighten; breath quickens to 1.5s. |
| **Thinking** | The two bleeds trade dominance on a 12s turnover and drift slowly — the room turning something over. |
| **Speaking** | The lower bleed alone pulses on a 0.42s speech cadence. The upper field holds still. |

Four states, one room, **no text labels**. Peripheral legibility is the goal: knowing what
Wakil is doing from the corner of the eye.

**Speaking is contained by geometry.** The 0.42s pulse is confined to the lower bleed —
the same bottom edge §9's thread and §12's live transcription attach to.

**There are no ornaments.** No reticles, brackets, scan lines, grid overlays or rings
anywhere in the application.

## 5. Colour

**Luminance is violet-indigo** (`#7c5cff` primary, through `#4fb9e8` in the void's blue
bleed and `#8be0c8` in the reserved green below). Not cyan: cyan is the dated Tron/Jarvis
default, and violet leaves the semantic hues free.

**Reserved semantics — never decorative, anywhere:**

| Hue | Meaning |
|-----|---------|
| Green `#8be0c8` | Local / staging · healthy · completed |
| Amber `#e8b45a` | Pending · caution · untrusted site text in the thread |
| Red `#e85c5c` | **Production** · destructive · failed |

Red is `#e85c5c`, at the weight of the amber and green beside it — a pure `#ff0000` on a
near-black field reads as a display fault rather than a warning.

Text is cool white (`#e8ecf6`) stepped down by opacity, never by a different hue.

The background-agent chips (§1) use these hues in these meanings — amber waiting, green
completed, red failed — and luminance violet for an agent at work.

**The terminal pane's carve-out.** A shell's stdout is quoted material, not Wakil's voice,
and flattening it to one white would tell the operator a program printed nothing
distinguishable when it did. **Quoted program output carries the program's own colour,
mapped onto this table's own values** — never raw web colour:

| ANSI | Maps to | Note |
|------|---------|------|
| 1 / 9 (red / bright red) | `#e85c5c` | §5's own red |
| 2 / 10 (green / bright green) | `#8be0c8` | §5's own green |
| 3 / 11 (yellow / bright yellow) | `#e8b45a` | §5's own amber |
| 4 / 12 (blue / bright blue) | `#4fb9e8` | §2's void-blue bleed |
| 5 / 13 (magenta / bright magenta) | `#7c5cff` | §5's luminance violet |
| 6 / 14 (cyan / bright cyan) | blend of blue and green, 2:1 toward blue | leaning blue keeps it from reading as a fourth status colour |
| 0 / 8 (black / bright black) | the pane's own text colour, dimmed | never a hue — near-black on the near-black field is illegible |
| 7 / default (white) | the pane's own text colour, unchanged | |

Bright variants are the same hue lifted toward white, never a different hue. 256-colour
and 24-bit truecolour are pulled into this table's saturation and luminance band (a
ceiling and a floor, sized off the five anchors' own HSL) rather than rendered raw.

**The carve-out does not reach Wakil's own chrome** — status chips, the environment
badge, every label Wakil draws stays bound by this section exactly. It widens who may use
colour, not what the reserved hues mean. Implementation: `TerminalAnsiColor.swift`
(`WakilKit`), asserted in `TerminalAnsiColorTests.swift`.

**A log in the editor.** Red marks a log's error levels and amber its warnings, while
timestamps and stack traces are dimmed, so each entry's first line carries the eye.

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
window costs a fraction of a speaking one.

## 8. Data surfaces

The one place the aesthetic yields to utility. Opaque slab, full-contrast text, no
translucency, no glow. Row separation by whitespace, not rules. Status as chips, explicit
`null` rendering, column type annotations, hover-revealed row actions, and a footer
carrying row count, timing, and read-only state.

**Density toggle** (⌘⇧D), airy 40px default, dense 23px on demand, remembered per pane.

The only luminous element permitted inside a data surface is the **anchor**'s left edge:
the anchor is a (row, column) pair, the selected cell the selection is anchored on. Other
selected rows get a **lifted background** — opaque, non-luminous.

**Sort is intent, not action, and the footer says which it got.** A pane that can
re-query re-queries; one that cannot sorts what it holds and the footer reads "sorted by X
within the N returned". **A sorted result that is still truncated admits it** — including
a re-queried sort under an inner bound the operator wrote (an outer `ORDER BY` cannot see
past it).

**A `NULL` is drawn as a dimmed `NULL`**, never as an empty cell — an empty string is
also an empty cell.

**A paged result says which rows are on screen, and no total.** The footer reads
`rows 501–1,000 · more remain`, and on the last page `rows 1,001–1,006 · end`. No total:
it needs a second full scan and can disagree with the page beside it.

**Some reads cannot be paged, and say so rather than offering the control.** An
`EXPLAIN` and a `SHOW` do not survive the subquery paging wraps a statement in
(`phase-2c-ii-probe.md` §2). The page controls are absent on such a result and the footer
says "this result cannot be paged".

**Status chips draw only on a declared type.** A chip is drawn only on a column whose
declared type is boolean, never inferred from the cell's text — a `VARCHAR` holding
"true" gets no chip, and neither does a MySQL `TINYINT` column, which is also how MySQL
spells a small integer.

## 9. Visible work

Agent progress renders as a **thought thread** rising out of the bottom edge's glow,
where §2's violet bleed rises. The bleed lifts locally beneath the thread while work is in
flight, and fades with it. Completed steps fade to dim green, the live step pulses. This
replaces spinners and progress bars entirely.

**No upcoming steps.** Harness events arrive one at a time and nothing announces what the
agent will do next, so an upcoming step could only be invented.

The thread draws only events that describe work — assistant text, tool calls, tool
results, turn end — never `stream_event` / `rate_limit_event` / `session_state_changed`
traffic.

The thread overlaps the panes, which take the full height. It is four compact rows,
resting at 32% opacity and rising to full on hover; a click expands a row in place (an
open row toggles closed from its label), and the thread folds 1.2 s after the pointer
leaves unless a mouse button is held. Each sent turn is a `you` row. The bottom edge is one
flow: the thread, then status and notes, then the composer bar beside the account
indicator.

## 10. Layout model

**D (tabs + columns) is the information architecture; the void is the presentation.**

**Free-floating canvas with magnetic edges.** Panes float anywhere the user drags them —
not a fixed tiling grid.

- **Magnetism.** Dragging a pane within a few pixels of another pane's edge (or the void
  edge) shows a violet snap-line; releasing locks it flush and matches height.
- **Shared borders.** Once two panes are snapped, their shared edge is coordinated —
  dragging it resizes *both*, so snapped panes never gap or overlap. Pulling a pane away
  unlinks it back to free-floating.
- **Maximize** (⌘⏎) fills the void with the focused pane; the rail and Core fade back.
  ⌘⏎ again restores.
- **The Landing** — what the canvas draws before this session has done anything: the
  organisation's sessions to continue, and the pane kinds to open. **Gated on the
  session, not on the pane count.** It goes the moment work starts — a resumed session, a
  pane, or a spoken turn — and does *not* return when the last pane closes. Owed: nothing
  mints a fresh session in-window, so there is no way back to it without relaunching.
- **The rail** — a chrome-less floating list of open panes (glyph + label + shortcut, low
  opacity until relevant). It answers "what is open"; floating panes can hide behind each
  other. **"Until relevant" means under the pointer**: the rail promotes to the mid plane
  on hover, and both ticks are the same 2pt mark in two hues — `#9e82ff` active, §5's green
  `#8be0c8` working, which wins on a pane that is both. See §3.

**One plane, two front doors.** ⌘P and ⌘K open the same plane (§4.3's geometry, no sheet,
no buttons); they differ in what they list and what Return does. Pressing the other chord
while it is open switches mode rather than stacking a second plane, and a leading `>` in ⌘P
is the same switch, undone by deleting it. `Palette.dc.html` is the artboard.

- **⌘P — open or switch to.** Ordered by group, none drawn as a header and the right-hand
  label being the row's kind: open panes, new panes (built from `Pane.kinds`),
  **resources** (database tables, API entries and changed files — each has a pane to land
  in), the current organisation's projects, sessions, providers.
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

Ways to reach anything, all equivalent: the rail / a keystroke / ⌘P or ⌘K / voice.

## 11. Panes

Every pane is dual-driven (Invariant 2) except the editor's text surface and the browser's
page. Some pane *types* hold multiple tabs internally; the app itself has no tab bar.

| Pane | Multi-tab? | Notes |
|------|-----------|-------|
| **Editor** | Yes (files, ⌘T) | Native, Monaco-based — see below. The one partial exception to dual-drive. ⌘T opens a scratch tab; files open from ⌘P (Resources) or the left column (⌘B). Unsaved edits ask before anything drops them. A file in a repository shows gutter marks against the index — a green bar for added lines, amber for changed, a muted triangle where lines were deleted — and a click on one opens the peek: the change's old lines over its new, with ↑ ↓, Revert (an undoable buffer edit) and ×. The Files tree shows a changed file's status letter. **Its chrome is the compact chrome below**: Monaco runs edge to edge under one 32 pt row — the editor glyph (*Editor*), the column's toggle, then the shared tab strip with ＋ for ⌘T's scratch tab. |
| **Git** | No | Folded into the editor (Decision 40): the editor's left column's **Changes** view (⌘⇧G) — one header per root, Staged / Changes / Untracked, status letters in §5's tones — opens read-only inline diff tabs in the editor. No pane of its own. |
| **Browser** | Yes (⌘T) | WebKit, one profile per organisation (Decision 48). The page is the **second exception to dual-drive**: clicks and typing inside it are the operator's alone; everything around it — tabs, address, ‹ ›, reload, find, zoom, downloads — is a `browser_*` action. **The agent may read the page and click, type, select, press and scroll in it (Decision 48)**, a site at a time: the first act on a site asks *Let the agent use <site>?* (**Don’t Allow** / **Allow for this conversation**), and every act on a production site asks, in the red plane, naming the element. It never types into or fills a password, card or one-time-code field. Three marks tell the operator: a **tag** on the tab — a chip at the address row’s right for the active tab (*In staging* in green, *Production* in red) and a 6 pt dot on every tagged tab’s strip entry, so a background tab wears it too; the **agent allowed** mark, with a × that withdraws the site; and, in the thread, a read as *1 page · untrusted text from <site>* in amber, which also marks untrusted site text. **Its chrome is the compact chrome below**, in two 32 pt rows over a page that runs edge to edge. Row one is the shared tab strip with the browser glyph (*Browser*), its entries in the browser's own width rule — 200 pt while they fit, then shrinking evenly to 96 pt, title truncated and favicon kept, the active one to no less than 140 pt, about fourteen characters of title, before the strip scrolls — and, pinned at the right after the ＋, the tab count: tabular digits without the micro-label's tracking, so 15 reads as one number, and a press opens the ⌄ menu of every tab. Narrow, entries shrink to favicon and ×, then fold into the count menu, which then carries the ⌄. Row two is ‹ › ↻ and the address field, always drawn as a field: rounded, a 1 px edge in the border token, the URL in mono, and the padlock — or the open lock and NOT SECURE for http beyond loopback — inside it at the left; its hover names the host, the transport and, for a certificate not trusted, why. There is no footer. The find bar and the downloads each take a row across the page's top or bottom edge, a hairline round each. **The address field suggests as you type**: open tabs, then bookmarks, then history, in a list under the field — ↓ ↑ move through it, Return opens the row, Esc closes it and restores what was typed — and it completes the host inline; the search engine's own suggestions are a setting, off by default. The **★** at the address row’s right is the bookmarks menu (*Bookmark This Page* or *Remove Bookmark*, then the bookmarks); ⌘D toggles. ⌘P lists open tabs and bookmarks. ⌘-click a URL in the terminal or the editor opens it here, ⌘⌥-click in the system browser. A playing video floats into the system's picture-in-picture window when you leave it, and Restore goes back. **Tabs form groups**: one of six muted swatches (blue, steel, teal, sand, stone, smoke; 20–50% saturated, so each reads as a hue, and never a reserved one). A group's header is the same in both modes: a soft pill tinted with its colour (13%, 19% under the pointer), a solid dot, the name in medium weight and the member count in the meta style; in the column it fills the row behind a chevron that turns 90° as it opens (§7's ease-out, still under Reduce Motion). Members carry the colour: an underline in the strip, and in the column ONE 2 pt line down their run from under the header's dot, the rows indented past it. The active member's violet tick stands in the line's place, never beside it. Collapsed, a group shows up to three of its members' favicons overlapping, and the active tab under the header, as a member row, while the active tab is one of its own. **Pinned** tabs and groups come first, per project, as a section of their own: in the column a grid of square favicon tiles — as many to a row as the width holds, four at 220 pt — each a rounded square with the hairline's edge, the title as its tooltip, the active one the raised chip with the rail's tick laid flat under its favicon, one not loaded yet dimmed; the pinned groups' pills under them, then the house's 0.5 pt rule at the hairline's opacity, and no unpinned tab above it. In the strip pinned tabs are favicon-only entries at the left, the pinned groups' pills after them, then a vertical line in the border token. Dropping a tab on the pinned tabs pins it there, and a pinned tab dropped past the line is unpinned where it lands. With nothing pinned there is no section and no line. ⌘W on one asks *Press ⌘W again to close* and its × closes in one click. **Vertical tabs** are a setting for every pane: a column at the left, 220 pt, 160–360 pt by its edge, ⌃⌘S hides it and the pointer at the left edge slides it out. In the vertical mode the header is one 32 pt row — the browser glyph, ‹ › ↻, the address field and ★, the field giving way first in a narrow pane — and the tab count sits at the column's foot beside *New Tab*, in the meta style. **Passwords (Decision 49)**: a focused login field with a saved login, or a new-password field, draws a 16 pt `key.fill` at its right edge, inset 4 pt, at the meta opacity. Nothing is filled until it is pressed; the press opens a popover of the site's logins (or *Suggest Strong Password* on a new-password field), which stays open while a fill runs, shows a Keychain error whole, and leaves the keyboard in the page. A sent form raises a bar across the pane's top: *Save the password for <user> on <site>?* with **Save**, **Not Now** and **Never for This Site**, or *Update the password…* with **Update** and **Not Now**; it stays until answered and the page under it stays usable. Settings → Browser → Passwords lists, reveals, copies, edits and deletes. |
| **Terminal** | No | One shell, on one PTY, opened **at a path** — not per-root, and no tab bar. A second shell is a second pane; §10's canvas is what running two of them is for. **Its chrome is the compact chrome below**: one shell, so no strip — one 32 pt row of the terminal glyph (*Terminal*), the pane's title, the live cwd · shell · size, Reopen on a dead pane and the ⌘F toggle; ⌘F's field takes a 32 pt row of its own under it. The surface runs to the border with a 6 pt gutter inside it, so no text meets the edge, and the bound (*last 200 commands · 500 lines each*) is one line under it. |
| **Database** | No | The canonical data surface (§8), above it the pane's own query — the database it runs against and the statement, editable, run with Return. A second query is a second pane. |
| **API client** | No | Request/response; consumes values from other panes. |
| **PM** | No | Kanban over the active project's issues, scoped to the active `(org, project)`. Columns are the Jira board's own; a card is §8's row drawn small, on §8's surface rather than a second grid. Dual-driven; the one write it carries is a status transition (Invariant 6). Sub-phase 2c-vi. |
| Recall | — | Surfaced through the agent, not a standalone pane. |

### The compact chrome — the browser, the editor and the terminal

A pane of these three kinds (`PaneKind.edgeToEdge`) runs its content to the slab's border:
the canvas pads it with nothing, draws no title over it and no resize row under it.

- **The slab.** The content is clipped to the slab's corners and takes its 10 pt bottom
  corners; the pane's own 1 px edge is drawn in the border token over it, so the outline
  holds against any content. The resize handle sits on a small chip in the bottom-right
  corner, over the content.
- **The header row: 32 pt.** The kind's glyph stands in the title's place at the row's
  left — the browser's compass, the editor's `</>`, the terminal's prompt — at the
  micro-label's opacity, the kind's name as its help and its spoken name. A hairline runs
  under the row, across the pane.
- **Two tokens, both cool white.** Content that meets its border needs a line to stop
  against, so §1's "no outline" and §8's "whitespace, not rules" give way here: **the
  border token, 0.14** (the settings form's field edge) — an edge-to-edge pane's border,
  the active tab's raised chip, the browser's address field; and **the hairline, 0.08**
  (the editor's rule between Changes roots) — under a header row, between two tabs at
  rest, and under each compact row.
- **The tab strip** (the browser's and the editor's; `PaneTabStrip`). Entries 26 pt high
  in the rail's language: the rail's 2 pt tick on the active one, which is a raised chip —
  a 0.08 lift and the border token's edge — with a 1 px hairline between two entries at
  rest and none against the chip or an entry lifted under the pointer (the rail's row
  lift). An entry drags along its own strip to reorder, a line in the tick's colour
  marking the drop. **More entries than fit:** the strip scrolls, and while it does, a
  side with entries out of sight fades over 24 pt and shows how many, `‹ 3` or `8 ›`; a
  press pages the strip toward them, and a side with none hidden shows nothing. The ＋
  (and the browser's count) are pinned at the right, outside the scrolling. The active
  entry is scrolled into view whenever it changes — a click, a key, a menu, the agent, a
  new tab — and only when some of it is out of sight, so a click on an entry already shown
  never moves the strip (Rule 6). How wide an entry is stays the kind's: the browser's
  shrink (its row above); the editor's keep their own width, because a shrunk file name
  hides which file it is.
- **Compact rows.** Any other row a pane draws across its content — the editor's notice,
  *changed on disk*, Compare's header, a diff tab's line, Stage Selected Ranges, the
  save-as field, a tab's unsaved prompt; the editor column's Files · Search · Changes
  header; the terminal's ⌘F field; the browser's find bar — is at most 32 pt for one line,
  at the row's 8 pt inset, with a hairline under it. A line that has to say more wraps
  rather than being cut (Rule 8). The editor column's header is 32 pt, so it and the strip
  beside it meet in one line.
- **Focus is unchanged.** Nothing in the chrome takes the keyboard: the glyph is not a
  control, and a press on an entry, a count or the ＋ moves the keyboard only where the
  action itself always has (a new tab arriving takes it, Rule 3).

**The database pane has no schema browser and no sidebar** (§1). A table list and a
column list are result sets, so both draw on §8's own surface, in a database pane, reached
by the same actions as any query. Hovering a row of a table list reveals one row action:
open that table in a new pane.

**The editor is native, not embedded VS Code** (Decision 17): a native Monaco-based editor
can be dual-driven — operated as actions ("rename to `bookingId`", "open the confirm
method") — which embedded VS Code cannot. Cost: no extension marketplace, no full
debugger.

- **The left column** — a column inside the pane, §1's one sanctioned sidebar, with three
  views: **Files** (⌘B), **Search** (⌘⇧F) and **Changes** (⌘⇧G). Nothing hides it at any
  width; ⌘B, ⌘⇧F, ⌘⇧G, its toggle or the agent show and hide it. Its edge drags from 160 pt
  to half the pane, and each pane keeps its own column — shown, view, width and open
  folders — across a relaunch; a new pane starts as the last one was left. Only the
  operator's own keys and buttons move the keyboard into it; the agent's actions never do.
  - **Files** — the project's roots as top-level folders (VS Code multi-root style), with
    a root that holds repositories showing each as a node. Gitignored files are dimmed, not
    hidden; heavy folders (`node_modules`, `vendor`, …) are one dimmed row, loaded when
    opened. The tree follows the disk live and keeps open folders open. It is writable
    (Decision 41): each root row shows a **+** on hover or selection, a menu of New File
    and New Folder, and a new item, or a rename (F2), is an inline name field in the row's
    own indent, monospaced 11 pt, with a refusal shown whole beneath it. A reveal button in
    its header (and ⌘K's *Reveal Active File in Tree*) opens the folders above the active
    file and selects its row; the tree never follows the active file by itself. File rows,
    Changes rows and editor tabs carry a single-colour Seti glyph for the file's language,
    in the name's own colour; folders keep their chevron.
  - **The preview tab** — a single click opens a file in one italic tab that the next
    single click replaces; a double-click or an edit keeps it. Tabs move by dragging along
    their own strip (a line in the tick's colour marks the drop) and close on a
    middle-click, as ⌘W closes them.
  - **Search** — across the project's files, literal or regex, with case and whole-word
    switches; it runs on a pause in typing, groups results by root and file (groups
    collapse), marks each match, and offers Cancel while it runs. A result opens with its
    match selected; the find bar stays shut (⌘F opens it). An invalid pattern is shown
    whole and nothing runs; a change on disk offers *Re-run*.
  - **Replace** — a ▸ beside the query opens a Replace field; each result line then shows
    its match struck through and the replacement in violet. *Replace All* and a file
    group's *Replace in this file* ask nothing (Decision 39): a file open in a tab is
    edited in its buffer, the rest are written, and one line — *Replaced 37 in 12 files ·
    Undo replace* — offers the undo, which leaves any file changed since.
  - **Changes** (Decision 40) — one block per root, a hairline between them: a header
    (`api  main ↑2 ↓1`, the branch dimmed; a header collapses its root), and only while the
    root has changes its message box and Commit, then Staged / Changes / Untracked, each
    collapsible. A clean root is one line (`web  main · clean`); a root that is not a git
    repository is not drawn. Rows read the file name, its folder dimmed, and the status
    letter in §5's tones (never red) at the far right. A click or Return opens a read-only
    inline diff tab under the preview-tab rule; ⌘⏎ in a diff opens the file at that line.
    It follows git live, with no refresh control.
  - **Find in file** — Monaco's own find and replace bar (⌘F, ⌥⌘F) in Wakil's colours,
    closed with Esc; the agent opens it with `editor_find`.
  ⌘P stays the faster path to a file whose name you know, and lists ignored files dimmed,
  ranked last.
- **Compare** — when a file changes on disk under unsaved edits, *Compare* draws the
  buffer against the disk's text as a diff **inside the pane**, closed with Esc. It is not
  a tab; the tab strip holds only files and scratch buffers.
- **Autocomplete, three tiers:**
  1. Basic — Monaco built-in (word/snippet), free, v1.
  2. Type-aware — per-language LSP (Intelephense, tsserver, …); real per-language work
     Wakil owns; added on demand starting with PHP/Laravel and TS.
  3. AI ghost-text — runs on the org's quick-tasks provider: its Claude account by
     default, a local model when the operator adds one (Decision 42). Context: the file and
     the active environment's schema. Wakil's edge over generic Copilot.
- **Change indicators** in the gutter and the peek: see the Editor row above. A file past
  10,000 lines shows no marks.

## 12. Voice

Voice is a transport, not a command language (Invariant 10): speech-to-text produces the
exact string the ⌘K box would send, through one code path.

- **Push-to-talk** (hold ⌥), no wake word. **The Core's four states *are* the voice
  indicator**: no separate object and no separate mic UI — the room itself listens and
  speaks. Listening: the room brightens and its bleeds tighten; the live transcription
  appears at the bottom edge, in the glow, beside §9's thread.

  **Release lands, it does not send.** An allow-priced write can run from a
  mistranscribed spoken turn (`2d-stt-probe.md` §10), so releasing ⌥ puts the transcript
  in the composer unsent, at the caret, and Return sends it. Silence is answered in words
  in the composer bar — "Hearing nothing from <device>" after 1.5 s with no sound — never
  a meter.

  **There is no waveform.** A waveform is a separate mic UI restating what the room's
  states already carry. The transcription stays because it is not an indicator: it shows
  **what was heard**, the only evidence the operator has before sending.
- **On-device STT** (Apple / Whisper) — audio never leaves the machine. Engine is
  per-organization (Decision 18).
- **You watch it work.** A spoken command's plan renders as the same thought thread
  (§9) that typed commands use.
- **Results land in panes, not the voice bubble.** Wakil speaks a one-line confirmation;
  the substance (rows, response, diff) appears in the relevant pane.
- **Write gate (Invariant 7).** In a chain, read steps run automatically; the chain
  *stops* at any mutation and shows a typed-confirmation gate. The user types `confirm` —
  saying "yes" does nothing. Voice may propose a write, never execute one — where the
  write's price is *gate*.
- **Environment governs the gate.** Each write declares its own price (Invariant 6,
  Decision 25); the HTTP send's is `(production: .gate, otherwise: .allow)`. Production:
  the gate turns red and **costs a typed confirmation**; it is not a refusal. The
  environment badge is always visible so the target world is known before speaking.
- **Hands-free mode: deferred.** A wake-word/toggle mode collides with the typed write
  gate. If added later, hands-free permits reads only.

## 13. Performance budget

Snappiness is a requirement, not a hope. Native (Swift/SwiftUI + Metal) removes the
web-runtime ceiling on the always-animating shell; felt speed then depends on engineering
the async boundaries below.

**Targets:**
- **120fps shell** on ProMotion — pane motion, magnetic drag, plane transitions, the Core.
- **Project/org switch < ~400ms to interactive**, and the latency is *covered by motion* —
  the outgoing pane recedes while the incoming rises (~500ms), hiding the reconnect. State
  is kept warm; panes are never torn down and rebuilt on switch.
- **The room is a Metal/GPU shader**, never CPU — it animates continuously, so CPU would
  jitter and drain battery. **One layer**, at its own cadence (§7).
- **Web-view pooling.** Editor (Monaco), browser, and any embedded view are separate web
  content processes with real startup/memory cost. Hidden panes suspend; instances are
  reused, not recreated. Cap concurrent live web contexts.
- **Data-grid virtualization.** Grids render only visible rows: a virtualizing SwiftUI
  `LazyVStack`, fixed row heights, and **no `Section`** (it under-reports the scroll
  view's document height by 2.8%). Not AppKit: `NSTableView` floors its row height at 24pt,
  out of reach of §8's 23pt dense row. Measured in `phase-2c-i-probe.md` on 50,000 rows:
  23.0000 pt/row exactly, 1,086 row bodies built, 0.574ms median scroll step, 1 step in
  300 over the 8.33ms budget.

**The honest boundary:** Swift makes the *container* fast; it does nothing for how fast
Monaco boots or a staging query returns. Content latency (agent subprocess, DB/HTTP I/O,
web-view startup) is handled by keeping things warm and letting motion mask it — not by the
choice of language.

## 14. Settings (Phase 2 UI)

Three scopes, mirroring the architecture — each setting lives at the level of the thing it
governs, and **credentials attach at the level where the resource lives.**

| Scope | Holds |
|-------|-------|
| **Wakil** (app-wide) | STT engine default, theme, density default, keybindings (Settings → Keyboard, Decision 50), global behavior. |
| **Organization** | The **set of providers** registered under it — each provider one Claude account, with its own config dir, its own agent binary and its own OAuth token; org-level connections + auth shared across all its projects — Jira site, Slack workspace, mailbox. |
| **Project** | Roots; scopes (Jira key, channels); environments, each with its DB and API config **including credentials**. |

The **Wakil** scope is stored in `~/.wakil/settings.json` (Decision 38): the editor's font
size, word wrap, autosave and whether gitignored files are shown. Keyboard (Decision 50)
lists every menu command with its chord and a recorder, and the keys that are fixed.

A Jira account is one login serving every project → Organization. A database belongs to a
specific project's environment → Project → environment.

**The org owns the set of providers, not which one is running.** An org may hold several
(`wakil provider add <id> --kind claude-code --config-dir <dir> --org <org>`, run more
than once; `~/.wakil/orgs/<org>/providers/` is a directory). Which is running is a
per-session fact, picked in the window and switchable mid-session with no relaunch
(`session_set_provider`), persisted as a fourth axis on `active.json` beside org, project
and environment. The running account is shown permanently at the bottom-trailing edge of
the window in luminance violet (green, amber and red are the environment's), readable
apart from the environment badge: the pair that matters is *which account, against which
environment*.

**Credential handling:** every credential entered in Settings is stored in the **macOS
Keychain**, referenced from config by a `ref` — never written to `project.json`
(committable) or any plaintext file. A provider's OAuth token's ref is derived from the
provider id (`provider:<id>`, org-scoped by `secrets.go` into the Keychain service
`wakil:<org>:provider:<id>`) rather than stored as a field, so a provider record never
carries its secret. Wakil transmits a credential only to the service it belongs to. The
CLI (`wakil secrets set`) and the Settings UI write the same Keychain entries.

**Settings forms share one vocabulary**, from `SettingsForm.swift`: a form sits in a
**`FormCard`**, a slab with §2's half-pixel luminous edge and no outline; fields are
**`LabelledField`**, the boxed `.field` under a `.micro` label; one-of-a-few choices are
**`SegmentedChoice`**, joined buttons with the chosen one in luminance violet, never a menu
(a menu's items are not in the accessibility tree until it opens); tags are **`Chip`**, the
environment chip's shape; actions are **`FormButton`**, filled for the primary one. A new
form that needs a piece this list lacks adds it there, not inline. **`FormHint`** is the
artboard's `.note`: one or two plain sentences under a setting saying what it does, beside
the setting it explains and never pooled in a footnote; a footnote keeps only where the
setting is stored. A field that sits in a list (a project's heavy folders) takes the same
boxed `.field` through `fieldBox`, and the list's add gesture is a `FormButton`.

**A page with more than one group is drawn in sections.** Each group is a
**`SettingsSection`**: a hairline above it, a micro header in QUICK TASKS' style, and 12pt
of rhythm; inside it, each setting is a **`SettingsRow`** — the label left at a fixed width
(`SettingsScale.labelWidth`), the value right, on one line. An empty value reads `—` until
it is typed in; a field is edited where it stands, its box drawn only on hover or focus
(`inPlaceField`). The Organisation page is Identity · Accounts · Jira · Git; Providers is
Accounts · Local models · Quick tasks; the Editor pages are Editing · Files and
Indentation · Heavy folders; a project is Project · Roots; each API entry is its own
section. A page of one group (an environment) draws its rows without a header. **A page
never draws wider than its pane:** what does not fit moves under its label rather than past
the edge — the accounts table, whose four columns are wider than the subject column at the
pane's 640pt default, draws each account as its identity and then KIND, CREDENTIAL and
SIGN-IN as labelled lines there, and a local model puts its URL under its name.

**The tree's projects and environments open and close.** Each is a branch with its own
chevron, pressed apart from the row so opening never selects and selecting never opens; →
and ← on the selected branch do the same, and the PROJECTS heading closes them all. The
heading, the active project and its active environment start open and everything else
closed; the state is the window's, never persisted, and changes only by the operator
(Rule 6) — except that reaching a node inside a closed parent opens its ancestors.

## 15. Open items

- **Exact typeface.** System sans is only assumed; a distinctive display face for
  micro-labels is unresolved, to be judged against a full window of real content.
- **A light-environment variant, if ever needed.** None exists; `VoidPalette` is the seam
  it would arrive through.
- **Full-working-day density test.** The density toggle (⌘⇧D, airy 40px / dense 23px)
  ships, but nobody has worked a full day against it.
- Commit-history / branch graph in the editor's Changes (deferred).
- Side-by-side diff in the editor's Changes (deferred; inline only).
- Grid snapping in addition to pane-to-pane magnetism.
- **The room's motion numbers are untuned.** Thinking's 12s turnover and drift magnitude,
  and the other states' amplitude ranges, were invented, not measured. They live in one
  file (`WakilKit/Visual/CoreMotion.swift`) so tuning is a one-file edit. The open
  question: whether a whole field in motion reads as calm rather than as a strobe.
  **Listening's numbers are approved by the operator** against the running room: period
  1.5 s, amplitude 0.95–1.25, spread 1.35, a 0.25 s ease (the bottom glow at 27 idle
  breathes 29–35 listening, the top-right bleed +32%, returning without a jump on release).
