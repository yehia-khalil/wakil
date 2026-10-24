package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// GitOp is the operation stopped part-way in a root, read from its git dir. Kind is "" when none is.
// Head and Subject are the commit being applied (rebase, cherry-pick, revert); Message is git's
// prepared message (MERGE_MSG without its comment lines), which fills an empty commit box.
type GitOp struct {
	Kind     string `json:"kind"` // "merge" | "rebase" | "cherry-pick" | "revert" | ""
	Incoming string `json:"incoming"`
	Onto     string `json:"onto"`
	Step     int    `json:"step"`
	Steps    int    `json:"steps"`
	Head     string `json:"head"`
	Subject  string `json:"subject"`
	Message  string `json:"message"`
}

// mergeMsgBranch is the branch named by git's prepared merge message (R6).
var mergeMsgBranch = regexp.MustCompile(`^Merge (?:remote-tracking )?branch '([^']+)'`)

// ReadGitOp names the operation in progress in g's root. A rebase is looked for first: one replaying
// merges can hold a MERGE_HEAD of its own.
func ReadGitOp(ctx context.Context, g *GitRunner) (GitOp, error) {
	out, err := g.Run(ctx, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return GitOp{}, err
	}
	dir := strings.TrimSpace(string(out))
	read := func(parts ...string) string {
		b, _ := os.ReadFile(filepath.Join(append([]string{dir}, parts...)...))
		return strings.TrimSpace(string(b))
	}
	var op GitOp
	switch {
	case fileExists(filepath.Join(dir, "rebase-merge")):
		op = GitOp{Kind: "rebase", Onto: read("rebase-merge", "onto"), Head: read("REBASE_HEAD")}
		op.Step, _ = strconv.Atoi(read("rebase-merge", "msgnum"))
		op.Steps, _ = strconv.Atoi(read("rebase-merge", "end"))
		if op.Head == "" {
			op.Head = read("rebase-merge", "stopped-sha")
		}
	case fileExists(filepath.Join(dir, "rebase-apply")):
		op = GitOp{Kind: "rebase", Onto: read("rebase-apply", "onto"), Head: read("REBASE_HEAD")}
		op.Step, _ = strconv.Atoi(read("rebase-apply", "next"))
		op.Steps, _ = strconv.Atoi(read("rebase-apply", "last"))
	case fileExists(filepath.Join(dir, "MERGE_HEAD")):
		op = GitOp{Kind: "merge"}
	case fileExists(filepath.Join(dir, "CHERRY_PICK_HEAD")):
		op = GitOp{Kind: "cherry-pick", Head: read("CHERRY_PICK_HEAD")}
	case fileExists(filepath.Join(dir, "REVERT_HEAD")):
		op = GitOp{Kind: "revert", Head: read("REVERT_HEAD")}
	default:
		return GitOp{}, nil
	}
	op.Message = preparedMessage(read("MERGE_MSG"))
	if op.Kind == "merge" {
		// MERGE_HEAD holds one id per merged head; an octopus is named by its first.
		head, _, _ := strings.Cut(read("MERGE_HEAD"), "\n")
		if m := mergeMsgBranch.FindStringSubmatch(op.Message); m != nil {
			op.Incoming = m[1]
		} else {
			op.Incoming = short(head)
		}
	}
	if op.Kind == "rebase" {
		op.Onto = branchAt(ctx, g, op.Onto)
	}
	if op.Head != "" {
		// stopped-sha may be abbreviated; the full id is what Skip's sentence and the UI key on.
		if full, err := g.Run(ctx, "rev-parse", "--verify", op.Head+"^{commit}"); err == nil {
			op.Head = strings.TrimSpace(string(full))
		}
		if s, err := g.Run(ctx, "log", "--max-count=1", "--format=%s", op.Head); err == nil {
			op.Subject = strings.TrimSpace(string(s))
		}
	}
	return op, nil
}

// preparedMessage drops git's comment lines (the conflict list, the instructions) from MERGE_MSG.
func preparedMessage(msg string) string {
	var keep []string
	for _, l := range strings.Split(msg, "\n") {
		if !strings.HasPrefix(l, "#") {
			keep = append(keep, l)
		}
	}
	return strings.TrimSpace(strings.Join(keep, "\n"))
}

// branchAt names the local branch whose tip is id (R6), else id's first seven letters.
func branchAt(ctx context.Context, g *GitRunner, id string) string {
	out, err := g.Run(ctx, "for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads")
	if err == nil {
		for _, l := range strings.Split(string(out), "\n") {
			if oid, name, ok := strings.Cut(l, " "); ok && oid == id {
				return name
			}
		}
	}
	return short(id)
}

func short(id string) string {
	if len(id) > 7 {
		return id[:7]
	}
	return id
}

// InProgressError refuses a write while op is under way, naming it; nil when nothing is.
func (op GitOp) InProgressError(root string) error {
	what := map[string]string{"merge": "A merge", "rebase": "A rebase", "cherry-pick": "A cherry-pick", "revert": "A revert"}[op.Kind]
	if what == "" {
		return nil
	}
	return UserError(what + " is in progress in " + root + "; finish or abort it first")
}
