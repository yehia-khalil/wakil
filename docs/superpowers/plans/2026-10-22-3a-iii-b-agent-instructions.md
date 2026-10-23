# 3a-iii-b Agent Instructions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator writes agent instructions per organisation (General, Commits, Pull requests) and per project (the same three); the agent receives them after Wakil's own rules, from its next turn, and the ✨ draft uses the Commits texts.

**Architecture:** Go stores the texts on the `Org` record and in `project.json`; a pure WakilKit function composes the appended prompt; the agent harness passes `agentSystemPrompt` plus that text to `--append-system-prompt`; a saved edit marks live agents stale, and before an agent's next turn the window forks its session (`--resume … --fork-session`, Decision 12) with the new text.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-ctx`), Swift 6 / SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-22-3a-iii-git-accounts-and-remotes-design.md`, part 4 ("Agent instructions"), items 11–15 and calls 7–8. Parts 1–3 are `2026-10-22-3a-iii-a-remote-git.md`.

## Global Constraints

- Org fields: `AgentGeneral`, `GitCommitInstructions`, `GitPRInstructions` (`json:"agentGeneral|gitCommitInstructions|gitPRInstructions,omitempty"`). Project field: `Agent *ProjectAgentInstructions` (`json:"agent,omitempty"`) with `General`, `Commits`, `PullRequests` (`json:"general|commits|pullRequests,omitempty"`).
- Headings in the appended text, exactly: `## Organisation <org> — general`, `## Organisation <org> — commits`, `## Organisation <org> — pull requests`, `## Project <project> — general`, `## Project <project> — commits`, `## Project <project> — pull requests`. Order: org general, commits, pull requests, then project's three. Empty texts and their headings are omitted.
- The thread line after a refresh, exactly: `Instructions updated — the agent has the new ones from this turn.`
- Size hint past 2,000 words per box: `Long instructions ride on every turn the agent takes`. Nothing is refused.
- Identifiers: `settings.org.agent.general`, `settings.org.git.commits`, `settings.org.git.pullRequests`, `settings.project.agent.general`, `settings.project.agent.commits`, `settings.project.agent.pullRequests`.
- Public repository: example names only in committed text.

## Rulings

- **R1 — The refresh is a fork.** Every resume in Wakil is a fork (`buildLaunch`: `--resume <parent> --fork-session`), so the refreshed agent runs under a new session id with recorded lineage, and the thread continues. Cost if wrong: none; Decision 12 already requires it.
- **R2 — Stale means "a live agent whose place's org or project texts changed since its launch".** The window keeps the composed text each agent was launched with; a save recomposes and compares. Cost if wrong: one extra fork.

## Review Focus

1. **A turn in flight when the operator saves** — the running turn is untouched; the fork happens before the next one. Test in Task 4.
2. **Two places of the same organisation, one with a live agent and one idle** — only the live one is marked stale; the idle one simply launches with the new text. Test in Task 4.
3. **A box cleared to empty** — its heading disappears from the next launch. Test in Task 3.
4. **Instructions that look like Wakil's own rules** — they come after Wakil's, never replace them. Test in Task 3.
5. **An org switch with a stale agent elsewhere** — the background agent keeps its place and is refreshed before its own next turn. Test in Task 4.

---

### Task 1: Probe — does a forked session take a changed `--append-system-prompt`?

**Files:** Create `docs/wakil/3a-iii-instructions-probe.md`.

- [ ] **Step 1: Measure** with the real `claude` CLI on this Mac (`--print`, a throwaway config dir): start a session with `--append-system-prompt "Answer every message with the word ALPHA."`; send "hello"; then `--resume <id> --fork-session --session-id <new>` with `--append-system-prompt "Answer every message with the word BRAVO."`; send "hello". Record both replies, the CLI version, and whether the forked transcript holds the first turn.
- [ ] **Step 2: Rule.** BRAVO and the history kept → the plan stands. Otherwise stop: amend the spec (item 15) before Task 4 — edits apply to the next conversation and New conversation becomes this phase's dependency.
- [ ] **Step 3: Commit** `3a-iii-b: probe — a forked session takes a new appended prompt`.

### Task 2: Go — the texts on the organisation and the project

**Files:**
- Modify: `internal/wakilcore/org.go`, `orgupdate.go` (`OrgPatch` gains the three `*string`), `configtree.go` (`ConfigTreeOrg` and each `ConfigTreeProject` return them), `config.go` (`Project.Agent`)
- Create: `internal/wakilcore/projectagent.go` (`UpdateProjectAgentInstructions(projectPath string, p ProjectAgentPatch) error`, read-modify-write like `UpdateProjectEditorSettings`)
- Modify: `cmd/wakil-ctx/main.go` (`update_org` takes the three; `set_project_agent_instructions`), `StandardActions.swift` (`ctx_update_org` forwards the three strings; `ctx_set_project_agent_instructions` operator-only), `SettingsTree.swift`
- Test: `internal/wakilcore/projectagent_test.go`, `orgupdate_test.go`, `app/Tests/WakilKitTests/EditorSettingsTests.swift`

- [ ] **Step 1: Write the failing tests**: `TestUpdateOrgSetsTheAgentTexts` (and `""` clears); `TestProjectAgentInstructionsRoundTrip` (other `project.json` fields untouched); `TestConfigTreeCarriesTheTexts`; Swift `theAgentTextsAreForwarded`.
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'AgentTexts|ProjectAgent|ConfigTreeCarries'` and the Swift filter. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./...` and the Swift filter. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-b: agent instructions on the organisation and the project`.

### Task 3: Composing the prompt, the launch, and the ✨ draft

**Files:**
- Modify: `app/Sources/WakilKit/Harness/AgentInstructions.swift` (`public struct AgentTexts: Sendable, Equatable { general, commits, pullRequests: String }`; `public func agentInstructions(org: String, orgTexts: AgentTexts, project: String?, projectTexts: AgentTexts?) -> String`)
- Modify: `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift` (`buildLaunch` gains `appendedInstructions: String = ""`, passed as `agentSystemPrompt + "\n\n" + appendedInstructions` when non-empty; the convenience init takes `appendedInstructions: @Sendable () -> String`, read at each launch)
- Modify: `app/Sources/WakilApp/WindowSession.swift` (the factory reads the place's org and project texts from `config_tree`)
- Modify: `app/Sources/WakilKit/App/CommitDraft.swift` (`request(…, commitInstructions: String)`: appended to the instructions under `Follow these commit rules:`), `WindowModel+CommitDraft.swift` (passes org then project Commits)
- Test: `app/Tests/WakilKitTests/AgentInstructionsTests.swift`, `ClaudeCodeCLIHarnessTests.swift`, `CommitDraftTests.swift`

- [ ] **Step 1: Write the failing tests**: `composesOrgThenProjectUnderTheirHeadings` (exact headings); `emptyTextsAndTheirHeadingsAreOmitted`; `nothingAtAllComposesEmpty`; `theLaunchAppendsAfterWakilsOwnRules` (the `--append-system-prompt` value starts with `agentSystemPrompt`); `theDraftCarriesTheCommitRules`.
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'AgentInstructionsTests|ClaudeCodeCLIHarnessTests|CommitDraftTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make app-test`. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-b: the agent and the draft receive the instructions`.

### Task 4: From the next turn — the update rides in the next message

> **Amended after Task 1's probe (2026-10-22):** a resumed session ignores a new appended prompt, so
> nothing is forked. `refreshInstructionsIfStale(place:)` instead returns the block
> `[Wakil: the operator updated your instructions. They replace any earlier ones under the same
> headings.]\n\n<composed text>`, which the send path puts before the operator's words in that
> turn's input (not in the thread's display of them), then records the composed text as
> `launchedInstructions`. Tests below read "the turn's input starts with the block" where they say
> "the second launch has `--resume`".

**Files:**
- Create: `app/Sources/WakilKit/App/WindowModel+AgentInstructions.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`PlaceAgent` keeps `launchedInstructions: String`; the send path calls `refreshInstructionsIfStale(place:)` before a turn), `InvalidationContractTests.swift`
- Test: `app/Tests/WakilKitTests/WindowModelAgentInstructionsTests.swift`

**Interfaces:**
- Produces: `func markAgentsStale(org: String, project: String?)` (after a save); `func refreshInstructionsIfStale(place: Place) async` (no-op without a live agent, while a turn is in flight, or when the composed text equals `launchedInstructions`; otherwise forks the session through the resume path with the new text and appends the thread line).

- [ ] **Step 1: Write the failing tests** with a recording harness factory: `aSaveForksTheLiveAgentBeforeItsNextTurn` (the second launch has `--resume <old> --fork-session` and the new text; the thread line exact); `aTurnInFlightIsNotInterrupted` (Review Focus 1); `anIdleAgentIsNotForkedJustLaunchedWithTheText` (Review Focus 2); `anUnchangedTextForksNothing`; `aBackgroundAgentIsRefreshedBeforeItsOwnNextTurn` (Review Focus 5).
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter WindowModelAgentInstructionsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make app-test`. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-b: instruction edits apply from the agent's next turn`.

### Task 5: WakilApp — the boxes

**Files:** `app/Sources/WakilApp/SettingsPane.swift` — Organisation page: a new **AGENT** section with **General**; the **GIT** section gains **Commits** and **Pull requests**; the Project page (2e-ii's) gains **AGENT** with the three. Multi-line, saved when left (Rule 2), placeholder examples (`Imperative subject under 72 characters; reference the ticket key`), the size hint past 2,000 words, identifiers from Global Constraints.

- [ ] **Step 1: Implement**, saving through `saveOrganisationField` (three new `OrganisationField` cases) and a new `saveProjectAgentInstructions(project:path:_:)`, then `markAgentsStale`.
- [ ] **Step 2: Run** `make app-bundle` and `go test ./e2e/driver -run TestEveryAuditedControlIsNamed`. Expected: builds; no new unnamed control.
- [ ] **Step 3: Commit** `3a-iii-b: the instruction boxes in Settings`.

### Task 6: Charter records

**Files:** `docs/wakil/decisions.md` (Decision 45), `north-star.md` (3a-iii's §8 wording names agent instructions).

- [ ] **Step 1: Edit**; run `scripts/public-check.sh` on the changed files. Expected: no hits.
- [ ] **Step 2: Commit** `3a-iii-b: charter records`.

**After the plan:** `superpowers:requesting-code-review`, Cover (an e2e check: write a project's General text, then read the next launch's arguments from the scripted agent's record), and the runbook's instruction rows in `docs/wakil/phase-3a-iii-acceptance.md`.
