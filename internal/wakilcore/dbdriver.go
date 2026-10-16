package wakilcore

import (
	"context"
	"fmt"
	"sync"
)

// Connection holds database connection parameters.
type Connection struct {
	Ref string
	// URL is a transient field carrying the resolved DSN with database password.
	// It must never be logged, marshaled, or returned to a tool caller.
	// Access it only internally to establish connections.
	URL      string `json:"-"`
	ReadOnly bool
	// Writable is whether this database has a write credential configured
	// at all — Database.WriteRef != "" — and it is ADVERTISEMENT, NEVER
	// PERMISSION.
	//
	// **No gate may ever branch on it.** That is the whole reason it is a
	// second field instead of ReadOnly gaining a meaning: ReadOnly was
	// demoted to a label (issue #14) exactly because a driver consulting a
	// config-supplied boolean turns the unconditional read-only gate into
	// a conditional one. Writable is subject to the same prohibition. The
	// only thing entitled to read it is code deciding whether to OFFER an
	// edit; whether one is allowed remains OpenDatabaseWritable's answer,
	// and it re-derives it from configuration rather than trusting this.
	//
	// It exists because a read had no way to know its own database could
	// not be written. describeEditability answers a structural question —
	// one table, a primary key, that key in the result — and happily said
	// "editable" for a database with no write credential, so the pane's
	// footer said editable, the editor opened, and the refusal arrived
	// only when Enter was pressed.
	Writable bool
}

// String returns a redacted string representation of the Connection.
// It includes the Ref and ReadOnly flag but redacts the URL to prevent
// accidental leakage of database credentials.
func (c Connection) String() string {
	return fmt.Sprintf("Connection{Ref:%q, ReadOnly:%v, URL:[redacted]}", c.Ref, c.ReadOnly)
}

type Container struct {
	Name string `json:"name"`
	Kind string `json:"kind"` // "table" | "collection"
}

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

// ContainerList wraps a []Container so wakil-db's list_tables tool can
// return one.
//
// Same reason as DatabaseList (config.go): MCP requires a tool result's
// structuredContent to be a JSON OBJECT, the MCP SDK derives a tool's
// advertised outputSchema from its handler's typed Out, and a []Container
// Out therefore advertised a top-level
// {"items":…,"type":["null","array"]} and shipped a bare array. A
// validating client rejects that, which is why list_tables failed outright
// in the Phase 1 acceptance run. See internal/mcpx's ToolErr doc comment.
//
// The field is "containers", not "tables", because the payload is not
// always tables: Conn.ListContainers is the driver-neutral call, and the
// Mongo driver fills it with collections (Kind == "collection"). Naming
// the field after the tool would make a Mongo response read as a lie.
//
// No completeness signal is carried, and that is a decision rather than an
// omission: every Conn.ListContainers implementation (sqlconn.go for
// MySQL/SQLite, driver_mongo.go for Mongo) enumerates the server's full
// answer or returns an error — there is no LIMIT, no cursor page size and
// no client-side cap anywhere on that path — so a Truncated field could
// only ever be false and would falsely imply a check nobody makes.
type ContainerList struct {
	// Containers is never nil when built through NewContainerList, so an
	// empty database marshals to [] rather than null.
	Containers []Container `json:"containers"`
}

// NewContainerList builds a ContainerList with a guaranteed non-nil
// Containers slice. Pass nil (as the error paths do) to get
// {"containers":[]}.
func NewContainerList(containers []Container) ContainerList {
	if containers == nil {
		containers = []Container{}
	}
	return ContainerList{Containers: containers}
}

type Column struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Key  bool   `json:"key,omitempty"`
}

type Schema struct {
	Columns []Column `json:"columns"`
}

type Rows struct {
	Columns []string `json:"columns"`
	// ColumnTypes is the database's own name for each column's type,
	// positionally aligned with Columns, or empty when the driver could not
	// say. The slice is either empty or exactly len(Columns) long: a driver
	// either answers for every column or answers for none, because a
	// positionally aligned slice that is SHORT annotates the wrong columns.
	//
	// An individual entry may still be "", meaning "no type for this
	// column", and a reader must treat that as no annotation rather than as
	// a type named by the empty string. The Mongo driver is where that
	// happens: it infers types from the documents it decoded (see
	// docsToRows), and an all-NULL column has no evidence in it, so it
	// reports "" for that one column and a real type for the rest. That is
	// the honest answer — naming a type there would be exactly the guess
	// ColumnTypesInferred exists to keep visible — and it is why the rule is
	// about the slice's LENGTH and not about every entry being filled in.
	// This comment previously said "never partially filled", which the
	// Mongo path had never satisfied; the readers were always right (Swift's
	// PaneColumn maps "" to nil so no annotation is drawn), and it was the
	// comment that was wrong.
	//
	// Inferring these from the values on screen was considered and rejected
	// for the SQL drivers, which have a declared schema to ask: inference is
	// wrong for an empty result, wrong for an all-NULL column, and wrong for
	// a column whose first 500 rows happen to be integers. Mongo has no
	// schema to ask, so it infers and says so through ColumnTypesInferred
	// rather than presenting a guess as a declaration.
	ColumnTypes []string `json:"columnTypes"`
	// ColumnTypesInferred is true when ColumnTypes was worked out from the
	// values rather than declared by the engine. Only the Mongo driver sets
	// it, because Mongo has no schema to ask. It exists for the same reason
	// Truncated does: so a caller can tell a fact from a guess instead of
	// reading both as facts.
	ColumnTypesInferred bool `json:"columnTypesInferred"`
	// Rows is the result's rows, and it is NEVER nil on a successful read:
	// a query that matched nothing carries an EMPTY slice, not a missing
	// one. Same rule as Pageable's below, for the same reader — a nil slice
	// marshals to `null`, and `null` is not how anything spells "zero
	// rows", it is how it spells "no answer". An agent that read
	// `"rows": null` off a genuinely empty table concluded the read had
	// failed and retried it six times through three different tools before
	// reporting the table as unreadable; nothing had failed.
	//
	// Enforced at both builders (collectRows, docsToRows) rather than at
	// the marshalling boundary, because there are three drivers and only
	// two places rows are assembled. Columns above carries the same
	// guarantee: an empty result still knows its shape.
	Rows   [][]any `json:"rows"`
	Millis int64   `json:"millis"`
	// Truncated is true when more rows matched the query than were
	// returned, so a caller (in particular, an LLM) can distinguish a
	// complete result from a partial one instead of reporting a partial
	// answer as the whole answer.
	Truncated bool `json:"truncated,omitempty"`
	// Pageable is whether this result can be asked for a second page at
	// all. False for an EXPLAIN and for a SHOW — both reads the gate
	// permits and neither one able to survive the subquery Wakil pages
	// with (SQLReadIsPageable). It is reported rather than inferred so a
	// caller can omit the page control instead of offering one that
	// returns a syntax error.
	//
	// No `omitempty`: false is the answer that matters, and a reader
	// (including an LLM) must not have to tell "cannot be paged" apart
	// from "this server is too old to say".
	Pageable bool `json:"pageable"`
	// ListsTables is whether THIS RESULT's rows name tables in this
	// connection's database, so a caller can offer a drill without
	// inferring one from the shape of the rows. True for SHOW TABLES;
	// false for everything else, Mongo included.
	//
	// No `omitempty`, for Pageable's reason: false is the answer that
	// matters, and a reader must not have to tell "these are not tables"
	// apart from "this server is too old to say".
	//
	// This field describes only a real Rows value — a SQL/Mongo read that
	// actually ran. It says nothing about a schema-browse pane (Wakil's
	// `.tables`/`.columns`): ListContainers, not a query, answers those,
	// so no Rows and no ListsTables value exists for them at all (final
	// review, Minor 5). Wakil's own Swift layer (`PaneStore`/`PaneTable`)
	// records a `listsTables` of its own for a schema-browse pane,
	// independently of this field and its zero value.
	ListsTables bool `json:"listsTables"`
	// Editable is nil unless this result's rows can each be named by a
	// WHERE clause. See the type.
	Editable *Editable `json:"editable,omitempty"`
}

// Editable is what a result reports about being written back to.
//
// nil means "not editable", and that is the answer wherever a single row
// cannot be named: a join, an aggregate, a view, a keyless table, a
// derived column, or a SELECT that omitted the key. A result grid holds
// the rows of a QUERY, not the rows of a TABLE, and inventing a WHERE
// clause for one is how a tool updates the wrong row — or every row.
type Editable struct {
	// Table is the single unqualified table the rows came from.
	Table string `json:"table"`
	// KeyColumns is its primary key, in the engine's key order.
	KeyColumns []string `json:"keyColumns"`
	// RowKeys is positionally aligned with Rows.Rows: the rendered,
	// dialect-escaped WHERE predicate naming that one row.
	//
	// **Rendered HERE, at read time, from the values the engine
	// returned** — which is the whole answer to a problem one layer up.
	// Swift's JSONValue held numbers as Double, so a key above 2^53
	// arrived rounded and an UPDATE composed from it named a different
	// row. A predicate is text; it crosses unchanged.
	//
	// It also describes the row AS IT WAS READ. If someone else changed
	// that row in between, the UPDATE matches nothing and says so, rather
	// than stamping over a change nobody saw.
	RowKeys []string `json:"rowKeys"`
	// Columns are the result columns that may be written to: every plain
	// reference to a column of Table, minus the key columns.
	//
	// Key columns are excluded deliberately. Changing a key is a
	// legitimate thing to want and a bad thing to do by double-click: it
	// changes the row's identity, which makes every RowKey the pane holds
	// — including the one the edit was composed from — describe a row that
	// no longer exists. The query line remains its route.
	Columns []string `json:"columns"`
}

// Written is what a mutation reports back: how many rows it changed and
// how long it took. It is deliberately not a Rows — a mutation returns no
// columns and no rows, and projecting a row count into a rows grid would
// put a fabricated shape on a surface Invariant 3 promises reflects what
// is actually on screen.
//
// RowsAffectedKnown exists for the same reason Rows.Truncated does: to let
// a caller tell "zero rows changed" apart from "the driver did not say".
// database/sql's Result.RowsAffected is documented as optional and returns
// an error on drivers that do not support it. Both drivers Wakil ships
// today (go-sql-driver/mysql, modernc.org/sqlite) do support it, so the
// false case is not expected to be reachable in practice — but a silent 0
// would be a lie in the one case it is, and the honest alternative costs
// one bool.
type Written struct {
	RowsAffected      int64 `json:"rowsAffected"`
	RowsAffectedKnown bool  `json:"rowsAffectedKnown"`
	Millis            int64 `json:"millis"`
}

// QuerySort is one pushed ORDER BY term: the column to order by and which
// way. QuerySpec.Sort holds these in a slice, in the order they apply —
// see the doc there for why a slice and not one term.
type QuerySort struct {
	Column     string
	Descending bool
}

type QuerySpec struct {
	Raw string
	// Offset is how many rows to skip before the first one returned.
	// Zero is page one and is the only value any caller passed before
	// 2c-ii, so a zero-valued QuerySpec behaves exactly as it always did.
	Offset int
	// Sort, when non-empty, is pushed into the statement as an ORDER BY
	// whose terms appear in exactly this order — index 0 is the primary
	// key, index 1 breaks its ties, and so on.
	//
	// A slice rather than a pointer to one term: an operator who sorts by
	// a second column has not replaced the first, they have refined it,
	// and a driver told only about the second would silently discard the
	// refinement it was asked for. Nil and empty both mean "no sort";
	// callers must not have to tell them apart.
	Sort []QuerySort
}

type Conn interface {
	ListContainers(ctx context.Context) ([]Container, error)
	Describe(ctx context.Context, name string) (Schema, error)
	// ListColumns returns every table's column names in one read, for
	// 2d-i's identifier vocabulary. Read-only.
	ListColumns(ctx context.Context) ([]TableColumns, error)
	Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error)
	// ReadTable returns rows from one named table or collection, paged and
	// optionally sorted, WITHOUT the caller composing a statement.
	//
	// It is not a convenience wrapper over Read and cannot be one. "Show
	// me everything in events" is SELECT * FROM "events" on SQLite,
	// backtick-quoted on MySQL, and on Mongo it is not SQL at all —
	// validateMongoQuery wants {"op":"find","collection":"events"}. A
	// caller that composed the statement itself would have to know the
	// dialect, which is exactly what Describe already establishes is the
	// driver's job, and which is also where quoteIdent lives.
	//
	// A result from here is always Pageable: Wakil composed the statement,
	// so there is no operator text that might not survive a wrap.
	ReadTable(ctx context.Context, name string, limit, offset int, sort []QuerySort) (Rows, error)
	// PrimaryKey reports a table's primary-key columns, in the order the
	// engine reports them for the key — which is NOT declaration order:
	// PRIMARY KEY (b, a) on a table declared (a, b, c) reports b first,
	// measured on both engines.
	//
	// An empty result and a nil error mean "this has no primary key", and
	// that is the answer for a keyless table, for a view, and for a table
	// that does not exist. A missing table is Describe's failure to
	// report, not this one's; answering "no key" for one costs nothing,
	// because "no key" already means "not editable".
	//
	// A UNIQUE NOT NULL column is not a primary key and is not reported.
	// It would identify a row just as well; Decision 20 says primary key,
	// and the gap is deliberate.
	PrimaryKey(ctx context.Context, table string) ([]string, error)
	// Write executes one mutating statement. A Conn obtained from
	// DbDriver.Connect ALWAYS fails this call; only one obtained from
	// DbDriver.ConnectWritable can succeed. See spec §4 — the asymmetry
	// runs one way: a write connection can still Read, because refusing
	// that would force a second connection to be opened just to show the
	// operator which rows a DELETE is about to remove.
	Write(ctx context.Context, spec QuerySpec) (Written, error)
	Close() error
}

type DbDriver interface {
	Kind() string
	// Connect opens a READ-ONLY connection. Unchanged by Phase 2b-iii,
	// and deliberately so: it takes no mode parameter, so no caller can
	// ask it for a writable connection and no bug in a flag's plumbing
	// can turn one into one. See spec §2.
	Connect(ctx context.Context, conn Connection) (Conn, error)
	// ConnectWritable opens a connection whose Write can succeed. It is a
	// separate method rather than Connect(readOnly bool) precisely so that
	// a bug here produces a broken WRITE and never a loosened read.
	ConnectWritable(ctx context.Context, conn Connection) (Conn, error)
	AssertReadOnly(spec QuerySpec) error
	AssertMutation(spec QuerySpec) error
}

// Package-level registry protected by RWMutex
var (
	driversMutex sync.RWMutex
	drivers      = map[string]DbDriver{}
)

// RegisterDriver registers a DbDriver for the given kind.
// Panics if a driver is already registered for that kind.
func RegisterDriver(kind string, d DbDriver) {
	driversMutex.Lock()
	defer driversMutex.Unlock()

	if _, exists := drivers[kind]; exists {
		panic(fmt.Sprintf("driver already registered for kind: %s", kind))
	}
	drivers[kind] = d
}

// GetDriver retrieves a registered DbDriver by kind.
// Returns a UserError if no driver is found.
func GetDriver(kind string) (DbDriver, error) {
	driversMutex.RLock()
	defer driversMutex.RUnlock()

	d, ok := drivers[kind]
	if !ok {
		return nil, UserError("no driver for database kind: " + kind)
	}
	return d, nil
}
