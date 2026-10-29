# Keyboard: one keymap, shown and changed in Settings

**Date:** 2026-10-28
**Status:** design written without a brainstorm (the operator said "skip"); every choice below is
a call made for the operator and is flagged as one; builder check done; awaiting the
operator's review
**Sub-phase:** Keyboard, a new Phase 3 row after Names. Follows main c0b8423 (rail, #82).

---

## Problem

Wakil's shortcuts are written straight into the code, in about thirty places:

- **34 menu chords in `AppScene.swift`**, each a `.keyboardShortcut` on a menu button. Some are
  shared on purpose: in a focused browser pane ⌘T, ⌘W and ⌘⇧G do the browser's thing, and
  everywhere else they do the editor's or the pane's thing. `browserKey` hand-codes that rule.
- **Keys that only work inside a pane:** the db grid (`DataSurfaceKeys`), the query line
  (`QueryLineKeys`), the editor's Files/Search/Changes columns, the terminal's ⌘C, Esc in prompts.
- **Push-to-talk:** ⌥ held on its own (`ListeningMachine`).
- **Chords written as text:** tooltips repeat the chord in a string ("New Tab (⌘T)", "Show Panes
  ⌃⌘R", "Files ⌘B · Search ⌘⇧F · Changes ⌘⇧G").

So there is nowhere to see every key at once, and no way to change one. Picking a free chord for a
new feature means reading a comment that lists the taken ones by hand ("Verified free — the window
binds ⌘↩, ⌘W, …"), and that list is already stale. A tooltip goes stale too, without any warning,
whenever its chord changes.

## Calls made for the operator (flagged for review)

The operator skipped the questions, so all of these are mine:

1. **One table, in WakilKit, is the only place a chord is written.** The menu bar, the dispatch
   rule, every tooltip, ⌘K and Settings → Keyboard all read it.
2. **Only menu commands can be changed.** Keys that live inside a pane (grid arrows, Space, Esc,
   the terminal's ⌘C), the editor's own Monaco keys, the system's editing keys (⌘C/⌘V/⌘X/⌘Z/⌘A) and
   push-to-talk are **listed but fixed**, so the list is complete without exposing everything to
   rebinding at once.
3. **Taking a chord moves it, it is not refused** (rule 7). When the chord you record already
   belongs to another command in the same place, your command gets it and the other one is left
   with no chord. The row says what it took, and offers Undo.
4. **One chord can serve two places, as it does today.** A command bound to a kind of pane (in a
   browser pane, say) wins while that pane is focused. Everywhere else the command bound to
   anywhere wins. If neither applies, the key goes on to whatever holds the keyboard. That's
   `browserKey`'s rule, generalised and made data.
5. **Some chords are refused, and Decision 50 records why.** The refusals are:
   - a chord with no ⌘ or ⌃ (F1–F19 excepted), because it would steal typing;
   - the system's own chords: ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘Tab, ⌘`, ⌘Space and ⌃Space;
   - the editing chords: ⌘C, ⌘V, ⌘X, ⌘Z, ⇧⌘Z and ⌘A.
6. **The overrides live in `~/.wakil/settings.json` under `"keys"`.** That's the Wakil-wide tier,
   next to `"editor"` and `"browser"`. Only the differences from the defaults are stored, so a new
   default reaches anyone who never changed that command.
7. **Changes go through the registry:** `ctx_keyboard` reads and `ctx_set_key` writes (Invariant
   2). **`ctx_set_key` is the operator's only**: it joins `ctx_set_editor_settings` and
   `ctx_set_browser_settings` on `PermissionPrompt`'s operator-only list (Decisions 30 and 38).
   The agent can read the keymap but can't rebind keys.
8. **⌘K rows show their chord** on the right, read from the table. This is new. It is small, and
   it's the cheapest way to learn the keys.
9. **There's no dialog anywhere.** Rule 1: nothing here is destroyed. Restore All Defaults leaves
   an Undo line, not a confirmation.

## What the operator gets

- **Settings → Keyboard**, a node in the Settings sidebar below Browser:
  - A search field at the top that matches a command's title or its chord: typing "⌘T" or "tab"
    both find New Tab.
  - Every command, grouped as the menu bar groups them: Conversation, Pane, Editor, Browser and
    Window. Each row shows the command's title, where it works (*anywhere*, *in a browser pane*,
    *in an editor pane*), its chord and ↺ when the chord differs from the default.
  - **Click a chord to record a new one.** The chord box says *Type a shortcut* and listens. The
    next allowed chord is saved at once (rule 2: no Enter). Esc, or a click elsewhere, cancels and
    keeps the old chord (rule 4). ⌫ while recording leaves the command with no chord.
  - A refused chord is shown in the row and names Decision 50 (rule 8: shown whole), and recording
    continues.
  - When the chord came from another command, the line under the row reads *Took ⌘⇧T from Reopen
    Closed Tab · Undo*. The other row now shows *none*. The line stays until the next change.
  - A *Fixed* group after the changeable ones lists the in-pane keys, push-to-talk (⌥ held) and
    the editor keys that a command chord would shadow (see Errors and edges). Each row is greyed
    and has no recorder.
  - **Restore All Defaults** sits at the bottom of the list. It leaves an Undo line in the same
    place.
- **The menu bar** shows each command with its current chord, so macOS's Help → search shows it
  too.
- **Every tooltip that names a chord** reads it from the table, so a changed chord shows up at
  once.
- **⌘K rows** show their chord, dimmed, on the right.

## What it does not do

- No chord sequences like ⌘K ⌘S, and no hold-to-act keys apart from push-to-talk.
- No keymap per organisation or per project. Keys are the operator's own, like the editor font
  size.
- No importing VS Code or Dia keymaps.
- No changing the editor's own Monaco keys, the terminal's keys, or the keys inside a pane.
- No global hotkeys that work while Wakil is in the background.
- Push-to-talk's key cannot be changed yet. It's listed, and changing it needs its own design,
  because it's a hold, not a chord.

## Design

### WakilKit: `Keyboard/`

- **`KeyChord`**: the key plus modifiers. It parses and prints the string form `⌃⌘R`, the same
  glyphs the tooltips use today, in macOS order ⌃⌥⇧⌘. Keys are matched by key code where the
  character would differ on a non-Latin layout, as `QueryLineKeys` already does.
- **`KeyCommand`**: a stable id (`pane.close`, `browser.reopenTab`, `conversation.new`), a title,
  a menu group, where it works (`anywhere` or a pane kind) and a default chord. The full list is a
  static table with one entry for each of today's 41 menu chords:
  - Tab 1 to Tab 8 are eight commands.
  - The shared chords are split into two commands each. That includes the browser's New Tab
    (⌘T) and Close Tab (⌘W), which today live inside `newScratch` and `closeFocusedTabOrPane`
    and have no menu item of their own. They become Browser-menu rows that show their chord as
    text.
  For the editor and terminal panes, a pane-specific entry isn't needed: `anywhere` falls through
  to the pane's own handling, as today.
- **`FixedKey`**: a title, a where and a printed chord, for the read-only group. It does no
  dispatch: the pane code that owns the key keeps it, and the table only describes it.
- **`Keymap`**: the defaults plus the overrides, which gives the current chord of every command.
  It holds two pure functions, and both are fully unit-tested:
  - `resolve(chord, focusedPaneKind)` returns the commands a press tries, in order: the pane
    kind's command first, then the anywhere command. An empty list means pass the key on. A
    command can decline at the press, as `browserKey` does today (the tab column's key with
    horizontal tabs, say). When it declines, the next command in the list runs, and the key is
    passed on when none is left.
  - `assign(id, chord)` returns the new overrides, plus the command the chord was taken from, if
    any. It refuses a chord Decision 50 lists.
- **`WindowModel.keymap`** is loaded from `ctx_keyboard` at start-up and after each
  `ctx_set_key`.

### WakilApp

- **`AppScene.commands`** builds its menus from the table instead of from literal
  `.keyboardShortcut`s. Every press goes to one place, `model.keyPressed(id)`, which runs the
  command, or, for a command bound to a pane kind when that pane isn't focused, resolves the chord
  again and passes it on. `browserKey` and its `otherwise:` argument fold into this.
  **Builder's constraint:** SwiftUI gives a chord to one menu item only. Where two commands share
  a chord, one menu item carries it and resolves at the press. The other shows the chord as text
  in its title, and the builder chooses how.
- **`KeyboardSettingsForm`**: the Settings node, the recorder (a local key-down monitor while
  recording, removed on cancel, the same pattern as `EditorColumn`'s) and the Undo line.
- **Tooltips and `CommandCatalog` rows** take the chord from `model.keymap` by command id. The six
  `.help(...)` strings that name a chord are rewritten to do the same.

### Go: `internal/wakilcore`

- `AppSettings` gains `Keys map[string]string \`json:"keys,omitempty"\``, an id mapped to a chord
  string. An empty string means deliberately no chord. Read-modify-write from disk at dispatch, as
  editor settings already do.
- `cmd/wakil-ctx` gains two tools:
  - `keyboard` returns the overrides and the file's error, whole.
  - `set_keys` takes the **complete** new `keys` map and writes it in one go. Go checks only that
    each chord is the right shape.
- **`ctx_set_key` is a Swift registry action** (`id`, plus `chord` or `null` to restore the
  default). It runs `Keymap.assign`, so the move and Decision 50 hold however it is reached:
  through Settings or through `--dispatch`. It then sends `set_keys` the whole resulting map, so
  a move, an Undo and Restore All are each one atomic write. Undo and Restore All are the same
  action, sending the earlier map back, or an empty one.
- An id the build doesn't know is kept on disk and ignored, so an older build can't wipe a newer
  one's binding. That's the opposite of `AppSettings`'s rule of dropping unknown keys: keep
  `keys` as a raw map, and merge the ids this build doesn't know back in before writing.

## Interaction rules

| Rule | How it is met |
|------|---------------|
| 1 Confirm only what destroys | No dialogs. Taking a chord and Restore All both leave Undo instead. |
| 2 Enter never required | A recorded chord saves the moment it's typed. |
| 3 A new input arrives focused | Clicking a chord starts recording at once; the box is focused. |
| 4 Anything that waits can be cancelled | Esc, or a click outside, ends recording with nothing changed. |
| 5 Work in flight shows it | Between the press and `ctx_set_key`'s reply, the chord box shows the new chord dimmed and doesn't record again. |
| 6 Stay where the operator was | After a save, Undo or Restore All, the list keeps its scroll position and search. |
| 7 Override, don't refuse | A taken chord moves. Decision 50's refusals are the only refusals, and they name it. |
| 8 Errors shown whole | An unreadable `settings.json` shows its error whole above the list, and the defaults stay in force. |
| 9 Defaults suggest | Every default can be changed or cleared; nothing forces a command to have a chord. |

## Errors and edges

- **`settings.json` can't be read:** the defaults hold, the error shows whole at the top of the
  node, and recording is off until the file reads again. A write would replace a file Wakil
  couldn't read, which is the data-loss case.
- **A stored chord Decision 50 now refuses**, from a hand edit or an older build: it is ignored,
  that row shows the refusal, and the default is in force.
- **Two stored overrides on the same chord in the same place**, from a hand edit: the first in
  table order wins, and the other row says so.
- **The editor's own keys:** today a menu chord fires before Monaco sees the key, because a menu
  command fires whatever holds focus. That doesn't change. A chord taken over from the editor (⌘D
  is the editor's select-next-match outside a browser pane) is listed in Fixed as "⌘D in the
  editor: select next match, when no command has ⌘D", so the operator can see what binding ⌘D
  would cost.
- **A chord the menu bar can't draw** (a bare F-key with no modifier) still works through
  `keyPressed`, and Settings shows it.

## Testing

- **WakilKit:**
  - The default table has no two commands sharing a chord in the same place, and every one of
    today's 41 menu chords is present.
  - A command that declines falls through to the next one.
  - `ctx_set_key` is refused for the agent.
  - Shared chords resolve both ways: ⌘T in a browser pane and outside one.
  - `assign`: it takes a chord and reports where from, refuses each Decision 50 chord, clears a
    chord, and restores a default.
  - Parsing and printing round-trip.
  - An override for an unknown id is ignored.
- **Go:**
  - The `keys` map round-trips, and an unknown id survives a write of another key.
  - A chord in a bad shape is refused, and nothing is written.
  - A missing file reads as no overrides.
- **e2e:**
  - Rebind New Scratch Tab through `--dispatch ctx_set_key`, press the new chord through the
    driver and see a scratch tab, then press the old chord and see nothing.
  - Record a chord in Settings and see the Undo line, then Undo.
  - A refused chord shows Decision 50.
  - ⌘K rows show the chord.
  - A tooltip shows a rebound chord.
- **Walk:**
  - Rebind a browser key and an editor key, then use them for a while.
  - Take a chord from another command and Undo it.
  - Restore All Defaults.
  - Check the menu bar and Help → search.

## Charter changes

- `north-star.md` §8: a **Keyboard** row after Names. North-star is already over its word limit
  (4485 of 4000), so the row is one line, and docs-check stays red until that is fixed
  separately. `make test` runs docs-check first, so until then, check the plan's work with
  `go test ./...` and the Swift tests directly.
- **Decision 50:** one keymap in WakilKit, with the overrides in `settings.json`. A taken chord
  moves to the new command. The refused chords are: no ⌘ or ⌃ (F-keys excepted), the system's
  chords and the editing chords, each listed.
- `design-language.md` §14: the Wakil-wide tier gains *Keyboard*.
