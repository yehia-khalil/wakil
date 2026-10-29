# Connections: the operator's own MCP servers, per organization

**Date:** 2026-10-25
**Status:** design awaiting the operator's review. Piece 1 of
`2026-10-25-ticket-work-design.md`, and the foundation the other pieces read through. Calls the
designer made are under *Calls made for the operator*.

---

## Problem

An agent in Wakil can reach Wakil's own MCP servers and nothing else. `buildLaunch` always passes
`--strict-mcp-config` with the JSON `agentMCPConfigJSON` builds (`AgentMCPConfig.swift`), so the
operator's own servers — a code host, a PM tool's wiki, a design tool, a logs-and-metrics service,
an analytics service, a chat workspace — are unreachable from inside Wakil, though the same agent
reaches them in a plain terminal. That strictness is load-bearing (Invariant 4: it is why one
provider can serve several organizations), so the answer is not to drop it but to put the
organization's own servers into the config Wakil builds.

Separately, the Jira token can only be stored from a terminal (`wakil secrets set jira:<org>`);
the organization form asks for the Jira site and nothing else (`OrgPlane.swift`).

## Decided by the operator (2026-10-25)

1. **Connect the service's own MCP server to the running agent** — the cheap path — rather than
   writing a Wakil adapter per service. Wakil adds a thin layer only: the right account per
   organization, the token entered once in Wakil, writes gated.
2. **Per organization.** A project override is planned for, not built (a project on a different
   PM tool than the rest of its organization; open question 6).
3. **Tokens are entered in Wakil**, never only from a terminal. **The Jira token too.** The
   terminal command keeps working.
4. **One page per connection** listing its tools, each with an **Allow agent** switch (ticked:
   the agent calls it without asking; unticked: every call asks).
5. **Switches start from the server's own hints**: a tool the server marks read-only starts
   ticked; anything else, and any tool without a hint, starts unticked. A tool the server marks
   destructive is locked unticked.
6. **The sign-in part of the form fits the server:** one token, several fields, a browser sign-in
   (OAuth), or nothing (a local command).
7. **Ready-made entries** for the services the operator uses, plus **Custom server** for anything
   else.
8. **Provider-agnostic:** every session in the organization gets its connections, whatever
   harness runs it.
9. **Skills are not part of this.**

## What the operator gets

1. **Organization settings → Connections.** A list: each connection with a dot and a word —
   *connected* (green), *needs sign-in* (amber), *failing* (red) — and **+ Add connection**.
   The existing Jira site moves here as the Jira connection; nothing about it is lost.
2. **Add connection** offers the ready-made list — GitHub, Jira, Confluence, Figma, Datadog,
   Amplitude, Slack — and **Custom server**. A ready-made entry already knows its server's address
   or command, its sign-in kind and its fields; the operator only signs in.
3. **The connection's page**:
   - **Server** — address or command (read-only for a ready-made entry, editable for a custom one).
   - **Sign-in** — one of four forms:

     | Kind | Form | Examples |
     |---|---|---|
     | Token | one field (two for Jira: email and API token) | GitHub PAT, Figma, Jira |
     | Fields | several labelled fields, some not secret (site, region) | Datadog (site, API key, app key), Amplitude (region, key, secret) |
     | Browser | **Sign in with …** → the browser → "Signed in as …" · **Sign out** | Atlassian remote, Slack, Figma remote |
     | None | a command and optional environment variables | a local `npx` server |

     A stored secret shows as `•••••••• stored in Keychain`, with **Replace** (the existing
     settings pattern: `settings.apiToken.confirm`). It is never shown again.
   - **Status** — "Connected · 9 tools · checked 2 min ago", or the server's error in full
     (Rule 8).
   - **Tools** — a table: **Tool · Server says · Allow agent**. *Server says* is the server's own
     annotation (read-only, writes, destructive, or —). One button: **Allow every tool the server
     marks read-only**.
4. **In a session**, the agent sees the organization's connections as ordinary MCP servers. A
   ticked tool runs. An unticked tool raises the permission plane, the same plane Wakil's own
   writes raise, naming the connection, the tool and its arguments; the operator allows it once
   or refuses. A locked tool always asks.
5. **Switching organization** switches connections with it: the next session in Umbrella never
   sees Initech Labs' design-tool account.

## How it works (the parts decided)

- **Secrets** live in the Keychain under `wakil:<org>:<ref>` (Invariant 4), the ref being
  `conn:<name>` for a new connection (Jira keeps `jira:<org>` so a stored credential is not
  orphaned). A browser sign-in stores its tokens the same way and refreshes them.
- **Wakil fronts every connection with its own small MCP process** — one per connection, in the
  capability layer (Invariant 10), started from the JSON `agentMCPConfigJSON` builds. It connects
  to the real server (stdio or HTTP), injects the organization's credentials, passes `tools/list`
  through, and on `tools/call` checks the tool's switch: ticked → forward; unticked or locked →
  ask the app over the socket the `wakil` shim already uses, then forward or refuse with a
  message the agent reads. **The gate sits in this process, not in a harness's permission hook,
  so it holds for every harness** (Invariant 1).
- **Claude Code's own gate today refuses every non-Wakil tool** (`permissionDecision`,
  `PermissionPrompt.swift`; `agentAllowedTools` lists only Wakil's servers). So each connection's
  fronting server is added server-wide to `--allowedTools`, and the fronting process becomes the
  only gate for it. This deliberately widens a list built to fail closed; the plan says so and
  tests that an unticked tool still asks and a locked one is still refused.
- **The ask travels on its own channel**, not as a registry action: the fronting process asks the
  app over a dedicated socket the agent is never given, and the app raises the permission plane
  and journals the answer. A registry action would be reachable by the agent through the shim.
- **Today "every harness" means Claude Code sessions.** It is the only harness adapter; quick
  tasks (`ClaudeCodeQuickModel`, empty `--mcp-config`) get no connections. Nothing in this design
  is Claude-specific, so a second harness gets connections by being handed the same config.
- **An organization may hold two connections of one kind** (two code-host accounts). Each has a
  name the operator can change, defaulting to the kind (`github`, then `github-2`); the name is the
  Keychain ref (`conn:<name>`) and the MCP server key. A ready-made entry stays offered after it is
  added.
- **The switches are per organization, per connection, per tool**, stored with the
  organization's other settings. A tool the server adds later starts from its hint, as on first
  add; a tool that disappears is dropped. A tool whose hint changes to *destructive* locks.
- **Ready-made entries** are a list shipped with Wakil: name, server, sign-in kind, fields. Data,
  not code — adding one is a list entry.
- **The ready-made "Jira" entry is today's `wakil-pm`**, not Atlassian's server: it keeps its
  project scoping and its earned transition, and its own gate. Its page has the sign-in (email and
  API token, stored as today's single `email:api_token` under `jira:<org>`) and status; its tools
  are listed without switches, because their prices are already earned. `wakil-pm` stays in
  `agentFacingServers` and answers "no Jira connection" as today when an org has none.
  **Atlassian's own MCP server is a separate ready-made entry, "Atlassian (Confluence)"**, a
  Browser sign-in fronted like any other.
- **The Jira site has three writers today** — the org create form (`OrgPlane.swift`), the Settings
  pane's organization node (`SettingsPane.swift`), and `wakil org set --jira-base` — all into
  `org.json`, which `NewJiraFromEnv` reads. The Jira connection's page becomes the place the site
  and token are edited in the app; the CLI keeps working; `org.json` stays the store, so nothing
  migrates.

## Invariant 6 and 7

Today every write is earned per adapter. A connection's tools are writes Wakil did not write.
**Decided by the operator (2026-10-25): a write tool can be ticked.** Every tool the server does
not mark read-only is a write whose price is *gate* until the operator ticks it; a destructive one
can never be ticked. **Ticking Allow agent on a tool that writes is the operator earning that
write in, for that organization** — recorded in `decisions.md` as a new class, "a connection's
tool, allowed by the operator", and in §4's table as one row for the class, not one per tool.

**A ticked write is still never run by voice** (Invariant 7, the designer's call): a spoken turn
that reaches a ticked write tool raises the plane once, as a *gate* write does. A ticked
read-only tool runs from voice like any read.

## Interaction Rules

| Rule | How this meets it |
|---|---|
| 1 | Replacing a token asks (pane-local, as today). Adding, removing a connection or flipping a switch asks nothing. A gated tool call asks — its price is *gate*. |
| 2 | Every field keeps what was typed on blur. |
| 3 | **Add connection** lands focused on the first sign-in field. |
| 4 | A browser sign-in in progress has **Cancel**; so does a status check that hangs. |
| 5 | **Sign in** and **Replace** show progress and can't be pressed twice. |
| 6 | Saving a field stays on the connection's page. |
| 7 | A later token replaces the earlier; a server that changes its tools is followed, not refused. |
| 8 | The server's own error, whole. |
| 9 | Ready-made defaults (server, fields) suggest; a custom server overrides any of them. |

## Non-goals

- Wakil-written adapters for these services (pieces 2+ decide where one is worth it).
- Per-project connections (planned for, not built).
- Skills.
- Sharing connections between organizations.

## What is left to the builder

- The fronting process's language and whether it is one binary per connection kind or one
  binary with a mode, within Invariant 10.
- The OAuth flow's mechanics (the MCP authorization spec: discovery, dynamic client
  registration, PKCE), and where the callback lands.
- The exact copy, within `design-language.md`.

## Calls made for the operator

- Jira's secret keeps the ref `jira:<org>`; new connections use `conn:<name>`.
- The gate lives in Wakil's fronting process, not in any harness.
- A tool added later starts from its hint; a hint turning destructive locks the tool.
- **Allow every tool the server marks read-only** is the one bulk control.
- Status is checked on open of the page and when a session starts, not on a timer.
- The ready-made Jira entry is `wakil-pm`; Atlassian's server is a separate "Atlassian (Confluence)" entry.
- The ask uses a dedicated socket the agent never gets, not a registry action.
- A ticked write still asks when the turn was spoken (Invariant 7).
- Two connections of one kind are allowed, named by the operator (default: the kind).
- The Jira site stays in `org.json`; the connection page edits it, so nothing migrates.

## Open questions

1. Open question 16: `Connection` also names a database in `wakil-db`'s schemas. This design uses
   §9's meaning; the database sense should be renamed in the plan.
