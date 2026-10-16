# 3a-i Task 1: the Monaco probe

Stop gate for the Git pane plan: does Monaco's diff editor render inside the
built Wakil.app with the network blocked?

## Vendored Monaco

- Version: `monaco-editor` 0.52.2 (`npm pack`, `min/vs` only)
- sha256 of the tarball: `c280cdcf0b0c13d1a2bf01af958d4387ed06d7f6c918401d00c4adcae1bc72b6`
- Vendored size (`du -sh app/Resources/monaco`): 14M
- Location: `app/Resources/monaco/` (`vs/`, `LICENSE`, `VERSION`)

## Resource-path decision

SwiftPM accepted `.copy("../../Resources/monaco")` from the WakilApp target,
so the tree was not moved under `Sources/WakilApp/`. The copy lands in the
resource bundle as a directory named `monaco`, a sibling of
`monaco-host.html`, so the host page loads `monaco/vs/loader.js` and sets
`paths: { vs: 'monaco/vs' }` (the plan's snippet said `vs/...`, which would
resolve to a path that does not exist in the bundle).
`scripts/make-app-bundle.sh` already `cp -R`s the whole resource bundle, so
no script change is needed.

## How the probe proves "offline"

Wi-Fi is not toggled. `MonacoDiffRenderer` installs a content rule list
blocking every request that is not `file:` or `blob:` (block-all, then
ignore-previous-rules per allowed scheme; rule-list regexes have no
lookahead). After `ready` the host page attempts `fetch('https://example.com')`
and posts `{type:'netprobe', blocked}`; the probe writes `net_blocked=<bool>`.
That attempt, the `{type:'layout'}` report and its animation-frame counter run
only when `window.wakilProbe` is set, which `--probe-monaco` alone does (a
`WKUserScript` at document start); a real pane makes no network attempt and
runs no idle frame loop. `MonacoDiffRenderer` takes the rule list as a
required argument, so no renderer exists without it (Task 10).

## Findings

- **Monaco needs a running AppKit event loop.** The early probes ran inside
  `main.swift`'s async top-level code with no `NSApp.run`. The window was
  never reported visible, WebKit kept the page `hidden` and fired no
  animation frames, and Monaco, which paints its lines from frames, painted
  none: the snapshot showed only the overview ruler. Spinning events by hand
  inside the async main task either starved the main queue (no `ready`) or
  let `swift_task_asyncMainDrainQueue`'s run loop return, and the runtime
  called `exit(0)`. The probe now calls `NSApp.run()` synchronously, starts
  its work from `applicationDidFinishLaunching`, and exits itself. An
  earlier note here blamed an offscreen window; that was wrong.
- **The diff worker runs off the main thread.** A `file:` page has origin
  `null`, so the loader cannot resolve the worker URL and Monaco falls back
  to the main thread. The host page sets `MonacoEnvironment.getWorkerUrl` to a
  blob that sets `baseUrl` and `importScripts` `workerMain.js` by absolute
  file URL; the rule list allows `blob:`. Run 11 logged no fallback warning.
- **`inactiveSchedulingPolicy = .none` is kept** so a pane scrolled off the
  canvas stays current. Its effect is unproven.
- **The host page forwards its diagnostics** (`window.onerror`,
  `unhandledrejection`, `console.error`/`warn`) to the `wakil` handler as
  `{type:'log'}`, and posts a `{type:'layout'}` report at `shown`. The probe
  writes both to `monaco-probe.log`; the Git pane keeps the bridge.

Run: `app/Wakil.app/Contents/MacOS/Wakil --probe-monaco <dir>` (writes
`monaco-probe.png`, `monaco-probe.txt` and `monaco-probe.log`). The probe
shows a borderless, click-through 900x600 window on screen for about a
second, as an `.accessory` app that never activates.

## Measurements (run 11)

| Item | Value |
|---|---|
| ready_ms | 407 |
| shown_ms | 506 |
| shown_via | raf (diff updated, then two frames) |
| net_blocked | true |
| Wakil.app size (`du -sh`) | 151M, of which Monaco is 14M |
| Snapshot | inline Swift diff with text, line numbers, highlighted changed tokens, green additions, muted deletions |
| Page log | `visibility=visible`, `rafTicks=7`, 80 `.view-line`s, fonts loaded, no worker fallback |
