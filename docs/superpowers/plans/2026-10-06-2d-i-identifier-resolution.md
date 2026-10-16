# 2d-i Identifier Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A typed turn that names an identifier loosely ("transaction read only") reaches the agent with a hint naming the real identifier (`transaction_read_only`), shown in the thread as one `RESOLVED` row; ⌘P/⌘K find items by their spoken shape.

**Architecture:** A pure fold matcher (`IdentifierResolver`) runs over a `Vocabulary` built from four `IdentifierSource`s (Wakil, panes, schema, code), owned by a `VocabularyStore` actor. `WindowModel.send` appends the rendered note to the turn, appends a `RESOLVED` thought row, and journals the note. Schema names come from a new read-only `wakil-db` tool, `list_columns`.

**Tech Stack:** Swift 6 / SwiftUI, swift-testing (`@Test`, `#expect`, `#require`) in `app/Tests/WakilKitTests`; Go with `modelcontextprotocol/go-sdk` in `cmd/wakil-db` and `internal/wakilcore`.

**Spec:** `docs/superpowers/specs/2026-10-06-2d-i-identifier-resolution-design.md` — read it before any task.

## Global Constraints

- **Fold** = lowercase, then keep only `a-z`, `0-9` and `.`. This is the measured rule (`scripts/probe/stt-set2/score2.py`'s `fold`); it drops spaces, hyphens, underscores, apostrophes and every other separator, and keeps dots so `paths.go` keeps its extension.
- Before folding a run of words, strip leading and trailing punctuation from each word, keeping internal dots (`store.swift.` → `store.swift`).
- Runs of **1 to 6 words**, longest first, non-overlapping.
- **Nothing to resolve:** a run equal to a name ignoring case (after the punctuation strip) produces no resolution.
- At most **3 candidates** per phrase, then "and N more". Ranking: source order **panes, schema, wakil, code**, then shorter origin, then text alphabetically.
- At most **8 resolutions** per turn; more → **no note at all**.
- Note header, verbatim: `[Wakil: identifiers in scope that match words in this turn — a hint, not a correction]`
- Code source cap: **20,000 names per root**, most frequent first. Skip directories `vendor/`, `node_modules/`, `.build/`, `build/`, `dist/`, `generated/`, `Generated/`.
- Code cache directory: `~/.wakil/vocabulary/`.
- **No near matching. No abbreviation expansion. The operator's text is never changed.**
- An org switch drops the whole vocabulary before anything else (Invariant 4).
- A failing source contributes nothing and is journalled whole; nothing shows on screen (Interaction Rule 8).
- `list_columns` uses the read connection (`openPicked`), never the write credential (Invariant 6 untouched).
- Commits: no `Co-Authored-By` trailer, no "Generated with" line (operator rule).
- Swift tests: `cd app && swift test --filter <Name>`. Go tests: `go test ./cmd/wakil-db/ ./internal/wakilcore/ -run <Name>`. The controller runs `make test` and `make app-test` at the end; subagents run only filtered tests.

## Review Focus

1. **A pasted log or long code block in a turn** — expect no note at all, not a huge one (the 8-resolution cap). Pinned in Task 3.
2. **An org switch while the code scan of the old project is still running** — expect the late result to be discarded, never merged into the new org's vocabulary. Pinned in Task 7.
3. **A project root that is not a git repository, or a root with 100k files** — expect no code names from that root (journalled), and no hang of the send path. Pinned in Task 6.
4. **A database that is unreachable at context change** — expect the schema source to contribute nothing, other sources still resolving. Pinned in Task 5.
5. **A turn sent before the first vocabulary build has finished** — expect the turn to go out at once, with whatever vocabulary is ready (possibly none). Pinned in Task 7.

---

## File Structure

| File | Responsibility |
|---|---|
| `internal/wakilcore/dbdriver.go` (modify) | `TableColumns`, `ColumnList` types; `ListColumns` on `Conn` |
| `internal/wakilcore/sqlconn.go` (modify) | `sqlConn.ListColumns` from `columnsSQL` |
| `internal/wakilcore/driver_mysql.go`, `driver_sqlite.go` (modify) | each driver's `columnsSQL` |
| `internal/wakilcore/driver_mongo.go` (modify) | collections with empty column lists |
| `internal/wakilcore/dbresolve_test.go`, `cmd/wakil/main_test.go` (modify) | fakes gain `ListColumns` |
| `cmd/wakil-db/main.go` (modify) | registers `list_columns` |
| `app/Sources/WakilKit/Identifiers/Identifier.swift` (create) | `Identifier`, `IdentifierKind`, `IdentifierSourceKind`, `fold`, `Vocabulary` |
| `app/Sources/WakilKit/Identifiers/IdentifierResolver.swift` (create) | the pure fold matcher |
| `app/Sources/WakilKit/Identifiers/TurnNote.swift` (create) | note text, `RESOLVED` row text, splitting a rebuilt turn |
| `app/Sources/WakilKit/Identifiers/IdentifierSources.swift` (create) | the protocol, Wakil and Panes sources |
| `app/Sources/WakilKit/Identifiers/SchemaSource.swift` (create) | `list_databases` + `list_columns` through a `ToolCaller` |
| `app/Sources/WakilKit/Identifiers/CodeSource.swift` (create) | `git ls-files` scan, cap, `HEAD` cache |
| `app/Sources/WakilKit/Identifiers/VocabularyStore.swift` (create) | owns sources, rebuilds, org drop, failure reporting |
| `app/Sources/WakilKit/Command/PaletteItem.swift` (modify) | fold-prefix ranking in `rank` |
| `app/Sources/WakilKit/Registry/ActionRegistry.swift` (modify) | `journalIdentifierEvent` |
| `app/Sources/WakilKit/App/WindowModel.swift` (modify) | send path, `RESOLVED` row, rebuilt thread, context hooks |
| `app/Sources/WakilKit/App/AppWiring.swift`, `app/Sources/WakilApp/WindowSession.swift` (modify) | build and pass the store |
| `scripts/probe/stt-set2/vocab-snapshot-2026-10-06.txt` (create) | frozen vocabulary for the corpus test |
| `app/Tests/WakilKitTests/Identifier*Tests.swift`, `VocabularyStoreTests.swift`, `CodeSourceTests.swift`, `SchemaSourceTests.swift` (create) | tests |

---

### Task 1: `wakil-db` `list_columns`

**Files:**
- Modify: `internal/wakilcore/dbdriver.go` (types near `Container`, line ~46; `Conn` interface, line ~269)
- Modify: `internal/wakilcore/sqlconn.go` (struct line ~39; add method after `ListContainers`, line ~97)
- Modify: `internal/wakilcore/driver_mysql.go:73` and `:289`, `internal/wakilcore/driver_sqlite.go:36` and `:155` (add `columnsSQL` beside `listSQL`)
- Modify: `internal/wakilcore/driver_mongo.go` (add method after `ListContainers`, line ~80)
- Modify: `internal/wakilcore/dbresolve_test.go:143`, `cmd/wakil/main_test.go` (any `Conn` fake: add `ListColumns`)
- Modify: `cmd/wakil-db/main.go` (register after `describe_table`, line ~203; update the `newServer` doc comment's tool count and list)
- Test: `internal/wakilcore/driver_sqlite_test.go`, `cmd/wakil-db/main_test.go`, `cmd/wakil-db/schema_test.go`

**Interfaces:**
- Produces: MCP tool `list_columns`, args `{"database"?: string}`, structured output `{"tables": [{"table": string, "columns": [string]}]}`. Swift (Task 5) relies on exactly these keys.

- [ ] **Step 1: Write the failing driver test** in `internal/wakilcore/driver_sqlite_test.go`:

```go
func TestSQLiteListColumns(t *testing.T) {
	path := seedSQLite(t) // customers(id, name)
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE edit_quote (id INTEGER PRIMARY KEY, transaction_read_only TEXT)`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: path})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	got, err := conn.ListColumns(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := []TableColumns{
		{Table: "customers", Columns: []string{"id", "name"}},
		{Table: "edit_quote", Columns: []string{"id", "transaction_read_only"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ListColumns = %#v, want %#v", got, want)
	}
}
```
Add `"reflect"` to the imports if absent.

- [ ] **Step 2: Run it and see it fail**

Run: `go test ./internal/wakilcore/ -run TestSQLiteListColumns`
Expected: FAIL to compile — `conn.ListColumns undefined`, `undefined: TableColumns`.

- [ ] **Step 3: Implement.** In `dbdriver.go`, beside `Container`:

```go
// TableColumns is one table's column names, in declaration order. Mongo
// fills Columns with nothing: a collection has no fixed fields to list.
type TableColumns struct {
	Table   string   `json:"table"`
	Columns []string `json:"columns"`
}

// ColumnList wraps a []TableColumns so wakil-db's list_columns tool can
// return an object, as schema_test.go requires of every tool.
type ColumnList struct {
	Tables []TableColumns `json:"tables"`
}

// NewColumnList never returns a nil slice, so an empty schema is
// "tables": [] on the wire, not null.
func NewColumnList(t []TableColumns) ColumnList {
	if t == nil {
		t = []TableColumns{}
	}
	return ColumnList{Tables: t}
}
```

Add to the `Conn` interface, after `Describe`:

```go
	// ListColumns returns every table's column names in one read, for
	// 2d-i's identifier vocabulary. Read-only.
	ListColumns(ctx context.Context) ([]TableColumns, error)
```

In `sqlconn.go`, add a field `columnsSQL string` under `listSQL`, and:

```go
// ListColumns runs the driver's columnsSQL, which yields (table, column)
// rows ordered by table then column position, and groups them.
func (c *sqlConn) ListColumns(ctx context.Context) ([]TableColumns, error) {
	rows, err := c.db.QueryContext(ctx, c.columnsSQL)
	if err != nil {
		return nil, UserError("cannot list columns: " + err.Error())
	}
	defer rows.Close()
	var out []TableColumns
	for rows.Next() {
		var table, column string
		if err := rows.Scan(&table, &column); err != nil {
			return nil, err
		}
		if n := len(out); n == 0 || out[n-1].Table != table {
			out = append(out, TableColumns{Table: table})
		}
		out[len(out)-1].Columns = append(out[len(out)-1].Columns, column)
	}
	return out, rows.Err()
}
```

In both `driver_mysql.go` constructions (`:73`, `:289`), beside `listSQL: "SHOW TABLES",`:

```go
		columnsSQL: "SELECT table_name, column_name FROM information_schema.columns " +
			"WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position",
```

In both `driver_sqlite.go` constructions (`:36`, `:155`), beside `listSQL`:

```go
		columnsSQL: "SELECT m.name, p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p " +
			"WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' ORDER BY m.name, p.cid",
```

In `driver_mongo.go`:

```go
// ListColumns lists collections only: Mongo has no fixed fields, and
// sampling documents for them (Describe's inference) per collection is
// a cost 2d-i's vocabulary does not need.
func (m *mongoConn) ListColumns(ctx context.Context) ([]TableColumns, error) {
	containers, err := m.ListContainers(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]TableColumns, 0, len(containers))
	for _, c := range containers {
		out = append(out, TableColumns{Table: c.Name, Columns: []string{}})
	}
	return out, nil
}
```

Every other `Conn` implementation (`fakeTestConn` in `dbresolve_test.go:143`, and the fake in `cmd/wakil/main_test.go` — find it with `grep -n "ListContainers" cmd/wakil/main_test.go`) gains:

```go
func (fakeTestConn) ListColumns(ctx context.Context) ([]TableColumns, error) { return nil, nil }
```
(use the fake's own receiver type and package qualifier).

- [ ] **Step 4: Run it and see it pass**

Run: `go test ./internal/wakilcore/ -run TestSQLiteListColumns`
Expected: PASS.

- [ ] **Step 5: Write the failing tool tests** in `cmd/wakil-db/main_test.go`:

```go
func TestListColumnsReturnsEveryTablesColumns(t *testing.T) {
	setupSQLiteEventsProject(t) // events(id, kind)
	cs := connectedClient(t)
	result := callTool(t, cs, "list_columns", map[string]any{})
	tables, ok := result["tables"].([]any)
	if !ok || len(tables) != 1 {
		t.Fatalf("tables = %#v, want one table", result["tables"])
	}
	first := tables[0].(map[string]any)
	if first["table"] != "events" {
		t.Fatalf("table = %v, want events", first["table"])
	}
	if !reflect.DeepEqual(first["columns"], []any{"id", "kind"}) {
		t.Fatalf("columns = %v, want [id kind]", first["columns"])
	}
}
```

Add `"list_columns"` to the `want` slice at `main_test.go:423` and to the tool list in `schema_test.go`'s `AssertObjectOutputSchemas` call. Add `{"list_columns", map[string]any{}}` to the `cases` of `TestToolHandlersNoActiveProject` (and to the second case list near line 310 if it enumerates every picked-database tool).

- [ ] **Step 6: Run and see them fail**

Run: `go test ./cmd/wakil-db/ -run 'TestListColumns|TestToolHandlersNoActiveProject|Schema|Tools'`
Expected: FAIL — unknown tool `list_columns`.

- [ ] **Step 7: Register the tool** in `cmd/wakil-db/main.go`, after `describe_table`:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "list_columns", Description: "List every table's column names in the selected database, in one read, under a tables key: [{table, columns}]. For a Mongo database, collections only, each with an empty columns list, because a collection has no fixed fields. Read-only: it uses the read connection, never the write credential. Use describe_table instead when you need a column's type or whether it is part of the key."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a dbArg) (*mcp.CallToolResult, wakilcore.ColumnList, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.NewColumnList(nil), nil
			}
			defer conn.Close()
			out, err := conn.ListColumns(ctx)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.NewColumnList(nil), nil
			}
			return nil, wakilcore.NewColumnList(out), nil
		})
```

Update `newServer`'s doc comment: "all nine tools", add `list_columns` to the list, and to the sentence naming the tools that go through `openPicked`/`OpenDatabase` ("five — list_tables, describe_table, list_columns, query and read_table").

- [ ] **Step 8: Run and see them pass**

Run: `go test ./cmd/wakil-db/ ./internal/wakilcore/`
Expected: PASS (MySQL and Mongo live tests skip without their env vars).

- [ ] **Step 9: Commit**

```bash
git add internal/wakilcore cmd/wakil-db cmd/wakil/main_test.go
git commit -m "wakil-db: list_columns — every table's columns in one read, for 2d-i's vocabulary"
```

---

### Task 2: `Identifier`, `fold`, `Vocabulary`

**Files:**
- Create: `app/Sources/WakilKit/Identifiers/Identifier.swift`
- Test: `app/Tests/WakilKitTests/IdentifierTests.swift`

**Interfaces:**
- Produces:
  - `public enum IdentifierKind: String, Sendable { case table, column, collection, code, file, action, org, project, environment, endpoint, path }`
  - `public enum IdentifierSourceKind: Int, Sendable, Comparable { case panes = 0, schema = 1, wakil = 2, code = 3 }` (raw value is rank order)
  - `public struct Identifier: Sendable, Hashable { text: String; kind: IdentifierKind; origin: String; source: IdentifierSourceKind }`
  - `public func identifierFold(_ s: String) -> String`
  - `public struct Vocabulary: Sendable { init(_ identifiers: [Identifier]); static let empty; var count: Int; func names(folded: String) -> [Identifier] }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

@Test func foldKeepsOnlyLettersDigitsAndDots() {
    #expect(identifierFold("transaction read only") == "transactionreadonly")
    #expect(identifierFold("transaction_read_only") == "transactionreadonly")
    #expect(identifierFold("Describe-Editability") == "describeeditability")
    #expect(identifierFold("customer's") == "customers")
    #expect(identifierFold("internal/wakilcore") == "internalwakilcore")
    #expect(identifierFold("paths.go") == "paths.go")
}

@Test func vocabularyLooksUpByFoldedForm() {
    let a = Identifier(text: "edit_quote", kind: .table, origin: "staging · core db", source: .schema)
    let b = Identifier(text: "EditQuote", kind: .code, origin: "wakil/app", source: .code)
    let vocabulary = Vocabulary([a, b, a])
    #expect(vocabulary.count == 2)
    #expect(Set(vocabulary.names(folded: "editquote")) == [a, b])
    #expect(vocabulary.names(folded: "nothing").isEmpty)
    #expect(Vocabulary.empty.count == 0)
}
```

- [ ] **Step 2: Run and see it fail**

Run: `cd app && swift test --filter IdentifierTests`
Expected: FAIL to compile — `cannot find 'identifierFold' in scope`.

- [ ] **Step 3: Implement** `Identifier.swift`:

```swift
import Foundation

/// What a known name is. Shown in the note, so a reader can tell a
/// column from a code name with the same spelling.
public enum IdentifierKind: String, Sendable {
    case table, column, collection, code, file, action, org, project, environment, endpoint, path
}

/// Which source supplied a name. The raw value is the candidate ranking
/// the spec fixes: what is on screen first, code last.
public enum IdentifierSourceKind: Int, Sendable, Comparable {
    case panes = 0, schema = 1, wakil = 2, code = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One name Wakil knows is in scope.
public struct Identifier: Sendable, Hashable {
    public let text: String
    public let kind: IdentifierKind
    /// Where it came from, as the note prints it: `staging · core db`, `wakil/app`.
    public let origin: String
    public let source: IdentifierSourceKind

    public init(text: String, kind: IdentifierKind, origin: String, source: IdentifierSourceKind) {
        self.text = text
        self.kind = kind
        self.origin = origin
        self.source = source
    }
}

/// The fold `2d-stt-probe.md` §6.2 measured and §10 re-measured:
/// lowercase, then keep only letters, digits and dots. Spaces, hyphens,
/// underscores, apostrophes and slashes all fold away; dots stay so
/// `paths.go` keeps its extension.
public func identifierFold(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "."
    }.map(Character.init))
}

/// Every source's names, indexed by folded form. Immutable: a rebuild
/// replaces it whole, so a reader never sees half of one org's names.
public struct Vocabulary: Sendable {
    private let byFold: [String: [Identifier]]
    public let count: Int

    public static let empty = Vocabulary([])

    public init(_ identifiers: [Identifier]) {
        var seen = Set<Identifier>()
        var byFold: [String: [Identifier]] = [:]
        for identifier in identifiers where seen.insert(identifier).inserted {
            let key = identifierFold(identifier.text)
            guard !key.isEmpty else { continue }
            byFold[key, default: []].append(identifier)
        }
        self.byFold = byFold
        self.count = seen.count
    }

    public func names(folded: String) -> [Identifier] { byFold[folded] ?? [] }
}
```

- [ ] **Step 4: Run and see it pass**

Run: `cd app && swift test --filter IdentifierTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Identifiers/Identifier.swift app/Tests/WakilKitTests/IdentifierTests.swift
git commit -m "2d-i: Identifier, the measured fold, and Vocabulary"
```

---

### Task 3: `IdentifierResolver`, against both recordings

**Files:**
- Create: `app/Sources/WakilKit/Identifiers/IdentifierResolver.swift`
- Create: `scripts/probe/stt-set2/vocab-snapshot-2026-10-06.txt`
- Test: `app/Tests/WakilKitTests/IdentifierResolverTests.swift`, `app/Tests/WakilKitTests/IdentifierCorpusTests.swift`

**Interfaces:**
- Consumes: Task 2's `Identifier`, `Vocabulary`, `identifierFold`.
- Produces:
  - `public struct Resolution: Sendable, Equatable { phrase: String; candidates: [Identifier]; more: Int }`
  - `public enum IdentifierResolver { static let maxRunWords = 6; static let maxCandidates = 3; static let maxResolutions = 8; static func resolve(_ text: String, in vocabulary: Vocabulary) -> [Resolution] }` — returns `[]` when over `maxResolutions`.

- [ ] **Step 1: Write the failing unit tests** in `IdentifierResolverTests.swift`:

```swift
import Testing
@testable import WakilKit

private func name(_ text: String, _ kind: IdentifierKind = .column, _ origin: String = "staging · core db",
                  _ source: IdentifierSourceKind = .schema) -> Identifier {
    Identifier(text: text, kind: kind, origin: origin, source: source)
}

@Test func joinsWordsIntoTheIdentifierTheyFold() {
    let v = Vocabulary([name("transaction_read_only")])
    let r = IdentifierResolver.resolve("Set transaction read only to one.", in: v)
    #expect(r == [Resolution(phrase: "transaction read only", candidates: [name("transaction_read_only")], more: 0)])
}

@Test func longestRunWinsAndRunsDoNotOverlap() {
    let v = Vocabulary([name("read_only"), name("transaction_read_only")])
    let r = IdentifierResolver.resolve("transaction read only", in: v)
    #expect(r.map(\.phrase) == ["transaction read only"])
}

@Test func aRunThatAlreadyIsTheNameResolvesNothing() {
    let v = Vocabulary([name("wakil", .project, "initech", .wakil), name("staging", .environment, "initech", .wakil)])
    #expect(IdentifierResolver.resolve("List the databases on Wakil, then staging.", in: v).isEmpty)
}

@Test func surroundingPunctuationIsStrippedButInnerDotsKept() {
    let v = Vocabulary([name("ContextStore.swift", .file, "wakil/app", .code)])
    let r = IdentifierResolver.resolve("Open context store.swift.", in: v)
    #expect(r.map(\.phrase) == ["context store.swift"])
}

@Test func candidatesRankBySourceThenOriginThenTextAndCapAtThree() {
    let v = Vocabulary([
        name("status", .code, "wakil/app", .code),
        name("Status", .column, "staging · jobs db", .schema),
        name("STATUS", .column, "staging · core db", .schema),
        name("status_", .column, "pane", .panes),
        name("s_tatus", .code, "a", .code),
    ])
    let r = IdentifierResolver.resolve("what is the S tatus", in: v)
    #expect(r.count == 1)
    #expect(r[0].candidates.map(\.text) == ["status_", "STATUS", "Status"])
    #expect(r[0].more == 2)
}

@Test func moreThanEightResolutionsMeansNone() {
    let names = (1...9).map { name("word\($0)_x") }
    let text = (1...9).map { "word\($0) x" }.joined(separator: " and ")
    #expect(IdentifierResolver.resolve(text, in: Vocabulary(names)).isEmpty)
    let eight = (1...8).map { "word\($0) x" }.joined(separator: " and ")
    #expect(IdentifierResolver.resolve(eight, in: Vocabulary(names)).count == 8)
}

@Test func anEmptyVocabularyOrTextResolvesNothing() {
    #expect(IdentifierResolver.resolve("transaction read only", in: .empty).isEmpty)
    #expect(IdentifierResolver.resolve("", in: Vocabulary([name("x_y")])).isEmpty)
}
```

- [ ] **Step 2: Run and see them fail**

Run: `cd app && swift test --filter IdentifierResolverTests`
Expected: FAIL to compile — `cannot find 'IdentifierResolver'`.

- [ ] **Step 3: Implement** `IdentifierResolver.swift`:

```swift
import Foundation

/// One phrase in a turn that folds to names Wakil knows.
public struct Resolution: Sendable, Equatable {
    /// The words as the operator wrote them, punctuation stripped.
    public let phrase: String
    /// At most `IdentifierResolver.maxCandidates`, best first.
    public let candidates: [Identifier]
    /// How many further candidates were cut.
    public let more: Int

    public init(phrase: String, candidates: [Identifier], more: Int) {
        self.phrase = phrase
        self.candidates = candidates
        self.more = more
    }
}

/// The fold matcher `2d-stt-probe.md` §10 measured. Pure: no I/O, no
/// state. **No near matching** — it failed the fresh recording.
public enum IdentifierResolver {
    public static let maxRunWords = 6
    public static let maxCandidates = 3
    public static let maxResolutions = 8

    public static func resolve(_ text: String, in vocabulary: Vocabulary) -> [Resolution] {
        let words = text.split(whereSeparator: \.isWhitespace).map(stripPunctuation).filter { !$0.isEmpty }
        guard !words.isEmpty, vocabulary.count > 0 else { return [] }
        var used = [Bool](repeating: false, count: words.count)
        var found: [(start: Int, resolution: Resolution)] = []
        for length in stride(from: min(maxRunWords, words.count), through: 1, by: -1) {
            for start in 0...(words.count - length) where !used[start..<(start + length)].contains(true) {
                let phrase = words[start..<(start + length)].joined(separator: " ")
                let names = vocabulary.names(folded: identifierFold(phrase))
                guard !names.isEmpty else { continue }
                for i in start..<(start + length) { used[i] = true }
                // Already says it: the operator wrote the name, nothing to resolve.
                if names.contains(where: { $0.text.lowercased() == phrase.lowercased() }) { continue }
                let ranked = names.sorted(by: rankedBefore)
                found.append((start, Resolution(
                    phrase: phrase,
                    candidates: Array(ranked.prefix(maxCandidates)),
                    more: max(0, ranked.count - maxCandidates))))
            }
        }
        // Over the cap, the turn is probably pasted output: no note at all.
        guard found.count <= maxResolutions else { return [] }
        return found.sorted { $0.start < $1.start }.map(\.resolution)
    }

    /// Leading and trailing punctuation off; inner dots and the rest stay.
    static func stripPunctuation(_ word: Substring) -> String {
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        return String(word).trimmingCharacters(in: edge)
    }

    static func rankedBefore(_ a: Identifier, _ b: Identifier) -> Bool {
        if a.source != b.source { return a.source < b.source }
        if a.origin.count != b.origin.count { return a.origin.count < b.origin.count }
        return a.text < b.text
    }
}
```

- [ ] **Step 4: Run and see them pass**

Run: `cd app && swift test --filter IdentifierResolverTests`
Expected: PASS. If `candidatesRankBySourceThenOriginThenTextAndCapAtThree` fails on the order of `STATUS`/`Status`, check `rankedBefore`'s origin-length rule ("staging · core db" is shorter than "staging · jobs db"? equal length — then text: `"STATUS" < "Status"` in Swift's ordering). Fix the implementation, not the expectation, unless the spec's ranking says otherwise.

- [ ] **Step 5: Freeze the corpus vocabulary**

```bash
cd scripts/probe/stt-set2
python3 -I vocab_code.py
sort -u vocab-code.txt vocab-small.txt > vocab-snapshot-2026-10-06.txt
rm vocab-code.txt
wc -l vocab-snapshot-2026-10-06.txt
```
Expected: about 19,000 lines. Every line is one identifier's text. In the test, each snapshot line becomes `Identifier(text:, kind: .code, origin: "snapshot", source: .code)` — the corpus measures recovery, not ranking.

- [ ] **Step 6: Write the corpus test** in `IdentifierCorpusTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// `scripts/probe/` holds both recordings from `2d-stt-probe.md` §10.
private let probeDirectory = URL(fileURLWithPath: #filePath)   // app/Tests/WakilKitTests/IdentifierCorpusTests.swift
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("scripts/probe")

private func lines(_ relative: String) throws -> [String] {
    try String(contentsOf: probeDirectory.appendingPathComponent(relative), encoding: .utf8)
        .split(separator: "\n").map(String.init)
}

/// `sttspike` output: `NN.wav\tseconds\ttranscript` lines under `## Apple`.
private func transcripts(_ relative: String) throws -> [String] {
    try lines(relative).filter { $0.split(separator: "\t").count == 3 }
        .map { String($0.split(separator: "\t")[2]) }
}

private let snapshot: Vocabulary = {
    let texts = (try? lines("stt-set2/vocab-snapshot-2026-10-06.txt")) ?? []
    return Vocabulary(texts.map { Identifier(text: $0, kind: .code, origin: "snapshot", source: .code) })
}()

/// §4's exact rule: case-sensitive, not inside a longer identifier.
private func exact(_ ident: String, in text: String) -> Bool {
    let pattern = "(?<![\\w.-])" + NSRegularExpression.escapedPattern(for: ident) + "(?![\\w-])"
    return text.range(of: pattern, options: .regularExpression) != nil
}

private func score(_ transcripts: [String], truth: [[String]]) -> (recovered: Int, wrong: Int) {
    var recovered = 0, wrong = 0
    for (text, idents) in zip(transcripts, truth) {
        let resolutions = IdentifierResolver.resolve(text, in: snapshot)
        let suggested = Set(resolutions.flatMap { $0.candidates.map(\.text) })
        recovered += idents.filter { !exact($0, in: text) && suggested.contains($0) }.count
        wrong += resolutions.filter { r in !r.candidates.contains { idents.contains($0.text) } }.count
    }
    return (recovered, wrong)
}

/// §3's identifiers, in order — `scripts/probe/stt-score.py`'s IDENT.
private let setOneTruth: [[String]] = [
    ["staging", "core"], ["edit_quote"], ["writeRef"], ["wakilcore", "AssertSQLMutation"],
    ["INI-2835"], ["2c-ii-b"], ["2b-viii"], ["Umbrella"], ["transaction_read_only"],
    ["hardenMySQLWriteConfig"], ["WakilWindow.swift"], ["make app-test"],
    ["phase-2c-ii-acceptance.md"], ["JSONValue"], ["wakil-pm"], ["wakil-acceptance-2"],
    ["edit_bit"], ["ctx_adopt_provider"], ["Invariant 6"], ["writeGate", "production"],
    ["paths.go", "internal/wakilcore"], ["acc-staging-core-write"], ["describeEditability"],
    ["wakilacc"], ["events"],
]

@Test func setOneRecoversAtLeastWhatTheProbeMeasured() throws {
    let result = score(try transcripts("stt-2026-10-06-apple.tsv"), truth: setOneTruth)
    #expect(result.recovered >= 6)   // §10: fold +6
    #expect(result.wrong <= 6)       // §10: 6 wrong
}

@Test func setTwoRecoversAtLeastWhatTheProbeMeasured() throws {
    let truth = try lines("stt-set2/utterances.tsv").filter { !$0.hasPrefix("#") }
        .map { $0.split(separator: "\t")[1].split(separator: ",").map(String.init) }
    let result = score(try transcripts("stt-set2/apple-2026-10-06.tsv"), truth: truth)
    #expect(result.recovered >= 11)  // §10: fold +11
    #expect(result.wrong <= 2)       // §10: 2 wrong
}
```

- [ ] **Step 7: Run the corpus tests**

Run: `cd app && swift test --filter IdentifierCorpusTests`
Expected: PASS. Record the actual `recovered`/`wrong` numbers (add a temporary `print`, then remove it). **If either `wrong` bound fails, stop and report the phrases to the controller** — do not loosen a bound. If recovered rises above the floor (the punctuation strip can recover `ContextStore.swift`), tighten that test's floor to the new number and note it in the commit message.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/Identifiers/IdentifierResolver.swift app/Tests/WakilKitTests/IdentifierResolverTests.swift app/Tests/WakilKitTests/IdentifierCorpusTests.swift scripts/probe/stt-set2/vocab-snapshot-2026-10-06.txt
git commit -m "2d-i: the fold resolver, pinned against both 2026-10-06 recordings"
```

---

### Task 4: `TurnNote` — the note, the row, the rebuilt split

**Files:**
- Create: `app/Sources/WakilKit/Identifiers/TurnNote.swift`
- Test: `app/Tests/WakilKitTests/TurnNoteTests.swift`

**Interfaces:**
- Consumes: Task 3's `Resolution`.
- Produces:
  - `public enum TurnNote { static let header: String; static func render(_ r: [Resolution]) -> String?; static func row(_ r: [Resolution]) -> String; static func split(_ sent: String) -> (typed: String, row: String?) }`
  - `render` returns the note block (header + lines), or `nil` for `[]`. The text sent is `typed + "\n\n" + note`.
  - `row` is the `RESOLVED` row's detail: `phrase → first candidate` joined by ` · `.
  - `split` undoes `typed + "\n\n" + note` for a rebuilt thread, and derives the same row text from the note's lines.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

private let column = Identifier(text: "transaction_read_only", kind: .column, origin: "staging · core db", source: .schema)
private let code = Identifier(text: "describeEditability", kind: .code, origin: "wakil/app", source: .code)
private let two = [
    Resolution(phrase: "transaction read only", candidates: [column], more: 0),
    Resolution(phrase: "describe editability", candidates: [code], more: 0),
]

@Test func renderWritesTheHeaderAndOneLinePerPhrase() {
    #expect(TurnNote.render(two) == """
    [Wakil: identifiers in scope that match words in this turn — a hint, not a correction]
    - "transaction read only" → transaction_read_only (column · staging · core db)
    - "describe editability" → describeEditability (code · wakil/app)
    """)
}

@Test func renderListsSeveralCandidatesAndHowManyMore() {
    let a = Identifier(text: "orders.status", kind: .column, origin: "staging · core db", source: .schema)
    let b = Identifier(text: "users.status", kind: .column, origin: "staging · core db", source: .schema)
    let note = TurnNote.render([Resolution(phrase: "status", candidates: [a, b], more: 2)])
    #expect(note?.hasSuffix(#"- "status" → orders.status (column · staging · core db), users.status (column · staging · core db) and 2 more"#) == true)
}

@Test func noResolutionsMeansNoNote() {
    #expect(TurnNote.render([]) == nil)
}

@Test func theRowNamesEachPhraseAndItsFirstCandidate() {
    #expect(TurnNote.row(two) == "transaction read only → transaction_read_only · describe editability → describeEditability")
}

@Test func splitUndoesWhatSendJoined() {
    let sent = "what is this\n\n" + TurnNote.render(two)!
    let parts = TurnNote.split(sent)
    #expect(parts.typed == "what is this")
    #expect(parts.row == TurnNote.row(two))
}

@Test func splitLeavesATurnWithNoNoteAlone() {
    let parts = TurnNote.split("just text\n\n[not ours]")
    #expect(parts.typed == "just text\n\n[not ours]")
    #expect(parts.row == nil)
}
```

- [ ] **Step 2: Run and see them fail**

Run: `cd app && swift test --filter TurnNoteTests`
Expected: FAIL to compile — `cannot find 'TurnNote'`.

- [ ] **Step 3: Implement** `TurnNote.swift`:

```swift
import Foundation

/// The hint 2d-i hands the agent under the operator's unchanged text, and
/// the one-line `RESOLVED` row the thought thread shows for it. Plain
/// text, so any harness can read it (Invariant 1).
public enum TurnNote {
    public static let header =
        "[Wakil: identifiers in scope that match words in this turn — a hint, not a correction]"

    public static func render(_ resolutions: [Resolution]) -> String? {
        guard !resolutions.isEmpty else { return nil }
        let lines = resolutions.map { r -> String in
            let names = r.candidates.map { "\($0.text) (\($0.kind.rawValue) · \($0.origin))" }
                .joined(separator: ", ")
            return "- \"\(r.phrase)\" → \(names)" + (r.more > 0 ? " and \(r.more) more" : "")
        }
        return ([header] + lines).joined(separator: "\n")
    }

    public static func row(_ resolutions: [Resolution]) -> String {
        resolutions.compactMap { r in r.candidates.first.map { "\(r.phrase) → \($0.text)" } }
            .joined(separator: " · ")
    }

    /// For a rebuilt thread: the transcript holds what was sent, which is
    /// the typed text plus the note. Returns the typed text and the row.
    public static func split(_ sent: String) -> (typed: String, row: String?) {
        guard let range = sent.range(of: "\n\n" + header + "\n") else { return (sent, nil) }
        let typed = String(sent[..<range.lowerBound])
        let pairs = sent[range.upperBound...].split(separator: "\n").compactMap { line -> String? in
            // - "phrase" → first (kind · origin)…
            guard line.hasPrefix("- \""), let close = line.range(of: "\" → ") else { return nil }
            let phrase = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
            let first = line[close.upperBound...].prefix { $0 != " " && $0 != "," }
            return "\(phrase) → \(first)"
        }
        return (typed, pairs.isEmpty ? nil : pairs.joined(separator: " · "))
    }
}
```

- [ ] **Step 4: Run and see them pass**

Run: `cd app && swift test --filter TurnNoteTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Identifiers/TurnNote.swift app/Tests/WakilKitTests/TurnNoteTests.swift
git commit -m "2d-i: TurnNote — the agent's hint, the RESOLVED row, and the rebuilt split"
```

---

### Task 5: Sources — the protocol, Wakil, Panes, Schema

**Files:**
- Create: `app/Sources/WakilKit/Identifiers/IdentifierSources.swift`
- Create: `app/Sources/WakilKit/Identifiers/SchemaSource.swift`
- Test: `app/Tests/WakilKitTests/IdentifierSourcesTests.swift`, `app/Tests/WakilKitTests/SchemaSourceTests.swift`

**Interfaces:**
- Consumes: `ActiveContext` (`ContextStore.swift:128`: `org`, `project`, `environment`, `rootPaths`), `ActionRegistry.all() -> [ActionDescriptor]` (`.name`), `LayoutStore.snapshot().panes` (`Pane.id`, `Pane.kind`), `PaneStore.snapshot(paneId:kind:) -> PaneSnapshot` (`.contents`: `.dataSurface(DataSurfaceSnapshot)` with `.columns` and `.editable?.table`; `.terminal(TerminalSnapshot)` with `.cwd`; `.api(ApiSnapshot)` with `.entry` and `.request.path: [ApiPart]` rendered by `apiRenderedPath`), `ToolCaller.callTool(name:arguments:timeout:)`, `MCPClient.readReplyTimeout`.
- Produces:
  - `public protocol IdentifierSource: Sendable { var kind: IdentifierSourceKind { get }; var name: String { get }; func identifiers(for context: ActiveContext) async throws -> [Identifier] }`
  - `public struct WakilSource: IdentifierSource` — `init(registry: ActionRegistry)`
  - `public struct PaneSource: IdentifierSource` — `init(layout: LayoutStore, panes: PaneStore)`
  - `public struct SchemaSource: IdentifierSource` — `init(db: any ToolCaller)`

- [ ] **Step 1: Write the failing tests.** In `IdentifierSourcesTests.swift`, build an `ActionRegistry` the way `ActionRegistryTests.swift` does (copy its setup helper — scratch journal directory), register one action named `pane_move`, and:

```swift
@Test func wakilSourceNamesActionsAndTheActiveContext() async throws {
    let registry = /* as ActionRegistryTests builds one, with an action named "pane_move" registered */
    let context = ActiveContext(org: "initech", project: "wakil-acceptance-2", environment: "staging",
                                rootPaths: [], activeProvider: "p", environmentProduction: .undeclared)
    let names = try await WakilSource(registry: registry).identifiers(for: context)
    #expect(names.contains(Identifier(text: "pane_move", kind: .action, origin: "wakil", source: .wakil)))
    #expect(names.contains(Identifier(text: "wakil-acceptance-2", kind: .project, origin: "initech", source: .wakil)))
    #expect(names.contains(Identifier(text: "staging", kind: .environment, origin: "initech · wakil-acceptance-2", source: .wakil)))
    #expect(names.contains(Identifier(text: "initech", kind: .org, origin: "wakil", source: .wakil)))
}
```

(Use `ActiveContext`'s real memberwise or public initializer — check `ContextStore.swift:128-185`; if it has none public, add `@testable import` and use the internal one.)

For panes: open a pane of kind `"db"` in a `LayoutStore`, seed its `PaneStore` contents with a data surface whose columns are `["id", "transaction_read_only"]` and editable table `edit_quote` (copy the seeding helper from `PaneStoreTests.swift`), and assert `PaneSource` yields `edit_quote` (`.table`) and `transaction_read_only` (`.column`) with origin `"pane · <pane title>"` and source `.panes`; a terminal pane yields its `cwd` as `.path`; an api pane yields its rendered path as `.endpoint` and its entry name as `.endpoint`.

In `SchemaSourceTests.swift`:

```swift
@Test func schemaSourceListsEveryDatabasesTablesAndColumns() async throws {
    let db = RecordingToolCaller(reply: { name, arguments in
        switch name {
        case "list_databases":
            return .object(["structuredContent": .object(["databases": .array([
                .object(["name": .string("core"), "driver": .string("mysql")])])])])
        case "list_columns":
            return .object(["structuredContent": .object(["tables": .array([
                .object(["table": .string("edit_quote"),
                         "columns": .array([.string("id"), .string("transaction_read_only")])])])])])
        default:
            throw CancellationError()
        }
    })
    let context = /* ActiveContext with environment "staging" */
    let names = try await SchemaSource(db: db).identifiers(for: context)
    #expect(Set(names) == [
        Identifier(text: "edit_quote", kind: .table, origin: "staging · core db", source: .schema),
        Identifier(text: "id", kind: .column, origin: "staging · core db", source: .schema),
        Identifier(text: "transaction_read_only", kind: .column, origin: "staging · core db", source: .schema),
    ])
    let calls = await db.calls
    #expect(calls.map(\.name) == ["list_databases", "list_columns"])
    #expect(calls[1].arguments == .object(["database": .string("core")]))
}

@Test func anUnreachableDatabaseThrowsSoTheStoreCanJournalIt() async {
    let db = RecordingToolCaller(reply: { name, _ in
        if name == "list_databases" {
            return .object(["structuredContent": .object(["databases": .array([.object(["name": .string("core")])])])])
        }
        return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("wakil-db: connection refused")])])])
    })
    await #expect(throws: (any Error).self) {
        _ = try await SchemaSource(db: db).identifiers(for: /* ActiveContext */)
    }
}
```

Copy `RecordingToolCaller` usage from `ToolCallerTests.swift:10-44` (it is declared in the test target; reuse it, do not redeclare).

- [ ] **Step 2: Run and see them fail**

Run: `cd app && swift test --filter 'IdentifierSourcesTests|SchemaSourceTests'`
Expected: FAIL to compile — `cannot find 'WakilSource'`.

- [ ] **Step 3: Implement** `IdentifierSources.swift`:

```swift
import Foundation

/// Answers "which names are in scope for this context?" — the seam Jira
/// keys (2c-vi) and the editor (Phase 3) plug into later.
public protocol IdentifierSource: Sendable {
    var kind: IdentifierSourceKind { get }
    /// For the journal: which source failed.
    var name: String { get }
    func identifiers(for context: ActiveContext) async throws -> [Identifier]
}

/// Wakil's own names: registered actions, and the active org, project
/// and environment. The capability servers' tool names are not known in
/// Swift, so they are not here (spec, corrected 2026-10-06).
public struct WakilSource: IdentifierSource {
    public let kind = IdentifierSourceKind.wakil
    public let name = "wakil"
    let registry: ActionRegistry

    public init(registry: ActionRegistry) { self.registry = registry }

    public func identifiers(for context: ActiveContext) async throws -> [Identifier] {
        var out = await registry.all().map {
            Identifier(text: $0.name, kind: .action, origin: "wakil", source: .wakil)
        }
        out.append(Identifier(text: context.org, kind: .org, origin: "wakil", source: .wakil))
        out.append(Identifier(text: context.project, kind: .project, origin: context.org, source: .wakil))
        out.append(Identifier(text: context.environment, kind: .environment,
                              origin: "\(context.org) · \(context.project)", source: .wakil))
        return out.filter { !$0.text.isEmpty }
    }
}

/// What is on screen: open panes' tables and columns, terminals' working
/// directories, api panes' endpoints.
public struct PaneSource: IdentifierSource {
    public let kind = IdentifierSourceKind.panes
    public let name = "panes"
    let layout: LayoutStore
    let panes: PaneStore

    public init(layout: LayoutStore, panes: PaneStore) {
        self.layout = layout
        self.panes = panes
    }

    public func identifiers(for context: ActiveContext) async throws -> [Identifier] {
        var out: [Identifier] = []
        for pane in await layout.snapshot().panes {
            let origin = "pane · \(pane.title)"
            switch await panes.snapshot(paneId: pane.id, kind: pane.kind).contents {
            case .dataSurface(let grid):
                if let table = grid.editable?.table {
                    out.append(Identifier(text: table, kind: .table, origin: origin, source: .panes))
                }
                out += grid.columns.map { Identifier(text: $0, kind: .column, origin: origin, source: .panes) }
            case .terminal(let terminal):
                out.append(Identifier(text: terminal.cwd, kind: .path, origin: origin, source: .panes))
            case .api(let api):
                out.append(Identifier(text: api.entry, kind: .endpoint, origin: origin, source: .panes))
                out.append(Identifier(text: apiRenderedPath(api.request.path), kind: .endpoint,
                                      origin: origin, source: .panes))
            default:
                break
            }
        }
        return out.filter { !$0.text.isEmpty }
    }
}
```

(Check `Pane`'s title property name in `LayoutStore.swift`/`Pane` — use the real one. If `PaneSnapshotContents` has more cases than these, `default` covers them.)

`SchemaSource.swift`:

```swift
import Foundation

/// The active environment's tables and columns, through `wakil-db`:
/// `list_databases`, then one `list_columns` per database. A database
/// that fails throws, so `VocabularyStore` journals it and keeps the rest.
public struct SchemaSource: IdentifierSource {
    public let kind = IdentifierSourceKind.schema
    public let name = "schema"
    let db: any ToolCaller

    public init(db: any ToolCaller) { self.db = db }

    public func identifiers(for context: ActiveContext) async throws -> [Identifier] {
        let listed = try await structured(db.callTool(
            name: "list_databases", arguments: .object([:]), timeout: MCPClient.readReplyTimeout))
        guard case .array(let databases)? = listed["databases"] else { return [] }
        var out: [Identifier] = []
        for case .object(let database) in databases {
            guard case .string(let dbName)? = database["name"] else { continue }
            let origin = "\(context.environment) · \(dbName) db"
            let columns = try await structured(db.callTool(
                name: "list_columns", arguments: .object(["database": .string(dbName)]),
                timeout: MCPClient.readReplyTimeout))
            guard case .array(let tables)? = columns["tables"] else { continue }
            for case .object(let table) in tables {
                guard case .string(let tableName)? = table["table"] else { continue }
                out.append(Identifier(text: tableName, kind: .table, origin: origin, source: .schema))
                if case .array(let names)? = table["columns"] {
                    for case .string(let column) in names {
                        out.append(Identifier(text: column, kind: .column, origin: origin, source: .schema))
                    }
                }
            }
        }
        return out
    }

    /// A tool result's `structuredContent`, or a thrown error carrying the
    /// tool's own text when it answered `isError`.
    private func structured(_ result: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let object) = result else { throw SchemaSourceError(message: "wakil-db answered with no object") }
        if case .bool(true)? = object["isError"] {
            var text = "wakil-db answered isError"
            if case .array(let content)? = object["content"], case .object(let first)? = content.first,
               case .string(let message)? = first["text"] { text = message }
            throw SchemaSourceError(message: text)
        }
        guard case .object(let structured)? = object["structuredContent"] else { return [:] }
        return structured
    }
}

public struct SchemaSourceError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
```

(If `StandardActions.swift`'s `callChecked` is reachable and does the same `isError` check, use it instead of `structured`'s error half and say so in a comment. Do not duplicate it if it fits.)

- [ ] **Step 4: Run and see them pass**

Run: `cd app && swift test --filter 'IdentifierSourcesTests|SchemaSourceTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Identifiers/IdentifierSources.swift app/Sources/WakilKit/Identifiers/SchemaSource.swift app/Tests/WakilKitTests/IdentifierSourcesTests.swift app/Tests/WakilKitTests/SchemaSourceTests.swift
git commit -m "2d-i: identifier sources — Wakil, panes, and the schema through list_columns"
```

---

### Task 6: `CodeSource` — the scan, the cap, the `HEAD` cache

**Files:**
- Create: `app/Sources/WakilKit/Identifiers/CodeSource.swift`
- Test: `app/Tests/WakilKitTests/CodeSourceTests.swift`

**Interfaces:**
- Consumes: `IdentifierSource`, `ActiveContext.rootPaths`.
- Produces: `public struct CodeSource: IdentifierSource` — `init(cacheDirectory: URL, cap: Int = 20_000, git: String = "/usr/bin/git")`; `static func defaultCacheDirectory(home: String) -> URL` (`~/.wakil/vocabulary`); `static func compoundNames(in text: String) -> [String]`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

private func makeRepo(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codesource-\(UUID().uuidString)")
    for (path, body) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
    for args in [["init", "-q"], ["add", "-A"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "seed"]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path] + args
        try p.run(); p.waitUntilExit()
    }
    return root
}

private func context(_ roots: [URL]) -> ActiveContext { /* ActiveContext with rootPaths: roots.map(\.path) */ }

@Test func compoundNamesTakesJoinedWordsOnly() {
    let names = CodeSource.compoundNames(in: "let describeEditability = edit_quote + events; AssertSQLMutation(x) acc-staging-core-write")
    #expect(Set(names) == ["describeEditability", "edit_quote", "AssertSQLMutation", "acc-staging-core-write"])
}

@Test func scansTrackedFilesAndSkipsVendoredOnes() async throws {
    let root = try makeRepo([
        "Sources/Pane.swift": "func buildLaunch() { describeEditability() }",
        "vendor/lib.go": "func vendoredThing() {}",
    ])
    let source = CodeSource(cacheDirectory: root.appendingPathComponent(".cache"))
    let texts = Set(try await source.identifiers(for: context([root])).map(\.text))
    #expect(texts.isSuperset(of: ["buildLaunch", "describeEditability", "Pane.swift"]))
    #expect(!texts.contains("vendoredThing"))
}

@Test func capKeepsTheMostFrequentNames() async throws {
    let root = try makeRepo(["a.txt": "common_name common_name common_name rare_name"])
    let source = CodeSource(cacheDirectory: root.appendingPathComponent(".cache"), cap: 1)
    let texts = try await source.identifiers(for: context([root])).map(\.text)
    #expect(texts == ["common_name"])
}

@Test func aRootThatIsNotAGitRepositoryThrows() async {
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) {
        _ = try await CodeSource(cacheDirectory: plain.appendingPathComponent(".cache")).identifiers(for: context([plain]))
    }
}

@Test func theCacheIsReusedUntilHeadMoves() async throws {
    let root = try makeRepo(["a.swift": "first_name"])
    let cache = root.appendingPathComponent(".cache")
    let source = CodeSource(cacheDirectory: cache)
    _ = try await source.identifiers(for: context([root]))
    // Change the working tree without committing: HEAD is unchanged, so the cache answers.
    try "second_name".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
    #expect(Set(try await source.identifiers(for: context([root])).map(\.text)).contains("first_name"))
    // Commit: HEAD moves, so it rescans.
    for args in [["add", "-A"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "two"]] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path] + args; try p.run(); p.waitUntilExit()
    }
    #expect(Set(try await source.identifiers(for: context([root])).map(\.text)).contains("second_name"))
}
```

- [ ] **Step 2: Run and see them fail**

Run: `cd app && swift test --filter CodeSourceTests`
Expected: FAIL to compile — `cannot find 'CodeSource'`.

- [ ] **Step 3: Implement** `CodeSource.swift`:

```swift
import Foundation

/// Compound names and file names from each project root's tracked files
/// (spec: "rule 1" — every language, no per-language patterns). Capped
/// per root, most frequent first, and cached per root and git `HEAD`.
public struct CodeSource: IdentifierSource {
    public let kind = IdentifierSourceKind.code
    public let name = "code"
    let cacheDirectory: URL
    let cap: Int
    let git: String

    static let skippedDirectories = ["vendor/", "node_modules/", ".build/", "build/", "dist/", "generated/", "Generated/"]
    static let skippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "ico", "pdf", "wav", "m4a", "caf", "aiff", "icns", "ttf", "otf",
        "woff", "woff2", "zip", "bin", "sum", "lock", "resolved", "metallib",
    ]
    /// snake_case, kebab-case, camelCase / PascalCase with two or more parts.
    static let compound = try! NSRegularExpression(pattern:
        "\\b(?:[A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)+|[a-z]+[A-Z][A-Za-z0-9]*|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*|[A-Z]{2,}[a-z][A-Za-z0-9]*)\\b")

    public init(cacheDirectory: URL, cap: Int = 20_000, git: String = "/usr/bin/git") {
        self.cacheDirectory = cacheDirectory
        self.cap = cap
        self.git = git
    }

    public static func defaultCacheDirectory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".wakil", isDirectory: true)
            .appendingPathComponent("vocabulary", isDirectory: true)
    }

    public static func compoundNames(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return compound.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    public func identifiers(for context: ActiveContext) async throws -> [Identifier] {
        var out: [Identifier] = []
        for root in context.rootPaths {
            let origin = "\(context.project)/\(URL(fileURLWithPath: root).lastPathComponent)"
            out += try names(root: root).map { Identifier(text: $0, kind: .code, origin: origin, source: .code) }
        }
        return out
    }

    func names(root: String) throws -> [String] {
        let head = try run(["-C", root, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (root + "@" + head).data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        let cacheFile = cacheDirectory.appendingPathComponent(key + ".txt")
        if let cached = try? String(contentsOf: cacheFile, encoding: .utf8) {
            return cached.split(separator: "\n").map(String.init)
        }
        var counts: [String: Int] = [:]
        for path in try run(["-C", root, "ls-files"]).split(separator: "\n").map(String.init) {
            if Self.skippedDirectories.contains(where: { path.hasPrefix($0) || path.contains("/" + $0) }) { continue }
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            if Self.skippedExtensions.contains(url.pathExtension.lowercased()) { continue }
            counts[url.lastPathComponent, default: 0] += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for name in Self.compoundNames(in: text) { counts[name, default: 0] += 1 }
        }
        let kept = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(cap).map(\.key)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? kept.joined(separator: "\n").write(to: cacheFile, atomically: true, encoding: .utf8)
        return kept
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CodeSourceError(message: "git \(arguments.dropFirst(2).joined(separator: " ")) in \(arguments[1]): \(message)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CodeSourceError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
```

Note: the sort keeps the most frequent first and breaks ties alphabetically — `($0.value, $1.key) > ($1.value, $0.key)` is descending by count, ascending by name. If `capKeepsTheMostFrequentNames` fails, fix the comparator.

- [ ] **Step 4: Run and see them pass**

Run: `cd app && swift test --filter CodeSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Identifiers/CodeSource.swift app/Tests/WakilKitTests/CodeSourceTests.swift
git commit -m "2d-i: the code source — tracked files' compound names, capped, cached per HEAD"
```

---

### Task 7: `VocabularyStore` — rebuilds, the org drop, failures

**Files:**
- Create: `app/Sources/WakilKit/Identifiers/VocabularyStore.swift`
- Modify: `app/Sources/WakilKit/Registry/ActionRegistry.swift` (add `journalIdentifierEvent` beside `journalSentRequest`, line ~362)
- Test: `app/Tests/WakilKitTests/VocabularyStoreTests.swift`

**Interfaces:**
- Consumes: `IdentifierSource`, `Vocabulary`, `ActiveContext`.
- Produces:
  - `public actor VocabularyStore { init(live: [any IdentifierSource], cached: [any IdentifierSource], report: @escaping @Sendable (String, String) async -> Void); func contextChanged(_ context: ActiveContext) async; func dropAll(); func current() async -> Vocabulary }`
  - `live` sources (Wakil, Panes) are read on every `current()`; `cached` sources (Schema, Code) are rebuilt by `contextChanged` in a background task and held.
  - `report(sourceName, errorDescription)` is how failures reach the journal.
  - `ActionRegistry.journalIdentifierEvent(action: String, params: JSONValue, environment: String, outcome: String) throws`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

private struct FixedSource: IdentifierSource {
    let kind: IdentifierSourceKind
    let name: String
    let answer: @Sendable (ActiveContext) async throws -> [Identifier]
    func identifiers(for context: ActiveContext) async throws -> [Identifier] { try await answer(context) }
}

private func ctx(_ org: String) -> ActiveContext { /* ActiveContext(org: org, project: "p", environment: "staging", …) */ }
private func table(_ text: String, _ org: String) -> Identifier {
    Identifier(text: text, kind: .table, origin: org, source: .schema)
}

@Test func cachedSourcesAreBuiltOnContextChangeAndLiveOnesOnEveryRead() async {
    let schema = FixedSource(kind: .schema, name: "schema") { [table("edit_quote", $0.org)] }
    let live = FixedSource(kind: .panes, name: "panes") { _ in [Identifier(text: "pane_col", kind: .column, origin: "pane", source: .panes)] }
    let store = VocabularyStore(live: [live], cached: [schema], report: { _, _ in })
    await store.contextChanged(ctx("initech"))
    await store.waitForRebuild()
    let v = await store.current()
    #expect(!v.names(folded: "editquote").isEmpty)
    #expect(!v.names(folded: "panecol").isEmpty)
}

@Test func anOrgSwitchDropsTheOldOrgsNamesAtOnceAndALateResultIsDiscarded() async {
    let gate = AsyncStream<Void>.makeStream()
    let schema = FixedSource(kind: .schema, name: "schema") { context in
        if context.org == "initech" { for await _ in gate.stream { break } }   // the old org's build is slow
        return [table(context.org == "initech" ? "old_table" : "new_table", context.org)]
    }
    let store = VocabularyStore(live: [], cached: [schema], report: { _, _ in })
    await store.contextChanged(ctx("initech"))
    await store.dropAll()
    await store.contextChanged(ctx("umbrella"))
    gate.continuation.yield()                                              // the old build finishes late
    await store.waitForRebuild()
    let v = await store.current()
    #expect(v.names(folded: "oldtable").isEmpty)
    #expect(!v.names(folded: "newtable").isEmpty)
}

@Test func aFailingSourceIsReportedAndTheOthersStillResolve() async {
    let reports = ReportBox()
    let bad = FixedSource(kind: .schema, name: "schema") { _ in throw SchemaSourceError(message: "connection refused") }
    let good = FixedSource(kind: .code, name: "code") { _ in [Identifier(text: "build_launch", kind: .code, origin: "x", source: .code)] }
    let store = VocabularyStore(live: [], cached: [bad, good], report: { await reports.add($0, $1) })
    await store.contextChanged(ctx("initech"))
    await store.waitForRebuild()
    #expect(!(await store.current()).names(folded: "buildlaunch").isEmpty)
    #expect(await reports.all == ["schema: connection refused"])
}

@Test func readingBeforeTheFirstBuildFinishesAnswersAtOnce() async {
    let never = FixedSource(kind: .code, name: "code") { _ in try await Task.sleep(for: .seconds(3600)); return [] }
    let store = VocabularyStore(live: [], cached: [never], report: { _, _ in })
    await store.contextChanged(ctx("initech"))
    let started = Date()
    _ = await store.current()
    #expect(Date().timeIntervalSince(started) < 1)
}

private actor ReportBox {
    var all: [String] = []
    func add(_ source: String, _ message: String) { all.append("\(source): \(message)") }
}
```

- [ ] **Step 2: Run and see them fail**

Run: `cd app && swift test --filter VocabularyStoreTests`
Expected: FAIL to compile — `cannot find 'VocabularyStore'`.

- [ ] **Step 3: Implement** `VocabularyStore.swift`:

```swift
import Foundation

/// Owns 2d-i's sources. Cached sources (schema, code) are rebuilt in the
/// background on a context change; live ones (Wakil, panes) are read on
/// every `current()`, which is cheap and always current. **A turn never
/// waits for a cached build**: `current()` answers with what is ready.
public actor VocabularyStore {
    private let live: [any IdentifierSource]
    private let cached: [any IdentifierSource]
    private let report: @Sendable (String, String) async -> Void
    private var context: ActiveContext?
    private var held: [Identifier] = []
    /// Bumped by every drop and every context change, so a build that
    /// finishes after either is discarded rather than merged (Invariant 4).
    private var generation = 0
    private var rebuild: Task<Void, Never>?

    public init(live: [any IdentifierSource], cached: [any IdentifierSource],
                report: @escaping @Sendable (String, String) async -> Void) {
        self.live = live
        self.cached = cached
        self.report = report
    }

    /// An org switch: nothing of the old org survives this call.
    public func dropAll() {
        generation += 1
        rebuild?.cancel()
        rebuild = nil
        held = []
        context = nil
    }

    public func contextChanged(_ context: ActiveContext) {
        if self.context?.org != context.org { held = [] }
        generation += 1
        self.context = context
        rebuild?.cancel()
        let mine = generation
        let sources = cached
        let report = report
        rebuild = Task.detached {
            var names: [Identifier] = []
            for source in sources {
                do { names += try await source.identifiers(for: context) }
                catch { await report(source.name, String(describing: error)) }
            }
            await self.install(names, generation: mine)
        }
    }

    private func install(_ names: [Identifier], generation mine: Int) {
        guard mine == generation else { return }
        held = names
    }

    /// For tests: waits for the latest cached build to finish.
    func waitForRebuild() async { await rebuild?.value }

    public func current() async -> Vocabulary {
        guard let context else { return .empty }
        var names = held
        for source in live {
            do { names += try await source.identifiers(for: context) }
            catch { await report(source.name, String(describing: error)) }
        }
        return Vocabulary(names)
    }
}
```

Note on the late-result test: the old build is cancelled, but `FixedSource` ignores cancellation; the generation check in `install` is what discards it. `waitForRebuild` waits for the *latest* task only.

In `ActionRegistry.swift`, beside `journalSentRequest`:

```swift
    /// 2d-i: a note handed to the agent, or a vocabulary source that
    /// failed. Not an action, so it has no `secretParams`; nothing it
    /// records is a credential.
    public func journalIdentifierEvent(
        action: String, params: JSONValue, environment: String, outcome: String
    ) throws {
        try appendJournalEntry(
            action: action, params: params, origin: .ui,
            environment: environment, outcome: outcome, secretParams: nil)
    }
```

- [ ] **Step 4: Run and see them pass**

Run: `cd app && swift test --filter VocabularyStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Identifiers/VocabularyStore.swift app/Sources/WakilKit/Registry/ActionRegistry.swift app/Tests/WakilKitTests/VocabularyStoreTests.swift
git commit -m "2d-i: VocabularyStore — background rebuilds, the org drop, failures journalled"
```

---

### Task 8: ⌘P/⌘K fold ranking

**Files:**
- Modify: `app/Sources/WakilKit/Command/PaletteItem.swift:93-104` (`rank`)
- Test: `app/Tests/WakilKitTests/PaletteTests.swift`

**Interfaces:**
- Consumes: Task 2's `identifierFold`.
- Produces: `rank(_:query:)` unchanged in signature.

- [ ] **Step 1: Write the failing test** in `PaletteTests.swift`:

```swift
@Test func aSpokenShapeQueryFindsTheJoinedName() {
    let items = [
        PaletteItem(id: "1", kind: .action, title: "db_run_query", subtitle: "", payload: "db_run_query"),
        PaletteItem(id: "2", kind: .action, title: "pane_move", subtitle: "", payload: "pane_move"),
        PaletteItem(id: "3", kind: .action, title: "pane_snap", subtitle: "flush to the grid", payload: "pane_snap"),
    ]
    #expect(rank(items, query: "pane move").first?.payload == "pane_move")
    #expect(rank(items, query: "pane move").count == 1)
}
```

(Match `PaletteItem`'s real initializer labels from `PaletteItem.swift:20-38`.)

- [ ] **Step 2: Run and see it fail**

Run: `cd app && swift test --filter PaletteTests`
Expected: FAIL — "pane move" has a space, so `fuzzyScore` finds no match.

- [ ] **Step 3: Implement** — replace `rank`'s body:

```swift
public func rank(_ items: [PaletteItem], query: String) -> [PaletteItem] {
    // 2d-i: a query whose fold is a prefix of a title's or subtitle's fold
    // ("pane move" → `pane_move`) ranks above every subsequence-only match.
    let folded = identifierFold(query)
    let foldBonus = 1_000_000
    return items
        .enumerated()
        .compactMap { position, item -> (Int, Int, PaletteItem)? in
            let title = fuzzyScore(query, against: item.title)
            let subtitle = fuzzyScore(query, against: item.subtitle)
            let folds = !folded.isEmpty && [item.title, item.subtitle].contains { identifierFold($0).hasPrefix(folded) }
            guard let best = [title, subtitle, folds ? 0 : nil].compactMap({ $0 }).max() else { return nil }
            return (best + (folds ? foldBonus : 0), position, item)
        }
        .sorted { ($0.0, -$0.1) > ($1.0, -$1.1) }
        .map(\.2)
}
```

Keep `rank`'s existing doc comment and add one sentence naming the fold rule.

- [ ] **Step 4: Run and see it pass, with the existing palette tests unchanged**

Run: `cd app && swift test --filter PaletteTests`
Expected: PASS, every existing test included. If an existing test fails because an empty query now changes order: `identifierFold("")` is empty and `folds` is false, so it must not — investigate rather than edit the old test.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Command/PaletteItem.swift app/Tests/WakilKitTests/PaletteTests.swift
git commit -m "2d-i: ⌘P/⌘K rank a folded prefix match first — \"pane move\" finds pane_move"
```

---

### Task 9: The window — send, the `RESOLVED` row, the rebuilt thread, wiring

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — init (line ~1528, add `vocabulary: VocabularyStore? = nil` before `environment:`), `forTesting` (line ~2030, add the same parameter and pass it), `refreshContext` (line ~2299), `invalidateForOrgChange` (line ~2436), `send` (line ~5413, before `harness.send(text)` at ~5550), `rebuiltThread` (line ~7125)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` — `WakilWiring` gains `public let vocabulary: VocabularyStore`, built in `build` after the registry and panes exist
- Modify: `app/Sources/WakilApp/WindowSession.swift:254` — pass `vocabulary: wiring.vocabulary`
- Test: `app/Tests/WakilKitTests/WindowIdentifierTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: the operator-visible behaviour in the spec's exit criterion.

- [ ] **Step 1: Write the failing tests.** Use `WindowModel.forTesting` with a recording `AgentHarness` fake — find the one `WindowModelTests.swift` uses to read what `send` passed (`grep -n "sentTexts\|func send(_ text" app/Tests/WakilKitTests/*.swift`) and reuse it.

```swift
import Foundation
import Testing
@testable import WakilKit

private func storeWith(_ names: [Identifier]) -> VocabularyStore {
    let source = /* FixedSource from VocabularyStoreTests — move it to a shared test-support file, `IdentifierTestSupport.swift`, rather than copying it */
    return VocabularyStore(live: [source(names)], cached: [], report: { _, _ in })
}

@Test @MainActor func aLooseIdentifierReachesTheAgentWithTheNoteAndTheThreadGetsOneRow() async throws {
    let harness = /* recording harness */
    let store = storeWith([Identifier(text: "transaction_read_only", kind: .column, origin: "staging · core db", source: .schema)])
    let model = WindowModel.forTesting(scratchRoot: /* temp dir */, harnessFactory: { _, _ in harness }, vocabulary: store)
    await store.contextChanged(/* the model's ActiveContext, or any with org "test-org" */)
    await model.send("what's in transaction read only")
    let sent = try #require(await harness.sentTexts.last)
    #expect(sent.hasPrefix("what's in transaction read only\n\n" + TurnNote.header))
    #expect(model.thoughts.contains { $0.label == "resolved" && $0.detail == "transaction read only → transaction_read_only" })
}

@Test @MainActor func aTurnWithNoIdentifierIsSentByteIdenticalWithNoRow() async throws {
    // same setup, send "hello there"
    // #expect(sent == "hello there"); #expect(!model.thoughts.contains { $0.label == "resolved" })
}

@Test @MainActor func aWindowWithNoStoreSendsUnchanged() async throws {
    // forTesting without `vocabulary:` — sent == typed, no row. Guards the default.
}

@Test @MainActor func aRebuiltTurnShowsTheTypedTextAndTheResolvedRow() async throws {
    // Seed `sessionRows`/the `session_read` reply (see how WindowModelTests drives `rebuiltThread`:
    // grep -n "rebuiltThread\|session_read" app/Tests/WakilKitTests/*.swift) with one user entry whose
    // text is "x\n\n" + TurnNote.render([…])!, and expect rows: ("you", "x") then ("resolved", "<row>").
}
```

Write each body in full when you implement it — the comments above name exactly what each asserts.

- [ ] **Step 2: Run and see them fail**

Run: `cd app && swift test --filter WindowIdentifierTests`
Expected: FAIL to compile — `extra argument 'vocabulary'`.

- [ ] **Step 3: Implement in `WindowModel.swift`.**

Add a stored property `private let vocabulary: VocabularyStore?`, the init parameter `vocabulary: VocabularyStore? = nil` (before `environment:`), and `self.vocabulary = vocabulary`. Add the same parameter to `forTesting` and pass it through.

At the end of `refreshContext`'s success path, after `rootPath = …`:

```swift
            await vocabulary?.contextChanged(active)
```

At the top of `invalidateForOrgChange`:

```swift
        // Invariant 4 for names: nothing of the old org resolves after this line.
        await vocabulary?.dropAll()
```

In `send`, replace `try await harness.send(text)` with:

```swift
            try await harness.send(await textWithIdentifierNote(text))
```

and add:

```swift
    /// 2d-i: the operator's text, unchanged, plus the hint when anything in
    /// it folds to a name in scope. Appends the `RESOLVED` row and journals
    /// the note whole; the row is one truncated line like every other.
    private func textWithIdentifierNote(_ text: String) async -> String {
        guard let vocabulary else { return text }
        let resolutions = IdentifierResolver.resolve(text, in: await vocabulary.current())
        guard let note = TurnNote.render(resolutions) else { return text }
        thoughts.append(ThoughtRow(id: nextThoughtId, label: "resolved", detail: TurnNote.row(resolutions), isError: false))
        nextThoughtId += 1
        try? await registry.journalIdentifierEvent(
            action: "identifiers_resolved", params: .object(["note": .string(note)]),
            environment: environment, outcome: "ok")
        return text + "\n\n" + note
    }
```

In `rebuiltThread`, replace the row-building loop body:

```swift
        for entry in thread.entries.suffix(Self.rebuiltThreadLimit) {
            var detail = entry.detail
            var resolvedRow: String?
            if entry.label == "you" { (detail, resolvedRow) = TurnNote.split(entry.detail) }
            rows.append(ThoughtRow(id: nextThoughtId, label: entry.label, detail: detail, isError: entry.isError))
            nextThoughtId += 1
            if let resolvedRow {
                rows.append(ThoughtRow(id: nextThoughtId, label: "resolved", detail: resolvedRow, isError: false))
                nextThoughtId += 1
            }
        }
```

- [ ] **Step 4: Run and see them pass**

Run: `cd app && swift test --filter 'WindowIdentifierTests|WindowModelTests'`
Expected: PASS, existing `WindowModelTests` unchanged.

- [ ] **Step 5: Wire production** — the step `wakil-never-wired-parameters` says gets skipped. In `AppWiring.swift`'s `build`, after the registry, panes and layout exist:

```swift
        let home = /* the same home the journal directory derives from in this function */
        var cachedSources: [any IdentifierSource] = [CodeSource(cacheDirectory: CodeSource.defaultCacheDirectory(home: home))]
        if let databaseClient { cachedSources.insert(SchemaSource(db: databaseClient), at: 0) }
        let journalRegistry = registry
        let vocabulary = VocabularyStore(
            live: [WakilSource(registry: registry), PaneSource(layout: layout, panes: panes)],
            cached: cachedSources,
            report: { source, message in
                try? await journalRegistry.journalIdentifierEvent(
                    action: "identifier_source_failed",
                    params: .object(["source": .string(source), "error": .string(message)]),
                    environment: "", outcome: "error")
            })
```

Add `vocabulary` to `WakilWiring` (property, init, and the `return WakilWiring(...)`). In `WindowSession.swift:254`, add `vocabulary: wiring.vocabulary,` to the `WindowModel(` call.

Then prove it is wired:

```bash
grep -n "vocabulary: wiring.vocabulary" app/Sources/WakilApp/WindowSession.swift
```
Expected: one line. Add an `AppWiringTests` assertion if that file has a test that builds a `WakilWiring` (it does: `AppWiringTests.swift`) — `#expect(await wiring.vocabulary.current().count >= 0)` is not enough; assert `WakilSource`'s action names resolve: after `contextChanged`, `current().names(folded: "panemove")` is non-empty.

- [ ] **Step 6: Run the touched suites**

Run: `cd app && swift test --filter 'WindowIdentifierTests|WindowModelTests|AppWiringTests|OrgSwitchTests'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/App/AppWiring.swift app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests/WindowIdentifierTests.swift app/Tests/WakilKitTests/IdentifierTestSupport.swift app/Tests/WakilKitTests/VocabularyStoreTests.swift app/Tests/WakilKitTests/AppWiringTests.swift
git commit -m "2d-i: the window sends the hint, shows a RESOLVED row, and drops names on an org switch"
```

---

### Task 10: The controller's gates

Not for a subagent (`subagents-never-run-long-gates`). The controller runs, in order:

- [ ] `make build` — Go binaries, so the Swift suite does not run against a stale `bin/` (`app-test-does-not-build-go`).
- [ ] `make test` — Go suite plus the charter word-count check. Expected: PASS.
- [ ] `make app-test` — whole Swift suite. Expected: PASS. A layout-persistence flake is #312/#344, not this branch; re-run once and cite the issue.
- [ ] Then the **Cover** rung: the e2e auditor (`docs/agents/e2e.md`) over this branch — the `RESOLVED` row, the send path, the org drop.

---

## Self-review

- **Spec coverage:** problem/goal → Tasks 3, 4, 9; the four sources → 5, 6; `list_columns` → 1; org boundary → 7, 9; failure → 5, 6, 7; fold matcher → 2, 3; note → 4; agent turn → 9; ⌘P/⌘K → 8; UI row and rebuilt thread → 4, 9; testing section → each task plus 10; exit criterion → walked after Cover. "Recorded, not built" needs no task.
- **Types:** `Identifier(text:kind:origin:source:)`, `Resolution(phrase:candidates:more:)`, `TurnNote.render/row/split`, `VocabularyStore.contextChanged/dropAll/current/waitForRebuild`, `journalIdentifierEvent(action:params:environment:outcome:)` — used with the same names in every task.
- **Placeholders left deliberately:** `ActiveContext` construction and the recording-harness fake are named by where to find them (`ContextStore.swift:128-185`, `WindowModelTests.swift`) because their exact initialisers must be read, not guessed. Task 9's last three tests name exactly what each asserts and how to drive it.
