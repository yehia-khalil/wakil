package driver

import "strings"

// FixtureRootToken is what a check writes where it means "this run's fixture
// root".
//
// **A check cannot hardcode the path, and the two actions that need one are
// not otherwise reachable.** Every run lays its fixture under a fresh
// directory — `/var/folders/…/wakil-e2e1855883569/` — because two runs sharing
// one would share a keychain, a HOME and a staged bundle. So the seeded
// project's file is at a different absolute path every time, and `db_set_dsn`
// and `db_remove_database` both take a `projectPath`: without this they can be
// dispatched only with a path that is wrong by construction, which tests the
// error branch and nothing else.
//
// **Only named values, and only in `dispatch` and `parity` params.** A
// general templating language in a check file would be a second thing to learn
// and a place for logic to accumulate; this is one name for one value the
// check could not otherwise know. Acts and assertions take no expansion,
// because nothing an operator clicks or reads carries this path.
const FixtureRootToken = "{fixtureRoot}"

// ChatStubToken is what a check writes where it means "this launch's chat
// stub": the origin of the loopback `/v1/chat/completions` server a seeded
// launch starts (StartChatStub). Its port changes on every launch, so a check
// that points a local model at it — `ctx_set_local_provider` with
// `baseURL: "{chatStub}"` — could not otherwise name it.
const ChatStubToken = "{chatStub}"

// PageStubToken is what a check writes where it means "this launch's page
// stub": the loopback origin StartPageStub serves the browser checks' pages
// from. Its port changes on every launch, like the chat stub's.
//
// **The tokens typed text may carry** (this and PageStubLiveToken), as well as params. The rule above
// holds because nothing an operator types carries a fixture path; a browser
// operator types a URL, and the address field is what the browser checks
// drive — a check that could only dispatch `browser_navigate` would never
// press Return in the field. See ExpandText.
const PageStubToken = "{pageStub}"

// PageStubLiveToken is the page stub under the name `localhost` rather than its loopback address:
// `http://localhost:<the stub's port>`, the origin of the seeded production project's `site` entry
// (SeedSpec.BrowserSites). A tab opened there is a different host from PageStubToken's, so the
// agent's consent for one never covers the other.
const PageStubLiveToken = "{pageStubLive}"

// PageStubLive turns the page stub's origin into its `localhost` twin. Empty stays empty, so a
// Runner without a stub leaves the token alone.
func PageStubLive(origin string) string {
	if _, port, ok := strings.Cut(strings.TrimPrefix(origin, "http://"), ":"); ok && origin != "" {
		return "http://localhost:" + port
	}
	return ""
}

// ExpandText replaces PageStubToken in the text a keystroke arm types, and no
// other token: the fixture root and the chat stub are not things an operator
// types, so they stay literal and a check that types one fails on it.
func ExpandText(text string, tokens map[string]string) string {
	for _, token := range []string{PageStubToken, PageStubLiveToken} {
		if value := tokens[token]; value != "" {
			text = strings.ReplaceAll(text, token, value)
		}
	}
	return text
}

// ExpandParams replaces each token in every string a params map carries,
// however deeply nested.
//
// Nested because params are arbitrary JSON and a path can travel inside an
// object or an array; a top-level-only substitution would work for today's two
// callers and quietly fail the first one that nests.
//
// A token whose value is "" is left untouched: the unit tests build a Runner
// with no fixture, and a check that names the token there should fail on the
// value it actually sent rather than on a silent empty expansion.
func ExpandParams(params map[string]interface{}, tokens map[string]string) map[string]interface{} {
	var pairs []string
	for token, value := range tokens {
		if value != "" {
			pairs = append(pairs, token, value)
		}
	}
	if params == nil || len(pairs) == 0 {
		return params
	}
	return expandMap(params, strings.NewReplacer(pairs...))
}

func expandMap(params map[string]interface{}, r *strings.Replacer) map[string]interface{} {
	expanded := make(map[string]interface{}, len(params))
	for key, value := range params {
		expanded[key] = expandValue(value, r)
	}
	return expanded
}

func expandValue(value interface{}, r *strings.Replacer) interface{} {
	switch typed := value.(type) {
	case string:
		return r.Replace(typed)
	case map[string]interface{}:
		return expandMap(typed, r)
	case []interface{}:
		out := make([]interface{}, len(typed))
		for i, element := range typed {
			out[i] = expandValue(element, r)
		}
		return out
	default:
		return value
	}
}
