# Phase 2c-ii-b — editing records from the DB pane — design

**Status:** binding authority for sub-phase 2c-ii-b.
**North star:** Decision 20, `docs/wakil/north-star.md`.
**Probe:** `docs/wakil/phase-2c-ii-b-probe.md`, 2026-09-13 — six of this spec's rules are
its findings, and two of them contradict what brainstorming had settled before it ran.
**Depends on:** `2026-09-13-integer-fidelity-design.md` (§11).
**Unblocked by:** 2c-ii's `D8b` and `D7`, both closed 2026-09-13.

---

## 1. What this is

> Double-click a cell, it becomes an input, Enter commits.

That is the whole feature, and every other section exists to keep it from being a lie.

**It is an entrance, not a path.** The edit composes one `UPDATE` and dispatches
`db_run_mutation` — the same and only `.mutate` action the typed route uses — through the
same `ActionRegistry`, the same `writeGate`, the same confirmation plane and the same
production block. Nothing here writes to a database. An editable grid that wrote through
to the engine itself would be the plainest violation of Invariant 2 in the codebase, and
it would arrive looking like a convenience.

**It is the second entrance to a path already open and already walked.** 2c-ii's query
line classifies a statement, hands a mutation to `WindowModel.runMutation` at
`origin: .ui`, and parks the plane — walked on `phase-2c-ii-acceptance.md` check 10. This
sub-phase adds no gate, no origin, and no confirmation mechanism.

---

## 2. The rule this is written against

> **A cell may only be editable when Wakil can name the exact row it would write to.**

A result grid holds the rows of a *query*, not the rows of a *table*. A join, an
aggregate, a computed expression, an alias, or a `SELECT` that omitted the key gives a
cell no `WHERE` clause to be written back through, and inventing one is how a tool
updates the wrong row — or every row.

Its corollary, from `design-language.md` §8 and obeyed already by `truncated` and the
sort footer:

> **Everything else stays read-only and says so.**

---

## 3. Who decides what, and where

The probe settled this by measurement rather than by preference. **Go decides
everything; Swift renders and carries.**

| Question | Answered by | Why not the other side |
|---|---|---|
| Which table did these rows come from? | Go, from the statement | Swift never parses SQL (2c-ii) |
| What are that table's key columns? | Go, per driver | Dialect-specific; nothing in Swift knows |
| Which exact row is this? | Go, at read time | A key above 2^53 cannot survive Swift (§11) |
| How does this text become a literal? | Go, per driver | `''`-doubling corrupts data on MySQL (probe §3.3) |
| Is this text valid for this column? | Go, from the declared type | sqlite stores `abc` in an INTEGER column (probe §3.4) |
| Is this cell editable *right now*? | Swift, reading Go's answer | It is a draw-time question about a value Go computed |

---

## 4. Provenance — `Rows.Editable`

`Rows` (`dbdriver.go`) gains one optional block, `nil` on every result that is not
editable:

```go
type Editable struct {
    Table      string   `json:"table"`
    KeyColumns []string `json:"keyColumns"`
    RowKeys    []string `json:"rowKeys"`
    Columns    []string `json:"columns"`
}
```

- `Table` — the single table the rows came from, unqualified, as the statement named it.
- `KeyColumns` — every primary-key column, in the engine's reported key order.
- `RowKeys` — positionally aligned with `Rows.Rows`: the rendered, dialect-escaped
  `WHERE` predicate identifying that one row, e.g. `` `id` = 42 `` or
  `` `b` = 'x' AND `a` = 7 ``.
- `Columns` — which result columns may be written to. Every column that is a plain
  reference to a column of `Table`, minus the key columns and minus any type a literal
  cannot express (§7).

**Key columns are excluded deliberately.** Changing a key is a legitimate thing to want
and a bad thing to do by double-click: it changes the row's identity, which makes every
`RowKey` the pane is holding — including the one the edit was composed from — describe a
row that no longer exists. The query line remains its route, where the operator writes
the whole statement and can see that is what they are doing.

**`RowKeys` is rendered in Go, at read time, from the values the engine returned.** That
is the entire answer to the precision problem: the key never becomes a number in Swift,
because Swift only ever holds the finished predicate text.

**It also buys a property nobody asked for and everybody wants.** The key describes the
row *as it was read*. If someone else changed that row in between, the `UPDATE` matches
nothing, `rowsAffected` is 0, and the operator is told — instead of silently stamping
over a change they never saw.

**Swift carries SQL text it did not compose, and this does not breach 2c-ii's rule.**
The rule is that Swift never *composes* SQL. A predicate produced by the driver and
handed back to the driver unmodified is a token as far as Swift is concerned; nothing in
`WakilKit` or `WakilApp` may parse, split, or build one.

**`RowKeys` is excluded from `PaneStore.snapshot`.** `read_pane` feeds an LLM's context,
and five hundred `WHERE` fragments in it buy the agent nothing it cannot see in the key
column itself. `table`, `keyColumns` and `columns` are included, because "this pane is
editable and these columns are writable" is a fact about the pane worth the agent knowing.

### 4.1 Keys must be permuted with their rows

`sortedRows` reorders rows client-side on a complete result, and `PaneStore` stores what
it returns. A parallel `RowKeys` array left unpermuted would pair every key with the
wrong row — the single worst failure this whole spec exists to prevent, reintroduced
below the layer that prevents it.

So `sortedRows` changes shape: it returns **a permutation** (`[Int]`, indices into the
input) rather than reordered rows, and `PaneStore.setRows` applies that one permutation to
the rows and to the keys together. One ordering, applied once, to everything that is
positionally aligned with a row.

---

## 5. The recogniser

A new file beside `readonly.go` — the only other place in Wakil that reads SQL —
answering one question: *do these rows come from exactly one named table, unambiguously?*

**The accepted shape, and nothing else:**

> `SELECT`, with no `DISTINCT`, of `*`, `<alias>.*`, or a list of bare identifiers;
> `FROM` exactly one unqualified table name with an optional alias; followed by nothing
> but `WHERE`, `ORDER BY`, `LIMIT` or `OFFSET`.

Refused: `WITH` anywhere, any join of any spelling (`JOIN`, comma), a subquery in `FROM`,
`GROUP BY`, `HAVING`, `UNION`/`INTERSECT`/`EXCEPT`, window functions, any selected item
that is not a bare identifier, duplicate result column names, and any qualified table
name.

**Two of those refusals are not tidiness, and the probe demonstrated both.**

- **`WITH events AS (SELECT 1 AS id, 'z' AS kind) SELECT * FROM events`** returns columns
  named `id` and `kind`. A recogniser reading the last `FROM <name>` calls it table
  `events`, looks up the real `events`' key, finds `id`, and declares it editable. The
  operator then edits a row that came from a literal in their own `WITH` clause and the
  `UPDATE` writes to the **real** `events` table, to a row that was never on screen.
  Refusing any `WITH` token closes it; a CTE cannot appear in a statement this recogniser
  would otherwise accept.
- **`SELECT id, kind || '!' AS kind FROM events`** produces a result column named `kind`
  that is not the table's `kind`. Editing it composes `SET kind = …` against the real
  column, so the operator edits a derived value and silently overwrites its source.
  Requiring every selected item to be a bare identifier is what stops it, and it is the
  same rule that drops `SELECT id AS ident`.

**A `WHERE` clause containing a subquery is not refused**, and does not need to be: the
rows still come from the one named table and the key still identifies them.

**A qualified name is refused** because the key lookup is scoped to the connection's own
database. Measured: with `wakilprobe2.events` keyed on `eid` and `wakilacc.events` keyed
on `id`, a bare-name lookup answers `id` for `FROM wakilprobe2.events` — a key the result
does not have. This is also consistent with the pane's database being part of its
identity (2c-ii §5).

**`ReadTable` needs no recogniser.** A `.table` subject names its table by construction
and selects every column, so it is editable whenever the table has a key.

**Then, whatever the route:** the table must have key columns, and every one of them must
appear in the result **under its own name**. A view and a keyless table both report no
key on both engines, so neither needs a special case — "no key columns" already means
"not editable".

---

## 6. Key discovery

A new `Conn` capability, `PrimaryKey(ctx, table) ([]string, error)`, returning key columns
in the engine's reported order.

| Driver | Query | Why this one |
|---|---|---|
| sqlite | `SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk` | Table-valued form takes a **bound parameter** |
| MySQL | `information_schema.KEY_COLUMN_USAGE` filtered on `DATABASE()`, `TABLE_NAME = ?`, `CONSTRAINT_NAME = 'PRIMARY'`, ordered by `ORDINAL_POSITION` | Also parameterised; `SHOW KEYS` is not |
| Mongo | not implemented — returns no key | The driver's write path is unimplemented anyway |

**Both take a bound parameter, so key discovery needs no identifier quoting at all.**
That is the reason `information_schema` beats `SHOW KEYS`: `SHOW KEYS FROM <name>` has
nowhere to put a parameter and would have to interpolate through `quoteIdent` —
`Describe`'s compromise, which does not need repeating where a parameterised route
exists. `SHOW KEYS` also errors on a missing table where `information_schema` returns
nothing, and "the table is gone" is already `Describe`'s to report.

**Composite order is reported and is not declaration order** — `PRIMARY KEY (b, a)` on a
table declared `(a, b, c)` reports `b` first on both engines. `AND` is commutative so a
`WHERE` in the wrong order would still match, but the ordinal is what says *which*
columns, and it is correct, so nothing guesses.

**A `UNIQUE NOT NULL` column is not a key and is not reported as one.** It would identify
a row just as well. Decision 20 says primary key; the gap is recorded as deliberate
rather than unnoticed.

---

## 7. Rendering a typed value

### 7.1 Every value is quoted

**The rule brainstorming settled — "numeric and boolean columns emit a bare literal" — is
deleted, and must not be built.** Measured on both engines:

```
UPDATE tt SET name = secret WHERE id = 1
  sqlite: name = "hunter2", no error
  mysql:  name = "hunter2", no error
```

**A bare literal is a column reference.** Typing `active`, `count`, `status` or `id` into
a cell would not store that word — it would copy another column of the same row, with no
error, no warning, and a confirmation plane showing a statement that reads perfectly
well. That is Decision 20's own "updates the wrong thing" failure, arriving through the
value instead of through the `WHERE`.

Quoting is safe for every type both engines have: `'42'` into an `INT` stores `42`,
`'9.99'` into a `DECIMAL(10,2)` stores `9.99`. So every literal is quoted and the engine
coerces.

**`BIT` is the one exception and is therefore not editable.** A quoted literal into
`BIT(1)` is `Error 1406 Data too long`. It is excluded from `Editable.Columns` and the
query line remains its route.

### 7.2 Escaping is per-driver, beside `quoteIdent`

| Driver | Rule |
|---|---|
| sqlite | Double the `'`. **Refuse a NUL** — it is a syntax error, the same truncate-at-NUL behaviour `Describe` and `ReadTable` already refuse a table name for. |
| MySQL | Double the `'`, and double the `\` **unless** the session's `sql_mode` carries `NO_BACKSLASH_ESCAPES`. |

**`''`-doubling alone silently corrupts data on MySQL**: `C:\path\n` stored as `C:path`
plus a newline, no error, against a confirmed statement whose text contained the right
value. `NO_BACKSLASH_ESCAPES` is **not** in MySQL 8's default `sql_mode`, so this is the
ordinary case and not an exotic one.

The mode is read once, at `ConnectWritable`, with `SELECT @@SESSION.sql_mode`, and stored
on the `sqlConn`. It cannot be set behind Wakil's back: `hardenMySQLWriteConfig` replaces
`cfg.Params` wholesale, so every pooled session sees the same server default.

**Hex literals were measured and rejected.** `X'…'` round-trips every payload on both
engines, mode-independently, NUL included — and on sqlite stores into a `TEXT` column with
`typeof() = 'blob'`, changing the value's type. It would also put
`SET name = X'4F27427269656E'` in front of an operator being asked to confirm what they
are about to run, which is the one thing the plane exists to prevent.

### 7.3 The column type validates

sqlite's type affinity accepts `abc` into an `INTEGER` column and **stores it as text**; a
cell that read `7` now reads `abc`, and the next numeric comparison against that column
quietly stops working. MySQL under `STRICT_TRANS_TABLES` refuses the same write, which is
right, but arrives as a round trip and an engine error message.

So the typed text is validated against the column's declared type **before composing** —
numeric types require a parseable number — giving both engines the same behaviour and
giving the operator a sentence rather than an engine error.

### 7.4 `=` means SQL

A leading `=` passes the rest through verbatim into the `SET` clause: `=NOW()`,
`=NULL`, `=price * 1.1`. One rule covers functions, NULL and column references; without
it NULL is unexpressible and `NOW()` is stored as the four characters `NOW()`.

Anything without a leading `=` is a literal, quoted per §7.1. To store the text `=NOW()`
the query line is the route.

**An expression is not validated and is not escaped**, because it is not a value — it is
the operator asking for SQL in so many words. It is still composed into one statement that
passes `AssertSQLMutation`, is shown whole in the plane, and requires a typed
confirmation. An operator who writes `=1 WHERE 1=1 --` gets exactly the statement they
wrote, in front of them, to confirm. That is the same authority the query line has given
them since 2c-ii, reached by a shorter route.

**`MutationAffectsEveryRow` will not flag that statement**, because it does contain a
`WHERE`. It is advisory and never refuses anything; this is recorded so the absence is
not read later as a defect.

---

## 8. Composition — `db_render_update`

A new `wakil-db` tool `render_update` and a new `.read` action wrapping it. It composes
the statement and **returns the text without executing it** — the same shape as
`classify_statement`: ask Go before running, so Wakil's Swift half never parses or
composes SQL.

```
db_render_update(database?, table, rowKey, column, value) -> { statement }
```

**`value` is the operator's raw text, verbatim, leading `=` and all.** The §7.4 rule is
applied in Go, in one place, beside the escaping and the validation it interacts with.
Swift must not strip the sigil, test for it, or branch on it — a second implementation of
"is this a value or an expression?" is a second answer to the question that decides
whether text gets escaped.

It resolves the database because it must: the escaper depends on the driver and, on
MySQL, on the session's `sql_mode` (§7.2). It runs no SQL against user data.

Swift then dispatches `db_run_mutation` with that statement, unchanged. **That is the
only `.mutate` action, exactly as Decision 20 requires**, and the plane shows the text
`db_run_mutation` received.

**Two round trips per edit, at human speed, and both are cheap.** The alternative —
`db_run_mutation` growing structured parameters — would give the one gated action two
input shapes and two things to get wrong, on the single surface in the codebase least
able to afford it.

**`db_render_update` is `.read` and so reachable by the agent.** It executes nothing and
composes only statements the agent could already write by hand.

---

## 9. The surface

### 9.1 The editor

Double-click an editable cell → it becomes a `TextField` seeded with the cell's current
text → **Enter** composes and dispatches → **Escape** abandons and restores.

- **NULL seeds as empty**, and an empty field on a nullable column means the empty
  string, not NULL. `=NULL` is NULL. The grid draws the two differently already (§8's
  explicit null rendering) and this keeps that distinction writable.
- **No `.keyboardShortcut`, ever** — `DBPane`'s standing prohibition, for the measured
  reason in its doc comment: a per-pane shortcut is window-scoped and fires the
  first-registered pane's control whatever has focus. `.onSubmit` on the focused field
  routes correctly.
- **One cell at a time.** A second double-click abandons the first.

### 9.2 What happens after Enter

| Outcome | The cell | The pane |
|---|---|---|
| Confirmed and ran | leaves edit mode | re-fetches its own subject (D8b's fix, unchanged) |
| Gate refused it | **stays in edit mode, text kept**, reason shown | untouched |
| Operator cancelled the plane | **stays in edit mode, text kept** | untouched |
| Validation refused it (§7.3) | **stays in edit mode, text kept**, reason shown | untouched, nothing ran |

**Validation refuses at `db_render_update`, not in the view.** It is a round trip like
any other, and it reaches no user data and no `.mutate` action — the statement is never
composed, so there is nothing to confirm and nothing to run. The operator is shown Go's
sentence, which is the same discipline `classify_statement` established: the refusal the
operator reads is the refusal that was actually made, never a second wording composed
nearer the screen.

**A refusal and a cancel both keep what was typed**, which is D7's lesson applied at
close range. Decision 20 predicted this would matter more here than on the typed route,
and it is right: on a cell edit the discarded text is the value the operator just
entered, and they are least inclined to retype it at exactly the moment Wakil refused
them. Escape is how you leave without committing.

**Only a confirmed run exits edit mode**, because only a confirmed run changed anything.

### 9.3 Saying so

The footer already ends with a fixed `read-only` label at its trailing edge. That label
becomes the truth:

| State | Trailing label |
|---|---|
| Editable | `editable` |
| Not editable, reason known | `read-only · more than one table` / `· no primary key` / `· key not in result` / `· derived column` |
| Not editable, no result | `read-only` |

It keeps `.layoutPriority(1)` — it is one of the three segments D9 established must
survive narrowing, and it is now carrying more.

**Editable cells get a faint hover treatment**, the same pattern `hoveredRow` and
`hoveredColumn` already drive for the drill button and the width handle: invisible at
rest so §8's "row separation by whitespace" holds, revealed under the pointer so the
double-click is discoverable. A surface that cannot do the thing must not look like it
can — and one that can must not look like it cannot.

---

## 10. What this does not do

- **No INSERT and no DELETE.** Adding and removing rows are not cell edits and have no
  cell to double-click. The query line is their route.
- **No multi-cell or multi-row edit.** One cell, one statement, one confirmation.
- **No Mongo.** The driver's write path is honestly unimplemented; `classify_statement`
  already refuses to call a Mongo statement a mutation for that reason.
- **No copy affordance.** The grid has none today and adding one is not this sub-phase.
- **No change to the gate, the plane, the production block, or `origin`.** Not one of
  them is touched.

---

## 11. Dependency on integer fidelity

**The edit does not depend on it.** The `WHERE` is composed in Go from values that never
crossed into Swift (§4), so a key above 2^53 updates the correct row either way.

**The operator does.** Without `2026-09-13-integer-fidelity-design.md`, a snowflake-keyed
table draws its key column as `9.007199254740992e+15` — so Wakil would be asking someone
to confirm an edit to a row whose identity it is displaying incorrectly directly above
the cell. The plane would show the right `WHERE` and the grid the wrong id, which is a
worse state than either being wrong alone.

It ships first for that reason, and for the one in its own §10: its third symptom — the
agent proposing a mutation against a misread key — is reachable today, with no cell
editing in the product at all.

---

## 12. Verification

Unit tests are where the rules live; the walk is where this is met.

- **The recogniser gets the probe's nineteen shapes as fixtures**, verdict by verdict,
  including the CTE and the aliased expression. Any future shape that is argued about
  gets added here rather than reasoned about.
- **Key discovery against live engines** (`make test-live`): single, composite,
  `WITHOUT ROWID`, no key, a view, a binary key, and a key column whose name needs
  quoting.
- **Escaping round-trips byte-for-byte** for the probe's twelve payloads, per driver,
  including the backslash case that fails today's naive escaper and the NUL that must be
  refused on sqlite.
- **`sortedRows`' permutation** — a sorted result whose keys still pair with their rows,
  which is §4.1's failure and is invisible to every other test.
- **`Editable` is `nil`** for a join, an aggregate, a view, a keyless table, a
  `SELECT` omitting the key, and a `BIT` column is absent from `Columns`.
- **An acceptance runbook**, `docs/wakil/phase-2c-ii-b-acceptance.md`, walked at the
  window. 2c-i's lesson, now this project's most expensive one, restated: six defects
  and two rulings came out of looking at the running thing after 500+ tests were green,
  and 2c-ii's walk found thirteen more. **This sub-phase is not met until it is walked.**

---

## 13. Open question 12, and what the walk must answer

> Is `confirm`-then-Run the right price for changing one cell the operator never wrote a
> statement for?

Nothing in this spec decides it, and nothing may. `writeGate` gates `.mutate` at every
origin, 2b-iii's spec §8 chose one mechanism for both authors on purpose, and the
operator has already paid the cost once on the typed route without complaint (check 10).
What is untested is whether it stays bearable when the statement was composed by a
double-click rather than typed — the one case where the plane is the operator's first
sight of what they are about to run.

**The runbook must ask it explicitly**, and the answer must be recorded as walked
evidence rather than as a preference, the way check 10's was.
