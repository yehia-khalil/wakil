# Contributing to Wakil

Read `docs/architecture/README.md` first: it is the map of the code, Swift and Go. The workflow (Design →
Plan → Build → Cover → Walk, and which tool drives each rung) is `docs/agents/workflow.md`; it is not
repeated here. The charter's invariants (`docs/wakil/north-star.md` §4) and `PRODUCT.md`
§Interaction Rules bind every change.

Each rule below names the test that enforces it, or says *convention*.

## Where does my code go?

| You are adding | It goes in | Enforced by |
|---|---|---|
| A capability that touches a system (a database, an API, git, Jira, files, the Keychain) | Go: logic in `internal/wakilcore`, a tool in a `cmd/<binary>/main.go` | `internal/wakilcore/layering_test.go` (wakilcore imports nothing else from the module); keeping the MCP SDK out of wakilcore is *convention* |
| A saved browser password (the exception to the row above: Swift, in `Browser/`, through Security.framework, not Go and not `/usr/bin/security`; Decision 49) | `BrowserPasswordStore` and the `browser_password_*` actions in `WakilKit/Browser/`; the page side in `WakilApp` | `BrowserPasswordStoreTests` (its own temporary keychain), `ActionClassificationTests` |
| Something the operator or the agent can do | An `Action`, registered by the `register*Actions` function of the folder that owns it (for example `registerEditorActions` in `Editor/EditorActions.swift`) | `ActionClassificationTests` (it declares an audience) |
| State a pane shows | That pane kind's folder (`Api/`, `Editor/`, `Terminal/`; the db and settings kinds in `Panes/`): its `PaneKind` conformance and `PaneStore+<Kind>.swift`; see "A new pane kind" | *convention* (`PaneKindsTests` checks a kind is registered, not where its state lives) |
| A pure decision a view needs (a label, a layout number, a key rule) | `WakilKit`, beside the kind or folder it belongs to; **never `WakilApp`**, which has no test target | *convention* |
| A new quick task (a short model call: a status line, a title, a fast edit) | A caller of `QuickTasks.respond` or `.infill` (`App/QuickTasks.swift`): a prompt and a parser, nothing in `Harness/` (Decision 42) | *convention* (`QuickTasksTests` pins the routing) |
| Drawing | `app/Sources/WakilApp/` | *convention* |
| A shared value type with no dependencies | `Core/` | `wakilKitKeepsItsLayering` (`Core/` may use no other folder) |
| Window orchestration that must see everything | `App/` (`WindowModel`, `WakilWiring`). The last resort: nothing in WakilKit may use `App/` | `wakilKitKeepsItsLayering` |

The folders and what each may use: `docs/architecture/wakilkit.md`.

## Recipes

### A new action

1. Build an `Action` (`app/Sources/WakilKit/Core/Action.swift`): `name`, `description`, `kind`
   (`.read`, `.control` or `.mutate`), **`audience`** (`.agentReachable` or `.operatorOnly`), `schema`,
   `handler`. Optional: `targetEnvironmentParam` (a `.control` that switches environment), `price`
   (a `.mutate`'s gate decision in production and otherwise; default block / gate), `secretParams`
   (params the journal redacts).
2. Register it in the owning folder's `register*Actions`. If no folder owns it, it probably belongs
   in an existing one. The handler reaches Go only through the `MCPClient`s it was given.
3. If it is `.operatorOnly`, also add it to `operatorOnlyActions` (`MCP/PermissionPrompt.swift`),
   which performs the refusal, and to the pinned list in
   `theClassificationLeavesTodaysReachabilityExactlyAsItWas`. `ActionClassificationTests` fails if
   the audience is missing or the two disagree.
4. Nothing else publishes it: the agent's `tools/list` is the registry, and `agentAllowedTools`
   pre-approves `.read` and `.control` actions automatically.
5. A control that dispatches it gets an e2e check, or a line in `e2e/checks/uncoverable.tsv` with
   its reason (see `docs/agents/e2e.md`).

### A new shortcut

1. Add a `KeyCommand` row in `app/Sources/WakilKit/Keyboard/KeyCommands.swift`: stable id, title,
   `KeyGroup`, `KeyPlace` and default chord. A default Decision 50 refuses, or one already held in the
   same place, fails `KeymapTests`.
2. Make `runKeyCommand` (`App/WindowModel+Keyboard.swift`) run it: a `browser.*` command through
   `browserKeys`, any other by a `case`. Only a pane-bound command returns false, when no pane of its
   kind has focus, so the key falls through; an anywhere command claims the key even when it does
   nothing, as its menu item does. A command a focused web page must not keep goes in
   `Keymap.beforePage`.
3. The menus build from `KeyCommand.all` by group, so a row in the Pane, Editor, Window or Browser
   group needs no `AppScene.swift` edit. Only a new `KeyGroup`, or a Conversation row (that menu
   names its ids), needs a `KeyMenuItems` there. Never write a literal `.keyboardShortcut` or a
   chord in a tooltip or a hint: read `model.keymap` or `\.keymap`.
4. An e2e check for the press, or a line in `e2e/checks/uncoverable.tsv`.

### A new MCP binary

1. `cmd/<name>/main.go`: `newServer()` with `mcp.NewServer` and `mcp.AddTool`, `main()` running it over
   `mcp.StdioTransport`. Logic in `internal/wakilcore`; errors through `mcpx.ToolErr`.
2. Add `<name>` to `BINS` in the `Makefile`.
3. Add it to the copy loop in `scripts/make-app-bundle.sh` and to `bundledServers` in
   `scripts/app_bundle_test.go`.
4. Add `/<name>` to `.gitignore` (root binary names are listed there).
5. If it should be registered into a provider's own config dir, add it to `SERVERS` in
   `scripts/register-provider.sh` and to `providerServers` in `scripts/register_provider_test.go`.
6. Choose who launches it:
   - **Window-owned** (its tools change pane state): start it in `WakilWiring.build` (`startClient`),
     add a property, add it to `wakilOwnedClients` (`everyWakilOwnedClientJoinsTheOrgSwitch` fails
     otherwise), and pass it to the `register*Actions` that use it.
   - **Agent-facing** (it answers and touches no pane): add it to `agentFacingServers`
     (`App/AgentMCPConfig.swift`).
7. Add a `### <name>` section to `docs/architecture/go.md`: what it serves, its tools, who launches it
   (`TestArchitectureDocsCoverEveryFolderAndBinary` fails otherwise).
8. Tests: `main_test.go` and a `schema_test.go` calling `mcpxtest.AssertObjectOutputSchemas` with
   its tool names.

### A new pane kind

A kind is a `PaneKind` conformance (`app/Sources/WakilKit/Panes/PaneKind.swift`); how the store
holds it is `docs/architecture/wakilkit.md`, "Pane kinds". Api (`Api/ApiPaneKind.swift`,
`Api/PaneStore+Api.swift`) is the smallest example; Editor (`Editor/`) shows a kind with a restore step, a non-action write path and a renderer seam.

| Where | What |
|---|---|
| its own WakilKit folder | the conformance (`<Kind>PaneKind.swift`: `names`, its `Contents` and `Snapshot`, `emptyContents`, `emptySnapshot`, `snapshot(of:in:)`, `readPane(_:in:)`, and `Shared` with the scope hooks if it keeps store-wide state); its store methods as an `extension PaneStore` in `PaneStore+<Kind>.swift`; `PaneSnapshot.<kind>`; an `OffersIdentifiers` conformance if it offers names to the vocabulary; its actions (`register<Kind>Actions`, called from `WakilWiring.build`); its tests |
| `WakilApp` | its view file, one `case` in `switch pane.kind` in `Canvas.swift`, and a `WindowModel` read of its cell if the view needs one (like `terminal(_:)`) |
| `App/PaneKinds.swift` | one line in `PaneKinds.standard` |
| `Layout/Pane.swift` | its name in `Pane.kinds` (what `pane_open` accepts and a loaded layout keeps) |

The tests it needs: `PaneKindsTests` covers registration with no change (listed once, names unique
and in `Pane.kinds` both ways, its never-written pane answers `read_pane`); the kind's own folder
tests its store methods, its `readPane` keys and its actions. A pane that must do something when it is restored (launch, an org switch loaded from disk) conforms to
`PaneRestorable` and returns a `PaneRestoreStep` from `restoreStep(for:)`: the action to dispatch, and whether a refusal is written
into the pane. `WindowModel.restorePaneContents` names no kind. Keep `rerunsSubjectOnRestore` true only
for a kind whose subject is a read (it is pinned in `PaneKindClassificationTests`).

Two traps met while building this:

- **The compiler.** Under the Swift 6.4 toolchain in use, `map`, `flatMap` and key paths over
  `[any PaneKind.Type]` crashed the compiler (SILGen) in test code. Write plain loops; see
  `servedNames()` in `PaneKindsTests.swift`.
- **The layering scanner.** `LayeringTests` treats a capitalised name declared in exactly one
  folder as a link to that folder. Spelling `Dictionary<…>.Keys` matched a type named `Keys` in
  `Speech/`. Avoid such spellings (`PaneStore.paneKeys` is `some Collection<String>` for this
  reason) or add the name to `FolderGraph.genericNames` in `LayeringTests.swift`.

### A new WakilKit folder

1. Say, in the PR, why the code does not belong in an existing folder.
2. Add a `### <Folder>/` section to `docs/architecture/wakilkit.md`: what it is for, key types, what
   it uses, its tests (`TestArchitectureDocsCoverEveryFolderAndBinary` fails otherwise).
3. Add a line to `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt` for each link it makes
   (`wakilKitKeepsItsLayering` fails otherwise). Links into `Core/` need none; links into `App/` are
   not allowed.

### A new provider

Organisations, providers and accounts are described in `docs/wakil/org-and-provider-model.md`. The
Go records are `internal/wakilcore/provider.go`; the Swift side is the `Provider*` files in
`app/Sources/WakilKit/App/`.

## Tests every change needs

| Change | Test |
|---|---|
| Swift logic | Swift Testing in `app/Tests/WakilKitTests/` |
| A stored property on `WindowModel` | Classify it in `InvalidationContractTests.swift`; reset it in `invalidateForOrgChange()` if it is org-derived |
| A new link between WakilKit folders | A line in `Fixtures/layering-allowed.txt` |
| A new action | An `audience`; see "A new action" |
| A UI control | An e2e check, or an `e2e/checks/uncoverable.tsv` line with its reason |
| Where keyboard focus goes, or a surface's layout | An `expect.focus` check for each focus change, and an `expect.frame` check at a narrow `do.resize` for each layout change (`docs/agents/e2e.md` step 3) |
| A new `WakilKit` folder, `cmd/` binary or `internal/` package | A section in `docs/architecture/` |
| Go | `go test` beside the code; a new tool in the binary's `schema_test.go` list |

## Before a PR

- `make build` and `make test`.
- `make app-test`. It does not build Go, so run `make build` first when Go changed.
- `make e2e` for a UI change: the checks the diff reaches, for a few minutes of screen. Ask the operator first. `make e2e-full` runs nightly on `main` (the night run, `make e2e-night-status`), not before merge.
- No `Co-Authored-By` or "Generated with" lines in commits or PR descriptions.
