# Wakil — Charter

**Status:** living document · **Created:** 2026-09-03 · **Owner:** Yehia Khalil

The north star, not a spec. Phase specs live on their feature's branch and must conform
to it. If a phase spec needs to violate an invariant here, the charter changes
first — deliberately, with a dated entry.

**Keep this under 4,000 words** (`make docs-check`, run by `make test`). This file is an
index: the reasoning lives in `decisions.md`, `open-questions.md` and `phase-log.md`.
Numbers are the address, so citations by number still land.

---

## 1. What Wakil is

Wakil is a native macOS workspace that collapses everything work-related into one
surface driven by conversation. It holds a single active context — an organization, a
project, an environment — and every tool inside it inherits that context automatically.
You never tell Wakil *which* Jira, *which* database, *which* Claude account. You tell it
what you want.

**The test, for settling future arguments:**

> A feature earns its place in Wakil only when its absence forces you to leave.

The invention is not integration but **ambient context** — (org, project, environment) as
implicit state every tool resolves against — and **dual-driven panes**, where speaking and
clicking are the same operation on the same state.

## 2. Who it's for

**Now:** the operator, across two organizations (Initech Labs, Umbrella) with separate
Jira sites, chat identities and Claude subscriptions, and multi-repository projects.

**Later, possibly:** other developers. This shapes one thing today: the core
must stay headless and provider-agnostic, so the shell is replaceable and nothing
assumes a single user. It does **not** justify building multi-user features now.

## 3. The frictions it removes

In rough order of daily pain:

1. **Identity re-selection** — every tool asks which account, every time.
2. **Context reconstruction** — rebuilding "where was I" on every switch.
3. **Source-blind search** — guessing whether a decision is in Jira, Slack or email
   before you can look.
4. **Tool fragmentation** — DB client, API client, terminal, editor, browser, each with
   its own idea of which project and environment you're in.
5. **Hands on keyboard for multi-step chores** — *fetch a record, then call an endpoint
   with that value* takes three tools and manual copying.

## 4. Invariants

Rules no phase may break.

1. **Agent-agnostic core.** Nothing outside the harness adapter knows Claude exists.
   Abstraction is at the *harness* level (loop, tools, context management) — not the
   model level.
2. **Actions are the only mutation path.** Every pane exposes an enumerated action
   registry. UI controls and the agent dispatch the same actions. Two code paths to the
   same state is forbidden.
3. **Panes are observable.** The agent can read any pane's state. Deictic references
   ("this table", "that response") resolve against what is actually on screen.
4. **An organisation is a credential boundary; a provider carries its own auth.**
   An organisation owns its adapter credentials and secrets, stored in the Keychain
   under `wakil:<org>:<ref>`. Cross-org bleed must be structurally impossible — by the
   service name, by the per-org directory, and by `Resolve()`'s check — not merely
   avoided. A **provider** (a Claude subscription, Codex, a local model) owns its own
   authentication; for Claude Code that is a config dir and an OAuth token. One
   organisation may hold several providers, and one provider may serve several
   organisations — which holds because `buildLaunch` always passes `--strict-mcp-config`,
   so Wakil's sessions ignore the `WAKIL_ORG` a config dir pins (only plain `claude` reads
   it). A saved browser password is a credential too: only in the Keychain, never the
   agent's, the store's, a file's or a log's.
5. **Exactly one place on screen; each agent keeps its own.** Implicit scope is the
   product; an explicit project argument would forfeit it. Decision 41.
6. **Read-only until a write earns its way in.** Writes are added per adapter with
   deliberate justification, never by default. Ten have earned in; the justification
   for each, and what each leaves refused, is in `decisions.md` under *"Invariant 6 — the
   writes that have earned in"*.

   | Write | Adapter | Earned |
   |---|---|---|
   | Row mutation — `INSERT`, `UPDATE`, `DELETE` | SQL databases | 2026-09-09 |
   | Issue status transition | Jira | 2026-09-14 |
   | Request with a mutation method | HTTP | 2026-09-17 |
   | File write — local files inside the project's roots | wakil-files | 2026-10-11 |
   | File create, move, Move to Trash — inside the roots | wakil-files | 2026-10-17 |
   | Stage, unstage, discard, commit — local git inside the project's roots | wakil-git | 2026-10-21 |
   | Fetch, pull, push, sync, clone — remote git, with the organisation's account | wakil-git | 2026-10-22 |
   | Switch, create, rename, delete branches; stash, apply, pop, drop — local git inside the roots | wakil-git | 2026-10-23 |
   | Merge, rebase, continue, skip, abort, resolve — local git inside the roots | wakil-git | 2026-10-24 |
   | Act in a web page — click, type, select, press — on a site the operator allowed for the conversation; every act on a production host gated | the browser | 2026-10-25 |

   **Still refused:** schema mutation (every DDL verb, `TRUNCATE` explicitly), Mongo
   mutation, every `wakil-pm` write but the transition, any request leaving the `baseUrl`
   of the API entry it targets, a command the **agent** runs in a terminal pane (it adds
   the organisation's credentials, not reach, to the agent's bare shell; the refusal
   defends Invariant 4), and a password, card or one-time-code field typed or filled by
   the agent.

   **Each write declares its own price** rather than inheriting one from its kind; see
   §9 and Decision 25.
7. **Writes are never voice-confirmable.** Voice may propose a mutation; only typed
   confirmation may execute one — wherever the write's price is *gate*. An adapter may
   declare a price of *allow*, and then a spoken turn does execute the write (Decision 25);
   the editor's file write is *allow*, voice included (Decision 36). Credential writes
   declare no price: the settings pane is operator-only, so voice never reaches them
   (Decision 30).
8. **Environment is always visible.** The active environment is on screen at all times.
   Production looks alarming.
9. **MCP-first for actions, direct API for sync.** MCP is the default transport for
   agent-facing actions. Bulk and incremental reads that feed an index use real APIs.
10. **Capability and action layers stay separate.** Capabilities are headless and usable
    without the app. Actions own pane state and live in the app.
11. **Agent provider and speech provider are pluggable and per-organization.** Neither may
    be assumed anywhere outside its own adapter.

## 5. Non-goals

Revisit deliberately, not casually.

- **Not a VSCode replacement.** The native editor is a lightweight, dual-driven Monaco
  surface (Decision 17), not a bid for VS Code's extension ecosystem or debugger. Heavy
  hands-on coding stays in real VS Code.
- **Not multi-user.** No teams, sharing, permissions or sync in any planned phase.
- **Not proactive** in Phases 1–3. Wakil does not interrupt. Revisited in Phase 4
  (Decision 14).
- **Not a Jira/Slack/email client.** Wakil surfaces and acts; no feature parity with the
  tools it binds.
- **Not cross-organization.** No query spans two orgs. Multi-repo covers the real need.
- **Not a product.** No pricing, packaging, marketing or distribution work.
- **Not Claude-via-API-key.** Claude access is subscription-only. API keys remain a
  legitimate mode for *other* providers.

## 6. Decisions and rationale

An index of 1–32, 36 and 41; `decisions.md` holds all 92 in full (two share number 41). ***Reverse if* is a gist.** Read it first: — means none stated,
true of 55 of the 92 entries and 14 listed here.

| # | The call | Reverse if |
|---|---|---|
| 1 | Native macOS application | voice gets cut |
| 2 | Swift/SwiftUI + Metal for the shell | the app goes cross-platform |
| 3 | Capability layer is a separate headless process, not in-app | — |
| 4 | A provider owns an opaque harness credential bundle | — |
| 5 | Three agent access modes, all supported: subscription, API key, local endpoint | — |
| 6 | Credentials at the org, scope at the project | — |
| 7 | A project has N roots, not one repository | — |
| 8 | Environment is a first-class project dimension | — |
| 9 | Every pane is dual-driven, via a shared action registry | — |
| 10 | Voice is a transport, not a command language | operators often have to undo what the fast path ran |
| 11 | Push-to-talk capture, not a wake word | — |
| 12 | Many sessions, with optional continuity | — |
| 13 | Session history is read from disk | — |
| 14 | Reactive in v1; proactivity deferred | — |
| 15 | Recall ships as grouped per-source results, not unified ranking | — |
| 16 | Two independent axes: harness and provider | — |
| 17 | Native Monaco editor, dual-driven — not embedded VS Code | the VS Code ecosystem proves disqualifying |
| 18 | Speech-to-text is pluggable, and selected per organization | — |
| 19 | Wakil.app serves its own MCP surface; the agent reaches panes only through it | a pane needs state the registry cannot own |
| 20 | A record is edited two ways — by writing the statement, or in the cell — and both compile to the same gated action | few real result sets qualify |
| 21 | Setup is a UI surface, and the shell is its peer rather than its prerequisite | operators would all rather edit JSON |
| 22 | A Claude account is shared across orgs; an org's credentials are not | an operator wants a separate account per org |
| 23 | SwiftTerm's headless engine, and nothing else, as `WakilKit`'s first external dependency | its OSC 133 gaps deepen, or it goes unmaintained |
| 24 | A pane's readable state is a discriminated union keyed by `kind` | a pane kind needs a second discriminator |
| 25 | A write's price rides on the action, not on its kind | a price must vary on a second axis |
| 26 | An environment declares whether it is production; its name supplies only the default | the flag is edited so rarely the name still rules |
| 27 | An agent's write to a draft request is refused while the operator has unsaved edits in it | the refusal fires in ordinary two-handed work |
| 28 | A provider's credential is the config dir plus a `setup-token` Wakil mints itself, and Wakil never implements refresh | the CLI can refresh an idle config dir |
| 29 | Go is the only process that writes the Keychain; a provider credential is minted and stored atomically there | the journal can carry a secret without serialising it |
| 30 | Settings is a pane the agent may read and never drive | a settings action carries no credential |
| 31 | `ProviderLogin` is a kind-keyed protocol; the seam splits at the human, not the language | a second kind shares Claude's mint shape |
| 32 | An organisation unlinks a binding, never removes a provider; `home` is an artefact | `claude` revokes per config dir, not per machine |
| 36 | The editor is the project's one code surface: file write earns its way in, and the Git pane folds into it | an editor write reaches what the agent's own tools cannot |
| 41 | Each agent keeps the place it started in, and switching tears nothing down | agents should follow the operator |

## 7. Open questions

Reasoning in `open-questions.md`, where a closed question keeps its entry.
**`Blocks` is a scheduling instrument** — check it against the phase map whenever either
changes.

| # | Question | Blocks | Status |
|---|---|---|---|
| 3 | When does grouped recall stop being enough and justify an index? | Phase 4 | **open** |
| 4 | Is the embedded editor ever genuinely needed? | Phase 3 | **open** |
| 6 | ~~Which PM provider ships first?~~ Jira, shipped. **Azure DevOps when?** | Phase 3 | half open |
| 15 | Can a Jira transition automation break Invariant 6's reversibility argument? | 2c-vi | **open** |
| 16 | `Connection` means an org account in §9 but a database in `wakil-db`'s schemas. Which keeps the word? | — | **open** |
| 17 | Does Wakil ever speak? | — | **open** |

**Closed** (answers in `open-questions.md`): 1 shell (Swift) · 2 per-session env ·
5 continuity default · 7 chat and inbox (**Slack, Gmail**) · 8 config outside a repo ·
9 local `ANTHROPIC_BASE_URL` · 10 default STT (**Apple**; Whisper selectable) · 11 void as
Core · 12 price of a cell edit · 13 org switch in the window · 14 org and project
creation · 18 non-agent model (a role).

**5 open, 1 half open, 12 closed.** Only question 15 blocks work: 2c-vi's write half.

## 8. Phase map

The status table: what is built and what each thing waits on. Each phase has a testable
exit criterion; walk findings are in `phase-log.md`.

**`Met`:** *walked* — an operator ran the acceptance runbook against the live app;
*accepted* — marked met without one.

| | Delivers | Met | Waits on |
|---|---|---|---|
| **Phase 1** | Capability layer: five headless MCP servers, the org/provider model, session discovery | **2026-09-07**, walked | — |
| **2a** | Harness, action registry, agent bridge, write gate, context switcher, one crude pane | **2026-09-08**, walked | — |
| **2b-i** | Third action kind, pane model, magnetic canvas, the rail, ⌘P/⌘K | **2026-09-15**, *accepted* | — |
| **2b-ii** | The void, planes, the Core, motion, the thought thread, production treatment | **2026-09-10**, walked | — |
| **2b-iii** | Write-gate UI and the first `.mutate` | **2026-09-10**, *accepted* | — |
| **2b-iv** | The void as the Core; the sphere deleted; one Metal layer | **2026-09-09**, walked | — |
| **bridge** | The permission-prompt bridge — a live agent's mutation reaches the plane | **2026-09-10**, walked | — |
| **2b-v** | Session resume, as a fork with recorded lineage | **2026-09-10**, *accepted* | — |
| **2b-vi** | Provider picker | **2026-09-11**, walked | — |
| **2b-vii** | Signing | — | **externally blocked**: no paid Developer ID for notarisation |
| **2b-viii** | The org switch | **2026-09-15**, walked ×3 | — |
| **2c-i** | The data surface: grid, selection model, virtualization, §8 chrome | **2026-09-12**, walked | — |
| **2c-ii** | DB pane in full — the pane owns its query | **2026-09-13**, walked ×3 | D1 deliberately unfixed |
| **integer fidelity** | `JSONValue.integer(Int64)` | **2026-09-13** | — |
| **conversation layouts** | Pane arrangements keyed by conversation and project | **2026-09-21**, walked | — |
| **2c-ii-b** | Editing records from the DB pane | **2026-09-15**, walked; three checks *accepted* | — |
| **2c-ii-c** | DB pane copy (⌘C, Copy as JSON), cancel (`db_cancel`, a per-pane read flight) and the row detail strip | **2026-10-15**, walked | — |
| **2c-iii** | Terminal pane — PTY, a shell opened at a path, the write-gate boundary for a shell | **2026-09-18**, walked | — |
| **2c-iv** | API client pane; `wakil-http` gains a gated write method | **2026-10-04**, walked ×3 | — |
| ~~**2c-v**~~ | Session browser — **cut** | — | — |
| **2c-vi** | PM board pane — Jira issues as a dual-driven kanban board | — | deferred 2026-10-06; q15 for writes |
| **2d-i** | Identifier resolution — transcripts resolved against the identifiers in scope | **2026-10-07**, walked | — |
| **2d-ii** | Push-to-talk, Apple STT, live transcription, composer, listening state | **2026-10-08**, walked | — |
| **2e** | The settings pane — an account added from Wakil with no credential in the operator's hands; unlink; the DSN write; the residue named | **2026-09-30**, walked | — |
| **Phase 3** | Breadth — editor, API client UI, chat and inbox adapters | — | — |
| **3a-i** | Git pane, read-only: changes by root, the spine, the Monaco diff host | **2026-10-09**, walked | — |
| **3a-ii** | Stage, unstage, commit — the fourth write | **2026-10-22**, walked | 3a-i |
| **3a-ii-b** | Stage and Unstage Selected Ranges in the diff tab; ✨ drafts the commit message with the quick model, the operator commits | **2026-10-22**, walked | 3a-ii |
| **2e-ii** | Add, rename and remove a project and an environment from Settings | — | 3a-ii |
| **2e-iii** | Add, edit and remove an environment's API entries from Settings, the token to the Keychain; databases edited in place, removal confirmed | — | 2e-ii |
| **2e-iv** | Edit a database's connection in Settings — host, port, database and user in project.json, only the password in the Keychain; Edit replaces Replace connection | — | 2e-iii |
| **3a-iii** | A git account per organisation — sign in, token or SSH key in the Keychain; push, pull, fetch, sync, clone; agent instructions | **2026-10-22**, walked | 3a-ii |
| **3a-iv** | Branches and stash — the branch picker in the context line, stash, pop, apply | **2026-10-23**, walked | 3a-iii |
| **3a-v** | Conflicts, history and blame — accept current or incoming, the Timeline, inline blame | — | 3a-ii |
| **3c** | Browser | — | — |
| **3c-i** | Pane, tabs, a profile per organisation | — | — |
| **3c-ii** | Agent reach | **2026-10-27**, walked | 3c-i |
| **3c-iii** | History, bookmarks, links | — | 3c-i |
| **3d** | The browser you live in | — | 3c |
| **3d-i** | Tab groups, automatic or your own; the pull-request group; pins per project; vertical tabs | — | 3c-iii |
| **3d-iii** | Picture in picture | — | 3c-i |
| **3d-iv** | Passwords in the Keychain | — | 3c-ii |
| **Conversations** | Several live conversations per place: new (⌘N), switch (Running, ⌘P, chips), close (⌘⇧W); folds New conversation and Track | — | — |
| **Names** | Conversations named by the quick model and renamed anywhere; browser tabs renamed | — | 3d-i (browser half) |
| **Keyboard** | One keymap; Settings → Keyboard rebinds menu commands | — | — |
| **Phase 4** | Depth — proactivity, recall index, a second harness, earned write paths | — | demand-driven |


## 9. Glossary

Terms coined for this project. Phase specs must use them consistently.

Terms coined for this project. Phase specs must use them consistently.

| Term | Meaning |
|------|---------|
| **Organization** | A credential boundary: adapter credentials and secrets in the Keychain under `wakil:<org>:<ref>`, plus a set of authenticated connections. One or more providers may serve it (Invariant 4). initech and Umbrella are organizations. |
| **Project** | A unit of work inside one organization. Has 1..n roots, a set of scopes, and a set of environments. |
| **Root** | One repository or directory belonging to a project. |
| **Environment** | A named target within a project — local, staging, production. Carries DB and HTTP configuration. Meaningless for PM, chat, and inbox. **Production is declared, not spelled**: a `production` flag, whose default the name supplies (Decision 26). |
| **Connection** | An authenticated account at the organization level: a Jira site, a Slack workspace, a mailbox. |
| **Scope** | A project-level narrowing of a connection: a Jira project key, a channel list, an email label set. |
| **Layout scope** | What a pane arrangement is filed under: the organization, project, environment and — once a conversation exists — its lineage root. The one key both pane stores and layout persistence share. **Not a Scope** — that narrows a connection; this names a canvas. |
| **Lineage root** | The oldest ancestor of a session: the identity a conversation — a chain of sessions — keeps across every resume that forked it. What ⌘P collapses a chain to. |
| **Place** | An (organization, project, environment); one agent at most (Decision 41). |
| **Active context** | The place on screen. Agents resolve against their own. |
| **Capability layer** | Headless, UI-free operations ("run this SQL, return rows"). Separate processes, usable without Wakil.app. |
| **Action layer** | In-app, stateful operations that own pane state, call capabilities, and update the UI. |
| **Pane** | A dual-driven surface in Wakil.app: state, an action registry, and readable state. DB viewer, API client, terminal. |
| **Action** | An enumerated, journalled state transition in a pane. The only path by which anything mutates. |
| **Harness** | An agent runtime supplying the loop, tool orchestration, and context management. Claude Code is the first. Not the same as a provider. |
| **Provider** | The model endpoint an agent talks to, plus its auth mode — subscription, API key, or local endpoint. Several providers can share one harness. |
| **Session** | One harness conversation, bound to exactly one provider, with its transcript in that provider's store. Wakil mints the id; a resume is a **fork** under a fresh id with recorded lineage, never a continuation (Decision 12, open question 5). |
| **Speech provider** | An STT implementation: Apple on-device, local Whisper, or a cloud API. Selected per organization. |
| **Write gate** | `writeGate`: the one policy function every dispatched action passes before its handler runs. Answers allow / gate / block from the action's price, its origin, and the active environment. |
| **Write price** | The pair of answers an **action** declares for itself — one for production, one outside it. The write gate reads it instead of the action's kind, so two adapters' writes can cost differently. Decision 25. |
| **PTY** | A pseudo-terminal: the kernel fd pair that lets Wakil host a program which believes it is attached to a terminal. |
| **Terminal pane** | The pane hosting an interactive shell on a PTY, opened at a path, carrying the active environment's variables and the org's credentials. Two surfaces: the **block history** of finished blocks, and the **live grid** a foreground program draws on. |
| **Block** | One submitted command and everything it produced — exit code, duration, output. The terminal pane's unit of state, and the granularity of one terminal action. |
| **Plane** | A surface that takes the whole window, in front of the canvas — `ConfirmationPlane`, `OrgPlane`. Never laid out, never saved, never in a layout. *(`design-language.md` §3's planes are depth layers, a different sense.)* |
| **Journal** | The append-only record of every dispatched action — name, parameters, outcome — written whether it ran, was refused, or was blocked. Swift-only, so a `wakil` CLI mutation leaves no entry. A parameter marked on its `Action` is written `[redacted]`, its name kept (Decision 29). |
| **Binding** | One (organization, provider id) pair: a record, plus a Keychain item at `wakil:<org>:provider:<id>`. What an organization adds and unlinks — the *account* is the config dir, and one account may carry a different id in each organization that binds it (Decision 32). A **credential-less binding** has no Keychain item: it draws a row and cannot start a session. |
| **Partiality** | What a listing reports about *what it could not read*, carried beside the data rather than inferred from its length — `SessionList.Skipped`/`UnreadProviders`, `Rows.Truncated`. A short answer and a trimmed one must never look alike, and a surface that shows the data owes the operator the partiality with it. |
