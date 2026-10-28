package wakilcore

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Browser settings (3c-i) are the operator's, app-wide, in ~/.wakil/settings.json under
// "browser", beside "editor": the search engine the address bar uses for words that are not a
// URL, and the page a new tab opens ("" is blank). A missing file, key or field reads as its
// default. A write is read-modify-write from disk, so it keeps the "editor" key, and a refused
// write writes nothing.
const (
	DefaultBrowserSearchEngine = "google"
	DefaultBrowserStartPage    = ""
	// DefaultBrowserTabs is where the tab strip sits: along the top, or "vertical" down the side.
	DefaultBrowserTabs = "horizontal"
)

// BrowserSearchEngines maps each engine to the URL its query is appended to.
var BrowserSearchEngines = map[string]string{
	"google":     "https://www.google.com/search?q=",
	"duckduckgo": "https://duckduckgo.com/?q=",
	"bing":       "https://www.bing.com/search?q=",
	"kagi":       "https://kagi.com/search?q=",
}

// BrowserAppSettings is the app-wide browser tier as stored: zero values mean "the default".
type BrowserAppSettings struct {
	SearchEngine string `json:"searchEngine,omitempty"`
	StartPage    string `json:"startPage,omitempty"`
	// SearchSuggestions asks the search engine for suggestions as the operator types; off by default.
	SearchSuggestions bool `json:"searchSuggestions,omitempty"`
	// Tabs is "horizontal" or "vertical"; empty is horizontal.
	Tabs string `json:"tabs,omitempty"`
	// NameGroups asks the model to name automatic tab groups; nil is on, so a stored false is kept.
	NameGroups *bool `json:"nameGroups,omitempty"`
	// PictureInPicture floats a playing video when the operator leaves its tab; nil is the default, on.
	PictureInPicture *bool `json:"pictureInPicture,omitempty"`
}

// BrowserSettings is the tier with every default filled in — what browser_settings answers.
// AppError is settings.json's read or parse error, whole; the values are then the defaults.
type BrowserSettings struct {
	SearchEngine string `json:"searchEngine"`
	StartPage    string `json:"startPage"`
	// SearchSuggestions is false unless the operator turned it on.
	SearchSuggestions bool `json:"searchSuggestions"`
	// Tabs is "horizontal" or "vertical".
	Tabs string `json:"tabs"`
	// NameGroups is true unless the operator turned it off.
	NameGroups bool `json:"nameGroups"`
	// PictureInPicture is true unless the operator turned it off.
	PictureInPicture bool   `json:"pictureInPicture"`
	AppError         string `json:"appError,omitempty"`
}

func browserEngineNames() []string {
	names := make([]string, 0, len(BrowserSearchEngines))
	for n := range BrowserSearchEngines {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// startPageProblem answers why s cannot be a start page, or "" when it can. Blank is allowed;
// otherwise only an absolute http or https URL with a host.
func startPageProblem(s string) string {
	if s == "" {
		return ""
	}
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "start page " + strconv.Quote(s) + " is not an http or https URL — leave it empty for a blank page"
	}
	return ""
}

// Resolved fills the defaults. A stored value that breaks a rule — only a hand edit can put one
// there — reads as the default rather than reaching the browser.
func (s BrowserAppSettings) Resolved() BrowserSettings {
	v := BrowserSettings{SearchEngine: DefaultBrowserSearchEngine, StartPage: DefaultBrowserStartPage,
		Tabs: DefaultBrowserTabs, NameGroups: true, PictureInPicture: true}
	if _, ok := BrowserSearchEngines[s.SearchEngine]; ok {
		v.SearchEngine = s.SearchEngine
	}
	if startPageProblem(s.StartPage) == "" {
		v.StartPage = s.StartPage
	}
	v.SearchSuggestions = s.SearchSuggestions
	if s.Tabs == "horizontal" || s.Tabs == "vertical" {
		v.Tabs = s.Tabs
	}
	if s.NameGroups != nil {
		v.NameGroups = *s.NameGroups
	}
	if s.PictureInPicture != nil {
		v.PictureInPicture = *s.PictureInPicture
	}
	return v
}

// ReadBrowserSettings resolves the browser tier. It never fails: an unreadable settings.json is
// returned as appError with the defaults in place.
func ReadBrowserSettings() (BrowserSettings, string) {
	app, err := LoadAppSettings()
	v := app.Browser.Resolved()
	if err != nil {
		v.AppError = err.Error()
		return v, err.Error()
	}
	return v, ""
}

// BrowserSettingsPatch names the fields a write changes; nil leaves a field as it is on disk.
type BrowserSettingsPatch struct {
	SearchEngine *string
	StartPage    *string
	// SearchSuggestions turns engine suggestions on or off.
	SearchSuggestions *bool
	// Tabs is "horizontal" or "vertical".
	Tabs *string
	// NameGroups turns model naming of automatic tab groups on or off.
	NameGroups *bool
	// PictureInPicture turns floating a playing video on or off.
	PictureInPicture *bool
}

// WriteBrowserSettings applies p to settings.json, read from disk now, keeping every other key.
// A file that does not parse is refused rather than overwritten.
func WriteBrowserSettings(p BrowserSettingsPatch) error {
	if p.SearchEngine == nil && p.StartPage == nil && p.SearchSuggestions == nil &&
		p.Tabs == nil && p.NameGroups == nil && p.PictureInPicture == nil {
		return nil
	}
	current, err := LoadAppSettings()
	if err != nil {
		return UserError(err.Error() + " — fix or remove the file by hand; a write here would discard what it holds")
	}
	if p.SearchEngine != nil {
		if _, ok := BrowserSearchEngines[*p.SearchEngine]; !ok {
			return UserError("search engine " + strconv.Quote(*p.SearchEngine) + " is not one of " +
				strings.Join(browserEngineNames(), ", "))
		}
		current.Browser.SearchEngine = *p.SearchEngine
	}
	if p.StartPage != nil {
		sp := strings.TrimSpace(*p.StartPage)
		if msg := startPageProblem(sp); msg != "" {
			return UserError(msg)
		}
		current.Browser.StartPage = sp
	}
	if p.SearchSuggestions != nil {
		current.Browser.SearchSuggestions = *p.SearchSuggestions
	}
	if p.Tabs != nil {
		if *p.Tabs != "horizontal" && *p.Tabs != "vertical" {
			return UserError("tabs is horizontal or vertical, not " + strconv.Quote(*p.Tabs))
		}
		current.Browser.Tabs = *p.Tabs
	}
	if p.NameGroups != nil {
		v := *p.NameGroups
		current.Browser.NameGroups = &v
	}
	if p.PictureInPicture != nil {
		pip := *p.PictureInPicture
		current.Browser.PictureInPicture = &pip
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
