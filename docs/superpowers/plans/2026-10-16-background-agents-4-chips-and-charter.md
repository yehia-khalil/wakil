# Background agents, Plan 4 of 4: the chips, and the charter

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator sees every agent in another place as a chip in the top-right of the window
and can go there with one click. The charter, decisions, glossary and design language record what
the background-agents work changed.

**Architecture:** WakilKit derives the chips from `WindowModel.agents` (Plan 3). That makes the
chip list a tested value, `WindowModel.chips: [AgentChip]`. `PlaceAgent` gains the two facts the
model cannot yet tell: whether a finished result is still unseen, and whether the session failed.
`WindowModel.goTo(_:)` composes the existing operator switches (org, then project, then
environment). WakilApp draws `AgentChips` from `chips`, so the view decides nothing.

**Tech Stack:** Swift 6 / Swift Testing (WakilKit), SwiftUI (WakilApp, no test target, covered by
the e2e auditor), Markdown.

**Spec:** `docs/superpowers/specs/2026-10-16-background-agents-design.md`, *What the operator gets* §2
*The chips*, *The chips (WakilApp)*, *Charter changes this sub-phase makes*, and the Interaction
Rules table. Plans 1–3 are on the branches below.

## Global Constraints

- **One chip per agent whose place is not the place on screen**, in one of four states:

  | State | When | Hue (`design-language.md` §5) | Text suffix |
  |---|---|---|---|
  | `.working` | turn in flight | violet `#7c5cff`, breathing on the Core's thinking rhythm | none |
  | `.waiting` | its place has a parked proposal (`waitingPlaces`) | amber `#e8b45a` | ` — waiting` |
  | `.done` | finished while off screen and not yet seen | green `#8be0c8` | ` — done` |
  | `.failed` | the session failed while off screen and not yet seen | red `#e85c5c` | ` — failed` |

  Precedence is `waiting` > `failed` > `working` > `done`. An agent that is idle and seen has
  no chip.
- **Chip text** is `<org> · <project> · <environment>`, with empty members left out. The
  environment segment of a production place is drawn in production red (Invariant 8),
  whatever the state hue.
- **Visiting a place** (it becomes the place on screen) clears its `done`/`failed`.
- **Interaction Rules.**
  - Rule 6: nothing moves the operator; only a click on a chip goes there.
  - Rule 5: the chips are work in flight shown off screen.
  - Rule 4: a waiting chip leads to its plane, where Cancel is.
  - Rule 1: a chip click asks nothing.
- **No agents elsewhere means no chips.** The window's resting state is unchanged.
- **Charter word limit.** `make test`'s docs-check limits `north-star.md` to 4000 words, and it is
  4026 at the base. The charter edits must leave it **at or under 4000**. The documented remedy is
  moving dated history into `decisions.md`; Invariant 5's parentheticals move into Decision 41.
- Commits carry no `Co-Authored-By` or "Generated with" lines. Run `make shaders build` before
  `make app-test`. If a full run hangs, run `sample` first, then `rm -rf app/.build` and rerun.

## Review Focus

1. **Two agents finish off screen, and the operator visits one.** Expected: that one's chip
   disappears and the other stays green. *(Task 1, `visitingAPlaceClearsOnlyItsChip`.)*
2. **An agent that is waiting and was also working.** Expected: amber wins. *(Task 1,
   `aWaitingAgentShowsAmberWhateverElseIsTrue`.)*
3. **A chip for a place in another org.** Expected: clicking it switches org, project and
   environment in that order and lands on that place. *(Task 1,
   `goToReachesAPlaceInAnotherOrg`.)*
4. **A production place's chip.** Expected: its environment segment is marked production.
   *(Task 1, `aProductionPlacesChipMarksItsEnvironment`.)*
5. **The charter after the edits.** Expected: `make test`'s docs-check passes. *(Task 3, Step 3.)*

---

### Task 1: the chips' model

**Files:**
- Create: `app/Sources/WakilKit/App/AgentChip.swift`
- Modify: `app/Sources/WakilKit/App/PlaceAgent.swift`: add `unseenResult: Bool` and
  `unseenFailure: Bool`.
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`:
  - the event pump sets `unseenResult` on `.result`, and `unseenFailure` on a harness error or
    process exit, whenever the agent's place is not the screen's
  - activating a place clears both for it
  - add `chips` and `goTo(_:)`
- Test: create `app/Tests/WakilKitTests/AgentChipTests.swift`, and update `InvalidationContractTests.swift`

**Interfaces:**
- Produces: `public struct AgentChip: Identifiable, Equatable, Sendable { public enum State {
  case working, waiting, done, failed }; public let place: Place; public let state: State; public
  let label: String; public let productionEnvironment: Bool; public var id: Place { place } }`.
- Produces: `WindowModel.chips: [AgentChip]`, computed. It has one entry per agent whose place
  differs from `place`, follows the state rules above, and is ordered stably by
  `(organization, project, environment)`.
- Produces: `WindowModel.goTo(_ target: Place) async`. It uses the operator's own switches:
  `requestOrganizationSwitch` if the org differs, then `setProject` if the project differs,
  then `setEnvironment` if the environment differs. It stops at the first refusal and leaves
  that refusal in `status`.
- `productionEnvironment` comes from the agent's place's production flags (`PlaceContexts`, or
  the name rule when they can't be read). Precompute it when the chip state changes, so `chips`
  stays synchronous.

- [ ] **Step 1: Write the failing tests**
  - `noAgentsElsewhereMeansNoChips`
  - `aWorkingAgentElsewhereIsAVioletChip`: state `.working`, with label
    `"initech · api · staging"`.
  - `aWaitingAgentShowsAmberWhateverElseIsTrue`: a turn in flight and a parked proposal give
    `.waiting`.
  - `aResultOffScreenIsDoneUntilVisited` and `visitingAPlaceClearsOnlyItsChip`.
  - `aFailedSessionOffScreenIsAFailedChip`.
  - `theScreensOwnAgentHasNoChip`.
  - `aProductionPlacesChipMarksItsEnvironment`.
  - `goToReachesAPlaceInAnotherOrg` and `goToStopsAtTheFirstRefusal`.

- [ ] **Step 2: Run them and see them fail**

  Run: `cd app && swift test --filter AgentChipTests`
  Expected: the build fails.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run the Swift suite**

  Run: `make app-test`
  Expected: PASS.

- [ ] **Step 5: Commit** with the message `Chips: the model of every agent in another place`.

### Task 2: the chips

**Files:**
- Create: `app/Sources/WakilApp/AgentChips.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`. Overlay the chips top-trailing, in the
  window's chrome layer, above the canvas and below any plane. Don't place them inside the
  `ContextLine` `VStack`.

**Interfaces:**
- Consumes: `WindowModel.chips` and `goTo(_:)` (Task 1).
- Each chip is a `Button` whose action is `Task { await model.goTo(chip.place) }`. It has a
  capsule with a hairline border and the `design-language.md` §5 hue dot, and the label in the
  window's small text style.
- The production environment segment is drawn in production red.
- The working dot breathes on the Core's thinking turnover, reusing the existing timing
  constant from `VoidView`/`Capture` rather than a new number.
- Accessibility: `accessibilityLabel("<label>, <state word>")`, with the state words
  `working`, `waiting on you`, `done` and `failed`.
- With reduced motion turned on, the dot does not breathe.

- [ ] **Step 1: Build.** Run `make app-build` and expect it to compile cleanly. (WakilApp has no
  unit tests. The e2e auditor covers this view after the plan.)
- [ ] **Step 2: Capture.** If the repo's capture target can render a window state seeded with
  chips (`make captures`; read the Makefile target first), add one capture for
  "two chips: working and waiting" and save the image to `.scratch/background-work/`. If it can't
  without new infrastructure, say so in the report.
- [ ] **Step 3: Commit** with the message `Chips: one per agent in another place, top right; a click goes there`.

### Task 3: the charter, decisions, glossary and design language

**Files:**
- Modify: `docs/wakil/decisions.md`. Add Decision 41, numbered after 39 (Decision 40 is
  reserved by the 3b-iii spec). It records the operator's decisions in the spec's *Decisions*
  section, plus the rulings that changed behaviour:
  - an agent's calls always go to its own place
  - an agent's proposals never expire
  - the org switch asks nothing about unsaved tabs
  - the environment is part of the place and of the layout scope
  - a legacy layout file is a read-only seed

  Include a "reverse if" line, and move Invariant 5's two dated parentheticals here.
- Modify: `docs/wakil/north-star.md`:
  - Invariant 5 becomes: **Exactly one place on screen; each agent keeps its own.** Implicit
    scope is the product. An explicit project argument on every tool call would forfeit it, and
    an agent never follows the operator's place. History: Decision 41.
  - Add the §6 index row `| 41 | One agent per place; each keeps its place; switching tears
    nothing down | … |`.
  - Glossary: add **Place**. Amend **Active context** to "the place on screen; an agent resolves
    against its own place". Amend **Layout scope** to include the environment.
- Modify: `docs/wakil/design-language.md`. Amend §1 for the chips: the first always-on chrome
  outside the context line, justified because it exists only while there is work elsewhere. Add
  their hue table, a pointer to Task 2's view, and the date.
- Modify: the spec's *Open questions* (`docs/superpowers/specs/2026-10-16-background-agents-design.md`),
  noting that the phase-map placement is still open.

- [ ] **Step 1: Write the edits.**
- [ ] **Step 2: Check the cross-references.** Run `grep -n "Decision 41" docs -r`. Expect the
  decisions entry, the charter row and the Invariant 5 pointer.
- [ ] **Step 3: Run the charter's word check**

  Run: `make docs-check`
  Expected: `north-star.md: N/4000 words` with N ≤ 4000.
- [ ] **Step 4: Commit** with the message `Charter: one agent per place — Decision 41, Invariant 5, glossary, design language`.

### After Task 3

The e2e auditor (`docs/agents/e2e.md`) owes these checks, which cover all four plans:
- Start an agent in place A, switch org, start an agent in B, then return through A's chip. A's
  thread shows its work, and the journal has both agents' entries.
- A's chip shows working, then done, and disappears on the visit.
- The retrodictions "a switch retargets a running agent" and "a chip that moves the operator
  unasked" go red.
