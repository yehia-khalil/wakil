# 2e-iii: API entries and databases edited from Settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add, edit and remove an environment's API entries from Settings (the token to the
Keychain), and edit a database in place (rename, remove write access) with removal confirmed.

**Architecture:** `internal/wakilcore` gets three API-entry writers and one database editor, each
a read-modify-write of `project.json` through `SaveProject`. `wakil-ctx` exposes four tools;
WakilKit registers four `.control`, operator-only actions and four window methods. The Settings
API page becomes the database page's twin (sections + an add-or-replace card), and both pages
get in-place fields (`LeaveSavedField`) and a pane-local **Remove** / **Keep it**.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-ctx`); Swift 6 / SwiftUI (WakilKit,
WakilApp); the e2e harness (`e2e/checks/seeded/*.jsonl`).

**Spec:** `docs/superpowers/specs/2026-10-22-2e-iii-api-entries-design.md`

## Global Constraints

- Every write reads `project.json` from disk at dispatch and saves through `SaveProject`; a
  project whose `org` isn't the current org is refused with the existing "a row stored in another
  organisation is read-only here" sentence (Invariant 4, Decision 21).
- A refused write writes nothing — no Keychain item, no file change.
- Keychain ref for an API token: `api:<project>:<environment>:<name>` (`ApiRef`). With a token, the
  Keychain is written before the file (`SetDatabaseDSN`'s order).
- No Keychain item is ever deleted; no secret is ever read back into the page or a tool result.
- Base URL validated and stored through `NormalizeHTTPBase`; auth header through
  `ValidateAuthHeader`; names through `ValidName` (2e-ii). Refusal text is theirs, whole.
- The four actions are `kind: .control`, `audience: .operatorOnly`, no price, and in
  `operatorOnlyActions` (Decision 30). `api_set_entry` has `secretParams: ["token"]`.
- Confirmation copy, exact:
  - token: `Store a token for <name> in <environment>? It goes to your Keychain, not to the project file.` with **Store it** / **Cancel**;
  - API entry removal: `Remove <name> from <environment>? Its Keychain item is kept.`;
  - database removal: `Remove <name> from <environment>? Its Keychain entries are kept.`;
  both removals with **Remove** / **Keep it**.
- Identifiers (spec, verbatim): `settings.api.<name>.name`, `.baseUrl`, `.authHeader`,
  `.replaceToken`, `.token`, `.clearToken`, `.remove`, `.remove.confirm`, `.remove.keep`;
  card `settings.api.name`, `settings.api.baseUrl`, `settings.api.authHeader`,
  `settings.api.token`, `settings.api.save`, `settings.apiToken.confirm`,
  `settings.apiToken.cancel`; databases `settings.db.<name>.name`, `.replaceConnection`,
  `.revokeWrite`, and `.remove` gaining `.remove.confirm` / `.remove.keep`.
- No new `wakil` CLI verbs. No commit carries `Co-Authored-By` or a "Generated with" line.

## Review Focus

1. **Saving the card with an empty token over an entry that has one:** the entry keeps its
   `authRef`; nothing is written to the Keychain. Pinned in Task 1.
2. **An `http://` base URL, or one with `user:pass@`:** refused with `NormalizeHTTPBase`'s sentence,
   and the Keychain is not touched even when a token was typed. Pinned in Task 1.
3. **Renaming an entry the active environment's open API pane is pointed at:** the pane follows the
   new name and still sends with the same credential. Pinned in Task 4.
4. **Renaming a database or entry onto a name the environment already has:** refused, naming the
   clash; the field keeps the typed name. Pinned in Tasks 1, 2 and the e2e in Task 6.
5. **A hand-written `authRef` (`legacy-token`) edited through the page:** kept through base URL,
   header and rename edits; replaced only by storing a token. Pinned in Task 1.

---

### Task 1: Go — API entry writers

**Files:**
- Create: `internal/wakilcore/apiwrite.go`, `internal/wakilcore/apiwrite_test.go`

**Interfaces:**
- Produces:
  - `func ApiRef(project, environment, name string) string`
  - `type ApiEntryRequest struct { ProjectPath, Environment, Name, BaseURL, AuthHeader, Token string }`
  - `func SetApiEntry(r ApiEntryRequest) error` — add, or replace by name.
  - `type ApiEntryEdit struct { NewName, BaseURL, AuthHeader *string; ClearToken bool }`
  - `func UpdateApiEntry(projectPath, environment, name string, edit ApiEntryEdit) error`
  - `func RemoveApiEntry(projectPath, environment, name string) error`

- [ ] **Step 1: Write the failing tests** (use `fakeKeychain(t)`, `projectFixture`, `CreateOrg` as `projectwrite_test.go` does):
  - `TestSetApiEntryStoresTheTokenInTheKeychainNotTheFile`: token `Bearer s3cret` → file has
    `authRef == "api:shop:staging:orders-api"`, file bytes don't contain `s3cret`,
    `SecretGetFor("acme", that ref) == "Bearer s3cret"`; baseUrl `https://api.example.com/` stored
    as `https://api.example.com`.
  - `TestSetApiEntryWithoutATokenKeepsAuthRef`: entry with `authRef:"legacy-token"`, replace with
    new base URL and empty token → `authRef` still `legacy-token`, no Keychain write.
  - `TestSetApiEntryRefusesAndWritesNothing`: table over `http://x`, `https://u:p@x`,
    `https://x/?q=1`, authHeader `Host`, name `""`, name `a/b` → error; file bytes unchanged;
    no Keychain item at the derived ref.
  - `TestUpdateApiEntryEditsOnlyWhatIsSet`: rename `orders-api`→`orders`, keeps `baseUrl`,
    `authHeader` and `authRef` (`legacy-token` kept, Review Focus 5); rename onto an existing name
    refused naming it; `ClearToken` drops `authRef` and the Keychain item stays readable.
  - `TestRemoveApiEntryKeepsTheKeychainItem`; and another-org project refused for all three.

- [ ] **Step 2: Run** `go test ./internal/wakilcore/ -run 'ApiEntry'` — FAIL (undefined).

- [ ] **Step 3: Implement** in `apiwrite.go`, following `SetDatabaseDSN`'s shape: validate all
  inputs → load (`loadOwnProject` from 2e-ii) → find environment (refuse when absent) → Keychain
  (token only) → mutate `Environment.API` → `SaveProject`. Unknown environment / entry refusals
  read `no environment "x" in project "y"` / `no API entry "x" in environment "y"`.

- [ ] **Step 4: Run** `go test ./internal/wakilcore/` — PASS.

- [ ] **Step 5: Commit** `2e-iii: API entry writers — the token to the Keychain, never the file`

### Task 2: Go — database edit in place

**Files:**
- Modify: `internal/wakilcore/projectwrite.go` (beside `RemoveDatabase`)
- Test: `internal/wakilcore/projectwrite_test.go`

**Interfaces:**
- Produces: `type DatabaseEdit struct { NewName *string; RevokeWrite bool }`,
  `func UpdateDatabase(projectPath, environment, name string, edit DatabaseEdit) error`

- [ ] **Step 1: Write the failing tests:** `TestUpdateDatabaseRenameKeepsItsRefs` (`ref` and
  `writeRef` unchanged after `core`→`orders`); clash refused naming `orders`; `ValidName`
  refusals; `TestRevokeWriteKeepsTheKeychainEntry` (`writeRef` empty, `SecretGetFor` at the old
  write ref still answers); another-org refused.
- [ ] **Step 2: Run** `go test ./internal/wakilcore/ -run 'UpdateDatabase|RevokeWrite'` — FAIL.
- [ ] **Step 3: Implement** `UpdateDatabase` with the same load/refuse/save shape as `RemoveDatabase`.
- [ ] **Step 4: Run** `go test ./internal/wakilcore/` — PASS.
- [ ] **Step 5: Commit** `2e-iii: a database renamed or its write access removed, its Keychain entries kept`

### Task 3: wakil-ctx — four tools

**Files:**
- Modify: `cmd/wakil-ctx/main.go` (after `remove_database`), `cmd/wakil-ctx/schema_test.go`
- Test: `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Consumes: Task 1 and 2 functions.
- Produces tools (args JSON names exact):
  - `set_api_entry {projectPath, environment, name, baseUrl, authHeader?, token?}`
  - `update_api_entry {projectPath, environment, name, newName?, baseUrl?, authHeader?, clearToken?}` — absent means unchanged (pointer fields).
  - `remove_api_entry {projectPath, environment, name}`
  - `update_database {projectPath, environment, name, newName?, revokeWrite?}`
  All answer an empty object; refusals via `toolErr`.

- [ ] **Step 1: Write the failing test** `TestApiEntryToolsRoundTrip`: set (no token) → `config_tree`
  shows the entry with `baseUrl`; update `newName` → listed under the new name; remove → gone.
  `TestUpdateDatabaseToolRenames`. Add the four names to `schema_test.go`'s expected list.
- [ ] **Step 2: Run** `go test ./cmd/wakil-ctx/` — FAIL.
- [ ] **Step 3: Implement** the four `mcp.AddTool` registrations; descriptions say the token goes to
  the Keychain, Keychain items are kept, and project of another org is refused.
- [ ] **Step 4: Run** `go test ./cmd/wakil-ctx/ ./internal/wakilcore/` — PASS.
- [ ] **Step 5: Commit** `2e-iii: wakil-ctx set/update/remove_api_entry and update_database`

### Task 4: WakilKit — four actions and the window methods

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (after `db_remove_database`),
  `app/Sources/WakilKit/Core/Action.swift` (`operatorOnlyActions`),
  `app/Sources/WakilKit/App/WindowModel.swift` (beside `removeDatabase`),
  `app/Sources/WakilKit/Api/PaneStore+Api.swift`, `app/Sources/WakilKit/Panes/SettingsTree.swift`
- Test: `app/Tests/WakilKitTests/ActionClassificationTests.swift`, `AppWiringTests.swift`,
  `JournalRedactionTests.swift`; Create `app/Tests/WakilKitTests/WindowModelApiEntryTests.swift`

**Interfaces:**
- Consumes: Task 3's tools.
- Produces:
  - actions `api_set_entry`, `api_update_entry`, `api_remove_entry`, `db_update_database`
    (params = the tool's, forwarded as-is; `callChecked` as `db_remove_database` does).
  - `WindowModel`:
    - `setApiEntry(projectPath:environment:name:baseUrl:authHeader:token:) async -> String?`
    - `updateApiEntry(projectPath:environment:name:newName:baseUrl:authHeader:clearToken:) async -> String?` (optionals: nil = unchanged)
    - `removeApiEntry(projectPath:environment:name:) async -> String?`
    - `updateDatabase(projectPath:environment:name:newName:revokeWrite:) async -> String?`
    Each answers the refusal whole or nil, and calls `refreshSettings()` either way.
  - `PaneStore.renameApiEntry(from: String, to: String)` — active scope's api panes whose
    `draft.entry == from` get `to`.
  - `SettingsAPI.authHeader: String` (decoded, default `""`).

- [ ] **Step 1: Write the failing tests:**
  - classification/wiring lists include the four names; all four `.operatorOnly`.
  - redaction: `api_set_entry` journals `token` as `[redacted]`.
  - `WindowModelApiEntryTests`: with a fake `ToolCaller` (pattern of
    `WindowModelProjectLifecycleTests`), `updateApiEntry(newName:)` on the active project and
    environment re-points an open api pane's draft from `orders-api` to `orders` and triggers a
    re-resolve (`list_apis` called after the write); on another environment it re-points nothing;
    a refused write returns the tool's text and re-points nothing.
  - `SettingsTree` decodes `authHeader`.
- [ ] **Step 2: Run** `make app-test` — FAIL.
- [ ] **Step 3: Implement.** After a successful API write whose `(project path, environment)` is the
  window's active place: on rename call `panes.renameApiEntry`, then `apiResolver?.reresolve(environment:)`.
- [ ] **Step 4: Run** `make app-test` — PASS.
- [ ] **Step 5: Commit** `2e-iii: four operator-only actions; an API rename re-points the open panes`

### Task 5: Settings pane — the API page and the database rows

**Files:**
- Modify: `app/Sources/WakilApp/SettingsPane.swift`, `app/Sources/WakilApp/Canvas.swift`
  (closures, as `removeDatabase` is wired), `app/Sources/WakilApp/SettingsNameField.swift` if a
  generic in-place field is extracted from `LifecycleNameField`.

**Interfaces:**
- Consumes: Task 4's window methods; 2e-ii's `LeaveSavedField`, `confirmButton`,
  `confirmingRemoval`, `FormCard`, `LabelledField`.

- [ ] **Step 1: API page.** Per entry a `SettingsSection(name)` with in-place **Name**, **Base URL**,
  **Auth header** (prompt `Authorization`) saved on leave; **Token** row: `in Keychain (<authRef>)`
  or `none`; **Replace token** (masked field + the token confirmation); **Clear token** (no
  confirmation — nothing destroyed); **Remove** with the removal confirmation. Below, the
  `ADD OR REPLACE AN API ENTRY` `FormCard` (NAME, BASE URL, AUTH HEADER, TOKEN masked); **Save**
  disabled until NAME and BASE URL are filled; with a token it asks first; cleared on success,
  kept on refusal. Delete the read-only note and its comment. Two entries sharing a name (a hand edit) are both drawn, with the caution note
  `two API entries are named <name>; edits act on the first`.
- [ ] **Step 2: Database rows.** In-place **Name**; **Replace connection** fills the existing card's
  name and driver and scrolls to it; **Remove write access** when `writable`; **Remove** now asks
  (replace the "No confirmation, and that is a ruling" comment with the new ruling).
- [ ] **Step 3: Build and test:** `make app-build && make app-test` — PASS; `make controls` shows no
  new failure (the pre-existing `EditorColumn.swift:753` one may remain).
- [ ] **Step 4: Commit** `2e-iii: Settings — API entries editable, databases edited in place, removals confirmed`

### Task 6: e2e, runbook, charter

**Files:**
- Create: `e2e/checks/seeded/2e-iii-api-entries.jsonl`, `e2e/checks/seeded/2e-iii-database-edit.jsonl`,
  `docs/wakil/phase-2e-iii-acceptance.md`
- Modify: `e2e/checks/uncoverable.tsv`, `docs/wakil/decisions.md` (Decision 21 note),
  `PRODUCT.md` (one line under Settings)

- [ ] **Step 1: Checks** (follow `2e-ii-project-lifecycle.jsonl`'s style; the seeded fixture's
  `e2e-project`): add an entry with no token via the card; edit its base URL and leave by a tree
  click; refuse `http://insecure.example` and auth header `Host` (assert the sentence and the
  field's `Value:`); rename it; remove with `.remove.keep` then `.remove` + `.remove.confirm`.
  Database: rename by leaving the field, a clash refused, **Remove write access**, remove with
  keep-then-confirm. Each of the four actions dispatched once too, for parity, or an
  `uncoverable.tsv` line saying why (as 2e-ii's).
- [ ] **Step 2: Runbook** with the setup block (a `walk-2e-iii` project in `personal`, `staging`
  with one database) and rows only for what checks can't drive: store a token and see the
  confirmation; send a request from the API pane with it; `security find-generic-password -s
  wakil:personal:api:walk-2e-iii:staging:orders-api -w` prints it; replace and clear; an agent
  asked to add an entry says it can't.
- [ ] **Step 3: Charter:** Decision 21 note (2026-10-22: API entries in the pane, superseding the
  "read-only, and stay so" code comment; database rename/revoke and confirmed removal); PRODUCT.md
  line. `make docs-check` shows no new failure.
- [ ] **Step 4: Commit** `2e-iii: e2e checks, runbook and charter`. The on-screen run waits for the operator's go.
