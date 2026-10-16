# Wakil — the permission-prompt bridge

**Status:** draft for review · **Created:** 2026-09-10 · Conforms to
`docs/wakil/north-star.md`. Probe: `docs/wakil/permission-prompt-probe.md` (ten
scenarios, `claude` 2.1.266, 2026-09-10).

2b-iii built a write gate and no agent has ever reached it. This spec is the missing
half: the reason a live agent's mutation never arrives at Wakil's socket, and the
smallest thing that fixes it.

## 0. Where this sits

Standalone, ordered after 2b-iv, before 2b-v. Decided by the operator on 2026-09-10.

| | Delivers | Status |
|---|---|---|
| ~~2b-i~~ | Pane model, magnetic canvas, the rail, ⌘P/⌘K | **Met 2026-09-08** |
| ~~2b-ii~~ | The void, planes, the Core, motion, the thought thread | Implemented 2026-09-09; acceptance outstanding |
| ~~2b-iii~~ | Write-gate UI and the first `.mutate` | Implemented 2026-09-09; **acceptance outstanding, and its live-agent `.mutate` path (§2 check 3b) was unreachable** |
| ~~2b-iv~~ | The void as the Core | **Met 2026-09-09** |
| ~~*probe*~~ | What does `--permission-prompt-tool` actually do? | **Answered 2026-09-10** — `docs/wakil/permission-prompt-probe.md` |
| **this spec** | The permission-prompt bridge | Makes `phase-2b-iii-acceptance.md` §2 check 3b — the live-agent `.mutate` half — walkable for the first time |
| 2b-v | Session resume | Untouched by this |
| 2b-vi | Provider picker | |
| 2b-vii | Signing | Partly blocked externally |

**Three phase-map options were on the table and the operator chose this one.** Completing
2b-iii would have enlarged an already-unwalked runbook; folding into 2b-v would have
reversed the 2026-09-09 split that separated the gate from session resume on the grounds
that they *"share no type, no file and no test."* That reason has weakened — what remains
of the gate work is a `buildLaunch` flag, and `--resume` is also a `buildLaunch` flag —
but the runbooks still test unrelated judgements, and mixing *"did the confirmation plane
read as alarming"* with *"did the thought thread rebuild"* in one sitting serves neither.

**2b-iii is not marked met by this spec.** Its six standing checks remain unwalked and
remain its own. What this changes is that one of them — check 3b, the live-agent
`.mutate` half of check 3 — stops being unwalkable.

## 1. Scope

**In:** one hand-written MCP tool, one launch flag, one policy function, their tests, and
the doc comments that currently assert the opposite.

**Out:** everything else. No change to `agentAllowedTools`'s filter, to `writeGate`, to
`ConfirmationBroker`, to `PendingMutation`, to the confirmation plane, or to the journal.
No new state anywhere. If this spec's implementation adds a stored value, something has
gone wrong with it.

## 2. The defect, stated exactly

`agentAllowedTools` filters the registry to `.read` and `.control` and never `.mutate`.
That filter is correct and this spec does not touch it: pre-approving a `.mutate` action
in an allow list nobody revisits is precisely the failure it exists to prevent.

The CLI's rule for a tool that is *not* on the allow list is not "ask" — it is "ask
whoever is available, and deny if nobody is." A `-p` session has nobody available unless
one is named. `docs/wakil/phase-2a-probe.md` §6 recorded the exact wording:

> Permission for this tool use was denied. It requires approval, and this session has no
> approval surface — nobody can answer a permission prompt here — so it was denied
> automatically.

So `db_run_mutation` is advertised in `tools/list`, visible to the agent, reachable by
name, and refused one layer above Wakil. **The request never reaches Wakil's socket**, so
`ActionRegistry.dispatch` never runs, `writeGate` never returns `.gate`,
`parkForConfirmation` never parks, and no confirmation plane ever appears. The
agent-proposed mutation path is proved by `MCPServerTests` and by nothing else.

2a declined to build the approval surface on the stated grounds that it *"has nothing real
to gate"*. That ceased to be true on 2026-09-09.

## 3. The rule this rests on

**The bridge decides reachability, never permission.**

The CLI asks *may this tool be invoked*. Wakil answers that question and only that
question. Whether the invocation then *executes* is decided where it is decided today —
`ActionRegistry.dispatch`, then `writeGate`, then a human at the confirmation plane.

This is Invariant 2 restated at a new boundary: actions are the only path to state, so a
layer that is not an action must not become a second place where state changes are
allowed or refused. A bridge that consulted `writeGate` would be exactly that second
place, and §6 records the concrete cost of building it.

## 4. What the CLI wants — measured, not assumed

From the probe. Repeated here because the implementation is written against these shapes
and a reader should not have to hold two documents open.

**In**, as the `arguments` of an ordinary `tools/call`:

```json
{"tool_name": "mcp__wakil__db_run_mutation",
 "input": {"statement": "DELETE FROM bookings WHERE id = 42", "database": "staging"},
 "tool_use_id": "toolu_…"}
```

`tool_name` is the prefixed form for MCP tools and the **bare** name for built-ins
(`"Write"`, `"Bash"`) — probe §7.

**Out**, as one text content block whose text is JSON:

```json
{"behavior": "allow", "updatedInput": {…}}
{"behavior": "deny", "message": "…"}
```

Three measured properties the implementation depends on:

- A denial's `message` reaches the agent **verbatim**, as `tool_result` content with
  `is_error: true` (probe §4).
- `updatedInput` **replaces** the tool's arguments wholesale (probe §5).
- The tool **must** appear in `tools/list` or the CLI hard-errors and the error reaches
  the agent (probe §8).

## 5. `approve_tool_use`

A third hand-written tool on Wakil's MCP surface, beside `read_pane` and `read_layout`,
intercepted in `handleToolsCall` before the registry lookup and for the same reason those
two are: it is not an action. It changes nothing, so there is nothing for the gate to
refuse; it observes nothing, so there is nothing for the journal to record. Registering
it as an action would put a no-op entry in the journal every time the agent reached for a
tool.

Its name is a public constant, `permissionPromptToolName`, for the reason
`readPaneToolName` is one: `buildLaunch` spells the same string into
`--permission-prompt-tool`, and a mismatch makes the CLI refuse at the first permission
check with an error the agent reads (probe §8) while nothing in the app looks wrong.

**Its `tools/list` description is written for the agent that will read it**, since it
cannot be hidden. It says what the tool is for and that calling it directly accomplishes
nothing — an agent that understands the tool is not asking Wakil's permission for
anything is an agent that does not try to use it as one.

### The decision

One pure function, no I/O, the entire policy:

```swift
public enum PermissionDecision: Equatable, Sendable {
    case allow
    case deny(String)
}

public func permissionDecision(toolName: String, knownActions: [String]) -> PermissionDecision
```

| `toolName` | Decision |
|---|---|
| `mcp__wakil__<name>` where `<name>` ∈ `knownActions` | `.allow` |
| `mcp__wakil__read_pane`, `mcp__wakil__read_layout` | `.allow` |
| `mcp__wakil__approve_tool_use` | `.deny` |
| anything else — built-ins, other servers, unknown names | `.deny` |

`knownActions` is passed in from `registry.all()` rather than read inside, so the function
stays pure and so the list cannot fall behind the action set — the same derivation
`agentAllowedTools` uses, for the same reason.

**Every kind is allowed here, `.mutate` included, and that is the point.** The filter that
keeps `.mutate` off the allow list stays exactly as it is; this function is what the CLI
consults *because* of that filter. Allowing a `.mutate` action to be invoked is not
allowing it to run.

**The tool refuses to answer about itself.** The CLI has no reason to ask — a designated
permission tool is not itself permission-checked — so this branch is unreachable. It is
written anyway because "unreachable" is a claim about a CLI this repo does not own, and
the cost of being wrong is a recursion.

**`wakil-pm` and `wakil-recall` are denied, and are equally unreachable**: both are
allow-listed server-wide, so probe §6 says they never arrive here. Denying them keeps the
fallthrough honest rather than carving out an exception for a case that cannot occur.

### The default branch is the whole point

Probe §7: the flag routes Claude's **built-in** tools here too — `Write` and a
non-trivial `Bash` both arrived.

Today Wakil passes no prompt tool, so every built-in that would prompt is auto-denied for
want of an approval surface. **Naming a prompt tool makes Wakil the answerer for those
too.** A bridge that allowed by default would remove a restriction while appearing to add
one — an agent would gain `Bash` and `Write` in the same change that was supposed to
tighten the gate.

**What this does not reach, and must not be described as reaching.** Probe §7 and §11
also measured `Bash(echo hi)`, `grep -rl`, and `Read` being auto-allowed by the CLI's own
policy *without the prompt tool being consulted at all*. Those calls cannot be denied
here, because the bridge is never asked about them.

**Narrowed 2026-09-10, and the narrowing matters more than the original claim did.** Every
one of those three measurements targeted a path *inside the session's working directory*,
which nobody noticed until the acceptance run refused a `Read` of `/tmp/x` that this
paragraph said could not be refused. Re-measured deliberately — same tool, two paths, one
session — the boundary is path scope, not tool identity: `Read ./inside.txt` and
`Bash cat inside.txt` never reach the bridge, while `Read /tmp/…` and `Bash cat /tmp/…`
both do and are both denied. Probe §7 carries the table. So this paragraph's set is
smaller than it says and the bridge's reach is larger, which is the safer direction to
have been wrong in but is still wrong. That is already true of Wakil today —
a tool that never needs permission never needs an approval surface — so it is neither
caused nor worsened by this spec, and it is not this spec's to fix. It is written down
because "the bridge denies built-ins" is the natural summary and it is false; the true
statement is **the bridge denies every built-in it is asked about**.

So the default is `.deny`, and the test for it **enumerates the built-ins by name** rather
than asserting a fallthrough. A fallthrough test passes for the wrong reason if the
matching logic is later rewritten; a named list fails.

### Shapes

On `.allow`, `updatedInput` echoes `input` **verbatim** — never rebuilt, never
normalised, never with a key added. Probe §5 measured that `updatedInput` replaces the
arguments wholesale, so anything reconstructed silently rewrites the call the agent made
and neither the agent nor the operator is told. This is the same rule
`parkForConfirmation` already follows for its re-dispatch, and for the same reason: the
call that runs must be the call that was proposed.

An `input` that is absent, or is not an object, echoes back as an empty object rather
than failing — the schema is the target tool's business, and a bridge that second-guessed
it would refuse calls Wakil's own dispatch would have handled.

**Malformed params return a `deny`, not a JSON-RPC error.** A missing `tool_name` leaves
the bridge unable to say what is being asked about, and a JSON-RPC error is not an answer
to *may this run* — the CLI's handling of one is unmeasured, and the failure direction
that costs nothing is refusal. The message says the request was malformed, so an agent
that somehow caused it is not told it lacked permission.

## 6. Production mutations are allowed through here, deliberately

`writeGate` returns `.block` for a `.mutate` action while the active environment is
production. The bridge could refuse those early, and does not.

If it did, the request would never reach `dispatch`, and `dispatch` is what writes
`"blocked"` to the journal. The refusal would become the one class of refused mutation
that leaves no record — the class most worth having a record of. Invariant 2 again: the
enforcement point is also the recording point, and moving enforcement earlier moves
recording nowhere.

So a production mutation is allowed to be invoked, reaches Wakil, is refused by
`writeGate`, journalled `"blocked"`, and the agent is told. One extra round trip buys a
journal entry.

## 7. The flag

`buildLaunch` gains two arguments:

    --permission-prompt-tool mcp__wakil__approve_tool_use

built from `wakilShimServerName` and `permissionPromptToolName` rather than written as a
literal, so the flag and the tool cannot drift.

No new parameter on `buildLaunch`. The value is derived entirely from constants, and a
parameter would imply a caller that might pass something else — there is none, and a
harness that launched without Wakil's own approval surface is not a configuration this
phase wants to make expressible.

**`--permission-prompts` is still not passed.** Its default is `host`, which is what makes
the prompt tool reachable (probe §1). Passing it explicitly would state a default; passing
`none` is what 2a's probe did to *measure* the denial this spec is removing.

**`--permission-mode` is still not passed**, for the reasons `agentAllowedTools`'
doc comment already gives. Nothing here changes that argument, and `bypassPermissions`
would switch off the layer this spec has just given something to answer with.

**`--allowedTools` does not change.** Probe §6: an allow-listed tool never reaches the
prompt tool, so reads and control actions keep going straight through. Routing them
through the bridge would add a round trip per call to the multi-step spoken command that
is the Phase 2 exit criterion, in exchange for nothing — the bridge would allow exactly
what the list already allows.

**`approve_tool_use` is not added to the allow list either**, and probe §11 is why this is
a decision rather than an oversight. That scenario ran Wakil's exact shape — a non-empty
allow list that excludes the prompt tool — and the CLI reached its designated prompt tool
anyway. Listing it would buy nothing and would hand the agent a silent route to call it
directly (§9).

## 8. What a live mutation now does, end to end

1. The agent emits `mcp__wakil__db_run_mutation`.
2. Not on the allow list, so the CLI calls `mcp__wakil__approve_tool_use` with
   `{tool_name, input, tool_use_id}`.
3. `permissionDecision` finds `db_run_mutation` in `registry.all()` → `.allow`, `input`
   echoed verbatim.
4. The CLI issues the real `tools/call`. `handleToolsCall` dispatches it.
5. `writeGate` returns `.gate`; `dispatch` throws `.needsConfirmation`;
   `parkForConfirmation` parks it in the broker. **The confirmation plane appears, for the
   first time, from a live agent.**
6. Approve → re-dispatch with `confirmation: "confirm"`, environment re-read after the
   park, journal writes the `gated` → `ok` pair.
7. Cancel → `-32002`. Expire → `-32004`. Broker busy → `-32005`. Wording unchanged from
   2b-iii, and probe §4 shows the agent reads them intact.

Nothing in steps 4–7 is new. That is the measure of whether this spec is the right size.

## 9. The agent can call the bridge itself

Probe §8 makes it visible in `tools/list` and there is no way to hide it.

It is a pure function of `tool_name` returning text. An agent calling it directly gets a
JSON string back and nothing else happens: the CLI is not listening to a call it did not
make, so no permission is granted and no state moves. The worst available outcome is that
the agent wastes a turn.

Documented rather than defended against. A defence would mean distinguishing a
CLI-originated call from an agent-originated one, and the only available signal —
`_meta["claudecode/toolUseId"]` — is a field the agent can also write. Building a check
that a determined caller can satisfy would give a false assurance in exchange for real
code.

## 10. File structure

| File | Change |
|---|---|
| `app/Sources/WakilKit/MCP/PermissionPrompt.swift` | **New.** `PermissionDecision`, `permissionDecision`, `permissionPromptToolName`, the `tools/list` entry, and the handler that renders the CLI's wire shape. |
| `app/Sources/WakilKit/MCP/MCPServer.swift` | Append the entry in `tools/list`; intercept the name in `handleToolsCall` beside `read_pane`/`read_layout`. |
| `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift` | Two arguments in `buildLaunch`; rewrite the doc-comment paragraph asserting no `--permission-prompt-tool` is built. |
| `app/Sources/WakilKit/App/WindowModel.swift` | Rewrite the *"there is still no `--permission-prompt-tool`, and it is now overdue"* passage. The filter itself is untouched. |
| `app/Tests/WakilKitTests/PermissionPromptTests.swift` | **New.** §11. |
| `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift` | Invert the assertion at line 79. |

A new file rather than growing `MCPServer.swift`, which is already 938 lines and holds
the socket server, the JSON-RPC dispatch, the gate park and both read tools.

## 11. Verification

Headless, in `PermissionPromptTests`:

1. A registered action of each kind — `.read`, `.control`, **`.mutate`** — is allowed.
   The `.mutate` row is the one that would have failed before this spec.
2. `read_pane` and `read_layout` are allowed.
3. Built-ins are denied, **enumerated by name**: `Bash`, `Write`, `Edit`, `Read`, `Task`,
   `WebFetch`, `WebSearch`, `NotebookEdit`. `Read` is in the list even though probe §7
   says the CLI settles it before asking — this checks the function's answer, not whether
   the question arrives, and the day CLI policy changes is the day the difference matters.
4. `mcp__wakil__<unregistered>` is denied.
5. `approve_tool_use` denies itself.
6. `mcp__wakil-pm__my_issues` and `mcp__wakil-recall__recall` are denied.
7. A bare unprefixed registry action name (`db_run_mutation`, no `mcp__wakil__`) is
   denied — the prefix is the namespace and a name that skips it is not this server's.
8. `knownActions` is derived from `registry.all()`, asserted against the live registry so
   the list cannot fall behind the action set. The drift alarm `agentAllowedTools`
   already carries, for the function that now has the opposite polarity.
9. The reply is one text content block whose text parses as JSON and carries `behavior`.
10. `updatedInput` is byte-identical to `input`, tested with a nested object and a key no
    Wakil action declares.
11. A missing/absent/non-object `input` echoes `{}` and still allows.
12. Missing `tool_name` denies, with a message naming the malformation rather than a
    permission.
13. `tools/list` contains `approve_tool_use` — probe §8 makes its absence a hard CLI
    failure, so this is not a cosmetic assertion.
14. `buildLaunch` emits `--permission-prompt-tool` with the exactly-prefixed value.
15. `agentAllowedTools` still excludes every `.mutate` action. Unchanged and must stay
    green: this spec's correctness depends on that filter continuing to do its job.

**Nothing here runs `claude`.** As with every flag `buildLaunch` builds, what is verified
is the argv, and that the CLI honours it is settled by the probe and re-settled by the
acceptance run.

Live, in the acceptance runbook this spec owes:

16. A live agent asked for a non-production mutation raises the confirmation plane.
    **This is `phase-2b-iii-acceptance.md` §2 check 3b's `.mutate` half, and it has never
    been runnable.**
17. Approving it runs the statement and the journal shows `gated` → `ok`. The approval
    half of the same check.
18. A live agent asked for a **production** mutation is refused outright: the journal
    shows `blocked`, never `gated`, and no confirmation is offered because none would
    help. `writeGate`'s `.block` row reaching a live agent for the first time — no prior
    check, live or headless, exercised this path.
19. Cancelling the non-production mutation refuses it, and the agent is told it needs
    confirmation rather than that it timed out.
20. Letting it expire tells the agent it expired — the `.cancelled`/`.expired` distinction
    reaching a real agent for the first time.
21. A live agent asked to run a shell command that writes or deletes is refused, and
    Wakil is what refused it. The §5 widening, checked rather than argued.

## 12. What this does not do

- **It does not mark 2b-iii met.** Six standing checks remain, and four of them are about
  whether the plane reads as alarming rather than as an obstacle — judgements no test
  makes.
- **It does not gate the agent's *own* built-in tools by policy.** It denies the ones it
  is asked about, wholesale. If a later phase wants the agent to run a shell command, that
  is a registry action with a kind and a gate, not a widening here.
- **It does not stop the agent reading files inside the session's working directory.**
  Probe §7 and §11: the CLI's own policy auto-allows read-only work there and it never
  reaches the bridge. True today, unchanged by this, and out of scope — closing it needs
  `--permission-mode` or a settings file in the provider's config dir, which is 2b-vi's
  territory, not this spec's. **Narrowed 2026-09-10:** as written this bullet said `Read`,
  `Glob` and read-only `Bash` outright, and that overstated the hole. Re-measured, the
  boundary is path scope — the same `Read`, and the same `cat`, pointed one directory
  outside the cwd, does reach the bridge and is denied there. Probe §7's table records the
  four calls. `Glob` is struck: it does not exist in 2.1.266's tool list, so nothing about
  it was ever measured.
- **It does not close probe §10's residual risk** in `parkForConfirmation`, only narrows
  it: at 130s the CLI does not give up. Ten minutes is unmeasured.
- **It adds no way for an agent to confirm its own mutation**, and the injection route
  probe §5 found is closed by `confirmation`'s existing placement as a sibling of
  `arguments`. A refactor that moves it inside would open it.

## 13. Risks

**The flag is undocumented.** Absent from `claude --help` on 2.1.266, mentioned only
inside `--permission-prompts`' text. It could change or vanish.

Not guarded at startup. If the option is removed, `claude` rejects it and the harness sees
a non-zero exit with the reason on stderr — loud, immediate, and pointing at the cause. A
guard would mean spawning `claude` at launch to test a flag, paying a cost on every start
for a failure that already announces itself. The runbook pins 2.1.266 instead, and a
standing check re-walks it.

**The wire shape is undocumented too**, and measured rather than specified. Same failure
mode, less loud: a changed shape would make the bridge's answers unparseable, and the CLI
would presumably fall back to denying. Failing closed is the right direction, and check 16
is where it surfaces.

**Wakil becomes the refusal surface for built-ins.** Named in §5 and defended by the
default branch and check 3. The risk is not that the code is wrong today — it is that a
later reader sees a function that mostly says `.allow` and "fixes" the default. The test
enumerating built-ins by name is what makes that fix fail.
