# 2e-ii: add, rename and remove a project and an environment from Settings

**Date:** 2026-10-22
**Status:** spec awaiting the operator's review. The operator skipped the design questions, so
every decision below is the designer's call, listed under *Calls made for the operator*.
**Sub-phase:** 2e-ii, phase map row (north-star.md, after 3a-ii). Follows 3a-ii (main 91f64b7).

---

## Problem

A project or an environment can't be made, renamed or removed in Wakil. Today a new project
needs a hand-written `<folder>/.wakil/project.json` plus `wakil project add`. A new environment
needs a hand edit of that file's `environments` map. Settings draws **+ Add a project** and
**+ Add an environment** dimmed as not-this-phase, and the environment page says "Create, rename
and remove are #45." Nothing renames anything anywhere.

Decision 21 (2026-09-15) says every configurable thing is creatable and editable in the app. Its
2026-09-22 amendment ruled environment create/rename/remove out of the 2e pane (#97). This
sub-phase reverses that part of the amendment.

## Calls made for the operator

1. **Add a project = choose a folder.** **+ Add a project** opens the macOS folder picker. The
   folder becomes the project's first root, and the name is the folder's name. If the folder
   already has `.wakil/project.json`, Wakil registers that file as it is (the same thing
   `wakil project add` does). Otherwise it writes a new one.
2. **Remove a project = take it off the org's list.** The row leaves `projects.json`, and
   `project.json` stays on disk, as `wakil project rm` does today. It asks first, in the pane
   (**Remove** / **Keep it**): the operator counts it as destroying (Rule 1, ruled on the walk
   2026-10-22). Adding the same folder again brings the project back whole.
3. **Remove an environment = Trash first, then remove.** An environment exists only inside
   `project.json`. Before the key goes, a copy of the file goes to the Trash as
   `project.json (before removing staging 14:02)`. That copy is the undo (Decision 41's pattern,
   as in 3a-ii's discard). There is no dialog, and production environments are treated the same.
4. **Rename is the Name field on the page**, saved when the field is left (Rule 2), as Git Name
   and Email are in 3a-ii.
5. **The active place follows the operator's edits.** Renaming the active project or
   environment keeps it active under its new name. Removing the active environment makes the
   project's first remaining environment active, or none. Removing the active project makes the
   org's first remaining project active, or none.
6. **A running agent pins its place.** Rename and remove are refused for a project or an
   environment that an agent is running in. The refusal names Invariant 5 (each agent keeps its
   own place) and says which agent it is. Stop the agent, then try again (Rule 7).
7. **Operator-only, as all of Settings is** (Decision 30). The agent reads the result through
   `config_tree` and `list_projects` but can't call the new actions. Voice reaches the agent, so
   voice can't call them either.
8. **No new `wakil` verbs.** Decision 21's amendment holds: shell parity runs one way, and a hand
   edit of `project.json` stays first-class.

## What the operator gets

1. **+ Add a project** under PROJECTS opens the folder picker. After a folder is chosen:
   - The project appears in the tree.
   - Its page opens with the **Name** field focused and selected (Rule 3).
   - The active project does not change (Rule 6).
   - Cancelling the picker does nothing.
2. **+ Add an environment** under a project adds `new-environment` (`new-environment-2`, … if
   taken). It has no databases and no API entries. Its page opens with **Name** focused and
   selected.
3. **The Project page's Name** and **the Environment page's Name** are editable. Leaving the
   field saves it. A name in use, an empty name, or a name containing `/` is shown whole under
   the field. The field keeps what was typed, and nothing is written (Rule 8). Left by moving to
   another page, the refusal shows in the window's status line instead.
4. **Each project page and each environment page ends with Remove**: *Remove from this
   organisation* on a project, *Remove environment* on an environment.
   - Afterwards the tree selects the removed node's parent heading. This is the one place where
     there is no node to stay on.
   - A removed environment's receipt reads `Removed staging — a copy of project.json is in the
     Trash`.
5. **A write in flight** shows a spinner on its control and can't be fired twice (Rule 5).
6. **Elsewhere, renames are live:**
   - The place line, the environment chip and the project switcher all show the new name.
   - The pane layout saved for the old name (`layouts/<org>/<project>@<env>.json`, and each
     conversation's under `conversations/<root>/`) moves to the new name, so the panes come back.
   - What the window holds in memory moves too: open shells keep running, unsaved editor tabs
     stay reachable, and a conversation on screen stays on screen.
   - Removing a project or environment closes its shells. It is refused while the place holds an
     unsaved editor tab; the refusal names the files and says to save or close them first.

## What it does not do

- It adds no roots and removes none (the Roots section stays read-only), and it doesn't edit
  `scopes` or the production flag. Those are other rows.
- It doesn't move or delete a project's folder or its `.wakil` directory.
- It doesn't rename Keychain entries. A database's `ref` is stored in `project.json`, so it keeps
  pointing at its entry after a rename.
- It has no project templates, and it doesn't copy an environment.

## Design

**Go: one writer per file (Decision 21).**
- In `internal/wakilcore`:
  - `CreateProject(org, folder, name)` writes `<folder>/.wakil/project.json` (name, org, one
    root at the folder) unless one exists. If one exists, its `org` must equal `org`: a file from
    another org is refused under Invariant 4, and the row takes the file's own `name`, not the
    `name` passed, so a renamed project added back comes back whole. Then it adds the registry
    row, and answers the name it used.
  - `RenameProject(org, old, new)` writes project.json `name` and the registry key in one
    read-modify-write each. project.json is written first, and the registry is put back if the
    second write fails.
  - `RemoveProject(org, name)` removes the registry row only.
  - `CreateEnvironment`, `RenameEnvironment` and `RemoveEnvironment` each do a read-modify-write
    of project.json through `SaveProject`. `RemoveEnvironment` puts the copy in the Trash first,
    the same way the file Trash does.
  - Each of these also updates `active.json` when it names the thing changed (call 5).
- In `wakil-ctx`, six tools: `create_project`, `rename_project`, `remove_project`,
  `create_environment`, `rename_environment`, `remove_environment`.

**Swift.**
- Six registry actions, `ctx_create_project`, `ctx_rename_project`, `ctx_remove_project`,
  `ctx_create_environment`, `ctx_rename_environment` and `ctx_remove_environment`. Each is
  `.control` and operator-only, and is added to `operatorOnlyActions`.
- After each dispatch, the window refreshes its context and the Settings tree, as
  `ctx_set_project` does.
- The agent-pin refusal (call 6) is checked in the action, against the window's running agent
  sessions.
- The layout file move is done by the window after a successful rename, through
  `LayoutPersistence`; the in-memory canvases move through the seams a conversation adopts the
  canvas by (`switchScope(to:adoptingFrom:)`, `TerminalStore.rehome`).

**Settings UI.**
- The two dimmed not-this-phase rows become live buttons:
  `settings.tree.addProject` and `settings.tree.project.<p>.addEnvironment`.
- New controls: `settings.project.name`, `settings.environment.name`,
  `settings.project.remove` and `settings.environment.remove`.
- The "#45" note on the environment page goes.

## Errors and edges

- A folder that already holds a project.json from another org is refused, and the org is named
  (Invariant 4).
- A folder already registered under another name is refused, and its registered name is shown.
- A name clash with a project or environment in this org or project is refused, and the clash
  is named.
- A project.json that can't be read or written: the error is shown whole on the page, and
  nothing else changes.
- If the Trash fails, the environment is not removed (Decision 41: no undo means no removal).
- A project.json edited by hand while the page is open: every write reads from disk at dispatch
  (Decision 21's amendment), so the edit is kept.
- Removing the last project leaves the window with no project, as a fresh org has today.

## Testing

- **Go unit tests** for each of the six writers:
  - known keys are kept; unknown keys drop, as `SaveProject` documents;
  - each refusal case;
  - the registry is put back when a rename fails halfway;
  - `active.json` follows a rename or a removal;
  - the Trash copy exists before the key goes.
- **WakilKit tests:** the six actions are operator-only, the agent-pin refusal works, and a
  rename moves the layout file.
- **e2e (seeded):** add a project from a fixture folder, rename it, remove it, and add it back.
  Add an environment, rename it, and remove it (Trash copy present). Rename the active
  environment and check the chip. Try a clash and an empty name.
- **Runbook** `docs/wakil/phase-2e-ii-acceptance.md`, with walk rows for the picker. The e2e
  harness can't drive the macOS folder picker, so a check passes the folder as a param.

## Charter changes this sub-phase makes

- Decision 21 gets a 2026-10-22 amendment: environment create/rename/remove is in the pane, and
  project create/rename/remove too. #97's ruling holds for project fields other than the name,
  and for the machine block.
- PRODUCT.md: one line under Settings.
- The phase map's 2e-ii row is marked met when walked.
