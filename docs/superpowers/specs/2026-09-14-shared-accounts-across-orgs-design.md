# One Claude account, several organisations — design

**Status:** binding authority for the sub-phase preceding `2026-09-14-multi-org-window-design.md`.
**Raised by:** the operator, 2026-09-14 — *"we need to be able to use the same provider
across orgs … we might end up consuming our limit and want to switch to another provider
that still has some usage left."*
**Sequenced before the multi-org window** on the operator's instruction, because that
design gives every open organisation its own live Claude session and this machine cannot
currently supply one to two of its three organisations.

---

## 1. The blocker, measured rather than assumed

`AddProvider` refuses a `configDir` already registered to another `(org, provider)` pair
(`internal/wakilcore/provider.go:144-152`). Read off this machine on 2026-09-14:

| org | providers |
|---|---|
| `initech` | `main` → `~/.claude-initech` |
| `personal` | `main` → `~/.claude-personal`, `second` → `~/.claude-umbrella` |
| `umbrella` | **none** |

`umbrella` has no account and **cannot be given one**: the account it should plainly use,
`~/.claude-umbrella`, is already claimed by `personal/second`. Registering it to `umbrella`
today requires first removing it from `personal`, which trades one org's agent for
another's rather than fixing anything.

Two consequences, and the second is the reason this is sequenced first:

- The operator's stated need — move to an account that still has usage left — is
  available only *within* one org. The account with quota is frequently in a different
  org, where it cannot be reached.
- Under the multi-org window design, opening `umbrella` yields a context with its five
  servers, an empty canvas and **no harness session, permanently**. That design's §11.1
  admits an org open with no project as a legitimate transient state for a *fresh* org;
  an org that can never acquire an account is a different thing, and shipping a switcher
  whose most interesting destination is permanently agent-less is not worth doing.

## 2. What the rule actually defends

Not Invariant 4, and not any credential. It defends **plain Claude Code**.

`scripts/register-provider.sh` registers each server with
`claude mcp add --scope user -e WAKIL_ORG=<org> -e WAKIL_PROVIDER=<provider>`, writing
the org *inside* the config dir (that script's lines 14-40 argue why at length: left
ambient, a stale `WAKIL_ORG` produces a silent cross-org credential lookup with no error
anywhere). A `claude` session started against that dir inherits the pinned org and
**cannot override it** — there is no `--org` for a `claude` session. So one config dir
serves exactly one org, for plain Claude Code, and the refusal in `AddProvider` is the
guard that keeps a second registration from overwriting the first's pin.

**Wakil's own sessions never read that pin.** `ClaudeCodeCLIHarness.buildLaunch` passes
`--mcp-config <generated JSON> --strict-mcp-config`
(`app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift:151-153`), which replaces the
config dir's registrations wholesale; `agentMCPConfigJSON(organization:provider:)` supplies
both values per selection and is deliberately rebuilt per provider switch rather than
captured. Wakil's two long-lived clients get theirs from
`AppWiring.childProcessEnvironment`. Nothing Wakil launches consults the pinned value,
which is why a shared config dir is already safe inside Wakil and has been since 2b-vi.

**The unmeasured assumption under all of this, named because it was silent and this is
the feature that leans on it.** `--strict-mcp-config` was measured working once, on
`personal` — the `max` account — and the probe that measured it says in as many words:
*"Not tested on `initech` (`team`) or `umbrella` (`enterprise`), where managed settings could
still constrain it"* (`phase-2a-probe.md` §5, repeated at `phase-2a-acceptance.md`'s
launch-command notes). Charter Decision 5 raises the same warning from the other
direction: team and enterprise plans can impose managed settings that constrain MCP
servers and permission modes, so *develop against `personal`; probe the other two*.
Sharing is exactly what puts those two managed accounts under that flag **in another
org**. If a managed policy overrode `--strict-mcp-config`, a shared session would read
the config dir's pinned servers — the homing org's — and cross the boundary this section
says it cannot cross. Nothing in this design detects that, and no Go test can: the flag
is passed to a real `claude` process. It is therefore the named subject of the acceptance
runbook's check 6, which must be walked on `umbrella` (`enterprise`) as well as on one
other account rather than on `personal` alone. Until that walk, read the paragraph below
as *true on `max`, assumed on `team` and `enterprise`*.

**This is the spec's load-bearing claim, so state it in its strongest form:** sharing an
*agent account* is not sharing an *organisation's credentials*. The Keychain service
scheme stays `wakil:<org>:<ref>`, `writeGate` still judges one org's environment, and the
cross-org project guard still compares `project.json`'s declared org against
`CurrentOrg()`. A Claude account is who pays for the agent's tokens. An org is whose
databases the agent may touch. They were conflated by a registration mechanism, not by a
rule.

## 3. The model — one headless home, many Wakil bindings

- A config dir has at most one **headless home**: the org whose `WAKIL_ORG` is pinned
  inside it. The first registration claims it.
- Any number of *additional* `(org, provider)` records may name the same config dir.
  These are **Wakil-only** bindings: usable from the window, and from the `wakil` CLI
  with `--org`, while a plain `claude` session in that directory still runs as the
  headless home.
- An additional binding is **never implicit**. It requires `--share`.

**The limitation, stated plainly rather than buried:** a shared account's plain-Claude-Code
flow still belongs to exactly one organisation. Only Wakil gets the account in several.
Phase 1's exit criterion — *"from plain Claude Code, 'what's assigned to me on umbrella'"* —
remains true for each dir's headless home and is not extended to the shared bindings. An
operator who needs that answer headlessly for a second org needs a second config dir,
and the refusal message should not pretend otherwise.

## 4. Changes

Five — four in Go and the CLI, one in `scripts/register-provider.sh`. **No Swift.**

**4.1 `Provider` gains one field** (`provider.go:19`):

```go
// Shared records that this binding did NOT claim the config dir's
// headless home — some other org's registration did. It exists so
// findConfigDirOwner can name the org whose WAKIL_ORG is pinned inside
// the directory, which is the only org a plain `claude` session there
// will ever run as.
Shared bool `json:"shared,omitempty"`
```

`omitempty` keeps every existing record byte-identical on rewrite.

**4.2 `AddProvider` takes the flag, and refuses in both directions.**
The matrix is five cases and all five are decided here, because a mode reachable two ways
is how quiet paths start:

| dir's existing owner | `--share` | outcome |
|---|---|---|
| none | no | register, claims the headless home — today's behaviour, unchanged |
| another org | no | **refuse** — today's message, extended to name `--share` and say what it does |
| another org | yes | register with `shared: true`; print which org holds the headless home |
| none | yes | **refuse** — "nothing to share: no other org has registered this config dir. Drop `--share` to register it normally." |
| **the same org** | either | **refuse, always** — `--share` does not reach this case |

**Sharing is across organisations only, never within one.** The existing same-org refusal
is defended by a different argument, and `TestAddProviderRejectsConfigDirClaimedWithinSameOrg`
states it: within one org `WAKIL_ORG` would survive a second registration but
`WAKIL_PROVIDER` would not, so sessions land under the wrong provider. Nothing in this
spec weakens that — and nothing wants to. Two provider ids in one org naming one account
is a duplicate record, not a capability: it buys no second account and no second quota,
which is the entire motivation for the feature. So `--share` is rejected with its own
message when the owner is the org being added to, rather than silently falling through to
the generic refusal.

**4.3 `findConfigDirOwner` learns to skip shared records** (`provider.go:187-204`), and
is exported as `ConfigDirHome(dir) (org, providerID string, err error)`. It returns the
*home* — by construction the record that pinned. Today it returns the first match in org
order, which with sharing would be arbitrary.

It keeps two callers with different needs, so both are spelled out: `AddProvider`'s
collision check wants *any* owner (it must still refuse a same-org duplicate, §4.2's last
row), while the script wants the *home*. One function cannot answer both, so
`findConfigDirOwner` gains a `homeOnly bool` and the exported `ConfigDirHome` passes true.

> **Correction, 2026-09-14, after the branch review — this paragraph was wrong and was
> implemented verbatim.** "Any owner" is not a question `findConfigDirOwner` can answer
> usefully: it returns the FIRST match in `ListOrgs()` sort order, which once sharing
> exists may be a *shared* record in a third org. `AddProvider` then compared that org
> against the org being added to and concluded "different org", so with `zulu` homing a
> dir and `alpha` sharing it, `--share` let **`zulu` register its own config dir a second
> time** — the one row of §4.2's matrix that says *refuse, always*. The same single lookup
> also made the cross-org refusal name `alpha` as the org that "pins `WAKIL_ORG` inside
> the directory" and tell the operator to `wakil provider rm` a record that releases
> nothing.
>
> `AddProvider` asks **two** questions instead, because one call cannot answer both:
> *does THIS org already hold a record naming this dir* (a scan of this org's records
> alone — `findConfigDirInOrg`), and *does another org home it* (`ConfigDirHome`). It then
> decides in order: a record in this org → refuse, `--share` does not rescue it; else
> another org homes it → refuse without `--share`, naming the **home**, accept with it;
> else nobody homes it → refuse `--share` as "nothing to share", otherwise accept and
> become the home. `findConfigDirOwner(dir, false)` survives for exactly one job:
> distinguishing "never registered" from "the homing record was deleted by hand and
> orphaned its sharers", which the last branch reports in its own words.

**4.4 A new CLI verb, `wakil provider home <id>`**, printing the org that homes this
provider's config dir — the provider's own org when it is not shared, the homing org when
it is — on stdout, one line, nothing else, exactly as `wakil provider config-dir` already
does (`cmd/wakil/providercmd.go:174`). The script needs this answer and has no other way
to get it.

**4.5 `scripts/register-provider.sh` refuses to re-pin.** Before any `claude mcp add`, it
asks `wakil provider home` who holds the dir; if that is a different org, it dies naming
that org, rather than silently stealing the pin and breaking the other org's headless
flow. This is the actual enforcement point — 4.2 is bookkeeping and this is the one
command that writes the file the pin lives in.

## 5. What does not change

- **No Swift.** The provider picker lists an org's providers; a shared one is simply a
  provider. Marking shared rows in ⌘P is deliberately not built — it is cosmetic, and the
  picker already names the account, which is the fact the operator is choosing on.
- **No session-list work.** `ListSessions` already filters by the active project's roots
  (`internal/wakilcore/sessions.go:419`) and explicitly does **not** count a confirmed
  non-match toward `skipped` (that field's doc comment, lines 115-140). So two orgs
  sharing one config dir already get correctly-scoped, accurately-annotated session
  lists. This was raised as a concern during design and measured to be a non-issue;
  recorded here so it is not re-raised.
- **No change to `CurrentOrg`, the Keychain scheme, `writeGate`, the production block or
  the cross-org project guard.**
- **No in-app provider registration.** Decision 21 commits to that eventually; this
  sub-phase stays on the CLI, exactly as the multi-org design's §12 does.

## 6. Verification

Go tests:

- All five rows of §4.2's matrix, each asserting the exact refusal text where it refuses —
  including the same-org row under `--share`, which must produce its own message and not
  the generic one.
- `findConfigDirOwner` returns the home and not a shared record, including when the
  shared record sorts first by org name (`alpha` sharing, `zulu` homing — otherwise the
  test passes for the wrong reason).
- A shared record round-trips through the JSON with `shared: true`, and an unshared one
  still writes no `shared` key at all.
- `register-provider.sh` gets a test for the refusal: a dir homed to org A, re-pinned
  from org B, must fail without having run `claude mcp add`.

Added 2026-09-14 by the branch review, each covering a hole the list above left:

- The same-org refusal with **two** records on disk — a home in one org and a sharer in
  another. Every subtest of the matrix above has exactly one, which is why none of them
  saw §4.3's correction-worthy defect.
- The cross-org refusal names the **home** org and provider, and names no sharer.
- `RemoveProvider` refuses to delete a record that homes a config dir other orgs share,
  names them, and still deletes a shared record or an unshared one nothing depends on.
  Without this the removal is a one-way door: `ConfigDirHome` then returns `""` forever
  and no `provider add`, with `--share` or without, can re-home the directory.
- `--share` is refused on `codex` and `local`, and `ConfigDirHome("")` answers nothing —
  the flag's help said "claude-code only" and nothing enforced it, so a shared codex
  record with an empty config dir was matched against every other empty one.

**An acceptance runbook, walked** — `docs/wakil/shared-accounts-acceptance.md`. Three
checks cannot be reached by any test in this repository and are the reason the runbook
exists:

1. A Wakil session in org B, running under an account homed to org A, spawns children
   that see `WAKIL_ORG=B` — verified in the journal and by a query that could only
   succeed against B's database, not from the window's labels alone.
2. A plain `claude` session in that shared directory still runs as A. This is the
   limitation §3 states, and an unwalked limitation is a guess.
3. The ⌘P session list in B shows B's sessions and not A's, though both live under the
   one config dir. §5 argues this is already true; the walk is what establishes it.

This project's most expensive and most repeated finding is that a green suite is the
floor and decides nothing above it — 649 tests were green at every point where 2c-ii was
shipping a defect, and 709 were green through 2c-ii-b's six. Nothing here is exempt.

## 7. Migration — the operator's, not this spec's

A handful of commands give `umbrella` and `initech` the accounts they cannot have today. They
touch real accounts and are **not run by any agent**; they belong in `operator-todo.md`
beside the existing provider-setup section, which now carries six bindings rather than
the three this paragraph first guessed at — every org gaining one to each of the other
two.

**Each binding is two commands, not one.** A Keychain item carries no org, so the service
name is the only place org scoping lives (`wakilcore.ProviderTokenRef`, and
`keychainService`): `wakil provider credentials <id>` resolves the ref under the org it
is called with, and the window bakes its own org into the lookup at construction
(`WakilCLICredentialsLookup`, `WindowSession.swift:141`). So a `initech-main` binding in
`personal` reads `wakil:personal:provider:initech-main`, which does **not** exist merely
because `wakil:initech:provider:main` does — the same token has to be stored again under the
sharing org. This is not a change this design makes; it is a consequence of the scheme
§2 says is untouched, and it went unstated in the first draft, which would have had the
acceptance runbook's check 6 fail at "select the shared provider" for a reason nobody
had predicted.

The assignment of which account homes which org is the operator's call and is not decided
here: the homes are already claimed by history rather than by intent, and re-homing a dir
means re-running `register-provider.sh` for it.

## 8. Open questions this leaves

- **Does a shared account's usage limit want surfacing in the window?** The motivation
  for this work is switching away from an exhausted account, and Wakil currently has no
  idea how much quota an account has left — the operator discovers it by being refused
  mid-turn. Out of scope here, and worth its own question: sharing an account across two
  orgs also shares its limit across them, which makes the invisible budget more visible
  as a problem, not less.
- **Should `provider list` show the headless home?** Probably, once more than one binding
  exists in practice. Not built on speculation.
- **Is `shared` the right name?** It describes the record's relationship to the directory,
  not to the account, and a reader could take it to mean "this account is shared" (true)
  rather than "this record does not own the pin" (what it stores). No better name was
  found; recorded so the next reader knows the ambiguity was seen.
