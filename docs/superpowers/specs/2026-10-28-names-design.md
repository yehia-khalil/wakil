# Names — conversations named by the quick model, renamed anywhere; browser tabs renamed

**Status:** design · **Date:** 2026-10-28 · **Branch:** `yehia-khalil/names` (from `main` 8a8875b)
**Plan:** `docs/superpowers/plans/2026-10-28-names.md`
**Depends on:** 3d-i (tab groups, pinned section, vertical column) for the browser half only. The
browser half is designed against `../wakil-public-3d-i` (`BrowserTab`, `BrowserSavedTab`,
`BrowserPin`, `BrowserPaneHeader`, `BrowserTabColumn`, `BrowserTabMenu`, `BrowserGroupNames`) and is
built after 3d-i merges into `main`.

The operator asked for this to be designed without questions. Every decision the operator did not
make is marked **(my call)** with its reason, so it can be overturned line by line.

## Why

A conversation's title today is its first message cut at 48 characters (`conversationTitle`,
`Core/Conversation.swift`; set once by `PlaceAgent.noteSend`). The first message is often an
instruction ("look at this", "why does the staging deploy …"), so the Running column, ⌘P's Running
group and the agent chips list several conversations that read alike. The conversations spec
(2026-10-23, call 6 and "What it does not do") left naming and renaming out; this phase adds both.
A browser tab is called by its page's title, which a site sets and changes; the operator wants to
call a tab what it is for.

## What the operator gets

### 1. Conversations are named once by the quick model

1. After a conversation's **first exchange** — its first turn that ends without error — Wakil asks
   the organisation's quick-tasks model (`QuickTasks.respond`, Decision 42) for a name of **up to
   five words**. It sends only the operator's first message and the start of the agent's first
   reply (§Journal and what is sent).
2. The name replaces the first-message title wherever the conversation is listed (§4). Until it
   lands, and if it never does, the first-message title shows, as today.
3. **It is asked once and never changes on its own.** A later turn, a resume, a provider switch or
   a relaunch never asks again.
4. **Settings → the organisation's Providers page → Quick tasks → "Name conversations with AI",
   On by default.** Off: nothing is sent, and new conversations keep the first-message title.
   Names already given stay.

### 2. Rename a conversation, any time

| Where | Gesture | What opens |
|---|---|---|
| ⌘K, and ⌘P after `>` | **Rename Conversation…** (shown while a conversation is on screen) | the palette's name step for the conversation on screen |
| ⌘P's Running group | **⌘R** on the selected row (the footer says `⌘R rename`) | the name step for that row's conversation |
| The Landing's Running column | right-click a row → **Rename…** | the row's title becomes a field, in place |
| An agent chip | right-click → **Rename…** | the palette opens on the name step for the chip's conversation |
| The agent | `conversation_rename` | — |

- **The operator's name always wins.** The quick model's name is kept beside it and never
  overwrites it; a model reply that lands after a rename is stored, not shown.
- **Clearing** (an empty name) removes the operator's name: the model's name shows again, or, with
  none, the first-message title.
- Every field (§Interaction rules) arrives focused with the shown name selected; leaving it keeps
  what was typed; Return keeps it; Esc puts the name back; empty means clear; unchanged does
  nothing.

### 3. Rename a browser tab

- Right-click a tab → **Rename Tab…**, and **Clear Name** when the tab has one. ⌘K → **Rename
  Tab…** on the focused browser pane's active tab.
- The name shows instead of the page title in the strip (full mode), the column, and the pinned
  tiles' tooltip. It is **kept across navigations in that tab** until cleared, and **saved with the
  tab**: in the layout, in the closed-tabs list (so ⌘⇧T brings it back), and for a pinned tab in
  `pins/<project>.json`.
- **A mark** — a small `pencil` glyph after the name, at the title's rest opacity — says the name is
  the operator's. **The page title stays in the tooltip:** `<name> — <page title>`.
- The agent: `browser_rename_tab`. `read_pane` lists each tab's `name` beside its `title`.
- **Group naming uses tab names.** `BrowserGroupNames.titles` sends a tab's name in place of its page
  title when it has one, and a named tab counts as titled.

### 4. Where names show

| Surface | Shows | Source |
|---|---|---|
| Landing → Running | the conversation's title | `LiveConversation.title` |
| ⌘P → Running | the title | `RunningConversationsSource` |
| Agent chips | `<place> — <title>` | `AgentChip.title` |
| Landing → Continue, ⌘P → Sessions | a past conversation's stored name, else today's label | `PaletteItems.sessionItems` |
| `session_list` (live) | `title`, and `titleSource` | `LiveConversation.json` |
| Close-question and refusal sentences | the title | `PlaceAgent.title` |
| Browser strip (full), column rows | the tab's name, else its page label | `BrowserTab.label` |
| Pinned tiles, folded strip entries | tooltip and spoken name: `<name> — <page title>` | `BrowserTab.tooltip` |
| ⌘K Rename Tab… prefill, tab suggestions in the address bar | the shown label | `BrowserTab.label` |

**There is no thread header today** (`ThoughtThread.swift` draws no title), so the conversation on
screen has none to rename from or show in. **(my call)** No header is added: a new piece of chrome
over the thread is a layout change the operator did not ask for; the on-screen conversation is
renamed through ⌘K / ⌘P, and its name is in ⌘P's Running group.

## Calls made for the operator

1. **The title is derived, from three slots.** `PlaceAgent` keeps `operatorName: String?`,
   `aiName: String?` and `messageTitle` (today's `title`). `title` becomes computed:
   `operatorName ?? aiName ?? messageTitle`. The rule is a pure function, `conversationDisplayTitle`,
   in `Core/Conversation.swift`. **(my call)** Keeping the model's name in its own slot is what makes
   "clearing returns to the AI's name" possible and lets a late reply land without overwriting.
2. **Invariant 2 — two slots, two paths, never two paths to one slot.** `operatorName` is written
   only by `conversation_rename`. `aiName` is written only by the naming quick task, which is not an
   action, as 3d-i's group naming (`nameDueGroups`) and 3a-ii-b's commit draft are not. Nothing else
   writes either. **(my call)** Making the model's name a dispatch would put a `source: ai` parameter
   in the agent's tool list that the agent could forge.
3. **`conversation_rename` is `.control`, agent-reachable**, registered with the `session_*` actions
   in `StandardActions.swift` and parked on `ConversationBroker` as `.rename(conversation:name:)`,
   drained by the window's `conversationPump` (the pattern `session_switch` uses, for its reason: no
   `WindowModel` exists at registration). Parameters: `conversation` (optional; default the caller's
   conversation, or the one on screen for the operator) and `name` (required; empty clears).
   - **An agent renames only its own conversation.** Given another conversation's id it is refused:
     *"conversation_rename: an agent renames only its own conversation (conversations call 5: an
     agent does not know about the others)"* — Rule 7's "refuse only what a recorded decision
     forbids, and say which".
   - **The agent's rename is the operator's name**, not a third slot. **(my call)** The agent renames
     because the operator asked it to; Rule 7 lets the later value win. The journal records who.
   - An id that names no live conversation is refused in the handler, before parking, so the caller
     hears it: *"conversation_rename: no live conversation <id>"*.
   - Reply: `{"renaming": <id>, "name": <name or null>}`, as `session_switch` answers `switching`.
4. **The name is cleaned, not refused.** An operator name is trimmed and its whitespace (newlines
   included) collapsed to single spaces; it is kept whole otherwise — views truncate it at their own
   width, as they do the first-message title. **(my call)** Rule 9: no length limit enforced.
5. **The model's name is parsed like a group name.** `ConversationNames.parse` reads
   `{"name": "..."}` (a code fence is read inside), drops surrounding quotes and trailing `.!?:;,`,
   collapses whitespace, keeps the first five words, then the first whole words that fit in 48
   characters. A reply that leaves nothing throws `QuickModelError.invalidReply` with the reply
   whole. **(my call)** Unlike group names, inner punctuation stays: conversation subjects carry
   `C++`, `2c-ii`, `API/v2`.
6. **When it is asked.** At the `.result` that ends a conversation's first turn with
   `isError == false`, when: the switch is on; the conversation has a first message; no name was
   asked for it before (`PlaceAgent.namingAsked`); it is not a resume (a resumed conversation starts
   with `namingAsked = true`); and **its organisation is the window's** (`agent.place.organization
   == organization`) — the quick tasks are the window's organisation's, and another organisation's
   conversation text must not reach them (Invariant 4). A conversation whose first turn ends while
   its organisation is not the window's is asked when that organisation's quick tasks are next built
   (`rebuildQuickTasks` ends by naming every due conversation). **(my call)** An errored first turn
   does not use up the one ask; the first clean exchange does.
7. **When the reply lands.** It is applied only when the quick tasks are still the ones asked
   (`quickTasksGeneration`) and the conversation's organisation is still the window's. A reply
   dropped by a rebuild clears `namingAsked`, so it is asked again at the next build. It is applied
   to a conversation closed meanwhile too: it goes to disk under the lineage root, so Continue shows
   it. A failure is recorded by `QuickTasks` (Settings shows the provider's last error whole) and in
   the journal; the conversation keeps its first-message title and is not asked again. **(my call)**
   One ask means one ask; a retry loop would spend the operator's quota on a label.
8. **Persistence: `~/.wakil/orgs/<org>/conversation-names.json`**, written by Swift
   (`ConversationNameFile`, `App/`), as `BrowserOrgFiles` writes the organisation's browser files:
   `{"<lineageRoot>": {"operator": "...", "ai": "..."}}`, either key absent when unset; an entry with
   neither is removed. Keyed by **lineage root**, the identity a conversation keeps across every
   resume (Go's `SessionMeta.LineageRoot` doc names "a name given to it" as its use). The file is
   the organisation's, under its own directory, written with the conversation's own organisation,
   never the window's (Invariant 4). It refuses an organisation directory that does not exist, as
   `OrgDirFor` does. Written atomically (temporary file, rename).
   - A rename before the conversation has a lineage root (before its first turn) holds in memory and
     is written when the root is first set (`WindowModel.send`).
   - A resume reads the entry for the root it inherits into `operatorName` and `aiName`.
   - Continue and ⌘P's Sessions read the file once per listing and title a past row
     `operator ?? ai ?? <CLI ai-title> ?? <first prompt> ?? id`, by the row's `lineageRoot`.
   - **The set of live conversations stays unpersisted** (conversations call 7); only names are new
     on disk. **(my call)** A Swift file rather than a `wakil-ctx` tool: like `layouts/` and
     `browser/`, it is Wakil's bookkeeping about its own surfaces, read and written only by the
     window, and Continue's titles are composed in Swift already.
9. **The setting is per organisation, in Quick tasks.** `org.json` gains `conversationNames`
   (`*bool`, nil = on), exactly as `commitDrafts` (3a-ii-b): `wakilcore/org.go`, `orgupdate.go`,
   `configtree.go`, `wakil-ctx update_org`, `SettingsOrg.conversationNames`,
   `WindowModel.OrganisationSwitch.conversationNames`, a `quickTaskSwitchRow` labelled **Name
   conversations with AI**, hint *"Names a conversation from its first message and reply"*.
   **(my call)** The operator suggested "Settings → Agent"; there is no Agent page, and Quick tasks is
   where every quick-model switch already sits. Per organisation, because what is sent is the
   organisation's conversation, and an organisation's data policy may forbid it (Decision 18's
   reasoning for speech). Turning it Off drops a reply still in flight (the rebuild bumps
   `quickTasksGeneration`).
10. **One name step in the palette, for every palette rename.** A new `CommandInput.name`: a text
    step that arrives **filled with the shown name, selected**; an empty line is a value (clear);
    its one row reads `Rename to “<typed>”`, `Clear name — back to “<fallback>”` or, unchanged,
    `Keep “<name>”` (which runs nothing and closes). Return runs it. **The palette closing — a click
    outside, a plane taking over — runs a changed name too** (Rule 2: focus leaving keeps it). **Esc
    cancels** it, as the 3d-i group field's Esc puts the name back. No recents. **(my call)** Esc is
    the one explicit "never mind" gesture a name field has on macOS (Finder, the 3d-i group field);
    every other way of leaving keeps.
11. **⌘R on a Running row.** **(my call)** The operator asked for rename "on a listed conversation"
    in ⌘P's Running group, and a palette row has one action (Return switches to it). A second key
    on the row is the smallest addition: ⌘R, named in the footer while a Running row is selected.
    ⌘R reads "rename" in no other palette.
12. **The chip and the pinned tile open the palette.** **(my call)** A chip, a pinned tile and a
    folded strip entry draw no title to edit in place, so their **Rename…** opens the palette (⌘P
    mode) directly on the name step for that conversation or tab. The Landing row and the full tab
    entry and column row edit in place. Esc closes the palette straight back (Rule 6: back where the
    operator was).
13. **A tab's name is `BrowserTab.name: String?`.** `label` becomes `name ?? pageLabel`, with
    `pageLabel` today's rule (title, else host, else New Tab). History, bookmarks and the agent's
    `title` keep the page's title. **(my call)** A bookmark or a history row is about the page; the
    name is about the tab.
14. **`browser_rename_tab`** — `.control`, agent-reachable, beside `browser_group` (whose `rename` is
    the same kind of write): `pane` (optional, the focused or only browser pane, as every
    `browser_*` resolves it), `tab` (default the active one), `name` (required; empty clears;
    cleaned as call 4). Never selects the tab (Rule 6). Refuses only a tab that does not exist
    (`BrowserActionError.noTab`) and the pull-request rows (`pullRequestGroupRefuses("renamed")` —
    3d-i ruling 18: they are a listing, never saved). Saves the layout (`persist(pane)`).
15. **A pinned tab's name is written to its pin at once.** `BrowserPin.name`, today a group's, also
    carries a tab pin's name; the pin is updated and every other pane of the project reconciled
    (`reconcileOthers`), as `browser_pin` does. **(my call)** 3d-i holds a pinned *page* until Pin
    Current Page because a navigation is incidental; a rename is deliberate, so it does not wait.
    `BrowserPinTab` (a pinned group's tabs) gains `name` too, written on Pin and Update Pin.
16. **The agent may rename a tab on a production site.** **(my call)** The name never reaches the
    page; it is Wakil's label, as a group name is. No site question, no gate.

## Interaction rules

| Rule | How this meets it |
|---|---|
| 1. Confirm only what destroys | Rename and clear destroy nothing (clear returns to a name still held). No dialog anywhere. |
| 2. Enter is never required | Every field and the palette name step keep a changed name when focus leaves or the palette closes; Return is a shortcut. |
| 3. A new input arrives focused | The Landing row field, the tab field and the name step arrive focused with the shown name selected. `expect.focus` checks pin the step. |
| 4. Anything that waits can be cancelled | The naming request is background work the operator never waits on; Off drops it. Nothing blocks a turn or a field. |
| 5. Work in flight shows it, and cannot be fired twice | The name step marks its row while `conversation_rename` / `browser_rename_tab` runs and takes no second Return (`PaletteModel.inFlight`). A field commits once (`done`, as `BrowserGroupNameField`). The naming request is asked once per conversation (`namingAsked`). |
| 6. Stay where the operator was | Renaming never switches conversation, selects a tab or moves the canvas. A chip's or tile's Rename returns to where the operator was when the palette closes. |
| 7. Override or ignore; don't refuse | A later name overrides; an unchanged name is ignored. Refused only: an agent renaming another conversation (conversations call 5), a conversation or tab that does not exist, the pull-request rows (3d-i ruling 18) — each saying which. |
| 8. Errors shown whole, block only what they must | A failed write of `conversation-names.json` keeps the name in memory and puts the error whole in `status`: *"conversation names: could not save <path>: <error> — the name holds until Wakil quits"*. A refused rename shows its sentence whole in the palette's error row or `status`. A naming failure goes to Settings → Quick tasks (the provider's last error, whole) and the journal, and blocks nothing. |
| 9. Defaults suggest | "Name conversations with AI" defaults On and is one click Off; the model's name is a default the operator overrides. |

## Journal and what is sent

- **`conversation_rename` and `browser_rename_tab`** are journalled by `ActionRegistry.dispatch` like
  every action: params (the name included — it is not a secret), origin (ui or agent), caller,
  outcome.
- **The naming request is a quick task, not a dispatch.** What leaves Wakil, and to where:
  - **To:** the organisation's `respond` route (Decision 42): its Quick tasks provider, falling back
    once to the running account when that is unreachable. That may be a warm `claude` session on the
    organisation's account or a local model; nothing else.
  - **Instructions** (fixed copy): *"Name this conversation from its opening message and the start of
    the reply. Answer with at most five words, no quotes, as JSON: {"name": "..."}."*
  - **Input:** `MESSAGE:` the operator's first message as typed — the `you` row's text, without the
    identifier note (2d-i) or an instructions update (3a-iii-b) — cut to its first 1,000 characters;
    a blank line; `REPLY:` the agent's text (`assistantText` events) of the first turn, joined, cut to
    its first 600 characters. No tool calls or results, no pane contents, no file paths beyond what
    those two texts contain. `maxTokens: 24`.
  - **Journal:** one line per ask, `conversation_named`, through a new
    `ActionRegistry.journalQuickTask(action:params:caller:outcome:)` (as `journalIdentifierEvent`
    journals a non-action): params `{"provider": <routed id>, "messageChars": n, "replyChars": n}`,
    outcome `ok: <name>` or the error whole. **(my call)** The words sent are not copied into the
    journal: they are already in the transcript, and the journal records that they left and where.

## Errors and edges

- **Off, or no quick tasks built:** nothing is asked; the first-message title stays.
- **The model is unreachable, slow or answers nonsense:** the title stays the first message; Settings
  shows the provider's error (`QuickTasks` records it); not asked again.
- **The operator renames while the model is asked:** the operator's name shows; the model's lands in
  `aiName` and on disk, and shows only if the operator clears.
- **The conversation is closed before the reply:** the reply is written to disk under its root;
  Continue shows it.
- **An organisation switch mid-ask:** the reply is dropped (generation), and the conversation is asked
  when its organisation's quick tasks are built again.
- **Two live conversations with one title:** `switchToConversation` by title already refuses an
  ambiguity and names both ids; renaming one resolves it.
- **`conversation-names.json` unreadable:** listings fall back to today's titles and `status` says
  *"conversation names: <path> is unreadable: <error>"*; a write over an unreadable file is refused
  rather than replacing it (the operator's names are in it), with the same sentence.
- **A tab renamed then closed and reopened (⌘⇧T):** the name comes back with it.
- **A pinned tab renamed in one pane:** every pane of the project that shows the pin takes the name
  at its next reconcile.
- **A 3c layout or a 3d-i pins file without names:** decoded with `name` absent.

## What it does not do

- No thread header, and no window title.
- No naming of past conversations that never had a name (Continue keeps the CLI's title for them).
- No AI renaming of tabs; no automatic tab names.
- No rename of a pinned group's tabs from the group's pin (each tab's own pin carries its name).
- No change to `session_switch`, Close, or what Continue lists — only to the labels.

## E2E coverage plan

The chat stub (`e2e/driver/chatstub.go`) gains `ConversationNameReply = {"name":"Fixture Named
Conversation"}`, answered when a message contains `conversationNameAsk = "Name this conversation"`,
and a slow variant when the first message starts `slow name` (it waits `SlowReply`). Checks point the
organisation's Quick tasks at `{chatStub}` as `3a-ii-b-draft.jsonl` does.

| Check | Dir | Proves |
|---|---|---|
| `names-ai-names-a-conversation.jsonl` | agent | after a first turn, ⌘P Running and the Landing's Running show "Fixture Named Conversation"; `session_list` live `title` and `titleSource: "ai"` |
| `names-ai-off.jsonl` | agent | parity `settings.org.conversationNames.off` ↔ `ctx_update_org {conversationNames:false}`; a first turn keeps the first-message title |
| `names-rename-palette.jsonl` | agent | ⌘K → Rename Conversation… → `expect.focus palette.query` → type → Return; title changes; again with an empty line → back to the AI name |
| `names-rename-running-cmd-r.jsonl` | agent | ⌘P, a backgrounded conversation's Running row, `cmd+r`, type, `escape` (unchanged) then again with Return; its chip's label carries the name |
| `names-operator-wins.jsonl` | agent | `slow name …` first message; rename before the reply; after `SlowReply` the operator's name still shows; clear → the AI name |
| `names-rename-dispatch.jsonl` | agent | `conversation_rename` dispatch, and `refuses: "no live conversation"` for an unknown id |
| `names-settings-switch.jsonl` | seeded | the switch row's frame on a narrow pane (`do.resize`), `expect.frame` inside `settings.pane` |
| `names-tab-rename.jsonl` (3d-i) | seeded | `browser_rename_tab`; the strip shows the name and `browser.tab.<id>.customMark`; `read_pane` `tabs[0].name`; a navigation keeps it; ⌘K Rename Tab…; clear |
| `names-tab-rename-column.jsonl` (3d-i) | seeded | the same in the vertical column (`browser_tab_column`), at a narrow `do.resize` |
| `names-tab-pinned.jsonl` (3d-i) | seeded | pin, rename, the other place's pane shows the name after its reconcile; ⌘⇧T after a close brings the name back |

**Uncoverable** (lines for `e2e/checks/uncoverable.tsv`): the Landing row's and the chip's
**Rename…** and the tab menu's **Rename Tab…** / **Clear Name** live in context menus, which no arm
opens (`editor_rename`'s case) — their dispatches are covered above; the parity of
`conversation_rename` and `browser_rename_tab` (the operator's channel is typing and leaving, not a
click: `ctx_rename_project`'s case); `browser.tab.<id>.customMark` (an `Image`, read by frame, not
pressed); the tooltips (`.help`, not in the tree's text).

**Unit tests carry what no check sees**: the precedence, the parser, what is sent and its cuts, the
once-only rule, the organisation guard, the generation drop and re-ask, the file round trip and its
refusal, the palette name step's keys, the agent's own-conversation refusal, the tab name surviving a
page report, a layout round trip and a pin reconcile, and group naming preferring names.

**The human half of the walk** (at most ten): the model's names on a real provider read like
names; the Landing row field in place; a chip's Rename… opens and returns; the tab mark at both
densities and in production red; a pinned tile's tooltip; a relaunch keeps tab names and pinned tab
names; after Quit, Continue lists the name; Off sends nothing (the quick provider's log).

## Docs this phase updates

`docs/architecture/state.md` (the new file, and `name` in the layout and pins rows),
`docs/wakil/north-star.md` §8 (a **Names** row: *Conversations named by the quick model and renamed
anywhere; browser tabs renamed* — waits on 3d-i for its browser half), and this spec's dated
amendments where the build disagrees.
