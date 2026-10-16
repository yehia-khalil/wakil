# Public repo split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scrub every employer, client and personal name from Rafiq's tree, then move the
scrubbed tree into a new public repository with one commit.

**Architecture:** One check script (`scripts/public-check.sh`) proves the tree is clean,
reading its patterns from a denylist outside the tree. The scrub lands as one PR on the
private repository, area by area, each area proven by its own suite. The cutover then
exports the merged tree with `git archive` into a new repository, and every outward step
is the operator's to approve.

**Tech Stack:** bash and perl (the check), Go and Swift suites (the proof), `gh`, `git`,
`gitleaks` (installed with Homebrew on the Mac, not added to the repository).

**Spec:** `docs/superpowers/specs/2026-10-15-public-repo-split-design.md`

## Global Constraints

- The real names are never written into a committed file. The denylist lives at
  `~/.config/rafiq/public-denylist.txt`. **This plan names them only as the denylist's
  patterns, and the plan itself must pass the check.**
- First employer org → `Initech Labs` (display), `initech` (identifier), `initech-labs`
  (slug), `initech.atlassian.net` (Jira host); its Jira project key → `INI`.
- Second employer org → `Umbrella`, `umbrella`, `umbrella.atlassian.net`,
  `~/.claude-umbrella`.
- The operator's first name in prose → "the operator". Absolute home paths
  `/Users/<name>/…` → `~/…`. Personal e-mail → removed.
- Allowed to remain: the GitHub handle `yehia-khalil` (and `github.com/yehia-khalil/…`
  URLs), the Go module path `github.com/yehia/rafiq` (out of scope, see spec), the
  LICENSE copyright line and the docs' `**Owner:**` lines.
- `Acme` and `Globex` are existing fixture names; nothing may be renamed onto them.
- Monaco (`app/Resources/monaco/`) is third-party and is not scanned or edited.
- Throwaway output goes in `.scratch/public-split/`, which `.git/info/exclude` ignores.
- Commits carry no `Co-Authored-By` trailer.
- Nothing outward-facing (push, PR, repo rename, repo create, visibility) happens without
  the operator's explicit yes for that step.

## Review Focus

1. **A bare three-digit org identifier that is really a number.** Renaming an HTTP
   status, a byte count or a port would change behavior. Expected: only org identifiers
   change, and the owning suite fails if a number was touched. Covered in Tasks 2 and 3 by
   reading every hit, not replacing blindly, and by the full suites.
2. **Two orgs that a test keeps apart collapse into one** because a mapping hit an
   existing fixture name. Expected: every test that distinguishes orgs still does.
   Covered by the Acme and Globex collision check in Task 1's denylist test and by the
   suites in Tasks 2 and 3.
3. **Case and possessive variants** (all-capitals, `…'s`, a name glued to a
   suffix like `-main`, `-eu`, `.atlassian.net`). Expected: the check catches them.
   Covered by Task 1's case-insensitive, substring test.
4. **Names in places a content grep skips:** file names, JSONL and TSV fixtures, HTML
   artboards and commit metadata. Expected: all are scanned. Covered by Task 1 (file
   names), Task 6 (artboards and fixtures read by hand) and Task 8 (commit metadata).
5. **Files that exist locally but not in git** (ignored, untracked). Expected: they never
   reach the public repository. Covered by Task 8 exporting with `git archive`, which
   takes tracked files only.

---

### Task 1: The denylist and the check

**Files:**
- Create: `~/.config/rafiq/public-denylist.txt` (outside the tree, never committed)
- Create: `scripts/public-check.sh`
- Modify: `.git/info/exclude` (add `/.scratch/` if missing; local only)

**Interfaces:**
- Produces: `scripts/public-check.sh [path…]`. It exits 0 when no tracked file under the
  given paths (default: the whole tree) matches a deny pattern once the allow patterns
  are removed, and exits 1 after printing every hit as `file:line: text`, plus `name: path`
  for each matching file name. It reads `RAFIQ_DENYLIST`, defaulting to
  `~/.config/rafiq/public-denylist.txt`, and exits 2 if that file is missing.
- Denylist format: one Perl regex per line, matched case-insensitively. A line starting
  `allow:` is a pattern removed from each line before the deny patterns run. `#` starts a
  comment.

- [ ] **Step 1: Write the denylist**

Create `~/.config/rafiq/public-denylist.txt`. The operator supplies the deny patterns and the four allow lines (the angle
brackets below are descriptions, filled in when the file is written, never in this plan):

```
# Real names that must not appear in the public tree. Never commit this file.
# deny patterns (one per line): the second employer's name; the first employer's
# name with and without a space or hyphen; the first employer's three-digit identifier
# as a whole word; the operator's first and last name; the home path prefix; the
# personal e-mail; the second employer's Jira key followed by -digits.
allow:<the GitHub handle>
allow:<the Go module path, dots escaped>
allow:<the LICENSE copyright line, parentheses escaped>
allow:<the docs' **Owner:** line prefix and name, asterisks escaped>
```

The operator types the deny patterns into the file themself; the agent asks for them in
chat as plain words, not secrets, and writes the file. It is not a credential.

- [ ] **Step 2: Write the check**

`scripts/public-check.sh`:

```bash
#!/usr/bin/env bash
# public-check — proves the tree names nothing on the denylist.
#
# The denylist lives outside the tree so the check that proves the real names are
# gone does not itself publish them. See
# docs/superpowers/specs/2026-10-15-public-repo-split-design.md.
set -euo pipefail

list="${RAFIQ_DENYLIST:-$HOME/.config/rafiq/public-denylist.txt}"
[ -f "$list" ] || { echo "public-check: no denylist at $list" >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)"
files=$(git ls-files -z -- "${@:-.}" ':!app/Resources/monaco' | tr '\0' '\n')

hits=$(printf '%s\n' "$files" | LIST="$list" perl -ne '
  BEGIN {
    open my $f, "<", $ENV{LIST} or die;
    while (<$f>) { chomp; next if /^\s*(#|$)/;
      if (s/^allow://) { push @allow, qr/$_/i } else { push @deny, qr/$_/i } }
  }
  chomp(my $path = $_);
  my $n = $path; $n =~ s/$_//g for @allow;
  for my $d (@deny) { if ($n =~ $d) { print "name: $path\n"; last } }
  next if -B $path;
  open my $in, "<", $path or next;
  while (my $line = <$in>) {
    my $t = $line; $t =~ s/$_//g for @allow;
    for my $d (@deny) { if ($t =~ $d) { chomp $line; print "$path:$.: $line\n"; last } }
  }
')

[ -z "$hits" ] && exit 0
printf '%s\n' "$hits"
echo "public-check: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') hit(s)" >&2
exit 1
```

Run: `chmod +x scripts/public-check.sh`

- [ ] **Step 3: Prove it can fail, and that allow lines work**

```bash
mkdir -p .scratch/public-split
printf 'foo\nallow:ok-foo\n' > .scratch/public-split/list.txt
```

The check reads tracked files only, and `.scratch/` is excluded, so the probe runs in a
throwaway repository:

```bash
d=.scratch/public-split/repo; rm -rf $d; mkdir -p $d && cd $d && git init -q
printf 'clean\nFOO here\nok-foo stays\n' > a.txt; touch foo-name.txt; git add .
RAFIQ_DENYLIST=../list.txt ../../../scripts/public-check.sh; echo "rc=$?"; cd -
```

Expected: `a.txt:2: FOO here`, `name: foo-name.txt`, then `rc=1`. Line 3 is absent,
because the allow line removed `ok-foo`. Then delete `foo-name.txt` and line 2, re-run,
and expect `rc=0`. Running with `RAFIQ_DENYLIST=/nonexistent` should give `rc=2`.

Then check the placeholders against existing fixtures:
`git grep -ilwE 'initech|umbrella' HEAD | wc -l`. Expected: `0`.

- [ ] **Step 4: Baseline on the real tree**

Run: `scripts/public-check.sh > .scratch/public-split/baseline.txt; echo "rc=$?"; wc -l .scratch/public-split/baseline.txt`
Expected: `rc=1` and some thousands of hits. This baseline is what Tasks 2–5 drive to zero.

- [ ] **Step 5: Commit**

```bash
rm -rf .scratch/public-split/repo
scripts/public-check.sh scripts/public-check.sh docs/superpowers/plans/2026-10-15-public-repo-split.md docs/superpowers/specs/2026-10-15-public-repo-split-design.md; echo "rc=$?"   # expect 0
git add scripts/public-check.sh
git commit -m "Scripts: public-check proves the tree names nothing on a denylist kept outside it"
```

---

### Task 2: Go — cmd, internal, e2e and the Go-side scripts

**Files:**
- Modify: every file under `cmd/`, `internal/`, `e2e/`, and
  `scripts/register_provider_test.go` that `scripts/public-check.sh cmd internal e2e scripts/register_provider_test.go` lists. The heaviest are
  `internal/rafiqcore/provider_test.go`, `sessions_test.go`, `capacity_test.go`,
  `resolve_test.go`, `org_test.go`, `jira_test.go` and `cmd/rafiq/orgcmd_test.go`.

**Interfaces:**
- Consumes: `scripts/public-check.sh` (Task 1).
- Produces: no API change. Org identifiers in fixtures change per the mapping; no exported
  Go identifier is renamed.

- [ ] **Step 1: List the hits**

Run: `scripts/public-check.sh cmd internal e2e scripts/register_provider_test.go | tee .scratch/public-split/go.txt | wc -l`

- [ ] **Step 2: Rewrite, file by file, reading each hit**

Apply the mapping from Global Constraints. Rules for the cases that need judgment:
- The second org's identifier, alone or glued (`<id>-main`, `<id>-eu`, `.claude-<id>`,
  `<id>.atlassian.net`), becomes `umbrella` in the same position.
- The first org's three-digit identifier becomes `initech` **only** where it is an org or
  account identifier: a JSON `"id"`, an `org` argument, a `<id>/main` account path, or a
  `RAFIQ_ORG` value. Where it is a count, a status, a size or a port, it stays.
- Account names that combine both orgs (second org's id + `-` + first org's id) become
  `umbrella-initech`.
- `/Users/<name>/rafiq.acceptance…` and similar absolute paths become
  `/Users/operator/rafiq.acceptance…` where a test asserts on an absolute path, and `~/…`
  in comments.
- An SSH-style `<name>@<ip>` becomes `operator@<ip>`.
- A comment that names the operator becomes "the operator".

After each file, run its package's tests: `CGO_ENABLED=0 go test ./internal/rafiqcore/ -run . -count=1`
(or the package you touched). Expected: PASS before you move on.

- [ ] **Step 3: Prove the area is clean and green**

Run: `scripts/public-check.sh cmd internal e2e scripts/register_provider_test.go; echo "rc=$?"`
Expected: `rc=0`.

Run: `make test`
Expected: PASS (both `docs-check` and `go test ./...`).

- [ ] **Step 4: Commit**

```bash
git add cmd internal e2e scripts/register_provider_test.go
git commit -m "Go: fixtures and comments use placeholder orgs and paths, not real ones (public split)"
```

---

### Task 3: Swift — app sources, tests and fixtures

**Files:**
- Modify: the files `scripts/public-check.sh app` lists. Heaviest are
  `app/Tests/RafiqKitTests/AccountTableTests.swift`, `WindowModelTests.swift`,
  `VocabularyStoreTests.swift`, `OrgSwitchTests.swift` and `TerminalActionsTests.swift`.
  The sources are `RafiqApp/OrgPlane.swift` (TextField placeholders), `SettingsPane.swift`,
  `RafiqKit/App/OrgListings.swift`, `RafiqKit/Panes/AccountTable.swift`,
  `Api/ApiDraft.swift`, `Api/ApiResolveDraft.swift`, `App/WindowModel.swift` and
  `Context/ContextStore.swift`. The fixtures are `app/Fixtures/stream-json/*.jsonl`.

**Interfaces:**
- Consumes: `scripts/public-check.sh`.
- Produces: no API change. `OrgPlane`'s placeholder text becomes `"Initech Labs"` and
  `"initech-labs"`. The slug test's example becomes `"Initech Labs"` → `initech-labs` and
  `"Umbrella"` → `umbrella`, keeping its padded-whitespace case.

- [ ] **Step 1: List the hits**

Run: `scripts/public-check.sh app | tee .scratch/public-split/swift.txt | wc -l`

- [ ] **Step 2: Rewrite, reading each hit**

Use the same rules as Task 2, Step 2. In `IdentifierCorpusTests.swift` the second org's
capitalised name is a corpus entry; it becomes `["Umbrella"]`. Keep the spelling of every
expectation consistent with its input, so a slug test still slugs what it feeds in.

- [ ] **Step 3: Prove the area is clean and green**

Run: `scripts/public-check.sh app; echo "rc=$?"`
Expected: `rc=0`.

Run: `make build app-test`. The Swift suite runs against `bin/`, so build first.
Expected: PASS. If it fails, rerun once alone with nothing else loading the machine
before treating it as real, because the Rafiq suites flake under load.

- [ ] **Step 4: Commit**

```bash
git add app
git commit -m "App: placeholders, fixtures and tests use placeholder orgs, not real ones (public split)"
```

---

### Task 4: Probes and scripts

**Files:**
- Delete: `scripts/probe/stt-set2/vocab-small.txt`,
  `scripts/probe/stt-set2/vocab-snapshot-2026-10-06.txt`
- Modify: `scripts/probe/stt-set2/vocab_code.py`, `scripts/probe/stt-set2/README.md`,
  `scripts/probe/stt-set2/utterances.tsv`, `scripts/probe/stt-score.py`,
  `scripts/probe/sttspike/Sources/sttspike/main.swift`,
  `scripts/probe/termspike/README.md`, `scripts/probe/termspike/Sources/termspike/Feed.swift`,
  `scripts/probe/setuptoken/setup-token-probe.sh`, `scripts/project-sync.sh`

**Interfaces:**
- Consumes: `scripts/public-check.sh`.

- [ ] **Step 1: Delete the vocabulary dumps and note it**

```bash
git rm -q scripts/probe/stt-set2/vocab-small.txt scripts/probe/stt-set2/vocab-snapshot-2026-10-06.txt
```

Add to `scripts/probe/stt-set2/README.md`, under its title:

```markdown
> The vocabulary files this probe scored against (`vocab-small.txt`,
> `vocab-snapshot-*.txt`) were a private Jira's ticket keys and are not published. The
> result is recorded in `docs/rafiq/2d-stt-probe.md`.
```

- [ ] **Step 2: Rewrite the remaining hits**

Use the same rules as Task 2, Step 2. Ticket keys `<KEY>-<n>` become `INI-<n>`. In
`scripts/project-sync.sh`, keep the `yehia-khalil/rafiq` handle, which the allow line
covers, and replace anything else.

- [ ] **Step 3: Prove it**

Run: `scripts/public-check.sh scripts; echo "rc=$?"`
Expected: `rc=0`.

Run: `bash -n scripts/project-sync.sh scripts/probe/setuptoken/setup-token-probe.sh && python3 -m py_compile scripts/probe/stt-score.py scripts/probe/stt-set2/vocab_code.py`
Expected: no output. Only the syntax is checked; the probes are finished and are not run.

- [ ] **Step 4: Commit**

```bash
git add -A scripts
git commit -m "Scripts: drop the private ticket-key vocabulary and use placeholder names in probes (public split)"
```

---

### Task 5: Docs and root files

**Files:**
- Modify: every file `scripts/public-check.sh docs PRODUCT.md CLAUDE.md AGENTS.md CONTRIBUTING.md README.md`
  lists (about 111 under `docs/`, including the `.dc.html` artboards in
  `docs/rafiq/screens/`).

**Interfaces:**
- Consumes: `scripts/public-check.sh`.

- [ ] **Step 1: List the hits**

Run: `scripts/public-check.sh docs PRODUCT.md CLAUDE.md AGENTS.md CONTRIBUTING.md README.md | tee .scratch/public-split/docs.txt | cut -d: -f1 | sort | uniq -c | sort -rn`

- [ ] **Step 2: Rewrite the prose**

Apply the mapping. Rules for prose:
- The operator's first name, used as a person in prose, becomes "the operator" (or
  "the operator's" for a possessive). Fix the grammar of the sentence around it, and
  don't leave the surname behind.
- The `**Owner:**` lines keep the name; the allow line covers them.
- Sentences describing the operator's employers ("works across two organizations — X and
  Y") become "works across two organizations — Initech Labs and Umbrella".
- In the charter, run `make docs-check` after editing; the 4,000-word limit still binds.

Commit `docs/rafiq/` and the rest separately, so each diff stays reviewable:

```bash
git add docs/rafiq && git commit -m "Docs: the charter and its logs use placeholder orgs and 'the operator' (public split)"
git add docs PRODUCT.md CLAUDE.md AGENTS.md CONTRIBUTING.md README.md && git commit -m "Docs: specs, plans and root docs use placeholder orgs and 'the operator' (public split)"
```

- [ ] **Step 3: Prove the whole tree is clean**

Run: `scripts/public-check.sh; echo "rc=$?"`
Expected: `rc=0`. This is the first whole-tree zero.

Run: `make docs-check`
Expected: the charter is under 4,000 words.

---

### Task 6: Leak review and secret scan

**Files:**
- Read: all of `docs/rafiq/`, `docs/rafiq/screens/*.html`, `e2e/checks/**/*.jsonl`,
  `app/Fixtures/`, `scripts/probe/**/*.tsv`
- Create: `.scratch/public-split/review.md` (findings; not committed)

- [ ] **Step 1: Secret scan**

```bash
command -v gitleaks || brew install gitleaks
gitleaks detect --no-git --source . --report-path .scratch/public-split/gitleaks.json --redact; echo "rc=$?"
```

Every finding must be a known fake test token (`sk-ant-oat01-EXAMPLE…`,
`…-not-a-real-token`, `hunter2@db.internal` and similar). List each one in `review.md`
as `file:line — fake: <why>`. Any finding that is not plainly fake: **stop and tell the
operator**; do not edit it away silently.

- [ ] **Step 2: Read what a grep can't judge**

Read every listed file for: other people's names, real ticket titles, real customer or
booking data, internal hostnames that aren't `*.internal` or `example.*` fixtures, and
screenshots of real accounts. Write each finding to `review.md` as
`file:line — what — proposed fix`.

- [ ] **Step 3: Operator decides, then fix**

Show `review.md` to the operator. Apply only the fixes they approve, re-run
`scripts/public-check.sh` (expect `rc=0`), and commit:

```bash
git add -A && git commit -m "Docs: remove what the public-split leak review found"
```

---

### Task 7: The scrub PR

- [ ] **Step 1: Full gate**

Run: `scripts/public-check.sh && make test && make build app-test; echo "rc=$?"`
Expected: `rc=0`. Capture with `rc=$?`; never pipe into `tail` or `grep`.

- [ ] **Step 2: Draft the PR for the operator**

Show the operator the title and body: what was renamed (the mapping, with placeholders
only), what was deleted, the review findings and how each was resolved, and the gate
result. Push and open the PR **only after their sign-off**:

```bash
git push -u origin yehia-khalil/public-split
gh pr create --base main --title "Public split: scrub real org and personal names from the tree" --body-file .scratch/public-split/pr-body.md
```

- [ ] **Step 3: CI green, operator merges**

Wait for the `swift.yml` workflow. The operator merges.

---

### Task 8: Cutover (every step is the operator's to approve)

> Amended 2026-10-15 by the Wakil rename: the new repository is `yehia-khalil/wakil`, and
> `yehia-khalil/rafiq` is archived where it stands instead of being renamed.

**Files:**
- Create: `.git/hooks/pre-push` in the new clone (local, not committed)

- [ ] **Step 1: In-flight branches**

```bash
git worktree list   # from the private clone
gh pr list -R yehia-khalil/rafiq --state open
```

Show the operator every worktree whose branch is not an ancestor of `origin/main`
(`git merge-base --is-ancestor <branch> origin/main`). Each one lands or is abandoned
**before** step 3. Do not proceed while any is undecided.

- [ ] **Step 2: Export the tree with one commit**

```bash
git fetch origin main
src=$(git rev-parse --show-toplevel)
out=~/Desktop/scripts/wakil-public
rm -rf "$out" && mkdir -p "$out"
git archive origin/main | tar -x -C "$out"
cd "$out" && git init -q -b main && git add -A
WAKIL_DENYLIST=~/.config/wakil/public-denylist.txt "$src/scripts/public-check.sh"; echo "rc=$?"   # expect 0
GIT_AUTHOR_NAME=yehia-khalil GIT_AUTHOR_EMAIL=yehia-khalil@users.noreply.github.com \
GIT_COMMITTER_NAME=yehia-khalil GIT_COMMITTER_EMAIL=yehia-khalil@users.noreply.github.com \
git commit -q -m "Wakil: initial public commit"
git log --format='%an <%ae> | %cn <%ce>'
```

Expected: one line, both identities being the noreply address.

- [ ] **Step 3: Archive the old repository** (operator: yes?)

```bash
gh repo archive yehia-khalil/rafiq --yes
```

- [ ] **Step 4: Create the new private repository and push** (operator: yes?)

```bash
cd ~/Desktop/scripts/wakil-public
gh repo create yehia-khalil/wakil --private --source . --push \
  --description "Native macOS workspace with ambient org, project and environment context — every tool, and the agent, already knows which one you mean."
gh repo edit yehia-khalil/wakil --add-topic macos,swift,swiftui,go,metal,developer-tools,productivity,ai-agents,claude-code,mcp
gh repo view yehia-khalil/wakil --json description,repositoryTopics,licenseInfo,visibility
```

Expected: description and topics read back, `licenseInfo.spdxId` is `MIT`, and
`visibility` is `PRIVATE`.

- [ ] **Step 5: Pre-push guard**

```bash
cat > ~/Desktop/scripts/wakil-public/.git/hooks/pre-push <<'EOF'
#!/usr/bin/env bash
# Refuse a push whose tree names anything on the denylist (public split).
exec "$(git rev-parse --show-toplevel)/scripts/public-check.sh"
EOF
chmod +x ~/Desktop/scripts/wakil-public/.git/hooks/pre-push
```

Prove it: add a denied word to a scratch commit, run `git push --dry-run`, and expect a
refusal with the hit printed. Then reset the scratch commit with `git reset --hard HEAD~1`.

- [ ] **Step 6: Re-file the open issues** (operator: yes?)

```bash
gh issue list -R yehia-khalil/rafiq --state open --json number,title,labels
```

For each, draft a scrubbed title and body for the operator. After sign-off, create it
with `gh issue create -R yehia-khalil/wakil` and recreate the three labels first
(`bug`, `needs-triage`, `wontfix`).

- [ ] **Step 7: Repoint the local clone and Orca**

The local working repository becomes `~/Desktop/scripts/wakil-public`. Point
the Orca workspace at it and recreate worktrees from the new `main`, using the
Orca CLI binary inside Orca.app (bare `orca` fails on this Mac). The old clone stays as
it is, with its remote still pointing at the archived `yehia-khalil/rafiq`.

- [ ] **Step 8: Operator makes it public**

The operator reviews `https://github.com/yehia-khalil/wakil` and, when satisfied, runs:

```bash
gh repo edit yehia-khalil/wakil --visibility public --accept-visibility-change-consequences
```
