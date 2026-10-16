# Several organisations in one window — design

**Status: SUPERSEDED 2026-09-14**, the same day it was written, by open question 13's
closure and sub-phase **2b-viii, "the org switch"** (`north-star.md` §7 q13 and §8).
It is **not** binding on any sub-phase, and nothing in it should be implemented.

**What changed.** This document answers *"how does an operator change organisation
without quitting?"* with **N organisations live at once** — *"every open org keeps its own
five `wakil-*` servers, and every open project keeps its own live Claude session… three
orgs with two projects each is fifteen server processes and six Claude sessions"* — and
switching that is instant *"because nothing is torn down."*

The answer taken instead is the opposite one: **swap in place, one org at a time.** The
window survives, `WAKIL_ORG` stops being a launch-time read exactly as `WAKIL_PROVIDER`
did in 2b-vi, and the five servers **respawn** under the new org with the active project,
the environment, every pane and every Keychain reference in flight **invalidated rather
than carried across**. A switch with no prior state to tear down is also the first-run
chooser, so the same machinery answers a launch with no `WAKIL_ORG` set — which is the
failure that raised the question.

**Why, briefly.** The blast radius is not fixed; it grows with every pane, and it is
smaller today than it will ever be again. Designing one teardown against a switch that
already exists is cheaper than designing it per pane afterwards — Decision 9's finding in
its general form, and 2c-iii's PTY holding a live shell in org A's project root is the
worst case. Swap-in-place also leaves **Invariant 5** (*"exactly one active (org, project,
environment)"*) untouched, where this document's N-live model strains it and never names
it — it cites Invariant 4 four times and Invariant 5 zero times.

**Kept, not deleted**, for three things that outlived it: the argument that `WindowModel`
should be multiplied rather than parameterised so Invariant 4's credential boundary stays
inside a single-org type; §9's observation that the confirmation broker's timeout assumes
the operator can see the plane; and §14's two open questions, which never reached §7.

*(Original status, when this was written: "binding authority for the sub-phase that
follows 2c-ii-b." Raised by the operator, 2026-09-14, at the 2c-ii-b walk — `open
app/Wakil.app` failed with "WAKIL_ORG is not set" and there was no in-app answer. It
claimed to close north-star open question 13, added the same day; question 13 was in fact
closed by 2b-viii later that day, and this banner exists because two documents otherwise
claim to answer it in opposite directions.)*

---

## 1. What this is

Today one running Wakil process serves exactly one organisation, fixed at launch by
`WAKIL_ORG`. There is no way to see which orgs exist, no way to change org without
quitting, and nothing in the window says why the failure happened when the variable is
unset.

This sub-phase makes several organisations open **at once, in one window**, with their
projects beneath them — every one of them genuinely running, not remembered. Switching
between them is instant because nothing is torn down.

**What "open" means here, decided by the operator:** every open org keeps its own five
`wakil-*` servers, and every open project keeps its own live Claude session. An agent
left working in `initech` keeps working while the operator reads `umbrella`. The cost is
explicit and accepted: three orgs with two projects each is fifteen server processes and
six Claude sessions.

---

## 2. The rule this is written against

> **Tabs are the information architecture. They are not the picture.**

`design-language.md` §10 settled this on 2026-09-03, before any of it was built:

> Resolves the tension between layout D (tabs + columns) and the void (no chrome):
> **D is the information architecture, the void is the presentation.**

and §1's first principle names the forbidden form outright:

> **Futurism through absence, not addition.** No window chrome, borders, sidebars, or
> tab bars.

So "one org tab with project sub-tabs" is the right **model** — it is how the operator
thinks about what is open, and this spec adopts it — and a tab strip is the wrong
**drawing**. A dropdown is the same error in less space: still chrome, still permanent.

§10 already names both surfaces this needs, and neither is new:

- **⌘P — open / switch.** "Panes, files (fuzzy across all roots), sessions. The 'open
  anything' bar." Orgs and projects belong here, beside sessions.
- **The rail.** "A chrome-less floating list of open panes (glyph + label + shortcut, low
  opacity until relevant). It answers 'what is open'; the active pane gets a luminous
  left tick, a working pane glows green in the periphery."

The rail's existing description is, word for word, the behaviour the operator asked for:
a dim list that says what is open, with a glow where something is working. It gains two
levels above the panes and nothing else changes about what it is.

---

## 3. The structural decision: multiply `WindowModel`, do not parameterise it

`WindowModel` is 3,200 lines and assumes one of everything — one org, one project, one
wiring, one agent, one confirmation broker, one layout, one void. **That assumption is
correct and this spec does not weaken it.** It is Invariant 4 expressed in code: an
organisation is a credential boundary, and the type that owns a window's state owns
exactly one side of that boundary.

So the window holds **many models, each still single-org**, rather than one model that
learned about many orgs:

```
WakilWindow                      // thin shell
  └── ContextRegistry            // NEW — the only thing that knows orgs exist
        ├── ContextKey(org, project) → WindowModel   // each exactly as today
        └── focused: ContextKey
```

- Switching context renders a different model. No teardown, no respawn, no reload.
- A `WindowModel` never learns another org exists. Every guard it already has — the
  cross-org project check, the write gate, the production block — keeps comparing values
  within one org, which is the only comparison that means anything.
- The seam already exists: `WakilWiring.build(environment:)` takes the environment as a
  parameter defaulted to the process's own, so a second wiring is
  `build(environment: env.merging(["WAKIL_ORG": "initech"]))`. Nothing is refactored to
  enable this; it is already shaped for it.
- `WindowSession` already performs "build a wiring, build a model from it" exactly once.
  This sub-phase performs it once per open context.

**The rejected alternative** is one `WindowModel` holding N wirings with everything keyed
by context. It touches every method in the largest file in the codebase, and it puts the
cross-org boundary *inside* the type whose job is to enforce the single-org invariant.
A bug there is a credential crossing an organisation.

---

## 4. `ContextRegistry`

New, small, and in `WakilKit` so it can be tested — `WakilApp` has no test target.

```swift
public struct ContextKey: Hashable, Sendable {
    public let org: String
    public let project: String
}

public actor ContextRegistry {
    public func open(_ key: ContextKey) async throws   // builds wiring + model
    public func close(_ key: ContextKey) async          // stops servers and harness
    public func focus(_ key: ContextKey)
    public var focused: ContextKey { get }
    public var open: [ContextKey] { get }               // in operator-visible order
}
```

- **`open` is idempotent.** Opening an already-open context focuses it. The operator
  cannot end up with two live wirings for one org by pressing ⌘P twice.
- **`close` stops the five servers and the harness**, in that order, and is the only path
  that does. `MCPClient.stop()` already exists.
- **A failed `open` opens nothing.** A wiring that cannot start its servers must not leave
  a half-built context in the registry — it throws, the registry is unchanged, and the
  window reports it the way it reports any other launch diagnostic today.

---

## 5. Listing organisations

`ListOrgs()` already exists in `internal/wakilcore/org.go` and is already used by
`wakil org list`. It needs only exposure:

- A `wakil-ctx` tool, `list_orgs`, returning `{orgs: [{name, projects: [...]}]}`.
- A `.read` action, `ctx_list_orgs`, wrapping it.

**One wrinkle that must not be glossed.** Every `wakil-ctx` process is pinned to one org
by `WAKIL_ORG`, so asking *this org's* server to enumerate *all* orgs is asking a process
to describe the other side of its own boundary. `ListOrgs` only reads directory names
under `~/.wakil/orgs/` — no credential, no `org.json`, no project contents — so the
answer is the set of names the operator already typed into `wakil org create`. That is
the whole justification, and the tool's description must say so, because "a server scoped
to one org returned a list of every org" is otherwise exactly the kind of thing a later
reader should be suspicious of.

**A per-org server must not be able to read another org's projects.** So `projects` in
the payload is populated only for the server's own org; every other entry carries its
name alone. Enumerating a second org's projects requires that org's own server, which
exists as soon as the context is open.

---

## 6. ⌘P

The existing "open / switch anything" bar gains two row kinds above its current ones:

- **`org/project`** — every project of every known org, open or not. Choosing one opens
  the context if it is closed and focuses it either way.
- **`org`** — an org with no project chosen (§11.1).

Rows read `initech · checkout-api`, org first, because the org is the credential boundary and
the thing the operator is actually changing. An already-open row carries the same
luminous tick the rail uses, so the two surfaces agree.

No new shortcut. ⌘P is where §10 says this lives, and adding a second bar for "switch
org" would be the chrome this design is avoiding, one keystroke removed.

---

## 7. The rail

The rail is real but thin: 56 lines, a `List` of panes with `"|"` for focus and the
literal word `"working"` for busy. None of §10's treatment exists — no glyph, no
shortcut, no low-opacity-until-relevant, no green periphery glow. **This sub-phase writes
the rail §10 actually describes**, because it is now carrying three levels of meaning
instead of one and the placeholder cannot.

Three levels, same idiom at each:

```
UMBRELLA                     ← org, dim
  billing-api          ●    ← project, green dot: an agent is working here
    events             |    ← pane, luminous tick: focused
    customers
initech                    ●    ← collapsed org with work happening inside it
PERSONAL
  wakil-acceptance
```

- **Low opacity at rest.** §10's own words. The rail is not a permanently-legible tab
  strip; it lifts on hover and on activity.
- **One luminous tick, on the focused pane.** §1's third principle permits one luminous
  surface and §8 permits one luminous element in a data surface; the rail does not get to
  add a second. Org and project focus are shown by weight, not by light.
- **Green means working**, at whatever level is collapsed enough to need it. §1's second
  principle: if it glows it is alive, active, or asking for attention.
- **Amber means waiting for a typed confirmation.** `#f0a848` is already the reserved
  semantic in §5. This is the badge that makes §9's rule survivable.

**The known risk, stated so the walk can test it:** the rail is deliberately quiet, and a
production confirmation waiting in a collapsed org must still be noticed. If the amber
does not carry at rest, that is a defect and the answer is to make *that* state louder —
not to give the whole rail permanent chrome.

---

## 8. The room, and Invariant 8

Decided by the operator: **the focused context owns the room.**

`design-language.md` §4 gives the void two owners — hue belongs to the environment, motion
and intensity to agent state. With several contexts live there are several of each, and
one void.

- **Hue is the focused context's environment.** A production room looks like production
  when you are *in* production. The rejected alternative — hue follows the most dangerous
  environment open anywhere — makes the room describe something other than what is in
  front of the operator, which is the lying-surface failure this project has spent three
  sub-phases removing.
- **Motion and intensity are the focused context's agent.** Work elsewhere is the rail's
  job, not the room's.
- **Invariant 8 is unchanged and now matters more.** The window must always say which
  org, project and environment it is in. With several open, an ambiguous banner is worse
  than it has ever been: the operator is one keystroke away from a different credential
  boundary. The banner reads org, project and environment, in that order, always.

**A context switch changes the hue over 400ms, matched to §7's existing environment
transition** (§11.2 records why this is a decision rather than a default).

---

## 9. The confirmation broker's clock

Decided by the operator: **badge it, and stop the clock until the context is focused.**

`ConfirmationBroker.defaultTimeout` is 120 seconds — "long enough to read a statement and
decide". That reasoning assumes the operator can see it. In an unfocused context they
cannot, so the timeout would be measuring how long they spent in a different organisation.

- **The broker is already per-wiring** (`wiring.confirmations`), so each open org has its
  own. This rule is per-broker and needs no cross-context machinery.
- **The clock starts when the context is first focused after the park**, and pauses again
  if focus leaves. A request can therefore sit indefinitely, which is the accepted cost —
  the alternative is an agent's proposal dying because the operator was elsewhere.
- **The rail shows amber for the whole time it is parked**, focused or not. A stopped
  clock that is also invisible would be a request that never resolves and never says so.
- **Nothing else about the broker changes.** `.busy` still refuses a second park in the
  same context; the typed word is still `confirm`; the production block still refuses
  before the broker is reached.

---

## 10. Where cross-context state lives — and the crack it opens

`~/.wakil/` is organised strictly per org: `orgs/<org>/{org.json, active.json,
projects.json, providers/}`. Every existing file belongs to exactly one organisation.

**"Which contexts are open" belongs to none of them**, and this spec will not invent a
home for it inside one org's directory — a `personal/open-contexts.json` naming `initech`
would be a file in one boundary describing another.

So: `~/.wakil/window.json`, at the root, holding the open context keys and the focused
one. Nothing else. No credentials, no project contents, no environment — a list of
`(org, project)` pairs the operator themselves opened.

**This is a deliberate crack in the boundary and must be recorded as one.** Until now,
nothing in `~/.wakil` outside `orgs/` knew that two organisations both existed for one
operator. A file that names `initech` and `umbrella` together asserts that one person works on
both. That is already true of the directory listing under `orgs/`, which is why the cost
is judged acceptable — but "already leaked elsewhere" is a weak argument and the next
person to add a root-level file should have to make it again rather than cite this one.

---

## 11. Two calls made for the operator's review

### 11.1 An org may be open with no project

**Yes.** An org with no active project is a real state today — `active.json` can name no
project, and `WindowSession` already appends *"no project root available yet, so this
session runs in `<home>` instead"*. Forbidding it would make a freshly-created org
unopenable in the very UI meant to make orgs reachable.

Such a context has its five servers, an empty canvas and no harness session. The rail
shows the org with no projects beneath it. ⌘P's `org` row exists for exactly this.

### 11.2 The void transitions rather than cutting

**400ms, matched to §7's existing environment change.** A hard cut on every ⌘P would make
the room flicker between hues during ordinary navigation, and §7's whole premise is that
motion carries meaning — an instantaneous change is the one motion that says nothing.

The risk is the opposite failure: a 400ms transition means that for 400ms after switching
into production, the room is not yet production-coloured. The banner is correct
immediately and the gate does not consult the hue, so nothing unsafe turns on it — but if
the walk finds the delay reads as "not production yet", the answer is a faster transition,
not a cut.

---

## 12. What this does not do

- **No tab bar, no dropdown, no sidebar.** §1, principle 1.
- **No change to the write gate, the production block, the confirmation plane's mechanics
  or `origin`.** The only broker change is §9's clock.
- **No change to `CurrentOrg`.** `WAKIL_ORG` stays launcher-declared and config still
  cannot set the ambient org. Each wiring is *launched* with its org by Wakil.app, which
  is the launcher — the invariant is satisfied exactly, not bent.
- **No second window.** macOS multi-window is orthogonal and untouched.
- **No org creation, deletion or provider registration in-app.** Those stay on the CLI;
  this sub-phase reads the org registry and never writes it.

---

## 13. Verification

- `ContextRegistry` is in `WakilKit` and gets real tests: idempotent open, close stopping
  servers, focus changes, a failed open leaving the registry unchanged.
- `ctx_list_orgs` gets a Go tool test asserting another org's projects are **not**
  enumerated (§5).
- The broker's paused clock gets a test: park in an unfocused context, advance well past
  120 seconds, focus it, confirm it is still live.
- **The rail, ⌘P and the void are in `WakilApp` and cannot be tested.** That is the same
  limit 2c-ii-b hit, and the same answer applies: an acceptance runbook, walked.
  `docs/wakil/phase-2d-acceptance.md`, unwalked and unmarked until the operator runs it.

The runbook must ask two things nothing here decides:

1. **Does the rail's amber carry?** A production confirmation parked in a collapsed org,
   noticed or missed while the operator works elsewhere (§7's stated risk).
2. **Is fifteen servers and six sessions actually bearable** on the operator's machine,
   in memory and in Claude session budget? The design accepted that cost on their word;
   only a day of real use answers it.

---

## 14. Open questions this leaves

- **What happens to an open context when its org is removed by the CLI mid-session?**
  `RemoveOrg` refuses while providers or projects exist, so the window is unlikely to see
  it — but "unlikely" is not "cannot", and the honest answer is probably that the context
  closes with a diagnostic rather than that the registry polices the filesystem.
- **Is one focused context per window right, or should the canvas ever show two at once?**
  Deliberately not answered. Splitting the canvas across credential boundaries is a much
  larger idea and the room's single-environment premise (§8) would have to go first.
