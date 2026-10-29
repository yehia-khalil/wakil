package wakilcore

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestReadKeysMissingFileIsEmpty(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	keys, appError := ReadKeys()
	if len(keys) != 0 || keys == nil || appError != "" {
		t.Errorf("ReadKeys() = %v, %q", keys, appError)
	}
}

func TestWriteKeysRoundTrips(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	want := map[string]string{"pane.close": "⌃⌘W", "browser.reload": ""}
	if err := WriteKeys(want); err != nil {
		t.Fatal(err)
	}
	got, appError := ReadKeys()
	if appError != "" || !reflect.DeepEqual(got, want) {
		t.Errorf("ReadKeys() = %v, %q; want %v", got, appError, want)
	}
}

func TestWriteKeysReplacesWholeMap(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := WriteKeys(map[string]string{"a": "⌘1"}); err != nil {
		t.Fatal(err)
	}
	if err := WriteKeys(map[string]string{"b": "⌘2"}); err != nil {
		t.Fatal(err)
	}
	got, _ := ReadKeys()
	if want := map[string]string{"b": "⌘2"}; !reflect.DeepEqual(got, want) {
		t.Errorf("ReadKeys() = %v, want %v", got, want)
	}
}

func TestWriteKeysAcceptsEveryKeyShape(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	keys := map[string]string{"a": "⌃⌥⇧⌘R", "b": "↩", "c": "⌘Tab", "d": "⇧Space", "e": "Esc", "f": "⌫", "g": "⌘↑", "h": "⌘→", "i": "F1", "j": "⌥F19", "k": "⌘,", "l": ""}
	if err := WriteKeys(keys); err != nil {
		t.Fatal(err)
	}
}

func TestWriteKeysRefusesBadShapeAndWritesNothing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := WriteKeys(map[string]string{"ok": "⌘1"}); err != nil {
		t.Fatal(err)
	}
	path := appSettingsFile(t)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"R", "⌘", "⌘⌘R", "⌘⌃R", "⌘F20", "⌘F0", "⌘tab", "⌘AB"} {
		err := WriteKeys(map[string]string{"x": bad})
		msg, ok := IsUserError(err)
		if !ok {
			t.Errorf("chord %q: err = %v, want a UserError", bad, err)
			continue
		}
		if !strings.Contains(msg, `"x"`) || !strings.Contains(msg, `"`+bad+`"`) {
			t.Errorf("chord %q: %q does not name the id and chord", bad, msg)
		}
		after, _ := os.ReadFile(path)
		if string(after) != string(before) {
			t.Errorf("chord %q: file changed", bad)
		}
	}
}

func TestWriteKeysRefusesUnparseableFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	path := appSettingsFile(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := WriteKeys(map[string]string{"a": "⌘1"}); err == nil {
		t.Fatal("a write over an unparseable file was accepted")
	}
	if b, _ := os.ReadFile(path); string(b) != "{" {
		t.Errorf("file = %q, want it untouched", b)
	}
	if keys, appError := ReadKeys(); len(keys) != 0 || appError == "" {
		t.Errorf("ReadKeys() = %v, %q; want empty keys and the error", keys, appError)
	}
}

func TestEditorWriteKeepsKeys(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	want := map[string]string{"pane.close": "⌃⌘W"}
	if err := WriteKeys(want); err != nil {
		t.Fatal(err)
	}
	if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(14)}); err != nil {
		t.Fatal(err)
	}
	if got, _ := ReadKeys(); !reflect.DeepEqual(got, want) {
		t.Errorf("keys after an editor write = %v, want %v", got, want)
	}
}
