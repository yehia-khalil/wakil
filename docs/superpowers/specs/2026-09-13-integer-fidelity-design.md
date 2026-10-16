# Integer fidelity — design

**Status:** binding authority for the fix that precedes 2c-ii-b.
**Probe:** `docs/wakil/phase-2c-ii-b-probe.md` §4 — where this was found and measured.
**Met:** 2026-09-13 — `JSONValue.integer(Int64)` decoded before `Double`, fourteen sites
migrated to accessors ahead of the case existing, cross-case numeric equality that narrows
the `Double` rather than widening the `Int64`, and `PaneCell`/`sortedRows` exact. Verified by
`make app-build`, `make app-test` (670 tests), `make test` and `make vet`, all green.
**Blocks:** sub-phase 2c-ii-b (Decision 20), which cannot show an operator the key of a
row it is asking them to edit.

---

## 1. What this is

`JSONValue` has one numeric case — `case number(Double)` (`JSONRPC.swift:135`) — and its
decoder tries `Double` before `String`. Every JSON number Wakil receives therefore
becomes a `Double`, and a `Double` stops representing every integer exactly above 2^53.

Measured, through the real `collectRows` path and `encoding/json`, on both engines:

```
wire:     [[9007199254740993,"x"]]     (go type int64, sqlite AND mysql)
in Swift: 9007199254740992
```

**A row keyed 9007199254740993 is a row Wakil believes is keyed 9007199254740992.**

This is not a display bug with a display fix. One cause produces three failures:

- **The grid draws the wrong value.** `PaneCell` guards its integer rendering with
  `abs(number) < 1e15` and falls back to `String(Double)`, so such a key draws as
  `9.007199254740992e+15` — wrong digits in an unreadable format.
- **`read_pane` hands the agent the wrong key.** The agent reads row id `…992`,
  proposes `UPDATE … WHERE id = …992`, and that statement reaches the confirmation
  plane looking entirely reasonable. The operator is asked to confirm a correct-looking
  statement aimed at a row that is not theirs. **This is a live path today**, independent
  of anything 2c-ii-b adds.
- **`sortedRows` ties wrongly.** Two distinct keys that collapse to the same `Double`
  compare equal, so their order is whatever the sort's stability happens to give.

**There is no correct copy of the value anywhere in the app.** It is lost at decode,
before any view, any action or any projection sees it. No feature downstream — a copy
affordance, a wider column, a tooltip — could recover it. The only workaround available
today is casting in the query line (`SELECT CAST(id AS CHAR) …`), because a string
crosses the wire intact.

**Reachability.** Ordinary `AUTO_INCREMENT` counters never approach 2^53. Time-encoded
identifiers — snowflake ids and their imitators — are past it on the day they are
minted, as are nanosecond timestamps and hash-derived keys. The operator's current
databases do not use them; the operator has stated they may.

---

## 2. The rule this is written against

> A value Wakil shows, sorts, or hands to an agent must be the value the database holds.

`PaneCell`'s existing `< 1e15` guard, `safeInt`'s and `safeInt64`'s identical guards, and
`truncated`'s whole existence are the same rule already obeyed elsewhere: **where Wakil
cannot represent something, it must not pretend to.** Today the number branch pretends.

---

## 3. The change

`JSONValue` gains a second numeric case:

```swift
case integer(Int64)
```

and its decoder tries `Int64` **before** `Double`. A wire `9007199254740993` becomes
`.integer`; a wire `1.5` fails `Int64` and becomes `.number` as it does now.

**Why a second case rather than replacing `number` with a decimal type.** JSON has one
number type and Wakil receives genuine non-integers — `millis` timings are integral but
a driver may report a `DOUBLE` column, and `1.5e3` is a legitimate cell value. A single
case cannot hold both an exact `Int64` and an exact fraction. Two cases can, and the
distinction they draw is the one the wire already draws.

**Encoding is symmetric and must round-trip.** `.integer(5)` encodes as `5`, not `5.0`;
`.number(5)` also encodes as `5`, which is what `JSONEncoder` already does for a
`Double` of `5.0`. So a value that arrives as `5` and is echoed back leaves as `5`
whichever case held it.

---

## 4. The hazard, and the order that closes it

**This change is dangerous in a way that is the opposite of what it looks like.** Of the
fourteen sites in `app/Sources` that pattern-match `JSONValue.number`:

| Form | Count | What adding a case does |
|---|---|---|
| `switch` arm (`JSONRPC.swift:167`, `PaneContents.swift:24`) | 2 | **Compile error.** Swift checks exhaustiveness. |
| `if case` / `guard case` | **12** | **Nothing. The pattern silently stops matching.** |

A `guard case .number(let n)? = obj["width"]` does not fail to compile when `.integer`
exists. It compiles, runs, and takes the `else` branch for every integer an agent ever
sends. The twelve silent sites are:

`WindowModel.swift` 196 (`millis`), 206 (`anchorRow`), 215 (selected rows), 237
(`scrollTarget`), 249 (`offset`) · `LayoutActions.swift` 282, 291 (numeric params) ·
`PaneContentActions.swift` 99, 210 (row indices), 135 (`width`) ·
`StandardActions.swift` 1457 (numeric param), 1539 (`millis`).

Row selection, scroll targets, column widths, paging and timings — every one would break
silently, at run time, on the first integer that reached it.

**Three sites that look like they belong on that list do not, and are named here so the
implementation does not "fix" them.** `MCPClient.swift:423` and `JSONRPC.swift:90` match
the JSON-RPC **id** enum, a separate two-case type whose decoder already tries `Int`
before `String` — request ids are exact today and this spec does not touch them.
`PaneFetch.swift:435` matches `PaneFetch.Page.number`, an unrelated enum that happens to
share the case name. Grepping for `case .number` finds all three; only the type they
match decides whether they matter.

**The JSON-RPC id enum's decoder is also the precedent for §3's decode order.** It
already tries the exact integer type first and falls back. This spec applies the rule the
adjacent type has obeyed since Phase 2a.

**So the case is added last, not first.** The order is not a preference:

1. **Add accessors to `JSONValue`** — `var int64Value: Int64?`, `var intValue: Int?`,
   `var doubleValue: Double?` — each returning the right answer for `.number` today and
   for `.integer` tomorrow. `intValue`/`int64Value` keep `safeInt`'s existing guards for
   the `.number` path (finite, integral, `< 1e15`) and return an `.integer`'s payload
   directly, because an `Int64` needs no narrowing.
2. **Rewrite all fourteen sites to use the accessors.** No behaviour changes; every site
   reads exactly what it reads today.
3. **Prove there are none left.** `grep -rn 'case \.number' app/Sources` must match only
   `JSONRPC.swift`'s own `JSONValue` encoder, the accessors, and the three unrelated-type
   sites named above. This grep is the safety check, and it is in the plan as a step,
   because the compiler cannot perform it.
4. **Add `case integer(Int64)`, the decoder order, and the encoder arm.** The two
   `switch` sites now fail to compile and are fixed; nothing else can silently change,
   because nothing else pattern-matches the case any more.
5. **Teach `PaneCell` and `sortedRows` the new case.**

---

## 5. Equality, and the 236 test constructions

`.integer(5)` and `.number(5)` are two representations of one value. Left to the
synthesised `Equatable`, they would not compare equal — and `app/Tests` constructs
`.number(…)` **236 times**, overwhelmingly as *expected* values in assertions whose
actual values will now arrive as `.integer`.

So `==` is written by hand: two numeric cases compare **numerically**, across cases.
`.integer(5) == .number(5)` is `true`; `.integer(9007199254740993) == .number(9007199254740992.0)`
is `false`, which is the entire point.

**`Hashable` is not added.** `JSONValue` does not conform today, and a hand-written `==`
without a matching `hash(into:)` would be a trap for whoever adds the conformance later.
If it is ever needed, the two numeric cases must hash identically for equal values; this
is recorded here rather than left to be discovered.

**Comparison across cases is by value, not by bit pattern.** `Int64` → `Double` is itself
lossy above 2^53, so the comparison converts the `Double` to `Int64` when it is integral
and in range, and compares as integers; otherwise it compares as `Double`. Two large
distinct integers must not be called equal by the very conversion this spec exists to
remove.

---

## 6. `PaneCell`

```swift
case .integer(let n):
    text = String(n)
    isNull = false
```

Exact for every `Int64`, with no bound and no fallback — the `< 1e15` guard exists only
because a `Double` cannot be trusted past it, and an `Int64` can be trusted everywhere.
The `.number` branch is unchanged, including its guard, because a `Double` is still a
`Double`.

**This is what makes the key readable on screen**, which is the property 2c-ii-b needs
and the one the operator asked for.

---

## 7. `sortedRows`

`PaneContents.swift`'s comparator builds a sort key per row and compares two finite
numbers numerically. It must compare `.integer` values as integers rather than by
converting both to `Double` — otherwise the tie this spec exists to remove survives
inside the sort, where it is invisible.

Mixed `.integer`/`.number` in one column is ordinary (a `NULL`-free integer column with
one fractional row, or a driver reporting both) and compares by value.

---

## 8. What this does *not* do

- **It does not change the wire format**, with one exception. Go emits `9007199254740993`
  today; it will emit `9007199254740993` after. Nothing in `internal/wakilcore` is
  touched. The exception is negative zero: a wire `-0.0` (or `-0`) fails the decoder's
  `Int64` attempt on today's code and stays `.number(-0.0)`, re-encoding as `-0` same as
  it decoded. After this change it decodes as `.integer(0)` — `Int64` has no negative
  zero to preserve — and re-encodes as `0`. Display is `"0"` either way, so this is a
  snapshot/journal echo difference only, not a value the operator or an agent ever reads
  differently, and it is not worth a case in the decoder to avoid.
- **It does not add a copy affordance.** The grid has none — cells carry a `.help`
  tooltip and nothing else — and adding one is not this fix. What this does is make the
  value the grid *shows* true, so a later copy affordance has something correct to copy
  and the query-line `CAST` workaround stops being necessary.
- **It does not touch `Int` narrowing policy.** `safeInt`'s guards stay exactly as they
  are for the `.number` path; a row index or a column width arriving as `1e300` is still
  refused rather than trapping.

---

## 9. How it is verified

- A round-trip test per boundary: `9007199254740993` decoded from JSON, held in a
  `JSONValue`, re-encoded, and compared byte-for-byte with the input.
- `PaneCell(.integer(9007199254740993)).text == "9007199254740993"`.
- The cross-case equality matrix, including the pair that must be **unequal**.
- Every one of the twelve silent sites gets a test that passes an integer through it and
  asserts the behaviour is unchanged — these are the sites with no compiler to protect
  them, so they get the protection tests instead.
- The `grep` of §4 step 3, run as a step and recorded.

---

## 10. Why this is its own piece of work

It is a defect in 2c-i's data surface and in the MCP boundary, both of which shipped
before 2c-ii-b was scoped, and its third symptom — the agent proposing a mutation
against a misread key — is reachable today with no cell editing in the product at all.
Folding it into 2c-ii-b would put a change to the core wire type inside a sub-phase
whose claim is that it is small, and would leave the defect unfixed for as long as that
sub-phase takes.

2c-ii-b depends on it in one direction only: **the edit's `WHERE` clause does not**, by
design — the per-row key is composed in Go, where the value was never at risk. What
depends on it is the operator's ability to *read* the key of the row they are editing,
which is not optional.
