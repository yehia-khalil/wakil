# Wakil build targets.
#
# Everything lands in bin/, which is gitignored, so a build never dirties
# the working tree. Nothing is ever built at the repository root: a stray
# root binary is both untracked clutter and — if it shares a name with a
# future source file — a thing .gitignore would have to hide. The
# .gitignore also lists the six root binary names explicitly for the case
# where someone runs `go build ./cmd/wakil-db` by hand without -o.
#
# CGO_ENABLED=0 is applied UNIFORMLY — to build, test and vet — so that the
# binaries, the tests that certify them, and the vet pass all compile under
# one set of build constraints. It used to be set on `build` alone, while
# `make test` ran plain `go test ./...`; the toolchain default here is
# CGO_ENABLED=1, so the suite was certifying a configuration nothing shipped.
#
# WHAT THIS CONSTRAINT IS NOT. It is not that cgo-on compiles different code.
# Measured on this tree (darwin/arm64, go1.27.1): the dependency graph is the
# same 363 packages in both modes, no package in it has any CgoFiles in
# either mode, and `go list -deps` reports a byte-identical list of compiled
# .go and .s files package for package. The two binaries come out the same
# size, with the same 14333 symbol names, the same 10 runtime cgo stubs and
# the same four linked dylibs, and `go test ./...` passes both ways. Every
# dependency is pure Go — modernc.org/sqlite, go-sql-driver/mysql and the
# mongo driver alike. An earlier version of this comment claimed cgo-on
# "would silently produce binaries that do not match what the code is written
# against"; that was not true of this tree and is not repeated here.
#
# WHAT IT IS. Two things, both real:
#
#  1. Cross-compilation, and therefore build reproducibility.
#     `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build ./cmd/wakil` succeeds on
#     this machine and yields a statically linked ELF. The identical command
#     with CGO_ENABLED=1 fails outright:
#         # runtime/cgo
#         gcc_amd64.S:27:8: error: unknown token in expression
#          pushq %rbx
#     because it needs a cross C toolchain that is not installed. Pinning cgo
#     off is what keeps the build independent of whichever C compiler a given
#     machine happens to have.
#
#  It does not cost the race detector, which is the usual reason a project
#  keeps cgo on: measured here, `CGO_ENABLED=0 go test -race ./...` builds
#  and passes on darwin/arm64, because Go supports -race without cgo on
#  this platform.
#
#  2. It is the premise wakilcore.SecretSet is written against. That function
#     shells out to the `security` CLI, and accepts exposing a secret in argv
#     for the duration of the call, specifically because a cgo Keychain
#     binding is not available to it (see its doc comment). Turning cgo on
#     would reopen that trade-off, and it should be reopened deliberately
#     rather than inherited by accident from an unset variable.

BINS := wakil wakil-ctx wakil-db wakil-git wakil-http wakil-pm wakil-recall wakil-files

# Set once and exported, so no target can drift from the others the way
# `test` did.
export CGO_ENABLED := 0

.PHONY: build test test-live e2e e2e-full e2e-run e2e-new e2e-night-install e2e-night-status e2e-runbook e2e-agent e2e-agent-checks e2e-retrodict e2e-cover e2e-backlog controls axresolve docs-check vet fmt clean shaders app-build app-test app-bundle captures captures-motion bench-surface

build:
	@mkdir -p bin
	@for b in $(BINS); do \
		echo "  build bin/$$b"; \
		go build -o bin/$$b ./cmd/$$b || exit 1; \
	done
	@echo "built: $(BINS)"

test: docs-check
	go test ./...

# ---------------------------------------------------------------------
# docs-check — the charter's own word limit, enforced
# ---------------------------------------------------------------------
#
# `north-star.md`'s header has always defined this check and nothing ever
# ran it. The file sat over its 4,000-word limit for five consecutive
# commits before anyone noticed, which is the 13,962-word failure the
# limit exists to prevent, at a tenth of the scale. A rule whose check
# nobody runs is not a rule, so `make test` runs it.
CHARTER := docs/wakil/north-star.md
CHARTER_LIMIT := 4000

docs-check:
	@words=$$(wc -w < $(CHARTER) | tr -d ' '); \
	if [ "$$words" -gt $(CHARTER_LIMIT) ]; then \
		echo "$(CHARTER): $$words words, over the $(CHARTER_LIMIT)-word limit."; \
		echo "  Something in it belongs in decisions.md, open-questions.md or phase-log.md."; \
		exit 1; \
	fi; \
	echo "  $(CHARTER): $$words/$(CHARTER_LIMIT) words"

# ---------------------------------------------------------------------
# test-live — the engine-backed tests, which `make test` cannot run
# ---------------------------------------------------------------------
#
# `make test` skips every test that needs a real MySQL or Mongo, so two of
# the guarantees this codebase leans on hardest — MySQL's
# transaction_read_only=1 and Mongo's read behaviour — are exercised by
# nothing in a default run. That was disclosed in the acceptance doc but
# left with no way to close it other than an operator remembering an
# undocumented `docker run` and two undocumented environment variables.
# This target is that way.
#
# It is deliberately NOT folded into `make test`. The default suite must
# stay runnable with nothing installed but Go; a target that needs Docker
# is a different contract, and merging them would make the fast loop
# depend on a daemon.
#
# THE SKIP CHECK IS THE POINT. `go test` reports a skipped test as "ok",
# so a naive live target passes cleanly with no containers running and
# certifies nothing at all — which is the exact failure this target exists
# to prevent. The run below therefore fails if any selected test SKIPs.
LIVE_MYSQL_CONTAINER ?= wakil-acc-mysql
LIVE_MONGO_CONTAINER ?= wakil-acc-mongo
LIVE_MYSQL_DSN ?= root:rootpw@tcp(127.0.0.1:13306)/wakilacc
LIVE_MONGO_URI ?= mongodb://127.0.0.1:27018/wakilacc

# The Mongo database name in the URI is REQUIRED, not decorative: the
# driver takes the connection's default database from the URI path, and
# the tests resolve it with databaseFromURI. A path-less
# "mongodb://127.0.0.1:27018" makes them fail rather than skip.

# The selection is by name prefix rather than an enumerated list so a new
# engine-backed test is covered the day it is written. It also picks up a
# handful of MySQL/Mongo tests that need no server (TestMySQLQuoteIdent,
# TestMongoEmptyDatabaseName, ...); running those again here is free, and
# they never skip, so they cannot mask a missing engine.
LIVE_TESTS ?= TestMySQL|TestMongo|TestHardenMySQLConfig

# The preflight only speaks about containers it knows the names of, so it
# stands aside entirely when the connection details were overridden — at
# that point the caller is pointing at an engine they manage and Docker
# has nothing to do with it.
LIVE_DEFAULTS := $(and $(filter file,$(origin LIVE_MYSQL_DSN)),$(filter file,$(origin LIVE_MONGO_URI)))

# WAKIL_MYSQL_CONTAINER is passed to the tests ONLY in the default path, and
# only so they can clean up after themselves. A MySQL test that proves a
# payload really writes a file has to make the server write one, and there
# is no SQL that deletes it again; without this, every run left another
# file in the container's secure_file_priv directory forever. The tests
# treat it as best effort and say so in their output when it is unset —
# which is the case when the caller overrode the connection details, since
# at that point the engine is theirs and Docker has nothing to do with it.
LIVE_CONTAINER_ENV := $(if $(LIVE_DEFAULTS),WAKIL_MYSQL_CONTAINER='$(LIVE_MYSQL_CONTAINER)',)

define LIVE_SETUP_HELP
Start the two throwaway engines, then re-run `make test-live`:

  docker run -d --name $(LIVE_MYSQL_CONTAINER) -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=wakilacc -p 13306:3306 mysql:8
  docker run -d --name $(LIVE_MONGO_CONTAINER) -p 27018:27017 mongo:7

(One line each on purpose: make collapses a backslash-newline inside a
`define`, so anything wrapped here would be printed joined up anyway.)

MySQL takes a few seconds to accept connections on a first run. If the
containers already exist but are stopped:

  docker start $(LIVE_MYSQL_CONTAINER) $(LIVE_MONGO_CONTAINER)

To throw them away afterwards:

  docker rm -f $(LIVE_MYSQL_CONTAINER) $(LIVE_MONGO_CONTAINER)

Both are disposable. Every test that touches them creates its own fixture
(the MySQL ones DROP and CREATE `customers`; the Mongo ones drop and
re-seed their collections), so there is no schema to preserve, nothing to
restore, and no reason to point this at a database you care about.

To use an engine you manage instead, override both and the Docker
preflight steps aside:

  make test-live LIVE_MYSQL_DSN='user:pw@tcp(host:3306)/db' LIVE_MONGO_URI='mongodb://host:27017/db'

The Mongo URI MUST carry a database name in its path.
endef
export LIVE_SETUP_HELP

.PHONY: test-live
test-live:
ifneq ($(LIVE_DEFAULTS),)
	@command -v docker >/dev/null 2>&1 || { \
		echo "test-live: docker is not on PATH."; echo; \
		echo "$$LIVE_SETUP_HELP"; exit 1; }
	@for c in $(LIVE_MYSQL_CONTAINER) $(LIVE_MONGO_CONTAINER); do \
		state=$$(docker inspect -f '{{.State.Running}}' $$c 2>/dev/null); \
		if [ "$$state" != "true" ]; then \
			echo "test-live: container $$c is not running (state: $${state:-absent})."; \
			echo; echo "$$LIVE_SETUP_HELP"; exit 1; \
		fi; \
	done
	@echo "  preflight ok: $(LIVE_MYSQL_CONTAINER), $(LIVE_MONGO_CONTAINER) running"
else
	@echo "  preflight skipped: connection details were overridden"
endif
	@echo "  WAKIL_MYSQL_DSN=$(LIVE_MYSQL_DSN)"
	@echo "  WAKIL_MONGO_URI=$(LIVE_MONGO_URI)"
	@out=$$(WAKIL_MYSQL_DSN='$(LIVE_MYSQL_DSN)' WAKIL_MONGO_URI='$(LIVE_MONGO_URI)' \
		$(LIVE_CONTAINER_ENV) \
		go test ./internal/wakilcore/ -count=1 -v -run '$(LIVE_TESTS)' 2>&1); \
	status=$$?; \
	printf '%s\n' "$$out"; \
	if [ $$status -ne 0 ]; then exit $$status; fi; \
	skipped=$$(printf '%s\n' "$$out" | grep -c -- '--- SKIP' || true); \
	if [ "$$skipped" -ne 0 ]; then \
		echo; \
		echo "test-live: $$skipped engine-backed test(s) SKIPPED, so nothing was proved."; \
		echo "A skip here means the environment variables did not reach the tests."; \
		echo; echo "$$LIVE_SETUP_HELP"; \
		exit 1; \
	fi; \
	echo; echo "test-live: all selected tests ran, none skipped."

# ---------------------------------------------------------------------
# e2e — the checks that drive the shipped bundle
# ---------------------------------------------------------------------
#
# WHICH CHECKS. `make e2e` runs the checks the branch's diff reaches —
# changed check files, the checks that press an identifier a changed file
# declares, the checks that dispatch an action a changed file spells — plus
# the org-plane check, and lists the changed files no check reaches
# (wakil-e2e-select; record in .context/e2e/select/latest.json). `make
# e2e-full` runs every check, once per branch, on the head that merges.
#
# Deliberately NOT part of `make test`, for the same reason `test-live` is
# not: the default suite must stay runnable with nothing installed but Go,
# and this one needs a GUI session, a built bundle and the Orca CLI. It is a
# different contract.
#
# The library under e2e/driver IS in `make test`, and must stay there. It
# holds the guards — a run that executed no check, a check that asserted
# nothing, a reply that did not parse, an action whose effect was never read
# back — and those are the last things that should be hidden behind a
# GUI-only target. The design proposed putting all of e2e/ behind a build
# tag; making the live half a program instead keeps the guards testable.
#
# `make test-live`'s lesson applies in a worse form here. `go test` reports a
# skipped test as ok, which is how a live target with no engines running
# "passed" and certified nothing; a GUI check that resolved a stale index,
# found nothing and asserted nothing also exits 0. So the runner fails when
# zero checks ran and when checks asserted nothing, and every unusable reply
# is a recorded failure rather than an assertion that quietly did not happen.
#
# WHAT A RUN DOES TO YOUR SESSION. It launches a SECOND Wakil, addressed by
# pid and never by bundle id — with two instances running, bundle-id
# addressing silently returns one of them, and the wrong one would be driven
# with the operator's live credentials. The instance has its own HOME, its
# own TMPDIR and its own Keychain, reached through a `security` shim on its
# own PATH; teardown identifies it by reading HOME back out of `ps`, never by
# process name. Reads and `set-value` do not take the foreground. Clicks do,
# so once the checks include them, start this when you are away from the
# machine. See docs/wakil/agent-e2e-probe.md.
#
# ONE LAUNCH PER CHECK FILE, and that is a rule rather than a default.
#
# Two things force it. The first is the fixture state: an instance either has a
# seeded org open or it does not, and the two want opposite assertions —
# e2e/checks/unseeded asserts the organisation plane, e2e/checks/seeded asserts
# what is behind it — so one launch cannot satisfy both.
#
# The second is stronger and was learnt writing 2c-iii's seven checks (#253):
# checks that share an instance couple through its state, and the coupling is
# INVISIBLE in the check files. `vocabulary.jsonl` addresses `terminal-1` and
# `terminal-2`, which are those ids only because nothing before it opened a
# pane; the organisation-switch check closes every pane on the canvas and
# leaves a different org open. Run together, the order of the files becomes
# part of the meaning of each of them, and nothing in a file says so.
#
# The cost is one launch each — a handful of seconds — and what it buys is that
# a check file is a statement about the app rather than about its position in a
# sequence.
#
# The loop stops at the first failure and names the file that failed, so a red
# run points at a check rather than at a compound exit status. A pass whose
# whole directory was empty still fails loudly on its own: the runner refuses a
# run in which zero checks ran, and a glob that matched nothing expands to
# itself and is refused as a path that is not there.
E2E_BUNDLE ?= app/Wakil.app
E2E_UNSEEDED ?= e2e/checks/unseeded/*.jsonl
E2E_SEEDED ?= e2e/checks/seeded/*.jsonl
# **A third fixture state.** The agent checks want a provider record naming the
# scripted agent; the others want one naming no binary at all, which is the
# state every check before #255 was written against. One launch cannot be both,
# for the reason the seeded/unseeded split already gives.
#
# THEY ARE STILL NOT IN `make e2e`, and #284 sharpened the reason without
# removing it. The old wording said "the Send button is pressed,
# `WindowModel.send` is entered, and no agent process is spawned". The middle
# clause was never measured and is probably wrong: every failing path in `send`
# writes `status`, and the failing runs have none, so the window suspends
# somewhere before the first of them — `await enterConversation()` is the only
# thing that runs earlier.
#
# **It is not rare on a machine that is short of disk.** Measured 2026-09-24:
# 20-odd consecutive green runs while the volume had room, then 6/6 failures
# once it was at 97% — reproduced with this branch's app and harness stashed,
# so it is neither. That is the first lever anyone has had on it, and it is
# also why these checks would make `make e2e` red for a reason that is not the
# branch's, which is how a gate gets switched off.
#
# **What changed is that the red now names itself.** A launch that seeded an
# agent and never ran one is a FATAL fault citing this issue
# (`Session.agentNeverRan`) rather than an assertion failure that reads like
# the branch's work. The two defects that used to make these fail on their own
# account — a rail click that restored no keyboard, and a `do.type` that never
# reached the binding — are fixed.
#
# **AND THEY ARE IN `make e2e` SINCE 2026-09-25.** Both reasons they were held
# out are now preconditions rather than red runs:
#
#   - The full disk above is `RefuseIfDiskIsTight`, which measures before it
#     stages anything and names the disk. A run that refuses up front is not
#     red for the branch's reason; it is not red at all.
#   - The intermittent failure (#284) was the harness's own actuation tool
#     taking the foreground and receiving its own keystrokes. `Runner.act`
#     brings the fixture forward before each act now. Measured: 0 failures in
#     23 runs under deliberate load, where the same check failed 1 in 12
#     before, and 37 of 37 idle.
#
# They are the most expensive launch, so they run LAST — after the cheaper
# states have had their chance to say the bundle is unusable.
E2E_AGENT ?= e2e/checks/agent/*.jsonl

# E2E_SETTLE overrides how long an assertion waits for its predicate, for every
# target that runs checks. Empty means each launch chooses its own — three
# seconds, or twenty when it carries the agent. `make e2e E2E_SETTLE=-1s` asks
# for no waiting at all, which is how #284 showed a flake was latency rather
# than a defect.
E2E_SETTLE ?=
E2E_SETTLE_ARG = $(if $(E2E_SETTLE),--settle $(E2E_SETTLE),)

# THE COVERAGE STEP RUNS EVEN WHEN A CHECK FAILED, and the target still fails.
# The checks stop at the first red file, as they always did — a red run points
# at a check rather than at a compound exit status — but coverage is computed
# from the check FILES and the actions the launch already observed, neither of
# which a failing assertion changes. Skipping it would mean a branch that adds
# uncovered surface AND breaks a check is told about the second and never about
# the first, which is the half it cannot see for itself.
# E2E_ONLY runs exactly the named checks instead of the selection, e.g.
# `make e2e E2E_ONLY='e2e/checks/seeded/git-*.jsonl'`.
E2E_ONLY ?=

# E2E_QUARANTINE names known-red checks by file base name, comma-separated, e.g.
# `make e2e-full E2E_QUARANTINE=api-unbind.jsonl,project-root-note.jsonl`. Each is
# handed to wakil-e2e's `--quarantine` on its own file only — one launch per
# file, and the runner refuses a name that is not among the checks it runs — and
# is reported on every run, never retried. A name no selected file carries fails
# the run before any launch: a stale entry would hide a check nobody runs.
E2E_QUARANTINE ?=

e2e: app-bundle axresolve e2e-agent
	@files=$$(go run ./e2e/cmd/wakil-e2e-select --trunk "$(E2E_TRUNK)" \
	    $(if $(E2E_ONLY),--only $(E2E_ONLY),)) || exit 1; \
	$(MAKE) --no-print-directory e2e-run E2E_FILES="$$(echo $$files)"

# e2e-full — every check, once per branch, on the head that merges. Unattended:
# it holds the screen for the whole suite (~22 min at 127 files).
e2e-full: app-bundle axresolve e2e-agent
	@files=$$(go run ./e2e/cmd/wakil-e2e-select --full \
	    $(E2E_UNSEEDED) $(E2E_SEEDED) $(E2E_AGENT)) || exit 1; \
	$(MAKE) --no-print-directory e2e-run E2E_FILES="$$(echo $$files)"

# e2e-run — the one loop both targets share. The launch comes from the
# directory, as it always has.
#
# The checks stop at the first red file unless E2E_KEEP_GOING is set. The night
# run (e2e/cmd/wakil-e2e-night) sets it, so one night finds every red file
# rather than the first. E2E_RUNNER is the driver, replaceable only so the
# loop itself can be tested (scripts/makefile_test.go).
E2E_KEEP_GOING ?=
E2E_RUNNER ?= go run ./e2e/cmd/wakil-e2e
e2e-run:
	@test -d "$(E2E_BUNDLE)" || { \
	    echo "make e2e: no bundle at $(E2E_BUNDLE) — run \`make app-bundle\`"; exit 1; }
	@for name in $$(echo "$(E2E_QUARANTINE)" | tr ',' ' '); do \
	    case " $$(for f in $(E2E_FILES); do printf '%s ' "$${f##*/}"; done)" in \
	        *" $$name "*) ;; \
	        *) echo "make e2e: E2E_QUARANTINE names $$name, which is not among the checks being run"; exit 1;; \
	    esac; \
	done
	@status=0; \
	for check in $(E2E_FILES); do \
	    case $$check in \
	        e2e/checks/unseeded/*) flags="--no-seed"; label="organisation plane";; \
	        e2e/checks/agent/*) flags="--agent on"; label="seeded, scripted agent";; \
	        *) flags=""; label="seeded";; \
	    esac; \
	    case ",$(E2E_QUARANTINE)," in \
	        *",$${check##*/},"*) flags="$$flags --quarantine $${check##*/}"; label="$$label, quarantined";; \
	    esac; \
	    echo "== $$check ($$label)"; \
	    $(E2E_RUNNER) --bundle "$(E2E_BUNDLE)" $$flags $(E2E_SETTLE_ARG) "$$check" \
	        || { status=1; [ -n "$(E2E_KEEP_GOING)" ] || break; }; \
	done; \
	echo "== coverage"; \
	$(MAKE) --no-print-directory e2e-cover || status=1; \
	exit $$status

# ---------------------------------------------------------------------
# e2e-cover — newly added surface without a check is red
# ---------------------------------------------------------------------
#
# The standing audit (design §2). It measures the checks against the two
# denominators the app itself supplies and fails when surface THIS BRANCH ADDED
# has nothing pointed at it.
#
# THE TWO DENOMINATORS, AND WHY NEITHER IS READ OFF THE SOURCE.
#
#   - Actions: `tools/list` on a live window. `ActionRegistry`'s own doc comment
#     calls its description "the only way to enumerate registered actions from
#     outside this actor", and MCPServer projects every one onto a tool — so the
#     running app is the only thing that knows, and a count grepped out of six
#     registrar files would be a second answer that drifts. The action's KIND
#     travels the same way, as `annotations.readOnlyHint` (#256), which is what
#     the parity rule below is stated in.
#   - Controls: every `.accessibilityIdentifier` under app/Sources/WakilApp,
#     harvested by `make controls`' own reader.
#
# THE THREE RULES. Every action is dispatched by at least one check; every
# action that WRITES is driven down both channels by a parity check, which is
# Invariant 2 executed rather than asserted; every identifier is pressed by at
# least one check.
#
# ONLY NEWLY ADDED SURFACE FAILS. Surface that predates the branch is the
# discovery audit's backlog — `make e2e-backlog` below. A gate demanding the
# whole registry on day one would be switched off within a week, which is how
# the north-star's first word limit failed. "New" is measured against the
# MERGE-BASE, never origin/main's tip, for `make e2e-new`'s reason: a branch
# whose trunk has moved on must not be asked for checks covering somebody
# else's actions.
#
# NO GUI AND NO SECOND LAUNCH. Every `make e2e` launch already asks `tools/list`
# before its first check, and records what it heard in
# .context/e2e/actions.json. This reads that, and REFUSES a record observed
# against another commit — measured against an older build the gate cannot see
# the action this branch just added, and would pass by being blind.
#
# So it needs a `make e2e` to have run, which is why `e2e` runs it last rather
# than this depending on anything: run alone on a stale tree it says so and
# names the target that fixes it.
e2e-cover:
	go run ./e2e/cmd/wakil-e2e-cover $(E2E_COVER_ARGS)

# ---------------------------------------------------------------------
# e2e-backlog — the discovery audit, which is a list and never a gate
# ---------------------------------------------------------------------
#
# Design §9.3: on demand, independent of any diff, every action and every
# control no check touches at all. Its output is work to be scheduled, not a
# build to be failed — a list this long that turned a build red would be
# switched off the same afternoon, and then nobody would have the list either.
#
# It reads the same denominators and the same coverage as the gate, through the
# same computation, so the backlog can never disagree with what the gate
# enforces.
e2e-backlog:
	go run ./e2e/cmd/wakil-e2e-cover --all $(E2E_COVER_ARGS)

# ---------------------------------------------------------------------
# e2e-new — a check that has never failed is not evidence
# ---------------------------------------------------------------------
#
# Runs ONLY the checks this branch added or changed, against a bundle built
# from the MERGE-BASE, and requires every one of them to go red. A check that
# passes against the code from before the work is not testing the work.
#
# This is `make test-live`'s lesson in its nastiest form. That target exists
# because `go test` reports a skipped test as ok, so a live target with no
# containers running passed cleanly and certified nothing — and at least a
# skip is PRINTED. A GUI check that resolved a stale index, found nothing and
# asserted nothing exits 0 with nothing anywhere saying so.
#
# WHY THIS AND NOT SOURCE MUTATION. Mutation needs a rebuild per check. This
# needs one extra bundle build per branch, no new machinery, and it is the
# Build rung's existing test-first discipline (mattpocock-skills:tdd) applied
# to the GUI.
#
# THE MERGE-BASE, NEVER origin/main's TIP. A branch whose trunk has moved on
# would otherwise be proved against code it was never written against: a check
# could go red on somebody else's change, which is the exact false evidence
# this target exists to refuse.
#
# WHAT IT BUILDS, AND WHERE. A detached worktree per commit under
# .context/e2e/bundles/<sha>, with `make app-bundle` run inside it. Keyed by
# the commit, so a cache hit can never be a different tree, and reused across
# runs — which is what makes #253's seven historical builds affordable.
#
# Depends on `axresolve` and NOT on `app-bundle`: the harness is this
# branch's, the app is the merge-base's, and that asymmetry is the whole
# point. It does not depend on `build` either, because the bundle it drives is
# built inside the base worktree from the base's own bin/.
#
# WHAT IT LEAVES. .context/e2e/new/<run>/verdict.json, and latest.json beside
# it — which check went red, which did not, and the reason in each case. That
# record is what the Cover rung reads; a reader has to be able to tell a check
# that failed on its own assertion from one that failed because the harness
# could not reach the window, because the second is red against anything.
#
# A branch that added no checks exits 0 and records that it proved nothing.
# Whether it OWED a check is the coverage gate's question, not this one's.
E2E_TRUNK ?= origin/main

# Depends on `e2e-agent` as well as `axresolve` since #284: a branch that
# changed a check under `e2e/checks/agent/` launches the scripted agent against
# the merge-base bundle, and `ResolveAgentStub` refuses the whole run when
# `e2e/bin/wakil-e2e-agent` is missing — the ordinary state of a fresh clone.
# Discovering that AFTER a five-minute bundle build is the cost this dependency
# avoids, and it is the same reason both tools are resolved before the build.
e2e-new: axresolve e2e-agent
	go run ./e2e/cmd/wakil-e2e-new --trunk "$(E2E_TRUNK)" $(E2E_NEW_ARGS)

# ---------------------------------------------------------------------
# e2e-night — the full suite on main, once a night
# ---------------------------------------------------------------------
#
# A launchd job runs `make e2e-full` on origin/main between 23:00 and 07:00
# when main has moved since the last green night, fixes what went red on
# e2e-night/<date> (local commits, never pushed) and re-runs it. It replaces
# a pre-merge e2e-full. Install once, from a checkout of main; read the
# morning's result from any worktree. See e2e/cmd/wakil-e2e-night.
e2e-night-install:
	go run ./e2e/cmd/wakil-e2e-night install

e2e-night-status:
	@go run ./e2e/cmd/wakil-e2e-night status

# ---------------------------------------------------------------------
# e2e-runbook — the machine half of an acceptance runbook, rendered
# ---------------------------------------------------------------------
#
# The Cover rung (docs/agents/workflow.md) in one section: every check ran
# green against THIS build, every check the branch added was seen to fail
# against the merge-base, and the surface it added carries checks. It is
# rendered from the records the runs already left — .context/e2e/runs/,
# .context/e2e/new/latest.json, .context/e2e/actions.json — and never typed.
#
# WHY IT IS GENERATED AND NOT WRITTEN. The Walk rung keeps its "Never an
# agent" because an agent must not declare its own work good. The machine half
# is trusted anyway, on the strength of `make e2e-new`: a check that has been
# seen to fail is evidence no matter who ran it. That argument holds for the
# RECORDS and not for a prose summary of them, so the summary is computed from
# the records rather than composed beside them.
#
# WHAT IT LEAVES. With E2E_RUNBOOK set, the named acceptance document, spliced
# between its two machine-walk markers and nothing else touched. Without it,
# the section on stdout. A document with no markers is REFUSED and prints the
# two lines to paste: where the section belongs in a runbook is a judgement
# about that runbook, and a generator that picked a place would be editing
# prose it does not understand.
#
# NO GUI AND NO LAUNCH, and it exits non-zero when the rung is not turned —
# so a red walk still renders, says so in the document, and fails the command.
E2E_RUNBOOK ?=

e2e-runbook:
	go run ./e2e/cmd/wakil-e2e-runbook \
	    --trunk "$(E2E_TRUNK)" \
	    $(if $(E2E_RUNBOOK),--into "$(E2E_RUNBOOK)",) $(E2E_RUNBOOK_ARGS)

# ---------------------------------------------------------------------
# e2e-retrodict — can this harness see the defects it was built for?
# ---------------------------------------------------------------------
#
# THE ACCEPTANCE CRITERION FOR THE WHOLE HARNESS (#253). 2c-iii's walk found
# twenty-one defects, every one in WakilApp or its seam with WakilKit. A
# harness that catches the mechanizable ones is proven; one that cannot is
# not, and that verdict lands before any effort goes into the agent stub and
# beyond.
#
# THE BUILDS THAT CARRIED THEM DO NOT EXIST. 2c-iii was squash-merged
# (84de6f6), so the branch's own commits are gone from every ref. Running the
# seven checks against 3bc0d1f — the commit before the terminal pane — makes
# all seven go red, and proves nothing: every one dies at the same step, on the
# same identifier #250 added three days ago.
#
# So each defect is put BACK. A patch under e2e/retrodiction/ removes one line
# whose absence the repo itself records as having caused the defect, the bundle
# is rebuilt with it, and the check that covers it must go red.
#
# THIS IS SOURCE MUTATION, WHICH e2e-new DELIBERATELY REJECTED, and the
# difference is the point: e2e-new is a standing gate on every branch, where a
# rebuild per check is unaffordable. This runs when the harness itself is in
# question, and nothing else can answer that question.
#
# It rebuilds the bundle once per case in a worktree of its own
# (.context/e2e/retrodiction-tree), incrementally, and leaves that tree clean —
# a worktree carrying a defect patch is a broken Wakil on disk under a name
# that does not say so.
#
# The verdict lands in .context/e2e/retrodiction/latest.json and is written up
# in docs/wakil/agent-e2e-retrodiction.md.
e2e-retrodict: axresolve
	go run ./e2e/cmd/wakil-e2e-retrodict $(E2E_RETRODICT_ARGS)

# The control denominator, listed — every `.accessibilityIdentifier` the
# audited sources carry, and the gate's verdict on them.
#
# **No GUI, no bundle, no Orca**: both halves read Swift source, which is why
# this is not part of `e2e` above and does not cost a launch.
#
# **The gate is not enforced here.** It runs inside `make test`
# (TestEveryAuditedControlIsNamed), because a rule that only a target nobody
# runs enforces is not enforced. This target answers the other question — what
# is actually IN the set — which a passing test does not.
#
# A surface joins the gate by being added to `driver.AuditedSources`, in the
# same change that names its controls. That is deliberate: a gate that demanded
# the whole tree on day one would be switched off within a week.
controls:
	go run ./e2e/cmd/wakil-controls

# The read-only accessibility resolver the e2e driver resolves identifiers
# with. It presses nothing; all actuation stays in Orca.
#
# **It exists because `orca computer get-app-state` emits no identifiers** —
# for a button its formatter prints AXTitle or AXValue and nothing else, under
# any flag. Measured 2026-09-23, docs/wakil/agent-e2e-probe.md §4b.
#
# Built with `swiftc` rather than through SwiftPM: it is 200 lines with no
# dependencies beyond ApplicationServices, and adding a target to app/ would
# put a test helper in the package `make app-bundle` builds the shipped app
# from. It lands in e2e/bin for the same reason it is not in bin/ — that
# directory's contents are copied into Wakil.app.
#
# **It needs the Accessibility grant**, inherited from whatever runs it. A
# revoked grant is reported as `accessibility_denied` and never as an
# identifier that could not be found, because those send a reader to opposite
# places.
# ---------------------------------------------------------------------
# e2e-agent — the deterministic agent behind the fixture's provider record
# ---------------------------------------------------------------------
#
# Stands in for `claude` on the checks that drive the agent (#255). It speaks
# the stream-json protocol the window already parses, and reaches the window
# through the socket named in the --mcp-config the window itself generated.
#
# SEEDED ONTO THE PROVIDER RECORD, NEVER ONTO PATH. `executableURL` does not
# search PATH, and #238's rule is that the resolved binary travels on the
# provider row as "the only absolute path the app has". So a check that drives
# this runs the production resolution path — listing, row, credentials,
# buildLaunch — and an unwired dependency still fails it.
#
# NOT `ANTHROPIC_BASE_URL`, which is what the ticket proposed. `buildLaunch`
# builds the child environment from a whitelist of four keys, and that is what
# makes ANTHROPIC_API_KEY unable to shadow a subscription BY CONSTRUCTION
# (Decision 16). Routing a stub that way needs the baseURL/authToken fallback
# Decision 16 deliberately leaves unbuilt; widening the whitelist for a test
# would spend a property the charter relies on.
#
# In e2e/bin for axresolve's reason: bin/ is what `make app-bundle` copies into
# Wakil.app, and a stand-in for the agent has no business shipping in it.
e2e-agent: e2e/bin/wakil-e2e-agent

# The agent checks on their own, for iterating on one without paying for the
# other ten. `make e2e` runs them too — see E2E_AGENT above.
e2e-agent-checks: app-bundle axresolve e2e-agent
	@status=0; \
	for check in $(E2E_AGENT); do \
	    echo "== $$check (seeded, scripted agent)"; \
	    go run ./e2e/cmd/wakil-e2e --bundle "$(E2E_BUNDLE)" --agent on $(E2E_SETTLE_ARG) "$$check" \
	        || { status=1; break; }; \
	done; \
	exit $$status

e2e/bin/wakil-e2e-agent: e2e/stub/main.go e2e/driver/agentscript.go
	@mkdir -p e2e/bin
	go build -o $@ ./e2e/stub

axresolve: e2e/bin/axresolve

e2e/bin/axresolve: e2e/axresolve/main.swift
	@mkdir -p e2e/bin
	swiftc -O -o $@ $<

vet:
	go vet ./...

# Reports rather than rewrites: `make fmt` in CI or in a review should not
# quietly change the tree it is checking. Run `gofmt -w` yourself.
fmt:
	@out=$$(gofmt -l .); \
	if [ -n "$$out" ]; then echo "not gofmt-clean:"; echo "$$out"; exit 1; fi; \
	echo "gofmt clean"

# Removes only the binaries this Makefile creates, not the whole bin/
# directory, so anything else an operator has parked there survives.
clean:
	@for b in $(BINS); do rm -f bin/$$b; done
	@rm -rf e2e/bin
	@echo "removed: $(BINS), e2e/bin"

# The Metal compiler is not part of SwiftPM: declaring a .metal file as a
# resource copies the source into the bundle and compiles nothing, and
# makeDefaultLibrary then fails at runtime with "no default library was
# found" (docs/wakil/phase-2b-probe.md §2). So the shaders are compiled
# here, ahead of `swift build`, which also makes a broken shader a build
# failure rather than a crash the first time a window opens.
#
# Requires the separately-downloaded Metal Toolchain — Xcode alone is not
# enough. See operator-todo.md, "Phase 2b toolchain".
#
# Final review Finding 2 (2026-09-09), corrected in the whole-branch review:
# with one `.metal` file named on the invocation, dropping it fails the
# `xcrun metal` compile outright — there is no source left to build, so a
# half-populated metallib from a half-dropped file list cannot happen since
# 2b-iv collapsed to a single shader. What the symbol check still earns its
# keep against is a *renamed* function: `Void.metal` compiles cleanly no
# matter what its vertex or fragment function is called, so a rename of
# `void_vertex` or `void_fragment` — by hand, or by a future edit that
# forgets a call site — would otherwise produce a `default.metallib` that
# exists and loads, just exporting the wrong name. `VoidView` fails loudly
# and names the fix when that happens (rather than crashing on Metal's
# generic "vertex function not found"), but the better fix is to make the
# broken build impossible to ship at all: `xcrun metal-nm` lists every
# function symbol a compiled `.metallib` exports, so this checks the two
# this app actually calls by name are present and fails the build here, at
# `make shaders` time, if not.
shaders:
	xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal
	@symbols="$$(xcrun metal-nm app/Sources/WakilApp/default.metallib)"; \
	for fn in void_vertex void_fragment; do \
	    echo "$$symbols" | grep -q " T $$fn$$" || { \
	        echo "make shaders: default.metallib is missing function '$$fn' — check the .metal file is still named above"; \
	        exit 1; \
	    }; \
	done

app-build: shaders
	cd app && swift build

# Depends on `shaders` too: once default.metallib is a `.copy` resource on
# the WakilApp target, SwiftPM cannot even load the package graph without
# it present, and `swift test` loads that same graph — so a clean tree
# would fail `app-test` on a file the tests never read.
#
# Quiet by default: failures, crashes and the summary on screen, every line
# in .context/app-test.log. A passing run is ~3,000 lines, almost all of them
# "started" and "passed", and an agent re-reads whatever it runs on every turn
# after — see scripts/quiet-test.sh. `VERBOSE=1 make app-test` prints it all.
app-test: shaders
	cd app && ../scripts/quiet-test.sh $(CURDIR)/.context/app-test.log -- ../scripts/swift-test.sh

# Depends on `build` because the bundle is only useful if the five Go
# binaries it copies out of bin/ are there: WakilWiring.binaryURL has no
# fallback once it is running from a bundle, so a Wakil.app assembled from a
# stale or empty bin/ finds nothing at all. The Swift side is built by the
# script itself, which needs to do it anyway to know where the product is.
# Depends on `shaders` for the same reason `app-test` does, one comment
# above: make-app-bundle.sh runs `swift build`, and default.metallib is a
# `.copy` resource on the WakilApp target, so SwiftPM cannot load the
# package graph without it. On a clean worktree this target used to fail
# with "couldn't build ... default.metallib because of missing inputs" —
# 2c-ii-b walk defect D6. `app-build` and `app-test` both already declared
# it; this one was the only path into `swift build` that did not, which is
# why the gap survived: anyone who had run the tests first never saw it.
app-bundle: build shaders
	@bash scripts/make-app-bundle.sh debug

# Writes one PNG per room state and per environment into .context/, and
# prints GPU frame cost against the 8.33ms budget. Not a pixel-diff gate —
# see the 2b-ii spec §11.
captures: app-build
	mkdir -p .context/2b-iv
	cd app && swift run WakilApp --capture ../.context/2b-iv

# One frame sequence per state, at that state's own resting frame rate.
# What the spec's §10 checks 1-3 are judged against — whether four states are
# distinguishable in motion, and whether a room in motion reads as calm.
# Stills cannot answer either (void-as-core-probe.md §6).
captures-motion: app-build
	mkdir -p .context/2b-iv/motion
	cd app && swift run WakilApp --capture-motion ../.context/2b-iv/motion

# Hosts the data surface offscreen over 50,000 rows and prints what a scroll
# step costs against the 8.33ms budget. Read, not asserted on — the 2b-ii
# spec §11 gives the reasoning, and a wall-clock assertion would be disabled
# within a week of a toolchain update.
#
# It exists because the Grid this replaced shipped in 2b-ii missing the
# budget on 300 steps out of 300 at 5,000 rows, with a 5.3-second first
# layout, and nothing anywhere said so. See docs/wakil/phase-2c-i-probe.md.
bench-surface: app-build
	cd app && swift run -c release WakilApp --bench-surface 50000
