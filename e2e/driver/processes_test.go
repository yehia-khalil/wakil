package driver

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

// pgrep exits 1 when nothing matched, which is the commonest outcome of an
// assertion that nothing survived. Treating that as an error would make every
// clean run red.
func TestPSReportsNoMatchAsEmptyAndNotAnError(t *testing.T) {
	got, err := PS{}.Matching("a-process-name-that-does-not-exist-9f3c1e")
	if err != nil {
		t.Fatalf("a pattern matching nothing must not be an error, got %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("got %v, want nothing", got)
	}
}

// A process that IS running must come back, or "nothing survived" would pass
// vacuously and the orphan assertion would prove nothing at all.
func TestPSFindsASurvivingProcess(t *testing.T) {
	marker := "wakil-e2e-ps-probe-" + strconv.Itoa(os.Getpid())
	child := exec.Command("/bin/sh", "-c", "exec -a "+marker+" sleep 30")
	if err := child.Start(); err != nil {
		t.Fatalf("starting the probe process: %v", err)
	}
	t.Cleanup(func() {
		_ = child.Process.Kill()
		_, _ = child.Process.Wait()
	})

	got, err := PS{}.Matching(marker)
	if err != nil {
		t.Fatalf("Matching: %v", err)
	}
	if len(got) == 0 {
		t.Fatalf("want the running probe %q to be found", marker)
	}
	if !strings.Contains(strings.Join(got, "\n"), marker) {
		t.Fatalf("the match must carry what it matched, got %v", got)
	}
}
