# The permission-prompt bridge — acceptance

**Status:** **WALKED 2026-09-10 — all six checks pass** · **Spec:** `docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`
· **Probe:** `docs/wakil/permission-prompt-probe.md` · **CLI pinned at:** `claude` 2.1.266

Every check here needs a running `Wakil.app`, a real `claude` binary, and a live agent
turn. None of them can be run headlessly, which is why they are here and not in
`PermissionPromptTests`.

**What this work makes runnable is `phase-2b-iii-acceptance.md` §2 check 3b** — the
`.mutate` half of the live agent turn, owed since 2026-09-08 and unreachable until now
because no `--permission-prompt-tool` existed for an agent to be offered a confirmation
through. 2a's acceptance checks 5 and 6 (the write gate and the production block, driven
from the UI and `--dispatch`) have been runnable by hand since 2026-09-09 and are **not**
what this retires — check 3 below is where that mutation's production form finally
reaches a live agent, which no check anywhere has done before.

## Before you start

Record the CLI version: `claude --version`. The spec's §13 accepts one risk — the flag is
undocumented in `--help` — and its mitigation is that this line is written down. If the
version differs from 2.1.266, say so in the result and expect check 1 to be where a change
surfaces.

## The checks

| # | Check | Result |
|---|---|---|
| 1 | Ask the agent, out loud or by typing, to delete a row from a **staging** database. The confirmation plane appears. *(The live-agent half of `phase-2b-iii-acceptance.md` §2 check 3b, first time runnable.)* | **PASS** |
| 2 | Approve it. The row is gone, and the journal carries the `gated` → `ok` pair for one action. *(The approval half of the same check.)* | **PASS** |
| 3 | With the active environment set to **production**, ask the agent to delete a row. It is refused outright: the journal outcome is `"blocked"`, never `"gated"`, and confirming does not help because no confirmation is offered. | **PASS** |
| 4 | Ask again (non-production), and **cancel**. The agent is told it needs confirmation — not that it timed out. | **PASS** |
| 5 | Ask again, and **walk away** for the broker's full 120 seconds. The agent is told the operator did not confirm in time, and the wording differs from check 4's. | **PASS** |
| 6 | Ask the agent to run a shell command that **writes or deletes** — for example, create or remove a file, not `ls` or `git status`. It is refused, and the refusal is Wakil's wording rather than the CLI's. | **PASS** |

## What each check is really asking

**1** is the whole sub-phase. Everything else is a variation on it. If the plane does not
appear, read the CLI's stderr first: probe §8 measured a name mismatch between the flag
and `tools/list` producing a clear error rather than a silent failure.

**2** is the only check that proves the *approved* path end to end through a live agent.
The headless test `MCPServerTests.anAgentProposedMutationParksAndRunsOnceApproved` covers
the same path with no CLI in it at all.

**3** is `writeGate`'s `.block` row reaching a live agent for the first time, and it is
the one check where a *pass* means nothing happened. The mutation must be refused before
any plane appears — `ActionRegistry.dispatch` never consults `confirmation` on a `.block`
path, so there is nothing to confirm and no plane to raise. A run that shows a
confirmation plane, or that journals `gated` instead of `blocked`, means production has
quietly become merely-gated and the second half of Invariant 8 has become the first half.

**4 and 5 are one check split in two, and the split is the point.**
`ConfirmationDecision` distinguishes `.cancelled` from `.expired` because *"an agent told
it was refused, when the truth is that nobody was at the keyboard, will go looking for a
permission to ask for instead of simply trying again."* That distinction has never reached
a real agent. Read what the agent says after each — if it reacts the same way to both, the
distinction is costing code and buying nothing, and that is worth knowing.

**6** is probe §7's widening, checked rather than argued. Naming a prompt tool made Wakil
the answerer for built-ins that would otherwise have been auto-denied. If the shell command
*runs*, the bridge's default branch is wrong and this is how you find out. This is why the
check must name a command that writes or deletes: a read-only one would run for a reason
that has nothing to do with the bridge (see below), and a pass for the wrong reason is
worse than no check at all.

**One thing check 6 cannot test.** Probe §7 and §11 measured `Read`, `Glob` and read-only
`Bash` being auto-allowed by CLI policy without the bridge being consulted at all. If you
ask the agent to read a file, or to run a read-only shell command such as `ls` or
`git status`, it will run, and the bridge is not what let it — the CLI settled the
question before the bridge was ever asked. That is true of Wakil today, is not changed by
this work, and is recorded in the spec's §12 as out of scope. Do not read a read-only
shell command succeeding as a failure of check 6; the check only means something for a
command that writes or deletes.

## Result

**Walked: 2026-09-10. By: the operator. CLI version: `claude` 2.1.266** — the pinned
version, so §13's undocumented-flag risk did not surface.

All six pass. Every outcome below was confirmed in `~/.wakil/journal/` and in the database
itself, not from the window alone — the screenshots show what the operator saw, the
journal shows what actually happened, and for checks 3 to 5 those are different questions.

| # | What the journal shows | What the data shows |
|---|---|---|
| 1 | `gated`, `origin: agent`, `DELETE FROM events WHERE id = 40` | plane appeared |
| 2 | `ok` on the same statement — the `gated` → `ok` pair | row 40 gone |
| 3 | `blocked`, `origin: agent`, `DELETE FROM events WHERE id = 50` | row 50 **survives** |
| 4 | a second `gated` with no `ok` | row 41 survives |
| 5 | a third `gated` with no `ok` | row 41 survives |
| 6 | nothing — the bridge is not an action and does not journal | `/tmp/does-not-exist-yet` never created |

**The `gated` → `ok` pair is the load-bearing evidence for check 2.** An agent has no way
to send a confirmation — `confirmation` is a sibling of `arguments` that no MCP client can
reach — so that pair on one statement can only mean a human typed `confirm`.

**Check 3 was run against a genuinely writable database, deliberately.** Production was
temporarily given an `events` record with a real `writeRef` and no `readOnly` flag,
pointed at the same SQLite file, with two throwaway rows in it. Nothing but `writeGate`
stood between the agent and the delete, so a failure would have shown up as a missing row
rather than as an assumption. The fixture was reverted immediately afterwards; production
defines only `core` again.

## What the run found that the checks did not ask about

**1. The agent refuses pre-emptively, and it made checks 3 and 6 unrunnable twice.**
Three separate turns ended with the agent explaining why a write could not succeed
*instead of attempting it*. Twice it was reasoning from `readOnly` (see 2); once it
reasoned correctly from the production rule and still never issued the call. A gate that
is never reached is indistinguishable, in the window, from a gate that refused — and the
journal was the only thing that told them apart. **Check 3 only ran once the operator
wrote "I know it may be refused — I want to see the refusal, so make the call rather than
deciding in advance."** Any future gate check needs that instruction in its script.

**2. `readOnly` is inert, advertised, and actively misleading — this is a defect.**
*Tracked as [#14](https://github.com/yehia-khalil/rafiq/issues/14).*
`config.go:60` says it plainly: *"ReadOnly is carried and NOT consulted."* But
`list_databases` publishes it to the agent while omitting `writeRef` entirely when unset
(`omitempty`), so the agent sees the field that decides nothing and cannot see the field
that decides everything. It derailed three turns. Either stop publishing it or make
`writeRef`'s absence explicit in the payload. Logged as its own bug; nothing in the
permission-prompt bridge caused it and nothing here fixes it.

**3. The journal does not record the environment.**
*Tracked as [#15](https://github.com/yehia-khalil/rafiq/issues/15).* A `blocked` entry implies production,
but a `gated` or `ok` entry does not say which environment the write actually hit. For a
record whose purpose is answering *what happened and under what conditions* after the
fact, that is a gap — the environment is the single input `writeGate` cares most about,
and it is the one thing the entry omits.

**4. Probe §7 understates the protection, and should be narrowed.**
*Tracked as [#16](https://github.com/yehia-khalil/rafiq/issues/16).* It records `Read` as
auto-allowed by CLI policy and never reaching the bridge. In this run `Read` on `/tmp/x`
**did** reach the bridge and was refused in Wakil's own words. The difference is almost
certainly the path: the probe read a file inside the session's working directory, and
`/tmp/x` is outside it. So the auto-allowed set is narrower than §7 claims, and the
bridge's reach is wider. Worth re-measuring before anyone relies on either statement.

**Re-measured 2026-09-10, and the path explanation is correct.** One session, one turn,
same tool, two paths, `claude` 2.1.266, against a throwaway prompt-tool logger:
`Read ./inside.txt` was auto-allowed and never reached the prompt tool; `Read /tmp/…`
reached it and was denied. A second run repeated it for `Bash`: `cat inside.txt`
auto-allowed and unseen, `cat /tmp/…` seen and denied. Each run's `permission_denials`
held exactly the one outside-cwd call. `Glob` could not be measured at all — it is not in
2.1.266's tool list — so its mention has been struck rather than narrowed. Probe §7, the
bridge spec's §5 and §12, `WindowModel`'s three-populations paragraph and
`permissionDecision`'s doc comment are corrected together. Issue #16 closed.

The re-measurement also surfaced something the issue did not ask about: a live agent read
the refusal — *"Wakil does not run Read"* — noticed it had just used `Read` successfully
one call earlier, and reported the message as misdescribing itself, *"a tool availability
rule rather than a scope rule"*. It is right, and the wording is staying anyway;
`permissionDecision`'s doc comment now records why.

**5. Checks 4 and 5 answered their question, and the answer is that the distinction
earns its keep.** The runbook asked whether a real agent reacts differently to
`.cancelled` and `.expired`. It does, exactly as `ConfirmationDecision`'s doc comment
predicted:

- *cancelled* → **"the mutation tool requires a human to confirm at the keyboard... Please
  confirm you want to run:"** — it turned to the operator.
- *expired* → **"The confirmation prompt timed out before it was approved. I've
  re-proposed the mutation"** — it simply tried again.

That is the behaviour the split was built for: *"an agent told it was refused, when the
truth is that nobody was at the keyboard, will go looking for a permission to ask for
instead of simply trying again."* Keep the distinction.

**6. Check 6 needed three attempts, and the reason is finding 1 in its sharpest form.**

Attempt one aimed at `/tmp/x`, which already existed (unrelated, four days old), so Claude
Code's read-before-write precondition fired *before* the permission layer and `Write`
never reached the bridge. What was refused was the agent's follow-up `Read` — a real
refusal in Wakil's wording, but of the wrong tool.

Attempt two used a path that did not exist. The agent declined **without calling
anything**: *"as established earlier, this session is restricted to Wakil's own tools."*
It had generalised from the first refusal. Within one session an agent that has been
refused once stops asking, so the bridge is never consulted and the check cannot run.

Attempt three used check 3's phrasing — *"I know it may be refused — I want to see the
refusal, so make the call rather than deciding in advance"* — and passed cleanly:

    TOOL         Write {"content":"","file_path":"/tmp/does-not-exist-yet"}
    TOOL RESULT  Wakil does not run Write. This session's agent may call Wakil's own
                 actions and nothing else — use one of those, or ask the operator to
                 do it in the Wakil window.

That string is `MCP/PermissionPrompt.swift:67-69` character for character, so the full
chain is proven live in one turn: the CLI asked the bridge about a built-in,
`permissionDecision`'s **default branch** denied it, and the message reached the agent
verbatim — probe §4's verbatim-delivery finding and §7's widening guard together. The
file was never created.

**The instruction is not a workaround, it is part of the check.** Any future runbook that
wants to observe a refusal must tell the agent to make the call anyway; otherwise the
agent's own caution, or its memory of an earlier refusal, silently substitutes for the
gate.
