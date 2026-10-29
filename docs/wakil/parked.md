# Parked issues

Twenty-nine issues closed `not planned` on **2026-09-26**, when the workflow moved to
five rungs and the tracker became a bug inbox
(`docs/superpowers/specs/2026-09-26-workflow-superpowers-migration-design.md`).

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
Its agenda is answered by `docs/superpowers/specs/2026-10-23-conversations-design.md`; each item
below points at the call there that answers it.

- **#78** — Track — two tickets in one window, without a second window *(the map)* → answered: calls 1–2
- **#79** — What a Track is, and where its boundaries fall → answered: calls 1–2
- **#80** — Does switching to a Track fork its session, and can Wakil afford that? → answered: call 3
- **#82** — Does the agent know about Tracks? → answered: call 5
- **#83** — What the Track switcher looks like, and where it lives → answered: "What the operator gets" items 2–4
- **#84** — Where Track state lives on disk → answered: call 7
- **#85** — What happens to an in-flight turn when the operator switches Track → answered: call 4
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
`docs/superpowers/plans/2026-09-26-phase-2c-iv-api-client-pane.md`. They are not
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
- **2c-ii** — D1 (one of thirteen walk defects) deliberately unfixed; reason in the fix round's spec §13.
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
- **3a-ii-b** — `api-unbind.jsonl` and `bg-agent-chip-over-landing.jsonl` are red on main, with no issue.
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
