package wakilcore

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ErrNotARepository is what a root that is not inside a work tree answers.
// The pane draws it as the root's whole state, not as a failure to hide.
var ErrNotARepository = UserError("not a git repository")

// gitReadSubcommands is the whole of what wakil-git may run. 3a-i is read-only
// by construction: a write is not refused by a rule, it has no path to exec.
//
// for-each-ref is not here: no reader needs it, and its `--format=%(signature)` verifies a
// signature, which runs a signing program.
var gitReadSubcommands = map[string]bool{
	"status": true, "diff": true, "show": true, "rev-parse": true,
	// 3a-iv: the branch and stash lists. Plumbing that runs no program a repository chooses.
	"for-each-ref": true, "rev-list": true, "log": true,
}

// gitSafetyArgs come before the subcommand on every call, so a repository's
// own config cannot make Wakil run a program.
var gitSafetyArgs = []string{
	"-c", "core.fsmonitor=false",
	"-c", "core.hooksPath=/dev/null",
	"-c", "core.pager=cat",
	"-c", "diff.external=",
	// `show` of a signed commit (a gitlink can name one in the repository's own object store)
	// verifies it under `log.showSignature=true`, running the repository's `gpg.program`.
	// Off, nothing is verified. The programs are emptied as well, so no other path to a
	// verification runs one: git 2.54 tries to exec an empty program, fails with "cannot
	// run", and runs nothing (measured with GIT_TRACE, for openpgp, ssh and x509).
	"-c", "log.showSignature=false",
	"-c", "gpg.program=",
	"-c", "gpg.openpgp.program=",
	"-c", "gpg.ssh.program=",
	"-c", "gpg.x509.program=",
	"--no-pager",
}

// gitAllowedFlags is, per subcommand, every flag a caller may pass. Anything
// else that starts with "-" is refused before exec: git's own flags can write
// files (--output), read outside the root (--no-index, --git-dir) or turn a
// program back on (--ext-diff, --textconv). Arguments after "--" are pathspecs
// and are not inspected. A key ending in "=" matches by prefix.
var gitAllowedFlags = map[string][]string{
	"status":       {"--porcelain=v2", "-z", "--branch", "--untracked-files=all"},
	"diff":         {"--cached", "--no-color", "--name-only", "-z", "--"},
	"show":         {"--name-only", "--format=", "-z", "--"},
	"rev-parse":    {"--show-toplevel", "--abbrev-ref", "--verify", "--short", "--absolute-git-dir", "--"},
	"for-each-ref": {"--sort=", "--format="},
	"rev-list":     {"--count"},
	"log":          {"-g", "--format=", "-z", "--follow", "--max-count=", "--skip=", "--name-status", "--"},
}

// checkGitFlags refuses the first flag of args that sub does not allow.
func checkGitFlags(sub string, args []string) error {
	for _, a := range args {
		// A format asking for a signature verifies it, which runs the repository's gpg.program.
		if f, ok := strings.CutPrefix(a, "--format="); ok && (strings.Contains(f, "%(signature") || strings.Contains(f, "%G")) {
			return UserError("wakil-git does not read signatures: " + a)
		}
		if a == "--" {
			return nil
		}
		if !strings.HasPrefix(a, "-") {
			continue
		}
		ok := false
		for _, f := range gitAllowedFlags[sub] {
			if a == f || (strings.HasSuffix(f, "=") && strings.HasPrefix(a, f)) {
				ok = true
				break
			}
		}
		if !ok {
			return UserError("wakil-git does not allow the flag " + a + " on " + sub)
		}
	}
	return nil
}

// GitRunner runs allowlisted read-only git subcommands in one project root.
type GitRunner struct{ Root string }

func NewGitRunner(root string, allowedRoots []string) (*GitRunner, error) {
	real, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, UserError("root " + root + " is not readable: " + err.Error())
	}
	for _, a := range allowedRoots {
		if ar, err := filepath.EvalSymlinks(a); err == nil && ar == real {
			return &GitRunner{Root: real}, nil
		}
	}
	return nil, UserError("root " + root + " is not a root of the active project")
}

func (g *GitRunner) Run(ctx context.Context, sub string, args ...string) ([]byte, error) {
	if !gitReadSubcommands[sub] {
		return nil, UserError("wakil-git reads only with status, diff, show, rev-parse, for-each-ref, rev-list, log and blame; refused: " + sub)
	}
	if err := checkGitFlags(sub, args); err != nil {
		return nil, err
	}
	filters, err := g.repoFilterOverrides(ctx)
	if err != nil {
		return nil, err
	}
	pre := append(append([]string{}, gitSafetyArgs...), filters...)
	if sub == "diff" || sub == "show" {
		args = append([]string{"--no-ext-diff", "--no-textconv"}, args...)
	}
	// A submodule's worktree is never looked into (R11). To tell whether a submodule is
	// dirty, status and diff start a child git inside it, and that child reads the
	// submodule's own config — its filter drivers, which the overrides above (read from
	// the parent's config) do not name. `--ignore-submodules=dirty` starts no child
	// (measured with GIT_TRACE on git 2.54) and still compares the submodule's checked-out
	// commit to the recorded one, so a submodule whose commit moved is still one changed
	// entry, staged or not. What it loses: a submodule with only modified or untracked
	// files inside it, at the recorded commit, shows as unchanged. Enumerating each
	// submodule's drivers was the alternative; it means reading every nested config
	// (and theirs) before each call, and one missed scope runs a program. The flag is
	// added here, not allowlisted, so a caller cannot pass a weaker one.
	if sub == "status" || sub == "diff" {
		args = append([]string{"--ignore-submodules=dirty"}, args...)
	}
	// The same child git, by another door: a moved submodule under the repository's own
	// `diff.submodule=diff` makes `git diff` run `git diff --submodule=diff` inside the
	// submodule, which reads its config (a `diff.<driver>.command` there runs) and gets
	// none of the flags above. `git show` does too, when it prints a commit's diff — a
	// gitlink can name a commit in the repository's own object store. On both `diff` and
	// `show`, `--submodule=short` overrides the config, starts no child, and keeps the
	// `Subproject commit` lines; `log` would only have added a summary.
	if sub == "diff" || sub == "show" {
		args = append([]string{"--submodule=short"}, args...)
	}
	out, errText, err := g.exec(ctx, pre, sub, args)
	if err != nil {
		if strings.Contains(errText, "not a git repository") {
			if repositoryAbove(g.Root) {
				return nil, ErrRepositoryAbove
			}
			return nil, ErrNotARepository
		}
		if errText == "" {
			errText = err.Error()
		}
		if missingObject(errText) {
			return nil, UserError("git " + sub + ": object not present locally " +
				"(partial clone; Wakil never fetches): " + errText)
		}
		return nil, UserError("git " + sub + ": " + errText)
	}
	return out, nil
}

// missingObject reports whether git failed for want of an object it does not hold: what a
// partial clone answers once GIT_NO_LAZY_FETCH stops the fetch (`show`: "bad object", `diff`:
// "unable to read" after "lazy fetching disabled"; an older git, "transport '…' not allowed"). A damaged repository says the same; the
// message carries git's own text either way.
func missingObject(errText string) bool {
	for _, s := range []string{"lazy fetching disabled", "fatal: bad object ", "fatal: unable to read ",
		"' not allowed"} { // "transport 'ssh' not allowed": an older git's refused fetch
		if strings.Contains(errText, s) {
			return true
		}
	}
	return false
}

// ErrRepositoryAbove is ErrNotARepository for a root inside another repository's work
// tree (R14). GIT_CEILING_DIRECTORIES keeps git from reading that parent's state as the
// root's; this says why the root is not one, so the operator is not left wondering.
var ErrRepositoryAbove error = &userError{
	msg: "not a git repository (the repository is above this root)", kind: ErrNotARepository}

// repositoryAbove reports whether a directory above root holds a `.git` (a directory, or
// a linked worktree's file).
func repositoryAbove(root string) bool {
	for dir := filepath.Dir(root); ; dir = filepath.Dir(dir) {
		if _, err := os.Lstat(filepath.Join(dir, ".git")); err == nil {
			return true
		}
		if parent := filepath.Dir(dir); parent == dir {
			return false
		}
	}
}

// exec runs git with the scrubbed environment: `-C root`, then pre, then sub and args.
// Every git process wakil-git starts goes through here.
func (g *GitRunner) exec(ctx context.Context, pre []string, sub string, args []string) ([]byte, string, error) {
	full := append([]string{"-C", g.Root}, pre...)
	full = append(full, sub)
	full = append(full, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	cmd.Env = gitScrubbedEnv(g.Root)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	return out.Bytes(), strings.TrimSpace(errb.String()), err
}

// ConfigValue reads one config key through git, every scope followed. The argv is fixed
// here, not a `config` entry in the public allowlist (as repoFilterOverrides does), so a
// caller cannot reach `config <key> <value>`. An unset key, or any failure, is "".
func (g *GitRunner) ConfigValue(ctx context.Context, key string) string {
	out, _, err := g.exec(ctx, gitSafetyArgs, "config", []string{"--get", key})
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// repoFilterOverrides neutralises every clean/smudge/process filter driver the repository's
// own config defines (R11): `git status` and a worktree `git diff` run a file's filter, so a
// driver in `.git/config` is a program the repository chose. A driver from the user's global
// or system config (git-lfs) is the operator's own and is left alone.
//
// **Read through git, with every scope and include followed, and keyed by scope** —
// `config --show-scope -z --get-regexp ^filter\.` — rather than `config --local`: `--local`
// reads `.git/config` alone and skips its `include.path` (measured on git 2.54), so a driver
// defined in an included file, or in a linked worktree's `config.worktree`, would run while
// the local read said there was none. Git resolves the gitdir itself, linked worktrees
// included. The argv is fixed here, not a `config` entry in the public allowlist: the flag
// check does not inspect positionals, and `git config <key> <value>` writes.
//
// Each driver gets `clean=`, `smudge=`, `process=` emptied and `required=false`, which a
// `required` driver otherwise turns into a refusal to read the file at all. A driver whose
// name holds `=` cannot be overridden on git's command line; the read is refused instead.
func (g *GitRunner) repoFilterOverrides(ctx context.Context) ([]string, error) {
	out, _, err := g.exec(ctx, gitSafetyArgs, "config", []string{"--show-scope", "-z", "--get-regexp", `^filter\.`})
	if err != nil {
		// Exit 1 is "no such key"; anything else (not a repository, unreadable config) is
		// left for the command proper to report in its own words.
		return nil, nil
	}
	seen := map[string]bool{}
	var overrides []string
	// -z --show-scope: "scope\0key\nvalue\0" per entry.
	fields := strings.Split(string(out), "\x00")
	for i := 0; i+1 < len(fields); i += 2 {
		scope, kv := fields[i], fields[i+1]
		if scope != "local" && scope != "worktree" {
			continue
		}
		key, _, _ := strings.Cut(kv, "\n")
		name := strings.TrimPrefix(key, "filter.")
		dot := strings.LastIndex(name, ".")
		if dot <= 0 {
			continue
		}
		name = name[:dot]
		if seen[name] {
			continue
		}
		seen[name] = true
		if strings.Contains(name, "=") {
			return nil, UserError("the repository's config defines a filter wakil-git cannot switch off: " + name)
		}
		for _, k := range []string{"clean=", "smudge=", "process=", "required=false"} {
			overrides = append(overrides, "-c", "filter."+name+"."+k)
		}
	}
	return overrides, nil
}

// gitScrubbedEnv keeps only what git needs to find itself and the user's
// identity files; every GIT_* the parent had is dropped.
//
// GIT_NO_LAZY_FETCH=1: in a partial clone, a read of a missing object would start a
// `git fetch` from the promisor remote — network access, and a child that runs what the
// repository's config chooses (remote.<r>.uploadpack, core.sshCommand, an ext:: url, a
// credential helper). With it set, git answers that the object is missing instead.
//
// GIT_CEILING_DIRECTORIES is the root's parent, so git looks at the root itself
// and never walks up: a root that is not a repo but sits inside one (a dotfiles
// repo at ~) answers ErrNotARepository instead of the parent's state.
func gitScrubbedEnv(root string) []string {
	env := []string{"GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0", "LC_ALL=C",
		// Both, because GIT_NO_LAZY_FETCH exists only from git 2.44; on older git the fetch
		// still starts and GIT_ALLOW_PROTOCOL=none refuses every transport it would use.
		"GIT_NO_LAZY_FETCH=1", "GIT_ALLOW_PROTOCOL=none",
		"GIT_CEILING_DIRECTORIES=" + filepath.Dir(root)}
	for _, k := range []string{"HOME", "PATH", "TMPDIR", "USER"} {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	return env
}

func (g *GitRunner) ResolvePath(rel string) (string, error) {
	if filepath.IsAbs(rel) {
		return "", UserError("path must be relative to the root: " + rel)
	}
	joined := filepath.Join(g.Root, rel)
	if !strings.HasPrefix(joined+string(filepath.Separator), g.Root+string(filepath.Separator)) {
		return "", UserError("path escapes the root: " + rel)
	}
	// A symlink that leaves the root is an escape too. A path that does not
	// exist (a deletion) is checked through its nearest existing parent.
	probe := joined
	for {
		// A dangling symlink fails EvalSymlinks like a missing path would, so
		// read the link itself and refuse one that points outside the root.
		if fi, err := os.Lstat(probe); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			if _, err := filepath.EvalSymlinks(probe); errors.Is(err, os.ErrNotExist) {
				target, _ := os.Readlink(probe)
				if !filepath.IsAbs(target) {
					target = filepath.Join(filepath.Dir(probe), target)
				}
				target = filepath.Clean(target)
				if target != g.Root && !strings.HasPrefix(target, g.Root+string(filepath.Separator)) {
					return "", UserError("path escapes the root: " + rel)
				}
			}
		}
		if real, err := filepath.EvalSymlinks(probe); err == nil {
			if real != g.Root && !strings.HasPrefix(real, g.Root+string(filepath.Separator)) {
				return "", UserError("path escapes the root: " + rel)
			}
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			return "", UserError("path unreadable: " + err.Error())
		}
		probe = filepath.Dir(probe)
	}
	return filepath.Rel(g.Root, joined)
}
