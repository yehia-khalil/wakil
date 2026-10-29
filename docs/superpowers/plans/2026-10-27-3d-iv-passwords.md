# 3d-iv: passwords — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wakil keeps the operator's site passwords, one store per organisation, in the macOS Keychain. A key
in a login field fills a saved login when the operator presses it. A bar at the pane's top offers to save or
update a login after a form is sent. A sign-up field is offered a strong password. Settings → Browser →
Passwords lists, reveals, copies, edits and deletes logins, and imports the Passwords app's CSV once. The
agent never sees a password and never fills one.

**Architecture:** Everything that decides is in WakilKit: the Keychain item's name and the org check
(`BrowserPasswords`), the store (`BrowserPasswordStore`, Security.framework in-process, so each item trusts
Wakil.app only and not `/usr/bin/security`), the CSV parser, the strong-password generator, what a sent form
is offered (save, update, nothing), and five operator-only `browser_password_*` actions. A scrubbing
decorator around the page driver hides any password Wakil filled from `browser_read_page`. WakilApp adds a
page script in its own content world (`wakil.passwords`) that reports the focused login field's rect and a
sent form, the key and its list, the save bar, and the Settings section. Go only learns to name the
leftover password items in `wakil org rm`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, WebKit (`WKContentWorld`, `WKScriptMessageHandler`),
Security.framework (`SecItem*`, `SecKeychainOpen`), LocalAuthentication, Swift Testing; Go
(`internal/wakilcore`, `cmd/wakil`).

**Spec:** `docs/superpowers/specs/2026-10-27-3d-browser-you-live-in-design.md`. Its parts for this lane are
"Lane C, 3d-iv: passwords", calls 12 and 13, Design (`BrowserPasswords.swift`, the `wakil org rm` line),
Interaction rules 1, 2, 4, 5, 7 and 8, Errors and edges ("Keychain denied or locked"), Testing (CSV parser,
strong-password shape, save-then-fill e2e), and Charter changes (Decision 49's passwords part, Invariant 4's
note, Invariant 6's note). Lane C uses only the default identity. Identities (3d-ii) are not built.

## Rulings

Every choice the spec left open, and every place it disagrees with the code, is decided here. Each one is a
**planner's call**. The ones marked **(seen)** change what the operator sees, and the operator should check
them.

1. **Swift reads and writes these items in-process through Security.framework, not by running
   `/usr/bin/security`.** Call 12 says WakilKit, not Go. The code says otherwise in three places:
   `ProviderCredentialsLookup.swift`'s header ("Swift does not read the Keychain"), `CONTRIBUTING.md`'s
   table (the Keychain → Go), and `docs/architecture/state.md` ("The Swift app never reads the Keychain
   directly"). The spec wins for one reason. Go's items trust `/usr/bin/security`
   (`credpresence.go`'s `securityBinary`), and the agent has a bare shell. So the agent could run
   `security find-generic-password -w` on a Go-written item and read it with no prompt. An item that
   `SecItemAdd` creates from Wakil.app trusts Wakil.app only. Any other program that asks for its value
   raises the system's permission prompt. Task 1 measures this before anything is built. The three docs
   are amended in Task 10, for browser passwords only.
2. **(seen) The cost of ruling 1 on an unsigned build.** An ad-hoc signed app gets a new code hash with
   every build. So the first read of each item after a rebuild asks *"Wakil wants to use your confidential
   information stored in … in your keychain"*. **Always Allow** holds until the next build. Listing never
   asks, because it reads attributes only. Task 1 records exactly what the operator sees, and the walk's
   row 10 shows it.
3. **The item's name.** The service is `wakil:<org>:browser-login:default` and the account is
   `<site> <username>`, split at the first space. A site key never holds a space, and a username may. The
   label is `<site> — Wakil (<org>)`, so Keychain Access shows something readable. The org and the
   identity must match Go's `orgFileTokenPattern` `^[A-Za-z0-9][A-Za-z0-9._-]*$`, so a `:` can't make two
   orgs' names collide (`keychainService`'s reasoning). `BrowserOrgFiles`' own check, which allows `:`, is
   not enough here.
4. **The org check on every read (call 12, as `Resolve()` does it).** Every query is by the exact service.
   Then every item that comes back is checked again: its service must equal the expected one, and its
   account's site must equal the asked site. An item that fails either check throws
   `BrowserPasswordError.wrongOrganisation`. It is never returned or skipped quietly.
5. **(seen) The site key is the registrable domain with no families.** The spec says "the registrable
   domain, as for groups". Groups also join families, and one family pairs `github.com` with
   `githubusercontent.com`, which serves user content. A password must never be offered there. So
   `BrowserPasswords.siteKey` is: nothing off http and https; `BrowserSite.key`'s `host:port` for a local
   host (loopback, `localhost`, `*.localhost`, `*.test`, an IP literal); otherwise
   `BrowserSiteKey.registrableDomain(host)`. That function comes from 3d-i's commit `dfe256b` (Task 2).
6. **(seen) The strong password is 23 characters.** The spec asks for "20 characters" in "four groups of five
   with hyphens", and those two don't fit together. The shape wins: four groups of five from
   `[A-Za-z0-9]`, joined by `-`. That is 20 letters and digits plus 3 hyphens, with at least one upper
   case, one lower case and one digit. It comes from `SystemRandomNumberGenerator`.
7. **What a sent form is offered.** The pure rule is `BrowserPasswords.offer`, in this order. An empty
   password gets nothing. A password that equals the suggestion the operator chose for that tab is saved
   with no bar. A site on the never list gets nothing. A saved login with the same username gets nothing
   when the password matches, and *Update* when it differs. An empty username on a site with exactly one
   saved login gets *Update* for that login (a change-password form). Anything else gets *Save*. **(seen)**
   *Update* has two buttons, **Update** and **Not Now**. *Never for This Site* belongs to *Save* only.
8. **The never list is a file, `passwords-never.json`, in the organisation's browser folder.** It is a
   sorted JSON array of site keys. It holds no credential. Clearing browsing data keeps it. A file that
   can't be read is never written over (3c-iii's ruling 4). **(seen)** Settings lists these sites under
   *Never saved for*, each with an ×, which is the only way to undo the choice.
9. **(seen) The clear question now names passwords:** `… Bookmarks and saved passwords stay.` (call 13).
10. **Reads are direct calls; writes are actions.** The key's list, Settings' list, reveal and copy call
    `BrowserPasswordStore` directly. No action returns a password, so none reaches a journal or an MCP
    reply. Filling, suggesting, saving, deleting and the never list are operator-only `.control` actions
    (Invariant 2), and `password` is a `secretParams` key. Import dispatches `browser_password_save` once
    per row. That gives Rule 4 its cancel point between rows, and one bad row stops no other (Rule 8).
11. **The key shows on the focused field only:** a username field (`autocomplete="username"`, or the
    nearest text or email input before a password field in its form) or a password field, and only when the
    site has a saved login, or the field is `autocomplete="new-password"`. It is drawn at the field's right
    edge, inset 4 pt, 16 pt square, using the `key.fill` glyph at the meta opacity. The script watches the
    main frame only. A login form in an iframe gets no key, and the walk names this as a known limit.
12. **The key's list is a popover, not a menu.** It stays open while a fill runs (Rule 5) and shows a
    Keychain error whole under the rows (spec: "the key glyph's list shows the error whole"). It closes
    when a fill succeeds, and the page's field keeps the keyboard (Rule 6).
13. **A fill lands only on the site and origin it was asked for.** The action checks the tab's current site
    key against the login's site. The page script also gets the `location.origin` that was captured when
    the key was pressed, and refuses if the page has moved since. The message handler reads the origin from
    `WKScriptMessage.frameInfo.securityOrigin`, never from the page's own words, and drops any message that
    is not from the main frame or not in `wakil.passwords`.
14. **A sent form means** a `submit` event, caught on the document in the capture phase, so it still fires
    when the page cancels it. It also means Enter in a password field that has no form. The bar stays,
    across the navigation the submit causes, until it is answered, its tab closes, or a newer submit
    replaces it. It hides while another tab is selected. It is the host's, not the store's, as
    `BrowserPrompt` is.
15. **Scrubbing.** `BrowserPasswordScrub` keeps, in memory only, up to 64 passwords that have been in a page:
    the ones filled, suggested, or saved from a bar. `BrowserScrubbingPageDriver` wraps the window's page
    driver and replaces each one with `••••••••` in a read's element values (any length), and in its
    text and labels (6 characters or more). This covers a site's *show password* toggle, which turns the
    field into text that the never-list cannot recognise.
16. **Reveal and copy need one authentication** through `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`.
    It holds for the Passwords section until the section closes, or for 5 minutes, whichever comes first.
    Copy writes the value with the `org.nspasteboard.ConcealedType` marker. An edited password is saved
    when focus leaves the field (Rule 2). Renaming a username moves the item: the old one is deleted after
    the new one is written.
17. **Import.** The operator picks a file in `NSOpenPanel`. It is read once into memory and parsed. The
    rows, with their values, live only in the sheet's view state, and are dropped when the sheet closes.
    Nothing is written but Keychain items. A URL with no scheme gets `https://` in front. A row whose URL
    has no site key is skipped as `not a web address`. When two rows name the same site and username, the
    later one wins (Rule 7). A row whose login is already saved replaces it and says so. After the import,
    the sheet asks in place whether to move the file to the Trash (`FileManager.trashItem`, never a
    permanent delete).
18. **`wakil org rm`** checks for the default identity's items with `find-generic-password -s <service>`,
    attributes only. It gets no value and raises no prompt. It names them as residue, and deletes nothing
    (call 13).

## Global Constraints

- Platform floor `macOS 14.4`. No new package dependency. `import Security` lives only in
  `BrowserPasswordStore.swift`, and `import LocalAuthentication` only in WakilApp.
- Keychain: service `wakil:<org>:browser-login:default`, account `<site> <username>`, label
  `<site> — Wakil (<org>)`, class `kSecClassGenericPassword`. When `WAKIL_KEYCHAIN` is set, every call is
  scoped to that file (`SecKeychainOpen`, then `kSecUseKeychain` on add and `kSecMatchSearchList` on
  queries). A set value whose file is missing is refused, and never falls back to the login keychain.
  **No test uses the login keychain**: every store in a test is built on a temporary keychain file.
- Files: `~/.wakil/orgs/<org>/browser/passwords-never.json` and nothing else. No password is ever written to
  a file, `PaneStore`, a layout, the journal, an MCP reply, `print`/`NSLog`/`os_log`, or an error's text.
- Actions, all `.control` and `.operatorOnly`, listed in `operatorOnlyActions`: `browser_password_fill
  {pane, tab, site, username}`, `browser_password_suggest {pane, tab}`, `browser_password_save {org,
  site, username, password?, previousUsername?, pane?, tab?}` (`secretParams: ["password"]`),
  `browser_password_delete {org, site, username}`, `browser_password_never {org, site, on}`. `read_pane` is
  unchanged.
- Copy, verbatim:
  - Bar: `Save the password for <user> on <site>?`, or `Save the password on <site>?` with no username;
    `Update the password for <user> on <site>?`. Buttons `Save`, `Not Now`, `Never for This Site`;
    `Update`, `Not Now`.
  - Key list: each username, or `(no username)`; `Suggest Strong Password`.
  - Settings: section `Passwords`, hint `Kept in the Keychain for this organisation. Wakil fills one only
    when you press the key in a field, and the agent never sees them.`; empty `No passwords saved for <org>
    yet.`; `Import…`, `Reveal`, `Copy`, `Edit`, `Delete`; `Delete the password for <user> on <site>? It
    can't be brought back.` with `Delete` and `Keep it`; `Never saved for`; reveal reason `reveal the
    password for <user> on <site>`.
  - Import: `Import from the Passwords app`; hint `In Passwords, choose File → Export All Passwords…, then
    pick the file here. Wakil reads it and keeps no copy.`; skips `no URL`, `no password`, `not a web
    address`, `a later row for the same login replaces this one`; `replaces the saved password`; `Import`,
    `Cancel`; `Importing <n> of <total>…`; `Imported <n> passwords. Skipped <m>.`; `Move <file> to the
    Trash? It holds every password in plain text.` with `Move to Trash` and `Keep it`.
  - Clear question: `Delete <org>'s browsing data? Every site signs you out, in every project, and its
    history is deleted. Bookmarks and saved passwords stay.`
  - Refusals: `browser_password_fill: <site> has no saved password for <user> in <org>.`;
    `browser_password_fill: the tab is on <now> now, so the password for <site> was not filled.`;
    `browser_password_save: "<org>" is not an organisation on this Mac.`; the agent's refusal
    (PermissionPrompt) `<tool>: only the operator fills, saves or deletes a saved password, by pressing the
    key in a field or in Settings → Browser → Passwords. You never see a password and never fill one.`
- Accessibility identifiers: `browser.password.key`, `browser.password.list`, `browser.password.login.<n>`,
  `browser.password.suggest`, `browser.password.error`, `browser.password.bar`, `browser.password.bar.save`,
  `.update`, `.notNow`, `.never`; `settings.browser.passwords`, `settings.browser.passwords.row.<n>` with
  `.reveal`, `.copy`, `.edit.username`, `.edit.password`, `.delete`, `.delete.confirm`, `.delete.keep`;
  `settings.browser.passwords.never.<n>`; `settings.browser.passwords.import`, `…import.row.<n>.org`,
  `…import.run`, `…import.cancel`, `…import.trash.confirm`, `…import.trash.keep`.
- Test passwords only, such as `walk-test-pass-1`. Organisations `initech` and `umbrella` in tests.
  Nothing committed names a home path or a real login.
- No `Co-Authored-By` or "Generated with" lines in commits.

### Shared files: rebase before the PR

3d-i (tab model) and 3d-iii (picture in picture) are being built on other branches. This lane adds new files
wherever it can. **Rebase onto whichever lane merges first** and settle these hunks:

| File | This lane's hunk | Also touched by |
|---|---|---|
| `app/Sources/WakilApp/BrowserTabHost.swift` | `configuration(files:…)` adds the passwords script and handler | 3d-iii (changes its signature to `configuration(files:handler:)`, adds PiP); 3d-ii later (identity store) |
| `app/Sources/WakilApp/BrowserWebView.swift` | `BrowserTabDelegate.didCommit` drops the tab's field report | 3d-i, 3d-iii |
| `app/Sources/WakilApp/BrowserPane.swift` | the bar row above the page; the key overlay on it | 3d-i (column), 3d-iii |
| `app/Sources/WakilApp/BrowserSettingsForm.swift` | one `SettingsSection("Passwords")` line | 3d-i, 3d-iii |
| `app/Sources/WakilKit/MCP/PermissionPrompt.swift` | five names and one sentence | 3d-iii |
| `app/Sources/WakilKit/Browser/BrowserOrgFiles.swift`, `BrowserActions.swift` | clear copy (ruling 9), doc list | 3d-i |
| `app/Sources/WakilKit/App/AppWiring.swift`, `app/Sources/WakilApp/WindowSession.swift` | store, scrub, page seam | — |
| `docs/wakil/north-star.md`, `decisions.md`, `design-language.md`, `docs/architecture/*`, the spec | Task 10 | 3d-i writes Decision 49 and the 3d row; this lane only adds to them |

`internal/wakilcore/browsersettings.go` and `cmd/wakil-ctx` are **not** touched: passwords have no setting.
The tab strip and `BrowserPictureInPicture*` are not touched.

## Review Focus

This list has six lines, not the usual five. Security is the point of this lane, and each line is a way the
operator would be hurt.

1. **A password reaching the agent, `read_pane`, the journal, a log or a file.** A filled field read back
   after *show password*, a journal line for `browser_password_save`, a Keychain error that quotes the
   value, a tab-state file after a fill. Pinned by Task 6's `aSavedPasswordNeverReachesTheJournal`,
   `readPaneCarriesNoPasswordAfterAFill` and `aReadHidesAFilledPasswordInTextAndValues`, Task 3's
   `keychainErrorsNeverCarryTheValue`, and Task 1's tab-state measurement.
2. **Another organisation's login returned or filled.** A login listed after an org switch, a fill using
   `umbrella`'s item in `initech`, an org named `a:b`. Pinned by Task 3's
   `anotherOrganisationsLoginIsNeverReturned` and `anOrganisationWithAColonIsRefused`, and Task 6's
   `fillReadsTheActiveOrganisationsLoginOnly`.
3. **The agent filling, saving or listing.** Pinned by Task 6's `everyPasswordActionIsOperatorOnly`, its
   refusal sentence, and the classification test's pinned list. No action lists logins.
4. **A fill with no press, or on a page that moved.** A redirect between the press and the fill, a
   `javascript:` origin, a message forged by the page's own script. Pinned by Task 6's
   `fillRefusesWhenTheTabHasMovedToAnotherSite`, and by Cover's checks `nothing filled on load`, `fill
   refused after redirect` and `a page's own postMessage is not heard`, which the Task 8 fixtures make
   possible.
5. **The CSV copied.** Pinned by Task 4's `theParserTakesBytesAndWritesNothing`, and Task 9's rule that
   the sheet drops its rows when it closes. Cover checks that `~/.wakil` holds none of the CSV's test
   passwords after an import.
6. **An e2e run or a test writing into the operator's login keychain.** Pinned by Task 3's
   `aMissingKeychainFileIsRefusedNotReplaced` and `theStoreWritesOnlyToItsKeychainFile`, and by the
   wiring test `theStoreTakesWakilKeychainFromTheEnvironment`.

---

### Task 1: Probe — the Keychain route and the tab state

**Files:**
- Create: `scripts/probe/3d-iv-keychain/main.swift` (throwaway, deleted in Step 5), `docs/wakil/3d-iv-keychain-probe.md`
- Modify: the spec — a dated amendment `## Amendment 2026-10-27 (3d-iv probe)` recording the findings and rulings 1–6

- [ ] **Step 1: Write the probe.** A Swift script that creates a throwaway keychain with `/usr/bin/security
  create-keychain`, `unlock-keychain` and `set-keychain-settings`, as `e2e/driver/launch.go:141-160` does.
  It adds `wakil:probe:browser-login:default` / `127.0.0.1:8123 walker` through `SecKeychainOpen` and
  `SecItemAdd` with `kSecUseKeychain`, lists it with `kSecMatchLimitAll` and `kSecReturnAttributes`, then
  reads its value back.
- [ ] **Step 2: Run it and record** in `3d-iv-keychain-probe.md`:
  - (a) whether add, list and read worked, and whether listing raised any prompt;
  - (b) the exit status and what is seen when `/usr/bin/security find-generic-password -s <svc> -a <acct> -w
    <file>` runs from Terminal (the agent's route). It must prompt and not print. Deny the prompt;
  - (c) `find-generic-password -s <svc> <file>` with no `-w`: exit 0, attributes, no prompt. Absent: 44;
  - (d) whether the temporary keychain appears in `security list-keychains -d user`;
  - (e) after `make app-bundle` twice, with an item written by the first build: what the second build's
    first read shows the operator;
  - (f) in the running app, on `e2e/fixtures/pages/form.html`, after typing `probe-pass-1` into its
    password field and leaving the tab: `grep -c probe-pass-1` over the org's
    `~/.wakil/orgs/<org>/browser/tabs/*.state` gives 0. Then the same with the field switched to
    `type=text` in the inspector, to know the edge.
- [ ] **Step 3: Decide.** If (b) prints the value with no prompt, **stop**. Ruling 1's argument fails, so
  ask the operator before Task 3. If (f) finds the value in a `type=password` field's state, add a task
  before Task 8 to write no tab state for a page with a filled password, and tell the operator.
- [ ] **Step 4: Write the spec amendment.** Body: rulings 1, 2, 5 and 6, and the findings, each dated.
  Edit the spec's body lines to match, as `docs/agents/workflow.md` requires.
- [ ] **Step 5: Delete the probe script, then commit** `probe: 3d-iv — the Keychain route and the tab state`.

### Task 2: The site key, naming, the generator and the offer (pure)

**Files:**
- Cherry-pick: `dfe256b` from `yehia-khalil/3d-i` (`BrowserSiteKey.swift`, `BrowserPublicSuffixes.swift`,
  `BrowserSiteKeyTests.swift`). Skip this if `main` already has `BrowserSiteKey`; rebase instead. Git drops
  the identical patch when 3d-i merges.
- Create: `app/Sources/WakilKit/Browser/BrowserPasswords.swift`
- Test: `app/Tests/WakilKitTests/BrowserPasswordsTests.swift`

**Interfaces:**
- Consumes: `BrowserSite.key(_:)` (`BrowserSiteConsent.swift`), `BrowserSiteKey.registrableDomain(_:)`.
- Produces:
  - `public struct BrowserLogin: Sendable, Equatable, Hashable { org: String; site: String; username: String; modified: Date? }`
  - `public enum BrowserPasswordOffer: Sendable, Equatable { case nothing, saveQuietly, askSave, askUpdate(username: String) }`
  - `public enum BrowserPasswords` with `static let identity = "default"`;
    `static func service(org: String, identity: String = identity) throws -> String`;
    `static func account(site: String, username: String) -> String`;
    `static func parseAccount(_ account: String) -> (site: String, username: String)?`;
    `static func check(service: String, account: String, org: String, site: String?) throws` (ruling 4);
    `static func siteKey(_ url: String) -> String?` (ruling 5);
    `static func strongPassword() -> String` and
    `static func strongPassword<G: RandomNumberGenerator>(using: inout G) -> String`;
    `static func offer(password: String, username: String, site: String, savedUsernames: [String],
    savedPassword: String?, never: Set<String>, suggested: String?) -> BrowserPasswordOffer` (ruling 7);
    `static func barQuestion(_ offer: BrowserPasswordOffer, username: String, site: String) -> String?`.
  - `public enum BrowserPasswordError: Error, Sendable, Equatable, CustomStringConvertible` with
    `badOrganisation(String)`, `badIdentity(String)`, `wrongOrganisation(expected: String)`,
    `noKeychainFile(String)`, `keychain(operation: String, status: Int32, message: String)`,
    `notFound(site: String, username: String, org: String)`. Its descriptions never take a password.

- [ ] **Step 1: Cherry-pick** `git cherry-pick dfe256b`, then run `make app-test`. Expected: green, with
  `BrowserSiteKeyTests` among the tests.
- [ ] **Step 2: Write the failing tests:**
  - `serviceNamesTheOrganisationAndTheIdentity`: `initech` gives `wakil:initech:browser-login:default`.
  - `anOrganisationWithAColonIsRefused`: `a:b`, `""`, `.x` and `-x` throw `.badOrganisation`.
  - `accountSplitsAtTheFirstSpace`: `github.com` with `jo smith` round-trips, and an empty username works.
  - `checkRefusesAnotherOrganisationsService`: `wakil:umbrella:…` checked against `initech` throws
    `.wrongOrganisation`. A matching service with another site's account throws too.
  - `siteKeyIsTheRegistrableDomainWithNoFamilies`: `https://www.github.com/login` → `github.com`;
    `https://gist.githubusercontent.com/x` → `githubusercontent.com`; `https://a.b.co.uk/` → `b.co.uk`;
    `http://127.0.0.1:8123/login.html` → `127.0.0.1:8123`; `http://localhost:8123/` → `localhost:8123`;
    `file:///x` and `about:blank` → nil.
  - `aStrongPasswordHasFourGroupsOfFive`: 1,000 draws all match `^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){3}$`,
    each has an upper case letter, a lower case letter and a digit, and no two are the same.
  - `offerFollowsTheOrder`: one case per branch of ruling 7, the suggestion beating the never list
    included.
  - `barQuestionCopy`: the three strings from Global Constraints.
- [ ] **Step 3: Run them to see them fail:** `make app-test`. Expected: `BrowserPasswords` is undefined.
- [ ] **Step 4: Implement** to rulings 3–7. Reuse Go's pattern string for the org and identity. Draw each
  character with `Int.random(in:using:)` over the 62-character alphabet, and draw again until all three
  kinds are present.
- [ ] **Step 5: Run them to see them pass:** `make app-test`.
- [ ] **Step 6: Commit** `browser: passwords — the Keychain name, the site key, a strong password, what a sent form is offered`.

### Task 3: The Keychain store

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserPasswordStore.swift`, `app/Tests/WakilKitTests/TemporaryKeychain.swift`
- Test: `app/Tests/WakilKitTests/BrowserPasswordStoreTests.swift`

**Interfaces:**
- Consumes: Task 2's naming, check and error.
- Produces: `public struct BrowserPasswordStore: Sendable` with
  - `public init(keychainFile: String?)`, and `public init(environment: [String: String])`, which reads
    `WAKIL_KEYCHAIN`, where an empty value means unset;
  - `func logins(org: String, site: String?) throws -> [BrowserLogin]`: attributes only, sorted by site,
    then by username;
  - `func password(org: String, site: String, username: String) throws -> String`;
  - `@discardableResult func save(org: String, site: String, username: String, password: String) throws -> BrowserSaveOutcome`,
    where `BrowserSaveOutcome` is `.added`, `.updated` or `.unchanged`;
  - `func rename(org: String, site: String, from: String, to: String, password: String?) throws`;
  - `func delete(org: String, site: String, username: String) throws`.
- `TemporaryKeychain` (tests): `init() throws` creates and unlocks a file keychain in a temporary
  directory with a random password, as `e2e/driver/launch.go:141-160` does. It has `path: String` and
  `func remove()`, which runs `security delete-keychain`.

- [ ] **Step 1: Write the failing tests** (each on its own `TemporaryKeychain`):
  - `aSavedLoginReadsBack`.
  - `savingTheSamePasswordIsUnchangedAndANewOneUpdates`.
  - `loginsListsAttributesOnlySortedBySite`.
  - `anotherOrganisationsLoginIsNeverReturned`: the same site and username saved in `initech` and
    `umbrella` with different passwords. Each org's `logins` and `password` see only their own.
  - `renameMovesTheItemAndDeletesTheOld`.
  - `deleteRemovesOneLogin`.
  - `aMissingLoginIsNotFoundNamingTheOrg`.
  - `aMissingKeychainFileIsRefusedNotReplaced`: the path does not exist, so `.noKeychainFile`, and no file
    is created.
  - `theStoreWritesOnlyToItsKeychainFile`: after a save, a second `TemporaryKeychain`'s store lists
    nothing.
  - `keychainErrorsNeverCarryTheValue`: a save on a locked keychain throws an error whose description does
    not contain the password (`security lock-keychain` first).
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement** with `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate` and `SecItemDelete`,
  using `kSecAttrService`, `kSecAttrAccount` and `kSecAttrLabel`. Run every result through
  `BrowserPasswords.check`. Build errors from the `OSStatus` and `SecCopyErrorMessageString` only. Leave a
  header comment that says why this file reads the Keychain in Swift when `ProviderCredentialsLookup.swift`
  says Swift doesn't (ruling 1).
- [ ] **Step 4: Run them to see them pass:** `make app-test`. No permission prompt may appear. If one
  does, the test touched a keychain it doesn't own.
- [ ] **Step 5: Commit** `browser: the password store — Keychain items that trust Wakil only, one service per organisation`.

### Task 4: The CSV parser

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserPasswordCSV.swift`
- Test: `app/Tests/WakilKitTests/BrowserPasswordCSVTests.swift`

**Interfaces:**
- Produces: `public struct BrowserImportRow: Sendable, Equatable, Identifiable { id: Int /* line */; title:
  String; site: String?; url: String; username: String; password: String; skipped: String? }` and
  `public enum BrowserPasswordCSV { static func parse(_ data: Data) throws -> [BrowserImportRow] }`. It
  throws `BrowserPasswordCSVError.noHeader` when the first record does not name `URL` and `Password`. It
  marks a row `skipped` per ruling 17, the duplicate-later-wins case included.

- [ ] **Step 1: Write the failing tests:**
  - `readsThePasswordsAppsColumns`: `Title,URL,Username,Password,Notes,OTPAuth`.
  - `headersMatchAnyCaseAndOrderAndExtraColumnsAreIgnored`.
  - `quotedFieldsKeepCommasQuotesAndNewlines`: `"a,b"`, `"say ""hi"""`, a quoted line break.
  - `crlfAndABomAreRead`.
  - `aRowWithNoUrlOrNoPasswordIsSkippedNotRefused`.
  - `aBareHostGetsHttps`: `github.com` → site `github.com`.
  - `anAppEntryIsNotAWebAddress`: `android://…` is skipped.
  - `theLaterOfTwoRowsForOneLoginWins`.
  - `aFileWithNoHeaderIsRefused`.
  - `theParserTakesBytesAndWritesNothing`: parse a temporary directory's file, and the directory's
    listing is unchanged afterwards.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement** an RFC 4180 reader over `String(decoding:as: UTF8.self)` with the BOM dropped,
  and `BrowserPasswords.siteKey` for the site.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: read the Passwords app's CSV export`.

### Task 5: The never list, and clearing data keeps passwords

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserOrgFiles+Passwords.swift`
- Modify: `app/Sources/WakilKit/Browser/BrowserOrgFiles.swift` (the doc comment's file list, and
  `BrowserClearDataQuestion.text`), `BrowserActions.swift` (`browser_clear_data`'s description: "bookmarks
  and saved passwords are kept"), `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (the `browser_clear_data`
  sentence)
- Test: `app/Tests/WakilKitTests/BrowserOrgFilesTests.swift`

**Interfaces:**
- Produces: `extension BrowserOrgFiles { func neverSave() throws -> [String]; @discardableResult func
  setNeverSave(site: String, on: Bool) throws -> [String] }`, which throws `BrowserNeverSaveUnreadable(reason:)`
  for a file that exists but won't parse.

- [ ] **Step 1: Write the failing tests:**
  - `neverSaveAddsRemovesAndStaysSorted`.
  - `anUnreadableNeverFileIsNeverWrittenOver`: the bytes are unchanged after the refusal.
  - `clearingBrowsingDataKeepsTheNeverList`.
  - The clear question's new copy (ruling 9).
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement** with an atomic write of a pretty-printed, sorted array.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: never save for a site; clearing browsing data keeps passwords`.

### Task 6: The actions, the scrub and the page seam

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserPasswordActions.swift`
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (build the store from `environment`, the scrub, and the
  decorator around `browserPageDriver`; new parameter `browserPasswordPage: (any BrowserPasswordPage)? =
  nil`; call `registerBrowserPasswordActions`; expose `WakilWiring.browserPasswords` and
  `.passwordScrub`), `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (five names and one sentence)
- Test: `app/Tests/WakilKitTests/BrowserPasswordActionsTests.swift`, `ActionClassificationTests.swift` (the
  pinned list), `AppWiringTests.swift`

**Interfaces:**
- Consumes: Tasks 2–5, `BrowserPageDriver`, `PaneStore.browserSnapshot(paneId:)`, `ActiveShellContext`.
- Produces:
  - `public protocol BrowserPasswordPage: Sendable { func fill(pane: String, tab: String, org: String,
    site: String, username: String, password: String) async throws; func suggest(pane: String, tab: String,
    org: String, site: String, password: String) async throws }`. Both act on the screen's canvas. They
    throw `BrowserPasswordPageError` (`.notShown`, `.siteChanged(now: String)`, `.noField`,
    `.failed(String)`).
  - `public actor BrowserPasswordScrub { init(cap: Int = 64); func remember(_ password: String); func
    scrub(_ read: BrowserPageRead) -> BrowserPageRead; func scrub(_ element: BrowserElement) -> BrowserElement }`
    (ruling 15).
  - `public struct BrowserScrubbingPageDriver: BrowserPageDriver { init(base: any BrowserPageDriver, scrub:
    BrowserPasswordScrub) }`. `read` and `describe` are scrubbed; `act` is passed through.
  - `func registerBrowserPasswordActions(into: ActionRegistry, panes: PaneStore, store: BrowserPasswordStore,
    scrub: BrowserPasswordScrub, page: (any BrowserPasswordPage)?, home: URL, activeOrg: @escaping
    @Sendable () async -> String)`. `pane` and `tab` are required: the key and the bar always know them.
- Handlers:
  - `fill` checks the tab's URL site key against `site`, and refuses with the copy when they differ. Then
    it reads `store.password(org: activeOrg(), …)`, calls `page.fill`, and calls `scrub.remember`.
  - `suggest` makes `strongPassword()`, calls `page.suggest` and `scrub.remember`, and returns no password.
  - `save` refuses an org with no `~/.wakil/orgs/<org>` directory. It remembers the password when `pane` is
    given, and it renames when `previousUsername` is given.
  - Every reply is `{org, site, username, outcome}` and never carries a password.

- [ ] **Step 1: Write the failing tests** (a `TemporaryKeychain` store, a recording fake `BrowserPasswordPage`,
  and a fake page driver):
  - `fillReadsTheActiveOrganisationsLoginOnly`: logins in `initech` and `umbrella`, `initech` active, and
    the fake receives `initech`'s value.
  - `fillRefusesWhenTheTabHasMovedToAnotherSite`: the store's tab is on `example.org`, so the copy is
    returned and the fake is not called.
  - `fillRefusesAMissingLoginNamingTheOrg`.
  - `suggestFillsAStrongPasswordAndRepliesWithoutIt`.
  - `saveAddsUpdatesAndRenames`.
  - `saveRefusesAnUnknownOrganisation`.
  - `deleteAndNeverWork`.
  - `everyPasswordActionIsOperatorOnly`: each of the five refused to an agent caller with the sentence.
  - `aSavedPasswordNeverReachesTheJournal`: save `walk-test-pass-1`, then fill it. No file under the journal
    directory contains it.
  - `readPaneCarriesNoPasswordAfterAFill`: `read_pane`'s JSON for the pane does not contain it.
  - `aReadHidesAFilledPasswordInTextAndValues`: after a fill, the decorator's read of a page whose text and
    a `type=text` element's value hold the password shows `••••••••`, and a 3-character password is hidden
    in values only.
  - `theStoreTakesWakilKeychainFromTheEnvironment` in `AppWiringTests`.
  - The classification list gains the five names.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: fill, suggest, save, delete and never — operator-only, a filled password hidden from the agent's reads`.

### Task 7: `wakil org rm` names the saved passwords

**Files:**
- Create: `internal/wakilcore/browserlogins.go`, `internal/wakilcore/browserlogins_test.go`
- Modify: `cmd/wakil/orgcmd.go` (`runOrgRm`, beside `BrowserStoreID` at :192), `cmd/wakil/orgcmd_test.go`

**Interfaces:**
- Produces: `func BrowserLoginsPresent(org string) (bool, error)`. It uses `keychainService(org,
  "browser-login:default")` and `keychainCommand("find-generic-password", "-s", service)`. Exit 44 gives
  false; any other failure gives `UserError` with `diagnostic`.

- [ ] **Step 1: Write the failing tests:**
  - `TestBrowserLoginsPresentReadsAttributesOnly`: a fake `security` through `WAKIL_SECURITY_BINARY`
    records its argv. It holds no `-w` or `-g`, and exit 0 gives true.
  - `TestBrowserLoginsAbsentIsNotAnError`: exit 44 gives false and no error.
  - `TestOrgRmNamesTheSavedPasswordsItLeaves`: stderr holds `wakil:initech:browser-login:default` and
    `Settings → Browser → Passwords`.
  - Exit 44 adds nothing.
  - A failed check prints `could not check the Keychain for its saved browser passwords: <err>`, and the
    org is still removed.
- [ ] **Step 2: Run them to see them fail:** `go test ./internal/wakilcore ./cmd/wakil -run 'BrowserLogins|SavedPasswords'`.
- [ ] **Step 3: Implement.** Check before `RemoveOrg`. The line reads: `its saved browser passwords stay in
  the Keychain under wakil:<org>:browser-login:default — next time, delete them first in Wakil (Settings →
  Browser → Passwords)`.
- [ ] **Step 4: Run them to see them pass:** `make build && go test ./internal/wakilcore ./cmd/wakil`.
  `TestEveryKeychainCallIsBuiltByKeychainCommand` stays green.
- [ ] **Step 5: Commit** `wakil org rm: name the organisation's saved browser passwords as residue`.

### Task 8: The page — script, key, list and save bar

**Files:**
- Create: `app/Sources/WakilApp/BrowserPasswordScript.swift` (the script, `world = .world(name:
  "wakil.passwords")`, `handlerName = "wakilPasswords"`), `BrowserPasswordMessages.swift` (one
  `WKScriptMessageHandler` per configuration, which resolves its tab by `message.webView`, so a pop-up
  sharing its opener's handler is heard as itself), `BrowserPasswordAgent.swift` (`BrowserPasswordPage`,
  made before the wiring, its host set after, like `BrowserPageAgent`), `BrowserPasswordViews.swift`
  (`BrowserPasswordKey`, `BrowserPasswordList`, `BrowserPasswordBar`)
- Create: `e2e/fixtures/pages/login.html`, `login-spa.html` (submit cancelled, then "Signed in" drawn),
  `signup.html` (username and two `new-password` fields), `signed-in.html`, `login-redirect.html`
  (navigates to `a.html` 1 s after load)
- Modify: `BrowserTabHost.swift` (`configuration` adds the user script at document end, main frame only, and
  the handler; the host holds `passwordFields[Key]`, `passwordOffers[Key]` and `pendingSuggestion[Key]`),
  `BrowserWebView.swift` (`didCommit` drops the tab's field report), `BrowserPane.swift` (the bar row over
  the page under the find bar; the key overlay on the page), `WindowSession.swift` (make
  `BrowserPasswordAgent` and pass it to `build`)

**Interfaces:**
- Script → Swift messages: `{kind: "field", role: "username"|"password"|"new", rect: {x, y, w, h}}`, then
  `{kind: "blur"}`, then `{kind: "submit", username, password, isNew}`. The script never posts a password
  except in `submit`.
- Swift → script, through `callAsyncJavaScript(_:arguments:in: nil, in: world)`, which passes values, never
  code: `wakilFill(origin, username, password)` and `wakilSuggest(origin, password)`. Each refuses with
  `"moved"` when `location.origin !== origin`, and with `"nofield"` when no field is found. Values are set
  with the native setter, and `input` and `change` events follow, as `BrowserAgentScript.nativeSet` does.
- On `submit`, the messages handler drops anything not from the main frame. It takes the site from
  `frameInfo.securityOrigin`. If the password equals the tab's `pendingSuggestion`, it dispatches
  `browser_password_save {org: scope.organization, site, username, password, pane, tab}` straight away.
  Otherwise it reads `logins` and, when the username matches, `password`, then sets `passwordOffers[Key]`
  from `BrowserPasswords.offer`. The bar's buttons dispatch `browser_password_save` or
  `browser_password_never`, and each one clears the offer.
- `BrowserPasswordAgent` refuses `.notShown` unless the screen's scope is a place of `org` and the tab is live
  there, and `.siteChanged` unless the live view's URL has the asked site key.
- The key's rect is the report's rect times `view.pageZoom`, in the page area's coordinates. A blur is kept
  for 300 ms, and dropped if the list opened meanwhile.

- [ ] **Step 1: Build the script, the handler and the fixtures.** Run `make build`. Expected: success.
- [ ] **Step 2: Build the key, the list and the bar** (rulings 11, 12 and 14, with the Global Constraints
  copy and identifiers). Run `make build`. Expected: success.
- [ ] **Step 3: Check the rules on paper, and write each in the commit body.**
  - Rule 1: the bar asks nothing destructive. *Never* can be undone in Settings.
  - Rule 5: the list's rows and the bar's buttons are disabled while their dispatch runs.
  - Rule 6: after a fill the page's field keeps the keyboard, and the bar never takes it.
  - Rule 8: a Keychain error shows whole in the list.
  - No autofill path exists: `page.fill` is called only from `browser_password_fill`.
- [ ] **Step 4: Smoke it by hand.** Serve `e2e/fixtures/pages` on `127.0.0.1:8123`, save a test login,
  then fill it. Throwaway screenshots go in `.scratch/3d-iv/`.
- [ ] **Step 5: Commit** `browser: the key in a login field fills on a press; a sent form offers to save or update`.

### Task 9: Settings → Browser → Passwords and the import

**Files:**
- Create: `app/Sources/WakilApp/BrowserPasswordsSettings.swift` (the list by site, reveal, copy, edit,
  delete, never saved), `app/Sources/WakilApp/BrowserPasswordImport.swift` (the sheet)
- Modify: `BrowserSettingsForm.swift` (one `SettingsSection("Passwords") { BrowserPasswordsSettings(org:
  organisationId, …) }`), and the place where `WakilWindow` hands the session to its views (an
  `EnvironmentValues.browserPasswords` entry set from `session.wiring.browserPasswords`)

**Interfaces:**
- Consumes: `BrowserPasswordStore.logins/password` (direct reads, ruling 10), `BrowserOrgFiles.neverSave()`,
  `BrowserPasswordCSV.parse`, `model.dispatchFromSurfaceThrowing` for `browser_password_save`, `_delete` and
  `_never`, and `ctx_list_orgs` for the import's picker.
- Reveal and copy follow ruling 16. Delete and Move to Trash ask in place (Rule 1). Edit opens its field
  focused (Rule 3) and saves on focus loss (Rule 2). Import's rows are listed by site, each with a `Picker`
  defaulting to `organisationId`. **Import** is disabled while it runs (Rule 5), and **Cancel** stops after
  the current row (Rule 4). Each row's refusal shows whole on that row (Rule 8).

- [ ] **Step 1: Build the list, reveal, copy, edit, delete and never saved.** Run `make build`. Expected:
  success.
- [ ] **Step 2: Build the import sheet and the Trash question.** The sheet's state is dropped on close, and
  no `write`, `copyItem` or temporary file appears in it. Run `make build`. Expected: success.
- [ ] **Step 3: Check Rules 1–5 and 8 on paper,** and write each in the commit body.
- [ ] **Step 4: Commit** `settings: Browser → Passwords — list, reveal, copy, edit, delete, never saved, import once`.

### Task 10: Docs, the walk, and the hand-off to Cover

**Files:**
- Modify: `docs/wakil/north-star.md`: §4 Invariant 4 gains one sentence, *"A saved browser password is a
  credential too: only in the Keychain, never the agent's, the store's, a file's or a log's."* §4 Invariant
  6's *Still refused* reads *"typed or filled by the agent"*. §8 adds a 3d-iv row, and the 3d row if 3d-i
  hasn't added it. Stay inside the word budget by replacing words, not adding them.
- Modify: `docs/wakil/decisions.md`: Decision 49's passwords paragraph (rulings 1, 2, 5 and 10). If 3d-i
  hasn't merged, write it under `## Decision 49` as a passwords-only subsection and fold it in at the
  rebase.
- Modify: `docs/wakil/design-language.md` §11's Browser row (the key and the save bar),
  `docs/architecture/state.md` (a Keychain row for `wakil:<org>:browser-login:<identity>`, read by
  `BrowserPasswordStore` in-process; amend "The Swift app never reads the Keychain directly";
  `passwords-never.json`), `docs/architecture/wakilkit.md` (Browser/), `wakilapp.md` (the views),
  `go.md` (`wakil org rm`), and `CONTRIBUTING.md`'s table row (browser passwords are the exception, with
  Decision 49 named)
- Create: `docs/wakil/phase-3d-iv-acceptance.md`, with the machine-walk markers and these rows
- Modify: `e2e/checks/uncoverable.tsv`: the reveal (LocalAuthentication), and the system prompt for another
  app's read

- [ ] **Step 1: Update the docs.**
- [ ] **Step 2: Write the walk.** Setup:
  ```bash
  make build && make app-bundle
  python3 -m http.server 8123 --bind 127.0.0.1 --directory e2e/fixtures/pages &
  python3 -m http.server 8124 --bind 127.0.0.1 --directory e2e/fixtures/pages &
  WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil
  ```
  Run in the worktree root. **A** is `personal` and **B** is `orgb`. Test passwords only. The CSV is
  `.scratch/3d-iv/passwords-test.csv`, written by the walk's setup with three fixture rows, one with no
  URL, and an extra column.

  | # | Do | Expect |
  |---|---|---|
  | 1 | Open `http://127.0.0.1:8123/login.html`, type `walker` and `walk-test-pass-1`, and press **Sign in** | `Save the password for walker on 127.0.0.1:8123?` at the pane's top. The signed-in page is usable under it. **Save** removes the bar |
  | 2 | Open `login.html` again. Wait, then click into the username field, press the key, and choose `walker` | Nothing is filled until the press. Then both fields are filled, and the keyboard stays in the page |
  | 3 | Sign in again with `walk-test-pass-2` | `Update the password for walker…` with **Update** and **Not Now** only. After **Update**, row 2's fill gives the new password |
  | 4 | On `http://127.0.0.1:8124/login.html`, sign in, then choose **Never for This Site**. Sign in again | No second bar. Settings → Browser → Passwords lists `127.0.0.1:8124` under *Never saved for*, and × takes it off |
  | 5 | Open `signup.html`, press the key in a password field, and choose **Suggest Strong Password**, then **Create** | Both fields hold the same `xxxxx-xxxxx-xxxxx-xxxxx`. No bar appears, and Settings lists the login |
  | 6 | After row 2's fill, ask the agent to read the page and to fill the password. Then, in Terminal: `grep -rl walk-test-pass ~/.wakil` | The read shows the password field with no value. The fill is refused with the operator-only sentence. The grep prints nothing |
  | 7 | ⌘⇧O → **B**, then open `login.html` on 8123 | No key in the fields, and Settings → Passwords reads `No passwords saved for orgb yet.` |
  | 8 | Back in **A**, Settings → Passwords: **Reveal**, **Copy**, **Edit** the password then click away, then **Delete** | Reveal asks for Touch ID or the Mac's password, once. The edit saves when focus leaves. Delete asks in place, and **Keep it** keeps the login |
  | 9 | **Import…** → the test CSV → **Import**, then answer the Trash question | Rows are listed by site with an organisation picker set to `personal`. The no-URL row is marked `no URL`. The receipt reads `Imported 2 passwords. Skipped 1.` **Move to Trash** moves the file |
  | 10 | In Terminal: `security find-generic-password -s wakil:personal:browser-login:default -a "127.0.0.1:8123 walker" -w`. Then rebuild (`make app-bundle`), relaunch, and repeat row 2 | macOS asks before `security` gets the value. Deny it, and nothing prints. After the rebuild, the first fill asks once (ruling 2), and **Always Allow** stops further asks |

  Known limits: a login form inside an iframe gets no key (ruling 11), and every rebuild asks again for each
  item (ruling 2).
- [ ] **Step 3: Run** `make build && make test && make app-test`. Expected: green, except the north-star word
  count, which stays unchanged or goes lower.
- [ ] **Step 4: Commit** `docs: 3d-iv passwords`.
- [ ] **Step 5: Hand the branch to the e2e auditor (Cover).** It should check:
  - save then fill on `login.html` and on `login-spa.html`;
  - nothing filled on load;
  - the fill refused after `login-redirect.html` moves;
  - a page's own `window.webkit` post is not heard (the handler lives in `wakil.passwords`);
  - update, never, suggest on `signup.html`;
  - the agent's `browser_read_page` after a fill, *show password* included;
  - `browser_type` into the password field still refused;
  - Settings list, edit, delete and never ×;
  - the import with the test CSV, with no CSV bytes under `~/.wakil`;
  - a second organisation sees nothing.

  **Ask the operator before using the screen.**
