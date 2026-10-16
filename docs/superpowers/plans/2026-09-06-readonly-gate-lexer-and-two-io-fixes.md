# Read-Only Gate Lexer + Two I/O Correctness Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the third read-only-gate bypass by replacing two sequential, context-free comment-stripping passes with one literal-aware left-to-right scan, and fix two smaller correctness defects found in the same review.

**Architecture:** `stripSQLComments` becomes a single pass that tracks quoted-span state, so a comment introducer inside a string, an identifier, or another comment can no longer open or close a span. Comment spans are replaced with a space exactly as today; quoted spans and `#` comment text are copied VERBATIM, which preserves the gate's existing over-rejecting behaviour byte for byte while removing the under-rejection. `AssertSQLReadOnly`'s passes 2 and 3 are untouched.

**Tech Stack:** Go 1.27, no new dependencies. Live verification against the `wakil-acc-mysql` (MySQL 8.4.11) and `wakil-acc-mongo` Docker containers, plus in-process `modernc.org/sqlite`.

**Spec:** the "Verified findings" section below. These are the three findings from a `/code-review high` pass over the full branch diff, each independently reproduced by the controller before this plan was written; finding 1 was reproduced end to end against a live server.

## Global Constraints

- `CGO_ENABLED=0` project-wide (`Makefile` exports it for build/test/vet; pinned by `scripts/makefile_test.go`).
- **Do NOT set `WAKIL_KEYCHAIN_TEST`.** No test may reach `wakilcore.SecretSet` or touch the real login keychain. `keychainService` is a pure function; the `security` CLI is faked on `PATH` in existing tests — follow that pattern.
- No test may read or write the real `~/.claude*` or `~/.wakil` directories. Build fixtures in `t.TempDir()`.
- **Comment accuracy is a hard failure.** Every claim written into a comment must have been run.
- **Probe, don't read.** Measure library and engine behaviour; do not infer it.
- **Mutation-test every fix**: break the production code, confirm the right test fails for the right reason and quote the message, revert, confirm the file is byte-identical against a `/tmp` backup and `git diff --exit-code` is clean. A mutation reporting `(cached)` has not run — force `-count=1`.
- A test that cannot fail is worse than no test. Assert the guard FIRED, not merely that the bad thing is absent.
- Never run `git checkout --` on a file with uncommitted changes. Never use `git stash` (shared stack). Do not push; the branch is already pushed and PR #1 is open.
- Gate before finishing each task: `gofmt -l .` empty, `go vet ./...`, `go test ./... -count=2`, `-race`, `-shuffle=on`, `make build`, and `make test-live` for Task 1.

---

## Verified findings

### Finding 1 (CRITICAL, merge blocker) — comment stripping is not literal-aware

`internal/wakilcore/readonly.go:123`. `stripSQLComments` runs `stripSQLBlockComments` and then the `sqlLineComment` regex. Neither knows about string literals or about the other's comment syntax, so a `/*` appearing inside a `--` line comment opens a block comment that swallows every line up to a later `*/` — **deleting live SQL before the `;` check, the leading-keyword check and the write-keyword scan ever run.**

Reproduced by the controller. `AssertSQLReadOnly` returned `nil` for every one of these:

```
"SELECT 1 -- /*\nINTO OUTFILE '/var/lib/mysql-files/x.txt'\n-- */"  -> stripped "SELECT 1  ", gate=nil
"SELECT 1 -- /*\nUNION SELECT 2\n-- */"                             -> stripped "SELECT 1  ", gate=nil
"SELECT 1 -- /*\nDELETE FROM customers\n-- */"                      -> stripped "SELECT 1  ", gate=nil
"SELECT '/*' ; DROP TABLE t -- */"                                  -> stripped "SELECT ' ",  gate=nil
```

Against the live `wakil-acc-mysql` container: the `UNION` form returned rows **1 and 2** (MySQL executed it), and the `INTO OUTFILE` form **wrote a 2-byte file on the database server** at `/var/lib/mysql-files/ctl_probe2.txt` (since deleted). No `;` is needed, so `MultiStatements=false` does not help.

This is the same file-write bypass `567fc08` closed for the `1--1` shape, reached through a different door. It is the third bypass found in this one function, which is why the fix is structural rather than another special case.

The doc comment on `AssertSQLReadOnly` currently claims literal-unawareness can only over-reject. The `SELECT '/*' ; DROP TABLE t -- */` case shows it under-rejects. That claim must be corrected, not softened.

### Finding 2 (LOW) — `SecretGet` strips every trailing newline

`internal/wakilcore/secrets.go:176` does `strings.TrimRight(out.String(), "\n")`. `security ... -w` appends exactly one newline of its own, and the write path (`readSecretValue`, `cmd/wakil/main.go:293`) deliberately strips at most one trailing newline and documents piping a second so a PEM key keeps its terminator. `TrimRight` undoes that: a stored value ending in `\n` silently loses it on read. The two doc comments contradict each other.

### Finding 3 (MEDIUM) — `WriteActive`'s temp file name is fixed

`internal/wakilcore/active.go:172` uses `tmp := path + ".tmp"`. Write-then-rename guards against a crash but not against a second writer. Now that the active context is per-org, two `wakil-ctx` processes **in the same org** — two Claude sessions, which this operator runs routinely — share that one path. `os.WriteFile` opens `O_TRUNC` and writes from offset 0, so a shorter write can leave a longer write's tail behind, and the mixed file is renamed into place; every subsequent `ReadActive` then fails `json.Unmarshal`.

---

## File Structure

| File | Responsibility after this plan |
|---|---|
| `internal/wakilcore/readonly.go` | `stripSQLComments` becomes the single literal-aware scanner plus three small helpers (`scanQuotedSpan`, `scanToLineEnd`, `startsLineComment`). `stripSQLBlockComments` is absorbed and deleted. `sqlLineComment` regex is deleted; its MySQL rule moves into `startsLineComment`. `AssertSQLReadOnly` and every keyword regex are unchanged. |
| `internal/wakilcore/readonly_test.go` | Gains the bypass corpus and the helper-level tests. Existing tests must all keep passing unchanged — that is the evidence the rewrite preserved behaviour. |
| `internal/wakilcore/secrets.go` | One-line change in `SecretGet` + corrected doc comment. |
| `internal/wakilcore/secrets_test.go` | Trailing-newline round-trip test against a fake `security`. |
| `internal/wakilcore/active.go` | `WriteActive` uses `os.CreateTemp` in the destination directory, with cleanup on every error path. |
| `internal/wakilcore/active_test.go` | Concurrency test + deterministic "not a fixed path" test. |

---

## Task 1: Literal-aware comment scanner

**Files:**
- Modify: `internal/wakilcore/readonly.go:8` (delete `sqlLineComment`), `:123-127` (`stripSQLComments`), `:145-171` (`stripSQLBlockComments`, absorbed), and `AssertSQLReadOnly`'s doc comment
- Test: `internal/wakilcore/readonly_test.go`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `stripSQLComments(s string) string` — unchanged signature, so `AssertSQLReadOnly` needs no edit. New unexported helpers `startsLineComment(s string, i int) bool`, `scanToLineEnd(s string, i int) int`, `scanQuotedSpan(s string, i int) int`, each returning a byte index.

### The design, and why each choice is the safe one

One left-to-right pass. At each byte, exactly one of these applies:

| Input at `i` | Action | Why |
|---|---|---|
| `'`, `"`, `` ` `` | copy the whole quoted span VERBATIM | The span's contents stay visible to the keyword scan, so `SELECT 'DELETE FROM t'` keeps being rejected exactly as today. Literal-awareness is used ONLY to decide where comments start — it must not become a permission to hide text. |
| `#` | copy to end of line VERBATIM | Same reason. `#` is stripped by nothing today, so `SELECT 1 # DELETE FROM t` is rejected; copying verbatim preserves that. Recognising `#` at all is nevertheless REQUIRED, because otherwise `SELECT 1 # /*\nDELETE FROM t\n# */` is the identical bypass in a new costume. |
| `--` followed by whitespace/control/EOF | replace whole span through end of line with ONE space | Existing `sqlLineComment` semantics, preserved exactly (see its doc comment for the measured MySQL rule and why newline is excluded from the introducer class). |
| `/*!` | copy through the closing `*/` VERBATIM | MySQL executable comment: content may be live. Existing behaviour. |
| `/*` (not `/*!`) with a closing `*/` | replace whole span with ONE space | Existing behaviour. |
| `/*` with no closing `*/` | copy the remainder VERBATIM and stop | Existing behaviour: never silently discard text of unknown intent. |
| anything else | copy the byte | |

**Replacement is a single space, never the empty string**, so stripping can never fuse two tokens and hide a keyword from the `\b`-anchored scan. This is already true today; keep it.

**Quoted spans deliberately do NOT honour backslash escapes.** MySQL treats `\'` as an escaped quote by default; SQLite and Postgres do not, and MySQL itself does not under `NO_BACKSLASH_ESCAPES`. Honouring the escape would extend the literal further, hiding MORE text from the scan. Ignoring it ends the literal EARLIER, leaving more text visible — over-rejection, the safe direction, and the same bias the rest of this file already takes. Doubling (`''`, `""`, ` `` `) IS honoured, because every target engine agrees on it.

### The design is already validated — these are the outputs to expect

The controller prototyped the exact `stripSQLComments` in Step 4 as a standalone program and ran it. This is what it produced. Your implementation must reproduce these outputs; a difference means you changed the design, not that the design was approximate.

```
in  "SELECT 1 -- /*\nINTO OUTFILE '/var/lib/mysql-files/x.txt'\n-- */"
out "SELECT 1  \nINTO OUTFILE '/var/lib/mysql-files/x.txt'\n "     <- INTO now visible

in  "SELECT 1 # /*\nDELETE FROM customers\n# */"
out "SELECT 1 # /*\nDELETE FROM customers\n# */"                    <- verbatim; DELETE visible

in  "SELECT '/*' ; DROP TABLE t -- */"
out "SELECT '/*' ; DROP TABLE t  "                                  <- ";" now visible

in  "SELECT '-- ' , x FROM t WHERE y = 1 ; DROP TABLE t"
out "SELECT '-- ' , x FROM t WHERE y = 1 ; DROP TABLE t"            <- literal inert

in  "SELECT 1 -- an ordinary comment"        out "SELECT 1  "
in  "SELECT * FROM customers /* a note */ WHERE id = 1"
                                             out "SELECT * FROM customers   WHERE id = 1"
in  "SELECT 1--1 INTO OUTFILE '/tmp/x'"      out unchanged   (567fc08 behaviour preserved)
in  "SELECT 1 /*!50000; DROP TABLE t*/"      out unchanged   (executable comment stays live)
in  "SELECT 1 /* /* */ DELETE FROM t */"     out "SELECT 1   DELETE FROM t */"  (no nesting)
in  "SELECT 1--\nDELETE FROM t"              out unchanged   (newline is not an introducer)
```

The last four are the regression cases: they are the behaviours the previous implementation got right, and they must not change.

### Steps

- [ ] **Step 1: Write the failing bypass corpus**

Add to `internal/wakilcore/readonly_test.go`:

```go
// TestAssertSQLReadOnly_CommentIntroducersAreNotContextFree pins the third
// bypass of this gate (see the plan's Finding 1). Each case hides live SQL
// from the gate by making one comment syntax open a span that another
// syntax, or a string literal, should have made inert.
//
// These are not hypotheticals. The controller ran the first two against the
// live MySQL 8.4.11 acceptance container: the UNION form returned rows 1 and
// 2, and the INTO OUTFILE form wrote a 2-byte file on the database server.
func TestAssertSQLReadOnly_CommentIntroducersAreNotContextFree(t *testing.T) {
	for _, tc := range []struct {
		name, query, wantMsg string
	}{
		{
			name:    "block comment opened inside a -- line comment hides INTO OUTFILE",
			query:   "SELECT 1 -- /*\nINTO OUTFILE '/var/lib/mysql-files/x.txt'\n-- */",
			wantMsg: "query contains a write operation",
		},
		{
			name:    "block comment opened inside a -- line comment hides DELETE",
			query:   "SELECT 1 -- /*\nDELETE FROM customers\n-- */",
			wantMsg: "query contains a write operation",
		},
		{
			name:    "block comment opened inside a # line comment hides DELETE",
			query:   "SELECT 1 # /*\nDELETE FROM customers\n# */",
			wantMsg: "query contains a write operation",
		},
		{
			name:    "block comment opened inside a string literal hides a second statement",
			query:   "SELECT '/*' ; DROP TABLE t -- */",
			wantMsg: "multiple statements are not allowed",
		},
		{
			name:    "line comment introducer inside a string literal does not start a comment",
			query:   "SELECT '-- ' , x FROM t WHERE y = 1 ; DROP TABLE t",
			wantMsg: "multiple statements are not allowed",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := AssertSQLReadOnly(tc.query)
			if err == nil {
				t.Fatalf("gate ALLOWED a query that hides live SQL: %q (stripped to %q)",
					tc.query, stripSQLComments(tc.query))
			}
			if !strings.Contains(err.Error(), tc.wantMsg) {
				t.Errorf("rejected for the wrong reason: got %q, want a message containing %q",
					err.Error(), tc.wantMsg)
			}
		})
	}
}
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `go test ./internal/wakilcore/ -run TestAssertSQLReadOnly_CommentIntroducersAreNotContextFree -v -count=1`

Expected: the first four subtests FAIL with `gate ALLOWED a query that hides live SQL`, each showing the stripped text collapsed to roughly `"SELECT 1  "`. Record the exact output in your report. If any subtest passes at this point, STOP and report — the premise of this task is wrong and the plan needs revising before any code changes.

- [ ] **Step 3: Write the helpers**

Replace `sqlLineComment` (`readonly.go:8` region) and `stripSQLBlockComments` with:

```go
// startsLineComment reports whether a "--" line comment begins at i.
//
// MySQL requires the second dash to be followed by whitespace or a control
// character, or by end of input; "--" followed by anything else is a binary
// minus applied to a unary minus. Measured against the live MySQL 8 used for
// acceptance:
//
//	SELECT 1--1 AS a      -> 2    (1 - (-1); NOT a comment)
//	SELECT 1 -- a comment -> 1    (comment)
//	SELECT 5--<TAB>6      -> 5    (comment)
//	SELECT 1--<EOF>       -> 1    (comment)
//
// Newline is excluded from the introducer class on purpose: for MySQL a
// "--" comment opens and closes on its own line, so treating "--\n" as an
// introducer would let the span run on and swallow the NEXT line, which is
// live SQL. That is precisely the bug this file has now been fixed for
// three times; do not "simplify" the class by adding \n to it.
//
// DEL (0x7f) is also excluded even though MySQL accepts it, because
// omitting it can only cost a false rejection of a query nobody writes.
func startsLineComment(s string, i int) bool {
	if i+1 >= len(s) || s[i] != '-' || s[i+1] != '-' {
		return false
	}
	if i+2 == len(s) {
		return true
	}
	c := s[i+2]
	return c <= 0x20 && c != '\n'
}

// scanToLineEnd returns the index of the newline that ends the line
// containing i, or len(s) if there is none. The newline itself is NOT
// consumed, so the caller copies it and the text keeps its line structure.
func scanToLineEnd(s string, i int) int {
	if n := strings.IndexByte(s[i:], '\n'); n >= 0 {
		return i + n
	}
	return len(s)
}

// scanQuotedSpan returns the index just past the quoted span that starts at
// i, where s[i] is one of ' " or `. An unterminated span runs to end of
// input.
//
// Doubling ('' inside '...') closes and reopens, which every engine Wakil
// targets agrees on. Backslash escapes are deliberately NOT honoured: MySQL
// treats \' as an escaped quote by default, SQLite and Postgres do not, and
// neither does MySQL under NO_BACKSLASH_ESCAPES. Honouring it would extend
// the literal and hide MORE text from the keyword scan; ignoring it ends the
// literal earlier and leaves more text visible. Over-rejection is the safe
// direction, and it is the bias this whole file takes.
func scanQuotedSpan(s string, i int) int {
	q := s[i]
	for j := i + 1; j < len(s); j++ {
		if s[j] != q {
			continue
		}
		if j+1 < len(s) && s[j+1] == q {
			j++ // doubled quote: consume both, stay inside
			continue
		}
		return j + 1
	}
	return len(s)
}
```

- [ ] **Step 4: Rewrite `stripSQLComments` as the single pass**

```go
// stripSQLComments removes dead comment spans in ONE left-to-right pass
// that tracks quoted-span state.
//
// WHY ONE PASS. This used to be two independent passes — block comments,
// then line comments — and neither knew about string literals or about the
// other's syntax. That made a comment introducer context-free, so a "/*"
// written inside a "--" comment opened a block comment that swallowed every
// line up to a later "*/", DELETING LIVE SQL before any check in
// AssertSQLReadOnly ran. Reproduced end to end against the live MySQL 8.4.11
// acceptance container:
//
//	SELECT 1 -- /*
//	UNION SELECT 2
//	-- */                 -> gate allowed it; MySQL returned rows 1 AND 2
//
//	SELECT 1 -- /*
//	INTO OUTFILE '/var/lib/mysql-files/x.txt'
//	-- */                 -> gate allowed it; a file appeared on the server
//
// No ";" is involved, so MultiStatements=false does not help. This was the
// THIRD bypass found in this function (after "SELECT 1--1 INTO OUTFILE",
// fixed in 567fc08), which is why the fix is structural: any scheme where
// one syntax can open a span inside another has the same shape of hole.
//
// WHAT IS AND IS NOT REMOVED. Only spans that are dead in every engine
// Wakil targets are replaced, and always with a single space so two tokens
// can never fuse and hide a keyword from the \b-anchored scan:
//
//   - "-- ..." to end of line          -> replaced (see startsLineComment)
//   - "/* ... */" without "!"          -> replaced
//
// Everything else is copied VERBATIM, including three things that might
// look like candidates for removal and are not:
//
//   - QUOTED SPANS ('...', "...", `...`). Their contents stay visible to
//     the keyword scan, so "SELECT 'DELETE FROM t'" keeps being rejected
//     exactly as before this rewrite. Literal-awareness here is only about
//     deciding where a comment STARTS; it must never become a licence to
//     hide text from the checks.
//   - "# ..." to end of line. Nothing stripped it before and nothing does
//     now, so "SELECT 1 # DELETE FROM t" is still rejected. It must still
//     be RECOGNISED, though, or "SELECT 1 # /*\nDELETE FROM t\n# */" is the
//     identical bypass in a new costume.
//   - "/*! ... */", MySQL's executable comment, whose contents MySQL parses
//     as live SQL — see the long note on AssertSQLReadOnly.
//
// An unterminated "/*" leaves the remainder untouched rather than silently
// discarding text of unknown intent.
func stripSQLComments(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		switch c := s[i]; {
		case c == '\'' || c == '"' || c == '`':
			end := scanQuotedSpan(s, i)
			b.WriteString(s[i:end])
			i = end
		case c == '#':
			end := scanToLineEnd(s, i)
			b.WriteString(s[i:end])
			i = end
		case startsLineComment(s, i):
			b.WriteByte(' ')
			i = scanToLineEnd(s, i)
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			rel := strings.Index(s[i+2:], "*/")
			if rel == -1 {
				b.WriteString(s[i:])
				i = len(s)
				break
			}
			end := i + 2 + rel + 2
			if i+2 < len(s) && s[i+2] == '!' {
				b.WriteString(s[i:end])
			} else {
				b.WriteByte(' ')
			}
			i = end
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String()
}
```

Delete `stripSQLBlockComments` and the `sqlLineComment` var. Remove the `regexp` import only if nothing else in the file needs it — the keyword regexes do, so it stays.

- [ ] **Step 5: Correct the two doc comments that are now false**

In `AssertSQLReadOnly`'s doc comment, pass 1's description says the passes are sequential and that literal-unawareness can only over-reject. Replace that with the single-pass description, and state the measured counter-example plainly: `SELECT '/*' ; DROP TABLE t -- */` was ALLOWED before this change, i.e. it under-rejected. Do not soften the correction — this file has twice had a comment that claimed more than it delivered.

- [ ] **Step 6: Run the new test and the whole existing suite**

Run: `go test ./internal/wakilcore/ -count=1`

Expected: PASS, including every pre-existing `readonly_test.go` test unchanged. **If any pre-existing test now fails, that is the signal that the rewrite changed behaviour somewhere it should not have — investigate before adjusting the test.** Adjusting a passing safety test to accommodate a rewrite is how a gate quietly loosens.

- [ ] **Step 7: Add helper-level tests**

```go
// TestScanQuotedSpan pins the span boundaries the scanner depends on,
// including the deliberate decision NOT to honour backslash escapes.
func TestScanQuotedSpan(t *testing.T) {
	for _, tc := range []struct {
		name, in string
		want     int
	}{
		{"simple", `'abc' rest`, 5},
		{"doubled quote stays inside", `'a''b' rest`, 6},
		{"unterminated runs to end", `'abc`, 4},
		{"backslash does NOT escape", `'a\' , x`, 4},
		{"double quotes", `"ab" x`, 4},
		{"backtick identifier", "`ab` x", 4},
		{"empty span", `'' x`, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := scanQuotedSpan(tc.in, 0); got != tc.want {
				t.Errorf("scanQuotedSpan(%q, 0) = %d, want %d (span %q)",
					tc.in, got, tc.want, tc.in[:min(got, len(tc.in))])
			}
		})
	}
}

// TestStartsLineComment pins the MySQL introducer rule, especially the two
// exclusions that are load-bearing: newline (whose inclusion would recreate
// the swallow-the-next-line bug) and the non-comment "--1".
func TestStartsLineComment(t *testing.T) {
	for _, tc := range []struct {
		in   string
		i    int
		want bool
	}{
		{"-- x", 0, true},
		{"--\tx", 0, true},
		{"--", 0, true},
		{"--1", 0, false},
		{"--\nDELETE FROM t", 0, false},
		{"-x", 0, false},
		{"SELECT 1 -- c", 9, true},
	} {
		if got := startsLineComment(tc.in, tc.i); got != tc.want {
			t.Errorf("startsLineComment(%q, %d) = %v, want %v", tc.in, tc.i, got, tc.want)
		}
	}
}
```

- [ ] **Step 8: Mutation-test each guard**

Back up first: `cp internal/wakilcore/readonly.go /tmp/mutbak-readonly.go`

Run each mutation with `-count=1`, record the exact failure message, then restore from the backup and confirm `diff` is silent and `git diff --exit-code` is clean.

1. Delete the `case c == '\'' || ...` quoted-span arm. Expect the literal-based subtests to fail.
2. Delete the `case c == '#'` arm. Expect the `#` bypass subtest to fail.
3. In `startsLineComment`, drop `&& c != '\n'`. Expect a failure showing the next line was swallowed.
4. In `startsLineComment`, change `c <= 0x20` to `true`. Expect the pre-existing `1--1 INTO OUTFILE` test from `567fc08` to fail — confirming the earlier fix is still load-bearing.
5. In `scanQuotedSpan`, honour backslash escapes (`if s[j] == '\\' { j++; continue }`). Expect `TestScanQuotedSpan`'s "backslash does NOT escape" case to fail.
6. Change the `/*!` check to strip executable comments. Expect the pre-existing `/*! */` tests to fail.

Any mutation that SURVIVES is a finding: report it rather than inventing a test to paper over it, and say whether you believe it is unkilled or genuinely equivalent.

- [ ] **Step 9: Re-prove the bypass is closed against real engines**

MySQL (container `wakil-acc-mysql`, `root:rootpw@tcp(127.0.0.1:13306)/wakilacc`). If it is not running, `docker start wakil-acc-mysql` and wait for `mysqladmin ping`.

Confirm the engine still executes the hidden SQL — the gate is the only thing that stops it:

```bash
printf "SELECT 1 -- /*\nUNION SELECT 2\n-- */;\n" \
  | docker exec -i wakil-acc-mysql mysql -uroot -prootpw wakilacc
```

Expected: rows `1` and `2`. That is the point — the engine has not changed and must not be relied on.

Then confirm the gate now refuses it, and that a file is NOT written, by driving the real `conn.Read` path with `WAKIL_MYSQL_DSN` set (see the existing gated tests for the pattern). Use a probe filename of your own choosing under `/var/lib/mysql-files/`, then `docker exec wakil-acc-mysql ls -l /var/lib/mysql-files/` and assert it is absent. Delete anything you do create.

SQLite: build a temp database, run `SELECT 1 -- /*\n; ATTACH DATABASE '<tmp>/side.db' AS s\n-- */` through the gate and, if the gate were to allow it, through `sqliteDriver.Connect` + `Conn.Read`. Assert the gate rejects it AND that `side.db` does not exist on disk afterwards. The pre-fix behaviour was that the file really was created.

Also confirm the fix did not over-reject into uselessness: `SELECT 1 -- an ordinary comment`, `SELECT * FROM customers /* a note */ WHERE id = 1`, and `SELECT 1--1 AS arith` must all still behave exactly as they did before this task (the first two allowed, the third rejected).

- [ ] **Step 10: Full gate, then commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build && make test-live
git add internal/wakilcore/readonly.go internal/wakilcore/readonly_test.go
git commit -m "fix(wakil): make comment stripping literal-aware in one pass"
```

---

## Task 2: `SecretGet` must strip exactly one trailing newline

**Files:**
- Modify: `internal/wakilcore/secrets.go:176`
- Test: `internal/wakilcore/secrets_test.go`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: no signature change.

- [ ] **Step 1: Write the failing test**

Use the existing fake-`security`-on-`PATH` pattern already in this file. The fake must print the stored value followed by the one newline the real `security -w` adds.

```go
// TestSecretGetStripsExactlyOneTrailingNewline pins the read half of a
// contract the write half already documents: readSecretValue strips at most
// ONE trailing newline, and cmd/wakil's help tells an operator to pipe a
// second newline when the secret itself must end in one (a PEM key is the
// motivating case). `security ... -w` then adds exactly one newline of its
// own when printing. TrimRight(…, "\n") removed BOTH, silently truncating
// the value, and made the two doc comments contradict each other.
func TestSecretGetStripsExactlyOneTrailingNewline(t *testing.T) {
	for _, tc := range []struct{ name, stored, want string }{
		{"ordinary secret", "hunter2", "hunter2"},
		{"secret that ends in a newline", "-----END KEY-----\n", "-----END KEY-----\n"},
		{"secret that ends in two newlines", "a\n\n", "a\n\n"},
		{"secret with interior newlines", "line1\nline2", "line1\nline2"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("CLAUDE_CONFIG_DIR", "/x/.claude-testorg")
			// fakeSecurity emits its stdout with printf '%s' — exactly the
			// bytes given, no newline of its own — so the "\n" appended here
			// is standing in for the one the real `security -w` adds.
			fakeSecurity(t, 0, tc.stored+"\n")

			got, err := SecretGet("db:staging")
			if err != nil {
				t.Fatalf("SecretGet: %v", err)
			}
			if got != tc.want {
				t.Errorf("SecretGet returned %q, want %q — the value stored was %q",
					got, tc.want, tc.stored)
			}
		})
	}
}
```

`fakeSecurity(t *testing.T, exitCode int, stdout string) (argsFile string)` already exists at `internal/wakilcore/secrets_test.go:161` — reuse it, do not write a second one. It writes a `security` shell script into a temp dir, puts ONLY that dir on `PATH`, and emits `stdout` verbatim via `printf '%s'`.

- [ ] **Step 2: Run it and confirm it fails**

Run: `go test ./internal/wakilcore/ -run TestSecretGetStripsExactlyOneTrailingNewline -v -count=1`

Expected: the newline-terminated cases FAIL, e.g. `SecretGet returned "-----END KEY-----", want "-----END KEY-----\n"`.

- [ ] **Step 3: Fix and correct the comment**

```go
	// Exactly ONE newline is removed, not all of them: `security -w` adds a
	// single newline of its own when printing, and readSecretValue on the
	// write side already strips at most one, so a secret whose own last byte
	// is a newline (a PEM key, per cmd/wakil's help text) must survive the
	// round trip. TrimRight would remove the value's own terminator too.
	return strings.TrimSuffix(out.String(), "\n"), nil
```

- [ ] **Step 4: Run, then mutate**

Run: `go test ./internal/wakilcore/ -count=1` — expect PASS.

Mutation: change `TrimSuffix` back to `TrimRight`; expect the newline cases to fail with the message above. Restore, confirm byte-identical.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/secrets.go internal/wakilcore/secrets_test.go
git commit -m "fix(wakil): keep a secret's own trailing newline on read"
```

---

## Task 3: `WriteActive` must not use a fixed temp path

**Files:**
- Modify: `internal/wakilcore/active.go:165-177`
- Test: `internal/wakilcore/active_test.go`

**Interfaces:**
- Consumes: nothing from Tasks 1-2.
- Produces: no signature change.

- [ ] **Step 1: Measure the pre-fix failure, then write the tests**

First measure — do not assume the race reproduces. Write a throwaway loop in `/tmp` (or a temporarily-added test) that runs N concurrent `WriteActive` calls with values of very different lengths and counts how many times the file afterwards fails to parse. **Report the observed rate.** If it is very low, raise the concurrency or the length difference until it is reliable; a test that catches this one run in fifty is not a test. (Precedent on this branch: a DSN-injection test caught its defect 1 run in 8 until it was measured and rewritten.)

Then write both tests:

```go
// TestWriteActiveIsAtomicUnderConcurrentWriters pins the property the
// write-then-rename dance is FOR. A fixed temp path ("<path>.tmp") only
// guards against a crash: two processes in the SAME org — two Claude
// sessions, which is ordinary use — both open that one path with O_TRUNC
// and write from offset 0, so a short write can leave a long write's tail
// behind and the mixed file is renamed into place. Every later ReadActive
// then fails json.Unmarshal, and the operator sees a corrupt active
// context with no way to tell what happened.
func TestWriteActiveIsAtomicUnderConcurrentWriters(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(t.TempDir(), ".claude-testorg"))

	// Deliberately very different lengths: a torn write is only observable
	// when one payload is long enough to leave a tail behind the other.
	short := ActiveContext{Project: "/a", Environment: "s"}
	long := ActiveContext{
		Project:     "/" + strings.Repeat("long-project-path-segment/", 40),
		Environment: strings.Repeat("e", 200),
	}

	const iterations = 200
	var wg sync.WaitGroup
	for i := 0; i < iterations; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); _ = WriteActive(short) }()
		go func() { defer wg.Done(); _ = WriteActive(long) }()
	}
	wg.Wait()

	got, err := ReadActive()
	if err != nil {
		t.Fatalf("after %d concurrent write pairs the active context is unreadable: %v", iterations, err)
	}
	if got.Project != short.Project && got.Project != long.Project {
		t.Fatalf("active context is a mixture of both writers: %+v", got)
	}
}

// TestWriteActiveDoesNotReuseAFixedTempPath is the deterministic companion
// to the race above: a race test can only ever fail PROBABILISTICALLY, so
// something must pin the actual mechanism. Occupying the old fixed path
// with a directory makes the fixed-path implementation fail outright while
// a per-call temp file is unaffected.
func TestWriteActiveDoesNotReuseAFixedTempPath(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(t.TempDir(), ".claude-testorg"))

	if err := WriteActive(ActiveContext{Project: "/a"}); err != nil {
		t.Fatalf("seed write: %v", err)
	}
	path, err := activePath()
	if err != nil {
		t.Fatalf("activePath: %v", err)
	}
	if err := os.Mkdir(path+".tmp", 0o755); err != nil {
		t.Fatalf("occupying the old fixed temp path: %v", err)
	}

	if err := WriteActive(ActiveContext{Project: "/b"}); err != nil {
		t.Fatalf("WriteActive still depends on the fixed temp path %q: %v", path+".tmp", err)
	}
	got, err := ReadActive()
	if err != nil || got.Project != "/b" {
		t.Fatalf("ReadActive = (%+v, %v), want project /b", got, err)
	}
}
```

- [ ] **Step 2: Run and confirm both fail**

Run: `go test ./internal/wakilcore/ -run TestWriteActive -v -count=1`

Expected: the deterministic test fails with `WriteActive still depends on the fixed temp path`. The race test should fail at the rate you measured in Step 1 — run it with `-count=5` and report how many runs failed.

- [ ] **Step 3: Implement**

```go
	// A per-call temp file, not "<path>.tmp". The rename is what makes the
	// replacement atomic for READERS, but a fixed temp name is not atomic
	// for WRITERS: two processes in the same org share that one path, both
	// open it O_TRUNC, and the shorter write can leave the longer one's tail
	// behind before its rename publishes the mixture. os.CreateTemp gives
	// each writer its own file, so the only shared operation left is the
	// rename, which the kernel makes atomic. It is created in the
	// DESTINATION directory on purpose: a rename across filesystems fails.
	f, err := os.CreateTemp(wakilDir, "active-*.json.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	// Any failure from here on must not leave a stray temp file behind.
	defer func() { _ = os.Remove(tmp) }()
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
```

Note `os.CreateTemp` creates with mode 0600; the explicit `Chmod` preserves the 0644 the previous implementation wrote. The deferred `Remove` is harmless after a successful rename — the path no longer exists — and is what stops a failed write leaving litter in `~/.wakil`.

- [ ] **Step 4: Run, then mutate**

Run: `go test ./internal/wakilcore/ -count=2 -race` — expect PASS.

Mutations, each reverted byte-identical afterwards:
1. Restore `tmp := path + ".tmp"` with `os.WriteFile`. Expect the deterministic test to fail; report how many of 5 runs the race test also caught.
2. Drop the `os.Chmod`. Expect a permissions assertion to fail — if no existing test covers the 0644 mode, add one, because otherwise this mutation survives.
3. Drop the deferred `Remove` and force an error after creation. Confirm whether anything notices; if nothing does, say so rather than claiming coverage.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/active.go internal/wakilcore/active_test.go
git commit -m "fix(wakil): give each WriteActive its own temp file"
```

---

## Final: whole-branch verification

- [ ] `gofmt -l .` (empty), `go vet ./...`, `go test ./... -count=2`, `go test ./... -race`, `go test ./... -shuffle=on`, `make build`, `make test-live`
- [ ] Confirm `git status --short` is empty and no probe files remain on the MySQL container: `docker exec wakil-acc-mysql ls -l /var/lib/mysql-files/`
- [ ] Push to update PR #1: `git push`
