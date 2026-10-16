package wakilcore

import "strings"
import "testing"

func TestRenderUpdate(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}

	// Every value is QUOTED, including a numeric column's. A bare literal
	// is a COLUMN REFERENCE on both engines and both take it silently:
	// SET name = secret stored the secret, no error. That is the failure
	// this rule exists against.
	got, err := c.RenderUpdate("events", `"id" = '1'`, "kind", "TEXT", "b")
	if err != nil {
		t.Fatal(err)
	}
	want := `UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'`
	if got != want {
		t.Fatalf("got %s want %s", got, want)
	}

	got, _ = c.RenderUpdate("events", `"id" = '1'`, "n", "INTEGER", "42")
	if got != `UPDATE "events" SET "n" = '42' WHERE "id" = '1'` {
		t.Fatalf("a numeric column's value is quoted too, got %s", got)
	}

	// A leading "=" is the operator asking for SQL. It passes through
	// verbatim: unquoted, unescaped, unvalidated.
	got, _ = c.RenderUpdate("events", `"id" = '1'`, "ts", "DATETIME", "=NOW()")
	if got != `UPDATE "events" SET "ts" = NOW() WHERE "id" = '1'` {
		t.Fatalf("got %s", got)
	}
	got, _ = c.RenderUpdate("events", `"id" = '1'`, "kind", "TEXT", "=NULL")
	if got != `UPDATE "events" SET "kind" = NULL WHERE "id" = '1'` {
		t.Fatalf("got %s", got)
	}

	// An empty field is the empty string, NOT null. The grid draws the
	// two differently and this keeps the distinction writable.
	got, _ = c.RenderUpdate("events", `"id" = '1'`, "kind", "TEXT", "")
	if got != `UPDATE "events" SET "kind" = '' WHERE "id" = '1'` {
		t.Fatalf("got %s", got)
	}

	// Quoting is applied, so a quote in a value cannot end the literal.
	got, _ = c.RenderUpdate("events", `"id" = '1'`, "kind", "TEXT", "x' WHERE 1=1 -- ")
	if !strings.Contains(got, `'x'' WHERE 1=1 -- '`) {
		t.Fatalf("got %s", got)
	}
}

// sqlite stores "abc" in an INTEGER column AS TEXT, silently; MySQL
// refuses it with an engine error. Validating first gives both engines
// the same behaviour and gives the operator a sentence rather than an
// error code.
func TestRenderUpdateValidatesNumericColumns(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}
	for _, typ := range []string{"INTEGER", "INT", "BIGINT", "DECIMAL", "NUMERIC", "REAL", "DOUBLE", "FLOAT"} {
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, "abc"); err == nil {
			t.Errorf("%s should refuse abc", typ)
		}
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, "42"); err != nil {
			t.Errorf("%s should accept 42: %v", typ, err)
		}
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, " 8 "); err != nil {
			t.Errorf("%s should accept a padded number: %v", typ, err)
		}
		// An expression is never validated — it is not a value.
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, "=n + 1"); err != nil {
			t.Errorf("%s should accept an expression: %v", typ, err)
		}
	}
	// A BIT column cannot be expressed as a quoted literal at all.
	if _, err := c.RenderUpdate("t", `"id" = '1'`, "b", "BIT", "1"); err == nil {
		t.Error("BIT should be refused")
	}
	// ...but a BIT column CAN be written via its own bit-literal syntax,
	// which only reaches the engine through the expression path — the
	// uneditable-type refusal above must not apply there. Round 1 finding:
	// the refusal used to run before the expression branch and blocked
	// this, the one construct that could legitimately write a BIT column.
	got, err := c.RenderUpdate("t", `"id" = '1'`, "b", "BIT", "=b'1'")
	if err != nil {
		t.Fatalf("a bit literal expression should be accepted for BIT: %v", err)
	}
	if got != `UPDATE "t" SET "b" = b'1' WHERE "id" = '1'` {
		t.Fatalf("got %s", got)
	}
}

// Round 1 finding: strconv.ParseFloat accepts far more than either engine's
// numeric literal syntax, and every one of these, quoted and sent to a
// numeric column, was measured to store as inert text on sqlite (typeof =
// "text") while live MySQL, under both sql_mode readings, refuses it with
// Error 1366 — the exact two-engine divergence this validation exists to
// collapse into one sentence. All six must be refused, not merely the
// hex form ("0x10") the original check already caught.
func TestRenderUpdateRefusesFloatSyntaxNoSQLEngineAccepts(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}
	for _, bad := range []string{"NaN", "Inf", "+Inf", "infinity", "0x1p4", "1_000"} {
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", "DOUBLE", bad); err == nil {
			t.Errorf("%q should be refused for a numeric column", bad)
		}
	}
}

// Round 1 finding: the numeric check validated strings.TrimSpace(value)
// but then quoted the untrimmed value, so "\n8" validated (its trimmed
// form is a plain number) and was then sent to MySQL as the literal
// '\n8', which strict mode refuses with Error 1366 — a value RenderUpdate
// had just told the operator was fine. Validation and quoting must agree
// on the same string; this pins that the value actually quoted is the
// trimmed one.
func TestRenderUpdateNumericValidationAndQuotingAgree(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}
	got, err := c.RenderUpdate("t", `"id" = '1'`, "n", "INT", "\n8")
	if err != nil {
		t.Fatalf("a numeric value with surrounding whitespace should validate: %v", err)
	}
	if got != `UPDATE "t" SET "n" = '8' WHERE "id" = '1'` {
		t.Fatalf("the trimmed value should be what is quoted, got %s", got)
	}
}

// Round 1 finding: hasTypePrefix used to be a bare strings.HasPrefix scan,
// which over-reaches in both directions — "BIT" swept in "BITTER"/"BITS",
// and "INT" swept in "INTERVAL" — and under-reaches for sqlite's own
// documented "UNSIGNED BIG INT" (INTEGER affinity, matches no shorter
// stem in the list at all). All three are pinned here.
func TestRenderUpdateTypeMatchingIsWordBoundaryNotBarePrefix(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}

	// "BITTER" and "BITS" are not BIT: an ordinary quoted value is
	// accepted, not refused as unquotable.
	for _, typ := range []string{"BITTER", "BITS"} {
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, "x"); err != nil {
			t.Errorf("%s should not be treated as BIT: %v", typ, err)
		}
	}

	// "INTERVAL" is not INT: it must not be validated as numeric, so a
	// non-numeric value must be accepted rather than refused.
	if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", "INTERVAL", "abc"); err != nil {
		t.Errorf("INTERVAL should not be validated as numeric: %v", err)
	}

	// sqlite's "UNSIGNED BIG INT" has INTEGER affinity and must be
	// validated as numeric, even though it shares no shorter stem with
	// any other entry in the list.
	if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", "UNSIGNED BIG INT", "abc"); err == nil {
		t.Error("UNSIGNED BIG INT should refuse abc")
	}
	if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", "UNSIGNED BIG INT", "42"); err != nil {
		t.Errorf("UNSIGNED BIG INT should accept 42: %v", err)
	}
}

// Round 1 finding: the leading "=" sigil has no escape hatch, and a value
// typed as "=secret" composes a bare column reference — measured, it
// copied another column's value with no error. This is documented as an
// intentional, unescapable limitation in RenderUpdate's doc comment
// ("The unescapable ="), not fixed here; this fixture pins the behaviour
// so it is recorded rather than rediscovered.
func TestRenderUpdateLeadingEqualsIsUnescapable(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}
	got, err := c.RenderUpdate("t", `"id" = '1'`, "v", "TEXT", "=secret")
	if err != nil {
		t.Fatalf("an expression is passed through unvalidated: %v", err)
	}
	if got != `UPDATE "t" SET "v" = secret WHERE "id" = '1'` {
		t.Fatalf("got %s — a bare column reference, exactly the hazard quoting exists against", got)
	}
}

func TestRenderUpdateRefusesEmptyParts(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}
	for _, tc := range []struct{ table, key, column string }{
		{"", `"id" = '1'`, "kind"},
		{"events", "", "kind"},
		{"events", `"id" = '1'`, ""},
	} {
		if _, err := c.RenderUpdate(tc.table, tc.key, tc.column, "TEXT", "x"); err == nil {
			t.Errorf("%#v should be refused", tc)
		}
	}
}

// The known defect this task was handed to decide (see RenderUpdate's doc
// comment, decision (b)): AssertSQLMutation's ";" scan runs over the whole
// composed statement text, including string literals, so an ordinary text
// value containing a semicolon would be falsely refused downstream with
// "multiple statements are not allowed in a mutation" — a message about
// stacked statements, for typing punctuation into a text field. RenderUpdate
// refuses it itself, earlier and with a sentence the operator can act on.
func TestRenderUpdateRefusesSemicolonInAValue(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}

	_, err := c.RenderUpdate("notes", `"id" = '1'`, "body", "TEXT", "hello; world")
	if err == nil {
		t.Fatal("a value containing ; should be refused, not silently mis-gated later")
	}

	// Confirm what WOULD have happened without this check: the composed
	// statement, if it had been allowed through, trips AssertSQLMutation's
	// blanket ";" scan even though the ";" is safely inside a quoted
	// literal — this is the false positive being avoided.
	wouldBe := `UPDATE "notes" SET "body" = 'hello; world' WHERE "id" = '1'`
	if err2 := AssertSQLMutation(wouldBe); err2 == nil {
		t.Fatal("expected the composed statement to trip the mutation gate's ; scan " +
			"(that is the defect RenderUpdate's own check exists to pre-empt)")
	}

	// An expression (leading "=") is the operator's own SQL, not a value —
	// a ";" there is a real attempt at a second statement and must reach
	// AssertSQLMutation to be refused there, not be pre-empted here.
	got, err := c.RenderUpdate("notes", `"id" = '1'`, "body", "TEXT", "=a; DROP TABLE notes")
	if err != nil {
		t.Fatalf("an expression is passed through, semicolon and all: %v", err)
	}
	if got != `UPDATE "notes" SET "body" = a; DROP TABLE notes WHERE "id" = '1'` {
		t.Fatalf("got %s", got)
	}
	if err := AssertSQLMutation(got); err == nil {
		t.Fatal("the gate should still catch this one, since it really is two statements")
	}
}
