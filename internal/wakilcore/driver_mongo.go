package wakilcore

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

func init() { RegisterDriver("mongo", mongoDriver{}) }

type mongoDriver struct{}

func (mongoDriver) Kind() string { return "mongo" }

func (mongoDriver) AssertReadOnly(spec QuerySpec) error { return AssertMongoReadOnly(spec.Raw) }

// Connect opens a MongoDB client for the given Connection.
//
// Read-only asymmetry with the other two drivers (documented here per
// resolution 7, since this is a real gap, not an oversight): the SQLite
// driver opens its database file with the SQLite-native mode=ro query
// parameter, and the MySQL driver sets transaction_read_only=1 on every
// pooled connection via the DSN — both are engine-level guarantees that
// hold even if AssertMongoReadOnly (or AssertSQLReadOnly) were somehow
// bypassed. MongoDB has no equivalent: there is no URI option, session
// flag, or client setting that makes a *mongo.Client itself refuse a
// write, so this function cannot set one. The only real, engine-level
// backstop available for Mongo is operational rather than something this
// driver can configure: the credentials in Connection.URL must name a
// database user that has been granted only the built-in "read" (or
// "readAnyDatabase") role on the target database. Provisioning such a
// least-privilege user is a deployment requirement for this driver, not
// an optional hardening step — without it, AssertMongoReadOnly is the
// only thing standing between a generated query and a real write, with no
// independent backstop if that gate is ever wrong.
func (mongoDriver) Connect(ctx context.Context, c Connection) (Conn, error) {
	dbName := databaseFromURI(c.URL)
	if dbName == "" {
		return nil, UserError("mongo connection URI must include a database name, e.g. mongodb://host/dbname")
	}
	cli, err := mongo.Connect(options.Client().ApplyURI(c.URL))
	if err != nil {
		return nil, UserError("cannot connect to mongo: " + redactURICredentials(err.Error(), c.URL))
	}
	if err := cli.Ping(ctx, nil); err != nil {
		_ = cli.Disconnect(context.Background())
		return nil, UserError("mongo unreachable: " + redactURICredentials(err.Error(), c.URL))
	}
	return &mongoConn{cli: cli, db: cli.Database(dbName)}, nil
}

// ConnectWritable and AssertMutation are both deferred. See mongoConn.Write
// for the reason — the dangerous input in a Mongo mutation is the filter,
// not the op, and deleteMany({}) passes any op-name allowlist.
//
// Failing at Connect rather than only at Write means an operator who
// configures a writeRef on a Mongo database is told so at the moment they
// try to use it, naming the limitation, rather than getting a connection
// that looks usable and refuses every statement.
func (mongoDriver) ConnectWritable(ctx context.Context, c Connection) (Conn, error) {
	return nil, UserError("mongo mutation is not implemented yet (Wakil writes to SQL databases only)")
}

func (mongoDriver) AssertMutation(spec QuerySpec) error {
	return UserError("mongo mutation is not implemented yet (Wakil writes to SQL databases only)")
}

type mongoConn struct {
	cli *mongo.Client
	db  *mongo.Database
}

func (m *mongoConn) Close() error { return m.cli.Disconnect(context.Background()) }

func (m *mongoConn) ListContainers(ctx context.Context) ([]Container, error) {
	names, err := m.db.ListCollectionNames(ctx, bson.D{})
	if err != nil {
		return nil, UserError("cannot list collections: " + err.Error())
	}
	var out []Container
	for _, n := range names {
		out = append(out, Container{Name: n, Kind: "collection"})
	}
	return out, nil
}

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

// Describe infers a schema from one sample document in the collection,
// since Mongo collections are schemaless. Per resolution 4, a genuinely
// empty collection (mongo.ErrNoDocuments) is the only case reported as an
// empty schema with a nil error; every other FindOne failure (e.g. an
// unreachable server, an auth failure) is surfaced as a UserError instead
// of being silently folded into "empty collection", which would otherwise
// make a broken connection indistinguishable from a collection with no
// documents.
func (m *mongoConn) Describe(ctx context.Context, name string) (Schema, error) {
	var doc map[string]any
	err := m.db.Collection(name).FindOne(ctx, bson.D{}).Decode(&doc)
	if err != nil {
		if errors.Is(err, mongo.ErrNoDocuments) {
			return Schema{}, nil
		}
		return Schema{}, UserError("cannot describe " + name + ": " + err.Error())
	}
	var sch Schema
	for k, v := range doc {
		sch.Columns = append(sch.Columns, Column{Name: k, Type: goType(v)})
	}
	return sch, nil
}

// PrimaryKey reports no key. Mongo's write path is unimplemented — Write
// refuses every statement — so a Mongo result is never editable, and
// "no key columns" is already exactly how that is expressed.
func (m *mongoConn) PrimaryKey(context.Context, string) ([]string, error) {
	return nil, nil
}

func (m *mongoConn) Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error) {
	q, err := validateMongoQuery(spec.Raw)
	if err != nil {
		return Rows{}, err
	}
	// clampReadLimit rather than a copy of its body. This was an inline
	// duplicate of that function until 2c-ii — the same two bounds and the
	// same 500 — which meant the cap had to be changed in two places and
	// would one day have been changed in one. TestMongoUsesTheSharedCap
	// pins the call.
	limit = clampReadLimit(limit)
	offset := spec.Offset
	if offset < 0 {
		offset = 0
	}
	start := time.Now()
	coll := m.db.Collection(q.Collection)

	var cursor *mongo.Cursor
	switch q.Op {
	case "find":
		filter, ferr := decodeMongoFilter(q.Filter)
		if ferr != nil {
			return Rows{}, ferr
		}
		// Push the limit server-side (limit+1, so an extra document
		// signals truncation) rather than decoding an unbounded result
		// set into memory and truncating afterward — an out-of-memory
		// risk against a large collection.
		findOpts := options.Find().SetLimit(int64(limit + 1))
		if offset > 0 {
			findOpts = findOpts.SetSkip(int64(offset))
		}
		if len(spec.Sort) > 0 {
			findOpts = findOpts.SetSort(sortDocument(spec.Sort))
		}
		cursor, err = coll.Find(ctx, filter, findOpts)
	case "aggregate":
		// Same server-side bound, applied by appending a $limit stage,
		// since aggregate has no equivalent SetLimit option.
		//
		// Sort, then skip, then limit — in that order, and the order is
		// not cosmetic. See appendSkipStage.
		pipeline := appendSortStage(q.Pipeline, spec.Sort)
		pipeline = appendSkipStage(pipeline, offset)
		pipeline = appendLimitStage(pipeline, limit+1)
		cursor, err = coll.Aggregate(ctx, pipeline)
	default:
		// This branch is reachable today, deterministically, for "count"
		// and "distinct": both are genuine read operations and so are
		// permitted by mongoReadOps (see readonly.go — that list is not
		// this task's to change), but this driver does not implement
		// either op yet. A caller therefore passes AssertMongoReadOnly
		// and only then hits this UserError at execution time. That is
		// a real, currently-true gap, not a hypothetical one guarding
		// against some future change to the allowlist — see
		// TestMongoReadRejectsUnimplementedReadOps, which pins exactly
		// this split. The message below is deliberately worded to be
		// distinguishable from a write-rejection: "not implemented yet"
		// tells the caller (including an LLM) this is a legitimate read
		// Wakil hasn't wired up, not a blocked write, so it knows not to
		// treat this the way it would treat a read-only-gate rejection.
		return Rows{}, UserError("mongo op " + q.Op + " is a read operation but is not implemented yet (only find and aggregate are supported)")
	}
	if err != nil {
		return Rows{}, UserError("mongo read failed: " + err.Error())
	}
	defer cursor.Close(ctx)

	var docs []map[string]any
	if err := cursor.All(ctx, &docs); err != nil {
		return Rows{}, UserError("mongo read failed: " + err.Error())
	}

	truncated := len(docs) > limit
	rows := docsToRows(docs, limit, time.Since(start).Milliseconds())
	rows.Truncated = truncated
	// Mongo has no unpageable read: skip and sort are options on a find
	// and stages in a pipeline, not syntax wrapped around a statement, so
	// nothing here can fail the way an EXPLAIN does on the SQL path.
	rows.Pageable = true
	return rows, nil
}

// ReadTable reads one collection whole. See Conn.ReadTable.
//
// An empty bson.D{} filter is Mongo's "everything", and the options are
// the same three Read composes. There is no name-quoting equivalent to
// worry about: a collection name is a value in the wire protocol, not
// text spliced into a statement.
func (m *mongoConn) ReadTable(
	ctx context.Context, name string, limit, offset int, sort []QuerySort,
) (Rows, error) {
	limit = clampReadLimit(limit)
	if offset < 0 {
		offset = 0
	}
	opts := options.Find().SetLimit(int64(limit + 1))
	if offset > 0 {
		opts = opts.SetSkip(int64(offset))
	}
	if len(sort) > 0 {
		opts = opts.SetSort(sortDocument(sort))
	}
	start := time.Now()
	cursor, err := m.db.Collection(name).Find(ctx, bson.D{}, opts)
	if err != nil {
		return Rows{}, UserError("cannot read " + name + ": " + err.Error())
	}
	defer cursor.Close(ctx)
	var docs []map[string]any
	if err := cursor.All(ctx, &docs); err != nil {
		return Rows{}, UserError("cannot read " + name + ": " + err.Error())
	}
	truncated := len(docs) > limit
	rows := docsToRows(docs, limit, time.Since(start).Milliseconds())
	rows.Truncated = truncated
	rows.Pageable = true
	return rows, nil
}

// Write is deferred, not refused, and the wording says so.
//
// Mongo mutation is out of Phase 2b-iii's scope for a reason worth keeping
// at the call site: the dangerous input is not the OP but the FILTER.
// Inverting AssertMongoReadOnly's allowlist would admit deleteMany({}) — a
// whole-collection wipe that passes any op-name check — so a Mongo write
// surface needs its own thinking about unbounded filters, about updateMany
// versus updateOne, and about $out/$merge. That thinking does not belong
// in the same phase as the gate itself.
//
// This is the same shape Read uses for "count" and "distinct" above:
// wording a caller can tell apart from a policy rejection, because
// reporting "Wakil refused this" when the truth is "Wakil cannot do this
// yet" would send the operator looking for a permission to grant.
func (m *mongoConn) Write(ctx context.Context, spec QuerySpec) (Written, error) {
	return Written{}, UserError("mongo mutation is not implemented yet (Wakil writes to SQL databases only)")
}

// decodeMongoFilter decodes a find spec's raw JSON filter into a document
// the driver accepts, defaulting to an empty document (matching
// everything) when no filter was supplied at all.
func decodeMongoFilter(raw json.RawMessage) (any, error) {
	if len(raw) == 0 {
		return bson.D{}, nil
	}
	var filter map[string]any
	if err := json.Unmarshal(raw, &filter); err != nil {
		return nil, UserError("invalid mongo filter JSON: " + err.Error())
	}
	return filter, nil
}

// appendLimitStage returns a copy of pipeline with a trailing {"$limit":
// n} stage, without mutating the caller's slice (which is also the
// already gate-checked mongoSpec.Pipeline).
func appendLimitStage(pipeline []map[string]any, n int) []map[string]any {
	out := make([]map[string]any, len(pipeline), len(pipeline)+1)
	copy(out, pipeline)
	return append(out, map[string]any{"$limit": n})
}

// appendSkipStage adds a $skip stage, or nothing at all when n is zero or
// negative.
//
// Callers MUST append skip before limit. The two are not commutative and
// the wrong order silently returns too few documents rather than failing:
// over 12 documents, $limit 4 then $skip 3 yields one document, because
// $limit runs first and leaves four to skip within. Measured in
// docs/wakil/phase-2c-ii-probe.md §2.
//
// Adding nothing at zero is the Mongo half of "page one is not wrapped":
// the pipeline a caller gets for the first page is exactly the pipeline
// every caller before 2c-ii got.
func appendSkipStage(pipeline []map[string]any, n int) []map[string]any {
	if n <= 0 {
		return pipeline
	}
	return append(append([]map[string]any{}, pipeline...), map[string]any{"$skip": n})
}

// sortDocument builds the ordered bson.D a $sort stage or SetSort call
// needs from a list of sort terms, in the order given.
//
// It returns a bson.D — an ORDERED slice — and not a map, on purpose. A Go
// map has undefined iteration order, so a two-key map would be marshalled
// with whichever column the runtime chose first, making the sort
// precedence vary between runs of the same query. With one key that was
// harmless, which is why every call site here was correct until a second
// term became expressible. All three of this driver's sort call sites
// (Read's find branch, ReadTable, and appendSortStage below) go through
// this one function so the ordering guarantee lives in exactly one place.
//
// 1 and -1 are Mongo's own spelling of ascending and descending; they are
// not interpolated from anything the caller controls, only chosen between.
func sortDocument(sort []QuerySort) bson.D {
	doc := make(bson.D, 0, len(sort))
	for _, term := range sort {
		dir := 1
		if term.Descending {
			dir = -1
		}
		doc = append(doc, bson.E{Key: term.Column, Value: dir})
	}
	return doc
}

// appendSortStage returns a copy of pipeline with a trailing {"$sort": ...}
// naming every term in order, or pipeline unchanged when sort is empty.
//
// The $sort value is the bson.D sortDocument builds — see its doc comment
// for why that must not be a map.
func appendSortStage(pipeline []map[string]any, sort []QuerySort) []map[string]any {
	if len(sort) == 0 {
		return pipeline
	}
	return append(append([]map[string]any{}, pipeline...),
		map[string]any{"$sort": sortDocument(sort)})
}
