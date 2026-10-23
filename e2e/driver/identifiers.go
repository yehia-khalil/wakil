package driver

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// Surfaces are the registered identifier namespaces, and the list is the
// contract rather than a convenience.
//
// **An identifier's first segment must be one of these.** Two things follow
// from that, and both are the point:
//
//   - The harvester can find identifiers by their shape alone, with no Swift
//     parsing. `app/Sources/WakilApp` is full of dotted lowercase literals
//     that are not identifiers — "xmark.circle", "magnifyingglass",
//     "exclamationmark.triangle" are SF Symbol names — and a grammar that
//     accepted any dotted literal would count them.
//   - A new surface cannot arrive unnamespaced. It is added here, once,
//     deliberately, in the same change that first names one of its controls.
//
// `provider` is reserved and carries nothing on `main`: the provider sign-in
// row #250 names is #236/#238, which has not landed. It is listed so that the
// branch carrying it does not have to argue for its own namespace.
var Surfaces = []string{
	// The api pane's own namespace, added in the change that first names
	// one of its controls — which is what the paragraph above asks for.
	// It is its own surface rather than `pane.api.*` on `settings`'
	// precedent: a pane KIND with its own vocabulary namespaces itself,
	// where `pane` is the chrome every kind shares.
	"api",
	// The branch picker's own namespace (3a-iv): `branch.picker.filter`, its rows
	// `branch.picker.row.<name>`, the blocked-switch and delete choices. One picker
	// opens from the context line and from a Changes header, so it is neither
	// `window` nor `editor`. Added by the Cover rung, on `editor`'s precedent: without
	// it no check can name a picker control and the gate cannot count them.
	"branch",
	// The data surface's own namespace, added in the change that first names
	// one of its controls — the row grip, `db.row.<i>.grip` (2c-iv, #308). A
	// grid row is the db pane's vocabulary, not chrome every kind shares, so
	// it is `db` on `api`'s precedent rather than `pane.db.*`.
	"db",
	// The editor pane's own namespace (3b-i), on `api`'s and `db`'s precedent:
	// tabs `editor.tab.<i>`, the disk line's Reload and Compare, the save-as
	// field and the unsaved prompt's three buttons. Added by the Cover rung:
	// without it the resolver drops every one of them from the tree it reads,
	// so no check could press them and the gate could not count them.
	//
	// 3b-iii folded the Git pane into the editor's Changes view, so what was
	// the `git` namespace (3a-i: `git.row:…`, `git.mark:…`) is gone with the
	// pane kind, and its rows are named here: `editor.changes.root:<root>`,
	// `editor.changes.row:<root>/<path>:<group>`, and a diff tab's lines
	// `editor.diff.*`. No `git.` identifier is left in the app to harvest.
	"editor",
	"landing",
	"org",
	"palette",
	"pane",
	"provider",
	"rail",
	"settings",
	"window",
}

// AuditedSources are the files whose actionable controls must all be named.
//
// **Scoped on purpose, and the scope is how a surface joins.** #250 covers the
// surfaces 2c-iii touches; the rest of the app arrives as each surface is
// worked. The design's own reasoning (§2): a gate that demanded the whole tree
// on day one would be switched off within a week, which is how the first
// north-star word limit failed. Adding a file here is the deliberate act that
// puts it under the gate, and it belongs in the change that names its
// controls — never in a change that merely touches it.
var AuditedSources = []string{
	// 2c-iv joins here, in the change that gave the api pane its first
	// control — the deliberate act this list's comment asks for. Until
	// then the pane drew only `Text` and had nothing to name: the
	// coverage gate could not ask, and #296's audit recorded the whole
	// pane as residue for exactly that reason.
	"ApiPane.swift",
	// The split (2c-iv 9c, Task 1) moved the pane's controls into one file per region;
	// each is under the gate, or the denominator goes blind on everything moved.
	"ApiPane+Fields.swift",
	"ApiPane+Request.swift",
	"ApiPane+Sending.swift",
	// Amendment 10 (2c-iv, Task 6): every field is one editor, and a token's `×` is named
	// in the editor's own files — `api.<key>.part.<i>.remove` / `.unbind` in the token view.
	"ApiFieldEditor.swift",
	"ApiTokenView.swift",
	// 3b-i joins here, in the Cover rung that named its surface `editor`. The
	// unsaved prompt (`UnsavedPromptBar`) lives in this file too, so the
	// window-level prompt's buttons are under the gate with the pane's.
	"EditorPane.swift",
	// 3b-iii joins the column here, in the Cover rung for the Changes view
	// that lives in it: the Files tree's rows, the Search view and the
	// Changes rows and root headers were named since 3b-ii, but the file sat
	// outside the gate, so a new tap target there could arrive unnamed.
	"EditorColumn.swift",
	// 3a-iv joins its two new files here, in the Cover rung that named the `branch` surface: the
	// picker (one view, opened from the context line and from a Changes header) and the Changes
	// view's in-place name field and Stashes group. Both were born named; listed so a control added
	// to either later cannot arrive unnamed.
	"BranchPicker.swift",
	"ChangesStashes.swift",
	"Landing.swift",
	"OrgPlane.swift",
	"Palettes.swift",
	"Rail.swift",
	"WakilWindow.swift",
	// 2e joins the gate here, in the change that named its controls — the
	// deliberate act this list's comment asks for. The settings pane had
	// thirty-odd actionable controls and not one identifier, which is a
	// VoiceOver defect with or without a harness.
	"SettingsPane.swift",
	"TerminalPane.swift",
	// 2d-ii joins the composer bar, in the change that named it. It holds no
	// constructor today — the field is an `NSTextView` behind an
	// `NSViewRepresentable`, which this audit cannot see at all, so
	// `window.composer` is named and NOT counted here; the identifier harvest
	// is what holds it. Listed so the first SwiftUI control added to the bar
	// is under the gate from the day it lands.
	//
	// `ThoughtThread.swift` is NOT listed, and the reason is a finding rather
	// than a choice: its row label column carries a second, pointer-only
	// toggle (`.onTapGesture` on the label `Text`) that this gate flags as
	// unnamed. The row's own accessibility action already toggles, so naming
	// the label would add a redundant button per row; dropping its tap is a
	// design call. Until one is made, its named controls are held by the
	// identifier harvest and the coverage gate, not by this audit.
	"ComposerBar.swift",
}

// Identifier is one accessibility identifier, as the source spells it.
type Identifier struct {
	// Name is the literal, with every `\(...)` interpolation replaced by
	// `<…>`. So `"pane.\(pane.id).reopen"` harvests as `pane.<…>.reopen`.
	Name string
	// Dynamic reports whether Name carries a placeholder. A dynamic
	// identifier is a family, not an address: the driver resolves a concrete
	// one against the live tree, and the harvester can only ever say the
	// family exists.
	Dynamic bool
	File    string
	Line    int
}

// interpolation matches a `\(...)` segment of a Swift string literal.
//
// Deliberately non-greedy and deliberately not brace-balanced: every
// interpolation in an identifier is a simple property read, and a nested
// parenthesis inside one would be a good reason to hoist it into a `let`
// rather than a good reason for a parser here.
var interpolation = regexp.MustCompile(`\\\([^)]*\)`)

// identifierLiteral matches a whole string literal on one line.
var identifierLiteral = regexp.MustCompile(`"([^"\\]|\\\(|\\[^(])*"`)

// HarvestIdentifiers lists every identifier under root, sorted by name.
//
// root is a directory of Swift sources — `app/Sources/WakilApp`. **This is the
// control denominator** (design §2): coverage of controls is measured against
// what this returns, so a run that returns nothing means the denominator is
// zero and control coverage is vacuous rather than met.
//
// **It descends, and that is the coverage gate's requirement rather than a
// nicety** (#256). The gate compares this harvest against the same harvest of
// the merge-base, which is read through `git ls-tree -r` and therefore always
// descends. A reader that stopped at the top level would miss, at head only,
// every control in the first subdirectory anyone adds — so those controls
// would never read as new, and the gate would pass by being blind about the
// newest code in the tree. `app/Sources/WakilApp` is flat today; nothing
// guarantees it stays that way, and the failure is silent when it does not.
func HarvestIdentifiers(root string) ([]Identifier, error) {
	var found []Identifier
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".swift" {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		// The base name, not the path: the gate reports a control as
		// `Rail.swift:12`, and the tree-side harvest can only ever know the
		// base name — comparing the two by a name that differed between them
		// would report every control in a subdirectory as new.
		found = append(found, IdentifiersIn(entry.Name(), string(data))...)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("harvesting identifiers: %w", err)
	}
	sort.Slice(found, func(i, j int) bool {
		if found[i].Name != found[j].Name {
			return found[i].Name < found[j].Name
		}
		if found[i].File != found[j].File {
			return found[i].File < found[j].File
		}
		return found[i].Line < found[j].Line
	})
	return found, nil
}

// IdentifiersIn harvests one file's identifiers.
//
// **It reads literals, not call structure**, and that is what lets it see all
// three shapes the app uses: a literal handed straight to
// `.accessibilityIdentifier`, a literal built by interpolation, and a literal
// handed to a helper that applies the modifier for it — `OrgPlane`'s
// `button(_:id:)` requires the name as an argument precisely so that omitting
// one does not compile. A harvester that only read `.accessibilityIdentifier(`
// call sites would miss every one of the second kind and report a denominator
// eight controls short.
//
// The cost of reading literals is that the grammar has to be narrow enough to
// exclude everything else in the file, which is what Surfaces buys.
func IdentifiersIn(file, source string) []Identifier {
	var found []Identifier
	for index, line := range strings.Split(source, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "//") {
			continue
		}
		for _, quoted := range identifierLiteral.FindAllString(line, -1) {
			name, ok := identifierName(quoted)
			if !ok {
				continue
			}
			found = append(found, Identifier{
				Name:    name,
				Dynamic: strings.Contains(name, "<…>"),
				File:    file,
				Line:    index + 1,
			})
		}
	}
	return found
}

// identifierName turns a quoted Swift literal into an identifier name, or
// reports that the literal is not one.
func identifierName(quoted string) (string, bool) {
	body := strings.TrimSuffix(strings.TrimPrefix(quoted, `"`), `"`)
	name := interpolation.ReplaceAllString(body, "<…>")
	// **No identifier in this app holds whitespace, and JavaScript does.**
	// 3a-i's Monaco host builds JS in Swift literals — `"window.wakilProbe =
	// true;"` — which begin with a surface (`window`) and a dot, and so read
	// as two new controls that no check could ever press: a gate red for a
	// denominator that was wrong, not for surface that was uncovered.
	if strings.IndexFunc(name, unicode.IsSpace) >= 0 {
		return "", false
	}
	segments := strings.Split(name, ".")
	if len(segments) < 2 {
		return "", false
	}
	if !isSurface(segments[0]) {
		return "", false
	}
	for _, segment := range segments[1:] {
		if segment == "" {
			return "", false
		}
	}
	return name, true
}

func isSurface(segment string) bool {
	for _, surface := range Surfaces {
		if segment == surface {
			return true
		}
	}
	return false
}
