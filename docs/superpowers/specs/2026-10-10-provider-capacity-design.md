# Provider capacity: how much each account has left

**Status:** design, amended 2026-10-11 (Claude source), awaiting operator review ·
**Date:** 2026-10-10 · **Owner:** Yehia Khalil

Wakil shows, for every provider account in the active organisation, how much of its
5-hour window and its weekly window is left and when each resets. This was gap #1 in
the Wakil-vs-Jarvis comparison (2026-10-09): Jarvis has it and Wakil's provider picker
has no number to choose by.

## Amendment, 2026-10-11: the Claude source

The walk's step 2 failed: a real turn on Claude Code 2.1.296 stored no reading. The
stream's `rate_limit_event`, which this spec first relied on, is no longer sent every
turn. It was in 2.1.263 (the recording below, 2026-10-03). From 2.1.294 it is sent from a
status-change subscriber, so only when an account's limit status changes. Four fresh
`claude -p --output-format stream-json` runs (two accounts, 2.1.294 and 2.1.296) sent none.

Two replacements were measured on this machine the same day:

| Source | With Wakil's stored tokens | Result |
|---|---|---|
| `GET /api/oauth/usage` (what `/usage` reads) | 403 `oauth_scope_insufficient`: the `claude setup-token` tokens Wakil stores carry `user:inference`, not `user:profile` | unusable without a second login per account, and Wakil refreshing tokens the CLI also refreshes |
| `anthropic-ratelimit-unified-*` headers on a 1-token `POST /v1/messages` | 200 | Max and Team accounts: 5h and 7d utilization and resets. Enterprise: no 5h or 7d window; an `overage` (monthly spend) utilization and reset |

**The operator chose the headers (2026-10-11),** knowing each read is a real 1-token
request against the account's own limit. This overrides the first draft's assumption that
reading must cost nothing. Jarvis tried a probe and withdrew it; the cost is bounded here by
the triggers and the one-minute floor below. The stream event is kept as a second source:
when it does arrive it is free.

## Intent

**Said by the operator:** show it on the home window in a smart, space-efficient way and in
Settings; show the weekly limit and its reset as well as the 5-hour one. Chosen designs: home
**A** (two hairlines beside ACCOUNT, details on hover), Settings **S3** (a strip above the
accounts table, the table untouched), ⌘P provider rows gain a one-line subtitle. Sources:
a 1-token probe per Claude account (amended above), Wakil's own stream when it reports, and
Codex's logs; no status-line hook.

**Assumed, open to correction:** the purpose is choosing which account to start or resume
on before a limit hits mid-session.

**Success:** with three accounts in an org, the operator can see from the home window
which one is low without opening anything, and choose between them in ⌘P or Settings
knowing both windows and both reset times.

## Where the numbers come from

**Claude Code: a 1-token probe, in Go.** `internal/wakilcore/capacity_claude.go` sends,
per Claude account, one `POST {base}/v1/messages` with the account's stored token
(`ProviderTokenRef(id)`, the token `wakil provider credentials` already hands the harness):

- headers `Authorization: Bearer <token>`, `anthropic-version: 2023-06-01`,
  `anthropic-beta: oauth-2025-04-20`;
- body: model `claude-haiku-5-5`, `max_tokens: 1`, the Claude Code system line, user `hi`;
- `{base}` is `https://api.anthropic.com`, overridable by `WAKIL_ANTHROPIC_BASE_URL` for
  tests and e2e only;
- an 8-second timeout per account, so a refresh fits the 10-second `ctx_*` budget; accounts are probed in parallel.

The headers read, every other one ignored:

| Header | Window |
|---|---|
| `anthropic-ratelimit-unified-5h-utilization`, `-5h-reset` | `fiveHour` |
| `anthropic-ratelimit-unified-7d-utilization`, `-7d-reset` | `sevenDay` |
| `anthropic-ratelimit-unified-overage-utilization`, `-overage-reset` | `month`, only when neither 5h nor 7d is present |

Utilization is 0…1; reset is Unix seconds. Measured 2026-10-11: a Team account read
`5h 0.05` / `7d 0.16`; an Enterprise account sent only `overage 0.05`, reset 1 Nov.

**The token never leaves Go** except in that one request's `Authorization` header to
`{base}`. It is not logged, not returned, not stored with the reading, and an error
message never quotes a header or a body that could carry it.

**Claude Code: the stream, when it reports.** `claude --output-format stream-json` sends a
`rate_limit_event` when the limit status changes. A recorded one (2.1.263):

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1788818400,
 "rateLimitType":"five_hour", …, "unifiedWindows":{
   "five_hour":{"utilization":0.01,"resetsAt":1788818400},
   "seven_day":{"utilization":0.41,"resetsAt":1788854400}}}, …}
```

Only `unifiedWindows` is read. Already built (`.rateLimit`, `capacity_record`); it stays.

**Codex: its own session logs, read-only.** The Codex CLI writes `rate_limits {primary,
secondary}` (`used_percent`, `window_minutes`, `resets_at`) into
`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` (default `~/.codex`). The newest few logs
are scanned from their end, Jarvis's method (`packages/platform/src/capacity-codex.ts`).
A codex provider record has no config dir (`provider.go` refuses `--share` for it), so
every codex provider on the machine reads the same `$CODEX_HOME`; that is what the CLI
itself does. Windows map by `window_minutes`: 300 → `fiveHour`, 10080 → `sevenDay`,
43200 → `month`; any other length is dropped.

**Local providers:** no limits; shown as such.

**Not in v1: a Claude Code status-line hook** (Jarvis's second source). It would make
readings fresh after terminal sessions too, but Wakil would have to write into every
account's Claude `settings.json` and could displace a status line the operator already has.

## When a probe is sent

`ctx_capacity` takes an optional `refresh: true`. With it, Go probes every Claude account
of the active org whose stored reading is older than **60 seconds**, records each result,
then returns the listing. Without it, nothing is sent: the store and the Codex logs only.

| Trigger | `refresh` |
|---|---|
| Launch (`refreshContext`) | true |
| Org switch, account switch | true |
| A turn ends | true |
| ⌘P opens, Settings opens, a strip re-read after a dispatch | false |
| The agent calls `capacity` | false |

The agent cannot make Wakil spend the operator's limit: `refresh` is honoured only for
operator-origin dispatches.

## Data flow

```
api.anthropic.com ◀── 1-token probe ── wakil-ctx capacity {refresh} ──▶ ~/.wakil/capacity/<account>.json
                                                │                                  ▲
~/.codex/sessions (read-only) ─────────────────▶│                                  │
                                                │                     wakil-ctx record_capacity
claude stream ── rate_limit_event ──▶ Harness/StreamJSON .rateLimit ──▶ App/CapacityFeed ── capacity_record
                                                │
          home indicator · Settings strip · ⌘P subtitle · agent (ctx_capacity)
```

- **Keyed by the account, not the organisation.** Decision 32: the account is the config
  dir. Decision 22: one Claude account may serve several orgs. A shared account therefore
  shows the same numbers in every org that holds it, which is true. Capacity is not a
  credential, so this does not touch Invariant 4's boundary. The probe reads the token
  under the active org, as `wakil provider credentials` does.
- **The store** is one file per account, `~/.wakil/capacity/<first 16 hex of
  sha256(configDir)>.json`, holding the config dir, the windows and `asOf`. Nothing is
  written into any Claude config dir. A newer reading replaces an older one; an older one
  arriving late is ignored (compare `asOf`). A probe and a stream event write the same file
  by the same rule.
- **One read path.** `wakil-ctx capacity` returns every provider of the active org, in the
  order `ctx_list_providers` returns them, each with its state (below). All three surfaces
  and the agent use it, so they cannot disagree.

## The reading

```
CapacityReading
  account        provider id in the active org ("main")
  kind           claude-code | codex | local
  state          read | notRead | noLimits | error
  error          the whole message, when state == error (a failed probe, a corrupt store
                 file, an unreadable log)
  fiveHour       Window?
  sevenDay       Window?
  month          Window?     — present only when fiveHour and sevenDay are both absent
  asOf           instant the reading was taken (probe time / stream event time / log line time)

Window
  percentLeft    0…100, integer = round((1 − utilization) × 100)
  resetsAt       instant
```

**Abstain, never guess.** A `utilization` outside 0…1, a missing or non-numeric reset, or
an unrecognised shape drops that window; a reading with neither a valid 5-hour nor a valid
month window is not recorded at all. Clamping would turn a format change into a confident
wrong number.

**A failed probe** (no token, timeout, non-2xx, no readable header) records nothing and
puts that account in `error` with the reason, unless a stored reading exists: then the
stored reading is returned with its old `asOf` and the error is dropped. A stale number
with its age is more use than an error over a number the operator can still see.

## What is drawn

| Case | Home (A) | Settings strip (S3) | ⌘P subtitle |
|---|---|---|---|
| Read, both windows over 20% | two violet hairlines, 44 pt | name, 5H and WEEK rows: bar, `28%`, `· 20:20` | `5h 28% · week 59%` |
| Read, month only | one violet hairline | name, MONTH row: bar, `95%`, `· 1 Nov` | `month 95%` |
| Any window at 20% or less | that hairline amber | that row amber | that figure amber |
| A window's reset has passed | that hairline drawn empty, dashed | `reset 20:20 · not read since` | `5h reset` |
| `notRead` | label only, no hairlines | `not read yet` | `not read yet` |
| `noLimits` (local) | label only | `no limits` | `no limits` |
| `error` | label only | the error, whole | `capacity unreadable` |

- **Amber is §5's caution hue; red is never used** — §5 reserves it for production, and a
  low account is not a production hazard.
- **Every reading carries its own "as of"**: per row in the hover card and the strip, and
  in the ⌘P subtitle only when older than an hour (`· as of 14:02`).
- **Reset times** are local, `HH:MM` when today, `Thu 09:00` within the week, `1 Nov`
  beyond it.
- **Bars show what is left**, full = untouched.
- **The hover card** lists every provider in the active org with the strip's rows, the
  active one marked `IN USE`. It opens on pointer hover over the indicator and on keyboard
  focus of it, and closes when either leaves; it takes no focus and moves nothing (Rule 6).
- **The Settings strip** sits between the pane title and the accounts table and re-reads
  on open and after every dispatch, as the table already does. The table's columns and
  widths do not change.

### Interaction rules (`PRODUCT.md`)

- **Rule 4, rule 5:** a refresh is parallel probes with an 8-second timeout each, inside
  the 10-second `ctx_*` budget; nothing waits on the operator, so there is no cancel
  control. While a read or refresh is in flight the previous figures stay drawn; nothing
  is fired twice because nothing is fired by a press.
- **Rule 6:** opening the hover card and re-reading never move focus or selection.
- **Rule 8:** one account that fails to read shows its own error, whole, in its row; the
  others still draw. A failed `capacity` call leaves the indicator showing the last
  readings with their "as of".
- **Rules 1, 2, 3, 7, 9:** not touched — no input, no operator write, no default.

## Code structure

Built on the WindowModel-split stack (`yehia-khalil/windowmodel-split` … `wm-8-layering`),
which must land first: it creates `Core/` and the layering test. **No new folder link is
added to `layering-allowed.txt`**; every link below already exists or points into `Core/`.
Checked against that stack's spec and `layering-allowed.txt` (the operator approved these
answers on 2026-10-10):

- **The record path is a registry action**, operator-only, as `session_record_parent` is:
  Invariant 2 keeps actions the only mutation path, and operator-only means the agent
  cannot forge a reading.
- **`App/` is `CapacityFeed`'s home**: only `WindowModel` and `WakilApp`'s views use it, and
  the split's hard rule is only that nothing else in `WakilKit` uses `App/`.
- **Level 3 is not made harder**: no new folder link, and the one shared type sits in
  `Core/`, which level 3 keeps at the bottom.

| Where | What |
|---|---|
| `WakilKit/Core/CapacityReading.swift` | the value types above, with `month`; Foundation only |
| `WakilKit/Harness/StreamJSON.swift` | `HarnessEvent.rateLimit(CapacityReading.Windows, at:)`; the parser (built) |
| `WakilKit/Registry/CapacityActions.swift` | `capacity_record` (operator-only) and `ctx_capacity` (agent-reachable read; `refresh` passed only for operator origin); both call `wakil-ctx` |
| `WakilKit/App/CapacityFeed.swift` | owned by `WindowModel`: takes harness events, dispatches `capacity_record`, holds the latest readings; `refresh(probe:)` |
| `WakilApp/CapacityIndicator.swift` | the hairlines (one for month-only) and the hover card |
| `WakilApp/CapacityRows.swift` | the rows view shared by the hover card and the Settings strip; the MONTH row |
| `WakilApp/SettingsPane.swift`, `Palettes.swift` | place the strip; the ⌘P subtitle |
| `internal/wakilcore/capacity.go` | the store: record, read, key by config dir; `month` |
| `internal/wakilcore/capacity_claude.go` | the probe and its header parser |
| `internal/wakilcore/capacity_codex.go` | the log reader; 43200 → `month` |
| `cmd/wakil-ctx/main.go` | tools `record_capacity` and `capacity {refresh}` |

## Testing

- **Go:** store round-trip with `month`; newer replaces older, a late older one is ignored;
  a shared config dir under two orgs reads the same; `notRead` for an account with no
  file. The probe against an `httptest` server: Team headers → 5h and 7d; Enterprise
  headers → month only; utilization 1.3, a non-numeric reset, a 401, a 429, a timeout and
  no rate-limit headers each abstain; a failed probe over a stored reading returns the
  stored one; a reading under 60 seconds old is not probed again; the request carries the
  token and the body names `max_tokens: 1`; no error string contains the token. Codex
  reader as before, plus 43200 → month.
- **Swift (`WakilKitTests`):** `StreamJSON` as built; `CapacityFeed.refresh(probe: true)`
  sends `refresh: true` and the ⌘P/Settings path sends none; an agent-origin `ctx_capacity`
  with `refresh: true` is sent without it; the month-only subtitle and amber at 20 and 21.
- **e2e (the auditor, Cover rung):** a stub server on `WAKIL_ANTHROPIC_BASE_URL`; the
  indicator appears at launch with no turn, turns amber against a 12% header, updates after
  a turn, a month-only account reads `month 95%` in the strip, and a passed reset reads
  `not read since`.

## Out of scope

- The status-line hook and any reading of terminal sessions' capacity.
- The `/api/oauth/usage` endpoint and any OAuth refresh in Wakil.
- Notifications or warnings when an account runs low (Phase 4's proactivity, Decision 14).
- Choosing an account automatically by capacity.
- Copilot and other providers Wakil does not run.

## Open questions

None. (The Codex 30-day question is answered by `month`.)
