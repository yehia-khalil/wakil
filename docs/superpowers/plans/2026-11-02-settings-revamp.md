# Settings revamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Regroup the settings tree by scope and bring every settings page except a project's Running page onto one vocabulary, one set of tokens and the nine Interaction Rules.

**Architecture:** Pure decisions (the node list, breadcrumbs, tree keyboard moves, ink contrast) move into `WakilKit/Panes/` where they can be tested; `WakilApp` only draws. The one new capability, setting an environment's production flag, follows the `ctx_rename_environment` path: `wakilcore` → `wakil-ctx` tool → operator-only Swift action → `WindowModel` → the settings pane.

**Tech Stack:** Swift 6 / SwiftUI (macOS), Swift Testing, Go (`internal/wakilcore`, `cmd/wakil-ctx`), the repo's JSONL e2e checks.

**Spec:** `docs/superpowers/specs/2026-11-02-settings-revamp-design.md`

## Global Constraints

- Never touch `RunningSettingsForm.swift`, the Running row, its label or its identifiers.
- `SettingsSection` keeps its optional `identifier:` parameter and `.fixedSize` title as on `yehia-khalil/workspaces-5-crews`; every `SettingsForm.swift` change is source-compatible with that branch.
- Every existing `settings.*` accessibility identifier and `identifierFragment` value stays, except the Organisation `….save` / `….revert` buttons that fix 3 removes.
- No `.lineLimit(1)`, `.truncationMode` or clipping on any settings text; ask "3× longer?" of every label touched.
- Colours by §5: destructive `#e85c5c`, healthy/staging `#8be0c8`, caution `#e8b45a`, luminance `#7c5cff`.
- Read text ≥ 4.5:1 against the void's lightest stop `#070812`.
- No confirmation, refusal, Enter-to-commit or jump is added without naming its Rule.
- Commits carry no `Co-Authored-By` or "Generated with" lines.
- Build/test commands: `make build`, `make test` (Go + docs-check), `make app-test` (Swift; run `make build` first when Go changed).

## Review Focus

1. **An org with a long display name** (60+ characters): the org heading in the tree and the breadcrumb wrap whole; nothing is clipped. → Task 9's narrow-frame e2e check.
2. **An environment whose flag was never declared, named `production`**: the dot is red, the choice reads "From the name", and choosing No overrides it and the dot turns green. → Task 1 and Task 7 tests.
3. **A `wakil-ctx` older than this branch** (no `production`/`productionDeclared` in the tree): no dot, the Production row reads "—" and its choice is held, not crashing. → Task 2 decode test.
4. **Leaving an Organisation field with a value the save refuses** (an invalid Jira site): the refusal shows whole under the field, the typed text stays, and leaving again without editing does not resend it. → Task 6 test.
5. **Typing in the tree while a field elsewhere has focus**: type-to-find never steals the keys from a focused text field. → Task 4 wiring step's e2e check.

---

### Task 1: `wakilcore` sets an environment's production flag

**Files:**
- Modify: `internal/wakilcore/envlife.go` (after `RenameEnvironment`)
- Modify: `internal/wakilcore/configtree.go:205-215, 440` (tree environment gains the declared flag)
- Modify: `cmd/wakil-ctx/main.go` (beside `rename_environment`, ~line 1425)
- Test: `internal/wakilcore/envlife_test.go`, `cmd/wakil-ctx/schema_test.go:114, 204`, `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Produces: `func SetEnvironmentProduction(projectPath, name string, production *bool) error`; tree JSON field `productionDeclared` (`*bool`, omitted when nil) beside the existing `production`; MCP tool `set_environment_production` with arguments `projectPath` (string), `name` (string), `production` (`"yes"`, `"no"` or `"name"`).

- [ ] **Step 1: Write the failing tests** in `envlife_test.go`:
  - `TestSetEnvironmentProductionDeclaresAndClears`: on a project with environment `live`, set `&true` → reloaded `Environments["live"].Production` is `&true` and `EnvironmentIsProduction("live", env)` is true; set `&false` on an environment named `production` → `EnvironmentIsProduction` false; set `nil` → `Production == nil` and the name rule answers again.
  - `TestSetEnvironmentProductionRefusesAnUnknownEnvironment`: error text `no environment "qa" in project "<name>"`.
  - In `configtree` tests: an environment with `Production: &false` named `production` emits `"production":false,"productionDeclared":false`; one with nil emits no `productionDeclared`.
- [ ] **Step 2: Run** `go test ./internal/wakilcore/ -run 'SetEnvironmentProduction|ConfigTree'` — expect FAIL (undefined).
- [ ] **Step 3: Implement** `SetEnvironmentProduction` with `loadOwnProject` → lookup (same refusal wording as `RenameEnvironment`) → assign `env.Production` → `SaveProject`. Add `ProductionDeclared *bool \`json:"productionDeclared,omitempty"\`` to the tree environment and fill it from `environment.Production` at line 440.
- [ ] **Step 4: Add the tool** `set_environment_production` in `cmd/wakil-ctx/main.go` mapping `"yes"`/`"no"`/`"name"` to `&true`/`&false`/`nil`, anything else a `UserError` ("production must be yes, no or name"). Add it to both lists in `schema_test.go` (`{"projectPath", "name", "production"}`) and a `main_test.go` round trip like `TestRenameEnvironmentRefusalReachesTheWireVerbatim`.
- [ ] **Step 5: Run** `make build && make test` — expect PASS.
- [ ] **Step 6: Commit** `wakil-ctx: set_environment_production — declare an environment production or not, or let its name decide (Rule 9)`.

### Task 2: The operator-only Swift action and the tree field

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (after `ctx_rename_environment`, ~line 1404)
- Modify: `app/Sources/WakilKit/MCP/PermissionPrompt.swift:122, 295`
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift:598-620`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (beside `renameEnvironment`, ~line 4173)
- Test: `app/Tests/WakilKitTests/SettingsEnvironmentProductionTests.swift`, `ActionClassificationTests` pinned list

**Interfaces:**
- Consumes: Task 1's tool `set_environment_production`.
- Produces: action `ctx_set_environment_production` (`.control`, `.operatorOnly`, params `project`, `projectPath`, `name`, `production`); `SettingsEnvironment.productionDeclared: Bool?`; `WindowModel.setEnvironmentProduction(project: String, projectPath: String, environment: String, to: Bool?) async -> String?` (nil on success, the refusal sentence otherwise).

- [ ] **Step 1: Write the failing tests**: `anEnvironmentDecodesItsDeclaredFlag` (`"productionDeclared":false` → `false`), `anUndeclaredFlagDecodesNil`; add `ctx_set_environment_production` to `theClassificationLeavesTodaysReachabilityExactlyAsItWas`.
- [ ] **Step 2: Run** `make app-test` — expect FAIL.
- [ ] **Step 3: Implement** the field (decoded with `decodeIfPresent`), the action modelled on `ctx_rename_environment` including `refuseIfAgentRuns`, its two `PermissionPrompt` lists, and the `WindowModel` method that calls it and re-reads the tree. Operator-only because what counts as production sets the agent's price (an agent must not lower it).
- [ ] **Step 4: Run** `make app-test` — expect PASS.
- [ ] **Step 5: Commit** `settings: ctx_set_environment_production, operator-only`.

### Task 3: The node list moves into WakilKit, regrouped by scope

**Files:**
- Create: `app/Sources/WakilKit/Panes/SettingsNode.swift` (moved from `SettingsPane.swift:2938-3030`, made `public`)
- Modify: `app/Sources/WakilApp/SettingsPane.swift` (remove the moved enum)
- Test: `app/Tests/WakilKitTests/SettingsNodeTests.swift`

**Interfaces:**
- Produces: `public enum SettingsNode` with new cases `.quickTasks`, `.browsingData`, `.speech` (fragments `quickTasks`, `browsingData`, `speech`); `public var label: String` (`.providers` → `"Accounts"`, `.organisation` → `"Organisation"`); `public enum SettingsScope { case wakil, organisation, projects }` and `public static func topLevel(_ scope: SettingsScope) -> [SettingsNode]` returning `[.editor, .browser, .keyboard]` and `[.organisation, .providers, .quickTasks, .browsingData, .speech]`; `breadcrumb(in:)` unchanged in signature.

- [ ] **Step 1: Write the failing tests**: fragments of every old case unchanged (`providers`, `organisation`, `editor`, `browser`, `keyboard`, `projectEditor.x`, `project.x`, `environment.x.y`, `databases.x.y`, `api.x.y`); new fragments as above; `topLevel` lists as above; breadcrumbs `[org, "Accounts"]`, `[org, "Quick tasks"]`, `[org, "Browsing data"]`, `[org, "Speech"]`, `["Wakil", "Browser"]`, `.organisation` → `[org]`.
- [ ] **Step 2: Run** `make app-test` — FAIL.
- [ ] **Step 3: Move and extend** the enum; `renaming(...)` comes along unchanged.
- [ ] **Step 4: Run** `make app-test` — PASS; `make app-bundle` builds `WakilApp`.
- [ ] **Step 5: Commit** `settings: SettingsNode in WakilKit; Accounts, Quick tasks, Browsing data and Speech as org nodes`.

### Task 4: Tree keyboard — ↑/↓, type-to-find, Esc keeps

**Files:**
- Create: `app/Sources/WakilKit/Panes/SettingsTreeKeys.swift`
- Modify: `app/Sources/WakilApp/SettingsPane.swift:491, 592-610` (`treeKey`) and the confirmation views (`confirmButton` callers)
- Test: `app/Tests/WakilKitTests/SettingsTreeKeysTests.swift`; e2e `e2e/checks/seeded/settings-tree-keys.jsonl`

**Interfaces:**
- Produces: `public enum SettingsTreeKeys { static func step<N: Hashable>(_ rows: [N], from: N?, by: Int) -> N?; static func find<N: Hashable>(_ rows: [(node: N, label: String)], prefix: String, after: N?) -> N? }`; `public struct TypeAhead { mutating func append(_ c: Character, at: Date) -> String }` with a 1 s reset.

- [ ] **Step 1: Write the failing tests**: `step` clamps at both ends (no wrap), from nil goes to the first row; `find` is case- and diacritic-insensitive, starts after the current row and wraps once, returns nil when nothing matches; `TypeAhead` gives `"st"` for s,t within 1 s and `"t"` when t comes 1.1 s later.
- [ ] **Step 2: Run** `make app-test` — FAIL.
- [ ] **Step 3: Implement** both, then wire `treeKey`: ↑/↓ step through visible selectable rows (headings excluded, the list the tree already builds); a printable key with no modifiers feeds `TypeAhead` and selects `find`'s result; neither opens a branch (Rule 6). Key handling stays on the tree's focus, so a focused field elsewhere keeps its keys. Esc while a destroy confirmation is showing presses its Keep it.
- [ ] **Step 4: Write the e2e check** `settings-tree-keys.jsonl`: focus the tree, ↓ twice selects the third row (`expect.focus`), type `ke` selects `settings.tree.keyboard`, Esc on the remove-environment confirmation leaves `settings.environment.remove` present. Run `make e2e-run E2E_FILES=e2e/checks/seeded/settings-tree-keys.jsonl` (ask the operator for the screen first).
- [ ] **Step 5: Commit** `settings: the tree answers ↑/↓ and type-to-find; Esc keeps`.

### Task 5: The tree drawn by scope, and the pages split

**Files:**
- Modify: `app/Sources/WakilApp/SettingsPane.swift:410-480` (tree), `:983-1070` (`subject`), `:1369-1410` (`speechRow`)
- Modify: `app/Sources/WakilApp/BrowserSettingsForm.swift:90-230` (browsing data and passwords leave)
- Create: `app/Sources/WakilApp/BrowsingDataSettingsForm.swift`
- Modify: e2e checks that reach moved controls (Step 4)

**Interfaces:**
- Consumes: `SettingsNode.topLevel`, `.label`, new cases (Task 3); `SettingsEnvironment.production` (Task 2).

- [ ] **Step 1: Draw the tree**: headings `WAKIL`, the org label uppercased, `PROJECTS`, each in the PROJECTS heading's existing style; WAKIL and the org heading have no chevron. Inside an open project, after Editor and Running, a micro `ENVIRONMENTS` label at depth 2 (not selectable, identifier `settings.tree.project.<p>.environmentsHeading`); each environment row gets a 6pt dot before its label — `#e85c5c` when `production == true`, `#8be0c8` when `false`, none when nil.
- [ ] **Step 2: Split the pages** in `subject`: Organisation = Identity · Connections · Git · Agent instructions (Default and Speech leave its Accounts section, which goes); Accounts (`.providers`) = Accounts table · Local models · a "Default account" row (`organisationEditor(.defaultProvider, …)`, same identifier); Quick tasks = `quickTasksRow` with its About button as a one-group page (rows without header); Browsing data = `BrowsingDataSettingsForm` holding the clear-data control and `BrowserPasswordsSettings` in sections "Clear" and "Passwords", identifiers unchanged; Speech = `speechRow` as a one-group page.
- [ ] **Step 3: Build** `make app-bundle`, open Settings, select each node; expect each page as listed and the Browser page holding search, tabs and picture in picture only.
- [ ] **Step 4: Update e2e checks**: `grep -rl` in `e2e/checks` for `settings.browser.clear`, `settings.browser.passwords`, `settings.quickTasks.`, `settings.org.quickProvider.`, `settings.org.speechProvider.`, `settings.org.defaultProvider`; in each, the click that reaches the page before them becomes `settings.tree.browsingData`, `settings.tree.quickTasks`, `settings.tree.speech` or `settings.tree.providers`. Run those checks with `make e2e-run` (operator's screen permitting).
- [ ] **Step 5: Commit** `settings: the tree by scope — WAKIL, the organisation, PROJECTS with ENVIRONMENTS; Accounts, Quick tasks, Browsing data and Speech pages`.

### Task 6: Organisation fields save on leave

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:3317` (`savesOnLeave`)
- Modify: `app/Sources/WakilApp/SettingsPane.swift:1300-1330` (`organisationEditor`: Save/Revert go)
- Modify: `e2e/checks/seeded/2e-settings-organisation.jsonl`
- Test: `app/Tests/WakilKitTests/LeaveSavedFieldTests.swift:83`

- [ ] **Step 1: Change the test** `onlyTheGitFieldsOfTheOrganisationSaveWhenLeft` → `everyOrganisationFieldSavesWhenLeft`: `leaving == WindowModel.OrganisationField.allCases.filter { $0 != .speechProvider }` (Speech is a choice, saved on press). Add `aRefusedOrganisationFieldKeepsItsText`: after a refused leave of `.jiraBase` with draft `"not a url"`, the draft is still `"not a url"` and `LeaveSave.value` returns nil for the same draft.
- [ ] **Step 2: Run** `make app-test` — FAIL.
- [ ] **Step 3: Implement**: `savesOnLeave` true for every field but `.speechProvider`; remove the Save and Revert buttons; Return still saves (Rule 2 allows, never requires it).
- [ ] **Step 4: Update** `2e-settings-organisation.jsonl`: replace each `click …save` with a `do.key` Tab (leave) and expect the stored value; drop `…revert` steps. Run it.
- [ ] **Step 5: Commit** `settings: the organisation's fields save when left; Save and Revert go (Rule 2)`.

### Task 7: The environment page — Production row, Databases and API as sections

**Files:**
- Modify: `app/Sources/WakilApp/SettingsPane.swift` environment subject (~line 1150-1180), databases (~2672), API (~3425)
- Create: `app/Sources/WakilKit/Panes/SettingsProductionChoice.swift`
- Test: `app/Tests/WakilKitTests/SettingsEnvironmentProductionTests.swift`

**Interfaces:**
- Consumes: `WindowModel.setEnvironmentProduction` (Task 2), `productionDeclared`.
- Produces: `public enum SettingsProductionChoice: String, CaseIterable { case no = "No", yes = "Yes", fromName = "From the name" }`, `static func current(declared: Bool?) -> Self`, `var declared: Bool?`, `static func hint(declared: Bool?, production: Bool?) -> String?` → `"From the name: production."` / `"From the name: not production."` when undeclared, nil when declared.

- [ ] **Step 1: Write the failing tests**: `current(declared: nil) == .fromName`, `true → .yes`, `false → .no`; `.fromName.declared == nil`; hint for `(nil, true)` and `(nil, false)` as above, `(false, false)` nil, `(nil, nil)` nil.
- [ ] **Step 2: Run** `make app-test` — FAIL.
- [ ] **Step 3: Implement** and draw a "Production" `SettingsRow` with `SegmentedChoice(options: SettingsProductionChoice.allCases.map(\.rawValue), …, identifier: "settings.environment.production")`, the hint as `FormHint` under it, in-flight shown as other choices do (Rule 5), the refusal under it whole (Rule 8). Databases and API: each entry a `SettingsSection` headed by its name, its fields `SettingsRow` + `inPlaceField`; API stays read-only; `FormCard` leaves both. Keep all existing `settings.databases.*` / `settings.api.*` identifiers.
- [ ] **Step 4: e2e** `e2e/checks/seeded/settings-environment-production.jsonl`: on seeded `production`, the segment reads "From the name" and the tree dot is red; press No → dot green; press From the name → red again. Run it.
- [ ] **Step 5: Commit** `settings: an environment's Production row (Rule 9); databases and API drawn in sections`.

### Task 8: Ink, destructive tone, spacing and radii tokens

**Files:**
- Create: `app/Sources/WakilKit/Panes/SettingsInk.swift`
- Modify: `app/Sources/WakilApp/SettingsForm.swift:30-65, 333-356`, and every settings file using a literal `.opacity(` on text, a literal spacing or `cornerRadius:`
- Test: `app/Tests/WakilKitTests/SettingsInkTests.swift`

**Interfaces:**
- Produces: `public enum SettingsInk { static let primary = 0.86, secondary = 0.62, tertiary = 0.40, disabled = 0.32; static func contrast(opacity: Double) -> Double }` (coolWhite `#e8ecf6` composited over `#070812`, WCAG relative luminance); `SettingsPalette.destructive = #e85c5c`; `SettingsScale.radiusField = 5`, `radiusSlab = 10`; `FormButton.destructive(_ title:identifier:filled:action:)`.

- [ ] **Step 1: Write the failing tests**: `contrast(opacity: 1)` ≈ 15.9 (±0.2); `contrast(opacity: SettingsInk.secondary) >= 4.5`; `contrast(opacity: SettingsInk.primary) >= 7`.
- [ ] **Step 2: Run** `make app-test` — FAIL.
- [ ] **Step 3: Implement** `SettingsInk`, then replace text opacities across settings: body/values primary, labels/headers/breadcrumb/hints/footnotes/`—` secondary, hairlines and glyphs tertiary, disabled disabled. Spacing literals map to `SettingsScale` (`gutter`, `columnGap`, `sectionGap`, `openGap`, `fieldGap`, plus `tight = 4` and `stack = 6` if needed). Radii map to the two tokens.
- [ ] **Step 4: One removal control**: every Remove/Delete/Clear trigger (`rowAction` at :3182, :3190, :3234, :3348; passwords Delete; clear data; project and environment remove) and every destroy confirm (`confirmButton` :855, :3516, browser clear confirm) uses `SettingsPalette.destructive` — trigger unfilled, confirm filled. Amber stays only on refusals and cautions. `grep -rn "caution" app/Sources/WakilApp/*Settings* app/Sources/WakilApp/SettingsPane.swift` shows no destroy control.
- [ ] **Step 5: Run** `make app-test && make app-bundle`; screenshot each page to `.scratch/settings-revamp/` and check no text reads dimmer than the breadcrumb.
- [ ] **Step 6: Commit** `settings: four ink steps at ≥4.5:1, one red removal control, spacing and radius tokens`.

### Task 9: No text cut

**Files:**
- Modify: every `.lineLimit(1)` / `.truncationMode` in `SettingsPane.swift`, `SettingsForm.swift` (`SettingsValue` ~:543), `BrowserPasswordsSettings.swift`, `QuickTaskSettingsForms.swift`, `EditorSettingsForms.swift`, `KeyboardSettingsForm.swift`, `BrowserSettingsForm.swift`
- Test: e2e `e2e/checks/seeded/settings-long-text.jsonl`

- [ ] **Step 1: Write the e2e check** with a seeded org display name of 64 characters, a project of 48, a local model URL of 120: at `do.resize` 640×600 the tree row, breadcrumb and URL each `expect.frame` within the pane and their full text is the element's value. Run — FAIL (cut).
- [ ] **Step 2: Remove** every cut; each text gets `.fixedSize(horizontal: false, vertical: true)`; a value that cannot sit beside its label goes `underRowValue()`; the breadcrumb is a wrapping flow of segments.
- [ ] **Step 3: Verify** `grep -rn "lineLimit(1)\|truncationMode" app/Sources/WakilApp/Settings*.swift app/Sources/WakilApp/*SettingsForm*.swift app/Sources/WakilApp/BrowserPasswordsSettings.swift` prints nothing (the Running form excluded); run the check — PASS.
- [ ] **Step 4: Commit** `settings: no text is cut — long names wrap whole`.

### Task 10: Off/On order, the Model choice, and §14

**Files:**
- Modify: `app/Sources/WakilApp/BrowserSettingsForm.swift` (picture in picture options), `SettingsPane.swift:1425-1450` (Model)
- Modify: `docs/wakil/design-language.md` §14

- [ ] **Step 1: Off/On**: every two-way `SegmentedChoice` in settings lists Off then On; identifiers unchanged.
- [ ] **Step 2: Model**: count options on the seeded org; when accounts + local models + "Same as agent" exceed what fits at 640pt (they do as soon as one local model is added), keep the `Menu` and record it in §14 as the one exception, with the reason (an open-ended list).
- [ ] **Step 3: Amend §14** (dated 2026-11-02): the tree from the spec; page sections — Organisation is Identity · Connections · Git · Agent instructions; Accounts is Accounts · Local models · Default account; Quick tasks, Browsing data and Speech are org pages; an environment page is Production, then a section per database and per API entry; Speech is per-org (Invariant 11), its line moves from the Wakil row to the Organization row of the table; `SettingsInk`, `destructive` and the radius tokens join the vocabulary paragraph.
- [ ] **Step 4: Run** `make test` (docs-check) — PASS.
- [ ] **Step 5: Commit** `settings: Off before On everywhere; §14 amended for the revamp`.

---

After Task 10: the Cover rung — the e2e auditor reads the branch and reports what it could not cover (`docs/agents/e2e.md`) — then the operator's walk.
