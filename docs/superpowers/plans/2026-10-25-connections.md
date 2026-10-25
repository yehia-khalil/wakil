# Connections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An organization's own MCP servers reach every agent session in that organization, signed in once in Settings, with every call gated by Wakil; and the Jira token is entered in the app.

**Architecture:** Connections are records in `org.json` (Go, `internal/wakilcore/connections.go`) with their secrets in the Keychain. A new capability binary, `cmd/wakil-connect`, fronts one connection: it dials the real server, injects the organization's credentials, re-exposes its tools, and on every call either forwards or asks the app over a dedicated approval socket. The app adds one `wakil-connect` per connection to the session's MCP config, answers the approval socket by raising the existing permission plane (`ConfirmationBroker`), and shows Settings → Connections.

**Tech Stack:** Go 1.27 with the forked `github.com/modelcontextprotocol/go-sdk` (its `mcp` client and server, its `auth` OAuth helpers); Swift (WakilKit, WakilApp); the macOS Keychain through `wakilcore.SecretGetFor`/`SecretSetFor`.

**Spec:** `docs/superpowers/specs/2026-10-25-connections-design.md` (umbrella: `docs/superpowers/specs/2026-10-25-ticket-work-design.md`).

## Global Constraints

- Per organization only; no per-project connection (spec: Decided 2).
- Secrets only in the Keychain under `wakil:<org>:<ref>`; a connection's ref is `conn:<name>`; Jira keeps `jira:<org>` holding `email:api_token` (spec: How it works).
- Switch default: a tool whose server sets `readOnlyHint: true` starts allowed; any other tool starts not allowed. A tool whose `destructiveHint` is **explicitly** `true` is locked not allowed. (MCP's own default for an absent `destructiveHint` is true; this plan locks only on an explicit `true`, or every unannotated tool would be locked.)
- A ticked write runs without asking **unless the turn that reached it was spoken**: then it asks once (Invariant 7, spec §Invariant 6 and 7).
- The gate lives in `wakil-connect`, not in a harness hook. Each connection server is allowed server-wide in `--allowedTools` (`mcp__<name>`).
- The approval socket is given only to `wakil-connect` processes, never to the shim; it can only *ask*, never approve.
- Connection names: lowercase `[a-z0-9-]`, 1–32 chars, not one of `wakil`, `wakil-pm`, `wakil-recall`, `wakil-git`, `wakil-ctx`, `wakil-db`, `wakil-http`, `wakil-files`, `wakil-connect`. Default name = the kind; a second of one kind gets `<kind>-2`, then `-3`.
- Every Settings write is an operator-only registry action (Decision 30), named `ctx_connection_*`, forwarded to a `wakil-ctx` tool; secret params are declared in `secretParams` so the journal redacts them.
- The ready-made Jira entry is `wakil-pm` (unchanged); "Atlassian (Confluence)" is a separate ready-made entry.
- Interaction Rules 1–9 as in the spec's table.
- Public repo: example names only; `scripts/public-check.sh` passes.

## Review Focus

1. **An org with no connections** — the session's MCP config and `--allowedTools` are byte-identical to today's. (Task 6 test `noConnectionsLeavesConfigUnchanged`.)
2. **A connection whose server is down or whose token is wrong** — the session still starts; that server's tools are absent and the connection page shows the server's error whole; other connections work. (Task 3 test `TestUpstreamDownServesNoToolsAndSaysWhy`; Task 7 status.)
3. **Org switch mid-window** — the next session's connections are the new org's; no `wakil-connect` of the old org survives into the new session's config. (Task 6 test `connectionsFollowThePlace`.)
4. **A tool the server adds after the page was opened** — it follows its hint at call time, with no stored switch. (Task 3 test `TestUnseenToolFollowsItsHint`.)
5. **The app is not running** (`wakil-connect` started by a plain harness with no approval socket) — ticked tools run, every other call is refused with a message that says to allow it in Wakil. (Task 3 test `TestHeadlessRefusesUnticked`.)

---

### Task 1: The connection record and its catalog

**Files:**
- Create: `internal/wakilcore/connections.go`, `internal/wakilcore/connectioncatalog.go`
- Modify: `internal/wakilcore/org.go` (add `Connections []Connection \`json:"connections,omitempty"\`` to `Org`)
- Test: `internal/wakilcore/connections_test.go`

**Interfaces:**
- Produces:
  ```go
  type Connection struct {
      Name      string            `json:"name"`
      Kind      string            `json:"kind"`      // catalog id or "custom"
      Transport string            `json:"transport"` // "stdio" | "http"
      Command   string            `json:"command,omitempty"`
      Args      []string          `json:"args,omitempty"`
      URL       string            `json:"url,omitempty"`
      SignIn    string            `json:"signIn"`    // "token" | "fields" | "browser" | "none"
      Values    map[string]string `json:"values,omitempty"` // non-secret field values (site, region)
      Allow     map[string]bool   `json:"allow,omitempty"`  // tool -> operator's switch
      Hints     map[string]string `json:"hints,omitempty"`  // tool -> "readOnly" | "writes" | "destructive" | ""
  }
  type ConnectionField struct { ID, Label string; Secret bool; Env, Header string } // where the value goes upstream
  type ConnectionKind struct { ID, Title, Transport, Command, URL, SignIn string; Args []string; Fields []ConnectionField }
  var ConnectionCatalog []ConnectionKind
  func AddConnection(org string, c Connection) (Connection, error) // fills Name when empty, validates, saves
  func UpdateConnection(org, name string, edit func(*Connection)) error
  func RemoveConnection(org, name string) error                    // also deletes conn:<name> from the Keychain
  func ConnectionFor(org, name string) (Connection, bool)
  func SetConnectionSecrets(org, name string, values map[string]string) error // JSON object under conn:<name>, merged
  func ConnectionSecrets(org, name string) (map[string]string, error)
  func SetConnectionAllow(org, name, tool string, allow bool) error // refuses a locked tool
  func ToolAllowed(c Connection, tool string) (allowed, locked bool)  // stored ?? hint=="readOnly"; locked = hint=="destructive"
  ```

- [ ] **Step 1: Write the failing tests** — `TestAddConnectionNamesByKind` (two `github` adds → names `github`, `github-2`); `TestAddConnectionRefusesReservedName` (`wakil-pm` → `UserError` containing "reserved"); `TestAddConnectionRefusesBadName` (`Git Hub` → `UserError`); `TestRemoveConnectionDeletesItsSecret`; `TestSetConnectionSecretsMerges` (set `{token:a}` then `{site:x}` → both present); `TestToolAllowedFollowsHint` (no stored switch: `readOnly`→allowed, `writes`→not, `""`→not, `destructive`→locked); `TestSetConnectionAllowRefusesLocked`; `TestStoredSwitchBeatsHint`. Use the existing secrets test seam the git-account tests use (`gitaccounts_test.go`).
- [ ] **Step 2:** `go test ./internal/wakilcore -run 'Connection|ToolAllowed'` → FAIL (undefined).
- [ ] **Step 3: Implement** in `connections.go`; `ConnectionCatalog` in `connectioncatalog.go` with these entries (ID · Title · Transport · URL/Command · SignIn · Fields):
  - `github` · GitHub · http · `https://api.githubcopilot.com/mcp/` · token · `token` (secret, Header `Authorization: Bearer`)
  - `atlassian` · Atlassian (Confluence) · http · `https://mcp.atlassian.com/v1/mcp` · browser · —
  - `figma` · Figma · http · `https://mcp.figma.com/mcp` · browser · —
  - `datadog`, `amplitude`, `slack` · their official MCP server · **verify each address and sign-in kind from the vendor's own MCP documentation and record the doc URL in a comment beside the entry**; Datadog's fields are `site` (not secret), `apiKey`, `appKey`; Amplitude's `region` (not secret), and its key and secret if its server takes them.
  - `custom` is not a catalog entry; it is `Kind: "custom"`.
  Jira is not in this catalog (it is `wakil-pm`, Task 7).
- [ ] **Step 4:** same command → PASS; `go vet ./...` clean.
- [ ] **Step 5: Commit** `connections: the record in org.json, its Keychain secrets and the ready-made catalog`.

### Task 2: Settings writes through wakil-ctx and the config tree

**Files:**
- Modify: `internal/wakilcore/configtree.go` (`ConfigTreeOrg.Connections []ConfigTreeConnection`, no secrets: `name, kind, title, transport, url, command, signIn, values, fields, allow, hints, signedIn bool`), `cmd/wakil-ctx/main.go`
- Create: `internal/wakilcore/jiratoken.go` (`SetJiraToken(org, email, token string) error` → `SecretSetFor(org, "jira:"+org, email+":"+token)`; refuses an empty part or a `:` in the email)
- Test: `cmd/wakil-ctx/main_test.go`, `cmd/wakil-ctx/schema_test.go`, `internal/wakilcore/jiratoken_test.go`

**Interfaces:**
- Consumes: Task 1.
- Produces `wakil-ctx` tools (args all carry `id` = the organisation, as `update_org` does): `connection_add {id, kind, name?, url?, command?, args?, values?}` → `{name}`; `connection_update {id, name, newName?, url?, command?, args?, values?}`; `connection_remove {id, name}`; `connection_secrets_set {id, name, values}` (secret); `connection_allow_set {id, name, tool, allow}`; `connection_catalog {}` → `[ConnectionKind]`; `jira_token_set {id, email, token}` (secret). `config_tree` carries `connections` and `jiraTokenStored bool`.

- [ ] **Step 1:** Tests: `TestConnectionToolsRoundTrip` (add → config_tree shows it without secrets → allow_set → remove); `TestConfigTreeNeverCarriesSecrets` (set a secret, marshal the tree, assert the value is absent); `TestJiraTokenSetStoresOneLine` (`email:token` under `jira:<org>`); schema test lists the new tools.
- [ ] **Step 2:** `go test ./cmd/wakil-ctx ./internal/wakilcore -run 'Connection|Jira|Schema'` → FAIL.
- [ ] **Step 3:** Implement the tools beside `git_token_set`, same error shape (`toolErr`).
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `connections: wakil-ctx tools to add, edit, sign in and switch; the Jira token from the app`.

### Task 3: wakil-connect, the fronting server

**Files:**
- Create: `cmd/wakil-connect/main.go`, `cmd/wakil-connect/upstream.go`, `cmd/wakil-connect/gate.go`, `cmd/wakil-connect/main_test.go`
- Modify: `Makefile` (add `wakil-connect` to `BINS`, line 53, so `make build` and `make app-bundle` carry it)

**Interfaces:**
- Consumes: Task 1 (`ConnectionFor`, `ConnectionSecrets`, `ToolAllowed`), Task 4 (`BrowserToken`).
- Invocation: `wakil-connect --connection <name>`; org from `WAKIL_ORG` (as every binary); approval socket from `WAKIL_APPROVAL_SOCKET` (optional).
- Produces the approval protocol (one JSON line each way over the unix socket):
  ```json
  {"connection":"github","tool":"create_issue","arguments":{...},"allowed":true,"readOnly":false,"locked":false}
  {"decision":"allow"}   |   {"decision":"deny","message":"…"}
  ```

- [ ] **Step 1:** Tests with an in-process fake upstream (go-sdk `mcp.NewInMemoryTransports`): `TestToolsPassThrough` (names, schemas and annotations unchanged); `TestAllowedReadOnlyForwardsWithoutAsking` (fake socket records zero requests); `TestEveryOtherCallAsks` (unticked, ticked write, locked → one request each, carrying the flags above); `TestDenyReturnsTheMessageAsToolError`; `TestHeadlessRefusesUnticked` (no socket: ticked forwards, unticked → error text containing "Allow agent" and the connection's name); `TestUnseenToolFollowsItsHint`; `TestUpstreamDownServesNoToolsAndSaysWhy` (`tools/list` empty, server `instructions` carry the error); `TestCredentialsInjected` (stdio: `Env`; http: `Header`, prefix as the catalog field says; browser: `Authorization: Bearer <BrowserToken>`).
- [ ] **Step 2:** `go test ./cmd/wakil-connect` → FAIL.
- [ ] **Step 3:** Implement: `upstream.go` dials `mcp.CommandTransport` (stdio) or `mcp.StreamableClientTransport` (http) with credentials; `main.go` lists upstream tools once at start and registers each with the raw `Server.AddTool`; `gate.go` implements the rule, reading each tool's hint from the upstream's **live** annotations (`readOnlyHint`, explicit `destructiveHint: true`) and falling back to the stored `Hints` — so a hint that turns destructive locks at once — then: ask the socket unless `allowed && readOnly`; with no socket, forward iff `allowed`. A ticked write still goes to the socket so the app can apply the spoken-turn rule.
- [ ] **Step 4:** → PASS; `make build` produces `wakil-connect`.
- [ ] **Step 5: Commit** `connections: wakil-connect fronts one connection, injects its credentials and gates every call`.

### Task 4: Browser sign-in

**Files:**
- Create: `internal/wakilcore/connectionoauth.go`, `internal/wakilcore/connectionoauth_test.go`
- Modify: `cmd/wakil-ctx/main.go` (tools `connection_signin_start {id, name}` → `{url}`, `connection_signin_wait {id, name}` → `{account}` blocking until done or cancelled; `connection_signout {id, name}`)

**Interfaces:**
- Produces: `StartConnectionSignIn(ctx, org, name string) (authURL string, err error)`; `WaitConnectionSignIn(ctx, org, name string) (account string, err error)`; `BrowserToken(ctx, org, name string) (string, error)` (refreshes when expired, rewrites the Keychain item); `SignOutConnection(org, name string) error`. Tokens live in the same `conn:<name>` JSON object under keys `access`, `refresh`, `expiry`, `client`.
- Mechanics left to the implementer within: the MCP authorization flow (server metadata discovery, dynamic client registration, PKCE, a loopback redirect on `127.0.0.1` with a random port), using the SDK's `auth`/`oauthex` packages.

- [ ] **Step 1:** Tests against an `httptest` authorization server: `TestSignInStoresTokens`; `TestBrowserTokenRefreshesWhenExpired`; `TestSignInCancelledLeavesNothing` (context cancelled → no Keychain write); `TestSignOutForgetsTokens`.
- [ ] **Step 2:** → FAIL. **Step 3:** implement. **Step 4:** → PASS.
- [ ] **Step 5: Commit** `connections: browser sign-in per organization, tokens in the Keychain, refreshed`.

### Task 5: The approval socket in the app

**Files:**
- Create: `app/Sources/WakilKit/Gate/ConnectionApproval.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (mark the conversation's turn spoken where it calls `journalVoiceTurn`, clear it where the turn ends — the `agent.turnInFlight = false` sites), `app/Sources/WakilApp/WindowSession.swift` (start one approval server per window beside `MCPSocketServer`)
- Test: `app/Tests/WakilKitTests/ConnectionApprovalTests.swift`

**Interfaces:**
- Consumes: Task 3's protocol; `ConfirmationBroker.request(_:)`; `PendingMutation`.
- Produces:
  ```swift
  public struct ConnectionCallRequest: Sendable, Equatable, Codable {
      public let connection: String; public let tool: String; public let arguments: JSONValue
      public let allowed: Bool; public let readOnly: Bool; public let locked: Bool
  }
  public enum ConnectionCallDecision: Equatable, Sendable { case allow; case deny(String) }
  public func connectionCallDecision(_ r: ConnectionCallRequest, spoken: Bool) -> ConnectionCallDecision? // nil = ask the operator
  public actor ConnectionApprovalServer { public init(socketPath: String, place: Place, conversation: String, broker: ConfirmationBroker, spoken: @escaping @Sendable () async -> Bool, journal: @escaping @Sendable (ConnectionCallRequest, String) async -> Void); public func start() async throws; public func stop() }
  ```
  One socket per conversation (path under the window's existing socket directory, suffix `-approval.sock`), so a request names its conversation by the socket it came on.
  The plane's proposal: `PendingMutation(action: "connection_call", params: <request as JSON>, database: nil, statement: "<connection> · <tool>(<arguments, one line>)", affectsEveryRow: false, origin: .agent, place:, conversation:)`.

- [ ] **Step 1:** Tests: `allowedReadOnlyIsAllowed`; `allowedWriteTypedIsAllowed`; `allowedWriteSpokenAsks` (returns nil); `unallowedAsks`; `lockedAlwaysAsks`; `approvedOnThePlaneAllows`; `cancelledOnThePlaneDeniesWithMessage` (message names the tool and says the operator declined); `everyDecisionIsJournalled` (action `connection_call`, outcome `allowed`/`asked-approved`/`asked-declined`); `requestOnUnknownConversationIsDenied`.
- [ ] **Step 2:** `make app-test` (filter `ConnectionApproval`) → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `connections: the app answers wakil-connect on its own socket, raising the permission plane; a spoken turn never runs a write unasked`.

### Task 6: Connections in the session's MCP config

**Files:**
- Modify: `app/Sources/WakilKit/App/AgentMCPConfig.swift`, `app/Sources/WakilApp/WindowSession.swift` (the `harnessFactory` closure: read the place's org connections each call, pass the approval socket path for the conversation)
- Test: the existing test file that already calls `agentMCPConfigJSON` (find it with `grep -rl agentMCPConfigJSON app/Tests`)

**Interfaces:**
- Consumes: Task 2's `config_tree` connections (decoded in Task 7's `SettingsConnection`; until then a minimal `AgentConnection { name: String }`), Task 5's socket path.
- Produces: `agentMCPConfigJSON(shimExecutable:socketPath:binaries:place:provider:connections: [AgentConnection] = [], approvalSocket: String? = nil)` — each connection becomes server `<name>` → `{command: <wakil-connect>, args: ["--connection", name], env: <the place env> + WAKIL_APPROVAL_SOCKET}`; the shim's env never gets `WAKIL_APPROVAL_SOCKET`. `agentAllowedTools(actions:connections:)` appends `mcp__<name>` for each.

- [ ] **Step 1:** Tests: `noConnectionsLeavesConfigUnchanged` (equal to the output with today's arguments); `eachConnectionIsAServerOfWakilConnect`; `approvalSocketOnlyOnConnections` (the shim's and `wakil-pm`'s env lack it); `connectionsAreAllowedServerWide`; `connectionsFollowThePlace` (two places, two orgs → each JSON names only its org's connections and its `WAKIL_ORG`); `missingWakilConnectBinaryDropsConnectionsWithANote`.
- [ ] **Step 2:** → FAIL. **Step 3:** implement. **Step 4:** → PASS.
- [ ] **Step 5: Commit** `connections: every session gets its organization's connections, allowed server-wide behind wakil-connect`.

### Task 7: Settings → Connections

**Files:**
- Create: `app/Sources/WakilApp/ConnectionsSection.swift`, `app/Sources/WakilKit/App/WindowModel+Connections.swift`
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift` (`SettingsConnection`, `SettingsConnectionField`; `SettingsOrg.connections`, `SettingsOrg.jiraTokenStored`), `app/Sources/WakilKit/Registry/StandardActions.swift` (the `ctx_connection_*` and `ctx_jira_token_set` actions in the git-accounts loop's shape), `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (add them to the operator-only list), `app/Sources/WakilApp/SettingsPane.swift` (the org node shows the section; its Jira site row moves into the Jira connection's page), `app/Sources/WakilApp/OrgPlane.swift` (create form keeps the Jira site field unchanged)
- Test: `app/Tests/WakilKitTests/WindowModelConnectionsTests.swift`, `app/Tests/WakilKitTests/SettingsTreeConnectionsTests.swift`

**Interfaces:**
- Consumes: Task 2 tools, Task 4 sign-in tools.
- Produces the WindowModel API the view calls: `addConnection(org:kind:name:) async -> (name: String?, error: String?)`, `removeConnection(org:name:) async -> String?`, `setConnectionSecrets(org:name:values:) async -> String?`, `setConnectionAllow(org:name:tool:allow:) async -> String?`, `allowReadOnlyTools(org:name:) async -> String?` (one `connection_allow_set` per tool hinted read-only and not yet allowed), `checkConnection(org:name:) async -> ConnectionStatus` (`.connected(tools: [ConnectionTool], checkedAt: Date)` | `.needsSignIn` | `.failing(String)` — runs `wakil-connect` once with `--list` and records hints through `connection_update`), `signIn(org:name:) async -> String?` (cancellable), `setJiraToken(org:email:token:) async -> String?`.
- `wakil-connect --list` (add to Task 3's binary in this task): prints `{tools:[{name, hint}]}` or `{error}` and exits.

The view, per the spec's *What the operator gets* 1–3 and the mockups' wording:
- List rows: dot + name + `connected` / `needs sign-in` / `failing`; **+ Add connection** → catalog list + **Custom server**.
- Page: Server (read-only for a catalog kind); Sign-in by kind (token: one secure field; fields: labelled fields, secret ones secure; browser: **Sign in with <Title>…** → progress + **Cancel** → "Signed in as …" · **Sign out**; none: command + environment); stored secrets show `•••••••• stored in Keychain` with **Replace** (the `settings.apiToken.confirm` pattern); Status line, error whole; Tools table **Tool · Server says · Allow agent** with a toggle per row, a locked row disabled with `(locked)`, and **Allow every tool the server marks read-only**.
- Jira page: site (the field that was on the org node), email, token (Replace pattern), status; `wakil-pm`'s tools listed with no switches and the line "Permissions for these are Wakil's own."
- Every field keeps its text on blur (Rule 2); the first sign-in field is focused on open (Rule 3); in-flight buttons disabled (Rule 5); saving stays on the page (Rule 6).

- [ ] **Step 1:** Tests: `settingsTreeDecodesConnections` (and an org with none decodes to `[]`); `addConnectionDispatchesOperatorOnly` (origin `.agent` refused); `secretsAreRedactedInTheJournal` (`ctx_connection_secrets_set`, `ctx_jira_token_set`); `allowReadOnlyToolsSkipsLockedAndAllowed`; `checkConnectionMapsErrorWhole`; `signInCanBeCancelled`.
- [ ] **Step 2:** → FAIL. **Step 3:** implement model then view. **Step 4:** → PASS; `make app-build` succeeds.
- [ ] **Step 5: Commit** `connections: Settings → Connections — the list, the sign-in forms, status and the Allow agent table; the Jira token in the app`.

### Task 8: The record

**Files:**
- Modify: `docs/wakil/decisions.md` (new `### 2026-10-25 — a connection's tool, allowed by the operator` under *Invariant 6 — the writes that have earned in*: the class, why — an organization's own server, the operator's explicit tick per tool, destructive never — and what stays refused: a locked tool unasked, a ticked write from a spoken turn unasked), `docs/wakil/north-star.md` (§4 Invariant 6 table row `| A connection's tool the operator allowed | wakil-connect | 2026-10-25 |`; §8 the new sub-phase row), `docs/architecture/README.md` (`wakil-connect` and the approval socket), `CONTRIBUTING.md` (adding a catalog entry is one `ConnectionKind`)
- Test: `make test` (its `docs-check`), `scripts/public-check.sh`

- [ ] **Step 1:** Write the four edits.
- [ ] **Step 2:** `make test` → PASS; `scripts/public-check.sh` → exit 0.
- [ ] **Step 3: Commit** `connections: the earned-write class, the charter row and the code map`.

---

After Task 8: the whole-branch review, then **Cover** (the e2e auditor, `docs/agents/e2e.md`) and **Walk** (`docs/wakil/phase-connections-acceptance.md`, written in Cover).
