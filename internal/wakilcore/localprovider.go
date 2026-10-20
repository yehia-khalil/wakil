package wakilcore

import (
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const (
	QuickOpInfill  = "infill"
	QuickOpRespond = "respond"
)

const errLocalOnly = "baseURL and serves apply only to --kind local — only a local endpoint speaks /infill (Decision 42)"

// normaliseLocal trims and checks a local provider's URL and operations, filling the default.
func normaliseLocal(p *Provider) error {
	raw := strings.TrimRight(strings.TrimSpace(p.BaseURL), "/")
	u, err := url.Parse(raw)
	if raw == "" || err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return UserError("baseURL must be an http or https URL, e.g. http://127.0.0.1:8012; got " + strconv.Quote(p.BaseURL))
	}
	p.BaseURL = raw
	seen := map[string]bool{}
	out := []string{}
	for _, op := range p.Serves {
		op = strings.TrimSpace(op)
		if op != QuickOpInfill && op != QuickOpRespond {
			return UserError("serves: unknown operation " + strconv.Quote(op) + " — one of infill, respond")
		}
		if !seen[op] {
			seen[op] = true
			out = append(out, op)
		}
	}
	if len(out) == 0 {
		out = []string{QuickOpInfill}
	}
	sort.Strings(out) // infill < respond
	p.Serves = out
	return nil
}

// resolvedServes is what config_tree publishes: what the provider's kind can serve.
func resolvedServes(p Provider) []string {
	switch p.Kind {
	case ProviderKindClaudeCode:
		return []string{QuickOpInfill, QuickOpRespond}
	case ProviderKindLocal:
		if len(p.Serves) == 0 {
			return []string{QuickOpInfill}
		}
		return p.Serves
	default:
		return []string{}
	}
}

// SetLocalProvider creates or overrides org's local provider id (Ruling R1). It refuses an
// existing record of another kind: that is a different account, not this endpoint's settings.
func SetLocalProvider(org string, p Provider) error {
	if err := validateProviderToken(p.ID); err != nil {
		return err
	}
	p.Kind = ProviderKindLocal
	if err := normaliseLocal(&p); err != nil {
		return err
	}
	if existing, err := LoadProviderFor(org, p.ID); err == nil && existing.Kind != ProviderKindLocal {
		return UserError("provider " + strconv.Quote(p.ID) + " is a " + existing.Kind + " account, not a local endpoint")
	}
	dir, err := providersDirFor(org)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return writeProviderFile(filepath.Join(dir, p.ID+".json"), p)
}
