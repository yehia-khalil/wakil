# Wakil — Decisions and rationale

**Status:** living document · **Split out of `north-star.md` §6 on 2026-09-15** · **Owner:** Yehia Khalil

Each entry: the call, why, and what would change our mind. The charter carries a
one-line index of these in its §6 and links here; this file carries them in full.

**Entries are cited by number, never by location** — "Decision 20" is the address, and
that is why moving them here broke nothing. 108 such citations exist across the specs,
plans and acceptance documents.

**Numbers are permanent.** A superseded decision is amended in place with a dated note,
never renumbered and never deleted — the history is the point.

**15 of 32 entries state no reversal condition**, including Decision 9, which is
self-described as costing *"~1.5–2× a plain UI pane and cannot be retrofitted."* A
decision nobody has said how to get out of is not wrong, but it is one this project
cannot cost — the charter's §6 table keeps the count visible for that reason.

**One appendix sits below the numbered entries** — *Invariant 6 — the writes that have
earned in*, moved out of `north-star.md` §4 on 2026-09-17 when that one invariant reached
474 words. Its entries are cited by date rather than by number; the charter keeps the rule
and the table.

---

Each entry: the call, why, and what would change our mind.

1. **Native macOS application.**
   Voice justifies it — on-device speech, TTS, global hotkeys, menu bar, Keychain are
   first-class only here. *Reverse if:* voice gets cut, at which point a VSCode
   extension becomes overwhelmingly cheaper.

2. **Swift/SwiftUI + Metal for the shell.** *(settled 2026-09-03; open question 1 closed)*
   Two arguments, both decisive: best access to the native-justifying APIs (on-device
   speech, TTS, global hotkeys, Keychain, menu bar), and the **performance budget** — a
   120fps always-animating shell with parallax panes and a continuously-live Core is
   exactly what a web runtime (Electron/Tauri) stutters on. Native removes that ceiling.
   *Necessary but not sufficient:* felt speed still depends on warm state, motion-masked
   switching, web-view pooling, and grid virtualization — see `design-language.md` §13.
   *Reverse if:* the app is ever rebuilt as cross-platform, which would reopen the
   tradeoff entirely.

3. **Capability layer is a separate headless process, not in-app.**
   Makes Phase 1 usable from plain Claude Code with no UI, retiring all integration
   risk before a line of Swift. Also keeps the shell replaceable.

4. **A provider owns an opaque harness credential bundle.**
   Under the Claude harness that bundle is a `CLAUDE_CONFIG_DIR` plus a
   `CLAUDE_CODE_OAUTH_TOKEN` — verified working on this machine already
   (`~/.claude-accounts.zsh`). A config dir isolates settings, history, plugins, *and*
   MCP OAuth, so it is a complete credential boundary for free. Keychain service name is
   `Claude Code-credentials-<sha256(configDir)[0:8]>`.
   The provider model stores the bundle as opaque harness-owned data so Invariant 1
   holds: only the harness adapter may interpret it.
   **Verified 2026-09-03** against `@anthropic-ai/claude-agent-sdk@0.3.237`: `Options.env`
   exists, and it **replaces the subprocess environment entirely rather than merging with
   `process.env`**. The SDK spawns Claude Code as a subprocess, so `CLAUDE_CONFIG_DIR` and
   `CLAUDE_CODE_OAUTH_TOKEN` pass straight through. Replace-not-merge is the desirable
   semantic here: Wakil constructs each provider's environment explicitly and simply
   never includes `ANTHROPIC_API_KEY`, which eliminates the key-shadowing trap by
   construction rather than by discipline. Pin the binary with
   `pathToClaudeCodeExecutable` rather than relying on `PATH`.
   *(Amended 2026-09-06: the bundle attaches to the **provider**, not the organisation —
   an org may hold several providers, so a bundle keyed to the org could serve only one
   Claude account per org, exactly the constraint Invariant 4's amendment removes. This
   is Decision 16's two-axis framing — harness vs. provider — finally implemented
   structurally rather than merely stated. The verified SDK findings above are
   unaffected: `Options.env` behaves identically regardless of which axis supplies the
   values.)*
   *(Amended 2026-09-07: Phase 2a drives the `claude` **CLI** directly over
   `--input-format stream-json --output-format stream-json`, rather than the TypeScript
   Agent SDK. Wakil.app is Swift, so the SDK would mean bundling a Node runtime and a
   sidecar into an app that chose native partly for startup and memory — and the SDK
   spawns this same CLI underneath, so that buys a wrapper over the identical coupling.
   The environment is constructed explicitly per provider and simply never includes
   `ANTHROPIC_API_KEY`, giving the same guarantee `Options.env` gave. The CLI also
   supplies `--session-id`, `--mcp-config`, `--strict-mcp-config` and
   `--permission-prompt-tool`, which Decisions 13 and 19 and Invariant 4 all now depend
   on. **Honest cost:** stream-json is a weaker contract than the SDK's types, so the
   parser is built against recorded fixtures and the binary is pinned by absolute path.
   The SDK remains available as a second `AgentHarness` implementation rather than a
   rewrite.)*
   *(Confirmed 2026-09-22, no amendment, by [#100](https://github.com/yehia-khalil/rafiq/issues/100).*
   Decision 31 splits the provider login across Swift and Go, and this entry's *opaque
   harness-owned data* is what makes that legal: **neither side interprets the credential**,
   so Invariant 1 is untouched by a seam that runs through the middle of a login. The
   wording was leaned on and is left exactly as it stands.*)

5. **Three agent access modes, all supported: subscription, API key, local endpoint.**
   These are properties of a *provider*, not of the harness (see Decision 16). Claude
   specifically is accessed by subscription — no API keys for Claude. API-key auth is a
   legitimate mode for other providers, and a local endpoint (Ollama, llama.cpp, LM
   Studio) needs no auth at all. Subscription tokens come from `claude setup-token`,
   stored in Keychain — not plaintext shell files.
   *(Verified 2026-09-07 — `claude auth status --json`, which reports per config dir with
   no interactive session: all three accounts are `authMethod: claude.ai` /
   `apiProvider: firstParty`; `personal` is `max`, `initech` is `team`, `umbrella` is
   `enterprise`. No account is on API billing, so this decision holds in practice and the
   Phase 1 acceptance run's "Claude API" banners were not evidence of a fallback. **New
   consequence:** team and enterprise plans can impose managed settings that constrain
   MCP servers and permission modes — the mechanisms Decision 19 and the Phase 2a harness
   depend on. Develop against `personal`; probe the other two.)*

6. **Credentials at the org, scope at the project.**
   Jira, Slack, and inbox share one shape: the org holds the account and auth, the
   project holds the filter (project key, channels, labels). One `Connection` +
   `Scope` pair covers all adapters, and switching projects never re-prompts for auth.

7. **A project has N roots, not one repository.**
   Microservice and backend-plus-frontends projects are the normal case. Maps 1:1 onto
   a VSCode multi-root workspace. Enables the cross-repo questions that justify
   grouping at all ("which consumers break if I change this contract").
   *(Noted 2026-09-17, no amendment — recorded because two tickets in a row re-derived
   it. **No UI surface consumes this decision for the whole of Phase 2.** The capability
   layer honours it fully: `session_list` walks every root (`sessions.go:341`), and
   `Resolved.RootPaths` is a list. But a terminal pane opens at a *path* and does not
   name a root, and `rootPath` means the fresh-session default and nothing else. Its
   only other consumers — the Git pane and the editor's file tree — are Phase 3. So a
   Phase 2 surface that appears to want a root is almost always asking the wrong
   question, and the two that did were both answered by deleting the root from the
   question rather than by wiring one through.)*

8. **Environment is a first-class project dimension.**
   DB and HTTP have nothing but environments; PM, chat, and inbox have none. Active
   context is (project, environment). This one addition is what makes destructive
   voice commands survivable.
   *(Amended 2026-09-17: **an environment holds APIs, plural.** This entry claims the
   DB/HTTP symmetry, and that is the address the correction belongs at — `databases` was
   a list from the start and `api` was a single object, which was never argued, only
   assumed. An environment often holds several first-party backends as separate domains
   or subdomains, and they mostly do **not** share a credential, which kills the
   environment-level default the single object implied. So `api` keeps its key and
   becomes an array of named entries, each with its own `baseUrl`, its own optional
   `authRef`, and an `authHeader` defaulting to `Authorization` — the header name was
   hardcoded while only the scheme was thought to be. `PickAPI` mirrors `PickDatabase`,
   which makes `request`'s new `api` field additive rather than breaking; `list_apis`
   mirrors `list_databases`. The type change over a rename is deliberate: a rename makes
   every existing object **silently** invisible to `json.Unmarshal`, while a type change
   fails **loudly** at `LoadProject`, against a known population of three files. The
   account, including the artboard defect that actually decided it — an operator-typed
   base URL carrying the environment's bearer token to an unreviewed host — is in
   `phase-log.md`, "an environment holds APIs, plural".)*
   *(Amended 2026-10-03 by 2c-iv Amendment 9b, W1: [#183](https://github.com/yehia-khalil/rafiq/issues/183)'s
   ambiguity refusal moves from `api_open` to Send.* An `api_open` naming no entry in an
   environment of several no longer refuses. It opens the pane **unpointed**, from ⌘K and from an
   agent alike, with the whole list in the chooser and in its result's `entries`. **Send from an
   unpointed pane is refused, "pick an entry first"**, before anything reaches `wakil-http`.
   Nothing is guessed, so the reason for refusing (*a guess would send one backend's credential
   to another backend's host*) still holds. It is met by a later refusal instead of an earlier
   one. `PickAPI` keeps its own refusal unchanged, and the window never reaches it without a
   name. Every api pane also re-resolves its entry by name when the environment changes and at
   launch. An entry of that name gives the pane that environment's origin and credential flag.
   No such entry keeps the name, and the URL line says the environment declares none.)*

9. **Every pane is dual-driven, via a shared action registry.**
   Adding a button makes it voice-addressable; adding a capability puts it in the UI.
   Drift becomes structurally impossible, and the registry yields an action journal
   with undo plus a single safety chokepoint. *Costs ~1.5–2× a plain UI pane and cannot
   be retrofitted.* Accepted knowingly.

10. **Voice is a transport, not a command language.**
    Speech-to-text produces the same string the text box would send; one code path.
    Building a voice grammar or intent parser is the failure mode to avoid.

    *Amended 2026-10-20 (3b-ix): one bounded exception, the fast path.* A line sent from the
    composer, typed or spoken (the same string through the same path), may first be offered to
    the org's quick-tasks model. The model may answer with exactly one action from a fixed list
    of 26 navigation actions, and no writes. Wakil runs it as the operator's own dispatch only if
    the action is on the list, its params fit the schema and every name it uses exists. Anything
    else, a late answer (past 400 ms on a local model, 2.5 s otherwise) or any doubt sends the
    line to the agent unchanged. There is still no grammar and no voice-only path. *Reverse if:*
    operators often have to undo what the fast path ran.

11. **Push-to-talk capture, not a wake word.**
    More reliable, no always-on microphone, and one fewer subsystem. Mistranscribed
    identifiers (`RAF-142` → "raff one forty two") are resolved by the agent against
    real ticket and endpoint lists rather than by demanding clean audio — which is why
    STT accuracy is a preference, not a correctness requirement. Engine choice is
    Decision 18.
    *(2026-10-06, sub-phase 2d-i: no amendment. "Resolved by the agent" gains a measured
    first stage: Wakil folds case and separators, matches against the names in scope, and
    hands the agent the candidates as a hint beneath the unchanged turn. Fold recovered 6
    and 11 of 29 identifiers on two recordings; near matching failed a fresh check and is
    not built. The agent still makes the call. `2d-stt-probe.md` §10.)*

12. **Many sessions, with optional continuity.**
    Session-per-task is the harness's natural grain; long-lived sessions drift in ways
    that cannot be debugged. Continuity comes from structured per-project memory plus
    the ability to resume any prior session.
    *(2026-09-15, sub-phase 2b-viii: no amendment, recorded deliberately.* `setProvider`
    still **refuses** a turn in flight; the org switch (spec §4.2) **queues** it instead.
    Two switches, two behaviours, on purpose — an org carries the operator's whole
    context and a provider does not, so the queue's drift risk is answered the same way
    q5's amendment answers it below: a resume is always a **fork**, minted under a fresh
    Wakil id with recorded lineage, never a long session silently continued. `setProvider`
    is not migrated to the queue here, but its own doc comment's stated cost — that a
    queue needs a deferred-state machine the window lacks — is now paid, so a later
    migration is cheaper than it was.)*

13. **Session history is read from disk.**
    Claude Code writes `$CLAUDE_CONFIG_DIR/projects/<encoded-root>/<sessionId>.jsonl`.
    Reading it gives every session for a project — including ones started outside
    Wakil, retroactively, with no integration. **The encoding is lossy** (`/` → `-`):
    always encode a known root and look for that directory; never decode directory
    names back into paths. Match by prefix to include worktrees.
    Two SDK options bear on this: `persistSession` (default true) controls whether
    sessions are written at all, and `sessionStore` (@alpha) can dual-write transcripts
    to an external store. The on-disk read stays primary — it is the only thing that sees
    sessions started outside Wakil — with `sessionStore` a possible later addition for
    sessions Wakil itself starts. Do not depend on an alpha API.

14. **Reactive in v1; proactivity deferred.**
    Proactivity is the fastest route to building something you mute. The one exception
    is a morning brief you explicitly ask for. Add proactive behaviour only where its
    absence has actually been felt.
    *Clarified 2026-10-19 (3b-viii):* ghost-text is reactive — it answers the operator's
    own typing, never moves focus, makes no sound, and is gone on the next keystroke.

15. **Recall ships as grouped per-source results, not unified ranking.**
    Searching each bound source and showing cited, grouped lists delivers most of the
    value with no index — deferring sync, staleness, and invalidation entirely. Jira
    relevance and email relevance share no signal, so honest ranking needs an index,
    and an index needs bulk APIs.

16. **Two independent axes: harness and provider.**
    The **harness** runs the loop, orchestrates tools, and manages context. The
    **provider** is what that loop talks to, plus how it authenticates — subscription,
    API key, or local endpoint. Conflating them overstates the cost of provider
    flexibility.
    Claude Code is the first harness, and it plausibly covers all three provider modes
    by itself: a local or third-party endpoint is reachable by overriding the base URL
    (via an Anthropic-compatible shim such as LiteLLM) rather than by writing a new
    harness. **Exhaust that path before building a second harness.**
    *(Verified 2026-09-08 — "plausibly" is now "measured", closing open question 9.
    `claude` 2.1.263, launched with `ANTHROPIC_BASE_URL=http://127.0.0.1:8787` and
    `ANTHROPIC_AUTH_TOKEN` against a stub Anthropic endpoint, POSTed
    `/v1/messages?beta=true` with `Authorization: Bearer <token>` and
    `anthropic-version: 2023-06-01`, and returned the stub's text as its `result`.
    Confirmed twice: under a plain `-p` launch, and under Wakil's exact `buildLaunch`
    argv — `--input-format stream-json --output-format stream-json --verbose
    --include-partial-messages --session-id --mcp-config --strict-mcp-config` — so the
    Phase 2a harness needs no argv change to drive a third-party or local model.
    `ANTHROPIC_BASE_URL` also **takes precedence over `CLAUDE_CODE_OAUTH_TOKEN`**: with
    both set the request still went to the stub, so a provider record cannot half-switch.
    Reproduction: `scripts/anthropic-stub.py`, which carries the exact invocation.*
    ***The one code change this needs.*** `buildLaunch`
    (`app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift`) constructs the child
    environment from nothing — exactly `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`,
    `HOME`, `PATH`. That whitelist is what makes `ANTHROPIC_API_KEY` unable to shadow a
    subscription *by construction*, and it is worth keeping for exactly that reason — but
    it equally makes `ANTHROPIC_BASE_URL` unable to get **in**. A non-subscription
    provider therefore needs `baseURL` and `authToken` on the `Provider` record
    (`internal/wakilcore/provider.go`, alongside `configDir`) and two more conditional
    keys here, emitted only for kinds that are not `claude-code`. That is the entire
    fallback path; it is deliberately not built yet, because nothing needs it today.
    **Caveat on the measurement:** a stub proves the transport, not that any given
    model drives this harness well — see the honest caveats below.*
    `AgentHarness` covers start, resume, list sessions, send, and capabilities.
    *(Noted 2026-09-08, revised 2026-09-10. That sentence was the intended shape, not
    the shipped one, as of Phase 2a: `start`, `send`, `events`, `interrupt`, `stop` — no
    resume, no session listing, no capability negotiation. Phase 2b-v (session resume)
    has since shipped resume: `AgentHarness.start` takes
    `start(sessionId:resumingFrom:workingDirectory:)`, and a past session is forked by
    handing its id as `resumingFrom` — not continued in place; see `buildLaunch` for why.
    `session_resume` is the `.control` action that drives this: it forks the named
    session into a freshly-minted Wakil session id and rebuilds the window's thought
    thread from the transcript, rather than merely reading the parent's metadata and
    first prompt as it did in 2a. List sessions and capability negotiation are still
    outstanding; those arrive with the phase that needs them.)*
    **Honest caveats:** a genuinely new harness — a provider with no loop of its own —
    means writing the loop yourself, which is real work rather than configuration. And
    small local models use tools markedly worse no matter how clean the plumbing, so
    "locally hosted" buys privacy and cost, not parity.
    *Amended 2026-10-19 (3b-viii):* the harness axis has two seams — `AgentHarness` for
    sessions and `QuickModel` for one-shot quick tasks, with two operations, `infill` and
    `respond`. `ClaudeCodeQuickModel` runs a warm `claude` session launched through
    `buildQuickLaunch` — `buildLaunch`'s environment whitelist and stream-json flags, with no MCP
    servers, and without the agent's prompt (`--append-system-prompt`), permission tool
    (`--permission-prompt-tool`) or `--allowedTools`; `LocalEndpointQuickModel` speaks a
    llama.cpp-style `/infill` and the OpenAI chat shape. Decision 42 says how a call picks between them.

17. **Native Monaco editor, dual-driven — not embedded VS Code.**
    *(Revised 2026-09-03. Originally: embedded `code-server`, black box, built last.)*
    The editor is built into Wakil on the Monaco component, so Wakil can operate it as
    actions ("rename to `bookingId`", "open the confirm method") like every other pane —
    which embedded VS Code, a black box in a webview, cannot. Cost: no extension
    marketplace, no full debugger. Includes a collapsible multi-root file tree, multi-tab
    files, and three-tier autocomplete (Monaco basic → per-language LSP on demand → AI
    ghost-text from the org's Claude account (since 3b-viii: the org's quick-tasks provider,
    Decision 42)). Git is a *separate* dual-driven pane (git is project-level across roots;
    the editor is per-file) that reuses Monaco's diff renderer and opens files into the editor. Full pane roster and layout model:
    `design-language.md` §10–11. *Reverse if:* the lack of the VS Code ecosystem proves
    disqualifying for real work — then embed `code-server` as the black-box exception and
    keep the native editor for dual-driven edits.

18. **Speech-to-text is pluggable, and selected per organization.**
    Apple's on-device recognition is the default — free, private, no model download.
    Local Whisper is the accuracy upgrade. Cloud STT (Deepgram, ElevenLabs, Whisper API)
    is the strongest on technical identifiers but streams audio off the machine, so it
    is opt-in and set per organization: a client org's data policy may forbid it. The
    interface is small — audio in, text out — so pluggability here is genuinely cheap.
    Use the *recognition API*, not macOS system Dictation; dictation inserts text into
    whatever field has focus and cannot be driven per-pane.

    *(2026-09-16 — the accuracy premise inverted. Recorded before the probe rather than
    after, because the premise is durable and the answer is not.)* This decision was
    written against `SFSpeechRecognizer`, and *"Apple is the free default, local Whisper
    is the accuracy upgrade"* was true of it. **It is no longer true in general.** macOS
    26 replaces that API with `SpeechAnalyzer`/`SpeechTranscriber`, which independent
    2026 benchmarks put ahead of Whisper large-v3-turbo on English word error rate —
    9.02% → 2.12% on clean speech, 16.25% → 4.56% on noisy — at roughly twice the speed,
    on device. **What did not invert is the one axis Wakil is actually on.**
    `SpeechAnalyzer` was reported to have dropped the custom-vocabulary feature
    `SFSpeechRecognizer` had, and custom vocabulary is very nearly the whole of what this
    application needs from an STT engine: what gets spoken here is `writeRef`, `wakilcore`, `2c-ii-b`,
    `AssertSQLMutation` and `INI-2835`, not prose. Whisper approximates it through prompt
    conditioning. So the ordering is now **unknown rather than reversed**, which is what
    open question 10 asks and what `2d-stt-probe.md` measures.

    **Correction, 2026-09-16, same day, after the probe ran.** The sentence above is
    wrong about the API. `AnalysisContext.contextualStrings` is in the macOS 27.0 SDK and
    `SpeechAnalyzer.setContext(_:)` attaches it — Apple did not drop custom vocabulary.
    What the probe found instead is worse for both candidates and better for Wakil:
    **Apple's contextual strings and WhisperKit's prompt tokens are both accepted and
    both change the transcript by not one character** (`2d-stt-probe.md` §6.1, verified
    by reading the context back and by a nonsense control). The engines scored 4/29 and
    3/29 on Wakil's own identifiers. **But roughly two thirds of the misses are the right
    words wrongly joined** — "transaction read only", "describe editability", "CTX adopt
    provider" — which a deterministic fold against the identifiers Wakil already has in
    scope recovers completely, taking Apple to 14/29 and WhisperKit to 15/29 with no
    model change and no vendor cooperation. See §6.2. The consequence for this decision
    is that **engine choice matters far less than it looked**, and the pluggability this
    entry already commits to is what makes that safe to say.

    **Settled 2026-09-16, closing open question 10: Apple ships as the default, Whisper
    stays selectable.** Not deleted — WhisperKit was ahead on the salvageable count
    (15/29 vs 14/29) and on mean closeness (0.893 vs 0.880), both inside the noise of a
    29-token sample, at roughly ten times the latency and a 950 MB model. That is exactly
    the shape this decision was written for: a default that is free and adequate, and an
    upgrade an operator may select per organisation when their vocabulary or their room
    makes it worth the cost. The cloud tier is untouched and still opt-in.

    **Nothing else in this decision changes.** Pluggable per organisation stands — the
    operator confirmed 2026-09-16 that engine choice is not tied to a *type* of org, only
    selected per org, which is what Invariant 11 already says. The recognition API over
    system Dictation stands. The cloud tier stays opt-in for the reason given, and is not
    what the probe is between: both candidates are on-device, so the data-policy argument
    does not arise for either.

    **Two structural facts the probe does not decide, recorded here because they bound
    whatever it decides:**

    - `SpeechAnalyzer` needs **macOS 26**, and `app/Package.swift` targets **14.4**. It
      is reached through `if #available(macOS 26, *)` rather than by raising the floor,
      so a machine below 26 simply has one fewer engine to select — which pluggability
      already accommodates and is a further argument for it.
    - The Go core is built **`CGO_ENABLED=0` by deliberate policy** (see the Makefile's
      own rationale, and `wakilcore.SecretSet`, which is written against that premise).
      A `whisper.cpp` cgo binding therefore cannot live in the capability layer without
      reopening that trade-off. **The shippable Whisper is WhisperKit** — Swift, Core ML,
      macOS 13+ — in the app, which is also where `SpeechAnalyzer` lives. Both engines
      sit behind one Swift protocol in `WakilKit`; the core holds only the per-org
      *selection*. That is the split ruled on 2026-09-16 against Invariant 10: capture
      and live partials need the window, engine choice and the provider record do not.
      ~~Note it would be `WakilKit`'s **first external dependency** — the package has
      none today.~~ *(Corrected 2026-09-17: it will not be the first. **Decision 23
      takes SwiftTerm**, and 2c-iii is scheduled before 2d. This sentence was true when
      written and was already doubted in `phase-log.md` — WhisperKit lost its probe and
      became selectable rather than default, so it may never be built at all, while the
      terminal pane cannot ship without an emulator. What the sentence was really
      saying — that adding a dependency to this package is a decision and not a detail —
      is what Decision 23 now carries.)*

19. **Wakil.app serves its own MCP surface; the agent reaches panes only through it.**
    *(Added 2026-09-07, from the Phase 2a design.)*
    The alternative — the agent calling `wakil-db` directly while Wakil watches the
    transcript and updates the pane — makes pane state a *reconstruction* with two
    writers, which Invariant 2 forbids, and leaves the deictic references of Invariant 3
    with nothing authoritative to resolve against. So the action registry projects
    directly into an MCP tool list that Wakil itself serves: each action is a tool with
    its own schema, and `read_pane` is the only hand-written one. `wakil-ctx`, `wakil-db`
    and `wakil-http` are removed from the agent's configuration — the registry is their
    only caller. `wakil-pm` and `wakil-recall` stay directly available, because they
    produce answers rather than pane state.
    **Transport:** Wakil's own executable in a `--mcp-shim` mode, copying JSON-RPC frames
    between stdio and a `0700` unix socket — not an in-app HTTP listener. One JSON-RPC
    implementation instead of two (the app needs a stdio client regardless), and
    filesystem permissions instead of a bearer token on a port every local process can
    reach. *Reverse if:* a pane ever needs state the registry cannot own.
20. **A record is edited two ways — by writing the statement, or in the cell — and both
    compile to the same gated action.**
    *(Added 2026-09-13, scoped as sub-phase 2c-ii-b.)*
    Typing `UPDATE … WHERE id = 4` is how a mutation is expressed today, and it is the
    honest form: it says exactly what it will do before it does it. It is also the wrong
    ergonomics for the thing an operator does most, which is fix one wrong value in a row
    they are already looking at. So the DB pane gains a second entrance — double-click a
    cell, it becomes an input, Enter commits — with the hard constraint that it is an
    *entrance*, not a path. The edit composes a single `UPDATE` and dispatches
    `db_run_mutation`, the same and only `.mutate` action the typed route uses, through
    the same registry, the same `writeGate`, and the same production block. Invariant 2
    is not negotiable here: an editable grid that wrote through to the database itself
    would be the plainest violation of it in the codebase, and it would arrive looking
    like a convenience.
    **What makes a cell editable is provenance, not type.** A result grid holds the rows
    of a *query*, not the rows of a *table*. A join, an aggregate, a computed expression,
    or a `SELECT` that simply omitted the primary key gives a cell no `WHERE` clause to
    be written back through, and inventing one is how a tool updates the wrong row —
    or every row. A cell is editable only when the pane can name the single table its
    rows came from and every primary-key column of that table is present in the result.
    Everything else stays read-only *and says so*, which is the rule `truncated` and the
    sort footer already obey (`design-language.md` §8): a surface that cannot do the
    thing must not look like it can.
    **A committed edit leaves the rows on screen stale**, and that is the second reason
    this is scoped after the DB pane rather than before it. `db_run_mutation` writes
    nothing back to the pane by design — a row count has no shape a rows grid can
    honestly draw — so an in-place edit would leave the old value sitting under the
    cursor, which is worse than no edit at all. The fix is the pane re-running its own
    query, which is exactly the re-query mechanism 2c-ii already owes pagination and sort
    honesty. Built first, it would be built twice.
    **Authorship does not change whether confirmation is required, and this is settled
    by evidence rather than by argument.** *(Corrected twice on 2026-09-13: once after
    reading the acceptance record, which shows the gate was never built around an agent
    proposing and a human disposing, and again after reading 2c-ii's own walk.)*
    `writeGate` gates `.mutate` at every origin — `.ui`, `.agent` and `.debug` alike — and
    2b-iii's spec §8 chose that deliberately: *"the same surface serves an
    operator-initiated mutation, dispatched from the window at `origin: .ui`, which the
    gate also gates. One confirmation mechanism, not two."* `ConfirmationPlane` branches
    on authorship for the wording and nothing else: `.agent` reads *"The agent proposes a
    change"*, everything else reads *"Confirm this change"*. So Enter in a cell
    **requests** confirmation; it does not supply it.
    **The typed half already exists and has been walked.** 2c-ii's query line classifies
    a statement before running it and hands a mutation to `WindowModel.runMutation` at
    `origin: .ui`, which parks the plane — `phase-2c-ii-acceptance.md` check 10, walked
    2026-09-13: *"Gate refusal, confirmation plane, `confirm` and cancel all behave."* So
    2c-ii-b is not the first `.ui` mutation and does not discharge the debt
    `phase-2b-iii-acceptance.md` recorded as *"the operator's own path is owed"* — 2c-ii
    discharged it. 2c-ii-b is the second entrance to a path that is already open, which is
    the whole reason it can be this small.
    **It inherits two defects that walk found on the typed route, and both are worse at
    close range.** `D8b`: a confirmed mutation does not re-fetch the pane, so the grid goes
    on showing a value the database no longer holds — predicted by this entry's stale-rows
    paragraph before the walk was read, and now an observed open defect rather than a
    forecast. On the typed route the operator at least knows they ran an `UPDATE`; on a
    cell edit the stale value sits directly under the cursor that just changed it, which
    is the same bug read as a failed edit. `D7`: a gate refusal discards what the operator
    typed — on a cell edit that is the value they just entered. **2c-ii-b is not startable
    until both are fixed**, which is a stronger form of "scoped after 2c-ii" than the
    ordering alone.
    **What is left open is narrower than it looked.** Open question 12 no longer asks
    whether an operator-authored mutation needs the plane, and no longer asks whether the
    `confirm`-then-Run cost is bearable in the abstract — the operator has now paid it, on
    check 10, and recorded no complaint. It asks only whether it stays bearable for a
    statement the operator never wrote. Invariant 7 and the production block are untouched
    either way — voice may never commit a cell, and a production database refuses both
    routes identically. *Reverse if:* the provenance rule proves so restrictive that few
    real result sets qualify, in which case the typed statement stays the whole answer, as
    it is today.

21. **Setup is a UI surface, and the shell is its peer rather than its prerequisite.**
    *(2026-09-14)*
    Every configurable thing — organisations, projects, environments, the databases inside
    them, and the credentials those databases need — is creatable and editable from inside
    Wakil.app. The files and the `security` command remain fully supported equals: nothing
    becomes UI-only, and a hand-edited `project.json` stays a first-class way to work.
    What changes is the default. Today setup is shell-only, and that was never decided —
    it is what was left over after every phase built the thing it was for. An operator
    adding their first database edits JSON by hand and runs `security
    add-generic-password` with a service name (`wakil:<org>:<ref>`) they have to know the
    scheme for, and nothing in the product tells them any of that. This entry exists so
    that stops being an accident.
    **Shell parity is a requirement, not a courtesy.** Config is plain JSON under
    `~/.wakil` and in project directories, and it must stay readable and writable that
    way: every acceptance runbook in `docs/wakil/` sets its fixtures up by editing those
    files, `make test-live` needs them scriptable, and a UI-only setup would make the
    product untestable by the very documents that certify it. The UI is a better front
    door onto the same files, never a private format.
    **The cost is more even than this entry first claimed, and the correction is the
    useful part.** Creating an org, a project, an environment, or a database *entry* is
    writing JSON that Wakil already owns and already parses — near-free. Adding a
    **credential** is not the step-change it looked like either.
    *(Corrected 2026-09-15, by the design review's §A1.* This paragraph read: *"it is the
    first Keychain WRITE from Swift, and Swift has not yet performed a Keychain READ. The
    provider picker, still owed from 2b-iii, is that read … a plan that schedules the
    credential UI without the provider picker has mis-costed itself by an entire risk
    surface."* **Both premises were false.** The provider picker is not owed — it is
    2b-vi, **MET 2026-09-11**, walked in full; the row is a few lines below this one. And
    Swift does not read the Keychain and is designed never to: `ProviderCredentialsLookup`
    says why at length — `secrets.go` shells out to the `security` CLI and encodes
    measured knowledge a second implementation would have to re-derive, so *"Go reads, and
    this asks Go."* There is no `import Security` anywhere in `app/`.*)
    **The write side is already a Go verb too**, symmetric with the read: `wakil secrets
    set` and `wakil secrets set-db`. `secrets.go` records that value normalisation was put
    at that boundary *precisely because a UI writer would otherwise miss it* — the design
    already anticipated this surface writing through Go. So the credential form costs a
    form, a validation surface, and one more subprocess spawn through the plumbing
    `ProviderCredentialsLookup` already uses. **No new framework, no new risk surface, and
    no ordering constraint** — the *Reverse if* below, which names a CLI Keychain writer,
    was always describing the mechanism that exists.
    **Two invariants constrain the UI's shape, and both are easy to breach by accident.**
    Invariant 6's rule is that writability comes from possessing a second credential the
    server granted, never from a flag — so the UI must ask for a *write DSN*, and must
    never offer "make this writable" as a checkbox. That checkbox is precisely the
    `readOnly` field issue #14 deleted for governing nothing while three live agent turns
    reasoned confidently from it. Invariant 4's rule is that the org is the credential
    boundary — so a credential form is always unambiguously inside one org, and the
    service name it writes is derived, never typed. Neither invariant is amended here.
    **What this does not settle.** Where org *creation* lives is genuinely open, because
    creating an org from a window already running as another org runs straight into open
    question 13's blast radius: an org change invalidates the active project, the
    environment, every pane and every Keychain reference in flight. Creating one and
    switching to it may well be two different gestures, and this entry does not decide
    that. No phase row is claimed either; this records the intent and its true cost so the
    scheduling is a decision rather than a surprise.
    *Reverse if:* the operator population turns out to be exclusively people who would
    rather edit JSON — in which case the honest answer is not a setup UI but a documented
    schema, a config validator, and a `wakil` CLI subcommand that writes the Keychain
    entry with the right service name.
    *(2026-09-15, sub-phase 2b-viii.* The near-free half — creating an org and adopting
    an account into one, both from inside the window's org plane — **shipped here**,
    closing open question 14. The costed half — registering a brand-new provider,
    including the first Keychain **write** from Swift — **remains unscheduled**; this
    sub-phase's §10 names it out of scope explicitly and §8.7 leaves the plane's adopting
    state ready to grow a form for it. The ordering this entry's *"What this does not
    settle"* paragraph predicted held: the read half (2b-vi's provider picker) landed
    first.)*
    *(2026-09-22, by the settings map [#46](https://github.com/yehia-khalil/rafiq/issues/46).*
    **The costed half is scheduled: it is sub-phase 2e**, built after 2c and before 2d
    ([#102](https://github.com/yehia-khalil/rafiq/issues/102)). And **shell parity runs one
    way** ([#99](https://github.com/yehia-khalil/rafiq/issues/99)): *a hand-edit can do
    everything the UI can* is verified against; *the UI can do everything a file can* is
    already false on purpose — [#97](https://github.com/yehia-khalil/rafiq/issues/97) rules
    project fields, environment create/rename/remove and the machine block out of the pane —
    so it is a direction of travel rather than a test. **The ruling that costs most is the
    one that adds nothing: no `wakil` verb is owed, ever, including for minting.** Of every
    capability 2e adds, exactly one has no shell path, and its equal already exists as
    `claude setup-token` itself — **the equal is the underlying tool, not a mirrored verb**.
    The third ground is a finding: **every `wakil` CLI mutation is unjournalled**, the
    journal being Swift-only (`ActionRegistry.swift:325-345`, no Go writer), so a
    credential-minting verb would be a supported, unrecorded entry point in the phase that
    made the journal load-bearing. The shared Go writer is **already structural** — one Go
    writer per file, no Swift config encoder anywhere — and is named as a rule rather than
    tested; one Go test is owed, because `project.json` has no writer today and 2e authors
    the product's first one. The settings pane **caches nothing**: disk on open and on every
    read, and every write is read-modify-write from disk at dispatch, never a flush of
    cached pane state.*)
    *(Amended 2026-10-22 by sub-phase 2e-ii, `docs/superpowers/specs/2026-10-22-2e-ii-projects-environments-design.md`.*
    **Creating, renaming and removing a project, and creating, renaming and removing an
    environment, are now in the pane.** The 2026-09-22 ruling that ruled them out is
    reversed for exactly these six acts, and holds for everything else it named: a project's
    other fields (roots, scopes, the editor block) and the machine block stay file-only.
    The shell-parity direction is unchanged — a hand edit can do all six, and still owes no
    new `wakil` verb. Two rulings came with it. **Removing an environment sends a copy of
    `project.json` to the Trash first**, so Put Back is the undo and no dialog stands in
    the way (Decision 41's pattern); removing a project only drops it from the
    organisation's list and leaves its folder alone. **A project or environment an agent is
    running in cannot be renamed or removed** (Invariant 5), and these actions are
    operator-only like the rest of Settings (Decision 30), so voice cannot reach them.)*
    *(Amended 2026-10-22 by sub-phase 2e-iii, `docs/superpowers/specs/2026-10-22-2e-iii-api-entries-design.md`.*
    **An environment's API entries are now editable in the pane**, superseding the code comment
    that held the API page "read-only, and stay so": add, rename, change the base URL or auth
    header, and remove, each as the operator's own act. **A token goes to the Keychain behind
    one confirmation and never to the project file**, the journal or the tree; clearing it
    forgets the ref and keeps the Keychain item, so it asks nothing. **A database can be
    renamed in place and its write access removed**, and **removing a database now asks**
    (it destroys nothing, but a thing gone from the page is a removal to confirm, as a
    project's and an environment's are); removing an API entry asks the same, and both say the
    Keychain item is kept. All four actions are operator-only, like the rest of Settings
    (Decision 30), so neither an agent nor voice can reach them.)*
    *(Amended 2026-10-23 by sub-phase 2e-iv, `docs/superpowers/specs/2026-10-23-2e-iv-database-edit-design.md`.*
    **A database's connection is now editable in the pane, and its non-secret parts live in
    `project.json`.** Host, port, database name and user (a path for SQLite) are written to the
    file, where they can be shown, edited and read by hand; **only the passwords go to the
    Keychain**, behind the same one confirmation, and the confirmation also says when a save
    makes the database writable. An empty password keeps the stored one for the same user, and
    a changed user must bring its own. **Edit replaces Replace connection**: it fills the card
    with everything known but the passwords. A record saved before this keeps its Keychain
    item as one whole string and is shown as such; typing it once makes it editable. The one
    shared Go builder makes the connection string at connect time, so the shell, the agent's
    tools and the card agree. The action stays operator-only (Decision 30).)*

22. **A Claude account is shared across orgs; an org's credentials are not.**
    *(2026-09-14, `docs/superpowers/specs/2026-09-14-shared-accounts-across-orgs-design.md`.)*
    A config dir carries at most one **headless home** — the org whose `WAKIL_ORG` is
    pinned inside it by `scripts/register-provider.sh`, which a plain `claude` session
    there reads and cannot override. Any number of additional `(org, provider)` records
    may name the same config dir as **Wakil-only** bindings, registered only behind an
    explicit `--share`: usable from the window and from the `wakil` CLI with `--org`,
    invisible to plain Claude Code. This is deliberately not a second credential
    boundary — the Keychain service scheme (`wakil:<org>:<ref>`), `writeGate`, and the
    cross-org project guard are all untouched, because what is shared is an *agent
    account* (who pays for the tokens), never an *organisation's credentials* (whose
    databases the agent may touch). Wakil's own sessions never read the pin in the first
    place — `ClaudeCodeCLIHarness.buildLaunch` passes `--mcp-config` and
    `--strict-mcp-config`, replacing a config dir's registrations wholesale on every
    launch — which is why a shared config dir was already safe inside Wakil and has
    been since 2b-vi; sharing only makes the *registration* honest about a fact that was
    already true.
    *Reverse if:* an operator turns out to want a genuinely separate account per org, in
    which case the honest answer is separate config dirs and no sharing at all — this
    decision does not commit to sharing being the normal case, only to it being a safe
    and named one when it is used.

23. **SwiftTerm's headless engine, and nothing else, as `WakilKit`'s first external
    dependency.**
    *(2026-09-17, ruled across map #36's terminal tickets; the account is in
    `phase-log.md`, "the terminal is a real terminal, and the shell has to help".)*
    The terminal pane hosts a real shell, so it must emulate a real terminal. The gap
    between a 300-line SGR parser and a terminal emulator is the **alternate screen**,
    and the alternate screen is the whole emulator — every full-screen program the
    operator would open the pane for lives on it. SwiftTerm was cloned and read before
    this was decided: it already ships OSC 133, OSC 7 and alt-screen notification, but
    it emits nothing, and it drops the `D;<code>` exit code. Those gaps are patchable;
    writing the emulator is not.
    **Only the headless engine is taken.** SwiftTerm's macOS view is AppKit, and an
    AppKit view cannot be a dual-driven pane under Decision 9 — it would own state the
    action registry does not, which Invariant 2 forbids. Wakil draws both of the pane's
    surfaces itself from the engine's state.
    **OSC 133 shell integration is load-bearing, not cosmetic.** With the shell owning
    the input line, Wakil never sees a submitted command, so `term_run` has no trigger
    and Invariant 2 fails at the window. OSC 133 `C` is what rescues it. That is why an
    unsupported shell is **refused at pane-open** rather than degraded, and why zsh and
    bash are supported by name.
    ***This supersedes Decision 18's claim to the same "first".*** That entry's closing
    note — *"it would be `WakilKit`'s first external dependency — the package has none
    today"* — was written about WhisperKit. WhisperKit then lost its probe and became
    selectable rather than default, while 2c-iii is scheduled before 2d. SwiftTerm
    arrives first. Decision 18's note is corrected in place.
    *Reverse if:* SwiftTerm's OSC 133 and exit-code gaps deepen faster than they can be
    patched, or the engine goes unmaintained — at which point the honest answers are
    writing the engine or dropping the block history, and dropping the block history
    costs the pane its unit of state (§9, **Block**).

24. **A pane's readable state is a discriminated union keyed by `kind`.**
    *(2026-09-17, from `read_pane` against a pane that is not a grid; the account is in
    `phase-log.md`, "`read_pane` learned to say what it is looking at".)*
    Invariant 3 says the agent can read any pane's state, and until 2c every pane was a
    grid, so `read_pane` returned one shape and the always-present-key rule could be
    absolute. A terminal pane is not a grid. The snapshot therefore carries a `kind` and
    the keys vary with it — **and the always-present-key rule survives, scoped to the
    kind**: within one `kind` every key is always present, so an agent still never has to
    probe for a field's existence.
    **The discriminator already existed one tool over.** `read_layout` has reported
    `kind` since 2b-i, so this is a wiring change plus a shape change rather than a new
    concept. An unknown pane id answers `kind: null`.
    **The five grid actions refuse a non-grid pane rather than no-op'ing into it.** A
    row index means a table row, a block, or a terminal line depending on kind and on
    which surface is on screen — three incompatible meanings behind one parameter. The
    refusal is deliberate and it leaves a real gap: a terminal has no scroll action, and
    2c-iii owes one.
    **`PaneStore.Contents` becomes an enum over kinds in one store**, because
    project-keying and warm state are what every kind needs identically. This decides
    nothing about where a pane's OS resources live — that is Decision 26's territory if
    one is ever written, and for the terminal it is `TerminalStore`.
    *Reverse if:* a pane kind arrives whose readable state cannot be named by a single
    `kind` value — at which point the honest answer is a second discriminator **inside**
    the kind, which the terminal's `screen` field already is, rather than a return to one
    flat shape.

25. **A write's price rides on the action, not on its kind.**
    *(2026-09-17, from the HTTP write boundary; the account is in `phase-log.md`, "the
    HTTP write earned its way in on the credential, not on the verb".)*
    Until now `writeGate` derived its answer from the action's `ActionKind`: `.mutate`
    meant *gate outside production, block inside it*, hardcoded. Two of the three writes
    that have earned in under Invariant 6 do not want that pair. The HTTP send wants
    *allow outside production, gate inside it*; the Jira transition wants *allow
    everywhere*, because a transition is bounded to one issue and is undone by dragging
    the card back.
    **A fourth `ActionKind` was proposed, verified against the code, and rejected.** It
    puts two axes — what an action does, and what it costs — in one enum. Worse, two of
    `ActionKind`'s three consumers compare by equality rather than switching, so
    `isMutation` would silently go false for the new kind and the confirmation plane
    would stop appearing. That is a safety chokepoint failing quietly, which is the one
    failure mode `writeGate` exists to prevent.
    **So `Action` gains a price and `writeGate` gains a fifth parameter, with no new
    return value.** SQL is unchanged by construction: today's hardcoded rule *is* the
    default pair, so an action that declares no price behaves exactly as it does now.
    *Reverse if:* a price ever needs to vary on an axis other than production — a
    per-organisation policy, say — at which point the pair becomes a function and the
    fifth parameter becomes a policy object rather than two values.
    **Built, not merely proposed, by 2c-iii's Task 1** (commits `a28f6b8`/`2e23824`,
    before a line of the terminal pane itself existed) — `Action.price` and
    `writeGate(price:)`'s fifth parameter are real and defaulted, not a plan this entry
    was describing ahead of the code. The terminal pane does not exercise the non-default
    branch: `term_run` never varies its price, because it is barred from agent dispatch
    outright by `operatorOnlyActions` rather than gated or allowed at one. The mechanism
    this decision describes is general-purpose infrastructure that one HTTP write and one
    Jira transition currently use; the terminal pane is evidence it composes with a third
    write-shaped adapter without needing a sixth `ActionKind`, not a fourth user of the
    non-default pair.
    *(Corrected 2026-09-22 by [#123](https://github.com/yehia-khalil/rafiq/issues/123), and
    the correction is to this entry's own claims.* **It claims two users it does not have.**
    Neither the HTTP write nor the Jira transition is built — 2c-iv and 2c-vi are both
    unshipped — so **no action in `app/Sources` declares a `price` at all**, and this
    decision's mechanism stands at **zero shipped users** while Invariant 6's table stands
    at three. The paragraph above reads as a description of running code and is a
    description of intent. The settings phase does not change that: every settings action is
    `.control`, `price` is **never consulted for `.control`**, so no settings action reaches
    the gate's `.gate` branch or parks in the broker. Recorded rather than repaired, because
    the mechanism is right and its first real user arrives with 2c-iv.*)

26. **An environment declares whether it is production; its name supplies only the default.**
    *(2026-09-21, from [#124](https://github.com/yehia-khalil/rafiq/issues/124) on the
    2c-iv map. The bill arrived here because Decision 25's first non-default price is the
    HTTP send's `(production: .gate, otherwise: .allow)`.)*
    `isProductionEnvironment` compares a trimmed, case-folded name to exactly
    `"production"`. Three Swift call sites read it — `writeGate`, `VoidPalette.forEnvironment`
    and `WindowModel.EnvironmentListing.isProduction` — and no Go code matches the string at
    all. Until the HTTP send, every shipped action declared no price and therefore got
    `(.block, .gate)`, so a production environment an operator had spelled `prod` still cost
    a human keystroke on every write. **The send is the first action that writes `.allow`
    down**, which is precisely the backstop `writeGate`'s own comment argued from. A project
    declaring its production environment as `prod` now resolves a real production `baseUrl`
    and a real production `authRef`, paints a room that is *not* red, and sends on one click
    or one spoken turn. The two failures correlate — one spelling removes both the signal and
    the keystroke — so neither covers for the other.
    **So `Environment` gains a `production` flag, and Wakil reads it instead of guessing.**
    An environment is production if it declares `production: true`, or declares nothing and
    is named `production`. The flag is authoritative in **both** directions: a `production`
    flag of `false` on an environment named `production` means not production.
    **Widening the match set was considered and refused for the second time** (it was first
    declined on 2026-09-14). Two reasons, and the first is new: with no action declaring a
    price, adding `prod` to the set converts a `prod` database mutation from `.gate`
    (confirmable) to `.block` (impossible), so the operator loses the ability to write at all
    — the hazard traded for a worse one. And the residue cannot be separated by spelling:
    `preproduction` and `prod-like` contain the word and are pinned as *not* production by
    `VoidPaletteTests.swift:22`. A list of names can only ever be a guess, and a wrong guess
    in a gate blocks a write.
    **The failure direction was re-argued and the cautious answer lost.** A flag that can only
    *add* production would make the change monotone, which is the house instinct
    (`VoidPaletteTests` argues failure direction explicitly for the red room). It was
    rejected: an operator can **already** disarm production today by renaming the environment
    to `prod` — that is the whole of #124 — so a writable `false` opens no new door. It
    replaces an *accidental* disarm with a *deliberate* one, and nobody types
    `"production": false` by mistake.
    **Reading the flag is in scope for the map that ruled it; writing it is not.** The map had
    already ruled *promotion* out of scope because it needs Wakil to author `project.json`,
    and there is no writer — [#67](https://github.com/yehia-khalil/rafiq/issues/67) left the
    file hand-edited. Reading one more optional field is not writing one. A checkbox belongs
    to the settings surface, [#46](https://github.com/yehia-khalil/rafiq/issues/46).
    **A resemblance list survives, in the one place a wrong guess is free.** An environment
    named `prod`, `prd`, `live` or `preprod` that declares no flag is surfaced once, carried
    with the environment listing, in §9 *Partiality*'s house style (`ProjectListing.Misfiled`
    is the precedent). So is an environment named `production` that declares `production:
    false` — not because it is wrong, but because a reader of the config would otherwise trust
    the name. Never a modal, never at send time. An explicit declaration silences the first.
    *Reverse if:* the flag turns out to be edited so rarely that the name is doing the work
    anyway — at which point the honest answer is not to re-derive production from spelling,
    but to make the flag required.

27. **An agent's write to a draft request is refused while the operator has unsaved edits in
    it, and the DB pane's adopt-when-untouched rule deliberately does not transfer.**
    *(2026-09-21, from [#130](https://github.com/yehia-khalil/rafiq/issues/130) on the 2c-iv
    map. The bill arrived here because [#109](https://github.com/yehia-khalil/rafiq/issues/109)
    gave the API client pane a **draft request** — the ruling that removes the DB pane's
    choose-then-submit gap rather than policing it — while 2c-iv's exit criterion makes the
    agent's send and the operator's send the same action. Two writers, one form.)*
    **The DB pane's rule has no target here, which is a stronger statement than "it does not
    fit".** `shouldAdoptSubject` gates exactly one thing: the query line's *text*. The agent's
    `db_run_query` writes `Pane.fetch` and the pane's rows regardless and never consults it —
    the guard runs later, in `DBPane`'s `.onChange(of: pane.fetch)`. So what the rule protects
    is a **description** sitting over a subject that changed anyway, and its worst case is a
    line that lags. A draft request has no description and nothing underneath: it *is* what
    goes on the wire. Gate the agent's write and the agent's request does not exist; let it
    land and the operator's edit is gone. One writer has to lose, and the DB pane never had to
    choose.
    **So an agent's write to a draft request is refused whole while any field it names carries
    an unsaved operator edit** — refused as one aggregated answer in the house style
    [#158](https://github.com/yehia-khalil/rafiq/issues/158) and
    [#116](https://github.com/yehia-khalil/rafiq/issues/116) set for the send, never applied
    field by field. What that buys is the property the question was really about: **a draft
    request always has one author**, so a request neither writer composed can never sit on the
    screen or leave the window. And unlike the DB line — whose non-adoption is silent and told
    to nobody — a refusal is an action result the agent reads.
    **The refusal is keyed to the action's origin, and it is the operator it protects, not the
    draft.** The operator's own whole-draft gestures — reopening a `Recent` row, changing the
    entry — always land: an operator who does that over their own edits did it deliberately,
    and refusing their own gesture is the pane arguing with them. **A collision is opt-in for
    the agent**: `resolvePane` is inherited unchanged, so an agent that names no pane gets a
    new one, and only an agent naming a pane id — one it read out of `read_pane` — can contend
    at all. That is also the standing escape from every refusal above, and it is why the
    refusal costs the agent one turn rather than its request.
    **An unsaved edit is per field, by content, and a refused send does not clear it.** A field
    is untouched while it still holds what it last agreed with — `currentText == lastRendered`,
    one field at a time — and focus plays no part, which `PaneFetchTests`'
    `focusPlaysNoPartInTheDecision` already pins for the query line. A send that leaves the
    window clears the marks, because [#152](https://github.com/yehia-khalil/rafiq/issues/152)'s
    strip keeps the sent request. **A refused send clears nothing**, which is `D7` at form
    scale and matters more here than it did there: under #158 and #116 a refusal is the
    ordinary outcome — a control character, a duplicate header name, a malformed emitted
    document, an unresolved bound value — and after one the draft holds the only copy of what
    the operator meant. The clearing path is the DB pane's, unextended: a later successful send.
    **The send itself never checks.** An agent's `send` puts what is on the screen on the wire,
    because Invariant 3 makes the screen the truth and [#122](https://github.com/yehia-khalil/rafiq/issues/122)
    composes the `statement` from the draft as it stands. A dirtiness check there would be a
    second gate over [#107](https://github.com/yehia-khalil/rafiq/issues/107)'s price, the
    thing [#137](https://github.com/yehia-khalil/rafiq/issues/137) refused when it refused an
    expiry — and it is unnecessary, because the write rule has already guaranteed the draft is
    single-authored.
    **Accepted cost, stated: a refused draft the operator abandons locks that pane to the agent
    indefinitely.** The DB pane has carried the same cost since `D7` and nobody has paid it
    yet; here the agent's way out is a pane of its own, which it can take without asking.
    *Reverse if:* the refusal turns out to fire in ordinary two-handed work rather than at the
    edges — at which point the answer is not to weaken the rule but to give the agent the
    terminal's shape, a proposal slot beside the draft, which 2c-iii has already built once
    (`term_propose`) and which this entry declined only because the send is dispatchable by the
    agent and `term_run` is not.
    *(Amended 2026-10-03 by 2c-iv Amendment 9a: **the mark is focus, not unsaved text.** The
    pane now saves as typed. A typed change is written ~300 ms after the last keystroke, and at
    once on Return, on leaving the field and before any gesture, so "unsaved" no longer exists
    to be measured. The content comparison above (`currentText == lastRendered`) is retired
    with `ApiFieldEdit`. **An agent's write to a draft request is refused whole while the
    operator's cursor is in a field it names.** The mark is set on focus in and cleared on focus
    out once that field's last write has landed. The path box marks both the path and the Query
    region, as 8a's keystroke did. The refusal, its aggregation, its origin rule and its wording
    are unchanged, and `read_pane` publishes neither keystroke nor focus. Leaving the field
    releases it, so the agent's retry lands. The clearing-by-send rule above goes with the
    content marks, because a send does not move the cursor. *Reverse if:* the cursor turns out
    to sit in a field for long stretches while nobody is editing. The answer then is an idle
    timeout on the mark, not a return to comparing text.)*
28. **A provider's credential is the config dir plus a `setup-token` Wakil mints itself, and Wakil never implements refresh.**
    *(2026-09-22, from [#95](https://github.com/yehia-khalil/rafiq/issues/95) on the
    settings map [#46](https://github.com/yehia-khalil/rafiq/issues/46); measured in
    `provider-login-probe.md` §9 and §11.)*
    [#89](https://github.com/yehia-khalil/rafiq/issues/89) proposed deleting the token. A
    `CLAUDE_CONFIG_DIR` plus a populated scoped Keychain item launches a session in a
    scrubbed environment, so `ProviderTokenRef` and the `provider:<id>` secret looked like
    dead code. **The measurement inverted it.** A config dir's own OAuth credential
    **expires while idle and the CLI cannot refresh it** — two of this machine's three
    provider dirs report `loggedIn: false` already — while the pasted `setup-token` still
    launches both. The token is the durable half; the config dir is the identity half; and
    **neither substitutes for the other**, because the minted token carries `user:inference`
    alone against the login's seven scopes, so `auth status --json` returns no email, org or
    subscription for it ([#119](https://github.com/yehia-khalil/rafiq/issues/119)). Two
    browser trips are therefore load-bearing, not one with a convenience: the login trip
    buys identity, the mint trip buys durability.
    **Wakil does not implement refresh, and that is a decision rather than an omission.**
    The CLI already tries and fails, and Orca has the identical hole. What this phase
    removes is **the human from the credential path, not the token from the design** — the
    rotation debt came from printing tokens into a terminal, never from their existence.
    **"Long-lived" is 365 days**, and the token is **revocable by nothing**: it is never
    written to the provider's store, so it is never an argument to any revoke call, and no
    web console URL for it is referenced anywhere in the binary
    ([#126](https://github.com/yehia-khalil/rafiq/issues/126)). A provider row therefore
    carries **two credentials and never merges them**
    ([#101](https://github.com/yehia-khalil/rafiq/issues/101)): they differ in
    revocability, and the irrevocable one is the one that launches sessions. Liveness read
    from `auth status --json` is an **identity** signal, not a capability signal — the
    token's own state is a computed date, from the Keychain item's `mdat`
    ([#166](https://github.com/yehia-khalil/rafiq/issues/166)).
    *Reverse if:* Anthropic ships a refresh path the CLI honours for an idle config dir —
    at which point the token becomes optional rather than load-bearing, and #89's original
    proposal becomes correct as written.

29. **Go is the only process that writes the Keychain, and a provider credential is minted and stored atomically there.**
    *(2026-09-22, from [#96](https://github.com/yehia-khalil/rafiq/issues/96) on the
    settings map [#46](https://github.com/yehia-khalil/rafiq/issues/46), amended the same
    day by [#139](https://github.com/yehia-khalil/rafiq/issues/139) and
    [#100](https://github.com/yehia-khalil/rafiq/issues/100); the redaction rule is
    [#123](https://github.com/yehia-khalil/rafiq/issues/123)'s.)*
    **The blocker is the journal, not the entitlements.**
    [#93](https://github.com/yehia-khalil/rafiq/issues/93) measured that no hardened-runtime
    entitlement covers keychain access — `com.apple.security.keychain` does not exist — and
    that what governs it is the item's ACL, which trusts exactly one application:
    `/usr/bin/security`. So shelling out is silent and in-process `SecItem` prompts, and the
    shell-out is **the design rather than an implementation detail**. What forbids Swift
    writing is separate and stronger: `JournalEntry.params` is written **verbatim on every
    dispatch**, including gated-and-refused and blocked ones (`Journal.swift:34`,
    `ActionRegistry.swift:158-191`), so *"delegate through an action"* and *"the secret
    rides in the params"* are incompatible.
    **That splits the two cases.** A **provider** credential is minted and stored
    atomically inside Go, its actions carrying identifiers only, so nothing travels and
    nothing needs redacting. A **database DSN** is typed by a human, so it moves through a
    `.control` action bearing **the journal's first redaction rule** — marked on `Action`,
    not on `ActionDescriptor`, because `dispatch` holds the former and never builds the
    latter. The rule keeps the parameter **name** and writes `[redacted]`, already this
    repo's word (`driver_mysql.go:374`, `httpclient.go:487`), and it is **positional rather
    than byte-matching** — the opposite of the Go scrubber, and correct here, because a
    journal knows which parameter is secret while a scrubber can only guess. Piping to
    `wakil secrets set` outside the registry is forbidden by Invariant 2.
    *(Amended 2026-09-22 by #139, and the amendment is the load-bearing half.* This entry
    first said the credential *never enters Swift's address space*. **Swift already holds a
    provider token on every session launch**, read off a one-shot `wakil provider
    credentials` stdout pipe (`ProviderCredentialsLookup.swift:75-83`) and placed in an
    environment dict (`ClaudeCodeCLIHarness.swift:114-119`). The rule is therefore **never
    journalled**: the journal is what this decision defends, and that same shipped path is
    the shape the mint verb copies.*)
    *(Amended 2026-09-22 by #100: this entry is **Claude-shaped**. Codex's credential is a
    file its own CLI writes, so "Go is the only process that touches the Keychain" is a
    statement about the Claude conformance rather than about every provider kind — see
    Decision 31.)*
    **Two holes are accepted and recorded rather than deferred.** The `security -w` argv
    window puts the value in the process argument list; #93 found its only fix also breaks
    prompt-free access. And the **unknown-action-name path journals no parameters at all**,
    because it structurally cannot read a mark (`ActionRegistry.swift:157-160`) — harmless
    today, a live plaintext hole from the first secret-bearing action onward.
    *Reverse if:* the journal ever gains a typed parameter model that can carry a secret
    without serialising it — at which point the split between the two cases dissolves and a
    Swift-side write becomes arguable again on its own merits.

30. **Settings is a pane the agent may read and never drive.**
    *(2026-09-22, from [#98](https://github.com/yehia-khalil/rafiq/issues/98) and
    [#123](https://github.com/yehia-khalil/rafiq/issues/123) on the settings map
    [#46](https://github.com/yehia-khalil/rafiq/issues/46).)*
    It is **a pane — the first singleton pane kind and the first that is never saved.** The
    plane lost on a measurement rather than on taste: `read_layout` emits no key for a plane
    (`MCPServer.swift:346-378`), so the agent reads back a normal layout while the canvas
    sits inert at 22% opacity, which is Invariant 3 breached rather than bent. A second,
    independent argument: **`WakilApp` has no test target and `WakilKit` does**, so a
    plane's state is pinned only by a runbook. `read_layout` grows `overlay`; the snapshot
    is **whole**; settings is excluded from the layout file, which removes the
    projectless-organisation hole rather than handling it; and **⌘,** opens exactly one.
    **Every settings action is operator-only**, on four reasons kept separate, one of them
    new to `operatorOnlyActions`: the DSN write is refused because the agent would *carry*
    the secret in its own params, where every existing member objects to what the agent
    could *reach*. So the pane is **readable and not drivable**, and that asymmetry is new
    to the product.
    **This is not a hole in Invariant 2.** UI controls and the agent dispatch the same
    actions; the invariant does not say the agent may dispatch *every* action, and
    `operatorOnlyActions` has enumerated exceptions since Phase 2a. What is new is the
    **scope**: this is that mechanism applied to a whole pane for the first time, which is
    why it is written down rather than left as a list membership. Its cost is already
    visible — [#102](https://github.com/yehia-khalil/rafiq/issues/102) could not file this
    phase as `2c-vii`, because 2c's exit criterion is *"each pane the phase ships is fully
    dual-driven"* and this pane is not.
    **The classification is total, and that is the phase's single test.** Every registered
    action is explicitly classified as operator-only or not — 31 today — and an unclassified
    action fails. The operator rejected a behavioural test for "destructive" in favour of an
    enumerated list, on the better argument that a behavioural test is a judgment made once,
    silently, by whoever writes the action. Confirmation for the destructive members is
    **pane-local and never the gate, the broker or the plane**: `ConfirmationPlane` renders
    verbatim and unelided, and would have put a DSN password on screen.
    *Reverse if:* a settings action arrives that carries no credential and reaches nothing
    the agent could not already reach — at which point the asymmetry belongs per action, as
    `operatorOnlyActions` already expresses it, and this pane stops being special.

31. **`ProviderLogin` is a kind-keyed protocol, and the seam splits at the human rather than at the language.**
    *(2026-09-22, from [#100](https://github.com/yehia-khalil/rafiq/issues/100) on the
    settings map [#46](https://github.com/yehia-khalil/rafiq/issues/46), amended the same
    day by [#139](https://github.com/yehia-khalil/rafiq/issues/139).)*
    **Swift spawns the interactive login; Go owns durable capture.** Invariant 1 survives
    because *neither side interprets the credential* — Decision 4's own wording, confirmed
    here rather than amended. **Invariant 11** is the basis for designing the seam now:
    Codex is measurably a different mechanism at every point (`CODEX_HOME`, a credential
    *file*, working refresh, no mint), which is what earns a protocol rather than what
    defers one. The contract is therefore **scoped home env var, spawn a login, read
    liveness** — and explicitly **not minting**, which is Claude-shaped. Claude Code is its
    only conformance; the second is
    [#136](https://github.com/yehia-khalil/rafiq/issues/136) and is out of scope.
    **Three actions, not one, and the count is set by timeouts rather than by taste.** Every
    `ctx_*` is a thin proxy to `wakil-ctx` on a **10-second** reply timeout, while a browser
    login is minutes. So `ctx_provider_login` returns at once and a `ProviderLoginSession`
    modelled on `TerminalSession` publishes the states; the **mint** is its own action,
    because Invariant 2 wants the credential-creating mutation enumerated in its own right —
    otherwise the journal says *"login"* for the step that creates a 365-day credential —
    and because re-auth at the mint alone has no expression under two; then
    `ctx_add_provider {id, configDir}` commits and returns the row plus liveness, writing
    **one record for the organisation the operator is standing in**. Another organisation
    adopts the account later from its own pane, and `ctx_adopt_provider` grows the
    **credential copy** it does not do today — `SecretGet` plus `SecretSet`, both in Go,
    both silent, no browser trip, possible only because Decision 28 keeps the minted token.
    **The mint's browser trip is a one-shot `wakil` verb Swift spawns**, not an MCP action —
    mirroring the credential *read* path that has shipped all along
    (`ProviderCredentialsLookup.swift:75-83`). Because it is not an MCP call the ten seconds
    never bind; because Go captures `setup-token`'s stdout and stores atomically the token
    never reaches Swift anyway; because it is a separate process a `wakil-ctx` restart
    cannot kill it. It owes a **second journal line on outcome**, reusing
    `recordUncertainMutation` (`StandardActions.swift:1691-1735`), because every action
    returns before its work finishes and an uncaught token is unrecoverable: the journal
    must distinguish *minted and stored* from *a one-year credential exists at Anthropic
    that Wakil never caught*.
    **MCP registration is out, and folding it in would have been wrong.** `buildLaunch`
    always passes `--strict-mcp-config`, so Wakil's sessions ignore the config dir's
    registrations entirely; `register-provider.sh` serves only plain `claude`; and
    `--scope user` pins one `WAKIL_ORG`, so a second organisation would overwrite the
    first. **Invariant 4's *"Owed: one provider serving several organisations"* is
    therefore already delivered for Wakil's own sessions.**
    *Reverse if:* a second provider kind turns out to share Claude's mint shape — at which
    point minting joins the contract and the protocol gains a fourth member, rather than
    each conformance carrying its own verb.

32. **An organisation unlinks a binding; it never removes a provider — and `home` is an artefact, not a setting.**
    *(2026-09-22, from [#126](https://github.com/yehia-khalil/rafiq/issues/126) on the
    settings map [#46](https://github.com/yehia-khalil/rafiq/issues/46), amended the same
    day by [#166](https://github.com/yehia-khalil/rafiq/issues/166).)*
    The record and the Keychain item are both per-`(org, id)`; the **account** is the config
    dir; one account on this machine carries four different ids across four organisations.
    So the unit is the **binding**, and removing one is an **unlink**, which **never
    refuses**.
    **`RemoveProvider` already ships, and its refusal does not survive.** Fired when a
    binding homes a directory others share, it rests on a claim that is **false and was
    measured so**: the comment calls the orphaned state *"a one-way door out of every
    command that could repair it"*, but a plain `provider add` re-homes the directory and
    every orphaned share recovers instantly. What the refusal actually guarded is **one
    optional field** — a shared binding with no `claudePath` inherits the home's — and the
    bindings that need it are exactly the ones `adopt_provider` creates, **because it never
    records the field**. So the refusal is deleted, and its dependency with it, by two
    changes in the **add** path and none in the remove path: adopt records the resolved
    `claudePath`, and a binding added to a directory nothing homes **becomes** the home.
    **Unlink deletes three things, all the organisation's own:** the record; the Keychain
    item, which owes Go its **first secret delete**, since `wakil:<org>:provider:<id>` is
    derived from the organisation plus the filename and so has exactly one referent; and
    the **stale pointers**, which is not housekeeping — after a remove, `org.json` still
    names the gone provider and `SaveOrg` **refuses to write the file**, so the pane breaks
    its own form. `active.json` has the mirror defect, validated nowhere.
    **Never touched: the config dir**, on the strongest residue argument available —
    `Claude Code-credentials-832632cb` exists on this machine with no directory hashing to
    it, and the name being `sha256(realpath(configDir))[0:8]` makes it **underivable
    forever**. **Revocation is refused on Invariant 4, not on caution:** `claude auth
    logout` does revoke and does delete the CLI's scoped item, but it is machine-wide and
    org-blind while every config dir here is named by two to four organisations. **The last
    unlink is the sole exception** — with no binding left the cross-org objection does not
    exist — and it is an offer, never automatic, and it can only ever revoke half, because
    Decision 28's minted token is revocable by nothing. So unlink owes one permanent
    sentence: **this phase creates a credential it cannot destroy.**
    **The rule that generalises is about visibility.** `home` is an artefact, not a setting:
    nobody chooses it, it is whichever organisation added the account first, it is not a
    persisted field anywhere, and **a refusal turning on an invisible unchosen attribute
    cannot be reasoned about.** The operator must never see it.
    *(Amended 2026-09-22 by #166, by one write in the path this entry said had none.*
    Deleting the orphan refusal means an unlinked home promotes `shared` bindings that have
    no `claudePath` and now nothing to inherit from, so **unlink backfills the inheriting
    record before deleting the departing home**. Letting it fail was rejected: that is the
    residue standard applied to damage the phase *causes* rather than inherits. And
    `adoptProviderArgs` has **no `claudePath` field at all**, so the add-path fix above must
    **add an argument, not populate one**.*)
    *(Amended 2026-09-22 by [#176](https://github.com/yehia-khalil/rafiq/issues/176), which
    extends **never touched** from unlink to the **add flow's cancel**, on a second and
    independent ground.* This entry's reason is that the scoped Keychain item is named from a
    hash of the config-dir path, so a delete makes the name uncomputable — which holds
    wherever the delete happens, and means sweeping an abandoned sign-in would manufacture
    another `Claude Code-credentials-832632cb`. The new ground is that the directory has a
    **use** after the cancel: #100 ruling 6 derives `~/.claude-<id>` from the provider id, so
    an abandoned directory is **deterministically addressable** and #101's `1 of 1` re-auth
    walks back into it. A third, weaker ground is that a sweep cannot keep its promise —
    `AppScene.swift:35-38` refuses to unwind half-built work and there is no crash hook, so it
    would fire on the cancel button and on neither of the other two exits. **Leaving it is the
    only disposition that behaves identically on cancel, quit and crash.** Re-entry shows the
    identity and offers `Continue as <email>` or `Sign in as someone else`; the latter is one
    `claude auth login`, which **replaces in place** and upserts the same Keychain item under
    an unchanged name, so it carries **no exposure to this entry's argument** and does not join
    Decision 30's destructive list.*)
    *Reverse if:* `claude` grows a revocation that names a config dir rather than the
    machine — at which point the last-unlink exception generalises to every unlink, and the
    sentence about a credential this phase cannot destroy can finally be deleted.

33. **A shipped Wakil is told which KEYCHAIN to use, and never which keychain TOOL.**
    *(2026-09-26, from [#301](https://github.com/yehia-khalil/rafiq/issues/301), which
    [#201](https://github.com/yehia-khalil/rafiq/issues/201) caused and which
    [#297](https://github.com/yehia-khalil/rafiq/pull/297) carried onto `main`.)*
    `WAKIL_KEYCHAIN` names the keychain file every `security` call in `wakilcore` is
    scoped to, as the trailing `[keychain]` positional those subcommands already take.
    It is read **in a shipped binary**, with no `testing.Testing()` gate.
    **The axis is the file, not the program, and that is the whole ruling.** #201 made
    the tool an absolute path on a sound argument — Decision 29's, measured by
    [#93](https://github.com/yehia-khalil/rafiq/issues/93): no hardened-runtime
    entitlement covers Keychain access, the item's own ACL governs it, and the ACL
    trusts exactly one application, `/usr/bin/security`, because the `claude` CLI
    created the item by shelling out to it. **So a tool override is a dead end twice
    over** — `testing.Testing()` blocks it, and a different binary is a different
    application to that ACL and would prompt anyway. The second lock is macOS's and
    cannot be legislated away. A keychain selector touches neither: the same
    Apple-signed binary runs, the ACL is satisfied exactly as before, and all that
    moves is which file it opens.
    **It is strictly weaker than the channel it replaces.** Until #201 this package
    resolved `security` through PATH, so any parent that could set an environment
    variable could already substitute the whole tool — which is precisely how the e2e
    fixture worked. A variable that can only redirect *which keychain file* is written
    is less power than that, granted to the same caller.
    **The residual risk, named rather than left to be found.** That second argument
    is *"no worse than before"*, and "before" is a state #201 judged unacceptable and
    closed — so it cannot carry the decision on its own. The ACL protects an
    **existing** item from other applications; it says nothing about Wakil
    legitimately writing a **new** item somewhere else, through the very binary it
    trusts. An attacker who can set `WAKIL_KEYCHAIN` therefore does not attack the
    item — they redirect Wakil's writes, and the next minted token lands in a keychain
    file they control. That is exfiltration with the trust model entirely intact.
    **What makes it acceptable is who can do it:** it takes control of Wakil's process
    environment, and such a caller can already substitute `claude` on `PATH`, read the
    config dir, or drive the app. It is inside every boundary this program has, and
    this grants it nothing it could not otherwise obtain. *(Third leg added
    2026-09-26 in review, which correctly refused the first two: the ACL argument is
    about the tool and says nothing about the destination, and a historical argument
    invites the reply "then why did we close it?")*
    **What #301 cost, which is the reason this is a decision and not a patch.** From
    #201 the fixture's `security` shim stopped reaching the product, because an
    absolute path does not consult PATH. Every Keychain write out of a *shipped* Wakil
    under e2e went at the operator's **login** keychain, and `VerifyIsolation` went on
    certifying those runs as isolated — it checks PATH, and PATH was still perfect.
    What saved the machine was macOS's authorization dialog, which nothing answered:
    the run hung there for thirteen minutes rather than succeeding. **A guard that
    cannot see the channel it guards is worse than no guard**, so the guard now reads
    both, and neither alone is sufficient evidence. `fixture.go`'s claim that isolation
    "has to be structural, because Invariant 4 requires cross-org bleed to be
    impossible rather than avoided" is true again, for the first time since #201.
    **The shim stays.** It is not redundant and it is not legacy: it covers everything
    that still resolves `security` by name and that the fixture does not own — `claude`
    above all, whose own Keychain item no parameter of Wakil's could ever scope.
    **Three smaller rulings inside this one, each of which fails silently if reversed:**
    every Keychain call is built by one constructor (`keychainCommand`) rather than
    appending the positional at five call sites, because the sixth site written without
    it would compile, pass, and write to the login keychain; an unset selector appends
    **nothing**, not an empty argument, since `security` reads a trailing `""` as a
    keychain named `""` where absent means the default; and `WAKIL_KEYCHAIN` is
    **forwarded** through `childProcessEnvironment` rather than parameterised like
    `WAKIL_ORG` and `WAKIL_PROVIDER` — those are launch-time facts the window can change
    mid-session, this one is fixed for the life of the process and set by the launcher.
    *Reverse if:* Wakil ever needs to read an item it did not write — today all five call
    sites operate on `wakil:<org>:<ref>` with account `wakil`, so one selector can scope
    them all. **The concrete case is nearer than it looks, and it will arrive disguised
    as a performance fix.** Every liveness read currently spawns `claude auth status
    --json` (`liveness.go:111`) — one process launch per account row, on every open of
    the settings pane — and the obvious optimisation is to read Claude Code's own
    credential item directly instead. That item is in the **login** keychain, not
    Wakil's, so the day that lands, Wakil reads one keychain and writes another in the
    same call path and a process-wide selector is the wrong shape. Whoever reaches for
    that optimisation will be thinking about process launches, not about keychains.
    Nothing in 2e reads a foreign item today: the mint runs `claude setup-token` on a
    PTY, liveness runs the CLI, and both reach the Keychain **through the `claude`
    binary rather than through `security`**; adopt copies `wakil:` to `wakil:`.

34. **Wakil pins a fork of the MCP Go SDK, because integer fidelity is not
    negotiable and the bug is upstream of every layer we own.**
    Set 2026-09-26, closing [#242](https://github.com/yehia-khalil/rafiq/issues/242).

    `applySchema` decodes every tool's arguments and every tool's result into
    `any` and **re-marshals** whenever defaults may have been applied — which is
    every object-rooted schema, so in practice always. The decoder had no
    `UseNumber()`, so each JSON number became a `float64` and the re-marshal wrote
    the lossy value back out. `9007199254740993` left the process as
    `9007199254740992`: wrong by one, silently, on **all three drivers** — the
    sqlite case needs no engine and fails identically, which is what ruled out
    driver behaviour.

    Why it is not an off-by-one. The 2026-09-13 record describes this class as
    *"a live Invariant 3 breach — the operator is asked to confirm a
    correct-looking statement aimed at a row that is not theirs."* A row key wrong
    in its last digit still **looks** right in every surface that displays it, and
    `read_pane` and every `db_run_query` result feed the write gate.

    **Four escapes were tried and closed, in this order:**
    - *Upgrade.* v1.8.0 carries the same missing `UseNumber()` and the same
      unconditional re-marshal. There is no released version without this.
    - *Drop the output schema*, so `applySchema` returns early on `resolved == nil`.
      Refused by our own `mcpxtest.AssertObjectOutputSchemas`, which says it in as
      many words: *"forfeiting the schema is not an acceptable way to satisfy this
      check."*
    - *Return `StructuredContent` ourselves and leave `Out` nil*, so `outval == nil`
      skips the call. `elemZero` replaces a nil pointer `Out` with a non-nil zero,
      so the only route to a nil `outval` is the elicitation path.
    - *`UseNumber()` alone.* **Falsified by measurement**, and this is the one worth
      recording because it is what anybody would try first: `json.Number` is a Go
      *string* type, and jsonschema rejects it — `9007199254740993 has type
      "string", want "integer"`.

    **So the fix narrows before it validates**: `json.Number` becomes `int64` when
    it is an integer that fits and `float64` otherwise. Both validate against
    `"integer"` and `"number"`, and both re-marshal to the text they were decoded
    from. It fixes the **argument** path as well as the result path, which #242 did
    not know was broken.

    The fork is pinned in `go.mod`, **by an immutable tag and never by a branch
    or a pseudo-version**:

    ```
    replace github.com/modelcontextprotocol/go-sdk =>
        github.com/yehia-khalil/go-sdk v1.7.1-rafiq.1
    ```

    *That is a correction, not a preference.* The first pin was the
    pseudo-version `v1.7.1-0.20260926203229-5fd9a259fcf1`, taken off the PR
    branch. Rebasing that branch onto upstream main force-pushed it, which left
    the pinned commit **on no branch at all** — reachable from this machine's
    object store and from a warm proxy cache, and from nothing else. A fresh
    clone would have failed to resolve it, on a schedule nobody controls.
    So the commit now has two permanent homes in the fork — the tag
    `v1.7.1-rafiq.1` and the branch `rafiq-pin` — and **neither is ever moved or
    force-pushed.** The PR branch moves freely; the pin does not.

    **The pin is `v1.7.0` plus this one change**, deliberately, and not the
    rebased head: v1.7.0 is a release, the 75 upstream commits since it are not,
    and every measurement in this entry was taken against the pinned tree.

    Upstreamed as [modelcontextprotocol/go-sdk#1302](https://github.com/modelcontextprotocol/go-sdk/pull/1302),
    rebased onto upstream main and reusing that tree's own
    `internal/json.UnmarshalUseNumber` from
    [#1239](https://github.com/modelcontextprotocol/go-sdk/pull/1239) rather than
    adding a second decoder helper — which also closes a gap the first revision
    had, since that function runs `checkMaxDepth` and the hand-rolled one did not.

    **#1239 is not this fix and does not remove the need for it.** It repaired the
    *client* side — `CallToolResult.StructuredContent` is typed `any`, so a Go
    client rounded wire numbers on the way in. It did not touch `applySchema`, so
    on upstream main today the **server** still corrupts the bytes before they are
    sent, which reaches every client including Wakil's Swift.

    **Reversal condition: drop the `replace` when #1302 merges AND a release
    carries it** — verified by removing the directive and watching
    `TestIntegerAbove2Pow53SurvivesOnTheWire` stay green, never by reading a
    changelog. Until then the fork stands on its own and nothing waits on
    upstream. Keeping the change to one function is what keeps that exit cheap.

    **A known limit, stated rather than discovered later:** a JSON integer beyond
    int64's range (~9.22e18) still degrades to `float64`. Exactness there would need
    a `big.Int`, which jsonschema does not accept and no MCP client expects. Every
    64-bit database key and every Snowflake-style id is inside int64.

    **What guards it here.** Two tests, both of which were seen to fail first.
    `TestIntegerAbove2Pow53SurvivesOnTheWire` asserts on the bytes off a real stdio
    transport — never through the SDK's Go client, whose `StructuredContent any`
    would reintroduce the same `float64` and measure the wrong thing.
    `TestShippedWakilDBPreservesLargeIntegers` drives `bin/wakil-db` itself, because
    *"the fix is in the code"* and *"the fix is in the binary the app launches"* are
    different claims; on stock v1.7.0 it reports `…992`/`…996`, and with the fork
    `…993`/`…995`.


---

35. **A failed action journals why: the sentence it threw, with every marked
    parameter's value taken out.**
    Set 2026-10-08 by the operator, closing the journal half of
    [#323](https://github.com/yehia-khalil/rafiq/issues/323).

    Before this an `"error"` line said only that a handler threw. #323's walk hit
    *"the binding could not be written"* twice, the journal held two bare
    `"error"` lines, and the cause (#330) was found by reading the pane, not the
    record that exists to answer it.

    **What is stored.** `JournalEntry.reason`, on `"error"` lines only: the
    error's own sentence (`String(describing:)`, the one the pane shows and the
    agent is sent), each string value of a parameter marked in `secretParams`
    replaced by `[redacted]`, capped at 300 characters. Optional, so every line
    written before it still decodes. `ok`, `gated`, `blocked`, `unknown` and
    `uncertain` carry none; their outcome is already the reason.

    **The trade the operator accepted.** A reason may quote non-secret input
    the operator or agent typed — a path, a host, an account name. That is the
    exposure the pane and the agent's transcript already have. An error *code*
    alone could not leak anything, and would have told #323's walk nothing:
    the useful half of a failure is usually Go's sentence.

    **A byte search, unlike `params`.** Decision 29 redacts `params` by
    position, because the journal knows which parameter is the secret. A
    sentence is a blob the registry did not compose, so the only way to keep a
    secret out of it is to look for the secret's bytes. A secret a handler
    re-encoded before quoting is not found; keeping those out of a message is
    the job of the Go scrubber that wrote it.

36. **The editor is the project's one code surface: file write earns its way in, and the Git pane
    folds into it.**
    *(2026-10-11, operator, during the 3b-i design.)*
    **File write** — local files inside the active project's roots — is the next write to earn in
    under Invariant 6. Its price is *allow* in production and outside it, for the operator and the
    agent alike, voice included: outside Wakil the agent's harness already has a bare file-write tool
    (inside Wakil sessions the bridge denies it, so `editor_save` is that write), so an editor write
    adds no reach beyond what a bare harness has — the argument that settled the terminal. Gating it would add friction and no
    safety. **Still refused:** any path outside the roots (after resolving symlinks), file delete,
    rename and move; each would earn in on its own. *(Earned in 2026-10-17, Decision 41.)*
    Mechanism: `wakil-files` (`files_write`), confined by `wakilcore.ConfineFilePath`;
    `editor_save` declares the price.
    **The Git pane folds into the editor** (sub-phase 3b-iii): the editor's left column has *Files* and
    *Changes*; a changed file's diff opens as an editor tab. This revises Decision 17's *"Git is a
    separate dual-driven pane"*: git stays project-level across roots, and so does the editor (its tree
    is the project's roots), so the split had nothing left to separate.
    *Reverse if:* a write the agent made through the editor is found to reach something its own file
    tools could not — then the price becomes *gate* for the agent.

37. **The editor's tree is the project's, whole, in every pane: root focus is dropped, and file
    operations and editor settings become sub-phases of their own.**
    *(2026-10-13, operator, during the 3b-ii design —
    `docs/superpowers/specs/2026-10-13-3b-ii-editor-tree-design.md`.)*
    **Root focus is dropped.** The 3b-i spec planned a per-pane focus toggle on each root that would
    hide it from the tree, ⌘P, search and Changes at once. ⌘P belongs to the whole window and focus to
    one pane, so a file would vanish from ⌘P with nothing on screen saying why. Each pane remembering
    which of its folders are open gives it its own view of the project without a new idea to learn.
    **Changes' root groups collapse (3b-iii)** with the tree's own rows, their open or closed state kept
    per pane and apart from Files'. **File operations** — new file, new folder, rename, move, delete —
    **are 3b-iv**: each extends Decision 36's one file write and Invariant 6, so each earns in there;
    until then the tree is read-only and rename and delete stay refused. **Editor settings are 3b-v**,
    autosave with them (font size, tabs, wrap, showing ignored files, the heavy-folder list); until
    then 3b-ii's heavy folders are a fixed list. The later rows move down by two: scratch buffers sent
    to other panes are 3b-vi (was 3b-iv), large files and logs 3b-vii (was 3b-v), AI ghost-text
    3b-viii (was 3b-vi) and LSP 3b-ix (was 3b-vii).
    *Reverse if:* a cross-file feature needs per-pane scoping that collapse cannot give.
    **Amended 2026-10-13 (3b-ii plan pre-flight, finding 6; the operator saw the three listed and
    signed off):** three departures from the 3b-ii spec. **Search runs on Go's `regexp`, not
    `git grep`:** every root, in a repository or not, is searched over the files `files_list`
    lists, so one pattern means the same thing everywhere and an invalid one is Go's own error;
    the cost is speed on very large repositories, revisited with large files in 3b-vii.
    **`vendor` joins the walk's skip list**, beside `node_modules`, so a folder of repositories
    never walks a Composer tree. **Outside a repository, the folders the walk skips are heavy, not
    ignored:** shown dimmed, loaded on opening, never searched — the walk cannot tell an ignored
    file from a skipped one without git. *Reverse if:* search on a large repository is measured too
    slow for the 250 ms pause, which brings `git grep` back for repositories.
    **Amended 2026-10-18 (3b-vii design; the operator decided):** **3b-vi — scratch buffers sent to
    other panes — is parked.** The DB pane's query line already wraps, colours and formats SQL, so
    only sending a selection to a terminal pane had value, and not enough to build now. The later
    rows keep their numbers: large files and logs 3b-vii, AI ghost-text 3b-viii, LSP 3b-ix.

38. **Editor settings live in two tiers, autosave is the operator's choice, and Decision 30 holds.**
    *(2026-10-13, operator, during the 3b-v design.)*
    Decision 37 is 3b-ii's (root focus dropped), landing with that branch.

    3b-v gives the editor its settings. **Two tiers, split by who a setting belongs to:** the
    operator's — font size, word wrap, autosave, and (part 2) showing ignored files — in
    `~/.wakil/settings.json`, the first file of design-language §14's *Wakil* scope; and the
    code's — tab size, tabs or spaces, and (part 2) the heavy folders — in each project's
    `project.json`, so a teammate gets them. A file's own indentation still wins.

    **Autosave** has three modes, Off by default: after a 1-second pause, or when focus leaves (a
    pane, a tab, or Wakil). It arms on any edit to a writable file tab, re-checks eligibility when
    the timer fires, and dispatches `editor_save` — Decision 36's write. It never writes a scratch
    tab, a tab changed on disk or deleted, or a tab whose save is in flight.

    **Decision 30 is kept.** These settings carry no credential, which its *Reverse if* names, but
    autosave decides when the operator's files are written and the heavy folders decide what search
    covers; the agent reads them (`ctx_editor_settings`); `ctx_set_editor_settings` and `ctx_set_project_editor_settings` stay operator-only.

    Go owns both tiers (`internal/wakilcore/editorsettings.go`, three `wakil-ctx` tools). A
    UserDefaults store was rejected: two stores, two read paths, and an app-wide half the agent
    could not read.

    *Reverse if:* an editor setting needs a per-organisation value, or the agent needs to change a
    setting to do its job.

39. **A replace across many files is Decision 36's file write, one file at a time.**
    *(2026-10-14, operator, during the 3b-ii-b design —
    `docs/superpowers/specs/2026-10-14-3b-ii-b-editor-replace-tabs-design.md`.)*
    `editor_replace` writes every match of the Search view's query in the files the search covers,
    each file whole and atomically through `wakil-files` (`files_replace`), confined to the roots after
    symlinks resolve. Its price is *allow* in production and outside it, for the operator and the agent
    alike, as `editor_save`'s is: it reaches nothing a bare harness's file tools could not. **It never
    writes a file open in a tab:** that file's buffer is edited instead, unsaved, so work the operator
    has not saved is never overwritten. **Its undo is in memory and conditional:** one, the latest
    replace's, for the window's life; it puts a file back only while the file is exactly as the replace
    left it (its modification time unchanged), and lists the rest. Replace All asks nothing (Rule 1):
    it is undoable.
    *Reverse if:* a replace is found to have overwritten work the operator had not saved — then the
    price becomes *gate*.

40. **The Git pane is the editor's Changes view; gutter marks and the peek ship with it.**
    *(2026-10-15, operator, during the 3b-iii design —
    `docs/superpowers/specs/2026-10-15-3b-iii-changes-view-design.md`.)*
    Decision 36's fold, made. The editor's left column has a third view, **Changes** (⌘⇧G): one
    header per root, Staged / Changes / Untracked, and a row opens a read-only **diff tab**
    (`User.php (Changes)`) in the editor's own web view, under the preview-tab rule; ⌘⏎ opens the
    file itself. **The window keeps one git status** (`GitStatus`), read once per root per watcher
    wake while any editor pane is open, and everything that shows git reads it. A file tab in a
    repository shows **gutter marks** against the index, computed in WakilKit from the buffer; a mark
    opens an inline **peek** whose **Revert** is a buffer edit — undoable, unsaved until ⌘S — and so
    asks nothing (Rule 1). The Files tree shows each changed file's status letter. **The Git pane
    kind is gone**, and a layout that saved one opens it as an editor pane on Changes — the first kind
    migration; every other unknown kind is still dropped. Stage, unstage, discard and commit are
    3a-ii's (Decision 43).
    *Reverse if:* the Changes view is found unable to show something the operator relied on the Git
    pane's spine or names column for — then that piece comes back inside the editor, not as a pane.
41. **File create, move and Move to Trash earn their way in: the Trash is the undo, and the price is allow.**
    *(2026-10-17, operator, during the 3b-iv design —
    `docs/superpowers/specs/2026-10-17-3b-iv-file-operations-design.md`.)*
    Decision 36 left delete, rename and move refused; each earns in here. **Delete is Move to
    Trash, with no dialog**: the Trash is undoable from Finder, so it destroys nothing and Rule 1
    asks nothing; there is no permanent delete. **Rename is F2**, so Enter keeps opening the row.
    **Creation has a button and a menu**: each root row has a **+** offering New File and New
    Folder, and a folder's right-click offers them too, with Rename and Move to Trash; a file's
    offers Rename and Move to Trash. **Open tabs follow a rename or move**, unsaved edits and all;
    Move to Trash closes clean tabs, and a tab with unsaved edits stays open, marked deleted, and
    saving it recreates the file. **The price is *allow*, for the operator and the agent, voice
    included**, on Decision 36's argument: the agent's harness already has `mv`, `mkdir` and `rm`,
    so the editor adds no reach, and the Trash is gentler than `rm`. **All three writes live in
    `wakil-files`** (approach A): Go is built with `CGO_ENABLED=0` and cannot call `NSFileManager`,
    so it runs `/usr/bin/trash`, which macOS ships from 15; on macOS 14 Move to Trash fails with an
    error that says so and nothing else is affected. Approach B (Swift trashes after Go confines)
    was rejected because it splits the check and the write across two processes; approach C
    (raise the floor to macOS 15) is out of scope.
    *Reverse if:* a trash or move the agent made through the editor reaches something its own `mv`
    or `rm` could not.

41. **One agent per place: each agent keeps the place it started in, and switching tears nothing
    down.**
    *(2026-10-16, operator, during the background-agents design —
    `docs/superpowers/specs/2026-10-16-background-agents-design.md`; built over four stacked plans,
    2026-10-16 to 2026-10-17.)*

    Before this a window ran one agent. An org switch ended it, and a project or environment switch
    silently retargeted it: every Wakil tool it called resolved against whatever the operator was
    looking at, so a job started in staging could finish in another environment with nothing
    recording that it moved.

    **The operator's decisions.** A **place** is an (organization, project, environment) triple,
    with at most one agent and its own thread and canvas. An agent is **pinned** to the place it
    started in for its whole life: its Wakil actions, database, API, git and file calls go there,
    whatever is on screen. Switching org, project or environment never stops, holds or redirects
    an agent, so the org switch's "switch when this turn finishes" queue is gone. Several agents
    run at once, one per place. An agent that needs the operator **waits**; it never pulls them
    back. Each agent elsewhere shows as a **chip**, top right (option B of three shown over the real
    window): violet while it works, amber while it waits, green when it finished and the operator
    has not looked; a visit clears it, and a click goes there. A finished agent's session stays
    alive until quit or a new conversation in that place. Quitting stops every agent; each is in
    its place's Continue, resumable as a fork (Decision 12). The journal records, for every entry
    an agent caused, which agent and which place. The environment is part of the place and of
    the **layout scope**: api · staging and api · production are two places, so switching
    environment moves to that environment's conversation instead of refetching the current one —
    this replaces the refetch-in-place behaviour.

    **Calls and rulings that changed what the operator or an agent experiences** (made while
    designing and building; each was costed in the plan ledgers):
    - **An agent's calls always go to its own place**, even while that place is on screen: routing
      is by who calls, not by whether the places match. A call with no agent session (the operator,
      the UI, `--dispatch`) always uses the window's.
    - **An agent cannot change its own place.** `ctx_set_project` and `ctx_set_environment`
      dispatched by an agent are refused (no org switch is exposed to it), saying the place is
      fixed when its session starts (Rule 7 allows the refusal; the amended Invariant 5 forbids the switch).
    - **An agent with no project is pinned by organisation**: it can never act in another org, and
      within its own it follows the operator's project as before. Its chip reaches its org only.
    - **An agent's proposals never expire.** It waits until the operator answers or cancels.
      Stopping or replacing a place's session cancels that place's parked proposal; quitting
      cancels all of them.
    - **The org switch asks nothing about unsaved tabs** — every place stays alive, so nothing is
      lost (the spec said "unchanged"; it contradicted itself).
    - **A project or environment switch never cancels a read**: a slow listing or query finishes
      into the place it began in. An org switch cancels the operator's in-flight DB reads and API
      sends in the org being left, so none reaches the incoming org's process (Invariant 4), and an
      agent's call on its own place's client is not cancelled.
    - **A legacy layout file is a read-only seed** for every environment of its project, never
      rewritten.
    - **No background git or editor watchers.** A hidden pane catches up when its place returns.
    - **If an agent's tool socket cannot start, the agent runs without Wakil's tools** and the status
      says why, rather than refusing the session (Rule 7).
    - **The thread no longer marks an org switch**: with places kept alive, the marker would be
      appended to a place's thread on every return.
    - **A provider switch changes only the on-screen place's agent. Quitting with agents running
      asks nothing.**
    - **The chips:** a failed agent gets a red ` — failed` chip; amber means a parked approval only
      (a question asked in text shows as done); precedence is waiting, failed, working, done. At
      most two are drawn in full and the rest fold into "+N more". A chip's production colour is
      the place's declared flag once read (Decision 26), the name only until then. A production
      environment segment is never truncated away.

    **Invariant 5's history, moved here from the charter.** *(Amended 2026-09-06: the provider is
    session-scoped, not context-scoped, and is deliberately not part of this triple [now: place] — see
    Decision 4.)* *(2026-09-15: 2b-viii's switch changes the triple's org member in place and
    needed no amendment.)* On 2026-10-17 the invariant became *exactly one place on screen; each
    agent keeps its own*, written short to stay inside the charter's word budget. In full: implicit
    scope is the product, and an explicit project argument on every tool call would forfeit it — no
    agent-facing tool grows a project or environment argument; each agent is pinned to the place
    it started in and never follows the operator's place. The charter's glossary says the same in
    brief: a **place** has at most one agent, its own thread and its own canvas; the **active
    context** is the place on screen, and every tool resolves against it implicitly, except that an
    agent resolves against its own place; the **layout scope** includes the environment. Invariant 4 stays
    structural: an agent's processes carry its own org's `WAKIL_ORG`, and `Resolve()` still checks
    it, so an agent in one org cannot reach another's credentials however the window routes.

    *Reverse if:* operators find they want an agent to follow them across places — for example,
    they repeatedly stop an agent and restart the same job in the place they moved to — or if
    the per-place cost (up to five pinned child processes per live agent) is measured as the
    reason the app is slow.

42. **Quick tasks run on one provider per org, and a local model is the operator's to run.**
    *(2026-10-19, operator, during the 3b-viii design —
    `docs/superpowers/specs/2026-10-19-3b-viii-ghost-text-design.md`.)*
    The org's `quickProvider`, else its active provider; each call routes to the first of the
    two that serves its operation, and an unreachable endpoint falls back once. A `local`
    provider is a URL plus what it serves (`infill` by default); Wakil installs, starts and
    downloads nothing. A new quick task is a caller of `QuickTasks` — a prompt and a parser —
    and adds no harness work. Measured 2026-10-19 on an M5 Pro: one-shot `claude -p` ~4.5 s,
    a warm session 1.0–1.8 s, Apple's on-device model fast but poor, `llama-server` with
    Qwen2.5-Coder 1.5B 30–210 ms. The Anthropic API with the subscription token stays
    excluded (§5).
    **Next quick task:** agent status lines. **Candidates, unscheduled:** shrinking what the agent reads (lossy; opt-in at
    most), session titles, voice cleanup, and a natural-language query in the
    DB query line (plain English drafted into SQL the operator reviews before it runs), and
    ghost-text in the API pane's JSON body (from the method, the URL and the text around the
    caret) — both added by the operator 2026-10-20. **Never a quick task:** the write
    gate, statement classification, anything touching credentials.
    *Reverse if:* quick tasks on the default provider cost enough quota to crowd out agent
    turns — then ghost-text defaults off without a local provider.
    *Amended 2026-10-20 (3b-ix): one model per org does every quick task; a `local` provider is a
    URL and serves both operations (the serves checkboxes are removed); each quick task has an
    on/off switch beside the model, per org (`ghostText`, `fastPath`). The fast path is built;
    next is agent status lines.*
    *Amended 2026-10-22 (3a-ii-b): commit drafts are built — ✨ in the commit box and
    `editor_changes_draft_message`, from what Commit would commit — with a third switch,
    `commitDrafts`, on by default.*

43. **Git writes earn their way in from the Changes view: priced allow, hooks run, a discard goes to
    the Trash, and the organisation names the author.**
    *(2026-10-21, operator, during the 3a-ii design —
    `docs/superpowers/specs/2026-10-21-3a-ii-git-writes-design.md`.)*
    The Changes view gets VS Code's Source Control: a message box per root, ⌘⏎ to commit, **+** /
    **−** / **↺** on rows and group headers, **Commit All** when nothing is staged, *Amend Last
    Commit* and *Undo Last Commit*, and the gutter peek's **Stage Change**. Seven
    `editor_changes_*` actions reach them, **priced *allow* everywhere**, voice and the agent
    included: a commit stays on this Mac and Undo Last Commit (a soft reset) reverses it. **Discard
    sends the current copy to the Trash** (`<name> (discarded HH:MM)`) before restoring it, so it
    asks nothing (Rule 1). **Writes go through `GitWriter`** in `wakil-git` (approach A), which
    lets the repository's hooks, signing program and clean filters run, as a terminal or VS Code
    does, and still blocks fsmonitor, pagers, external diff and every network path; `GitRunner`'s
    reads still run none of them. **The author is the organisation's**: Settings → Organisation →
    Git holds a name and an email, passed as `-c user.name/user.email` to every write; with none
    set, git's own config decides, and the commit box says which. The identity moved here from
    3a-iii; the SSH key, push, pull and fetch stay 3a-iii's. **Stage Selected Ranges** in the diff
    tab came in 3a-ii-b, with Unstage, through the same `git_stage_hunk` and guard. A `git commit` the
    agent runs in its own shell is unchanged.
    *Reverse if:* a commit or discard from Wakil is found to have lost work that the Trash or Undo
    Last Commit could not bring back — then the price becomes *gate*.

44. **An organisation's git account per provider; remote git priced allow; Wakil never touches the
    Mac's own SSH or git config.**
    *(2026-10-22, operator, during the 3a-iii design —
    `docs/superpowers/specs/2026-10-22-3a-iii-git-accounts-and-remotes-design.md`.)*
    Settings → Organisation → Git holds one account per host: **Sign in** (device flow; GitHub and
    GitLab.com, offered once Wakil's OAuth client ids are set, and *Use a gh login* for GitHub), **a
    pasted token** (Bitbucket, self-hosted, any host) or **an SSH key** (picked from `~/.ssh` or
    generated under the organisation's folder, its passphrase in the Keychain). Wakil runs git itself
    and hands each command the account for the remote's host: `ssh -F /dev/null` with that key alone
    on the route `ssh -G` reads, or its own credential helper — so an alias or an https clone can no
    longer push as another organisation's account, and nothing in `~/.ssh` or any git config is
    written. **Fetch, pull, push, sync, publish and clone are priced *allow* for every channel**,
    voice included (Invariant 7's allow exception): a push asked for in words must happen. **Force is
    never available**, so a mistaken push is undone by a following commit. Pull's strategy (rebase,
    merge, fast-forward only) is the organisation's setting, rebase by default; uncommitted changes are
    set aside and put back (`--autostash`, the operator's ruling during the walk), and kept in git's
    stash when they clash; a conflicting pull is aborted and named, for 3a-v to resolve. **Pull sets uncommitted changes aside and puts them back**
    (`--autostash`, the operator's ruling during the walk, as JetBrains does); changes that clash with
    what came in stay in git's stash, and Pull says so. The agent may clone, but only into the folder the
    operator last cloned into, and only the operator adds a clone as a project (Decision 30).
    *Reverse if:* injecting the account per command cannot reach a host the Mac's own setup reaches —
    or an agent push the operator did not ask for is found on a remote, and then push becomes *gate*
    for the agent.

45. **Agent instructions are the operator's, appended after Wakil's own rules, and reach a live agent
    in its next turn.**
    *(2026-10-22, operator, during the 3a-iii design; delivery amended by the probe in
    `docs/wakil/3a-iii-instructions-probe.md`.)*
    Settings holds three boxes per organisation — **General** under Agent, **Commits** and **Pull
    requests** under Git — and the same three on each project's page. The agent's launch appends them
    to `--append-system-prompt` **after** Wakil's own prompt, under one heading per box (organisation
    first, then the project), so they add to Wakil's rules and never replace them; an empty box and its
    heading are left out. ✨ drafts a commit message with the Commits texts. The CLI ignores a changed
    appended prompt on `--resume`, so **a saved edit rides in the agent's next turn**, as a block
    before the operator's words that says it replaces the earlier text, with a thread line saying so;
    a turn in flight is never interrupted. Each box saves when it is left (Rule 2); past 2,000 words
    it says long instructions ride on every turn, and nothing is refused.
    *Reverse if:* the agent is found following an earlier text after an update, or a resumed session
    starts honouring a new appended prompt — then a save restarts the session instead.

46. **Branches and stash from the context line and the Changes view, VS Code's flow; the first
    write priced by who asks.**
    *(2026-10-23, operator, during the 3a-iv design —
    `docs/superpowers/specs/2026-10-23-3a-iv-branches-and-stash-design.md`.)*
    The context line gains a **Branch** segment, the active root's, whose picker is VS Code's Quick
    Pick: a filter, Create branch, Create branch from…, the local branches, the remote ones, Fetch.
    The Changes view's root header opens the same picker; ▾ gains Branch and Stash submenus, and each
    root a **Stashes** group with Apply, Pop and Drop. A switch git refuses for changes in the way
    offers **Stash and Switch**, **Bring Them Along** (stash, switch, pop) or **Cancel** — never force,
    never discard. A clash keeps the stash and puts the touched files back, so nothing is left
    half-merged. Switch, create, rename, stash, apply and pop are priced *allow* for every channel, as
    Decision 43's writes are. **Delete Branch, Drop and Drop All carry an agent price of *gate*:** the
    operator's click confirms once, in place (Rule 1), and the agent's ask — voice reaches these only
    through the agent — raises the permission plane. `Action.agentPrice` is that one rule, not a
    general per-channel pricing scheme. A stash is named by its id as well as its position, so a list
    the terminal or another worktree changed is refused rather than another stash touched.
    *Reverse if:* an agent's delete the operator did not mean is approved by habit at the plane — then
    delete and drop become operator-only.

## Invariant 6 — the writes that have earned in

**Moved out of `north-star.md` §4 on 2026-09-17.** The invariant had grown to 474 words,
12% of a charter that must stay under 4,000, and the rule itself is one sentence — the
rest was three per-adapter justifications, which is exactly the "it has become a spec and
will rot" failure the charter's header warns about. §4 keeps the rule and the table;
this section carries the reasoning.

**Citations still land.** These are cited by date — *"Invariant 6's 2026-09-14
amendment"* — never by location, the same way decisions are cited by number.

### 2026-09-09 — row mutation on SQL databases

`INSERT`, `UPDATE`, `DELETE` and nothing else, gated by `wakilcore.AssertSQLMutation` and
reached only through a second credential, `Database.writeRef`, so a database with no such
credential cannot be mutated by anyone.

**Schema mutation has not earned its way in.** Every DDL verb — `CREATE`, `DROP`, `ALTER`,
`TRUNCATE`, `RENAME`, `GRANT`, `REVOKE`, `LOAD DATA` — is refused, not because it is hard
but because this invariant asks for a justification per adapter and none has been written
for it. `TRUNCATE` is refused explicitly rather than by omission: it reads like a `DELETE`
and is DDL. Mongo mutation is likewise not implemented, with its own reason — see Phase
2b-iii's spec §11.

### 2026-09-14 — a Jira issue status transition

An issue id and a target status, and nothing else, reached from the PM board pane (§8's
2c-vi). The justification this invariant demands: of everything `wakil-pm` can do, a
transition is the only operation whose absence forces the operator out of Wakil and into
Jira's web UI, which is §1's arbitration test applied to a single verb. Reading an issue
does not force anyone out — the agent already surfaces it.

**What stays refused:** field edits, comments, issue creation, deletion, assignee changes,
and sprint or board configuration. A transition is also the narrowest write in the
application, and narrower in kind than a SQL mutation: both of its arguments are
enumerated by the adapter — the issue exists or the call fails, and the target must be a
transition Jira itself offers from the current status — so there is no statement to
classify and no unbounded blast radius to gate.

**It does not reach the confirmation plane, and that is the deliberate half.**
`writeGate` earns its price because a `DELETE` with a bad `WHERE` is unbounded and
unrecoverable. A transition is bounded to one issue and is undone by dragging the card
back. Charging `confirm`-then-Run for a drag would price a reversible act like an
irreversible one, and the board's actual value — moving three cards while reading a
standup — does not survive that price. Invariant 8's production treatment likewise does
not apply: a Jira site is not an environment, and the red room says nothing about a PM
write. **Reverse if** an organisation binds a Jira automation to a transition. Automations
send mail, notify chat and create issues, so a transition that fires one is not reversible
in the world even though it is reversible in Jira's data model, and the whole argument
above changes — see §7 q15.

### 2026-09-17 — an HTTP request with a mutation method

`POST`, `PUT`, `PATCH` and `DELETE` against the environment's configured API entries,
reached from the API client pane (§8's 2c-iv).

**It earns its way in on the credential, not on the verb.** The agent already has `curl`
in a bare environment, so a write is not new power. What changes is that a write stops
requiring the environment's bearer token to be copied by hand into a tool with none of
Wakil's scrubbing, origin binding or redirect refusal.

**No second credential, and no method allowlist** — the two symmetries with SQL that were
proposed and removed. One unscoped key held in two Keychain entries proves nothing to the
server, so `Database.writeRef`'s argument does not transfer. And an HTTP method is not a
semantic boundary the way a SQL verb is: `POST /bookings/X/delete` deletes.

**What stays refused:** any request leaving the environment's `baseUrl`, by path or by
redirect — and the redirect refusal is now load-bearing rather than free, because a
307/308 preserves method *and* body, so a POST following one would send the body and the
`Authorization` header to a host the operator never reviewed. Caller-set `Authorization`,
`Cookie`, `Host` and `Proxy-*` headers stay refused: the tool owns authentication. And any
mutation method in production without a typed confirmation.

*(Amended 2026-09-19 by [#108](https://github.com/yehia-khalil/rafiq/issues/108), substance
unchanged. Read against Decision 8's plural `api[]`, "the environment's `baseUrl`" had two
readings; it is **the targeted entry's, singular**. And the API client pane draws **no
free-text base-URL override**: `ApiClient.dc.html`'s editable row is a feature this refusal
does not permit, not a hole it needs. A host worth reaching twice is an `api[]` entry, which
pairs it with its own `authRef`; a host worth reaching once is `curl` in the terminal pane,
which the operator already has and which binds no database cell into its body. Dropping the
credential would not have rescued the override — the request body carries values bound from
a database row, so an unauthenticated send to an operator-typed host is still exfiltration,
and caller-set `Authorization` being refused makes such a request unauthenticat**able**
rather than merely unauthenticated. The redirect refusal is untouched and unconditional.)*

*(Amended 2026-09-20 by [#114](https://github.com/yehia-khalil/rafiq/issues/114): **the write is the window's, not the binary's.** Lifting
`AssertHTTPReadOnly` (`readonly.go:727`) lifts it for every copy of `wakil-http`, including the
one `scripts/register-provider.sh` registers into each provider's config dir with `--scope user`
— where there is no window, no write gate and no confirmation plane. `wakil-db`'s headless
`mutate` is not the precedent it looks like: it refuses without a separately configured
`writeRef`, and this section's own ruling leaves HTTP with no second credential to refuse on. So
a mutation method is refused unless the child environment carries a marker that only
`WakilWiring.childProcessEnvironment` sets. **This does not re-open "no second credential"** —
the marker is not a key, it proves nothing to the server, and it grants no authority the read
credential lacks; it scopes which *process* may spend that credential to the one whose owner runs
the gate. It narrows this section's stated cost — *"the day the send ships, every environment
with an API configured is writable"* — to: writable **from the window**.)*

*(Amended 2026-09-22 by [#187](https://github.com/yehia-khalil/rafiq/issues/187), which built the Go
half and therefore had to **name** what the two amendments above describe. The marker is
`WAKIL_IN_WINDOW`, and it counts as set only when its value is exactly `1` — not "any non-empty
value", because a variable left over as `0` or `false` in a forwarded environment would otherwise
arm the write path, and a marker armed by its own negation is worse than no marker.
`wakilcore.WindowMarkerEnv` is exported so the Swift side sets a name rather than a literal. **The
setter is still owed:** `childProcessEnvironment` does not yet add it, so `send` is refused
everywhere until the window work adds that line — which is the safe direction for the gap to point,
and is where a send first has a caller ([#194](https://github.com/yehia-khalil/rafiq/issues/194)).

An **outbound cap** joins the refusals at the same time, and it is this ticket's number rather than
a ruling: **1 MiB**, refused with the limit named, never truncated. The probe booked a cliff below
64 MiB and found none — a 67 MB call crossed the pipe with no refusal, no truncation and no hang,
held in full in three processes — so the absence was the finding, and the refusal is owed on the
truncation rule's own ground: *a limit nobody is told about is the failure, and here there was not
even a limit*. It is sixteen times the 64 KiB **response** cap deliberately: a response lands in a
model's context, a request body does not. What it costs is a file upload, which this tool has never
claimed to do and which would want a streaming path rather than a larger number.

The send also refuses a caller-set **`Content-Type`**, which the list above does not name and
which is not a widening of it: the send has its own `contentType` parameter, and two channels
for one value is the silent-overwrite class this section already closes two of. Wakil sets the
header after the caller's, so a caller's would be overwritten and never complained about —
`Host`'s precedent is to refuse rather than ignore quietly. The READ tool's `headers` parameter
is untouched, which is what *"the agent's `headers` param is unchanged"* protects.

And **an empty body sends no body and no `content-type`** — story 27's three wire states,
implemented here rather than only in the pane, because this is the layer that puts bytes on the
wire. A `contentType` named alongside an empty body is refused rather than dropped quietly.)*

### Not earned: a command the agent can run in the terminal pane

Recorded here because a reader will otherwise re-derive it wrongly, and because the reason
is the opposite of the obvious one. **The agent already has a shell.** `Bash` inside the
session's working directory is auto-allowed by Claude Code's own policy and never reaches
Wakil's permission-prompt tool at all (`permission-prompt-probe.md` §7, re-measured
2026-09-10). What it does **not** have is that shell with the organisation's credentials
and the active environment's variables in it, which is precisely what a terminal pane is.

So an agent-reachable run would buy the agent credentials, not reach, and the refusal
protects Invariant 4's boundary rather than the machine. `term_run` is `.control` and is
the seventh member of `operatorOnlyActions`; the agent proposes a block and only the
operator's Enter runs it.

### 2026-10-11 — a file write inside the project's roots

Local files only, through `wakil-files`'s `files_write` (and, since 3b-ii-b, `files_replace`),
whole text by atomic rename, confined to the active project's roots after symlinks resolve.
Priced *allow* everywhere, voice included. The reasoning, and what stays refused (delete,
rename, move, any path outside the roots), is Decision 36. The editor's `editor_save`, and since 3b-ii-b `editor_replace` and
`editor_replace_undo` (Decision 39), are the actions that reach it.

### 2026-10-17 — file create, move and Move to Trash

Through `wakil-files`, confined to the active project's roots, priced *allow* everywhere, voice
included. The Trash is undoable, so nothing is destroyed. The agent's harness already holds `mv`,
`mkdir` and `rm`, so the editor adds no reach. All three are confined on the parent folder, so a
link is acted on as itself, never followed. Still refused: permanent delete, a root, anything
outside the roots, and a move across volumes. The reasoning is Decision 41.

### 2026-10-21 — stage, unstage, discard and commit, inside the project's roots

Local git only, through `wakil-git`'s `GitWriter`, on a root of the active project, priced *allow*
everywhere, voice included. A commit stays on this Mac, and Undo Last Commit reverses it; a
discard's old copy is in the Trash. A commit runs the repository's hooks and signing program — no
more than the agent's shell can already run in that repository — while every read still runs
none. Still refused: push, pull, fetch and every remote (3a-iii), branches and stash (3a-iv),
rebase, and any flag off a tool's list. The reasoning is Decision 43.

**Fetch, pull, push, sync, clone (2026-10-22, 3a-iii, Decision 44).** A push publishes beyond this
Mac. It is priced *allow* for every channel at the operator's ruling, is never forced, and is
journalled with its caller; a mistaken push is undone by a following commit. Reads still run no
program a repository chooses; a remote operation lets only Wakil's own ssh and credential helper run,
and refuses a repository's `remote.<name>.uploadpack` or `receivepack`.

### 2026-10-23 — branches and stash, inside the project's roots

Local git, through `GitWriter`, on a root of the active project. Switch, create, rename, stash,
apply and pop stay on this Mac and undo — priced *allow* everywhere, voice included. **Branch delete
and stash drop are the first git writes Wakil cannot undo** (git's reflog and `git fsck` can, outside
Wakil), so the agent's ask for one raises the plane while the operator's own click confirms in place:
Decision 46's agent price. No `--force`, no `--discard-changes`, no `branch -M`. Reads gain
`for-each-ref`, `rev-list` and `log -g` for the lists, with any format that would verify a signature
refused. Still refused: merge, rebase and conflict resolution (3a-v), tags, and a remote branch's
deletion.
