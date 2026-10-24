package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// GitMergeResult: Done is false when git stopped on conflicts, listed in Conflicts; Summary is the
// note for the operator, or git's own one-line result.
type GitMergeResult struct {
	Done      bool     `json:"done"`
	Conflicts []string `json:"conflicts"`
	Summary   string   `json:"summary"`
}

// noEditor goes before every rebase: the scrubbed env drops EDITOR, and a repository's own editor
// must not open either — the commit keeps its message, the todo list is git's.
var noEditor = []string{"-c", "core.editor=true", "-c", "sequence.editor=true"}

const (
	pushedNote    = "; commits already pushed were rewritten, so Push is refused as behind"
	keptStashNote = "; your uncommitted changes are in git stash"
)

// Merge merges branch into the current one, carrying uncommitted changes with --autostash (call 12).
func (w *GitWriter) Merge(ctx context.Context, branch string) (GitMergeResult, error) {
	if err := notAFlag(branch); err != nil {
		return GitMergeResult{}, err
	}
	if err := w.inProgress(ctx); err != nil {
		return GitMergeResult{}, err
	}
	stash := w.stashTop(ctx)
	out, errb, err := w.gitWith(ctx, nil, nil, "merge", "--no-edit", "--autostash", branch)
	return w.finish(ctx, stash, "", out, errb, err)
}

// Rebase replays the current branch's own commits onto onto, carrying uncommitted changes.
func (w *GitWriter) Rebase(ctx context.Context, onto string) (GitMergeResult, error) {
	if err := notAFlag(onto); err != nil {
		return GitMergeResult{}, err
	}
	if err := w.inProgress(ctx); err != nil {
		return GitMergeResult{}, err
	}
	var b rebaseBase
	b.head = w.oneOf(ctx, "symbolic-ref", "-q", "HEAD")
	b.orig = w.oneOf(ctx, "rev-parse", "--verify", "-q", "HEAD")
	b.onto = w.oneOf(ctx, "rev-parse", "--verify", "-q", onto+"^{commit}")
	stash := w.stashTop(ctx)
	out, errb, err := w.gitWith(ctx, noEditor, nil, "rebase", "--autostash", onto)
	return w.finish(ctx, stash, w.rewrotePushed(ctx, b, err), out, errb, err)
}

// Continue finishes what is in progress once no conflict is left unstaged: a merge, cherry-pick or
// revert is committed (message from the box, else git's); a rebase goes on, and may stop again.
func (w *GitWriter) Continue(ctx context.Context, message string) (GitMergeResult, error) {
	op, err := ReadGitOp(ctx, w.runner())
	if err != nil {
		return GitMergeResult{}, err
	}
	if op.Kind == "" {
		return GitMergeResult{}, UserError("Nothing to continue")
	}
	conflicts, err := w.conflicts(ctx)
	if err != nil {
		return GitMergeResult{}, err
	}
	if len(conflicts) > 0 {
		return GitMergeResult{}, UserError("Resolve the conflicts in " + strings.Join(conflicts, ", ") + " first")
	}
	stash := w.stashTop(ctx)
	if op.Kind != "rebase" {
		c, err := w.Commit(ctx, message, false)
		if err != nil {
			return GitMergeResult{}, err
		}
		r := GitMergeResult{Done: true, Summary: c.Commit + " " + c.Summary}
		if w.keptAutostash(ctx, stash) {
			r.Summary += keptStashNote
		}
		return r, nil
	}
	b := w.readRebaseBase(ctx)
	out, errb, err := w.gitWith(ctx, noEditor, nil, "rebase", "--continue")
	return w.finish(ctx, stash, w.rewrotePushed(ctx, b, err), out, errb, err)
}

// Skip leaves the rebase's current commit out and goes on.
func (w *GitWriter) Skip(ctx context.Context) (GitMergeResult, error) {
	op, err := ReadGitOp(ctx, w.runner())
	if err != nil {
		return GitMergeResult{}, err
	}
	if op.Kind != "rebase" {
		return GitMergeResult{}, UserError("Skip is for a rebase")
	}
	b := w.readRebaseBase(ctx)
	stash := w.stashTop(ctx)
	out, errb, err := w.gitWith(ctx, noEditor, nil, "rebase", "--skip")
	return w.finish(ctx, stash, w.rewrotePushed(ctx, b, err), out, errb, err)
}

// Abort puts the tree back to before the operation in progress, with its autostash, by git's own
// `<kind> --abort`.
func (w *GitWriter) Abort(ctx context.Context) (GitMergeResult, error) {
	op, err := ReadGitOp(ctx, w.runner())
	if err != nil {
		return GitMergeResult{}, err
	}
	if op.Kind == "" {
		return GitMergeResult{}, UserError("Nothing to abort")
	}
	stash := w.stashTop(ctx)
	out, errb, err := w.gitWith(ctx, nil, nil, op.Kind, "--abort")
	if err != nil {
		return GitMergeResult{}, err
	}
	r := GitMergeResult{Done: true, Summary: oneLine(out, errb)}
	if r.Summary == "" {
		r.Summary = "Aborted the " + op.Kind
	}
	if w.keptAutostash(ctx, stash) {
		r.Summary += keptStashNote
	}
	return r, nil
}

// finish reads a merge's or rebase's outcome: stopped on conflicts (the note), failed (git's
// error), or done (git's line, then note, then a kept autostash).
func (w *GitWriter) finish(ctx context.Context, stash, note string, out, errb []byte, err error) (GitMergeResult, error) {
	if err != nil {
		if ctx.Err() != nil {
			return GitMergeResult{}, err
		}
		conflicts, cerr := w.conflicts(ctx)
		if cerr != nil || len(conflicts) == 0 {
			return GitMergeResult{}, err
		}
		return GitMergeResult{Conflicts: conflicts, Summary: w.stopNote(ctx, conflicts)}, nil
	}
	r := GitMergeResult{Done: true, Summary: oneLine(out, errb) + note}
	if w.keptAutostash(ctx, stash) {
		r.Summary += keptStashNote
	}
	return r, nil
}

func (w *GitWriter) stopNote(ctx context.Context, conflicts []string) string {
	paths := strings.Join(conflicts, ", ")
	if op, _ := ReadGitOp(ctx, w.runner()); op.Kind == "rebase" {
		return "Rebase stopped on conflicts in " + paths + " (step " + strconv.Itoa(op.Step) + " of " +
			strconv.Itoa(op.Steps) + "); resolve them below"
	}
	return "Merge stopped on conflicts in " + paths + "; resolve them below"
}

// conflicts is each unmerged path once, in git's order, from `ls-files -u -z`.
func (w *GitWriter) conflicts(ctx context.Context) ([]string, error) {
	out, err := w.git(ctx, nil, "ls-files", "-u", "-z")
	if err != nil {
		return nil, err
	}
	return unmergedPaths(out), nil
}

// unmergedPaths reads `ls-files -u -z`: each path once, in git's order.
func unmergedPaths(out []byte) []string {
	var paths []string
	seen := map[string]bool{}
	for _, rec := range nulFields(out) {
		_, p, ok := strings.Cut(rec, "\t") // "<mode> <id> <stage>\t<path>"
		if ok && !seen[p] {
			seen[p] = true
			paths = append(paths, p)
		}
	}
	return paths
}

// oneLine is git's result in a line: its first that is not progress, autostash bookkeeping or a hint, from
// stderr first (where a rebase says how it went), else stdout.
func oneLine(out, errb []byte) string {
	for _, b := range [][]byte{errb, out} {
		for _, l := range strings.Split(string(b), "\n") {
			if i := strings.LastIndex(strings.TrimRight(l, "\r"), "\r"); i >= 0 {
				l = l[i+1:] // progress ("Rebasing (1/2)") is overwritten in place by what follows it
			}
			l = strings.TrimSpace(l)
			switch {
			case l == "", strings.HasPrefix(l, "hint:"), strings.HasPrefix(l, "warning:"),
				strings.Contains(l, "autostash"), strings.HasPrefix(l, "Your changes are safe"),
				strings.HasPrefix(l, "You can run"):
				continue
			}
			return l
		}
	}
	return ""
}

// oneOf is a git read's output trimmed, "" on any failure.
func (w *GitWriter) oneOf(ctx context.Context, sub string, args ...string) string {
	out, err := w.git(ctx, nil, sub, args...)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// stashTop is refs/stash's id, "" when there is no stash.
func (w *GitWriter) stashTop(ctx context.Context) string {
	return w.oneOf(ctx, "rev-parse", "--verify", "-q", "refs/stash")
}

// keptAutostash: git could not reapply its autostash and stored it as a new top stash ("autostash").
func (w *GitWriter) keptAutostash(ctx context.Context, before string) bool {
	top := w.stashTop(ctx)
	if top == "" || top == before {
		return false
	}
	return w.oneOf(ctx, "log", "-g", "-1", "--format=%gs", "refs/stash", "--") == "autostash"
}

// rebaseBase is what a rebase started from: the branch (refs/heads/…), its commit, and onto's.
type rebaseBase struct{ head, orig, onto string }

func (w *GitWriter) readRebaseBase(ctx context.Context) rebaseBase {
	dir := w.oneOf(ctx, "rev-parse", "--absolute-git-dir")
	for _, d := range []string{"rebase-merge", "rebase-apply"} {
		read := func(name string) string {
			b, _ := os.ReadFile(filepath.Join(dir, d, name))
			return strings.TrimSpace(string(b))
		}
		if fileExists(filepath.Join(dir, d)) {
			return rebaseBase{head: read("head-name"), orig: read("orig-head"), onto: read("onto")}
		}
	}
	return rebaseBase{}
}

// rewrotePushed is pushedNote when a finished rebase replayed commits the branch's upstream already
// has, so the branch is now behind it; "" otherwise.
func (w *GitWriter) rewrotePushed(ctx context.Context, b rebaseBase, err error) string {
	if err != nil || !strings.HasPrefix(b.head, "refs/heads/") || b.orig == "" || b.onto == "" {
		return ""
	}
	up := strings.TrimPrefix(b.head, "refs/heads/") + "@{upstream}"
	all := w.oneOf(ctx, "rev-list", "--count", b.orig, "^"+b.onto, "--")
	unpushed := w.oneOf(ctx, "rev-list", "--count", b.orig, "^"+b.onto, "^"+up, "--")
	if unpushed == "" || all == unpushed {
		return "" // no upstream, or none of the replayed commits is on it
	}
	if _, err := w.git(ctx, nil, "merge-base", "--is-ancestor", up, b.head); err == nil {
		return ""
	}
	return pushedNote
}
