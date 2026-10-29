# Testing

Four kinds of check, from fastest to slowest: Go tests, Swift unit tests, e2e checks against the
built app, and the operator's acceptance walk. The workflow that decides when each runs is
`docs/agents/workflow.md`; this file says what each one is.

## Swift unit tests

- **Where:** `app/Tests/WakilKitTests/`, one target (`WakilKitTests`) testing `WakilKit` only.
  `WakilApp` has no test target, which is why decisions live in `WakilKit`.
- **Framework:** Swift Testing (`import Testing`, `@Test`, `#expect`).
- **Run:** `make app-test` (all; output to `.context/app-test.log` through `scripts/quiet-test.sh`),
  or filtered: `cd app && ../scripts/swift-test.sh --filter '<regex>'`. `scripts/swift-test.sh` adds
  the framework search paths the Command Line Tools need for Swift Testing.
- **`make app-test` does not build Go.** Tests that drive a binary use whatever `bin/` holds, so run
  `make build` first when the Go side changed.

The structural tests, which fail on a shape rather than a behaviour:

| Test | File | Fails when |
|---|---|---|
| `wakilKitKeepsItsLayering` | `LayeringTests.swift` | a folder uses `App/`, `Core/` uses a folder, a link is not on `Fixtures/layering-allowed.txt`, or a listed link is gone. See [wakilkit.md](wakilkit.md). |
| `everyWindowModelPropertyIsClassifiedForTheOrgSwitch` | `InvalidationContractTests.swift` | a `WindowModel` stored property is not classified as org-derived or org-independent. See [state.md](state.md). |
| `everyRegisteredActionDeclaresAnAudience`, `theAudienceAgreesWithTheOperatorOnlyDenylist` and two more | `ActionClassificationTests.swift` | a registered action has no `audience`, or `.operatorOnly` disagrees with `operatorOnlyActions`. |
| `everyWakilOwnedClientJoinsTheOrgSwitch`, `theWatcherIsActuallyPassedIn`, the child-environment key sets | `AppWiringTests.swift` | an `MCPClient` on `WakilWiring` is missing from `wakilOwnedClients`; the wiring is not handed over; a child gets an unexpected variable. |
| the shutdown contract | `ShutdownContractTests.swift` | a long-lived pump `WindowModel` starts is not cancelled by `shutdown()`. |
| `everyKindIsListedOnceAndNamesAreUnique`, `everyLayoutKindIsServed`, `everyKindsNamesAreLayoutKinds`, `everyKindsEmptyPaneAnswersReadPane` | `PaneKindsTests.swift` | a pane kind is listed twice in `PaneKinds.standard`, two kinds serve one name, `Pane.kinds` and the kinds' names disagree, or a kind's never-written pane does not answer `read_pane`. See [wakilkit.md](wakilkit.md), "Pane kinds". |
| `aPaneHoldingOneKindRefusesAnother`, `aNeverWrittenPaneAnswersItsKindsEmptySnapshot` and the scope-hook tests | `PaneKindStorageTests.swift` | `PaneStore`'s slots let one kind overwrite another's pane, a never-written pane answers the wrong shape, or a kind's store-wide state misses a scope change. |
| `aTerminalTickInvalidatesOnlyItsOwnPane` | `PaneSnapshotCellTests.swift` | a terminal refresh invalidates another pane's reads: it watches panes that have no cell, so it catches `WindowModel.paneCells` being replaced on a tick. Its sibling `aTerminalTickDoesNotInvalidateAnotherPanesExistingCell` watches a second terminal pane's real cell, so it also catches a tick writing another pane's cell. Whether SwiftUI redraws only that view rests on `paneView`'s call site in `WakilApp/Canvas.swift`, which is untested. |

## Go tests

- **Run:** `make test` runs `docs-check` (the charter's 4,000-word limit) and then
  `go test ./...` with `CGO_ENABLED=0`. A single test: `go test ./scripts/ -run <Name>`.
- **Per package:** a `_test.go` beside most files in `internal/wakilcore`; each `cmd/` binary has
  `main_test.go`, and `wakil-ctx`, `wakil-db`, `wakil-http`, `wakil-pm` and `wakil-recall` have
  `schema_test.go` (output schemas through `internal/mcpx/mcpxtest`).
- **`internal/wakilcore/layering_test.go`** — the Go layering rules (see [go.md](go.md)).
- **`internal/mcpx/shippedbinary_test.go`** — drives the built `bin/wakil-db`; skipped until
  `make build`.
- **`scripts/*_test.go`** — checks on the repository itself: `makefile_test.go` (every Makefile
  recipe runs with `CGO_ENABLED=0`; defines `repoRoot`), `app_bundle_test.go` (`scripts/make-app-bundle.sh` bundles every
  server), `register_provider_test.go` (`scripts/register-provider.sh`), and
  `architecture_docs_test.go` (every WakilKit folder, `cmd/` binary and `internal/` package has a
  heading in `docs/architecture/wakilkit.md` or `go.md`).
- **`make test-live`** — the MySQL and Mongo tests `make test` skips, against Docker containers.

## e2e

The built app, launched and driven through its accessibility identifiers. The auditor that writes
the checks is described in `docs/agents/e2e.md`; read it before writing one.

- **Driver:** `e2e/cmd/wakil-e2e` with `e2e/driver/` (the step kinds are `do`, `dispatch`, `expect`
  and `parity`, parsed by `e2e/driver/check.go`). `e2e/axresolve/` resolves identifiers read-only;
  `e2e/stub/` is the scripted agent.
- **Checks:** `e2e/checks/unseeded/*.jsonl` (nothing on disk; the organisation plane),
  `e2e/checks/seeded/*.jsonl` (an organisation open, no agent), `e2e/checks/agent/*.jsonl` (seeded
  with the scripted agent). The directory chooses the launch.
- **`e2e/checks/uncoverable.tsv`** — surface no check can reach, one line each with its reason.
  `e2e/checks/backfill.tsv` lists checks proved failable elsewhere.
- **Gates:** `make e2e` runs the checks against a fresh bundle, then the coverage step; `make e2e-new`
  proves each new check fails against the merge-base; `make e2e-cover` and `make e2e-backlog` report
  coverage.
- **The night run:** `e2e/cmd/wakil-e2e-night` with `e2e/night/`, a launchd job that runs
  `make e2e-full` on `main` between 23:00 and 07:00, fixes what went red on `e2e-night/<date>` and
  re-runs it. It replaces a pre-merge full run.
- **It uses the screen.** Ask the operator before running it.

## Acceptance runbooks

`docs/wakil/*-acceptance.md`, one per sub-phase, on its branch until the feature merges: what the operator walks by hand (the Walk rung).
`make e2e-runbook` renders the machine half (the e2e records) into a runbook between its markers.

## Make targets

| Target | What it does |
|---|---|
| `make build` | Builds every Go binary in `BINS` into `bin/` |
| `make test` | `docs-check`, then `go test ./...` |
| `make docs-check` | Fails if `docs/wakil/north-star.md` exceeds 4,000 words |
| `make test-live` | Engine-backed Go tests against Docker MySQL and Mongo |
| `make vet` | `go vet ./...` |
| `make fmt` | Fails if any Go file is not gofmt-clean |
| `make shaders` | Compiles `app/Shaders/Void.metal` to `app/Sources/WakilApp/default.metallib` |
| `make app-build` | `swift build` in `app/` |
| `make app-test` | The Swift suite (does not build Go) |
| `make app-bundle` | `make build`, then `scripts/make-app-bundle.sh debug` |
| `make e2e` | The e2e checks against a fresh bundle, then coverage |
| `make e2e-new` | Proves new checks fail against the merge-base |
| `make e2e-cover` | The coverage gate on its own |
| `make e2e-backlog` | Every action and control no check touches (a list, never a gate) |
| `make e2e-runbook` | Renders the machine half of an acceptance runbook |
| `make e2e-agent-checks` | Only the scripted-agent checks |
| `make e2e-retrodict` | Re-introduces past defects to prove the harness sees them |
| `make e2e-night-install` | Builds the night run and loads its launchd job (23:00) |
| `make e2e-night-status` | Last night's result; fails if the night did not run |
| `make controls` | Lists every accessibility identifier and the gate's verdict; no GUI |
| `make captures`, `make captures-motion` | `WakilApp --capture` into `.context/2b-iv`, `--capture-motion` into `.context/2b-iv/motion` |
| `make bench-surface` | `WakilApp --bench-surface 50000`, release build |
| `make clean` | Removes `bin/` binaries and `e2e/bin` |
