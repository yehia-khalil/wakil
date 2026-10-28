package wakilcore

import (
	"os"
	"strings"
	"testing"
)

func TestBrowserSettingsDefaults(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	got, appErr := ReadBrowserSettings()
	if appErr != "" || got.SearchEngine != "google" || got.StartPage != "" {
		t.Errorf("ReadBrowserSettings() = %+v, %q; want google, blank, no error", got, appErr)
	}
}

func TestSetBrowserSettingsKeepsEditorKey(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(15)}); err != nil {
		t.Fatal(err)
	}
	if err := WriteBrowserSettings(BrowserSettingsPatch{SearchEngine: strp("kagi")}); err != nil {
		t.Fatal(err)
	}
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if s.Editor.FontSize != 15 || s.Browser.SearchEngine != "kagi" {
		t.Errorf("settings = %+v; the editor key must survive a browser write", s)
	}
	// And the other way round.
	if err := UpdateEditorAppSettings(EditorAppPatch{WordWrap: boolp(true)}); err != nil {
		t.Fatal(err)
	}
	if got, _ := ReadBrowserSettings(); got.SearchEngine != "kagi" {
		t.Errorf("browser key lost by an editor write: %+v", got)
	}
}

func TestSetBrowserSettingsRefusesUnknownEngine(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	err := WriteBrowserSettings(BrowserSettingsPatch{SearchEngine: strp("yahoo")})
	if err == nil {
		t.Fatal("yahoo was accepted")
	}
	for _, n := range []string{"bing", "duckduckgo", "google", "kagi"} {
		if !strings.Contains(err.Error(), n) {
			t.Errorf("error %q does not name %s", err, n)
		}
	}
	if _, statErr := os.Stat(appSettingsFile(t)); statErr == nil {
		t.Error("a refused write wrote a file")
	}
}

func TestSetBrowserSettingsRefusesAStartPageThatIsNotAURL(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, bad := range []string{"not a url", "ftp://example.com", "file:///etc/passwd", "javascript:alert(1)"} {
		if err := WriteBrowserSettings(BrowserSettingsPatch{StartPage: strp(bad)}); err == nil {
			t.Errorf("start page %q was accepted", bad)
		}
	}
	for _, ok := range []string{"", "https://example.com", "http://localhost:3000"} {
		if err := WriteBrowserSettings(BrowserSettingsPatch{StartPage: strp(ok)}); err != nil {
			t.Errorf("start page %q refused: %v", ok, err)
		}
	}
	if got, _ := ReadBrowserSettings(); got.StartPage != "http://localhost:3000" {
		t.Errorf("StartPage = %q", got.StartPage)
	}
}

func TestBrowserSettingsSearchSuggestionsDefaultsOff(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	got, appErr := ReadBrowserSettings()
	if appErr != "" || got.SearchSuggestions {
		t.Errorf("ReadBrowserSettings() = %+v, %q; want searchSuggestions false", got, appErr)
	}
}

func TestWriteBrowserSettingsSearchSuggestionsKeepsOtherKeys(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(15)}); err != nil {
		t.Fatal(err)
	}
	if err := WriteBrowserSettings(BrowserSettingsPatch{SearchEngine: strp("kagi")}); err != nil {
		t.Fatal(err)
	}
	on := true
	if err := WriteBrowserSettings(BrowserSettingsPatch{SearchSuggestions: &on}); err != nil {
		t.Fatal(err)
	}
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if !s.Browser.SearchSuggestions || s.Browser.SearchEngine != "kagi" || s.Editor.FontSize != 15 {
		t.Errorf("settings = %+v; searchSuggestions on, searchEngine and editor must survive", s)
	}
	if got, _ := ReadBrowserSettings(); !got.SearchSuggestions {
		t.Errorf("ReadBrowserSettings() = %+v; want searchSuggestions true", got)
	}
}

func TestBrowserSettingsTabsAndNamingDefaults(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	got, appErr := ReadBrowserSettings()
	if appErr != "" || got.Tabs != "horizontal" || !got.NameGroups {
		t.Errorf("ReadBrowserSettings() = %+v, %q; want horizontal, nameGroups true", got, appErr)
	}
	// A hand edit that breaks the rule reads as the default.
	if got := (BrowserAppSettings{Tabs: "diagonal"}).Resolved(); got.Tabs != "horizontal" {
		t.Errorf("tabs diagonal resolved to %q; want horizontal", got.Tabs)
	}
	if got := (BrowserAppSettings{Tabs: "vertical"}).Resolved(); got.Tabs != "vertical" {
		t.Errorf("tabs vertical resolved to %q", got.Tabs)
	}
}

func TestWriteBrowserSettingsTabsRefusesUnknown(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	err := WriteBrowserSettings(BrowserSettingsPatch{Tabs: strp("grid")})
	if err == nil || err.Error() != `tabs is horizontal or vertical, not "grid"` {
		t.Fatalf("err = %v; want the tabs refusal", err)
	}
	if got, _ := ReadBrowserSettings(); got.Tabs != "horizontal" {
		t.Errorf("tabs = %q after a refused write", got.Tabs)
	}
	path, _ := appSettingsPath()
	if _, statErr := os.Stat(path); statErr == nil {
		t.Error("a refused write created settings.json")
	}
	if err := WriteBrowserSettings(BrowserSettingsPatch{Tabs: strp("vertical")}); err != nil {
		t.Fatal(err)
	}
	if got, _ := ReadBrowserSettings(); got.Tabs != "vertical" {
		t.Errorf("tabs = %q; want vertical", got.Tabs)
	}
}

func TestWriteBrowserSettingsNameGroupsFalseIsKept(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(15)}); err != nil {
		t.Fatal(err)
	}
	if err := WriteBrowserSettings(BrowserSettingsPatch{SearchEngine: strp("kagi")}); err != nil {
		t.Fatal(err)
	}
	off := false
	if err := WriteBrowserSettings(BrowserSettingsPatch{NameGroups: &off}); err != nil {
		t.Fatal(err)
	}
	path, _ := appSettingsPath()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"nameGroups": false`) {
		t.Errorf("settings.json = %s; want \"nameGroups\": false stored", b)
	}
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if s.Browser.SearchEngine != "kagi" || s.Editor.FontSize != 15 {
		t.Errorf("settings = %+v; searchEngine and editor must survive", s)
	}
	if got, _ := ReadBrowserSettings(); got.NameGroups {
		t.Errorf("ReadBrowserSettings() = %+v; want nameGroups false", got)
	}
}

func TestBrowserSettingsPictureInPictureDefaultsOn(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	got, appErr := ReadBrowserSettings()
	if appErr != "" || !got.PictureInPicture {
		t.Errorf("ReadBrowserSettings() = %+v, %q; want pictureInPicture true", got, appErr)
	}
}

func TestWriteBrowserSettingsPictureInPictureOffKeepsOtherKeys(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(15)}); err != nil {
		t.Fatal(err)
	}
	on := true
	if err := WriteBrowserSettings(BrowserSettingsPatch{SearchEngine: strp("kagi"), SearchSuggestions: &on}); err != nil {
		t.Fatal(err)
	}
	off := false
	if err := WriteBrowserSettings(BrowserSettingsPatch{PictureInPicture: &off}); err != nil {
		t.Fatal(err)
	}
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if s.Browser.PictureInPicture == nil || *s.Browser.PictureInPicture ||
		s.Browser.SearchEngine != "kagi" || !s.Browser.SearchSuggestions || s.Editor.FontSize != 15 {
		t.Errorf("settings = %+v; pictureInPicture off, searchEngine, searchSuggestions and editor must survive", s)
	}
	if got, _ := ReadBrowserSettings(); got.PictureInPicture {
		t.Errorf("ReadBrowserSettings() = %+v; want pictureInPicture false", got)
	}
}

func TestWriteBrowserSettingsPictureInPictureOnlyIsNotANoOp(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	off := false
	if err := WriteBrowserSettings(BrowserSettingsPatch{PictureInPicture: &off}); err != nil {
		t.Fatal(err)
	}
	if got, _ := ReadBrowserSettings(); got.PictureInPicture {
		t.Errorf("ReadBrowserSettings() = %+v; a patch with only pictureInPicture must write", got)
	}
}
