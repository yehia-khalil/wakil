package driver

import (
	"os"
	"strings"
	"testing"
)

// actedJSON is a keyboard reply Orca confirmed.
const actedJSON = `{
  "ok": true,
  "result": {
    "action": {"path": "accessibility", "verification": {"state": "verified"}}
  }
}`

// **The three keyboard arms exist because a shell cannot be driven any other
// way.** `do.click` presses a named control and `do.type` addresses a named
// field; a terminal pane has neither — what it has is a PTY, and the only
// thing a PTY reads is keystrokes.
func TestParseChecksReadsTheThreeKeyboardArms(t *testing.T) {
	check, err := ParseChecks("terminal", []byte(
		`{"do":{"keys":"ls"}}`+"\n"+
			`{"do":{"press":"Return"}}`+"\n"+
			`{"do":{"hotkey":"ctrl+c"}}`+"\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(check.Steps) != 3 {
		t.Fatalf("want three steps, got %d", len(check.Steps))
	}
	if check.Steps[0].Do.Keys != "ls" {
		t.Fatalf("got %q", check.Steps[0].Do.Keys)
	}
	if check.Steps[1].Do.Press != "Return" {
		t.Fatalf("got %q", check.Steps[1].Do.Press)
	}
	if check.Steps[2].Do.Hotkey != "ctrl+c" {
		t.Fatalf("got %q", check.Steps[2].Do.Hotkey)
	}
}

// A `do` carrying two arms would run one and drop the other, and which one
// ran would depend on field order in a struct the check author never sees —
// the same rule the four step kinds already hold to.
func TestParseChecksRefusesADoCarryingTwoArms(t *testing.T) {
	_, err := ParseChecks("terminal", []byte(`{"do":{"keys":"ls","press":"Return"}}`+"\n"))
	if err == nil {
		t.Fatal("want a refusal for a do carrying both keys and press")
	}
	if !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("the refusal must say what the rule is, got %q", err)
	}
}

// **Typing empty text is refused at parse time.** It reaches the window,
// changes nothing, and reads in a check file as though something was sent.
func TestParseChecksRefusesAnEmptyKeystrokeArm(t *testing.T) {
	for _, line := range []string{`{"do":{"keys":""}}`, `{"do":{"press":""}}`, `{"do":{"hotkey":""}}`} {
		if _, err := ParseChecks("terminal", []byte(line+"\n")); err == nil {
			t.Fatalf("%s: want a refusal", line)
		}
	}
}

// Keystrokes are addressed by pid for the same reason every read is: with two
// Wakils running, a bundle-id selector silently resolves to one of them, and
// this channel carries WRITES — a stray `rm` typed into the operator's own
// shell is the worst outcome this harness can produce.
func TestKeyboardCommandsAddressByPIDAndNeverByBundleID(t *testing.T) {
	cases := []struct {
		name string
		call func(Orca) (Response, error)
		want []string
	}{
		{"type-text", func(o Orca) (Response, error) { return o.TypeText(44187, "ls -la") },
			[]string{"computer", "type-text", "--text", "ls -la"}},
		{"press-key", func(o Orca) (Response, error) { return o.PressKey(44187, "Return") },
			[]string{"computer", "press-key", "--key", "Return"}},
		{"hotkey", func(o Orca) (Response, error) { return o.Hotkey(44187, "ctrl+c") },
			[]string{"computer", "hotkey", "--key", "ctrl+c"}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			exe, argvLog := fakeOrca(t, actedJSON, 0)
			if _, err := testCase.call(Orca{Exe: exe}); err != nil {
				t.Fatalf("%s: %v", testCase.name, err)
			}
			recorded, err := os.ReadFile(argvLog)
			if err != nil {
				t.Fatal(err)
			}
			argv := string(recorded)
			if !strings.Contains(argv, "pid:44187") {
				t.Fatalf("argv must address by pid, got:\n%s", argv)
			}
			if strings.Contains(argv, "dev.wakil") {
				t.Fatalf("argv must never carry a bundle id, got:\n%s", argv)
			}
			for _, want := range testCase.want {
				if !strings.Contains(argv, want) {
					t.Fatalf("argv missing %q:\n%s", want, argv)
				}
			}
			// **No screenshot per keystroke.** A check types a command a
			// character at a time in the worst case; a PNG per keystroke would
			// cost more than the run.
			if !strings.Contains(argv, "--no-screenshot") {
				t.Fatalf("argv must skip the screenshot, got:\n%s", argv)
			}
			// **--restore-window, earned by a flake.** Without it a keystroke
			// depends on ambient focus: measured, a run with something else
			// frontmost refused twelve acts with `window_not_focused`. It can
			// only bring the pid this call already names forward, so it
			// cannot deliver a keystroke to the operator's instance.
			if !strings.Contains(argv, "--restore-window") {
				t.Fatalf("argv must bring the fixture window forward, got:\n%s", argv)
			}
		})
	}
}

// A keystroke Orca refused is a failure, never a silent no-op. This is the
// same rule `act` already holds clicks to; typing has to obey it too, because
// a check whose keystrokes never landed still reads its assertions against a
// window that simply never changed.
func TestActReportsARefusedKeystroke(t *testing.T) {
	exe, _ := fakeOrca(t, `{"ok":false,"error":{"code":"window_not_focused"}}`, 1)
	runner := &Runner{Orca: Orca{Exe: exe}, PID: 44187}
	_, err := runner.act(&Do{Keys: "ls"})
	if err == nil {
		t.Fatal("want the refusal reported")
	}
	if !strings.Contains(err.Error(), "refused") {
		t.Fatalf("got %q", err)
	}
}
