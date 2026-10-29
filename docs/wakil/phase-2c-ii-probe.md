# Paging a raw query, and who receives ⌘↩ — a 2c-ii probe

**Run:** 2026-09-12 · **Machine:** MacBook Air M3, macOS 26.6.2 · **Engines:** sqlite
(modernc, in-process), MySQL 8 and Mongo 7 in the `wakil-acc-*` containers `make
test-live` already provisions · **Probe code:** throwaway — a `_test.go` in
`internal/wakilcore` and a `--probe-keys` mode in `WakilApp`, both deleted after this
document was written

---

## 1. What prompted it

`2026-09-12-phase-2c-ii-db-pane-design.md` §12 asked two
questions it refused to guess at. Both are cheap now and expensive at the acceptance
walk, which is 2c-i's lesson stated as a rule: six defects and two rulings came out of
looking at the running thing after 500+ tests were green.

1. **§3 pages by wrapping the operator's query in a subquery.** Not every read survives
   being a subquery. Which ones do not, and does the wrapping cost anything — column
   types, in particular, since §8's header annotation is read off the statement that
   actually ran?
2. **§5 puts an editable query line inside a pane on the canvas, run with ⌘↩.** Pane
   focus has been wrong here before (`583cc1d`). Does ⌘↩ reach the pane the operator is
   typing in?

## 2. Question 1 — what survives being wrapped

Each statement run bare, then as
`SELECT * FROM (<raw>) AS wakil_page LIMIT 3 OFFSET {0,3}`, then with an outer
`ORDER BY` added, on sqlite and MySQL.

| Statement | Wrapped | Column types survive |
|---|---|---|
| `SELECT id, kind FROM events` | ✅ | ✅ `INT`/`VARCHAR`, `INTEGER`/`TEXT` |
| …with its own `LIMIT 4` | ✅ | ✅ |
| …with its own `LIMIT 4 OFFSET 2` | ✅ | ✅ |
| `WITH x AS (…) SELECT * FROM x` | ✅ | ✅ |
| `SELECT kind, count(*) AS n … GROUP BY kind` | ✅ | ✅ (MySQL `BIGINT`; sqlite reports none for the expression, as it does unwrapped) |
| `SELECT id … UNION SELECT id …` | ✅ | ✅ |
| …with its own `ORDER BY id DESC` | ✅ | ✅ |
| `SELECT *` (4 typed columns) | ✅ | ✅ `INT VARCHAR TINYINT DATETIME` |
| `EXPLAIN SELECT …` | ❌ **both engines** | — |
| `SHOW TABLES` (MySQL) | ❌ | — |
| `PRAGMA table_info(…)` (sqlite) | ❌ | — |

**Wrapping is free where it works, and it works everywhere it matters.** Every ordinary
read paged correctly at both offsets, and — the part worth having measured — the
declared column types came through the subquery unchanged. MySQL still reports `TINYINT`
for a `BOOLEAN` through a wrap, which is what keeps §8's chip rule failing the way it is
supposed to.

**The three failures are real, reachable, and gate-approved.** Run against the gate
directly:

| Query | `AssertSQLReadOnly` |
|---|---|
| `SELECT id FROM events` | passes |
| `SHOW TABLES` | **passes** |
| `EXPLAIN SELECT id FROM events` | **passes** |
| `WITH x AS (SELECT 1) SELECT * FROM x` | passes |
| `SELECT * FROM (SELECT …) AS wakil_page LIMIT 3 OFFSET 3` | passes |
| `PRAGMA table_info(events)` | refused |
| `UPDATE events SET kind='x'` | refused |

So an operator can legitimately run `SHOW TABLES` or an `EXPLAIN`, see rows, and press
*next page* — and today's spec would hand them
`Error 1064 … near 'SHOW TABLES) AS wakil_page LIMIT 3 OFFSET 0'`. `PRAGMA` is not a
case: the gate refuses it before paging is reached.

**The fix is free, and the gate already computed it.** The refusal message is *"only
SELECT/EXPLAIN/SHOW queries are allowed (read-only)"* — the gate necessarily knows which
of the three verbs it accepted. `SELECT` (including `WITH … SELECT`) is pageable;
`EXPLAIN` and `SHOW` are not. That is a fact the gate already has, not a new guess about
SQL, so §3's "which reads are unpageable" is answered by surfacing something that exists
rather than by parsing anything.

### Two honesty findings that came out of the same run

- **An inner `LIMIT` bounds the universe, and an outer `ORDER BY` sorts within it.**
  `SELECT id, kind FROM events LIMIT 4` wrapped with `ORDER BY 1 DESC` returns the
  reverse of *rows 1–4*, not the last 4 of the table. That is correct SQL and it is the
  right answer — but it is §8's "sorted by X within the N returned" reappearing one layer
  down, now caused by the operator's own `LIMIT` instead of by `clampReadLimit`. Spec §7
  claims the footer's admission "disappears from this pane entirely". It does not.
- **Paging past the end returns zero rows, not an error.** The aggregate has three groups;
  at `OFFSET 3` it returns none, with the columns intact. So "end" is detectable and a
  page-past-the-end is recoverable rather than a failure.

### Mongo

| | Result |
|---|---|
| `find` `skip=3 limit=4` | ids 4,5,6,7 |
| `find` `skip=3 limit=4 sort id:-1` | ids 9,8,7,6 |
| aggregate `$skip,$limit` | ids 4,5,6,7 |
| aggregate `$limit,$skip` (wrong order) | **1 doc** — order is load-bearing, as §3 assumed |
| user's own `$limit 5`, then `$skip 3, $limit 4` | ids 4,5 — the inner limit bounds it, same rule as SQL |
| `find {}` `skip=9 limit=4` on 12 docs | 3 docs, no error |

Mongo needs no wrapping and has no unpageable case. `$skip` before `$limit`, appended
after whatever the operator wrote, behaves exactly as the SQL path does.

## 3. Question 2 — ⌘↩ goes to the wrong pane

Two panes, each with a query `TextField` and a hidden
`Button(…).keyboardShortcut(.return, modifiers: .command)` — the obvious SwiftUI
spelling of "⌘↩ runs this pane's query" — plus a window-level message field. Focus
driven through `@FocusState`, then keys delivered.

| Focus | ⌘↩ (key-equivalent chain) | plain ↩ (`.onSubmit`) |
|---|---|---|
| pane `db-1`'s field | `db-1` | `db-1` |
| pane **`db-2`**'s field | **`db-1`** | `db-2` |
| the message field | **`db-1`** | `message` |

**`.keyboardShortcut` is window-scoped, not focus-scoped, and it is not even
focus-*biased*: it fired the first-registered pane's button every time.** Typing in
`db-2` and pressing ⌘↩ would run `db-1`'s query into `db-1` — silently, with both panes
looking plausible afterwards. This is the fourth-cause-of-one-symptom shape 2c-i warned
2c-ii to expect, and no test target could have seen it: `WakilApp` has none, because a
test target cannot import an executable.

**`.onSubmit` on the focused field is correctly scoped in all three positions**,
including against the window's own message field, which also wants Return.

**So the query line submits on plain Return.** ⌘↩ was chosen to keep Return free for
newlines, and a single-line query field has no newlines to keep it free for — the
constraint that motivated the shortcut does not exist. If ⌘↩ is wanted anyway, it must be
**one** window-level shortcut that dispatches to the focused pane id, never a shortcut per
pane.

### What this measurement does not establish

The probe window was offscreen and never became key (`isKeyWindow == false`), so
`NSApplication.sendEvent` did not deliver ⌘↩ at all and the result above came through an
explicit `performKeyEquivalent(with:)`. That is the same chain AppKit runs for a key
equivalent, and first-registered-wins is its documented behaviour, so the finding stands
— but the acceptance walk should press ⌘↩ on a real key window with two panes open and
confirm it, rather than take this as settled.

## 4. Recommendation

1. **Page by wrapping, conditionally, as §3 says** — it is correct and type-preserving on
   every read that matters, on both SQL engines.
2. **Carry the gate's verb out with the result.** `SELECT`/`WITH` is pageable;
   `EXPLAIN`/`SHOW` is not, and the footer should say *"this result cannot be paged"*
   rather than let the operator press a control that returns a syntax error.
3. **Amend spec §7.** The footer's "within the N returned" admission survives, because an
   operator's own `LIMIT` recreates the condition it exists for. It is not the DB pane
   outgrowing the warning; it is the warning acquiring a second cause.
4. **Submit the query line on Return, via `.onSubmit`.** No per-pane `.keyboardShortcut`
   anywhere in the DB pane.
