# 2d-ii: voice capture, the composer, and the listening room

**Date:** 2026-10-07
**Status:** approved 2026-10-07; implemented on yehia-khalil/2d-ii-voice
**Sub-phase:** 2d-ii — waits on 2d-i (met 2026-10-07) and 2e (met 2026-09-30), both met
**Prototype:** `docs/wakil/screens/Composer.prototype.html`, variant A — throwaway, captured on
this branch as the primary source for the composer and thread decisions below

---

## Problem

Decision 1 rests on voice, and no voice exists. The room has had a listening state since
2b-iv that nothing sets; design-language §12 describes push-to-talk that nothing captures;
Decision 18 and Invariant 11 require a per-organization speech engine that has no seam.
2d-i built the resolver a spoken turn needs. 2d-ii builds the capture in front of it.

Two findings shape it. **An allow-priced write can run from a mistranscribed spoken turn**
(2d-i, `2d-stt-probe.md` §10), so §12's *release to send* is unsafe as drawn. And **the
silence case** — a dead microphone looks exactly like a room that is listening — is owed by
2d and may not be answered with a meter (§12, amended 2026-09-15).

## What the operator gets

1. **Hold ⌥, alone, while Wakil is frontmost.** After ~180 ms with no other key or click,
   the room enters listening and the live transcription is drawn in the composer bar. The
   engine's unsettled tail is drawn dimmer than the settled words.
2. **Release lands the transcript in the composer, unsent**, at the caret, with spaces
   added where needed and nothing replaced. The bar's hint reads *heard · Return sends ·
   edit first*. **Return sends** through the existing `send(_:)`, so 2d-i's resolver note
   applies. **Esc while holding** discards what was heard this hold.
3. **Failure is said in words in the bar, never drawn as a meter.** *"Hearing nothing from
   MacBook Pro Microphone"* after 1.5 s with no audio and no words, naming the input device;
   *"Wakil can't use the microphone. Allow it in System Settings → Privacy & Security →
   Microphone"* when permission is refused.
4. **First use may download the English model.** The bar says so with the size; Esc
   cancels.
5. **The composer is one slim bar at the bottom edge** (prototype variant A): caret bar,
   the line, and the hints *Hold ⌥ to speak · ⌘P open · ⌘K actions* inside the same row.
   Return sends, ⇧Return breaks a line, it grows to six lines, and there is **no Send
   button**.
6. **Panes take the whole height, and the thought thread overlaps them.** The 132 pt
   `threadClearanceReserve` is deleted; §3 already lets the near plane overlap. The thread:
   - shows the **last four rows**, compact (10.5 pt detail, 7.5 pt label column), with
     *"N earlier · show"* above them;
   - sits on a dark blurred backing, and **rests at 32 % opacity, rising to full on hover**
     (160 ms). Errors are red at rest too; nothing else is exempted from the fade;
   - **expands a row in place on click** — monospaced, wrapped, selectable — and stays full
     while any row is open or the earlier rows are shown;
   - **folds and fades 1.2 s after the pointer leaves**, unless a mouse button is held (a
     drag-selection in progress — SwiftUI cannot report a text selection, so this is the
     observable form of the rule); Esc folds it at once;
   - gains a **`you` row** for each sent turn, so what was actually sent stays visible;
   - takes hits on its rows only; the pane beneath stays clickable everywhere else.
7. **The listening breath is built.** The room's breath is phase-continuous across state
   changes, its amplitude and spread ease into listening over ~250 ms rather than snapping,
   and listening's numbers are tuned with the operator. Under Reduce Motion the room
   brightens and tightens for listening but does not breathe.
8. **Speech engines are pluggable now.** A `speechProvider` in `org.json`, a registry of
   engines, and a **Speech** row in the settings pane's Organisation form choose the engine
   per organization. Apple is the only one registered.

## What it does not do

- **No speaking state.** Nothing delivers text-to-speech; open question 17.
- **No spoken aliases.** `2b-viii` heard as "2B8" is corrected by hand in the composer
  before Return — the unsent landing is what makes that cheap.
- **No global hotkey.** ⌥ listens only while Wakil is frontmost; a system-wide modifier tap
  needs Input Monitoring and would take ⌥ from other apps.
- **No Whisper or cloud engine.** The seam admits them as one new conformance each.
- **No vocabulary biasing.** `contextualStrings` was measured inert (`2d-stt-probe.md` §6.1).
- **No Reduce Motion beyond the breath.** Parallax, thinking turnover and the rail's
  promotion stay recorded debt (PRODUCT.md §Accessibility).
- **No languages beyond English.**

## Design

### Units

| Unit | Where | Does | Depends on |
|---|---|---|---|
| `SpeechEvent` | `WakilKit/Speech/` | `partial(settled:volatile:)`, `final(String)`, `heardNothing(device:)`, `denied`, `downloading(done:total:)`, `failed(String)` | — |
| `SpeechProvider` (protocol) | `WakilKit/Speech/` | `start(locale:) -> AsyncStream<SpeechEvent>`, `stop()`, `cancel()`. Audio in, text out (Decision 18) | the engine |
| `SpeechRegistry` | `WakilKit/Speech/` | id → (display name, factory). `resolve(id?) -> (provider, note?)`: missing id → `apple`; unknown id → `apple` plus a note naming it | providers |
| `ListeningMachine` | `WakilKit/Speech/` | The state machine: `idle → arming → listening → idle`. Owns the 180 ms arm, cancel-on-other-input, the 1.5 s silence timer, Esc-discard, focus-loss-as-release, and the landing rule (insert at caret, pad spaces). Pure: every input carries its time, and it returns effects for `ComposerModel` to run | `SpeechEvent` |
| `ComposerModel`, `ComposerBarContent` | `WakilKit/App/` | Owns the draft and caret, runs the machine's effects against the provider; what the bar draws: the draft, or the heard text with its volatile tail, or a notice; and the hint for the state | `ListeningMachine`, `WindowModel` |
| `ThreadDisclosure` | `WakilKit/App/` | Visible rows (last four), the earlier count, open rows, pinned, and the 1.2 s fold, with time passed in | `WindowModel.thoughts` |
| `CoreMotion` (changed) | `WakilKit/Visual/` | Gains an accumulated breath phase and eased amplitude/spread, so a state change neither jumps phase nor snaps; a Reduce Motion variant that holds amplitude at the state's mean | — |
| `AppleSpeechProvider` | `WakilApp` | `AVAudioEngine` input tap → `SpeechAnalyzer` + `SpeechTranscriber`; `AssetInventory` for the model; input-device name from Core Audio. Plumbing from `scripts/probe/sttspike` | Speech, AVFoundation |
| `speechProvider` | Go, `internal/wakilcore/org.go` beside `defaultProvider` | Optional string, `omitempty`; read and written through the same path as the Organisation form's other strings | — |
| Speech row | `SettingsPane`, Organisation form | A `SegmentedChoice` over the registry; shows the registry's note when the stored id is unknown | `SpeechRegistry` |
| Composer bar, thread | `WakilWindow`, `ThoughtThread` | Draw the two models above; the reserve is deleted, hit-testing is per row | the models |

### Data flow

⌥ down → `ListeningMachine.optionDown` → 180 ms with no other input → `begin` →
`SpeechRegistry.resolve(org.speechProvider)` → `provider.start` → `WindowModel.coreState =
.listening` → `partial` events redraw the bar → ⌥ up → `stop` → `final` → inserted into the
composer draft at the caret → `coreState` back to the turn rule (`forTurn(inFlight:)`) →
Return → `send(_:)` unchanged. After a successful send, a separate journal entry
`action: voice_turn, params {via: voice}` is written when any of the sent text landed from
speech; nothing else downstream changes (Invariant 10).

### The bundle

`NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` join the bundle's
Info.plist in `make app-bundle`. The bundle is ad-hoc signed (2b-vii is externally blocked),
so TCC may re-prompt after a rebuild; that is a development cost, not a design defect.

## Errors and edges — against PRODUCT.md §Interaction Rules

| Case | Behaviour | Rule |
|---|---|---|
| Permission refused | Bar names the Settings path; the next hold re-checks; typing is unaffected | 8 |
| No audio for 1.5 s | Bar names the input device; clears as soon as audio arrives | 8 |
| Model not installed | Bar shows the download and its size; Esc cancels | 4 |
| Engine fails mid-utterance | Words so far land; the error is a whole red thread row | 8 |
| ⌥ released under 180 ms, or ⌥ chorded with a key or click | Nothing happens; ⌥ is an ordinary modifier | 7 |
| Wakil loses focus while holding | Treated as release — what was heard lands, unsent | 2 |
| Hold during a turn in flight | Allowed; lands for the next turn; nothing double-sends | 5 |
| Composer already has text | Insert at caret; nothing replaced | 7 |
| Esc while holding | Discards this hold only | 4 |
| Allow-priced write from a misheard turn | Nothing sends until Return; gate-priced writes still need typed confirmation | 1, Inv. 7 |
| Unknown `speechProvider` | Apple is used; the Speech row says *unknown engine 'x', using Apple* | 7 |
| Settings pane focused | Speech lands in the agent composer; the settings pane stays operator-only (Decision 30) | — |

Rules 3 and 6: the composer is focused when the text lands, and nothing on the canvas moves.
Rule 9 is not touched: Apple is a default, and the Speech row overrides it.

## Testing

**`WakilKit` unit tests, test-first, against `ScriptedSpeechProvider` and with time passed
in explicitly:**

- `ListeningMachine`: the 180 ms arm; a chorded key or click cancels; caret insertion and
  padding; Esc discards; focus loss lands; the silence timer starts at `begin` and resets
  on audio; `denied`, `downloading` and `failed` map to the bar's notices.
- `SpeechRegistry`: lookup, missing → apple, unknown → apple with the note.
- `CoreMotion`: phase is continuous across idle → listening → idle; amplitude and spread
  ease rather than step; Reduce Motion holds amplitude constant.
- `ThreadDisclosure`: four visible, the earlier count, open/pinned, the 1.2 s fold, and
  no fold while a mouse button is held.
- **Wiring**: the production `AppWiring` registers `apple` and hands the registry to
  `WindowModel` — the never-wired-parameter class, which fakes alone cannot catch.

**Go:** `org.go` round-trips `speechProvider`; an `org.json` without it still reads.

**e2e (Cover):** a launch switch substitutes a scripted provider for the microphone. Checks
drive real ⌥ events and read the composer and thread through accessibility: hold → release
lands unsent; Return sends with a `voice_turn` journal entry (`via: voice`) written; Esc discards; a scripted silence
shows the notice; the Speech row writes `org.json`; a pane's frame extends beneath the
thread.

**Operator walk:** the real microphone and voice; permission refused, then granted; the
model download; tuning and approving the listening breath; the thread's fade, expand and
fold over a full pane; a misheard identifier corrected before Return.

## Open questions

None blocking. Open question 17 (does Wakil ever speak) stays open and owns the speaking
state.
