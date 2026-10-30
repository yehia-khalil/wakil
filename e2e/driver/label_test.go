package driver

import "testing"

func TestALabelStepNamesExactlyOnePredicate(t *testing.T) {
	text := "Billing"
	for _, line := range []string{
		`{"expect":{"label":"landing.row.running:0"}}`,
		`{"expect":{"label":"landing.row.running:0","contains":"a","equals":"b"}}`,
		`{"expect":{"label":"landing.row.running:0","present":true}}`,
	} {
		if _, err := ParseChecks("x.jsonl", []byte(line)); err == nil {
			t.Errorf("%s parsed, and it asserts nothing definite", line)
		}
	}
	check, err := ParseChecks("x.jsonl", []byte(`{"expect":{"label":"palette.row.r","contains":"Billing"}}`))
	if err != nil || len(check.Steps) != 1 || !check.Steps[0].Expect.Confirms() {
		t.Fatalf("a label step with one predicate parses and confirms: %v %v", check, err)
	}
	if err := judgeLabel(&Expect{Label: "x", Contains: &text}, "Rename to “Billing refund”"); err != nil {
		t.Error(err)
	}
	if err := judgeLabel(&Expect{Label: "x", Equals: &text}, "Billing refund"); err == nil {
		t.Error("equals passed on a longer label")
	}
	if err := judgeLabel(&Expect{Label: "x", Contains: &text}, ""); err == nil {
		t.Error("contains passed on an empty label")
	}
}
