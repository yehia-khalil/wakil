# Public repo split — design

**Status:** proposed · **Created:** 2026-10-15 · **Amended 2026-10-15** by
`2026-10-15-rename-to-wakil-design.md`: the new public repository is `yehia-khalil/wakil`,
the old one is archived without being renamed, and the Go module path is in scope there.

## Goal

Publish Rafiq as a public repository that names no employer, no client and no personal
account, and make that public repository the only one work happens in.

## Decisions (agreed 2026-10-15)

1. **A new repository with one commit**, not a history rewrite. All 1,140 commits of the
   current history carry the names, so cleaning today's tree alone would publish them
   anyway; rewriting the history in place breaks every worktree, branch and PR link.
2. **The public repository becomes the working repository.** The current one is renamed,
   kept private and archived. Nothing is synced from private to public afterwards, so a
   name can only leak through a new commit, and the guard below covers that.
3. **Every org name becomes a neutral placeholder**, and the operator's name survives only
   in the LICENSE copyright and the docs' *Owner* lines.

## The mapping

The real names are kept in a denylist **outside the tree**
(`~/.config/wakil/public-denylist.txt`), never in a committed file, so the check that
proves they are gone does not itself publish them.

| Kind | Becomes |
|---|---|
| First employer org: display name, identifier, slug, Jira host | `Initech Labs`, `initech`, `initech-labs`, `initech.atlassian.net` |
| Second employer org: display name, identifier, Jira host, Claude config dir | `Umbrella`, `umbrella`, `umbrella.atlassian.net`, `~/.claude-umbrella` |
| The first org's Jira project key | `INI` (so `INI-2835`) |
| The operator's first name in prose | "the operator" |
| Absolute home paths (`/Users/<name>/…`) | `~/…` |
| Personal e-mail | removed |

The GitHub handle `yehia-khalil` stays: it is the repository's owner and visible in its
URL anyway. The denylist allows it explicitly.

**Why not Acme and Globex**, as first proposed: both are already fixture names (Acme in
62 files, Globex in 6), and tests distinguish orgs by name. Mapping a real org onto an
existing fixture would merge two orgs a test means to keep apart. Initech and Umbrella
appear nowhere.

**The first org's identifier is a bare number** in the account tables and their tests
(an org named by three digits, and account rows such as `<digits>/main`). It is replaced where it is an org identifier and
left where it is a number, by reading each hit; a blind replace is wrong here. The tests
are the proof that the reading was right.

## Removed, not renamed

- `scripts/probe/stt-set2/vocab-small.txt` and `vocab-snapshot-2026-10-06.txt`: a dump of
  roughly 3,000 real ticket keys from the first org's Jira. The probe is finished (its
  result is recorded in `docs/rafiq/2d-stt-probe.md`), and the scoring script that reads
  them is kept with a one-line note that its vocabulary was private.
- Anything the leak review below flags as personal rather than about Rafiq.

## Where the work happens

1. **Scrub on a branch of the private repository**, as one PR. The diff is reviewable,
   and CI and the suites run on it like any other change.
2. **Gate the PR** on all of:
   - the denylist grep over the tree returns nothing, case-insensitive, Monaco excluded;
   - a secret scan (`gitleaks detect --no-git`) finds nothing beyond the known fake
     test tokens (`sk-ant-oat01-EXAMPLE…` and similar), each of which is listed;
   - a read of every `docs/` file a grep cannot judge: other people's names, ticket
     titles, screenshots and `.dc.html` artboards with real data;
   - `make test`, `make build app-test` and CI are green.
3. **Export the merged tree** with `git archive` into an empty directory, and make one
   commit, authored as `yehia-khalil <yehia-khalil@users.noreply.github.com>`, so the
   personal e-mail is not in the commit metadata either.

## Cutover

1. Before the cut, **every in-flight branch lands or is abandoned.** There are 13
   worktrees today; a branch left on the old history cannot be merged into the new
   repository except by replaying it as a patch.
2. Archive `yehia-khalil/rafiq` where it stands; it is not renamed.
3. Create a new **private** `yehia-khalil/wakil` and push the single commit. The rename PR
   already points `docs/agents/issue-tracker.md` and CLAUDE.md at it.
4. Set the About text, topics and branch protection again.
5. Re-file the two open bug issues in the new repository, scrubbed.
6. Repoint the local clone and the Orca workspace at the new remote, and recreate the
   worktrees from it.
7. **The operator** reviews the new repository on GitHub, then makes it public.

## The guard against new leaks

A local `pre-push` hook (in `.git/hooks`, not committed) runs the same denylist grep over
the pushed commits and refuses the push on a hit. It lives outside the tree for the same
reason the denylist does.

## Not in scope

- **The Go module path** is `github.com/yehia/rafiq`, which does not match the repository.
  `go install` from the public repository will not work until it does. Changing it touches
  every import, so it is its own change.
- PR and issue numbers cited in the docs (`#138`, `PR #427`) will point at the new
  repository's unrelated numbers. They are left as they are; the archive keeps their
  meaning.
- The private repository's issues and PRs are not migrated.

## Open questions

None blocking. The leak review in step 2 may find files to remove; each is listed in the
PR description.
