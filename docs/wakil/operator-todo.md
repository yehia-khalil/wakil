# Operator TODO — things Claude cannot do for you

Everything here needs your hands. Either it touches real credentials, your real
Claude accounts, or an interactive session — none of which an agent should be
driving. Kept current as work proceeds; **last updated 2026-09-21.**


> **2026-10-22 — register Wakil's two OAuth apps, for 3a-iii's Sign in.** Until then Sign in is
> hidden (SSH keys, tokens and *Use a gh login* work without it).
>
> 1. GitHub → Settings → Developer settings → OAuth Apps → New OAuth App: name `Wakil`, homepage and
>    callback any URL you own, then **Enable Device Flow**. No secret is needed.
> 2. GitLab.com → Preferences → Applications → Add new application: name `Wakil`, uncheck
>    **Confidential**, scopes `read_repository`, `write_repository`, `read_user`.
> 3. Put the two client ids in `internal/wakilcore/gitoauth.go` (`GitHubClientID`,
>    `GitLabClientID`) and rebuild.

> **2026-09-21 — four states of the rail want one look.**
> [#138](https://github.com/yehia-khalil/rafiq/issues/138) is fixed and `WakilApp` has
> no test target, so the promotion itself can only be seen. Open a window with two or
> three panes and check, against `docs/wakil/screens/Rail.dc.html`:
>
> 1. **At rest** the rail is ambient — dim, slightly small, slightly blurred — and the
>    pane names are *not* comfortably readable. That is the point of the next check.
> 2. **Put the pointer on it.** Scale, opacity and blur release together over ~450ms,
>    the names become fully legible, and the row under the pointer lifts. Nothing
>    should snap and nothing should twitch — the first build's hover region moved with
>    the scale it triggered, which fed the animation back into itself. The whole 220pt
>    column promotes, including the empty space below the last row; that is deliberate
>    (see `Rail.swift`), not an overshoot.
> 3. **Run something that names a pane** (a query on a db pane). Its tick turns green
>    and glows, seen from the corner of the eye, without the word "working" appearing
>    anywhere.
> 4. **⌘⏎ to maximize.** The rail fades back to 0.12 — and still promotes to full
>    legibility when you point at it, because while a pane is maximized the rail is the
>    only way back to the others.

> **2026-09-20 — a runbook is waiting to be walked:
> `conversation-layouts-acceptance.md`.** [#142](https://github.com/yehia-khalil/rafiq/issues/142)
> and its three tickets are closed, so pane arrangements are now keyed by
> conversation rather than by project. Ten checks, written and unwalked.
>
> **Copy `~/.wakil/layouts` before you start.** The defect
> [#148](https://github.com/yehia-khalil/rafiq/issues/148) found *destroyed layout
> files*: a switch onto a conversation with no arrangement of its own wrote an empty
> canvas over both that conversation's file and the project's seed, which is what every
> later conversation in that project opens on. It is fixed and pinned by a test; checks
> 3 and 6 are what would catch it coming back, and both read your real files.
>
> **One check cannot be replaced by a test, by construction.** Every automated test in
> this work drives a `session_get` double, so `wakilcore.LineageRootIn` — the resolver
> that decides which conversation an arrangement belongs to — has never once answered a
> live window. Check 4 is the only place it does.

> **2026-09-16 — the MySQL write credential exists.** `wakil.acceptance`'s staging
> `core` database now carries `writeRef: acc-staging-core-write`, and the two
> credentials name two different MySQL users rather than both naming `root`:
>
> | Keychain ref | MySQL user | Grant |
> |---|---|---|
> | `acc-staging-core` | `wakil_read` | `SELECT` on `wakilacc.*` |
> | `acc-staging-core-write` | `wakil_write` | `SELECT, INSERT, UPDATE, DELETE` on `wakilacc.edit_quote` and `wakilacc.edit_bit`, and nothing else |
>
> `SELECT` cannot be dropped from the write grant — MySQL requires it for the `WHERE`
> clause of any `UPDATE` or `DELETE`. The grant is two tables rather than `wakilacc.*`
> because those are the only two 2c-ii-b's checks 12, 14 and 17 touch; widen it if a
> later check needs a third. The read credential was **root** until this date, which
> is why it was rotated at the same time: the read path hardens its own DSN, so
> nothing was broken, but a root read credential meant the fixture could not
> distinguish "Wakil refused this" from "the server would have allowed it".
>
> **Verified at the server, not at the window.** `wakil_write` can `UPDATE edit_quote`,
> is denied `UPDATE` on `customers` and `DROP` on `edit_quote`; `wakil_read` can
> `SELECT` and is denied `UPDATE`. **What is still unestablished is the same thing
> `parked.md` names — the MySQL write path has never been exercised at the window.**
> This removes the reason it could not be; it does not walk checks 12, 14 and 17.

> **2026-09-15 — the acceptance-check backlog is closed.** Every outstanding acceptance
> runbook in the repository was accepted by the operator on that date rather than walked:
> 2a check 8, 2b-i's three standing checks, 2b-iii's six, 2b-v's ten, 2b-vi's dual-drive
> gap, and 2c-ii-b's checks 12, 14 and 17. `parked.md`'s "2026-09-15 acceptance backlog"
> records exactly what each one leaves unestablished. **Nothing in this file blocks a
> phase marker any more.** The sections below are kept because what they describe is
> still true and still unrun — they are now a reference for what to reach for if a
> surface misbehaves, not a queue.
>
> **What genuinely remains on your hands, and is not an acceptance check:** ~~the MySQL
> **write credential** on staging~~ — **done 2026-09-16, see the entry above** — and the
> **paid Apple Developer Program membership** 2b-vii needs for notarised distribution,
> which is now the only one left.

Nothing in this file should ever contain an actual secret value.

---

## MIGRATION — rebuild org and provider state from nothing  ✅ DONE 2026-09-07

*Completed on this machine: three orgs created (`personal`, `initech`, `umbrella`, the
first two with `--jira-base https://initech.atlassian.net`, `umbrella` with its own
site), two providers registered under `personal` (`main` → `~/.claude-personal`,
`work` → `~/.claude-initech`), and `wakil-acceptance` registered as a project. Kept
below as the procedure to follow on a new machine — the steps are unchanged.*

**Two corrections to the steps below, learned by running them.** `wakil org create`
accepts no `--jira-base` silently, and the omission does not surface until the first
Jira call — check `cat ~/.wakil/orgs/<org>/org.json` after Step 2. And do not point
two orgs at one config dir in Step 3: see "One config dir serves one org" in
`phase-1-acceptance.md`.

**2026-09-06.** This is a breaking change and nothing migrates automatically.
Org identity used to be derived from `CLAUDE_CONFIG_DIR` — the Claude account's
own directory. It now comes from `WAKIL_ORG` alone (or the global `--org` flag on
the CLI), declared by whatever launches a server, with no fallback to the old
variable. `~/.wakil` has been deleted in full: the per-org tree it now holds —
`orgs/<org>/org.json`, `orgs/<org>/active.json`, `orgs/<org>/projects.json`,
`orgs/<org>/providers/<id>.json` — is rebuilt from nothing, because the two files
the old flat layout held (an `active.json` with no org of its own, and a
`projects.json` with one throwaway acceptance-run entry) depended on the exact
assumption this change removes; migrating them would only have carried a guess
about "whose org was this?" forward under a new name.

**No Keychain re-store is needed, and nothing there should be touched.** Org
strings did not change — `personal`, `initech`, `umbrella` are the same strings they
always were — so every `wakil:<org>:<ref>` service name your Keychain already
holds is still exactly right. This is the one piece of state deliberately carried
forward: a credential is the one thing you cannot regenerate from a command.

Do these five steps in order, from the repository root, after `make build`.

### Step 1 — deregister the old server registrations

`~/.claude-initech` and `~/.claude-personal` currently hold registrations that pass
`-e CLAUDE_CONFIG_DIR` and no `WAKIL_ORG`. Under the new code every one of them
fails at the first tool call, so they must be removed rather than left for
`register-provider.sh` to overwrite:

```bash
for s in wakil-ctx wakil-db wakil-pm wakil-http wakil-recall; do
  CLAUDE_CONFIG_DIR=~/.claude-initech claude mcp remove "$s" --scope user
done
for s in wakil-ctx wakil-db wakil-pm wakil-http wakil-recall; do
  CLAUDE_CONFIG_DIR=~/.claude-personal claude mcp remove "$s" --scope user
done
```

`~/.claude-umbrella` does not exist — `umbrella` was never registered under Phase 1
— so there is nothing to deregister there. It is created fresh in Step 3.

### Step 2 — create each org

```bash
./bin/wakil org create personal --jira-base https://<site>.atlassian.net
./bin/wakil org create initech      --jira-base https://<site>.atlassian.net
./bin/wakil org create umbrella  --jira-base https://<site>.atlassian.net
```

Omit `--jira-base` for an org with no Jira site. It can be set or changed later
with `wakil org set <org> --jira-base https://<site>.atlassian.net` — see §2's
Jira bullet below for the URL constraints.

### Step 3 — add a provider per account

A `claude-code` provider needs a config dir that already exists, so create
`~/.claude-umbrella` before registering it — `personal` and `initech` already have
theirs:

```bash
mkdir -p ~/.claude-umbrella

./bin/wakil provider add main --kind claude-code --config-dir ~/.claude-personal --org personal
./bin/wakil provider add main --kind claude-code --config-dir ~/.claude-initech      --org initech
./bin/wakil provider add main --kind claude-code --config-dir ~/.claude-umbrella  --org umbrella
```

The provider id (`main` here) is yours to choose — it only has to be unique
within its org. This is also where a second Claude account, or a `codex`/`local`
provider, gets added later. §3 below covers provider setup as a standing
procedure, not just this one-time rebuild.

### Step 4 — register the MCP servers per provider

```bash
export PATH="$PWD/bin:$PATH"   # register-provider.sh shells out to `wakil` and `claude`

scripts/register-provider.sh personal main "$PWD/bin"
scripts/register-provider.sh initech      main "$PWD/bin"
scripts/register-provider.sh umbrella  main "$PWD/bin"
```

See §3 below for exactly what this does and refuses.

### Step 5 — register projects, then set the active one

```bash
./bin/wakil project add booking --path /abs/path/to/booking/.wakil/project.json --org personal
```

Repeat per project, substituting the org its `project.json` declares — `project
add` refuses a mismatch. Registering does not select a project: start a Claude
Code session under the provider you just registered and call the `set_project`
tool (`wakil-ctx`) to make one active. `list_projects` confirms what is
registered; `get_context` confirms what is active.

---

## 1. Keychain round-trip test — ⚠️ ACCEPTED 2026-09-15, NEVER RUN

*Outstanding since Task 5 and closed without being run, with the rest of the backlog.
The command below still works and still proves what it says; nothing now waits on it.*

Writes to your real login keychain and may raise a GUI prompt, so it has been
deliberately excluded from every agent run.

From the repository root:

```bash
WAKIL_KEYCHAIN_TEST=1 go test ./internal/wakilcore/ -run TestKeychainRoundTrip -v
```

Expected: PASS. If macOS prompts, choose **Always Allow** and note that it
prompted — Task 18 step 2 asks for that detail.

The test pins `WAKIL_ORG` itself, so it always creates and deletes the one item
`wakil:wakilselftest:wakil-unit-test-ref` no matter which org's shell you run it
from, and it can never collide with a real credential.

---

## 2. Credentials — I cannot enter or store any of these

I can write the code that reads them and the runbook that tells you where they
go, but storing a secret is yours. Each of these is a separate item:

Every command in this section stores under the org named by `WAKIL_ORG`, or by a
`--org <org>` flag given anywhere on the command line (see the MIGRATION section
above). Neither is optional here: with no org named at all, `wakil secrets set`
and `set-db` refuse outright with "WAKIL_ORG is not set" rather than falling back
to any default — there is no org an unset value silently resolves to.

- **Atlassian API token** — create it at id.atlassian.com (Security → API tokens).
  Then: `wakil secrets set jira:umbrella --org umbrella` and paste
  `email:api_token`. Repeat per org that has a Jira scope. The ref keeps the org
  in it (`jira:<org>`) even though the service name now carries one too, so the
  redundant-looking `wakil:umbrella:jira:umbrella` is expected — renaming the ref
  would have been a second breaking change for no gain.
- **The org's Jira site** — set with `wakil org create <org> --jira-base
  https://<site>.atlassian.net`, or later with `wakil org set <org> --jira-base
  https://<site>.atlassian.net`. Must be absolute https, no
  userinfo/query/fragment/path (the code rejects those). It lives in that org's
  `org.json`, not in an environment variable, so every provider registered under
  the org shares one site with no way for two of them to disagree — the per-org
  problem flagged in Task 14 is solved this way rather than by baking a copy
  into each registration. `WAKIL_JIRA_BASE` still exists, but only as a manual
  override for diagnosing a wrong `org.json`; you do not export it in normal use,
  and `register-provider.sh` never sets it.
- **Database connection URLs** — one entry per connection named in a
  `project.json`. Task 18 wants at least one MySQL, one SQLite and one Mongo
  under `staging`. Either paste a whole DSN:

      wakil secrets set booking-staging-core --org <org>
      # then paste the DSN, Ctrl-D

  or let the CLI compose one, which is the safer route — it percent-escapes the
  password for Mongo (a mongodb:// URI is a URL) and keeps it literal for MySQL
  (that DSN is not one), and it emits `mode=ro` for SQLite and
  `transaction_read_only=1` for MySQL. Mongo gets no marker because none
  exists — see the last bullet in this section:

      wakil secrets set-db booking-staging-core --org <org> \
        --driver mysql --host db.internal --port 3306 --db booking --user reader
      # then paste ONLY the password, Ctrl-D

      wakil secrets set-db booking-staging-mongo --org <org> \
        --driver mongo --host m.internal --port 27017 --db booking --user reader \
        --auth-source admin

      wakil secrets set-db booking-staging-sqlite --org <org> \
        --driver sqlite --db /absolute/path/to/booking.db      # no password

  In every form the value is read from **stdin only**. There is no flag that
  takes a secret on the command line, and there will not be one: an argv token
  lands in your shell history and is readable via `ps -ww`.
- **API auth token for `wakil-http`** — whatever `env.API.authRef` points at.
- **Mongo least-privilege user** — Mongo has NO connection-level read-only mode.
  SQLite gets `mode=ro` and MySQL gets `transaction_read_only=1`, but for Mongo
  the *only* real guarantee is that the user you configure holds just the `read`
  role. This is a deployment requirement, not something the driver can enforce.

  **`--auth-source` is part of that, and it is easy to get wrong.** A MongoDB
  user belongs to the database it was CREATED in, which is not necessarily the
  database it reads. The usual least-privilege recipe creates the reader in
  `admin`:

      use admin
      db.createUser({user: "reader", pwd: passwordPrompt(),
                     roles: [{role: "read", db: "booking"}]})

  A `mongodb://` URI with a database in its path and no `authSource` makes the
  driver authenticate against **that path database** (measured:
  `ApplyURI("mongodb://u:p@h:1/booking").Auth.AuthSource == "booking"`), so the
  reader above would be looked for in `booking`, not found, and the connection
  would fail with an authentication error that says nothing about where the user
  actually lives. `--auth-source admin` writes the option explicitly and the
  question stops depending on a default.

  Omit `--auth-source` only when the user really was created in the database it
  reads. `$external` users (X.509, LDAP, Kerberos) are not supported by
  `set-db` — it always writes a username and password into the URI — so paste
  such a connection whole with `wakil secrets set` instead.

## Write credentials — `writeRef`, and what to grant it

**New 2026-09-09, with Phase 2b-iii.** Until this phase Wakil could not write to a
database at all, so every credential in the section above was a *read* credential and
there was nothing else to store. There is now one more kind, and it is the only kind
where what you grant it is not a detail.

**Wakil now has exactly one mutating action** — `db_run_mutation`, which runs one
`INSERT`, `UPDATE` or `DELETE`. Schema changes of every kind (`CREATE`, `DROP`, `ALTER`,
`TRUNCATE`, `RENAME`, `GRANT`) are refused, multiple statements are refused, and Mongo is
not implemented. It is blocked outright when the active environment is `production`, and
gated everywhere else behind a confirmation you type at the keyboard.

### What to run

**No `writeRef` means that database cannot be mutated — by the agent, by you, by
`--dispatch`, ever.** That is deliberate, and it means every database configured before
2026-09-09 is unmutable until you edit its record on purpose. Two steps per writable
database:

```bash
# 1. Store the credential. Read from stdin only, as everything in this file is.
WAKIL_ORG=personal wakil secrets set 'db:staging:write'
# paste the write DSN, Ctrl-D

# 2. Name it in that database's record in project.json.
#    `wakil project list` prints the path of each project.json.
#
#    {"name":"orders","driver":"mysql","ref":"db:staging","writeRef":"db:staging:write"}
```

`wakil secrets set-db` composes a DSN for you and is the safer route for the read
credential, but note that it emits the read-only markers — `transaction_read_only=1` for
MySQL, `mode=ro` for SQLite. For a *write* credential paste the DSN whole with
`wakil secrets set`, or compose one and strip the marker; the write path
(`hardenMySQLWriteConfig`, `sqliteWriteDSN`) sets `mode=rw` and omits
`transaction_read_only` on its own, and it discards every stored parameter it does not
recognise regardless.

### What to grant it — the part I cannot do for you or check afterwards

**Grant that credential the narrowest permission the statements you actually intend
really need.** Not "a write user". Ideally `INSERT`, `UPDATE`, `DELETE` on the specific
tables, in the specific schema, and nothing else.

**Wakil cannot audit a grant it did not make.** This is stated as a risk in the 2b-iii
spec's §12 rather than mitigated away, because there is no version of it that lives in
code. Everything Wakil enforces is enforced *before* the statement reaches the server:
`AssertSQLMutation` refuses DDL and multiple statements, `MultiStatements` and
`AllowAllFiles` are forced off, and `writeGate` blocks production outright. None of that
is a substitute for what the server itself will permit. The server's grant is the last
line and the only one Wakil has no view of.

So, plainly: **a `writeRef` pointing at a `root` credential works perfectly, and defeats
the entire point.** Every check in `docs/wakil/phase-2b-iii-acceptance.md` will pass
against it. The two-credential design exists so that write authority is *proved to the
server by presenting a credential the server has granted write roles to*, rather than
asserted by Wakil to itself and hoped to be honoured at the far end — and a `root`
`writeRef` converts it back into the boolean it was designed not to be.

**Two more, neither enforced anywhere:**

- **`writeRef` must name a different Keychain entry from `ref`.** Nothing refuses you if
  it does not. Pointing both at one credential silently gives the *read* connection write
  authority at the server, which is the one thing this design exists to prevent — Wakil's
  read path would still refuse to send a write, but a bug anywhere else would no longer be
  contained by the credential.
- **`readOnly` on a database record is gone.** Removed on 2026-09-10 (issue #14) after it
  was found to be worse than inert. It protected nothing and granted nothing, but
  `list_environments` reported an environment "read-only" from it, and `list_databases`
  published it to the agent while hiding `writeRef` — so an agent could read
  `readOnly: true` on a database that a `writeRef` made fully writable. Both tools now ask
  `writeRef`, which is the only field that decides anything. **You do not need to edit any
  `project.json`:** the key is simply ignored on load, and a file that still carries it
  behaves exactly as one that does not.

**For Mongo there is no write story yet at all.** `ConnectWritable` returns *"mongo
mutation is not implemented yet"*, so a `writeRef` on a Mongo database buys you an error
message rather than a capability. The least-privilege note in §2 above still stands as
the *read* requirement and is unchanged by this section.

## 3. Provider setup — per org

**2026-09-06.** A **provider** is one Claude account (or Codex, or a local
model) attached to an org — several may attach to the same org. This is the
standing procedure: Steps 3 and 4 of the MIGRATION section above are exactly
this, run once per org during the rebuild. Follow it again later to add a
second account to an org.

- A config dir per **provider** (`~/.claude-initech`, `~/.claude-personal`,
  `~/.claude-umbrella`), not per org.
- `CLAUDE_CODE_OAUTH_TOKEN` for each, from your subscription — **not** an API key.
- Launch with `env -u ANTHROPIC_API_KEY` so the key is genuinely unset, not empty.
- `wakil provider add <id> --kind claude-code --config-dir <dir> --org <org>`
  registers the account under that org. The config dir must already exist, and must
  not already be claimed by another provider in any org — since 2026-09-07 a
  collision is refused outright, naming the owner and the `provider rm` that releases
  it, because `register-provider.sh` pins `WAKIL_ORG` and `WAKIL_PROVIDER` inside the
  config dir and a second registration would overwrite the first. There is no
  `--force`; reusing a dir means removing the old provider first.
  `wakil provider list --org <org>` confirms it; `wakil provider config-dir <id>
  --org <org>` prints its resolved config dir — used by `register-provider.sh`
  below, not for interactive use.

**Two more steps as of 2b-vi (2026-09-11), and they are not optional any more.** Before
this sub-phase the account a window ran as arrived as four environment variables on the
launch command, so a provider record that named only a config dir was enough. It is not
enough now: `Wakil.app` asks `wakil provider credentials <id>` for everything one `claude`
invocation needs, and a record missing either of these answers is a window that refuses to
start a session and says which command would fix it.

- **`--claude-path` on `wakil provider add`.** The agent binary this provider launches:

      wakil provider add <id> --kind claude-code --config-dir <dir> \
        --claude-path "$(command -v claude)" --org <org>

  This is what `WAKIL_CLAUDE_PATH` used to carry. It is recorded per provider rather than
  per machine on purpose — a provider may one day be a different binary entirely (Codex, a
  local model), and the field is where that difference will live. An existing provider
  registered before 2b-vi has an empty `claudePath`; re-add it, or set the field, before
  expecting a window to launch a session under it.

  **A `--share` binding is the exception and needs no `--claude-path` of its own** (fixed
  2026-09-14, `shared-accounts-acceptance.md` D2). It names a config dir another org homes,
  so it inherits that record's binary — same account, same machine, same `claude`. Passing
  the flag anyway still wins. The inheritance is resolved on every read rather than copied
  into the record, so moving the binary means editing the homing record alone; if that
  record has no `claudePath` either, `provider credentials` refuses and names it.

- **`wakil secrets set provider:<id> --org <org>` for the token.** The ref is *derived*
  from the provider id — `wakilcore.ProviderTokenRef` returns `provider:<id>` and nothing
  writes it down in the record, so there is no second string that can disagree with the
  id — and `secrets.go` scopes it into the Keychain service `wakil:<org>:provider:<id>`.
  The org is not optional here for the reason §2 already gives: a Keychain item carries no
  org of its own, so the service name is the only place org scoping can live, and there is
  deliberately no fallback to an older unscoped name. Paste the value from
  `claude setup-token` run against that provider's config dir:

      env CLAUDE_CONFIG_DIR=<dir> claude setup-token     # prints the token to paste
      wakil secrets set provider:<id> --org <org>        # paste it here

  `wakil provider credentials <id>` is the only verb that ever prints it back, and it is
  deliberately not registered as an MCP tool — an agent that could read the token could
  launch sessions outside the write gate.

**`~/.claude-tokens.zsh` is superseded — empty it rather than leaving it.** It existed so
a launch command could export `CLAUDE_CODE_OAUTH_TOKEN` for the window; nothing reads that
variable out of Wakil's own environment any more, and the file is now a second copy of a
secret whose real home is the Keychain. Two copies of a credential is not redundancy, it
is a second thing to rotate and a second thing to forget — and the one in a dotfile is the
one that gets read by anything that can read your home directory. Once each provider's
token is in the Keychain and a window starts a session under it, blank the file (keep it
if some other tool sources it, but leave no token in it).

**This does not close the rotation item below** (the "Two things left over from the run"
list). Those two tokens were pasted into an agent transcript on 2026-09-07 and that
transcript is still on disk; moving a token into the Keychain changes where Wakil reads
it from, not whether it was exposed. They still need regenerating with `claude setup-token`.

### Registering the MCP servers — one command per (org, provider)

Build first (`make build` writes all six binaries into `bin/`), then run this
once per provider. It writes into that provider's Claude configuration, so it is
yours to run — no agent has run it or will:

```bash
make build
export PATH="$PWD/bin:$PATH"

scripts/register-provider.sh <org> <provider-id> "$PWD/bin"
```

Both `<org>` and `<provider-id>` must already be registered (`wakil org create`,
`wakil provider add`) — the script checks `wakil org list` and `wakil provider
list --org <org>` before touching anything and refuses, naming the exact command
to run, if either is missing.

What it does, and what it refuses to do:

- Registers the five MCP servers (`wakil-ctx`, `wakil-db`, `wakil-pm`,
  `wakil-http`, `wakil-recall`) with `--scope user`, so they belong to the
  provider's own account rather than to whatever directory you ran the command
  from. The `wakil` CLI itself is deliberately **not** registered — it is your
  tool, not Claude's.
- Passes `-e WAKIL_ORG=<org>` and `-e WAKIL_PROVIDER=<provider-id>` to every one
  of them. Org identity is now declared, not derived — `wakilcore.CurrentOrg`
  reads `WAKIL_ORG` and nothing else — so pinning it at registration is what
  stops a server inheriting a stale or absent value and reading another org's
  credential silently.
- Does **not** pass `WAKIL_JIRA_BASE` to anything. The Jira site now lives in
  the org's own `org.json` (`wakil org create|set --jira-base`, §2 below), read
  fresh by every provider of that org, so an org cannot end up with two
  registrations quietly disagreeing about which Jira site they point at.
- Refuses to do anything unless `claude` and `wakil` are on `PATH`, the bin
  directory holds all five binaries present and executable, the org is
  registered, the provider is registered under that org, and the provider's
  recorded config dir still exists. If any `claude mcp add` fails it prints
  Claude's own error, names the servers that failed, and exits non-zero — it
  never claims success it did not have.
- Re-running it for the same provider is the normal way to change something (a
  new bin path after moving the repo, for instance): it removes each server,
  best-effort, before re-adding it, so a re-run cannot abort on "already
  registered" and leave the provider half-wired.

## 4. Task 18 — the acceptance run  ✅ DONE 2026-09-07

The plan states it: *"This task has no unit test — it is the spec's §8 acceptance
run, executed by the operator and recorded."*

It was run on 2026-09-05 and all seven exit criteria passed — but against the
model this branch replaced, before org identity moved to `WAKIL_ORG` and before
providers became their own axis. `docs/wakil/phase-1-acceptance.md` has been
rewritten for the current model: its setup steps are new, the seven criteria are
unchanged, and a table at the top says which of them the decoupling actually
moved (criterion 6, session discovery, most of all — the function it exercised
was deleted). The 2026-09-05 results are kept alongside, dated, rather than
overwritten.

What I have done: built the binaries and run the full unit suite (9 packages
green, also under `-race`; `go vet` and `gofmt` clean), and recorded that in
Step 1 of the runbook.

**Done.** Re-run completed 2026-09-07 by the operator. All seven exit criteria PASS
against the org/provider model; results are recorded criterion by criterion, dated,
in `docs/wakil/phase-1-acceptance.md` alongside the 2026-09-05 ones.

Summary of what the re-run established, and what it cost:

- `make test-live` green with zero skips; `TestKeychainRoundTrip` PASS, no macOS
  prompt. (§1 above is therefore also done.)
- Criterion 6, the one carrying real uncertainty, is the strongest result: two
  Claude accounts registered as providers `main` and `work` under one org, and a
  single `list_sessions` returned 9 sessions correctly tagged across both.
- Criterion 7 passes with two independent mechanisms now: per-org registries make a
  foreign project invisible, and `Resolve()`'s re-check still refuses a misfiled one
  without writing anything.
- Four setup traps cost real time and are written up in the runbook so they do not
  recur: `wakil org create` without `--jira-base` fails silently until the first
  Jira call; `make test-live` overwrites the MySQL fixture; a session launched with
  plain `claude` or exited without sending a prompt writes no transcript at all; and
  `env VAR=~/path` does not expand the tilde in zsh, which silently creates a config
  dir named `~`.
- One structural limitation found, not a defect: **one config dir serves one org.**
  See the section of that name in `phase-1-acceptance.md`, and Invariant 4's
  2026-09-07 qualification in `north-star.md`. Nothing on this list is blocked by it.

Two things left over from the run, both yours:

- **Rotate the two `CLAUDE_CODE_OAUTH_TOKEN` values.** They were pasted into an
  agent conversation on 2026-09-07 and are in that transcript on disk. Regenerate
  with `claude setup-token` per config dir. **Still open as of 2026-09-11**, and 2b-vi
  did not close it: that sub-phase moved where Wakil *reads* the token from (the
  Keychain, per §3's new steps) and it cannot un-expose a value already written into a
  transcript. Where the new value goes has changed, though — `wakil secrets set
  provider:<id> --org <org>` per provider, not `~/.claude-tokens.zsh`, which §3 now says
  to empty rather than keep as a second source of truth.
- **Check the subscription state.** Every session banner during the run read
  *"Claude API"* / *"API Usage Billing"* rather than *"Claude Max"*, on both
  accounts. Charter Decision 5 says Claude access is subscription-only. Run `/status`
  in each and confirm before Phase 2 assumes a subscription.

  **RESOLVED 2026-09-07.** `claude auth status --json` reports auth state
  non-interactively, per config dir, printing no secrets — so this never needed an
  interactive `/status` at all:

      env CLAUDE_CONFIG_DIR=~/.claude-personal claude auth status --json

  | Config dir | Account | subscriptionType |
  |---|---|---|
  | `~/.claude-personal` | operator@example.com | `max` |
  | `~/.claude-initech` | operator@example.com (initech) | `team` |
  | `~/.claude-umbrella` | operator@example.com (umbrella.co) | `enterprise` |

  All three are `authMethod: "claude.ai"` with `apiProvider: "firstParty"`, and
  `ANTHROPIC_API_KEY` appears in no shell profile on this machine. **No account is on
  API billing, so Charter Decision 5 holds** and the "Claude API" / "API Usage
  Billing" banners seen during the acceptance run were not evidence of a fallback.

  Two things this surfaced, both carried forward rather than closed here:

  - **initech is `team` and umbrella is `enterprise`.** Managed settings on those plans can
    constrain MCP servers and permission modes — exactly what Phase 2a's
    `ClaudeCodeCLIHarness` depends on (`--mcp-config`, `--strict-mcp-config`,
    `--permission-prompt-tool`). Phase 2a's first task probes this rather than
    assuming it.
  - **The default `~/.claude` dir is broken and unused:** `auth status` reports
    `team` with a null email, and `.claude.json` is missing with a backup sitting in
    `~/.claude/backups/`. Nothing in Wakil points at it — every provider names its own
    config dir — so this is cosmetic. Restore it from the backup or ignore it.

## 5. Optional, and only you can trigger it

- `/code-review ultra` — a multi-agent cloud review of the branch. It is
  user-triggered and billed; I cannot launch it. Worth considering before merge
  given how much security-sensitive code is on this branch.

## 6. At the end

**Phase 1 is done.** The code is on `main` (`594202c`, `1110e57`, `52d42d8`) and the
acceptance re-run in §4 passed all seven exit criteria on 2026-09-07 against the model
that actually ships — so the claim that it works end to end now rests on a run of the
current code, not of its predecessor.

Still open, in rough order:

1. Rotate the two OAuth tokens, and confirm the subscription state — both in §4.
2. ~~Decide what to do about "one config dir serves one org".~~ **DONE 2026-09-07** —
   candidate fix 1 is implemented: `wakil provider add` now refuses a config dir any
   provider in any org already claims, and names the owner plus the `provider rm` that
   releases it. There is no `--force`. **One thing for you:** the guard is add-time
   only, so run `wakil provider list --org <org>` for each of `personal`, `initech` and
   `umbrella` once and confirm no two rows share a `configDir` — `~/.claude-initech` was
   flipped between orgs during the acceptance run, and a collision created before the
   guard would still be sitting there. Details in `phase-1-acceptance.md`.
3. **A config-dir collision exists right now, and it is live.** Audited 2026-09-07 by
   reading `~/.wakil/orgs/*/providers/*.json`:

   | provider | configDir |
   |---|---|
   | `initech/main` | `~/.claude-initech` |
   | `personal/main` | `~/.claude-personal` |
   | **`personal/work`** | **`~/.claude-initech`** ← same dir as `initech/main` |

   `initech/main` and `personal/work` both claim `~/.claude-initech`. This is exactly the
   pre-existing collision the add-time guard cannot catch, created while `~/.claude-initech`
   was flipped between orgs during the Phase 1 acceptance run.

   **It is not latent — it has already taken effect.** The registrations inside that
   config dir currently read:

       CLAUDE_CONFIG_DIR=~/.claude-initech claude mcp get wakil-ctx
       → WAKIL_ORG=personal
         WAKIL_PROVIDER=work

   So `personal/work` overwrote `initech/main`. **Launching Claude Code with
   `CLAUDE_CONFIG_DIR=~/.claude-initech` expecting org `initech` actually operates as org
   `personal`** — the silent cross-org failure Invariant 4's guard was added to prevent,
   sitting in your live configuration.

   **Your call, because it depends on what you meant.** Two options:

   - If `~/.claude-initech` is the Initech Labs account and `personal/work` was a mistake:
     `./bin/wakil provider rm work --org personal`, then re-run
     `scripts/register-provider.sh initech main "$PWD/bin"` to restore the initech pinning.
   - If you genuinely want that account under `personal` (it is the account the Phase 1
     acceptance run used as `personal`'s second provider, so this may be deliberate):
     `./bin/wakil provider rm main --org initech`, and give `initech` its own config dir.

   Either way, re-run the audit afterwards and confirm no two rows share a `configDir`.
   I have deliberately not run either command — both destroy a registration, and which
   one is right depends on your intent.

4. `umbrella` has an org and a Jira base but no provider and no project. Add them
   when there is work there: §3's procedure, unchanged.
5. Phase 2 now has a spec and a running implementation — see
   `docs/superpowers/specs/2026-09-07-phase-2a-spine-design.md` and
   `docs/superpowers/plans/2026-09-07-phase-2a-spine.md`. Charter open question 5 is
   closed (start fresh, resume as a visible action). Question 10 (default STT engine)
   remains open and blocks sub-phase 2d only.

6. **Rotate the two `CLAUDE_CODE_OAUTH_TOKEN` values** (still owed — see the item above;
   as of 2b-vi the replacement goes into the Keychain with `wakil secrets set
   provider:<id> --org <org>`), **then run Phase 2a's Task 1.** The
   live probe is the last thing blocking sub-phase 2a: it records the `claude` CLI's
   stream-json event shapes as test fixtures and answers whether
   `--permission-prompt-tool` covers MCP tool calls. Tasks 6 and 11 of the plan both
   consume what it records. Command and expected output are in the plan's Task 1.

---

## Phase 2b toolchain — ✅ DONE 2026-09-08, but read this on a new machine

The 2a spec said *"install Xcode before 2b, not before 2a."* That turned out to be
necessary and **not sufficient**, and the gap is silent enough to be worth writing down.

Xcode 26 ships the Metal compiler as a separately downloadable component. With Xcode
installed and selected, `xcrun -f metal` resolves and looks fine — and compiling
anything then fails with `cannot execute tool 'metal' due to missing Metal Toolchain`.
So a machine can pass every check you would think to run and still be unable to build
the Core.

Both steps, in order:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain          # 688 MB
```

Verify with an actual compile, not with `xcrun -f`:

```bash
printf '#include <metal_stdlib>\nusing namespace metal;\nfragment float4 f() { return float4(1); }\n' > /tmp/t.metal
xcrun metal -o /tmp/t.metallib /tmp/t.metal && echo OK && rm -f /tmp/t.metal /tmp/t.metallib
```

`xcrun -f metallib` failing is expected and is not a second missing component — recent
toolchains fold linking into the `metal` driver.

**Done on this machine on 2026-09-08**, verified by the compile above. Recorded because
`make app-build` acquires a hard dependency on this from 2b-ii onward
(`docs/wakil/phase-2b-probe.md` §1–2), and because nothing in the build will tell you
which of the two steps you missed.

**As of 2b-ii this is no longer advisory.** `make app-build` depends on `make shaders`,
which runs `xcrun metal`. A machine without the Metal Toolchain component cannot build
Wakil at all — the failure names the fix, but only after the download has been attempted.

**One thing I cannot do for you: verify 120fps.** This machine is a MacBook Air M3 with
a 60 Hz built-in display and a 60 Hz external, so `NSScreen.maximumFramesPerSecond`
reports 60 and the north-star's *"120fps shell on ProMotion"* cannot be observed here at
all. The 2b acceptance documents record GPU and CPU cost against the 8.33 ms frame
budget instead, and say plainly that the target itself went untested. If you ever run
Wakil on ProMotion hardware, that is the moment to check it.

---

## Phase 2b-v — walk the acceptance runbook  ⚠️ CLOSED 2026-09-10, RE-CLOSED 2026-09-15, NEVER WALKED

**You marked 2b-v met on 2026-09-10 without running any of this, and on 2026-09-15 you
accepted it for good.** The section is kept below unchanged, because nothing in it became
untrue — the ten checks are still unwalked, still need a running `Wakil.app`, a real
`claude` binary and a live agent turn, and are still the only things that would establish
what the sub-phase is for. It is not a debt any more; it is a **reference for what was
never established**, which is where to look first if session resume misbehaves. The same
applies to 2b-iii's six checks and 2b-i's three.

If you ever come back to one item in this whole file, make it **check 10** — the reason
is in the paragraph below, and it is the only check no script could ever have run.

---


**New 2026-09-10.** Session resume's value is a set of human judgements (does a rebuilt
thread read as the same conversation continued, does the seam read as a seam rather than
an error) that no test in the suite can make on your behalf. The sub-phase was marked met
the same day without any of them being made. `docs/wakil/phase-2b-v-acceptance.md` has ten
standing checks, every one marked **ACCEPTED — not walked**. Only you can run them — each needs a
running `Wakil.app`, a real `claude` binary, and a live agent turn, all three of which
the automated suite is forbidden to touch.

**One of the ten needs something the other nine do not: a second, independent process.**
Check 10 asks whether resuming a session that is open in a terminal at the same time
leaves both proceeding and the two transcripts separate — the exact scenario
`session-resume-probe.md` §9 measured going wrong under continue-in-place (two writers
scrambling one transcript with no error from the CLI), which is why every resume is a
fork instead. That is not something a script driving `Wakil.app` alone can confirm:
someone has to actually have a `claude` session open by hand in a terminal, resume that
same session from ⌘P while it stays open, and watch both. I cannot open a second
interactive terminal session and type into it while also driving the app — confirm this
one specifically, not just walk past it because the other nine passed.

**No new credential is needed.** Every check in the runbook resumes a session under a
provider already registered on this machine (§3 above) — the same `CLAUDE_CODE_OAUTH_TOKEN`
already sitting in your Keychain, read the same way 2a's launch command has always read
it. Check 8 (the provider refusal) needs a *second* registered provider under the same
org, not a new kind of credential; if only one provider is registered under the org you
walk this against, register a second the normal way (§3) before starting, or the check
has nothing to refuse.

---

## Not blocking, for the record

- Several MCP servers in this session need authorization before their tools work
  (claude.ai connectors via connector settings; others via `claude mcp` or `/mcp`
  in an interactive session). None of it is needed for Wakil.
- Docker is present and I have been starting/removing throwaway containers
  myself, so that is not on your list.

---

## Shared accounts — give every org the accounts it does not itself home

**This section supersedes an earlier draft of itself.** A version of this task was
written this morning against a `personal/second` provider sharing `~/.claude-umbrella`
and a choice of whether to re-home that directory to `umbrella`. Both no longer exist:
you deleted all three orgs and rebuilt them since. Read the table below, not any memory
of that draft.

**As of 2026-09-14 this machine reads:**

| org | provider | config dir | homes it? |
|---|---|---|---|
| `personal` | `main` | `~/.claude-personal` | yes |
| `initech` | `main` | `~/.claude-initech` | yes |
| `umbrella` | `main` | `~/.claude-umbrella` | yes |

All three orgs are registered, all five MCP servers are registered per account (the
normal §3 procedure, already run for each), and `wakil provider credentials main --org
<each>` resolves for all three. `personal` carries two projects and no `jiraBase`; `initech`
and `umbrella` each have one. There is no `second` provider, or any provider named
anything but `main`, anywhere on this machine.

**There is no re-homing decision to make and no Option A/B to choose between.** Every
org already homes its own account by intent, not by history — the situation the earlier
draft agonised over does not exist any more. What Tasks 1–4 buy on top of this state is
purely **cross-registration**: each org gaining Wakil-only bindings to the *other two*
accounts, so that an account which has hit its usage limit in the middle of a session
can be swapped for one that still has quota left, without leaving the org you are
working in. That is the whole motivation the design document opens with, and this
machine's state now lets it be delivered directly rather than through a re-homing step.

**`main` is already taken as an id in every org.** A shared binding needs its own id
distinct from `main` within the org it is being added to — `AddProvider` refuses a
duplicate id exactly as it refuses a duplicate config dir, and the two refusals are
unrelated to each other. The commands below use `<home-org>-main` as that id — legible,
and impossible to collide with `main` itself.

**A shared binding must NEVER be followed by `scripts/register-provider.sh`.** Task 4
makes the script refuse exactly this on purpose — it asks `wakil provider home` who
pins the directory, and dies naming that org rather than silently overwriting its
`WAKIL_ORG` pin. There is also no reason to run it: Wakil's own sessions never read the
pin (`ClaudeCodeCLIHarness.buildLaunch` passes `--mcp-config` and
`--strict-mcp-config`, replacing the config dir's registrations wholesale for every
launch), so a shared account needs no MCP registration of its own to be usable from
inside Wakil. Registration is only ever for the org that homes the directory.

**A SHARED BINDING NEEDS ITS OWN COPY OF THE TOKEN. This is two commands per binding,
not one, and the second is the one nothing tells you about.** A Keychain item carries no
org of its own, so the service name is the only place org scoping can live (§2, and
§3's provider-token bullet above): `wakil provider credentials <id>` resolves
`wakilcore.ProviderTokenRef(id)` under **the org it is called with**, and the window
bakes its own org into that lookup at construction (`WakilCLICredentialsLookup`,
`WindowSession.swift`). So `initech-main` registered under `personal` is read as
`wakil:personal:provider:initech-main` — an item that does **not** exist merely because
`wakil:initech:provider:main` does. Register the share without storing the token and the
binding appears in ⌘P, is selectable, and then refuses to start a session: the account
is shared, the credential is not.

It is the same token, pasted a second time under a second org. Print it once per account
with `claude setup-token` against that account's config dir (§3's procedure), or read
back the copy you already stored with `wakil provider credentials main --org <home-org>`
— that verb exists precisely so nothing else has to touch the Keychain.

Nothing below is run by an agent. Every command touches your real accounts.

```sh
# personal gains initech's account
wakil provider add initech-main --kind claude-code --config-dir ~/.claude-initech --share --org personal
wakil secrets set provider:initech-main --org personal        # paste initech's token

# personal gains umbrella's account
wakil provider add umbrella-main --kind claude-code --config-dir ~/.claude-umbrella --share --org personal
wakil secrets set provider:umbrella-main --org personal    # paste umbrella's token

# initech gains personal's account
wakil provider add personal-main --kind claude-code --config-dir ~/.claude-personal --share --org initech
wakil secrets set provider:personal-main --org initech        # paste personal's token

# initech gains umbrella's account
wakil provider add umbrella-main --kind claude-code --config-dir ~/.claude-umbrella --share --org initech
wakil secrets set provider:umbrella-main --org initech         # paste umbrella's token

# umbrella gains personal's account
wakil provider add personal-main --kind claude-code --config-dir ~/.claude-personal --share --org umbrella
wakil secrets set provider:personal-main --org umbrella    # paste personal's token

# umbrella gains initech's account
wakil provider add initech-main --kind claude-code --config-dir ~/.claude-initech --share --org umbrella
wakil secrets set provider:initech-main --org umbrella         # paste initech's token
```

Six bindings, not three — every org gains a binding to each of the other two, not just
one direction — and twelve commands, because each binding is an `add` and a `secrets
set`. Skip any pair you genuinely do not want; nothing above depends on the others
having run. Do not skip a `secrets set` for a binding you do keep: an `add` without it
is the failure described above, and it surfaces at the window rather than here.

**Check after running any of these:** `wakil provider list --org <org>` now names the
shared account beside `main`; `wakil provider home <shared-id> --org <org>` prints
the **home** org — `initech`, `personal` or `umbrella` as appropriate — never the org you just
ran the command against; and `wakil provider credentials <shared-id> --org <org>` prints
a token rather than failing. If `home` printed the org you ran it against, the binding
did not record as shared and something above was mistyped. If `credentials` failed, the
`secrets set` for that binding did not run, or ran under the wrong `--org`.

**Undoing one of these is not symmetrical, by design.** `wakil provider rm <shared-id>
--org <org>` removes a binding freely — nothing depends on it. Removing the record that
*homes* a config dir is refused while any org still shares it, and the refusal names
them: the home is the only thing tying the directory to the org whose `WAKIL_ORG` is
pinned inside it, and deleting it would strand every sharer with no way back. Remove the
bindings first. Neither command ever touches the Keychain, so a token you stored above
outlives the binding that used it.

This machine's own `docs/wakil/shared-accounts-acceptance.md` is the runbook that walks
these commands and the checks Wakil needs at the window. **Walked in full 2026-09-14, all
eight result rows PASS** — including the result that settles a question older than this
sub-phase: `--strict-mcp-config` holds on an enterprise account, and on a team account,
not just on `max`. Four defects came out of that walk and all four are now fixed.

---

## LIGHT MODE — confirm the app is readable with the Mac set to light  ⚠️ ACCEPTED 2026-09-15, NEVER RUN

*Closed with the rest of the backlog. The fix below shipped and is believed correct; the
four confirmations were never made. Two minutes if you ever want them.*

**Added 2026-09-14** with the safety fixes from
`docs/wakil/north-star-and-design-review-2026-09-14.md` §F0. One check, two minutes,
and it needs your hands because `WakilApp` has no test target and this is a rendering
question no test in this repository can ask.

**The defect it closes.** Every background in Wakil is hardcoded near-black, but a long
list of `Text` views carried no explicit colour and resolved to the *system* label
colour — black on a Light Mode Mac. The worst of them is the SQL statement on the
confirmation plane: an operator asked to type `confirm` for a database mutation they
cannot read. The launch state, every error in the status line, the rail and the palette
were all in the same position.

**The fix** is `NSApp.appearance = .darkAqua` plus `.preferredColorScheme(.dark)`
(`AppScene.swift`) — the app now declares itself dark rather than inheriting the
system's appearance. Note it is **not** `NSRequiresAquaSystemAppearance`, which the
design review suggested: that key pins an app to *light* and would have guaranteed the
bug instead of fixing it.

**The check.** System Settings ▸ Appearance ▸ **Light**, then launch Wakil — both
`swift run` and `open app/Wakil.app`, because they take different paths to the
appearance. Confirm:

1. The window is dark, not light, and the void reaches all four edges as usual.
2. The status line under the canvas is readable — force an error if none is showing
   (a query against a database that does not exist will do).
3. **Open the confirmation plane and read the statement.** Run any mutation against
   `staging` from the query line; the plane must show the SQL in light monospace on the
   dark plane. This is the check that matters — the other two are cheap confirmations
   that the appearance took.
4. The environment badge at the top is readable, and switching to `production` leaves it
   **clearly readable and unmistakably red** — no dimmer and no softer than it was on
   `staging`. Judge it as *legible and alarming*, not as *brighter*: production is red on
   near-black at 5.82:1 where the ordinary badge is near-white at 16.86:1, so it is the
   lower-contrast of the two by construction and always will be. What the fix guarantees
   is that both clear the readability floor; what production adds is hue, not luminance.

Set Appearance back to Dark afterwards, or don't — the point of the fix is that it no
longer matters.
