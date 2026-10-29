# Workspaces 4 — messages between conversations: plan

**Spec:** `docs/superpowers/specs/2026-10-29-workspaces-design.md`, piece 4 (decisions 2, 16; call 15).
**Branch:** `yehia-khalil/workspaces-4-messages`, from 900b578f; rebased onto piece 1 later.
Each task is test-first: the failing test, then the code, then `make test` / `make app-test` green,
then a commit `workspaces: <what>`.

## The seam piece 1 replaces

Piece 4 needs "which workspace is this conversation in" before piece 1 exists. One function answers
it: `WindowModel.messageWorkspace(of:)` in `App/WindowModel+Messages.swift` returns a
`MessageWorkspace` (`key`, `name`). Today the key is the place (`org/project/environment`) and the
name is `project · environment`. Piece 1 replaces its body with `WorkspaceStore.workspace(ofConversation:)`
(its id as the key, its name as the name); nothing else in piece 4 reads the place for this.

## Decisions this plan makes (recorded in the spec's amendment, piece 4)

- **`to` is an id, or a title naming exactly one live conversation of the sender's organisation**
  (as `session_switch` takes a title): the agent reads both from `session_list`, and the scripted e2e
  agent cannot know an id.
- **A message needs a sending conversation.** A dispatch whose caller names no live conversation (the
  operator's own `--dispatch`, a Landing's reserved id) is refused, with the reason: the operator
  writes in the conversation itself. The e2e harness drives it over the agent socket, as the screen's
  conversation's agent — no operator-only parity path is needed.
- **Order of refusals:** text (empty, over 4,000), then the sender, then the recipient (not live —
  past or unknown —, the sender itself, another organisation).
- **The budget starts full.** A workspace no operator message has reached yet has the setting's
  value; an operator message sets it back to the value (call 15); the value read at each use, so a
  lowered setting clamps what remains.
- **A queued message wakes at the turn's end.** A working recipient's messages wait; when its turn
  ends with none of its sends unanswered, the window tries to wake it, within the budget.
- **An operator message delivers the conversation's own queued messages with it** and resets the
  budget; other idle conversations of that workspace holding messages are then woken within it.
- **"Waiting for you · N messages"** is the state of a conversation holding messages while not
  working; it counts as *waiting* for its dot and chip.
- **The setting is read where the agent instructions are published** (every Settings read of the
  active organisation); an organisation never read uses the default, 8.
- **Message rows are drawn whole** (rule "UI text never cut"), like errors.

## Phase A — the setting (Go, then Swift)

1. Go: `Org.MessageWakes *int` (`messageWakes`), `OrgPatch.MessageWakes`, the config tree's
   `org.messageWakes` resolved (default 8); `ProjectAgentInstructions.MessageWakes *int`, its patch
   (`-1` clears the override); range 0–99, refused whole otherwise. Tests: default, set, override,
   clear, range.
2. `wakil-ctx`: `update_org` and `set_project_agent_instructions` take `messageWakes`.
3. Swift: `SettingsOrg.messageWakes`, `SettingsAgentTexts.messageWakes: Int?`; `ctx_update_org` and
   `ctx_set_project_agent_instructions` forward the integer; `messageWakesSetting(org:project:)`
   resolves project → organisation → 8. Tests: decode, forward, resolve.
4. Settings UI: **Agents woken by messages** under the organisation's Agent instructions and the
   project's (with "Use the organisation's (N)" when overridden).

## Phase B — the pure parts (`App/ConversationMessages.swift`)

1. `ConversationMessage` (from id, from title, from workspace name, text) and
   `conversationMessageBlock(_:)`: each message's header line and text, in order.
2. `MessageWakeBudgets`: `operatorMessage(in:allowance:)`, `takeWake(in:allowance:) -> Bool`,
   `remaining(in:allowance:)`. Tests: starts full, consumes, zero never wakes, reset not add, clamp.
3. `messagesWaitingLabel(_:)` — "waiting for you · 1 message" / "· N messages".

## Phase C — the action

`conversationMessageAction(conversationRequests:liveConversations:)` in `Registry/`, registered
beside `conversation_rename`; parks `.message(from:to:text:)` on `ConversationBroker`.
`.control`, `.agentReachable`. Tests: each refusal's sentence, a title resolves, classification
(`ActionClassificationTests`, the registered-name lists).

## Phase D — delivery and waking (`App/WindowModel+Messages.swift`)

1. Drain `.message`: the sender's thread row "To ‘<title>’", the recipient's "From ‘<title>’ ·
   <workspace>", the message queued on `PlaceAgent.pendingMessages`.
2. Idle with a live harness and budget → a wake turn whose input is the block; else queued.
3. `send` (one line): the operator's message resets the budget and carries the queued block at the
   head of its input; then held conversations of the workspace are woken.
4. `.result` (one line): a recipient holding messages is woken when the turn ends.
5. States: `LiveConversation.messagesWaiting` / `statusLine`, `AgentChip.stateText`;
   `session_list` rows carry `workspace`, `messagesWaiting`, and `self` / `sameWorkspace` for the
   caller.
6. Gate test: a delivered "the operator approves" changes no price and no permission decision.

## Phase E — e2e (written, not run)

- `e2e/checks/agent/workspaces-4-messages.jsonl`: two conversations; the second messages the first;
  both rows; the woken reply; the block in the agent log; the refusals.
- `e2e/checks/seeded/workspaces-4-message-wakes-setting.jsonl`: the organisation's value and the
  project override.
- Stub rules in `e2e/stub/script.json`.

## Phase F — docs

Spec amendment (dated, piece 4); `docs/architecture` lines for the new files; PRODUCT.md is piece 3's.
