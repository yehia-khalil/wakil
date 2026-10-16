package driver

import (
	"slices"
	"strings"
	"testing"
)

// #332: an operator's live Wakil (`dev.wakil.app`) took the foreground
// mid-act, and the scripted-agent check read as an app that never launched
// its agent. The stray guard could not see it: it looks for the staged
// fixture bundle, and a live Wakil is not one.

const livePSSample = `  101 /Applications/Wakil.app/Contents/MacOS/Wakil
  102 /Users/x/burrfish/app/Wakil.app/Contents/MacOS/Wakil --mcp-shim --socket /tmp/a.sock
  103 /private/var/folders/T/wakil-e2e1/WakilE2E.app/Contents/MacOS/Wakil
  104 /private/var/folders/T/wakil-e2e1/WakilE2E.app/Contents/MacOS/Wakil --mcp-shim
  105 /usr/bin/vim notes/Wakil.app.md
  106 /Applications/Orca.app/Contents/MacOS/Orca`

func TestEveryWakilThatIsNotAFixtureIsFound(t *testing.T) {
	got := liveWakils(livePSSample)
	if !slices.Equal(got, []int{101, 102}) {
		t.Fatalf("live Wakils = %v, want [101 102] — the installed app and a branch build's shim, "+
			"never a staged fixture or a file that merely names the app", got)
	}
}

func TestNoLiveWakilIsNothing(t *testing.T) {
	if got := liveWakils("  106 /Applications/Orca.app/Contents/MacOS/Orca"); len(got) != 0 {
		t.Fatalf("got %v", got)
	}
}

func TestTheRefusalSaysWhatToQuit(t *testing.T) {
	err := liveWakilRefusal([]int{101})
	if err == nil || !strings.Contains(err.Error(), "quit Wakil") || !strings.Contains(err.Error(), "101") {
		t.Fatalf("err = %v", err)
	}
	if liveWakilRefusal(nil) != nil {
		t.Fatal("nothing running is no refusal")
	}
}
