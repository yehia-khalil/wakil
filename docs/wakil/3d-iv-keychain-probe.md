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

Run every command from the worktree root. (b) needs an item written by a binary other than
`/usr/bin/security`, so first build the writer below. It touches the throwaway keychain file only, with
the test value only.

```sh
mkdir -p .scratch/3d-iv
security create-keychain -p x "$PWD/.scratch/3d-iv/b.keychain"
security unlock-keychain -p x "$PWD/.scratch/3d-iv/b.keychain"
cat > .scratch/3d-iv/writer.swift <<'SWIFT'
import Foundation
import Security
var kc: SecKeychain?
guard SecKeychainOpen(CommandLine.arguments[1], &kc) == errSecSuccess, let k = kc else { exit(1) }
let q: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "wakil:probe:browser-login:default",
    kSecAttrAccount as String: "127.0.0.1:8123 walker",
    kSecValueData as String: Data("probe-pass-1".utf8),
    kSecUseKeychain as String: k,
]
print("add", SecItemAdd(q as CFDictionary, nil))
SWIFT
swiftc -o .scratch/3d-iv/writer .scratch/3d-iv/writer.swift 2>/dev/null
.scratch/3d-iv/writer "$PWD/.scratch/3d-iv/b.keychain"
```

| # | Check | Command | Expected |
|---|---|---|---|
| (b) | The agent's route prompts and prints nothing | `/usr/bin/security find-generic-password -s wakil:probe:browser-login:default -a "127.0.0.1:8123 walker" -w "$PWD/.scratch/3d-iv/b.keychain"` then **Deny** the dialog | A macOS dialog asks for access, and after Deny `probe-pass-1` is not printed. Record the exit status (not known beforehand). **If it prints the value with no dialog, stop: ruling 1's argument fails; ask before Task 3.** |
| (e) | What a rebuild shows | Covered by the plan's walk row 10 (rebuild, then fill), since the item must be written by the app itself. No standalone command: it needs `make app-bundle` twice and the app's own read | The second build's first read shows *"Wakil wants to use your confidential information stored in … in your keychain"*, and **Always Allow** holds until the next build. Record the exact words. |
| (f) | The tab state holds no password | In the app, open `e2e/fixtures/pages/form.html`, type `probe-pass-1` into the password field, switch tabs, then `grep -c probe-pass-1 ~/.wakil/orgs/personal/browser/tabs/*.state` | Every file reports 0. Then switch the field to `type=text` in the inspector, type it again, leave the tab, and repeat the grep; record the count, which is the edge. **If the first grep finds the value, add a task before Task 8 that writes no tab state for a page with a filled password.** |

Afterwards: `security delete-keychain "$PWD/.scratch/3d-iv/b.keychain"; rm -r .scratch/3d-iv`.
