# Phase 2b-ii — Atmosphere: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply `design-language.md` §1–9 to the window 2b-i built — the void, the Core,
the three planes, motion, the thought thread, and the production treatment — at the frame
budget the probe measured.

**Architecture:** Three layers, back to front: a paused Metal view drawing the void, the
existing SwiftUI canvas, and a continuous Metal view drawing the Core and the thought
thread. Every question with a right answer (which Core state, which colours, how far to
parallax, which harness events become rows) is a pure value type in `WakilKit` with unit
tests; `WakilApp` only draws them.

**Tech Stack:** Swift 6.3.2 · SwiftPM (`swift-tools-version: 6.0`) · SwiftUI + AppKit ·
Metal / MetalKit · swift-testing (`import Testing`, `@Test`, `#expect`) · GNU make

**Spec:** `docs/superpowers/specs/2026-09-09-phase-2b-ii-atmosphere-design.md`

## Global Constraints

- **Deployment target is macOS 14.4**, set in `app/Package.swift`. Do not raise it.
- **Tests use swift-testing, never XCTest.** `import Testing`, `@Test func name()`,
  `#expect(...)`. Free functions at file scope, not methods on a class.
- **Run tests with `make app-test`** from the repository root, or
  `cd app && ../scripts/swift-test.sh --filter <name>` for one test. A bare `swift test`
  fails to find `Testing.framework` on this machine; the wrapper script adds the paths.
- **Build with `make app-build`** from the repository root, never a bare `swift build` in
  `app/` — from Task 2 onward the Makefile is what compiles the shaders first.
- **Geometry in `WakilKit` uses `PaneFrame`/`Double`, never `CGRect` or `CGFloat`.** The
  view layer converts at the boundary and nowhere else, so `WakilKitTests` runs without a
  display. `y` grows **downward**, matching SwiftUI.
- **No `await` on the pointer-moved path.** Parallax follows the cursor through local
  SwiftUI `@State`, exactly as 2b-i's `dragOffsets` do, and dispatches nothing.
- **No document produced by this phase may claim 120 fps was observed.** Both displays on
  the build machine are 60 Hz (probe §4). Record GPU cost against the 8.33 ms budget and
  name the display that could not test it.
- **Palette values, verbatim from `design-language.md` §2 and §5:** void field
  `#030408`–`#070812` · violet `#7c5cff` · blue `#4fb9e8` · mint/green `#8be0c8` · amber
  `#e8b45a` · text cool white `#e8ecf6`. Red has no hex in §5 and Task 4 assigns one.
- **Motion durations, verbatim from §7:** Core breath 5.4 s idle / 1.5 s listening · Core
  bob 6.5 s · plane transition 400–600 ms ease-out · value materialising 250 ms fade +
  4 px rise.
- **Commit after every task**, with the task number in the subject.

---

## File Structure

New, outside any SwiftPM target — SwiftPM reports a `.metal` file inside `Sources` as an
unhandled resource, and these are build inputs rather than Swift ones:

    app/Shaders/Void.metal          the void: field, two bleeds, grain, vignette
    app/Shaders/Core.metal          the Core: iridescence, specular, rim, tick rings

New, in `WakilKit` — pure, testable, no display:

    Visual/CoreState.swift          four states; the turn-in-flight derivation
    Visual/VoidPalette.swift        environment → the void's colours
    Visual/Plane.swift              plane constants; cursor → parallax offset

New, in `WakilApp` — drawing only:

    VoidView.swift                  paused MTKView; redraws on change
    CoreView.swift                  continuous MTKView; 120 fps cap
    ThoughtThread.swift             §9's rendering, on the near plane

`WakilWindow.swift` (883 lines) splits along its existing `// MARK` boundaries in Task 1,
before anything new lands in it:

    WindowSession.swift             the session          (today's lines 31–193)
    AppScene.swift                  scene + app delegate (193–327)
    WakilWindow.swift               the shell: the three-layer ZStack
    Canvas.swift                    the canvas and its gestures (566–803)
    Rail.swift                      the rail             (803–832)
    Palettes.swift                  ⌘P and ⌘K            (832–883)

Modified:

    Makefile                        `shaders` target; `app-build` depends on it
    .gitignore                      the generated default.metallib
    app/Package.swift               `.copy("default.metallib")` on WakilApp
    WakilKit/App/WindowModel.swift  turn-in-flight; thoughtRow's optional return
    WakilKit/Layout/Pane.swift      density, persisted
    WakilKit/Layout/LayoutStore.swift  setDensity
    WakilKit/Layout/LayoutActions.swift pane_set_density
    docs/wakil/design-language.md   §5 gains red's hex value

---

## Task 1: Split `WakilWindow.swift`

Nothing changes behaviourally. This is the readability precondition for every later task,
and it happens first so that no later diff mixes "moved" with "changed".

**Files:**
- Create: `app/Sources/WakilApp/WindowSession.swift`
- Create: `app/Sources/WakilApp/AppScene.swift`
- Create: `app/Sources/WakilApp/Canvas.swift`
- Create: `app/Sources/WakilApp/Rail.swift`
- Create: `app/Sources/WakilApp/Palettes.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the same symbols as today, in new files — `WindowSession`,
  `WakilAppDelegate`, `WakilApplication`, `WakilWindow`, `PaletteView`. No signature
  changes.

- [ ] **Step 1: Record the baseline**

```bash
make app-build && make app-test 2>&1 | tail -5
```

Expected: builds, and every test passes. Write the passing test count down — Step 5
compares against it.

- [ ] **Step 2: Move each region into its own file**

Cut, do not retype. Each new file gets the imports the moved code actually uses
(`WindowSession.swift` and `AppScene.swift` need `AppKit`, `SwiftUI`, `Foundation` and
`WakilKit`; `Canvas.swift`, `Rail.swift` and `Palettes.swift` need `SwiftUI` and
`WakilKit`). All five stay in the `WakilApp` module, so nothing becomes `public` and
nothing moves between types.

`canvas`, `paneView`, `dragGesture`, the resize gesture, `previewDrag` and
`schedulePreview` are `private` methods on `WakilWindow`, so they move as
`extension WakilWindow { ... }` in `Canvas.swift`. The `@State` properties they read stay
on the struct in `WakilWindow.swift` — an extension in the same module can see them.

Do the same for `rail(_:)` in `Rail.swift`, and for `palette(items:...)` plus the
`PaletteView` struct in `Palettes.swift`.

- [ ] **Step 3: Build**

```bash
make app-build
```

Expected: success. A `cannot find X in scope` error means a needed `import` did not come
across with the code; add it to that file.

- [ ] **Step 4: Check that nothing was left behind or duplicated**

```bash
grep -c "" app/Sources/WakilApp/*.swift
```

Expected: the six files' line counts sum to roughly today's 883 plus about six lines of
`import` per new file. A total far above that means a region was copied rather than moved.

- [ ] **Step 5: Run the tests**

```bash
make app-test 2>&1 | tail -5
```

Expected: PASS, with the same test count as Step 1. This is a pure move; a changed count
means something was edited.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp/
git commit -m "2b-ii Task 1: split WakilWindow.swift along its MARK boundaries

883 lines, and 2b-ii would take it past 1200. Pure move: the regions were
already separated by comments, nothing changed type or visibility, and the
test count is unchanged."
```

---

## Task 2: The build route — `make shaders`, and a black void behind the canvas

Retires the whole build risk before any shader is worth writing. The void here is
literally black; Task 3 makes it a void.

**Files:**
- Create: `app/Shaders/Void.metal`
- Create: `app/Sources/WakilApp/VoidView.swift`
- Modify: `Makefile:209` (`app-build`)
- Modify: `.gitignore`
- Modify: `app/Package.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`

**Interfaces:**
- Consumes: Task 1's split files.
- Produces: `struct VoidView: NSViewRepresentable` with
  `init(palette: VoidPalette, parallax: CGSize)` — **note both parameters are added in
  later tasks**; this task's version is `init()` with no parameters. Task 4 adds
  `palette`, Task 5 adds `parallax`.

- [ ] **Step 1: Verify the toolchain, because the failure is silent**

```bash
printf '#include <metal_stdlib>\nusing namespace metal;\nfragment float4 f() { return float4(1); }\n' > /tmp/t.metal
xcrun metal -o /tmp/t.metallib /tmp/t.metal && echo TOOLCHAIN-OK && rm -f /tmp/t.metal /tmp/t.metallib
```

Expected: `TOOLCHAIN-OK`. If instead it prints
`cannot execute tool 'metal' due to missing Metal Toolchain`, stop and run
`xcodebuild -downloadComponent MetalToolchain` (688 MB) — `xcrun -f metal` resolving is
not evidence the compiler is present. `xcrun -f metallib` failing is expected and is not
a second missing component.

- [ ] **Step 2: Write the shader**

`app/Shaders/Void.metal` — a full-screen triangle and a solid near-black fill. The vertex
function takes no buffer: three vertices covering clip space is cheaper than a quad and
needs no index buffer.

```metal
#include <metal_stdlib>
using namespace metal;

struct VoidVertex {
    float4 position [[position]];
    float2 uv;
};

// A full-screen triangle from vertex_id alone. No vertex buffer, no index
// buffer: (0,0), (2,0), (0,2) in uv space covers the whole clip rect and the
// rasteriser discards the overhang.
vertex VoidVertex void_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VoidVertex out;
    out.uv = uv;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return out;
}

fragment float4 void_fragment(VoidVertex in [[stage_in]]) {
    return float4(0.012, 0.016, 0.031, 1.0);   // #030408
}
```

- [ ] **Step 3: Add the make target**

In `Makefile`, replace the `app-build` target at line 209 with:

```make
# The Metal compiler is not part of SwiftPM: declaring a .metal file as a
# resource copies the source into the bundle and compiles nothing, and
# makeDefaultLibrary then fails at runtime with "no default library was
# found" (docs/wakil/phase-2b-probe.md §2). So the shaders are compiled
# here, ahead of `swift build`, which also makes a broken shader a build
# failure rather than a crash the first time a window opens.
#
# Requires the separately-downloaded Metal Toolchain — Xcode alone is not
# enough. See operator-todo.md, "Phase 2b toolchain".
shaders:
	xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal

app-build: shaders
	cd app && swift build
```

Add `shaders` to the `.PHONY` line if the Makefile has one.

- [ ] **Step 4: Ignore the generated library and declare it as a resource**

Append to `.gitignore`:

```
# Generated by `make shaders` from app/Shaders/*.metal
app/Sources/WakilApp/default.metallib
```

In `app/Package.swift`, change the `WakilApp` target to:

```swift
.executableTarget(
    name: "WakilApp",
    dependencies: ["WakilKit"],
    resources: [.copy("default.metallib")]),
```

`.copy`, not `.process`: the file goes into the bundle under its own name, which is what
`device.makeDefaultLibrary(bundle:)` looks for. `.process` would rename or transform it.

- [ ] **Step 5: Write the view**

`app/Sources/WakilApp/VoidView.swift`:

```swift
import MetalKit
import SwiftUI

/// The void, drawn in Metal behind everything (spec §2).
///
/// **Paused, and that is the point.** `isPaused` with
/// `enableSetNeedsDisplay` means this view draws only when something
/// actually changes it — the environment, the window's size, the parallax
/// offset — so a still window costs zero void frames. Spec §2.2 records why
/// that, and not a frame-rate cap, is where the saving is.
struct VoidView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        // `MTKView(frame:device:)` rather than `MTKView()`: MTKView declares
        // its own designated initialiser, so NSView's `init(frame:)` is not
        // inherited and a bare `MTKView()` does not compile.
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        // Opaque: nothing is behind the void, and a transparent drawable
        // would composite against the window's background for no reason.
        view.layer?.isOpaque = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState

        override init() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = try? device.makeDefaultLibrary(bundle: .module) else {
                // A missing default.metallib means `make shaders` did not
                // run. Failing loudly here is the whole reason the shader is
                // compiled at build time (probe §2) — the alternative is a
                // window that opens with nothing in it.
                fatalError("VoidView: no Metal device or no default.metallib — run `make shaders`")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "void_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "void_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.device = device
            self.queue = queue
            self.pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
```

- [ ] **Step 6: Put it behind the window's content**

In `WakilWindow.swift`, wrap the existing body's `VStack` in a `ZStack`:

```swift
var body: some View {
    ZStack {
        VoidView()
            .ignoresSafeArea()
        VStack(alignment: .leading) {
            if let session {
                loaded(session)
            } else {
                Text("starting…")
            }
        }
        .padding()
    }
    .frame(minWidth: 1000, minHeight: 860)
    // …the existing .task stays as it is, on the ZStack
}
```

- [ ] **Step 7: Build and look at it**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Expected: the window opens with a near-black background behind the controls instead of
the system window background. Quit it.

If it crashes on `no default.metallib`, `make shaders` did not run — check that
`app-build` depends on `shaders`.

- [ ] **Step 8: Confirm the tests still pass**

```bash
make app-test 2>&1 | tail -5
```

Expected: PASS. Nothing in `WakilKit` changed.

- [ ] **Step 9: Commit**

```bash
git add Makefile .gitignore app/Package.swift app/Shaders/ app/Sources/WakilApp/
git commit -m "2b-ii Task 2: make shaders, and a Metal layer behind the window

Retires the build route the probe designed: xcrun metal prebuild into
default.metallib, .copy onto the WakilApp target, makeDefaultLibrary(bundle:)
by name. The shader draws flat #030408 for now — Task 3 makes it a void.

make app-build now depends on the separately-downloaded Metal Toolchain."
```

---

## Task 3: The void itself

**Files:**
- Modify: `app/Shaders/Void.metal`
- Modify: `app/Sources/WakilApp/VoidView.swift`

**Interfaces:**
- Consumes: Task 2's `VoidView` and pipeline.
- Produces: a `VoidUniforms` struct shared between Swift and Metal:

```swift
struct VoidUniforms {
    var resolution: SIMD2<Float>
    var bleedA: SIMD3<Float>     // the lower bleed's colour
    var bleedB: SIMD3<Float>     // the upper-right bleed's colour
    var parallax: SIMD2<Float>   // added in Task 5; zero here
}
```

- [ ] **Step 1: Write the shader**

Replace `void_fragment` in `app/Shaders/Void.metal`. Everything §2 asks for: the field,
two radial bleeds, grain at ~14%.

```metal
struct VoidUniforms {
    float2 resolution;
    float3 bleedA;
    float3 bleedB;
    float2 parallax;
};

// Hash-based value noise. Grain is not decoration: two wide radial
// gradients on a near-black field band visibly on an 8-bit panel, and
// ~14% of a pixel of noise is what breaks the banding up.
static float grain(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

fragment float4 void_fragment(VoidVertex in [[stage_in]],
                              constant VoidUniforms &u [[buffer(0)]]) {
    float2 uv = in.uv + u.parallax;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);

    // The field: #030408 at the top, #070812 at the bottom.
    float3 field = mix(float3(0.012, 0.016, 0.031),
                       float3(0.027, 0.031, 0.071), uv.y);

    // Violet from below, centred under the frame so only its upper arc
    // shows; cool blue from the upper right, off-canvas for the same
    // reason. Both are wide and weak — §1's "light is information" means
    // an atmospheric bleed must never read as an object.
    float2 a = (uv - float2(0.5, 1.18)) * float2(aspect, 1.0);
    float2 b = (uv - float2(1.10, -0.10)) * float2(aspect, 1.0);
    float fa = exp(-dot(a, a) * 3.2) * 0.55;
    float fb = exp(-dot(b, b) * 4.0) * 0.38;

    float3 colour = field + u.bleedA * fa + u.bleedB * fb;

    // Vignette, so the frame's corners fall away and nothing reads as a
    // rectangle with edges.
    float2 v = (uv - 0.5) * float2(aspect, 1.0);
    colour *= 1.0 - clamp(dot(v, v) * 0.35, 0.0, 0.35);

    colour += (grain(in.position.xy) - 0.5) * 0.14 * 0.06;
    return float4(colour, 1.0);
}
```

- [ ] **Step 2: Feed the uniforms from Swift**

In `VoidView.Coordinator`, add the matching struct and pass it. Declare it in Swift
exactly as it is in Metal — field order and types must match, because this is a raw
memory copy with no schema:

```swift
struct VoidUniforms {
    var resolution: SIMD2<Float> = .zero
    var bleedA: SIMD3<Float> = .zero
    var bleedB: SIMD3<Float> = .zero
    var parallax: SIMD2<Float> = .zero
}
```

In `draw(in:)`, after `setRenderPipelineState`:

```swift
var uniforms = VoidUniforms(
    resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
    bleedA: SIMD3(0.486, 0.361, 1.0),    // #7c5cff violet, from below
    bleedB: SIMD3(0.310, 0.725, 0.910),  // #4fb9e8 cool blue, upper right
    parallax: .zero)
encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VoidUniforms>.stride, index: 0)
```

- [ ] **Step 3: Build and look at it**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Expected: a near-black field with a faint violet glow rising from the bottom and a cooler
blue one from the upper right, corners falling away, no visible banding between them.

If you see concentric rings where the gradients meet, the grain term is too weak —
raise `0.06` in the last line and look again.

- [ ] **Step 4: Commit**

```bash
git add app/Shaders/Void.metal app/Sources/WakilApp/VoidView.swift
git commit -m "2b-ii Task 3: the void — field, two bleeds, grain, vignette

design-language.md §2. Grain at ~14% is load-bearing rather than decorative:
two wide gradients on a near-black field band without it."
```

---

## Task 4: `VoidPalette` and the production treatment

**Files:**
- Create: `app/Sources/WakilKit/Visual/VoidPalette.swift`
- Create: `app/Tests/WakilKitTests/VoidPaletteTests.swift`
- Modify: `app/Sources/WakilApp/VoidView.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`
- Modify: `docs/wakil/design-language.md` (§5 gains red's hex)

**Interfaces:**
- Consumes: Task 3's `VoidUniforms`.
- Produces (a small `RGB` struct rather than a tuple, because tuples are not `Equatable`
  and every test below compares colours):

```swift
public struct RGB: Sendable, Equatable { public let r, g, b: Double }
public struct VoidPalette: Sendable, Equatable {
    public let bleedA: RGB          // the lower bleed
    public let bleedB: RGB          // the upper-right bleed
    public let isProduction: Bool
    public static func forEnvironment(_ environment: String) -> VoidPalette
    public static let violet: RGB   // #7c5cff
    public static let blue: RGB     // #4fb9e8
    public static let red: RGB      // #e85c5c
}
```

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/VoidPaletteTests.swift`:

```swift
import Testing
@testable import WakilKit

@Test func aProductionEnvironmentTurnsTheVoidRed() {
    let palette = VoidPalette.forEnvironment("production")
    #expect(palette.isProduction)
    #expect(palette.bleedA == VoidPalette.red)
    #expect(palette.bleedB == VoidPalette.red)
}

/// `writeGate` matches production case-insensitively, and a treatment that
/// disagreed with the gate about what production is would be worse than no
/// treatment: the room would look safe while the gate refused.
@Test func productionIsMatchedRegardlessOfCase() {
    #expect(VoidPalette.forEnvironment("Production").isProduction)
    #expect(VoidPalette.forEnvironment("PRODUCTION").isProduction)
    #expect(VoidPalette.forEnvironment("  production  ").isProduction)
}

@Test func everyOtherEnvironmentKeepsTheVioletAndBlueBleeds() {
    for name in ["staging", "local", "development", "prod-like", "preproduction"] {
        let palette = VoidPalette.forEnvironment(name)
        #expect(!palette.isProduction, "\(name) is not production")
        #expect(palette.bleedA == VoidPalette.violet)
        #expect(palette.bleedB == VoidPalette.blue)
    }
}

/// The failure direction matters. An environment that has not resolved yet
/// is empty (`WindowModel.environment` before `refreshContext` answers), and
/// a treatment that failed *into* production would paint the room red on
/// every launch until the answer arrived — which is how a warning stops
/// being read.
@Test func anUnresolvedEnvironmentIsNotProduction() {
    #expect(!VoidPalette.forEnvironment("").isProduction)
    #expect(!VoidPalette.forEnvironment("unknown").isProduction)
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd app && ../scripts/swift-test.sh --filter VoidPalette
```

Expected: FAIL — `cannot find 'VoidPalette' in scope`.

- [ ] **Step 3: Implement**

`app/Sources/WakilKit/Visual/VoidPalette.swift`:

```swift
import Foundation

/// A colour in linear-ish 0…1 components, as the shader wants it.
///
/// Not `CGColor` or `NSColor`: this type is decided in `WakilKit`, which
/// stays free of AppKit so that every question with a right answer can be
/// tested without a display (spec §2.3).
public struct RGB: Sendable, Equatable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// What colour the void's two bleeds are, given the active environment.
///
/// **The whole production treatment is here** (spec §3.2): the environment
/// label turns red and the void's bleeds turn red, and nothing else on
/// screen changes. Lighting every pane edge would put a dozen bright
/// objects beside the Core and break §1's "one bright object"; and §5's
/// "reserved semantics, never decorative" cuts both ways — red that is
/// everywhere is wallpaper, and will not stop anyone on the day it needs to.
public struct VoidPalette: Sendable, Equatable {
    /// The bleed rising from below the frame.
    public let bleedA: RGB
    /// The bleed from the upper right.
    public let bleedB: RGB
    /// Whether this palette is the production one. The label reads this too,
    /// so the badge and the room cannot disagree.
    public let isProduction: Bool

    /// `#7c5cff` — §5's primary luminance.
    public static let violet = RGB(0.486, 0.361, 1.0)
    /// `#4fb9e8` — §5's cool blue.
    public static let blue = RGB(0.310, 0.725, 0.910)
    /// `#e85c5c`. §5 names red as production's hue and gives no value; this
    /// is that value, chosen to sit at the same weight as the amber
    /// `#e8b45a` and the green `#8be0c8` beside it rather than as a pure
    /// `#ff0000`, which on a near-black field reads as a fault in the
    /// display. Recorded back into `design-language.md` §5.
    public static let red = RGB(0.910, 0.361, 0.361)

    /// The palette for an environment name.
    ///
    /// Matching is trimmed and case-insensitive because `writeGate` matches
    /// production the same way. A treatment that disagreed with the gate
    /// about what production is would paint a safe-looking room around a
    /// refusal.
    public static func forEnvironment(_ environment: String) -> VoidPalette {
        let name = environment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "production" {
            return VoidPalette(bleedA: red, bleedB: red, isProduction: true)
        }
        return VoidPalette(bleedA: violet, bleedB: blue, isProduction: false)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd app && ../scripts/swift-test.sh --filter VoidPalette
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Wire it into the view**

Give `VoidView` a palette and use it. In `VoidView.swift`:

```swift
struct VoidView: NSViewRepresentable {
    let palette: VoidPalette

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.palette = palette
        view.needsDisplay = true
    }
    // makeNSView unchanged
```

On the coordinator, add `var palette = VoidPalette.forEnvironment("")` and build the
uniforms from it:

```swift
bleedA: SIMD3(Float(palette.bleedA.r), Float(palette.bleedA.g), Float(palette.bleedA.b)),
bleedB: SIMD3(Float(palette.bleedB.r), Float(palette.bleedB.g), Float(palette.bleedB.b)),
```

In `WakilWindow.swift`, pass the active environment, and colour the label to match:

```swift
VoidView(palette: VoidPalette.forEnvironment(session?.model.environment ?? ""))
    .ignoresSafeArea()
```

Find the existing environment label — it draws `model.environmentLabel` — and add:

```swift
.foregroundStyle(
    VoidPalette.forEnvironment(model.environment).isProduction
        ? Color(red: 0.910, green: 0.361, blue: 0.361)
        : Color(red: 0.910, green: 0.925, blue: 0.965))   // #e8ecf6
```

- [ ] **Step 6: Record red's value in the design language**

In `docs/wakil/design-language.md` §5, change the red row of the semantics table to carry
its hex, matching the other two rows:

```
| Red `#e85c5c` | **Production** · destructive · failed |
```

And add below the table:

```
**Red's value was assigned 2026-09-09**, during 2b-ii's implementation — this table named
the hue and never gave it a number. `#e85c5c` sits at the same weight as the amber and
green beside it; a pure `#ff0000` on a near-black field reads as a fault in the display
rather than as a warning.
```

- [ ] **Step 7: See it**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Expected: violet and blue as before. Then, with a `wakil-ctx` running and an environment
named `production` active, the bleeds and the label are red. If you have no production
environment registered, temporarily change the `VoidView(palette:)` line to
`.forEnvironment("production")`, confirm, and change it back.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/Visual/ app/Tests/WakilKitTests/VoidPaletteTests.swift \
        app/Sources/WakilApp/ docs/wakil/design-language.md
git commit -m "2b-ii Task 4: VoidPalette, and production turns the room red

The badge and the void's bleeds, and nothing else. Matching is trimmed and
case-insensitive so it cannot disagree with writeGate about what production
is, and an unresolved environment fails open into 'not production' — a
warning shown on every launch stops being read.

design-language.md §5 gains red's hex, which it never had."
```

---

## Task 5: `Plane` and parallax

**Files:**
- Create: `app/Sources/WakilKit/Visual/Plane.swift`
- Create: `app/Tests/WakilKitTests/PlaneTests.swift`
- Modify: `app/Sources/WakilApp/VoidView.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`
- Modify: `app/Sources/WakilApp/Rail.swift`

**Interfaces:**
- Consumes: `VoidPalette` (Task 4).
- Produces:

```swift
public enum Plane: Sendable, CaseIterable {
    case far, mid, near
    public var scale: Double
    public var opacity: Double
    public var blur: Double
    public var parallaxFactor: Double
    public func parallaxOffset(cursor: (x: Double, y: Double),
                               in size: (width: Double, height: Double)) -> (x: Double, y: Double)
    public static let maximumOffset: Double
}
```

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/PlaneTests.swift`:

```swift
import Testing
@testable import WakilKit

@Test func theThreePlanesCarrySection3sConstants() {
    #expect(Plane.far.scale == 0.94)
    #expect(Plane.far.opacity == 0.30)
    #expect(Plane.far.blur == 1.4)
    // Mid is the data register: full scale, opaque, crisp. Any other value
    // here is §1's second principle broken in the type system.
    #expect(Plane.mid.scale == 1.0)
    #expect(Plane.mid.opacity == 1.0)
    #expect(Plane.mid.blur == 0.0)
    #expect(Plane.near.scale == 1.0)
    #expect(Plane.near.opacity == 1.0)
    #expect(Plane.near.blur == 0.0)
}

/// Spec §6: parallax moves the void and the far plane and never a pane.
/// Moving a data surface under the cursor while it is being read fights
/// §1's legibility register and makes table text shimmer.
@Test func theMidPlaneNeverParallaxes() {
    #expect(Plane.mid.parallaxFactor == 0)
    let offset = Plane.mid.parallaxOffset(cursor: (x: 0, y: 0), in: (width: 100, height: 100))
    #expect(offset.x == 0)
    #expect(offset.y == 0)
}

@Test func theCursorAtTheCentreMeansNoOffset() {
    let offset = Plane.far.parallaxOffset(cursor: (x: 50, y: 40), in: (width: 100, height: 80))
    #expect(abs(offset.x) < 1e-9)
    #expect(abs(offset.y) < 1e-9)
}

@Test func everyCornerIsWithinTheMaximumOffset() {
    let size = (width: 100.0, height: 80.0)
    for cursor in [(x: 0.0, y: 0.0), (x: 100.0, y: 0.0), (x: 0.0, y: 80.0), (x: 100.0, y: 80.0)] {
        let offset = Plane.far.parallaxOffset(cursor: cursor, in: size)
        #expect(abs(offset.x) <= Plane.maximumOffset + 1e-9)
        #expect(abs(offset.y) <= Plane.maximumOffset + 1e-9)
    }
}

/// A cursor dragged outside the window — which happens on every drag that
/// leaves the frame — must not send the far plane arbitrarily far.
@Test func aCursorOutsideTheWindowIsClamped() {
    let offset = Plane.far.parallaxOffset(cursor: (x: -900, y: 4000), in: (width: 100, height: 80))
    #expect(abs(offset.x) <= Plane.maximumOffset + 1e-9)
    #expect(abs(offset.y) <= Plane.maximumOffset + 1e-9)
}

/// A zero-sized window is what a view reports for one frame at launch.
/// Dividing by it must not produce NaN, which would propagate into a
/// transform and blank the view.
@Test func aZeroSizedWindowYieldsNoOffsetRatherThanNaN() {
    let offset = Plane.far.parallaxOffset(cursor: (x: 10, y: 10), in: (width: 0, height: 0))
    #expect(offset.x == 0)
    #expect(offset.y == 0)
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd app && ../scripts/swift-test.sh --filter Plane
```

Expected: FAIL — `cannot find 'Plane' in scope`.

- [ ] **Step 3: Implement**

`app/Sources/WakilKit/Visual/Plane.swift`:

```swift
import Foundation

/// `design-language.md` §3's three planes, and how far each one moves
/// against the cursor.
///
/// Depth is expressed through scale, opacity and blur **together** — never
/// one alone — which is why all three are properties of the same value
/// rather than three constants a view happens to apply in the same place.
public enum Plane: Sendable, CaseIterable {
    /// Ambient context: the rail, the status line. Blurred and dimmed, so
    /// it can move freely — nothing on it is being read.
    case far
    /// The active data surface. §1's second register: full contrast, crisp,
    /// and **still**.
    case mid
    /// The Core and the thought thread. Brightest, may overlap.
    case near

    public var scale: Double {
        switch self {
        case .far: return 0.94
        case .mid, .near: return 1.0
        }
    }

    public var opacity: Double {
        switch self {
        case .far: return 0.30
        case .mid, .near: return 1.0
        }
    }

    public var blur: Double {
        switch self {
        case .far: return 1.4
        case .mid, .near: return 0.0
        }
    }

    /// The furthest any plane moves from its resting position, in points.
    ///
    /// One number, deliberately, because it is the thing most likely to be
    /// wrong: the magnitude that reads as depth and the magnitude that
    /// reads as instability are close together, and only the operator can
    /// tell them apart. Tuning it must not be a code change anywhere else.
    public static let maximumOffset: Double = 8

    /// How much of `maximumOffset` this plane takes.
    ///
    /// **The mid plane is zero and that is a rule, not a tuning.** Spec §6:
    /// parallax moves the void and the far plane and never a pane. A data
    /// surface that shifts while it is being read fights §1's legibility
    /// register, and text sliding against the pixel grid shimmers.
    public var parallaxFactor: Double {
        switch self {
        case .far: return 1.0
        case .mid: return 0.0
        // The near plane moves opposite the far one, at half the distance.
        // Opposing directions are what makes two layers read as depth
        // rather than as one layer sliding.
        case .near: return -0.5
        }
    }

    /// Where this plane sits, given the cursor's position within a window
    /// of `size`. `(0, 0)` when the cursor is at the centre.
    ///
    /// Clamped, so a cursor dragged outside the window — which happens on
    /// every drag that leaves the frame — cannot send a plane arbitrarily
    /// far. A zero-sized window yields zero rather than NaN; a view reports
    /// one for a frame at launch, and a NaN in a transform blanks it.
    public func parallaxOffset(
        cursor: (x: Double, y: Double),
        in size: (width: Double, height: Double)
    ) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (x: 0, y: 0) }
        let nx = min(max((cursor.x / size.width) * 2 - 1, -1), 1)
        let ny = min(max((cursor.y / size.height) * 2 - 1, -1), 1)
        let d = Plane.maximumOffset * parallaxFactor
        return (x: nx * d, y: ny * d)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd app && ../scripts/swift-test.sh --filter Plane
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Track the cursor, without awaiting anything**

In `WakilWindow.swift`, add local state and a hover handler. This is the same shape as
2b-i's `dragOffsets`: `@State` updated per pointer event, no dispatch, no `await`.

```swift
/// The cursor's position in the window, and the window's size — the two
/// inputs `Plane.parallaxOffset` needs.
///
/// Local `@State`, updated on every pointer-moved event, exactly as
/// `dragOffsets` is and for the same reason: §10's rule is that nothing on
/// the frame path awaits. A parallax that dispatched an action per event
/// would journal thousands of entries and put an actor hop between the
/// pointer and the frame.
@State private var cursor: CGPoint = .zero
@State private var windowSize: CGSize = .zero
```

On the `ZStack`, add:

```swift
.onContinuousHover { phase in
    if case .active(let location) = phase { cursor = location }
}
.background(GeometryReader { geometry in
    Color.clear.onAppear { windowSize = geometry.size }
        .onChange(of: geometry.size) { _, new in windowSize = new }
})
```

Compute the offsets once:

```swift
private var farOffset: (x: Double, y: Double) {
    Plane.far.parallaxOffset(
        cursor: (x: cursor.x, y: cursor.y),
        in: (width: windowSize.width, height: windowSize.height))
}
```

- [ ] **Step 6: Move the void and the far plane**

Pass the offset to `VoidView` — add `let parallax: CGSize` to it, set
`uniforms.parallax` from it, divided by the drawable size so the shader receives it in uv
space:

```swift
parallax: SIMD2(Float(parallax.width / max(view.drawableSize.width, 1)),
                Float(parallax.height / max(view.drawableSize.height, 1)))
```

In `Rail.swift`, apply the far plane to the rail:

```swift
.scaleEffect(Plane.far.scale)
.opacity(Plane.far.opacity)
.blur(radius: Plane.far.blur)
.offset(x: farOffset.x, y: farOffset.y)
.animation(.easeOut(duration: 0.4), value: cursor)
```

Do the same to the context line (org / project / environment). **Do not apply any of it
to `canvas(model)`** — `Plane.mid.parallaxFactor` is zero and the panes stay still.

- [ ] **Step 7: See it, and be honest about the magnitude**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Move the cursor slowly across the window. Expected: the bleeds and the rail drift
slightly, in opposite directions, and the panes do not move at all. If it reads as
instability rather than depth, lower `Plane.maximumOffset` — that is the one constant it
is meant to be.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/Visual/Plane.swift app/Tests/WakilKitTests/PlaneTests.swift \
        app/Sources/WakilApp/
git commit -m "2b-ii Task 5: the three planes, and parallax that never moves a pane

Plane.mid.parallaxFactor is zero as a rule rather than a tuning: a data
surface that shifts while it is being read fights §1's legibility register.
Clamped at the window's edges, zero on a zero-sized window — a NaN in a
transform blanks the view."
```

---

## Task 6: `CoreState` and turn-in-flight

**Files:**
- Create: `app/Sources/WakilKit/Visual/CoreState.swift`
- Create: `app/Tests/WakilKitTests/CoreStateTests.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`send`, `append`)

**Interfaces:**
- Consumes: nothing.
- Produces:

```swift
public enum CoreState: String, Sendable, Equatable, CaseIterable {
    case idle, listening, thinking, speaking
    public static func forTurn(inFlight: Bool) -> CoreState
}
// on WindowModel:
public private(set) var turnInFlight: Bool
public var coreState: CoreState { CoreState.forTurn(inFlight: turnInFlight) }
```

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/CoreStateTests.swift`:

```swift
import Testing
@testable import WakilKit

@Test func theCoreIsIdleWithNoTurnAndThinkingWithOne() {
    #expect(CoreState.forTurn(inFlight: false) == .idle)
    #expect(CoreState.forTurn(inFlight: true) == .thinking)
}

/// Spec §4.1: the shader renders four states and the app sets two. The
/// other two exist so 2d wires a microphone into a renderer that is already
/// there rather than writing the same four-state shader twice.
@Test func allFourStatesExistAndHaveStableRawValues() {
    #expect(CoreState.allCases.count == 4)
    #expect(CoreState.idle.rawValue == "idle")
    #expect(CoreState.listening.rawValue == "listening")
    #expect(CoreState.thinking.rawValue == "thinking")
    #expect(CoreState.speaking.rawValue == "speaking")
}

/// The shader takes the state as an integer uniform, so the ordering is
/// part of the wire format between Swift and Metal and cannot be reordered
/// silently.
@Test func theShaderIndexIsStable() {
    #expect(CoreState.idle.shaderIndex == 0)
    #expect(CoreState.listening.shaderIndex == 1)
    #expect(CoreState.thinking.shaderIndex == 2)
    #expect(CoreState.speaking.shaderIndex == 3)
}
```

Then, in `app/Tests/WakilKitTests/WindowModelTests.swift`, append:

```swift
// MARK: - Core state

/// A turn is in flight from a successful `send` until the `.result` event
/// that ends it. Nothing else sets it — spec §4.1.
@MainActor
@Test func aTurnInFlightMakesTheCoreThink() async {
    let model = makeModel()
    #expect(model.coreState == .idle)
    model.beginTurnForTesting()
    #expect(model.coreState == .thinking)
    model.appendForTesting(.result(isError: false, text: "done"))
    #expect(model.coreState == .idle)
}

/// A turn that ended in error still ended. Leaving the Core thinking after
/// a failed turn would be a sphere that never stops.
@MainActor
@Test func aFailedTurnAlsoEndsTheThinking() async {
    let model = makeModel()
    model.beginTurnForTesting()
    model.appendForTesting(.result(isError: true, text: "boom"))
    #expect(model.coreState == .idle)
}

/// A `send` with no harness never started a turn, so nothing may be in
/// flight — otherwise the Core thinks forever on a machine with no provider
/// configured, which is the documented degraded launch.
@MainActor
@Test func aSendWithNoHarnessLeavesTheCoreIdle() async {
    let model = makeModel()          // built with harness: nil
    await model.send("hello")
    #expect(model.coreState == .idle)
    #expect(!model.status.isEmpty)
}
```

Use the same `makeModel()` helper the existing `WindowModelTests` uses; if it takes
arguments, pass whatever the existing tests pass for a model with no harness.

- [ ] **Step 2: Run them to verify they fail**

```bash
cd app && ../scripts/swift-test.sh --filter "CoreState|Core"
```

Expected: FAIL — `cannot find 'CoreState' in scope`.

- [ ] **Step 3: Implement `CoreState`**

`app/Sources/WakilKit/Visual/CoreState.swift`:

```swift
import Foundation

/// Which of `design-language.md` §4's four states the Core is in.
///
/// **All four are rendered; two are ever set** (spec §4.1). Listening and
/// speaking belong to voice, which is 2d, and driving them from proxies
/// available today — assistant text arriving is not speech, a focused
/// prompt field is not listening — would invent semantics 2d then has to
/// unpick. Rendering them now costs nothing (the probe already captured all
/// four) and saves writing the same four-state shader twice.
public enum CoreState: String, Sendable, Equatable, CaseIterable {
    /// Desaturated, 5.4 s breath. Present but asleep.
    case idle
    /// Fully saturated, rings tighten, breath quickens to 1.5 s. **2d.**
    case listening
    /// Iridescence rotates — internal turbulence.
    case thinking
    /// Pulses on speech cadence, shifts toward green. **2d.**
    case speaking

    /// The state for a session with, or without, a turn in flight.
    public static func forTurn(inFlight: Bool) -> CoreState {
        inFlight ? .thinking : .idle
    }

    /// What the shader receives. Part of the wire format between Swift and
    /// Metal — `Core.metal` branches on these integers — so the order is
    /// pinned by a test rather than left to declaration order.
    public var shaderIndex: Int32 {
        switch self {
        case .idle: return 0
        case .listening: return 1
        case .thinking: return 2
        case .speaking: return 3
        }
    }
}
```

- [ ] **Step 4: Track the turn in `WindowModel`**

Add beside the other observed properties (near line 424, with `thoughts`):

```swift
/// Whether a turn is in flight: true from a successful `send`, false on
/// the `.result` event that ends it. The Core reads it through
/// `coreState` and nothing else does.
///
/// Set on the *successful* path only. A `send` that failed — no harness,
/// which is the ordinary degraded launch — never started a turn, and a
/// Core left thinking forever is worse than one that never started.
public private(set) var turnInFlight = false

/// Which of §4's four states the Core draws. See `CoreState`.
public var coreState: CoreState { CoreState.forTurn(inFlight: turnInFlight) }
```

In `send(_:)`, after `try await harness.send(text)` and before `status = ""`:

```swift
turnInFlight = true
```

In `append(_:)`, before projecting the row:

```swift
if case .result = event { turnInFlight = false }
```

Add the two test hooks next to them, `internal` so `@testable import` reaches them and
nothing outside the module can:

```swift
/// Test hook: `send` needs a live harness to reach `turnInFlight = true`,
/// and `CoreStateTests` must not spawn `claude` to check a boolean.
func beginTurnForTesting() { turnInFlight = true }
/// Test hook: drives `append` directly, so the `.result` transition can be
/// exercised without a harness.
func appendForTesting(_ event: HarnessEvent) { append(event) }
```

- [ ] **Step 5: Run the tests**

```bash
cd app && ../scripts/swift-test.sh --filter "CoreState|Turn|Core"
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Visual/CoreState.swift \
        app/Tests/WakilKitTests/CoreStateTests.swift \
        app/Tests/WakilKitTests/WindowModelTests.swift \
        app/Sources/WakilKit/App/WindowModel.swift
git commit -m "2b-ii Task 6: CoreState, driven by whether a turn is in flight

Four states, two ever set. turnInFlight is true only on the successful send
path — a send with no harness never started a turn, and the degraded launch
must not leave the Core thinking forever."
```

---

## Task 7: `Core.metal` and the `CoreView` layer

The largest task, and the one whose result is judged by eye. It fixes the three defects
the probe's capture showed.

**Files:**
- Create: `app/Shaders/Core.metal`
- Create: `app/Sources/WakilApp/CoreView.swift`
- Modify: `Makefile` (the `shaders` target compiles both files)
- Modify: `app/Sources/WakilApp/WakilWindow.swift`

**Interfaces:**
- Consumes: `CoreState` (Task 6), `Plane` (Task 5).
- Produces: `struct CoreView: NSViewRepresentable` with
  `init(state: CoreState, parallax: CGSize)`.

- [ ] **Step 1: Compile both shaders**

In `Makefile`, extend the `shaders` target:

```make
shaders:
	xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal app/Shaders/Core.metal
```

One `.metallib` from both sources; `makeDefaultLibrary(bundle:)` finds every function in
it by name, so both views share one library.

- [ ] **Step 2: Write the shader**

`app/Shaders/Core.metal`. Three things here are the probe's §5 defects being fixed, and
each is commented as such.

```metal
#include <metal_stdlib>
using namespace metal;

struct CoreVertex {
    float4 position [[position]];
    float2 uv;
};

struct CoreUniforms {
    float2 resolution;
    float  time;        // seconds since the view appeared
    int    state;       // CoreState.shaderIndex
    float2 parallax;    // in uv units
};

vertex CoreVertex core_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    CoreVertex out;
    out.uv = uv;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return out;
}

// §5's iridescent palette, as a closed loop.
//
// **Probe §5 defect 1, fixed here.** The capture showed a hard radial seam
// because atan2 wraps at ±π and a four-stop palette does not close across
// the wrap. Summing cosines is periodic by construction, so there is no
// wrap to close: the function is continuous at every angle including the
// one where the old one jumped.
static float3 iridescence(float t) {
    const float3 dc     = float3(0.42, 0.40, 0.62);
    const float3 amp    = float3(0.34, 0.30, 0.36);
    const float3 freq   = float3(1.0, 1.0, 1.0);
    const float3 phase  = float3(0.00, 0.28, 0.62);   // violet → blue → mint → magenta
    return dc + amp * cos(6.28318 * (freq * t + phase));
}

fragment float4 core_fragment(CoreVertex in [[stage_in]],
                              constant CoreUniforms &u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);

    // Breath and bob. §7: 5.4s breath at idle, 1.5s listening; 6.5s bob,
    // independent of the breath cycle.
    float breathPeriod = (u.state == 1) ? 1.5 : 5.4;
    float breath = 0.5 + 0.5 * sin(6.28318 * u.time / breathPeriod);
    float bob    = sin(6.28318 * u.time / 6.5) * 0.012;

    float2 centre = float2(0.5, 0.5) + u.parallax + float2(0.0, bob);
    float2 p = (in.uv - centre) * float2(aspect, 1.0);
    float r = length(p) / 0.13;                  // 0 at the centre, 1 at the rim
    float angle = atan2(p.y, p.x) / 6.28318 + 0.5;

    // Thinking rotates the iridescence — §4's "internal turbulence".
    float spin = (u.state == 2) ? u.time * 0.22 : u.time * 0.03;
    float3 colour = iridescence(angle + spin + r * 0.18);

    // Idle is desaturated; listening is fully saturated; speaking shifts
    // toward the mint green of §5.
    float luma = dot(colour, float3(0.299, 0.587, 0.114));
    float saturation = (u.state == 0) ? 0.45 : 1.0;
    colour = mix(float3(luma), colour, saturation);
    if (u.state == 3) {
        float pulse = 0.5 + 0.5 * sin(6.28318 * u.time / 0.42);
        colour = mix(colour, float3(0.545, 0.878, 0.784), 0.35 * pulse);  // #8be0c8
    }

    // **Probe §5 defect 3, fixed here.** Rim occlusion was too weak for the
    // sphere to read as a volume rather than a disc. A sphere's own surface
    // turns away from the viewer near the rim, so the term is the surface
    // normal's z — sqrt(1 - r²) — not a flat radial ramp, and it is applied
    // as a power so the falloff bites in the outer third.
    float nz = sqrt(max(1.0 - r * r, 0.0));
    colour *= pow(nz, 0.55) * 0.72 + 0.28;
    colour *= 1.0 - 0.42 * pow(clamp(r, 0.0, 1.0), 3.0);

    // **Probe §5 defect 2, fixed here.** The specular was too large and too
    // hot, so the sphere read as pearl. §4 fixes its placement at 34%/26%
    // and that was already right; the radius drops to a quarter of what the
    // probe drew and the intensity is halved, so it reads as a highlight on
    // a volume rather than as a second light source.
    float2 spec = p - float2(-0.32, -0.48) * 0.13;
    float specular = exp(-dot(spec, spec) / (2.0 * 0.00035)) * 0.55;
    colour += specular * nz;

    // The sphere's own edge, and the outer bloom §4 gives it.
    float sphere = smoothstep(1.0, 0.985, r);
    float bloom  = exp(-max(r - 1.0, 0.0) * 5.5) * 0.22 * (0.75 + 0.25 * breath);

    // The single permitted ornament (§4): two thin tick rings, reactive —
    // they tighten and accelerate on listening. Nothing else is drawn.
    float ringPhase = (u.state == 1) ? u.time * 1.8 : u.time * 0.5;
    float ringRadius = (u.state == 1) ? 1.22 : 1.34;
    float ticks = step(0.82, fract((angle + ringPhase) * 48.0));
    float ring = ticks * exp(-pow((r - ringRadius) * 26.0, 2.0)) * 0.55;
    float ring2 = step(0.90, fract((angle - ringPhase * 0.6) * 32.0))
                * exp(-pow((r - ringRadius * 1.14) * 30.0, 2.0)) * 0.32;

    float3 out = colour * sphere * (0.82 + 0.18 * breath)
               + float3(0.486, 0.361, 1.0) * (bloom + ring + ring2);
    float alpha = clamp(sphere + bloom + ring + ring2, 0.0, 1.0);
    return float4(out, alpha);
}
```

- [ ] **Step 3: Write the view**

`app/Sources/WakilApp/CoreView.swift`. Structurally like `VoidView`, with the opposite
cadence and a transparent drawable — it sits **in front of** the panes.

```swift
import MetalKit
import WakilKit
import SwiftUI

/// The Core, drawn in Metal in front of the panes (spec §2.1).
///
/// **Continuous, where `VoidView` is paused.** §4's Core has a breathing
/// idle state and genuinely wants a clock; the void behind it is static.
/// Two cadences is the reason this is a second Metal layer rather than one
/// shader behind everything — and one layer would also put the Core behind
/// the panes, which §3 forbids.
struct CoreView: NSViewRepresentable {
    let state: CoreState
    let parallax: CGSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        // The cap north-star.md §8 asks for: a statement of intent and a
        // guard on future hardware. It clamps nothing on this machine —
        // both displays are 60 Hz — and the saving is in VoidView being
        // paused, not here.
        view.preferredFramesPerSecond = 120
        // Transparent: the void and the panes are behind this layer and
        // must show through everywhere the Core is not. The transparency is
        // set on the layer, not on the view — `NSView.isOpaque` is get-only.
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.state = state
        context.coordinator.parallax = parallax
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        var state: CoreState = .idle
        var parallax: CGSize = .zero
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let start = CFAbsoluteTimeGetCurrent()

        struct CoreUniforms {
            var resolution: SIMD2<Float> = .zero
            var time: Float = 0
            var state: Int32 = 0
            var parallax: SIMD2<Float> = .zero
        }

        override init() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = try? device.makeDefaultLibrary(bundle: .module) else {
                fatalError("CoreView: no Metal device or no default.metallib — run `make shaders`")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "core_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "core_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // Premultiplied source-over: the shader returns colour already
            // scaled by its own coverage, so the panes behind show through
            // everywhere the Core does not cover.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.device = device
            self.queue = queue
            self.pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }
            var uniforms = CoreUniforms(
                resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                time: Float(CFAbsoluteTimeGetCurrent() - start),
                state: state.shaderIndex,
                parallax: SIMD2(Float(parallax.width / max(view.drawableSize.width, 1)),
                                Float(parallax.height / max(view.drawableSize.height, 1))))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CoreUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
```

- [ ] **Step 4: Put it in front**

In `WakilWindow.swift`, the `ZStack` becomes three layers in spec §2's order. The Core
takes the **near** plane's parallax, which opposes the far plane's:

```swift
ZStack {
    VoidView(palette: VoidPalette.forEnvironment(session?.model.environment ?? ""),
             parallax: CGSize(width: farOffset.x, height: farOffset.y))
        .ignoresSafeArea()

    VStack(alignment: .leading) { /* … the existing content … */ }
        .padding()

    CoreView(state: session?.model.coreState ?? .idle,
             parallax: CGSize(width: nearOffset.x, height: nearOffset.y))
        .ignoresSafeArea()
        // The Core is not a control. Without this it would swallow every
        // click meant for a pane beneath it.
        .allowsHitTesting(false)
}
```

Add `nearOffset` beside `farOffset`, using `Plane.near`.

- [ ] **Step 5: Look at all four states**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Expected: a desaturated sphere breathing slowly, drifting on a longer cycle, in front of
the panes, with two thin tick rings. Clicking a pane behind it still works.

To see thinking, send a message to the agent — the sphere saturates and its iridescence
starts rotating. To see listening and speaking, temporarily hard-code
`CoreView(state: .listening, ...)`, look, and change it back. Task 13 automates this.

**Check the three defects specifically**, because they are why this task exists: no hard
radial line anywhere on the sphere at any angle; the highlight reads as a highlight, not
as a pearl surface; and the sphere reads as a ball rather than a disc.

- [ ] **Step 6: Confirm the tests still pass**

```bash
make app-test 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Makefile app/Shaders/Core.metal app/Sources/WakilApp/
git commit -m "2b-ii Task 7: the Core, in a second Metal layer in front of the panes

Four states rendered, two set. Continuous where VoidView is paused, which is
why it is a second layer — and one layer would put the Core behind the panes,
which §3 forbids.

Fixes the probe's three §5 defects: the conic seam (a cosine palette is
periodic, so there is no wrap to close), the specular (quarter the radius,
half the intensity), and rim occlusion (the surface normal's z, not a flat
radial ramp)."
```

---

## Task 8: The thought thread

**Files:**
- Create: `app/Sources/WakilApp/ThoughtThread.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`thoughtRow`, `append`)
- Modify: `app/Tests/WakilKitTests/WindowModelTests.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`

**Interfaces:**
- Consumes: `Plane` (Task 5).
- Produces: `func thoughtRow(id: Int, for event: HarnessEvent) -> ThoughtRow?` — **the
  return type changes from non-optional**. Every caller must handle `nil`.

- [ ] **Step 1: Invert the existing test and add the new ones**

In `app/Tests/WakilKitTests/WindowModelTests.swift`, replace
`thoughtRowShowsAnUnknownFrameByItsType` entirely — the comment above it states the
opposite of what is now true and must go with it:

```swift
/// Probe §2 found `.unknown` to be the path most events take — 10 of
/// `basic-turn.jsonl`'s 13 lines are `stream_event`, `rate_limit_event` or
/// `session_state_changed`. 2a drew them, because §7 asked for a plain list
/// of harness events. §9's thread holds perhaps six lines before the live
/// step is pushed off the end, so drawing them buries the four lines that
/// describe work under eleven that do not, and defeats the only claim §9
/// makes. Spec §7.1.
@Test func anUnknownFrameProducesNoRowAtAll() {
    #expect(thoughtRow(id: 6, for: .unknown(type: "rate_limit_event")) == nil)
    #expect(thoughtRow(id: 7, for: .unknown(type: "system")) == nil)
}

@Test func everyEventThatDescribesWorkStillProducesARow() {
    #expect(thoughtRow(id: 0, for: .assistantText("hello")) != nil)
    #expect(thoughtRow(id: 1, for: .toolUse(id: "t", name: "n", input: .object([:]))) != nil)
    #expect(thoughtRow(id: 2, for: .toolResult(id: "t", content: .string("ok"), isError: false)) != nil)
    #expect(thoughtRow(id: 3, for: .result(isError: false, text: "done")) != nil)
    #expect(thoughtRow(id: 4, for: .systemInit(sessionId: "s")) != nil)
}

/// Row ids must stay unique once some events produce no row. `append`
/// numbers from a counter of its own rather than from `thoughts.count`,
/// which would repeat an id after any drop — and `ThoughtRow` is
/// `Identifiable`, so a repeated id makes SwiftUI draw one row twice and
/// omit another.
@MainActor
@Test func droppedEventsDoNotCollapseRowIds() async {
    let model = makeModel()
    model.appendForTesting(.assistantText("one"))
    model.appendForTesting(.unknown(type: "rate_limit_event"))
    model.appendForTesting(.assistantText("two"))
    #expect(model.thoughts.count == 2)
    #expect(model.thoughts[0].id != model.thoughts[1].id)
}
```

The four surviving `thoughtRow…` tests above it now compare against an optional. Add `!`
to each: `thoughtRow(id: 0, for: .assistantText("hello"))!`.

- [ ] **Step 2: Run them to verify they fail**

```bash
cd app && ../scripts/swift-test.sh --filter thought
```

Expected: FAIL — `value of type 'ThoughtRow' has no member` / `cannot convert value of
type 'ThoughtRow' to 'ThoughtRow?'`, and `anUnknownFrameProducesNoRowAtAll` failing on a
non-nil row.

- [ ] **Step 3: Make `thoughtRow` optional and give `append` its own counter**

In `WindowModel.swift`, change the signature and the `.unknown` case:

```swift
/// Projects one `HarnessEvent` into a thought-thread row, or into nothing.
///
/// **`.unknown` yields `nil`, and that changed in 2b-ii** (spec §7.1). 2a
/// drew every case, because §7 asked for a plain list of harness events and
/// a list can carry noise. §9's thread rises out of the Core and holds
/// perhaps six lines; the probe measured 10 of a turn's 13 events as
/// `.unknown`, so drawing them buries the lines that describe work under
/// the ones that do not.
public func thoughtRow(id: Int, for event: HarnessEvent) -> ThoughtRow? {
    switch event {
    // …the five other cases unchanged…
    case .unknown:
        return nil
    }
}
```

Add the counter next to `thoughts` and use it in `append`:

```swift
/// Monotonic row ids. **Not `thoughts.count`**, which was correct while
/// every event produced a row and repeats an id the moment one does not —
/// `ThoughtRow` is `Identifiable`, so a repeated id makes SwiftUI draw one
/// row twice and omit another.
private var nextThoughtId = 0

private func append(_ event: HarnessEvent) {
    if case .result = event { turnInFlight = false }
    guard let row = thoughtRow(id: nextThoughtId, for: event) else { return }
    nextThoughtId += 1
    thoughts.append(row)
}
```

Note the ordering: `turnInFlight` is cleared **before** the `guard`, so an event that
produces no row can still end a turn.

- [ ] **Step 4: Run the tests**

```bash
cd app && ../scripts/swift-test.sh --filter "thought|Thought"
```

Expected: PASS.

- [ ] **Step 5: Draw the thread**

`app/Sources/WakilApp/ThoughtThread.swift`:

```swift
import WakilKit
import SwiftUI

/// §9's thought thread, on the near plane: agent progress rising out of the
/// Core. Completed steps fade to dim green, the live step is brightest.
/// This replaces spinners and progress bars entirely.
///
/// **No upcoming steps**, and `design-language.md` §9 was amended on
/// 2026-09-09 to remove them: harness events arrive one at a time and
/// nothing announces what the agent will do next, so an upcoming step could
/// only be invented.
struct ThoughtThread: View {
    let rows: [ThoughtRow]

    /// How many rows the thread shows. Six, because a thread rising out of
    /// the Core is a peripheral object — reading it should not be a
    /// scrolling exercise, and the substance lands in panes, not here (§12).
    private static let visible = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label.uppercased())
                        .font(.system(size: 8.5, weight: .medium))
                        .tracking(1.6)                       // §6: .16–.22em at 8.5px
                        .frame(width: 74, alignment: .trailing)
                        .foregroundStyle(colour(for: row).opacity(0.55))
                    Text(row.detail)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(colour(for: row))
                }
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: rows.count)   // §7: 250ms + 4px rise
        .allowsHitTesting(false)
    }

    private var shown: [ThoughtRow] {
        Array(rows.suffix(Self.visible))
    }

    /// Completed steps are dim green (§5: green is completed), the live
    /// step — the last one — is at full text weight, and a failure is red.
    private func colour(for row: ThoughtRow) -> Color {
        if row.isError { return Color(red: 0.910, green: 0.361, blue: 0.361) }   // #e85c5c
        if row.id == rows.last?.id { return Color(red: 0.910, green: 0.925, blue: 0.965) }
        return Color(red: 0.545, green: 0.878, blue: 0.784).opacity(0.45)        // #8be0c8
    }
}
```

In `WakilWindow.swift`, replace the existing `List(model.thoughts) { … }` with
`ThoughtThread(rows: model.thoughts)`.

- [ ] **Step 6: See it during a real turn**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Send the agent something that uses a tool — *"run select 1"* against a configured
project. Expected: four or five lines, each rising as it arrives, the newest brightest and
the older ones dim green. No `event stream_event` rows.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift \
        app/Tests/WakilKitTests/WindowModelTests.swift \
        app/Sources/WakilApp/
git commit -m "2b-ii Task 8: the thought thread, showing only what describes work

thoughtRow returns nil for .unknown — 10 of a turn's 13 events, per the
probe. append numbers rows from its own counter, because thoughts.count
repeats an id the moment an event produces no row, and ThoughtRow is
Identifiable.

turnInFlight clears before the guard, so an event that draws nothing can
still end a turn."
```

---

## Task 9: Panes as slabs

§8 as treatment. What a data surface *contains* is 2c's.

**Files:**
- Modify: `app/Sources/WakilApp/Canvas.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift`

**Interfaces:**
- Consumes: `Plane` (Task 5).
- Produces: nothing new; `paneView` changes appearance only.

- [ ] **Step 1: Make the pane a slab**

In `Canvas.swift`, `paneView` gets §2's slab treatment. **No border**, per §2 — the edge
is a half-pixel luminous line and a drop shadow:

```swift
.background(
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        // Near-opaque, never translucent. §1's second register: the
        // atmosphere stops at the slab's edge, and a data surface with the
        // void showing through it is unreadable at exactly the moment it
        // matters.
        .fill(Color(red: 0.055, green: 0.063, blue: 0.098))
)
.overlay(
    // The half-pixel luminous edge §2 asks for, in place of a border.
    // Brighter at the top, where a light from above would catch it.
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                startPoint: .top, endPoint: .bottom),
            lineWidth: 0.5)
)
.shadow(color: .black.opacity(0.55), radius: 18, y: 8)
```

- [ ] **Step 2: Apply §6's typography**

The pane's title becomes a micro-label; every numeric and identifier becomes monospace
with tabular figures.

```swift
Text(pane.title.uppercased())
    .font(.system(size: 9, weight: .medium))
    .tracking(1.7)
    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
```

In the `Table`'s cells:

```swift
Text(index < row.cells.count ? row.cells[index] : "")
    .font(.system(size: 12, design: .monospaced))
    .monospacedDigit()
```

Column headers take the same micro-label treatment as the title.

- [ ] **Step 3: Row separation by whitespace, and the active row's edge**

§8: no rules between rows, and the one luminous element permitted inside a data surface is
the active row's left edge. Apply generous vertical padding to each cell and, on the
selected row, a 2 pt violet capsule at the leading edge:

```swift
.padding(.vertical, 6)
.overlay(alignment: .leading) {
    if isActiveRow {
        Capsule()
            .fill(Color(red: 0.486, green: 0.361, blue: 1.0))
            .frame(width: 2)
    }
}
```

- [ ] **Step 4: Set the mid plane explicitly**

On the canvas in `WakilWindow.swift`, so the rule is visible in the code rather than
implied by its absence:

```swift
// The mid plane: full scale, opaque, crisp, and **still**. Plane.mid's
// parallax factor is zero (§6), so there is deliberately no .offset here.
canvas(model)
    .scaleEffect(Plane.mid.scale)
    .opacity(Plane.mid.opacity)
```

- [ ] **Step 5: Look at it**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Expected: panes read as slabs floating in the void — no outlines, a soft shadow, a faint
bright edge along the top. Run a query: the table's text is monospaced and legible at full
contrast, with no glow and no translucency behind it.

- [ ] **Step 6: Confirm the tests still pass**

```bash
make app-test 2>&1 | tail -5
```

Expected: PASS. Nothing in `WakilKit` changed.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilApp/
git commit -m "2b-ii Task 9: panes as slabs — §8 as treatment

Rounded near-opaque surface, drop shadow, half-pixel luminous edge, no
border. Micro-labels at §6's tracking, monospace tabular figures for data,
whitespace between rows rather than rules, and the active row's left edge as
the only luminous thing inside a data surface.

What a data surface contains — chips, null, column types, the footer — is
2c's, and needs a second data source to be designed against."
```

---

## Task 10: `pane_set_density` — ⌘⇧D as an action

**Files:**
- Modify: `app/Sources/WakilKit/Layout/Pane.swift`
- Modify: `app/Sources/WakilKit/Layout/LayoutStore.swift`
- Modify: `app/Sources/WakilKit/Layout/LayoutActions.swift`
- Modify: `app/Tests/WakilKitTests/LayoutActionsTests.swift`
- Modify: `app/Tests/WakilKitTests/PaneTests.swift`
- Modify: `app/Sources/WakilApp/AppScene.swift`
- Modify: `app/Sources/WakilApp/Canvas.swift`

**Interfaces:**
- Consumes: `LayoutStore`, `ActionRegistry` (2b-i).
- Produces:

```swift
public enum PaneDensity: String, Sendable, Codable, CaseIterable {
    case airy, dense
    public var rowHeight: Double     // 40, 23
    public var toggled: PaneDensity
}
// on Pane:      public var density: PaneDensity = .airy   (in CodingKeys — it persists)
// on LayoutStore: public func setDensity(_ density: PaneDensity, id: String) throws
// registry:     "pane_set_density", .control, params { id: String, density: String }
```

- [ ] **Step 1: Write the failing tests**

Append to `app/Tests/WakilKitTests/PaneTests.swift`:

```swift
@Test func aNewPaneIsAiry() {
    let pane = Pane(id: "db-1", kind: "db", title: "t",
                    frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
    #expect(pane.density == .airy)
}

@Test func densityCarriesSection8sRowHeights() {
    #expect(PaneDensity.airy.rowHeight == 40)
    #expect(PaneDensity.dense.rowHeight == 23)
    #expect(PaneDensity.airy.toggled == .dense)
    #expect(PaneDensity.dense.toggled == .airy)
}

/// §8: "remembered per pane". Unlike `busy`, density is a setting rather
/// than runtime state, so it *is* in `CodingKeys` and does survive a quit.
@Test func densitySurvivesAJSONRoundTrip() throws {
    var pane = Pane(id: "db-1", kind: "db", title: "t",
                    frame: PaneFrame(x: 1, y: 2, width: 3, height: 4))
    pane.density = .dense
    let data = try JSONEncoder().encode(pane)
    #expect(try JSONDecoder().decode(Pane.self, from: data).density == .dense)
}

/// A layout written before this field existed must still open. Failing to
/// decode would take the whole arrangement down for a row height.
@Test func aPaneSavedBeforeDensityExistedDecodesAsAiry() throws {
    let json = Data("""
    {"id":"db-1","kind":"db","title":"t","frame":{"x":0,"y":0,"width":1,"height":1}}
    """.utf8)
    #expect(try JSONDecoder().decode(Pane.self, from: json).density == .airy)
}
```

Append to `app/Tests/WakilKitTests/LayoutActionsTests.swift`, following the shape the
existing action tests use there:

```swift
@Test func paneSetDensityIsAControlActionAndChangesOnePane() async throws {
    let layout = LayoutStore()
    let registry = ActionRegistry(journal: Journal())
    await registerLayoutActions(into: registry, layout: layout)
    let a = await layout.open(kind: "db", title: "a")
    let b = await layout.open(kind: "db", title: "b")

    let action = await registry.all().first { $0.name == "pane_set_density" }
    // .control, not .mutate: changing a row height changes Wakil and
    // nothing else, so the gate's production rule must not apply — being
    // pointed at a production database is no reason to be unable to make a
    // table denser. Spec §11.
    #expect(action?.kind == .control)

    _ = try await registry.dispatch(
        "pane_set_density",
        params: .object(["id": .string(a.id), "density": .string("dense")]),
        origin: .ui, environment: "staging")

    let snapshot = await layout.snapshot()
    #expect(snapshot.panes.first { $0.id == a.id }?.density == .dense)
    #expect(snapshot.panes.first { $0.id == b.id }?.density == .airy)
}

@Test func paneSetDensityRejectsAnUnknownValue() async throws {
    let layout = LayoutStore()
    let registry = ActionRegistry(journal: Journal())
    await registerLayoutActions(into: registry, layout: layout)
    let pane = await layout.open(kind: "db", title: "a")

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            "pane_set_density",
            params: .object(["id": .string(pane.id), "density": .string("compact")]),
            origin: .ui, environment: "staging")
    }
}
```

Match the exact `ActionRegistry` / `Journal` / `dispatch` construction the neighbouring
tests in that file already use — copy their setup rather than the sketch above if it
differs.

- [ ] **Step 2: Run them to verify they fail**

```bash
cd app && ../scripts/swift-test.sh --filter "density|Density"
```

Expected: FAIL — `cannot find 'PaneDensity' in scope`.

- [ ] **Step 3: Add the type and the field**

In `app/Sources/WakilKit/Layout/Pane.swift`, above `Pane`:

```swift
/// How tall a data surface's rows are — `design-language.md` §8's density
/// toggle, remembered per pane.
///
/// Airy is the default, chosen for beauty and for the secondary line it
/// affords; dense exists because scanning a large result set is the pane's
/// real job.
public enum PaneDensity: String, Sendable, Codable, CaseIterable {
    case airy, dense

    public var rowHeight: Double {
        switch self {
        case .airy: return 40
        case .dense: return 23
        }
    }

    public var toggled: PaneDensity { self == .airy ? .dense : .airy }
}
```

On `Pane`, beside `busy`:

```swift
/// This pane's row density (§8), remembered per pane.
///
/// **In `CodingKeys`, unlike `busy`**, and the distinction is the point: a
/// dispatch that was in flight when the app quit is not in flight when it
/// reopens, but a pane the operator made dense is still meant to be dense.
/// Runtime state is dropped on save; settings are kept. The default value
/// is what lets a layout written before this field existed decode as airy
/// rather than fail.
public var density: PaneDensity = .airy
```

and add `density` to the `CodingKeys` enum.

- [ ] **Step 4: Add the store method**

In `LayoutStore.swift`, beside `setBusy`:

```swift
/// Sets one pane's row density. Throws if no pane has that id, like every
/// other id-taking method here.
public func setDensity(_ density: PaneDensity, id: String) throws {
    _ = try requirePane(id)
    guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }
    current.panes[index].density = density
}
```

Use whatever the actor's own name for the active snapshot is — `requirePane` returns it,
so follow how `setBusy` and `move` reach the pane array and mirror that exactly.

- [ ] **Step 5: Register the action**

In `LayoutActions.swift`, after the last `registry.register(...)` call, and update the
doc comment's *"eight layout actions"* to *"nine"*:

```swift
await registry.register(Action(
    name: "pane_set_density",
    description: "Set a pane's row density: \"airy\" (40pt rows) or \"dense\" (23pt).",
    kind: .control,
    schema: .object([
        "type": .string("object"),
        "properties": .object([
            "id": .object(["type": .string("string")]),
            "density": .object([
                "type": .string("string"),
                "enum": .array([.string("airy"), .string("dense")]),
            ]),
        ]),
        "required": .array([.string("id"), .string("density")]),
    ]),
    handler: { params in
        let id = try requireString(params, "id", action: "pane_set_density")
        let raw = try requireString(params, "density", action: "pane_set_density")
        guard let density = PaneDensity(rawValue: raw) else {
            throw LayoutActionError.badParam(action: "pane_set_density", param: "density", value: raw)
        }
        try await layout.setDensity(density, id: id)
        return .object([:])
    }
))
```

- [ ] **Step 6: Run the tests**

```bash
cd app && ../scripts/swift-test.sh --filter "density|Density|Layout"
```

Expected: PASS.

- [ ] **Step 7: Bind ⌘⇧D and use the row height**

In `AppScene.swift`, in the same `CommandGroup(after: .windowArrangement)` as *Maximize
Pane*:

```swift
Button("Toggle Density") {
    focusedPane { model, id in await model.toggleDensity(id: id) }
}
.keyboardShortcut("d", modifiers: [.command, .shift])
```

On `WindowModel`, beside `toggleMaximize`, and following its exact dispatch shape:

```swift
/// Toggles the focused pane's density (§8's ⌘⇧D).
///
/// Dispatches rather than mutating, like every other control in this
/// window: Invariant 2 does not stop at layout, and a toggle wired
/// straight to `@State` would be the first thing here the agent cannot do
/// and the journal cannot see.
public func toggleDensity(id: String) async {
    let current = layoutSnapshot.panes.first { $0.id == id }?.density ?? .airy
    await dispatchLayout("pane_set_density", params: .object([
        "id": .string(id),
        "density": .string(current.toggled.rawValue),
    ]))
}
```

In `Canvas.swift`, apply it to the table: `.frame(height: pane.density.rowHeight)` on the
row content, or `Table`'s `.rowHeight` equivalent for the SwiftUI version in use.

- [ ] **Step 8: Confirm ⌘K lists it and the toggle works**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Press ⌘K and type `density` — the action is there, because the palette is
`registry.all()`. Run a query, press ⌘⇧D, and the rows tighten. Quit and reopen: the pane
is still dense.

- [ ] **Step 9: Commit**

```bash
git add app/Sources/WakilKit/Layout/ app/Tests/WakilKitTests/ app/Sources/WakilApp/
git commit -m "2b-ii Task 10: pane_set_density — §8's toggle as a registry action

.control, because changing a row height changes Wakil and nothing else.
Persisted, unlike busy: a dispatch in flight at quit is not in flight at
launch, but a pane the operator made dense is still meant to be dense. A
layout written before the field existed decodes as airy."
```

---

## Task 11: Motion — the project-switch transition, and maximize fading the rail and Core

**Files:**
- Modify: `app/Sources/WakilApp/WakilWindow.swift`
- Modify: `app/Sources/WakilApp/Canvas.swift`
- Modify: `app/Sources/WakilApp/Rail.swift`

**Interfaces:**
- Consumes: `Plane`, `WindowModel.layoutSnapshot`, `WindowModel.project`.
- Produces: nothing new.

- [ ] **Step 1: Animate the swap**

`LayoutStore` already keeps every visited project's panes in memory, so a switch is a swap
and there is nothing to rebuild. What is missing is the motion that covers the reconnect
underneath it. In `WakilWindow.swift`:

```swift
/// The project the canvas is currently drawing. Changing it is what
/// triggers §13's transition — the outgoing arrangement recedes while the
/// incoming one rises, so the ~400ms reconnect happens behind motion
/// rather than behind a frozen window.
///
/// `.id(model.project)` is what makes SwiftUI treat the two arrangements as
/// different views rather than as one view whose contents changed; without
/// it there is no insertion or removal to transition.
canvas(model)
    .id(model.project)
    .transition(.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 1.04)),
        removal: .opacity.combined(with: .scale(scale: 0.96))))
    .animation(.easeOut(duration: 0.5), value: model.project)
```

500 ms, from §13's *"the outgoing pane recedes while the incoming rises (~500ms)"* — and
within §7's 400–600 ms band for a plane transition, which is what this is.

- [ ] **Step 2: Fade the rail and the Core on maximize**

§10 asks for it and 2b-i's maximize does not do it, because there was nothing to fade. In
`WakilWindow.swift`:

```swift
private var isMaximized: Bool { session?.model.layoutSnapshot.maximizedId != nil }
```

On the `CoreView` and on `rail(model)`:

```swift
.opacity(isMaximized ? 0.12 : 1)
.animation(.easeOut(duration: 0.45), value: isMaximized)
```

Not zero: §10 says *fade back*, not *disappear*, and a Core that vanishes reads as a bug
rather than as deference.

- [ ] **Step 3: Measure the switch**

With two projects registered, launch the app, then time a switch from the dispatch script
rather than by hand — a stopwatch cannot resolve 400 ms:

```bash
cat > /tmp/switch.jsonl <<'EOF'
{"action":"ctx_set_project","params":{"name":"<project-a>"}}
{"action":"ctx_set_project","params":{"name":"<project-b>"}}
EOF
time ./build/Wakil.app/Contents/MacOS/WakilApp --dispatch /tmp/switch.jsonl
```

Record the number. Expected: well under 400 ms for the swap — `LayoutStore` holds both
arrangements. Write it into the acceptance document in Task 13; this is the figure 2b-i
recorded as never measured.

- [ ] **Step 4: See both**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Switch project from ⌘P: the outgoing panes shrink and fade while the incoming ones grow
into place. Press ⌘⏎ on a focused pane: it fills the void and the rail and Core recede.

- [ ] **Step 5: Confirm the tests still pass**

```bash
make app-test 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp/
git commit -m "2b-ii Task 11: the project-switch transition, and maximize fades the rail and Core

500ms asymmetric transition keyed on the project id, so the reconnect
happens behind motion rather than behind a frozen window. Built now, while
switching is still cheap, so 2c inherits a budget instead of reworking four
pane kinds against a switch that flickers.

§10's 'the rail and Core fade back' finally has something to fade."
```

---

## Task 12: The window loses its title bar

**Files:**
- Modify: `app/Sources/WakilApp/AppScene.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Hide the title bar, keep the traffic lights**

In `AppScene.swift`, on the `WindowGroup`:

```swift
// §1's first principle is futurism through absence: no window chrome. The
// title bar hides and the traffic lights stay, so the void reaches all four
// edges — which is the claim §2 actually makes — while close, minimise,
// zoom, Mission Control, tiling and window restoration keep working.
//
// Fully borderless was the alternative and costs every one of those for
// three small circles.
.windowStyle(.hiddenTitleBar)
```

Then, in `WakilAppDelegate.applicationDidFinishLaunching` (add it if absent), make the
title bar transparent and the content full-size, since `.hiddenTitleBar` alone leaves the
bar's height reserved:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    guard let window = NSApp.windows.first else { return }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.styleMask.insert(.fullSizeContentView)
    // The void is the background. Without this the system window
    // background shows for one frame on launch and behind the rounded
    // corners forever.
    window.backgroundColor = NSColor(red: 0.012, green: 0.016, blue: 0.031, alpha: 1)
    window.isMovableByWindowBackground = true
}
```

- [ ] **Step 2: Check the traffic lights are still there and still work**

```bash
make app-build && make app-bundle && open build/Wakil.app
```

Expected: no title bar, the void reaching every edge, three traffic lights in the top
left over the void. Close, minimise and zoom all work; ⌘Q quits.

**Check one thing specifically:** the traffic lights must not sit on top of a pane's
controls. If the canvas starts under them, add top padding to the content layer — not to
the void, which is meant to reach the edge.

- [ ] **Step 3: Confirm the tests still pass**

```bash
make app-test 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/WakilApp/AppScene.swift
git commit -m "2b-ii Task 12: hide the title bar, keep the traffic lights

§1's first principle, delivered: the void reaches all four edges. Fully
borderless would cost close/minimise/zoom, Mission Control, tiling and
window restoration for three small circles."
```

---

## Task 13: The capture tool, the frame-cost measurement, and the acceptance document

**Files:**
- Create: `app/Sources/WakilApp/Capture.swift`
- Modify: `app/Sources/WakilApp/main.swift`
- Modify: `Makefile`
- Create: `docs/wakil/phase-2b-ii-acceptance.md`
- Modify: `docs/wakil/operator-todo.md`

**Interfaces:**
- Consumes: everything above.
- Produces: `--capture <directory>` on the `WakilApp` binary, writing one PNG per Core
  state and per environment, plus GPU frame timings on stdout.

- [ ] **Step 1: Add the flag, above the AppKit boundary**

In `main.swift`, beside the existing `--mcp-shim` and `--dispatch` checks and **before**
`WakilApplication.main()`, following exactly the argument-parsing shape those two use:

```swift
/// Returns the `--capture <directory>` value, or `nil` when the flag is
/// absent. Same shape and same reasoning as `shimSocketPath` above: exits
/// with a message when the flag is present and its value is missing.
private func capturePath(in arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--capture") else { return nil }
    guard let path = value(after: flagIndex, in: arguments, flag: "--capture", named: "<directory>") else {
        exit(1)
    }
    return path
}
```

and, after the `--dispatch` check:

```swift
// Offscreen rendering, so it runs without a window — but it does need a
// Metal device, so it sits *below* the two headless checks above rather
// than beside them. `runCapture` is synchronous: every draw is followed by
// `waitUntilCompleted`, because the GPU timestamps are the point.
if let directory = capturePath(in: CommandLine.arguments) {
    exit(runCapture(into: directory))
}
```

- [ ] **Step 2: Write the capture**

`app/Sources/WakilApp/Capture.swift`. Render each shader to an offscreen texture and write
a PNG, then time 260 frames of the Core and print the percentiles — the probe's method,
reused so the numbers are comparable.

```swift
import AppKit
import CoreGraphics
import ImageIO
import Metal
import WakilKit
import UniformTypeIdentifiers

/// Renders every Core state and every void palette offscreen and writes one
/// PNG each, then measures GPU cost over 260 frames.
///
/// **Not a pixel-diff gate, deliberately** (spec §11). A golden-image test
/// over a shader containing grain, a conic gradient and a time-varying
/// breath fails on a toolchain update and gets disabled within a week, and a
/// disabled test is worse than an honest runbook line. These exist to be
/// looked at, and the acceptance document records what was seen.
///
/// 900×620 and 260 frames with the first 10 dropped, matching
/// `docs/wakil/phase-2b-probe.md` §3 exactly, so the numbers here are
/// comparable with the probe's rather than merely plausible.
func runCapture(into directory: String) -> Int32 {
    let width = 900, height = 620

    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let library = try? device.makeDefaultLibrary(bundle: .module) else {
        FileHandle.standardError.write(Data("wakil --capture: no Metal device or no default.metallib — run `make shaders`\n".utf8))
        return 1
    }

    func pipeline(_ vertexName: String, _ fragmentName: String, blending: Bool) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexName)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        if blending {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    guard let voidPipeline = pipeline("void_vertex", "void_fragment", blending: false),
          let corePipeline = pipeline("core_vertex", "core_fragment", blending: true) else {
        FileHandle.standardError.write(Data("wakil --capture: could not build a pipeline\n".utf8))
        return 1
    }

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    textureDescriptor.usage = [.renderTarget, .shaderRead]
    guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
        FileHandle.standardError.write(Data("wakil --capture: could not allocate the target texture\n".utf8))
        return 1
    }

    // These two mirror the `VoidUniforms` and `CoreUniforms` in VoidView and
    // CoreView. They are declared again here rather than shared because
    // both of those are private to their own view; if either wire format
    // changes, all three change together or the capture draws nonsense.
    struct VoidUniforms {
        var resolution: SIMD2<Float>
        var bleedA: SIMD3<Float>
        var bleedB: SIMD3<Float>
        var parallax: SIMD2<Float>
    }
    struct CoreUniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var state: Int32
        var parallax: SIMD2<Float>
    }

    let resolution = SIMD2(Float(width), Float(height))

    /// Draws the void, and optionally the Core over it, into `texture`.
    /// Returns the command buffer so the caller can read its GPU timestamps.
    @discardableResult
    func render(palette: VoidPalette, state: CoreState?, time: Float) -> MTLCommandBuffer? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var voidUniforms = VoidUniforms(
            resolution: resolution,
            bleedA: SIMD3(Float(palette.bleedA.r), Float(palette.bleedA.g), Float(palette.bleedA.b)),
            bleedB: SIMD3(Float(palette.bleedB.r), Float(palette.bleedB.g), Float(palette.bleedB.b)),
            parallax: .zero)
        encoder.setRenderPipelineState(voidPipeline)
        encoder.setFragmentBytes(&voidUniforms, length: MemoryLayout<VoidUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if let state {
            var coreUniforms = CoreUniforms(
                resolution: resolution, time: time, state: state.shaderIndex, parallax: .zero)
            encoder.setRenderPipelineState(corePipeline)
            encoder.setFragmentBytes(&coreUniforms, length: MemoryLayout<CoreUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer
    }

    /// Reads the target texture back and writes it as a PNG.
    func writePNG(to path: String) -> Bool {
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(
            &bytes, bytesPerRow: rowBytes,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // The texture is BGRA; CGImage is told so by the byte-order flag
        // rather than by swizzling the buffer.
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

    let staging = VoidPalette.forEnvironment("staging")

    // One PNG per Core state. time = 2.0 rather than 0, so idle is not
    // caught at a zero crossing of its 5.4s breath and photographed at its
    // dimmest.
    for state in CoreState.allCases {
        guard render(palette: staging, state: state, time: 2.0) != nil,
              writePNG(to: "\(directory)/core-\(state.rawValue).png") else {
            FileHandle.standardError.write(Data("wakil --capture: failed on core-\(state.rawValue)\n".utf8))
            return 1
        }
        print("wrote core-\(state.rawValue).png")
    }

    // One PNG per environment, void only — the production treatment is
    // about the room, so photographing it with the Core in front would
    // photograph the wrong thing.
    for name in ["staging", "production"] {
        guard render(palette: VoidPalette.forEnvironment(name), state: nil, time: 0) != nil,
              writePNG(to: "\(directory)/void-\(name).png") else {
            FileHandle.standardError.write(Data("wakil --capture: failed on void-\(name)\n".utf8))
            return 1
        }
        print("wrote void-\(name).png")
    }

    // 260 frames, first 10 dropped as warm-up — the probe's method.
    var timings: [Double] = []
    for frame in 0..<260 {
        guard let buffer = render(palette: staging, state: .thinking, time: Float(frame) / 60.0) else {
            return 1
        }
        if frame >= 10 {
            timings.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0)
        }
    }
    timings.sort()
    func percentile(_ p: Double) -> Double {
        timings[min(timings.count - 1, Int(Double(timings.count) * p))]
    }
    print(String(
        format: "core gpu p50=%.3fms p95=%.3fms max=%.3fms over %d frames",
        percentile(0.50), percentile(0.95), timings.last ?? 0, timings.count))
    // Printed, not asserted. The budget is 8.33ms at 120fps and this
    // machine cannot display 120fps at all (probe §4), so the honest output
    // is the cost beside the refresh rate that could not test it.
    print(String(
        format: "budget 8.33ms at 120fps; this display reports %dHz",
        NSScreen.main?.maximumFramesPerSecond ?? 0))
    return 0
}
```


- [ ] **Step 3: Add the make target**

```make
# Writes one PNG per Core state and per environment into .context/, and
# prints GPU frame cost against the 8.33ms budget. Not a pixel-diff gate —
# see the 2b-ii spec §11.
captures: app-build
	mkdir -p .context/2b-ii
	cd app && swift run WakilApp --capture ../.context/2b-ii
```

- [ ] **Step 4: Run it**

```bash
make captures
open .context/2b-ii
```

Expected: six PNGs — `core-idle`, `core-listening`, `core-thinking`, `core-speaking`,
`void-staging`, `void-production` — and a line of timings on stdout. Record the timings;
they go into the acceptance document.

- [ ] **Step 5: Write the acceptance document**

`docs/wakil/phase-2b-ii-acceptance.md`, following `phase-2b-i-acceptance.md`'s shape:

- **§0 Why this list is short** — most of this phase is judged by eye, and the document
  says which parts a machine checked and which it did not.
- **§1 Before you start** — `make app-build`, `make app-test`, `make captures`.
- **§2 The standing checks**, one per thing only a person can answer:
  1. The void reads as depth rather than as a gradient; no banding where the bleeds meet.
  2. The Core reads as a volume, not a disc; no seam at any angle; the highlight is a
     highlight, not pearl. Compare against `.context/core-probe-states.png` — the three
     defects the probe found should be visibly gone.
  3. Production is alarming without being exhausting. Switch to a production environment
     and back.
  4. Parallax adds depth without inducing motion sickness.
  5. The thought thread is readable during a real turn, and carries no `stream_event`
     rows.
  6. ⌘⇧D tightens the rows, survives a quit, and appears in ⌘K.
  7. ⌘⏎ fills the void and the rail and Core fade back.
  8. Switching project moves rather than flickers.
- **§3 What was verified headlessly** — the unit tests, named.
- **§4 What 2b-ii cannot verify, and why** — 120 fps (both displays 60 Hz, name them);
  listening and speaking as application states (rendered and photographed, never set);
  2a's acceptance checks 5 and 6, still, because this phase registers no `.mutate` action.
- **§5 Recorded measurements** — the GPU percentiles from Step 4 against the 8.33 ms
  budget, and the project-switch number from Task 11 Step 3.

- [ ] **Step 6: Update the operator TODO**

In `docs/wakil/operator-todo.md`, under *"Phase 2b toolchain"*, add:

```
**As of 2b-ii this is no longer advisory.** `make app-build` depends on `make shaders`,
which runs `xcrun metal`. A machine without the Metal Toolchain component cannot build
Wakil at all — the failure names the fix, but only after the download has been attempted.
```

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilApp/Capture.swift app/Sources/WakilApp/main.swift Makefile \
        docs/wakil/phase-2b-ii-acceptance.md docs/wakil/operator-todo.md
git commit -m "2b-ii Task 13: the capture tool, the frame measurement, and the runbook

--capture writes one PNG per Core state and per environment and prints GPU
cost over 260 frames, the probe's method, so the numbers are comparable.
Deliberately not a pixel-diff gate: a golden image over grain and a
time-varying breath gets disabled within a week.

The acceptance document says plainly which checks a machine ran and which it
could not — 120fps among them, on two 60Hz displays."
```

---

## Task 14: Close out the phase

**Files:**
- Modify: `docs/wakil/north-star.md`
- Modify: `docs/wakil/design-language.md`

- [ ] **Step 1: Mark 2b-ii met in the phase map**

In `north-star.md` §8, mark the 2b-ii row met with its date and a pointer to
`docs/wakil/phase-2b-ii-acceptance.md`, in the same form the 2a and 2b-i rows use.

- [ ] **Step 2: Answer the frame-rate note honestly**

`north-star.md` §8's *"An input to 2b-ii: cap the frame rate, but cap the right thing"*
predicted three things. Add a dated paragraph recording what happened to each:

1. The cap was set (`preferredFramesPerSecond = 120` on `CoreView`) and clamps nothing on
   this machine, exactly as predicted.
2. The saving came from `VoidView` being paused — a still window draws zero void frames.
3. The two cadences were kept apart by making them two Metal layers, which the depth model
   required anyway.

- [ ] **Step 3: Close the design language's open items this phase settled**

In `design-language.md` §15, strike the items 2b-ii answered and leave the rest. Red's hex
was recorded in Task 4. The typeface, the full-working-day density test, and the light
variant all stay open — say so rather than deleting them.

- [ ] **Step 4: Commit**

```bash
git add docs/wakil/
git commit -m "2b-ii: phase map and design language updated

north-star.md §8 records what happened to each of the three predictions its
frame-rate note made. The cap was set and clamps nothing; the saving came
from the paused void; the two cadences are two layers, which §3 required
anyway."
```

---

## Self-Review

**Spec coverage.** Every section of the spec has a task: §2.1/§2.4 → Tasks 2 and 7 · §2.2
→ Tasks 2 and 7 · §2.3 → Tasks 4, 5, 6 · §3.1 → Task 3 · §3.2 → Task 4 · §4.1 → Tasks 6
and 7 · §4.2 → Task 7 · §4.3 → Task 7 · §5 → Task 9 · §5.1 → Task 10 · §6 → Task 5 · §7 →
Task 8 · §8.1/§8.2 → Task 11 · §9 → Task 12 · §10 → Task 13 · §11 → Task 13 · §13 → Task
1 for the split, and every task for its own files.

**Two gaps found and closed while reviewing:** the spec's §7.2 amendment to
`design-language.md` §9 was already committed with the spec, so no task repeats it; and
red had no hex anywhere in the design language, which Task 4 Step 6 now records.

**Type consistency.** `VoidPalette.forEnvironment` / `RGB` (Task 4) is used unchanged in
Tasks 4 and 13 · `Plane.parallaxOffset(cursor:in:)` (Task 5) in Tasks 5, 7, 9 ·
`CoreState.shaderIndex` (Task 6) in Tasks 7 and 13 · `PaneDensity.rowHeight` (Task 10) in
Task 10 · `thoughtRow(id:for:) -> ThoughtRow?` (Task 8) in Task 8 only. `VoidView`'s
initialiser grows across Tasks 2, 4 and 5, and each task states the signature it leaves
behind.
