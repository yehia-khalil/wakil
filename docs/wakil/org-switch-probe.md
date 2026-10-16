# Restarting a server under a new org, and what `get_context` will not tell you — an org-switch probe

**Run:** 2026-09-14 · **Machine:** macOS 26.6.2, arm64, Go 1.27.1, Swift 6.3.3 ·
**Probe code:** throwaway — `app/Tests/WakilKitTests/OrgSwitchProbeTests.swift` and a
four-line patch to `MCPClient.start()`, both reverted after this document was written.
The patch is reproduced verbatim in §2 so the implementation can redo it deliberately,
with tests, rather than from memory.

---

## 1. What prompted it

Open question 13 — *how does an operator change organisation without quitting?* — was
raised at the 2c-ii-b walk, when `open app/Wakil.app` failed with *"WAKIL_ORG is not
set"* and the window had no answer. The design agreed with the operator on 2026-09-14
picks **swap in place**: the window survives, and `wakil-ctx` and `wakil-db` are
re-pointed at the new org under the same `MCPClient` instances, so the registry, the
three brokers, the journal and the pane and layout stores are never rebuilt.

That design rests on three things nobody had measured. This project's rule since 2c-i
is that a green suite is the floor and decides nothing above it, and its corollary
since 2c-ii is that the cheap time to find out is before the spec, not at the walk.

1. **Does `MCPClient` survive `stop()` → `start()`?** `performTeardown`'s doc comment
   says a `stop()` after a subsequent `start()` works, which reads like restart was
   anticipated — but it never resets `frameReader`, `stdoutFinished`, `stderrFinished`
   or `transportError`.
2. **Does `wakil-ctx` start with `WAKIL_ORG` unset?** `list_orgs` has to answer the
   operator who has no org — the exact operator open question 13 came from — and it
   can only live on that server if the server runs at all in that state.
3. **What does `ctx_get_context` report for an org with no active project?** The
   window's context bar and its whole per-(org, project) layout key are read from it.

## 2. Question 1 — `MCPClient` does not survive a restart, and four lines fix it

**It does not.** One instance, `start()` → `listTools()` → `stop()` → `start()`, against
the real `wakil-ctx`:

```
✘ probeRestartSameEnvironment: Caught error: .transportClosed(underlying: nil)
```

The failure is in the second `start()`, not in anything after it, and the cause is a
two-step latch:

- `stop()` terminates the child; the stdout drain thread hits EOF and
  `stdoutReachedEOF()` sets `transportError = .transportClosed(underlying: nil)`
  (`MCPClient.swift:469`). Nothing ever clears it.
- `start()` ends by sending `initialize` through `sendRequest`, whose first act is
  `if let transportError { throw transportError }` (`MCPClient.swift:359`).

So a restarted client rejects its own handshake. **This is not a latent bug today** —
nothing in Wakil has ever called `start()` twice on one instance — but it is the first
thing an org switch does, and it would have been found at the walk rather than here.

Four lines at the top of `start()` are sufficient. With this patch both probes pass:

```swift
public func start() async throws {
    transportError = nil
    stdoutFinished = false
    stderrFinished = false
    frameReader = FrameReader()
    ...
```

**Resetting these is safe, and the reason is structural rather than lucky.** `stop()`
awaits `waitForDrainToFinish()`, which does not return until *both* drain threads have
reached EOF and run their actor-isolated callbacks. By the time `stop()` returns there
is no old thread left that could set `transportError` again, so a reset in the
following `start()` cannot be undone by the previous child. A restart that did not wait
for drain would have exactly that race; this one cannot.

Put the reset in `start()` rather than in a `restart` method: it is a statement about
what starting means, and it keeps the only-ever-started-once path byte-identical in
behaviour (all four values are already at these settings on a fresh instance).

**`restart(environment:)` then re-points the server for real.** Two scratch orgs, each
with its own provider registered, one `MCPClient` instance:

| | `list_providers` |
|---|---|
| started as `alpha` | `["alpha-acct"]` |
| after `restart(environment: env("beta"))` | `["beta-acct"]` |

The server answers for the org it was last started with. `environment` has to become a
`var` for this; nothing else in `MCPClient` changes.

## 3. Question 2 — `wakil-ctx` starts happily with no org, and that is what makes `list_orgs` possible

With `WAKIL_ORG` unset and a scratch `HOME`, the server completes the MCP handshake and
advertises its full tool set:

```
INIT:  {"result":{"serverInfo":{"name":"wakil-ctx","version":"0.1.0"}, ...}}
TOOLS: get_context, get_session, list_environments, list_projects, list_providers,
       list_sessions, read_session, record_session_parent, set_environment,
       set_project, set_provider
```

Only the *calls* that need an org fail, and they fail well — `isError: true` carrying
`CurrentOrg`'s own sentence, *"WAKIL_ORG is not set — every Wakil process runs for
exactly one org."*

So `list_orgs` can live on `wakil-ctx` as the design proposed. The condition is the one
the design already states and this measurement now justifies: **it must never call
`CurrentOrg()`.** It reads `~/.wakil/orgs/` through `ListOrgs()`, which is org-independent,
and an operator with no org set must be able to call it. A `list_orgs` that demanded an
org would reproduce the dead end that raised open question 13 inside the very tool built
to end it.

## 4. Question 3 — `get_context` will not tell you which org you are, and the window would lie about it

**This is the finding that changes the design.** In an org with no active project:

```json
{"content":[{"type":"text","text":"no active project — run set_project first"}],
 "structuredContent":{"Environment":"","Org":"","Project":null,"ProjectPath":"","Provider":{"match":false}},
 "isError":true}
```

`Org` is **empty**, though the server knows perfectly well it is running as `alpha` —
the value is sitting in its own environment. The org is not derived from the project and
did not need to be withheld.

Follow that through the window and it is the 2c-ii-b walk's D3 one level up, at the
context bar instead of a pane title:

- `ContextStore.callChecked` throws on `isError: true` (`ContextStore.swift:200`).
- `refreshContext`'s `catch` sets `status` and **returns without touching
  `organization`, `project` or `environment`** (`WindowModel.swift:1400`).

So switching into an org that has no active project — a fresh org, which is the common
case and the one a new operator meets first — would leave the bottom edge reading
`org: initech` while every spawned child runs as `umbrella`, every Keychain lookup resolves
under `umbrella`, and the write gate judges `umbrella`'s environment. D3 was a pane
drawing the wrong table name. This is the window drawing the wrong **credential
boundary**, which is Invariant 4's own subject.

Two changes, and the spec should take both:

1. **Go: `get_context` reports `Org` even when it errors.** The org comes from
   `CurrentOrg()` and is knowable whenever the process started at all; withholding it
   because a *different* resolution step failed is what makes the error unreadable.
   This helps the headless caller too — today `ctx_get_context` on a fresh org tells an
   agent nothing about where it is.
2. **Swift: `setOrganization` sets `organization` from the id it switched to, before
   `refreshContext` runs.** That value is authoritative in a way `get_context`'s answer
   is not: it is the string Wakil itself put into the child environment. `refreshContext`'s
   `catch` should also clear `project` and `environment` rather than keep another org's,
   for the same reason.

Neither is optional. With only the first, a `get_context` that fails for some *other*
reason still leaves a stale org on screen; with only the second, the headless surface
stays mute.

## 5. One thing found by accident — config dirs are unique across orgs, not within one

The first draft of the restart probe registered both scratch providers against the same
`--config-dir` and the second registration was refused:

```
configDir "/private/tmp/…" is already registered to provider "beta-acct" in org "beta"
 — one config dir serves exactly one (org, provider) pair …
```

Worth recording because it cost a wrong diagnosis for a few minutes — the empty
`list_providers` looked like the restart silently failing to re-point, when the fixture
had simply never been created. It also establishes that `provider add` already reads
across every org on the machine, so a cross-org read is not itself a new thing this work
introduces.

> **Note added 2026-09-14, after this probe ran: the finding above is a dated
> measurement, and the thing it measured has since changed.** The refusal quoted here no
> longer exists in that form. `2026-09-14-shared-accounts-across-orgs-design.md` — written
> the same day, and partly on the strength of this section — made the cross-org refusal
> conditional: a config dir still has exactly one **headless home** (the org whose
> `WAKIL_ORG` is pinned inside it, which is what the old rule was actually defending),
> but any number of *other* orgs may now name it as Wakil-only bindings behind an
> explicit `--share`. What stayed absolute is the narrower rule: one org may name one
> config dir **once**, `--share` or not. So the heading's "unique across orgs, not within
> one" has become "homed by one org, nameable by others only with `--share`, and still
> never twice within one org".
>
> The probe's own text is left as it was written. It records what the machine did on the
> day, which is the point of a probe record; the second sentence of the paragraph above —
> that `provider add` reads across every org — is unaffected and is still the mechanism
> the sharing rules are built on.

## 6. What the probe did not settle

- **Nothing here touches `wakil-db`.** The restart was measured against `wakil-ctx`
  only. `wakil-db` is the same `MCPClient` on the same transport, so the mechanism
  carries; what does not carry automatically is what happens to a pane mid-fetch when
  its database client restarts under it. That belongs in the spec's ordering, and in
  the acceptance runbook.
- **The credentials lookup was not exercised.** `WakilCLICredentialsLookup` bakes
  `organization:` in at construction (`WindowSession.swift:141`), and re-pointing it is
  design §3's second item. No measurement was taken.
- **Whether the app should remember its last org across launches is untouched by this
  probe** — it is a ruling about Invariant 4's scope, not a fact to measure, and it is
  still open.
