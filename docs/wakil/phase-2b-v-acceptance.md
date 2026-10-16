# Phase 2b-v acceptance — session resume

**Status:** **MET 2026-09-10 — accepted without an acceptance run.** None of the ten checks in §2 was ever walked; the sub-phase was marked met by the operator on their own authority, and that was **re-affirmed on 2026-09-15** when the operator accepted the whole outstanding runbook backlog (`phase-log.md`, "The 2026-09-15 acceptance"). **If you ever come back to one check here, make it check 10** — a resume of a session that is open in a second terminal at the same time. It is the only check in the entire backlog that no script driving `Wakil.app` could have run, and `session-resume-probe.md` §9 measured that exact scenario going wrong. Read §4 before relying on any row here · **Spec:** `docs/superpowers/specs/2026-09-10-phase-2b-v-session-resume-design.md`
· **Probe:** `docs/wakil/session-resume-probe.md` · **CLI pinned at:** `claude` 2.1.266

2b-ii's lesson, recorded in `north-star.md` §8, is that a sub-phase whose value is a
human judgement gets marked "implemented" and then treated as met. Every check below is
numbered for that reason. **"The code is written" and "the phase is done" are different
claims, and only this runbook closes the second one.**

## 0. Why the ten checks below cannot be run by a machine

`north-star.md` §8 gives 2b-v one exit criterion: *"⌘P lists this org's past sessions and
picking one continues it, with its thought thread rebuilt — a resume the operator can
see, not a flag."* Every headless test this sub-phase added — the transcript reader
against fixtures, the two argv shapes and the refusal when neither is `--resume`, the
lineage store's round trip, both refusals in §7 of the spec, the reply-before-swap
ordering — proves the mechanism is wired correctly. None of it can answer the actual
question, which is a judgement, not a fact: does picking a session in ⌘P feel like
continuing a conversation, or like starting a new one that happens to remember some
words? The spec's own §11 draws this line explicitly: *"whether a rebuilt thread reads
as the same conversation continued, whether the seam reads as a seam rather than as an
error, and whether a collapsed chain in ⌘P reads as one session"* are named there as
exactly what no test in this repository covers. This runbook is where that gets
answered, once, by a human, and dated.

**What "implemented" already covers, so this runbook does not re-argue it.** All 26
tests this sub-phase added are green (see §3), including the two argv shapes never
appearing without both `--fork-session` and `--session-id`, the lineage store's
round-trip with an absent store and a parentless child, and both refusals (wrong
provider, cwd no longer a project root) at the unit level. That is the code being
written. It is not the sub-phase being done.

## 1. Prerequisites

Every check below needs all of these in place before you start. Skipping one does not
make a check fail cleanly — it makes it fail for the wrong reason, which is worse than
not running it.

1. **`make build`.** `bin/` is per-worktree, and both the Swift suite (16 tests, per
   `phase-2b-iv-acceptance.md` H3) and the running app shell out to `bin/wakil-ctx` for
   every context, session and lineage operation this sub-phase touches. A worktree that
   has never run `make build` will fail checks 1 through 9 below for want of a binary,
   not for want of the feature working.
2. **A project whose first root is real** — an existing, readable directory on this
   machine, registered as `roots[0]` in that project's `project.json`. §5.1 of the spec
   runs every fresh session in the project's first declared root; if that path does not
   exist, the fresh session used to seed checks 2–10 below never starts.
3. **`WAKIL_PROVIDER` set** at launch, to the id of a real, registered Claude Code
   provider under the active org (`wakil provider list --org <org>`). §7 of the spec
   refuses a resume whose session belongs to a different provider than the one the
   window is running — check 8 depends on this being a real, checkable value, not an
   empty string.
4. **At least two past sessions filed under that project's first root** — one launched
   by Wakil itself, one typed by hand into a `claude` terminal session run from that
   same directory. Checks 1 and 7 need the Wakil-made one; checks 4, 5, 6 and 9 can use
   either; check 10 needs the hand-typed one still resumable from its own terminal at
   the same time as ⌘P resumes it.
5. **A second provider registered under the same org, with at least one session on
   record under it** — for check 8. Two accounts already exist for this on the machine
   this was written on (`personal`'s `main` and a second registered provider; confirm
   with `wakil provider list --org personal`); any two will do, as long as a session
   exists under the one the window is *not* running as.
6. **The launch command**, per `phase-2a-acceptance.md` §1, with the provider from (3):

   ```bash
   WAKIL_ORG=<org> \
   WAKIL_PROVIDER=<provider id from step 3> \
   WAKIL_CLAUDE_PATH="$(command -v claude)" \
   CLAUDE_CONFIG_DIR="<that provider's config dir>" \
   CLAUDE_CODE_OAUTH_TOKEN='<the token for that account>' \
   app/Wakil.app/Contents/MacOS/Wakil
   ```

   `make app-bundle` first, same reason as every other 2b runbook: the bundle is what
   carries `wakil-ctx` and the rest into `Contents/Resources`, and `WakilWiring.binaryURL`
   has no fallback once running from one.

## 2. The ten standing checks

**None of the ten was ever walked.** On 2026-09-10 the operator marked
this sub-phase met without running the runbook, so every result row reads **ACCEPTED — not
walked**: a record of a decision, not of an observation. No ⌘P list was opened, no thread
was rebuilt, no seam was looked at. Walking them still needs a running window, a real
`claude` binary and a live agent turn — none of which the automated suite is permitted to
touch — and the checks are left here unmodified for whoever wants the evidence later.

**Check 10 is the one to be most careful about having skipped.** It asks whether resuming
a session that is open in a terminal at the same time leaves both proceeding with separate
transcripts — the exact scenario `session-resume-probe.md` §9 measured going wrong under
continue-in-place, where two writers scrambled one transcript with *no error from the
CLI*. Forking instead of continuing is the designed fix and its unit tests are green, but
the two-writer scenario itself has never been reproduced against the shipped build.

### Check 1 — the list is not empty

**⌘P shows sessions Wakil itself created.**

This is the cheapest proof in the whole sub-phase, and the reason is worth spelling
out rather than leaving implicit. Before this work, `ClaudeCodeCLIHarness` never set
`Process.currentDirectoryURL`, so every `claude` process Wakil launched inherited
**Wakil.app's own working directory** — not the project's, not any root the operator
declared — and its transcript was filed under that inherited directory's encoded form.
`ListSessions` filters candidates by `firstCwd` against the *active project's roots*
(`sessions.go:357-373`), so a transcript filed under the launcher's own directory is a
confirmed non-match for every project and drops out of the listing silently. Measured on
this machine (`session-resume-probe.md` §8): three transcripts across two worktree
directories carried `mcp__wakil__` calls — proof Wakil launched them — and the
*registered* project root held four transcripts of which **none** came from Wakil. So
before this sub-phase, ⌘P's session list could show only sessions the operator had
typed by hand inside the project directory; a session Wakil itself started was
structurally unfindable, regardless of how correct everything else about the resume
path was.

A pass here means: open ⌘P, and at least one entry corresponds to a session this same
Wakil window (or an earlier one, run from this same project) actually launched — check
its id or timestamp against what you saw run. A failure here means the cwd fix
regressed, or the project's first root is not what you think it is; do not proceed to
checks 2–10 until this one passes, because every later check resumes something from
this same list.

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 2 — titles read as titles

**Entries are recognisable without opening them.**

§4.2 of the spec makes a session's ⌘P label the transcript's last `ai-title` record
(rewritten by the CLI as the conversation proceeds, last one winning) rather than the
first 200 runes of whatever the operator happened to type — falling back to
`firstPrompt` only when a session has no `ai-title` at all. Look at the list without
opening any entry: does each label read as a description of what that conversation was
about, or as a truncated fragment of a prompt? Both the Wakil-launched and the
hand-typed session from the prerequisites should be checkable here.

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 3 — one entry per conversation

**Resume the same session twice; ⌘P still shows one entry for it, not three.**

Every resume is a fork (§3 of the spec): the CLI mints a new transcript per resume, so
without Wakil's own lineage store, resuming one session twice would leave three
unrelated-looking entries in ⌘P with nothing to show they are one conversation. The
lineage store (`~/.wakil/orgs/<org>/sessions.json`) is what `ListSessions` joins in to
collapse a chain of forks back into one entry. Resume a session, then resume the child
that resulted. ⌘P should still show one row for the whole chain, not a growing list of
near-identical ones.

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 4 — continuity, by asking

**Resume a session and ask it something only that conversation knows.**

Pick a session where you know what was discussed, resume it, and ask a question whose
answer depends on that earlier context — a detail you gave it, a name it used, a
decision it made. Judge the *answer*, not the absence of an error: an agent that
resumes cleanly at the transport level but has lost the thread of the conversation
would still pass every headless test in §3 and still fail this check.

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 5 — the thread reads as continued

**Does the rebuilt thread read as the same conversation, and does the seam read as a
seam rather than as an error?**

On a successful resume, `thoughts` is replaced wholesale by up to 200 rebuilt rows
(oldest-first, `user` entries included — the one kind a *live* thread never draws,
because per §4.1 of the spec the operator's own prompt live is something they typed a
second ago, and read back a day later that reasoning inverts) followed by one seam row:
label `"resumed"`, detail `"resumed from <parent id>"` (plus `" (earlier turns not
shown)"` if the 200-row cap actually truncated something), rendered with `isError:
false`. `ThoughtThread` shows only the last six rows and does not scroll
(`design-language.md` §9), so immediately after a resume you should see the seam and
the five rows before it, with live rows pushing them out as the new turn proceeds. Judge
by eye: does the seam read as a labelled boundary — "here is where history ends and the
live conversation resumes" — or does it read as a fault, the way an error row would?

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 6 — the parent is untouched

**After resuming, the original transcript has gained no records. Check on disk, not in
the window.**

Every resume is a fork by construction (§3 of the spec, decided by probe §9's finding
that two concurrent writers scramble one transcript with no error from the CLI), so the
parent's `.jsonl` file should be provably unmodified. Before resuming, record the
parent transcript's line count and modification time (`wc -l <path>`,
`stat -f %m <path>`); resume it, have a full turn, then check both again. Checking the
window is not sufficient here — the window only ever shows the child's rebuilt thread,
so a bug that silently appended to the parent would be invisible from the UI and visible
only on disk.

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 7 — a live agent resumes

**Ask the agent to resume a session by name. It should answer before it disappears, and
the new session should be the one that continues.**

`session_resume` is `.control`, not `.mutate` (§8 of the spec — the write it performs
never leaves Wakil's own process), so it is on the agent's allow list automatically.
Ask the live agent, in conversation, to resume a named past session. The handler
returns `{"resuming": "<id>", "note": "this session ends as the fork starts"}`
*synchronously*, before the swap happens on the window's next main-actor turn — this
is deliberate, because the shim's socket dies with the `claude` process the swap tears
down, so a reply sent after the swap could never arrive. Confirm both halves: the agent
receives and can report that answer, and the session that continues afterward is
genuinely the resumed one (ask it something only the parent conversation would know, as
in check 4).

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 8 — the provider refusal

**Try to resume a session belonging to another provider. The refusal should name
both.**

Using the second provider from the prerequisites, resume a session recorded under it
while the window is running as the first. The refusal lands in `status` (there is
nowhere else for a SwiftUI control to throw to) and reads: `"resume <parent>: that
session belongs to provider <thread.provider>, and this window is running
<providerId>"`. Confirm the message actually names both providers by their real ids, not
a placeholder — this is the scope boundary the spec draws between 2b-v and 2b-vi, and
2b-vi's job is to remove this refusal, not soften its wording.

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 9 — the write gate still gates

**Propose a mutation *in a resumed session*.**

`permission-prompt-acceptance.md` measured the bridge surviving a resume — the MCP
config, the allow list and `--permission-prompt-tool` all take effect on a resumed
`claude` process with no resume-specific code (§4 of the spec, and probe §4's
measurement). This check is the same claim, judged by eye at the plane rather than in a
probe log: resume a session, then ask the agent to do something that requires
confirmation (a database write, per `phase-2b-iii-acceptance.md`'s checks). The
confirmation plane should appear exactly as it does in a fresh session — same wording,
same gate, same journal entries — because nothing about the write gate has a resume
variant to fail differently in.

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

### Check 10 — nothing scrambles

**Resume a session that is open in a terminal at the same time. Both should proceed,
and the two transcripts should be separate files.**

This is the check the fork-vs-continue decision (§3 of the spec) exists to make safe.
Probe §9 measured that two concurrent `claude` processes writing to *one* transcript
neither error nor stay coherent — the file stays valid JSON and the conversation stops
making sense, with turns interleaved out of order. Forking makes this structurally
unreachable *for Wakil's own resumes*, because a resume always mints a fresh child
transcript rather than writing into the parent. Confirm it rather than trust the
argument: open a `claude` session in a terminal by hand, resume that same session from
⌘P while the terminal session is still open, and do something in both. Both should
proceed without error, and `ls` against the transcript store afterward should show two
files — the terminal session's original transcript, untouched (check 6 covers this
directly), and a new one for the fork — never one file racing two writers.

| Result | | |
|---|---|---|
| **ACCEPTED — not walked** | 2026-09-10 | Marked met on the operator's authority. This check was never run; no result was observed. |

## 3. Headless checks

Everything below is scriptable, and none of it substitutes for §2. Run these first —
they are cheap, and a failure here means the standing checks above cannot mean anything
either.

```bash
go test ./...
```

Expected: every package `ok`.

```bash
make app-test
```

Expected: **381 tests pass, reported as two consecutive `swift test` invocations — "380
tests in 1 suite" then "1 test in 1 suite".** `phase-2b-iii-acceptance.md` H2 measured
319 at that sub-phase's acceptance write-up, before the permission-prompt bridge and
this sub-phase's own plan (26 tests, plus 3 more added by the fix wave that closed the
final whole-branch review) both added to the suite; 381 is what `make app-test` reports
on this tree today, measured directly rather than reconstructed by addition.

**Why two invocations, and why that is not a weaker suite.** One pre-existing test,
`stopDeliversTheTailOfTheStreamRatherThanDiscardingIt`
(`ClaudeCodeCLIHarnessTests.swift`), measures a real-time budget: 3000 of 3000 frames
delivered against `Engine.stdoutDrainDeadlineNanoseconds`' 2-second production deadline.
This sub-phase's 26 new tests were enough additional parallel load to make it lose that
race — it failed 3 runs out of 3 under the full suite while passing standalone in 4.7
seconds. `@Suite(.serialized)` alone did not fix it: measured directly, the suite still
delivered only 1018 of 3000 frames under full-suite load, because a serialized suite
only serialises its own children relative to each other, and Swift Testing still ran it
concurrently with the other ~377 tests regardless. The fix that actually works runs it
in a second, separate `swift test` process with nothing else scheduled — `scripts/swift-test.sh`
now does this automatically for a default, unfiltered `make app-test` — rather than
loosening the 3000-of-3000 assertion or the 2-second deadline, either of which would
have weakened the regression guard for a bug that once discarded 60–85% of a session's
events silently. Verified by running `make app-test` three consecutive times: PASS, PASS,
PASS, and 381 of 381 on the tree as it stands.

```bash
printf '%s\n' '{"action":"session_resume","params":{"id":"<a known session id>"}}' \
    > /tmp/wakil-check-resume.jsonl
WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check-resume.jsonl
echo "exit=$?"
```

Expected: exit `0`, and the printed line reports
`{"resuming":"<a known session id>","note":"this session ends as the fork starts"}`.

**What this does and does not prove.** `--dispatch` builds `WakilWiring.registry`
directly (`WakilApp/main.swift`, `runDispatchFile`) rather than a full `WindowModel`, so
the `ResumeBroker` this action posts to has no subscriber — per its own doc comment
(`ResumeBroker.swift`), a request with no subscriber is buffered, not dropped and not
acted on, and the buffer is only ever drained by the one window that calls
`requests()` in its initialiser. So this check proves the `.control` action is
registered and answers synchronously with the reply-before-swap contract §8 of the
spec describes — it does **not** and cannot exercise the actual harness swap, the
rebuilt thread, or a lineage write, because nothing in `--dispatch` mode ever drains the
broker to perform them. Checks 3, 5 and 7 in §2 are what that swap actually needs.

```bash
printf '%s\n' '{"action":"session_record_parent","params":{"child":"<fresh uuid>","parent":"<a known session id>"}}' \
    > /tmp/wakil-check-lineage.jsonl
WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check-lineage.jsonl
echo "exit=$?"
jq --arg c "<fresh uuid>" '.[$c]' ~/.wakil/orgs/<org>/sessions.json
```

Expected: exit `0`, and the `jq` line prints `"<a known session id>"` — the lineage
store's write path, exercised headlessly and independently of the harness swap, exactly
as spec §4.3 intends ("Written by `wakil-ctx` on behalf of the app rather than by the
app directly, so the resume path is scriptable headlessly and the `--dispatch` runbook
can exercise it").

**Two warnings, same as every other `--dispatch` check in this repository.** This
writes to your real `~/.wakil/journal` and your real lineage store. Use a session id
you are prepared to see a throwaway lineage entry attached to, and do not reuse
`<fresh uuid>` for anything you care about tracking cleanly afterward.

---

## 4. Result

**MET 2026-09-10, by acceptance without an acceptance run.** The operator
marked this sub-phase met on their own authority. **None of the ten checks in §2 was
walked**, and every row there records that fact rather than a result.

What that does and does not establish:

- **Established.** Every headless check the spec's §11 lists is green — both `buildLaunch`
  argv shapes and the refusal when `--resume` appears without `--fork-session` and
  `--session-id`, the lineage store's round trip, both §7 refusals, the reply-before-swap
  ordering, and the registered-name set after `session_resume` became `session_get`.
  `make app-test` reported 378 tests passing on 2026-09-10, and **380 passing when re-run
  from the `lansing` worktree on 2026-09-10** after this document was updated. The cwd
  defect fix is real and
  measured: `ClaudeCodeCLIHarness` now sets `Process.currentDirectoryURL`, and
  `session-resume-probe.md` §8 measured the failure it repairs.
- **Not established.** Whether a rebuilt thread reads as the same conversation continued,
  whether the seam reads as a seam rather than as an error, and whether a live agent's own
  resume request is honoured before it disappears. These are what the sub-phase is for.
- **Not established, and cheapest of all.** Check 1 — that ⌘P now lists a session Wakil
  itself created. Before the cwd fix, all three Wakil-launched transcripts on this machine
  sat under worktree directories while the registered project root held four transcripts
  of which none came from Wakil, so ⌘P could not list a single Wakil-created session. That
  the fix works end to end in the running app is inferred from the unit tests, not observed.

The checks stay in the document, unmodified. The honest answer to "was session resume ever
verified in the app?" is no.
