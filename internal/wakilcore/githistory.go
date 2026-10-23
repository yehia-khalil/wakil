package wakilcore

import (
	"context"
	"strconv"
	"strings"
	"time"
)

// GitCommit is one commit in a file's history (3a-v-a): Path is the file's name at that commit, which
// differs from today's after a rename.
type GitCommit struct {
	ID      string    `json:"id"`
	Parents []string  `json:"parents"`
	Author  string    `json:"author"`
	Email   string    `json:"email"`
	Date    time.Time `json:"date"`
	Subject string    `json:"subject"`
	Body    string    `json:"body"`
	Path    string    `json:"path"`
}

// FileHistoryPage is how many commits a page of a file's history holds when the caller names none.
const FileHistoryPage = 50

// historyFormat ends each commit with its fields NUL-separated and starts it with a record separator,
// so a message holding anything but NUL reads whole.
const historyFormat = "--format=%x1e%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%b%x00"

// ReadFileHistory reads path's commits, newest first, following renames: skip commits, then count
// (FileHistoryPage when 0). An untracked file has none.
func ReadFileHistory(ctx context.Context, g *GitRunner, path string, skip, count int) ([]GitCommit, error) {
	rel, err := g.ResolvePath(path)
	if err != nil {
		return nil, err
	}
	if count <= 0 {
		count = FileHistoryPage
	}
	out, err := g.Run(ctx, "log", "--follow", "--name-status", "-z", historyFormat,
		"--skip="+strconv.Itoa(skip), "--max-count="+strconv.Itoa(count), "--", rel)
	if err != nil {
		return nil, err
	}
	commits := []GitCommit{}
	last := rel
	for _, rec := range strings.Split(string(out), "\x1e") {
		f := strings.Split(rec, "\x00")
		if len(f) < 7 {
			continue
		}
		c := GitCommit{ID: f[0], Parents: strings.Fields(f[1]), Author: f[2], Email: f[3],
			Subject: f[5], Body: strings.TrimRight(f[6], "\n")}
		c.Date, _ = time.Parse(time.RFC3339, f[4])
		// What follows the fields is --name-status: a status, then one name, or two for a rename or copy.
		var names []string
		for _, s := range f[7:] {
			if s = strings.TrimLeft(s, "\n"); s != "" {
				names = append(names, s)
			}
		}
		switch {
		case len(names) >= 3 && (names[0][0] == 'R' || names[0][0] == 'C'):
			c.Path = names[2]
		case len(names) >= 2:
			c.Path = names[1]
		default:
			c.Path = last // a merge lists no names; the file kept the name it had after it
		}
		last = c.Path
		commits = append(commits, c)
	}
	return commits, nil
}
