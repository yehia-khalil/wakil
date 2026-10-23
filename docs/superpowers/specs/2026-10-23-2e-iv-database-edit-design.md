# 2e-iv: edit a database's connection in Settings

**Date:** 2026-10-23
**Status:** spec awaiting the operator's review. The operator skipped the design questions, so
every decision below beyond the two they made is the designer's call, listed under *Calls made
for the operator*.
**Sub-phase:** 2e-iv, a new phase map row after 2e-iii (main 5c3f31e). Asked for on the 2e-iii
look: "why do we have replace connection on db connections and not edit?" — then "edit should
replace the 'replace connection' option".

---

## Problem

A database's connection is stored as one secret string in the Keychain (`db:<project>:<env>:<name>`),
host, user and password together. The page never reads a secret back, so it cannot show what a
connection is, and changing one field (a moved host, a new password) means retyping all of it
through **Replace connection**. A hand-reader of `project.json` cannot see where a database lives
either.

## Decided by the operator (2026-10-23)

1. **The non-secret parts live in `project.json`; only the password lives in the Keychain.**
2. **Edit pre-fills everything but the password, and replaces "Replace connection"** — one verb,
   not two.

## Calls made for the operator

1. **Record shape.** A database gains an optional `connection` object in `project.json`:
   `{"host","port","database","user"}` for a server driver (mysql, mongo), `{"path"}` for sqlite.
   When writes are allowed it also holds `writeUser`. `ref` and `writeRef` keep their names and
   derivation.
2. **What the Keychain holds.** For a server database with `connection`, the `ref` item holds the
   read password only and the `writeRef` item the write password only. The connection string is
   assembled in Go at connect time from `connection` + the password, with today's per-driver
   formats (mysql `user:pass@tcp(host:port)/db`, mongo `mongodb://user:pass@host:port/db`, user and
   password percent-encoded for mongo). The DSN-building and its refusals move from Swift
   (`databaseConnectionString`) to Go, so the shell, the agent's tools and the pane share one
   builder.
3. **SQLite.** Its path is not a secret: it goes into `connection.path` so Edit can show it, and the
   Keychain items keep holding the path as today, so the SQLite connect path is unchanged.
4. **Old records keep working untouched.** A database with no `connection` is a *legacy* record: its
   Keychain item is the whole connection string, read exactly as today. No automatic migration —
   splitting would mean parsing a secret. **Edit** on a legacy record opens the card with its name
   and driver filled, an empty connection and a one-line note: "This connection was saved as one
   string, so it can't be shown. Type it once and it will be editable from then on." Saving turns
   it into a split record.
5. **Leaving the password empty keeps it.** On Edit of a split record the password field is empty
   with the prompt `unchanged`; saving with it empty writes no Keychain item (Rule 9: optional stays
   optional). The same for the write password. A new database still needs one, as today.
6. **Edit is the card, filled.** **Edit** on a row fills the ADD OR REPLACE A DATABASE card with every
   field but the password(s), retitles it **EDIT ledger**, scrolls to it and focuses the first field
   (Rule 3). Saving a name already listed replaces that database, as today. **Cancel** on the card
   empties it and puts its title back. One card, so there is never a second form on the page.
7. **Confirmation only when a secret is written.** Saving with a password typed asks, as today
   ("Store a connection for ledger in staging? The password goes to your Keychain, not to the
   project file."). Saving non-secret parts only (host, port, database, user, path) asks nothing:
   it is an ordinary edit (Rule 1).
8. **A changed user with an empty password is refused**, whole, under the card: "a new user needs
   its password — the stored one belongs to <old user>". The same for writeUser.
9. **Tools.** `wakil-ctx` gets `set_database_connection {projectPath, environment, name, driver,
   host?, port?, database?, user?, path?, password?, grantWrite?, writeUser?, writePassword?}`;
   `set_database_dsn` stays as it is for scripts and agents' hand-written configs (legacy shape).
   One registry action `db_set_connection`, `.control`, operator-only, `secretParams: ["password",
   "writePassword"]`. The card switches to it.
10. **What agents see.** `config_tree` and the settings tree carry `connection` (no secret in it).
    `list_databases` (wakil-db) is unchanged: name, driver, writable.

## What the operator gets

1. Each database row's verbs read **EDIT · REMOVE WRITE ACCESS · REMOVE** (Remove write access only
   when writable). **Replace connection** is gone.
2. The row shows where it lives under the chips, muted and monospaced: `e2e@db.internal:3306/ledger`
   (sqlite: its path), shortened in the middle when narrow. A legacy record shows `saved as one
   string` there instead.
3. **Edit** fills the card as in call 6; the operator changes one field and saves.
4. A refusal is shown whole under the card and the card keeps what was typed (Rule 8).

## What it does not do

- It doesn't read any password back, or show one.
- It doesn't migrate legacy records on its own.
- It doesn't change the query pane, the write gate (Decision 25), or which credential a write uses.
- No new drivers.

## Design notes for the builder

- Go: `Database.Connection *DatabaseConnection` (`Host, Port, Database, User, Path, WriteUser`);
  `BuildConnectionString(driver, conn, password) (string, error)` in `internal/wakilcore`, with the
  Swift refusals ported verbatim (host breakers, database breakers, port range, mysql user colon);
  `OpenDatabase` / `OpenDatabaseWritable` call it when `Connection != nil` (server drivers), else
  read the item whole (legacy, sqlite). `SetDatabaseConnection(request)` validates everything before
  any Keychain write, writes the Keychain first only for passwords typed, then the file — and keeps
  2e-iii's fresh-ref rule (`:2` when another row names the derived ref).
- Swift: the card gains an edit mode (title, empty-means-unchanged password prompts, legacy note);
  `DatabaseConnectionFields` stays the card's model; `databaseConnectionString` is deleted once Go
  owns building (its tests move to Go).
- Rename (2e-iii) keeps `connection` with the record.

## Errors and edges

- A split record whose Keychain item is missing: connect fails with today's missing-secret sentence.
- A hand edit to `connection` while the page is open is kept (read at dispatch).
- `connection` present on a sqlite record with a different path than the Keychain item: the item
  wins at connect (as today); Edit shows `connection.path` and saving rewrites both.

## Testing

- **Go:** build string per driver (+ every refusal); split record round trip (Keychain holds only the
  password; file holds no password); empty password keeps the item; changed user + empty password
  refused; legacy record still connects and is untouched by non-Edit writes; writable split record
  connects with the write user.
- **WakilKit:** `db_set_connection` operator-only, both passwords redacted in the journal.
- **e2e (seeded):** Edit a split database: the card fills (Value: host/user/database), change the
  host, save without a password (no question), the row shows the new host; Edit a legacy one: the
  note shows; Cancel restores the card. Fixture keychain as in 2e-iii.
- **Runbook** `docs/wakil/phase-2e-iv-acceptance.md`: a real mysql connect after an Edit that kept
  the password, and `security find-generic-password … -w` printing only the password.

## Charter changes

- North-star phase map: a **2e-iv** row after 2e-iii.
- Decision 21: a note that a database's non-secret parts live in `project.json`.
- PRODUCT.md: the Settings line mentions Edit.
