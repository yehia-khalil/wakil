package night

import (
	"os/exec"
	"strings"
	"testing"
)

func TestPlistRunsTheNightAt23WithThePathItWasInstalledWith(t *testing.T) {
	plist := Plist("/x/bin/wakil-e2e-night", "/x/wakil-public", "/x/night.log", "/usr/bin:/Users/me/.local/bin")
	for _, want := range []string{
		"<string>" + Label + "</string>",
		"<string>/x/bin/wakil-e2e-night</string>", "<string>run</string>", "<string>/x/wakil-public</string>",
		"<key>Hour</key>", "<integer>23</integer>", "<key>Minute</key>", "<integer>0</integer>",
		"<string>/usr/bin:/Users/me/.local/bin</string>", "<string>/x/night.log</string>",
	} {
		if !strings.Contains(plist, want) {
			t.Errorf("plist is missing %s", want)
		}
	}
	plutil, err := exec.LookPath("plutil")
	if err != nil {
		t.Skip("plutil is not on PATH")
	}
	lint := exec.Command(plutil, "-lint", "-")
	lint.Stdin = strings.NewReader(plist)
	if out, err := lint.CombinedOutput(); err != nil {
		t.Fatalf("plutil: %v\n%s", err, out)
	}
}

func TestTheLastNightThatShouldHaveRun(t *testing.T) {
	for _, c := range []struct {
		now  int
		hour int
		want int
	}{
		{28, 8, 27},  // morning: last night
		{27, 23, 26}, // tonight is still running: the night before
		{28, 2, 26},
		{28, 22, 27},
	} {
		if got := LastNight(at(c.now, c.hour, 0)); !got.Equal(at(c.want, 0, 0)) {
			t.Errorf("LastNight(Oct %d %02d:00) = %s, want Oct %d", c.now, c.hour, got, c.want)
		}
	}
}
