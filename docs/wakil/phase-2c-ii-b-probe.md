# Writing one cell back — a 2c-ii-b probe

**Run:** 2026-09-13 · **Machine:** MacBook Air M3, macOS 26.6.2 · **Engines:** sqlite
(modernc, in-process), MySQL 8 in the `wakil-acc-mysql` container `make test-live`
provisions · **Probe code:** throwaway — five `zz_probe_*_test.go` files in
`internal/wakilcore` and one `swift` scratch file, all deleted after this document was
written.

---

## 1. What prompted it

Decision 20 scopes 2c-ii-b as "small": a second entrance to a `.mutate` path 2c-ii
already opened and already walked. Brainstorming on 2026-09-13 settled three rules
before any of them had been measured —

- a cell is editable only where the pane can name **one table** and **every primary-key
  column is present in the result**;
- the operator's typed text becomes a literal whose form the **column's type** decides,
  with a leading `=` meaning "this is SQL, pass it through";
- the reach is `.table` panes **and** a simple `SELECT`.

— and each of the three rests on something an engine does, not on something anyone can
reason out. 2c-i's lesson, restated for the third time: the cheap moment to be wrong is
now.

**One of the four questions was already answered and is not re-run here.**
`phase-2c-ii-probe.md` §2 measured that declared column types survive `pageWrap`'s
subquery on both engines. Every paged or sorted read is wrapped, so the type-decides
rule would have been dead on arrival otherwise; it is not.

---

## 2. Question 1 — how does a pane learn a table's primary key?

Nothing in the stack knows. `sqlConn.Describe` returns `{name, type}` per column and
no key at all. Two candidate mechanisms per engine, run against eight table shapes.

| Table | sqlite `pragma_table_info` | MySQL `SHOW KEYS` | MySQL `information_schema` |
|---|---|---|---|
| `ints` — single INTEGER PK | `[1] id` | `[1] id` | `[1] id` |
| `comp` — `PRIMARY KEY (b, a)` | `[1] b  [2] a` | `[1] b  [2] a` | `[1] b  [2] a` |
| `nopk` — no key | *(none)* | *(none)* | *(none)* |
| `withoutrowid` — `WITHOUT ROWID` | `[1] k` | — | — |
| `weird` — PK column named ``odd `name`` / `odd "name` | `[1] odd "name` | `` [1] odd `name `` | `` [1] odd `name `` |
| `v1` — a **view** | *(none)* | *(none)* | *(none)* |
| `blobpk` — BLOB/VARBINARY PK | `[1] b` | `[1] b` | `[1] b` |
| `uniq` — `UNIQUE NOT NULL`, no PK | *(none)* | *(none)* | *(none)* |
| `missing` — does not exist | *(none)*, no error | **Error 1146** | *(none)*, no error |

**Composite order is reported and is not the column order.** `comp` is declared
`(a, b, c)` and keyed `(b, a)`; both engines report `b` first. A `WHERE` built in
declaration order would still match — `AND` is commutative — but the ordinal is the
thing that says *which columns*, and it is reported correctly by every mechanism, so
nothing has to guess.

**Both winning mechanisms take a bound parameter, so PK discovery needs no identifier
quoting at all.** sqlite's `pragma_table_info` has a table-valued form —
`SELECT name, pk FROM pragma_table_info(?)` — and MySQL's `information_schema.
KEY_COLUMN_USAGE` is an ordinary table. That is the reason to prefer
`information_schema` over `SHOW KEYS`: `SHOW KEYS FROM <name>` has nowhere to put a
parameter and would have to interpolate the table name through `quoteIdent`, which is
`Describe`'s compromise and does not need repeating when a parameterised route exists.

**A view and a keyless table both answer "no key", which is the answer the editing rule
wants.** Neither is editable, and neither needs a special case: "no primary key
columns" already means "not editable".

**A `UNIQUE NOT NULL` column is not a primary key and is not reported as one.** It would
identify a row just as well. Decision 20 says primary key, and this probe records that
the gap is real and deliberate rather than unnoticed — a `uniq`-shaped table stays
read-only.

**`SHOW KEYS` errors on a missing table and `information_schema` returns nothing.**
Another point to `information_schema`: the "table is gone" case is already
`Describe`'s to report, and a PK lookup that throws a second, differently-worded error
for it is a second thing to handle.

---

## 3. Question 2 — how does a typed value become a literal?

The confirmation plane shows the statement verbatim and `sqlConn.Write` executes
`spec.Raw`, so there is no parameter-binding path anywhere on this route: whatever the
operator confirms is the exact text the engine runs. The literal has to be *rendered*,
and rendering is where a value gets corrupted or gets to be an injection.

### 3.1 A bare literal is a column reference, and both engines take it silently

This is the probe's most important single result.

```
UPDATE tt SET name = secret WHERE id = 1
```

| Engine | `name` afterwards | Error |
|---|---|---|
| sqlite | `"hunter2"` | none |
| MySQL | `"hunter2"` | none |

**The brainstormed rule — "numeric and boolean columns emit a bare literal" — is
therefore wrong and must not be built.** A column named `active`, `count`, `status` or
`id` typed into a cell would not store that word: it would copy another column of the
same row, with no error, no warning, and a confirmation plane showing a statement that
reads perfectly well. That is precisely the "a tool updates the wrong thing" failure
Decision 20's provenance rule exists to prevent, arriving through the value instead of
through the `WHERE`.

### 3.2 Quoting is safe for every type both engines have, with one exception

Each column type given the same typed text twice — bare, then single-quoted:

| Type | bare | quoted |
|---|---|---|
| MySQL `INT`, `BIGINT`, `DECIMAL`, `DOUBLE`, `TINYINT`(bool), `YEAR` | stored | **stored, identical** |
| MySQL `DATE`, `DATETIME`, `TIMESTAMP`, `TIME` | syntax error / `Incorrect date value` | **stored** |
| MySQL `TEXT`, `CHAR`, `VARCHAR`, `BLOB`, `ENUM` | `Unknown column 'hello'` | **stored** |
| MySQL `JSON`, `SET` | syntax error | **stored** |
| MySQL `BIT(1)` | stored | **Error 1406 Data too long** |
| sqlite `INTEGER`, `REAL`, `NUMERIC`, `BOOLEAN`, untyped | stored | **stored, identical** |
| sqlite `TEXT`, `VARCHAR`, `BLOB`, `DATETIME` | error or wrong | **stored** |

**So the rule inverts: always quote, and let the engine coerce.** `'42'` into an `INT`
stores `42`; `'9.99'` into a `DECIMAL(10,2)` stores `9.99`. A quoted literal is never a
column reference, never an injection, and never a syntax error — the one thing it cannot
express is a value for a `BIT` column, which is one narrow type this surface can decline
and send to the query line.

**The column type keeps a job, but it is validation, not quoting** — see §3.4.

**One display artefact worth knowing before the walk finds it.** sqlite `DATETIME`
accepted `'2026-09-13 10:11:12'` and read back as `2026-09-13T10:11:12Z`: modernc's
driver parses a `DATETIME`-affinity column into a `time.Time` and renders it in RFC 3339.
The value is right; the string in the grid after the re-fetch is not the string that was
typed. Nothing here is doing anything wrong, and it will look like something is.

### 3.3 `''`-doubling alone silently corrupts data on MySQL

The same payloads through two escapers, written and read back byte for byte:

| Payload | sqlite, `''` only | MySQL, `''` only | MySQL, `''` + `\\` | MySQL, `''` only, `NO_BACKSLASH_ESCAPES` |
|---|---|---|---|---|
| `O'Brien` | ✅ | ✅ | ✅ | ✅ |
| `x' WHERE 1=1 -- ` | ✅ stored as data | ✅ stored as data | ✅ | ✅ |
| `C:\path\n` | ✅ | ❌ **`C:path` + newline, no error** | ✅ | ✅ |
| `a\nb`, `a\tb`, `café 🚀`, `` a`b ``, `say "hi"`, `` | ✅ | ✅ | ✅ | ✅ |
| `a\x00b` (embedded NUL) | ❌ **syntax error** | ✅ | ✅ | ✅ |

`SELECT @@SESSION.sql_mode` on the container:
`ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION`
— **`NO_BACKSLASH_ESCAPES` is not in MySQL 8's default mode.**

Three things follow.

1. **A dialect-blind escaper corrupts a Windows path with no error.** `C:\path\n`
   becomes `C:path` plus a newline. The operator confirmed a statement whose text
   *contained* the right value and got a different one stored. Escaping therefore
   belongs beside `quoteIdent` — a per-driver function — and not in shared code.
2. **The correct MySQL escaper depends on a server setting Wakil does not control.**
   Doubling the backslash is right under the default mode and *wrong* under
   `NO_BACKSLASH_ESCAPES`, where it would store two. The mode is readable in one query
   on a connection already open (`SELECT @@SESSION.sql_mode`), and
   `hardenMySQLWriteConfig` **replaces** `cfg.Params` wholesale, so no stored DSN can
   set it behind Wakil's back and every pooled session sees the same server default.
3. **A NUL in a typed value is a syntax error on sqlite** — the same truncate-at-NUL
   behaviour `Describe` and `ReadTable` already refuse a table name for, one layer down,
   and it should be refused the same way rather than handed to the engine.

**Hex literals were measured and rejected.** `X'...'` round-tripped every payload on
both engines, mode-independently, NUL included — and on sqlite it stored into a `TEXT`
column with `typeof() = 'blob'`, changing the value's type. It would also put
`SET name = X'4F27427269656E'` in front of an operator being asked to confirm what they
are about to run, which is the one thing the plane exists to prevent.

### 3.4 A wrong value for a numeric column: MySQL refuses, sqlite stores it

`UPDATE nt SET n = <quoted> WHERE id = 1` against an `INTEGER`/`INT` column holding `7`:

| Typed | sqlite | MySQL |
|---|---|---|
| `abc` | **stored `"abc"`, `typeof = text`** | Error 1366, nothing written |
| `` (empty) | **stored `""`, `typeof = text`** | Error 1366, nothing written |
| `7x` | **stored `"7x"`, `typeof = text`** | Error 1265, nothing written |
| `0x10` | **stored `"0x10"`, `typeof = text`** | Error 1265, nothing written |
| ` 8 ` | stored `8`, `typeof = integer` | stored `8` |

**This is the job the column type keeps.** sqlite's type affinity accepts a string into
an `INTEGER` column and stores it as text — a cell that reads `7` becomes a cell that
reads `abc`, and the next numeric comparison against that column quietly stops working.
MySQL under `STRICT_TRANS_TABLES` refuses, which is the correct outcome but arrives as a
round trip and an engine error message rather than as a refusal the operator can read.
Validating the typed text against the column's reported type **before composing** gives
both engines the same behaviour and gives the operator the sentence, not the engine.

---

## 4. Question 3 — a primary-key value cannot round-trip through Swift

Not on the original list. Found while tracing where the `WHERE` term's value comes from.

A large-integer key, through the real `collectRows` path and `encoding/json`:

```
sqlite BIGINT pk on wire: [[9007199254740993,"x"]]   (go type int64)
mysql  BIGINT pk on wire: [[9007199254740993,"x"]]   (go type int64)
```

`JSONValue` (`JSONRPC.swift:132`) has one numeric case, `case number(Double)`, and its
decoder tries `Double` before `String`. Measured in Swift:

```
decoded: 9007199254740992   Int64(arr[0]) = 9007199254740992
```

**Swift receives 9007199254740992 for a row whose key is 9007199254740993.** Both
engines. An `UPDATE … WHERE id = 9007199254740992` composed from that value updates a
different row, or none — and the plane would show the wrong number to confirm, so even
a careful operator is being asked the wrong question. `PaneCell` already documents the
same 1e15 boundary for *display*; this is the same boundary doing damage on the way
back.

It is reachable: snowflake ids, Twitter-style ids, `BIGINT UNSIGNED` counters and any
key above 2^53 are ordinary. **The design must not send a key value back as a number
through Swift.** The options are for the spec to choose between, and this probe only
establishes that choosing is required:

- have Go emit an opaque per-row key string alongside the rows, which Swift echoes back
  without interpreting;
- give `JSONValue` an integer case and decode `Int64` before `Double`;
- send the key as a string and re-render it in Go against the key column's own type.

---

## 5. Question 4 — what must a "one named table" recogniser refuse?

Nineteen shapes run against sqlite, against a table `events(id PK, kind, secret)`.

| Shape | Result columns | Verdict for editing |
|---|---|---|
| `SELECT * FROM events` | `id kind secret` | **editable** |
| `SELECT * FROM events e` | `id kind secret` | **editable** — alias must be stripped, not treated as the table |
| `SELECT e.* FROM events AS e` | `id kind secret` | **editable** |
| `SELECT * FROM "events"` | `id kind secret` | **editable** — quoted name must be unquoted |
| `SELECT * FROM events;` | `id kind secret` | **editable** — the gate already permits one trailing `;` |
| `SELECT * FROM /*x*/ events` | `id kind secret` | **editable** — comments already stripped by `stripSQLComments` |
| `SELECT id AS ident, kind FROM events` | `ident kind` | refuse — PK not present *under its own name* |
| `SELECT kind FROM events` | `kind` | refuse — PK absent |
| `SELECT id, id, kind FROM events` | `id id kind` | refuse — a duplicate result name has no single column to write |
| `SELECT id, kind \|\| '!' AS kind FROM events` | `id kind` | **refuse — and this one is the trap** |
| `WITH events AS (SELECT 1 AS id, 'z' AS kind) SELECT * FROM events` | `id kind` | **refuse — and this one is worse** |
| `SELECT * FROM events JOIN users ON …` | 5 cols, two `id` | refuse |
| `SELECT * FROM events, users` | 5 cols | refuse |
| `SELECT * FROM (SELECT id, kind FROM events) x` | `id kind` | refuse |
| `SELECT DISTINCT kind FROM events` | `kind` | refuse |
| `SELECT kind, count(*) n FROM events GROUP BY kind` | `kind n` | refuse |
| `SELECT id, kind FROM events UNION SELECT id, name FROM users` | `id kind` | refuse |
| `SELECT id, row_number() OVER () rn FROM events` | `id rn` | refuse |
| `SELECT * FROM (VALUES (1,2))` | `column1 column2` | refuse |

**The CTE is the dangerous one.** `WITH events AS (…) SELECT * FROM events` returns
columns named `id` and `kind`, and a recogniser that reads the last `FROM <name>` calls
it table `events`, looks up `events`' real primary key, finds `id`, and declares the
result editable. The operator then edits a row that came from a literal in their own
`WITH` clause, and the `UPDATE` **writes to the real `events` table**, to a row that was
never on screen. Refusing any statement containing a `WITH` token closes it; nothing
subtler is needed, because a CTE cannot appear anywhere in a statement this recogniser
would otherwise accept.

**The expression column is the quiet one.** `SELECT id, kind || '!' AS kind` produces a
result column named `kind` that is not the table's `kind`. Editing it composes
`SET kind = …` against the real column, so the operator edits a derived value and
silently overwrites the source. Requiring **every** selected item to be a bare
identifier — or `*`, or `<alias>.*` — is what stops it, and it is the same rule that
already drops the `AS ident` case.

**Cross-schema names defeat the PK lookup.** With a `wakilprobe2.events` keyed on `eid`
and a `wakilacc.events` keyed on `id`, the parameterised lookup scoped to `DATABASE()`
answers `id` for the bare name `events` — so `SELECT * FROM wakilprobe2.events` would be
told its key is a column it does not have. A qualified table name must be refused, which
is also consistent with the pane's database being part of its identity.

**The accepted shape, stated once:**

> `SELECT` — with no `DISTINCT` — of `*`, `<alias>.*`, or a list of bare identifiers,
> `FROM` exactly one unqualified table name with an optional alias, followed by nothing
> but `WHERE` / `ORDER BY` / `LIMIT` / `OFFSET`. No `WITH`, no join of any spelling, no
> subquery in `FROM`, no `GROUP BY`, `HAVING`, `UNION`, `INTERSECT`, `EXCEPT` or window
> function. Duplicate result column names refuse. The table must have primary-key
> columns and every one of them must appear in the result under its own name.

A `WHERE` clause containing a subquery is *not* refused by that rule and does not need
to be: the rows still come from the one named table, and the key still identifies them.

---

## 6. What this changes before a line of the spec is written

1. **"Numeric columns emit a bare literal" is deleted.** A bare literal is a column
   reference on both engines and both engines take it silently (§3.1). Every value is
   quoted; the leading `=` stays the only route to unquoted SQL, and it is the operator
   asking for it in so many words.
2. **The column type moves from deciding the quoting to validating the text** (§3.4),
   because sqlite will store `abc` in an `INTEGER` column and MySQL will refuse it — and
   one refusal the operator can read beats two engine behaviours.
3. **Literal escaping is per-driver, beside `quoteIdent`** (§3.3): sqlite doubles the
   quote and refuses a NUL; MySQL doubles the quote and doubles the backslash **unless
   the session's `sql_mode` carries `NO_BACKSLASH_ESCAPES`**, which has to be read at
   connect rather than assumed.
4. **`BIT` columns are not editable from the grid.** The one type a quoted literal
   cannot express (§3.2).
5. **A key value must not cross into Swift as a JSON number** (§4). Unresolved by
   design, flagged for the spec, and not optional.
6. **PK discovery is a new per-driver capability with a parameterised query on both
   engines** (§2) — `pragma_table_info(?)` and `information_schema.KEY_COLUMN_USAGE`
   — needing no identifier quoting and reporting composite order correctly.
7. **The recogniser must refuse `WITH` outright and require every selected item to be a
   bare identifier** (§5). Both hazards produce a well-formed, confirmable `UPDATE`
   against the wrong data.
