package wakilcore

import (
	"bufio"
	"bytes"
	"context"
	"strconv"
	"strings"
	"time"
)

// GitBlameLine is who last changed one line (3a-v-a). A line not yet committed has an all-zero ID.
type GitBlameLine struct {
	Line    int       `json:"line"`
	ID      string    `json:"id"`
	Author  string    `json:"author"`
	Date    time.Time `json:"date"`
	Subject string    `json:"subject"`
	// Path is the file's name at that commit; ParentPath its name in the commit before, set only when
	// a rename lies between them — the two sides of the commit's diff (3a-v-a walk, step 8).
	Path       string `json:"path"`
	ParentPath string `json:"parentPath,omitempty"`
	// Pushed: the commit is on a remote-tracking branch, so its host has a page for it (3c-i's
	// Open on GitHub). Set only when MarkPushed was asked for.
	Pushed bool `json:"pushed,omitempty"`
}

// BlameDeadline bounds one blame: it is decoration, and a huge file must not hold a git process.
const BlameDeadline = 10 * time.Second

// ReadBlame blames path, line by line, in order. With text, that text is blamed in place of the file
// on disk (the tab's unsaved buffer), so the lines match what is on screen.
func ReadBlame(ctx context.Context, g *GitRunner, path string, text *string) ([]GitBlameLine, error) {
	rel, err := g.ResolvePath(path)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, BlameDeadline)
	defer cancel()
	args := []string{"--porcelain"}
	var stdin []byte
	if text != nil {
		args, stdin = append(args, "--contents=-"), []byte(*text)
	}
	out, err := g.RunInput(ctx, stdin, "blame", append(args, "--", rel)...)
	if err != nil {
		return nil, err
	}
	return parseBlamePorcelain(out), nil
}

// MarkPushed sets Pushed on each committed line whose commit a remote-tracking branch holds. One
// `rev-list <ids> --not --remotes` answers every line at once: what it lists is not on any remote,
// and a pushed commit stops the walk at once, so the cost is the unpushed commits, not the history.
// With no remote-tracking refs at all nothing is pushed and rev-list does not run.
func MarkPushed(ctx context.Context, g *GitRunner, lines []GitBlameLine) error {
	ids, seen := []string{}, map[string]bool{}
	for _, l := range lines {
		if !seen[l.ID] && len(l.ID) == 40 && strings.Trim(l.ID, "0") != "" && isHex(l.ID) {
			seen[l.ID] = true
			ids = append(ids, l.ID)
		}
	}
	if len(ids) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, BlameDeadline)
	defer cancel()
	refs, err := g.Run(ctx, "for-each-ref", "--format=%(refname)", "refs/remotes")
	if err != nil || len(bytes.TrimSpace(refs)) == 0 {
		return err
	}
	out, err := g.Run(ctx, "rev-list", append(ids, "--not", "--remotes", "--")...)
	if err != nil {
		return err
	}
	unpushed := map[string]bool{}
	for _, id := range strings.Fields(string(out)) {
		unpushed[id] = true
	}
	for i := range lines {
		lines[i].Pushed = seen[lines[i].ID] && !unpushed[lines[i].ID]
	}
	return nil
}

func isHex(s string) bool {
	for _, c := range s {
		if !strings.ContainsRune("0123456789abcdef", c) {
			return false
		}
	}
	return true
}

// ReadOrigin is the root's `origin` URL with any credentials (`user:token@`) taken out, or "" when
// there is none: what the blame hover maps to the host's commit page. Read from config, so no
// `remote` subcommand is allowed in.
func ReadOrigin(ctx context.Context, g *GitRunner) string {
	return StripRemoteCredentials(g.ConfigValue(ctx, "remote.origin.url"))
}

// StripRemoteCredentials drops the password of a URL remote's user info (`https://x:tok@host/…` →
// `https://host/…`, `ssh://git:pw@host/…` → `ssh://git@host/…`); an https user name goes too, since
// it is often the token itself. An scp-like remote has no password and is left as it is.
func StripRemoteCredentials(raw string) string {
	raw = strings.TrimSpace(raw)
	scheme, rest, ok := strings.Cut(raw, "://")
	if !ok {
		return raw
	}
	end := strings.IndexAny(rest, "/?#")
	if end < 0 {
		end = len(rest)
	}
	at := strings.LastIndex(rest[:end], "@")
	if at < 0 {
		return raw
	}
	user := rest[:at]
	if strings.EqualFold(scheme, "ssh") {
		name, _, _ := strings.Cut(user, ":")
		return scheme + "://" + name + "@" + rest[at+1:]
	}
	return scheme + "://" + rest[at+1:]
}

// parseBlamePorcelain reads `blame --porcelain`: a header `<id> <orig> <final> [<count>]` per line,
// the commit's fields only the first time that commit appears, `previous` and `filename` every time,
// then the line itself after a tab.
func parseBlamePorcelain(out []byte) []GitBlameLine {
	type info struct {
		author, subject string
		date            time.Time
	}
	seen := map[string]*info{}
	lines := []GitBlameLine{}
	var cur *GitBlameLine
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		l := sc.Text()
		if strings.HasPrefix(l, "\t") { // the line's text ends its entry
			if cur != nil {
				if c := seen[cur.ID]; c != nil {
					cur.Author, cur.Subject, cur.Date = c.author, c.subject, c.date
				}
				lines = append(lines, *cur)
				cur = nil
			}
			continue
		}
		if cur == nil {
			f := strings.Fields(l)
			if len(f) < 3 || len(f[0]) != 40 {
				continue
			}
			n, _ := strconv.Atoi(f[2])
			cur = &GitBlameLine{Line: n, ID: f[0]}
			if seen[f[0]] == nil {
				seen[f[0]] = &info{}
			}
			continue
		}
		key, val, _ := strings.Cut(l, " ")
		c := seen[cur.ID]
		switch key {
		case "filename":
			cur.Path = blameName(val)
			if cur.ParentPath == cur.Path {
				cur.ParentPath = ""
			}
		case "previous": // `previous <id> <name>`; the name may hold spaces
			if _, name, ok := strings.Cut(val, " "); ok && blameName(name) != cur.Path {
				cur.ParentPath = blameName(name)
			}
		case "author":
			c.author = val
		case "author-time":
			if s, err := strconv.ParseInt(val, 10, 64); err == nil {
				c.date = time.Unix(s, 0).UTC()
			}
		case "summary":
			c.subject = val
		}
	}
	return lines
}

// blameName reads a file name as the porcelain writes it: as is, or C-quoted ("caf\303\251.txt")
// when it holds a quote, a backslash, a control or a non-ASCII byte — the escapes Go's own literals use.
func blameName(s string) string {
	if strings.HasPrefix(s, `"`) {
		if u, err := strconv.Unquote(s); err == nil {
			return u
		}
	}
	return s
}
