# The Go capability layer

The Go side is Wakil's headless capabilities: reading and writing configuration, databases, HTTP
APIs, git, Jira and agent transcripts. Six binaries serve them as **MCP servers over stdio**; a
seventh, `wakil`, is the operator's CLI. None of them draws anything or knows about panes. The Swift
app (or the `claude` CLI) starts them as child processes and calls their tools.

- Module: `github.com/yehia-khalil/wakil` (`go.mod`). MCP SDK: `github.com/modelcontextprotocol/go-sdk`.
- Every server builds its tools in `newServer()` with `mcp.NewServer` and `mcp.AddTool`, and runs it
  in `main()` over `mcp.StdioTransport`.
- `CGO_ENABLED=0` for every build, test and vet: the `Makefile` exports it once, and its comment
  says why. `make build` writes every binary in `BINS` to `bin/`.

## The rules

| Rule | Enforced by |
|---|---|
| `internal/...` never imports `cmd/...` | `internal/wakilcore/layering_test.go` |
| `internal/wakilcore` imports no other package of the module | `internal/wakilcore/layering_test.go` |
| Only `cmd/` binaries and `internal/mcpx` import the MCP SDK; `wakilcore` never does | *convention* (`mcpx` exists for this, per its package comment; `layering_test.go` checks module imports only, so it would not catch an SDK import) |
| A tool handler returns errors through `mcpx.ToolErr`, never a raw `error` | *convention* (each binary's `toolErr` comment says why) |
| Every `cmd/` binary and `internal/` package has a heading in this file | `TestArchitectureDocsCoverEveryFolderAndBinary` in `scripts/architecture_docs_test.go` |

## Binaries

Who launches what:

- **The window** starts five servers per assembly in `WakilWiring.build`
  (`app/Sources/WakilKit/App/AppWiring.swift`): `wakil-ctx`, `wakil-db`, `wakil-http`, `wakil-git`, `wakil-ticket`
  (`wakilOwnedClients`). Their environment is `childProcessEnvironment`: `HOME`, `PATH`,
  `WAKIL_IN_WINDOW=1`, and `WAKIL_ORG`, `WAKIL_PROVIDER`, `WAKIL_KEYCHAIN` when set. They are
  restarted in place on an org switch (`WakilWiring.switchOrg`).
- **The agent's `claude` CLI** starts the servers in `agentFacingServers` (`wakil-pm`,
  `wakil-recall`, `wakil-git`) plus the `wakil` shim, from the JSON `agentMCPConfigJSON` builds
  (`app/Sources/WakilKit/App/AgentMCPConfig.swift`). Each gets `WAKIL_ORG` and `WAKIL_PROVIDER`.
- **`wakil-git` is started by both**: the window's copy serves the window's `GitStatus` and the
  editor's diff tabs and gutter baselines, and the harness's copy answers the agent's direct reads.
  They never share a process.
- `scripts/register-provider.sh` registers six servers (all but `wakil`) into one provider's own
  Claude config dir with `claude mcp add`, for sessions outside the window. It is an operator step.

### wakil

The operator's CLI, **not an MCP server** (`cmd/wakil/main.go`). Subcommand families:

- `secrets set | set-db | set-api` — puts a credential in the Keychain under `wakil:<org>:<ref>`.
  Secret values arrive on stdin, never argv.
- `org create | set | list | rm` (`orgcmd.go`) — `~/.wakil/orgs/<org>/org.json`.
- `provider add | list | rm | config-dir | home | credentials | mint` (`providercmd.go`,
  `providercredentials.go`) — provider records under the org's `providers/`. The window runs
  `wakil provider credentials` to read an account's credentials (`WakilCLICredentialsLookup`) and
  `wakil provider mint` to store a new one (`WakilCLIProviderMint`), both in
  `app/Sources/WakilKit/App/`.
- `project add | list | rm` (`projectcmd.go`) — the org's project registry.
- `setapi.go` — the `secrets set-api` composing aid.

The org comes from `WAKIL_ORG` or the global `--org` flag.

### wakil-ctx

The active context and the machine's configuration (`cmd/wakil-ctx/main.go`). Window-launched; the
registry's `ctx_*` actions call it, and so do `ContextStore` and the settings pane.

Tools: `get_context`, `list_projects`, `set_project`, `set_environment`, `list_environments`,
`list_sessions`, `get_session`, `read_session`, `record_session_parent`, `set_provider`,
`list_providers`, `config_tree`, `list_orgs`, `create_org`, `update_org`, `derive_config_dir`,
`list_accounts`, `list_machine_providers`, `add_provider`, `unlink_provider`, `set_database_dsn`,
`remove_database`, `adopt_provider`.

The editor settings: `editor_settings` answers both tiers; `set_editor_settings` takes `showIgnored`
(app-wide); `set_project_editor_settings` takes `heavyFolders`, the whole list (per project).

### wakil-db

Databases of the active environment (`cmd/wakil-db/main.go`). Window-launched; behind the `db_*`
actions and the ⌘P table list.

Tools: `list_databases`, `list_tables`, `describe_table`, `list_columns`, `query` (read-only),
`read_table`, `mutate` (one INSERT, UPDATE or DELETE; needs a `writeRef`), `render_update`,
`classify_statement`.

### wakil-git

Read-only git for the active project's roots (`cmd/wakil-git/main.go`). Started by the window and by
the harness (see above).

Tools: `git_status`, `git_diff`, `git_show`.

### wakil-files

The editor's file capability (3b-i, 3b-ii). Seven tools:

- `files_list` — one root's `files` (`git ls-files` with ignores in a repository, a walk otherwise),
  its `ignored` files, the `heavy` folders (`.git` and the active project's `editor.heavyFolders`,
  default `vendor`, `node_modules`; 3b-v; outside a repository the walk's built-in `skippedDirs` are
  heavy) and, for a folder of repositories, its `repos`. `files` and
  `ignored` together are capped at 50,000, tracked first.
- `files_list_dir` — one folder's direct entries (`{name, kind}`, folders first); how a heavy folder
  opens.
- `files_search` — a literal or Go-regexp search (`case`, `word`, `regex`) over the files
  `ListFiles` lists in every root (or `roots`): `{root, path, line, column (UTF-16), preview}`, capped at
  2,000 (`truncated`). One Go pattern in every root, so a pattern means the same in and out of a
  repository; skips ignored, heavy, binary and over-2 MB files.
- `files_replace_text` — read-only: each of `texts` with every match replaced (the `files_search`
  pattern, line by line; `$1`, `${name}`, `$$` with `regex`), answering `{text, count, edits}` per text.
  Wakil's preview and its open tabs' buffers (3b-ii-b).
- `files_replace` — the write: every match in the files `files_search` covers, each file atomic and
  mode-kept; `skip` leaves the open tabs on disk (`skipped` lists those covered), `only` names one
  file. Answers each file's `original` and `mtime` for the undo, and `failures` whole. `max_files`
  (or 250 ms) ends a call early and `next` resumes it, so a Cancel lands between calls.
- `files_read` — text up to 2 MB, size, mtime; no text for binary or non-UTF-8 files.
- `files_write` — whole text, atomic rename, `create` for a new file.

Every path is confined to the active project's roots after resolving symlinks
(`wakilcore.ConfineFilePath`); a refusal names Invariant 6 and Decision 36. Window-owned: started in
`WakilWiring.build` and joined to the org switch. Not registered into providers — the agent has its
own file tools. Logic in `internal/wakilcore/files.go`.

### wakil-http

HTTP against the active environment's API entries (`cmd/wakil-http/main.go`). Window-launched;
behind the api pane's actions and the ⌘P api list. `register-provider.sh` also registers it into a
provider's config dir.

Tools: `request` (GET/HEAD), `send` (POST/PUT/PATCH/DELETE), `list_apis`, `parse_curl`,
`locate_api_url`.

**`send` refuses every mutation unless `WAKIL_IN_WINDOW` is exactly `1`** (`WindowMarkerEnv` and
`AssertHTTPWindow` in `internal/wakilcore/httpsend.go`). Only the window's `childProcessEnvironment`
sets it, so a copy registered into a provider's config dir answers `request` and refuses `send`.
`AppWiringTests` pins the window's side.

### wakil-pm

Jira, scoped to the active project's Jira project key (`cmd/wakil-pm/main.go`). Harness-launched
(`agentFacingServers`).

Tools: `my_issues`, `search_issues`, `get_issue`.

### wakil-ticket

The Ticket view's capability (`cmd/wakil-ticket/main.go` registers, `branch.go` assembles).
**Window-owned** (`wakilOwnedClients`, pinned per place), never in `agentFacingServers`: the agent
reaches it only through registry actions. Logic in `internal/wakilcore`: `ticketrecord.go` (the
record and its log), `ticketlink.go` (keys, links, long-lived branches), `githubreview.go` (GitHub's
GraphQL API with the organization's git account for the remote's host, never `gh`).

Tools: `ticket_branch` (one root's branch: tickets with their sources and records, PRs with threads
and checks, the stack one step each way, and each unread source whole in `partial`),
`ticket_in_flight` (the organization's tickets in flight and Waiting on you, each with its state in
words), `ticket_record`, `ticket_record_write`, `ticket_link`, `review_reply`, `review_resolve` and
`review_thread` (a thread described from GitHub by its id, so a reply's or resolve's words on the plane
are GitHub's answer).

**The four writes refuse unless `WAKIL_IN_WINDOW` is exactly `1`** (`InWakilWindow`), as
`wakil-http`'s `send` does. A read's GitHub and Jira calls share one 15 s budget (Swift cancels at 20 s); one source failing
leaves the others shown.

### wakil-recall

Cited search across every source bound to the active project (Jira only today)
(`cmd/wakil-recall/main.go`). Harness-launched (`agentFacingServers`).

Tools: `recall`.

### wakil-connect

Fronts one of the organization's MCP connections (`cmd/wakil-connect`, run as
`wakil-connect --connection <name>`). It dials the real server once at start (`upstream.go`: a stdio
command, or Streamable HTTP at `ResolvedConnectionURL`), with the connection's credentials in place:
each catalog field's `Env` or `Header` from the record or the `conn:<name>` Keychain item, any
`env:<NAME>` / `header:<Name>` key of that item (how a custom connection carries its own), and a
browser sign-in's token from `BrowserToken`. Credentials go only to the server's own origin, and a
redirect elsewhere is not followed. It offers the server's tools unchanged and gates every
call (`gate.go`): the hint comes from the server's live annotations, falling back to the stored
`Hints`; an allowed read-only tool runs, anything else asks the app over `WAKIL_APPROVAL_SOCKET`
(one JSON line each way) and is refused if the app cannot answer. With no socket only an allowed
tool runs. A server that is down or refuses the credentials leaves it running with no tools and the
reason in its `instructions`. The approval socket is not passed on to a stdio server.

Tools: whatever the connection's server lists.

## Packages

### internal/wakilcore

The shared logic every binary uses. It imports nothing else from the module, and nothing MCP. Errors
meant for a human are `UserError` (`mcperr.go`). By area:

- **Config and paths** — `paths.go` (`WakilDir` = `~/.wakil`, `CurrentOrg` from `WAKIL_ORG`,
  `OrgsDir`, `OrgDirFor`), `org.go` (`Org`, `org.json`), `orgupdate.go`, `editorsettings.go`
  (`AppSettings`: the two editor tiers, `~/.wakil/settings.json`), `registry.go`
  (`ProjectEntry`, `projects.json`), `config.go` (`Project`, `LoadProject`: a project's
  `project.json`), `projectwrite.go` (`SaveProject`, `SetDatabaseDSN`), `active.go`
  (`ActiveContext`, `active.json`), `resolve.go` (`Resolve`, `PartialResolved`), `configtree.go`
  (what `config_tree` returns), `production.go` (`EnvironmentIsProduction`,
  `EnvironmentIsReadOnly`), `pickname.go`. See [state.md](state.md) for the files.
- **Keychain** — `secrets.go` (`SecretGet`, `SecretSet`; service name `wakil:<org>:<ref>` from
  `keychainService`), `credpresence.go` (`SecretPresence`; runs `/usr/bin/security` at its absolute
  path; `WAKIL_KEYCHAIN` names the keychain file; `WAKIL_SECURITY_BINARY` overrides the tool in test
  binaries only),
  `secretscrub.go` (`SecretScrubber`).
- **Databases** — `dbdriver.go` (`Connection`, `RegisterDriver`), `driver_sqlite.go`
  (`modernc.org/sqlite`), `driver_mysql.go` (`github.com/go-sql-driver/mysql`), `driver_mongo.go` and
  `mongo_util.go` (`go.mongodb.org/mongo-driver/v2`), `sqlconn.go` (`sqlConn.queryContext`: MySQL reads pin a connection and `KILL QUERY` it on cancel, same-server checked by `@@server_uuid`), `dbresolve.go` (`PickDatabase`,
  `OpenDatabase`, `OpenDatabaseWritable`), `readonly.go` (`AssertSQLReadOnly`), `mutation.go`
  (`AssertSQLMutation`, `MutationAffectsEveryRow`), `classify.go` (`ClassifyStatement`),
  `editable.go`, `updatestmt.go` (what `render_update` composes).
- **HTTP** — `httpclient.go` (`DoRequest`, `NormalizeHTTPBase`), `httpsend.go` (`InWakilWindow`,
  `AssertHTTPWindow`, `AssertHTTPMutation`), `apiresolve.go` (`PickAPI`), `apilocate.go`
  (`LocateAPIURL`), `curl.go` (what `parse_curl` returns).
- **Git** — `gitread.go` (`GitRunner`), `gitstatus.go` (`ParseGitStatus`), `gitdiff.go`
  (`GitDiff`).
- **Jira** — `jira.go` (`JiraClient`; base URL from the org record, `WAKIL_JIRA_BASE` as an override).
- **Recall** — `recall.go` (`RecallOutput`, `SourceStatus`).
- **Sessions and lineage** — `sessions.go` (`SessionMeta`, `SessionList`), `transcript.go`
  (`SessionThread`, `ThreadEntry`), `sessions_lineage.go` (`sessions.json`, `SessionParents`).
- **Providers and accounts** — `provider.go` (`Provider`, `AddProvider`, `CurrentProvider` from
  `WAKIL_PROVIDER`; provider credential service `wakil:<org>:provider:<id>`), `accounts.go`
  (`ListAccounts`), `adopt.go` (`AdoptProvider`), `unlink.go` (`UnlinkProvider`), `mint.go`
  (`MintProviderToken`), `liveness.go` (`ReadSignInLiveness`), `configdir.go` (`DeriveConfigDir`),
  `pty.go`.

Tests: a `_test.go` beside most files. Tests that need a real MySQL or Mongo are skipped by `make test` and
run by `make test-live`. `layering_test.go` holds the two Go layering rules.

### internal/mcpx

MCP-SDK-facing helpers shared by the `cmd/` servers, so `wakilcore` never imports the SDK
(`internal/mcpx/mcpx.go`).

- `ToolErr(server, err)` — turns an error into an MCP tool-error result carrying one human sentence.
  Each binary wraps it as `toolErr`.
- `internal/mcpx/mcpxtest/` — `AssertObjectOutputSchemas`, an assertion that needs a live
  client/server round trip, shared by every server's tests. Only `_test.go` files may import it.
- `shippedbinary_test.go` — drives the built `bin/wakil-db` over a real stdio pipe; skipped unless
  `make build` has run.

## Adding a binary

See `CONTRIBUTING.md`, "A new MCP binary": the full list of places a new `cmd/` binary must be named.
