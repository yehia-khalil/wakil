# Settings revamp — design

Date: 2026-11-02 · Branch `worktree-settings-revamp` · Scope: every settings page **except a
project's Running page**, which another session owns (`RunningSettingsForm.swift` on
`yehia-khalil/workspaces-5-crews`).

## Why

A design review of the settings pane (impeccable critique, 2026-11-02, 25/40) found it reads
as a pile, not a place: the tree mixes three scopes with no headings, "Accounts" means three
different things, org-owned browsing data sits on an app-wide page, removal wears three
tones none of them red, text is cut in 21 places, and several read lines fall under 4.5:1.
The vocabulary in `SettingsForm.swift` is right; the pages have drifted from it.

Success: an operator finds any setting by scope at a glance, every control behaves by the
nine Interaction Rules, nothing is cut, and the pages share one set of tokens.

## Goals

1. **Tree grouped by scope**, each scope headed, names that mean one thing.
2. **Seven fixes** (below), each closing a finding.
3. **Tokens**: text opacity, spacing and radius come from `SettingsScale`/`SettingsPalette`.

## Non-goals

- The Running page, its row in the tree, its label and its identifiers.
- New settings. Every setting here exists today; only where and how it is drawn changes —
  except the production flag's setter (fix 5), the one new action.
- Changing what any setting stores or where (`~/.wakil/settings.json`, org and project files,
  Keychain refs stay as they are).

## Anti-goals

- An e2e check breaks because an identifier moved. `settings.*` identifiers and
  `SettingsNode.identifierFragment` values stay; a page that moves takes its controls'
  identifiers with it.
- A confirmation, refusal, Enter-to-commit or jump added anywhere without naming its rule.
- Any text truncated, ellipsised or clipped (memory: UI text never cut; "3× longer?").

## Constraints

- PRODUCT.md Interaction Rules 1–9; North Star Inv. 2 (actions are the only mutation path),
  Inv. 3 (panes observable), Inv. 8 (environment always visible); WCAG 4.5:1 on read text.
- `docs/wakil/design-language.md` §5 colour meanings, §6 typography, §14 settings vocabulary.
- **Shared types with the Running session:** `SettingsSection` keeps the optional
  `identifier:` parameter and `.fixedSize` title added on `workspaces-5-crews`. Any change to
  a `SettingsForm.swift` type stays source-compatible with that branch; renames of the Running
  row are asked of that session first.

## The tree

```
WAKIL                 heading
  Editor
  Browser             search, tabs, picture in picture
  Keyboard
<ORG NAME>            heading, styled as PROJECTS
  Organisation        Identity · Connections · Git · Agent instructions
  Accounts  N         was Providers: Claude accounts · Local models · Default account
  Quick tasks         its own page: model, ghost text, fast path, commit drafts
  Browsing data       moved from Browser: Clear data · Passwords
  Speech              stays per-org
PROJECTS              heading
  <project>
    Editor
    Running           (other session's)
    ENVIRONMENTS      micro heading, no extra level
      ● staging       › Databases · API
      ● production    › Databases · API
      + Add an environment
  + Add a project
```

- **Headings** are micro labels (§6), not nodes; WAKIL and the org heading do not open or
  close. PROJECTS keeps its close-all behaviour.
- **The org heading is the org's label**, uppercase; the page under it is named
  "Organisation", so the org's name is no longer a page title that changes when edited.
- **ENVIRONMENTS** is a micro label at the environments' depth inside an open project; it
  adds no selection stop and no level.
- **Environment dot**: green for a non-production environment, red for production (§5), from
  `SettingsEnvironment.production`; nil (old `wakil-ctx`) draws no dot.
- **Breadcrumbs** follow: `Wakil › Browser`, `<org> › Accounts`, `<org> › Quick tasks`,
  `<org> › Browsing data`, `<org> › Speech`; project paths unchanged.
- **Node cases**: `.providers` keeps its case and `identifierFragment` `providers` and is
  labelled "Accounts". New cases `.quickTasks`, `.browsingData`, `.speech` with fragments
  `quickTasks`, `browsingData`, `speech`.
- **Moves keep identifiers**: Clear data and Passwords keep `settings.browser.*`; the Quick
  tasks controls keep `settings.quickTasks.*` / `settings.org.quickProvider.*`; Speech keeps
  its row identifier. E2e checks that reach these by first selecting Browser or Providers or
  Organisation are updated to select the new node (`e2e/checks/seeded/3b-viii-*`,
  `3c-i` settings check, and the others `grep settings.tree.` finds).
- **§14 amendment (dated 2026-11-02)**: the tree above, the page section lists, and Speech
  recorded as per-org (the code and Invariant 11 already have it there; §14's table said
  app-wide).

## The seven fixes

1. **Destruction is red, and one control.** Add `SettingsPalette.destructive` (§5 red
   `#e85c5c`). Every Remove/Delete/Clear in settings is one `FormButton` style, `.destructive`,
   red text and edge; amber stays for caution and refusals. Rule 1 unchanged: only destroy or
   gate confirms.
2. **No text cut.** Remove every `.lineLimit(1)` and `.truncationMode` in settings (21 sites:
   tree labels, breadcrumb, `SettingsValue`, account rows, local model URLs, API entries,
   passwords). Long text wraps whole; a value that cannot fit beside its label moves under it
   (`underRowValue`), as §14 already says. The breadcrumb wraps by segment.
3. **Organisation fields save on leave** (Rule 2). Display name, Default account and Jira
   site join `WindowModel.savesOnLeave`; their Save/Revert buttons go. A refusal is shown whole
   under the field (Rule 8) and the field keeps the typed text.
4. **Databases and API entries** leave `FormCard` for `SettingsSection`/`SettingsRow`: each
   database or API entry is a section headed by its name; credential fields are
   `inPlaceField`; API stays read-only as today.
5. **The production flag is drawn and settable.** The environment page gets a "Production"
   row: `SegmentedChoice` No / Yes, with a `FormHint` saying where the answer comes from —
   "From the name: production." or "From the name: not production." when no explicit flag is set, nothing when it is. Choosing writes the
   explicit flag through a **new action** `ctx_set_environment_production(project, environment,
   production)` (Go `wakilcore` + `wakil-ctx` tool `set_environment_production`, operator-only Swift action, Inv. 2);
   a third segment "From the name" clears it. Rule 9: the name suggests, the operator decides.
6. **Tree keyboard.** ↑/↓ move the selection through visible rows (headings skipped), → / ←
   keep opening and closing, type-to-find selects the next visible row whose label starts with
   the typed letters (1 s reset). Esc on a pending destroy confirmation answers "Keep it".
   Selection never opens a branch (Rule 6).
7. **Contrast and tokens.** Read text ≥ 4.5:1 on the void: section headers, empty-value `—`,
   breadcrumb, footnotes and hints raised to the `SettingsPalette` secondary step. Text
   opacity collapses from 29 values to four named steps (primary, secondary, tertiary for
   decoration only, disabled); spacing from 14 values to the `SettingsScale` steps; corner
   radii from 6 to two (`field`, `slab`).

## Also in scope

- **Off/On order**: every two-way choice reads Off then On (Browser's picture-in-picture
  flips to match Editor's word wrap).
- **Quick tasks Model** becomes a `SegmentedChoice` per group only if every option fits the
  pane at 640pt; otherwise it stays a `Menu`, and §14 records it as the one exception, with the
  reason (an open-ended list of accounts and local models).

## Left to the builder

- The exact four opacity values and spacing steps, provided read text measures ≥ 4.5:1.
- Order of work and how it splits into tasks; fix 5's Go action can land first on its own.
- Wording of hints, within §12 voice.

## My calls (approved by the operator, 2026-11-02)

- Speech gets its own page rather than staying a row on Organisation, because the Accounts
  section it sat in moves to the Accounts page.
- Production flag gets a three-way choice (No / Yes / From the name) and a new action.
- The org heading carries the org's label; the page is "Organisation".
- Quick tasks Model: segmented if it fits, else a recorded `Menu` exception.
- E2e checks that navigate through moved pages are updated in this branch.

## Interaction Rules check

| Rule | How this design holds it |
|------|--------------------------|
| 1 Confirm only destroy/gate | No new confirmations; red marks the existing destroy confirmations. |
| 2 Enter never required | Fix 3 removes the last Save/Revert fields. |
| 3 New input arrives focused | Unchanged; add-environment/add-project keep it. |
| 4 Waiting can be cancelled | Unchanged; no new waits. |
| 5 Work in flight shows it | Production flag write shows in-flight like other choices. |
| 6 Stay where the operator was | Moves keep selection on save; ↑/↓ never open branches. |
| 7 Override, don't refuse | Production flag overrides the name. |
| 8 Errors shown whole | Fix 2 and fix 3: refusals wrap, never cut. |
| 9 Defaults suggest | Production from the name is a suggestion the operator can change. |
