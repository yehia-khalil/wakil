# Issue tracker: GitHub

Issues live on `yehia-khalil/wakil`. Use the `gh` CLI; it infers the repo inside a clone.

## Issues are a bug inbox

**Since 2026-09-26, an issue is a defect report and nothing else.** Specs and plans are
files under `docs/superpowers/`; see `docs/agents/workflow.md`. No maps, no grilling or
research tickets, no child tickets, no issue-as-spec.

[#179](https://github.com/yehia-khalil/rafiq/issues/179) (2c-iv) and
[#89](https://github.com/yehia-khalil/rafiq/issues/89) (2e) are the last two
issues-as-spec and stay open, binding. Nothing after them.

## Operations

- **Create**: `gh issue create --title "..." --body "..."` — heredoc for multi-line bodies.
- **Read**: `gh issue view <number> --comments`
- **List**: `gh issue list --state open --json number,title,labels --jq '.[] | "\(.number)\t\(.title)"'`
- **Comment**: `gh issue comment <number> --body "..."`
- **Label**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`
- **Reopen a parked issue**: `gh issue reopen <number>` — the index is `docs/wakil/parked.md`.

## Labels

Three. See `docs/agents/triage-labels.md`.

## Project board

[**Wakil**](https://github.com/users/yehia-khalil/projects/6) (`--owner yehia-khalil`,
number `6`) is a view over the open issues. With issues reduced to a bug inbox it is a
short list, and `Status` is still derived rather than asserted:

1. closed → `Done`
2. has an assignee → `In flight`
3. open `blocked_by` dependency, or `needs-info` → `Blocked`
4. `needs-triage` → `Triage`
5. otherwise → `Ready`

`scripts/project-sync.sh` re-derives it and adds any open issue the board is missing;
`--dry-run` prints without writing. **It runs long — 400s+ historically — so background
it and never block on it.** Never hand-set `Status`: the next sync overwrites it.

Needs the `project` gh scope (`gh auth refresh -s project`).

## Pull requests

**PRs as a request surface: no.** GitHub shares one number space across issues and PRs,
so a bare `#42` may be either: resolve with `gh pr view 42` and fall back to
`gh issue view 42`.
