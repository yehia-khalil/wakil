#!/bin/bash
set -euo pipefail

# Wrapper for swift test that adds framework search paths for the Swift Testing module.
#
# Swift 6.3.2's SwiftPM does not automatically discover the Testing framework
# installed with Command Line Tools at $(xcode-select -p)/Library/Developer/Frameworks/Testing.framework.
# This wrapper adds the required -F flags and runtime rpaths so that the test bundle
# can find both Testing.framework and lib_TestingInterop.dylib at build and runtime.
# Tested and verified on macOS 26.6.2, CLT SDK 26.5, Swift 6.3.2 (swiftlang-6.3.2.1.108).
#
# The flags are conditionally applied: if Testing.framework is present, we add them;
# if not (e.g., when Xcode is installed later), SwiftPM will find Testing on its own
# and the flags become inert, ensuring the build doesn't break.

XCODE_PATH="$(xcode-select -p)" || {
    echo "error: xcode-select -p failed" >&2
    exit 1
}

if [ -z "$XCODE_PATH" ]; then
    echo "error: xcode-select -p returned empty path" >&2
    exit 1
fi

FW="$XCODE_PATH/Library/Developer/Frameworks"
LIB="$XCODE_PATH/Library/Developer/usr/lib"

# Caller-supplied arguments, inspected before the Testing.framework flags
# (below) are folded into "$@" — the isolation split further down needs to
# know whether the *caller* asked for a scoped run, not whether this script
# ended up adding flags of its own.
#
# Keyed on whether `--filter`/`--skip` actually appear, not on argument
# count: `[ "$#" -eq 0 ]` is false for ANY argument, including one that has
# nothing to do with scoping — `scripts/swift-test.sh -c release`, say —
# which used to fall into the "already scoped" branch below and run
# unsplit, putting the drain-regression test back in the parallel plan that
# was measured failing 3/3 (see the isolation comment further down).
CALLER_SCOPED=0
for arg in "$@"; do
    case "$arg" in
        --filter | --filter=* | --skip | --skip=*) CALLER_SCOPED=1 ;;
    esac
done

# macOS's system /bin/bash is 3.2, which throws "unbound variable" under
# `set -u` when expanding a zero-element array — so the Testing.framework
# flags are appended into $@ itself rather than kept in a separate array.
if [ -d "$FW/Testing.framework" ]; then
    set -- -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
fi

# ClaudeCodeCLIHarnessTests.swift's stopDeliversTheTailOfTheStreamRatherThanDiscardingIt
# is a real-time measurement (3000 of 3000 frames delivered against
# Engine.stdoutDrainDeadlineNanoseconds' 2-second production deadline), and
# Swift Testing parallelises an entire target's tests by default. Putting the
# test in a `@Suite(.serialized)` of its own is not enough by itself: that
# trait only serialises a suite's own children relative to each other, and
# measured on this machine, the suite still ran concurrently with the other
# ~377 tests and delivered only 1018 of 3000 frames on one run. Swift Testing
# has no trait for "do not run this test while anything else in the target
# is running" — the closest thing to it is running it in a separate `swift
# test` process with nothing else scheduled, which is what this does.
#
# This split only applies when the caller has not already scoped the run.
# If a caller supplies their own `--filter` or `--skip` — as the acceptance
# runbook's headless checks do, to run one test by name — they have already
# scoped the run themselves, so it runs once, unsplit. Any OTHER argument
# (`-c release`, `--parallel`, ...) does not scope anything and must still
# get the split, which is why this is keyed on CALLER_SCOPED rather than on
# whether any arguments were passed at all.
ISOLATED_TEST='stopDeliversTheTailOfTheStreamRatherThanDiscardingIt'

if [ "$CALLER_SCOPED" -eq 0 ]; then
    swift test "$@" --skip "$ISOLATED_TEST"
    swift test "$@" --filter "$ISOLATED_TEST"
else
    exec swift test "$@"
fi
