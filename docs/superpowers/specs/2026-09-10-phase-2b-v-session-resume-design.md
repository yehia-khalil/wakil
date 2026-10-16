# Wakil — Phase 2b-v, session resume

**Status:** draft for review · **Created:** 2026-09-10 · Conforms to
`docs/wakil/north-star.md`. Probe: `docs/wakil/session-resume-probe.md` (twelve scenarios,
`claude` 2.1.266, 2026-09-10).

`north-star.md` §8 gives this sub-phase one exit criterion: *"⌘P lists this org's past
sessions and picking one continues it, with its thought thread rebuilt — a resume the
operator can see, not a flag."* ⌘P has listed sessions since 2b-i. Picking one has never
continued it: `runPaletteItem` dispatches `session_resume`, which reads a session's
metadata and returns. This spec is the rest.

## 0. Where this sits

Ordered after the permission-prompt bridge, before 2b-vi.

| | Delivers | Status |
|---|---|---|
| ~~2b-i~~ | Pane model, magnetic canvas, the rail, ⌘P/⌘K | **Met 2026-09-08** |
| ~~2b-ii~~ | The void, planes, the Core, motion, the thought thread | Implemented 2026-09-09; acceptance outstanding |
| ~~2b-iii~~ | Write-gate UI and the first `.mutate` | Implemented 2026-09-09; acceptance outstanding |
| ~~2b-iv~~ | The void as the Core | **Met 2026-09-09** |
| ~~bridge~~ | `--permission-prompt-tool` and `approve_tool_use` | **Met 2026-09-10** |
| **2b-v** | **Session resume** | **This spec** |
| 2b-vi | Provider picker | Owed. §7 names the refusal this spec leaves for it |
| 2b-vii | Signing | Owed, partly blocked externally |

## 1. Scope

In: the resume path end to end — a transcript reader in the capability layer, a lineage
store, two new `SessionMeta` fields, a fork-shaped launch, a replaceable harness, a
rebuilt thought thread, and the working-directory fix without which none of it is
reachable.

Out: the provider picker (2b-vi), any change to the write gate or the bridge (§5 of the
probe measured both surviving a resume untouched), scrolling or expanding the thought
thread (§6), and deleting or pruning transcripts.

## 2. The five measurements this rests on

Every one is from `session-resume-probe.md`. None is inferred.

1. **`--resume` works under `-p --input-format stream-json` and keeps the id** (§1).
2. **There are exactly two re-entry shapes and no third** (§2). `--session-id` with
   `--resume` is refused outright unless `--fork-session` is also passed:
   `--session-id can only be used with --continue or --resume if --fork-session is also specified.`
3. **Nothing is replayed on stdout** (§3). The thread must be read off the transcript.
4. **The MCP surface, `--allowedTools` and `--permission-prompt-tool` all survive a
   resume** (§4). `probe_write`, off the allow list, still reached the prompt tool first.
5. **Two concurrent resumes of one session scramble it** (§9). Neither process errors;
   the file stays valid JSON and the conversation stops making sense.

## 3. Fork, not continue-in-place

Measurement 5 decides it. Continuing in place is safe only under an exclusivity guarantee
that no layer of this system can make: the CLI enforces nothing, and a session the
operator has open in a terminal is invisible to Wakil — a collision that probe §5 makes
likely rather than theoretical, because it makes terminal-born sessions listable and
resumable in the first place.

So every resume is a fork:

    --resume <parent> --fork-session --session-id <fresh uuid Wakil minted>

Three consequences, each of which this spec takes on rather than leaves implicit.

**Wakil keeps minting every id.** Charter open question 5 was closed on *"a new
`--session-id` UUID per launch, ... because Wakil assigns the id, the resume list is
authoritative"*. Forking with an explicit `--session-id` preserves that property exactly.
Continuing in place would have been the first agent session id Wakil did not choose.

**The listed transcript becomes immutable.** A resume can never alter the thing ⌘P
listed. Probe §7 closes the other door: `--session-id` refuses any id that already has a
transcript, dead or alive, so Wakil cannot accidentally start a *fresh* session onto an
old one either.

**Lineage is Wakil's job.** The CLI records none — probe §2 looked for `forkedFrom`,
`parentSessionId` and `sourceSessionId` in a forked transcript and found no such field.
But Wakil mints the child id, so it holds both halves of the link. §4 stores it. Without
this, ⌘P grows a near-identical entry per resume with nothing to show they are one
conversation, and the list gets worse the more the feature is used.

## 4. Capability layer — `wakil-ctx`

Three additions. All headless and usable without the app, per Invariant 10.

### 4.1 `read_session`

    in:  {"id": string, "limit": number}
    out: {"entries": [{"kind": string, "text": string, "toolName": string, "isError": bool}],
          "truncated": bool, "cwd": string, "provider": string, "parent": string}

`kind` is one of `user`, `assistant`, `tool`, `toolResult`. Entries are oldest-first.
`limit` keeps the last `limit` entries and sets `truncated` when earlier ones were
dropped, which is the same partiality-alongside-data invariant as `Rows.Truncated`,
`IssuePage.Truncated` and `SessionList.Skipped`.

**`thinking` blocks are dropped here, in the capability, not in the app.** `thoughtRow`
has no thinking case, so a live thread has never shown them; dropping them at this layer
makes it structural that no caller can reintroduce them by accident. Probe §3 measured 21
thinking blocks in a real 100-record transcript, so this is a real subtraction, made once
and in one place.

**`user` is returned, and it is the one place a rebuilt thread diverges from a live one.**
`design-language.md` §9 enumerates what the thread draws — *"assistant text, tool calls,
tool results, turn end"* — and `thoughtRow` matches it: the operator's own prompt is never
a row, because live, the operator typed it a second ago. Read back a day later that
reasoning inverts. A history of tool calls with no record of what was asked is not a
conversation, it is a log. So the rebuild renders `user` entries too, and §9 of this spec
states the divergence rather than burying it.

Ignored deliberately rather than by accident, all measured present in probe §3:
`attachment`, `queue-operation`, `atis-latch`, `last-prompt`, `mode`.

It returns `cwd`, `provider` and `parent` alongside the entries because it has to read the
metadata anyway to find the file, and one round trip is better than three. **It locates
the transcript by id across the org's providers rather than by filtering `ListSessions`,
which is what lets it name the refusal in §5.1 precisely**: `GetSession` filters the
project-scoped listing, so a session whose cwd is no longer a root is simply "not found",
and the operator learns nothing about why.

### 4.2 `SessionMeta` gains `cwd` and `title`

`cwd` is what `firstCwd` already reads on the way to filtering, currently discarded. It
has to be reported rather than derived, because `EncodeRootPath` is documented lossy and
strictly one-way — the transcript's *directory name* cannot answer "which directory did
this session run in", and §6 needs that answer.

`title` is the transcript's last `ai-title` record. Probe §3 measured six of them in one
session, rewritten as the conversation proceeded, last one winning. It becomes ⌘P's label,
with the existing `firstPrompt` as fallback for a session that has none. `firstPrompt`
stays: it is 200 runes of what the operator typed, and a title is what a model thought the
conversation was about.

### 4.3 The lineage store

`~/.wakil/orgs/<org>/sessions.json`, mapping child id → parent id. It sits beside
`org.json`, `active.json`, `projects.json` and `providers/` because it is per-org state of
exactly that kind, and because Invariant 4 makes the org directory a boundary that
cross-org bleed must be structurally unable to cross.

`ListSessions` joins it in, so each `SessionMeta` carries its parent when it has one and
⌘P can collapse a chain of forks into one entry. Written by `wakil-ctx` on behalf of the
app rather than by the app directly, so the resume path is scriptable headlessly and the
`--dispatch` runbook can exercise it.

## 5. The launch shape — `buildLaunch`

`HarnessLaunch` gains `workingDirectory`. `buildLaunch` gains `resumingFrom: String?` and
`workingDirectory: String`, and builds one of exactly two argv shapes:

| | argv fragment |
|---|---|
| fresh | `--session-id <fresh>` |
| fork | `--resume <parent> --fork-session --session-id <fresh>` |

Never a third, and that is a test rather than a convention: measurement 2 is a startup
refusal, so an argv carrying `--resume` without both `--fork-session` and `--session-id`
is a session that never begins.

`buildLaunch`'s doc comment currently says `--resume` *"is deliberately never among the
arguments this function builds ... resuming is 2b's"*. It is now 2b's. That comment is
rewritten, not amended.

Everything else about the launch is unchanged. Measurement 4 is what buys that: the MCP
config, the allow list and the permission-prompt tool all take effect on a resumed session,
so `agentMCPConfigJSON`, `agentAllowedTools` and `permissionDecision` need no resume
variant and get none.

### 5.1 The working directory, and the defect it fixes

`Engine.start` sets `process.currentDirectoryURL` from `launch.workingDirectory`. Today it
sets nothing, so `claude` inherits Wakil.app's own directory, records it in the transcript,
and is filed under its encoded form — while `ListSessions` filters candidates by
`firstCwd` against the *active project's roots* (`sessions.go:357-373`). The consequence,
measured on this machine in probe §8: all three Wakil-launched transcripts sit under
worktree directories, and the registered project root holds four transcripts of which none
came from Wakil. **⌘P cannot list a single session Wakil itself created**, and this
sub-phase's exit criterion is unreachable until that is fixed.

Which directory:

- **A fresh session runs in the project's first declared root.** `roots` is an ordered
  array of `{path, role}`; the operator declared the order.
- **A resumed session runs in the cwd its own transcript records** — §4.2's new field.
- **If that cwd is no longer one of the active project's roots, the resume is refused**
  with the path named, rather than run somewhere else. Probe §9 measured what the
  alternative looks like: the CLI happily accepts a foreign cwd, keeps the transcript in
  the original project's directory, and writes records carrying the new one, so the file
  ends up describing two places at once.

## 6. The harness becomes replaceable, not resumable

`AgentHarness.start(sessionId:)` becomes
`start(sessionId:resumingFrom:workingDirectory:)`. This is the protocol change
`north-star.md` §8 predicted for this sub-phase, and it is the whole of it — no `resume`
method, because a resume is a new process, not a state change in an existing one.

`workingDirectory` is on `start` rather than on the harness's initialiser because §5.1
makes it a per-session value: fresh sessions run in the project's first root and resumed
ones in the session's own cwd, so an instance-level directory would be wrong for exactly
the case this sub-phase exists to serve.

`ClaudeCodeCLIHarness` needs nothing else. Its single-shot properties stay exactly as they
are and are load-bearing: `events()` still refuses a second consumer with
`preconditionFailure`, and `start` after `stop` still throws `alreadyStopped`. Each
instance still serves one session and one consumer.

What changes is `WindowModel`:

- it takes a `@Sendable () -> AgentHarness?` **factory** instead of an injected instance,
  and holds the current one;
- `startEventPump` loses `guard eventPump == nil` in favour of cancel-and-replace;
- resume is: stop the old harness → cancel the pump → replace `thoughts` → start a new
  harness with fork argv → restart the pump.

`WindowSession.start()` supplies the factory. Its own launch-time `sessionId` — the one
threaded into `WakilWiring.build` and the MCP socket path — is untouched by a resume, and
this is worth stating because it looks like it should not be: **the journal and the socket
are keyed on the window's id, not the agent's.** `WindowSession` mints one UUID for the
journal file (`~/.wakil/journal/<id>.jsonl`, via `ActionRegistry(journalDirectory:sessionId:)`)
and the socket path; `WindowModel.send` mints a second, unrelated one for the agent. So a
resume changes the agent's session and leaves one journal per window, which is the right
grain: the journal records what this window did, and it resumed something.

## 7. Two refusals, both visible

**Wrong provider.** A session belongs to exactly one provider — a Claude Code session is a
subprocess bound to one config dir and its transcript lives inside it, which is why
`SessionMeta.Provider` exists and is not decoration. Resuming needs that provider's config
dir and OAuth token, and until 2b-vi those are launch-time environment variables. So a
resume whose `provider` differs from `WAKIL_PROVIDER` is refused, naming both. **This is
the scope boundary between 2b-v and 2b-vi**, stated rather than discovered: 2b-vi's job is
to remove this refusal by choosing the provider in the window and reading its credentials
from the org's provider record.

**Cwd no longer a project root.** §5.1.

Both land in `status`, like every other refusal in this window — a SwiftUI control has
nowhere to throw to, so a refusal has to become something on screen or it becomes nothing
at all.

## 8. The actions

| name | kind | change |
|---|---|---|
| `session_resume` | `.read` → **`.control`** | Now resumes. Was metadata-only |
| `session_get` | `.read` | **New name for the old `session_resume`** — `get_session` metadata, unchanged behaviour |
| `session_list` | `.read` | Reports the two new `SessionMeta` fields and the parent |

`session_resume` becomes `.control` by the enum's own definition: it changes Wakil's own
state and the world outside Wakil is untouched, so the environment never blocks it. That
makes `agentAllowedTools` publish it automatically — it filters on `.read || .control` and
excludes `.mutate` by *kind*, never by name — and this spec deliberately adds no
name-based exception, which would be the first of its kind.

**So the agent can resume a session, and the handler replies before it swaps.** The wrinkle
the write gate never had is that the agent calling resume kills the process that owes the
tool result: the shim's socket dies with `claude`, so a reply sent after the swap can never
arrive. The handler therefore returns `"resuming into <id>"` synchronously and schedules
the swap on the next main-actor turn. The calling agent gets an honest result and is then
replaced. *"Resume yesterday's booking session"*, spoken, is precisely the shape of the
Phase 2 exit criterion, so making this reachable is not a courtesy.

**The rename is breaking and is the right way round.** Today's `session_resume` does not
resume; the name has to go to the action that does. `StandardActionsTests`,
`AppWiringTests` and `WindowModelTests` all assert the registered name set and move with
it, and any runbook dispatching `session_resume` for metadata must be updated to
`session_get`.

## 9. The rebuilt thread

On a successful resume, `thoughts` is replaced — not appended to — by:

1. up to 200 rows mapped from `read_session`'s entries — the live mapping for
   `assistant`, `tool` and `toolResult`, plus a row for `user`, which per §4.1 is the one
   kind a live thread never draws and a rebuilt one must, and
2. a seam row naming the parent session, so what is history is labelled as history.

Then live rows arrive on top, exactly as they always have.

**What the operator actually sees is six rows, and that is deliberate.** `ThoughtThread`
renders `Array(rows.suffix(6))` — `private static let visible = 6` — and does not scroll.
Six is `design-language.md` §9's own number (*"a thread that holds six lines"*), and §12
puts the substance in panes rather than in the thread, so this is a peripheral object by
design and not by omission. So immediately after a resume the operator sees the seam and the five
rows before it, and live rows push them out as the turn proceeds. The 200-row cap is
therefore a guard on the model rather than on paint cost: probe §3 measured a real session
at ~100 message records, so 200 is above anything yet observed and an operator should never
normally see `truncated` fire. It is in the spec because an unbounded rebuild of an
unbounded transcript is a bound nobody has measured, not because 200 is a considered
number.

`nextThoughtId` continues from after the rebuilt rows. `ThoughtRow` is `Identifiable` and a
repeated id makes SwiftUI draw one row twice and omit another — the bug 2b-ii's comment
records having already made once.

## 10. File structure

| file | change |
|---|---|
| `internal/wakilcore/sessions.go` | `read_session`'s reader; `SessionMeta.Cwd`, `.Title`, `.Parent`; `firstCwd`'s value reported rather than discarded |
| `internal/wakilcore/sessions_lineage.go` | new — the lineage store's read/write |
| `cmd/wakil-ctx/main.go` | register `read_session` and the lineage writer; object-typed `Out` per `internal/mcpx`'s rule |
| `app/Sources/WakilKit/Harness/AgentHarness.swift` | `start(sessionId:resumingFrom:)` |
| `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift` | `buildLaunch`'s two shapes; `HarnessLaunch.workingDirectory`; `Engine.start` sets `currentDirectoryURL` |
| `app/Sources/WakilKit/App/WindowModel.swift` | harness factory; pump replacement; the resume path; the rebuilt thread and its seam |
| `app/Sources/WakilKit/Registry/StandardActions.swift` | `session_resume` becomes `.control`; `session_get` added; `session_list`'s new fields |
| `app/Sources/WakilApp/WindowSession.swift` | supplies the factory and the first-root working directory |
| `app/Sources/WakilApp/ThoughtThread.swift` | the seam row's treatment |
| `docs/wakil/phase-2b-v-acceptance.md` | new — ships with this spec, unwalked |

## 11. Verification

**Go.** The transcript reader against fixtures for each block type; the `limit`/`truncated`
pair; a missing file; a transcript with no `ai-title`; a session whose `cwd` belongs to
another project. The lineage store round-trip, including a child with no parent and an
absent store. `SessionMeta`'s three new fields on the wire, and `wakil-ctx`'s schema test
(`cmd/wakil-ctx/schema_test.go` exists because `list_sessions` once shipped an unusable
bare-array `Out`).

**Swift.** `buildLaunch`'s two argv shapes exactly, and that `--resume` never appears
without both `--fork-session` and `--session-id`. `workingDirectory` reaching `Process`.
Harness replacement across a resume without tripping `events()`'s single-consumer
precondition, and `nextThoughtId` not repeating across a rebuild. Both refusals in §7.
The reply-before-swap ordering — that `session_resume` returns before the old harness
stops. The registered-name set after the rename.

**What none of it covers.** Whether a rebuilt thread reads as the same conversation
continued, whether the seam reads as a seam rather than as an error, and whether a
collapsed chain in ⌘P reads as one session. 2b-ii's lesson, recorded in `north-star.md`
§8, is that a sub-phase whose value is a human judgement gets marked "implemented" and
then treated as met. `docs/wakil/phase-2b-v-acceptance.md` ships with this spec, listing
those checks as **not yet run**, and the row in the phase map is marked met only after the
runbook is walked, dated and recorded.

## 12. What this does not do

- **No provider switching.** §7's refusal is 2b-vi's to remove.
- **No lineage in the transcript.** Wakil's store is the only record of a fork's parent;
  a transcript read by anything other than Wakil shows no relationship. Probe §2
  established the CLI offers nowhere to put one.
- **No concurrency guard.** Fork makes one unnecessary *for Wakil's own resumes*, since
  each gets its own transcript. It does nothing about two other `claude` processes
  scrambling a session between themselves; that is probe §9's finding and is outside
  anything this app controls.
- **No thread scrolling, no expansion, no history search.** Six rows and no scroll is
  `design-language.md` §9's position, and this sub-phase does not reopen it. A resumed
  session's full history is on disk and in no view.
- **No pruning.** Every fork is a full copy of its history. Measured harmless — a real
  session's transcript is 315 KB and the whole store 5.4 MB (probe §9) — but it grows
  monotonically and nothing here trims it.
- **No synchronisation between `send` and `resume`.** Both mutate the same window's
  `harness`/`sessionId`/`thoughts` state with no lock between them. A prompt typed while
  a resume's round trip (`readThread`, then `next.start`) is still in flight can be
  swallowed — `send` sees the harness `resume` is about to replace and hands it a turn
  that either lands on a session about to be superseded or, if it lands after the swap
  completes, addresses a harness the operator's screen has already moved on from — or
  can surface as `agent: notRunning` immediately after an otherwise successful resume, if
  the two calls interleave the other way. Neither the window nor `ActionRegistry` queues
  one against the other.
- **A parked mutation confirmation survives a resume.** `resume` replaces `harness` and
  `sessionId` but does not touch `confirmations`, so a proposal parked by the
  soon-to-be-superseded process stays approvable — reachable from `confirmPending` —
  for a `claude` process that resume has already stopped. Approving it resolves the
  waiter, but nothing is left running to act on the result. Bounded only by whatever
  timeout the broker itself parks proposals under; nothing about `resume` shortens it.

## 13. Risks

**The rename lands on three test files and any runbook using `session_resume` for
metadata.** Mechanical, but a shipped action name changes meaning rather than disappearing,
so a stale caller gets a resume where it wanted a read. Mitigated by the name set being
asserted in `StandardActionsTests`, `AppWiringTests` and `WindowModelTests` — a stale
caller in this repo fails a test rather than misbehaving.

**`--fork-session` is documented, unlike the bridge's `--permission-prompt-tool`, but the
resume shape is still one CLI's behaviour.** If the flag interaction changes, `claude`
rejects the argv at startup with a non-zero exit and the reason on stderr, which the
harness surfaces. That failure is loud, so no startup guard is built; the acceptance
runbook pins 2.1.266 instead, as the bridge's does.

**A resume of a very large transcript is unmeasured.** Probe §6 measured cost falling on
resume, not rising, but its histories were two and three turns long. A session with a day
of work reads far more cached tokens, and the 200-row cap bounds the thread, not the
context the CLI re-sends.

**`ai-title` is undocumented.** It is a transcript record type, not a flag, and nothing
guarantees it stays. §4.2 falls back to `firstPrompt`, which is the label ⌘P shows today,
so its disappearance is a downgrade rather than a break.
