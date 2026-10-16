# Phase 2c-ii walk defects — design

**Status:** binding authority for the fix round that follows 2c-ii's acceptance walk.
**Walk:** `docs/wakil/phase-2c-ii-acceptance.md` — walked 2026-09-13, twelve defects.
**Phase spec:** `docs/superpowers/specs/2026-09-12-phase-2c-ii-db-pane-design.md`.

---

## 1. What this is, and what it is not

2c-ii's fourteen acceptance checks were walked at the window on 2026-09-13. **Every
mechanism the phase built works.** The query line runs and refines in place; ⌘↩ answers
the pane it is typed in; paging is exact in both directions; a sort on page three re-queries
the whole result; relaunch restores a schema pane and a paged pane and refetches every pane
against the live environment; the routing inversion opens a second pane exactly when the
operator names a second subject.

**What failed is the promise underneath all of it.** Twelve defects, and once they are laid
beside each other they are one sentence repeated:

> A pane, or the window, said something untrue about what it was pointed at.

- **D12** — a pane whose fetch *failed* drew `no rows`.
- **D11** — a pane kept the previous environment's rows under the new environment's banner.
- **D8b** — a pane kept pre-mutation rows after the mutation it ran.
- **D7** — a refused statement was erased instead of left to be corrected.
- **D5** — a sort was sometimes text in the line and sometimes a glyph on a header.
- **D10** — the *window* said `production` while the agent had moved it to `staging`.
- **D3** — the agent said the answer in chat and drew nothing, so the canvas said nothing.

This spec fixes eleven of the twelve. **D1 is recorded and deliberately unfixed** (§13).

**This is not a new phase.** It adds no pane kind, no driver, no surface the north star does
not already name. It has exactly one piece of genuinely new surface — the agent's system
prompt (§5) — and that exists because the walk proved 2c-ii cannot be met without it.

---

## 2. The one rule this round is written against

Every fix below is a consumer of one rule, and where a fix has a choice to make, this rule
decides it:

> **A surface may only say what it knows. When it does not know, it says that instead.**

2c-i's walk found four causes of "rows returned, nothing on screen" and instructed this
phase to assume a fifth existed. **It does — D12** — and its shape is this rule broken in
the smallest possible way: `DBPane` drew `no rows` for a state it had not been told apart
from an empty result. The information was there. The journal has it. Nothing carried it to
the surface.

That is why §3 comes first and why it is not merely a `Text` change: the fix is to give the
pane a state it can be in, not a sentence it can print.

---

## 3. D12 — a pane knows when its fetch failed *(blocking)*

### 3.1 What happens now

`DBPane.swift:72` draws `no rows` on one condition:

```swift
if table.columns.isEmpty {
    Text("no rows")
```

`table.columns.isEmpty` is true in three unrelated states:

1. the query ran and returned no rows,
2. the pane has never been fetched at all,
3. **the fetch was attempted and failed.**

`restorePaneContents` discards every dispatch result with `_ =`, so nothing records which.
`WindowModel.dispatch` does set `status` on a throw, but `restorePaneContents` loops, so *n*
failures leave one message in the window's status line and nothing on any pane.

Walked evidence: reopening on `production` journalled `db_refetch` → `error` for `db-25` and
`db-26`, and both panes drew `no rows`.

### 3.2 The rule

**"I looked and found nothing" and "I could not look" are different facts and must not
share a sentence.** The operator acts differently on each: the first is an answer, the
second is a broken pane.

### 3.3 What is built

**`PaneStore` gains a failure state, held beside the contents rather than inside them.**

```swift
/// Why this pane's last fetch did not produce rows, or `nil` if the last
/// fetch succeeded.
///
/// **Beside `rows` rather than replacing them, because a failure must not
/// silently erase the last good result.** A pane showing yesterday's rows
/// under a red line saying the refetch failed is honest; a pane blanked by
/// a transient failure has thrown away the only thing it knew.
var failure: String?
```

- `setRows(...)` clears `failure` — a result arriving *is* the success signal, and there is
  no path where rows and a live failure are both true.
- New `setFailure(paneId:message:)` sets it without touching `rows`, `columns`, `offset` or
  `sort`.
- `snapshot` emits `failure` unconditionally (`null` when absent), for the same reason
  `pageable` carries no `omitempty`: a reader — the agent included — must not have to tell
  "did not fail" from "this build is too old to say".

**`PaneTable` carries `failure: String?`**, projected in `paneTable(from:)` beside
`pageable` and `offset`.

**Every call site that discards a dispatch result now records the failure.** Three of them:

```swift
public func restorePaneContents() async {
    for pane in layoutSnapshot.panes where pane.kind == "db" && pane.fetch != nil {
        if await dispatch("db_refetch", .object(["pane": .string(pane.id)])) == nil {
            await panes.setFailure(paneId: pane.id, message: status)
        }
    }
    await refreshPanes()
}
```

and the same shape in `refetchPane(id:)` and `pagePane(id:to:)`.

**`DBPane` draws the failure where the rows would go**, and `no rows` only when there is no
failure:

```swift
if let failure = table.failure {
    Text(failure)          // red, monospaced, same treatment as `refusal`
    Spacer()
} else if table.columns.isEmpty {
    Text("no rows")
    Spacer()
} else {
    DataSurface(...)
}
```

### 3.4 What this must not become

**Not a modal, not a note in the window's status line, not a toast.** The claim is about
one pane and belongs in that pane, for the same reason D14's per-pane refusal keying was
fixed during the phase itself: a message about pane B drawn under pane A is the same class
of lie in a smaller font.

**Not a retry.** A pane that silently retried a failing fetch would be a pane whose
displayed state depends on when the operator looked at it.

---

## 4. D11 — switching environment invalidates every pane *(blocking)*

### 4.1 What happens now

```swift
public func setEnvironment(_ name: String) async {
    if await dispatch("ctx_set_environment", .object(["name": .string(name)])) != nil {
        await refreshContext()
    }
}
```

Open `db` panes are neither refetched nor cleared. Walked evidence: with the banner reading
`environment: production`, three panes showed `core · tables`, `docs · tables` (seven
collections) and `docs · describe_me` (one Mongo document). **`production` defines one
database, `core`.** Every row in the latter two came from `staging` and stayed on screen
until the app was quit.

### 4.2 The rule

This is the persistence boundary broken from the other side. 2c-ii refuses to write rows to
disk because *redrawing yesterday's rows would show a database state that may no longer
exist* — and here the same rows survived a change that guarantees they describe a different
database entirely.

> **An environment switch is a relaunch into that environment.** It must leave the canvas
> in the state reopening the app there would leave it in.

### 4.3 What is built

`setEnvironment` does what relaunch does:

```swift
public func setEnvironment(_ name: String) async {
    guard await dispatch("ctx_set_environment", .object(["name": .string(name)])) != nil
    else { return }
    await refreshContext()
    // D11. The panes on screen describe the environment we just left.
    // `restorePaneContents` is the relaunch path, and a switch must leave
    // the canvas exactly as reopening the app in the new environment would.
    await restorePaneContents()
}
```

**This is one call because the relaunch path is already correct.** `restorePaneContents`
refetches every `db` pane with a fetch, and with §3 in place each pane that cannot resolve
its subject in the new environment now says so instead of drawing `no rows`.

**D11 and D12 compound, and neither fix is sufficient alone.** D11 plants the stale rows;
D12 is why the corrective fetch stays silent. Fixing only D11 turns three lying panes into
three panes claiming to be empty. Fixing only D12 leaves the lie until the next relaunch.

### 4.4 The design question this settles

The layout file is keyed `~/.wakil/layouts/<org>/<project>.json` — **not** per environment,
so `production` and `staging` share one arrangement.

**Decided: the arrangement stays shared and panes refetch.** An operator's pane arrangement
is a property of how they work, not of which environment they are pointed at. Keying the
layout per environment would mean quitting on `production` and reopening on `staging` shows
a different canvas — which would have made D11's *apparent* symptom (the one the operator
first reported) genuinely real.

---

## 5. D3 — the agent is told what the canvas is *(blocking, new surface)*

### 5.1 What happens now

**Wakil passes the agent no system prompt.** `ClaudeCodeCLIHarness.launch` builds `-p`,
`--input-format`, `--output-format`, `--verbose`, `--include-partial-messages`,
`--session-id`, `--mcp-config`, `--strict-mcp-config`, `--permission-prompt-tool`,
`--allowedTools`. There is no `--append-system-prompt`, and `grep` finds the flag nowhere in
the source tree.

The agent is generic Claude Code holding some MCP tools. Its entire knowledge of Wakil is
the tool descriptions plus the `paneNote` string returned on auto-open.

Walked evidence — the operator closed a pane and asked for its contents again:

> *"You've asked this exact same question four times in a row now, and the answer hasn't
> changed."*
> *"I'll hold off repeating the same query a sixth time since nothing indicates it will
> produce a new result."*

No pane was opened.

### 5.2 The rule

**This is not the agent disobeying its instructions. It is an agent with no instructions
behaving exactly as one would.** It reasoned about the *conversation* — have I said this
before — because the conversation is the only surface it had been told about. The operator
was reasoning about the *canvas*: is it on screen.

> **Wakil's agent answers by drawing. The transcript is how it narrates what it drew, never
> a substitute for having drawn it.**

### 5.3 What is built

A new file, `app/Sources/WakilKit/Harness/AgentInstructions.swift`, holding one
`public let agentSystemPrompt: String`, passed as `--append-system-prompt` in
`ClaudeCodeCLIHarness.launch`.

**`--append-system-prompt`, not `--system-prompt`.** Replacing Claude Code's own prompt
would discard its tool-use discipline and its refusal behaviour, both of which Wakil relies
on and neither of which it wants to restate.

**It lives in `WakilKit`, not `WakilApp`, and is a `let` on a type, not a file read at
runtime.** `WakilApp` has no test target and cannot have one. A test must be able to assert
that the prompt says the load-bearing things, and a runtime-read file would make the prompt
a deployment artefact that could go missing.

**Five things it must say**, and these five are the acceptance surface for §5:

1. **The canvas is the deliverable.** A question about data is answered by opening or
   refining a pane. Say what you drew and where; do not paste rows into the transcript in
   place of drawing them.
2. **A closed pane is not a cached answer.** If the operator asks again for something you
   have already answered, they are asking for it *on screen*. Draw it. Never decline on the
   grounds that you have answered it before — you cannot see the canvas, and whether a pane
   is open is not a fact the transcript contains.
3. **Naming a pane refines it; omitting one opens a new pane.** Declare which you mean by
   passing `pane` or not. Wakil never infers it.
4. **The operator's context is theirs.** Do not switch the active environment, project or
   provider to make your own work easier. If the work needs a different one, say so and let
   the operator decide.

   **The prompt must state where there is no backstop, and an earlier draft got this
   wrong.** It claimed Wakil would stop the agent at a confirmation plane for all three.
   Only part of that holds, and the agent is better served by the truth: switching the
   **provider** is refused outright at the permission layer (`operatorOnlyActions`) and
   never reaches a plane at all; switching **into or out of `production`** is held for the
   operator's confirmation (§6.3); switching the **project**, or moving between two
   non-production environments, is **not blocked by anything**. An agent told it will be
   stopped may infer a backstop exists and feel licensed to try. Telling it exactly where
   none exists is the stronger instruction.
5. **Never claim a pane shows something you have not confirmed it shows.** `read_pane`
   returns what is actually on screen; the result of the tool you just called is what you
   asked for, which is not the same thing.

Items 2 and 4 are D3 and D10 stated as instructions. **Item 4 does not replace §6's gate** —
it is the courtesy; §6 is the enforcement, and the enforcement is what holds when the
instruction is ignored.

### 5.4 How this is tested

`WakilKit` tests assert the prompt is non-empty and that `launch`'s argument list contains
`--append-system-prompt` immediately followed by it. **The five claims themselves cannot be
unit-tested** — whether an agent obeys a prompt is not a property of the string — and the
plan must not pretend otherwise by asserting on substrings of prose that will be reworded.
D3 is settled at the window, in the re-walk, or not at all.

---

## 6. D10 — leaving production is as gated as entering it *(blocking)*

### 6.1 What happens now

`WriteGate.swift:74`:

```swift
case .control:
    guard origin == .agent, isProduction(targetEnvironment) else { return .allow }
    return .gate
```

An agent switching **into** production is gated. An agent switching **out of** production is
allowed. Walked evidence: the operator switched to `production` from the UI; 63 seconds
later the agent called `ctx_set_environment {"name":"staging"}` and carried on. Journalled
`ok`.

**This is a recurrence.** `Action.swift:15` records that 2a's acceptance run already found
"the agent re-pointing the active context unasked", and `.control` exists because of it. The
gate built then guards one direction.

### 6.2 The rule

> **Production on either side of a `.control` switch is the operator's business.**

Entering production silently is dangerous because the next mutation is judged against it.
Leaving production silently is dangerous because **everything the operator subsequently
believes about the window is wrong** — the banner they last read said production, and every
read, every mutation proposal and every confirmation plane after that point is judged
against an environment they did not choose.

### 6.3 What is built

```swift
case .control:
    // D10. Production on EITHER side. Entering it silently arms the next
    // mutation; leaving it silently invalidates everything the operator
    // believes the window is pointed at — and the operator read that
    // banner, so the belief is Wakil's fault, not theirs.
    guard origin == .agent,
          isProduction(targetEnvironment) || isProduction(environment)
    else { return .allow }
    return .gate
```

**`.gate` is already the confirmation plane** — `ActionRegistry.dispatch` throws
`.needsConfirmation`, which `WindowModel.dispatch` routes to `parkAndAwait`. Nothing new is
built in the gate. The operator's own switches are untouched (`origin == .agent` still
guards the whole clause).

### 6.4 What the confirmation plane needs

**Correction (Task 7).** An earlier draft of this section put this fix in
`WindowModel.parkAndAwait`. That was wrong, and the implementer traced why:
`parkAndAwait` is reached only from `WindowModel.dispatch`, which is hard-coded to
`origin: .ui`, while `.control` gates only for `origin == .agent`. No agent-originated
environment switch can ever reach it.

**The agent's path is `MCPServer.parkForConfirmation`, and it already works.** It computes
`isMutation` from the action's kind, and for a `.control` action takes the non-mutation
branch — `describeProposal(action:arguments:)` — which yields a non-empty string, so the
plane rises and `affectsEveryRow` is correctly `false`. **§6.3's gate change alone fixes
D10.**

What remains is not correctness but what the operator reads at the moment they decide.
`describeProposal` renders `ctx_set_environment {"name":"staging"}` — the action and its
JSON arguments. That is a machine-shaped description in front of a human being asked to
approve a change to the one piece of state that decides whether a mutation is frightening.

So `confirmationDescription` still exists, and still is a `switch` over known action names
returning `nil` by default — but it belongs in `parkForConfirmation`'s non-mutation branch,
preferred over `describeProposal` and falling back to it:

```swift
let statement = isMutation
    ? (stringArgument(arguments, "statement") ?? "")
    : (confirmationDescription(action: name, params: arguments)
        ?? describeProposal(action: name, arguments: arguments))
```

An action that gains a gate later states its own sentence or inherits `describeProposal`'s
machine shape; neither is silent, and the default costs nothing.

### 6.5 What `parkAndAwait` does not need

`parkAndAwait`'s own guard is **correct as it stands and needs no change**. It serves
`.mutate` actions dispatched from the window, which always carry a `statement`:

```swift
guard let statement = stringParam(params, "statement"), !statement.isEmpty else {
    status = "\(name): no statement to confirm — nothing ran"
    return nil
}
```

`ctx_set_environment` carries `name`, not `statement`, so today a gated environment switch
**dies at the plane with a misleading message** rather than raising one. That is live for
the existing into-production case too — §6.3 merely makes it reachable more often.

`PendingMutation` gains no new field, and nothing here changes. Recorded only so the next
reader does not repeat the misdiagnosis:

```swift
let statement = stringParam(params, "statement")
    ?? confirmationDescription(action: name, params: params)
```

with `confirmationDescription` a pure function in `WakilKit` returning
`"switch the active environment to production"` for `ctx_set_environment`, and `nil` for
anything else — which preserves today's refusal for an action that genuinely has nothing to
show. `affectsEveryRow` is `false` for a context switch.

**It is a pure function in `WakilKit` so a test can reach it**, and it is a `switch` over
known action names rather than string-building over arbitrary params, so an action that
gains a gate later must state its own sentence rather than inherit a generic one.

---

## 7. D8b — a confirmed mutation refreshes its pane *(important)*

### 7.1 What happens now

`runMutation` deliberately does not refresh, and its comment is correct as far as it goes:

> *It does NOT refresh the pane afterwards, unlike `runQuery`: a mutation returns no rows,
> and re-reading the pane would leave the previous query's results on screen looking like
> this statement's output.*

That reasoning holds for `runMutation(_:database:)`, which names **no pane** — it is the
window's mutation control and has no pane to refresh.

**`runFromQueryLine` is different**: the operator typed the statement into a specific pane's
line, and that pane has a subject of its own. Walked evidence: after `confirm` on
`update events set customer_id = 42 where id = 3`, the plane closed, the line correctly
snapped back to `events` (Task 14's fix, working as designed) and the pane went on showing
`customer_id = 7` for `id = 3`.

### 7.2 The rule

> **Rows may not outlive the state they describe — least of all across the one action
> guaranteed to have changed it.**

### 7.3 What is built

`runMutation` gains an optional `pane:` and refetches it **only when the mutation actually
ran**:

```swift
public func runMutation(_ statement: String, database: String?, pane: String?) async {
    var params: [String: JSONValue] = ["statement": .string(statement)]
    if let database { params["database"] = .string(database) }
    guard await dispatch("db_run_mutation", .object(params)) != nil else { return }
    // D8b. The pane's own subject, re-read. Not the mutation's output —
    // `refetchPane` re-runs `Pane.fetch`, which is still `events`.
    if let pane, !pane.isEmpty { await refetchPane(id: pane) }
}
```

**A cancelled or refused mutation must not refetch.** `dispatch` returns `nil` for both, so
the `guard` is the whole distinction — and it must be, because refetching after a cancel
would redraw the pane for no reason and teach the operator that cancelling does something.

**The window's mutation control passes `nil`** and keeps today's behaviour exactly.

---

## 8. D4 — a new page starts at its first row *(important)*

### 8.1 What happens now

Paging changes `offset` and redraws the rows. The `ScrollView`'s scroll position is
untouched, so an operator mid-way down page two lands mid-way down page three.

### 8.2 What is built

The mechanism already exists: `PaneStore.Contents.scrollTarget`, projected onto `PaneTable`,
acted on by `DataSurface`'s `ScrollViewReader`. It is keyed on `scrollTarget` changing, which
will not fire when consecutive pages both want row 0.

`DataSurface` gains a second, independent trigger keyed on the page itself:

```swift
.onChange(of: table.offset) { _, _ in
    // D4. A new page is a new result and starts at its first row. Keyed on
    // `offset` rather than `scrollTarget` because two consecutive pages both
    // want row 0, and `scrollTarget` would not change between them.
    guard let first = table.rows.first?.id else { return }
    proxy.scrollTo(first, anchor: .top)
}
```

**No animation.** `scrollTarget`'s existing handler animates because it is following a
selection the operator can see moving. A page change replaces every row at once; animating a
scroll through rows that are already gone would draw motion that means nothing.

---

## 9. D7 — a refusal keeps the draft *(important)*

### 9.1 What happens now

Typing `upadte events set customer_id = 42 where id = 3` produces the correct refusal from
`classifyStatement` — *"only INSERT/UPDATE/DELETE statements are allowed"* — and the query
line then reverts to the pane's subject, discarding the text.

### 9.2 The rule

> **A refusal is the one outcome where the draft is most worth keeping.** It is wrong, it is
> known to be wrong, and the operator is the only one who can correct it.

The reversion is `shouldAdoptSubject` doing its job: after the submit, `lastRendered` was
updated, so the line counts as having no unsaved edits and adopts the unchanged subject.

### 9.3 What is built

`runFromQueryLine` records a refusal *before* the line can re-sync, and `DBPane` does not
update `lastRendered` on a submit that was refused. Concretely: the existing per-pane
`queryLineRefusals[paneId]` already carries the message; `shouldAdoptSubject` gains a
parameter for it.

```swift
public func shouldAdoptSubject(
    currentText: String, lastRendered: String, incoming: String, refused: Bool
) -> Bool {
    // D7. A refused line is an unsaved edit by another name: the operator's
    // text did not become the pane's subject, and it is the only copy of what
    // they meant. Adopting over it would make them retype a statement to fix
    // two characters.
    if refused { return false }
    return currentText == lastRendered && currentText != incoming
}
```

**A subsequent successful submit clears the refusal**, which restores adoption — the
existing `queryLineRefusals[paneId] = nil` on success already does this, so no new clearing
path is introduced.

---

## 10. D5 — the sort lives on the headers *(important)*

### 10.1 What happens now

Sorting by one column draws ▼ on that header and leaves the query line unchanged. Sorting by
a second column writes `ORDER BY …` into the query line **and the arrow disappears.**

Both halves are individually correct. `PaneFetch.sort` is a single
`QuerySort { Column, Descending }`; a two-column sort cannot be expressed in it, so the
agent falls back to writing SQL, and a `.sql` subject carries no `sort` for a header to draw.

### 10.2 The rule

The rule 2c-ii already intended, now stated so an operator can learn it:

> **The query line shows your subject. The headers show the ordering Wakil applied.**

An operator who types their own `ORDER BY` sees it in the line and no arrow — correctly,
because Wakil did not apply that ordering, their SQL did. **Wakil does not parse the SQL to
discover otherwise**; a Swift-side SQL reader would be a second answer to a question the Go
gate already answers, and the first time the two disagreed the disagreement would be the bug.

### 10.3 What is built

**The data type grows; the rule does not change.**

Go, `internal/wakilcore/dbdriver.go`:

```go
// QuerySort is one pushed ORDER BY term.
type QuerySort struct {
    Column     string
    Descending bool
}

type QuerySpec struct {
    Raw    string
    Offset int
    // Sort, when non-empty, is pushed into the statement as an ORDER BY
    // whose terms appear in exactly this order — index 0 is the primary
    // key, index 1 breaks its ties, and so on.
    //
    // A slice rather than a pointer to one term: an operator who sorts by
    // a second column has not replaced the first, they have refined it,
    // and a driver told only about the second would silently discard the
    // refinement it was asked for.
    Sort []QuerySort
}
```

`Conn.ReadTable`'s `sort` parameter widens the same way. `pageWrap` emits
`ORDER BY a ASC, b DESC`.

**Mongo's `$sort` must become a `bson.D`, and this is not cosmetic.**
`appendSortStage` today builds:

```go
map[string]any{"$sort": map[string]any{sort.Column: dir}}
```

A Go `map` has **undefined iteration order**. With one key that is harmless, which is why it
has been correct until now. With two, the driver would marshal the keys in whatever order
the runtime chose, so *which column sorts first would vary between runs of the same query* —
a flaky result no single-column test can see and no reviewer would spot by reading. The
value becomes `bson.D`, which is an ordered slice and is what the two `SetSort` call sites
in this same file already use. The stage itself stays a one-key `map[string]any`.

**The MCP tool arguments widen too, and this is a wire-format change.** `cmd/wakil-db`'s
`queryArg` carries `SortColumn string` and `SortDescending bool` — one term, by
construction. They are replaced by a single `Sort []struct{Column string; Descending bool}`
on both `query` and `read_table`. The two scalar fields are **removed, not deprecated**:
nothing outside this repo calls these tools, `wakil-db` and the app ship as one bundle from
one `make build`, and leaving a second way to express a sort would mean a precedence
question (does `SortColumn` come before `Sort[0]`?) that has no right answer.

`WindowModel.refetchPane` and `StandardActions.refetchPane(paneId:fetch:db:panes:)` — the
single subject-to-tool-call mapping — pass the array through unchanged.

`sortCanBeRecorded(on:pageable:)` is **unchanged in meaning and unchanged in signature**: it
judges the subject and the result's pageability, neither of which depends on how many terms
the sort has. An empty array is "no sort" and must be accepted wherever `nil` was.

Swift mirrors it. **The Swift type is `PaneSort`, not `QuerySort`** — `QuerySort` is Go's
name and never crosses the boundary; the two meet as JSON. So `PaneFetch.sort` goes
`PaneSort?` → `[PaneSort]`, and `PaneTable.sort` with it. `sorted(by:)` **appends or
replaces**:

```swift
/// Appends `column` as a new sort term, or — if it already sorts —
/// promotes it to primary and flips its direction. A column appears at
/// most once.
///
/// **A new column APPENDS; it does not become primary.** A second header
/// click means "and then by this", so the first column the operator chose
/// stays the one that orders the result and the second only breaks its
/// ties. (An earlier draft of this spec said "new primary" here and
/// contradicted its own test; the test was right.)
///
/// **Appending rather than replacing is what makes the second header click
/// mean what the operator means by it** — "and then by this" — which is
/// exactly the request that used to fall out of `QuerySort` into raw SQL.
public func sorted(by column: String, descending: Bool) -> PaneFetch
```

Offset still resets to 0 on any sort change, unchanged from 2c-ii.

`DataSurface` draws an arrow on **every** sorted column, with its ordinal when there is more
than one term — `▼1`, `▲2` — because two arrows with no precedence shown would be a new
ambiguity in place of the old one.

The footer's partial-sort warning names every term:
`sorted by kind, id within the 500 returned`.

### 10.4 What this does not do

**`db_run_query` still takes no sort** (2c-ii ruling R1, unchanged). A sort is expressed by
`db_read_table`'s parameters or by `pane_sort`; a `.sql` subject's ordering is the
operator's own text and stays that way.

---

## 11. D2 — drillability is declared by the driver *(important)*

### 11.1 What happens now

`db_list_tables` produces a `.tables` subject, and `DBPane` offers a drill on it. Typing
`show tables` produces a `.sql` subject, and no row opens anything — despite the result being
a table list in every way the operator can see.

### 11.2 The rule

The spec's instinct is right and stays: **Wakil must not infer that a one-column result of
table-ish strings is a table list.** That is guessing from shape, and the first
single-column `SELECT name FROM …` would prove it wrong.

But the operator cannot see the distinction that decides it, and a rule nobody can see is
indistinguishable from a bug. The resolution is to move the decision to where SQL knowledge
already lives:

> **Drillability is declared by the driver, never inferred by the surface.**

The Go gate already inspects the leading verb — `SQLReadIsPageable` returns false for `SHOW`
and `EXPLAIN` by exactly this means, using the same normalisation as `AssertSQLReadOnly`
(`stripSQLComments` → `TrimRight` → `ToUpper`).

### 11.3 What is built

`internal/wakilcore/readonly.go` gains, mirroring `SQLReadIsPageable` exactly:

```go
// SQLReadListsTables reports whether sql is a bare table listing whose rows
// name tables in the connection's own database.
//
// Deliberately narrow: only `SHOW TABLES`, with no FROM/IN clause and no
// FULL. `SHOW FULL TABLES` returns a second column; `SHOW TABLES FROM other`
// names a database this connection's drill would not open. A narrow rule that
// is always right is worth more than a broad one that is usually right — a
// drill that opens the wrong table is a worse failure than a drill that is
// absent.
func SQLReadListsTables(sql string) bool
```

`Rows` gains `ListsTables bool` (json `listsTables`, **no `omitempty`**, same reasoning as
`Pageable`). **Exactly one place sets it true:** `sqlConn.Read`, from
`SQLReadListsTables(spec.Raw)` — judging the **operator's raw text**, never a statement
Wakil composed, exactly as the read-only gate does. Mongo's `Read` sets it false; Mongo has
no `SHOW TABLES` to recognise.

**`Conn.ListContainers` is not involved and must not be changed.** It returns
`[]Container`, not `Rows` — the `.tables` subject never produces a `Rows` at all. Its pane
contents are built in Swift by `schemaPaneContents` and handed to `setRows` directly, and
its drill already works today off the subject. `listsTables` exists solely to rescue the
`.sql` path, which is the only one that was missing a drill.

Swift: `PaneTable` carries `listsTables`, and `offersDrill` consults it **in addition to**
the subject — the subject still answers for `.tables`, the flag answers for `.sql`, and
neither is ever inferred from the rows:

```swift
/// A drill is offered when the pane's subject is a table list, or when the
/// driver declared the result to be one (D2). Never inferred from the shape
/// of the rows.
public func offersDrill(subject: PaneQuery?, listsTables: Bool) -> Bool
```

`drillTarget(row:subject:)` already reads the first cell's text as the table name and is
unchanged; the database it opens against is the pane's own, which is why §11.3 refuses
`SHOW TABLES FROM other`.

---

## 12. D6 and D9 — two layout fixes *(minor)*

**D6 — the scrollbar covers the drill button.** `DataSurface`'s row overlay uses
`.padding(.trailing, 6)`; the vertical scroller is ~15pt wide and overlays it, clipping
`open` to `ope`. The trailing padding clears the scroller's gutter. **Not by hiding the
scroller** — it is the only indication of position in a 500-row page.

**D9 — the footer overflows when the pane is narrow.** `footer()`'s `HStack` has no line
limit, so at small widths each segment wraps to one character per line. Every footer segment
takes `.lineLimit(1)` and `.fixedSize(horizontal: false, vertical: true)`, and the `HStack`
truncates from the middle: `rows`, the range and `read-only` are the claims that must survive
narrowing, because they are the ones the operator checks a result against.

---

## 13. D1 — recorded, not fixed

A pane opened by `db_read_table` shows `EVENTS ▸ events` where the operator expected the SQL
that produced the rows.

**There is no SQL to show.** Nothing composed a `SELECT`; `Conn.ReadTable` exists precisely
so that Swift never does, because "everything in `events`" is three different statements on
three drivers and is not SQL at all on Mongo. Displaying an invented `SELECT * FROM events`
would be Wakil claiming to have run a statement it did not run — and the operator could then
edit one character of it and expect SQL semantics that Mongo would not honour.

The line is editable, and typing SQL into it converts the pane to a `.sql` subject. **That is
the affordance, and it is not visible.** Making it visible is a query-line design question
2c-iv reopens; it is recorded in the walk's §5 and in §16 below rather than guessed at here.

---

## 14. What this spec does not do

- **No new pane kind.** `Pane.kinds` stays `["db"]`.
- **No Swift-side SQL parsing.** §10 and §11 both move SQL knowledge *toward* Go, not away.
- **No retry, anywhere.** §3 explicitly refuses it.
- **No change to the read-only gate's authority.** It still judges the operator's raw text,
  first, before any wrap.
- **No per-environment layout file.** §4.4 decided against it, on the record.
- **No attempt to unit-test whether the agent obeys §5.** §5.4 says why.

---

## 15. Exit criterion

> An environment switch leaves the canvas as reopening the app there would. A pane that
> could not fetch says so, in the pane, in place of its rows. A confirmed mutation's pane
> re-reads itself; a cancelled one's does not. A refused statement stays in the line to be
> corrected. A page starts at its first row. Every sorted column carries an arrow, in
> precedence order, and the query line carries only the subject. A table listing offers its
> drill whether the agent or the operator asked for it. An agent that moves the operator out
> of production is stopped at the confirmation plane, and an agent asked twice for the same
> pane draws it twice.

The last clause is settled at the window and nowhere else.

**2c-ii is met when this spec's fixes are in and
`docs/wakil/phase-2c-ii-acceptance.md` §2 is walked a third time** — with the environment
switched while panes are open, which is the case that produced both blockers.

---

## 16. Open items

- **The query line's affordance (D1).** Nothing on screen says the line can be typed into,
  or that typing SQL into a table pane converts it. For 2c-iv.
- **`SHOW FULL TABLES` and `SHOW TABLES FROM x`** are deliberately not drillable (§11.3).
  If the walk finds operators typing them, the narrow rule is what should widen, with its
  own decision about which database the drill opens against.
- **`confirmationDescription` covers one action** (§6.4). The second action to need a gated
  sentence must add its own case; it must not grow a generic fallback.
- **The five claims in §5.3 are untested prose.** Their only verification is the re-walk.
  If 2c-iii adds a second pane kind, the prompt gains a sixth claim and the same limit
  applies to it.
