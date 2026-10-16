# 2d-ii Voice Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push-to-talk on ⌥ that lands an unsent, editable transcript in a new composer bar; a compact thought thread that overlaps full-height panes; a phase-continuous listening breath; and a per-organization pluggable speech engine with Apple as the one conformance.

**Architecture:** Everything with a right answer lives in `WakilKit` as pure value types that take time as an argument (`ListeningMachine`, `ThreadDisclosure`, `BreathClock`, `ComposerText`, `SpeechRegistry`) plus one `@MainActor` coordinator (`ComposerModel`) that runs the machine's effects against a `SpeechProvider`. `WakilApp` only draws them and forwards key, mouse and app-activation events. Go gains one optional `org.json` string, `speechProvider`, written through the existing `update_org` path.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, Swift Testing, Speech (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26+), AVFoundation, Core Audio; Go 1.x for `internal/wakilcore` and `cmd/wakil-ctx`.

**Spec:** `docs/superpowers/specs/2026-10-07-2d-ii-voice-capture-design.md`. Prototype: `docs/wakil/screens/Composer.prototype.html` (variant A) — open it to see the composer bar and thread behaviour every UI task below reproduces.

## Global Constraints

- Push-to-talk is ⌥ held **alone** for **180 ms** (`ListeningMachine.armDelay = 0.18`), only while Wakil is the key app. No global hotkey.
- Release lands the transcript **unsent** at the caret; **Return sends**, **⇧Return** breaks a line, **Esc while holding** discards this hold. No Send button.
- Silence notice after **1.5 s** with no audio (`silenceAfter = 1.5`): `Hearing nothing from <device name>`. Denied: `Wakil can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone`. **Never a meter or waveform** (design-language §12).
- Composer hints, verbatim: `Hold ⌥ to speak · ⌘P open · ⌘K actions`; after a landing: `heard · Return sends · edit first`; while holding: `release to put it in the line`.
- Thread: **4** rows visible, `N earlier · show` above; rest opacity **0.32**, full on hover in **160 ms**; click expands a row in place (monospaced, wrapped, selectable); folds **1.2 s** after the pointer leaves unless a mouse button is held; Esc folds; a `you` row per sent turn; hit-testing on rows only. Errors are not exempted from the fade.
- The 132 pt `threadClearanceReserve` is **deleted**; panes take the full height.
- Breath: phase-continuous across state changes; amplitude/spread/drift/coupling ease with a **0.25 s** time constant; Reduce Motion holds amplitude at the state's mean and zeroes drift.
- Speech engine id lives in `org.json` as `speechProvider` (optional, `omitempty`); missing → `apple`; unknown → Apple plus the note `unknown engine '<id>', using Apple`. Apple is the only registered engine. English (`en-US`) only.
- `WakilKit` stays free of AppKit (`VoidPalette`'s rule). Speech/AVFoundation/CoreAudio are allowed in `WakilKit` only inside `AppleSpeechProvider.swift`, behind `#if canImport(Speech)` and `@available(macOS 26.0, *)`. The package platform stays `.macOS("14.4")`.
- **No GUI runs** (`make e2e*`, launching `Wakil.app`) while peer session burrfish holds the GUI; ask the operator first (memory: shared GUI between sessions).
- Subagents run **scoped** test filters only; the controller runs full gates (Task 17).
- Commits: no `Co-Authored-By` trailer, no "Generated with" line (operator rule).
- Every UI task checks PRODUCT.md §Interaction Rules; the spec's errors table names which rule each case meets.

## Review Focus

1. **Two windows open, ⌥ held in one.** The `NSEvent` local monitor sees app-wide events; only the key window's composer may arm. Pinned in Task 12 by the `isKeyWindow` guard and covered by the e2e auditor; reviewers check the guard exists.
2. **⌥ released before the engine has started** (fast tap just over 180 ms, or a slow `speechEngineId()` lookup). The machine is `finishing` with no provider; it must not start an engine late, and must time out to idle. Pinned in Task 4 (`finishingTimesOutAndLandsWhatWasHeard`) and Task 7 (`releaseBeforeTheEngineStartsNeverStartsIt`).
3. **A provider that never sends `.final` after `stop()`.** The 2 s `finishTimeout` lands what was heard and cancels. Pinned in Task 4.
4. **Organisation switch, then hold ⌥.** The engine id must be the new organisation's, not a cached one. Pinned in Task 6 (`speechEngineIdIsReReadAfterTheOrgChanges`).
5. **Caret past the end, or inside a multi-unit character** (emoji, CRLF) when speech lands. `ComposerText.insert` clamps and works in UTF-16, as NSTextView reports. Pinned in Task 5.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `internal/wakilcore/org.go`, `orgupdate.go`, `configtree.go` | modify | `speechProvider` field, patch, tree |
| `cmd/wakil-ctx/main.go` | modify | `update_org` accepts `speechProvider` |
| `internal/wakilcore/orgupdate_test.go`, `configtree_test.go` | modify | Go tests |
| `app/Sources/WakilKit/Panes/SettingsTree.swift` | modify | `SettingsOrg.speechProvider` |
| `app/Sources/WakilKit/Registry/StandardActions.swift` | modify | `ctx_update_org` forwards `speechProvider` |
| `app/Sources/WakilKit/Registry/ActionRegistry.swift` | modify | `journalVoiceTurn(environment:)` |
| `app/Sources/WakilKit/Speech/SpeechProvider.swift` | create | `SpeechEvent`, `SpeechProvider`, `SpeechEngine`, `SpeechRegistry` |
| `app/Sources/WakilKit/Speech/ScriptedSpeechProvider.swift` | create | the scripted engine (tests and e2e) |
| `app/Sources/WakilKit/Speech/ListeningMachine.swift` | create | push-to-talk state machine |
| `app/Sources/WakilKit/Speech/AppleSpeechProvider.swift` | create | the Apple conformance + `SpeechRegistry.standard` |
| `app/Sources/WakilKit/App/ComposerText.swift` | create | landing rule + bar content |
| `app/Sources/WakilKit/App/ComposerModel.swift` | create | coordinator: machine ↔ provider ↔ window |
| `app/Sources/WakilKit/App/ThreadDisclosure.swift` | create | thread fold/expand/fade state |
| `app/Sources/WakilKit/Visual/BreathClock.swift` | create | phase-continuous, eased motion |
| `app/Sources/WakilKit/App/WindowModel.swift` | modify (small) | `isListening`, `coreState`, `send(_:via:)`, `you` row, `appendSpeechFailure`, `speechEngineId()`, `OrganisationField.speechProvider` |
| `app/Sources/WakilKit/App/AppWiring.swift` | modify | `WakilWiring.speech` |
| `app/Sources/WakilApp/VoidView.swift` | modify | uses `BreathClock`, reads Reduce Motion |
| `app/Sources/WakilApp/ComposerBar.swift` | create | the bar view, `ComposerField` editor, key monitor |
| `app/Sources/WakilApp/WakilWindow.swift` | modify | mounts the bar, deletes the reserve and the old TextField |
| `app/Sources/WakilApp/WindowSession.swift` | modify | builds `ComposerModel` |
| `app/Sources/WakilApp/ThoughtThread.swift` | rewrite | compact, faded, expandable thread |
| `app/Sources/WakilApp/SettingsPane.swift` | modify | Speech row |
| `scripts/make-app-bundle.sh` | modify | Info.plist usage strings |
| `app/Tests/WakilKitTests/*` | create | one test file per new WakilKit unit |
| `docs/wakil/design-language.md`, `PRODUCT.md`, `Visual/CoreState.swift` doc | modify | record the amended §12 and §9 |

**Merge-risk note:** burrfish's unmerged `yehia-khalil/db-query-line` also edits `WindowModel.swift` (+14 lines) and `InvalidationContractTests.swift` (1 line). Keep this plan's `WindowModel` edits to the marked spots so the later rebase is mechanical.

---

### Task 1: `speechProvider` in Go

**Files:**
- Modify: `internal/wakilcore/org.go:18-32` (struct `Org`)
- Modify: `internal/wakilcore/orgupdate.go:15-38`
- Modify: `internal/wakilcore/configtree.go:13-19` and `:172-177`
- Modify: `cmd/wakil-ctx/main.go:133-141` (`updateOrgArgs`) and `:428-432` (`update_org` handler) and the tool `Description` string at `:427`
- Test: `internal/wakilcore/orgupdate_test.go`, `internal/wakilcore/configtree_test.go`

**Interfaces:**
- Produces: `org.json` key `speechProvider` (string, omitted when empty); `ConfigTreeOrg.SpeechProvider` serialised as `"speechProvider"`; `update_org` argument `speechProvider` (optional string, `""` clears).

- [ ] **Step 1: Write the failing tests**

Append to `internal/wakilcore/orgupdate_test.go`:

```go
// TestUpdateOrgWritesSpeechProviderAndLeavesTheRest is 2d-ii's field on
// the read-modify-write path: the Speech row sends only this key.
func TestUpdateOrgWritesSpeechProviderAndLeavesTheRest(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{DisplayName: "Acme"}); err != nil {
		t.Fatal(err)
	}
	engine := "apple"
	if err := UpdateOrg("acme", OrgPatch{SpeechProvider: &engine}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if o.SpeechProvider != "apple" {
		t.Errorf("SpeechProvider = %q", o.SpeechProvider)
	}
	if o.DisplayName != "Acme" {
		t.Errorf("DisplayName = %q; a field not in the patch must survive", o.DisplayName)
	}
}

// TestSpeechProviderIsStoredAsGivenEvenWhenUnknown: the Swift side falls
// back to Apple and says so (interaction rule 7), so Go must not refuse an
// engine id it has never heard of — Go does not know which engines exist.
func TestSpeechProviderIsStoredAsGivenEvenWhenUnknown(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	engine := "  whisper-local  "
	if err := UpdateOrg("acme", OrgPatch{SpeechProvider: &engine}); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("acme")
	if o.SpeechProvider != "whisper-local" {
		t.Errorf("SpeechProvider = %q, want trimmed whisper-local", o.SpeechProvider)
	}
}

// TestOrgJSONWithoutSpeechProviderStillReads: every org.json written before
// 2d-ii lacks the key, and omitempty keeps an unset one out of new files.
func TestOrgJSONWithoutSpeechProviderStillReads(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{DisplayName: "Acme"}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(orgFilePath(t, "acme"))
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	if _, present := raw["speechProvider"]; present {
		t.Errorf("an unset speechProvider must be omitted, got %s", b)
	}
	o, err := LoadOrgFor("acme")
	if err != nil || o.SpeechProvider != "" {
		t.Errorf("LoadOrgFor = %+v, %v", o, err)
	}
}
```

Append to `internal/wakilcore/configtree_test.go`:

```go
func TestConfigTreeCarriesSpeechProvider(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{SpeechProvider: "apple"}); err != nil {
		t.Fatal(err)
	}
	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Org.SpeechProvider != "apple" {
		t.Errorf("tree.Org.SpeechProvider = %q", tree.Org.SpeechProvider)
	}
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `go test ./internal/wakilcore -run 'SpeechProvider|ConfigTreeCarriesSpeech' -v`
Expected: FAIL — `unknown field SpeechProvider in struct literal`.

- [ ] **Step 3: Implement**

`internal/wakilcore/org.go`, inside `type Org struct` after `DefaultProvider`:

```go
	// SpeechProvider names the speech-to-text engine this organization's
	// windows listen with (2d-ii; Decision 18, Invariant 11). Empty means
	// the default, Apple. Go does not validate it against a list: which
	// engines exist is the app's knowledge, and the app falls back to
	// Apple and says so when the id is one it does not know.
	SpeechProvider string `json:"speechProvider,omitempty"`
```

In `normaliseOrg`, before its final `return o, nil`, add:

```go
	o.SpeechProvider = strings.TrimSpace(o.SpeechProvider)
```

(add `"strings"` to `org.go`'s imports if it is not already there).

`internal/wakilcore/orgupdate.go`: add the field and extend both methods:

```go
type OrgPatch struct {
	DisplayName     *string
	JiraBase        *string
	DefaultProvider *string
	SpeechProvider  *string
}

func (p OrgPatch) isEmpty() bool {
	return p.DisplayName == nil && p.JiraBase == nil && p.DefaultProvider == nil &&
		p.SpeechProvider == nil
}
```

and in `apply`, after the `DefaultProvider` block:

```go
	if p.SpeechProvider != nil {
		o.SpeechProvider = *p.SpeechProvider
	}
```

`internal/wakilcore/configtree.go`: add to `ConfigTreeOrg`:

```go
	SpeechProvider  string `json:"speechProvider"`
```

and in `LoadConfigTreeFor`'s `tree.Org = ConfigTreeOrg{...}` literal add `SpeechProvider: record.SpeechProvider,`.

`cmd/wakil-ctx/main.go`: add to `updateOrgArgs` after `DefaultProvider`:

```go
	SpeechProvider  *string `json:"speechProvider,omitempty" jsonschema:"optional speech engine id (apple); omit to leave unchanged, send \"\" to clear"`
```

pass it in the `update_org` handler (`SpeechProvider: a.SpeechProvider,`), and change the tool's Description to begin `"Change an organisation's display name, Jira site, default account or speech engine, leaving every other field…"`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore ./cmd/wakil-ctx -run 'Org|ConfigTree' -v`
Expected: PASS, including every pre-existing `TestUpdateOrg*` and `TestConfigTree*`.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/org.go internal/wakilcore/orgupdate.go internal/wakilcore/configtree.go cmd/wakil-ctx/main.go internal/wakilcore/orgupdate_test.go internal/wakilcore/configtree_test.go
git commit -m "2d-ii: speechProvider in org.json, through update_org and the config tree"
```

---

### Task 2: `speechProvider` on the Swift settings path

**Files:**
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift:87-108` (`SettingsOrg`)
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift:953-994` (`ctx_update_org` schema and forwarded keys)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `enum OrganisationField` (near line 3140): add a case
- Test: `app/Tests/WakilKitTests/OrganisationEditTests.swift`, `app/Tests/WakilKitTests/SettingsTreeTests.swift` (create if absent)

**Interfaces:**
- Produces: `SettingsOrg.speechProvider: String` (`""` when absent); `WindowModel.OrganisationField.speechProvider` (rawValue `"speechProvider"`); `ctx_update_org` forwards `speechProvider`.

- [ ] **Step 1: Write the failing tests**

Append to `OrganisationEditTests.swift`:

```swift
/// 2d-ii: the Speech row saves through the same action, one key at a time.
@Test func savingTheSpeechEngineSendsOnlyThatFieldAndTheId() async throws {
    let (registry, caller) = try await registryWithRecordingContext()

    _ = try await registry.dispatch(
        name: "ctx_update_org",
        params: .object(["id": .string("acme"), "speechProvider": .string("apple")]),
        origin: .ui, environment: "staging", confirmation: nil)

    let calls = await caller.recorded()
    guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
        Issue.record("expected one update_org call, got \(calls)"); return
    }
    #expect(Set(arguments.keys) == ["id", "speechProvider"])
    #expect(arguments["speechProvider"] == .string("apple"))
}

@Test func organisationFieldNamesTheSpeechEngine() {
    #expect(WindowModel.OrganisationField.speechProvider.rawValue == "speechProvider")
}
```

Create `app/Tests/WakilKitTests/SettingsOrgSpeechTests.swift`:

```swift
import Testing
import Foundation
@testable import WakilKit

@Test func settingsOrgDecodesSpeechProvider() throws {
    let json = #"{"id":"acme","displayName":"","jiraBase":"","defaultProvider":"","speechProvider":"apple"}"#
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
    #expect(org.speechProvider == "apple")
}

/// A tree from a `wakil-ctx` built before 2d-ii has no key at all.
@Test func settingsOrgWithoutSpeechProviderDecodesAsEmpty() throws {
    let json = #"{"id":"acme"}"#
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
    #expect(org.speechProvider == "")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'savingTheSpeechEngine|organisationFieldNamesTheSpeechEngine|settingsOrg'`
Expected: FAIL to compile — `speechProvider` is not a member.

- [ ] **Step 3: Implement**

`SettingsTree.swift`, `SettingsOrg`: add `public var speechProvider: String`; extend `init(id:displayName:jiraBase:defaultProvider:speechProvider: String = "")`; in `init(from:)` add `speechProvider = try container.decodeIfPresent(String.self, forKey: .speechProvider) ?? ""`; add `speechProvider` to `CodingKeys`.

`StandardActions.swift`, `ctx_update_org`: add `"speechProvider": .object(["type": .string("string")]),` to `properties`; change the forwarded-key loop to `for key in ["displayName", "jiraBase", "defaultProvider", "speechProvider"]`; append to the description `" or speech engine"` after `"default account"`.

`WindowModel.swift`, `OrganisationField`: add `case speechProvider`. Fix every `switch` over `OrganisationField` the compiler then reports — at least its `label` (`"Speech"`) and `identifierFragment` (the case name) — and `SettingsPane.storedValue` (`case .speechProvider: return tree.org.speechProvider`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'OrganisationEdit|settingsOrg|organisationField'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Panes/SettingsTree.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp/SettingsPane.swift app/Tests/WakilKitTests/OrganisationEditTests.swift app/Tests/WakilKitTests/SettingsOrgSpeechTests.swift
git commit -m "2d-ii: the settings path carries speechProvider"
```

---

### Task 3: The speech seam and the scripted engine

**Files:**
- Create: `app/Sources/WakilKit/Speech/SpeechProvider.swift`
- Create: `app/Sources/WakilKit/Speech/ScriptedSpeechProvider.swift`
- Test: `app/Tests/WakilKitTests/SpeechRegistryTests.swift`, `app/Tests/WakilKitTests/ScriptedSpeechProviderTests.swift`

**Interfaces:**
- Produces:
  - `public enum SpeechEvent: Sendable, Equatable { case started(device: String); case audio; case partial(settled: String, volatile: String); case final(String); case denied; case downloading(fraction: Double, totalBytes: Int64); case failed(String) }`
  - `public protocol SpeechProvider: AnyObject, Sendable { func start(locale: Locale) -> AsyncStream<SpeechEvent>; func stop() async; func cancel() async }`
  - `public struct SpeechEngine: Sendable { id: String; name: String; make: @Sendable () -> any SpeechProvider }`
  - `public struct SpeechRegistry: Sendable { static let defaultId = "apple"; init(engines: [SpeechEngine], override: SpeechEngine? = nil); engines: [SpeechEngine]; func resolve(_ stored: String) -> (engine: SpeechEngine?, note: String?); func note(for stored: String) -> String? }`
  - `public final class ScriptedSpeechProvider: SpeechProvider { struct Step: Sendable, Equatable, Decodable { after: Double; event: SpeechEvent }; init(steps: [Step]); static func load(_ path: String) throws -> [Step] }`

**Provider contract** (write it as the protocol's doc comment): `start` returns a stream that yields `.started(device:)` first once audio is flowing; `stop()` asks the engine to finish and the stream then yields exactly one `.final` and finishes; `cancel()` finishes the stream with no `.final`. `.audio` is a presence signal — sound above the engine's floor — never a level.

- [ ] **Step 1: Write the failing tests**

`SpeechRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import WakilKit

private func engine(_ id: String, _ name: String) -> SpeechEngine {
    SpeechEngine(id: id, name: name, make: { ScriptedSpeechProvider(steps: []) })
}

@Test func aMissingIdResolvesToApple() {
    let registry = SpeechRegistry(engines: [engine("apple", "Apple")])
    let (found, note) = registry.resolve("")
    #expect(found?.id == "apple")
    #expect(note == nil)
}

@Test func aKnownIdResolvesToItself() {
    let registry = SpeechRegistry(engines: [engine("apple", "Apple"), engine("whisper", "Whisper")])
    #expect(registry.resolve("whisper").engine?.id == "whisper")
}

/// Interaction rule 7: override or ignore, don't refuse — and say which.
@Test func anUnknownIdFallsBackToAppleAndSaysSo() {
    let registry = SpeechRegistry(engines: [engine("apple", "Apple")])
    let (found, note) = registry.resolve("deepgram")
    #expect(found?.id == "apple")
    #expect(note == "unknown engine 'deepgram', using Apple")
}

@Test func noEngineAtAllIsSaidRatherThanCrashing() {
    let registry = SpeechRegistry(engines: [])
    let (found, note) = registry.resolve("")
    #expect(found == nil)
    #expect(note == "no speech engine is available on this Mac")
}

/// The e2e override wins over any stored id, but the Speech row's note is
/// computed without it, so the pane still describes the organisation.
@Test func theOverrideWinsForListeningButNotForTheSettingsNote() {
    let registry = SpeechRegistry(engines: [engine("apple", "Apple")], override: engine("scripted", "Scripted"))
    #expect(registry.resolve("deepgram").engine?.id == "scripted")
    #expect(registry.note(for: "deepgram") == "unknown engine 'deepgram', using Apple")
}
```

`ScriptedSpeechProviderTests.swift`:

```swift
import Testing
import Foundation
@testable import WakilKit

private func collect(_ stream: AsyncStream<SpeechEvent>) async -> [SpeechEvent] {
    var out: [SpeechEvent] = []
    for await event in stream { out.append(event) }
    return out
}

@Test func playsItsStepsThenAFinalOfWhatWasHeardOnStop() async {
    let provider = ScriptedSpeechProvider(steps: [
        .init(after: 0, event: .started(device: "Test Mic")),
        .init(after: 0, event: .partial(settled: "open the", volatile: "book")),
    ])
    let stream = provider.start(locale: Locale(identifier: "en-US"))
    try? await Task.sleep(for: .milliseconds(50))
    await provider.stop()
    let events = await collect(stream)
    #expect(events == [
        .started(device: "Test Mic"),
        .partial(settled: "open the", volatile: "book"),
        .final("open the book"),
    ])
}

@Test func cancelFinishesWithNoFinal() async {
    let provider = ScriptedSpeechProvider(steps: [.init(after: 0, event: .partial(settled: "x", volatile: ""))])
    let stream = provider.start(locale: Locale(identifier: "en-US"))
    try? await Task.sleep(for: .milliseconds(50))
    await provider.cancel()
    let events = await collect(stream)
    #expect(!events.contains { if case .final = $0 { return true }; return false })
}

@Test func loadsAScriptFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).json")
    try Data(#"""
    [{"after":0,"kind":"started","device":"Scripted Mic"},
     {"after":0.2,"kind":"audio"},
     {"after":0.1,"kind":"partial","settled":"open the","volatile":"booking"},
     {"after":0,"kind":"downloading","fraction":0.5,"totalBytes":1000},
     {"after":0,"kind":"denied"},
     {"after":0,"kind":"failed","message":"boom"},
     {"after":0,"kind":"final","text":"open the booking"}]
    """#.utf8).write(to: url)
    let steps = try ScriptedSpeechProvider.load(url.path)
    #expect(steps.map(\.event) == [
        .started(device: "Scripted Mic"), .audio,
        .partial(settled: "open the", volatile: "booking"),
        .downloading(fraction: 0.5, totalBytes: 1000), .denied, .failed("boom"),
        .final("open the booking"),
    ])
    #expect(steps[1].after == 0.2)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'SpeechRegistry|ScriptedSpeechProvider|aMissingId|aKnownId|anUnknownId|noEngineAtAll|theOverrideWins|playsItsSteps|cancelFinishes|loadsAScript'`
Expected: FAIL to compile — `SpeechRegistry` not found.

- [ ] **Step 3: Implement `SpeechProvider.swift`**

```swift
import Foundation

/// What a speech engine reports while it listens (2d-ii). Decision 18's
/// "audio in, text out", plus the three things the composer bar must be
/// able to say in words: nothing heard, permission refused, model loading.
///
/// **`.audio` is presence, never a level.** design-language §12 forbids a
/// meter; the only thing the app does with sound is notice its absence.
public enum SpeechEvent: Sendable, Equatable {
    /// Audio is flowing from this input device. Always the first event.
    case started(device: String)
    /// Sound above the engine's floor arrived. Rate-limited by the engine.
    case audio
    /// The engine's current reading: words it will not revise, then its
    /// unsettled tail.
    case partial(settled: String, volatile: String)
    /// The whole utterance, after `stop()`. Exactly once, then the stream ends.
    case final(String)
    /// Microphone permission is refused.
    case denied
    /// The engine's model is downloading. `totalBytes` is 0 when unknown.
    case downloading(fraction: Double, totalBytes: Int64)
    /// The engine failed. The stream ends after this.
    case failed(String)
}

/// One speech-to-text engine (Invariant 11: pluggable, per organization).
///
/// Contract: `start` returns a stream whose first event is
/// `.started(device:)`. `stop()` asks the engine to finish; the stream then
/// yields exactly one `.final` and ends. `cancel()` ends the stream with no
/// `.final`. A provider instance serves one hold; the registry makes a new
/// one each time.
public protocol SpeechProvider: AnyObject, Sendable {
    func start(locale: Locale) -> AsyncStream<SpeechEvent>
    func stop() async
    func cancel() async
}

/// A registered engine: its `org.json` id, the name the Speech row shows,
/// and how to make one.
public struct SpeechEngine: Sendable {
    public let id: String
    public let name: String
    public let make: @Sendable () -> any SpeechProvider

    public init(id: String, name: String, make: @escaping @Sendable () -> any SpeechProvider) {
        self.id = id
        self.name = name
        self.make = make
    }
}

/// Which engines exist, and which one an organization's `speechProvider`
/// names. A new engine is one conformance and one entry here.
public struct SpeechRegistry: Sendable {
    public static let defaultId = "apple"

    public let engines: [SpeechEngine]
    /// Replaces every lookup when set — the e2e harness's scripted engine,
    /// so a check never reaches a real microphone.
    public let override: SpeechEngine?

    public init(engines: [SpeechEngine], override: SpeechEngine? = nil) {
        self.engines = engines
        self.override = override
    }

    /// The engine to listen with for a stored id, and a sentence when the
    /// stored id could not be honoured.
    public func resolve(_ stored: String) -> (engine: SpeechEngine?, note: String?) {
        if let override { return (override, nil) }
        return lookup(stored)
    }

    /// The Speech row's note for a stored id, ignoring any override.
    public func note(for stored: String) -> String? { lookup(stored).note }

    private func lookup(_ stored: String) -> (engine: SpeechEngine?, note: String?) {
        let id = stored.isEmpty ? Self.defaultId : stored
        if let exact = engines.first(where: { $0.id == id }) { return (exact, nil) }
        guard let fallback = engines.first(where: { $0.id == Self.defaultId }) else {
            return (nil, "no speech engine is available on this Mac")
        }
        return (fallback, "unknown engine '\(stored)', using \(fallback.name)")
    }
}
```

- [ ] **Step 4: Implement `ScriptedSpeechProvider.swift`**

```swift
import Foundation

/// A speech engine that plays a fixed script — the unit tests' fake and the
/// e2e harness's microphone (`WAKIL_SPEECH_SCRIPT`). It keeps the provider
/// contract: on `stop()` it yields a `.final` of what its partials said,
/// unless the script already contained one.
public final class ScriptedSpeechProvider: SpeechProvider, @unchecked Sendable {
    public struct Step: Sendable, Equatable, Decodable {
        public let after: Double
        public let event: SpeechEvent

        public init(after: Double, event: SpeechEvent) {
            self.after = after
            self.event = event
        }

        private enum Keys: String, CodingKey {
            case after, kind, device, settled, volatile, text, fraction, totalBytes, message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            after = try c.decodeIfPresent(Double.self, forKey: .after) ?? 0
            switch try c.decode(String.self, forKey: .kind) {
            case "started": event = .started(device: try c.decode(String.self, forKey: .device))
            case "audio": event = .audio
            case "partial":
                event = .partial(
                    settled: try c.decodeIfPresent(String.self, forKey: .settled) ?? "",
                    volatile: try c.decodeIfPresent(String.self, forKey: .volatile) ?? "")
            case "final": event = .final(try c.decode(String.self, forKey: .text))
            case "denied": event = .denied
            case "downloading":
                event = .downloading(
                    fraction: try c.decode(Double.self, forKey: .fraction),
                    totalBytes: try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0)
            case "failed": event = .failed(try c.decode(String.self, forKey: .message))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: c, debugDescription: "unknown speech step kind '\(other)'")
            }
        }
    }

    public static func load(_ path: String) throws -> [Step] {
        try JSONDecoder().decode([Step].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private let steps: [Step]
    private let lock = NSLock()
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var player: Task<Void, Never>?
    private var heard = ""
    private var sentFinal = false

    public init(steps: [Step]) { self.steps = steps }

    public func start(locale: Locale) -> AsyncStream<SpeechEvent> {
        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream()
        lock.withLock { self.continuation = continuation }
        let steps = self.steps
        player = Task { [weak self] in
            for step in steps {
                if step.after > 0 { try? await Task.sleep(for: .seconds(step.after)) }
                if Task.isCancelled { return }
                self?.emit(step.event)
            }
        }
        return stream
    }

    public func stop() async {
        player?.cancel()
        let (continuation, heard, sentFinal) = lock.withLock { (self.continuation, self.heard, self.sentFinal) }
        if !sentFinal { continuation?.yield(.final(heard)) }
        continuation?.finish()
    }

    public func cancel() async {
        player?.cancel()
        lock.withLock { continuation }?.finish()
    }

    private func emit(_ event: SpeechEvent) {
        let continuation: AsyncStream<SpeechEvent>.Continuation? = lock.withLock {
            switch event {
            case .partial(let settled, let volatile):
                heard = [settled, volatile].filter { !$0.isEmpty }.joined(separator: " ")
            case .final: sentFinal = true
            default: break
            }
            return self.continuation
        }
        continuation?.yield(event)
        if case .final = event { continuation?.finish() }
        if case .failed = event { continuation?.finish() }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Speech app/Tests/WakilKitTests/SpeechRegistryTests.swift app/Tests/WakilKitTests/ScriptedSpeechProviderTests.swift
git commit -m "2d-ii: the speech seam — SpeechProvider, SpeechRegistry, the scripted engine"
```

---

### Task 4: `ListeningMachine`

**Files:**
- Create: `app/Sources/WakilKit/Speech/ListeningMachine.swift`
- Test: `app/Tests/WakilKitTests/ListeningMachineTests.swift`

**Interfaces:**
- Consumes: `SpeechEvent` (Task 3).
- Produces:
  - `public struct ListeningMachine: Sendable, Equatable` with `static let armDelay = 0.18, silenceAfter = 1.5, finishTimeout = 2.0`
  - `enum Phase { case idle, arming(since: Double), listening(since: Double), finishing(since: Double) }`
  - `enum Notice { case heardNothing(device: String), denied, downloading(fraction: Double, totalBytes: Int64) }`
  - `enum Effect { case startEngine, stopEngine, cancelEngine, land(String), failed(String) }`
  - read-only `phase`, `settled`, `volatile`, `notice`, `isListening` (listening or finishing), `isCapturing` (listening only), `heard`
  - `mutating` `optionDown(at:)`, `optionUp(at:)`, `otherInput()`, `escape()`, `resigned(at:)`, `tick(at:)`, `receive(_:)` — each returns `[Effect]`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

private func armed(at t: Double = 0) -> ListeningMachine {
    var m = ListeningMachine()
    _ = m.optionDown(at: t)
    _ = m.tick(at: t + ListeningMachine.armDelay)
    return m
}

@Test func holdingOptionAloneArmsAfter180ms() {
    var m = ListeningMachine()
    #expect(m.optionDown(at: 0) == [])
    #expect(m.tick(at: 0.17) == [])
    #expect(m.tick(at: 0.18) == [.startEngine])
    #expect(m.isCapturing)
}

@Test func releasingBefore180msDoesNothing() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0)
    #expect(m.optionUp(at: 0.1) == [])
    #expect(m.tick(at: 1) == [])
    #expect(m.phase == .idle)
}

/// ⌥ chorded with a key or a click is an ordinary modifier (rule 7).
@Test func anotherKeyOrClickWhileArmingCancels() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0)
    _ = m.otherInput()
    #expect(m.tick(at: 0.5) == [])
    #expect(m.phase == .idle)
}

@Test func releaseStopsTheEngineAndTheFinalLands() {
    var m = armed()
    _ = m.receive(.partial(settled: "open the", volatile: "book"))
    #expect(m.optionUp(at: 1) == [.stopEngine])
    #expect(m.receive(.final("open the booking")) == [.land("open the booking")])
    #expect(m.phase == .idle)
}

@Test func anEmptyFinalLandsNothing() {
    var m = armed()
    _ = m.optionUp(at: 1)
    #expect(m.receive(.final("")) == [])
}

@Test func escapeWhileHoldingDiscards() {
    var m = armed()
    _ = m.receive(.partial(settled: "drop the table", volatile: ""))
    #expect(m.escape() == [.cancelEngine])
    #expect(m.phase == .idle)
    #expect(m.heard == "")
}

@Test func escapeWhenIdleIsNotConsumed() {
    var m = ListeningMachine()
    #expect(m.escape() == [])
}

/// Losing focus while holding is a release (rule 2: input is never lost).
@Test func resigningActiveIsARelease() {
    var m = armed()
    #expect(m.resigned(at: 1) == [.stopEngine])
}

@Test func noAudioFor1_5sNamesTheDevice() {
    var m = armed(at: 0)
    _ = m.receive(.started(device: "MacBook Pro Microphone"))
    _ = m.tick(at: 1.6)
    #expect(m.notice == nil, "1.42 s since listening began is under the threshold")
    _ = m.tick(at: 0.18 + 1.5)
    #expect(m.notice == .heardNothing(device: "MacBook Pro Microphone"))
}

@Test func soundClearsTheSilenceNotice() {
    var m = armed(at: 0)
    _ = m.tick(at: 5)
    #expect(m.notice != nil)
    _ = m.receive(.audio)
    #expect(m.notice == nil)
}

/// A pause mid-sentence is not a dead microphone.
@Test func aPauseAfterSoundNeverRaisesTheNotice() {
    var m = armed(at: 0)
    _ = m.receive(.audio)
    _ = m.tick(at: 10)
    #expect(m.notice == nil)
}

@Test func deniedAndDownloadingAreNotices() {
    var m = armed()
    _ = m.receive(.downloading(fraction: 0.4, totalBytes: 120_000_000))
    #expect(m.notice == .downloading(fraction: 0.4, totalBytes: 120_000_000))
    _ = m.receive(.denied)
    #expect(m.notice == .denied)
}

/// Review focus 3: a provider that never sends `.final`.
@Test func finishingTimesOutAndLandsWhatWasHeard() {
    var m = armed()
    _ = m.receive(.partial(settled: "show tables", volatile: ""))
    _ = m.optionUp(at: 1)
    #expect(m.tick(at: 2.9) == [])
    #expect(m.tick(at: 3.0) == [.cancelEngine, .land("show tables")])
    #expect(m.phase == .idle)
}

/// Review focus 2: released before any engine started.
@Test func finishingWithNothingHeardTimesOutToIdle() {
    var m = armed()
    _ = m.optionUp(at: 1)
    #expect(m.tick(at: 3.0) == [.cancelEngine])
    #expect(m.phase == .idle)
}

/// Spec: engine fails mid-utterance — words so far land, the error is reported.
@Test func aFailureLandsWhatWasHeardAndReportsIt() {
    var m = armed()
    _ = m.receive(.partial(settled: "open", volatile: "the"))
    #expect(m.receive(.failed("engine stopped")) == [.land("open the"), .failed("engine stopped")])
    #expect(m.phase == .idle)
}

@Test func eventsWhileIdleAreIgnored() {
    var m = ListeningMachine()
    #expect(m.receive(.partial(settled: "stale", volatile: "")) == [])
    #expect(m.heard == "")
}

@Test func heardJoinsSettledAndVolatile() {
    var m = armed()
    _ = m.receive(.partial(settled: " open the ", volatile: "book "))
    #expect(m.heard == "open the book")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter ListeningMachineTests`
Expected: FAIL to compile — `ListeningMachine` not found. (Swift Testing names free functions by file; if the filter matches nothing, use `--filter 'holdingOptionAlone|releasingBefore|anotherKeyOrClick|releaseStops|anEmptyFinal|escape|resigning|noAudioFor|soundClears|aPauseAfter|deniedAnd|finishing|aFailureLands|eventsWhileIdle|heardJoins'`.)

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Push-to-talk (2d-ii), as a pure state machine: every input carries the
/// time it happened, and every transition returns the effects
/// `ComposerModel` must run. No clock, no engine, no AppKit — so every
/// rule below is a unit test.
public struct ListeningMachine: Sendable, Equatable {
    /// ⌥ must be held alone this long before listening starts, so ⌥ used as
    /// a modifier never opens the microphone.
    public static let armDelay: Double = 0.18
    /// No sound at all for this long after listening starts names the
    /// input device (design-language §12's silence case, in words).
    public static let silenceAfter: Double = 1.5
    /// How long after release to wait for the engine's `.final` before
    /// landing what was already heard.
    public static let finishTimeout: Double = 2.0

    public enum Phase: Sendable, Equatable {
        case idle
        case arming(since: Double)
        case listening(since: Double)
        case finishing(since: Double)
    }

    public enum Notice: Sendable, Equatable {
        case heardNothing(device: String)
        case denied
        case downloading(fraction: Double, totalBytes: Int64)
    }

    public enum Effect: Sendable, Equatable {
        case startEngine
        case stopEngine
        case cancelEngine
        case land(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var settled = ""
    public private(set) var volatile = ""
    public private(set) var notice: Notice?
    private var device = "the microphone"
    private var heardSound = false

    public init() {}

    /// Listening or finishing — what the room's state follows.
    public var isListening: Bool {
        switch phase {
        case .listening, .finishing: return true
        case .idle, .arming: return false
        }
    }

    /// Listening and still holding — the only phase an engine may start in.
    public var isCapturing: Bool {
        if case .listening = phase { return true }
        return false
    }

    public var heard: String {
        [settled, volatile]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public mutating func optionDown(at now: Double) -> [Effect] {
        guard phase == .idle else { return [] }
        phase = .arming(since: now)
        return []
    }

    public mutating func optionUp(at now: Double) -> [Effect] {
        switch phase {
        case .arming:
            phase = .idle
            return []
        case .listening:
            phase = .finishing(since: now)
            return [.stopEngine]
        case .idle, .finishing:
            return []
        }
    }

    public mutating func otherInput() -> [Effect] {
        if case .arming = phase { phase = .idle }
        return []
    }

    public mutating func escape() -> [Effect] {
        switch phase {
        case .listening, .finishing:
            reset()
            return [.cancelEngine]
        case .arming:
            phase = .idle
            return []
        case .idle:
            return []
        }
    }

    public mutating func resigned(at now: Double) -> [Effect] { optionUp(at: now) }

    public mutating func tick(at now: Double) -> [Effect] {
        switch phase {
        case .arming(let since) where now - since >= Self.armDelay:
            reset()
            phase = .listening(since: now)
            return [.startEngine]
        case .listening(let since):
            if !heardSound, notice == nil, now - since >= Self.silenceAfter {
                notice = .heardNothing(device: device)
            }
            return []
        case .finishing(let since) where now - since >= Self.finishTimeout:
            let text = heard
            reset()
            return text.isEmpty ? [.cancelEngine] : [.cancelEngine, .land(text)]
        default:
            return []
        }
    }

    public mutating func receive(_ event: SpeechEvent) -> [Effect] {
        guard isListening else { return [] }
        switch event {
        case .started(let name):
            device = name
            return []
        case .audio:
            heardSound = true
            if case .heardNothing = notice { notice = nil }
            return []
        case .partial(let newSettled, let newVolatile):
            settled = newSettled
            volatile = newVolatile
            heardSound = true
            if case .heardNothing = notice { notice = nil }
            if case .downloading = notice { notice = nil }
            return []
        case .downloading(let fraction, let total):
            notice = .downloading(fraction: fraction, totalBytes: total)
            return []
        case .denied:
            notice = .denied
            return []
        case .final(let text):
            guard case .finishing = phase else {
                settled = text
                volatile = ""
                return []
            }
            reset()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.land(trimmed)]
        case .failed(let message):
            let text = heard
            reset()
            return text.isEmpty ? [.failed(message)] : [.land(text), .failed(message)]
        }
    }

    private mutating func reset() {
        phase = .idle
        settled = ""
        volatile = ""
        notice = nil
        heardSound = false
        device = "the microphone"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command. Expected: PASS (17 tests).

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Speech/ListeningMachine.swift app/Tests/WakilKitTests/ListeningMachineTests.swift
git commit -m "2d-ii: ListeningMachine — the 180 ms arm, release, Esc, silence and the finish timeout"
```

---

### Task 5: `ComposerText` — the landing rule and the bar's words

**Files:**
- Create: `app/Sources/WakilKit/App/ComposerText.swift`
- Test: `app/Tests/WakilKitTests/ComposerTextTests.swift`

**Interfaces:**
- Consumes: `ListeningMachine` (Task 4).
- Produces:
  - `public enum ComposerText { static func insert(_ spoken: String, into draft: String, at caret: Int) -> (draft: String, caret: Int) }` — `caret` is a UTF-16 offset.
  - `public enum ComposerBarContent: Sendable, Equatable { case draft(hint: String); case hearing(settled: String, volatile: String, hint: String); case notice(String, hint: String) }` with `static func make(machine: ListeningMachine, landedUnsent: Bool) -> ComposerBarContent` and `static let keysHint, landedHint, releaseHint: String`, `static func sentence(for: ListeningMachine.Notice) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

@Test func landingInAnEmptyDraftIsJustTheWords() {
    let r = ComposerText.insert("show tables", into: "", at: 0)
    #expect(r.draft == "show tables")
    #expect(r.caret == 11)
}

@Test func landingAtTheEndAddsASpace() {
    let r = ComposerText.insert("in staging", into: "show tables", at: 11)
    #expect(r.draft == "show tables in staging")
    #expect(r.caret == 22)
}

@Test func landingMidDraftPadsBothSidesAndReplacesNothing() {
    let r = ComposerText.insert("all", into: "show tables", at: 5)
    #expect(r.draft == "show all tables")
    #expect(r.caret == 8)
}

@Test func existingWhitespaceIsNotDoubled() {
    let r = ComposerText.insert("all", into: "show  tables", at: 5)
    #expect(r.draft == "show all tables" || r.draft == "show all  tables")
    #expect(!r.draft.contains("   "))
}

/// Review focus 5.
@Test func aCaretPastTheEndIsClamped() {
    let r = ComposerText.insert("x", into: "ab", at: 99)
    #expect(r.draft == "ab x")
}

@Test func theCaretCountsUTF16LikeNSTextView() {
    // "👍" is two UTF-16 units; the caret after it is 2.
    let r = ComposerText.insert("ok", into: "👍", at: 2)
    #expect(r.draft == "👍 ok")
    #expect(r.caret == 5)
}

@Test func theBarShowsTheKeysWhenIdle() {
    #expect(ComposerBarContent.make(machine: ListeningMachine(), landedUnsent: false)
            == .draft(hint: "Hold ⌥ to speak · ⌘P open · ⌘K actions"))
}

@Test func theBarSaysHeardAfterALanding() {
    #expect(ComposerBarContent.make(machine: ListeningMachine(), landedUnsent: true)
            == .draft(hint: "heard · Return sends · edit first"))
}

@Test func theBarShowsTheTranscriptWhileListening() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0); _ = m.tick(at: 0.2)
    _ = m.receive(.partial(settled: "open the", volatile: "book"))
    #expect(ComposerBarContent.make(machine: m, landedUnsent: false)
            == .hearing(settled: "open the", volatile: "book", hint: "release to put it in the line"))
}

@Test func theBarSaysTheNoticesInWords() {
    #expect(ComposerBarContent.sentence(for: .heardNothing(device: "MacBook Pro Microphone"))
            == "Hearing nothing from MacBook Pro Microphone")
    #expect(ComposerBarContent.sentence(for: .denied)
            == "Wakil can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone")
    #expect(ComposerBarContent.sentence(for: .downloading(fraction: 0.42, totalBytes: 0))
            == "Downloading the English speech model — 42% · Esc cancels")
    #expect(ComposerBarContent.sentence(for: .downloading(fraction: 0.5, totalBytes: 120_000_000))
            .hasPrefix("Downloading the English speech model — 50% of "))
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'landing|existingWhitespace|aCaretPast|theCaretCounts|theBar'`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Where spoken words go when ⌥ is released: into the draft at the caret,
/// unsent, with a space either side where the neighbours are not already
/// whitespace, and nothing replaced (interaction rule 7).
public enum ComposerText {
    /// `caret` is a UTF-16 offset — what `NSTextView.selectedRange` reports.
    public static func insert(_ spoken: String, into draft: String, at caret: Int) -> (draft: String, caret: Int) {
        let text = draft as NSString
        let at = max(0, min(caret, text.length))
        let before = text.substring(to: at)
        let after = text.substring(from: at)
        let padLeft = !before.isEmpty && !(before.last?.isWhitespace ?? true)
        let padRight = !after.isEmpty && !(after.first?.isWhitespace ?? true)
        let inserted = (padLeft ? " " : "") + spoken + (padRight ? " " : "")
        let lead = (padLeft ? " " : "") + spoken
        let caretAfter = (before as NSString).length + (lead as NSString).length
        return (before + inserted + after, caretAfter)
    }
}

/// What the composer bar draws (prototype variant A).
public enum ComposerBarContent: Sendable, Equatable {
    case draft(hint: String)
    case hearing(settled: String, volatile: String, hint: String)
    case notice(String, hint: String)

    public static let keysHint = "Hold ⌥ to speak · ⌘P open · ⌘K actions"
    public static let landedHint = "heard · Return sends · edit first"
    public static let releaseHint = "release to put it in the line"

    public static func make(machine: ListeningMachine, landedUnsent: Bool) -> ComposerBarContent {
        guard machine.isListening else {
            return .draft(hint: landedUnsent ? landedHint : keysHint)
        }
        if let notice = machine.notice { return .notice(sentence(for: notice), hint: releaseHint) }
        return .hearing(settled: machine.settled, volatile: machine.volatile, hint: releaseHint)
    }

    public static func sentence(for notice: ListeningMachine.Notice) -> String {
        switch notice {
        case .heardNothing(let device):
            return "Hearing nothing from \(device)"
        case .denied:
            return "Wakil can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone"
        case .downloading(let fraction, let total):
            let percent = Int((fraction * 100).rounded())
            guard total > 0 else { return "Downloading the English speech model — \(percent)% · Esc cancels" }
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "Downloading the English speech model — \(percent)% of \(size) · Esc cancels"
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass** — the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/ComposerText.swift app/Tests/WakilKitTests/ComposerTextTests.swift
git commit -m "2d-ii: the landing rule and the composer bar's words"
```

---

### Task 6: `WindowModel` — listening, the `you` row, the voice journal line, the engine id

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` at these spots only:
  - after `public private(set) var turnInFlight = false` (~line 962): add `isListening`; replace `coreState`
  - `public func send(_ text: String) async` (~line 5437): new signature, `you` row and journal line next to `turnInFlight = true` (~line 5574)
  - new methods `setListening(_:)`, `appendSpeechFailure(_:)`, `speechEngineId()` beside `textWithIdentifierNote` (~line 7182)
- Modify: `app/Sources/WakilKit/Registry/ActionRegistry.swift` beside `journalIdentifierEvent` (~line 381): add `journalVoiceTurn(environment:)`
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift`: classify `isListening`
- Modify: `app/Sources/WakilKit/Visual/CoreState.swift`: doc comment (listening is now set)
- Test: `app/Tests/WakilKitTests/WindowModelVoiceTests.swift`

**Interfaces:**
- Consumes: `SettingsTree`, `SettingsOrg.speechProvider` (Task 2).
- Produces:
  - `public private(set) var isListening: Bool`; `public func setListening(_ on: Bool)`
  - `public var coreState: CoreState` — `.listening` while `isListening`, else `forTurn(inFlight:)`
  - `public enum TurnSource: String, Sendable { case typed, voice }` nested in `WindowModel`
  - `public func send(_ text: String, via source: TurnSource = .typed) async`
  - `public func appendSpeechFailure(_ message: String)` — a red thread row labelled `speech`
  - `public func speechEngineId() async -> String` — the active org's `speechProvider`, `""` when unset
  - `ActionRegistry.journalVoiceTurn(environment: String) throws`

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/WakilKitTests/WindowModelVoiceTests.swift`:

```swift
import Testing
import Foundation
@testable import WakilKit

/// A harness whose `send` always succeeds, so `WindowModel.send` reaches
/// the line that marks the turn as started.
private final class AcceptingHarness: AgentHarness, @unchecked Sendable {
    private let stream: AsyncStream<HarnessEvent>
    private let continuation: AsyncStream<HarnessEvent>.Continuation
    private(set) var sent: [String] = []
    init() { (stream, continuation) = AsyncStream<HarnessEvent>.makeStream() }
    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {}
    func send(_ text: String) async throws { sent.append(text) }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}

@MainActor
@Test func listeningDrivesTheCoreState() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    #expect(model.coreState == .idle)
    model.setListening(true)
    #expect(model.coreState == .listening)
    model.setListening(false)
    #expect(model.coreState == .idle)
}

@MainActor
@Test func aSentTurnAppearsAsAYouRow() async {
    let harness = AcceptingHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("show tables")
    #expect(model.thoughts.contains { $0.label == "you" && $0.detail == "show tables" })
}

@MainActor
@Test func aVoiceTurnIsJournalledAsVoice() async throws {
    let harness = AcceptingHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("show tables", via: .voice)
    let entries = try await model.registryForTesting.journalEntries()
    let entry = try #require(entries.last { $0.action == "voice_turn" })
    #expect(entry.params == .object(["via": .string("voice")]))
}

@MainActor
@Test func aTypedTurnWritesNoVoiceLine() async throws {
    let harness = AcceptingHarness()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
    await model.send("show tables")
    let entries = try await model.registryForTesting.journalEntries()
    #expect(!entries.contains { $0.action == "voice_turn" })
}

@MainActor
@Test func aSpeechFailureIsAWholeRedRow() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    let message = String(repeating: "the engine stopped because ", count: 10)
    model.appendSpeechFailure(message)
    #expect(model.thoughts.last == ThoughtRow(id: model.thoughts.last!.id, label: "speech", detail: message, isError: true))
}

/// Review focus 4: the engine id is the CURRENT organisation's.
@MainActor
@Test func speechEngineIdIsReReadAfterTheOrgChanges() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    model.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "alpha", speechProvider: "apple")))
    #expect(await model.speechEngineId() == "apple")
    model.setSettingsForTesting(nil)   // what invalidateForOrgChange does
    model.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "beta", speechProvider: "whisper")))
    #expect(await model.speechEngineId() == "whisper")
}
```

`registryForTesting` and `ActionRegistry.journalEntries()` already exist (2d-i's `WindowIdentifierTests` reads the journal the same way). Add in Step 3, beside `registryForTesting` (~line 2184):

```swift
    /// TEST-ONLY: puts a settings tree in place, or clears it as
    /// `invalidateForOrgChange` does.
    func setSettingsForTesting(_ tree: SettingsTree?) { settings = tree }
```

and to `SettingsTree.swift`, if it has no such initialiser:

```swift
    public init(org: SettingsOrg, providers: [SettingsProvider] = [], projects: [SettingsProject] = []) {
        self.org = org
        self.providers = providers
        self.projects = projects
        self.misfiled = []
        self.unreadable = []
        self.providersSkipped = []
    }
```

(match the stored properties the file actually declares; the decoder at line 62 lists them).

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'listeningDrivesTheCoreState|aSentTurnAppears|aVoiceTurnIsJournalled|aTypedTurnWrites|aSpeechFailureIs|speechEngineIdIsReRead'`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

After `turnInFlight`:

```swift
    /// True while push-to-talk is listening or finishing (2d-ii). Set only
    /// by `ComposerModel`. Org-independent: it describes the operator's
    /// hand on ⌥, not either organisation's state.
    public private(set) var isListening = false
    /// Which of §4's four states the Core draws. Listening wins over a turn
    /// in flight: the operator speaking the next turn is what the room
    /// should show.
    public var coreState: CoreState {
        isListening ? .listening : CoreState.forTurn(inFlight: turnInFlight)
    }

    public func setListening(_ on: Bool) {
        if isListening != on { isListening = on }
    }

    /// Where a turn's text came from, for the journal.
    public enum TurnSource: String, Sendable { case typed, voice }
```

(delete the old one-line `coreState`).

Change `public func send(_ text: String) async` to `public func send(_ text: String, via source: TurnSource = .typed) async`. Immediately after `turnInFlight = true` and before `try await harness.send(...)`, insert:

```swift
            // 2d-ii: the operator's own turn is a row, so what was actually
            // sent — a misheard sentence included — stays on screen.
            thoughts.append(ThoughtRow(id: nextThoughtId, label: "you", detail: text, isError: false))
            nextThoughtId += 1
            if source == .voice {
                try? await registry.journalVoiceTurn(environment: environment)
            }
```

Beside `textWithIdentifierNote`:

```swift
    /// 2d-ii: a speech engine's failure, whole, as a red thread row
    /// (interaction rule 8).
    public func appendSpeechFailure(_ message: String) {
        thoughts.append(ThoughtRow(id: nextThoughtId, label: "speech", detail: message, isError: true))
        nextThoughtId += 1
    }

    /// The active organisation's speech engine id, `""` when unset. Reads
    /// the cached settings tree, and fetches only the tree — never the
    /// account table `refreshSettings` also reads — when there is none,
    /// because this runs on every hold of ⌥.
    public func speechEngineId() async -> String {
        if let settings { return settings.org.speechProvider }
        guard let result = try? await registry.dispatch(
            name: "ctx_config_tree", params: .object([:]), origin: .ui,
            environment: environment, confirmation: nil),
              let tree = decodeSettingsTree(fromResult: result) else { return "" }
        settings = tree
        return tree.org.speechProvider
    }
```

`ActionRegistry.swift`, beside `journalIdentifierEvent`:

```swift
    /// 2d-ii: a turn whose text landed from speech. Carries no transcript —
    /// the turn itself is the agent's record; this line says only how it
    /// was entered.
    public func journalVoiceTurn(environment: String) throws {
        try appendJournalEntry(
            action: "voice_turn", params: .object(["via": .string("voice")]), origin: .ui,
            environment: environment, outcome: "ok", secretParams: [])
    }
```

`InvalidationContractTests.swift`: add `"isListening",` to the `orgIndependent` list with the comment `// 2d-ii: the operator's hand on ⌥, not either organisation's state.`

`CoreState.swift`: replace the paragraph beginning `**All four are rendered; two are ever set.**` with: `**All four are rendered; three are set.** Listening is set by push-to-talk (2d-ii) through `WindowModel.isListening`. Speaking stays unset: nothing delivers text-to-speech (open question 17).`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowModelVoice|listeningDrives|aSentTurn|aVoiceTurn|aTypedTurn|aSpeechFailure|speechEngineId|everyWindowModelPropertyIsClassified|CoreState'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/Registry/ActionRegistry.swift app/Sources/WakilKit/Visual/CoreState.swift app/Sources/WakilKit/Panes/SettingsTree.swift app/Tests/WakilKitTests/WindowModelVoiceTests.swift app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "2d-ii: the window listens — coreState, the you row, voice_turn, the engine id"
```

---

### Task 7: `ComposerModel`

**Files:**
- Create: `app/Sources/WakilKit/App/ComposerModel.swift`
- Test: `app/Tests/WakilKitTests/ComposerModelTests.swift`

**Interfaces:**
- Consumes: `ListeningMachine` (4), `ComposerText`, `ComposerBarContent` (5), `SpeechRegistry`, `SpeechProvider` (3), `WindowModel.setListening/send(_:via:)/appendSpeechFailure/speechEngineId` (6).
- Produces: `@MainActor @Observable public final class ComposerModel` with
  - `init(window: WindowModel, speech: SpeechRegistry, now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime })`
  - `var draft: String`, `var caret: Int` (UTF-16), `private(set) var machine`, `private(set) var landedUnsent`, `private(set) var focusToken: Int` (incremented on every landing — the view focuses the field when it changes, rule 3)
  - `var bar: ComposerBarContent`
  - `func optionDown()`, `func optionUp()`, `func otherInput()`, `func escape() -> Bool` (true when Esc was consumed), `func resigned()`, `func tick()`, `func edited(draft: String, caret: Int)`, `func submit() async`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import WakilKit

@MainActor
private final class Clock {
    var t: Double = 0
}

@MainActor
private func model(steps: [ScriptedSpeechProvider.Step], clock: Clock) -> (ComposerModel, WindowModel) {
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot)
    window.setSettingsForTesting(SettingsTree(org: SettingsOrg(id: "test-org")))
    let registry = SpeechRegistry(engines: [
        SpeechEngine(id: "apple", name: "Apple", make: { ScriptedSpeechProvider(steps: steps) }),
    ])
    return (ComposerModel(window: window, speech: registry, now: { clock.t }), window)
}

/// Lets the model's start/pump tasks run.
private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }

@MainActor
@Test func holdThenReleaseLandsTheWordsUnsent() async {
    let clock = Clock()
    let (composer, window) = model(steps: [
        .init(after: 0, event: .started(device: "Test Mic")),
        .init(after: 0, event: .partial(settled: "show", volatile: "tables")),
    ], clock: clock)
    composer.optionDown()
    clock.t = 0.2; composer.tick()
    #expect(window.coreState == .listening)
    await settle()
    #expect(composer.bar == .hearing(settled: "show", volatile: "tables", hint: ComposerBarContent.releaseHint))
    clock.t = 1; composer.optionUp()
    await settle()
    #expect(composer.draft == "show tables")
    #expect(composer.landedUnsent)
    #expect(composer.focusToken == 1)
    #expect(window.coreState == .idle)
    #expect(!window.thoughts.contains { $0.label == "you" }, "nothing is sent until Return")
}

@MainActor
@Test func speechLandsAtTheCaretOfWhatWasTyped() async {
    let clock = Clock()
    let (composer, _) = model(steps: [.init(after: 0, event: .partial(settled: "all", volatile: ""))], clock: clock)
    composer.edited(draft: "show tables", caret: 5)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle()
    clock.t = 1; composer.optionUp()
    await settle()
    #expect(composer.draft == "show all tables")
}

@MainActor
@Test func escapeWhileHoldingKeepsTheTypedDraft() async {
    let clock = Clock()
    let (composer, window) = model(steps: [.init(after: 0, event: .partial(settled: "drop", volatile: ""))], clock: clock)
    composer.edited(draft: "keep me", caret: 7)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle()
    #expect(composer.escape())
    await settle()
    #expect(composer.draft == "keep me")
    #expect(window.coreState == .idle)
}

@MainActor
@Test func escapeWhenIdleIsNotConsumed() {
    let (composer, _) = model(steps: [], clock: Clock())
    #expect(!composer.escape())
}

/// Review focus 2.
@MainActor
@Test func releaseBeforeTheEngineStartsNeverStartsIt() async {
    let clock = Clock()
    let (composer, _) = model(steps: [.init(after: 0, event: .partial(settled: "late", volatile: ""))], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    composer.optionUp()                     // before any await: the engine lookup has not finished
    await settle()
    clock.t = 3; composer.tick()            // finish timeout
    await settle()
    #expect(composer.draft == "")
    #expect(composer.machine.phase == .idle)
}

@MainActor
@Test func aFailureLandsWhatWasHeardAndAddsARedRow() async {
    let clock = Clock()
    let (composer, window) = model(steps: [
        .init(after: 0, event: .partial(settled: "open", volatile: "the")),
        .init(after: 0.01, event: .failed("engine stopped")),
    ], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle()
    #expect(composer.draft == "open the")
    #expect(window.thoughts.last?.label == "speech")
    #expect(window.thoughts.last?.isError == true)
}

@MainActor
@Test func submitSendsAndClearsAndMarksVoice() async {
    let clock = Clock()
    let (composer, _) = model(steps: [.init(after: 0, event: .partial(settled: "show tables", volatile: ""))], clock: clock)
    composer.optionDown(); clock.t = 0.2; composer.tick()
    await settle()
    clock.t = 1; composer.optionUp()
    await settle()
    await composer.submit()
    #expect(composer.draft == "")
    #expect(!composer.landedUnsent)
}

@MainActor
@Test func submittingWhitespaceSendsNothing() async {
    let (composer, window) = model(steps: [], clock: Clock())
    composer.edited(draft: "   ", caret: 3)
    await composer.submit()
    #expect(!window.thoughts.contains { $0.label == "you" })
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'holdThenRelease|speechLandsAtTheCaret|escapeWhileHolding|escapeWhenIdleIsNotConsumed|releaseBeforeTheEngine|aFailureLandsWhatWasHeardAndAdds|submitSends|submittingWhitespace'`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// The composer bar's model (2d-ii): the draft the operator types into and
/// speech lands in, and the coordinator that runs `ListeningMachine`'s
/// effects against a speech engine. `WakilApp` forwards ⌥, other keys,
/// clicks, Esc, app deactivation and a ~20 Hz tick; everything decided is
/// decided here or in the machine.
@MainActor
@Observable
public final class ComposerModel {
    public var draft = ""
    /// UTF-16 offset, as `NSTextView` reports it.
    public var caret = 0
    public private(set) var machine = ListeningMachine()
    /// True from a landing until the draft is sent or emptied.
    public private(set) var landedUnsent = false
    /// Bumped on every landing; the bar focuses its field when it changes.
    public private(set) var focusToken = 0

    private let window: WindowModel
    private let speech: SpeechRegistry
    private let now: @MainActor () -> Double
    private var provider: (any SpeechProvider)?
    private var pump: Task<Void, Never>?
    /// Which hold an engine belongs to, so a late engine from an earlier
    /// hold is cancelled instead of adopted.
    private var hold = 0

    public init(
        window: WindowModel, speech: SpeechRegistry,
        now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.window = window
        self.speech = speech
        self.now = now
    }

    public var bar: ComposerBarContent {
        .make(machine: machine, landedUnsent: landedUnsent && !draft.isEmpty)
    }

    public func optionDown() { run(machine.optionDown(at: now())) }
    public func optionUp() { run(machine.optionUp(at: now())) }
    public func otherInput() { run(machine.otherInput()) }
    public func resigned() { run(machine.resigned(at: now())) }
    public func tick() { run(machine.tick(at: now())) }

    /// True when Esc belonged to listening and must not reach anything else.
    public func escape() -> Bool {
        let consumed = machine.phase != .idle
        run(machine.escape())
        return consumed
    }

    public func edited(draft: String, caret: Int) {
        self.draft = draft
        self.caret = caret
        if draft.isEmpty { landedUnsent = false }
    }

    public func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let source: WindowModel.TurnSource = landedUnsent ? .voice : .typed
        draft = ""
        caret = 0
        landedUnsent = false
        await window.send(text, via: source)
    }

    private func run(_ effects: [ListeningMachine.Effect]) {
        window.setListening(machine.isListening)
        for effect in effects {
            switch effect {
            case .startEngine:
                hold += 1
                start(hold: hold)
            case .stopEngine:
                let current = provider
                Task { await current?.stop() }
            case .cancelEngine:
                let current = provider
                provider = nil
                pump?.cancel()
                pump = nil
                Task { await current?.cancel() }
            case .land(let text):
                let landed = ComposerText.insert(text, into: draft, at: caret)
                draft = landed.draft
                caret = landed.caret
                landedUnsent = true
                focusToken += 1
            case .failed(let message):
                window.appendSpeechFailure(message)
            }
        }
        window.setListening(machine.isListening)
    }

    private func start(hold: Int) {
        Task { [weak self] in
            guard let self else { return }
            let stored = await self.window.speechEngineId()
            // Released, Esc'd or re-held while the lookup ran: start nothing.
            guard self.hold == hold, self.machine.isCapturing else { return }
            guard let engine = self.speech.resolve(stored).engine else {
                self.run(self.machine.receive(.failed("no speech engine is available on this Mac")))
                return
            }
            let provider = engine.make()
            self.provider = provider
            let events = provider.start(locale: Locale(identifier: "en-US"))
            self.pump = Task { [weak self] in
                for await event in events {
                    guard let self, self.hold == hold else { return }
                    self.run(self.machine.receive(event))
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass** — the Step 2 command. Expected: PASS. If `holdThenReleaseLandsTheWordsUnsent` is flaky under load, raise `settle()`'s sleep to 100 ms; do not add retries.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/ComposerModel.swift app/Tests/WakilKitTests/ComposerModelTests.swift
git commit -m "2d-ii: ComposerModel — the machine's effects against the engine and the window"
```

---

### Task 8: `ThreadDisclosure`

**Files:**
- Create: `app/Sources/WakilKit/App/ThreadDisclosure.swift`
- Test: `app/Tests/WakilKitTests/ThreadDisclosureTests.swift`

**Interfaces:**
- Consumes: `ThoughtRow`.
- Produces: `public struct ThreadDisclosure: Sendable, Equatable` with `static let visibleCount = 4, foldAfter = 1.2, restOpacity = 0.32`; `private(set) var open: Set<Int>, showAll: Bool, hovering: Bool`; `var pinned: Bool`; `var opacity: Double`; `func visible(_ rows: [ThoughtRow]) -> (rows: [ThoughtRow], earlier: Int)`; `mutating toggle(_ id: Int)`, `showEarlier()`, `pointerEntered()`, `pointerLeft(at:)`, `tick(at:mouseHeld:)`, `escape() -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

private func rows(_ n: Int) -> [ThoughtRow] {
    (0..<n).map { ThoughtRow(id: $0, label: "tool", detail: "step \($0)", isError: false) }
}

@Test func showsTheLastFourAndCountsTheRest() {
    let d = ThreadDisclosure()
    let (shown, earlier) = d.visible(rows(7))
    #expect(shown.map(\.id) == [3, 4, 5, 6])
    #expect(earlier == 3)
}

@Test func fewerThanFourShowsThemAll() {
    let (shown, earlier) = ThreadDisclosure().visible(rows(2))
    #expect(shown.count == 2)
    #expect(earlier == 0)
}

@Test func showEarlierShowsEverythingAndPins() {
    var d = ThreadDisclosure()
    d.showEarlier()
    #expect(d.visible(rows(7)).rows.count == 7)
    #expect(d.pinned)
}

@Test func restsFadedAndHoverBringsItUp() {
    var d = ThreadDisclosure()
    #expect(d.opacity == 0.32)
    d.pointerEntered()
    #expect(d.opacity == 1)
}

@Test func anOpenRowKeepsItFullAfterThePointerLeaves() {
    var d = ThreadDisclosure()
    d.pointerEntered()
    d.toggle(5)
    d.pointerLeft(at: 10)
    #expect(d.opacity == 1)
    #expect(d.open == [5])
}

@Test func foldsAndFades1_2sAfterThePointerLeaves() {
    var d = ThreadDisclosure()
    d.pointerEntered(); d.toggle(5); d.showEarlier()
    d.pointerLeft(at: 10)
    d.tick(at: 11.1, mouseHeld: false)
    #expect(d.pinned)
    d.tick(at: 11.2, mouseHeld: false)
    #expect(!d.pinned)
    #expect(d.opacity == 0.32)
}

@Test func comingBackInsideTheDebounceKeepsItOpen() {
    var d = ThreadDisclosure()
    d.pointerEntered(); d.toggle(5)
    d.pointerLeft(at: 10)
    d.pointerEntered()
    d.tick(at: 20, mouseHeld: false)
    #expect(d.open == [5])
}

/// A drag-selection in progress is not a departure.
@Test func aHeldMouseButtonPostponesTheFold() {
    var d = ThreadDisclosure()
    d.pointerEntered(); d.toggle(5)
    d.pointerLeft(at: 10)
    d.tick(at: 12, mouseHeld: true)
    #expect(d.open == [5])
    d.tick(at: 12.1, mouseHeld: false)
    #expect(d.open.isEmpty)
}

@Test func escapeFoldsAtOnceAndReportsWhetherItDidAnything() {
    var d = ThreadDisclosure()
    #expect(!d.escape())
    d.toggle(1)
    #expect(d.escape())
    #expect(!d.pinned)
}

@Test func toggleClosesAnOpenRow() {
    var d = ThreadDisclosure()
    d.toggle(3); d.toggle(3)
    #expect(d.open.isEmpty)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'showsTheLastFour|fewerThanFour|showEarlier|restsFaded|anOpenRowKeeps|foldsAndFades|comingBack|aHeldMouseButton|escapeFolds|toggleCloses'`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The thought thread's disclosure state (2d-ii): four rows, faded at rest,
/// full on hover, rows expanded on click, folded 1.2 s after the pointer
/// leaves. Pure; the view passes time in.
public struct ThreadDisclosure: Sendable, Equatable {
    public static let visibleCount = 4
    public static let foldAfter: Double = 1.2
    public static let restOpacity: Double = 0.32

    public private(set) var open: Set<Int> = []
    public private(set) var showAll = false
    public private(set) var hovering = false
    private var leftAt: Double?

    public init() {}

    public var pinned: Bool { !open.isEmpty || showAll }
    public var opacity: Double { hovering || pinned ? 1 : Self.restOpacity }

    public func visible(_ rows: [ThoughtRow]) -> (rows: [ThoughtRow], earlier: Int) {
        guard !showAll, rows.count > Self.visibleCount else { return (rows, 0) }
        return (Array(rows.suffix(Self.visibleCount)), rows.count - Self.visibleCount)
    }

    public mutating func toggle(_ id: Int) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }

    public mutating func showEarlier() { showAll = true }

    public mutating func pointerEntered() {
        hovering = true
        leftAt = nil
    }

    public mutating func pointerLeft(at now: Double) {
        hovering = false
        leftAt = now
    }

    public mutating func tick(at now: Double, mouseHeld: Bool) {
        guard let left = leftAt, !hovering else { return }
        // A drag-selection in progress is not a departure; the wait
        // resumes, unrestarted, once the button is up.
        if mouseHeld { return }
        if now - left >= Self.foldAfter { fold() }
    }

    /// True when there was something to fold.
    public mutating func escape() -> Bool {
        let had = pinned
        fold()
        return had
    }

    private mutating func fold() {
        open = []
        showAll = false
        leftAt = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass** — the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/ThreadDisclosure.swift app/Tests/WakilKitTests/ThreadDisclosureTests.swift
git commit -m "2d-ii: ThreadDisclosure — four rows, faded at rest, expand, fold after 1.2 s"
```

---

### Task 9: `BreathClock`

**Files:**
- Create: `app/Sources/WakilKit/Visual/BreathClock.swift`
- Test: `app/Tests/WakilKitTests/BreathClockTests.swift`

**Interfaces:**
- Consumes: `CoreMotion` (its memberwise init is internal to `WakilKit`, which is where this lives).
- Produces: `public struct BreathClock: Sendable` with `static let easeSeconds = 0.25`; `init()`; `mutating func advance(by dt: Double, toward target: CoreMotion, reduceMotion: Bool) -> (time: Double, motion: CoreMotion)`. The returned `time` is what `VoidUniforms.time` takes: the shader computes `phase = 2π · time / period`, so `time = cycles × period` makes the phase `2π · cycles`, continuous across a period change.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

private func phase(_ frame: (time: Double, motion: CoreMotion)) -> Double {
    frame.time / frame.motion.period
}

/// The bug this fixes: the shader's phase is time/period, so changing the
/// period mid-breath jumped the room. Cycles must carry over.
@Test func phaseIsContinuousIntoListening() {
    var clock = BreathClock()
    var frame = clock.advance(by: 0, toward: .forState(.idle), reduceMotion: false)
    for _ in 0..<60 { frame = clock.advance(by: 1.0 / 60, toward: .forState(.idle), reduceMotion: false) }
    let before = phase(frame)
    let after = phase(clock.advance(by: 1.0 / 60, toward: .forState(.listening), reduceMotion: false))
    #expect(abs(after - before) < 0.02, "phase jumped from \(before) to \(after)")
}

@Test func phaseIsContinuousBackToIdle() {
    var clock = BreathClock()
    var frame = clock.advance(by: 0.7, toward: .forState(.listening), reduceMotion: false)
    let before = phase(frame)
    frame = clock.advance(by: 1.0 / 60, toward: .forState(.idle), reduceMotion: false)
    #expect(abs(phase(frame) - before) < 0.02)
}

@Test func amplitudeEasesRatherThanSnapping() {
    var clock = BreathClock()
    for _ in 0..<120 { _ = clock.advance(by: 1.0 / 60, toward: .forState(.idle), reduceMotion: false) }
    let first = clock.advance(by: 1.0 / 60, toward: .forState(.listening), reduceMotion: false).motion
    let idle = CoreMotion.forState(.idle), listening = CoreMotion.forState(.listening)
    #expect(first.amplitudeHigh > idle.amplitudeHigh)
    #expect(first.amplitudeHigh < listening.amplitudeHigh, "one frame in, the ease is not finished")
    var settled = first
    for _ in 0..<120 { settled = clock.advance(by: 1.0 / 60, toward: listening, reduceMotion: false).motion }
    #expect(abs(settled.amplitudeHigh - listening.amplitudeHigh) < 0.001)
    #expect(abs(settled.spreadFactor - listening.spreadFactor) < 0.001)
}

@Test func theFirstFrameTakesTheTargetAsIs() {
    var clock = BreathClock()
    let frame = clock.advance(by: 0.15, toward: .forState(.listening), reduceMotion: false)
    #expect(frame.motion == .forState(.listening))
}

@Test func reduceMotionHoldsAmplitudeAtTheMeanAndStopsDrift() {
    var clock = BreathClock()
    var frame = clock.advance(by: 0, toward: .forState(.thinking), reduceMotion: true)
    for _ in 0..<120 { frame = clock.advance(by: 1.0 / 60, toward: .forState(.thinking), reduceMotion: true) }
    let thinking = CoreMotion.forState(.thinking)
    let mean = (thinking.amplitudeLow + thinking.amplitudeHigh) / 2
    #expect(abs(frame.motion.amplitudeLow - mean) < 0.001)
    #expect(abs(frame.motion.amplitudeHigh - mean) < 0.001)
    #expect(frame.motion.driftAmplitude < 0.001)
}

@Test func reduceMotionStillBrightensAndTightensForListening() {
    var clock = BreathClock()
    var frame = clock.advance(by: 0, toward: .forState(.listening), reduceMotion: true)
    for _ in 0..<60 { frame = clock.advance(by: 1.0 / 60, toward: .forState(.listening), reduceMotion: true) }
    #expect(frame.motion.spreadFactor == CoreMotion.forState(.listening).spreadFactor)
    #expect(frame.motion.amplitudeHigh > CoreMotion.forState(.idle).amplitudeHigh)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'phaseIsContinuous|amplitudeEases|theFirstFrameTakes|reduceMotion'`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The room's breath across state changes (2d-ii).
///
/// `Void.metal` computes `phase = 2π · time / period`. Passing wall time
/// made every period change — idle's 5.4 s to listening's 1.5 s the moment
/// ⌥ arms — jump the breath mid-cycle. This counts **cycles** instead and
/// hands the shader `cycles × period`, so the phase continues from where
/// it was. Strength, spread, drift and coupling ease toward the new state
/// over `easeSeconds`; the period itself switches at once, which is exactly
/// what phase continuity makes safe.
///
/// Drift uses the same `time` against `driftPeriod`. Only thinking drifts,
/// and its two periods are equal (12 s), so its drift stays continuous too;
/// every other state eases its drift amplitude to zero.
public struct BreathClock: Sendable {
    public static let easeSeconds: Double = 0.25

    private var cycles: Double = 0
    private var shown: CoreMotion?

    public init() {}

    public mutating func advance(
        by dt: Double, toward target: CoreMotion, reduceMotion: Bool
    ) -> (time: Double, motion: CoreMotion) {
        let goal = reduceMotion ? Self.still(target) : target
        let eased: CoreMotion
        if let shown {
            let k = min(max(dt / Self.easeSeconds, 0), 1)
            func ease(_ from: Double, _ to: Double) -> Double { from + (to - from) * k }
            eased = CoreMotion(
                period: goal.period,
                amplitudeLow: ease(shown.amplitudeLow, goal.amplitudeLow),
                amplitudeHigh: ease(shown.amplitudeHigh, goal.amplitudeHigh),
                spreadFactor: ease(shown.spreadFactor, goal.spreadFactor),
                driftAmplitude: ease(shown.driftAmplitude, goal.driftAmplitude),
                driftPeriod: goal.driftPeriod,
                bleedBPhase: ease(shown.bleedBPhase, goal.bleedBPhase),
                upperCoupling: ease(shown.upperCoupling, goal.upperCoupling),
                restingFrameRate: goal.restingFrameRate)
        } else {
            eased = goal
        }
        shown = eased
        cycles += max(dt, 0) / max(goal.period, 1e-4)
        return (cycles * goal.period, eased)
    }

    /// Reduce Motion: the state's brightness and tightness stay, its
    /// movement goes — amplitude pinned at the mean, no drift.
    private static func still(_ m: CoreMotion) -> CoreMotion {
        let mean = (m.amplitudeLow + m.amplitudeHigh) / 2
        return CoreMotion(
            period: m.period, amplitudeLow: mean, amplitudeHigh: mean,
            spreadFactor: m.spreadFactor, driftAmplitude: 0, driftPeriod: m.driftPeriod,
            bleedBPhase: m.bleedBPhase, upperCoupling: m.upperCoupling,
            restingFrameRate: m.restingFrameRate)
    }
}
```

`reduceMotionStillBrightensAndTightensForListening` asserts exact `spreadFactor` equality after 60 eased frames from a first frame that already took the target as-is — it holds because the first `advance` with no `shown` returns the goal.

- [ ] **Step 4: Run the tests to verify they pass** — the Step 2 command plus `--filter CoreMotion` for the existing suite. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Visual/BreathClock.swift app/Tests/WakilKitTests/BreathClockTests.swift
git commit -m "2d-ii: BreathClock — phase-continuous, eased breath, Reduce Motion"
```

---

### Task 10: The Apple engine, the standard registry, the wiring, the bundle

**Files:**
- Create: `app/Sources/WakilKit/Speech/AppleSpeechProvider.swift`
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` — `WakilWiring` gains `public let speech: SpeechRegistry`; `build(...)` passes `speech: SpeechRegistry.standard(environment: environment)` (find the memberwise construction near line 365, `vocabulary: vocabulary,`). Run `grep -rn 'WakilWiring(' app` and add the argument at every construction site.
- Modify: `scripts/make-app-bundle.sh:76-90` (the Info.plist heredoc)
- Test: `app/Tests/WakilKitTests/SpeechWiringTests.swift`

**Interfaces:**
- Consumes: `SpeechProvider`, `SpeechEvent`, `SpeechRegistry`, `ScriptedSpeechProvider` (Task 3).
- Produces: `@available(macOS 26.0, *) public final class AppleSpeechProvider: SpeechProvider`; `extension SpeechRegistry { public static func standard(environment: [String: String]) -> SpeechRegistry }`; `WakilWiring.speech`; env var `WAKIL_SPEECH_SCRIPT` (path to a JSON script; set by the e2e harness only).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import WakilKit

/// The never-wired-parameter class: tests inject fakes, so only this test
/// says the production registry actually contains Apple.
@Test func theStandardRegistryRegistersAppleOnMacOS26() {
    let registry = SpeechRegistry.standard(environment: [:])
    if #available(macOS 26.0, *) {
        #expect(registry.engines.map(\.id) == ["apple"])
        #expect(registry.engines.first?.name == "Apple")
        #expect(registry.override == nil)
    } else {
        #expect(registry.engines.isEmpty)
    }
}

@Test func aSpeechScriptOverridesTheMicrophone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).json")
    try Data(#"[{"after":0,"kind":"started","device":"Scripted Mic"}]"#.utf8).write(to: url)
    let registry = SpeechRegistry.standard(environment: ["WAKIL_SPEECH_SCRIPT": url.path])
    #expect(registry.resolve("apple").engine?.id == "scripted")
}

/// A bad script must not silently fall through to the real microphone.
@Test func anUnreadableSpeechScriptFailsLoudly() async {
    let registry = SpeechRegistry.standard(environment: ["WAKIL_SPEECH_SCRIPT": "/nonexistent/script.json"])
    guard let engine = registry.resolve("").engine else { Issue.record("no engine"); return }
    #expect(engine.id == "scripted")
    var events: [SpeechEvent] = []
    for await event in engine.make().start(locale: Locale(identifier: "en-US")) { events.append(event) }
    guard case .failed(let message)? = events.last else { Issue.record("expected .failed, got \(events)"); return }
    #expect(message.contains("/nonexistent/script.json"))
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'theStandardRegistry|aSpeechScript|anUnreadableSpeechScript'`
Expected: FAIL to compile — `standard(environment:)` not found.

- [ ] **Step 3: Implement `AppleSpeechProvider.swift`**

```swift
import Foundation

extension SpeechRegistry {
    /// The engines this build ships, plus the e2e override when
    /// `WAKIL_SPEECH_SCRIPT` names a script. An unreadable script becomes an
    /// engine that fails with the path, never a silent fall-through to the
    /// real microphone.
    public static func standard(environment: [String: String]) -> SpeechRegistry {
        var engines: [SpeechEngine] = []
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            engines.append(SpeechEngine(id: "apple", name: "Apple", make: { AppleSpeechProvider() }))
        }
        #endif
        var override: SpeechEngine?
        if let path = environment["WAKIL_SPEECH_SCRIPT"], !path.isEmpty {
            let steps: [ScriptedSpeechProvider.Step]
            do {
                steps = try ScriptedSpeechProvider.load(path)
            } catch {
                steps = [.init(after: 0, event: .failed("speech script \(path) unreadable: \(error)"))]
            }
            override = SpeechEngine(id: "scripted", name: "Scripted", make: { ScriptedSpeechProvider(steps: steps) })
        }
        return SpeechRegistry(engines: engines, override: override)
    }
}

#if canImport(Speech)
import AVFoundation
import CoreAudio
import Speech

/// Apple's on-device engine (`SpeechAnalyzer` + `SpeechTranscriber`, macOS
/// 26), the default since open question 10 closed. Audio never leaves the
/// machine. Plumbing follows `scripts/probe/sttspike`, changed from a file
/// to a live input tap. Vocabulary biasing is deliberately not set:
/// `2d-stt-probe.md` §6.1 measured `contextualStrings` inert.
@available(macOS 26.0, *)
public final class AppleSpeechProvider: SpeechProvider, @unchecked Sendable {
    /// RMS above this counts as sound. Presence only — never drawn.
    private static let soundFloor: Float = 0.01

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var runner: Task<Void, Never>?

    public init() {}

    public func start(locale: Locale) -> AsyncStream<SpeechEvent> {
        let (events, out) = AsyncStream<SpeechEvent>.makeStream()
        runner = Task { [weak self] in
            await self?.run(locale: locale, out: out)
            out.finish()
        }
        return events
    }

    public func stop() async {
        let (engine, input, analyzer) = lock.withLock { (self.engine, self.input, self.analyzer) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    public func cancel() async {
        let (engine, input, analyzer) = lock.withLock { (self.engine, self.input, self.analyzer) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        runner?.cancel()
    }

    private func run(locale: Locale, out: AsyncStream<SpeechEvent>.Continuation) async {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            out.yield(.denied)
            return
        }
        do {
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                reportingOptions: [.volatileResults], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progress = request.progress
                let watcher = Task {
                    while !Task.isCancelled {
                        out.yield(.downloading(fraction: progress.fractionCompleted, totalBytes: progress.totalUnitCount))
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { watcher.cancel() }
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                out.yield(.failed("the speech model accepts no audio format this Mac offers"))
                return
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let natural = node.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: natural, to: format) else {
                out.yield(.failed("cannot convert \(natural) to \(format)"))
                return
            }
            var lastSound = Date.distantPast
            node.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
                if Self.rms(buffer) > Self.soundFloor, Date().timeIntervalSince(lastSound) > 0.2 {
                    lastSound = Date()
                    out.yield(.audio)
                }
                if let converted = Self.convert(buffer, with: converter, to: format) {
                    inputContinuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            engine.prepare()
            try engine.start()
            lock.withLock {
                self.engine = engine
                self.analyzer = analyzer
                self.input = inputContinuation
            }
            out.yield(.started(device: Self.inputDeviceName()))

            let collector = Task { () -> String in
                var settled = ""
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        settled += text
                        out.yield(.partial(settled: settled, volatile: ""))
                    } else {
                        out.yield(.partial(settled: settled, volatile: text))
                    }
                }
                return settled
            }
            try await analyzer.start(inputSequence: inputs)
            let final = try await collector.value
            out.yield(.final(final.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch is CancellationError {
            return
        } catch {
            out.yield(.failed(String(describing: error)))
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    /// The default input device's name, for "Hearing nothing from …".
    private static func inputDeviceName() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return "the microphone" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() as String?
        else { return "the microphone" }
        return value
    }
}
#endif
```

This code was written against the macOS 27 SDK's `Speech.swiftinterface` signatures (`SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`, `.volatileResults`, `AssetInventory.assetInstallationRequest(supporting:)`, `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`, `start(inputSequence:)`, `finalizeAndFinishThroughEndOfInput()`, `cancelAndFinishNow()`, `AnalyzerInput(buffer:)`). If the compiler disagrees on one, fix the call to the SDK's actual signature (`grep -n '<name>' $(find $(xcrun --show-sdk-path)/System/Library/Frameworks/Speech.framework -name '*.swiftinterface' | head -1)`) and keep the behaviour; do not restructure. Swift 6 may flag `lastSound` captured mutably in the tap closure — box it in a `final class` with an `NSLock` if so.

- [ ] **Step 4: Wire it**

`AppWiring.swift`: add to `WakilWiring`:

```swift
    /// 2d-ii: the speech engines this build ships (Invariant 11). Built
    /// once per process; each hold of ⌥ makes a fresh provider from it.
    public let speech: SpeechRegistry
```

and pass `speech: SpeechRegistry.standard(environment: environment)` in `build`.

`scripts/make-app-bundle.sh`, inside the Info.plist heredoc beside `CFBundleShortVersionString`:

```xml
  <key>NSMicrophoneUsageDescription</key><string>Wakil listens only while you hold ⌥. Audio never leaves this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Wakil turns what you say while holding ⌥ into text, on this Mac.</string>
```

- [ ] **Step 5: Run the tests and the build**

Run: `cd app && ../scripts/swift-test.sh --filter 'theStandardRegistry|aSpeechScript|anUnreadableSpeechScript|SpeechRegistry'` then `make app-build`
Expected: tests PASS; build succeeds with no new warnings in `AppleSpeechProvider.swift`.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Speech/AppleSpeechProvider.swift app/Sources/WakilKit/App/AppWiring.swift scripts/make-app-bundle.sh app/Tests/WakilKitTests/SpeechWiringTests.swift
git commit -m "2d-ii: the Apple engine, the standard registry and its e2e override, the bundle's usage strings"
```

---

### Task 11: The room breathes through `BreathClock`

**Files:**
- Modify: `app/Sources/WakilApp/VoidView.swift` — the `Coordinator`'s stored properties (~line 154-177) and `draw(in:)` (~line 309-360)

**Interfaces:**
- Consumes: `BreathClock.advance(by:toward:reduceMotion:)` (Task 9).

`WakilApp` has no test target; the behaviour is pinned by Task 9's tests, and the operator sees it at Task 18.

- [ ] **Step 1: Implement**

Add to the coordinator beside `lastDrawTime`:

```swift
        /// 2d-ii: phase-continuous, eased breath. `time` handed to the
        /// shader is the clock's, not wall time — see `BreathClock`.
        private var breath = BreathClock()
```

In `draw(in:)`, after `delta` is computed, add:

```swift
            let frame = breath.advance(
                by: delta, toward: CoreMotion.forState(state),
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
```

and in the `VoidUniforms(...)` call replace `time: Float(now - start),` with `time: Float(frame.time),` and `motion: CoreMotion.forState(state),` with `motion: frame.motion,`. Update the comment above `time:` to say the time is the breath clock's. Leave `start` in place if anything else reads it; delete it if nothing does.

- [ ] **Step 2: Build**

Run: `make app-build`
Expected: succeeds.

- [ ] **Step 3: Render the four states headlessly**

Run: `make captures`
Expected: `.context/2b-iv/*.png` written for idle, listening, thinking, speaking with no crash (the capture path drives `VoidView`'s uniforms; if it builds `VoidUniforms` itself with `CoreMotion.forState`, leave it — captures are single instants).

- [ ] **Step 4: Commit**

```bash
git add app/Sources/WakilApp/VoidView.swift
git commit -m "2d-ii: the void breathes through BreathClock and honours Reduce Motion"
```

---

### Task 12: The composer bar

**Files:**
- Create: `app/Sources/WakilApp/ComposerBar.swift`
- Modify: `app/Sources/WakilApp/WindowSession.swift` (~line 254): build and hold `ComposerModel`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`: delete `@State private var promptField` (line 40), the `HStack { TextField(...) Button("Send") }` (lines ~630-637), `threadClearanceReserve` (lines ~124-140) and its `.padding(.bottom, threadClearanceReserve)` (line ~303); mount `ComposerBar` at the bottom edge; move the thread up to sit on the bar

**Interfaces:**
- Consumes: `ComposerModel` (Task 7), `ComposerBarContent` (Task 5), `WakilWiring.speech` (Task 10).
- Produces: `WindowSession.composer: ComposerModel`; `struct ComposerBar: View` taking `composer: ComposerModel`, `onEscapeUnconsumed: () -> Bool`; accessibility ids `window.composer` (the editable field — **keep this id**, existing e2e checks type into it) and `window.composer.bar`, `window.composer.hint`, `window.composer.heard`.

- [ ] **Step 1: `WindowSession`** — after `let model = WindowModel(...)`, add `let composer = ComposerModel(window: model, speech: wiring.speech)` and store it as a `let composer: ComposerModel` property beside `model`, set in the initialiser the same way `model` is.

- [ ] **Step 2: Create `ComposerBar.swift`**

```swift
import AppKit
import WakilKit
import SwiftUI

/// The composer (2d-ii, prototype variant A): one slim bar on the bottom
/// edge. Typed and spoken text land in the same field; Return sends,
/// ⇧Return breaks a line; the hints live inside the bar. No Send button.
struct ComposerBar: View {
    let composer: ComposerModel
    /// Esc that listening did not consume goes here (the thread's fold).
    let onEscapeUnconsumed: () -> Bool

    @State private var host: NSWindow?

    private let coolWhite = Color(red: 0.910, green: 0.925, blue: 0.965)
    private let violet = Color(red: 0.620, green: 0.510, blue: 1.0)

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 1).fill(violet).frame(width: 1.5, height: 18)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            hint
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.02, green: 0.024, blue: 0.047).opacity(0.82)))
        .accessibilityIdentifier("window.composer.bar")
        .background(WindowReader(window: $host))
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
        .task {
            while !Task.isCancelled {
                composer.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch composer.bar {
        case .draft:
            ComposerField(composer: composer)
                .accessibilityIdentifier("window.composer")
        case .hearing(let settled, let volatile, _):
            (Text(settled).foregroundColor(coolWhite.opacity(0.90))
             + Text(settled.isEmpty || volatile.isEmpty ? volatile : " " + volatile)
                .foregroundColor(coolWhite.opacity(0.45)))
                .font(.system(size: 14))
                .lineLimit(6)
                .accessibilityIdentifier("window.composer.heard")
        case .notice(let sentence, _):
            Text(sentence)
                .font(.system(size: 14))
                .foregroundStyle(coolWhite.opacity(0.62))
                .accessibilityIdentifier("window.composer.heard")
        }
    }

    private var hint: some View {
        let text: String
        switch composer.bar {
        case .draft(let h), .hearing(_, _, let h), .notice(_, let h): text = h
        }
        let landed = text == ComposerBarContent.landedHint
        return Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.7)
            .foregroundStyle(landed ? violet.opacity(0.85) : coolWhite.opacity(0.50))
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("window.composer.hint")
    }

    // MARK: - ⌥, other input, Esc, deactivation

    @State private var monitor: Any?
    @State private var resignObserver: Any?

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            // Review focus 1: only the key window's composer listens.
            guard let host, event.window === host, host.isKeyWindow else { return event }
            switch event.type {
            case .flagsChanged:
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting([.capsLock, .numericPad, .function])
                if flags == .option { composer.optionDown() }
                else if flags.isEmpty { composer.optionUp() }
                else { composer.otherInput() }
                return event
            case .keyDown:
                if event.keyCode == 53 {   // Esc
                    if composer.escape() { return nil }
                    if onEscapeUnconsumed() { return nil }
                    return event
                }
                composer.otherInput()
                return event
            default:
                composer.otherInput()
                return event
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { composer.resigned() } }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
    }
}

/// Finds the hosting `NSWindow`, so the monitor can ignore other windows.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window { DispatchQueue.main.async { window = nsView.window } }
    }
}

/// The editable line: an `NSTextView` that wraps, grows to six lines,
/// sends on Return and breaks a line on ⇧Return, and reports its caret in
/// UTF-16 so speech lands where the operator left it.
struct ComposerField: NSViewRepresentable {
    let composer: ComposerModel

    private static let font = NSFont.systemFont(ofSize: 14)
    private static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    func makeCoordinator() -> Coordinator { Coordinator(composer: composer) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let text = scroll.documentView as! NSTextView
        text.delegate = context.coordinator
        text.font = Self.font
        text.textColor = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 0.92)
        text.insertionPointColor = NSColor(red: 0.620, green: 0.510, blue: 1.0, alpha: 1)
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.setAccessibilityPlaceholderValue("Ask, or name what to open")
        context.coordinator.text = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = context.coordinator.text else { return }
        if text.string != composer.draft {
            text.string = composer.draft
            text.setSelectedRange(NSRange(location: min(composer.caret, (composer.draft as NSString).length), length: 0))
        }
        if context.coordinator.focused != composer.focusToken {
            context.coordinator.focused = composer.focusToken
            text.window?.makeFirstResponder(text)            // rule 3: landed input arrives focused
        }
        let lines = max(1, min(6, Int((text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0) / Self.lineHeight)))
        scroll.frame.size.height = CGFloat(lines) * Self.lineHeight
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let text = context.coordinator.text, let container = text.textContainer,
              let layout = text.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let lines = max(1, min(6, Int(ceil(used / Self.lineHeight))))
        return CGSize(width: proposal.width ?? 400, height: CGFloat(lines) * Self.lineHeight)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let composer: ComposerModel
        weak var text: NSTextView?
        var focused = 0
        init(composer: ComposerModel) { self.composer = composer }

        func textDidChange(_ notification: Notification) { report() }
        func textViewDidChangeSelection(_ notification: Notification) { report() }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSEvent.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            Task { await composer.submit() }
            return true
        }

        private func report() {
            guard let text else { return }
            composer.edited(draft: text.string, caret: text.selectedRange().location)
        }
    }
}
```

- [ ] **Step 3: Mount it in `WakilWindow`**

Delete `promptField`, the `TextField`/`Send` `HStack`, `threadClearanceReserve` and its padding, as listed under **Files**. In the `ZStack` after the `accountIndicator(...)` block, add:

```swift
                    // 2d-ii: the composer bar on the bottom edge, opposite
                    // the account indicator; panes run down to just above it.
                    ComposerBar(
                        composer: session.composer,
                        onEscapeUnconsumed: { threadDisclosure.escape() })
                        .padding(.leading, 24)
                        .padding(.trailing, accountWidth > 0 ? accountWidth + 44 : 24)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
```

Change the `accountIndicator` block's `.padding(.bottom, 26)` to `.padding(.bottom, 16)` so it shares the bar's row, and the thread's `.padding(.bottom, 26)` to `.padding(.bottom, 52)` so it sits on top of the bar. Add `@State private var threadDisclosure = ThreadDisclosure()` to `WakilWindow` (Task 13 uses it). Give the canvas `VStack` a bottom padding of `48` (the bar's height plus its gap) so a pane ends above the bar rather than under it — that replaces the 132 pt reserve.

Search for other readers of the deleted pieces: `grep -n 'promptField\|threadClearanceReserve\|window.send' app/Sources app/Tests e2e`. `window.send` is used by existing e2e checks to click Send; list every file that references it in your report — the e2e auditor rewrites those checks to press Return at the Cover rung. Do not edit the `.jsonl` checks yourself.

- [ ] **Step 4: Build**

Run: `make app-build`
Expected: succeeds. Do not launch the app (Global Constraints: no GUI runs).

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/ComposerBar.swift app/Sources/WakilApp/WakilWindow.swift app/Sources/WakilApp/WindowSession.swift
git commit -m "2d-ii: the composer bar — push-to-talk, Return sends, the reserve deleted"
```

---

### Task 13: The thread — compact, faded, expandable, overlapping

**Files:**
- Rewrite: `app/Sources/WakilApp/ThoughtThread.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift` — pass `$threadDisclosure`; remove the thread's `.allowsHitTesting(false)`

**Interfaces:**
- Consumes: `ThreadDisclosure` (Task 8), `ThoughtRow`.
- Produces: `ThoughtThread(rows:parallax:disclosure:)` with `disclosure: Binding<ThreadDisclosure>`; accessibility ids `window.thread`, `window.thread.row.<id>`, `window.thread.earlier`.

- [ ] **Step 1: Rewrite `ThoughtThread.swift`**

Keep the file's existing doc comment paragraphs about the near plane and "no upcoming steps"; replace the struct with:

```swift
struct ThoughtThread: View {
    let rows: [ThoughtRow]
    let parallax: CGSize
    @Binding var disclosure: ThreadDisclosure

    var body: some View {
        let (shown, earlier) = disclosure.visible(rows)
        VStack(alignment: .leading, spacing: 0) {
            if earlier > 0 {
                Text("\(earlier) earlier · show".uppercased())
                    .font(.system(size: 7.5, weight: .medium))
                    .tracking(1.3)
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.40))
                    .padding(.leading, 72)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { disclosure.showEarlier() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("window.thread.earlier")
            }
            ForEach(shown) { row in
                rowView(row)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.02, green: 0.024, blue: 0.047).opacity(0.85))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)))
        .frame(maxWidth: 640, alignment: .leading)
        .opacity(rows.isEmpty ? 0 : disclosure.opacity)
        .animation(.easeOut(duration: 0.16), value: disclosure.opacity)   // spec: 160 ms
        .onHover { inside in
            if inside { disclosure.pointerEntered() }
            else { disclosure.pointerLeft(at: ProcessInfo.processInfo.systemUptime) }
        }
        .task {
            while !Task.isCancelled {
                disclosure.tick(at: ProcessInfo.processInfo.systemUptime,
                                mouseHeld: NSEvent.pressedMouseButtons != 0)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.thread")
        .scaleEffect(Plane.near.scale)
        .blur(radius: Plane.near.blur)
        .offset(x: parallax.width, y: parallax.height)
    }

    private func rowView(_ row: ThoughtRow) -> some View {
        let open = disclosure.open.contains(row.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label.uppercased())
                .font(.system(size: 7.5, weight: .medium))
                .tracking(1.3)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(colour(for: row).opacity(0.55))
            Group {
                if open {
                    Text(row.detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(row.detail)
                        .font(.system(size: 10.5))
                        .italic(row.label == "resumed")
                        // Errors are shown whole (interaction rule 8).
                        .lineLimit(row.isError ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: row.isError)
                        .foregroundStyle(colour(for: row))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(open ? Color.white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { disclosure.toggle(row.id) }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("window.thread.row.\(row.id)")
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    private func colour(for row: ThoughtRow) -> Color {
        if row.isError { return Color(red: 0.910, green: 0.361, blue: 0.361) }
        if row.id == rows.last?.id { return Color(red: 0.910, green: 0.925, blue: 0.965) }
        if row.label == "you" { return Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.70) }
        return Color(red: 0.545, green: 0.878, blue: 0.784).opacity(0.45)
    }
}
```

Add `import AppKit` at the top for `NSEvent`.

- [ ] **Step 2: Update the call site in `WakilWindow`**: `ThoughtThread(rows: session.model.thoughts, parallax: ..., disclosure: $threadDisclosure)`; delete the `.allowsHitTesting(false)` that follows it (rows take hits; the empty frame around them does not, because nothing there has a content shape). Keep the `GeometryReader` anchor reporting and the account-width trailing padding.

- [ ] **Step 3: Build** — `make app-build`. Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/WakilApp/ThoughtThread.swift app/Sources/WakilApp/WakilWindow.swift
git commit -m "2d-ii: the thread — four rows over the panes, faded at rest, expand on click, fold on leave"
```

---

### Task 14: The Speech row in settings

**Files:**
- Modify: `app/Sources/WakilApp/SettingsPane.swift` — the Organisation form (where `OrganisationField` rows are drawn, ~line 540-620)

**Interfaces:**
- Consumes: `OrganisationField.speechProvider` (Task 2), `SpeechRegistry.standard(environment:)`, `SpeechRegistry.note(for:)` (Tasks 3, 10), `SegmentedChoice(options:selection:identifier:held:)` (`SettingsForm.swift:146`).
- Produces: accessibility ids `settings.org.speechProvider.<engine id>` per segment and `settings.org.speechProvider.note`.

- [ ] **Step 1: Implement**

The form currently draws every `OrganisationField` as a text field. Exclude `.speechProvider` from that loop and draw it after the others:

```swift
    /// 2d-ii: the organisation's speech engine (Invariant 11). One segment
    /// per registered engine; a stored id no engine answers to is drawn as
    /// a held segment, with the registry's note beneath it (rule 7).
    private func speechRow(tree: SettingsTree) -> some View {
        let registry = SpeechRegistry.standard(environment: ProcessInfo.processInfo.environment)
        let stored = tree.org.speechProvider
        let ids = registry.engines.map(\.id)
        let current = stored.isEmpty ? SpeechRegistry.defaultId : stored
        return VStack(alignment: .leading, spacing: 2) {
            Text("SPEECH")
                .font(.system(size: Scale.micro, weight: .medium))
                .tracking(Scale.microTracking)
                .foregroundStyle(coolWhite.opacity(0.32))
            SegmentedChoice(
                options: ids,
                selection: Binding(
                    get: { current },
                    set: { id in
                        guard id != current else { return }
                        drafts[.speechProvider] = id
                        save(.speechProvider, tree: tree)
                    }),
                identifier: { "settings.org.speechProvider.\($0)" },
                held: ids.contains(current) ? nil : current)
            if let note = registry.note(for: stored) {
                Text(note)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .accessibilityIdentifier("settings.org.speechProvider.note")
            }
            if let refusal = refusals[.speechProvider] {
                Text(refusal).font(.system(size: Scale.body)).foregroundStyle(caution)
            }
        }
        .padding(.bottom, 4)
    }
```

`SegmentedChoice` draws its option strings; to show `Apple` rather than `apple`, map ids to names when drawing — if `SegmentedChoice` has no label closure, pass `registry.engines.map(\.name)` as `options` and translate in the binding (`get` returns the name for `current`, `set` maps the tapped name back to its id). Pick whichever keeps `SegmentedChoice` unchanged.

Saving on tap, with no Save button, meets rule 2 (Enter is never required) and rule 1 (no confirmation for an ordinary edit).

- [ ] **Step 2: Build** — `make app-build`. Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add app/Sources/WakilApp/SettingsPane.swift
git commit -m "2d-ii: the Speech row — engine per organisation, unknown ids held and named"
```

---

### Task 15: Record the amended design

**Files:**
- Modify: `docs/wakil/design-language.md` §12 (the Push-to-talk bullet, ~line 434) and §9 (~line 324)
- Modify: `PRODUCT.md:85-87` (the Push-to-talk bullet)
- Modify: `docs/wakil/design-language.md` open items (~line 602-606): listening's numbers are tuned at Task 18

- [ ] **Step 1: Edit**

§12, after the bullet's first sentence, add an amendment paragraph in the file's existing italic-dated style:

```markdown
  ***Release lands, it does not send. Amended 2026-10-07*** *— 2d-ii, on the operator's
  instruction. An allow-priced write can run from a mistranscribed spoken turn (2d-i,
  `2d-stt-probe.md` §10), so releasing ⌥ puts the transcript in the composer unsent, at the
  caret, and Return sends it. The silence case is answered in words in the composer bar —
  "Hearing nothing from <device>" after 1.5 s with no sound — never a meter. Spec:
  `docs/superpowers/specs/2026-10-07-2d-ii-voice-capture-design.md`.*
```

and change "release to send" in the bullet's first sentence to "release to land it in the composer".

§9, append:

```markdown
*Amended 2026-10-07 (2d-ii): the thread overlaps the panes, which now take the full height.
It shows four rows, rests at 32% opacity and rises to full on hover, expands a row in place
on click, and folds 1.2 s after the pointer leaves. Each sent turn is a `you` row.*
```

`PRODUCT.md` push-to-talk bullet: append `Release lands the transcript in the composer unsent; Return sends.`

- [ ] **Step 2: Check** — `make docs-check`. Expected: passes (`north-star.md` is at its 4000-word cap and is not edited here).

- [ ] **Step 3: Commit**

```bash
git add docs/wakil/design-language.md PRODUCT.md
git commit -m "2d-ii: design-language §9/§12 and PRODUCT record release-to-land and the overlapping thread"
```

---

### Task 16: Whole-branch review

- [ ] **Step 1:** Dispatch the final code reviewer (subagent-driven) or one fresh reviewer (native) over `main...HEAD`, with the spec, this plan's Global Constraints and Review Focus, and PRODUCT.md §Interaction Rules as the brief.
- [ ] **Step 2:** Fix what it confirms, one commit per finding, each with its own scoped test run.

---

### Task 17: Gates (controller only — never a subagent)

- [ ] **Step 1:** `go build ./... && go vet ./... && go test ./...` — Expected: PASS.
- [ ] **Step 2:** `make build && make app-test` (memory: `app-test` does not build Go; build first) — Expected: PASS. Read `.context/app-test.log` for the count; record it in the report.
- [ ] **Step 3:** `make app-bundle` — Expected: `app/Wakil.app` built; `plutil -p app/Wakil.app/Contents/Info.plist | grep -E 'NSMicrophone|NSSpeech'` prints both keys.
- [ ] **Step 4:** `make docs-check` — Expected: PASS.
- [ ] **Step 5:** Ask the operator, and message burrfish, before any GUI run. Then the **Cover** rung: the e2e auditor (`docs/agents/e2e.md`) writes the checks named in the spec's Testing section using `WAKIL_SPEECH_SCRIPT`, and rewrites every check that clicked `window.send` (listed in Task 12's report) to press Return in `window.composer`.

---

### Task 18: Tune the listening breath with the operator

The spec owes a tuning pass: design-language lists listening's spread and amplitudes as invented. This needs the operator and the GUI, so it waits on Task 17's GUI clearance.

- [ ] **Step 1:** With the operator's go-ahead, launch `app/Wakil.app` on an open organisation; hold ⌥ and let them watch idle → listening → idle.
- [ ] **Step 2:** Adjust only `CoreMotion.forState(.listening)` (`app/Sources/WakilKit/Visual/CoreMotion.swift:97-101`) and `BreathClock.easeSeconds`, rebuilding (`make app-bundle`) between rounds, until the operator approves. Cap it at three rounds, then offer the operator a choice of the best two (memory: GUI timing fix loops).
- [ ] **Step 3:** Run `cd app && ../scripts/swift-test.sh --filter 'CoreMotion|BreathClock'`; update any assertion that pinned an old number only if it pinned the number itself rather than a relation the spec requires (idle lowest ceiling, listening highest).
- [ ] **Step 4:** Commit `2d-ii: listening breath tuned with the operator` with the approved numbers in the message, and replace design-language's open item on listening's numbers with the approved values and date.

After Task 18: the operator walk, from an acceptance runbook the e2e auditor drafts at Cover (`docs/wakil/phase-2d-ii-acceptance.md`).
