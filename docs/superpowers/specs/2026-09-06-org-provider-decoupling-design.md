# Organisations and providers — decoupling design

**Status:** approved 2026-09-06 · **Supersedes:** `docs/wakil/org-and-provider-model.md`
(the deferred-decision note), whose three open questions this document answers.

**Lands before any Phase 2 / Swift work.** Phase 2's `AgentHarness`, org switcher and
Settings UI all read the model defined here; building them against Phase 1's assumption
would mean rewriting them.

---

## 1. The problem

Phase 1 collapsed two independent axes into one:

```go
func CurrentOrg() string { return OrgFromConfigDir(os.Getenv("CLAUDE_CONFIG_DIR")) }
```

The organisation **is** the Claude config dir. `~/.claude-initech` → org `initech`. Three
consequences, all contradicting the intended model:

1. Org names are not free — they must be spellable as a config-dir suffix.
2. One provider per org, structurally: two directories cannot share a basename. A rate
   limit on the initech account therefore blocks initech work entirely, because switching
   accounts changes the org and the cross-org guard then refuses the project — a guard
   doing its job against a threat that was never the point.
3. Non-Claude providers have no directory to derive an org from.

The intended model has two orthogonal axes:

| Axis | Owns | Examples |
|---|---|---|
| **Organisation** | credentials, secrets, projects, Jira binding, DB refs | `initech`, `client-a`, `side-project` |
| **Provider** | the model, the auth, the rate limit, the bill | a Claude subscription, Codex, a local LLM |

One org may have several providers. A provider may serve several orgs.

## 2. Scope

**In:** the on-disk registry for orgs and providers, org identity from an explicit
launcher-declared value, per-org projects and active context, provider-aware session
discovery, the `wakil org` / `wakil provider` CLI, the reworked registration script, and
the charter amendment that permits all of it.

**Out:** anything Swift. Launching a provider, the provider dropdown, and the
rate-limit handoff flow are Phase 2 — nothing headless can perform them (§7).

## 3. Identity

### 3.1 Org

`CurrentOrg()` reads **`WAKIL_ORG` and nothing else**. `OrgFromConfigDir` is deleted.

Unset is a `UserError`. There is deliberately no fallback to `CLAUDE_CONFIG_DIR`: a
fallback resolves silently to `default`, or to whatever config dir the process happened
to inherit, and the failure then surfaces far from its cause as a missing credential.
That is the same reasoning that made the Phase 1 Keychain rename refuse a fallback, and
the same failure mode `register-org.sh`'s header already documents at length.

An org not present under `~/.wakil/orgs/` is a hard error naming the org and pointing at
`wakil org create`. This is load-bearing: today a mistyped org is caught by the
filesystem, because `register-org.sh` refuses when `~/.claude-umbrela` does not exist.
Once the org is a free-form string, nothing else would catch `WAKIL_ORG=umbrela` — it is a
legal token, `orgs/umbrela/active.json` would be created, and the failure would appear
much later as "no credential for `jira:umbrela`". The registry restores that check.

`orgFileTokenPattern` (`active.go:47`) keeps its job unchanged. The org is now a
directory name rather than a filename infix, and both uses need the same guarantee: no
`/`, no leading dot, plus no `:` for the Keychain service name. An invalid org stays an
error rather than something sanitised, for the reason already recorded there — sanitising
maps two distinct orgs onto one file, which is the exact collision the split prevents.

### 3.2 Provider

`WAKIL_PROVIDER` names the provider id and is **optional**. Optional because the operator
runs `wakil secrets set` by hand, where the launcher is a human and there is no provider
at all. Its only consumer is the match report in §7; session discovery does not need it,
because it enumerates every provider of the org.

When set, it must name a provider registered under the current org; an unknown id is an
error, for the same typo reason as the org.

### 3.3 The security property, unchanged

**The org is chosen by whoever launches the process, and is never influenced by anything
a project file or a model can control.**

Therefore: no active-org file, and no `set_org` tool. A `project.json` declares which org
it *belongs to* — that is what `Resolve()` checks against — but it must never *set* the
ambient org, or the cross-org guard degrades into comparing a value against itself.

Phase 2 switches org by relaunching the harness with a different `WAKIL_ORG`, not by
writing a file that a running server re-reads.

## 4. On-disk layout

```
~/.wakil/
  orgs/
    initech/
      org.json
      active.json
      projects.json
      providers/
        primary.json
        backup.json
    umbrella/
    personal/
```

Nothing global survives except `orgs/` itself.

**Why a directory per org rather than one or two shared files.** Per-file writes never
collide. Several sessions run concurrently as a matter of routine here, and that is the
same class of bug the per-call temp file in `active.go:182` was introduced to fix — a
shared file is a shared write target. It also gives per-org state one consistent home,
which is why `active.json` and `projects.json` move in rather than staying alongside.

### 4.1 `org.json`

```json
{
  "displayName": "Initech Labs",
  "jiraBase": "https://example.atlassian.net",
  "defaultProvider": "primary"
}
```

`jiraBase` moves here, out of the registration script. With N providers per org it was N
places to state one fact, and two providers of `initech` registered with different Jira sites
was a silent inconsistency nothing checked. The Jira site belongs to the org for the same
reason the `jira:<org>` Keychain ref does.

Validation reuses `normalizeJiraBase` (`jira.go:137`), which already rejects non-https,
userinfo, query, fragment and path, and already has tests. What changes is that it is now
called at **creation** time from `wakil org create --jira-base`, so a bad value is
refused when typed rather than at first Jira call — and the equivalent check in bash is
retired. `NewJiraFromEnv` reads `org.json`, with `WAKIL_JIRA_BASE` retained as an
override for one-off CLI use.

`defaultProvider` is optional and, when set, must name a registered provider.

### 4.2 `providers/<id>.json`

```json
{
  "kind": "claude-code",
  "label": "Initech Labs — primary subscription",
  "configDir": "/Users/you/.claude-initech"
}
```

`kind` is one of `claude-code`, `codex`, `local`.

- `claude-code` — `configDir` required, validated to exist at registration. This restores
  the filesystem check lost in §3.1 and is the only kind with a session adapter (§6) and
  automated MCP registration (§8).
- `codex`, `local` — recorded, not automated. `wakil provider add` prints exactly what
  that client needs (binary paths, `WAKIL_ORG`, `WAKIL_PROVIDER`) for the operator to
  wire in by hand.

Recording a kind we do not automate is honest rather than aspirational: 14 of the 16
tools are already provider-agnostic stdio MCP servers and work unchanged under any
MCP-capable client. Only `list_sessions` and `get_session` are Claude-specific. Claiming
to automate a client that has never been tested would be the dishonest option.

### 4.3 `projects.json`

```json
{
  "booking": { "path": "/Users/you/src/booking/.wakil/project.json", "provider": "backup" }
}
```

Per-org, and the value grows from a bare path string to an object. Both changes are free
now and would each cost a migration later.

`provider` is optional; absent, the org's `defaultProvider` applies.

**Why per-org.** `list_projects` (`cmd/wakil-ctx/main.go:78-91`) currently loads the
global registry and then opens **every registered project's `project.json` across every
org** to filter by `CurrentOrg()`. Listing `umbrella`'s projects reads `initech`'s files off
disk. Per-org, that is one file read, no cross-org disk access, and no filter.

## 5. Two sources of truth for a project's org

Per-org placement means a project's org is now stated twice: by which org directory lists
it, and by its own `project.json`. This case cannot arise today, because the registry is
org-blind, so the rule must be explicit.

**The project's own `project.json` is authoritative. A registry entry filed under the
wrong org is a reported error, not a silent skip.**

`Resolve()` and `SetProjectChecked()` keep their existing `proj.Org != currentOrg` checks
unchanged — those remain the cross-org boundary. What is new is that `list_projects`
surfaces a misfiled entry instead of dropping it. This is strictly better than today,
where a project whose org field is wrong simply vanishes from the listing with no
indication why.

## 6. Session discovery

`sessionsRoot()` is **deleted**, not hardened.

Hardening was the alternative: it currently falls back to `~/.claude/projects` when
`CLAUDE_CONFIG_DIR` is unset (`sessions.go:119-129`), which is harmless only because
`CurrentOrg()` reads the same variable. The moment org comes from `WAKIL_ORG`, the two
can disagree — `WAKIL_ORG=umbrella` with no config dir would operate as `umbrella` while
listing the default account's transcripts. That is not a credential leak (`ListSessions`
still only returns transcripts whose cwd is under the active project's roots, and the
project is still org-checked) but it is a provenance failure: "which provider's history
am I looking at?" stops having an answer.

Deleting it removes the ambient dependency entirely rather than papering over it:

- `ListSessions` enumerates the current org's providers and reads each `claude-code`
  provider's own `<configDir>/projects`. The encode-a-known-root and prefix-match logic
  is unchanged — including the rule that directory names are never decoded back into
  paths, since the `/` → `-` encoding is lossy.
- `SessionMeta` gains `Provider string`.
- `SessionList` gains `UnreadProviders []string` — providers with no session adapter
  (`codex`, `local`) or an unreadable root. `Skipped` keeps its current, precisely
  defined meaning ("could not confirm this transcript is ours"); a whole unread provider
  is a different statement and gets a different field. Same house invariant as
  `Rows.Truncated`, `IssuePage.Truncated` and `RecallOutput.Sources`: carry the
  partiality signal alongside the data.
- `get_session(id)` searches the org's providers, errors naming both if an id is
  ambiguous, and errors if absent. It needs this because it reads the transcript through
  `sessionsRoot()` *after* filtering `ListSessions()` output (`sessions.go:399-410`);
  fixing only the listing would leave it returning a session it then cannot read.

This is the largest piece of work in the change, and it is what makes a rate-limit
handoff inspectable afterwards instead of half the work vanishing behind the wrong
account's history.

## 7. Provider preference — reported, never enforced

A project may name a provider (§4.3). Nothing headless can enforce it: by the time
`wakil-ctx` is running, the provider has already launched it. The direction of control is
provider → servers.

So `get_context` reports three things: the selected provider (project's, else the org's
default), the running provider (`WAKIL_PROVIDER`, or "the launcher did not declare one"),
and whether they match. It never blocks. A binding would fire hardest exactly when the
operator is rate-limited and reaching for the backup account, which is the case this
feature exists to make easy.

In Phase 2 the app makes the two agree by construction and the report becomes a no-op.

**On "switching provider mid-session".** It cannot be a switch. A Claude Code session is
a subprocess bound to one config dir, and its transcript lives inside that config dir;
provider B cannot resume provider A's session, because `--resume` reads B's own
transcript store where A's session does not exist. The achievable thing is a **handoff**:
stop on A, start a fresh session on B seeded with A's context, with the same project,
environment and credentials already active. The work then exists as two sessions, one per
provider — which is exactly why §6 tags sessions with their provider.

## 8. CLI and registration

New subcommands: `wakil org create|list|rm`, `wakil provider add|list|rm`. Removing an
org that still holds providers or projects is refused unless forced; forced removal
deletes the whole `orgs/<org>/` directory, including its active context, and never
touches the Keychain — a credential outliving its org is recoverable, a deleted one is
not.

Every `wakil` subcommand accepts `--org`, overriding `WAKIL_ORG`. A flag is safe here
precisely because a human typing it *is* the launcher (§3.3), and it retires the
`CLAUDE_CONFIG_DIR`-must-be-set gotcha that currently dominates `operator-todo.md`.

`scripts/register-org.sh` becomes `scripts/register-provider.sh`, taking an org and a
provider id. It refuses an unregistered org or provider, passes `-e WAKIL_ORG` and
`-e WAKIL_PROVIDER` to all five servers, and no longer passes `WAKIL_JIRA_BASE`. Its
symlink-resolution warning becomes unnecessary for org identity — the org is now declared,
not derived — but the resolved `configDir` is still what gets recorded and announced.

## 9. Breaking changes — delete, do not migrate

**There is no migration code and no migration of data.** Every trace of the Phase 1
layout is deleted and the new structure is built from nothing.

The reasoning is not only that a one-time convenience path would live in the codebase
permanently. It is that the existing on-disk state is already inconsistent with the code
that would read it, so migrating it would carry that inconsistency forward under a new
name. Measured on this machine before deletion:

- `~/.wakil/active.json` existed under the **pre-split** filename, and it was still being
  read: `ReadActive` falls back to it through `readLegacyActive` (`active.go:120-136`)
  whenever the current org has no file of its own, adopting it only if the project it
  names belongs to the current org. So the machine was running on an upgrade-compatibility
  path, not on the per-org layout Phase 1 nominally shipped. That fallback — plus
  `legacyActiveFile`, `legacyActivePath` and `readLegacyActive` — is deleted by this
  change, because the layout it bridges to is itself replaced. Migrating the file would
  have meant guessing which org it belonged to, which is the exact ambiguity this design
  exists to remove.
- `~/.wakil/projects.json` held one entry, the throwaway `wakil-acceptance` fixture from
  the acceptance run.

`~/.wakil` has been deleted. Nothing in it was worth carrying.

### What the operator does to rebuild

1. **Deregister the old servers**, per org that has them. The existing registrations in
   `~/.claude-initech` and `~/.claude-personal` pass `-e CLAUDE_CONFIG_DIR` and no
   `WAKIL_ORG`, so under the new code every one of them fails at the first tool call.
   They must be removed, not left to be overwritten:
   `claude mcp remove wakil-ctx wakil-db wakil-pm wakil-http wakil-recall` with that org's
   `CLAUDE_CONFIG_DIR` set.
2. `wakil org create` per org, with `--jira-base` where applicable.
3. `wakil provider add` per account. Note that `~/.claude-umbrella` does not exist on this
   machine — `umbrella` was never set up under Phase 1 — so it is created here for the
   first time rather than migrated.
4. `scripts/register-provider.sh` per provider.
5. Register projects, then `set_project` per org.

**No Keychain re-store.** Org strings stay `personal` / `initech` / `umbrella`, so every
`wakil:<org>:<ref>` service name is untouched. This is the one thing deliberately carried
forward, because a credential is the one kind of state the operator cannot regenerate
from a command.

`operator-todo.md` replaces its Phase 1 migration section with the above.

## 10. Charter amendment

`north-star.md` Invariant 4 currently reads:

> An organization is a whole credential boundary. All of an org's credentials — Claude
> subscription, MCP OAuth, adapter auth — live inside its config dir.

This design makes that false by construction. The amendment, dated, splits the two:

- The **organisation** owns its adapter credentials and secrets, in the Keychain under
  `wakil:<org>:<ref>`. Cross-org bleed remains structurally prevented — by the service
  name, by the per-org directory, and by `Resolve()`'s check.
- The **provider** owns its own auth (for `claude-code`, a config dir and OAuth token).
  One org may hold several; one provider may serve several orgs.

Decision 4 ("An organization owns an opaque harness credential bundle") is amended to
attach the bundle to the provider rather than the org. Decision 16's two-axis framing
(harness vs provider) is unchanged and is in fact what this design finally implements.
Invariant 5 is untouched: the active triple stays (org, project, environment) — the
provider is session-scoped, not context-scoped.

## 11. Testing

Per the Phase 1 discipline, which holds unchanged:

- Fixtures in `t.TempDir()` with `HOME` redirected. No test reads or writes the real
  `~/.claude*` or `~/.wakil`. Provider `configDir`s are temp dirs too, so session
  discovery is exercised without touching a real transcript store.
- `security` is faked on `PATH`; no test reaches `SecretSet` or the login keychain.
- Every guard is mutation-tested: break the production code, confirm the right test fails
  for the right reason and quote the message, revert, confirm byte-identical. A test that
  cannot fail is worse than no test — assert the guard **fired**, not merely that the bad
  thing is absent.
- Gate per task: `gofmt -l .` empty, `go vet ./...`, `go test ./... -count=2`, `-race`,
  `-shuffle=on`, `make build`.

Guards that specifically need a firing test: unset `WAKIL_ORG`; unregistered org;
unregistered `WAKIL_PROVIDER`; org id failing `orgFileTokenPattern`; a project filed under
the wrong org (§5); `defaultProvider` naming a missing provider; a `claude-code` provider
whose `configDir` does not exist; `org rm` with dependants; and `get_session` for a
session belonging to a provider other than the running one.

## 12. Answers to the deferred note's open questions

- **Where does the org registry live?** `~/.wakil/orgs/<org>/`, directory per org (§4).
  Projects move in with it; nothing stays global.
- **Does a provider need per-org settings?** Not yet. `kind`, `label` and the launch
  fields are all anything reads today. Model choice and token budget wait for Phase 2,
  where the app that launches a provider defines what it needs.
- **What does `list_sessions` mean with several providers?** Merged, with every session
  tagged by provider and unreadable providers named (§6) — the same grouped-and-honest
  shape `recall` uses for sources.
