package night

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Store is where the night keeps its state: under the git common dir, so every
// worktree of the repository sees the same nights and nothing is committed.
type Store struct {
	Dir string
}

const dateLayout = "2006-01-02"

// CommonDir is the repository's git common dir, absolute.
func CommonDir(repo string) (string, error) {
	out, err := exec.Command("git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
	if err != nil {
		return "", fmt.Errorf("finding the git common dir of %s: %w", repo, err)
	}
	return strings.TrimSpace(string(out)), nil
}

// OpenStore opens, creating if needed, the night's store for repo.
func OpenStore(repo string) (Store, error) {
	common, err := CommonDir(repo)
	if err != nil {
		return Store{}, err
	}
	store := Store{Dir: filepath.Join(common, "wakil-e2e-night")}
	if err := os.MkdirAll(store.results(), 0o755); err != nil {
		return Store{}, err
	}
	return store, nil
}

func (s Store) results() string { return filepath.Join(s.Dir, "results") }

// LastGreen is the origin/main commit of the last green night, or "" if none.
func (s Store) LastGreen() (string, error) {
	body, err := os.ReadFile(filepath.Join(s.Dir, "last-green"))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	return strings.TrimSpace(string(body)), err
}

func (s Store) SetLastGreen(commit string) error {
	return os.WriteFile(filepath.Join(s.Dir, "last-green"), []byte(commit+"\n"), 0o644)
}

// ResultPath is where the result of the night starting on night is written.
func (s Store) ResultPath(night time.Time) string {
	return filepath.Join(s.results(), night.Format(dateLayout)+".md")
}

// FixerSummaryPath is where the fixer writes its summary and PR draft.
func (s Store) FixerSummaryPath(night time.Time) string {
	return filepath.Join(s.results(), night.Format(dateLayout)+"-fixer.md")
}

func (s Store) WriteResult(r Result) (string, error) {
	path := s.ResultPath(r.Night)
	return path, os.WriteFile(path, []byte(r.Markdown()), 0o644)
}

// Latest returns the most recent night's result, or the zero time when no
// night has run.
func (s Store) Latest() (time.Time, string, error) {
	entries, err := os.ReadDir(s.results())
	if err != nil {
		return time.Time{}, "", err
	}
	var nights []time.Time
	for _, e := range entries {
		night, err := time.ParseInLocation(dateLayout, strings.TrimSuffix(e.Name(), ".md"), time.Local)
		if err == nil {
			nights = append(nights, night)
		}
	}
	if len(nights) == 0 {
		return time.Time{}, "", nil
	}
	sort.Slice(nights, func(i, j int) bool { return nights[i].Before(nights[j]) })
	last := nights[len(nights)-1]
	body, err := os.ReadFile(s.ResultPath(last))
	return last, string(body), err
}
