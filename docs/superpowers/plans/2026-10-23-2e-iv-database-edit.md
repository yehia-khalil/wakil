# 2e-iv: edit a database's connection in Settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A database's non-secret connection parts live in `project.json` and only its password in
the Keychain, so **Edit** (replacing **Replace connection**) fills everything but the password.

**Architecture:** Go owns building a connection string from `connection` + password
(`BuildConnectionString`), used by the resolver at connect time for split records; legacy records
(no `connection`) are read whole as today. A new writer `SetDatabaseConnection` behind a new tool and
an operator-only action replaces the card's DSN write. The Settings card gains an edit mode.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-ctx`); Swift 6 / SwiftUI (WakilKit, WakilApp);
e2e harness.

**Spec:** `docs/superpowers/specs/2026-10-23-2e-iv-database-edit-design.md`

## Global Constraints

- Server drivers are `mysql` and `mongo`; `sqlite` is a file. Formats exactly as today: mysql
  `user:pass@tcp(host:port)/db`; mongo `mongodb://<pct user>:<pct pass>@host:port/db` (RFC 3986
  unreserved kept); default ports 3306 / 27017.
- Refusal sentences ported verbatim from `app/Sources/WakilKit/Panes/DatabaseConnection.swift`
  (`a host is needed`, `a user is needed`, `a database name is needed`, the host/database breaker
  sentences, `the port must be a number from 1 to 65535`, the mysql user-colon sentence,
  `a SQLite database needs the path to its file`).
- A split server record's Keychain items hold ONLY passwords; `project.json` never holds a password.
- Empty password on a split record = keep the stored item (no Keychain write). Changed user (or
  writeUser) with an empty password is refused: `a new user needs its password — the stored one belongs to <old user>`.
- A refused write writes nothing. Keychain before file, and only for passwords typed. 2e-iii's
  fresh-ref rule (`refsNamedByOthers` / `freshRef`) applies to new refs.
- Legacy records (no `connection`) connect exactly as today; nothing migrates them automatically.
- `db_set_connection`: `.control`, operator-only, in `operatorOnlyActions`,
  `secretParams: ["password", "writePassword"]`. `set_database_dsn` / `db_set_dsn` stay.
- Copy: legacy note `This connection was saved as one string, so it can't be shown. Type it once and it will be editable from then on.`;
  card title in edit mode `EDIT <name>`; password prompt `unchanged`; question
  `Store a connection for <name> in <environment>? The password goes to your Keychain, not to the project file.`;
  a legacy row's location line `saved as one string`.
- Identifiers: `settings.db.<name>.edit` (replaces `.replaceConnection`), `settings.db.cancelEdit`;
  existing card ids unchanged.
- The operator's UI bar from 2e-iii stands: quiet, uncluttered, fits the pane at its default width.
- No commit carries `Co-Authored-By` or a "Generated with" line.

## Review Focus

1. **A password containing `@`, `:` or `/`** connects for both drivers (mysql takes the last `@`;
   mongo percent-encodes). Pinned in Task 1.
2. **Edit, change only the port, save with the password empty** → no question, Keychain untouched,
   connect still works with the old password. Pinned in Tasks 2 and 6.
3. **Edit on a legacy record, then Cancel** → nothing written, record still legacy. Pinned in Task 6.
4. **A hand-edited `connection` with a port of `0` or a host with `/`** → connect refuses with the
   ported sentence, not a driver panic. Pinned in Task 1.
5. **A writable split record** opens its write connection with `writeUser` + the write password.
   Pinned in Task 1.

---

### Task 1: Go — the connection builder and the resolver

**Files:** Create `internal/wakilcore/dbconnection.go`, `internal/wakilcore/dbconnection_test.go`;
Modify `internal/wakilcore/config.go` (Database gains `Connection`), `internal/wakilcore/dbresolve.go`.

**Interfaces — Produces:**
- `type DatabaseConnection struct { Host, Port, Database, User, Path, WriteUser string }` with json
  tags `host,port,database,user,path,writeUser` (all omitempty); `Database.Connection *DatabaseConnection` json `connection,omitempty`.
- `func BuildConnectionString(driver string, c DatabaseConnection, user, password string) (string, error)` — `user` passed explicitly so the write login reuses it.
- `OpenDatabase` / `OpenDatabaseWritable`: when `Connection != nil` and the driver is a server driver,
  the Keychain item is the password and the URL is `BuildConnectionString` (read user = `User`, write
  user = `WriteUser`); otherwise unchanged.

- [ ] **Step 1: Tests** (`dbconnection_test.go`): table per driver for the built string, including
  passwords `p@ss:w/rd` (mysql string contains it raw; mongo percent-encodes to `p%40ss%3Aw%2Frd`);
  every refusal sentence from Global Constraints; empty port → default; sqlite → `Path`.
  `TestASplitRecordConnectsWithItsPasswordOnly`: fakeKeychain holds `hunter2` at the ref; a stub
  driver captures `Connection.URL` == `e2e:hunter2@tcp(db.internal:3306)/ledger`.
  `TestAWritableSplitRecordUsesTheWriteUser`. `TestALegacyRecordIsReadWhole`. Port `0` and host
  `a/b` refused at connect.
- [ ] **Step 2: Run** `go test ./internal/wakilcore/ -run 'Connection|SplitRecord|LegacyRecord'` — FAIL.
- [ ] **Step 3: Implement.** Port the Swift rules; `url.UserPassword(...).String()`-style encoding for mongo must keep exactly the unreserved set listed.
- [ ] **Step 4: Run** `go test ./internal/wakilcore/` — PASS.
- [ ] **Step 5: Commit** `2e-iv: Go builds a database's connection string from its parts and a password`

### Task 2: Go — `SetDatabaseConnection`

**Files:** Modify `internal/wakilcore/projectwrite.go` (beside `SetDatabaseDSN`); Test `projectwrite_test.go`.

**Interfaces — Produces:** `type DatabaseConnectionRequest struct { ProjectPath, Environment, Name, Driver string; Connection DatabaseConnection; Password, WritePassword string; GrantWrite bool }`, `func SetDatabaseConnection(r DatabaseConnectionRequest) error`.

Rules: validate with `BuildConnectionString` (using a placeholder password when empty) before any
write; new record needs `Password` for server drivers; existing split record + empty password keeps
the item unless `User` changed (refuse, Global Constraints sentence); same for `WriteUser`/`WritePassword`
when `GrantWrite`; existing legacy record → becomes split, password required; sqlite: Keychain items
get the path (read, and write when granted) as today, `Connection.Path` set; an existing `writeRef` is
kept when `GrantWrite` is false (as `SetDatabaseDSN`).

- [ ] **Step 1: Tests:** `TestTheSplitRecordKeepsOnlyThePasswordInTheKeychain` (file has no `hunter2`;
  item == `hunter2`); `TestAnEmptyPasswordKeepsTheStoredOne` (port changed, item untouched — assert
  no Keychain write via the fake's call log); `TestAChangedUserNeedsItsPassword`;
  `TestALegacyRecordBecomesSplitWhenEdited`; `TestARefusedConnectionWritesNothing` (bad port →
  file bytes + Keychain unchanged); `TestASQLitePathIsInTheFileAndTheKeychain`; fresh-ref after a
  rename (2e-iii's case).
- [ ] **Step 2: Run** `go test ./internal/wakilcore/ -run 'SplitRecord|EmptyPassword|ChangedUser|LegacyRecord|RefusedConnection|SQLitePath'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/wakilcore/` — PASS.
- [ ] **Step 5: Commit** `2e-iv: SetDatabaseConnection — parts to the file, only passwords to the Keychain`

### Task 3: wakil-ctx — the tool, and the tree carries `connection`

**Files:** Modify `cmd/wakil-ctx/main.go`, `cmd/wakil-ctx/schema_test.go`, `internal/wakilcore/configtree.go`; Test `cmd/wakil-ctx/main_test.go`, `internal/wakilcore/configtree_test.go`.

**Interfaces — Produces:** tool `set_database_connection {projectPath, environment, name, driver, host?, port?, database?, user?, path?, password?, grantWrite?, writeUser?, writePassword?}` → empty object; `ConfigTreeDatabase.Connection *DatabaseConnection` json `connection,omitempty` (never a password — the type has none).

- [ ] **Step 1: Tests:** round trip through the tool (fake keychain) then `config_tree` shows
  `connection.host`; schema list gains `set_database_connection`; config_tree of a legacy record has no `connection`.
- [ ] **Step 2–4:** red, implement (description: passwords go to the Keychain and are never returned; empty password keeps the stored one), green: `go test ./cmd/wakil-ctx/ ./internal/wakilcore/`.
- [ ] **Step 5: Commit** `2e-iv: wakil-ctx set_database_connection; the tree shows where a database lives`

### Task 4: WakilKit — the action and the window method

**Files:** Modify `app/Sources/WakilKit/Registry/StandardActions.swift`, `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (`operatorOnlyActions` + a denial sentence like `db_set_dsn`'s), `app/Sources/WakilKit/App/WindowModel.swift`, `app/Sources/WakilKit/Panes/SettingsTree.swift`; Tests: ActionClassificationTests, AppWiringTests, StandardActionsTests, MCPClientTests (tool list), JournalRedactionTests, PermissionPromptTests.

**Interfaces — Produces:** action `db_set_connection` (params = the tool's); `WindowModel.setDatabaseConnection(projectPath:environment:name:driver:connection:password:grantWrite:writePassword:) async -> String?` (refreshes settings and databases either way, as `setDatabaseDSN`); `SettingsDatabase.connection: SettingsDatabaseConnection?` (`host, port, database, user, path, writeUser` decoded, defaults "").

- [ ] **Step 1: Tests:** operator-only; both passwords `[redacted]` in the journal; an empty password is not sent as a key; tree decodes `connection` and its absence.
- [ ] **Step 2–4:** red, implement, `make app-test` green (bin/ must be built in a fresh worktree: `make build` first).
- [ ] **Step 5: Commit** `2e-iv: db_set_connection, operator-only; the settings tree knows a database's parts`

### Task 5: Settings — Edit replaces Replace connection

**Files:** Modify `app/Sources/WakilApp/SettingsPane.swift`, `app/Sources/WakilKit/Panes/DatabaseConnection.swift` (delete `databaseConnectionString` / `databaseFormCredentials` once unused; keep `DatabaseConnectionFields`, drivers, default ports), `app/Sources/WakilKit/Panes/SettingsEntryWording.swift` (copy + location line), delete `app/Tests/WakilKitTests/DatabaseConnectionStringTests.swift` (its cases now live in Task 1's Go tests); add wording tests.

**Interfaces — Consumes:** Task 4's window method and `SettingsDatabase.connection`.

- [ ] **Step 1:** Row: location line under the chips — `user@host:port/database` (sqlite: path; legacy: `saved as one string`), muted monospaced, one line, middle-truncated. Verbs: **Edit** (`settings.db.<name>.edit`), Remove write access, Remove.
- [ ] **Step 2:** Card edit mode: Edit fills name, driver, host, port, database, user, path, grantWrite + writeUser from `connection`; passwords empty with prompt `unchanged` (split) or required (legacy, with the legacy note); title `EDIT <name>`; a quiet **Cancel** (`settings.db.cancelEdit`) empties the card and restores `ADD OR REPLACE A DATABASE`; selection change also leaves edit mode; focus the first field (Rule 3); scroll respects Reduce Motion.
- [ ] **Step 3:** Save sends `db_set_connection`; asks the question only when a password is typed; non-secret-only saves don't ask. Refusals under the card, the card keeps what was typed. Card validation now comes from Go's refusal (no Swift DSN builder).
- [ ] **Step 4:** `make app-build && make app-test` green; `make controls` only the pre-existing EditorColumn finding.
- [ ] **Step 5: Commit** `2e-iv: Settings — Edit fills the card with all but the password`

### Task 6: e2e, runbook, charter

**Files:** Create `e2e/checks/seeded/2e-iv-database-edit.jsonl`, `docs/wakil/phase-2e-iv-acceptance.md`; Modify `e2e/checks/seeded/2e-iii-database-edit.jsonl` and `2e-settings-databases.jsonl` (Replace connection → Edit), `e2e/checks/uncoverable.tsv`, `docs/wakil/decisions.md` (Decision 21 note), `PRODUCT.md`.

- [ ] **Step 1: Checks** (assert field values as `Value: <text>`, never identifiers; names that are not prefixes of each other; a positive read after every click): add a split database through the card; its location line shows; **Edit** fills `Value: db.internal`; change port to `3307`, save, no question appears, the line shows `:3307`; Edit again, type a password, the question appears, Store it; a legacy one made by `db_set_dsn` dispatch shows `saved as one string`, Edit shows the legacy note, Cancel restores the card title; refusal: user changed with empty password. `db_set_connection` parity or an uncoverable line.
- [ ] **Step 2: Runbook** with setup (walk-2e-iv, staging, one legacy mysql database) — rows only for what checks can't reach: a real mysql connect after a keep-password Edit (if a local mysql exists; else note it), `security find-generic-password … -w` prints only the password, `cat project.json` holds the parts and no password.
- [ ] **Step 3: Charter:** Decision 21 note; PRODUCT.md Settings line; `make docs-check` no new failure; `go test ./e2e/...` only the pre-existing finding.
- [ ] **Step 4: Commit** `2e-iv: e2e checks, runbook and charter`. On-screen runs wait for the operator's go.
