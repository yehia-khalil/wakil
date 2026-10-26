package wakilcore

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Linking a branch to its tickets (spec: "Linking"). A key counts only when its prefix is the
// PM project key of one of the organisation's projects, so `fix-UTF-8` is not a ticket.
// A link made in Wakil is kept in tickets/links.json and wins over anything inferred.

// TicketMatch is one ticket found for a branch. Source is "wakil", "branch", "pr" or "trailer".
type TicketMatch struct{ Key, Source string }

// PRHeadBase is an open PR's head and base branch names.
type PRHeadBase struct{ Head, Base string }

var ticketKeyInTextRE = regexp.MustCompile(`(?i)\b([A-Z][A-Z0-9_]*)-(\d+)\b`)
var ticketTrailerRE = regexp.MustCompile(`(?im)^\s*Ticket:\s*(.*)$`)

// OrgProjectKeys is every project's scopes.pm.projectKey in the organisation, uppercase and
// unique. A project that cannot be read, or has no PM scope, adds nothing.
func OrgProjectKeys(org string) []string {
	reg, err := LoadRegistryFor(org)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(reg))
	for n := range reg {
		names = append(names, n)
	}
	sortStrings(names)
	var keys []string
	seen := map[string]bool{}
	for _, n := range names {
		p, err := LoadProject(reg[n].Path)
		if err != nil || p.Scopes.PM == nil {
			continue
		}
		k := strings.ToUpper(strings.TrimSpace(p.Scopes.PM.ProjectKey))
		if k != "" && !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	return keys
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

func inKeys(prefix string, projectKeys []string) bool {
	for _, k := range projectKeys {
		if strings.EqualFold(k, prefix) {
			return true
		}
	}
	return false
}

// TicketKeysIn returns the ticket keys in text whose prefix is one of projectKeys,
// uppercase, unique, in the order first seen.
func TicketKeysIn(text string, projectKeys []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, m := range ticketKeyInTextRE.FindAllStringSubmatch(text, -1) {
		if !inKeys(m[1], projectKeys) {
			continue
		}
		k := strings.ToUpper(m[1]) + "-" + m[2]
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	return out
}

// TrailerKeys returns the keys on `Ticket:` lines of the commit messages, and nowhere else.
func TrailerKeys(messages []string, projectKeys []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, msg := range messages {
		for _, m := range ticketTrailerRE.FindAllStringSubmatch(msg, -1) {
			for _, k := range TicketKeysIn(m[1], projectKeys) {
				if !seen[k] {
					seen[k] = true
					out = append(out, k)
				}
			}
		}
	}
	return out
}

// RepoKey is how links.json names a repository: remote host and path, so worktrees share it.
func RepoKey(host, owner, repo string) string {
	return strings.ToLower(host) + "/" + owner + "/" + repo
}

func linksPaths(org string) (file, lock string, err error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return "", "", err
	}
	d := filepath.Join(dir, "tickets")
	return filepath.Join(d, "links.json"), filepath.Join(d, "links.json.lock"), nil
}

func readLinks(path string) (map[string]string, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	m := map[string]string{}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("ticket links %s are not readable: %w", path, err)
	}
	return m, nil
}

func linkID(repoKey, branch string) string { return repoKey + ":" + branch }

// LinkTicket records that branch of repoKey is for the ticket key; an empty key unlinks, which
// returns the branch to inference. The key's prefix is not checked here: the operator typed it.
func LinkTicket(org, repoKey, branch, key string) error {
	key = strings.TrimSpace(key)
	if key != "" && !ticketKeyRE.MatchString(key) {
		return UserError("ticket key " + strconv.Quote(key) + " is not a key like INI-142")
	}
	path, lock, err := linksPaths(org)
	if err != nil {
		return err
	}
	return withTicketLock(lock, func() error {
		m, err := readLinks(path)
		if err != nil {
			return err
		}
		if key == "" {
			delete(m, linkID(repoKey, branch))
		} else {
			m[linkID(repoKey, branch)] = strings.ToUpper(key)
		}
		b, err := json.MarshalIndent(m, "", "  ")
		if err != nil {
			return err
		}
		tmp, err := os.CreateTemp(filepath.Dir(path), "links.json.*.tmp")
		if err != nil {
			return err
		}
		defer os.Remove(tmp.Name())
		if _, err := tmp.Write(append(b, '\n')); err != nil {
			tmp.Close()
			return err
		}
		if err := tmp.Close(); err != nil {
			return err
		}
		if err := os.Chmod(tmp.Name(), 0o644); err != nil {
			return err
		}
		return renameTicketFile(tmp.Name(), path)
	})
}

// TicketLinkFor is the ticket the operator linked the branch to in Wakil, if any.
func TicketLinkFor(org, repoKey, branch string) (string, bool) {
	path, _, err := linksPaths(org)
	if err != nil {
		return "", false
	}
	m, err := readLinks(path)
	if err != nil {
		return "", false
	}
	k, ok := m[linkID(repoKey, branch)]
	return k, ok && k != ""
}

// MatchTickets finds a branch's tickets. A Wakil link alone wins: inference is not consulted.
// Otherwise every source is tried (branch name always; the PR's title and body when there is a
// PR; the commits' `Ticket:` trailers when there are commits), a key is listed once under the
// first source that found it, and looked names each source tried in the spec's words.
// trailers are the commits' messages; commitCount is how many commits were read.
func MatchTickets(link, branch string, prNumber int, prTexts []string, commitCount int, trailers []string, keys []string) (matches []TicketMatch, looked []string) {
	if link != "" {
		return []TicketMatch{{Key: strings.ToUpper(link), Source: "wakil"}}, []string{"the link made in Wakil"}
	}
	seen := map[string]bool{}
	add := func(found []string, source string) {
		for _, k := range found {
			if !seen[k] {
				seen[k] = true
				matches = append(matches, TicketMatch{Key: k, Source: source})
			}
		}
	}
	looked = append(looked, "branch name")
	add(TicketKeysIn(branch, keys), "branch")
	if prNumber > 0 {
		looked = append(looked, fmt.Sprintf("PR #%d's title and body", prNumber))
		add(TicketKeysIn(strings.Join(prTexts, "\n"), keys), "pr")
	}
	if commitCount > 0 {
		noun := "commits'"
		if commitCount == 1 {
			noun = "commit's"
		}
		looked = append(looked, fmt.Sprintf("%d %s trailers", commitCount, noun))
		add(TrailerKeys(trailers, keys), "trailer")
	}
	return matches, looked
}

// LongLivedBranches are the remote default plus each open PR's base that carries no key and
// is no open PR's head, so `staging` and `production` are found without a list.
func LongLivedBranches(defaultBranch string, openPRs []PRHeadBase, keys []string) []string {
	heads := map[string]bool{}
	for _, p := range openPRs {
		heads[p.Head] = true
	}
	out := []string{defaultBranch}
	seen := map[string]bool{defaultBranch: true}
	for _, p := range openPRs {
		if seen[p.Base] || heads[p.Base] || len(TicketKeysIn(p.Base, keys)) > 0 {
			continue
		}
		seen[p.Base] = true
		out = append(out, p.Base)
	}
	return out
}
