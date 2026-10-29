# The collapsible rail: acceptance

**Design:** [`design-language.md`](design-language.md) §10, "The rail collapses" (2026-10-28) · **Action:** `rail_set`

The exit criterion: ⌃⌘R puts the rail away to a spine of marks at the window's right edge and brings it back;
resting the pointer on the spine slides the full rail out over the canvas; the agent can do the same.

## 0. Setup

Run this in the worktree root, on this Mac. It is safe to re-run. Open three panes (a terminal, an editor, a
database) with ⌘K, and have one terminal run `sleep 30` so a pane is working.

```bash
make build && make app-bundle
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil
```

## 1. The walk

| # | Where | Do | Expect | Walked |
|---|---|---|---|---|
| 1 | Wakil | Press ⌃⌘R, from the composer, then from a terminal, then from a browser page | Each time the rail fades away and a row of short horizontal marks, one per pane in the rail's order, is in the top bar at the right, above the panes. The active pane's mark is longer and violet, the working pane's is green with a glow, the rest are faint. The canvas takes the rail's width. Keyboard focus stays where it was. Press ⌃⌘R again: the rail is back, unchanged. The rail's sidebar glyph (tooltip *Hide Panes ⌃⌘R*) and a click on the marks do the same | ✓ 2026-10-28 |
| 2 | Wakil | Collapsed, rest the pointer on the marks for a moment | After a beat (about a quarter of a second) the full rail comes out over the canvas, it does not push a pane. It arrives from a few points to the right, sharpening and brightening to the mid plane, over about half a second. It is readable over a bright pane. The marks are gone while it is out, and it does not flicker while the pointer rests on them | ✓ 2026-10-28 |
| 3 | Wakil | Peeked, click a row, then move the pointer off the rail | The pane is focused. The rail stays about a third of a second after the pointer leaves, then fades away. Moving to the rail from the marks, or back to its edge, does not make it flicker | ✓ 2026-10-28 |
| 4 | Wakil | Collapsed, rest the pointer at the window's right edge, away from any mark, top to bottom | A 6 pt strip along the whole edge brings the rail out the same way. Peeking and leaving never move keyboard focus: type in the composer throughout | |
| 5 | System Settings → Accessibility → Display | Turn on **Reduce motion**, collapse and peek again | Collapsing and the peek are a plain crossfade, with no slide | |
| 6 | Wakil | Maximize a pane (⌘⏎) while collapsed, then while shown | The marks fade back the way the rail does. Resting the pointer on them still brings the rail out at full strength | |
| 7 | Wakil | Quit and relaunch with the rail collapsed. Then show it, quit and relaunch | It comes back collapsed. After showing it, it comes back shown. A first launch starts shown | |
| 8 | Wakil, VoiceOver | Collapsed, move to the marks. Ask the agent: "put the rail away", then "show the rail" | VoiceOver reads one element, "Open panes", with a value like "3 panes, editor active, 1 working", and Press shows the rail. The agent's calls (`rail_set`) do what ⌃⌘R does and appear in the journal | |

## 2. What no check reaches

The hover peek, its timings, the slide and the release, Reduce Motion and persistence across a relaunch are
walk-only (rows 2 to 5 and 7); `e2e/checks/uncoverable.tsv` names them under `rail.edge`. `rail-collapse.jsonl`
covers the action, the spine and the edge in the tree, ⌃⌘R, and focus staying put.
