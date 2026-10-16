# Phase 2c-ii acceptance — the DB pane in full

**Status:** **Walked three times on 2026-09-13** — twice for check 11, then all fourteen
checks after the fix round. **Thirteen defects found; twelve fixed.** D1 is deliberately
unfixed and the fix round's spec §13 says why.

The third walk passed twelve of fourteen checks, including the two that had made this phase
not-met: the agent now draws a pane when asked a second time instead of declining, and it
expresses a two-column sort through `pane_sort` instead of escaping into raw SQL. It found
one new defect (D13) and could not exercise one check at all (§7 explains why, and why that
is acceptable).

§5 records every defect with the commits that closed it. §7 gives the verdict.

## 1. Scope — what is under test, and what is not

Everything below is a consumer of **one mechanism**: a `db` pane owns its query. §14's
exit criterion states the whole surface this runbook holds to:

> A `db` pane shows its own query and its own database, editable in place. Return re-runs it;
> ‹ › page through a result larger than the cap without a round trip through the agent, and
> the footer says which rows are on screen and whether more remain. A sort on a paged result
> re-queries and the footer stops apologising. The schema is browsed as rows on the same
> surface, and a table drills into a query in a new pane. An agent refining a query names
> the pane and the pane updates; an agent asking a different question names none and a pane
> opens. A restored pane comes back showing rows. An `UPDATE` typed into the query line
> reaches the confirmation plane. Every one of those is reachable by pointer and by action,
> and journals identically.

**Two things were added to this row during brainstorming, and are under test here
because of it** (spec §0): the query line routes a mutation to 2b-iii's confirmation
plane by asking `classify_statement` before it runs anything, rather than running and
catching a refusal; and the routing default inverted — naming a pane refines it, omitting
one opens a new pane. Check 14 exists because of the second.

**Not under test here:**

- 2c-iii (terminal pane), 2c-iv (API client pane) and 2c-v (session browser) — different
  sub-phases, no code for them exists yet.
- **Select by key** (spec §15) — `Column.Key` is declared and no driver has ever set it;
  before `pane_select_by_key` can exist, `Describe` has to learn keyness per dialect.
  Nothing here changes that.
- **Keyset paging** (spec §15) — impossible over a raw-SQL surface, and not attempted.
- **Several scrolling grids at once, over an animating Metal layer** (spec §15). Opening a
  pane per question by default makes two or three panes the ordinary case rather than the
  unusual one, and `make bench-surface` (§3) measures exactly one surface. This runbook
  does not add a multi-pane rendering check to compensate; it is recorded here as
  unmeasured, again, on purpose.
- **Accessibility parity** — inherited from 2c-i and 2b-ii, unchanged.

### 1.1 Prerequisites

Skipping one of these does not make a check fail cleanly — it makes it fail for the
wrong reason, which is worse than not running it.

1. **`make build`, first.** `bin/` is per-worktree; a worktree that never ran it fails
   for want of a binary rather than for want of a feature. `make build` writes **six**
   binaries into `bin/` — `wakil`, `wakil-ctx`, `wakil-db`, `wakil-http`, `wakil-pm`,
   `wakil-recall` — not five; a plan document elsewhere in this tree still says "five" and
   is wrong.
2. **`make app-bundle`**, so the running app carries the CLI binaries into
   `Contents/Resources`, per every prior 2b/2c runbook.
3. **An org, a project, and an environment with a database registered.** Check 3
   specifically needs **an environment defining two databases**, so the query line has
   something to name. Check 11 specifically needs **`production`**, with several `db`
   panes open across different subjects before quitting.
4. **The 1,006-row table from 2c-i's walk**, still reachable — checks 4 and 12 page and
   persist against it.
5. **A table larger than 5,000 rows**, for check 7 — the query must carry its own
   `LIMIT 5000` and still be large enough that the limit, not the table, is what bounds it.
6. **A Mongo database holding at least one collection with at least one document.**
   2c-i's walk found the acceptance environment's Mongo `docs` database entirely empty
   (`phase-2c-i-acceptance.md`, check 13); check 9 here needs a real collection to list and
   a real document to drill into, on Mongo specifically — `.table` exists as its own
   subject precisely because a composed `SELECT` would fail there.
7. **The launch command**, per `phase-2a-acceptance.md` §1:
   `WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil`.
8. **A way to ask the agent to act, by voice or by typing.** Check 14 must be run the way
   it is described — spoken or typed at the agent — not driven by hand and then described
   as if it had been.
9. **The journal**, for check 13 — know where it lives (`~/.wakil`) and how to read
   `origin` off an entry before starting, not while hunting for it mid-check.
10. **A real, onscreen, key window, with two `db` panes open**, for check 2. The probe
    that recommended plain Return (`phase-2c-ii-probe.md` §3) could not reach a key
    window — its window was offscreen and never became key, so ⌘↩ arrived through an
    explicit `performKeyEquivalent` rather than through `NSApplication.sendEvent`. This
    check is what closes that gap; it is not satisfied by an offscreen or background
    window.

## 2. The checks

Nothing here is marked PASS. Each check is written for the operator to walk at the
window; the **Result** row under each is left blank on purpose — a runbook that
pre-fills a result nobody has seen is worse than one that admits it was never run.

### Check 1 — the query line shows the pane's query, and Return runs it

Open a pane, run a query from the agent, read the line. Edit it, press Return, watch the
pane refine rather than a second pane open.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | Line shows the pane's subject, editable, Return runs it. A table subject still reads `events` rather than SQL — D1, recorded and deliberately unfixed (§13 of the fix spec). |

### Check 2 — two panes, and ⌘↩ if you try it

Open two db panes. Type in the second one's line and press Return; confirm the second
pane changed and the first did not. Then press ⌘↩ in the second pane and record what
happens — **the probe could not test this on a real key window** (probe §3), and this is
the check that closes it.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 1) | The second pane changed, the first did not. ⌘↩ runs the pane being typed in — the probe's warning does not reproduce on a real key window. |

### Check 3 — the database is nameable

In an environment with two databases, run a query against the second one from the line.
This is 2c-i's open item; it should now be reachable.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 1) | Ran against `core` and `events` from the line; the database shown in the line follows. |

### Check 4 — paging, both directions

On the 1,006-row table from 2c-i's walk: page forward to the end and back to the start.
Confirm no row is seen twice and none is skipped, and that the footer reads
`rows 501–1,000 · more remain` and then `rows 1,001–1,006 · end`.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | Paged to the end and back, no row repeated or skipped, and a new page now starts at its first row — D4 fixed and re-walked. |

### Check 5 — a sort on page three

Page to the third page of a result, then click a header. The pane must come back **at
page one**, sorted over the whole result.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 1) | Sorting from page three returns to page one, sorted over the whole result. |

### Check 6 — the footer's silence, looked at once more

On a complete sorted result the footer says nothing about the sort and the only
indicator is the ▲/▼ at 9pt. 2c-i recorded that as easy to miss and asked 2c-ii to
decide deliberately; it was decided to leave it. Record whether that still holds now
that a re-query is in play.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | Footer stays silent on a complete sort; one sorted column draws a bare arrow, two draw `▲1`/`▲2`. |

### Check 7 — a partial sort still admits it

Run a query with its own `LIMIT 5000` against a table larger than that, then sort it.
The footer must say "sorted by X within the N returned" — this is the correction the
probe forced and the thing a green suite would not have caught.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 1) | A query carrying its own `LIMIT 5000` still reports the sort as within the returned rows. |

### Check 8 — `SHOW TABLES` from the query line

The page controls must be absent and the footer must say the result cannot be paged,
rather than a control appearing and returning a syntax error.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | `SHOW TABLES` runs, page controls absent, footer says the result cannot be paged. D2 fixed: drillability is now declared by the driver. **See §7 — the MySQL drill is accepted on the operator's authority, not walked.** |

### Check 9 — the schema, as rows, and the drill

List the tables; the pane draws them. Hover a row and open it; a **new** pane appears
beside the list, showing that table. Do it on Mongo too — this is the case `.table`
exists for, and a composed `SELECT` would fail there.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | Schema lists as rows, the drill opens a table into a new pane, Mongo included, and the `open` button clears the scrollbar — D6 fixed and re-walked. |

### Check 10 — a mutation from the query line

Type an `UPDATE` and press Return: the confirmation plane must rise. Confirm one; cancel
another. In both cases the pane's rows and its query must be untouched. Then type a
`DROP` and confirm the gate's own sentence appears and nothing runs.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | Gate refusal, plane, `confirm` and cancel all behave. The pane now re-reads itself after a confirmed mutation (D8b) and a refused statement stays in the line (D7) — both fixed and re-walked. |

### Check 11 — relaunch, several panes, on `production`

Quit with three or four panes showing different things, on `production`, and reopen.
Every pane must come back showing rows. **Record how it felt** — this is the risk spec
§8 and §15 record: launching Wakil now issues queries on its own, and the operator chose
that with the alternative in front of them.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | Walked three times. Relaunch is correct and the agent's own switch now refreshes the window: banner, panes and write gate all follow. D10, D11, D12 fixed and re-walked. |

### Check 12 — relaunch a schema pane and a paged pane

The subject, the page and the sort all persist; confirm a pane that was on page three
comes back on page three.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | A schema pane and a paged pane both came back where they were left, sort included. |

### Check 13 — the journal

Run a query from the line and the same query from the agent. The two entries must differ
in nothing but `origin` — 2a's acceptance check, in its 2c-ii form.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 1) | The same query from the line and from the agent differ only in `origin`. |

### Check 14 — the operator's own flow, driven by voice or by the agent

*"Query table A. Add a filter on id. Add a filter on name. Sort by timestamp. Now query
table B."* The first four must land in one pane; the fifth must open a second. This is
the check the whole routing inversion exists for, and it must be run the way it was
described — spoken or typed at the agent, not by hand.

| Result | Date | Notes |
|---|---|---|
| **Pass** | 2026-09-13 (walk 3) | Filter → filter → sort refined one pane; naming a second table opened a second pane. The agent now expresses a two-column sort through `pane_sort` rather than escaping into raw SQL — D5 fixed and re-walked. |

## 3. Verification — `make bench-surface`, run by the implementer

Not a judgement call — run it and paste the output. Done below, by the implementer,
since it needs no window. **This measures one surface.** Spec §15 notes that §6's
routing opens a pane per question by default, so two or three scrolling grids over an
animating Metal layer is the ordinary case now, not the unusual one — and it remains
unmeasured; this bench is not a substitute for that measurement.

```
$ make bench-surface
xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal
cd app && swift build
[0/1] Planning build
Building for debugging...
[0/4] Copying default.metallib
[1/4] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.12s)
cd app && swift run -c release WakilApp --bench-surface 50000
Building for production...
[0/6] Copying default.metallib
[0/6] Write sources
[3/6] Write swift-version--58304C5D6DBC2206.txt
[5/7] Compiling WakilKit AppWiring.swift
[6/8] Compiling WakilApp AppScene.swift
[6/8] Write Objects.LinkFileList
[7/8] Linking WakilApp
Build of product 'WakilApp' complete! (25.27s)
  rows              50000 at 23pt
  first layout      30.383 ms
  document height   1150000 pt (exact would be 1150000, +0.00%)
  scroll step       median 0.689 ms   p95 2.324 ms   worst 2.963 ms
  over 8.33ms       0 / 300   ok
  deep scroll (worst case, scrollbar dragged length of pane)   median 35.511 ms   p95 39.334 ms   worst 39.823 ms   (probe: ~48ms worst at 50,000 rows)
```

Machine: this worktree's build environment, 2026-09-12. Exit 0. This bench changed no
rendering in this phase and is run to confirm the construction 2c-i shipped is undisturbed
— it measures the one-surface case only, per the note above.

## 4. Verification — the other five commands, confirmed green on this tree

```
$ go clean -testcache && make test
go test ./...
ok  	github.com/yehia-khalil/wakil/cmd/wakil	1.465s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-ctx	0.819s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-db	3.162s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-http	3.507s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-pm	5.751s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-recall	2.342s
ok  	github.com/yehia-khalil/wakil/internal/mcpx	1.894s
?   	github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest	[no test files]
ok  	github.com/yehia-khalil/wakil/internal/wakilcore	17.064s
ok  	github.com/yehia-khalil/wakil/scripts	16.530s
```
Exit 0.

```
$ make vet
go vet ./...
```
Exit 0, silent — no findings.

```
$ make test-live
  preflight ok: wakil-acc-mysql, wakil-acc-mongo running
  WAKIL_MYSQL_DSN=root:rootpw@tcp(127.0.0.1:13306)/wakilacc
  WAKIL_MONGO_URI=mongodb://127.0.0.1:27018/wakilacc
=== RUN   TestMongoReadAndGate
--- PASS: TestMongoReadAndGate (0.01s)
=== RUN   TestMongoTruncation_Find
--- PASS: TestMongoTruncation_Find (0.15s)
=== RUN   TestMongoTruncation_Aggregate
--- PASS: TestMongoTruncation_Aggregate (0.10s)
=== RUN   TestMongoPagingFind
--- PASS: TestMongoPagingFind (0.09s)
=== RUN   TestMongoPagingAggregate
--- PASS: TestMongoPagingAggregate (0.10s)
=== RUN   TestMongoSortAppliesToWholeCollectionThenSkip_Find
--- PASS: TestMongoSortAppliesToWholeCollectionThenSkip_Find (0.10s)
=== RUN   TestMongoSortAppliesToWholeCollectionThenSkip_Aggregate
--- PASS: TestMongoSortAppliesToWholeCollectionThenSkip_Aggregate (0.10s)
=== RUN   TestMongoDescribe
--- PASS: TestMongoDescribe (0.11s)
=== RUN   TestMongoEmptyDatabaseName
--- PASS: TestMongoEmptyDatabaseName (0.00s)
=== RUN   TestMongoConnectRedactsPassword
--- PASS: TestMongoConnectRedactsPassword (0.20s)
=== RUN   TestMongoReadRejectsUnimplementedReadOps
=== RUN   TestMongoReadRejectsUnimplementedReadOps/count
=== RUN   TestMongoReadRejectsUnimplementedReadOps/distinct
--- PASS: TestMongoReadRejectsUnimplementedReadOps (0.00s)
    --- PASS: TestMongoReadRejectsUnimplementedReadOps/count (0.00s)
    --- PASS: TestMongoReadRejectsUnimplementedReadOps/distinct (0.00s)
=== RUN   TestMongoWriteIsNotImplementedRatherThanRefused
--- PASS: TestMongoWriteIsNotImplementedRatherThanRefused (0.00s)
=== RUN   TestMongoConnectWritableIsNotImplemented
--- PASS: TestMongoConnectWritableIsNotImplemented (0.00s)
=== RUN   TestMongoUsesTheSharedCap
--- PASS: TestMongoUsesTheSharedCap (0.00s)
=== RUN   TestMySQLReadAndGate
--- PASS: TestMySQLReadAndGate (0.22s)
=== RUN   TestMySQLEngineLevelReadOnly
    driver_mysql_test.go:102: engine-level read-only rejection: Error 1792 (25006): Cannot execute statement in a READ ONLY transaction.
--- PASS: TestMySQLEngineLevelReadOnly (0.13s)
=== RUN   TestMySQLQuoteIdentAndDescribe
--- PASS: TestMySQLQuoteIdentAndDescribe (0.15s)
=== RUN   TestMySQLConnectRedactsPassword
=== RUN   TestMySQLConnectRedactsPassword/malformed_DSN_carries_no_driver_text
=== RUN   TestMySQLConnectRedactsPassword/unreachable_DSN_redacts_a_password_present_in_the_error
--- PASS: TestMySQLConnectRedactsPassword (0.00s)
    --- PASS: TestMySQLConnectRedactsPassword/malformed_DSN_carries_no_driver_text (0.00s)
    --- PASS: TestMySQLConnectRedactsPassword/unreachable_DSN_redacts_a_password_present_in_the_error (0.00s)
=== RUN   TestHardenMySQLConfigNeutralisesHostileDSN
--- PASS: TestHardenMySQLConfigNeutralisesHostileDSN (0.00s)
=== RUN   TestMySQLSetInjectionCannotDisableReadOnly
--- PASS: TestMySQLSetInjectionCannotDisableReadOnly (0.14s)
=== RUN   TestMySQLDoubleDashOutfileBypassIsBlocked
--- PASS: TestMySQLDoubleDashOutfileBypassIsBlocked (0.12s)
=== RUN   TestMySQLGenuineDoubleDashQueriesStillWork
=== RUN   TestMySQLGenuineDoubleDashQueriesStillWork/genuine_line_comment
=== RUN   TestMySQLGenuineDoubleDashQueriesStillWork/arithmetic_double_minus
=== RUN   TestMySQLGenuineDoubleDashQueriesStillWork/tab_introduces_a_comment
--- PASS: TestMySQLGenuineDoubleDashQueriesStillWork (0.00s)
    --- PASS: TestMySQLGenuineDoubleDashQueriesStillWork/genuine_line_comment (0.00s)
    --- PASS: TestMySQLGenuineDoubleDashQueriesStillWork/arithmetic_double_minus (0.00s)
    --- PASS: TestMySQLGenuineDoubleDashQueriesStillWork/tab_introduces_a_comment (0.00s)
=== RUN   TestMySQLQuoteIdent
=== RUN   TestMySQLQuoteIdent/ordinary_identifier
=== RUN   TestMySQLQuoteIdent/empty_identifier
=== RUN   TestMySQLQuoteIdent/single_embedded_backtick
=== RUN   TestMySQLQuoteIdent/nothing_but_backticks
=== RUN   TestMySQLQuoteIdent/injection_payload
=== RUN   TestMySQLQuoteIdent/NUL_byte_is_passed_through_untouched
=== RUN   TestMySQLQuoteIdent/double_quote_is_not_special_here
--- PASS: TestMySQLQuoteIdent (0.00s)
    --- PASS: TestMySQLQuoteIdent/ordinary_identifier (0.00s)
    --- PASS: TestMySQLQuoteIdent/empty_identifier (0.00s)
    --- PASS: TestMySQLQuoteIdent/single_embedded_backtick (0.00s)
    --- PASS: TestMySQLQuoteIdent/nothing_but_backticks (0.00s)
    --- PASS: TestMySQLQuoteIdent/injection_payload (0.00s)
    --- PASS: TestMySQLQuoteIdent/NUL_byte_is_passed_through_untouched (0.00s)
    --- PASS: TestMySQLQuoteIdent/double_quote_is_not_special_here (0.00s)
=== RUN   TestMySQLCommentIntroducerBypassIsBlocked
=== RUN   TestMySQLCommentIntroducerBypassIsBlocked/block_comment_opened_inside_a_--_comment
=== RUN   TestMySQLCommentIntroducerBypassIsBlocked/block_comment_opened_inside_a_#_comment
=== RUN   TestMySQLCommentIntroducerBypassIsBlocked/escaped_quote_inside_a_literal_re-arming_a_--_comment
--- PASS: TestMySQLCommentIntroducerBypassIsBlocked (0.32s)
    --- PASS: TestMySQLCommentIntroducerBypassIsBlocked/block_comment_opened_inside_a_--_comment (0.10s)
    --- PASS: TestMySQLCommentIntroducerBypassIsBlocked/block_comment_opened_inside_a_#_comment (0.10s)
    --- PASS: TestMySQLCommentIntroducerBypassIsBlocked/escaped_quote_inside_a_literal_re-arming_a_--_comment (0.10s)
=== RUN   TestMySQLCommentHandlingDidNotOverReject
=== RUN   TestMySQLCommentHandlingDidNotOverReject/ordinary_line_comment
=== RUN   TestMySQLCommentHandlingDidNotOverReject/ordinary_block_comment
=== RUN   TestMySQLCommentHandlingDidNotOverReject/literal_containing_a_comment_introducer
=== RUN   TestMySQLCommentHandlingDidNotOverReject/literal_containing_a_block_introducer
=== RUN   TestMySQLCommentHandlingDidNotOverReject/backslash_both_readings_agree_about
--- PASS: TestMySQLCommentHandlingDidNotOverReject (0.00s)
    --- PASS: TestMySQLCommentHandlingDidNotOverReject/ordinary_line_comment (0.00s)
    --- PASS: TestMySQLCommentHandlingDidNotOverReject/ordinary_block_comment (0.00s)
    --- PASS: TestMySQLCommentHandlingDidNotOverReject/literal_containing_a_comment_introducer (0.00s)
    --- PASS: TestMySQLCommentHandlingDidNotOverReject/literal_containing_a_block_introducer (0.00s)
    --- PASS: TestMySQLCommentHandlingDidNotOverReject/backslash_both_readings_agree_about (0.00s)
=== RUN   TestMySQLExecutableCommentCloseBypassIsBlocked
=== RUN   TestMySQLExecutableCommentCloseBypassIsBlocked/versioned_hint
=== RUN   TestMySQLExecutableCommentCloseBypassIsBlocked/unversioned_hint
=== RUN   TestMySQLExecutableCommentCloseBypassIsBlocked/optimizer_hint_shape
--- PASS: TestMySQLExecutableCommentCloseBypassIsBlocked (0.11s)
    --- PASS: TestMySQLExecutableCommentCloseBypassIsBlocked/versioned_hint (0.00s)
    --- PASS: TestMySQLExecutableCommentCloseBypassIsBlocked/unversioned_hint (0.00s)
    --- PASS: TestMySQLExecutableCommentCloseBypassIsBlocked/optimizer_hint_shape (0.00s)
=== RUN   TestHardenMySQLConfigReadAndWriteAgree
--- PASS: TestHardenMySQLConfigReadAndWriteAgree (0.00s)
=== RUN   TestMySQLWritableConnectionWritesAndReadOnlyOneStillCannot
--- PASS: TestMySQLWritableConnectionWritesAndReadOnlyOneStillCannot (0.17s)
=== RUN   TestMySQLWritableConnectionStillRefusesDDL
--- PASS: TestMySQLWritableConnectionStillRefusesDDL (0.00s)
PASS
ok  	github.com/yehia-khalil/wakil/internal/wakilcore	2.652s

test-live: all selected tests ran, none skipped.
```
Exit 0. **`wakil-acc-mysql` and `wakil-acc-mongo` were both running for this run, and
the harness reports "all selected tests ran, none skipped"** — the condition Task 16's
brief required before this line could be pasted here.

```
$ make app-test
xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal
cd app && ../scripts/swift-test.sh
Building for debugging...
[0/5] Copying default.metallib
[1/5] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.23s)
Test Suite 'Selected tests' started at 2026-09-12 18:29:44.480.
Test Suite 'WakilPackageTests.xctest' started at 2026-09-12 18:29:44.482.
Test Suite 'WakilPackageTests.xctest' passed at 2026-09-12 18:29:44.482.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-12 18:29:44.482.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
◇ Test ctxSetProviderNeverReachesTheAllowedToolsList() started.
◇ Test aTextColumnContainingTheWordNaNSortsConsistently() started.
◇ Test stopReturnsPromptlyWhenAGrandchildHoldsStdoutOpen() started.
◇ Test anActionsReturnValueReachesTheAgentInAToolResultEnvelope() started.
◇ Test aPaneCarriesItsSubjectThroughAFileRoundTrip() started.
◇ Test noPermissionModeNoPromptsTargetAndNoSkipFlagArePassed() started.
◇ Test paneFrameEdgesAreDerivedFromOriginAndSize() started.
◇ Test anEmptySelectionHasNoAnchorAndNoRows() started.
◇ Test manyLargeFramesOnOneConnectionAreAnsweredInOrderAndInFull() started.
◇ Test aSendWithNoHarnessLeavesTheCoreIdle() started.
◇ Test paneMaximizeAndRestoreRoundTripThroughTheRegistry() started.
◇ Test binaryResolutionFindsTheDevCheckoutLayout() started.
◇ Test aBlankStatementFromTheAgentIsRefusedRatherThanParked() started.
◇ Test paneTableOfAnUntouchedPaneIsEmpty() started.
◇ Test readPaneAnswersFromThePaneStore() started.
◇ Test paneIdsListsEveryPaneWrittenTo() started.
◇ Test productionIsMatchedRegardlessOfCase() started.
◇ Test aHeaderDragCommitsTheWidthThePointerEndedAt() started.
◇ Test maximizeAndRestoreReturnTheOriginalFrame() started.
◇ Test noStateAsksForMoreThanOneHundredAndTwentyFramesPerSecond() started.
◇ Test aLargeButRepresentableRowIndexIsStillAccepted() started.
◇ Test theDragCandidateExcludesTheDraggedPaneItself() started.
◇ Test panesBecomePaletteItemsCarryingTheirId() started.
◇ Test onlyATableListOffersADrill() started.
◇ Test everyStatesAmplitudeRangeIsOrdered() started.
◇ Test aSubjectThisBuildCannotReadCostsThePaneAndNotTheFile() started.
◇ Test bothHandWrittenReadToolsAreReachable() started.
◇ Test theObservationPumpDoesNothingUntilSomethingIsDispatched() started.
◇ Test aSecondProposalIsRefusedWhileOneIsPending() started.
◇ Test droppingOnePaneLeavesTheOthersAlone() started.
◇ Test ctxSetEnvironmentRefusesAnEnvironmentTheProjectDoesNotDeclare() started.
◇ Test anAgentsLayoutDispatchReachesTheCanvasToo() started.
◇ Suite StopDeliversTheTailOfTheStreamSuite started.
◇ Test overridesAreKeyedByNameSoReorderingDoesNotMisapplyThem() started.
◇ Test dbPaneContentsIsNilForAResultThatIsNotARowsPayload() started.
✔ Suite StopDeliversTheTailOfTheStreamSuite passed after 0.001 seconds.
◇ Test aChainOfForksCollapsesToItsNewestMember() started.
◇ Test savingTwiceIsStableOnDisk() started.
◇ Test twoProjectsInOneOrgDoNotOverwriteEachOther() started.
◇ Test aColumnNeverShrinksBelowTheFloor() started.
◇ Test unrelatedSessionsAreNotCollapsed() started.
◇ Test selectRowsKeepsTheAnchorInsideTheSetItNames() started.
◇ Test anEmptyQueryMatchesEverythingWithEqualScore() started.
◇ Test aHeaderOffsetIsNeverPositive() started.
◇ Test anOrdinaryControlActionIsStillAllowed() started.
◇ Test aParkedResumeRequestIsActedOn() started.
◇ Test commandClickOnARowNotYetSelectedAddsItAndMakesItTheAnchor() started.
◇ Test aPanesBottomEdgeSnapsToANeighboursTopEdge() started.
◇ Test sortingPutsRowsIntoTheirDisplayedPosition() started.
◇ Test thoughtRowNamesTheToolAndKeepsItsMCPPrefix() started.
◇ Test aMutationGetsALongerReplyBudgetThanARead() started.
◇ Test aTruncatedResultIsMarkedTruncatedInThePaneSnapshot() started.
◇ Test closingAPaneRemovesItAndItsLinksAndRefocuses() started.
◇ Test aMutatingActionIsNeverOnTheAllowList() started.
◇ Test aFailedTurnAlsoEndsTheThinking() started.
◇ Test everyOtherEnvironmentKeepsTheVioletAndBlueBleeds() started.
◇ Test staleEventsFromTheSupersededHarnessNeverReachTheRebuiltThread() started.
◇ Test aRequestWithoutAToolNameIsDeniedRatherThanErrored() started.
◇ Test aMutationOfUnknownFateIsJournalledUncertainBesideTheError() started.
◇ Test thePermissionPromptToolIsNamedInTheArgv() started.
◇ Test shimModeIsDetectedBeforeAnyUISetup() started.
◇ Test aCursorOutsideTheWindowIsClamped() started.
◇ Test aPaneSnapsToTheVoidEdgeWhenNoNeighbourIsNearer() started.
◇ Test paneRowAccessibilityLabelNamesAMissingCellAsEmpty() started.
◇ Test dispatchingTheMutationInProductionJournalsBlockedAndNeverRunsTheHandler() started.
◇ Test paneCloseOnAnUnknownIdThrowsRatherThanSucceeding() started.
◇ Test aProductionEnvironmentTurnsTheVoidRed() started.
◇ Test everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule() started.
◇ Test commandItemsAreExactlyTheRegisteredActions() started.
◇ Test openingPanesGivesEachAUniqueIdAndFocusesTheNewest() started.
◇ Test decodesTheCredentialsJSON() started.
◇ Test frameReaderEmitsTwoMessagesFromOneChunk() started.
◇ Test onlyStructurallyBrokenLinesThrowAndTheyReportTheirIndex() started.
◇ Test paneColumnWidthIsTotalAgainstDegenerateInput() started.
◇ Test focusingTheAlreadyFocusedPaneFromTheRailStillDispatches() started.
◇ Test anAbsentOrNonObjectInputEchoesEmptyAndStillAllows() started.
◇ Test exactlyAtTheThresholdSnapsAndBeyondItDoesNot() started.
◇ Test snapshotReportsRowsInTheDisplayedOrder() started.
◇ Test aGatedControlActionParksWithADescriptionNotABlankStatement() started.
◇ Test allReturnsNonExecutableDescriptorsOnly() started.
◇ Test dispatchSplitsCRLFScriptsIntoOneDispatchPerLine() started.
◇ Test aDecisionForAStaleIdIsIgnored() started.
◇ Test projectNamesWithPathSeparatorsCannotEscapeTheDirectory() started.
◇ Test dbPaneContentsDropsColumnTypesEntirelyWhenShorterThanColumns() started.
◇ Test returningToAProjectKeepsWhatWasOpenedThereSinceTheLoad() started.
◇ Test toolsCallDispatchesThroughTheRegistry() started.
◇ Suite SubprocessDBActionTests started.
◇ Test startRunsTheChildInTheGivenWorkingDirectory() started.
◇ Test resumingReplacesTheHarnessAndRestartsTheEventPump() started.
◇ Test anAllowedToolAnswersAllow() started.
◇ Test aDensePaneIsSavedAndRestoredDense() started.
◇ Test cancellingLeavesTheMutationUnrunAndSaysSo() started.
◇ Test aTurnInFlightMakesTheCoreThink() started.
◇ Test aHeaderDragsCommittedWidthReachesTheCanvasThroughTheRegistry() started.
◇ Test everyCornerIsWithinTheMaximumOffset() started.
◇ Test approvingAParkedProposalResolvesTheWaiter() started.
◇ Test dbPaneContentsReadsAnAbsentTruncatedKeyAsComplete() started.
◇ Test parkedMutationJudgesTheEnvironmentAtConfirmationNotAtProposalTime() started.
◇ Test paneMoveAndResizeChangeTheStore() started.
◇ Test sendingStartsTheSessionAndListsTheEventsItProduces() started.
◇ Test anUnresolvedEnvironmentIsNotProduction() started.
◇ Test requiredStreamingFlagsArePresent() started.
◇ Test dbPaneContentsKeepsColumnTypesWhenTheyMatchTheColumnCount() started.
◇ Test binaryResolutionAcceptsPackageSwiftAsTheCheckoutMarker() started.
◇ Test toolCallDecodesAsTheElevenLinesTheFixtureActuallyHas() started.
◇ Test aSelectionIsClampedToWhatTheNewRowsCanCarry() started.
◇ Test everySubjectCarriesItsDatabase() started.
◇ Test binaryResolutionReturnsNilRatherThanCrashingWhenNothingIsThere() started.
◇ Test refreshPanesAppliesTheRecordedSortIntent() started.
◇ Test binaryResolutionStopsTheAncestorWalkAtTheCheckoutRoot() started.
◇ Test maximizingAnAlreadyMaximizedPaneIsANoOp() started.
◇ Test currentReflectsProjectAndEnvironmentAfterTheActionsSetThem() started.
◇ Test commitingADragThatWasPreviewingASnapDispatchesPaneSnap() started.
◇ Test toolCallFixtureYieldsToolUsesAndResultsThatMatchByID() started.
◇ Test aWordBoundaryScoresHigherThanMidWord() started.
◇ Test everySubjectRoundTripsThroughJSON() started.
◇ Test aSuccessfulSwitchDispatchesThePersistenceWriteWithTheChosenProvider() started.
◇ Test ctxSetProjectRefusesAProjectFiledUnderAnotherOrg() started.
◇ Test anOrdinaryHandlerFailureJournalsErrorAloneWithNoUncertainLine() started.
◇ Test paneRowAccessibilityLabelPairsEveryColumnWithItsValue() started.
◇ Test theFirstMutationIsBlockedInProductionAndGatedElsewhere() started.
◇ Test aPrefixScoresHigherThanAScatteredMatch() started.
◇ Test frameReaderLatchesOverflowForNextPushWhenUnterminatedFrameExceedsCap() started.
◇ Test aRecognisedTypeWithAnUnexpectedPayloadDegradesInsteadOfThrowing() started.
◇ Test earlyClientDisconnectDoesNotKillTheServerOrOtherConnections() started.
◇ Test binaryResolutionTreatsTheEnvironmentOverrideAsExclusive() started.
◇ Test aFailedSendClearsTurnInFlightRatherThanLeavingItSet() started.
◇ Test noSortAndAnUnknownColumnBothLeaveTheOrderAlone() started.
◇ Test aCorruptLayoutDegradesToNilWithANote() started.
◇ Test theCursorAtTheCentreMeansNoOffset() started.
◇ Test linkingTheSamePairTwiceDoesNotDuplicateIt() started.
◇ Test aToolUseForAToolWakilNeverConfiguredStillDecodes() started.
◇ Test sessionResumeRefusesAMissingId() started.
◇ Test startAfterStopThrowsAlreadyStopped() started.
◇ Test threadLiftIsFullWhileATurnIsInFlight() started.
◇ Test activeContextCarriesTheActiveProvider() started.
◇ Test switchingProjectRestoresItsSavedLayoutAndReportsAnUnreadableOne() started.
◇ Test reorderingUsesTheUnsortedRowsSoASecondSortIsNotBuiltOnTheFirst() started.
◇ Test mutationsAreBlockedOutrightInProduction() started.
◇ Test aNegativeRowIsRefused() started.
◇ Test readPaneOnAPaneNothingHasWrittenIsAnEmptySnapshotNotAnError() started.
◇ Test movingAPaneUnlinksEveryEdgeItHeld() started.
◇ Test snappingToANeighbourAlsoLandsWhereThePreviewSaid() started.
◇ Test aSnapshotReportsWhetherItCanBePagedAndWhereItIs() started.
◇ Test environmentNeverCarriesAnAPIKey() started.
◇ Test anUnpageableResultSaysSoRatherThanOmittingTheKey() started.
◇ Test paneRowOverflowsAvailableWidthOnceTheFlooredTotalExceedsIt() started.
◇ Test loadReplacesOneProjectsArrangementWholesale() started.
◇ Test aFetchDecodedWithAPageSizeAboveTheCapClampsToOneThousand() started.
◇ Test matchingIsCaseInsensitive() started.
◇ Test paneSnapRejectsAnUnknownEdge() started.
◇ Test sortingResetsTheOffsetToZero() started.
◇ Test aProductionMutationIsBlockedAndNeverParks() started.
◇ Test pagingMovesTheOffsetByWholePages() started.
◇ Test readLayoutOnAnEmptyCanvasIsAnEmptyAnswerNotAnError() started.
◇ Test openItemsListEveryProjectInTheActiveOrg() started.
◇ Test childEnvironmentForwardsOnlyTheKeysItMeansTo() started.
◇ Test removingAPaneRemovesEveryLinkItHeld() started.
◇ Test aNotificationGetsNoReply() started.
◇ Test frameReaderPreservesPriorMessagesThenLatchesDecodeErrorOnNextPush() started.
◇ Test aSwitchMintsAFreshSessionRatherThanForking() started.
◇ Test scrollToRowRefusesARowIndexThatCannotBeAnIndex() started.
◇ Test paneFocusMovesFocusToTheNamedPane() started.
◇ Test requestsBeforeAnySubscriberAreNotLost() started.
◇ Test openItemsListEveryProviderInTheActiveOrgAndMarksTheRunningOne() started.
◇ Test theMidPlaneNeverParallaxes() started.
◇ Test aPaneTableFromAnOlderSnapshotIsNotPageable() started.
◇ Test dbRunMutationRequiresAStatement() started.
◇ Test anUnrecognisedTypeBecomesUnknownRatherThanThrowing() started.
◇ Test closingTheLastPaneLeavesNoFocus() started.
◇ Test anAgentsDispatchReachesTheScreenWithoutTheOperatorClicking() started.
◇ Test jsonrpcMessageDistinguishesExplicitNullResultFromAbsentResult() started.
◇ Test theDebugSinkIsSilentWhenDisabled() started.
◇ Test mutationsAreGatedOutsideProduction() started.
◇ Test allFourStatesExistAndHaveStableRawValues() started.
◇ Test focusNoLongerDecidesAnything() started.
◇ Test aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy() started.
◇ Test refusesASwitchWhileATurnIsInFlight() started.
◇ Test theAllowListAdmitsControlActionsAndBothReadTools() started.
◇ Test standardActionNamesAreStableAndNamespaced() started.
◇ Test actionsBecomePaletteItemsCarryingTheirName() started.
◇ Test thoughtRowCarriesAssistantTextVerbatim() started.
◇ Test aMagnitudeFarOutsideInt64RangeFallsBackRatherThanTrapping() started.
◇ Test aColumnWithNoTypeCarriesNil() started.
◇ Test sortDirectionRoundTripsThroughItsWireName() started.
◇ Test restoreWithNothingMaximizedIsANoOp() started.
◇ Test actionKindHasThreeCasesWithStableRawValues() started.
◇ Test snappingMatchesExtentAndRecordsTheLink() started.
◇ Test anUnregisteredWakilNameIsRefused() started.
◇ Test selectCellRefusesARowIndexThatCannotBeAnIndex() started.
◇ Test concurrentStartStopCyclesCompleteWithoutDeadlocking() started.
◇ Test resumeNeverAppearsWithoutForkSessionAndASessionId() started.
◇ Test shiftExtendsDownwardFromTheAnchor() started.
◇ Test controlIsAllowedFromTheAgentWhenNoProductionTargetIsNamed() started.
◇ Test aNeighbourThatDoesNotOverlapAlongTheSharedEdgeIsNotACandidate() started.
◇ Test listToolsReturnsWakilCtxToolSet() started.
◇ Test oneAssistantLineWithSeveralBlocksYieldsSeveralEvents() started.
◇ Test unknownEventsAreDroppedButReachTheDebugSinkWhenEnabled() started.
◇ Test framesIntersectOnlyWhenTheyOverlapInBothAxes() started.
◇ Test settingRowsDoesNotDisturbSelectionOrSort() started.
◇ Test aSuccessfulSwitchClearsTheThreadAndDrawsASeam() started.
◇ Test columnsWithNoOverrideDivideTheSpaceEvenly() started.
◇ Test refusesWhenTheLookupThrowsAnythingElse() started.
◇ Test listeningIsTheOnlyStateThatChangesSpread() started.
◇ Test aBareActionNameWithoutTheServerPrefixIsRefused() started.
◇ Test aNewResultStillLeavesTheSelectionAloneWhenItCanCarryIt() started.
◇ Test dispatchJournalsUnderTheGivenHome() started.
◇ Test rowsArrivingUnderAStandingSortAreOrderedToo() started.
◇ Test resumingTheSessionAlreadyRunningInThisWindowIsRefused() started.
◇ Test encodeFrameEndsWithExactlyOneNewline() started.
◇ Test recordingASubjectOnAPaneThatIsGoneIsSilent() started.
◇ Test clickingTheAlreadyFocusedPaneDispatchesNothing() started.
◇ Test onePaneCanHoldSeveralNeighboursOnOneEdge() started.
◇ Test aNamespacedMCPToolNameSurvivesIntact() started.
◇ Test speakingIsTheOnlyStateWhosePulseIsLocalToTheLowerBleed() started.
◇ Test idleAndListeningKeepTheDesignLanguagesPeriods() started.
◇ Test jsonrpcErrorDistinguishesExplicitNullDataFromAbsentData() started.
◇ Test missingRequiredParamThrowsRatherThanCrashing() started.
◇ Test aWindowWithNoActiveProviderCanStillAcquireOne() started.
◇ Test readPaneIsNotADispatchAndIsNotJournalled() started.
◇ Test aPaneNeverSnapsToItselfBecauseItIsNotInNeighbours() started.
◇ Test paneOpenRefusesAKindThisBuildCannotDraw() started.
◇ Test sortIsRecordedAsIntentAndIsNullUntilSet() started.
◇ Test ctxSetProviderPersistsThroughTheRealBinaryAndIsVisibleToGetContext() started.
◇ Test aNewPaneIsAiry() started.
◇ Test sessionSetProviderIsKnownToARegistryBuiltWithoutAnyWindow() started.
◇ Test updatedInputEchoesTheInputVerbatim() started.
◇ Test debugScriptReportsTheNumberOfFailedLines() started.
◇ Test rowIndexActionsSayTheyAreZeroBasedPositions() started.
◇ Test aNullCellIsDistinguishableFromAnEmptyString() started.
◇ Test journalEntriesAreIdenticalAcrossOriginsExceptForOrigin() started.
◇ Test idleHasTheLowestCeilingAndListeningTheHighest() started.
◇ Test readLayoutIsAdvertisedAndJournalsNothing() started.
◇ Test aFreshLaunchNeverMentionsResume() started.
◇ Test aRefusedToolAnswersDenyWithAMessageTheAgentCanRead() started.
◇ Test commandClickDeselectsANonAnchorRowAndKeepsTheExistingAnchor() started.
◇ Test pagingBackFromTheFirstPageStaysOnIt() started.
◇ Test theHeaderTracksHorizontalScrollingAndOnlyThat() started.
◇ Test changingOrClearingTheSortRestatesTheDisplayedOrder() started.
◇ Test anOperatorMutationParksAndRunsOnceConfirmed() started.
◇ Test anUnsavedEditIsProtectedFromBeingOverwritten() started.
◇ Test refusesCredentialsWithAnEmptyField() started.
◇ Test dispatchRunsTheHandlerAndReturnsItsValue() started.
◇ Test stdoutLinesArriveAsDecodedEventsNotJustUnknowns() started.
◇ Test requestsAfterTheSoleSubscriberIsGoneAreDroppedNotHoarded() started.
◇ Test unknownActionThrowsRatherThanSilentlySucceeding() started.
◇ Test typingTheWrongWordDoesNotConfirm() started.
◇ Test aPaneCannotBeMovedEntirelyOutsideTheCanvas() started.
◇ Test theBridgeIsNotOnTheAllowList() started.
◇ Test linksAreOrderedDeterministically() started.
◇ Test namingNoPaneTargetsNoPane() started.
◇ Test everyLayoutActionIsRegisteredAsControl() started.
◇ Test readPaneWithoutAUsablePaneIdIsInvalidParams() started.
◇ Test rowsAndTypesRoundTripPerPane() started.
◇ Test everyProjectedMCPToolNameSatisfiesTheSameRule() started.
◇ Test environmentIsBuiltExplicitlyNotInherited() started.
◇ Test threadLiftDecaysToZeroAfterTheLastRow() started.
◇ Test endingADragCommitsExactlyOneAction() started.
◇ Test aLayoutFileWithoutPreMaximizeFramesStillLoads() started.
◇ Test aReloadedMaximizedLayoutStillRestoresToItsOriginalFrame() started.
◇ Test sessionSetProviderNeverReachesTheAllowedToolsList() started.
◇ Test dispatchResolvesRealActionNamesThroughTheSharedWiring() started.
◇ Test runningAPaletteActionDispatchesIt() started.
◇ Test openItemsIncludeEveryOpenPane() started.
◇ Test theThreePlanesCarrySection3sConstants() started.
◇ Test snappingToTheVoidEdgeMovesWithoutResizing() started.
◇ Test mutationInProductionIsBlockedEvenWithCorrectConfirmation() started.
◇ Test columnWidthLandsOnThePaneAndPersistsWithIt() started.
◇ Test aNewPaneIsNotBusy() started.
◇ Test resizingASnappedPaneResizesItsNeighbourToo() started.
◇ Test everyStateGetsAtLeastTwentyFiveFramesPerCycleOnASixtyHertzPanel() started.
◇ Test aLayoutWrittenBeforeSubjectsExistedStillDecodes() started.
◇ Test aRefusedPaneCloseDoesNotDropAnyContents() started.
◇ Test aSubsequenceMatchesEvenWhenScattered() started.
◇ Test anUntouchedLineAdoptsAReQueriedPanesNewDescription() started.
◇ Test noNeighbourAndNoVoidEdgeInRangeMeansNoCandidate() started.
◇ Test thePaletteShowsATitleWhenTheSessionHasOne() started.
◇ Test paneOpenDefaultsItsTitleToTheKind() started.
◇ Test concurrentCommitsLeaveTheLatestArrangementOnDisk() started.
◇ Test theOtherWakilServersAreRefused() started.
◇ Test anUnknownFrameProducesNoRowAtAll() started.
◇ Test concurrentStopCallsOnTheSameClientAllReturn() started.
◇ Test contextSettersAreControlAndOnlyTheEnvironmentOneNamesATarget() started.
◇ Test activeContextDefaultsRootPathsToEmptyWhenAbsent() started.
◇ Test frameReaderPreservesPriorMessagesThenLatchesOverflowOnNextPush() started.
◇ Test dispatchRejectsAnEnvironmentFlagWithNoValue() started.
◇ Test selectRowsRefusesATrappingAnchor() started.
◇ Test aSavedLayoutLoadsBackIdentically() started.
◇ Test overridesAloneCanExceedTheWidthAndAreStillHonoured() started.
◇ Test sessionResumeParksTheRequestAndReturnsWithoutWaiting() started.
◇ Test focusingAnOffCanvasPaneBringsItBackIntoView() started.
◇ Test anAgentProposedMutationParksAndRunsOnceApproved() started.
◇ Test commandClickDeselectingTheAnchorRowItselfMovesTheAnchorToASurvivor() started.
◇ Test theWireFormatsLayoutIsPinned() started.
◇ Test callToolSurfacesAServerSideErrorRatherThanHanging() started.
◇ Test theCoreIsIdleWithNoTurnAndThinkingWithOne() started.
◇ Test paneTableCarriesTheTruncationFlagAndDefaultsItToFalse() started.
◇ Test toolsListProjectsTheRegistryPlusBothReadToolsAndTheBridge() started.
◇ Test densitySurvivesAJSONRoundTrip() started.
◇ Test scrollClearRemovesAPendingTarget() started.
◇ Test aLayoutCommitWritesNothingUntilTheOrgAndProjectAreKnown() started.
◇ Test actingOnAnUnknownPaneThrows() started.
◇ Test thePromptToolFlagIsBuiltFromTheSameConstantsTheServerAdvertises() started.
✔ Test paneFrameEdgesAreDerivedFromOriginAndSize() passed after 0.012 seconds.
◇ Test aSelectionAlwaysContainsItsAnchorRow() started.
◇ Test providerLabelForASetProviderIsThatProviderIdVerbatim() started.
◇ Test anUntouchedPaneAnswersWithEveryKeyPresent() started.
◇ Test theMCPSurfaceIsThisAssemblysOwnRegistryAndPaneStore() started.
◇ Test stateNeverTouchesTheBleedColours() started.
◇ Test surfacesTheLookupRefusalVerbatim() started.
◇ Test everyRegisteredActionIsAllowedWhenDerivedFromALiveRegistry() started.
◇ Test selectingAMutationFromCommandKWithNoArgumentsDoesNotPark() started.
◇ Test commandClickDeselectingTheLastRemainingRowLeavesNoAnchor() started.
◇ Test noLayoutActionNamesATargetEnvironment() started.
◇ Test everyStateGetsAtLeastTwentyFiveFramesPerCycle() started.
◇ Test cancellingAParkedMutationRefusesTheAgent() started.
◇ Test allowedToolsReachTheArgvAsOneCommaSeparatedValue() started.
◇ Test aResultLandingDuringSendsSuspensionDoesNotStickTurnInFlightBackOn() started.
◇ Test theAnthropicToolNameRuleHelperRejectsWhatTheRuleRejects() started.
◇ Test aPaneRoundTripsThroughJSON() started.
◇ Test paneSetDensityRejectsAnUnknownValue() started.
◇ Test thoughtRowMarksAFailedTurnAsAnError() started.
◇ Test anExpiredConfirmationIsDistinguishableFromARefusal() started.
◇ Test paneColumnWidthDividesAvailableWidthEvenlyMinusSpacing() started.
◇ Test theBridgeRefusesToAnswerAboutItself() started.
✔ Test noPermissionModeNoPromptsTargetAndNoSkipFlagArePassed() passed after 0.014 seconds.
◇ Test shiftExtendsUpwardWhenTheClickedRowIsAboveTheAnchor() started.
◇ Test anEmptyPaneStringIsTheSameAsNamingNone() started.
◇ Test paneSnapAcceptsAnAbsentToPaneIdAsTheVoidEdge() started.
◇ Test aPreviewNearAnotherPaneSurfacesASnapCandidate() started.
◇ Test theVoidTheSolverUsesFollowsTheReportedCanvasSize() started.
◇ Test everyEventThatDescribesWorkStillProducesARow() started.
◇ Test theDefaultDirectoryHangsOffTheGivenHome() started.
◇ Test agentMCPConfigNeverExposesThePaneAffectingBinaries() started.
✔ Test anEmptySelectionHasNoAnchorAndNoRows() passed after 0.015 seconds.
◇ Test dispatchExitsZeroAndReturnsRealResultsWhenTheBinariesArePresent() started.
◇ Test movingThePaneDoesNotMoveTheHeaderOffItsColumns() started.
◇ Test maximizingASecondPaneRestoresTheFirst() started.
◇ Test aFetchDecodedWithAZeroPageSizeClampsToOne() started.
◇ Test aForkCarriesResumeForkSessionAndAFreshSessionId() started.
◇ Test answeringAPermissionQuestionWritesNothingToTheJournal() started.
◇ Test everyActionWithAMissingClientThrowsRatherThanCrashing() started.
◇ Test aLineSplitAcrossTwoReadChunksIsReassembled() started.
◇ Test anOverriddenColumnKeepsItsWidthAndTheRestDivideWhatIsLeft() started.
◇ Test aLayoutCommitIsWrittenUnderTheActiveOrgAndProject() started.
◇ Test aSavedPaneOfAnUndrawableKindIsDroppedWithANote() started.
◇ Test productionMatchIsExactAndCaseInsensitive() started.
◇ Test dispatchGatesAnAgentControlActionNamingProduction() started.
◇ Test resultAppearsButIsNotTheLastEventInEitherFixture() started.
◇ Test shiftWithNoExistingAnchorBehavesLikeAPlainClick() started.
◇ Test threadLiftClampsANegativeElapsedTime() started.
✔ Test aPaneCarriesItsSubjectThroughAFileRoundTrip() passed after 0.016 seconds.
◇ Test mixedNumericAndTextValuesStillFormAConsistentOrder() started.
◇ Test updatesPublishParkAndRelease() started.
◇ Test initializeIsAnswered() started.
◇ Test plainClickCollapsesAMultiRowSelectionToTheClickedRow() started.
✔ Test paneTableOfAnUntouchedPaneIsEmpty() passed after 0.016 seconds.
◇ Test selectRowsRefusesATrappingIndexInsideItsArray() started.
◇ Test resizingPastASnappedNeighbourFloorsItRatherThanGoingToZero() started.
◇ Test basicTurnDecodesAsTheThirteenLinesTheFixtureActuallyHas() started.
◇ Test rankingDropsNonMatchesAndOrdersByScore() started.
◇ Test everyFixtureLineProducesExactlyOneEvent() started.
◇ Test aParkedProposalExpires() started.
✔ Test paneIdsListsEveryPaneWrittenTo() passed after 0.016 seconds.
✔ Test ctxSetProviderNeverReachesTheAllowedToolsList() passed after 0.017 seconds.
◇ Test uncertainMutationCarriesTheEnvironmentToo() started.
◇ Test agentMCPConfigNamesTheShimAndTheAnswerBinaries() started.
◇ Test controlIsGatedWhenTheAgentTargetsProduction() started.
◇ Test binaryResolutionFindsTheBundleLayout() started.
◇ Test journalLinesWrittenBeforeThisFieldExistedStillDecode() started.
◇ Test rerunningTheSameQueryKeepsTheWholeSelection() started.
◇ Test paneOpenReturnsTheNewPanesId() started.
◇ Test theLastEventBeforeEOFIsNeverDroppedByTheStreamFinishing() started.
◇ Test aResumedSessionRunsInTheDirectoryTheTranscriptRecords() started.
◇ Test dispatchSkipsBlankLinesRatherThanErroringOnThem() started.
◇ Test paneRowFitsAvailableWidthWhenNoColumnIsFloored() started.
◇ Test everyRegisteredActionIsReachableIncludingMutations() started.
◇ Test threadLiftIsZeroWithNoRows() started.
◇ Test everyBuiltInToolIsRefused() started.
◇ Test activeContextCarriesTheResolvedRootPaths() started.
✔ Test anActionsReturnValueReachesTheAgentInAToolResultEnvelope() passed after 0.018 seconds.
◇ Test paneCloseRemovesThePaneFromTheStore() started.
✔ Test aHeaderDragCommitsTheWidthThePointerEndedAt() passed after 0.018 seconds.
◇ Test mutationWithoutConfirmationIsRefusedAndJournalledAsGated() started.
✔ Test productionIsMatchedRegardlessOfCase() passed after 0.018 seconds.
◇ Test clickingAnUnfocusedPaneFocusesIt() started.
◇ Test aFetchDecodedWithANegativeOffsetClampsToZero() started.
✔ Test maximizeAndRestoreReturnTheOriginalFrame() passed after 0.018 seconds.
✔ Test readPaneAnswersFromThePaneStore() passed after 0.019 seconds.
◇ Test resumingWithAnUnsetProviderNamesItAsUnsetRatherThanBlank() started.
◇ Test aMutationTimeoutIsReportedAsUnknownRatherThanAsAFailure() started.
✔ Test noStateAsksForMoreThanOneHundredAndTwentyFramesPerSecond() passed after 0.019 seconds.
◇ Test allFiveStillRunWhenPointedAtProduction() started.
◇ Test childEnvironmentTakesTheProviderAsAParameterNotFromTheEnvironment() started.
◇ Test aLayoutOfKnownKindsLoadsWithNoNote() started.
◇ Test dbPaneContentsDropsColumnTypesEntirelyWhenLongerThanColumns() started.
◇ Test racingStartAndStopNeverLeavesAnOrphan() started.
◇ Test jsonValueRoundTripsNestedStructures() started.
◇ Test everyJournalOutcomeCarriesTheEnvironmentTheGateJudged() started.
◇ Test paneSnapshotSerialisesColumnsAndRowsForReadPane() started.
◇ Test frameReaderSkipsBlankLinesRatherThanFailing() started.
◇ Test sessionResumeIsControlAndSessionGetIsRead() started.
◇ Test columnTypesOfTheWrongLengthAreDroppedEntirely() started.
◇ Test readsAreAllowedInEveryEnvironmentFromEveryOrigin() started.
◇ Test debugScriptReportsAFailureWithoutAbortingLaterLines() started.
◇ Test encodedRequestNotificationAndErrorResponseAllCarryTheJSONRPCVersionTag() started.
◇ Test aSelectionWithNoSurvivingRowsBecomesEmpty() started.
◇ Test switchingProjectDoesNotCarryOnesRowsIntoTheOthersPane() started.
◇ Test aLayoutWrittenBeforeColumnWidthsExistedStillDecodes() started.
◇ Test aMissingRequiredParamThrowsRatherThanDefaulting() started.
◇ Test paneOpensSchemaNamesTheKindsItWillAccept() started.
◇ Test aFailingStartLeavesTheExistingSessionUntouched() started.
✔ Test binaryResolutionFindsTheDevCheckoutLayout() passed after 0.020 seconds.
◇ Test activeContextDefaultsActiveProviderToEmptyWhenAbsent() started.
◇ Test everyAllowListEntryNamesAServerTheMCPConfigActuallyDefines() started.
◇ Test comingBackToAProjectFindsItsRowsWhereTheyWereLeft() started.
◇ Test aServerWhoseNameMerelyStartsWithWakilIsRefused() started.
◇ Test paneOpenStillAcceptsTheKindThisBuildDoesDraw() started.
◇ Test readPaneAdvertisesEverythingItReturns() started.
◇ Test densityCarriesSection8sRowHeights() started.
◇ Test aPaletteSourceThatCannotAnswerSaysSoRatherThanLookingEmpty() started.
◇ Test aNonSubsequenceDoesNotMatch() started.
◇ Test frameReaderSplitsOnNewlinesAcrossChunks() started.
◇ Test mirrorReflectingARegistryYieldsNoChildren() started.
✔ Test theDragCandidateExcludesTheDraggedPaneItself() passed after 0.023 seconds.
◇ Test rankingIsStableForEqualScores() started.
◇ Test staleEventsFromTheSupersededHarnessNeverReachTheClearedThreadAfterASwitch() started.
◇ Test aPersistenceWriteFailureDoesNotUndoTheSwap() started.
✔ Test panesBecomePaletteItemsCarryingTheirId() passed after 0.023 seconds.
◇ Test anUntouchedLineFollowsTheSubjectEvenWhenNothingChangedAtAll() started.
◇ Test busyIsStillNotPersisted() started.
◇ Test aControlActionWithNoTargetParamIsNeverGated() started.
✔ Test paneMaximizeAndRestoreRoundTripThroughTheRegistry() passed after 0.024 seconds.
◇ Test scrollToRowIsRecordedAsATarget() started.
◇ Test aSecondCallToEventsCrashesRatherThanSplittingTheStream() started.
◇ Test switchingProjectPreservesTheOutgoingArrangement() started.
◇ Test aThreeDeepChainCollapsesToTheSingleNewestEntry() started.
◇ Test aGraphRoundTripsThroughJSON() started.
◇ Test snappingLandsThePaneWhereThePreviewSaidItWould() started.
◇ Test dbRunMutationIsRegisteredAsTheFirstMutateAction() started.
◇ Test anOrdinaryMutationFailurePassesThroughUnchanged() started.
◇ Test aNodePointingIntoASelfCycleDoesNotHangTheWalk() started.
◇ Test everyTypeWithoutACaseSurfacesAsUnknownWithItsWireTag() started.
◇ Test sessionListIsRegisteredAndFailsLoudlyWithoutAClient() started.
✔ Test onlyATableListOffersADrill() passed after 0.026 seconds.
◇ Test aNegativeRowIndexIsStillRefused() started.
◇ Test aFailedResultDecodesAsAnErrorAndAMissingTextIsNil() started.
◇ Test aZeroSizedWindowYieldsNoOffsetRatherThanNaN() started.
◇ Test theAllowListIsExactlyTheRegistrysReadAndControlActionsPlusBothReadTools() started.
◇ Test ctxSetProviderRefusesAnUnregisteredProviderId() started.
✔ Test aBlankStatementFromTheAgentIsRefusedRatherThanParked() passed after 0.027 seconds.
◇ Test aProviderWithNoLabelFallsBackToItsId() started.
◇ Test aModelHoldsATablePerPane() started.
◇ Test paneColumnWidthNeverGoesBelowItsFloor() started.
✔ Test aLargeButRepresentableRowIndexIsStillAccepted() passed after 0.029 seconds.
◇ Test rebuiltRowIdsDoNotCollideWithLiveOnes() started.
◇ Test cancellingAParkedProposalResolvesTheWaiter() started.
◇ Test noColumnsIsNoWidths() started.
◇ Test focusPlaysNoPartInTheDecision() started.
◇ Test stdoutChunksReachTheEventStreamInTheOrderTheyWereRead() started.
◇ Test offersDrillOnlyForATableListSubjectIncludingAnEmptyOne() started.
◇ Test numericColumnsSortNumericallyNotLexically() started.
◇ Test refusesASwitchToTheProviderAlreadyRunning() started.
◇ Test openingAPaneThroughTheModelGoesThroughTheRegistry() started.
◇ Test aParkedRequestReachesTheSubscriber() started.
◇ Test anUnmeasuredSurfaceDrawsItsHeaderSquare() started.
◇ Test dispatchExitsNonZeroWhenAnyLineErrored() started.
✔ Test aSubjectThisBuildCannotReadCostsThePaneAndNotTheFile() passed after 0.032 seconds.
◇ Test theSameSelectionFromUiAgentAndDebugJournalsIdentically() started.
◇ Test dbPaneContentsCarriesTruncatedFromACappedResult() started.
◇ Test aRowTooShortForTheSortedColumnSortsAsANull() started.
◇ Test paneSetDensityIsAControlActionAndChangesOnePane() started.
◇ Test theFooterNamesWhichRowsAreOnScreenOnlyWhenPaging() started.
◇ Test pagingToAnAbsolutePageMultipliesByThePageSize() started.
◇ Test thinkingIsTheOnlyStateWithDriftOrAntiphase() started.
◇ Test providerLabelForAnUnsetProviderIsTheHonestWordNotAnEmptyString() started.
◇ Test busyIsSetAndClearedWithoutTouchingAnythingElse() started.
◇ Test repliesSplitAcrossReadChunksNeverCorruptTheFrameStream() started.
◇ Test runningAQueryRefreshesTheTableFromThePaneStore() started.
◇ Test dbPaneContentsFallsBackRatherThanTrappingOnAnUnusableMillis() started.
✔ Test bothHandWrittenReadToolsAreReachable() passed after 0.034 seconds.
◇ Test anotherProjectsPaneOfTheSameNameIsEmpty() started.
✔ Test everyStatesAmplitudeRangeIsOrdered() passed after 0.034 seconds.
◇ Test theShimCarriesJSONRPCBetweenStdioAndTheSocket() started.
◇ Test aPaneTableCarriesWhereItIsAndWhetherItCanMove() started.
◇ Test theRunningProviderIsMarkedDistinctlyInItsPaletteRow() started.
◇ Test aResumeThatFailsToStartLeavesTheExistingSessionUntouched() started.
◇ Test journalIsAppendedAsOneJSONLineEach() started.
◇ Test everyWindowControlDispatchesWithTheUIOrigin() started.
◇ Test controlIsAllowedFromTheUIAndDebugEverywhere() started.
◇ Test dispatchingTheMutationWithoutConfirmationJournalsGated() started.
◇ Test dispatchFromSurfaceRoutesASelectionThroughPaneStoreAndRefreshesTheTable() started.
◇ Test blankLinesAreSkippedRatherThanTreatedAsMalformed() started.
◇ Test anUntouchedLineFollowsTheSubject() started.
◇ Test selectionRoundTripsAndAlwaysContainsItsAnchor() started.
◇ Test debugScriptDispatchesAndJournalsWithDebugOrigin() started.
◇ Test resumingAcrossProvidersIsRefusedAndNamesBoth() started.
◇ Test orgNamesWithPathSeparatorsCannotEscapeTheDirectory() started.
◇ Test kitVersionIsSet() started.
◇ Test rowsArriveOrderedByTheSortTheyWereGiven() started.
◇ Test namingAPaneTargetsThatPane() started.
◇ Test aLinkIsVisibleFromBothSides() started.
◇ Test dispatchRejectsAnEnvironmentValueThatIsAnotherFlag() started.
◇ Test wiringRegistersEveryStandardActionEvenWithNoBinariesPresent() started.
◇ Test dispatchFromSurfaceRoutesColumnWidthThroughLayoutNotPaneStore() started.
◇ Test aPaneSavedBeforeDensityExistedDecodesAsAiry() started.
◇ Test aProviderPaletteItemRoutesToSetProviderWithTheRightId() started.
◇ Test snapshotOfAnUnknownPaneIsEmptyNotAnError() started.
◇ Test anUnknownToolIsAnErrorNotACrash() started.
◇ Test aHeaderDragCannotTakeAColumnBelowTheLayoutMinimum() started.
◇ Test layoutActionsJournalTheirOrigin() started.
◇ Test theRebuiltThreadCarriesASeamNamingTheParent() started.
◇ Test theMotionFieldsAreCarriedThroughUnchanged() started.
◇ Test closingAPaneDropsItsContents() started.
◇ Test allFiveAreControlAndNameNoTargetEnvironment() started.
◇ Test rankingSearchesTheSubtitleToo() started.
◇ Test aNonSQLSubjectDescribesItselfRatherThanPretendingToBeSQL() started.
◇ Test aTruncatedPaneIsMarkedTruncatedOnTheWindow() started.
◇ Test sessionIdIsPassedNotGeneratedByTheCLI() started.
✔ Test aTextColumnContainingTheWordNaNSortsConsistently() passed after 0.039 seconds.
◇ Test snapEdgeOppositesAndAxes() started.
◇ Test nonFiniteNumbersFallBackToDefaultsRatherThanTrapping() started.
◇ Test ctxListProjectsDispatchesThroughToTheRealBinary() started.
◇ Test theAgentCannotChooseTheNextLaunchsAccountEither() started.
◇ Test nullsSortLastInBothDirections() started.
◇ Test mutationAffectsEveryRowAgreesWithTheGoFixtureTable() started.
◇ Test aFreshSessionRunsInTheProjectsFirstRoot() started.
◇ Test aProductionMutationNeverReachesTheOperator() started.
◇ Test paneTableGivesIdenticalRowsDistinctIdentities() started.
◇ Test columnWidthsSurviveAJSONRoundTrip() started.
◇ Test childEnvironmentOmitsTheProviderWhenThereIsNone() started.
◇ Test aParentWithNoChildInTheListingIsKept() started.
◇ Test aFailedToolResultCarriesItsErrorFlagAndAMissingOneIsFalse() started.
◇ Test aPaneWithAnOutOfRangeOffsetDecodesToAClampedFetch() started.
◇ Test droppedEventsDoNotCollapseRowIds() started.
◇ Test refusesASwitchWithAProposalParked() started.
◇ Test binaryResolutionTreatsAnEmptyEnvironmentOverrideAsSet() started.
◇ Test namingAPaneWorksWithNoLayoutAtAll() started.
◇ Test ctxSetProjectCannotElevateIntoProduction() started.
◇ Test anEmptyAllowListOmitsTheFlagEntirelyRatherThanPassingItEmpty() started.
◇ Test thePaletteFallsBackToTheFirstPromptThenTheId() started.
◇ Test theSoleSubscriberReceivesEveryRequest() started.
◇ Test unlinkingOneEdgeLeavesTheOthersAlone() started.
◇ Test theAgentCannotSwitchItsOwnAccount() started.
◇ Test theWorkingDirectoryIsCarriedOnTheLaunch() started.
◇ Test aBusyPaneIsSavedAndRestoredIdle() started.
◇ Test cellTextMatchesTheOldProjectionForEveryNonNullKind() started.
◇ Test thoughtRowMarksAFailedToolResultAsAnError() started.
◇ Test readLayoutReportsPanesFramesFocusAndSnaps() started.
◇ Test standardActionsAreReadOrControlAndNeverMutateIn2bI() started.
◇ Test executableIsPinnedByAbsolutePath() started.
◇ Test aFetchDefaultsToThePageSizeTheDriverAlreadyUses() started.
◇ Test snapshotsDifferingOnlyInBusyAreTheSameArrangement() started.
◇ Test paneTableRendersEveryCellOfASnapshot() started.
◇ Test theAgentsProductionTargetMatchIsCaseInsensitiveToo() started.
◇ Test aFailedDispatchBecomesVisibleStatusText() started.
◇ Test aPanesSubjectIsRecordedAndReadBack() started.
◇ Test paneTableCarriesTypesSelectionAndSort() started.
◇ Test sendingWithNoHarnessSaysSoInsteadOfDoingNothing() started.
◇ Test aPanesRightEdgeSnapsToANeighboursLeftEdge() started.
◇ Test selectCellSetsTheAnchorAndCollapsesTheSelectionToItsRow() started.
◇ Test loadingSomethingNeverSavedIsNilWithNoNote() started.
◇ Test droppingAPaneForgetsEverythingItHeld() started.
◇ Test requestDoesNotWaitForTheRequestToBeHandled() started.
◇ Test aToolResultWhoseContentIsAJSONStringStaysAString() started.
◇ Test theNearestCandidateWins() started.
◇ Test paneTableStaysTotalOnAShapeItDoesNotRecognise() started.
◇ Test openedPanesCascadeRatherThanStackingExactly() started.
◇ Test agentToolsCallMovesLayoutStoreNotJustTheReply() started.
✔ Test dbPaneContentsIsNilForAResultThatIsNotARowsPayload() passed after 0.046 seconds.
✔ Test overridesAreKeyedByNameSoReorderingDoesNotMisapplyThem() passed after 0.046 seconds.
✔ Test droppingOnePaneLeavesTheOthersAlone() passed after 0.046 seconds.
✔ Test aChainOfForksCollapsesToItsNewestMember() passed after 0.050 seconds.
✔ Test unrelatedSessionsAreNotCollapsed() passed after 0.052 seconds.
✔ Test aColumnNeverShrinksBelowTheFloor() passed after 0.052 seconds.
✔ Test anEmptyQueryMatchesEverythingWithEqualScore() passed after 0.053 seconds.
✔ Test aHeaderOffsetIsNeverPositive() passed after 0.054 seconds.
✔ Test commandClickOnARowNotYetSelectedAddsItAndMakesItTheAnchor() passed after 0.056 seconds.
✔ Test anOrdinaryControlActionIsStillAllowed() passed after 0.056 seconds.
✔ Test selectRowsKeepsTheAnchorInsideTheSetItNames() passed after 0.057 seconds.
✔ Test sortingPutsRowsIntoTheirDisplayedPosition() passed after 0.057 seconds.
✔ Test aPanesBottomEdgeSnapsToANeighboursTopEdge() passed after 0.057 seconds.
✔ Test aMutationGetsALongerReplyBudgetThanARead() passed after 0.057 seconds.
✔ Test savingTwiceIsStableOnDisk() passed after 0.058 seconds.
✔ Test closingAPaneRemovesItAndItsLinksAndRefocuses() passed after 0.058 seconds.
✔ Test aMutatingActionIsNeverOnTheAllowList() passed after 0.058 seconds.
✔ Test aTruncatedResultIsMarkedTruncatedInThePaneSnapshot() passed after 0.058 seconds.
✔ Test thoughtRowNamesTheToolAndKeepsItsMCPPrefix() passed after 0.059 seconds.
✔ Test everyOtherEnvironmentKeepsTheVioletAndBlueBleeds() passed after 0.058 seconds.
✔ Test aRequestWithoutAToolNameIsDeniedRatherThanErrored() passed after 0.059 seconds.
✔ Test thePermissionPromptToolIsNamedInTheArgv() passed after 0.060 seconds.
✔ Test aPaneSnapsToTheVoidEdgeWhenNoNeighbourIsNearer() passed after 0.063 seconds.
✔ Test aCursorOutsideTheWindowIsClamped() passed after 0.063 seconds.
✔ Test twoProjectsInOneOrgDoNotOverwriteEachOther() passed after 0.064 seconds.
✔ Test aMutationOfUnknownFateIsJournalledUncertainBesideTheError() passed after 0.064 seconds.
✔ Test paneRowAccessibilityLabelNamesAMissingCellAsEmpty() passed after 0.065 seconds.
✔ Test aProductionEnvironmentTurnsTheVoidRed() passed after 0.066 seconds.
✔ Test openingPanesGivesEachAUniqueIdAndFocusesTheNewest() passed after 0.066 seconds.
✔ Test decodesTheCredentialsJSON() passed after 0.067 seconds.
✔ Test onlyStructurallyBrokenLinesThrowAndTheyReportTheirIndex() passed after 0.067 seconds.
✔ Test frameReaderEmitsTwoMessagesFromOneChunk() passed after 0.068 seconds.
✔ Test paneCloseOnAnUnknownIdThrowsRatherThanSucceeding() passed after 0.069 seconds.
✔ Test paneColumnWidthIsTotalAgainstDegenerateInput() passed after 0.069 seconds.
✔ Test dispatchingTheMutationInProductionJournalsBlockedAndNeverRunsTheHandler() passed after 0.069 seconds.
✔ Test snapshotReportsRowsInTheDisplayedOrder() passed after 0.070 seconds.
✔ Test anAbsentOrNonObjectInputEchoesEmptyAndStillAllows() passed after 0.071 seconds.
✔ Test exactlyAtTheThresholdSnapsAndBeyondItDoesNot() passed after 0.072 seconds.
✔ Test everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule() passed after 0.071 seconds.
✔ Test allReturnsNonExecutableDescriptorsOnly() passed after 0.074 seconds.
✔ Test dbPaneContentsDropsColumnTypesEntirelyWhenShorterThanColumns() passed after 0.076 seconds.
✔ Test anAllowedToolAnswersAllow() passed after 0.100 seconds.
✔ Test projectNamesWithPathSeparatorsCannotEscapeTheDirectory() passed after 0.103 seconds.
✔ Test toolsCallDispatchesThroughTheRegistry() passed after 0.106 seconds.
✔ Test everyCornerIsWithinTheMaximumOffset() passed after 0.105 seconds.
◇ Test listingTablesDrawsThemAsRows() started.
✔ Test aDensePaneIsSavedAndRestoredDense() passed after 0.108 seconds.
✔ Test dbPaneContentsReadsAnAbsentTruncatedKeyAsComplete() passed after 0.109 seconds.
✔ Test requiredStreamingFlagsArePresent() passed after 0.111 seconds.
✔ Test dbPaneContentsKeepsColumnTypesWhenTheyMatchTheColumnCount() passed after 0.112 seconds.
✔ Test anUnresolvedEnvironmentIsNotProduction() passed after 0.112 seconds.
✔ Test everySubjectCarriesItsDatabase() passed after 0.112 seconds.
✔ Test paneMoveAndResizeChangeTheStore() passed after 0.112 seconds.
✔ Test aSelectionIsClampedToWhatTheNewRowsCanCarry() passed after 0.113 seconds.
✔ Test maximizingAnAlreadyMaximizedPaneIsANoOp() passed after 0.114 seconds.
✔ Test binaryResolutionReturnsNilRatherThanCrashingWhenNothingIsThere() passed after 0.114 seconds.
✔ Test binaryResolutionAcceptsPackageSwiftAsTheCheckoutMarker() passed after 0.118 seconds.
✔ Test aWordBoundaryScoresHigherThanMidWord() passed after 0.117 seconds.
✔ Test binaryResolutionStopsTheAncestorWalkAtTheCheckoutRoot() passed after 0.118 seconds.
✔ Test everySubjectRoundTripsThroughJSON() passed after 0.118 seconds.
✔ Test paneRowAccessibilityLabelPairsEveryColumnWithItsValue() passed after 0.118 seconds.
✔ Test theFirstMutationIsBlockedInProductionAndGatedElsewhere() passed after 0.118 seconds.
✔ Test aPrefixScoresHigherThanAScatteredMatch() passed after 0.120 seconds.
✔ Test anOrdinaryHandlerFailureJournalsErrorAloneWithNoUncertainLine() passed after 0.120 seconds.
✔ Test aRecognisedTypeWithAnUnexpectedPayloadDegradesInsteadOfThrowing() passed after 0.120 seconds.
✔ Test toolCallDecodesAsTheElevenLinesTheFixtureActuallyHas() passed after 0.121 seconds.
✔ Test noSortAndAnUnknownColumnBothLeaveTheOrderAlone() passed after 0.120 seconds.
✔ Test theCursorAtTheCentreMeansNoOffset() passed after 0.126 seconds.
✔ Test linkingTheSamePairTwiceDoesNotDuplicateIt() passed after 0.126 seconds.
✔ Test binaryResolutionTreatsTheEnvironmentOverrideAsExclusive() passed after 0.129 seconds.
✔ Test sessionResumeRefusesAMissingId() passed after 0.129 seconds.
✔ Test threadLiftIsFullWhileATurnIsInFlight() passed after 0.129 seconds.
✔ Test startAfterStopThrowsAlreadyStopped() passed after 0.129 seconds.
✔ Test activeContextCarriesTheActiveProvider() passed after 0.129 seconds.
✔ Test reorderingUsesTheUnsortedRowsSoASecondSortIsNotBuiltOnTheFirst() passed after 0.130 seconds.
✔ Test mutationsAreBlockedOutrightInProduction() passed after 0.130 seconds.
✔ Test aCorruptLayoutDegradesToNilWithANote() passed after 0.130 seconds.
✔ Test toolCallFixtureYieldsToolUsesAndResultsThatMatchByID() passed after 0.130 seconds.
✔ Test movingAPaneUnlinksEveryEdgeItHeld() passed after 0.130 seconds.
✔ Test snappingToANeighbourAlsoLandsWhereThePreviewSaid() passed after 0.130 seconds.
✔ Test readPaneOnAPaneNothingHasWrittenIsAnEmptySnapshotNotAnError() passed after 0.133 seconds.
✔ Test environmentNeverCarriesAnAPIKey() passed after 0.133 seconds.
✔ Test anUnpageableResultSaysSoRatherThanOmittingTheKey() passed after 0.137 seconds.
✔ Test paneRowOverflowsAvailableWidthOnceTheFlooredTotalExceedsIt() passed after 0.138 seconds.
✔ Test aToolUseForAToolWakilNeverConfiguredStillDecodes() passed after 0.138 seconds.
✔ Test aSnapshotReportsWhetherItCanBePagedAndWhereItIs() passed after 0.138 seconds.
✔ Test aFetchDecodedWithAPageSizeAboveTheCapClampsToOneThousand() passed after 0.138 seconds.
✔ Test aNegativeRowIsRefused() passed after 0.139 seconds.
✔ Test loadReplacesOneProjectsArrangementWholesale() passed after 0.139 seconds.
✔ Test matchingIsCaseInsensitive() passed after 0.138 seconds.
✔ Test sortingResetsTheOffsetToZero() passed after 0.139 seconds.
✔ Test pagingMovesTheOffsetByWholePages() passed after 0.139 seconds.
✔ Test paneSnapRejectsAnUnknownEdge() passed after 0.139 seconds.
✔ Test readLayoutOnAnEmptyCanvasIsAnEmptyAnswerNotAnError() passed after 0.139 seconds.
✔ Test removingAPaneRemovesEveryLinkItHeld() passed after 0.153 seconds.
✔ Test aNotificationGetsNoReply() passed after 0.155 seconds.
✔ Test frameReaderPreservesPriorMessagesThenLatchesDecodeErrorOnNextPush() passed after 0.155 seconds.
✔ Test childEnvironmentForwardsOnlyTheKeysItMeansTo() passed after 0.157 seconds.
✔ Test aProductionMutationIsBlockedAndNeverParks() passed after 0.157 seconds.
✔ Test requestsBeforeAnySubscriberAreNotLost() passed after 0.160 seconds.
✔ Test shimModeIsDetectedBeforeAnyUISetup() passed after 0.168 seconds.
✔ Test paneFocusMovesFocusToTheNamedPane() passed after 0.164 seconds.
✔ Test theMidPlaneNeverParallaxes() passed after 0.164 seconds.
✔ Test anUnrecognisedTypeBecomesUnknownRatherThanThrowing() passed after 0.164 seconds.
✔ Test closingTheLastPaneLeavesNoFocus() passed after 0.164 seconds.
✔ Test dbRunMutationRequiresAStatement() passed after 0.164 seconds.
✔ Test aPaneTableFromAnOlderSnapshotIsNotPageable() passed after 0.164 seconds.
✔ Test mutationsAreGatedOutsideProduction() passed after 0.164 seconds.
✔ Test jsonrpcMessageDistinguishesExplicitNullResultFromAbsentResult() passed after 0.164 seconds.
✔ Test allFourStatesExistAndHaveStableRawValues() passed after 0.167 seconds.
✔ Test focusNoLongerDecidesAnything() passed after 0.168 seconds.
✔ Test standardActionNamesAreStableAndNamespaced() passed after 0.175 seconds.
✔ Test scrollToRowRefusesARowIndexThatCannotBeAnIndex() passed after 0.176 seconds.
✔ Test actionsBecomePaletteItemsCarryingTheirName() passed after 0.176 seconds.
✔ Test theAllowListAdmitsControlActionsAndBothReadTools() passed after 0.176 seconds.
✔ Test aColumnWithNoTypeCarriesNil() passed after 0.177 seconds.
✔ Test aMagnitudeFarOutsideInt64RangeFallsBackRatherThanTrapping() passed after 0.177 seconds.
✔ Test sortDirectionRoundTripsThroughItsWireName() passed after 0.177 seconds.
✔ Test thoughtRowCarriesAssistantTextVerbatim() passed after 0.177 seconds.
✔ Test actionKindHasThreeCasesWithStableRawValues() passed after 0.177 seconds.
✔ Test snappingMatchesExtentAndRecordsTheLink() passed after 0.177 seconds.
✔ Test restoreWithNothingMaximizedIsANoOp() passed after 0.178 seconds.
✔ Test anUnregisteredWakilNameIsRefused() passed after 0.184 seconds.
✔ Test shiftExtendsDownwardFromTheAnchor() passed after 0.184 seconds.
✔ Test controlIsAllowedFromTheAgentWhenNoProductionTargetIsNamed() passed after 0.184 seconds.
✔ Test aNeighbourThatDoesNotOverlapAlongTheSharedEdgeIsNotACandidate() passed after 0.185 seconds.
✔ Test resumeNeverAppearsWithoutForkSessionAndASessionId() passed after 0.185 seconds.
✔ Test framesIntersectOnlyWhenTheyOverlapInBothAxes() passed after 0.186 seconds.
✔ Test settingRowsDoesNotDisturbSelectionOrSort() passed after 0.187 seconds.
✔ Test oneAssistantLineWithSeveralBlocksYieldsSeveralEvents() passed after 0.187 seconds.
✔ Test columnsWithNoOverrideDivideTheSpaceEvenly() passed after 0.188 seconds.
✔ Test listeningIsTheOnlyStateThatChangesSpread() passed after 0.188 seconds.
✔ Test aBareActionNameWithoutTheServerPrefixIsRefused() passed after 0.189 seconds.
✔ Test aNewResultStillLeavesTheSelectionAloneWhenItCanCarryIt() passed after 0.189 seconds.
✔ Test selectCellRefusesARowIndexThatCannotBeAnIndex() passed after 0.190 seconds.
✔ Test encodeFrameEndsWithExactlyOneNewline() passed after 0.192 seconds.
✔ Test rowsArrivingUnderAStandingSortAreOrderedToo() passed after 0.193 seconds.
✔ Test recordingASubjectOnAPaneThatIsGoneIsSilent() passed after 0.193 seconds.
✔ Test onePaneCanHoldSeveralNeighboursOnOneEdge() passed after 0.195 seconds.
✔ Test speakingIsTheOnlyStateWhosePulseIsLocalToTheLowerBleed() passed after 0.195 seconds.
✔ Test idleAndListeningKeepTheDesignLanguagesPeriods() passed after 0.195 seconds.
✔ Test jsonrpcErrorDistinguishesExplicitNullDataFromAbsentData() passed after 0.195 seconds.
✔ Test aPaneNeverSnapsToItselfBecauseItIsNotInNeighbours() passed after 0.195 seconds.
✔ Test readPaneIsNotADispatchAndIsNotJournalled() passed after 0.195 seconds.
✔ Test sortIsRecordedAsIntentAndIsNullUntilSet() passed after 0.195 seconds.
✔ Test missingRequiredParamThrowsRatherThanCrashing() passed after 0.195 seconds.
✔ Test aNewPaneIsAiry() passed after 0.195 seconds.
✔ Test paneOpenRefusesAKindThisBuildCannotDraw() passed after 0.195 seconds.
✔ Test sessionSetProviderIsKnownToARegistryBuiltWithoutAnyWindow() passed after 0.195 seconds.
✔ Test updatedInputEchoesTheInputVerbatim() passed after 0.195 seconds.
✔ Test debugScriptReportsTheNumberOfFailedLines() passed after 0.195 seconds.
✔ Test aNullCellIsDistinguishableFromAnEmptyString() passed after 0.195 seconds.
✔ Test rowIndexActionsSayTheyAreZeroBasedPositions() passed after 0.195 seconds.
✔ Test idleHasTheLowestCeilingAndListeningTheHighest() passed after 0.195 seconds.
✔ Test readLayoutIsAdvertisedAndJournalsNothing() passed after 0.195 seconds.
✔ Test dispatchSplitsCRLFScriptsIntoOneDispatchPerLine() passed after 0.201 seconds.
✔ Test pagingBackFromTheFirstPageStaysOnIt() passed after 0.195 seconds.
✔ Test commandClickDeselectsANonAnchorRowAndKeepsTheExistingAnchor() passed after 0.195 seconds.
✔ Test theHeaderTracksHorizontalScrollingAndOnlyThat() passed after 0.195 seconds.
✔ Test aRefusedToolAnswersDenyWithAMessageTheAgentCanRead() passed after 0.195 seconds.
✔ Test journalEntriesAreIdenticalAcrossOriginsExceptForOrigin() passed after 0.195 seconds.
✔ Test anUnsavedEditIsProtectedFromBeingOverwritten() passed after 0.195 seconds.
✔ Test aNamespacedMCPToolNameSurvivesIntact() passed after 0.196 seconds.
✔ Test aFreshLaunchNeverMentionsResume() passed after 0.195 seconds.
✔ Test refusesCredentialsWithAnEmptyField() passed after 0.195 seconds.
✔ Test dispatchRunsTheHandlerAndReturnsItsValue() passed after 0.195 seconds.
✔ Test aPaneCannotBeMovedEntirelyOutsideTheCanvas() passed after 0.195 seconds.
✔ Test theBridgeIsNotOnTheAllowList() passed after 0.195 seconds.
✔ Test linksAreOrderedDeterministically() passed after 0.195 seconds.
✔ Test unknownActionThrowsRatherThanSilentlySucceeding() passed after 0.195 seconds.
✔ Test everyLayoutActionIsRegisteredAsControl() passed after 0.195 seconds.
✔ Test rowsAndTypesRoundTripPerPane() passed after 0.195 seconds.
✔ Test readPaneWithoutAUsablePaneIdIsInvalidParams() passed after 0.195 seconds.
✔ Test environmentIsBuiltExplicitlyNotInherited() passed after 0.195 seconds.
✔ Test threadLiftDecaysToZeroAfterTheLastRow() passed after 0.195 seconds.
✔ Test changingOrClearingTheSortRestatesTheDisplayedOrder() passed after 0.196 seconds.
✔ Test namingNoPaneTargetsNoPane() passed after 0.195 seconds.
✔ Test everyProjectedMCPToolNameSatisfiesTheSameRule() passed after 0.195 seconds.
✔ Test sessionSetProviderNeverReachesTheAllowedToolsList() passed after 0.195 seconds.
✔ Test theThreePlanesCarrySection3sConstants() passed after 0.195 seconds.
✔ Test snappingToTheVoidEdgeMovesWithoutResizing() passed after 0.195 seconds.
✔ Test aReloadedMaximizedLayoutStillRestoresToItsOriginalFrame() passed after 0.195 seconds.
✔ Test aNewPaneIsNotBusy() passed after 0.195 seconds.
✔ Test resizingASnappedPaneResizesItsNeighbourToo() passed after 0.195 seconds.
✔ Test everyStateGetsAtLeastTwentyFiveFramesPerCycleOnASixtyHertzPanel() passed after 0.195 seconds.
✔ Test aLayoutWrittenBeforeSubjectsExistedStillDecodes() passed after 0.195 seconds.
✔ Test aLayoutFileWithoutPreMaximizeFramesStillLoads() passed after 0.196 seconds.
✔ Test aSubsequenceMatchesEvenWhenScattered() passed after 0.196 seconds.
✔ Test anUntouchedLineAdoptsAReQueriedPanesNewDescription() passed after 0.195 seconds.
✔ Test noNeighbourAndNoVoidEdgeInRangeMeansNoCandidate() passed after 0.194 seconds.
✔ Test aRefusedPaneCloseDoesNotDropAnyContents() passed after 0.195 seconds.
✔ Test thePaletteShowsATitleWhenTheSessionHasOne() passed after 0.195 seconds.
✔ Test theOtherWakilServersAreRefused() passed after 0.195 seconds.
✔ Test anUnknownFrameProducesNoRowAtAll() passed after 0.194 seconds.
✔ Test paneOpenDefaultsItsTitleToTheKind() passed after 0.196 seconds.
✔ Test activeContextDefaultsRootPathsToEmptyWhenAbsent() passed after 0.196 seconds.
✔ Test mutationInProductionIsBlockedEvenWithCorrectConfirmation() passed after 0.197 seconds.
✔ Test columnWidthLandsOnThePaneAndPersistsWithIt() passed after 0.197 seconds.
✔ Test contextSettersAreControlAndOnlyTheEnvironmentOneNamesATarget() passed after 0.196 seconds.
✔ Test selectRowsRefusesATrappingAnchor() passed after 0.196 seconds.
✔ Test overridesAloneCanExceedTheWidthAndAreStillHonoured() passed after 0.196 seconds.
✔ Test sessionResumeParksTheRequestAndReturnsWithoutWaiting() passed after 0.197 seconds.
✔ Test focusingAnOffCanvasPaneBringsItBackIntoView() passed after 0.197 seconds.
✔ Test commandClickDeselectingTheAnchorRowItselfMovesTheAnchorToASurvivor() passed after 0.197 seconds.
✔ Test theWireFormatsLayoutIsPinned() passed after 0.197 seconds.
✔ Test aSavedLayoutLoadsBackIdentically() passed after 0.197 seconds.
✔ Test theCoreIsIdleWithNoTurnAndThinkingWithOne() passed after 0.197 seconds.
✔ Test paneTableCarriesTheTruncationFlagAndDefaultsItToFalse() passed after 0.197 seconds.
✔ Test toolsListProjectsTheRegistryPlusBothReadToolsAndTheBridge() passed after 0.197 seconds.
✔ Test densitySurvivesAJSONRoundTrip() passed after 0.197 seconds.
✔ Test scrollClearRemovesAPendingTarget() passed after 0.197 seconds.
✔ Test actingOnAnUnknownPaneThrows() passed after 0.197 seconds.
✔ Test thePromptToolFlagIsBuiltFromTheSameConstantsTheServerAdvertises() passed after 0.197 seconds.
✔ Test aSelectionAlwaysContainsItsAnchorRow() passed after 0.197 seconds.
✔ Test anUntouchedPaneAnswersWithEveryKeyPresent() passed after 0.197 seconds.
✔ Test theMCPSurfaceIsThisAssemblysOwnRegistryAndPaneStore() passed after 0.197 seconds.
✔ Test stateNeverTouchesTheBleedColours() passed after 0.197 seconds.
✔ Test everyRegisteredActionIsAllowedWhenDerivedFromALiveRegistry() passed after 0.196 seconds.
✔ Test commandClickDeselectingTheLastRemainingRowLeavesNoAnchor() passed after 0.196 seconds.
✔ Test noLayoutActionNamesATargetEnvironment() passed after 0.196 seconds.
✔ Test everyStateGetsAtLeastTwentyFiveFramesPerCycle() passed after 0.196 seconds.
✔ Test theAnthropicToolNameRuleHelperRejectsWhatTheRuleRejects() passed after 0.196 seconds.
✔ Test aPaneRoundTripsThroughJSON() passed after 0.196 seconds.
✔ Test paneSetDensityRejectsAnUnknownValue() passed after 0.196 seconds.
✔ Test thoughtRowMarksAFailedTurnAsAnError() passed after 0.196 seconds.
✔ Test paneColumnWidthDividesAvailableWidthEvenlyMinusSpacing() passed after 0.196 seconds.
✔ Test theBridgeRefusesToAnswerAboutItself() passed after 0.196 seconds.
✔ Test shiftExtendsUpwardWhenTheClickedRowIsAboveTheAnchor() passed after 0.196 seconds.
✔ Test allowedToolsReachTheArgvAsOneCommaSeparatedValue() passed after 0.196 seconds.
✔ Test anEmptyPaneStringIsTheSameAsNamingNone() passed after 0.196 seconds.
✔ Test paneSnapAcceptsAnAbsentToPaneIdAsTheVoidEdge() passed after 0.195 seconds.
✔ Test theVoidTheSolverUsesFollowsTheReportedCanvasSize() passed after 0.195 seconds.
✔ Test everyEventThatDescribesWorkStillProducesARow() passed after 0.195 seconds.
✔ Test theDefaultDirectoryHangsOffTheGivenHome() passed after 0.195 seconds.
✔ Test agentMCPConfigNeverExposesThePaneAffectingBinaries() passed after 0.195 seconds.
✔ Test movingThePaneDoesNotMoveTheHeaderOffItsColumns() passed after 0.195 seconds.
✔ Test maximizingASecondPaneRestoresTheFirst() passed after 0.195 seconds.
✔ Test aFetchDecodedWithAZeroPageSizeClampsToOne() passed after 0.195 seconds.
✔ Test aForkCarriesResumeForkSessionAndAFreshSessionId() passed after 0.195 seconds.
✔ Test answeringAPermissionQuestionWritesNothingToTheJournal() passed after 0.198 seconds.
✔ Test dispatchJournalsUnderTheGivenHome() passed after 0.206 seconds.
✔ Test everyActionWithAMissingClientThrowsRatherThanCrashing() passed after 0.198 seconds.
✔ Test anOverriddenColumnKeepsItsWidthAndTheRestDivideWhatIsLeft() passed after 0.198 seconds.
✔ Test productionMatchIsExactAndCaseInsensitive() passed after 0.198 seconds.
✔ Test aSavedPaneOfAnUndrawableKindIsDroppedWithANote() passed after 0.198 seconds.
✔ Test dispatchGatesAnAgentControlActionNamingProduction() passed after 0.198 seconds.
✔ Test shiftWithNoExistingAnchorBehavesLikeAPlainClick() passed after 0.197 seconds.
✔ Test threadLiftClampsANegativeElapsedTime() passed after 0.199 seconds.
✔ Test mixedNumericAndTextValuesStillFormAConsistentOrder() passed after 0.199 seconds.
✔ Test initializeIsAnswered() passed after 0.199 seconds.
✔ Test plainClickCollapsesAMultiRowSelectionToTheClickedRow() passed after 0.199 seconds.
✔ Test resultAppearsButIsNotTheLastEventInEitherFixture() passed after 0.202 seconds.
✔ Test resizingPastASnappedNeighbourFloorsItRatherThanGoingToZero() passed after 0.201 seconds.
✔ Test frameReaderLatchesOverflowForNextPushWhenUnterminatedFrameExceedsCap() passed after 0.213 seconds.
✔ Test rankingDropsNonMatchesAndOrdersByScore() passed after 0.202 seconds.
✔ Test selectRowsRefusesATrappingIndexInsideItsArray() passed after 0.203 seconds.
✔ Test uncertainMutationCarriesTheEnvironmentToo() passed after 0.203 seconds.
✔ Test agentMCPConfigNamesTheShimAndTheAnswerBinaries() passed after 0.203 seconds.
✔ Test controlIsGatedWhenTheAgentTargetsProduction() passed after 0.202 seconds.
✔ Test binaryResolutionFindsTheBundleLayout() passed after 0.203 seconds.
✔ Test journalLinesWrittenBeforeThisFieldExistedStillDecode() passed after 0.202 seconds.
✔ Test rerunningTheSameQueryKeepsTheWholeSelection() passed after 0.202 seconds.
✔ Test paneOpenReturnsTheNewPanesId() passed after 0.203 seconds.
✔ Test everyFixtureLineProducesExactlyOneEvent() passed after 0.205 seconds.
✔ Test paneRowFitsAvailableWidthWhenNoColumnIsFloored() passed after 0.204 seconds.
✔ Test everyRegisteredActionIsReachableIncludingMutations() passed after 0.203 seconds.
✔ Test basicTurnDecodesAsTheThirteenLinesTheFixtureActuallyHas() passed after 0.205 seconds.
✔ Test threadLiftIsZeroWithNoRows() passed after 0.203 seconds.
✔ Test everyBuiltInToolIsRefused() passed after 0.204 seconds.
✔ Test activeContextCarriesTheResolvedRootPaths() passed after 0.204 seconds.
✔ Test paneCloseRemovesThePaneFromTheStore() passed after 0.203 seconds.
✔ Test mutationWithoutConfirmationIsRefusedAndJournalledAsGated() passed after 0.204 seconds.
✔ Test aSendWithNoHarnessLeavesTheCoreIdle() passed after 0.222 seconds.
✔ Test aFetchDecodedWithANegativeOffsetClampsToZero() passed after 0.203 seconds.
✔ Test aMutationTimeoutIsReportedAsUnknownRatherThanAsAFailure() passed after 0.203 seconds.
✔ Test childEnvironmentTakesTheProviderAsAParameterNotFromTheEnvironment() passed after 0.203 seconds.
✔ Test allFiveStillRunWhenPointedAtProduction() passed after 0.203 seconds.
✔ Test dbPaneContentsDropsColumnTypesEntirelyWhenLongerThanColumns() passed after 0.203 seconds.
✔ Test aLayoutOfKnownKindsLoadsWithNoNote() passed after 0.204 seconds.
✔ Test jsonValueRoundTripsNestedStructures() passed after 0.204 seconds.
✔ Test paneSnapshotSerialisesColumnsAndRowsForReadPane() passed after 0.204 seconds.
✔ Test frameReaderSkipsBlankLinesRatherThanFailing() passed after 0.204 seconds.
✔ Test sessionResumeIsControlAndSessionGetIsRead() passed after 0.204 seconds.
✔ Test columnTypesOfTheWrongLengthAreDroppedEntirely() passed after 0.204 seconds.
✔ Test readsAreAllowedInEveryEnvironmentFromEveryOrigin() passed after 0.204 seconds.
✔ Test everyJournalOutcomeCarriesTheEnvironmentTheGateJudged() passed after 0.204 seconds.
✔ Test encodedRequestNotificationAndErrorResponseAllCarryTheJSONRPCVersionTag() passed after 0.203 seconds.
✔ Test aSelectionWithNoSurvivingRowsBecomesEmpty() passed after 0.203 seconds.
✔ Test aLayoutWrittenBeforeColumnWidthsExistedStillDecodes() passed after 0.203 seconds.
✔ Test debugScriptReportsAFailureWithoutAbortingLaterLines() passed after 0.204 seconds.
✔ Test paneOpensSchemaNamesTheKindsItWillAccept() passed after 0.203 seconds.
✔ Test activeContextDefaultsActiveProviderToEmptyWhenAbsent() passed after 0.202 seconds.
✔ Test aMissingRequiredParamThrowsRatherThanDefaulting() passed after 0.203 seconds.
✔ Test comingBackToAProjectFindsItsRowsWhereTheyWereLeft() passed after 0.202 seconds.
✔ Test everyAllowListEntryNamesAServerTheMCPConfigActuallyDefines() passed after 0.204 seconds.
✔ Test paneOpenStillAcceptsTheKindThisBuildDoesDraw() passed after 0.204 seconds.
✔ Test readPaneAdvertisesEverythingItReturns() passed after 0.204 seconds.
✔ Test densityCarriesSection8sRowHeights() passed after 0.203 seconds.
✔ Test aNonSubsequenceDoesNotMatch() passed after 0.202 seconds.
✔ Test frameReaderSplitsOnNewlinesAcrossChunks() passed after 0.202 seconds.
✔ Test aServerWhoseNameMerelyStartsWithWakilIsRefused() passed after 0.204 seconds.
✔ Test mirrorReflectingARegistryYieldsNoChildren() passed after 0.202 seconds.
✔ Test rankingIsStableForEqualScores() passed after 0.202 seconds.
✔ Test anUntouchedLineFollowsTheSubjectEvenWhenNothingChangedAtAll() passed after 0.202 seconds.
✔ Test aControlActionWithNoTargetParamIsNeverGated() passed after 0.202 seconds.
✔ Test busyIsStillNotPersisted() passed after 0.202 seconds.
✔ Test scrollToRowIsRecordedAsATarget() passed after 0.202 seconds.
✔ Test switchingProjectPreservesTheOutgoingArrangement() passed after 0.201 seconds.
✔ Test aThreeDeepChainCollapsesToTheSingleNewestEntry() passed after 0.200 seconds.
✔ Test aGraphRoundTripsThroughJSON() passed after 0.200 seconds.
✔ Test snappingLandsThePaneWhereThePreviewSaidItWould() passed after 0.200 seconds.
✔ Test dbRunMutationIsRegisteredAsTheFirstMutateAction() passed after 0.200 seconds.
✔ Test anOrdinaryMutationFailurePassesThroughUnchanged() passed after 0.200 seconds.
✔ Test aNodePointingIntoASelfCycleDoesNotHangTheWalk() passed after 0.200 seconds.
✔ Test sessionListIsRegisteredAndFailsLoudlyWithoutAClient() passed after 0.200 seconds.
✔ Test aNegativeRowIndexIsStillRefused() passed after 0.200 seconds.
✔ Test aFailedResultDecodesAsAnErrorAndAMissingTextIsNil() passed after 0.199 seconds.
✔ Test aZeroSizedWindowYieldsNoOffsetRatherThanNaN() passed after 0.199 seconds.
✔ Test theAllowListIsExactlyTheRegistrysReadAndControlActionsPlusBothReadTools() passed after 0.199 seconds.
✔ Test aProviderWithNoLabelFallsBackToItsId() passed after 0.199 seconds.
✔ Test paneColumnWidthNeverGoesBelowItsFloor() passed after 0.198 seconds.
✔ Test everyTypeWithoutACaseSurfacesAsUnknownWithItsWireTag() passed after 0.200 seconds.
✔ Test noColumnsIsNoWidths() passed after 0.196 seconds.
✔ Test focusPlaysNoPartInTheDecision() passed after 0.196 seconds.
✔ Test offersDrillOnlyForATableListSubjectIncludingAnEmptyOne() passed after 0.197 seconds.
✔ Test numericColumnsSortNumericallyNotLexically() passed after 0.197 seconds.
✔ Test anUnmeasuredSurfaceDrawsItsHeaderSquare() passed after 0.197 seconds.
✔ Test aParkedRequestReachesTheSubscriber() passed after 0.198 seconds.
✔ Test theSameSelectionFromUiAgentAndDebugJournalsIdentically() passed after 0.197 seconds.
✔ Test dbPaneContentsCarriesTruncatedFromACappedResult() passed after 0.197 seconds.
✔ Test aRowTooShortForTheSortedColumnSortsAsANull() passed after 0.197 seconds.
✔ Test paneSetDensityIsAControlActionAndChangesOnePane() passed after 0.197 seconds.
✔ Test theFooterNamesWhichRowsAreOnScreenOnlyWhenPaging() passed after 0.197 seconds.
✔ Test pagingToAnAbsolutePageMultipliesByThePageSize() passed after 0.197 seconds.
✔ Test thinkingIsTheOnlyStateWithDriftOrAntiphase() passed after 0.197 seconds.
✔ Test busyIsSetAndClearedWithoutTouchingAnythingElse() passed after 0.196 seconds.
✔ Test dbPaneContentsFallsBackRatherThanTrappingOnAnUnusableMillis() passed after 0.200 seconds.
✔ Test dispatchRejectsAnEnvironmentFlagWithNoValue() passed after 0.223 seconds.
✔ Test anotherProjectsPaneOfTheSameNameIsEmpty() passed after 0.199 seconds.
✔ Test aPaneTableCarriesWhereItIsAndWhetherItCanMove() passed after 0.199 seconds.
✔ Test theRunningProviderIsMarkedDistinctlyInItsPaletteRow() passed after 0.199 seconds.
✔ Test journalIsAppendedAsOneJSONLineEach() passed after 0.199 seconds.
✔ Test controlIsAllowedFromTheUIAndDebugEverywhere() passed after 0.199 seconds.
✔ Test dispatchingTheMutationWithoutConfirmationJournalsGated() passed after 0.199 seconds.
✔ Test blankLinesAreSkippedRatherThanTreatedAsMalformed() passed after 0.199 seconds.
✔ Test anUntouchedLineFollowsTheSubject() passed after 0.199 seconds.
✔ Test selectionRoundTripsAndAlwaysContainsItsAnchor() passed after 0.199 seconds.
✔ Test dispatchResolvesRealActionNamesThroughTheSharedWiring() passed after 0.226 seconds.
✔ Test rowsArriveOrderedByTheSortTheyWereGiven() passed after 0.199 seconds.
✔ Test namingAPaneTargetsThatPane() passed after 0.199 seconds.
✔ Test aLinkIsVisibleFromBothSides() passed after 0.199 seconds.
✔ Test orgNamesWithPathSeparatorsCannotEscapeTheDirectory() passed after 0.199 seconds.
✔ Test wiringRegistersEveryStandardActionEvenWithNoBinariesPresent() passed after 0.199 seconds.
✔ Test aPaneSavedBeforeDensityExistedDecodesAsAiry() passed after 0.199 seconds.
✔ Test snapshotOfAnUnknownPaneIsEmptyNotAnError() passed after 0.199 seconds.
✔ Test anUnknownToolIsAnErrorNotACrash() passed after 0.199 seconds.
✔ Test aHeaderDragCannotTakeAColumnBelowTheLayoutMinimum() passed after 0.199 seconds.
✔ Test layoutActionsJournalTheirOrigin() passed after 0.198 seconds.
✔ Test theMotionFieldsAreCarriedThroughUnchanged() passed after 0.198 seconds.
✔ Test closingAPaneDropsItsContents() passed after 0.198 seconds.
✔ Test allFiveAreControlAndNameNoTargetEnvironment() passed after 0.198 seconds.
✔ Test debugScriptDispatchesAndJournalsWithDebugOrigin() passed after 0.199 seconds.
✔ Test rankingSearchesTheSubtitleToo() passed after 0.198 seconds.
✔ Test aNonSQLSubjectDescribesItselfRatherThanPretendingToBeSQL() passed after 0.198 seconds.
✔ Test kitVersionIsSet() passed after 0.200 seconds.
✔ Test sessionIdIsPassedNotGeneratedByTheCLI() passed after 0.198 seconds.
✔ Test nonFiniteNumbersFallBackToDefaultsRatherThanTrapping() passed after 0.197 seconds.
✔ Test snapEdgeOppositesAndAxes() passed after 0.197 seconds.
✔ Test theAgentCannotChooseTheNextLaunchsAccountEither() passed after 0.197 seconds.
✔ Test nullsSortLastInBothDirections() passed after 0.197 seconds.
✔ Test paneTableGivesIdenticalRowsDistinctIdentities() passed after 0.196 seconds.
✔ Test childEnvironmentOmitsTheProviderWhenThereIsNone() passed after 0.196 seconds.
✔ Test columnWidthsSurviveAJSONRoundTrip() passed after 0.196 seconds.
✔ Test aParentWithNoChildInTheListingIsKept() passed after 0.195 seconds.
✔ Test mutationAffectsEveryRowAgreesWithTheGoFixtureTable() passed after 0.196 seconds.
✔ Test aFailedToolResultCarriesItsErrorFlagAndAMissingOneIsFalse() passed after 0.195 seconds.
✔ Test aPaneWithAnOutOfRangeOffsetDecodesToAClampedFetch() passed after 0.195 seconds.
✔ Test namingAPaneWorksWithNoLayoutAtAll() passed after 0.195 seconds.
✔ Test binaryResolutionTreatsAnEmptyEnvironmentOverrideAsSet() passed after 0.195 seconds.
✔ Test frameReaderPreservesPriorMessagesThenLatchesOverflowOnNextPush() passed after 0.226 seconds.
✔ Test anEmptyAllowListOmitsTheFlagEntirelyRatherThanPassingItEmpty() passed after 0.195 seconds.
✔ Test thePaletteFallsBackToTheFirstPromptThenTheId() passed after 0.195 seconds.
✔ Test theSoleSubscriberReceivesEveryRequest() passed after 0.195 seconds.
SWIFT TASK CONTINUATION MISUSE: send(_:) leaked its continuation without resuming it. This may cause tasks waiting on it to remain suspended forever.
✔ Test unlinkingOneEdgeLeavesTheOthersAlone() passed after 0.261 seconds.
✔ Test theWorkingDirectoryIsCarriedOnTheLaunch() passed after 0.261 seconds.
✔ Test theAgentCannotSwitchItsOwnAccount() passed after 0.261 seconds.
✔ Test cellTextMatchesTheOldProjectionForEveryNonNullKind() passed after 0.261 seconds.
✔ Test thoughtRowMarksAFailedToolResultAsAnError() passed after 0.261 seconds.
✔ Test readLayoutReportsPanesFramesFocusAndSnaps() passed after 0.260 seconds.
✔ Test standardActionsAreReadOrControlAndNeverMutateIn2bI() passed after 0.260 seconds.
✔ Test executableIsPinnedByAbsolutePath() passed after 0.260 seconds.
✔ Test aFetchDefaultsToThePageSizeTheDriverAlreadyUses() passed after 0.260 seconds.
✔ Test snapshotsDifferingOnlyInBusyAreTheSameArrangement() passed after 0.261 seconds.
✔ Test paneTableRendersEveryCellOfASnapshot() passed after 0.260 seconds.
✔ Test theAgentsProductionTargetMatchIsCaseInsensitiveToo() passed after 0.260 seconds.
✔ Test aPanesSubjectIsRecordedAndReadBack() passed after 0.260 seconds.
✔ Test paneTableCarriesTypesSelectionAndSort() passed after 0.259 seconds.
✔ Test aPanesRightEdgeSnapsToANeighboursLeftEdge() passed after 0.259 seconds.
✔ Test aBusyPaneIsSavedAndRestoredIdle() passed after 0.261 seconds.
✔ Test selectCellSetsTheAnchorAndCollapsesTheSelectionToItsRow() passed after 0.259 seconds.
✔ Test loadingSomethingNeverSavedIsNilWithNoNote() passed after 0.259 seconds.
✔ Test droppingAPaneForgetsEverythingItHeld() passed after 0.259 seconds.
✔ Test requestDoesNotWaitForTheRequestToBeHandled() passed after 0.259 seconds.
✔ Test theNearestCandidateWins() passed after 0.259 seconds.
✔ Test paneTableStaysTotalOnAShapeItDoesNotRecognise() passed after 0.259 seconds.
✔ Test openedPanesCascadeRatherThanStackingExactly() passed after 0.259 seconds.
✔ Test agentToolsCallMovesLayoutStoreNotJustTheReply() passed after 0.259 seconds.
✔ Test dispatchSkipsBlankLinesRatherThanErroringOnThem() passed after 0.287 seconds.
✔ Test aToolResultWhoseContentIsAJSONStringStaysAString() passed after 0.263 seconds.
✔ Test providerLabelForASetProviderIsThatProviderIdVerbatim() passed after 0.297 seconds.
✔ Test dispatchExitsNonZeroWhenAnyLineErrored() passed after 0.294 seconds.
✔ Test providerLabelForAnUnsetProviderIsTheHonestWordNotAnEmptyString() passed after 0.296 seconds.
✔ Test dispatchExitsZeroAndReturnsRealResultsWhenTheBinariesArePresent() passed after 0.317 seconds.
✔ Test dispatchRejectsAnEnvironmentValueThatIsAnotherFlag() passed after 0.296 seconds.
✔ Test requestsAfterTheSoleSubscriberIsGoneAreDroppedNotHoarded() passed after 0.324 seconds.
✔ Test aSecondProposalIsRefusedWhileOneIsPending() passed after 0.343 seconds.
✔ Test sendingWithNoHarnessSaysSoInsteadOfDoingNothing() passed after 0.299 seconds.
✔ Test aGatedControlActionParksWithADescriptionNotABlankStatement() passed after 0.342 seconds.
✔ Test aDecisionForAStaleIdIsIgnored() passed after 0.342 seconds.
✔ Test commandItemsAreExactlyTheRegisteredActions() passed after 0.343 seconds.
✔ Test approvingAParkedProposalResolvesTheWaiter() passed after 0.341 seconds.
✔ Test parkedMutationJudgesTheEnvironmentAtConfirmationNotAtProposalTime() passed after 0.341 seconds.
✔ Test aSecondCallToEventsCrashesRatherThanSplittingTheStream() passed after 0.322 seconds.
✔ Test cancellingAParkedMutationRefusesTheAgent() passed after 0.335 seconds.
✔ Test aFailedSendClearsTurnInFlightRatherThanLeavingItSet() passed after 0.343 seconds.
✔ Test refusesASwitchToTheProviderAlreadyRunning() passed after 0.317 seconds.
✔ Test aProviderPaletteItemRoutesToSetProviderWithTheRightId() passed after 0.312 seconds.
✔ Test aProductionMutationNeverReachesTheOperator() passed after 0.308 seconds.
✔ Test resumingWithAnUnsetProviderNamesItAsUnsetRatherThanBlank() passed after 0.337 seconds.
✔ Test updatesPublishParkAndRelease() passed after 0.340 seconds.
✔ Test cancellingAParkedProposalResolvesTheWaiter() passed after 0.327 seconds.
✔ Test aParkedProposalExpires() passed after 0.341 seconds.
✔ Test anExpiredConfirmationIsDistinguishableFromARefusal() passed after 0.345 seconds.
✔ Test anAgentProposedMutationParksAndRunsOnceApproved() passed after 0.351 seconds.
✔ Test aModelHoldsATablePerPane() passed after 0.335 seconds.
✔ Test resumingAcrossProvidersIsRefusedAndNamesBoth() passed after 0.328 seconds.
✔ Test refusesWhenTheLookupThrowsAnythingElse() passed after 0.356 seconds.
✔ Test resumingTheSessionAlreadyRunningInThisWindowIsRefused() passed after 0.356 seconds.
✔ Test aLayoutCommitWritesNothingUntilTheOrgAndProjectAreKnown() passed after 0.352 seconds.
✔ Test surfacesTheLookupRefusalVerbatim() passed after 0.351 seconds.
✔ Test earlyClientDisconnectDoesNotKillTheServerOrOtherConnections() passed after 0.361 seconds.
✔ Test refreshPanesAppliesTheRecordedSortIntent() passed after 0.362 seconds.
✔ Test aFreshSessionRunsInTheProjectsFirstRoot() passed after 0.327 seconds.
✔ Test refusesASwitchWhileATurnIsInFlight() passed after 0.360 seconds.
✔ Test aSuccessfulSwitchDispatchesThePersistenceWriteWithTheChosenProvider() passed after 0.362 seconds.
✔ Test aFailedDispatchBecomesVisibleStatusText() passed after 0.323 seconds.
✔ Test runningAPaletteActionDispatchesIt() passed after 0.357 seconds.
✔ Test aFailedTurnAlsoEndsTheThinking() passed after 0.366 seconds.
✔ Test aPaletteSourceThatCannotAnswerSaysSoRatherThanLookingEmpty() passed after 0.344 seconds.
✔ Test aTurnInFlightMakesTheCoreThink() passed after 0.363 seconds.
✔ Test theDebugSinkIsSilentWhenDisabled() passed after 0.361 seconds.
✔ Test unknownEventsAreDroppedButReachTheDebugSinkWhenEnabled() passed after 0.361 seconds.
✔ Test openingAPaneThroughTheModelGoesThroughTheRegistry() passed after 0.339 seconds.
✔ Test aTruncatedPaneIsMarkedTruncatedOnTheWindow() passed after 0.334 seconds.
✔ Test aSuccessfulSwitchClearsTheThreadAndDrawsASeam() passed after 0.367 seconds.
✔ Test aSwitchMintsAFreshSessionRatherThanForking() passed after 0.368 seconds.
✔ Test runningAQueryRefreshesTheTableFromThePaneStore() passed after 0.344 seconds.
✔ Test clickingTheAlreadyFocusedPaneDispatchesNothing() passed after 0.370 seconds.
✔ Test theRebuiltThreadCarriesASeamNamingTheParent() passed after 0.341 seconds.
✔ Test aResumedSessionRunsInTheDirectoryTheTranscriptRecords() passed after 0.362 seconds.
✔ Test aHeaderDragsCommittedWidthReachesTheCanvasThroughTheRegistry() passed after 0.376 seconds.
✔ Test droppedEventsDoNotCollapseRowIds() passed after 0.340 seconds.
✔ Test dispatchFromSurfaceRoutesColumnWidthThroughLayoutNotPaneStore() passed after 0.346 seconds.
✔ Test dispatchFromSurfaceRoutesASelectionThroughPaneStoreAndRefreshesTheTable() passed after 0.347 seconds.
✔ Test cancellingLeavesTheMutationUnrunAndSaysSo() passed after 0.379 seconds.
✔ Test aWindowWithNoActiveProviderCanStillAcquireOne() passed after 0.375 seconds.
✔ Test refusesASwitchWithAProposalParked() passed after 0.342 seconds.
✔ Test sendingStartsTheSessionAndListsTheEventsItProduces() passed after 0.379 seconds.
✔ Test aPersistenceWriteFailureDoesNotUndoTheSwap() passed after 0.360 seconds.
✔ Test anAgentsLayoutDispatchReachesTheCanvasToo() passed after 0.383 seconds.
✔ Test anAgentsDispatchReachesTheScreenWithoutTheOperatorClicking() passed after 0.377 seconds.
✔ Test ctxListProjectsDispatchesThroughToTheRealBinary() passed after 0.347 seconds.
✔ Test callToolSurfacesAServerSideErrorRatherThanHanging() passed after 0.374 seconds.
✔ Test ctxSetEnvironmentRefusesAnEnvironmentTheProjectDoesNotDeclare() passed after 0.388 seconds.
✔ Test openItemsIncludeEveryOpenPane() passed after 0.386 seconds.
✔ Test focusingTheAlreadyFocusedPaneFromTheRailStillDispatches() passed after 0.394 seconds.
✔ Test aParkedResumeRequestIsActedOn() passed after 0.397 seconds.
✔ Test typingTheWrongWordDoesNotConfirm() passed after 0.389 seconds.
✔ Test ctxSetProjectRefusesAProjectFiledUnderAnotherOrg() passed after 0.394 seconds.
✔ Test anOperatorMutationParksAndRunsOnceConfirmed() passed after 0.391 seconds.
✔ Test aResultLandingDuringSendsSuspensionDoesNotStickTurnInFlightBackOn() passed after 0.387 seconds.
✔ Test everyWindowControlDispatchesWithTheUIOrigin() passed after 0.365 seconds.
✔ Test concurrentStopCallsOnTheSameClientAllReturn() passed after 0.389 seconds.
✔ Test selectingAMutationFromCommandKWithNoArgumentsDoesNotPark() passed after 0.390 seconds.
✔ Test aPreviewNearAnotherPaneSurfacesASnapCandidate() passed after 0.388 seconds.
✔ Test clickingAnUnfocusedPaneFocusesIt() passed after 0.384 seconds.
✔ Test ctxSetProviderPersistsThroughTheRealBinaryAndIsVisibleToGetContext() passed after 0.398 seconds.
✔ Test ctxSetProviderRefusesAnUnregisteredProviderId() passed after 0.379 seconds.
✔ Test currentReflectsProjectAndEnvironmentAfterTheActionsSetThem() passed after 0.402 seconds.
✔ Test aResumeThatFailsToStartLeavesTheExistingSessionUntouched() passed after 0.388 seconds.
✔ Test aFailingStartLeavesTheExistingSessionUntouched() passed after 0.402 seconds.
✔ Test resumingReplacesTheHarnessAndRestartsTheEventPump() passed after 0.422 seconds.
✔ Test staleEventsFromTheSupersededHarnessNeverReachTheRebuiltThread() passed after 0.424 seconds.
✔ Test commitingADragThatWasPreviewingASnapDispatchesPaneSnap() passed after 0.425 seconds.
✔ Test rebuiltRowIdsDoNotCollideWithLiveOnes() passed after 0.401 seconds.
✔ Test ctxSetProjectCannotElevateIntoProduction() passed after 0.409 seconds.
✔ Test theShimCarriesJSONRPCBetweenStdioAndTheSocket() passed after 0.414 seconds.
✔ Test openItemsListEveryProviderInTheActiveOrgAndMarksTheRunningOne() passed after 0.445 seconds.
✔ Test openItemsListEveryProjectInTheActiveOrg() passed after 0.503 seconds.
✔ Test aLayoutCommitIsWrittenUnderTheActiveOrgAndProject() passed after 0.556 seconds.
✔ Test concurrentCommitsLeaveTheLatestArrangementOnDisk() passed after 0.561 seconds.
✔ Test aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy() passed after 0.570 seconds.
✔ Test listToolsReturnsWakilCtxToolSet() passed after 0.574 seconds.
✔ Test switchingProjectRestoresItsSavedLayoutAndReportsAnUnreadableOne() passed after 0.580 seconds.
✔ Test returningToAProjectKeepsWhatWasOpenedThereSinceTheLoad() passed after 0.596 seconds.
✔ Test switchingProjectDoesNotCarryOnesRowsIntoTheOthersPane() passed after 0.579 seconds.
✔ Test endingADragCommitsExactlyOneAction() passed after 0.607 seconds.
✔ Test theObservationPumpDoesNothingUntilSomethingIsDispatched() passed after 0.623 seconds.
✔ Test concurrentStartStopCyclesCompleteWithoutDeadlocking() passed after 0.616 seconds.
✔ Test staleEventsFromTheSupersededHarnessNeverReachTheClearedThreadAfterASwitch() passed after 0.607 seconds.
✔ Test startRunsTheChildInTheGivenWorkingDirectory() passed after 0.804 seconds.
✔ Test stdoutLinesArriveAsDecodedEventsNotJustUnknowns() passed after 1.155 seconds.
✔ Test manyLargeFramesOnOneConnectionAreAnsweredInOrderAndInFull() passed after 1.473 seconds.
✔ Test listingTablesDrawsThemAsRows() passed after 1.721 seconds.
◇ Test describingATableDrawsItsColumnsAsRows() started.
✔ Test aLineSplitAcrossTwoReadChunksIsReassembled() passed after 1.898 seconds.
✔ Test stdoutChunksReachTheEventStreamInTheOrderTheyWereRead() passed after 2.370 seconds.
✔ Test stopReturnsPromptlyWhenAGrandchildHoldsStdoutOpen() passed after 2.486 seconds.
✔ Test describingATableDrawsItsColumnsAsRows() passed after 1.282 seconds.
◇ Test describingATableNeedsATableName() started.
✔ Test theLastEventBeforeEOFIsNeverDroppedByTheStreamFinishing() passed after 3.257 seconds.
✔ Test describingATableNeedsATableName() passed after 0.345 seconds.
◇ Test readingATableRecordsItAsTheSubject() started.
✔ Test readingATableRecordsItAsTheSubject() passed after 0.304 seconds.
◇ Test schemaBrowsingObeysTheSameRoutingRuleAsAQuery() started.
✔ Test schemaBrowsingObeysTheSameRoutingRuleAsAQuery() passed after 0.382 seconds.
◇ Test allThreeSchemaActionsAreReadsNotControls() started.
✔ Test allThreeSchemaActionsAreReadsNotControls() passed after 0.289 seconds.
◇ Test aQueryWithNoPaneOpensOne() started.
✔ Test repliesSplitAcrossReadChunksNeverCorruptTheFrameStream() passed after 4.417 seconds.
✔ Test aQueryWithNoPaneOpensOne() passed after 0.303 seconds.
◇ Test aSecondQueryWithNoPaneOpensASecondPane() started.
✔ Test aSecondQueryWithNoPaneOpensASecondPane() passed after 0.300 seconds.
◇ Test aQueryNamingAPaneRefinesItInPlace() started.
✔ Test aQueryNamingAPaneRefinesItInPlace() passed after 0.298 seconds.
◇ Test aQueryRecordsTheSubjectIncludingItsDatabase() started.
✔ Test aQueryRecordsTheSubjectIncludingItsDatabase() passed after 0.302 seconds.
◇ Test namingAPaneThatIsNotOpenIsStillAnError() started.
✔ Test namingAPaneThatIsNotOpenIsStillAnError() passed after 0.299 seconds.
◇ Test aQueryAtAnOffsetRecordsWhereThePaneIs() started.
✔ Test aQueryAtAnOffsetRecordsWhereThePaneIs() passed after 0.294 seconds.
◇ Test theResultTellsTheAgentWhichPaneItLandedIn() started.
✔ Test theResultTellsTheAgentWhichPaneItLandedIn() passed after 0.296 seconds.
◇ Test dbRunQueryWritesToTheNamedPane() started.
✔ Test dbRunQueryWritesToTheNamedPane() passed after 0.312 seconds.
◇ Test dbRunQueryStillDefaultsToTheDbPane() started.
✔ Test dbRunQueryStillDefaultsToTheDbPane() passed after 0.307 seconds.
◇ Test dbRunQueryWithNoPaneParamOpensANewPaneRatherThanReusingTheOneAlreadyOpen() started.
✔ Test dbRunQueryWithNoPaneParamOpensANewPaneRatherThanReusingTheOneAlreadyOpen() passed after 0.316 seconds.
◇ Test dbRunQueryRefusesAPaneThatIsNotOpen() started.
✔ Test dbRunQueryRefusesAPaneThatIsNotOpen() passed after 0.294 seconds.
◇ Test dbRunQueryAcceptsThePaneIdThatPaneOpenMinted() started.
✔ Test dbRunQueryAcceptsThePaneIdThatPaneOpenMinted() passed after 0.300 seconds.
◇ Test dbRunQueryNamesThePaneItDrewInto() started.
✔ Test dbRunQueryNamesThePaneItDrewInto() passed after 0.290 seconds.
◇ Test dbRunQueryWithNoPaneOpenOpensOneAndDrawsInIt() started.
✔ Test dbRunQueryWithNoPaneOpenOpensOneAndDrawsInIt() passed after 0.176 seconds.
◇ Test dbRunQuerySaysItsResultReplacesThePaneAndNamesTheCap() started.
✔ Test dbRunQuerySaysItsResultReplacesThePaneAndNamesTheCap() passed after 0.320 seconds.
◇ Test refetchingRunsThePanesOwnSubject() started.
✔ Test refetchingRunsThePanesOwnSubject() passed after 0.288 seconds.
◇ Test eachSubjectRefetchesThroughItsOwnTool() started.
✔ Test eachSubjectRefetchesThroughItsOwnTool() passed after 1.172 seconds.
◇ Test refetchingAPaneWithNoSubjectIsAnError() started.
✔ Test refetchingAPaneWithNoSubjectIsAnError() passed after 0.308 seconds.
◇ Test pagingMovesTheOffsetAndRerunsTheSubject() started.
✔ Test racingStartAndStopNeverLeavesAnOrphan() passed after 10.864 seconds.
✔ Test pagingMovesTheOffsetAndRerunsTheSubject() passed after 0.296 seconds.
◇ Test pagingBackFromTheFirstPageStaysThereAndStillRedraws() started.
✔ Test pagingBackFromTheFirstPageStaysThereAndStillRedraws() passed after 0.302 seconds.
◇ Test pagingToANonsenseDestinationIsRefusedNotDefaulted() started.
✔ Test pagingToANonsenseDestinationIsRefusedNotDefaulted() passed after 0.301 seconds.
◇ Test pagingAPaneWhoseResultIsNotPageableIsRefusedAndLeavesTheOffsetUntouched() started.
✔ Test pagingAPaneWhoseResultIsNotPageableIsRefusedAndLeavesTheOffsetUntouched() passed after 0.306 seconds.
◇ Test classifyingAStatementAsksTheGates() started.
✔ Test classifyingAStatementAsksTheGates() passed after 0.310 seconds.
◇ Test allThreeTask11ActionsAreReadsNotControls() started.
✔ Test allThreeTask11ActionsAreReadsNotControls() passed after 0.314 seconds.
◇ Test sortingACompleteResultOrdersItInPlaceWithNoRoundTrip() started.
✔ Test sortingACompleteResultOrdersItInPlaceWithNoRoundTrip() passed after 0.311 seconds.
◇ Test sortingATruncatedResultRequeriesAtPageOne() started.
✔ Test sortingATruncatedResultRequeriesAtPageOne() passed after 0.358 seconds.
◇ Test sortingAPagedButUntruncatedResultStillRequeries() started.
✔ Test sortingAPagedButUntruncatedResultStillRequeries() passed after 0.321 seconds.
◇ Test clearingASortClearsItOnThePaneToo() started.
✔ Test clearingASortClearsItOnThePaneToo() passed after 0.309 seconds.
◇ Test aBadDirectionIsStillRefusedRatherThanDefaulted() started.
✔ Test aBadDirectionIsStillRefusedRatherThanDefaulted() passed after 0.307 seconds.
◇ Test paneSortIsAReadNowBecauseItCanReachADatabase() started.
✔ Test paneSortIsAReadNowBecauseItCanReachADatabase() passed after 0.312 seconds.
◇ Test runFromQueryLineRoutesAReadToDbRunQuery() started.
✔ Test runFromQueryLineRoutesAReadToDbRunQuery() passed after 0.298 seconds.
◇ Test runFromQueryLineRoutesAMutationToDbRunMutationAndParksForConfirmation() started.
✔ Test runFromQueryLineRoutesAMutationToDbRunMutationAndParksForConfirmation() passed after 0.305 seconds.
◇ Test runFromQueryLineRefusesNeitherAndDispatchesNothingFurther() started.
✔ Test runFromQueryLineRefusesNeitherAndDispatchesNothingFurther() passed after 0.297 seconds.
◇ Test aRefusalRaisedInOnePaneDoesNotAppearUnderAnother() started.
✔ Test aRefusalRaisedInOnePaneDoesNotAppearUnderAnother() passed after 0.304 seconds.
◇ Test runFromQueryLineRerunsAnUnchangedNonSQLSubjectAsItselfRatherThanAsText() started.
✔ Test runFromQueryLineRerunsAnUnchangedNonSQLSubjectAsItselfRatherThanAsText() passed after 0.360 seconds.
✔ Suite SubprocessDBActionTests passed after 15.941 seconds.
✔ Test run with 583 tests in 2 suites passed after 15.945 seconds.
Building for debugging...
[0/4] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.12s)
Test Suite 'Selected tests' started at 2026-09-12 18:30:01.176.
Test Suite 'WakilPackageTests.xctest' started at 2026-09-12 18:30:01.178.
Test Suite 'WakilPackageTests.xctest' passed at 2026-09-12 18:30:01.178.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-12 18:30:01.178.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
◇ Suite StopDeliversTheTailOfTheStreamSuite started.
◇ Test stopDeliversTheTailOfTheStreamRatherThanDiscardingIt() started.
✔ Test stopDeliversTheTailOfTheStreamRatherThanDiscardingIt() passed after 2.410 seconds.
✔ Suite StopDeliversTheTailOfTheStreamSuite passed after 2.410 seconds.
✔ Test run with 1 test in 1 suite passed after 2.410 seconds.
```
Exit 0. **583 tests in 2 suites, plus the 1 isolated `swift test` invocation** —
`phase-2b-v-acceptance.md` §3 explains why that one runs alone.

**The DB action tests now live in a serialized suite, and that is a recorded cost, not a
regression.** Their harness spawns a real subprocess per test, and roughly 22 of them
running in parallel were timing out the MCP `initialize` handshake against each other.
The suite is green but slower for it — about 22s against about 17s before the move. See
§6.

```
$ make app-build
xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal
cd app && swift build
[0/1] Planning build
Building for debugging...
[0/4] Copying default.metallib
[1/4] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.20s)
```
Exit 0.

All five: **green.** Together with §3's `make bench-surface`, every command Task 16's
brief names has been run on this tree and pasted here in full.

**These outputs are the state of the tree on 2026-09-12 before the final whole-branch
review's fix wave.** That wave fixed twelve findings — among them two that made checks
below unwalkable: `Pane.fetch` never reached disk at all (checks 11 and 12 tested a
feature nothing could reach), and the database chooser spec §5 requires had not been
built (check 3 is written as though it exists). All six commands were re-run after it,
green, with the suite now at **605 tests in 2 suites plus the 1 isolated invocation**;
the outputs are pasted in full in
`.superpowers/sdd/2026-09-12-phase-2c-ii-db-pane/final-fix-report.md`. Nothing in §2 was
narrowed to accommodate any of it.

## 5. Defects found during the walk

**Walked by the operator on 2026-09-13**, against `staging` (`core` MySQL, `events`
sqlite, `docs` Mongo) and `production`. All fourteen of §2's checks were reached, check 11
twice. Twelve defects were found.

**2c-i's instruction to this phase was to assume a fifth cause of "rows returned, nothing
on screen" exists. It does — D12.** A pane whose refetch failed draws `no rows`, because
`DBPane` keys that message on `table.columns.isEmpty` alone, which is equally true of a
query that returned nothing, a pane never fetched, and a fetch that errored. The failure
was known and written to the journal; only the surface stayed quiet. `Pane.swift:124`
already names the third cause in this family, from 2c-i's own walk.

Everything else here is one theme in four voices: **a pane, or the window, saying
something untrue about what it is pointed at.** D11 keeps a previous environment's rows
under the new environment's banner. D12 reports a failed fetch as an empty one. D8b keeps
pre-mutation rows after the mutation ran. D3 and D10 are the agent's half of the same
theme — it declined to draw a pane the operator had closed because it had already answered
in chat, and it moved the active environment unasked. Neither of those last two is a code
defect; both are the agent's instructions.

### D3 — the agent answers in chat instead of drawing, and treats a repeat as redundant

**Fixed** — `ae7a488`, `4050490`. Wakil now passes `--append-system-prompt`; before this it passed the agent no system prompt at all, which is why it reasoned about the conversation. **Settled only at the re-walk:** whether an agent so instructed actually draws the pane is not a property of a string, and no test reaches it (spec §5.4).

**Check 8 / check 9, blocking.** The operator closed a `db` pane and asked for the same
thing again. The agent replied *"You've asked this exact same question four times in a
row now, and the answer hasn't changed"*, and on the next ask *"I'll hold off repeating
the same query a sixth time since nothing indicates it will produce a new result."* No
pane was opened. The rows existed; the agent decided the operator did not need to see
them.

Two separate errors are tangled here:

1. **A closed pane is not a cached answer.** The agent is reasoning about the
   *conversation* — have I said this before — when the operator is reasoning about the
   *canvas*: is it on screen. Asking again after closing a pane is not repetition, it is
   the only way to get the pane back.
2. **Chat is not a substitute for a pane.** Answering "the `events` database has 2
   tables" in the transcript satisfies nothing this phase built. The whole point of a
   `db` pane is that the result is a surface the operator can sort, page and drill, not
   a sentence.

**Where it lives:** not in Swift and not in Go. This is the agent's instructions — what
Wakil tells the model about when to call `db_list_tables` and what a pane is for. Every
mechanism 2c-ii built worked; the agent chose not to use it.

**Why the tests did not catch it.** Nothing in 605 tests exercises the agent's judgement.
`db_list_tables` has tests; *deciding to call it* has none and cannot easily have one.

### D10 — the agent changes the active environment without being asked, and without saying so

**Fixed** — `bb8a83a`, `16f3047`. `writeGate` now gates an agent `.control` switch with `production` on **either** side, not only when entering it. The confirmation plane shows a human sentence ("switch the active environment to staging") rather than the action and its JSON.

**Check 11, blocking.** The operator switched to `production` from the UI, worked there,
and then — with no prompt asking for it — the agent called
`ctx_set_environment {"name":"staging"}` and carried on. The journal is unambiguous:

```
05:02:52  ui     ctx_set_environment {"name":"production"}   ok
05:02:56  ui     pane_close db-23, db-22
05:03:16  agent  db_list_databases                           (production)
05:03:55  agent  ctx_set_environment {"name":"staging"}      ok   <- unasked
05:03:57  agent  db_list_tables {"database":"docs"}          (staging)
05:04:11  ui     db_read_table describe_me                   (staging)
          quit
05:04:18  ui     db_refetch db-24, db-25, db-26              (staging)
```

The apparent symptom — "I quit on production and reopened on staging" — is **not** a
persistence bug. Persistence behaved: `active.json` read `staging` at quit because the
agent had put it there, every pane alive at quit was a staging pane, and relaunch restored
exactly those. `~/.wakil/layouts/personal/wakil-acceptance.json` holds their subjects
faithfully.

**Why this is blocking and not cosmetic.** The active environment is the single piece of
state that decides whether a mutation is frightening. The confirmation plane prints
`STAGING` in red because that word is load-bearing — it is the operator's whole basis for
typing `confirm` quickly or slowly. An agent that can move it silently makes the banner
untrustworthy, and a banner the operator has learned to distrust is worse than no banner.

Same family as D3: the agent treating Wakil's state as its own scratch space rather than
the operator's. D3 is the agent declining to act on the canvas; D10 is the agent acting
on the context unasked. Both are instruction defects, and both are invisible to every
test in §3 and §4.

**Side effect on this walk:** check 11 did not run. It must be re-walked, and the re-walk
should confirm the environment banner still reads `production` immediately before quitting.

### D11 — switching environment does not invalidate open panes

**Fixed** — `0dc7f3f` (operator's switch), `ae0a89a` (the agent's). The second was found by the final whole-branch review: D11's original fix lived only in `WindowModel.setEnvironment`, whose sole caller is the UI chooser, so an agent switch left every pane stale — and, worse, left `writeGate` judging a stale environment, making a production mutation merely gated instead of blocked. `observationPump` now refreshes the context and refetches on `ctx_set_environment` whoever asked for it.

**Check 11 re-walk, blocking. Seen live, not inferred.** With the banner reading
`environment: production`, three panes on the canvas showed `core - tables`
(customers, events), `docs - tables` (seven collections) and `docs - describe_me`
(one Mongo document, `_id 6aa580e028d7af3157d4c345`).

**`production` has no `docs` database.** It defines exactly one, `core`. Every row in
those two panes came from `staging`, and they sat there under a `production` banner until
the app was quit. Quitting is what corrected it: on relaunch all three panes refetched
against the real environment, `core` resolved, and the two `docs` panes failed (D12).

**The cause.** `WindowModel.setEnvironment` dispatches `ctx_set_environment`, calls
`refreshContext()`, and stops. Open `db` panes are neither refetched nor cleared, so they
keep the previous environment's rows indefinitely.

This is the persistence boundary's own rule broken from the other side. Rows are refused a
place on disk because redrawing yesterday's rows would show a database state that may no
longer exist — and here the same rows survive a change that guarantees they describe a
different database entirely. The relaunch path already does the right thing
(`restorePaneContents` refetches every `db` pane with a fetch); the environment-switch
path simply never learned to.

**The fix is one line of intent:** `setEnvironment` must do what relaunch does. Calling
`restorePaneContents()` after `refreshContext()` makes the switch behave exactly like a
relaunch into that environment, which is what the operator means by it.

**The design question underneath still needs a decision.** The layout file is keyed
`~/.wakil/layouts/<org>/<project>.json` — **not** per environment — so `production` and
`staging` share one pane arrangement. Two ways out:

1. **Re-fetch every `db` pane on an environment switch.** The arrangement is preserved and
   each pane redraws against the new environment; a pane whose database is absent shows
   that, once D12 is fixed.
2. **Key the layout per environment.** Each environment keeps its own arrangement, at the
   cost that quitting on `production` and reopening on `staging` shows a different canvas.

**Recommended: (1)**, and it is what the relaunch path already implements.

### D12 — a pane whose fetch failed draws "no rows"

**Fixed** — `ccc5c04` (the state), `69274d9` (the three call sites), `290ab0e` / `4111d62` (the drawing). A pane now carries a failure distinct from an empty result, and draws it **above** its retained rows rather than in place of them.

**Check 11 re-walk, blocking.** Reopened on `production`, the two panes whose subject is
the `docs` database drew **`no rows`**. The journal for the same three refetches:

```
db_refetch {"pane":"db-24"}  environment: production  ok      <- core - tables
db_refetch {"pane":"db-25"}  environment: production  error   <- docs - tables
db_refetch {"pane":"db-26"}  environment: production  error   <- docs - describe_me
```

`production` defines one database, `core`. There is no `docs` there, so both refetches
failed — correctly. The pane then reported that failure as an empty result.

**Those two statements mean opposite things.** "No rows" says *I looked in `docs` and
found nothing*. The truth is *`docs` is not a database in this environment*. One is a fact
about the data; the other is a fact about the pane's subject being unresolvable, and the
operator cannot act on the second while being told the first.

**Where it lives.** `DBPane.swift:72` draws `no rows` on one condition —
`table.columns.isEmpty` — which is true in three unrelated states: the query returned no
rows, the pane has never been fetched, and the fetch failed. `restorePaneContents`
discards each dispatch result with `_ =`, so nothing marks the pane as failed;
`WindowModel.dispatch` does set `status`, but the loop overwrites it once per pane, so two
failures leave one message in the window's status line and nothing at all on either pane.

**This is the fourth appearance of a cause this codebase has already named.**
`Pane.swift:124` records the third, from 2c-i's walk — *"Three panes reading 'no rows'
again, from a third cause."* 2c-i's instruction to this phase was to assume a fifth cause
of "rows returned, nothing on screen" exists. It does, and this is it: the rows were never
returned, the failure was known and journalled, and the surface said nothing.

**The fix has two halves**, and both are needed: `PaneStore` must carry a failed state
distinct from an empty one, and `DBPane` must draw the error where the rows would go
rather than falling through to `no rows`.

### D13 — a failed query leaves the pane showing stale rows, with the error only in the status line

**Third walk, 2026-09-13. New.** A pane on `events` (sqlite) was showing 500 rows of the
`events` table, sorted by kind. The operator typed `show tables` into its query line and
pressed Return. sqlite has no `SHOW TABLES`, so it failed — correctly. What the pane then
showed:

- the query line read **`show tables`**,
- the grid still showed the **previous `events` rows**,
- the footer still said **"sorted by kind within the 500 returned"**,
- and the only sign of failure was one line at the bottom of the *window*:
  `db_run_query: query failed: SQL logic error: near "show": syntax error (1)`.

**This is D12 surviving in the one call site nobody wired.** D12's fix taught three call
sites to record a per-pane failure — `restorePaneContents`, `refetchPane(id:)` and
`pagePane(id:to:)`. `WindowModel.runQuery` still ended with `_ = await dispatch(...)`,
discarding the result exactly as all four once did.

So the same defect the walk opened with — a pane reporting a failure as something else —
remained reachable by the most ordinary action in the application: typing a query and
pressing Return. The per-task reviews could not see it because D12 was scoped to the refetch
path, and the whole-branch review read the three sites that had been changed rather than the
fourth that had not.

**Fixed** — `runQuery` now records the failure like its three siblings, and `DBPane` draws it
above the retained rows.

### D8b — a confirmed mutation does not refresh the pane

**Fixed** — `03c7b19`, `d7807ac`. `runMutation` refetches the pane's own subject, and only when the mutation actually ran: a cancel and a refusal both leave the pane alone.

**Check 10, important.** After typing `confirm` and running `update events set
customer_id = 42 where id = 3`, the confirmation plane closed and the query line
correctly returned to the pane's real subject (`events`) — but **the rows on screen were
not re-fetched.** The pane went on showing `customer_id = 7` for `id = 3`, which is a
value the database no longer held.

This is the persistence boundary's own argument turned against the pane: rows are never
allowed to outlive the state they describe, and here they did, by the one action
guaranteed to have invalidated them.

The query-line reset itself is **correct and intended** — it is Task 14's fix. A
mutation is not a pane's subject, so the line must snap back to what the pane is
actually reading. What is missing is the re-fetch that should follow.

### D4 — scroll position survives a page change

**Fixed** — `9345e35`. Keyed on `offset` rather than `scrollTarget`, because two consecutive pages both want row 0 and `scrollTarget` would not change between them. Unanimated.

**Check 4, important.** Scrolled to the middle of page two, pressing `›` draws page three
with the scroll offset unchanged — the operator lands mid-result on rows they have not
seen the top of. A new page is a new result; it must start at its first row.

Paging is otherwise correct in both directions, with no repeated or skipped row.

### D7 — a gate refusal discards what the operator typed

**Fixed** — `a885a2e`, and **the first fix was wrong**. This spec misdiagnosed the cause as `shouldAdoptSubject`; the final review found the actual culprit is `restoreQueryLine`, which the refusal branch called and whose handler sets the line unconditionally. A refusal no longer restores; a mutation still does.

**Check 10, important.** Typing `upadte events set customer_id = 42 where id = 3` (note
the transposed letters) produced the right refusal — *"only INSERT/UPDATE/DELETE
statements are allowed"* — and then **reverted the query line to the pane's subject**,
throwing away the text with the typo in it.

The operator now has to retype the whole statement to fix two characters. A refusal is
the one outcome where the draft is most worth keeping: it is wrong, it is known to be
wrong, and the operator is the only one who can correct it.

### D5 — a one-column sort is drawn as an arrow, a two-column sort is written as text

**Fixed** — `8a81593`, `7544f33`, `d7b953c`, `f581bb4`, `142748c`, `2d81329`, `6daa75c`. The sort became an ordered list end to end (Go, wire, Swift), every sorted column carries its arrow with a precedence ordinal, a second click refines rather than replacing, and dropping one term no longer clears the rest. Mongo's `$sort` became a `bson.D` — as a Go map its key order was undefined, so a two-column sort would have varied between runs of the same query.

**Check 14, important.** Sorting by one column shows a ▼ in that column's header and
leaves the query line unchanged. Sorting by a second column writes `ORDER BY …` into the
query line and **the arrow disappears**. Both states are individually defensible — one
is `PaneFetch.sort`, which `QuerySort` can express; the other is SQL, which it cannot —
but the operator sees a sort that sometimes is text and sometimes is a glyph, with no
rule they can learn.

Filtering does not have this problem: a filter is always written into the line.

### D2 — `SHOW TABLES` produces rows you cannot open, `db_list_tables` produces rows you can

**Fixed** — `b9e6a8b`, `39bf8b8`, `9a07950`. Drillability is now **declared by the driver**, never inferred from the shape of the rows: `SQLReadListsTables` recognises a bare `SHOW TABLES` where the read-only gate already reads the verb. Deliberately narrow — `SHOW FULL TABLES` and `SHOW TABLES FROM other` stay undrillable, and the spec §11.3 says why.

**Check 8/9, important.** Typing `show tables` into the query line returns the table list
and the rows highlight on click, but there is **no drill affordance** — nothing opens a
table from that result. Asking the agent for the same list (subject `.tables`) gives every
row an `open` button.

The mechanism is exactly as designed: `offersDrill` keys on the pane's *subject*, and a
typed `SHOW TABLES` is a `.sql` subject like any other. Wakil is refusing to guess that a
one-column result of table-ish strings is a table list — which is the right instinct and
the wrong outcome. The operator cannot see the distinction that decides it.

### D6 — the scrollbar covers the drill button

**Fixed** — `68a95b1`. Padding, not concealment: the scroller is the only indication of position in a 500-row page.

**Check 9, minor.** On a schema pane the vertical scrollbar is drawn over the trailing
edge of the row, clipping the hover-revealed `open` button to `ope`. The button is still
clickable at its left edge, but it reads as broken.

### D9 — the footer overflows when the pane is narrow

**Fixed** — `68a95b1`, `f7d1e84`. The footer truncates on one line, and `rows`, the range and `read-only` carry the layout priority that makes them the segments which survive narrowing.

**Side note during the walk, minor.** Resized small, the footer's three segments
(`500 rows`, `rows 1–500 · more remain`, `read-only`, plus `sorted by id within the…`)
wrap to one character per line, producing a column of vertical letters. The footer needs
to truncate, not wrap.

### D1 — a table subject shows the table's name where the operator expects a query

**Check 1, by design, recorded for the record.** The query line on a pane opened by
`db_read_table` reads `EVENTS ▸ events` — the subject is a table, so the line shows the
table. The operator expected to see the SQL that produced the rows.

There is no SQL to show: nothing composed a `SELECT`, and inventing one for display
would be Wakil claiming to have run a statement it did not run. The line is editable, and
typing SQL into it converts the pane to a `.sql` subject, which is how the operator gets
the query they wanted. **No change proposed** — but the confusion is real and belongs in
whatever 2c-iv does about the query line's affordance.

### What was confirmed working

Checks 2, 3, 5, 6, 7 and 14's routing all held, including the two this phase most
expected to fail:

- **Check 2 — ⌘↩ on a real key window.** The probe could not test this and warned the
  per-pane shortcut might answer for the wrong pane. It does not. It runs the pane the
  operator is typing in.
- **Check 14 — the routing inversion.** `query table A` → filter → filter → sort all
  refined pane one; `query table B` opened pane two, unprompted and correctly. This is
  the flow the operator described when the phase was designed, and it works as described.
- **Check 5** — a sort on page three returns to page one, sorted over the whole result.
- **Check 7** — a query carrying its own `LIMIT 5000`, sorted, still reports "sorted by
  … within the …" rather than claiming a whole-table ordering.
- **Check 9's Mongo half** — opening a Mongo collection from the schema list works,
  which the `.table` subject exists specifically to make possible.

**Checks 12 and 13 — relaunch and the journal — both hold.** A schema pane and a paged
pane each came back where they were left, and the same query issued from the line and from
the agent differs in nothing but `origin`. This is the half of the phase whose two worst
bugs (a `fetch` that never reached disk; an offset that overflowed into a SIGTRAP) were
caught by review rather than by a test, and it is now walked.

**Check 11's relaunch is correct, and was the only honest thing on screen.** Reopened on
`production`, every `db` pane refetched against the real active environment rather than
trusting anything it had been showing. That is what exposed D11 and D12 — the arrangement
survived, `core` resolved, and the two panes whose database does not exist in `production`
failed, exactly as they should have. The relaunch path is also where D11's fix already
lives: `restorePaneContents` is the behaviour `setEnvironment` needs to borrow.

## 6. What a review left open

None of these block this phase. They were found by this build's own reviews, judged out
of scope for a fix here, and are recorded so they are not rediscovered from scratch at
the walk or in 2c-iv/2c-v.

- **`drillTarget`'s `!first.isNull` guard is unreachable through the public API.**
  `PaneCell`'s only initializer makes `isNull == true` imply empty text, so
  `!first.text.isEmpty` already subsumes it. Kept as a statement of intent rather than
  removed.
- **`schemaPaneContents` supplies `key: false` only when the field is absent.** A
  non-boolean `key` value from a future driver would pass through unchanged into a column
  declared `BOOLEAN`. No driver sends a non-boolean `key` today, and no driver populates
  `wakilcore.Column.Key` at all — this is latent, not live.
- **`pagePane`, `refetchPane`, `classifyStatement` and `restorePaneContents` on
  `WindowModel` have no dedicated unit tests.** Their per-pane failure isolation and their
  empty-parameter omission are established by reading the code, not by a test asserting
  it.
- **`DBPane.pageControls()`'s visibility condition duplicates `rowRangeDescription`'s
  guard by hand** (`table.pageable, table.truncated || table.offset > 0`) rather than the
  two sharing one named property. They agree today because they were written together;
  nothing enforces that they keep agreeing.
- **The DB action tests had to be moved into a serialized suite.** Their harness spawns a
  real subprocess per test, and roughly 22 of them running in parallel were timing out the
  MCP `initialize` handshake against each other. The suite is green but slower for it —
  about 22s against about 17s before the move (§4).

## 7. Result

**Walked three times: 2026-09-13 (twice for check 11), then a third walk of all fourteen
checks after the fix round. Thirteen defects found in total; twelve fixed.**

### The third walk

Twelve of the fourteen checks passed. **The two that had made the phase not-met both pass
now**, and they are the ones no test could have settled:

- **D3** — asked for a table it had already described, the agent opened a fresh pane and
  confirmed it with `read_pane`, instead of declining because it had answered before.
- **D5's agent half** — asked to sort by two columns, the agent issued two `pane_sort`
  calls and produced `▲1` / `▲2` with "sorted by id, kind within the 500 returned", rather
  than abandoning the mechanism and writing `ORDER BY` into the SQL.
- **D10** — asked on `production` for a Mongo collection that only exists on `staging`, the
  agent answered *"There's no Mongo database in this environment — only `core` (MySQL) is
  listed"* and **did not switch**. The gate was never even reached, because the behaviour it
  guards no longer happens.
- **D7** — the refused statement stayed in the line, under its refusal. Its first fix was
  wrong and looked right; this one was walked.

### What the third walk found

**D13**, recorded in §5: a failed *query* left the pane showing stale rows with the error
only in the window's status line. D12's fix had reached three call sites and not the fourth
— the one reached by typing a query and pressing Return. Fixed.

### Two things accepted rather than walked, named so the record stays honest

**The `SHOW TABLES` drill against MySQL was never seen on screen.** Both attempts ran it
against `events`, which is SQLite and has no such statement, so what they exercised was the
error path, not the drill. The operator accepted check 8 on the strength of the code and its
tests — `SQLReadListsTables` is red-verified in Go against a live MySQL, and `offersDrill`'s
two sources are pinned in Swift — rather than walking it a third time. **Recorded here
because "passed" and "accepted without walking" are different facts**, and this document's
whole purpose is that a surface says what it knows.

### One check could not be run, and the reason is worth recording

**Check A2 — a mutation blocked in `production` — did not exercise the write gate.** The
agent refused it on its own: *"the `core` database is marked `writable: false` in this
environment — no mutation can run against it by any route."* It never called
`db_run_mutation`, so `writeGate` was never consulted.

This project's `production` defines one database, `core`, with no `writeRef`. The connection
is read-only before the gate is reached, so **there is no way to exercise the production
block in this environment at all**. Two independent defences, the outer one firing first.
That is the right shape for a safety property and the wrong shape for a test: the gate's
production block remains covered by unit tests and by the truth table in the fix round's
review, and not by this runbook. An environment with a writable production database would be
needed to walk it, and creating one to test a block is a poor trade.

### Verification

`make test`, `make vet`, `make app-test`, `make app-build` and `make bench-surface` green.
**`make test-live` could not be run** — the Docker daemon stopped mid-session — but no `.go`
file changed after `7544f33`, where it last ran green with both engines up and nothing
skipped.

### Verdict

**2c-ii is met, by a walked runbook**, on the same terms
`phase-2c-i-acceptance.md` was:
every check in §2 run by the operator against the live app, defects recorded in §5 rather
than explained away, and the two judgement calls no command can make — whether an instructed
agent actually draws, and whether the context stays the operator's — answered at the window.

D13 was found *by* the third walk, so the walk that establishes "met" is the one that found
the last defect — which is the ordinary way this works, not a technicality. Its fix is
narrow (one call site learning what three siblings already knew) and carries its own test.
Its fix landed in `a89d77e` with its test in `ca3d6fa`, and the suite is green at 650 —
so the row in `north-star.md` has moved.

Thirteen defects, across three walks, behind 649 green tests. The suite established the
floor every time and decided nothing above it.
