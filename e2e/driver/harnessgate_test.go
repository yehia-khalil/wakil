package driver_test

import (
	"os"
	"regexp"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// The app opens its operator channel only under the bundle id this harness stages its fixture
// under, so the two must be one string: the Swift constant `e2eFixtureBundleIdentifier`
// (HarnessChannel.swift) and E2EBundleIdentifier. If they drift, the fixture quietly opens no
// operator channel and every operator-only step meets the agent socket's refusal.
func TestTheAppsHarnessGateNamesTheBundleIdTheFixtureIsStagedUnder(t *testing.T) {
	source, err := os.ReadFile("../../app/Sources/WakilKit/MCP/HarnessChannel.swift")
	if err != nil {
		t.Fatal(err)
	}
	match := regexp.MustCompile(`public let e2eFixtureBundleIdentifier = "([^"]*)"`).FindSubmatch(source)
	if match == nil {
		t.Fatal("HarnessChannel.swift declares no e2eFixtureBundleIdentifier literal")
	}
	if got := string(match[1]); got != driver.E2EBundleIdentifier {
		t.Errorf("the app gates its harness channel on %q, the fixture is staged as %q", got, driver.E2EBundleIdentifier)
	}
}

// **The gate's call site** (WakilApp has no test target). The harness channel is opened in one
// place, and the identifier it is judged by is the running bundle's own, read there and then:
// not an environment variable, a default or an argument, which anything that launches the app
// could set.
func TestTheWindowJudgesTheHarnessGateByItsOwnBundleIdentifier(t *testing.T) {
	source, err := os.ReadFile("../../app/Sources/WakilApp/WindowSession.swift")
	if err != nil {
		t.Fatal(err)
	}
	if direct := regexp.MustCompile(`startHarnessSocket\(`).FindAllIndex(source, -1); len(direct) != 0 {
		t.Errorf("WindowSession.swift calls startHarnessSocket directly %d times: it opens the channel through openHarnessSocket", len(direct))
	}
	calls := regexp.MustCompile(`openHarnessSocket\(`).FindAllIndex(source, -1)
	if len(calls) != 1 {
		t.Fatalf("WindowSession.swift calls openHarnessSocket %d times, want once", len(calls))
	}
	if !regexp.MustCompile(`openHarnessSocket\(\s*bundleIdentifier: Bundle\.main\.bundleIdentifier,`).Match(source) {
		t.Error("openHarnessSocket is not handed Bundle.main.bundleIdentifier directly")
	}
}
