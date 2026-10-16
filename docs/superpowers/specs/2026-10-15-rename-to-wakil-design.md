# Rename to Wakil — design

**Status:** proposed · **Created:** 2026-10-15

## Goal

Rename the product from Rafiq to **Wakil** (Arabic: the one you entrust to act on your
behalf) before the repository goes public. A shipped product already uses the old name.

## Decisions (agreed 2026-10-15)

1. **The name is Wakil**, chosen over Dalil, Zamil, Jalis and others: it says what the
   product is (an agent holding each org's credentials and acting inside that org), keeps
   the Arabic root, and no notable project uses it.
2. **The rename is its own PR**, landing after the public-split scrub PR and before the
   cutover, so the public repository starts under the new name.
3. **Existing data moves with a one-time script**, not with migration code in the product:
   this Mac is the only installation.

## What is renamed

Everything, with no aliases and no compatibility shims. There is one user, and a fresh
repository has no history to stay consistent with.

| Thing | From | To |
|---|---|---|
| Product name in prose and UI | Rafiq | Wakil |
| Binaries and their `cmd/` folders | `rafiq`, `rafiq-ctx`, `rafiq-db`, … | `wakil`, `wakil-ctx`, `wakil-db`, … |
| Go package | `internal/rafiqcore` | `internal/wakilcore` |
| Go module path | `github.com/yehia/rafiq` | `github.com/yehia-khalil/wakil` |
| Swift targets | `RafiqKit`, `RafiqApp`, `RafiqKitTests` | `WakilKit`, `WakilApp`, `WakilKitTests` |
| App bundle and bundle ids | `Rafiq.app`, `dev.rafiq.app`, `dev.rafiq.e2e` | `Wakil.app`, `dev.wakil.app`, `dev.wakil.e2e` |
| Environment variables | `RAFIQ_*` | `WAKIL_*` |
| Keychain service and account | `rafiq:<org>:<ref>`, account `rafiq` | `wakil:<org>:<ref>`, account `wakil` |
| State directory | `~/.rafiq` | `~/.wakil` |
| Docs folder | `docs/rafiq/` | `docs/wakil/` |
| Repository | `yehia-khalil/rafiq` | `yehia-khalil/wakil` (the new public one) |

The **Go module path is now in scope.** The split spec left it out because changing it
touches every import; the rename touches every import anyway, and it now matches the
repository, so `go install` works.

Case is kept: `Rafiq` → `Wakil`, `rafiq` → `wakil`, `RAFIQ` → `WAKIL`. Today no file
contains `wakil`, so the replacement cannot merge with an existing name.

**After the rename, the old name appears in exactly two files:** the migration script, whose header explains it, and this spec. A check proves it.

## The migration script

`scripts/migrate-from-rafiq.sh`, run once on this Mac after the rename PR merges and
before the first launch of Wakil. It is idempotent and refuses rather than overwrites:

1. **Refuse** if Rafiq or Wakil is running, or if `~/.wakil` already exists.
2. **Keychain:** for every generic password whose service starts `rafiq:` and whose
   account is `rafiq`, read the secret and add it as `wakil:<same rest>` with account
   `wakil`. Then read each new item back and compare it with the old one. Only when **all**
   of them match does it delete the old items. On any mismatch it deletes the new items
   it created and exits non-zero, leaving the old ones untouched. Secrets are never
   printed; the script reports counts and service names only.
3. **State:** `mv ~/.rafiq ~/.wakil`. Inside it, rewrite any stored path or name that
   contains the old name (org files that record binary paths, for example); the script
   lists every file it changed.
4. **Preferences:** `defaults export dev.rafiq.app - | defaults import dev.wakil.app -`,
   and the same for `RafiqApp` → `WakilApp`. The old domains are left in place, because
   they are harmless and are the only rollback for window state.
5. **Report external references** it does not touch: `rafiq` inside `~/.zshrc`,
   `~/.claude*/settings.json`, `~/.claude*/*.json` MCP configs and the Orca workspace
   config. The operator decides on each.

**Rollback** before step 2 deletes anything: nothing has changed. After that, the old
Keychain items are gone, but the script's counterpart, `--reverse`, copies them back the
same way. This is the same code with the prefixes swapped, so it is not a second
implementation.

## Effect on the public-split spec

- The new public repository is `yehia-khalil/wakil`. The old `yehia-khalil/rafiq` is
  **not renamed**: it is archived where it stands, which removes a cutover step.
- The public-split plan's Task 8 changes accordingly; nothing else in it does.
- The denylist does not need the old name; the rename's own check covers it.

## Proof

- `git grep -il rafiq` lists only `scripts/migrate-from-rafiq.sh` and this spec.
- No path in `git ls-files` contains `rafiq`.
- `make test`, `make build app-test` and CI are green.
- The migration script runs against a **throwaway keychain**
  (`security create-keychain`) and a temporary `HOME` holding a fake `.rafiq` tree, never
  the login keychain, in both directions, with a deliberately corrupted copy proving the
  all-or-nothing rollback.
- After the operator runs it for real: Wakil launches, the org list matches, and one
  secret-backed action (a db query) works in each org.

## Not in scope

- A logo or icon redesign. The app has no logo today.
- Domains. `wakil.ai` and `getwakil.com` are taken; `.app` and `.dev` were not checked.
