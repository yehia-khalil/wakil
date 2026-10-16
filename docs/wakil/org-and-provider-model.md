# Organisations and providers — deferred design decision

**Status: SUPERSEDED 2026-09-06** by
`docs/superpowers/specs/2026-09-06-org-provider-decoupling-design.md`, which implements
this model and answers the open questions below. Kept for the reasoning and the
measurements, which the spec cites rather than repeats.

*(Original status, when this was written: "deferred to Phase 2. Nothing here is
implemented." Recorded then because Phase 1 shipped an assumption that
contradicted the intended model, and the gap was cheap to close later only if it
was written down while the reasoning was fresh.)*

## The intended model

> Organisations are not companies I work at. I need to create organisations with
> custom names that have nothing to do with my Claude accounts or subscriptions.
> Claude accounts are just pluggable LLMs attached to an organisation. Each
> organisation keeps its own credentials and secrets, and that must not be tied to
> Claude accounts. I also need different providers within the same organisation —
> Codex, or a local LLM.

Two independent axes:

| Axis | What it owns | Examples |
|---|---|---|
| **Organisation** | credentials, secrets, projects, Jira binding, DB refs | `initech`, `client-a`, `side-project` |
| **Provider / agent account** | the model, the auth, the rate limit, the bill | a Claude subscription, Codex, a local LLM |

They are orthogonal. One organisation may have several providers (two Claude
accounts for rate-limit headroom, plus a local model for cheap work). One provider
may serve several organisations.

## What Phase 1 actually assumes

Phase 1 collapses both axes into one: **the organisation IS the Claude config dir.**

```go
func CurrentOrg() string { return OrgFromConfigDir(os.Getenv("CLAUDE_CONFIG_DIR")) }
```

`~/.claude-initech` → org `initech`. The org name is the directory's basename with
`.claude` stripped.

Three consequences, all of which contradict the model above:

1. **Org names are not free.** They must be spellable as a config-dir suffix, and
   the directory must be named to match.
2. **One provider per org, structurally.** Two Claude accounts cannot serve org
   `initech`, because two directories cannot share a basename. This is what makes a
   rate limit on the initech account block initech work entirely: switching to another
   account changes the org, and the cross-org guard then refuses the project — a
   guard doing exactly its job, against a threat that was never the point.
3. **Non-Claude providers have no way in.** There is no directory for Codex or a
   local model to derive an org from.

## How deeply is Claude wired in?

Measured, not estimated. Every non-test reference to `CLAUDE_CONFIG_DIR` in
`internal/` and `cmd/`:

| Site | Purpose | Under the new model |
|---|---|---|
| `paths.go` — `CurrentOrg()` | derives the org | **the only thing that must change** |
| `sessions.go` — `sessionsRoot()` | reads `$CLAUDE_CONFIG_DIR/projects` | ~~**stays**~~ — **wrong, see correction below.** The implementation deleted this function; session discovery now enumerates the org's registered providers instead of reading an ambient directory. |
| `active.go` | comments and one error message | text only |
| `scripts/register-org.sh` | passes it to each server | becomes per-provider registration |

That is the whole coupling. The five MCP servers are plain stdio binaries speaking
the MCP protocol; nothing in them is Claude-specific. Any MCP-capable client can
launch them today.

**Session discovery is the exception, and it should stay Claude-specific.**
`sessionsRoot()` reads Claude Code's own transcript layout. That is not a leak of
the wrong abstraction — session discovery is inherently per-harness, and a Codex or
local-model provider would need its own adapter with its own on-disk format. The
right shape is a small provider interface behind `ListSessions`, not a generalised
path.

### Exactly what breaks when the provider is not Claude Code

Counted against the tools actually registered in `cmd/`, not estimated:

| Tools | Count | Under a non-Claude provider |
|---|---|---|
| `get_context`, `set_project`, `set_environment`, `list_projects`, `list_environments` | 5 | work unchanged |
| `list_databases`, `list_tables`, `describe_table`, `query` | 4 | work unchanged |
| `my_issues`, `search_issues`, `get_issue` | 3 | work unchanged |
| `request` | 1 | works unchanged |
| `recall` | 1 | works unchanged — Phase 1 binds Jira as its **only** fan-out source (`sourceJira`, recall.go:12). It is not session-backed, so it does not inherit the coupling below. |
| **`list_sessions`, `get_session`** | **2** | **go dark** |

So 14 of 16 tools are already provider-agnostic; the servers are plain stdio MCP
binaries and any MCP-capable client can launch them today. The migration in this
document is about **credential scoping**, not about client compatibility — that
distinction is worth keeping straight, because it makes the change much smaller
than "make Wakil multi-provider" sounds.

`get_session` is coupled twice over: it filters `ListSessions()`' output *and*
then reads the transcript itself through `sessionsRoot()` (sessions.go:320-336).
Both halves need the adapter; fixing only `ListSessions` would leave it returning
a session it then cannot read.

### The trap: today's org/session agreement is accidental, and this change breaks it

The final Phase 1 review checked cross-org isolation and concluded, correctly for
the code as it stands:

> `sessionsRoot()` derives from the same `CLAUDE_CONFIG_DIR` as `CurrentOrg()`, so
> session discovery is org-scoped by construction.

That is true **only because both read the same environment variable**. The moment
`CurrentOrg()` reads `WAKIL_ORG` instead, the two can disagree — and `sessionsRoot()`
does not fail when `CLAUDE_CONFIG_DIR` is unset, it silently falls back to
`~/.claude/projects` (sessions.go:106-116). Launch a provider with `WAKIL_ORG=umbrella`
and no `CLAUDE_CONFIG_DIR` and you are operating as org `umbrella` while listing the
*default* Claude account's transcripts.

This is not a credential leak — `ListSessions` still only returns transcripts whose
cwd is under the active project's roots, and the project itself is still org-checked
by `Resolve()`. It is a correctness and provenance problem: the answer to "which
provider's history am I looking at?" stops being "this one's". Whoever picks this up
must decide deliberately whether session discovery keys off the provider or off the
org, and say so in `sessionsRoot()`'s doc comment. Doing nothing means the guarantee
quietly degrades from "by construction" to "by coincidence".

> **Correction, 2026-09-06:** the implementation did not leave `sessionsRoot()` in
> place with a corrected doc comment — it deleted the function outright.
> `internal/wakilcore/sessions.go` now enumerates the current org's *registered*
> providers (`ListProvidersFor`) and, for each `claude-code` one, reads its
> recorded `configDir` directly; nothing reads the ambient `CLAUDE_CONFIG_DIR`
> variable at all, so the silent-fallback trap described above cannot occur —
> there is no longer an environment variable for a launcher to leave stale. See
> `docs/superpowers/specs/2026-09-06-org-provider-decoupling-design.md` §6.

## The change, when it happens

Replace the derivation with an explicit value, passed by whatever launches the
server:

```go
// org comes from the launcher, not from the harness's own directory layout.
func CurrentOrg() string {
    if org := os.Getenv("WAKIL_ORG"); org != "" {
        return org
    }
    return OrgFromConfigDir(os.Getenv("CLAUDE_CONFIG_DIR")) // legacy fallback
}
```

The mechanism already exists: `register-org.sh` passes `-e CLAUDE_CONFIG_DIR=<dir>`
into every registration, so it would pass `-e WAKIL_ORG=<name>` the same way. What
changes is that the org becomes something the *launcher declares* rather than
something the *directory implies*.

This unlocks all three requirements at once:

- **Custom org names** — any string that is filename-safe (`active-<org>.json` and
  the Keychain ref `jira:<org>` both embed it; see `orgFileTokenPattern` in
  `active.go` for the guard that already exists and why it refuses rather than
  sanitises).
- **Several providers per org** — every registration for org `initech` passes
  `WAKIL_ORG=initech`, whatever client it is registering into. Two Claude accounts, or
  Claude plus Codex, all resolve the same credentials and the same projects.
- **Rate-limit failover** — hit a limit on one account, launch another that carries
  the same `WAKIL_ORG`, keep working on the same project with the same secrets.

Everything downstream already keys on the org string and needs no change:
`active-<org>.json`, the `jira:<org>` Keychain ref, `Resolve()`'s cross-org check,
and `list_projects`' filter.

## Security note — read before implementing

The org selects which credentials a process can reach. Today it is derived from
`CLAUDE_CONFIG_DIR`, which the operator sets at launch. Under the new model it
would come from `WAKIL_ORG`, also set at launch.

The property that must be preserved: **the org is chosen by whoever launches the
process, and is never influenced by anything a project file or a model can
control.** A `project.json` declares which org it *belongs to* — that is what
`Resolve()` checks against — but it must never be able to *set* the ambient org, or
the cross-org guard becomes a comparison of a value against itself.

Rename `register-org.sh`'s framing too: it registers **a provider for an org**, not
an org.

## Open questions

- Where does the org registry live? `~/.wakil/orgs.json`, or a directory per org?
  Projects are already registered globally in `~/.wakil/projects.json` and declare
  their own org, so a separate registry may not be needed at all.
- Does a provider need per-org settings (model choice, token budget), or is it
  enough that the launcher knows?
- Session discovery per provider: what does `list_sessions` mean when an org has
  three providers with three transcript formats? Merged, or grouped by provider the
  way `recall` groups by source?

### How they were answered — 2026-09-06, by the implementation

Recorded here so this file's last section is not read as still-open. The reasoning
is in `docs/superpowers/specs/2026-09-06-org-provider-decoupling-design.md`.

- **Org registry: a directory per org.** `~/.wakil/orgs/<org>/` holds `org.json`,
  `active.json`, `projects.json` and `providers/<id>.json`. There is no `orgs.json`
  — the directory name *is* the org id, so the two cannot disagree, and
  `OrgDirFor`'s existence check is what turns a mistyped `WAKIL_ORG` into a refusal
  ("org `umbrela` is not registered") instead of state quietly created under a
  phantom org. The project registry moved inside it rather than staying global,
  which turned a silent filter into a report: an entry whose `project.json`
  declares a different org used to just vanish from `list_projects`, and now comes
  back under `misfiled` with both orgs named.
- **Per-org provider settings: not yet, and nothing depends on it.** A provider
  record carries `kind`, an optional `label` and — for `claude-code` — `configDir`.
  Model choice and token budget belong to the harness for now. An org may name a
  `defaultProvider`, which is advisory: `get_context` reports selected-vs-running
  and never blocks on a mismatch.
- **Session discovery: merged, tagged, with unreadable stores named.**
  `list_sessions` returns one list across every provider the org holds, newest
  first, each session carrying the `provider` it came from — so the merge does not
  cost provenance. `unreadProviders` names providers whose stores could not be
  looked inside (a kind with no session adapter, a `claude-code` record with no
  `configDir`, an unreadable store, an unparseable record), which is `recall`'s
  `sources` idea applied here: "answered and had nothing" must stay distinguishable
  from "was never asked".
