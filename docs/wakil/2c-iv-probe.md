# A request built of parts — the 2c-iv probe

**Run:** 2026-09-22, **with §5.4 added 2026-09-23** · **Machine:** Apple M3, macOS 27.0,
Go 1.27.1 darwin/arm64 · **Engines:** sqlite (modernc.org/sqlite v1.58.0, in-process);
MySQL 8 and Mongo 7 in Docker, **run 2026-09-23** — §5.4, and §7 for why they did not run
the first time · **MCP:** `github.com/modelcontextprotocol/go-sdk` v1.7.0 ·
**Probe code:** throwaway — `zz_probe_2civ_*_test.go` files in `internal/wakilcore`,
`cmd/wakil-http` and `cmd/wakil-db`, all deleted after this document was written.

Pre-registered as [#179](https://github.com/yehia-khalil/rafiq/issues/179)'s *Further
Notes* table: five measurements, each with what it would falsify booked **before** it was
run. A measurement with no ruling attached is a curiosity.

**Per `workflow.md`, where this probe and the spec disagree, the probe governs.** §8
lists the contradictions, which are commented onto #179 and corrected in its body before
`/to-tickets`.

---

## 1. What prompted it

Nineteen rulings closed 2c-iv's map, and four of them rest on something a process does
rather than on something anyone can reason out: whether one stdio pipe carries two panes'
sends at once, how large a frame a capped response actually produces, whether the write
path has a cliff, and **what a database cell is by the time a bound value can be made
from it**.

The fourth is the one that can kill a ruling rather than fill a hole, and it did.

---

## 2. Measurement 1 — do two panes' sends serialise over one `wakil-http` pipe?

**Booked by [#114](https://github.com/yehia-khalil/rafiq/issues/114). Falsifies the
per-window client lifecycle itself:** if a slow request in one pane freezes every other
pane's send, the client becomes per-pane or gains a multiplexer.

Run against **the shipped binary** — `go build`, spawned as a subprocess, spoken to in
newline-delimited JSON-RPC over its real stdin and stdout. An in-process `newServer()`
would have measured the handler and not the transport, and the transport is the question.

Two `tools/call` frames down one pipe: a `GET` against an endpoint that sleeps 1500 ms,
then 80 ms later a `GET` against one that returns immediately.

| Request | id | Reply arrived |
|---|---|---|
| fast | 2 | **80 ms** |
| slow | 1 | **1.51 s** |

**Concurrent, and the ruling stands.** The fast reply overtook the slow one by 1.43
seconds. One slow send does not freeze another pane, so #114's eager per-window client
needs no multiplexer and does not become per-pane.

**A second fact, free and load-bearing: replies come back OUT OF ORDER.** id 2 was
written to the pipe before id 1. Nothing in the pane may assume reply order, and nothing
does — `MCPClient` matches on a `pending: [Int: PendingRequest]` map keyed by request id
(`MCPClient.swift:108`), which is exactly what this measurement makes necessary rather
than merely tidy. Recorded because a future reader optimising that map into a queue would
be removing the thing this line proves is needed.

---

## 3. Measurement 2 — where does the response body ceiling go?

**Booked by [#118](https://github.com/yehia-khalil/rafiq/issues/118). Falsifies nothing
outright — it fills a hole the map deliberately left.** `FrameReader` latches
`frameTooLarge` **permanently** above 4 MiB (`JSONRPC.swift:374`, `:411-417`) rather than
truncating, so the client does not recover, it dies.

**The size that matters is not the body's — it is the FRAME the body produces**, because
the frame is what `FrameReader` buffers. Measured across three content kinds, at the
shipped `httpBodyCap` of 64 KiB (`httpclient.go:37`):

| Body content | Upstream | Frame bytes | Truncated | Expansion | Frame ÷ 4 MiB |
|---|---|---|---|---|---|
| JSON (ASCII, quotes, braces) | 1 KiB | 3,269 | no | 3.2× | 0.001 |
| JSON | 64 KiB | **183,883** | yes | **2.8×** | 0.044 |
| JSON | 1 MiB | 183,883 | yes | 2.8× | 0.044 |
| plain ASCII | 64 KiB | 131,419 | no | **2.0×** | 0.031 |
| plain ASCII | 1 MiB | 131,455 | yes | 2.0× | 0.031 |
| NUL bytes (worst case) | 64 KiB | **852,313** | no | **13.0×** | **0.203** |
| NUL bytes | 1 MiB | 852,349 | yes | 13.0× | 0.203 |

**The body crosses TWICE in every frame** — once escaped into `content[0].text`, once
into `structuredContent.body` — which is where two of those two-point-something multiples
come from. The rest is JSON string escaping, and a NUL costs six bytes as `\u0000`.

**The cap is safe, and the headroom is 5×, not 64×.** At 64 KiB the worst frame this
probe could construct is 0.203 of the latch. That is comfortable, and it is a much
smaller margin than the bare numbers 64 KiB and 4 MiB suggest, because nobody reading
those two numbers would expect a factor of thirteen between them.

**What a cap could be raised to**, if #118 ever wants one, before the frame reaches the
latch:

| At this expansion | A body cap of | yields a 4 MiB frame |
|---|---|---|
| 2.8× (realistic JSON) | ~1.4 MiB | at the latch |
| 13.0× (pathological) | **315 KiB** | at the latch |

**Ruling this fills:** the response cap may be raised as far as **256 KiB** with the
pathological factor still inside the latch, and `TestHTTPBodyCapDefaultIsProductionValue`
should move with it if it is. **It is not recommended here**, because nothing measured
says 64 KiB is too small — that is a question about what an operator needs to see, not
about what the pipe can carry, and the pane draws the whole body the transport delivered
either way.

---

## 4. Measurement 3 — where does an outbound body stop being carryable?

**Booked by [#116](https://github.com/yehia-khalil/rafiq/issues/116). Falsifies #116's
silence on size.** The 4 MiB latch faces **inbound only**; the write path is uncapped. If
the outbound path has a cliff, the pane owes a refusal *before* the gate rather than a
hang after it.

`doRequest` has no body at all today, so the only half that exists to measure is the
pipe. Payload carried in a header value, which the shipped tool already accepts.

| Payload | Frame bytes | Outcome |
|---|---|---|
| 1 KiB | 1,168 | frame crossed; HTTP 200 |
| 64 KiB | 65,680 | frame crossed; HTTP 200 |
| 1 MiB | 1,048,720 | frame crossed; HTTP 200 |
| 4 MiB | 4,194,448 | frame crossed; **HTTP 431** |
| 16 MiB | 16,777,360 | frame crossed; HTTP 431 |
| **64 MiB** | **67,109,008** | **frame crossed**; HTTP 431 |

**No cliff on the pipe below 64 MiB**, and the whole sweep ran in 1.9 seconds. The SDK
and the pipe carry a 64 MiB `tools/call` without refusing, truncating or hanging.

**The 431 is not Wakil's and must not be read as one.** It is `net/http`'s default
`MaxHeaderBytes` of 1 MiB **on the upstream test server**, refusing an oversized *header*.
A body is not a header, so it bounds nothing here. The two layers are reported separately
above precisely so this is not mistaken for a Wakil limit.

**Ruling this fills, and it inverts what the booking expected.** #116 owes a refusal
*before* the gate not because the outbound path has a cliff but **because it has none**:
a 64 MiB body crosses silently, is held in full in three processes, and nothing anywhere
says no. The honest options are a stated outbound cap with a refusal joining the one
aggregate, or an accepted cost written down. **A cap is recommended**, on the ground
`Truncated` already establishes: a limit nobody is told about is the failure, and here
there is not even a limit.

---

## 5. Measurement 4 — what does a cell actually arrive as?

**Booked by [#116](https://github.com/yehia-khalil/rafiq/issues/116). Falsifies #116
ruling 3 outright, and through it #112's *type and exact lexical form*.** The one item on
the table that can kill a ruling rather than fill a hole.

The ruling, in its own words:

> A part carries the source cell's **declared type and its exact lexical form**; quoting
> is decided at **emit**. A `DECIMAL` arrives from the driver as the *string* `"19.90"`,
> so an arrived-type rule would emit it into a JSON number position as a quoted string,
> and a `float64` would print `19.9` — which is why *type* **and** *exact lexical form*
> are both needed.

### 5.1 What arrives, on sqlite

`SELECT *` over a table declaring eleven types, the row inserted with `'19.90'` as a
**string literal** into the `DECIMAL` column:

| Column | Declared | Arrives as | Prints as |
|---|---|---|---|
| `c_int` | `INTEGER` | `int64` | `42` |
| `c_bigint` | `BIGINT` | `int64` | `9007199254740993` |
| **`c_decimal`** | **`DECIMAL(10,2)`** | **`float64`** | **`19.9`** |
| `c_numeric` | `NUMERIC` | `float64` | `0.1` |
| `c_real` | `REAL` | `float64` | `19.9` |
| `c_text` | `TEXT` | `string` | `plain` |
| `c_bool` | `BOOLEAN` | `int64` | `1` |
| `c_date` | `DATE` | **`time.Time`** | `2026-09-22 00:00:00 +0000 UTC` |
| `c_datetime` | `DATETIME` | `time.Time` | `2026-09-22 14:22:07 +0000 UTC` |
| `c_blob` | `BLOB` | `string` | *(4 raw bytes)* |
| `c_null` | `TEXT` | `<nil>` | `<nil>` |

**A `DECIMAL` does not arrive as a string. It arrives as `float64 19.9`, and the exact
lexical form is already gone before Wakil sees the value at all.** Re-run with the value
inserted as the numeric literal `19.90` rather than the string `'19.90'`: **also
`float64 19.9`**. There is no way to store a `DECIMAL` in sqlite and read back `"19.90"` —
`DECIMAL` carries NUMERIC affinity, so the engine converts at INSERT, and the loss is
sqlite's, not the driver's and not Wakil's.

### 5.2 What the pane receives, which is what actually decides this

A bound value is made in **Swift**, and Swift never sees a Go value. It sees the JSON
`Rows` marshals to. The wire, measured:

```json
{"columns":["c_decimal","c_bigint","c_bool","c_date","c_blob","c_null","c_text"],
 "columnTypes":["DECIMAL(10,2)","BIGINT","BOOLEAN","DATE","BLOB","TEXT","TEXT"],
 "columnTypesInferred":false,
 "rows":[[19.9,9007199254740993,1,"2026-09-22T00:00:00Z","ޭ��",null,"19.90"]],
 "millis":0,"pageable":true,"listsTables":false}
```

Five things in that one line, and only the first is the booked falsification:

1. **`DECIMAL(10,2)` → the JSON number `19.9`.** The declared type survives; the lexical
   form does not exist to survive. **#116 ruling 3 is falsified as written.**
2. **`BOOLEAN` → the JSON number `1`**, not `true`. A bound value in a JSON boolean
   position must map 1/0 through the declared type; there is no bool on the wire.
3. **`DATE` → the string `"2026-09-22T00:00:00Z"`.** A date cell becomes a full RFC 3339
   *timestamp*. Bound into a path segment it emits `2026-09-22T00%3A00%3A00Z`, which is
   not what any API's docs write, and the operator never typed it.
4. **`BLOB` → silently corrupted, unrecoverably.** Proven byte for byte: stored
   `DE AD BE EF` (4 bytes), arrives in Go as those same 4 bytes, and the JSON encoder —
   which must emit valid UTF-8 — replaces the invalid run, so the value read back is
   `DE AD EF BF BD EF BF BD` (8 bytes). **Not recoverable.** This is true of the DB pane
   today and is not 2c-iv's to fix, but a bound value makes it reachable by a *send*.
5. **`TEXT "19.90"` → `"19.90"`.** The lexical form survives wherever the column's
   affinity leaves it alone. The rule is not about DECIMAL; it is about affinity.

> ⚠️ ***The next paragraph is WRONG and is kept only because #179 cites it.*** Measured
> again on 2026-09-23 **through the shipped `wakil-db` binary** rather than through an
> in-process `json.Marshal`, `BIGINT` arrives as **`9007199254740992`** on all three
> drivers. The loss is in the MCP SDK's `applySchema`, in Go, before Swift. **§5.4 finding
> (c) and §8 row 9 carry it.** The wire line quoted just above is the in-process marshal,
> not what leaves the process.

~~**`BIGINT` is correct and is NOT a finding.**~~ `9007199254740993` crosses the wire intact,
and Swift decodes it exactly because `JSONValue.integer(Int64)` is tried before `Double`
— found, measured and fixed on 2026-09-13 (`integer-fidelity-design.md`,
`phase-2c-ii-b-probe.md` §4). **It is the precedent this finding should be read against,
and it is also why the same repair does not transfer:** integer fidelity was lost in
Swift's *decoder* and was recoverable there. The decimal is lost in the *engine*, two
processes earlier, and no Swift change can reach it.

### 5.3 What this rules

**#116 ruling 3's premise is false, and its conclusion is half right.** *Declared type*
is real, published, and enough to decide quoting: `columnTypes` carries `DECIMAL(10,2)`
truthfully whatever the value became. *Exact lexical form* is **not a thing a part can
carry**, because for the numeric affinities there is no lexical form left by the time any
Wakil code runs.

**What replaces it, stated so `/to-tickets` does not re-derive it.** A part carries the
cell's **declared type** and **the JSON token the pane received** — which for a numeric
affinity is a number and for everything else is a string. Emit then decides quoting from
the declared type, exactly as ruled. What is given up is the promise that
`DECIMAL "19.90"` reaches the wire as `19.90` rather than `19.9`; on sqlite that promise
was never keepable. ~~**Whether it is keepable on MySQL is the open half** — see §7.~~
***Measured 2026-09-23: it IS keepable on MySQL and on Mongo, and the correction is
therefore PER-DRIVER. See §5.4.*** The replacement rule above survives that unchanged —
the JSON token carries the difference, so no emit-path driver branch is needed for the
decimal. The boolean is the one place a branch is unavoidable.

**One consequence worth naming now:** a `float64` round-trip is lossy in a second way the
ruling did not reach. `19.90` and `19.9` are the same number but not the same *price*,
and an API that echoes a price back will disagree with the request. That is an argument
for the pane saying what it is sending, not for a lexical form it cannot have.

### 5.4 The other two engines — MySQL and Mongo

**Run 2026-09-23**, closing the gap §7 left open. Same machine, same Go; engines
`mysql:8` and `mongo:7` in the two containers `test-live` names, on 13306 and 27018.
**Booked by [#184](https://github.com/yehia-khalil/rafiq/issues/184)**, whose question was
not whether #116 ruling 3 falls — §5.3 already did that — but **how wide the correction
is**.

**The engine was the whole obstacle and it is worth recording how it moved.** OrbStack's
socket returned `EOF` on 2026-09-22 and still did on 2026-09-23: `orbctl start` answered
*"OrbStack is already running. Docker engine is ready to use."* while `docker info`, `orbctl
status` and `orbctl list` all hung or returned `EOF`. **`orbctl stop` followed by `orbctl
start` cleared it in under a minute.** The daemon was wedged, not absent, and the tool that
reports on it was reporting on itself.

**Two reasons the retired spike could never have run, both of which had to be fixed before
anything was measured.** It read `LIVE_MYSQL_DSN` / `LIVE_MONGO_URI`; `test-live` exports
`WAKIL_MYSQL_DSN` / `WAKIL_MONGO_URI`. And its names — `TestProbeCellArrival*` — do not
match `LIVE_TESTS = TestMySQL|TestMongo|TestHardenMySQLConfig`, so the target would not have
selected them at all. Either one alone produces a green `test-live` that measured nothing,
which is the exact failure the target's skip check exists to catch and which the skip check
cannot catch, because a test that is never *selected* never *skips*. §7's instruction is
corrected below.

**Measured on the shipped binary.** `go build ./cmd/wakil-db`, spawned as a subprocess,
spoken to in newline-delimited JSON-RPC over its real stdin and stdout, credentials served
by a fake `security` on `PATH` so no Keychain is touched. The bytes below are the
`structuredContent` of the `query` reply **as they came off the pipe** — which is what
`MCPClient` hands Swift's decoder and the only thing a bound value can be made from. The
in-process `Read` → `json.Marshal(Rows)` of §5.2 was run alongside it and **the two do not
agree**; see the last finding in this section.

#### MySQL 8, `go-sql-driver` — through the shipped binary

```
{"columnTypes":["DECIMAL","DATE","TINYINT","BLOB","BIGINT"],
 "columnTypesInferred":false,
 "columns":["c_decimal","c_date","c_bool","c_blob","c_bigint"],
 "listsTables":false,"millis":1,"pageable":true,
 "rows":[["19.90","2026-09-22",1,"ޭ��",9007199254740992]]}
```

| Column | DDL | `columnTypes` | Go type | JSON token | Token bytes |
|---|---|---|---|---|---|
| `c_decimal` | `DECIMAL(10,2)` | `DECIMAL` | **`string`** | **`"19.90"`** | `22 31 39 2E 39 30 22` |
| `c_date` | `DATE` | `DATE` | **`string`** | **`"2026-09-22"`** | `22 32 30 32 36 2D 30 39 2D 32 32 22` |
| `c_bool` | `BOOLEAN` | **`TINYINT`** | `int64` | `1` | `31` |
| `c_blob` | `BLOB` | `BLOB` | `string` | *(8 bytes)* | `22 DE AD EF BF BD EF BF BD 22` |
| `c_bigint` | `BIGINT` | `BIGINT` | `int64` | **`9007199254740992`** | `39 30 30 37 31 39 39 32 35 34 37 34 30 39 39 32` |

**1. `DECIMAL` DOES arrive as the string `"19.90"` on MySQL.** Five payload bytes,
`31 39 2E 39 30`, inserted as the *numeric literal* `19.90` and not as a quoted string, so
the trailing zero survived the engine rather than a quoting accident. MySQL's `DECIMAL` is
real fixed-point, `go-sql-driver` hands it back as `[]byte`, and `collectRows`
(`sqlconn.go`) turns `[]byte` into `string`. **#116 ruling 3's sentence is TRUE here and
FALSE on sqlite, measured, on the same day, through the same code. The correction is
PER-DRIVER.**

**2. `DATE` is not what sqlite's `DATE` is.** sqlite gave the RFC 3339 *timestamp*
`"2026-09-22T00:00:00Z"`; MySQL gives the date `"2026-09-22"`, ten bytes, no time and no
zone. Both are strings, neither is the other, and §5.2's finding 3 — which #179 restated as
a rule — describes only sqlite. `parseTime` is off (`hardenMySQLConfig` replaces
`cfg.Params` wholesale and never sets it), so the driver never builds a `time.Time` and the
server's own rendering crosses intact.

**3. `BOOLEAN` is gone by the time `columnTypes` is written.** MySQL's `BOOLEAN` is a
synonym: the DDL spelling is erased at `CREATE TABLE` and `DatabaseTypeName()` reports
**`TINYINT`**, indistinguishable from a real `TINYINT` column holding 1. **An emit rule
that maps 1/0 "through the declared type" — which is what §5.3's replacement rule says and
what #179 restates — cannot be written for MySQL, because on MySQL there is no declared
`BOOLEAN` to key it on.** The same statement on sqlite has a `BOOLEAN` to read. Per-driver
again, and this one is not a difference of outcome but a difference in whether the rule is
*expressible*.

**4. `DECIMAL(10,2)` loses its scale.** sqlite publishes `DECIMAL(10,2)`; MySQL publishes
`DECIMAL`. The declared-type string is not comparable across drivers even where both
drivers declare.

**5. `BLOB` corrupts identically to sqlite, and that one IS universal.** Stored
`DE AD BE EF`; on the wire `DE AD EF BF BD EF BF BD`, eight bytes for four, unrecoverable,
for the reason §5.2 gives. Two drivers, same result.

#### MongoDB 7, `mongo-driver/v2` — through the shipped binary

The collection declares nothing. Two documents, one field (`c_null`) null in both.

```
{"columnTypes":["bson.ObjectID","array","bson.Binary","bool","bson.DateTime",
                "bson.Decimal128","bson.D","double","int","int","","string"],
 "columnTypesInferred":true,
 "columns":["_id","c_array","c_binary","c_bool","c_date","c_decimal128",
            "c_doc","c_double","c_int32","c_int64","c_null","c_string"],
 "listsTables":false,"millis":1,"pageable":true,
 "rows":[["6ab36879256415ec561baaa8",[1,2],{"Data":"3q2+7w==","Subtype":0},true,
          "2026-09-22T14:22:07Z","19.90",{"a":1},19.9,42,9007199254740992,null,"19.90"]]}
```

| Column | Stored | `columnTypes` | Go type | JSON token | Emittable? |
|---|---|---|---|---|---|
| `c_decimal128` | `Decimal128("19.90")` | `bson.Decimal128` | `bson.Decimal128` | **`"19.90"`** (`31 39 2E 39 30`) | scalar |
| `c_double` | `19.90` | `double` | `float64` | `19.9` | scalar |
| `c_bool` | `true` | `bool` | `bool` | **`true`** (`74 72 75 65`) | scalar |
| `c_date` | 2026-09-22T14:22:07Z | `bson.DateTime` | `bson.DateTime` | `"2026-09-22T14:22:07Z"` | scalar |
| `c_string` | `"19.90"` | `string` | `string` | `"19.90"` | scalar |
| `c_int32` | `int32(42)` | `int` | `int32` | `42` | scalar |
| `c_int64` | `9007199254740993` | `int` | `int64` | **`9007199254740992`** | scalar, **wrong** |
| `_id` | ObjectID | `bson.ObjectID` | `bson.ObjectID` | `"6ab36879256415ec561baaa8"` | scalar |
| `c_binary` | `DE AD BE EF` | `bson.Binary` | `bson.Binary` | **`{"Data":"3q2+7w==","Subtype":0}`** | **no — object** |
| `c_array` | `[1,2]` | `array` | `bson.A` | `[1,2]` | **no — array** |
| `c_doc` | `{a:1}` | `bson.D` | `bson.D` | `{"a":1}` | **no — object** |
| `c_null` | null in every doc | **`""`** | `<nil>` | **`null`** (`6E 75 6C 6C`) | **no — no value** |

**6. The all-NULL column reports the empty string, as the probe's note said, and `null` as
its value.** `columnTypes[10]` is two quote bytes, `22 22`. There is no type *and* no value,
and the second is the harder of the two: a bound value has nothing to emit.

**7. Mongo's inferred type names are not database types — they are Go type names, half the
time.** `bool`, `int`, `double`, `string` and `array` are BSON names; `bson.ObjectID`,
`bson.Binary`, `bson.DateTime`, `bson.Decimal128` and `bson.D` are `%T` output, from
`inferMongoType`'s default branch. A reader cannot key an emit rule on this string the way
it can on `DECIMAL`. Worth naming separately: **`inferMongoType`'s `case time.Time: return
"date"` is dead on the live path** — the driver hands back `bson.DateTime`, never
`time.Time`, so no Mongo date is ever annotated `date`.

**8. Mongo is the only driver that produces a real JSON boolean.** `true`, not `1`. §5.2's
finding 2 ("there is no bool on the wire") is a sqlite and MySQL statement, not a universal
one.

**9. Mongo's binary is NOT corrupted — it is base64, losslessly.** `3q2+7w==` decodes to
exactly `DE AD BE EF`, verified. The `BLOB` corruption of §5.2 finding 4 is a *string*
problem, and Mongo is the driver that does not put binary in a string. **A blanket "a part
whose source column is a binary type refuses" — which is what #179 now says — refuses a
Mongo binary whose bytes are intact.** It should still refuse, but for the reason that
applies: the token is a JSON *object*, and no scalar position can take one.

**10. The inferred type is a property of the PAGE, not of the column.** Measured
separately, and it decides the shape of the Mongo answer. `docsToRows` takes the first
non-nil value **in the rows it returns**. A collection whose `c_maybe` is null in document 1
and `"19.90"` in document 2:

```
limit=1 → "columnTypes":["bson.ObjectID","","int"]        ← the empty string
limit=2 → "columnTypes":["bson.ObjectID","string","int"]  ← same column, same data
```

A **live** bound value re-resolves against its source pane's current rows. So on Mongo the
annotation a part carries can change between two sends with no data change at all — the
operator need only have paged.

#### 5.4.1 What this rules

**(a) The emit correction is PER-DRIVER, and it is per-driver in three separate ways.**
Not one behaviour with two outcomes:

1. **Outcome differs.** `DECIMAL` → the string `"19.90"` on MySQL, the number `19.9` on
   sqlite, the string `"19.90"` on Mongo (`Decimal128`). MySQL and Mongo keep the lexical
   form; sqlite destroyed it at INSERT.
2. **The annotation differs.** `DECIMAL(10,2)` (sqlite) vs `DECIMAL` (MySQL) vs
   `bson.Decimal128` (Mongo). `BOOLEAN` (sqlite) vs `TINYINT` (MySQL) vs `bool` (Mongo).
3. **Expressibility differs.** The boolean rule §5.3 wrote — map 1/0 *through the declared
   type* — is writable on sqlite, **not writable on MySQL** (no `BOOLEAN` survives the
   DDL), and **unnecessary on Mongo** (a real JSON `true` arrives).

**§5.3's replacement rule nevertheless survives, and this is the useful part.** "A part
carries the cell's **declared type** and **the JSON token the pane received**" needs no
per-driver branch for the decimal, because the *token* carries the difference: MySQL hands
over a JSON string and sqlite a JSON number, and an emit that writes the token into a JSON
number position unquoted produces `19.90` from MySQL and `19.9` from sqlite — each engine's
own truth, with no driver test in the emit path. **What is per-driver is the outcome, not
the rule.** The boolean is the one place a driver branch is unavoidable.

**What the pane must publish so a reader can tell which of the two it got.** Four things,
per part, and **only three of them exist today**:

- **The declared type string**, verbatim — `columnTypes[i]`. Ships.
- **`columnTypesInferred`** — whether that string is a declaration or a guess. Ships.
- **The JSON token as received, with its JSON type** (string / number / boolean / null /
  array / object). Ships, as the value itself; what does not ship is any statement *about*
  it, so a reader must infer the token's type from the token.
- **The driver kind** — `sqlite`, `mysql`, `mongo`. **Does not ship on a read result.**
  `Rows` has no driver field; `list_databases` carries `DatabaseInfo.Driver` and a read
  result carries nothing. Without it, `DECIMAL` alone cannot tell a reader whether the
  scale was published (`DECIMAL(10,2)`) or dropped (`DECIMAL`), and `TINYINT` cannot be
  told from a `BOOLEAN` that MySQL erased. **A bound value must carry its source pane's
  driver kind, and that is a new field, not a re-reading of an existing one.**

**(b) A Mongo-sourced bound value is ADMITTED, as *captured*, when and only when the
arrived token is a JSON scalar.** Three classes, measured:

- **Admitted** — `string`, `int`, `double`, `bool`, `bson.Decimal128`, `bson.DateTime`,
  `bson.ObjectID`. The token is a JSON string, number or boolean; the part carries it with
  its inferred type and `columnTypesInferred: true`, so the pane states that the type is a
  guess rather than presenting it as a declaration. This confirms #179's stated default.
  **`Decimal128` is the best-behaved decimal of the three engines** — `"19.90"`, lexical
  form intact, from a database with no schema at all.
- **Refused — non-scalar.** `array` → a JSON array, `bson.D` → a JSON object,
  `bson.Binary` → a JSON object. No URL segment, header value or JSON scalar position can
  take one, and flattening it would be the delimiter-parsing #179 exists to avoid. The
  refusal is by **token shape**, not by inferred-type name — the names are `%T` output and
  cannot be enumerated safely.
- **Refused — no value.** The all-NULL column. `null` has no lexical form to emit. The
  empty-string type is a *symptom* here, not the cause: the cause is that the cell is null,
  which is equally true of sqlite's `c_null` and MySQL's `c_null`. **Refusing on "the type
  is empty" would be the wrong rule** — it would admit a null cell in a column whose other
  rows gave it a type, and refuse a non-null cell whose column happens to be untyped on
  this page. **Refuse on the null, not on the empty string.**

**And one condition #179's "admit it with its inferred type" needs that nothing has said.**
Because the inferred type is page-dependent (finding 10), a **live** Mongo binding's
annotation is not stable across a re-page. Either the part **captures the inferred type at
bind time** and re-resolves only the value, or a live Mongo binding must re-state its type
on every send and the pane must show it changing. **The first is the cheaper answer and the
one consistent with `columnTypesInferred` meaning "a guess": a guess pinned at bind time is
honest; a guess that silently changes is not.**

**(c) An unbooked falsification, measured on the shipped path, that nothing here was
looking for: `BIGINT` does NOT cross the wire intact.** §5.2 recorded the opposite —
*"`BIGINT` is correct and is NOT a finding. `9007199254740993` crosses the wire intact"* —
and #179 restates it as the precedent the decimal should be read against. **It was measured
at the wrong boundary.** §5.2 used an in-process `json.Marshal(Rows)`; the shipped binary
emits, for the same value, on all three drivers:

```
sqlite  "rows":[[9007199254740992]]     stored 9007199254740993
mysql   ... ,9007199254740992]]         stored 9007199254740993
mongo   ... ,9007199254740992, ...      stored int64 9007199254740993
```

Byte for byte off the pipe, `39 30 30 37 31 39 39 32 35 34 37 34 30 39 39 32` — and
identically in the `content[0].text` fallback block. The sqlite case is the control: it
needs no engine, and it fails the same way, so **this is not a driver behaviour at all.**

**The mechanism, read out of the SDK.** `mcp/server.go:426` calls
`applySchema(outJSON, outputResolved, true)` before assigning `StructuredContent`.
`applySchema` (`mcp/tool.go:104-140`) unmarshals the marshalled output into a plain `any` —
where every JSON number becomes a `float64` — applies schema defaults, and, because
`appliedDefaults` is true for any object-rooted output, **re-marshals from that `any`.**
The round trip through `float64` is where the integer dies. The key order confirms it:
the binary emits `columnTypes, columnTypesInferred, columns, listsTables, millis, pageable,
rows` — alphabetical, which is `map[string]any` marshalling, not Go struct-field order.

**Why this matters more than it looks.** The 2026-09-13 integer-fidelity work
(`integer-fidelity-design.md`) fixed the loss in **Swift's decoder**, by trying
`JSONValue.integer(Int64)` before `Double`. That repair is intact and is not what failed.
The loss measured here happens **in the Go server, before the bytes are written**, so
Swift's decoder receives `9007199254740992` and decodes it perfectly. **A correct decoder
cannot recover a number that was already rounded upstream** — and every `wakil-db` read of
any id above 2^53 has been silently wrong since the SDK's `applySchema` began re-marshalling.

**It is out of 2c-iv's scope and it must not be folded in.** It is not a parts-model
question, it is not a bound-value question, and it is not this pane's to repair: it affects
every `wakil-db` and `wakil-http` structured result equally. **It needs its own ticket**,
and the repair is in the SDK boundary — a `json.Decoder` with `UseNumber`, or skipping the
re-marshal when defaults changed nothing. Recorded here because this measurement is where
it surfaced and because §5.2 currently tells a reader the opposite.

---

## 6. Measurement 5 — does a captured bound value survive a working session?

**Booked by [#137](https://github.com/yehia-khalil/rafiq/issues/137). Falsifies nothing,
and that is the point.** The accepted cost of #137 ruling 2 is a **rate**: if re-binding
is constant in ordinary use, the answer is a cheaper *gesture*, never a longer lifetime.

**Not run, and an agent cannot run it.** A rate over a normal working session is measured
by working, not by a spike — and the pane it would be measured in does not exist yet.
**It belongs in the acceptance runbook, not here**, as a count the operator keeps during
the walk: how many times a bound value had to be re-bound, against how many sends.

**One thing the logic prototype contributed to it in advance.** Driving the model by hand
showed that a re-bind is only one click **if `api_bind` overwrites a dead binding rather
than only filling a hole** — otherwise it is unbind-then-drop, and #137's stated cost is
understated by half before the rate is even measured. That correction is folded into
#179's §*The eight actions*; the rate question is unaffected and stays open.

---

## 7. What was not run, and what that leaves unestablished

> ~~**MySQL and Mongo halves of measurement 4.** Docker was not reachable on this machine
> during the run — the OrbStack socket returned `EOF` on every attempt — and chasing it was
> judged worse than recording the gap.~~ ***CLOSED 2026-09-23 by
> [#184](https://github.com/yehia-khalil/rafiq/issues/184) — see §5.4.*** `orbctl stop`
> followed by `orbctl start` cleared the wedged socket; both engines came up and both halves
> were measured, on the shipped binary. **The correction is per-driver**, a Mongo-sourced
> bound value **is admitted when its token is a JSON scalar and refused otherwise**, and a
> third thing nobody booked — `BIGINT` — turned out to be broken on the shipped path in a
> way §5.2's in-process measurement could not see. §5.4 carries all of it.
>
> **The command recorded here was wrong in two ways and would have measured nothing.** It
> named `LIVE_MYSQL_DSN` / `LIVE_MONGO_URI`, which `test-live` does not export, and
> `TestProbeCellArrivalMySQL` / `TestProbeCellArrivalMongo`, which its `LIVE_TESTS` pattern
> does not select. **A test that is never selected never skips, so the target's skip check
> cannot catch it.** The working form, for anyone re-running §5.4:
>
> ```
> docker start wakil-acc-mysql wakil-acc-mongo
> WAKIL_MYSQL_DSN='root:rootpw@tcp(127.0.0.1:13306)/wakilacc' \
> WAKIL_MONGO_URI='mongodb://127.0.0.1:27018/wakilacc' \
>   go test ./internal/wakilcore/ -run 'TestMySQLProbe|TestMongoProbe' -count=1 -v
> WAKIL_MYSQL_DSN='…' WAKIL_MONGO_URI='…' \
>   go test ./cmd/wakil-db/ -run 'ProbeWire' -count=1 -v
> ```
>
> with the spikes restored from **this document's own retirement commit's parent** — the
> adapted ones, already on a `TestMySQL`/`TestMongo` prefix and already reading the right
> environment variables. The 2026-09-22 originals are at `75e9fab^` and need both fixes
> before they measure anything.

**Nothing else on this list was closed.** Measurement 5 (§6) is still a rate an agent
cannot measure, and still belongs in the acceptance runbook rather than here.

---

## 8. Contradictions with the spec

Per `workflow.md`: the probe governs, these are commented onto
[#179](https://github.com/yehia-khalil/rafiq/issues/179), and its body is corrected before
`/to-tickets` runs.

| # | Spec says | The probe measured | Disposition |
|---|---|---|---|
| 1 | §*The parts model*: "A `DECIMAL` arrives from the driver as the **string** `19.90`" | `float64 19.9` on sqlite, however it was stored | **Falsified.** The premise is false; *exact lexical form* is unavailable and must be replaced by *the JSON token received*. §5.3 |
| 2 | §*The parts model* is silent on `DATE`, `BOOLEAN` and `BLOB` | `DATE` → an RFC 3339 timestamp string; `BOOLEAN` → the number 1; `BLOB` → **unrecoverably corrupted** | **Three holes, not one.** Each needs an emit rule or a refusal. §5.2 |
| 3 | §*The four data positions* is silent on size | The pipe carries a 64 MiB frame with no refusal | **Confirmed silent, and the silence is the hazard.** An outbound cap is owed. §4 |
| 4 | §*`wakil-http` in the window*: a third `MCPClient`, eager per window | Two sends over one pipe are **concurrent**, replies out of order | **Holds.** No multiplexer, no per-pane client. §2 |
| 5 | #118 left the response ceiling as a hole | 64 KiB yields at most 0.203 of the 4 MiB latch; the body crosses **twice** per frame | **Hole filled.** Headroom is 5×, not 64×. §3 |

**Added 2026-09-23, from §5.4.** Rows 6–9 correct §*The parts model* as the probe itself
left it on 2026-09-22 — three of them contradict a sentence the probe wrote.

| # | Spec says | The probe measured | Disposition |
|---|---|---|---|
| 6 | §*The parts model*, as corrected 2026-09-22: a `BOOLEAN` "arrives as the JSON number `1`, **never** `true`", a `DATE` "arrives as a full RFC 3339 timestamp string" | MySQL: `DATE` → `"2026-09-22"`, no time, no zone; `BOOLEAN` → `columnTypes` says **`TINYINT`**, the spelling is erased at DDL. Mongo: `bool` → **`true`** | **Both restatements are sqlite-only.** The `DATE` rule names a form two of three drivers do not produce; the boolean rule keys on a declared type MySQL does not publish, so it is **not expressible** there. §5.4 |
| 7 | §*The parts model*: "a part whose source column is a **binary type** refuses", because a `BLOB` is corrupted | Mongo's `bson.Binary` → `{"Data":"3q2+7w==","Subtype":0}`, base64, **losslessly** — `3q2+7w==` is exactly `DE AD BE EF` | **Right refusal, wrong reason.** The corruption is a *string* problem and Mongo does not put binary in a string. Refuse on the **token shape** (an object cannot fill a scalar position), which also catches `array` and `bson.D`. §5.4 |
| 8 | §*The parts model*: "Where a driver declares no type, the **arrived type is the authority**… the honest default is to admit it as **captured** with its inferred type" — marked *unmeasured* | Admissible for the seven scalar-token types; **not** for `array`, `bson.D` or `bson.Binary`; **not** for a null cell. And the inferred type is **page-dependent** — the same column reports `""` at limit 1 and `"string"` at limit 2 | **Confirmed, and narrowed twice.** Two refusals the default did not carry, and a live Mongo binding must **pin its inferred type at bind time** or its annotation changes when the operator pages. §5.4 |
| 9 | §5.2 of **this document**, restated by #179: "`BIGINT` is correct and is NOT a finding. `9007199254740993` crosses the wire intact" | The **shipped `wakil-db` binary** emits `9007199254740992` — on sqlite, MySQL and Mongo alike, in `structuredContent` and in the text fallback | **Falsified, and it was the probe's own claim.** §5.2 measured an in-process `json.Marshal(Rows)`; the SDK's `applySchema` re-marshals through `map[string]any`, so the integer dies **in Go, before Swift**. Out of 2c-iv's scope — **needs its own ticket**. §5.4 |

**Nothing here reaches the charter.** Every correction instantiates existing mechanism:
the type annotation `columnTypes` already ships, the aggregate refusal already exists, and
the outbound cap is `Truncated`'s rule applied in the other direction.

**Row 9 is the exception to that sentence, and it is flagged rather than absorbed.** It is
not a 2c-iv correction at all: it is a live defect in every structured result `wakil-db`
and `wakil-http` return, it predates this sub-phase, and folding it into 2c-iv's tickets
would hide a repair that belongs at the MCP boundary.

**And one methodological correction the probe owes itself.** Row 9 exists because §5.2
measured "what the pane receives" with an in-process `json.Marshal`. That is the same
marshal the SDK *starts* from, which is why it looked sufficient — but it is not the last
thing that touches the bytes. **The pane receives what comes off the pipe, and the only
way to measure that is to spawn the binary**, which §2 already did for the transport and
§5.2 did not do for the payload.
