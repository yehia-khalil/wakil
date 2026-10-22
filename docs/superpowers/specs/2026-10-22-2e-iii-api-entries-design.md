# 2e-iii: add, edit and remove an environment's API entries from Settings

**Date:** 2026-10-22
**Status:** spec awaiting the operator's review. The operator skipped the design questions, so
every decision below is the designer's call, listed under *Calls made for the operator*.
**Sub-phase:** 2e-iii, a new phase map row after 2e-ii (main dd65cbf). Asked for on the 2e-ii
walk: "i need it editable in settings ofcourse".

---

## Problem

An environment's API entries (`environments.<env>.api[]` in `project.json`: `name`, `baseUrl`,
`authRef`, `authHeader`) can only be written by hand. The Settings API page lists them read-only,
under a note saying they "stay so". The credential is worse: the operator has to know the
Keychain service scheme (`wakil:<org>:<ref>`) and run `security add-generic-password` with a ref
they invented. Decision 21 says every configurable thing is creatable and editable in the app.
Databases have been since 2e; API entries are the gap.

## Calls made for the operator

1. **It follows the database page.** The API page lists what exists, one section per entry, and
   ends with an **ADD OR REPLACE AN API ENTRY** card: NAME, BASE URL, AUTH HEADER, TOKEN. Saving
   a name that already exists replaces that entry, as the database card does.
2. **Each entry is also editable where it stands.** Its **Name**, **Base URL** and **Auth
   header** are fields in its section, saved when the field is left (Rule 2), as the 2e-ii Name
   fields are. The card is for a new entry; nobody retypes an entry to fix one field.
3. **The token goes to the Keychain, never to the file.** What lands in `project.json` is
   `authRef`, a Keychain entry name. The ref is derived, never typed:
   `api:<project>:<environment>:<name>`, as `DatabaseRef` derives `db:…`. The token field is
   masked, and holds the header's whole value (`Bearer abc…`), because that is what is sent today.
4. **Storing a token asks first**, in the pane, with **Store it** / **Cancel**, worded as the
   database card's: "Store a token for orders-api in staging? It goes to your Keychain, not to the
   project file." No part of the token is shown. A save with the token empty doesn't ask, and
   keeps the entry's current `authRef`.
5. **An entry's token can be replaced or cleared from its section.** **Replace token** opens a
   masked field and the same confirmation. **Clear token** drops `authRef` from the entry; the
   Keychain item is kept, as removing a database keeps its own (the same credential may be named
   elsewhere, and the registry can't see that).
6. **Removing an entry asks first** (**Remove** / **Keep it**), as the operator ruled for project
   and environment removal on the 2e-ii walk (Rule 1). The Keychain item is kept.
7. **A hand-typed `authRef` is respected.** It is shown as it is, kept through every edit that
   doesn't store a new token, and replaced by the derived ref only when a token is stored.
8. **Renaming an entry doesn't rename its Keychain item.** `authRef` is stored in the entry, so it
   keeps pointing at its item. Open API panes in this window whose request names the old entry in
   that environment follow the new name; a request saved to a file is not rewritten (a hand edit
   stays first-class).
9. **Operator-only, as all of Settings is** (Decision 30). The agent reads entries through
   `config_tree` and `list_apis` (which never carry `authRef`) and can't call the new actions;
   voice reaches the agent, so voice can't either. No agent pin: an entry is configuration, not a
   place (Invariant 5 is about places).
10. **No new `wakil` verbs.** A hand edit of `project.json` stays first-class (Decision 21).

## What the operator gets

1. On an environment's **API** page:
   - Each entry is a section headed by its name, with editable **Name**, **Base URL** and **Auth
     header** (`Authorization` shown as the prompt when empty), a **Token** row reading
     `in Keychain (api:shop:staging:orders-api)` or `none`, **Replace token**, **Clear token**
     and **Remove**.
   - The **ADD OR REPLACE AN API ENTRY** card below. **Save** is dimmed until NAME and BASE URL
     are filled. On success the card clears; on a refusal it keeps what was typed (Rule 8).
   - The read-only note goes.
2. A refusal is shown whole under the field or card that caused it, and nothing is written:
   - a base URL that isn't an absolute `https` URL, or carries credentials, a query or a fragment
     (`NormalizeHTTPBase`'s own sentences);
   - an auth header `ValidateAuthHeader` refuses (`Host`, `Cookie`, `Proxy-*`, not a token);
   - an empty name, a name containing `/`, or a rename onto a name the environment already has.
   Left by moving to another page, a field's refusal shows in the window's status line (as 2e-ii).
3. The base URL is stored normalised (trailing `/` trimmed), so what the page shows is what a
   request uses.
4. A write in flight shows a spinner and can't be fired twice (Rule 5).
5. The environment page's **API** count and the API pane's entry picker show the change without
   a reload, as a database add does today.

## What it does not do

- It doesn't change how requests are sent: origin binding, redirect refusal, scrubbing and the
  write gate (Decision 25's price) are untouched.
- It doesn't delete Keychain items, and it doesn't read a stored token back into the page.
- It doesn't make databases editable in place, or add a confirmation to removing a database.
  Those would bring the database page in line with this one, and are a separate row if wanted.
- It doesn't add OAuth flows or token refresh. A token is a static header value, as today.

## Design

**Go (`internal/wakilcore`), one writer per change, each a read-modify-write of `project.json`
through `SaveProject` from disk at dispatch, refusing a project of another org (Invariant 4):**
- `SetApiEntry(ApiEntryRequest{ProjectPath, Environment, Name, BaseURL, AuthHeader, Token})`
  adds or replaces by name. It validates first (name, `NormalizeHTTPBase`, `ValidateAuthHeader`)
  and writes nothing on a refusal. With a token, the Keychain is written first
  (`SecretSetFor(org, ApiRef(...), token)`), then the file, as `SetDatabaseDSN` orders it.
  Without one, an existing entry's `authRef` is kept.
- `ApiRef(project, environment, name) string` returns `api:<project>:<environment>:<name>`.
- `UpdateApiEntry(path, env, name, ApiEntryEdit{NewName, BaseURL, AuthHeader *string, ClearToken
  bool})` edits one entry in place: the fields that are set change, the rest are kept.
- `RemoveApiEntry(path, env, name)` drops the entry and keeps the Keychain item.
- `wakil-ctx` gets three tools, `set_api_entry`, `update_api_entry` and `remove_api_entry`, the
  token parameter marked secret-bearing.

**Swift.**
- Three registry actions, `api_set_entry`, `api_update_entry` and `api_remove_entry`, `.control`,
  operator-only and in `operatorOnlyActions`, with `secretParams: ["token"]` so the journal records
  the name and `[redacted]`, as `db_set_dsn` does.
- After each write the window refreshes the Settings tree and the environment's API entries.
- A rename re-points open API panes' drafts in the window from the old entry name to the new one,
  in the same environment.

**Settings UI** (`SettingsPane.swift`, `SettingsForm.swift`'s vocabulary, which the database card
already said "the API settings form will use too").
- New identifiers: `settings.api.<name>.name`, `.baseUrl`, `.authHeader`, `.replaceToken`,
  `.token`, `.clearToken`, `.remove` (with `.remove.confirm` / `.remove.keep`), and on the card
  `settings.api.name`, `settings.api.baseUrl`, `settings.api.authHeader`, `settings.api.token`,
  `settings.api.save`, `settings.apiToken.confirm`, `settings.apiToken.cancel`.
- In-place fields reuse `LeaveSavedField` (2e-ii), so leaving by a tree click saves.

## Errors and edges

- A Keychain write that fails leaves the file untouched, and the error is shown whole.
- An entry named in a request that no longer exists (removed, or renamed by hand) is reported by
  the API pane as it is today when an environment lacks the entry.
- A `project.json` edited by hand while the page is open keeps the hand edit (read at dispatch).
  Keys this build doesn't know still drop, as `SaveProject` documents.
- Two entries with the same name in a hand-written file: the page draws both; an edit or a
  removal acts on the first, and the page says the names clash.

## Testing

- **Go unit tests** for each writer: add, replace keeping `authRef`, a token stored before the
  file (a stubbed Keychain), every refusal writing nothing, a rename refused on a clash, a hand
  `authRef` kept, clear token keeping the Keychain item, removal keeping it.
- **WakilKit tests:** the three actions are operator-only, the token is redacted in the journal,
  a rename re-points an open draft.
- **e2e (seeded):** add an entry without a token; edit its base URL by leaving the field with a
  tree click; refuse an `http://` URL and a `Host` header; rename it; remove it with **Keep it**
  then **Remove**. The token flow's Keychain write is a walk row, as the database DSN's is.
- **Runbook** `docs/wakil/phase-2e-iii-acceptance.md`: store a token, send a request with it from
  the API pane, replace and clear it, and check `security find-generic-password -s
  wakil:personal:api:walk-2e-iii:staging:orders-api` in a terminal.

## Charter changes this sub-phase makes

- North-star phase map: a **2e-iii** row after 2e-ii.
- Decision 21: a 2026-10-22 note that API entries are now in the pane, superseding the 2c-iv
  "read-only, and stay so" call made in the pane's code.
- PRODUCT.md: one line under Settings.
