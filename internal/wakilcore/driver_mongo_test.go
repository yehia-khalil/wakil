package wakilcore

import (
	"context"
	"net/url"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

// docker run -d --name wakil-mongo-test -p 27018:27017 mongo:7
// export WAKIL_MONGO_URI='mongodb://127.0.0.1:27018/app'
func TestMongoReadAndGate(t *testing.T) {
	uri := os.Getenv("WAKIL_MONGO_URI")
	if uri == "" {
		t.Skip("set WAKIL_MONGO_URI to run the Mongo driver test")
	}
	d, _ := GetDriver("mongo")
	conn, err := d.Connect(context.Background(), Connection{URL: uri})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, err = conn.Read(context.Background(),
		QuerySpec{Raw: `{"collection":"customers","op":"find","filter":{}}`}, 10)
	if err != nil {
		t.Fatalf("find failed: %v", err)
	}
	if err := d.AssertReadOnly(QuerySpec{Raw: `{"collection":"c","op":"deleteMany"}`}); err == nil {
		t.Fatal("must reject write")
	}
}

// mongoTestConn is a small helper shared by the live tests below: it skips
// unless WAKIL_MONGO_URI is set, connects through the real driver, and
// returns both the resulting Conn and the URI (the latter so a test can
// also call seedCollection, which needs to write and so cannot go through
// this read-only Conn).
func mongoTestConn(t *testing.T) (Conn, string) {
	t.Helper()
	uri := os.Getenv("WAKIL_MONGO_URI")
	if uri == "" {
		t.Skip("set WAKIL_MONGO_URI to run the Mongo driver test")
	}
	d, err := GetDriver("mongo")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: uri})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn, uri
}

// seedCollection drops and repopulates a collection with n documents,
// going straight at the raw Mongo driver rather than through Wakil's
// gated Conn (which is read-only by design and could not do this seeding
// itself).
func seedCollection(t *testing.T, uri, collection string, n int) {
	t.Helper()
	cli, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Disconnect(context.Background())

	coll := cli.Database(databaseFromURI(uri)).Collection(collection)
	if err := coll.Drop(context.Background()); err != nil {
		t.Fatal(err)
	}
	docs := make([]any, 0, n)
	for i := 0; i < n; i++ {
		docs = append(docs, bson.M{"seq": i, "name": "doc"})
	}
	if _, err := coll.InsertMany(context.Background(), docs); err != nil {
		t.Fatal(err)
	}
}

// TestMongoTruncation_Find proves resolution 5: the server-side limit is
// actually applied (not just docsToRows' post-hoc cut), and Truncated
// reports correctly both when more documents exist than the limit and
// when they don't.
func TestMongoTruncation_Find(t *testing.T) {
	conn, uri := mongoTestConn(t)
	seedCollection(t, uri, "truncate_find", 7)

	rows, err := conn.Read(context.Background(),
		QuerySpec{Raw: `{"collection":"truncate_find","op":"find","filter":{}}`}, 3)
	if err != nil {
		t.Fatalf("find failed: %v", err)
	}
	if !rows.Truncated {
		t.Error("expected Truncated=true when more docs exist than the limit")
	}
	if len(rows.Rows) != 3 {
		t.Errorf("expected exactly 3 rows, got %d", len(rows.Rows))
	}

	rows, err = conn.Read(context.Background(),
		QuerySpec{Raw: `{"collection":"truncate_find","op":"find","filter":{}}`}, 100)
	if err != nil {
		t.Fatalf("find failed: %v", err)
	}
	if rows.Truncated {
		t.Error("expected Truncated=false when the limit exceeds the doc count")
	}
	if len(rows.Rows) != 7 {
		t.Errorf("expected exactly 7 rows, got %d", len(rows.Rows))
	}
}

// TestMongoTruncation_Aggregate mirrors TestMongoTruncation_Find for the
// aggregate path, which has no SetLimit option and must instead get its
// bound from an appended $limit pipeline stage.
func TestMongoTruncation_Aggregate(t *testing.T) {
	conn, uri := mongoTestConn(t)
	seedCollection(t, uri, "truncate_agg", 7)

	rows, err := conn.Read(context.Background(),
		QuerySpec{Raw: `{"collection":"truncate_agg","op":"aggregate","pipeline":[{"$match":{}}]}`}, 3)
	if err != nil {
		t.Fatalf("aggregate failed: %v", err)
	}
	if !rows.Truncated {
		t.Error("expected Truncated=true when more docs exist than the limit")
	}
	if len(rows.Rows) != 3 {
		t.Errorf("expected exactly 3 rows, got %d", len(rows.Rows))
	}

	rows, err = conn.Read(context.Background(),
		QuerySpec{Raw: `{"collection":"truncate_agg","op":"aggregate","pipeline":[{"$match":{}}]}`}, 100)
	if err != nil {
		t.Fatalf("aggregate failed: %v", err)
	}
	if rows.Truncated {
		t.Error("expected Truncated=false when the limit exceeds the doc count")
	}
	if len(rows.Rows) != 7 {
		t.Errorf("expected exactly 7 rows, got %d", len(rows.Rows))
	}
}

// docSeqs extracts the "seq" field from each row of rows, in row order, so
// a paging test can assert exact document identity and order rather than
// a count — a count assertion passes even under a transposed skip/limit,
// which is exactly the bug this task's find-vs-aggregate divergence could
// hide.
func docSeqs(t *testing.T, rows Rows) []int {
	t.Helper()
	idx := -1
	for i, c := range rows.Columns {
		if c == "seq" {
			idx = i
			break
		}
	}
	if idx == -1 {
		t.Fatalf("no seq column in %v", rows.Columns)
	}
	out := make([]int, len(rows.Rows))
	for i, r := range rows.Rows {
		switch v := r[idx].(type) {
		case int32:
			out[i] = int(v)
		case int64:
			out[i] = int(v)
		case int:
			out[i] = v
		case float64:
			out[i] = int(v)
		default:
			t.Fatalf("seq value has unexpected type %T: %v", v, v)
		}
	}
	return out
}

// TestMongoPagingFind pages a 7-document find collection at page size 3 —
// a size that does not divide the document count evenly, so the last page
// is short. It asserts exact seq values on every page (not just counts),
// that the three pages partition the collection with no document seen
// twice and none skipped, and that Truncated is true on the two full
// pages and false on the last.
func TestMongoPagingFind(t *testing.T) {
	conn, uri := mongoTestConn(t)
	seedCollection(t, uri, "page_find", 7)

	read := func(offset int) Rows {
		rows, err := conn.Read(context.Background(),
			QuerySpec{Raw: `{"collection":"page_find","op":"find","filter":{}}`, Offset: offset}, 3)
		if err != nil {
			t.Fatalf("find failed at offset %d: %v", offset, err)
		}
		return rows
	}

	page1 := read(0)
	if got, want := docSeqs(t, page1), []int{0, 1, 2}; !intSlicesEqual(got, want) {
		t.Errorf("page 1: got %v, want %v", got, want)
	}
	if !page1.Truncated {
		t.Error("page 1: expected Truncated=true")
	}

	page2 := read(3)
	if got, want := docSeqs(t, page2), []int{3, 4, 5}; !intSlicesEqual(got, want) {
		t.Errorf("page 2: got %v, want %v", got, want)
	}
	if !page2.Truncated {
		t.Error("page 2: expected Truncated=true")
	}

	page3 := read(6)
	if got, want := docSeqs(t, page3), []int{6}; !intSlicesEqual(got, want) {
		t.Errorf("page 3: got %v, want %v", got, want)
	}
	if page3.Truncated {
		t.Error("page 3: expected Truncated=false")
	}

	seen := map[int]bool{}
	for _, seq := range append(append(docSeqs(t, page1), docSeqs(t, page2)...), docSeqs(t, page3)...) {
		if seen[seq] {
			t.Errorf("seq %d appeared on more than one page", seq)
		}
		seen[seq] = true
	}
	for i := 0; i < 7; i++ {
		if !seen[i] {
			t.Errorf("seq %d was never returned by any page", i)
		}
	}
}

// TestMongoPagingAggregate mirrors TestMongoPagingFind for the aggregate
// path, so the two ops are asserted to agree on paging the same way they
// already are for truncation.
func TestMongoPagingAggregate(t *testing.T) {
	conn, uri := mongoTestConn(t)
	seedCollection(t, uri, "page_agg", 7)

	read := func(offset int) Rows {
		rows, err := conn.Read(context.Background(),
			QuerySpec{Raw: `{"collection":"page_agg","op":"aggregate","pipeline":[{"$match":{}}]}`, Offset: offset}, 3)
		if err != nil {
			t.Fatalf("aggregate failed at offset %d: %v", offset, err)
		}
		return rows
	}

	page1 := read(0)
	if got, want := docSeqs(t, page1), []int{0, 1, 2}; !intSlicesEqual(got, want) {
		t.Errorf("page 1: got %v, want %v", got, want)
	}
	if !page1.Truncated {
		t.Error("page 1: expected Truncated=true")
	}

	page2 := read(3)
	if got, want := docSeqs(t, page2), []int{3, 4, 5}; !intSlicesEqual(got, want) {
		t.Errorf("page 2: got %v, want %v", got, want)
	}
	if !page2.Truncated {
		t.Error("page 2: expected Truncated=true")
	}

	page3 := read(6)
	if got, want := docSeqs(t, page3), []int{6}; !intSlicesEqual(got, want) {
		t.Errorf("page 3: got %v, want %v", got, want)
	}
	if page3.Truncated {
		t.Error("page 3: expected Truncated=false")
	}

	seen := map[int]bool{}
	for _, seq := range append(append(docSeqs(t, page1), docSeqs(t, page2)...), docSeqs(t, page3)...) {
		if seen[seq] {
			t.Errorf("seq %d appeared on more than one page", seq)
		}
		seen[seq] = true
	}
	for i := 0; i < 7; i++ {
		if !seen[i] {
			t.Errorf("seq %d was never returned by any page", i)
		}
	}
}

// intSlicesEqual compares two int slices element-by-element, in order —
// order matters here because a paging test is asserting document
// identity AND position, not just membership.
func intSlicesEqual(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestMongoSortAppliesToWholeCollectionThenSkip_Find proves the sort is
// pushed to the server and applied over the WHOLE collection before the
// offset is applied — not applied only within whatever page skip would
// otherwise land on. A descending sort by seq over 7 documents orders them
// 6,5,4,3,2,1,0; skipping 3 of that ordering and taking 3 more must yield
// 3,2,1 — not the result of skipping first and sorting only what's left.
func TestMongoSortAppliesToWholeCollectionThenSkip_Find(t *testing.T) {
	conn, uri := mongoTestConn(t)
	seedCollection(t, uri, "sort_find", 7)

	rows, err := conn.Read(context.Background(),
		QuerySpec{
			Raw:    `{"collection":"sort_find","op":"find","filter":{}}`,
			Offset: 3,
			Sort:   []QuerySort{{Column: "seq", Descending: true}},
		}, 3)
	if err != nil {
		t.Fatalf("find failed: %v", err)
	}
	if got, want := docSeqs(t, rows), []int{3, 2, 1}; !intSlicesEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// TestMongoSortAppliesToWholeCollectionThenSkip_Aggregate mirrors the find
// case above through the aggregate path, whose $sort/$skip/$limit stage
// order is exactly what appendSortStage/appendSkipStage/appendLimitStage
// compose.
func TestMongoSortAppliesToWholeCollectionThenSkip_Aggregate(t *testing.T) {
	conn, uri := mongoTestConn(t)
	seedCollection(t, uri, "sort_agg", 7)

	rows, err := conn.Read(context.Background(),
		QuerySpec{
			Raw:    `{"collection":"sort_agg","op":"aggregate","pipeline":[{"$match":{}}]}`,
			Offset: 3,
			Sort:   []QuerySort{{Column: "seq", Descending: true}},
		}, 3)
	if err != nil {
		t.Fatalf("aggregate failed: %v", err)
	}
	if got, want := docSeqs(t, rows), []int{3, 2, 1}; !intSlicesEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// TestMongoDescribe proves resolution 4: Describe works against a seeded
// collection, and a genuinely empty collection yields an empty schema
// with a nil error (not conflated with a describe failure).
func TestMongoDescribe(t *testing.T) {
	conn, uri := mongoTestConn(t)
	seedCollection(t, uri, "describe_me", 1)

	sch, err := conn.Describe(context.Background(), "describe_me")
	if err != nil {
		t.Fatalf("describe failed: %v", err)
	}
	if len(sch.Columns) == 0 {
		t.Fatalf("expected inferred columns, got %+v", sch)
	}

	sch, err = conn.Describe(context.Background(), "totally_empty_collection")
	if err != nil {
		t.Fatalf("describe of empty collection should not error: %v", err)
	}
	if len(sch.Columns) != 0 {
		t.Fatalf("expected empty schema for empty collection, got %+v", sch)
	}
}

// TestMongoEmptyDatabaseName proves resolution 6: a URI with no database
// path is rejected with a UserError before ever reaching
// cli.Database(""). This needs no live server (Connect checks the URI's
// path before dialing anything), so it runs unconditionally.
func TestMongoEmptyDatabaseName(t *testing.T) {
	d, err := GetDriver("mongo")
	if err != nil {
		t.Fatal(err)
	}
	for _, uri := range []string{
		"mongodb://127.0.0.1:27017",
		"mongodb://127.0.0.1:27017/",
	} {
		_, err := d.Connect(context.Background(), Connection{URL: uri})
		if err == nil {
			t.Fatalf("expected error for URI with no database name: %q", uri)
		}
		if _, ok := IsUserError(err); !ok {
			t.Fatalf("expected UserError for %q, got %T: %v", uri, err, err)
		}
	}
}

// TestMongoConnectRedactsPassword makes the URI sanitiser demonstrably
// FIRE. The previous version of this test could not fail: it used the
// password "s3cr3t-not-real" and asserted only that the message did not
// contain it, but the raw driver error on this path never did. Measured:
//
//	mongo.Connect -> nil (it only validates configuration)
//	cli.Ping      -> "server selection error: context deadline exceeded,
//	                  current topology: { Type: Unknown, Servers: [{ Addr:
//	                  127.0.0.1:1, ... connection refused }, ] }"
//	                                                  (contains pw: false)
//
// Deleting redactURICredentials therefore left the old assertions green.
//
// The password here is "127.0.0.1" instead, chosen because the topology
// error above quotes that exact string — a password is an arbitrary
// secret and nothing stops it coinciding with text the driver echoes,
// which is the whole reason the sanitiser exists. The "[redacted]"
// marker assertion is what gives this test the ability to fail; with the
// sanitiser removed, the address comes through raw and both assertions
// below break.
//
// The URI-level fallback inside redactURICredentials (replacing the whole
// connection string with "[redacted-uri]") is NOT exercised here: no
// observed driver error echoes the full URI, so there is nothing to make
// it fire without fabricating an error the driver cannot produce. It
// stays as documented defence in depth, not as covered code.
func TestMongoConnectRedactsPassword(t *testing.T) {
	d, err := GetDriver("mongo")
	if err != nil {
		t.Fatal(err)
	}
	const password = "127.0.0.1"
	uri := "mongodb://user:" + password + "@127.0.0.1:1/app?serverSelectionTimeoutMS=200&connectTimeoutMS=200"

	_, err = d.Connect(context.Background(), Connection{URL: uri})
	if err == nil {
		t.Fatal("expected an error connecting to an unreachable mongo URI")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "[redacted]") {
		t.Fatalf("the URI-credential sanitiser did not fire on the ping error: %q", msg)
	}
	if strings.Contains(msg, password) {
		t.Fatalf("error message leaked password: %q", msg)
	}
	if strings.Contains(msg, uri) {
		t.Fatalf("error message leaked full URI: %q", msg)
	}
}

// TestMongoReadRejectsUnimplementedReadOps pins a currently-true gap
// found in review: AssertMongoReadOnly permits "count" and "distinct"
// (they are genuine read operations, and mongoReadOps is not this task's
// to change), but mongoConn.Read implements only "find" and "aggregate".
// A caller issuing an ordinary, well-formed count/distinct spec today
// passes the gate and then deterministically hits Read's "not
// implemented yet" branch — this is not a hypothetical path guarding
// against some future allowlist change, it is reachable right now. This
// test states that split as an explicit contract, so a future task that
// implements count/distinct will see exactly what test needs updating.
//
// It needs no live server: mongo.Connect only validates configuration,
// not reachability (confirmed via `go doc go.mongodb.org/mongo-driver/v2/mongo.Connect`),
// and neither op reaches a network call — Read's switch hits the default
// branch and returns before any I/O — so this runs unconditionally
// alongside the other ungated tests.
func TestMongoReadRejectsUnimplementedReadOps(t *testing.T) {
	cli, err := mongo.Connect(options.Client().ApplyURI("mongodb://127.0.0.1:1/testdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Disconnect(context.Background())
	conn := &mongoConn{cli: cli, db: cli.Database("testdb")}

	specs := map[string]string{
		"count":    `{"collection":"u","op":"count"}`,
		"distinct": `{"collection":"u","op":"distinct","field":"x"}`,
	}
	for name, spec := range specs {
		t.Run(name, func(t *testing.T) {
			// The gate must allow it: this is a genuine read op.
			if err := AssertMongoReadOnly(spec); err != nil {
				t.Fatalf("gate should allow a genuine read op %q: %v", name, err)
			}
			// But Read must reject it, distinctly from a write rejection.
			_, err := conn.Read(context.Background(), QuerySpec{Raw: spec}, 10)
			if err == nil {
				t.Fatalf("expected Read to reject unimplemented op %q", name)
			}
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected UserError for %q, got %T: %v", name, err, err)
			}
			if strings.Contains(msg, "blocked") || strings.Contains(msg, "write") {
				t.Fatalf("message for an unimplemented read op should not read like a write rejection: %q", msg)
			}
			if !strings.Contains(msg, "not implemented") {
				t.Fatalf("expected message to say the op isn't implemented yet, got %q", msg)
			}
		})
	}
}

// Mongo mutation is deferred, not refused. The wording must read as "not
// implemented yet" so a caller (including an LLM) does not report it to the
// operator as a policy rejection. See spec §11.
func TestMongoWriteIsNotImplementedRatherThanRefused(t *testing.T) {
	m := &mongoConn{}
	_, err := m.Write(context.Background(), QuerySpec{Raw: `{"collection":"c","op":"insertOne"}`})
	if err == nil {
		t.Fatal("mongo Write must fail")
	}
	if !strings.Contains(err.Error(), "not implemented") {
		t.Errorf("message must say not implemented, got %q", err)
	}
}

func TestMongoConnectWritableIsNotImplemented(t *testing.T) {
	d, err := GetDriver("mongo")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.ConnectWritable(context.Background(), Connection{URL: "mongodb://127.0.0.1/db"}); err == nil {
		t.Fatal("mongo ConnectWritable must fail")
	} else if !strings.Contains(err.Error(), "not implemented") {
		t.Errorf("want not-implemented wording, got %q", err)
	}
	if err := d.AssertMutation(QuerySpec{Raw: `{"collection":"c","op":"insertOne"}`}); err == nil {
		t.Fatal("mongo AssertMutation must fail")
	} else if !strings.Contains(err.Error(), "not implemented") {
		t.Errorf("want not-implemented wording, got %q", err)
	}
}

func TestDocsToRowsInfersColumnTypes(t *testing.T) {
	docs := []map[string]any{
		{"_id": "abc", "name": "widgets", "qty": int32(4), "active": true},
		// A later document with a nil where an earlier one had a value must
		// not erase the type already established: a null is the absence of a
		// value, not evidence about the column.
		{"_id": "def", "name": nil, "qty": int32(9), "active": false},
	}
	got := docsToRows(docs, 10, 7)
	if !got.ColumnTypesInferred {
		t.Error("ColumnTypesInferred is false; Mongo has no schema to declare")
	}
	if len(got.ColumnTypes) != len(got.Columns) {
		t.Fatalf("ColumnTypes has %d entries for %d columns", len(got.ColumnTypes), len(got.Columns))
	}
	want := map[string]string{"_id": "string", "name": "string", "qty": "int", "active": "bool"}
	for i, c := range got.Columns {
		if got.ColumnTypes[i] != want[c] {
			t.Errorf("column %q: type %q, want %q", c, got.ColumnTypes[i], want[c])
		}
	}
}

func TestDocsToRowsReportsNoTypeForAnAllNullColumn(t *testing.T) {
	// An all-null column has no evidence in it. Reporting "string" here
	// because that is what a nil marshals to would be exactly the guess
	// ColumnTypesInferred exists to keep honest.
	got := docsToRows([]map[string]any{{"a": nil}, {"a": nil}}, 10, 0)
	if len(got.ColumnTypes) != 1 || got.ColumnTypes[0] != "" {
		t.Errorf("ColumnTypes = %v, want one empty entry", got.ColumnTypes)
	}
}

func TestDocsToRowsNamesAnArrayColumnArray(t *testing.T) {
	// bson.A, not []any: the v2 driver's type map decodes a BSON array into
	// bson.A, and a type switch on []any does not match a named type with
	// that underlying type. A test written against []any would pass while
	// every real Mongo array reported "bson.A".
	got := docsToRows([]map[string]any{{"tags": bson.A{"a", "b"}}}, 10, 0)
	if len(got.ColumnTypes) != 1 || got.ColumnTypes[0] != "array" {
		t.Errorf("ColumnTypes = %v, want [array]", got.ColumnTypes)
	}
}

func TestAppendSkipStageGoesBeforeTheLimit(t *testing.T) {
	// The order is load-bearing and the probe measured it: $limit then
	// $skip over 12 docs with limit 4 and skip 3 returns ONE document,
	// because $limit runs first and leaves only four to skip within.
	// $skip then $limit returns four. Callers must compose in that order,
	// and this test is what says so.
	pipeline := appendSkipStage([]map[string]any{{"$match": map[string]any{}}}, 3)
	pipeline = appendLimitStage(pipeline, 5)
	if len(pipeline) != 3 {
		t.Fatalf("want three stages, got %d: %v", len(pipeline), pipeline)
	}
	if _, ok := pipeline[1]["$skip"]; !ok {
		t.Fatalf("stage 1 must be $skip, got %v", pipeline[1])
	}
	if _, ok := pipeline[2]["$limit"]; !ok {
		t.Fatalf("stage 2 must be $limit, got %v", pipeline[2])
	}
}

func TestAppendSkipStageIsANoOpAtZero(t *testing.T) {
	// Page one must produce the exact pipeline every caller before 2c-ii
	// sent, for the same reason a SQL page one is not wrapped.
	base := []map[string]any{{"$match": map[string]any{}}}
	if got := appendSkipStage(base, 0); len(got) != 1 {
		t.Fatalf("a zero skip must add no stage, got %v", got)
	}
	if got := appendSkipStage(base, -4); len(got) != 1 {
		t.Fatalf("a negative skip must add no stage, got %v", got)
	}
}

func TestAppendSortStage(t *testing.T) {
	pipeline := appendSortStage([]map[string]any{{"$match": map[string]any{}}},
		[]QuerySort{{Column: "id", Descending: true}})
	if len(pipeline) != 2 {
		t.Fatalf("want two stages, got %v", pipeline)
	}
	// The $sort value must be a bson.D (ordered), not a map — see
	// TestSortStageIsOrdered for why a map here would be a flaky bug.
	doc, ok := pipeline[1]["$sort"].(bson.D)
	if !ok {
		t.Fatalf("stage 1 must be $sort as bson.D, got %T: %v", pipeline[1]["$sort"], pipeline[1])
	}
	if len(doc) != 1 || doc[0].Key != "id" || doc[0].Value != -1 {
		t.Fatalf("descending must be -1, got %v", doc)
	}
	asc := appendSortStage(nil, []QuerySort{{Column: "id"}})
	ascDoc := asc[0]["$sort"].(bson.D)
	if len(ascDoc) != 1 || ascDoc[0].Key != "id" || ascDoc[0].Value != 1 {
		t.Fatalf("ascending must be 1, got %v", ascDoc)
	}
	if got := appendSortStage([]map[string]any{{"$match": map[string]any{}}}, nil); len(got) != 1 {
		t.Fatalf("a nil sort must add no stage, got %v", got)
	}
}

// The $sort stage must be a bson.D, not a map. A Go map has undefined
// iteration order, so a two-key map would sort by whichever column the
// runtime happened to marshal first — differently between runs of the same
// query. This asserts the TYPE, because the ordering bug it prevents is
// not reliably reproducible.
func TestSortStageIsOrdered(t *testing.T) {
	pipeline := appendSortStage(nil, []QuerySort{
		{Column: "kind"},
		{Column: "id", Descending: true},
	})
	if len(pipeline) != 1 {
		t.Fatalf("stages = %d, want 1", len(pipeline))
	}
	doc, ok := pipeline[0]["$sort"].(bson.D)
	if !ok {
		t.Fatalf("$sort is %T, want bson.D — a map would sort in random order", pipeline[0]["$sort"])
	}
	want := bson.D{{Key: "kind", Value: 1}, {Key: "id", Value: -1}}
	if !reflect.DeepEqual(doc, want) {
		t.Fatalf("$sort = %v, want %v", doc, want)
	}
}

func TestMongoUsesTheSharedCap(t *testing.T) {
	// Not a behavioural test of Read — that needs a live server and lives
	// in the TestMongo* family make test-live runs. This pins the one
	// thing a unit test can pin: that the two clamps agree. If the inline
	// copy comes back and one of them is edited, this fails.
	for _, in := range []int{-1, 0, 1, 499, 500, 1000, 1001, 10_000_000} {
		if got, want := clampReadLimit(in), sharedCapForTest(in); got != want {
			t.Fatalf("clampReadLimit(%d) = %d, want %d", in, got, want)
		}
	}
}

// sharedCapForTest is the cap written out longhand, so the test states the
// contract rather than comparing the function to itself.
func sharedCapForTest(limit int) int {
	if limit <= 0 || limit > 1000 {
		return 500
	}
	return limit
}

// Measured 2026-10-13: Mongo ends an operation whose client went away. Pinned
// here so a driver upgrade that changes it is caught.
func TestMongoCancelledReadStopsOnTheServer(t *testing.T) {
	conn, _ := mongoTestConn(t)
	uri := os.Getenv("WAKIL_MONGO_URI")
	client, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect(context.Background())
	dbName := strings.TrimPrefix(mustParseURIPath(t, uri), "/")
	coll := client.Database(dbName).Collection("zz_cancel")
	_ = coll.Drop(context.Background())
	if _, err := coll.InsertMany(context.Background(), []any{bson.M{"a": 1}, bson.M{"a": 2}, bson.M{"a": 3}}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = coll.Drop(context.Background()) })

	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(500*time.Millisecond, cancel)
	q := `{"op":"find","collection":"zz_cancel","filter":{"$where":"sleep(5000) || true"}}`
	if _, err := conn.Read(ctx, QuerySpec{Raw: q}, 10); err == nil {
		t.Fatal("the read finished; it should have been cancelled")
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		var res bson.M
		err := client.Database("admin").RunCommand(context.Background(),
			bson.D{{Key: "currentOp", Value: 1}, {Key: "ns", Value: dbName + ".zz_cancel"}}).Decode(&res)
		if err != nil {
			t.Fatal(err)
		}
		if len(res["inprog"].(bson.A)) == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the $where sleep is still running on the server 5 s after the cancel")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func mustParseURIPath(t *testing.T, uri string) string {
	t.Helper()
	u, err := url.Parse(uri)
	if err != nil {
		t.Fatal(err)
	}
	return u.Path
}
