# 3b-viii — quick tasks and ghost-text: acceptance

**Spec:** [`2026-10-19-3b-viii-ghost-text-design.md`](../superpowers/specs/2026-10-19-3b-viii-ghost-text-design.md)
· **Charter:** Decision 42; Decisions 14 and 16 amended

The exit criterion, from the spec: pausing in an editor tab or the DB query line shows dim
ghost text at the caret; Tab takes it. With nothing set it runs on the org's Claude account
(about 1.5 to 2.5 s, a pulse while it waits); with a `local` provider picked under **Quick
tasks** it lands in about 100 to 300 ms. **Ghost-text** in Settings turns it off.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run in the repo root, on this Mac, after `make build` and `make app-bundle`.

Local server (once; the first start downloads 1.5 GB):

```bash
brew install llama.cpp
llama-server --fim-qwen-1.5b-default --port 8012
```

Leave it running in its own Terminal window. Check it answers:
`curl -s http://127.0.0.1:8012/health` prints `{"status":"ok"}`.

Org and local provider (re-runnable; the org is `personal`, Claude account already linked):

```bash
export WAKIL_ORG=personal
./bin/wakil provider rm qwen || true
./bin/wakil provider add qwen --kind local --base-url http://127.0.0.1:8012 --label "Qwen 1.5B"
```

Do **not** set the org's Quick tasks yet: sections 1 and 3 walk the Claude default first.

Launch with `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`. Use a project whose active
environment has a SQL database with a `bookings` table (the `events` SQLite database of
`db-query-line-acceptance.md` works if it has one; otherwise any SQL environment). Open a project
with a few source files, and a DB pane on that environment.

Settings is ⌘, ; the org's choices are under the organisation node, Providers.

## 1. The walk on Claude (Quick tasks: Same as agent)

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Settings, organisation: read the **Quick tasks** row | **Same as agent** is selected. `qwen` is listed beside it | |
| 2 | Open a source file in an editor tab, put the caret at the end of a line, type `const x = ` and stop | A pulse shows at the caret after about 0.4 s; a dim suggestion replaces it after about 1.5 to 2.5 s | |
| 3 | Look at the suggestion and the pulse | The ghost text is dim cool white (about 34% opacity), starts exactly at the caret, and does not shift the text after it. The pulse is faint, at the caret, and gone when the text lands | |
| 4 | Press Tab | The suggestion becomes real text, the caret sits after it, the tab is marked unsaved | |
| 5 | Press ⌘Z | The whole accepted text goes in one step | |
| 6 | Type again to get a suggestion, then type any character | The suggestion is gone at once; a new request starts after the pause | |
| 7 | Get a suggestion, press Esc | It is dropped and does not come back until you type | |
| 8 | Get a suggestion, move the caret with an arrow key and no edit | The suggestion is dropped, and any request in flight is cancelled (no suggestion lands later at the old place) | |
| 9 | Open a peek (a gutter change mark) or Compare, with a suggestion showing, press Esc | The first Esc closes the peek or Compare as it did before 3b-viii; the suggestion does not make Esc do something else. Then check that Esc with a suggestion and no peek drops the suggestion | |
| 10 | In the DB pane's query line, with the caret at the end of `SELECT id, ` and the environment bound to a database with `bookings`, pause | A dim suggestion appears after the caret, same tone as the editor's. It names real columns when the line mentions the table (for example `FROM bookings`) | |
| 11 | In the query line, put the caret in the middle of a line, pause | No request, no suggestion. At the end of the line, it asks | |
| 12 | In the query line with a suggestion showing: Tab | The suggestion is inserted. Tab on an empty line, or with nothing showing, still leaves the line | |
| 13 | In the query line, Return with a suggestion showing | The typed text runs; the suggestion is never accepted and never run | |
| 14 | In the query line, Esc with a suggestion showing | The suggestion drops and focus stays; a second Esc cancels a running read, else leaves the line | |
| 15 | In the query line, type a multi-line query and pause at the end of its last line; then pause at the end of an earlier line | Asks only at the end of the whole text; an earlier line end asks nothing | |
| 16 | In the query line, start a request and watch the caret for more than 0.4 s | The pending pulse shows, drawn like the editor's; it stops when the suggestion lands or you type | |
| 17 | Open a terminal pane and type | No suggestion, no pulse | |
| 18 | Open a diff, a tail or an over-cap file and put the caret in it | No request (read-only tabs never ask) | |
| 19 | Settings, Editor: set **Ghost-text** to Off, then type in an editor tab and the query line | Nothing appears in either. Set it On again and it returns | |

## 2. The walk on the local model (Quick tasks: Qwen 1.5B)

Select `Qwen 1.5B` in the **Quick tasks** row first.

| # | Do | Expect | Walked |
|---|---|---|---|
| 20 | Settings, Providers: read the `qwen` row under **LOCAL MODELS** | URL `http://127.0.0.1:8012`; **Serves** has *Code completion* ticked and *Instructions* unticked; the *Code completion* box is greyed out (the last ticked one cannot be unticked); a status line reads *not tried yet* until a suggestion is asked, then *reachable* | |
| 21 | Type in an editor tab and pause | A suggestion lands in about 100 to 300 ms after the 250 ms pause; the pulse (0.4 s) never shows | |
| 22 | In the DB query line, type `SELECT id, ` after naming `bookings`, pause | A suggestion with real `bookings` columns | |
| 23 | Tab, Esc, typing and ⌘Z behave as in rows 4 to 8 | Same results | |
| 24 | Stop the server (Ctrl-C in its Terminal), then type and pause in the editor | The suggestion still arrives once, from Claude (the one fallback), after about 2 s. In Settings the `qwen` status line, and the line under the **Quick tasks** row, show the connection error whole, not shortened; stderr has one `quick-tasks: qwen:` line for it | |
| 25 | Start the server again, type and pause | The suggestion comes from the local model again (fast), and the status line goes back to *reachable* | |
| 26 | Quick tasks back to **Same as agent**, then to `Qwen 1.5B` | Each change takes effect on the next suggestion; no restart needed | |

## 3. The walk of the Settings screen

| # | Do | Expect | Walked |
|---|---|---|---|
| 27 | Open Settings, Providers | **QUICK TASKS** row shows the choices as one segmented control, **Same as agent** first; **LOCAL MODELS** below it lists local providers, then **Add local model** | |
| 28 | Look at the layout and the accessibility ids (Accessibility Inspector) | `settings.org.quickProvider.same`, `settings.org.quickProvider.qwen`, `settings.localProvider.add`, `settings.localProvider.qwen.url`, `.serves.infill`, `.serves.respond`, `.status` are present | |
| 29 | Click **Add local model** | A new row appears with an empty URL field, focused, with *Code completion* ticked and *Instructions* unticked; **Add local model** is disabled | |
| 30 | Press Esc with the new row empty; click **Add local model** again and click elsewhere | The empty row goes away both ways and **Add local model** comes back; nothing was saved | |
| 31 | Add a row, type `http://127.0.0.1:8012`, press Return | The row stays and is saved as `local`; its status line shows | |
| 32 | Tab to a *Serves* checkbox and press Space | The checkbox takes focus from the keyboard and toggles; the change is saved (reopen Settings to confirm) | |
| 33 | Try to untick both Serves boxes; then type a URL like `ftp://x` | The last ticked box is greyed out and cannot be unticked. The URL gets a refusal in the warning colour, said whole, under the row; what you typed stays on screen | |
| 34 | Set Quick tasks to a provider, then unlink that provider (`WAKIL_ORG=personal ./bin/wakil provider rm qwen`) | The row falls back to **Same as agent**; nothing crashes | |

## 4. Known and not fixed

- **A code-only local model takes ghost-text; every `respond` task goes to Claude.** With the
  default `Serves`, no `respond` caller exists yet in 3b-viii, so this is untested by hand.
- **Agent-origin `db_set_dsn` refreshes the schema vocabulary only while Settings is open**
  (`WindowModel.swift`, about L1093 to L1096). Ghost-text's schema cache is refreshed on
  environment switch, so a DSN the agent changed mid-session can leave the schema stale until
  the next switch. Found during the build, not part of this sub-phase.
- **`ClaudeCodeCLIHarness.interrupt()` sends SIGINT.** Measured during this build, SIGINT ends a
  `claude -p` stream-json process, where a stream-json `control_request` keeps it alive.
  `ClaudeCodeQuickModel` uses the control request; the agent's interrupt may not keep its
  session. Found during the build, not fixed here.
- **`make e2e`'s coverage gate is red on `ctx_set_local_provider`**: a registry action added by
  this sub-phase with no e2e check yet. That is the e2e auditor's rung (**Cover**), not this one.

## 5. Residue: what the walk cannot establish

- **The real Claude path is walked by hand and costs quota.** No check spends it; the e2e
  auditor uses a stub `/infill` server on loopback.
- **Timing figures** (1.5 to 2.5 s on Claude, 100 to 300 ms local) are the spec's measurements on
  one M5 Pro; the walk confirms they feel that way, not that they hold on other machines.
- **A recycled `claude` session** (every 20 operations) and **10 idle minutes** stopping it are
  pinned by `ClaudeCodeQuickModelTests` against a fake process; a walk would need an hour.
