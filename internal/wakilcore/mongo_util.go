package wakilcore

import (
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
)

// databaseFromURI extracts the database name from a mongodb:// URI's path
// component (e.g. "mongodb://host/app" -> "app"). It returns "" both for a
// URI that fails to parse and for one with no path — mongoDriver.Connect
// treats an empty result as an error rather than ever calling
// cli.Database("").
func databaseFromURI(uri string) string {
	u, err := url.Parse(uri)
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(u.Path, "/")
}

// redactURICredentials removes both the password embedded in a mongodb://
// URI and the URI itself (as a fallback) from an error message before it
// is wrapped in a UserError. Connection.URL may carry a password (see
// dbdriver.go), and unlike go-sql-driver/mysql's mysql.Config, the Mongo
// driver exposes no parsed struct that separates the password out
// structurally — so this works from the raw URI string via net/url. Per
// resolution 8, the URI itself must never reach a UserError message or a
// log line.
func redactURICredentials(msg, uri string) string {
	if u, err := url.Parse(uri); err == nil {
		if pw, ok := u.User.Password(); ok && pw != "" {
			msg = strings.ReplaceAll(msg, pw, "[redacted]")
		}
	}
	// Defense in depth: if the driver's error text happens to echo the
	// whole connection string (not just the password), scrub that too.
	if uri != "" {
		msg = strings.ReplaceAll(msg, uri, "[redacted-uri]")
	}
	return msg
}

// goType reports the Go type driving BSON-to-Go decoding for a decoded
// document field, used as a stand-in "column type" for Describe since
// Mongo collections are schemaless and this is inferred from a sample
// document rather than declared anywhere.
func goType(v any) string { return fmt.Sprintf("%T", v) }

// inferMongoType names the type of a single decoded BSON value, or "" for
// a nil. The names are deliberately Mongo's vocabulary rather than Go's —
// this string is drawn in a column header for a human, and "primitive.M"
// would tell them nothing.
func inferMongoType(v any) string {
	switch v.(type) {
	case nil:
		return ""
	case bool:
		return "bool"
	case int32, int64, int:
		return "int"
	case float32, float64:
		return "double"
	case string:
		return "string"
	case time.Time:
		return "date"
	case []any, bson.A:
		return "array"
	default:
		// Everything else — embedded documents, ObjectIDs, Decimal128,
		// binary — is named by its own Go type rather than lumped into
		// "object". A wrong-looking name an operator can search for beats a
		// right-looking name that hides which of six things this is.
		return fmt.Sprintf("%T", v)
	}
}

// docsToRows flattens heterogeneous documents into a columnar shape using
// the union of top-level keys (sorted, _id first) so the MCP output
// matches the SQL drivers' Rows shape. It also caps the number of rows
// returned at limit, mirroring sqlConn.Read's own row cap; the caller is
// responsible for setting Rows.Truncated by comparing len(docs) to limit
// before this cut is applied.
func docsToRows(docs []map[string]any, limit int, millis int64) Rows {
	keySet := map[string]bool{}
	for _, d := range docs {
		for k := range d {
			keySet[k] = true
		}
	}
	// Empty, not nil — see Rows.Rows. Mongo is the driver that needs this
	// most: it derives its columns from the documents themselves, so zero
	// documents means both fields would otherwise marshal as `null`, and a
	// reader would have neither rows nor a shape to tell an empty
	// collection apart from a failed read.
	cols := []string{}
	for k := range keySet {
		if k != "_id" {
			cols = append(cols, k)
		}
	}
	sort.Strings(cols)
	if keySet["_id"] {
		cols = append([]string{"_id"}, cols...)
	}
	var out Rows
	out.Columns = cols
	out.Rows = [][]any{}
	out.Millis = millis
	// Mongo has no schema, so the type is whatever the documents show. The
	// FIRST non-nil value per column wins and later ones do not overwrite
	// it: a column that is int in one document and string in the next is a
	// real thing in Mongo, and picking the last would make the annotation
	// depend on scroll position.
	//
	// A column whose every value is nil keeps the zero value, "", which is
	// this slice's way of saying "no type for this column" — see
	// Rows.ColumnTypes, whose contract is that the slice is either empty or
	// len(Columns) long, not that every entry is filled in. Naming a type
	// for a column with no evidence in it would be exactly the guess
	// ColumnTypesInferred exists to keep visible, and the readers already
	// handle it (Swift's PaneColumn maps "" to nil, so nothing is drawn).
	// TestDocsToRowsReportsNoTypeForAnAllNullColumn pins it.
	types := make([]string, len(cols))
	for i, d := range docs {
		if i >= limit {
			break
		}
		row := make([]any, len(cols))
		for j, c := range cols {
			row[j] = d[c]
			if types[j] == "" {
				types[j] = inferMongoType(d[c])
			}
		}
		out.Rows = append(out.Rows, row)
	}
	out.ColumnTypes = types
	out.ColumnTypesInferred = true
	return out
}
