package wakilcore

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// gitIn runs git in dir isolated from the user's global and system config, so
// a developer's includeIf/insteadOf rules cannot change what a test proves.
func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// gitTestRepo makes a repo with one committed file, a.txt = "one\n".
func gitTestRepo(t *testing.T) string {
	t.Helper()
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	gitIn(t, dir, "init", "-q", "-b", "main")
	gitIn(t, dir, "config", "user.email", "t@example.com")
	gitIn(t, dir, "config", "user.name", "t")
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("one\n"), 0o644)
	gitIn(t, dir, "add", "a.txt")
	gitIn(t, dir, "commit", "-q", "-m", "init")
	return dir
}

func TestRunnerRefusesARootOutsideTheProject(t *testing.T) {
	repo := gitTestRepo(t)
	if _, err := NewGitRunner(repo, []string{t.TempDir()}); err == nil {
		t.Fatal("want refusal for a root not in the project")
	}
}

func TestRunnerRefusesAWriteSubcommand(t *testing.T) {
	repo := gitTestRepo(t)
	g, _ := NewGitRunner(repo, []string{repo})
	// for-each-ref is not a write, but no reader needs it and its --format can verify a
	// signature, which runs the repository's gpg.program.
	for _, sub := range []string{"add", "commit", "checkout", "fetch", "push", "config", "-c", "for-each-ref"} {
		if _, err := g.Run(context.Background(), sub); err == nil {
			t.Errorf("%s: want refusal", sub)
		}
	}
}

func TestResolvePathRefusesEscape(t *testing.T) {
	repo := gitTestRepo(t)
	outside := t.TempDir()
	os.Symlink(outside, filepath.Join(repo, "link"))
	g, _ := NewGitRunner(repo, []string{repo})
	for _, p := range []string{"../x", "/etc/passwd", "link/x", "a/../../x"} {
		if _, err := g.ResolvePath(p); err == nil {
			t.Errorf("%q: want refusal", p)
		}
	}
	if got, err := g.ResolvePath("./a.txt"); err != nil || got != "a.txt" {
		t.Errorf("a.txt: got %q, %v", got, err)
	}
}

func TestRepoConfiguredProgramsNeverRun(t *testing.T) {
	repo := gitTestRepo(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "evil.sh")
	os.WriteFile(script, []byte("#!/bin/sh\ntouch "+marker+"\n"), 0o755)
	for _, kv := range [][2]string{
		{"core.fsmonitor", script},
		{"diff.external", script},
		{"core.pager", script},
	} {
		gitIn(t, repo, "config", kv[0], kv[1])
	}
	os.MkdirAll(filepath.Join(repo, ".git", "hooks"), 0o755)
	os.WriteFile(filepath.Join(repo, ".git", "hooks", "post-index-change"), []byte("#!/bin/sh\ntouch "+marker+"\n"), 0o755)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("two\n"), 0o644)

	g, _ := NewGitRunner(repo, []string{repo})
	if _, err := g.Run(context.Background(), "status", "--porcelain=v2", "-z", "--branch"); err != nil {
		t.Fatal(err)
	}
	if _, err := g.Run(context.Background(), "diff", "--", "a.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a repo-configured program ran")
	}
}

// R11: a clean/smudge/process filter named in the repo's own config — directly or through
// an include the local config pulls in — runs on `git status` and a worktree `git diff`
// unless neutralised. It never runs, and the status still reads.
func TestRepoConfiguredFiltersNeverRun(t *testing.T) {
	for _, viaInclude := range []bool{false, true} {
		repo := gitTestRepo(t)
		marker := filepath.Join(t.TempDir(), "ran")
		script := filepath.Join(t.TempDir(), "evil.sh")
		os.WriteFile(script, []byte("#!/bin/sh\ntouch "+marker+"\ncat\n"), 0o755)
		if viaInclude {
			inc := filepath.Join(t.TempDir(), "inc.cfg")
			os.WriteFile(inc, []byte("[filter \"evil.x\"]\n\tclean = "+script+"\n\tsmudge = "+script+
				"\n\tprocess = "+script+"\n\trequired = true\n"), 0o644)
			gitIn(t, repo, "config", "include.path", inc)
			os.WriteFile(filepath.Join(repo, ".gitattributes"), []byte("*.txt filter=evil.x\n"), 0o644)
		} else {
			for _, k := range []string{"clean", "smudge", "process"} {
				gitIn(t, repo, "config", "filter.evil."+k, script)
			}
			gitIn(t, repo, "config", "filter.evil.required", "true")
			os.WriteFile(filepath.Join(repo, ".gitattributes"), []byte("*.txt filter=evil\n"), 0o644)
		}
		os.WriteFile(filepath.Join(repo, "a.txt"), []byte("two\n"), 0o644)

		g, _ := NewGitRunner(repo, []string{repo})
		st, err := ReadGitStatus(context.Background(), g)
		if err != nil {
			t.Fatalf("include=%v: status: %v", viaInclude, err)
		}
		if len(st.Files) == 0 {
			t.Fatalf("include=%v: status read nothing", viaInclude)
		}
		if _, err := GitDiff(context.Background(), g, "a.txt", "changed"); err != nil {
			t.Fatalf("include=%v: diff: %v", viaInclude, err)
		}
		if _, err := os.Stat(marker); err == nil {
			t.Fatalf("include=%v: a repo-configured filter ran", viaInclude)
		}
	}
}

// R11: only the repo's own drivers are neutralised; one from the user's global config
// (git-lfs, installed per user) is left as it is — and still runs. The runner scrubs the
// environment (GIT_CONFIG_GLOBAL is dropped) but keeps HOME, so the global config is the
// `.gitconfig` under HOME.
func TestGlobalFilterDriversAreLeftAlone(t *testing.T) {
	repo := gitTestRepo(t)
	gitIn(t, repo, "config", "filter.mine.clean", "cat")
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "lfs.sh")
	os.WriteFile(script, []byte("#!/bin/sh\ntouch "+marker+"\ncat\n"), 0o755)
	home := t.TempDir()
	os.WriteFile(filepath.Join(home, ".gitconfig"), []byte("[filter \"lfs\"]\n\tclean = "+script+"\n"), 0o644)
	t.Setenv("HOME", home)
	g, _ := NewGitRunner(repo, []string{repo})
	args, err := g.repoFilterOverrides(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "filter.mine.clean=") || strings.Contains(joined, "filter.lfs.") {
		t.Fatalf("overrides = %q", joined)
	}
	os.WriteFile(filepath.Join(repo, ".gitattributes"), []byte("*.txt filter=lfs\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("two\n"), 0o644)
	if _, err := ReadGitStatus(context.Background(), g); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("the global filter driver did not run")
	}
}

// R11: a submodule's own filter driver never runs either. `git status` checks a submodule
// in a child git that reads the submodule's config, not the parent's overrides.
func TestSubmoduleConfiguredFiltersNeverRun(t *testing.T) {
	repo := gitTestRepo(t)
	sub := gitTestRepo(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "evil.sh")
	os.WriteFile(script, []byte("#!/bin/sh\ntouch "+marker+"\ncat\n"), 0o755)
	gitIn(t, repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sm")
	gitIn(t, repo, "commit", "-qm", "sm")
	gitIn(t, filepath.Join(repo, "sm"), "config", "filter.s.clean", script)
	os.WriteFile(filepath.Join(repo, "sm", ".gitattributes"), []byte("*.txt filter=s\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "sm", "a.txt"), []byte("two\n"), 0o644)

	g, _ := NewGitRunner(repo, []string{repo})
	if _, err := ReadGitStatus(context.Background(), g); err != nil {
		t.Fatal(err)
	}
	if _, err := GitDiff(context.Background(), g, "sm", "changed"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a submodule-configured filter ran")
	}

	// What the guard keeps: a submodule whose checked-out commit moved is still one
	// changed entry. (Dirt alone inside it, at the recorded commit, is not shown.)
	gitIn(t, filepath.Join(repo, "sm"), "-c", "filter.s.clean=", "commit", "-qam", "moved")
	os.Remove(marker)
	st, err := ReadGitStatus(context.Background(), g)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Files) != 1 || st.Files[0].Path != "sm" || st.Files[0].Group != "changed" {
		t.Fatalf("a moved submodule should be one changed entry: %+v", st.Files)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a submodule-configured filter ran")
	}
}

func TestNotARepository(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	g, _ := NewGitRunner(dir, []string{dir})
	_, err := g.Run(context.Background(), "status", "--porcelain=v2", "-z")
	if !errors.Is(err, ErrNotARepository) {
		t.Fatalf("got %v", err)
	}
}

func TestRunnerRefusesUnlistedFlags(t *testing.T) {
	repo := gitTestRepo(t)
	g, _ := NewGitRunner(repo, []string{repo})
	out := filepath.Join(t.TempDir(), "x")
	cases := [][]string{
		{"diff", "--output=" + out},
		{"diff", "--no-index", "a", "b"},
		{"diff", "--ext-diff"},
		{"diff", "--textconv"},
		{"status", "--git-dir=x"},
		{"show", "--output=" + out},
	}
	for _, c := range cases {
		if _, err := g.Run(context.Background(), c[0], c[1:]...); err == nil {
			t.Errorf("%v: want refusal", c)
		}
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("a refused flag still wrote a file")
	}
}

func TestRunnerAllowsTheFlagsTheReadersUse(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("two\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	ctx := context.Background()
	for _, c := range [][]string{
		{"status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"},
		{"diff", "--cached", "--no-color", "--", "a.txt"},
		{"diff", "--no-color", "--", "a.txt"},
		{"show", "HEAD:a.txt"},
		{"rev-parse", "--show-toplevel"},
		{"rev-parse", "--abbrev-ref", "HEAD"},
	} {
		if _, err := g.Run(ctx, c[0], c[1:]...); err != nil {
			t.Errorf("%v: %v", c, err)
		}
	}
}

func TestNotARepositoryInsideAParentRepo(t *testing.T) {
	parent := gitTestRepo(t)
	sub := filepath.Join(parent, "plain")
	os.Mkdir(sub, 0o755)
	g, _ := NewGitRunner(sub, []string{sub})
	_, err := g.Run(context.Background(), "status", "--porcelain=v2", "-z")
	if !errors.Is(err, ErrNotARepository) {
		t.Fatalf("got %v", err)
	}
	// R14: the ceiling keeps git off the parent; the text says why this root is not one.
	if err.Error() != "not a git repository (the repository is above this root)" {
		t.Fatalf("text = %q", err.Error())
	}
	if msg, ok := IsUserError(err); !ok || msg != err.Error() {
		t.Fatalf("IsUserError = %q, %v", msg, ok)
	}
}

// R14: a plain directory with no repository above it keeps the bare text.
func TestNotARepositoryWithNothingAbove(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	g, _ := NewGitRunner(dir, []string{dir})
	_, err := g.Run(context.Background(), "status", "--porcelain=v2", "-z")
	if err == nil || err.Error() != "not a git repository" {
		t.Fatalf("got %v", err)
	}
}

func TestResolvePathRefusesADanglingSymlinkOutside(t *testing.T) {
	repo := gitTestRepo(t)
	os.Symlink(filepath.Join(t.TempDir(), "nope"), filepath.Join(repo, "dangle"))
	os.Symlink("inside-missing", filepath.Join(repo, "ok"))
	g, _ := NewGitRunner(repo, []string{repo})
	if _, err := g.ResolvePath("dangle"); err == nil {
		t.Error("dangling outside link: want refusal")
	}
	if _, err := g.ResolvePath("ok"); err != nil {
		t.Errorf("dangling inside link: %v", err)
	}
}

// R11: the parent's own `diff.submodule` (diff or log) never makes `git diff` start a child
// git inside a submodule whose commit moved — that child reads the submodule's config, so its
// `diff.<driver>.command` would run. The diff of a moved submodule is the same `Subproject
// commit` pair whatever the parent sets.
func TestSubmoduleDiffNeverStartsAChildGit(t *testing.T) {
	for _, staged := range []bool{false, true} {
		texts := map[string]string{}
		for _, mode := range []string{"diff", "log", "short"} {
			repo := gitTestRepo(t)
			sub := gitTestRepo(t)
			marker := filepath.Join(t.TempDir(), "ran")
			script := filepath.Join(t.TempDir(), "evil.sh")
			mustWrite(t, script, "#!/bin/sh\ntouch "+marker+"\ncat\n", 0o755)
			gitIn(t, repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sm")
			gitIn(t, repo, "commit", "-qm", "sm")
			sm := filepath.Join(repo, "sm")
			mustWrite(t, filepath.Join(sm, "a.txt"), "moved\n", 0o644)
			gitIn(t, sm, "commit", "-qam", "moved")
			side := "changed"
			if staged {
				gitIn(t, repo, "add", "sm")
				side = "staged"
			}
			gitIn(t, sm, "config", "diff.t.command", script)
			gitIn(t, sm, "config", "diff.t.textconv", script)
			mustWrite(t, filepath.Join(sm, ".gitattributes"), "*.txt diff=t\n", 0o644)
			gitIn(t, repo, "config", "diff.submodule", mode)

			g, _ := NewGitRunner(repo, []string{repo})
			d, err := GitDiff(context.Background(), g, "sm", side)
			if err != nil {
				t.Fatalf("staged=%v mode=%s: %v", staged, mode, err)
			}
			if _, err := os.Stat(marker); err == nil {
				t.Fatalf("staged=%v mode=%s: a submodule-configured diff driver ran", staged, mode)
			}
			if !strings.Contains(d.Text, "+Subproject commit ") {
				t.Fatalf("staged=%v mode=%s: want the Subproject commit lines, got %q", staged, mode, d.Text)
			}
			// Hashes differ per repo; compare the shape only.
			texts[mode] = regexpHex.ReplaceAllString(d.Text, "H")
		}
		if texts["diff"] != texts["short"] || texts["log"] != texts["short"] {
			t.Fatalf("staged=%v: diff.submodule changed the output: %q", staged, texts)
		}
	}
}

var regexpHex = regexp.MustCompile(`[0-9a-f]{7,40}`)

// R11: `show` prints a commit with its diff when a gitlink names a commit in the repository's
// own object store (a crafted repo, or one that is its own submodule). If that commit moved a
// submodule, the parent's `diff.submodule=diff` would start a child git inside it, which runs
// the submodule's `diff.<driver>.command`. Neither the HEAD nor the index side may.
func TestShowOfAGitlinkToAParentCommitStartsNoChildGit(t *testing.T) {
	repo := gitTestRepo(t)
	sub := gitTestRepo(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "evil.sh")
	mustWrite(t, script, "#!/bin/sh\ntouch "+marker+"\ncat\n", 0o755)
	gitIn(t, repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sm")
	gitIn(t, repo, "commit", "-qm", "sm")
	sm := filepath.Join(repo, "sm")
	mustWrite(t, filepath.Join(sm, "a.txt"), "moved\n", 0o644)
	gitIn(t, sm, "commit", "-qam", "moved")
	gitIn(t, repo, "add", "sm")
	gitIn(t, repo, "commit", "-qm", "move sm") // HEAD now moves sm
	out, err := exec.Command("git", "-C", repo, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	gitIn(t, repo, "update-index", "--add", "--cacheinfo", "160000,"+strings.TrimSpace(string(out))+",lp")
	gitIn(t, repo, "commit", "-qm", "loop")
	gitIn(t, sm, "config", "diff.t.command", script)
	mustWrite(t, filepath.Join(sm, ".gitattributes"), "*.txt diff=t\n", 0o644)
	gitIn(t, repo, "config", "diff.submodule", "diff")

	g, _ := NewGitRunner(repo, []string{repo})
	for _, rev := range []string{"HEAD", "index"} {
		if _, err := GitShow(context.Background(), g, "lp", rev); err != nil {
			t.Fatalf("%s: %v", rev, err)
		}
		if _, err := os.Stat(marker); err == nil {
			t.Fatalf("%s: a submodule-configured diff driver ran", rev)
		}
	}
}

func mustWrite(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

// R11: `show` of a gitlink to a signed commit in the repository's own object store, with the
// repository's `log.showSignature=true`, would run its `gpg.program` (or ssh/x509 program) to
// verify the signature. Neither side may.
func TestShowOfASignedCommitRunsNoSigningProgram(t *testing.T) {
	repo := gitTestRepo(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "evil.sh")
	mustWrite(t, script, "#!/bin/sh\ntouch "+marker+"\n", 0o755)
	rev := func(r string) string {
		out, err := exec.Command("git", "-C", repo, "rev-parse", r).Output()
		if err != nil {
			t.Fatal(err)
		}
		return strings.TrimSpace(string(out))
	}
	commit := "tree " + rev("HEAD^{tree}") + "\nparent " + rev("HEAD") +
		"\nauthor t <t@example.com> 1700000000 +0000\ncommitter t <t@example.com> 1700000000 +0000" +
		"\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n AAAA\n -----END PGP SIGNATURE-----\n\nsigned\n"
	hash := exec.Command("git", "-C", repo, "hash-object", "-t", "commit", "-w", "--stdin")
	hash.Stdin = strings.NewReader(commit)
	out, err := hash.Output()
	if err != nil {
		t.Fatal(err)
	}
	gitIn(t, repo, "update-index", "--add", "--cacheinfo", "160000,"+strings.TrimSpace(string(out))+",sg")
	gitIn(t, repo, "commit", "-qm", "signed link")
	for _, kv := range [][2]string{{"log.showSignature", "true"}, {"gpg.program", script},
		{"gpg.openpgp.program", script}, {"gpg.ssh.program", script}, {"gpg.x509.program", script}} {
		gitIn(t, repo, "config", kv[0], kv[1])
	}

	g, _ := NewGitRunner(repo, []string{repo})
	for _, side := range []string{"HEAD", "index"} {
		if _, err := GitShow(context.Background(), g, "sg", side); err != nil {
			t.Fatalf("%s: %v", side, err)
		}
		if _, err := os.Stat(marker); err == nil {
			t.Fatalf("%s: the repository's signing program ran", side)
		}
	}
}

// partialCloneCases are a partial clone's promisor remotes whose fetch runs a program the
// repository chose.
func partialCloneCases(src string) map[string]func(script string) [][2]string {
	return map[string]func(script string) [][2]string{
		"uploadpack": func(s string) [][2]string {
			return [][2]string{{"remote.origin.url", src}, {"remote.origin.uploadpack", s}}
		},
		"sshCommand": func(s string) [][2]string {
			return [][2]string{{"remote.origin.url", "ssh://h.invalid/x"}, {"core.sshCommand", s}}
		},
		"ext": func(s string) [][2]string {
			return [][2]string{{"remote.origin.url", "ext::" + s}, {"protocol.ext.allow", "always"}}
		},
	}
}

// partialCloneRepo is a repo whose a.txt blob is missing (HEAD and index), a partial clone
// of a promisor remote configured by kvs, with a.txt modified. It answers the repo and the
// marker the script in kvs touches.
func partialCloneRepo(t *testing.T, kvs func(script string) [][2]string) (string, string) {
	t.Helper()
	repo := gitTestRepo(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "evil.sh")
	mustWrite(t, script, "#!/bin/sh\ntouch "+marker+"\nexit 1\n", 0o755)
	out, err := exec.Command("git", "-C", repo, "rev-parse", "HEAD:a.txt").Output()
	if err != nil {
		t.Fatal(err)
	}
	blob := strings.TrimSpace(string(out))
	if err := os.Remove(filepath.Join(repo, ".git", "objects", blob[:2], blob[2:])); err != nil {
		t.Fatal(err)
	}
	for _, kv := range append([][2]string{{"core.repositoryformatversion", "1"},
		{"extensions.partialClone", "origin"}, {"remote.origin.promisor", "true"}}, kvs(script)...) {
		gitIn(t, repo, "config", kv[0], kv[1])
	}
	mustWrite(t, filepath.Join(repo, "a.txt"), "dirty\n", 0o644)
	return repo, marker
}

// Charter (no network) and R11: in a partial clone, a read of a missing object would start a
// lazy `git fetch` from the promisor remote, which runs what the repository's config chooses
// (remote.<r>.uploadpack, core.sshCommand, an ext:: url). Wakil never fetches: nothing runs,
// and the side that needed the object says it is not present locally.
func TestPartialCloneNeverFetches(t *testing.T) {
	for name, kvs := range partialCloneCases(gitTestRepo(t)) {
		repo, marker := partialCloneRepo(t, kvs)
		g, _ := NewGitRunner(repo, []string{repo})
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		_, diffErr := GitDiff(ctx, g, "a.txt", "changed")
		_, headErr := GitShow(ctx, g, "a.txt", "HEAD")
		_, indexErr := GitShow(ctx, g, "a.txt", "index")
		cancel()
		if _, err := os.Stat(marker); err == nil {
			t.Fatalf("%s: a lazy fetch ran the repository's program", name)
		}
		for side, err := range map[string]error{"diff": diffErr, "HEAD": headErr, "index": indexErr} {
			if err == nil || !strings.Contains(err.Error(), "not present locally") {
				t.Errorf("%s %s: want a not-present-locally error, got %v", name, side, err)
			}
		}
	}
}

// GIT_NO_LAZY_FETCH exists from git 2.44 only. On an older git the lazy fetch still starts,
// and GIT_ALLOW_PROTOCOL=none is what refuses its transport. The scrubbed env holds both, and
// without GIT_NO_LAZY_FETCH the rest of it alone still runs nothing.
func TestPartialCloneNeverFetchesWithoutNoLazyFetch(t *testing.T) {
	repo := gitTestRepo(t)
	env := gitScrubbedEnv(repo)
	for _, want := range []string{"GIT_NO_LAZY_FETCH=1", "GIT_ALLOW_PROTOCOL=none"} {
		if !slices.Contains(env, want) {
			t.Fatalf("scrubbed env lacks %s: %q", want, env)
		}
	}
	for name, kvs := range partialCloneCases(gitTestRepo(t)) {
		repo, marker := partialCloneRepo(t, kvs)
		var old []string
		for _, kv := range gitScrubbedEnv(repo) {
			if !strings.HasPrefix(kv, "GIT_NO_LAZY_FETCH=") {
				old = append(old, kv)
			}
		}
		for _, args := range [][]string{{"show", "HEAD:a.txt"}, {"show", ":a.txt"}, {"diff", "--", "a.txt"}} {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			cmd := exec.CommandContext(ctx, "git", append([]string{"-C", repo, "--no-pager"}, args...)...)
			cmd.Env = old
			out, err := cmd.CombinedOutput()
			cancel()
			if err == nil {
				t.Errorf("%s %v: a missing object read without error: %s", name, args, out)
			}
			if !missingObject(string(out)) {
				t.Errorf("%s %v: not read as a missing object: %s", name, args, out)
			}
			if _, err := os.Stat(marker); err == nil {
				t.Fatalf("%s %v: a lazy fetch ran the repository's program", name, args)
			}
		}
	}
}
