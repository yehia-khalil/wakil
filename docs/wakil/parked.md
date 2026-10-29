# Parked issues

Twenty-nine issues closed `not planned` on **2026-09-26**, when the workflow moved to
five rungs and the tracker became a bug inbox
(the migration design, which left `main` when it merged).

**Nothing here is abandoned and nothing is destroyed.** Each is closed, not deleted;
reopening is `gh issue reopen <n>`, and the full body, comments and history are intact
on GitHub. This file exists so the pile stays readable without the board carrying it.

**When these come back.** A parked finding returns as **input to a spec** when its area
is next worked — not as a ticket. The Design rung reads this file for the sub-phase it
is about to design, and the observations here become spec sections or get ruled out on
the record.

---

## Track — answered by Conversations (8)

Track became the *Conversations* row of the phase map on 2026-10-23, folded with New conversation.
Each item below says what Conversations built to answer it.

- **#78** — Track — two tickets in one window, without a second window *(the map)* → answered: a conversation, not the place, is the unit; several live per place, each pinned to its own socket
- **#79** — What a Track is, and where its boundaries fall → answered: as #78 — a conversation with its own harness, thread, draft and canvas, at most one on screen per place
- **#80** — Does switching to a Track fork its session, and can Wakil afford that? → answered: switching never forks; only an ended conversation resumes as a fork
- **#82** — Does the agent know about Tracks? → answered: no; each sees only its own thread, and each write passes the gate on its own
- **#83** — What the Track switcher looks like, and where it lives → answered: chips, the Landing's Running column and ⌘P's Running group
- **#84** — Where Track state lives on disk → answered: nothing new; a canvas is filed under its lineage root, and live conversations are not persisted
- **#85** — What happens to an in-flight turn when the operator switches Track → answered: it finishes in the background; a proposal waits on its chip
- **#86** — Where Track lands in the phase map, and what it displaces → answered: the phase-map row, *Conversations*

## Findings not tied to a live sub-phase (12)

Real observations, filed as `needs-triage` and never triaged into a phase. Several are
charter-level questions rather than defects.

- **#131** — A pane's title is the last action's, not the operator's
- **#136** — What the Codex conformance of `ProviderLogin` does
- **#141** — §9 says the terminal pane carries the org's credentials; nothing does
- **#144** — An operator's switch into production costs nothing, and now there is a button for it
- **#145** — A session cannot be named, so the surface that lists them shows raw UUIDs
- **#156** — `get_context` publishes every secret ref; `list_databases` strips them
- **#159** — Untrusted content reaches the agent through `read_pane` — is that Wakil's to say anything about?
- **#167** — The action journal is a durable store nobody owns
- **#171** — What a pane does when the agent writes under the operator's hand — three mechanisms, no stated rule
- **#177** — `resolvePane` hardcodes `kind: "db"` — three pane kinds, three copies
- **#230** — `secrets set-api` stores no scheme, and the basic pair is not a scrub form
- **#235** — One word for two nestings: "region", and one fact under two names: credentialed / authenticated

## Drift, docs and dead seams (6)

Documentation that overstates what ships, and seams with no production caller. None
blocks a phase.

- **#45** — The rename-gate annotation overstates what renaming production does
- **#47** — ⌘P discards what `list_sessions` returns about partiality, lineage and provider
- **#87** — `session-resume-probe.md` §8 reports a defect that has since been fixed
- **#104** — The driver gate methods have no production caller, and statement classification switches on driver names instead
- **#105** — The credential-scrub ordering is prose, executed by hand at two call sites that have drifted
- **#254** — e2e: the browser leg — a login binary seeded onto the provider record

## Flakes under load (3)

Characterised in their own bodies; each reproduces only in the full run or under load.
`docs/wakil/` already records that load, a locked screen and Orca stealing its own
keystrokes all read as app defects.

- **#222** — A layout write raced by its own assertion: `aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy` flakes in the full run
- **#262** — A percent-encoded cell is inert at emit and refused at the wire, in Go's words
- **#282** — `aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy` fails under load: a layout write lands after the test deletes the file

---

## Not parked — absorbed into the 2c-iv plan (4)

Genuinely unbuilt. Their content became the phases of
the 2026-09-26 phase-2c-iv API-client-pane plan (left `main` when it merged). They are not
waiting; they are being built.

- **#192** — `api_bind` and `api_unbind` → Phase 1
- **#193** — `api_request` → Phase 2
- **#194** — `api_send` → Phase 3, the exit clause
- **#195** — Recent, `api_reopen`, Copy as cURL → Phase 4

## Not parked — shipped (8)

**These are done.** [PR #297](https://github.com/yehia-khalil/rafiq/pull/297) merged the
whole 2e stack to `main` on 2026-09-26 — 17,843 insertions across 109 files. They closed
as *completed*.

- **#236** — The Providers node shows this organisation, and adoption becomes a door
- **#238** — The sign-in that spawned `/claude`, a re-auth that asks twice, a confirmation with no buttons
- **#240** — The mint spoke only to a terminal, and nobody had ever run it
- **#244** — Every trip ran in the wrong directory, and the token was printed in a sentence
- **#259** — Every account added through the pane was born unusable
- **#269** — The settings pane was a whole band below the scale it was drawn to *(one criterion unmet — a visual ruling against the artboard, carried into the runbook's walk)*
- **#270** — The table says which account is running, and offers the switch
- **#271** — The review's findings: a path across the org boundary, a repair that repaired nothing, a header 22pt adrift

## Also closed — seventeen stale pull requests

#209, #210, #218, #219, #220, #221, #223, #226, #227, #228, #229, #237, #239, #241,
#245, #260, #272 — every head already contained in `main` via #297, verified with
`git merge-base --is-ancestor`. Seventeen open drafts that looked like pending work and
were not. `gh pr reopen <n>` if that turns out to be wrong.

## Still open (5)

| Issue | Why |
|---|---|
| **#179** | 2c-iv's spec — binding, with dated probe corrections in its comments |
| **#89** | 2e's spec — binding, synthesised from map #46 and corrected by two probes. Stays open until 2e is **walked** |
| **#301** | The e2e fixture's keychain shim cannot reach the shipped binary, and the agent checks hang on a login-keychain prompt |
| **#242** | Every integer above 2^53 dies in the Go MCP SDK, before Swift ever decodes it |
| **#292** | An act can lose the foreground midway, and the failure blames the app |

---

## Owed from the retired phase log (2026-10-29)

Each line is something a walk or a map left owed or open that main's code does not
visibly resolve. Issue numbers (#nnn) are from the old `rafiq` tracker. Read the lines for the
sub-phase you are about to design.

- **2b-vii** — signing: notarisation needs a paid Developer ID this Mac lacks; local signing with entitlements and the hardened runtime is reachable. Also unwalked: the terminal's bundle `PATH` on a Developer ID build.
- **2c-v** — cut 2026-09-16 (session browser). The label is not reused and 2c-vi is not renumbered; 15 citations land on it.
- **2c-vi** — PM board, deferred 2026-10-06; its write waits on open question 15. Exit: a dragged card and "move 2835 to review" dispatch one action, and only a transition Jira offers from the current status is reachable. Reuses the 2c-i data surface. Not a Jira client.
- **2c-ii** — D1 (one of thirteen walk defects) deliberately unfixed: a pane opened by `db_read_table` shows the table, not SQL, because no `SELECT` was composed (`Conn.ReadTable` keeps Swift from writing one); typing SQL into the line converts the pane, an affordance not yet visible.
- **2c-iii** — `pane_close` ends in `panes?.drop`, a second leak site that should await the terminal's teardown (`LayoutActions.swift`).
- **2c-iii** — the tripwire's `panes` and `layout` entries are wrong; whoever moves them corrects them.
- **2c-iii** — `WindowSession`'s close path is untestable (no `WakilApp` test target) and needs an operator walk; `harness?.stop()` and `shutdown()` ordering are untested.
- **2c-iii** — a TUI that repaints via scroll regions (`CSI S`/`T`) would still record noise in a block; walked once against Claude Code only. "Send to thread" copies a fenced quote and reaches no compose field.
- **2c-iii / 3a-i** — the terminal pane cannot paste or edit a selection (#365).
- **2c-iv** — #342: an accessibility client that sets a field's whole value drops its holes. A hole dragged between fields, a chip at the path's wrap edge and a query row's `×` beside a twin holding typing are walk-only. Unicode domain names and IPv6 zones are refused by the URL check. The environment menu once opened empty; cause never confirmed.
- **2e** — #323's journal half: a refused action is journalled as `"error"` with no text; adding text needs a redaction review first.
- **2e** — keeping the whole canvas on an account switch (operator ruling, "after 2e"); not built.
- **2e / #176** — `backups/` keeps a displaced account's identity across a switch; the plaintext fallback can leave a `.credentials.json` a replacing login would not sweep; a replacing login does not revoke the displaced refresh token. Unsettled: whether the CLI resolves symlinks in `CLAUDE_CONFIG_DIR` before hashing the Keychain name (§9.1's `realpath`).
- **2d-ii** — the first-use speech model download was never exercised; `2d-ii-thread-earlier` and `2d-ii-voice-lands-unsent` are intermittent; a pane twitches after a drop (#353).
- **3a-ii-b** — `api-unbind.jsonl` is red on main, with no issue (`bg-agent-chip-over-landing` is under background-agents).
- **3a-iii** — Sign in (device flow) waits on Wakil's two OAuth apps (`operator-todo.md`).
- **3b-iii** — `api-bound-locks.jsonl` is intermittent on main; `3b-i-editor-unsaved-save.jsonl` lost its app once with no crash report.
- **Layout-persistence timing tests** flake under load (#312, #328, #332, #344); see also #222 and #282 above.

## Owed from the walks, before the runbooks go (2026-10-29)

**2026-09-15 acceptance backlog** — the operator accepted these without walking them; each is still unknown:

- **2a** — check 8: cross-org isolation at the window, never run for want of a fixture; unit tests only.
- **2b-i** — the canvas, rail and palettes were never looked at under a real mouse and eye.
- **2b-iii** — the write gate's UI half (the confirmation plane at the window; 2a checks 5 and 6) was not walked.
- **2b-v** — ten checks accepted unwalked. Come back to check 10: resuming a session open in a second terminal must leave both with separate transcripts (`session-resume-probe.md` §9 measured it going wrong under continue-in-place). It needs a hand-opened `claude` session.
- **2b-vi** — the live in-window provider swap is headless-only; `ctx_set_provider` is proven, the swap is not.
- **2c-ii-b** — the MySQL write path (checks 12, 14, 17) has never been exercised at the window; the write credential exists since 2026-09-16.

**3a-ii** (found by e2e, not ruled on):

- The agent's own shell commits under git config, not the organisation's identity.
- Drafts do not survive a relaunch (R3); the ↑ history goes with them.
- A cancelled commit shows `editor_changes_commit: CancellationError()` under the message box.
- Commit All refused by a hook leaves every file staged (`git add -A` ran first).
- Unstaging an untracked path gives git's refusal, not Rule 7's no-op.
- ⌘⇧G focuses the list, not the message box (spec Rule 3).
- After a Settings save the hint changes only once the Changes view is shown again.

**3a-iii** (deferred from the whole-branch review):

- **Credentials pasted into a clone link bypass the helper and are journalled.** (security)
- **The device code is journalled.** (security)
- Hosts are not validated as `hostname[:port]`; conflict paths with spaces are listed split.
- An instructions update is lost if that turn's send fails.
- Account Test has no Cancel; a clone whose sheet is closed still adds its project.
- A ProxyJump hop gets no organisation key; Wakil's `known_hosts` does not inherit `~/.ssh/known_hosts`.
- The agent's own shell pushes with the Mac's git and ssh, not the organisation's account.

**3b-iii** — diff tabs are not saved, so a migrated pane has none after a relaunch (R7); files past 10,000 lines show no change marks or peek (B1).

---

## Owed by the acceptance runbooks (deleted 2026-10-29)

Items the runbooks recorded as unwalked, unbuilt or deferred, saved here before the runbooks were deleted from the branch (git keeps them). Grouped by sub-phase; `(security)` marks a security gap.
They were swept from the runbooks as written and checked against `main` only where that was cheap: a line may already be fixed.

**365-terminal-input-editing**

- **365** bash 4+ path of selection editing ships untested: no Homebrew bash on this Mac, `homebrewBashReplacesTheSelectedWord` skips.
- **365** zsh-vi-mode and plugins that rebuild keymaps late: selection edits silently stop; no such plugin ever tried.
- **365** deferred review minors: widget read loop has no timeout; ⌘C over CJK adds a space per wide character; very fast keys can arrive out of order.
- **365** drag on the live region may not focus the pane (review flag); no e2e check reaches drag or double-click selection, walk-only.

**background-agents**

- **background-agents** walk 2, 3, 4, 7 never walked (Reduce Motion dot, production-red segment, amber `— waiting` chip, `+N more` popover); the runbook was never marked walked.
- **background-agents** no check for the red `— failed` chip, for an agent's own `ctx_set_*` being refused ("place is pinned"), or for one journal line tying session and place.
- **background-agents** `project-root-note` intermittent: switch to `e2e-project` still "working" after 3 s, twice in three runs.
- **background-agents** `3b-v-click-focuses-pane` red: click lands under the 220 pt Rail, so the Rail takes focus and "q" goes nowhere; fails at merge-base too.
- **background-agents** `3b-ii-b-replace-cancel` intermittent: regex search over the 200 MiB haystack lands just past the 3 s settle; time it before it leaves quarantine.
- **background-agents** Landing at 1000 wide overflows: content wider than the window, chip at x 777–1048 and capacity indicator at 894–1040 (`bg-agent-chip-over-landing` red).

**phase-connections**

- **connections** a second gated call in a conversation while one is on the plane is refused ("Another call in this conversation is already waiting…"), not queued.
- **connections** no approval waits on a timer: an unanswered plane holds the agent's turn until answered or the agent is stopped.
- **connections** quick tasks get no connections; only Claude Code sessions carry them.
- **connections** the spoken flag is sticky for the turn: a typed message sent beside a spoken one still asks before a ticked write.
- **connections** a change made from a terminal (`wakil-ctx`) reaches open conversations only after Settings is next read (a removal still refuses at once).
- **connections** a restart for a connection change ends the idle agent's background shells and subagents; a sign-in change restarts every open conversation in the organisation, even one that never uses that connection.
- **connections** Datadog and Amplitude (the fields sign-in) and Slack's pre-registered client never walked.
- **connections** a per-project connection (a project on another PM tool than its organisation, open question 6) planned for, not built.

**conversation-layouts**

- **conversation-layouts** no reclamation: layout files for conversations gone from `list_sessions` are never dropped, so `~/.wakil/layouts` only grows.
- **conversation-layouts** two windows on one conversation writing one layout file was never reasoned about.

**palette**

- **palette** IME candidate windows (Japanese, Chinese) never walked: ↑ ↓ Return Esc belonging to the input method during marked text is unverified beyond the dead-key ´.
- **palette** Send and Fill from cURL not walked from the palette; Send needs a server, the walk's API entry points nowhere.

**phase-1**

- **phase-1** `get_issue` returns no comments (disclosed in its tool description); `recall` has no recency ordering and snippets carry status, not an excerpt.
- **phase-1** nothing has ever run against a `codex` or `local` provider; they register but have no session adapter.

**phase-2a**

- **2a** `initech` and `umbrella` never tried against `--mcp-config` and `--strict-mcp-config`; managed settings on team and enterprise plans could override them.

**phase-2b-i**

- **2b-i** 120fps on ProMotion never observed (this Mac reports 60 Hz); only the frame-cost proxy exists. Project switch under 400 ms never measured.
- **2b-i** `Pane.busy` publishing before the dispatch is awaited is untested; `WindowModel` has no test target to reach it.

**phase-2b-ii**

- **2b-ii** Project-switch timing (spec target ~400ms to interactive) was never measured; needs a second registered project on this machine.
- **2b-ii** Overlapping agent turns: `turnInFlight` is a Bool, so a second turn's result or throwing send can clear the flag while the first runs; a counter is needed.
- **2b-ii** Where a developer sees dropped raw stream events when debugging a stalled session was never verified; spec's "harness still logs them" claim unsubstantiated.
- **2b-ii** 120fps on ProMotion is unfalsifiable here (both displays report 60Hz); only GPU frame cost against the 8.33ms budget was taken.
- **2b-ii** Void, production tint and thought-thread legibility were walked once only; VoiceOver over the hand-built grid and 500-row grid cost never measured.
- **2b-ii** Uniform structs for `VoidUniforms` agree between Swift and Metal only by inspection; a `static_assert` or checked shared layout would pin them.
- **2b-ii** Void pauses on `NSWindow.occlusionState` with no periodic reconciliation; a missed resume notification would leave it frozen. `VoidView` still `fatalError`s with no Metal device.
- **2b-ii** Cursor parallax writes `@State` on `WakilWindow`, re-evaluating the whole body per pointer event; unmeasured, fix is moving `cursor` into a child view.

**phase-2b-iii**

- **2b-iii** `readOnly` on the database record is inert (carried, never consulted); only `writeRef` decides write authority. `writeRef` equal to `ref` is not refused.
- **2b-iii** A caller that gives up first still gets the write: the MCP connection reads frames serially, so a cancel (or another tool's permission question) queues behind a 120s park.
- **2b-iii** `ConfirmationBroker.request` uses `withCheckedContinuation`, so a cancelled caller holds the single-flight slot for the full 120s timeout.
- **2b-iii** Confirmation plane is not modal enough: dim covers only the canvas, context row and composer stay clickable, and a tall thought thread draws over the plane.
- **2b-iii** Mongo mutation not built; DDL (CREATE, DROP, ALTER, TRUNCATE, GRANT, LOAD DATA) refused with no per-adapter justification written.
- **2b-iii** The confirmation token is the literal word `confirm`; database or environment name was considered and deferred.
- **2b-iii** Confirmation is single-flight only: a second gated dispatch while one is parked is refused with -32005; no queue and no awaiting-confirmation room state.

**phase-2b-iv**

- **2b-iv** The `make captures` GPU timing line (8.33ms budget) was never captured off the terminal; no number recorded, only the probe's older ~1.1ms.
- **2b-iv** Runbook H1/H2 commands are wrong as written: need `make build` first and `--exclude-dir=.build` on the deleted-layer grep.

**phase-2b-viii**

- **2b-viii** `autoResumeAfterSwitch` still filters on `cwd == rootPath` by exact match; #53 ruled it deleted, but sessions in subdirectories or non-first roots are discarded. Spurious fresh-session note.
- **2b-viii** `ActionRegistry.dispatch` and MCP `tools/call` never consult `operatorOnlyActions`; operator-only guarantee rests on the CLI allow-list and `approve_tool_use` alone. Hardening not done.

**phase-2c-i**

- **2c-i** `pane_move`, `pane_resize` and `pane_set_column_width` accept NaN and infinity; the store mutates, then the journal encode fails and the dispatch is absent from the audit log.
- **2c-i** `LayoutStore.setColumnWidth` enforces no minimum width; only the pointer path floors at `paneColumnMinimumWidth`, so an agent can set width 5.
- **2c-i** `pane_select_cell` and `pane_select_rows` accept a row index beyond the row count, so `read_pane` can report an anchor on a row that does not exist.
- **2c-i** The refresh pump subscribes asynchronously after `init`, so a dispatch racing window construction is missed with no catch-up.
- **2c-i** Check 13's positive half (a bool-typed column drawing a chip) was unexercisable against an empty Mongo database; pinned only at unit level.

**phase-2c-ii**

- **2c-ii** `SHOW TABLES` drill against MySQL was never seen on screen; check 8 was accepted on code and tests only.
- **2c-ii** Production mutation block (check A2) never exercised at the window: the one production DB has no `writeRef`, so `writeGate` was never reached; unit tests only.
- **2c-ii** `schemaPaneContents` supplies `key: false` only when absent, so a future driver's non-boolean `key` would pass into a BOOLEAN column; latent.
- **2c-ii** `DBPane.pageControls()` duplicates `rowRangeDescription`'s visibility guard by hand; nothing enforces they keep agreeing.

**phase-2c-ii-b**

- **2c-ii-b** The full `make test-live` run was never re-run end to end after the MySQL escaping fixes (Docker engines down); only two live tests re-run green.
- **2c-ii-b** The pane title is now redundant (`EVENTS` above `events · select ...`); deleting it from pane chrome and keeping it for the rail is an unmade design call.
- **2c-ii-b** Per-reason read-only footer labels (spec 9.3) deliberately unbuilt on operator evidence; revisit only if operators report confusion.

**phase-2c-iii**

- **2c-iii** Sixteen of twenty-six checks never walked (only ten were): violet-only-in-proposal, mirror never lit, hatch texture, ⌘F counting in blocks, resize cadence under live drag, scrollback bound, Propose rerun, backfill label, probe drawing measurements.
- **2c-iii** Search across the 200-block-capped history does not tell the operator it did not reach further back; unestablished, never walked.

**phase-2c-iv**

- **2c-iv** No check has ever drawn a real reply: fixture hosts are `.invalid`, so the Body/Headers table and a successful response render only on the hand walk.
- **2c-iv** "Also look at" list (split proportions with a 200 KB reply, IME after a chip, undo after unbind, Recent shared across panes, title follows entry) was never ticked; look-only items.

**phase-2d-i**

- **2d-i** A session title can show part of the identifier note when the first message is 112–199 characters long; parked in PR #347, no fix found on main.
- **2d-i** `list_columns` is exercised against SQLite only; the MySQL and Mongo paths skip without live databases.

**phase-2d-ii**

- **2d-ii** Two post-walk fixes were not re-walked: the bar learning its window (`fa1c47d`) and the first-use microphone-permission notice (`5b2e4f2`).
- **2d-ii** `ThoughtThread.swift` is not under the control gate: its label column has a pointer-only second toggle. Open design call: drop the tap or name it.
- **2d-ii** No check for speech landing in the composer while the settings pane has focus (walk 14); ordinary work, not a harness limit.
- **2d-ii** ⇧Return breaking a line without sending in the agent composer has no check; accessibility-dump multi-line value format unmeasured.

**phase-2e**

- **2e** Checks 3, 4 and 7 each left a real one-year credential at Anthropic; the operator owes revoking the ones not kept, and `wakil org rm <org> --force` for scratch orgs.

**phase-2e-ii**

- **2e-ii** Whole 15-row walk never walked (Walked column empty): folder picker, Trash Put Back, agent-pin refusal with a live agent, voice refusal, rename-on-leave refusal in the status line.
- **2e-ii** Renaming a project drops any `project.json` key the build does not know (`SaveProject` writes only known keys); a hand-edited file loses it.
- **2e-ii** A removed environment's Trash copy is its only undo; once the Trash is emptied nothing restores it.

**phase-2e-iii**

- **2e-iii** Whole 11-row walk never walked: real-Keychain token store, replace, clear, send of the stored token to a real host, agent and voice refusal, database rename.
- **2e-iii** Removing an API entry keeps its Keychain item; it must be deleted by hand with `security delete-generic-password`.
- **2e-iii** A hand-edited file with two API entries of one name: edit and removal act on the first, the later one only carries a note.

**phase-2e-iv**

- **2e-iv** Whole 7-row walk never walked; row 5 (a real MySQL connection built from the file's parts plus the kept password) needs a local server and has never run.
- **2e-iv** Removing a database keeps its Keychain item; it must be deleted by hand.
- **2e-iv** A legacy one-string database record is not split for the operator; Edit asks for the parts once. A changed user requires retyping the password.

**phase-3a-i**

- **3a-i** Journal noise: a watcher refresh is journalled as `ui`, so a busy repo writes entries the operator did not act on. Never measured or filtered.
- **3a-i** A pruned linked worktree as a project root is untested; after `git worktree prune` its `.git` file points nowhere.

**phase-3a-ii**

- **3a-ii** Signing never walked: a repository with `commit.gpgsign` and a pinentry prompt was not seen; walk repositories do not sign.

**phase-3a-ii-b**

- **3a-ii-b** With several cursors the Stage/Unstage button's enabled state follows only the main cursor, while the press stages every selection.
- **3a-ii-b** New files are named in the drafted commit message without their contents or line counts.
- **3a-ii-b** The draft's ⌘Z has no redo, and can outlive an org switch, restoring the old org's text.
- **3a-ii-b** The Stage/Unstage strip hides while the diff refreshes after each write instead of greying out.
- **3a-ii-b** Draft counts (`path +a -d`) are skewed by content lines that start with `--` or `++`.
- **3a-ii-b** Each repaint re-diffs the tab for the strip's enabled state; near 10,000 lines that is slow.

**phase-3a-v-a**

- **3a-v-a** Whole runbook never walked: all ten rows (Timeline, Load more, inline blame, Open Changes, Inline blame setting, agent blame question) have an empty Walked column.
- **3a-v-a** A rename commit ending a Timeline page opens without its old name (empty left side) until the next page loads.
- **3a-v-a** The blame hover shows the commit subject, not its body; body only in the row tooltip and the commit's tab.
- **3a-v-a** VoiceOver "scroll to bottom" on a long lazy list (Timeline, Search results) traps in SwiftUI and quits Wakil.

**phase-3a-v-b**

- **3a-v-b** Whole runbook never walked: all ten rows (merge, rebase, stash clash, Accept Current/Incoming/Both, Undo Apply, agent resolves) have an empty Walked column.
- **3a-v-b** Branch picker shows no spinner and Escape cannot cancel while a merge or rebase it started runs (Rules 4/5).
- **3a-v-b** Amend Last Commit stays enabled in the menu while conflicts remain.
- **3a-v-b** The Compare tab is not refreshed when the conflict changes; close and reopen it.
- **3a-v-b** An Accept moves the cursor to its block even when the cursor was elsewhere in the file.
- **3a-v-b** After a relaunch, or for a clash made in a terminal, there is no Undo Apply; resolve by hand.
- **3a-v-b** Undo Apply is offered only when the stash's files had no changes of your own before the apply.
- **3a-v-b** If the branch renamed a file the stash edits, Undo Apply leaves that file as git left it.
- **3a-v-b** Not built: three-way Merge Editor, Source Control Graph, starting a cherry-pick or revert, interactive rebase, `merge --squash`.

**phase-3b-i**

- **3b-i** Real Arabic input sources' own shortcuts walked on one layout switch only; other layouts and input methods untested. Cover also cannot press ⌘K/⌘P/⌘T under Arabic (harness sends US codes).
- **3b-i** Dirty tabs in another project or conversation: ⌘Q and org switch offer only Don't Save and Cancel; saving needs switching to that scope.
- **3b-i** Cover could not reach: saving tick and second ⌘S during a save, Cancel on a save, red close button, minimised-window ⌘Q, relaunch restore, highlighting, Compare that cannot read a file.

**phase-3b-ii**

- **3b-ii** Whole runbook never walked ("Not yet walked"): tree, search, find, replace, live update, relaunch restore rows.
- **3b-ii** The tree's selection is view-local, so `read_pane` does not report the highlighted row; only the walk sees it.
- **3b-ii** The 2,000-match note and 50,000-file note are walk-only and unseeded; caps pinned by Go and WakilKit tests only.
- **3b-ii** Cover could not reach: loading/busy ticks, a listing error, keyboard navigation and focus timing (↑↓ ←→ type-ahead, ⌘B), live update from a dispatched terminal command (#401).

**phase-3b-ii-b**

- **3b-ii-b** Operator walk (rows 1-9: replace preview, Replace All, undo, reveal, tab drag, middle-click, agent) never ticked; runbook says "Not yet walked".
- **3b-ii-b** Walk-only visuals never looked at: strike-through, violet preview, drop line, selected revealed row, disabled reveal tooltip, Replace field taking the keyboard.
- **3b-ii-b** Preview covers only 2,000 shown lines; Replace All past them unexercised (no fixture reaches it). Middle-click close and saved tab order after relaunch are walk-only.

**phase-3b-iii**

- **3b-iii** Nothing pins that choosing a changed file from ⌘P on a fresh session enters the conversation (`paletteOpensAPane` gained `editor_changes_select`).
- **3b-iii** Proof for `palette-open-kinds.jsonl` was stale after its edit and needed re-proving; not confirmed re-proved.

**phase-3b-iv**

- **3b-iv** Keystrokes doubled once after an agent renamed the open file (`ghi` read back `ghighi`, one act, run 20261017-154716); no cause proven.
- **3b-iv** macOS 14 Move to Trash error message (needs `/usr/bin/trash`, macOS 15) never seen; walk Mac is on 15.

**phase-3b-iv-b**

- **3b-iv-b** Whole icon walk (rows 1-10: glyphs, grey-white colour, no clipping, tabs, Changes, size) never ticked; no check can see the icons.
- **3b-iv-b** Font failing to load (no icons, tree file names shift 10 pt left) never exercised.

**phase-3b-ix**

- **3b-ix** Whole fast-path walk (rows 1-20, local llama-server and Claude path) never ticked; runbook says "Nothing here is walked yet".
- **3b-ix** `term_open`'s `path` kept only when it is a project root; otherwise the terminal opens where it would with no path.
- **3b-ix** A delete is caught only by its first word; "Please get rid of the drafts" still reaches the model.
- **3b-ix** File scope is the top 20 project files; a file outside the top 20 for every word sends the line to the agent.
- **3b-ix** Real Claude path costs quota and is hand-walked only; timing figures (0.1 s local, 1-2.5 s Claude) measured on one machine.

**phase-3b-v**

- **3b-v** A heavy-folder change made outside the Settings pane (hand-edited project.json, another window) re-lists nothing until next disk wake or project switch.
- **3b-v** Open search results are marked changed after a heavy-folder save, not re-run.
- **3b-v** The unsaved prompt's Save takes no save slot, so it can overlap a save in flight; Don't Save cannot stop a write already started.
- **3b-v** Git's diff web view still keeps the keyboard when the Git pane loses focus.
- **3b-v** A hand-set indentation (Monaco Change Indentation) is re-detected on any editor option change and lands on the project's values (Monaco 0.52.2).
- **3b-v** Cover could not reach: agent's write refusal (rows 10, 17), refusal texts, the two steppers, resign-active autosave, Compare releasing the keyboard, what Monaco draws.
- **3b-v** Cover could not reach: dimmed heavy/ignored rows, Rule 5 during an in-flight heavy-folder write, emptying a row or draft shifting on removal (Rule 6).
- **3b-v** `3b-v-editor-indent-scratch.jsonl` went red once in a full run (step 29), passed 2 of 2 alone.

**phase-3b-vii**

- **3b-vii** Walk rows 1-10 never ticked: log colours, folding, follow-stops-when-scrolled-up, open trace across appends, `> laravel.log` then append.
- **3b-vii** A log emptied and rewritten past its old length before the editor re-reads it shows a wrong splice until next shrink or reopen (accepted cost).
- **3b-vii** More than 2 MB written between two reads, and a binary chunk, are unit-tested only, never walked.
- **3b-vii** Typing in a small `.log` while a write lands: race predates 3b-vii, not walked.

**phase-3b-viii**

- **3b-viii** Whole walk unticked (Claude path rows 1-9, DB query line 10-13, local model, Settings): ghost-text feel and timings never walked by the operator.
- **3b-viii** Agent-origin `db_set_dsn` refreshes the schema vocabulary only while Settings is open, so ghost-text's schema cache can go stale mid-session.
- **3b-viii** The agent's own `ClaudeCodeCLIHarness.interrupt()` still sends SIGINT, which ends the `claude -p` process; the session may not survive an interrupt.
- **3b-viii** Real Claude path costs quota and is walk-only; a recycled session (every 20 operations) and 10-idle-minute stop are unit-tested against a fake only.

**phase-3c-i**

- **3c-i** Walk rows 1-10 never ticked (tabs, per-org profile isolation, relaunch, pop-up, find, download, camera prompt, inspector, clear data, org rm).
- **3c-i** A page's `beforeunload` question is not shown (WKWebView has no public hook); Interaction rule 1 unmet until WebKit offers one.
- **3c-i** A load that times out shows its error only after WebKit's own timeout, a minute or more.
- **3c-i** `wakil org rm` cannot delete the organisation's WebKit store; it names it and says to clear it in Settings first.
- **3c-i** A page's own question in a pane you are not in waits shown, without the keyboard: needs a click to answer.
- **3c-i** Unwalked: HTTP basic-auth prompt, file chooser, untrusted certificate, crashed page, failed download, link to an app the Mac lacks.

**phase-3c-ii**

- **3c-ii** Operator's own `.ui` acts in a page on a production site have no surface (Decision 48); needs a proposal `origin:` parameter and `parkAndAwait` support.
- **3c-ii** The site allow-list lives in memory: a reopened conversation or relaunch asks again. Until the config tree is read, every site counts as production.
- **3c-ii** Pages over 200 KB are cut, and frames are counted not read.
- **3c-ii** Unwalked residue: framework-controlled fields, open shadow roots, cross-origin frames, agent click on `target=_blank`, the colours, the 1 s quiet after typing, `lastOperatorInput` routing.

**phase-3c-iii**

- **3c-iii** Clearing browsing data then reloading open tabs writes those pages back into history (M-b).
- **3c-iii** A fragment change followed by a title change drops the new title from history; the history read is capped at 200 rows before ranking.
- **3c-iii** Keys sent with no gap (a script) can land after the completion, giving `youtube.comoutube.com`.
- **3c-iii** Long plain terminal output may draw slower since every row is scanned for links (M-d); `seq 1 200000` was never timed against main.

**phase-3d-i**

- **3d-i** None of the 18 walk rows (auto-groups, pinning, PR group, vertical column, AI naming, favicons, middle-click, tiles) was walked; Walked column is blank, Known section says "None yet".

**phase-3d-iii**

- **3d-iii** A `<video>` inside a shadow root is not found, so it does not float; ⌘H does not float.
- **3d-iii** Restore dock over SwiftUI's hosting view is proven only in plain AppKit; a pane rebuilt by a layout change may float briefly (unverified).
- **3d-iii** Floating relies on two WebKit private callbacks and one private preference; a macOS update could drop one and the setting turns itself off.

**phase-3d-iv**

- **3d-iv** Row 10 accepted not re-run after 9cc7b06; probe items open: (b) `security` prompt and exit status, (e) exact words after rebuild, (f) whether saved tab state ever holds a typed password.
- **3d-iv** A login form inside an iframe gets no key (ruling 11); the script watches the main frame only.
- **3d-iv** Every rebuild re-asks for each Keychain item (ad-hoc signature changes code hash); signing (2b-vii) removes it.
- **3d-iv** Ad-hoc signed, no hardened runtime: the agent's shell could `DYLD_INSERT_LIBRARIES` into Wakil (unmeasured) or run `Wakil --dispatch browser_password_save/_delete/_never` with no prompt. (security)
- **3d-iv** A password a site sends in a GET URL is not scrubbed from the tab URL, so the agent's read of the address can show it. (security)
- **3d-iv** A password under 6 characters shown as page text by a show-password toggle is not hidden in page text or labels (ruling 15). (security)
- **3d-iv** `wakil org rm` names saved passwords as residue and deletes none; Settings Copy leaves the password on the pasteboard for 90 s. (security)
- **3d-iv** Import receipt reads `Imported 1 passwords.` for one row; non-local http pages get no key and refuse fill.
- **3d-iv** Unwalked residue: Keychain prompt, LocalAuthentication, key pixels, framework-controlled logins (React), open shadow-root logins; Cover list in section 4 not run, machine walk "Not run yet".

**phase-conversations**

- **conversations** The whole 7-row walk is unwalked ("Not walked"): two live agents in one place, switching mid-turn, approval from chip and Running row, quit/relaunch into Continue, production red, five dot colours.

**phase-ticket-view**

- **ticket-view** after a failed record, Next or Link write, a retry takes a keystroke: Enter on the same text sends nothing.
- **ticket-view** a picked branch's read cannot be cancelled early; it stops at the 20 s limit.
- **ticket-view** a key no project of the organisation claims shows only "No ticket found", not which project key is missing.
- **ticket-view** linking does not read Jira's development panel (only an undocumented `dev-status` endpoint serves it); a PR whose head is in a fork is not matched; GitLab and Bitbucket PRs are not read.

**rail-collapse**

- **rail-collapse** Rows 4 to 8 unwalked: 6 pt right-edge peek strip, Reduce Motion crossfade, maximise while collapsed, collapsed state across relaunch, VoiceOver "Open panes" and agent `rail_set`.
- **rail-collapse** Hover peek, its timings, slide, release, Reduce Motion and relaunch persistence are walk-only; no check reaches them (`rail.edge` in `uncoverable.tsv`).

**ticket-work** (the umbrella design's pieces 4–6, designed 2026-10-25, not built)

- **ticket-work** the steps row: a repo's declared process (Design · Plan · Build 4/9 · …) in the Ticket header, a step done when its evidence exists, never by a hand tick; rulings counted in the header with Keep / Overrule (the record already stores `rulings`).
- **ticket-work** Then: after a merge, deploy or gate, one-click next moves — Run a CI dispatch (live, cancellable), Move the ticket, Draft a comment — from the repo's docs plus what the operator did last time; a time-tracking and presence footer when the organisation has those connections. Move waits on open question 15.
- **ticket-work** people, recall and cost: reviewers suggested from who reviewed the repo before; a Not done line waiting on a person with Draft message; **Similar before** in the hand-off brief from `wakil-recall` (not drawn until then); per-ticket agent runs, tokens and provider.
