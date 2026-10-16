package driver

import (
	"strings"
	"testing"
)

// The shape `ioreg -n Root -d1 -a` actually prints, captured 2026-09-25 while
// the screen was locked. Trimmed to the session dictionary; the keys around it
// are kept because what this parser has to get right is finding ITS key among
// neighbours whose names start the same way.
const lockedSession = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>IOConsoleUsers</key>
	<array>
		<dict>
			<key>CGSSessionScreenIsLocked</key>
			<true/>
			<key>CGSSessionScreenLockedTime</key>
			<integer>1790282663</integer>
			<key>kCGSSessionOnConsoleKey</key>
			<true/>
		</dict>
	</array>
</dict>
</plist>`

func TestALockedScreenIsReadOutOfTheSessionDictionary(t *testing.T) {
	if !screenLockedIn(lockedSession) {
		t.Fatal("a session dictionary saying the screen is locked was read as unlocked, " +
			"which is the reading that lets a run spend thirty seconds blaming the app")
	}
}

// **The key is ABSENT when the screen is unlocked**, which is macOS's own
// shape and not an omission in this fixture: the window server adds
// CGSSessionScreenIsLocked on lock and removes it on unlock.
func TestAnUnlockedScreenHasNoSuchKeyAtAll(t *testing.T) {
	unlocked := strings.Replace(lockedSession,
		"<key>CGSSessionScreenIsLocked</key>\n\t\t\t<true/>\n\t\t\t", "", 1)
	if strings.Contains(unlocked, LockKey) {
		t.Fatalf("the fixture still carries %s, so this test would pass on the wrong reason", LockKey)
	}
	if screenLockedIn(unlocked) {
		t.Fatal("an unlocked session was read as locked, which would refuse every run on this Mac")
	}
}

// **A present-but-false key reads as unlocked too.** Nothing observed has
// emitted that shape, but reading a key's NAME and ignoring its VALUE is
// exactly the bug that would turn this precondition into a permanent refusal,
// so it is pinned rather than left to the absence case to cover.
func TestAKeyThatSaysFalseIsNotALockedScreen(t *testing.T) {
	if screenLockedIn(strings.Replace(lockedSession, "<true/>", "<false/>", 1)) {
		t.Fatal("the key's presence was taken for its value")
	}
}

// **The refusal names the lock, not the app.** The whole point of this
// precondition is the sentence it prints, so the sentence is what is asserted.
func TestTheRefusalSaysWhatToGoAndDo(t *testing.T) {
	err := refusalFor(true)
	if err == nil {
		t.Fatal("a locked screen was not refused")
	}
	for _, want := range []string{"screen is locked", "Unlock the screen", "#284"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal never says %q: %v", want, err)
		}
	}
	if refusalFor(false) != nil {
		t.Fatal("an unlocked screen was refused")
	}
}
