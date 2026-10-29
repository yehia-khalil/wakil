# Agent-run e2e — probe

**Run 2026-09-23**, against the six items `2026-09-23-agent-e2e-design.md`
§14 pre-registered. Every verdict below was executed on this machine; nothing here
is inferred from documentation. Two items resolved **better** than the spec
assumed, one **corrects** the spec outright, and one splits into two answers where
the spec expected one.

Measured against the already-built bundle at
`~/orca/workspaces/wakil/provider-settings/app/Wakil.app`, with the operator's own
Wakil running throughout. Nothing the probe created survives it (§7).

---

## 1. Two concurrent instances — resolved, favourably

`open -n --env HOME=… --env TMPDIR=… --env PATH=… <bundle>` launches a second
instance alongside the operator's. Measured: pids `10429` (operator) and `44187`
(fixture) alive together, the fixture's `~/.wakil` created under the fixture `HOME`
and not under the operator's.

**Two findings the spec did not anticipate, both load-bearing:**

- **`--app dev.wakil.app` silently returns only ONE of the two instances.** With two
  Wakils running, `orca computer list-windows --app dev.wakil.app` listed the
  operator's window (id 26116) and not the fixture's. It did not error; it did not
  say a second existed. `--app pid:44187` addressed the fixture correctly (window id
  26252). §6.4's "address by `pid:`, never by bundle id" is therefore not a
  precaution but the only correct behaviour, and a harness that got this wrong would
  drive the operator's live credentials **with no error to warn it**.
- **A child started with `&` from a shell dies with that shell.** The first attempt
  launched the bundle binary directly in the background; it was gone by the next
  command, and every later call failed `app_not_found` — which read exactly like a
  capability limit and was not one. `open -n` detaches through LaunchServices and is
  the launcher the runner must use.

`open -n` also means the app inherits launchd's minimal environment, which is the
same fact `WindowModel` records for #238. `--env` is what makes that controllable,
and it is how the fixture `PATH` of §2 below reaches the app's Go children.

## 2. Keychain override — resolved, and no production change is needed

**Better than §6.2 assumed.** The spec proposed adding a keychain parameter to
`SecretSet`, and flagged a charter question if that failed. Neither is necessary.

All three Keychain invocations live in one file and resolve `security` **through
`PATH`** — `secrets.go:117`, `:143`, `:262`. There is no absolute-path invocation
anywhere in `internal/` or `cmd/`, and the Swift side never shells to `security` at
all. So a shim on the fixture `PATH` that appends the trailing `[keychain]`
positional redirects every generic-password call to a scratch keychain.

Verified end to end through the real Go path, not the CLI alone:

    printf 'govalue123' | env HOME=<fixture> WAKIL_ORG=probe-org \
      PATH=<fixture>/bin:/usr/bin:/bin  bin/wakil secrets set goprobe

    → stored "goprobe" in the keychain for org "probe-org"
    → find-generic-password … <fixture>.keychain-db   →  govalue123
    → find-generic-password … login.keychain-db       →  item could not be found

**The charter question in §14.2 is withdrawn.** Isolation is a different keychain
*file*, which is structural in exactly the sense Invariant 4 demands — not a naming
convention that a mistake could collide with.

This is also an existing repo idiom rather than an invention: four test files
already override `security` this way (`dbresolve_test.go:228`,
`httpclient_test.go:1140`, `jira_test.go:1338`, `secrets_test.go:190`).

**The dependency, and it holds.** The shim only works if the app's spawned Go
children inherit the fixture `PATH`. Measured: an `open -n --env` launch produced
`wakil-ctx` pid 49920 carrying

    HOME=<fixture>/home4
    PATH=<fixture>/bin:/usr/bin:/bin

so the shim reaches the children. The runner should still assert this before any
check runs — a launcher that dropped `PATH` would write into the operator's login
keychain, and that failure is silent.

**Corrected 2026-09-26 by [#301](https://github.com/yehia-khalil/rafiq/issues/301),
and the sentence that went stale is the first one.** *"There is no absolute-path
invocation anywhere in `internal/` or `cmd/`"* was measured and true on 2026-09-23.
[#201](https://github.com/yehia-khalil/rafiq/issues/201) made it false four days
later, for a good reason — the item's ACL trusts `/usr/bin/security` by name, so the
product has to invoke that name — and an absolute path does not consult `PATH`. The
shim went on working for everything that resolves `security` by name and stopped
reaching the product, silently, exactly as the paragraph below warns a dropped `PATH`
would.

So §8's row for 6.2 is **reversed**: the keychain parameter this probe withdrew is
what ships. `WAKIL_KEYCHAIN` names the keychain file and `wakilcore` passes it as the
trailing positional itself; the shim stays for `claude` and anything else the fixture
does not own. The probe's own reasoning survives intact — isolation is still a
different keychain *file*, structural in exactly the sense Invariant 4 demands, and
the withdrawn charter question stays withdrawn. What changed is who appends the
positional. See Decision 33.

**One trap for the runner while it does.** `pgrep -f wakil-ctx` matched children of
*three* different worktrees' bundles on this machine. Children must be matched by
full bundle path or by parent pid, never by binary name.

## 3. Acting on an unfocused window — splits in two

The spec asked one question and got two answers.

| Action | Steals the foreground? | Evidence |
|---|---|---|
| `click` (AXPress) | **Yes** | Arc frontmost → click on `pid:44187` → Wakil frontmost. Reproduced on a second control. A *failed* click left Arc frontmost, which rules out the measurement itself doing it. |
| `set-value` | **No** | Arc frontmost throughout; the value landed (`text field (settable), Value: Probe Org`). |

**So §12 softens.** It is not true that a run takes the screen. Field input, every
observation and the whole `read_pane` channel run in the background; only acts that
must genuinely be *clicks* — which is the parity subset, and the parity subset is
the point of Invariant 2 — take the foreground. The runner should prefer `set-value`
wherever the check is about state rather than about the click path, and mark the
foreground-taking checks as a named subset the operator can schedule.

**Also measured, and it hardens a design rule into a tool constraint.** Orca refuses
an index-based action that is not preceded by a fresh snapshot *for that app and
window*:

    element_not_found: element indexes require a fresh get-app-state
    snapshot for this app/window

§4's "resolve the identifier immediately before each act, never cache" is therefore
enforced by the tool, not merely advised by its guide.

## 4. Accessibility tree depth — answered for the data surface, and for the terminal (2026-09-23)

Answered by reading rather than by building state, because reaching a canvas pane
needs more than the probe had (see below).

`paneRowAccessibilityLabel` and `DataSurface.swift:662` settle it: each row is **one**
accessibility element labelled `"id: 1, name: widgets"`, carrying `.isSelected` when
selected — and **the row's cells are deliberately hidden** from the tree
(`.accessibilityElement(children: .ignore)`), because a `Grid` of `Text` views gave
VoiceOver nothing and a per-row label was the repair.

**The division of labour this forces, which the two-channel design already had:**
the tree answers *is it present, is it labelled, is it selected*; `read_pane`
answers *what does it contain*. A check asserting on a particular cell must go
through `read_pane`, and cannot go through the tree.

**The terminal pane's grid — MEASURED 2026-09-23 (#249), and it confirms the
division above.** With the fixture seed and the identifiers in place, a canvas
pane was finally reachable. Two terminal panes open, the window's tree is 51
elements, and the pane contributes this:

```
 9 text PROJECT
10 text /…/project
11 text ·          12 text zsh      13 text ·      14 text 80×20
16 button                                    <- pane.<id>.searchToggle
22 scroll area, Secondary Actions: scroll up, scroll down
   23 list, Secondary Actions: scroll to top, scroll to bottom
24 button
25 text ▸          26 text operator@example.com project %
29 text last 200 commands · 500 lines each
33 text resize
```

**The grid is not in the tree at all.** The live region's rows, the block
history's output, the prompt's contents beyond the `▸` and the prompt line
itself — none of it appears. What the tree carries is the pane's *chrome*: its
header path, shell and size, its search toggle, its scroll areas, and the
bound note. The history is a `list` with no rows exposed.

So §4's division of labour holds for the terminal exactly as it does for the
data surface, and for the same reason one level down: **the tree answers
whether a pane is present and what it is; `read_pane` answers what is in it.**
Every one of 2c-iii's mechanizable checks — a block carrying its exit code and
duration, characters echoing before Enter, `vim` leaving a block behind — is a
`read_pane` question, and that walk's check 15 already established `read_pane`
returns both surfaces as a union keyed by `kind`. Measured here:
`read_pane terminal-1` returns `{"shell":"zsh","cwd":"…","rows":24,"cols":80,
"blocks":[],"screen":"blocks","grid":[],…}`.

**One consequence for check authors, stated now rather than discovered later:**
a check that asserts on terminal output through `expect: {tree: contains}` will
pass or fail for the wrong reason, because the text it is looking for was never
a candidate. Terminal content assertions go through `read_pane`.

**A build-order consequence the probe surfaced.** A fresh fixture `HOME` opens on
the organisation plane: 9 elements, one anonymous button, *"NO ORGANISATION IS OPEN
· NOTHING BEHIND THIS PLANE"*. Reaching a canvas pane needs an org, then a session,
then a provider with a credential. **The fixture is therefore not just a `HOME`** —
it must carry seeded `~/.wakil` state and a stubbed provider, or no check can reach
a pane at all. §13's step 2 must build the seed, not only the flag.

## 4b. Identifiers are invisible to `get-app-state` — CLOSED 2026-09-23 (third run, #250), and it corrects the spec

**Spec §4 and #250 both say the driver "resolves identifier → element index from a
`get-app-state` taken immediately before each act". It cannot: that snapshot never
carries an identifier, under any flag.**

Measured with two throwaway programs kept at `scripts/probe/axidentifier/` — a
SwiftUI app drawing eight controls that differ in exactly one accessibility
attribute each, and an `AXUIElementCopyAttributeValue` walker that prints what is
really on them. Reading the two outputs side by side is the whole measurement.

| On the element | Set in SwiftUI by | In Orca's `treeText`? |
|---|---|---|
| `AXIdentifier` | `.accessibilityIdentifier` | **never** |
| `AXDescription` | `.accessibilityLabel`, or a `Button`'s own title | **no** — on a button. Yes on a text field |
| `AXHelp` | `.help` | no |
| `AXValue` | `.accessibilityValue` | **yes** — `button, Value: V1.token` |
| `AXTitle` | AppKit only; SwiftUI never sets it | **yes** — `button T7.token` |

The raw walk of the same eight controls shows every attribute present and correct,
so **`.accessibilityIdentifier` is not broken** — SwiftUI puts it on `AXIdentifier`
exactly as documented. What drops it is Orca's compact formatter, and for a button
that formatter emits `AXTitle` or `AXValue` and nothing else.

**This is not a flag away.** `orca agent-context --json` gives `computer
get-app-state` these flags and no others: `help, json, pairing-code, environment,
worktree, session, app, window-id, window-index, restore-window, no-screenshot`.
There is no verbosity, no attribute selection, and no `element-frames` subcommand
despite `capabilities` advertising `elementFrames: true`.

**The one channel that works today is the one that must not be used.**
`.accessibilityValue("pane.open.terminal")` renders as `button, Value:
pane.open.terminal` and needs no new machinery at all — but `AXValue` is spoken, so
every button would read its dotted token aloud. #250's premise is that identifiers
are *real accessibility and not test scaffolding*; a change that makes VoiceOver
worse to make a harness possible inverts it. Rejected on that ground, by the
operator, 2026-09-23.

**What replaces it, ruled the same day.** A read-only resolver owned by this repo:
it walks the accessibility tree of `pid:<n>` itself, finds the element whose
`AXIdentifier` matches, and returns its frame. The driver converts that screen frame
into the window space Orca's snapshot already reports (`coordinateSpace: "window"`,
with the window's own `x`/`y`/`width`/`height` beside it) and acts through `orca
computer click --x --y`.

Three properties earned that shape rather than the two alternatives:

- **Identifiers stay identifiers.** Nothing is added to a spoken attribute, so the
  accessibility claim survives intact and the set is still a VoiceOver improvement
  on its own.
- **All actuation stays in Orca.** The resolver never presses anything; it only
  looks. A helper that called `AXUIElementPerformAction` itself would be simpler —
  no coordinate arithmetic — but it would become a second write channel, outside
  the place where Orca reports `unverified (synthetic input)`.
- **Orca's own element indexing is never reverse-engineered.** The formatter
  flattens and drops container groups — nine drawn controls came back as a
  fourteen-element list with the `AXGroup` wrapper gone — so a resolver that tried
  to reproduce Orca's numbering would be a second copy of an undocumented rule,
  agreeing to stay in step until it quietly did not.

**What it costs, named rather than discovered later.** A new binary, and that binary
needs the Accessibility grant. In practice it inherits the terminal's — the probe's
walker read another app's tree with no prompt of its own — but a grant that goes
stale presents as every resolution failing at once, which is the failure mode
`docs/agents/` already records for Orca itself. The resolver must say so in its own
refusal rather than report "identifier not found".

**The 0-or-more-than-1 rule is unchanged and now lands on the resolver.** An
identifier resolving to no element, or to several, is a check failure and never a
retry.

## 4c. A fixture instance cannot be CLICKED under the app's own bundle id — measured 2026-09-23 (#250)

**Orca refuses every click on a second instance of a bundle id another running
instance also claims.** Coordinate clicks and element-index clicks alike, with
the same reply each time:

```
window_not_focused: coordinate click aborted because target pid N window M is no
longer the focused topmost recipient (current: no focused window); bring the
target window forward, run get-app-state again, and retry
```

**Everything else works on the same instance.** `get-app-state`, `press-key`,
`type-text` and `set-value` all returned `ok: true` against the very instance
whose clicks were refused. Only clicks — which is exactly the parity subset, the
part that exists to execute Invariant 2 rather than assert it.

### What it is not

Each of these was measured and excluded, in this order:

| Suspected | Measured |
|---|---|
| The machine, or this session | A bundled probe app clicked `ok: true` seconds before and after a refused Wakil click |
| Coordinates specifically | `click --element-index 4` was refused with the identical message |
| The window not being focused | `AXMain`, `AXFocused` and the app's `AXFrontmost` were all true, and `AXFocusedWindow` was set |
| Focus not reaching the right process | `System Events` reported the fixture's own pid frontmost, verified by unix id rather than by name |
| The windows overlapping | Moving the fixture window changed nothing |
| Two instances of one bundle, as such | Two instances of the probe app, bundled under one id, clicked fine |
| A stale Orca snapshot | A fresh `get-app-state` immediately before the click changed nothing |

### What it is

**The bundle id.** Holding the build, the fixture, the seed and the coordinates
constant and changing only `CFBundleIdentifier` to `dev.wakil.e2e`, the same
click returned `ok: true` and opened the pane it aimed at.

The mechanism is visible in one measurement: after `--restore-window`,
`NSWorkspace.frontmostApplication` moved from the fixture's pid to **a different
Wakil process** — another worktree's, running under the same
`dev.wakil.app`. Orca's `--restore-window` activates through the bundle, so it
brings forward whichever instance LaunchServices names; its click precondition
then finds the target window is not the frontmost one and declines.

**The refusal is correct.** A click is aimed at a screen, and Orca will not aim
one at a window it cannot establish as the target's. This is §6.4's finding —
bundle-id addressing silently resolves to one instance of several — arriving in
the *activation* path rather than in `list-windows`, and it is the same
dangerous direction: the instance it favours is the operator's.

### The consequence, and why it is not a workaround

**The runner stages a copy of the bundle under `dev.wakil.e2e` and launches
that** (`driver.StageBundle`). The copy lives inside the fixture, so teardown
removes it with everything else and two runs can never share one.

This makes §6.4 structural rather than observed. That section already requires
that a run never reach the operator's instance, and addresses by pid for exactly
that reason — but pid discipline only binds the components the harness calls
directly, and LaunchServices is not one of them. A distinct bundle id binds the
ones it does not control. It is the same move the Keychain isolation makes: a
different keychain **file**, not a naming convention.

**Nothing is re-signed, and nothing needs to be.** `Wakil.app` is never signed
as a bundle — `make-app-bundle.sh` assembles it around a Mach-O that `swift
build` already signed ad hoc, and puts `Wakil_WakilApp.bundle` at the .app's top
level where `Bundle.module` looks, which is what makes `codesign` refuse it
outright (*"unsealed contents present in the bundle root"*). Because no bundle
seal exists, editing `Info.plist` invalidates nothing. Measured: the staged copy
launches, spawns its five Go children, and passes the isolation guard.

### Proven end to end

Staged copy → seeded fixture → `window.openTerminal` resolved by identifier →
`ClickPoint` converted to window space → `orca computer click --x --y`
`ok: true` → `rail.terminal-1` and `pane.terminal-1.searchToggle` appeared in
the tree. That is #250's whole mechanism, against the shipped bundle.

## 5. `setup-token` substitutability — resolved, and it corrects the spec

**§7's browser stub is wrong as written.** It said "a fake `setup-token` binary on
the fixture `PATH`". That cannot work: `WindowModel`'s own doc comment for
`loginBinary()` records that **`executableURL` does not search `PATH`**, and that a
GUI launched from Finder inherits launchd's minimal one — which is why #238 made the
binary travel on the provider row as *"the only absolute path the app has"*.

The stub must therefore be **seeded into the fixture's provider record**, as the
`binary` field the row carries.

**That is the better mechanism, not a workaround.** Seeding the record exercises the
production resolution path — the accounts listing, the row, `loginBinary()` — so an
unwired dependency still fails the check.

**And a rule for the harness:** it must **never** install the stub by injecting
`providerLoginBinary`. That parameter exists so a test can pin a fake without a
listing behind it — it is precisely the defaulted-injectable class this whole harness
exists to catch (`providerMint` #204, `providerLoginBinary` #238), and a check that
set it would bypass the defect it was written to find.

## 6. Orca CLI resolution — resolved

`/usr/local/bin/orca` is a root-owned symlink, mode `lrwx------`. The CLI cannot read
its own link target through it and every invocation dies with *"Unable to determine
Orca.app path from symlink"* — including `--version` and `skills get`. Escalated
permissions do not help; the mode is on the link.

Every command in this probe ran through
`/Applications/Orca.app/Contents/Resources/bin/orca`. The runner must resolve the
executable deliberately and fail loudly if it cannot, rather than trusting `PATH`.

## 6b. `TMPDIR`, and the socket — CLOSED 2026-09-23 (second run, #248), and the answer is no

`open -n --env TMPDIR=…` **does** reach the app: the fixture process carried
`TMPDIR=<fixture>/tmp4` while the operator's carried the real one. What was left
unmeasured was whether `FileManager.default.temporaryDirectory` — which
`WindowSession` builds the socket path from — honours it.

**It does not.** Measured directly rather than through a launch, because the
question is Foundation's and needs no app:

    TMPDIR env               = <fixture>/tmp
    FileManager.temporaryDir = /var/folders/0h/…/T      ← the per-user dir
    NSTemporaryDirectory()   = /var/folders/0h/…/T/

Tried four ways, all identical: the injected directory absent; present at mode
0700; with and without a trailing slash; and as a short path under `/tmp` (to
rule out `sun_path`'s 104-byte limit being involved). Foundation resolves the
per-user Darwin directory via `confstr(_CS_DARWIN_USER_TEMP_DIR)` and never
consults the variable. So **the fixture's MCP socket lands in the same directory
as the operator's**, and §14.2's fallback applies.

**But the fallback as written — "the runner scans the real `$TMPDIR`" — should
not be built.** Two measurements say why:

- **Nothing unlinks a socket at exit.** The real `$TMPDIR` on this machine holds
  **69** `wakil-*.sock` files, dated back to 2026-09-18, and exactly **one** live
  app. `MCPSocketServer.start` unlinks a stale file at *its own* path, but the
  path carries a fresh session UUID every launch, so it never removes an earlier
  one. A scan picking the newest mtime is therefore choosing from a 69-deep pile
  of dead sockets, not resolving an ambiguity between two live ones.
- **`lsof` answers exactly.** `lsof -p <pid>` returns the one socket that pid
  holds, in one line:

      Wakil  68342  operator  3u  unix  0x…  /var/folders/0h/…/T/wakil-4A45…-…sock

  The runner already establishes a pid distinct from every pre-existing Wakil
  before any check runs (§6.4), so it has the exact input this needs.

**Consequence for #249:** find the socket by asking `lsof` for the fixture pid's
own socket. Never scan the directory, and never match by mtime or by name — that
is the same silent-wrong-instance failure §6.4 measured for `--app
dev.wakil.app`, in a channel that carries writes.

**A defect this surfaced, outside the harness's scope:** `WindowSession` never
unlinks its socket on exit, so every Wakil session leaks one file into the
per-user temporary directory permanently. 69 of them is the current cost. Filed
separately rather than fixed here.

## 6c. The seeded fixture reaches the Landing — measured 2026-09-23 (#248)

The seed of §6.1 exists, so the build-order consequence §4 raised is closed. A
seeded instance resolves and draws the Landing; the accessibility tree read off
the live window:

    0 standard window Wakil
      1 text ORGANISATION      2 text e2e-fixture     3 text e2e-project
      4 text STAGING           9 text CONTINUE · NEWEST FIRST
     10 text OPEN             12 text Nothing to continue in this project
     20 text ACCOUNT          21 text e2e-provider

25 elements, against the 9 of the unseeded organisation plane.

**The check was seen to fail before it was kept**, which is §8's rule applied to
the first check that had a choice: all five assertions of
`e2e/checks/seeded/landing.jsonl` go **red** against an unseeded instance (9
elements, nothing matched) and green against a seeded one. So it measures the
seed's effect and not merely the app's ability to draw.

**One trap worth naming:** the tree reports these labels **uppercased**
(`STAGING`, `CONTINUE · NEWEST FIRST`), because the views apply
`.textCase(.uppercase)`. The first version of the check asserted the source
casing and failed on two of five assertions for that reason alone. Assert the
text as the tree renders it, not as the Swift literal spells it.

**Two measurements that cost the seed an ordering, both found by executing
rather than by reading:** `CreateOrg` validates `defaultProvider` against the
org's registered providers while `AddProvider` needs the org directory to exist,
so the default provider can only be set after the provider; and
`SetProjectChecked` blanks an environment the incoming project does not declare,
so the environment and provider pick must be written after it.

## 7. What the probe left behind

Nothing. Both fixture instances (pids 44187 and 49915) were killed, each identified
by reading its `HOME` out of `ps -Ewww` rather than by name; the operator's two Wakils
were confirmed still running on the real `HOME` afterwards. The scratch keychain was deleted and never entered the keychain search
list, which still reads `login.keychain-db` and `System.keychain` exactly as before.
Both probe secrets were confirmed absent from the login keychain afterwards. All
fixture `HOME`s live under the session scratchpad.

## 8. Consequences for the spec

| § | Change |
|---|---|
| 6.2 | Keychain parameter not needed; fixture `PATH` shim instead. §14.2's charter question withdrawn. |
| 6.4 | Upgraded from precaution to measured necessity — bundle-id addressing silently resolves to one instance of several. Add: launch via `open -n`, never a backgrounded child. |
| 6.1 | The fixture must carry seeded `~/.wakil` state and a stubbed provider, not only `HOME`, `TMPDIR`, `PATH` and a keychain. |
| 7 | Browser stub moves from the fixture `PATH` to the fixture's provider record. Add the prohibition on injecting `providerLoginBinary`. |
| 12 | Softened: only the parity subset takes the foreground. `set-value` and every observation run in the background. |
| 4 | "Resolve immediately before each act" is tool-enforced, not advisory. |
| 13 | Step 2 builds the fixture **seed**, not only the flag. |
| 6.4 | Upgraded again: addressing by pid is necessary and not sufficient. A fixture instance must also carry its OWN bundle id, or Orca refuses every click on it. §4c. |
| 4 | "Resolve identifier → element index from a `get-app-state`" is **withdrawn** — that snapshot carries no identifier. Resolution moves to a repo-owned read-only AX resolver, and the act becomes a coordinate click. §4b. |
