# Review — the charter, and a design audit

**Status:** assessment · **Date:** 2026-09-14 · **Reviewer:** Claude Code, at the
operator's request

This document changes nothing. `north-star.md`, `design-language.md`, every spec, every
acceptance runbook and every source file are exactly as they were. It records what a
full read of the charter and a full audit of the shipped interface found, with a
file:line for each claim so every one of them can be checked or refuted.

Two things were asked for: a review of the north star, and *"a design audit — I want to
make sure the final product is usable and UI friendly."* They turned out to be one
finding seen from two sides. **The charter contains an arbitration test it has never
once applied, and the design language contains an aesthetic doctrine it has never costed
against usability.** Both documents reason unusually well and verify unusually little.

---

## Summary — the six findings that change what happens next

1. **Light Mode renders the app's safety-critical text invisible.** No `Info.plist` in
   the repo, no `NSRequiresAquaSystemAppearance` in the one the bundle script
   synthesizes, no `.preferredColorScheme(.dark)` anywhere. Backgrounds are hardcoded
   near-black; the SQL statement in the confirmation plane, and every error message in
   the app, carry no explicit colour and resolve to the system label colour — black on a
   Light Mode Mac. §F0.
2. **The production environment badge is rendered at 1.46:1 contrast behind a 1.4pt
   blur.** Invariant 8 says *"production is unmissable."* It is the lowest-contrast text
   in the application, and the production state is *less* legible than the normal one.
   2b-ii's visual review already recorded that production reads *"warm rather than
   alarming"* — this is the arithmetic behind that observation. §G.
3. **The production trigger is an exact string match, inconsistent three ways.**
   `" production"` paints the room red while the write gate treats it as
   non-production; `prod`, `prd` and `live` get no red room, no red badge and no write
   block at all. §H.
4. **Decision 21 — written 2026-09-14, the newest entry in the charter — is costed on
   two premises that the same document and a code comment both refute.** The next
   sub-phase's sequencing rests on it. §A1.
5. **The walks have found 34 defects; 21 are interaction/usability and 9 are visual.**
   28 of 34 were found by a person looking at a screen, every one against a green suite
   of 605–709 tests. The mechanical cause is that `WakilApp` has no test target, so the
   suite covers 0% of the surface the walks test, and every screenshot lands in a
   gitignored directory. §F, §N.
6. **Decision 1's entire justification is scheduled last.** Native macOS rests wholly on
   voice — *"Reverse if: voice gets cut"* — and there is no speech subsystem at all, no
   spec and no plan, in a phase explicitly *"ordered by risk retired."* §E2.

### What this review is based on

Full reads of `north-star.md` (968 lines) and `design-language.md` (445); a
per-invariant audit of all eleven invariants against the Go and Swift source; a
phase-map reconciliation against `git log`, 16 specs, 16 plans and 24 acceptance and
probe documents; a read of the SwiftUI view layer; and WCAG 2.1 contrast ratios computed
against the void's real shader values.

### What this review is not

It is not a re-litigation of the product. The charter's judgement calls — native over
Electron, dual-drive over convenience, subscription over API key, honesty over polish —
are sound and are not questioned here. Nor is its candour: this project records its own
shortfalls better than most. §O says what must survive any cleanup.

---

# PART 1 — The charter

## A. It contradicts itself, its siblings, and the code

### A1. Decision 21 is costed on two false premises

Decision 21 (2026-09-14) argues the ordering of the setup UI:

> Adding a **credential** is a different thing entirely: it is the first Keychain WRITE
> from Swift, and **Swift has not yet performed a Keychain READ**. **The provider
> picker, still owed from 2b-iii**, is that read, and its own row above flags it as "its
> own risk surface entirely." So the ordering is forced rather than chosen: the provider
> picker's read lands first… a plan that schedules the credential UI without the
> provider picker has **mis-costed itself by an entire risk surface**.

Both premises are wrong.

- **The provider picker is not owed.** `north-star.md:664`, in the same document:
  *"**2b-vi** | Provider picker | … **MET 2026-09-11.** Walked in full by the operator:
  all three checks … pass, in both directions and on `production` as well as
  `staging`."*
- **Swift does not read the Keychain, and is designed never to.**
  `app/Sources/WakilKit/App/ProviderCredentialsLookup.swift:6-14` is titled *"WHY SWIFT
  DOES NOT READ THE KEYCHAIN"*: *"A Swift copy that drifted from that scheme would not
  fail loudly; it would return the wrong org's credential, which is the cross-org
  sharing the 2026-09-06 decoupling ended. **So Go reads, and this asks Go.**"*
  `grep -rln "import Security" app/Sources` returns nothing.

The risk surface Decision 21 says must be crossed first was crossed three days earlier,
by a route that states in a doc comment that it will never be crossed the way Decision
21 assumes. This is the most immediately consequential finding in Part 1, because the
sub-phase after 2c-ii-b is sequenced by it.

### A2. The production block is not an invariant

The hardest safety rule in the product exists only in `design-language.md:326-328`:

> **Environment governs the gate.** Staging: confirm and proceed. **Production: blocked
> outright in v1 (read-only, no override)**, gate turns red.

The charter references it at `:370`, `:421-422` and `:608-613`, and three of four recent
specs depend on it. But Invariant 8 (`:108-110`) says only *"The active environment is on
screen at all times. Production looks alarming."* A rule no phase may break is recorded
in the document that is supposed to conform to the charter, not in the charter.

### A3. The charter breaches Invariant 1 in its own text

Invariant 1: *"Nothing outside the harness adapter knows Claude exists."* Decision 17,
`north-star.md:325-326`:

> three-tier autocomplete (Monaco basic → per-language LSP on demand → **AI ghost-text
> from the org's Claude account**)

The same sentence is duplicated at `design-language.md:302-303`.

### A4. Invariant 2 has an undeclared carve-out, granted by a sibling document

`design-language.md:269`:

> Every pane is dual-driven (Invariant 2) **except the editor's text surface**.

Repeated at `:274` — *"The one partial exception to dual-drive."* The charter says
invariants are *"Rules no phase may break"* (`:58`) and that a spec needing to violate
one requires *"the charter changes first — deliberately, with a dated entry"* (`:8`).
Neither Invariant 2, nor Decision 9, nor Decision 17 records this exception.

### A5. Cross-references are unreliable in both directions

- **The charter cites a rule that does not exist.** `north-star.md:378-380` attributes
  to `design-language.md` §8 a general law — *"which is the rule `truncated` and the sort
  footer already obey (`design-language.md` §8): a surface that cannot do the thing must
  not look like it can."* `grep -ci "look like it can" docs/wakil/design-language.md`
  returns **0**. §8 states only a narrow ruling about paging controls
  (`design-language.md:202-208`): *"a control that returns a syntax error is worse than
  no control."* The general principle is the charter's own invention, attributed
  elsewhere.
- **The sibling mis-cites the charter.** `design-language.md:309` writes *"Voice is a
  transport, not a command language (**Invariant 10**)."* That is **Decision** 10
  (`north-star.md:230`); Invariant 10 is the capability/action split. The same section
  cites *"charter Decision 18"* correctly at `:318`, so the error is local.
- **An ordinal range used as an exit criterion has rotted.** `north-star.md:534` sets
  2b's exit at *"`design-language.md` §1–13 realised"*. §13 is no longer the last
  section — the doc gained §14 Settings and §15 Open items — so the range silently
  excludes two sections, one of which (§15) records that 2b-ii's items are *not* closed.
  And `:659`, 2b-ii's own row, scopes the same exit at *"§1–9 realised."*

### A6. Invariant 1 is violated in code, in the one layer §2 says must not be

Recorded here as debt. This review does not choose between amending the charter and
fixing the code — see *Recorded debt* below.

### A7. Both halves of 2b's exit criterion are unmeasurable, and the charter says so

`north-star.md:534` asserts *"120fps; project switch < 400ms."* `:902`: *"**One exit
criterion above is now known to be untestable on the build machine.** Both its displays
are 60 Hz, so *'120fps'* cannot be observed here at all."* `:757-758`: the project-switch
row *"is a judgement that the glide is fast enough, **not** a measurement, because no
number was ever put to a stopwatch."* The row still asserts both.

---

## B. Authority is flowing the wrong way

### B1. The arbitration test has never arbitrated

`north-star.md:22-24`:

> **The test, for settling future arguments:**
> A feature earns its place in Wakil only when its absence forces you to leave.

`grep -rn "forces you to leave\|earns its place" --include=*.md docs` — excluding this
review, which quotes it — returns **exactly one hit: the definition itself**. Across
roughly 363,000 words of project
documentation, twenty-one decisions, fourteen open questions and six phases have been
settled without it. A tie-breaker that has never broken a tie is decoration, and §E1
shows what it would have changed had it been used.

### B2. Three-quarters of decisions carry no reversal condition

§6 declares its own entry format — *"Each entry: the call, why, and what would change
our mind."* Only **6 of 21** entries carry a *Reverse if* (1, 2, 17, 19, 20, 21). The
fifteen without include the most expensive commitments in the product:

- **Decision 9** — every pane dual-driven, self-described as costing *"~1.5–2× a plain UI
  pane and cannot be retrofitted"*, with no stated condition under which it would be
  abandoned.
- **Decision 13** (session history read from disk) and **Decision 16** (harness/provider
  axes), both load-bearing for the harness design.

### B3. Specs now decide what the charter is supposed to decide

The charter's rule (`:7-9`): *"Phase specs … must conform to this document. If a phase
spec needs to violate an invariant here, the charter changes first — deliberately, with
a dated entry."* Four current specs do not.

**`2026-09-14-multi-org-window-design.md`** declares itself *"binding authority for the
sub-phase that follows 2c-ii-b"* and *"**Closes:** north-star open question 13, added the
same day."* It makes several organisations live simultaneously — *"every open org keeps
its own five `wakil-*` servers, and every open project keeps its own live Claude session…
three orgs with two projects each is fifteen server processes and six Claude sessions."*

Credit where it is due: the spec is careful exactly where it matters most. It multiplies
`WindowModel` rather than parameterising it, specifically so Invariant 4's credential
boundary stays inside a single-org type — *"A `WindowModel` never learns another org
exists"* — and no query spans two orgs, so the **Not cross-organization** non-goal holds.
Invariant 4 is not strained.

**Invariant 5 is, and the spec never names it.** It cites Invariant 4 four times and
Invariant 5 zero times. The charter says *"**Exactly one active (org, project,
environment).** Implicit scope is the product"*, and the glossary reinforces it:
*"Exactly one is active."* The spec's model is N live, one focused. Its defensible
position — that "active" means "focused," and every tool call still resolves against one
triple — is one it never actually argues. And the invariant's own justification,
*"implicit scope is the product,"* is precisely what N background agents complicate: an
agent running in an unfocused context resolves implicitly against a triple the operator
is not looking at. The spec's §9 concedes the visibility problem for the confirmation
broker (*"That reasoning assumes the operator can see it"*) and patches it by pausing the
timeout — a symptom of the same strain.

It also self-records a second crack rather than sending it to the charter: *"**This is a
deliberate crack in the boundary and must be recorded as one.** … A file that names `initech`
and `umbrella` together asserts that one person works on both."*

And it contradicts Decision 21 head-on, both dated 2026-09-14: the spec says *"**No org
creation, deletion or provider registration in-app.**"* Decision 21 opens *"**Every
configurable thing — organisations, projects, environments…** is creatable and editable
from inside Wakil.app."*

Meanwhile open question 13 still records the opposite option as live — *"Reverse if: one
org per window proves to be how the operator actually works, in which case the honest
answer is a launcher that sets `WAKIL_ORG` and no in-app switch at all."*

**Every other invariant that came under pressure got a dated amendment** — Invariant 4's
*"History, consolidated 2026-09-07"*, Invariant 6's 2026-09-09 parenthetical. Invariant 5
has not.

**Three more, briefly:**

| Spec | The strain |
|---|---|
| `2026-09-12-phase-2c-ii-db-pane` | Relaunch *"issues queries on its own… **eight unasked-for reads against production the instant the app opens**"* — against the non-goal *"Not proactive in Phases 1–3. Wakil does not interrupt."* Separately, `c.gate(spec.Raw)` judges the operator's text but the driver executes a subquery wrapped around it, so **the gated string ≠ the executed string** — a fact about Invariant 6 that lives only in the spec. |
| `2026-09-13-phase-2c-ii-b-record-editing` | §7.4's `=` sigil passes text through unescaped: *"An operator who writes **`=1 WHERE 1=1 --`** gets exactly the statement they wrote"*, and *"**`MutationAffectsEveryRow` will not flag that statement**, because it does contain a `WHERE`."* Invariants 2, 6 and 7 hold — the plane and gate still fire — but **Decision 20's** own provenance rule (*"A cell is editable only when the pane can name the single table its rows came from"*) is defeated through the value rather than the key. |
| `2026-09-13-integer-fidelity` | Records a **live Invariant 3 breach**: *"`read_pane` hands the agent the wrong key… The operator is asked to confirm a correct-looking statement aimed at a row that is not theirs. **This is a live path today.**"* True for every integer above 2^53, on the path feeding the write gate, from 2c-i's ship until 2026-09-13. **The charter mentions integer fidelity nowhere at all**, and 2c-i's row still reads clean. |

### B4. Open questions are essays inside table cells

Questions 12, 13 and 14 run 200–450 words each inside a single `|`-delimited row. Q13
alone contains an invariant re-interpretation, a mechanism proposal, a blast-radius
analysis and a *Reverse if*, and names `CurrentOrg`, `WAKIL_ORG`,
`AppWiring.childProcessEnvironment`, `project.json` and `Resolve()`. A table whose cells
need paragraphs is not a table.

---

## C. Size and structure

The charter opens with its own failure predicate:

> Keep this under five pages. Past that it has become a spec and will rot.

It is **11,795 words** — roughly 4.7× five pages. It has grown monotonically from 2,865
words on 2026-09-06 to its present size in eight days across sixteen commits, adding
**747 lines and removing 98**. It has never once been cut.

| Section | Words | Share |
|---|---|---|
| §1–3 What / Who / Frictions | 314 | 3% |
| §4 Invariants | 627 | 5% |
| §5 Non-goals | 135 | 1% |
| **§6 Decisions** | **3,616** | **31%** |
| §7 Open questions | 1,084 | 9% |
| **§8 Phase map** | **5,601** | **47%** |
| §9 Glossary | 331 | 3% |

**C1. The north star is 12% of the north star.** The charter-grade material — what Wakil
is, who it is for, the frictions, the invariants, the non-goals, the glossary — totals
1,407 words.

**C2. §8 is an acceptance log, not a phase map.** It carries defect identifiers (`D1`,
`D7`, `D8b`, `D11`, `D13`), dated test counts (319, 605, 649 — the current figure is
709), probe findings and per-walk narratives, all of which already exist in
`docs/wakil/*-acceptance.md`. The retrospectives about acceptance *discipline* alone —
the 2b-iii, 2b-v, 2b-ii/iv and 2b-vi notes — run to roughly 184 lines, about **19% of the
whole charter** and roughly twice the size of the phase map's forward-looking content.

**C3. Decision entries have inverted in size.** Decisions 1–15 (2026-09-03) have a median
length of **5 lines**. Decisions 16, 20 and 21 are **50, 69 and 48**. Decisions 20 and 21
together (117 lines) are as long as the first fifteen combined (131 lines).

**C4. Spec-grade material that has no business in a charter.** Reproduction steps
(`claude` 2.1.263, `ANTHROPIC_BASE_URL=http://127.0.0.1:8787`, `POST
/v1/messages?beta=true`, `anthropic-version: 2023-06-01`); a literal grep and its hit
count (`:838-839`); a version pin for an SDK the project then chose not to use
(`@anthropic-ai/claude-agent-sdk@0.3.237`, `:165-172`, superseded twenty lines later at
`:180-192`); and a **63-line design memo** — *"An input to 2b-ii: cap the frame rate, but
cap the right thing"* (`:873-936`) — sitting between sub-phase 2b-vi and Phase 3, with
its own prediction/answer/supersession structure. Its conclusion is already stated more
tersely and more usably in `design-language.md:155-157` and `:347-350`. The charter holds
the working-out; the design doc holds the answer. That is inverted.

**C5. Five paragraphs begin mid-sentence.**

| Line | What is there |
|---|---|
| `:614` | An orphan fragment with no subject: *"otherwise — is the reason 2c-ii's runbook exists at all."* |
| `:616` | A paragraph opening with a bare file path: *"`docs/superpowers/specs/2026-09-11-phase-2c-i-data-surface-design.md` §0. Two of the six have specs of their own…"* |
| `:687` | *"All of its plan's tasks are done…"* after a section break |
| `:760` | *"All 14 of its plan's tasks are done…"* |
| `:794` | A paragraph beginning with the single word *"The"* |

`:614` and `:616` were introduced by `7802db2` on 2026-09-13. Nobody has read the
document end to end in the days since — which is the mechanism behind every other finding
in Part 1.

---

## D. Phase map vs. reality

| What the charter says | What the repository shows |
|---|---|
| 2a's row (`:533`) carries **no status at all** | Everything downstream is built on it, and its exit criterion was demonstrated. The only delivered sub-phase with no verdict. |
| 2c-ii-b's cell (`:551`) is entirely in blocked/future tense — *"blocked until 2c-ii's `D8b`… and `D7`… are closed"* | Both closed 2026-09-13. The code shipped (`4eb85f1`) and was walked (`df3adf0`). `phase-2c-ii-b-acceptance.md:3`: *"**Status: walked 2026-09-14. Twenty of twenty-three checks pass; three do not close.**"* All three fail for one reason — *"Three checks, one credential."* Leaving the row unmarked was deliberate and correct; the charter carrying no record that the walk happened is not. |
| Invariant 4: *"The second half is not yet… It **arrives with** the Phase 2a harness."* | It arrived. `WindowModel.swift:687-688` emits `WAKIL_ORG` and `WAKIL_PROVIDER` into every server's `env` in the generated `--mcp-config`, rebuilt per selection (`WindowSession.swift:162-178`). An 11-line "not yet" whose "yet" is answered 750 lines later in the same file. |
| Phase 3's body lists *"Embedded editor (`code-server` pane)"* | Decision 17 explicitly revised **away** from `code-server`: *"(Revised 2026-09-03. Originally: embedded `code-server`, black box, built last.)"* The charter is stale in both directions on the same subject. |
| `2d` = *"Push-to-talk, pluggable STT, live transcription"* (`:536`) | The multi-org spec names its runbook `docs/wakil/phase-2d-acceptance.md`. **Two subsystems now claim the label.** The file does not exist yet, so nothing has broken — yet. |
| — | **Integer fidelity** has a spec, a plan and a shipped commit. `grep -i "integer\|fidelity" north-star.md` → **zero hits**. Also absent: the readonly-gate lexer work (plan, no spec, no row) and org/provider decoupling (recorded only as an Invariant 4 amendment). |

### Open questions

Four are answered elsewhere and still listed as open; two block on a phase that shipped.

- **Q4** *(is the embedded editor needed?)* — Decision 17 does not ask, it commits, and
  non-goal 1 states it as settled.
- **Q10** *(which STT default?)* — Decision 18 answers it verbatim: *"Apple's on-device
  recognition is the default."*
- **Q12** *(is `confirm`-then-Run the right price for a cell edit?)* — **answered.**
  `phase-2c-ii-b-acceptance.md` check 22: *"`confirm`-then-Run held up across repeated
  edits. The operator ran several back-to-back and raised no complaint about the price
  itself, **which is the question open question 12 actually asks**."*
- **Q13** — closed by a spec written the same day, which says so in its own header.
- **Q6** and **Q8** carry *"Blocks: Phase 1"*, and Phase 1 is MET.

The multi-org spec's §14 also raises two further open questions that never reached §7.

### One sibling document with a stale code block

`org-and-provider-model.md` is correctly marked SUPERSEDED at line 3 and carries inline
dated corrections — but `:140-148` was never corrected and still shows:

```go
func CurrentOrg() string {
    if org := os.Getenv("WAKIL_ORG"); org != "" { return org }
    return OrgFromConfigDir(os.Getenv("CLAUDE_CONFIG_DIR")) // legacy fallback
}
```

The shipped `internal/wakilcore/paths.go:48-58` has **no fallback and a different
signature** — it returns `(string, error)` and refuses. Open question 13's entire
argument depends on that refusal (*"`CurrentOrg` refuses a fallback so that config can
never set the ambient org"*). A reader who reaches the code block before the banner gets
the opposite of the invariant.

---

## E. Direction

### E1. The ranked frictions are largely untouched

§3 lists the frictions *"in rough order of daily pain."* After eleven days:

| # | Friction | Status |
|---|---|---|
| 1 | Identity re-selection | Untouched in-app — the provider picker selects Claude accounts, not Jira/Slack identities |
| 2 | Context reconstruction | Partly — session resume (2b-v), accepted without a walk |
| 3 | Source-blind search | Untouched — `wakil-recall` is headless only |
| 4 | Tool fragmentation | Partly — DB pane only; terminal (2c-iii) and API client (2c-iv) unbuilt |
| 5 | Multi-step chores | Untouched — needs 2c-iv |

Against this, **2b-ii and 2b-iv — the void, the Core, atmosphere, motion — consumed two
full sub-phases, roughly 26,000 words of spec and plan, and a Metal renderer.**

Applied honestly, §1's own test does not admit them: the absence of a luminous void does
not force anyone to leave. This is not an argument that the atmosphere was worthless —
it is visibly the thing that makes Wakil feel like itself, and the honesty of its
specification is exemplary. It is the observation that **the charter contains a test
which, had it ever been applied (§B1), would have reordered the work**, and it was never
applied.

### E2. Decision 1's entire justification is scheduled last

Decision 1 (native macOS) rests wholly on voice:

> Voice justifies it — on-device speech, TTS, global hotkeys, menu bar, Keychain are
> first-class only here. *Reverse if:* voice gets cut, at which point a VSCode extension
> becomes overwhelmingly cheaper.

Voice is **Phase 2d — unstarted**. There is no speech subsystem at all: zero matches for
`SFSpeech`, `AVAudio`, `AVFoundation`, `Speech`, microphone, push-to-talk, dictation or
STT anywhere in `app/Sources`; `app/Package.swift` declares no such dependency; there is
no spec and no plan. Open question 10 is still open.

Phase 2 was explicitly *"Ordered by risk retired rather than by visible progress"* — yet
the single decision the largest architectural commitment hangs on is the last risk
scheduled, and the charter flags this nowhere. Every week 2d slips is a week Decision 1
is unfalsified rather than validated.

---

# PART 2 — Design audit

## F0. Light Mode renders the app's safety-critical text invisible

**Highest-severity finding in this audit, and a one-line fix.**

The app never forces its appearance:

- There is no `Info.plist` in the repository. The one `scripts/make-app-bundle.sh:55-65`
  synthesizes carries `CFBundleName`, `CFBundleIdentifier`, `CFBundleExecutable`,
  `CFBundlePackageType` and `CFBundleShortVersionString` — and **no
  `NSRequiresAquaSystemAppearance`**.
- `grep -rn "preferredColorScheme\|NSRequiresAquaSystemAppearance\|NSAppearance"
  app/Sources app/Package.swift Makefile` returns **nothing**.

Backgrounds are hardcoded near-black — `AppScene.swift:127` (`#030408`),
`ConfirmationPlane.swift:77` (`black @ 0.86`), `Canvas.swift:310` (`#0E1019`). But a long
list of `Text` views carry **no `.foregroundStyle` at all**, and therefore resolve to the
system label colour, which is **black in Light Mode**:

| What | Where |
|---|---|
| **The SQL statement the operator must read before typing `confirm`** | `ConfirmationPlane.swift:52-55` — font, `textSelection`, frame, **no colour** |
| The confirmation heading and the database name | `ConfirmationPlane.swift:39-40,48` |
| **`Text(model.status)` — every error message in the app** | `WakilWindow.swift:554` |
| `"starting…"` — the entire launch state | `WakilWindow.swift:273` |
| Wiring diagnostics | `WakilWindow.swift:560` |
| Rail rows | `Rail.swift:19-22` |
| `Text("resize")` | `Canvas.swift:298` |
| Palette items | `Palettes.swift:49-50` |

On a Mac set to Light Mode, the confirmation plane shows black text on a near-black
plane, and the operator is asked to type `confirm` for a database mutation they cannot
read.

**Confidence and its limits.** This is a high-confidence inference from the code, not an
observed render — the app could not be run here. That caveat is itself the finding:
there is no Light Mode test, no snapshot baseline, and every acceptance walk was
performed on one machine in one appearance. This is exactly the class of defect the
project's instruments cannot see (§N).

**Fix:** either `NSRequiresAquaSystemAppearance` in the bundle script's plist, or
`.preferredColorScheme(.dark)` on the scene — or, if the *"light-environment variant"*
§15 contemplates is ever wanted, give every unstyled `Text` an explicit token now.

---

## F. The empirical answer: what happens when a human uses it

The project has already collected most of the evidence. Across six acceptance walks,
**34 defects**:

| Class | Count |
|---|---|
| **Interaction / usability** | **21** |
| **UI / visual** | **9** |
| Correctness / logic | 6 |
| Performance | 1 |

*(some defects count in two classes)*. **28 of 34 were found by a person looking at a
screen**, with 605–709 tests green at every point.

### The operator's own words

These are the highest-value usability signals in the repository. All three describe
something **invisible**:

> **"i dont see the edge of the column so i cant drag and resize it"**
> — `phase-2c-i-acceptance.md:172`. The handle was a 6pt transparent strip with no cursor
> and no mark. The document's own gloss: *"A 6pt transparent strip with no cursor and no
> mark is a control only someone who has read the source can use."*

> **"it says nothing is open and still doesnt open them"**
> — `phase-2c-i-acceptance.md:215`. The operator was looking at an empty canvas while the
> agent relayed "no pane is open, here are the raw results" and stopped. This overturned
> a shipped design decision.

> **"sort is working but not written somewhere on the pane"**
> — `phase-2c-i-acceptance.md:154`. *"The operator looked for the sort in the footer and
> did not find it."*

**Two of the three are still open.** The sort indicator was re-examined at 2c-ii check 6
and left silent again; the query-line affordance is deferred to 2c-iv.

### The dominant defect class: a surface stating something untrue

Twelve or more instances, spanning every walk. `1 rows`. `DOCS` drawn over SQL rows. `no
rows` for three unrelated states. A `production` banner over staging rows. `ACCOUNT`
meaning two different things 1,400pt apart. `readOnly` published to the agent while the
field that actually decides is omitted. *"completed with no output"* for every action
that in fact returned a payload.

The operator's phrase, still quoted verbatim in `DBPane`'s doc comment a full phase
later: **"a pane titled EVENTS showing customer rows has a lying title."** And the
project's own conclusion, from D10: *"a banner the operator has learned to distrust is
worse than no banner."*

### "Rows returned, nothing on screen" has five distinct causes

The codebase tracks this as a numbered family. `Pane.swift:124`: *"Three panes reading
'no rows' again, from a third cause."* 2c-i instructed 2c-ii to **assume a fifth cause
existed**. It did. Root cause: `DBPane.swift:72` keyed `no rows` on
`table.columns.isEmpty`, *"which is true in three unrelated states."*

### Fixes reach some call sites and not others

D13 is D12 surviving at *"the most ordinary action in the application: typing a query and
pressing Return."* D7's first fix was on a code path that never fires. 2c-ii-b's D3 is
2c-i's complaint still standing a phase later — *"The fix was half-applied and the half
that was skipped is the half the operator was complaining about."* This is a systemic
pattern, not three coincidences, and §N explains the mechanism.

---

## G. The far-plane treatment breaks the two surfaces that matter most

`Plane.far` = **scale 0.94, opacity 0.30, blur 1.4** (`WakilKit/Visual/Plane.swift:20-37`).

Two things render on it:

- **The rail** (`Rail.swift:42-45`) — *"It exists because floating panes can hide behind
  each other"*, i.e. the only way to reach a pane dragged off-canvas.
- **The environment badge** (`WakilWindow.swift:443-446`) — Invariant 8's entire
  implementation.

Computed by WCAG 2.1 relative luminance against the void's real base from the shader
(`Void.metal:77-78`, which mixes `#030408`–`#070812`; `#05060d` used below):

| Surface | Contrast | AA (4.5 body / 3.0 large) |
|---|---|---|
| Text `#e8ecf6`, full opacity | **17.10:1** | Pass |
| Red `#e85c5c`, full opacity | **5.89:1** | Pass |
| Rail / badge, normal — white @ 0.30 | **2.33:1** | **Fail** |
| **Badge in production — red @ 0.30** | **1.46:1** | **Fail badly** |
| Rail while a pane is maximized (0.30 × 0.12) | **1.05:1** | Invisible |

Three consequences:

1. **The palette is fine; the plane treatment is what breaks it.** Every reserved hue
   passes AA at full opacity. The 0.30 multiplier destroys all of them.
2. **Production is the *least* legible state**, because red carries less luminance than
   white — 1.46:1 against 2.33:1. Invariant 8 says *"Production looks alarming."* At
   1.46:1 behind a 1.4pt blur it looks like nothing. The comment at
   `WakilWindow.swift:432-436` notices the tension and then concludes *"the plane
   treatment is orthogonal to it."* Opacity and blur are not orthogonal to legibility;
   they are the mechanism of it. That sentence is the reasoning error, and the room's red
   bleeds are doing all the work the badge is credited with.
3. **Maximized, the rail reaches 3.6% effective alpha.** The comment says it fades *"not
   to zero, which would read as a bug rather than as deference."* 1.05:1 is
   indistinguishable from zero, so it reads as exactly the bug it set out to avoid.

**This was observed before and never connected to a cause.** 2b-ii's visual review
recorded that production reads **"warm rather than alarming."** The arithmetic above is
why.

### It is not confined to the far plane

Nine of the fifteen text elements inside a data pane fail AA, on the slab's own `#0E1019`
(`Canvas.swift:310`):

| Element | file:line | size | α | ratio |
|---|---|---|---|---|
| **Footer — `read-only`, truncation and sort warnings** | `DataSurface.swift:1083,1096` | 9 | 0.35 | **2.9:1** |
| **`NULL`** — the distinction `:869-873` exists to make | `DataSurface.swift:872` | 12 | 0.30 | **2.4:1** |
| **`no rows`** | `DBPane.swift:117` | 12 | 0.30 | **2.4:1** |
| **Column type annotation** | `DataSurface.swift:320` | 9 mono | 0.25 | **2.1:1** |
| **Failure / refusal text (red)** | `DBPane.swift:83,94` | 10–12 | 0.75 | **3.6:1** |
| Column header, pane title, DB chooser, sort arrow | `DataSurface.swift:313`, `Canvas.swift:251`, `DBPane.swift:237`, `DataSurface.swift:328` | 7–9 | 0.45 | **4.0:1** |
| Edit-hover outline | `DataSurface.swift:832` | — | 0.30 | 2.4:1 (fails the 3:1 non-text floor) |

The footer carries **every honesty claim the surface makes** — `read-only`, *"more
matched than were returned"*, *"sorted by X within the N returned"*, *"this result cannot
be paged"* — at 2.9:1 in 9pt tracked caps. §8 is the best section in the design language,
and its conclusions are rendered at the threshold of visibility.

### The script, so these numbers can be argued with

```python
def lin(c):
    c /= 255.0
    return c/12.92 if c <= 0.04045 else ((c+0.055)/1.055)**2.4

def L(rgb):
    r, g, b = (lin(x) for x in rgb)
    return 0.2126*r + 0.7152*g + 0.0722*b

def ratio(a, b):
    la, lb = L(a), L(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)

def over(fg, alpha, bg):
    return tuple(alpha*f + (1-alpha)*b for f, b in zip(fg, bg))

void  = (5, 6, 13)      # Void.metal:77-78
slab  = (14, 16, 25)    # Canvas.swift:310
white = (232, 236, 246) # #e8ecf6
red   = (232, 92, 92)   # #e85c5c

ratio(over(red,   0.30,  void), void)   # 1.46  production badge
ratio(over(white, 0.30,  void), void)   # 2.33  rail, normal badge
ratio(over(white, 0.036, void), void)   # 1.05  rail, maximized
ratio(over(white, 0.35,  slab), slab)   # 2.94  footer
```

---

## H. The production trigger is a string equality test, inconsistent three ways

Three call sites normalise the environment name differently:

| Site | Normalisation |
|---|---|
| `VoidPalette.forEnvironment` (`VoidPalette.swift:55-56`) | `.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()` then `== "production"` |
| `WriteGate.isProduction` (`WriteGate.swift:101-104`) | `.lowercased() == "production"` — **no trim** |
| `WindowModel.setEnvironment` (`:1491`) | none; `WakilWindow.swift:452` feeds it a raw `TextField` |

Two consequences:

1. **`" production"` — with a leading space, typed or pasted — turns the room and badge
   red while the gate treats it as non-production**, offering a *confirmable* mutation
   instead of the outright block. That is precisely the disagreement
   `VoidPalette.swift:50-53` states is impossible: *"A treatment that disagreed with the
   gate about what production is would paint a safe-looking room around a refusal."* The
   inverse happens — an alarming room around a permitted write.
2. **`prod`, `prd` and `live` get no red room, no red badge, and no write block at all.**
   The repository's own documents use `"prod"` 11 times and `"live"` 4 times. Nothing
   warns an operator whose production environment is not spelled exactly `production`,
   and all three defences fail together on a single naming-convention mismatch.

The shared-palette design is right — the room and the gate should never disagree. The
implementation achieves agreement on the hue and not on the predicate.

---

## I. Discoverability — four recall interfaces, no recognition surface

`design-language.md:265`:

> Three ways to reach anything, all equivalent: the rail / a keystroke / ⌘P or ⌘K /
> voice.

That lists four, and *"all equivalent"* is not true — but the deeper problem is that
**none of the four is a recognition interface**:

- The rail *"answers 'what is open'"* (`:254`) — a switcher, not a launcher. At first run
  nothing is open, so it is empty at exactly the moment a new user needs it most.
  Confirmed in code: `Rail.swift:17` is a bare `List(model.layoutSnapshot.panes)` with no
  empty state and no placeholder.
- A keystroke requires knowing the keystroke.
- ⌘P/⌘K require knowing they exist, then typing a term you already know.
- Voice is push-to-talk with *"no separate object and no separate mic UI"* (`:312`) —
  nothing on screen indicates voice is a capability at all.

There is **no onboarding, no first-run, no empty state, no help content, and no shortcut
cheat-sheet** anywhere in the doctrine or the code. ⌘⇧D (density), ⌘T, ⌘B and ⌘⏎ are
reachable by no listed route.

And `design-language.md:282` deletes the one browsable surface a database tool has, with
the cause stated outright:

> The database pane has no schema browser and no sidebar, **and §1 is why.**

The replacement — *"a table list is one row per table… reached by the same actions as any
query"* — means that to learn what tables exist you must already know an action exists
that lists them.

**This is survivable if Wakil has exactly one user, who built it.** The charter's §2 says
*"Later, possibly: other developers."* Those two statements have not been reconciled, and
the reconciliation is a product decision, not a design one.

---

## J. Affordance at rest is largely absent

§1 bans the standard vocabulary of at-rest affordance — *"No window chrome, borders,
sidebars, or tab bars"* — and `design-language.md:36` adds *"No panel has a visible
outline."* Nothing replaces them.

| Affordance | Visible at rest? |
|---|---|
| Hover-revealed row actions (`:164`, `:285-287`) | **No, by name** |
| Sortable column headers (`:179`) | Never specified — no arrow, no header treatment, no hover state |
| Double-click-to-edit cell | **Absent from the design language entirely** |
| Resizable columns | Absent |
| Pane magnetism / snap (`:245-250`) | Feedback exists only *during* the drag |
| Far-plane promotion (`:61-62`) | **The promotion gesture is never defined** — unbuildable as written |

Cursor shape — the one channel §1 did not ban, and the cheapest — is never used as an
affordance signal in the document. In the code there is **exactly one cursor change**:
`NSCursor.resizeLeftRight` on the column-width handle (`DataSurface.swift:417-423`),
added *because* the walk found the drag unusable. The lesson was learned for that one
control and applied nowhere else — not to the pane resize handle (`Canvas.swift:298`, a
bare `Text("resize")` with a `DragGesture`), the pane drag body, the header sort target,
the drill button, the rail rows, the database chooser, or the page controls.

**Two things promised and not built:** the *"luminous left tick"* on the active rail row
is a literal pipe character (`Rail.swift:19`, `Text(... ? "|" : " ")`), and **the active
row's luminous left edge — promised by both the 2b-ii spec and `design-language.md` §8 —
does not exist**, recorded as an open spec/ship discrepancy in
`phase-2b-ii-acceptance.md`.

**The rail is mouse-only.** Its rows use `.onTapGesture` (`Rail.swift:27`) rather than a
`Button`: no keyboard focus, no Tab order, no VoiceOver action, no cursor change. The
same is true of column sort (`DataSurface.swift:336`), row and cell selection (`:632`,
`:796`), and opening the cell editor (`:762`, double-click only). A keyboard-only user
cannot operate the data surface at all — there is no arrow-key row movement anywhere, and
`onKeyPress` has **zero uses** in the codebase.

### Hit targets

| Control | file:line | Size |
|---|---|---|
| Column width handle | `DataSurface.swift:404-408` | **6pt wide** — a quarter of the 24pt minimum |
| Page ‹ / › | `DBPane.swift:304-315` | ~**7 × 14pt** (11pt glyph, `.plain`, no padding, no `contentShape`) |
| Drill "open" | `DataSurface.swift:603-612` | ~**30 × 11pt** |
| `Text("resize")` | `Canvas.swift:298-299` | ~45 × 16pt, no `contentShape`, no cursor, no visual affordance |
| Dense data rows | `Pane.swift:78` | 23pt — deliberate, documented, and defensible given the density toggle |

---

## K. Accessibility is seven call sites in one file

`grep -rc accessibility app/Sources` → **4 in `DataSurface.swift`, 3 in
`WindowModel.swift`, two of which are comments. Nothing anywhere else.**

| API | Uses |
|---|---|
| `.accessibilityLabel` / `.accessibilityElement` / `.accessibilityAddTraits` | 1 / 1 / 2 — all in `DataSurface.swift:334,633-635` |
| `.accessibilityValue`, `.accessibilityHint`, `accessibilityIdentifier` | **0** |
| `accessibilityReduceMotion`, `accessibilityReduceTransparency` | **0** |
| `@ScaledMetric`, `.dynamicTypeSize` | **0** |

Across `design-language.md`'s 445 lines, the terms *VoiceOver, accessibility, WCAG,
Dynamic Type, reduce motion, colour blindness, keyboard navigation, focus ring, tooltip,
onboarding, empty state* appear **zero times**. *"Contrast"* appears three times, never
as a number.

Specific consequences:

- **The confirmation plane has no accessibility labelling.** The one surface where
  misreading means an unintended database mutation is invisible to VoiceOver. So are the
  rail, the query line, the thought thread and the void.
- **No reduce-motion accommodation exists.** `VoidView.swift:62-63` sets `isPaused =
  false` and `enableSetNeedsDisplay = false`; the only thing that ever pauses the shader
  is window occlusion (`:274-276`). The rail, badge and thought thread slide ±8pt with
  every pointer move (`WakilWindow.swift:363-365`, `Plane.swift:46`) — cursor parallax is
  a vestibular trigger and is precisely what `prefers-reduced-motion` exists to disable.
  **2d's `speaking` state is a 0.42s pulse at 120fps — 2.4Hz full-field luminance
  modulation**, adjacent to photosensitivity guidance, with no guard. The design language
  flags the risk itself (§15: *"Whether a whole field in motion reads as calm rather than
  as a strobe is the open question underneath them"*) and §14 provides no switch.
- **Dead accessibility code.** `paneRowAccessibilityLabel` (`WindowModel.swift:546`) is
  the *tested* row-label function — two tests in `WindowModelTests.swift:843,851` — and
  **nothing calls it**. `DataSurface` uses a private duplicate (`:1025`) that `zip`s
  columns with cells and therefore **silently drops trailing columns on short rows**, the
  exact case the tested version was written to handle. Two tests guard a behaviour the
  shipping view does not have.
- **The hover-revealed drill button is not in the accessibility tree at all**
  (`DataSurface.swift:602`, gated on `hoveredRow`), so it is permanently unreachable by
  VoiceOver and by keyboard. The same is true of the editable-cell outline (`:828-856`),
  so a keyboard user has no way to discover which cells are editable — the only non-hover
  signal is the footer's `read-only` / `editable` word, at 2.9:1.
- **There is no loading state on a pane.** `Pane.busy` reaches only the rail's
  `Text(pane.busy ? "working" : "")` (`Rail.swift:22`) — an unlabelled word at 0.30
  opacity behind a 1.4pt blur, effectively invisible when maximized. Inside the pane:
  nothing. A slow query shows the previous result with no indication a new one is
  running. `Rail.swift:12-15` justifies this by *"the window is genuinely brief, because
  a layout action is an in-memory actor call"* — true for layout actions, false for
  `db_run_query`, which crosses MCP to a real database.
- **§14 Settings makes five things configurable** — *"STT engine default, theme, density
  default, keybindings, global behavior"* — and **none of them addresses motion, contrast
  or text size**. (`theme` is also vacuous: §15 says no light variant exists.) The
  undefined *"global behavior"* is the natural seam for a reduce-motion or contrast
  setting, and the document does not say so.

**One note against Decision 2**, which justified native macOS by *"best access to the
native-justifying APIs (on-device speech, TTS, global hotkeys, Keychain, menu bar)."*
Accessibility is the most native-only API surface there is, and it is the one that went
unused. To engineering's credit, VoiceOver row labels were built anyway and are checked
in `phase-2b-ii-acceptance.md:338-355` — but the design language never asked for them and
sets no standard anyone can be held to, so that is an accident that worked once rather
than a policy.

---

## L. Typography loads the aesthetic onto the least legible element

§6 is three lines. Verbatim:

> - **Micro-labels:** uppercase, `letter-spacing: .16–.22em`, **8–9.5px, low opacity.
>   These carry most of the futuristic feel.**

- **8–9.5px is below every platform floor.** Apple's HIG floor for legible text is 11pt;
  8px uppercase is roughly a 6px x-height. Wide tracking at that size degrades word-shape
  recognition, which is the main mechanism for reading small text — so the tracking makes
  it worse, not better.
- **"Low opacity" is never quantified anywhere**, and 0.30 is demonstrably in this
  design's vocabulary (`Plane.far`). At 0.30 the contrast is 2.33:1 at a ~6px x-height.
- **No font weight is stated anywhere in the document.**
- The document says these labels *"carry most of the futuristic feel"* — the least
  legible element is assigned the most aesthetic load.

All sizes are fixed px/pt, so Dynamic Type is structurally excluded — and §13
hard-commits to it: *"a SwiftUI `LazyVStack` of **fixed-height rows** holds **23.0000
pt/row exactly**."* Fixed row height is load-bearing for the performance budget, so the
120fps target and any future text scaling are in direct conflict. That trade-off is not
flagged anywhere.

---

## M. The confirmation plane — good, with five gaps

This is the safety-critical surface, and much of it is genuinely well made:

- **The statement is shown verbatim and unelided, scrolling rather than truncating**
  (`ConfirmationPlane.swift:13-15,51-57`): *"An operator confirming a statement they
  cannot entirely see is not confirming it."* At 13pt mono in a 520pt plane it soft-wraps
  and is never cut off.
- `.textSelection(.enabled)` — the operator can copy it.
- Focus is forced onto the typed field on appear (`:84`) with a documented reason:
  otherwise *"an operator who sees the plane and types 'confirm' would type it somewhere
  else entirely."*
- `affectsEveryRow` draws *"No WHERE clause — this affects every row."* in red (`:59-62`).
- It is deliberately not an `NSAlert`, with a stated technical reason.
- Authorship changes the wording and nothing else (`:39`), exactly as Decision 20 claims.

The gaps:

1. **A 120-second timeout exists and is completely invisible.**
   `ConfirmationBroker.swift:39` — `defaultTimeout = .seconds(120)`, armed at `:58-61`.
   The plane renders no countdown, no progress indicator, and no mention that a timeout
   exists. An operator reading a long `UPDATE` can have it vanish mid-read; what they get
   instead is a status line reading *"the confirmation expired — nothing ran"* in the
   unstyled `Text(model.status)` row.
2. **The environment name is drawn in destructive red unconditionally** (`:42-44`). On
   `staging` it renders identically to `production`, on the one surface where the
   distinction matters most — and it trains the operator to discount red, against §5's
   *"reserved semantics — never decorative, anywhere."*
3. **The destructive action is not visually distinguished.** `:71-72` is two
   default-chrome buttons — no `role: .destructive`, no `.tint(destructive)`, no
   prominence. The reserved red is spent on the border (`:78`) and the environment label,
   and none of it reaches the button that runs the `DELETE`. Cancel is declared first,
   which is correct macOS reading order, but Cancel is also the visually louder of the two
   because Run is greyed until the word is typed.
4. **Wrong-word feedback is silence.** `Run` is `.disabled(typed != "confirm")` with no
   explanation of why, and `.onSubmit(confirm)` (`:70`) is guarded downstream at
   `WindowModel.swift:1966`. Typing `Confirm` — capital C — and pressing Return does
   nothing at all: no error, no hint, no shake. The guard is correct; the absence of
   feedback is not.
5. **No focus ring.** Every field in the app is `.textFieldStyle(.plain)`; the only cue
   that the safety-critical field holds first responder is the caret.

### The shell around it

`AppScene.swift:200-208` replaces `.newItem` with an empty `CommandGroup`, which removes
the **entire File menu**. The complete menu bar is Wakil / Edit / Window / Help, with no
Help content, and **⌘P and ⌘K appear in no menu at all** — they exist only as
`.keyboardShortcut` on two in-window buttons (`WakilWindow.swift:472-475`). The app's two
primary entry points are undiscoverable through the one macOS affordance whose job is to
teach shortcuts.

### Error messages are raw by policy, with no actionable complement

All four `setFailure` call sites pass the driver's text verbatim
(`WindowModel.swift:1533,1545,1554,1676`), and the policy is stated deliberately at
`:1541-1544`: *"Wakil must not paraphrase an error it did not generate."* That is a
defensible honesty principle and this review does not argue with it. But it is applied
with no complement: there is no actionable layer on top, no retry affordance, no "the
database `docs` is not defined in this environment." The register exists elsewhere in the
same file — `:1392` produces *"no wakil-ctx client: org, project and environment are
unknown"*, and `:2854` produces *"the confirmation expired — nothing ran"* — it simply is
not used for query failures. Separately, `DBPane.swift:92-95` has no `.lineLimit`, so a
multi-line driver stack trace expands unbounded and squeezes the data surface out of the
pane.

### The `read-only` label is under-informative

`PaneEditable` is `nil` when the subject names no single table, **or** names no key,
**or** names no writable column (`PaneEditable.swift:143-146`) — three different
situations with three different remedies. `editabilityLabel` (`:105-107`) collapses all
three into one word, rendered at 2.9:1. The operator who double-clicks a cell and gets
nothing sees `read-only` and no reason. 2c-ii-b deliberately did not build the four
per-reason labels, and — to the project's credit — that call was made **on evidence**:
check 23 asked the operator directly and the answer was *"`read-only` alone is enough to
act on."* That is the right way to make the decision; it is worth re-asking once the
label is legible.

---

## N. Why the walks keep finding this: the UI has no tests and no visual baseline

- **`WakilApp` has no test target.** `app/Package.swift:25` declares only
  `.testTarget(name: "WakilKitTests", dependencies: ["WakilKit"])`. **All 4,358 lines of
  the view layer** — `DataSurface.swift` (1,138), `WakilWindow.swift` (579),
  `Canvas.swift` (382), `VoidView.swift` (356), `DBPane.swift` (319),
  `ConfirmationPlane.swift` (86) — are untested and untestable in CI. Four separate
  documents name this as the structural reason a defect of this shape has to be caught by
  an eye.
- **There are no snapshot or visual-regression tests**, and every screenshot the walks
  produce is written to `.context/`, which is **gitignored** (`.gitignore:2`). For a
  product whose differentiator is visual — a design language with reserved hues, four
  motion states and a Metal void — **there is no visual baseline anywhere in the
  repository**. A regression in the void's appearance is invisible to CI and to every
  future reader.
- The consequence is arithmetic: the human walk is the **only** UI instrument that
  exists. The charter's most-repeated lesson — *"a green suite is the floor and decides
  nothing above it"*, with 649 tests green at every point a defect was shipping — has a
  simple mechanical cause. **The suite covers 0% of the surface the walks test.**

A worked example of what that costs, from `phase-2c-ii-probe.md` §3: a per-pane
`.keyboardShortcut` is window-scoped and first-registered-wins, so *"Typing in `db-2` and
pressing ⌘↩ would run `db-1`'s query into `db-1` — silently, with both panes looking
plausible afterwards."* This was found by measurement, not by a test, and the fix — plain
`Return` via `.onSubmit`, plus a standing prohibition on per-pane shortcuts
(`DBPane.swift:162-208`, `DataSurface.swift:699-705`) — is exactly right. It is also
exactly the kind of thing that will regress silently the next time, for the same reason.

Also worth noting: `phase-2c-ii-b-acceptance.md` records D1, D2 and D3 as **fixed but
"unverified at the window"**, for this reason.

---

## O. What is strong, and must not be lost

Any cleanup that flattens the following makes the project worse, not better.

- **The honesty doctrine in §8 is better than most shipping products manage.** The
  sort-truncation admission, no-total paging, typed-only status chips, the dimmed `NULL`
  rather than an empty cell, and *"a control that returns a syntax error is worse than no
  control."* §8 designates itself *"the one place the aesthetic yields to utility"* and
  earns it.
- **Invariant 2 is enforced structurally, not by discipline.** `ActionDescriptor`
  (`Action.swift:106-111`) has **no `handler` member**, so `descriptor.handler` is a
  *compile error* rather than a permission error — `dispatch` is the only route that
  exists. `ContextStore.swift:24-34` records that `setProject`/`setEnvironment` were
  *deleted* from the store precisely because they were a second path.
- **Invariant 6's gate is an allowlist**, so DDL is refused by construction rather than by
  enumeration, with `TRUNCATE` argued explicitly rather than omitted; writability is
  *derived* from `WriteRef != ""` and never stored, so it cannot disagree with itself.
- **The charter records its own shortfalls rather than papering over them** — *"met by
  acceptance, not by an acceptance run"*, **ACCEPTED — not walked**, `D1` left
  deliberately unfixed with a reason, and *"a green suite is the floor and decides nothing
  above it."* The problem in Part 1 is location and volume, never candour.
- **2c-ii-b's checks 22 and 23 are the one place a suspected usability problem was put to
  the human and disconfirmed** — correctly causing four planned UI labels to stay
  unbuilt. That is the model worth repeating, and it is the answer to most of Part 2:
  ask the operator, record the answer, and let a disconfirmation stop work.

---

# Recorded debt — Invariant 1

Recorded here rather than resolved, at the operator's instruction. This entry states the
divergence and its cost; it does **not** choose between amending the charter and fixing
the code.

**The invariant** (`north-star.md:60-62`):

> **Agent-agnostic core.** Nothing outside the harness adapter knows Claude exists.
> Abstraction is at the *harness* level (loop, tools, context management) — not the model
> level.

**Decision 4's claim** (`north-star.md:~160`):

> The provider model stores the bundle as **opaque harness-owned data so Invariant 1
> holds**.

**What the code does.** It stores it transparently, in the layer §2 singles out as the
one that *"must stay headless and provider-agnostic, so the shell is replaceable"*:

| Site | What leaks |
|---|---|
| `internal/wakilcore/provider.go:35` | ``ClaudePath string `json:"claudePath,omitempty"` `` — a Claude-named field on the core provider record |
| `internal/wakilcore/provider.go:48` | `ProviderKindClaudeCode = "claude-code"` |
| `internal/wakilcore/provider.go:101-126` | `AddProvider` branches on Claude-specific `configDir` semantics; user-facing text names `CLAUDE_CONFIG_DIR` |
| `internal/wakilcore/sessions.go:214-219` | `providerSessionsRoot` hard-codes Claude Code's on-disk layout |
| `app/Sources/WakilKit/App/WindowModel.swift:609-618` | `ProviderCredentials` carries `claudePath` across the whole app |
| `app/Sources/WakilKit/App/ProviderCredentialsLookup.swift:29,38,43` | the `Wire` type mirrors it |
| `cmd/wakil/providercmd.go:68-71` | `--claude-path`, `--config-dir (the CLAUDE_CONFIG_DIR…)` |

**The asymmetry that makes this debt rather than a defect.** `sessions.go:204-207`
already argues its own exception, and argues it well: *"this reads Claude Code's own
on-disk layout, which is not a leak of the wrong abstraction but the honest shape of the
problem."* Session discovery genuinely cannot be provider-agnostic — it is reading
another program's files. **No comparable argument exists for `ClaudePath` being a field
on the record** rather than a key inside the opaque bundle Decision 4 describes.

**What it forecloses.** A Codex provider, or a local endpoint, is *describable* by the
core today but not *servable* by it: the record has a field only one harness can
interpret, and `providerSessionsRoot` will look for a directory only one harness writes.
Decision 16 says a second provider needs *"`baseURL` and `authToken` on the `Provider`
record… and two more conditional keys"* in `buildLaunch` — which is accurate as far as it
goes, and which would add two more harness-specific fields to the same record rather than
removing the one already there.

**Two honest routes, neither chosen here.**
- *Amend* — extend `sessions.go`'s argument to cover `ClaudePath`, and soften Decision 4's
  "opaque" to say the core knows one harness's credential shape. Cheapest; lowers the bar
  rather than meeting it.
- *Fix* — move `ClaudePath` into the opaque bundle and put `providerSessionsRoot` behind a
  harness-owned interface. This is a code change of real size and belongs in a phase, not
  in a documentation pass.

Also verified, and **not** debt: `provider.go` has no `BaseURL`/`AuthToken` fields, so
Decision 16's *"deliberately not built yet"* is accurate; and `buildLaunch`'s environment
whitelist is still exactly `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`, `HOME`, `PATH`
(`ClaudeCodeCLIHarness.swift:113-119`), built from a literal rather than filtered — so
`ANTHROPIC_API_KEY` cannot shadow a subscription by construction, exactly as claimed.

---

# Remediation menu — unexecuted, costed

Nothing below has been done. Ordered by value per hour, not by severity.

### Do first (~1 hour)

- **Force dark appearance** — `NSRequiresAquaSystemAppearance` in
  `scripts/make-app-bundle.sh`'s plist, or `.preferredColorScheme(.dark)` on the scene —
  **or** give every unstyled `Text` an explicit colour token. One line against §F0, the
  worst finding in this document. The second form is the better investment if §15's
  light-environment variant is ever wanted.

### Cheap and high-value (~half a day)

- Exempt the environment badge from `Plane.far`'s 0.30 opacity and 1.4 blur, or raise
  both for it specifically (§G). Invariant 8 is currently met by the shader, not the
  label.
- Trim in `WriteGate.isProduction`, and match a configurable set rather than one literal
  (§H). Consider warning when an environment name looks production-like but is not.
- Raise the text opacity floor on the slab: 0.25–0.35 → roughly 0.62 at 9pt to reach
  4.5:1. Worst offenders are the footer, `NULL`, `no rows` and the type annotation (§G).
- Quantify *"low opacity"* in `design-language.md` §6 and state a contrast floor.
- Give the rail an empty state, and make its rows `Button`s rather than `.onTapGesture`
  (§I, §J) — one line, and currently the only keyboard-free way to reach an off-canvas
  pane.
- Show the 120-second timeout on the confirmation plane; give `Run` destructive styling;
  make the environment colour conditional (§M).
- Delete or wire up `paneRowAccessibilityLabel` (§K) — two tests currently guard a
  behaviour the shipping view does not have.

### Charter correctness (~1 hour)

- Correct Decision 21's two premises (§A1) — the cost argument needs rewriting, not just
  the facts.
- Fix the mis-citations: the invented §8 rule (§A5), `design-language.md`'s "Invariant
  10" (§A5), the "§1–13" ordinal (§A5), Decision 17's Claude-account ghost-text (§A3).
- Update Invariant 4's tense — the second half arrived (§D).
- Fix Phase 3's `code-server` line against Decision 17 (§D).
- Resolve the `2d` label collision (§D).
- Repair the five mid-sentence paragraphs (§C5).
- Correct `org-and-provider-model.md:140-148`'s `CurrentOrg` block (§D).

### Governance (~2 hours)

- Promote the production block to an invariant (§A2), or state why it is not one.
- Amend Invariant 5 for the multi-org model, or reject the spec's claim to bindingness
  (§B3). Either is fine; the current state — a binding spec against an unamended
  invariant — is not.
- Record the undeclared Invariant 2 carve-out, or remove it from `design-language.md`
  (§A4).
- Close Q4, Q10, Q12 and Q13; re-target Q6 and Q8 away from a shipped phase (§D).
- Add a *Reverse if* to Decision 9 in particular, or mark it explicitly irreversible
  (§B2).

### Structural (~1 day and up)

- **A `WakilApp` test target and committed snapshot baselines, including a Light Mode
  pass** (§N). This is the single change that would alter the defect curve, and it is the
  reason §F0 and §G went unseen.
- A keyboard path into the grid — `onKeyPress` on the `surfaceFocused` anchor that
  already exists (`DataSurface.swift:166`) and currently consumes nothing (§J).
- An accessibility pass, starting with the confirmation plane (§K).
- A reduce-motion setting under §14's undefined *"global behavior"*, gating at minimum the
  0.42s speaking pulse and the cursor parallax (§K).
- Split the charter: `north-star.md` back to roughly 2,500 words (§1–5, §9, a one-line
  decision index carrying each call and its reversal condition, and a status-only phase
  table), with `docs/wakil/decisions/` one file per decision, `docs/wakil/phase-log.md`
  for the walk narratives, and `docs/wakil/open-questions.md` with one section per
  question (§C). This touches cross-references in every phase document, which is why it
  is last.

---

## Reproducing the measurements in this document

```
wc -w docs/wakil/north-star.md                                    # 11,795
grep -rn "forces you to leave\|earns its place" --include=*.md docs \
  | grep -v north-star-and-design-review                            # 1 hit: the definition
grep -rc accessibility app/Sources                                # 4 + 3, two files
grep -rn "ReduceMotion\|ScaledMetric\|dynamicTypeSize" app/Sources # empty
grep -rln "import Security" app/Sources                           # empty
grep -i "integer\|fidelity" docs/wakil/north-star.md              # empty
grep -ci "look like it can" docs/wakil/design-language.md         # 0
find . -name '*.plist' -not -path './.git/*'                      # none
grep -rn "preferredColorScheme\|NSRequiresAquaSystemAppearance\|NSAppearance" app/Sources
                                                                  # empty
```

Growth series: walk `git log --format=%h --reverse -- docs/wakil/north-star.md` and run
`wc -w` on each revision. Contrast ratios: the script in §G, against `Void.metal:77-78`
and `Canvas.swift:310`. Defect counts: the §4/§5 sections of the six acceptance
documents.
