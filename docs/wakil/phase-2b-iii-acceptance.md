# Phase 2b-iii acceptance — the write gate earns a subject

**Status:** **MET 2026-09-10 — accepted without an acceptance run.** No check in §2 was ever walked; the sub-phase was marked met by the operator on their own authority, and that was **re-affirmed on 2026-09-15** when the operator accepted the whole outstanding runbook backlog (`phase-log.md`, "The 2026-09-15 acceptance"). These six checks will not be walked. Read §4 before relying on any row here · **Spec:** `docs/superpowers/specs/2026-09-09-phase-2b-iii-write-gate-design.md`

Written 2026-09-10, at the end of Task 11 of
`docs/superpowers/plans/2026-09-09-phase-2b-iii-write-gate.md`. **You execute this**; no
agent has run any of it and none will. Every check below either needs a display session,
spends your Claude subscription, or writes to a real database — all three of which the
automated suite is forbidden to touch.

A check with an empty result is a check that was not run, and that is worth knowing
later, so unrun items say so rather than being quietly dropped — the same convention
`phase-2b-i-acceptance.md`, `phase-2b-ii-acceptance.md` and `phase-2b-iv-acceptance.md`
use. **"The code is written" and "the phase is done" are different claims, and only this
runbook closes the second one.** 2b-iii was nonetheless marked **met on 2026-09-10 without
this runbook being walked** — see §4. The convention above still holds inside this
document: an unrun check says so.

This sub-phase is unusual among 2b's in that its exit criterion belongs to another
document. The north-star gives 2b-iii one: *2a's acceptance checks 5 and 6 finally run.*
Those two checks live in `docs/wakil/phase-2a-acceptance.md`, they carried a placeholder
script and the words "not expressible in 2a" from 2026-09-08 until 2026-09-09, and they
are checks 1 and 2 below. This document owns their **result**; that one owns their
**script**, so it is not re-derived here — the same instruction `phase-2b-i-acceptance.md`
§5 gave ("do not re-derive them").

Companion documents: `docs/wakil/phase-2a-acceptance.md` (checks 5 and 6, and §1's launch
command), `docs/wakil/phase-2b-i-acceptance.md` §5 (the live agent turn owed since
2026-09-08, check 3 below), `docs/wakil/phase-2a-probe.md` §6–7 (what the CLI does with an
unlisted tool, and why `personal` sits on `production`),
`docs/wakil/operator-todo.md` ("Write credentials — `writeRef`, and what to grant it"),
and `docs/wakil/design-language.md` §3 and §5 (the depth model the plane sits in, and the
destructive hue it is edged in).

---

## 0. What was implemented, and what was not

The north-star's 2b-iii row named four things — *write-gate UI and the first `.mutate`,
session resume, provider picker, signing*. **One of the four was built.** The other three
were split out during brainstorming on 2026-09-09 for the reason 2b itself was split on
2026-09-08: they are not one spec, and each is recorded in the spec's §0 with its
evidence rather than dropped.

| Split out | Where it went | Why it is not here |
|---|---|---|
| Session resume | 2b-v | A change to the `AgentHarness` protocol and to ⌘P's session list. It shares no type, no file and no test with the gate. |
| Provider picker | 2b-vi | It reads a token out of the org's provider record instead of out of the environment, which means touching the Keychain from Swift for the first time. Its own risk surface entirely. |
| Signing | 2b-vii | A build-system change, and **partly blocked externally**: `security find-identity -v -p codesigning` on this machine reports exactly one identity, an *Apple Development* certificate. There is no **Developer ID Application** certificate — what notarisation and distribution outside the App Store require — and obtaining one needs a paid Apple Developer Program membership. Local signing with entitlements and the hardened runtime is achievable today; notarised distribution is not, and a phase should not ship with a known-unreachable half. |

**Mongo mutation was cut from the one item that remained**, and the reason is not
difficulty. `driver_mongo.go` records that the dangerous input in a Mongo write is the
**filter**, not the op: inverting `AssertMongoReadOnly`'s allowlist would admit
`deleteMany({})`, a whole-collection wipe that passes any op-name check. So
`mongoDriver.ConnectWritable` and `mongoDriver.AssertMutation` both return
*"mongo mutation is not implemented yet (Wakil writes to SQL databases only)"* — the
not-implemented shape that file already uses for `count`/`distinct`, deliberately worded
so it does not read as a refusal. Failing at `Connect` rather than only at `Write` means
an operator who puts a `writeRef` on a Mongo database is told so the first time they try
to use it, naming the limitation, rather than being handed a connection that looks usable
and refuses every statement.

**What did ship, in one paragraph, so the checks below have something to be checks *of*.**
`Database.writeRef` — no write credential, no mutation, ever, for that database.
`OpenDatabaseWritable`, a second code path that refuses before it reads the Keychain when
the field is empty; the read path is not edited at all. `AssertSQLMutation`, allowing
exactly `INSERT`/`UPDATE`/`DELETE` and refusing every DDL verb, a second statement, and
`INTO OUTFILE`/`DUMPFILE`. `db_run_mutation`, the first and only `ActionKind.mutate`
action Wakil has ever registered — `MutationActionTests` pins that count at one, so a
second is a test failure rather than an unremarked addition. A `ConfirmationBroker` that
parks a refused proposal, single-flight, for 120 seconds. And `ConfirmationPlane`, a red
plane above the canvas that renders the full statement and takes the typed word.

---

## 1. Before you start

### 1.1 The suite, and the build

```bash
make build && make test && make vet && make app-build && make app-test && make app-bundle
```

| | Check | Expected |
|---|---|---|
| H1 | Go suite | green — every package `ok` |
| H2 | Swift suite | **319 tests pass.** `phase-2b-iv-acceptance.md` H1 expected 294 and the merged tree reported 295; 2b-iii's own tasks added the rest (`MutationActionTests`, `ConfirmationBrokerTests`, the five park tests in `MCPServerTests`, the window's park tests in `WindowModelTests`). |
| H3 | `make build` really did run | 16 tests shell out to `bin/wakil-ctx`, and `bin/` is per-worktree. This is 2b-iv's H1 finding, repeated here because it costs an hour to rediscover. |

`make app-bundle` is not optional for checks 1 and 2: they run
`app/Wakil.app/Contents/MacOS/Wakil --dispatch`, which needs the assembled bundle with
the five MCP-server binaries in `Contents/Resources`. See `phase-2a-acceptance.md` §1 for
why that directory is load-bearing and has no fallback.

### 1.2 A database you are willing to break

**Do not point any of this at a database you care about.** Checks 1 and 2 delete a row,
and check 3 asks an agent to change one.

The `make test-live` MySQL container is the right subject, and it already exists:

```bash
docker run -d --name wakil-acc-mysql -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=wakilacc -p 13306:3306 mysql:8
```

(The exact container and port are whatever `make test-live` prints — run it with the
containers stopped and it prints the two `docker run` lines itself. It is disposable:
every live test creates its own fixture, so there is no schema to preserve.)

Seed one table with something to delete:

```bash
docker exec -i wakil-acc-mysql mysql -uroot -prootpw wakilacc <<'SQL'
CREATE TABLE IF NOT EXISTS customers (id INT PRIMARY KEY, name VARCHAR(64));
DELETE FROM customers;
INSERT INTO customers VALUES (41,'a'),(42,'b'),(43,'c');
SQL
```

Check 1's script deletes `id=43`; check 2's tries and must fail. Re-seed between runs —
check 1's second script exits `0` only if the `DELETE` actually connected, and a row that
is already gone still exits `0` with `rowsAffected: 0`, which is a pass for the wrong
reason. **Look at `rowsAffected`, not only at the exit code.**

### 1.3 The `writeRef` — without this, nothing below works

This is the precondition that most easily makes check 1 pass for the wrong reason: with
no write credential, the mutation fails at the *connection*, `--dispatch` exits `2`, and
`[ $? -eq 2 ] && echo "gated as expected"` prints exactly what a working gate prints.

```bash
# 1. Store a credential the server has granted write permission to.
WAKIL_ORG=personal wakil secrets set 'db:staging:write'
# paste the write DSN on stdin, then Ctrl-D. There is no flag that takes a
# secret on the command line and there will not be one.

# 2. Add the ref to that database in project.json. `wakil project list` prints
#    the path of each project.json.
#    {"name":"orders","driver":"mysql","ref":"db:staging","writeRef":"db:staging:write"}
```

Three things to get right, because none of them is enforced in code:

- **`writeRef` must name a different Keychain entry from `ref`.** Nothing refuses you if
  it does not, and pointing both at one credential silently gives the *read* path write
  authority at the server — the single thing the two-credential design exists to prevent.
- **Grant that credential the narrowest permission the statements need.** Wakil cannot
  audit a grant it did not make; the spec says so in §12 and declines to pretend
  otherwise. A `writeRef` naming `root` works perfectly and defeats the entire point.
- **`readOnly` on the database record is still inert.** It is carried and not consulted,
  exactly as it was before this phase. `writeRef` is the only field that decides anything.

**Against the throwaway container specifically, `root:rootpw` is the right credential and
is not a violation of the second bullet.** The container exists to be destroyed and holds
nothing; the narrow-grant rule is about the databases you keep, and it is stated at length
in `operator-todo.md` where an operator will meet it. Do not let the convenience here
migrate into a real `project.json` — that is precisely the failure mode that section
names.

### 1.4 The active environment, and what `--environment` does not do

`--dispatch --environment staging` sets the string `writeGate` reads and the string the
journal records. **It does not re-point the active context**, and `wakil-db` resolves
*which* database to open from `active.json`. Probe §7 found `personal` sitting on
`production`, so unless you switch first, `--environment staging` gates the call as
staging while opening the production database. Switch the active environment before you
start, or put a `ctx_set_environment` line at the top of the script and restore it at the
end the way `phase-2a-acceptance.md` check 7 does.

### 1.5 The window, for checks 3 to 6

`phase-2a-acceptance.md` §1's launch command, unchanged:

```bash
WAKIL_ORG=personal \
WAKIL_PROVIDER=<your claude-code provider id for that org> \
WAKIL_CLAUDE_PATH="$(command -v claude)" \
CLAUDE_CONFIG_DIR="$HOME/.claude-personal" \
CLAUDE_CODE_OAUTH_TOKEN='<the token for that account>' \
app/Wakil.app/Contents/MacOS/Wakil
```

`personal`, not `initech` or `umbrella` — probe §5 confirmed `--mcp-config` and
`--strict-mcp-config` work unmanaged on the `max` account and explicitly did *not* test
the `team` and `enterprise` ones. Launched from a shell the window may open behind
Terminal; ⌘-Tab.

---

## 2. The standing checks

Six checks. Run them in order — check 3 depends on the same `writeRef` checks 1 and 2
establish, and check 6 is a judgement about a plane that checks 3, 4 and 5 put on screen.

Record the result and the date; a re-run replaces the row rather than appending to it.

**Nothing below was ever walked.** On 2026-09-10 the operator marked this
sub-phase met without running the runbook. Every row therefore reads **ACCEPTED — not
walked**, which is a record of a decision, not of an observation: no plane was looked at,
no journal line was read, no exit code was seen. The checks remain here, unmodified and
still runnable, for whoever wants the evidence later.

### Check 1 — 2a's check 5: gated, then confirmed

*`phase-2a-acceptance.md` §4, "Check 5 — the write gate". The scripts are there and are
not repeated here.* This is half of the sub-phase's exit criterion.

**Run both scripts in that section**, with `db_run_mutation`, `DELETE FROM customers
WHERE id=43` and your database's name already substituted in — as of 2026-09-09 they are
written out concretely there rather than as placeholders.

**Look for**, in order:

1. The first script exits `2`.
2. The journal's last `db_run_mutation` line reads
   `{"action":"db_run_mutation","origin":"debug","outcome":"gated"}` — **`gated`, not
   `error`.** An `error` means the call never reached the gate, and the exit code `2` you
   just saw was a connection failure wearing the gate's clothes. This is the single most
   likely way this check passes for the wrong reason, which is why it is step 2 rather
   than a footnote.
3. The second script exits `0`, and its output line carries a `rowsAffected` of `1`.
   Read that number only alongside `rowsAffectedKnown`: `rowsAffectedKnown: false` means
   the driver reported no count at all, not that zero rows changed, so `rowsAffected: 1`
   is proof the write landed only when `rowsAffectedKnown` is `true` beside it.
4. `docker exec -i wakil-acc-mysql mysql -uroot -prootpw wakilacc -e 'select * from customers'`
   shows `43` gone.
5. The journal now holds `gated` then `ok` for `db_run_mutation`, in that order.

**What is already proved headlessly, so you do not have to take it on faith:**
`MutationActionTests.dispatchingTheMutationWithoutConfirmationJournalsGated` pins step 2,
and `TestMySQLWritableConnectionWritesAndReadOnlyOneStillCannot` (in `make test-live`)
pins that the write path really writes *and* that the same statement through the read
path still fails at the engine. What your hands add is that the whole spine —
`--dispatch` → `ActionRegistry` → `writeGate` → `wakil-db` → a real MySQL — carries it end
to end against real Keychain credentials, which no test in this repo may touch.

| Result | Date | Notes |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 2 — 2a's check 6: blocked in production, and a confirmation does not help

*`phase-2a-acceptance.md` §4, "Check 6 — production blocked".* The other half of the exit
criterion.

**Look for:** exit `2`, and a journal line whose outcome is `"blocked"` — **not
`"gated"`**. The distinction is the check. `writeGate` returns `.block` for `.mutate` in
production, and `.block` is not a decision the typed token can overturn:
`ActionRegistry.dispatch` never consults `confirmation` on that path, and no plane
appears. A run that exits `0`, or that journals `gated`, means production has quietly
become merely-gated and the second half of Invariant 8 has become the first half.

The script deliberately *supplies* `"confirmation":"confirm"`. It is there to be ignored.

**Also confirm nothing ran:** `id=43` (or whatever you re-seeded) is still in the table.

| Result | Date | Notes |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 3 — the live agent turn, owed since 2026-09-08

*`phase-2b-i-acceptance.md` §5, "The agent-into-production gate has not been exercised
live", which names this acceptance run as the moment to spend the turn.*

That document recorded two things: that no `claude` turn had ever tried the gate, and
that **it could not have been satisfied even if one had** — `MCPServer.handle` reads
`confirmation` as a sibling of `name`/`arguments`, a field no conforming MCP client
sends, so an agent hitting the gate got a hard refusal rather than a confirmable gate.
2b-iii's answer is not to let the agent send it. Invariant 7 is a statement about *who*
confirms, and an agent emitting the string `"confirm"` is not a human typing it. So the
sibling stays unreachable and **the refusal stops being a dead end**: the proposal parks
in the broker, a human decides, and the same call is re-dispatched.

This check has two halves and they are expected to behave differently. **Walk both.**

**3a — the `.control` half, which should park.** In the window, with the active
environment *not* production, type into the message field:

> switch the active environment to production

`ctx_set_environment` is `.control`, it declares `targetEnvironmentParam: "name"`, and
`writeGate` gates a `.control` action from an agent whose target is production. It is on
the agent's allow list (`.control` joined it in 2b-i), so the call reaches Wakil's socket
and parks.

**Look for:** the red plane appears; it says *"The agent proposes a change"*; and where a
mutation would show SQL it shows a rendered description instead —
`ctx_set_environment {"name":"production"}`. Type `confirm` and press Run. The environment
switches, and the journal holds `gated` then `ok` for `ctx_set_environment` with
`"origin":"agent"` on **both** lines. `origin` staying `.agent` is correct rather than a
compromise: the agent is who asked. The human's participation is recorded by the
transition itself, which nothing but a human can cause — an agent cannot manufacture that
pair by retrying, because it has no way to send a confirmation.

```bash
grep -h '"action":"ctx_set_environment"' ~/.wakil/journal/*.jsonl | tail -2 | jq -c '{action,origin,outcome}'
```

Put the environment back afterwards.

**3b — the `.mutate` half, which is expected to be refused before Wakil ever sees it.**
Ask the agent, in the same window:

> delete the customer with id 42 from the orders database

**What this check is actually determining is which of two things happens**, and the code
predicts the second:

- *If the plane appears*, walk it exactly as 3a: confirm by hand, then check the journal
  carries `gated` then `ok` for `db_run_mutation` with `"origin":"agent"`.
- *If the agent reports a permission denial instead*, *that is the predicted outcome and
  it is not this check failing.* `agentAllowedTools` filters the registry to `.read` and
  `.control`, **never `.mutate`** — `WindowModelTests.aMutatingActionIsNeverOnTheAllowList`
  and `theAllowListAdmitsControlActionsAndBothReadTools` both pin it — and no
  `--permission-prompt-tool` was built, so in a `-p` session with no approval surface an
  unlisted MCP tool is denied by the CLI itself. Probe §6 recorded the exact wording:
  *"Permission for this tool use was denied. It requires approval, and this session has no
  approval surface — nobody can answer a permission prompt here — so it was denied
  automatically."* The tool is still advertised in `tools/list`, so the agent can see it
  and reach for it; it just cannot get through. **The proposal never arrives at the
  socket, so no plane appears and the broker never parks anything.**

Record which of the two you saw, verbatim. If it is the second, the agent-originated
`.mutate` park remains proved only headlessly
(`MCPServerTests.anAgentProposedMutationParksAndRunsOnceApproved`, which drives `handle`
directly), and §3's first gap is the item that closes it.

**The prediction above was overtaken on 2026-09-10.** The permission-prompt bridge
(`docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`) built the
`--permission-prompt-tool` whose absence this check turns on, so **the first outcome is
now the expected one**: the plane should appear, and a permission denial is now this
check failing rather than the predicted result. `agentAllowedTools` is unchanged and
still filters `.mutate` off the allow list — the bridge is what the CLI consults because
of that filter, and it decides reachability, never permission. Read the two bullets above
as the record of what was predicted before that existed.

| Result | Date | Notes |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 4 — cancel, and confirm nothing ran

Repeat whichever half of check 3 actually parked. This time press **Cancel**, or press
**ESC** — cancelling is always the safe default and both must work.

**Look for:**

1. The plane disappears.
2. The agent is told it was refused: JSON-RPC `-32002`, the same code a plain gate
   refusal returns, worded `<action> requires confirmation`.
3. **Nothing ran.** For 3a, the active environment is unchanged. For 3b, the row is still
   there. Check the database, not the agent's summary of it.
4. The journal holds a `gated` line and **no** matching `ok`.

Then, without reloading anything, propose a second mutation and confirm **the field is
empty**. A half-typed word carrying over from a cancelled proposal — including a literal
`confirm`, which would leave Run enabled on a statement nobody has read — is the defect
`Canvas.swift`'s `.onChange(of: model.pending)` exists to prevent, and it compares ids
rather than "did it become nil" for a specific reason recorded there. This is the
by-hand half of that.

| Result | Date | Notes |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 5 — walk away for two minutes

Propose a change and **do not touch the keyboard**. `ConfirmationBroker.defaultTimeout` is
120 seconds, one named constant in one file.

**Look for:** after roughly two minutes, the plane disappears on its own, and the agent is
told something *distinguishable from a refusal*. The wire form is JSON-RPC `-32004`
(against `-32002` for a cancel), worded *"the operator did not confirm in time — propose
it again"*.

**The distinction is the check, and it is not pedantry.** An agent told "you were refused"
when the truth is "nobody was at the keyboard" will go looking for a permission to ask for
instead of simply trying again. So judge the *agent's own rendering* of it in the thought
thread, not the code — you are checking whether the wording survives the trip and reads
that way to a reader who cannot see the error code.

**Two things may interfere, and both are real behaviour rather than a bad run.** First,
the CLI has a tool-call timeout of its own; if it gives up before Wakil's 120s elapses,
you will see it report a failure early. Second, and worse — see §3 — if you then approve
the proposal anyway, **the mutation still runs**, against an agent that was already told
the call failed. If you want to see the expiry cleanly, let the clock run out rather than
approving late.

| Result | Date | Notes |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 6 — by eye, and the reason the phase exists

*Spec §8. This is the judgement no test can make, and it is why this runbook exists at
all rather than a green suite standing in for it.*

With a proposal parked — the `DELETE FROM customers` one from check 1, dispatched from
the window if you can, or the `.control` one from 3a — sit and look at the plane. Four
questions, and answer them separately:

1. **Does it read as *alarming* rather than as *an obstacle*?** This is the whole
   distinction. An obstacle is a thing you dismiss on the way to what you wanted; an alarm
   is a thing you read. If your instinct is to reach for the field before you have read
   the statement, the plane has failed at the one job it has, and the fix is a design
   question rather than a bug.
2. **Is the full statement legible?** It is rendered verbatim and unelided in a
   `ScrollView` capped at 180pt, in 13pt monospace, inside a 520pt-wide plane. Try a long
   one — a `DELETE` with a three-clause `WHERE`, or a 400-character `UPDATE`. An operator
   confirming a statement they cannot entirely see is not confirming it. Does it wrap
   legibly, or does it need scrolling that is not obvious enough to notice?
3. **Does the every-row warning land?** Propose `DELETE FROM customers` with **no**
   `WHERE`. The line *"No WHERE clause — this affects every row."* must appear, in the
   destructive red, and it must read as more serious than the rest of the plane rather
   than as one more grey line. This warning is **advisory only** — `MutationAffectsEveryRow`
   in Go and `mutationAffectsEveryRow` in Swift both decorate, neither refuses, and nothing
   may make them otherwise — so its entire value is whether a human notices it.
4. **Is `#e85c5c` right against the void, or does it vibrate?** The plane's border sits
   over 2b-ii's near-black field with its violet and blue bleeds. Red against violet at
   low luminance is exactly where simultaneous-contrast shimmer lives. Look at the border
   for a full ten seconds without moving your eyes. If the edge crawls, that is a finding
   about the design language's §5 hue in this context, not about this plane, and it
   belongs in `design-language.md`.

**Two defects to look for specifically, both known and neither fixed** — see §3, and both
need a human eye because no test can see a screen:

- The dimming backdrop is applied inside the canvas's `.overlay`, so it covers the canvas
  and nothing else. The org/project/environment row and the agent composer stay **lit and
  interactive** while a proposal is parked. Try clicking them. Judge whether that reads as
  "this is the one thing the window is asking about" or as a modal with holes in it.
- The overlay sits below `ThoughtThread` in `WakilWindow`'s `ZStack`. Fill the thread with
  a long turn first — six rows is its visible maximum — then park a proposal, and check
  whether the thread draws over the plane. At small window sizes it is likelier.

| Result | Date | Notes |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

---

## 3. Known gaps

Mirroring the spec's §11 rather than restating it — each entry below says what it means
for someone walking §2, which the spec does not. Three of these were found by review
after the spec was written and are recorded here first.

**A live agent cannot reach `db_run_mutation` at all.** `agentAllowedTools` filters to
`.read` and `.control`, and `--permission-prompt-tool` was not built — a decision taken in
2a on the grounds that "2a registers zero `.mutate` actions … there is nothing for it to
refuse", which stopped being true on 2026-09-09. The allow-list filter is the safe
direction to fail in and should stay; what is missing is the approval surface the CLI
needs in order to ask. Until it exists, the agent-proposed *mutation* path is exercised
only headlessly, and the agent-proposed *`.control`* path (check 3a) is the only live
subject the broker has. **This is the largest single gap in the sub-phase** and the reason
check 3 is written as two halves rather than one.

**Closed 2026-09-10.** The approval surface this paragraph asks for is
`approve_tool_use`, named to the CLI by `buildLaunch`'s `--permission-prompt-tool` and
specced in `docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`,
against ten measured scenarios in `docs/wakil/permission-prompt-probe.md`. The allow-list
filter stayed exactly as this paragraph says it should.

**Check 3b was walked on 2026-09-10 and passes** — recorded in
`docs/wakil/permission-prompt-acceptance.md`, which owns that run's evidence. The
confirmation plane appeared from a live agent for the first time, and the journal carries
the `gated` → `ok` pair with `origin: agent` for one statement. That pair cannot be
produced by an agent retrying, because an agent has no way to send a confirmation, so it
is proof a human typed one. **This check is retired; the other five in §2 are not.**

**A client that gives up first still gets the write.** The park holds a JSON-RPC request
open for up to 120 seconds, and `Connection.ingest` awaits each `handle` call to
completion before reading the connection's next frame — so a `notifications/cancelled`
the CLI sends after its own tool-call timeout cannot even be *read* until the parked
request resolves. If that happens and a human approves anyway, the mutation runs. What
executes is the operator's own confirmed intent, read in full and acted on deliberately,
so running it is not wrong; what is lost is narrower and still real — the agent that
proposed it has already moved on believing the call failed, so it never learns the write
it asked for actually happened. Restoring that notice would mean this connection reading
ahead of a parked request. Documented at the call site in `MCPServer.parkForConfirmation`
and recorded here rather than closed.

**Narrowed, not closed, 2026-09-10.** `permission-prompt-probe.md` §10 held an ordinary
`tools/call` open for 130 seconds against a real CLI: no tool-call timeout fired and no
`notifications/cancelled` was sent, and the agent received the genuine result. So the
scenario this paragraph describes does not occur inside the window the broker can hold
(120s). Nothing here measured ten minutes, and nothing here says the CLI has no tool-call
timeout at all — only that it is longer than the broker's.

**The bridge adds a sibling case, 2026-09-10.** `MCPServer.swift`'s connection drains
frames strictly serially, so a *permission question about a different tool* can now sit
unread behind a 120-second park — before `--permission-prompt-tool` existed such a
question generated no MCP traffic at all, because the CLI denied it locally without ever
asking. Worst case is a stalled turn, not a widening: no tool runs that would not have
been permitted anyway, and probe §9 and §10 each measured only a single un-queued call, so
neither speaks to what happens behind one.

**A cancelled caller holds the single-flight slot for the full timeout.**
`ConfirmationBroker.request` suspends on `withCheckedContinuation`, not
`withTaskCancellationHandler`. If the task that parked a proposal is cancelled while it
waits, the continuation is never resumed early and `pending` stays occupied until the
120-second timer fires — so every other proposal in that window gets `.busy` for a
proposal nobody is waiting on any more. Not reachable from the window (the pump outlives
the plane) and not observed in practice; recorded because the fix is a different primitive
rather than a patch.

**The plane is not modal enough, and can be drawn over.** Both restated from check 6
because they are gaps rather than judgements: the dim covers only the canvas, leaving the
context row and the composer lit and clickable behind a parked proposal; and the overlay
sits below `ThoughtThread` in `WakilWindow`'s `ZStack`, so a tall thread can draw over
the plane. Neither was fixed, and both were deliberate deferrals rather than oversights —
raising the overlay to the window level means moving it out of `Canvas` and past the
thread, which is a layout change with its own risk in the same sub-phase that added the
gate.

**There is no way to compose a mutation in the window.** `WindowModel.runMutation` exists
and is tested, and the spec's §8 says "the same surface serves an operator-initiated
mutation, dispatched from the window at `origin: .ui`" — but **no control calls it**. The
window has a query field and no mutation field, and the only way to reach
`db_run_mutation` from the UI is ⌘K, which dispatches with empty params and is refused
with *"no statement to confirm — nothing ran"* rather than parking a blank plane. So the
`.ui`-origin half of "one confirmation mechanism, not two" is real in the model and
unreachable in the window. Check 6 is walkable through the agent's path or through
`--dispatch`; the operator's own path is owed.

**Mongo mutation.** §0. Deferred with a reason: the dangerous input is the filter, not the
op. A Mongo write surface needs its own thinking about unbounded filters, about
`updateMany` versus `updateOne`, and about `$out`/`$merge`.

**DDL of every kind is refused.** `CREATE`, `DROP`, `ALTER`, `TRUNCATE`, `RENAME`,
`GRANT`, `REVOKE`, `LOAD DATA`. **Not refused for difficulty** — refused because Invariant
6 requires a justification per adapter and none has been written for schema mutation.
`TRUNCATE` is the entry most likely to be argued back in and the one to argue hardest
about: it reads like a `DELETE` and is not one. It is DDL in both MySQL and SQLite, it is
not transactional in MySQL, it resets `AUTO_INCREMENT`, and it cannot take a `WHERE` at
all — which means the every-row warning could not fire for it even in principle. Widening
the gate is one allowlist entry plus that justification; it was designed to be widened
deliberately, not to be permanent.

**The confirmation token is the literal word `confirm`.** It carries no information about
what is being confirmed and muscle memory defeats it. Considered alternatives, in
descending strength: the database name, then the environment name. Deferred so that
`ActionRegistry.dispatch` stayed unchanged and both of `phase-2a-acceptance.md`'s scripts
could run **verbatim**, as that document asks. Revisit once somebody has lived with it —
and check 6's first question is the evidence that decides it.

**No fifth `CoreState` for awaiting-confirmation.** Arguably the room should register a
parked proposal alongside `idle`/`listening`/`thinking`/`speaking`. It was not added,
because `design-language.md` §15 records the room's four motion states as **untuned** — their
numbers invented by 2b-iv's spec with no precedent here — and a fifth would tangle this sub-phase with that
tuning pass.

**Single-flight only; there is no queue.** A second gated dispatch arriving while one is
parked is refused immediately with `-32005` and a message saying so. A queue would need an
ordering rule, a UI that can show more than one, and an answer for what happens when two
confirmations contradict each other, and none of that is worth building before anyone has
confirmed one mutation.

**Session resume, the provider picker, and signing.** §0. Still owed, still theirs; the
signing item additionally needs a Developer ID Application certificate this machine does
not have.

---

## 4. Result

**MET 2026-09-10, by acceptance without an acceptance run.** The operator
marked this sub-phase met on their own authority. **No check in §2 was walked**, and every
row in §2 records that fact rather than a result.

What that does and does not establish, stated plainly so nobody has to reconstruct it:

- **Established.** Every headless check the spec's §10 lists is green, and `make app-test`
  reported 319 tests passing on 2026-09-10. That was already true before this decision and
  is unaffected by it.
- **Not established.** Whether a red plane reads as alarming rather than as an obstacle,
  whether a statement is legible enough to be confirmed honestly, and whether an expiry
  reads differently from a refusal to the agent that receives it. These are the judgements
  the sub-phase exists to make, they are the reason this runbook was written, and no human
  has made them. Marking the row met did not make them; it set them aside.
- **Also not established.** 2a's acceptance checks 5 and 6 — the sub-phase's stated exit
  criterion — became runnable on 2026-09-09 and have still never been run. The
  permission-prompt bridge (2026-09-10) retired check 3b specifically, so the live-agent
  mutation path *is* covered by that sub-phase's own walked runbook; the rest is not.

The checks below stay in the document, unmodified. If the write gate later misbehaves in a
way a person would have caught by looking at it, §2 is where to start, and the honest
answer to "was this ever verified?" is no.
