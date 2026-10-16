#!/usr/bin/env bash
# migrate-from-rafiq — moves this Mac's Rafiq state to Wakil, once.
#
# The product was named Rafiq until 2026-10-15. This script and its test are the
# only code that still uses that name, on purpose: they exist to find the old
# state. Spec: docs/superpowers/specs/2026-10-15-rename-to-wakil-design.md.
#
#   scripts/migrate-from-rafiq.sh            Rafiq -> Wakil
#   scripts/migrate-from-rafiq.sh --reverse  Wakil -> Rafiq (the rollback)
#
# Tests set MIGRATE_KEYCHAIN (default: the login keychain) and
# MIGRATE_SECURITY (default: /usr/bin/security). An operator never needs to.
#
# A secret passes through `security add-generic-password -w` on argv for the
# length of one call, the same trade-off rafiqcore.SecretSet documents: there is
# no cgo Keychain binding to hand it over any other way.
set -euo pipefail

from=rafiq; to=wakil; From=Rafiq; To=Wakil
if [ "${1:-}" = "--reverse" ]; then from=wakil; to=rafiq; From=Wakil; To=Rafiq; fi

keychain="${MIGRATE_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
security="${MIGRATE_SECURITY:-/usr/bin/security}"

die() { echo "migrate: $*" >&2; exit 1; }

# 1. Refuse rather than overwrite.
for app in Rafiq Wakil RafiqApp WakilApp; do
	if pgrep -x "$app" >/dev/null 2>&1; then die "$app is running; quit it first"; fi
done
# An open Claude session keeps the MCP servers alive, and they recreate the state
# folder the moment it moves.
servers='/(rafiq|wakil)(-[a-z]+)?( |$)'
if pgrep -f "$servers" >/dev/null 2>&1; then
	die "a rafiq or wakil server is still running (see: pgrep -fl '$servers'); quit the Claude sessions that use them first"
fi
[ -d "$HOME/.$from" ] || die "nothing to migrate: $HOME/.$from does not exist"
[ ! -e "$HOME/.$to" ] || die "$HOME/.$to already exists; refusing to overwrite it"

# 2. Keychain: copy every item, read every copy back, and only then delete the
#    originals. Any failure deletes the copies made so far and changes nothing else.
services=$("$security" dump-keychain "$keychain" | FROM="$from" perl -ne '
	BEGIN { $/ = "keychain: " }
	next unless /^class: "genp"/m;
	next unless /^\s*"acct"<blob>="\Q$ENV{FROM}\E"$/m;
	if (/^\s*"svce"<blob>=0x/m) { print "UNPRINTABLE\n"; next }
	print "$1\n" if /^\s*"svce"<blob>="(\Q$ENV{FROM}\E:[^"\n]*)"$/m;
')
if grep -qx UNPRINTABLE <<<"$services"; then
	die "a $from Keychain item has a service name that is not plain text; move it by hand"
fi

created=()
rollback() {
	for svc in ${created[@]+"${created[@]}"}; do
		"$security" delete-generic-password -s "$svc" -a "$to" "$keychain" >/dev/null 2>&1 || true
	done
}

count=0
while IFS= read -r svc; do
	[ -n "$svc" ] || continue
	new="$to${svc#"$from"}"
	raw=$("$security" find-generic-password -s "$svc" -a "$from" -g "$keychain" 2>&1 >/dev/null) \
		|| { rollback; die "could not read $svc"; }
	case "$raw" in *"password: 0x"*) rollback; die "$svc holds a secret that is not plain text; move it by hand";; esac
	secret=$("$security" find-generic-password -s "$svc" -a "$from" -w "$keychain") \
		|| { rollback; die "could not read $svc"; }
	"$security" add-generic-password -s "$new" -a "$to" -w "$secret" "$keychain" \
		|| { rollback; die "could not add $new (does it already exist?)"; }
	created+=("$new")
	back=$("$security" find-generic-password -s "$new" -a "$to" -w "$keychain") \
		|| { rollback; die "could not read back $new"; }
	[ "$back" = "$secret" ] || { rollback; die "$new did not read back what was written; nothing was deleted"; }
	count=$((count + 1))
done <<<"$services"

stuck=""
while IFS= read -r svc; do
	[ -n "$svc" ] || continue
	"$security" delete-generic-password -s "$svc" -a "$from" "$keychain" >/dev/null 2>&1 || stuck="$stuck  $svc"$'\n'
done <<<"$services"
if [ -n "$stuck" ]; then
	printf 'migrate: the copies are in place, but these originals would not delete:\n%s' "$stuck" >&2
	die "delete them by hand (security delete-generic-password -s <service> -a $from), then re-run"
fi
echo "keychain: moved $count item(s) from $from: to $to:"

# 3. State, then each registered project's folder. The journal is history and
#    is not rewritten; only the org files' project paths are.
mv "$HOME/.$from" "$HOME/.$to"
echo "state: moved ~/.$from to ~/.$to"
trap 'echo "migrate: stopped after moving ~/.$from to ~/.$to; run with --reverse to undo" >&2' ERR
while IFS= read -r -d '' f; do
	if grep -q "/\.$from/project\.json" "$f"; then
		FROM="$from" TO="$to" perl -pi -e 's{/\.\Q$ENV{FROM}\E/project\.json}{/.$ENV{TO}/project.json}g' "$f"
		echo "  rewrote ${f#"$HOME/"}"
	fi
done < <(if [ -d "$HOME/.$to/orgs" ]; then find "$HOME/.$to/orgs" -name '*.json' -print0; fi)

if [ -d "$HOME/.$to/orgs" ]; then find "$HOME/.$to/orgs" -name projects.json -print0; fi \
	| xargs -0 cat 2>/dev/null \
	| TO="$to" perl -ne 'print "$1\n" while m{"path"\s*:\s*"([^"]+)/\.\Q$ENV{TO}\E/project\.json"}g' \
	| sort -u | while IFS= read -r dir; do
		if [ -d "$dir/.$from" ] && [ ! -e "$dir/.$to" ]; then
			mv "$dir/.$from" "$dir/.$to"
			echo "  project: moved $dir/.$from to .$to (commit it in that repository if it is tracked)"
		elif [ -d "$dir/.$to" ]; then
			echo "  project: $dir already has .$to"
		else
			echo "  project: $dir/.$from not found; left as it is"
		fi
	done

# 4. Preferences. The old domains stay: they are harmless, and they are the only
#    rollback for window state.
for pair in "dev.$from.app dev.$to.app" "${From}App ${To}App"; do
	set -- $pair
	if defaults read "$1" >/dev/null 2>&1; then
		defaults export "$1" - | defaults import "$2" -
		echo "defaults: copied $1 to $2"
	fi
done

# 5. What this script does not touch.
echo "Not changed; check these yourself:"
for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME"/.claude*/settings.json "$HOME"/.claude*/.claude.json; do
	if [ -f "$f" ] && grep -qi "$from" "$f"; then echo "  $f mentions $from"; fi
done
if command -v docker >/dev/null 2>&1; then
	docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^$from-" | while IFS= read -r c; do
		echo "  docker container $c (make test-live now expects $to-acc-*; recreate it from its setup help)"
	done || true
fi
echo "  Re-run scripts/register-provider.sh for each org and provider, so Claude's MCP"
echo "  config names the $to-* servers."
