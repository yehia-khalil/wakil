# Phase 2b-iii — the write gate earns a subject

**Date:** 2026-09-09
**Status:** design, approved in brainstorming; not yet implemented
**Predecessors:** `2026-09-07-phase-2a-spine-design.md`,
`2026-09-08-phase-2b-i-structure-design.md`,
`2026-09-09-phase-2b-ii-atmosphere-design.md`,
`2026-09-09-void-as-core-design.md`

---

## 0. Where 2b-iii sits, and what was cut out of it

The north-star's §8 table gives 2b-iii four items — *write-gate UI and the first
`.mutate`, session resume, provider picker, signing* — and one exit criterion: **2a's
acceptance checks 5 and 6 finally run.**

**Only the first item is in this spec.** The other three were split out during
brainstorming on 2026-09-09, for the reason 2b itself was split on 2026-09-08: they are
not one spec. The evidence for each:

| Item | Why it is not here |
|---|---|
| Session resume | A change to the `AgentHarness` protocol and to ⌘P's session list. Shares no type, no file and no test with the gate. |
| Provider picker | Reads a token out of the org's provider record instead of the environment, which means touching the Keychain from Swift for the first time. Its own risk surface entirely. |
| Signing | A build-system change. Also **partly blocked externally**: `security find-identity -v -p codesigning` on the development machine reports exactly one identity, *Apple Development: operator@example.com (4VPUKZC8VD)*. There is no **Developer ID Application** certificate, which is what notarisation and distribution outside the App Store require, and obtaining one needs a paid Apple Developer Program membership. Local signing with entitlements and the hardened runtime is achievable today; notarised distribution is not, and a phase should not ship with a known-unreachable half. |

Those three keep their north-star row and are re-ordered after this one. **Nothing about
them is cancelled by this document** — §11 records them as still owed.

What remains is the item the exit criterion actually names. Checks 5 and 6 have been
"not expressible" since 2026-09-08 for one reason, stated twice in
`phase-2a-acceptance.md`: *there is no `.mutate` action to gate, so any script written
today would pass for the wrong reason.* This spec builds the subject.

---

## 1. Scope

**In:**

1. A writable database path in `internal/wakilcore`, reached by a **separate credential**
   and a **separate code path** from the read path.
2. `AssertSQLMutation` — a mutation gate allowing exactly `INSERT`, `UPDATE`, `DELETE`.
3. A `mutate` tool on `wakil-db`.
4. `db_run_mutation` — the first `ActionKind.mutate` action Wakil has ever registered.
5. The pending-confirmation surface: an agent-proposed mutation parks, the operator
   types, the parked call runs.
6. The additions to `phase-2a-acceptance.md` that make checks 5 and 6 runnable, and a
   `phase-2b-iii-acceptance.md` runbook.

**Out, and recorded in §11 as owed rather than dropped:** Mongo mutation, DDL of any
kind, a stronger confirmation token, a fifth `CoreState`, and the three items §0 split
out.

---

## 2. The rule the whole sub-phase rests on

> **The read path does not learn about writing.**

Not "the read path stays correct if a flag threads through it properly" — the read path
is not edited at all. `OpenDatabase`, `DbDriver.Connect`, `hardenMySQLConfig`,
`sqliteReadOnlyDSN` and `sqlConn.gate` are untouched by this phase.

This is not caution for its own sake. Four separate doc comments in the current tree
promise it in almost these words — `dbresolve.go:43-47` ("every driver's read-only gate
is unconditional — it does not, and must not, depend on this flag"),
`driver_mysql.go:68-75`, `driver_sqlite.go:38-46`, and `driver_mongo.go:24-39`. A
`Connect(readOnly:)` parameter would falsify all four at once, and would put the read
path's safety at the mercy of a boolean's plumbing. A second function cannot do that: a
bug in `ConnectWritable` produces a broken *write*, never a loosened read.

`Connection.ReadOnly` and `Database.ReadOnly` stay exactly as they are — carried,
inert, and documented as inert. This phase does **not** make them load-bearing. They
were considered as the seam and rejected for the reason above.

---

## 3. Write authority is a credential, not a flag

`Database` gains one field:

```go
type Database struct {
    Name     string `json:"name"`
    Driver   string `json:"driver"`
    Ref      string `json:"ref"`
    WriteRef string `json:"writeRef,omitempty"`
    ReadOnly bool   `json:"readOnly,omitempty"`
}
```

**No `writeRef` → that database cannot be mutated by anything, by anyone, ever.** Not by
the agent, not by the operator, not by `--dispatch`. That is Invariant 6 ("read-only
until a write earns its way in") applied per resource rather than per phase, and it means
every database configured before today is unmutable without an explicit edit.

**Why a second credential rather than a boolean opt-in.** The same argument this codebase
already makes twice. `secrets.go:23-47` puts the org in the Keychain service name so
cross-org sharing is *impossible* rather than *avoided*, and declines a fallback that
would soften it. `hardenMySQLConfig` **discards** every unrecognised DSN parameter rather
than filtering a list of dangerous ones, because the danger turned out to live in the
value grammar rather than in any key name. Both prefer structural over enumerated. A
`writeRef` is structural: authority is proven to the server by presenting a credential
the server itself has granted write roles to. A boolean would be Wakil asserting write
authority to itself and hoping the far end agrees.

It is also the only option with a coherent Mongo story. `driver_mongo.go:24-39` records
that MongoDB has **no** URI option, session flag or client setting that makes a
`*mongo.Client` refuse a write, so the deployment requirement is that the stored
credential names a user granted only the built-in `read` role. Under a boolean, a
correctly-provisioned Mongo deployment would fail at the server no matter what Wakil
decided. Under `writeRef`, the write credential is a different user with different
grants, which is exactly how Mongo expects the distinction to be drawn.

**Cost, stated plainly:** one extra `wakil secrets set` per writable database, and an
operator who must think about what that credential is allowed to do. That cost is the
feature.

---

## 4. The writable path

```go
// dbresolve.go
func OpenDatabaseWritable(ctx context.Context, d Database) (Conn, error)

// dbdriver.go
type DbDriver interface {
    Kind() string
    Connect(ctx context.Context, conn Connection) (Conn, error)
    ConnectWritable(ctx context.Context, conn Connection) (Conn, error)
    AssertReadOnly(spec QuerySpec) error
    AssertMutation(spec QuerySpec) error
}

type Conn interface {
    ListContainers(ctx context.Context) ([]Container, error)
    Describe(ctx context.Context, name string) (Schema, error)
    Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error)
    Write(ctx context.Context, spec QuerySpec) (Written, error)
    Close() error
}

type Written struct {
    RowsAffected int64 `json:"rowsAffected"`
    Millis       int64 `json:"millis"`
}
```

`OpenDatabaseWritable` refuses before touching the Keychain when `d.WriteRef == ""`, with
a message naming the database and the field to add.

**The asymmetry between the two connections is deliberate and runs one way only.** A
`Conn` returned by `Connect` fails `Write` unconditionally: `sqlConn` gains a `writeGate`
field which the read path leaves nil, and `Write` returns
`UserError("this connection is read-only")` whenever it is. A `Conn` returned by
`ConnectWritable` keeps `Read` working, because reading through a write connection is
harmless and refusing it would force a second connection to be opened just to show the
operator which rows a `DELETE` is about to remove. The rule is *a read connection can
never write*, not *the two connections are mirror images*.

Per driver:

- **MySQL** — `hardenMySQLWriteConfig`, a **separate function**, deliberately not
  `hardenMySQLConfig(readOnly bool)`. It still sets `cfg.Params` to a fresh map,
  discarding every stored parameter, and still forces `MultiStatements = false` and
  `AllowAllFiles = false`. It omits only `transaction_read_only`. Both hardening
  functions get a test asserting the two forced-off fields, so a future edit to either
  cannot quietly drop them from one.
- **SQLite** — `sqliteWriteDSN`, sharing `setMode`'s `#`-escaping and first-`?` boundary
  handling with the read path (that logic is factored, the *mode value* is not), setting
  `mode=rw`. **Not `rwc`**: a mutation must not bring a database into existence. A missing
  file is an error, not an empty database to write into.
- **Mongo** — `ConnectWritable` returns `UserError`, and `AssertMutation` likewise, in the
  same shape `driver_mongo.go:129-141` already uses for `count`/`distinct`: wording that
  says *legitimate operation, not implemented yet*, distinguishable from a refusal. See
  §11.

---

## 5. What SQL is allowed

```go
func AssertSQLMutation(sql string) error
```

Reuses `stripSQLComments` — the genuinely hard-won part of `readonly.go`, hardened across
five documented bypasses — then:

1. Empty after stripping → `UserError("empty statement")`.
2. Any `;` other than a trailing one → refused, same wording shape as the read gate.
3. First keyword must be one of **`INSERT`, `UPDATE`, `DELETE`**. Everything else refused.

**DDL is refused.** No `CREATE`, `DROP`, `ALTER`, `TRUNCATE`, `RENAME`, `GRANT`, `REVOKE`,
`LOAD DATA`. Invariant 6 says writes are added per adapter *with deliberate
justification, never by default* — schema mutation has not been justified anywhere and
must not arrive as a side effect of the first row mutation. `TRUNCATE` is called out
because it reads like a `DELETE` and is not one: it is DDL in both MySQL and SQLite
semantics, is not transactional in MySQL, and ignores a `WHERE` because it cannot take
one.

**Why the mutation gate needs no keyword scan, where the read gate does.**
`AssertSQLReadOnly` must scan the *whole* statement after its prefix check, because a
statement legitimately beginning `SELECT` can still write — `SELECT 1 INTO OUTFILE` is
the documented case, and it is what drove three of that function's five hardening rounds.
The mutation gate has no equivalent hole: with `;` refused and `MultiStatements = false`,
a statement beginning `INSERT`/`UPDATE`/`DELETE` is exactly one statement of that verb,
and the writes it can perform are the writes it is being confirmed for.

**One belt-and-braces exception**, recorded as such: the gate additionally refuses
`INTO OUTFILE` and `INTO DUMPFILE` anywhere in the stripped text. This was **not proven
reachable** from an `INSERT`/`UPDATE`/`DELETE` prefix — MySQL rejects `INSERT ... SELECT
... INTO OUTFILE` at parse time — and it is not the primary defence either, since
`AllowAllFiles = false` already stops the server asking this host for files. It costs one
scan and closes the question rather than leaving it argued.

### The `WHERE` notice — advisory, never a gate

A separate `MutationAffectsEveryRow(sql string) bool` scans the stripped text for a
`WHERE` token, for `UPDATE` and `DELETE` only. Its **sole** consumer is the confirmation
surface, which shows *"no WHERE clause — this affects every row."*

It never refuses anything. That is the whole design: a wrong answer produces a missing or
spurious warning, never a blocked legitimate write and never an unwarned dangerous one
that the operator was not already shown the full statement for. Wakil does not
second-guess a deliberate `DELETE FROM sessions` — it makes sure the operator read it.

---

## 6. `db_run_mutation`

```
name:   db_run_mutation
kind:   .mutate                       ← the first one Wakil has ever registered
params: { statement: string (required), database: string }
```

Mirrors `db_run_query`'s shape, including the optional `database` selector, and dispatches
to `wakil-db`'s new `mutate` tool through the same `callChecked` path.

**It does not write to the `db` pane.** That pane holds columns and rows; a mutation has
neither. Projecting `rowsAffected` into a rows grid would put a fabricated shape on a
surface Invariant 3 promises reflects what is on screen. The result returns to the caller
and the confirmation surface reports it.

`registerStandardActions`' doc comment currently ends *"Wakil still ships zero `.mutate`
actions."* That sentence is deleted, and the file's header rewritten to explain the one
that now exists — the sentence has been load-bearing documentation since 2a and must not
simply go stale.

---

## 7. The pending-confirmation path

### The problem this solves

`phase-2b-i-acceptance.md:524-543` records it exactly: `MCPServer.handle` reads
`confirmation` as a **sibling** of `name`/`arguments` in `tools/call` params
(`MCPServer.swift:314-317`), *"a field no conforming MCP client sends, so a real agent
hitting this row gets a hard refusal rather than a confirmable gate."* Today the agent
cannot satisfy a gate at all. That doc names this phase's acceptance run as the moment to
resolve it.

### The resolution

**The agent still cannot self-confirm, and that is permanent.** Invariant 7 — *"voice may
propose a mutation; only typed confirmation may execute one"* — is a statement about who
confirms, and an agent emitting the string `"confirm"` is not a human typing it. The
sibling field is not widened into the tool's argument schema. Instead the refusal stops
being a dead end.

`ActionRegistry.dispatch` is **unchanged**. `.gate` without `"confirm"` still journals
`"gated"` and still throws `.needsConfirmation`. The parking happens strictly above it, in
a new `ConfirmationBroker` reachable from `MCPSurface`:

1. `handleToolsCall` dispatches at `origin: .agent` as it does today.
2. It catches `ActionError.needsConfirmation` and hands the proposal — action name,
   params, resolved database name, statement, and the every-row notice — to the broker.
3. The broker parks it and awaits a decision.
4. On **approve**, `handleToolsCall` re-dispatches the same name and params with
   `confirmation: "confirm"` and returns the handler's real result.
5. On **cancel**, the agent gets `-32002`, the existing code for a refused gate.
6. On **timeout**, the agent gets a distinct error saying the confirmation expired, so
   "you were refused" and "nobody was at the keyboard" do not read alike.

**Blocking**, holding the JSON-RPC request open — the same shape as Claude Code's own
permission prompts, which the operator already has a feel for. **120 seconds**, as one
named constant in one file so the tuning pass is a one-line edit.

**Single-flight.** One pending mutation at a time; a second gated dispatch arriving while
one is parked is refused immediately with a message saying so. A queue would need a queue
UI, an ordering rule and a story for what happens when two confirmations contradict each
other, and none of that is worth building before anyone has confirmed one mutation.

### The journal needs no schema change

The parked refusal already wrote `{"action":"db_run_mutation","origin":"agent","outcome":"gated"}`.
The confirmed re-dispatch writes `{"action":"db_run_mutation","origin":"agent","outcome":"ok"}`.
That pair reads as *proposed, refused, then confirmed and ran*, and it is **unambiguous**:
an agent cannot manufacture it by retrying, because it has no way to send a confirmation
itself. `JournalEntry` gains no field and `Journal.swift` is untouched.

`origin` stays `.agent` on both entries, and that is correct rather than a compromise —
the agent is who asked. The human's participation is recorded by the transition itself,
which nothing but a human can cause.

---

## 8. The window

A centred **plane above the canvas** (design-language §3's depth model), edged in
`#e85c5c` — §5's reserved destructive hue, the value 2b-ii assigned. Deliberately **not**
an `NSAlert`: a system modal is off-language and spins its own run loop, which the void's
`CAMetalLayer` and 2b-iv's motion are not written to survive.

It shows:

- the action name and the resolved database;
- the **full statement**, verbatim and unelided — an operator confirming a statement they
  cannot entirely see is not confirming it;
- the every-row notice from §5 when it applies;
- a confirmation field;
- Cancel. **ESC cancels**, and cancelling is always the safe default.

**The same surface serves an operator-initiated mutation**, dispatched from the window at
`origin: .ui`, which the gate also gates. One confirmation mechanism, not two — the same
argument `WakilWiring.build` already makes for having one action set behind both
`--dispatch` and the window.

**The typed token is the literal `"confirm"`.** This keeps `ActionRegistry.dispatch`
unchanged and lets `phase-2a-acceptance.md`'s check 5 and 6 scripts run **verbatim**, as
that document asks ("do not re-derive them"). The trade-off was raised in brainstorming
and decided: a fixed word carries no information about what is being confirmed and is
defeated by muscle memory. It is recorded in §11 as an open item, not re-argued here.

**No fifth `CoreState`.** A pending confirmation is arguably a fifth thing the room should
register, alongside `idle`/`listening`/`thinking`/`speaking`. It is not added, because
`CoreMotion`'s four existing states are recorded in `design-language.md` §15 as **untuned
— invented by 2b-iv's spec with no precedent** — and adding a fifth would tangle this
phase with that tuning pass. §11.

---

## 9. File structure

**Go — changed:**

| File | Change |
|---|---|
| `internal/wakilcore/config.go` | `Database.WriteRef` |
| `internal/wakilcore/dbresolve.go` | `OpenDatabaseWritable` |
| `internal/wakilcore/dbdriver.go` | `ConnectWritable`, `AssertMutation`, `Conn.Write`, `Written` |
| `internal/wakilcore/sqlconn.go` | `sqlConn.Write`, `writeGate` field (nil ⇒ read-only) |
| `internal/wakilcore/driver_mysql.go` | `ConnectWritable`, `hardenMySQLWriteConfig` |
| `internal/wakilcore/driver_sqlite.go` | `ConnectWritable`, `sqliteWriteDSN`, factored `setMode` |
| `internal/wakilcore/driver_mongo.go` | `ConnectWritable`/`AssertMutation` → not-implemented |
| `cmd/wakil-db/main.go` | the `mutate` tool |

**Go — new:** `internal/wakilcore/mutation.go` (`AssertSQLMutation`,
`MutationAffectsEveryRow`) and its test. Deliberately a new file rather than an addition
to `readonly.go`: that file is 900 lines about one question, and the mutation gate answers
the opposite one.

**Swift — changed:** `Registry/StandardActions.swift` (`db_run_mutation`, header rewrite),
`MCP/MCPServer.swift` (`handleToolsCall`'s catch), `App/AppWiring.swift` (broker into
`MCPSurface`), `WakilApp/Canvas.swift` (present the plane).

**Swift — new:** `Gate/ConfirmationBroker.swift`, `Gate/PendingMutation.swift`,
`WakilApp/ConfirmationPlane.swift`.

---

## 10. Verification

**Headless — Go:**

1. `AssertSQLMutation` accepts `INSERT`/`UPDATE`/`DELETE`; refuses `SELECT`, every DDL
   verb in §5, a second statement, an empty statement, and `INTO OUTFILE`.
2. It refuses each DDL verb **when reached through a stripped comment**, reusing
   `readonly.go`'s own bypass fixtures — the five documented bypasses are re-run against
   the new gate rather than assumed inapplicable.
3. `MutationAffectsEveryRow` on `UPDATE`/`DELETE` with and without `WHERE`, including a
   `WHERE` appearing only inside a string literal and only inside a comment.
4. `hardenMySQLWriteConfig` forces `MultiStatements` and `AllowAllFiles` off and does
   **not** set `transaction_read_only`; `hardenMySQLConfig` still sets it. One test over
   both, so they cannot drift.
5. `sqliteWriteDSN` yields `mode=rw`, never `rwc`, over the same hostile-path fixtures
   `sqliteReadOnlyDSN` is tested against.
6. `OpenDatabaseWritable` with no `writeRef` fails **without reading the Keychain**.
7. Mongo `ConnectWritable` and `AssertMutation` return the not-implemented wording, and a
   test asserts it is distinguishable from a refusal.

**Live — Go (`make test-live`):** a MySQL `INSERT`/`UPDATE`/`DELETE` through
`ConnectWritable` really changes rows, and the same statements through `Connect` fail at
the engine. The existing throwaway container already runs as `root`, so no new
infrastructure. These join `LIVE_TESTS`, whose prefix selection picks them up
automatically.

**Headless — Swift:**

8. `db_run_mutation` is registered `.mutate`, and `writeGate` returns `.block` for it in
   `production` and `.gate` elsewhere — the existing matrix, now with a live subject.
9. The broker: approve re-dispatches with `"confirm"`; cancel yields `-32002`; timeout
   yields the distinct expiry error; a second concurrent gated dispatch is refused.
10. The journal after an approved agent mutation contains exactly the `gated` → `ok`
    pair of §7, in that order.
11. `everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule` still passes.

**By hand — the point of the phase.** `phase-2a-acceptance.md` checks 5 and 6, run with
`db_run_mutation` substituted into the scripts already written there. Plus a new
`phase-2b-iii-acceptance.md` covering what no script can judge: whether the confirmation
plane reads as *alarming* rather than as *an obstacle*, whether the full statement is
legible in it, and the live agent turn `phase-2b-i-acceptance.md:536-543` has been owed
since 2026-09-08 — an agent asked to make a change, refused, parked, and confirmed by
hand.

---

## 11. What this phase does not do, and still owes

- **Mongo mutation.** Explicitly deferred, with a reason rather than an omission: the
  dangerous input is not the *op* but the **filter**. Inverting `AssertMongoReadOnly`'s
  allowlist would admit `deleteMany({})` — a whole-collection wipe that passes any
  op-name check. A Mongo write surface needs its own thinking about unbounded filters,
  about `updateMany` versus `updateOne`, and about `$out`/`$merge`, and that thinking does
  not belong in the same phase as the gate itself. `driver_mongo.go` says so at the call
  site, in the not-implemented shape it already uses for `count`/`distinct`.
- **DDL.** §5. Not refused for difficulty — refused because Invariant 6 requires a
  justification that has not been written.
- **The confirmation token.** `"confirm"` is a rote word that carries no information about
  what is being confirmed and that muscle memory defeats. Considered alternatives, in
  descending strength: the database name, the environment name. Deferred to keep
  `ActionRegistry.dispatch` and both acceptance scripts unchanged. Revisit once anyone has
  lived with it.
- **A fifth `CoreState`** for awaiting-confirmation. §8.
- **A confirmation queue.** Single-flight only. §7.
- **Session resume, the provider picker, signing.** §0. Still owed, still theirs; the
  signing item additionally needs a Developer ID Application certificate that this machine
  does not have.

---

## 12. Risks

| Risk | Mitigation |
|---|---|
| The writable path drifts from the read path's hardening as both are edited. | One test asserts the forced-off fields on **both** MySQL config functions, so a drop from either fails. |
| A blocking MCP request hangs the agent's turn if the operator walks away. | 120s timeout, one named constant, with a distinct error so expiry never reads as refusal. |
| `writeRef` makes the operator provision a write credential and they grant it too much. | Cannot be fixed in code — Wakil cannot audit a grant it did not make. `operator-todo.md` gains a note asking for the narrowest grant the statements need. Stated here rather than mitigated away. |
| The first mutation ships and DDL is wanted the following week. | It is one allowlist entry plus the justification Invariant 6 asks for. The gate is designed to be widened deliberately, not to be permanent. |
