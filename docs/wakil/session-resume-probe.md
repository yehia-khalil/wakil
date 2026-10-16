# The session-resume probe

**Run:** 2026-09-10 · **Machine:** MacBook Air M3 (`Mac15,12`), macOS 26.6.2 ·
**CLI:** `claude` 2.1.266 · **Account:** `personal` (`~/.claude-personal`, `firstParty`) ·
**Probe:** `.context/probe-session-resume/`, throwaway, gitignored ·
**Throwaway project roots:** `~/wakil-resume-probe`, `~/wakil-resume-probe-other`

Run before writing 2b-v's spec, for the reason the 2a, 2b, void-as-core and
permission-prompt probes were run before theirs: to stop a spec being written against
assumptions about a CLI this repo does not own.

`north-star.md` §8 gives 2b-v one exit criterion — *"⌘P lists this org's past sessions and
picking one continues it, with its thought thread rebuilt — a resume the operator can see,
not a flag"*. Five things stood between that sentence and a spec, and none of them was
answerable from `--help`. All five are answered below, plus three findings the probe was
not looking for: a live defect in shipped code (§8), the failure mode that decides the
spec's first design decision (§9), and a closed door (§7).

The probe was a Python stdio MCP server logging every inbound frame, exposing
`probe_read` (on `--allowedTools`), `probe_write` (off it, so it must reach the prompt
tool) and `probe_approve` (the `--permission-prompt-tool` target) — the same shape
`permission-prompt-probe.md` used, so the two runs are comparable. Twelve scenarios, all
against the real binary, driven through Wakil's own argv shape: `-p`,
`--input-format stream-json`, `--output-format stream-json`, `--verbose`,
`--include-partial-messages`, `--mcp-config`, `--strict-mcp-config`,
`--permission-prompt-tool`, `--allowedTools`.

---

## 1. `--resume` works under `-p --input-format stream-json`, and keeps the id

Scenario 1 started a session under a Wakil-minted `--session-id` and taught it a codeword.
Scenario 2 relaunched with `--resume <that id>` and asked for the codeword back. It came
back. The `system/init` event of the resumed run reported **the same `session_id`**, and
the `result` event did too.

So resume is not a mode with its own transport quirks: the resumed session is the same
session, on the same stream shape, and every event carries the id Wakil already knows.

## 2. `--resume` and `--session-id` are mutually exclusive — unless you fork

Scenario 3 passed both. The CLI refused at startup, before any turn:

    Error: --session-id can only be used with --continue or --resume if --fork-session is also specified.

That single sentence is the whole shape of the decision 2b-v has to make, because it means
there are exactly two ways to re-enter a session and no third:

| | argv | resulting id | transcript |
|---|---|---|---|
| **Continue in place** | `--resume <old>` | the old id, unchanged | appended to the old file |
| **Fork** | `--resume <old> --fork-session [--session-id <new>]` | a new id — the CLI mints one, or Wakil supplies it | a **new** file holding a full copy of the history |

Scenario 4 forked without `--session-id` and the CLI minted `4eb08eac-…`; scenario 5
forked with an explicit one and got exactly the id it was given. Both remembered the
codeword.

**Fork copies rather than references.** The forked transcript held all three turns of
history as its own records — 31 lines, self-contained — and no field anywhere in it named
the session it came from (`forkedFrom`, `parentSessionId`, `sourceSessionId` were all
absent). The parent was left untouched: it never gained the fork's turn.

That cuts both ways, and the spec has to choose deliberately:

- **In favour of fork.** Charter open question 5 is closed on *"always start fresh — a new
  `--session-id` UUID per launch, ... because Wakil assigns the id, the resume list is
  authoritative rather than reconstructed by scanning directories."* Forking preserves that
  property exactly: Wakil still mints the id of every session it runs. The journal, the
  MCP socket path and `WindowSession`'s whole identity are keyed on that id
  (`WindowSession.start()`), and a fork means none of that keying has to learn about
  borrowed ids. The old transcript also becomes immutable — a resumed session can never
  corrupt the thing ⌘P listed.
- **Against fork.** Resuming twice from one session yields two unrelated-looking
  transcripts with no recorded lineage, so ⌘P's list grows a copy per resume and cannot
  show that any of them are the same conversation. Continuing in place keeps one session
  per conversation, which is what an operator means by "the session I was in yesterday".

## 3. Nothing is replayed on stdout — the thread must be rebuilt from the transcript

The resumed run in scenario 2 emitted `system/init`, `system/status`, then the
`stream_event`s and `assistant` message of **the new turn only**. Not one `user` or
`assistant` event for any prior turn crossed stdout.

`--replay-user-messages` does not help: its help text is *"Re-emit user messages from
stdin back on stdout for acknowledgment"* — stdin, not history.

So *"with its thought thread rebuilt"* cannot be satisfied by listening. It has to be
read off disk, and by Invariant 10 that read belongs in the capability layer — a new
`wakil-ctx` tool, not `FileManager` in Swift.

**The transcript has everything the thread needs.** A real Wakil-launched transcript
(`…-wakil-castries/2CFDBAF1-….jsonl`, 56 assistant and 31 user records) decomposes into
exactly the content blocks `thoughtRow` already maps: 22 `text`, 21 `thinking`, 22
`tool_use`, 22 `tool_result`. The `user`/`assistant` records carry `message` in Anthropic
wire format plus `cwd`, `gitBranch`, `timestamp`, `uuid` and `parentUuid`.

**And one thing the thread could use that Wakil does not currently read.** Transcripts
carry `{"type":"ai-title","aiTitle":"…"}` records — a CLI-generated title for the
conversation, rewritten as it proceeds (six of them in that one session, the last winning).
`SessionMeta` today offers `FirstPrompt`, truncated to 200 runes; `aiTitle` is a better ⌘P
label than the first 200 characters of whatever the operator happened to type first.

Also present, and to be ignored deliberately rather than by accident: `attachment` (42
records in that session — the most numerous type after the messages themselves),
`queue-operation`, `atis-latch`, `last-prompt` and `mode`.

## 4. The MCP surface, the allow list and the write gate all survive a resume

Scenario 6 resumed with the full probe config and asked for both tools. Measured:

- `system/init` advertised `mcp__probe__probe_read` and `mcp__probe__probe_write`, and
  `mcp_servers` reported `probe` as `connected`.
- `probe_read` (on the allow list) ran without a prompt.
- `probe_write` (off it) reached `probe_approve` first. The probe server's frame log
  shows the ordering directly: `tools/call probe_read` → `tools/call probe_approve`
  (`tool_name: mcp__probe__probe_write`, the proposed input verbatim, a `tool_use_id`) →
  `tools/call probe_write`.
- `permission_denials` in the `result` event was empty.

So the bridge landed on 2026-09-10 is not a fresh-session-only mechanism, and 2b-v
inherits the write gate on resumed sessions with no further work. Nothing about
`agentAllowedTools`, `permissionDecision` or `--permission-prompt-tool` needs a resume
variant.

## 5. A session started outside Wakil can be resumed *into* Wakil, and gains its tools

Scenario 7 started a session with a bare `-p` launch — no `--mcp-config`, no allow list,
no prompt tool — and taught it a second codeword. Scenario 8 resumed **that** session with
Wakil's full config attached. The resumed session both remembered the codeword and called
`probe_read` successfully.

This is a capability the exit criterion does not ask for and gets for free: ⌘P can offer
sessions the operator started by hand in a terminal, and picking one hands it Wakil's
whole tool surface from that turn onward. It is worth stating in the spec as supported
rather than leaving it to be discovered, because it changes what the list is *for*.

## 6. Resume is cheaper than a fresh start, not dearer

The worry going in was that a resumed session re-sends its history and so the first turn
after a resume would be slow or expensive. The opposite is true on the measured cases,
because history arrives as cache reads rather than cache writes.

| Scenario | cost (USD) | duration | cache created | cache read | out |
|---|---|---|---|---|---|
| 1 — fresh, one turn | 0.04159 | 2.08 s | 9 147 | 19 872 | 4 |
| 2 — resume, one turn | 0.00661 | 2.06 s | 175 | 29 019 | 10 |
| 4 — fork, one turn | 0.00622 | 2.04 s | 69 | 29 194 | 10 |
| 5 — fork w/ explicit id | 0.00610 | 1.73 s | 55 | 29 194 | 4 |
| 7 — bare fresh | 0.04079 | 1.95 s | 8 990 | 18 953 | 4 |
| 8 — bare, resumed w/ MCP | 0.02369 | 5.61 s | 980 | 85 278 | 270 |

A resumed turn cost about a sixth of a fresh one. The fresh launch pays for writing the
system prompt and tool definitions into cache; the resumed launch reads them back.

**Do not over-read this.** These histories are two and three turns long. A session with a
day of work in it reads far more cached tokens (scenario 8's 85 278 against scenario 2's
29 019 shows the direction), and cached reads are cheap but not free. What the measurement
does retire is the specific fear that resume needs a cost warning in the UI before it can
ship.

## 7. Not asked for, found anyway: `--session-id` refuses any id that already has a transcript

The probe's own first attempt failed with an authentication error, then re-ran with the
same id, and got:

    Error: Session ID 30c55742-5208-4a9a-a689-475c5f3a23fb is already in use.

The session was long dead — the process had exited — but the transcript file existed, and
that is enough. So "in use" means "has a transcript", not "is running".

Wakil is unaffected today: it mints a fresh UUID per launch and cannot collide. It
matters to 2b-v only as a closed door — *re-entering a session by passing its own id to
`--session-id`* is not one of the two shapes in §2, and no amount of trying will make it
one.

Related, and confirmed rather than assumed: **uppercase ids round-trip.** Swift's
`UUID().uuidString` is uppercase and the CLI's own ids are lowercase, so this was worth
checking. Scenario 10 started `CE8F3132-07F7-…` and scenario 11 resumed it by that exact
string; the transcript is named with the uppercase form and the codeword came back.

## 8. Not asked for, found anyway: Wakil's own sessions cannot appear in ⌘P today

This is a defect in shipped code, and it is squarely 2b-v's business — a resume list that
cannot list the sessions Wakil itself creates.

`ClaudeCodeCLIHarness` never sets `Process.currentDirectoryURL` (grep: the only property
set on the process besides pipes is `executableURL`), so `claude` inherits **Wakil.app's**
working directory. `claude` records that inherited cwd in the transcript and files the
transcript under its encoded form. `wakilcore.ListSessions` then filters candidate
transcripts by `firstCwd(path)` against the *active project's roots*
(`sessions.go:357-373`), so a session filed under the launcher's directory is a confirmed
non-match for every project and is dropped from the listing — silently, and not even
counted in `skipped`, because a confirmed non-match is deliberately not counted there.

Measured on this machine's real transcript store, rather than argued from the code. Three
transcripts under `~/.claude-personal/projects` mention `mcp__wakil__`, i.e. were launched
by Wakil.app:

| project directory | transcripts | Wakil-launched |
|---|---|---|
| `-Users-operator-conductor-workspaces-wakil-castries` | 14 | **2** |
| `-Users-operator-conductor-workspaces-wakil-sacramento` | 4 | **1** |
| `-Users-operator-wakil-acceptance` (the registered project root) | 4 | **0** |

Every Wakil-launched session is filed under the *worktree Wakil was launched from*. The
registered project — `wakil-acceptance`, the one ⌘P scopes to — holds four transcripts and
not one of them came from Wakil. So ⌘P's session section, as shipped, can only ever list
sessions the operator started by hand inside the project directory.

The fix is small (`currentDirectoryURL`) and the design question attached to it is not: a
Wakil project may declare several roots, and a session gets exactly one cwd. 2b-v's spec
has to say which root a launch runs in, and what happens when a project has more than one.

**A second-order finding from the same area.** Scenario 9 resumed a session from a
*different* working directory. It worked, the codeword came back, and the agent reported
the new cwd as its own. The transcript stayed in the original project's directory but
gained records carrying the foreign cwd (32 records with the original, 5 with the new).
`ListSessions` reads only `firstCwd`, so the listing is stable — the session keeps
appearing under the project it started in — but the record is no longer coherent, and
anything the agent did with a relative path went somewhere the transcript does not
advertise. Resuming with the session's own root as cwd is therefore not a nicety.

## 9. Not asked for, found anyway: two concurrent resumes scramble one transcript

Added after the first eight sections, because the fork-vs-continue decision in §2 turned
out to hang on it.

Scenario 12 resumed one session twice at once — process A given a slow prompt (a
200-word paragraph), process B started a second later with a one-word prompt. **Neither
failed.** No "already in use", no refusal, no warning; both `init` events reported the
same session id and both `result` events reported success.

The transcript is not corrupt as a file — all 76 lines parse as JSON — but it is
scrambled as a conversation:

    58  user       "Write a 200-word paragraph about tide pools."
    66  user       "Continue from where you left off."       <- injected by process B
    67  assistant  "No response requested."
    68  user       "Reply with just the word beta."
    71  assistant  "beta"
    74  assistant  "Tide pools are small, self-contained ..."  <- process A, arriving last

A linear read — which is exactly what §3's thread rebuild does — yields a conversation
that never happened, with an answer after the question that followed it. The `parentUuid`
chain would in principle show the branch, but nothing about the file's *order* does.

**This is the argument that decides §2.** Continuing in place is only safe under an
exclusivity guarantee that Wakil cannot make: the CLI enforces nothing, and a session the
operator has open in a terminal is invisible to Wakil — a collision made *likely* rather
than theoretical by §5, which makes terminal-born sessions listable in the first place.
Forking is safe by construction: a new transcript per fork, never a shared writer.

**A useful thing seen in the same scenario.** Process B resumed a session whose last user
turn had not yet been answered, and the CLI injected `"Continue from where you left off."`
by itself. Wakil quitting or crashing mid-turn is a real case, and this is what a resume
of it will look like — the CLI repairs the dangling turn rather than refusing it.

**And the cost that is not a cost.** Forking copies the history, so it was worth measuring
what a copy weighs. A real Wakil-launched session's transcript is 315 KB; the whole of
`~/.claude-personal/projects` — 12 project directories, months of sessions — is 5.4 MB.
Disk is not a reason to prefer either shape.

---

## 10. What this means for the spec

Ten findings, and the four that constrain the design:

1. **Resume has exactly two shapes** (§2), and §9 decides between them: **fork**, because
   continuing in place needs an exclusivity guarantee no layer of this system can make.
   The CLI records no lineage between a fork and its parent, but Wakil mints the child id
   and so holds both halves of the link — recording it is Wakil's job, and ⌘P collapsing a
   chain into one entry is what keeps the list from growing a duplicate per resume.
2. **The thought thread comes off disk** (§3), through a new `wakil-ctx` tool, mapping
   `text` / `thinking` / `tool_use` / `tool_result` blocks onto the existing `ThoughtRow`.
   `aiTitle` is available and is a better ⌘P label than `firstPrompt`.
3. **The harness must become replaceable, not resumable** (§1 + the code as it stands).
   `events()` refuses a second consumer, `start` after `stop` throws `alreadyStopped`, and
   `WindowSession` bakes one session id into the journal and the socket path at launch. A
   resume is a new harness instance, which means `WindowModel` needs a factory rather than
   an injected instance, and `startEventPump`'s `guard eventPump == nil` has to go.
4. **§8's cwd defect is in scope.** Without it the exit criterion is unreachable in
   practice: the list would work and would never contain a session Wakil made.

And two the spec can lean on rather than solve: the write gate and the allow list already
work on resumed sessions (§4), and resume is cheap (§6).
