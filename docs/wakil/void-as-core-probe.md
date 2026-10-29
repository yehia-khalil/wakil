# The void as the Core — a design probe

**Run:** 2026-09-09 · **Machine:** MacBook Air M3, macOS 26.6.2 · **Probe:**
`/tmp/voidcore-spike`, throwaway, outside the repo · **Renders:** `.context/void-as-core/`
(12 PNGs, gitignored, same convention as `phase-2b-probe.md`'s capture)

Run immediately after 2b-ii's first hands-on launch, which is also the first time anybody
looked at the phase's output. The question came from the operator and it is a good one, so
it is written down before it is acted on.

---

## 1. What prompted it

2b-ii shipped `design-language.md` §4's Core: an iridescent sphere, four states, the
interface's only bright object. On the first launch it was **dead centre of the window at
44% of its height, sitting on top of the open pane** — see `.context/void-as-core/` and the
commit *"Fix: the Core covered the pane underneath it"*.

That is not a shader bug. §4 states the *goal* — "peripheral legibility ... knowing what
Wakil is doing from the corner of the eye" — and never turns it into a position or a size,
and neither did 2b-ii's spec. So the shader kept the defaults from the Metal feasibility
probe, which drew the sphere alone in an empty window with nothing to occlude. Nothing in
the phase's headless verification could have caught it: the acceptance captures had no pane
in them either.

It was fixed by moving the Core bottom-centre at a third of the radius. Then the operator
asked the better question:

> *"Why not make the void be the core and not a sphere? Maybe it glows and radiates as it
> speaks or listens — or have the core sphere pop up upon request."*

## 2. The three variants rendered

Every render composites a mock pane, because the absence of one is exactly why the original
defect survived to a hands-on run.

| | |
|---|---|
| **A** | The sphere as it ships, for reference. |
| **B** | **The void is the Core.** No sphere at all. The room carries the state. |
| **C** | The void carries ambient state; a small sphere is *summoned* for listening and speaking only. |

Twelve images at 1200×800: A idle; B at all four states in staging, each at the animation's
high and low point; B thinking in production; C listening and speaking.

## 3. The rule the variants had to obey, and the finding that matters

**Hue belongs to the environment. Motion and intensity belong to agent state.**

This was the objection that could have killed the idea. `design-language.md` §5 already
spends the void on environment — violet normally, red on production — so making it also
carry agent state puts two independent variables on one surface. Wakil speaking while
pointed at production would have to be green and red at once.

Splitting the channels resolves it: the environment owns the hue, the agent owns the
movement. A red room that breathes faster is production-and-thinking, unambiguously.

**`B-void-thinking-production-high.png` is the finding.** It reads as unmistakably a
production room *and* carries the state motion inside it. The two variables coexist. The
strongest objection to the operator's idea does not hold.

## 4. What each variant is actually worth

**B's win is structural, not aesthetic.** Across all eight B renders the pane is never
touched, at any state, at either extreme of the animation. The occlusion problem is not
solved — it stops being possible. That is worth more than a placement constant that has to
be re-tuned every time a pane moves, and §1's fourth principle (*data is never
low-contrast behind a data surface*) becomes structurally guaranteed rather than a
constraint the layout has to keep honouring.

**B's weakness is discrete state legibility.** Put `B-void-idle-staging-low.png` beside
`B-void-thinking-staging-high.png`: distinguishable, but only just, and what distinguishes
them is brightness — one channel doing four jobs. In motion it should read better, because
idle breathes at 5.4s and listening at 1.5s and *rate* is legible where amplitude is not.
A still cannot show that, so this remains partly untested. See §6.

**C is the reviewer's preference and was not chosen.** The room carries ambient state and a
sphere appears only for the states that need a precise answer and an anchor — which are
also exactly the states where §9's thought thread needs something to rise out of and §12's
waveform needs something to sit beneath. **The operator chose B**, with a slow idle breath
retained rather than a motionless idle.

## 5. What B costs

Recorded plainly, because B is a charter-level change and these are its bill.

- **`design-language.md` §4 is rewritten, not amended.** It is titled "The Core" and
  specifies four states on one object. Under B there is no object.
- **§1's third principle loses its mechanism.** *"One bright object. The Core is the only
  genuinely luminous thing on screen — that is what keeps a living interface calm."* Under
  B nothing is luminous, which arguably serves the goal better than the mechanism did, but
  the principle has to be rewritten to say so.
- **§9 and §12 lose their anchor.** The thought thread rises *out of the Core*; the
  listening waveform and live transcription sit *beneath it*. The bottom edge, where the
  violet bleed rises, is the natural replacement and reads well — the thread rises out of
  the glow — but it is a decision, not a detail.
- **The void can no longer be paused.** 2b-ii's §2.2 makes "a still window draws zero void
  frames" the phase's real battery saving, and a breathing idle spends it. A 5.4s breath
  does not need 120fps, so capping that layer far lower recovers most of it. This is the
  first thing B's spec must decide.
  **This bullet is wrong and 2b-iv's spec §5 corrects it.** It compares the void layer
  against itself and ignores the layer beside it: `CoreView` is continuous at
  `preferredFramesPerSecond = 120` and paused only on occlusion, so an idle 2b-ii window
  already drew a full-rate sphere of a much heavier shader. An idle B window draws 15fps of
  one cheap one. B is roughly a four-fold idle saving, not a cost — deleting the second
  layer pays for the breath outright.

**What B deletes**, which is the other half of the ledger: `CoreView`, `Core.metal`, and the
second Metal layer entirely — all of which exist only to keep a front-layer object from
getting in the way. `CoreState` survives as the thing that drives the void. **Corrected
after the fact:** the near-plane parallax and the occlusion-pause logic were *not* deleted
with them. `docs/superpowers/specs/2026-09-09-void-as-core-design.md` §4 rescues the near
plane for the thought thread rather than orphaning it, and §5 carries the occlusion pause
onto the surviving layer unchanged, reasoning included. Only the hit-testing opt-out went
with the object it was written for. 2b-ii's spec §2.1 justified two Metal layers *because*
the Core sits in front of the panes; with no Core, one layer is correct.

## 6. What this probe did not establish

- **Whether four states are distinguishable in motion.** Stills cannot show that a 0.42s
  pulse and a 5.4s breath feel completely different. Judging B properly wants a short screen
  recording, which is a second, cheap probe and should precede B's spec.
- **Whether it reads as calm.** §1 warns that a single bright object works *because*
  everything else stays quiet. A whole field in motion could be a strobe you cannot look
  away from. Nothing here tests that, and it is the risk B carries that A never did.
- **The numbers.** The probe had to invent every motion parameter, because the design
  language gives none for a room: speaking's amplitude, thinking's 12s turnover, listening's
  tightening factor. They are listed in `.context/void-as-core/spike-notes.md`. Speaking's
  amplitude is the one that decides the strobe question and wants the operator's own eye.

## 7. Status

**A decision, taken 2026-09-09.** B is specified as
`docs/superpowers/specs/2026-09-09-void-as-core-design.md` and implemented as sub-phase
2b-iv; `north-star.md`'s open question 11 is closed and `design-language.md` §4 is
rewritten.

Five choices were made in the design review that this probe did not settle: B is its own
sub-phase, meant to be walked only **after** 2b-ii's acceptance run had recorded a human
judgement of the sphere it replaces. **That gate was never walked** — the plan that
executed the sub-phase ran straight through and deleted the sphere first; see
`docs/wakil/phase-2b-iv-acceptance.md` §0 and `docs/wakil/north-star.md` §8 for the honest
record and what remains recoverable. "The Core" keeps its name and means
presence rather than an object; each state's frame rate follows its own cadence; §9's
thread and §12's waveform anchor to the bottom edge **with the bleed reacting to them**;
and speaking's 0.42s pulse is contained by confining it to the lower bleed rather than by
holding its amplitude down.

§6's three unknowns are not closed by that decision. Two of them — whether four states are
distinguishable in motion, and whether a room in motion reads as calm — are numbered checks
in `phase-2b-iv-acceptance.md`, judged against `make captures-motion`. The third, the
invented numbers, is why they all live in one file.

Nothing in 2b-ii was reverted. The Core shipped bottom-centre and small, which was correct
under A and harmless under B, since B deletes it outright.
