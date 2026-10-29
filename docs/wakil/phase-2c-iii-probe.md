# The terminal pane's throughput — a pre-registered probe

**Run:** 2026-09-17 · **Machine:** MacBook Air M3, 16 GB, macOS 27.0 (26A428) ·
**Toolchain:** Swift 6.4 · **Dependency under test:** SwiftTerm 1.20.0 ·
**Probe:** `scripts/probe/termspike`, kept · **Build:** release
(`swift build -c release`) throughout; no debug number appears here, because
SwiftUI's debug layout cost is not the cost that ships

---

## 1. What prompted it

[#72](https://github.com/yehia-khalil/rafiq/issues/72) pre-registered exactly one
measurement, and named the risk in one sentence:

> **Throughput**, measured before the pane is built: `cat` of a large file and a
> build's output, through SwiftTerm's parser, a SwiftUI grid and the unbounded
> stream. 2c-i's probe found a 5.3-second first layout nobody had measured, and a
> **custom grid renderer at 120fps is that shape of unknown.**

The chain that has to keep up is five links long, and 2c-iii is the first
sub-phase in which Wakil does not own any of the middle three:

```
pty master → drain thread → unbounded stream → SwiftTerm parser → SwiftUI
```

This probe measures each link, then the whole thing on a real shell. It answers
the pre-registered question, and it found four things the spec did not ask about
— two of which change it.

## 2. What was measured, and how

Six measurements, run by `scripts/probe/termspike` (§8). The method for the two
drawing measurements is 2c-i's, deliberately: an offscreen `NSWindow` hosting the
construction through `NSHostingView` and **ordered in** — SwiftUI neither lays out
nor fires `onAppear` for a window that was never brought on screen — then, per
frame, `layoutSubtreeIfNeeded` followed by a flushed `CATransaction`, timed.

| # | Question | Method |
|---|---|---|
| 1 | How fast can SwiftTerm's parser eat, and does chunk size change it? | 32 MB of plain and of SGR-coloured output, fed at five chunk sizes |
| 2 | What does reconstructing blocks from OSC 133 marks cost, and do the marks survive? | 20–400 marked commands, then a full-buffer mark walk |
| 3 | What does SwiftTerm *not* give back? | Fed `D;42`, `OSC 7` and an alternate-screen switch; read the public API for each |
| 4 | Does the whole chain keep up on a real shell? | `forkpty` + `bash --noprofile --norc -i`, `cat` of 28 MB and a real `swift build` |
| 5 | Can a SwiftUI grid draw the live screen at 120fps? | Three constructions × three grid sizes, whole new screen every frame |
| 6 | Can a SwiftUI list draw the block history? | 50–500 blocks × 40–1000 lines, first layout then 20 scroll steps |

Two cases in measurement 4 are the pre-registered ones. `cat` of a large file is
a 28 MB text file; "a build's output" is a **real** `swift build` of `WakilKit`
into a scratch build path, run both quiet and `-v`.

## 3. Result — the pre-registered question passes, with one construction disqualified

**The parser is not the bottleneck, and chunk size does not matter.**

| payload | rate | flat across chunk sizes? |
|---|---|---|
| plain (`cat`) | **73–77 MB/s** | yes — 73.0 at 1 KB, 76.8 at 1 MB |
| build-like (SGR) | **55–60 MB/s** | yes — 59.2 at 1 KB, 59.7 at 1 MB |

The flatness is the useful half. The drain thread hands over whatever `read(2)`
returned and does not get to pick, so **the pane never needs to coalesce bytes
before feeding** — only before drawing.

**The whole chain, on a real shell, at 132×36:**

| case | bytes | end-to-end | parse only | reads | 60 Hz frames |
|---|---|---|---|---|---|
| `cat` of a large file, inline parse | 28.22 MB | **78.0 MB/s** | 0.328 s | 29,025 | 21 |
| `cat` of a large file, unbounded queue | 28.22 MB | **91.8 MB/s** | 0.301 s | 29,088 | 4 |
| a build's output, quiet | 1.1 KB | — | 0.001 s | 136 | 20 |
| a build's output, `-v` | 28.8 KB | — | 0.001 s | 196 | 25 |

**The grid, which is what the spec was actually afraid of:**

| construction | 80×24 | 132×36 | 200×50 |
|---|---|---|---|
| **A — a `Text` per cell** | 98.0 ms · 10 fps | **240.5 ms · 4 fps** | 121.4 ms · 8 fps |
| **B — a `Text` per row** | 3.12 ms · 321 fps | **4.82 ms · 207 fps** | 7.98 ms · 125 fps |
| **C — one `Canvas`** | 0.95 ms · 1048 fps | **1.29 ms · 773 fps** | 1.95 ms · 513 fps |

The fear was justified and the answer is narrow: **the literal reading of "a
custom grid renderer" — one addressable view per cell — is disqualified.** At the
pane's own 132×36 it draws 4 frames a second, thirty times slower than the 120fps
the spec had in mind, and it is the only construction measured that fails.

Both alternatives clear 120fps with room: B by 1.7× at the largest size measured
and 3.4× at 132×36, C by 4.3× and 6.4×. **C is not needed to pass**, which matters
because a `Canvas` draws its own text and gives up per-cell hit-testing, selection
and accessibility — everything `design-language.md` wants from the grid. B keeps
all of it.

**Two honesty notes on that table.** A's 200×50 median is *faster* than its own
132×36, repeatably, and sizing the window to the grid to rule out culling did not
move it. Once a construction is this far past the frame budget, the flush stops
capturing the whole cost and the number stops meaning what the other rows mean.
It does not change the verdict — every A cell is a disqualification — but A's
three numbers are not a curve and should not be read as one. And C's *worst*
frame is 16–18 ms against a ~1 ms median at every size, so the `Canvas` has a
spike the other constructions do not.

**The block history is not a rendering problem at all.**

| blocks | lines each | total rows | held in memory | first layout | median scroll step |
|---|---|---|---|---|---|
| 200 | 40 | 8,200 | 0.88 MB | 10 ms | 5.40 ms |
| 1000 | 40 | 41,000 | 4.42 MB | 8 ms | 5.33 ms |
| 200 | 500 | 100,200 | 18.39 MB | 34 ms | 0.46 ms |
| 500 | 1000 | 500,500 | 85.67 MB | 66 ms | 0.79 ms |

A `LazyVStack` of blocks is genuinely lazy: the scroll step is flat at ~5 ms from
2,050 rows to 500,500, and the first layout never approaches 2c-i's 5.3-second
cliff. **So the scrollback bound the spec owes a number to is a memory decision,
not a frame-rate one** — see §6.

## 4. Four findings the probe was not looking for

### 4.1 The marks do **not** survive scrollback — they survive *scrolling*

#72's dependency section took SwiftTerm for, among other things, *"OSC 133
semantic-prompt parsing with marks that survive scrollback."* The claim is not
originally Wakil's: it is SwiftTerm's own doc comment, at
`SemanticPrompt.swift:16` — *"Values are attached to cells as they are written and
survive scrollback"* — read into `phase-log.md` (line 1332, *"marks survive
scrollback"*) when the engine was cloned and read, and synthesised from there into
the spec. Measured:

| commands fed | buffer rows | marks still findable | lost |
|---|---|---|---|
| 20 | 1,020 | 20 | 0 |
| 100 | 5,100 | 100 | 0 |
| 200 | 10,036 | 194 | **6** |
| 400 | 10,036 | 193 | **207** |

The buffer plateaus at the scrollback cap and **marks are trimmed with the lines
that carried them.** Within the window they survive scrolling perfectly, which is
the clause's true content; past it they are gone, and a block whose opening mark
has been trimmed cannot be reconstructed from the buffer at all.

**This changes the spec, and it does not touch Decision 23.** Worth separating,
because the repo cites rulings by number and a wrongly-attributed correction breaks
the citation as surely as a silent edit would. Decision 23 says only that SwiftTerm
*"already ships OSC 133, OSC 7 and alt-screen notification"*, which is true; the
scrollback clause was never in it. Its *Reverse if* — *"SwiftTerm's OSC 133 and
exit-code gaps deepen faster than they can be patched"* — is **not** triggered:
capturing blocks at the `D` mark is that patch, and it is the same work the dropped
exit code already required.

So *"block boundaries come from the OSC 133 marks"* stays true, but reconstructing
a block history by walking SwiftTerm's buffer does not work. Wakil must **capture
each block as it completes**, at the `D` mark, into its own storage — which is also
the only place the per-block line cap can be applied. The walk itself is not the
obstacle: 10,036 rows cost 0.7 ms.

### 4.2 There is no content-change callback at all

`TerminalDelegate` has **no `refresh` member** — no `contentChanged`, nothing that
fires when cells are written. The first version of this probe implemented one and
it compiled and ran, silently, because it satisfied no protocol requirement and
was never called; its first table reported zero callbacks and that number was
meaningless. SwiftTerm instead accumulates a dirty range that the embedder
**polls** with `getUpdateRange()` / `clearUpdateRange()`. The delegate carries only
out-of-band events: the alternate-screen switch, the OSC 7 cwd, the title, and
bytes to write back.

This is good news, and it is why measurement 5 is survivable. Polling *is* the
coalescing, and it collapses the work by three orders of magnitude:

| poll interval | dirty rows to repaint, over 32 MB |
|---|---|
| per 1 KB chunk | 1,179,666 |
| per 64 KB chunk | 18,468 |
| per 1 MB chunk | 1,188 |
| **at 60 Hz, 28 MB through a real pty** | **4–21 frames, 144–792 rows total** |

Twenty-eight megabytes of `cat` costs the grid **twenty-one frames**. The pane's
redraw cost is a function of its poll rate and nothing else — not of how hard the
shell is trying.

### 4.3 The unbounded stream is the one place the chain does not hold

The two shapes differ, and not in the direction the throughput column suggests:

| shape | end-to-end | peak queued | peak footprint |
|---|---|---|---|
| inline parse (drain thread parses) | 78.0 MB/s | 0 | 40.72 MB |
| unbounded queue (drain enqueues, consumer parses) | 91.8 MB/s | **18.33 MB** | 29.31 MB |

The queue is faster precisely *because* it cannot push back: the drain thread
never blocks on the parser, so the pty never blocks on the drain, so 18 MB of a
28 MB `cat` piles up in memory before the consumer catches up. At 28 MB that is
survivable. It scales linearly with the size of the file, and `cat` of a large
file is the pre-registered case *because the operator does it by accident*.

**The spec's "unbounded stream" needs a bound**, or the drain thread needs to
parse inline and let the pty block — which is what a terminal emulator classically
does, costs 15% of throughput here, and is the only one of the two that cannot be
made to exhaust memory. §6 recommends.

*(Peak footprint is only meaningful from an isolated `termspike pty` run; under
`all` the allocator is already warm from measurement 1 and the same work reads
0.14 MB instead of 40.72 MB. The numbers above are the isolated run.)*

### 4.4 Three small things the pane must handle itself

- **The exit code is dropped, as the spec says.** `oscSemanticPrompt` switches on
  `"C", "D"` together and parses the remaining fields as `k=`/click options, so the
  `42` in `OSC 133;D;42` reaches no public API. Confirmed by feeding it and finding
  nothing. Capturing it is Wakil's, and since `C` and `D` are indistinguishable at
  every public seam, Wakil must scan the byte stream for the marks itself rather
  than ask the terminal about them — which pairs with 4.1.
- **`hostCurrentDirectory` returns the raw URL**, `file://localhost/Users/operator/orca`,
  not a path. The header that carries the live cwd has to parse it.
- **OSC 133 is discarded entirely under the alternate screen.** `oscSemanticPrompt`
  opens with `guard !isCurrentBufferAlternate`. For the normal case this is
  harmless — the shell emits `C` before the program starts and `D` after it exits,
  both on the primary screen — but it means User Story 16's *"four minutes in `vim`
  still leaves a block"* rests on the mark landing outside the switch, and a program
  that enters the alternate screen before the shell's `C` would leave no block at all.

## 5. What this does not answer

- **Nothing about a hardened, signed app.** Every measurement here is a plain
  `swift build` binary run from a terminal. The entitlement implications of
  spawning a PTY from a hardened app are 2b-vii and externally blocked; this probe
  does not touch them.
- **Nothing about `zsh`.** The pty leg runs `bash --noprofile --norc -i` only. The
  spec names both, and the generated rc is per shell.
- **Nothing about the generated rc.** These marks were fed as bytes, not emitted by
  a real shell integration. #38 measured a real shell round trip; this probe
  measured the parser's response to marks, not a shell's ability to produce them.
- **Nothing about `^C`, resize or reaping.** #38 established those and this probe
  did not re-measure them.
- **Nothing about the mirror.** The harness stream is not in this chain.
- **Construction B was measured with two colour runs per row**, not with arbitrary
  per-cell SGR. A row that alternates attributes every cell is a worse case than
  anything here, and B is the construction that would feel it.

## 6. Recommendation

1. **Draw the live grid as one `Text` per row (construction B), not one per cell.**
   It clears 120fps by 1.7–3.4× and keeps the per-cell selection, hit-testing and
   accessibility a `Canvas` gives up. Reserve C for the case where B stops holding
   under real SGR density — §5's untested worse case.
2. **Drive redraw from a polled `getUpdateRange()` at the display's frame rate**,
   never from the feed. There is no push to drive it from anyway (4.2), and polling
   turns 28 MB of `cat` into 21 frames.
3. **Do not coalesce bytes before feeding the parser.** Chunk size does not move the
   rate, and the pty caps reads at 1,024 bytes regardless of the buffer offered.
4. **Capture each block at its `D` mark into Wakil's own storage; do not reconstruct
   the history from SwiftTerm's buffer.** The marks do not outlive the scrollback
   cap (4.1), and Wakil must scan for the marks itself to get the exit code anyway
   (4.4).
5. **Bound the drain.** Either parse inline on the drain thread and let the pty
   block — 15% slower, and it cannot exhaust memory — or keep the queue and cap it.
   The spec's word "unbounded" should not survive this measurement unqualified.
6. **A starting bound for the scrollback, now that it is a memory question:**
   ~112 bytes per held output row measured, so **1,000 blocks × a 1,000-line cap is
   ~86 MB per pane** and 200 × 500 is ~18 MB. Neither is a drawing problem at any
   size measured. The spec says the bound is reported on screen; these are the
   numbers it would report.

## 7. What this changes in [#72](https://github.com/yehia-khalil/rafiq/issues/72)

Two sections, both in *Implementation Decisions*, plus one line elsewhere:

- **The dependency** — *"marks that survive scrollback"* is true only inside the
  scrollback window, and the block history cannot be derived from the buffer (4.1).
- **`TerminalStore`** — *"a plain thread reading available data into an unbounded
  stream"* is the shape that queued 18 MB on a 28 MB `cat` (4.3). The shape is
  right; the word *unbounded* is the defect.
- **`phase-log.md` line 1332** — *"marks survive scrollback"*, taken from SwiftTerm's
  own doc comment when the engine was read. It is where the claim entered this
  repository, and it is the line a later reader would find first.

**No numbered decision is affected**, and no grilling ticket is owed. 4.1 and 4.3
are a probe doing the job the spec gave it — *"2c-ii's probe changed three sections
of its own spec before a line was written"* — not a ruling reopened. Per
`docs/agents/workflow.md`, a spec and a probe that disagree are not resolved by a
silent edit: these go into the binding design spec, which takes this issue **plus** this document as its
input.

## 8. The harness

`scripts/probe/termspike`, kept in the repository rather than thrown away, for the
same reason `sttspike` was: two of its findings change the spec, and 2c-iii's build
will want to re-run measurements 5 and 6 against the real pane rather than take
this document's word for it.

```
cd scripts/probe/termspike
swift build -c release

./.build/release/termspike parse     # 1 — parser feed rate
./.build/release/termspike blocks    # 2 — mark survival and walk cost
./.build/release/termspike gaps      # 3 — what SwiftTerm does not return
TERMSPIKE_REPO=../../../app TERMSPIKE_BIGFILE=/tmp/termspike-big.txt \
  ./.build/release/termspike pty     # 4 — the whole chain on a real shell
./.build/release/termspike grid      # 5 — the live grid, three constructions
./.build/release/termspike history   # 6 — the block history
./.build/release/termspike all       # all six
```

`TERMSPIKE_BIGFILE` wants a large text file; the run above used 28 MB of 96-byte
lines. **Not built by `make`** — it pulls SwiftTerm, which `WakilKit` does not
depend on until this sub-phase ships.

Read §4.2 before trusting any callback-shaped number from a future edit of this
harness: the first draft of measurement 1 counted a delegate method that does not
exist, and reported zeroes that looked like a result.
