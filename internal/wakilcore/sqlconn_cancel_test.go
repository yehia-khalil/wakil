package wakilcore

import (
	"context"
	"testing"
	"time"
)

// endlessCTE counts to two billion: minutes of work on any machine, and a
// WITH statement, so AssertSQLReadOnly lets it through like any read.
const endlessCTE = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 2000000000) SELECT max(x) AS n FROM c"

// A cancelled read returns at once rather than running to the end. modernc's
// driver interrupts the statement when the context ends; this pins it.
func TestSQLiteCancelledReadReturnsAtOnce(t *testing.T) {
	path := seedSQLite(t)
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: path})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(300*time.Millisecond, cancel)
	start := time.Now()
	_, err = conn.Read(ctx, QuerySpec{Raw: endlessCTE}, 10)
	if err == nil {
		t.Fatal("the read finished; it should have been cancelled")
	}
	if waited := time.Since(start); waited > 2*time.Second {
		t.Fatalf("the read returned %s after start — the cancel did not interrupt it", waited)
	}
}
