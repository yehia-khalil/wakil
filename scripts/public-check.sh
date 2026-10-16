#!/usr/bin/env bash
# public-check — proves the tree names nothing on the denylist.
#
# The denylist lives outside the tree so the check that proves the real names are
# gone does not itself publish them. See
# docs/superpowers/specs/2026-10-15-public-repo-split-design.md.
set -euo pipefail

list="${WAKIL_DENYLIST:-$HOME/.config/wakil/public-denylist.txt}"
[ -f "$list" ] || { echo "public-check: no denylist at $list" >&2; exit 2; }
list="$(cd "$(dirname "$list")" && pwd)/$(basename "$list")"

cd "$(git rev-parse --show-toplevel)"
files=$(git ls-files -z -- "${@:-.}" ':!app/Resources/monaco' | tr '\0' '\n')

hits=$(printf '%s\n' "$files" | LIST="$list" perl -ne '
  BEGIN {
    open my $f, "<", $ENV{LIST} or die;
    while (<$f>) { chomp; next if /^\s*(#|$)/;
      if (s/^allow://) { push @allow, qr/$_/i } else { push @deny, qr/$_/i } }
  }
  chomp(my $path = $_);
  next if $path eq "";
  my $n = $path; $n =~ s/$_//g for @allow;
  for my $d (@deny) { if ($n =~ $d) { print "name: $path\n"; last } }
  next if -B $path;
  open my $in, "<", $path or next;
  while (my $line = <$in>) {
    my $t = $line; $t =~ s/$_//g for @allow;
    for my $d (@deny) { if ($t =~ $d) { chomp $line; print "$path:$.: $line\n"; last } }
  }
')

[ -z "$hits" ] && exit 0
printf '%s\n' "$hits"
echo "public-check: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') hit(s)" >&2
exit 1
