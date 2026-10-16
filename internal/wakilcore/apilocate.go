package wakilcore

import (
	"net/url"
	"sort"
	"strings"
)

type APILocation struct {
	Found       bool     `json:"found"`
	Active      bool     `json:"active"`
	Environment string   `json:"environment"`
	Entry       string   `json:"entry,omitempty"`
	Path        string   `json:"path"`
	Host        string   `json:"host"`
	Entries     []string `json:"entries"`
	// NoHost: the URL has no host to place (scheme-less, or unparsable). Swift refuses it in
	// those words rather than as a host no entry has.
	NoHost bool `json:"noHost"`
	// PastedHost and EntryHost are set only when the match forgave a leading `www.`: the host
	// as pasted, and the entry's own host. The request still goes to the entry's base URL.
	PastedHost string `json:"pastedHost,omitempty"`
	EntryHost  string `json:"entryHost,omitempty"`
}

// LocateAPIURL answers which API entry a URL belongs to (Amendment 11b): the same origin
// (scheme, host, port — host case and the scheme's default port normalized), and the URL's
// path at or under the entry's base path, by whole segments. An exact host in any environment beats a www. match; the active environment first;
// the longest base path wins. Then the other environments, by name. It reads the given
// project and nothing else.
func LocateAPIURL(p Project, activeEnv, rawURL string) APILocation {
	loc := APILocation{Environment: activeEnv}
	for _, e := range p.Environments[activeEnv].API {
		loc.Entries = append(loc.Entries, e.Name)
	}
	sort.Strings(loc.Entries)
	u, err := url.Parse(rawURL)
	if err != nil || u.Hostname() == "" {
		loc.NoHost = true
		return loc
	}
	loc.Host = u.Hostname()

	names := make([]string, 0, len(p.Environments))
	for name := range p.Environments {
		if name != activeEnv {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	order := append([]string{activeEnv}, names...)
	// An exact host in ANY environment beats a www.-equivalent one: exact in the active
	// environment, exact elsewhere (by name), then the same two for the www. rule.
	for _, www := range []bool{false, true} {
		for _, name := range order {
			if m, ok := matchEntry(p.Environments[name].API, u, www); ok {
				loc.Found, loc.Active, loc.Environment, loc.Entry, loc.Path =
					true, name == activeEnv, name, m.entry, m.rest
				loc.PastedHost, loc.EntryHost = m.pasted, m.entryHost
				return loc
			}
		}
	}
	return loc
}

type entryMatch struct {
	entry, rest, pasted, entryHost string
}

// matchEntry: the best entry of one environment, by exact host or (www) by a host that differs
// only by a leading `www.` — pasted/entryHost then name the change.
func matchEntry(entries []ApiConfig, u *url.URL, www bool) (entryMatch, bool) {
	entry, rest, host, ok := bestEntry(entries, u, www)
	if !ok {
		return entryMatch{}, false
	}
	if !www {
		return entryMatch{entry: entry, rest: rest}, true
	}
	return entryMatch{entry: entry, rest: rest, pasted: u.Hostname(), entryHost: host}, true
}

func bestEntry(entries []ApiConfig, u *url.URL, www bool) (string, string, string, bool) {
	best, bestLen, rest, host, found := "", -1, "", "", false
	for _, e := range entries {
		base, err := url.Parse(e.BaseURL)
		if err != nil || !sameOrigin(base, u, www) {
			continue
		}
		bp := strings.TrimSuffix(base.EscapedPath(), "/")
		up := u.EscapedPath()
		if bp != "" && up != bp && !strings.HasPrefix(up, bp+"/") {
			continue
		}
		if len(bp) > bestLen {
			best, bestLen, found, host = e.Name, len(bp), true, base.Hostname()
			rest = strings.TrimPrefix(up, bp)
			if u.RawQuery != "" {
				rest += "?" + u.RawQuery
			}
		}
	}
	return best, rest, host, found
}

func sameOrigin(a, b *url.URL, www bool) bool {
	if !strings.EqualFold(a.Scheme, b.Scheme) {
		return false
	}
	ha, hb := a.Hostname(), b.Hostname()
	if www {
		ha, hb = stripWww(ha), stripWww(hb)
	}
	if !strings.EqualFold(ha, hb) {
		return false
	}
	return effectivePort(a) == effectivePort(b)
}

func effectivePort(u *url.URL) string {
	if p := u.Port(); p != "" {
		return p
	}
	switch strings.ToLower(u.Scheme) {
	case "https":
		return "443"
	case "http":
		return "80"
	}
	return ""
}

// stripWww drops ONE leading `www.`, case-insensitively; no other subdomain is forgiven.
func stripWww(h string) string {
	if len(h) > 4 && strings.EqualFold(h[:4], "www.") {
		return h[4:]
	}
	return h
}
