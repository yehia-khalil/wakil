package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type dbArg struct {
	Database string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
}

// listDatabasesArg is deliberately empty: list_databases takes no
// parameters — it always lists every database in the active environment.
// Reusing dbArg here would advertise a "database" input property that the
// handler silently ignores, which is misleading to a caller trying to
// filter the list.
type listDatabasesArg struct{}

type tableArg struct {
	Database string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Name     string `json:"name" jsonschema:"table or collection name"`
}
type queryArg struct {
	Database string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Query    string `json:"query" jsonschema:"SQL string, or a Mongo JSON spec {collection,op,filter|pipeline}"`
	Limit    int    `json:"limit,omitempty" jsonschema:"maximum rows to return"`
	Offset   int    `json:"offset,omitempty" jsonschema:"rows to skip before the first one returned; 0 is the first page. Only SELECT and WITH results can be paged - the pageable field in the result says whether this one can"`
	// Sort is the ORDER BY, in precedence order: index 0 is the primary
	// key and later terms break its ties. Pushed into the statement rather
	// than applied to the rows afterwards, so a sort over a truncated
	// result orders everything that matches.
	Sort []sortArg `json:"sort,omitempty" jsonschema:"order the result by these columns, in precedence order"`
}

type readTableArg struct {
	Database string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Name     string `json:"name" jsonschema:"table or collection name"`
	Limit    int    `json:"limit,omitempty" jsonschema:"maximum rows to return"`
	Offset   int    `json:"offset,omitempty" jsonschema:"rows to skip before the first one returned; 0 is the first page"`
	// Sort is the ORDER BY, in precedence order: index 0 is the primary
	// key and later terms break its ties. Pushed into the statement rather
	// than applied to the rows afterwards, so a sort over a truncated
	// result orders everything that matches.
	Sort []sortArg `json:"sort,omitempty" jsonschema:"order the result by these columns, in precedence order"`
}

type classifyArg struct {
	Database  string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Statement string `json:"statement" jsonschema:"the SQL or Mongo JSON to judge; it is NOT run"`
}

// sortArg is one ORDER BY term as it crosses the wire.
type sortArg struct {
	Column     string `json:"column" jsonschema:"the column to order by"`
	Descending bool   `json:"descending,omitempty" jsonschema:"order descending instead of ascending"`
}

func (s sortArg) spec() wakilcore.QuerySort {
	return wakilcore.QuerySort{Column: s.Column, Descending: s.Descending}
}

// sortSpecs turns the wire's list of sort terms into the driver's
// []QuerySort, preserving order (index 0 is the primary key, later terms
// break its ties). An empty or nil args is "no sort" and becomes nil
// rather than an empty non-nil slice, matching QuerySpec.Sort/ReadTable's
// own "nil/empty means no ORDER BY" contract.
func sortSpecs(args []sortArg) []wakilcore.QuerySort {
	if len(args) == 0 {
		return nil
	}
	out := make([]wakilcore.QuerySort, 0, len(args))
	for _, a := range args {
		out = append(out, a.spec())
	}
	return out
}

type mutateArg struct {
	Database  string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Statement string `json:"statement" jsonschema:"one INSERT, UPDATE or DELETE statement; schema changes are refused"`
}

type renderUpdateArg struct {
	Database string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	// Table, RowKey and Column must all come from the SAME result's
	// editable block (editable.table, editable.rowKeys, editable.columns).
	// RenderUpdate cross-checks none of this — it composes whatever it is
	// given — so a rowKey lifted from one result and paired with a table
	// or column from another composes a well-formed UPDATE against the
	// wrong table's row.
	Table      string `json:"table" jsonschema:"the table to update — must be editable.table from the SAME result rowKey and column came from"`
	RowKey     string `json:"rowKey" jsonschema:"the WHERE-clause predicate naming one row, taken VERBATIM from a query or read_table result's editable.rowKeys — it is the driver's own rendering of that row's key, and composing one yourself is how a tool updates the wrong row. Must come from the same result as table and column."`
	Column     string `json:"column" jsonschema:"the column being written — a name from that same result's editable.columns"`
	ColumnType string `json:"columnType,omitempty" jsonschema:"the column's declared type, e.g. from describe_table; used to validate a numeric value and to refuse an uneditable type such as BIT"`
	// Value's "=" hazard is documented in full on the tool's Description
	// (see render_update's registration) because that is the one string an
	// LLM caller reliably reads; this tag repeats the load-bearing half of
	// it for a caller that only inspects the per-field schema.
	Value string `json:"value" jsonschema:"the new cell value, as literal text — UNLESS it begins with \"=\", in which case everything after it is raw SQL, NOT a value: a bare word there (e.g. \"=status\") is a column reference and silently copies that column (\"=NOW()\"/\"=NULL\" are the safe, intended use). A literal value that must itself start with \"=\" cannot be sent through this field; use the query line instead."`
}

// RenderedUpdate wraps the composed statement, for the reason
// ContainerList and DatabaseList wrap theirs: MCP requires a tool result's
// structuredContent to be a JSON OBJECT.
type RenderedUpdate struct {
	Statement string `json:"statement"`
}

// openPicked resolves the active environment, picks the named database
// (or the environment's sole database when name is empty), and opens a
// read-only connection to it. Every step here can fail before ever
// touching the Keychain or a network socket — ResolveEnvironment and
// PickDatabase are pure configuration lookups — so a bad or ambiguous
// name is reported without any side effect.
func openPicked(ctx context.Context, name string) (wakilcore.Conn, error) {
	env, err := wakilcore.ResolveEnvironment()
	if err != nil {
		return nil, err
	}
	db, err := wakilcore.PickDatabase(env, name)
	if err != nil {
		return nil, err
	}
	return wakilcore.OpenDatabase(ctx, db)
}

// openPickedWritable is openPicked's write-path sibling. It differs in one
// call — OpenDatabaseWritable rather than OpenDatabase — and that call is
// what selects the separate write credential and the separate connection
// path. Written out rather than parameterised for the same reason
// ConnectWritable is a separate method: a shared opener with a mode
// argument would put the read path at the mercy of an argument.
func openPickedWritable(ctx context.Context, name string) (wakilcore.Conn, error) {
	env, err := wakilcore.ResolveEnvironment()
	if err != nil {
		return nil, err
	}
	db, err := wakilcore.PickDatabase(env, name)
	if err != nil {
		return nil, err
	}
	return wakilcore.OpenDatabaseWritable(ctx, db)
}

// newServer builds the wakil-db MCP server with all nine tools registered:
// list_databases, list_tables, describe_table, list_columns, query, mutate, read_table,
// classify_statement and render_update. Extracted from main so it (and the
// tools it wires up) is reachable from tests.
//
// mutate and render_update are the two of the nine that reach the WRITE
// credential (Database.WriteRef) and connection (OpenDatabaseWritable/
// ConnectWritable): render_update needs it too, even though it runs
// nothing, because the escaping it composes depends on the write
// connection's own sql_mode (see sqlConn.backslashEscapes and the comment
// at render_update's registration, below). Of the other seven, five —
// list_tables, describe_table, list_columns, query and read_table — go through
// openPicked/OpenDatabase; list_databases opens no connection because it
// only reads the active environment's configuration, and
// classify_statement opens none because it answers from the gates
// themselves.
func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-db", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "list_databases", Description: "List the named database connections in the active environment, under a databases key. Each entry carries its name, its driver, and writable: whether that database is configured for writing at all. writable false means no mutation can run against it by any route — not by you, not by the operator — and writable true means only that a mutation is possible, never that it is permitted: it still passes the write gate and, outside production, a human confirmation. The list is always complete — it is read whole from the active project's configuration, never paged or capped — so an empty databases array means the environment defines no databases."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ listDatabasesArg) (*mcp.CallToolResult, wakilcore.DatabaseList, error) {
			env, err := wakilcore.ResolveEnvironment()
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.NewDatabaseList(nil), nil
			}
			return nil, wakilcore.NewDatabaseList(env.Databases), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_tables", Description: "List tables/collections for a database connection, under a containers key. Each entry's kind says which it is (\"table\" for SQL, \"collection\" for Mongo). The list is always complete — the driver returns everything the server reports or fails — so an empty containers array means the database really is empty."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a dbArg) (*mcp.CallToolResult, wakilcore.ContainerList, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.NewContainerList(nil), nil
			}
			defer conn.Close()
			out, err := conn.ListContainers(ctx)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.NewContainerList(nil), nil
			}
			return nil, wakilcore.NewContainerList(out), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "describe_table", Description: "Describe a table/collection: columns/types or inferred fields."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a tableArg) (*mcp.CallToolResult, wakilcore.Schema, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Schema{}, nil
			}
			defer conn.Close()
			out, err := conn.Describe(ctx, a.Name)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Schema{}, nil
			}
			return nil, out, nil
		})

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

	mcp.AddTool(s, &mcp.Tool{Name: "query", Description: "Run a read-only query and return rows. SQL string or Mongo JSON spec. Use offset to ask for a later page of the SAME query and sort to order the whole result before it is paged — both re-run the query against the engine, so what comes back is a page of the real ordering rather than a re-shuffle of the rows you already had. sort is a list of {column, descending} terms in precedence order: a second term breaks ties left by the first. The pageable field says whether this particular result can be paged at all: an EXPLAIN or a SHOW cannot, because paging wraps the statement in a subquery and those two do not survive it. An empty rows array means the query really matched no rows — rows is never absent on a result that came back, so an empty one is an answer, not a missing answer, and re-running the same read will not produce different rows."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a queryArg) (*mcp.CallToolResult, wakilcore.Rows, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Rows{}, nil
			}
			defer conn.Close()
			out, err := conn.Read(ctx, wakilcore.QuerySpec{
				Raw:    a.Query,
				Offset: a.Offset,
				Sort:   sortSpecs(a.Sort),
			}, a.Limit)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Rows{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "mutate", Description: "Run ONE INSERT, UPDATE or DELETE against the active environment's database and report how many rows changed. Schema changes (CREATE/DROP/ALTER/TRUNCATE/RENAME/GRANT) are refused, as are multiple statements. The database must have a writeRef configured or this fails without connecting. Mongo databases are not supported yet. The rowsAffectedKnown field says whether rowsAffected is a real count: false means the driver did not report one, NOT that zero rows changed."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a mutateArg) (*mcp.CallToolResult, wakilcore.Written, error) {
			conn, err := openPickedWritable(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Written{}, nil
			}
			defer conn.Close()
			out, err := conn.Write(ctx, wakilcore.QuerySpec{Raw: a.Statement})
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Written{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "read_table", Description: "Return rows from one table or collection by name, without composing a query. Use this instead of writing \"SELECT * FROM x\" yourself: the driver renders it for its own dialect, which is the only form that also works against Mongo, where there is no SQL. Pages and sorts exactly as query does, and the result is always pageable. An empty rows array means the table really is empty — the columns are still reported, so a result with columns and no rows is a complete answer about a table that has none, not a read that failed."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a readTableArg) (*mcp.CallToolResult, wakilcore.Rows, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Rows{}, nil
			}
			defer conn.Close()
			out, err := conn.ReadTable(ctx, a.Name, a.Limit, a.Offset,
				sortSpecs(a.Sort))
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Rows{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "render_update", Description: "Compose the UPDATE that writes one cell back, and return it WITHOUT running it. table, rowKey and column must all come from the SAME result's editable block — editable.table, that row's own entry in editable.rowKeys, and a name from editable.columns — never assembled by hand or mixed from two different results: RenderUpdate cross-checks none of this, so a rowKey paired with the wrong table composes a well-formed UPDATE against that other table's row. value is a literal UNLESS it begins with \"=\", in which case everything after the \"=\" is raw SQL, NOT a value — a bare word there (e.g. \"=status\") is a COLUMN REFERENCE, and the statement silently copies that column's value with no error (\"=NOW()\" and \"=NULL\" are the safe, intended use of this escape). A literal value that must itself begin with \"=\" cannot be expressed through this tool at all; use the query line instead. Every ordinary literal is quoted and escaped for the dialect, and a value for a numeric column must parse as a number. The database must have a writeRef configured or this fails without connecting. This runs nothing: pass the statement it returns to mutate, which still requires the write gate and a human confirmation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a renderUpdateArg) (*mcp.CallToolResult, RenderedUpdate, error) {
			// Writable, because the escaping depends on the WRITE
			// connection's own sql_mode (see sqlConn.backslashEscapes) —
			// composing against the read connection's could quote a
			// backslash for the wrong mode and silently store the wrong
			// value.
			conn, err := openPickedWritable(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), RenderedUpdate{}, nil
			}
			defer conn.Close()
			sc, ok := conn.(interface {
				RenderUpdate(table, rowKey, column, columnType, value string) (string, error)
			})
			if !ok {
				return mcpx.ToolErr("wakil-db",
						wakilcore.UserError("this database cannot compose an update")),
					RenderedUpdate{}, nil
			}
			statement, err := sc.RenderUpdate(a.Table, a.RowKey, a.Column, a.ColumnType, a.Value)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), RenderedUpdate{}, nil
			}
			return nil, RenderedUpdate{Statement: statement}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "classify_statement", Description: "Say whether a statement is a read, a mutation, or neither — WITHOUT running it and without opening a connection. kind is \"read\", \"mutation\" or \"neither\"; for \"neither\", reason carries the gate's own sentence explaining why. The answer comes from the same gates that will judge the statement if it is run, so it is not a second opinion. Use it to decide which tool to call, never as permission: a mutation still passes the write gate and a human confirmation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a classifyArg) (*mcp.CallToolResult, wakilcore.StatementClass, error) {
			// Resolution only — no connection, no Keychain. PickDatabase
			// is a pure configuration lookup, and the driver kind is all
			// ClassifyStatement needs.
			env, err := wakilcore.ResolveEnvironment()
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.StatementClass{}, nil
			}
			db, err := wakilcore.PickDatabase(env, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.StatementClass{}, nil
			}
			return nil, wakilcore.ClassifyStatement(db.Driver, a.Statement), nil
		})

	return s
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
