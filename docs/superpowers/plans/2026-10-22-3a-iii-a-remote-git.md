# 3a-iii-a Remote Git Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each organisation holds one git account per provider (SSH key, pasted token, or GitHub/GitLab.com sign-in), and Wakil fetches, pulls, pushes, syncs, publishes and clones with it, whatever the remote's spelling.

**Architecture:** Go owns accounts and secrets (`wakil-ctx` tools, the `Org` record, the Keychain) and a third git runner, `GitRemote`, in `wakil-git`, which builds each command's credential injection from a pure function. WakilKit registers `editor_changes_fetch/pull/push/sync/publish` and `editor_clone`, all priced allow, on 3a-ii's per-root write lock; WakilApp draws the accounts in Settings → Organisation → Git, the remote button in the Changes view, and Clone in Add a project.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-git`, `cmd/wakil-ctx`, `cmd/wakil`), Swift 6 / SwiftUI, Swift Testing, the e2e harness.

**Spec:** `docs/superpowers/specs/2026-10-22-3a-iii-git-accounts-and-remotes-design.md` (parts 1–3: accounts, remote operations, clone). Part 4, agent instructions, is `2026-10-22-3a-iii-b-agent-instructions.md`.

## Global Constraints

- Every remote action and `editor_clone`: kind `.mutate`, `audience: .agentReachable`, `price: (production: .allow, otherwise: .allow)`.
- Action names: `editor_changes_fetch`, `editor_changes_pull`, `editor_changes_push`, `editor_changes_sync`, `editor_changes_publish`, `editor_clone`. Tool names: `git_fetch`, `git_pull`, `git_push`, `git_publish`, `git_sync`, `git_clone`, `git_remote_whoami`.
- Account tools (operator-only, Decision 30): `ctx_git_account_add`, `ctx_git_account_remove`, `ctx_git_ssh_keys`, `ctx_git_key_generate`, `ctx_git_token_set`, `ctx_git_account_test`, `ctx_git_device_start`, `ctx_git_device_poll`.
- Keychain refs (Invariant 4's `wakil:<org>:<ref>`): `git-<host>-token`, `git-<host>-ssh-passphrase`.
- Generated keys: `~/.wakil/orgs/<org>/git/ssh/<host>_ed25519`, comment `<user or email> (Wakil · <org>)`; Wakil's known_hosts `~/.wakil/orgs/<org>/git/known_hosts`.
- Pull strategy values: `rebase` (default when empty), `merge`, `ff-only`.
- Protocols allowed: `ssh`, `https` (`file` only when the runner is built with `allowFileProtocol: true`, which only tests do).
- Never `--force`, `--force-with-lease` or `+refspec`. Nothing written to `~/.ssh` or any git config.
- Refusal and error texts verbatim: `No git account for <host> in <org> — add one in Settings → Organisation → Git`; `Authentication failed for <user> on <host> — Settings → Organisation → Git`; `Rejected: the remote has newer commits. Pull or Sync first`; `<branch> has no upstream — Publish it first`; `the destination already exists: <path>`; `protocol not allowed: <scheme>`.
- Background fetch: every 300 s while an editor pane is open and the app is active, and on opening the Changes view.
- Public repository: committed text uses example names (initech, umbrella), never real employers or accounts (`scripts/public-check.sh` refuses them on push).
- Never add Co-Authored-By or "Generated with" lines.

## Rulings

- **R1 — One lock for local and remote writes per root.** `GitWriteFlights` (3a-ii) also guards remote operations: a commit and a push in one root never overlap, and the message is 3a-ii's `a git write is already running in <root name>`. Cost if wrong: a second, remote-only lock.
- **R2 — Progress goes through the reply, not a stream.** MCP tool calls return once; `GitRemote` collects git's last `--progress` line per phase and the window polls nothing. While a call runs, the spinner shows `Pushing…`/`Pulling…`; the final reply carries the last progress line for the journal. Cost if wrong: a live progress line needs a notification channel later.
- **R3 — The account for a remote is found in Go.** `wakil-git` reads the active org's record (`LoadOrg`) at each call, resolves the remote's host, and picks the account, so WakilKit passes only `root`. Cost if wrong: none outside Go.
- **R4 — OAuth client IDs are build-time constants, empty by default.** `internal/wakilcore/gitoauth.go` holds `GitHubClientID` and `GitLabClientID`; empty means the Sign in method is not offered. The operator fills them after registering the apps (operator-todo). Cost if wrong: one config read.

- **R5 — The e2e fixture's `file://` remote.** `wakil-git` sets `AllowFileProtocol` when its environment carries `WAKIL_GIT_ALLOW_FILE=1`, which only the e2e harness's fixture launch sets (`e2e/driver/fixture.go`). The shipped app never sets it. Cost if wrong: Cover needs a local SSH server instead.

## Review Focus

1. **An alias remote (`git@github-umbrella:org/repo.git`) whose `~/.ssh/config` names another key** — the push must use the organisation's key and only it. Test in Task 3 (`-F /dev/null`, `IdentityAgent=none`, only route options).
2. **A token or URL with credentials appearing in git's error text** — never shown or journalled. Test in Task 4 (`scrubRemoteText`).
3. **A pull that conflicts under Rebase** — the tree is back exactly as before (`git status --porcelain` unchanged) and the paths are listed. Test in Task 4.
4. **Cancelling a clone halfway** — the partial folder is gone. Test in Task 4.
5. **An organisation switch while a push runs** — the push finishes in its repository, the result is not shown in the new org's view (3a-ii's `changesGeneration`). Test in Task 7.

---

### Task 1: The organisation's git accounts and pull strategy — Go records and tools

**Files:**
- Modify: `internal/wakilcore/org.go` (`Org` gains `GitAccounts []GitAccount \`json:"gitAccounts,omitempty"\``, `PullStrategy string \`json:"pullStrategy,omitempty"\``), `orgupdate.go` (`OrgPatch.PullStrategy *string`), `configtree.go` (`ConfigTreeOrg.GitAccounts`, `.PullStrategy` resolved)
- Create: `internal/wakilcore/gitaccounts.go`
- Modify: `cmd/wakil-ctx/main.go` (`update_org` takes `pullStrategy`; new tools `git_account_add`, `git_account_remove`)
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (`ctx_update_org` forwards `pullStrategy` as a string — the 3a-ii-b lesson: unlisted keys are dropped; `ctx_git_account_add`, `ctx_git_account_remove` registered `.control`, in `operatorOnlyActions`)
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift` (`SettingsOrg.gitAccounts`, `.pullStrategy`, `.gitHostSuggestions`)
- Test: `internal/wakilcore/gitaccounts_test.go`, `app/Tests/WakilKitTests/EditorSettingsTests.swift`

**Interfaces:**
- Produces: `type GitAccount struct { Host, Provider, Method, User, KeyPath, Username string }` (Method ∈ `ssh`, `token`, `signin`; Provider ∈ `github`, `gitlab`, `bitbucket`, `other`); `func AddGitAccount(org string, a GitAccount) error` (replaces the one for `a.Host`); `func RemoveGitAccount(org, host string) error` (deletes both Keychain refs, Trashes a key under the org's `git/ssh/`); `func GitAccountFor(org, host string) (GitAccount, bool)`.

- [ ] **Step 1: Write the failing tests**: `TestAddGitAccountReplacesTheSameHost`, `TestRemoveGitAccountDeletesItsSecretsAndTrashesAGeneratedKey` (a key outside `git/ssh/` is not touched), `TestPullStrategyDefaultsToRebaseAndRefusesOtherValues` (`"rebase"`, `"merge"`, `"ff-only"` saved; `"squash"` refused `pullStrategy is rebase, merge or ff-only`); Swift `thePullStrategyIsForwarded` beside `theCommitDraftsSwitchIsForwarded`.
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'GitAccount|PullStrategy'` and `cd app && ../scripts/swift-test.sh --filter thePullStrategyIsForwarded`. Expected: FAIL (undefined).
- [ ] **Step 3: Implement** the files above. `config_tree` returns accounts without secrets.
- [ ] **Step 4: Run** `go test ./...` (excluding `e2e/driver`'s audited-controls check if still red on main) and the Swift filter. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: an organisation's git accounts and pull strategy`.

### Task 2: Host resolution — `ssh -G` and remote URLs

**Files:**
- Create: `internal/wakilcore/gitremotehost.go`
- Test: `internal/wakilcore/gitremotehost_test.go`

**Interfaces:**
- Produces: `type RemoteURL struct { Scheme, User, Host, Port, Path string }` (Scheme ∈ `ssh`, `https`, `file`; scp-like `git@h:p` is `ssh`); `func ParseRemoteURL(raw string) (RemoteURL, error)` (refuses `ext::`, `git://`, `http://` with `protocol not allowed: <scheme>`); `type SSHRoute struct { HostName, Port, User, ProxyJump, HostKeyAlias string }`; `func ResolveSSHRoute(alias string) (SSHRoute, error)` (runs `ssh -G <alias>`, keeps only those five keys); `type GitHostSuggestion struct { Host string; Repositories int }`; `func GitHostSuggestions(org string) []GitHostSuggestion` (each project root's `origin` host, aliases resolved), returned on `config_tree` as `ConfigTreeOrg.GitHostSuggestions` and `SettingsOrg.gitHostSuggestions`.

- [ ] **Step 1: Write the failing tests**: table `TestParseRemoteURL` (`git@github.com:o/r.git`, `ssh://git@host:2222/o/r`, `https://github.com/o/r`, `https://tok@github.com/o/r` → User kept for scrubbing, `file:///tmp/r`, `ext::sh -c x` refused, `git://h/r` refused); `TestResolveSSHRouteReadsOnlyTheRoute` with `HOME` pointed at a temp dir whose `.ssh/config` has `Host github-umbrella / HostName github.com / IdentityFile ~/.ssh/umbrella / Port 22` → `HostName github.com`, and no identity anywhere in the result; `TestGitHostSuggestionsCountRepositoriesPerHost` (two projects on the alias, one on bitbucket.org → `github.com 2`, `bitbucket.org 1`).
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'ParseRemoteURL|ResolveSSHRoute|GitHostSuggestions'`. Expected: FAIL.
- [ ] **Step 3: Implement.** `ResolveSSHRoute` runs `ssh -G` with the scrubbed env and a 5 s timeout.
- [ ] **Step 4: Run** the same. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: remote URLs, ssh routes and provider suggestions`.

### Task 3: Credential injection — pure, plus the askpass and credential helper

**Files:**
- Create: `internal/wakilcore/gitcredentials.go`
- Modify: `cmd/wakil/main.go` (subcommands `wakil git-askpass --org <org> --host <host>` and `wakil git-credential --org <org> --host <host> get`)
- Test: `internal/wakilcore/gitcredentials_test.go`, `cmd/wakil/main_test.go`

**Interfaces:**
- Consumes: Task 1's `GitAccount`, Task 2's `RemoteURL`, `SSHRoute`; `SecretGetFor(org, ref)`.
- Produces: `type GitInvocation struct { Args []string; Env []string }`; `func RemoteInvocation(org string, a GitAccount, remote RemoteURL, route SSHRoute, wakilBin, knownHosts string) GitInvocation` — Args are pre-subcommand `-c` pairs; Env the extra variables.

Per method (the spec's table, exactly):
- **ssh:** `GIT_SSH_COMMAND=ssh -F /dev/null -i <KeyPath> -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile=<knownHosts> -o StrictHostKeyChecking=accept-new` plus `-o HostName=…` / `-o Port=…` / `-o User=…` / `-o ProxyJump=…` / `-o HostKeyAlias=…` for each non-empty route field; `SSH_ASKPASS=<wakilBin> git-askpass --org <org> --host <host>`, `SSH_ASKPASS_REQUIRE=force` when the Keychain holds `git-<host>-ssh-passphrase`; an `https` remote adds `-c url.git@<host>:.insteadOf=https://<host>/`.
- **token / signin:** `-c credential.helper=`, `-c credential.helper=!<wakilBin> git-credential --org <org> --host <host>`, `-c credential.interactive=false`; an `ssh` remote adds `-c url.https://<host>/.insteadOf=git@<host>:` and `-c url.https://<host>/.insteadOf=ssh://git@<host>/`.
- `git-credential get` prints `username=<x-access-token | oauth2 | Username>` and `password=<token>` for GitHub, GitLab and Bitbucket/other respectively.

- [ ] **Step 1: Write the failing tests**: `TestSSHInvocationUsesOnlyTheOrganisationsKey` (contains `-F /dev/null`, `IdentityAgent=none`, the key path, the route's HostName; no `~/.ssh` path); `TestSSHInvocationRewritesHTTPS`; `TestTokenInvocationResetsHelpersAndRewritesSSH`; `TestAskpassOnlyWhenAPassphraseIsKept`; `TestGitCredentialAnswersPerProvider` (Keychain faked through the existing secrets test seam in `secrets_test.go`).
- [ ] **Step 2: Run** `go test ./internal/wakilcore ./cmd/wakil -run 'Invocation|Askpass|GitCredential'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: per-command credentials — ssh, token, askpass and credential helper`.

### Task 4: `GitRemote` and the `wakil-git` tools

**Files:**
- Create: `internal/wakilcore/gitremote.go`
- Modify: `cmd/wakil-git/main.go` (the seven tools, registered only under `WAKIL_GIT_WRITES=1` like 3a-ii's)
- Test: `internal/wakilcore/gitremote_test.go`, `cmd/wakil-git/main_test.go`

**Interfaces:**
- Consumes: Tasks 1–3; 3a-ii's `NewGitRunner` root check, `gitScrubbedEnv`, identity `-c` args.
- Produces: `type GitRemote struct{ … }`; `func NewGitRemote(org, root string, allowedRoots []string, opts GitRemoteOptions) (*GitRemote, error)` (`GitRemoteOptions{ AllowFileProtocol bool; WakilBin string }`); methods `Fetch(ctx) (GitRemoteResult, error)`, `Pull(ctx) (GitRemoteResult, error)`, `Push(ctx)`, `Publish(ctx)`, `Sync(ctx)`; `func GitClone(ctx, org, url, dest string, opts GitRemoteOptions) (GitRemoteResult, error)`; `func GitRemoteWhoAmI(ctx, org, host string) (string, error)`; `type GitRemoteResult struct { Summary, Progress string; Conflicts []string; Ahead, Behind int }`; `func scrubRemoteText(s string) string` (drops `user:pass@` and `token@` from URLs, and any `password=` line).

Behaviour pinned: `GIT_ALLOW_PROTOCOL=ssh:https` (`ssh:https:file` with `AllowFileProtocol`); `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`; `-c core.sshCommand=` before injection; a non-default `remote.<r>.uploadpack`/`receivepack` refused; Pull runs `git pull --rebase|--no-rebase|--ff-only` by `PullStrategy`; a conflict runs `git rebase --abort` or `git merge --abort` and returns `Conflicts`; Push refuses no upstream with `<branch> has no upstream — Publish it first`; a rejected non-fast-forward maps to `Rejected: the remote has newer commits. Pull or Sync first`; an auth failure (`Permission denied (publickey)`, `Authentication failed`, `could not read Username`) maps to `Authentication failed for <user> on <host> — Settings → Organisation → Git`; no account maps to the spec's text before git runs; Clone refuses an existing destination and removes a partial one on failure or cancel.

- [ ] **Step 1: Write the failing tests** with two bare repositories over `file://` and `AllowFileProtocol: true`, an account stub for host `""`/file: `TestFetchPruneAndAheadBehind`; `TestPullRebaseConflictAbortsAndListsPaths` (porcelain before == after); `TestPullMergeAndFastForwardOnly`; `TestPushRejectedNonFastForwardMapsItsText`; `TestPushWithoutUpstreamAsksForPublish`; `TestPublishSetsUpstream`; `TestSyncStopsAtTheFirstFailure`; `TestCloneRefusesAnExistingDestination`; `TestCloneCancelledRemovesThePartialFolder`; `TestNoAccountRefusesBeforeGitRuns`; `TestNeverForce` (no arg vector contains `force` or a `+` refspec); `TestScrubRemoteText`; `TestRepositoryUploadpackIsRefused`.
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'GitRemote|Pull|Push|Publish|Sync|Clone|Scrub|Uploadpack|NoAccount|NeverForce'`. Expected: FAIL.
- [ ] **Step 3: Implement** `gitremote.go` and the tools.
- [ ] **Step 4: Run** `go test ./internal/wakilcore ./cmd/wakil-git`. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: GitRemote — fetch, pull, push, publish, sync, clone`.

### Task 5: Account setup tools — SSH keys, tokens, test

**Files:**
- Create: `internal/wakilcore/gitaccountsetup.go`
- Modify: `cmd/wakil-ctx/main.go` (`git_ssh_keys`, `git_key_generate`, `git_token_set`, `git_account_test`); `StandardActions.swift` (the four `ctx_git_*`, `.control`, operator-only; secret params scrubbed from the journal as `secretParams`)
- Test: `internal/wakilcore/gitaccountsetup_test.go`

**Interfaces:**
- Produces: `type SSHKeyListing struct { Path, Comment, Type string; Encrypted bool }`; `func ListSSHKeys() []SSHKeyListing` (`~/.ssh/*.pub` with a private key beside it; `Encrypted` from `ssh-keygen -y -P "" -f`); `func GenerateGitKey(org, host, comment string) (publicKey string, err error)` (ed25519 with a 32-byte random passphrase saved first as `git-<host>-ssh-passphrase`); `func SetGitToken(org, host, token string) error`; `func SetGitKeyPassphrase(org, host, passphrase string) error`; `func TestGitAccount(ctx, org, host string) (user string, err error)` (Task 4's `GitRemoteWhoAmI`: `ssh -T` with the invocation and parse `Hi <u>!` / `Welcome to GitLab, @<u>!` / `authenticated via ssh key`; token: `GET https://api.github.com/user`, `https://gitlab.com/api/v4/user`, `https://api.bitbucket.org/2.0/user` with the token).

- [ ] **Step 1: Write the failing tests**: `TestListSSHKeysMarksEncryptedOnes` (generate one with and one without a passphrase in a temp HOME); `TestGenerateGitKeyStoresThePassphraseBeforeTheKey`; `TestWhoAmIParsesEachHostsGreeting` (table over the three greetings and a refusal kept whole); `TestTokenSecretsNeverReachTheJournal` (Swift, `secretParams`).
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'SSHKeys|GenerateGitKey|WhoAmI'` and the Swift filter. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: SSH keys, tokens and the connection test`.

### Task 6: WakilKit — the remote actions

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorChangesRemote.swift` (registered from `registerEditorChangesWrites`)
- Modify: `app/Sources/WakilKit/App/WindowModel+ChangesWrites.swift` (`changesFetch/Pull/Push/Sync/Publish(root:)` through `changesWrite`; `changesRemoteLabel(root:) -> ChangesRemoteButton`)
- Modify: test lists in `WindowModelPaletteTests.swift` and `AppWiringTests.swift`
- Test: `app/Tests/WakilKitTests/EditorChangesRemoteTests.swift`

**Interfaces:**
- Produces: `public enum ChangesRemoteButton: Equatable { case publish, push, pull, sync, none }` and `func changesRemoteButton(_ root: GitRootState) -> ChangesRemoteButton` (no upstream → publish; ahead>0 & behind>0 → sync; ahead → push; behind → pull; else none); the five actions with param `root`.

- [ ] **Step 1: Write the failing tests**: `eachRemoteActionCallsItsToolAndIsAllowedForTheAgentInProduction`; `aRemoteWriteTakesTheRootsWriteLock` (a running commit refuses a push with 3a-ii's text); `theButtonFollowsAheadBehindAndUpstream` (table); `conflictsComeBackWhole`.
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter EditorChangesRemoteTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Status is re-read after each (3a-ii's path).
- [ ] **Step 4: Run** `make app-test`. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: fetch, pull, push, sync and publish as actions`.

### Task 7: Background fetch and the org switch

**Files:**
- Create: `app/Sources/WakilKit/App/WindowModel+BackgroundFetch.swift`
- Modify: `InvalidationContractTests.swift` (new properties classified)
- Test: `app/Tests/WakilKitTests/WindowModelBackgroundFetchTests.swift`

**Interfaces:**
- Produces: `WindowModel.backgroundFetchInterval: Duration = .seconds(300)`; `func startBackgroundFetch()`, `func stopBackgroundFetch()` (started when an editor pane opens and the app is active, stopped otherwise); a fetch failure sets `changesRemoteNotes[root]` (header line), never `changesErrors`.

- [ ] **Step 1: Write the failing tests** with an injected clock: `fetchesEachRootOnTheInterval`; `noFetchWithoutAnEditorPane`; `aFailedFetchIsAHeaderNoteNotAnError`; `aPushThatLandsAfterAnOrgSwitchIsNotShown` (Review Focus 5).
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter WindowModelBackgroundFetchTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make app-test`. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: fetch in the background every five minutes`.

### Task 8: Clone — `editor_clone` and Add a project

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorClone.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`cloneProject(link: String, into folder: String) async -> (name: String?, error: String?)`: `editor_clone` then 2e-ii's `createProject(folder:)`; `lastCloneFolder` per org in the app settings file)
- Test: `app/Tests/WakilKitTests/EditorCloneTests.swift`

**Interfaces:**
- Consumes: Task 4's `git_clone`; 2e-ii's `WindowModel.createProject(folder:)`.
- Produces: `editor_clone` params `url`, `folder` (optional for the operator; for the agent it must equal `lastCloneFolder` or be omitted, else refused `the agent clones only into <lastCloneFolder>`); reply `{path}`; the agent's clone registers nothing and the thread line reads `Cloned to <path> — Add as project`.

- [ ] **Step 1: Write the failing tests**: `theOperatorsCloneBecomesAProject`; `theAgentsCloneRegistersNothing`; `theAgentClonesOnlyIntoTheLastFolder`; `aCloneIntoAnExistingFolderIsRefusedWhole`.
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter EditorCloneTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make app-test`. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: clone from a link`.

### Task 9: WakilApp — Settings, the Changes view, Add a project

**Files:**
- Modify: `app/Sources/WakilApp/SettingsPane.swift` (Git section: **Accounts** rows `settings.org.git.account.<host>` with **Test**, **Replace**, **Remove** (asks in the pane, Rule 1), **+ Add a git account** sheet `settings.org.git.account.add` — provider (suggestions first) → method (only what the provider allows; Sign in only when Task 10's client ID is set) → steps; **Pull strategy** segmented `settings.org.git.pullStrategy.<value>`); `addProject()` becomes a menu **Choose a folder…** / **Clone from a link…** (`settings.projects.add.folder`, `.clone`) with the clone sheet (link field focused, Rule 3; destination with **Change…**; **Clone**; progress; **Cancel**)
- Modify: `app/Sources/WakilApp/EditorColumn.swift` (root header `main ↑2 ↓1`; the remote button `editor.changes.<root>.remote` titled from `ChangesRemoteButton`; ▾ **Fetch** `editor.changes.<root>.fetch`; spinner and Cancel; header note)
- Test: e2e only (no WakilApp test target)

- [ ] **Step 1: Implement** the views. SSH steps show the public key in a selectable monospaced block with **Copy** and **Open <host>'s SSH keys page** (`https://github.com/settings/ssh/new`, `https://gitlab.com/-/user_settings/ssh_keys`, `https://bitbucket.org/account/settings/ssh-keys/`; other hosts no button); token steps link `https://github.com/settings/tokens/new?scopes=repo`, `https://gitlab.com/-/user_settings/personal_access_tokens`, `https://bitbucket.org/account/settings/api-tokens/`.
- [ ] **Step 2: Run** `make app-bundle` and `go test ./e2e/driver -run TestEveryAuditedControlIsNamed`. Expected: builds; no new unnamed control.
- [ ] **Step 3: Commit** `3a-iii-a: accounts, the remote button and Clone in the app`.

### Task 10: Sign in — GitHub and GitLab.com device flow (last)

**Files:**
- Create: `internal/wakilcore/gitoauth.go` (`GitHubClientID`, `GitLabClientID` constants, empty; `DeviceStart(provider) (DeviceCode, error)`, `DevicePoll(provider, deviceCode) (token string, pending bool, err error)`)
- Modify: `cmd/wakil-ctx/main.go`, `StandardActions.swift` (`ctx_git_device_start`, `ctx_git_device_poll`), `SettingsPane.swift` (the code, **Open github.com/login/device**, waiting with **Cancel**, **Try again** on expiry); **Use a gh login** (`gh auth status` accounts → `gh auth token --user <u>` → `SetGitToken`)
- Test: `internal/wakilcore/gitoauth_test.go` (an `httptest` server standing in for `https://github.com/login/device/code`, `/login/oauth/access_token`, `https://gitlab.com/oauth/authorize_device`, `/oauth/token`)

- [ ] **Step 1: Write the failing tests**: `TestDeviceFlowPollsUntilApproved` (`authorization_pending`, then a token); `TestDeviceFlowSlowDownWidensTheInterval`; `TestDeviceFlowExpiredSaysSo`; `TestSignInNotOfferedWithoutAClientID`.
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run DeviceFlow`. Expected: FAIL.
- [ ] **Step 3: Implement.** Scopes: GitHub `repo`; GitLab `read_repository write_repository read_user`.
- [ ] **Step 4: Run** the same and `make app-test`. Expected: PASS.
- [ ] **Step 5: Commit** `3a-iii-a: sign in with GitHub and GitLab.com`.

### Task 11: Charter records

**Files:** `docs/wakil/north-star.md` (Invariant 6's seventh row; 3a-iii's §8 wording names clone), `docs/wakil/decisions.md` (Invariant 6 appendix entry; Decision 44), `docs/wakil/operator-todo.md` (register the GitHub OAuth App and the GitLab.com application; where the client IDs go).

- [ ] **Step 1: Edit** them, with example names only. Run `scripts/public-check.sh` on the changed files. Expected: no hits.
- [ ] **Step 2: Commit** `3a-iii-a: charter records`.

**After the plan:** `superpowers:requesting-code-review`, then Cover (`docs/agents/e2e.md`; a seeded fixture with a bare `file://` remote), then the runbook `docs/wakil/phase-3a-iii-acceptance.md`.
