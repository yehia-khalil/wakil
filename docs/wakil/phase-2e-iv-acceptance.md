# 2e-iv — a database's connection edited from Settings: acceptance

**Spec:** [`2026-10-23-2e-iv-database-edit-design.md`](../superpowers/specs/2026-10-23-2e-iv-database-edit-design.md)
· **Charter:** Decision 21 (amended 2026-10-23), Decision 30, Invariant 5

The exit criterion, from the spec: in Settings the operator adds a database as its parts and
edits any of them later — host, port, database and user in `project.json`, only the password in
the Keychain — without typing a connection string and without retyping the password for a port
change. An agent cannot do it. A password never reaches the project file, the journal or the tree.

Nothing here is walked yet: the Walked column is empty until the operator ticks it. The checks
(`make e2e`) cover what the card, Edit, the confirmation and the refusals do; this walk is only
what a check cannot drive, which is anything that reads or connects through the real Keychain.

## 0. Setup

Run this in the repo root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run. It needs no database server for rows 1 to 6.

```bash
(
set -e
ORG=personal
W="$TMPDIR/walk-2e-iv"
rm -rf "$W"
mkdir -p "$W/alpha" "$W/project"
cat > "$W/project/project.json" <<J
{"name":"walk-2e-iv","org":"$ORG","roots":[{"path":"$W/alpha"}],"scopes":{},"environments":{"staging":{"databases":[{"name":"ledger","driver":"mysql","ref":"db:walk-2e-iv:staging:ledger"}],"api":[]}}}
J
./bin/wakil project rm walk-2e-iv --org "$ORG" || true
./bin/wakil project add walk-2e-iv --path "$W/project/project.json" --org "$ORG"
security add-generic-password -U -a wakil -s "wakil:$ORG:db:walk-2e-iv:staging:ledger" -w 'walkuser:walkpass@tcp(127.0.0.1:3306)/walkdb'
echo "project file: $W/project/project.json"
)
```

`walk-2e-iv` has one environment, `staging`, holding one database, `ledger`, in the old shape: a
Keychain item that is the whole connection string (a dummy one) and no `connection` in the file.
Launch with `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil` from the repo root, make
`walk-2e-iv` active with ⌘P and `staging` the environment, and open Settings (⌘,). Keep a
Terminal window open for rows 2 to 4. The walk types the dummy password `walkpass`; it is not a
real credential. Row 5 connects, so it only works if a MySQL server on this Mac has the user
`walkuser`, password `walkpass` and database `walkdb`; nothing here creates one.

## 1. The walk

Walk in order, in `personal`.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Under `walk-2e-iv` › `staging` open **Databases**. The row `ledger` reads `saved as one string`. Press **Edit**, read the note, then type HOST `127.0.0.1`, DATABASE `walkdb`, USER `walkuser`, PASSWORD `walkpass` (leave PORT empty) and press **Save** | The PASSWORD field shows dots. The note says the connection was saved as one string and must be typed once. The question reads `Store a connection for ledger in staging? The password goes to your Keychain, not to the project file.` and names no part of the connection | |
| 2 | Press **Store it**, then in Terminal: `security find-generic-password -s wakil:personal:db:walk-2e-iv:staging:ledger -w` | The row's line reads `walkuser@127.0.0.1:3306/walkdb`. The command prints `walkpass` and nothing else: the Keychain item is the password now, no longer a connection string. macOS may ask to allow it; allow once | |
| 3 | In Terminal: `cat "$TMPDIR/walk-2e-iv/project/project.json"` | The database holds a `connection` with `host`, `database` and `user`, and still `"ref":"db:walk-2e-iv:staging:ledger"`. `walkpass` appears nowhere in the file, and neither does `@tcp(` | |
| 4 | Press **Edit** on `ledger`, set PORT to `3307`, leave PASSWORD empty, press **Save**. Then run row 2's `security` command and row 3's `cat` | No question: nothing secret was typed. The line reads `walkuser@127.0.0.1:3307/walkdb` and the file says `"port":"3307"`. The command still prints `walkpass`: an empty password kept the stored one | |
| 5 | Edit PORT back to `3306` and Save. If a local MySQL has `walkuser` / `walkpass` / `walkdb`, open a query pane on `ledger` and run `select 1` | One row, `1`: the connection string Go built from the file's parts and the kept password reached a real server. Without that server this row is not walked; say so in the Walked column | |
| 6 | In the journal (the activity view) look for the saves in rows 1 and 4 | The `db_set_connection` lines show the password as `[redacted]`, never its text; row 4's carries none | |
| 7 | In the composer: `set the ledger database host to evil.example in staging`, Return. Then hold ⌥, say the same sentence, release | The agent says it can't; asked what the tool answered, it quotes `only the operator configures a database` and points at the settings pane (⌘,). The row's line is unchanged. Voice reaches the agent, so it is told the same | |

## 2. Known and not fixed

- **Removing a database keeps its Keychain item**, as it did before 2e-iv. The item is deleted by
  hand with `security delete-generic-password -s wakil:personal:db:walk-2e-iv:staging:ledger`.
- **A legacy record is not split for the operator.** Its item is a whole connection string with
  the password inside; splitting it would mean parsing a secret, so Edit asks for the parts once.
- **A changed user needs its password typed**: the stored one belongs to the old user, and Go
  refuses the save rather than send it to another login.

## 3. Residue: what the walk cannot establish

- **Storing a password** is checked on screen by `2e-iv-database-edit.jsonl` (from the card and
  from Edit, asserting the question, the typed text absent from the tree and `[redacted]` in the
  journal). It writes the harness's throwaway fixture keychain, which a check cannot read back,
  so rows 2 and 4 keep the real login Keychain.
- **Connecting** (row 5) needs a database server that is not part of this repo. Without one,
  nothing in the walk or the checks reaches a real MySQL; Go's tests pin the string it builds.
- **The agent's refusal** (row 7) needs a running agent, a real provider and quota; the action's
  operator-only audience is pinned in the Swift tests and the checks dispatch it on the agent's
  own socket.
- **Where the text cursor sits after Edit** (HOST, or FILE for SQLite) is not in the accessibility
  tree; the checks assert the field's `Value:` line only.
- **The `unchanged` hint** on an empty PASSWORD is a field prompt, not a value, and the tree does
  not show it; the Swift tests pin when it appears.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

Not yet generated: run `make e2e`, then `make e2e-runbook`, on the head that merges.

<!-- /machine-walk -->
