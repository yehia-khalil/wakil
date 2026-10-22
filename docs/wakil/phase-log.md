# Wakil — Phase log

**Status:** living document · **Split out of `north-star.md` §8 on 2026-09-15** · **Owner:** Yehia Khalil

What each phase and sub-phase delivered, how it was split, what its acceptance walk
found, and what was left owed. The charter's §8 keeps the **status table** — the thing
you schedule from — and links here for everything else.

**Why this is not in the charter.** At the split this section alone was 6,515 words, 47%
of the charter, and it is append-only by nature: every walk adds a record. A document
that grows on every commit cannot also be the one you re-read to decide what is true.
Keeping the status table there and the narrative here lets both do their job.

**This is a log.** Entries are historical records. Correct them when they are wrong, but
do not tidy them into a summary — the walk narratives are the most-cited evidence in the
repository precisely because they say what actually happened.

---

## The 2026-09-15 split

*Moved out of the charter 2026-09-16, when adding `2d-i` pushed it to 4,140 words against
its own 4,000 limit. The charter's rule is that the overflow goes to a log; this is the
overflow, and moving it rather than raising the limit is the rule working.*

**Split 2026-09-15, into an index and three logs.** Sections 6, 7 and 8 were 87% of the
document and all three grow on every phase. They now live beside it:

| File | Holds | Charter keeps |
|---|---|---|
| **`decisions.md`** | the 22 decisions in full | §6 — one line each, the call and its reversal condition |
| **`open-questions.md`** | the 15 questions and their reasoning | §7 — number, question, what it blocks, status |
| **`phase-log.md`** | what each walk found, how phases split, what is owed | §8 — the status table you schedule from |

**What did not change: the section numbers, and the entry numbers.** §6 is still
"Decisions", §8 is still "Phase map", Decision 20 is still Decision 20. Citations across
this repository are overwhelmingly by number — 181 *"Invariant N"*, 108 *"Decision N"*,
43 *"open question N"* — so the split broke none of them, and the 36 that cite a charter
*section* still land on the section that now indexes what they were pointing at.

## What the status table points at

**One thing this table is trying to make impossible to miss.**

**2d is unstarted, and Decision 1 rests entirely on it.** *"Voice justifies it … Reverse
if: voice gets cut, at which point a VSCode extension becomes overwhelmingly cheaper."*
Phase 2 was ordered by risk retired, and the risk the largest architectural commitment
hangs on is scheduled last. Every week it slips, Decision 1 is unfalsified rather than
validated. As of 2026-09-15 it is also the **only** thing in Phase 2 that is neither built
nor externally blocked, so it is no longer competing with anything for the next slot.

**2026-09-16 — "ordered by risk retired" is a heuristic, not a rule, and this log should
stop citing it as though it binds.** Asked directly whether the principle still governs
the schedule, the operator answered *"not necessarily."* It is recorded here because two
places in this file and the paragraph immediately above argue *from* it, and an argument
resting on a rule nobody is bound by is the kind of thing that survives unexamined for
months.

**What this does not change: 2d still goes next.** But for a different and smaller reason
than the one above gives. `2d-stt-probe.md` is half a day and closes open question 10 with
evidence; its outcome changes 2d's size by a large factor — if Apple's `SpeechAnalyzer`
wins, 2d loses a model download, a Core ML dependency and a build-form decision
altogether. Committing a sub-phase slot before knowing that is committing blind. **That is
a cost argument, not a risk-ordering one**, and it would hold even if the phases had been
ordered by something else entirely.

**What it does change:** after the probe, `2c-iii`, `2c-iv`, `2c-v` and the rest of 2d
are scheduled on their merits rather than on a stated ordering. Nothing in §8 should be
read as owing its position to the principle any more.

## 2026-09-21 — pane layouts learned which conversation they belong to, and the walk overturned the design that got them there

**Walked 2026-09-21**, against `conversation-layouts-acceptance.md`. The operator's
verdict was one word — *good* — and the record below is that report plus what was
verified on disk, not a per-check transcript taken at the time.

#142 shipped in four tickets: #146 keyed the three layout layers on one `LayoutScope`
value instead of a bare project string; #147 put the conversation's **lineage root** in
it, so resuming restores the workspace the conversation happened in; #148 routed a
session switch through the same orchestrator a project switch uses; and **#160 exists
only because the walk rejected #142's own user story 12.**

### What the walk found

**The step that failed was the one asserting the design.** Step 10 said a project switch
inside a conversation must NOT swap the panes — one conversation, one workspace,
whichever project you visited it from. The operator switched to a project with no
sessions at all, found the previous project's panes still on screen, and ruled the other
way inside a minute. An arrangement is now keyed by conversation **and** project (#160);
the amendment is a dated comment on #142.

**A passing test is not a correct one.** Story 12 was implemented deliberately, argued at
length in a hand-written `Hashable` conformance, and pinned by three tests that named it
in their own titles. Everything downstream was faithful to it. What none of that could
do is notice that the ruling was wrong — and the runbook, written from the spec, carried
the error to the walk as an expected *pass*. **A runbook inherits the spec's mistakes;
the walk is the only rung that does not.** That is the strongest argument this repository
has yet produced for the rule that a phase is not met until an operator has walked it.

The three tests were **inverted rather than deleted**, each carrying a dated note saying
what it used to assert and why that changed, so the change of mind is legible in the diff
instead of looking like coverage that evaporated.

### The shape of the two defects, which is worth more than the repairs

**#148 — a value read between the two halves of a swap is not a value.** Pointing the
stores at an incoming conversation takes two actor hops and a file read, and in between
`LayoutStore` answers with an *empty* arrangement filed under a scope nothing has restored
yet. `refreshLayout` runs off the back of every dispatch the observation pump sees —
including the `session_record_parent` that `resume` itself makes — so it landed squarely
in that window, compared the outgoing conversation's panes against that empty canvas,
called it a change, and wrote it. Because a conversation's save also refreshes the
project's seed, **one switch emptied two files**: the conversation's own, and the seed
every later conversation in that project opens on. The arrangement was gone from disk
before the read meant to restore it had run.

The repair is a flag naming the window (`layoutSwapInFlight`) and a flush of the outgoing
arrangement inside it. The generalisable part is the first sentence: a mid-transition read
is not state, and anything that commits on a diff must be told when a diff is meaningless.

**#161 — two files written by one call wanted two different rules.**
`LayoutPersistence.save` refreshed the project's seed from every conversation write,
unconditionally, including one with no panes. A conversation carried into a project it had
never been arranged in wrote that project's seed as `{"panes": []}`. Found by **reading
the files after the walk passed**, not during it: the canvas was correct throughout and
nothing on screen was wrong. A conversation's own file must record "nothing was open" —
that is a state #142 names outright and it has to survive a relaunch — while the seed must
never say it, because the seed answers "what should the next conversation here start
from" and nothing is never that answer.

**Both defects are the same sentence one layer apart: an empty canvas is a legitimate
thing to hold and an illegitimate thing to propagate.**

### What the walk did not establish

- **Reclamation.** #142 defines when an arrangement becomes eligible to be dropped and
  builds no sweeper. The layout directory grows.
- **A long fork chain.** Step 4 resumed three times, which is what an afternoon affords;
  depth, cycles and self-parents are pinned only in `sessions_lineage_test.go`.
- **Files under the pre-#160 path.** `<org>/conversations/<root>.json` is no longer read.
  Two such files exist on this machine and were left where they lie, per "reclamation is
  by absence, not by deletion"; the conversations open on their project's seed instead.
- **Two windows.** One window is assumed throughout. Two writing one layout file was never
  reasoned about, and the walk began by quitting a second window for exactly that reason.

### A gate finding, recorded because it changes how the gate is read

`make app-test` was run fourteen times across these three tickets. The failing set **tracks
machine load**: three names on a quiet machine, eight with `Wakil.app` running alongside,
and fourteen immediately after killing it. Every name beyond the stable three is in
`TerminalStoreTests` or the shell half of `OrgSwitchTests` — tests that spawn a real PTY
and wait on it in real time. Not one was ever in the layout, scope, persistence or
conversation suites, which is what let a fourteen-failure run mid-branch still be read as
clean.

The practical rule, now on #127: **do not run `make app-test` with `Wakil.app` open, or in
the seconds after quitting one.** Both roughly triple the failing set, which is precisely
the condition under which a real regression would be invisible — the failure mode #127 was
opened to prevent.

## 2026-09-17 — ⌘P's partiality got a slot, and Invariant 4's history paid for it

Triage of [#47](https://github.com/yehia-khalil/rafiq/issues/47), which arrived as three findings against ⌘P and leaves as one.
The other two were checked against the code and did not survive it.

### Two of the three had already shipped

**`provider` is not discarded.** It is the session row's entire subtitle, and has been
since `55a4d84` (2026-09-10) — six days before the ticket was filed. The claim came in
verbatim from [#37](https://github.com/yehia-khalil/rafiq/issues/37)'s body, which reads *"it discards `provider`, `cwd`, `skipped` and
`unreadProviders`"*; that sentence is wrong about the first of the four, in both places.
Corrected in #47 rather than in #37, which is closed and is a dated record.

**Lineage is not invisible either.** `sessionItems(from:)` appends `resumed N×` when it
collapses a fork chain. What is absent is the *parent's identity*, and nothing wants it:
#37 cut the pane that would have shown a chain, and open question 5's amendment is
satisfied by the chain existing under a fresh Wakil-minted id, not by it being browsable.

**What stands is the partiality**, and it is worse than the ticket argued. `skipped` is
not an exotic failure: a transcript that offers no `cwd` to confirm project membership
against is *deliberately* dropped and counted (`sessions.go`'s stage-2 confirmation, the
fix for the cross-project leak), which is exactly a session started moments ago. The row
most likely to be wanted is the row most likely to be silently missing.

### The row budget, and where a note goes

The restyle ([#70](https://github.com/yehia-khalil/rafiq/issues/70)) had already ruled the row: kind column, title, one dot-separated
subtitle. So the session subtitle is `provider · resumed N× · root`, the root shown only
when **the listing** spans more than one — computed from the rows the function already
holds rather than from `ContextStore.rootPaths`, which keeps `sessionItems(from:)` pure
and fixture-testable as its own doc comment intends.

**The note cannot go on the window's status line**, which is where every other ⌘P source
reports its failures: it is drawn outside the plane, under the same full-window dimmer the
plane sits on, so the operator would be told the list is incomplete everywhere except
where they are reading it. `Palette.dc.html` gains a line above the key hints — cool white
stepped down, not a warning hue, because §5's three are semantic and an unreadable store
is a fact about the search rather than about the work. It **names** the providers rather
than counting them; `UnreadProviders` is a `[]string` for that reason.

**Until the restyle ships in code the note goes to the status line anyway**, joined with
the projects and providers notes. The defect is discarding the fields, not where the
sentence renders, and holding a confirmed bug for an unscheduled restyle trades a real
lie for a tidy one.

**No number.** It is a rule about one surface, not the system, and with the note on the
status line for now, recording *"not the status line"* as a decision would be one the tree
contradicts on day one. The bar is the standing three and it clears only two.

### The artboard was corrected against the code, not the other way round

`Palette.dc.html` drew the session subtitle as `session_01MUwNSH · 2h 14m` — an id and an
age, neither of which the subtitle has ever carried. The id is the *title*'s last-resort
fallback (`title → firstPrompt → id`) and no age is computed anywhere. `docs/agents/domain.md`
already rules this case: where a spec and the shipped code disagree, the code is what
ships. Annotation `palette-partiality` on the canvas records both that and the missing
slot.

### Invariant 4's history, moved out

§9 gains two terms the corpus used everywhere and defined nowhere — **Session**, and
**Partiality** for the `Skipped`/`UnreadProviders`/`Truncated` discipline the codebase
takes seriously and had no word for. That put the charter back over 4,000, one pass after
the [#64](https://github.com/yehia-khalil/rafiq/issues/64) entry below brought it under, so it is paid for the same way and out of the
block that entry named as next.

Invariant 4 keeps the rule, one line on what is delivered and what is owed, and a pointer
here. Moved: the 2026-09-06 config-dir amendment and why the original text structurally
forbade two accounts on one org; that `register-provider.sh` pins `WAKIL_ORG` inside a
config dir under five fixed server names, so a config dir carries exactly one org, and
that since 2026-09-07 `wakil provider add` refuses a config dir another provider already
claims, making that an explicit boundary that can no longer fail silently; that the route
to the owed half changed with the Phase 2a design, from namespacing server names per org
to passing `--mcp-config` per session with `WAKIL_ORG` and `WAKIL_PROVIDER` set at launch,
which removes the config dir from org identity altogether, arriving with the Phase 2a
harness while the CLI path keeps its guard; and the original reproduction, *"One config
dir serves one org"* in `phase-1-acceptance.md`.

Moved with it, from 2026-09-15 and sub-phase 2b-viii: the switch is operator-initiated and
never config-derived — `ctx_create_org` and `ctx_adopt_provider` are both
`operatorOnlyActions`, the mechanism already denying `ctx_set_provider` — and
`invalidateForOrgChange()` clears every credential reference before the new org's client
starts, so the text did not need to change to cover it.

| Change | Words |
|---|---|
| §9 gains **Session** | +40 |
| §9 gains **Partiality** | +55 |
| Invariant 4's history block, moved here | −160 |
| Header: the §4 move's "next candidate" line, now spent | +22 |

**`north-star.md` is 3,939 words.** The check is the one the header states:
`wc -w docs/wakil/north-star.md`.

## 2026-09-17 — three rulings earned a number, and Invariant 6 paid for them

The closing pass of map #36 ([#64](https://github.com/yehia-khalil/rafiq/issues/64)), and the map's terminal node. Thirteen tickets had each written their answer into this
file as they closed; this entry decides which of those answers earn a **permanent number**
in `decisions.md` or `open-questions.md`, and what the map leaves owed. Numbers were
deliberately withheld until now: they are cited by address across the specs, so assigning
one mid-effort and reversing it later leaves a hole.

### The screen: three of twelve

The bar is the standing one — **hard to reverse, surprising without context, the result of
a real trade-off.** Twelve candidates went in. Three came out with a number.

- **Decision 23 — SwiftTerm's headless engine, and nothing else, as `WakilKit`'s first
  external dependency** (from [#43](https://github.com/yehia-khalil/rafiq/issues/43)). All three parts, plainly: a dependency in a package that had
  none is hard to remove once a pane is built on it; *why is there a vendored terminal
  emulator, and why not its view?* is exactly the question a reader will ask; and the
  trade-off was measured rather than assumed — the gap between a 300-line SGR parser and a
  terminal is the alternate screen, and the alternate screen is the whole emulator.
- **Decision 24 — a pane's readable state is a discriminated union keyed by `kind`** (from
  [#40](https://github.com/yehia-khalil/rafiq/issues/40)). This is the contract every future pane kind inherits, on an **agent-facing**
  wire shape, and it scopes the always-present-key rule rather than abandoning it.
- **Decision 25 — a write's price rides on the action, not on its kind** (from [#63](https://github.com/yehia-khalil/rafiq/issues/63)). A
  fourth `ActionKind` was proposed, verified against the code and rejected because
  `isMutation` would have gone silently false — a safety chokepoint failing quietly is the
  one failure mode `writeGate` exists to prevent.

**Three more amend an entry that already exists rather than taking a number.** Decision 8
gains the API cardinality and the auth-header shape ([#67](https://github.com/yehia-khalil/rafiq/issues/67)) — it is the entry that claims
the DB/HTTP symmetry, so that is the address the correction belongs at. Decision 18's
closing note, *"it would be `WakilKit`'s first external dependency"*, is struck: it was
written about WhisperKit, which lost its probe and became selectable rather than default,
while 2c-iii ships before 2d. And Decision 7 gains a dated note, no amendment, recording
that **no UI surface consumes it for the whole of Phase 2** — two tickets in a row
re-derived that, and both were answered by deleting the root from the question.

**Seven earn nothing, and that is the pass working.** [#37](https://github.com/yehia-khalil/rafiq/issues/37), [#41](https://github.com/yehia-khalil/rafiq/issues/41), [#49](https://github.com/yehia-khalil/rafiq/issues/49), [#50](https://github.com/yehia-khalil/rafiq/issues/50), [#53](https://github.com/yehia-khalil/rafiq/issues/53), [#61](https://github.com/yehia-khalil/rafiq/issues/61) and
[#42](https://github.com/yehia-khalil/rafiq/issues/42)-as-a-number are schedule, bookkeeping, visual design and one bug fix. Their homes are
this file, `design-language.md` and §8, and each already has its entry. A map that
promoted ten of its own rulings would be telling the reader that nothing it decided was
ordinary.

**The one that was genuinely close: [#39](https://github.com/yehia-khalil/rafiq/issues/39).** Its ruling is a *refusal*, not a write earning
its way in, so it is the wrong shape for `decisions.md`. But it rests on a fact a future
reader will otherwise re-derive backwards — **the agent already has a bare shell**, so an
agent-reachable `term_run` would buy it the organisation's *credentials*, not *reach*, and
the refusal defends Invariant 4 rather than the machine. That fact is now one sentence
inside Invariant 6's refusals list, where it is load-bearing instead of trivia.

### Invariant 6 was the budget, and it was also the problem

The charter stood at **4,025 words against its own 4,000-word limit** and this pass wanted
to add roughly 250. Every ticket since [#39](https://github.com/yehia-khalil/rafiq/issues/39) has budgeted against that breach, and [#40](https://github.com/yehia-khalil/rafiq/issues/40)
declined to add vocabulary because of it.

**Invariant 6 alone was 474 words — 12% of the whole charter, for one rule whose text is a
single sentence.** The other ~450 were three per-adapter justifications, each written into
§4 at the moment its write earned in. That is precisely the failure mode the charter's own
header warns about: *"past that it has become a spec and will rot."* An invariant that
grows a paragraph per adapter is a spec with a rule at the top of it.

So §4 took the move §6, §7 and §8 already took on 2026-09-15: **the rule and a table stay;
the justifications moved to `decisions.md`.** Citations survive because they were always by
date — *"Invariant 6's 2026-09-14 amendment"* — never by location. The table is three rows,
the refusals are four lines, and both are now readable in one glance, which the 474 words
were not.

**What the refund bought, all of it:**

| | Words |
|---|---|
| Invariant 6 restructured — 474 down to 172 | **−302** |
| Invariant 7's per-adapter exception | +74 |
| §6 index rows for Decisions 23, 24, 25 | +145 |
| §9 gains **Write price** | +47 |
| §7 index row for question 16 | +29 |
| Header: the §4 move recorded, the limit rationale re-costed | −12 |
| §6's *"read the third column first"* paragraph, moved to `decisions.md`'s header | −43 |

The limit rationale had to be re-costed rather than merely trimmed: it derived the
document's floor from *"22 decisions, 15 questions and 22 phase rows"*, and this pass
changed two of those three numbers.

**`north-star.md` is 3,982 words.** It has been over its limit since 2026-09-14 and it is
not over it now. Invariant 4's history block, 222 words, is the same shape and is the next
candidate; it was deliberately left, because one structural repair per pass is enough and
this map never touched Invariant 4.

### Invariant 7 had no exception and needed one

[#63](https://github.com/yehia-khalil/rafiq/issues/63) found the conflict and left it owed: *"only typed confirmation may execute one"* has
no environment clause, so a spoken staging write executes on no keystroke and breaches it.
The resolution is that **the charter already contradicted itself** — Phase 2's exit
criterion is a spoken chain that ends in *"then call the confirmation endpoint with that
ID"*, which is a write. So the exception is recorded rather than invented: a write's price
may be *allow*, and then voice does execute it. Two are: the HTTP send outside production,
and the Jira transition everywhere.

### Question 16, and a word that means two things

§9 defines **Connection** as an authenticated account at the *organization* level. But
`wakil-db`'s tool schemas say *"connection name"* for a database, which is
*environment*-level, in seven places. [#67](https://github.com/yehia-khalil/rafiq/issues/67) hit this while ruling that an environment
holds several APIs, avoided widening it by saying *API entry* throughout, and left the
disposition here.

**It becomes open question 16 rather than staying a finding in this file.** It blocks
nothing, which is the argument for leaving it — and the argument against. A term drifting
quietly in shipped schemas is exactly what an index of open questions is for; a finding
inside one dated entry among sixty is not visible to anyone who is not already reading
that entry. Its three honest repairs are recorded with their costs, and the cheapest moment
to pay is whenever `wakil-db`'s schemas are next edited for another reason.

### Question 13's argument is spent

Closed since 2026-09-14, and the scheduling it argued for was **executed** — 2b-viii met
2026-09-15, before a line of 2c-iii. Two facts inside it have gone stale: it counts 2c-v
among the panes whose teardown would need retrofitting, and 2c-v was cut; and it reads as
scheduling advice for a sub-phase whose order has since been ruled outright by [#61](https://github.com/yehia-khalil/rafiq/issues/61). Both
are left standing with a dated note, per this file's rule that a closed entry is a record
of what was asked and what answered it, not a tidy list.

### The debt this map leaves 2c-iii

**Six doc comments are wrong, or will be the moment 2c-iii lands.** Every terminal ticket
found one and deferred it, because the map plans and does not edit Swift. They were
scattered across five entries of this file, which means a builder starting 2c-iii would
have found at most the one in front of them. They are gathered here, and **2c-iii's exit
criterion now has a sixth clause: the sub-phase does not close while any of them is still
false.**

A wrong doc comment is worse than a missing one. The next agent reads it and believes it —
which is not hypothetical here: [#39](https://github.com/yehia-khalil/rafiq/issues/39)'s own ticket was written on a false premise it
took from one, and [#40](https://github.com/yehia-khalil/rafiq/issues/40) found `MCPServer.swift:687`'s justification falsified by a class
sitting one file over.

| Symbol | What is wrong | Found by |
|---|---|---|
| `ActionKind.mutate` | *"Gated everywhere, blocked in production"* — false twice over: [#39](https://github.com/yehia-khalil/rafiq/issues/39) added a `.control` action the comment's framing does not cover, and Decision 25 moves the gating to the action's price, so `.mutate` no longer implies either half | [#39](https://github.com/yehia-khalil/rafiq/issues/39), worsened by [#63](https://github.com/yehia-khalil/rafiq/issues/63) |
| `PaneStore.swift:368` | Describes `Contents` as one shape; Decision 24 makes it an enum over kinds | [#40](https://github.com/yehia-khalil/rafiq/issues/40) |
| `MCPServer.swift:233` | Describes `read_pane`'s snapshot as having a fixed key set; Decision 24 scopes that to the kind | [#40](https://github.com/yehia-khalil/rafiq/issues/40) |
| `MCPServer.swift:687` | Justifies the unknown-id non-error with *"`PaneStore` has no registry"* — falsified by `LayoutStore` being one. **The conclusion stands and the argument does not**, so this one is rewritten, not deleted; it now answers `kind: null` | [#40](https://github.com/yehia-khalil/rafiq/issues/40) |
| `autoResumeAfterSwitch` | Claims the collapse hides sessions, then refutes itself mid-sentence; it keeps the newest member, which is what `resume` launches in | [#53](https://github.com/yehia-khalil/rafiq/issues/53) |
| `WriteGate.swift`'s table | Maps kind → answer; Decision 25 makes the price the input, with today's hardcoded pair as the default | [#63](https://github.com/yehia-khalil/rafiq/issues/63) |

**Two more owed items are not doc comments and are named so they are not looked for
twice.** `term_open(path:)` and the terminal's missing scroll action bring [#39](https://github.com/yehia-khalil/rafiq/issues/39)'s account
from two actions to four — that is spec work for 2c-iii, not a number, and 2c-iii's exit
criterion already requires both surfaces to be readable. And `wakil secrets set-api` is
ruled by [#67](https://github.com/yehia-khalil/rafiq/issues/67) and built with 2c-iv.

### A stale row corrected in passing

**§8 was promising two different things were next.** [#61](https://github.com/yehia-khalil/rafiq/issues/61) stripped *"next in 2c"* from the
2c-iii cell on the grounds that **Waits on** names blockers and not sequence — correctly —
but §8's **2d-i** row still read *"— **next**"*, written 2026-09-16 after the STT probe and
before 2d was scheduled after 2c. So the charter said 2d-i was next while [#61](https://github.com/yehia-khalil/rafiq/issues/61) had ruled
2c-iii. The cell now names its blocker, *"the rest of 2c"*, which is what the column is for.

### What this leaves owed

**Nothing.** That is the point of the pass, and it is checkable: the owed pile is either
paid here (the two §4 amendments, the Decision 8 amendment, the SwiftTerm number, question
13's disposition), promoted to a number, ruled out of scope on the map, or written into
the table above with an exit criterion attached to it.

**The map is complete.** Its destination was *a scoping and sequencing ruling for the rest
of 2c, done when each surviving sub-phase's design spec could be written with nothing left
to argue.* Fourteen tickets, thirteen rulings, one pane cut, three numbers. What remains in
its fog is 2c-iv's and 2c-vi's **spec** work — the binding mechanism, the request body,
`ApiClient.dc.html`'s redraw, and open question 15 — which is the next effort and was
always out of scope for this one.

## 2026-09-17 — an environment holds APIs, plural, and the credential was only ever half configured

[#67](https://github.com/yehia-khalil/rafiq/issues/67) asked whether `Environment.API` should
mirror `Environment.Databases`: a list of named entries rather than a singleton. It was graduated
out of [#63](https://github.com/yehia-khalil/rafiq/issues/63), which had proposed copying
`Database.WriteRef` onto `ApiConfig` and was told the grains do not match — SQL write permission
is per named connection, HTTP write permission could only ever be per environment. The credential
half was ruled there; the **cardinality** half was deferred here.

**The answer is yes, and it earns a number** — as an amendment to **Decision 8**, not a new one.
Decision 8 is the entry that claims the DB/HTTP symmetry (*"DB and HTTP have nothing but
environments"*), so the cardinality belongs at that address. An amendment also costs the charter
nothing: `decisions.md` carries no word limit, and `north-star.md` §9's `Environment` definition
(*"Carries DB and HTTP configuration"*) is already true of either shape. Owed to
[#64](https://github.com/yehia-khalil/rafiq/issues/64) as its **eleventh** candidate.

### The ergonomic argument is not the one that decided it

The ticket argued from naming: a project cannot name its own API and a vendor's. True, and not
load-bearing. What decided it is a defect in the artboard the ticket cited as its own evidence.

`ApiClient.dc.html` draws a **one-off base-URL override** — editable in the pane, for one request,
never written to disk — and four rows below it draws the credential, `auth from wakil:initech:api-staging`,
taken from the environment. And `doRequest` takes `base` and `authRef` as **independent
parameters** (`httpclient.go:319`); nothing ties them together. `SecretGet(authRef)` and
`req.Header.Set("Authorization", tok)` know nothing about where the request is going. **So the
override as drawn sends the environment's bearer token to whatever host the operator types.**

That is the guarantee `noRedirectClient` exists to protect, and its comment says so outright:
refusing every 3xx stops *"a server at the environment's own baseUrl redirect[ing] a request to an
arbitrary host … defeating the 'requests are bound to the environment's baseUrl' guarantee this
tool's description makes."* `NormalizeHTTPBase` refusing userinfo in a baseUrl is the same instinct
a third time. **The adapter already refuses a server-driven origin change with the credential
attached; the artboard introduced an operator-driven one.**

A list fixes it by construction. A named entry carries its own `baseUrl` **and** its own `authRef`,
so choosing a target chooses a credential, in one place, and no unnamed origin can be paired with
another's token.

### The operator's fact, which reshaped the list

The list is not primarily for vendor APIs. **Each environment often holds several first-party
backends, as separate domains or subdomains** — `api`, `auth`, `billing` — and they **mostly do not
share a credential**. That killed the environment-level-default option outright and settled the
shape: `authRef` per entry, optional, no default, sharing expressed by naming the same Keychain
entry twice. A shared ref is then a *feature* rather than a hole, because the token still reaches
only origins the config names, which is precisely the property the unnamed override broke.

### The config change, and why it fails loudly

`"api"` keeps its key and becomes an **array**; `ApiConfig` gains a required `Name`, exactly as
`Database` has one. Three options were weighed and the failure mode decided it:

- **Renaming to `"apis"`** would make every existing `"api": {…}` object an unknown field.
  `json.Unmarshal` ignores those, so the environment would report no API configured while pointing
  at a file that visibly configures one — **a silent loss that reads as a bug in the tool**.
- **A custom `UnmarshalJSON` accepting both** would be the **first custom decoder in `wakilcore`**,
  and would make a two-spelling config format permanent to save editing two files.
- **Changing the type in place** fails at `LoadProject` with *"parse project.json: …"*, loudly, and
  also on `wakil project add`, which loads before it registers.

The whole population is **two files** — `~/wakil.acceptance/.wakil/project.json` and
`~/wakil.acceptance2/.wakil/project.json`, both `"api": { "baseUrl": "https://httpbin.org" }` with
no `authRef` — plus `phase-1-acceptance.md:246`. A loud parse error against three known files is
the right price for a config shape change. There is **no config versioning and no migration
machinery** in this repo, and this ruling deliberately does not add any.

### Selection and discovery: `PickDatabase` was already the answer

`PickDatabase` had solved this exactly — name optional, empty allowed **only** when the environment
has one entry, duplicates rejected as ambiguous rather than resolved to the first. `PickAPI` mirrors
it in `apiresolve.go` beside `dbresolve.go`.

That makes `request` gaining an `api` field **additive, not breaking**: the two live single-API
environments keep working with callers that omit it. The *"tool-schema change on a walked Phase 1
server"* the ticket feared is real but backward compatible.

`wakil-http` also gains **`list_apis`**, mirroring `list_databases` — with three subdomains the
agent has no way to learn that `billing` exists, and today it does not need one because there is
nothing to choose. It publishes `name`, `baseUrl` and `authenticated`, and **neither `authRef` nor
`authHeader`**: `DatabaseInfo` publishes neither `Ref` nor `WriteRef` for the same reason — they
are Keychain entry names, of no use to an agent and no business of one.

`authenticated` is **derived** from `AuthRef != ""`, never stored, exactly as `writable` is derived
from `WriteRef` (*"a stored copy is a second source of truth for a safety property and would
drift"*). It ships **with** the mitigation sentence `writable` already carries, transferred
verbatim in shape: ***`authenticated` true means only that a credential is configured, never that
it is valid or sufficient.*** Without that sentence it would be declined: issue #14 is what this
repo already suffered when a published boolean was allowed to read as a promise — three live agent
turns read `readOnly: true`, concluded a write was impossible, and declined without ever calling
the tool, so the gate under test was never reached.

### The question the ticket never asked, and the operator did

**The scheme was never hardcoded; the header name was.** The Keychain holds the *whole header
value*, so `Bearer …`, `Basic …` and an opaque token all work today without Wakil knowing which is
which — that opacity is deliberate and is kept. But `httpclient.go:441` is
`req.Header.Set("Authorization", tok)`, a literal, so **any backend not authenticating through
`Authorization` is unserved**: a custom header, a query parameter, a cookie session (`Cookie` is
denied outright), or mTLS.

The apparent escape hatch is worse than the gap. Nothing denies `X-API-Key` — the caller-header
loop rejects only `authorization`, `cookie`, `host` and `proxy-*` — so a caller *can* set it. But
then **the secret never comes from the Keychain**: it is typed into the tool call, so it lands in
the journal and in the agent's context in plaintext, and it is **not scrubbed**, because
`NewAuthHeaderScrubber(tok)` is built only from the Keychain value. That constructor's own comment
records the measurement that motivated it — a server echoing back only the credential went
unredacted, *192 bytes verbatim*. So the manual route loses both properties #63 named as the entire
justification for Wakil touching HTTP.

**`ApiConfig` therefore also gains `AuthHeader`, defaulting to `Authorization`.** One field, one
changed line. Wakil stays scheme-agnostic at request time — the Keychain still holds the whole
value — and cookie-session backends come along free, because the deny list governs *callers*, not
Wakil's own injection. **A full auth-scheme enum was considered and rejected**: it throws away the
reason the Keychain holds the whole header value, which is so that Wakil never has to know the
scheme.

**One consequence ships with it:** the configured header name must join the deny list
**dynamically**. The caller loop runs at line 428 and Wakil's injection at 441, so Wakil already
wins by ordering — but a caller whose `X-API-Key` is silently overwritten has a latent bug, and the
file already holds the precedent: `Host` is denied although `net/http` ignores it, because *"a
caller believing it worked is its own latent bug, and rejecting it explicitly is more honest than
quietly ignoring it."*

**Query-parameter auth stays refused.** `NormalizeHTTPBase` already refuses both userinfo and a
query string in a baseUrl, so the codebase holds the line that **secrets go in headers, never in
URLs**. mTLS stays out: it is a transport concern, not a header, and nothing in the current design
reaches it.

### The override survives, unauthenticated

Once entries carry their own credentials, *"the environment's credential"* stops referring to
anything, so the drawn override had to be re-grounded. It keeps its place in the pane and **carries
no credential at all**: an origin the environment does not configure is an origin it has no token
for.

The objection is #63's own argument turned around — if Wakil's value over `curl` is scrubbing,
origin binding and redirect refusal **around a credential**, then a credential-less request is a
worse `curl`. It survives only because this is an **operator** affordance in a **pane**: the
operator has no `curl` there, and what the pane adds is the rendered response, the history, Decision
20's bound values from other panes, and the header and redirect discipline, all of which hold
without a token. The spec owes one sentence: *an overridden base URL carries no credential.*

### The convenience gap this ticket created, and did not leave owed

**There is no CLI that authors `project.json` contents at all** — `wakil project add` registers a
*path*; `environments`, `databases` and `api` are hand-edited. That is pre-existing and stays.

The **credential** half is not. `wakil secrets set-db` exists specifically to *compose* a DSN, with
per-driver flags and the password from stdin and never argv. HTTP has no equivalent: the operator
types the whole header value into bare `wakil secrets set`, prefix included, and a missing
`Bearer ` yields a silent 401 that Wakil cannot diagnose because Wakil never inspects the value.
`AuthHeader` widens that — now **two** formats must be right unaided.

So **`wakil secrets set-api <ref> [--scheme bearer|basic|raw]`** is ruled here and built with
2c-iv: it composes the header value under the same stdin discipline, while Wakil stays
scheme-agnostic at request time, because the scheme is a composing aid and is never stored. This is
deliberately **not** filed as owed. The gap is *created* by this ticket's `AuthHeader` field rather
than inherited, and #64 exists precisely because the owed pile grew by one item per ticket.

### Findings

**A glossary collision, pre-existing and now load-bearing.** §9 defines **Connection** as an
*organization*-level authenticated account — a Jira site, a Slack workspace, a mailbox. But
`wakil-db`'s tool schemas say *"connection name"* for a **database**, which is an
*environment*-level thing, and this ruling would have added a second environment-level use for
APIs. The term means two different things in shipped code. **This log uses "API entry", not "API
connection"**, and §9 is left alone: the charter is at **4,025 against its own 4,000-word limit**,
and a glossary repair that must also correct `wakil-db`'s seven schema strings is not this ticket's
to pay for.

**Two artboards went stale, and only one is repaired here.** `ConfigLevels.dc.html` was a factual
key list — `api.baseUrl · Per environment`, `api.authRef · Keychain name`, and a Keychain column
captioned *"Bearer or basic"* — all three now wrong. **Corrected in this ticket**, to four `api[].*`
rows inheriting `databases[].name`'s *"Unique per env"*, and to *"the whole header value · scheme
included"*. `ApiClient.dc.html` is **not** corrected: its override row needs the credential line
removed, and its URL line `/v1/bookings/{id}/confirm` shows no indication of which backend it
resolves against, which with three subdomains it must. That is a design question, not bookkeeping,
and it is 2c-iv's spec work — graduated as fog rather than filed, so that a map already one step
from closing is not re-opened for it. Per #49, a redraw here would be structurally validated only:
every `.dc.html` loads a `support.js` the repo does not contain.

**Left owed: nothing new.** The Decision 8 amendment is #64's to write, as it was always going to
be.

## 2026-09-17 — the HTTP write earned its way in on the credential, not on the verb

[#63](https://github.com/yehia-khalil/rafiq/issues/63) asked what justifies an HTTP write under
Invariant 6, and what 2c-iv's long-promised *"gated write method"* is actually made of. It was
graduated out of the map's fog by [#61](https://github.com/yehia-khalil/rafiq/issues/61), which
found the gap: **the invariant demands a justification per adapter and none existed for HTTP**,
while §8's 2c-iv row and Phase 2's exit criterion had both been promising one since they were
written, and `AssertHTTPReadOnly` had been refusing every verb but GET/HEAD *"with no override"*.

### The justification, which is not the shape the other two use

*"The exit clause needs it"* is why we want it, not why it earned its way in. The argument that
holds is about where the **credential** goes.

The agent already has a shell ([#39](https://github.com/yehia-khalil/rafiq/issues/39)):
`curl -X POST` is reachable today inside the session cwd, in a bare environment with no Keychain.
So is the operator, in any terminal. **An HTTP write is therefore not new power.** What it
changes is that a write stops requiring the environment's bearer token to be copied by hand into
a second tool — one with none of Wakil's secret scrubbing, none of its origin binding, none of
its redirect refusal. §1's arbitration test applied to the credential rather than to the verb:
*the absence of an HTTP write does not force the operator out — it forces the credential out
with them.* That argument survives the "but curl exists" objection which would have demolished a
convenience one.

### Four rulings, and the premise the operator removed

**One — no second credential.** The ticket proposed `ApiConfig.writeRef` mirroring
`Database.WriteRef`. The operator removed the premise: *"the http layer should be capable of
whatever the auth token is capable of."* That is `Database.WriteRef`'s own argument run in the
opposite direction — write authority should be **proven to the server**, never asserted by Wakil
to itself — and an API issuing one unscoped key would have the operator put the same token in
both Keychain entries, proving nothing. **The cost, stated rather than hidden:** SQL's *"a
database with no `writeRef` cannot be mutated by anyone"* has no HTTP analogue. The day the send
ships, every environment with an API configured is writable.

**The grains were never the same anyway**, which the operator's own clarification exposed:
`Environment.Databases` is a **list**, each entry carrying its own read and write credential,
while `Environment.API` is a **singleton**. SQL write permission is per named connection; HTTP
write permission could only ever have been per environment. Graduated as
[#67](https://github.com/yehia-khalil/rafiq/issues/67).

**Two — all methods.** No allowlist. The ticket recommended POST alone; the operator's own
principle argued against it, and correctly. The recommendation had also rested on a weak premise:
**an HTTP method is not a semantic boundary the way a SQL verb is.** `AssertSQLMutation` bounds
what a statement can do because the engine defines `INSERT`/`UPDATE`/`DELETE`. `POST` means
whatever the server says — `POST /bookings/BK-8842/delete` deletes. A method allowlist here would
have been narrowness of record, not blast radius.

**Three — confirm in production only, mutation methods only.** Not everywhere, which is what the
artboard draws (`Type confirm to send` on staging) and what the ticket recommended.

**Four — SQL is not changed.** `.mutate` keeps `.gate` outside production and `.block` in it.

### The finding that costs the charter, and it is Invariant 7 rather than 6

Invariant 6 gets its third dated justification, which is routine. **Invariant 7 does not
survive intact.** It reads *"Voice may propose a mutation; only typed confirmation may execute
one"*, with no environment clause. Under ruling three, a spoken *"POST the confirm endpoint for
booking 8842"* on staging executes a write with no keystroke.

**And the charter already contradicted itself here, before this ticket.** Phase 2's exit
criterion is *"spoken end-to-end"*, on staging, ending in *"then call the confirmation endpoint
with that ID"*. A typed confirmation at the end is not end-to-end speech. So the ruling did not
create the conflict; it resolved it, in favour of the exit criterion. `WriteGate.swift`'s own
D10 comment shows the same reading already in the code — it justifies its narrowness by keeping
that criterion *"free of confirmations"*, and quotes the sentence only as far as the fetch.

**The narrowest amendment:** Invariant 7 gains a per-adapter exception — HTTP, outside
production — written the way Invariant 6 already carries its per-adapter write justifications.
SQL keeps Invariant 7 whole.

### The mechanism: a fourth `ActionKind` was proposed, verified, and rejected

The ticket first proposed a fourth kind (`.boundedWrite`): allow outside production, gate in it.
Checked against the code, that is an anti-pattern, on three counts.

**It puts two axes in one enum.** `ActionKind`'s cases are a taxonomy of *what an action touches*
(`Action.swift:19-27`) — nothing, Wakil's own state, the world outside. An HTTP write touches the
world outside, so on that axis it simply **is** `.mutate`. Price is `writeGate`'s job.

**Two of its three consumers fail silently.** Only `WriteGate.swift` switches exhaustively. The
others compare by equality and would compile clean while misbehaving: `MCPServer.swift:540`'s
`isMutation` would go **false**, so the confirmation plane would stop reading the `statement`
argument and fall through to `describeProposal`'s machine-shaped output; and
`WindowModel.swift:878`'s `.read || .control` filter would exclude the new kind from
`--allowedTools` by accident rather than by decision.

**The codebase already solved this shape, and not with a kind.** `ctx_set_environment` needed the
gate to know something no kind could express, and the answer was a per-action field —
`Action.targetEnvironmentParam` (`Action.swift:79`), read by `dispatch` and handed to `writeGate`
(`ActionRegistry.swift:161`). *The plumbing exists; the field is new* — the ticket first
overstated this as a field "of exactly this shape", which it is not: that one is a `String?`
naming a params key, resolved per call, where a price is fixed at registration.

**And it is not a one-off.** Invariant 6's 2026-09-14 amendment already commits the Jira
transition to *neither confirmation plane nor production treatment*, so **2c-vi's write cannot be
`.mutate` either**. Two known outside-world writes already want non-`.mutate` policies, and
theirs differ from each other:

| Action | Outside production | In production |
|---|---|---|
| `db_run_mutation` | `.gate` | `.block` |
| the HTTP send (2c-iv) | `.allow` | `.gate` |
| the Jira transition (2c-vi) | `.allow` | `.allow` |

A kind built for HTTP alone would force 2c-vi to invent a second mechanism — the same failure
#61 named for the third in-window MCP client.

### What ships instead: a write price

`ActionKind` stays at three cases. `Action` gains a **price**, and `writeGate` gains a fifth
parameter rather than a new return — `GateDecision`'s three outcomes already express every row of
the table above, so a price is a *pair of values that already exist*, not new vocabulary.

The `.mutate` branch becomes `isProduction(environment) ? price.inProduction :
price.outsideProduction`. **SQL is unchanged by construction, not by care:** today's hardcoded
`isProduction ? .block : .gate` *is* the pair `(.gate, .block)`, so defaulting the parameter to
it makes the change a pure widening. Verified by reading at five sites — the gate's own branch,
the one non-test caller (`ActionRegistry.swift:161`), `MCPServer.swift:540`'s `isMutation`,
`WindowModel.swift:878`'s filter, and `dispatch`'s switch on the result — plus 18 four-argument
test call sites in `WriteGateTests` and `MutationActionTests` which a defaulted parameter leaves
compiling and asserting the same thing. **Not verified by building; nothing was compiled or run.**

The default is both the safety property and the risk, so the tripwire carries the other half:
`MutationActionTests` currently pins the `.mutate` count at one, and must instead pin that every
`.mutate` action declares a price **explicitly** — so a new write cannot inherit one silently in
either direction.

### Question 6 discharged by subtraction: `confirmationDescription` does not grow

The map's fog worried that `confirmationDescription` would need a second case and must not grow
a generic fallback. **It gains neither.** Because the send stays `.mutate`,
`parkForConfirmation`'s `isMutation` is true, so it reads the `statement` argument exactly as
`db_run_mutation` does. The send carries a human sentence as `statement`; the `switch` over
action names is not touched at all.

### What stays refused

Named explicitly, because both existing Invariant 6 justifications do it and it is the half that
keeps the invariant meaningful. **Refused:** any request leaving the environment's `baseUrl`, by
path or by redirect — and the redirect refusal is now **load-bearing rather than free**, because
a 307/308 preserves method *and* body, so a POST following one would send the body and the
`Authorization` header to a host the operator never reviewed. Caller-set `Authorization`,
`Cookie`, `Host` and `Proxy-*` headers, unchanged: the tool owns authentication. And any mutation
method in production without a typed confirmation. **Not refused, and deliberately so:** `PUT`,
`PATCH` and `DELETE`, which ruling two allows.

`AssertHTTPReadOnly` is untouched and survives **repurposed**: its GET/HEAD predicate is exactly
*"is this a mutation method"*, inverted, so the send action uses it to refuse a GET back to the
read action. Its *"with no override"* comment stays literally true, and
`phase-1-acceptance.md:549`'s recorded POST refusal keeps passing without an edit — the send is a
**second tool beside `request`**, as `wakil-db`'s `mutate` sits beside `query`, and a second
action beside `http_request`, since `ActionKind` is fixed per action and cannot vary by method.

### What this leaves owed

- **Invariant 6 gains a third dated justification** (HTTP), and **Invariant 7 gains its
  per-adapter exception**. Both are `north-star.md` §4 edits for the end-of-map pass, against a
  document at **4,025 words on a 4,000-word limit**.
- **A `write price` may want a §9 entry**, since `write gate` has one. It would have to be paid
  for out of the trim candidates in the 2026-09-16 terminal entry.
- **`ActionKind.mutate`'s doc comment** — *"Gated everywhere, blocked in production"* — becomes
  wrong. It was **already owed a correction from #39**, so the two must be paid in one edit
  rather than twice, alongside #40's three, #53's one, and `WriteGate.swift`'s own table.

## 2026-09-16 — the probe ran, q10 closed, and 2d split

`2d-stt-probe.md` was pre-registered, run against 25 utterances of the operator's own
speech, and scored by `scripts/probe/stt-score.py` rather than by eye. **Apple 4/29,
WhisperKit 3/29.** §5's condition required WhisperKit to be ahead by 6, so Apple ships as
the default and **q10 closed** — with Whisper selectable, per Decision 18 and Invariant 11.

**Three things the probe found that were not what it was looking for.**

**1. Both vendors' vocabulary-biasing APIs are inert here.** Apple's
`AnalysisContext.contextualStrings` was set with all 29 identifiers and read back from
`analyzer.context` intact; the transcript was byte-identical to no context at all.
WhisperKit's `promptTokens` behaved the same against a nonsense control. This also
corrects a claim this repository had repeated from 2026 benchmark write-ups — that macOS
26 dropped custom vocabulary. It did not. The API is there and it did nothing.

**2. Two thirds of both engines' misses are the right words, wrongly joined.**
"transaction read only", "describe editability", "CTX adopt provider", "harden MySQL write
config", "JSON value". **Both engines make the same mistake on the same identifiers**, so
no engine choice fixes it. A deterministic fold — case, spaces, hyphens, underscores —
against the identifiers already in scope takes Apple to 14/29 and WhisperKit to 15/29.

**Decision 11 assumed exactly this on 2026-09-03** — *"mistranscribed identifiers are
resolved by the agent against real ticket and endpoint lists rather than by demanding
clean audio"* — and nobody had measured it. The measurement is that the resolver carries
about two thirds of the load. **That is why 2d split**: `2d-i` is the resolver, needs no
audio and no model, is testable in `WakilKit` (which `WakilApp` is not), and serves ⌘P/⌘K
as much as speech. `2d-ii` is the capture work behind it.

**3. Some identifiers are not speakable, and no layer fixes them.** `2b-viii` came back
"2B8" from both engines — closeness 0.44, worst in the set — and `2c-ii-b` as "2 C 2 B" at
0.60. Roman-numeral sub-phase labels and hyphenated version strings are the failing
category. **2d's design has to either accept that these stay typed, or give them spoken
aliases.** Worth settling before `2d-ii` assumes otherwise.

**What the probe did not measure.** Whether fuzzy matching recovers any of the fourteen
genuinely-wrong-word misses (`writeRef` → "right ref", `Umbrella` → "together and"); and
whether either vendor's biasing can be made to work on a different code path. Neither was
pursued — §6.2's fold needs no vendor cooperation and no threshold.

## The 2026-09-15 acceptance — the whole runbook backlog, discharged at once

**On 2026-09-15 the operator accepted every outstanding acceptance check in the
repository, on their own authority, without walking any of them.** That is a scheduling
decision and it is theirs to make; what follows is the record of exactly what it covered,
so that "met" never has to be reverse-engineered from a table later.

**What was accepted, and what each one leaves unestablished:**

| Runbook | Checks accepted | What is therefore unknown |
|---|---|---|
| `phase-2a-acceptance.md` | check 8 | Whether cross-org isolation holds at the window. Never run for want of a fixture; the guard is covered by unit tests only |
| `phase-2b-i-acceptance.md` | its three standing checks | Whether the canvas, the rail and the palettes work and read correctly under a real mouse and eye. No human has ever looked at them — §3's `--dispatch` proof and §4 are the whole of what was established |
| `phase-2b-iii-acceptance.md` | six | The write gate's **UI** half — the confirmation plane at the window, and 2a's checks 5 and 6, which this runbook owns the result of. The headless half was established |
| `phase-2b-v-acceptance.md` | ten | Whether a rebuilt thread reads as the same conversation continued, whether the seam reads as a seam, and — check 10 — whether resuming a session that is open in a second terminal leaves both proceeding with separate transcripts. That last one is the scenario `session-resume-probe.md` §9 measured going *wrong* under continue-in-place |
| `phase-2b-vi-acceptance.md` | the dual-drive gap | The live provider swap remains headless-only; `ctx_set_provider` is proven, the in-window swap of it is not |
| `phase-2c-ii-b-acceptance.md` | checks 12 (MySQL half), 14, 17 | **The MySQL write path has never been exercised at the window**, because staging's MySQL database still has no write credential. SQLite editing was walked and passes |

**What this does not change.** Every one of these is now *met*, and nothing in §8 waits on
a runbook. But acceptance moves a marker, not a fact: this project's own most-repeated and
most expensive finding is that **a green suite is the floor and decides nothing above it**
— 2c-ii shipped defects against 649 green tests, 2c-ii-b against 709, 2b-viii against 794,
and the two correctness bugs 2b-viii's walk caught had passing tests over the very code
they were in. The checks above are precisely the instruments that find that class of
defect, and they were retired unused. If one of these surfaces misbehaves later, this
entry is where to look first.

**The one to come back to, if any.** Check 10 of 2b-v — it needs a second, independent
`claude` session open by hand in a terminal, which is the only check in the whole backlog
that no script driving `Wakil.app` could ever have confirmed, and it guards against two
writers scrambling one transcript.

---

Each phase has an exit criterion that can actually be tested.

### Phase 1 — Capability layer (no Swift)  ✅ **MET 2026-09-07**
`wakil-ctx`, `wakil-pm` (Jira), `wakil-db` (read-only), `wakil-http`, `wakil-recall`
(grouped), the org/provider model (Invariant 4, amended 2026-09-06), and session
discovery. Headless MCP servers, driven from plain Claude Code.

> **Exit:** from plain Claude Code, "what's assigned to me on umbrella" and "fetch
> customer 42 from staging" both return correct answers, with no Swift written.

Purpose: retire every integration risk before paying for a UI.

**Met.** All seven of the spec's §8 exit criteria passed on 2026-09-07 against the
org/provider model, from plain Claude Code with no Swift written — the Jira half
against `INI` on `initech.atlassian.net`, the database half against three drivers
returning the same row. Recorded criterion by criterion in
`docs/wakil/phase-1-acceptance.md`. One structural limitation surfaced (Invariant 4's
second half, above); it does not affect the exit criteria.

### Phase 2 — Wakil.app
SwiftUI shell. Action-registry foundation. DB, HTTP, and terminal panes, fully
dual-driven. Org/project/environment switcher. Session browser over the on-disk history.
Push-to-talk voice. `AgentHarness` abstraction with the Claude Code implementation.

> **Exit:** spoken end-to-end — *"open the booking project on staging, fetch the latest
> reservation, then call the confirmation endpoint with that ID"* — with every step
> visible in its pane and editable by hand afterwards.

**Split into four sub-phases 2026-09-07.** Seven independent subsystems is not one spec;
written as one it would rot before it was half-built. Ordered by risk retired rather than
by visible progress, because Decision 9 records that dual-drive cannot be retrofitted —
so every pane built before the action registry exists is a pane that gets rebuilt.

| | Delivers | Exit |
|---|---|---|
| **2a** | Harness, action registry, agent bridge, write gate, context switcher, one crude pane | A typed command runs through the registry; clicking does the same and journals identically — **MET 2026-09-08.** That criterion is `phase-2a-acceptance.md`'s check 4, walked by the operator and passed, along with every other check expressible at the time. Two were not: checks 5 and 6 (the write gate, production blocked) had nothing to gate in 2a and waited for 2b-iii, whose row below records them finally running. Check 8 (cross-org isolation) was never run for want of a fixture, and was **accepted on 2026-09-15** rather than walked — the guard is covered by unit tests alone. Marked here 2026-09-15 — it was the only delivered sub-phase carrying no verdict at all, which made the foundation everything else sits on unreadable from this table |
| **2b** | The void, the Core (Metal), planes, magnetism, the rail, ⌘P/⌘K, motion | `design-language.md` §1–13 realised; 120fps; project switch < 400ms |
| **2c** | The panes — the shared data surface first, then every pane built on it; the sub-phase table below is the list | Each pane the phase ships is fully dual-driven |
| **2d** | Push-to-talk, pluggable STT, live transcription | The Phase 2 exit criterion above |
| **2e** | The settings pane — the surface Decision 21 costed and never scheduled. An account is added from inside Wakil across two browser trips; a **binding** is unlinked; a database DSN is written under the journal's first redaction rule; `org.json`'s three strings are editable; and every binding the pane draws is either credentialed or named as not. **Ordered after 2c and before 2d**, which its letter does not say: 2c-iv carries Phase 2's own exit clause and §1's arbitration test ranks a monthly act below two daily ones, while [#123](https://github.com/yehia-khalil/rafiq/issues/123) pins the pane ahead of 2d-ii so voice is built unable to reach it rather than taught to avoid it. `Waits on` carries the order, not the label — §8 is label-ordered, and 2b-i sits first having been met last. | **Two clauses, because the phase has two halves and one clause would let a half ship untested.** An account is added from the settings pane and a **Session** launches under it without the operator seeing, typing or pasting a credential — minted and stored inside Go, with the mint's outcome journalled; **and** every binding the pane draws either carries a credential or is named as lacking one. |

## 2026-09-17 — the window learned to quit, and one pump was never cancelled

Two bugs that [#41](https://github.com/yehia-khalil/rafiq/issues/41) surfaced and the
[The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map ruled out of scope,
fixed together because they are the same contract seen twice: **what the window stops when
it goes away.** Neither is a 2c decision and neither waited for one.

**`WindowModel.shutdown()` now cancels `providerSwitchPump`**
([#57](https://github.com/yehia-khalil/rafiq/issues/57)). It was the only one of five
omitted — declared `:1181`, started in `init` at `:1473` directly beside `resumePump`,
which *is* cancelled. An oversight, not a decision: no comment anywhere defended it.

**What that issue asked for already existed, and does not help.** It proposed *"a test
that fails when a sixth pump is added"*. `InvalidationContractTests` is a whole-`Mirror`
sweep, so a sixth pump already fails it — but it fails as *a property nobody classified*,
and you satisfy it by adding the name to `orgIndependent` one line below
`providerSwitchPump` itself, which asserts nothing about cancellation. That test says so
about itself: *"a NAMING test, and deliberately only that."*

The real gap was wider. **No test asserted anything about `shutdown()` at all** — three
`shutdown` hits across `app/Tests/`, every one of them cleanup, never a subject. Nothing
covered pump cancellation, `harness?.stop()`, or `WindowSession.shutdown()`'s ordering.
`ShutdownContractTests` closes the first: it walks the `Mirror` for properties whose name
ends in `Pump` and asserts every *started* one is cancelled after `shutdown()`. **Keyed on
the suffix rather than on being a `Task`**, because `pendingSave` is also a `Task` and must
**not** be cancelled — it is the most recent layout write, and cancelling it on the way out
is how an operator loses the layout they just arranged.

**Closing the window now quits Wakil**
([#56](https://github.com/yehia-khalil/rafiq/issues/56)).
`applicationShouldTerminateAfterLastWindowClosed` returns `true`, which routes window close
into `applicationShouldTerminate` and the teardown that already exists — rather than adding
a second path that would have to restate `WindowSession.shutdown()`'s ordering, where the
`claude` child dies before the socket its shim connects to is closed and unlinked. Before
this, closing the window without quitting left the app running and holding two Go children,
a `claude` if a session was live, and a bound socket, with no surface to see or kill any of
them.

**The alternative — tear the window down, leave the app alive — was rejected on a fact
check.** That is what a multi-window app would owe, and Wakil is not one:
`north-star.md` does not use the word *"window"* anywhere, no numbered Decision is about
windows, and §8 has no row for window or application lifecycle. It would also require
`startup` to become re-runnable, and it is a one-shot `Task` deliberately.

**A finding, fixed in passing: ⌘N's removal was defended by a comment that had stopped
being true.** `AppScene.swift` claimed a second window would run `WindowSession.start()`
again and that *"the second assignment would simply overwrite the first"*. `WakilWindow`'s
`.task` has since gained a reuse guard, so a second window now finds `delegate.startup`
already set and **shares** the first window's session and model. Nothing leaks; two windows
draw one `WindowModel` instead, which is worse in a different way. The command stays
removed on the design ruling — **one window, permanently** — which
`applicationShouldTerminateAfterLastWindowClosed` now depends on.

**Left owed:**

- **#56's fix is unverifiable by test.** `WindowSession` lives in `WakilApp`, which has
  **no test target**, so nothing in the suite can prove the window's close path tears
  anything down. It wants an operator walk, and no runbook step covers it yet.
- **The tripwire's `panes` and `layout` entries are still wrong**, as #41 found.
  Deliberately untouched — that correction belongs with whoever moves them.
- **Two of `shutdown()`'s three subjects remain untested**: `harness?.stop()` and
  `WindowSession.shutdown()`'s ordering. Only pump cancellation is covered.

## 2026-09-16 — the order of the rest of 2c was a numeral, not a ruling

[#61](https://github.com/yehia-khalil/rafiq/issues/61) asked whether 2c-iv, the API
client pane, should move ahead of 2c-iii, the terminal. **It does not — the sequence is
`2c-iii → 2c-iv → 2c-vi`.** But almost nothing about the question survived being looked
at, and the ruling below is not the one the ticket was arguing for or against.

### There was no "2c-iii next" constraint to overturn

The ticket treated *"2c-iii next"* as an inherited constraint whose justification might
or might not survive the eight tickets that have since reshaped the sub-phase. **It was
never a constraint.** `north-star.md`'s 2c-iii row read *"2c-ii-b's re-walk"* in its
**Waits on** column until `c0f8f9c` (2026-09-15) cleared that blocker and rewrote the
cell as *"— **unblocked; next in 2c**"*. The word *next* is the roman numeral restated in
a column whose job is to name what a row is waiting for, added in a commit whose own
summary says *"what this leaves next is 2d"*. No argument was made for it because none
was being made.

Open question 13 is the only written sequencing argument that touches 2c-iii, and it
points the other way: it sequences **2b-viii before** 2c-iii, on the grounds that a PTY
holding a live shell in org A's project root is the worst org-switch teardown case. That
argues about what comes *before* 2c-iii and is silent on what comes after. It was
discharged when 2b-viii met on 2026-09-15.

**So the question was not "does the inherited order survive" but "there is no order;
rule one."** What follows is that ruling, recorded here rather than left implicit in a
numeral for the next reader to mistake for a decision.

### The argument for going first dissolved on where the exit clause is walked

[#37](https://github.com/yehia-khalil/rafiq/issues/37) ruled the API client **mandatory**
because Phase 2's exit criterion ends *"then call the confirmation endpoint with that
ID"*, and that clause is 2c-iv and nothing else. That ruling stands. **It does not imply
"first."** This file's own Phase 2 table assigns the Phase 2 exit criterion to **2d** —
2c's row exits on *"each pane the phase ships is fully dual-driven"*, and 2d's `Exit`
cell reads *"The Phase 2 exit criterion above"*. The spoken sentence is walked after the
whole of 2c. Mandatory-before-Phase-2-exits is therefore satisfied from **any** slot in
2c, and distinguishes no ordering within it.

### What does distinguish them: the coupling is order-sensitive in one direction

[#40](https://github.com/yehia-khalil/rafiq/issues/40) made `PaneStore.Contents` an enum
over kinds in one store and made the `read_pane` snapshot a discriminated union keyed by
`kind`. That generalisation is paid for **once, by whichever kind is built second**; the
third adds a case. The ticket asked whether that cost is order-sensitive, which is the
sharp version of the question, and it is — **in one direction only.**

The terminal is the extreme kind. It returns **two** surfaces with a `screen` field
saying which the operator sees, which puts a discriminator *inside* a kind; its live grid
is re-snapshotted on every change; and its block history carries `origin`. The API client
is the mild one: a request, a response, and a history the artboard draws as a result set
whose request and response are not rows. **An enum shape designed against the extreme
case fits the mild one. Designed against the mild one it gets reshaped**, and the reshape
lands on code the second pane already shipped.

The same asymmetry holds for teardown.
[#41](https://github.com/yehia-khalil/rafiq/issues/41) designed `TerminalStore` as an
actor modelled on `MCPClient`, with the org-switch tripwire widened to a third bucket to
catch it. 2c-iv needs a **third in-window MCP client** with exactly that lifecycle —
`wakil-http` does not run in the window at all today. Built after the terminal it
inherits a pattern that has been argued and walked; built before it, it invents one.
*(Corrected 2026-09-20 by [#114](https://github.com/yehia-khalil/rafiq/issues/114): `wakil-http` runs in the window from 2c-iv on, as a third
`MCPClient` on `WakilWiring`. The lifecycle it inherits is **`MCPClient`'s own, not
`TerminalStore`'s** — "with exactly that lifecycle" above reads as if 2c-iv had a new actor to
build, and it has none. `TerminalStore` was *modelled on* `MCPClient` precisely because a PTY is
not an MCP client; `wakil-http` is one.)*

### And readiness, which is this map's own finish line

The map is done when each surviving sub-phase's design spec *could be written with
nothing left to argue*. **2c-iii is there.** Eight tickets have landed on it
([#39](https://github.com/yehia-khalil/rafiq/issues/39),
[#40](https://github.com/yehia-khalil/rafiq/issues/40),
[#41](https://github.com/yehia-khalil/rafiq/issues/41),
[#42](https://github.com/yehia-khalil/rafiq/issues/42),
[#43](https://github.com/yehia-khalil/rafiq/issues/43),
[#49](https://github.com/yehia-khalil/rafiq/issues/49),
[#50](https://github.com/yehia-khalil/rafiq/issues/50), and #37's ruling), its exit
criterion is written, and its artboard has been redrawn against the rulings. **2c-iv is
not**: its binding mechanism has *no code, no syntax and no action*, and the finding
below adds a charter amendment in front of it. Ordering by readiness is what the phase
split already said it was doing — *"ordered by risk retired rather than by visible
progress"* — and a sub-phase whose spec cannot be written retires no risk by being
scheduled early.

### The finding that costs the charter: 2c-iv's write has no justification

Invariant 6 is *"read-only until a write earns its way in"*, and it demands a
justification **per adapter**, *"never by default"*. Two have been written: **SQL row
mutation** (2026-09-09, gated by `AssertSQLMutation` behind a second credential) and the
**Jira issue status transition** (2026-09-14, reached from 2c-vi). **There is none for
the HTTP adapter** — not in the invariant, not in `decisions.md`, not anywhere.

`north-star.md` §8's 2c-iv row nonetheless promises *"`wakil-http` gains a gated write
method"*, and Phase 2's exit clause requires a verb that is neither GET nor HEAD. The
code refuses it twice over, deliberately:

- `AssertHTTPReadOnly` (`internal/wakilcore/readonly.go:727`) allows only GET and HEAD,
  and its doc comment says **"with no override"** — the phrase is load-bearing, not
  incidental.
- `noRedirectClient` (`internal/wakilcore/httpclient.go:285`) refuses **every** redirect
  through `CheckRedirect`, which a read-only client can do freely and a non-idempotent
  verb reopens.
- `phase-1-acceptance.md:549` records `POST` via `wakil-http` as **"not reachable from a
  session"**, with a *second independent* server-side refusal walked at
  `cmd/wakil-http/main_test.go:205`.

**This is charter-level work sitting in front of 2c-iv that no ticket covered**, and it
is a second, independent reason the pane is not the one to build next. Filed as its own
ticket, scoped to the whole write boundary rather than to the invariant's sentence alone:
you cannot write a per-adapter justification without saying which verbs, gated how, and
behind what. That is the same shape as
[#39](https://github.com/yehia-khalil/rafiq/issues/39), *the enumerated action behind a
pane*, which this map has already run once successfully.

### 2c-vi stays last, on a different reason than the one recorded

Its row in the Phase 2c table below gave **two** reasons for being sequenced last, and
**both are now spent**:

1. *"2b-viii's teardown contract must exist first"* — **discharged**, not withdrawn. It
   was right, and it was paid: 2b-viii met 2026-09-15.
2. *"the only pane in the phase that carries a write"* — **false**, and corrected in that
   row. §8's 2c-iv row has promised an HTTP write since it was written, so there are two
   write-carrying panes in 2c, not one. The claim was true of Invariant 6's *justified*
   writes and was stated as a claim about panes.

What replaces them needs no argument at all: **open question 15 blocks 2c-vi's write
half**, and §8 records it. A live blocker is a stronger reason to be last than either
sentence it replaces. Neither 2c-iii nor 2c-iv has one.

### What this changes in the files

- **`north-star.md` §8's 2c-iii cell loses `next in 2c`**, leaving `—`. The **Waits on**
  column names blockers; a sequence asserted from it is what produced a constraint nobody
  had ruled. Sequence belongs in this file's Phase 2c table, where 2c-vi's already lives.
  On a document 29 words over its 4,000-word limit this is a **refund**, not a cost — four words, leaving it at 4,025.
- **The 2c-vi row's two reasons** are struck and replaced, per above.
- **Nothing else.** The five owed doc comments (`ActionKind`, `PaneStore.swift:368`,
  `MCPServer.swift:233`, `:687`, `autoResumeAfterSwitch`) stay owed to 2c-iii's **build**;
  this map plans and does not edit Swift.

**Graduated from the fog:** the HTTP write boundary ([#63](https://github.com/yehia-khalil/rafiq/issues/63)), and the map's own end-of-map
promotion pass — the one that gives SwiftTerm's dependency a numbered Decision, joins
`term_open` to #39's action account, and decides which of this map's ten rulings earn a
number in `decisions.md`. It has been deferred once per ticket since #39 and is now the
map's terminal node ([#64](https://github.com/yehia-khalil/rafiq/issues/64), blocked by #63), so that the map's completion is checkable rather than assumed.

---

## 2026-09-16 — auto-resume was asking Swift a question Go had already answered

Resolved by [Auto-resume after an org switch only looks in the first root](https://github.com/yehia-khalil/rafiq/issues/53), the ninth ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map, and the one [#42](https://github.com/yehia-khalil/rafiq/issues/42) surfaced. It is 2b-v / 2b-viii residue and blocked nothing in 2c.

**The ruling, in one line: the `cwd` half of the predicate is deleted, not widened — `session_list` already filters to any root of the active project, so the fix is a subtraction and the palette carries the path in its subtitle, where it is searchable.**

### The ticket asked whether Swift should ask Go, and the answer is that it already does

`autoResumeAfterSwitch` picks the newest row matching `provider == providerId && cwd == rootPath` (`WindowModel.swift:3919`), where `rootPath` is `rootPaths.first` (`:1839`). The ticket read that as a choice between three predicates — root one, any root, or no cwd at all. It is not a choice, because the rows being filtered are **already root-scoped one layer down**: `ListSessions` keeps a transcript only if `cwdMatchesAnyRoot(cwd, ProjectRootPaths(r))` (`sessions.go:419`), across every provider the org holds. So the Swift clause is a **second, narrower filter sitting on top of a correct one**, and deleting it widens nothing beyond the active project. "Any root" is not a predicate Swift needs to acquire; it is one Swift needs to stop overriding.

### The defect is not multi-root residue — it bites at N = 1

This is where the ticket's own framing was too generous to the code. `cwdMatchesAnyRoot` is a **prefix** match (`sessions.go:526`): a session whose cwd is `<root>/anything` is listed by Go and then rejected by Swift's exact equality. So a project with **one** root loses every session ever started below that root — the multi-root case is the second instance of the bug, not the first. The ticket offered itself as *"the one piece of hard evidence that behaving as though N = 1 has already cost something."* It is weaker evidence than that, and a worse defect than that: behaving as though the project is **one directory** is what cost something, and #42's ruling is untouched.

**The field note already had the symptom and the wrong cause.** `phase-2b-viii-acceptance.md` recorded the exact-string match as a thing to watch, and named the tell exactly right — *"a **spurious** 'no previous session in \<org\>' note on a switch that should have resumed something"* — while guessing at trailing slashes and symlinks. Neither has ever arisen. Subdirectories arise constantly.

### What the deletion buys, beyond the fix

`rootPath` has three uses in the whole window: two `workingDirectory:` arguments for **fresh** harness starts (`:3624`, `:4003`), and this predicate. Remove the predicate and `rootPath` means exactly one thing — the fresh-session default — which is what [#42](https://github.com/yehia-khalil/rafiq/issues/42) already ruled it is. That predicate was the one line in the app still contradicting the ruling. The method's doc comment is careful about why the *provider* half is not optional and silent about the `cwd` half; the silence was accurate.

### The palette says where, and says it in the subtitle

`PaletteItem` gains **no field**. The subtitle is scored by `rank()` alongside the title and the better of the two wins (`PaletteItem.swift:93`) — the same mechanism that makes ⌘K find `pane_snap` by typing *"flush"* — so a path in the subtitle is **searchable**: typing a root's name filters ⌘P's session rows to that root. A `cwd` field would need a view change *and* a ranking change to become reachable at all, and would be a field with one consumer against eighteen `PaletteItem(` construction sites. The cost of the choice is that the subtitle is a single `Text` in a `VStack` (`Palettes.swift:50`) and has to stay one line.

It renders as the **`~`-abbreviated absolute path, always shown**. Relative-to-its-root is ruled out by the ruling above — it would re-acquire the root knowledge just deleted. The last path component alone is ambiguous exactly where it matters, since two roots of one project plausibly share a leaf (`app`, `src`). And *always* rather than only-when-it-differs, because "differs from `rootPath`" is the same root comparison, and a conditional path makes an absent one unreadable.

`status` gains the directory on a **successful** auto-resume, which is the other half: today it is silent on success and false on failure. The failure message stays as it is — after the fix, *"no previous session in \<org\>"* is finally true when it appears.

### The collapse does not hide roots, and the doc comment says otherwise

The ticket asked whether `sessionItems(from:)`'s chain-collapsing hides roots too. It does not: the collapse keeps the **newest** member, `resume()` launches in `thread.cwd` (`:3794`), so the surviving row's cwd *is* the directory the operator would land in. What is discarded is earlier members' cwds, which decide nothing.

But `autoResumeAfterSwitch`'s doc comment gives the collapse as a reason to read raw rows — *"Worse, `sessionItems(from:)` deliberately COLLAPSES resume chains down to the newest member … exactly the sessions this method most wants to consider"* — and that sentence refutes its own "Worse" in its own second half. The surviving valid reason is the one stated first: `PaletteItem` carries no `provider`, and after this ruling it still does not.

### Where the fix lands

**Its own small change, and not inside a pane sub-phase.** The whole of it is one deleted clause, one `status` string, one subtitle clause, and a test that puts a session in a subdirectory — which is the test 2b-viii never had. 2c-iii is already roughly twice its one-line row, and folding an unrelated correctness fix into it buys nothing. The closed ticket is that change's spec.

### What this leaves owed

- `autoResumeAfterSwitch`'s doc comment: the `cwd`-half paragraph goes, and the collapse sentence is wrong independently of this fix. It joins `ActionKind`'s and the three named by [#40](https://github.com/yehia-khalil/rafiq/issues/40).
- `phase-2b-viii-acceptance.md` corrected here in two places: check 9's evidence quoted the predicate verbatim (its **claim** — no cross-provider resume, a fresh session with a note — survives the fix untouched), and the field-watch note is replaced rather than amended, since the hazard it describes stops existing once the clause is gone.

## 2026-09-16 — 2c's sub-phase table was the only one in this file without an exit column

Resolved by [Do 2c's sub-phases get their own exit criteria?](https://github.com/yehia-khalil/rafiq/issues/50), the eighth ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map, and the last of those [#39](https://github.com/yehia-khalil/rafiq/issues/39) surfaced.

**The ruling, in one line: yes, and it is the same `Exit` column the other two sub-phase tables in this file already have — filled retroactively, pane-specific per row, and costing `north-star.md` nothing.**

### The ticket compared against the wrong table, and that made it look like an invention

It asked whether the table should *"grow a third column"* against the parent's `Delivers` / `Met` / `Waits on`. That is `north-star.md` §8, the **status** table — and §8 has no exit column for **any** row in it. The table 2c's sub-phase table actually sits under is this file's Phase 2 table, whose columns are **`Delivers` | `Exit`**. So the missing column was never `Met`; §8 already carries `Met` and `Waits on` for every 2c sub-phase.

Read that way the answer was close to settled before the ticket opened. This file holds three sub-phase tables — Phase 2's, 2b's and 2c's — and **only 2c's was two columns.** 2b's is filled for every row including the met ones, with the verdict folded *into* the `Exit` cell rather than given a column of its own (*"layout is dual-driven — **MET 2026-09-15 by acceptance without an acceptance run**"*), and no two of its cells say the same thing. The question was not what shape to invent; it was why 2c alone had gone without.

**And 2c's met rows already carried their exit content, in the wrong cell.** 2c-i's `Delivers` ended with its MET date and what the walk found; so did 2c-ii-b's and integer fidelity's. 2c-ii carried no verdict in that table at all. So the column is a **split, not an authoring** — the prose existed and `Delivers` was doing two jobs badly. 2c-ii is the one row whose criterion had to be recovered, and it is recovered by pointer: its spec §14 states it and `phase-2c-ii-acceptance.md` §1 quotes it in full, so the cell names it and declines to restate it.

### The three unbuilt rows, and why they are written here rather than in their specs

The map produces decisions rather than specs, which argued for leaving these to 2c-iii, 2c-iv and 2c-vi. **They are written here anyway, for two reasons.** A column that ships empty for the three rows that matter is the two-column table in a new shape. And a sub-phase authoring its own exit criterion is grading its own homework — the criterion is what the spec is tested against, so it has to exist before the spec does.

Each states what **this** pane must do that no other pane in 2c must. The three-clause definition of *"fully dual-driven"* — [#39](https://github.com/yehia-khalil/rafiq/issues/39)'s, recorded under its own entry below — is **not** repeated into any row: it decomposes 2c's *parent* criterion, one level up, and is the floor every row inherits rather than text any row restates. A criterion identical eight times is a column that says nothing, which was the ticket's own sharpest worry.

**None of the three enumerates anything**, per [#37](https://github.com/yehia-khalil/rafiq/issues/37)'s finding that the enumeration is what drifts. They are behavioural and walkable:

- **2c-iii** — *a real shell runs in the pane; the agent proposes a command and only the operator's Enter runs it; `read_pane` returns both of the pane's surfaces; and no shell outlives the pane that opened it.* One clause each from the four tickets that fed it. The last is the one that would otherwise go untested: [#41](https://github.com/yehia-khalil/rafiq/issues/41) found there is no `deinit` in `WakilKit` that releases an OS resource, so reaping is the sub-phase's least-defended claim.
- **2c-iv** — *a request built in the window and a request built by the agent are the same action; a value bound from another pane resolves in the URL before the send; `read_pane` describes a pane that is neither a grid nor a stream; and production costs a typed confirmation that staging does not.* The binding mechanism is named because it is the pane's largest unbuilt thing and has no code, no syntax and no action today.

  **Fourth clause corrected 2026-09-19** by [#107](https://github.com/yehia-khalil/rafiq/issues/107). It read *"and production refuses the send rather than confirming it"* — a `.block`. It was written 2026-09-16, in the session recorded above as *"the finding that costs the charter: 2c-iv's write has no justification"*, so it named a price for a write that had not yet earned in. The justification arrived the next day and priced it: Decision 25's table gives the HTTP send `.allow` outside production and `.gate` in it, and Invariant 6's HTTP entry refuses *"any mutation method in production **without a typed confirmation**"* — which is the charter's wording for a gate, not a wall. The clause still tests that the pane treats production differently; it tests it on the axis the ruling chose. Blocking would send an operator with a production incident out to `curl` with a production bearer token, which is the failure the write earned in on — *"it earns its way in on the credential, not on the verb"*.
- **2c-vi** — *a card dragged between columns and "move 2835 to review" dispatch the same action, against columns that are the Jira board's own; and the only target reachable is a transition Jira itself offers from the current status.* The second clause is what makes Invariant 6's narrowest-write justification walkable rather than asserted — *"both of its arguments are enumerated by the adapter"* — and is what open question 15 is really asking about. 2c-vi's `Delivers` loses the dual-drive sentence it had been half-stating its own criterion with.

**No cell names an acceptance runbook yet**, because none of the three exists. 2b's cells name theirs in the *verdict* half, written at MET time, and these follow that.

### What this does not touch, deliberately

**`north-star.md` is unchanged, and the ticket's fourth worry was a false premise.** These tables live in this file, which §1 above defines as the charter's overflow log and which has no word limit. §8 stays the status index — *what is built, what it waits on* — for every phase, not 2c's alone.

**A standing inconsistency found on the way, and left alone:** §8's header says *"Each phase has an exit criterion that can actually be tested"* and its table then renders no such column for any row. The criteria live here, for every phase in the file, and that sentence is a pointer rather than a promise the table keeps. Fixing it costs words a 4,029-word document does not have, and it is not 2c's defect.

**A stale row corrected in passing:** 2c-iii's `Delivers` still read *"per-root shells"* after [#42](https://github.com/yehia-khalil/rafiq/issues/42) took the root concept out of the sub-phase entirely — §8's row was amended then and this one was not. It now reads *"a shell opened at a path"*, matching §8.

**`integer fidelity`'s `Exit` cell states that it has no criterion**, and says why: it is a fix, not a sub-phase, so there is no phase to exit and the fix staying closed is the whole test. A blank there would read as an oversight rather than the answer.

## 2026-09-16 — a proposal is a block that has not run

Resolved by [Redraw `Terminal.dc.html`: the two surfaces, the proposal, and the agent's own shell](https://github.com/yehia-khalil/rafiq/issues/49), the seventh ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map. A prototype ticket: three structurally different redraws were drawn across five scenes each and flipped through, rather than argued. The operator picked the first.

**The ruling, in one line: one lane, one vocabulary — the proposal is a block that has not run, the mirror is a recessed block in the same lane, and the live grid is a mode the whole pane enters.** `Terminal.dc.html` is redrawn accordingly.

### The argument that decided it, and it came from a closed ticket

The three variants disagreed about where Wakil may speak in a pane whose prompt belongs to zsh: **A** put the proposal in the history as a dashed block; **B** gave Wakil a standing band between the history and the prompt; **C** put it on the near plane as a card and moved the agent's shell into a docked strip of its own.

**[#40](https://github.com/yehia-khalil/rafiq/issues/40) had already settled the shape without anyone noticing it settled this.** It ruled that a block carries `origin`: `operator`, `agent` or `proposed` — and that `proposed` is the value that *earns* the field, because without it the agent cannot tell whether its own proposal was accepted. **So a proposal is already a block in the snapshot the agent reads.** A band or a card gives one thing two homes: the agent reads a block where the operator sees a banner, which is Invariant 3's honesty claim failing quietly. Drawn in the lane, acceptance is **one object changing state** — the dashed block becomes a real one and `origin` flips from `proposed` to `operator` — and the drawn lifecycle and the snapshot lifecycle are the same lifecycle.

That is the whole answer to *"`term_propose` loses its surface"*, which [#43](https://github.com/yehia-khalil/rafiq/issues/43) recorded as a real gap. The surface it lost was a Wakil-drawn *input line*. It did not need one.

### What the two losing variants were right about, and both were taken

**B was right that Wakil goes silent under a full-screen program.** When `vim` holds the screen the history is parked, and A as drawn had nowhere for a proposal to land for as long as the program runs. **B's band is adopted, scoped to the grid mode only**: the parked-history strip already drawn above the grid carries anything pending. Wakil keeps a voice without acquiring permanent chrome, and nothing it draws occupies a cell the program believes it owns.

**C was right about backfill, and the operator's own words are the argument.** *"Not always open a terminal, but when it is open I would like to see it"* — and A as drawn implied the mirror starts at pane-open, so the terminal you open *because* you want to see what the agent is doing shows nothing until its next command. **The mirror backfills**, and it costs nothing: it is reconstructed from `toolUse`/`toolResult` off the harness stream, which Wakil already holds, so the record predates the pane. Bounded by the same block cap as the rest of the history, and it says on screen that it is backfilled.

### The mirror, settled

- **It says where it ran, on its own line** — `Wakil's shell · <cwd> · bare environment`. The bare environment is the harness's, built from nothing but `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`, `HOME` and `PATH`; this pane's PTY carries the active environment's variables and the org's credentials.
- **It is never luminous.** §1's second principle says light is information — *"alive, active, or asking for attention"* — and a mirrored block is none of those: it is a report of something that already happened elsewhere. **Emphasis in this pane tracks exactly one thing: whether the block is asking for your Enter.** So violet is spent on the proposal alone and the mirror is drawn recessed, a darker inset with a hatched edge. This is why a third treatment did not need a third hue, which §5 would have refused anyway.
- **`Rerun` reads `Propose rerun`.** Running a mirrored command here would execute a command the agent chose with the operator's credentials in the operator's environment — the propose path wearing a disguise. `Copy` and `Send to thread` are unaffected.
- **Consecutive agent blocks collapse into one expandable group**, on the operator's call. A turn can be six greps between two of your commands, and ungrouped the mirror buries your history in someone else's. The alternative considered and rejected was a mirror on/off toggle: it hides what you opened the pane to see. **The group is a rendering, not state** — `read_pane` still returns the blocks, each carrying `origin: agent`, exactly as #40 specified.
- **Every open terminal pane gets the mirror.** The alternative was a nearest-cwd heuristic, which is a rule the operator has to learn and cannot predict with two panes open. The mirror is a *view* on one record, and a view that appears in one pane and not another is the worse failure. Duplication is what a view is for.

### The running state cannot be a progress bar

`toolUse` arrives the instant the agent issues the call, *before* the command runs; `toolResult` arrives whole when it finishes. So a mirrored block appears immediately in a running state and fills in on completion — and **characters never scroll as they are produced, and cannot**, because those `Bash` calls are auto-allowed by CLI policy and never reach Wakil. Realtime is true of *what it is running*, not of *watching it scroll*.

The block therefore carries an amber `running` chip, an elapsed counter that ticks because time passes, and the line *"Wakil was told this started. Its output arrives whole when it finishes — nothing scrolls here."* There is no bar: Wakil has no idea how far along the command is, and §9 already rules that the thought thread is what this project draws **instead of** progress bars.

### The hand-off is drawn, because it is the one moment the two surfaces touch

Accepting a proposal injects the bytes into zsh's line. The dashed block disappears and the command sits in the operator's prompt **unrun** — injected bytes are indistinguishable from typed ones, so from that instant it is theirs in every sense — and it becomes a real block when the shell reports OSC 133 `C`, which is also what journals `term_run`. **Two Enters, deliberately**: one to accept, one to run. That is Invariant 7's shape (*"voice may propose a mutation; only typed confirmation may execute one"*) generalised from voice to the agent, and it is why the proposed block must be gone before the prompt fills, or the operator sees the same command twice.

### The cuts owed from #42, discharged

Removed from the artboard here: the `root 1 of 3` counter, the cross-root `Infra · exit 1` chip, the `Outside every root` chip and its banner, and `All roots` on both ⌘F and a block. The header keeps the **live** cwd, which [#43](https://github.com/yehia-khalil/rafiq/issues/43) requires regardless via OSC 7. The `sc-if` scenes became a single `scene` enum — `history`, `mirror`, `propose`, `handoff`, `grid`, `after grid` — because the states are now mutually exclusive rather than orthogonal toggles.

### What this leaves owed

- **A drawn artboard in this repo cannot be looked at.** Every `.dc.html` loads `./support.js`, which is not in the repository and never has been; the files are seeded into an external canvas instead. So this redraw was validated structurally — placeholders all bound, `sc-if` nesting kept to the one level every other artboard uses, `renderVals` exercised across all six scenes — and **not visually**. That is a standing cost on every screen here, not this ticket's, and it is recorded because the next person to redraw one will hit it in the same minute.
- Nothing new is owed to `read_pane`: the group is a rendering and `origin: proposed` now has a drawn referent, which is what #40 assumed and could not point at.

## 2026-09-16 — the PTY gets an owner, and the tripwire's two buckets were never enough

Resolved by [Where a PTY lives, and what widens the org-switch tripwire](https://github.com/yehia-khalil/rafiq/issues/41), the sixth ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map. The ticket asked where a live PTY lives and what has to widen so the org-switch teardown catches it, quoting 2b-viii's spec promise verbatim — *"a terminal pane holding a PTY open in org A's project root cannot be added without the author being told, by a failing test, that they must classify it"* — and calling it false as written.

**The ruling, in one line: the PTY lives in a new `TerminalStore` actor modelled on `MCPClient`; the tripwire gains a third bucket because its existing two already lie; and a behavioural test that opens a real shell and asserts it is reaped is what actually holds the promise.**

### The promise is not false — it is worse than false, it is satisfied wrongly

The ticket's premise was that a PTY held outside `WindowModel` is enumerated by no test. True, and not the sharp version. **A PTY held *inside* `WindowModel` — as the new store the ruling puts there — is enumerated by the tripwire, fires it, and gets classified into the wrong bucket by an author doing exactly what the failure message asks.**

`InvalidationContractTests.swift:32` lists `panes` and `layout` under `orgIndependent`. `invalidateForOrgChange()` clears **both**, explicitly and awaited, as its last two lines (`WindowModel.swift:2033`). So `orgIndependent` does not mean *"holds no org state"*; it means *"this reference is not reassigned"*, and the two stores that carry the most org state in the window are filed under it. A `terminals` property inherits that reading — the reference is genuinely stable — and the shell survives the switch with the tripwire green and the author's classification defensible.

**The pattern is not an accident of the test; it is how the app tears down.** `WakilWiring.switchOrg(to:)` stops and restarts the *same* `MCPClient` instances in place (`AppWiring.swift:386-407`), never replacing them, because `registerStandardActions` closed over those instances. A live child process dying while its owning reference never changes is the shape this app already uses everywhere. The tripwire has no vocabulary for it.

**So the fix is a third bucket, not a widened skip rule** — which is the one thing the test's own message forbids. `orgDerivedBehindAReference`: a stable reference whose contents are org-scoped and must be torn down. `panes` and `layout` move into it, correcting a classification that is wrong today, and `terminals` joins them. The bucket's name is the instruction the next author needs.

### The PTY lives in its own actor, and ARC is not allowed near it

`PaneStore` had the stronger case than the ticket credited: the PTY's lifetime is *identical* to pane contents in every respect — born at pane open, warm across a project switch, dead at `pane_close`, dead at an org switch — and [#40](https://github.com/yehia-khalil/rafiq/issues/40) had already put the block history and the live grid there as an enum case. A second store re-implements `byProject` keying for no new rule.

It loses on one fact that is not about terminals at all. **There is no `deinit` in `WakilKit` that releases an OS resource — not one.** The only `deinit` in the whole app removes a notification observer (`VoidView.swift:183`); the sole implicit exception is `Connection.fh`'s `closeOnDealloc` (`MCPServer.swift:951`). Every process and every file descriptor in this application is released by an explicit `await …stop()`. Putting a PTY inside `PaneStore.Contents` means `byProject = [:]` and `drop(paneId:)` release it — the first resource in the codebase whose release depends on ARC, and the one where that is least survivable: [#38](https://github.com/yehia-khalil/rafiq/issues/38) measured `close(2)` on a pty master **blocking forever** while a drain thread is parked in `read(2)`, reproduced twice, process in state `U`. **A cleared dictionary does not kill a shell, and here it cannot even be made to.**

So: **`TerminalStore`, an actor, held by `WindowModel` beside `panes` and `layout`, modelled directly on `MCPClient`** — single-flight async `stop()` guarded by a `teardownTask`, `terminationHandler` rather than `Process.waitUntilExit()` (`MCPClient.swift:325-356`, and the 75-second hang its doc comment records). Contents stay in `PaneStore` per #40; only the *live resource* moves. `invalidateForOrgChange()` gains a third awaited line beside the two it has.

### What actually holds the promise is a test that kills a shell

The third bucket proves someone *thought about* the PTY. It cannot prove the shell dies — the tripwire says so about itself, in its own doc comment. So the ruling adds the behavioural half: **open a real PTY through the model, `await invalidateForOrgChange()`, assert the child is reaped.**

This is affordable because #38 measured it rather than guessed: a full `bash --noprofile --norc -i` round trip — open, write, read the echo, resize, `exit`, reap — took **0.073s** inside `swift test`, with 64 concurrent pty pairs opening without failure and no sandbox interference. The `swift test` process has no controlling terminal of its own and `openpty` still works.

**An exhaustiveness check on `Pane.kinds` was the third candidate and is declined.** It is a `Set<String>` (`Pane.swift:131`), so adding `"terminal"` compels nothing anywhere — which is a real gap, and it is the *same* gap the third bucket names one level up. A third mechanism guarding what the bucket already names, whose real subject is 2c-iv's `"api"` and 2c-vi's `"board"` rather than this sub-phase, is not worth its weight here.

### What the operator sees, and the shell nobody warned about

The layout is cleared wholesale on an org switch, so **the terminal pane vanishes with every other pane.** No dead pane, no special case, nothing the switch's motion has to explain.

**The consequence is stated out loud because it is the scenario the ticket was written against:** a `tail -f` the operator forgot about dies silently, with no warning and no prompt. The switch is **not** gated on a running shell. Guard 2 refuses to start while a *mutation* is parked, and a shell is not a parked mutation — making it one would let a forgotten `tail -f` block an org switch indefinitely, which is a worse failure than the one it prevents.

### A restored terminal pane has no shell, and that is a coherent state

The pane is in the layout snapshot like any other, so returning to org A's project restores it. **The pane persists; the shell does not, and neither does the block history.** The restored pane is empty and awaits `term_open`.

[#42](https://github.com/yehia-khalil/rafiq/issues/42) is what makes this clean rather than awkward: `term_open(path:)` exists as a separate action precisely because *a shell must exist before anything runs in it*, so "a terminal pane with no PTY" is a state the action set already names. The alternative — respawning a shell at the saved path on layout load — spawns processes as a side effect of reading a file, which no other pane kind does and which no operator asked for.

### The fourth kill point has no path at all, and it is not this map's

There is **no window-close teardown anywhere in the application**: no `windowWillClose`, no `applicationShouldTerminateAfterLastWindowClosed`, no `.onDisappear` on the window (`Canvas.swift:75-82`'s is per-pane drag cleanup). The only teardown is app *termination* — `WakilAppDelegate.applicationShouldTerminate` (`AppScene.swift:46-53`) → `WindowSession.shutdown()` (`:310`) → `WindowModel.shutdown()` + `MCPSocketServer.stop()` + `WakilWiring.shutdown()`.

Today that is invisible: ⌘N is removed (`AppScene.swift:227`) so there is exactly one window, and closing it leaves an app holding two Go children and a `claude` that nobody notices. **A PTY makes it visible** — close the window and org A's shell keeps running, holding its cwd, with no surface anywhere to see or kill it.

**Ruled out of scope for this map** and tracked as [#56](https://github.com/yehia-khalil/rafiq/issues/56). It is a pre-existing hole that 2c-iii makes visible rather than creates, it belongs to whoever owns window lifecycle rather than to the terminal pane, and 2c-iii's teardown story is complete without it: pane close, org switch, app quit. The app-quit leg is already wired — `WindowModel.shutdown()` (`:4930-4935`) cancels the pumps and awaits `harness?.stop()`, and `terminals.shutdownAll()` is a fifth line in a method whose whole purpose is that.

### What this leaves owed

- **`pane_close` is a second leak site on a path nobody calls an org switch.** It ends in `await panes?.drop(paneId: id)` (`LayoutActions.swift:107`), a dictionary removal. It must await the terminal's teardown too. Mechanical once the owner is decided, which is why it is owed rather than ticketed.
- **`invalidateForOrgChange()` gains a third awaited store clear**, and `WindowModel.shutdown()` a fifth line.
- **The tripwire's `panes` and `layout` entries are wrong today**, independently of any terminal. Moving them is a correction 2c-iii makes in passing.
- **Found adjacent, unrelated to the PTY:** `WindowModel.shutdown()` cancels `eventPump`, `confirmationPump`, `observationPump` and `resumePump` but **not `providerSwitchPump`** (declared `:1181`, started `:1473`) — the only one of the five omitted. Tracked as [#57](https://github.com/yehia-khalil/rafiq/issues/57).
- **No new §9 vocabulary.** `PTY` and `terminal pane` were added by [#39](https://github.com/yehia-khalil/rafiq/issues/39); `TerminalStore` is a type name, not domain language. `north-star.md` stands over its own limit and this ticket declines to widen the breach.

## 2026-09-16 — `read_pane` learned to say what it is looking at

Resolved by [How read_pane describes a pane that is not a grid](https://github.com/yehia-khalil/rafiq/issues/40), the fifth ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map. The ticket asked how Invariant 3 — *"panes are observable; the agent can read any pane's state"* — survives a pane that is not a grid, given that `PaneStore.snapshot` emits a fixed set of fourteen tabular keys with no discriminator among them.

**The ruling, in one line: the snapshot becomes a discriminated union keyed by `kind`, the always-present-key rule survives scoped to the kind, and the five grid actions refuse a pane that is not a grid rather than no-op'ing into it.**

### The discriminator already existed, one tool over

`read_layout` has reported `kind` for every pane since 2b-i (`MCPServer.swift:313`), against a validated `Pane.kinds` set. `MCPSurface` holds `layout` beside `panes` (`:114-115`) and `readPane` is simply handed only one of the two (`:399`). So the ticket's *"no discriminator of any sort"* is true of the snapshot and false of the surface, and **the whole ruling is a one-line wiring change plus a shape change**, not new machinery.

`kind` is the `Pane.kinds` string verbatim, always present. Every key of *that kind* is always present, including when false, empty or null — `PaneStore.swift:368`'s rule unchanged in purpose and narrowed in scope. `failure` is the one kind-independent key, because any pane can fail to produce what it was asked for.

**A flat superset was the alternative and it compounds.** A terminal pane under one key set asserts `columnTypesInferred: false`, `pageable: false`, `listsTables: false` and eleven more — thirteen tabular facts true only by accident, inside an object whose documented purpose is that a reader never decodes a value it did not ask for. And every kind added would widen *every* pane's snapshot, for every reader, permanently. **Leaning on `read_layout` instead was the other alternative**: it loses because `read_pane` is named by itself in `agentAllowedTools`, so a result that cannot be interpreted without a second tool's result can be read wrong by a caller doing nothing wrong.

### Both terminal surfaces are returned, and `screen` says which one is on screen

[#43](https://github.com/yehia-khalil/rafiq/issues/43) gave the pane a **block history** and a **live grid**, with `bufferActivated(source:)` moving between them while the pane is open — so the key set varies by **runtime state inside one kind**, not only across kinds. `read_pane` therefore returns both, with `screen` reporting which the operator is actually looking at.

Returning only the authoritative surface was tempting and breaks the very rule this ticket defends: an agent that read `blocks` a moment ago finds them gone because `vim` opened — and that is exactly the moment it is most likely to be asked *"what went wrong in that build"*, a question about history asked while a pager holds the screen.

**One cost is accepted deliberately.** `snapshot` is not `read_pane`'s path alone: `refreshPanes` calls it for every pane on every change (`WindowModel.swift:2647`). So **`grid` is the visible screen only, never scrollback** — bounded by the pane's own dimensions — with history living in `blocks`, where #43's block cap already bounds it. `blocksTruncated` reports a trimmed history the way `Rows.Truncated` reports trimmed rows.

### `origin`, and the value that earns the field

A **mirrored** block — one the agent ran in its own bare-environment shell, drawn in the history by [#49](https://github.com/yehia-khalil/rafiq/issues/49) — is `read_pane`-visible, carrying `origin`: `operator`, `agent`, or `proposed`. Hiding it was arguable on context cost and loses because **Invariant 3 is a claim about honesty rather than usefulness**; a snapshot omitting blocks the operator can plainly see is `truncated`'s failure mode in a new place, and the cost is bounded by the block cap and skippable the instant `origin` names it.

**`proposed` is what makes the field load-bearing.** #43 took the input line away from Wakil, so a `term_propose`d command lands on a surface Wakil draws and the shell does not own — and without `proposed` in the snapshot **the agent cannot tell whether its own proposal was accepted, discarded, or still sitting there**, which is the single thing it most needs to read a terminal pane for.

### An unknown pane id answers `kind: null`, and its old justification is gone

The non-error stands; the argument for it does not. `MCPServer.swift:687` reasons that *"`PaneStore` has no registry of ids, by its own documented contract, so 'unknown' and 'written to, then empty' are genuinely the same state."* True of `PaneStore` and **false of the window: `LayoutStore` is a registry of open panes**, and has been since 2b-i. What was actually missing was never an error but a discriminator, and `kind: null` supplies it without making `read_pane` fail on the honest case the original reasoning protected — a freshly launched window drawing "no rows" before any query.

Erroring is now genuinely available where it was not in 2a. It is declined on two grounds: an MCP `isError` costs the agent a turn and teaches it nothing the field does not, and a pane can close between the `read_layout` that named it and the `read_pane` that asks — a race that would turn a correct sequence of calls into a failure.

### The grid actions refuse, and the gap that opens is deliberate

`pane_select_cell`, `pane_select_rows`, `pane_set_column_width`, `pane_scroll_to_row` and `pane_scroll_clear` refuse a pane whose kind is not a grid, naming the kind. `registerPaneContentActions` already takes `layout:` and uses it for one line (`:141`), so the check costs no wiring.

**No-op'ing is today's behaviour and it is a failure this log has already recorded twice.** An agent calling `pane_select_cell` on a terminal id writes a selection and a `scrollTarget` into a `PaneStore` entry nothing draws, gets a success back, and believes it selected something — the `kind: "database"` incident's shape (`Pane.swift:118`), a call nothing rejected and nothing looked wrong about, from a fourth cause.

**Reinterpreting them was the interesting option and loses on one word.** `row` is documented three times over as a zero-based index into the displayed order *that a sort changes* (`PaneContentActions.swift:25-32`). A terminal has no sort, and `row` would then mean a table row, a block, or a terminal line depending on kind and current `screen` — three incompatible meanings behind one parameter, in the one place the file says only one of them can be what the actions and `read_pane` both mean.

**The gap is real and stays open on purpose.** A terminal pane is left with no scroll and no selection action, so an agent cannot bring a block into view the way it can a row, and Invariant 2 wants a pane driven both ways. A terminal read/scroll action is owed alongside [#42](https://github.com/yehia-khalil/rafiq/issues/42)'s `term_open`: #39's account reaches **four** actions, not two. Mechanical once the refusal is decided, which is why it is owed rather than ticketed.

### Storage, and the boundary against #41

`PaneStore.Contents` becomes an **enum over kinds** — `.grid` / `.terminal` — in one store with one `snapshot` that switches. A separate `TerminalStore` would duplicate everything `PaneStore` earns its keep on and that a terminal needs identically: project-keyed contents (final review Finding 6, where one project's `db-1` answered with another project's rows), `switchProject`, and §13's requirement that panes are never torn down on a project switch and their state stays warm — and a shell the operator left running is the *most* warm-state thing on the canvas.

**This decides nothing about where the PTY lives.** The store holds a rendered value — text, marks, exit codes — not a process. [#41](https://github.com/yehia-khalil/rafiq/issues/41) still owns the PTY and the org-switch tripwire, and nothing here narrows it.

### The view stops reading the agent's JSON

`refreshPanes` draws the screen today by re-parsing the agent-facing snapshot JSON — `paneTable(from: JSONValue)` (`WindowModel.swift:162`), for every pane id on every change. `snapshot` gains a typed return and JSON serialisation moves to the MCP boundary.

The round-trip was doing real work and it is not the work it looks like. What 2c-i's final review required is that **one sort is applied once** (Finding 1), so the agent's rows and the screen's rows are one sequence rather than two — and a typed value satisfies that identically while letting the compiler check the union. Keeping it means a hand-written JSON parser in `WindowModel` per pane kind, whose failure mode is a **silently empty pane**: the symptom `Pane.swift:118` records from two causes already, and the one this app is worst at surfacing.

### What this leaves owed

- **Three doc comments are amended by this ruling and none is amended here**, because the map plans rather than builds: `PaneStore.swift:368` (always-present, now *per kind*, with the reason), `MCPServer.swift:233` (the `tools/list` prose describes exactly the tabular fields and must describe both shapes), and `MCPServer.swift:687` (its justification is falsified above and must be rewritten, not merely trimmed). They join `ActionKind`'s wrong comment, owed to 2c-iii since #39.
- **`readPane` must take `surface.layout`** (`MCPServer.swift:399`). One line, and the whole ruling rests on it.
- **#39's action account reaches four** — `term_propose`, `term_run`, `term_open`, and a terminal read/scroll action — for the end-of-map pass.
- **2c-iv is a third kind, and this ruling is what makes that a spec question rather than a map one.** The ticket's scope note named 2c-v and not 2c-iv, which is backwards: 2c-v is cut, and `ApiClient.dc.html` draws the pane's *history* as a result set (*"History is not a feature, it is the data surface pointed at this pane's own log"*, the comment above `.hrow`) while the request and response it holds are not rows. The union is deliberately extensible; 2c-iv's payload belongs in 2c-iv's spec.
- **No new §9 vocabulary, deliberately.** `block history` and `live grid` were added by #43 and are what this reuses. `north-star.md` stands at 4,029 words against its 4,000 limit and this ticket declines to widen the breach.


## 2026-09-16 — "per-root shells" was never a feature, and the roots came out

Resolved by [What per-root shells means when only rootPaths.first is used](https://github.com/yehia-khalil/rafiq/issues/42), the fourth ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map. The ticket asked what §8's phrase *"per-root shells"* could mean, given that `ContextStore.ActiveContext.rootPaths` is plural and every consumer in the window takes `.first`. **The operator's answer removed the premise rather than choosing between its options:** a terminal pane opens **at a path**. Not at a root. Nothing tracks which root a path belongs to, and *"open a terminal in that directory"* is the whole of the instruction.

**The ruling, in one line: the path is a parameter of opening the pane, and the root concept leaves 2c-iii entirely.**

### What the ticket got wrong, and what the artboard already knew

**The ticket never cites its own artboard, which had ruled on this.** `Terminal.dc.html:127-131` says it plainly — *"Per-root shells, and NO tab bar — §1 forbids one. The header names the active root and says how many there are; switching is ⌘P… A second root whose last command failed surfaces here as one chip rather than as a strip of tabs you have to read."* It renders `under api · root 1 of 3 · ⌘P`, an `Infra · exit 1` chip belonging to a *different* root, and `This root` / `All roots` on both ⌘F and each block. So the drawing had already picked the ticket's third option — N shells, the pane a view onto one of them — and the ticket argued as though the question were open.

**And the ticket's premise is false in two places.** `rootPath` is the **fresh-session default**, not the app's model of roots. `resume()` launches in `thread.cwd` (`WindowModel.swift:3794`) — the session's own recorded directory, which is whichever root it was started under, including one started outside Wakil. And the capability layer enumerates *every* root: `ListSessions` walks `ProjectRootPaths` (`sessions.go:341`), which is what `phase-1-acceptance.md:581` asserts by name. Roots were never unused; they were unused **in the window**.

### The cost the ruling avoids, which is the reason it is right

Naming a root means naming it *something*. The artboard names roots by **role** — `root: api`, `Infra` — and `Root.Role` does exist (`config.go:19`). But `Resolved.RootPaths` is `[]string` (`resolve.go:27`): the wire carries paths and drops roles, so no root ever reaches Swift with a name on it. Any pane that displays a root therefore forces a choice between widening the wire and inventing a label in Swift — and `resolve.go`'s own doc comment rules the second one out, on the grounds that re-deriving root facts in Swift is *"a second implementation of a rule that lives here."*

**Opening at a path makes that whole branch disappear.** No role on the wire, no label to invent, no counter, no selector, and — because a project with one root is the common case — no affordance that has to know how to vanish.

### What this removes from the redraw

[#49](https://github.com/yehia-khalil/rafiq/issues/49) inherits a shorter artboard. Cut: the `root 1 of 3` counter, the cross-root `Infra · exit 1` chip, the `Outside every root` chip and its banner, `This root` / `All roots` on ⌘F, and `All roots` on a block. The last of those was never affordable here anyway — a command fanned out across roots is **cross-pane reference**, which this map already records as unbuilt fog belonging to 2c-iv. What survives is the artboard's honesty about the live cwd, which [#43](https://github.com/yehia-khalil/rafiq/issues/43) requires regardless via OSC 7.

### Decision 7 is not consumed here, and 2c-iii is not its first consumer

The ticket asked whether a terminal pane makes roots visible for the first time. **It asked the right question and the answer is no.** The only other multi-root promises in the doctrine are the Git pane (*"Dedicated, multi-root. Changes grouped by root"*, `design-language.md:290`) and the editor's file tree (*"multi-root, all project roots as top-level folders"*, `:311`) — **both Phase 3**. So Decision 7 (*"a project has N roots, not one repository"*) stays unconsumed by any UI surface until Phase 3, and the app goes on behaving as though N = 1 for the whole of Phase 2. That is now a recorded fact rather than an accident, which is all this ticket was ever able to change about it.

### A third action, and a finding against #39

[#39](https://github.com/yehia-khalil/rafiq/issues/39) enumerated exactly two terminal actions, `term_propose` and `term_run`. **That enumeration is incomplete, and this ticket is what discovers it.** A database pane's first action carries everything it needs — `db_run_query` names its own query — but a shell has to *exist* before anything runs in it, and [#43](https://github.com/yehia-khalil/rafiq/issues/43) gave the input line to the shell, so the operator's first typed command never passes through an action at all. Without a third action there is no tool by which an agent can do the thing the operator described.

So: **`term_open`, taking `path`**, `.control` like the other two, allowed by the write gate everywhere. The mechanism is already built — `resolvePane` (`StandardActions.swift:1771`) opens a pane when the call named none and titles it from the subject, which is how `db_run_query` titles a pane by its database. The terminal titles by the path.

### Any path, and the asymmetry that creates

A path outside every project root is **allowed, silently**. Refusing one would be theatre: it is a real PTY and `cd` walks out of any fence at will, which the artboard itself concedes in *"YES, `cd` ANYWHERE."* The header carries the live cwd and says nothing further.

**Recorded deliberately, because it is discoverable later as a bug:** this makes the terminal *more permissive than session reads*, which `wakil-ctx` already refuses for a cwd that is not a root of the active project (`cmd/wakil-ctx/main.go:186`, via `cwdMatchesAnyRoot`). The asymmetry is intended — a shell is not an agent session — and the real boundary for a shell is the write gate and the injected environment, which §8's row for 2c-iii already names as its third concern.

### No tabs, and a row corrected

**The terminal pane has no tabs.** `design-language.md`'s pane table said *"Multi-tab? Yes (sessions)"* and was the only source that did: §1's first principle names tab bars among what has been removed, the artboard forbids one outright, and §9's glossary entry is singular — *"the pane hosting **an** interactive shell."* The row is corrected here, together with its note.

The argument for tabs is real and loses on a distinction worth writing down. Editor and Browser do carry ⌘T tabs, and #43 ruled the pane should *"behave as close to a terminal as it could"* — real terminals have tabs. But editor and browser tabs hold **documents**: cheap, disposable, opened by the dozen. A shell is durable state with a live process, and every pane whose subject is a piece of work — database, API client, PM — is already `Multi-tab? No`. #43's ruling was about fidelity *inside* the grid, not chrome around it. There is also a concrete cost: tabs mean N hidden PTYs per pane, so [#41](https://github.com/yehia-khalil/rafiq/issues/41)'s org-switch teardown would have to walk tabs inside panes rather than panes — and one PTY per pane is what made #41 cheaper. Nothing is lost: two shells at one path is two panes.

### What this leaves owed

- **§8's 2c-iii row and §9's glossary entry are amended here** — *"per-root shells"* became *"a shell opened at a path"*, and the glossary's *"under one of the project's roots"* became *"opened at a path"*. Net **+2 words** on `north-star.md`: the glossary line is two cheaper, the §8 row four dearer.
- **The 4,062-word figure this map has been budgeting against is wrong.** `wc -w` on `north-star.md` reads **4,027** before this ticket's edits and **4,029** after. The limit is still breached and the trim candidates named in the terminal entry below still stand, but a ticket that must add vocabulary has ~33 more words of headroom than it has been told.
- **`term_open` wants adding to #39's account** when the end-of-map pass promotes these rulings to `decisions.md`; #39's entry in this log says two actions and will then say three.
- **A defect this ticket exposed but did not cause:** `autoResumeAfterSwitch` matches `cwd == rootPath` (`WindowModel.swift:3919`), so after an org switch a session living in any root but the first is never resumed and the operator silently gets a fresh one — and `PaletteItem` carries no `cwd`, so ⌘P cannot say which root anything is in either. Filed as its own ticket on the map. It blocks nothing in 2c-iii.

## 2026-09-16 — the terminal is a real terminal, and the shell has to help

Resolved by [Does the terminal pane emulate a terminal?](https://github.com/yehia-khalil/rafiq/issues/43), the third ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map. Recorded here by [#52](https://github.com/yehia-khalil/rafiq/pull/52), `4527735`. The ticket asked how much of a terminal the pane emulates. **The answer is all of it**, on the operator's instruction — *"I want this to behave as close to a terminal as it could"* — and the cost of that answer is the substance of this entry.

**The ruling, in one line: take SwiftTerm, give the shell the input line, require shell integration, and support zsh and bash by name.** The pane gains two surfaces — a **block history** and a **live grid** — and both are now §9 vocabulary.

### Two premises this ticket carried, both corrected

**One, and it was mine rather than the ticket's.** The ticket said cursor movement and erase are *"unavoidable for a shell prompt with line editing."* Read against `Terminal.dc.html`, that looked false: the artboard draws the operator typing into a *Wakil-drawn* line, where `term_propose`'s pending command lands with *"⏎ to run · ⌫ to discard"*, and [#39](https://github.com/yehia-khalil/rafiq/issues/39) had already ruled those keystrokes are text-field editing rather than actions. On that reading the emulator collapses to SGR, `\r`, `\b`, `\e[K` and tabs — no cursor addressing, because nothing repaints. **That reading was put to the operator and rejected**, and correctly: a pane that cannot run `vim` is not a terminal, and the whole gap between the two readings is the alternate screen.

**Two, and this one stands.** With a persistent shell — which the artboard commits to twice, in *"YES, `cd` ANYWHERE — it is a real PTY"* and in a header carrying the **live** cwd — a PTY master is one undifferentiated byte stream. Nothing in it says where `ls`'s output ended, what the exit code was, or that the cwd changed. The artboard draws all three per block. **That machinery was unbudgeted anywhere on this map**, and it is a larger cost than the VT question the ticket was opened about.

### SwiftTerm, measured rather than recalled

The package was cloned and read, not remembered. MIT, macOS 11+ against the package's 14.4, xterm.js lineage, `Terminal.swift` at 9,983 lines, headless and therefore testable in `WakilKit` — which is where [#38](https://github.com/yehia-khalil/rafiq/issues/38) established the PTY can live too, so the untestable `WakilApp` gets only the drawing, exactly as for every other pane.

Four things it already has that this map assumed would have to be written:

- **`SemanticPrompt.swift` — OSC 133 is parsed and stored.** `SemanticContent` is `.prompt`/`.input`/`.output`, marks survive scrolling, and prompt groups exist. **Corrected 2026-09-17:** this line read *"marks survive scrollback"*, taken from SwiftTerm's own doc comment when the engine was read. `phase-2c-iii-probe.md` §4.1 measured otherwise — a mark dies with its row when the scrollback cap evicts it, so the block history cannot be derived from the buffer and is captured at each `D` mark into Wakil's own storage instead. This is where the claim entered the repository, which is why the correction is here rather than only in the probe. This is the block-boundary machinery of the previous section, already built.
- **`hostCurrentDirectory` and `hostCurrentDirectoryUpdated(source:)`** — OSC 7 parsed, which is the artboard's live-cwd header served directly.
- **`bufferActivated(source:)`** — the alternate screen announces itself, so the pane knows when a foreground program has taken the screen.
- `SearchEngine`/`SearchService` for ⌘F, plus `Pty.swift`, `LocalProcess.swift`, Unicode width tables and a Metal renderer.

**What it does not give.** It *consumes* OSC 133; nothing *emits* it — the generated rc is still Wakil's to write. The stored marks are `A` and `P`; the exit code rides `D;<code>` and was not found retained, so capturing it is Wakil's too. And the macOS view is AppKit (`MacTerminalView`); the SwiftUI wrapper is iOS-only. **Using that view would put Terminal.app inside Wakil** — no blocks, no per-block affordances, nothing from `design-language.md`. Only the headless engine is taken; the grid is drawn in SwiftUI.

**This is `WakilKit`'s first external dependency.** The package has had none, and `2d-stt-probe.md` §2 faced the same shape over WhisperKit — which then lost its probe, so the count is still zero. The difference is that WhisperKit was one of two ways to get the same result, and here there is no second way: the gap between a 300-line SGR parser and a terminal is the alternate screen, and the alternate screen is the whole emulator.

### The part that costs the charter, and why shell integration is not optional

**Invariant 2 stops holding by itself the moment the shell owns the input line.** In a real terminal the operator types into the shell — readline, tab completion, ⌃R. Wakil then sees keystrokes, never a *submitted command*. `term_run`, which #39 made an enumerated, journalled action and the seventh member of `operatorOnlyActions`, has no trigger, and *"actions are the only mutation path"* fails at the window.

**OSC 133 `C` is what rescues it.** The shell reports that a command started; Wakil journals `term_run` from that report rather than from its own input field. #39's journal fields are unchanged, including the one that records whether the command was proposed by the agent and accepted or typed by the operator.

So shell integration is **load-bearing for the charter**, not a nicety, and that is why unsupported shells are **refused at pane-open rather than degraded**: a degraded mode is a mode in which commands run outside the action registry. **zsh and bash are named**, the way Invariant 6 refuses DDL by naming each verb rather than by omission. The operator uses zsh, so the practical cost is nil.

**`term_propose` loses its surface, and that is a real gap.** #39 assumed a Wakil-drawn input line to land the proposal in. With the shell owning it, Wakil can only inject bytes, and injected bytes are indistinguishable from typed ones — so *"Proposed by Wakil · not run"* needs a drawn surface that does not exist yet.

### The two surfaces

**Block history** — finished blocks, reconstructed from the OSC 133 marks, Wakil-drawn, scrollable, searchable, carrying Copy / Rerun / exit code / duration. **Live grid** — the foreground program, which is the whole pane when something takes the screen. Both are now in §9, on the **Terminal pane** entry rather than as two rows of their own, because the split is a property of the pane.

This is what makes the artboard survive the emulator. A character grid cannot draw an **Open** button beside a file, so the structured-output rendering the artboard shows for `ls` is a per-command allowlist over the block history — which the artboard already anticipated: *"opt-in per command and it degrades to text the moment the shape is not recognised."*

**Scrollback is bounded in blocks, not lines**, with a line cap inside each. ⌘F already counts in blocks and #39 made the block the unit of state; *"the last 200 commands"* means something to an operator where *"10,000 lines"* does not. The bound is reported the way `Rows.Truncated` is, so a trimmed history is never mistaken for a short one.

### Mirroring the agent's shell: kept, and reshaped

The operator asked directly whether *"I see what the agent is running, in realtime"* survives. **It does, and nothing here removes it** — but two things about it are now settled that [#49](https://github.com/yehia-khalil/rafiq/issues/49) did not have.

**Timing.** `toolUse` arrives the instant the agent issues the call, *before* the command runs; `toolResult` arrives whole when it finishes (`StreamJSON.swift:35,51`). So the block appears immediately and fills in on completion. **Characters do not scroll as they are produced, and cannot** — `permission-prompt-probe.md` §7 established that the agent's `Bash` calls are auto-allowed by CLI policy and never reach Wakil, so Wakil learns of them from the transcript rather than by running them. Realtime is true of *what it is running*, not of *watching it scroll*.

**Placement, which is new.** A mirrored block does not come from the pane's PTY, and foreign rows cannot be spliced into a live emulator buffer without lying to the shell about where its cursor is — and it breaks outright under a full-screen program. **The mirror lives in the block history and never in the live grid**, pausing while a foreground program holds the screen and catching up when it exits. #39's three constraints on it are untouched.

### What this leaves owed

- **2c-iii is roughly twice the size of its one-line row in §8** — a dependency, a generated rc per shell, a custom SwiftUI grid renderer, a drawn proposal surface, and the two-surface split. The row is not amended here; [#50](https://github.com/yehia-khalil/rafiq/issues/50) owns what that table says.
- **Throughput is a pre-registered probe inside 2c-iii**, not a map ticket: `cat` of a large file and a build's output, through SwiftTerm's parser, a SwiftUI grid and the `.unbounded` `AsyncStream` #38 flagged. 2c-i's probe found a 5.3-second first layout nobody had measured, and a custom grid renderer at 120fps is that shape of unknown.
- **The dependency wants a numbered Decision** with its reversal condition, in the end-of-map pass rather than now — per this map's Notes, numbers are assigned in one pass.
- `ActionKind`'s doc comment is still wrong and still owed to 2c-iii, unchanged from #39.

### The limit, again

§9's **Terminal pane** entry gained the two surfaces. It was paid for: §8's *"How to read `Met`"* paragraph lost its 2026-09-15 narrative half to a pointer at the entry in this file that already carries it — the candidate #39's session named, executed rather than shaved at random. `north-star.md` is now **4,027 words against its 4,000 limit**, down from 4,062 and still over. The one remaining named candidate, §6's *"Read the third column first"*, was deliberately not taken: it carries a live count — 15 of 22 decisions with no stated reversal condition — that nothing else in the repository carries.

## 2026-09-16 — the terminal's two actions, and the discovery that the agent already has a shell

Resolved by [The enumerated action behind a terminal pane](https://github.com/yehia-khalil/rafiq/issues/39), the second ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map. The ticket asked what the enumerated action behind a terminal pane is, and whether such a pane can be dual-driven at all.

**The ticket's central premise was false, and correcting it is the most useful thing here.** It argued the gate fork had exactly two prongs, because `.mutate` actions "would not appear in the agent's tool list at all." They do. `tools/list` projects **every** registered action, `.mutate` included (`MCPServer.swift:138`), and `permissionDecision` says so outright — *"Every kind is allowed, `.mutate` included, and that is the point"* (`PermissionPrompt.swift:147`). `agentAllowedTools` is a **pre-approval** list, not a visibility list; filtering `.mutate` off it is precisely what routes such a call through the CLI's permission prompt and into the confirmation plane. That is the bridge, met 2026-09-10, walked. There was always a middle prong.

**#37's ruling survives the correction, on a better reason.** The run stays operator-only not because an agent-dispatched `.mutate` is mechanically impossible, but because Invariant 6 admits no write that cannot be classified, and a shell command cannot be. `classify_statement` works on SQL because SQL has a bounded grammar and enumerated verbs. A shell has neither: `ls > file` writes, `find -delete` deletes, `make` and `npm test` run arbitrary code, and `;`, `&&`, `|` and `$()` compose anything out of anything. No honest read/mutate split exists over a free-form command string, so the operator-only run is a **policy** choice with a stated justification rather than a mechanical consequence.

### The two actions

**`term_propose` — `.control`, agent-reachable, ungated.** Writes a command into the pane's prompt in the visibly distinct state `Terminal.dc.html` already draws (*"Proposed by Wakil · not run / ⏎ to run · ⌫ to discard"*). `.control`'s existing definition is literally true here: nothing outside Wakil is touched. **At most one pending proposal per pane**; a second replaces the first and the replacement is itself journalled, so an agent cannot silently swap the command under a hand already moving to Enter. Note this is *not* `db_render_update`'s case — that action is `.read` because it only returns a statement, where a propose writes pane state.

**`term_run` — `.control`, operator-only, the seventh member of `operatorOnlyActions`.** It gets its own denial sentence: `operatorOnlyDenialMessage` is a three-family switch and this is a fourth family, not a reuse.

**Why `.control` and not `.mutate`, which is the harder half.** `.mutate` breaks twice. `writeGate` gates it **everywhere** except production, so every `ls` would cost a typed confirmation. And it `.block`s in production **regardless of origin**, so the pane would die exactly where an operator most wants a shell. Neither is survivable, and the pane is not worth building under either.

**What this costs, stated rather than buried:** `ActionKind`'s own doc comment says `.control` means *"The world outside Wakil is untouched."* For a shell run that is false. Choosing `.control` redefines it as **"not gated by environment"** rather than "doesn't touch the world," and the next reader of that enum will trip on it unless the comment is amended in 2c-iii. The justification is that the instrument protecting this action is `operatorOnlyActions` plus the in-pane ⏎, **not** `writeGate`: a command typed by the operator and submitted by hand is neither an unreviewed agent mutation nor an unclassified statement, which is what the gate was built for. A fourth `ActionKind` would have been the honest alternative and was rejected as charter-level cost for no behavioural gain.

### Granularity: the block

**One action per submitted command.** Keystrokes into the prompt are text-field editing, not actions — the precedent is the DB pane, which has **no action for typing in the query editor**; `db_run_query` takes the whole statement. `Terminal.dc.html` already counts in blocks (*"3 blocks"*, *"1 block hidden · no match"*) and every per-block affordance it draws — Copy, Rerun, exit code, duration, Send to thread — presumes the block is the unit. **Block** is now a glossary term.

**Known cost, and it belongs to [#43](https://github.com/yehia-khalil/rafiq/issues/43):** this gives no action model at all for an interactive program that never returns a prompt — `vim`, a REPL, `top`.

### What the run's journal entry records

Command, cwd, root, the active (org, project, environment), origin, exit code, duration. **Not the output** — it is unbounded, and the artboard's own example is a `keychain` grep, so the journal would become the place secrets accumulate. `read_pane` is where output is read.

Plus one field the obvious list misses: **whether the command was proposed by the agent and accepted, or typed by the operator.** Those are materially different events, and after the fact the journal is the only place the difference survives.

### The discovery: the agent already has a shell, and it is not the pane's

The operator asked the right question — *must every read and every navigation cost my Enter key?* — and the answer turned out to be that it already doesn't, by a route nobody on this map had noticed.

**The agent can already run read-only shell commands, today, and Wakil cannot stop it.** `permission-prompt-probe.md` §7, re-measured 2026-09-10: `Bash cat inside.txt` is **auto-allowed by CLI policy and never reaches Wakil's prompt tool at all**. Only paths outside the session's working directory arrive, and those are denied in Wakil's words. So *"the agent may not run"* was never a statement about the agent's ability to execute shell, and #37's phrasing should be read narrowly: it may not run **in the pane's PTY**.

**Which means the delta a permissive terminal would open is credentials, not reads.** The harness builds the agent's child environment **from nothing** — `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`, `HOME`, `PATH`, and that is the whole dictionary (`ClaudeCodeCLIHarness.swift:113`). The terminal pane's PTY is the opposite: per the artboard it *"carries staging's environment variables and Initech Labs' credentials."* Letting the agent run in the pane would not buy it reading; it would buy it **reading with the org's credentials and the active environment attached**, which is precisely the part worth a keystroke.

**And the credentialed reads worth wanting are Invariant 9's territory anyway.** `wakil-db`, `wakil-http` and `wakil-pm` already do credentialed reads, classified, through capabilities. The shell is the **residue** — what Wakil has no capability for. The operator confirmed that residue (`kubectl get pods`, `aws s3 ls`, `docker ps`) is **rare rather than daily**, so it is worth exactly one Enter, and **no agent-reachable run ships**.

**Two shapes were considered and rejected.** A `term_rerun <blockId>` taking an enumerated block id and no new string was rejected outright: *"the operator ran it once"* is not consent to it running at arbitrary times later, and `npm run deploy` is a block too. An operator-marked rerunnable block is the honest version of the same idea and is **deferred, not refused** — the friction it would relieve is unmeasured until the pane exists, and this repo has form for deferring exactly this (D1, deliberately unfixed).

### What the operator actually wanted, which was a different axis

Not permission — **observability**. *"When a terminal is open, I want to see the commands the agent is running."*

**The plumbing already exists.** Every tool call the agent makes arrives at Wakil on the harness stream with its full input and output — `toolUse(id:name:input:)` and `toolResult(id:content:isError:)` (`StreamJSON.swift:35,51`) — including the `Bash` calls the CLI auto-allows and never asks Wakil about. Wakil already *receives* every command the agent runs; today it renders them only in the thought thread. Mirroring them into an open terminal pane is a rendering decision, not a new capability, and needs no new permission.

**It is not an action**, which is why it is not settled here: nothing is dispatched and nothing is journalled as a state transition, so Invariant 2 is not engaged. It graduates out of this map's fog as its own `wayfinder:prototype` ticket — [What a terminal pane shows of the agent's own shell](https://github.com/yehia-khalil/rafiq/issues/49) — with three constraints already ruled on:

1. **A mirrored block must be visibly distinct, and must say where it ran.** It ran in the agent's process: different cwd, **bare environment**. Drawn like a block the operator ran, it would be read as having run in the operator's shell, with the operator's credentials. `Terminal.dc.html` has two block treatments today (operator-run, Wakil-proposed) and this is a third.
2. **`Bash` only.** A terminal is a shell surface; file reads and edits belong to the thought thread now and the editor pane in Phase 3. Mirroring every tool turns the terminal into a second, worse thought thread.
3. **`Rerun` on a mirrored block becomes a proposal, not a run.** This is a credential escalation otherwise: the agent ran the command with a bare environment, and one click would re-run it with the org's credentials and the active environment attached — the propose path wearing a disguise, reachable by an agent that knows `Rerun` exists. Routing it back through *"Proposed by Wakil · not run"* collapses it into the path that already exists instead of minting a second one. `Copy` and `Send to thread` are unaffected.

### What "fully dual-driven" means for a pane that is not a grid

2c's exit criterion asserts it and never decomposes it. The definition, general and applied per pane:

1. Every state transition in the pane is a **registered action**.
2. `read_pane` returns the pane's **full state**, so the agent sees what the operator sees.
3. Every action is **agent-dispatchable** except those listed in `operatorOnlyActions`, each with a written reason.

The terminal passes with exactly one entry under (3). Clause 2's *content* for a stream rather than a grid is [#40](https://github.com/yehia-khalil/rafiq/issues/40)'s and stays there. Whether the 2c sub-phase table grows a third column so each sub-phase states its own exit criterion is now sharp enough to ticket and graduates as [Do 2c's sub-phases get their own exit criteria?](https://github.com/yehia-khalil/rafiq/issues/50).

### Glossary, and a limit breached

`PTY`, `terminal pane`, `write gate` and `block` were all absent from §9 — the first three found by [#38](https://github.com/yehia-khalil/rafiq/issues/38), and `writeGate` is cited constantly across the specs while being defined nowhere. All four are added rather than worked around, per this map's Notes.

**That puts `north-star.md` at 4,062 words against its own 4,000-word limit, and the rule is being failed loudly rather than quietly.** Two duplicated narrative paragraphs were moved to pointers first — §8's account of the 2d split and §7's account of the `Blocks` column going stale, both of which `phase-log.md` already carries under their own headings — which recovered 116 words and was not enough. The remaining candidates, for whoever picks this up: §8's *"How to read `Met`"* paragraph (~130 words, narrative belonging to "The 2026-09-15 acceptance") and §6's *"Read the third column first"* paragraph. This was not fixed inside a terminal ticket by shaving prose at random.

## 2026-09-16 — 2c's definition became a criterion, one pane was cut, and the terminal is not an exception

Resolved by [Which panes ship, and what is 2c?](https://github.com/yehia-khalil/rafiq/issues/37), the first ticket of the [The rest of 2c](https://github.com/yehia-khalil/rafiq/issues/36) map. Three rulings.

**One — §1's arbitration test was applied to all four unbuilt panes, and the session browser failed it.** Terminal, API client and PM board ship. **2c-v is cut.** The terminal's absence sends you to Terminal.app several times an hour. The API client is not merely justified but *mandatory*: Phase 2's exit criterion ends *"then call the confirmation endpoint with that ID"*, and that clause is 2c-iv and nothing else. The PM board's test was already run and recorded — Invariant 6's 2026-09-14 amendment says a transition *"is the only operation whose absence forces the operator out of Wakil and into Jira's web UI, which is §1's arbitration test applied to a single verb."*

**The session browser could not be made to pass, and the reason is that the thing it sounded like already ships.** *Continuing sessions per project* is 2b-v, met 2026-09-10: ⌘P lists this org's past sessions scoped to the active project's roots, and picking one forks it under a fresh Wakil-minted id with recorded lineage and its thought thread rebuilt. What a *browser* would have added is narrower than its name suggests, and is exactly what `sessionPaletteItems()` throws away: reading a transcript **without forking** (the palette never calls `session_read`, so every peek today mints a session), the lineage `session_record_parent` writes (`sessionItems(from:)` deliberately collapses resume chains), and each session's `provider` and `cwd`. **Reverse if** reading a past session without resuming it turns out to be something the operator does often enough that the fork trail is a cost — that is the justification the pane never had, and it can be re-scoped on it.

**Two — 2c's row stopped enumerating panes and started stating a criterion.** It read *"DB pane in full, API client pane, terminal pane, session browser"* / *"Each fully dual-driven"*. **The enumeration is what drifted**: 2c split into five on 2026-09-12 and the row was amended; the PM board was added on 2026-09-14 and it was not, so for two days the phase's definition and its contents disagreed and nobody noticed. Delivers now points at the sub-phase table instead of duplicating it, so there is one list rather than two that can diverge, and the exit gains *"the phase ships"* so it survives a cut or an addition.

**The same four-pane wording is restated verbatim in four dated design specs** — `2026-09-07-phase-2a-spine-design.md:17`, `2026-09-08-phase-2b-i-structure-design.md:21`, `2026-09-09-phase-2b-ii-atmosphere-design.md:20`, `2026-09-09-void-as-core-design.md:24`. **They are deliberately left alone, and nobody should later "fix" them.** They are dated records of what was true when each was written; this file is the live status document. That distinction already operates here — `2d-stt-probe.md` records an erratum rather than editing itself, and `phase-2c-ii-b-acceptance.md` says at its head that a later decision overrode its instruction rather than being edited to match.

**Three — the terminal pane is not an exception to dual-drive.** `Terminal.dc.html` proposed that the agent may read the pane and propose into it but may not run, because a shell command cannot be classified the way `classify_statement` classifies SQL, and Invariant 6 will not admit a write that cannot be classified. **That design is upheld in full. Its characterisation is not.** The artboard called it *"the second partial exception to dual-drive"*; Invariant 2 says UI controls and the agent dispatch *the same actions*, not that the agent may dispatch *every* action — and `operatorOnlyActions` (`PermissionPrompt.swift:91`) already holds six enumerated, journalled actions the UI drives and the agent is denied, enforced twice. A terminal with an agent-reachable *propose* and an operator-only *run* is that mechanism applied to a seventh action, not a hole in the invariant. **So 2c's exit criterion needed no weakening**, and the artboard was corrected rather than enshrined.

**2c split into five, 2026-09-12** — the spec's own §0 records the agreement itself as
2026-09-11, one day before this row is amended to say so — for the same reason 2b split
on 2026-09-08 and 2b-iii split again on 2026-09-09: 2c's row above names four panes, and
building the first of them turned up a fifth, independent subsystem hiding inside all
four — the surface each was going to draw its rows on. Decision 9 records that
dual-drive cannot be retrofitted, so that surface is split out and built first rather
than inside whichever pane happens to come first and extracted once a second consumer
appears, which would carry one pane's assumptions into every pane built after it.

| | Delivers | Exit |
|---|---|---|
| **2c-i** | The data surface: the grid, the selection model, virtualization, §8's chrome, and the move of pane contents out of the window and into panes | Rows are drawn on one shared surface that more than one pane kind can consume, selection and virtualization hold at size, and pane contents live in panes rather than in the window — **MET 2026-09-12, by a walked runbook.**All fourteen checks in `phase-2c-i-acceptance.md` were run by the operator against the live app; the walk found six defects and forced two rulings no test or review had caught (that runbook's §5 items 8–13 and §7). |
| **2c-ii** | DB pane in full — the pane owns its query, and the schema browser, pagination, sort-as-re-query and relaunch are four consumers of that one change rather than four features. Paging is offset paging in the driver, which wraps the operator's statement only when it must; the schema browser is the data surface pointed at metadata, with §8's first hover-revealed row action drilling into a table. **Two things were added to this row on 2026-09-12**, both from brainstorming: the query line routes a mutation to 2b-iii's confirmation plane, asking `classify_statement` before it runs anything rather than running and catching a refusal; and **the routing default inverted** — naming a pane refines it, omitting one opens a new pane. That inversion is the only behaviour 2c-i's walk signed off on that this sub-phase changes, and it is the operator's own flow: *query A, filter, filter, sort* is one subject, *query B* is another. | The criterion its spec §14 states and `phase-2c-ii-acceptance.md` §1 quotes in full, and this cell deliberately does not restate: a `db` pane owns its query, and the schema browser, pagination, sort-as-re-query and restore are consumers of that one fact rather than four features beside it — **MET 2026-09-13, walked ×3.** |
| **integer fidelity** | **A fix, not a sub-phase, and it belongs on this table because it shipped and nothing here said so.** `JSONValue` had one numeric case — `number(Double)` — and its decoder tried `Double` first, so every JSON number Wakil received became a `Double`, which stops representing integers exactly above 2^53. Measured through the real `collectRows` path on both engines: a row keyed `9007199254740993` arrived in Swift as `…992`. One cause, three failures — the grid drew the wrong digits, `sortedRows` tied wrongly, and **`read_pane` handed the agent the wrong key**, so the agent could propose `UPDATE … WHERE id = …992` and the confirmation plane would show the operator a correct-looking statement aimed at a row that was not theirs. That was a **live breach of Invariant 3** on the path feeding the write gate, reachable with no cell editing in the product at all, and there was no correct copy of the value anywhere in the app — it was lost at decode. Its spec's §10 says why it is its own piece of work: it is a defect in 2c-i's data surface and in the MCP boundary, both of which shipped before 2c-ii-b was scoped. 2c-i's row above therefore reads clean for a phase that shipped with this in it. Added 2026-09-15; the charter had not mentioned it at all | **None, and the blank is the honest answer: this is a fix, not a sub-phase**, so there is no phase to exit — it is tested by the defect staying closed. **MET 2026-09-13**: `JSONValue.integer(Int64)` decoded before `Double`, fourteen sites migrated to accessors, cross-case equality that narrows the `Double` rather than widening the `Int64`, `PaneCell` and `sortedRows` exact; `make app-build`, `make app-test` (670 tests), `make test` and `make vet` all green. |
| **2c-ii-b** | **Editing records from the DB pane** — the second entrance to `db_run_mutation`, per Decision 20: double-click a cell, it becomes an input, Enter commits, through the same action, the same `writeGate` and the same production block as a statement typed by hand. Added 2026-09-13, and deliberately **not** numbered 2c-iii. It is sequenced here because it needs two things 2c-ii owns and nothing before it has — a pane that knows which table and which primary key its rows came from (Decision 20's provenance rule), and a pane that can re-run its own query once the edit lands, which is 2c-ii's pagination re-query. It is the **second** entrance to a `.ui` mutation path 2c-ii already opened and already walked (that runbook's check 10), not the first. It was blocked until 2c-ii's `D8b` (a confirmed mutation does not re-fetch the pane) and `D7` (a gate refusal discards the typed draft) were closed — both are worse under a cell edit than under the typed statement that found them — and **both closed 2026-09-13**. | A cell edited in the grid reaches `db_run_mutation` through the same action, the same `writeGate` and the same production block as a statement typed by hand into the query line. **Shipped and walked 2026-09-14:twenty of twenty-three checks pass, and three did not close — all three for the same reason, that staging's MySQL database carries no write credential, so no MySQL pane was editable at any point in the walk. MET 2026-09-15**, when the operator accepted those three (12's MySQL half, 14 and 17) rather than waiting on the credential. **What that leaves unestablished is exactly one thing and it is worth naming: the MySQL write path has never been exercised at the window.** SQLite editing was walked and passes. Six defects were found against 709 green tests and all six are fixed; the three whose fixes live in the untestable `WakilApp` target were confirmed at the window. *Three checks, one credential* — `phase-2c-ii-b-acceptance.md` §5 had instructed that this row stay unmarked until they were re-walked; the 2026-09-15 acceptance overrides that instruction rather than satisfying it, and that document says so at its head. It keeps a letter rather than a number because `2c-iii`, `2c-iv` and `2c-v` are already written into `Pane.swift`, the 2c-i spec and the 2c-i acceptance runbook, and renumbering three labels to express one ordering is a worse trade than an odd name. |
| **2c-iii** | Terminal pane — PTY, a shell opened at a path, and the write-gate boundary for a shell. **Corrected 2026-09-16:** this row read *"per-root shells"* until [#42](https://github.com/yehia-khalil/rafiq/issues/42) took the root concept out of the sub-phase entirely; §8's row was amended then and this one was not. | A real shell runs in the pane; the agent proposes a command and only the operator's Enter runs it; `read_pane` returns both of the pane's surfaces; and no shell outlives the pane that opened it. One clause each from the four tickets that fed it — [#43](https://github.com/yehia-khalil/rafiq/issues/43), [#37](https://github.com/yehia-khalil/rafiq/issues/37)/[#39](https://github.com/yehia-khalil/rafiq/issues/39), [#40](https://github.com/yehia-khalil/rafiq/issues/40), [#41](https://github.com/yehia-khalil/rafiq/issues/41) — and the last is the one that would otherwise go untested, since #41 found no `deinit` in `WakilKit` releases an OS resource. **Sixth clause, added 2026-09-17 by [#64](https://github.com/yehia-khalil/rafiq/issues/64): the sub-phase does not close while any of the six doc comments in "The debt this map leaves 2c-iii" is still false.** They are the debt every terminal ticket deferred; a wrong doc comment is worse than a missing one, because the next agent reads it and believes it. |
| **2c-iv** | API client pane — request/response, consuming values from other panes; `wakil-http` gains a gated write method. **Sequenced after 2c-iii on 2026-09-16** ([#61](https://github.com/yehia-khalil/rafiq/issues/61)), not before it: the entry above gives the argument. **Blocked on a charter amendment** — Invariant 6 demands a justification per adapter and none has been written for the HTTP adapter, while `AssertHTTPReadOnly` refuses every verb but GET/HEAD *"with no override"*. Filed as [#63](https://github.com/yehia-khalil/rafiq/issues/63). | A request built in the window and a request built by the agent are the same action; a value bound from another pane resolves in the URL before the send; `read_pane` describes a pane that is neither a grid nor a stream; and production refuses the send rather than confirming it. The third clause is [#40](https://github.com/yehia-khalil/rafiq/issues/40)'s third pane kind; the fourth is the one place 2c's panes diverge from the write gate's usual behaviour, so it is stated rather than inherited. |
| ~~**2c-v**~~ | ~~Session browser pane~~ — **CUT 2026-09-16**, by the ruling recorded above. Never built; no code, no spec, no artboard. The label is **not** reused and 2c-vi is **not** renumbered: `2c-v` has fifteen citations across eleven files, two of them source (`Pane.swift:129`, `Canvas.swift:267`), and `phase-log.md`'s 2c-ii-b row already settled that *"renumbering three labels to express one ordering is a worse trade than an odd name"* — fifteen is more than three. A reader following one of those citations should land here. | **CUT**; a sub-phase that does not ship has nothing to exit. |
| **2c-vi** | **PM board pane** — the active project's Jira issues as a kanban board. Added 2026-09-14 at the operator's request, and sequenced **last in 2c**. ~~It is the only pane in the phase that carries a write (Invariant 6's 2026-09-14 amendment), so it should land after the panes that carry none. And 2b-viii's teardown contract must exist first: a board holding one org's issues is exactly the org-derived state §5.2's tripwire is built to catch, and this pane is the cheapest possible test of whether that contract actually holds for a pane written after it.~~ **Both of those reasons were spent by 2026-09-16 and neither is why it is last any more** ([#61](https://github.com/yehia-khalil/rafiq/issues/61)). The teardown one is **discharged** — it was right, and 2b-viii met 2026-09-15. The write one is **false**: §8's 2c-iv row has promised *"`wakil-http` gains a gated write method"* since it was written, so 2c carries two write-bearing panes, not one; the claim was true of Invariant 6's *justified* writes and was stated as a claim about panes. **What it is last on instead: open question 15**, which blocks its write half and is recorded in §8's Waits-on cell. A live blocker needs no argument, and neither 2c-iii nor 2c-iv has one. The board's *cheapest-test-of-the-teardown-contract* point survives the strike as an observation; it is simply no longer load-bearing, because 2c-iii now tests that contract first. It inherits 2c-i's data surface rather than inventing a second grid — a column is a filtered result set and a card is a row drawn small — which is the same argument that put the schema browser on that surface in 2c-ii. **What it is not:** a Jira client. §5's non-goal stands in full; the one verb it adds is the one that earned its way in. | A card dragged between columns and *"move 2835 to review"* dispatch the same action, against columns that are the Jira board's own; and the only target reachable is a transition Jira itself offers from the current status. The second clause is what makes Invariant 6's narrowest-write justification walkable rather than asserted — *"both of its arguments are enumerated by the adapter"* — and is what open question 15 is really asking about. |

**Six as of 2026-09-13**: record editing was split out as **2c-ii-b** rather than
folded into 2c-ii, on the operator's instruction to scope it after the DB pane's work
and tackle it separately. 2c-ii is the reason it can be separate at all — its query line
already carries an operator-authored mutation to the confirmation plane, so 2c-ii-b adds
an entrance to that path rather than the path. Decision 20 records what it costs, and why
the part that looks like a grid affordance is really a question about which rows a cell
can be written back through.

**2c-ii probed before it planned, and the probe changed three sections of
its own spec** — `docs/wakil/phase-2c-ii-probe.md`, 2026-09-12. Wrapping a
query in a subquery is safe and type-preserving on every read that matters,
but `EXPLAIN` and `SHOW` are gate-approved reads that cannot be wrapped, so
a next-page on either would have handed the operator a raw syntax error. A
per-pane `.keyboardShortcut` sends ⌘↩ to the wrong pane — window-scoped,
first-registered wins, whatever has focus — so the query line submits on
Return instead. And the spec's claim that this pane outgrows §8's
partial-sort admission was wrong: an outer `ORDER BY` cannot see past an
inner bound, so a re-query can come back truncated too. None of the three
was visible to a test, and the second was invisible to any test that could
exist.

**2c-ii is MET, 2026-09-13, by a runbook walked three times.**
`docs/wakil/phase-2c-ii-acceptance.md` records all three passes and every defect
each one found — **thirteen in total, twelve fixed**; D1 is deliberately unfixed
and the fix round's spec §13 says why.

**What the walks cost, and what that means.** The first walk ran all fourteen
checks against 605 green tests and two review rounds, and found twelve defects —
three of them blocking. Fixing those took sixteen reviewed tasks, after which a
whole-branch review found **two further Critical defects at the seams between
tasks that every per-task review had passed**: D7 had been fixed on a code path
that never fires, and D11 had been fixed only for the operator's environment
chooser and not the agent's, where it left the write gate judging a stale
environment — making a `production` mutation confirmable when policy says it must
be blocked outright. The third walk then found a thirteenth defect, D13, by the
most ordinary action in the app: typing a query that fails.

That is 2c-i's lesson restated twice over, and it is now this project's most
expensive and most repeated finding: **a green suite is the floor and decides
nothing above it.** 649 tests were green at every point where a defect was
shipping.

**What the walk settled that no command could.** Two of the three blocking
defects were the agent's judgement, not Wakil's code: it declined to redraw a
pane it had already described in chat, and it moved the operator's environment
unasked. Wakil had never passed it a system prompt at all. Both are fixed and
both were confirmed at the window — the agent now draws when asked twice, and
when production lacks a database the work needs, it says so instead of switching.
Whether an instructed agent obeys is not a property of a string, so no test
reaches it; the walk is the only instrument there is.

**One check could not be walked, and that is recorded rather than papered over.**
A mutation blocked in `production` never reached `writeGate`: this project's
production defines one database with no write reference, so the connection is
read-only before the gate is consulted. Two independent defences with the outer
one firing first — the right shape for a safety property and the wrong shape for
a test. The production block stays covered by unit tests and by the gate's truth
table, and the acceptance document says so in §7.
otherwise — is the reason 2c-ii's runbook exists at all.

`docs/superpowers/specs/2026-09-11-phase-2c-i-data-surface-design.md` §0. Two of the six
have specs of their own: 2c-i's, and 2c-ii's
`docs/superpowers/specs/2026-09-12-phase-2c-ii-db-pane-design.md` with the walk-defect
spec beside it. **2c-i is met — by an acceptance run, not by acceptance.** Its
row stayed unmarked until `docs/wakil/phase-2c-i-acceptance.md` was actually walked,
refusing the shortcut 2b-iii and 2b-v took, and the walk earned the wait: six defects
and two rulings surfaced from the operator's own screenshots after 500+ tests were green
and two review rounds had passed. The first phase since 2b-iv whose "met" rests on a
walked runbook.

**2c inherits two things from 2b-ii it did not ask for**, both recorded in
`phase-2b-ii-acceptance.md`'s discrepancy section and dated 2026-09-09. First, a
selection model: the active row's luminous left edge (`design-language.md` §8) was
deferred out of 2b-ii because no selection model exists anywhere in the codebase and
building one to support a single visual flourish was judged to be a data-surface
feature belonging here. Second, a rendering surface: 2b-ii replaced SwiftUI's `Table`
with a hand-built `Grid`/`ScrollView`, measured to be necessary because `Table`'s
backing `NSTableView` floors row height at the 24pt platform default and cannot reach
the design language's 23pt dense row. 2c's "DB pane in full" is not a `Table` to extend
— it is this grid, which has no column resizing, no header-driven sort, and no built-in
lazy rendering for large result sets, none of which were wired up in 2b-i either, so
these are options foreclosed rather than regressions, but 2c is where their absence
first matters.

**Both are discharged by 2c-i, and a third thing was found.** The selection model exists
(an anchor cell plus a row set), and the `Grid` is replaced by a virtualizing
`LazyVStack` that also recovers column resizing and header-driven sort — the two
options 2b-ii recorded as foreclosed. The third: that `Grid` was **missing the 120fps
budget on every frame at 5,000 rows**, with a 5.3-second first layout, which nothing had
measured. `docs/wakil/phase-2c-i-probe.md`.

Each gets its own spec. 2a's is `docs/superpowers/specs/2026-09-07-phase-2a-spine-design.md`.

**2b split again, 2026-09-08**, for the reason 2b's own row demonstrates: a visual
language, a GPU renderer, a layout engine, a navigation model and five items 2a deferred
are not one spec. Ordered structure-first, because §10's magnetism and §3's planes are
statements about *several panes arranged against each other* and mean nothing with one —
so styling a single-pane window and rebuilding it for many would repeat Decision 9's
finding in a new form.

| | Delivers | Exit |
|---|---|---|
| **2b-i** | Third action kind, pane model, magnetic canvas, the rail, ⌘P/⌘K | Several panes coexist, snap, and are reachable three ways; layout is dual-driven — **MET 2026-09-15 by acceptance without an acceptance run.** Its three standing checks were never run: the implementing session had no Accessibility and no Screen Recording grant, so it could launch the window and drive its socket but could not click, type into it or photograph it, and no walk was ever scheduled afterwards. §3's `--dispatch` proof and §4 are the whole of what was established. The row had been *shipped, unmarked* beneath four sub-phases marked met on top of it; the operator discharged it with the rest of the backlog on 2026-09-15 |
| **2b-ii** | The void, planes, the Core, motion, the thought thread, production treatment | `design-language.md` §1–9 realised at budget — **MET 2026-09-10.** Acceptance walked 2026-09-09; the six rows that walk left half-discharged were confirmed by the operator 2026-09-10 |
| **2b-iii** | Write-gate UI and the first `.mutate` — nothing else | 2a's acceptance checks 5 and 6 finally run — **MET 2026-09-10 by acceptance without an acceptance run.** The runbook was never walked; the operator marked it met on their own authority, and re-affirmed that on 2026-09-15 when the whole backlog was accepted. See the note below for what that leaves unestablished |
| **2b-iv** | The void as the Core; the sphere deleted; one Metal layer | §4 realised without an object, at lower idle cost than 2b-ii — **MET 2026-09-09**, acceptance walked in full; one latent defect found and fixed |
| **bridge** | The permission-prompt bridge: `--permission-prompt-tool` and `approve_tool_use` | A live agent's proposed mutation reaches the confirmation plane instead of being denied by the CLI — **MET 2026-09-10** — runbook walked in full, all six checks pass, verified in the journal and the database rather than from the window alone. Retires `phase-2b-iii-acceptance.md` §2 check 3b (the live-agent mutation path) and adds a live production-block check and a built-in refusal check. Four findings recorded, none in the bridge itself |
| **2b-v** | Session resume | ⌘P lists this org's past sessions and picking one forks it into a new Wakil-minted session that continues it, with its thought thread rebuilt — **MET 2026-09-10 by acceptance without an acceptance run.** The runbook was never walked; the operator marked it met on their own authority, and re-affirmed that on 2026-09-15 when the whole backlog was accepted. See the note below for what that leaves unestablished — and check 10 in particular, the one check in the entire backlog no script could ever have run |
| **2b-vi** | Provider picker | The session's Claude account is chosen in the window and read from the org's provider record; `WAKIL_PROVIDER`, `WAKIL_CLAUDE_PATH`, `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_OAUTH_TOKEN` stop being launch-time environment variables — **MET 2026-09-11.** Walked in full by the operator: all three checks in `docs/wakil/phase-2b-vi-acceptance.md` — the switch, the seam, the indicator — pass, in both directions and on `production` as well as `staging`, with the seam's no-false-continuity half tested against a real planted secret. The walk found four defects, all fixed before the row was upgraded (§5 of that document). **Dual-drive remains only partly satisfied** — `ctx_set_provider` is headless, the live swap is not. **Accepted as-is 2026-09-15**; the gap is real and is no longer tracked as owed. See the note below |
| **2b-vii** | Signing | `Wakil.app` launches from `/Applications` on a machine that never built it. **Partly blocked externally** — notarisation needs a *Developer ID Application* certificate, which requires a paid Apple Developer Program membership and which this machine does not hold; `security find-identity -v -p codesigning` reports one *Apple Development* identity and nothing else. Local signing with entitlements and the hardened runtime is reachable today; notarised distribution is not |
| **2b-viii** | The org switch | The window changes organisation without quitting, and a launch with no `WAKIL_ORG` set asks for one instead of refusing to open. **Corrected 2026-09-15 by task 15, against spec §4.4's table rather than memory:** `WAKIL_ORG` stops being read at the **three child-spawn sites** (`AppWiring.childProcessEnvironment`, the credentials lookup, the harness's MCP config) — it does **not** stop being a launch-time read outright, and remains the launch seed that decides which org the window first opens in (spec §7.1). And the window runs **four** servers, not five: `wakil-ctx` and `wakil-db`, restarted by Wakil itself on a switch, plus `wakil-pm` and `wakil-recall`, which die with the harness and respawn under the new org with the next one. `wakil-http` does not run in the window at all — five is the *headless* count, what `scripts/register-provider.sh` wires into a provider's own config dir, never what this window runs. *(Corrected 2026-09-20 by [#114](https://github.com/yehia-khalil/rafiq/issues/114): from 2c-iv the window runs **five** — **three Wakil-owned** (`wakil-ctx`, `wakil-db`, and now `wakil-http`, started in `WakilWiring.build` and restarted in place on a switch) plus the same **two harness-spawned**. The four above was true until 2c-iv started `wakil-http` in the window. The trap this sentence was written to close is live in a new form: the headless five is now the **same five binaries** in a different arrangement, so a bare count reads as agreement where none exists. Never write the number alone — write "three Wakil-owned, two harness-spawned".)* Every pane, the active project, the environment and every Keychain reference in flight are invalidated rather than carried across. **Scheduled 2026-09-14, closing open question 13, and sequenced BEFORE 2c-iii** for the reason that row gives: the blast radius is every pane's contents, and the panes are still ahead of it. **Not blocked by 2c-ii-b's outstanding re-walk** — those three checks wait on a MySQL write credential and share nothing with this. **Probe first:** 2c-i's probe found a 5.3-second first layout nothing had measured, and 2c-ii's changed three sections of its own spec before a line was written; a sub-phase that respawns four servers under a running window has more of that kind of thing in it, not less. **Implemented across fifteen tasks and MET 2026-09-15** — `docs/wakil/phase-2b-viii-acceptance.md` is the runbook (spec §12's fifteen checks), and the operator walked all fifteen over three passes. Those passes found **nine defects nothing in the test suite could see**: five presentation rulings that did not survive contact (§8.1.1, §8.4.1, §8.6.1), then two genuine correctness bugs in `WakilKit` that fifteen task reviews and a whole-branch review had all passed over (**§6.3** — a launch into an org with no active project left `organization` empty and force-opened the org plane over a healthy org, because §6 had reasoned about *switching* into a fresh org and never asked what a launch does; **§5.4** — an org switch restored the canvas's arrangement from disk and never re-ran the panes' subjects, so every restored `db` pane read "no rows") plus §8.4.2, and finally two regressions introduced by those fixes (§8.5's Escape collision, and five error types showing the operator their Swift case names). The last was found three separate times in three surfaces before it was understood as a class rather than an incident. **The lesson for the phases after this one:** every one of the nine was invisible to 794 passing tests, and the two correctness bugs were invisible *because* the tests that covered their areas asserted at a level the missing call did not reach — §5.4 had a passing test that called `restorePaneContents()` directly, which is exactly what the shipped code did not do. A test that drives the real chain is the only kind that would have caught either, and both now have one, each verified to fail with its fix reverted |

**2b-iii split again, 2026-09-09**, for the reason 2b itself split on 2026-09-08: its row
above named four things and they are not one spec. *Write-gate UI and the first `.mutate`*
is a Go write path, a SQL mutation gate, a blocking confirmation broker and a plane.
*Session resume* is a change to the `AgentHarness` protocol and to ⌘P's session list, and
shares no type, no file and no test with the gate. *Provider picker* reads a token out of
the org's provider record instead of out of the environment, which means touching the
Keychain from Swift for the first time — its own risk surface entirely. *Signing* is a
build-system change and is the one with an external blocker: there is no Developer ID
Application certificate on this machine and obtaining one needs a paid Apple Developer
Program membership, so a sub-phase that promised notarised distribution would ship with a
known-unreachable half. The three keep their rows above, re-ordered after 2b-iv, and
nothing about them is cancelled — `docs/superpowers/specs/2026-09-09-phase-2b-iii-write-gate-design.md`
§0 and §11 record them as owed.

**2b-viii's spec had a false claim in §3.1, found and corrected by task 15, 2026-09-15 —
recorded here so the record shows the spec was wrong rather than the correction being
made silently.** §3.1 said a restart that fails "leaves the client `nil`... every action
handler throws `StandardActionError.missingClient`". The code that actually shipped
does the opposite, and says so in its own doc comment: `AppWiring.switchOrg` leaves a
failed client **stopped, not `nil`** — a subsequent handler's `guard let client else`
still sees one, and what actually throws is `MCPClient.call`'s own `.notRunning`. Read
uncharitably, the original paragraph could suggest that which of the two errors a caller
sees changes whether `recordUncertainMutation` is bypassed. It is not, either way:
`recordUncertainMutation` (`StandardActions.swift:1727`) guards on
`StandardActionError.mutationFateUnknown` alone, so `.notRunning` and `.missingClient`
both pass through it as a no-op, identically — there was nothing to bypass in the first
place. The spec's §3.1 is corrected in place with a dated note; this entry exists
because a design document being wrong on a verified fact belongs in the log that records
what each walk (and, here, each acceptance task) actually found, not only in the file
that got fixed.

**2b-iii is met by acceptance, not by an acceptance run — read its row with that in
mind.** On 2026-09-10 the operator marked it met without walking
`docs/wakil/phase-2b-iii-acceptance.md`; all six of its standing checks record **ACCEPTED
— not walked** rather than a result. What follows is what *was* established, and it is
entirely the headless half.

All of its plan's tasks are done and every headless check the spec's §10 lists is green:
`AssertSQLMutation`
accepts exactly `INSERT`/`UPDATE`/`DELETE` and refuses every DDL verb, including through a
stripped comment, using `readonly.go`'s own five documented bypass fixtures;
`OpenDatabaseWritable` refuses a missing `writeRef` without reading the Keychain;
`hardenMySQLWriteConfig` forces `MultiStatements` and `AllowAllFiles` off; the broker
approves, cancels, expires and refuses a second proposal; and the journal carries the
`gated` → `ok` pair for an approved agent mutation. `make app-test` reports 319 tests
passing on 2026-09-10, against the 294 `phase-2b-iv-acceptance.md` H1 expected before this
sub-phase. **None of that is what the sub-phase is for.** Whether the confirmation plane
reads as *alarming* rather than as *an obstacle*, whether a statement is legible enough to
be honestly confirmed, and whether an expiry reads differently from a refusal to the agent
receiving it are judgements a machine cannot make, and as of this writing no human has
made them either, because the runbook that would have asked them was set aside rather than
walked. `docs/wakil/phase-2b-iii-acceptance.md` §2 marks all six standing checks
**ACCEPTED — not walked** — including the two that *are* the exit criterion, 2a's checks 5
and 6, which became runnable on 2026-09-09 and were never run. The row says met; the
judgement behind it is the operator's decision to accept, not an observation of the
running app. If the write gate later misbehaves in a way a person would have caught by
looking at it, that runbook is where to start.

**That gap is closed as of 2026-09-10, and the closing is its own small
sub-phase.** It read: *a live agent still cannot reach `db_run_mutation` at all* —
`agentAllowedTools` filters the registry to `.read` and `.control` and never
`.mutate`, correctly, but the `--permission-prompt-tool` that was always meant to be
the CLI-layer half of the gate was not built, on the 2a-era grounds that there was
nothing for a refusal surface to refuse. Until it existed, an agent proposing a
mutation was denied by the CLI before the request reached Wakil's socket, so the
confirmation plane never appeared and the broker never parked it.

It is now built: `docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`,
against ten measured scenarios in `docs/wakil/permission-prompt-probe.md`. The filter is
unchanged — the bridge decides *reachability*, never permission, so a mutation still
reaches `dispatch`, `writeGate` and a human at the plane exactly as before. What changed
is that it arrives at all.

**This did not itself mark 2b-iii met** — that happened separately on 2026-09-10, by the
operator accepting the sub-phase without walking its runbook. What the bridge changed is
narrower and is the one part of 2b-iii backed by an actual walk: check 3b, the live-agent
`.mutate` half of check 3, stopped being unwalkable and was then genuinely walked as part
of the bridge's own acceptance run. The other five 2b-iii checks were never walked at all.

**2b-iv exists because 2b-ii's first hands-on run asked a better question than its spec
did.** The plan was for it to be ordered after 2b-iii, gated on walking 2b-ii's acceptance
runbook *first*, in full — once the sphere is deleted nobody can compare it against the
room on a running window ever again, and that runbook was the only opportunity to record a
human judgement of what it replaced. **Neither happened.** The gate was never walked, and
2b-iv landed before 2b-iii rather than after it — recorded honestly in
`docs/wakil/phase-2b-iv-acceptance.md` §0 and `docs/wakil/void-as-core-probe.md` §7. The
baseline is not entirely lost: `cf50d35` is the last commit with `Core.metal` and
`CoreView.swift`, so the sphere is still individually walkable in a worktree at that
commit, though nobody will ever again compare it against the room side by side in the same
running window.

2b-i's spec is `docs/superpowers/specs/2026-09-08-phase-2b-i-structure-design.md`, and
the Metal feasibility probe that preceded it is `docs/wakil/phase-2b-probe.md`. 2b-ii's
spec is `docs/superpowers/specs/2026-09-09-phase-2b-ii-atmosphere-design.md`, 2b-iii's is
`docs/superpowers/specs/2026-09-09-phase-2b-iii-write-gate-design.md`, and 2b-iv's is
`docs/superpowers/specs/2026-09-09-void-as-core-design.md`.

**2b-ii is MET as of 2026-09-10.** Its runbook *was* walked — 2026-09-09, by the operator
on a MacBook Air M3 from the `nicosia` worktree at `515434f`, thirteen rows filled in, one
defect found and fixed the same day (clicking a pane did not focus it, latent since 2b-i).
The walk left six rows half-discharged — four "PASS, pending confirmation" and two
"NOT RECORDED"/"NOT MEASURED", each needing a tool the walk did not reach for
(Activity Monitor, VoiceOver, a stopwatch, a real quit-and-relaunch). The operator
confirmed all six on 2026-09-10, and `phase-2b-ii-acceptance.md` §2 keeps them
distinguishable as **PASS (confirmed 2026-09-10)**. Two caveats survive being met: check 2
is **void** — it judges the Core sphere, which 2b-iv deleted, and is walkable only in a
worktree at `cf50d35` — and the project-switch row is a judgement that the glide is fast
enough, **not** a measurement, because no number was ever put to a stopwatch and none has
been invented.

All 14 of its plan's tasks are done, and every headless check the spec's §11 lists
(`CoreState`'s
transitions, `VoidPalette`'s environment matching, `Plane`'s parallax bounds,
`thoughtRow`'s optional return, `pane_set_density`'s dispatch/journal/persistence) is
green. **On the count itself: 2b-ii's own close-out claimed `make app-test` reported
276/276, unverified as of this writing; the number actually measured at `ea7d4b5`** (this
branch's merge-base with `origin/main` — 2b-ii's last commit, before any 2b-iv code) **was
280/280.** 2b-iv's own tasks then added to that; `phase-2b-iv-acceptance.md`'s H1 expects
294, which is what `make app-test` reports today. None of that is what the phase is *for*.
Whether the void reads as depth rather than a gradient, the Core as a volume rather than a disc,
production as alarming rather than exhausting, parallax as depth rather than nausea, the
thought thread as legible during a real turn, and a project switch as a glide rather than
a flicker — every one of those is a judgement a machine cannot make, and as of this
writing a human has made every one of them. `docs/wakil/phase-2b-ii-acceptance.md` §2
carries the per-check record. "The code is written" and "the phase is done" are different
claims, and for this sub-phase it is the second one that is closed.

**2b-iv is MET, and was already met when its row said so.** Its runbook was walked in full
on 2026-09-09 alongside 2b-ii's, on the same machine and from the same worktree: H1–H5 and
all ten standing checks answered. Whether four states read as four in motion, whether a
room in motion reads as calm rather than as a strobe, and whether the thread reads as
rising out of the glow are judgements a machine cannot make, and a human made all three.
Two rows were left half-discharged by the walk — check 10 (occlusion, whose GPU half
cannot be judged by eye) and H4's GPU timing line, which the capture printed but nobody
copied off the terminal — and the operator confirmed both on 2026-09-10. **H4's number was
never taken and is not invented**; the probe's ~1.1 ms of an 8.33 ms budget, which predates
this sub-phase, remains the only measured figure.

**2b-v is met by acceptance, not by an acceptance run — read its row with that in mind.**
On 2026-09-10 the operator marked it met without walking
`docs/wakil/phase-2b-v-acceptance.md`; all ten of its standing checks record **ACCEPTED —
not walked** rather than a result. What follows is what *was* established, and it is
entirely the headless half.

The sub-phase's own defect fix is real and measured: `ClaudeCodeCLIHarness` now sets
`Process.currentDirectoryURL`, and before that fix `session-resume-probe.md` §8 measured
that all three Wakil-launched transcripts on this machine sat under worktree
directories while the registered project root held four transcripts of which none came
from Wakil — ⌘P could not list a single session Wakil itself had created. Every headless
check the spec's §11 lists is green: the two `buildLaunch` argv shapes and the refusal
when `--resume` appears without both `--fork-session` and `--session-id`, the lineage
store's round trip (including an absent store and a parentless child), both refusals in
§7 (wrong provider, a cwd no longer a project root), the reply-before-swap ordering, and
the registered-name set after `session_resume` was renamed to `session_get`. `make
app-test` reported 378 tests passing on 2026-09-10, and 380 when re-run from the `lansing`
worktree the same day. **None of that is what the sub-phase
is for.** Whether a rebuilt thread reads as the same conversation continued, whether the
seam reads as a seam rather than as an error, and whether a live agent's own resume
request is honoured before it disappears are judgements a machine cannot make, and no
human has made them either, because the runbook that would have asked them was set aside
rather than walked. `docs/wakil/phase-2b-v-acceptance.md` marks all ten standing checks
**ACCEPTED — not walked** — including check 1, the cheapest proof in the sub-phase, that
⌘P now lists a session Wakil itself created, which is therefore inferred from the unit
tests rather than observed in the running app. Two are worth naming as skipped: that one,
and check 10, which would have reproduced the two-writer transcript scramble
`session-resume-probe.md` §9 measured — the failure forking exists to prevent, never
reproduced against the shipped build.

**2b-vi is met, and what the walk found is worth more than the pass.** Written
2026-09-11 at the end of its own plan, and upgraded the same day after the operator
walked `phase-2b-vi-acceptance.md` in full.

**The runbook earned its keep.** Three checks caught four defects that 410 passing
Swift tests and a green Go suite could not see: two things on the window's bottom edge
both labelled ACCOUNT (news and state, indistinguishable); a provider row in ⌘P that
could not be told from a session row; a Keychain read that returned a secret as
unmarked hex whenever it ended in a newline, failing at first use with a 401 pointing
nowhere near its cause; and — surfaced only because the third was fixed — both of this
machine's provider tokens corrupted by a wrapped terminal paste. The third of those is
not a 2b-vi defect at all. It was a Phase 1 defect that had been latent since the
secrets layer was written, and it took a sub-phase that makes a whole window depend on
one token to expose it. That is the argument for walking runbooks, stated better than
this document has managed to state it so far.

*The rest of this note is what was established before the walk, and it still holds.*

*First, what is established.* The four launch-time variables are gone as inputs:
`grep -rn 'CLAUDE_CONFIG_DIR\|CLAUDE_CODE_OAUTH_TOKEN\|WAKIL_CLAUDE_PATH\|WAKIL_PROVIDER'
app/Sources` returns fourteen hits and not one of them is a read that decides which
account this window runs as — four are writes into a child process's environment (the
`claude` child's `CLAUDE_CONFIG_DIR`/`CLAUDE_CODE_OAUTH_TOKEN`, `WAKIL_PROVIDER` on every
MCP server, and `childProcessEnvironment`'s forward, which takes the provider as a
parameter now precisely so a mid-session switch reaches the children), nine are doc
comments explaining that history, and one is `WakilWiring.build` forwarding a launch-time
`WAKIL_PROVIDER` to `wakil-ctx`/`wakil-db` to fill Go's *advisory* Selected-vs-Running
note — a value that decides nothing and whose absence costs nothing. The account now
comes from the org's provider record (config dir, `claudePath`) plus the Keychain
(`wakil:<org>:provider:<id>`), picked per session as `active.json`'s fourth axis.

*Second, what is not.* The three judgements the sub-phase exists to produce are
unanswered — none has been walked in a real window. Task 12 (commit `5789d4a`) closed
the affordance gap that used to make check 1 unwalkable: a `.provider` kind in the ⌘P
palette, whose rows call `setProvider` directly with the id already on the row, so the
switch can be driven from the window today. **⌘K still cannot pass the provider id** —
the palette dispatches a chosen action with empty params, because the param-collecting
step of a palette selection (2b-i spec §6.1) was never built — so selecting
`session_set_provider` from ⌘K still yields `session_set_provider: missing required
param "provider"` and no switch, the same gap the "Open pane" button exists to work
around for `pane_open`. ⌘P is the route; ⌘K is not, and the agent is denied the action
by design either way. The live swap is exercised by unit tests and by no walked check
yet.

*And the dual-drive half, stated plainly because Decision 9 says it cannot be
retrofitted.* `ctx_set_provider` — the bookkeeping write that persists the pick — **is**
driveable headlessly through `--dispatch`, journals like any other action, and is honest
about what it did (it returns an empty object and claims nothing more). The live swap,
`session_set_provider`, **is not**: `runDispatchFile` builds its own wiring with no
`WindowModel`, so the action parks into a `ProviderSwitchBroker` that nothing drains, and
the handler nevertheless returns `{"switching": "<id>"}` unconditionally. A `--dispatch`
step for it would report success for a swap that never happened, which is why
`phase-2b-vi-acceptance.md` §4 names it as a trap rather than using it as a check.

### An input to 2b-ii: cap the frame rate, but cap the right thing

Raised by the operator on 2026-09-08, after the first hands-on run of 2b-i: *"can we cap
it at 120 fps and not more, if this would save resources and frames that are not needed?"*

The instinct is right and the number is right, and it is recorded here rather than acted
on because **2b-i has nothing running at frame rate to cap.** SwiftUI redraws on state
change; there is no display link, no `MTKView`, no render loop. An idle 2b-i window draws
zero frames per second. The decision becomes real the moment the Core lands.

Three things 2b-ii should keep apart when it does:

1. **A cap alone saves little.** macOS vsync already clamps to the panel's refresh rate —
   nothing can render faster than the display. On the build machine that is 60 Hz, and
   ProMotion's ceiling *is* 120, so `preferredFramesPerSecond = 120` mostly prevents work
   the compositor would have discarded. Set it anyway, as a statement of intent and a
   guard on future hardware, but do not expect it to be where the saving comes from.
2. **The saving is in not rendering at all.** For a window that is idle most of the time,
   the lever is event-driven drawing — `MTKView.enableSetNeedsDisplay` / `isPaused` — so a
   still canvas costs nothing. That is a much larger win than a rate cap, which still
   burns its full quota drawing an unchanged image.
3. **The Core and the void want different cadences.** §4's Core has a breathing idle
   state and genuinely wants continuous rendering; the void behind it is static. Two
   render paths at different rates is a real design decision for 2b-ii and should be made
   deliberately, not inherited by accident from whichever view owns the drawable.

The probe measured the Core at ~1.1 ms of an 8.33 ms budget, so this is a choice made
from headroom rather than under pressure.

**One exit criterion above is now known to be untestable on the build machine.** Both
its displays are 60 Hz, so *"120fps"* cannot be observed here at all; the 2b documents
record GPU and CPU cost against the 8.33 ms frame budget and say the target itself went
untested. The probe measured the Core at ~1.1 ms of GPU per frame, so the budget is not
in doubt — only the observation is.

**Answered, 2026-09-09, by 2b-ii's implementation** (spec §2.2,
`docs/wakil/phase-2b-ii-acceptance.md` §3 and §5). All three predictions above held:

1. **The cap alone saved little, as predicted.** `preferredFramesPerSecond = 120` is set
   on `CoreView`'s `MTKView`. It clamps nothing on this machine: both attached displays
   still report 60 Hz (`phase-2b-ii-acceptance.md` §3 row 5), so 120 fps was never
   reachable here to begin with — the cap is a statement of intent for hardware this
   machine does not have, exactly as this section said it would be.
2. **The saving came from not rendering at all, as predicted.** `VoidView` runs with
   `isPaused = true` and `enableSetNeedsDisplay = true`; a still window draws zero void
   frames rather than an unchanged image at any rate. This is the win, not the cap.
3. **The two cadences were kept apart by two Metal layers, as this section asked for
   deliberately rather than by accident.** `VoidView` and `CoreView` are two separate
   `MTKView`s, paused and continuous respectively. That split was not only the
   frame-rate answer — the depth model (§3) required it independently: the Core sits in
   front of the panes and the void sits behind them, and SwiftUI has no way to nest a
   view inside a single `MTKView`'s own draw call. The two questions had one answer.

**Point 3 superseded, 2026-09-09, by 2b-iv.** *"The Core and the void want different
cadences"* was right about the method — the split was made deliberately rather than
inherited — and its answer had a shelf life of one sub-phase. Deleting the sphere left one
cadence, and one layer is now not merely sufficient but correct. The replacement rule is
that **the cadence sets the cap**: each state is drawn at the rate its own period needs,
at least 25 frames per cycle and never above 120, which makes an idle window
(15fps, one cheap shader) about a quarter the cost of what 2b-ii shipped (0 void frames
plus a continuous 60fps sphere of a much heavier one). Point 2's finding — that the saving
is in not rendering at all — survives in a second form: the window still draws nothing
while it is occluded, minimised or on another space.

### Phase 3 — Breadth
Embedded editor (`code-server` pane). API client UI. Chat and inbox adapters. Additional
panes as friction reveals them.

> **Exit:** a full working day without leaving Wakil, except deliberately.

### Phase 4 — Depth
Proactivity. Recall index with incremental sync. A second harness. Write paths where
they have earned justification.

> **Exit:** none — this phase is demand-driven by then.

## 2026-09-18 — the terminal pane built, the sixth doc comment stopped refuting itself, and the runbook is written but not walked

[#72](https://github.com/yehia-khalil/rafiq/issues/72)'s seventeen-task plan
(`docs/superpowers/plans/2026-09-17-phase-2c-iii-terminal-pane.md`) is done: `TerminalStore`
owns a real shell on a `forkpty` PTY, block boundaries and exit codes come from OSC 133
marks a generated rc emits and Wakil's own byte scanner finds, the four actions
(`term_open`, `term_propose`, `term_run`, `term_scroll`) are all `.control`, `term_run`
joined `operatorOnlyActions` as its seventh member, `read_pane` returns the pane's two
surfaces as a `kind`-keyed union, the mirror draws the agent's own `Bash` calls recessed in
every open pane, and three awaited kill points — pane close, org switch, app quit — leave
no shell behind them. Full ledger: this sub-phase's own `progress.md`, 26 rulings and
roughly the volume this file's header warns a narrative accumulates.

This entry is Task 17's record: the sixth and last owed doc comment, the acceptance
runbook, and what the build itself caught along the way. **Nothing below was walked.**
The runbook exists to be walked; writing it is not walking it, and this entry does not
mark 2c-iii met.

### The sixth doc comment stopped contradicting itself in its own paragraph

`WindowModel.autoResumeAfterSwitch`'s doc comment argued, in one paragraph, that the
palette's `sessionItems(from:)` collapse *hides* "exactly the sessions this method most
wants to consider" — and then, one sentence later, that the newest member of a resume
chain is the one a return visit should continue. The newest member of a chain is precisely
what the collapse **keeps**. The paragraph refuted its own claim without noticing, which
this file already flagged as the fifth of six doc comments 2c-iii owed
("The debt this map leaves 2c-iii", 2026-09-17) — found by [#53](https://github.com/yehia-khalil/rafiq/issues/53), which is itself a case of the standing rule this project keeps repeating: a wrong comment is read and believed, and [#39](https://github.com/yehia-khalil/rafiq/issues/39)'s own ticket was
written on a false premise it took from one.

The repair keeps the true half and replaces the argument. The raw `session_list` rows are
read, not `sessionPaletteItems()`'s output, because **`PaletteItem` carries only
`id`/`kind`/`title`/`subtitle`/`payload`** — no `provider`, no `cwd` — so there is nothing
on the palette's own row type to filter a resume candidate by, and both filters the method
applies (provider match, then non-empty check) are load-bearing against fields the palette
never carries in the first place. The collapse is not the objection; it is *aligned* with
what this method wants, for the same reason it is right for ⌘P. `session_list`'s
newest-first guarantee, and the early return on an empty `providerId`, are both kept
unchanged — only the self-contradicting middle paragraph moved.

**All six are now closed**, per this file's own table: `ActionKind.mutate` (Task 1's fix
round), `PaneStore.swift:368` and `MCPServer.swift:233`/`:687` (Task 3's fix round),
`WriteGate.swift`'s table (folded into Decision 25's own build, Task 1), and
`autoResumeAfterSwitch` (this task). Check 25 of the new runbook is the point-in-time
confirmation of all six against today's code; it has not been walked, same as every other
check in it.

### Three mistakes the build's own tests caught, recorded by shape rather than only by repair

This project's standard for this log is the shape of the mistake, not only what fixed it.
Full mechanism and evidence for each is in `progress.md`; this is the compressed account.

**1. Every terminal shell inherited the capability servers' own pipes, and it would have
hung an org switch or app quit in the shipped app.** `forkpty` copies the whole
file-descriptor table, and nothing set `FD_CLOEXEC` on `MCPClient`'s and `MCPServer`'s
pipe write-ends before it — so every pane's shell held a live copy of them. Their drain
threads then never saw EOF, `MCPClient.stop()` never returned, and the full test suite
wedged at ~0.8 seconds of CPU for 45 minutes at a time, four separate times across one
session. **No task in the seventeen-task plan would have caught this** — it surfaced only
because the suite spawns real shells and a real hang is loud, not because any test
targeted file-descriptor inheritance. It was diagnosed by sampling the hung process (three
threads parked in `read(2)`) and confirmed by matching `lsof` peer addresses fd-for-fd
against the live `wakil-terminal-*` children, which falsified the first hypothesis
(leaked `TerminalStore` sessions in the tests) as only half the mechanism. The fix closes
every fd above the tty in the child before `execve` and sets `FD_CLOEXEC` on the master in
the parent — and, because a fix that only removes today's trigger is not a fix for the
class, the drain join that a wedged fd would block on was **bounded**, so any future leak
of this shape now surfaces as one named failing test in about two seconds rather than
silent minutes. A regression test proves the mechanism directly: a pipe whose write end a
child would inherit, polled for EOF with a timeout, red for exactly the reason the suite
wedged.

**2. The shell integration labelled blocks with commands that had not run.** The first
draft captured the command a block belonged to by reading `history 1` from the rc. That
reads what the shell **recorded**, not what is about to run, so under `HISTIGNORE` or
`HISTCONTROL=ignorespace` — both mainstream shell settings, not exotic ones — a block could
carry a **stale, previously-executed** command line paired with a different command's exit
code. Measured directly: `echo one` / `ls` / a space-prefixed `echo spaced` / `echo three`
produced blocks labelled "echo one", "echo one", "echo one", "echo three" — three blocks
in a row carrying the wrong text, one of them (the ignorespace-hidden `ls`) invisible
entirely. This is worse than the truncation bug it replaced (an earlier `$BASH_COMMAND`
approach that only chopped a `;`-joined line): a wrong command reads as confident and
plausible, and both the operator and the agent read a block's command as what ran. The
fix captures history's **number** alongside its text and emits an empty command rather
than a stale one when the number has not advanced — an honest gap instead of a confident
lie. The general form of this lesson — recorded once so a future ticket does not
re-derive it — is that a labelling mechanism sourced from what a system *recorded* rather
than what it is *about to do* can be quietly wrong in exactly the cases where a
lowest-common-denominator shell configuration diverges from a plain one, which is not a
rare case among real operators' own dotfiles.

**3. The mirror filed the agent's whole history ahead of the operator's.** Mirrored blocks
were given a synthesised timestamp (`epoch + a small integer per block`, so the whole
mirror sat within a few seconds of 1970) while operator blocks carried real `Date()`
values around today's epoch second, and `recordTerminal` inserts by that field. Every
mirrored block therefore sorted before **every** operator block, deterministically — not
occasional bunching but a total, silent inversion — including operator commands run an
hour before the agent ever touched the pane. This defeats the mirror's only stated purpose,
which is showing the agent's commands interleaved with the operator's own work: a history
that puts all of one party's work before all of the other's is not an interleaving, it is
two histories concatenated and mislabelled as one. Caught by review before it shipped,
not by the build's own tests — the existing test asserted grouping over mirrored blocks
alone, which cannot see a cross-origin ordering defect, and that gap is itself worth
naming as a lesson: a test that only exercises one origin cannot prove two origins
interleave correctly. The fix sources a real arrival time — captured once, synchronously,
where `WindowModel.append` first retains the event, then threaded into the pure decode
rather than read from `Date()` inside it — and the regression test that closed it
interleaves operator and mirrored blocks with known timestamps and asserts chronological
order **across origins**, which is the property that was actually broken.

### What the runbook covers, and what of it came from the build rather than the plan

`docs/wakil/phase-2c-iii-acceptance.md` is written against the plan's own 26 checks (the
four actions, the four teardown/restore checks, the six doc comments, and the probe
re-run) plus two the plan's checklist does not contain, both surfaced by the build itself
rather than authored in advance:

- **The bundle-`PATH` check (3a).** A bundled `Wakil.app` inherits `launchd`'s environment,
  not a terminal's — so a shell spawned without a genuine login-shell profile chain ships
  unable to find `kubectl` or `brew`, while every one of this sub-phase's unit tests keeps
  passing, because `swift test` itself runs from a shell whose `PATH` is already correct.
  This is the one check in the runbook a green suite cannot stand in for, and it must be
  walked in `make app-bundle`'s output specifically, never against a test run or a debug
  launch.
- **The orphan-shell sweep note**, for whoever runs the terminal tests or this walk next.
  An interrupted run — of `make app-test` or of the walk itself — orphans every shell it
  had open; they reparent to `init` and hold their ptys indefinitely, because teardown
  only runs on a normal process exit. This sub-phase's own build hit 70 such orphans across
  roughly three interrupted runs during one fix round, which then independently contributed
  to a later gate wedge. The sweep command is in the runbook's §1.2, verbatim from what the
  build used to clear them.

Two more checks the orchestrating brief asked for and the plan's own checklist already
carried, kept in the runbook rather than treated as novel: check 26 (re-running the
probe's drawing measurements 5 and 6 against the shipped pane, which is why
`scripts/probe/termspike` stayed in the tree after the pane shipped rather than being
deleted), and the known-partial note for "Send to thread" — it copies a fenced quote to
the pasteboard rather than reaching a compose field, because no compose hook exists yet;
stated as a partial in §3 rather than left for the walk to rediscover.

In passing: this plan's own text (`2026-09-17-phase-2c-iii-terminal-pane.md:22`) already
corrected the issue's phrase *"marks that survive scrollback"* against the probe's finding
that marks survive *scrolling*, not scrollback eviction — the correction Task 17's brief
asked to be noted was already made before this task started; nothing needed changing.

### What this leaves unestablished

**All of it, in the sense that matters.** Every one of the runbook's 27 items (26 checks
plus the known-partial note) is unwalked — no Result cell in the new runbook carries
anything but blank. North-star §8's row for 2c-iii records the runbook's existence and
that it is unmet pending a walk, not that the sub-phase passed. Specifically unestablished
until an operator runs it: whether the two-Enter proposal design (checks 11–13) feels
right rather than merely tests right; whether the mirror's pause-under-full-screen and
backfill behaviour (checks 16–18) reads clearly on screen; whether the bundle actually
carries a usable `PATH` on a real Developer ID-signed build (2b-vii's blocker means this
walk can only run against an ad hoc, unsigned bundle); and the two re-run probe
measurements (check 26), which have only ever been measured against the offscreen-window
harness, never the shipped construction.

### North-star §8 and the word count

§8's `2c-iii` row now names the runbook and records **built, not yet walked** rather than
leaving the `Met` column blank — the distinction this column exists to hold, per its own
header: *"walked* means an operator ran the acceptance runbook against the live app;
*accepted* means it was marked met without one." Neither applies yet, so the cell says so
rather than borrowing either word.

This sub-phase adds **no new §9 vocabulary.** Every term it uses —
`PTY`, `Terminal pane`, `Block`, `Write gate`, `Write price`, `Partiality` — was already
in the glossary before this build started. `TerminalStore` is a type name, not domain
language, and is not an entry.

`wc -w docs/wakil/north-star.md`, measured directly rather than carried forward from an
earlier entry's figure (which had since moved, and the header's own rule is to measure,
not to trust a prior count): **3,939 words** before this task's §8 edit, **3,945** after
it — six words for one cell, comfortably inside the 4,000-word limit.

---

## 2026-09-18 — a two-axis review, and one bound this branch had no scope for

The branch was reviewed a second time, against **issue #72 itself** rather than against the
implementation plan every earlier review had graded it on. Six spec findings and three
standards findings came back; eight were code, prose or test changes and are in the
branch. This entry records the ninth, which is not a change at all.

### `MCPClient.waitForDrainToFinish` was bounded on this branch, and the issue scoped it out

**What the branch did.** `MCPClient.waitForDrainToFinish()` used to park until both drain
threads reached end-of-file, with nothing else to release it. This branch gave it a
deadline — `drainDeadlineNanoseconds`, two seconds — and a record of every wait that hit
the deadline instead of EOF (`abandonedDrains`), so an unclosed descriptor surfaces as a
named, assertable fact rather than as a process that never returns.

**Why it was done inline, mid-build.** The defect that surfaced it was found by *this
sub-phase's own suite*: a terminal pane's shells hold ptys, and an interrupted run orphans
them, so this was the first sub-phase whose tests routinely produced the exact condition —
a descriptor nobody closes — that turns that unbounded join into a hang. In the shipped
app the same join is on the path an organisation switch and an app quit both take, so what
was at stake was not a slow test: it was a window that never finishes switching and an app
that never finishes quitting, with no error and nothing on screen. Forty-five minutes of
silence is what an unbounded wait costs a walk; a named test failure is what it costs now.

**And the issue's Out of Scope says otherwise.** Verbatim: *"Window-lifecycle teardown and
the uncancelled pump — pre-existing holes this pane makes visible rather than creates; both
already closed as their own tickets."* That is exactly this hole, and it names the ticket
that owns it. The ruling to fix it inline was made during the build and it was wrong on
scope: making a pre-existing hole *visible* is not the same as being the ticket that
closes it, and "we are already in here" is not a scope argument.

**The code stays, and this is the correction.** `docs/agents/workflow.md`: *"Where a spec
and the shipped code disagree, the code is what ships. Say so, and correct the spec — never
quietly match it."* Reverting would restore a state where any descriptor leak becomes
forty-five minutes of silence instead of a named test failure, which is a worse repository
than this one. So the divergence is recorded here, dated, rather than repaired backwards.
The issue's own append-only correction — a dated comment on #72, with its body edited to
match — is the operator's to post; nothing in this branch posts it.

**The shape of the mistake, which is the part worth carrying.** A fix being *good* is not
the same as a fix being *in scope*, and the moment those two questions get answered
together is the moment a sub-phase starts absorbing whatever it happens to trip over. The
test that caught this is the one that should have been the whole intervention: it names the
hole, it fails loudly, and it would have handed the owning ticket a reproduction instead of
a resolution.

## 2026-09-18 — the walk, twenty-one defects, and a seam with two correct halves

2c-iii is met. An operator walked `phase-2c-iii-acceptance.md`'s ten checks against the
built bundle, found twenty-one defects across the day, and re-walked a build that had
already been declared fixed — which is where two of the twenty-one came from. 1060 tests
green at the close, against 954 when the walk began.

### The runbook was capped at ten first, and that is why there was a walk at all

The sub-phase wrote twenty-six checks. The operator declined them, and was right to:
a long runbook is an inventory, an inventory is not a plan for an afternoon, and **a
runbook nobody walks defends nothing**. Ten were chosen and walked the same day.
`docs/agents/workflow.md` now caps every runbook at ten, with the two tests used to pick
them — *what can a test not see*, and *what broke latest*.

The twenty-one defects are the return on that cap. Twenty-six unwalked checks would have
found none of them.

### Where they were, which is one fact repeated twenty-one times

Every defect was in `WakilApp` or the seam between it and `WakilKit`. **None** was in the
PTY, the mark scanner, the block model, the store or the mirror. The 954 tests were telling
the truth about what they covered; the walk covered what they cannot. `WakilApp` has no test
target and cannot have one, and this sub-phase is the clearest evidence yet of what that
costs: the standing rule that logic belongs in `WakilKit` is not a style preference, it is
the difference between a defect a test catches and a defect an operator catches.

### The shape worth carrying: two correct halves and no join

Walk defects C2 (the live region redrawing the whole screen) and D3 (no cursor, ever) were
fixed by two agents working concurrently on disjoint files. One published `promptRow` and
the cursor position from the session; the other wrote the slicing and placement that consume
them. Both landed. Both were tested. **The two lines joining them were never written**, and
the view kept passing `nil`.

Every test passed and both defects reproduced verbatim on the next walk.

The cause was orchestration, not implementation: the seam was split across two changes, each
forbidden the other's files, and the join lived in the file the *first* agent owned while
only the *second* could see the field existed. Neither was wrong about its own half; nobody
owned the middle. **If a seam is split across two changes, the join belongs in whichever
lands second — never in a `TODO`.** A `TODO` at a seam is a defect with a comment on it.

### Three fixes that were worse than the bug before they were right

Recorded because the pattern repeated, not for the individual repairs.

**The tail sentinel.** A zero-height row at the end of the scroll stack had its visibility
read as "the operator is at the bottom". But appending content is exactly what pushes a tail
sentinel off screen — growth was indistinguishable from scrolling away, so following switched
off after the first block and never came back. Replaced with `defaultScrollAnchor(.bottom)`,
which is native, stateless, and a net deletion.

**The `clear` guard.** Keyed on the alternate-screen flag at the end of each read chunk. When
a short-lived full-screen program's entire visit fitted inside one `read(2)`, it wiped the
whole block history — every command from before the program ran. A real-shell test caught it.

**The cursor-up scan.** Its first draft withheld unresolved bytes from `output`, blinding an
existing alternate-screen split-read test.

All three are the same shape: **a signal read at the wrong boundary.** Chunk boundaries and
layout boundaries are not semantic boundaries, and a guard that samples state at one of them
is sampling noise.

### One rule widened, because it keyed on a mechanism rather than a behaviour

D4 gave a block no output when its command held the **alternate screen** — the screen was
never that command's stdout. Correct, and too narrow: Claude Code renders a full interface on
the *normal* screen and never switches, so its block recorded raw redraw bytes.

The rule now keys on the program having **moved the cursor up** — repainting by definition —
while `\r` alone does not trigger it, so a progress bar's real output survives. `heldTheGrid`
keeps its name to avoid a wire-shape change; its meaning is wider than the name now suggests.

### Colour, and a rule the design language did not have

§5 reserves green, amber and red for environment and outcome, and says text is never stepped
by hue. A terminal contradicts that the moment a program emits SGR.

Resolved by deciding whose voice the colour is. §5 governs **Wakil's** voice; a program's
stdout is quoted material and keeps its own colour — rendered in this app's values, so a
program's red and a failed block's `✗` are the same red. §5 carries the carve-out now.
Background SGR is parsed and not drawn: `Text` concatenation carries a foreground only, and
one `Text` per row is a measured constraint (per-cell was 240.5 ms/frame, 4 fps).

### What this leaves

- **A TUI's block on exit.** The widened rule catches direct cursor addressing; a program that
  repaints via scroll regions (`CSI S`/`T`, deliberately excluded) would still record noise.
  Walked once against Claude Code and clean; not proven for every TUI.
- **`aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy`** flakes under the full suite.
  The test deletes a layout file and asserts it is not recreated, without waiting for earlier
  writes to flush. Pre-existing, in layout persistence, unrelated to this sub-phase. The
  assertion is right; the setup races it.
- **The `▸` gutter and the parked strip** both taught the same lesson twice: the pty must be
  told the size of the screen it is *shown in*, not the size of the pane. Anything drawn beside
  the grid has to be subtracted first, and both bugs looked like overlap or truncation rather
  than like arithmetic.

---

## 2026-09-20 — the response is the bottom of the request's own surface

Resolved by [Redraw `ApiClient.dc.html`: the response surface, and the two known
corrections](https://github.com/yehia-khalil/rafiq/issues/115), the ninth ticket of the
[2c-iv](https://github.com/yehia-khalil/rafiq/issues/106) map and its second prototype ticket
after [#49](https://github.com/yehia-khalil/rafiq/issues/49). Three structurally different
redraws were drawn across seven scenes each and flipped through, rather than argued. The
operator picked the first.

**The ruling, in one line: the response is a second region of the request's own pane — always
present, replaced on every send, never a row in a log that opens and never a pane of its own.**
`ApiClient.dc.html` is redrawn accordingly, with six stacked corrections applied and a seventh
found in the drawing.

### The screen drew half of what the pane does

`ApiClient.dc.html` drew the method, the environment chips, the base-URL row, the URL line with
its bound value, the bound-values list, the headers, the body, the send affordance and a
`Recent` strip. **There was no response body, no status, no headers-back, nothing.** The entire
second half of what an API client does was undrawn, and four of the ticket's five questions were
about it.

### What decided it, and it was §8 arguing against the variant that invoked §8

The three variants disagreed about what a response **is** in this pane: **A** made it the bottom
half of the request's own surface; **B** took the artboard's own instinct literally — *"history
is the data surface pointed at this pane's own log"* — and made the lower half §8's grid with the
response as its anchored row opened in place; **C** opened the reply as a pane of its own, which
buys Invariant 2 for free and makes a response a value source, so chaining falls out.

**B's boldest claim is refused on B's own authority.** If the lower half is a data surface, a
JSON array of objects is rows and should draw on the grid. But §8's standing rule is that *a
surface which cannot do the thing must not look like it can* — the rule `truncated` and the sort
footer already obey. The grid promises sort, paging, selection and a **(row, column) anchor**,
and a JSON object honours none of them; drawn there, a response would offer a bind gesture that
cannot complete. **A body is text.**

**C's cost is the one the drawing made visible.** A refusal opens no pane, because nothing
happened — so C needs a second surface anyway for the case that has no reply, and its reply pane
dies with the window exactly as A's region does, buying nothing back for
[#114](https://github.com/yehia-khalil/rafiq/issues/114)'s record.

### A body carries no hue, and the status carries all of it

§5 reserves green, amber and red for meaning and forbids a decorative fourth. The terminal pane's
2026-09-18 carve-out does not reach here: it exists because a shell's stdout is *quoted material
carrying its own SGR*, and a JSON response carries none — there is nothing of the server's to
honour. So a body is cool white stepped by opacity, exactly as §5's last line already said, and
**the status code is the one coloured thing on the surface** — coloured because §5 reserves those
hues for precisely *healthy* and *failed*.

### Two of the drawn states are not responses at all

This is the sharpest thing the drawing settled, and neither state existed on the screen before.

**A refusal carries no status, no timing and no size.** When a bound value cannot resolve, no
request is built, so there is nothing to describe: the strip reads `not sent · no request was
built · nothing reached billing`, and every unresolved value is listed with what *was* available,
per [#112](https://github.com/yehia-khalil/rafiq/issues/112).

> The first draft of the prototype printed `200 · 184ms` over a request that was never built.
> It was caught by drawing it. That is `queryTargetPane`'s walked failure in a new place —
> *nothing rejected it, resolution fell through to something* — and it is the exact dishonesty
> this pane exists against.

**A send with no reply is not a failure either.** It is recorded fate-unknown, in the vocabulary
`mutationFateUnknown` already ships — *"this is NOT a report that nothing happened. Wakil stopped
waiting; it did not stop the request."* Amber, never red: red would claim it failed, and the
whole point is that nobody knows.

**And a 401 is where [#113](https://github.com/yehia-khalil/rafiq/issues/113)'s promise is paid.**
That ticket cut `secrets get` on the grounds that *the API client pane is the read-back*. The
pane names the **entry** whose credential was rejected and the command that replaces the secret
behind it, and still names no ref — it is not allowed to know one.

### The six corrections, and the seventh the drawing found

Applied: the credential line goes and the pane names no secret ([#67](https://github.com/yehia-khalil/rafiq/issues/67));
the URL line is chooser · resolved origin · path ([#109](https://github.com/yehia-khalil/rafiq/issues/109));
the base-URL row goes, both halves ([#108](https://github.com/yehia-khalil/rafiq/issues/108));
the rail reads `billing · confirm`, kind `api` (#109); the environment chip row is deleted and
every history row carries its entry and environment ([#110](https://github.com/yehia-khalil/rafiq/issues/110));
and the provenance caption names the **key** rather than the visual ordinal, with a captured bound
value drawn apart from a live one (#112).

**The seventh came from drawing the two halves on one screen:** the source pane's footer read
`read-only` while a live value was bound out of it. Its query names one table and selects its
primary key, so Decision 20's precondition holds — and #112 had since made that footer word
load-bearing in a way it was not when the screen was drawn: *"a pane that draws `editable` in its
footer is exactly a live value source."* The artboard was contradicting itself in one word, and
only a drawing that put the source and the consumer side by side would surface it.

**A captured bound value wears no hue.** Violet says *this re-resolves against a source pane at
send*; a captured value cannot, so the mark would promise a source that can be asked again. §5
forbids inventing a second hue, so the difference is carried by the absence of the first —
recessed, flat, edged. What it should say about its **age** is
[#137](https://github.com/yehia-khalil/rafiq/issues/137)'s and is deliberately not drawn.

### The accepted cost, drawn rather than argued

**The response evicts the `Recent` strip to a single folded line.** That is A's own cost and it is
on the screen rather than in a footnote. It also sharpened the question it defers: a fold asserts
a count, and a count is a claim about a store.

### An artboard in this repo can be looked at after all

[#49](https://github.com/yehia-khalil/rafiq/issues/49) closed with a finding that has governed
every redraw since: every `.dc.html` loads a `./support.js` that **is not in the repository and
never has been**, so *"a drawn artboard in this repo cannot be opened and looked at"*, and that
redraw was validated **structurally only**.

That is now half retired. The template is small enough to resolve by hand: a throwaway ~40-line
script evaluates the `data-dc-script`'s `renderVals()` against a stub `DCLogic`, expands
`sc-for`, substitutes the placeholders and writes standalone HTML, which headless Chromium then
renders. **This redraw was validated visually, in all five scenes and in production.**

It earned its keep immediately, on two defects structural validation could not have seen:

- the `refused` scene drew the refusal *"the source pane re-ran its query"* **over a source pane
  still showing its previous rows** — the screen telling two stories at once, which is precisely
  the failure this pane's whole surface exists against;
- in production the confirmation slot pushed the response body past the pane's edge and clipped
  it, because the room's extra chrome had never been drawn together with a reply.

The resolver is throwaway and stayed out of the repository. **The finding for the next person to
redraw a screen: the barrier #49 recorded is a ten-minute one, and structural validation is no
longer the honest ceiling.**

### Drawn as slots, not rulings

Two things the screen shows a **place** for without deciding: the confirmation sentence a gated
`.mutate` must carry, whose wording is [#117](https://github.com/yehia-khalil/rafiq/issues/117)'s;
and the body's emit rule, which is [#116](https://github.com/yehia-khalil/rafiq/issues/116)'s. What
*is* this screen's to say about the confirmation, and now says: **the bound values are resolved
before the operator is asked.** Confirming a request built of unresolved parts would be confirming
a request nobody can read.

### What the prototype opened, after the verdict

The operator read the drawing and asked two questions it could not answer, and both became
tickets rather than notes.

**The first exposed an omission in the drawing itself.** All seven scenes bound a value, which
made binding look compulsory; it is not, since a field is a sequence of parts and a part may be
literal text. An eighth scene was added — typed end to end, nothing bound, and no source pane
open anywhere on the canvas.

**The second has no answer anywhere in the map: *how do you bind it?*** #112 ruled what a bound
value **is** and that `bind` is an enumerated action; the **gesture** was never drawn. Four
candidates now are, in a ninth scene, disagreeing about which end starts it — and the operator's
own proposal is the strongest of them: name the hole (`{{param}}`), then drop a whole row at it.
It is the only one where a hole has a name before anything fills it, which is a gap the other
three cannot close.

It carries two conditions, and the first is a challenge to a closed ruling rather than a detail:
**`{{ }}` may exist only if it converts on the keystroke and is never stored**, or #112's ruling 1
falls and #122's item 2 returns from void. Filed as
[#150](https://github.com/yehia-khalil/rafiq/issues/150), blocking #117, and recorded on #112 so a
reader of ruling 1 meets the challenge rather than a contradiction. The second is that **a matched
name is a guess**: the demo row carries both `id` (`8842`) and `booking_id` (`BK-2026-8842`) while
the API documents the segment as `{id}`, so silent name-matching sends
`/v1/bookings/8842/confirm` and nothing fails. The drop therefore **proposes** and the operator
accepts.

*(Resolved 2026-09-22 by [#150](https://github.com/yehia-khalil/rafiq/issues/150): the first
condition is **refused and the hole survives it**. A keystroke conversion is not a delimiter in
#112 ruling 1's sense — nothing is stored and nothing is scanned at send, so ruling 1 stands
unamended — but `{{ }}` is refused on a second ground the condition never reached: #116 made the
body a field of parts, and a JSON body may itself be a template, so a conversion makes
`{"subject": "Hello {{name}}"}` untypeable. That is #111 §1's own finding arriving in a region of
the pane that did not exist when this passage was written. What G4 was **for** is ruled in
regardless — a named hole is a third kind of part, an **unbound slot**, always named, made by a
gesture rather than by typed characters. The second condition is untouched and stays #117's.)*

### What this hands on

- **[#152](https://github.com/yehia-khalil/rafiq/issues/152)** — graduated from the map's fog,
  which was waiting on exactly this redraw. The fold asserts a count; every row records the
  environment it ran against, which is only worth recording if the row outlives it; and #114's
  fate-unknown record **provably cannot live on the response surface**, because an org switch
  destroys the pane that holds it. So: is the log persisted, at what scope, surviving what?
- **The map's *"error and failure surface"* patch is discharged**, not graduated. This redraw *is*
  that surface; which transport failure maps to which of the three treatments is `/to-spec`'s
  restatement rather than a question of its own.
- **[#118](https://github.com/yehia-khalil/rafiq/issues/118)** — `read_pane` now has a response to
  describe, and three states that are not one: a response, a refusal with no status, and a send
  whose fate is unknown.

**The prototype and its two losing variants:** branch
[`prototype/115-api-client-redraw`](https://github.com/yehia-khalil/wakil/tree/prototype/115-api-client-redraw),
`b695f14`. Out of main by the convention #49 set — but unlike #49's, this one is **still live
material**: scene 9 is what #117 and #150 will argue over, and both tickets name the branch.

---

## 2026-09-21 — settings got a row, and the letter is an address rather than a schedule

Resolved by [Where the settings phase lands in §8, and what it displaces](https://github.com/yehia-khalil/rafiq/issues/102),
the last ticket of the [Is settings a phase?](https://github.com/yehia-khalil/rafiq/issues/46)
map. Four rulings, and the one that cost most is the one that reversed the recommendation
it started from.

### One — it is `2e`, and `2c-vii` was killed by a measurement

The candidates were `2e`, `2c-vii`, `2b-ix`, and a *named* row on `bridge`'s precedent.
**2c's exit criterion is *"Each pane the phase ships is fully dual-driven"***, and this
pane cannot meet it: [#123](https://github.com/yehia-khalil/rafiq/issues/123) ruled every
settings action operator-only and [#98](https://github.com/yehia-khalil/rafiq/issues/98)
ruled that **the agent may read settings and dispatch nothing on it**. That is not the
terminal's shape — [#37](https://github.com/yehia-khalil/rafiq/issues/37) upheld 2c-iii
precisely *because* `propose` stays agent-reachable and only `run` is operator-only, so it
was `operatorOnlyActions` applied to a seventh action rather than a hole in Invariant 2.
**Settings is the first surface where the agent reads and dispatches nothing**, so filing
it inside 2c would either fail 2c's exit or force the weakening #37 explicitly refused.

`2b-ix` fails differently and cheaply: 2b's exit is *"`design-language.md` §1–13 realised;
120fps; project switch < 400ms"*, and this phase delivers none of it. A named row is
precedented but both precedents describe themselves as *"a fix, not a sub-phase"*, which
thirteen rulings and the product's first removal action are not.

### Two — after 2c, before 2d, and the argument for going next did not survive being checked

The ticket named open question 13 as the type specimen — *the blast radius is not fixed;
it grows with every pane, and it is smaller today than it will ever be again* — and asked
whether that reasoning applies here or cuts the other way. **It cuts the other way, and
three candidate arguments for going next died on inspection:**

- **The rotation item is not urgency.** [#99](https://github.com/yehia-khalil/rafiq/issues/99)
  already found the shell equal exists — `claude setup-token` piped into `wakil secrets set`
  works by hand today — so the operator can close that TODO without this phase at all. It
  was used as urgency twice in this ticket's own rounds and it is not.
- **2c-iv does not need this phase's redaction rule.** The argument was that an API client
  would journal an auth header in plaintext before [#123](https://github.com/yehia-khalil/rafiq/issues/123)'s
  rule exists. **Decision 8's amendment gives each API entry an `authRef`, a reference and
  not a value** (`decisions.md:123-138`), so 2c-iv carries no credential in its params. The
  sharpest pro-now argument available turned out not to exist.
- **A classification test is retrofittable, and that is the point of it.** #123's totality
  rule — every registered action explicitly classified, 31 today — does grow with every
  action 2c-iv and 2c-vi add. But this is **not** Decision 9's *"dual-drive cannot be
  retrofitted"*; classifying ~35 actions late is hours of judgment, not a rebuild. The
  q13 shape requires a contract each later pane must implement, and this is not one.

**What decided it is §1's arbitration test, which is this repo's own shipping criterion
and is what cut 2c-v.** The terminal passed because its absence *"sends you to Terminal.app
several times an hour."* Adding a provider is a monthly act. On the repo's own test,
settings ranks **below both remaining panes**. Two facts point the same way: **Phase 2's
exit criterion runs through 2c-iv and nothing else** ([#37](https://github.com/yehia-khalil/rafiq/issues/37)),
and building 2c-iv first **makes this phase better** — [#97](https://github.com/yehia-khalil/rafiq/issues/97)
ruled the API row read-only *because* Decision 8's amendment runs ahead of the code, and
that reason evaporates once 2c-iv has run it.

**The one thing that does pin an order is [#123](https://github.com/yehia-khalil/rafiq/issues/123)'s
voice rule**, and it is weaker than it was first pitched: Invariant 7 is price-keyed and
this phase ships credential writes carrying no price, safe today by #98 rather than by the
invariant. That is a property of one pane, not a contract every pane implements — but it
is real, and it wants 2d-ii designed with the pane already present rather than taught to
avoid it afterwards. So: **after 2c, before 2d.**

**Nothing is displaced and nothing is cut.** 2c-iv and 2c-vi keep their rows, their order
and their arguments.

### Three — the letter is an address, the `Waits on` column is the schedule

`2e` reads as *after 2d*, and the phase is built before it. That mismatch is not a defect
of this row; **§8 is ordered by label and always has been**, which is measurable on rows
that already shipped: **2b-i sits first and was met 2026-09-15, while 2b-iv sits fourth and
was met 2026-09-09** — the four 2b rows shipped in the order iv, ii/iii, i, and the table
shows the reverse. 2b-vii is unbuilt and 2b-viii shipped. And 2c-ii-b already ruled the
principle outright: *"renumbering three labels to express one ordering is a worse trade
than an odd name."*

**Where 2b-vii/2b-viii reads correctly and `2e`/`2d` would not** is the `Met` column: one
says *externally blocked*, the other carries a date. All three of 2d-i, 2d-ii and 2e are
blank, so nothing would tell a reader which comes first. **The fix belongs in `Waits on`,
whose job that is**, and which [#61](https://github.com/yehia-khalil/rafiq/issues/61)
recorded being used this way before (2c-iii's cell once read *"— unblocked; next in 2c"*).
So 2e's cell reads *the rest of 2c; **built before 2d***, and **2d-ii's gains `2e`**.

**`Waits on` is `—` for signing.** [#93](https://github.com/yehia-khalil/rafiq/issues/93)
found no hardened-runtime entitlement covers keychain access, `com.apple.security.keychain`
does not exist, and `/usr/bin/security` is already the trusted application on both items;
[#96](https://github.com/yehia-khalil/rafiq/issues/96) then ruled Go the only process that
writes. **This phase does not inherit 2b-vii's Developer ID block**, and 2b-vii's own row
needs no edit — it never claimed keychain access among the things signing unblocks.

### Four — the exit criterion has two clauses, and its second was rewritten from the machine to the pane

[#166](https://github.com/yehia-khalil/rafiq/issues/166) handed this ticket a criterion:
*"every binding on this machine has a credential the operator did not paste."* It is
falsifiable by inspection, which is its strength, and it is **machine-state rather than
product capability**, which is its weakness — it is satisfiable tonight by hand with
`wakil secrets set`, without the pane being touched.

The house style is 2c-ii-b's: not *"you can edit cells"* but *"through the same action,
the same `writeGate` and the same production block as a statement typed by hand"* — the
**ruling** made testable, not the feature. So the criterion is **two clauses**, because the
phase has two halves and one clause lets a half ship untested (2c-i's is already three):

> An account is added from the settings pane and a **Session** launches under it without
> the operator seeing, typing or pasting a credential — minted and stored inside Go, with
> the mint's outcome journalled; **and** every binding the pane draws either carries a
> credential or is named as lacking one.

**#166's clause was moved from the machine to the pane** — *every binding **the pane
draws*** — so it tests the residue report #166 specified rather than the accident of this
machine's current state. That is a rewrite of another ticket's words and is recorded as
one.

### What this leaves owed

**The map does not close when #102 closes.** #102 rules only the **scheduling** entries,
because they are its own business: **open question 14** gains a dated amendment — its
*"provider registration… remains unscheduled"* is the sentence this row discharges, and it
stays closed and gains a note the way question 5 carries three — and **Decision 21**'s
*"costed half"* is recorded as scheduled at 2e.

Everything else graduates, on [#64](https://github.com/yehia-khalil/rafiq/issues/64)'s
precedent from map #36: which of the thirteen rulings earn a Decision number, the
**Invariant 4** amendment [#100](https://github.com/yehia-khalil/rafiq/issues/100) made,
the **Decision 25** correction #123 measured (it *"claims two users it does not have"*),
and §9's four owed entries — `Plane`, `journal`, `binding`, `credential-less binding`.
**This map had no such ticket and map #36 did**, which is the gap this ruling found.

**The word budget is not tight — it is already breached, and that was found by rebasing
rather than by reasoning.** This ruling was written against a branch where
`north-star.md` stood at **3,960** of its 4,000-word limit, so the first draft of the 2e
row (**4,012**) looked like the moment the rule broke, and the row was cut to the house
style unbuilt rows already use — 2c-vi's is thirteen words — to land back under at 3,998.
**That reading was wrong, and the rebase onto `main` corrected it.** Measured across the
commits that touched the file:

| Commit | `wc -w` |
|---|---|
| `84de6f6` terminal pane | 3,960 |
| `40b8f30` cut the API pane's base-URL override | **4,022** |
| `50aa0e9` layout layers keyed on a scope value | **4,062** |
| `848cdf1` a conversation's panes come back | **4,139** |
| `88aebf6` pane layouts keyed by conversation | **4,172** |
| `4d39fe9` declare production rather than spell it | **4,254** |

**The charter has been over its own limit for five consecutive commits, and nothing said
so.** The header defines the check itself — *"`wc -w docs/wakil/north-star.md` — if it is
over 4,000, something belongs in a log"* — and it is a check nobody runs, which is the
same failure mode the 13,962-word original had, at a tenth of the scale. The 2e row adds
**38** words on top of 254 already owed.

**This is handed to [#169](https://github.com/yehia-khalil/rafiq/issues/169) enlarged, not
as a footnote.** That pass owes §9 four entries — `Plane`, `journal`, `binding`,
`credential-less binding` — and now owes a **292-word repayment** before it writes one of
them. §4 and Invariant 4's history block were both moved to a log on 2026-09-17 to pay for
§9's last two terms, so the precedent for where the words come from exists. **The row is
deliberately not trimmed further to chase the limit**: cutting an unbuilt phase's
description below 2c-vi's thirteen words would pay for someone else's overspend by making
this row the least legible on the table.

## 2026-09-21 — two writers on one draft request, and the rule the DB pane never had to make

Resolved by [Two writers on one draft request: what happens to the operator's unsaved
edits?](https://github.com/yehia-khalil/rafiq/issues/130), the fifteenth ticket of the
[2c-iv](https://github.com/yehia-khalil/rafiq/issues/106) map, graduated from
[#109](https://github.com/yehia-khalil/rafiq/issues/109) and sharpened twice before it was
worked — by [#137](https://github.com/yehia-khalil/rafiq/issues/137), which made an agent's
re-query *destructive* to a draft, and by [#116](https://github.com/yehia-khalil/rafiq/issues/116),
which made the body a field of parts two writers can each hold part of.

**The ruling, in one line: an agent's write to a draft request is refused whole while the
operator has unsaved edits in it, so a draft request always has exactly one author.**
[Decision 27](decisions.md).

### The rule the ticket was written to port does not port

The ticket proposed `shouldAdoptSubject` as the near neighbour, and it is not one.
`shouldAdoptSubject` gates **the query line's text** and nothing else. `db_run_query` writes
`Pane.fetch` and the pane's rows and never calls it (`StandardActions.swift:693-716`); the
guard runs afterwards, in `DBPane`'s `.onChange(of: pane.fetch)`. So the DB pane's answer to
two writers is *let the write land and let the description lag*, and its worst case is the
lying pane its own doc comment names — a line that says one thing while the rows say another.

**A draft request has no description and nothing underneath it.** It is the subject, and it is
what goes on the wire. There is no third place for a gated write to land, so the DB pane's
structure — the one that let it protect the operator without costing the agent anything — is
exactly what is missing. One writer has to lose. The DB pane never had to choose, which is why
its rule reads as transferable and is not.

### Twelve rulings

1. **An agent's write meeting an unsaved operator edit is refused whole**, aggregated in
   #158's and #116's house style, never applied field by field. A partial application is the
   one outcome that produces a request neither writer composed.
2. **The refusal is keyed to origin.** The operator's own whole-draft gestures — reopening a
   `Recent` row, changing the entry — always land.
3. **Untouched is per field and by content** (`currentText == lastRendered`, one field at a
   time). **Focus plays no part**, already pinned for the query line by
   `PaneFetchTests.focusPlaysNoPartInTheDecision`. Marks clear on a landing write, on a revert,
   and on a send that left the window — #152's strip keeps that request, so clearing is free.
4. **A refused send clears nothing.** `D7` at form scale, and under #158 and #116 a refusal is
   the ordinary outcome rather than the edge one. The clearing path is the DB pane's,
   unextended: a later successful send.
5. **The send never checks.** Invariant 3 makes the screen the truth and #122 composes the
   `statement` from the draft as it stands; a check there would be a second gate over #107's
   price, which #137 already refused once.
6. **A collision is opt-in.** `resolvePane` is inherited unchanged — an agent naming no pane
   gets a new one — so only an agent naming a pane id can contend, and every refusal has a
   standing escape that costs it one turn rather than its request.
7. **The rule lives in a policy function beside `writeGate`, consulted by dispatch** — a free
   function in `WakilKit`, on `shouldAdoptSubject`'s own precedent, because `WakilApp` has no
   test target. Not in the handlers, and not inside `writeGate`, whose business is the
   environment.
8. **The refusal names the fields, quotes nothing, and names the alternative.** Quoting is
   redundant — #118 publishes the draft as parts — and `operatorOnlyDenialMessage`'s `term_run`
   sentence sets the style: say what to do instead, not only what may not be done.
9. **A landed agent write leaves no mark**, and the freeze after a refused send leaves none
   either. §5's three hues are spent (amber is pending · caution, violet is the live binding),
   `design-language.md` marks agent-originated changes nowhere, and the freeze is exactly
   co-extensive with the refusal #115 already draws. **The artboard owes this ticket nothing.**
10. **`read_pane` gains no dirtiness key.** It would report the operator's keystroke state
    rather than the screen — the one thing ruling 3 establishes Wakil does not read — and
    anything read before a write is a race the refusal already settles.
11. **No edit clears the drawn response.** #152's three tenses do the work: the draft is
    future, the response is present, and editing the future does not destroy the present.
    #110 clears on an environment switch because that is a fact about the *response*.
12. **#137's destructive case gets no interruption.** The draft draws the hole, keeps the
    origin, and the send refuses. The identical loss happens with **no writer at all** —
    `setEnvironment` re-runs every db pane — so anything that interrupts for the agent would
    have to interrupt for an environment switch.

### `ActionOrigin`'s doc comment is already false, and this ruling decides which half

`Action.swift:47-50` says a UI button, the agent and a debug script are *"indistinguishable to
the gate and the handler — `origin` exists solely so the journal can still tell them apart
after the fact."* **`writeGate`'s own signature disproves the gate half**: it takes `origin:`,
and `D10` turns on it. The handler half is true and this ruling keeps it true — which is the
whole of ruling 7, and the reason the refusal is not written inside the setters.

**`operatorOnlyActions` looks like the precedent and cannot be used.** It is a *static name
list*, consulted at `--allowedTools` (`WindowModel.swift:795`) and again in
`permissionDecision` — two halves of one refusal, so an action on that list is never offered
to the agent at all. 2c-iv's exit criterion requires the setters to stay offered and refusable
only sometimes, which a name list cannot express. This is a second, state-reading policy
function, not a seventh member.

### Three panes, three mechanisms, no stated rule

The DB pane lets the write land and lags its description. The terminal pane bars the agent
outright (`term_run` in `operatorOnlyActions`) and gives it a slot of its own (`term_propose`,
two Enters). The API client pane refuses the agent's write over an unsaved edit. Each is
right for its own structure and none was derived from a general rule, because there is not
one — a fourth pane kind would have no precedent to follow, only three. Filed out of scope on
the map as owed to every pane kind rather than to this one.

### What this hands on

- **[#117](https://github.com/yehia-khalil/rafiq/issues/117)**: its last blocker but one is
  gone, and it inherits ruling 7's seam — every draft-write action carries the policy check,
  and *reopen a past request* is one action whose behaviour differs by origin rather than a
  pair of actions.
- **Build note.** `ActionOrigin`'s doc comment needs a dated correction naming `writeGate` as
  a reader; no Swift was written here.
- **Books no probe item.** The refusal rate does not change the ruling, because the escape
  costs nothing.
- **§9 owes nothing**, and could not have been charged anyway: the charter stands **254 words
  over its own limit** with [#169](https://github.com/yehia-khalil/rafiq/issues/169) already
  owing the repayment. *Draft* and *request* are ordinary English here.
## 2026-09-22 — five rulings earned a number, §6 paid for them, and the charter's own check finally exists

Map [#46](https://github.com/yehia-khalil/rafiq/issues/46)'s closing pass
([#169](https://github.com/yehia-khalil/rafiq/issues/169)), on
[#64](https://github.com/yehia-khalil/rafiq/issues/64)'s precedent from map #36. The map
is complete: sixteen tickets closed, no open children.

**Two corrections to the ticket's own framing, before the screen.** It says *"thirteen
rulings"* and *"`decisions.md` is at 25"*. The map closed **sixteen** tickets, and
`decisions.md` was at **26** — Decision 26 landed in `9c11ce9`, after #169 was written. So
the screen was sixteen candidates against a next number of 27.

### The screen — five of sixteen

The bar was the standing three-part one: hard to reverse, surprising without context, the
result of a real trade-off.

| # | From | The call |
|---|---|---|
| **28** | #95 | A provider's credential is the config dir **plus** a `setup-token` Wakil mints itself; Wakil never implements refresh |
| **29** | #96 | Go is the only process that writes the Keychain; a provider credential is minted and stored atomically there |
| **30** | #98, #123 | Settings is a pane the agent may **read and never drive** |
| **31** | #100, #139 | `ProviderLogin` is a kind-keyed protocol; the seam splits at **the human**, not the language |
| **32** | #126, #166 | An organisation **unlinks a binding**, never removes a provider; `home` is an artefact, not a setting |

**#123 was the close one, and it was split rather than numbered.** Its redaction rule is
hard to reverse and genuinely surprising — **positional rather than byte-matching**, the
opposite of the Go scrubber — but it is *about* the journal, which is what #139 established
Decision 29 defends. So the redaction rule rides inside 29, and #123's operator-only
totality rides inside 30, which is the pane it is true of. Two entries citing each other is
what the split avoided.

**Four amend an entry that exists.** Decision 21 gains #99's parity ruling (*parity runs one
way; the equal is the underlying tool, never a mirrored verb; no `wakil` verb is owed, ever*)
and #102's scheduling. Decision 25 gains #123's measurement that it **claims two users it does
not have**. Invariant 4's **Owed** clause is deleted — #100 measured it delivered, because
`buildLaunch` always passes `--strict-mcp-config`. Decision 4 is **confirmed, not amended**:
#100 leaned on its *neither side interprets the credential* wording and the wording holds.

**Seven earned nothing** — #92, #93, #94, #119 (measurements, housed in the probe docs),
#101 (surface design, `design-language.md`'s address), #102 (schedule), #97 (scope). **#166
was the argued exclusion:** the residue standard is real and load-bearing, but it is the
idiom this repo already uses — `layoutDroppingUnknownPaneKinds`, `list_sessions`' `skipped`,
`list_projects`' misfiled entries — so it fails the *surprising without context* limb. Its
rulings live in 2e's spec and in Decision 32's amendment.

### §6 paid, and it is the same repair Invariant 6 took

#64 found Invariant 6 had grown a paragraph per adapter inside a rule of one sentence. **§6
had the same shape in a column.** Its *Reverse if* column was **382 words**, of which ~337
was verbatim duplication of `decisions.md`, which §6's own header says *carries them in
full*. Decision 21's condition alone was 44 words rendered twice in the repo.

So the column becomes a **gist** — each condition in six words or fewer, stated in full at
its entry — and the fifteen `— none stated —` markers are untouched, because that count is
what the section tells you to read first. The same rule then paid twice more, in the two
places the index was carrying what it indexes: **§8's row parentheticals** (which checks
were accepted, what each walk found — all of it in this file, which §8's header already
points at) and the **header's own split history**.

| | Words |
|---|---|
| §6's *Reverse if* column collapsed to a gist | **−250** |
| §8's acceptance parentheticals and the 2d-split narrative | **−120** |
| Header: split history → this file; the check rewritten | **−66** |
| §4: Invariant 6's 2026-09-19 rewording (already at its entry in `decisions.md`) | **−60** |
| §6/§7 prose the new header made redundant | **−48** |
| §6 rows for Decisions 27–32, including the one `main` never added | +185 |
| §9 gains **Plane**, **Journal**, **Binding** | +127 |
| Invariant 7's note; Invariant 4 corrected | +16 |

**`north-star.md` is 3,990 words** — under its own limit, in the headroom #64 left at
3,982.

**The rebase moved the numbers, and the check is what caught it.** While this pass was
being written, `fa4a97d` landed [#130](https://github.com/yehia-khalil/rafiq/issues/130)'s
draft-request ruling on `main` as **Decision 27**, so these five became **28–32**. The map's
Notes guard against a number being assigned mid-effort and then reversed, but that guard is
*within* a map; two maps closing in the same week are outside it, and nothing in the repo
orders them. **`main` also added Decision 27 to `decisions.md` and never added its §6 index
row** — so the charter's index was missing an entry, and a wholesale rewrite of that table
would have dropped it silently. The row is added here. And the extra row took the file to
**4,015**, where `make docs-check` **refused the commit** — the first thing it caught was
this pass's own overspend, four hours old.

### The check now exists, and that is the finding that outranks the arithmetic

The charter has defined this check in its own header since the 13,962-word failure:
*"`wc -w docs/wakil/north-star.md` — if it is over 4,000, something belongs in a log."* **It
had no implementation anywhere.** No `Makefile` target, no `scripts/` line, and this repo has
no CI at all. The file sat over the limit for **five consecutive commits** — 4,022, 4,062,
4,139, 4,172, 4,254 — and nothing said so.

**`make docs-check` counts the words and fails over 4,000, and `make test` depends on it.**
`make test` is the only thing that runs on every change here, so it is the only place a
check can live and be run. The alternatives were both refused on evidence rather than
taste: a runbook check would spend one of `workflow.md`'s ten on exactly what a test *can*
see, and "a human habit" is the thing that just failed five times in a row.

### §9's four owed terms became three

`Plane` and `Journal` are defined as owed. **`credential-less binding` is folded into
`Binding` as a clause, not given a row** — it is a *state* of a binding rather than a peer
term, and #166's own value claim was the **collapse**: the product says this three
different ways in three places. A glossary that spends two rows to say *binding* and *broken
binding* has re-spread what the entry existed to gather.

`Plane` also inherits a live collision and names it: `design-language.md` §3 uses the word
for a **depth layer** while `ConfirmationPlane`/`OrgPlane` are **surfaces**. The surface
keeps the word here; the clash is recorded in the entry rather than left for someone to
rediscover, which is question 16's shape one term over.

### The defect ledger — 25, deduped to 18, and the "live" column did not survive checking

The sixteen tickets state **25** defects found in passing, not *"roughly thirty"*, and they
come from **seven** tickets, not sixteen: #126 and #166 found seven each, #123 four, #100
three, #99 two, #102 and #139 one each. The other nine carry defect-*shaped* findings under
other headings that their own tickets never call defects.

**Every one of the 25 is stated live by the ticket that found it. Two are not.** #99's pair
— the runbook fixture's stale `readOnly` keys and a `//` comment `encoding/json` rejects —
were paid by **`cef86dc` (#132)**, *"Make the Phase 1 project.json fixture copy-pasteable
again"*, after #99 closed. **A ticket's "live today" is a claim about the day it was
written**, and a ledger that copies it forward inherits a stale fact. Both were re-checked
against the file rather than the ticket; so was every other row below.

**Disposition: no new issues, and no third exit clause.** 2e's exit criterion stays at
#102's two clauses. A third reading *"and eighteen named defects are false"* is an
inventory, which is the failure `workflow.md:62` names for runbooks and the same failure one
level up. The nineteen inside 2e's build are **the spec's scope**, which is what a spec is
for; the six outside it are paid here.

| Defect | Where | Found by | Disposition |
|---|---|---|---|
| Runbook fixture carried stale `readOnly` keys and a `//` comment `encoding/json` rejects | `phase-1-acceptance.md` | #99 | **Already paid** — `cef86dc` (#132) |
| The charter's 4,000-word check had no implementation | `north-star.md` header | #102 | **Paid here** — `make docs-check` |
| Decision 25 claims two users it does not have | `decisions.md` | #123 | **Paid here** — dated correction at the entry |
| §9 defines no `Plane`, `journal`, `binding`, `credential-less binding` | `north-star.md` §9 | #98, #123, #126, #166 | **Paid here** — three rows |
| §9.3 says `ProviderTokenRef` is removable; §10.6 records #95 ruling it survives, and §9.3 does not say it is superseded | `provider-login-probe.md` §9.3 | #100 | **Paid here** — superseded note; the measurement kept, the conclusion marked |
| Invariant 4's **Owed** clause was already delivered | `north-star.md` §4 | #100 | **Paid here** — clause deleted, dated |
| Go shells out to the **bare name** `security`, PATH-resolved; #93's prompt-free ACL guarantee names `/usr/bin/security` | `secrets.go` | #100 | 2e's spec |
| `wakil provider credentials` is absent from the CLI's own `usage` | `cmd/wakil/main.go` | #100 | 2e's spec |
| `JournalEntry.params` is written verbatim on **every** dispatch, including refused and blocked — and the **unknown-action-name path** structurally cannot read a redaction mark | `Journal.swift:34`, `ActionRegistry.swift:157-191` | #96, #123 | 2e's spec — one defect with a subset that survives the fix |
| `operatorOnlyActions` is pinned against **removal** and never **omission**, across four test sites | four test sites | #123 | Out of scope on the map; 2e's own list gets a totality test instead |
| `RemoveProvider`'s *"one-way door"* comment is **false** — `provider add` re-homes the directory | `provider.go` | #126 | 2e's spec — the refusal is deleted |
| `RemoveProvider` strands `org.json.defaultProvider`, and `SaveOrg` then refuses to write the file — **the pane breaks its own form** | `RemoveProvider`/`normaliseOrg` | #126 | 2e's spec |
| `active.json.provider` is validated nowhere, on either path | `active.go` | #126 | 2e's spec |
| **`adoptProviderArgs` has no `claudePath` field at all**, so the add-path fix must add an argument, not populate one — and `omitempty` makes an empty field and a never-set one byte-identical | `cmd/wakil-ctx/main.go:149-155`, `:332-345` | #166, superseding #126 | 2e's spec — **see the warning below** |
| `claude auth logout` prints success when it revoked nothing | `claude` 2.1.278 | #126 | 2e's spec — the last-unlink offer must read the result, not the exit code |
| `OrgPlane` warns by **guessing** — it fires on *"an adoption happened this session"*, never on a check, so it is silent on relaunch | `OrgPlane.swift:623-631` | #166 | 2e's spec — ruled deleted, not left alongside |
| The launch failure **prints a shell command into the window status line** | `secrets.go` → status line | #166 | 2e's spec — in the phase whose premise is that you should not type one |
| Diagnosis lands two processes away from the record, and strictly **after** the operator commits to the switch | `secrets.go`, `ProviderCredentialsLookup.swift` | #166 | 2e's spec |
| Dangling-provider validation is **write-time only** | `resolve.go:89-92` | #166 | 2e's spec |
| Three credential-less bindings (`umbrella/umbrella-initech`, `new-org/initech-main`, `test-org/main`); 17 orphaned Keychain items, two of them class 4 | this machine | #95, #126, #166 | 2e's spec — **named, not repaired**, per #166's residue standard |
| `operator-todo.md` §4's rotation item is stale; §3's instruction to blank `~/.claude-tokens.zsh` is unexecuted | `operator-todo.md` | #95, #119, #166 | Closed by 2e's exit criterion — re-running the flow *is* the rotation |
| `credentials(forProvider:)` is `async throws` over blocking `readDataToEndOfFile()`/`waitUntilExit()` | `ProviderCredentialsLookup.swift:75-83` | #139 | 2e's spec — the shape transfers, this line of it does not |

**One row is bold because a builder would follow it into a dead end.** #126 ruled that
`adopt_provider` must **record** `claudePath`. #166 then measured that `adoptProviderArgs`
has **no such field**, so #126's instruction is unimplementable exactly as written. #166's
wording supersedes it, and Decision 32 carries the correction in its amendment rather than
leaving it in a ticket nobody re-reads. This is #64's *"a wrong doc comment is worse than a
missing one"* in the ledger's own shape.

### Left owed

**Nothing, and it is checkable.** Every item on #169's queue is promoted to a number,
recorded as an amendment, paid in this commit, or entered in the table above with a
disposition. The map has no open children.

## 2026-09-22 — the map's seventeenth ticket, and the sweep that would have made another orphan

Map [#46](https://github.com/yehia-khalil/rafiq/issues/46)'s last ticket
([#176](https://github.com/yehia-khalil/rafiq/issues/176)), opened after
[#169](https://github.com/yehia-khalil/rafiq/issues/169)'s closing pass had already
declared the map complete. **That declaration was right about the frontier and wrong about
the fog.** #169 closed with sixteen tickets and no open children, but the map's `Not yet
specified` still carried one patch, and [#166](https://github.com/yehia-khalil/rafiq/issues/166)
had sharpened it the day before into something statable. A map with an empty frontier and
live fog is not complete; it is waiting for someone to test whether the fog has hardened.

### What the patch was, and why it graduated

Cancelling between the add flow's two browser trips leaves a live sign-in in a derived
config dir that no provider record names. [#101](https://github.com/yehia-khalil/rafiq/issues/101)
surfaced it and declined to rule; #166 bounded it, ruling that the residue standard owes it
**nothing** — that standard covers what the pane draws a row for, and this has no record and
so no row — while leaving the other head, **stop making it**, explicitly alive. That is what
made it in scope: the flow this phase designs manufactures one every time a human changes
their mind, and the spec has to say what the cancel control does.

### The pre-pass moved the question twice, and the second move decided it

The facts were gathered AFK before the sitting, per `docs/agents/workflow.md`. Two of them
falsified the ticket as filed.

**The first reading put the dir on the wrong side of an in-repo split.** The pre-pass argued
provenance: `CreateOrg` rolls back a half-made org dir (`org.go:105-113`) and `TerminalStore`
removes the rc directory it created (`:472`), against `AppScene.swift:35-38` and
`abandonedResources` (`TerminalStore.swift:129-155`), which both deliberately leak rather
than unwind from an arbitrary point. It placed the config dir on the leak side because
`claude` creates it. **[#100](https://github.com/yehia-khalil/rafiq/issues/100) ruling 6 says
Wakil creates it**, and a read of the shipping binary then showed the CLI `mkdir`s it
recursively anyway. The split is real; the ruling does not rest on it.

**The second move is the one that mattered.** #100 ruling 6 derives the path as
`~/.claude-<id>` — **a pure function of the provider id the operator types**. So the
directory is not stranded in the sense the fog entry assumed: it is **deterministically
addressable**, and #101's `1 of 1` re-auth, designed for *"a config dir that still resolves"*,
is already the entry point that walks back into it. The recovery the ticket was filed to
design **was already built**, in a ticket that did not know it had built it.

### The ruling

**No sweep.** Three grounds, and the second is the one that generalises: **Decision 32's
Keychain argument bites on the add path too, and not by analogy.** The CLI's scoped item is
named from a hash of the config-dir path, so deleting the directory makes the item's name
uncomputable — and `Claude Code-credentials-832632cb` is what that looks like afterwards,
the item #166 brute-forced against ~60 candidate paths and **never identified**. A sweep
manufactures the orphan the map already catalogued as permanently unidentifiable. The third
ground is that it cannot keep its promise: the fog entry named three exits and a sweep fires
on one, because `applicationShouldTerminate` **explicitly refuses** to unwind half-built work
and there is no crash hook anywhere in the app. **Leaving it is the only disposition that
behaves identically on cancel, quit and crash**, which is why the ruling owes no story about
the other two.

**#101's trip-2 cancel text is superseded** — it describes a loss that no longer exists. *Every
cancel states its cost* is unweakened by this: a cancel states its cost rather than
manufacturing one, and this is the only place in the product where the recovery path is ever
stated.

**Re-entry shows the identity and offers two options**, `Continue as <email>` or `Sign in as
someone else`. The hazard is **misidentification, not residue** — nothing guarantees the second
`acme` is the same human's account. Making "someone else" mean *pick a different id* was
rejected on #126's rule that the operator must never see that class of artefact. The mechanism
was measured free: `claude auth login` **replaces in place with no branch reading the stored
credential**, the binary's only *"already logged in"* guard belonging to `claude mcp login`,
and the Keychain write being an **upsert under an unchanged name** keyed on the unix user.

**It does not join [#123](https://github.com/yehia-khalil/rafiq/issues/123)'s destructive
list**, on #123's own stated reason for keeping `writeRef` off: it escalates rather than
destroys, and is undone by the same gesture that did it. **#123 stays at two entries and its
single test needs no edit.**

**A directory never re-entered is an accepted, named cost**, on `abandonedResources`'
precedent. Drawing it contradicts #166; building the disk-side query would be the product's
first disk scan, feeding a report nothing acts on — and #166 already measured how this class
ages.

### The finding that outranks the ruling

**`provider-login-probe.md` §9.1 and the shipping binary contradict each other on `realpath`.**
§9.1 rules the Keychain name is `sha256(realpath(configDir))` and calls `realpath`
**load-bearing**, on a measurement. The binary resolves no symlinks, and the `realpath` §9.1
cites is **Orca's**. The four reproducing derivations are all `~/.claude-*` paths with no
symlink component, so they do not discriminate. This is not academic: **`AddProvider` already
stores `filepath.EvalSymlinks(abs)`** (`provider.go:154`, with `:310` depending on it), and
#100 ruling 6 leaned on §9.1 by name. If the CLI does not resolve, a derived path with a
symlinked component gives Wakil a Keychain name the CLI never wrote to, **and the failure is
silent**. Settling it is read-only and needs no credential: point `CLAUDE_CONFIG_DIR` at a
symlink, run `auth status --json`, and read back `configDirectory`.

Filed as 2e's spec work rather than a new ticket, on #169's own disposition — *the rest are
2e's spec, which is what a spec is for*. Four more defects ride with it, three live: `backups/`
retains the displaced account's identity across a switch and nothing on the login or logout
path touches it; the plaintext fallback can leave a `.credentials.json` a replacing login
would not sweep; and a replacing login does not revoke the displaced refresh token.

### Left owed

**Nothing.** #176 graduated no fog of its own. #46 has **no open children and an empty `Not
yet specified`**, which is the first time both have been true at once — and it is what turns
the Fog rung.

## 2026-09-30 — 2e walked: ten checks pass, and the walk found eleven defects no test could

The operator walked `phase-2e-acceptance.md`'s ten checks between 2026-09-29 and
2026-09-30, and **all ten pass**. That is 2e's exit criterion, both clauses: the settings
pane itself, and *"every binding the pane draws has a credential the operator did not
paste."* It was not a clean walk. It found eleven defects, and every one was fixed and
re-walked before its check was marked.

### What the walk found

| Found at | Defect | Fixed in |
|---|---|---|
| organisation plane | the list could not scroll, and New organisation was out of reach | #320 |
| check 2 | row verbs stacked one letter per line in a narrower window | #326 |
| check 3 | an organisation with no accounts could not find `claude` (#271's Invariant-4 fix left it no path) | #322, with an operator override |
| check 3 | the pane's `ctx_add_provider` never forwarded `claudePath`, so **every pane registration had failed since #259** | #330 |
| check 3 | a refused binding said only "could not be written" | #323 (pane half) |
| check 5 | USE closed the settings pane, then, once reopened, twitched | #331, #334, #335 |
| check 6 | the ACCOUNT indicator kept naming an unlinked account | #324 |
| check 6 | Adopt and Register hid under an error banner | #325 |
| check 8 | the form took a connection string the driver cannot parse | #319 (separate fields) |
| check 8 | the form looked unfinished | #327 (a shared settings-form vocabulary) |
| the walk itself | a test wrote organisations into the operator's real `~/.wakil`, 40 of them, and a live Wakil read them half-built | #321 |

### The shape of the mistakes

**Every product defect was a path only running the app exercises.** #330 is the purest
case. The window model had sent `claudePath` since #259 and Go had required it since #259,
but the action between them dropped it, and every test that drove an add injected a fake
commit, so none of them reached that handler. The Cover rung, turned for 2e on
2026-09-29, could not reach it either, because the browser leg is uncoverable (#254). **Only
the walk exercised the whole path**, which is the argument for the rule that a phase is not
met until the operator has walked it.

**A diagnosis was wrong for a day, and the fix for #323 is what exposed it.** The first
register failure coincided with the #321 test leak, and a command-line retry that called Go
directly succeeded. It was recorded as the leak's doing. It was not: the retry succeeded
because it bypassed the Swift handler that was dropping the path. Only once #323 made the
pane show the refusal's own sentence could the cause be read rather than inferred. #323 and
#330 both record the correction.

**One fix was a patch where a structure was wanted.** #331 reopened the settings pane after
a provider switch, and #334 moved it back. The operator saw it twitch. #335 carries the pane
across the layout swap instead, so nothing closes. The first two were symptoms of treating
"the pane survives" as something to restore rather than something to preserve.

### What the walk left unestablished

- **#323's journal half.** A refused action is journalled as `"error"` with no text. Adding
  text needs a redaction review first, because an error sentence can quote what was typed.
- **Two operator rulings, recorded in the 2e plan as designs for after 2e.** Editing a saved
  database (approach B: store the parts, and only the password in the Keychain), and keeping
  the whole canvas on an account switch.
- **Suite flakes surfaced along the way:** #312 (a second instance noted), #328 and #332.
  None of them is 2e's.
- **The machine half was not re-rendered on the final build**, by the operator's call. It
  was last rendered at `edea12f` (#319). The fixes after it passed a full `make e2e`
  (24/24, #329 and #333), except #334 and #335, which were covered by unit tests and a hand
  check with no check or identifier changes. The next `make e2e-runbook` against `main`
  brings it level.

## 2026-10-04 — 2c-iv walked: the ten checks pass, after two amendments the walk drove

The operator walked `phase-2c-iv-acceptance.md` three times. The **first walk**
(2026-10-01) found that the pane could not add a query parameter or a header and that the
body could not hold a newline; Amendment 8 built them. The **second** (2026-10-03) passed
checks 1, 2, 3, 5, 7, 8 and 9 and failed 4, 6 and 10 on five defects and twenty changes;
Amendment 9 answered them in two plans — *saved as typed, and sending* (9a, 9b) and *the
split pane* (9c). The **third** (2026-10-04) re-walked 4, 5, 6 and 10 and **all pass**:
a request built by hand, every step, reaches `https://httpbin.org` and draws its reply —
2c-iv's exit criterion, both clauses.

### What the walks found that no check could

| Found at | Defect | Fixed in |
|---|---|---|
| walk 2, check 4 | no POST, PUT, PATCH or DELETE had ever left a pane — the window never set `WAKIL_IN_WINDOW` (#187's "setter owed") | `bd5ab8b` |
| walk 2, check 4 | Send committed a typed body but not a typed path, so the pane sent a request it did not show | Amendment 9a, saved as typed |
| walk 2 | a GET with a body failed on `wakil-http`'s schema; a content type beside an empty body was refused | 9b (B1, B2) |
| walk 2, check 10 | a switch left every api pane at *no origin*, round trip included; the chooser was dead on a restored pane | 9b (W1) |
| `make e2e` during 9a | the body lost the cursor after its first save; Format was undone on focus-out; the plane could name a different request than the wire; a Query edit did not redraw the path box (SwiftUI re-sets a field's own text on focus change) | plan A's fix rounds |
| walk 3 | the first agent turn after a launch rebuilt the canvas from disk and wiped an api pane's draft and entry (an account switch did the same) | `e51e847`, `8086317` |
| walk 3 | the split's dividers were invisible, Recent was unreachable at the default pane size, a root path read as a double space, the drop's line said only "Filled 1" | `e880dee` … `44d0305` |

### What the walk left unestablished

- **The body with holes is not one editor.** Literal boxes and chips are laid side by side,
  so multi-line JSON around a chip misaligns. The fix is the body as one text view with each
  hole an inline token — Amendment 10, designed next. It would also retire most of the
  chip-key and caret machinery that cost plan B's longest loop.
- **The environment menu once opened empty** (walk 3, after the canvas wipe). Not
  reproduced on the fixed build; the cause was never confirmed.
- **Deferred minors** from plan A's and plan B's reviews are recorded in their final
  reviews; none is operator-visible beyond the above.
- **Suite flakes:** #312's layout-persistence timing tests surfaced again under load.

## 2026-10-05 — 2c-iv Amendment 10: one editor per field, and check 4 re-walked

The walk of 2026-10-04 left one thing unestablished: the body with holes was literal boxes
and chips side by side, so JSON around a chip misaligned. Amendment 10 made **every field
— path, query values, headers and body — one TextKit 2 editor**, with each hole or bound
value a chip inside the text: one character to the caret, a real `×` at its right edge,
and AppKit owning typing, selection, undo, input methods and wrapping. Every rule about a
token (the key verdict, the bound-selection refusal, a move, the made-binding backstop) is
a WakilKit function with a test; the editor only applies the verdict. The per-box
machinery — the chip key catcher, the field items, the body caret, the index-keyed
save-as-typed — is deleted, and the save model holds one part list per field and writes one
region at a time. Nine tasks, each reviewed; a whole-branch review and one fix wave.
`make e2e` green at the commit the runbook's machine section names; all 22 changed checks seen red against `ed1af70`. The
operator re-walked check 4 on 2026-10-05: **it passes**.

### What the live looks found that no check could

| Found at | Defect | Fixed in |
|---|---|---|
| first look, body | a chip's space was reserved but nothing drawn: TextKit 2 asks for an attachment's view while drawing and places it only in a later layout pass | `88208f5` |
| second look, body | a white page over each hole after the text changed: a contentless attachment draws the stock document icon, which showed through the chip's tint | `3226050`, in a 30-minute live window |
| `make e2e` | the harness's `keys` and `type into` set the field's whole accessibility value and dropped every token in it; checks type beside a token one `press` at a time | `71ef940`; the app-side fix is [#342](https://github.com/yehia-khalil/rafiq/issues/342) |
| final review | a bare U+FFFC typed or set into a field shifted storage offsets against the model's, so a Backspace beside a bound chip could drop its binding silently (W16) | `8cfb5c7` |

### What it left unestablished

- **An accessibility client that sets a field's whole value** drops its holes, or is
  refused in a field holding a binding — [#342](https://github.com/yehia-khalil/rafiq/issues/342).
- **A hole dragged between fields** is walked, not checked: the harness cannot drag from
  inside a text view.
- **A chip at the path's wrap edge** and **a query row's `×` beside a twin holding typing**
  are walk items; no check pins either.
- **Suite flakes:** `2c-iii-7-org-switch` failed once under load and passed alone.

## 2026-10-06 — 2c-iv Amendment 11: a cURL command pasted into the path

**A request copied from a browser's devtools, an API's docs or a colleague's message is
sent from Wakil without retyping it.** A paste into an api pane's path that starts with
`curl` replaces the whole draft: method, path, query, headers and body, on the entry the URL
belongs to. If another entry of this environment matches, the pane switches to it. A host no
entry has is refused, and so is an entry of another environment. The line under the request
says what was filled and what was dropped, and carries **Undo**. Go reads the command
(`parse_curl`) and places its URL (`locate_api_url`), both read-only on `wakil-http`. Swift
decides and writes (`api_fill_from_curl`, `api_undo_fill`). The pasted text is journalled
redacted. Six tasks, each reviewed; a whole-branch review and two fix waves. `make e2e` is
green at the commit the runbook's machine section names, and all three new checks were seen
red against `42c75ce`. The operator walked check 11 on 2026-10-06.

### What the reviews and the walk found that no check had

| Found at | Defect | Fixed in |
|---|---|---|
| Task 1 review | the plan read an unknown flag as taking no value, so `curl -U alice:pw https://…` made the password the URL | curl's value-taking option table |
| Task 1 re-reviews | a header named `Authorization s3cr3t;` and a CR/LF inside a header value carried a credential past the deny list | one-token header names; a line break drops the header |
| final review | a non-breaking space between words (common in clipboards from web pages) glued `-H 'Authorization: …'` onto the URL, putting the token in the draft's path | one blank predicate for the splitter and the trigger, the same 27 scalars pinned in Go and Swift tests |
| final review | a URL's `user:password@`, and malformed authorities, came back out of `parse_curl` | userinfo dropped by name; an unreadable URL refused in Go |
| the walk | `www.httpbin.org` pasted against an `httpbin.org` entry was refused | a host differing only by a leading `www.` matches; the line names it; an exact host in any environment wins |
| e2e coverage | the paste channel was first excused as unreachable, but the harness's ⌘C/⌘V reaches it | `api-paste-curl-hotkey.jsonl`, copying from a plain field |

### What it left unestablished

- **Unicode domain names** (`bücher.example`) and IPv6 zones are refused by the URL check;
  an entry written in punycode is unaffected.
- **Layout-persistence tests flake under load**,
  [#344](https://github.com/yehia-khalil/rafiq/issues/344), which predates this branch.
- **An accessibility client setting a field's whole value**,
  [#342](https://github.com/yehia-khalil/rafiq/issues/342), still owed from Amendment 10.

## 2026-10-06 — 2d-i moved ahead of 2c-vi, and its resolver measured

**The operator deferred 2c-vi and started 2d-i.** 2d-i's row had waited on *"the rest of
2c"*, which was sequence rather than a blocker: the resolver needs no audio and no model, and
the one source it loses until the PM board exists is Jira keys, which plug in later as one
more `IdentifierSource`. 2c-vi is deferred, not cut, and still waits on question 15 for its
write half.

**The design was measured before it was written.** Two recordings of the operator's voice,
the second written and frozen before recording, settled that 2d-i ships **fold only**: near
matching passed on the set it was tuned on and failed the fresh one. Result in
`2d-stt-probe.md` §10; design in
`docs/superpowers/specs/2026-10-06-2d-i-identifier-resolution-design.md`.

**Two things the design conversation moved to 2d-ii.** The composer revamp and the Core's
listening state, both now on 2d-ii's row. And from the measurement: an allow-priced write can
run from a mistranscribed spoken turn, so 2d-ii's composer should show the transcript before
sending. **One thing it found no phase owns:** the speaking state has nothing to drive it,
because nothing delivers text-to-speech — open question 17.

## 2026-10-08 — 2d-ii walked: voice reaches the composer, and every step passes

**2d-ii shipped in #354** — push-to-talk on ⌥, Apple's on-device `SpeechAnalyzer` behind a
per-organisation speech registry, the composer bar, the thread over full-height panes, and the
listening breath. Design in `docs/superpowers/specs/2026-10-07-2d-ii-voice-capture-design.md`;
walk in `phase-2d-ii-acceptance.md`. **Release lands, it does not send** (design-language §12,
amended): 2d-i measured that an allow-priced write can run from a misheard turn, so the
transcript waits unsent in the composer until Return.

The operator walked it on this Mac's own microphone and **every step passes**. The breath's
numbers were approved unchanged against the running room.

### What the walk and the Cover rung found that no unit test could

| Found at | Defect | Fixed in |
|---|---|---|
| Cover, first agent run | thread rows were exposed as buttons, so their text was invisible to accessibility | `e2ed58a` |
| Cover | select-all in the new composer opened Writing Tools, and the harness read that panel | `62fc9c9` |
| Cover | the scripted agent ran from `~/Desktop`, so a TCC Desktop prompt blocked it | `e6ee568` |
| walk | the words appeared only on release, not while held | `36fba0f` (`fastResults`, a prepared model) |
| walk | "no project root available yet" stayed after a project with a root was open — pre-existing since 2b-v | `80c97d7` |
| walk | ⌥ looked dead: the first-use macOS prompt took the key window, and the bar could miss its window | `fa1c47d`, `5b2e4f2` |

### What the walk left unestablished

- **The first-use model download** was not exercised; the model was already installed.
- **Two intermittent e2e checks**: `2d-ii-thread-earlier` (Esc after expand, once in three)
  and `2d-ii-voice-lands-unsent` (another app taking the foreground mid-hold). Both are in the
  runbook's §2; the final run passed 65 of 65 with no re-runs.
- **Pre-existing, filed:** a pane twitches after a drop (#353).


## 2026-10-09 — 3a-i walked: the Git pane, read-only, and every step passes

**3a-i is the first Phase 3 sub-phase**: a read-only Git pane listing every root of the active
project with Staged, Changes and Untracked groups, drilling into a Monaco diff with the list
folded into a spine (or, at ≥ 900 pt, a file-name column), kept live by FSEvents, dual-driven,
and voice-addressable. Design in `docs/superpowers/specs/2026-10-08-3a-i-git-pane-read-design.md`;
walk in `phase-3a-i-acceptance.md`. `wakil-git` is a new headless, agent-facing MCP server whose
read-only claim is enforced by construction: an allowlisted runner, scrubbed environment, and
repo-supplied programs neutralised (filters, submodule children, signature programs, lazy fetch).

The operator walked it on this Mac and **all ten steps pass**. 3a-ii (stage, commit) and 3a-iii
(push, pull with a Wakil-held SSH key per organisation) follow.

### What review, Cover and the walk found that no unit test could

| Found at | Defect | Fixed in |
|---|---|---|
| probe | Monaco painted no text: the probe never ran an NSApp event loop | `c826ee2` |
| final review + sweeps | a repository's own config could still make git run a program (filters, submodule diff, signed gitlinks, partial-clone fetch) | `c99739f`..`c641ae6` |
| Cover | the pane's keyboard did nothing; rows had no accessibility press | `7a68f0b` |
| Cover | the #339 input guard counted the harness's own keystrokes as physical input (H1) | `89868d0` |
| walk | switching files was slow: the shared MCP frame reader was quadratic and capped below a 2 MB file's reply | `bbb125f` |
| walk (request) | a wide folded pane showed only status marks; it now shows file names | `72b97b4` |
| suite | two races in the watcher's start/stop on org and project switch | `5c09971` |

### What the walk left unestablished

- **Pre-existing, filed:** the terminal pane cannot paste or edit a selection (#365).
- The runbook's §2–§3 residue: cold-cache Monaco load, watcher refreshes journalled as `ui`, a
  pruned linked worktree, and the visual rulings.

## 2026-10-16 — 3b-iii walked: the Changes view, diff tabs, gutter marks and the peek

**3b-iii folds the 3a-i Git pane into the editor.** Its list is the editor's Changes view (⌘⇧G),
each changed file opens as a read-only diff tab, a tracked file carries change marks in its
gutter against the index, and a peek on a mark shows the change and reverts it as an undoable
buffer edit. Nothing writes to git (Decision 40). A saved Git pane migrates to an editor pane on
Changes. Design in `docs/superpowers/specs/2026-10-15-3b-iii-changes-view-design.md`; walk in
`phase-3b-iii-acceptance.md`. Shipped as stack #12, PRs #5–#11 and #13.

The operator walked it on this Mac, under `personal`, and **all ten steps pass**.

### What review, Cover and the walk found that no unit test could

| Found at | Defect | Fixed in |
|---|---|---|
| final review | ⌘⏎ in a diff tab opened the wrong line after a swap; open and restore waited on git; a double Revert applied a stale range | `-7-review-fixes` |
| Cover | a diff tab and a Changes header reached the accessibility tree as nameless buttons | `3dc72d8` |
| Cover | an untracked file was marked all-added: `git_show` answered its index side as an empty file (it now says `absent`) | `3dc72d8` |
| Cover | ⌘Z after an agent edit and a Revert undid both: Monaco merged the two edits into one undo step | `3dc72d8` |
| walk | a click on a Changes row waited out the double-click interval before opening | `4b6b699` |
| walk | the peek's ↑ ↓ Revert × took no clicks: a view zone sits under Monaco's text layer | `4b6b699` |

### What the walk left unestablished

- The runbook's §2–§3 residue: colours, the peek's buttons by the harness (HTML in the web view),
  double-click to pin, and the half-second refresh, all walk-only.
- **Pre-existing, not 3b-iii's:** `api-bound-locks.jsonl` fails intermittently, on main too (3 of
  4 runs on 2026-10-16); `3b-i-editor-unsaved-save.jsonl` lost its app once with no crash report.
- North-star §8 has no Phase 3b rows, so 3b-iii's `Met` is recorded here and in the runbook.

## 2026-10-22 — 3a-ii-b walked: stage and unstage selected ranges, and a drafted commit message

**3a-ii-b finishes 3a-ii's write path.** A Changes diff tab stages only the selected lines (a
button over the diff, the right-click menu, ⌘K), a Staged one unstages them, and ✨ in the commit box
drafts a message with the org's quick model from what Commit would commit; the operator edits and
commits. Ranges are merged in Swift and written through 3a-ii's `git_stage_hunk` under its blob guard.
Design in `docs/superpowers/specs/2026-10-22-3a-ii-b-ranges-and-drafts-design.md`; walk in
`phase-3a-ii-b-acceptance.md`.

The operator walked it on this Mac and **all ten steps pass**, after the two walk fixes below.

### What review, Cover and the walk found that no unit test could

| Found at | Defect | Fixed in |
|---|---|---|
| final review | a partial selection beside an unterminated last line moved its missing newline; a refreshing diff tab staged a fresh read's lines; drafts from the agent had no ⌘Z; files past `git_diff`'s cut were not named | `020f3d1`..`cd41b98` |
| Cover | the **Commit drafts** switch did nothing: `ctx_update_org` forwarded only listed keys | `46b5f76` |
| Cover | a partly selected block staged its unselected neighbour's removal, or unstaged beside the line that stayed: blocks now pair old and new lines (spec amendment) | `46b5f76`, `1f0899f` |
| walk | a wrapped message scrolled in a one-line box; ✨ drew in the emoji's yellow | `0501126` |

### What the walk left unestablished

- `make e2e-full` on `ec123ce`: 196 of 198 green. `api-unbind.jsonl` and
  `bg-agent-chip-over-landing.jsonl` are red there **and on `main`** (re-run against a 91f64b7 bundle,
  same failures), so not this branch's; neither has an issue yet.
- Deferred minors from the final review are listed in the runbook's §2.

