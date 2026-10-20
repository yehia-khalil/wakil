# 3b-ix: the fast path — one-line composer commands without an agent turn

**Date:** 2026-10-20
**Status:** design approved by the operator 2026-10-20
**Sub-phase:** 3b-ix, the next quick task named in Decision 42. Follows 3b-viii (main 2a491bf).

---

## Problem

Every line sent from the composer, typed or spoken, is an agent turn: 5 to 10 s before
anything happens, and quota spent, even for "switch to staging" or "open confirm.go" — the
commands an operator gives most. 3b-viii built the quick-model seam with a `respond` operation
for exactly this; nothing calls it yet.

Decision 10 stands in the way as written: *"Building a voice grammar or intent parser is the
failure mode to avoid."* A model that turns a line into an action is an intent parser, so this
sub-phase amends Decision 10 first, narrowly.

Measured on the operator's Mac (M5 Pro, 2026-10-20), llama-server, Q4_K_M, prompt cache warm,
17 navigation actions and a project's names in the prompt, 16 lines plus 16 held-out lines:

| Model, prompt | Ghost-text median | Fast-path median | Right of 16 (test / held-out) | Wrong but valid |
|---|---|---|---|---|
| Qwen2.5-Coder-1.5B base (3b-viii's default) | 197 ms | 252 ms | 7 / — | 8 |
| Qwen2.5-Coder-1.5B-Instruct, rules only | 136 ms | 204 ms | 10 / — | 5 |
| **Qwen2.5-Coder-1.5B-Instruct, rules + worked examples** | **134 ms** | **113 ms** | **14 / 12** | **1 / 2** |
| Qwen2.5-Coder-7B-Instruct, rules + worked examples | 433 ms | 340 ms | 16 / 14 | 0 / 1 |

- Worked examples in the prompt mattered more than model size (10 → 14 on the 1.5B).
- Every wrong-but-valid answer seen was a read or an open (describe instead of read, read
  instead of open). The allowed list holds no writes, so the worst case is one Esc.
- The 1.5B sometimes invents a file that is not in scope; the name check below rejects it.
- The 7B is more accurate but puts ghost-text at ~430 ms, past 3b-viii's 100 to 300 ms.
- Claude's warm session answers `respond` in 1.0 to 1.8 s (Decision 42's measurement).

## Decisions the operator took during this design (2026-10-20)

- **In the composer**, not the ⌘K palette: the composer is the slow path, and voice lands there.
- **Navigation only.** A fixed list of 26 actions (below). `ActionKind.control` is not the line:
  it also holds configuration changes (`ctx_unlink_provider`, `db_set_dsn`, `ctx_add_provider`)
  and `term_run`.
- **Run at once, with a receipt** and *Ask the agent instead*. Rule 1: nothing on the list
  destroys.
- **The model proposes; Wakil checks.** The action is on the list, its params fit its schema,
  every name it uses exists. Anything else goes to the agent unchanged.
- **Recommended local model: Qwen2.5-Coder-1.5B-Instruct**, one model for ghost-text and the
  fast path. The 7B stays an option for an operator who accepts slower ghost-text.
- **The model sees the top 20 file matches** for the line, not the whole project.
- **One model per org stays** (Decision 42), and it does every quick task. The per-provider
  *Code completion* / *Instructions* checkboxes go; each feature gets an on/off switch beside
  the model, in one place.
- **Fast path defaults on only when the model is a local one.** On *Same as agent* it would add
  1 to 1.8 s and quota to every agent turn, so it defaults off there; the operator may turn it on.
- **A deadline** of 300 ms on a local model and 2.5 s otherwise (Ruling R1, plan 2026-10-20) on the
  model's answer; past it the line goes to the agent.
- **Voice is covered by the composer path** (dictation lands there, Return sends). Voice
  cleanup stays an unscheduled candidate.

## What the operator gets

- Return in the composer on *switch to staging* changes the context line in about 0.1 s on the
  local model. No agent turn starts.
- Under the composer, a receipt: *Ran: switch environment to staging · Ask the agent instead*.
  *Ask the agent instead* sends the original line to the agent as a normal turn.
- A line the fast path does not take — a question, a change, a fix, a delete, anything naming
  something not in scope, a late or malformed answer — goes to the agent exactly as today, about
  0.1 s later on a local model.
- An action the handler refuses (closing a tab with unsaved edits) shows its refusal whole in
  the receipt (Rule 8), with *Ask the agent instead*.
- Settings → Providers, under QUICK TASKS: **Model**, **Ghost-text**, **Fast path**.

```
QUICK TASKS
Model         local ⌃⌄          Code completion goes to local
Ghost-text    ● On              suggestions as you type
Fast path     ● On              one-line commands without the agent
──────────────────────────────────────────────────────────────
LOCAL MODELS
local         http://127.0.0.1:8012   • reachable          REMOVE
```

## What it does not do

- No writes, no configuration change, no shell command, no query run, no API send.
- No grammar, no keyword table, no voice-only path: one string, one path (Decision 10, kept).
- No agent turn started in parallel and cancelled: a started turn has spent quota and may act.
- No change to the ⌘K palette.
- No voice cleanup, no natural-language SQL, no status lines (later quick tasks).

## Design

### The allowed list — `WakilKit/App/FastPath.swift`

26 actions, each with the params the model may set. Every other param is dropped before dispatch;
`discard` is never sent, so a pane or tab with unsaved edits stays open and says so.

| Area | Actions |
|---|---|
| Editor | `editor_open`, `editor_goto`, `editor_search`, `editor_find`, `editor_tree_reveal`, `editor_new_scratch`, `editor_close`, `editor_focus_tab`, `editor_changes_select`, `editor_set_language` |
| Context | `ctx_set_environment`, `ctx_set_project` |
| Database | `db_read_table`, `db_describe_table`, `db_list_tables`, `db_page`, `db_refetch` |
| Panes | `pane_open`, `pane_focus`, `pane_close`, `pane_maximize`, `pane_restore`, `pane_sort` |
| Other | `term_open`, `api_open`, `settings_open` |

Kept from the list on purpose: `session_resume` (ends the session), `api_cancel` (a cancelled
write's fate is unknown), `db_cancel` (one click already), `api_reopen` (needs Recent row ids),
`editor_peek` (needs a marked line).

A test pins the list against the registry: every name exists, and none is `.mutate`.

### The prompt and the scope

One system prompt, built per line:

- The rules: one action only if the line asks for exactly one and every name is in scope;
  otherwise `agent`. Questions, changes, fixes and deletes are always `agent`. Never invent a
  name.
- The 26 actions with their params.
- Fixed worked examples (about nine, as measured), including four that answer `agent`.
- The scope:
  - files: the top 20 of the active project's files. Each word of the line is ranked with the
    same file entries and matcher ⌘P uses (`PaletteSearch.rank`), and the per-word lists are
    interleaved. ⌘P's matcher needs every word to match, so ranking the whole line would match
    nothing;
  - in full: projects of the org, environments of the active project and the active one, tables
    of the active environment's databases (the vocabulary ghost-text already reads), open panes
    (id, kind, title), API entries of the active environment.

The rules, the action list and the examples come first and never change within a window, so the
server's prompt cache holds them; only the scope and the line vary.

The answer is constrained by a JSON schema: `{"action": <one of the 26 or "agent">, "params": {}}`.

### `FastPath` — route one line

```swift
public enum FastPathRoute: Sendable, Equatable {
    case action(name: String, params: JSONValue)
    case agent
}
public struct FastPath: Sendable {
    public func route(_ line: String, scope: FastPathScope) async -> FastPathRoute
}
```

- Calls `QuickTasks.respond` with the prompt and the schema, under a deadline of 300 ms on a local
  model and 2.5 s otherwise (Ruling R1). The deadline
  cancels the request.
- Checks, in order; the first that fails answers `.agent`:
  1. the reply parses and matches the schema;
  2. the action is on the list (`agent` answers `.agent`);
  3. the params fit that action's registry schema, after dropping params not on the list;
  4. every name param is in scope exactly: `path` among the files sent (except `term_open`, whose `path` is a directory and is not checked
     against the file scope), `name` among the projects
     or environments, `table` among the tables, `id` among the open panes, `entry` among the API
     entries.
- Never throws to the composer: a model error, a timeout or a refusal is `.agent`, and the
  model's error is kept for Settings as ghost-text's is (Rule 8).

### Routing — one model, both features (amends Decision 42)

- `QuickTasks` routes every operation to the org's `quickProvider` when set, else the active
  provider, with the existing single fall-back to the active provider when a local endpoint
  fails. A local provider serves both `infill` and `respond`.
- `Provider.Serves` is no longer read. Records that carry `serves` still load; the field is
  ignored and dropped on the next write.

### Go — `internal/wakilcore`

- `Org` gains `GhostText *bool` and `FastPath *bool` (nil is the default). `ctx_update_org`
  writes both, with the same read-modify-write as the other org fields.
- Defaults, computed in one place and sent on `config_tree` as resolved booleans:
  - `ghostText`: the org's value, else the app-wide `editor.ghostText` (so an operator who turned
    it off keeps it off), else on;
  - `fastPath`: the org's value, else on when `quickProvider` names a `local` provider, else off.
- The app-wide `editor.ghostText` is read only as that fallback; Settings no longer writes it.
- `ctx_set_local_provider` stops taking `serves`.

### Composer — `ComposerModel.submit`

1. The line is trimmed and the draft cleared, as today.
2. If fast path is on for the org and quick tasks are built: `FastPath.route(line, scope:)`.
3. `.action`: dispatch through the registry with origin `.ui` and the operator as caller — the
   same action a click dispatches (Invariant 2). The journal records the dispatch with
   `via: "fastPath"`. The receipt shows what ran, in words from the action and its params.
   The composer keeps focus (Rule 6); the action's own effect (a pane opened, an environment
   switched) is what was asked.
4. A dispatch refused or thrown: the receipt shows the error whole and *Ask the agent instead*.
5. `.agent`: `window.send(line, via:)`, unchanged.
6. *Ask the agent instead* sends the original line through `window.send` and clears the receipt.
   The receipt also clears on the next send or on Esc in an empty composer.

### WakilApp

- `ComposerBar`: the receipt line, `composer.fastPath.receipt` and
  `composer.fastPath.askAgent`.
- `SettingsPane`, Providers: QUICK TASKS becomes three rows — **Model** (the 3b-viii dropdown,
  unchanged), **Ghost-text** and **Fast path** switches (`settings.org.ghostText`,
  `settings.org.fastPath`), each with a one-line hint. A default shown comes with why: *On: the
  model is local* / *Off: on Same as agent each line would wait for Claude first*.
- `LocalProviderRow` loses the two checkboxes.
- Settings → Editor loses its Ghost-text row.

### Interaction rules

- **Rule 1:** nothing on the list destroys, so nothing is confirmed. `discard` is never sent.
- **Rule 2:** the composer's line is never lost: an `.agent` route sends it; a refused action
  keeps it in the receipt with *Ask the agent instead*.
- **Rule 4 and 5:** the wait is at most 300 ms on a local model, 2.5 s otherwise, and shows nothing; the composer cannot send twice
  meanwhile (the draft is already cleared, as today).
- **Rule 6:** the composer keeps focus after a fast-path action.
- **Rule 8:** a refusal is shown whole in the receipt; a model error is shown whole in Settings.
- **Rule 9:** the switches' defaults suggest and are overridable either way.

## Errors and edges

| Case | Result |
|---|---|
| Local server down | `respond` fails fast, the line goes to the agent; Settings shows the error whole |
| Model slower than its deadline (300 ms local, 2.5 s otherwise) | the request is cancelled, the line goes to the agent |
| Malformed or off-schema reply | agent |
| Name not in scope (invented file) | agent |
| A file outside the top 20 | the model cannot name it: agent |
| Unsaved tab or pane on close | the handler's refusal in the receipt, nothing closed |
| No project, no environment | those scope sets are empty; actions needing them go to the agent |
| Quick tasks not built (no provider) | fast path skipped, the line goes to the agent |
| Switching org mid-request | the answer is dropped (the generation check ghost-text uses); the line goes to the agent |
| Production | `ctx_set_environment production` runs as the operator's own click does; the receipt names it |

## Testing

- **Unit (WakilKit, fake `QuickModel`):** each check refuses to agent; the deadline; `discard`
  stripped; names exact; the top-20 pre-filter; receipt wording per action; the org-generation
  drop; *Ask the agent instead* sends the original line.
- **Pin test:** the 26 names exist in the registry and none is `.mutate`.
- **Go:** `ghostText` / `fastPath` on `ctx_update_org` and their defaults; `serves` ignored on
  load and dropped on write; the app-wide fallback for `ghostText`.
- **e2e (seeded):** the stub endpoint on loopback gains `/v1/chat/completions` answering canned
  JSON. Checks: a line runs `ctx_set_environment` and shows the receipt; a reply naming a file not
  in scope goes to the agent; a refused `editor_close` shows its refusal; a reply after the
  deadline goes to the agent; the two switches write the org and parity with `ctx_update_org`.
- **Walk:** on Qwen2.5-Coder-1.5B-Instruct, typed and dictated lines, including a voice line with
  a mistranscribed file name.

## Charter changes this sub-phase makes

- **Decision 10, amended:** *Amended 2026-10-20 (3b-ix): one bounded exception, the fast path.*
  A line sent from the composer, typed or spoken (the same string through the same path), may
  first be offered to the org's quick-tasks model. The model may answer with exactly one action
  from a fixed list of 26 navigation actions, and no writes. Wakil runs it as the operator's own
  dispatch only if the action is on the list, its params fit the schema and every name it uses
  exists. Anything else, a late answer (past 300 ms on a local model, 2.5 s otherwise) or any doubt sends the line to the agent
  unchanged. There is still no grammar and no voice-only path. *Reverse if:* operators often have
  to undo what the fast path ran.
- **Decision 42, amended:** one model per org does every quick task; a `local` provider is a URL
  and serves both operations (the *serves* checkboxes are removed); each quick task has an on/off
  switch beside the model, per org. The fast path is built; next is agent status lines.
- **PRODUCT.md** (voice paragraph): a line Return sends may run one navigation action at once.
- **Runbook:** `docs/wakil/phase-3b-ix-acceptance.md`.
