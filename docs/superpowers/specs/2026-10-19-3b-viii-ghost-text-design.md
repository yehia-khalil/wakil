# 3b-viii: quick tasks, and AI ghost-text as the first — on the org's provider, or a local model

**Date:** 2026-10-19
**Status:** design approved by the operator 2026-10-19, in two parts
**Sub-phase:** 3b-viii, which follows 3b-vii (main 8ebeb01). It waits on nothing.

---

## Problem

Autocomplete's third tier — AI ghost-text with project and schema context — is the editor's stated
edge over generic completion (design-language §11, Decision 17, PRODUCT.md), and none of it exists.
Wakil's only route to a model is an agent session, which is shaped for conversations, not for a
suggestion after every pause.

Measured on the operator's Mac (M5 Pro, 48 GB, 2026-10-19), same prompts:

| Route | Per suggestion | Quality |
|---|---|---|
| `claude -p --model haiku`, one-shot | ~4.5 s | good |
| Warm `claude` stream-json session, one turn each | 1.0–1.8 s (2.9 s first) | good |
| Apple FoundationModels, on-device | 0.26–1.2 s | poor: echoes the line, answers `begin` to a Go loop |
| `llama-server` `/infill`, Qwen2.5-Coder 1.5B Q8, schema as `input_extra` | **30–210 ms** warm | good, schema-aware |

With the `bookings` schema in the prompt the local model wrote `b.ConfirmedAt = time.Now()`,
`$booking->status = 'confirmed';` and the real column list after `SELECT id, `. Calling the
Anthropic API with the subscription's OAuth token would be faster still, and Anthropic's terms forbid
it; it stays excluded with the rest of §5's non-goal.

## Decisions the operator took during this design (2026-10-19)

- **Automatic.** A suggestion appears after a pause in typing; no key to ask for one.
- **Context: the file, plus the active environment's schema** for tables the file names. The ticket
  is a later sub-phase.
- **Schema rule:** table names found in the file — singular or plural, snake or camel case
  (`Booking`, `bookings`, `booking_id` → `bookings`) — send the columns of at most five tables. No
  match, or no DB binding for the environment, sends the file alone.
- **Everything runs on the org's selected provider by default.** A local model is optional: the
  operator may name another provider for quick tasks. Nothing is installed by Wakil.
- **One quick-tasks provider per org**, not one per task. Ghost-text follows it now; the ⌘K fast
  path and agent status lines will follow it later.
- **The operator runs the local server; Wakil points at a URL.** No process supervision, no model
  download in Wakil.
- **Build the seam for every quick task now, not for ghost-text alone.** Later tasks add a caller —
  a prompt and a parser — and never rework the harness. So both operations below ship and are tested
  in 3b-viii, with ghost-text as the first caller of one of them.
- **Scope:** the quick-model seam (both operations, routing by what a provider serves), the provider
  setting, and ghost-text in the editor and the DB query line. The ⌘K fast path (which needs Decision 10 amended) and agent status lines are their own
  sub-phases, next in that order. Shrinking what the agent reads, titles and drafts, and voice
  cleanup are recorded in Decision 42 as candidates, not scheduled.

## What the operator gets

- Typing in an editor tab or the DB query line and pausing shows dim ghost text at the caret. Tab
  takes it; typing over it or Esc drops it.
- With no quick-tasks provider set, it runs on the org's active Claude provider: ~1.5–2.5 s after the
  pause, on the subscription's quota. A faint pulse at the caret says one is coming.
- Settings → organisation → **Quick tasks: Same as agent ▾** lists the org's providers. Adding a
  `local` provider asks for a URL (`http://127.0.0.1:8012`). Picked, suggestions land in about
  100–300 ms and cost nothing.
- Settings → Editor → **Ghost-text** switches it off everywhere.

Running the local option, once: `brew install llama.cpp`, then
`llama-server --fim-qwen-1.5b-default --port 8012` (downloads 1.5 GB on first start).

## What it does not do

- No ticket context, no multi-file context beyond the schema, no "next edit" suggestions.
- No suggestion in a terminal pane: the shell's line belongs to readline (Terminal screen, "the live
  prompt").
- Wakil does not start, stop, install or update a local model server.
- The agent cannot see or accept a suggestion: it is not pane state (below).

## Design

### Seam — `WakilKit/Harness/QuickModel.swift` (amends Decision 16)

Two operations cover every quick task named so far: filling a gap in code, and answering an
instruction about some input.

```swift
public enum QuickOperation: String, Sendable, CaseIterable { case infill, respond }

public struct InfillRequest: Sendable, Equatable {        // ghost-text
    public var prefix: String        // ≤ ~1,500 tokens before the caret, cut at a line start
    public var suffix: String        // ≤ ~500 tokens after, cut at a line end
    public var path: String          // project-relative; the query line sends "query.sql"
    public var language: String      // editorLanguage(forPath:)
    public var extras: [QuickExtra]  // named texts; ghost-text sends the schema as "schema.sql"
    public var multiline: Bool       // caret on an empty line
}

public struct RespondRequest: Sendable, Equatable {       // ⌘K fast path, status lines, titles, …
    public var instructions: String  // what to do, said once per task
    public var input: String         // what to do it to
    public var jsonSchema: String?   // nil: plain text back; set: one JSON value matching it
    public var maxTokens: Int
}

public protocol QuickModel: Sendable {
    var serves: Set<QuickOperation> { get }
    func infill(_ request: InfillRequest) async throws -> String     // cancellable
    func respond(_ request: RespondRequest) async throws -> String   // cancellable
}
```

A model asked for an operation it does not serve throws `QuickModelError.unsupported`; routing
(below) never asks it. **`QuickTasks`** is the one entry point callers use: `infill(_:)` and
`respond(_:)` pick the model, apply the fallback, and own cancellation, so a later task is a caller
of `QuickTasks.respond` and nothing more.

Two implementations, both in `Harness/`, and nothing above them names a model (Invariants 1, 11):

- **`ClaudeCodeQuickModel`** — one warm `claude` process per provider, launched through
  `buildLaunch`'s environment whitelist with `--model haiku`, `--tools ""`, `--strict-mcp-config`
  with no servers, `--no-session-persistence` and one task-neutral `--system-prompt`: do exactly what
  the turn asks and reply with the result only. Serves both operations. **infill** is one user turn
  with the extras, then the code with `<CURSOR>` between prefix and suffix, and "reply with only the
  text to insert". **respond** is one user turn with the instructions, then the input; when
  `jsonSchema` is set the turn carries the schema and "reply with one JSON value matching it", and
  the reply is parsed and validated — a reply that fails is re-asked once with the error, then the
  call throws. (`--json-schema` is fixed at launch, so one warm process cannot take it per request.)
  Every 20 turns it is replaced by a spare already started, so a restart never costs a cold
  start. Started on the first request, stopped after 10 idle minutes, on org switch and on quit.
  One turn at a time: cancelling a request interrupts its turn, and any reply that still arrives is
  dropped, so the next request never queues behind a stale one.
- **`LocalEndpointQuickModel`** — HTTP to the provider's `baseURL`, serving what the provider record
  says it serves. **infill:** `POST /infill` with `input_prefix`, `input_suffix`, `input_extra`,
  `cache_prompt: true`, `temperature: 0`, `n_predict` 64 (128 when multiline) and `stop: ["\n"]`
  unless multiline. **respond:** `POST /v1/chat/completions` (the OpenAI shape llama-server and
  Ollama both speak) with the instructions as the system message, the input as the user message,
  `max_tokens`, `temperature: 0`, and — when `jsonSchema` is set —
  `response_format: {type: json_schema}`, so the server constrains the output; the reply is still
  validated. Cancelling cancels the HTTP task.

`QuickModels.make(for: Provider)` returns the first for `claude-code`, the second for `local` with a
`baseURL`, and nil otherwise (a `codex` provider has no quick model).

**Routing, per call:** the org's `quickProvider` if its model serves the operation, else the active
provider if its model does, else `QuickModelError.noProvider` — which ghost-text shows as nothing,
and Settings as "Ghost-text needs a Claude or local provider". A code-only local model therefore
takes ghost-text and every `respond` task goes to Claude with no further setting.

### Go — `internal/wakilcore`

- **`Provider.BaseURL`** (`baseURL`), accepted only on kind `local` and required there for quick
  tasks; an `http`/`https` URL, stored normalised. `capacity` already reports `local` as having no
  limits.
- **`Provider.Serves`** (`serves`), on kind `local` only: which of `infill` and `respond` the
  endpoint's model is fit for. The operator says so because a server cannot: a code model answers a
  chat request badly, not with an error. Default `["infill"]` — a suggestion the operator can change
  (Rule 9). A `claude-code` provider serves both and records nothing.
- **`Org.QuickProvider`** (`quickProvider`), beside `SpeechProvider` and shaped like it: a provider
  id bound to the org, or empty for "the active provider". Set through `update_org`; an id not bound
  to the org is the existing unknown-provider `UserError`, said whole. Unlinking that provider
  clears it.
- **`AppSettings.editor.ghostText`**, default true — the operator's tier (Decision 38).

### WakilKit — `GhostText`

One controller per pane, the same for both surfaces:

1. Each text change or caret move cancels the request in flight and restarts a debounce: 250 ms
   when the quick provider is `local`, 500 ms for Claude.
2. On the debounce it builds the `InfillRequest` and calls `QuickTasks.infill`. The schema comes from 2d-i's `SchemaSource` for the
   window's environment, cached per environment and refreshed on environment switch; the table match
   is the rule above.
3. One request per pane. A reply whose request is no longer current is dropped.
4. **Clean-up:** the longest tail of the reply that equals the start of the suffix is cut
   (`llama-server` echoed `FROM bookings WHERE …` in the probe); trailing whitespace is cut; single
   line unless `multiline`, then at most six lines. Empty after clean-up shows nothing.
5. **Provider choice** is `QuickTasks`' routing, for every operation alike. If a `local` endpoint
   fails to connect, that call is retried once on the active provider and the endpoint is marked
   unreachable with the error whole; the next call tries the endpoint again.

Accepting is typing: the text enters through the editor's own insert, one undo step, reported as an
edit like a keystroke; the file is written only on save (Invariant 2; no new write under Invariant
6). The suggestion is a transient overlay, not part of the pane's readable state, so the agent
neither sees nor accepts it; what Invariant 3 exposes — the buffer — is unchanged until Tab.

### WakilApp

- **Editor** — `monaco-host.html` registers one `registerInlineCompletionsProvider` for all languages
  that asks Swift for a suggestion over the existing message bridge and resolves with it. Monaco owns
  drawing and keys: **Tab** accepts, **⌘→** accepts a word, **Esc** dismisses. The ghost colour is the
  Editor screen's `.ghost`, `rgba(232,236,246,0.34)`.
- **Query line** — `QueryLineEditor` draws the suggestion after the caret in the same tone without
  putting it in the text storage, so undo and the reported text never contain it. **Tab** accepts
  while one shows and otherwise still leaves the line. **Esc**: dismiss the suggestion, else cancel a
  running read, else leave the line. **Return** runs what was typed and never accepts.
- **Pending pulse** — a request still open after 400 ms shows a faint pulse at the caret until it
  lands or is cancelled. In practice only Claude shows it.
- **Settings** — the org form gains **Quick tasks** (Same as agent, or one of the org's providers);
  a `local` provider row gains **URL**, **Serves: code completion / instructions** (two checkboxes,
  the first ticked by default), and shows *reachable* or the last error whole. The editor
  settings gain **Ghost-text**.

### Interaction rules

- **4, anything that waits can be cancelled:** typing, a caret move or Esc cancels the request.
- **5, work in flight shows it and cannot fire twice:** the pulse; a new request replaces the old.
- **6, stay where the operator was:** accepting leaves the caret after the inserted text; focus never
  moves.
- **7, override or ignore:** a URL on a non-`local` provider is the one refusal, named by this
  decision (only a local endpoint speaks `/infill`).
- **8, errors whole, blocking only what they must:** errors go to the provider row and the log,
  never into the pane, and never stop typing.
- **9, optional stays optional:** no quick provider is needed; ghost-text can be off.
- Rules 1–3 are not touched: nothing is confirmed, nothing needs Enter, no new input appears.

## Errors and edges

- **No provider can serve quick tasks** (none bound, or only `codex`): nothing appears; Settings says
  "Ghost-text needs a Claude or local provider".
- **Endpoint down:** one fallback per request to the active provider, as above. That fallback spends
  subscription quota; the provider row shows why.
- **Org switch:** every in-flight request is cancelled and the Claude quick process stopped
  (2b-viii's invalidation).
- **Schema read fails:** the file is sent alone; the failure is logged once per environment.
- **Read-only tabs** (diff, tail, over-cap) never ask.
- **Production environment:** unchanged — only the schema's table and column names are sent, never
  rows, and only through the org's own binding.

## Testing

- **Go:** `baseURL` and `serves` accepted on `local`, refused on other kinds with the named reason;
  `serves` defaults to `["infill"]` and refuses an unknown operation; `quickProvider` set, refused
  when unbound, cleared on unlink; `ghostText` default and round-trip.
- **WakilKit, `QuickTasks` with fake models:** routing for each operation (quick provider serves it,
  doesn't, absent; active provider serves it, doesn't); fallback once on connection failure; an
  unsupported operation never reaches a model; cancellation; `QuickModels.make` per kind.
- **WakilKit, ghost-text:** prefix/suffix windows; table matching (singular, plural, snake, camel,
  at most five); suffix-overlap trim and the line rule; debounce per provider kind; cancel on change;
  a stale reply dropped.
- **WakilKit, the two models:** `ClaudeCodeQuickModel` against a fake stream-json process — both
  turn framings, JSON validated, re-asked once then thrown, recycle at 20 with the spare, interrupt
  on cancel. `LocalEndpointQuickModel` against a stub HTTP server — the `/infill` and
  `/v1/chat/completions` bodies, `response_format` when a schema is set, the reply validated, cancel.
- **E2E (the auditor):** a stub `/infill` server on loopback. In the editor and the query line: a
  suggestion appears, Tab accepts it as one undo step, Esc and typing drop it, the query line's Tab
  still leaves an empty line, the switch turns it off, a stopped stub falls back. The real Claude
  path and real models are left to the walk; no check spends quota.

## Charter changes this sub-phase makes

- **Decision 16, amended:** the harness axis has two seams — `AgentHarness` for sessions and
  `QuickModel` for one-shot quick tasks, with two operations (`infill`, `respond`).
- **Decision 42, new: quick tasks.** One quick-tasks provider per org, defaulting to the active
  provider; a `local` provider is a URL the operator runs and says what it serves; Wakil installs and
  supervises nothing. Each call routes to the first of those two that serves its operation. A new
  quick task is a caller of `QuickTasks` — a prompt and a parser — and adds no harness work.
  It names the next two sub-phases (the ⌘K fast path, which must amend Decision 10, then agent status
  lines) and the unscheduled candidates (shrinking what the agent reads — lossy, opt-in at most;
  session titles and commit drafts; voice cleanup). Never a quick task: the write gate, statement
  classification, anything touching credentials.
- **Decision 14, clarified:** ghost-text is reactive — it answers the operator's own typing, never
  moves focus, makes no sound, and is gone on the next keystroke.
- **design-language §11 and PRODUCT.md:** tier 3 runs on the org's quick-tasks provider — its Claude
  account by default, a local model when the operator adds one.
