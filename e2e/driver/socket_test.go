package driver_test

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// A listening socket shows on several descriptors at one path, which is what
// a real `lsof -F n` reply looks like.
func TestSocketsFromLSOFFoldsDescriptorsAtOnePath(t *testing.T) {
	output := "p68342\nf3\nn/tmp/wakil-4A4502AB.sock\nf4\nn/tmp/wakil-4A4502AB.sock\n"
	paths, err := driver.SocketsFromLSOF(68342, output)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(paths, []string{"/tmp/wakil-4A4502AB.sock"}) {
		t.Errorf("got %q", paths)
	}
}

// `->0x…` is lsof's spelling for a connected socket with no path on this
// side. Only a bound, named socket can be dialled.
func TestSocketsFromLSOFIgnoresUnnamedPeers(t *testing.T) {
	output := "p949\nf3\nn->0x91fa4c8581eef535\nf28\nn/tmp/wakil-63CBB28F.sock\n"
	paths, err := driver.SocketsFromLSOF(949, output)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(paths, []string{"/tmp/wakil-63CBB28F.sock"}) {
		t.Errorf("got %q", paths)
	}
}

// The process holds other sockets too; only Wakil's are candidates.
func TestSocketsFromLSOFIgnoresSocketsThatAreNotWakils(t *testing.T) {
	output := "p1\nn/tmp/com.apple.something.sock\nn/tmp/wakil-ABC.sock\nn/var/run/mDNSResponder\n"
	paths, err := driver.SocketsFromLSOF(1, output)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(paths, []string{"/tmp/wakil-ABC.sock"}) {
		t.Errorf("got %q", paths)
	}
}

// One socket per place the window has shown: every one is listed, sorted, for
// SelectScreenSocket to choose among.
func TestSocketsFromLSOFListsEverySocketThePidHolds(t *testing.T) {
	output := "p7\nn/tmp/wakil-BBB.sock\nn/tmp/wakil-AAA.sock\nn/tmp/wakil-BBB.sock\n"
	paths, err := driver.SocketsFromLSOF(7, output)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(paths, []string{"/tmp/wakil-AAA.sock", "/tmp/wakil-BBB.sock"}) {
		t.Errorf("got %q", paths)
	}
}

// **Zero is an answer, not a crash**: the window opens a socket when it shows
// a place, which is later than launch.
func TestSocketsFromLSOFRefusesWhenThereIsNone(t *testing.T) {
	_, err := driver.SocketsFromLSOF(4242, "p4242\nf3\nn->0xdeadbeef\n")
	if err == nil {
		t.Fatal("found a socket in a reply that had none")
	}
	if !strings.Contains(err.Error(), "4242") {
		t.Errorf("the refusal does not name the pid: %v", err)
	}
}

// **A directory scan must never be the fallback**, and this is the guard on
// that. The fixture's sockets land in the same per-user directory as the
// operator's — Foundation's `temporaryDirectory` ignores an injected TMPDIR —
// and nothing unlinks a socket at exit, so that directory holds scores of dead
// ones. Anything resembling a scan reintroduces the wrong-instance failure in
// the one channel that writes.
func TestSocketsFromLSOFReadsOnlyWhatThePidHolds(t *testing.T) {
	if _, err := driver.SocketsFromLSOF(1234, ""); err == nil {
		t.Fatal("an empty lsof reply produced a socket")
	}
}

var (
	staging = driver.Place{Organization: "e2e-fixture", Project: "e2e-project", Environment: "staging"}
	qa      = driver.Place{Organization: "e2e-fixture", Project: "e2e-project", Environment: "qa"}
	twoOrg  = driver.Place{Organization: "e2e-fixture-two", Project: "e2e-project-two", Environment: "staging"}
)

func on(place driver.Place) *driver.Place { return &place }

func TestSelectScreenSocketPicksTheOnePinnedToTheScreen(t *testing.T) {
	path, err := driver.SelectScreenSocket(7, []driver.SocketPlace{
		{Path: "/tmp/wakil-A.sock", Place: staging, Screen: on(qa)},
		{Path: "/tmp/wakil-B.sock", Place: qa, Screen: on(qa)},
		{Path: "/tmp/wakil-C.sock", Place: twoOrg, Screen: on(qa)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if path != "/tmp/wakil-B.sock" {
		t.Errorf("got %q, want the qa socket", path)
	}
}

// The organisation is part of the place: a same-named project and environment
// in another organisation is another place.
func TestSelectScreenSocketComparesTheWholePlace(t *testing.T) {
	other := driver.Place{Organization: "e2e-fixture-two", Project: "e2e-project", Environment: "staging"}
	_, err := driver.SelectScreenSocket(7, []driver.SocketPlace{
		{Path: "/tmp/wakil-A.sock", Place: other, Screen: on(staging)},
	})
	if err == nil {
		t.Fatal("chose a socket pinned to another organisation")
	}
}

// **Several is a refusal, and this is the arm that matters.** This channel
// dispatches actions: choosing wrong would run them in another session, and
// nothing in the reply would say so.
func TestSelectScreenSocketRefusesSeveralForTheScreen(t *testing.T) {
	_, err := driver.SelectScreenSocket(7, []driver.SocketPlace{
		{Path: "/tmp/wakil-AAA.sock", Place: staging, Screen: on(staging)},
		{Path: "/tmp/wakil-BBB.sock", Place: staging, Screen: on(staging)},
	})
	if err == nil {
		t.Fatal("picked one of two sockets for one place")
	}
	for _, want := range []string{"wakil-AAA.sock", "wakil-BBB.sock"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not name %s: %v", want, err)
		}
	}
}

func TestSelectScreenSocketRefusesNoneForTheScreen(t *testing.T) {
	_, err := driver.SelectScreenSocket(7, []driver.SocketPlace{
		{Path: "/tmp/wakil-AAA.sock", Place: staging, Screen: on(qa)},
	})
	if err == nil {
		t.Fatal("drove a socket pinned to a place the window does not show")
	}
	if !strings.Contains(err.Error(), "wakil-AAA.sock") {
		t.Errorf("the refusal does not name the socket: %v", err)
	}
}

// Two answers taken either side of a switch describe two screens; neither is
// trusted.
func TestSelectScreenSocketRefusesSocketsThatDisagreeAboutTheScreen(t *testing.T) {
	_, err := driver.SelectScreenSocket(7, []driver.SocketPlace{
		{Path: "/tmp/wakil-A.sock", Place: staging, Screen: on(staging)},
		{Path: "/tmp/wakil-B.sock", Place: qa, Screen: on(qa)},
	})
	if err == nil {
		t.Fatal("chose while the sockets disagreed about the screen")
	}
}

// A window that does not say what it shows cannot be chosen by it.
func TestSelectScreenSocketRefusesAnUnknownScreen(t *testing.T) {
	_, err := driver.SelectScreenSocket(7, []driver.SocketPlace{
		{Path: "/tmp/wakil-A.sock", Place: staging},
	})
	if err == nil {
		t.Fatal("chose without knowing the screen")
	}
}

// --- ScreenChannel against stand-in sockets ----------------------------------

// screen is the window's place on screen, which every stand-in socket reports.
type screen struct {
	mu    sync.Mutex
	place driver.Place
}

func (s *screen) set(place driver.Place) { s.mu.Lock(); s.place = place; s.mu.Unlock() }
func (s *screen) get() driver.Place     { s.mu.Lock(); defer s.mu.Unlock(); return s.place }

// placeSocket serves one stand-in socket pinned to place: `initialize` reports
// it and the screen, and every `tools/call` answers with the place it was made
// for, so a test can read which socket a dispatch reached.
func placeSocket(t *testing.T, dir string, name string, place driver.Place, on *screen) string {
	t.Helper()
	path := filepath.Join(dir, name)
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listening on %s: %v", path, err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			conn, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				for {
					line, readErr := reader.ReadBytes('\n')
					if readErr != nil {
						return
					}
					var request struct {
						ID     int    `json:"id"`
						Method string `json:"method"`
					}
					if json.Unmarshal(line, &request) != nil {
						return
					}
					var result interface{}
					switch request.Method {
					case "initialize":
						result = map[string]interface{}{
							"serverInfo": map[string]string{"name": "wakil"},
							"_meta":      map[string]interface{}{"wakil/place": place, "wakil/screen": on.get()},
						}
					default:
						result = map[string]interface{}{
							"content": []map[string]string{{"type": "text", "text": place.Environment + "@" + place.Organization}},
						}
					}
					frame, _ := json.Marshal(map[string]interface{}{"jsonrpc": "2.0", "id": request.ID, "result": result})
					if _, writeErr := conn.Write(append(frame, '\n')); writeErr != nil {
						return
					}
				}
			}(conn)
		}
	}()
	return path
}

func socketDir(t *testing.T) string {
	t.Helper()
	// Short, for `sun_path`: see dialFake.
	dir, err := os.MkdirTemp("", "s")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// A dispatch after a switch reaches the socket of the place switched to, and
// one after the switch back reaches the first again: the socket each place
// opened stays pinned to it.
func TestScreenChannelFollowsTheScreenAcrossSockets(t *testing.T) {
	dir := socketDir(t)
	window := &screen{place: staging}
	var mu sync.Mutex
	paths := []string{placeSocket(t, dir, "wakil-a.sock", staging, window)}
	channel := driver.NewScreenChannel(7, 2*time.Second, func() ([]string, error) {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), paths...), nil
	})
	t.Cleanup(func() { _ = channel.Close() })

	expectCall(t, channel, "staging@e2e-fixture")

	// The window switches environment and opens that place's socket.
	window.set(qa)
	mu.Lock()
	paths = append(paths, placeSocket(t, dir, "wakil-b.sock", qa, window))
	mu.Unlock()
	expectCall(t, channel, "qa@e2e-fixture")
	if socket, _ := channel.Socket(); filepath.Base(socket) != "wakil-b.sock" {
		t.Errorf("the channel is on %s, not the qa socket", socket)
	}

	// And to another organisation.
	window.set(twoOrg)
	mu.Lock()
	paths = append(paths, placeSocket(t, dir, "wakil-c.sock", twoOrg, window))
	mu.Unlock()
	expectCall(t, channel, "staging@e2e-fixture-two")

	window.set(staging)
	expectCall(t, channel, "staging@e2e-fixture")
}

// A switch whose socket has not opened yet is waited for, not answered by the
// place left.
func TestScreenChannelWaitsForTheScreensSocket(t *testing.T) {
	dir := socketDir(t)
	window := &screen{place: staging}
	var mu sync.Mutex
	paths := []string{placeSocket(t, dir, "wakil-a.sock", staging, window)}
	channel := driver.NewScreenChannel(7, 3*time.Second, func() ([]string, error) {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), paths...), nil
	})
	t.Cleanup(func() { _ = channel.Close() })
	expectCall(t, channel, "staging@e2e-fixture")

	window.set(qa)
	go func() {
		time.Sleep(300 * time.Millisecond)
		mu.Lock()
		paths = append(paths, placeSocket(t, dir, "wakil-b.sock", qa, window))
		mu.Unlock()
	}()
	expectCall(t, channel, "qa@e2e-fixture")
}

// Past its deadline the channel refuses, naming what it saw, rather than
// dispatching into the place left.
func TestScreenChannelRefusesWhenNoSocketIsTheScreens(t *testing.T) {
	dir := socketDir(t)
	window := &screen{place: qa}
	path := placeSocket(t, dir, "wakil-a.sock", staging, window)
	channel := driver.NewScreenChannel(7, 200*time.Millisecond, func() ([]string, error) {
		return []string{path}, nil
	})
	t.Cleanup(func() { _ = channel.Close() })
	_, err := channel.Call("read_layout", nil)
	if err == nil {
		t.Fatal("dispatched into a socket pinned to a place the window does not show")
	}
	if !strings.Contains(err.Error(), "wakil-a.sock") {
		t.Errorf("the refusal does not name the socket: %v", err)
	}
}

func expectCall(t *testing.T, channel *driver.ScreenChannel, want string) {
	t.Helper()
	result, err := channel.Call("read_layout", nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.Text != want {
		t.Errorf("the call reached %q, want %q", result.Text, want)
	}
}
