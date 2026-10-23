# 2e-iii — API entries and databases edited from Settings: acceptance

**Spec:** [`2026-10-22-2e-iii-api-entries-design.md`](../superpowers/specs/2026-10-22-2e-iii-api-entries-design.md)
· **Charter:** Decision 21 (amended 2026-10-22), Decision 30, Invariant 5

The exit criterion, from the spec: in Settings the operator adds, edits and removes an
environment's API entries, stores or replaces an entry's token in the Keychain, renames a
database and removes its write access, without editing `project.json`. A token never reaches
the project file, the journal or the tree. An agent cannot do any of it.

Nothing here is walked yet: the Walked column is empty until the operator ticks it. The checks
(`make e2e`) cover what an entry's fields, refusals, renames and removals do; this walk is only
what a check cannot drive, which is anything that stores a token in the real Keychain.

## 0. Setup

Run this in the repo root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run. It needs no database server: the database is only listed, never queried.

```bash
(
set -e
ORG=personal
W="$TMPDIR/walk-2e-iii"
rm -rf "$W"
mkdir -p "$W/alpha" "$W/project"
cat > "$W/project/project.json" <<J
{"name":"walk-2e-iii","org":"$ORG","roots":[{"path":"$W/alpha"}],"scopes":{},"environments":{"staging":{"databases":[{"name":"ledger","driver":"mysql","ref":"db:walk-2e-iii:staging:ledger"}],"api":[]}}}
J
./bin/wakil project rm walk-2e-iii --org "$ORG" || true
./bin/wakil project add walk-2e-iii --path "$W/project/project.json" --org "$ORG"
security delete-generic-password -s "wakil:$ORG:api:walk-2e-iii:staging:orders-api" >/dev/null 2>&1 || true
echo "project file: $W/project/project.json"
)
```

`walk-2e-iii` has one environment, `staging`, holding one database, `ledger`, and no API entries.
The setup also clears any Keychain item an earlier walk left for `orders-api`.

Launch with `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil` from the repo root, make
`walk-2e-iii` active with ⌘P and `staging` the environment, and open Settings (⌘,). Keep a
Terminal window open for rows 3, 5 and 7. The walk types the dummy token
`Bearer walk-token-123`; it is not a real credential.

## 1. The walk

Walk in order, in `personal`.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Under `walk-2e-iii` › `staging` open **API**. In the card type NAME `orders-api`, BASE URL `https://httpbin.org`, TOKEN `Bearer walk-token-123`, press **Save** | The TOKEN field shows dots, not the text. The question reads `Store a token for orders-api in staging? It goes to your Keychain, not to the project file.` and names no part of the token | |
| 2 | Press **Store it** | The entry `orders-api` appears with Token `in Keychain (api:walk-2e-iii:staging:orders-api)` — the name of the Keychain item, never the token. The card is empty again | |
| 3 | In Terminal: `security find-generic-password -s wakil:personal:api:walk-2e-iii:staging:orders-api -w` | Prints `Bearer walk-token-123`. macOS may ask to allow it; allow once | |
| 4 | In Terminal: `cat "$TMPDIR/walk-2e-iii/project/project.json"` | The entry holds `"authRef":"api:walk-2e-iii:staging:orders-api"` and no token text anywhere | |
| 5 | Open the API pane for `orders-api` (⌘P or the palette), and send `GET /headers` from it | httpbin answers 200 with the headers it received. The reply holds `"Authorization": "[redacted]"`: the stored token was sent, and Wakil scrubs it from the reply as it scrubs every echoed credential. The request the pane draws shows `authorization` as "supplied by the orders-api entry", never the token |
| 6 | Back in Settings press **Replace token**, type `Bearer walk-token-456`, press **Store it** | One question at a time, on the entry; **Store it** replaces the item. Run row 3's command: it prints `Bearer walk-token-456` | |
| 7 | Press **Replace token**, type something, then press **Cancel** | The field and the question go away; row 3's command still prints `Bearer walk-token-456` | |
| 8 | Press **Clear token** | No question (it destroys nothing). Token reads `none`. Row 3's command still prints `Bearer walk-token-456`: the Keychain item is kept | |
| 9 | In the journal (the activity view) look for the store in row 6 | The `api_set_entry` line shows the token as `[redacted]`, never its text | |
| 10 | In the composer: `add an API entry named walk-agent at https://api.example.com to staging`, Return. Then hold ⌥, say the same sentence, release | The agent says it can't; asked what the tool answered, it quotes `only the operator configures an API entry` and points at the settings pane (⌘,), not the organisation sentence (`creating an organisation…`). No `walk-agent` entry appears. Voice reaches the agent, so it is told the same | |
| 11 | Open **Databases** for `staging`. Rename `ledger` to `ledger-main` and click away in the tree (no Return) | The row shows `ledger-main`, its Keychain refs still end `:ledger`; saved on leaving the field (Rule 2). **Remove write access** is absent: this database is not writable | |

## 2. Known and not fixed

- **Removing an API entry keeps its Keychain item**, as removing a database keeps its entries.
  The item is deleted by hand with `security delete-generic-password -s wakil:personal:api:walk-2e-iii:staging:orders-api`.
- **A hand-edited file holding two entries of one name** draws both; an edit or a removal by
  name acts on the first, and the later one carries a note saying so.

## 3. Residue: what the walk cannot establish

- **Storing and clearing a token** are checked on screen: `2e-iii-api-entries.jsonl` stores
  one from the card and from **Replace token**, reads the Keychain line, asserts the typed text
  is absent from the tree and `[redacted]` in the journal, and presses **Clear token**. They
  write the harness's throwaway fixture keychain, which a check cannot read back, so rows 1 to
  8 keep the real login Keychain: `security find-generic-password` and the real-host send.
- **Sending with the token** (row 5) needs the real Keychain item and a real host that echoes
  the header it received.
- **The agent's refusal** (row 10) needs a running agent, a real provider and quota; the
  actions' operator-only audience is pinned in the Swift tests and the checks dispatch them on
  the agent's own socket.
- **The field keeping what was typed** is asserted as the field's `Value:` line in the tree;
  where the text cursor sits is not in that tree.
- **The refusal sentences** (`must be an absolute https URL`, `authHeader Host cannot carry a
  credential`) are asserted by the checks, on Return and by dispatch.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

Not yet generated: run `make e2e`, then `make e2e-runbook`, on the head that merges.

<!-- /machine-walk -->
