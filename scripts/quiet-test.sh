#!/bin/bash
set -uo pipefail

# Runs a test command, writes its FULL output to a log, and prints only what
# a reader acts on: failures, crashes, errors and the run's own summary.
#
#   scripts/quiet-test.sh <log> -- <command> [args...]
#
# It exists because `make app-test` prints ~3,000 lines on a run, and about
# 2,300 of them are a "started" and a "passed" line per test. Measured
# 2026-09-24: 240 KB for one run. Every line an agent runs is read into its
# context and re-read on every turn after, so a passing suite was the single
# most expensive thing in a session, and it said almost nothing.
#
# NOTHING IS LOST. The log holds every byte, and VERBOSE=1 prints them too.
# This is a view of the output, not a replacement for it.
#
# THE EXIT CODE IS THE COMMAND'S, never the filter's: a quiet run that turned
# a red suite green would be worse than the noise it removed.
#
# It KEEPS by pattern rather than dropping by pattern, so a failure shape
# nobody anticipated is hidden, not invented. The guard against that is the
# tail: the last TAIL_LINES lines are always printed, whatever they say,
# because a crash — `Fatal error: Index out of range` — ends the run with
# no ✘ line at all, and the lines just before it name the test it killed.

if [ "$#" -lt 3 ] || [ "$2" != "--" ]; then
    echo "usage: $0 <log> -- <command> [args...]" >&2
    exit 64
fi

LOG="$1"
shift 2
TAIL_LINES="${TAIL_LINES:-15}"

mkdir -p "$(dirname "$LOG")"

if [ "${VERBOSE:-0}" = "1" ]; then
    "$@" 2>&1 | tee "$LOG"
    exit "${PIPESTATUS[0]}"
fi

"$@" >"$LOG" 2>&1
status=$?

# ANSI escapes are stripped before matching and printing: the compiler
# colours its diagnostics, and a pattern that has to allow for `[1;33m`
# in the middle of "warning:" is a pattern nobody can read.
awk -v tail_n="$TAIL_LINES" -v logpath="$LOG" -v status="$status" '
{
    line = $0
    gsub(/\033\[[0-9;]*m/, "", line)
    gsub(/\033\]8;;[^\033]*\033\\/, "", line)
    all[NR] = line
}
/✔ (Test|Suite)/                      { passed++; next }
line ~ /: warning:/                   { warnings++ }
line ~ /✘/                            { keep[NR] = 1; next }
line ~ /^↳/                           { keep[NR] = 1; next }
line ~ /(^|[^a-z])(error|Fatal error):/ { keep[NR] = 1; next }
line ~ /^Test run with /              { keep[NR] = 1; next }
line ~ /^Executed [0-9]+ tests?/      { keep[NR] = 1; next }
line ~ /^Note: Some test targets/     { keep[NR] = 1; next }
line ~ /^  - .*\((Swift Testing|XCTest)\)/ { keep[NR] = 1; next }
END {
    first_tail = NR - tail_n + 1
    shown = 0
    for (i = 1; i <= NR; i++) {
        if (i >= first_tail) break
        if (keep[i]) { print all[i]; shown++ }
    }
    if (first_tail > 1) print "  ··· last " tail_n " lines ···"
    for (i = (first_tail > 1 ? first_tail : 1); i <= NR; i++) { print all[i]; shown++ }
    printf "quiet-test: %d of %d lines shown (%d passed, %d warning lines hidden), exit %d. Full log: %s\n", \
        shown, NR, passed, warnings, status, logpath
}' "$LOG"

exit "$status"
