package driver

import (
	"fmt"
	"os/exec"
	"path"
	"sort"
	"strings"
)

// AppSourceRoot is where the control denominator is harvested from: the
// window's own Swift, and nothing in WakilKit — a control is something an
// operator can press, and WakilKit draws none.
const AppSourceRoot = "app/Sources/WakilApp"

// ActionSourceRoot covers both targets, because actions are registered in six
// files across WakilKit and read by WakilApp. It is only ever searched for
// whether a NAME was already there, never parsed.
const ActionSourceRoot = "app/Sources"

// TreeReader reads one commit's files. An interface because the gate's whole
// newness question is answered against a commit nobody has checked out, and a
// test should be able to hand it a tree without making one.
type TreeReader interface {
	// Files lists the paths under dir at that commit.
	Files(dir string) ([]string, error)
	// Read returns one path's content at that commit.
	Read(path string) ([]byte, error)
}

// GitTree reads a commit out of a repository without checking it out.
//
// **Two invocations and no worktree.** `make e2e-new` builds a worktree per
// commit because it has to BUILD the base; this only has to read it, and a
// worktree for that would cost a checkout to answer a question `git show`
// answers in milliseconds.
type GitTree struct {
	Repo   string
	Commit string
}

// Files lists the paths under dir at this commit.
func (t GitTree) Files(dir string) ([]string, error) {
	out, err := exec.Command(
		"git", "-C", t.Repo, "ls-tree", "-r", "--name-only", t.Commit, "--", dir).Output()
	if err != nil {
		return nil, fmt.Errorf("listing %s at %s: %w", dir, ShortCommit(t.Commit), err)
	}
	var paths []string
	for _, line := range strings.Split(string(out), "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			paths = append(paths, trimmed)
		}
	}
	return paths, nil
}

// Read returns one path's content at this commit.
func (t GitTree) Read(file string) ([]byte, error) {
	out, err := exec.Command("git", "-C", t.Repo, "show", t.Commit+":"+file).Output()
	if err != nil {
		return nil, fmt.Errorf("reading %s at %s: %w", file, ShortCommit(t.Commit), err)
	}
	return out, nil
}

// Sources is a tree's Swift text, held for one question: was this name there?
type Sources struct {
	text  string
	files int
}

// TreeSources reads the Swift under dir at a commit.
//
// **Comment lines are dropped as they are read**, which is what lets Mentions
// below be a plain substring search and still mean what it says. The likeliest
// way a name appears at the base without the action existing is a comment
// planning the work, and reading that as the action having existed marks a
// genuinely new action old — the flattering direction, and silent.
//
// **An empty read is refused rather than returned.** Every action and every
// identifier would then count as new, the gate would name forty of them at
// once, and a gate that fires forty times on its first run is one somebody
// switches off that afternoon. The failure it protects against is ordinary —
// a renamed directory, a commit from before the tree had this layout — and
// silent in exactly the direction that destroys the instrument.
func TreeSources(tree TreeReader, dir string) (Sources, error) {
	var text strings.Builder
	files, err := eachSwiftFile(tree, dir, func(_ string, data []byte) {
		text.WriteString(withoutCommentLines(string(data)))
		text.WriteString("\n")
	})
	if err != nil {
		return Sources{}, err
	}
	if files == 0 {
		return Sources{}, fmt.Errorf(
			"no Swift sources under %s in that tree — every action would read as newly "+
				"added, and a gate that fires on the whole registry at once is one nobody keeps",
			dir)
	}
	return Sources{text: text.String(), files: files}, nil
}

// Files is how many sources were read, for a caller narrating what it did.
func (s Sources) Files() int { return s.files }

// Mentions reports whether this tree spelled the name as a string literal, in
// code rather than in a comment.
//
// **As a literal, never as a word.** An action's name reaches the wire only
// because something wrote `name: "term_close"`; `term_close` the Swift symbol
// is not the action having existed. The quotes are the difference, and
// TreeSources having dropped the comments is what keeps them meaning it.
//
// **What is left, named rather than discovered later.** A quoted name in a
// trailing comment on a line of code still counts, and so does one in a list
// that names an action before it is registered. Both mark a new action as old,
// which loses a gate entry rather than inventing one — the same direction the
// whole rule errs in, and the residue the task audit (#257) reads a diff to
// catch.
func (s Sources) Mentions(name string) bool {
	return strings.Contains(s.text, `"`+name+`"`)
}

// TreeIdentifiers harvests the control denominator out of a commit.
//
// It reads the same grammar `HarvestIdentifiers` does — deliberately the same
// function per file, over the same descent — because a baseline harvested by
// different rules than the head would report the difference between two
// harvesters as new surface.
func TreeIdentifiers(tree TreeReader, dir string) ([]Identifier, error) {
	var found []Identifier
	files, err := eachSwiftFile(tree, dir, func(file string, data []byte) {
		found = append(found, IdentifiersIn(path.Base(file), string(data))...)
	})
	if err != nil {
		return nil, err
	}
	if files == 0 {
		return nil, fmt.Errorf(
			"no Swift sources under %s in that tree — every identifier would read as newly "+
				"added", dir)
	}
	sort.Slice(found, func(i, j int) bool { return found[i].Name < found[j].Name })
	return found, nil
}

// eachSwiftFile hands every Swift source under dir to visit, and returns how
// many there were. The two readers above differ only in what they do with the
// text; the walk, the extension filter and the count were the same in both.
func eachSwiftFile(tree TreeReader, dir string, visit func(file string, data []byte)) (int, error) {
	paths, err := tree.Files(dir)
	if err != nil {
		return 0, err
	}
	read := 0
	for _, file := range paths {
		if path.Ext(file) != ".swift" {
			continue
		}
		data, err := tree.Read(file)
		if err != nil {
			return 0, err
		}
		visit(file, data)
		read++
	}
	return read, nil
}

// withoutCommentLines drops whole-line Swift comments, the way IdentifiersIn
// already does for the head harvest.
//
// Line comments only, and deliberately: a block comment needs a lexer to find
// the end of, a string containing "/*" would fool a cheap one, and the whole
// point of this text is that it is searched rather than parsed.
func withoutCommentLines(source string) string {
	var kept strings.Builder
	for _, line := range strings.Split(source, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "//") {
			continue
		}
		kept.WriteString(line)
		kept.WriteString("\n")
	}
	return kept.String()
}

// NewActions are the ones the base tree never named.
func NewActions(tools []Tool, base Sources) []Tool {
	var fresh []Tool
	for _, tool := range tools {
		if !base.Mentions(tool.Name) {
			fresh = append(fresh, tool)
		}
	}
	return fresh
}

// NewIdentifiers are the names at head that the base did not carry, one entry
// per name.
//
// **Per name, not per call site.** One helper draws four Cancel buttons and
// each call passes its own identifier, so a name can be harvested twice from
// one file; a branch that moves a control between files owes one check, and a
// gate that named it twice would read as two pieces of work.
func NewIdentifiers(head, base []Identifier) []Identifier {
	known := map[string]bool{}
	for _, identifier := range base {
		known[identifier.Name] = true
	}
	var fresh []Identifier
	for _, identifier := range head {
		if known[identifier.Name] {
			continue
		}
		known[identifier.Name] = true
		fresh = append(fresh, identifier)
	}
	sort.Slice(fresh, func(i, j int) bool { return fresh[i].Name < fresh[j].Name })
	return fresh
}

// Fresh is the surface a branch added, and what answering that cost.
type Fresh struct {
	Surface Surface
	// BaseCommit is the merge-base the question was answered against.
	BaseCommit string
	// SourceFiles is how many Swift files were read at that commit, for the
	// line a caller prints: an answer computed from nothing would say every
	// action is new, and TreeSources refuses that — this is what lets a reader
	// see the refusal was not needed. It is a count, which is why it is not
	// called Sources: that is the name of the text those files hold.
	SourceFiles int
}

// FreshSurface is what this branch added, read off the commit it forked from.
//
// **The merge-base, never the tip of the trunk** — `make e2e-new`'s rule, for
// its reason: a branch whose trunk has moved on would otherwise be asked for
// checks covering somebody else's actions.
//
// **One function, because two callers ask the same question.** The coverage
// gate asks it to decide what fails the build, and the runbook's machine
// section asks it to say what the branch owed; the day two copies disagreed,
// the document would certify a gate that was enforcing something else.
func FreshSurface(repo, trunk string, whole Surface) (Fresh, error) {
	base, err := MergeBase(repo, trunk)
	if err != nil {
		return Fresh{}, err
	}
	tree := GitTree{Repo: repo, Commit: base}
	sources, err := TreeSources(tree, ActionSourceRoot)
	if err != nil {
		return Fresh{}, err
	}
	identifiers, err := TreeIdentifiers(tree, AppSourceRoot)
	if err != nil {
		return Fresh{}, err
	}
	return Fresh{
		Surface: Surface{
			Actions:     NewActions(whole.Actions, sources),
			Identifiers: NewIdentifiers(whole.Identifiers, identifiers),
		},
		BaseCommit:  base,
		SourceFiles: sources.Files(),
	}, nil
}
