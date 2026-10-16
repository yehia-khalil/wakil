# WindowModel split and WakilKit layering — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink `WindowModel.swift` by moving its free-standing code out and extracting six self-contained pieces as their own tested types, then enforce `WakilKit`'s folder layering with a ratcheting test.

**Architecture:** Eight stacked PRs (gh-stack), one per step, merged together. Extractions keep every name tests use on `WindowModel` (forwarders). Moved state stays visible to `InvalidationContractTests`. The layering test reads `WakilKit`'s sources, builds a folder graph and checks a hard rule (nothing uses `App/`), a shrink-only allow-list, and that `Core/` uses nothing.

**Tech Stack:** Swift 6 (WakilKit, Swift Testing), Go 1.x (`go/build`), gh-stack.

**Spec:** `docs/superpowers/specs/2026-10-10-windowmodel-split-and-layering-design.md`

## Global Constraints

- No behaviour change anywhere. A test that needs more than a name/path change is a sign behaviour moved: stop and report.
- Every name a test uses on `WindowModel` keeps working (`WindowModel.slugForOrgIdentifier`, `nextFocusGeneration()`, `surfaceChainSettled()`, `rootWatcherForTesting`, `useClaudeLocatorForTesting`, `loginBinaryForTesting()`, `receiveForTesting`, …).
- `InvalidationContractTests.everyWindowModelPropertyIsClassifiedForTheOrgSwitch` stays green: each new stored property is classified; a moved name is removed from its old set.
- New types are `@MainActor`; one that a view reads is `@Observable`.
- Swift tests run from `app/`: `../scripts/swift-test.sh --filter <Name>`. Subagents run only filtered tests; the controller runs `make app-test` / `make test` / `make e2e`.
- Line numbers below are at 35c73fc1 and drift as code moves: **anchor on symbol names**.
- One stack layer per task; never commit a lower layer's change on a higher branch (gh-stack skill).
- No `Co-Authored-By` trailers.

## Review Focus

1. **An org switch after an extraction** — every moved piece of org state is still reset. Pinned per task by a reset test on the new type plus the classification test.
2. **Two overlapping git watcher syncs** (a refresh during a project switch) — the watcher's last instruction is the last sync's decision. Pinned in Task 3 (`overlappingSyncsReachTheWatcherInOrder`).
3. **A view reading moved state** (`claudePathOverride` in `Canvas.swift`, the register form) — still updates. `ClaudeLocator` is `@Observable` and `WindowModel` forwards with a computed property; Task 6 builds the app.
4. **The layering analyser misreading code** — a name in a comment or string, a type declared in two folders, a nested `CodingKeys`. Pinned in Task 8 by fake-tree tests.
5. **A stale allow-list entry after someone removes a dependency** — must fail, so the list shrinks. Pinned in Task 8 (`aStaleAllowedLinkFails`).

---

### Task 1: Stack bottom — move the free-standing code out (PR 1)

The bottom layer is the current branch, `yehia-khalil/windowmodel-split`, which already holds the spec and this plan.

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (remove lines 4–841 and 8084–8098 — the free code)
- Create: `app/Sources/WakilKit/Panes/PaneTable.swift` (`PaneRow` … `paneRowAccessibilityLabel`; **in `Panes/`, not `App/`**: `Api/` uses `PaneRow`, and nothing may use `App/` after Task 8)
- Create: `app/Sources/WakilKit/App/ThoughtRow.swift` (`ThoughtRow`, `thoughtRow(id:for:)`)
- Create: `app/Sources/WakilKit/App/ProviderCredentials.swift` (`ProviderCredentials`, `ProviderSelection`, `AlwaysSucceedsCredentialsLookupForTesting` made `internal`)
- Create: `app/Sources/WakilKit/App/AgentMCPConfig.swift` (`agentFacingServers` … `agentAllowedTools`)
- Create: `app/Sources/WakilKit/App/WindowModelSupport.swift` (`confirmationDescription`, `apiSurfaceCallDetaches`)
- Modify: `docs/superpowers/specs/2026-10-10-windowmodel-split-and-layering-design.md` (PaneTable goes to `Panes/`)

**Interfaces:** Produces nothing new; every moved symbol keeps its name and access level (except the one `private` → `internal`).

- [ ] **Step 1: Make the branch a stack**

```bash
cd /Users/operator/Desktop/scripts/wakil
gh extension list | grep -q gh-stack || gh extension install github/gh-stack
git config rerere.enabled true
gh stack init yehia-khalil/windowmodel-split
gh stack view --json
```
Expected: a stack with one branch, `yehia-khalil/windowmodel-split`, trunk `main`. If `init` refuses an existing branch, run `gh stack init --help` and use its adopt form; do not create a new branch.

- [ ] **Step 2: Split the file with a script** (save as `$SCRATCH/split_free.py`, where `$SCRATCH` is the session scratchpad)

```python
import re, sys
path = "app/Sources/WakilKit/App/WindowModel.swift"
src = open(path).read().split("\n")

def start_of(decl):
    """Index of the first doc-comment/attribute line above the line matching `decl`."""
    i = next(n for n, l in enumerate(src) if re.match(decl, l))
    while i > 0 and (src[i-1].startswith("///") or src[i-1].startswith("@")):
        i -= 1
    return i

blocks = [
    ("app/Sources/WakilKit/Panes/PaneTable.swift", start_of(r"^public struct PaneRow\b"), start_of(r"^public struct ThoughtRow\b")),
    ("app/Sources/WakilKit/App/ThoughtRow.swift", start_of(r"^public struct ThoughtRow\b"), start_of(r"^// MARK: - Provider credentials")),
    ("app/Sources/WakilKit/App/ProviderCredentials.swift", start_of(r"^// MARK: - Provider credentials"), start_of(r"^// MARK: - The agent's MCP configuration")),
    ("app/Sources/WakilKit/App/AgentMCPConfig.swift", start_of(r"^// MARK: - The agent's MCP configuration"), start_of(r"^// MARK: - WindowModel")),
]
class_end = max(n for n, l in enumerate(src) if l == "}" and n < start_of(r"^public func confirmationDescription\b"))
tail = ("app/Sources/WakilKit/App/WindowModelSupport.swift", start_of(r"^public func confirmationDescription\b"), len(src))

header = ["import Foundation", ""]
for out, a, b in blocks + [tail]:
    body = src[a:b]
    while body and body[-1] == "": body.pop()
    open(out, "w").write("\n".join(header + body) + "\n")

keep = src[:start_of(r"^public struct PaneRow\b")] + src[start_of(r"^// MARK: - WindowModel"):class_end + 1]
open(path, "w").write("\n".join(keep) + "\n")
print("kept", len(keep), "lines")
```

Run: `python3 $SCRATCH/split_free.py`
Expected: `kept` about 7,240 lines (8,098 − ~860).

- [ ] **Step 3: Fix the one access level**

In `app/Sources/WakilKit/App/ProviderCredentials.swift` change `private struct AlwaysSucceedsCredentialsLookupForTesting` to `struct AlwaysSucceedsCredentialsLookupForTesting` (it is the default `lookup` of `WindowModel.forTesting`, now in another file). Add `import Observation` to a new file only if the compiler asks for it.

- [ ] **Step 4: Build and run the suite**

Run: `make app-build` (from repo root), then from `app/`: `../scripts/swift-test.sh --filter "PaneTable|WindowModel|ThoughtRow|Provider|AgentMCP|InvalidationContract|Confirmation"`
Expected: builds; all listed suites pass. If a test fails, the move was not pure — diff the moved text against `git show HEAD:app/Sources/WakilKit/App/WindowModel.swift` and fix the split, never the test.

- [ ] **Step 5: Correct the spec and commit**

In the spec, PR 1's first bullet: change "→ `PaneTable.swift`" to "→ `Panes/PaneTable.swift` (not `App/`: `Api/` uses `PaneRow`)".

```bash
git add app/Sources/WakilKit docs/superpowers/specs/2026-10-10-windowmodel-split-and-layering-design.md
git commit -m "WindowModel: move the free-standing code into its own files (PR 1 of 8)"
```

---

### Task 2: Listings and palette helpers become their own types (PR 2)

**Files:**
- Create: `app/Sources/WakilKit/App/OrgListings.swift`, `app/Sources/WakilKit/App/PaletteItems.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (the statics in "Palettes" and "The context line's own listings")
- Test: create `app/Tests/WakilKitTests/OrgListingsTests.swift`

**Interfaces:**
- Produces: `enum OrgListings` with `nonisolated static` `orgListings(from:)`, `machineProviderListings(from:)`, `projectListings(from:)`, `environmentListings(from:)`, `adoptionCandidates(from:excluding:)` (public), `slugForOrgIdentifier(from:)` (public), and the helpers `intField(_:_:)`, `stringField(_:_:)` (now `internal`); `enum PaletteItems` with `sessionItems(from:)`, `age(ofRFC3339:now:)`, `providerItems(from:running:)`.
- `WindowModel` keeps a one-line forwarder for each of the nine public/internal statics, same signature, so the existing ~60 test call sites compile unchanged.

- [ ] **Step 1: Add the layer**

```bash
gh stack add yehia-khalil/wm-2-listings
```

- [ ] **Step 2: Write the failing test** (`OrgListingsTests.swift`) — it calls the new types directly, so it fails until they exist

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func orgListingsAndTheWindowModelForwarderAgree() {
    let rows: [JSONValue] = [.object(["id": .string("alpha"), "displayName": .string("Alpha")])]
    #expect(OrgListings.orgListings(from: rows) == WindowModel.orgListings(from: rows))
    #expect(OrgListings.orgListings(from: rows).first?.name == "alpha")
}

@Test func slugForOrgIdentifierLivesOnOrgListings() {
    #expect(OrgListings.slugForOrgIdentifier(from: "Umbrella Ops") == WindowModel.slugForOrgIdentifier(from: "Umbrella Ops"))
}

@Test func paletteAgeLivesOnPaletteItems() {
    let now = ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z")!
    #expect(PaletteItems.age(ofRFC3339: "2026-10-10T11:00:00.000Z", now: now)
        == WindowModel.age(ofRFC3339: "2026-10-10T11:00:00.000Z", now: now))
}
```

If `OrgListing` is not `Equatable`, compare `.map(\.name)` instead.

- [ ] **Step 3: Run it to see it fail**

Run: `../scripts/swift-test.sh --filter OrgListingsTests`
Expected: compile error — `cannot find 'OrgListings' in scope`.

- [ ] **Step 4: Move the bodies**

For each of the six listing statics plus `intField`/`stringField`: cut the whole function (doc comment included) from `WindowModel.swift` into

```swift
import Foundation

/// The org plane's and the context line's listings, parsed from `ctx_*` results.
/// Pure: no window state. Moved out of `WindowModel` (PR 2 of the split); the
/// window keeps same-named forwarders for its callers and tests.
enum OrgListings {
    // moved functions here, unchanged except `private` → `internal` on intField/stringField
}
```

Do the same for `sessionItems`, `age`, `providerItems` into `enum PaletteItems { … }` in `PaletteItems.swift`. Inside the moved bodies, `Self.x(` that referred to `WindowModel` statics now refers to the new enum — leave it if the callee moved with it, else write `WindowModel.x(`.

In `WindowModel`, where each function was, add its forwarder, e.g.:

```swift
    nonisolated internal static func orgListings(from rows: [JSONValue]) -> [OrgListing] {
        OrgListings.orgListings(from: rows)
    }
    nonisolated public static func slugForOrgIdentifier(from name: String) -> String? {
        OrgListings.slugForOrgIdentifier(from: name)
    }
    nonisolated internal static func age(ofRFC3339 stamp: String, now: Date = Date()) -> String? {
        PaletteItems.age(ofRFC3339: stamp, now: now)
    }
```

(one per moved public/internal static, signatures copied verbatim). Instance-method callers of `stringField`/`intField` in `WindowModel` become `OrgListings.stringField(` / `OrgListings.intField(`.

- [ ] **Step 5: Run the new and existing tests**

Run: `../scripts/swift-test.sh --filter "OrgListings|Palette|OrgPlane|Listing|Adoption|Slug|SessionItems"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/App app/Tests/WakilKitTests/OrgListingsTests.swift
git commit -m "WindowModel: listings and palette helpers become OrgListings and PaletteItems (PR 2 of 8)"
```

---

### Task 3: The git watcher becomes GitRootWatcher (PR 3)

**Files:**
- Create: `app/Sources/WakilKit/Git/GitRootWatcher.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`rootWatcher`, `watchedGitRoots`, `gitWatcherChain`, `syncGitWatcher`, the `init` assignment, `rootWatcherForTesting`)
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift`
- Test: create `app/Tests/WakilKitTests/GitRootWatcherTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class GitRootWatcher {
      enum Outcome: Equatable { case unchanged, started, stopped }
      let watcher: any RootWatcher
      private(set) var watchedRoots: [String]
      init(watcher: any RootWatcher)
      func sync(to wanted: [String], changed: @escaping @Sendable (String) async -> Void) async -> Outcome
  }
  ```
- Consumes: `RootWatcher` (`Git/GitWatcher.swift`): `watch(roots:window:changed:) async`, `stop() async`.

- [ ] **Step 1: Add the layer**

```bash
gh stack add yehia-khalil/wm-3-git-watcher
```

- [ ] **Step 2: Write the failing tests** (`GitRootWatcherTests.swift`)

```swift
import Foundation
import Testing
@testable import WakilKit

/// Records what it was told, in order.
private actor RecordingWatcher: RootWatcher {
    private(set) var calls: [String] = []
    func watch(roots: [String], window: Duration, changed: @escaping @Sendable (String) async -> Void) async {
        calls.append("watch " + roots.joined(separator: ","))
    }
    func stop() async { calls.append("stop") }
}

@MainActor
@Test func theSameRootsTwiceStartOneWatch() async {
    let recorder = RecordingWatcher()
    let watcher = GitRootWatcher(watcher: recorder)
    #expect(await watcher.sync(to: ["/a", "/b"], changed: { _ in }) == .started)
    #expect(await watcher.sync(to: ["/a", "/b"], changed: { _ in }) == .unchanged)
    #expect(await recorder.calls == ["watch /a,/b"])
    #expect(watcher.watchedRoots == ["/a", "/b"])
}

@MainActor
@Test func noRootsStopsAndForgetsThem() async {
    // The org-switch reset: `invalidateForOrgChange` ends in a sync to [].
    let recorder = RecordingWatcher()
    let watcher = GitRootWatcher(watcher: recorder)
    _ = await watcher.sync(to: ["/a"], changed: { _ in })
    #expect(await watcher.sync(to: [], changed: { _ in }) == .stopped)
    #expect(await recorder.calls == ["watch /a", "stop"])
    #expect(watcher.watchedRoots.isEmpty)
}

@MainActor
@Test func noRootsWhenNothingIsWatchedTellsTheWatcherNothing() async {
    let recorder = RecordingWatcher()
    let watcher = GitRootWatcher(watcher: recorder)
    #expect(await watcher.sync(to: [], changed: { _ in }) == .unchanged)
    #expect(await recorder.calls.isEmpty)
}

@MainActor
@Test func overlappingSyncsReachTheWatcherInOrder() async {
    let recorder = RecordingWatcher()
    let watcher = GitRootWatcher(watcher: recorder)
    async let first = watcher.sync(to: ["/p"], changed: { _ in })
    async let second = watcher.sync(to: ["/q"], changed: { _ in })
    async let third = watcher.sync(to: [], changed: { _ in })
    _ = await (first, second, third)
    #expect(await recorder.calls == ["watch /p", "watch /q", "stop"])
}
```

- [ ] **Step 3: Run to see them fail**

Run: `../scripts/swift-test.sh --filter GitRootWatcherTests`
Expected: compile error — `cannot find 'GitRootWatcher' in scope`.

- [ ] **Step 4: Implement `GitRootWatcher.swift`**

```swift
import Foundation

/// The window's git watcher, told which roots to watch (3a-i; extracted from
/// `WindowModel` in PR 3 of the split).
///
/// **Chained, not merely awaited.** Two syncs can overlap — a refresh landing
/// during a project switch — and each hops to the watcher's actor; chaining is
/// what keeps the watcher's last instruction the last sync's decision.
///
/// **Returning means the watcher has been told.** A sync that finds its
/// decision already made still waits for that instruction to land.
@MainActor
final class GitRootWatcher {
    enum Outcome: Equatable { case unchanged, started, stopped }

    let watcher: any RootWatcher
    /// The roots the watcher was last asked to watch; empty when it is stopped.
    private(set) var watchedRoots: [String] = []
    private var chain: Task<Void, Never>?

    init(watcher: any RootWatcher) {
        self.watcher = watcher
    }

    func sync(to wanted: [String], changed: @escaping @Sendable (String) async -> Void) async -> Outcome {
        guard wanted != watchedRoots else {
            await chain?.value
            return .unchanged
        }
        watchedRoots = wanted
        let previous = chain
        let watcher = watcher
        let next = Task {
            await previous?.value
            if wanted.isEmpty {
                await watcher.stop()
            } else {
                await watcher.watch(roots: wanted, window: .milliseconds(300), changed: changed)
            }
        }
        chain = next
        await next.value
        return wanted.isEmpty ? .stopped : .started
    }
}
```

- [ ] **Step 5: Use it in `WindowModel`**

Replace the three stored properties (`rootWatcher`, `watchedGitRoots`, `gitWatcherChain`) with:

```swift
    /// Watches the project's roots while a git pane is open — see `GitRootWatcher`.
    /// Nil only in tests that open no git pane.
    private let gitWatcher: GitRootWatcher?
```

In `init`, replace `self.rootWatcher = rootWatcher` with `self.gitWatcher = rootWatcher.map { GitRootWatcher(watcher: $0) }`. Change `var rootWatcherForTesting: (any RootWatcher)? { rootWatcher }` to `{ gitWatcher?.watcher }`.

In `syncGitWatcher`, keep its doc comment and everything up to `let wanted = …`; replace the rest with:

```swift
        guard let gitWatcher else { return }
        // (the existing roots / canvasIsCurrent / hasGitPane / wanted lines stay here)
        let changed: @Sendable (String) async -> Void = { [weak self] root in
            await self?.gitRootChanged(root)
        }
        switch await gitWatcher.sync(to: wanted, changed: changed) {
        case .unchanged:
            // A git pane opened while another is open leaves the roots unchanged, so the
            // watch does not restart; any git pane no read has reached yet reads now
            // (final review, item 6).
            if !wanted.isEmpty { await refreshUnreadGitPanes() }
        case .started:
            // A watch that starts reads first (fix round 1, I1): the watcher only reports
            // changes from now on.
            await refreshGitPanes(root: nil)
        case .stopped:
            break
        }
```

(`guard let gitWatcher` replaces the old `guard let rootWatcher` as the first line.)

- [ ] **Step 6: Reclassify in `InvalidationContractTests.swift`**

Remove `"watchedGitRoots"` from `orgDerived`, `"gitWatcherChain"` from `orgIndependent`, `"rootWatcher"` from `orgDerivedBehindAReference`; add to `orgDerivedBehindAReference`:

```swift
    // PR 3 of the split. `gitWatcher` holds the watcher and the roots it watches —
    // one for the window's life, whose CONTENTS are the outgoing project's roots.
    // `invalidateForOrgChange` ends with `syncGitWatcher`, which syncs it to no roots:
    // the watcher stops and `watchedRoots` empties (GitRootWatcherTests.noRootsStopsAndForgetsThem).
    "gitWatcher",
```

- [ ] **Step 7: Run the tests**

Run: `../scripts/swift-test.sh --filter "GitRootWatcher|Git|InvalidationContract|OrgSwitch|AppWiring"`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests/GitRootWatcherTests.swift app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "WindowModel: the git watcher becomes GitRootWatcher (PR 3 of 8)"
```

---

### Task 4: The terminal mirror becomes TerminalMirrorFeed (PR 4)

`Terminal/TerminalMirror.swift` already holds `MirrorEvent` and `mirroredBlocks`; the new class goes in that file and is named `TerminalMirrorFeed` (not `TerminalMirror`, which reads as the file's free functions).

**Files:**
- Modify: `app/Sources/WakilKit/Terminal/TerminalMirror.swift` (add the class)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`mirrorEvents`, `mirrorEventId`, `isMirrorRelevant`, `retainMirrorEvent`, `pumpMirror`, `backfillMirror`, the `mirrorEvents = []` in `invalidateForOrgChange`)
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift`
- Modify: `docs/superpowers/specs/2026-10-10-windowmodel-split-and-layering-design.md` (PR 4 type name)
- Test: create `app/Tests/WakilKitTests/TerminalMirrorFeedTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class TerminalMirrorFeed {
      private(set) var events: [MirrorEvent]
      init(panes: PaneStore, layout: LayoutStore)
      func retain(_ event: HarnessEvent, at arrivedAt: Date)
      func pump(_ event: HarnessEvent) async
      func backfill() async
      func reset()
  }
  ```
- Consumes: `MirrorEvent(_:at:)`, `mirroredBlocks(from:cap:)`, `TerminalBlock.historyCap`, `PaneStore.appendMirrored(paneId:block:)`, `PaneStore.setTerminalBackfilledAt(paneId:_:)`, `LayoutStore.snapshot()`. `HarnessEvent.toolUse(id:name:input:)`, `.toolResult(id:content:isError:)`.

- [ ] **Step 1: Add the layer**

```bash
gh stack add yehia-khalil/wm-4-mirror
```

- [ ] **Step 2: Write the failing tests** (`TerminalMirrorFeedTests.swift`). Find how existing tests build a `PaneStore` and a `LayoutStore` (`grep -n "LayoutStore(" app/Tests/WakilKitTests/*.swift | head -3`) and use the same construction in `makeFeed()`.

```swift
import Foundation
import Testing
@testable import WakilKit

@MainActor
private func makeFeed() -> TerminalMirrorFeed {
    let panes = PaneStore()
    let layout = LayoutStore(panes: panes)   // match the construction existing tests use
    return TerminalMirrorFeed(panes: panes, layout: layout)
}

private let bash = HarnessEvent.toolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")]))
private let bashResult = HarnessEvent.toolResult(id: "t1", content: .string("a\nb"), isError: false)

@MainActor
@Test func onlyTheAgentsBashCallsAndTheirResultsAreRetained() {
    let feed = makeFeed()
    feed.retain(.toolUse(id: "r1", name: "Read", input: .object([:])), at: Date())
    feed.retain(.toolResult(id: "r1", content: .string("x"), isError: false), at: Date())
    feed.retain(bash, at: Date())
    feed.retain(bashResult, at: Date())
    #expect(feed.events.map(\.event) == [bash, bashResult])
}

@MainActor
@Test func retainedEventsAreCappedAtTwiceTheHistory() {
    let feed = makeFeed()
    for n in 0..<(TerminalBlock.historyCap * 2 + 5) {
        feed.retain(.toolUse(id: "t\(n)", name: "Bash", input: .object([:])), at: Date())
    }
    #expect(feed.events.count == TerminalBlock.historyCap * 2)
}

@MainActor
@Test func resetForgetsEveryRetainedEvent() {
    // The org-switch reset: the outgoing org's agent commands must not replay.
    let feed = makeFeed()
    feed.retain(bash, at: Date())
    feed.reset()
    #expect(feed.events.isEmpty)
}
```

If `HarnessEvent` is not `Equatable`, compare `feed.events.count` and the ids instead.

- [ ] **Step 3: Run to see them fail**

Run: `../scripts/swift-test.sh --filter TerminalMirrorFeedTests`
Expected: compile error — `cannot find 'TerminalMirrorFeed' in scope`.

- [ ] **Step 4: Implement** — append to `TerminalMirror.swift`

```swift
/// The agent's `Bash` calls, mirrored into every terminal pane (Task 15;
/// extracted from `WindowModel` in PR 4 of the split).
@MainActor
final class TerminalMirrorFeed {
    private let panes: PaneStore
    private let layout: LayoutStore
    /// The agent's `Bash` tool uses and their results, as they arrived.
    private(set) var events: [MirrorEvent] = []

    init(panes: PaneStore, layout: LayoutStore) {
        self.panes = panes
        self.layout = layout
    }

    func retain(_ event: HarnessEvent, at arrivedAt: Date) {
        guard isRelevant(event) else { return }
        events.append(MirrorEvent(event, at: arrivedAt))
        let overflow = events.count - TerminalBlock.historyCap * 2
        if overflow > 0 { events.removeFirst(overflow) }
    }

    func pump(_ event: HarnessEvent) async {
        guard let id = Self.id(of: event),
              let block = mirroredBlocks(from: events, cap: TerminalBlock.historyCap)
                  .first(where: { $0.id == id })
        else { return }
        for pane in await layout.snapshot().panes where pane.kind == "terminal" {
            await panes.appendMirrored(paneId: pane.id, block: block)
        }
    }

    func backfill() async {
        let blocks = mirroredBlocks(from: events, cap: TerminalBlock.historyCap)
        guard !blocks.isEmpty else { return }
        // Captured once, before the loop, rather than per pane: every block in
        // `blocks` already happened, and nothing suspends between here and the
        // last `appendMirrored` below, so one timestamp at or after all of them —
        // and strictly before whatever `pump` appends next — separates "replayed
        // from history" from "streamed live" for every pane this call touches.
        let backfilledAt = Date()
        for pane in await layout.snapshot().panes where pane.kind == "terminal" {
            for block in blocks { await panes.appendMirrored(paneId: pane.id, block: block) }
            await panes.setTerminalBackfilledAt(paneId: pane.id, backfilledAt)
        }
    }

    func reset() { events = [] }

    private static func id(of event: HarnessEvent) -> String? {
        switch event {
        case .toolUse(let id, _, _): return id
        case .toolResult(let id, _, _): return id
        default: return nil
        }
    }

    private func isRelevant(_ event: HarnessEvent) -> Bool {
        switch event {
        case .toolUse(_, let name, _):
            return name == "Bash"
        case .toolResult(let id, _, _):
            return events.contains {
                if case .toolUse(let seenId, let seenName, _) = $0.event {
                    return seenId == id && seenName == "Bash"
                }
                return false
            }
        default:
            return false
        }
    }
}
```

- [ ] **Step 5: Use it in `WindowModel`**

Replace `private var mirrorEvents: [MirrorEvent] = []` with `private let mirror: TerminalMirrorFeed`; in `init`, after `panes` and `layout` are assigned: `self.mirror = TerminalMirrorFeed(panes: panes, layout: layout)` (use the local names `init` already uses for those two). Delete the five private mirror methods. Replace call sites: `retainMirrorEvent(event, at: Date())` → `mirror.retain(event, at: Date())`; `pumpMirror(` → `mirror.pump(`; `backfillMirror()` → `mirror.backfill()`; in `invalidateForOrgChange`, `mirrorEvents = []` → `mirror.reset()`.

- [ ] **Step 6: Reclassify** — remove `"mirrorEvents"` from `orgDerived` (keep its comment's substance), add to `orgDerivedBehindAReference`:

```swift
    // PR 4 of the split. `mirror` holds `events`, the outgoing org's agent `Bash`
    // calls; `invalidateForOrgChange` calls `mirror.reset()`
    // (TerminalMirrorFeedTests.resetForgetsEveryRetainedEvent).
    "mirror",
```

Update the spec's PR 4 row: type name `TerminalMirrorFeed`.

- [ ] **Step 7: Run the tests**

Run: `../scripts/swift-test.sh --filter "TerminalMirror|Mirror|InvalidationContract|OrgSwitch|Backfill"`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests docs/superpowers/specs/2026-10-10-windowmodel-split-and-layering-design.md
git commit -m "WindowModel: the terminal mirror becomes TerminalMirrorFeed (PR 4 of 8)"
```

---

### Task 5: The surface ordering chain becomes SurfaceChain (PR 5)

**Files:**
- Create: `app/Sources/WakilKit/App/SurfaceChain.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`surfaceChain`, `enqueueFromSurface`, `enqueueApiFocus`, `focusGenerations`, `nextFocusGeneration`, `surfaceChainSettled`, the three `await surfaceChain?.value` sites)
- Test: create `app/Tests/WakilKitTests/SurfaceChainTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class SurfaceChain {
      @discardableResult func enqueue<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never>
      func settled() async
      static func nextFocusGeneration() -> Int
  }
  ```
- The stored property keeps the name `surfaceChain` (already classified `orgIndependent`), so the tripwire needs no change.

- [ ] **Step 1: Add the layer**

```bash
gh stack add yehia-khalil/wm-5-surface-chain
```

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

@MainActor
@Test func workRunsInTheOrderItWasEnqueuedEvenWhenTheFirstIsSlow() async {
    let chain = SurfaceChain()
    var order: [Int] = []
    chain.enqueue { try? await Task.sleep(nanoseconds: 50_000_000); order.append(1) }
    chain.enqueue { order.append(2) }
    chain.enqueue { order.append(3) }
    await chain.settled()
    #expect(order == [1, 2, 3])
}

@MainActor
@Test func enqueueHandsBackTheWorksResult() async {
    let chain = SurfaceChain()
    let task = chain.enqueue { 42 }
    #expect(await task.value == 42)
}

@MainActor
@Test func settledOnAnEmptyChainReturns() async {
    await SurfaceChain().settled()
}

@MainActor
@Test func focusGenerationsOnlyGoUp() {
    let a = SurfaceChain.nextFocusGeneration()
    let b = SurfaceChain.nextFocusGeneration()
    #expect(b > a)
}
```

- [ ] **Step 3: Run to see them fail**

Run: `../scripts/swift-test.sh --filter SurfaceChainTests`
Expected: compile error — `cannot find 'SurfaceChain' in scope`.

- [ ] **Step 4: Implement `SurfaceChain.swift`**

```swift
import Foundation

/// The order an api pane's surface edits reach the store in (2c-iv Amendment 9a;
/// extracted from `WindowModel` in PR 5 of the split): each piece of work starts
/// only after everything enqueued before it has finished.
@MainActor
final class SurfaceChain {
    private var tail: Task<Void, Never>?
    private static var focusGenerations = 0

    @discardableResult
    func enqueue<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// Returns once everything enqueued so far has run.
    func settled() async { await tail?.value }

    static func nextFocusGeneration() -> Int {
        focusGenerations += 1
        return focusGenerations
    }
}
```

- [ ] **Step 5: Use it in `WindowModel`**

- `@ObservationIgnored private var surfaceChain: Task<Void, Never>?` → `@ObservationIgnored private let surfaceChain = SurfaceChain()` (keep the doc comment above it).
- `enqueueFromSurface`'s body becomes:

```swift
        surfaceChain.enqueue { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let calls = build(await self.panes.apiSnapshot(paneId: pane))
            let landed = calls.isEmpty ? true : await self.dispatchFromSurfaceInOrder(calls)
            settled(landed)
            return landed
        }
```

- `enqueueApiFocus`'s body becomes:

```swift
        surfaceChain.enqueue { @MainActor [weak self] in
            await self?.panes.setApiFocus(paneId: pane, fields: fields, generation: generation)
        }
```

- Delete `private static var focusGenerations`; `nextFocusGeneration()` becomes `{ SurfaceChain.nextFocusGeneration() }`.
- `surfaceChainSettled()` and the three `await surfaceChain?.value` lines become `await surfaceChain.settled()`.

- [ ] **Step 6: Run the tests**

Run: `../scripts/swift-test.sh --filter "SurfaceChain|Api|Surface|Focus|InvalidationContract"`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/App app/Tests/WakilKitTests/SurfaceChainTests.swift
git commit -m "WindowModel: the surface ordering chain becomes SurfaceChain (PR 5 of 8)"
```

---

### Task 6: The Claude locator becomes ClaudeLocator (PR 6)

**Files:**
- Create: `app/Sources/WakilKit/App/ClaudeLocator.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`providerLoginBinary`, `claudeLocator`, `locatedClaude`, `claudePathOverride`, `loginBinary`, `resolvedClaudePath`, `locateClaudeIfNeeded`, `useClaudeLocatorForTesting`, `init`)
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift`
- Test: create `app/Tests/WakilKitTests/ClaudeLocatorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor @Observable final class ClaudeLocator {
      var override: String
      private(set) var located: String?
      init(locator: ClaudeExecutableLocator?, injected: String)
      func loginBinary(ownBinaries: [String]) -> String
      func resolvedPath(ownBinaries: [String]) -> String
      func locateIfNeeded() async
      func use(_ locator: ClaudeExecutableLocator)
  }
  ```
- Consumes: `resolveLoginBinary(override:ownBinaries:located:)`, `ClaudeExecutableLocator(home:shellLookup:isExecutable:)`, `.locate()`.
- `WindowModel.claudePathOverride` stays `public var`, now computed (Canvas.swift sets it).

- [ ] **Step 1: Add the layer**

```bash
gh stack add yehia-khalil/wm-6-claude-locator
```

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

private func locator(answer: String, calls: LockedCounter) -> ClaudeExecutableLocator {
    ClaudeExecutableLocator(
        home: "/Users/x",
        shellLookup: { calls.increment(); return answer },
        isExecutable: { _ in true })
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@MainActor
@Test func anInjectedBinaryWinsOverEverything() {
    let claude = ClaudeLocator(locator: nil, injected: "/fake/claude")
    claude.override = "/typed/claude"
    #expect(claude.loginBinary(ownBinaries: ["/own/claude"]) == "/fake/claude")
    #expect(claude.resolvedPath(ownBinaries: ["/own/claude"]) == "/fake/claude")
}

@MainActor
@Test func theTypedOverrideWinsForALoginButNotForTheFormsPrefill() {
    let claude = ClaudeLocator(locator: nil, injected: "")
    claude.override = "/typed/claude"
    #expect(claude.loginBinary(ownBinaries: ["/own/claude"]) == "/typed/claude")
    #expect(claude.resolvedPath(ownBinaries: ["/own/claude"]) == "/own/claude")
}

@MainActor
@Test func theMachineLookupRunsOnce() async {
    let calls = LockedCounter()
    let claude = ClaudeLocator(locator: locator(answer: "/opt/homebrew/bin/claude", calls: calls), injected: "")
    await claude.locateIfNeeded()
    await claude.locateIfNeeded()
    #expect(calls.value == 1)
    #expect(claude.located == "/opt/homebrew/bin/claude")
    #expect(claude.resolvedPath(ownBinaries: []) == "/opt/homebrew/bin/claude")
}

@MainActor
@Test func aNewLocatorForgetsTheOldAnswer() async {
    let claude = ClaudeLocator(locator: locator(answer: "/a/claude", calls: LockedCounter()), injected: "")
    await claude.locateIfNeeded()
    claude.use(locator(answer: "/b/claude", calls: LockedCounter()))
    #expect(claude.located == nil)
    await claude.locateIfNeeded()
    #expect(claude.located == "/b/claude")
}

@MainActor
@Test func anOrgSwitchClearsTheTypedOverride() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    model.claudePathOverride = "/typed/claude"
    await model.invalidateForOrgChange()
    #expect(model.claudePathOverride == "")
}
```

- [ ] **Step 3: Run to see them fail**

Run: `../scripts/swift-test.sh --filter ClaudeLocatorTests`
Expected: compile error — `cannot find 'ClaudeLocator' in scope`.

- [ ] **Step 4: Implement `ClaudeLocator.swift`**

```swift
import Foundation
import Observation

/// Which `claude` a provider login spawns (#322; extracted from `WindowModel`
/// in PR 6 of the split). Order: an injected binary (tests), the path the
/// operator typed, this organisation's own record, the machine lookup.
@MainActor
@Observable
final class ClaudeLocator {
    /// The `claude` path the operator typed on the register form, which wins
    /// over every lookup. Empty means "use what Wakil found".
    var override: String = ""
    /// The machine lookup's answer, read once and off the main actor.
    private(set) var located: String?
    @ObservationIgnored private var locator: ClaudeExecutableLocator?
    /// A binary pinned by the caller (a test's fake); wins when non-empty.
    @ObservationIgnored private let injected: String

    init(locator: ClaudeExecutableLocator?, injected: String) {
        self.locator = locator
        self.injected = injected
    }

    func loginBinary(ownBinaries: [String]) -> String {
        if !injected.isEmpty { return injected }
        return resolveLoginBinary(override: override, ownBinaries: ownBinaries, located: located ?? "")
    }

    /// What the register form prefills: never the override.
    func resolvedPath(ownBinaries: [String]) -> String {
        if !injected.isEmpty { return injected }
        return resolveLoginBinary(override: "", ownBinaries: ownBinaries, located: located ?? "")
    }

    func locateIfNeeded() async {
        guard located == nil, let locator else { return }
        located = await Task.detached { locator.locate() }.value
    }

    func use(_ locator: ClaudeExecutableLocator) {
        self.locator = locator
        located = nil
    }
}
```

- [ ] **Step 5: Use it in `WindowModel`**

- Replace `providerLoginBinary`, `claudeLocator`, `locatedClaude` and the stored `claudePathOverride` with:

```swift
    /// Which `claude` a login spawns — see `ClaudeLocator`.
    private let claude: ClaudeLocator
    /// The `claude` path the operator typed on the register form (#322).
    public var claudePathOverride: String {
        get { claude.override }
        set { claude.override = newValue }
    }
```

- In `init`: replace `self.providerLoginBinary = providerLoginBinary` and `self.claudeLocator = claudeLocator` with `self.claude = ClaudeLocator(locator: claudeLocator, injected: providerLoginBinary)`.
- `loginBinary()` body (keep its Invariant 4 comment): `claude.loginBinary(ownBinaries: ownClaudeBinaries)`.
- `resolvedClaudePath()` body: `claude.resolvedPath(ownBinaries: ownClaudeBinaries)`.
- `locateClaudeIfNeeded()` body: `await claude.locateIfNeeded()`.
- `useClaudeLocatorForTesting(_ locator:)` body: `claude.use(locator)`.
- `invalidateForOrgChange`'s `claudePathOverride = ""` stays (it now goes through the setter).

- [ ] **Step 6: Reclassify** — remove `"claudePathOverride"` from `orgDerived`, `"claudeLocator", "locatedClaude"` from `orgIndependent`, and `"providerLoginBinary"` from whichever set holds it; add to `orgDerivedBehindAReference`:

```swift
    // PR 6 of the split. `claude` holds the operator's typed `claude` path (org-derived:
    // `invalidateForOrgChange` clears it through `claudePathOverride`,
    // ClaudeLocatorTests.anOrgSwitchClearsTheTypedOverride) and the machine lookup
    // (org-independent: one machine).
    "claude",
```

- [ ] **Step 7: Run the tests and build the app** (a view reads `claudePathOverride`)

Run: `../scripts/swift-test.sh --filter "ClaudeLocator|ClaudeExecutable|ProviderLogin|Settings|InvalidationContract"`, then from the repo root `make app-build`.
Expected: all pass; the app builds.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/App app/Tests/WakilKitTests/ClaudeLocatorTests.swift app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "WindowModel: the Claude locator becomes ClaudeLocator (PR 6 of 8)"
```

---

### Task 7: Shared vocabulary moves to Core/ (PR 7)

Measured 2026-10-10: these depend on nothing outside the set and Foundation. `Pane` (needs `Panes/` types) and `LayoutActionError` (needs `Pane`) fail the rule and stay.

**Files:**
- Create: `app/Sources/WakilKit/Core/JSONValue.swift` — from `MCP/JSONRPC.swift`: the `JSONValue` enum (from its doc comment "A JSON value tree"), both `extension JSONValue` blocks, and the `KeyedDecodingContainer` / `KeyedEncodingContainer` extensions (they decode/encode `JSONValue`)
- Create: `app/Sources/WakilKit/Core/ToolCaller.swift` — the `ToolCaller` protocol from `MCP/ToolCaller.swift`; `extension MCPClient: ToolCaller {}` stays in `MCP/ToolCaller.swift`
- Create: `app/Sources/WakilKit/Core/GateDecision.swift` — the `GateDecision` enum from `Gate/WriteGate.swift`
- Move (`git mv`): `Registry/Action.swift`, `Gate/EnvironmentName.swift`, `Layout/LayoutScope.swift`, `Panes/PaneContents.swift` → `Core/`

**Interfaces:** none change; same module, same names.

- [ ] **Step 1: Add the layer**

```bash
gh stack add yehia-khalil/wm-7-core
```

- [ ] **Step 2: Move**

```bash
cd /Users/operator/Desktop/scripts/wakil/app/Sources/WakilKit
mkdir -p Core
git mv Registry/Action.swift Core/Action.swift
git mv Gate/EnvironmentName.swift Core/EnvironmentName.swift
git mv Layout/LayoutScope.swift Core/LayoutScope.swift
git mv Panes/PaneContents.swift Core/PaneContents.swift
```

Then cut the three declarations named above into their new `Core/` files, each starting with `import Foundation`, text unchanged.

- [ ] **Step 3: Verify Core depends on nothing outside Core** (save as `$SCRATCH/core_deps.py`)

```python
import os, re
def strip(t):
    t = re.sub(r'"""[\s\S]*?"""', '""', t); t = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', t)
    t = re.sub(r'/\*[\s\S]*?\*/', '', t); return re.sub(r'//[^\n]*', '', t)
pat = re.compile(r'^\s*(?:(?:public|internal|private|fileprivate|final|nonisolated|@\w+(?:\([^)]*\))?)\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w+)', re.M)
root = "app/Sources/WakilKit"; defs = {}; core = {}
for d, _, fs in os.walk(root):
    for f in fs:
        if f.endswith(".swift"):
            p = os.path.join(d, f); rel = os.path.relpath(p, root); t = strip(open(p).read())
            for m in pat.finditer(t): defs.setdefault(m.group(1), rel.split("/")[0])
            if rel.startswith("Core/"): core[rel] = t
bad = {rel: sorted({w for w in re.findall(r'\b[A-Z]\w+\b', t) if defs.get(w, "Core") != "Core"}) for rel, t in core.items()}
for rel, ws in bad.items(): print(rel, ws or "ok")
```

Run (repo root): `python3 $SCRATCH/core_deps.py`
Expected: every `Core/` file prints `ok`. A file that names an outside type goes back to its folder (`git mv` back / paste back) and the plan's ruling is ledgered.

- [ ] **Step 4: Run the whole Swift suite** (a pure move must not change anything)

Run (repo root): `make app-build`, then from `app/`: `../scripts/swift-test.sh --filter "JSON|Action|Gate|Environment|LayoutScope|Pane|MCP|Registry"`
Expected: all pass. (The controller runs the full `make app-test` at the end.)

- [ ] **Step 5: Commit**

```bash
git add -A app/Sources/WakilKit
git commit -m "WakilKit: shared vocabulary types move to Core/ (PR 7 of 8)"
```

---

### Task 8: The layering tests (PR 8)

**Files:**
- Create: `app/Tests/WakilKitTests/LayeringTests.swift` (the analyser and its tests)
- Create: `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt`
- Create: `internal/wakilcore/layering_test.go`

**Interfaces:**
- Produces (test target only): `FolderGraph.build(files: [String: String]) -> FolderGraph`; `FolderGraph.edges: [FolderGraph.Edge: (file: String, type: String)]`; `FolderGraph.skipped: Set<String>`; `layeringVerdict(_ graph: FolderGraph, allowed: Set<String>) -> LayeringVerdict` with `intoApp`, `coreUsesOthers`, `unlisted`, `stale: [String]`.
- Go: `violation(module, pkg, imp string) string`.

- [ ] **Step 1: Add the layer**

```bash
gh stack add yehia-khalil/wm-8-layering
```

- [ ] **Step 2: Write the analyser's own tests first** (top of `LayeringTests.swift`)

```swift
import Foundation
import Testing

private let fakeTree: [String: String] = [
    "App/Model.swift": "final class AppThing {}",
    "Panes/Pane.swift": "struct PaneThing { var a: AppThing }",
    "Layout/Layout.swift": "struct LayoutThing { var p: PaneThing }",
    "Core/Value.swift": "struct CoreThing { var l: LayoutThing }",
    "Terminal/Term.swift": """
        struct TermThing { var c: CoreThing }
        // a LayoutThing in a comment does not count
        let s = "nor a LayoutThing in a string"
        """,
    "Api/A.swift": "struct Twin {}",
    "Git/B.swift": "struct Twin {}\nlet t = Twin()",
]

@Test func aLinkIntoAppFails() {
    let verdict = layeringVerdict(FolderGraph.build(files: fakeTree), allowed: ["Layout -> Panes"])
    #expect(verdict.intoApp == ["Panes -> App (Panes/Pane.swift uses AppThing)"])
}

@Test func anUnlistedLinkFails() {
    let verdict = layeringVerdict(FolderGraph.build(files: fakeTree), allowed: [])
    #expect(verdict.unlisted == ["Layout -> Panes (Layout/Layout.swift uses PaneThing)"])
}

@Test func aStaleAllowedLinkFails() {
    let verdict = layeringVerdict(FolderGraph.build(files: fakeTree), allowed: ["Layout -> Panes", "Gone -> Away"])
    #expect(verdict.stale == ["Gone -> Away"])
}

@Test func coreUsingAnotherFolderFails() {
    let verdict = layeringVerdict(FolderGraph.build(files: fakeTree), allowed: ["Layout -> Panes"])
    #expect(verdict.coreUsesOthers == ["Core -> Layout (Core/Value.swift uses LayoutThing)"])
}

@Test func anyFolderMayUseCoreAndCommentsAndStringsDoNotCount() {
    let graph = FolderGraph.build(files: fakeTree)
    let fromTerminal = graph.edges.keys.filter { $0.from == "Terminal" }.map(\.description)
    #expect(fromTerminal == ["Terminal -> Core"])
    #expect(layeringVerdict(graph, allowed: ["Layout -> Panes"]).unlisted.isEmpty)
}

@Test func aNameDeclaredInTwoFoldersIsSkippedNotGuessed() {
    let graph = FolderGraph.build(files: fakeTree)
    #expect(graph.skipped.contains("Twin"))
    #expect(!graph.edges.keys.contains { $0.to == "Api" || $0.to == "Git" })
}
```

- [ ] **Step 3: Run to see them fail**

Run: `../scripts/swift-test.sh --filter LayeringTests`
Expected: compile error — `cannot find 'FolderGraph' in scope`.

- [ ] **Step 4: Implement the analyser** (in `LayeringTests.swift`, below the imports)

```swift
/// `WakilKit`'s folders and which use which: a type declared in folder A and
/// named in a file of folder B is a link B -> A. Comments and string literals
/// are stripped first. A name declared in two folders, or a generic nested name,
/// is skipped and listed rather than guessed at.
struct FolderGraph {
    struct Edge: Hashable, Comparable, CustomStringConvertible {
        let from: String
        let to: String
        var description: String { "\(from) -> \(to)" }
        static func < (a: Edge, b: Edge) -> Bool { (a.from, a.to) < (b.from, b.to) }
    }

    /// Each link, with the first file and type that made it, for messages.
    var edges: [Edge: (file: String, type: String)] = [:]
    var skipped: Set<String> = []

    static let genericNames: Set<String> = ["CodingKeys", "Source", "Contents", "Kind", "State"]

    /// `files`: path relative to the source root ("Panes/PaneStore.swift") → its text.
    static func build(files: [String: String]) -> FolderGraph {
        var declaredIn: [String: Set<String>] = [:]
        var stripped: [String: String] = [:]
        for (path, text) in files {
            let clean = strip(text)
            stripped[path] = clean
            for name in matches(declarationPattern, in: clean) {
                declaredIn[name, default: []].insert(folder(of: path))
            }
        }
        var graph = FolderGraph()
        var owner: [String: String] = [:]
        for (name, folders) in declaredIn {
            if folders.count == 1, !genericNames.contains(name) { owner[name] = folders.first! }
            else { graph.skipped.insert(name) }
        }
        for (path, clean) in stripped.sorted(by: { $0.key < $1.key }) {
            let from = folder(of: path)
            for word in Set(matches(#"\b([A-Z]\w+)\b"#, in: clean)).sorted() {
                guard let to = owner[word], to != from else { continue }
                let edge = Edge(from: from, to: to)
                if graph.edges[edge] == nil { graph.edges[edge] = (path, word) }
            }
        }
        return graph
    }

    static func folder(of path: String) -> String {
        path.contains("/") ? String(path.split(separator: "/")[0]) : "(root)"
    }

    static func strip(_ text: String) -> String {
        var s = text
        for (pattern, replacement) in [
            (#"\"\"\"[\s\S]*?\"\"\""#, "\"\""),
            (#"\"(?:\\.|[^\"\\\n])*\""#, "\"\""),
            (#"/\*[\s\S]*?\*/"#, ""),
            (#"//[^\n]*"#, ""),
        ] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s
    }

    static let declarationPattern =
        #"(?m)^\s*(?:(?:public|internal|private|fileprivate|final|nonisolated|@\w+(?:\([^)]*\))?)\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w+)"#

    static func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}

struct LayeringVerdict {
    var intoApp: [String] = []
    var coreUsesOthers: [String] = []
    var unlisted: [String] = []
    var stale: [String] = []
    var isClean: Bool { intoApp.isEmpty && coreUsesOthers.isEmpty && unlisted.isEmpty && stale.isEmpty }
}

/// The rules: nothing uses `App/` (WindowModel stays on top); `Core/` uses no
/// other folder and any folder may use it; every other link is on the
/// allow-list; and every allow-list entry is still a real link, so the list
/// only shrinks.
func layeringVerdict(_ graph: FolderGraph, allowed: Set<String>) -> LayeringVerdict {
    var verdict = LayeringVerdict()
    for edge in graph.edges.keys.sorted() {
        let witness = graph.edges[edge]!
        let line = "\(edge) (\(witness.file) uses \(witness.type))"
        if edge.to == "App" { verdict.intoApp.append(line) }
        else if edge.from == "Core" { verdict.coreUsesOthers.append(line) }
        else if edge.to == "Core" { continue }
        else if !allowed.contains(edge.description) { verdict.unlisted.append(line) }
    }
    let real = Set(graph.edges.keys.map(\.description))
    verdict.stale = allowed.subtracting(real).sorted()
    return verdict
}
```

- [ ] **Step 5: Run the analyser's tests**

Run: `../scripts/swift-test.sh --filter LayeringTests`
Expected: the six fake-tree tests pass.

- [ ] **Step 6: Add the real-tree test** (append to `LayeringTests.swift`)

```swift
private let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let sourceRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/WakilKit")
private let allowedFile = testsDir.appendingPathComponent("Fixtures/layering-allowed.txt")

private func readTree(_ root: URL) -> [String: String] {
    var files: [String: String] = [:]
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
    for case let url as URL in walker where url.pathExtension == "swift" {
        let rel = String(url.path.dropFirst(root.path.count + 1))
        files[rel] = try! String(contentsOf: url, encoding: .utf8)
    }
    return files
}

private func readAllowed() -> Set<String> {
    let text = (try? String(contentsOf: allowedFile, encoding: .utf8)) ?? ""
    return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") })
}

@Test func wakilKitKeepsItsLayering() {
    let graph = FolderGraph.build(files: readTree(sourceRoot))
    let verdict = layeringVerdict(graph, allowed: readAllowed())
    #expect(verdict.intoApp.isEmpty, "Nothing in WakilKit may use App/ (WindowModel stays on top):\n\(verdict.intoApp.joined(separator: "\n"))")
    #expect(verdict.coreUsesOthers.isEmpty, "Core/ may use no other folder:\n\(verdict.coreUsesOthers.joined(separator: "\n"))")
    #expect(verdict.unlisted.isEmpty, """
        New folder links. If each is intended, add it to Fixtures/layering-allowed.txt \
        (the reviewer sees it); otherwise remove the dependency:
        \(verdict.unlisted.map { String($0.prefix(while: { $0 != "(" })).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
        """)
    #expect(verdict.stale.isEmpty, "These allowed links no longer exist; delete them from Fixtures/layering-allowed.txt:\n\(verdict.stale.joined(separator: "\n"))")
    print("layering: \(graph.edges.count) links; skipped names: \(graph.skipped.sorted().joined(separator: ", "))")
}
```

- [ ] **Step 7: Seed the allow-list from the failure**

Create `Fixtures/layering-allowed.txt` with this header and nothing else:

```
# WakilKit folder links allowed today (from -> to). LayeringTests fails on a
# link not listed here and on a listed link that no longer exists, so this list
# only shrinks. Core/ and links into it are not listed. Nothing may use App/.
```

Run: `../scripts/swift-test.sh --filter wakilKitKeepsItsLayering`
Expected: FAIL listing every current link under "New folder links", and **`intoApp` and `coreUsesOthers` empty**. If either is non-empty, Tasks 1 or 7 left something behind: fix the code, not the list. Paste the listed links into the file, sorted, one per line.

Run it again. Expected: PASS.

- [ ] **Step 8: Write the Go test** (`internal/wakilcore/layering_test.go`)

```go
package wakilcore_test

import (
	"bufio"
	"go/build"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// violation says why package pkg importing imp breaks the module's layering, or "".
// Rules: internal/... never imports cmd/...; internal/mcpx never imports internal/wakilcore.
func violation(module, pkg, imp string) string {
	in := func(p, dir string) bool { return p == module+"/"+dir || strings.HasPrefix(p, module+"/"+dir+"/") }
	if in(pkg, "internal") && in(imp, "cmd") {
		return pkg + " imports a command: " + imp
	}
	if in(pkg, "internal/mcpx") && in(imp, "internal/wakilcore") {
		return pkg + " imports wakilcore: " + imp
	}
	return ""
}

func TestLayeringRulesCatchWhatTheyShould(t *testing.T) {
	m := "example.com/x"
	cases := []struct {
		pkg, imp string
		bad      bool
	}{
		{m + "/internal/wakilcore", m + "/cmd/wakil", true},
		{m + "/internal/mcpx", m + "/internal/wakilcore", true},
		{m + "/internal/mcpx/mcpxtest", m + "/internal/wakilcore", true},
		{m + "/cmd/wakil", m + "/internal/wakilcore", false},
		{m + "/internal/wakilcore", m + "/internal/mcpx", false},
		{m + "/internal/wakilcore", "strings", false},
	}
	for _, c := range cases {
		if got := violation(m, c.pkg, c.imp) != ""; got != c.bad {
			t.Errorf("violation(%s -> %s) = %v, want %v", c.pkg, c.imp, got, c.bad)
		}
	}
}

func TestModuleKeepsItsLayering(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	module := modulePath(t, filepath.Join(root, "go.mod"))
	for _, top := range []string{"internal", "cmd"} {
		err := filepath.WalkDir(filepath.Join(root, top), func(path string, d fs.DirEntry, err error) error {
			if err != nil || !d.IsDir() {
				return err
			}
			if d.Name() == "testdata" {
				return filepath.SkipDir
			}
			p, err := build.ImportDir(path, 0)
			if err != nil {
				if _, ok := err.(*build.NoGoError); ok {
					return nil
				}
				return err
			}
			rel, _ := filepath.Rel(root, path)
			pkg := module + "/" + filepath.ToSlash(rel)
			for _, imp := range append(append(append([]string{}, p.Imports...), p.TestImports...), p.XTestImports...) {
				if v := violation(module, pkg, imp); v != "" {
					t.Error(v)
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

func modulePath(t *testing.T, goMod string) string {
	f, err := os.Open(goMod)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if line := strings.TrimSpace(s.Text()); strings.HasPrefix(line, "module ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "module "))
		}
	}
	t.Fatal("no module line in go.mod")
	return ""
}
```

Run (repo root): `go test ./internal/wakilcore -run 'Layering' -v`
Expected: both tests PASS. The real-tree check cannot be made to fail by a temporary import (a command is a `main` package and cannot be imported), so its failability rests on `TestLayeringRulesCatchWhatTheyShould`, which exercises every rule both ways.

- [ ] **Step 9: The remeasurement**

Run (repo root): the cycle script below and keep its output for the PR description.

```bash
python3 - <<'EOF'
import collections
edges = collections.defaultdict(set)
for line in open("app/Tests/WakilKitTests/Fixtures/layering-allowed.txt"):
    line = line.strip()
    if line and not line.startswith("#"):
        a, b = [x.strip() for x in line.split("->")]; edges[a].add(b)
nodes = set(edges) | {b for bs in edges.values() for b in bs}
idx, low, st, on, out, c = {}, {}, [], set(), [], [0]
def sc(v):
    idx[v] = low[v] = c[0]; c[0] += 1; st.append(v); on.add(v)
    for w in edges[v]:
        if w not in idx: sc(w); low[v] = min(low[v], low[w])
        elif w in on: low[v] = min(low[v], idx[w])
    if low[v] == idx[v]:
        comp = []
        while True:
            w = st.pop(); on.discard(w); comp.append(w)
            if w == v: break
        out.append(comp)
for v in sorted(nodes):
    if v not in idx: sc(v)
print("links:", sum(len(b) for b in edges.values()))
for comp in out:
    if len(comp) > 1: print("cycle group:", sorted(comp))
print("mutual pairs:", sorted({tuple(sorted((a, b))) for a in edges for b in edges[a] if a in edges.get(b, ())}))
EOF
```

Expected: fewer links than the 66 measured before PR 1, `App` in no cycle (nothing uses it).

- [ ] **Step 10: Commit**

```bash
git add app/Tests/WakilKitTests/LayeringTests.swift app/Tests/WakilKitTests/Fixtures/layering-allowed.txt internal/wakilcore/layering_test.go
git commit -m "Layering tests: nothing uses App/, Core/ uses nothing, and a shrink-only allow-list (PR 8 of 8)"
```

---

### Task 9: Gate, review and submit (controller only)

- [ ] **Step 1:** `make build`, then `make app-test` (background; read `.context/app-test.log`), then `make test`. Expected: green apart from known load flakes (rerun one alone before calling it a defect).
- [ ] **Step 2:** `make app-build`; launch `WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil`, open a terminal, an api and a git pane, quit. Expected: no crash.
- [ ] **Step 3:** `wc -l app/Sources/WakilKit/App/WindowModel.swift`. Expected: 5,000–6,000 lines.
- [ ] **Step 4:** Ask the operator for the screen, quit any live Wakil, `make e2e`. Expected: all checks pass, gate clear.
- [ ] **Step 5:** Fresh whole-stack review (most capable model) with this plan's Review Focus.
- [ ] **Step 6:** `gh stack submit --auto`, then put each PR's body in front of the operator as a draft (the remeasurement goes in PR 8's) before `gh pr edit`. Merge only on the operator's word: `gh stack merge <top PR> --yes`.
