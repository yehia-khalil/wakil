# Passwords in the Keychain — the 3d-iv probe

**Run:** 2026-10-28 · **Machine:** Apple M3, macOS 27.0 · **Probe code:** throwaway, a Swift script
compiled with `swiftc`, deleted before this was committed. Every operation targeted a throwaway keychain
file under `.scratch/3d-iv/`, never added to the search list and deleted afterwards. Test value
`probe-pass-1` only.

**What the probe did.** It created the keychain with `/usr/bin/security create-keychain`,
`unlock-keychain` and `set-keychain-settings` (as `e2e/driver/launch.go` does). It opened the file with
`SecKeychainOpen` and added `wakil:probe:browser-login:default` / `127.0.0.1:8123 walker` with
`SecItemAdd` and `kSecUseKeychain`. It listed with `SecItemCopyMatching` (`kSecMatchSearchList`,
`kSecMatchLimitAll`, `kSecReturnAttributes`), then read the value back (`kSecReturnData`). **The item's
trusted application is therefore the probe binary**, standing in for Wakil.app.

**This run was unattended, so (b), (e) and (f) are open.** Each needs a person to see or deny a dialog,
or the running app. They are listed below as *for the operator, not yet measured*. **Task 1's decision
is provisional until (b) is run:** ruling 1 stands on the strength of the ACL below, and the operator
checks (b) before Cover.

## Measured

| | Question | Result |
|---|---|---|
| (a) | Did add, list and read work, and did listing prompt? | Yes to all three. `SecItemAdd` 0, list returned 1 item with service, account and label, read returned `probe-pass-1`. No prompt was raised or waited on (every call ran under a 10 s alarm; none fired). |
| (c) | `security find-generic-password -s <svc> <file>`, no `-w` | Exit 0; prints the attributes (`svce`, `acct`, label) and no value. Absent service: exit 44. |
| (d) | Does the temp keychain appear in `security list-keychains -d user`? | No. Only `login.keychain-db`, before and after. `create-keychain` does not add to the search list. |
| ACL (evidence for b) | `security dump-keychain -a <file>` (no `-d`) | The `decrypt` entry lists **one** trusted application: the probe binary, by `cdhash`. `/usr/bin/security` is not in it. The other entries are `encrypt` (any application) and `change_acl` (none). So the item is readable without a prompt only by the binary that wrote it. |

The probe binary read its own item with no prompt, as expected for the creator.

## For the operator, not yet measured

Run from the worktree root, `/Users/yehia/Desktop/scripts/wakil-public-3d-iv`. The probe script is gone;
(b) needs an item written by a different binary than `/usr/bin/security`, so recreate the
essence: a ten-line Swift file with `SecKeychainOpen(file)` then `SecItemAdd` of a generic password
(`kSecAttrService` `wakil:probe:browser-login:default`, `kSecAttrAccount` `127.0.0.1:8123 walker`,
`kSecValueData` `probe-pass-1`, `kSecUseKeychain` the opened keychain), after
`security create-keychain -p x .scratch/3d-iv/b.keychain`.

| # | Check | Command | Expected |
|---|---|---|---|
| (b) | The agent's route prompts and prints nothing | `/usr/bin/security find-generic-password -s wakil:probe:browser-login:default -a "127.0.0.1:8123 walker" -w /Users/yehia/Desktop/scripts/wakil-public-3d-iv/.scratch/3d-iv/b.keychain` then **Deny** | A macOS dialog asks for access; after Deny the exit status is 36 or 128 and `probe-pass-1` is not printed. **If it prints the value with no dialog, stop: ruling 1's argument fails; ask before Task 3.** |
| (e) | What a rebuild shows | `make app-bundle` twice (in `/Users/yehia/Desktop/scripts/wakil-public-3d-iv`), with an item written by the first build, then read it from the second | The second build's first read shows *"Wakil wants to use your confidential information stored in … in your keychain"*; **Always Allow** holds until the next build. Record the exact words. |
| (f) | The tab state holds no password | In the app, open `e2e/fixtures/pages/form.html`, type `probe-pass-1` into the password field, switch tabs, then `grep -c probe-pass-1 ~/.wakil/orgs/<org>/browser/tabs/*.state` | Every file reports 0. Then switch the field to `type=text` in the inspector, type it again, leave the tab, repeat the grep; record the count, which is the edge. **If the first grep finds the value, add a task before Task 8 that writes no tab state for a page with a filled password.** |

Delete `.scratch/3d-iv/b.keychain` afterwards with `security delete-keychain`.
