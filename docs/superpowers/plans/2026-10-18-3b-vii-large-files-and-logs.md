# 3b-vii: Large Files and Logs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A growing Laravel log is followed in the editor: over 2 MB it opens as its last 2 MB, new lines are appended (not reloaded), the view follows when at the bottom, entries are coloured and fold, and project search names the large files it skipped.

**Architecture:** `files_read` gains a tail reply and a `from` byte offset (Go). WakilKit keeps how far each tab has read (`readTo`), decides append versus fresh read on `editor_refresh`, and emits a new `.append` render step when the store's text only grew. The Monaco host gets a `log` language, a folding provider, and `wakilAppendText`, which follows the bottom.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-files`), Swift 6 (WakilKit, WakilApp), Monaco (Monarch tokenizer, folding provider) in `monaco-host.html`.

**Spec:** `docs/superpowers/specs/2026-10-18-3b-vii-large-files-and-logs-design.md`

## Global Constraints

- The cap is `FileCap` (`2 << 20` bytes) everywhere; no new size constant except `2 * FileCap` (Ruling R1).
- Tail notice, exactly: `Showing the last 2 MB of <N MB>`, `<N MB>` written by the existing `megabytes(_:)` in `EditorActions.swift`.
- Search line, exactly: `1 file over 2 MB not searched: <path>`; `N files over 2 MB not searched: <p1>, <p2>, <p3>` and, past three, `, …and <N-3> more`.
- Stop notices, exactly: `<name> now holds binary data; it stopped following` and `<name> is no longer UTF-8; it stopped following`.
- Colours: red `#e85c5c`, amber `#e8b45a` (design-language §5); dim `#7d8396`.
- Only tail tabs and `.log` files append; every other file keeps `editorAfterDiskRead` unchanged.
- Never add `Co-Authored-By` or "Generated with" lines to commits.
- Tests: `cd app && ../scripts/swift-test.sh --filter <name>` for Swift, `go test ./internal/wakilcore -run <name>` for Go; the suite is `make app-test` (after `make build` in a fresh worktree) and `go test ./...`.

**Rulings made while planning** (spec silent):
- **R1:** a tail tab whose text would pass `2 * FileCap` bytes after an append reads a fresh tail instead, so memory stays bounded and the notice stays true.
- **R2:** a clean `.log` under the cap whose reply `size` passes `FileCap` reads afresh at once (it becomes a tail tab), rather than "on its next fresh read".
- **R3:** the reply keeps `over_cap: true` for a tail (agents reading `files_read` keep their signal); WakilKit branches on `tail`.

## Review Focus

1. **A log written mid-line** (no trailing `\n` yet): the partial line must appear once, whole, never duplicated or split — pinned in Task 1 (`from` stops at the last newline) and Task 3 (append from `end`, not `size`).
2. **A log emptied by `> laravel.log` then written again past the old length before the refresh lands:** `size >= from` but the content is new. Accepted cost: the tab shows a wrong splice until the next shrink or reopen; noted in the walk as a known edge, not tested.
3. **The operator types in a clean small `.log` while a write lands:** the append must not eat the keystroke into a wrong store text — pinned in Task 3 (a dirty tab never appends) and Task 5 (host cancels the pending typing frame like `replaceWhole`).
4. **A tail tab while another tab is active:** the append lands in the store; when shown again, the planner's `.show` re-sends the model's whole text — pinned in Task 4 (`append` only for the active, rendered key).
5. **Search over a root with many big files:** the line lists at most three names — pinned in Task 6.

---

### Task 1: Go — `files_read` tail and `from`

**Files:**
- Modify: `internal/wakilcore/files.go:23-41` (FileRead), `:498-540` (ReadFile)
- Modify: `cmd/wakil-files/main.go:47-49` (readArg), `:148-159` (tool)
- Test: `internal/wakilcore/files_test.go`

**Interfaces:**
- Produces: `ReadFile(path string, roots []string) (FileRead, error)` (unchanged signature; over the cap it now returns a tail) and `ReadFileFrom(path string, from int, roots []string) (FileRead, error)`. `FileRead` gains `Tail bool json:"tail"`, `Start int json:"start"`, `End int json:"end"`, `Shrunk bool json:"shrunk"`, `TooFar bool json:"too_far"`. Tool arg `from` (optional integer).

- [ ] **Step 1: Write the failing tests** — replace `TestFilesReadOverTheCapReturnsNoText` and add:

```go
func TestFilesReadOverTheCapReturnsTheTailFromALineStart(t *testing.T) {
	a, _, _ := filesRoots(t)
	head := strings.Repeat("x", FileCap) // pushed out of the window
	body := "partial line\n[2026-10-18 13:33:20] local.ERROR: boom\nlast\n"
	write(t, filepath.Join(a, "laravel.log"), head+body)
	r, err := ReadFile(filepath.Join(a, "laravel.log"), []string{a})
	if err != nil || !r.Tail || !r.OverCap || r.Size != len(head)+len(body) {
		t.Fatalf("got %+v %v", r, err)
	}
	if strings.HasPrefix(r.Text, "x") || !strings.HasSuffix(r.Text, "local.ERROR: boom\nlast\n") {
		t.Fatalf("tail does not start at a line: %q…", r.Text[:40])
	}
	if r.Start != r.Size-len(r.Text) || r.End != r.Size {
		t.Fatalf("start %d end %d size %d len %d", r.Start, r.End, r.Size, len(r.Text))
	}
}

func TestFilesReadFromReturnsWholeLinesAfterTheOffset(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "laravel.log")
	write(t, p, "one\ntwo\nthr")
	r, err := ReadFileFrom(p, 4, []string{a})
	if err != nil || r.Text != "two\n" || r.End != 8 || r.Size != 11 {
		t.Fatalf("got %+v %v", r, err)
	}
	r, _ = ReadFileFrom(p, 8, []string{a})
	if r.Text != "" || r.End != 8 {
		t.Fatalf("a line still being written must wait: %+v", r)
	}
}

func TestFilesReadFromAShorterFileSaysShrunk(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "laravel.log")
	write(t, p, "new\n")
	r, err := ReadFileFrom(p, 100, []string{a})
	if err != nil || !r.Shrunk || r.Text != "" {
		t.Fatalf("got %+v %v", r, err)
	}
}

func TestFilesReadFromTooFarBehindSaysTooFar(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "laravel.log")
	write(t, p, strings.Repeat("y\n", FileCap)) // 2×FileCap bytes past offset 0
	r, err := ReadFileFrom(p, 0, []string{a})
	if err != nil || !r.TooFar || r.Text != "" {
		t.Fatalf("got %+v %v", r, err)
	}
}

func TestFilesReadFromFlagsABinaryChunk(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "laravel.log")
	write(t, p, "ok\n\x00bad\n")
	r, _ := ReadFileFrom(p, 3, []string{a})
	if !r.Binary || r.Text != "" {
		t.Fatalf("got %+v", r)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore -run 'TestFilesRead(OverTheCap|From)'`
Expected: FAIL — `undefined: ReadFileFrom` (compile error).

- [ ] **Step 3: Implement.** In `files.go`, change the `FileCap` comment to `// FileCap is the most text files_read returns at once; over it, the file's last FileCap bytes (3b-vii).`, add the fields to `FileRead`, and replace the over-cap branch and add `ReadFileFrom`:

```go
type FileRead struct {
	Path    string `json:"path"`
	Root    string `json:"root"`
	Text    string `json:"text"`
	Size    int    `json:"size"`
	Mtime   int64  `json:"mtime"`
	Binary  bool   `json:"binary"`
	UTF8    bool   `json:"utf8"`
	OverCap bool   `json:"over_cap"`
	Exists  bool   `json:"exists"`
	// Tail: over the cap, Text is the file's last FileCap bytes from the first line start; Start is
	// its offset. End is the offset after Text (3b-vii).
	Tail   bool `json:"tail"`
	Start  int  `json:"start"`
	End    int  `json:"end"`
	Shrunk bool `json:"shrunk"`  // from: the file is now shorter than from
	TooFar bool `json:"too_far"` // from: more than FileCap bytes lie past from
}
```

```go
	r := FileRead{Path: real, Root: root, Size: int(info.Size()), Mtime: info.ModTime().UnixNano(), Exists: true}
	var data []byte
	if r.Size > FileCap {
		r.OverCap, r.Tail = true, true
		chunk, rerr := readAt(real, r.Size-FileCap, FileCap)
		if rerr != nil {
			return FileRead{}, rerr
		}
		r.Start = r.Size - FileCap
		if i := bytes.IndexByte(chunk, '\n'); i >= 0 && i+1 < len(chunk) {
			chunk, r.Start = chunk[i+1:], r.Start+i+1
		}
		data = chunk
	} else if data, err = os.ReadFile(real); err != nil {
		return FileRead{}, err
	}
	r.End = r.Start + len(data)
	classify(&r, data)
	return r, nil
}

// classify sets Binary, UTF8 and Text from data, as files_read always has.
func classify(r *FileRead, data []byte) {
	switch {
	case bytes.IndexByte(data, 0) >= 0:
		r.Binary = true
	case !utf8.Valid(data):
		r.UTF8 = false
	default:
		r.UTF8 = true
		r.Text = string(data)
	}
}

// readAt reads n bytes of the file at real from off.
func readAt(real string, off, n int) ([]byte, error) {
	f, err := os.Open(real)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	buf := make([]byte, n)
	m, err := f.ReadAt(buf, int64(off))
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	return buf[:m], nil
}

// ReadFileFrom reads the whole lines past byte offset from (3b-vii: a growing log). Shrunk when
// the file is now shorter than from; TooFar when more than FileCap bytes lie past it. Text stops
// after the last newline, so a line still being written waits for the next read.
func ReadFileFrom(path string, from int, roots []string) (FileRead, error) {
	real, root, err := ConfineFilePath(path, roots, false)
	if err != nil {
		return FileRead{}, err
	}
	info, err := os.Stat(real)
	if errors.Is(err, fs.ErrNotExist) {
		return FileRead{Path: real, Root: root, UTF8: true}, nil
	}
	if err != nil {
		return FileRead{}, err
	}
	if !info.Mode().IsRegular() {
		return FileRead{}, UserError(path + " is not a regular file; the editor opens regular files only")
	}
	r := FileRead{Path: real, Root: root, Size: int(info.Size()), Mtime: info.ModTime().UnixNano(), Exists: true,
		Start: from, End: from, UTF8: true}
	switch {
	case r.Size < from:
		r.Shrunk = true
		return r, nil
	case r.Size-from > FileCap:
		r.TooFar = true
		return r, nil
	}
	data, err := readAt(real, from, r.Size-from)
	if err != nil {
		return FileRead{}, err
	}
	data = data[:bytes.LastIndexByte(data, '\n')+1]
	r.End = from + len(data)
	classify(&r, data)
	return r, nil
}
```

Add `"io"` to the imports. In `cmd/wakil-files/main.go`:

```go
type readArg struct {
	Path string `json:"path" jsonschema:"absolute path of a file inside one of the active project's roots"`
	From *int   `json:"from,omitempty" jsonschema:"byte offset: answer only the whole lines after it (a growing log)"`
}
```

and the tool:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "files_read", Description: "Read-only. One file's text, size and mtime (Unix ns). Over 2 MB, the last 2 MB from a line start (tail, over_cap, start). With from (a byte offset), only the whole lines after it, end the offset after them; shrunk when the file is now shorter than from, too_far when more than 2 MB lie past it. No text for a binary file (binary) or a file that is not UTF-8 (utf8 false); exists false for a missing file; a FIFO, socket or device is refused. Confined to the active project's roots."},
		func(_ context.Context, _ *mcp.CallToolRequest, a readArg) (*mcp.CallToolResult, wakilcore.FileRead, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileRead{}, nil
			}
			var r wakilcore.FileRead
			var err error
			if a.From != nil {
				r, err = wakilcore.ReadFileFrom(a.Path, *a.From, rs)
			} else {
				r, err = wakilcore.ReadFile(a.Path, rs)
			}
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileRead{}, nil
			}
			return nil, r, nil
		})
```

- [ ] **Step 4: Run them to see them pass**, then the package

Run: `go test ./internal/wakilcore -run 'TestFilesRead' && go test ./internal/wakilcore ./cmd/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/files.go internal/wakilcore/files_test.go cmd/wakil-files/main.go
git commit -m "3b-vii: files_read answers a large file's tail, and reads from an offset"
```

---

### Task 2: Go — `files_search` names the large files it skipped

**Files:**
- Modify: `internal/wakilcore/files.go:610-615` (SearchResult), `:690-700` (the skip)
- Modify: `cmd/wakil-files/main.go:112` (description)
- Test: `internal/wakilcore/files_test.go`

**Interfaces:**
- Produces: `SearchResult.SkippedLarge []string json:"skipped_large"` — root-relative slash paths, sorted per root in listing order, never nil.

- [ ] **Step 1: Write the failing test**

```go
func TestFilesSearchNamesTheLargeFilesItSkipped(t *testing.T) {
	a, b := searchFixture(t)
	write(t, filepath.Join(a, "storage", "laravel.log"), strings.Repeat("bookingId\n", FileCap/9))
	r, err := SearchFiles(context.Background(), []string{a, b}, testHeavy, nil, SearchQuery{Query: "bookingId"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(r.SkippedLarge, ",") != "storage/laravel.log" {
		t.Fatalf("skipped %v", r.SkippedLarge)
	}
}
```

(If `searchFixture`'s roots are git repositories that ignore `storage/`, write the file at `a/big.log` instead and expect `big.log`; check `searchFixture` first.)

- [ ] **Step 2: Run it to see it fail**

Run: `go test ./internal/wakilcore -run TestFilesSearchNamesTheLargeFilesItSkipped`
Expected: FAIL — `r.SkippedLarge undefined`.

- [ ] **Step 3: Implement.** Add the field and fill it:

```go
type SearchResult struct {
	Matches   []SearchMatch `json:"matches"`
	Truncated bool          `json:"truncated"`
	// FilesTruncated: some root's listing hit FileListCap, so it was searched only in part.
	FilesTruncated bool `json:"files_truncated"`
	// SkippedLarge: the files over FileCap that were not searched, root-relative (3b-vii).
	SkippedLarge []string `json:"skipped_large"`
}
```

`res := SearchResult{Matches: []SearchMatch{}, SkippedLarge: []string{}}`, and split the stat check:

```go
			info, serr := os.Stat(p)
			if serr != nil || !info.Mode().IsRegular() {
				continue
			}
			if info.Size() > FileCap {
				res.SkippedLarge = append(res.SkippedLarge, rel)
				continue
			}
```

Tool description: replace `as are binary files and files over 2 MB.` with `as are binary files and files over 2 MB (named in skipped_large).`

- [ ] **Step 4: Run it to see it pass**

Run: `go test ./internal/wakilcore -run TestFilesSearch`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/files.go internal/wakilcore/files_test.go cmd/wakil-files/main.go
git commit -m "3b-vii: files_search names the files over 2 MB it skipped"
```

---

### Task 3: WakilKit — tail tabs, `.log`, and appending on refresh

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorSnapshot.swift` (EditorTab: two properties)
- Modify: `app/Sources/WakilKit/Editor/EditorTabs.swift:48-65` (`.log`)
- Modify: `app/Sources/WakilKit/Editor/EditorActions.swift:136-156` (`editorTab(fromRead:)`), `:1158-1170` (`editor_refresh`)
- Modify: `app/Tests/WakilKitTests/EditorTestSupport.swift` (FakeFiles: tail and `from`)
- Test: `app/Tests/WakilKitTests/EditorLogTests.swift` (new), `EditorActionsTests.swift:68-77` (notice), `EditorTabsTests.swift`

**Interfaces:**
- Consumes: Task 1's reply keys `tail`, `start`, `end`, `size`, `shrunk`, `too_far`, `binary`, `utf8`.
- Produces: `EditorTab.tailStart: Int?`, `EditorTab.readTo: Int`, `editorAppends(_ tab: EditorTab) -> Bool`, `enum EditorAppendOutcome { case unchanged, appended(EditorTab), reread, stopped(EditorTab), deleted }`, `editorAfterAppendRead(_ tab: EditorTab, reply: [String: JSONValue]) -> EditorAppendOutcome`, `editorTailNotice(size: Int) -> String`.

- [ ] **Step 1: Give FakeFiles tails and `from`.** In `EditorTestSupport.swift` add `var tails: [String: (text: String, start: Int, size: Int)] = [:]`, `func putTail(_ path: String, text: String, start: Int, size: Int) { clock += 1; tails[path] = (text, start, size); disk[path] = nil }`, and at the top of `case "files_read":`:

```go
            if let tl = tails[path] {
                return ok(["path": .string(path), "exists": .bool(true), "text": .string(tl.text), "utf8": .bool(true),
                           "binary": .bool(false), "over_cap": .bool(true), "tail": .bool(true),
                           "start": .integer(Int64(tl.start)), "end": .integer(Int64(tl.size)),
                           "size": .integer(Int64(tl.size)), "mtime": .integer(clock)])
            }
            if case .object(let a) = arguments, let from = a["from"]?.intValue {
                calls[calls.count - 1] += " from \(from)"
                guard let f = disk[path] else { return ok(["path": .string(path), "exists": .bool(false), "text": .string(""),
                                                          "utf8": .bool(true), "size": .integer(0), "mtime": .integer(0)]) }
                let bytes = Array(f.text.utf8)
                if bytes.count < from { return ok(["exists": .bool(true), "shrunk": .bool(true), "text": .string(""),
                                                   "utf8": .bool(true), "size": .integer(Int64(bytes.count)), "mtime": .integer(f.mtime)]) }
                if bytes.count - from > 2 << 20 { return ok(["exists": .bool(true), "too_far": .bool(true), "text": .string(""),
                                                             "utf8": .bool(true), "size": .integer(Int64(bytes.count)), "mtime": .integer(f.mtime)]) }
                var chunk = Array(bytes[from...])
                chunk = Array(chunk[..<((chunk.lastIndex(of: 0x0A) ?? -1) + 1)])
                let text = String(decoding: chunk, as: UTF8.self)
                return ok(["exists": .bool(true), "text": .string(text), "utf8": .bool(true), "binary": .bool(text.contains("\0")),
                           "start": .integer(Int64(from)), "end": .integer(Int64(from + chunk.count)),
                           "size": .integer(Int64(bytes.count)), "mtime": .integer(f.mtime)])
            }
```

(`put` must also clear `tails[path] = nil`.) Return `"binary": true` with empty text when the chunk holds `\0`, as Go does: if `text.contains("\0")`, send `"text": ""`.

- [ ] **Step 2: Write the failing tests** in `EditorLogTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private let log = "/p/api/storage/logs/laravel.log"

@Test func aLogMapsToTheLogLanguage() {
    #expect(editorLanguage(forPath: log) == "log")
    #expect(editorFileGlyph(forPath: log) == "\u{E023}")
}

@Test func aLargeFileOpensAsItsTailReadOnlyWithTheNotice() async throws {
    let f = try await editorFixture()
    await f.files.putTail(log, text: "b\nc\n", start: 299_999_996, size: 300_000_000)
    try await f.dispatch("editor_open", ["path": .string(log)])
    let t = await f.snapshot().tabs[0]
    #expect(t.readOnly && t.text == "b\nc\n" && t.tailStart == 299_999_996 && t.readTo == 300_000_000)
    #expect(t.notice == "Showing the last 2 MB of 300 MB")
    #expect(t.cursor.line == 3, "a log opens at its bottom")
}

@Test func aGrowingLogIsAppendedNotReloaded() async throws {
    let f = try await editorFixture()
    await f.files.put(log, "one\n")
    try await f.dispatch("editor_open", ["path": .string(log)])
    await f.files.put(log, "one\ntwo\nthr")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "one\ntwo\n" && t.readTo == 8 && !t.dirty)
    #expect(await f.files.calls.contains("files_read \(log) from 4"))
    await f.files.put(log, "one\ntwo\nthree\n")
    try await f.dispatch("editor_refresh", origin: .ui)
    #expect(await f.snapshot().tabs[0].text == "one\ntwo\nthree\n", "the partial line arrives once, whole")
}

@Test func aShrunkLogIsReadAfresh() async throws {
    let f = try await editorFixture()
    await f.files.put(log, "one\ntwo\n")
    try await f.dispatch("editor_open", ["path": .string(log)])
    await f.files.put(log, "new\n")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "new\n" && t.readTo == 4)
}

@Test func aDirtyLogIsNeverAppended() async throws {
    let f = try await editorFixture()
    await f.files.put(log, "one\n")
    try await f.dispatch("editor_open", ["path": .string(log)])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine\n", basis: 0)
    await f.files.put(log, "one\ntwo\n")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "mine\n" && t.diskState == .changedOnDisk)
}

@Test func aTailTabGrowsAndItsNoticeFollowsTheSize() {
    var tab = EditorTab.file(path: log, root: "/p/api", text: "a\n", mtime: 1, language: "log")
    tab.readOnly = true; tab.tailStart = 2_999_998; tab.readTo = 3_000_000
    let reply: [String: JSONValue] = ["exists": .bool(true), "text": .string("b\n"), "utf8": .bool(true),
                                      "end": .integer(3_000_002), "size": .integer(3_000_002), "mtime": .integer(2)]
    guard case .appended(let t) = editorAfterAppendRead(tab, reply: reply) else { Issue.record("not appended"); return }
    #expect(t.text == "a\nb\n" && t.readTo == 3_000_002 && t.notice == "Showing the last 2 MB of 3 MB")
}

@Test func aTailPastTwiceTheCapIsReadAfresh() {
    var tab = EditorTab.file(path: log, root: "/p/api", text: String(repeating: "x", count: 2 * (2 << 20) - 1),
                             mtime: 1, language: "log")
    tab.tailStart = 0; tab.readTo = 10
    let reply: [String: JSONValue] = ["exists": .bool(true), "text": .string("yy\n"), "utf8": .bool(true),
                                      "end": .integer(13), "size": .integer(13), "mtime": .integer(2)]
    #expect(editorAfterAppendRead(tab, reply: reply) == .reread)
}

@Test func aSmallLogPassingTheCapIsReadAfresh() {
    let tab = EditorTab.file(path: log, root: "/p/api", text: "a\n", mtime: 1, language: "log")
    let reply: [String: JSONValue] = ["exists": .bool(true), "text": .string("b\n"), "utf8": .bool(true),
                                      "end": .integer(4), "size": .integer(3_000_000), "mtime": .integer(2)]
    #expect(editorAfterAppendRead(tab, reply: reply) == .reread)
}

@Test func aBinaryChunkStopsFollowingAndSaysSo() {
    var tab = EditorTab.file(path: log, root: "/p/api", text: "a\n", mtime: 1, language: "log")
    tab.readTo = 2
    let reply: [String: JSONValue] = ["exists": .bool(true), "text": .string(""), "binary": .bool(true), "utf8": .bool(true),
                                      "end": .integer(2), "size": .integer(9), "mtime": .integer(2)]
    guard case .stopped(let t) = editorAfterAppendRead(tab, reply: reply) else { Issue.record("not stopped"); return }
    #expect(t.notice == "laravel.log now holds binary data; it stopped following" && t.readOnly)
    #expect(!editorAppends(t))
}

@Test func otherFilesNeverAppend() {
    #expect(!editorAppends(EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "", mtime: 1, language: "go")))
}
```

In `EditorActionsTests.swift:68-77`, rename to `anOverCapFileWithNoTailOpensReadOnlyWithItsNoticeWhole` and expect `"dump.sql is 48 MB and could not be read as text"` (the over-cap-without-tail fallback: a binary tail answers `binary`, so this only shows for an old `wakil-files`); update `:306` and `:347` the same way if they assert the old text.

- [ ] **Step 3: Run them to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter "EditorLogTests|anOverCapFile"`
Expected: FAIL — `tailStart`, `readTo`, `editorAfterAppendRead`, `putTail` undefined.

- [ ] **Step 4: Implement.**

`EditorSnapshot.swift`, in `EditorTab` beside `readOnly`:

```swift
    /// The byte offset the tab's text starts at, when it holds a large file's tail (3b-vii); nil = the whole file.
    public var tailStart: Int? = nil
    /// The byte offset the tab has read its file up to: where the next append reads from (3b-vii).
    public var readTo: Int = 0
```

`EditorTabs.swift`: `case "log": return "log"` before `default`.

`EditorActions.swift`, replacing `editorTab(fromRead:)`'s over-cap branch and adding the helpers:

```swift
public func editorTailNotice(size: Int) -> String { "Showing the last 2 MB of \(megabytes(size))" }

/// A tab from a `files_read` reply. A large file's tail opens read-only with its notice; binary or
/// not UTF-8 opens read-only with a notice. A log opens at its bottom (3b-vii).
func editorTab(fromRead o: [String: JSONValue], path: String, root: String) -> EditorTab {
    let name = (path as NSString).lastPathComponent
    let text: String = { if case .string(let s)? = o["text"] { s } else { "" } }()
    var tab = EditorTab.file(path: path, root: root, text: text, mtime: Int64(o["mtime"]?.intValue ?? 0),
                             language: editorLanguage(forPath: path))
    tab.readTo = o["end"]?.intValue ?? (o["size"]?.intValue ?? text.utf8.count)
    if o["exists"] == .bool(false) { tab.diskState = .deleted }
    if o["binary"] == .bool(true) {
        tab.readOnly = true
        tab.notice = "\(name) is a binary file"
    } else if o["utf8"] == .bool(false) {
        tab.readOnly = true
        tab.notice = "\(name) is not UTF-8; it opens read-only"
    } else if o["tail"] == .bool(true) {
        tab.readOnly = true
        tab.tailStart = o["start"]?.intValue ?? 0
        tab.notice = editorTailNotice(size: o["size"]?.intValue ?? 0)
    } else if o["over_cap"] == .bool(true) {
        tab.readOnly = true
        tab.notice = "\(name) is \(megabytes(o["size"]?.intValue ?? 0)) and could not be read as text"
    }
    if tab.language == "log" || tab.tailStart != nil {
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        tab.cursor = EditorPosition(line: lines, column: 1)
        tab.scrollTop = Double(lines) * 100        // past the end; Monaco clamps it to the bottom
    }
    return tab
}

/// Whether a disk change reaches this tab as an append (3b-vii): a tail, or a clean `.log` still following.
public func editorAppends(_ tab: EditorTab) -> Bool {
    guard case .file = tab.subject, tab.diskState != .deleted else { return false }
    if tab.notice?.hasSuffix("it stopped following") == true { return false }
    return tab.tailStart != nil || (tab.language == "log" && !tab.dirty)
}

public enum EditorAppendOutcome: Equatable {
    case unchanged, appended(EditorTab), reread, stopped(EditorTab), deleted
}

/// What an appending tab becomes after `files_read {from: readTo}` (3b-vii, Ruling R1 and R2).
public func editorAfterAppendRead(_ tab: EditorTab, reply o: [String: JSONValue]) -> EditorAppendOutcome {
    if o["exists"] == .bool(false) { return .deleted }
    if o["shrunk"] == .bool(true) || o["too_far"] == .bool(true) { return .reread }
    let size = o["size"]?.intValue ?? 0
    if tab.tailStart == nil && size > 2 << 20 { return .reread }
    let name = ((tab.path ?? "") as NSString).lastPathComponent
    var t = tab
    if o["binary"] == .bool(true) || o["utf8"] == .bool(false) {
        t.readOnly = true
        t.notice = o["binary"] == .bool(true) ? "\(name) now holds binary data; it stopped following"
                                              : "\(name) is no longer UTF-8; it stopped following"
        return .stopped(t)
    }
    let chunk: String = { if case .string(let s)? = o["text"] { s } else { "" } }()
    let end = o["end"]?.intValue ?? tab.readTo
    if chunk.isEmpty || end == tab.readTo {
        if tab.tailStart != nil { t.notice = editorTailNotice(size: size) }
        return t == tab ? .unchanged : .appended(t)
    }
    if tab.tailStart != nil && tab.text.utf8.count + chunk.utf8.count > 2 * (2 << 20) { return .reread }
    t.text += chunk
    t.savedText = t.text
    t.readTo = end
    t.mtime = Int64(o["mtime"]?.intValue ?? Int(tab.mtime))
    t.diskState = .inSync
    t.edits += 1
    if tab.tailStart != nil { t.notice = editorTailNotice(size: size) }
    return .appended(t)
}
```

(If `EditorTab` is not `Equatable`, compare `t.notice == tab.notice` instead of `t == tab`.) Also in `editorAfterDiskReadRaw`, after `t.readOnly = read.readOnly`, add `t.tailStart = read.tailStart; t.readTo = read.readTo` so a fresh read resets both.

`editor_refresh`: replace the read loop with one that appends where it can:

```swift
                var reads: [String: (fresh: EditorTab, basis: Int64)] = [:]
                var appended: [String: (outcome: EditorAppendOutcome, basis: Int64)] = [:]
                for tab in tabs {
                    guard case .file(let path, let r) = tab.subject, only == nil || r == only else { continue }
                    if editorAppends(tab), let files,
                       case .ok(let o)? = try? await filesTool(files, "files_read",
                                                               ["path": .string(path), "from": .integer(Int64(tab.readTo))]) {
                        let outcome = editorAfterAppendRead(tab, reply: o)
                        if outcome != .reread { appended[path] = (outcome, tab.mtime); continue }
                    }
                    if let fresh = try? await read(path, action: "editor_refresh") { reads[path] = (fresh, tab.mtime) }
                }
                let collectedAppends = appended
```

and inside `panes.updateEditor`, before the `collected` loop's body applies, handle appends first:

```swift
                    for i in s.tabs.indices {
                        guard let p = s.tabs[i].path, let (outcome, basis) = collectedAppends[p],
                              !s.tabs[i].saving, s.tabs[i].mtime == basis, s.tabs[i].readTo == tabs.first(where: { $0.path == p })?.readTo
                        else { continue }
                        switch outcome {
                        case .appended(let t), .stopped(let t): s.tabs[i] = t
                        case .deleted: s.tabs[i].diskState = .deleted
                        case .unchanged, .reread: break
                        }
                    }
```

(`EditorAppendOutcome` needs `Equatable`; `EditorTab` is `Equatable` if `EditorSnapshot` is — check and add `Equatable` conformance to the enum only.)

- [ ] **Step 5: Run them to see them pass**, then the editor suites

Run: `cd app && ../scripts/swift-test.sh --filter "EditorLogTests|EditorActionsTests|EditorRefreshTests|EditorBaselineTests|EditorTabsTests"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Editor app/Tests/WakilKitTests
git commit -m "3b-vii: a large file opens as its tail, and a log is appended to, not reloaded"
```

---

### Task 4: WakilKit — the `.append` render step

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorRenderer.swift:5-40` (protocol), `:63-76` (step), `:128-138` (planner), `:207-228` (apply)
- Modify: `app/Sources/WakilApp/MonacoEditorRenderer.swift:79-82`
- Test: `app/Tests/WakilKitTests/EditorRendererTests.swift` (and its `RecordingRenderer` at `:217`)

**Interfaces:**
- Produces: `EditorRenderStep.append(key: String, text: String, basis: Int)`, `EditorRenderer.appendText(key: String, text: String, basis: Int)`; host function `wakilAppendText(key, text, basis)` (Task 5 writes it).

- [ ] **Step 1: Write the failing test** beside the `.reset` tests (match their fixture helpers at `EditorRendererTests.swift:40-55`):

```swift
@Test func textThatOnlyGrewIsAppendedNotReset() {
    // Same shape as the reset test above: rendered "one\n", the store now "one\ntwo\n".
    let steps = planAfterDiskChange(rendered: "one\n", now: "one\ntwo\n")
    #expect(steps == [.append(key: "file:/p/a.go", text: "two\n", basis: 0)])
}

@Test func textThatChangedEarlierIsStillReset() {
    let steps = planAfterDiskChange(rendered: "one\n", now: "uno\ntwo\n")
    #expect(steps == [.reset(key: "file:/p/a.go", text: "uno\ntwo\n", basis: 0)])
}
```

Write `planAfterDiskChange(rendered:now:)` as a private helper in the test file from the body of the existing reset test at `:50-55` (one active file tab `/p/a.go`, `rendered` holding the old text, the snapshot holding the new).

- [ ] **Step 2: Run to see it fail**

Run: `cd app && ../scripts/swift-test.sh --filter "AppendedNotReset|StillReset"`
Expected: FAIL — `.append` is not a member.

- [ ] **Step 3: Implement.** Add `case append(key: String, text: String, basis: Int)` to `EditorRenderStep`; to the protocol:

```swift
    /// Append `text` at the end of a model (a growing log, 3b-vii). The page follows the bottom when
    /// the last line was in view, and folds new log entries.
    func appendText(key: String, text: String, basis: Int)
```

In the planner, the `else` branch that emits `.reset`:

```swift
                } else if r.text.isEmpty == false, t.text.hasPrefix(r.text) {
                    steps.append(.append(key: key, text: String(t.text.dropFirst(r.text.count)), basis: serial))
                } else {
                    steps.append(.reset(key: key, text: t.text, basis: serial))
                }
```

In `editorApply`: `case .append(let key, let text, let basis): renderer.appendText(key: key, text: text, basis: basis)`. `RecordingRenderer` records it like `resetText`. `MonacoEditorRenderer`:

```swift
    func appendText(key: String, text: String, basis: Int) {
        run("wakilAppendText(\(Self.js(key)),\(Self.js(text)),\(basis))")
    }
```

- [ ] **Step 4: Run to see it pass**, then the renderer suite

Run: `cd app && ../scripts/swift-test.sh --filter EditorRendererTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor/EditorRenderer.swift app/Sources/WakilApp/MonacoEditorRenderer.swift app/Tests/WakilKitTests/EditorRendererTests.swift
git commit -m "3b-vii: text that only grew reaches Monaco as an append"
```

---

### Task 5: WakilApp — the `log` language, folding and following in Monaco

**Files:**
- Modify: `app/Sources/WakilApp/monaco-host.html:67-90` (theme rules), after the theme (language), `:265-273` (`wakilShowModel`), after `wakilResetText` (`wakilAppendText`)

**Interfaces:**
- Consumes: `wakilAppendText(key, text, basis)` from Task 4; language id `log` from Task 3.

No unit test reaches the page (WakilApp has no test target). The proof is `make app-build` plus the walk; Cover adds what the auditor can see.

- [ ] **Step 1: Theme rules.** In `defineTheme('wakil', …)` replace `rules: []` with:

```js
      base: 'vs-dark', inherit: true, rules: [
        // 3b-vii: a log's levels, in §5's red and amber; its timestamps and traces dimmed.
        { token: 'log-time', foreground: '7d8396' },
        { token: 'log-trace', foreground: '7d8396' },
        { token: 'log-error', foreground: 'e85c5c' },
        { token: 'log-warn', foreground: 'e8b45a' }
      ],
```

- [ ] **Step 2: The language and its folds**, right after `defineTheme(...)`:

```js
    // 3b-vii: Laravel-style logs. An entry starts at a [date time] line and runs to the next.
    const logEntry = /^\[\d{4}-\d{2}-\d{2}[ T][^\]]*\]/;
    monaco.languages.register({ id: 'log' });
    monaco.languages.setMonarchTokensProvider('log', { tokenizer: { root: [
      [/^\[\d{4}-\d{2}-\d{2}[ T][^\]]*\]/, 'log-time'],
      [/\.(EMERGENCY|ALERT|CRITICAL|ERROR):/, 'log-error'],
      [/\.WARNING:/, 'log-warn'],
      [/^(#\d+ |\[stacktrace\]).*$/, 'log-trace'],
      [/[^\[.#]+/, ''],
      [/./, '']
    ] } });
    function logStarts(model, from) {
      const out = [];
      for (let l = from; l <= model.getLineCount(); l++) if (logEntry.test(model.getLineContent(l))) out.push(l);
      return out;
    }
    monaco.languages.registerFoldingRangeProvider('log', { provideFoldingRanges: function (model) {
      const s = logStarts(model, 1), ranges = [];
      for (let i = 0; i < s.length; i++) {
        const end = (i + 1 < s.length ? s[i + 1] : model.getLineCount() + 1) - 1;
        if (end > s[i]) ranges.push({ start: s[i], end: end });
      }
      return ranges;
    } });
    // Folds the entries starting at or after line `from` once the folding model has their ranges.
    function foldEntries(key, from) {
      setTimeout(function () {
        const m = models[key];
        if (!m || key !== current || m.getLanguageId() !== 'log') return;
        const lines = logStarts(m, from);
        if (lines.length) ed.trigger('wakil', 'editor.fold', { selectionLines: lines.map(function (l) { return l - 1; }), levels: 1 });
      }, 60);
    }
```

(`models`, `current` and `ed` are declared below the theme today; move this block after `const ed = monaco.editor.create(...)` and the `models` declaration so they are in scope.)

- [ ] **Step 3: Fold on first show.** In `wakilShowModel`, change the creation line to:

```js
      const created = !models[key];
      if (created) { models[key] = monaco.editor.createModel(text, language); indent(models[key]); }
```

and after `report();` add `if (created) foldEntries(key, 1);`.

- [ ] **Step 4: Append and follow**, after `wakilResetText`:

```js
    // 3b-vii: a growing log. Appended as its own undo step; the view follows only when the last line
    // was in view (Rule 6), and the new entries arrive folded (Rule 9: an opened fold stays open).
    window.wakilAppendText = function (key, text, serial) {
      const m = models[key]; if (!m) return;
      if (typingTimer !== null && key === current) { cancelAnimationFrame(typingTimer); typingTimer = null; }
      const shown = key === current;
      const vr = shown ? ed.getVisibleRanges() : [];
      const follow = shown && vr.length > 0 && vr[vr.length - 1].endLineNumber >= m.getLineCount() - 1;
      const from = m.getLineCount();
      const end = m.getFullModelRange().getEndPosition();
      applying = true;
      m.pushStackElement();
      m.pushEditOperations([], [{ range: new monaco.Range(end.lineNumber, end.column, end.lineNumber, end.column), text: text }],
                           function () { return null; });
      m.pushStackElement();
      applying = false;
      basis[key] = serial;
      if (shown) {
        foldEntries(key, from);
        if (follow) ed.revealLine(m.getLineCount());
        report();
      }
    };
```

- [ ] **Step 5: Build**

Run: `make app-build`
Expected: builds with no error.

- [ ] **Step 6: See it** (throwaway, not committed): `mkdir -p .scratch/3b-vii && printf '[2026-10-18 13:33:20] local.ERROR: boom {"exception":"x"}\n[stacktrace]\n#0 /var/www/a.php(1): f()\n#1 {main}\n"}\n[2026-10-18 13:33:21] local.WARNING: slow\n[2026-10-18 13:33:22] local.INFO: ok\n' > .scratch/3b-vii/laravel.log`, open it in the app (add `.scratch/3b-vii` as a root of a throwaway project, or ⌘P it if the current project holds it), and check: red `ERROR`, amber `WARNING`, the first entry folded, the view at the bottom; then `printf '[2026-10-18 13:34:00] local.ERROR: again\n#0 x\n' >> .scratch/3b-vii/laravel.log` and check it arrives folded with the view following.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilApp/monaco-host.html
git commit -m "3b-vii: Monaco colours and folds logs, and follows an appended log at the bottom"
```

---

### Task 6: The search line for skipped large files

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorSearch.swift:20-60` (state), `EditorActions.swift:1500-1511` (`matches(from:)`), `:1585-1587`, `:1649` (assign and clear), `EditorPaneKind.swift:72` (read_pane)
- Modify: `app/Sources/WakilApp/EditorColumn.swift:888-891` (the line)
- Modify: `app/Tests/WakilKitTests/EditorTestSupport.swift` (FakeFiles `searchSkippedLarge`)
- Test: `app/Tests/WakilKitTests/EditorSearchTests.swift`, `EditorSearchActionsTests.swift`

**Interfaces:**
- Consumes: Task 2's `skipped_large`.
- Produces: `EditorSearchState.skippedLarge: [String]`, `editorSkippedLargeNote(_ paths: [String]) -> String?`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theSkippedLargeNoteNamesUpToThreeFiles() {
    #expect(editorSkippedLargeNote([]) == nil)
    #expect(editorSkippedLargeNote(["storage/logs/laravel.log"]) == "1 file over 2 MB not searched: storage/logs/laravel.log")
    #expect(editorSkippedLargeNote(["a", "b", "c"]) == "3 files over 2 MB not searched: a, b, c")
    #expect(editorSkippedLargeNote(["a", "b", "c", "d", "e"]) == "5 files over 2 MB not searched: a, b, c, …and 2 more")
}
```

and in `EditorSearchActionsTests.swift`, following the file's existing search test (set `await f.files.searchSkippedLarge = ["storage/logs/laravel.log"]` — add a setter if the actor needs one), dispatch `editor_search` and `#expect(snapshot.search.skippedLarge == ["storage/logs/laravel.log"])`.

- [ ] **Step 2: Run to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter "SkippedLarge"`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement.** `EditorSearchState`: `public var skippedLarge: [String] = []` (a defaulted property, not an init parameter). In `EditorSearch.swift`:

```swift
/// The line under the results naming the files over 2 MB search skipped (3b-vii); nil when none.
public func editorSkippedLargeNote(_ paths: [String]) -> String? {
    guard !paths.isEmpty else { return nil }
    let head = paths.prefix(3).joined(separator: ", ")
    let more = paths.count > 3 ? ", …and \(paths.count - 3) more" : ""
    return "\(paths.count) file\(paths.count == 1 ? "" : "s") over 2 MB not searched: \(head)\(more)"
}
```

`matches(from:)` returns a fourth element `skippedLarge: [String]` decoded from `content["skipped_large"]` (strings of the array); line 1585 assigns it, 1587 and 1649 clear it to `[]`. `EditorPaneKind.swift:72` adds `"skipped_large": .array(q.skippedLarge.map { .string($0) })`. FakeFiles' `files_search` reply adds `"skipped_large": .array(searchSkippedLarge.map { .string($0) })`. `EditorColumn.swift`, after the `filesTruncated` line:

```swift
            if let note = editorSkippedLargeNote(search.skippedLarge) {
                searchLine(note, opacity: 0.55).accessibilityIdentifier("editor.search.largeNote")
            }
```

- [ ] **Step 4: Run to see them pass**, then the search suites

Run: `cd app && ../scripts/swift-test.sh --filter "EditorSearch"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources app/Tests
git commit -m "3b-vii: search says which files over 2 MB it did not search"
```

---

### Task 7: Charter, docs and the whole suite

**Files:**
- Modify: `docs/wakil/decisions.md` (Decision 37, after its last amendment)
- Modify: `docs/wakil/design-language.md` (§5 Colour, one sentence)
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift:484` area if it describes `files_search`'s skips (mention `skipped_large`)

- [ ] **Step 1: Decision 37 amendment**, appended to Decision 37's text:

```markdown
    **Amended 2026-10-18 (3b-vii design; the operator decided):** **3b-vi — scratch buffers sent to
    other panes — is parked.** The DB pane's query line already wraps, colours and formats SQL, so
    only sending a selection to a terminal pane had value, and not enough to build now. The later
    rows keep their numbers: large files and logs 3b-vii, AI ghost-text 3b-viii, LSP 3b-ix.
```

- [ ] **Step 2: design-language §5**, one sentence at the end of the Colour section's prose:

```markdown
In a log (3b-vii) red marks the error levels and amber the warnings — the same meanings — while
timestamps and stack traces are dimmed, so each entry's first line carries the eye.
```

- [ ] **Step 3: The whole suite**

Run: `make build && make app-test && go test ./...`
Expected: all pass. Any red named in the report; an intermittent one is rerun once and quarantined by name, never retried into green silently.

- [ ] **Step 4: Commit**

```bash
git add docs/wakil/decisions.md docs/wakil/design-language.md app/Sources/WakilKit/MCP/MCPServer.swift
git commit -m "3b-vii: Decision 37 parks 3b-vi; design-language names the log colours"
```
