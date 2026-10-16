package wakilcore

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// Editor settings (3b-v, Decision 38) live in two tiers, split by who a setting belongs to.
//
//   - App-wide, the operator's own, in ~/.wakil/settings.json under "editor": font size, word
//     wrap, autosave, showing ignored files. The file is design-language §14's "Wakil" scope,
//     and its first.
//   - Per project, the code's, in project.json under "editor": tab size, tabs or spaces, and the
//     heavy folders, so a teammate gets the same values.
//
// A missing file, key or field reads as its default, so no install needs a migration. Every
// write is read-modify-write from disk at dispatch, and a refused write writes nothing — the
// rules UpdateOrg and SaveProject already follow.
const (
	AutosaveOff   = "off"
	AutosavePause = "pause"
	AutosaveFocus = "focus"

	DefaultEditorFontSize = 12
	MinEditorFontSize     = 9
	MaxEditorFontSize     = 24
	DefaultEditorTabSize  = 4
	MinEditorTabSize      = 1
	MaxEditorTabSize      = 16
)

const appSettingsFileName = "settings.json"

// DefaultHeavyFolders are the heavy folders of a project that names none — 3b-ii's fixed list,
// less .git, which is always heavy and never stored.
var DefaultHeavyFolders = []string{"vendor", "node_modules"}

// HeavyNames is what the file listing treats as heavy: .git, then the project's folders.
func HeavyNames(folders []string) []string {
	return append([]string{".git"}, folders...)
}

// AppSettings is ~/.wakil/settings.json. Keys this build does not know are dropped on a write,
// as SaveProject drops them.
type AppSettings struct {
	Editor EditorAppSettings `json:"editor"`
}

// EditorAppSettings is the app-wide tier as stored: zero values mean "the default".
type EditorAppSettings struct {
	FontSize    int    `json:"fontSize,omitempty"`
	WordWrap    bool   `json:"wordWrap,omitempty"`
	Autosave    string `json:"autosave,omitempty"`
	ShowIgnored *bool  `json:"showIgnored,omitempty"` // nil is the default, on
}

// EditorProjectSettings is the per-project tier as stored. InsertSpaces is a pointer because
// false (tabs) is a value and absent is the default (spaces); HeavyFolders likewise, because an
// empty list (only .git heavy) is a value and absent is DefaultHeavyFolders.
type EditorProjectSettings struct {
	TabSize      int       `json:"tabSize,omitempty"`
	InsertSpaces *bool     `json:"insertSpaces,omitempty"`
	HeavyFolders *[]string `json:"heavyFolders,omitempty"`
}

// EditorAppValues is the app-wide tier with every default filled in.
type EditorAppValues struct {
	FontSize    int    `json:"fontSize"`
	WordWrap    bool   `json:"wordWrap"`
	Autosave    string `json:"autosave"`
	ShowIgnored bool   `json:"showIgnored"`
}

// EditorProjectValues is one project's tier with every default filled in.
type EditorProjectValues struct {
	TabSize      int      `json:"tabSize"`
	InsertSpaces bool     `json:"insertSpaces"`
	HeavyFolders []string `json:"heavyFolders"`
}

// EditorSettings is both tiers resolved for the active project — what editor_settings answers.
// Flat rather than embedding the two halves, so the tool's derived output schema is one plain
// object. AppError is settings.json's read or parse error, whole; the values are then the
// defaults.
type EditorSettings struct {
	FontSize     int      `json:"fontSize"`
	WordWrap     bool     `json:"wordWrap"`
	Autosave     string   `json:"autosave"`
	ShowIgnored  bool     `json:"showIgnored"`
	TabSize      int      `json:"tabSize"`
	InsertSpaces bool     `json:"insertSpaces"`
	HeavyFolders []string `json:"heavyFolders"`
	AppError     string   `json:"appError,omitempty"`
}

// Resolved fills the defaults. A stored value outside its range — only a hand edit can put one
// there — reads as the default rather than reaching the editor.
func (s EditorAppSettings) Resolved() EditorAppValues {
	v := EditorAppValues{FontSize: DefaultEditorFontSize, WordWrap: s.WordWrap, Autosave: AutosaveOff, ShowIgnored: true}
	if s.FontSize >= MinEditorFontSize && s.FontSize <= MaxEditorFontSize {
		v.FontSize = s.FontSize
	}
	if validAutosave(s.Autosave) {
		v.Autosave = s.Autosave
	}
	if s.ShowIgnored != nil {
		v.ShowIgnored = *s.ShowIgnored
	}
	return v
}

// Resolved fills the defaults; a nil receiver (a project with no editor block) is every default.
// A stored heavy folder that breaks a rule — only a hand edit can put one there — is dropped, so
// no bad name reaches git's pathspecs.
func (s *EditorProjectSettings) Resolved() EditorProjectValues {
	v := EditorProjectValues{TabSize: DefaultEditorTabSize, InsertSpaces: true, HeavyFolders: slices.Clone(DefaultHeavyFolders)}
	if s == nil {
		return v
	}
	if s.TabSize >= MinEditorTabSize && s.TabSize <= MaxEditorTabSize {
		v.TabSize = s.TabSize
	}
	if s.InsertSpaces != nil {
		v.InsertSpaces = *s.InsertSpaces
	}
	if s.HeavyFolders != nil {
		v.HeavyFolders = []string{}
		for _, n := range *s.HeavyFolders {
			n = strings.TrimSpace(n)
			if heavyFolderProblem(n) == "" && !slices.Contains(v.HeavyFolders, n) {
				v.HeavyFolders = append(v.HeavyFolders, n)
			}
		}
	}
	return v
}

// heavyFolderProblem answers why name cannot be a heavy folder, or "" when it can.
func heavyFolderProblem(name string) string {
	switch {
	case name == "":
		return "a heavy folder needs a name"
	case strings.Contains(name, "/"):
		return "heavy folder " + strconv.Quote(name) + " is a path — give a folder name; it is matched at any depth"
	case name == "." || name == "..":
		return "heavy folder " + strconv.Quote(name) + " is not a folder name"
	case name == ".git":
		return ".git is always heavy — it needs no row"
	}
	return ""
}

// validHeavyFolders trims each name and answers the list, or the first rule a name breaks.
func validHeavyFolders(names []string) ([]string, error) {
	out := make([]string, 0, len(names))
	for _, n := range names {
		n = strings.TrimSpace(n)
		if p := heavyFolderProblem(n); p != "" {
			return nil, UserError(p)
		}
		if slices.Contains(out, n) {
			return nil, UserError("heavy folder " + strconv.Quote(n) + " is listed twice")
		}
		out = append(out, n)
	}
	return out, nil
}

func validAutosave(s string) bool {
	return s == AutosaveOff || s == AutosavePause || s == AutosaveFocus
}

func appSettingsPath() (string, error) {
	dir, err := WakilDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, appSettingsFileName), nil
}

// LoadAppSettings reads ~/.wakil/settings.json. No file is not an error: it is every default.
func LoadAppSettings() (AppSettings, error) {
	path, err := appSettingsPath()
	if err != nil {
		return AppSettings{}, err
	}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return AppSettings{}, nil
	}
	if err != nil {
		return AppSettings{}, fmt.Errorf("read %s: %w", path, err)
	}
	var s AppSettings
	if err := json.Unmarshal(b, &s); err != nil {
		return AppSettings{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return s, nil
}

// EditorAppPatch names the app-wide fields a write changes; nil leaves a field as it is on disk.
type EditorAppPatch struct {
	FontSize    *int
	WordWrap    *bool
	Autosave    *string
	ShowIgnored *bool
}

// UpdateEditorAppSettings applies p to settings.json, read from disk now. A file that does not
// parse is refused rather than overwritten: the operator wrote it by hand, and a write would
// discard what it holds.
func UpdateEditorAppSettings(p EditorAppPatch) error {
	if p.FontSize == nil && p.WordWrap == nil && p.Autosave == nil && p.ShowIgnored == nil {
		return nil
	}
	current, err := LoadAppSettings()
	if err != nil {
		return UserError(err.Error() + " — fix or remove the file by hand; a write here would discard what it holds")
	}
	if p.FontSize != nil {
		if *p.FontSize < MinEditorFontSize || *p.FontSize > MaxEditorFontSize {
			return UserError(fmt.Sprintf("font size %d is out of range: %d to %d",
				*p.FontSize, MinEditorFontSize, MaxEditorFontSize))
		}
		current.Editor.FontSize = *p.FontSize
	}
	if p.WordWrap != nil {
		current.Editor.WordWrap = *p.WordWrap
	}
	if p.Autosave != nil {
		if !validAutosave(*p.Autosave) {
			return UserError("autosave " + strconv.Quote(*p.Autosave) + " is not one of off, pause, focus")
		}
		current.Editor.Autosave = *p.Autosave
	}
	if p.ShowIgnored != nil {
		v := *p.ShowIgnored
		current.Editor.ShowIgnored = &v
	}
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

// EditorProjectPatch names the per-project fields a write changes.
type EditorProjectPatch struct {
	TabSize      *int
	InsertSpaces *bool
	HeavyFolders *[]string
}

// UpdateProjectEditorSettings applies p to the project file at projectPath, read from disk now.
// A project filed under another organisation is refused, as SetDatabaseDSN refuses one.
func UpdateProjectEditorSettings(projectPath string, p EditorProjectPatch) error {
	if p.TabSize == nil && p.InsertSpaces == nil && p.HeavyFolders == nil {
		return nil
	}
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	project, err := LoadProject(projectPath)
	if err != nil {
		return err
	}
	if project.Org != org {
		return UserError("project " + strconv.Quote(project.Name) + " belongs to org " +
			strconv.Quote(project.Org) + ", not " + strconv.Quote(org) +
			" — a project stored in another organisation is read-only here")
	}
	if p.TabSize != nil && (*p.TabSize < MinEditorTabSize || *p.TabSize > MaxEditorTabSize) {
		return UserError(fmt.Sprintf("tab size %d is out of range: %d to %d",
			*p.TabSize, MinEditorTabSize, MaxEditorTabSize))
	}
	var heavy []string
	if p.HeavyFolders != nil {
		if heavy, err = validHeavyFolders(*p.HeavyFolders); err != nil {
			return err
		}
	}
	if project.Editor == nil {
		project.Editor = &EditorProjectSettings{}
	}
	if p.TabSize != nil {
		project.Editor.TabSize = *p.TabSize
	}
	if p.InsertSpaces != nil {
		v := *p.InsertSpaces
		project.Editor.InsertSpaces = &v
	}
	if p.HeavyFolders != nil {
		project.Editor.HeavyFolders = &heavy
	}
	return SaveProject(projectPath, *project)
}

// LoadEditorSettings resolves both tiers for the active project. It never fails: an unreadable
// settings.json is reported in AppError with the defaults in place, and no active project means
// the project defaults.
func LoadEditorSettings() EditorSettings {
	var out EditorSettings
	app, err := LoadAppSettings()
	if err != nil {
		out.AppError = err.Error()
	}
	a := app.Editor.Resolved()
	out.FontSize, out.WordWrap, out.Autosave, out.ShowIgnored = a.FontSize, a.WordWrap, a.Autosave, a.ShowIgnored
	var project *EditorProjectSettings
	if r, err := Resolve(); err == nil && r.Project != nil {
		project = r.Project.Editor
	}
	pv := project.Resolved()
	out.TabSize, out.InsertSpaces, out.HeavyFolders = pv.TabSize, pv.InsertSpaces, pv.HeavyFolders
	return out
}
