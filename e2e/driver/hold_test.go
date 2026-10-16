package driver

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// --- parsing: the hold and release arms ------------------------------------

func TestAHoldAndItsReleaseParse(t *testing.T) {
	check, err := ParseChecks("ptt.jsonl", []byte(
		`{"do":{"hold":"option"}}`+"\n"+
			`{"expect":{"tree":"contains","text":"x"}}`+"\n"+
			`{"do":{"release":"option"}}`+"\n"+
			`{"expect":{"tree":"contains","text":"x"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := check.Steps[0].Do.Describe(); got != "hold option" {
		t.Fatalf("Describe = %q", got)
	}
	if got := check.Steps[2].Do.Describe(); got != "release option" {
		t.Fatalf("Describe = %q", got)
	}
}

// A key held through the HID tap stays down for the whole session until
// something posts it up, so a check that could leave one down is refused
// before any window is touched.
func TestAHoldThatIsNeverReleasedIsRefused(t *testing.T) {
	_, err := ParseChecks("ptt.jsonl", []byte(
		`{"do":{"hold":"option"}}`+"\n"+`{"expect":{"tree":"contains","text":"x"}}`))
	if err == nil || !strings.Contains(err.Error(), "no later step releases it") {
		t.Fatalf("err = %v", err)
	}
}

func TestAReleaseWithNoHoldBeforeItIsRefused(t *testing.T) {
	_, err := ParseChecks("ptt.jsonl", []byte(
		`{"do":{"release":"option"}}`+"\n"+`{"do":{"hold":"option"}}`))
	if err == nil || !strings.Contains(err.Error(), "which no earlier step holds") {
		t.Fatalf("err = %v", err)
	}
}

func TestHoldingAKeyThatIsAlreadyHeldIsRefused(t *testing.T) {
	_, err := ParseChecks("ptt.jsonl", []byte(
		`{"do":{"hold":"option"}}`+"\n"+`{"do":{"hold":"option"}}`+"\n"+`{"do":{"release":"option"}}`))
	if err == nil || !strings.Contains(err.Error(), "already holds") {
		t.Fatalf("err = %v", err)
	}
}

func TestAHoldNamingNoModifierIsRefused(t *testing.T) {
	for _, line := range []string{`{"do":{"hold":"a"}}`, `{"do":{"release":"alt"}}`} {
		_, err := ParseChecks("ptt.jsonl", []byte(line))
		if err == nil || !strings.Contains(err.Error(), "not a modifier") {
			t.Fatalf("%s: err = %v", line, err)
		}
	}
}

// A hold is one of the do arms and joins the exactly-one rule.
func TestAHoldCannotAlsoPress(t *testing.T) {
	_, err := ParseChecks("ptt.jsonl", []byte(`{"do":{"hold":"option","press":"Escape"}}`))
	if err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("err = %v", err)
	}
}

// A hold presses no named control, so it covers none.
func TestAHoldExercisesNoIdentifier(t *testing.T) {
	check := mustParse(t, "ptt",
		`{"do":{"hold":"option"}}`, `{"do":{"release":"option"}}`,
		`{"expect":{"tree":"contains","text":"x"}}`)
	if got := CoverageOf([]Check{check}).Exercised(); len(got) != 0 {
		t.Fatalf("Exercised = %v, want none", got)
	}
}

// --- running: the resolver posts the key, and a read must confirm it -------

// keyResolver stands in for axresolve, answering a modifier act the way the
// real one does — unverified, synthetic — and logging what it was asked.
func keyResolver(t *testing.T) (exe, log string) {
	t.Helper()
	dir := t.TempDir()
	exe = filepath.Join(dir, "axresolve")
	log = filepath.Join(dir, "argv")
	base := `{"ok":true,"window":{"x":0,"y":50,"width":1710,"height":1050},"elements":[]`
	down := base + `,"acted":{"action":"key-down","identifier":"option","verified":false,` +
		`"reason":"synthetic_input"}}`
	up := base + `,"acted":{"action":"key-up","identifier":"option","verified":false,` +
		`"reason":"synthetic_input"}}`
	script := "#!/bin/sh\n" +
		"case \"$*\" in\n" +
		"  *--key-down*) echo \"$*\" >> " + log + "; cat <<'DOWN'\n" + down + "\nDOWN\n;;\n" +
		"  *--key-up*) echo \"$*\" >> " + log + "; cat <<'UP'\n" + up + "\nUP\n;;\n" +
		"  *) cat <<'READ'\n" + base + "}\nREAD\n;;\n" +
		"esac\n"
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe, log
}

func TestARunnerHoldsAndReleasesThroughTheResolver(t *testing.T) {
	exe, log := keyResolver(t)
	runner, _ := newRunner(t, stateJSON, nil)
	runner.Resolver = Resolver{Exe: exe}

	got := runner.Run([]Check{mustParse(t, "ptt",
		`{"do":{"hold":"option"}}`,
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`,
		`{"do":{"release":"option"}}`,
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	want := "--pid 44187 --key-down option\n--pid 44187 --key-up option\n"
	if string(data) != want {
		t.Fatalf("the resolver was asked\n%s\nwant\n%s", data, want)
	}
}

// Nothing on screen says a modifier is down, so the act is unverified, and a
// release that no positive read follows must not pass.
func TestAReleaseNoReadConfirmsIsRed(t *testing.T) {
	exe, _ := keyResolver(t)
	runner, _ := newRunner(t, stateJSON, nil)
	runner.Resolver = Resolver{Exe: exe}

	got := runner.Run([]Check{mustParse(t, "ptt",
		`{"do":{"hold":"option"}}`,
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`,
		`{"do":{"release":"option"}}`,
		`{"expect":{"tree":"absent","text":"NEVER DRAWN"}}`)})

	err := got.Err()
	if err == nil || !strings.Contains(err.Error(), "no confirming state read followed it") {
		t.Fatalf("err = %v", err)
	}
}

// --- the scripted microphone -----------------------------------------------

func TestEveryFixtureCarriesTheSpeechScript(t *testing.T) {
	fixture, err := NewFixture(filepath.Join(t.TempDir(), "run1"))
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(fixture.SpeechScript)
	if err != nil {
		t.Fatalf("the script was not written: %v", err)
	}
	if string(data) != SpeechScript {
		t.Fatalf("the script on disk is not SpeechScript:\n%s", data)
	}
	env := map[string]string{}
	for _, assignment := range fixture.Env("/usr/bin:/bin", Seeded{}) {
		name, value, _ := strings.Cut(assignment, "=")
		env[name] = value
	}
	if env[SpeechScriptEnv] != fixture.SpeechScript {
		t.Fatalf("%s = %q, want %q — without it a hold of ⌥ opens the real microphone",
			SpeechScriptEnv, env[SpeechScriptEnv], fixture.SpeechScript)
	}
}

// Absent means unset, never the empty string.
func TestAFixtureWithNoScriptExportsNone(t *testing.T) {
	fixture := Fixture{Root: "/f", Home: "/f/home", TmpDir: "/f/tmp", BinDir: "/f/bin"}
	for _, assignment := range fixture.Env("/usr/bin:/bin", Seeded{}) {
		if strings.HasPrefix(assignment, SpeechScriptEnv+"=") {
			t.Fatalf("exported %q for a fixture with no script", assignment)
		}
	}
}

// The harness cannot import the app, so the variable's name exists twice. A
// mismatch would export a name nothing reads and the app would open the real
// microphone — #301's failure shape, so it is pinned against the source.
func TestTheHarnessAndTheAppSpellTheSpeechScriptVariableTheSameWay(t *testing.T) {
	source, err := os.ReadFile(filepath.Join(
		"..", "..", "app", "Sources", "WakilKit", "Speech", "AppleSpeechProvider.swift"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(source), `environment["`+SpeechScriptEnv+`"]`) {
		t.Fatalf("AppleSpeechProvider.swift does not read %s", SpeechScriptEnv)
	}
}

// The script is decoded by Swift, which an unknown `kind` makes fail — and an
// unreadable script becomes an engine that fails at once, so every voice check
// would go red for a reason that is the harness's. Every kind used must be one
// the decoder names, and every step must carry the fields its kind needs.
func TestTheSpeechScriptSpeaksOnlyKindsTheAppDecodes(t *testing.T) {
	source, err := os.ReadFile(filepath.Join(
		"..", "..", "app", "Sources", "WakilKit", "Speech", "ScriptedSpeechProvider.swift"))
	if err != nil {
		t.Fatal(err)
	}
	decoded := map[string]bool{}
	for _, match := range regexp.MustCompile(`case "([a-z]+)":`).FindAllStringSubmatch(string(source), -1) {
		decoded[match[1]] = true
	}
	var steps []map[string]interface{}
	if err := json.Unmarshal([]byte(SpeechScript), &steps); err != nil {
		t.Fatalf("SpeechScript is not JSON: %v", err)
	}
	if len(steps) == 0 {
		t.Fatal("SpeechScript has no steps")
	}
	settled := ""
	for index, step := range steps {
		kind, _ := step["kind"].(string)
		if !decoded[kind] {
			t.Fatalf("step %d has kind %q, which ScriptedSpeechProvider does not decode", index, kind)
		}
		if _, ok := step["after"].(float64); !ok {
			t.Fatalf("step %d has no numeric after", index)
		}
		if kind == "started" && step["device"] != SpeechScriptDevice {
			t.Fatalf("step %d starts device %v, want %q", index, step["device"], SpeechScriptDevice)
		}
		if kind == "partial" {
			settled, _ = step["settled"].(string)
		}
	}
	if settled != SpeechScriptWords {
		t.Fatalf("the script settles on %q, want %q — what lands is the last partial", settled,
			SpeechScriptWords)
	}
}

// The scripted agent answers the scripted words, and answers them with its
// own rule — even when a turn note rides along with them, which the rule
// order decides. Otherwise the voice turn check would be red on a prompt the
// stub refuses, a reason that is the harness's and not the app's.
func TestTheStubAgentAnswersTheScriptedWords(t *testing.T) {
	script, err := LoadAgentScript(filepath.Join("..", "stub", "script.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, prompt := range []string{
		SpeechScriptWords,
		"please " + SpeechScriptWords + "\n\n[wakil: identifiers in scope that match words in this turn",
	} {
		rule, ok := script.Rule(prompt)
		if !ok || rule.Reply != "the spoken turn arrived" {
			t.Fatalf("%q is answered by %+v (matched %v)", prompt, rule, ok)
		}
	}
}
