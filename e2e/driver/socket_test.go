package driver_test

import (
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// A listening socket shows on several descriptors at one path, which is what
// a real `lsof -F n` reply looks like.
func TestSocketFromLSOFFoldsDescriptorsAtOnePath(t *testing.T) {
	output := "p68342\nf3\nn/tmp/wakil-4A4502AB.sock\nf4\nn/tmp/wakil-4A4502AB.sock\n"
	path, err := driver.SocketFromLSOF(68342, output)
	if err != nil {
		t.Fatal(err)
	}
	if path != "/tmp/wakil-4A4502AB.sock" {
		t.Errorf("got %q", path)
	}
}

// `->0x…` is lsof's spelling for a connected socket with no path on this
// side. Only a bound, named socket can be dialled.
func TestSocketFromLSOFIgnoresUnnamedPeers(t *testing.T) {
	output := "p949\nf3\nn->0x91fa4c8581eef535\nf28\nn/tmp/wakil-63CBB28F.sock\n"
	path, err := driver.SocketFromLSOF(949, output)
	if err != nil {
		t.Fatal(err)
	}
	if path != "/tmp/wakil-63CBB28F.sock" {
		t.Errorf("got %q", path)
	}
}

// The process holds other sockets too; only Wakil's are candidates.
func TestSocketFromLSOFIgnoresSocketsThatAreNotWakils(t *testing.T) {
	output := "p1\nn/tmp/com.apple.something.sock\nn/tmp/wakil-ABC.sock\nn/var/run/mDNSResponder\n"
	path, err := driver.SocketFromLSOF(1, output)
	if err != nil {
		t.Fatal(err)
	}
	if path != "/tmp/wakil-ABC.sock" {
		t.Errorf("got %q", path)
	}
}

// **Zero is an answer, not a crash**: the session opens its socket when the
// window starts one, which is later than launch.
func TestSocketFromLSOFRefusesWhenThereIsNone(t *testing.T) {
	_, err := driver.SocketFromLSOF(4242, "p4242\nf3\nn->0xdeadbeef\n")
	if err == nil {
		t.Fatal("found a socket in a reply that had none")
	}
	if !strings.Contains(err.Error(), "4242") {
		t.Errorf("the refusal does not name the pid: %v", err)
	}
}

// **Several is a refusal, and this is the arm that matters.** This channel
// dispatches actions: choosing wrong would run them against the operator's
// live window, and nothing in the reply would say so.
func TestSocketFromLSOFRefusesSeveral(t *testing.T) {
	output := "p7\nn/tmp/wakil-AAA.sock\nn/tmp/wakil-BBB.sock\n"
	_, err := driver.SocketFromLSOF(7, output)
	if err == nil {
		t.Fatal("picked one of two sockets")
	}
	for _, want := range []string{"wakil-AAA.sock", "wakil-BBB.sock"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not name %s: %v", want, err)
		}
	}
}

// **A directory scan must never be the fallback**, and this is the guard on
// that. The fixture's socket lands in the same per-user directory as the
// operator's — Foundation's `temporaryDirectory` ignores an injected TMPDIR —
// and nothing unlinks a socket at exit, so that directory holds scores of dead
// ones. Anything resembling a scan reintroduces the wrong-instance failure in
// the one channel that writes.
func TestSocketFromLSOFReadsOnlyWhatThePidHolds(t *testing.T) {
	// A reply naming a pid other than the one asked about is still only what
	// lsof was asked for; the point is that nothing here consults the
	// filesystem, so an empty reply cannot become "whatever is lying around".
	if _, err := driver.SocketFromLSOF(1234, ""); err == nil {
		t.Fatal("an empty lsof reply produced a socket")
	}
}
