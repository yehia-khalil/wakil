# 3a-i Git Pane (read-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dual-driven, read-only `git` pane that lists every root of the active project with its Staged / Changes / Untracked files, drills into a Monaco diff with the list folded into a spine, and stays live as files change.

**Architecture:** A new headless Go MCP server, `wakil-git`, runs the system `git` through one allowlisted, environment-scrubbed runner and serves `git_status`, `git_diff` and `git_show`. WakilKit gains a `GitSnapshot` in `PaneStore`, four pane actions, pure functions for step order and post-refresh selection, an FSEvents watcher behind a protocol, and a `GitSource` for the identifier resolver. WakilApp gains `GitPane` and a `MonacoDiffRenderer` (`WKWebView`, Monaco vendored) behind WakilKit's `DiffRenderer` protocol.

**Tech Stack:** Go 1.x + `github.com/modelcontextprotocol/go-sdk/mcp`; Swift 6 / SwiftUI / swift-testing; WebKit (`WKWebView`, `WKContentRuleList`); CoreServices FSEvents; Monaco Editor (MIT), vendored.

**Spec:** `docs/superpowers/specs/2026-10-08-3a-i-git-pane-read-design.md`

## Global Constraints

- Read-only. `wakil-git` runs only `status`, `diff`, `show`, `rev-parse`; any other subcommand is refused before `exec`. (`for-each-ref` was dropped in the final fix round: no reader needs it, and its `%(signature)` format runs a signing program.)
- Every git call passes `--no-ext-diff --no-textconv -c core.fsmonitor=false -c core.hooksPath=/dev/null` (the `-c` pairs before the subcommand) and runs with `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0` and a scrubbed environment.
- A `root` argument must equal one of the active project's `wakilcore.ProjectRootPaths`; a `path` is resolved against it and refused if it escapes it, symlinks included.
- Caps: diffs 5,000 lines, files 2 MB (2,097,152 bytes); past a cap the result says so with `truncated: true` and the true size.
- No network, ever. Monaco loads from the bundle with every non-`file:` request blocked.
- Deletions in the diff are a muted tone, never §5 red `#e85c5c`. Additions use §5 green `#8be0c8`.
- Watcher coalescing window: 300 ms.
- Spine width: 26 px.
- Group order: Staged, Changes, Untracked. Step order: roots in project order, then group order, then path (byte order).
- Copy, verbatim: `clean` · `not a git repository` · `binary · <size>` · `diff is <N> lines · first 5,000 shown`.
- Every existing consumer of `WindowModel.rootPath` keeps its exact behaviour (`rootPaths.first`).
- No `Co-Authored-By` trailer on commits (operator rule).

## Review Focus

1. **A file in two groups** (partly staged) — the operator expects two rows and two different diffs, and stepping visits both. Pinned in Task 3 (parser) and Task 7 (step order).
2. **The selected file disappears on refresh** (committed or reverted in a terminal) — the selection lands on the row now in its place, or the list unfolds; never a jump to the top. Pinned in Task 7.
3. **A repo whose config names a program** (`core.fsmonitor`, a hook, an external diff driver) — Wakil must never run it. Pinned in Task 2.
4. **A path with spaces, unicode, or a rename** — porcelain `-z` parsing must keep it whole and show `old → new`. Pinned in Task 3.
5. **Two roots, one broken** (corrupt index, deleted directory) — the broken root shows its error whole and the other still lists. Pinned in Task 6 (snapshot) and Task 4 (tool error is per-root).

---

## File Structure

| File | Responsibility |
|---|---|
| `internal/wakilcore/gitread.go` | The one git runner: allowlist, scrubbed env, root/path validation, caps |
| `internal/wakilcore/gitstatus.go` | Porcelain v2 `-z` parser → `GitStatus` |
| `internal/wakilcore/gitdiff.go` | `GitDiff` and `GitShow` built on the runner |
| `cmd/wakil-git/main.go` | MCP server: `git_status`, `git_diff`, `git_show` |
| `app/Resources/monaco/` (vendored) + `app/Sources/WakilApp/monaco-host.html` | Monaco bundle and the host page |
| `app/Sources/WakilKit/Git/GitSnapshot.swift` | Pane state types |
| `app/Sources/WakilKit/Git/GitNavigation.swift` | Pure: step order, post-refresh selection |
| `app/Sources/WakilKit/Git/GitActions.swift` | `git_select`, `git_step`, `git_fold`, `git_unfold`, `git_refresh` |
| `app/Sources/WakilKit/Git/GitWatcher.swift` | `RootWatcher` protocol + `FSEventsRootWatcher` + debounce |
| `app/Sources/WakilKit/Git/DiffRenderer.swift` | The seam the editor reuses |
| `app/Sources/WakilKit/Git/GitSource.swift` | `IdentifierSource` for visible paths |
| `app/Sources/WakilApp/GitPane.swift` | The list, the spine, keyboard |
| `app/Sources/WakilApp/MonacoDiffRenderer.swift` | `WKWebView` conformance |

---

### Task 1: Probe — Monaco renders a diff inside the built Wakil.app, offline

**Stop gate.** If any expected result below fails, stop and report to the operator; do not start Task 2.

**Files:**
- Create: `app/Resources/monaco/` (vendored `min/vs` from `monaco-editor`), `app/Resources/monaco/VERSION` (version + sha256 of the tarball), `app/Resources/monaco/LICENSE`
- Create: `app/Sources/WakilApp/monaco-host.html`
- Create: `app/Sources/WakilApp/MonacoDiffRenderer.swift` (probe-sized first version; Task 10 completes it)
- Modify: `app/Package.swift` (WakilApp resources), `app/Sources/WakilApp/main.swift` (a `--probe-monaco <dir>` flag beside `--capture`)
- Create: `docs/wakil/3a-i-monaco-probe.md`

**Interfaces:**
- Produces: `monaco-host.html` exposing `window.wakilShowDiff(original, modified, language)` and posting `ready` / `shown` messages to `window.webkit.messageHandlers.wakil`.

- [ ] **Step 1: Vendor Monaco**

```bash
cd /Users/operator/orca/workspaces/wakil/burrfish
mkdir -p .context/monaco && cd .context/monaco
npm pack monaco-editor@0.52.2
shasum -a 256 monaco-editor-0.52.2.tgz
tar xzf monaco-editor-0.52.2.tgz
cd ../..
mkdir -p app/Resources/monaco
cp -R .context/monaco/package/min/vs app/Resources/monaco/vs
cp .context/monaco/package/LICENSE app/Resources/monaco/LICENSE
printf 'monaco-editor 0.52.2\nsha256 <paste the shasum line printed above>\n' > app/Resources/monaco/VERSION
du -sh app/Resources/monaco
```

Expected: `du` prints a size; record it. Replace the `<paste…>` text with the real hash before committing.

- [ ] **Step 2: Write the host page** — `app/Sources/WakilApp/monaco-host.html`

```html
<!doctype html>
<html><head><meta charset="utf-8">
<style>html,body,#d{margin:0;height:100%;background:#0b0d14}</style></head>
<body><div id="d"></div>
<script src="vs/loader.js"></script>
<script>
  require.config({ paths: { vs: 'vs' } });
  require(['vs/editor/editor.main'], function () {
    monaco.editor.defineTheme('wakil', {
      base: 'vs-dark', inherit: true, rules: [],
      colors: {
        'editor.background': '#0b0d14',
        'diffEditor.insertedTextBackground': '#8be0c82a',
        'diffEditor.insertedLineBackground': '#8be0c814',
        'diffEditor.removedTextBackground': '#c9a0a024',
        'diffEditor.removedLineBackground': '#c9a0a012'
      }
    });
    const editor = monaco.editor.createDiffEditor(document.getElementById('d'), {
      theme: 'wakil', readOnly: true, originalEditable: false,
      renderSideBySide: false, automaticLayout: true, minimap: { enabled: false }
    });
    window.wakilShowDiff = function (original, modified, language) {
      const o = monaco.editor.createModel(original, language);
      const m = monaco.editor.createModel(modified, language);
      const old = editor.getModel();
      editor.setModel({ original: o, modified: m });
      if (old) { old.original.dispose(); old.modified.dispose(); }
      window.webkit.messageHandlers.wakil.postMessage({ type: 'shown' });
    };
    window.webkit.messageHandlers.wakil.postMessage({ type: 'ready' });
  });
</script></body></html>
```

- [ ] **Step 3: Ship both as resources** — in `app/Package.swift`, the WakilApp target:

```swift
            resources: [
                .copy("default.metallib"),
                .copy("monaco-host.html"),
                .copy("../../Resources/monaco"),
            ]),
```

If SwiftPM refuses a resource path outside the target directory, move the vendored tree to `app/Sources/WakilApp/monaco/` instead, use `.copy("monaco")`, and record the move in the probe doc.

- [ ] **Step 4: Probe renderer** — `app/Sources/WakilApp/MonacoDiffRenderer.swift`

```swift
import AppKit
import WebKit

/// The Monaco host. Probe-sized in Task 1; Task 10 adds `DiffRenderer` conformance.
@MainActor
final class MonacoDiffRenderer: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private(set) var ready = false
    private var onReady: [() -> Void] = []
    var onShown: (() -> Void)?

    init(blockNetwork: WKContentRuleList?) {
        let config = WKWebViewConfiguration()
        if let blockNetwork { config.userContentController.add(blockNetwork) }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "wakil")
        let root = Bundle.module.resourceURL!
        webView.loadFileURL(root.appendingPathComponent("monaco-host.html"), allowingReadAccessTo: root)
    }

    /// Blocks every request that is not `file:`.
    static func compileNetworkBlock() async throws -> WKContentRuleList? {
        let rules = #"[{"trigger":{"url-filter":"^(?!file:).*"},"action":{"type":"block"}}]"#
        return try await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "wakil-monaco-offline", encodedContentRuleList: rules)
    }

    func show(original: String, modified: String, language: String) {
        let run = { [weak self] in
            guard let self else { return }
            let args = [original, modified, language].map(Self.jsString).joined(separator: ",")
            self.webView.evaluateJavaScript("wakilShowDiff(\(args))")
        }
        if ready { run() } else { onReady.append(run) }
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let type = (message.body as? [String: Any])?["type"] as? String
        MainActor.assumeIsolated {
            if type == "ready" { ready = true; onReady.forEach { $0() }; onReady = [] }
            if type == "shown" { onShown?() }
        }
    }

    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }
}
```

- [ ] **Step 5: The probe flag** — in `main.swift`, beside the `--capture` handling, add a `--probe-monaco <dir>` branch that opens an offscreen 900×600 window with a `MonacoDiffRenderer`, shows a 200-line Swift diff, waits for `shown`, writes `<dir>/monaco-probe.png` (via `webView.takeSnapshot`) and `<dir>/monaco-probe.txt` containing `ready_ms=<n> shown_ms=<n>`, then exits 0; exits 1 with the reason on a 10 s timeout. Follow `capturePath(in:)`'s parsing pattern for the flag.

- [ ] **Step 6: Run it against the shippable artefact**

```bash
cd /Users/operator/orca/workspaces/wakil/burrfish
make app-bundle
mkdir -p .context/3a-i
app/Wakil.app/Contents/MacOS/Wakil --probe-monaco "$PWD/.context/3a-i"; rc=$?; echo "rc=$rc"
cat .context/3a-i/monaco-probe.txt
du -sh app/Wakil.app
```

Expected: `rc=0`; `monaco-probe.txt` has both timings; the PNG (open it with the Read tool) shows a dark inline diff with green additions and muted deletions. Then repeat with Wi-Fi off (`networksetup -setairportpower en0 off`, run, `networksetup -setairportpower en0 on`) — same result.

- [ ] **Step 7: Record** — write `docs/wakil/3a-i-monaco-probe.md`: Monaco version and hash, vendored size, bundle size before/after, `ready_ms`, `shown_ms`, offline result, and any resource-path move from Step 3.

- [ ] **Step 8: Commit**

```bash
git add app/Resources/monaco app/Sources/WakilApp/monaco-host.html app/Sources/WakilApp/MonacoDiffRenderer.swift app/Package.swift app/Sources/WakilApp/main.swift docs/wakil/3a-i-monaco-probe.md
git commit -m "3a-i probe: Monaco renders a diff inside the built Wakil.app, offline"
```

---

### Task 2: The read-only git runner

**Files:**
- Create: `internal/wakilcore/gitread.go`
- Test: `internal/wakilcore/gitread_test.go`

**Interfaces:**
- Produces:
  - `type GitRunner struct{ Root string }`
  - `func NewGitRunner(root string, allowedRoots []string) (*GitRunner, error)` — refuses a root not in `allowedRoots` (compared after `filepath.EvalSymlinks` on both sides).
  - `func (g *GitRunner) Run(ctx context.Context, sub string, args ...string) ([]byte, error)` — refuses non-allowlisted `sub`.
  - `func (g *GitRunner) ResolvePath(rel string) (string, error)` — returns the cleaned repo-relative path, refuses escape.
  - `var ErrNotARepository = UserError("not a git repository")`
  - `func gitTestRepo(t *testing.T) string` (test helper, in `gitread_test.go`, reused by Tasks 3–4)

- [ ] **Step 1: Write the failing tests**

```go
package wakilcore

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// gitTestRepo makes a repo with one committed file, a.txt = "one\n".
func gitTestRepo(t *testing.T) string {
	t.Helper()
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	run("config", "user.email", "t@example.com")
	run("config", "user.name", "t")
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("one\n"), 0o644)
	run("add", "a.txt")
	run("commit", "-q", "-m", "init")
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
	for _, sub := range []string{"add", "commit", "checkout", "fetch", "push", "config", "-c"} {
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
		exec.Command("git", "-C", repo, "config", kv[0], kv[1]).Run()
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

func TestNotARepository(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	g, _ := NewGitRunner(dir, []string{dir})
	_, err := g.Run(context.Background(), "status", "--porcelain=v2", "-z")
	if !errors.Is(err, ErrNotARepository) {
		t.Fatalf("got %v", err)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore -run 'Runner|ResolvePath|RepoConfigured|NotARepository' -count=1`
Expected: FAIL — `undefined: NewGitRunner`.

- [ ] **Step 3: Implement** — `internal/wakilcore/gitread.go`

```go
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
var gitReadSubcommands = map[string]bool{
	"status": true, "diff": true, "show": true, "rev-parse": true, "for-each-ref": true,
}

// gitSafetyArgs come before the subcommand on every call, so a repository's
// own config cannot make Wakil run a program.
var gitSafetyArgs = []string{
	"-c", "core.fsmonitor=false",
	"-c", "core.hooksPath=/dev/null",
	"-c", "core.pager=cat",
	"-c", "diff.external=",
	"--no-pager",
}

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
		return nil, UserError("wakil-git runs only status, diff, show, rev-parse and for-each-ref; refused: " + sub)
	}
	full := append([]string{"-C", g.Root}, gitSafetyArgs...)
	full = append(full, sub)
	if sub == "diff" || sub == "show" {
		full = append(full, "--no-ext-diff", "--no-textconv")
	}
	full = append(full, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	cmd.Env = gitScrubbedEnv()
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if strings.Contains(msg, "not a git repository") {
			return nil, ErrNotARepository
		}
		if msg == "" {
			msg = err.Error()
		}
		return nil, UserError("git " + sub + ": " + msg)
	}
	return out.Bytes(), nil
}

// gitScrubbedEnv keeps only what git needs to find itself and the user's
// identity files; every GIT_* the parent had is dropped.
func gitScrubbedEnv() []string {
	env := []string{"GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0", "LC_ALL=C"}
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./internal/wakilcore -run 'Runner|ResolvePath|RepoConfigured|NotARepository' -count=1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/gitread.go internal/wakilcore/gitread_test.go
git commit -m "3a-i: a read-only git runner — allowlisted, scrubbed, confined to the project's roots"
```

---

### Task 3: `GitStatus` — the porcelain v2 parser

**Files:**
- Create: `internal/wakilcore/gitstatus.go`
- Test: `internal/wakilcore/gitstatus_test.go`

**Interfaces:**
- Consumes: `GitRunner.Run` (Task 2), `gitTestRepo` (Task 2).
- Produces:

```go
type GitFile struct {
	Path     string `json:"path"`
	OrigPath string `json:"origPath,omitempty"` // a rename's old path
	Group    string `json:"group"`              // "staged" | "changed" | "untracked"
	Status   string `json:"status"`             // one letter: M A D R C T U ?
}
type GitStatus struct {
	Root     string    `json:"root"`
	Branch   string    `json:"branch"`   // "" when detached
	Detached string    `json:"detached"` // short SHA when detached
	Upstream string    `json:"upstream"`
	Ahead    int       `json:"ahead"`
	Behind   int       `json:"behind"`
	Files    []GitFile `json:"files"`
}
func ParseGitStatus(root string, porcelain []byte) GitStatus
func ReadGitStatus(ctx context.Context, g *GitRunner) (GitStatus, error)
```

- [ ] **Step 1: Write the failing tests**

```go
package wakilcore

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func TestStatusPartlyStagedFileIsInBothGroups(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\n"), 0o644)
	gitIn(t, repo, "add", "a.txt")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\nthree\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	st, err := ReadGitStatus(context.Background(), g)
	if err != nil {
		t.Fatal(err)
	}
	want := []GitFile{{Path: "a.txt", Group: "staged", Status: "M"}, {Path: "a.txt", Group: "changed", Status: "M"}}
	if len(st.Files) != 2 || st.Files[0] != want[0] || st.Files[1] != want[1] {
		t.Fatalf("files = %+v", st.Files)
	}
	if st.Branch != "main" {
		t.Errorf("branch = %q", st.Branch)
	}
}

func TestStatusUntrackedRenameSpacesAndUnicode(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "new file é.txt"), []byte("x\n"), 0o644)
	gitIn(t, repo, "mv", "a.txt", "b c.txt")
	g, _ := NewGitRunner(repo, []string{repo})
	st, _ := ReadGitStatus(context.Background(), g)
	var sawRename, sawUntracked bool
	for _, f := range st.Files {
		if f.Group == "staged" && f.Status == "R" && f.Path == "b c.txt" && f.OrigPath == "a.txt" {
			sawRename = true
		}
		if f.Group == "untracked" && f.Path == "new file é.txt" {
			sawUntracked = true
		}
	}
	if !sawRename || !sawUntracked {
		t.Fatalf("files = %+v", st.Files)
	}
}

func TestStatusDetachedHead(t *testing.T) {
	repo := gitTestRepo(t)
	gitIn(t, repo, "checkout", "-q", "--detach")
	g, _ := NewGitRunner(repo, []string{repo})
	st, _ := ReadGitStatus(context.Background(), g)
	if st.Branch != "" || len(st.Detached) < 7 {
		t.Fatalf("branch=%q detached=%q", st.Branch, st.Detached)
	}
}

func TestParseAheadBehind(t *testing.T) {
	in := "# branch.oid abc\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -1\x00"
	st := ParseGitStatus("/r", []byte(in))
	if st.Upstream != "origin/main" || st.Ahead != 2 || st.Behind != 1 {
		t.Fatalf("%+v", st)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore -run 'Status|AheadBehind' -count=1`
Expected: FAIL — `undefined: ReadGitStatus`.

- [ ] **Step 3: Implement** — `internal/wakilcore/gitstatus.go`

```go
package wakilcore

import (
	"context"
	"strconv"
	"strings"
)

// (GitFile and GitStatus exactly as in the Interfaces block above.)

// ParseGitStatus reads `git status --porcelain=v2 -z --branch`. Entries are
// NUL-separated; a rename (`2`) carries its original path as the NEXT entry.
func ParseGitStatus(root string, porcelain []byte) GitStatus {
	st := GitStatus{Root: root, Files: []GitFile{}}
	entries := strings.Split(string(porcelain), "\x00")
	var oid string
	for i := 0; i < len(entries); i++ {
		e := entries[i]
		switch {
		case strings.HasPrefix(e, "# branch.oid "):
			oid = strings.TrimPrefix(e, "# branch.oid ")
		case strings.HasPrefix(e, "# branch.head "):
			if h := strings.TrimPrefix(e, "# branch.head "); h != "(detached)" {
				st.Branch = h
			} else if len(oid) >= 7 {
				st.Detached = oid[:7]
			}
		case strings.HasPrefix(e, "# branch.upstream "):
			st.Upstream = strings.TrimPrefix(e, "# branch.upstream ")
		case strings.HasPrefix(e, "# branch.ab "):
			f := strings.Fields(strings.TrimPrefix(e, "# branch.ab "))
			if len(f) == 2 {
				st.Ahead, _ = strconv.Atoi(strings.TrimPrefix(f[0], "+"))
				st.Behind, _ = strconv.Atoi(strings.TrimPrefix(f[1], "-"))
			}
		case strings.HasPrefix(e, "1 "), strings.HasPrefix(e, "u "):
			// 1 XY sub mH mI mW hH hI path   (8 fields before path)
			// u XY sub m1 m2 m3 mW h1 h2 h3 path (10 fields before path)
			n := 8
			if e[0] == 'u' {
				n = 10
			}
			parts := strings.SplitN(e, " ", n+1)
			if len(parts) == n+1 {
				st.Files = append(st.Files, filesFor(parts[1], parts[n], "")...)
			}
		case strings.HasPrefix(e, "2 "):
			// 2 XY sub mH mI mW hH hI Xscore path, then origPath as next entry
			parts := strings.SplitN(e, " ", 10)
			if len(parts) == 10 && i+1 < len(entries) {
				st.Files = append(st.Files, filesFor(parts[1], parts[9], entries[i+1])...)
				i++
			}
		case strings.HasPrefix(e, "? "):
			st.Files = append(st.Files, GitFile{Path: e[2:], Group: "untracked", Status: "?"})
		}
	}
	return st
}

// filesFor turns one XY pair into its rows: X is the index side (staged),
// Y the work-tree side (changed). A file with both is two rows.
func filesFor(xy, path, orig string) []GitFile {
	var out []GitFile
	if x := xy[0]; x != '.' {
		f := GitFile{Path: path, Group: "staged", Status: string(x)}
		if x == 'R' || x == 'C' {
			f.OrigPath = orig
		}
		out = append(out, f)
	}
	if y := xy[1]; y != '.' {
		out = append(out, GitFile{Path: path, Group: "changed", Status: string(y)})
	}
	return out
}

func ReadGitStatus(ctx context.Context, g *GitRunner) (GitStatus, error) {
	out, err := g.Run(ctx, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
	if err != nil {
		return GitStatus{Root: g.Root, Files: []GitFile{}}, err
	}
	return ParseGitStatus(g.Root, out), nil
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./internal/wakilcore -run 'Status|AheadBehind' -count=1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/gitstatus.go internal/wakilcore/gitstatus_test.go
git commit -m "3a-i: git status, parsed — a partly staged file is two rows"
```

---

### Task 4: `GitDiff` and `GitShow`, capped

**Files:**
- Create: `internal/wakilcore/gitdiff.go`
- Test: `internal/wakilcore/gitdiff_test.go`

**Interfaces:**
- Consumes: `GitRunner` (Task 2).
- Produces:

```go
const GitDiffLineCap = 5000
const GitFileByteCap = 2 << 20 // 2,097,152

type GitDiffResult struct {
	Text      string `json:"text"`
	Binary    bool   `json:"binary"`
	Lines     int    `json:"lines"`     // true total
	Truncated bool   `json:"truncated"`
}
type GitShowResult struct {
	Text      string `json:"text"`
	Binary    bool   `json:"binary"`
	Bytes     int    `json:"bytes"`     // true size
	Truncated bool   `json:"truncated"`
}
func GitDiff(ctx context.Context, g *GitRunner, path, side string) (GitDiffResult, error) // side: "staged" | "changed"
func GitShow(ctx context.Context, g *GitRunner, path, rev string) (GitShowResult, error)  // rev: "HEAD" | "index" | "worktree"
```

`worktree` is read straight from disk (after `ResolvePath`), because Monaco's modified side for a Changes row is the file as it is now.

- [ ] **Step 1: Write the failing tests**

```go
package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiffSidesDiffer(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\n"), 0o644)
	gitIn(t, repo, "add", "a.txt")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\nthree\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	staged, _ := GitDiff(context.Background(), g, "a.txt", "staged")
	changed, _ := GitDiff(context.Background(), g, "a.txt", "changed")
	if !strings.Contains(staged.Text, "+two") || strings.Contains(staged.Text, "+three") {
		t.Errorf("staged = %q", staged.Text)
	}
	if !strings.Contains(changed.Text, "+three") || strings.Contains(changed.Text, "+two") {
		t.Errorf("changed = %q", changed.Text)
	}
}

func TestShowEachSide(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("staged\n"), 0o644)
	gitIn(t, repo, "add", "a.txt")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("disk\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	for rev, want := range map[string]string{"HEAD": "one\n", "index": "staged\n", "worktree": "disk\n"} {
		r, err := GitShow(context.Background(), g, "a.txt", rev)
		if err != nil || r.Text != want {
			t.Errorf("%s: %q, %v", rev, r.Text, err)
		}
	}
}

func TestDiffOverTheLineCapAdmitsIt(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte(strings.Repeat("x\n", 6000)), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	r, _ := GitDiff(context.Background(), g, "a.txt", "changed")
	if !r.Truncated || r.Lines <= GitDiffLineCap || strings.Count(r.Text, "\n") > GitDiffLineCap {
		t.Fatalf("truncated=%v lines=%d shown=%d", r.Truncated, r.Lines, strings.Count(r.Text, "\n"))
	}
}

func TestBinaryFile(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "b.bin"), []byte{0, 1, 2, 0, 255}, 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	r, _ := GitShow(context.Background(), g, "b.bin", "worktree")
	if !r.Binary || r.Text != "" || r.Bytes != 5 {
		t.Fatalf("%+v", r)
	}
}

func TestShowRefusesAnEscapingPath(t *testing.T) {
	repo := gitTestRepo(t)
	g, _ := NewGitRunner(repo, []string{repo})
	if _, err := GitShow(context.Background(), g, "../../etc/passwd", "worktree"); err == nil {
		t.Fatal("want refusal")
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore -run 'Diff|Show|Binary' -count=1`
Expected: FAIL — `undefined: GitDiff`.

- [ ] **Step 3: Implement** — `internal/wakilcore/gitdiff.go`

```go
package wakilcore

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
)

// (constants and result types exactly as in the Interfaces block above.)

func GitDiff(ctx context.Context, g *GitRunner, path, side string) (GitDiffResult, error) {
	rel, err := g.ResolvePath(path)
	if err != nil {
		return GitDiffResult{}, err
	}
	args := []string{"--no-color", "--"}
	switch side {
	case "staged":
		args = append([]string{"--cached"}, args...)
	case "changed":
	default:
		return GitDiffResult{}, UserError("side must be staged or changed, got " + side)
	}
	out, err := g.Run(ctx, "diff", append(args, rel)...)
	if err != nil {
		return GitDiffResult{}, err
	}
	if bytes.Contains(out, []byte("\nBinary files ")) || bytes.HasPrefix(out, []byte("Binary files ")) {
		return GitDiffResult{Binary: true}, nil
	}
	lines := strings.SplitAfter(string(out), "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	r := GitDiffResult{Lines: len(lines)}
	if len(lines) > GitDiffLineCap {
		lines, r.Truncated = lines[:GitDiffLineCap], true
	}
	r.Text = strings.Join(lines, "")
	return r, nil
}

func GitShow(ctx context.Context, g *GitRunner, path, rev string) (GitShowResult, error) {
	rel, err := g.ResolvePath(path)
	if err != nil {
		return GitShowResult{}, err
	}
	var data []byte
	switch rev {
	case "HEAD":
		data, err = g.Run(ctx, "show", "HEAD:"+filepath.ToSlash(rel))
	case "index":
		data, err = g.Run(ctx, "show", ":"+filepath.ToSlash(rel))
	case "worktree":
		data, err = os.ReadFile(filepath.Join(g.Root, rel))
		if os.IsNotExist(err) {
			data, err = nil, nil // a deletion: the modified side is empty
		}
	default:
		return GitShowResult{}, UserError("rev must be HEAD, index or worktree, got " + rev)
	}
	if err != nil {
		// A file absent at HEAD (added) or in the index (untracked) has an empty original side.
		if rev != "worktree" && strings.Contains(err.Error(), "exists on disk, but not in") ||
			strings.Contains(err.Error(), "does not exist in") {
			return GitShowResult{}, nil
		}
		return GitShowResult{}, err
	}
	r := GitShowResult{Bytes: len(data)}
	if bytes.IndexByte(data[:min(len(data), 8000)], 0) >= 0 {
		r.Binary = true
		return r, nil
	}
	if len(data) > GitFileByteCap {
		data, r.Truncated = data[:GitFileByteCap], true
	}
	r.Text = string(data)
	return r, nil
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./internal/wakilcore -run 'Diff|Show|Binary' -count=1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/gitdiff.go internal/wakilcore/gitdiff_test.go
git commit -m "3a-i: git diff and show, capped and admitting it"
```

---

### Task 5: `cmd/wakil-git` — the MCP server, built and bundled

**Files:**
- Create: `cmd/wakil-git/main.go`, `cmd/wakil-git/main_test.go`
- Modify: `Makefile:53` (`BINS`), `scripts/make-app-bundle.sh:63` (the copy loop), `internal/mcpx/shippedbinary_test.go` if it enumerates binaries

**Interfaces:**
- Consumes: Tasks 2–4; `wakilcore.Resolve`, `wakilcore.ProjectRootPaths`, `mcpx.ToolErr`.
- Produces: tools `git_status {root}`, `git_diff {root, path, side}`, `git_show {root, path, rev}`; structured content is the Go result struct as JSON.

- [ ] **Step 1: Write the failing test** — `cmd/wakil-git/main_test.go`. Reuse `setupProject`'s shape from `cmd/wakil-db/main_test.go:24` (copy it here; packages are separate) with `roots:[{"path":"."}]`, then `git init` the project dir, then:

```go
func TestStatusRefusesARootOutsideTheProject(t *testing.T) {
	setupProject(t, `"local":{}`, "local")
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_status", Arguments: map[string]any{"root": t.TempDir()}})
	if err != nil || !res.IsError {
		t.Fatalf("want a tool error, got %+v %v", res, err)
	}
}

func TestStatusAnswersForTheProjectRoot(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local") // returns the project dir
	gitInit(t, root)
	os.WriteFile(filepath.Join(root, "new.txt"), []byte("x\n"), 0o644)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_status", Arguments: map[string]any{"root": root}})
	if err != nil || res.IsError {
		t.Fatalf("%+v %v", res, err)
	}
	b, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(b), `"path":"new.txt"`) || !strings.Contains(string(b), `"group":"untracked"`) {
		t.Fatalf("%s", b)
	}
}

func TestToolListIsExactlyTheThreeReads(t *testing.T) {
	cs := connectedClient(t)
	tools, _ := cs.ListTools(context.Background(), nil)
	var names []string
	for _, tl := range tools.Tools {
		names = append(names, tl.Name)
	}
	slices.Sort(names)
	if !slices.Equal(names, []string{"git_diff", "git_show", "git_status"}) {
		t.Fatalf("%v", names)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./cmd/wakil-git -count=1`
Expected: FAIL — no `newServer`.

- [ ] **Step 3: Implement** — `cmd/wakil-git/main.go`

```go
package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type statusArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
}
type diffArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path" jsonschema:"file path relative to the root"`
	Side string `json:"side" jsonschema:"staged (index vs HEAD) or changed (work tree vs index)"`
}
type showArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path" jsonschema:"file path relative to the root"`
	Rev  string `json:"rev" jsonschema:"HEAD, index or worktree"`
}

// runner confines every call to a root the active project declares.
func runner(root string) (*wakilcore.GitRunner, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	g, err := wakilcore.NewGitRunner(root, wakilcore.ProjectRootPaths(*r))
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	return g, nil
}

func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-git", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "git_status", Description: "Read-only. One root's branch, ahead/behind against its local tracking ref (never fetched), and its files in three groups: staged (index vs HEAD), changed (work tree vs index), untracked. A partly staged file appears in both staged and changed."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a statusArg) (*mcp.CallToolResult, wakilcore.GitStatus, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, wakilcore.GitStatus{}, nil
			}
			st, err := wakilcore.ReadGitStatus(ctx, g)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitStatus{}, nil
			}
			return nil, st, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_diff", Description: "Read-only. The unified diff of one file on one side: staged or changed. Capped at 5,000 lines; truncated says so and lines is the true total."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a diffArg) (*mcp.CallToolResult, wakilcore.GitDiffResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, wakilcore.GitDiffResult{}, nil
			}
			r, err := wakilcore.GitDiff(ctx, g, a.Path, a.Side)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitDiffResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_show", Description: "Read-only. One file's text at HEAD, in the index, or in the work tree. Capped at 2 MB; binary files return no text."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a showArg) (*mcp.CallToolResult, wakilcore.GitShowResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, wakilcore.GitShowResult{}, nil
			}
			r, err := wakilcore.GitShow(ctx, g, a.Path, a.Rev)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitShowResult{}, nil
			}
			return nil, r, nil
		})
	return s
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **Step 4: Build and bundle it** — `Makefile:53` becomes `BINS := wakil wakil-ctx wakil-db wakil-git wakil-http wakil-pm wakil-recall`; the loop in `scripts/make-app-bundle.sh:63` gains `wakil-git`. If `internal/mcpx/shippedbinary_test.go` lists binaries, add it there.

- [ ] **Step 5: Run**

Run: `go test ./cmd/wakil-git ./internal/... -count=1 && make build`
Expected: PASS, and `built: wakil wakil-ctx wakil-db wakil-git …`.

- [ ] **Step 6: Commit**

```bash
git add cmd/wakil-git Makefile scripts/make-app-bundle.sh internal/mcpx
git commit -m "3a-i: wakil-git — three read tools, confined to the active project's roots"
```

---

### Task 6: The `git` pane kind and its snapshot

**Files:**
- Create: `app/Sources/WakilKit/Git/GitSnapshot.swift`
- Modify: `app/Sources/WakilKit/Layout/Pane.swift:166` (`kinds`), `:201-258` (`Contents` + both switches), `:262-267` (`contentsByKind`)
- Modify: `app/Sources/WakilKit/Panes/PaneSnapshot.swift:57` (`case git(GitSnapshot)`)
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift:343` (private `Contents` gains `case git(GitSnapshot)`), the `snapshot(paneId:kind:)` switch (~`:1556`), plus `gitSnapshot(paneId:)` and `setGit(paneId:_:)`
- Modify: `app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift:74` (a `.git` arm)
- Test: `app/Tests/WakilKitTests/GitPaneSnapshotTests.swift`

**Interfaces:**
- Produces:

```swift
public enum GitGroup: String, Sendable, Codable, CaseIterable { case staged, changed, untracked }

public struct GitFileRow: Sendable, Equatable, Hashable {
    public var path: String
    public var origPath: String?
    public var group: GitGroup
    public var status: String
}

public struct GitRootState: Sendable, Equatable {
    public var root: String           // absolute
    public var name: String           // last path component
    public var branch: String         // "" when detached
    public var detached: String       // short SHA or ""
    public var ahead: Int
    public var behind: Int
    public var files: [GitFileRow]    // already in group, then path order
    public var error: String?         // whole text; "not a git repository" for a non-repo
    public var loading: Bool
}

public struct GitSelection: Sendable, Equatable, Hashable {
    public var root: String
    public var path: String
    public var group: GitGroup
}

public struct GitDiffState: Sendable, Equatable {
    public var original: String
    public var modified: String
    public var language: String
    public var binary: Bool
    public var bytes: Int
    public var lines: Int
    public var truncated: Bool
    public var error: String?
    public var loading: Bool
}

public struct GitSnapshot: Sendable, Equatable {
    public var roots: [GitRootState]
    public var selection: GitSelection?
    public var folded: Bool
    public var diff: GitDiffState?
    public static let empty = GitSnapshot(roots: [], selection: nil, folded: false, diff: nil)
}
```

- [ ] **Step 1: Write the failing tests** — `GitPaneSnapshotTests.swift`

```swift
import Testing
@testable import WakilKit

@Test func gitIsARegisteredAndClassifiedKind() {
    #expect(Pane.kinds.contains("git"))
    #expect(Pane.contentsByKind["git"] == .git)
    #expect(Pane.Contents.git.rerunsSubjectOnRestore == true)
}

@Test func anUnwrittenGitPaneAnswersEmptyNotAsAGrid() async {
    let store = PaneStore()
    let snap = await store.snapshot(paneId: "g1", kind: "git")
    #expect(snap.contents == .git(.empty))
}

@Test func oneBrokenRootDoesNotHideTheOther() async {
    let store = PaneStore()
    var s = GitSnapshot.empty
    s.roots = [
        GitRootState(root: "/tmp/a", name: "a", branch: "main", detached: "", ahead: 0, behind: 0,
                     files: [GitFileRow(path: "x.php", origPath: nil, group: .changed, status: "M")],
                     error: nil, loading: false),
        GitRootState(root: "/tmp/b", name: "b", branch: "", detached: "", ahead: 0, behind: 0,
                     files: [], error: "git status: fatal: index file corrupt", loading: false),
    ]
    await store.setGit(paneId: "g1", s)
    let json = paneSnapshotJSON(await store.snapshot(paneId: "g1", kind: "git"))
    let roots = json["roots"]?.arrayValue ?? []
    #expect(roots.count == 2)
    #expect(roots[0]["files"]?.arrayValue?.count == 1)
    #expect(roots[1]["error"]?.stringValue == "git status: fatal: index file corrupt")
}
```

(If `JSONValue` has no `arrayValue` / `stringValue` / subscript helpers, use the accessors `ApiWireContractTests.swift` uses for the same job.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter GitPaneSnapshotTests`
Expected: FAIL — `GitSnapshot` undefined.

- [ ] **Step 3: Implement**
  - Create `GitSnapshot.swift` with the types above.
  - `Pane.swift`: `kinds` gains `"git"`; `Contents` gains `case git` with a doc line *"The project's roots and what changed in each. `"git"` today (3a-i)."*; `rerunsSubjectOnRestore` → `case .git: return true` with the comment *"its subject is a read — `git status` per root — and re-running it is how a reopened pane is current"*; `emptySnapshot` → `case .git: return .git(.empty)`; `contentsByKind` gains `"git": .git`.
  - `PaneSnapshot.swift`: `case git(GitSnapshot)`.
  - `PaneStore.swift`: private `Contents` gains `case git(GitSnapshot)`; `snapshot` gains `case .git(let s): return PaneSnapshot(kind: kind, failure: nil, contents: .git(s))`; add, mirroring `api(_:)`/`setApi(_:_:)` at `:422-431`:

```swift
    public func gitSnapshot(paneId: String) -> GitSnapshot {
        guard case .git(let s)? = panes[paneId] else { return .empty }
        return s
    }

    public func setGit(paneId: String, _ snapshot: GitSnapshot) {
        switch panes[paneId] {
        case .dataSurface?, .terminal?, .api?: return
        case .git?, nil: panes[paneId] = .git(snapshot)
        }
    }
```

  Every other `switch` over the private `Contents` that the compiler now flags gets a `.git` arm that does what its `.api` arm does for "not my kind" (usually `return` / `continue`).
  - `PaneSnapshotJSON.swift`: a `.git` arm emitting `roots` (each: `root`, `name`, `branch`, `detached`, `ahead`, `behind`, `error` or null, `loading`, `files` [each `path`, `origPath` or null, `group`, `status`]), `selection` (`root`, `path`, `group`) or null, `folded`, and `diff` (`binary`, `bytes`, `lines`, `truncated`, `error`, `loading`, `language` — **not** the texts, which are large and readable through `git_show`) or null. Every key always present, per the file's own rule.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && swift test --filter 'GitPaneSnapshotTests|PaneKindClassificationTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Git/GitSnapshot.swift app/Sources/WakilKit/Layout/Pane.swift app/Sources/WakilKit/Panes app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift app/Tests/WakilKitTests/GitPaneSnapshotTests.swift
git commit -m "3a-i: the git pane kind, classified, with a readable snapshot"
```

---

### Task 7: Navigation — step order and where the selection lands after a refresh

**Files:**
- Create: `app/Sources/WakilKit/Git/GitNavigation.swift`
- Test: `app/Tests/WakilKitTests/GitNavigationTests.swift`

**Interfaces:**
- Consumes: Task 6 types.
- Produces:

```swift
/// Every row in step order: roots in project order, then staged, changed, untracked, then path.
public func gitRows(_ roots: [GitRootState]) -> [GitSelection]
/// The row `delta` away from `current`, clamped at both ends. nil when there are no rows.
public func gitStep(_ roots: [GitRootState], from current: GitSelection?, by delta: Int) -> GitSelection?
/// Rule 6. Where the selection goes when `before` is replaced by `after`.
public enum GitReselect: Equatable { case keep(GitSelection), moved(GitSelection), unfold(root: String) }
public func gitReselect(_ selection: GitSelection, before: [GitRootState], after: [GitRootState]) -> GitReselect
```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

private func root(_ name: String, _ files: [(String, GitGroup)]) -> GitRootState {
    GitRootState(root: "/p/\(name)", name: name, branch: "main", detached: "", ahead: 0, behind: 0,
                 files: files.map { GitFileRow(path: $0.0, origPath: nil, group: $0.1, status: "M") },
                 error: nil, loading: false)
}
private func sel(_ r: String, _ p: String, _ g: GitGroup) -> GitSelection { GitSelection(root: "/p/\(r)", path: p, group: g) }

@Test func stepOrderCrossesGroupsThenRootsAndVisitsAPartlyStagedFileTwice() {
    let roots = [root("api", [("b.php", .changed), ("a.php", .staged), ("a.php", .changed), ("z", .untracked)]),
                 root("portal", [("v.vue", .changed)])]
    #expect(gitRows(roots) == [sel("api", "a.php", .staged), sel("api", "a.php", .changed),
                               sel("api", "b.php", .changed), sel("api", "z", .untracked),
                               sel("portal", "v.vue", .changed)])
}

@Test func stepClampsAtBothEnds() {
    let roots = [root("api", [("a", .changed), ("b", .changed)])]
    #expect(gitStep(roots, from: sel("api", "b", .changed), by: 1) == sel("api", "b", .changed))
    #expect(gitStep(roots, from: sel("api", "a", .changed), by: -1) == sel("api", "a", .changed))
    #expect(gitStep(roots, from: nil, by: 1) == sel("api", "a", .changed))
    #expect(gitStep([], from: nil, by: 1) == nil)
}

@Test func aSelectedFileThatStillExistsIsKept() {
    let before = [root("api", [("a", .changed), ("b", .changed)])]
    #expect(gitReselect(sel("api", "a", .changed), before: before, after: before) == .keep(sel("api", "a", .changed)))
}

@Test func aSelectedFileThatVanishedMovesToTheRowNowInItsPlace() {
    let before = [root("api", [("a", .changed), ("b", .changed), ("c", .changed)])]
    let after = [root("api", [("a", .changed), ("c", .changed)])]
    #expect(gitReselect(sel("api", "b", .changed), before: before, after: after) == .moved(sel("api", "c", .changed)))
}

@Test func theLastRowVanishingMovesToTheNewLastRowInTheSameRoot() {
    let before = [root("api", [("a", .changed), ("b", .changed)]), root("portal", [("v", .changed)])]
    let after = [root("api", [("a", .changed)]), root("portal", [("v", .changed)])]
    #expect(gitReselect(sel("api", "b", .changed), before: before, after: after) == .moved(sel("api", "a", .changed)))
}

@Test func aRootWithNothingLeftUnfoldsAtThatRoot() {
    let before = [root("api", [("a", .changed)])]
    let after = [root("api", [])]
    #expect(gitReselect(sel("api", "a", .changed), before: before, after: after) == .unfold(root: "/p/api"))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter GitNavigationTests`
Expected: FAIL — `gitRows` undefined.

- [ ] **Step 3: Implement** — `GitNavigation.swift`

```swift
import Foundation

private let groupOrder: [GitGroup: Int] = [.staged: 0, .changed: 1, .untracked: 2]

public func gitRows(_ roots: [GitRootState]) -> [GitSelection] {
    roots.flatMap { r in
        r.files
            .sorted { a, b in
                let ga = groupOrder[a.group]!, gb = groupOrder[b.group]!
                if ga != gb { return ga < gb }
                return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)   // byte order
            }
            .map { GitSelection(root: r.root, path: $0.path, group: $0.group) }
    }
}

public func gitStep(_ roots: [GitRootState], from current: GitSelection?, by delta: Int) -> GitSelection? {
    let rows = gitRows(roots)
    guard !rows.isEmpty else { return nil }
    guard let current, let i = rows.firstIndex(of: current) else { return rows.first }
    return rows[min(max(i + delta, 0), rows.count - 1)]
}

public enum GitReselect: Equatable { case keep(GitSelection), moved(GitSelection), unfold(root: String) }

public func gitReselect(_ selection: GitSelection, before: [GitRootState], after: [GitRootState]) -> GitReselect {
    let afterRows = gitRows(after)
    if afterRows.contains(selection) { return .keep(selection) }
    let sameRootAfter = afterRows.filter { $0.root == selection.root }
    guard !sameRootAfter.isEmpty else { return .unfold(root: selection.root) }
    // The index the selection held among its root's rows before; the row now at that index, or the last.
    let sameRootBefore = gitRows(before).filter { $0.root == selection.root }
    let i = sameRootBefore.firstIndex(of: selection) ?? 0
    return .moved(sameRootAfter[min(i, sameRootAfter.count - 1)])
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && swift test --filter GitNavigationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Git/GitNavigation.swift app/Tests/WakilKitTests/GitNavigationTests.swift
git commit -m "3a-i: step order across roots and groups; the selection stays where the operator was"
```

---

### Task 8: The actions — `git_refresh`, `git_select`, `git_step`, `git_fold`, `git_unfold`

**Files:**
- Create: `app/Sources/WakilKit/Git/GitActions.swift`
- Test: `app/Tests/WakilKitTests/GitActionsTests.swift`

**Interfaces:**
- Consumes: Tasks 6–7; `ActionRegistry`, `Action`, `ToolCaller`, `LayoutStore`, `optionalString` and `requireOpenPane` (used by `ApiActions.swift:467-500`); `callChecked` from `StandardActions` for tool errors.
- Produces:

```swift
public func registerGitActions(
    into registry: ActionRegistry,
    panes: PaneStore,
    layout: LayoutStore?,
    git: (any ToolCaller)?,
    roots: @escaping @Sendable () async -> [String]
) async
```

Actions (all `kind: .read` except fold/unfold/step/select which are `.control`; all `audience: .agentReachable`; each takes `pane`):
- `git_refresh {pane, root?}` — re-reads `git_status` for one root (or all), applies `gitReselect`, re-fetches the diff when the selection is kept or moved.
- `git_select {pane, root, path, group}` — sets the selection, `folded = true`, fetches the diff (cancelling any diff in flight for this pane).
- `git_step {pane, delta}` — `gitStep`, then as `git_select`.
- `git_fold {pane}` / `git_unfold {pane}` — set `folded`; unfold keeps the selection.

Diff fetch: for `group == .staged` original = `git_show(rev: HEAD)`, modified = `git_show(rev: index)`; for `.changed` original = `index`, modified = `worktree`; for `.untracked` original = `""`, modified = `worktree`. Language from extension (`php`, `swift`, `ts`, `tsx`→`typescript`, `js`, `vue`→`html`, `go`, `py`→`python`, `json`, `md`→`markdown`, `sql`, `yml`/`yaml`→`yaml`; else `plaintext`).

- [ ] **Step 1: Write the failing tests** — `GitActionsTests.swift`, with a fake:

```swift
import Foundation
import Testing
@testable import WakilKit

/// A wakil-git that answers from a dictionary and counts calls. `slowShow` parks git_show until released.
actor FakeGit: ToolCaller {
    var status: [String: JSONValue] = [:]       // root -> structuredContent
    var shows: [String: String] = [:]           // "root|path|rev" -> text
    var calls: [String] = []
    var parked: [CheckedContinuation<Void, Never>] = []
    var slowShow = false
    func set(status root: String, files: [(String, String, String)], branch: String = "main") {
        status[root] = .object([
            "root": .string(root), "branch": .string(branch), "detached": .string(""),
            "upstream": .string(""), "ahead": .integer(0), "behind": .integer(0),
            "files": .array(files.map { .object(["path": .string($0.0), "group": .string($0.1), "status": .string($0.2)]) }),
        ])
    }
    func release() { parked.forEach { $0.resume() }; parked = [] }
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let root = arguments["root"]?.stringValue ?? ""
        calls.append("\(name) \(root) \(arguments["path"]?.stringValue ?? "")")
        switch name {
        case "git_status":
            if let s = status[root] { return .object(["structuredContent": s]) }
            return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("not a git repository")])])])
        case "git_show":
            if slowShow { await withCheckedContinuation { parked.append($0) } }
            try Task.checkCancellation()
            let key = "\(root)|\(arguments["path"]?.stringValue ?? "")|\(arguments["rev"]?.stringValue ?? "")"
            return .object(["structuredContent": .object(["text": .string(shows[key] ?? ""), "binary": .bool(false),
                                                          "bytes": .integer(0), "truncated": .bool(false)])])
        default: return .object([:])
        }
    }
}
```

Tests (each builds `ActionRegistry()`, `PaneStore()`, a `LayoutStore` with one open `git` pane `g1` the way `ApiPaneTests.swift` builds an api pane, calls `registerGitActions(... roots: { ["/p/api", "/p/portal"] })`, then dispatches):

1. `refreshListsEveryRootAndShowsANonRepoAsItsError` — `/p/portal` has no status → its `error == "not a git repository"`, `/p/api` lists its files.
2. `selectFoldsAndLoadsBothSidesForAChangedFile` — after `git_select {root:/p/api, path:a.php, group:changed}`: `folded == true`, `diff.original == shows["/p/api|a.php|index"]`, `diff.modified == shows["/p/api|a.php|worktree"]`.
3. `selectingAnotherFileCancelsTheDiffInFlight` — `slowShow = true`; dispatch select a, then select b without awaiting the first; release; final `diff` is b's and a's result never lands (assert `selection.path == "b"` and `diff.modified == b's text`).
4. `stepMovesAcrossRoots` — select last row of `api`, `git_step {delta: 1}` → selection is the first row of `portal`.
5. `unfoldKeepsTheSelection` — select, `git_unfold` → `folded == false`, selection unchanged.
6. `refreshAfterACommitMovesTheSelection` — select `b`, change fake status to drop `b`, `git_refresh` → selection is the row now in `b`'s place.
7. `everyGitActionIsAgentReachableAndNoneMutates` — over `registry.all()` filtered by `git_` prefix: `audience == .agentReachable`, `kind != .mutate`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter GitActionsTests`
Expected: FAIL — `registerGitActions` undefined.

- [ ] **Step 3: Implement** `GitActions.swift`. Structure:

```swift
import Foundation

/// One diff fetch per pane at a time; a new select cancels the old (Interaction Rule 4).
actor GitDiffFlights {
    private var tasks: [String: Task<Void, Never>] = [:]
    func replace(_ pane: String, with task: Task<Void, Never>) { tasks[pane]?.cancel(); tasks[pane] = task }
}

func gitLanguage(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "php": "php"; case "swift": "swift"; case "ts", "tsx": "typescript"; case "js", "jsx": "javascript"
    case "vue", "html": "html"; case "go": "go"; case "py": "python"; case "json": "json"
    case "md": "markdown"; case "sql": "sql"; case "yml", "yaml": "yaml"; case "css": "css"
    default: "plaintext"
    }
}

func gitRootState(root: String, result: Result<JSONValue, Error>) -> GitRootState { /* decode structuredContent
   into GitRootState; on a tool error (isError) or a thrown error, files = [] and error = the whole text */ }

public func registerGitActions(into registry: ActionRegistry, panes: PaneStore, layout: LayoutStore?,
                               git: (any ToolCaller)?, roots: @escaping @Sendable () async -> [String]) async {
    let flights = GitDiffFlights()
    // refresh(pane, only:) — read each root (in parallel with a TaskGroup, results re-ordered to project
    // order), apply gitReselect to any selection, write the snapshot, then load the diff if kept/moved.
    // load(pane, selection) — set diff.loading, start a Task that calls git_show for both sides,
    // `try Task.checkCancellation()` before writing, register it with `flights.replace`.
    // Register the five actions with the schemas listed in Interfaces; each handler calls
    // requireOpenPane(pane, action:, layout:) the way api_open does, and returns
    // paneSnapshotJSON(await panes.snapshot(paneId: pane, kind: "git")).
}
```

Write the full bodies; the test list above is the contract. A missing `git` client throws `StandardActionError.missingClient` like every other action does.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && swift test --filter GitActionsTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Git/GitActions.swift app/Tests/WakilKitTests/GitActionsTests.swift
git commit -m "3a-i: git pane actions — one path for the operator and the agent"
```

---

### Task 9: Wiring — `wakil-git` client, `rootPaths`, and the watcher

**Files:**
- Create: `app/Sources/WakilKit/Git/GitWatcher.swift`
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (`gitClient`, `wakilOwnedClients`, `startClient("wakil-git")`, `registerGitActions`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`rootPaths`, watcher lifecycle)
- Test: `app/Tests/WakilKitTests/GitWatcherTests.swift`, additions to `AppWiringTests.swift`

**Interfaces:**
- Consumes: Task 8's `registerGitActions`.
- Produces:

```swift
public protocol RootWatcher: Sendable {
    /// Calls `changed(root)` at most once per `window` per root, after events stop for `window`.
    func watch(roots: [String], window: Duration, changed: @escaping @Sendable (String) async -> Void) async
    func stop() async
}
public actor FSEventsRootWatcher: RootWatcher { … }
/// Pure: whether an FSEvents path should wake a refresh.
public func gitWatchWakes(_ path: String, root: String) -> Bool
```

`WindowModel` gains `public private(set) var rootPaths: [String]`; `rootPath` becomes a computed `rootPaths.first ?? NSHomeDirectory()`. At `WindowModel.swift:2395` set `rootPaths = active.rootPaths`; at `:2435` and `:2658` set `rootPaths = []`. The watcher starts when a `git` pane exists in the scope and the project is known, restarts on project switch (beside the existing org/project switch path), and stops when the last `git` pane closes; its `changed(root)` dispatches `git_refresh {pane, root}` for every open git pane.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

@Test func watchWakesOnSourceAndIndexButNotObjects() {
    #expect(gitWatchWakes("/p/api/app/Booking.php", root: "/p/api"))
    #expect(gitWatchWakes("/p/api/.git/index", root: "/p/api"))
    #expect(gitWatchWakes("/p/api/.git/HEAD", root: "/p/api"))
    #expect(gitWatchWakes("/p/api/.git/refs/heads/main", root: "/p/api"))
    #expect(!gitWatchWakes("/p/api/.git/objects/ab/cdef", root: "/p/api"))
    #expect(!gitWatchWakes("/p/api/.git/logs/HEAD", root: "/p/api"))
    #expect(!gitWatchWakes("/p/api/.git/index.lock", root: "/p/api"))
}

@Test(.timeLimit(.minutes(1))) func aBurstOfWritesIsOneRefresh() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let root = dir.resolvingSymlinksInPath().path
    let count = Counter()
    let w = FSEventsRootWatcher()
    await w.watch(roots: [root], window: .milliseconds(300)) { _ in await count.bump() }
    for i in 0..<20 { try "x\(i)".write(toFile: root + "/f\(i).txt", atomically: false, encoding: .utf8) }
    try await Task.sleep(for: .seconds(2))
    await w.stop()
    #expect(await count.value == 1)
}

actor Counter { var value = 0; func bump() { value += 1 } }
```

In `AppWiringTests.swift`:

```swift
@Test func wakilGitIsAWakilOwnedClientAndItsActionsAreRegistered() async throws {
    // Build the wiring the way wiringBuildsAVocabularyThatResolvesWakilsOwnActionNames does.
    // Assert wakilOwnedClients names "wakil-git", and registry.all() contains git_select, git_step,
    // git_fold, git_unfold, git_refresh.
}

@Test func windowModelKeepsTheFirstRootForEveryExistingConsumer() async {
    // WindowModel.forTesting with active rootPaths ["/p/api", "/p/portal"]:
    // rootPath == "/p/api", activeShellContext.rootPath == "/p/api", rootPaths == both.
}

@Test func theWatcherIsActuallyPassedIn() async {
    // WindowModel built through the production initializer path (not forTesting) has a non-nil
    // rootWatcher — the never-wired-injectable guard.
}
```

Write the three bodies against the existing helpers in `AppWiringTests.swift` and `WindowModel.forTesting` (`WindowModel.swift:2074`).

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter 'GitWatcherTests|AppWiringTests'`
Expected: FAIL.

- [ ] **Step 3: Implement**
  - `gitWatchWakes`: false if the path relative to `root` starts with `.git/objects/`, `.git/logs/`, or ends in `.lock`; true otherwise. (Ignored paths cost one extra `git status`, which is cheap and honest; `git check-ignore` per event is not worth its latency here — note this in the file.)
  - `FSEventsRootWatcher`: one `FSEventStreamCreate` per root with `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`, latency 0.05, on a private dispatch queue; each wake that passes `gitWatchWakes` resets that root's debounce `Task` (`Task.sleep(for: window)` then `changed(root)`).
  - `AppWiring`: `public let gitClient: MCPClient?`; `wakilOwnedClients` adds `("wakil-git", gitClient)`; `let gitClient = await startClient("wakil-git")` beside `httpClient`; `await registerGitActions(into: registry, panes: panes, layout: layout, git: gitClient, roots: { … active rootPaths … })`.
  - `WindowModel` changes as listed in Interfaces.

- [ ] **Step 4: Run to verify they pass**

Run: `make build && cd app && swift test --filter 'GitWatcherTests|AppWiringTests|WindowModel'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Git/GitWatcher.swift app/Sources/WakilKit/App app/Tests/WakilKitTests/GitWatcherTests.swift app/Tests/WakilKitTests/AppWiringTests.swift
git commit -m "3a-i: wakil-git wired in; every root known to the window; the pane stays live"
```

---

### Task 10: `DiffRenderer`, `GitPane`, the spine

**Files:**
- Create: `app/Sources/WakilKit/Git/DiffRenderer.swift`, `app/Sources/WakilApp/GitPane.swift`
- Modify: `app/Sources/WakilApp/MonacoDiffRenderer.swift` (conform), `app/Sources/WakilApp/Canvas.swift:286-425` (a `"git"` arm), the rail and ⌘P open lists wherever `"api"` is offered as an openable kind
- Test: `app/Tests/WakilKitTests/GitPaneLinesTests.swift`

**Interfaces:**
- Produces:

```swift
@MainActor public protocol DiffRenderer: AnyObject {
    func show(original: String, modified: String, language: String)
    func clear()
    var scrollTop: Double { get set }
}

/// Pure, testable text for the pane (WakilApp has no test target).
public func gitRootLine(_ r: GitRootState) -> String       // "api · main ↑2 ↓1", "api · a1b2c3d", "api · main · clean"
public func gitDiffBanner(_ d: GitDiffState) -> String?    // "binary · 2.1 MB", "diff is 48,000 lines · first 5,000 shown", nil
public func gitSpineMarks(_ roots: [GitRootState]) -> [[GitSelection]]   // one array per root, step order
```

- [ ] **Step 1: Write the failing tests** — `GitPaneLinesTests.swift`

```swift
import Testing
@testable import WakilKit

private func r(_ files: [GitFileRow] = [], branch: String = "main", detached: String = "",
               ahead: Int = 0, behind: Int = 0, error: String? = nil) -> GitRootState {
    GitRootState(root: "/p/api", name: "api", branch: branch, detached: detached, ahead: ahead,
                 behind: behind, files: files, error: error, loading: false)
}

@Test func rootLines() {
    #expect(gitRootLine(r()) == "api · main · clean")
    #expect(gitRootLine(r([GitFileRow(path: "a", origPath: nil, group: .changed, status: "M")], ahead: 2, behind: 1)) == "api · main ↑2 ↓1")
    #expect(gitRootLine(r([GitFileRow(path: "a", origPath: nil, group: .changed, status: "M")], branch: "", detached: "a1b2c3d")) == "api · a1b2c3d")
    #expect(gitRootLine(r(error: "not a git repository")) == "api · not a git repository")
}

@Test func banners() {
    var d = GitDiffState(original: "", modified: "", language: "plaintext", binary: true, bytes: 2_202_009,
                         lines: 0, truncated: false, error: nil, loading: false)
    #expect(gitDiffBanner(d) == "binary · 2.1 MB")
    d.binary = false; d.lines = 48_000; d.truncated = true
    #expect(gitDiffBanner(d) == "diff is 48,000 lines · first 5,000 shown")
    d.truncated = false
    #expect(gitDiffBanner(d) == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter GitPaneLinesTests`
Expected: FAIL.

- [ ] **Step 3: Implement**
  - `DiffRenderer.swift` and the three pure functions (size with `ByteCountFormatter` `.file` style, decimal; numbers with a `,` grouping `NumberFormatter`, `en_US_POSIX`).
  - `MonacoDiffRenderer: DiffRenderer` — `clear()` sets an empty model pair; `scrollTop` reads/writes through `editor.getModifiedEditor().getScrollTop()/setScrollTop()` via `evaluateJavaScript`; keep the Task 1 offline rule list.
  - `GitPane.swift`, SwiftUI:
    - **Unfolded:** a `ScrollView` of root headers (`gitRootLine`, error text whole beneath it in §8's data register) and group labels (`STAGED`, `CHANGES`, `UNTRACKED`, micro-label style as other panes use) with rows `status letter + path` (`old → new` for a rename); amber for M, green for A/?, muted for D, as in the mockup. Click or Return → `git_select`.
    - **Folded:** `HStack { spine(26 pt); diff }`. The spine draws one 16 pt mark per row from `gitSpineMarks`, a 1 pt separator between roots, the selected mark outlined in §5 violet `#7c5cff`; clicking a mark dispatches `git_select`. Above the diff: `root / path · n of N · ↑↓` and `gitDiffBanner` when non-nil. The diff is an `NSViewRepresentable` around one `MonacoDiffRenderer` owned by the pane (created on first fold, kept for the pane's life); when the snapshot's `diff` changes, call `show`; when only a refresh re-delivers the same selection, restore `scrollTop` afterwards (rule 6).
    - **Keys:** ↑/↓ → `git_step {delta: ∓1}` when folded (and move the highlight when unfolded); Esc → `git_unfold`, scrolling the list so the selected row is visible.
    - A `loading` root or diff draws a quiet mark — reuse the rail's existing busy treatment rather than a spinner (§9: no spinners).
  - `Canvas.swift`: `case "git": GitPane(snapshot: …, dispatch: …)`, following the `"api"` arm at `:354`.
  - Rail / ⌘P: offer `git` wherever `api` is offered as a kind to open, titled `Git`.

- [ ] **Step 4: Run**

Run: `cd app && swift test --filter GitPaneLinesTests && cd .. && make app-build`
Expected: PASS and a clean build.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Git/DiffRenderer.swift app/Sources/WakilApp app/Tests/WakilKitTests/GitPaneLinesTests.swift
git commit -m "3a-i: the git pane — the list, the spine, and a Monaco diff behind DiffRenderer"
```

---

### Task 11: Voice — `GitSource`

**Files:**
- Create: `app/Sources/WakilKit/Git/GitSource.swift`
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (append `GitSource` to the sources list beside `SchemaSource` at `:340`)
- Test: `app/Tests/WakilKitTests/GitSourceTests.swift`

**Interfaces:**
- Consumes: `IdentifierSource` (`IdentifierSources.swift:5`), `Identifier`, `LayoutStore`, `PaneStore.gitSnapshot`.
- Produces: `public struct GitSource: IdentifierSource` — `kind = .panes`, `name = "git"`; for every open `git` pane, one `Identifier(kind: .file, origin: "git · <root name>")` per visible row with `text` = the full path **and** one with `text` = the file's base name without extension (so *"booking controller"* folds onto `BookingController`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import WakilKit

@Test func gitPaneFilesAreIdentifiersByPathAndBaseName() async throws {
    let (layout, panes) = await openGitPane(id: "g1")   // helper: LayoutStore with one "git" pane, as in GitActionsTests
    var s = GitSnapshot.empty
    s.roots = [GitRootState(root: "/p/api", name: "api", branch: "main", detached: "", ahead: 0, behind: 0,
                            files: [GitFileRow(path: "app/Http/BookingController.php", origPath: nil, group: .changed, status: "M")],
                            error: nil, loading: false)]
    await panes.setGit(paneId: "g1", s)
    let names = try await GitSource(layout: layout, panes: panes).identifiers(for: .init(org: "o", project: "p", environment: "local"))
    #expect(names.contains { $0.text == "app/Http/BookingController.php" && $0.kind == .file })
    #expect(names.contains { $0.text == "BookingController" && $0.origin == "git · api" })
}
```

(`openGitPane` lives in `GitActionsTests.swift`'s support code from Task 8; move it to a `GitTestSupport.swift` if both files need it.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift test --filter GitSourceTests`
Expected: FAIL.

- [ ] **Step 3: Implement** — mirror `PaneSource` (`IdentifierSources.swift:59-97`): iterate `layout.snapshot().panes` where `kind == "git"`, read `panes.gitSnapshot(paneId:)`, emit the two identifiers per row, drop empties.

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && swift test --filter 'GitSourceTests|Identifier'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Git/GitSource.swift app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/GitSourceTests.swift
git commit -m "3a-i: files in the git pane are names voice can resolve"
```

---

### Task 12: Charter, full gates, and the walk runbook

**Files:**
- Modify: `docs/wakil/north-star.md` §8 (Phase 3 rows), `docs/wakil/design-language.md` §11 Git row and §15
- Create: `docs/wakil/phase-3a-i-acceptance.md`

- [ ] **Step 1: Charter edits**
  - north-star §8: after the `**Phase 3**` row, add three rows — `**3a-i**` *Git pane, read-only: changes by root, the spine, the Monaco diff host* / `—` / `—`; `**3a-ii**` *Stage, unstage, commit — the fourth write* / `—` / `3a-i`; `**3a-iii**` *A git account per organisation; push and pull* / `—` / `3a-ii`.
  - design-language §11 Git row: replace *"diff reuses the editor's Monaco diff renderer; click-to-open into the editor"* with *"the diff is drawn by the Monaco host 3a-i built, which the editor will reuse; a drilled-in diff folds the list into a spine of status marks. Click-to-open into the editor arrives with the editor."*
  - design-language §15: add *"Side-by-side diff in the Git pane (deferred by 3a-i; inline only)"*.

- [ ] **Step 2: The runbook** — `docs/wakil/phase-3a-i-acceptance.md`, in the shape of `docs/wakil/phase-2d-ii-acceptance.md`: a numbered walk (≤ 10 steps) covering the exit criterion — open a two-root project; both roots listed with Staged / Changes / Untracked; a partly staged file in both groups; drill in, spine, ↑↓ across the roots, Esc back to the same file; *"show me booking controller"* by voice; the agent selects and reads the pane; `echo x >> file` in a terminal pane appears without a refresh; a non-repo root shows `not a git repository` while the other lists.

- [ ] **Step 3: Full gates (controller only — not a subagent)**

```bash
cd /Users/operator/orca/workspaces/wakil/burrfish
make build; rc=$?; echo "build rc=$rc"
make test; rc=$?; echo "go rc=$rc"
make app-test; rc=$?; echo "swift rc=$rc"
```

Expected: all three `rc=0`. Do not pipe through `tail`; read `.context/app-test.log` on failure.

- [ ] **Step 4: Commit**

```bash
git add docs/wakil
git commit -m "3a-i: charter rows, the Git row amended, and the acceptance runbook"
```

**After this plan:** the Cover rung (the e2e auditor, `docs/agents/e2e.md`) and then the operator's walk.
