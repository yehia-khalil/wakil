# WakilApp

`WakilApp` (`app/Sources/WakilApp/`) is the executable target: SwiftUI and AppKit views, the Metal
void, and the process's entry point. **It has no test target** (`app/Package.swift`), so the rule is:
views read `WindowModel` and dispatch through it, and nothing worth asserting is decided here. A pure
decision a view needs goes in `WakilKit`, beside the pane kind or folder it belongs to (*convention*;
see `CONTRIBUTING.md`).

## `main.swift` and its modes

`main.swift` checks its arguments in this order, before anything touches AppKit, and exits from
each mode:

| Flag | What it does |
|---|---|
| `--mcp-shim --socket <path>` | `runShim` (`WakilKit/MCP/Shim.swift`): copies stdio to and from the window's socket. The agent's `claude` spawns the app this way. Runs headless; `ShimTests` checks it exits rather than hangs with no display. |
| `--dispatch <file> [--environment <name>]` | `runDispatchFile`: builds the same assembly as the window (`WakilWiring.build`), runs each line of the JSONL file through `runDebugScriptReportingFailures`, prints one line per non-empty input line, then `wiring.shutdown()`. `--environment` defaults to `development` and is only the string the gate judges and the journal records. Exit 0 all ran, 1 never ran, 2 a line failed. Journals to `~/.wakil/journal`. |
| `--capture <directory>` | `runCapture` (`Capture.swift`): offscreen Metal renders of the void. |
| `--capture-motion <directory>` | `runCaptureMotion` (`Capture.swift`): frame sequences per state. |
| `--bench-surface [rows]` | `runSurfaceBench` (`SurfaceBench.swift`): hosts `DataSurface` over synthetic rows (default 50,000) and prints scroll cost. |

With none of them, `WakilApplication.main()` opens the window.

## From launch to a window

1. `WakilApplication` (`AppScene.swift`) is the SwiftUI `App`: one `WindowGroup` holding
   `WakilWindow`, with `WakilAppDelegate` as the application delegate.
2. `WakilWindow` (`WakilWindow.swift`) starts `WindowSession.start()` in its `.task`, hands the
   startup `Task` to the delegate before awaiting it, then calls `model.refreshContext()` and
   `model.refreshPanes()`.
3. `WindowSession.start()` (`WindowSession.swift`) assembles the window: see
   [runtime.md](runtime.md).
4. On quit, `WakilAppDelegate.applicationShouldTerminate` answers `.terminateLater`, awaits the
   startup task, runs `WindowSession.shutdown()`, then replies to AppKit. With no startup task yet
   it answers `.terminateNow`.
   Before that, `applicationShouldTerminate` and the window's close button (`windowShouldClose`) ask
   `WindowModel.requestQuit()`: a dirty editor tab raises the unsaved prompt first, minimised or not.

## The canvas

`Canvas.swift` (an extension of `WakilWindow`) draws the panes. Its `paneView(_:_:)` holds
**`switch pane.kind`**, which picks each pane's view:

| `pane.kind` | View | Reads from `WindowModel` |
|---|---|---|
| `db` | `DBPane` (`DBPane.swift`, with `DataSurface.swift` and `QueryLineEditor.swift`) | `table(_:)`, `editable(paneId:)`, query-line state |
| `terminal` | `TerminalPane` (`TerminalPane.swift`; its header row is `PaneStripRow`) | `terminal(_:)` |
| `api` | `ApiPane` (`ApiPane*.swift`, `ApiFieldEditor.swift`, `ApiTokenView.swift`, `ApiPaneFlow.swift`) | `api(_:)` |
| `editor` | `EditorPane` (`EditorPane.swift`, `EditorColumn.swift`, `MonacoEditorRenderer.swift` (one page: the code editor and the diff editor, 3b-iii), `EditorMiddleClick.swift`, `monaco-host.html`; its tabs are the shared `PaneTabStrip`) | `editor(_:)`, `gitRoots`, `editorSaveAsRequest`, the unsaved prompt |
| `settings` (`Pane.settingsKind`) | `SettingsPane` (`SettingsPane.swift`, `SettingsForm.swift`) | `settings`, `accounts`, the login state |
| `browser` | `BrowserPane` (`BrowserPane.swift`, `BrowserPaneHeader.swift` — its tabs on the shared `PaneTabStrip`, and the address row, which also draws the site tag chip, the tab dots and the *agent allowed* mark — `BrowserPrompts.swift`, `BrowserWebView.swift`), its pages from the window's `BrowserTabHost` | `browser(_:)`, `browserScope`, `browserSettingsCache` |
| anything else | a "no view for a … pane" line | — |

**Edge to edge** (2026-10-26, `PaneKind.edgeToEdge`, read as `Pane.edgeToEdge`): the editor, the
terminal and the browser draw to the slab's border. `paneView` drops the inset, `PaneTitle` and the
resize row for them, and `EdgeToEdgePane` clips the content to the slab's corners, draws the border
token's 1 px edge and puts the resize handle on a chip over the bottom-right corner. Their first row
is the compact chrome in `PaneTabStrip.swift`: `PaneStripStyle` (the 32 pt row, the border token and
the hairline, the tab entry's numbers), `PaneStripRow` and `PaneGlyph` (the kind's glyph in the
title's place), `PaneHairline`, and `PaneTabStrip` — the tab strip the browser and the editor share,
its overflow worked out by `TabStripLayout` (WakilKit).

`terminal(_:)`, `api(_:)` and `editor(_:)` each read one pane's `PaneSnapshotCell`, so one
pane's terminal tick writes only that pane's cell and invalidates only views reading it
(`refreshPanes`, after every action, still rewrites every pane's cell). Whether SwiftUI redraws
only that view depends on `paneView`'s call site in `Canvas.swift` (unchanged, untested).
`PaneSnapshotCellTests` pins the write.

**A link the operator clicks elsewhere in Wakil** goes through `WakilLinks.open` (`WakilLinks.swift`):
`WindowModel.openLinkInWakil` (`browser_open`, a new tab in the place's browser pane, which comes
forward with the keyboard), or the system browser on ⌥-click — the modifier as the clicked surface saw it at the
press (`monaco-host.html` records `altKey` from a capture-phase mousedown and posts it with `web`). 3c-i's one caller
is the blame hover's Open on GitHub (`EditorPane`'s `openLink`).

**The browser pane does not own its pages.** `BrowserTabHost` (`BrowserTabHost.swift`), held by
`WindowSession` for the life of the window, keeps one `WKWebView` per tab **keyed by place** —
`(LayoutScope, pane, tab)` — so a tab switch, a resize or a place switch rebuilds the SwiftUI view and
puts the same web view back, never reloading the page; pane and tab ids repeat from place to place, and
a key without the place would hand one organisation's logged-in page to another (Invariant 4). Each
view is built on its organisation's `WKWebsiteDataStore(forIdentifier:)`; at most 20 are live, the
least recently shown saved to its `interactionState` and rebuilt on selection. **The seam rule:** a
web view reports what the page did (title, URL, progress, find count, downloads, a page-opened tab)
through `PaneStore`'s seam calls, never through an action, and carries its place; `WindowModel`
drops a report from a place not on screen, and the pane asks for every report again when its place
is shown (`reportAll`). Commands go the other way only: an action bumps the tab's `command`, the
pane's `sync` hands it to the host. A page's own prompts (alert, sign-in, camera) are the host's,
not store state (`BrowserPrompt`): the page asked, not the operator or the agent.
`BrowserSettingsForm.swift` is Settings → Browser (search engine, start page, Clear data).

**The agent's reach into a page (3c-ii)** is `BrowserPageAgent` (`BrowserPageAgent.swift`), the
`BrowserPageDriver` WakilKit's actions call, and `BrowserAgentScript.swift`, the script it runs. The
driver works only on a tab's existing live web view (`BrowserTabHost.liveView`; none live means
*not loaded*), never takes the keyboard and never selects a tab (Rule 6). The script runs in the
isolated content world `wakil.agent`, so the page cannot see it; the agent's strings reach it only as
`callAsyncJavaScript` arguments, never as source. It reads visible elements with refs (open shadow roots
walked, frames counted), builds the page text from text nodes and skips every never-list field, and
re-checks the live element at act time. An act waits out the operator's typing (`lastOperatorInput`,
1 s quiet, 10 s ceiling) and each call has a 10 s timeout. The driver replaces any script failure that
is not the script's own fixed sentence with Wakil's, so no page text reaches the agent that way.

**This switch is the one view-side place a new pane kind touches**: its view file and one `case`
(the rest of the recipe is `CONTRIBUTING.md`, "A new pane kind").

## The other views

| View | File | What it is |
|---|---|---|
| `Rail` | `Rail.swift` | The list of pane names, one way to reach a pane; promoted on hover |
| `ContextLine` | `ContextLine.swift` | The active org, project and environment, drawn as one line |
| `ComposerBar` | `ComposerBar.swift` | The bar typed and spoken text land in; Return sends |
| `ThoughtThread` | `ThoughtThread.swift` | The agent's progress, rising from the bottom edge |
| `ConfirmationPlane` | `ConfirmationPlane.swift` | The typed confirmation for a gated mutation; the site question (3c-ii): **Don't Allow** / **Allow for this conversation**, a click for a typed request and the typed word for a spoken one |
| `OrgPlane` | `OrgPlane.swift` | ⌘⇧O: every organisation on the machine; create, adopt, switch |
| `Landing` | `Landing.swift` | What the window draws before the session has done anything |
| `PalettePlane`, `PaletteController` | `Palettes.swift` | ⌘K and ⌘P, driving `PaletteModel` |
| `VoidView` | `VoidView.swift` | The Metal void behind everything (shader `app/Shaders/Void.metal`) |
| `DataSurface` | `DataSurface.swift` | The db pane's grid: its keys (⌘C, Space, ↑↓, Esc), right-click menu and footer Cancel |
| `RowDetailStrip` | `RowDetailStrip.swift` | The db pane's side strip showing the selected row's whole values |

## The rule for views

- **Read `WindowModel`, dispatch through it.** A control calls a `WindowModel` method (for example
  `dispatchFromSurface`), which goes through `ActionRegistry.dispatch` with origin `.ui`. A view
  never calls an `MCPClient` or writes a store. That every state change goes through the registry is
  charter Invariant 2 (`docs/wakil/north-star.md` §4).
- **Every control follows `PRODUCT.md` §Interaction Rules.**
- **Accessibility identifiers are the e2e harness's handles.** `make controls` lists them, and the
  coverage gate expects a check for a new one or a line in `e2e/checks/uncoverable.tsv`. See
  [testing.md](testing.md).
