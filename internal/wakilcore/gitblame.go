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

// parseBlamePorcelain reads `blame --porcelain`: a header `<id> <orig> <final> [<count>]` per line,
// the commit's fields only the first time that commit appears, then the line itself after a tab.
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
