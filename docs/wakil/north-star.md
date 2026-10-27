# Wakil — Charter

**Status:** living document · **Created:** 2026-09-03 · **Owner:** Yehia Khalil

This is the north star, not a spec. It records what Wakil is, the rules no phase may
break, what Wakil is deliberately not, and why each decision was made. Phase specs live
in `docs/superpowers/specs/` and must conform to this document. If a phase spec needs to
violate an invariant here, the charter changes first — deliberately, with a dated entry.

**Keep this under 4,000 words. Past that it has become a spec and will rot.** That is not
a style note. It is the rule that failed: by 2026-09-14 this document was **13,962
words**, and a decision was costed on two premises it contradicted forty lines away.

**This file is an index; the reasoning lives in three logs** — `decisions.md`,
`open-questions.md`, `phase-log.md`. §6, §7 and §8 keep the tables you schedule from.
Numbers are the address, so citations by number still land. How the splits went is in `phase-log.md`.

**The check runs.** `make docs-check` fails over 4,000 words and `make test` runs it.
Before 2026-09-22 it was a human habit, and the file sat over the limit for five commits unnoticed.

---

## 1. What Wakil is

Wakil is a native macOS workspace that collapses everything work-related into one
surface driven by conversation. It holds a single active context — an organization, a
project, an environment — and every tool inside it inherits that context automatically.
You never tell Wakil *which* Jira, *which* database, *which* Claude account. You tell it
what you want.

**The test, for settling future arguments:**

> A feature earns its place in Wakil only when its absence forces you to leave.

Wakil's invention is not integration. Integrations are assembly work. The invention is
**ambient context** — (org, project, environment) as implicit state every tool resolves
against — and **dual-driven panes**, where speaking and clicking are the same operation
on the same state.

## 2. Who it's for

**Now:** The operator, working across two organizations (Initech Labs, Umbrella) with separate Jira
sites, separate chat identities, separate Claude subscriptions, and projects that span
multiple repositories.

**Later, possibly:** other developers. This shapes exactly one thing today — the core
must stay headless and provider-agnostic, so the shell is replaceable and nothing
assumes a single user. It does **not** justify building multi-user features now.

## 3. The frictions it removes

Concrete, in rough order of daily pain:

1. **Identity re-selection.** Every tool asks which account, every time. Two Jira sites,
   two chat identities, two Claude subscriptions.
2. **Context reconstruction.** Rebuilding "where was I" on every switch between tickets,
   projects, and organizations.
3. **Source-blind search.** A decision lives in a Jira comment, a Slack thread, or an
   email, and finding it means guessing which before you can look.
4. **Tool fragmentation.** A DB client, an API client, a terminal, an editor, a browser
   — each with its own idea of which project and environment you're in.
5. **Hands on keyboard for multi-step chores.** Chains like *fetch a record, then call an
   endpoint with that value* are mechanical but require three tools and manual copying.

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
   organisations.

   **Both halves are delivered.** Two Claude accounts on one org since Phase 1; and one
   provider serving several orgs, because `buildLaunch` always passes `--strict-mcp-config`,
   so Wakil's sessions ignore the `WAKIL_ORG` a config dir pins and only plain `claude`
   still reads it *(measured 2026-09-22)*. History in `phase-log.md`.
5. **Exactly one place on screen; each agent keeps its own.** Implicit scope is the
   product; an explicit project argument would forfeit it. History: Decision 41.
6. **Read-only until a write earns its way in.** Writes are added per adapter with
   deliberate justification, never by default. Ten have earned in. The justification
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
   of the API entry it targets, a command the **agent** runs in a terminal pane — the
   agent already has a bare shell, so a terminal run adds the organisation's credentials,
   not reach, and the refusal defends Invariant 4 — and a password, card or one-time-code field typed by the agent.

   **Each write declares its own price** rather than inheriting one from its kind; see
   §9 and Decision 25.
7. **Writes are never voice-confirmable.** Voice may propose a mutation; only typed
   confirmation may execute one — wherever the write's price is *gate*. *(2026-09-17: the
   per-adapter exception this invariant never had. An adapter may declare a price of
   *allow*, and then a spoken turn does execute the write. Phase 2's exit criterion
   required it. Decision 25 is the mechanism.)* *(2026-09-22: 2e's credential
   writes declare no price; Decision 30 makes the settings pane operator-only, so voice
   never reaches them. 2026-10-11: the editor's file write declares *allow*, voice
   included — Decision 36.)*
8. **Environment is always visible.** The active environment is on screen at all times.
   Production looks alarming.
9. **MCP-first for actions, direct API for sync.** MCP is the default transport for
   agent-facing actions. Bulk and incremental reads that feed an index use real APIs.
10. **Capability and action layers stay separate.** Capabilities are headless and usable
    without the app. Actions own pane state and live in the app.
11. **Agent provider and speech provider are pluggable and per-organization.** Neither may
    be assumed anywhere outside its own adapter.

## 5. Non-goals

Explicit, as of 2026-09-03. Revisit deliberately, not casually.

- **Not a VSCode replacement.** The native editor is a lightweight, dual-driven Monaco
  surface (Decision 17), not a bid for VS Code's extension ecosystem or debugger. Heavy
  hands-on coding stays in real VS Code.
- **Not multi-user.** No teams, sharing, permissions, or sync in any planned phase.
- **Not proactive** in Phases 1–3. Wakil does not interrupt. Revisited in Phase 4 —
  see Decision 14.
- **Not a Jira/Slack/email client.** Wakil surfaces and acts; it does not attempt
  feature parity with the tools it binds.
- **Not cross-organization.** No query spans two orgs. Multi-repo covers the real need.
- **Not a product.** No pricing, packaging, marketing, or distribution work.
- **Not Claude-via-API-key.** Claude access is subscription-only. API keys remain a
  legitimate mode for *other* providers.

## 6. Decisions and rationale

Each entry: the call, why, and what would change our mind.

**Read the third column first** — **15 of 32 entries state no reversal condition**, and
`decisions.md`'s header says what that gap costs.

| # | The call | Reverse if |
|---|---|---|
| 1 | Native macOS application | voice gets cut |
| 2 | Swift/SwiftUI + Metal for the shell | the app goes cross-platform |
| 3 | Capability layer is a separate headless process, not in-app | **— none stated —** |
| 4 | A provider owns an opaque harness credential bundle | **— none stated —** |
| 5 | Three agent access modes, all supported: subscription, API key, local endpoint | **— none stated —** |
| 6 | Credentials at the org, scope at the project | **— none stated —** |
| 7 | A project has N roots, not one repository | **— none stated —** |
| 8 | Environment is a first-class project dimension | **— none stated —** |
| 9 | Every pane is dual-driven, via a shared action registry | **— none stated —** |
| 10 | Voice is a transport, not a command language | **— none stated —** |
| 11 | Push-to-talk capture, not a wake word | **— none stated —** |
| 12 | Many sessions, with optional continuity | **— none stated —** |
| 13 | Session history is read from disk | **— none stated —** |
| 14 | Reactive in v1; proactivity deferred | **— none stated —** |
| 15 | Recall ships as grouped per-source results, not unified ranking | **— none stated —** |
| 16 | Two independent axes: harness and provider | **— none stated —** |
| 17 | Native Monaco editor, dual-driven — not embedded VS Code | the VS Code ecosystem proves disqualifying |
| 18 | Speech-to-text is pluggable, and selected per organization | **— none stated —** |
| 19 | Wakil.app serves its own MCP surface; the agent reaches panes only through it | a pane needs state the registry cannot own |
| 20 | A record is edited two ways — by writing the statement, or in the cell — and both compile to the same gated action | few real result sets qualify |
| 21 | Setup is a UI surface, and the shell is its peer rather than its prerequisite | operators would all rather edit JSON |
| 22 | A Claude account is shared across orgs; an org's credentials are not | an operator wants a separate account per org |
| 23 | SwiftTerm's headless engine, and nothing else, as `WakilKit`'s first external dependency | its OSC 133 gaps deepen, or it goes unmaintained |
| 24 | A pane's readable state is a discriminated union keyed by `kind` | a pane kind needs a second discriminator |
| 25 | A write's price rides on the action, not on its kind | a price must vary on a second axis |
| 26 | An environment declares whether it is production; the name is only the default | the flag is edited so rarely the name still rules |
| 27 | An agent's write to a draft request is refused while the operator has unsaved edits in it | the refusal fires in ordinary two-handed work |
| 28 | A provider's credential is the config dir plus a `setup-token` Wakil mints itself, and Wakil never implements refresh | the CLI can refresh an idle config dir |
| 29 | Go is the only process that writes the Keychain; a provider credential is minted and stored atomically there | the journal can carry a secret without serialising it |
| 30 | Settings is a pane the agent may read and never drive | a settings action carries no credential |
| 31 | `ProviderLogin` is a kind-keyed protocol; the seam splits at the human, not the language | a second kind shares Claude's mint shape |
| 32 | An organisation unlinks a binding, never removes a provider; `home` is an artefact | `claude` revokes per config dir, not per machine |
| 36 | File write earns in (allow everywhere, inside the roots); the Git pane folds into the editor | an editor write reaches what the agent's own tools cannot |
| 41 | One agent per place, kept; switching tears nothing down | agents should follow the operator |

***Reverse if* is a gist**; `decisions.md` states each in full.

## 7. Open questions

Recorded honestly rather than guessed; the reasoning is in `open-questions.md`, and a
closed question keeps its entry.

**`Blocks` is a scheduling instrument, not a label** — check it against the phase map
whenever either changes. It has gone stale once (`phase-log.md`, 2026-09-15).

| # | Question | Blocks | Status |
|---|---|---|---|
| 1 | Swift/SwiftUI or Tauri for the shell? | — | closed 2026-09-03 |
| 2 | Can the Agent SDK take per-session env? | — | closed 2026-09-03 |
| 3 | When does grouped recall stop being enough and justify an index? | Phase 4 | **open** |
| 4 | Is the embedded editor ever genuinely needed? | Phase 3 | **open** |
| 5 | Default continuity behaviour: resume the last session, or always start fresh? | — | closed 2026-09-07 |
| 6 | ~~Which PM provider ships first?~~ Jira, shipped. **Azure DevOps when?** | Phase 3 | half open |
| 7 | Which chat and inbox providers first? | — | closed 2026-10-08 — **Slack and Gmail** |
| 8 | Where does project config live when the project directory is not itself a repo? | — | closed 2026-09-15 |
| 9 | Does Claude Code honour ANTHROPIC_BASE_URL against a local Anthropic-compatible endpoint? | — | closed 2026-09-08 |
| 10 | Which STT engine ships as the default? | — | closed 2026-09-16 — **Apple**, measured; Whisper stays selectable |
| 11 | Should the void itself be the Core, with no sphere at all? | — | closed 2026-09-09 |
| 12 | ~~Is `confirm`-then-Run the right price for a cell the operator never wrote a statement for?~~ | — | closed 2026-09-15 |
| 13 | How does an operator change organisation without quitting? | — | closed 2026-09-14 |
| 14 | Where does org and project *creation* live, from inside one org? | — | closed 2026-09-15 |
| 15 | Can a Jira transition automation break Invariant 6's reversibility argument? | 2c-vi | **open** |
| 16 | `Connection` means an org account in §9 but a database in `wakil-db`'s schemas. Which keeps the word? | — | **open** |
| 17 | Does Wakil ever speak? | — | **open** |
| 18 | Which model serves a non-agent job? | — | closed 2026-10-08 — a role |

**5 open, 1 half open, 12 closed.** Only question 15 blocks work: 2c-vi's write half.

## 8. Phase map

Each phase has an exit criterion that can be tested. **This is the status table
— what is built, what is not, and what each thing waits on.** Everything else is in
**`phase-log.md`**: what each walk found, which checks were accepted rather than walked,
how the phases split. Decision 1 still rests on 2d shipping.

**How to read `Met`.** *Walked* means an operator ran the acceptance runbook against the
live app; *accepted* means it was marked met without one.

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
| **2b-vii** | Signing | — | **externally blocked**: notarisation needs a paid Developer ID this machine does not hold |
| **2b-viii** | The org switch | **2026-09-15**, walked ×3 | — |
| **2c-i** | The data surface: grid, selection model, virtualization, §8 chrome | **2026-09-12**, walked | — |
| **2c-ii** | DB pane in full — the pane owns its query | **2026-09-13**, walked ×3 | D1 deliberately unfixed |
| **integer fidelity** | `JSONValue.integer(Int64)` — a fix, not a sub-phase | **2026-09-13** | — |
| **conversation layouts** | Pane arrangements keyed by conversation and project — cross-cutting, not a sub-phase | **2026-09-21**, walked | — |
| **2c-ii-b** | Editing records from the DB pane | **2026-09-15** — *walked 2026-09-14, its three open checks accepted* | — |
| **2c-ii-c** | DB pane copy, cancel and row detail | **2026-10-15**, walked | — |
| **2c-iii** | Terminal pane — PTY, a shell opened at a path, the write-gate boundary for a shell | **2026-09-18**, walked | — |
| **2c-iv** | API client pane; `wakil-http` gains a gated write method | **2026-10-04**, walked ×3 | — |
| ~~**2c-v**~~ | Session browser — **cut 2026-09-16** (`phase-log.md`) | — | — |
| **2c-vi** | PM board pane — Jira issues as a dual-driven kanban board | — | deferred 2026-10-06; q15 for writes |
| **2d-i** | Identifier resolution — transcripts resolved against the identifiers in scope | **2026-10-07**, walked | — |
| **2d-ii** | Push-to-talk, Apple STT, live transcription, composer, listening state | **2026-10-08**, walked | — |
| **2e** | The settings pane — accounts added and unlinked from Wakil | **2026-09-30**, walked | the rest of 2c; **built before 2d** |
| **Phase 3** | Breadth — editor, API client UI, chat and inbox adapters | — | — |
| **3a-i** | Git pane, read-only: changes by root, the spine, the Monaco diff host | **2026-10-09**, walked | — |
| **3a-ii** | Stage, unstage, commit — the fourth write | **2026-10-22**, walked | 3a-i |
| **3a-ii-b** | Stage and Unstage Selected Ranges; ✨ drafts the commit message | **2026-10-22**, walked | 3a-ii |
| **2e-ii** | Add, rename and remove a project and an environment from Settings | — | 3a-ii |
| **2e-iii** | Add, edit and remove an environment's API entries from Settings | — | 2e-ii |
| **2e-iv** | Edit a database's connection in Settings; only the password in the Keychain | — | 2e-iii |
| **3a-iii** | A git account per organisation; push, pull, fetch, sync, clone | **2026-10-22**, walked | 3a-ii |
| **3a-iv** | Branches and stash — the branch picker in the context line, stash, pop, apply | **2026-10-23**, walked | 3a-iii |
| **3a-v** | Conflicts, history and blame — accept current or incoming, the Timeline, inline blame | — | 3a-ii |
| **3c** | Browser | — | — |
| **3c-i** | Pane, tabs, a profile per organisation | — | — |
| **3c-ii** | Agent reach | **2026-10-27**, walked | 3c-i |
| **3c-iii** | History, bookmarks, links | — | 3c-i |
| **3d** | The browser you live in | — | 3c |
| **3d-i** | Tab groups — automatic, named by the quick model, and your own; the pull-request group; pins per project; vertical tabs | — | 3c-iii |
| **3d-ii** | Identities inside an organisation | — | 3d-i |
| **3d-iii** | Picture-in-picture | — | 3c-i |
| **3d-iv** | Passwords in the Keychain | — | 3c-ii |
| **Conversations** | Several live conversations per place: new, switch, close | — | — |
| **Phase 4** | Depth — proactivity, recall index, a second harness, earned write paths | — | demand-driven |

## 9. Glossary

Terms coined for this project. Phase specs must use them consistently.

| Term | Meaning |
|------|---------|
| **Organization** | A credential boundary: adapter credentials and secrets in the Keychain under `wakil:<org>:<ref>`, plus a set of authenticated connections. One or more providers may serve it (Invariant 4, amended 2026-09-06). initech and Umbrella are organizations. |
| **Project** | A unit of work inside one organization. Has 1..n roots, a set of scopes, and a set of environments. |
| **Root** | One repository or directory belonging to a project. A microservice project has several. |
| **Environment** | A named target within a project — local, staging, production. Carries DB and HTTP configuration. Meaningless for PM, chat, and inbox. **Whether an environment is *production* is declared, not spelled**: it carries a `production` flag, and the name supplies the flag's default rather than the answer (Decision 26). |
| **Connection** | An authenticated account at the organization level: a Jira site, a Slack workspace, a mailbox. |
| **Scope** | A project-level narrowing of a connection: a Jira project key, a channel list, an email label set. |
| **Layout scope** | What a pane arrangement is filed under: the organization, project, environment and — once a conversation exists — its lineage root. The one key both pane stores and layout persistence share. **Not a Scope** — that narrows a connection; this names a canvas. |
| **Lineage root** | The oldest ancestor of a session, and so the identity one conversation keeps across every resume that forked it: a conversation is a chain of sessions, not one. What ⌘P collapses a chain to, and what an arrangement is filed under. |
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
| **Write price** | The pair of answers an **action** declares for itself — one for production, one outside it. Read by the write gate instead of the action's kind, so two adapters' writes can cost different things. Decision 25. |
| **PTY** | A pseudo-terminal. The kernel fd pair that lets Wakil host a program which believes it is attached to a terminal. |
| **Terminal pane** | The pane hosting an interactive shell on a PTY, opened at a path, carrying the active environment's variables and the org's credentials. Two surfaces: the **block history** of finished blocks, and the **live grid** a foreground program draws on. |
| **Block** | One submitted command and everything it produced — exit code, duration, output. The terminal pane's unit of state, and the granularity of one terminal action. |
| **Plane** | A surface that takes the whole window, in front of the canvas — `ConfirmationPlane`, `OrgPlane`. Never laid out, never saved, never in a layout. *(`design-language.md` §3 uses the word for a depth layer; the surface keeps it here.)* |
| **Journal** | The append-only record of every dispatched action — name, parameters, outcome — written whether it ran, was refused, or was blocked. Swift-only, so a `wakil` CLI mutation leaves no entry. A parameter marked on its `Action` is written `[redacted]`, its name kept (Decision 29). |
| **Binding** | One (organization, provider id) pair: a record, plus a Keychain item at `wakil:<org>:provider:<id>`. What an organization adds and unlinks — the *account* is the config dir, and one account may carry a different id in each organization that binds it (Decision 32). A **credential-less binding** has no Keychain item: it draws a row and cannot start a session. |
| **Partiality** | What a listing reports about *what it could not read*, carried beside the data rather than inferred from its length — `SessionList.Skipped`/`UnreadProviders`, `Rows.Truncated`. A short answer and a trimmed one must never look alike, and a surface that shows the data owes the operator the partiality with it. |
