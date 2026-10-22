package wakilcore

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

// GitRemoteOptions: AllowFileProtocol admits file:// remotes, which only tests and the e2e fixture
// (WAKIL_GIT_ALLOW_FILE=1, R5) use; WakilBin is the `wakil` binary the askpass and the credential
// helper call back into (default: beside this executable).
type GitRemoteOptions struct {
	AllowFileProtocol bool
	WakilBin          string
}

// GitRemoteResult is what a remote operation reports: git's last summary and progress lines, the
// conflicting paths of an aborted pull, and the branch's distance from its upstream afterwards.
type GitRemoteResult struct {
	Summary   string   `json:"summary"`
	Progress  string   `json:"progress,omitempty"`
	Conflicts []string `json:"conflicts,omitempty"`
	Ahead     int      `json:"ahead"`
	Behind    int      `json:"behind"`
}

// GitRemote runs 3a-iii's remote operations in one project root, with the organisation's account
// for the remote's host (Decision 44). It shares 3a-ii's per-root lock (R1): a commit and a push
// in one root never overlap. It never forces.
type GitRemote struct {
	Org, Root string
	Identity  GitIdentity
	opts      GitRemoteOptions
	trace     func(args []string) // tests: every git argument vector, before it runs
}

func NewGitRemote(org, root string, allowedRoots []string, opts GitRemoteOptions) (*GitRemote, error) {
	r, err := NewGitRunner(root, allowedRoots)
	if err != nil {
		return nil, err
	}
	o, _ := LoadOrgFor(org)
	return &GitRemote{Org: org, Root: r.Root, Identity: OrgGitIdentity(o), opts: opts}, nil
}

func (o GitRemoteOptions) wakilBin() string {
	if o.WakilBin != "" {
		return o.WakilBin
	}
	if exe, err := os.Executable(); err == nil {
		return filepath.Join(filepath.Dir(exe), "wakil")
	}
	return "wakil"
}

// remoteEnv is gitScrubbedEnv with the transports a remote operation needs: ssh and https (and
// file when allowed), never ext::, git:// or http://; prompts off; then the invocation's own.
func remoteEnv(dir string, allowFile bool, extra []string) []string {
	protocols := "ssh:https"
	if allowFile {
		protocols += ":file"
	}
	env := []string{}
	for _, kv := range gitScrubbedEnv(dir) {
		if strings.HasPrefix(kv, "GIT_ALLOW_PROTOCOL=") || strings.HasPrefix(kv, "GIT_NO_LAZY_FETCH=") {
			continue
		}
		env = append(env, kv)
	}
	env = append(env, "GIT_ALLOW_PROTOCOL="+protocols, "GCM_INTERACTIVE=never")
	return append(env, extra...)
}

// credentials resolves rawURL's host to the organisation's account and its invocation. A file
// remote needs none, and is refused unless allowed.
func credentials(org, rawURL string, opts GitRemoteOptions) (GitInvocation, GitAccount, string, error) {
	remote, err := ParseRemoteURL(rawURL)
	if err != nil {
		return GitInvocation{}, GitAccount{}, "", err
	}
	if remote.Scheme == "file" {
		if !opts.AllowFileProtocol {
			return GitInvocation{}, GitAccount{}, "", UserError("protocol not allowed: file")
		}
		return GitInvocation{}, GitAccount{}, "", nil
	}
	host := RemoteHost(remote)
	a, ok := GitAccountFor(org, host)
	if !ok {
		return GitInvocation{}, GitAccount{}, host, UserError("No git account for " + host + " in " + org +
			" — add one in Settings → Organisation → Git")
	}
	route := SSHRoute{HostName: host}
	if remote.Scheme == "ssh" {
		if r, err := ResolveSSHRoute(remote.Host); err == nil {
			route = r
		}
	}
	knownHosts := ""
	if dir, err := OrgDirFor(org); err == nil {
		knownHosts = filepath.Join(dir, "git", "known_hosts")
		os.MkdirAll(filepath.Dir(knownHosts), 0o700)
	}
	return RemoteInvocation(org, a, remote, route, opts.wakilBin(), knownHosts), a, host, nil
}

var (
	remoteURLCreds = regexp.MustCompile(`(https?://)[^/@\s]+@`)
	remoteSecrets  = regexp.MustCompile(`(?m)^(password|oauth_?token)=.*$`)
	remoteProgress = regexp.MustCompile(`[^\r\n]*\d+%[^\r\n]*`)
)

// scrubRemoteText drops credentials from git's words before anyone sees or journals them.
func scrubRemoteText(s string) string {
	s = remoteURLCreds.ReplaceAllString(s, "$1")
	return remoteSecrets.ReplaceAllString(s, "$1=…")
}

// remoteError maps git's words to what the operator can act on (spec, item 7); anything else is
// git's own text, scrubbed and whole up to 3a-ii's cap.
func remoteError(sub string, text string, a GitAccount, host string, err error) error {
	text = scrubRemoteText(text)
	switch {
	case strings.Contains(text, "non-fast-forward") || strings.Contains(text, "[rejected]") || strings.Contains(text, "fetch first"):
		return UserError("Rejected: the remote has newer commits. Pull or Sync first")
	case strings.Contains(text, "Permission denied (publickey)") || strings.Contains(text, "Authentication failed") ||
		strings.Contains(text, "could not read Username") || strings.Contains(text, "Invalid username or password"):
		who := a.User
		if who == "" {
			who = "this organisation's account"
		}
		return UserError("Authentication failed for " + who + " on " + host + " — Settings → Organisation → Git")
	}
	return gitWriteError(sub, []byte(text), nil, err)
}

// exec runs one git command in dir under the root's write lock, killing git's process group on
// cancel. It returns stdout and the combined, scrubbed stderr.
func (g *GitRemote) git(ctx context.Context, inv GitInvocation, sub string, args ...string) ([]byte, string, error) {
	m, _ := gitWriteLocks.LoadOrStore(g.Root, &sync.Mutex{})
	mu := m.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()
	return runRemoteGit(ctx, g.Root, g.Root, g.opts, g.Identity, inv, g.trace, sub, args...)
}

func runRemoteGit(ctx context.Context, dir, envRoot string, opts GitRemoteOptions, id GitIdentity, inv GitInvocation,
	trace func([]string), sub string, args ...string) ([]byte, string, error) {
	full := append([]string{"-C", dir}, gitWriteSafetyArgs...)
	// The repository's config may not choose a program for this command: Wakil's ssh and helper only.
	full = append(full, "-c", "core.sshCommand=", "-c", "core.askPass=", "-c", "credential.interactive=false")
	for _, k := range []string{"user", "author", "committer"} {
		if id.Name != "" {
			full = append(full, "-c", k+".name="+id.Name)
		}
		if id.Email != "" {
			full = append(full, "-c", k+".email="+id.Email)
		}
	}
	full = append(append(append(full, inv.Args...), sub), args...)
	if trace != nil {
		trace(full)
	}
	if err := ctx.Err(); err != nil {
		return nil, "", err
	}
	cmd := exec.Command("git", full...)
	cmd.Env = remoteEnv(envRoot, opts.AllowFileProtocol, inv.Env)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = gitWriteWaitDelay
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Start(); err != nil {
		return nil, "", err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-ctx.Done():
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return nil, "", ctx.Err()
	case err := <-done:
		if errors.Is(err, exec.ErrWaitDelay) {
			err = nil
		}
		return out.Bytes(), scrubRemoteText(errb.String()), err
	}
}

func lastProgress(stderr string) string {
	all := remoteProgress.FindAllString(stderr, -1)
	if len(all) == 0 {
		return ""
	}
	return strings.TrimSpace(all[len(all)-1])
}

// plain runs a local, credential-free git query in the root (no lock: reads only).
func (g *GitRemote) plain(args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", g.Root}, args...)...)
	cmd.Env = gitScrubbedEnv(g.Root)
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func (g *GitRemote) branch() (string, error) {
	b, err := g.plain("symbolic-ref", "--short", "HEAD")
	if err != nil || b == "" {
		return "", UserError("HEAD is detached: check out a branch first")
	}
	return b, nil
}

// upstream is the branch's remote and its remote branch, or ok false.
func (g *GitRemote) upstream(branch string) (remote, merge string, ok bool) {
	remote, err1 := g.plain("config", "branch."+branch+".remote")
	merge, err2 := g.plain("config", "branch."+branch+".merge")
	if err1 != nil || err2 != nil || remote == "" || merge == "" {
		return "", "", false
	}
	return remote, strings.TrimPrefix(merge, "refs/heads/"), true
}

// prepare finds remote's URL, refuses a repository-chosen pack program, and builds the invocation.
func (g *GitRemote) prepare(remote string) (GitInvocation, GitAccount, string, error) {
	for _, k := range []string{"uploadpack", "receivepack"} {
		if v, _ := g.plain("config", "remote."+remote+"."+k); v != "" {
			return GitInvocation{}, GitAccount{}, "", UserError("the repository sets remote." + remote + "." + k +
				"; Wakil does not run a program a repository chooses")
		}
	}
	url, err := g.plain("remote", "get-url", remote)
	if err != nil || url == "" {
		return GitInvocation{}, GitAccount{}, "", UserError("no remote named " + remote)
	}
	return credentials(g.Org, url, g.opts)
}

func (g *GitRemote) distance() (int, int) {
	out, err := g.plain("rev-list", "--left-right", "--count", "HEAD...@{u}")
	if err != nil {
		return 0, 0
	}
	f := strings.Fields(out)
	if len(f) != 2 {
		return 0, 0
	}
	a, _ := strconv.Atoi(f[0])
	b, _ := strconv.Atoi(f[1])
	return a, b
}

func (g *GitRemote) result(stdout []byte, stderr string) GitRemoteResult {
	a, b := g.distance()
	return GitRemoteResult{Summary: strings.TrimSpace(string(stdout)), Progress: lastProgress(stderr), Ahead: a, Behind: b}
}

// Fetch updates the remote-tracking branches of the branch's remote (origin without one).
func (g *GitRemote) Fetch(ctx context.Context) (GitRemoteResult, error) {
	remote := "origin"
	if b, err := g.branch(); err == nil {
		if r, _, ok := g.upstream(b); ok {
			remote = r
		}
	}
	inv, a, host, err := g.prepare(remote)
	if err != nil {
		return GitRemoteResult{}, err
	}
	out, stderr, err := g.git(ctx, inv, "fetch", "--prune", "--progress", remote)
	if err != nil {
		if ctx.Err() != nil {
			return GitRemoteResult{}, ctx.Err()
		}
		return GitRemoteResult{}, remoteError("fetch", stderr, a, host, err)
	}
	return g.result(out, stderr), nil
}

// Pull integrates the upstream by the organisation's strategy. A conflict aborts the rebase or
// merge, leaves the tree as it was, and reports the conflicting paths (3a-v resolves conflicts).
func (g *GitRemote) Pull(ctx context.Context) (GitRemoteResult, error) {
	branch, err := g.branch()
	if err != nil {
		return GitRemoteResult{}, err
	}
	remote, _, ok := g.upstream(branch)
	if !ok {
		return GitRemoteResult{}, UserError(branch + " has no upstream — Publish it first")
	}
	inv, a, host, err := g.prepare(remote)
	if err != nil {
		return GitRemoteResult{}, err
	}
	// A merge or rebase already under way is the operator's: refuse, so the abort below only ever
	// undoes what this pull started.
	if rebasing, merging := g.inProgress(); rebasing || merging {
		what := "A merge"
		if rebasing {
			what = "A rebase"
		}
		return GitRemoteResult{}, UserError(what + " is in progress in " + g.Root + "; finish or abort it first")
	}
	o, _ := LoadOrgFor(g.Org)
	mode := map[string]string{"rebase": "--rebase", "merge": "--no-rebase", "ff-only": "--ff-only"}[PullStrategyOf(o)]
	out, stderr, err := g.git(ctx, inv, "pull", mode, "--progress")
	if err == nil {
		return g.result(out, stderr), nil
	}
	if ctx.Err() != nil {
		// Cancelled part-way (an org switch stops wakil-git): nothing was under way before this
		// pull, so whatever is now is its own, and is undone.
		g.abortInProgress()
		return GitRemoteResult{}, ctx.Err()
	}
	if rebasing, merging := g.inProgress(); rebasing || merging {
		paths, _ := g.plain("diff", "--name-only", "--diff-filter=U")
		conflicts := strings.Fields(paths)
		g.abortInProgress()
		r := g.result(nil, stderr)
		r.Conflicts = conflicts
		return r, UserError("Pull stopped on conflicts in " + strings.Join(conflicts, ", ") +
			"; nothing was changed. Resolve them in a terminal, or wait for the conflict view (3a-v)")
	}
	return GitRemoteResult{}, remoteError("pull", stderr, a, host, err)
}

// inProgress reports a rebase or a merge stopped part-way in the repository.
func (g *GitRemote) inProgress() (rebasing, merging bool) {
	gitDir, _ := g.plain("rev-parse", "--git-dir")
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(g.Root, gitDir)
	}
	rebasing = fileExists(filepath.Join(gitDir, "rebase-merge")) || fileExists(filepath.Join(gitDir, "rebase-apply"))
	return rebasing, fileExists(filepath.Join(gitDir, "MERGE_HEAD"))
}

// abortInProgress aborts the rebase or merge this pull started.
func (g *GitRemote) abortInProgress() {
	switch rebasing, merging := g.inProgress(); {
	case rebasing:
		g.git(context.Background(), GitInvocation{}, "rebase", "--abort")
	case merging:
		g.git(context.Background(), GitInvocation{}, "merge", "--abort")
	}
}

// Push sends the branch to its upstream. It needs one (Publish makes it) and never forces.
func (g *GitRemote) Push(ctx context.Context) (GitRemoteResult, error) {
	branch, err := g.branch()
	if err != nil {
		return GitRemoteResult{}, err
	}
	remote, merge, ok := g.upstream(branch)
	if !ok {
		return GitRemoteResult{}, UserError(branch + " has no upstream — Publish it first")
	}
	inv, a, host, err := g.prepare(remote)
	if err != nil {
		return GitRemoteResult{}, err
	}
	out, stderr, err := g.git(ctx, inv, "push", "--progress", remote, "HEAD:refs/heads/"+merge)
	if err != nil {
		if ctx.Err() != nil {
			return GitRemoteResult{}, ctx.Err()
		}
		return GitRemoteResult{}, remoteError("push", stderr, a, host, err)
	}
	return g.result(out, stderr), nil
}

// Publish pushes a branch with no upstream to origin (else the only remote) and sets it.
func (g *GitRemote) Publish(ctx context.Context) (GitRemoteResult, error) {
	branch, err := g.branch()
	if err != nil {
		return GitRemoteResult{}, err
	}
	remotes, _ := g.plain("remote")
	names := strings.Fields(remotes)
	remote := ""
	for _, r := range names {
		if r == "origin" {
			remote = r
		}
	}
	if remote == "" && len(names) > 0 {
		remote = names[0]
	}
	if remote == "" {
		return GitRemoteResult{}, UserError("this repository has no remote to publish to")
	}
	inv, a, host, err := g.prepare(remote)
	if err != nil {
		return GitRemoteResult{}, err
	}
	out, stderr, err := g.git(ctx, inv, "push", "--progress", "--set-upstream", remote, branch)
	if err != nil {
		if ctx.Err() != nil {
			return GitRemoteResult{}, ctx.Err()
		}
		return GitRemoteResult{}, remoteError("push", stderr, a, host, err)
	}
	return g.result(out, stderr), nil
}

// Sync is Pull then Push, stopping at the first failure.
func (g *GitRemote) Sync(ctx context.Context) (GitRemoteResult, error) {
	if r, err := g.Pull(ctx); err != nil {
		return r, err
	}
	return g.Push(ctx)
}

// GitClone clones rawURL into dest (which must not exist) with the organisation's account for its
// host. A failed or cancelled clone removes the partial folder.
func GitClone(ctx context.Context, org, rawURL, dest string, opts GitRemoteOptions) (GitRemoteResult, error) {
	if !filepath.IsAbs(dest) {
		return GitRemoteResult{}, UserError("the destination must be an absolute path: " + dest)
	}
	if fileExists(dest) {
		return GitRemoteResult{}, UserError("the destination already exists: " + dest)
	}
	inv, a, host, err := credentials(org, rawURL, opts)
	if err != nil {
		return GitRemoteResult{}, err
	}
	parent := filepath.Dir(dest)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return GitRemoteResult{}, err
	}
	o, _ := LoadOrgFor(org)
	_, stderr, err := runRemoteGit(ctx, parent, dest, opts, OrgGitIdentity(o), inv, nil, "clone", "--progress", "--", rawURL, dest)
	if err != nil {
		os.RemoveAll(dest)
		if ctx.Err() != nil {
			return GitRemoteResult{}, ctx.Err()
		}
		return GitRemoteResult{}, remoteError("clone", stderr, a, host, err)
	}
	return GitRemoteResult{Summary: "cloned into " + dest, Progress: lastProgress(stderr)}, nil
}

// repositoryName is the folder a clone of rawURL gets: its last path part without .git.
func repositoryName(rawURL string) string {
	p := strings.TrimRight(strings.TrimSpace(rawURL), "/")
	if i := strings.LastIndexAny(p, "/:"); i >= 0 {
		p = p[i+1:]
	}
	return strings.TrimSuffix(p, ".git")
}

// CloneInto clones rawURL into folder/<repository name>. The operator may name any folder, and it
// becomes the organisation's last clone folder; the agent (operator false) may clone only into that
// folder (call 6), and with none named it is the default. It answers the clone's path.
func CloneInto(ctx context.Context, org, rawURL, folder string, operator bool, opts GitRemoteOptions) (string, GitRemoteResult, error) {
	o, err := LoadOrgFor(org)
	if err != nil {
		return "", GitRemoteResult{}, err
	}
	last := o.LastCloneFolder
	if folder == "" {
		folder = last
	}
	if folder == "" {
		return "", GitRemoteResult{}, UserError("choose a folder to clone into: + Add a project → Clone from a link…")
	}
	if !operator && folder != last {
		return "", GitRemoteResult{}, UserError("the agent clones only into " + last)
	}
	name := repositoryName(rawURL)
	if name == "" {
		return "", GitRemoteResult{}, UserError("not a repository link: " + rawURL)
	}
	dest := filepath.Join(folder, name)
	r, err := GitClone(ctx, org, rawURL, dest, opts)
	if err != nil {
		return "", r, err
	}
	if operator && folder != last {
		if o, err := LoadOrgFor(org); err == nil {
			o.LastCloneFolder = folder
			SaveOrg(org, *o)
		}
	}
	return dest, r, nil
}
