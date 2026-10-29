# Workspaces piece 2 — Running the app: the Go core

**Spec:** `docs/superpowers/specs/2026-10-29-workspaces-design.md`, piece 2 and decisions 12–15, with
its *Amendment 2026-10-29: piece 2's Go core*. **Branch:** `yehia-khalil/workspaces-2-running`.
**Scope of this plan:** Go only (`internal/wakilcore`, `cmd/wakil-ctx`). The Running settings UI,
Run / Stop / Build actions, Try, and the terminals that execute a plan are a later plan, written
after piece 1 lands; that plan calls the tools below and nothing else.

## Contracts the Swift side will call (all on `wakil-ctx`, window-owned)

Every tool answers a JSON object; every refusal is one whole sentence through `toolErr`. `repo` is a
root's folder name (the last path element of a `roots[].path`). `projectPath` is optional
everywhere and defaults to the active project.

| Tool | In | Out | Writes |
|---|---|---|---|
| `recipe_detect` | `{repo, projectPath?}` | `Draft`: `{repo, kind, recipe, doesntRun, runtimes[], missingEnv[{key,example}], hosts[], compose?, questions[]}`; `recipe.notes` says, per field key, where it came from | nothing |
| `recipe_draft_all` | `{repos?: [name], projectPath?}` (default every root) | `DraftAll`: `{recipes{name: Recipe}, repos{name: RepoRun}, groups[{recipe, repos[], from}], sharedServices[{name, host, in, repos[], from}], nothingToRun[{repo, why}], questions[]}` | nothing (Rule 9: the operator saves) |
| `recipe_effective` | `{repo, projectPath?}` | `{repo, recipeName, doesntRun, recipe, from{fieldKey: "shared"\|"repo"}}` | nothing |
| `recipe_save` | `{recipes?: {name: Recipe\|null}, repos?: {name: RepoRun}, projectPath?}` | `{}` | `project.json`, read-modify-write; the whole result validated first, every problem listed |
| `recipe_plan` | `{repo, workspace, checkouts[{repo, path, port}], projectPath?}` | `RunPlan` (below) | nothing |
| `recipe_ready_wait` | `{url?, output?, text?, timeoutSeconds?}` | `{ready, detail}` | nothing; cancellable (Rule 4) |
| `ports_allocate` | `{existing{checkoutKey: port}, want[checkoutKey]}` | `{blocks{checkoutKey: port}, taken[port]}` | nothing (the caller keeps blocks in `workspaces.json`) |
| `compose_override` | `{repo, port, reserved?[offset], workspace, projectPath?}` or `{dir, …}` | `{projectName, file, yaml, remaps[{service, from, to, protocol}], variables[{service, variable}], containerNames[{service, name}], cannotRunTwice}` | nothing (the plan carries the file) |

Field keys of `from` and `notes`: `needs`, `copy`, `clone`, `services`, `setup`, `build`, `ready`,
`teardown`, `alsoWriteEnvFile`, `in`, `ports.<VAR>`, `env.<VAR>`, `processes.<name>`.

`RunPlan`: `{repo, recipe, dir, env{VAR: value}, secrets{VAR: "wakil:<org>:<ref>"}, envFile?{path,
keys[]}, files[{path, content, gitExclude}], steps[PlanStep], build?, ready?{url|output,
timeoutSeconds}, teardown[PlanStep], warnings[]}`; `PlanStep` is `{phase, name, command, dir,
longRunning, once, target, targetKind, paths, from}` with `phase` one of `need` (start `target`
first; `targetKind` `repo` or `service`, whose plan is `recipe_plan {repo: target}`), `copy` and
`clone` (`paths` from `from`, Main's folder, into `dir`; clone is copy-on-write), `service`,
`setup`, `process`, `build`, `teardown`; `once` is `workspace` (needs, services), `checkout` (copy,
clone, setup) or empty. Commands are not expanded: the terminal's environment is `env` plus each
`secrets` value read from the Keychain at run time; `ready.url` is expanded. `warnings` carries the
compose cannot-run-twice sentence. An effective `build` of `""` means none.

## Phase 1 — The recipe in `project.json`

1. **Types and round trip.** `Recipe`, `EnvValue` (`"v"` or `{"secret": "ref"}`), `Process`,
   `Ready`, `RepoRun` embedded in `Root`, `Project.Recipes`. Tests: a full file round-trips
   byte-stable; a file without the keys loads and saves unchanged; `omitzero` keeps `[]` distinct
   from absent.
2. **Merge.** `EffectiveRecipe(project, repo)`: lists and scalars replace, maps merge per key,
   processes by name (an empty command removes a shared one); `from` per field. Tests per field kind.
3. **Validate.** `ValidateRecipes(project)`: names, references, needs cycles, env names, a value or a
   secret, ready URL or output, process names, relative copy and clone globs; every problem in one
   error. Tests one per problem, and a combined one.
4. **Save.** `SaveRecipes(path, patch)`: read-modify-write, validate before writing, org check.

## Phase 2 — Ports and env

5. `AllocatePortBlocks(existing, want, probe)`: blocks of ten from 41200, skip any listening port,
   keep existing blocks, the no-free-block sentence. `ListeningProbe` (dial and bind).
6. `RunEnv(ctx)`: `WAKIL_PORT`, `_1.._9`, `WAKIL_PORT_<REPO>`, `WAKIL_DIR`, `WAKIL_DIR_<REPO>`,
   `WAKIL_WORKSPACE`, `WAKIL_REPO`, `COMPOSE_PROJECT_NAME`; `RepoEnvName` sanitising and its clash
   error; `ExpandWakil(expr, env)` (`$X`, `${X}`, `$$`; an unknown `$WAKIL_*` named whole).

## Phase 3 — Compose isolation

7. `ParseCompose` (short and long `ports`, variables, fixed ports, `container_name`, build vs image).
8. `ComposeOverride(file, base, reserved)`: `!override` lists with fixed ports moved into the block;
   the cannot-run-twice sentence. Fixtures with both syntaxes.

## Phase 4 — Detection

9. `DetectRecipe(dir, opts)`: one fixture repo per row of the Detect table under
   `internal/wakilcore/testdata/recipes/<row>/`, golden `<row>.json` (`-update` rewrites). The
   repo's own entry points (Makefile, justfile, Taskfile, Procfile, `bin/dev`, `script(s)/*`) win
   over stack guesses; each field's note says why.

## Phase 5 — Draft all

10. `DraftAllRecipes(drafts)`: group by kind, majority values shared, differences as overrides;
    shared services from `.env.example` hosts several repos point at and no repo's own compose
    defines; questions.

## Phase 6 — The plan and readiness

11. `BuildRunPlan(project, repo, ctx)`: ordered steps, env, secrets as Keychain service names,
    the compose override file and `COMPOSE_FILE`, `.env` keys when opted in. `MergeDotEnv`.
12. `WaitReady` (URL 200–399 polled, or an output line: substring, `/regex/`), timeout, cancel.

## Phase 7 — Tools and docs

13. The eight tools on `wakil-ctx`; `schema_test.go` list; tool tests through the in-memory client.
14. `docs/architecture/go.md` (tools, files), `state.md` (`project.json` keys), the spec amendment.

Gates per commit: `go test ./internal/wakilcore/ ./cmd/wakil-ctx/`, `bash scripts/public-check.sh`;
at the end `make build`, `make test`.

---

# Part two — the Swift half (written after piece 1 landed, 2026-10-30)

**Scope:** the Running settings, Run / Stop / Build, Try, terminals that execute a plan, port blocks
in `workspaces.json`. Piece 1 gives each checkout `ports` (`PortBlock?`) and `path`; the record is
Go's, written through `workspaces_write`. The home screen's card (where ▶ Run is drawn) is piece 3;
this part gives it the status line and the actions it will call.

**Calls this part makes** (recorded in the spec's amendment *piece 2's Swift half*):

- **One-shot steps run headless, processes in terminals.** `services`, `setup` and `build` run
  through Go (`recipe_exec`: the operator's login shell, output captured whole, cancellable), so a
  failure is shown whole on the card and in the thread (Rule 8) and *setting up* can show (Rule 5).
  Each process gets a terminal pane in the workspace's view, titled `<repo> · <process>`, opened at
  the checkout with the plan's environment (secrets included, read from the Keychain at run time)
  and the command typed and run — so the operator and the agent read it with `read_pane`.
- **Files, copy, clone and `.env` are Go's** (`recipe_prepare`), not Swift's: a capability that
  touches the filesystem belongs in Go (CONTRIBUTING). Copy and clone never overwrite, and run once
  per checkout (`setUp` in the checkout's record, set once setup passed).
- **Try is headless too** (`recipe_try`): the throwaway workspace's checkout, every step's output,
  the ready check, then its processes stopped and teardown run. Archived when the form closes.
- **Secrets** are stored by `recipe_secret_set` under a derived ref `run:<project>:<owner>:<VAR>`
  (owner: the recipe or the repo); never typed, never shown.
- **The agent's reach** is `workspace_run`, `workspace_stop`, `workspace_build` in its own workspace,
  naming a repo and a process, never a command; price *allow* outside production, *gate* in it. The
  Running settings' actions (`running_*`) are operator-only.

## Phase 8 — Go: what the window needs to run a plan

15. `WorkspaceCheckout.SetUp` (`setUp`), kept through `workspaces_write`. Test: round trip.
16. `PrepareRun(plan, mainDir, firstRun, secrets)`: write `files` (and their `.git/info/exclude`
    line), copy (`cp -R`, never over an existing file) and clone (`cp -Rc`, APFS clonefile) on a
    first run, the `.env` lines when `envFile`. Tests: each, on temp dirs; nothing overwritten.
17. `ExecStep(ctx, dir, env, command, timeout)`: the login shell, combined output, exit code,
    seconds; a cancelled context kills the process group. Tests: exit code, output, timeout, cancel.
18. `TryRecipe(ctx, plan, …)`: prepare, services, setup, processes started headless, ready (URL or
    output line), processes stopped, teardown; each step's result. Tests with `sh` commands.
19. Tools `recipe_prepare`, `recipe_exec`, `recipe_try`, `recipe_secret_set` on wakil-ctx, confined
    to the project's folders and recorded checkouts; schema list; tool tests.

## Phase 9 — Swift: the plan and the runner (`WakilKit/Workspace/`)

20. `RunPlan` and friends, `Decodable` from `recipe_plan` / `recipe_prepare`. Test: decodes Go's
    golden plan.
21. Port blocks on `WorkspaceRouter` (`ensurePorts`): `ports_allocate` with every recorded block as
    `existing`, keyed `<workspace id>/<repo>`; recorded as `PortBlock(first, count: 10)` and saved.
    Tests: allocates once, keeps a block, the no-free-block refusal whole.
22. `WorkspaceRunner` (actor): `run(workspace, repo, process?)` — needs first (a repo of the
    workspace or a shared service, once per workspace), prepare, services (once per workspace),
    setup (once per checkout), then each process in its terminal, then ready; `stop(workspace,
    repo?)` closes the terminals (a shared service's teardown runs when its last user stops);
    `build`. State per workspace and repo (`RunState`) and `runStatusLine` (`api running on :41200 ·
    queue running`). Through a `RunTerminals` seam and the ctx `ToolCaller`. Tests with fakes: the
    order, once-ness, a failure stops the run and is said whole, stop, build, a process filter.
23. Archive stops the workspace's processes and runs its teardown (the router's run hook).

## Phase 10 — Actions

24. `workspace_run {workspace?, repo, process?}`, `workspace_stop {workspace?, repo?}`,
    `workspace_build {workspace?, repo}`: agent-reachable; an agent's own workspace by default, and
    only its own; refused from Main naming decision 12. Price `(production: .gate, otherwise:
    .allow)`. Tests: classification, refusals, the agent's own workspace.
25. Operator-only `running_read`, `running_detect`, `running_draft_all`, `running_save`,
    `running_secret_set` (`secretParams: value`), `running_try`, `running_try_end`. Tests through a
    fake ctx client.
26. `workspace_list` rows carry what is running (Invariant 3); the agent's instructions name the
    three actions.

## Phase 11 — The Running settings (`WakilApp`, decisions in `WakilKit`)

27. `RunningSettingsModel` (WakilKit, pure): the list grouped by recipe (shared services first, then
    recipes, then no recipe), a repo's rows with where each value came from (shared grey, own
    violet), an edit turned into a save patch (a repo's change is an override; clearing an override
    inherits again), env rows with secrets. Tests per rule.
28. The settings tree's **Running** node under a project; `RunningSettingsForm`: the list, the form,
    Env with 🔒, **Draft all** (proposal, Save all / Discard), **Detect** (fills the form unsaved),
    **Try** (steps, Cancel). Kept on blur (Rule 2), Draft never saved unasked (Rule 9), Try
    cancellable (Rule 4) and shown in flight (Rule 5), errors whole (Rule 8).

## Phase 12 — Cover and docs

29. e2e checks (`e2e/checks/seeded/workspaces-running-*.jsonl`), written, not run.
30. `docs/architecture/wakilkit.md`, `go.md`, `state.md`; the spec's amendment.
