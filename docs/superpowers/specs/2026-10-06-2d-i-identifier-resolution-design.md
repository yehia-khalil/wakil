# 2d-i: identifier resolution

**Date:** 2026-10-06
**Status:** design approved by the operator 2026-10-06, section by section
**Sub-phase:** 2d-i — moved ahead of 2c-vi by the operator on 2026-10-06 (2c-vi is deferred, not
cut; see the charter's §8 row)
**Evidence:** [`2d-stt-probe.md`](../../wakil/2d-stt-probe.md) §6.2 (2026-09-16) and §10
(2026-10-06), which holds this design's two measurements

---

## Problem

**Both speech engines hear the right words and don't know they are one identifier.** Apple
returns "transaction read only" for `transaction_read_only` and "describe editability" for
`describeEditability`. The probe measured that two thirds of its misses had this shape, and
that a deterministic fold against the names Wakil already knows recovers them without any
model change.

Decision 11 has said since 2026-09-03 that mistranscribed identifiers are *"resolved by the
agent against real ticket and endpoint lists"*. No phase built the lists or handed them to
the agent. 2d-i builds that first stage. **It needs no audio and no model**, and it serves
typed text today, so ⌘P/⌘K and every typed turn benefit before 2d-ii exists.

## What the operator gets

1. **A typed turn that names an identifier loosely reaches the agent with a hint.** "what's
   in transaction read only" is sent as typed, plus a note saying that phrase matches the
   `transaction_read_only` column. The agent makes the final call (Decision 11).
2. **The thread shows a `RESOLVED` row** naming each phrase and the identifier it matched,
   on one line like every other row. The full note is in the journal.
3. **⌘P/⌘K find items by their spoken shape.** "pane move" finds `pane_move`.

## What it does not do

- **No near matching (approximate spelling).** It was measured twice and failed the fresh set
  (§Measurements). "right ref" for `writeRef` and "tell 2835" for `INI-2835` stay for the
  agent to work out from context.
- **No abbreviation expansion.** "active M" for `activeEnv` and "Kopit CTX" for `copiedCtx`
  don't resolve. An abbreviation resolves only when it is spoken as its letters ("CTX list
  environments").
- **No rewriting.** The operator's text is never changed; the note is added beneath it.
- **No audio, no push-to-talk, no composer change.** Those are 2d-ii's. So are the Core's
  listening state and the composer revamp, recorded against 2d-ii on 2026-10-06.
- **No Jira keys.** The PM source arrives with 2c-vi as one more `IdentifierSource`.

## Measurements this design rests on

Two recordings by the operator on 2026-10-06, Apple `SpeechAnalyzer`, 25 utterances each,
transcripts committed under `scripts/probe/`. The pass mark for near matching was fixed
before either was recorded: at least 3 more identifiers recovered than fold-only, at most 3
more wrong suggestions.

| | Set 1 (the 2026-09-16 utterances), 29 identifiers | Set 2 (new, written before recording), 29 identifiers |
|---|---|---|
| Exact, no resolver | 3 | 4 |
| Fold only | +6 recovered, 6 wrong | +11 recovered, 2 wrong |
| Fold + near, against every name | +7 more recovered, +19 more wrong: **fails** | — |
| Fold + near, against short lists only | +4 more, +3 more wrong: passes | +1 more, +1 more wrong: **fails** |

Near matching against short lists was chosen *after* seeing set 1, so set 2 was recorded as
a fresh check, and it failed. **2d-i ships fold-only.**

**About one turn in five carries a suggestion the operator did not mean.** Every wrong
fold-only suggestion matched a real name: `operatorOnly`, `DBPane`, `MySQL`, `isActive`,
`re-run`, `fRoM`. Filtering prose words and single-part names was tried and removed one of
six. The noise is accepted because the note is a hint the agent can ignore, never an action.

## Design

### Units

All in `WakilKit`.

| Unit | Does | Depends on |
|---|---|---|
| `Identifier` | One known name: `text`, `kind` (table, column, collection, code, file, action, tool, org, project, environment, endpoint, path) and `origin` (`staging · core db`, `wakil/app`) | — |
| `IdentifierSource` (protocol) | `identifiers(for context) async throws -> [Identifier]`, and `gather(for context)`, which also returns the parts that failed while the rest answered | the source's own data |
| `Vocabulary` | Every source's current names, indexed by folded form; immutable, replaced whole | sources |
| `IdentifierResolver` | Pure: `resolve(text, in: Vocabulary) -> [Resolution]`. No I/O, no state | `Vocabulary` |
| `TurnNote` | Renders `[Resolution]` as the note's text, or `nil` | resolver |
| `VocabularyStore` | Owns the sources, rebuilds on their triggers, publishes the current `Vocabulary` | sources, active context |

**`IdentifierSource` is the seam the later sources plug into**: Jira keys (2c-vi), the editor
(Phase 3), MCP servers added later. A new source changes neither the resolver, the note nor
the palettes.

### The four sources

1. **Wakil.** Registered action names (`registry.all()`), and the org, project and
   environment names. In memory; rebuilt when any of them changes. *(The capability servers'
   own tool names are not known in Swift, so they are not a source in 2d-i; corrected
   2026-10-06 while planning.)*
2. **Schema.** Table and column names for every database in the active environment, through
   `wakil-db`'s new `list_columns` (below). Rebuilt on a context change and at launch.
3. **Panes.** Open panes' column names and table, API endpoints (path and name), and the
   terminal's working directory. In memory; rebuilt when the pane store changes.
4. **Code.** For each root of the active project: tracked files from `git ls-files`,
   skipping `vendor/`, `node_modules/`, `.build/`, `build/`, `dist/`, `generated/` and
   binary extensions. From each file it takes compound names (snake_case, camelCase,
   PascalCase with at least two parts, kebab-case) and the file's basename.
   - **Capped at 20,000 names per root**, keeping the most frequent.
   - **Built off the main actor** and **cached per root and git `HEAD`** under
     `~/.wakil/vocabulary/`, beside `~/.wakil/layouts/`. Rebuilt on a context change and at
     launch; the `HEAD`-keyed cache means a rebuild after a commit rescans and an unchanged
     `HEAD` reuses the cache. *(Corrected 2026-10-06 in the final review: a per-send rebuild
     would also re-run `list_columns` against every database on every turn.)*
   - A root that is not a git repository, or has no commits, contributes nothing and is
     journalled; the other roots still contribute.

### `wakil-db`: `list_columns`

`describe_table` costs one call per table. `list_columns` returns every table's columns in
one read:

- **SQL:** one query on `information_schema.columns` for the selected database's schema,
  through the normal read connection (`openPicked`/`OpenDatabase`), never the write
  credential.
- **Mongo:** collections only, with an empty column list. Mongo has no fixed fields to list.
- Arguments: the database name, as every other picked-database tool takes it. Output: a
  list of `{table, columns: [name]}`, plus `truncated` if the server caps it.

It is a read, so Invariant 6 is not engaged.

### The org boundary

**On an org switch, `VocabularyStore` drops the whole vocabulary before building the new
one.** Between the two, the vocabulary is empty and nothing resolves. One org's names never
appear in another org's note: Invariant 4's boundary, applied to names. The code cache is
keyed by root path, which belongs to one project and so to one org.

### Failure

- **A source that throws contributes nothing**, and the others still resolve (Interaction
  Rule 8).
- **A source with parts keeps the parts that answered.** One root of several, or one
  database of several, that fails is journalled and the rest still contribute. The source
  throws only when every part failed.
- The failure goes to the journal with its whole reason. **Nothing is shown on screen**: a
  missing note is not something the operator needs to act on.
- **A turn never waits for a source.** The note uses the vocabulary that is current when
  the turn is sent.

### The fold matcher

- **Fold:** lowercase, then keep only letters, digits and dots — the rule both recordings
  were scored with. Spaces, hyphens, underscores, apostrophes and slashes all fold away;
  dots stay, so `paths.go` and `ContextStore.swift` keep their extension. Leading and
  trailing punctuation is stripped from each word first (`store.swift.` → `store.swift`).
- **Scan:** runs of 1 to 6 words, longest first, non-overlapping. A run whose fold equals a
  name's fold is a resolution.
- **Nothing to resolve:** a run that already equals the name, ignoring case and surrounding
  punctuation ("Wakil", "staging."), produces no resolution.
- **Several names for one phrase:** at most 3 candidates, ranked by source (panes on
  screen, then schema, then Wakil, then code), then shorter origin first, then
  alphabetically. Beyond 3: "and N more".
- **At most 8 resolutions per turn.** A turn that would produce more (pasted output, a long
  log) is sent with no note at all.

### The note

Appended to the turn text after a blank line, only when there is at least one resolution:

```
[Wakil: identifiers in scope that match words in this turn — a hint, not a correction]
- "transaction read only" → transaction_read_only (column · staging · core db)
- "describe editability" → describeEditability (code · wakil/app)
- "status" → orders.status, users.status, jobs.status (column · staging · core db) and 2 more
```

Plain text, so it is harness-agnostic (Invariant 1). Its first line tells the agent it may
disagree.

### Where it runs

- **The agent turn.** `WindowModel.send` resolves the text against the current vocabulary
  and passes `text + note` to `harness.send`. It appends one `RESOLVED` thread row and
  journals the note whole. A rebuilt thread (a reopened session) strips the note from the
  `you` row's text and shows the same `RESOLVED` row in its place.
- **⌘P/⌘K.** `rank()` keeps `fuzzyScore` and adds the fold. When the query's fold is a
  prefix of a title's or subtitle's fold, that item ranks above every match that is
  subsequence-only.

### UI and the Interaction Rules

**No new control.** The thought thread is not interactive (`ThoughtThread` sets
`allowsHitTesting(false)`, and `design-language.md` §3 forbids interaction there without
promotion), and the live thread never shows the operator's own message. So the resolution
is one more row, in the thread's own form:

```
RESOLVED   transaction read only → transaction_read_only · describe editability → describeEditability
```

One line, truncated at the tail like every row. The journal holds the note whole. *(Changed
2026-10-06 while planning, operator's choice: the spec first proposed an expandable line
under the operator's message, which the thread cannot carry.)*

| Rule | How this meets it |
|---|---|
| 1. Confirm only what destroys | No confirmation added |
| 2. Enter never required to keep input | The composer is unchanged |
| 5. Work in flight shows it | The send path's in-flight behaviour is unchanged; resolution is synchronous and adds no wait |
| 6. Stay where the operator was | Nothing moves; the row is appended like any other |
| 7. Override or ignore; don't refuse | No turn is refused; a turn over the limit is sent with no note |
| 8. Errors shown whole, block only what they must | A failed source blocks nothing; its error is journalled whole. The row is truncated, but it is not an error, and the note is whole in the journal |

Rules 3, 4 and 9 are not touched: no new input, nothing that waits, no defaults.

## Testing

- **The resolver against both recordings.** The 50 committed transcripts are fixtures.
  Set 1 must recover at least 6 and set 2 at least 11, with wrong-suggestion counts pinned,
  so a later change cannot quietly lower them. The vocabulary for this test is a committed
  snapshot, not a live scan.
- **Each source, with a fake:**
  - schema against a fake `ToolCaller`;
  - code against a temporary git repository, checking the skip list, the cap, the
    frequency ordering and the `HEAD` cache;
  - panes against a seeded `PaneStore`;
  - Wakil against a registry and context.
- **The org boundary:** after switching from org A to B, no A name resolves, including
  during the rebuild.
- **The note:** its format, the 3-candidate and 8-resolution limits, a turn over the limit,
  and a turn with no match sent byte-identical.
- **⌘P/⌘K:** "pane move" ranks `pane_move` first, and the existing ranking tests pass
  unchanged.
- **`list_columns`:** Go tests against the acceptance MySQL fixture; Mongo returns
  collections with empty column lists; the read connection is used, never the write one.
- **The rebuilt thread:** a `you` row whose text carries a note shows the typed text and a `RESOLVED` row.
- **The e2e auditor** covers the `RESOLVED` row and the send path (the Cover rung).

## Exit criterion

On the walk, the operator:

1. sends a turn naming a column loosely ("what's in transaction read only"). The agent
   receives the note, the thread shows a `RESOLVED` row, and the journal holds the note.
2. sends a turn naming code loosely ("where is build launch defined"). Same.
3. sends a turn with no identifiers. No note, no line.
4. types "pane move" in ⌘K. `pane_move` is first.
5. switches org, then sends a turn naming one of the previous org's tables. No note.

## Recorded, not built

- **Near matching.** Failed the fresh check. It comes back only with a new pre-registered
  measurement.
- **Abbreviation expansion** ("environment" → `Env`, "account" → `acc`). The operator
  pronounces abbreviations as words, so this is the largest remaining category after fold.
  Needs its own measurement.
- **For 2d-ii: an allow-priced write can run from a mistranscribed spoken turn.** The Jira
  transition and an HTTP send outside production execute without typed confirmation
  (Invariant 7's allow price). "Move till 1042 to review" mapped to the wrong ticket would
  move it. 2d-ii's composer should show the transcript before sending.
- **For 2d-ii: the composer revamp and the Core's listening state.** Speaking has no phase
  that delivers text-to-speech: open question 17.
