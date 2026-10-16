# The `--permission-prompt-tool` probe

**Run:** 2026-09-10 · **Machine:** MacBook Air M3 (`Mac15,12`), macOS 26.6.2 ·
**CLI:** `claude` 2.1.266 · **Account:** `personal` (`~/.claude-personal`, `firstParty`,
no `permissions` block in `settings.json`) · **Probe:** `.context/probe-permission-prompt/`,
throwaway, gitignored

Run before writing the permission-prompt bridge spec, for the reason the 2a and 2b probes
were run before theirs: to stop a spec being written against assumptions about a CLI this
repo does not own.

The question was narrow. `docs/wakil/phase-2a-probe.md` §6 established *that* the CLI's
permission layer covers MCP tool calls and denies them in a session with no approval
surface. It never established what an approval surface actually **is** on the wire — what
the CLI sends a `--permission-prompt-tool`, what it expects back, and what happens to the
answer. Ten scenarios, all against the real binary.

The probe was a Python stdio MCP server logging every frame it received, exposing three
tools: `probe_write` (mutation-shaped, the thing to be gated), `probe_read` (to test the
allow-list interaction), and `probe_approve` (the `--permission-prompt-tool` target, whose
answer was set per scenario by an environment variable).

---

## 1. The flag is undocumented but live

`--permission-prompt-tool` does not appear in `claude --help` on 2.1.266. The only
mention of it anywhere in that output is inside the help text of a *different* flag:

    --permission-prompts <target>  Who answers permission prompts with --print:
                                   "host" (the SDK host or --permission-prompt-tool)
                                   or "none" (nobody: anything that would prompt is
                                   denied automatically; the permission mode still
                                   decides everything else)
                                   (choices: "host", "none", default: "host")

It is nevertheless accepted and honoured. **`--permission-prompts` defaults to `host`**,
which is what makes the prompt tool reachable without passing a second flag — and it is
also the flag 2a's probe set to `none`, which is why that probe measured a denial rather
than a prompt.

Recorded as a risk rather than a blocker: an undocumented flag can change or vanish. If it
is removed, `claude` rejects the unknown option at startup and the harness sees a non-zero
exit with the reason on stderr. That failure is loud, so the bridge carries no startup
guard; the acceptance runbook pins the version instead.

## 2. What the CLI sends

Scenario 1 — `probe_write` absent from `--allowedTools`, `probe_approve` answering
`allow`. The prompt tool received an ordinary `tools/call`:

```json
{"jsonrpc": "2.0", "id": 2, "method": "tools/call",
 "params": {"name": "probe_approve",
            "arguments": {"tool_name": "mcp__probe__probe_write",
                          "input": {"statement": "DELETE FROM bookings",
                                    "database": "staging"},
                          "tool_use_id": "toolu_011d9gmov8gr2uir2rcjqvdW"},
            "_meta": {"claudecode/toolUseId": "toolu_011d9gmov8gr2uir2rcjqvdW",
                      "progressToken": 2}}}
```

Three fields in `arguments`: `tool_name` (prefixed form for MCP tools, bare name for
built-ins — see §7), `input` (the proposed arguments, verbatim), and `tool_use_id`, which
is repeated in `_meta` under `claudecode/toolUseId`.

## 3. What the CLI expects back

One text content block whose **text is JSON**, not a JSON result object:

```json
{"jsonrpc": "2.0", "id": 2,
 "result": {"content": [{"type": "text",
   "text": "{\"behavior\": \"allow\", \"updatedInput\": {\"statement\": \"DELETE FROM bookings\", \"database\": \"staging\"}}"}]}}
```

`{"behavior": "allow", "updatedInput": {…}}` or `{"behavior": "deny", "message": "…"}`.
The real `tools/call` then follows on the same connection, and in scenario 1 `probe_write`
ran with exactly the arguments proposed.

## 4. A denial's `message` reaches the agent verbatim

Scenario 2, `probe_approve` answering `deny` with a marker string. The agent saw:

    TOOL_RESULT is_error=True | "PROBE-DENY-MARKER: the operator did not confirm in
    time — propose it again"

Verbatim — no CLI boilerplate wrapped around it, no substitution. The call also appeared
in the final result frame's `permission_denials` array, with its `tool_name`,
`tool_use_id` and full `tool_input`.

**This is the finding that decided the architecture.** It means a refusal issued from this
layer can carry Wakil's own vocabulary — including `ConfirmationDecision`'s deliberate
split between `.cancelled` and `.expired` — rather than being flattened into whatever
wording the CLI would choose. Which in turn means the design does *not* have to move the
confirmation gate up into the prompt tool in order to keep that vocabulary, because
`tools/call`'s own JSON-RPC errors already reach the agent intact. The two candidate
architectures were separated by exactly this, and it turned out not to separate them.

## 5. `updatedInput` replaces the arguments wholesale

Scenario 3, `probe_approve` answering `allow` with `confirmation: "confirm"` added to the
input it echoed. The real call arrived as:

    REAL CALL ARGS: {"statement": "UPDATE t SET x=1", "database": "staging",
                     "confirmation": "confirm"}

So a permission tool can rewrite the call it approves, and the agent is never told.

**Two consequences, and they point in opposite directions.** The bridge must echo `input`
back *verbatim* on allow — anything rebuilt could differ from what the agent asked for,
which is the same reasoning `parkForConfirmation` already gives for re-dispatching
`arguments` unchanged rather than reconstructing them from the parked projection.

And the injection route this opens is closed by an existing decision rather than by luck:
`handleToolsCall` reads `confirmation` as a sibling of `name`/`arguments`, never from
inside `arguments`, precisely so that no MCP client can send one (Invariant 7 — *"voice
may propose a mutation; only typed confirmation may execute one"*). `updatedInput` lands
*inside* `arguments`, so it cannot reach that field. The sibling placement was chosen in
2b-iii against a threat model that did not include this one, and holds against it anyway.
Worth stating explicitly so a later refactor does not "tidy" `confirmation` into the
arguments object and quietly open the route.

## 6. An allow-listed tool never reaches the prompt tool

Scenario 4 — `--allowedTools=mcp__probe__probe_read`, prompt tool answering `deny`. The
log shows one `tools/call`, for `probe_read` itself. The prompt tool was never consulted
and the read ran.

So `--allowedTools` keeps its job unchanged and the prompt tool sees only the residue.
That is a performance argument as much as a design one: routing every read through a
prompt tool would add a round trip per call to the multi-step spoken command that is the
Phase 2 exit criterion.

*(Recorded in passing, because it cost a scenario: `--allowedTools` is variadic, so the
space-separated form swallowed the prompt argument that followed it and `claude` exited
with "Input must be provided either through stdin or as a prompt argument when using
--print". `buildLaunch`'s doc comment already warns about this and uses the
comma-separated single-argument form; the probe's first attempt did not, and reproduced
the failure that comment predicts.)*

## 7. Built-in tools route here too — and this is the widening to guard

Scenario 8 asked for a file to be written, prompt tool answering `deny`. Two prompt calls
arrived, both with a **bare** `tool_name`:

    {"tool_name": "Write", "input": {"file_path": "/tmp/wakil-probe-should-not-exist.txt",
                                     "content": "x\n"}, "tool_use_id": "toolu_01FF2…"}
    {"tool_name": "Bash",  "input": {"command": "ls -l /tmp/wakil-probe-should-not-exist.txt …",
                                     "description": "Check whether the target file exists"},
                           "tool_use_id": "toolu_01NDh…"}

Both were denied and the file was never created.

But scenario 6 asked for `echo hi` and the prompt tool was **never called** — no entry in
the log, and `permission_denials` was empty. Scenario 11 went further without being asked
to: on its way to the tool it had been told to call, the agent ran `grep -rl` through this
repository and `Read` this very file, and neither reached the prompt tool either. The
config dir has no `permissions` block, so all three are the CLI's own policy auto-allowing
read-only work before anyone is asked.

**So the prompt tool is consulted for what CLI policy does not already settle, and that
set is a subset of the built-ins, not all of them.** Stated precisely, because the
imprecise version is tempting and wrong:

- Built-ins that would prompt — `Write`, a non-trivial `Bash` — reach the prompt tool and
  can be denied.
- Built-ins the CLI's policy auto-allows — a read of a file **inside the session's
  working directory**, a trivial `Bash` — never reach it and **cannot be denied there at
  all**.

> **Narrowed 2026-09-10 by a second probe. The rule is path scope, and this section
> originally overstated it.** As first written, the second bullet read *"`Read`, `Glob`, a
> trivial or read-only `Bash`"* with no qualification, and the bridge's acceptance run
> contradicted it: a `Read` of `/tmp/x` **did** reach the prompt tool and was refused in
> Wakil's own wording. Re-measured directly, same tool, two paths, one session, `claude`
> 2.1.266, `.context/probe-read-scope/` (throwaway):
>
> | Call | Reached the prompt tool? | Outcome |
> |---|---|---|
> | `Read` `./inside.txt` (in cwd) | **no** | auto-allowed, contents returned |
> | `Read` `/tmp/wakil-probe-outside.txt` | **yes** | denied in Wakil's words |
> | `Bash` `cat inside.txt` | **no** | auto-allowed, contents returned |
> | `Bash` `cat /tmp/wakil-probe-outside.txt` | **yes** | denied in Wakil's words |
>
> Each run's `permission_denials` carried exactly the one outside-cwd call, and the prompt
> server's log carried exactly one line. So the auto-allowed set is **narrower** than this
> section claimed and the bridge's reach is **wider**: the CLI's own policy settles
> read-only work inside the working directory and asks about everything else, including
> the identical tool pointed one directory over. Being wrong in the safer direction is
> still being wrong, and three documents were repeating it.
>
> **`Glob` is struck rather than corrected, because it could not be measured.** It is not
> in 2.1.266's session tool list at all, and `ToolSearch select:Glob` reports no such
> deferred tool. The original claim about it was never measured either; it was carried
> alongside `Read` by inference. Nothing should be asserted about it until it exists.

The second half is not a regression this work introduces. It is true of Wakil *today*: a
tool that never needs permission never needs an approval surface, so the agent in a
current Wakil session can already read files in its working directory. Nothing here
changes that, and a bridge cannot change it either — it is not asked.

What the bridge does change is the first half. Today those prompting built-ins are
auto-denied for want of an approval surface; naming a prompt tool makes Wakil the
answerer. A bridge that allowed by default would silently *remove* that restriction while
appearing to add one. The default branch of the decision function is the whole defence,
and it defends exactly the calls it is asked about.

## 8. The prompt tool must be advertised in `tools/list`

Scenario 9 served a `tools/list` omitting `probe_approve` while still answering
`tools/call` for it. The CLI refused at the first permission check:

    Error: MCP tool mcp__probe__probe_approve (passed via --permission-prompt-tool)
    not found. Available MCP tools: mcp__probe__probe_write, mcp__probe__probe_read

and the same text reached the agent inside a `<tool_use_error>`.

So the tool cannot be hidden. The agent will see it in `tools/list` and can call it
directly. Under the chosen architecture that is harmless — the bridge is a pure function
of `tool_name` returning text, and the CLI is not listening to a call the agent made
itself — but it is a property to document rather than discover.

## 9. A 130-second park survives

Scenario 7 — prompt tool sleeping 130s before answering `allow`. The log shows the call
at t=11.4s and the answer at t=141.4s; the real `tools/call` followed immediately and the
agent received the genuine result. Total turn 144s. No CLI-side timeout, no
`notifications/cancelled`.

`ConfirmationBroker.defaultTimeout` is 120s, so the broker's own expiry fires with room to
spare and is the only clock that matters.

## 10. An ordinary tool call survives 130s too — which downgrades a recorded risk

Scenario 10 held `probe_write` itself for 130s, with the prompt tool answering
immediately. Same outcome: answer at t=133.6s, agent received the real result, turn 136s.

`parkForConfirmation`'s doc comment records a residual risk in these terms:

> The park can hold this request open for up to the broker's timeout (120s by default),
> and `Connection.consume` awaits each `handle` call to completion before reading the
> connection's next frame — so a `notifications/cancelled` the CLI sends after its own
> tool-call timeout cannot even be read until this one resolves.

At 130s there is no such timeout and no such notification, so the scenario the comment
guards against does not occur within the window the broker can hold. This is a bound, not
a proof of absence: nothing here measured 10 minutes, and nothing here says the CLI has no
tool-call timeout at all — only that it is longer than the broker's. The risk is narrowed
rather than closed, and it is evidence about code that already shipped rather than about
the bridge.

## 11. A non-empty allow list that excludes the prompt tool still reaches it

Scenario 11 is Wakil's actual shape, and every earlier scenario had missed it: scenario 1
ran with *no* allow list at all, and scenario 4's allow list covered the tool being
called, so the prompt tool was never needed. Neither answered the question Wakil depends
on — *does the designated prompt tool have to appear in its own `--allowedTools`?*

With `--allowedTools=mcp__probe__probe_read` and `probe_approve` absent from it, a call to
`probe_write` produced both round trips in order and the write ran.

So **`approve_tool_use` must not be added to `agentAllowedTools`**. The CLI reaches its
designated prompt tool regardless, and putting it on the allow list would only give the
agent a silent route to call it directly (§8), buying nothing.

---

## What the probe changed about the plan

1. **The architecture question was answered by §4, not by argument.** Parking the
   confirmation inside the prompt tool would have needed a one-shot approval token in the
   broker to stop the follow-on `tools/call` raising a second plane. §4 shows the reason
   to want that — carrying Wakil's refusal vocabulary through the CLI layer — is already
   satisfied by the errors `tools/call` returns today. The token, and the second gate it
   implies, are not built.
2. **§7 turned the bridge from a widening into a gate.** Without that scenario the
   decision function's default branch would plausibly have been written to allow, on the
   grounds that the CLI had already made its own checks.
3. **§5 promoted "echo `input` verbatim" from an obvious choice to a stated rule**, and
   attached a reason to `confirmation`'s placement that a later refactor now has to
   answer before moving it.
4. **§10 is a finding about existing code**, unrelated to the bridge, and belongs in
   whatever revisits `parkForConfirmation` next.
5. **§11 was added after the spec's first draft**, when writing the implementation plan
   surfaced that no scenario had yet run the configuration Wakil actually launches with.
   Had it gone unmeasured, the plan would have carried a coin-flip: add the prompt tool to
   the allow list and open a silent route to it, or leave it off and risk the CLI refusing
   to reach it.
6. **§7 was rewritten after §11 was run**, because scenario 11 showed the agent reading
   files without the prompt tool being consulted. The first draft claimed the bridge
   denies built-ins; it denies the built-ins it is *asked* about, and the CLI settles the
   read-only ones before asking. The corrected claim is narrower and is what the spec now
   says.
