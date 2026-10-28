# 3d-iv — browser passwords: acceptance

**Spec:** [`2026-10-27-3d-browser-you-live-in-design.md`](../superpowers/specs/2026-10-27-3d-browser-you-live-in-design.md) §3d-iv
· **Plan:** [`2026-10-27-3d-iv-passwords.md`](../superpowers/plans/2026-10-27-3d-iv-passwords.md)
· **Charter:** Invariant 4 (a saved browser password is a credential), Invariant 6 (*Still refused*: typed or filled by the agent), Decision 49, design language §11 (Browser)
· **Probe:** [`3d-iv-keychain-probe.md`](3d-iv-keychain-probe.md)

The exit criterion: a login form's sent form offers to save or update its password. A key in a login
field fills it on a press, and only then. The password lives in the Keychain, in an item that trusts Wakil
only, and never reaches the agent, a file, a log or the store. Settings → Browser → Passwords lists,
reveals, copies, edits and deletes them, lists the sites never to offer, and imports the Passwords app's
CSV once. A second organisation sees nothing.

**Not walked yet.** Everything below is the operator's. The build was made without driving the screen,
so rows 11 to 14 and the probe's open rows (b), (e) and (f) are checks nobody has run.

## 0. Setup

Run this in the worktree root, on this Mac. It is safe to re-run. Test passwords only.

```bash
make build && make app-bundle
mkdir -p .scratch/3d-iv
printf 'Title,URL,Username,Password,Notes,Extra\nCSV One,http://127.0.0.1:8123/login.html,csv-one,csv-test-pass-1,,x\nCSV Two,127.0.0.1:8123,csv-two,csv-test-pass-2,,y\nCSV No URL,,csv-three,csv-test-pass-3,,z\n' > .scratch/3d-iv/passwords-test.csv
python3 -m http.server 8123 --bind 127.0.0.1 --directory e2e/fixtures/pages &
python3 -m http.server 8124 --bind 127.0.0.1 --directory e2e/fixtures/pages &
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil
```

Organisation **A** is `personal` and **B** is `orgb`. The fixture forms send with GET and their fields
have no name, so the test password never reaches the tab's URL. Stop the servers afterwards with
`kill %1 %2` in the shell that started them. Before the walk, run the probe's open rows (b), (e) and (f) from
[`3d-iv-keychain-probe.md`](3d-iv-keychain-probe.md): if (b) shows the value with no dialog, stop.

## 1. The walk

| # | Where | Do | Expect | Walked |
|---|---|---|---|---|
| 1 | Wakil | Open `http://127.0.0.1:8123/login.html`, type `walker` and `walk-test-pass-1`, and press **Sign in** | `Save the password for walker on 127.0.0.1:8123?` at the pane's top. The signed-in page is usable under it. **Save** removes the bar | |
| 2 | Wakil | Open `login.html` again. Wait, then click into the username field, press the key, and choose `walker` | Nothing is filled until the press. Then both fields are filled, and the keyboard stays in the page | |
| 3 | Wakil | Sign in again with `walk-test-pass-2` | `Update the password for walker…` with **Update** and **Not Now** only. After **Update**, row 2's fill gives the new password | |
| 4 | Wakil | On `http://127.0.0.1:8124/login.html`, sign in, then choose **Never for This Site**. Sign in again | No second bar. Settings → Browser → Passwords lists `127.0.0.1:8124` under *Never saved for*, and × takes it off | |
| 5 | Wakil | Open `signup.html`, press the key in a password field, and choose **Suggest Strong Password**, then **Create** | Both fields hold the same `xxxxx-xxxxx-xxxxx-xxxxx`. No bar appears, and Settings lists the login | |
| 6 | Wakil, Terminal | After row 2's fill, ask the agent to read the page and to fill the password. Then, in Terminal: `grep -rl walk-test-pass ~/.wakil` | The read shows the password field with no value. The fill is refused with the operator-only sentence. The grep prints nothing | |
| 7 | Wakil | ⌘⇧O → **B**, then open `login.html` on 8123 | No key in the fields, and Settings → Passwords reads `No passwords saved for orgb yet.` | |
| 8 | Wakil | Back in **A**, Settings → Passwords: **Reveal**, **Copy**, **Edit** the password then click away, then **Delete** | Reveal asks for Touch ID or the Mac's password, once. The edit saves when focus leaves. Delete asks in place, and **Keep it** keeps the login | |
| 9 | Wakil | **Import…** → `.scratch/3d-iv/passwords-test.csv` → **Import**, then answer the Trash question | Rows are listed by site with an organisation picker set to `personal`. The no-URL row is marked `no URL`. The receipt reads `Imported 2 passwords. Skipped 1.` **Move to Trash** moves the file | |
| 10 | Terminal, Wakil | `security find-generic-password -s wakil:personal:browser-login:default -a "127.0.0.1:8123 walker" -w`. Then rebuild (`make app-bundle`), relaunch, and repeat row 2 | macOS asks before `security` gets the value. Deny it, and nothing prints. After the rebuild, the first fill asks once (ruling 2), and **Always Allow** stops further asks. A rename-only **Edit** in Settings after a rebuild asks too | |

Rows 11 to 14 are what the build could not check without the screen. They are the first things to look
at: a defect in any is a UI defect nobody has seen.

| # | Where | Do | Expect | Walked |
|---|---|---|---|---|
| 11 | Wakil | On `login.html` with a saved login, click into Username, then Password. Press the key. Zoom the page with ⌘+, resize the pane, scroll | The key is 16 pt, inside the focused field's right edge, inset 4 pt, and follows the field through zoom, resize and scroll. The popover points at the key, not at the pane's corner | |
| 12 | Wakil | Press the key, then press Esc (no choice). Press it again and choose `walker`. Type a character | After Esc the key is still there, or returns when you click into the field. After a choice the popover closes and the next character goes into the page's field, never into the address bar or the composer | |
| 13 | Wakil | Settings → Passwords → **Edit** on a row | The password field takes the keyboard on its own. Typing replaces the password. Empty keeps the old one. Click away saves; **Done** saves | |
| 14 | Wakil | **Import…** → **Choose File…** | The macOS file picker comes in front of the sheet, and the sheet is still there when it closes (also after Cancel). The file's rows then appear | |

## 2. Known and not fixed

- A login form inside an iframe gets no key (ruling 11): the script watches the main frame only.
- Every rebuild asks again for each item (ruling 2): an ad-hoc signed build has a new code hash each
  time. **Always Allow** holds until the next build. Signing (2b-vii) removes it.
- A password a site sends in a GET URL is not scrubbed from the tab's URL, so the agent's read of the
  address can show it. The fixtures avoid it by naming no fields.
- A password under 6 characters made visible as page text by a *show password* toggle is not hidden in
  the page's text or labels (ruling 15); in an element's value it is, at any length.
- `wakil org rm` names the organisation's saved passwords as residue and deletes none. Delete them
  first in Settings.
- A page's own script can raise a Save bar by sending a form it built, for its own site, with values it
  already holds; saving needs your **Save**.
- The import receipt reads `Imported 1 passwords.` for one row: the copy is fixed by the plan.
- An http page that is not local (not loopback, `localhost`, `*.localhost`, `*.test` or an IP
  literal) gets no key, and a fill or suggestion there is refused: a site key drops the scheme, so a
  login saved on https would otherwise fill on the same site's http page.
- **Copy** in Settings leaves the password on the pasteboard for 90 s; it is cleared then unless
  something else was copied since.
- The Wakil binary is ad-hoc signed with no hardened runtime, so code the agent runs in its shell
  could (a) load itself into the trusted binary (`DYLD_INSERT_LIBRARIES`) and read saved passwords with
  no prompt — unmeasured; (b) run `Wakil --dispatch` with `browser_password_save`, `_delete` or
  `_never` and overwrite or delete logins with no prompt — the e2e driver needs `--dispatch`, so this
  lane does not refuse it; (c) rebuild the app, which raises the same **Always Allow** prompt as your
  own rebuild. Signing with the hardened runtime (2b-vii) fixes it; that is your call.
- Open in the probe: (b) the prompt `security` raises and the exit status, (e) the exact words after
  a rebuild, (f) whether a tab's saved state ever holds a typed password (it should not).

## 3. Residue: what the walk cannot establish

- The Keychain's own prompt (row 10) and LocalAuthentication (row 8): system dialogs outside the
  accessibility tree. `uncoverable.tsv` names `…passwords.row.<…>.copy` (and Reveal with it) and
  `…passwords.import.choose` as the two controls they cover.
- A framework-controlled login (React and the like), a login in an open shadow root, and a real site's
  own password manager prompts: the fixtures have none of them.
- The key's pixels (row 11) and the focus rulings (rows 12 and 13): no step kind reads them.

## 4. What Cover checks

Handed to the e2e auditor (`docs/agents/e2e.md`), not walked here. Ask the operator before it uses the
screen. If it runs without the login keychain, set `WAKIL_KEYCHAIN` to a temporary keychain file.

- save then fill on `login.html` and on `login-spa.html`;
- nothing filled on load;
- the fill refused after `login-redirect.html` moves;
- http (non-local) page: fill refused;
- a page's own `window.webkit` post is not heard (the handler lives in `wakil.passwords`);
- update, never and suggest on `signup.html`;
- the agent's `browser_read_page` after a fill, *show password* included;
- `browser_type` into the password field still refused;
- Settings list, edit, delete and never ×;
- the import with the test CSV, with no CSV bytes under `~/.wakil`;
- a second organisation sees nothing.

## 5. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

Not run yet. `make e2e-runbook` fills this in after Cover.

<!-- /machine-walk -->
