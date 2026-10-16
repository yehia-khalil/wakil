# Wakil Phase 1 — Capability Layer

**Status:** draft for review · **Created:** 2026-09-03 · Conforms to
`docs/wakil/north-star.md`

Phase 1 builds the headless capability layer — a set of MCP servers plus a file-based
context model — driven from **plain Claude Code**, with no Swift and no UI. Its purpose is
to retire every integration risk before the native app is built. Everything here is
reused unchanged by Wakil.app in Phase 2.

**Exit criterion (from the charter):** from plain Claude Code, both *"what's assigned to
me on umbrella"* and *"fetch customer 42 from staging"* return correct answers, with no
Swift written.

---

## 1. Scope

**In:**
- `wakil-ctx` — the context model and active-context resolution
- `wakil-pm` — Jira, read-only (both orgs)
- `wakil-db` — databases (SQL + document), read-only, environment-bound, pluggable
- `wakil-http` — HTTP/API client, environment-bound
- `wakil-recall` — grouped per-source search (no index)
- The organization config-dir convention and per-org MCP registration
- Session discovery (read Claude Code history from disk)

**Out (later phases):** all UI, voice, the action layer, write paths, Slack/inbox
adapters, Azure DevOps, a recall index, the harness abstraction (Phase 1 *is* Claude
Code — the harness abstraction is a Phase 2 concern).

**Build order within Phase 1:** `wakil-ctx` → `wakil-pm` + `wakil-db` (these two satisfy
the exit criterion) → `wakil-http` → `wakil-recall` → session discovery.

## 2. Architecture

Five independent MCP servers, each a separate process, each doing one thing. They do
**not** call each other. Shared state — the active context — lives in a file that
`wakil-ctx` owns and the others read. This keeps every server testable in isolation and
avoids inter-process coupling.

```
Claude Code (org config dir sets CLAUDE_CONFIG_DIR + CLAUDE_CODE_OAUTH_TOKEN)
  │  MCP (stdio)
  ├─ wakil-ctx     owns ~/.wakil/active.json ; resolves (org,project,environment)
  ├─ wakil-pm      reads active.json → Jira scope ; Jira REST
  ├─ wakil-db      reads active.json → environment.databases[] ; pluggable, read-only
  ├─ wakil-http    reads active.json → environment.api ; HTTP
  └─ wakil-recall  reads active.json → all scopes ; queries providers directly
                   via shared wakilcore clients (never calls the other servers)
```

**Transport rule (Invariant 9):** MCP is the surface Claude Code calls. Inside a server,
reads that would later feed an index use the provider's real API directly. In Phase 1
there is no index, so every server simply wraps its provider's API and exposes MCP tools.

**Language: Go**, official Go MCP SDK, stdio transport. Chosen not for raw speed (these
servers are I/O-bound — the bottleneck is provider latency, not CPU) but for what suits a
snappy, self-contained native app: each server compiles to a **single static binary with
no runtime**, so bundling into Wakil.app is trivial; low memory (~5–15MB each vs Node's
~30–50MB) matters with several long-lived helpers; and instant startup. One Go module,
one command per server (`cmd/wakil-ctx`, …), shared internal package `wakilcore` for the
config/context types, the `active.json` reader, the `DbDriver` interface, and the
read-only gate. (Supersedes the charter's early "adapters in TypeScript" assumption, which
predated the native-app decision.)

## 3. Configuration & state

Three locations, matching the charter's "credentials at the org, scope at the project":

**a) Organization = a Claude config dir.** No new file. An org is a `CLAUDE_CONFIG_DIR`
(e.g. `~/.claude-initech`) plus its `CLAUDE_CODE_OAUTH_TOKEN`. The wakil MCP servers are
registered in that dir's MCP settings, so launching Claude Code with that config dir makes
"the initech organization" active. Reuses the existing `~/.claude-accounts.zsh` mechanism.

**b) Project definition — `<projectDir>/.wakil/project.json`.** Committed where the
project dir is itself a repo; machine-local otherwise (open question 8 in the charter).
Contains no secrets.

```jsonc
{
  "name": "booking-platform",
  "org": "initech",                        // which config-dir org this belongs to
  "roots": [
    { "path": "api",       "role": "service"  },
    { "path": "web-admin", "role": "frontend" },
    { "path": "mobile",    "role": "frontend" }
  ],
  "scopes": {
    "pm":   { "provider": "jira", "projectKey": "RAF" }
  },
  "environments": {
    "staging": {
      "databases": [
        { "name": "core",      "driver": "mysql",  "ref": "booking-staging-core"  },
        { "name": "analytics", "driver": "sqlite", "ref": "booking-staging-events" },
        { "name": "sessions",  "driver": "mongo",  "ref": "booking-staging-mongo"  }
      ],
      "api": { "baseUrl": "https://staging.booking.internal" }
    },
    "production": {
      "databases": [
        { "name": "core", "driver": "mysql", "ref": "booking-prod-core", "readOnly": true }
      ],
      "api": { "baseUrl": "https://api.booking.com" }
    }
  }
}
```

Each environment has **an array of named database connections** (a project routinely spans
a relational primary, an analytics store, a document DB). `driver` selects the pluggable
backend; `ref` resolves to the Keychain connection; `readOnly` may be set per connection.

`db.ref` and any API auth are *references* to secrets, never the secrets themselves.
`project.json` holds only non-sensitive fields — environment names, refs, `baseUrl`,
`readOnly`. **Every credentialed field lives behind a ref in the Keychain**, never in this
file (it is meant to be committable).

**c) Machine-local registry & secrets — `~/.wakil/`.**
- `~/.wakil/active.json` — the active context: `{ "project": "<path>", "environment": "staging" }`. Org is implicit from the config dir. Written only by `wakil-ctx`.
- `~/.wakil/projects.json` — maps project name → `project.json` path (so `wakil-ctx` can switch by name).
- Secrets live in the **macOS Keychain**, keyed by `ref`. Phase 1 reads them; a small `wakil secrets set <ref>` CLI writes them. Never in any JSON file, never in env beyond the process that needs them.

**Credential model — the full connection is the secret.** A DB `ref` resolves to a Keychain
entry holding the **complete connection: host, port, database, user, password** (as a
connection URL or a small JSON blob). Non-secret parts are not split out into `project.json`
— keeping the whole connection in one Keychain entry is simpler and means an internal
hostname never lands in a committable file either. The same pattern covers every
credentialed service: an API `authRef`, and later Slack/mailbox tokens, each resolve to one
Keychain entry.

**Where credentials attach mirrors the settings scopes** (charter — settings model):
- **Organization-level** creds — Jira/Slack/mailbox auth — are shared across the org's
  projects and already live in the org's config-dir credential store.
- **Project/environment-level** creds — the DB connection, per-environment API auth — attach
  to the environment and resolve through its `ref`.

In Phase 1 these are entered via the `wakil secrets set` CLI; in Phase 2 the same Keychain
entries are written by the Settings UI. Wakil sends a credential only to the service it
belongs to, never anywhere else.

## 4. Servers

### 4.1 `wakil-ctx`
Owns the active context. The only server that writes state.

| Tool | Purpose |
|------|---------|
| `get_context()` | Returns the resolved active `(org, project, roots, environment, scopes)`. Every other server reads `active.json` directly, but this tool lets the agent and the user see it. |
| `list_projects()` | From `~/.wakil/projects.json`, filtered to the active org. |
| `set_project(name)` | Switches active project (must belong to the active org). |
| `set_environment(name)` | Switches active environment within the active project. |
| `list_environments()` | Names + which are read-only. |

Guard: `set_project` rejects a project whose `org` ≠ the active config dir's org, enforcing
Invariant 5 (one active context) and preventing cross-org bleed.

### 4.2 `wakil-pm` (Jira, read-only)
Resolves the active project's `scopes.pm` to a Jira project key and queries the org's Jira
site. Auth: reuses the Atlassian MCP OAuth already present in each config dir (the charter
notes `atlassian-initech` / `atlassian-umbrella` already exist) — Phase 1 may either call
Jira REST with that token or defer to the existing Atlassian MCP. **Decision: wrap Jira
REST directly** so scope resolution and the "assigned to me" filter are ours; the existing
Atlassian MCP stays available for anything richer.

| Tool | Purpose |
|------|---------|
| `my_issues()` | Issues assigned to the current user in the active scope. Satisfies "what's assigned to me on umbrella". |
| `search_issues(jql?)` | Scoped JQL search; scope prepended so cross-project leakage is impossible. |
| `get_issue(key)` | One issue with comments. |

### 4.3 `wakil-db` (read-only, environment-bound, pluggable, multi-connection)
Serves the active environment's `databases[]`. A project routinely has several
connections of different kinds, so every tool takes a `database` name (optional when the
environment has exactly one).

**Pluggable driver interface.** Each backend implements one `DbDriver` in `wakilcore`;
adding a database kind is adding a driver, nothing else:

```go
type DbDriver interface {
    Kind() string                                    // Phase 1: "mysql", "sqlite", "mongo"
    Connect(ctx context.Context, conn Connection) (Conn, error) // resolved from Keychain ref
    ListContainers(ctx context.Context) ([]Container, error)    // tables (SQL) or collections (Mongo)
    Describe(ctx context.Context, name string) (Schema, error)  // columns/types/keys, or inferred fields
    Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error) // driver-native; limit hard-capped
    AssertReadOnly(spec QuerySpec) error             // per-driver write rejection — see below
}
```

**Read-only is enforced two ways, per driver:** connect with a read-only role/user where
the backend supports it, *and* reject writes before sending — the gate is driver-specific
because the query languages differ:
- **SQL (mysql, sqlite):** allow only `SELECT`/`EXPLAIN`/`SHOW`; reject anything else and
  reject multi-statement/comment-smuggled writes (`SELECT 1; DROP …`).
- **Mongo:** allow only `find`/`aggregate`/`count`/`distinct`; reject `insert*`/`update*`/
  `delete*`/`replace*`/`bulkWrite`/`findAndModify`, and reject any `aggregate` pipeline
  containing `$out` or `$merge` (those write).

Per-connection `readOnly: true` is absolute in Phase 1 regardless of driver.

| Tool | Purpose |
|------|---------|
| `list_databases()` | The named connections in the active environment (name, kind, read-only). |
| `list_tables(database?)` | Tables/collections for one connection. |
| `describe_table(database?, name)` | Columns/types/keys, or inferred field shape for Mongo. |
| `query(database?, query, limit?)` | Driver-native read (`SQL` string, or a Mongo find/aggregate spec); default and hard-capped limit; returns rows + timing. Satisfies "fetch customer 42 from staging". |

**Phase 1 drivers: MySQL, SQLite, Mongo.** Postgres, Metabase, and BigQuery are later —
each is one new `DbDriver`, so the interface is the whole plan for them.

### 4.4 `wakil-http` (environment-bound)
Resolves `environment.api.baseUrl` + any auth ref. Read-only means **GET/HEAD only** in
Phase 1; other verbs are rejected (they are writes — Phase 4).

| Tool | Purpose |
|------|---------|
| `request(method, path, query?, headers?)` | GET/HEAD against the active baseUrl; relative paths only, so it can't be pointed off-environment. |

### 4.5 `wakil-recall` (grouped, no index)
Fans out a query across bound sources and returns **grouped, cited** results — no unified
ranking, no index (charter Decision 15). Phase 1 sources: `wakil-pm` (Jira) only, since
Slack/inbox are later. Structured so adding a source is adding a fan-out target.

| Tool | Purpose |
|------|---------|
| `recall(query)` | Returns `{ jira: [...], ... }`, each result carrying a source, title, snippet, and link (citation). |

Recall calls providers directly (not via the other MCP servers — no inter-server calls);
it shares the provider client code through `wakilcore`.

## 5. Session discovery

A read-only utility (small MCP server `wakil-sessions`, or a tool on `wakil-ctx` — **build
as `wakil-ctx` tools** to avoid a sixth process). Reads
`$CLAUDE_CONFIG_DIR/projects/<encoded-root>/<sessionId>.jsonl`.

| Tool | Purpose |
|------|---------|
| `list_sessions()` | All sessions for the active project's roots, merged by timestamp, newest first. Includes sessions started outside Wakil. |
| `get_session(id)` | Metadata + first prompt for a session. |

**Critical (charter Decision 13):** the path encoding is lossy (`/`→`-`). Always **encode
a known root path and look for that directory**; never decode directory names back to
paths. Match Conductor worktrees by encoded-root **prefix**.

## 6. Cross-cutting

- **Read-only enforcement** lives in `wakilcore`: HTTP verb allow-list, per-driver DB
  gates (each `DbDriver.AssertReadOnly`), and the `readOnly` flag — every data path funnels
  through the same layer. This is the single chokepoint the charter wants, moved earlier
  than the action layer.
- **Auth resolution** relies on `CLAUDE_CODE_OAUTH_TOKEN` being set and
  `ANTHROPIC_API_KEY` being *truly unset* (charter Decision 4 / verified open-question 2).
  The launcher must `env -u ANTHROPIC_API_KEY`. Refresh-token expiry surfaces as a clear
  "re-auth <org>" message, not a raw 401.
- **Secrets** never touch disk in plaintext or env files; Keychain only.
- **Errors** are returned as structured MCP errors with a human sentence (e.g. "staging DB
  unreachable", "not authenticated for umbrella"), never raw stack traces.

## 7. Testing

- Each server unit-tested against a fake provider (in-memory Jira, Dockerized MySQL/Mongo,
  a temp-file SQLite, a stub HTTP server).
- Each `DbDriver` gets its own adversarial read-only tests: SQL — `INSERT`/`UPDATE`/
  `DELETE`/`DROP` and comment-smuggled writes (`SELECT 1; DROP…`); Mongo — `insert*`/
  `update*`/`delete*`/`bulkWrite`/`findAndModify` and `$out`/`$merge` pipelines; HTTP —
  POST/PUT/PATCH/DELETE. All must be rejected. New drivers must ship this test set.
- Context isolation test: with the initech config dir active, `set_project` on a umbrella
  project is rejected.
- End-to-end: register both orgs, run the two exit-criterion prompts through actual Claude
  Code, assert correct answers.

## 8. Exit criteria (testable)

1. `claude-initech` and `claude-umbrella` each expose the wakil servers.
2. "what's assigned to me on umbrella" → correct issue list from Umbrella's Jira.
3. "fetch customer 42 from staging" → correct row from the named staging connection;
   works across at least one MySQL, one SQLite, and one Mongo connection.
4. Every write attempt (SQL, Mongo, or HTTP) is rejected; production is unreachable for
   writes.
5. "show my recent sessions on this project" lists sessions across all roots, including
   ones started outside Wakil.
6. No Swift, no UI. Everything runs under plain Claude Code.

## 9. Open questions (Phase 1-specific)

- **8 (from charter):** where `project.json` lives for non-repo project dirs — machine-local accepted for now.
- Does wrapping Jira REST directly duplicate too much of the existing Atlassian MCP? Revisit if the existing MCP's scoping turns out sufficient.
- Keychain access from a Go MCP subprocess launched by Claude Code — confirm the process can read the Keychain in this launch context (small spike before `wakil-db`; a Go binary invoking `security find-generic-password` or the Keychain API should be fine, but verify the prompt/entitlement behavior).
