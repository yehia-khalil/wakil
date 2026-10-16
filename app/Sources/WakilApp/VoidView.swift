import MetalKit
import QuartzCore
import WakilKit
import SwiftUI

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
    /// `nil` before an organisation is open (Task 14, spec §8.5) — the
    /// room draws no bleeds at all rather than a guessed or default
    /// colour. See `VoidUniforms.init`'s own doc comment for the boundary
    /// where that absence actually takes effect.
    let palette: VoidPalette?
    /// Which of §4's four states the room is in. Sets both what the shader
    /// draws and how often it is asked to.
    let state: CoreState
    /// The far plane's parallax offset, in points — the window's `farOffset`.
    /// Converted to uv units in `draw(in:)`, because the shader's `uv` runs
    /// 0…1 across the drawable and a point offset means something different
    /// at every window size.
    let parallax: CGSize
    /// §10: "the rail and Core fade back" when a pane is maximized. With no
    /// Core, the room defers instead — its bleeds recede toward the bare
    /// field while the motion continues underneath, so it reads as the same
    /// room with the lights down. Not to zero, which would read as a bug
    /// rather than as deference.
    let isMaximized: Bool
    /// Where §9's thread meets the bottom edge, in uv.
    let threadAnchorX: Double
    /// Whether the thread has any rows right now — `ThreadLift`'s "is
    /// there anything to lift for". Read from the live row count
    /// (`!thoughts.isEmpty`), not from whether a row has *ever* arrived:
    /// `lastRowAt` below is set forward-only and never cleared, so it
    /// stays non-nil for the rest of the session once anything has
    /// happened — "a row arrived at some point" is not "the thread has
    /// rows now", and conflating the two was Task 5's fix-round Finding 2.
    let hasRows: Bool
    /// Whether a turn is in flight — `ThreadLift`'s "hold the glow up".
    let isTurnInFlight: Bool
    /// When the thread last gained a row, for `ThreadLift`'s decay
    /// (`secondsSinceLastRow`) only — not for whether it currently has
    /// rows; see `hasRows`.
    let lastRowAt: Date?

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        if coordinator.parallax != parallax {
            coordinator.parallax = parallax
            coordinator.boostForParallax(view)
        }
        // If a state change and a parallax change land in the same
        // `updateNSView` call, this branch runs *after* the boost above and
        // overwrites `preferredFramesPerSecond` with the new state's resting
        // rate — stomping the 120fps boost `boostForParallax` just set. Not
        // fixed, because it is self-healing and fixing it would add
        // ordering complexity for a one-frame cosmetic gap: the next
        // pointer-moved event re-triggers `boostForParallax` and restores
        // 120fps for its own 250ms window, same as any other parallax
        // change would.
        if coordinator.state != state {
            coordinator.state = state
            view.preferredFramesPerSecond = CoreMotion.forState(state).restingFrameRate
        }
        coordinator.ambientTarget = isMaximized ? Coordinator.maximizedAmbientScale : 1
        coordinator.threadAnchorX = threadAnchorX
        coordinator.hasRows = hasRows
        coordinator.isTurnInFlight = isTurnInFlight
        coordinator.lastRowAt = lastRowAt
        coordinator.observeOcclusion(of: view)
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        // `nil` — never `VoidPalette.forEnvironment("")` (T14-R5): this is
        // overwritten by `updateNSView` before any real draw, but the
        // ruling is that call must not exist anywhere on this path, full
        // stop, not "exist harmlessly because it's always overwritten".
        var palette: VoidPalette?
        var state: CoreState = .idle
        var parallax: CGSize = .zero
        // `CACurrentMediaTime()`, not `CFAbsoluteTimeGetCurrent()`: the
        // latter is wall-clock time, which can step backwards across an NTP
        // correction or a manual clock change — and every consumer of this
        // clock below (the parallax boost window, the ambient-ease and
        // breath-clock deltas) would wedge at its current value
        // until wall time caught back up. `CACurrentMediaTime()` is
        // monotonic and never steps backwards. (`ThreadLift`'s `Date` is a
        // separate clock, already guarded with `max(_, 0)` against the same
        // hazard — left alone.)
        /// The window currently being watched, so `observeOcclusion` can
        /// tell "already watching this one" from "the view moved to a new
        /// window" — `NSViewRepresentable` gives no `viewDidMoveToWindow`
        /// hook, so this is re-checked on every `updateNSView` instead.
        private weak var observedWindow: NSWindow?
        // `nonisolated(unsafe)`: a plain `@MainActor`-isolated stored
        // property cannot be touched from `deinit`, which the compiler
        // treats as running outside actor isolation regardless of the
        // class's own annotation (`NSObjectProtocol` is not `Sendable`
        // either, so there is no safe implicit hop). Safe here because
        // every write happens on the main actor already (`observeOcclusion`
        // and `updateNSView` are both `@MainActor`), and `deinit`'s one
        // read-then-remove is the only access that ever runs off it.
        private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?
        /// How long full rate is held after a parallax change. Long enough
        /// to cover the gap between two pointer-moved events during a slow
        /// drag, short enough that a window nobody is touching is back at
        /// its resting rate before anyone notices.
        static let parallaxBoostSeconds: Double = 0.25
        private var parallaxBoostUntil: CFTimeInterval = 0
        /// The bleed strength while a pane is maximized. `design-language.md`
        /// §10's deference, as a multiplier on the bleeds only.
        static let maximizedAmbientScale: Float = 0.4
        /// Where the ease is now. `NSViewRepresentable` does not animate its
        /// inputs, so the 450 ms `.easeOut` that used to sit on `CoreView`'s
        /// `.opacity` modifier is a per-frame approach in `draw(in:)`
        /// instead — which this view can do cheaply because, unlike the
        /// paused layer it replaces, it is already drawing on a clock.
        ///
        /// **A time constant, not a duration.** `draw(in:)` below is
        /// exponential decay (`ambientScale` moves a fraction of the
        /// remaining distance to `ambientTarget` every frame), not a
        /// fixed-duration ease — decay is what lets `ambientTarget` flip
        /// mid-flight without tracking a start value or restarting a curve.
        /// Exponential decay never *finishes*, so what this constant sets is
        /// how fast it approaches: after one time constant the remaining
        /// distance is ~37%, after three it is ~5% — visually settled. Spec
        /// §10's ~450 ms visible settle is therefore three of these, which
        /// is why this is 0.15 and not 0.45.
        static let ambientEaseTimeConstant: Double = 0.15
        var ambientTarget: Float = 1
        private var ambientScale: Float = 1
        private var lastDrawTime: CFTimeInterval = 0
        /// 2d-ii: phase-continuous, eased breath. `time` handed to the
        /// shader is the clock's, not wall time — see `BreathClock`.
        private var breath = BreathClock()
        var threadAnchorX: Double = 0.5
        var hasRows = false
        var isTurnInFlight = false
        var lastRowAt: Date?

        deinit {
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
            }
        }

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
            // `try?`, not `try!` (final review Finding 2, 2026-09-09):
            // `default.metallib` can exist yet not export `void_vertex` or
            // `void_fragment` — `make shaders`'s single `xcrun metal` command
            // line compiles both `.metal` files at once, and dropping one
            // filename from it leaves this library present but missing half
            // its functions. `makeFunction(name:)` answers `nil` rather than
            // throwing for that, so `descriptor.vertexFunction` above is
            // silently `nil` and only `makeRenderPipelineState` fails — a
            // bare `try!` there crashed with Metal's generic "vertex function
            // not found", naming neither cause nor cure. This names both, the
            // same way `Capture.swift`'s `pipeline(_:_:)` already does for
            // the identical failure.
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
                fatalError(
                    "VoidView: default.metallib is missing void_vertex/void_fragment — run `make shaders`")
            }
            self.pipeline = pipeline
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// **Inherited from `CoreView`, which 2b-iv deletes** (spec §5).
        /// Dropping it would have deleted a working, shipped power-saving fix
        /// (2b-ii final review Finding 3) as collateral damage of deleting
        /// the file it happened to live in, which is not a decision anybody
        /// made. The reasoning below is that review's, unchanged — only the
        /// layer it guards is different.
        ///
        /// **Pauses the Core while its window cannot be seen** (final
        /// review Finding 3, 2026-09-09). Nothing was observing
        /// `NSWindow.occlusionState` before this, so a 120fps continuous
        /// `MTKView` rendered forever — occluded behind another app,
        /// minimised to the Dock, the whole app backgrounded — defeating
        /// App Nap and keeping the display link alive on a laptop for a
        /// sphere nobody could see.
        ///
        /// **Signal chosen: `NSWindow.occlusionState`, not app-active
        /// state.** Occlusion covers minimised, fully-covered-by-another-
        /// window and other-space cases in one flag, which is the actual
        /// question ("can anything possibly be seeing this frame"). App
        /// activation is a different question — deliberately answered
        /// "no, don't pause on it": the Core is a presence indicator ("the
        /// agent is here and in this state"), not a decoration, and a
        /// window that is merely *not focused* while still fully visible
        /// (an editor in front, Wakil visible beside it) is exactly the
        /// case where a suddenly-frozen sphere would read as "Wakil
        /// stopped" rather than as the deliberate power saving it is.
        /// Visibility, not focus, is the bar.
        ///
        /// Registered here rather than in `makeNSView` because the view has
        /// no window yet at that point; `updateNSView` runs again as soon
        /// as SwiftUI has inserted it, so this re-checks on every call and
        /// does nothing once already watching the current window.
        func observeOcclusion(of view: MTKView) {
            guard let window = view.window, window !== observedWindow else { return }
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
            }
            observedWindow = window
            applyOcclusion(of: window, to: view)
            // `queue: .main` guarantees this block only ever runs on the
            // main thread, which is what makes `MainActor.assumeIsolated`
            // below sound — `addObserver(forName:object:queue:using:)`
            // itself takes a plain, non-`@MainActor` closure, so the
            // compiler cannot see that guarantee on its own.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let window = self.observedWindow else { return }
                    self.applyOcclusion(of: window, to: view)
                }
            }
        }

        private func applyOcclusion(of window: NSWindow, to view: MTKView) {
            view.isPaused = !window.occlusionState.contains(.visible)
        }

        /// **The one place 2b-iv could regress against 2b-ii, and does not.**
        /// A moving cursor means somebody is looking at this window, so it
        /// gets full rate; a still cursor over a still window is the idle
        /// case worth saving. Called only when the parallax actually
        /// changed — `updateNSView` fires on every `WakilWindow` body
        /// re-evaluation, including ones where nothing visual moved, and
        /// treating those as pointer motion would hold full rate forever
        /// while a session was merely streaming events.
        func boostForParallax(_ view: MTKView) {
            parallaxBoostUntil = CACurrentMediaTime() + Self.parallaxBoostSeconds
            view.preferredFramesPerSecond = 120
        }

        /// Drops back to the state's resting rate once the boost has run
        /// out. Called from `draw(in:)`, because that is the only thing that
        /// happens on a clock — a timer would be a second clock for no
        /// reason on a view that already has one.
        func expireParallaxBoost(_ view: MTKView) {
            guard parallaxBoostUntil > 0, CACurrentMediaTime() >= parallaxBoostUntil else { return }
            parallaxBoostUntil = 0
            view.preferredFramesPerSecond = CoreMotion.forState(state).restingFrameRate
        }

        func draw(in view: MTKView) {
            expireParallaxBoost(view)
            let now = CACurrentMediaTime()
            // First frame: no previous timestamp, so snap rather than
            // integrate against a nonsense delta.
            let delta = lastDrawTime == 0 ? Self.ambientEaseTimeConstant : now - lastDrawTime
            lastDrawTime = now
            let frame = breath.advance(
                by: delta, toward: CoreMotion.forState(state),
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            let step = Float(min(max(delta / Self.ambientEaseTimeConstant, 0), 1))
            ambientScale += (ambientTarget - ambientScale) * step
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }
            encoder.setRenderPipelineState(pipeline)
            // `parallax` arrives in points (it's `WakilWindow.farOffset`, computed
            // from `Plane.maximumOffset`, which is a point magnitude). `view.bounds`
            // is the view's size in points; `view.drawableSize` is the *drawable's*
            // size in physical pixels — 2x the point size on a Retina display, as
            // measured on this machine: bounds.size = {1470, 923} vs.
            // drawableSize = {2940, 1846}, backingScaleFactor 2.0. The shader's `uv`
            // runs 0…1 across the visible view, not across the pixel grid, so
            // dividing by `drawableSize` here would halve the excursion on any
            // Retina display. Divide by `bounds.size` instead.
            let boundsWidth = Float(max(view.bounds.size.width, 1))
            let boundsHeight = Float(max(view.bounds.size.height, 1))
            // Computed per frame, not per `updateNSView`: the decay is
            // continuous and this view is already on a clock, so a timer to
            // drive it separately would be a second clock for no reason.
            let lift = ThreadLift.value(
                hasRows: hasRows,
                isTurnInFlight: isTurnInFlight,
                secondsSinceLastRow: lastRowAt.map { -$0.timeIntervalSinceNow } ?? 0)
            var uniforms = VoidUniforms(
                resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                palette: palette,
                parallax: SIMD2(
                    Float(parallax.width) / boundsWidth,
                    Float(parallax.height) / boundsHeight),
                // The breath clock's time, not wall time: phase-continuous
                // across state changes and motion held still under Reduce Motion (time still advances).
                time: Float(frame.time),
                motion: frame.motion,
                threadAnchorX: Float(threadAnchorX),
                threadLift: Float(lift),
                ambientScale: ambientScale)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VoidUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
