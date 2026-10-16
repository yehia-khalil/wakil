package wakilcore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Capacity is how much of a provider account's rate-limit windows is left.
// It is keyed by the ACCOUNT — the config dir (Decision 32) — not by the
// org, because one Claude account may serve several orgs (Decision 22) and
// its limits are the same in each. It is not a credential, so sharing it
// across orgs does not touch Invariant 4's boundary.

const (
	CapacityRead     = "read"
	CapacityNotRead  = "notRead"
	CapacityNoLimits = "noLimits"
	CapacityError    = "error"
)

// CapacityWindow is one window. Times are RFC 3339 UTC strings with whole
// seconds, on the wire and on disk: a Swift ISO 8601 decoder rejects
// fractional seconds, and a string field keeps the MCP schema plain.
type CapacityWindow struct {
	PercentLeft int    `json:"percentLeft"`
	ResetsAt    string `json:"resetsAt"`
}

// CapacityRecord is what record_capacity stores for one account.
type CapacityRecord struct {
	FiveHour *CapacityWindow `json:"fiveHour,omitempty"`
	SevenDay *CapacityWindow `json:"sevenDay,omitempty"`
	Month    *CapacityWindow `json:"month,omitempty"`
	AsOf     string          `json:"asOf"`
}

type capacityFile struct {
	ConfigDir string `json:"configDir"`
	CapacityRecord
}

// CapacityReading is one provider's row in the `capacity` answer.
type CapacityReading struct {
	Account  string          `json:"account"`
	Kind     string          `json:"kind"`
	State    string          `json:"state"`
	FiveHour *CapacityWindow `json:"fiveHour,omitempty"`
	SevenDay *CapacityWindow `json:"sevenDay,omitempty"`
	Month    *CapacityWindow `json:"month,omitempty"`
	AsOf     string          `json:"asOf,omitempty"`
	Error    string          `json:"error,omitempty"`
}

type CapacityListing struct {
	Readings []CapacityReading `json:"readings"`
}

// codexReader is ReadCodexCapacity, held in a variable so the store's tests
// never scan the real ~/.codex.
var codexReader = func() (CapacityReading, bool, error) { return ReadCodexCapacity(codexSessionsDir()) }

func capacityPath(configDir string) (string, error) {
	dir, err := WakilDir()
	if err != nil {
		return "", err
	}
	// Resolved, as AddProvider records it: on macOS /var is a symlink to
	// /private/var, and one account must map to one file however it is spelled.
	key := filepath.Clean(configDir)
	if resolved, err := filepath.EvalSymlinks(key); err == nil {
		key = resolved
	}
	sum := sha256.Sum256([]byte(key))
	return filepath.Join(dir, "capacity", hex.EncodeToString(sum[:])[:16]+".json"), nil
}

// wholeSecondUTC is the one spelling stored and returned: RFC 3339, UTC,
// whole seconds. Swift's .iso8601 decoder rejects fractional seconds, and one
// bad time would drop the whole listing.
func wholeSecondUTC(t time.Time) string {
	return t.UTC().Truncate(time.Second).Format(time.RFC3339)
}

// validWindow checks a window and returns it with its time normalised.
func validWindow(w CapacityWindow) (CapacityWindow, error) {
	if w.PercentLeft < 0 || w.PercentLeft > 100 {
		return w, UserError(fmt.Sprintf("percentLeft %d is outside 0…100", w.PercentLeft))
	}
	t, err := time.Parse(time.RFC3339, w.ResetsAt)
	if err != nil {
		return w, UserError("resetsAt " + w.ResetsAt + " is not an RFC 3339 time")
	}
	w.ResetsAt = wholeSecondUTC(t)
	return w, nil
}

// normaliseWindow validates an optional window in place.
func normaliseWindow(w **CapacityWindow) error {
	if *w == nil {
		return nil
	}
	v, err := validWindow(**w)
	if err != nil {
		return err
	}
	*w = &v
	return nil
}

// RecordCapacity stores a Claude Code account's reading. A reading older
// than the one already stored is ignored, not an error: two windows can
// finish turns on the same account out of order.
func RecordCapacity(org, providerID string, r CapacityRecord) error {
	p, err := LoadProviderFor(org, providerID)
	if err != nil {
		return err
	}
	if p.Kind != ProviderKindClaudeCode || p.ConfigDir == "" {
		return UserError("provider " + providerID + " is not a claude-code account with a config dir")
	}
	if r.FiveHour != nil || r.SevenDay != nil {
		r.Month = nil // month is present only when the others are absent
	}
	if r.FiveHour == nil && r.Month == nil {
		return UserError("a capacity reading needs a fiveHour or a month window")
	}
	for _, w := range []**CapacityWindow{&r.FiveHour, &r.SevenDay, &r.Month} {
		if err := normaliseWindow(w); err != nil {
			return err
		}
	}
	asOf, err := time.Parse(time.RFC3339, r.AsOf)
	if err != nil {
		return UserError("asOf " + r.AsOf + " is not an RFC 3339 time")
	}
	r.AsOf = wholeSecondUTC(asOf)
	path, err := capacityPath(p.ConfigDir)
	if err != nil {
		return err
	}
	if prev, err := readCapacityFile(path); err == nil && prev != nil {
		if prevAt, err := time.Parse(time.RFC3339, prev.AsOf); err == nil && prevAt.After(asOf) {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(capacityFile{ConfigDir: filepath.Clean(p.ConfigDir), CapacityRecord: r}, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}

// readCapacityFile returns nil, nil for a file that does not exist.
func readCapacityFile(path string) (*capacityFile, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var f capacityFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("capacity file %s is unreadable: %w", path, err)
	}
	return &f, nil
}

const capacityProbeFloor = 60 * time.Second

// Seams, so the store's tests never read the Keychain or reach the network.
var (
	claudeTokenReader = func(org, id string) (string, error) { return SecretGetFor(org, ProviderTokenRef(id)) }
	claudeProber      = ProbeClaudeCapacity
	capacityNow       = time.Now
)

// probeStale probes, in parallel, every claude-code provider whose stored
// reading is missing or older than the floor, and stores what each answers.
// It returns the failures by provider id; a success is only in the store.
func probeStale(org string, providers []Provider) map[string]string {
	now := capacityNow()
	failures := map[string]string{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, p := range providers {
		if p.Kind != ProviderKindClaudeCode || p.ConfigDir == "" {
			continue
		}
		if path, err := capacityPath(p.ConfigDir); err == nil {
			if f, err := readCapacityFile(path); err == nil && f != nil {
				if at, err := time.Parse(time.RFC3339, f.AsOf); err == nil && now.Sub(at) < capacityProbeFloor {
					continue
				}
			}
		}
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			fail := func(msg string) { mu.Lock(); failures[id] = msg; mu.Unlock() }
			token, err := claudeTokenReader(org, id)
			if err != nil {
				fail(err.Error())
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), claudeProbeTimeout)
			defer cancel()
			rec, err := claudeProber(ctx, anthropicBaseURL(), token, now)
			if err != nil {
				fail(err.Error())
				return
			}
			if err := RecordCapacity(org, id, rec); err != nil {
				fail(err.Error())
			}
		}(p.ID)
	}
	wg.Wait()
	return failures
}

// ReadCapacityFor answers every provider of org, in ListProvidersFor's
// order. One account that cannot be read is that row's error; the call
// itself fails only when the org's providers cannot be listed (Rule 8).
func ReadCapacityFor(org string, refresh bool) (CapacityListing, error) {
	providers, err := ListProvidersFor(org)
	if err != nil {
		return CapacityListing{Readings: []CapacityReading{}}, err
	}
	var failures map[string]string
	if refresh {
		failures = probeStale(org, providers)
	}
	out := make([]CapacityReading, 0, len(providers))
	for _, p := range providers {
		r := CapacityReading{Account: p.ID, Kind: p.Kind, State: CapacityNotRead}
		switch p.Kind {
		case ProviderKindClaudeCode:
			path, err := capacityPath(p.ConfigDir)
			if err != nil {
				r.State, r.Error = CapacityError, err.Error()
				break
			}
			f, err := readCapacityFile(path)
			switch {
			case err != nil:
				r.State, r.Error = CapacityError, err.Error()
			case f != nil:
				r.State, r.FiveHour, r.SevenDay, r.Month, r.AsOf = CapacityRead, f.FiveHour, f.SevenDay, f.Month, f.AsOf
			}
			if msg, failed := failures[p.ID]; failed && r.State == CapacityNotRead {
				r.State, r.Error = CapacityError, msg
			}
		case ProviderKindCodex:
			got, found, err := codexReader()
			switch {
			case err != nil:
				r.State, r.Error = CapacityError, err.Error()
			case found:
				r.State, r.FiveHour, r.SevenDay, r.Month, r.AsOf = CapacityRead, got.FiveHour, got.SevenDay, got.Month, got.AsOf
			}
		case ProviderKindLocal:
			r.State = CapacityNoLimits
		}
		out = append(out, r)
	}
	return CapacityListing{Readings: out}, nil
}

func ReadCapacityForCurrentOrg(refresh bool) (CapacityListing, error) {
	org, err := CurrentOrg()
	if err != nil {
		return CapacityListing{Readings: []CapacityReading{}}, err
	}
	return ReadCapacityFor(org, refresh)
}
