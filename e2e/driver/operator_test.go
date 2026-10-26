package driver_test

import (
	"bufio"
	"encoding/json"
	"net"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// The operator socket's path is the app's `harnessSocketPath(forAgentSocket:)`, spelled again:
// the agent socket's directory, its session id, `-e2e.sock`. Both languages pin this literal.
func TestOperatorSocketForMirrorsTheApp(t *testing.T) {
	got := driver.OperatorSocketFor("/var/folders/ab/T/wakil-6F1C2D3E-0000-4000-8000-000000000001.sock")
	want := "/var/folders/ab/T/6F1C2D3E-0000-4000-8000-000000000001-e2e.sock"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// The operator socket is not a `wakil-*.sock`, so it is never a candidate for the agent channel.
func TestSocketsFromLSOFNeverOffersTheOperatorSocket(t *testing.T) {
	output := "p7\nn/tmp/wakil-AAA.sock\nn/tmp/AAA-e2e.sock\nn/tmp/AAA-approval.sock\n"
	paths, err := driver.SocketsFromLSOF(7, output)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(paths, []string{"/tmp/wakil-AAA.sock"}) {
		t.Errorf("got %q", paths)
	}
}

// Every named socket the pid holds, whatever it is called: what the operator socket is looked up in.
func TestUnixSocketsFromLSOFListsEveryNamedSocket(t *testing.T) {
	output := "p7\nn/tmp/wakil-AAA.sock\nn->0x91fa\nn/tmp/AAA-e2e.sock\nn/tmp/AAA-e2e.sock\n"
	got := driver.UnixSocketsFromLSOF(output)
	if !reflect.DeepEqual(got, []string{"/tmp/AAA-e2e.sock", "/tmp/wakil-AAA.sock"}) {
		t.Errorf("got %q", got)
	}
}

// operatorSocket serves a stand-in operator socket: `tools/list` names `serves`, and a
// `tools/call` answers `operator:<name>` so a test can read which socket a dispatch reached.
func operatorSocket(t *testing.T, dir, name string, serves ...string) string {
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
					case "tools/list":
						tools := []map[string]interface{}{}
						for _, s := range serves {
							tools = append(tools, map[string]interface{}{"name": s, "annotations": map[string]bool{"readOnlyHint": false}})
						}
						result = map[string]interface{}{"tools": tools}
					default:
						result = map[string]interface{}{
							"content": []map[string]string{{"type": "text", "text": "operator:" + name}},
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

// The operator socket beside the screen's agent socket is found among what the pid holds, says
// which actions it serves, and takes the call.
func TestOperatorChannelDrivesTheSocketBesideTheScreens(t *testing.T) {
	dir := socketDir(t)
	window := &screen{place: staging}
	agent := placeSocket(t, dir, "wakil-a.sock", staging, window)
	operator := operatorSocket(t, dir, "a-e2e.sock", "ctx_update_org")
	held := func() ([]string, error) { return []string{agent, operator}, nil }
	screenChannel := driver.NewScreenChannel(7, 2*time.Second, func() ([]string, error) { return []string{agent}, nil })
	t.Cleanup(func() { _ = screenChannel.Close() })

	channel, err := driver.NewOperatorChannel(7, screenChannel, held)
	if err != nil || channel == nil {
		t.Fatalf("NewOperatorChannel = %v, %v", channel, err)
	}
	t.Cleanup(func() { _ = channel.Close() })
	if !channel.Serves("ctx_update_org") || channel.Serves("pane_open") {
		t.Errorf("Serves: ctx_update_org %v, pane_open %v", channel.Serves("ctx_update_org"), channel.Serves("pane_open"))
	}
	result, err := channel.Call("ctx_update_org", nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.Text != "operator:a-e2e.sock" {
		t.Errorf("the call reached %q", result.Text)
	}
}

// A build with no operator socket — the merge-base `make e2e-new` drives — has no channel, said
// as nil rather than as an error: everything goes over the agent socket, as it did there.
func TestOperatorChannelIsAbsentWhenThePidHoldsNone(t *testing.T) {
	dir := socketDir(t)
	window := &screen{place: staging}
	agent := placeSocket(t, dir, "wakil-a.sock", staging, window)
	screenChannel := driver.NewScreenChannel(7, 2*time.Second, func() ([]string, error) { return []string{agent}, nil })
	t.Cleanup(func() { _ = screenChannel.Close() })

	channel, err := driver.NewOperatorChannel(7, screenChannel, func() ([]string, error) { return []string{agent}, nil })
	if err != nil || channel != nil {
		t.Fatalf("NewOperatorChannel = %v, %v, want nil, nil", channel, err)
	}
}

// After a switch the operator socket is the new place's, and one the pid does not hold is
// refused by name: never a guess, never another place's.
func TestOperatorChannelFollowsTheScreenAndRefusesASocketThePidDoesNotHold(t *testing.T) {
	dir := socketDir(t)
	window := &screen{place: staging}
	var mu sync.Mutex
	agentA := placeSocket(t, dir, "wakil-a.sock", staging, window)
	operatorA := operatorSocket(t, dir, "a-e2e.sock", "ctx_update_org")
	agents := []string{agentA}
	heldPaths := []string{agentA, operatorA}
	screenChannel := driver.NewScreenChannel(7, 2*time.Second, func() ([]string, error) {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), agents...), nil
	})
	t.Cleanup(func() { _ = screenChannel.Close() })
	held := func() ([]string, error) {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), heldPaths...), nil
	}
	channel, err := driver.NewOperatorChannel(7, screenChannel, held)
	if err != nil || channel == nil {
		t.Fatalf("NewOperatorChannel = %v, %v", channel, err)
	}
	t.Cleanup(func() { _ = channel.Close() })

	window.set(qa)
	agentB := placeSocket(t, dir, "wakil-b.sock", qa, window)
	operatorB := operatorSocket(t, dir, "b-e2e.sock", "ctx_update_org")
	mu.Lock()
	agents = []string{agentA, agentB}
	heldPaths = []string{agentA, operatorA, agentB}
	mu.Unlock()
	if _, err := channel.Call("ctx_update_org", nil); err == nil || !strings.Contains(err.Error(), "b-e2e.sock") {
		t.Fatalf("want a refusal naming the operator socket the pid does not hold, got %v", err)
	}

	mu.Lock()
	heldPaths = append(heldPaths, operatorB)
	mu.Unlock()
	result, err := channel.Call("ctx_update_org", nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.Text != "operator:b-e2e.sock" {
		t.Errorf("the call reached %q, want the place switched to", result.Text)
	}
}

// failedHarnessSocket is an agent socket of a current fixture whose operator socket would not
// start: its `initialize` says why, under `wakil/harnessFailure`.
func failedHarnessSocket(t *testing.T, dir, name string, place driver.Place, failure string) string {
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
						ID int `json:"id"`
					}
					if json.Unmarshal(line, &request) != nil {
						return
					}
					result := map[string]interface{}{
						"serverInfo": map[string]string{"name": "wakil"},
						"_meta": map[string]interface{}{
							"wakil/place": place, "wakil/screen": place, "wakil/harnessFailure": failure,
						},
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

// **A socket that failed is not a build that opens none** (review M3). When the pid holds no
// operator socket but the agent socket says the fixture's failed to start, the channel is an
// error naming why — never the silent fallback to the agent socket a merge-base build gets.
func TestOperatorChannelThatFailedToStartIsAnErrorNamingWhy(t *testing.T) {
	dir := socketDir(t)
	failure := "e2e harness socket /tmp/a-e2e.sock: bind failed — the harness's operator-only steps are refused this session"
	agent := failedHarnessSocket(t, dir, "wakil-a.sock", staging, failure)
	screenChannel := driver.NewScreenChannel(7, 2*time.Second, func() ([]string, error) { return []string{agent}, nil })
	t.Cleanup(func() { _ = screenChannel.Close() })

	channel, err := driver.NewOperatorChannel(7, screenChannel, func() ([]string, error) { return []string{agent}, nil })
	if err == nil || !strings.Contains(err.Error(), failure) {
		t.Fatalf("want an error naming %q, got %v, %v", failure, channel, err)
	}
	if !strings.Contains(err.Error(), "failed to start") {
		t.Errorf("the error does not say the socket failed to start: %v", err)
	}
}
