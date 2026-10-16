# Signing a provider in without ever printing a token — an Orca provider-login probe

**Run:** 2026-09-17 · **Machine:** macOS 26.0 (Darwin 27.0.0), arm64 · **Subject:**
Orca 1.4.204 (`/Applications/Orca.app`, Electron), `claude` CLI 2.1.274 ·
**Probe code:** none. Read-only: the app's `app.asar` was extracted to a scratch
directory and read; the Keychain was queried for *existence* only
(`security find-generic-password` without `-w`, so no secret was read or printed).
Nothing in this repo changed, and no credential of Orca's or Wakil's was written.

---

## 1. What prompted it

Adding a provider to Wakil today is a four-step operator chore that ends in a token on
a terminal (`operator-todo.md` §3):

```
env CLAUDE_CONFIG_DIR=<dir> claude setup-token     # prints the token to paste
wakil secrets set provider:<id> --org <org>        # paste it here
wakil provider add <id> --config-dir <dir>
scripts/register-provider.sh <org> <id> /abs/path/to/bin
```

Two consequences are already logged as debt. The token is **long-lived and never
refreshes**, which is why two of them have been sitting in `operator-todo.md` awaiting
rotation since 2026-09-07 after being pasted into an agent transcript. And because the
ref carries no org (`provider.go`, `ProviderTokenRef`), an account shared across two
orgs means **the same token pasted twice** — a step that is easy to forget and whose
failure is a window that refuses to start.

Orca adds an account with one click: a browser opens, you sign in, the account appears
in the list, and panes switch between accounts with no token anywhere. This probe
answers **how**, and **which parts of it Wakil can take** — including whether any of it
lets Wakil stop handling a long-lived token at all.

## 2. What Orca actually does

The whole flow is `hZi` in `out/main/index.js` (offset ~6,085,527 of the extracted
bundle), reached from the `claudeAccounts:add` IPC handler. In order:

1. **`mkdtemp` a throwaway config dir** — `$TMPDIR/orca-claude-login-XXXXXX`, then
   `realpathSync` it. The sign-in never touches the account's real directory, so a
   failed or cancelled login cannot corrupt an existing account.
2. **Snapshot the currently active credentials** so they can be put back (`ve.a()` —
   `readActiveClaudeKeychainCredentials`).
3. **Spawn `claude auth login --claudeai`**, with `CLAUDE_CONFIG_DIR` *and*
   `CLAUDE_SECURESTORAGE_CONFIG_DIR` both set to the temp dir. Not a PTY — plain
   `spawn` with piped stdio, `stdin` deliberately left open, `detached: true` on POSIX.
   The CLI opens the system browser itself. **Orca never sees the OAuth round trip.**
4. **Watch the output while it runs.** stdout and stderr are accumulated into a 4 KB
   ring and matched against
   `/\baccess_denied\b|authorization (?:request )?(?:was )?denied|…/i`, so a refusal in
   the browser surfaces as *"Claude sign-in was denied"* instead of hanging to timeout.
5. **Cancel is real.** An `AbortController` is exposed to the UI as
   `claudeAccounts:cancelPendingLogin`; on abort it kills the **process group**
   (`process.kill(-pid)`), not the child, because the CLI has children of its own.
6. **`claude auth status --json`** in the same temp dir (`allowFailure: true`) to learn
   who just signed in.
7. **Capture** (`XXi`/`ZXi`): read the credentials JSON, read `oauthAccount` from
   `.claude.json` or `.config.json`, and merge an identity — email, `organizationUuid`,
   `organizationName` — from whichever of the three sources has each field. A capture
   that yields no credentials is a hard error: *"Claude login completed, but no OAuth
   credentials were captured."*
8. **Write into Orca's own store, then restore and clean up** — always, in a `finally`:
   delete the temp dir's Keychain item, put the snapshotted credentials back, `rm -rf`
   the temp dir. The restore failure is re-thrown separately from the login failure, so
   "we broke your existing login" is never swallowed by "the login failed".

Timeouts, all explicit: **login 180 s**, `auth status` 20 s, every `security` call 3 s,
token refresh 10 s.

**The verbatim contract with the CLI is three tokens wide:** `auth login --claudeai`,
`auth status --json`, and `CLAUDE_CONFIG_DIR`. All three exist on the installed CLI
2.1.274, and `auth login` additionally takes `--email <email>` to pre-fill the login
page and `--console` for API-billing accounts.

## 3. Where the credentials end up, and the Keychain naming scheme

On macOS Orca keeps **nothing secret on disk**. Per account it creates
`~/Library/Application Support/orca/claude-accounts/<uuid>/auth/` holding only:

- `oauth-account.json` — the identity (email, org uuid, org name, plan tier, role).
  Observed on this machine; it carries no token.
- `.orca-managed-claude-auth` — an ownership marker whose content is the account id.

The token itself goes to the Keychain under service **`Orca Claude Code Managed
Credentials`**, account = the account uuid. Every read, write and `rm -rf` of the
directory first goes through `assertOwned`: no symlinks, `realpath` must stay inside
the accounts root, the relative path must be exactly `<id>/auth`, and the marker file
must contain that id. A directory it does not own is refused, loudly — *"Managed Claude
auth storage is not owned by Orca."* Directories are `0700`, files `0600`.

To *run* an account, Orca writes those credentials into the item **Claude Code itself
reads**, runs, and deletes it again (`sGi`: write → run → `finally` delete-strict). That
item's name is derived, in `out/main/chunks/keychain-D83P-Fti.js`:

```
service = "Claude Code-credentials"                                  # unscoped
        | "Claude Code-credentials-" + sha256(realpath(configDir).normalize("NFC")).hex[0:8]
account = $USER if it matches /^[a-zA-Z0-9._-]+$/ else "claude-code-user"
```

**This scheme is not Orca's invention, and it is already holding Wakil's providers.**
Computing the hash for this machine's config dirs and testing only for existence:

| config dir | service suffix | item |
|---|---|---|
| `~/.claude` | `5e83572f` | absent (uses the unscoped item) |
| `~/.claude-initech` | `3be3165e` | **present** |
| `~/.claude-umbrella` | `07c4511c` | **present** |
| `~/.claude-personal` | `91d95fe0` | **present** |

So each of Wakil's three providers *already* has a full, refreshable OAuth credential
in the Keychain, under a name Wakil can derive from the `configDir` it already stores.
The pasted `setup-token` is a **second, weaker credential for an account that already
has a better one** — weaker because `ClaudeCodeCLIHarness.swift:116` passes it as
`CLAUDE_CODE_OAUTH_TOKEN`, which never refreshes and must be re-pasted per org.

## 4. Who refreshes the token — Orca does, itself

The one place Orca talks to Anthropic directly is refresh (`ZWi`):

```
POST https://platform.claude.com/v1/oauth/token
grant_type=refresh_token&refresh_token=…&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e
```

That is Claude Code's own public client id, reused. It refreshes when
`now + 300 s >= expiresAt`, with a 10 s timeout, and rewrites `claudeAiOauth`'s
`accessToken`, `expiresAt`, `refreshToken` and `scopes` in place. A failure logs and
returns null rather than throwing — a stale token is a degraded pane, not a dead app.

This is why Orca panes never ask you to log in again, and it is exactly what a
`setup-token` cannot do.

## 5. What Orca does *not* do, which is as useful to know

- **It runs no OAuth client of its own for Claude.** There is no authorize URL in the
  main bundle and no `orca://` callback in the loop — the only deep-link route in the
  whole app is `orca://pair` (48 references), for device pairing. The browser round
  trip belongs entirely to the CLI.
- **It does run a loopback PKCE flow — for its own cloud sign-in**, not for providers
  (`Lpi`): an ephemeral `http://127.0.0.1/auth/callback` server, `code_challenge_method
  S256`, 32-byte `state` and `nonce` compared on return, `access_denied` distinguished
  from other failures, and a small styled "Signed in to Orca" page served back so the
  browser tab ends somewhere deliberate. **That is the pattern to copy only if Wakil
  ever needs an identity of its own.** It is not needed to add a Claude provider.
- **Codex is a separate adapter**, not a generalisation: `runCodexLogin` spawns
  `codex login` against a managed `CODEX_HOME`, with its own storage
  (`codex-pane-accounts.json`, `codex-runtime-home/`). Orca did not try to abstract
  "provider login" across the two.

## 6. What Wakil can take, against the invariants

**Directly transferable, and it is the whole of the seamlessness:**

1. **Temp-dir login, then capture, then restore.** Steps 1–8 of §2 map onto Wakil
   unchanged. Wakil's advantage is that it does not even need the restore dance in the
   common case: it can log in *directly* into the provider's own `configDir`, because
   unlike Orca it is not multiplexing one CLI installation's ambient state — each
   provider already owns its directory.
2. **Read the scoped Keychain item instead of a pasted token** (§3). This is the
   finding with the largest blast radius, and it closes the rotation TODO by deleting
   the thing that needed rotating.
3. **Cancel that kills the process group, a denial regex, and a bounded login
   timeout.** Cheap, and each one is a hang the naive version will have.
4. **Ownership markers before any destructive write.** `.orca-managed-claude-auth` is
   one file and it is what makes `rm -rf` on a config dir defensible.

**What the invariants change:**

- **Invariant 1 (agent-agnostic core).** `claude auth login` is Claude Code's, so the
  login belongs in the harness adapter, next to `ClaudeCodeCLIHarness`, never in
  `wakilcore`. Orca reached the same shape by accident of having two adapters; Wakil
  should reach it deliberately, with `ProviderKindCodex` and `ProviderKindLocal`
  returning "no login adapter" rather than a stub that pretends.
- **Invariant 4 (an org is a credential boundary).** Orca's accounts are machine-global;
  Wakil's are per-org, and `ProviderTokenRef` carries no org. A login therefore has to
  end by asking **which orgs get this provider** and writing the credential ref once per
  org — the "same token pasted twice" step, automated. `ctx_list_machine_providers` and
  `ctx_adopt_provider` already exist for exactly this fan-out and should be the ones
  doing it.
- **Invariant 2 (actions are the only mutation path).** A Settings "Add provider"
  button dispatches the same action the agent would. It joins `ctx_create_org` and
  `ctx_adopt_provider` in `operatorOnlyActions` — an agent must not be able to open a
  browser and mint a credential.
- **Invariant 3 (panes are observable).** The login has a long-running, cancellable,
  human-blocked middle. It needs pane-visible state (`idle | waiting-for-browser |
  capturing | failed`), not a modal that the agent cannot see.

## 7. The risks this probe did *not* retire

- **A live `claude auth login` was never run.** Doing so would have opened a browser and
  rewritten this machine's credentials, which is not a thing to do inside a probe. That
  the scoped items in §3's table exist is strong evidence the CLI writes them when
  `CLAUDE_CONFIG_DIR` is set, but the *write path during a fresh login* is inferred, not
  observed. Orca itself hedges here — `ZXi` falls back from the scoped item, to the
  unscoped item *if its hash changed since before the login*, to `.credentials.json` on
  disk. **Any implementation should copy that three-way fallback rather than trusting
  one location**, and the first task of the phase should be the live run that settles it.
- **Whether the harness can drop `CLAUDE_CODE_OAUTH_TOKEN` entirely** — i.e. whether
  `CLAUDE_CONFIG_DIR` plus a populated scoped Keychain item is sufficient to launch a
  session — is untested. If it is, `ProviderTokenRef` and half of
  `providercredentials.go` become dead code. If it is not, Wakil must refresh the token
  itself the way §4 does, and the `client_id` above is the one to use.
- **Keychain prompts.** Orca's `security` calls carry a 3 s timeout, which implies it
  expects them to be non-interactive — but an item written by one binary and read by
  another can prompt for authorisation. Wakil writing into Claude Code's own item is
  precisely that case.

## 8. Proposed scope

One phase, not one ticket, and it absorbs the Settings-UI work rather than following it:

1. **Live-run probe** of `claude auth login` under a scratch `CLAUDE_CONFIG_DIR`, to
   settle §7's first two unknowns before any spec.
2. **`ProviderLogin` in the harness adapter** — spawn, watch, cancel, capture, bounded,
   with the three-way credential fallback.
3. **Credential source becomes the scoped Keychain item**, with the pasted token kept
   only as a fallback for accounts that have none — and the rotation TODO closed.
4. **`ctx_add_provider` action**, operator-only, dispatching the above, then registering
   the MCP servers (what `register-provider.sh` does today) and fanning the credential
   ref out to the chosen orgs.
5. **A Settings surface** on the plane `OrgPlane` already built: list providers with
   identity and org bindings, "Add provider" → browser → row appears, plus remove and
   re-authenticate. Both drawn from the same action registry the agent dispatches.

The honest ordering note: step 3 is worth more than step 5 and is independent of it. If
the phase has to be cut, cut the UI, not the credential change.

---

## 9. The live run — 2026-09-18

**Run:** 2026-09-18, ~20:00–20:15Z · **Subject:** `claude` CLI **2.1.277** (2.1.274 in §1–§8) ·
**Ticket:** [#92](https://github.com/yehia-khalil/rafiq/issues/92) on map
[#46](https://github.com/yehia-khalil/rafiq/issues/46) · **Account signed in:** the
operator's personal account (`max`, `firstParty`), chosen because re-authenticating it
costs nothing.

§1–§8 were read-only and never ran a login. This section did, under a throwaway
`mktemp -d` config dir, and it settles §7's three unknowns. **Every Keychain item and
credentials file on the machine was snapshotted before and after; the two snapshots are
byte-identical, and the scratch dir and its Keychain item were both deleted.**

### 9.1 The service name is computable, not guessed

`sha256(realpath(configDir))` truncated to 8 hex chars, prefixed `Claude Code-credentials-`,
reproduced §3's table exactly on all four of this machine's config dirs — `5e83572f`,
`3be3165e`, `07c4511c`, `91d95fe0`. The derivation is sound and Wakil can compute it from
the `configDir` it already stores.

Note `realpath` is load-bearing: `/tmp/wakil-login-probe.c83Igf` resolves to
`/private/tmp/wakil-login-probe.c83Igf`, and hashing the un-resolved path yields the wrong
item. Orca `realpath`s for this reason.

### 9.2 Q1 — does a fresh login write the *scoped* item? **Yes, and only that.**

After `claude auth login --claudeai` under `CLAUDE_CONFIG_DIR=/private/tmp/wakil-login-probe.c83Igf`:

| Location | Before | After |
| --- | --- | --- |
| `Claude Code-credentials-76fdce51` (the scratch dir's derived name) | absent | **present**, `acct="operator"`, `cdat`=`mdat`=`20260918200930Z` |
| `<scratch>/.credentials.json` | — | **never created** |
| `Claude Code-credentials-3be3165e` / `-07c4511c` / `-91d95fe0` | `20260914…` | **unchanged** |
| `Claude Code-credentials` (unscoped) | `20260918193047Z` | **unchanged** |
| `~/.claude/.credentials.json` | mtime `1789730370`, 4155 b | **unchanged** |

The scratch dir received `.claude.json`, `backups/`, and after one session `cache/`,
`plugins/`, `projects/`, `sessions/`, `skills/` — **no credential file at all**.

**This is stronger than §4 predicted.** The CLI wrote exactly one place, the derivable
scoped item, and touched nothing else on the machine. **Orca's three-way fallback
(scoped item → unscoped item if its hash changed → `.credentials.json` on disk) is
defensive rather than necessary on 2.1.277** — Wakil's capture step can read one location
and fail loudly if it is empty, instead of inheriting a three-way guess.

### 9.3 Q2 — can the harness drop `CLAUDE_CODE_OAUTH_TOKEN`? **Yes.**

```
env -i HOME=… USER=… PATH=… TERM=dumb CLAUDE_CONFIG_DIR=/private/tmp/wakil-login-probe.c83Igf \
    claude -p "Reply with exactly: ok"
→ ok        (exit 0)
```

A **scrubbed** environment: no `CLAUDE_CODE_OAUTH_TOKEN`, no `ANTHROPIC_API_KEY` (both
verified unset in the parent too). The session ran and returned.

**`CLAUDE_CONFIG_DIR` plus a populated scoped item is sufficient to launch a session.**
So `ProviderTokenRef` (`provider.go:99`), the `provider:<id>` secret, and the
`setup-token` paste step are removable, and `ClaudeCodeCLIHarness.swift:116` stops passing
a token it does not need. This is §7's unknown 2 answered in the direction that deletes
code.

> **The measurement stands; the conclusion drawn from it is SUPERSEDED — see §10.6 and
> Decision 28.** *(Added 2026-09-22 by [#169](https://github.com/yehia-khalil/rafiq/issues/169);
> the contradiction was found by [#100](https://github.com/yehia-khalil/rafiq/issues/100).)*
> A scrubbed launch off the config dir alone **does** work, exactly as recorded above. What
> it does not survive is **time**: §10, written later the same day, measured that a config
> dir's own OAuth credential expires while idle and the CLI cannot refresh it. So
> `ProviderTokenRef` **survives**, the `provider:<id>` secret stays, and the paste step is
> removed by Wakil minting the token itself rather than by deleting the token. Read this
> section as the measurement it is, never as the ruling it proposed.

### 9.4 Q3 — does reading it prompt? **Not via `/usr/bin/security`.**

`security find-generic-password -s <scoped> -a $USER -w` returned **exit 0 in under a
second, no prompt** (secret discarded, never printed). This confirms empirically what
[#93](https://github.com/yehia-khalil/rafiq/issues/93) established from Apple's
documentation and the item's ACL: the item trusts `/usr/bin/security`, because the
creating binary is trusted and the `claude` CLI creates it by shelling out to `security`
too.

**The in-process route was deliberately not run.** Per #93 a linked `SecItemCopyMatching`
presents `Wakil.app` to the ACL, which is not in the trusted list, so it is expected to
raise an authorisation dialog — and a modal that blocks is not worth triggering to confirm
a documented outcome. Recorded as unmeasured rather than measured.

### 9.5 What the flow actually looks like, which §2 could not see

The live argv confirms Claude Code's own public `client_id`
`9d1c250a-e61b-44d9-88ed-5944d1962f5e`, `code_challenge_method=S256`, a `state`, and
scopes `org:create_api_key user:profile user:inference user:sessions:claude_code
user:mcp_servers user:file_upload user:plugins`.

**The redirect is `https://platform.claude.com/oauth/code/callback` — a hosted page, not a
`127.0.0.1` listener.** *(Half wrong — corrected in §11.8: that is the URL the CLI prints,
but the browser is opened on a `localhost` callback and there is a listener behind it.)* The CLI prints `Paste code here if prompted >` and then, in this
run, **completed from the browser round trip alone without anything being written to
stdin**, ending `Login successful.` (exit 0).

So the code paste is a **fallback path, not the happy path**. A GUI wrapper should keep
stdin writable so it *can* supply a code, but a surface that only shows a spinner will
usually work — which is the opposite of what this section's first draft assumed, and it
is why it was run rather than reasoned about.

### 9.6 Identity comes back without a secret

`claude auth status --json` under the scratch dir returned `loggedIn`, `authMethod`,
`apiProvider`, `email`, `orgId`, `orgName`, `subscriptionType`, `configDirectory` — every
field a provider row needs, and no credential. §2's step 5 works as read.

### 9.7 What this run did NOT establish

**Refresh.** The scoped item's `mdat` was unchanged after a session, but the credential was
four minutes old and nowhere near expiry, so nothing can be concluded about whether the CLI
rewrites the item in place. One suggestive observation, not proof: on this machine the
*unscoped* item's `mdat` had moved to the same day while all three *scoped* items sat at
`20260914…`, which is consistent with the CLI rewriting whichever item it is actively using.

**Whether a provider's credential can go stale while idle** therefore remains open, and it
is the one fact [#95](https://github.com/yehia-khalil/rafiq/issues/95) must not assume in
either direction. If it can, Wakil needs §4's refresh call after all; if the CLI always
refreshes on use, Wakil needs nothing.

---

## 10. The credential expires — 2026-09-18, later the same day

**§9.7 left refresh unestablished. It is established now, and it points the other way.**
Measured while resolving [#95](https://github.com/yehia-khalil/rafiq/issues/95), by launching
a tokenless session against each of this machine's real provider config dirs rather than
against the scratch dir.

### 10.1 Two of three provider config dirs are already dead

```
~/.claude       loggedIn: true    (the default dir, used daily — not a provider config dir)
~/.claude-initech   loggedIn: false   "OAuth session expired and could not be refreshed"
~/.claude-personal  loggedIn: false   same
~/.claude-umbrella   loggedIn: true, enterprise  (its `400 Invalid effort level` is unrelated)
```

`~/.claude-initech` was **not touched by §9's run**, so idle expiry is independently evidenced.
`~/.claude-personal` is confounded — §9 signed that same account in under a scratch dir, which
may have rotated its refresh token — and does not need to count.

The dirs that live are the ones in regular use; the dirs that died are the ones sitting
idle since `20260914…`. **An idle provider dies, which is precisely the multi-org case
Wakil exists to serve.**

### 10.2 Refresh does not rescue them, and §4's plan would not have either

The CLI's own message is *"could not be refreshed"* — it **already tried**. So implementing
§4's `POST /v1/oauth/token`, `grant_type=refresh_token` call rescues nothing an idle
provider needs. **Orca has the identical hole**: its refresh runs only while Orca is
running, and an account it has not launched in days reaches the same dead end.

This retires §7's second unknown in the direction opposite to the one §8 assumed.

### 10.3 The pasted `setup-token` still works — it is the durable credential

```
CLAUDE_CONFIG_DIR=~/.claude-initech       + CLAUDE_CODE_OAUTH_TOKEN=<stored>  → ok, exit 0
CLAUDE_CONFIG_DIR=~/.claude-personal  + CLAUDE_CODE_OAUTH_TOKEN=<stored>  → ok, exit 0
```

Both config dirs whose OAuth credential is dead launch normally on the stored token, eleven
days after it was minted. **§1's framing — "a second, weaker credential for an account that
already has a better one" — is backwards.** The `setup-token` credential is the one keeping
those providers alive, and `claude setup-token` remains present on 2.1.277: *"Set up a
long-lived authentication token (requires Claude subscription)."*

### 10.4 Two shared bindings have no credential at all

Found while enumerating: `wakil:umbrella:provider:umbrella-initech` and
`wakil:new-org:provider:initech-main` are **absent**, while `initech:main`, `umbrella:main` and
`acceptance-b:main` are present. Those are two `--share` bindings whose second paste was
never done — exactly the failure `provider.go`'s `ProviderTokenRef` comment warns about —
and both windows refuse to start a session today. Invariant 4's "same token pasted twice"
chore is not hypothetical debt; it has already cost two bindings.

### 10.5 `auth status --json` is a liveness probe

It reports `loggedIn: false` / `authMethod: "none"` for a dead dir and the full identity for
a live one, in under a second, with no session launch and no secret. This is how §10.1 was
measured, and it is the cheapest health signal a provider row can carry.

### 10.6 What #95 ruled on the strength of this

The credential source is the config dir **plus a `setup-token` Wakil mints itself**;
`ProviderTokenRef` survives; Wakil does **not** implement refresh. The phase removes the
human from the credential path, not the token from the design — the rotation debt in
`operator-todo.md` §3 exists because tokens were printed to a terminal and pasted into an
agent transcript, not because tokens exist.

**Still unmeasured:** whether `setup-token` mints silently after a fresh login or needs its
own browser round trip. It takes no flags and minting produces a real long-lived credential,
so it was not run. Filed as [#119](https://github.com/yehia-khalil/rafiq/issues/119).
**Answered in §11 — it needs its own trip**, and §11.5 narrows "long-lived" to 365 days.

---

## 11. `setup-token` needs its own browser trip — 2026-09-20

**Run:** 2026-09-20 · **Subject:** `claude` CLI **2.1.278** (`GIT_SHA 809c9806`, built
2026-09-19), the version installed on this machine · **Ticket:**
[#119](https://github.com/yehia-khalil/rafiq/issues/119) on map
[#46](https://github.com/yehia-khalil/rafiq/issues/46).

§10.6 left one thing unmeasured: whether `claude setup-token`, run under a config dir
that was *just* authenticated, mints from the existing credential or opens a second
browser flow. **It opens a second flow. The answer is two trips.**

### 11.0 The live run has now happened — 2026-09-23, and it changed the answer

**Added after the fact.** Everything below §11.0 was written from a reading of the
CLI's bundled JavaScript, and §11.1 says so plainly. The reading was right about the
shape — `setup-token` does start its own OAuth flow, and the answer is two trips — and
wrong about nothing it claimed. What it could not tell us is the thing that broke the
feature for an operator, because no reading can:

**`claude setup-token` writes nothing at all to a pipe.** Measured 2026-09-23 against
CLI **2.1.280**: zero bytes on stdout and stderr over twelve seconds spawned with
pipes and `/dev/null` on stdin; ~1.5 KB on a pseudo-terminal in the same seconds. It
opens the browser itself, accepts the callback on `http://localhost:<port>/callback`,
and completes the exchange either way — so with pipes **a real one-year credential is
created at Anthropic and the caller never sees the token.** `claude auth login` behaves
the same way, and additionally offers a `Paste code here if prompted >` prompt that a
`/dev/null` stdin can never answer.

**And the token is printed inside a sentence**, not on a line of its own:

> ✓ Long-lived authentication token created successfully! Your OAuth token (valid for
> 1 year): sk-ant-… Store this token securely.

A line-based scan therefore found nothing however well the spawn worked, and every
successful mint was discarded.

**What it cost.** Several real one-year credentials, created and dropped, before the
cause was found. They are revocable only in the operator's Anthropic account. The
instrument §11.1 committed unrun — `scripts/probe/setuptoken/setup-token-probe.sh` —
would not by itself have caught this either: it, too, would have captured a pipe.

The finding is pinned by `TestSetupTokenSpeaksOnlyToATerminal`
(`internal/wakilcore/ptyprobe_test.go`), which runs both spawns and asserts that the
pipe is silent and the terminal is not. It is skipped unless `WAKIL_CLAUDE_BINARY` is
set and stops before anything is approved, so it creates no credential.

Tickets: [#240](https://github.com/yehia-khalil/rafiq/issues/240),
[#244](https://github.com/yehia-khalil/rafiq/issues/244).

### 11.1 Why the decisive half was read rather than run

§9 and §10 were live runs. This section is not, and the reason is the one #119 named:
minting produces a **real credential that does not expire on its own**, so a live run
leaves a live secret behind and owes an explicit revocation. The shipping binary is a Bun
single-file executable whose JS is present in cleartext, so the flow could be read off
**the artefact that actually ships** — not a proxy for it, the same bytes the operator
runs. Two supporting facts *were* measured live, both read-only, both using credentials
that already exist on the machine.

The instrument for the live run is committed unrun at
`scripts/probe/setuptoken/setup-token-probe.sh` — snapshots, scrubbed-environment checks,
teardown and a manual-revocation banner. §11.9 says what it would still buy.

### 11.2 `setup-token` always starts a fresh OAuth flow — the answer

`setupTokenHandler` renders the same `ConsoleOAuthFlow` component the login uses, with
`mode: "setup-token"`. Two lines decide it:

```js
// initial state — no credential is consulted
let [c,O] = g(() => {
  if (N === "setup-token") return { state: "ready_to_start" };
  …
});

// and "ready_to_start" fires the flow on the next tick
C(() => { if (c.state === "ready_to_start" && !Ve.current) { Ve.current = true; … wt … } });
```

`wt` calls `j.startOAuthFlow(…)` unconditionally. **There is no branch anywhere in the
handler or the component that reads the config dir's stored credential, and no path that
short-circuits when one is present.** The only pre-flight checks are a managed-policy
check (`I_e(!0)`) and an "you already have an API key configured" *warning* that is
explicitly suppressed for this mode (`Ue && N !== "setup-token"`).

So a fresh login does not help. **The operator goes to the browser twice for one
provider**, and [#101](https://github.com/yehia-khalil/rafiq/issues/101) has two
human-blocked middles rather than one.

### 11.3 The minted token is printed and stored nowhere

The success branch splits on the same flag, and only one side persists:

```js
if (N === "setup-token")
  O({ state:"success", token:X.accessToken, expiresAt:X.expiresAt ?? undefined });
else {
  await wwe(X, { storageV5:M, credentials:ae });   // ← the only write
  …
}
```

`wwe(…, {credentials})` is the credential-store write — the call that produced the scoped
Keychain item in §9.2. **It is not reached in `setup-token` mode.** The token goes to the
terminal and nowhere else:

```
✓ Long-lived authentication token created successfully!
Your OAuth token (valid for <n>):
<token>
Store this token securely. You won't be able to see it again.
Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>
```

**"You won't be able to see it again" is literally true** — there is no second copy. This
is what makes capture Wakil's job rather than a convenience, and it is the strongest
possible argument for [#96](https://github.com/yehia-khalil/rafiq/issues/96)'s ruling that
minting and storing are **one atomic Go step**: anything that drops the token on the floor
between mint and store has destroyed it, and the only recovery is a third browser trip.

### 11.4 Minting therefore cannot disturb the config dir's credential

#119's observation 5 falls out of §11.3 rather than needing its own measurement: the
`setup-token` path never touches the credentials store, so the config dir's own OAuth
credential and its derived Keychain item are untouched, and `auth status --json` under
that dir is unchanged across a mint. The two credentials are independent by construction.

### 11.5 The minted token is deliberately weaker than the login — one scope, 365 days

The same call that starts the flow sets both:

```js
j.startOAuthFlow(…, {
  loginWithClaudeAi: ee,
  inferenceOnly:  N === "setup-token",          // ← scope
  expiresIn:      N === "setup-token" ? W ?? H3 : undefined,   // ← lifetime
  orgUUID: Ye,
});
```

and the authorize-URL builder turns `inferenceOnly` into the scope list:

```js
let I = w ? w.scopes : h ? [uE] : ogr();        // uE === "user:inference"
```

| | scopes requested |
| --- | --- |
| `claude auth login` | `org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload` (+`user:plugins`) — matches §9.5's observed argv |
| `claude setup-token` | **`user:inference`, and nothing else** |

`H3 = 31536000` seconds — **365 days, not indefinite.** The handler's validator `E()`
ignores its argument and always returns the default, which is why `setup-token` has no
flags: the lifetime is not configurable from the CLI. "Long-lived" in §10.3 means *a
year*, and the tokens keeping `~/.claude-initech` and `~/.claude-personal` alive today are
**dated, not permanent** — they expire around 2026-09-03+365. That is a fact
`operator-todo.md` §3's rotation entry did not have.

The CLI states the consequences of the narrow scope itself, in two places:

> Remote Control requires a full-scope login token. Long-lived tokens (from
> `claude setup-token` or `CLAUDE_CODE_OAUTH_TOKEN`) are limited to inference-only for
> security reasons.

> \[Claude in Chrome] Disabled: OAuth token has no scope accepted by `/api/oauth/validate`
> (needs `user:profile`, `user:office`, or `user:ccr_inference`; env-var and `setup-token`
> sessions default to `user:inference` only)

Inference is what Wakil's sessions need and §10.3 proved they get it, so this does not
threaten the design — but **a Wakil session is by construction a less capable session than
one the bare `claude` CLI opens**, and that belongs in the spec rather than being
discovered later.

### 11.6 Identity comes only from the config-dir path — measured

§9.6 found `auth status --json` returns the whole provider row. That is true of the
**config-dir** credential and not of the token. Measured just now, three ways, in a
scrubbed environment (`env -i`, empty `mktemp -d` config dir where noted):

| what is supplied | `loggedIn` | `authMethod` | `email` / `orgId` / `orgName` / `subscriptionType` |
| --- | --- | --- | --- |
| a live config dir (`~/.claude-umbrella`) | `true` | `claude.ai` | **all four present** |
| a stored minted token, empty config dir | `true` | `oauth_token` | **all four absent** |
| nothing | `false` | `none` | absent |

The token carries no `user:profile` scope (§11.5), so there is no profile to return.

**This is why both trips are load-bearing, and it is a sharper reason than "the ruling
says so".** [#95](https://github.com/yehia-khalil/rafiq/issues/95) ruled the credential
source is *the config dir plus a minted token*; §11.2 shows the mint does not need the
login, so one might have asked whether Wakil could skip straight to minting. It cannot:
**the login trip buys the identity a provider row displays, and the mint trip buys the
durability.** They are two different purchases and neither substitutes for the other.

### 11.7 `auth status --json` does not validate a token — measured, and it narrows §10.5

A deliberately invalid token, in the same scrubbed environment:

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-not-a-real-token-000…   →   "loggedIn": true
```

**On the `oauth_token` path, `loggedIn` reports the presence of an environment variable,
not the health of a credential.** It is only a liveness signal on the `claude.ai` path,
where the CLI holds the credential's own expiry and refresh state — which is what §10.1
actually measured, and the dead dirs still read `loggedIn: false` today.

So §10.5's "`auth status --json` is a liveness probe" and #95's "every provider row
carries liveness from `auth status --json`" both stand, **with a condition that must reach
the spec**: liveness is read against the config dir **with `CLAUDE_CODE_OAUTH_TOKEN`
absent from the environment**. A harness that sets the token and then asks for status gets
an unconditional `true` and loses liveness and identity in the same call. Given
`ClaudeCodeCLIHarness.swift` passes the token when it launches sessions, that is a live
foot-gun and not a theoretical one.

### 11.8 A correction to §9.5: there *is* a localhost listener

§9.5 concluded *"the redirect is `https://platform.claude.com/oauth/code/callback` — a
hosted page, not a `127.0.0.1` listener."* The first half is right about the URL the CLI
**prints**; the second half is wrong. `startOAuthFlow` opens a listener first and builds
**two** authorize URLs from the same `state` and `code_challenge`:

```js
this.authCodeListener = new u;
this.port = await this.authCodeListener.start();
let s = Ukn({...n, isManual:true});    // redirect_uri = MANUAL_REDIRECT_URL (the hosted page)
let p = Ukn({...n, isManual:false});   // redirect_uri = http://localhost:<port>/callback
… await e(s), await ao(p)              // display s, open the browser on p
```

The browser is sent to the **localhost-callback** URL; the hosted-page URL is the one
displayed for copy-paste. `useManualRedirect: !l` then keys off
`authCodeListener.hasPendingResponse()`.

This explains §9.5's observation cleanly — the login "completed from the browser round
trip alone without anything being written to stdin" **because the localhost listener
caught the code**, not because the hosted page did something clever. §9.5's practical
conclusion is unchanged and if anything firmer: the paste is a fallback, a spinner-only
surface will usually work, and stdin should stay writable.

It does, however, **falsify a contrast [#100](https://github.com/yehia-khalil/rafiq/issues/100)
drew**: it distinguished Codex from Claude Code partly on Codex having "a localhost
listener" and Claude Code not. Both have one. The seam #100 earns survives on its other
four grounds (`CODEX_HOME`, a credential *file*, working refresh, no mint), but this
ground is gone.

Authorize endpoint, for the record: `https://claude.com/cai/oauth/authorize`;
manual redirect `https://platform.claude.com/oauth/code/callback`.

### 11.9 What this did NOT establish

**Whether the second browser trip costs a click or costs nothing.** The CLI opens a
browser either way — that is settled and it is what the surface must draw. But if the
operator's browser already holds a claude.ai session, the authorize page may approve with
one click or auto-approve and flash past. The difference does not change the state machine
[#101](https://github.com/yehia-khalil/rafiq/issues/101) has to draw (two waits either
way), only how long the second wait feels. `scripts/probe/setuptoken/setup-token-probe.sh`
measures it, and it costs one real 1-year credential plus a manual revocation to find out
— which is why it has not been run.

**The in-process `SecItem` route** remains unmeasured, as in §9.4, and for the same reason.
