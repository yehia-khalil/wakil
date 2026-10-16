# termspike — the terminal pane's throughput harness

The instrument behind `docs/wakil/phase-2c-iii-probe.md`. Kept in the repository,
like `sttspike` and unlike this project's other probe spikes, because two of its
findings change [#72](https://github.com/yehia-khalil/rafiq/issues/72) and 2c-iii's
build will want to re-run measurements 5 and 6 against the real pane.

```
swift build -c release

./.build/release/termspike parse     # 1 — SwiftTerm parser feed rate
./.build/release/termspike blocks    # 2 — OSC 133 mark survival and walk cost
./.build/release/termspike gaps      # 3 — what SwiftTerm does not return
./.build/release/termspike pty       # 4 — the whole chain on a real shell
./.build/release/termspike grid      # 5 — the live grid, three constructions
./.build/release/termspike history   # 6 — the block history
./.build/release/termspike all       # all six
```

`TERMSPIKE_REPO` is the cwd the pty's shell starts in and the package its build
case builds (default: the process cwd; the probe run used `app/`).
`TERMSPIKE_BIGFILE` is the file the `cat` case reads (default
`/tmp/termspike-big.txt`); the run used 28 MB of 96-byte lines.

**Two traps, both of which this harness fell into once.**

- `TerminalDelegate` has **no content-change member**. A `refresh(source:…)` method
  compiles, satisfies nothing, is never called, and reports clean zeroes that look
  like a measurement. SwiftTerm accumulates a dirty range that the embedder polls
  with `getUpdateRange()`. See §4.2 of the probe.
- Peak-footprint deltas are only meaningful from an isolated subcommand run. Under
  `all` the allocator is warm and the same work reads 0.14 MB instead of 40.72 MB.

**Not built by `make`.** It pulls SwiftTerm, which `WakilKit` does not depend on
until 2c-iii ships. The deployment target matches the app package (macOS 14.4) on
purpose: a throughput number measured against a SwiftUI the shipping target cannot
have measures nothing.
