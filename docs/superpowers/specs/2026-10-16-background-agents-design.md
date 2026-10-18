# Background agents: one agent per place, kept running while the operator is elsewhere

**Date:** 2026-10-16
**Status:** design agreed with the operator in conversation 2026-10-16; awaiting their review of this
document
**Sub-phase:** not yet placed on the phase map (see Open questions). It waits on nothing.

---

## Problem

The operator gives an agent a long job, switches somewhere else to keep working — often to give a
second agent another job — and comes back expecting the first to have carried on, with its whole
thread and a record of what it did. Today Wakil cannot do that:

- **A window runs one agent.** `WindowModel` holds a single `harness`, `sessionId`, `thoughts`
  and `turnInFlight`. A second job "elsewhere" is the same session.
- **An org switch ends it.** `requestOrganizationSwitch` queues behind a running turn, then
  `setOrganization` clears the thread and drops the harness (`WindowModel.swift` ~1955–1967). The
  operator lands sessionless and must resume from Continue.
- **A project or environment switch silently retargets it.** `setProject` and `switchEnvironment`
  neither wait nor stop. The agent keeps running in the old project's root, but every Wakil tool
  it calls resolves against the new active context — including the agent-facing binaries its own
  `claude` process spawned, because every binary reads the per-org `active.json`
  (`internal/wakilcore/active.go`) at call time. A job started in staging can finish in another
  environment with nothing recording that it moved.
- **The journal cannot say which job did what where**, because there was only ever one.

## Decisions the operator took during this design (2026-10-16, to be recorded as Decision 41)

- **A place is an (organization, project, environment) triple.** Each place has at most one
  agent, and its own thread and canvas — switching environment inside one project moves to
  another place, not a refetch of the same canvas.
- **An agent is pinned to the place it started in**, for its whole life. Whatever the operator
  is looking at, the agent's Wakil actions, database, API, git and file calls go to its own place.
- **Switching org, project or environment never stops, holds or redirects an agent.** The org
  switch's "switch when this turn finishes" queue goes away: there is nothing left for it to wait
  for.
- **Several agents run at once**, one per place, each with its own thread and canvas.
- **An agent that needs the operator waits.** It does not pull the operator back. A marker says
  which place is waiting.
- **The marker is a chip per agent, top right of the window** (option B of three shown over the
  real window: the context-line dots and a summary line were the others). Click a chip to go to
  that place. No agents elsewhere means no chips.
- **A chip's life:** violet while the agent works, amber while it waits on the operator, green
  when it has finished and the operator has not yet looked. It disappears once the operator has
  visited that place after it finished.
- **A finished agent's session stays alive** until the operator quits or starts a new
  conversation in that place, so it can be replied to.
- **Quitting stops every agent.** Each appears in its place's Continue, resumable as a fork in the
  usual way (Decision 12). Agents that outlive the app — a daemon — are out of scope.
- **The journal records, for every entry an agent caused, which agent and which place.**

## What the operator gets

### 1. Leaving a place with an agent in it

The operator switches by any path — context line, ⌘P, palette, a chip. The agent they left keeps
working. Its thread, panes and any approval it raises stay with its place. The window now shows
the destination place: its own thread, canvas and agent (or the Landing, if it has none).

### 2. The chips

Top right, stacked, one per agent in a place *other than the one on screen*:

| State | Hue (`design-language.md` §5 reserved) | Text |
|---|---|---|
| Working | violet `#7c5cff`, breathing | `initech · api · staging` |
| Waiting on the operator | amber `#e8b45a` | `umbrella · web · production — waiting` |
| Finished, not yet seen | green `#8be0c8` | `initech · api · staging — done` |

A production place's chip carries the production red in its environment segment, as everywhere
else (Invariant 8). Clicking a chip is an ordinary switch to that place.

### 3. Coming back

The place is exactly as left: the same thread, the same canvas, the agent still running (or
waiting with its approval plane up, or finished). Nothing is rebuilt or resumed, because nothing
was stopped. A green chip clears on arrival.

### 4. Starting a second agent

In any place without an agent, the composer starts one as today. In a place that already has
one, the composer talks to that agent — there is never a second agent in one place.

### 5. Asking what happened

The journal can answer "what did the agent in initech · api · staging do while I was in
billing": every entry carries its agent's session and its place.

## What it does not do

- No agents outliving the app; quitting stops them all.
- No second agent in the same place.
- No cap on concurrent agents beyond what the provider's capacity readings already show.
- No notification outside the window (system notifications, sounds). The chip is the marker.
- No change to how a session is resumed, forked or listed (Decision 12).
- No change to prices or Invariant 7: an approval raised by a background agent is the same plane,
  raised in its own place. The write gate itself does change — it must price a call by the
  calling agent's place (see Pinning, path 4).
- No journal reader. The journal gains the fields; reading it (a surface or an agent tool) is a
  later sub-phase. *(My call.)*

## Design

What is fixed and what is left to the builder. The builder should read `WindowModel`'s org switch
(`setOrganization`, `performOrganisationSwitch`, `fireQueuedSwitchIfReady`), `send`, `setProject`,
`switchEnvironment`, `activateLayout`, and `internal/wakilcore/active.go` before planning.

### The place's agent becomes a unit of its own (WakilKit)

Everything `WindowModel` holds today as the window's one agent — at least `harness`, `sessionId`,
`thoughts`, `turnInFlight`, the Bash `mirror`, the parked confirmation, the lineage root — moves
into a per-place value the window keeps a table of, keyed by place. The window's "current agent"
is the entry for the place on screen. **How** it is split (a type of its own, how `WindowModel`
delegates to it) is the builder's, guided by `docs/architecture/README.md` and CONTRIBUTING.md.
It belongs in WakilKit so it is testable.

### Each place stays alive (the operator's "as if I had never left")

A place the operator leaves is not torn down. Its panes, layout, terminals (their shells keep
running), editor buffers, in-flight reads, database choices and parked confirmation all stay in
memory, and a background agent's pane actions land in its own place's stores — not in whatever is
on screen. This replaces today's org-switch teardown (`invalidateForOrgChange`:
`terminals.shutdownAll`, `layout.clearAllScopes()`, `panes.clearAllScopes()`, dropped buffers),
and with it the unsaved-tabs prompt on an org switch, which existed only because the switch
discarded buffers. It is the largest part of this work: `PaneStore`, `LayoutStore`, the terminal
host, the editor and every action handler that reads "the window's" state must take a place.
*(Answered by the operator's requirement; the size is noted so the plan can stack it.)*

### Pinning (the hard part)

An agent's calls must resolve against its own place, never the place on screen. Four paths reach
an agent's tools today, and each must be pinned:

1. **Wakil's own actions, through the shim and `MCPSocketServer`.** The window must know which
   agent a frame came from (for example, a socket per agent, or a per-agent token in the shim
   arguments — builder's call) and dispatch it against that agent's place.
2. **The window's binaries (`wakil-ctx`, `wakil-db`, `wakil-http`, `wakil-git`).** These are one
   `MCPClient` per binary, re-pointed at the new org on a switch (`switchOrg`), and they call
   `wakilcore.Resolve()`, which reads the per-org `active.json` **at call time**
   (`resolve.go:122,171,209`). So this is not only an org problem: two agents in one org but
   different projects or environments would share a client that follows the operator. Whether the
   window passes the place per call (an internal argument between window and binary) or runs a
   pinned client set per place is the builder's call. The constraint is the amended Invariant 5:
   the **agent-facing** tool schemas do not grow a project or environment argument.
3. **The agent-facing binaries `claude` spawns itself** (`agentFacingServers`). They read
   `active.json` at call time, so a project or environment switch moves them. They must be
   launched with the agent's place fixed. The terminal pane already exports
   `WAKIL_PROJECT`/`WAKIL_ENVIRONMENT` (`ShellIntegration.swift:560-562`), **but no Go code reads
   them** — the only selector `wakilcore` honours is `WAKIL_ORG` (`paths.go:49`). Making
   `wakilcore` honour them over `active.json` is new Go work, and it also changes the terminal
   pane, whose shells follow `active.json` today despite the exports. That change is wanted: a
   background place's shell should stay in its place too.
4. **The window-side handlers and the write gate.** `MCPSocketServer`'s `environmentProvider`
   prices a call by the environment on screen, before and after a parked confirmation, and the
   production flag is one window-wide value (`registry.setEnvironmentProduction`). A background
   agent in production while the operator is in staging would be priced as staging — the same
   Invariant 4 shape #182 closed for org switches. Likewise `GitRootsSource` (the window's
   `gitRootPaths`), the file-write roots check, `databaseChoices`, `rootPath` and the single
   `ConfirmationBroker` all read the place on screen. Each must resolve against the calling
   agent's place, and the broker becomes per place (today `setOrganization` refuses to switch
   while it holds a parked mutation, so one waiting approval would block every switch).

**Invariant 4 stays structural:** an agent in org A must be unable to reach org B's credentials
by construction (its processes carry org A's `WAKIL_ORG` and `Resolve()` still checks it), not by
the window routing correctly.

**The agent's own context-switch actions.** An agent's place is fixed at start, so
`ctx_set_project` and `ctx_set_environment` (and `ctx_set_org`, if exposed) dispatched *by an
agent* are refused, saying the agent's place is fixed and the operator can start an agent in the
other place. This tightens `AgentInstructions` rule 4 from "nothing stops you" to a refusal Rule 7
allows, because the amended Invariant 5 forbids it. *(My call — see Calls made.)*

### The switches

- **`setOrganization`** no longer clears the thread or drops the harness. It stops tearing down
  per-agent state and instead swaps which place is on screen. The queued-switch machinery
  (`queuedOrgSwitch`, `cancelQueuedSwitch`, `stopTurnAndSwitchNow`, `fireQueuedSwitchIfReady`, the
  `send` guard on a queued switch) is deleted, not left unreachable.
- **`setProject` and `switchEnvironment`** change the place on screen and nothing an agent sees.
- The unsaved-tabs prompt on an org switch is unchanged.

### Layout scope and the environment

Today a layout scope is (organization, project, lineage root) — the environment is not in it, and
switching environment keeps the same conversation and refetches its panes. A place includes the
environment, so the conversation, its thread and its canvas now belong to (organization, project,
environment, lineage root). Switching environment therefore moves to *that environment's*
conversation (or its Landing) rather than refetching the current one. **This changes existing
behaviour (D11's refetch-in-place), and the operator chose it on 2026-10-16:** api · staging and
api · production are two places, each with its own agent, thread and canvas.

### The chips (WakilApp)

A view reading the window's table of agents, drawing those not in the place on screen. Placement
and motion follow `design-language.md` §3 (planes) and §7 (motion); the breathing on a working
chip borrows the Core's idle/thinking rhythm rather than inventing one. `design-language.md` gets
an amendment: this is the first always-on chrome outside the context line, justified because it
exists only while there is work elsewhere.

### The journal

Today `JournalEntry` (`Registry/Journal.swift`) records only `environment` and an `origin`
(ui / agent / debug), in one file per window. It gains the organization, the project and, for an
agent's entry, its session id. Operator entries gain the organization and project too — new work,
not existing behaviour. The file stays one per window.

### Quit

`shutdown()` stops every agent's harness, not just the current one. Nothing asks first (see Rule
1 below).

### Provider

The provider stays session-scoped (Decision 4). A provider switch applies to the agent in the
place on screen only; other places' agents keep theirs. *(My call.)*

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How this meets it |
|---|---|
| 1. Confirm only what destroys | Switching away from a running agent asks nothing. Quitting with agents running asks nothing: each is resumable from Continue, so nothing is destroyed. *(My call.)* |
| 4. Anything that waits can be cancelled | A waiting agent's approval plane keeps its Cancel. A working agent can be stopped from its own place as today (interrupt). |
| 5. Work in flight shows it | The chips are exactly this, for work off screen; on screen, the Core and thread are unchanged. |
| 6. Stay where the operator was | Nothing moves the operator. An agent that starts waiting turns its chip amber and stays put. Only a click on a chip goes there. |
| 7. Override or ignore; don't refuse | The one new refusal — an agent switching its own place — names the amended Invariant 5. |
| — Waiting means a parked approval | A chip is amber only while the agent's place holds a parked confirmation or permission prompt. An agent that ends its turn by asking a question in text is done (green): there is no reliable signal for "asked in text", and green already says "go look". *(My call.)* |
| 8. Errors are shown whole | An agent that fails in a background place shows the failure in its thread; its chip turns to the failed red with the text `— failed`. *(My call: a fourth chip state; failed is a terminal state like done.)* |

Other edges:

- **An agent's place is removed or renamed while it runs** (project deleted, environment
  removed): its next call fails whole in its own thread, as any call against a missing project
  does today. No special handling.
- **Unlinking the provider or account an agent is using**: as today for the on-screen agent;
  applied to each affected agent.
- **Two windows** (`WindowGroup`): the table of agents is per window, as the harness is today.

## Testing

Per CONTRIBUTING.md and `docs/agents/e2e.md`. At minimum:

- **WakilKit unit tests**: the per-place agent table; a switch of each kind (org, project,
  environment) leaves the other place's agent running, its thread intact and its `turnInFlight`
  unchanged; a chip's state transitions (working → waiting → working → done → cleared on visit);
  `shutdown` stops every agent.
- **Pinning tests, one per path above**: an agent started in place A, the operator switched to
  B, then the agent's call resolves against A — through the socket, through the window's
  binaries, and through an agent-facing binary. These are the tests that matter most; each must
  be shown to fail with the pin removed.
- **Invariant 4**: an agent in org A, the operator in org B; the agent's processes carry org A and
  cannot resolve org B's secrets.
- **Journal**: an entry from a background agent carries its session and place.
- **E2E (the auditor)**: start an agent, switch org, start a second agent, return; the first
  agent's thread shows its work and the journal has both agents' entries. Add a retrodiction in
  the style of `e2e/retrodiction/5-switch-stops-the-journal.patch` for "a switch retargets a
  running agent".

## How it lands — stacked PRs, one unit of work each

A suggested order; the plan settles it.

1. The per-place agent table, behaviour unchanged (one place in use).
2. Per-place stores: panes, layout, terminals, editor, broker take a place; nothing torn down on a
   switch. Likely several PRs of its own.
3. `wakilcore` honours `WAKIL_PROJECT`/`WAKIL_ENVIRONMENT`.
4. Pinning: the four paths, with their tests.
5. The switches: queue deleted; project/env switches keep agents.
6. Layout scope gains the environment.
7. The chips.
8. The journal fields.
9. Charter, design-language and glossary amendments.

## Charter changes this sub-phase makes

- **Invariant 5** is amended: *exactly one place is on screen; each agent is pinned to the place
  it started in and never follows the operator's.* The implicit-scope argument stands — no tool
  call grows an explicit project argument.
- **Glossary**: add **Place** (an organization, project and environment); amend **Active
  context** to "the place on screen" and note that an agent resolves against its own place; amend
  **Layout scope** to include the environment.
- **`AgentInstructions` rule 4**: the agent's own context switches are refused, not merely
  discouraged.
- **`design-language.md`**: the chips, as an amendment to §1's "futurism through absence".
- **Decision 41** records the operator's decisions above.

## Calls made (not discussed with the operator)

- Agent-dispatched context switches are refused.
- A provider switch affects only the on-screen place's agent.
- Quitting with agents running asks nothing.
- A failed agent gets a red `— failed` chip.
- Amber means a parked approval only; a question asked in text shows as done.
- The journal gains fields only; no reader in this sub-phase.
- Window-to-binary pinning mechanism (per-call place or per-place clients) left to the builder,
  bounded by Invariant 5.

## Open questions

1. **Where on the phase map** this sits. **Still open on 2026-10-17**, after all four plans were
   built: Decision 41 records the design, but the charter's §8 has no row for it yet, and none was
   added without the operator placing it.
