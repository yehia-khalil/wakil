package wakilcore

import (
	"strings"
	"testing"
)

func TestClassifyStatementSQL(t *testing.T) {
	for _, tc := range []struct {
		name string
		sql  string
		want string
	}{
		{"select", "SELECT id FROM events", "read"},
		{"cte", "WITH x AS (SELECT 1) SELECT * FROM x", "read"},
		{"show", "SHOW TABLES", "read"},
		{"explain", "EXPLAIN SELECT id FROM events", "read"},
		{"update", "UPDATE events SET kind = 'x' WHERE id = 1", "mutation"},
		{"insert", "INSERT INTO events VALUES (1, 'a')", "mutation"},
		{"delete", "DELETE FROM events WHERE id = 1", "mutation"},
		{"lowercase update", "update events set kind = 'x'", "mutation"},
		// Neither gate accepts a DDL verb, and that is the answer: the
		// operator is shown the gate's own sentence and nothing runs.
		{"drop", "DROP TABLE events", "neither"},
		{"alter", "ALTER TABLE events ADD COLUMN x INT", "neither"},
		{"truncate", "TRUNCATE TABLE events", "neither"},
		{"empty", "   ", "neither"},
		// Two statements: refused by both gates, for the same reason.
		{"two statements", "SELECT 1; SELECT 2", "neither"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ClassifyStatement("sqlite", tc.sql)
			if got.Kind != tc.want {
				t.Fatalf("ClassifyStatement(%q).Kind = %q (reason %q), want %q",
					tc.sql, got.Kind, got.Reason, tc.want)
			}
		})
	}
}

func TestClassifyStatementCarriesTheGatesOwnSentence(t *testing.T) {
	got := ClassifyStatement("mysql", "DROP TABLE events")
	if got.Kind != "neither" {
		t.Fatalf("Kind = %q", got.Kind)
	}
	// The operator sees this verbatim, so it must be the gate's wording
	// and not a sentence invented here — the gate is the thing that knows
	// why, and a second wording would drift from the refusal that
	// actually happens when the statement is run.
	if got.Reason == "" {
		t.Fatal("a neither answer must carry a reason")
	}
	if !strings.Contains(got.Reason, "schema changes") {
		t.Fatalf("reason = %q, want the mutation gate's own sentence", got.Reason)
	}
}

func TestClassifyStatementMongo(t *testing.T) {
	read := ClassifyStatement("mongo", `{"op":"find","collection":"events"}`)
	if read.Kind != "read" {
		t.Fatalf("a find is a read, got %q (%q)", read.Kind, read.Reason)
	}
	agg := ClassifyStatement("mongo", `{"op":"aggregate","collection":"events","pipeline":[{"$match":{}}]}`)
	if agg.Kind != "read" {
		t.Fatalf("an aggregate is a read, got %q (%q)", agg.Kind, agg.Reason)
	}
	// Mongo writes are honestly unimplemented — mongoConn.Write refuses
	// every statement — so "mutation" would be a promise this build
	// cannot keep. "neither", with the reason, is the true answer.
	write := ClassifyStatement("mongo", `{"op":"insertOne","collection":"events","document":{}}`)
	if write.Kind != "neither" {
		t.Fatalf("a mongo write must be neither, got %q", write.Kind)
	}
	if write.Reason == "" {
		t.Fatal("a neither answer must carry a reason")
	}
}

func TestClassifyStatementUnknownDriver(t *testing.T) {
	got := ClassifyStatement("postgres-someday", "SELECT 1")
	if got.Kind != "neither" {
		t.Fatalf("an unknown driver must refuse rather than guess, got %q", got.Kind)
	}
}
