package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// loggingResolver answers --focus and --set-value, and records every argv it
// was called with — which is the only way to see which of the two a step took.
func loggingResolver(t *testing.T, focusOK bool) (exe, argvLog string) {
	t.Helper()
	dir := t.TempDir()
	argvLog = filepath.Join(dir, "argv")
	exe = filepath.Join(dir, "axresolve")
	window := `"window":{"x":0,"y":50,"width":1710,"height":1050},"elements":[]`
	focused := `{"ok":true,` + window + `,"acted":{"action":"focus",` +
		`"identifier":"window.composer","verified":true}}`
	refused := `{"ok":false,"error":{"code":"not_found",` +
		`"message":"no element named window.composer"}}`
	set := `{"ok":true,` + window + `,"acted":{"action":"set-value",` +
		`"identifier":"window.composer","verified":true}}`
	reply := focused
	if !focusOK {
		reply = refused
	}
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" >> " + argvLog + "\n" +
		"case \"$*\" in\n" +
		"  *--focus*) cat <<'FOCUSED'\n" + reply + "\nFOCUSED\n;;\n" +
		"  *--set-value*) cat <<'SET'\n" + set + "\nSET\n;;\n" +
		"  *) cat <<'READ'\n{\"ok\":true," + window + "}\nREAD\n;;\n" +
		"esac\n"
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe, argvLog
}

// **`do.type` types. #284, Defect 2.**
//
// It was `set-value` alone, which on a SwiftUI `TextField` writes the
// element's accessibility value and leaves the binding behind it empty — so
// `both-surfaces.jsonl` clicked Send on a composer the app believed held
// nothing, three green runs in a row, with the agent's own log saying it was
// never asked. The arm has to reach the app, and the only thing that reaches
// a SwiftUI binding from outside is a keystroke.
func TestTypeIntoFocusesTheFieldAndThenTypesItForReal(t *testing.T) {
	resolverExe, resolverArgv := loggingResolver(t, true)
	orcaExe, orcaArgv := fakeOrca(t, actedJSON, 0)
	runner := &Runner{
		Orca:     Orca{Exe: orcaExe},
		Resolver: Resolver{Exe: resolverExe},
		PID:      44187,
	}

	response, err := runner.typeInto(&TypeInto{Into: "window.composer", Text: "what did it print?"})

	if err != nil {
		t.Fatalf("typeInto: %v", err)
	}
	if !response.OK {
		t.Fatalf("response = %+v", response)
	}
	resolver := read(t, resolverArgv)
	if !strings.Contains(resolver, "--focus") {
		t.Fatalf("the field was never focused, so the keystrokes had nowhere to go:\n%s", resolver)
	}
	if !strings.Contains(resolver, "window.composer") {
		t.Fatalf("the resolver was not pointed at the field:\n%s", resolver)
	}
	// The whole defect in one assertion: a value written here reads back, and
	// reports VERIFIED, while the app never sees a character.
	if strings.Contains(resolver, "--set-value") {
		t.Fatalf("set-value cannot reach a SwiftUI binding and must not be how text arrives:\n%s", resolver)
	}
	orca := read(t, orcaArgv)
	if !strings.Contains(orca, "type-text") || !strings.Contains(orca, "what did it print?") {
		t.Fatalf("the text was never typed:\n%s", orca)
	}
}

// A field that could not be focused has to fail loudly here. Typing anyway
// would send the keystrokes to whatever DID hold focus — a terminal pane, in
// every check that drives both surfaces — and the check would then fail
// somewhere else entirely, or worse, pass.
func TestTypeIntoRefusesWhenTheFieldCannotBeFocused(t *testing.T) {
	resolverExe, _ := loggingResolver(t, false)
	orcaExe, orcaArgv := fakeOrca(t, actedJSON, 0)
	runner := &Runner{
		Orca:     Orca{Exe: orcaExe},
		Resolver: Resolver{Exe: resolverExe},
		PID:      44187,
	}

	_, err := runner.typeInto(&TypeInto{Into: "window.composer", Text: "hello"})

	if err == nil {
		t.Fatal("want a refusal when the field could not be focused")
	}
	if !strings.Contains(err.Error(), "nowhere for the text to go") {
		t.Fatalf("the refusal must say why it matters, got %q", err)
	}
	if _, statErr := os.Stat(orcaArgv); statErr == nil {
		t.Fatalf("nothing may be typed when the field was not focused:\n%s", read(t, orcaArgv))
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
