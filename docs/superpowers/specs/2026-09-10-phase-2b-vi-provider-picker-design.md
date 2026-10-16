# Phase 2b-vi — the provider picker

**Status:** design, not implemented · **Phase row:** `north-star.md` §8, 2b-vi

The session's Claude account is chosen in the window and read from the org's provider
record. `WAKIL_PROVIDER`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN` and
`WAKIL_CLAUDE_PATH` stop being launch-time environment variables.

---

## 0. What this sub-phase is not

**It is not the handover.** Switching provider mid-session starts a genuinely new
conversation under the new account, with a visible seam. Carrying the prior conversation
across the account boundary — as a Wakil-written handover document, not as a copied
transcript — was designed alongside this in the same brainstorming session and
deliberately split out, for the reason 2b split on 2026-09-08 and 2b-iii split on
2026-09-09: "pick a provider" and "hand over a conversation" are two specs, and written
as one the second would rot before the first shipped.

The split is also ordered for failure. The picker is what removes four environment
variables; the handover is a refinement on top. Implementing the picker first means a
problem in the handover work strands a nice-to-have rather than the migration.

§9 records the handover design as owed, so the decision is not lost.

**It is not the crude-controls cleanup.** See §8.

---

## 1. Why the premise "first Keychain access from Swift" turned out to be false

`north-star.md`'s 2b-iii split note (2026-09-09) describes this sub-phase as *"touching
the Keychain from Swift for the first time — its own risk surface entirely."* That framing
is wrong, and the correction is the reason this design looks the way it does.

`internal/wakilcore/secrets.go` does not use the Security framework. It shells out to the
`security` CLI, and it carries measured knowledge that a second implementation would have
to re-derive:

- `find-generic-password` exits **44** for a missing item (`errSecItemNotFound`), measured
  against a throwaway keychain.
- The service name is `wakil:<org>:<ref>` and the account attribute is the constant
  `"wakil"` for every item — so **the service name is the only place org scoping can
  live.**
- `security` accepts `/`, `..`, `.`, `""`, `my org`, `orgé` and an embedded newline as the
  org component and round-trips values byte-for-byte, so the org validation exists for the
  `:` delimiter, not because the tool cares.
- There is deliberately **no fallback** to the older unscoped `wakil:<ref>` name: a
  Keychain item carries no org, so a fallback could not distinguish this org's old secret
  from another org's, and would hand over whichever exists.

That last point is the decisive one. A Swift reimplementation that drifted from this
scheme would not fail loudly — it would return **the wrong org's credential**, which is
exactly the cross-org sharing the 2026-09-06 decoupling was written to end.

So Swift does not read the Keychain. Go does, as it already does, and Swift asks it.

**Two further reasons, both independent of the above:**

1. **It keeps 2b-vi and 2b-vii apart.** `SecItem` from an app running the hardened runtime
   pulls in `keychain-access-groups` entitlements and a signed-identity story. 2b-vii is
   where signing is decided and it has a known external blocker — no *Developer ID
   Application* certificate on this machine. A provider picker that depended on entitlement
   work could not ship ahead of a sub-phase that cannot currently finish.
2. **It is testable today.** The Go path has a gated real round-trip test
   (`WAKIL_KEYCHAIN_TEST=1 go test ./internal/wakilcore/ -run TestKeychainRoundTrip`),
   excluded from every agent run by design. Swift has no equivalent and the app suite is
   forbidden from touching the real Keychain, so a Swift implementation would ship
   essentially unverified.

**The one real cost, stated plainly:** the token crosses a process boundary on stdout.
This is not a regression — today the same token crosses the same kind of boundary as
`CLAUDE_CODE_OAUTH_TOKEN` in a child process's environment, which is no better protected.
§2.3 says what constrains it.

**Where this design would be wrong:** if Wakil.app ever had to work with no `bin/`
present. Everything else in the app already assumes those binaries, so that is
hypothetical today — but it is the condition under which §2 should be revisited.

---

## 2. The credential path

### 2.1 What the provider record gains

`Provider` (`internal/wakilcore/provider.go`) gains one field:

```go
ClaudePath string `json:"claudePath,omitempty"`
```

**Why `claudePath` is a record field and not an environment variable.** It is the third
variable `providerCredentials` requires today, and the phase row named only the other two.
Leaving it behind would mean this sub-phase removes three variables and quietly keeps a
fourth — the kind of half-migration that is forgotten until it breaks. It is also
genuinely per-provider: a `codex` or `local` provider is a different binary entirely, not
a different account for the same one.

**Why it is not a secret.** A path is not a credential. Putting it in the Keychain would
mean a Keychain read to answer "which binary", which is both slower and misleading about
what is sensitive.

### 2.2 Where the token lives

`wakil:<org>:provider:<id>` — the existing `security` service-name scheme, with the ref
**derived from the provider id** rather than stored as a `tokenRef` field.

**Why derived.** `validateProviderToken` already reuses `orgFileTokenPattern` with the
comment *"a provider id and an org id have the exact same filename and Keychain-token
constraints"*. The constraint needed for a derived ref is already enforced, and was
enforced in anticipation of exactly this. A stored `tokenRef` would add a second string
that can disagree with the filename, which is the failure mode `Provider.ID`'s own
`json:"-"` was written to avoid ("the file's basename, not a field in the file, so the two
cannot disagree").

**What derivation forecloses:** two providers cannot share one token. That is correct —
two providers sharing an account are one provider with two names, and `AddProvider`
already refuses two providers sharing a config dir for the same reason.

Stored with the existing command, unchanged:

```
wakil secrets set provider:<id> --org <org>
```

### 2.3 The new command

```
wakil provider credentials <id> --org <org>
```

Emits one JSON object on stdout:

```json
{"configDir":"/Users/…/.claude-personal","claudePath":"/…/claude","oauthToken":"…"}
```

**Refusals**, each naming the fix rather than only the fault:

| Condition | Behaviour |
|---|---|
| Provider id not registered in this org | exit 2, names `wakil provider list --org <org>` |
| Provider kind is not `claude-code` | exit 2, says session launch is only automated for `claude-code` |
| No token in the Keychain | exit 2, names `wakil secrets set provider:<id> --org <org>` verbatim |
| Keychain read fails for any other reason | exit 2, carries `security`'s stderr through `diagnostic()` |
| `configDir` no longer exists | exit 2 — a config dir deleted after registration would launch `claude` into a fresh account |

**Constraints on the token, which are the whole reason this command is separate from
`provider list`:**

- The token appears **only** in the success JSON on stdout. No refusal path, no
  diagnostic, and no log line may contain it — `secretscrub.go` is the existing mechanism
  and this command must route its errors through it.
- The command must not be added to any MCP server's tool surface. It is a launch-time
  lookup for the app, not a capability an agent may call. An agent that could read the
  token could launch sessions outside the write gate entirely.
- `--dispatch` runbooks that print command output must not print this one.

### 2.4 What Swift does with it

`providerCredentials(from environment:)` in `WindowModel.swift` is **deleted**, not kept
alongside a new path.

**Why deleted rather than kept as a fallback.** A fallback that still reads
`CLAUDE_CODE_OAUTH_TOKEN` when the record lookup fails means the environment variables
never actually stop being launch-time — they become the quiet path that gets used whenever
the new one is inconvenient, and the migration is never finished. This is the same
reasoning `secrets.go` gives for refusing an unscoped-name fallback: a fallback that
papers over a missing migration prevents the migration.

Its replacement is a lookup closure, injected the way `harnessFactory` already is, so
tests supply a fake rather than a fake environment. `ProviderCredentials` keeps its shape;
only its source changes.

**`WAKIL_ORG` stays an environment variable.** That is deliberate and dates to
2026-09-06 — org identity is declared by whatever launches the app, with no fallback. This
sub-phase does not touch it.

### 2.5 Which provider a window opens under

From the org's `active.json`, alongside org, project and environment — a fourth axis on a
file that already holds three, resolved the same way and by the same code.

`WindowModel.providerId` is currently `let`, with the comment *"saying which is why is
2b-vi's hook"*. It becomes `var`, maintained by §3's action.

---

## 3. The switch

### 3.1 Shape

`harnessFactory` becomes `@Sendable (ProviderCredentials) -> AgentHarness?`. It currently
takes no arguments and closes over credentials captured once at window start
(`WindowSession.swift:111`), which is precisely what makes a switch impossible today.

A new **`.control`** action, `session_set_provider`, taking `{"provider": "<id>"}`. It runs
through the registry and journals like every other action, so ⌘K and a `--dispatch` script
do the same thing and produce the same journal line — Decision 9's dual-drive requirement,
which cannot be retrofitted.

### 3.2 Ordering — reuse `resume()`'s, do not re-derive it

The swap reuses `WindowModel.resume(sessionId:)`'s ordering verbatim:

1. Start the new harness **first**. Nothing about the running session is touched until
   `next.start` has returned successfully.
2. Bump `eventPumpGeneration` **before** `await harness?.stop()`.
3. Only then replace `harness`, `sessionId`, `providerId` and `thoughts`.

Both orderings are load-bearing and both were found by review rather than by design
(findings 1 and 2 of the 2026-09-10 acceptance review). Start-then-swap exists because an
earlier stop-then-start lost the working session outright when `start` threw. The
generation bump exists because `stop()` waits for stdout to become buffered events, not
for this window to drain them, and `Task.cancel()` does not stop an `AsyncStream` from
delivering values already in its buffer.

`resume()`'s doc comment says **"Do not 'fix' this back to stop-then-start."** That
applies here unchanged, and this spec restates it so a reader of `session_set_provider`
alone does not have to find it.

**One difference from `resume()`, and it is the important one.** A resume forks from a
parent transcript under the *same* provider. A provider switch cannot: transcripts live
under the provider's own config dir (`sessions.go`'s `providerSessionsRoot`), so the new
account's `claude` cannot read a transcript filed under the old account's directory. This
is why `resume()` refuses when `thread.provider != providerId`, and that refusal stays
exactly as written. The new session starts fresh.

### 3.3 Refusals

All land in `status`, never thrown — same as `resume()`'s, and for the same reason: this
is reached from a palette selection, which has nowhere to throw to.

| Condition | Why it refuses rather than proceeding |
|---|---|
| A turn is in flight | The swap would abandon a turn the operator is waiting on |
| A `.mutate` proposal is parked | The proposal belongs to an agent about to stop existing; expiring it reaches that agent as a refusal it cannot interpret |
| Provider id not registered in this org | Nothing to switch to |
| Provider has no stored credentials | §2.3's refusal, surfaced verbatim so the operator sees the `wakil secrets set` to run |
| Provider already running in this window | No-op dressed as an action is worse than a refusal |

**Why refuse rather than queue.** A queued switch needs a deferred-state machine nothing
else in the window has, and it defers a decision the operator can simply re-make in a few
seconds. Refusing costs one wait; queueing costs a mechanism.

### 3.4 The seam

`thoughts` is cleared and a seam row is appended naming **both** accounts — the one left
and the one joined.

The seam must not read as an error, and must not imply continuity that does not exist:
the new agent has never seen the prior conversation and cannot be made to. That is a
judgement, and it belongs in §7's runbook rather than in a test.

---

## 4. The indicator

Always visible, at the bottom edge, where `design-language.md` §9's thought thread and
§12's waveform already attach.

**Why always visible rather than on demand.** "Work account against a personal project" is
the same class of mistake as "production database", and the design language already gives
production a permanent alarming treatment rather than a warning at the point of use.

**One hard constraint.** §5 reserves green (`#8be0c8`), amber (`#e8b45a`) and red
(`#e85c5c`) for environment semantics and states they are **never decorative, anywhere**.
The account indicator therefore cannot use them. It gets luminance violet (`#7c5cff`) and
text opacity, per §5's rule that text steps down by opacity and never by a different hue.

Account and environment must remain **independently** readable — the pair that matters is
"which account, against which environment", and an indicator that blended them would make
the dangerous combination harder to see, not easier.

---

## 5. What this changes in existing documents

**`design-language.md` §14 is stale and this sub-phase must amend it.** Its scope table
gives the Organization *"Claude account / config dir"* — singular, written before the
2026-09-06 org/provider decoupling established that one org may hold several providers.
The row should name the provider set, not one account.

**`operator-todo.md` §3** describes provider setup ending at `wakil provider add`. It
gains the token step (§2.2) and the `claudePath` field (§2.1). Its instruction to keep
tokens in `~/.claude-tokens.zsh` is superseded: after this sub-phase the token belongs in
the Keychain, and the shell file should be emptied rather than left as a second source of
truth. **The rotation item at line 417 is still owed and is not closed by this work** —
those two tokens were pasted into an agent transcript on 2026-09-07 and moving them into
the Keychain does not un-expose them.

**`phase-2a-acceptance.md`** documents the three variables as part of the launch command
for its standing checks. Those launch commands change.

---

## 6. Testing

### Headless — Go

- The command's JSON shape on success.
- Each refusal in §2.3, by exit code and by the fix it names.
- **A test that the token appears in no refusal path and no diagnostic.** This is the one
  that matters most and is easy to omit.
- The derived service name is exactly `wakil:<org>:provider:<id>`, pinned against
  `keychainService` rather than re-spelled, so a change to the scheme fails here.
- The real Keychain round trip stays behind the existing `WAKIL_KEYCHAIN_TEST=1` gate and
  out of every agent run.

### Headless — Swift

- Credential lookup against an injected fake; no test shells out to `wakil` or reads a
  Keychain.
- Every refusal in §3.3.
- Start-then-swap ordering: a failing `start` leaves harness, pump and thoughts untouched
  — the direct analogue of the resume test that pins finding 2.
- The generation bump drops buffered events from the old pump after the seam.
- The seam row's content, and that `providerId` follows the swap.
- `session_set_provider` is registered as `.control`, and is **absent** from
  `agentAllowedTools` — an agent must not switch its own account.

### Not testable headlessly

Whether the switch reads as deliberate rather than as a failure, whether the seam reads as
a seam rather than an error, and whether the indicator is legible without becoming noise.
These go to `docs/wakil/phase-2b-vi-acceptance.md` as standing checks.

**Given four sub-phases whose runbooks went unwalked or unrun, that runbook should be
short.** A ten-check runbook that is never walked establishes less than a three-check one
that is. Three checks: the switch, the seam, the indicator.

---

## 7. Exit criterion

> The session's Claude account is chosen in the window and read from the org's provider
> record; `WAKIL_PROVIDER`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN` and
> `WAKIL_CLAUDE_PATH` are not read by anything at launch.

Verifiable two ways, and both are required:

1. `grep -rn 'CLAUDE_CONFIG_DIR\|CLAUDE_CODE_OAUTH_TOKEN\|WAKIL_CLAUDE_PATH\|WAKIL_PROVIDER' app/Sources`
   returns only **writes to a child process**, never a read of Wakil's own environment.
   Exactly three sites survive, and they are correct because a child still needs these
   variables even once Wakil stops taking them from its own environment:

   | Site | Why it survives |
   |---|---|
   | `ClaudeCodeCLIHarness.swift:104-105` | Builds the `claude` child's environment from `buildLaunch`'s parameters. The values now originate in the provider record instead of Wakil's environment; this code does not change |
   | `WindowModel.swift:355` (`agentMCPConfigJSON`) | Writes `WAKIL_PROVIDER` into each MCP server's environment — spec §2.4's mechanism. Its `provider` argument now comes from the record |
   | `AppWiring.swift:319` (`childProcessEnvironment`) | Forwards `WAKIL_PROVIDER` to child processes. **This one does change**: it currently *reads* `environment["WAKIL_PROVIDER"]`, and must take the provider as a parameter instead |

   The sites that must be **gone**, all of them reads: `WindowModel.swift:301, 305-307`
   (`providerCredentials`, deleted per §2.4), `WindowModel.swift:1538`, and
   `WindowSession.swift:104, 158, 182`.

2. A window launched with all four variables **unset** starts a session successfully.
   `WindowSession.swift:158`'s note — *"WAKIL_PROVIDER is not set, so this window's
   provider id is empty"* — must no longer be reachable, because an unset variable is no
   longer how a provider goes missing.

The second is the real one. The first can pass while a read hides behind a computed name.

---

## 8. An open item this sub-phase surfaces but does not own

**The crude controls have no owner.** `WakilWindow.swift` still carries bare, unstyled
`TextField`+`Button` pairs at lines 361, 365, 372 and 634 — project, environment,
read-only query, and the message to the agent. They are 2a scaffolding ("one crude pane",
`north-star.md` §8), and 2b-ii styled the room around them — void, planes, Core, thread —
without touching them.

Of the four:

- **query (372)** belongs to 2c's "DB pane in full".
- **project and environment (361, 365)** duplicate what the rail already does, and 2b-i
  delivered the rail.
- **the message field (634)** is named by no sub-phase at all. §12's voice work is 2d and
  is about speech, not this.

Two of the four are unowned, which is the same pattern that produced four unwalked
runbooks: something real, never assigned to anyone.

**Why it matters here specifically.** §4's indicator lands at the bottom edge, immediately
beside the unstyled message field. The picker will look wrong through no fault of its own,
and an acceptance check asking "is the indicator legible" will be answered against a
control the design language never described.

Recorded here; it needs a home in the phase map, and this sub-phase is not it.

---

## 9. Owed: the handover

Designed alongside this and split out (§0). The shape agreed:

- **Wakil writes the handover, not the outgoing agent.** `readThread` already reads a
  session's transcript — that is how 2b-v rebuilds a thread — so Wakil can build the
  handover itself. Asking the outgoing agent to summarize gives better prose but fails in
  the case that most often motivates a switch: a rate limit, which is exactly when that
  agent cannot produce a turn.
- **Nothing is copied between config dirs.** The handover is Wakil's own artifact, passed
  to the new session as its opening message. What crosses the account boundary is a
  document the operator can read first — categorically different from moving one account's
  transcript into another's directory, which Invariant 4 forbids.
- **The seam stays visible regardless.** A handover is a lossy summary wearing the clothes
  of continuity; the new agent will speak as though it knows what it only read a paragraph
  about. The thread must show that the account changed and that a summary crossed, not the
  conversation.
