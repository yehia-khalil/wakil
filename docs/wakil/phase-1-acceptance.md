# Phase 1 acceptance run

The spec's §8 exit criteria, as a runbook. **You execute this**; no agent has run
any of it and none will — every step below either writes to your real Keychain,
mutates your real Claude configuration, or needs an interactive Claude Code
session.

**Status: re-run 2026-09-07 against the org/provider model — all seven exit
criteria PASS.** Phase 1's exit criteria are met.

The original 2026-09-05 run (against the model this replaced) also passed all
seven, after finding four real defects, all fixed (`51b4019`, `c9876c0`). Those
results are recorded inline below, dated, and are **not** rewritten: they describe
what actually happened. Each criterion now carries both, so the difference between
"passed once, on code since replaced" and "passed on the code that ships" stays
visible.

The re-run found no defect in the shipped code. It did find one **structural
limitation** in the org/provider model — see *"One config dir serves one org"*
below — and established that two of criterion 5's steps are unreachable from a
Claude session by construction, which is recorded there rather than left blank.

What changed underneath them: the org/provider decoupling (2026-09-06, merged as
`1110e57`) moved org identity from `CLAUDE_CONFIG_DIR` to `WAKIL_ORG`, split
`~/.wakil` into a per-org tree, and made providers a separate axis with their own
records. **Every setup command in this document has been rewritten for that model.**
The seven criteria themselves are unchanged, but four of them now exercise
materially different machinery, so the table below says what a re-run is actually
re-proving. Re-running all seven with equal ceremony would hide that distinction.

**Do `operator-todo.md`'s MIGRATION section first.** `~/.wakil` was deleted in full,
so there is no org, no provider, no project registry and no registered MCP server to
run any of this against until it is rebuilt.

A criterion with an empty result is a criterion that was not tested, and that is worth
knowing later — so unrun items say so rather than being quietly dropped.

Companion document: `docs/wakil/operator-todo.md` lists the credentials and account
setup this run depends on.

---

## What the re-run has to re-prove

| # | Criterion | 2026-09-05 | What the decoupling changed under it |
|---|---|---|---|
| 1 | Servers and 16 tools listed | PASS | **Registration path only.** `register-org.sh` is gone; `register-provider.sh <org> <provider> <bin>` replaces it and pins `WAKIL_ORG` and `WAKIL_PROVIDER` on all five servers. Same tools, same count — a mechanical re-check. |
| 2 | Context switching | PASS | **Where the active context lives.** `active.json` moved from one global file to `orgs/<org>/active.json`, and `get_context` now also reports a provider (selected vs. running). |
| 3 | Jira | PASS | **Where the site comes from.** `WAKIL_JIRA_BASE` is no longer how a registered server learns its Jira site — `org.json`'s `jiraBase` is, read fresh per call. The env var survives only as a manual override. |
| 4 | Three database drivers | PASS | **Nothing in the drivers.** Only whether your credentials are reachable — see the Keychain note below. |
| 5 | Writes are refused | PASS | **Nothing.** The three gates are org-agnostic and were not touched. Re-run it anyway: it is the criterion the charter's read-only promise rests on, and it is cheap. |
| 6 | Session discovery | PASS | **Substantially.** `sessionsRoot()` was deleted. Discovery now enumerates the org's *registered providers* and reads each one's recorded `configDir`; sessions are tagged with the provider they came from, and providers whose stores could not be read are named in `unreadProviders`. Nothing reads the ambient `CLAUDE_CONFIG_DIR` any more. **This is the one criterion whose old PASS says least about the current code.** |
| 7 | Cross-org guard | PASS | **The mechanism, not the outcome.** The old recorded rationale — "a single global `active.json` shared by both orgs, made safe by re-checking on every read" — is now only half true: each org has its own file *and* `Resolve()` still re-checks `proj.Org` against `CurrentOrg()`. The re-check remains the boundary; the shared file is no longer part of the story. |

**Keychain, one condition.** The migration needs no re-store *if* your credentials
were already stored under the org-scoped name. Items are named
`wakil:<org>:<ref>`; anything stored under the older org-less `wakil:<ref>` (which
is what the 2026-09-05 run used) is unreachable now and must be stored again. Check
one before starting rather than discovering it inside a Claude session:

```bash
security find-generic-password -s 'wakil:personal:jira:personal' >/dev/null && echo present
```

---

## Two things to read before you start

**1. `"readOnly"` in `project.json` is advisory metadata. It enforces nothing.**

Every driver applies its read-only measures *unconditionally* — SQLite gets
`mode=ro`, MySQL gets `transaction_read_only=1`, and every query passes the
`AssertSQLReadOnly` / `AssertMongoReadOnly` / `AssertHTTPReadOnly` gate — whether
or not the flag is set. The only code that reads the flag is `wakil-ctx`, which
merely *reports* it through `list_environments`.

The consequence to keep in mind while testing: setting `"readOnly": false` will not
make anything writable, it will only make `list_environments` *describe* that
environment as writable, which could mislead the model. Criterion 5 below is
therefore testing the gates, not the flag.

> **Superseded 2026-09-10 — the flag no longer exists.** This section is kept as
> written because it is the record of the Phase 1 run, and because it identified
> the defect correctly a year before it was fixed: *"it will only make
> `list_environments` describe that environment as writable, which could mislead
> the model."* It did exactly that, three times, during the permission-prompt
> bridge acceptance run. `readOnly` was removed from `Database` under issue #14;
> `list_environments` and `list_databases` now both derive writability from
> `writeRef`, the only field that decides anything. Anyone re-running this
> runbook should ignore the two paragraphs above and read `operator-todo.md`'s
> write-credentials section instead. A `project.json` that still carries the key
> loads fine — it is ignored, not rejected.

**2. Mongo has no connection-level read-only mode.**

The gate blocks write *operations*, but the only real guarantee is a user holding
just the `read` role. See `operator-todo.md` §2 for the `createUser` recipe and the
`authSource` pitfall.

---

## Step 1 — Full build + unit suite  ✅ done for you

```bash
make build
go test ./...
```

**Result (re-recorded 2026-09-06, on this machine, post-decoupling):**

- `make build` — OK. All six binaries in `bin/`: `wakil`, `wakil-ctx`, `wakil-db`,
  `wakil-pm`, `wakil-http`, `wakil-recall`.
- `go test ./...` — **9 packages, all `ok`.** 436 test functions plus 1 fuzz target.
- Also green under `-race`; `gofmt -l .` empty; `go vet ./...` clean.
- Go 1.27.1 darwin/arm64.

14 tests SKIP because they need a service or your Keychain. They are Step 2 —
and `make test-live` is the one command that runs the engine-backed ones and
refuses to report success if they skip:

| Skipped test | Needs |
|---|---|
| `TestKeychainRoundTrip` | `WAKIL_KEYCHAIN_TEST=1` |
| `TestMySQLReadAndGate`, `TestMySQLQuoteIdentAndDescribe`, `TestMySQLEngineLevelReadOnly`, `TestMySQLSetInjectionCannotDisableReadOnly`, `TestMySQLDoubleDashOutfileBypassIsBlocked`, `TestMySQLCommentIntroducerBypassIsBlocked`, `TestMySQLExecutableCommentCloseBypassIsBlocked`, `TestMySQLCommentHandlingDidNotOverReject`, `TestMySQLGenuineDoubleDashQueriesStillWork` | `WAKIL_MYSQL_DSN` |
| `TestMongoReadAndGate`, `TestMongoDescribe`, `TestMongoTruncation_Find`, `TestMongoTruncation_Aggregate` | `WAKIL_MONGO_URI` |

Five of the nine MySQL skips are the read-only-gate bypass corpus added after the
final review. They need a live engine precisely because they assert what the
*engine* does with a statement the lexer let through, so a skipped run leaves the
strongest read-only claim in this codebase unexercised.

---

## Step 2 — Run the gated tests once

Throwaway containers; nothing here touches a real database.

**This is one command.** `make test-live` starts nothing itself, but it
checks the containers are up, sets both environment variables for you, runs the
engine-backed tests, and — the part that matters — **fails if any of them
SKIP**. `go test` reports a skipped test as `ok`, so the obvious hand-rolled
version passes cleanly with no containers running and certifies nothing:

```bash
docker run -d --name wakil-acc-mysql -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=wakilacc -p 13306:3306 mysql:8
docker run -d --name wakil-acc-mongo -p 27018:27017 mongo:7
# give MySQL ~20s to initialise on a first run

make test-live

# afterwards:
docker rm -f wakil-acc-mysql wakil-acc-mongo
```

If a container is missing or stopped, `make test-live` prints those `docker run`
lines and exits non-zero rather than quietly skipping. To point it at an engine
you manage instead, override both connection strings and the Docker preflight
steps aside:

```bash
make test-live LIVE_MYSQL_DSN='user:pw@tcp(host:3306)/db' LIVE_MONGO_URI='mongodb://host:27017/db'
```

The Mongo database name in the URI is **REQUIRED** — `driver_mongo` rejects a URI
without one ("mongo connection URI must include a database name"), which fails
every Mongo test with a message that reads like a broken suite rather than a
misconfigured one.

**Fixtures are disposable and self-created.** The MySQL tests `DROP TABLE IF
EXISTS customers` and rebuild it; the Mongo tests drop and re-seed their own
collections. Nothing depends on a pre-existing schema, so there is no fixture to
preserve and no reason to point this at a database you care about.

The equivalent by hand, if you want the environment set in your own shell:

```bash
export WAKIL_MYSQL_DSN='root:rootpw@tcp(127.0.0.1:13306)/wakilacc'
export WAKIL_MONGO_URI='mongodb://127.0.0.1:27018/wakilacc'
go test ./internal/wakilcore/ -count=1 -run 'MySQL|Mongo' -v
```

Remember that this form does **not** fail on a skip; check the output yourself.

Then the Keychain one, **separately** — it writes to your real login keychain and
may raise a GUI prompt:

```bash
WAKIL_KEYCHAIN_TEST=1 go test ./internal/wakilcore/ -run TestKeychainRoundTrip -v
```

It pins `WAKIL_ORG=wakilselftest` itself, so it always creates and deletes the one
item `wakil:wakilselftest:wakil-unit-test-ref` no matter which org's shell you run
it from, and it can never collide with a real credential.

**Result (2026-09-05):** **PASS.** Run against throwaway containers after the
final review's fixes: 15 gated tests green, including `TestMySQLEngineLevelReadOnly`,
`TestMySQLSetInjectionCannotDisableReadOnly` and `TestMySQLDoubleDashOutfileBypassIsBlocked`
— the three that pin the engine-level read-only guarantees the final review found
were bypassable.
- MySQL: PASS. Mongo: PASS.
- Keychain: **PASS** — `TestKeychainRoundTrip` green in 0.13s. macOS did **not** prompt.

**Re-run needed?** No — none of this code changed with the decoupling. Run it anyway
if the migration is the first thing you have done on this machine in a while; it is
one command and it rules out an environment problem before the interactive steps.

---

## Step 3 — Seed configuration

This is the step the decoupling changed most. There is no `mkdir ~/.wakil` and no
hand-written `projects.json` any more: the per-org tree
(`orgs/<org>/org.json`, `active.json`, `projects.json`, `providers/<id>.json`) is
written by the CLI, and `OrgDirFor` refuses an org no one ran `wakil org create` for
— which is what catches a mistyped `WAKIL_ORG` before it can quietly create state
under a phantom org.

Steps 2, 3 and 5 of `operator-todo.md`'s MIGRATION section are exactly this. In
short:

```bash
./bin/wakil org create personal --jira-base https://<site>.atlassian.net
mkdir -p ~/.claude-personal   # a claude-code provider needs a config dir that exists
./bin/wakil provider add main --kind claude-code --config-dir ~/.claude-personal --org personal
```

Then the project file itself. It must be committable and contain **no secrets** —
every credential is a `ref` pointing into the Keychain:

```json
{
  "name": "<project-name>",
  "org": "personal",
  "roots": [{ "path": "/abs/path/to/repo", "role": "api" }],
  "scopes": { "pm": { "provider": "jira", "projectKey": "<KEY>" } },
  "environments": {
    "staging": {
      "databases": [
        { "name": "core",   "driver": "mysql",  "ref": "booking-staging-core" },
        { "name": "events", "driver": "sqlite", "ref": "booking-staging-events" },
        { "name": "docs",   "driver": "mongo",  "ref": "booking-staging-mongo" }
      ],
      "api": [{ "name": "api", "baseUrl": "https://staging-api.example.com", "authRef": "booking-staging-api" }]
    },
    "production": {
      "databases": [
        { "name": "core", "driver": "mysql", "ref": "booking-prod-core" }
      ]
    }
  }
}
```

Two notes on that block, kept **outside** it because `project.json` is parsed by
`encoding/json`, which rejects comments — a fixture carrying a `//` line fails at
`LoadProject` rather than loading with the comment ignored.

- **Absolute roots are supported** (fixed in `c9876c0` — they were silently mangled
  before, and this example is what surfaced it). Relative roots resolve against the
  directory holding `.wakil/`.
- **No database here carries `readOnly`**, and none should: the key was removed from
  `Database` under issue #14, and writability now derives from `writeRef` alone. A
  file that still carries it loads fine — the key is ignored, not rejected — but
  copying it forward advertises a flag that governs nothing. See the superseded note
  in *Two things to read before you start*.

Register it in the org's registry. `project add` refuses a `project.json` whose
declared `"org"` does not match, so a file cannot be filed under the wrong org:

```bash
./bin/wakil project add <project-name> --path /abs/path/to/repo/.wakil/project.json --org personal
```

Registering does not *select* it — that is `set_project` from inside a session
(criterion 2).

Store each credential. The value is read from **stdin**, never from argv, so it
never lands in your shell history. Every command takes the org from `--org` (or
`WAKIL_ORG`); with neither set they refuse outright rather than falling back to
anything:

```bash
# Opaque values, pasted on stdin then Ctrl-D:
./bin/wakil secrets set booking-staging-api --org personal   # the API auth token
./bin/wakil secrets set jira:personal --org personal         # email:api_token, ONE line

# Composed for you, so you never hand-write a DSN. The password is read from
# stdin; everything else is a flag, because none of it is secret.
./bin/wakil secrets set-db booking-staging-core --org personal \
  --driver mysql --host <h> --port 3306 --db <d> --user <u>
./bin/wakil secrets set-db booking-staging-mongo --org personal \
  --driver mongo --host <h> --port 27017 --db <d> --user <u> --auth-source admin

# sqlite takes no host/port/user and reads no stdin — there is no password:
./bin/wakil secrets set-db booking-staging-events --org personal \
  --driver sqlite --db /absolute/path/to/events.db
```

The org you pass here must match `project.json`'s `"org"` and the org the servers
were registered with (Step 4) — `personal` in this example. Nothing can detect a
mismatch for you: a credential stored under the wrong org is a perfectly good item
at an address nothing will ever read. `wakil` therefore prints the org it resolved
in both the paste prompt and the confirmation line, so a mismatch is visible before
you paste.

`--auth-source admin` matters: without it the driver authenticates against the
*data* database, and a least-privilege reader created in `admin` will fail to
authenticate. See `operator-todo.md` §2.

**Result (2026-09-05):** PASS, with one correction. `jira:personal` was first stored
as a bare API token; `wakil-pm` rejected it with
*"stored Jira credential for jira:personal must be email:api_token"* — naming the ref
and the expected shape. Re-stored as `email:token` and it worked. This is the §6
"errors are human sentences" requirement doing its job on the first real mistake made
against it.

**Re-run needed?** Yes, in full — the paths, the commands and the Keychain naming all
changed. The recorded result above says nothing about the current CLI.

---

## Step 4 — Register the servers per provider, and launch clean

One invocation per (org, provider) pair. The script reads the provider's recorded
`configDir` via `wakil provider config-dir`, exports it so `claude mcp add` writes
into that account's own configuration, and pins `-e WAKIL_ORG` and
`-e WAKIL_PROVIDER` on every one of the five servers:

```bash
make build
export PATH="$PWD/bin:$PATH"   # the script shells out to `wakil` and `claude`

scripts/register-provider.sh personal main "$PWD/bin"
```

It refuses to do anything unless `claude` and `wakil` are on `PATH`, all five
binaries are present and executable in the bin directory, the org is registered, the
provider is registered under that org, and the provider's recorded config dir still
exists — naming the exact command to run for whichever is missing. A re-run is the
normal way to change something (a new bin path after moving the repo): each server is
removed before being re-added, so a re-run cannot abort on "already registered" and
leave the provider half-wired.

It does **not** pass `CLAUDE_CONFIG_DIR` to the servers, and does not pass
`WAKIL_JIRA_BASE` to anything. A server derives nothing from the config dir any more,
and the Jira site lives in `org.json` where an org's several providers cannot
disagree about it.

Launch with the key genuinely unset — `env -u`, not `ANTHROPIC_API_KEY=`:

```bash
env -u ANTHROPIC_API_KEY \
  CLAUDE_CONFIG_DIR=~/.claude-personal \
  CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_PERSONAL_TOKEN" \
  claude
```

`CLAUDE_CONFIG_DIR` here selects which *account* Claude Code runs as — that is still
its job, and the only one it still has. It no longer selects the org; the servers
carry `WAKIL_ORG` from their registration.

**Result (2026-09-05, on the predecessor script):** PASS after a **defect was found and
fixed** (`51b4019`). `scripts/register-org.sh` was not idempotent: `claude mcp add`
refuses an existing name, so re-running aborted on the first server and reported the org
"only partially registered" while leaving it unchanged. The real cost was silent — an org
registered without a Jira base, re-run *with* one, aborted, and `WAKIL_JIRA_BASE` was
still missing. Idempotence carried forward into `register-provider.sh` and is pinned by
`scripts/register_provider_test.go`.

**Re-run needed?** Yes — different script, different arguments, and the properties it
now guarantees (org pinned on every server, config dir exported not passed) were never
exercised by hand.

---

## Step 5 — The seven exit criteria

Do these inside the Claude Code session from Step 4.

### 1. The Wakil servers are listed

Run `/mcp`. Expect five servers and these 16 tools:

| Server | Tools |
|---|---|
| `wakil-ctx` | `get_context`, `set_project`, `set_environment`, `list_projects`, `list_environments`, `list_sessions`, `get_session` |
| `wakil-db` | `list_databases`, `list_tables`, `describe_table`, `query` |
| `wakil-pm` | `my_issues`, `search_issues`, `get_issue` |
| `wakil-http` | `request` |
| `wakil-recall` | `recall` |

**Result (2026-09-05):** PASS. All five servers and all 16 tools listed.

**Re-run:** mechanical. Same five servers, same 16 tools; only how they were
registered changed.


**Result (re-run 2026-09-07):** PASS. `/mcp` listed all five servers and all 16
tools, under provider `main` in `~/.claude-personal`.

### 2. Context switching

> set project to `<name>`, environment staging

Then ask for `get_context`. Expect the right org, project, and environment.

**Also check the provider report**, which is new: `get_context` now returns
`provider: {selected, running, match, note}` — the provider the active project (or the
org's `defaultProvider`) prefers, versus the one actually running, taken from
`WAKIL_PROVIDER`. It never blocks anything; it is there so a session can say *which
account is doing this work*. With the single provider from Step 3 registered, expect
`selected` and `running` to agree, or `selected` empty with a note saying nothing was
declared.

**Result (2026-09-05):** PASS. (Pre-decoupling: no provider report existed, and the
active context came from a single global file.)

**Re-run:** yes. The context now lives at `orgs/<org>/active.json`, and the provider
report is untested by hand.


**Result (re-run 2026-09-07):** PASS. `get_context` returned org `personal`,
project `wakil-acceptance`, environment `staging`, both roots, both environments'
databases and the PM scope `INI`, read from `orgs/personal/active.json`.

The provider report was present and correct: *"no provider pinned by project/org;
currently running `work`"* — `selected` empty because neither the project nor the
org declares a `defaultProvider`, `running` taken from the pinned `WAKIL_PROVIDER`.
Non-blocking on every path, as designed.

### 3. Jira

> what's assigned to me on umbrella

Expect real issues from your project. If Jira is not configured yet, the failure
should name *which* thing is missing — an unset base URL, a locked Keychain, and a
missing credential are three different messages.

The base URL now comes from that org's `org.json` (`wakil org create|set
--jira-base`), read on every call. `WAKIL_JIRA_BASE` still overrides it, but only as
a diagnostic tool for a wrong `org.json` — nothing sets it for you, and
`register-provider.sh` deliberately does not.

**Result (2026-09-05):** PASS on re-run. Initially blocked on a malformed credential,
with exactly the right message (see Step 3); correct once re-stored as `email:token`.

**Re-run:** yes — the site now comes from a file rather than the environment, and
`org.json` has never been the source in a live session.


**Result (re-run 2026-09-07):** PASS. `my_issues` returned 50 INI issues from
`https://initech.atlassian.net`, with the page honestly marked truncated. The base
URL came from `orgs/personal/org.json`; `WAKIL_JIRA_BASE` was not set anywhere, so
this is the first live proof that `org.json` is the source.

One setup defect, found the hard way: `wakil org create` had been run *without*
`--jira-base`, leaving `org.json` as `{}`. Nothing complained until the first Jira
call. Worth knowing that an org with no site is created silently — `wakil org set
personal --jira-base ...` is the fix, and `cat ~/.wakil/orgs/<org>/org.json` is the
one-second check.

### 4. All three database drivers

Ask for a real row from each connection in turn — MySQL (`core`), SQLite
(`events`), Mongo (`docs`):

> fetch customer 42 from staging

**Result (2026-09-05):** PASS. Row 42 (Ada Lovelace, gold) returned from MySQL, SQLite
and Mongo, consistent across all three.

On the FIRST pass **`list_databases` and `list_tables` failed**, and the session had to guess table and
collection names to get there. Root cause: both declared a slice-typed `Out`, so their
advertised `outputSchema` was a top-level JSON array where MCP requires
`structuredContent` to be an object — a protocol violation a validating client rejects
outright. Fixed in `c9876c0` by wrapping each in a struct; a new
`TestOutputSchemasAreObjects` in all five servers now asserts every tool advertises
`"type":"object"`.

On the re-run both worked: the session listed containers in all three stores and found
`customers` in each before querying — no guessing.

Also noted, not a defect: the Mongo document keys on `_id`, not `id`, so a wrong guess
returns an empty result that reads like "customer 42 is absent" when it is not. A
cross-store lookup has to map that field.

**Re-run:** yes, but as a credential check rather than a driver check. The drivers were
not touched; what is unproven is that your Keychain items are reachable under
`wakil:<org>:<ref>`.


**Result (re-run 2026-09-07):** PASS. `list_databases` and `list_tables` both
worked — no guessing this time — and customer 42 (Ada Lovelace, ada@example.com,
gold) came back identical from mysql `core`, sqlite `events` and mongo `docs`. The
session hit the empty first result on Mongo and worked out the `_id` vs `id`
difference by itself.

Credential reachability under `wakil:<org>:<ref>` — what this re-run was actually
testing — confirmed for all three refs.

**Setup note.** `make test-live` drops and rebuilds `customers` in the shared
`wakilacc` MySQL database, so running it before this criterion replaces the fixture
with the tests' own two-column table. Re-seed after any `make test-live`.

### 5. Writes are refused — the important one

Ask it, one at a time, to run:
- a SQL `DELETE` (or `UPDATE`, or `DROP`)
- a Mongo `deleteMany`
- an HTTP `POST`

Each must be refused with a **human sentence**, not a stack trace, and no data may
change. Then switch to `production` and confirm reads still work and writes are
refused there too.

Remember: this is testing the gates, not `"readOnly"`. There is no override.

**Result (2026-09-05):** **PASS — the strongest result of the run.** All three refused
before reaching any backend, each by a different mechanism:

| Attempt | Refusal |
|---|---|
| `DELETE FROM customers WHERE id = -1` (mysql) | only SELECT/EXPLAIN/SHOW queries are allowed (read-only) |
| `deleteMany {_id:-1}` (mongo) | mongo op deleteMany is a write and was blocked (read-only) |
| `POST /post` (httpbin) | only GET/HEAD requests are allowed in read-only mode |

Three independent layers — SQL verb allowlist, Mongo op classification, HTTP method
allowlist — not one shared check. All failed closed with a reason rather than erroring
vaguely or silently doing nothing.

Depth beyond the gate: the throwaway MySQL and Mongo users were created with `SELECT` /
`read` grants only, so the credentials themselves cannot write even if something reached
them by another route. SQLite additionally opens with `mode=ro`.

Two observations from the re-run worth keeping. The SQL guard is statement-type based,
so it rejected on the `DELETE` keyword before the row filter was ever evaluated — the
zero-row `WHERE` the session used as a safety net was never needed. And `wakil-http`
refuses twice over: its schema declares only GET/HEAD, and the server rejects POST
independently, so ignoring the schema does not get a write through.

Not covered: a write probe against the `events` (SQLite) connection, and the `production`
environment.

**Re-run:** the gates are unchanged by the decoupling, so this PASS still stands on its
own code. Re-run it regardless — it is three prompts, and it is the criterion the
charter's read-only invariant rests on. Close the two gaps above while you are there.


**Result (re-run 2026-09-07):** PASS for everything a session can reach — and the
two gaps left open on 2026-09-05 turn out to be **unreachable from a session by
construction**, not merely untested.

| Attempt | Outcome |
|---|---|
| `DELETE FROM customers WHERE id = -1` (mysql `core`) | refused — *only SELECT/EXPLAIN/SHOW queries are allowed (read-only)* |
| `deleteMany {_id:-1}` (mongo `docs`) | refused — *mongo op deleteMany is a write and was blocked (read-only)* |
| `DELETE FROM events WHERE id = -1` (sqlite `events`) | refused — same SQL gate. **This closes one of the two 2026-09-05 gaps**: the sqlite connection had never been write-probed |
| production read from `core` | worked — environment switched, `acc-prod-core` resolved from the Keychain, `customers` and `orders` listed |
| `POST` via `wakil-http` | **not reachable from a session** |
| `DELETE` under `production` | **not reachable from a session** |

Neither unreachable case is a coverage hole, and neither should cost a future
operator any time:

- **POST.** `request`'s `method` is an enum of `GET`/`HEAD` only, so a conforming
  MCP client rejects `POST` during input validation before the server is ever
  invoked. The server's *independent* refusal — the second of `wakil-http`'s two
  layers, recorded on 2026-09-05 — is asserted by
  `cmd/wakil-http/main_test.go:205`, which calls the tool directly with
  `{"method":"POST"}` and requires the error to say `read-only`. A test can bypass
  schema validation; a well-behaved client cannot.
- **Production.** The model declined the `DELETE` on its own safety grounds and
  never invoked the tool. The question is moot regardless: `AssertSQLReadOnly` is
  bound at the driver (`driver_mysql.go:17`, `driver_sqlite.go:18`) and receives
  `spec.Raw` — the SQL string — and nothing else. The gate's signature carries no
  environment, so there is no code path on which `production` and `staging` could
  diverge. That is a stronger guarantee than a successful manual probe would have
  supported.

**The lesson, recorded so it is not re-learned.** A criterion whose remaining steps
are intercepted by the tool schema and by the model's own refusal is not a criterion
a session can settle. Test those two properties in Go. The three gates that *are*
session-reachable — SQL verb allowlist, Mongo op classification, and the sqlite leg
added here — remain worth running by hand every time, because they are what the
charter's read-only invariant rests on.

### 6. Session discovery

> show my recent sessions on this project

Expect sessions across all of the project's roots, **including one you started
outside Wakil** — open a plain `claude` session in one of the roots first so there
is something to find.

**This criterion tests different code than it did on 2026-09-05.** `sessionsRoot()`,
which read `$CLAUDE_CONFIG_DIR/projects` and fell back to `~/.claude/projects` when
unset, was deleted. `ListSessions` now enumerates every provider registered under the
active org and reads each `claude-code` provider's *recorded* `configDir`, so:

- Each session carries a `provider` field naming the store it came from.
- `unreadProviders` names providers whose stores could not be looked inside — a kind
  with no session adapter (`codex`, `local`), a `claude-code` record with no
  `configDir`, an unreadable store, or an unparseable record. A provider that has
  simply never run a session is *not* listed there: its empty answer is known, not
  unknown.
- `skipped` (omitted when zero) counts transcript directories or files the search
  could not read, so an empty `sessions` array with a non-zero `skipped` means "could
  not look", not "none exist".

**Worth doing deliberately:** register a second provider under the same org, run a
session under each, and confirm one `list_sessions` call returns both, each tagged
with the right provider. That is the multi-provider promise the whole decoupling was
for, and no human has watched it work.

⚠️ **Also re-run this specific check.** `EncodeRootPath` maps both `/` and `.`
to `-`. The `.` half was confirmed on 2026-09-05 (see below), but it costs nothing:

```bash
mkdir -p /tmp/wakil.dot.test && cd /tmp/wakil.dot.test && claude   # exit immediately
ls ~/.claude-personal/projects | grep -i dot
```

Expect `-tmp-wakil-dot-test`. If you get something else (e.g. dots preserved), the
replacer in `internal/wakilcore/sessions.go` needs extending and its test updating.
Note the directory to look in is now the *provider's* config dir, not `~/.claude`.

**Result (2026-09-05):** PASS on re-run. On the first pass it FAILED with **two more
defects**, both fixed in `c9876c0`. After the fix the tool listed all four sessions on the
`wakil.acceptance` root, newest first, with `skipped: 0` — so the caller can tell a
complete listing from a partial one.

1. `list_sessions` had the same slice-typed-`Out` protocol violation as criterion 4.
2. `ListSessions` mangled **absolute** `roots[].path` values:
   `filepath.Join(projDir, "/abs/path")` concatenates rather than treating the second
   element as absolute, so the encoded prefix never matched and the call returned zero
   sessions **with a nil error** — indistinguishable from "this project has no sessions".
   The example in Step 3 of this very document uses absolute roots, so anyone following it
   hits this.

`get_session` was the same root cause, not a third bug: it filters `ListSessions`, so it
reported "session not found" for the session it was running inside. Verified after the
fix: all three sessions found, and `get_session` resolves `28a20e7b` correctly.

⚠️ The session diagnosed this as `wakil-ctx` hardcoding `~/.claude/projects`. **That was
wrong** — the lookup correctly returned `/Users/operator/.claude-personal/projects` and the
directory existed. The per-org plumbing was never at fault.

**dot encoding: CONFIRMED.** `/Users/operator/wakil.acceptance` produced
`-Users-operator-wakil-acceptance`. This closes the open risk flagged above: the `.`→`-` rule
had no real-world sample among the 73 existing project directories, and is now evidence
rather than inference. Recorded in `EncodeRootPath`'s doc comment.

**Re-run:** yes, and this is the one to spend time on.


**Result (re-run 2026-09-07):** PASS — and this is the criterion the decoupling most
needed to prove.

`list_sessions` returned 9 sessions on the `wakil.acceptance` root, newest first,
each tagged with the provider whose store it came from: 4 under `main`
(`~/.claude-personal`) and 5 under `work` (`~/.claude-initech`), both registered under
org `personal`. `skipped: 0`, `unreadProviders` empty. One call, two Claude
accounts, correctly attributed — the multi-provider promise, watched working for the
first time.

**dot encoding: re-confirmed.** `/tmp/wakil.dot.test` produced
`-private-tmp-wakil-dot-test` in `~/.claude-personal/projects`. Note macOS resolves
`/tmp` to `/private/tmp` before the encoder sees it, so the recorded name is longer
than the path you typed — expected, and not a bug in `EncodeRootPath`.

**Two procedural traps worth recording**, because both produce zero sessions and
look exactly like "session discovery is broken":

1. Launching with plain `claude` reads `~/.claude`, not the provider's config dir.
   The transcript lands somewhere `ListSessions` will never look.
2. Exiting a session without sending a message writes no `.jsonl` at all. Seeding a
   provider's store requires `CLAUDE_CONFIG_DIR` pinned *and* at least one prompt
   sent and answered.

### 7. Cross-org guard

From a session registered for one org, try to select another org's project:

> set project to `<a initech project>`

Must be rejected. This is the guard that keeps one org's credentials away from
another org's work.

**Result (2026-09-05):** **PASS**, and the guard is stronger than this criterion asks for.
Measured from a session running as org `initech` against the project bound to org `personal`:

| Operation | Outcome |
|---|---|
| `set_project wakil-acceptance` | refused — *belongs to org "personal" but the active org is "initech"* |
| `Resolve()` | refused |
| `ResolveEnvironment()` | refused — **the databases are unreachable, not merely unnamed** |
| `active.json` afterwards | **unchanged** |

Two things worth recording, because neither is obvious from the criterion:

1. **The refusal writes nothing.** `SetProjectChecked` returns before it touches
   `active.json`, so a rejected switch cannot leave partial state. The acceptance session
   reported *"I set the project name in the ctx store"* — that was wrong; nothing was
   written, and the file was verified byte-identical afterwards.
2. **The guard is on the operation, not on the storage.** `Resolve()` re-checks
   `proj.Org` against `CurrentOrg()` on *every call*, so an org that can see a foreign
   project's registry entry still cannot use what it points at. Defence on the
   operation rather than on the storage, the same posture as `DoRequest` validating its
   own base URL. Anyone tempted to "optimise" that repeated check should read this first.

> **Amended 2026-09-06.** The original wording of (2) explained the re-check by
> pointing at `~/.wakil/active.json` being "a single global file shared by both orgs
> — org is not part of its path". That file is now per-org
> (`orgs/<org>/active.json`), so the premise is gone but the conclusion is not: the
> re-check is still what makes the guard hold, and `activePath()`'s doc comment says
> so explicitly — *"Safety does not rest on the per-org split."* Two independent
> mechanisms now, and only the second is load-bearing.

**Re-run:** yes. The outcome should be identical; what is unproven is that it is still
identical now that each org has its own context file, and that `WAKIL_ORG` — declared at
registration rather than derived from a directory — is what the guard compares against.
Do it by launching the session registered for a *different* org, not by exporting
`WAKIL_ORG` in your shell: the registered value wins, and testing the shell variable
tests nothing a real session would ever hit.


**Result (re-run 2026-09-07):** PASS, both halves, and stronger than 2026-09-05.

Measured from a session pinned to org `initech` (`~/.claude-initech` temporarily
re-registered as provider `main` under `initech` for the purpose), against the project
filed under `personal`:

| Operation | Outcome |
|---|---|
| `list_projects` | empty — org `initech`'s registry holds nothing |
| `set_project wakil-acceptance` | *"unknown project"* — never reaches the org check |
| `set_project wakil-acceptance`, with a misfiled entry hand-planted in `orgs/initech/projects.json` | refused, naming both orgs, and quoting the exact `wakil project rm` / `wakil project add ... --org personal` remediation |
| `orgs/initech/active.json` afterwards | **does not exist** |

Two things the per-org split changed, both in the guard's favour:

1. **There are now two mechanisms, and the first one is new.** Registries are
   per-org, so a foreign project is not merely unusable — it is invisible. Reaching
   `Resolve()`'s org re-check at all required *hand-planting* a misfiled entry,
   because `wakil project add` refuses to create one. The 2026-09-05 run could reach
   the re-check directly, since a single global `projects.json` was shared.
2. **The refusal writes nothing — demonstrated harder than before.** On 2026-09-05
   `active.json` was verified byte-identical afterwards. Here it was never created
   at all: after a rejected `set_project`, `orgs/initech/active.json` does not exist.

`activePath()`'s doc comment — *"Safety does not rest on the per-org split"* —
remains correct, and is now the second of two independent mechanisms rather than the
only one.

---

## One config dir serves one org

**Found during the 2026-09-07 re-run.** Not a defect in any criterion — every
criterion passed — but a limit on what the org/provider model can express, and it
is currently silent.

`register-provider.sh` writes the five servers into a provider's `configDir` under
fixed names (`wakil-ctx`, `wakil-db`, …), each pinned with `-e WAKIL_ORG`. A config
dir therefore holds exactly one set of five, and exactly one org. Registering a
second (org, provider) pair against the same config dir **overwrites the first**,
because the script removes each name before re-adding it — the idempotence that
makes a re-run safe is the same thing that makes the second org win.

Reproduced by accident, then confirmed by reading `.claude.json`:

```
wakil provider add main --kind claude-code --config-dir ~/.claude-initech --org initech
scripts/register-provider.sh initech main <bin>          # WAKIL_ORG=initech

wakil provider add work --kind claude-code --config-dir ~/.claude-initech --org personal
scripts/register-provider.sh personal work <bin>     # WAKIL_ORG=personal — overwrites
```

Afterwards `~/.wakil/orgs/initech/providers/main.json` still exists and still names
`/Users/operator/.claude-initech`, but no config dir on the machine launches a server with
`WAKIL_ORG=initech`. Nothing detects this: `provider add` accepts a `configDir` already
claimed by another org, and `register-provider.sh` overwrites without comment. The
first symptom is a session that silently runs as the wrong org — which is precisely
the failure `-e WAKIL_ORG` exists to prevent, arriving by a different route.

**This contradicts Invariant 4 as amended.** *"One organisation may hold several
providers, and one provider may serve several organisations"* — the first half
holds and criterion 6 proves it. The second half does not, for `claude-code`: org
identity is pinned inside the config dir, so the config dir remains an org boundary
in practice even though it is no longer one by design.

Two candidate fixes were recorded:

1. **Refuse the collision.** `wakil provider add` rejects a `configDir` already
   registered under a different org, naming the other org. Cheap, honest, and makes
   the limitation explicit at the point someone hits it. **Implemented 2026-09-07.**
2. **Namespace the server names per org** (`wakil-ctx@initech`), so one config dir can
   carry several orgs' registrations at once. Delivers Invariant 4's second half
   properly, but changes every tool name a session sees. **Not implemented**, and not
   planned until a second Claude account for a second org is actually wanted.

### What fix 1 does — implemented 2026-09-07

`AddProvider` (`internal/wakilcore/provider.go`) now refuses a `configDir` that any
provider in **any** org already records, and names the owner:

```
configDir "/Users/operator/.claude-initech" is already registered to provider "main" in org
"initech" — one config dir serves exactly one (org, provider) pair, because
scripts/register-provider.sh pins WAKIL_ORG and WAKIL_PROVIDER inside it and a second
registration would overwrite the first. Use a different config dir, or release this
one with: wakil provider rm main --org initech
```

Three details, each with a reason:

- **Any collision, not just cross-org.** The doc's original fix 1 said "a different
  org". But two providers in the *same* org sharing a config dir is the same bug one
  level down: `register-provider.sh` pins `WAKIL_PROVIDER` too, so the second
  registration wins and sessions get tagged under the wrong provider. The guard
  enforces the working rule below as a real invariant.
- **Symlink-resolved, not string-compared.** The candidate `configDir` goes through
  `EvalSymlinks` before the scan, so a symlink to a claimed directory — the same
  directory by another name — is caught.
- **No `--force`.** Reusing a config dir means `wakil provider rm` the old provider
  first. That is one extra command in a rare workflow, and it leaves no state in which
  two records claim one directory. The refusal prints the exact `rm` to run.

Two things it deliberately does not do. It is **add-time only**: a collision already on
disk from before the guard stays there, so check `wakil provider list --org <each>` once
after upgrading rather than expecting a retro-scan. And a corrupt provider record is
skipped by `listProvidersFor` and so cannot be reported as an owner — such a record is
already invisible to every other caller, and failing the add instead would let one bad
file block all registration.

The working rule is unchanged and now enforced: **one config dir per (org, provider)
pair**, and a second Claude account for a second org needs its own config dir and its
own login. Testing criterion 7 on this machine required temporarily flipping
`~/.claude-initech` to org `initech` and flipping it back afterwards; under the guard that
sequence is `provider rm` then `provider add` rather than a silent overwrite.

---

## Step 6 — Record and commit

```bash
git add docs/wakil/phase-1-acceptance.md
git commit -m "docs: Phase 1 acceptance results, post-decoupling re-run"
```

Record each criterion's outcome under a dated **Result (re-run YYYY-MM-DD)** line
below the existing one. Keep the 2026-09-05 entries: a criterion that passed under one
model and failed under the next is the most informative thing this document could ever
contain, and overwriting is how that gets lost.

---

## Step 7 — Known deviations from the spec, for you to ratify  ✅ prepared for you

These are decisions taken during implementation that differ from the spec as
written. None is a defect; each wants a yes or no from you.

1. **Jira auth uses a `jira:<org>` Keychain ref, with the site in the org's
   `org.json`**, rather than reusing Claude Code's stored Atlassian OAuth token (spec
   §4.2 left this open). Simpler, and consistent with the ref→Keychain pattern every
   other credential uses. *(Updated 2026-09-06: the site used to come from
   `WAKIL_JIRA_BASE`, baked into each registration. It moved into `org.json` so an
   org's several providers cannot disagree about which Jira site they point at; the
   env var survives as an override only.)* Revisit if reusing the existing Atlassian
   MCP token proves preferable.
2. **SQLite was built before MySQL** (the spec listed MySQL first) because it needs
   no Docker and proves the whole `DbDriver`→`sqlConn`→server pipeline on the
   fastest test loop.
3. **`recall` returns `{groups, sources}`**, not the bare `{jira: [...]}` the spec's
   table sketches. `groups` holds exactly that shape one level down; `sources` says
   whether each source actually answered. Without it, "Jira answered and nothing
   matched" is indistinguishable from "Jira was never configured" — and an LLM told
   "no results" will confidently report there are none.
4. **`recall` results carry no recency ordering.** `SearchIssues` wraps every
   fragment as `project = <key> AND (<jql>)`, and JQL's `ORDER BY` may not appear
   inside a parenthesised sub-clause, so adding one would make every recall call
   fail with a Jira 400. §4.5 asks for "no unified ranking" anyway.
5. **`recall` snippets carry the issue *status*, not an excerpt.** `Issue` is a
   five-field projection with no description or comment body to quote. Widening it
   is Phase 1 scope you may want to claim — it compounds with (6).
6. **`get_issue` does not return comments**, though spec §4.2 says "one issue with
   comments". Now **recorded in code and carried to Phase 2**, not merely observed:
   `wakilcore.GetIssue`'s doc comment states what the spec asks, what the function
   actually returns, and why the gap was left open; and `wakil-pm`'s `get_issue`
   tool description says plainly that comments are absent and that a model must not
   conclude from the result that an issue has no discussion. That second one is the
   operationally important half — the description is what an LLM reads, and a model
   that assumes it has seen the comments will confidently report there are none.
   `TestGetIssueDescriptionDisclosesMissingComments` pins it via `ListTools`.

   Not implemented, deliberately. It is not a wider field list: `search()` is shared
   by all three read paths, comment bodies arrive as Atlassian Document Format
   rather than text, and comments page independently and unbounded. None of that
   can be measured from this branch — there is no live Jira instance available —
   and the standing rule here is that an integration is measured, not inferred.

---

## What the run found — summary

**All seven exit criteria passed on 2026-09-05**, against the pre-decoupling model.
Criterion 5 (writes refused) and criterion 7 (cross-org guard) are the two that matter
most for the charter's read-only and per-org promises, and both held under direct
attack.

Four defects, none of which the unit suite could have caught, because each
lived in the gap between the code and a real client:

| # | Defect | Fixed in |
|---|---|---|
| 1 | `register-org.sh` not idempotent; a re-run aborted and silently left `WAKIL_JIRA_BASE` missing | `51b4019` |
| 2 | `list_databases`, `list_tables`, `list_sessions` advertised a top-level array output schema — an MCP protocol violation that validating clients reject | `c9876c0` |
| 3 | `ListSessions` mangled absolute `roots[].path` via `filepath.Join`, returning zero sessions with a nil error | `c9876c0` |
| 4 | `get_session` inherited (3), reporting "session not found" for the session it was running inside | `c9876c0` |

Two of these were controller rulings that turned out to be wrong, and both are now
recorded as such in the code rather than quietly reversed: `mcpx.go`'s claim that a
slice-typed `Out` was a cosmetic artifact, and the assumption that an absolute root
path would round-trip through `filepath.Join`.

Defect 1 is also the clearest argument for re-running rather than trusting the table:
it was a setup-script bug that no test could see and that only appeared on the second
invocation. The setup script has since been replaced wholesale.

### Deferred, not defects

- **`list_sessions` returns no `firstPrompt`.** This matches spec §5, which assigns the
  first prompt to `get_session`. But it means a model listing sessions sees only IDs,
  timestamps and now a provider tag, and cannot tell them apart without N follow-up
  calls — which is exactly why the acceptance session fell back to reading transcripts
  off disk. Worth revisiting; the provider tag added by the decoupling helps
  attribution but not recognition.
- **No write probe against the SQLite `events` connection**, and none against
  `production`. Criterion 5 covered MySQL, Mongo and HTTP.
- **`wakil` is not on `PATH`** for a session (deliberately — it is the operator's tool,
  not an MCP server), so a session cannot inspect or repair its own stored credentials.
  The error message names the ref and the org, but not where they live.
- **No provider-kind coverage beyond `claude-code`.** `codex` and `local` providers can
  be registered and are honestly reported as having no session adapter, but nothing has
  ever run against one.
