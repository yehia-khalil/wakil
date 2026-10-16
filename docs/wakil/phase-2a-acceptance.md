# Phase 2a acceptance run

The design spec's §8 exit criteria, as a runbook. **You execute this**; no agent has
run any of it and none will. Every check below either needs a display session, spends
your Claude subscription, or writes to your real `~/.wakil` — all three of which the
automated suite is forbidden to touch.

Written 2026-09-08, at the end of Task 11 of
`docs/superpowers/plans/2026-09-07-phase-2a-spine.md`. A check with an empty result is
a check that was not run, and that is worth knowing later, so unrun items say so rather
than being quietly dropped.

**Run 2026-09-08 by the operator. All three standing checks PASS, and one-time checks 4
and 7 PASS.** Check 8 was the only one outstanding, for want of a fixture: it needs a
project filed under an org other than `personal`, and no other org has one. It was
**ACCEPTED on 2026-09-15** rather than run (`phase-log.md`, "The 2026-09-15 acceptance"),
so cross-org isolation at the window rests on unit tests alone. What the
run established that no test could — the `claude` CLI honours `--allowedTools`, so the
agent can actually reach Wakil's tools; the `mcp__wakil__<tool>` names survive the trip
intact, which is what the dot-free rename was for; and the thought thread does grow
during a turn rather than in one burst at the end. It also surfaced one thing nobody
predicted: see §6's last entry.

**Amended 2026-09-09 by Phase 2b-iii.** One-time checks 5 (the write gate) and 6
(production blocked) carried a placeholder script and the words *"not expressible in
2a"* from the day this document was written, because 2a registered no `.mutate` action
and a script written against nothing would have passed for the wrong reason. Phase
2b-iii registered `db_run_mutation`, so both scripts are now concrete and both are
**runnable and unrun**. Their preconditions, and the reasons each can still pass for
the wrong reason, are in the sections themselves; the results, when someone walks them,
go in `docs/wakil/phase-2b-iii-acceptance.md` §2 rather than here. Nothing else in this
document was re-run on that date, and no row below has changed.

Companion documents: `docs/wakil/phase-2a-probe.md` (what the live probe found, and
which of its findings this runbook depends on), `docs/wakil/north-star.md` (the
invariants these checks are evidence for), and
`docs/superpowers/specs/2026-09-07-phase-2a-spine-design.md` §8 (why the operator list
is three items rather than eight).

---

## 0. Why this list is short

Spec §8 splits verification by layer. Everything expressible as a headless assertion
is one — the Swift suite plus the Go suite, run by `make app-test` and `make test`,
which are mine to keep green. (Neither suite's size is written down here. A count in a
runbook is stale the next time a test is added, and a stale one invites the reader to
treat a correct run as a discrepancy; the commit that changes a suite is where its count
belongs.) What is left here is only what a machine cannot honestly check: that a window
appears on a screen, that a real subscription answers, and that output arrives
progressively rather than all at once.

The debug dispatch hook (`--dispatch`, spec §4) is what keeps that list from being
eight items long. It drives `ActionRegistry.dispatch` — the one chokepoint every state
change passes through — from a file instead of from a mouse, so five of the eight
original criteria become scripts you run once with your own eyes and then hand to CI.
Three of those five are expressible today; **two are not, and this document says so
rather than pretending otherwise.** See §4.

---

## 1. Before you start

```bash
make app-build && make app-test && make app-bundle
```

`make app-bundle` builds the six Go binaries into `bin/`, builds the SwiftPM product,
and assembles `app/Wakil.app` with the five MCP-server binaries in
`Contents/Resources`. That directory is load-bearing: `WakilWiring.binaryURL` resolves
bundled binaries at `<executable dir>/../Resources/<name>` and has **no fallback** once
it is running from a bundle, because its checkout-marker walk stops at the first
ancestor holding a `go.mod` or an `app/Package.swift` and an installed `Wakil.app` has
neither. A bundle missing a binary is an app that cannot find it at all.

**The launch command — rewritten 2026-09-11 by 2b-vi, which deleted four fifths of it.**
It used to carry `WAKIL_PROVIDER`, `WAKIL_CLAUDE_PATH`, `CLAUDE_CONFIG_DIR` and
`CLAUDE_CODE_OAUTH_TOKEN`, because the session's account was a launch-time fact. It is
not one any more: the account is read from the org's provider record and picked in the
window, so the only variable left is the org.

```bash
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil
```

**What moved, rather than disappeared.** Three of those four values still reach the
`claude` child process — `buildLaunch` still writes `CLAUDE_CONFIG_DIR` and
`CLAUDE_CODE_OAUTH_TOKEN` into its environment, and still launches the path the provider
names. They now come from `wakil provider credentials <id>` (the config dir and the agent
binary from the provider record, the token from the Keychain under
`wakil:<org>:provider:<id>`) instead of from the shell that launched Wakil. Setting them
in your shell has no effect on the window any more: nothing in `app/Sources` reads any of
the four out of Wakil's own environment.

**So the setup is now a precondition, not a command line.** Before this launch line can
start a session, all three of these must already be true — `operator-todo.md` §3 has the
commands:

1. The provider is registered with a **config dir and a `--claude-path`**
   (`wakil provider add <id> --kind claude-code --config-dir <dir> --claude-path
   "$(command -v claude)" --org personal`).
2. Its **token is in the Keychain** (`wakil secrets set provider:<id> --org personal`).
3. That provider is the org's **active** one — `active.json`'s fourth axis. A window with
   no active provider opens fine and refuses to start a session, saying so in the notes at
   the bottom. Set it in a running window by switching account, or headlessly, which is
   the cheaper way to do it the first time:

   ```bash
   printf '%s\n' '{"action":"ctx_set_provider","params":{"name":"<provider id>"}}' \
       > /tmp/wakil-pick-provider.jsonl
   WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-pick-provider.jsonl
   ```

   This writes the pick and nothing else — it is bookkeeping, not a live swap, and it
   returns an empty object because there is nothing else it honestly has to say. It needs
   an active project already set, the same as every other `ctx_*` write.

Four things to know about the launch command itself:

- **`personal`, not `initech` or `umbrella`.** Probe §5 confirmed `--mcp-config` and
  `--strict-mcp-config` work unmanaged on the `max` account and explicitly did *not*
  test the `team` and `enterprise` ones, where managed settings could still override
  them. Develop and accept against `personal`.
- **The token is now read from the Keychain and nowhere else.** 2a stored no token and
  took it from the environment; since 2b-vi `wakil provider credentials` reads it, over
  a pipe, on demand — one exit from one process. Nothing writes it to a file, and
  `~/.claude-tokens.zsh` is superseded (`operator-todo.md` §3).
- **Launched this way the window may open behind Terminal.** That is the shell's
  activation policy, not a fault; bring it forward with ⌘-Tab.
- **A window with no usable provider is still legitimate** and is still how you exercise
  everything except the agent: the window opens, and the pane and context controls work.
  What has changed is the wording, because the old text named environment variables that
  no longer decide anything. The message now comes from whichever precondition failed —
  *"no active provider is set for this org"* when `active.json` names none, or the
  `wakil provider credentials` refusal verbatim (which names the exact
  `wakil secrets set` to run) when the account has no stored token. It appears in the
  same two places as before, neither of them the message field — that is an ordinary
  `TextField` and keeps whatever you typed:
  - **at launch, as a note line at the very bottom of the window**, below everything
    else. `WindowSession.start` catches the error while assembling the harness and
    appends it to the same `notes` list that reports a missing Go binary or a socket
    that would not bind;
  - **after you press Send, as the status line** just above those notes, prefixed
    `no agent session: `. `WindowModel.send` writes it there rather than appearing to
    send.

**What the window is.** Deliberately unstyled — no colours, no motion, no custom
fonts. One row of plain-text labels (org, project, environment), a project and an
environment field with buttons, a query field, the database pane as a plain `Table`, a
message field for the agent, and the thought thread as a plain `List`. Every control
dispatches through the same `ActionRegistry` the agent and `--dispatch` use; none of
them writes pane state directly. 2b builds the real design.

**There is one window, and File ▸ New Window is deliberately absent** (⌘N does
nothing). 2a's app delegate holds a single session, so a second window would start a
second `WindowSession` — its own `wakil-ctx`, `wakil-db`, socket and harness — and only
the last one started would be torn down on ⌘Q, leaving the other's socket file and
possibly its `claude` child behind. That would show up in the orphan checks below as a
leak that is really an artefact of ⌘N. Multiple windows and multiple panes are 2b and
2c's; the command is removed rather than left to mislead this runbook.

---

## 2. The three standing checks

Run all three after any change to the harness, the window, or the wiring. Record the
result and the date; a re-run replaces the row rather than appending to it, and the
date is what tells you how stale a PASS is.

### Standing check 1 — a window appears and stays

**Command:** the launch command in §1.

**Look for:**

1. A window titled *Wakil* within a few seconds.
2. A first line reading `org: personal   project: <name>   environment: production`
   (Invariant 8 — the active environment is on screen at all times; probe §7 recorded
   `personal`'s active environment as `production`, so that is the expected value on a
   fresh account, not a mistake).
3. `no rows` where the table will be, since nothing has been queried yet.
4. No line of red-flag text at the bottom. Anything that did not come up cleanly —
   a Go binary that could not be found, a socket that would not bind, no active provider
   for this org or a provider whose token is not in the Keychain (since 2b-vi; it was
   "absent provider variables" before) — is printed there as plain text rather than
   swallowed.
5. It is still there sixty seconds later.

**Before you launch**, record which Wakil sockets already exist:

```bash
SOCKDIR="$(getconf DARWIN_USER_TEMP_DIR)"
ls "$SOCKDIR" | grep '^wakil-.*\.sock$' | sort > /tmp/wakil-sockets-before.txt
```

Then quit with ⌘Q and check nothing was orphaned:

```bash
pgrep -fl 'wakil-ctx|wakil-db'   # must print nothing

# must print nothing either: no socket outlived this session that did not predate it
ls "$SOCKDIR" | grep '^wakil-.*\.sock$' | sort | diff - /tmp/wakil-sockets-before.txt
```

Both are the visible half of `WindowSession.shutdown()`, which runs from
`applicationShouldTerminate` before the process exits. If either prints something, the
teardown did not run.

**Why the socket check is a before/after comparison rather than "the directory is
empty".** Each session unlinks *its own* socket path and nothing else: the path carries
a fresh session UUID, and `MCPSocketServer.stop()` is what removes it. Nothing sweeps
that directory for older `wakil-*.sock` files, by design — a sweep would have to guess
which of the paths it found belong to a session that is still alive, and 2a runs a
single session at a time. So a socket left behind by a crash or a `kill -9` stays there
indefinitely, and an "empty directory" check would read red forever afterwards for a
reason unrelated to the run in front of you. The comparison asks the question the code
can actually answer: *did this session clean up after itself.* If
`/tmp/wakil-sockets-before.txt` is not empty, those are older leaks; delete them by
hand.

**Why `getconf` and not `$TMPDIR`.** The socket goes in
`FileManager.default.temporaryDirectory`, which is the per-user Darwin temporary
directory — the value `getconf DARWIN_USER_TEMP_DIR` prints. Measured on this machine,
that is *not* read from the environment: overriding `TMPDIR` before launching does not
move it, so a shell with a customised `TMPDIR` would have sent this check looking in
the wrong place. `grep` rather than a `wakil-*.sock` glob for the same kind of reason:
zsh, which is macOS's login shell, makes an unmatched glob a shell error that
`2>/dev/null` on the command does not suppress.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-08 | Window titled *Wakil* within seconds. Labels read `org: personal   project: wakil-acceptance   environment: production` — the `production` probe §7 predicted. `no rows` under the query field, no note line at the bottom, still up after a minute. Teardown clean: `pgrep` silent, and the socket directory identical before and after (both empty). |

### Standing check 2 — a real turn against `personal` returns an answer

This is the check that spends your subscription, and the only one that exercises the
whole spine at once: window → `ClaudeCodeCLIHarness` → `claude` → `--mcp-config` →
`--mcp-shim` → unix socket → `MCPSocketServer` → `ActionRegistry.dispatch(origin:
.agent)` → `wakil-ctx` → back.

**Command:** in the running window, type into *message to the agent* and press
**Send**:

> Use your wakil tools to list the projects in this organisation, then tell me how
> many there are.

**Look for, in the thought thread, in this order:**

1. a `session` row carrying a UUID;
2. one or more `tool` rows — at least one naming `mcp__wakil__ctx_list_projects`.
   The `mcp__<server>__<tool>` prefix is the CLI's, and probe §4 found it also
   emitting `tool` rows for tools Wakil never configured (a `ToolSearch` call it makes
   on its own to load a deferred schema); those are expected and are not a fault;
3. a `tool result` row **without** ` — error` in it, carrying your project names;
4. an `assistant` row with the answer in prose;
5. a `turn` row, also without ` — error`.

**This is the only check that confirms the session's permission allow list.** Nothing
in the Swift suite runs `claude`, so `--allowedTools` is asserted at the argv level and
no further: `ClaudeCodeCLIHarnessTests` checks the flag and its value,
`WindowModelTests` checks that the list matches the registry's action set and names
only servers the `--mcp-config` defines. Whether the CLI *honours* those entries is
what your eyes establish here and nowhere else.

**What a permission denial looks like.** The failure mode this check exists to catch is
a `tool result` row carrying ` — error` whose text is probe §6's, verbatim:

> Permission for this tool use was denied. It requires approval, and this session has
> no approval surface — nobody can answer a permission prompt here — so it was denied
> automatically.

That message on a **read** means the allow list is wrong — not that the harness is
broken, and not that the write gate fired. `ActionRegistry.dispatch` and `writeGate`
allow every read unconditionally and were never consulted; the call was refused by the
`claude` CLI's own permission layer before it ever reached the shim, because the tool
was not on `--allowedTools` and `-p` is a session with nobody to ask. Probe §6 measured
exactly this, and it is why the allow list is passed at all.

**Diagnosing it, in this order:**

1. **Read the tool name off the `tool` row that preceded the denial** — the thought
   thread prints it verbatim. It must be one of these nine, which is the whole list the
   session is launched with (`agentAllowedTools`, derived from the registry):

   ```
   mcp__wakil__ctx_list_projects   mcp__wakil__db_list_databases   mcp__wakil__read_pane
   mcp__wakil__ctx_set_environment mcp__wakil__db_run_query        mcp__wakil-pm
   mcp__wakil__ctx_set_project     mcp__wakil__session_resume      mcp__wakil-recall
   ```

   If the denied name differs from its entry above in *spelling*, that is the bug, and
   it is a naming problem in the action set rather than a mistake in the list. Record
   the exact name you saw; it is the one thing this runbook cannot predict. Note that
   every name above is dot-free deliberately: the Anthropic API's documented tool-name
   rule is `^[a-zA-Z0-9_-]{1,128}$`, and the CLI's name construction — read at `claude`
   2.1.263, never run from this repo — concatenates `mcp__<server>__<tool>` through an
   alias-map lookup rather than a sanitiser, so a name breaking that rule would be
   passed on verbatim rather than normalised. The actions were renamed from
   `ctx.list_projects` and friends for exactly that reason, and
   `everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule` in the Swift suite now
   fails at test time if a future action reintroduces an illegal character.
2. **If the denied name is a tool Wakil never configured** (probe §4: the CLI issues its
   own `ToolSearch` call, and could reach for `Bash` or `Read`), the denial is correct
   and is not a failure of this check. Only a denial of an `mcp__wakil*` tool is.
3. **If nothing was denied but no `mcp__wakil*` tool row appears at all**, the problem
   is upstream of permissions: the `--mcp-config` did not reach the CLI, or the shim
   could not connect. Check the note line at the bottom of the window and
   `pgrep -fl Wakil` for a live shim.

**What you should not see, ever:** a `tool` row for a *mutating* tool that succeeded.
2a registered zero `.mutate` actions, and `agentAllowedTools` filters the list to
`.read` (widened to `.read` and `.control` in 2b-i, never to `.mutate`) so the first
one 2b added could not be pre-approved by an allow list nobody revisited.

**Half of that sentence's promise came due on 2026-09-09 and half did not.** Phase
2b-iii registered `db_run_mutation`, and `WindowModelTests` now pins it as absent from
the allow list. **`--permission-prompt-tool` was still not built.** The consequence is
concrete and belongs here rather than in a footnote: in a `-p` session with no approval
surface, an unlisted MCP tool is denied by the CLI itself (probe §6), so a live `claude`
turn asking Wakil to run a mutation is refused *before the request ever reaches Wakil's
socket* — the confirmation plane never appears, because the proposal never arrives.
What you will see in the thought thread is the probe's own wording, `Permission for this
tool use was denied. It requires approval, and this session has no approval surface`.
That is the safe direction to fail in and it is not this check failing; it is
`phase-2b-iii-acceptance.md` §3's first gap, and §2 check 3 there is where it gets
walked.

**The other half came due on 2026-09-10.** `--permission-prompt-tool` is now built
(`docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`), so the
consequence described above no longer holds: a live `claude` turn asking Wakil to run a
mutation now reaches the socket, and the confirmation plane appears. The allow list is
unchanged and `db_run_mutation` is still absent from it — the bridge is what the CLI
consults *because* of that absence. The paragraph above is kept as the record of what
was true between 2026-09-09 and 2026-09-10.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-08 | The whole spine, first live run. `session: 2E787A49-…`, a `ToolSearch` call the CLI made on its own (probe §4 — expected, not a fault), then `tool: mcp__wakil__ctx_list_projects {}`, a `tool result` with the real project record, `assistant: There is **1 project** in this organization: \`wakil-acceptance\``, and a matching `turn` row. **No permission denial anywhere** — this is the only evidence that the CLI honours `--allowedTools`, and it does. The dot-free rename is also confirmed end to end: the namespaced name arrived intact. |

### Standing check 3 — the thought thread renders progressively

**Command:** in the same session, send:

> Count from one to twenty, putting each number in its own short sentence.

**Look for:** rows appearing in the list *while the answer is being produced*, not all
at once when it finishes. Watch the list, not the clock.

**Be precise about what progressive means here.** 2a's decoder maps four frame types
to events and sends everything else to `.unknown`, which the thread draws as `event:
<type>` rows. Probe §2 measured that as the majority path — 10 of `basic-turn.jsonl`'s
13 lines. So what you will see arriving during a turn is a stream of `event:
stream_event` rows interleaved with whole `assistant` rows. **Text arrives one whole
content block at a time, never token by token**, even though `--include-partial-messages`
is passed: the token-level deltas are deliberately not decoded, because the
`assistant` frame carries the same text again in full and decoding both would either
duplicate it or split it across events. Token-level rendering is 2b's, with the design
language.

The check is therefore: does the list grow during the turn? If every row appears in
one burst at the end, the event pump is not draining `events()` as they arrive.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-08 | Rows appeared while the answer was being produced, not in one burst at the end. As documented, text arrived one whole `assistant` block at a time rather than token by token, interleaved with `event: stream_event` rows. |

---

## 3. What `--dispatch` is, before the one-time checks use it

```bash
app/Wakil.app/Contents/MacOS/Wakil --dispatch <file.jsonl> [--environment <name>]
```

One JSON object per line — `{"action": "...", "params": {...}}`, with an optional
`"confirmation"` — dispatched in order with `origin: .debug`. **stdout is strictly one
JSON line per non-empty input line**, so output line N describes input line N and the
whole stream is safe to pipe to `jq`. Diagnostics go to stderr.

**Exit codes, which are what make these checks assertable:**

| Code | Meaning |
|---|---|
| `0` | every line dispatched successfully |
| `2` | the run happened and at least one line produced an error line — malformed JSON, an unknown action, a gate refusal, or a handler that threw. Every other line still ran |
| `1` | the run never happened: the script could not be read, or an argument was missing or flag-shaped |

Note the inversion for a check whose *expected* result is a refusal: that script exits
`2` on success, so its assertion is `[ $? -eq 2 ]`. Wakil never distinguishes an
expected error from an unexpected one; only you know which you meant.

**Two warnings.** `--dispatch` journals to the real `~/.wakil/journal`, and
`ctx_set_project` / `ctx_set_environment` change your real active context. Leave the
context as you found it; check 7 below reads the active environment off disk before it
switches and restores that same value at the end.

---

## 4. The five one-time checks

Spec §8's items 4–8: yours to confirm once with your own eyes, after which the script
in each section stands in for them. **Three were expressible when this was written.
Two were not, and the reason was the same for both: 2a registers zero `.mutate`
actions.**

**Amended 2026-09-09.** Checks 5 and 6 became runnable when Phase 2b-iii registered
`db_run_mutation`. Their scripts below now name it and a real statement, and each
carries the preconditions that stop it passing for the wrong reason. Neither has been
walked; `docs/wakil/phase-2b-iii-acceptance.md` §2 is where the result goes.

That is not an oversight. `registerStandardActions` declares all six actions `.read`,
including `ctx_set_project` and `ctx_set_environment` — those change Wakil's own
selection of what is active, not the outside world the gate exists to protect, and
registering either as `.mutate` would block it in exactly the case (a production
environment) where you most need to switch context in order to go *look* at something.
So there is nothing in 2a for the gate to gate.

| # | Check | Expressible today? | Status |
|---|---|---|---|
| 4 | Dual-drive equivalence | Yes | **PASS 2026-09-08** |
| 5 | The write gate | **No — waits for 2b** | n/a |
| 6 | Production blocked | **No — waits for 2b** | n/a |
| 7 | Context re-pointing | Yes | **PASS 2026-09-08** |
| 8 | Cross-org isolation | Yes | _never run — no fixture; **ACCEPTED 2026-09-15**_ |

### Check 4 — dual-drive equivalence

*Invariant 2: UI controls and the agent dispatch the same actions. Two code paths to
the same state is forbidden.*

**By eye, once.** Start the window (§1). Type `select 1` into *read-only query* and
press **Run query** — this is an `origin: .ui` dispatch, the first in production code.
It journals whether or not it succeeds: with no database configured for the active
environment it will report an error as status text and journal
`{"action":"db_run_query","origin":"ui","outcome":"error"}`, which is still the
dispatch this check is about. Then, from a second terminal, run **the same action with
the same params** through the debug hook:

```bash
printf '%s\n' '{"action":"db_run_query","params":{"query":"select 1"}}' > /tmp/wakil-check4.jsonl
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check4.jsonl
echo "exit=$?"
```

Same action, same params, deliberately: this check's whole claim is that two drivers
reach one path, and it cannot be seen at all if the two legs run different actions.
`db_run_query` is the action to use because it is the one the window can also send —
`ctx_list_projects` is not reachable from any window control, so there is no UI leg to
compare it against.

Then read the journal back and compare the two rows:

```bash
cat ~/.wakil/journal/*.jsonl | jq -c '{action, origin, outcome}' | sort | uniq -c
```

**Look for:** two entries reading `{"action":"db_run_query","origin":"ui","outcome":…}`
and `{"action":"db_run_query","origin":"debug","outcome":…}` — same action, same
outcome, same shape, differing only in `origin`. With no database configured for the
active environment both say `"error"` and the `--dispatch` run exits `2`; with one
configured both say `"ok"` and it exits `0`. Either pairing proves the point; a pair
that *disagrees* on `outcome` does not, and means the two legs did not do the same
thing.

A third entry with `"origin":"agent"` will also be there if standing check 2 has been
run in the same session. It is a bonus, not part of the comparison: the agent chose its
own action, so it will not generally be `db_run_query`.

**If the active environment does have a database configured,** the UI leg is also the
only exercise the database pane gets — take the extra look while you are here (see the
gap recorded in §6). Confirm the table drew the query's columns and rows, and then run
a query against a table with more than 500 rows (`select * from <a big table>`) and
confirm the line **"showing 500 rows — more matched than were returned"** appears under
it. That line and `read_pane`'s `"truncated": true` are the same flag; without it, both
you and the agent read 500 rows as the whole table.

**What is already proved headlessly, so you do not have to take it on faith:** the
`agent` leg is covered end to end by
`ShimTests.theShimCarriesJSONRPCBetweenStdioAndTheSocket`, which drives a real
`--mcp-shim` subprocess against a real `MCPSocketServer` and asserts the resulting
journal entry's origin is `agent`; the `ui` leg by
`WindowModelTests.everyWindowControlDispatchesWithTheUIOrigin`; and journal equality
across origins by `ActionRegistryTests`. What the eye adds here is that the *window's*
controls really reach that path, which no test can assert without a display session.

### Check 5 — the write gate

**Runnable since 2026-09-09; still unrun.** From 2026-09-08 until then this section
read *"not expressible in 2a"*, and the reason was not caution: there was no `.mutate`
action to gate, so any script written here would have passed for the wrong reason.
Phase 2b-iii built the subject
(`docs/superpowers/specs/2026-09-09-phase-2b-iii-write-gate-design.md`) —
`db_run_mutation`, the first and, as of this writing, the only `ActionKind.mutate`
action Wakil registers. The placeholders below are now a real action name and a real
statement. **Nobody has walked the result yet;** when someone does, it is recorded in
`docs/wakil/phase-2b-iii-acceptance.md` §2 check 1, not here — that runbook owns
2b-iii's evidence, and this section owns the script.

**What is checkable without any of this, and always was:** `writeGate` is a pure
function and `WriteGateTests` covers the full environment × kind matrix;
`ActionRegistryTests` asserts `dispatch` consults it *before* the handler runs and
journals `"gated"` on a refusal. The mechanism was tested from 2a onward; what it
lacked was a live subject.

#### Before you run either script

Both scripts below fail at the *connection* rather than at the gate unless a write
credential exists, and a connection failure would let the first script exit `2` for
entirely the wrong reason — it exits `2` whether the gate refused the call or the
handler threw. Three preconditions, and check all three:

1. **The database named in the script has a `writeRef`.** `Database.WriteRef` is a
   second Keychain ref holding a credential the *server* has granted write permission
   to. With the field empty, `OpenDatabaseWritable` refuses before it reads the
   Keychain at all, naming the database and the field — which is Invariant 6 applied
   per resource: every database configured before 2026-09-09 is unmutable until
   somebody edits its record on purpose.

   ```bash
   WAKIL_ORG=personal wakil secrets set 'db:staging:write'   # paste the write DSN on stdin, Ctrl-D
   # then add "writeRef": "db:staging:write" to that database in project.json
   # (`wakil project list` prints the path of each project.json)
   ```

   The `writeRef` must name a *different* entry from `ref`. Pointing both at the same
   credential is not refused anywhere and quietly gives the read path write authority
   at the server, which is the one thing the two-credential design exists to prevent.
   See `operator-todo.md`, "Write credentials — `writeRef`, and what to grant it".

2. **That credential can actually run the statement.** `INSERT`, `UPDATE` and `DELETE`
   on the one table you are aiming at, and nothing else it does not need.

3. **The active environment really is the one you are naming.** `--environment` is
   read by `writeGate` and written to the journal; it does **not** re-point the active
   context, and `wakil-db` resolves which database to open from `active.json`. So
   `--environment staging` against an account sitting on `production` gates the call
   using the string `staging` while opening the *production* database. Probe §7 found
   `personal` sitting on `production`, so this is the likely default rather than a
   corner case. Either switch first, or put a `ctx_set_environment` line at the top of
   the script and restore it at the end, the way check 7 does.

#### The scripts

```bash
# Expected: the mutation is refused for want of confirmation. Exit code 2.
printf '%s\n' '{"action":"db_run_mutation","params":{"statement":"DELETE FROM customers WHERE id=43","database":"orders"}}' > /tmp/wakil-check5.jsonl
app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check5.jsonl --environment staging
[ $? -eq 2 ] && echo "gated as expected"

# Expected: with the confirmation, it runs. Exit code 0.
printf '%s\n' '{"action":"db_run_mutation","params":{"statement":"DELETE FROM customers WHERE id=43","database":"orders"},"confirmation":"confirm"}' \
  > /tmp/wakil-check5-confirmed.jsonl
app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check5-confirmed.jsonl --environment staging
[ $? -eq 0 ] && echo "confirmed and ran"
```

**Read the first script's exit code together with the journal, not on its own.** The
line it writes is `{"action":"db_run_mutation","origin":"debug","outcome":"gated"}`;
an `"error"` there instead means the call never reached the gate.

```bash
grep -h '"action":"db_run_mutation"' ~/.wakil/journal/*.jsonl | tail -2
```

**`confirmation` is a sibling of `action`/`params`, not a param**, and that is
deliberate rather than incidental: `--dispatch` and the window can supply it and a
conforming MCP client cannot, which is what keeps Invariant 7's *typed* confirmation
out of an agent's reach. See §5 of `docs/wakil/phase-2b-iii-acceptance.md` for what
the agent gets instead.

**The window's confirmation control now exists.** This section used to end "the window
has no confirmation control yet … it arrives with the first mutation", and it did:
`ConfirmationPlane` is the red plane above the canvas that renders a parked proposal's
full statement and takes the typed word. What it is *not* yet reachable from is a
mutation the operator composes at the keyboard — the window has a query field and no
mutation field, so `WindowModel.runMutation` has no control wired to it. See
`phase-2b-iii-acceptance.md` §3.

### Check 6 — production blocked

**Runnable since 2026-09-09; still unrun.** It read "not expressible in 2a" until
then, for the same reason as check 5, and the point was worth stating twice: probe §7
found `personal`'s active environment is `production`, so from the moment a `.mutate`
action existed this check became the *default* state of your account rather than
something you have to arrange. `db_run_mutation` is that action, added by Phase 2b-iii
(`docs/superpowers/specs/2026-09-09-phase-2b-iii-write-gate-design.md`), and the result
is recorded in `docs/wakil/phase-2b-iii-acceptance.md` §2 check 2 when someone walks it.

**What is observable today** is the half of it that concerns reads: in `production`,
every 2a action still runs, because `writeGate` allows reads unconditionally. Confirm
that much while you are in the window for check 1 — the query field works with
`environment: production` on screen. It is the correct behaviour and it is not the
block.

**The script.** Check 5's three preconditions apply here too, and the third one
especially: `--environment production` is what `writeGate` reads, and it is the whole
subject of this check.

```bash
# Expected: blocked outright, and NOT recoverable by supplying a confirmation.
printf '%s\n' '{"action":"db_run_mutation","params":{"statement":"DELETE FROM customers WHERE id=43","database":"orders"},"confirmation":"confirm"}' \
  > /tmp/wakil-check6.jsonl
app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check6.jsonl --environment production
[ $? -eq 2 ] && echo "blocked as expected"
grep -h '"outcome":"blocked"' ~/.wakil/journal/*.jsonl | tail -1
```

**The `confirmation` in that script is the check, not an oversight.** `writeGate`
returns `.block` for `.mutate` in production, and `.block` is not a decision a
confirmation can overturn — `ActionRegistry.dispatch` never consults the token on that
path. A run that exits `0`, or that journals `"gated"` rather than `"blocked"`, has
found a real defect: it means production is merely being *gated*, and the second half
of Invariant 8 has quietly become the first half.

`--environment` defaults to `development`, never `production`, so this stricter
behaviour has to be opted into explicitly rather than tripped by omission.

The other half of Invariant 8 — *"production looks alarming"* — was **not met in 2a and
was not checkable here.** The environment was on screen as plain text and nothing about
`production` was treated differently, because 2a had no visual language to be alarming
in. 2b-ii gave it one (`phase-2b-ii-acceptance.md` check 5, the production treatment)
and 2b-iii gave the *confirmation surface* the same hue — `#e85c5c`, §5's reserved
destructive red, on the plane's border, its environment label and its every-row
warning. Both are judgements by eye and both are recorded in their own runbooks rather
than here: `phase-2b-ii-acceptance.md` §2 check 3, and
`phase-2b-iii-acceptance.md` §2 check 6.

### Check 7 — context re-pointing

*Invariant 5: exactly one active (org, project, environment).*

**By eye, once.** In the window, type a project name into *project* and press **Set
project**; the labels must change to match. Do the same with *environment*. A refusal
(a project belonging to another org, say) appears as plain status text under the
table rather than doing nothing.

**The script that replaces it.** Note that this changes your real active context, so
it puts it back — **to whatever it found, not to a constant**. An earlier version of
this script restored a hard-coded `production`, which was right only because probe §7
happened to record `personal` sitting on `production`; run from anywhere else it would
have silently re-pointed your context rather than restoring it.

```bash
BEFORE=$(jq -r .environment ~/.wakil/orgs/personal/active.json)
printf '%s\n' \
  '{"action":"ctx_set_environment","params":{"name":"staging"}}' \
  '{"action":"db_list_databases","params":{}}' \
  "{\"action\":\"ctx_set_environment\",\"params\":{\"name\":\"$BEFORE\"}}" \
  > /tmp/wakil-check7.jsonl
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check7.jsonl
echo "exit=$?"   # expected 0, if `staging` exists in the active project
echo "restored to: $BEFORE"
```

`orgs/<org>/active.json` is where Phase 1 puts the active `(project, environment)` pair
for one org — the same file the Phase 1 acceptance run reads. If it is absent, no
context has been set for that org and there is nothing for this check to restore; set
one first.

**Look for:** exit 0, and the middle line's database list belonging to `staging` rather
than to the environment `$BEFORE` names. If the active project has no `staging`
environment the first line errors and the run exits 2 — that is a fixture problem, not a
failure of the check; point it at an environment the project actually has.

### Check 8 — cross-org isolation

*Invariant 4: cross-org bleed must be structurally impossible — by the service name,
by the per-org directory, and by `Resolve()`'s check — not merely avoided.*

**By eye, once.** With `WAKIL_ORG=personal`, type the name of a project belonging to a
*different* org into the window's *project* field and press **Set project**. It must
be refused, with the server's own message visible as status text.

**The script that replaces it:**

```bash
printf '%s\n' '{"action":"ctx_set_project","params":{"name":"<a project of another org>"}}' \
  > /tmp/wakil-check8.jsonl
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check8.jsonl
[ $? -eq 2 ] && echo "refused as expected"
```

**Look for:** exit 2, and an `{"error": ...}` line carrying `wakil-ctx`'s own refusal
verbatim — never a silent no-op. `StandardActionsTests
.ctxSetProjectRefusesAProjectFiledUnderAnotherOrg` asserts the same refusal headlessly,
against the real `bin/wakil-ctx` and by **dispatching the action** — the same path the
command above and the window's button take — so what your eye adds is only that the
button really reaches it. (This assertion used to live in `ContextStoreTests` against
`ContextStore.setProject`, a method no production caller had; it moved when that method
was deleted.)

---

## 5. What has been verified headlessly

Recorded here so a later reader can tell what was actually observed from what is still
outstanding. None of this needed a display session or a Claude turn. Rows 1–4 are Task
11's, 2026-09-08; row 5 was added later the same day with `read_pane`'s wiring, and
row 6 with the session's permission allow list.

| # | Observation |
|---|---|
| 1 | `make app-bundle` produced `app/Wakil.app` with `Contents/MacOS/Wakil` and exactly the five MCP-server binaries in `Contents/Resources`. |
| 2 | `app/Wakil.app/Contents/MacOS/Wakil --mcp-shim --socket /tmp/absent.sock` exited `1` with `connect(/tmp/absent.sock) failed: No such file or directory` on stderr. No window, no hang. |
| 3 | `--dispatch` run **from inside the bundle**, against a scratch `HOME` and with `WAKIL_BIN_DIR` unset, spawned `wakil-ctx` from `Contents/Resources` and returned real `ctx_list_projects` (then named `ctx.list_projects`) results with exit `0`. This is the first end-to-end exercise of `binaryURL`'s bundle branch; with `WAKIL_ORG` unset the same run returned the server's own "WAKIL_ORG is not set" error and exit `2`, which is how the spawn was confirmed rather than assumed. |
| 4 | A real `--mcp-shim` subprocess carried JSON-RPC to a real `MCPSocketServer` and back, and the resulting journal entry's origin was `agent` (`ShimTests.theShimCarriesJSONRPCBetweenStdioAndTheSocket`). Spec §8 had listed the shim direction as covered by this runbook alone. |
| 5 | **Invariant 3, over the real transport.** With a pane populated by `PaneStore.setRows`, a `tools/call` for `read_pane` sent through a real `--mcp-shim` subprocess to a real `MCPSocketServer` came back carrying that pane's columns and rows intact — cell types included — in both `structuredContent` and the text `content` block (same test as row 4). `MCPServerTests`' four `readPane…` tests cover the in-process shapes: the snapshot verbatim, an empty snapshot for a pane nothing has written to, `-32602` for a missing or non-string `paneId`, and no journal entry (`read_pane` is hand-written, not a dispatched action). |
| 6 | **The session's permission allow list, at the argv level only.** `buildLaunch` passes `--allowedTools` naming the registry's `.read` and `.control` actions, both hand-written read tools (`read_pane` and `read_layout`), and the `wakil-pm`/`wakil-recall` servers, and passes no `--permission-mode`, but does now pass `--permission-prompt-tool` (added 2026-09-10; the row read "and no `--permission-prompt-tool`" before that). Asserted by six `ClaudeCodeCLIHarnessTests` (the allow-list flag, its comma-joined value, the prompt-tool flag, its constant-built value, the absence of the other permission flags, and the bridge's absence from the allow list) and four `WindowModelTests` (the list equals the registry's `.read` and `.control` action set plus both read tools; a `.mutate` action never appears; every entry names a server the `--mcp-config` defines; the list admits `.control` actions and both read tools). **Nothing here ran `claude`**, so that the CLI honours the list is standing check 2's to establish and no test's. |

---

## 6. Known gaps in 2a, none of them checkable here

Stated so that a PASS on everything above is not read as more than it is.

- **Only one pane exists to observe.** `read_pane` is wired and answers from
  `PaneStore` (row 5 above), but 2a ships one pane type — `db` — and the window keeps
  no selection state, so a deictic reference resolves to a whole pane's contents
  ("this table") and not to a row within it. Invariant 3 holds for what 2a puts on
  screen; 2c's data surface is what makes it worth more.
- **Zero `.mutate` actions**, so checks 5 and 6 wait for 2b, as recorded above.
- **The database pane's populated path is uncovered.** No test drives `db_run_query`
  against a live `wakil-db` — doing so needs Keychain-backed credentials, which no test
  here may touch — so nothing automated has ever seen real rows reach the pane. What
  *is* covered headlessly is the projection either side of that call:
  `StandardActionsTests` pins the `structuredContent` → pane step (columns, rows and
  `truncated`) against literal `wakilcore.Rows` payloads, `TestRowsJSONWireShape`
  (Go) pins the payloads themselves, and `MCPServerTests`/`ShimTests` cover
  `PaneStore` → `read_pane`. The gap is the live middle. Check 4's last paragraph asks
  the operator to look at the pane, but only when the active environment happens to
  have a database configured — so it closes the gap for that operator and no one else.
  This is how a dropped `truncated` flag survived eleven task reviews.
- **Resume is not implemented.** Charter open question 5 settled resume as a visible
  enumerated action, and that is still the intent, but 2a ships none of it: `--resume`
  is passed nowhere, `AgentHarness` has no resume method, and the `session_resume`
  action only reads a session's metadata and first prompt. Resume is 2b's.
- **"Production looks alarming" is unmet** — plain text only, no treatment.
- **`initech` and `umbrella` are untested.** Probe §5 confirmed `--mcp-config` and
  `--strict-mcp-config` on the unmanaged `max` account only; managed settings on the
  `team` and `enterprise` plans could still override them, and nothing here has tried.
- **The app is unsigned and hand-assembled.** No signing, no entitlements, no
  notarisation; `Wakil.app` lives in the build directory and is gitignored. Distribution
  is 2b's.
- **The agent can re-point the active context unasked, and nothing gates it.**
  *Found by the 2026-09-08 acceptance run, not by any review.* Standing check 2 asked
  the agent only to list projects and count them. The journal from that turn reads:

  ```json
  {"action":"ctx_list_projects","origin":"agent","outcome":"ok"}
  {"action":"ctx_set_project","origin":"agent","outcome":"ok","params":{"name":"wakil-acceptance"}}
  ```

  It set the active project as well. Harmless on the day — it set it to what was
  already active — but it was not asked to, and nothing stopped it: `ctx_set_project`
  and `ctx_set_environment` are registered `.read`, so `writeGate` allows them
  unconditionally in every environment, and `agentAllowedTools` puts them on the
  session's allow list because it filters on exactly that kind.

  The `.read` classification was deliberate and its reasoning is still sound as far as
  it goes (`StandardActions`' own doc: these change Wakil's selection of what is
  active, not the outside world the gate exists to protect, and gating them would
  block a context switch in `production` precisely when an operator most needs to go
  *look* at something). What the reasoning did not anticipate is the third party. It
  weighed the gate against the operator; the operator is not the only caller. An agent
  answering a question can silently move the one active `(org, project, environment)`
  that Invariant 5 says there is exactly one of — and every subsequent action, from
  either driver, then runs against a context the operator did not choose and has no
  reason to re-read.

  Not fixed in 2a: the fix is a design question, not a patch. Either a third
  `ActionKind` between `.read` and `.mutate` for "changes Wakil's own state, not the
  world" — gated by origin rather than by environment — or simply dropping the two
  setters from `agentAllowedTools` so the agent can read context but not steer it.
  2b is where the gate's second layer gets built and where this belongs; noted here
  because the run is the only reason anyone knows.
