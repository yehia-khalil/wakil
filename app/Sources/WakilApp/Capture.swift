import AppKit
import CoreGraphics
import ImageIO
import Metal
import WakilKit
import UniformTypeIdentifiers

/// Reads `texture` back and writes it as a PNG at `path`.
///
/// File-scope and shared: `runCapture` and `runCaptureMotion` differ only in
/// the dimensions and texture they close over, and duplicating this body
/// between them would be two copies of the same bug waiting to diverge.
private func writePNG(from texture: MTLTexture, width: Int, height: Int, to path: String) -> Bool {
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

/// Renders every state of the room and every void palette offscreen and
/// writes one PNG each, then measures GPU cost over 260 frames.
///
/// **Not a pixel-diff gate, deliberately** (spec §11). A golden-image test
/// over a shader containing grain, two moving bleeds and a time-varying
/// breath fails on a toolchain update and gets disabled within a week, and a
/// disabled test is worse than an honest runbook line. These exist to be
/// looked at, and the acceptance document records what was seen.
///
/// 900×620 and 260 frames with the first 10 dropped, matching
/// `docs/wakil/phase-2b-probe.md` §3's *point* dimensions and frame count.
///
/// **Fix round 1 correction (Task 13 review).** That comment used to claim
/// the resulting number was "comparable with the probe's rather than merely
/// plausible." It was not comparable, and the claim was never checked: this
/// function allocates a `900×620` texture in raw pixels, while the probe ran
/// an `MTKView`, whose `drawableSize` is `bounds.size × backingScaleFactor`
/// by default — 2.0 on this machine, per `VoidView.swift`'s own measured
/// comment (`bounds {1470, 923}` vs. `drawableSize {2940, 1846}`). A fragment
/// shader's cost is close to linear in pixel count, so a measurement at a
/// quarter of the probe's likely pixel count was never a fair comparison.
/// `docs/wakil/phase-2b-probe.md` itself only ever states a "900×620
/// window" — never a drawable size — so the probe's true pixel count is not
/// recorded anywhere and could not be confirmed, only inferred. Below, this
/// function now also measures at `1800×1240` — double on both axes, matching
/// the 2.0 backing-scale figure actually measured elsewhere in this app —
/// and reports both numbers, each labelled with the resolution it was taken
/// at, rather than reporting one number as though resolution did not matter.
func runCapture(into directory: String) -> Int32 {
    let width = 900, height = 620

    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let library = try? device.makeDefaultLibrary(bundle: .module) else {
        FileHandle.standardError.write(Data("wakil --capture: no Metal device or no default.metallib — run `make shaders`\n".utf8))
        return 1
    }

    func pipeline(_ vertexName: String, _ fragmentName: String) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexName)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    guard let voidPipeline = pipeline("void_vertex", "void_fragment") else {
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

    let resolution = SIMD2(Float(width), Float(height))

    /// Draws the room, in the given state, into `texture`. Returns the
    /// command buffer so the caller can read its GPU timestamps.
    @discardableResult
    func render(palette: VoidPalette, state: CoreState, time: Float) -> MTLCommandBuffer? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var voidUniforms = VoidUniforms(
            resolution: resolution, palette: palette, parallax: .zero, time: time,
            motion: CoreMotion.forState(state),
            threadAnchorX: 0.5, threadLift: 0, ambientScale: 1)
        encoder.setRenderPipelineState(voidPipeline)
        encoder.setFragmentBytes(&voidUniforms, length: MemoryLayout<VoidUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer
    }

    let staging = VoidPalette.forEnvironment("staging", production: .undeclared)

    // One PNG per state — of the room, which is now the Core. time = 2.0
    // rather than 0, so idle is not caught at a zero crossing of its 5.4 s
    // breath and photographed at its dimmest.
    for state in CoreState.allCases {
        guard render(palette: staging, state: state, time: 2.0) != nil,
              writePNG(from: texture, width: width, height: height, to: "\(directory)/room-\(state.rawValue).png") else {
            FileHandle.standardError.write(Data("wakil --capture: failed on room-\(state.rawValue)\n".utf8))
            return 1
        }
        print("wrote room-\(state.rawValue).png")
    }

    // One PNG per environment, at idle — the production treatment is about
    // the room itself, not about any one state of it.
    for name in ["staging", "production"] {
        guard render(palette: VoidPalette.forEnvironment(name, production: .undeclared), state: .idle, time: 2.0) != nil,
              writePNG(from: texture, width: width, height: height, to: "\(directory)/void-\(name).png") else {
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
        format: "room gpu (%dx%d) p50=%.3fms p95=%.3fms max=%.3fms over %d frames",
        width, height, percentile(0.50), percentile(0.95), timings.last ?? 0, timings.count))

    // Fix round 1 (Task 13 review): re-measured at double both axes, to match
    // the physical-pixel drawable the app actually renders into on a 2.0
    // backing-scale display (see the doc comment above this function for the
    // full account). A second texture and a second draw path — not a reuse
    // of `texture`/`render` above — so the six PNGs and the first measurement
    // are untouched by this addition.
    let scaledWidth = width * 2, scaledHeight = height * 2
    let scaledDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: scaledWidth, height: scaledHeight, mipmapped: false)
    scaledDescriptor.usage = [.renderTarget, .shaderRead]
    guard let scaledTexture = device.makeTexture(descriptor: scaledDescriptor) else {
        FileHandle.standardError.write(Data("wakil --capture: could not allocate the scaled measurement texture\n".utf8))
        return 1
    }
    let scaledResolution = SIMD2(Float(scaledWidth), Float(scaledHeight))

    func renderScaled(time: Float) -> MTLCommandBuffer? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scaledTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var voidUniforms = VoidUniforms(
            resolution: scaledResolution, palette: staging, parallax: .zero, time: time,
            motion: CoreMotion.forState(.thinking),
            threadAnchorX: 0.5, threadLift: 0, ambientScale: 1)
        encoder.setRenderPipelineState(voidPipeline)
        encoder.setFragmentBytes(&voidUniforms, length: MemoryLayout<VoidUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer
    }

    var scaledTimings: [Double] = []
    for frame in 0..<260 {
        guard let buffer = renderScaled(time: Float(frame) / 60.0) else { return 1 }
        if frame >= 10 {
            scaledTimings.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0)
        }
    }
    scaledTimings.sort()
    func scaledPercentile(_ p: Double) -> Double {
        scaledTimings[min(scaledTimings.count - 1, Int(Double(scaledTimings.count) * p))]
    }
    print(String(
        format: "room gpu (%dx%d, 2x) p50=%.3fms p95=%.3fms max=%.3fms over %d frames",
        scaledWidth, scaledHeight, scaledPercentile(0.50), scaledPercentile(0.95),
        scaledTimings.last ?? 0, scaledTimings.count))

    // Printed, not asserted. The budget is 8.33ms at 120fps and this
    // machine cannot display 120fps at all (probe §4), so the honest output
    // is the cost beside the refresh rate that could not test it.
    print(String(
        format: "budget 8.33ms at 120fps; this display reports %dHz",
        NSScreen.main?.maximumFramesPerSecond ?? 0))
    return 0
}

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
/// frames and the five sequences together are 536 PNGs (81+45+180+50+180 —
/// idle, listening, thinking, speaking, and thinking-production for check
/// 4), so the smaller frame keeps the gitignored output to tens of
/// megabytes rather than hundreds. Frame *cost* is measured by `--capture`;
/// this is for looking at.
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

    // Four states in staging, plus thinking in production — the one
    // combination the spec's §10 check 5 asks about, because it is where
    // "hue is the environment's and motion is the agent's" either holds or
    // does not.
    let sequences: [(name: String, palette: VoidPalette, state: CoreState)] =
        CoreState.allCases.map { (name: $0.rawValue, palette: VoidPalette.forEnvironment("staging", production: .undeclared), state: $0) }
        + [(name: "thinking-production", palette: VoidPalette.forEnvironment("production", production: .undeclared), state: .thinking)]

    for sequence in sequences {
        let motion = CoreMotion.forState(sequence.state)
        let rate = motion.restingFrameRate
        let frames = Int((motion.period * Double(rate)).rounded())
        for frame in 0..<frames {
            let time = Float(Double(frame) / Double(rate))
            guard render(palette: sequence.palette, state: sequence.state, time: time),
                  writePNG(from: texture, width: width, height: height,
                           to: String(format: "%@/motion-%@-%04d.png", directory, sequence.name, frame))
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
