# Phase 2b-iv — The void as the Core: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the Core sphere and make the void itself carry Wakil's four states, on one
Metal layer, at a lower idle cost than what 2b-ii ships.

**Architecture:** Every number the room moves by lives in `WakilKit` as a tested value type
(`CoreMotion`, `ThreadLift`, `VoidUniforms`); `Void.metal` receives those numbers and applies
them with **no branches**; `VoidView` becomes the app's only Metal layer, drawing
continuously at a frame rate derived from the current state's own cadence. `CoreView.swift`
and `Core.metal` are deleted outright.

**Tech Stack:** Swift 6.3.2 · SwiftPM (`swift-tools-version: 6.0`) · SwiftUI + AppKit ·
Metal / MetalKit · `simd` · swift-testing (`import Testing`, `@Test`, `#expect`) · GNU make

**Spec:** `docs/superpowers/specs/2026-09-09-void-as-core-design.md`

## Global Constraints

- **Deployment target is macOS 14.4**, set in `app/Package.swift`. Do not raise it.
- **Tests use swift-testing, never XCTest.** `import Testing`, `@Test func name()`,
  `#expect(...)`. Free functions at file scope, not methods on a class.
- **Run tests with `make app-test`** from the repository root, or
  `cd app && ../scripts/swift-test.sh --filter <name>` for one test. A bare `swift test`
  fails to find `Testing.framework` on this machine.
- **Build with `make app-build`** from the repository root, never a bare `swift build` in
  `app/` — the Makefile compiles the shaders first.
- **A test target cannot import an executable target.** `WakilApp` is an executable, so
  anything that needs a test lives in `WakilKit`. This is why Task 2 moves `VoidUniforms`
  out of `VoidView` and into `WakilKit`.
- **`WakilKit` must not import AppKit or SwiftUI.** `import simd` and `import Foundation`
  are fine — they need no display. This is what keeps `WakilKitTests` runnable headlessly.
- **Hue belongs to the environment; motion and intensity belong to agent state.** No task
  in this plan may modify `VoidPalette.swift` or `VoidPaletteTests.swift`. If a task seems
  to need to, stop and escalate — the spec's central claim has broken.
- **Motion periods, verbatim from `design-language.md` §7:** idle breath **5.4 s**,
  listening breath **1.5 s**. From `Core.metal` as shipped: speaking pulse **0.42 s**.
  Thinking's **12 s** is this sub-phase's own invention and has no precedent.
- **Palette values, verbatim from `design-language.md` §2 and §5:** void field
  `#030408`–`#070812` · violet `#7c5cff` · blue `#4fb9e8` · mint/green `#8be0c8` · red
  `#e85c5c` · text cool white `#e8ecf6`.
- **No document produced by this phase may claim 120 fps was observed.** Both displays on
  the build machine are 60 Hz.
- **Commit after every task**, with the task number in the subject.

---

## File Structure

New, in `WakilKit` — pure, testable, no display:

    Visual/CoreMotion.swift         CoreState → periods, amplitudes, spread, drift,
                                    frame rate; and ThreadLift's decay curve
    Visual/VoidUniforms.swift       the Swift↔Metal wire format, built from a
                                    CoreMotion and a VoidPalette

New, in tests:

    Tests/WakilKitTests/CoreMotionTests.swift
    Tests/WakilKitTests/VoidUniformsTests.swift

New, in docs:

    docs/wakil/phase-2b-iv-acceptance.md

Modified:

    app/Shaders/Void.metal                        motion, coupling, ambient scale
    app/Sources/WakilApp/VoidView.swift           continuous; rate from CoreMotion;
                                                  occlusion pause; eased ambient scale
    app/Sources/WakilApp/WakilWindow.swift        CoreView removed; thread re-anchored
    app/Sources/WakilApp/ThoughtThread.swift      near-plane treatment
    app/Sources/WakilApp/Capture.swift            one pipeline; --capture-motion
    app/Sources/WakilApp/main.swift               --capture-motion flag
    app/Sources/WakilKit/Visual/CoreState.swift   shaderIndex removed
    app/Tests/WakilKitTests/CoreStateTests.swift  pinning test removed
    Makefile                                      shaders + captures targets
    docs/wakil/design-language.md                 §§1, 2, 3, 4, 7, 9, 12, 13, 15
    docs/wakil/north-star.md                      §7 q11, §8, frame-rate section
    docs/wakil/void-as-core-probe.md              §5 correction, §7 status
    docs/wakil/phase-2b-ii-acceptance.md          note on the Core-specific checks

Deleted:

    app/Sources/WakilApp/CoreView.swift
    app/Shaders/Core.metal

**Task ordering note.** The room is built (Tasks 2–3) *before* the sphere is deleted
(Task 4). During those two commits both layers draw, which looks odd and is harmless — and
it means there is never a commit where the window has no presence indicator at all, and it
gives the reviewer a direct A/B between the sphere and the room on one running window.

---

## Task 1: `CoreMotion` and `ThreadLift`

Turns `CoreState` into every number the room needs, and the thought thread's activity into
a 0…1 lift. Pure `WakilKit`; nothing renders yet.

**Files:**
- Create: `app/Sources/WakilKit/Visual/CoreMotion.swift`
- Create: `app/Tests/WakilKitTests/CoreMotionTests.swift`

**Interfaces:**
- Consumes: `CoreState` (`app/Sources/WakilKit/Visual/CoreState.swift`), unmodified.
- Produces:
  - `CoreMotion.forState(_ state: CoreState) -> CoreMotion`
  - stored properties `period`, `amplitudeLow`, `amplitudeHigh`, `spreadFactor`,
    `driftAmplitude`, `driftPeriod`, `bleedBPhase`, `upperCoupling` — all `Double` — and
    `restingFrameRate: Int`
  - computed `framesPerCycle: Double`
  - `ThreadLift.value(hasRows: Bool, isTurnInFlight: Bool, secondsSinceLastRow: Double) -> Double`
  - `ThreadLift.decaySeconds: Double`

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/WakilKitTests/CoreMotionTests.swift`:

```swift
import Testing
@testable import WakilKit

/// `design-language.md` §7's table, verbatim. The room inherits the sphere's
/// cadences rather than inventing new ones, and these two are the only
/// periods the design language actually states.
@Test func idleAndListeningKeepTheDesignLanguagesPeriods() {
    #expect(CoreMotion.forState(.idle).period == 5.4)
    #expect(CoreMotion.forState(.listening).period == 1.5)
}

/// Spec §3: idle is "present but asleep" and listening is "attending", so
/// idle has the lowest ceiling of the four and listening the highest.
///
/// Stated as ceilings rather than as "dimmest"/"brightest" on purpose:
/// thinking's *floor* (0.30) is below idle's (0.55), because thinking's two
/// bleeds trade dominance and each one dips further than idle ever does.
/// A test asserting idle is lowest on both ends would be asserting something
/// false.
@Test func idleHasTheLowestCeilingAndListeningTheHighest() {
    let idle = CoreMotion.forState(.idle)
    let listening = CoreMotion.forState(.listening)
    for state in CoreState.allCases where state != .idle {
        #expect(idle.amplitudeHigh < CoreMotion.forState(state).amplitudeHigh)
    }
    for state in CoreState.allCases where state != .listening {
        #expect(listening.amplitudeHigh > CoreMotion.forState(state).amplitudeHigh)
    }
}

@Test func everyStatesAmplitudeRangeIsOrdered() {
    for state in CoreState.allCases {
        let motion = CoreMotion.forState(state)
        #expect(motion.amplitudeLow < motion.amplitudeHigh)
    }
}

/// §4's word for listening is "tighten", and spread is the only channel that
/// can express it for a room. No other state touches it.
@Test func listeningIsTheOnlyStateThatChangesSpread() {
    for state in CoreState.allCases {
        let spread = CoreMotion.forState(state).spreadFactor
        #expect(state == .listening ? spread > 1.0 : spread == 1.0)
    }
}

/// Thinking is "internal turbulence": the only state whose bleeds move, and
/// the only one whose two bleeds are out of phase so they trade dominance
/// rather than brightening together.
@Test func thinkingIsTheOnlyStateWithDriftOrAntiphase() {
    for state in CoreState.allCases {
        let motion = CoreMotion.forState(state)
        if state == .thinking {
            #expect(motion.driftAmplitude > 0)
            #expect(motion.driftPeriod > 0)
            #expect(motion.bleedBPhase == 0.5)
        } else {
            #expect(motion.driftAmplitude == 0)
            #expect(motion.bleedBPhase == 0)
        }
    }
}

/// Spec §3: speaking's 0.42s pulse is contained by geometry, not by a small
/// constant. Upper coupling 0 means the upper-right bleed holds still while
/// only the lower bleed pulses, so no large peripheral area ever flickers at
/// speech rate. Every other state modulates both bleeds together.
@Test func speakingIsTheOnlyStateWhosePulseIsLocalToTheLowerBleed() {
    for state in CoreState.allCases {
        let coupling = CoreMotion.forState(state).upperCoupling
        #expect(state == .speaking ? coupling == 0 : coupling == 1)
    }
}

/// Spec §5's rule: each state buys the smoothness its own period needs and
/// no more. Below 25 frames a cycle, motion reads as stepping.
@Test func everyStateGetsAtLeastTwentyFiveFramesPerCycle() {
    for state in CoreState.allCases {
        #expect(CoreMotion.forState(state).framesPerCycle >= 25)
    }
}

/// north-star.md's frame-rate section: 120 is the ceiling, as a statement of
/// intent and a guard on future hardware. Nothing may ask for more.
@Test func noStateAsksForMoreThanOneHundredAndTwentyFramesPerSecond() {
    for state in CoreState.allCases {
        let rate = CoreMotion.forState(state).restingFrameRate
        #expect(rate > 0)
        #expect(rate <= 120)
    }
}

@Test func threadLiftIsZeroWithNoRows() {
    #expect(ThreadLift.value(hasRows: false, isTurnInFlight: true, secondsSinceLastRow: 0) == 0)
}

@Test func threadLiftIsFullWhileATurnIsInFlight() {
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: true, secondsSinceLastRow: 99) == 1)
}

/// Decays to zero over `decaySeconds` after the last row, so the glow fades
/// with the thread rather than snapping off with it.
@Test func threadLiftDecaysToZeroAfterTheLastRow() {
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: false, secondsSinceLastRow: 0) == 1)
    #expect(abs(ThreadLift.value(hasRows: true, isTurnInFlight: false,
                                 secondsSinceLastRow: ThreadLift.decaySeconds / 2) - 0.5) < 1e-9)
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: false,
                             secondsSinceLastRow: ThreadLift.decaySeconds) == 0)
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: false, secondsSinceLastRow: 10) == 0)
}

/// A clock that goes backwards — which `Date` can, across an NTP step — must
/// not produce a lift above 1 and blow the bleed out.
@Test func threadLiftClampsANegativeElapsedTime() {
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: false, secondsSinceLastRow: -5) == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter CoreMotion`
Expected: FAIL to **compile**, with `cannot find 'CoreMotion' in scope` and
`cannot find 'ThreadLift' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Sources/WakilKit/Visual/CoreMotion.swift`:

```swift
import Foundation

/// How the room moves in each of `design-language.md` §4's four states.
///
/// **Why this is a Swift type and not constants inside the shader.**
/// `Core.metal` — the sphere this sub-phase deletes — branched on an integer
/// state uniform and carried its periods as literals inside the fragment
/// function. Repeating that here would put five *admittedly invented*
/// numbers (see below) somewhere nothing is testable, where no test can
/// assert they match §7's table, and where the tuning pass the acceptance
/// runbook requires would edit Metal source with no safety net.
/// `VoidPalette`'s doc comment states the rule this follows: WakilKit stays
/// free of AppKit so that every question with a right answer can be tested
/// without a display, and "does idle breathe at the period §7 gives" is
/// exactly such a question.
///
/// **Expressing everything as scalars keeps the shader branchless.** Two of
/// the properties below — `bleedBPhase` and `upperCoupling` — encode what
/// would otherwise be per-state special cases, so `Void.metal` has no
/// `if (state == …)` anywhere.
///
/// **Which numbers have a source and which are invented.** `period` for idle
/// (5.4 s) and listening (1.5 s) is `design-language.md` §7's own table.
/// Speaking's 0.42 s is `Core.metal`'s shipped pulse period. Everything
/// else — thinking's 12 s and its drift magnitude, listening's spread
/// factor, and all four amplitude ranges — is this sub-phase's invention,
/// recorded as such in the spec's §13. They are starting values for the
/// tuning pass, which is why they are all in one file.
public struct CoreMotion: Sendable, Equatable {
    /// Seconds for one full cycle of the state's own cadence.
    public let period: Double
    /// The bleeds' strength at the bottom of the cycle, as a multiplier
    /// where 1.0 is the void exactly as 2b-ii ships it.
    public let amplitudeLow: Double
    /// The bleeds' strength at the top of the cycle.
    public let amplitudeHigh: Double
    /// Multiplies the bleeds' Gaussian exponent, so **larger is tighter**.
    /// Listening is the only state that is not 1.0 — §4's "rings tighten",
    /// translated from a ring to a room.
    public let spreadFactor: Double
    /// How far the bleed centres travel, in uv units. Thinking only.
    public let driftAmplitude: Double
    /// Seconds for one full circuit of that drift. Zero when there is no
    /// drift; `Void.metal` guards the division.
    public let driftPeriod: Double
    /// Bleed B's phase offset as a fraction of a cycle. 0.5 — thinking's
    /// value — puts the two bleeds in antiphase so they trade dominance,
    /// which is what reads as turnover rather than as a faster breath.
    public let bleedBPhase: Double
    /// How much of the cycle's amplitude the upper-right bleed takes.
    /// 1 everywhere except speaking, where it is 0: the 0.42 s pulse then
    /// modulates only the lower bleed, so the room speaks from the bottom
    /// edge the voice and the thought thread already occupy and no large
    /// peripheral area flickers at speech rate. This is the strobe answer,
    /// and it is geometric rather than a small constant.
    public let upperCoupling: Double
    /// What `MTKView.preferredFramesPerSecond` is set to while this state is
    /// current and the pointer is at rest.
    public let restingFrameRate: Int

    /// Frames drawn in one full cycle at the resting rate. The floor is 25;
    /// below that a cycle reads as stepping rather than as motion.
    public var framesPerCycle: Double { Double(restingFrameRate) * period }

    public static func forState(_ state: CoreState) -> CoreMotion {
        switch state {
        case .idle:
            // Present but asleep: the lowest ceiling of the four, and the
            // slowest cadence. 15 fps is 81 frames per breath, and safe on a
            // slow luminance ramp because the per-frame delta of a 5.4 s sine
            // is far below an 8-bit quantisation step — and because
            // `Void.metal`'s grain is a hash of position only, with no time
            // term, so it cannot shimmer or alias against a low rate.
            return CoreMotion(
                period: 5.4, amplitudeLow: 0.55, amplitudeHigh: 0.67,
                spreadFactor: 1.0, driftAmplitude: 0, driftPeriod: 0,
                bleedBPhase: 0, upperCoupling: 1, restingFrameRate: 15)
        case .listening:
            // The brightest state at rest, and the only one that tightens.
            return CoreMotion(
                period: 1.5, amplitudeLow: 0.95, amplitudeHigh: 1.25,
                spreadFactor: 1.35, driftAmplitude: 0, driftPeriod: 0,
                bleedBPhase: 0, upperCoupling: 1, restingFrameRate: 30)
        case .thinking:
            // 12 s has no precedent anywhere. `Core.metal` spun at ~28.6 s
            // (`time * 0.22` rad/s), which the probe found too slow to read
            // as motion at all once translated from a rotating gradient on a
            // small object to a brightness swing across two large bleeds.
            return CoreMotion(
                period: 12.0, amplitudeLow: 0.30, amplitudeHigh: 1.00,
                spreadFactor: 1.0, driftAmplitude: 0.04, driftPeriod: 12.0,
                bleedBPhase: 0.5, upperCoupling: 1, restingFrameRate: 15)
        case .speaking:
            // 120 is asked for and 60 is what this machine's panels give, so
            // this lands at 25.2 frames per pulse here — exactly at the floor.
            // That is a real constraint on shortening the period later, and
            // it is recorded rather than left to be discovered.
            return CoreMotion(
                period: 0.42, amplitudeLow: 0.85, amplitudeHigh: 1.00,
                spreadFactor: 1.0, driftAmplitude: 0, driftPeriod: 0,
                bleedBPhase: 0, upperCoupling: 0, restingFrameRate: 120)
        }
    }
}

/// How brightly the lower bleed lifts where §9's thought thread meets the
/// bottom edge — the coupling that makes the room look like it is giving
/// birth to the thread rather than merely hosting it.
///
/// **The most invented thing in this sub-phase**, and the spec says so:
/// nothing in `design-language.md` describes a locally-modulated bleed. It
/// lives here rather than in the shader for the same reason `CoreMotion`
/// does — a decay curve buried in Metal is a decay curve nobody can test.
public enum ThreadLift {
    /// How long the glow takes to fade after the last row arrives. Matched
    /// to nothing in particular; long enough that the glow fades with the
    /// thread rather than snapping off with it.
    public static let decaySeconds: Double = 0.6

    public static func value(
        hasRows: Bool, isTurnInFlight: Bool, secondsSinceLastRow: Double
    ) -> Double {
        guard hasRows else { return 0 }
        if isTurnInFlight { return 1 }
        // `max(_:0)` because `Date` can step backwards across an NTP
        // correction, and a negative elapsed time would otherwise produce a
        // lift above 1 and blow the bleed out.
        let elapsed = max(secondsSinceLastRow, 0)
        guard elapsed < decaySeconds else { return 0 }
        return 1 - elapsed / decaySeconds
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter CoreMotion`
Expected: PASS, 12 tests.

- [ ] **Step 5: Run the whole suite, to prove nothing else moved**

Run: `make app-test`
Expected: PASS. The count rises by 12 from 2b-ii's 276 to 288.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Visual/CoreMotion.swift app/Tests/WakilKitTests/CoreMotionTests.swift
git commit -m "2b-iv Task 1: CoreMotion and ThreadLift — the room's numbers, in one testable file"
```

---

## Task 2: `Void.metal` takes motion, and `VoidView` draws continuously

The shader stops being static. `VoidUniforms` moves into `WakilKit` so the wire format
itself becomes testable, which is also what makes the layout guard possible.

**Files:**
- Create: `app/Sources/WakilKit/Visual/VoidUniforms.swift`
- Create: `app/Tests/WakilKitTests/VoidUniformsTests.swift`
- Modify: `app/Shaders/Void.metal`
- Modify: `app/Sources/WakilApp/VoidView.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift` (pass `state` to `VoidView`)
- Modify: `app/Sources/WakilApp/Capture.swift` (use the moved struct; keep it building)

**Interfaces:**
- Consumes: `CoreMotion.forState(_:)`, `VoidPalette`, `CoreState` from Task 1 and 2b-ii.
- Produces:
  - `VoidUniforms.init(resolution:palette:parallax:time:motion:threadAnchorX:threadLift:ambientScale:)`
  - `VoidView(palette:state:parallax:)` — the `state` parameter is new.

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/WakilKitTests/VoidUniformsTests.swift`:

```swift
import Testing
import simd
@testable import WakilKit

/// **The layout guard.** `setFragmentBytes` is a raw memory copy with no
/// schema, so `VoidUniforms` and `Void.metal`'s struct must agree byte for
/// byte. Metal's `float3` is 16-byte aligned and 16 bytes long and Swift's
/// `SIMD3<Float>` matches, which is why the two `float3`s sit where they do.
/// A `float3` appended *after* the run of plain floats would silently repad
/// the struct on one side only and corrupt every field after it.
///
/// The rule this enforces: **every `SIMD3` comes first, and every field
/// after the last one is a plain `Float` or `SIMD2<Float>`.** If this test
/// fails, do not update the number — work out which field broke the rule.
@Test func theWireFormatsLayoutIsPinned() {
    #expect(MemoryLayout<VoidUniforms>.stride == 112)
    #expect(MemoryLayout<VoidUniforms>.alignment == 16)
}

/// The environment owns the hue and the agent owns the movement (spec §2).
/// The palette's two colours must reach the shader untouched no matter what
/// state the room is in — if a state could tint them, the split has broken.
@Test func stateNeverTouchesTheBleedColours() {
    let production = VoidPalette.forEnvironment("production")
    for state in CoreState.allCases {
        let uniforms = VoidUniforms(
            resolution: SIMD2(900, 620), palette: production, parallax: .zero,
            time: 3.0, motion: CoreMotion.forState(state),
            threadAnchorX: 0.5, threadLift: 0, ambientScale: 1)
        #expect(uniforms.bleedA == SIMD3(Float(production.bleedA.r),
                                         Float(production.bleedA.g),
                                         Float(production.bleedA.b)))
        #expect(uniforms.bleedB == SIMD3(Float(production.bleedB.r),
                                         Float(production.bleedB.g),
                                         Float(production.bleedB.b)))
    }
}

/// Every motion field arrives at the shader as the `CoreMotion` gave it.
@Test func theMotionFieldsAreCarriedThroughUnchanged() {
    let motion = CoreMotion.forState(.thinking)
    let uniforms = VoidUniforms(
        resolution: SIMD2(900, 620), palette: VoidPalette.forEnvironment("staging"),
        parallax: .zero, time: 1.0, motion: motion,
        threadAnchorX: 0.25, threadLift: 0.5, ambientScale: 0.4)
    #expect(uniforms.period == Float(motion.period))
    #expect(uniforms.amplitudeLow == Float(motion.amplitudeLow))
    #expect(uniforms.amplitudeHigh == Float(motion.amplitudeHigh))
    #expect(uniforms.spreadFactor == Float(motion.spreadFactor))
    #expect(uniforms.driftAmplitude == Float(motion.driftAmplitude))
    #expect(uniforms.driftPeriod == Float(motion.driftPeriod))
    #expect(uniforms.bleedBPhase == Float(motion.bleedBPhase))
    #expect(uniforms.upperCoupling == Float(motion.upperCoupling))
    #expect(uniforms.threadAnchorX == 0.25)
    #expect(uniforms.threadLift == 0.5)
    #expect(uniforms.ambientScale == 0.4)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter VoidUniforms`
Expected: FAIL to compile, `cannot find 'VoidUniforms' in scope`.

- [ ] **Step 3: Create the wire format in `WakilKit`**

Create `app/Sources/WakilKit/Visual/VoidUniforms.swift`:

```swift
import simd

/// The Swift half of `Void.metal`'s `VoidUniforms`. Field order and types
/// must match it exactly, because `setFragmentBytes` is a raw memory copy
/// with no schema.
///
/// **It lives in `WakilKit`, not beside the view that sends it**, so it can
/// be tested: a test target cannot import an executable target, and the wire
/// format's layout is precisely the kind of thing worth a test. `VoidView`
/// and `Capture.swift` both use this one declaration; there is no second
/// hand-copy of a memory layout anywhere.
///
/// **Layout rule, enforced by `VoidUniformsTests`:** every `SIMD3<Float>`
/// comes first, and every field after the last one is a plain `Float` or a
/// `SIMD2<Float>`. `SIMD3<Float>` is 16-byte aligned on both sides; appending
/// one after the run of floats below would repad the struct on one side only.
public struct VoidUniforms: Sendable, Equatable {
    public var resolution: SIMD2<Float>
    /// The bleed rising from below. **Environment, never state** (spec §2).
    public var bleedA: SIMD3<Float>
    /// The bleed from the upper right. **Environment, never state.**
    public var bleedB: SIMD3<Float>
    public var parallax: SIMD2<Float>
    /// Seconds since the view appeared.
    public var time: Float
    public var period: Float
    public var amplitudeLow: Float
    public var amplitudeHigh: Float
    public var spreadFactor: Float
    public var driftAmplitude: Float
    public var driftPeriod: Float
    public var bleedBPhase: Float
    public var upperCoupling: Float
    /// Where §9's thread meets the bottom edge, in uv. Measured from the
    /// thread's own laid-out frame, never assumed.
    public var threadAnchorX: Float
    public var threadLift: Float
    /// 1 normally; lower while a pane is maximized. Multiplies the **bleeds
    /// only** — never the field, the vignette or the grain — so a maximized
    /// window reads as the same room with the lights down rather than as a
    /// different, flatter surface.
    public var ambientScale: Float

    public init(
        resolution: SIMD2<Float>,
        palette: VoidPalette,
        parallax: SIMD2<Float>,
        time: Float,
        motion: CoreMotion,
        threadAnchorX: Float,
        threadLift: Float,
        ambientScale: Float
    ) {
        self.resolution = resolution
        self.bleedA = SIMD3(Float(palette.bleedA.r), Float(palette.bleedA.g), Float(palette.bleedA.b))
        self.bleedB = SIMD3(Float(palette.bleedB.r), Float(palette.bleedB.g), Float(palette.bleedB.b))
        self.parallax = parallax
        self.time = time
        self.period = Float(motion.period)
        self.amplitudeLow = Float(motion.amplitudeLow)
        self.amplitudeHigh = Float(motion.amplitudeHigh)
        self.spreadFactor = Float(motion.spreadFactor)
        self.driftAmplitude = Float(motion.driftAmplitude)
        self.driftPeriod = Float(motion.driftPeriod)
        self.bleedBPhase = Float(motion.bleedBPhase)
        self.upperCoupling = Float(motion.upperCoupling)
        self.threadAnchorX = threadAnchorX
        self.threadLift = threadLift
        self.ambientScale = ambientScale
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter VoidUniforms`
Expected: PASS, 3 tests.

If `theWireFormatsLayoutIsPinned` fails, print the real value with a scratch
`#expect(MemoryLayout<VoidUniforms>.stride == 0)` and read the number out of the failure
message — then confirm the field order matches the rule in the doc comment before changing
the expectation. A mismatch is far more likely to be a misplaced field than a wrong number.

- [ ] **Step 5: Rewrite `Void.metal`'s fragment shader**

Replace the `VoidUniforms` struct and the whole `void_fragment` function in
`app/Shaders/Void.metal`. The vertex function and `grain` are unchanged.

```metal
struct VoidUniforms {
    float2 resolution;
    float3 bleedA;          // environment — never touched by state
    float3 bleedB;          // environment — never touched by state
    float2 parallax;
    float  time;
    float  period;
    float  amplitudeLow;
    float  amplitudeHigh;
    float  spreadFactor;
    float  driftAmplitude;
    float  driftPeriod;
    float  bleedBPhase;
    float  upperCoupling;
    float  threadAnchorX;
    float  threadLift;
    float  ambientScale;
};

fragment float4 void_fragment(VoidVertex in [[stage_in]],
                              constant VoidUniforms &u [[buffer(0)]]) {
    float2 uv = in.uv + u.parallax;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);

    // The field: #030408 at the top, #070812 at the bottom.
    float3 field = mix(float3(0.012, 0.016, 0.031),
                       float3(0.027, 0.031, 0.071), uv.y);

    // **The room is the Core.** There is no state branch here and there is
    // no sphere anywhere: `CoreMotion` resolved the state to numbers in
    // Swift, and this function only applies them.
    float phase = 6.28318 * u.time / max(u.period, 1e-4);
    float ampA = mix(u.amplitudeLow, u.amplitudeHigh, 0.5 + 0.5 * sin(phase));
    float ampB = mix(u.amplitudeLow, u.amplitudeHigh,
                     0.5 + 0.5 * sin(phase + 6.28318 * u.bleedBPhase));
    // Speaking passes upperCoupling = 0, which holds the upper bleed at its
    // resting strength while only the lower one pulses — so a 0.42s cadence
    // never reaches a large peripheral area. Every other state passes 1.
    ampB = mix(1.0, ampB, u.upperCoupling);

    // Thinking's turnover. The two bleeds drift in *opposite* directions,
    // which doubles the apparent movement for a given displacement and keeps
    // the field's centre of mass still — a room turning over rather than a
    // room sliding. `max(_, 1e-4)`: a state with no drift passes a zero
    // period, and a division by zero here is a NaN that blanks the frame.
    float dphase = 6.28318 * u.time / max(u.driftPeriod, 1e-4);
    float2 drift = u.driftAmplitude * float2(cos(dphase), sin(dphase));

    // Violet from below, centred under the frame so only its upper arc
    // shows; cool blue from the upper right, off-canvas for the same
    // reason. Both are wide and weak — §1's "light is information" means
    // an atmospheric bleed must never read as an object.
    float2 a = (uv - float2(0.5, 1.18) - drift) * float2(aspect, 1.0);
    float2 b = (uv - float2(1.10, -0.10) + drift) * float2(aspect, 1.0);
    float fa = exp(-dot(a, a) * 3.2 * u.spreadFactor) * 0.55 * ampA;
    float fb = exp(-dot(b, b) * 4.0 * u.spreadFactor) * 0.38 * ampB;

    // §9's thread and §12's waveform anchor to the bottom edge, and the
    // bleed answers them: it lifts locally where the thread meets it, so
    // the room reads as giving birth to the thread rather than hosting it.
    float2 t = (uv - float2(u.threadAnchorX, 1.06)) * float2(aspect, 1.0);
    fa += exp(-dot(t, t) * 26.0) * 0.30 * u.threadLift;

    float3 colour = field + u.bleedA * fa + u.bleedB * fb;
    // §10's "the Core fades back" while a pane is maximized, with no Core to
    // fade: the bleeds recede toward the bare field and the field itself,
    // the vignette and the grain are untouched.
    colour = mix(field, colour, u.ambientScale);

    // Vignette, so the frame's corners fall away and nothing reads as a
    // rectangle with edges.
    float2 v = (uv - 0.5) * float2(aspect, 1.0);
    colour *= 1.0 - clamp(dot(v, v) * 0.35, 0.0, 0.35);

    colour += (grain(in.position.xy) - 0.5) * 0.14 * 0.06;
    return float4(colour, 1.0);
}
```

- [ ] **Step 6: Make `VoidView` continuous, and drive it from `CoreMotion`**

In `app/Sources/WakilApp/VoidView.swift`:

Replace the type's doc comment and add the `state` property:

```swift
/// The void, drawn in Metal behind everything — and, since 2b-iv, the Core
/// itself (spec §4).
///
/// **Continuous, where it used to be paused.** 2b-ii drew this layer only
/// when the environment, the size or the parallax changed, and put the
/// breathing on a second `MTKView` in front of the panes. That layer is
/// gone: the room carries the four states now, so this one has a clock.
///
/// **This is cheaper than what it replaces, not dearer.** An idle 2b-ii
/// window drew zero void frames and a *continuous 60 fps Core* of a much
/// heavier shader — iridescence, two tick rings, a specular, rim occlusion.
/// An idle 2b-iv window draws 15 fps of this one. Deleting the second layer
/// pays for the breath outright, with change. (`void-as-core-probe.md` §5
/// says the opposite; it compared this layer against itself and ignored the
/// layer beside it. Corrected in the spec's §5.)
struct VoidView: NSViewRepresentable {
    let palette: VoidPalette
    /// Which of §4's four states the room is in. Sets both what the shader
    /// draws and how often it is asked to.
    let state: CoreState
    let parallax: CGSize
```

Replace `makeNSView`'s pause configuration:

```swift
    func makeNSView(context: Context) -> MTKView {
        // `MTKView(frame:device:)` rather than `MTKView()`: MTKView declares
        // its own designated initialiser, so NSView's `init(frame:)` is not
        // inherited and a bare `MTKView()` does not compile.
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = CoreMotion.forState(state).restingFrameRate
        // Opaque: nothing is behind the void, and a transparent drawable
        // would composite against the window's background for no reason.
        view.layer?.isOpaque = true
        return view
    }
```

Replace `updateNSView` entirely:

```swift
    /// **Sets the frame rate from the state's own cadence** (spec §5). Each
    /// state buys the smoothness its period needs and no more: idle's 5.4 s
    /// breath at 15 fps is 81 frames a cycle, speaking's 0.42 s pulse at 120
    /// is 50. `CoreMotion`'s tests hold the floor at 25 frames per cycle.
    ///
    /// The old guard here — "mark needsDisplay only when something actually
    /// changed", 2b-ii's final review Finding 4 — is gone with the paused
    /// policy it served. The equivalent comparison now decides whether to
    /// *retune the display link*, which is the one thing here that is not
    /// free to do every time SwiftUI re-evaluates the window's body.
    func updateNSView(_ view: MTKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.palette = palette
        coordinator.parallax = parallax
        if coordinator.state != state {
            coordinator.state = state
            view.preferredFramesPerSecond = CoreMotion.forState(state).restingFrameRate
        }
    }
```

In `Coordinator`, delete the nested `VoidUniforms` struct (it now comes from `WakilKit`)
and add the state:

```swift
        var palette = VoidPalette.forEnvironment("")
        var state: CoreState = .idle
        var parallax: CGSize = .zero
        private let start = CFAbsoluteTimeGetCurrent()
```

Replace the uniform construction in `draw(in:)` (the comment block above it about points
versus pixels stays exactly as it is):

```swift
            var uniforms = VoidUniforms(
                resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                palette: palette,
                parallax: SIMD2(
                    Float(parallax.width) / boundsWidth,
                    Float(parallax.height) / boundsHeight),
                time: Float(CFAbsoluteTimeGetCurrent() - start),
                motion: CoreMotion.forState(state),
                threadAnchorX: 0.5,
                threadLift: 0,
                ambientScale: 1)
```

`threadAnchorX`, `threadLift` and `ambientScale` are inert here and Tasks 4 and 5 drive
them. They are in the struct from the start so the wire format is written — and its layout
test written — exactly once.

- [ ] **Step 7: Pass the state in from `WakilWindow`**

In `app/Sources/WakilApp/WakilWindow.swift`, in `body`'s `ZStack`:

```swift
            VoidView(
                palette: VoidPalette.forEnvironment(session?.model.environment ?? ""),
                state: session?.model.coreState ?? .idle,
                parallax: CGSize(width: farOffset.x, height: farOffset.y))
                .ignoresSafeArea()
```

Leave the `CoreView(...)` block below it alone. Both layers draw for this task and the
next; Task 4 deletes the Core.

- [ ] **Step 8: Keep `Capture.swift` building**

In `app/Sources/WakilApp/Capture.swift`, delete the `VoidUniforms` typealias line (the
struct is now `WakilKit`'s, imported already) and keep the `CoreUniforms` one:

```swift
    typealias CoreUniforms = CoreView.Coordinator.CoreUniforms
```

Replace **both** `voidUniforms` constructions — the one in `render` and the one in
`renderScaled` — with the new initialiser. In `render`:

```swift
        var voidUniforms = VoidUniforms(
            resolution: resolution, palette: palette, parallax: .zero, time: time,
            motion: CoreMotion.forState(state ?? .idle),
            threadAnchorX: 0.5, threadLift: 0, ambientScale: 1)
```

In `renderScaled`:

```swift
        var voidUniforms = VoidUniforms(
            resolution: scaledResolution, palette: staging, parallax: .zero, time: time,
            motion: CoreMotion.forState(.thinking),
            threadAnchorX: 0.5, threadLift: 0, ambientScale: 1)
```

`render`'s `void-<environment>.png` captures pass `state: nil`, which now means the room is
photographed idle rather than static. Change that loop's `time` from `0` to `2.0`, matching
the reason already given a few lines above it — a zero crossing photographs the breath at
its dimmest:

```swift
        guard render(palette: VoidPalette.forEnvironment(name), state: nil, time: 2.0) != nil,
```

- [ ] **Step 9: Build and run the whole suite**

Run: `make app-test`
Expected: PASS, 291 tests (288 from Task 1, plus 3).

- [ ] **Step 10: Look at it**

Run: `make captures && open .context/2b-ii`
Expected: six PNGs. `void-staging.png` and `void-production.png` now show the room at
`time = 2.0` rather than static — the bleeds are dimmer than 2b-ii's, because idle's
amplitude ceiling is 0.67. The four `core-*.png` still have the sphere over the room.

Then run the app and watch it: `cd app && swift run WakilApp`. The room should breathe
slowly. **Both the room and the sphere are breathing at this commit** — that is expected
and Task 4 removes the sphere.

- [ ] **Step 11: Commit**

```bash
git add app/Sources/WakilKit/Visual/VoidUniforms.swift \
        app/Tests/WakilKitTests/VoidUniformsTests.swift \
        app/Shaders/Void.metal app/Sources/WakilApp/VoidView.swift \
        app/Sources/WakilApp/WakilWindow.swift app/Sources/WakilApp/Capture.swift
git commit -m "2b-iv Task 2: the room breathes — Void.metal takes motion, VoidView takes a clock"
```

---

## Task 3: The frame-rate policy — the occlusion pause and the parallax bump

Two power/responsiveness behaviours that the resting rate alone does not give.

**Files:**
- Modify: `app/Sources/WakilApp/VoidView.swift`

**Interfaces:**
- Consumes: `CoreMotion.forState(_:)`, `VoidView.Coordinator` from Task 2.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Move the occlusion pause over from `CoreView`**

`CoreView.Coordinator` has `observedWindow`, `occlusionObserver`, `deinit`,
`observeOcclusion(of:)` and `applyOcclusion(of:to:)`. Copy all five into
`VoidView.Coordinator` **verbatim, including every doc comment**, changing only the
`CoreView:` prefix in any message to `VoidView:`. Do not paraphrase the comments — they
record why the signal is `NSWindow.occlusionState` rather than app-activation, and that
reasoning transfers unchanged.

Add `import AppKit` to the top of `VoidView.swift` if `MetalKit` does not already bring
`NSWindow` into scope; `CoreView.swift` compiles with only `MetalKit`, `WakilKit` and
`SwiftUI`, so it should not be needed.

Prepend one paragraph to `observeOcclusion`'s doc comment:

```swift
        /// **Inherited from `CoreView`, which 2b-iv deletes** (spec §5).
        /// Dropping it would have deleted a working, shipped power-saving fix
        /// (2b-ii final review Finding 3) as collateral damage of deleting
        /// the file it happened to live in, which is not a decision anybody
        /// made. The reasoning below is that review's, unchanged — only the
        /// layer it guards is different.
```

Call it from `updateNSView`, alongside the rest:

```swift
        coordinator.observeOcclusion(of: view)
```

- [ ] **Step 2: Add the parallax bump**

The surviving layer carries the far plane's parallax, which follows the pointer. 2b-ii
redrew it at pointer-event rate; a flat 15 fps would visibly step against §7's
"weightless". So the resting rate applies at rest, and the pointer buys full rate while it
moves.

In `VoidView.Coordinator`, add:

```swift
        /// How long full rate is held after a parallax change. Long enough
        /// to cover the gap between two pointer-moved events during a slow
        /// drag, short enough that a window nobody is touching is back at
        /// its resting rate before anyone notices.
        static let parallaxBoostSeconds: Double = 0.25
        private var parallaxBoostUntil: CFAbsoluteTime = 0
```

Add the method:

```swift
        /// **The one place 2b-iv could regress against 2b-ii, and does not.**
        /// A moving cursor means somebody is looking at this window, so it
        /// gets full rate; a still cursor over a still window is the idle
        /// case worth saving. Called only when the parallax actually
        /// changed — `updateNSView` fires on every `WakilWindow` body
        /// re-evaluation, including ones where nothing visual moved, and
        /// treating those as pointer motion would hold full rate forever
        /// while a session was merely streaming events.
        func boostForParallax(_ view: MTKView) {
            parallaxBoostUntil = CFAbsoluteTimeGetCurrent() + Self.parallaxBoostSeconds
            view.preferredFramesPerSecond = 120
        }

        /// Drops back to the state's resting rate once the boost has run
        /// out. Called from `draw(in:)`, because that is the only thing that
        /// happens on a clock — a timer would be a second clock for no
        /// reason on a view that already has one.
        func expireParallaxBoost(_ view: MTKView) {
            guard parallaxBoostUntil > 0, CFAbsoluteTimeGetCurrent() >= parallaxBoostUntil else { return }
            parallaxBoostUntil = 0
            view.preferredFramesPerSecond = CoreMotion.forState(state).restingFrameRate
        }
```

Update `updateNSView` to detect the change before overwriting it:

```swift
    func updateNSView(_ view: MTKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.palette = palette
        if coordinator.parallax != parallax {
            coordinator.parallax = parallax
            coordinator.boostForParallax(view)
        }
        if coordinator.state != state {
            coordinator.state = state
            view.preferredFramesPerSecond = CoreMotion.forState(state).restingFrameRate
        }
        coordinator.observeOcclusion(of: view)
    }
```

Note the ordering: a state change after a boost wins and resets the rate immediately. That
is correct — a state change is a bigger event than a mouse twitch, and the next parallax
event re-boosts within one frame anyway.

Call the expiry at the top of `draw(in:)`, before the guard:

```swift
        func draw(in view: MTKView) {
            expireParallaxBoost(view)
            guard let drawable = view.currentDrawable,
```

- [ ] **Step 3: Build and run the suite**

Run: `make app-test`
Expected: PASS, 291 tests. No test covers this task directly — `MTKView`,
`NSWindow.occlusionState` and the display link all need a display, which is why the spec's
§10 puts both behaviours in the human runbook rather than in `WakilKitTests`.

- [ ] **Step 4: Verify by hand, and record what you saw**

Run `cd app && swift run WakilApp` and check three things:

1. Move the pointer across the window in a slow arc. The room's bleeds should slide
   smoothly, with no visible stepping. Stop moving; the breath continues.
2. Put another window fully in front of Wakil, then bring Wakil back. Nothing should be
   visibly wrong on return — no frozen frame, no jump.
3. Leave Wakil visible but click another app so Wakil loses focus. **The room must keep
   breathing.** Visibility, not focus, is the bar — a room that freezes when you click away
   reads as "Wakil stopped".

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/VoidView.swift
git commit -m "2b-iv Task 3: carry the occlusion pause onto the surviving layer, and boost the rate while the pointer moves"
```

---

## Task 4: Delete the Core, and let the room take the maximize fade

**Files:**
- Delete: `app/Sources/WakilApp/CoreView.swift`
- Delete: `app/Shaders/Core.metal`
- Modify: `app/Sources/WakilKit/Visual/CoreState.swift`
- Modify: `app/Tests/WakilKitTests/CoreStateTests.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`
- Modify: `app/Sources/WakilApp/VoidView.swift`
- Modify: `app/Sources/WakilApp/Capture.swift`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `VoidUniforms.ambientScale` from Task 2.
- Produces: `VoidView(palette:state:parallax:isMaximized:)` — the `isMaximized` parameter
  is new and Task 5 does not change it.

- [ ] **Step 1: Delete the two files**

```bash
git rm app/Sources/WakilApp/CoreView.swift app/Shaders/Core.metal
```

- [ ] **Step 2: Remove `shaderIndex` and the test that pinned it**

In `app/Sources/WakilKit/Visual/CoreState.swift`, delete the `shaderIndex` property and its
doc comment entirely. Then replace the type's doc comment, which describes a shader that no
longer exists:

```swift
/// Which of `design-language.md` §4's four states Wakil is in.
///
/// **Since 2b-iv the void carries these, not a sphere.** §4's "the Core" now
/// means Wakil's presence rather than an object, and the room expresses it —
/// `CoreMotion` turns each case below into periods, amplitudes and a frame
/// rate. The enum reaches Metal only through those numbers, which is why
/// there is no longer a `shaderIndex` here: the shader has no state to
/// branch on.
///
/// **All four are rendered; two are ever set.** Listening and speaking
/// belong to voice, which is 2d, and driving them from proxies available
/// today — assistant text arriving is not speech, a focused prompt field is
/// not listening — would invent semantics 2d then has to unpick.
public enum CoreState: String, Sendable, Equatable, CaseIterable {
```

In `app/Tests/WakilKitTests/CoreStateTests.swift`, delete `theShaderIndexIsStable` and its
doc comment. Update the surviving `allFourStatesExistAndHaveStableRawValues` doc comment's
reference from "spec §4.1" to:

```swift
/// 2b-ii spec §4.1, still true under 2b-iv: four states are rendered and the
/// app sets two. The other two exist so 2d wires a microphone into a
/// renderer that is already there.
```

- [ ] **Step 3: Add the eased ambient scale to `VoidView`**

The Core's maximize fade was `.opacity(isMaximized ? 0.12 : 1)` with a 450 ms ease — a
SwiftUI modifier on a view that no longer exists. `NSViewRepresentable` does not animate
its inputs, so the ease moves into the coordinator, which is drawing on a clock anyway.

Add the parameter:

```swift
    /// §10: "the rail and Core fade back" when a pane is maximized. With no
    /// Core, the room defers instead — its bleeds recede toward the bare
    /// field while the motion continues underneath, so it reads as the same
    /// room with the lights down. Not to zero, which would read as a bug
    /// rather than as deference.
    let isMaximized: Bool
```

In `Coordinator`:

```swift
        /// The bleed strength while a pane is maximized. `design-language.md`
        /// §10's deference, as a multiplier on the bleeds only.
        static let maximizedAmbientScale: Float = 0.4
        /// Where the ease is now. `NSViewRepresentable` does not animate its
        /// inputs, so the 450 ms `.easeOut` that used to sit on `CoreView`'s
        /// `.opacity` modifier is a per-frame approach in `draw(in:)`
        /// instead — which this view can do cheaply because, unlike the
        /// paused layer it replaces, it is already drawing on a clock.
        static let ambientEaseSeconds: Double = 0.45
        var ambientTarget: Float = 1
        private var ambientScale: Float = 1
        private var lastDrawTime: CFAbsoluteTime = 0
```

Add to `draw(in:)`, immediately after `expireParallaxBoost(view)`:

```swift
            let now = CFAbsoluteTimeGetCurrent()
            // First frame: no previous timestamp, so snap rather than
            // integrate against a nonsense delta.
            let delta = lastDrawTime == 0 ? Self.ambientEaseSeconds : now - lastDrawTime
            lastDrawTime = now
            let step = Float(min(max(delta / Self.ambientEaseSeconds, 0), 1))
            ambientScale += (ambientTarget - ambientScale) * step
```

and pass it in the uniforms, replacing the inert `ambientScale: 1`:

```swift
                ambientScale: ambientScale,
```

Set the target in `updateNSView`:

```swift
        coordinator.ambientTarget = isMaximized ? Coordinator.maximizedAmbientScale : 1
```

- [ ] **Step 4: Remove the Core from the window**

In `app/Sources/WakilApp/WakilWindow.swift`, delete the entire `CoreView(...)` block from
the `ZStack` — the view, `.ignoresSafeArea()`, `.allowsHitTesting(false)`, `.opacity(...)`
and `.animation(...)`. Pass `isMaximized` to the void instead:

```swift
            VoidView(
                palette: VoidPalette.forEnvironment(session?.model.environment ?? ""),
                state: session?.model.coreState ?? .idle,
                parallax: CGSize(width: farOffset.x, height: farOffset.y),
                isMaximized: isMaximized)
                .ignoresSafeArea()
```

`isMaximized` and `nearOffset` both stay: `isMaximized` is still read by `Rail.swift`, and
Task 5 gives `nearOffset` its new consumer. Do not delete either.

Update the type's doc comment, which still describes 2b-i's layer stack — replace the
sentence beginning "2b-i adds the canvas" with:

```swift
/// 2b-ii added the void, the planes, the Core and the thought thread; 2b-iv
/// deleted the Core as an object and gave its four states to the room, so
/// there is one Metal layer here rather than two and nothing is drawn in
/// front of a pane at all.
```

- [ ] **Step 5: Collapse `Capture.swift` to one pipeline**

- Delete the `corePipeline` from the `guard` and change it to
  `guard let voidPipeline = pipeline("void_vertex", "void_fragment", blending: false) else {`.
- Delete the `blending:` parameter from `pipeline(_:_:blending:)` and its whole `if blending`
  body — nothing blends now. Update its two call sites.
- Delete the `typealias CoreUniforms` line.
- In `render`, delete the `if let state { … }` block that drew the Core, and change the
  signature's `state: CoreState?` to `state: CoreState` (there is no "void only" case any
  more — the room is always in some state).
- Change the per-state loop's filenames from `core-` to `room-`:

```swift
    // One PNG per state — of the room, which is now the Core. time = 2.0
    // rather than 0, so idle is not caught at a zero crossing of its 5.4 s
    // breath and photographed at its dimmest.
    for state in CoreState.allCases {
        guard render(palette: staging, state: state, time: 2.0) != nil,
              writePNG(to: "\(directory)/room-\(state.rawValue).png") else {
            FileHandle.standardError.write(Data("wakil --capture: failed on room-\(state.rawValue)\n".utf8))
            return 1
        }
        print("wrote room-\(state.rawValue).png")
    }
```

- In the per-environment loop, pass `state: .idle` where it passed `state: nil`.
- In `renderScaled`, delete the `coreUniforms` construction and the two encoder calls that
  drew the Core.
- Change both measurement `print`s from `"core gpu"` to `"room gpu"`, and update the
  function's doc comment: it opens "Renders every Core state and every void palette
  offscreen"; the Core is the room now, and the paragraph about `CoreView.swift`'s measured
  backing scale should cite `VoidView.swift` instead, since that comment moved nowhere but
  the file it named is gone.

- [ ] **Step 6: Update the Makefile**

In the `shaders` target, drop `Core.metal` and the two core symbols:

```make
shaders:
	xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal
	@symbols="$$(xcrun metal-nm app/Sources/WakilApp/default.metallib)"; \
	for fn in void_vertex void_fragment; do \
	    echo "$$symbols" | grep -q " T $$fn$$" || { \
	        echo "make shaders: default.metallib is missing function '$$fn' — check the .metal file is still named above"; \
	        exit 1; \
	    }; \
	done
```

In the `captures` target, write to this sub-phase's own directory:

```make
captures: app-build
	mkdir -p .context/2b-iv
	cd app && swift run WakilApp --capture ../.context/2b-iv
```

- [ ] **Step 7: Build and run the suite**

Run: `make app-test`
Expected: PASS, **290** tests — 291 from Task 3 minus `theShaderIndexIsStable`.

If the build fails with `cannot find 'CoreView' in scope`, something still references the
deleted layer. Find it: `grep -rn "CoreView\|core_vertex\|core_fragment\|shaderIndex" app/ Makefile`.
Expected output after this task: nothing.

- [ ] **Step 8: Look at it**

```bash
make captures && open .context/2b-iv
cd app && swift run WakilApp
```

Expected: four `room-*.png` with **no sphere in any of them**, plus the two environment
PNGs. In the running app the sphere is gone; the room breathes. Open a pane and maximize it
(⌘⏎) — the room should dim over about half a second and come back when you restore.

- [ ] **Step 9: Commit**

```bash
git add -A app/ Makefile
git commit -m "2b-iv Task 4: delete the Core sphere; the room takes the maximize fade"
```

---

## Task 5: Re-anchor the thought thread, and couple the bleed to it

**Files:**
- Modify: `app/Sources/WakilApp/WakilWindow.swift`
- Modify: `app/Sources/WakilApp/ThoughtThread.swift`
- Modify: `app/Sources/WakilApp/VoidView.swift`

**Interfaces:**
- Consumes: `ThreadLift.value(hasRows:isTurnInFlight:secondsSinceLastRow:)` from Task 1;
  `VoidUniforms.threadAnchorX` / `.threadLift` from Task 2; `Plane.near` (2b-ii,
  unmodified).
- Produces: `VoidView(palette:state:parallax:isMaximized:threadAnchorX:isTurnInFlight:lastRowAt:)`.

- [ ] **Step 1: Give the thread its plane treatment**

`ThoughtThread`'s doc comment already claims it is "on the near plane" and it applies no
plane treatment at all — no scale, no opacity, no blur, no offset. Deleting `CoreView` in
Task 4 left `Plane.near` with **no consumer anywhere in the codebase**. This backs the
claim and rescues the plane.

In `app/Sources/WakilApp/ThoughtThread.swift`, replace the doc comment's first paragraph:

```swift
/// §9's thought thread, on the near plane: agent progress rising out of the
/// bottom edge's glow, which is where §4's Core lives since 2b-iv. Completed
/// steps fade to dim green, the live step is brightest. This replaces
/// spinners and progress bars entirely.
///
/// **The plane treatment is applied here rather than claimed and skipped.**
/// Until 2b-iv this comment said "on the near plane" while the view carried
/// no scale, opacity, blur or offset, and `Plane.near`'s only real consumer
/// was `CoreView`. Deleting the Core would have orphaned the plane outright;
/// the thread takes it instead, which is what §3 always said it had.
```

Add a parallax parameter and the treatment. The `.blur` and `.opacity` are no-ops by value
for the near plane (0.0 and 1.0), applied anyway so the rule reads from the code rather
than from its absence — the same convention `WakilWindow`'s mid-plane canvas already uses:

```swift
struct ThoughtThread: View {
    let rows: [ThoughtRow]
    /// The near plane's offset — `WakilWindow.nearOffset`. Opposes the
    /// void's own parallax (`Plane.near.parallaxFactor` is -0.5), which is
    /// what makes the thread and the room it rises from read as two depths.
    let parallax: CGSize
```

and at the end of `body`, after `.allowsHitTesting(false)`:

```swift
        .scaleEffect(Plane.near.scale)
        .opacity(Plane.near.opacity)
        .blur(radius: Plane.near.blur)
        .offset(x: parallax.width, y: parallax.height)
```

- [ ] **Step 2: Move the thread to the bottom edge**

In `WakilWindow.loaded(_:)`, delete these three lines:

```swift
        // The thought thread (spec §9): agent progress rising out of the
        // Core, drawn from only the events that describe work — `.unknown`
        // frames never reach `model.thoughts` (`thoughtRow`).
        ThoughtThread(rows: model.thoughts)
```

Add state to `WakilWindow` for the anchor and the last row's arrival:

```swift
    /// Where §9's thread meets the bottom edge, in uv — what the void's
    /// local bleed lift is centred on.
    ///
    /// **Measured, never assumed.** A constant would silently drift the glow
    /// away from the thread the first time anybody changed this window's
    /// padding, and the drift would be invisible in a still.
    @State private var threadAnchorX: Double = 0.5
    /// When the thread last gained a row. Drives `ThreadLift`'s decay, so
    /// the glow fades with the thread rather than snapping off with it.
    @State private var lastRowAt: Date?
    @State private var lastRowCount = 0
```

In `body`'s `ZStack`, after the `VStack` and before nothing else (the Core's old position),
add the overlay:

```swift
            // §9's thread, anchored to the bottom edge — where §2's violet
            // bleed rises, and since 2b-iv where §4's Core is. It rises out
            // of the glow, and the glow answers it: `threadLift` below
            // brightens the bleed locally at `threadAnchorX`.
            ThoughtThread(
                rows: session?.model.thoughts ?? [],
                parallax: CGSize(width: nearOffset.x, height: nearOffset.y))
                .padding(.horizontal, 24)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { reportThreadAnchor(geometry) }
                        .onChange(of: geometry.frame(in: .named("window"))) { _, _ in
                            reportThreadAnchor(geometry)
                        }
                })
                .allowsHitTesting(false)
```

Name the coordinate space on the `ZStack`, immediately before `.frame(minWidth:…)`:

```swift
        .coordinateSpace(.named("window"))
```

Add the two helpers to `WakilWindow`:

```swift
    /// Converts the thread's laid-out frame into the uv the shader wants.
    /// Clamped, because a thread wider than the window — a long tool name in
    /// a narrow window — would otherwise centre the glow off-canvas.
    private func reportThreadAnchor(_ geometry: GeometryProxy) {
        let frame = geometry.frame(in: .named("window"))
        guard windowSize.width > 0 else { return }
        threadAnchorX = min(max(frame.midX / windowSize.width, 0), 1)
    }
```

and, on the `ZStack`, track new rows so the decay has a start time:

```swift
        .onChange(of: session?.model.thoughts.count ?? 0) { _, new in
            if new > lastRowCount { lastRowAt = Date() }
            lastRowCount = new
        }
```

- [ ] **Step 3: Feed the coupling to the shader**

Add three parameters to `VoidView`:

```swift
    /// Where §9's thread meets the bottom edge, in uv.
    let threadAnchorX: Double
    /// Whether a turn is in flight — `ThreadLift`'s "hold the glow up".
    let isTurnInFlight: Bool
    /// When the thread last gained a row, for `ThreadLift`'s decay.
    let lastRowAt: Date?
```

In `Coordinator`, mirror them:

```swift
        var threadAnchorX: Double = 0.5
        var isTurnInFlight = false
        var lastRowAt: Date?
```

and set them in `updateNSView`:

```swift
        coordinator.threadAnchorX = threadAnchorX
        coordinator.isTurnInFlight = isTurnInFlight
        coordinator.lastRowAt = lastRowAt
```

In `draw(in:)`, compute the lift per frame and replace the two inert uniform values.
**Per frame, not per update:** the decay is continuous and this view is already on a clock,
so a timer to drive it would be a second clock for no reason.

```swift
            let lift = ThreadLift.value(
                hasRows: lastRowAt != nil,
                isTurnInFlight: isTurnInFlight,
                secondsSinceLastRow: lastRowAt.map { -$0.timeIntervalSinceNow } ?? 0)
```

```swift
                threadAnchorX: Float(threadAnchorX),
                threadLift: Float(lift),
```

And pass them from `WakilWindow`:

```swift
            VoidView(
                palette: VoidPalette.forEnvironment(session?.model.environment ?? ""),
                state: session?.model.coreState ?? .idle,
                parallax: CGSize(width: farOffset.x, height: farOffset.y),
                isMaximized: isMaximized,
                threadAnchorX: threadAnchorX,
                isTurnInFlight: session?.model.coreState == .thinking,
                lastRowAt: lastRowAt)
                .ignoresSafeArea()
```

`coreState == .thinking` is the in-flight signal because `WindowModel.coreState` is
`CoreState.forTurn(inFlight:)` and thinking is the only state it returns for a live turn.

- [ ] **Step 4: Build and run the suite**

Run: `make app-test`
Expected: PASS, 290 tests. Unchanged — this task is all view layer, and the one piece with
a right answer (`ThreadLift`) was tested in Task 1.

- [ ] **Step 5: Verify by hand**

Run `cd app && swift run WakilApp`, type a message to the agent and send it.

1. The thread appears **at the bottom of the window**, not in the middle of the control
   stack.
2. The lower bleed brightens under the thread while the turn runs, and fades over about
   half a second after the last row.
3. Move the pointer: the thread drifts **opposite** the room's own drift. That opposition
   is `Plane.near.parallaxFactor` being -0.5, and it is what reads as two depths.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp/WakilWindow.swift app/Sources/WakilApp/ThoughtThread.swift \
        app/Sources/WakilApp/VoidView.swift
git commit -m "2b-iv Task 5: the thread anchors to the bottom edge, and the bleed answers it"
```

---

## Task 6: `--capture-motion`

The probe's §6 says its central question — *are four states distinguishable in motion, and
does a whole field in motion read as calm or as a strobe?* — cannot be answered by stills.
The offscreen harness already renders at an arbitrary `time`, so emitting one frame
sequence per state costs very little and answers it **before** the acceptance sitting rather
than during it, and reproducibly.

**Files:**
- Modify: `app/Sources/WakilApp/Capture.swift`
- Modify: `app/Sources/WakilApp/main.swift`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `CoreMotion.forState(_:)`, `VoidUniforms`, and `Capture.swift`'s existing
  `pipeline`, texture and `writePNG` shape from Task 4.
- Produces: `runCaptureMotion(into directory: String) -> Int32`.

- [ ] **Step 1: Add the flag to `main.swift`**

Next to `capturePath(in:)`:

```swift
/// Returns the `--capture-motion <directory>` value, or `nil` when absent.
/// Same shape and reasoning as `capturePath` above.
private func captureMotionPath(in arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--capture-motion") else { return nil }
    guard let path = value(after: flagIndex, in: arguments, flag: "--capture-motion", named: "<directory>") else {
        exit(1)
    }
    return path
}
```

and below the existing `--capture` check — **below, because `--capture` must keep winning
if both are somehow passed, and because `firstIndex(of: "--capture")` does not match
`--capture-motion`** (they are separate array elements, compared whole, so there is no
prefix collision):

```swift
// The motion sequences (spec §8). Same offscreen path as `--capture`, but
// many frames per state rather than one, so the four states can be watched
// rather than inspected — which is the one judgement this sub-phase cannot
// make headlessly.
if let directory = captureMotionPath(in: CommandLine.arguments) {
    exit(runCaptureMotion(into: directory))
}
```

- [ ] **Step 2: Write `runCaptureMotion`**

Append to `app/Sources/WakilApp/Capture.swift`:

```swift
/// Renders one full cycle of each state as a numbered PNG sequence, at that
/// state's own resting frame rate — so playing the sequence back at that
/// rate is real time, and what you watch is what the app draws.
///
/// **This exists because a still cannot answer the question the sub-phase
/// turns on** (`void-as-core-probe.md` §6). A 0.42 s pulse and a 5.4 s breath
/// can produce visually identical high/low frame pairs and feel completely
/// different in motion; and whether a whole field in motion reads as calm or
/// as a strobe is not visible in any single frame. The spec's §10 makes both
/// numbered checks in the acceptance runbook, and this is what they are run
/// against.
///
/// 600×414 rather than `runCapture`'s 900×620: one cycle of thinking is 180
/// frames and the five sequences together are ~356 PNGs, so the smaller
/// frame keeps the gitignored output to tens of megabytes rather than
/// hundreds. Frame *cost* is measured by `--capture`; this is for looking at.
func runCaptureMotion(into directory: String) -> Int32 {
    let width = 600, height = 414

    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let library = try? device.makeDefaultLibrary(bundle: .module) else {
        FileHandle.standardError.write(Data("wakil --capture-motion: no Metal device or no default.metallib — run `make shaders`\n".utf8))
        return 1
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "void_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "void_fragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
        FileHandle.standardError.write(Data("wakil --capture-motion: could not build the void pipeline\n".utf8))
        return 1
    }

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    textureDescriptor.usage = [.renderTarget, .shaderRead]
    guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
        FileHandle.standardError.write(Data("wakil --capture-motion: could not allocate the target texture\n".utf8))
        return 1
    }

    let resolution = SIMD2(Float(width), Float(height))

    func render(palette: VoidPalette, state: CoreState, time: Float) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = VoidUniforms(
            resolution: resolution, palette: palette, parallax: .zero, time: time,
            motion: CoreMotion.forState(state),
            threadAnchorX: 0.5, threadLift: 0, ambientScale: 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VoidUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return true
    }

    func writePNG(to path: String) -> Bool {
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(
            &bytes, bytesPerRow: rowBytes,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue:
                      CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    // Four states in staging, plus thinking in production — the one
    // combination the spec's §10 check 5 asks about, because it is where
    // "hue is the environment's and motion is the agent's" either holds or
    // does not.
    let sequences: [(name: String, palette: VoidPalette, state: CoreState)] =
        CoreState.allCases.map { (name: $0.rawValue, palette: VoidPalette.forEnvironment("staging"), state: $0) }
        + [(name: "thinking-production", palette: VoidPalette.forEnvironment("production"), state: .thinking)]

    for sequence in sequences {
        let motion = CoreMotion.forState(sequence.state)
        let rate = motion.restingFrameRate
        let frames = Int((motion.period * Double(rate)).rounded())
        for frame in 0..<frames {
            let time = Float(Double(frame) / Double(rate))
            guard render(palette: sequence.palette, state: sequence.state, time: time),
                  writePNG(to: String(format: "%@/motion-%@-%04d.png", directory, sequence.name, frame))
            else {
                FileHandle.standardError.write(
                    Data("wakil --capture-motion: failed on \(sequence.name) frame \(frame)\n".utf8))
                return 1
            }
        }
        print("wrote \(frames) frames for \(sequence.name) at \(rate)fps (one \(motion.period)s cycle)")
        // The sequences loop cleanly — frame N is one full period after
        // frame 0 — so `-stream_loop` makes a clip long enough to judge
        // rather than a flash. Printed rather than run: assembling video is
        // not this binary's job, and ffmpeg is not a dependency of the app.
        print("  ffmpeg -framerate \(rate) -stream_loop 6 -i \(directory)/motion-\(sequence.name)-%04d.png"
            + " -c:v libx264 -pix_fmt yuv420p \(directory)/motion-\(sequence.name).mp4")
    }
    return 0
}
```

- [ ] **Step 3: Add the Makefile target**

After `captures:`:

```make
# One frame sequence per state, at that state's own resting frame rate.
# What the spec's §10 checks 1-3 are judged against — whether four states are
# distinguishable in motion, and whether a room in motion reads as calm.
# Stills cannot answer either (void-as-core-probe.md §6).
captures-motion: app-build
	mkdir -p .context/2b-iv/motion
	cd app && swift run WakilApp --capture-motion ../.context/2b-iv/motion
```

and add `captures-motion` to the `.PHONY` line.

- [ ] **Step 4: Run it**

Run: `make captures-motion`
Expected: five lines reporting 81, 45, 180, 50 and 180 frames respectively, each with an
ffmpeg command under it. `ls .context/2b-iv/motion | wc -l` should report 536.

- [ ] **Step 5: Assemble and watch at least one clip**

Run the printed ffmpeg command for `idle` and for `speaking`, then open both. If ffmpeg is
not installed, `open` the frame directory and use QuickTime's *File → Open Image Sequence*,
which asks for the frame rate — give it the rate printed for that state.

This is the first time anybody has seen the room move. Note what you see; Task 8's runbook
is where it gets recorded properly.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp/Capture.swift app/Sources/WakilApp/main.swift Makefile
git commit -m "2b-iv Task 6: --capture-motion, so the strobe question can be watched rather than argued"
```

---

## Task 7: The documentation

Charter-level change, so the paper trail is part of the deliverable. No code in this task.

**Files:**
- Modify: `docs/wakil/design-language.md`
- Modify: `docs/wakil/north-star.md`
- Modify: `docs/wakil/void-as-core-probe.md`
- Modify: `docs/wakil/phase-2b-ii-acceptance.md`

- [ ] **Step 1: Rewrite `design-language.md` §1's third principle**

Replace principle 3 entirely:

```markdown
3. **One luminous surface.** The room is the only genuinely luminous thing — and it is
   behind everything, so it can never be in front of what you are reading. Nothing else
   glows. *(Rewritten 2026-09-09 by 2b-iv. This principle used to read "One bright object.
   The Core is the only genuinely luminous thing on screen." Its goal — a living interface
   that stays calm — survives; its mechanism does not, because there is no object any more.
   The goal is served better, not worse: a bright object had to be placed somewhere, and on
   2b-ii's first hands-on run it was placed on top of an open pane.)*
```

- [ ] **Step 2: Rewrite `design-language.md` §4**

Replace the whole of §4 — from the `## 4. The Core` heading to just before `## 5. Colour` —
with:

```markdown
## 4. The Core

Wakil's presence. **Not an object: the room.** The void of §2 carries the four states, and
nothing is drawn in front of the panes at all.

**Hue belongs to the environment. Motion and intensity belong to agent state.** §5 already
spends the void's colour on environment — violet normally, red on production — so the two
channels are split rather than shared. A red room that breathes faster is
production-and-thinking, unambiguously.

| State | Behaviour |
|-------|-----------|
| **Idle** | The dimmest of the four, on a 5.4s breath. Present but asleep. |
| **Listening** | Brightest, and the bleeds tighten; breath quickens to 1.5s. |
| **Thinking** | The two bleeds trade dominance on a 12s turnover and drift slowly — the room turning something over. |
| **Speaking** | The lower bleed alone pulses on a 0.42s speech cadence. The upper field holds still. |

Four states, one room, **no text labels**. Peripheral legibility is the goal: knowing what
Wakil is doing from the corner of the eye.

**Speaking is contained by geometry, not by a small number.** A 0.42s pulse across a whole
peripheral field is precisely what §1's first principle warns against, so it is confined to
the lower bleed — the same bottom edge §9's thread and §12's waveform attach to. The room
speaks from where the voice is coming from.

**There are no ornaments.** The tick rings — previously "the single permitted ornament" —
went with the sphere. No reticles, brackets, scan lines, or grid overlays anywhere in the
application, and now no rings either.

**Rewritten 2026-09-09, not amended** (charter open question 11, now closed). This section
described an iridescent sphere with a specular highlight and rotating tick rings. 2b-ii's
first hands-on run put that sphere on top of an open pane — because this section stated the
goal and never turned it into a position or a size — and the operator asked whether the void
should be the Core instead. Probed the same day (`void-as-core-probe.md`, twelve renders),
specified as
`docs/superpowers/specs/2026-09-09-void-as-core-design.md`. The occlusion problem is not
solved by the rewrite; it stops being possible.
```

- [ ] **Step 3: Amend §2, §3, §7, §9, §12, §13, §15**

**§2**, append one paragraph:

```markdown
**Since 2026-09-09 the void is also §4's Core.** Its two bleeds carry Wakil's four states
in their amplitude, spread and drift, while their *colour* stays the environment's alone.
The two channels never mix.
```

**§3**, replace the Near row's "Holds" cell:

```markdown
| **Near** | Full scale, brightest, may overlap | The thought thread, current utterance |
```

and append below the table:

```markdown
**The Core left this plane on 2026-09-09** and the thought thread is what keeps it. Under
§4's rewrite the room is behind everything, so the near plane holds only what rises out of
it.
```

**§7**, replace the motion table with:

```markdown
| Motion | Duration |
|--------|----------|
| Room breath | 5.4s idle · 1.5s listening |
| Room turnover | 12s thinking |
| Room speech pulse | 0.42s speaking, lower bleed only |
| Plane transition | 400–600ms, ease-out |
| Value materialising | 250ms fade + 4px rise |

**The room's frame rate follows its own cadence.** Each state is drawn at the rate its
period needs and no faster — at least 25 frames per cycle, never above 120 — so an idle
window costs a fraction of a speaking one. *(The Core bob, 6.5s, is gone: it was the
sphere's vertical drift and there is no sphere.)*
```

**§9**, replace the first sentence:

```markdown
Agent progress renders as a **thought thread** rising out of the bottom edge's glow —
where §2's violet bleed rises, and where §4's Core lives since 2026-09-09. The glow
answers it: the bleed lifts locally beneath the thread while work is in flight, and fades
with it. Completed steps fade to dim green, the live step pulses. This replaces spinners
and progress bars entirely.
```

**§12**, replace the push-to-talk bullet:

```markdown
- **Push-to-talk** (hold ⌥), no wake word. **The Core's four states *are* the voice
  indicator** — literally, since 2026-09-09: there is no separate object and no separate
  mic UI, the room itself listens and speaks. Listening: the room brightens and its bleeds
  tighten; a waveform and live transcription appear at the bottom edge, in the glow, beside
  §9's thread; release to send.
```

**§13**, replace the third bullet of **Targets**:

```markdown
- **The room is a Metal/GPU shader**, never CPU — it animates continuously, so CPU would
  jitter and drain battery. **One layer, not two** (2026-09-09): 2b-ii ran a paused void
  behind the panes and a continuous Core in front of them, and deleting the Core left one
  cadence on one layer. An idle window went from a continuous 60fps sphere to a 15fps room
  and got *cheaper*, not dearer.
```

**§15**, add to the still-open list:

```markdown
- **The room's motion numbers are untuned.** Thinking's 12s turnover and drift magnitude,
  listening's spread factor, and all four amplitude ranges were invented by 2b-iv's spec
  and have no precedent here. They live in one file (`WakilKit/Visual/CoreMotion.swift`)
  precisely so the tuning pass is a one-file edit. Whether a whole field in motion reads as
  calm rather than as a strobe is the open question underneath them.
```

- [ ] **Step 4: Close north-star open question 11**

In `docs/wakil/north-star.md` §7, replace row 11's cell with:

```markdown
| 11 | ~~Should the void itself be the Core, with no sphere at all?~~ **CLOSED 2026-09-09 — yes.** Raised by the operator after 2b-ii's first hands-on run put the sphere on top of an open pane; probed the same day and specified as `docs/superpowers/specs/2026-09-09-void-as-core-design.md` (sub-phase 2b-iv). The objection that could have killed it does not hold: hue stays owned by the environment while motion and intensity are owned by agent state, so a production room still looks like production while Wakil is thinking in it. `design-language.md` §4 was rewritten rather than amended, §1's third principle lost its mechanism and kept its goal, and §9 and §12 re-anchored to the bottom edge. It also came out **cheaper** — one Metal layer at 15fps idle against two with a continuous sphere. | — |
```

- [ ] **Step 5: Add 2b-iv to the phase map**

In §8's 2b sub-phase table, after the 2b-iii row:

```markdown
| **2b-iv** | The void as the Core; the sphere deleted; one Metal layer | §4 realised without an object, at lower idle cost than 2b-ii |
```

and append below that table:

```markdown
**2b-iv exists because 2b-ii's first hands-on run asked a better question than its spec
did**, and it is ordered after 2b-iii rather than before it for one reason: 2b-ii's
acceptance runbook must be walked *first*, in full. Once the sphere is deleted nobody can
compare it against the room on a running window ever again, and that runbook is the only
opportunity to record a human judgement of what it replaced.
```

- [ ] **Step 6: Amend the frame-rate section**

At the end of `north-star.md`'s "An input to 2b-ii: cap the frame rate, but cap the right
thing" section, append:

```markdown
**Point 3 superseded, 2026-09-09, by 2b-iv.** *"The Core and the void want different
cadences"* was right about the method — the split was made deliberately rather than
inherited — and its answer had a shelf life of one sub-phase. Deleting the sphere left one
cadence, and one layer is now not merely sufficient but correct. The replacement rule is
that **the cadence sets the cap**: each state is drawn at the rate its own period needs,
at least 25 frames per cycle and never above 120, which makes an idle window
(15fps, one cheap shader) about a quarter the cost of what 2b-ii shipped (0 void frames
plus a continuous 60fps sphere of a much heavier one). Point 2's finding — that the saving
is in not rendering at all — survives in a second form: the window still draws nothing
while it is occluded, minimised or on another space.
```

- [ ] **Step 7: Update the probe document**

In `docs/wakil/void-as-core-probe.md` §5, append to the fourth bullet ("The void can no
longer be paused"):

```markdown
  **This bullet is wrong and 2b-iv's spec §5 corrects it.** It compares the void layer
  against itself and ignores the layer beside it: `CoreView` is continuous at
  `preferredFramesPerSecond = 120` and paused only on occlusion, so an idle 2b-ii window
  already drew a full-rate sphere of a much heavier shader. An idle B window draws 15fps of
  one cheap one. B is roughly a four-fold idle saving, not a cost — deleting the second
  layer pays for the breath outright.
```

Replace §7 in full:

```markdown
## 7. Status

**A decision, taken 2026-09-09.** B is specified as
`docs/superpowers/specs/2026-09-09-void-as-core-design.md` and implemented as sub-phase
2b-iv; `north-star.md`'s open question 11 is closed and `design-language.md` §4 is
rewritten.

Five choices were made in the design review that this probe did not settle: B is its own
sub-phase, walked **after** 2b-ii's acceptance run; "the Core" keeps its name and means
presence rather than an object; each state's frame rate follows its own cadence; §9's
thread and §12's waveform anchor to the bottom edge **with the bleed reacting to them**;
and speaking's 0.42s pulse is contained by confining it to the lower bleed rather than by
holding its amplitude down.

§6's three unknowns are not closed by that decision. Two of them — whether four states are
distinguishable in motion, and whether a room in motion reads as calm — are numbered checks
in `phase-2b-iv-acceptance.md`, judged against `make captures-motion`. The third, the
invented numbers, is why they all live in one file.

Nothing in 2b-ii was reverted. The Core shipped bottom-centre and small, which was correct
under A and harmless under B, since B deletes it outright.
```

- [ ] **Step 8: Note the Core checks in 2b-ii's acceptance document**

Append to `docs/wakil/phase-2b-ii-acceptance.md` §2:

```markdown
**The Core-specific checks are still to be walked, and walking them is time-critical.**
2b-iv (`docs/superpowers/specs/2026-09-09-void-as-core-design.md`) deletes the sphere
outright. Whether it reads as a volume rather than a disc, whether its specular reads as a
highlight rather than as pearl, whether the tick rings read as reactive, and whether it is
legible from the corner of the eye are judgements that can only ever be made against a
running 2b-ii. After 2b-iv lands there is no way to make them at all, and no baseline to
compare the room against. Walk this runbook before that sub-phase starts.
```

- [ ] **Step 9: Commit**

```bash
git add docs/wakil/
git commit -m "2b-iv Task 7: rewrite design-language §4, close charter question 11, correct the probe's ledger"
```

---

## Task 8: The acceptance runbook, and closing out

**Files:**
- Create: `docs/wakil/phase-2b-iv-acceptance.md`
- Modify: `docs/wakil/north-star.md`

- [ ] **Step 1: Write the runbook**

Create `docs/wakil/phase-2b-iv-acceptance.md`:

```markdown
# Phase 2b-iv acceptance — the void as the Core

**Status:** not yet run · **Spec:** `docs/superpowers/specs/2026-09-09-void-as-core-design.md`

2b-ii's lesson, recorded in `north-star.md` §8, is that a phase whose value is a human
judgement gets marked "implemented" and then treated as met. Every check below is
numbered for that reason. **"The code is written" and "the phase is done" are different
claims, and only this runbook closes the second one.**

## 1. Headless, before anything else

| | Check | Command | Expected |
|---|---|---|---|
| H1 | The suite is green | `make app-test` | 290 tests pass |
| H2 | Nothing references the deleted layer | `grep -rn "CoreView\|core_vertex\|core_fragment\|shaderIndex" app/ Makefile` | no output |
| H3 | The palette was never touched | `git diff origin/main -- app/Sources/WakilKit/Visual/VoidPalette.swift app/Tests/WakilKitTests/VoidPaletteTests.swift` | no output — spec §2's proof |
| H4 | The stills render | `make captures` | six PNGs in `.context/2b-iv`, none containing a sphere |
| H5 | The sequences render | `make captures-motion` | 536 frames across five sequences |

## 2. The judgement, against `make captures-motion`

Assemble each clip with the ffmpeg line the tool prints, or open the frame directory in
QuickTime with *File → Open Image Sequence* at the printed rate. Watch each for at least
thirty seconds.

1. **Are the four states distinguishable in motion?** Watch idle and thinking back to back.
   The probe found them "distinguishable, but only just" in stills and argued that *rate*
   would separate them where amplitude did not. This is where that argument is tested. If
   it fails, the fallback is variant C — the room carries ambient state and a small sphere
   is summoned for listening and speaking only — which was the reviewer's preference and is
   recoverable, since `Core.metal` is in git history rather than gone.
2. **Does a room in motion read as calm, or as a strobe you cannot look away from?** This
   is the risk B carries that A never did. §1 warns that a single bright object works
   *because* everything else stays quiet.
3. **Is speaking's bottom-locality enough containment, at its amplitude?** Watch
   `motion-speaking` specifically, at the edge of vision rather than head-on — the question
   is whether it is bearable in the corner of your eye while you read a pane, not whether it
   looks good when you stare at it.
4. **Does production-and-thinking read as both at once?** Watch
   `motion-thinking-production` against `motion-thinking`. Colour is the only difference
   between them by construction, so if hue and motion do not coexist it shows up as the
   *shape* of the bleeds reading differently, not the colour.

Record the answer to each, and any number you changed in
`app/Sources/WakilKit/Visual/CoreMotion.swift` as a result. **Checks 1–3 are the tuning
pass**; changing a number here and re-running `make captures-motion` is the expected
workflow, not a failure.

## 3. The running window

Run `cd app && swift run WakilApp`.

5. **Is anything ever occluded?** Open several panes, drag them everywhere, maximize one.
   Nothing should ever be drawn in front of a pane. This should be *structurally
   impossible* now — confirm it rather than assume it.
6. **Does the thread read as rising out of the glow?** Send a message. The bleed should lift
   under the thread while the turn runs and fade with it. Judge whether it reads as the room
   giving birth to the thread or as a smudge — the coupling has no precedent in the design
   language and dialling it toward zero degrades cleanly to a plain bottom-edge anchor.
7. **Does the maximize dim read as deference or as a fault?** ⌘⏎ on a pane and back.
8. **Does parallax still read as depth?** Move the pointer in a slow arc. The thread should
   drift opposite the room. No stepping.
9. **Does an unfocused window keep breathing?** Click another app while leaving Wakil
   visible. It must. Visibility, not focus, is the bar.
10. **Does an occluded window stop?** Cover Wakil completely, wait, bring it back. Nothing
    should be visibly wrong on return.

## 4. Result

*(Fill in on the day: date, machine, who walked it, the answer to each check, every number
changed, and anything left open.)*
```

- [ ] **Step 2: Mark the row honestly**

In `north-star.md` §8's sub-phase table, the 2b-iv row's Exit cell becomes:

```markdown
§4 realised without an object, at lower idle cost than 2b-ii — **implemented; acceptance outstanding**
```

Add below the table's existing 2b-ii paragraph:

```markdown
**2b-iv is implemented, not met — the same distinction, for the same reason.** Its headless
checks are cheap and green, and none of them is what the sub-phase is for. Whether four
states read as four in motion, whether a room in motion reads as calm rather than as a
strobe, and whether the thread reads as rising out of the glow are judgements a machine
cannot make. `docs/wakil/phase-2b-iv-acceptance.md` lists all ten checks as not yet run.
```

- [ ] **Step 3: Verify the whole thing one more time**

```bash
make app-test && make captures && make captures-motion
grep -rn "CoreView\|core_vertex\|core_fragment\|shaderIndex" app/ Makefile
git diff origin/main -- app/Sources/WakilKit/Visual/VoidPalette.swift
```

Expected: tests pass; both capture runs succeed; the grep prints nothing; the palette diff
is empty.

- [ ] **Step 4: Commit**

```bash
git add docs/wakil/
git commit -m "2b-iv Task 8: the acceptance runbook, and an honest phase-map row"
```

---

## Self-Review

**Spec coverage.** §2's channel split → Task 2's `stateNeverTouchesTheBleedColours` and the
global constraint forbidding palette edits. §3's `CoreMotion` table → Task 1. §4's layer
collapse → Tasks 2 and 4; `Plane.near`'s rescue → Task 5 Step 1. §5's frame policy → Tasks
2 (resting rate), 3 (occlusion pause, parallax bump). §6's shader → Task 2 Step 5; the
layout hazard → Task 2's `theWireFormatsLayoutIsPinned`. §7's anchor and coupling → Task 5;
§12's waveform is spec text only, written in Task 7 Step 3. §8's deletions → Task 4;
`--capture-motion` → Task 6. §9's documentation → Task 7. §10's verification → Tasks 1, 2
(headless) and 8 (human). §1's maximize call → Task 4 Step 3.

**Type consistency.** `CoreMotion.forState(_:)` is the only constructor used, in Tasks 2, 3,
4 and 6. `VoidUniforms`'s initialiser takes the same eight labels everywhere it is called
(Tasks 2, 4, 6). `ThreadLift.value(hasRows:isTurnInFlight:secondsSinceLastRow:)` is called
with those exact labels in Task 5. `VoidView`'s parameter list grows in three places and
every call site is updated in the same task that grows it: `state` (Task 2 Step 7),
`isMaximized` (Task 4 Step 4), `threadAnchorX`/`isTurnInFlight`/`lastRowAt` (Task 5 Step 3).

**Test counts.** 2b-ii ends at 276. Task 1 adds 12 → 288. Task 2 adds 3 → 291. Task 4
removes 1 → 290. Tasks 3, 5, 6, 7, 8 add none, and the runbook's H1 expects 290. If a count
disagrees at execution time, trust the runner and correct the plan rather than the code.
