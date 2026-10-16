# Shared accounts across orgs — acceptance

**Status: WALKED IN FULL, 2026-09-14. All eight result rows PASS.** Four defects were
found, three of them in this document rather than in the code; D1 and D4 are fixed here,
D2 and D3 were carried out of the walk and **both are fixed as of 2026-09-14**, after the
walk rather than during it; §4 records each fix under its own entry.

The walk's headline result is check 6 pass A, because it settles a question older than
this sub-phase: **`--strict-mcp-config` holds on an enterprise account.** The whole design
rests on a Wakil session never reading the config dir's pinned servers, and that had been
measured on the `max` account only — `phase-2a-probe.md` §5 says so in as many words, and
charter Decision 5 warns that team and enterprise managed settings could constrain it.
Sharing is the feature that puts a managed account under that flag in another org, so the
question stopped being theoretical. It is now measured on the strictest tier available.

Every check below was written for the operator to run against a live machine. The automated suite is green (§3), and a
green suite is the floor this project has now stated three times is not the ceiling —
see `phase-2c-ii-b-acceptance.md` §3 and §5. Nothing here upgrades that floor to a
result. Do not mark the `north-star.md` row for this work as met on the strength of this
document; mark it met only after someone has walked it and filled in §2's blank Result
rows.

This is the acceptance runbook `docs/superpowers/specs/2026-09-14-shared-accounts-across-orgs-design.md`
§6 requires, for the sub-phase that lets one Claude account (one config dir) be
registered under more than one org. The design's own words for why a runbook is needed
at all, restated because they are the reason this document exists rather than a
green `go test ./...`: *"a green suite is the floor and decides nothing above it — 649
tests were green at every point where 2c-ii was shipping a defect, and 709 were green
through 2c-ii-b's six."*

## 1. Scope — what is under test, and what is not

**Under test here, because Tasks 1–4 built it:**

- The five-row refusal matrix in `AddProvider` (`internal/wakilcore/provider.go`), walked
  at the `wakil provider add` CLI surface rather than as a Go unit test — checks 1–4.
- `scripts/register-provider.sh`'s refusal to re-pin a config dir another org homes,
  before any `claude mcp add` runs — check 5.
- The one claim Wakil sessions depend on and Go cannot verify: that a shared account's
  children see the *sharing* org's `WAKIL_ORG`, not the homing org's — check 6. That
  claim rests on `--strict-mcp-config` holding, which has been measured on the `max`
  account only; check 6 is therefore walked twice, one of the two on the **enterprise**
  account, and says why in its own text.
- The one claim plain Claude Code depends on and Wakil cannot verify: that a shared
  directory's headless flow is untouched — check 7.

**Not under test here, because the design's §5 says it does not change and nothing in
Tasks 1–4 touched it:**

- The Keychain service scheme (`wakil:<org>:<ref>`), `writeGate`, the production block,
  and the cross-org project guard — none of the four is read or written by sharing.
- Session-list scoping under a shared config dir. The design's §5 argues this was
  already correct before Tasks 1–4 (`ListSessions` filters by the active project's roots
  and does not count a confirmed non-match toward `skipped`) and records the walk that
  would confirm it as belonging to *this* runbook's design document — spec §6's check 3.
  It is deliberately **not** one of this runbook's seven: the operator asked for seven,
  the design's own verification section lists three, and the third (session-list
  scoping) is folded into check 6's window session rather than walked as a separate
  check, since both need the same live window open under a shared account.
- Anything cosmetic in the provider picker (⌘P). The design's §5 states plainly that
  marking a shared row is not built, and this runbook does not go looking for it.
- **The multi-org window design** (`2026-09-14-multi-org-window-design.md`) — that
  sub-phase depends on this one and has its own runbook when it ships.
- **Quota visibility.** The motivation for this whole sub-phase — swapping to an account
  with usage left — is not delivered by it. Wakil still discovers an exhausted account
  by being refused mid-turn; this is recorded as an open question in the design's §8 and
  is not a check here.

### 1.1 Prerequisites

1. Three orgs, each already homing its own config dir — this machine's current state
   (see `operator-todo.md`'s "Shared accounts" section) satisfies this: `personal` homes
   `~/.claude-personal`, `initech` homes `~/.claude-initech`, `umbrella` homes `~/.claude-umbrella`.
2. `make build`, run from the repo root, so `bin/wakil` reflects Tasks 1–4 and
   `"$PWD/bin"` names the directory check 5's command below expects as its third
   argument.
3. For checks 1–4: no state from a previous walk of this same runbook left in
   `~/.wakil` — each check registers and (where it succeeds) should be removed with
   `wakil provider rm <id> --org <org>` before the next, so the matrix is walked against
   a clean slate each time rather than against leftovers from the previous check.
   **Remove a sharing binding before the record that homes its directory**, always:
   `provider rm` refuses to delete a home while other orgs still share it, and names
   them. That refusal is deliberate — deleting a home strands every sharer with no
   command that can re-home the directory — so it is a prerequisite's ordering note and
   not a defect to raise. Nothing here asks you to remove the three `main` providers
   this machine already has; only the ids these checks create.
4. For checks 6 and 7: at least one org already carrying a Wakil-only binding to another
   org's account — `operator-todo.md`'s migration section gives the exact commands.
   Check 6 additionally needs a database defined only in the sharing org's project, so
   that a successful query is evidence the child ran under the sharing org and not the
   homing org by coincidence.
5. **For check 6, the shared binding's OAuth token stored under the SHARING org** —
   `wakil secrets set provider:<binding-id> --org <sharing-org>`, the second command of
   each pair in `operator-todo.md`'s migration section. This is a prerequisite and not a
   step of the check because getting it wrong does not produce an interesting failure,
   it produces a boring one: `wakil provider credentials` resolves
   `provider:<id>` under the org it is called with, and the window bakes its own org into
   that lookup (`WakilCLICredentialsLookup`, `WindowSession.swift`), so a `initech-main`
   binding in `personal` reads `wakil:personal:provider:initech-main` — an item that does not
   exist merely because `wakil:initech:provider:main` does. Without it check 6 fails at
   "select the shared provider", before any of the things it is actually measuring. Confirm
   with `wakil provider credentials <binding-id> --org <sharing-org>` before opening the
   window; it prints the token or says what is missing.
6. **For check 6, the `umbrella` (enterprise) account available as one of the two ends** —
   see that check's own note on why the plan tier is part of what it measures.

## 2. The checks

Nothing here is marked PASS. Each check is written for the operator to walk; the
**Result** row under each is left blank on purpose.

### Check 1 — `wakil provider add` without `--share`, against a dir another org homes

| Do this | Expect |
|---|---|
| `wakil provider add work --kind claude-code --config-dir ~/.claude-initech --org personal`, where `initech` already homes `~/.claude-initech` | Refused. The message names the owning org (`initech`), the owning provider (`main`), and names `--share` as the way to proceed |

The refusal is `AddProvider`'s own text: *"configDir … is already registered to
provider "main" in org "initech" — that org pins WAKIL_ORG inside the directory … To use
this same account from org "personal" inside Wakil, re-run with --share …"*
(`internal/wakilcore/provider.go`). `TestAddProviderShareMatrix`'s first subtest asserts
this shape at the Go level; this check is the same refusal read at the CLI, against a
real config dir on this machine.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Walked at the CLI against the real `~/.claude-initech`. Refusal named `initech`, `main` and `--share`, verbatim as this check predicts. Exit 2. |

### Check 2 — the same command, with `--share`

| Do this | Expect |
|---|---|
| `wakil provider add work --kind claude-code --config-dir ~/.claude-initech --org personal --share` | Accepted. `wakil provider add`'s own stderr, printed only because `--share` was set, names the org that still homes the directory: *"this account is shared: initech/main still pins WAKIL_ORG inside … , so a plain `claude` session started there runs as "initech", not "personal". Inside Wakil it runs as "personal" …"* |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | `work` registered under `personal`. The `--share`-only stderr named `initech/main` as still pinning the directory and stated both halves — plain `claude` there stays `initech`, inside Wakil it runs as `personal`. |

### Check 3 — `--share` against a dir nobody has registered

| Do this | Expect |
|---|---|
| `mkdir -p /tmp/never-registered && wakil provider add ghost --kind claude-code --config-dir /tmp/never-registered --org personal --share`, against a directory that exists but that no `wakil provider add` has ever named | Refused with *"nothing to share: no org has registered configDir … yet. Drop --share to register it normally …"* |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Refused. Note the path in the message is the symlink-resolved `/private/tmp/never-registered`, not the `/tmp/…` typed — `AddProvider` resolves before it compares, which is what makes the collision check symlink-proof. |

### Check 4 — `--share` against a dir this same org already registered

| Do this | Expect |
|---|---|
| `wakil provider add again --kind claude-code --config-dir ~/.claude-personal --org personal --share`, where `personal` already homes `~/.claude-personal` as `main` | Refused, and the message says **"same org"** in its own words — *"is already registered to provider "main" in this same org — one org may name one account once. Sharing is between different orgs …"* — and at no point suggests `--share`, because `--share` cannot reach this row of the matrix |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Refused with "in this same org — one org may name one account once", and `--share` appears only in the clause saying it does not change this. Never offered as a way through. |

### Check 5 — `scripts/register-provider.sh` refuses a shared binding

| Do this | Expect |
|---|---|
| With `work` registered under `personal` as a `--share` binding to `initech`'s `~/.claude-initech` (check 2's outcome), and from the repo root so `"$PWD/bin"` resolves (prerequisite 2), run `scripts/register-provider.sh personal work "$PWD/bin"` — the script takes exactly three positional arguments, `<org> <provider-id> <bin-dir>`, and dies with a generic usage message on any other count before it looks at ownership at all | Refuses, naming the homing org (`initech`), and **no `claude mcp add` runs** — confirm by checking that none of the five servers gained a new registration under `personal`'s environment |

The script's own text: *"provider 'work' in org 'personal' shares a config dir that org
'initech' homes (…). Registering it here would overwrite 'initech's WAKIL_ORG pin and silently
repoint that org's plain `claude` sessions. Wakil already runs this account under
'personal' without any registration, so if you only wanted it usable from Wakil there is
nothing left to do. If you meant to MOVE the pin to 'personal' instead, that is a
re-homing, in this order: (1) drop this sharing binding — wakil provider rm work --org
personal; (2) remove the record that homes the directory in 'initech' … and that removal is
refused until step 1 has run; (3) re-add the directory under 'personal' without --share,
then re-run this script to move the pin."* (`scripts/register-provider.sh`). Read the
three steps as part of the check, not as trailing prose: a refusal that names a command
the operator cannot paste, or one that would itself be refused, is the defect this
wording replaced. The refusal fires
before the script's first `claude mcp add` — `register_provider_test.go`'s
`TestRefusesToRegisterAProviderWhoseConfigDirAnotherOrgHomes` asserts zero calls reached
the mocked `claude` binary; this check is the same assertion read against the real
script and a real `claude` on PATH.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Refused, naming `initech`, before any `claude mcp add`. Confirmed by count rather than by reading the message: `CLAUDE_CONFIG_DIR=~/.claude-personal claude mcp list | grep -c wakil-` returned **5**, not 10 — `personal`'s own registration untouched and nothing added. |

### Check 6 — a Wakil session under a shared account sees the sharing org's `WAKIL_ORG`

**No test in this repository can reach this check.** It crosses the one boundary this
project cannot automate: a live agent turn inside `Wakil.app`, spawned as a real
subprocess against a real config dir, with a real model on the other end of the
subscription. `app/Sources/WakilApp` has no test target and cannot have one
(`phase-2c-ii-b-acceptance.md`'s own stated limit), and `WakilKit`'s tests prove the
rules `ClaudeCodeCLIHarness.buildLaunch` and `agentMCPConfigJSON` encode, not that a real
`claude` process launched with them actually reports the org they encoded. The design's
own §6 lists this as one of three checks no test can reach, for the same reason.

**What this check is really measuring, stated so the walk aims at it rather than
stumbling into it: whether `--strict-mcp-config` holds on a MANAGED account.** The whole
design rests on it — a Wakil session never reads the config dir's pinned servers because
`--mcp-config` plus `--strict-mcp-config` replaces them wholesale (design §2). That was
measured **once, on `personal` (`max`) only**, and the probe that measured it says so in
as many words: *"Not tested on `initech` (`team`) or `umbrella` (`enterprise`), where managed
settings could still constrain it"* (`phase-2a-probe.md` §5; `phase-2a-acceptance.md`
repeats it, and charter Decision 5 records the same warning — team and enterprise plans
can impose managed settings that constrain MCP servers and permission modes). Sharing is
the feature that puts those two accounts under that flag *in another org*. If a managed
policy overrode `--strict-mcp-config`, a shared session would read the directory's pinned
servers — the homing org's — and cross the boundary this design says it cannot cross. The
journal reading `WAKIL_ORG=<sharing org>` is what rules that out, and reading the homing
org instead is not a cosmetic mislabel: it is the load-bearing claim failing.

**So walk this check twice, and one of the two must use the `umbrella` (enterprise)
account** — the strictest tier on this machine, and the one furthest from where the flag
was measured. The other pass may use any second pairing; `initech` (`team`) is the more
informative choice, leaving `personal` (`max`) as the tier already covered. Record each
pass on its own Result row: an enterprise pass and a max pass are two different
measurements, and collapsing them into one loses exactly the distinction this note
exists to draw.

| Do this | Expect |
|---|---|
| Open a Wakil window against the sharing org — `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`, the direct-binary launch `phase-2c-ii-b-acceptance.md` §1.1 prerequisite 8 verified inherits the shell's environment (a plain `open app/Wakil.app` does not: LaunchServices does not pass `WAKIL_ORG` through, and every server answers "WAKIL_ORG is not set"). With `work` sharing `initech`'s account into `personal` per check 2, select the shared provider. Run a query against a database that only `personal`'s project defines — one `initech`'s project does not have, so a correct result is possible only if the child ran as `personal`. Then ask the agent for Jira issues — `list the Jira issues assigned to me` | The query succeeds, **and** `wakil-pm` answers for the SHARING org. Neither piece of evidence may be a window label: `phase-2c-ii-b-acceptance.md`'s defect D3 punished exactly that, because a label is drawn once and can go stale. The Jira call is the discriminator, and it needs a pairing where the two orgs differ in `jiraBase` — on this machine `personal` has none and both `initech` and `umbrella` do, so a shared session in `personal` must come back *"no Jira site configured for org personal"*. Returning the homing org's issues instead would mean the session read the directory's pinned servers, which is the load-bearing claim failing |

| Result (pass A — **`umbrella`, enterprise**, required) | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-14 | `personal` sharing `umbrella`'s **enterprise** account as `umbrella-main`. Two pieces of evidence, neither a window label. (1) `select * from events` returned 500 of 537 rows from the sqlite database only `personal`'s project defines. (2) The decisive one: `mcp__wakil-pm__my_issues` returned *"no Jira site configured for org **personal**"* — `wakil-pm`, spawned under `~/.claude-umbrella` where `register-provider.sh` pinned `WAKIL_ORG=umbrella`, reporting itself as `personal`. **`--strict-mcp-config` holds on an enterprise account** — measured on `max` only until now (`phase-2a-probe.md` §5), with charter Decision 5 warning it might not carry. |

| Result (pass B — a second pairing, `initech`/team preferred) | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-14 | `personal` sharing `initech`'s **team** account as `work`. Same two evidences: the agent drew the `events` table from the sqlite database only `personal` defines (500 of 537 rows, via `mcp__wakil__db_read_table`), and `mcp__wakil-pm__my_issues` returned *"no Jira site configured for org **personal**"* — spawned under `~/.claude-initech`, where `WAKIL_ORG=initech` is pinned. With pass A this makes both managed tiers measured: `--strict-mcp-config` is not overridden by managed settings on either team or enterprise. |

### Check 7 — plain `claude` in the shared directory still runs as the homing org

**No test in this repository can reach this check either, and for a different reason
than check 6's: this one leaves Wakil entirely.** It is a claim about plain Claude Code
— a `claude` session started by hand in a terminal, reading `CLAUDE_CONFIG_DIR` and
whatever `WAKIL_ORG` `scripts/register-provider.sh` pinned inside it — and nothing this
repository builds or tests drives that binary interactively. It is also the design's
stated limitation (§3: *"a shared account's plain-Claude-Code flow still belongs to
exactly one organisation"*), and the design says outright that an unwalked limitation is
a guess. This check is what turns the guess into a measurement.

| Do this | Expect |
|---|---|
| In a terminal, `CLAUDE_CONFIG_DIR=~/.claude-initech claude mcp get wakil-ctx`, with `initech` still the org `register-provider.sh` pinned there and `personal` only sharing the account via `--share` (never `register-provider.sh`'d, which check 5 confirms is refused). Read the `WAKIL_ORG` in the server's recorded environment. **Do not ask an interactive session instead** — see D4: the account's OAuth token lives in the Keychain and is injected by Wakil, so a plain `claude` in that directory is *"Not logged in"* and cannot answer. The pin is the claim anyway; the session was only ever a way of reading it | The session runs as `initech` — the same servers, the same `WAKIL_ORG=initech` it would have shown before any sharing existed. `personal`'s Wakil-only binding is invisible to it; there is no `--org` flag for a plain `claude` session and nothing about sharing gives it one |

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-14 | Walked as the pin rather than as a session — see D4. `CLAUDE_CONFIG_DIR=~/.claude-initech claude mcp get wakil-ctx` reports `WAKIL_ORG=initech WAKIL_PROVIDER=main`, unchanged by `personal`'s `work` binding. All three dirs checked and each still pins its own org (`initech`→initech, `personal`→personal, `umbrella`→umbrella). The design's stated limitation is now a measurement: a shared account's headless flow still belongs to exactly one organisation. |

## 3. Verification — commands confirmed green on this tree

Not a substitute for §2, exactly as `phase-2c-ii-b-acceptance.md`'s own §3 says of
itself — the rules these commands prove are not the surface this runbook exists to
walk. They are the floor checks 1–5 stand on before anyone touches a terminal, and the
floor checks 6 and 7 cannot stand on at all, because nothing here reaches either.

```
$ make test
ok  	github.com/yehia-khalil/wakil/cmd/wakil	(cached)
ok  	github.com/yehia-khalil/wakil/cmd/wakil-ctx	(cached)
ok  	github.com/yehia-khalil/wakil/cmd/wakil-db	(cached)
ok  	github.com/yehia-khalil/wakil/cmd/wakil-http	(cached)
ok  	github.com/yehia-khalil/wakil/cmd/wakil-pm	(cached)
ok  	github.com/yehia-khalil/wakil/cmd/wakil-recall	(cached)
ok  	github.com/yehia-khalil/wakil/internal/mcpx	(cached)
?   	github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest	[no test files]
ok  	github.com/yehia-khalil/wakil/internal/wakilcore	(cached)
ok  	github.com/yehia-khalil/wakil/scripts	(cached)
```
Exit 0. Re-run 2026-09-14 after the branch review's fixes, with the five new tests §3
names below in the tree.

```
$ make vet
go vet ./...
```
Exit 0, silent — no findings.

The tests behind checks 1–5, named rather than merely counted. `CGO_ENABLED=0` is what
the Makefile exports for every target, so this runs the same build the block above did:

```
$ CGO_ENABLED=0 go test ./internal/wakilcore/... -run \
    'TestProviderSharedRoundTripsAndIsOmittedWhenFalse|TestConfigDirHomeSkipsSharedRecordsRegardlessOfOrgOrder|TestConfigDirHomeReportsNoneForAnUnclaimedDir|TestAddProviderShareMatrix|TestAddProviderRefusesASecondRecordInAnOrgThatAlreadyNamesTheDir|TestAddProviderCrossOrgRefusalNamesTheHomeAndNotAnotherSharer|TestAddProviderRefusesShareOnAKindWithNoConfigDir|TestRemoveProviderRefusesWhileOtherOrgsShareTheConfigDir|TestRemoveProviderStillRemovesARecordNothingDependsOn' -v
--- PASS: TestProviderSharedRoundTripsAndIsOmittedWhenFalse (0.00s)
--- PASS: TestConfigDirHomeSkipsSharedRecordsRegardlessOfOrgOrder (0.00s)
--- PASS: TestConfigDirHomeReportsNoneForAnUnclaimedDir (0.00s)
--- PASS: TestAddProviderShareMatrix (0.01s)
    --- PASS: .../another_org_owns_it,_no_--share:_refused,_and_the_message_names_--share (0.00s)
    --- PASS: .../another_org_owns_it,_with_--share:_accepted_and_marked_shared (0.00s)
    --- PASS: .../nobody_owns_it,_with_--share:_refused (0.00s)
    --- PASS: .../the_same_org_owns_it,_with_--share:_refused_with_its_own_message (0.00s)
    --- PASS: .../nobody_owns_it,_no_--share:_registered_as_the_home (0.00s)
--- PASS: TestAddProviderRefusesASecondRecordInAnOrgThatAlreadyNamesTheDir (0.01s)
    --- PASS: .../the_org_that_homes_it,_with_--share,_while_another_org_shares_it (0.00s)
    --- PASS: .../the_org_that_homes_it,_no_--share,_while_another_org_shares_it (0.00s)
    --- PASS: .../the_org_that_already_shares_it,_with_--share (0.00s)
--- PASS: TestAddProviderCrossOrgRefusalNamesTheHomeAndNotAnotherSharer (0.00s)
--- PASS: TestRemoveProviderRefusesWhileOtherOrgsShareTheConfigDir (0.00s)
--- PASS: TestRemoveProviderStillRemovesARecordNothingDependsOn (0.00s)
--- PASS: TestAddProviderRefusesShareOnAKindWithNoConfigDir (0.00s)
PASS
ok  	github.com/yehia-khalil/wakil/internal/wakilcore	0.586s
```
Five subtests of `TestAddProviderShareMatrix`, one per row of the design's §4.2 matrix —
checks 1–4 above are the same four cross-org rows read at the CLI rather than at the Go
API, plus the same-org row check 4 also exercises.

The five tests after it were added by the branch review on 2026-09-14 and each one
fails without its fix. They are here because **the matrix's own five subtests could not
see the defect the matrix was written to prevent**: every one of them puts exactly ONE
record on disk for the config dir, and `--share` letting an org register the same dir
twice needs TWO — a home in one org and a sharer in another. Checks 1–4 walk the matrix
at the CLI and would not have caught it either. A green row is not a covered row.

```
$ go test ./scripts/... -run \
    'TestRefusesToRegisterAProviderWhoseConfigDirAnotherOrgHomes|TestStillRegistersTheProviderThatHomesItsOwnConfigDir' -v
--- PASS: TestRefusesToRegisterAProviderWhoseConfigDirAnotherOrgHomes (0.19s)
--- PASS: TestStillRegistersTheProviderThatHomesItsOwnConfigDir (0.43s)
PASS
ok  	github.com/yehia-khalil/wakil/scripts	0.845s
```
The first is check 5's own assertion — zero `claude mcp add` calls reached the mocked
binary — against a scripted `claude`. The second is the control: without it, this suite
would pass if the script refused everything, sharing binding or not.

Machine: this worktree's build environment, 2026-09-14.

## 4. Defects found during the walk

**Three, 2026-09-14.** None is in the refusal matrix or the enforcement point — those
walked exactly as written. All three are in the surfaces around them, which is where the
previous three walks in this project found theirs too.

### D1 — this document told the operator to read the journal for a value the journal does not carry · check 6 · FIXED

Check 6's own expectation read *"open the journal and read what `WAKIL_ORG` the spawned
server actually reported."* A journal entry carries `id`, `outcome`, `origin`, `params`,
`action`, `ts` and `environment` — and **no org**. The instruction could not be followed,
and an operator trying would either invent a substitute or record the check off the window
label, which is the one thing its own text forbids.

This is check 5's defect one check later: a step that cannot be run as written, found only
by running it. It is fixed above — the evidence is now a `wakil-pm` call, whose answer
comes from the spawned child rather than from anything Wakil drew, and the check now says
the pairing must differ in `jiraBase` for that answer to discriminate.

### D4 — check 7 asked for a session that cannot log in · check 7 · FIXED

Check 7 said to start `CLAUDE_CONFIG_DIR=~/.claude-initech claude` and ask the session which
org's tools it had. Walked, that session comes up **"Not logged in · Run /login"**: the
account's OAuth token lives in the Keychain under `wakil:initech:provider:main` and is
injected by Wakil as `CLAUDE_CODE_OAUTH_TOKEN`, so the config dir itself holds no
credential and a plain session there cannot complete a turn.

Same family as D1 and as check 5's missing argument — a step that reads fine and cannot be
run. The fix is also an improvement: the claim was never about a session, it was about the
**pin**, and `claude mcp get wakil-ctx` reads the pin directly, without a login, without a
model call, and without spending a token. Check 7 now says so, and says not to substitute
an interactive session.

Three of this walk's four defects are this one shape. It is worth naming as a pattern
rather than three separate slips: **a runbook step is a claim about a command, and the only
way to check that claim is to run the command.** Reading it does not.

### D2 — a shared binding must repeat `claudePath` that its home record already carries · found while setting up check 6 · FIXED 2026-09-14

`wakil provider add umbrella-main --config-dir ~/.claude-umbrella --share --org personal`
succeeds and writes a record with no `claudePath`. Selecting it in ⌘P then fails at the
window with *"set provider umbrella-main: the provider record is missing claudePath"*, and
the account indicator stays `unset`. The homing record two directories away has the value;
nothing offers it, and `AddProvider` does not require it.

It cost this walk one attempt at check 6. It is the same account and the same binary, so
the sharing record having to name it again is a papercut rather than a rule — **a shared
binding could inherit `claudePath` from the record that homes the directory.** Recorded
rather than fixed at the time because the fix is a design call about where a shared
record's fields come from, and a walk is not the place to make one.

**Fixed 2026-09-14, and the design call went to DERIVING rather than copying.**
`wakilcore.ResolveProviderClaudePath` answers "which binary does this record launch",
which `provider credentials` now asks instead of reading the field: an explicit
`claudePath` still wins, a shared record with none inherits the homing record's, and a
record that is not shared keeps its empty value so the existing refusal still reads
correctly for it. Copying the value into the sharing record at `provider add` was the
alternative and was rejected on `ProviderTokenRef`'s own stated grounds — a copy is a
second string that can disagree with the first, and it disagrees the day the binary moves.
A share whose home is gone, or whose home carries no `claudePath` either, is refused by
name so the operator fixes the record that actually owns the value rather than the one
that surfaced the error. Five tests in `provider_test.go`, one in
`providercredentials_test.go`.

### D3 — the launch-time "no active provider" note survives a successful switch · seen throughout · FIXED 2026-09-14

*"no active provider is set for this org yet — pick one in ⌘P…"* is appended by
`WindowSession` when a window opens for an org whose `active.json` names no provider. It
is still on screen after ⌘P has selected one, the seam has been written, and the account
indicator reads the new provider — visible in every screenshot of this walk, including the
ones where the shared account is demonstrably running.

Pre-existing 2b-vi behaviour, not introduced by this sub-phase, and no session state is
wrong — only the note is stale. Recorded here because this walk is where it was seen, and
because a status line that contradicts the indicator beside it is the same family as the
defect D1 above exists to prevent.

**Fixed 2026-09-14 by making the note derived rather than appended.** `WindowSession.notes`
is a `let [String]` assembled while the window is being built, so nothing could retract a
sentence once it was in there. The note is `WindowModel.noActiveProviderNote` now — `nil`
unless `providerId` is empty — which is the same value the account indicator reads, so the
two cannot disagree by construction. The move also relocates it from `WakilApp`, which has
no test target and cannot have one (`phase-2c-ii-b-acceptance.md` §3), into `WakilKit`,
which does: a string no automated test could reach is now pinned by three in
`ProviderSwitchTests`, including one that asserts it is gone after `setProvider` succeeds.

## 5. Result

**Walked in full, 2026-09-14. Eight of eight result rows PASS.**

Checks 1-5 walked at the CLI against this machine's real config dirs, and all five behave
exactly as written — including check 5's count-not-message confirmation that `personal`
still carries five registered servers and gained none. Check 6's **enterprise** pass is the
result that matters: a session in `personal` running `umbrella`'s account queried a database
only `personal` defines, and `wakil-pm` — spawned under `~/.claude-umbrella`, where
`WAKIL_ORG=umbrella` is pinned — answered *for `personal`*. **`--strict-mcp-config` holds on
an enterprise account.** That had been measured on `max` alone, and charter Decision 5
records the warning that it might not carry.

Pass B repeated it on the **team** account with the same outcome, so both managed tiers are
now measured and the warning charter Decision 5 carries is answered for both. Check 7 —
the design's own stated limitation, that a shared account's headless flow still belongs to
one org — is a measurement rather than a guess: all three config dirs still pin their own
org, unchanged by any sharing binding.

**Four defects, in §4, and all four are now fixed.** D1 and D4 were fixed here, in this
document; both were steps that could not be run as written, and both were found only by
running them. D2 (a shared binding must repeat `claudePath`) and D3 (a stale launch note)
were carried out of the walk as non-blocking and were fixed on 2026-09-14, each under its
own entry above. **Three of the four are the same shape**, which §4's D4 entry names as the
lesson: a runbook step is a claim about a command, and only running it checks that claim.

**No `north-star.md` phase row is marked by this document, because none exists to mark** —
this sub-phase was sequenced ahead of the multi-org window design without claiming a row of
its own, exactly as Decision 21 declined to claim one. What this walk establishes belongs
to Decision 22 and to the multi-org window's own runbook when it ships.

The original pre-walk assessment follows, unchanged, because it is what the document
claimed before anyone ran it.

**Not walked. Not met, and not eligible to be marked met by this document alone.**

Five of seven checks are reachable by an operator with `make build` and a terminal, and
the automated floor under them (§3) is green: 709+ tests including five new subtests in
`TestAddProviderShareMatrix` and two in `scripts` that directly assert the refusal this
runbook's check 5 walks by hand. Two checks — 6 and 7 — are not reachable by any test
this repository can write, for two different reasons: check 6 crosses a process boundary
into a real agent session inside `Wakil.app`, which has no test target and cannot have
one; check 7 leaves Wakil entirely and is a claim about plain Claude Code, which nothing
here drives interactively. Both are exactly the design's own §6 list of what an unwalked
limitation costs, restated as checks rather than left as prose.

Check 6 carries two Result rows rather than one, and the first of them is the
**enterprise** account. The design's load-bearing claim — that `--strict-mcp-config`
replaces a config dir's registrations wholesale, so a Wakil session never reads the
pinned servers — was measured on `personal` (`max`) and nowhere else, and sharing is
precisely the feature that puts the `team` and `enterprise` accounts under that flag in
someone else's org. One pass on `max` would leave the tier where managed settings could
override it unmeasured, which is how a load-bearing assumption stays an assumption.

Until an operator walks all seven — check 6 twice — and fills in §2's Result rows, this sub-phase's row in
`north-star.md` stays unmarked — the same discipline `phase-2b-v-acceptance.md` and
`phase-2c-ii-b-acceptance.md` both record being skipped once already, at a cost each of
those documents spends a full section describing.
