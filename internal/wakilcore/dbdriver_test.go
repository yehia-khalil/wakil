package wakilcore

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
)

type fakeDriver struct{}

func (fakeDriver) Kind() string                                      { return "fake" }
func (fakeDriver) Connect(context.Context, Connection) (Conn, error) { return nil, nil }
func (fakeDriver) AssertReadOnly(QuerySpec) error                    { return nil }

// ConnectWritable and AssertMutation exist only to satisfy DbDriver; this
// fake never exercises the write path.
func (fakeDriver) ConnectWritable(context.Context, Connection) (Conn, error) {
	return nil, UserError("fake: ConnectWritable not implemented")
}
func (fakeDriver) AssertMutation(QuerySpec) error {
	return UserError("fake: AssertMutation not implemented")
}

// The driver registry is process-global and RegisterDriver panics on a
// duplicate kind, so registering at test scope would panic on the second
// iteration of `go test -count=2`. Register exactly once per test binary.
var registryFakeDriverOnce sync.Once

func TestDriverRegistry(t *testing.T) {
	registryFakeDriverOnce.Do(func() { RegisterDriver("fake", fakeDriver{}) })
	d, err := GetDriver("fake")
	if err != nil || d.Kind() != "fake" {
		t.Fatalf("registry miss: %v", err)
	}
	if _, err := GetDriver("nope"); err == nil {
		t.Fatal("unknown driver must error")
	}
}

// dupKindCounter yields a fresh kind name per invocation. It is shared by
// TestDuplicateRegistrationPanics and TestConcurrentRegistryAccess, both of
// which register a kind and would otherwise panic on the second iteration
// of a -count=2 run against the process-global registry. For the duplicate
// test that panic was worse than a failure: it was caught by the same
// recover(), leaving the test green for the wrong reason — no longer
// testing that the SECOND registration panics.
var dupKindCounter atomic.Int64

// TestDuplicateRegistrationPanics verifies that registering a driver with
// the same kind twice causes a panic.
func TestDuplicateRegistrationPanics(t *testing.T) {
	kind := fmt.Sprintf("duplicate_test_kind_%d", dupKindCounter.Add(1))
	RegisterDriver(kind, fakeDriver{})
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic on duplicate registration")
		}
	}()
	RegisterDriver(kind, fakeDriver{}) // Should panic
}

// TestConnectionDoesNotLeakURL verifies that Connection.URL is never
// serialized and that String() methods redact it.
func TestConnectionDoesNotLeakURL(t *testing.T) {
	conn := Connection{
		Ref:      "my-ref",
		URL:      "postgres://user:s3cr3t-not-real@localhost/mydb",
		ReadOnly: true,
	}

	// Test JSON marshaling does not include URL
	data, err := json.Marshal(conn)
	if err != nil {
		t.Fatalf("json.Marshal failed: %v", err)
	}
	if string(data) == "" {
		t.Fatal("json.Marshal returned empty result")
	}
	if string(data) == "{}" {
		// This is expected - URL should not be marshaled
	} else if containsSubstring(string(data), "s3cr3t-not-real") {
		t.Fatalf("json.Marshal leaked password: %s", string(data))
	}

	// Test %v format does not leak URL
	v := fmt.Sprintf("%v", conn)
	if containsSubstring(v, "s3cr3t-not-real") {
		t.Fatalf("%%v format leaked password: %s", v)
	}

	// Test %+v format does not leak URL
	plusV := fmt.Sprintf("%+v", conn)
	if containsSubstring(plusV, "s3cr3t-not-real") {
		t.Fatalf("%%+v format leaked password: %s", plusV)
	}

	// Verify that the redaction contains expected safe info
	if !containsSubstring(v, "my-ref") {
		t.Fatalf("String() should include Ref: %s", v)
	}
	if !containsSubstring(v, "redacted") {
		t.Fatalf("String() should indicate URL is redacted: %s", v)
	}
}

// TestConcurrentRegistryAccess verifies that concurrent GetDriver reads are
// safe (no race conditions). Note it exercises concurrent READS only: the
// single RegisterDriver below happens before any goroutine starts, so this
// does not cover a write racing a read. Run with -race for it to mean
// anything.
func TestConcurrentRegistryAccess(t *testing.T) {
	// A fresh kind per invocation: RegisterDriver panics on a duplicate, so
	// a fixed name would panic on the second iteration of -count=2.
	kind := fmt.Sprintf("concurrent_test_kind_%d", dupKindCounter.Add(1))

	// Pre-register a driver so GetDriver calls don't fail
	RegisterDriver(kind, fakeDriver{})

	done := make(chan bool, 4)

	// Start multiple goroutines reading from the registry
	for i := 0; i < 3; i++ {
		go func(id int) {
			for j := 0; j < 10; j++ {
				_, _ = GetDriver(kind)
			}
			done <- true
		}(i)
	}

	// Wait for all readers to complete
	for i := 0; i < 3; i++ {
		<-done
	}
}

// Helper function to check if a string contains a substring
func containsSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// TestNewContainerListNeverMarshalsNull asserts the guard NewContainerList
// exists for actually fires: a nil Containers marshals to
// {"containers":null}, which is what every wakil-db error path would
// otherwise put on the wire, since they all pass nil.
func TestNewContainerListNeverMarshalsNull(t *testing.T) {
	got, err := json.Marshal(NewContainerList(nil))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if want := `{"containers":[]}`; string(got) != want {
		t.Errorf("NewContainerList(nil) marshals to %s, want %s", got, want)
	}

	list := NewContainerList([]Container{{Name: "users", Kind: "table"}})
	if len(list.Containers) != 1 || list.Containers[0].Name != "users" {
		t.Errorf("NewContainerList must pass a non-empty slice through unchanged, got %+v", list.Containers)
	}
}

// TestRowsJSONWireShape pins the exact JSON wakil-db's `query` tool puts on
// the wire, because a consumer outside this module reads it by key name and
// cannot be compiled against this struct.
//
// The consumer is Wakil's Swift `db_run_query` action
// (app/Sources/WakilKit/Registry/StandardActions.swift, `dbPaneContents`),
// which decodes this object out of the CallToolResult's structuredContent
// and copies it into the pane an LLM reads through `read_pane`. Renaming a
// tag here would not fail any Go test and would not fail the Swift build; it
// would silently stop the pane being populated, or — for `truncated` — stop
// a capped result being marked as capped.
//
// Both spellings of Truncated are asserted, since the field is
// `omitempty`: a truncated result carries `"truncated":true` and a complete
// one carries no `truncated` key at all. The Swift side has to read an
// absent key as false, and the literal fixtures it tests against are copies
// of these two strings.
func TestRowsJSONWireShape(t *testing.T) {
	truncated, err := json.Marshal(Rows{
		Columns: []string{"id", "name"}, Rows: [][]any{{1, "ada"}}, Millis: 3, Truncated: true,
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if want := `{"columns":["id","name"],"columnTypes":null,"columnTypesInferred":false,"rows":[[1,"ada"]],"millis":3,"truncated":true,"pageable":false,"listsTables":false}`; string(truncated) != want {
		t.Errorf("truncated Rows marshals to %s, want %s", truncated, want)
	}

	complete, err := json.Marshal(Rows{Columns: []string{"id"}, Rows: [][]any{{1}}, Millis: 3})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if want := `{"columns":["id"],"columnTypes":null,"columnTypesInferred":false,"rows":[[1]],"millis":3,"pageable":false,"listsTables":false}`; string(complete) != want {
		t.Errorf("complete Rows marshals to %s, want %s", complete, want)
	}
}
