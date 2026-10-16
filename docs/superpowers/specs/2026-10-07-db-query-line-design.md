# The DB pane's query line: whole, structured, formattable

**Date:** 2026-10-07
**Status:** design approved by the operator 2026-10-07, section by section
**Found:** on the 2d-i walk (2026-10-07). The query line clipped
`SELECT typeof(customer_id) AS stored_kind, COUNT(*) AS row_count, COUNT(DISTINCT` and
gave no way to read the rest except by scrolling the field with the caret.

---

## Problem

The DB pane's query line (`app/Sources/WakilApp/DBPane.swift`, `queryLine()`) is a
one-line SwiftUI `TextField`. A query wider than the pane is cut off. The line exists so
that the pane's identity is visible (the 2c-i walk's "a pane titled EVENTS showing
customer rows has a lying title"), and a clipped query hides exactly that identity. The
agent writes long queries, so this is the common case, not an edge one.

## What the operator gets

1. **The whole query, wrapped.** The line grows to six lines, then scrolls.
2. **Structure by brightness.** Keywords, identifiers, literals and comments are told
   apart by opacity and weight. No hue is used.
3. **Format.** ⌥⇧F, or a quiet "Format" control on the line, lays the query out with one
   clause per line. ⌘Z undoes it.
4. **Return still runs. ⇧Return inserts a line break.**

## What it does not do

- **No hue.** `design-language.md` §5 says Wakil's own text is "cool white stepped down
  by opacity, never by a different hue", and green, amber and red are reserved. A palette
  would need a §5 carve-out amendment; it was declined for now (operator, 2026-10-07).
- **Format never changes a query's meaning.** It moves whitespace only. It never changes
  keyword case, quoting, comments or literals.
- **Format is not an action.** It is an edit inside the editor and runs nothing. The agent
  already sets a pane's query whole through `db_run_query`.
- **No autocomplete.** No identifier suggestions; 2d-i's vocabulary is not wired here.

## Design

### Units

| Unit | Where | Does |
|---|---|---|
| `SQLTokenizer` | `WakilKit`, pure | Splits text into tokens, each a kind plus its exact source range. Kinds: keyword, identifier, quotedIdentifier, string, number, comment, operator, punctuation, whitespace. **Lossless**: joining the token texts gives the input byte for byte. |
| `SQLStyle` | `WakilKit`, pure | Maps a token kind to `(opacity, weight, italic)`. No colour value. |
| `SQLFormat` | `WakilKit`, pure | `format(_ text: String, dialect: QueryDialect) -> SQLFormatResult`, which is either `.formatted(String)` or `.unchanged(reason: String)`. |
| `QueryLineEditor` | `WakilApp` | An `NSTextView` on TextKit 2, after `ApiFieldEditor`'s pattern. Wraps, grows to 6 lines, then scrolls. Restyles from `SQLStyle` on every change. Handles the keys. Every substitution is off. |
| `DBPane.queryLine()` | `WakilApp` | Replaces the `TextField` with `QueryLineEditor`, adds the Format control, and shows the "not formatted" line. |

`QueryDialect` is `.sql` or `.mongo`, read from the chosen database's driver
(`mongo` → `.mongo`, anything else → `.sql`).

### The tokenizer

- **Strings:** `'…'` with `''` and `\'` escapes. A quoted token containing a backslash is read
  differently by MySQL (escapes) and SQLite (none), so Format leaves such a line unchanged.
- **Quoted identifiers:** `` `…` `` (MySQL) and `"…"` (SQLite and Postgres).
- **Comments:** `-- …` and `# …` to the next `\n`, and `/* … */`. `#` is a comment in every SQL
  dialect (Ruling 1). Postgres `$$…$$` is not lexed, so a Postgres driver must teach the
  tokenizer dollar quotes before Format is enabled for it (Ruling 5).
- **Numbers:** integer, decimal and exponent forms.
- **Keywords:** a fixed, case-insensitive set. Any other word is an identifier.
- **An unterminated string, quoted identifier or block comment** becomes one token running
  to the end of the text, with `unterminated` set. Lossless still holds.

### The style (opacity steps on the editor's text colour `#e8ecf6`)

| Kind | Opacity | Weight | Italic |
|---|---|---|---|
| keyword | 1.0 | medium | no |
| identifier, quotedIdentifier | 0.85 | regular | no |
| string, number | 0.6 | regular | no |
| operator, punctuation | 0.6 | regular | no |
| comment | 0.4 | regular | yes |

The editor face is the current line's: monospaced, 11 pt.

### Format: SQL

- **Break before each top-level clause keyword:**
  - `SELECT`, `FROM`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`, `OFFSET`
  - `UNION` / `UNION ALL`, `INTERSECT`, `EXCEPT`
  - `INSERT INTO`, `VALUES`, `UPDATE`, `SET`, `DELETE FROM`, `RETURNING`
  - every `JOIN` form, with its `ON` kept on the same line
- **`AND` / `OR`:** at the top level of a `WHERE` or `HAVING`, each starts a new line,
  indented two spaces.
- **Select lists:** one line if the clause fits in 80 characters. Otherwise one item per
  line, indented two spaces.
- **Subqueries:** a `(SELECT …)` is laid out by the same rules, indented two spaces per
  level. Any other parentheses stay on one line.
- **Comments:** a `--` or `#` comment always ends its line. Comments keep their position
  relative to their neighbouring tokens.
- **Whitespace:** Format rewrites only whitespace already present. A run of spaces, tabs and
  newlines between two tokens becomes one space, a line break, or nothing before `,` `)` `.`
  `;` and after `(` `.`. Tokens that touch stay touching (`COUNT(*)`, `$1`, `@@x`,
  `SELECT*FROM`); the only exception is a subquery's `(` and `)`, which take their line
  breaks. A keyword after `.` is a name, never a clause. A run containing any other
  whitespace (NBSP, form feed, U+2028) is kept byte for byte, and a newline between two
  strings stays a newline. Leading and trailing whitespace is trimmed. (Rulings 2–4)

### Format: Mongo

The JSON spec is pretty-printed with two-space indents. Object key order is preserved.

### The safety rule

Format compares the token sequence with whitespace dropped, before and after. **Unless the
two sequences are identical, by kind and by text, Format returns `.unchanged`.** So a
format can never alter what runs. Format also returns `.unchanged` with a reason when:

- a token is `unterminated`, e.g. "a string opened at character 42 never closes";
- the Mongo JSON does not parse, with the parser's own message;
- the text is empty.

The check is only as strong as the tokenizer's agreement with every engine Wakil ships.
Where they read text differently (a backslash in a quoted token, `[`, a `--` not followed by
whitespace), Format returns `.unchanged` (Ruling 7).
A combining mark joined to ASCII punctuation (Swift reads one character where a database reads two) also returns `.unchanged`.

### The editor

- **Return** runs the line's text (`run(text)`). **⇧Return** inserts a newline.
  **⌥⇧F** formats.
- **Escape** leaves the field and keeps the text.
- **Undo:** the text storage is the undo target. Format registers as one undo step. When
  outside text is taken (a sort, a page, the agent, a restore), the undo stack is cleared,
  as in `ApiFieldEditor`'s Ruling 12.
- **Height:** grows with the wrapped content from one line up to six, then scrolls.
- **Accessibility:** the line has no accessibility identifier today, and no check reaches
  it. The editor gets `db.<paneId>.queryLine`, the Format control `db.<paneId>.format`,
  and the "not formatted" line's text is plain text so a check can read it.
- **State:** binds to the same `text` and `lastRendered` state as today.
  `shouldAdoptSubject`, `QueryLineRestore`, the refusal line and the database chooser are
  unchanged.
- **Caret:** after Format, the caret sits on the same token it sat on before, mapped
  through the token sequence.

### The "not formatted" line

When Format returns `.unchanged(reason)`, one dim line under the query line reads
`not formatted: <reason>`, drawn in the refusal line's style. The text is left as it was.
The line clears on the next edit. Nothing else is blocked, and Run runs the text as
written.

## Interaction Rules

| Rule | How this meets it |
|---|---|
| 1. Confirm only what destroys | No confirmation added |
| 2. Enter never required to keep input | Text stays when focus leaves, as today |
| 3. A new input arrives focused | No new input |
| 4. Anything that waits can be cancelled | Format is synchronous and local; nothing waits |
| 5. Work in flight shows it | Unchanged: running a query is the existing path |
| 6. Stay where the operator was | Format keeps the caret on its token. Wrapping grows the line, not the pane's position |
| 7. Override or ignore; don't refuse | An unsafe Format leaves the text alone and says why. Run is never refused by it |
| 8. Errors shown whole | The "not formatted" reason is whole and blocks nothing |
| 9. Defaults suggest | No defaults |

## Testing

- **`SQLTokenizer`:**
  - Lossless join over a corpus: every SQL string in the repo's Swift and Go test fixtures
    and e2e checks, collected into a test resource. Plus edge cases: backticks, `""`,
    `''` and `\'` escapes, `--` / `#` / `/* */` comments, an unterminated string, an
    unterminated block comment, and the empty string.
- **`SQLFormat`:**
  - Expected outputs for the clause, `JOIN … ON`, `AND`/`OR`, select-list wrapping at
    80 characters, subquery indentation, and comment placement rules.
  - Over the same corpus: whitespace-free tokens are identical before and after.
  - Idempotence: formatting twice gives the same result as formatting once.
  - Unterminated input and bad JSON return `.unchanged` with their reasons.
  - Mongo JSON pretty-prints with key order preserved.
- **`SQLStyle`:** every kind maps to the table above, and no output carries a colour other
  than the text colour.
- **e2e (the Cover rung):**
  - a long query shows whole;
  - Return runs it, and ⇧Return adds a line;
  - ⌥⇧F formats;
  - the agent re-queries the pane and the line shows the new text, and ⌘Z does not bring the
    old text back; separately, a sort with unsaved edits keeps the edits;
  - the "not formatted" line appears for an unterminated string.

## Exit criterion

On the walk, the operator:

1. runs a long query and sees it whole across several lines;
2. sees keywords stand out by brightness alone, with no colour;
3. presses Format and sees one clause per line;
4. presses ⌘Z and gets the previous layout back;
5. presses Format on a query with an unterminated string and sees the reason, with the
   text unchanged;
6. the agent re-queries the pane and the line shows the new text, and ⌘Z does not bring the
   old text back; separately, a sort with unsaved edits keeps the edits.
