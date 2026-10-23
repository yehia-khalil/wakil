package wakilcore

import (
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	QuickOpInfill  = "infill"
	QuickOpRespond = "respond"
)

const errLocalOnly = "baseURL applies only to --kind local — only a local endpoint speaks /infill"

// normaliseLocal trims and checks a local provider's URL and drops the retired serves field.
func normaliseLocal(p *Provider) error {
	raw := strings.TrimRight(strings.TrimSpace(p.BaseURL), "/")
	u, err := url.Parse(raw)
	if raw == "" || err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return UserError("baseURL must be an http or https URL, e.g. http://127.0.0.1:8012; got " + strconv.Quote(p.BaseURL))
	}
	p.BaseURL = raw
	// 3b-ix: one model per org does every quick task, so a local provider serves both
	// operations. A record that still carries serves loads; the field is dropped on write.
	p.Serves = nil
	return nil
}

// resolvedServes is what config_tree publishes: what the provider's kind can serve.
func resolvedServes(p Provider) []string {
	switch p.Kind {
	case ProviderKindClaudeCode, ProviderKindLocal:
		return []string{QuickOpInfill, QuickOpRespond}
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
