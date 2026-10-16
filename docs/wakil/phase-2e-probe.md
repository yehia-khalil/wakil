# The path the CLI hashes, and the pane it was drawn for — the 2e probe

**Run:** 2026-09-22 · **Machine:** macOS 26.0 (Darwin 27.0.0), arm64 · **Subject:**
`claude` CLI 2.1.278 · **Probe code:** none. Read-only apart from one scratch
directory under `/private/tmp`: the Keychain was queried for *existence* only
(`security find-generic-password` without `-w`, so no secret was read or printed),
no credential was minted, no login was run, and nothing in this repo changed.

---

## 1. What this rung was pre-registered to settle

[#89](https://github.com/yehia-khalil/rafiq/issues/89) named two things for the Probe
rung, and this document answers both.

1. ***Further Notes*, "One open item the builder must settle first"** — §9.1 of
   `provider-login-probe.md` rules the Keychain service name is
   `sha256(realpath(configDir))` and calls `realpath` **load-bearing**; a read of the
   shipping binary found no symlink resolution anywhere, and the `realpath` §9.1 cites
   is **Orca's**. Shipped code has already picked a side — `AddProvider` stores
   `filepath.EvalSymlinks(abs)` (`provider.go:154`), and `findConfigDirOwner` depends
   on it (`:310`). The spec's instruction: *"Settle it before writing the derivation."*
2. **The database half's layout** — *"what is genuinely open is layout, which is what a
   prototype settles cheaply. The cheapest place to close this is the Probe rung, which
   2e has not yet spent."*

## 2. The `realpath` question — settled, and §9.1 is wrong

### 2.1 The derivation itself reproduces, unchanged, on 2.1.278

`sha256(<path>)` truncated to 8 hex chars, prefixed `Claude Code-credentials-`, against
this machine's four real config dirs:

| Config dir | sha8 | Keychain item |
| --- | --- | --- |
| `~/.claude` | `5e83572f` | present |
| `~/.claude-initech` | `3be3165e` | present |
| `~/.claude-personal` | `91d95fe0` | present |
| `~/.claude-umbrella` | `07c4511c` | present |

The same four §9.1 reported. **None of them contains a symlink component** — every
`realpath` equals the path itself — which is exactly why #89 says they "do not
discriminate". They confirm the hash rule and say nothing about resolution.

### 2.2 The discriminating test: the same directory, reached two ways

`~/.claude-umbrella` is signed in. A symlink was pointed at it and `CLAUDE_CONFIG_DIR`
set to the **symlink**:

```
CLAUDE_CONFIG_DIR=~/.claude-umbrella          → loggedIn: true,  authMethod: "claude.ai"
CLAUDE_CONFIG_DIR=<symlink to the same dir>  → loggedIn: false, authMethod: "none"
```

with

```
sha8(/Users/operator/.claude-umbrella)  = 07c4511c   item PRESENT
sha8(<the symlink's own path>)      = 4961b664   item absent
```

One directory. One credential. Two answers. **The CLI does not resolve symlinks — it
hashes the literal string handed to it in `CLAUDE_CONFIG_DIR`**, finds no item under
that name, and reports a signed-in account as logged out.

`configDirectory` in the JSON echoes the unresolved path too, which is the weaker
check #89 proposed; §2.2's version is stronger because it shows the *credential
lookup* following the unresolved name, not merely the report.

### 2.3 What that costs, and the rule that replaces §9.1

**§9.1's "`realpath` is load-bearing" is false of the CLI.** Its own evidence is a
login run against `/private/tmp/wakil-login-probe.c83Igf` — a path that was *already*
resolved when it was handed over — so the measurement never exercised resolution. The
`realpath` in that reasoning is Orca's, exactly as #89 suspected.

**But "stop resolving" is the wrong correction**, because the stored value has a second
consumer that needs resolution: `findConfigDirOwner` compares config dirs to refuse a
second provider claiming one directory, and its own comment is right — *"comparing a raw
path here would miss a symlink to a claimed directory — which is the same directory"*.

So the rule is neither "resolve" nor "don't":

> **One string.** Whatever Wakil puts in `CLAUDE_CONFIG_DIR` is the string it must hash
> to name the Keychain item. Resolve once, as early as the derivation, and use that one
> value for the spawn, for the record, and for the hash.

Today's launch path already satisfies this by accident: `ClaudeCodeCLIHarness.swift:115`
passes the stored — therefore resolved — `configDir`, so the CLI hashes what Wakil
stored and the two agree. **2e is where it can break**, because the pane derives
`~/.claude-<id>` and spawns a login into it *before any record exists*: if the spawn is
handed the unresolved derivation and `AddProvider` then stores the `EvalSymlinks`'d one,
Go computes a name the login never wrote to. The failure is silent — a fresh, correct
sign-in that reads as logged out, which is precisely §2.2 above.

This is only reachable when `~/.claude-<id>` has a symlinked component — a symlinked
home among them — so it is a narrow case with an unbounded blast radius, and it costs
one line at the derivation to close.

## 3. Two findings this rung did not go looking for

### 3.1 `auth status --json` is not read-only on first contact

Against a **fresh** directory it creates `.claude.json`, `.claude.json.lock` and
`backups/` before answering. Against an **initialised** one it writes nothing: a second
call left `.claude.json`'s mtime and `backups/` untouched.

The pane reads liveness on open and on every read (*The pane*, "caches nothing at all"),
so this is worth stating plainly rather than discovering during the walk. Two
consequences, neither fatal:

- **The first liveness read of a derived-but-never-used dir creates it and its
  scaffolding.** That strengthens rather than weakens Decision 32 — *"Wakil creating it
  is belt-and-braces rather than a requirement"* — and it means a cancelled trip-1 can
  leave a directory behind even where Wakil never spawned a login, which the trip-1
  cancel text already covers.
- **Re-reads are free of writes**, so "read from disk every time" does not put the
  config dir in a write loop.

### 3.2 A dead dir names nobody — reconfirmed on 2.1.278

```
~/.claude-initech       loggedIn: false, authMethod: "none"   (no identity field at all)
~/.claude-personal  loggedIn: false, authMethod: "none"
```

This is §10.5 holding four days and one CLI version later, and it is what the logic
prototype's one ruling rests on — see §4.

## 4. The layout half

Two throwaway prototypes, both on **`prototype/2e-settings-pane`**, neither merged.
Single files: check the branch out and double-click.

**`ProviderSignIn.prototype.html`** — the add-a-provider state model as a pure reducer
over the machine's accounts, the per-`(org, id)` Keychain item and the bindings, driven
by free-play buttons and eight walkthroughs. It earned one ruling:

> **A lapsed sign-in is not "a config dir that still resolves".** *The config dir* says
> the counter reads `1 of 1` for a dir that resolves; §10.5 and §3.2 above say a dead
> dir reports logged-out **with no identity**, so there is nothing to continue as. The
> count derives from liveness: `loggedIn: true` → `1 of 1`, the mint alone; anything
> else → `2 of 2`, **and the first trip is the one that clears the red**.

Drawn the other way, pressing **Re-authenticate** on a red row succeeded and left the
row red, because nothing on a mint-only path writes the sign-in — the only control that
cleared it was *Sign in as someone else*, which is the wrong label for "sign in again as
me". Liveness and re-entry are one signal read twice, so the counter needs no rule of
its own.

**`SettingsPane.prototype.html`** — five stances on the pane: the files, the objects,
the credential spine, a flat menu of categories, and the config tree. **The config tree
won**, and the structs fix its shape rather than taste doing it:

```
Organisation          org.json — three strings
Providers             (organisation, provider id) — ORG-LEVEL, cannot nest
Projects              projects.json → name: {path, provider}
  └ project           project.json — roots, scopes, environments
      └ environment   ← holds databases and an api (config.go:31)
          ├ Databases
          └ API
```

Two things the drawing settled. The nesting is **four deep, not three**: an
`Environment` holds `Databases []Database` and `API *ApiConfig`, while a `Project` holds
only the environments map, so "databases under a project" skips a level that exists. And
**Providers cannot nest at all** — a binding is `(organisation, provider id)`, so it sits
beside the projects and every project in the organisation draws on it. The credential
spine cuts *across* the file tree rather than along it, which is the losing variant C's
argument preserved as an asymmetry inside the winner.

Costs, drawn rather than argued: reaching a DSN is four levels down and needs a
breadcrumb; and the shape invites `+ Add a project` and `+ Add an environment`, neither
of which this phase builds ([#45](https://github.com/yehia-khalil/rafiq/issues/45)), so
both are drawn marked *not this phase*.

## 5. Where this probe governs over the issue

Per `docs/agents/workflow.md`, these are commented onto #89 and its body corrected
before `/to-tickets` is run.

1. **§9.1's `realpath` ruling is withdrawn**, and Decision 31's derivation, which leaned
   on it by name, is re-grounded on §2.3's *one string* rule.
2. **The trip counter derives from liveness**, not from the directory existing, and
   re-authenticating a lapsed row is two trips.
3. **The pane draws a read-only API entry.** *What is editable* rules the API row
   read-only, which presumes a row exists; the artboard-corrections list does not
   mention it. It is a ninth correction.
4. **The layout is the config tree**, four deep, with providers beside the projects.

## 6. What this rung did not settle

- ~~**Whether the gap between the two browser trips is an explicit pause or an automatic
  advance.**~~ **Withdrawn 2026-09-22 — it was already ruled, and this bullet is wrong.**
  [#101](https://github.com/yehia-khalil/rafiq/issues/101) ruled it an **automatic advance**
  on 2026-09-20 — *"two departures, zero questions"* — and its machine has no gap phase at
  all. This rung's prototype re-introduced a pause, flagged it `OPEN`, and this bullet
  copied the flag without re-reading the map. See
  [#203](https://github.com/yehia-khalil/rafiq/issues/203).
- **Whether the CLI *writes* under the unresolved name as well as reading under it.**
  §2.2 measures the read path. The write path is inferred from §9.2, where a login wrote
  exactly the derived name of the string it was handed; settling it directly costs a real
  login and a real credential, which this rung declined to spend.
