# 3b-ix — the fast path: acceptance

**Spec:** [`2026-10-20-3b-ix-fast-path-design.md`](../superpowers/specs/2026-10-20-3b-ix-fast-path-design.md)
· **Charter:** Decision 10 amended (the fast path); Decision 42 amended

The exit criterion, from the spec: Return in the composer on a one-line navigation command
(*switch to staging*) runs it at once on the org's quick-tasks model, about 0.1 s on a local
model, with a receipt under the composer and **Ask the agent instead**. Anything else goes to the
agent as before. **Fast path** in Settings turns it off.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run in the repo root, on this Mac, after `make build` and `make app-bundle`.

Local server (once; the first start downloads the model):

```bash
brew install llama.cpp
llama-server -hf Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M --port 8012 -c 8192
```

Leave it running in its own Terminal window. Check it answers:
`curl -s http://127.0.0.1:8012/health` prints `{"status":"ok"}`.

Org and local provider (re-runnable; the org is `personal`, Claude account already linked):

```bash
export WAKIL_ORG=personal
./bin/wakil provider rm local || true
./bin/wakil provider add local --kind local --base-url http://127.0.0.1:8012
```

Launch with `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`. Use a project with a
`staging` environment next to the active one, a source file `confirm.go` and no `orders.go`, and
a SQL environment with a `bookings` table. Open a DB pane and an editor tab with unsaved edits
ready for row 10.

Settings is ⌘, ; **QUICK TASKS** and **LOCAL MODELS** are on the organisation's Providers page.

## 1. The walk

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Settings, Providers: read **QUICK TASKS** | Three rows: **Model** (dropdown: Same as agent, Accounts, Local models; *Code completion goes to …* under it), **Ghost-text** and **Fast path**, each an Off/On choice with a one-line hint. **LOCAL MODELS** rows have no checkboxes. Settings, Editor has no Ghost-text row | |
| 2 | Look at the accessibility ids (Accessibility Inspector) | `settings.org.quickProvider`, `settings.org.ghostText.off` and `.on`, `settings.org.fastPath.off` and `.on` are present | |
| 3 | With **Model** on Same as agent, read **Fast path** | **Off** is chosen (it defaults on only for a local model). Set **Model** to `local`: **Fast path** is **On** unless you set it before | |
| 4 | **Model**: `local`, **Fast path**: On. In the composer type `switch to staging`, Return | The context line changes to staging at once (about 0.1 s). No agent turn starts. A receipt shows under the composer: *Ran: switch environment to staging*, with **Ask the agent instead** | |
| 5 | Type `open confirm.go`, Return | `confirm.go` opens in an editor tab; receipt *Ran: open confirm.go*. The composer keeps focus | |
| 6 | Type `go to line 40`, Return | The editor caret goes to line 40; the receipt says so | |
| 7 | Type `show bookings`, Return | The DB pane shows the `bookings` table; the receipt says so | |
| 8 | Type `close the db pane`, Return | The DB pane closes, with no confirmation; the receipt says so | |
| 9 | Type a question (`why is checkout slow?`), Return | No receipt. An agent turn starts as it did before 3b-ix, about 0.1 s later | |
| 10 | Type `delete the draft bookings`, Return | No receipt, no action: the line goes to the agent as a normal turn (deletes are never on the list) | |
| 11 | Type `open orders.go`, Return (no such file) | No receipt: the line goes to the agent, which says it cannot find the file | |
| 12 | After row 4, click **Ask the agent instead** | The original line (`switch to staging`) is sent to the agent as a normal turn; the receipt goes | |
| 13 | After any receipt, press Esc in the empty composer | The receipt clears. Esc with text in the composer leaves the receipt | |
| 14 | With the editor tab that has unsaved edits focused, type `close this tab`, Return | The tab stays open. The receipt shows the refusal whole, in the warning colour, with **Ask the agent instead**; the line is not lost | |
| 15 | Stop the server (Ctrl-C in its Terminal), type `switch to staging`, Return | The line goes to the agent unchanged; Settings shows the connection error whole under the **Model** row | |
| 16 | Start the server again, repeat row 4 | The fast path runs it again; the error is gone | |
| 17 | Set **Fast path** to **Off**, type `switch to staging`, Return | No fast path: the line is an agent turn at once, no receipt. Set it **On** again and row 4 works | |
| 18 | Set **Model** to Same as agent and **Fast path** to On, type `switch to staging`, Return | It works on the Claude account, about 1 to 2.5 s with nothing shown while it waits; past 2.5 s the line goes to the agent | |
| 19 | Hold ⌥ and say a file name the speech model garbles (for example "open confirm dot go" heard as *open con firm go*), release, press Return | If the name is not an exact file in scope, the line goes to the agent, which resolves it as before; nothing wrong is opened | |
| 20 | Type `switch to staging`, press Return, and at once switch the project or environment in the context line | The fast path sends nothing; the line still goes to the agent of the place it was typed in | |

## 2. Known and not fixed

- **`term_open`'s `path` is a directory** and is not checked against the file scope; only the
  other name params are checked against what was sent.
- **File scope is the top 20 of the project's files**, gathered by ranking each word of the line
  with ⌘P's matcher and interleaving the lists. A file outside the top 20 for every word is out of
  scope, so the line goes to the agent.
- **A warm-up request runs after each quick-tasks rebuild**, so the first line after a Settings
  change is not slower than the rest. It is not shown anywhere.

## 3. Residue: what the walk cannot establish

- **The real Claude path is walked by hand and costs quota.** The e2e auditor uses a stub
  server on loopback.
- **Timing figures** (0.1 s local, 1 to 2.5 s on Claude) are the spec's measurements on one
  M5 Pro; the walk confirms they feel that way, not that they hold on other machines.
- **What the model answers for lines not in the examples** varies with the model; the checks
  pin the code that gates the answer, not the answer.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

Not generated yet: run `make e2e-runbook`.

<!-- /machine-walk -->
