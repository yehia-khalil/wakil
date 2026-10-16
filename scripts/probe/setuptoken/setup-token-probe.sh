#!/usr/bin/env bash
# setup-token-probe.sh — does `claude setup-token` mint silently after a fresh
# login, or does it need its own browser round trip?
#
#   Ticket: https://github.com/yehia-khalil/rafiq/issues/119
#   Map:    https://github.com/yehia-khalil/rafiq/issues/46
#   Method: the same terms as #92 (docs/wakil/provider-login-probe.md §9) —
#           a throwaway `mktemp -d` config dir, a full before/after snapshot of
#           every Claude Code Keychain item and credentials file, and an
#           explicit teardown.
#
# HITL. The operator runs this in their own terminal and clicks through two
# browser round trips at most. Everything else is measured by the script.
#
#   ./setup-token-probe.sh              # the whole run, pausing at each human step
#   ./setup-token-probe.sh --cleanup-only <state-file>   # tear down a run that died
#
# THE TOKEN THIS MINTS IS REAL AND DOES NOT EXPIRE. The raw transcripts hold it
# in cleartext; they live in a 0700 temp dir and step 12 shreds them. The
# findings file is redacted and is the only thing safe to paste anywhere.

set -uo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
SECURITY=/usr/bin/security          # #93: the binary the item's ACL trusts
KEYCHAIN_PREFIX='Claude Code-credentials'

# ---------------------------------------------------------------- scaffolding

die()  { printf '\n\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[2m  %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }

step() {
  printf '\n\033[1m── %s ─────────────────────────────────────\033[0m\n' "$*"
}

pause() {
  printf '\n\033[33mHUMAN STEP\033[0m %s\n' "$1"
  printf '  press return when you are ready, or ctrl-c to abort: '
  read -r _ </dev/tty
}

# Every secret this run touches matches this. Findings go through it.
redact() { sed -E 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-***REDACTED***/g'; }

say() { printf '%s\n' "$*" >>"$FINDINGS"; }

# Keychain metadata for every Claude Code item, secrets never read.
snapshot_keychain() {
  "$SECURITY" dump-keychain 2>/dev/null | awk -v pfx="$KEYCHAIN_PREFIX" '
    /^keychain: /  { if (rec ~ pfx) print rec; rec = "" }
                   { rec = rec $0 "\n" }
    END            { if (rec ~ pfx) print rec }
  ' | grep -E '"(svce|acct|cdat|mdat)"' \
    | sed -E 's/^ +//; s/<[a-z]+>/ /; s/=0x[0-9A-F]+ +/= /' \
    | paste - - - - \
    | sed -E 's/.*"acct" *= *"([^"]*)".*"cdat" *= *"([^"]*)".*"mdat" *= *"([^"]*)".*"svce" *= *"([^"]*)".*/\4  acct=\1 cdat=\2 mdat=\3/' \
    | sed -E 's/\\000//g' \
    | sort
}

# Every credentials file the CLI could plausibly write, by size and mtime.
snapshot_files() {
  for d in "$HOME"/.claude "$HOME"/.claude-* ${SCRATCH:+"$SCRATCH"} ${SCRATCH2:+"$SCRATCH2"}; do
    [ -d "$d" ] || continue
    f="$d/.credentials.json"
    if [ -e "$f" ]; then
      printf '%s  %s\n' "$(stat -f '%z bytes  mtime=%Sm' -t '%Y%m%dT%H%M%SZ' "$f")" "$f"
    else
      printf 'absent                          %s\n' "$f"
    fi
  done | sort -k4
}

derive_service() {
  printf '%s-%s' "$KEYCHAIN_PREFIX" \
    "$(printf '%s' "$(realpath "$1")" | shasum -a 256 | cut -c1-8)"
}

# A scrubbed environment: no inherited token, no API key, no config dir.
# Mirrors #92 §9.3 exactly so the two runs are comparable.
scrubbed() {
  env -i HOME="$HOME" USER="$USER" PATH="$PATH" TERM=dumb "$@"
}

# ------------------------------------------------------------------- teardown

cleanup() {
  local state="$1"
  # shellcheck disable=SC1090
  . "$state"
  step "12. Teardown"

  if [ -n "${SERVICE:-}" ]; then
    if "$SECURITY" delete-generic-password -s "$SERVICE" >/dev/null 2>&1; then
      ok "deleted Keychain item $SERVICE"
    else
      note "no Keychain item $SERVICE to delete (already gone)"
    fi
  fi
  if [ -n "${SERVICE2:-}" ]; then
    "$SECURITY" delete-generic-password -s "$SERVICE2" >/dev/null 2>&1 \
      && ok "deleted Keychain item $SERVICE2" \
      || note "no Keychain item $SERVICE2 to delete"
  fi
  for d in "${SCRATCH:-}" "${SCRATCH2:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" && ok "removed $d"
  done
  if [ -n "${RAW:-}" ] && [ -d "$RAW" ]; then
    find "$RAW" -type f -exec rm -P {} \; 2>/dev/null
    rm -rf "$RAW"
    ok "shredded raw transcripts in $RAW"
  fi
}

if [ "${1:-}" = "--cleanup-only" ]; then
  [ -n "${2:-}" ] || die "--cleanup-only needs the state file the run printed"
  cleanup "$2"; exit 0
fi

# ------------------------------------------------------------------ preflight

step "0. Preflight"
[ -n "$CLAUDE_BIN" ] || die "no \`claude\` on PATH"
VERSION="$("$CLAUDE_BIN" --version 2>&1)"
ok "claude: $VERSION  ($CLAUDE_BIN)"
[ -x "$SECURITY" ] || die "no $SECURITY"

for v in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR; do
  if [ -n "${!v:-}" ]; then
    die "$v is set in this shell. Run the probe from a shell where it is not — \
an inherited credential makes step 8 meaningless."
  fi
done
ok "CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, CLAUDE_CONFIG_DIR all unset"

RAW="$(mktemp -d "${TMPDIR:-/tmp}/setup-token-probe-raw.XXXXXX")"; chmod 700 "$RAW"
RUNDIR="$(mktemp -d "${TMPDIR:-/tmp}/setup-token-probe.XXXXXX")"
FINDINGS="$RUNDIR/findings.md"
STATE="$RUNDIR/state.sh"
: >"$FINDINGS"
ok "raw (secret-bearing, shredded at step 12): $RAW"
ok "findings (redacted, keep this):            $FINDINGS"

SCRATCH="$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/wakil-setup-token.XXXXXX")")"
SCRATCH2="$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/wakil-setup-token-empty.XXXXXX")")"
SERVICE="$(derive_service "$SCRATCH")"
SERVICE2="$(derive_service "$SCRATCH2")"
cat >"$STATE" <<EOF
SCRATCH=$SCRATCH
SCRATCH2=$SCRATCH2
SERVICE='$SERVICE'
SERVICE2='$SERVICE2'
RAW=$RAW
EOF
ok "scratch config dir: $SCRATCH"
ok "derived item name:  $SERVICE"
note "if this run dies, tear it down with:"
note "  $0 --cleanup-only $STATE"

"$SECURITY" find-generic-password -s "$SERVICE" >/dev/null 2>&1 \
  && die "an item named $SERVICE already exists — pick a different scratch dir"
ok "no pre-existing item for the scratch dir"

say "# \`setup-token\` after a fresh login — probe run $(date -u +%Y-%m-%dT%H:%MZ)"
say ""
say "- **Subject:** \`claude\` CLI $VERSION"
say "- **Scratch config dir:** \`$SCRATCH\` → item \`$SERVICE\`"
say "- **Empty control dir:** \`$SCRATCH2\` → item \`$SERVICE2\` (never authenticated)"
say ""

# ------------------------------------------------------------------- 1. before

step "1. Snapshot BEFORE"
snapshot_keychain >"$RUNDIR/before-keychain.txt"
snapshot_files    >"$RUNDIR/before-files.txt"
ok "$(wc -l <"$RUNDIR/before-keychain.txt" | tr -d ' ') Claude Code Keychain items"
ok "$(wc -l <"$RUNDIR/before-files.txt" | tr -d ' ') credentials-file locations"
cat "$RUNDIR/before-keychain.txt"

# -------------------------------------------------------------------- 2. login

step "2. Fresh login under the scratch dir"
note "argv: CLAUDE_CONFIG_DIR=$SCRATCH claude auth login --claudeai"
pause "a browser will open. Sign in with the account you picked for this probe."

T0=$(date -u +%s)
CLAUDE_CONFIG_DIR="$SCRATCH" script -q "$RAW/login.transcript" \
  "$CLAUDE_BIN" auth login --claudeai </dev/tty
LOGIN_RC=$?
T1=$(date -u +%s)
say "## Step 2 — \`claude auth login --claudeai\`"
say ""
say "Exit $LOGIN_RC, $((T1-T0))s wall clock (includes the human)."
say ""

CLAUDE_CONFIG_DIR="$SCRATCH" "$CLAUDE_BIN" auth status --json \
  >"$RUNDIR/status-after-login.json" 2>&1
ok "auth status: $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(f"loggedIn={d.get(\"loggedIn\")} method={d.get(\"authMethod\")} sub={d.get(\"subscriptionType\")} email={d.get(\"email\")}")' "$RUNDIR/status-after-login.json" 2>/dev/null || cat "$RUNDIR/status-after-login.json")"

snapshot_keychain >"$RUNDIR/mid-keychain.txt"
if "$SECURITY" find-generic-password -s "$SERVICE" >/dev/null 2>&1; then
  ok "the derived item $SERVICE now exists (as #92 §9.2 found)"
else
  die "no item $SERVICE after a successful login — the derivation or the CLI changed"
fi
say "\`auth status --json\` after login:"
say ''
say '```json'
say "$(redact <"$RUNDIR/status-after-login.json")"
say '```'
say ""

# -------------------------------------------------------- 3. THE QUESTION

step "3. \`claude setup-token\` under the SAME scratch dir — the question"
note "argv: CLAUDE_CONFIG_DIR=$SCRATCH claude setup-token"
note "WATCH FOR: does a browser open? is there a prompt? or does a token appear at once?"
pause "run it. If a browser opens, that is the answer to the ticket — complete it anyway."

T2=$(date -u +%s)
CLAUDE_CONFIG_DIR="$SCRATCH" script -q "$RAW/setup-token.transcript" \
  "$CLAUDE_BIN" setup-token </dev/tty
MINT_RC=$?
T3=$(date -u +%s)

printf '\n'
printf 'Answer the two things only you saw:\n'
printf '  Did a browser window/tab open? [y/N]: '; read -r SAW_BROWSER </dev/tty
printf '  Did it wait for typed input (a code, a confirmation)? [y/N]: '; read -r SAW_PROMPT </dev/tty

say "## Step 3 — \`claude setup-token\`, same config dir, immediately after"
say ""
say "- Exit **$MINT_RC**, **$((T3-T2))s** wall clock."
say "- Browser opened: **${SAW_BROWSER:-n}** ← *the ticket's question*"
say "- Waited on typed input: **${SAW_PROMPT:-n}**"
say ""
say "Transcript (redacted):"
say ''
say '```'
say "$(redact <"$RAW/setup-token.transcript" | tr -d '\r')"
say '```'
say ""

# The minted token: pull it out of the transcript, keep it out of everything else.
grep -oE 'sk-ant-[A-Za-z0-9_-]+' "$RAW/setup-token.transcript" | tail -1 >"$RAW/token" || true
chmod 600 "$RAW/token"
if [ -s "$RAW/token" ]; then
  ok "a token was printed to stdout ($(wc -c <"$RAW/token" | tr -d ' ') bytes), captured to $RAW/token"
  MINTED=1
else
  note "no sk-ant-… token on stdout — step 4 will say where it went instead"
  MINTED=0
fi

# ------------------------------------------------- 4. where the token landed

step "4. Where the minted token landed"
snapshot_keychain >"$RUNDIR/after-mint-keychain.txt"
KDIFF="$(diff "$RUNDIR/mid-keychain.txt" "$RUNDIR/after-mint-keychain.txt" || true)"
say "## Step 4 — where it landed"
say ""
if [ -z "$KDIFF" ]; then
  ok "no Keychain change at all: the token is stdout-only"
  say "**No Keychain change.** Minting wrote nothing to the Keychain — the token exists"
  say "only on stdout, which is what makes capture Wakil's job."
else
  ok "Keychain changed:"; printf '%s\n' "$KDIFF"
  say "**The Keychain changed:**"
  say ''; say '```'; say "$KDIFF"; say '```'
fi
say ""
NEWFILES="$(find "$SCRATCH" -newermt "@$T2" -type f 2>/dev/null | sed "s|$SCRATCH/||" | sort | head -40)"
say "Files in the scratch dir touched since minting began:"
say ''; say '```'; say "${NEWFILES:-（none）}"; say '```'
say ""
printf '%s\n' "${NEWFILES:-(no files touched)}"

# ------------------------------------------ 5. is the token config-dir-free?

step "5. Does the minted token launch a session on its own?"
say "## Step 5 — is the minted token independent of the config dir?"
say ""
if [ "$MINTED" = 1 ]; then
  note "scrubbed env, CLAUDE_CODE_OAUTH_TOKEN=<minted>, CLAUDE_CONFIG_DIR=$SCRATCH2 (empty, never authenticated)"
  OUT5="$(scrubbed CLAUDE_CODE_OAUTH_TOKEN="$(cat "$RAW/token")" CLAUDE_CONFIG_DIR="$SCRATCH2" \
          "$CLAUDE_BIN" -p 'Reply with exactly: ok' 2>&1)"; RC5=$?
  printf 'exit %s: %s\n' "$RC5" "$(printf '%s' "$OUT5" | head -3)"
  say "\`\`\`"
  say "env -i … CLAUDE_CODE_OAUTH_TOKEN=<minted> CLAUDE_CONFIG_DIR=$SCRATCH2 claude -p 'Reply with exactly: ok'"
  say "→ exit $RC5: $(printf '%s' "$OUT5" | redact | head -3 | tr '\n' ' ')"
  say "\`\`\`"
  say ""
  [ "$RC5" = 0 ] && ok "independent of the config dir" || note "did NOT launch — see the output above"
else
  note "skipped: nothing was minted to stdout"
  say "Skipped — no token on stdout."
  say ""
fi

# ------------------------------- 6. did minting disturb the login credential?

step "6. Did minting disturb the config dir's own OAuth credential?"
CLAUDE_CONFIG_DIR="$SCRATCH" "$CLAUDE_BIN" auth status --json \
  >"$RUNDIR/status-after-mint.json" 2>&1
say "## Step 6 — the config dir's own credential, after minting"
say ""
say '```json'
say "$(redact <"$RUNDIR/status-after-mint.json")"
say '```'
say ""
SDIFF="$(diff "$RUNDIR/status-after-login.json" "$RUNDIR/status-after-mint.json" || true)"
if [ -z "$SDIFF" ]; then
  ok "auth status byte-identical before and after minting"
  say "Byte-identical to step 2's status: **minting does not disturb the login.**"
else
  ok "auth status changed:"; printf '%s\n' "$SDIFF"
  say "Changed:"; say ''; say '```'; say "$(printf '%s' "$SDIFF" | redact)"; say '```'
fi
say ""
MDAT_MID="$(grep -F "$SERVICE " "$RUNDIR/mid-keychain.txt" || true)"
MDAT_NOW="$(grep -F "$SERVICE " "$RUNDIR/after-mint-keychain.txt" || true)"
say "The scratch dir's own Keychain item across the mint:"
say ''; say '```'; say "before: $MDAT_MID"; say "after:  $MDAT_NOW"; say '```'
say ""

# ------------------------------------------- 7. does logout revoke the mint?

step "7. Does \`claude auth logout\` revoke the minted token?"
note "this is the cleanup question: a minted token does not expire on its own."
CLAUDE_CONFIG_DIR="$SCRATCH" "$CLAUDE_BIN" auth logout >"$RAW/logout.transcript" 2>&1
LOGOUT_RC=$?
ok "logout exit $LOGOUT_RC"
say "## Step 7 — does \`auth logout\` revoke the minted token?"
say ""
say "\`CLAUDE_CONFIG_DIR=<scratch> claude auth logout\` → exit $LOGOUT_RC."
say ""
if [ "$MINTED" = 1 ]; then
  sleep 2
  OUT7="$(scrubbed CLAUDE_CODE_OAUTH_TOKEN="$(cat "$RAW/token")" CLAUDE_CONFIG_DIR="$SCRATCH2" \
          "$CLAUDE_BIN" -p 'Reply with exactly: ok' 2>&1)"; RC7=$?
  printf 'minted token after logout → exit %s: %s\n' "$RC7" "$(printf '%s' "$OUT7" | head -3)"
  if [ "$RC7" = 0 ]; then
    say "**The minted token still works after logout (exit 0) — logout does not revoke it.**"
    say "Teardown therefore needs a manual revocation; see the banner the run printed."
    REVOKE_NEEDED=1
  else
    say "The minted token stops working after logout (exit $RC7):"
    say ''; say '```'; say "$(printf '%s' "$OUT7" | redact | head -5)"; say '```'
    say "So \`auth logout\` under the config dir **is** a revocation gesture."
    REVOKE_NEEDED=0
  fi
else
  REVOKE_NEEDED=0
fi
say ""

# ------------------------------------------------------------- 8. after / diff

step "8. Snapshot AFTER, and diff against BEFORE"
snapshot_keychain >"$RUNDIR/after-keychain.txt"
snapshot_files    >"$RUNDIR/after-files.txt"
say "## Step 8 — the whole machine, before vs after"
say ""
FULLK="$(diff "$RUNDIR/before-keychain.txt" "$RUNDIR/after-keychain.txt" || true)"
FULLF="$(diff "$RUNDIR/before-files.txt" "$RUNDIR/after-files.txt" || true)"
say "Keychain (every \`Claude Code-credentials*\` item):"
say ''; say '```'; say "${FULLK:-（identical — only the scratch item differs, and step 12 deletes it）}"; say '```'
say ""
say "Credentials files:"
say ''; say '```'; say "${FULLF:-（identical）}"; say '```'
say ""
printf '%s\n' "${FULLK:-keychain: only the scratch item differs}"
printf '%s\n' "${FULLF:-credentials files: identical}"

# ----------------------------------------------------------------- 9. teardown

cleanup "$STATE"

snapshot_keychain >"$RUNDIR/final-keychain.txt"
FINALK="$(diff "$RUNDIR/before-keychain.txt" "$RUNDIR/final-keychain.txt" || true)"
say "After teardown, against the BEFORE snapshot:"
say ''; say '```'; say "${FINALK:-（byte-identical）}"; say '```'
say ""
if [ -z "$FINALK" ]; then ok "machine restored: byte-identical to BEFORE"
else printf '\033[31mNOT restored:\033[0m\n%s\n' "$FINALK"; fi

step "Done"
printf 'Findings (redacted, safe to paste): %s\n' "$FINDINGS"
if [ "${REVOKE_NEEDED:-0}" = 1 ]; then
  printf '\n\033[31m!! MANUAL REVOCATION OWED !!\033[0m\n'
  printf 'The minted token survived logout and does not expire. Revoke it now at\n'
  printf '  https://claude.ai/settings  →  the account you signed in with\n'
  printf 'The local copy is shredded; the credential is not.\n'
fi
