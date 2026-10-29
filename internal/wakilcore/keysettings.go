package wakilcore

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The keymap's overrides live in ~/.wakil/settings.json under "keys": command id to chord. The
// Swift keymap owns the ids, the defaults and the conflict rules; this file stores the map and
// checks only that each chord is well formed. An empty chord is a command the operator unbound;
// an id absent from the map keeps its default.

// keyModifiers is the modifier glyphs in the order a chord writes them.
const keyModifiers = "⌃⌥⇧⌘"

var (
	namedKeys    = []string{"↩", "Tab", "Space", "Esc", "⌫", "↑", "↓", "←", "→"}
	functionKeys = regexp.MustCompile(`^F([1-9]|1[0-9])$`)
)

// KeyboardSettings is what the keyboard tool answers. Keys is never nil. AppError is
// settings.json's read or parse error, whole; Keys is then empty.
type KeyboardSettings struct {
	Keys     map[string]string `json:"keys"`
	AppError string            `json:"appError"`
}

// ReadKeys reads the overrides. It never fails: an unreadable settings.json is returned as
// appError with no overrides.
func ReadKeys() (keys map[string]string, appError string) {
	app, err := LoadAppSettings()
	if err != nil {
		return map[string]string{}, err.Error()
	}
	keys = map[string]string{}
	for id, chord := range app.Keys {
		keys[id] = chord
	}
	return keys, ""
}

// validChord reports whether chord is "", or distinct modifiers in ⌃⌥⇧⌘ order then one key.
func validChord(chord string) bool {
	if chord == "" {
		return true
	}
	rest := chord
	last := -1
	for rest != "" {
		r, size := utf8.DecodeRuneInString(rest)
		i := strings.IndexRune(keyModifiers, r)
		if i < 0 || i <= last {
			break
		}
		last = i
		rest = rest[size:]
	}
	if rest == "" {
		return false // modifiers with no key
	}
	if slices.Contains(namedKeys, rest) || functionKeys.MatchString(rest) {
		return true
	}
	// A bare character is typing, not a shortcut: it needs a modifier.
	r, size := utf8.DecodeRuneInString(rest)
	return last >= 0 && size == len(rest) && r != utf8.RuneError && !strings.ContainsRune(keyModifiers, r)
}

// WriteKeys replaces the whole override map. A file that does not parse is refused rather than
// overwritten, as UpdateEditorAppSettings refuses it, and a malformed chord writes nothing.
func WriteKeys(keys map[string]string) error {
	current, err := LoadAppSettings()
	if err != nil {
		return UserError(err.Error() + " — fix or remove the file by hand; a write here would discard what it holds")
	}
	ids := make([]string, 0, len(keys))
	for id := range keys {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	for _, id := range ids {
		if !validChord(keys[id]) {
			return UserError(fmt.Sprintf("key %s: %s is not a chord — modifiers in the order ⌃⌥⇧⌘, then one key (a character, ↩ Tab Space Esc ⌫ ↑ ↓ ← →, or F1 to F19), or empty for unbound",
				strconv.Quote(id), strconv.Quote(keys[id])))
		}
	}
	current.Keys = keys
	path, err := appSettingsPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(current, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}
