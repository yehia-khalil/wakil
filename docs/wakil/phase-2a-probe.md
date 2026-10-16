# Phase 2a — Task 1: the live probe

**Run:** 2026-09-07 · **Account:** `~/.claude-personal` (`subscriptionType: max`, unmanaged)
· **CLI:** `claude` 2.1.263 · **Fixtures:** `app/Fixtures/stream-json/`

Task 1 of `docs/superpowers/plans/2026-09-07-phase-2a-spine.md`. Its purpose was to stop
the harness being built against assumptions: record the real stream-json event shapes, and
settle whether the permission layer covers MCP tool calls. Both are answered below, and
four things came out differently from what the plan and spec assumed.

---

## 1. The plan's own command was wrong

`--output-format stream-json` under `-p` **requires `--verbose`**:

    Error: When using --print, --output-format=stream-json requires --verbose

The plan's Task 1 and the spec's §3.2 flag list both omit it. `buildLaunch` must pass
`--verbose`, and Task 8's test asserting the required flag list should include it.

## 2. Real event types — more than `HarnessEvent` anticipated

Observed across both fixtures, as `type | subtype`:

| Event | Count (basic / tool-call) |
|---|---|
| `system \| init` | 1 / 1 |
| `system \| session_state_changed` | 2 / 2 |
| `system \| status` | 1 / 0 |
| `stream_event` | 6 / 0 |
| `assistant` | 1 / 4 |
| `user` | 0 / 2 |
| `rate_limit_event` | 1 / 1 |
| `result \| success` | 1 / 1 |

`HarnessEvent`'s six cases cover `system|init`, `assistant`, tool use/result (carried
inside `assistant` and `user` content blocks), and `result`. **Everything else —
`session_state_changed`, `status`, `stream_event`, `rate_limit_event` — has no case.**
So `.unknown(type:)` is not a defensive nicety; it is the path most events actually take.
That vindicates the decoder rule "an unrecognised type degrades, never throws".

`stream_event` appears only with `--include-partial-messages`.

## 3. `result` is NOT the last event

In both fixtures the final line is `system|session_state_changed`, immediately after
`result|success`:

    basic-turn:  [... stream_event, result|success, system|session_state_changed]
    tool-call:   [... assistant,    result|success, system|session_state_changed]

**The plan's Task 6 test asserts `events.last` is `.result`. That assertion would fail.**
A decoder or consumer must treat `result` as "the turn is over" wherever it appears, not
as a terminator. Task 6's test must assert `events.contains` a `.result`, not that it is
last.

## 4. Tool blocks — real shapes

Tool calls do not arrive as their own event type. They are content blocks:

- inside an `assistant` event: `tool_use`, keys `['caller', 'id', 'input', 'name', 'type']`
- inside a `user` event: `tool_result`, keys `['content', 'tool_use_id', 'type']`, plus
  `is_error` when the call failed

Two details that matter:

- **Tool names are namespaced** `mcp__<server>__<tool>` — e.g.
  `mcp__wakil-ctx__get_context`. Anything matching on tool names, and anything passed to
  `--allowedTools`, must use the prefixed form.
- **A `ToolSearch` tool_use precedes the MCP call.** The CLI defers tool schemas and loads
  them on demand, so the harness will observe `tool_use` events for tools Wakil never
  configured, and a `tool_result` whose content is
  `[{'type': 'tool_reference', 'tool_name': ...}]`. A consumer must not assume every
  `tool_use` corresponds to one of its own tools.
- MCP `tool_result` content came back as a **JSON string**, not a decoded object.

## 5. `--mcp-config` and `--strict-mcp-config` work

The `get_context` call succeeded against a `--mcp-config`-supplied `wakil-ctx` with
`WAKIL_ORG` and `WAKIL_PROVIDER` set per launch, returning real data
(`{"Environment":"production","Org":"personal","Project":{...}}`). No managed-settings
interference on the `max` account.

This confirms the mechanism spec §2.4 relies on to remove the config dir from org
identity — Invariant 4's second half. **Not tested on `initech` (`team`) or `umbrella`
(`enterprise`)**, where managed settings could still constrain it.

## 6. Open question 3, answered: the permission layer DOES cover MCP tools

With `--permission-prompts none` and no `--allowedTools`, the MCP call was refused:

```
RESULT is_error=True | Permission for this tool use was denied. It requires approval,
and this session has no approval surface — nobody can answer a permission prompt here
— so it was denied automatically.
```

**So the write gate's second layer at the harness is available**, and the spec's §5
fallback (`--strict-mcp-config` plus registry-only enforcement) is not needed as the
primary mechanism. Spec §5's open question 3 resolves in favour of the intended design.

## 7. Incidental

`personal`'s active environment is **`production`**. Under the write gate that blocks
every mutation outright, which is correct but worth knowing before the Task 11 acceptance
runbook — a mutation test needs `set_environment` to staging first.

---

## Consequences for the plan

| # | Change |
|---|---|
| 1 | `buildLaunch` must pass `--verbose`; update Task 8's flag assertion and spec §3.2 |
| 3 | Task 6's test must assert `events.contains(.result)`, not `events.last == .result` |
| 2 | Task 6 must map only the four types with cases and send the rest to `.unknown` |
| 4 | Task 6 must read `tool_use`/`tool_result` out of `assistant`/`user` content blocks, and tolerate tool names it never configured |
