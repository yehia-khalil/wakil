package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestStashModes(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "changed\n")
	writeIn(t, work, "u.txt", "untracked\n")
	if err := w.Stash(ctx, "plain", "default"); err != nil {
		t.Fatal(err)
	}
	if s := git("status", "--porcelain"); s != "?? u.txt" {
		t.Fatalf("default left %q", s)
	}
	if err := w.Stash(ctx, "with untracked", "untracked"); err != nil {
		t.Fatal(err)
	}
	if s := git("status", "--porcelain"); s != "" {
		t.Fatalf("untracked left %q", s)
	}
	writeIn(t, work, "a.txt", "staged\n")
	git("add", "a.txt")
	writeIn(t, work, "b.txt", "loose\n")
	if err := w.Stash(ctx, "staged only", "staged"); err != nil {
		t.Fatal(err)
	}
	if s := git("status", "--porcelain"); s != "?? b.txt" {
		t.Fatalf("staged left %q", s)
	}
	if !strings.Contains(git("stash", "list"), "staged only") {
		t.Fatal("no message")
	}
}

func TestNothingToStashSaysSo(t *testing.T) {
	_, w, _ := branchFixture(t)
	if err := w.Stash(context.Background(), "", "default"); err == nil || err.Error() != "No local changes to stash" {
		t.Fatalf("err = %v", err)
	}
}

func TestReadStashesListsFilesWithUntracked(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "a.txt", "changed\n")
	writeIn(t, work, "u.txt", "untracked\n")
	if err := w.Stash(context.Background(), "wip search", "untracked"); err != nil {
		t.Fatal(err)
	}
	s, err := ReadStashes(context.Background(), w.runner())
	if err != nil || len(s) != 1 {
		t.Fatalf("stashes = %+v err %v", s, err)
	}
	if s[0].Index != 0 || s[0].ID != git("rev-parse", "stash@{0}") || s[0].Message != "wip search" || s[0].Branch != "main" {
		t.Fatalf("stash = %+v", s[0])
	}
	if strings.Join(s[0].Files, ",") != "a.txt,u.txt" || strings.Join(s[0].Untracked, ",") != "u.txt" || s[0].Date.IsZero() {
		t.Fatalf("files = %v date %v", s[0].Files, s[0].Date)
	}
}

func TestApplyPopDropByIndexAndID(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "one\n")
	w.Stash(ctx, "first", "default")
	writeIn(t, work, "b.txt", "two\n")
	git("add", "b.txt")
	w.Stash(ctx, "second", "default")
	s, _ := ReadStashes(ctx, w.runner())
	if len(s) != 2 || s[0].Message != "second" {
		t.Fatalf("stashes = %+v", s)
	}
	if note, clash, err := w.StashApply(ctx, 1, s[1].ID, false); err != nil || note != "" || clash != nil {
		t.Fatalf("apply: %q %+v %v", note, clash, err)
	}
	if b, _ := os.ReadFile(filepath.Join(work, "a.txt")); string(b) != "one\n" || len(strings.Split(git("stash", "list"), "\n")) != 2 {
		t.Fatal("apply did not keep the stash")
	}
	git("checkout", "--", "a.txt")
	if _, _, err := w.StashApply(ctx, 0, s[0].ID, true); err != nil {
		t.Fatal(err)
	}
	if git("stash", "list") == "" || strings.Contains(git("stash", "list"), "second") {
		t.Fatalf("pop kept it: %q", git("stash", "list"))
	}
	rest, _ := ReadStashes(ctx, w.runner())
	if err := w.StashDrop(ctx, 0, rest[0].ID); err != nil || git("stash", "list") != "" {
		t.Fatalf("drop: %v %q", err, git("stash", "list"))
	}
}

// Review Focus 2: another worktree or the terminal stashes between Wakil's read and its drop.
func TestAMovedStashListIsRefused(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "mine\n")
	w.Stash(ctx, "mine", "default")
	read, _ := ReadStashes(ctx, w.runner())
	writeIn(t, work, "a.txt", "terminal\n")
	git("stash", "push", "-q", "-m", "from the terminal")
	err := w.StashDrop(ctx, 0, read[0].ID)
	if err == nil || err.Error() != "The stash list changed; look again" {
		t.Fatalf("err = %v", err)
	}
	if n := len(strings.Split(git("stash", "list"), "\n")); n != 2 {
		t.Fatalf("a stash went: %d left", n)
	}
	if err := w.StashDropAll(ctx, []string{read[0].ID, git("rev-parse", "stash@{0}")}); err != nil || git("stash", "list") != "" {
		t.Fatalf("drop all: %v", err)
	}
}

// clashFixture pops a stash whose a.txt clashes with a commit made since; the operator's other.txt is
// unrelated. b.txt is the stash's non-conflicting change, which git leaves staged.
func clashFixture(t *testing.T) (work string, w *GitWriter, git func(args ...string) string, note string, clash *GitStashClash) {
	t.Helper()
	work, w, git = branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	writeIn(t, work, "b.txt", "stashed b\n")
	git("add", "b.txt")
	w.Stash(ctx, "clashing", "default")
	writeIn(t, work, "a.txt", "one\nCOMMITTED\nthree\n")
	git("commit", "-qam", "moved on")
	writeIn(t, work, "other.txt", "mine, unrelated\n")
	s, _ := ReadStashes(ctx, w.runner())
	note, clash, err := w.StashApply(ctx, 0, s[0].ID, true)
	if err != nil || clash == nil {
		t.Fatalf("note %q clash %+v err %v", note, clash, err)
	}
	return work, w, git, note, clash
}

// A clash is left in the tree to resolve, the stash kept, and recorded for Undo Apply.
func TestStashPopClashLeavesConflictsAndTheStash(t *testing.T) {
	work, _, git, note, clash := clashFixture(t)
	if note != "Your stash clashes with main in a.txt; resolve it below, or Undo Apply" {
		t.Fatalf("note = %q", note)
	}
	if git("ls-files", "-u") == "" || !strings.Contains(readIn(t, work, "a.txt"), "<<<<<<<") {
		t.Fatalf("no conflict left: %q", readIn(t, work, "a.txt"))
	}
	if readIn(t, work, "b.txt") != "stashed b\n" || readIn(t, work, "other.txt") != "mine, unrelated\n" {
		t.Fatal("the stash's other change or the operator's file was touched")
	}
	if clash.ID != git("rev-parse", "stash@{0}") || !slices.Equal(clash.Conflicts, []string{"a.txt"}) || len(clash.Created) != 0 {
		t.Fatalf("clash = %+v", clash)
	}
	if len(clash.Files) != 2 || clash.Files[0].Path != "a.txt" || clash.Files[0].Hash != git("hash-object", "a.txt") ||
		clash.Files[1].Path != "b.txt" || clash.Files[1].Hash != git("hash-object", "b.txt") {
		t.Fatalf("files = %+v", clash.Files)
	}
}

func TestUndoApplyRestoresAndKeepsTheStash(t *testing.T) {
	work, w, git, _, clash := clashFixture(t)
	if err := w.StashUndoApply(context.Background(), *clash); err != nil {
		t.Fatal(err)
	}
	if st := git("status", "--porcelain"); st != "?? other.txt" {
		t.Fatalf("status = %q", st)
	}
	if readIn(t, work, "a.txt") != "one\nCOMMITTED\nthree\n" {
		t.Fatalf("a.txt = %q", readIn(t, work, "a.txt"))
	}
	if git("stash", "list") == "" {
		t.Fatal("the stash went")
	}
}

// Once the stash is dropped it holds nothing back: Undo Apply would delete the only copy.
func TestUndoApplyRefusesWhenTheStashIsGone(t *testing.T) {
	work, w, git, _, clash := clashFixture(t)
	before := git("status", "--porcelain")
	git("stash", "drop", "-q")
	err := w.StashUndoApply(context.Background(), *clash)
	if err == nil || err.Error() != "The stash is gone, so Undo Apply would lose its changes; resolve it by hand" {
		t.Fatalf("err = %v", err)
	}
	if git("status", "--porcelain") != before || readIn(t, work, "b.txt") != "stashed b\n" {
		t.Fatal("the refusal changed the tree")
	}
}

// Review Focus 5: an edit made since the clash is never thrown away.
func TestUndoApplyRefusesAnEditedFile(t *testing.T) {
	work, w, git, _, clash := clashFixture(t)
	writeIn(t, work, "a.txt", "one\nRESOLVED\nthree\n")
	err := w.StashUndoApply(context.Background(), *clash)
	if err == nil || err.Error() != "a.txt changed since the clash; Undo Apply would lose that — resolve it by hand" {
		t.Fatalf("err = %v", err)
	}
	if readIn(t, work, "a.txt") != "one\nRESOLVED\nthree\n" || git("ls-files", "-u") == "" {
		t.Fatal("the refusal changed the tree")
	}
}

func TestGitShowReadsAStashFile(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "a.txt", "stashed\n")
	writeIn(t, work, "u.txt", "untracked\n")
	w.Stash(context.Background(), "s", "untracked")
	id := git("rev-parse", "stash@{0}")
	g := w.runner()
	ctx := context.Background()
	if r, err := GitShow(ctx, g, "a.txt", "stash:"+id); err != nil || r.Text != "stashed\n" {
		t.Fatalf("stash side: %+v %v", r, err)
	}
	if r, err := GitShow(ctx, g, "a.txt", "stash-base:"+id); err != nil || r.Text != "one\ntwo\nthree\n" {
		t.Fatalf("base side: %+v %v", r, err)
	}
	if r, err := GitShow(ctx, g, "u.txt", "stash-untracked:"+id); err != nil || r.Text != "untracked\n" {
		t.Fatalf("untracked side: %+v %v", r, err)
	}
	if _, err := GitShow(ctx, g, "a.txt", "stash:HEAD~1"); err == nil {
		t.Fatal("a stash side takes a commit id only")
	}
}

// Review C1: Undo Apply never deletes a file the apply did not create, and reads names with spaces or
// non-ASCII letters whole.
func TestUndoApplyNeverDeletesTheOperatorsFiles(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	writeIn(t, work, "u.txt", "stashed u\n")
	writeIn(t, work, "my notes.txt", "stashed notes\n")
	writeIn(t, work, "café.txt", "stashed café\n")
	if err := w.Stash(ctx, "clashing", "untracked"); err != nil {
		t.Fatal(err)
	}
	writeIn(t, work, "a.txt", "one\nCOMMITTED\nthree\n")
	git("commit", "-qam", "moved on")
	writeIn(t, work, "u.txt", "OPERATOR\n")      // the operator's own, untracked
	writeIn(t, work, "notes.txt", "unrelated\n") // a name a split on spaces would hit
	s, _ := ReadStashes(ctx, w.runner())
	if got := strings.Join(s[0].Files, "|"); got != "a.txt|café.txt|my notes.txt|u.txt" {
		t.Fatalf("files = %q", got)
	}
	note, clash, err := w.StashApply(ctx, 0, s[0].ID, true)
	if err != nil || clash == nil || note != "Your stash clashes with main in a.txt; resolve it below, or Undo Apply" {
		t.Fatalf("note %q clash %+v err %v", note, clash, err)
	}
	if !slices.Equal(clash.Created, []string{"café.txt", "my notes.txt"}) {
		t.Fatalf("created = %q", clash.Created)
	}
	for _, f := range clash.Files {
		if f.Path == "u.txt" {
			t.Fatalf("the operator's u.txt is in the clash: %+v", clash.Files)
		}
	}
	if err := w.StashUndoApply(ctx, *clash); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"u.txt": "OPERATOR\n", "notes.txt": "unrelated\n", "a.txt": "one\nCOMMITTED\nthree\n"} {
		if b, err := os.ReadFile(filepath.Join(work, name)); err != nil || string(b) != want {
			t.Errorf("%s = %q, %v", name, b, err)
		}
	}
	for _, name := range []string{"my notes.txt", "café.txt"} {
		if _, err := os.Stat(filepath.Join(work, name)); !os.IsNotExist(err) {
			t.Errorf("%s left behind", name)
		}
	}
	if git("stash", "list") == "" {
		t.Fatal("the stash went")
	}
}

// Review I3: a stash mid-merge would throw the merge away; it is refused, as a switch is.
func TestStashRefusesMidMerge(t *testing.T) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "side")
	writeIn(t, work, "s.txt", "s\n")
	git("add", "s.txt")
	git("commit", "-qm", "side")
	git("switch", "-q", "main")
	git("merge", "--no-commit", "--no-ff", "side")
	err := w.Stash(context.Background(), "", "default")
	if err == nil || !strings.HasPrefix(err.Error(), "A merge is in progress in ") {
		t.Fatalf("err = %v", err)
	}
	gitDir := git("rev-parse", "--absolute-git-dir")
	if _, err := os.Stat(filepath.Join(gitDir, "MERGE_HEAD")); err != nil {
		t.Fatal("the merge was thrown away")
	}
}

// Review I2: Drop All drops the stashes the operator was shown, not one pushed since.
func TestDropAllDropsOnlyTheListedStashes(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "1\n")
	w.Stash(ctx, "one", "default")
	writeIn(t, work, "a.txt", "2\n")
	w.Stash(ctx, "two", "default")
	shown, _ := ReadStashes(ctx, w.runner())
	writeIn(t, work, "a.txt", "3\n")
	git("stash", "push", "-q", "-m", "from the terminal")
	ids := []string{shown[0].ID, shown[1].ID}
	if err := w.StashDropAll(ctx, ids); err != nil {
		t.Fatal(err)
	}
	if l := git("stash", "list"); !strings.Contains(l, "from the terminal") || strings.Contains(l, "one") || strings.Contains(l, "two") {
		t.Fatalf("list = %q", l)
	}
}

// Final review C1: an edit staged before the apply is in no stash, so Undo Apply puts it back staged
// and in the tree, for the file that clashed and for one that merged cleanly, rather than to HEAD.
func TestUndoApplyKeepsAnEditStagedBeforeTheApply(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "c.txt", "1\n2\n3\n4\n5\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	writeIn(t, work, "c.txt", "STASHED\n2\n3\n4\n5\n")
	w.Stash(ctx, "clashing", "default")
	writeIn(t, work, "a.txt", "one\nSTAGED\nthree\n")
	writeIn(t, work, "c.txt", "1\n2\n3\n4\nSTAGED\n")
	git("add", "a.txt", "c.txt")
	stagedA, stagedC := git("rev-parse", ":a.txt"), git("rev-parse", ":c.txt")
	s, _ := ReadStashes(ctx, w.runner())
	_, clash, err := w.StashApply(ctx, 0, s[0].ID, false)
	if err != nil || clash == nil || !slices.Equal(clash.Conflicts, []string{"a.txt"}) {
		t.Fatalf("clash %+v err %v", clash, err)
	}
	if err := w.StashUndoApply(ctx, *clash); err != nil {
		t.Fatal(err)
	}
	if git("rev-parse", ":a.txt") != stagedA || git("rev-parse", ":c.txt") != stagedC {
		t.Fatalf("the staged edits went: %s", git("ls-files", "-s"))
	}
	if readIn(t, work, "a.txt") != "one\nSTAGED\nthree\n" || readIn(t, work, "c.txt") != "1\n2\n3\n4\nSTAGED\n" {
		t.Fatalf("tree: %q %q", readIn(t, work, "a.txt"), readIn(t, work, "c.txt"))
	}
	if st := git("status", "--porcelain"); st != "M  a.txt\nM  c.txt" {
		t.Fatalf("status = %q", st)
	}
}

// A staged copy that already matches the stash's lets git apply over it without looking at the tree,
// so the file can carry an unstaged edit on top: putting the staged copy back would lose that edit, so
// Undo Apply refuses, naming the file, and changes nothing.
func TestUndoApplyRefusesAnUnstagedEditOnAStagedCopy(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "c.txt", "1\n2\n3\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	writeIn(t, work, "c.txt", "S\n2\n3\n")
	w.Stash(ctx, "clashing", "default")
	writeIn(t, work, "a.txt", "one\nSTAGED\nthree\n")
	writeIn(t, work, "c.txt", "S\n2\n3\n")
	git("add", "a.txt", "c.txt")
	writeIn(t, work, "c.txt", "S\n2\n3\nUNSTAGED EXTRA\n")
	s, _ := ReadStashes(ctx, w.runner())
	_, clash, err := w.StashApply(ctx, 0, s[0].ID, false)
	if err != nil || clash == nil || !slices.Equal(clash.Conflicts, []string{"a.txt"}) {
		t.Fatalf("clash %+v err %v", clash, err)
	}
	before := git("ls-files", "-s", "-u")
	err = w.StashUndoApply(ctx, *clash)
	if err == nil || err.Error() != "c.txt has unstaged edits; Undo Apply would lose them — resolve it by hand" {
		t.Errorf("err = %v", err)
	}
	if readIn(t, work, "c.txt") != "S\n2\n3\nUNSTAGED EXTRA\n" {
		t.Fatalf("c.txt = %q", readIn(t, work, "c.txt"))
	}
	if git("ls-files", "-s", "-u") != before {
		t.Fatalf("the index changed: %s", git("ls-files", "-s"))
	}
}

// The same with nothing staged: HEAD already holds the stash's copy, so git applies over the file
// without looking at the tree, and putting it back to HEAD would lose the unstaged edit.
func TestUndoApplyRefusesAnUnstagedEditOverHEAD(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "c.txt", "1\n2\n3\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	writeIn(t, work, "c.txt", "S\n2\n3\n")
	w.Stash(ctx, "clashing", "default")
	writeIn(t, work, "a.txt", "one\nCOMMITTED\nthree\n")
	writeIn(t, work, "c.txt", "S\n2\n3\n")
	git("commit", "-qam", "moved on")
	writeIn(t, work, "c.txt", "S\n2\n3\nUNSTAGED EXTRA\n")
	s, _ := ReadStashes(ctx, w.runner())
	_, clash, err := w.StashApply(ctx, 0, s[0].ID, false)
	if err != nil || clash == nil || !slices.Equal(clash.Conflicts, []string{"a.txt"}) {
		t.Fatalf("clash %+v err %v", clash, err)
	}
	before := git("ls-files", "-s", "-u")
	err = w.StashUndoApply(ctx, *clash)
	if err == nil || err.Error() != "c.txt has unstaged edits; Undo Apply would lose them — resolve it by hand" {
		t.Errorf("err = %v", err)
	}
	if readIn(t, work, "c.txt") != "S\n2\n3\nUNSTAGED EXTRA\n" {
		t.Fatalf("c.txt = %q", readIn(t, work, "c.txt"))
	}
	if git("ls-files", "-s", "-u") != before {
		t.Fatalf("the index changed: %s", git("ls-files", "-s"))
	}
}

// A stash that renames c.txt to n.txt touches both names: listed with rename detection, only n.txt is
// recorded, so Undo Apply removed it and left c.txt deleted. Both names go back.
func TestUndoApplyPutsBackBothNamesOfARename(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "c.txt", "1\n2\n3\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	git("mv", "c.txt", "n.txt")
	w.Stash(ctx, "clashing", "default")
	writeIn(t, work, "a.txt", "one\nCOMMITTED\nthree\n")
	git("commit", "-qam", "moved on")
	s, _ := ReadStashes(ctx, w.runner())
	_, clash, err := w.StashApply(ctx, 0, s[0].ID, false)
	if err != nil || clash == nil || !slices.Equal(clash.Conflicts, []string{"a.txt"}) {
		t.Fatalf("clash %+v err %v", clash, err)
	}
	if err := w.StashUndoApply(ctx, *clash); err != nil {
		t.Fatal(err)
	}
	if st := git("status", "--porcelain"); st != "" || readIn(t, work, "c.txt") != "1\n2\n3\n" {
		t.Fatalf("status %q", st)
	}
}

// The same rename over an edit staged to c.txt: git merges the edit into n.txt and stages c.txt
// deleted. Undo Apply puts the staged edit back on c.txt, never loses it.
func TestUndoApplyKeepsAnEditStagedOnARenamedFile(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "c.txt", "1\n2\n3\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	git("mv", "c.txt", "n.txt")
	w.Stash(ctx, "clashing", "default")
	writeIn(t, work, "a.txt", "one\nCOMMITTED\nthree\n")
	git("commit", "-qam", "moved on")
	writeIn(t, work, "c.txt", "1\n2\n3\nSTAGED MINE\n")
	git("add", "c.txt")
	staged := git("rev-parse", ":c.txt")
	s, _ := ReadStashes(ctx, w.runner())
	_, clash, err := w.StashApply(ctx, 0, s[0].ID, false)
	if err != nil || clash == nil || !slices.Equal(clash.Conflicts, []string{"a.txt"}) {
		t.Fatalf("clash %+v err %v", clash, err)
	}
	if err := w.StashUndoApply(ctx, *clash); err != nil {
		t.Fatal(err)
	}
	if git("rev-parse", ":c.txt") != staged || readIn(t, work, "c.txt") != "1\n2\n3\nSTAGED MINE\n" {
		t.Fatalf("the staged edit went: %s", git("status", "--porcelain"))
	}
	if st := git("status", "--porcelain"); st != "M  c.txt" {
		t.Fatalf("status = %q", st)
	}
}

// Bring Them Along stashes the index too, so its clash has nothing staged to keep: Undo Apply puts
// the files back to the new branch's HEAD, the stash kept.
func TestUndoApplyAfterABringAlongClash(t *testing.T) {
	work, w, git := blockedFixture(t)
	git("add", "a.txt")
	r, err := w.Switch(context.Background(), "other", SwitchOptions{Carry: "bring"})
	if err != nil || r.Clash == nil {
		t.Fatalf("r = %+v err %v", r, err)
	}
	if err := w.StashUndoApply(context.Background(), *r.Clash); err != nil {
		t.Fatal(err)
	}
	if st := git("status", "--porcelain"); st != "" || readIn(t, work, "a.txt") != "one\nOTHER\nthree\n" {
		t.Fatalf("status %q a.txt %q", st, readIn(t, work, "a.txt"))
	}
	if git("stash", "list") == "" {
		t.Fatal("the stash went")
	}
}

// A file the clash recorded as absent (Hash "") that is there now is the operator's: refused.
func TestUndoApplyRefusesAFileRecreatedSinceTheClash(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "c.txt", "c\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	git("rm", "-q", "c.txt")
	w.Stash(ctx, "clashing", "default")
	writeIn(t, work, "a.txt", "one\nCOMMITTED\nthree\n")
	git("commit", "-qam", "moved on")
	s, _ := ReadStashes(ctx, w.runner())
	_, clash, err := w.StashApply(ctx, 0, s[0].ID, false)
	if err != nil || clash == nil {
		t.Fatalf("clash %+v err %v", clash, err)
	}
	var recorded bool
	for _, f := range clash.Files {
		recorded = recorded || (f.Path == "c.txt" && f.Hash == "")
	}
	if !recorded {
		t.Fatalf("files = %+v", clash.Files)
	}
	writeIn(t, work, "c.txt", "OPERATOR\n")
	err = w.StashUndoApply(ctx, *clash)
	if err == nil || err.Error() != "c.txt changed since the clash; Undo Apply would lose that — resolve it by hand" {
		t.Fatalf("err = %v", err)
	}
	if readIn(t, work, "c.txt") != "OPERATOR\n" {
		t.Fatal("the refusal changed c.txt")
	}
}
