# Phase 2b-vi acceptance — the provider picker

**Status:** **MET 2026-09-11.** Walked in full by the operator on a
MacBook Air M3, org `personal`, providers `main` (`~/.claude-personal`) and `second`
(`~/.claude-umbrella`), on `staging` and again on `production`. All three checks pass.
Four defects were found during the walk and all four were fixed before this row was
written — §5 records them. **The one gap this walk left open — dual-drive only partly
satisfied, because `ctx_set_provider` is headless and the live in-window swap is not —
was accepted as-is on 2026-09-15** and is no longer tracked as owed (`phase-log.md`,
"The 2026-09-15 acceptance") · **Spec:**
`docs/superpowers/specs/2026-09-10-phase-2b-vi-provider-picker-design.md`
· **CLI measured at:** `claude` 2.1.268 (2b-v's runbook pinned 2.1.266; nothing in this
sub-phase depends on the difference, and the version is recorded so a later failure has
a baseline to compare against)

`north-star.md` §8 draws the line this document exists to hold: a sub-phase whose value
is a human judgement gets marked **implemented**, and only a walked runbook marks it
**met**. 2b-vi is implemented. It is not met. **"The code is written" and "the phase is
done" are different claims, and only this runbook closes the second one.**

## 0. Why there are three checks and not ten

Four sub-phases in this repository — 2b-ii, 2b-iii, 2b-iv, 2b-v — produced runbooks that
went unwalked, part-walked, or were closed by an operator's decision without a single
check being run. The spec's §6 draws the obvious conclusion and this document obeys it:
**a ten-check runbook that is never walked establishes less than a three-check one that
is.** So there are three, and they are the three things no test in this repository can
answer:

1. **The switch** — does moving to another account read as deliberate, or as a failure?
2. **The seam** — does it read as a seam rather than an error, and does it avoid
   implying the new agent knows the conversation it did not have?
3. **The indicator** — is it legible without becoming noise, and are account and
   environment independently readable?

**What "implemented" already covers, so these three do not re-argue it.** The whole
headless half is green (§3): the Go command's success shape and every refusal it can
give; a test that the token appears in no refusal and no diagnostic; the derived service
name `wakil:<org>:provider:<id>` pinned against `keychainService` rather than re-spelled;
Swift's credential lookup against an injected fake, with no test touching a real
Keychain; every refusal `setProvider` can give; start-then-swap ordering, so a failing
`start` leaves harness, pump and thoughts untouched; the generation bump dropping
buffered events from the old pump after the seam; the seam row's content; and
`session_set_provider` being registered `.control`, kept off `agentAllowedTools`, and
denied at the permission gate when the agent asks for it anyway. That is the code being
written. It is not the sub-phase being done.

## 1. Prerequisites

Skipping one of these does not make a check fail cleanly — it makes it fail for the
wrong reason, which is worse than not running it.

1. **`make build`, first, before anything else.** `bin/` is per-worktree and **16 tests
   shell out to `bin/wakil-ctx`**; a worktree that has never run it fails those 16 for
   want of a binary rather than for want of a feature. This is not hypothetical:
   `phase-2b-iv-acceptance.md`'s H1 row records exactly this happening on a real walk
   ("Failed 16/295 on the first attempt purely for want of `make build`"), and says
   plainly that no runbook mentions it. This one does. Run `make build` and then
   `make app-test`, in that order, every time.
2. **`make app-bundle`**, same reason as every other 2b runbook: the bundle is what
   carries `wakil-ctx` and the rest into `Contents/Resources`, and `WakilWiring.binaryURL`
   has no fallback once it is running from one.
3. **Two providers registered under one org, both fully configured.** Checks 1 and 2 are
   a *switch*, so one account is not enough. For each of the two, per `operator-todo.md`
   §3:
   - `wakil provider add <id> --kind claude-code --config-dir <dir> --claude-path
     "$(command -v claude)" --org <org>` — **the `--claude-path` is new and is not
     optional**; a provider registered before 2b-vi has an empty `claudePath` and will
     refuse to launch;
   - `wakil secrets set provider:<id> --org <org>`, pasting the value from
     `env CLAUDE_CONFIG_DIR=<dir> claude setup-token`. Confirm both are readable before
     you start: `wakil provider credentials <id> --org <org>` prints the JSON (**it
     prints the token — do not do this on a shared screen or leave it in scrollback**).
4. **An active provider for the org**, which is `active.json`'s fourth axis and not an
   environment variable any more. Set it headlessly once:

   ```bash
   printf '%s\n' '{"action":"ctx_set_provider","params":{"name":"<provider id>"}}' \
       > /tmp/wakil-pick-provider.jsonl
   WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-pick-provider.jsonl
   ```

   It needs an active project already selected, the same as every other `ctx_*` write,
   and it writes to your real `~/.wakil` and your real journal.
5. **The launch command**, per `phase-2a-acceptance.md` §1 as this sub-phase rewrote it —
   one variable, not five:

   ```bash
   WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil
   ```

   **Exporting `WAKIL_PROVIDER`, `WAKIL_CLAUDE_PATH`, `CLAUDE_CONFIG_DIR` or
   `CLAUDE_CODE_OAUTH_TOKEN` in that shell now does nothing to the window**, and leaving
   a stale one set is a good way to convince yourself the old path is still live. Unset
   them (`env -u …`) before walking this, which also exercises the sub-phase's own exit
   criterion: a window launched with all four unset must still start a session.
6. **Something worth saying to the first account before you switch.** Check 2 asks
   whether the seam implies a continuity that does not exist, and that question is
   unanswerable unless a real conversation existed on the other side of it. Have a turn
   or two with the first account — something specific enough that you would notice the
   new agent not knowing it.

## 2. The three standing checks

**All three were walked on 2026-09-11** — each needed a running window, a real
subscription and a live `claude` process, none of which the automated suite is
permitted to touch. Results are in the rows below.

### Check 1 — the switch reads as deliberate

**Switch the window to the other account, and judge what that felt like.**

The switch is `session_set_provider`: it starts the new account's harness *first*, bumps
the event-pump generation, stops the old harness, clears the thread, appends the seam,
and only then adopts the new session id and provider. A refusal — a turn in flight, a
mutation parked at the confirmation plane, an unregistered id, an account with no stored
token, the account already running — lands in the status line and the session you had
carries on untouched. What none of that establishes is the thing this check asks: when
you switch, does the window read as *having done what you asked*, or as *having lost the
session*? A fresh session under a new account and a crashed session look alarmingly
similar from a distance — empty thread, no agent mid-thought — and the difference has to
be legible in under a second or the feature is a liability on the day it matters most (a
rate limit mid-task, which is exactly when nobody is in the mood to interpret a blank
window).

**Read this before you try to walk it — ⌘P is the route, ⌘K is not, and `--dispatch`
must never be either.** Task 12 (commit `5789d4a`) added a `.provider` kind to the ⌘P
palette (`WindowModel.openItems()` → `providerPaletteItems()`, backed by the new
`ctx_list_providers` action): open ⌘P and provider rows appear alongside panes, projects
and sessions, one per provider registered to the org. The row for whichever provider
this window is actually running under (`WindowModel.providerId`) is marked — its
subtitle carries "running" — so before you choose you can see which account is current.
Selecting a different row calls `setProvider` directly with the id already sitting on
that row (`runPaletteItem`'s `.provider` case), not through the registry's empty-params
dispatch, so the missing payload this section used to describe is no longer missing.
**That is the walk:** open ⌘P, note which row reads running, choose the other one, and
judge what the switch feels like against the question at the top of this check.

**⌘K still cannot drive this.** ⌘K lists every registered action and dispatches the
chosen one with **empty params** (`WindowModel.runPaletteItem` →
`dispatchLayout(item.payload, .object([:]))`), because the param-collecting second step
of a palette selection (2b-i's spec §6.1) was never built. Picking `session_set_provider`
from ⌘K therefore still produces `session_set_provider: missing required param
"provider"` in the status line and no switch at all — the same shape as the known
`pane_open` gap that the "Open pane" button exists to work around. ⌘P is the route; ⌘K
is not, and the agent is denied this action at the permission gate by design either way.

**Nor can `--dispatch`.** See §4's trap below: `session_set_provider` returns
`{"switching": "<id>"}` after parking into a broker that nothing drains headlessly — exit
`0` and a payload claiming success, for a swap that never happened in a process with no
window to swap. Walk this check in a real window or record it as unwalked; a headless
step here would certify a false result.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-11 | Walked by the operator via ⌘P, in **both directions and on both environments** — `main → second` and `second → main` on `staging`, and again on `production`. Provider rows appear alongside panes, projects and sessions; the running row is marked; selecting the other row performs the switch. It reads as deliberate: the thread clears and the seam lands in the same motion, so the empty thread is explained rather than merely empty — the "fresh session vs crashed session" ambiguity this check exists to test did not arise. ⌘K was not used and `--dispatch` was not used, per the two traps above. |

### Check 2 — the seam reads as a seam, and claims nothing

**Look at the thought thread immediately after a switch.**

On a switch, `thoughts` is cleared wholesale and one row is appended: label `account`,
detail `account changed: <the account left> → <the account joined>`, rendered with
`isError: false`. It is **not** a resume: a resume forks a parent transcript, and a
switch cannot, because transcripts live under the provider's own config dir and the new
account's `claude` cannot read a file under the old account's directory. The new session
is genuinely new, and the new agent has never seen a word of the previous conversation.

Two judgements, and they pull against each other:

- **Does it read as a boundary rather than as a fault?** `ThoughtThread` shows the last
  six rows and does not scroll (`design-language.md` §9), so straight after a switch the
  seam is alone on an otherwise empty thread, which is the most exposed a single row ever
  is in this app. An error row would sit in the same place.
- **Does it avoid implying continuity?** This is the one to be strict about. The row
  names both accounts and nothing else — deliberately, because anything warmer would be
  a lie: there is no handover in this sub-phase (spec §0 and §9 record it as designed,
  split out and owed). Ask the new agent something only the previous conversation knew.
  It should not know it, and the thread should have already told you it would not.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-11 | Walked with a real planted secret, which is the only way this check means anything. On `second`: *"remember 1+1 is yolo, its a code between us"* — the agent wrote it to `~/.claude-umbrella/projects/-Users-operator-wakil-acceptance/memory/user_code_1plus1.md` and confirmed. Switched to `main`. Asked *"hi, what is the code between us"* → *"Nothing yet — … No code has been written or discussed between us so far."* **The new account did not know it, and the seam had already said it would not.** The seam reads as a boundary rather than a fault. Note the structural reason, which is stronger than the agent's answer alone: the memory landed inside the *leaving* account's own config dir, so `main` could not have known it even had the thread implied otherwise — Invariant 4 doing the work the seam only describes. |

### Check 3 — the indicator is legible, and account and environment read independently

**The account indicator's entire visual acceptance is owed here.** Task 10's implementer
could not judge any of it: `screencapture -x` in that environment returns the macOS lock
screen (a live clock over a violet/blue wallpaper that resembles this app's own void
closely enough to have looked plausible for one capture), a limitation
`phase-2b-i-acceptance.md` and `phase-2b-ii-acceptance.md` already record for this
machine. Nothing below has been seen by an eye.

What it is, so you know what you are looking at: `ACCOUNT` in 8.5px uppercase at `.16em`
tracking — the same micro-label idiom as the thought thread's row labels — followed by
the provider id in monospace (§6: identifiers are always monospace), both in luminance
violet `#7c5cff`, the label at 0.55 opacity and the value at 0.9. It sits at the
**bottom-trailing** corner, sharing the thread's edge but not its corner. Violet rather
than white is a deliberate, single exception to §5's "text steps down by opacity, never
by hue", made because §5 reserves green, amber and red for environment semantics and
says they are never decorative anywhere — so the one hue left for a second axis of
meaning is the app's own accent.

Three things to judge, and the third is the reason the indicator exists at all:

1. **Legible without becoming noise.** Violet at 0.55/0.9 opacity over the void's own
   violet bleed is the risk: the void is not a flat backdrop, it drifts, and an indicator
   that disappears into a bleed for part of that drift is not permanent in any useful
   sense. Watch it through a full idle cycle, and while the Core is thinking.
2. **Does it collide with the unstyled message field?** It lands at the bottom edge
   beside 2a scaffolding the design language never described — a bare `TextField` and
   `Button` that no sub-phase owns (spec §8 records this as unowned, and says the picker
   will look wrong through no fault of its own). Judge the indicator, not the scaffolding
   — but if the scaffolding makes the indicator unreadable, that is a finding, and §8 of
   the spec is where it belongs.
3. **Are account and environment independently readable?** The environment badge is at
   the top, on the far plane, in white-or-red; the account is at the bottom-trailing
   corner in violet. The pair that matters is *this account, against this environment* —
   "work account against a personal project" is the same class of mistake as "production
   database". Can you read both, at a glance, without hunting? Try it on a production
   environment, where the badge turns red, and check that the red does not swallow the
   violet.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-11 | Judged on `staging` and then on `production`, which is the case that mattered. **The red does not swallow the violet.** On production the void itself carries the environment (2b-iv's room treatment), and the violet `ACCOUNT <id>` at the bottom-trailing corner stays clearly legible against it — the two axes are carried by *different things*, the room's hue versus corner text, so they read independently rather than competing for the same attention. No disappearance into the void's own violet bleed was observed on staging either. The collision with the unstyled 2a message field (spec §8) did not make the indicator unreadable; the scaffolding remains ugly and remains unowned. |

## 3. Headless checks

Everything here is scriptable and none of it substitutes for §2. Run it first: a failure
here means the three checks above cannot mean anything either.

```bash
make build          # FIRST. See §1.1 — 16 Swift tests shell out to bin/wakil-ctx.
go test ./...
make app-test
```

Measured on this tree on 2026-09-11: every Go package `ok`; `make app-test` reports
**405 tests in 1 suite**, then a second `swift test` invocation with **1 test in 1
suite** (`stopDeliversTheTailOfTheStreamRatherThanDiscardingIt`, run alone on purpose —
`phase-2b-v-acceptance.md` §3 explains why, and it is not a weaker suite).

```bash
printf '%s\n' '{"action":"ctx_set_provider","params":{"name":"<a registered provider id>"}}' \
    > /tmp/wakil-check-provider.jsonl
WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check-provider.jsonl
echo "exit=$?"
```

Expected: exit `0`, and the printed result is an **empty object**. That is the honest
answer and the reason this check is worth running: `ctx_set_provider` persists the pick
into `active.json`'s fourth axis and claims nothing more — it is bookkeeping, not a live
swap. Confirm the write landed by reading the file, not by trusting the exit code:

```bash
jq '.provider' ~/.wakil/orgs/<org>/active.json
```

**Warning, same as every `--dispatch` check here.** This writes to your real `~/.wakil`
and your real journal.

## 4. Dual-drive is only PARTLY satisfied, and this is where that is written down

Decision 9 requires every capability to be drivable from the UI and from a script, and
`north-star.md` records that dual-drive cannot be retrofitted. This sub-phase satisfies
it **for the bookkeeping half and not for the live swap**, and the gap is real:

- **`ctx_set_provider` — driveable headlessly, and honest.** It goes through the registry
  like anything else, journals like anything else, and `--dispatch` genuinely performs it
  (§3 above). Its empty-object result claims exactly what it did.
- **`session_set_provider` — NOT driveable headlessly.** `runDispatchFile`
  (`WakilApp/main.swift`) builds `WakilWiring.registry` directly and never constructs a
  `WindowModel`, so the `ProviderSwitchBroker` this action posts into has **no
  subscriber**. Per the broker's own doc comment a request with no subscriber is
  buffered, not dropped and not acted on, and the buffer is only ever drained by a window
  that called `requests()` in its initialiser. In `--dispatch` mode nothing ever does.

### The trap: do not "optimise" check 1 by scripting the switch

`session_set_provider`'s handler parks the request and then returns
`.object(["switching": <id>])` **unconditionally** — it does not, and structurally
cannot, wait to learn whether a swap happened. Headlessly, therefore:

```bash
# DO NOT USE THIS AS A CHECK. It reports success for a switch that never occurred.
printf '%s\n' '{"action":"session_set_provider","params":{"provider":"other"}}' > /tmp/x.jsonl
app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/x.jsonl
# → {"switching":"other"}, exit 0, and no account changed anywhere
```

Exit `0` and a payload saying `switching`, for a swap that did not happen, in a process
that has no window to swap. **A runbook step built on that would certify a false
result** — which is precisely the failure mode this whole document is written against.
The switch is walked in a real window or it is not walked. This is the same shape as
2b-v's `session_resume` `--dispatch` check, which survives in that runbook only because
it is explicit about proving registration and the reply contract *and nothing else*; the
difference here is that `session_set_provider`'s reply is not even a contract worth
proving, so no headless step for it appears in §3 at all.

## 5. Result

**Not yet run, as of 2026-09-11.** No check in §2 has been walked. This document records
what would establish the sub-phase, not what has.

What that leaves standing:

- **Established.** The headless half, in full — §0 lists it, §3 runs it, and it is green
  on this tree (405 Swift tests plus the isolated one; every Go package `ok`). The exit
  criterion's first half is verified by inspection: no code in `app/Sources` reads
  `WAKIL_PROVIDER`, `WAKIL_CLAUDE_PATH`, `CLAUDE_CONFIG_DIR` or
  `CLAUDE_CODE_OAUTH_TOKEN` to decide which account this window runs as; the surviving
  references are writes into a child process's environment, doc comments explaining that
  history, and one forward of a launch-time `WAKIL_PROVIDER` into `wakil-ctx`/`wakil-db`
  that feeds Go's advisory Selected-vs-Running note and decides nothing about the
  session (`AppWiring.build`).
- **Not established.** All three checks. Whether a switch reads as deliberate, whether
  the seam reads as a seam, whether the indicator is legible and independent of the
  environment badge. These are what the sub-phase is *for*.
- **Not established, and structural rather than merely unrun.** The exit criterion's
  second half — *a window launched with all four variables unset starts a session* — has
  not been observed in a running app. And check 1 has no affordance to walk it through:
  ⌘K cannot pass the provider id, and nothing else in the window can either (§2, check
  1). Until that is built, the live swap has been exercised by unit tests and by nothing
  else.

The honest answer to "can an operator switch account in the running app?" is: the
mechanism is built, tested and reachable from the registry, and there is currently no
control that hands it the one argument it needs.

---

## 5. What the walk found

Four defects, none of which any test in this repository would have caught, and all
four fixed before the status line above was written. This section is the argument for
walking runbooks rather than accepting sub-phases: every one of these was invisible to
410 passing Swift tests and a green Go suite.

### 1. Two things on one edge were both called ACCOUNT — fixed, `8d353ce`

The switch seam's thought-thread row label (bottom-leading) and the account
indicator's micro-label (bottom-trailing) rendered the same word in the same 8.5px
tracked uppercase idiom, in the same horizontal band, about 1400pt apart. They mean
different things: the seam is **news** (a switch happened once, and scrolls out of the
six-row thread), the indicator is **state** (which account you are on right now,
permanently — the entire reason Task 10 exists). Two identical words for news and
state means neither reads as either.

The seam's label became `session`, which is what the row marks. Its detail dropped the
now-redundant `account changed: ` prefix at the same time: it reads `SESSION main →
second`.

### 2. A provider row was indistinguishable from a session row — fixed, `12547bd`

No row kind in ⌘P named itself, because until 2b-vi no two kinds shared a vocabulary.
Provider rows broke that: a session's subtitle is the provider id it ran under, and a
provider's title is that same id. Typing `main` returned four session rows subtitled
`main` above one provider row titled `main`, separated only by reading
`claude-code · running` carefully. Provider rows now lead with their kind —
`account · claude-code · running`.

### 3. A Keychain secret ending in a newline came back as hex — fixed, `a651e04`

The one with teeth beyond this sub-phase. `security find-generic-password -w` does not
always print the bytes it stored: when the value is not a plain printable string it
prints lowercase hex instead, **with no marker of any kind**. Every step that could
have caught it reported success — the write succeeded, the read succeeded, `claude
auth status` said `loggedIn: true` because a token was *present* — and the only symptom
was a `401 Invalid bearer token` on the first real turn, arriving nowhere near the
paste that caused it.

`readSecretValue` had deliberately stripped exactly one trailing terminator so that a
secret whose own last byte is a newline (a PEM key, per the CLI's help text) could
round-trip. It never could. That intention is what created the defect it was written to
avoid.

Fixed in three places, and the third one matters most: `SecretSet` normalises too, not
only `cmd/wakil`'s stdin reader, because `design-language.md` §14 says the Phase 2
Settings UI "writes the same Keychain entries" — a UI has no stdin, would call
`SecretSet` directly, and would have reintroduced the whole thing from a text field
carrying a newline. The operator asked exactly that question, which is why the fix
moved to the store.

**A note on the first version of that fix, because the lesson is general.** It guessed
hex from the value's shape — "even length and all hex digits" — and this repository's
own suite killed it in minutes: `httpclient_test.go` authenticates with
`0123456789abcdef01`, which is even-length, entirely hex digits, and an utterly
ordinary secret. It was decoded into nine bytes of binary and the request died with
`invalid header field value`. A hex-encoded value and a value that looks like hex
cannot be told apart by inspection, so the encoding is now **asked for** (`security -g`
marks it with an explicit `0x` on stderr) rather than inferred. That case is pinned.

### 4. Both provider tokens were corrupt from a wrapped paste — operator data, repaired

Not a code defect, and worth recording because the *diagnosis* took an hour. Both
tokens carried two newlines **and two spaces embedded mid-string**: `claude
setup-token` printed a 108-character token across three terminal lines, and the mouse
selection captured the visual wraps as real characters. 112 stored, four of them junk.

Defect 3 hid it. While the value came back as hex, `claude` reported an opaque `401`;
once it received the real bytes it reported `Invalid Authorization header value from
CLAUDE_CODE_OAUTH_TOKEN: it contains a line break at character 39 (112 characters on 3
lines)` — which names the fault exactly. That improvement is the clearest evidence
defect 3 was worth fixing.

Repaired by stripping the whitespace and **verifying the result against the real API
before writing it**, so no re-login was needed.

**Closed, and better than the warning first proposed.** A warning still leaves the
operator to act on it. `wakil provider credentials` now strips whitespace from the
token outright — interior included — so a wrapped paste simply works.

It is done THERE and not in `SecretSet`, and the distinction is the whole point: an
OAuth token cannot contain whitespace, so removing it can only restore the value, while
`SecretSet` takes secrets of every kind and a database password containing a space is
an ordinary thing to store (`wakil secrets set-db` stores exactly those). Knowing what
the value *is* is what makes stripping legal. A token that is *entirely* whitespace is
refused rather than handed over as an empty credential, and both cases are pinned.
