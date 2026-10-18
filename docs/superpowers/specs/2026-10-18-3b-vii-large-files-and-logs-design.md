# 3b-vii: large files and logs — a growing log followed in the editor

**Date:** 2026-10-18
**Status:** design approved by the operator 2026-10-18, section by section
**Sub-phase:** 3b-vii, which follows 3b-iv-b (main a639cf6). It waits on nothing. 3b-vi (scratch
buffers sent to other panes) is parked; see Charter changes.

---

## Problem

The editor's sixth use is "orienting and reading logs" (open-questions #4). Today a file over 2 MB
opens as an empty read-only tab whose notice still says "files over 2 MB open in 3b-v"; a log under
2 MB reloads whole on every write, which closes anything the operator opened and never follows the
bottom; and project search skips files over 2 MB without a word. The operator's logs are mostly
Laravel's `storage/logs/laravel.log`, watched while a bug is reproduced.

## Decisions the operator took during this design (2026-10-18)

- **Design for the growing log first.** Large static files ride on the same read-only view.
- **Over 2 MB, the tab holds the last 2 MB**, read-only, with a strip saying so. No paged viewer for
  the whole file: the latest entries are what a log is opened for, and Monaco holds 2 MB easily.
- **Follow like a terminal.** At the bottom, the view moves with new lines; scrolled up, it stays.
  No button, no setting.
- **A small log syntax for `.log`**: dim timestamp, red `ERROR` and above, amber `WARNING`, dimmed
  stack-trace lines.
- **Each entry folds, and starts folded**, so a screen shows one line per entry.
- **Search keeps skipping files over 2 MB but says which.**
- **Approach: append only the new bytes.** Reloading the whole file on each write re-sends up to
  2 MB and closes opened traces; reading files from Swift would put file I/O outside the Go layer.

## What the operator gets

- Opening `laravel.log` (tree, ⌘P — gitignored files are already listed) shows it at the bottom,
  coloured, each entry folded to its first line.
- While a bug is reproduced, new entries arrive folded at the bottom and the view follows them.
  Scrolling up to read a trace stops the following; scrolling back to the bottom resumes it.
- A log over 2 MB shows its last 2 MB under the strip `Showing the last 2 MB of 300 MB`, the size
  kept current as it grows. Typing does nothing: the tab is read-only.
- `> laravel.log` or a rotation empties the tab and starts again from the new content.
- ⌘⇧F lists under its results `1 file over 2 MB not searched: storage/logs/laravel.log` (past three
  names, `…and N more`).

## What it does not do

- No paged viewer for a whole large file, no editing a tail, no search inside the unread part.
- No log formats beyond the patterns below; no filtering by level.
- No follow for files other than `.log` and tail tabs: they reload whole, as today.

## Design

### Go — `internal/wakilcore/files.go`, `files_read`

- **No `from`, file over `FileCap`:** read the last `FileCap` bytes, drop up to and including the
  first `\n` (so the text starts at a line), and reply `tail: true`, `start` (the byte offset of the
  first byte returned), `size`, `mtime` and the text. Replaces today's text-less `over_cap` reply.
- **With `from`** (a byte offset): if `size < from`, reply `shrunk: true` and no text. Else read from
  `from` to the end, at most `FileCap` bytes, and cut after the last `\n`; reply the text and `end`
  (the offset after it). A chunk with no `\n` yet returns empty text and `end == from`. Cutting at a
  newline keeps every chunk whole lines and never splits a UTF-8 character.
- If more than `FileCap` bytes lie past `from`, reply `too_far: true` and no text; the tab reloads as
  a fresh tail.
- The binary and UTF-8 checks run on the bytes read, as today.

### Go — `files_search`

- `SearchResult` gains `skipped_large: [path]`: the files skipped for being over `FileCap`
  (relative to their root, sorted, all of them). Binary files stay silently skipped.

### WakilKit

- **`EditorTab`** gains `tailStart: Int?` (nil = the whole file) and `readTo: Int` (the byte offset
  the tab holds up to). A tail tab is `readOnly` with the notice
  `Showing the last 2 MB of <size>` (whole megabytes, as `megabytes(_:)` writes them).
- **Which tabs append:** a tail tab, or a `.log` file with no unsaved edits. On a disk change,
  such a tab reads `from: readTo`:
  - text → append it, `readTo = end`, and update the notice's size;
  - `shrunk` or `too_far` → read afresh (no `from`), as on open;
  - deleted → `.deleted`, as today.
- A dirty `.log` keeps today's rule: `changedOnDisk`, edits kept, no append.
- A `.log` under 2 MB that grows past it while clean becomes a tail tab on its next fresh read.
- Every other file keeps `editorAfterDiskRead` as it is.
- **`editorLanguage(forPath:)`** maps `.log` to `log`. `editorFileGlyph` shows the plain page (Seti
  has no log glyph).
- **Search:** the results view shows the `skipped_large` line when it is not empty.
- The stale `files over 2 MB open in 3b-v` notice goes.

### WakilApp — `monaco-host.html`

- **`log` language** (a Monarch tokenizer), coloured by the `wakil` theme:
  - `^\[\d{4}-\d{2}-\d{2}[ T][^\]]*\]` → dim (the comment tone);
  - `\.(EMERGENCY|ALERT|CRITICAL|ERROR):` → red `#e85c5c`; `\.WARNING:` → amber `#e8b45a`;
  - lines starting `#\d+ ` or `[stacktrace]` → dim;
  - everything else plain.
- **Folding:** a folding-range provider for `log` — each entry from its timestamp line to the line
  before the next timestamp line (or the end); a one-line entry has no range. After a model is set,
  and after each append, the new entries' ranges are folded; ranges the operator opened are left
  alone. ⌘K ⌘J unfolds all (Monaco's own).
- **Append:** a new host call appends text at the end of the model. Before it, the host notes
  whether the last line is visible; after it, if it was, it reveals the new last line.
- A log tab opens scrolled to the bottom.

### Interaction rules

- **Rule 6 (stay where the operator was):** the view only moves when it is already at the bottom.
- **Rule 9 (defaults suggest):** folded is the starting state; an opened trace stays open.
- **Rule 7 (don't refuse):** a tail tab is read-only like today's read-only tabs — typing does
  nothing, no dialog.
- **Rule 8 (errors whole):** the notices are whole sentences, never truncated.

## Errors and edges

- **The log is emptied or rotated:** `shrunk`, the tab reloads from the new content.
- **Deleted:** the tab is marked deleted, as today.
- **More than 2 MB written between reads:** `too_far`, the tab reloads as a fresh tail.
- **A NUL byte or invalid UTF-8 in an appended chunk:** the tab stops following and its notice says
  `<name> now holds binary data; it stopped following` (or `…is no longer UTF-8…`). Reopening reads
  it afresh.
- **A last line still being written** (no `\n`): it waits for the next read.
- **A 2 MB tail with no newline at all** (one giant line): the text is the whole 2 MB, unstripped.

## Testing

- **Go** (`files_test.go`): the tail starts after a newline and reports `start`; `from` ends at the
  last newline and reports `end`; no newline yet → empty; `shrunk`; `too_far`; `skipped_large`.
- **Swift** (`WakilKitTests`): append versus fresh read per tab kind and reply; the notice text and
  its size update; a dirty `.log` is not appended; `.log` maps to `log`; the search line's wording
  for one, three and five files.
- **e2e** (the auditor, at Cover): the notice strip and the search line are visible to accessibility.
- **Walk:** a real `laravel.log` grown by a script: following, stopping when scrolled up, folding,
  colours, a 3 MB log's tail, `> laravel.log`.

## Charter changes this sub-phase makes

- **Decision 37, amended:** 3b-vi (scratch buffers sent to other panes) is **parked** by the operator
  on 2026-10-18 — the DB pane's query line already wraps, colours and formats SQL, so only sending a
  selection to a terminal pane had value, and not enough to build now. The later rows keep their
  numbers.
- **`design-language.md`**, §5 Colour: one sentence — in a log, red and amber mark error and warning
  levels, their meaning in §5.
- No Invariant, no new Decision: `files_read` stays a read inside the roots.
