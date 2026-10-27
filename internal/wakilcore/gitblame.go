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
	// Open on GitHub): on one of origin's. Set only when MarkPushed was asked for.
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

// PushedDeadline bounds MarkPushed on its own, apart from the blame's BlameDeadline: the check only
// decides whether the hover offers a link, so a slow one gives up and offers none.
var PushedDeadline = time.Second

// MarkPushed sets Pushed on each committed line whose commit one of origin's remote-tracking branches
// holds (the link points at origin's page, so a commit only on another remote gets none). One
// `rev-list <ids> --not --remotes=origin` answers every line at once: what it lists is not on origin.
// Its cost is the walk down from origin's tips until each id is reached from one — for an old file
// close to the whole history, which a commit-graph shortens — so it has PushedDeadline of its own.
// **It never fails the blame:** with no origin refs, past the deadline, or on any git error (an id
// git does not hold), every line is left not pushed, and the hover simply offers no link.
func MarkPushed(ctx context.Context, g *GitRunner, lines []GitBlameLine) {
	ids, seen := []string{}, map[string]bool{}
	for _, l := range lines {
		if !seen[l.ID] && len(l.ID) == 40 && strings.Trim(l.ID, "0") != "" && isHex(l.ID) {
			seen[l.ID] = true
			ids = append(ids, l.ID)
		}
	}
	if len(ids) == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, PushedDeadline)
	defer cancel()
	refs, err := g.Run(ctx, "for-each-ref", "--format=%(refname)", "refs/remotes/origin")
	if err != nil || len(bytes.TrimSpace(refs)) == 0 {
		return
	}
	out, err := g.Run(ctx, "rev-list", append(ids, "--not", "--remotes=origin", "--")...)
	if err != nil {
		return
	}
	unpushed := map[string]bool{}
	for _, id := range strings.Fields(string(out)) {
		unpushed[id] = true
	}
	for i := range lines {
		lines[i].Pushed = seen[lines[i].ID] && !unpushed[lines[i].ID]
	}
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

// StripRemoteCredentials takes the credentials out of a remote's URL. A URL remote loses its user info
// whole (`https://x:tok@host/…` → `https://host/…`), except that an ssh user is kept without its password
// (`ssh://git:pw@host/…` → `ssh://git@host/…`); the user info ends at the LAST `@` before the host, so a
// token holding an unencoded `/`, `?` or `#` goes too (`https://u:ab/cd@host/…` → `https://host/…`: an
// authority that is not a dotted host with a numeric port, and an `@` after it, is user info). One
// with no dotted host after any `@` answers "": no origin, rather than one that may carry a token.
// An scp-like remote keeps `user@`, and loses a `user:secret@` (`u:tok@host:path` → `host:path`).
func StripRemoteCredentials(raw string) string {
	raw = strings.TrimSpace(raw)
	scheme, rest, ok := strings.Cut(raw, "://")
	if !ok {
		head := raw
		if i := strings.Index(head, "/"); i >= 0 {
			head = head[:i]
		}
		if at := strings.LastIndex(head, "@"); at >= 0 && strings.Contains(head[:at], ":") {
			return raw[at+1:]
		}
		return raw
	}
	authorityEnd := strings.IndexAny(rest, "/?#")
	if authorityEnd < 0 {
		authorityEnd = len(rest)
	}
	authority := rest[:authorityEnd]
	at := strings.LastIndex(authority, "@")
	if at < 0 {
		host, port, hasPort := strings.Cut(authority, ":")
		if !strings.Contains(rest[authorityEnd:], "@") || (strings.Contains(host, ".") && (!hasPort || isDigits(port))) {
			return raw // no `@` at all, or a real host whose path holds one
		}
		// User info holding an unencoded `/`, `?` or `#`: the host is what follows the first `@` that
		// is followed by a dotted host. Its user name cannot be trusted either, so all of it goes.
		for i := authorityEnd; i < len(rest); i++ {
			if rest[i] != '@' {
				continue
			}
			end := strings.IndexAny(rest[i+1:], "/?#")
			if end < 0 {
				end = len(rest) - i - 1
			}
			candidate, _, _ := strings.Cut(rest[i+1:i+1+end], ":")
			if strings.Contains(candidate, ".") && !strings.Contains(candidate, "@") {
				return scheme + "://" + rest[i+1:]
			}
		}
		return ""
	}
	// The user info runs to the last `@` before the host's first `/` (`?`, `#`) that follows it.
	for {
		next := strings.IndexAny(rest[at+1:], "/?#")
		hostEnd := len(rest)
		if next >= 0 {
			hostEnd = at + 1 + next
		}
		more := strings.LastIndex(rest[:hostEnd], "@")
		if more == at {
			break
		}
		at = more
	}
	user := rest[:at]
	if strings.EqualFold(scheme, "ssh") {
		name, _, _ := strings.Cut(user, ":")
		return scheme + "://" + name + "@" + rest[at+1:]
	}
	return scheme + "://" + rest[at+1:]
}

func isDigits(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return s != ""
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
