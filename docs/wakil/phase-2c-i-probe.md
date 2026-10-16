# The data surface's grid — a construction probe

**Run:** 2026-09-11 · **Machine:** MacBook Air M3, 16 GB, macOS 26.6.2 · **Toolchain:**
Swift 6.3.3 · **Probe:** `/tmp/gridspike`, throwaway, outside the repo · **Build:**
release (`swift build -c release`); a debug build was run first and its numbers are
discarded, because SwiftUI's debug layout cost is not the cost that ships

---

## 1. What prompted it

2c-i has to pick how a pane's data surface is drawn, and the two documents that govern
the choice disagree.

`design-language.md` §13 says:

> On very dense tabular data, prefer AppKit over SwiftUI for the grid specifically —
> SwiftUI list perf is the known weak spot.

2b-ii then measured, and recorded in `WakilWindow.swift`, that `Table`'s backing
`NSTableView` floors its row height at the platform default of 24pt, which puts §8's
23pt dense row out of reach inside it. That is why the pane draws a hand-built
`Grid` in a `ScrollView` today.

Both cannot be honoured as written. §13's line also predates the measurement that
contradicts it, so it is advice that has not met this case rather than a constraint that
survived it. The question is therefore narrow and answerable: **can a SwiftUI
`LazyVStack` of fixed-height rows hold the exact 23pt row *and* stay inside the frame
budget on a result set large enough to matter?**

## 2. What was measured, and how

An offscreen `NSWindow` at 900×400 hosting each construction through `NSHostingView`,
ordered in (SwiftUI neither lays out nor fires `onAppear` for a window that was never
brought on screen), with eight columns of short monospace strings.

Three things, each with its own method:

- **Exact row height** — the rendered `NSScrollView`'s `documentView.frame.height`
  divided by the row count. This is the only honest route available: unlike
  `NSTableView`, which 2b-ii interrogated through `rect(ofRow:)`, SwiftUI does **not**
  create an `NSView` per row, so walking the view hierarchy for 23pt-tall views finds
  nothing to measure. A first attempt did exactly that and reported one height bucket
  of 28pt with thirteen members — the chrome, not the rows. Its output is discarded.
- **Laziness** — a counter bumped from each row's `onAppear`. 50,000 rows that build
  50,000 bodies are not virtualized; 50,000 rows that build a viewport's worth are.
- **Frame cost** — `contentView.scroll(to:)`, `reflectScrolledClipView`,
  `layoutSubtreeIfNeeded`, `CATransaction.flush()`, timed per step. Run twice, and the
  distinction matters: **10pt per step** is what a scroll does, and **a sixtieth of the
  document per step** is a teleport in which every row is new. The second is reported
  as a worst case, not as the answer.

## 3. Result — A passes, and not narrowly

**The 23pt row is exact.**

| Row height asked for | Rows | Document height | Per row | |
|---|---|---|---|---|
| 23pt | 10 | 230.00 pt | 23.0000 | exact |
| 23pt | 100 | 2300.00 pt | 23.0000 | exact |
| 40pt | 10 | 400.00 pt | 40.0000 | exact |
| 40pt | 100 | 4000.00 pt | 40.0000 | exact |

Both of §8's densities, to four decimal places, with no floor anywhere near them.

**It virtualizes.** Row bodies constructed, against row count:

| Rows | `LazyVStack` | `Grid` (what ships today) |
|---|---|---|
| 500 | 487 | 500 |
| 5,000 | 1,055 | 5,000 |
| 50,000 | **1,086** | not run — 5,000 already cost seconds |

The `LazyVStack` figure is flat in the row count and tracks the *scrolling*, not the
data: a 400pt viewport at 23pt holds about 17 rows, and the measurement scrolls 60
times, which is the ~1,020 the two larger cases report. `Grid` builds every row it is
given, once, up front.

**First layout**, which is the same number stated another way: `Grid` took **5.3
seconds** to lay out 5,000 rows. `LazyVStack` was indistinguishable from its own
fixed settling delay at every size up to 50,000.

**It holds the frame budget.** 300 steps of 10pt, the way a scroll actually moves:

| | median | p95 | worst | steps over 8.33ms |
|---|---|---|---|---|
| `LazyVStack`, 5,000 rows | 0.574 ms | 1.713 ms | 9.086 ms | **1 / 300** |
| `LazyVStack`, 50,000 rows | 0.633 ms | 1.911 ms | 9.081 ms | **1 / 300** |
| `Grid`, 5,000 rows | 26.667 ms | 28.679 ms | 174.114 ms | **300 / 300** |

Two readings worth keeping. The `LazyVStack` median is a **thirteenth** of the 8.33ms
a 120fps frame allows, and it does not degrade from 5,000 rows to 50,000 — which is
what virtualization means when it is working. And `Grid` misses the budget on *every
single step* at 5,000 rows, by a factor of three at the median: the pane that ships
today does not hold 120fps on any result set a database would actually return, and that
was not previously written down anywhere.

Under teleporting steps — a sixtieth of a 1.1-million-point document per step, every row
new — `LazyVStack`'s worst step reaches 48ms at 50,000 rows. That is a scrollbar
dragged the length of the pane in one gesture, and it is the honest ceiling to record,
but it is not the case the budget is about.

## 4. One defect found, and it is in `Section`, not in laziness

The first `LazyVStack` construction wrapped its rows in a `Section` with a pinned
header, which is the obvious way to get a column header that scrolls horizontally with
the columns beneath it and stays put vertically. Its document height came out **2.8%
short** of the truth — 111,779pt where 5,000 23pt rows are 115,000pt.

Isolating it:

| Construction | 500 rows | 5,000 rows |
|---|---|---|
| `Section`, header pinned | −2.63% | −2.80% |
| `Section`, header **not** pinned | −2.63% | −2.80% |
| Header drawn **above** the `ScrollView` | **+0.00%** | **+0.00%** |

So it is `Section` itself, and pinning has nothing to do with it. A 2.8% error in the
reported content height is a scrollbar whose thumb is the wrong size and a
scroll-to-row that lands in the wrong place — both of which 2c-i needs to be exact,
since "jump to the row the agent selected" is a dual-drive action and not a nicety.

**The construction 2c-i should build** is therefore a header outside the vertical
scroll and a bare `LazyVStack` of rows inside it, measured above at exactly 0.00%
error. What that costs is the free horizontal-scroll synchronisation the pinned header
gave: the header and the rows are now in different scroll contexts, so their horizontal
offset has to be shared by hand. That is a known piece of work, not an open question —
but it is work, and it belongs in the spec rather than being discovered during it.

## 5. What this does not answer

- **Cell content is short monospace strings.** §8 wants status chips, explicit `null`
  rendering and type annotations in those cells. Richer cell views are more expensive
  per row; the measurement above is a floor for the construction, not for the finished
  surface.
- **One pane.** 2c-i puts data surfaces inside panes on the magnetic canvas, several at
  once, over a Metal layer that is itself drawing. Nothing here measures two scrolling
  grids and the room together.
- **Sort and column resize are untested.** Both were given up when `Table` went, and
  neither is recovered by `LazyVStack` — they are hand-built either way.
- **Accessibility is untested.** The per-row collapse 2b-ii added to `Grid` should port
  unchanged, but "should" is not a measurement.

## 6. Recommendation

Take **A**: SwiftUI `LazyVStack`, fixed row heights, header outside the vertical
`ScrollView`. §13's preference for AppKit is not upheld by measurement in this case and
should be amended to say so rather than left to contradict §8.
