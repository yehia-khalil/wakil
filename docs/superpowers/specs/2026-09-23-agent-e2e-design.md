# Agent-run end-to-end tests — design

**Tracker:** [#246](https://github.com/yehia-khalil/rafiq/issues/246), with eleven
children carrying the decomposition ([#247](https://github.com/yehia-khalil/rafiq/issues/247)
through [#257](https://github.com/yehia-khalil/rafiq/issues/257)). There is no plan
file; the tickets are the decomposition (`docs/agents/workflow.md`, the Tickets rung).

**Binding authority for the implementation that follows.** Written 2026-09-23, on a
probe run the same day against the live `Wakil.app` (pid 50803, bundle
`dev.wakil.app`, running from `~/orca/workspaces/wakil/provider-settings`) with
`orca computer`, and on a read of `ActionRegistry`, `WindowSession`, `main.swift`
and the `Makefile`. Every capability claim below was executed, not inferred; the
claims that were **not** executed are collected in §14 and must be probed before a
line is written.

The operator's instruction, which shapes every trade-off here: *minimize my
interference; it should be capable of auditing the app and writing tests covering
every aspect of the implemented task — the UI, the flow, the clicks and inputs.*

**Amended 2026-09-23, the same day, against `docs/wakil/agent-e2e-probe.md`** — the
run of the six items §14 pre-registered. Two resolved better than assumed (§6.2 needs
no production change at all; §12's cost is a subset rather than the whole suite), one
**corrected** this spec outright (§7's browser stub could not have worked as written),
and one added a requirement the spec had missed (§6.1's fixture is a seeded state, not
just a `HOME`). Each correction below says what it is correcting, so the next reader
sees the shape of the mistake and not only its repair. §14 now records only what
remains open.

---

## 1. The gap, measured

`WakilApp` has no test target. Every `WakilKit` test constructs its collaborator
directly and hands it a fake, so the wiring path is never exercised — which is why
`WindowModel`'s defaulted injectables can ship unpassed (`providerMint`,
`providerLoginBinary`, and `useActiveContext` before them; the first two are on an
unmerged branch as of this writing, so they are evidence of the *class*, not of
`main`).

The size of the class is on record. `docs/wakil/phase-2c-iii-acceptance.md`: the
2026-09-18 walk of ten checks found **twenty-one defects, every one of them in
`WakilApp` or its seam with `WakilKit`** — none in the PTY, the mark scanner, the
block model, the store or the mirror. Two surfaced only on a **re-walk** of a build
already declared fixed. That is the gap: it is not a correctness gap in the tested
core, it is a wiring-and-seam gap in the untested shell, and the only instrument
currently pointed at it is an operator's afternoon.

**What already exists and does not close it.** `--dispatch <file.jsonl>` runs verbs
headlessly through `WakilWiring.build` with meaningful exit codes (0 / 1 / 2), and
`scripts/checks/layout-dual-drive.jsonl` is a check file already in the tree. But
`--dispatch` never constructs `WindowModel` or `WindowSession`, and never draws.
It cannot see the class above.

## 2. What "everything" means — the two denominators

A coverage claim without a denominator is a mood. Invariants 2 and 3 supply two,
and both are enumerable **at runtime, from outside the process**:

1. **Action coverage.** `ActionRegistry` exposes a schema-only description of every
   registered action — its own doc comment calls this *"the only way to enumerate
   registered actions from outside this actor"* — and `MCPServer` projects every
   registered action onto a Wakil tool. `StandardActions` registers twenty-six,
   seventeen of them `ActionKind.read`. So `tools/list` on the live window's socket
   returns the complete list of things the app can do.

2. **Control coverage.** Every `.accessibilityIdentifier` in `app/Sources/WakilApp`,
   harvested by grep. **Today that set is empty.** The tree carries two
   `.accessibilityLabel` calls (`DataSurface.swift:662`, `Rail.swift:227`) and one
   mention of the API in a `WindowModel` doc comment — and not a single
   `.accessibilityIdentifier`. A live read of the window showed thirteen anonymous
   `button` elements. Populating this set is funded work (§6.3), and until it exists
   the denominator is zero, so control coverage is vacuous rather than met.

**The rules built on them:**

- Every action a ticket touches is dispatched by at least one check.
- Every action of kind `write` carries a **parity check** — performed once by
  clicking and once by dispatching, asserting identical resulting state. That is
  Invariant 2 (*"UI controls and the agent dispatch the same actions. Two code paths
  to the same state is forbidden"*) executed rather than asserted in prose.
- Every identifier is exercised by at least one check.
- **Uncovered surface fails the gate — but only newly added surface.** An action or
  identifier that appears in the branch diff with no check makes `make e2e` red and
  names it. Surface that predates the harness does **not** fail the gate; it is the
  discovery audit's backlog (§9.3). A gate that demanded the whole registry on day
  one would be switched off within a week, which is how the first north-star word
  limit failed.

That last rule is the one that keeps this from rotting without the operator
policing it, and it is the single largest contributor to the instruction in the
header.

## 3. Architecture

| Component | Lives in | Is |
|---|---|---|
| **Driver** | `e2e/driver/` | A Go library over three channels (§4) |
| **Checks** | `e2e/checks/{unseeded,seeded}/*.jsonl` | Declarative steps, writable without touching Go (§5). **Split by fixture state 2026-09-23 (#248)**: an unseeded instance opens on the organisation plane and a seeded one does not, so one launch cannot assert both and `make e2e` runs a pass per directory. |
| **Runner** | `make e2e` | Bundle, launch on fixture state, discover the socket, run, write evidence, tear down |
| **Auditor** | a repo skill + `docs/agents/e2e.md` | Reads a diff, enumerates surface, writes the checks, proves them failable, reports the residue (§9) |

**Go, under `e2e/`.** Go because the repo already tests its scripts this way
(`scripts/app_bundle_test.go`, `scripts/makefile_test.go`) and because `go test`
gives subtests, parallelism control and a failure format the tree already reads.

**The live half is a program, not a tagged test package** *(corrected 2026-09-23
during #247. This section said "behind `//go:build e2e`", on the reasoning that
`make test` runs `go test ./...` and must stay runnable with nothing installed but
Go. The premise is right and the mechanism was wrong: a tag over `e2e/` would have
excluded **the library's own unit tests** along with the GUI ones — and those are the
guards that stop a check silently asserting nothing, which is the last thing that
should be hidden behind a GUI-only target.)*

So `e2e/driver` is ordinary Go and runs in `make test`; `e2e/cmd/wakil-e2e` is a
program that `make e2e` invokes. No build tag is needed: a `main` compiles under
`go build ./...` and `go vet ./...`, and runs only when something runs it.

**The `test-live` lesson applies verbatim.** That target exists because `go test`
reports a skipped test as `ok`, so a live target with no containers running passed
cleanly and certified nothing. A GUI harness has the same failure in a worse form: a
check that resolved a stale index, found nothing and asserted nothing also exits 0.
Therefore: **the runner fails when zero checks ran**, fails when a check performed
zero assertions, and fails when an act reports Orca's `unverified (synthetic input)`
without a subsequent state read that confirms the effect.

## 4. The driver — three channels

1. **GUI.** `orca computer` as a subprocess, `--json` in and out. Verified available
   on this machine: `click`, `typeText`, `pasteText`, `pressKey`, `hotkey`, `scroll`,
   `drag`, `setValue`, `performAction`, plus `screenshot` and `elementFrames`.
   Verified **un**available: `surfaces.menubar`, `surfaces.menus`, `surfaces.dock`,
   `surfaces.dialogs`, `windows.focus`, `windows.moveResize`, `ocr`. So no menu-bar
   driving — `⌘,` and its kin go through `hotkey` — and focus comes from
   `--restore-window`.
2. **Agent.** An MCP client on the live window's Unix socket. `WindowSession.start`
   opens one at `$TMPDIR/wakil-<sessionId>.sock`; `PaneSnapshotJSON` is behind it.
   This is both a drive channel (dispatch an action as the agent would) and the
   authoritative observation channel (`read_pane` — Invariant 3).
3. **Process.** `ps` for orphaned children, the fixture journal directory for
   journalling assertions, and process exit codes.

**Controls are addressed by identifier, never by index.** The driver resolves
identifier → element index from a `get-app-state` taken immediately before each act,
and never caches one. This is **enforced by the tool, not merely advised**: measured
2026-09-23, an index-based action not preceded by a fresh snapshot for that app and
window is refused with `element_not_found: element indexes require a fresh
get-app-state snapshot for this app/window`. An identifier that resolves to zero or to
more than one element is a check failure, not a retry.

## 5. The check format

One file per flow, one JSON object per line, four step kinds:

```jsonl
{"do":{"click":"provider.row.work.signIn"}}
{"do":{"type":{"into":"agent.composer","text":"open the customers table"}}}
{"dispatch":{"action":"pane_open","params":{"kind":"db","title":"Left"}}}
{"expect":{"pane":"db-1","field":"title","equals":"Left"}}
{"expect":{"tree":"contains","text":"signed in"}}
{"expect":{"process":{"none-matching":"tail -f"}}}
{"parity":{"action":"pane_maximize","click":"pane.db-1.maximize","assert":"read_pane"}}
```

`do` drives the GUI; `dispatch` drives the agent channel; `expect` asserts against
`read_pane`, the accessibility tree, or the process table; `parity` does both drives
and asserts they land identically. The format is deliberately declarative so the
auditor can write checks without editing Go — the same reasoning that produced
`scripts/checks/layout-dual-drive.jsonl`.

## 6. State isolation

### 6.1 The fixture flag

`--fixture <dir>`, taking its place beside `--dispatch`, `--capture` and
`--mcp-shim` in `main.swift`, resolves one launch's entire state under `<dir>`:
`HOME` (and therefore `~/.wakil` and the journal), the Claude config directories,
and the Keychain.

**The fixture is seeded state, not only a `HOME`** *(added 2026-09-23; the spec had
missed this)*. A fresh fixture `HOME` opens on the organisation plane — nine elements,
one anonymous button, *"NO ORGANISATION IS OPEN · NOTHING BEHIND THIS PLANE"*. Reaching
a canvas pane needs an org, then a session, then a provider carrying a credential. So
`<dir>` ships with a seeded `~/.wakil` and a stubbed provider record, or no check can
reach a pane at all.

`main.swift` already establishes the convention this must follow: read `HOME` from
the process environment rather than `FileManager.default.homeDirectoryForCurrentUser`,
which resolves through the system directory service and ignores an overridden `HOME`.
`runDispatchFile` says so explicitly and cites the global constraint — *never touch
the real `~/.wakil` in a test*. The fixture flag is that constraint made
enforceable rather than remembered.

### 6.2 The Keychain, which is the part that needs care

Invariant 4 stores secrets at `wakil:<org>:<ref>` and requires cross-org bleed to be
**structurally impossible**, not merely avoided. A fixture run that wrote into the
operator's login keychain would violate that invariant on the operator's own machine.

**No production change is needed** *(corrected 2026-09-23; this section previously
proposed adding a keychain parameter to `SecretSet`, and raised a charter question for
the case where that failed. Both were unnecessary — the mechanism was already in the
tree.)* All three Keychain invocations live in `secrets.go` (`:117`, `:143`, `:262`)
and resolve `security` **through `PATH`**; there is no absolute-path invocation
anywhere in `internal/` or `cmd/`, and the Swift side never shells to `security`. A
shim on the fixture `PATH` appending the trailing `[keychain]` positional redirects
every call to a scratch keychain. The probe proved this end to end through
`bin/wakil secrets set`: the value round-tripped from the fixture keychain and was
absent from the login keychain.

Isolation is therefore a different keychain **file** — structural in exactly the sense
Invariant 4 demands, not a naming convention. It is also an existing repo idiom:
`dbresolve_test.go:228`, `httpclient_test.go:1140`, `jira_test.go:1338` and
`secrets_test.go:190` all override `security` this way.

**The one dependency:** the app's spawned Go children must inherit the fixture `PATH`.
The runner asserts its `PATH` reached the child before any check runs, because a
launcher that dropped it would write into the operator's login keychain.

### 6.3 The identifier contract

Every actionable control in `WakilApp` gets a stable `.accessibilityIdentifier`,
namespaced by surface (`provider.row.<id>.signIn`, `pane.<id>.maximize`,
`rail.<pane>`, `org.plane.create`). Two properties make this a contract rather than
test scaffolding:

- It is **real accessibility**. Thirteen anonymous buttons is a VoiceOver defect
  independent of any harness.
- It is **enforced**. An actionable control without an identifier fails the gate, so
  the set cannot silently shrink.

### 6.4 Never the operator's instance

The runner launches with `open -n` and addresses the result by `pid:<n>`, never by
`dev.wakil.app` or by name. A check that reached the operator's open window would be
driving their live credentials. The runner refuses to start if it cannot establish a
pid distinct from every pre-existing Wakil process.

**This is measured, not precautionary.** With two instances running, `list-windows
--app dev.wakil.app` returned **only the operator's** — no error, no indication a
second existed. Bundle-id addressing fails silently and in the dangerous direction.

**And `open -n` is required, not merely convenient.** A bundle binary started as a
backgrounded child of a shell dies with that shell; every later call then fails
`app_not_found`, which reads exactly like a capability limit and is not one. `open -n`
detaches through LaunchServices, and its `--env` is what carries the fixture `HOME`,
`TMPDIR` and `PATH` — necessary because a LaunchServices start inherits launchd's
minimal environment, the same fact `WindowModel` records for #238.

## 7. Determinism

- **Agent stub.** `e2e/stub/`, grown from `scripts/anthropic-stub.py`, serves
  scripted SSE turns shaped like `app/Fixtures/stream-json`, reached through
  `ANTHROPIC_BASE_URL`. Decision 16 (2026-09-08) already established that `claude`
  honours that variable, with that script as the recorded reproduction. This is what
  makes agent-involving checks reproducible, free, and account-free.
- **Browser stub**, seeded into the fixture's **provider record** *(corrected
  2026-09-23: this said "on the fixture `PATH`", which could not have worked.
  `WindowModel.loginBinary()`'s doc comment records that `executableURL` does not
  search `PATH`, and that a GUI inherits launchd's minimal one — which is why #238
  made the binary travel on the provider row as "the only absolute path the app
  has".)* The fake binary's absolute path is the `binary` field the row carries, and
  it prints a canned 108-character token. It must be spawned **on a PTY**: `claude
  setup-token` is silent on a pipe, and `scripts/probe/setuptoken/setup-token-probe.sh`
  is the crib.

  Seeding the record is the better mechanism, not a workaround: it runs the production
  resolution path — listing, row, `loginBinary()` — so an unwired dependency still
  fails the check. **The harness must never install the stub by injecting
  `providerLoginBinary`.** That parameter exists so a test can pin a fake with no
  listing behind it, and it is itself a member of the defaulted-injectable class this
  harness exists to catch (#204, #238); a check that set it would bypass the defect it
  was written to find.

  The gate proves the hand-off and the absorption; it never opens a browser. A real
  sign-in stays a separate, on-demand target on the `make test-live` pattern — it
  touches real accounts, mints real long-lived credentials, and may meet 2FA.
- **Settling.** Every act is followed by a re-read. Waits are on a predicate with a
  timeout, never a fixed sleep.
- **Evidence.** Every failure writes a screenshot, the accessibility tree and a
  `read_pane` snapshot to `.context/e2e/<run>/`, so a red run is diagnosable without
  reproducing it. An intermittent check is quarantined and reported, never silently
  retried into green.

## 8. Proof of failability

**No check counts until it has been seen to fail.** `make e2e-new` runs only the
checks added on the current branch against a bundle built from the **merge-base**,
and requires them to go red. A check that passes against the code from before the
work is not testing the work.

This replaces source mutation, which would need a rebuild per check. It costs one
extra bundle build per branch, it needs no new machinery, and it is the Build rung's
existing test-first discipline (`mattpocock-skills:tdd`) applied to the GUI.

## 9. The auditor

A repo skill, documented at `docs/agents/e2e.md` and referenced from `CLAUDE.md`
beside the four existing agent skills. Three modes:

1. **Task audit** — the default, run at the Build rung. Reads the branch diff;
   derives the actions, identifiers, panes and flows it touched; cross-references
   live `tools/list` and the identifier grep; writes the missing checks; runs
   `make e2e-new` to prove each red, then `make e2e` to prove each green; reports
   **what it could not cover and why**. That residue list is the only thing that
   reaches the operator.
2. **Standing audit** — the gate of §2. New surface without a check is red.
3. **Discovery audit** — on demand, diff-independent. Crawls the live tree and the
   full registry and reports every action and control no check touches at all. Its
   output is a backlog, not a gate.

## 10. The ladder

One new rung in `docs/agents/workflow.md`, between **Build** and **Review**:

> **Cover** — done when every action and identifier the ticket touched carries a
> check, `make e2e` is green, and `make e2e-new` was red against the merge-base.

**Runbook** then holds only the human residue — still capped at ten, and now
genuinely shorter. **Walk** stays the operator's and keeps its *"Never an agent"*.
That rule guards against an agent declaring its own work good, and §8 is exactly
what lets the machine-walked half be trusted without the operator re-checking it.
The runbook grows a machine section the runner fills in **with evidence** — exit
codes, snapshots, screenshots — and a human section that stays prose.

**Against 2c-iii's ten, for calibration:** seven mechanize directly (bundle `PATH`
and `which brew`; a block carrying exit code and duration; characters echoing before
Enter; `⌃C` returning to the prompt; `vim` taking the pane and leaving a block; no
orphan after a pane closes; an org switch that is not blocked, kills the old shell
and still journals the new run). Two more mechanize against the stubbed agent (the
two-`⏎` hand-off; both surfaces readable while `vim` is open). One stays the
operator's, because half of it is visual — agent runs reading as *recessed* and
*interleaved rather than bunched*.

## 11. What stays the operator's, permanently

The visual rulings: violet confined to the proposal, the mirror never lit, the hatch
reading as texture, a room in motion reading as calm. `--capture` and
`--capture-motion` already serve these, and `void-as-core-probe.md` §6 already
established that stills cannot answer the motion ones. Also: *did the right real
account get used*, against a live provider.

Naming this boundary is part of the design. A harness that implied it covered these
would be worse than one that admits it does not.

## 12. The cost that cannot be designed away

*(Rewritten 2026-09-23. This section claimed a run takes the screen. The probe
split the question in two, and most of the suite is in the half that does not.)*

**Only real clicks take the foreground.** Measured: `click` (AXPress) activates the
app — Arc frontmost, click, Wakil frontmost, reproduced on a second control, with a
failed click leaving Arc frontmost as the control. `set-value` does **not**: the value
landed while Arc stayed frontmost throughout.

So field input, every observation and the whole `read_pane` channel run in the
background, and the runner prefers `set-value` wherever a check is about state rather
than about the click path. What is left in the foreground is the **parity subset** —
which is also the subset that exists to prove Invariant 2, so the cost is paid exactly
where it buys the most. Those checks are a named group the operator can schedule.

`make e2e` remains something started deliberately — never a hook, never on save. If
even the parity subset's foreground cost binds, the upgrade is a second macOS login
session with its own Orca runtime; that complexity stays deferred until it is felt.

## 13. Build order, and the acceptance criterion for the harness itself

1. ~~Probe §14's open items.~~ **Done 2026-09-23** — `docs/wakil/agent-e2e-probe.md`.
2. Driver + `--fixture` + **the fixture seed** (§6.1) + runner skeleton, with the
   zero-checks-ran guard.
3. Identifiers for the surfaces 2c-iii touches.
4. Checks for 2c-iii's seven mechanizable items.
5. Agent stub; then its two checks.
6. `make e2e-new`.
7. The auditor skill and the `Cover` rung.

**The acceptance criterion is retrodiction.** 2c-iii's runbook is already walked and
`phase-log.md`'s 2026-09-18 entry records the shapes of the twenty-one defects it
found. A harness that catches the mechanizable ones against the builds that carried
them is proven. One that cannot is not — and that verdict must land at the end of
step 4, before any effort goes into step 5 and beyond.

## 14. What this spec leaves unestablished

**Six items stood here until 2026-09-23; `docs/wakil/agent-e2e-probe.md` ran them and
five are closed, along with one that the probe raised and answered in the same run
(`PATH` reaches the app's Go children: `wakil-ctx` carried the fixture `PATH`)** — two concurrent instances (§6.4), the Keychain override (§6.2),
acting on an unfocused window (§12), `setup-token` substitutability (§7), and Orca CLI
resolution (§4). Each closure is folded into the section it belongs to rather than
left here as a note.

What is still open, and what each one blocks:

1. **The terminal pane's accessibility tree.** The data surface is settled — one
   labelled element per row carrying `.isSelected`, cells deliberately hidden
   (§4's division of labour follows from it). The terminal grid is unmeasured, because
   reaching a canvas pane needed the fixture seed the probe did not yet have.
   **Blocks nothing:** 2c-iii's mechanizable checks are all `read_pane` questions, and
   that walk's check 15 already established `read_pane` returns both surfaces as a
   union keyed by `kind`. Measure it when the seed exists, at step 3.
2. **`TMPDIR` and the MCP socket.** The env var reaches the app — the fixture process
   carried the fixture `TMPDIR`, the operator's carried the real one. What is
   unmeasured is whether `FileManager.default.temporaryDirectory`, which
   `WindowSession` builds the socket path from, honours it; the fixture instance never
   opened a session, so no socket was created. If it does not, the runner scans the
   real `$TMPDIR` and must distinguish its own instance's socket from the operator's.
   **Blocks step 2**, and is measured the moment the seed of §6.1 exists.
