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
