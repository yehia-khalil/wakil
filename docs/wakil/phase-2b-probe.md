# Phase 2b — the Metal probe

**Run:** 2026-09-08 · **Machine:** MacBook Air M3 (`Mac15,12`), 10-core GPU, macOS 26.6.2
· **Toolchain:** Xcode 26, Swift 6.3.2, Metal Toolchain 17F109 · **Probe:**
`/tmp/coreprobe`, throwaway, outside the repo

Run before writing the 2b-i spec, to stop the Core being designed against assumptions.
The question was narrow — *can a SwiftPM package compile and host a Metal shader, and
what does the Core cost per frame* — and the answer to the second half is comfortable
enough that performance stopped being a design constraint. The answer to the first half
was not what the 2a spec assumed.

The probe drew `design-language.md` §2's void and §4's Core in one fragment shader, ran
it in an `MTKView` for 260 frames, and captured all four Core states offscreen. The
capture is at `.context/core-probe-states.png`.

---

## 1. Xcode alone is not enough — the Metal toolchain ships separately

`xcode-select -p` pointed at `/Applications/Xcode.app/Contents/Developer` and
`xcrun -f metal` resolved, but compiling anything failed:

    error: cannot execute tool 'metal' due to missing Metal Toolchain;
    use: xcodebuild -downloadComponent MetalToolchain

Xcode 26 moved the Metal compiler out of the app into a separately downloadable
component — 688 MB, installed with `xcodebuild -downloadComponent MetalToolchain`.
After that, `xcrun metal -O2 -o out.metallib in.metal` works.

`xcrun -f metallib` still fails. That is not a second missing component: recent
toolchains fold linking into the `metal` driver, and `metal -o foo.metallib` produces
the library directly. Nothing needs `metallib` by name.

**Consequence.** The 2a spec's *"install Xcode before 2b"* is necessary but not
sufficient, and a fresh machine will pass `xcrun -f metal` while still being unable to
build. `operator-todo.md` records both steps.

## 2. SwiftPM does not compile `.metal` files

The finding that changes the build. Declaring the shader as a resource —

```swift
.executableTarget(name: "CoreProbe", resources: [.process("Core.metal")])
```

— **copies the source into the resource bundle and compiles nothing.** The bundle held
`Core.metal` and no `.metallib` anywhere in `.build`, and
`device.makeDefaultLibrary(bundle:)` failed at runtime with:

    Error Domain=MTLLibraryErrorDomain Code=6 "no default library was found"

Compiling `.metal` is an Xcode *project* build rule. SwiftPM has no equivalent, and
`.process` has no special handling for the extension — it treats a shader as it would a
PNG. Wakil builds with `swift build` and a hand-assembled bundle (2a spec §2.1), so
this applies directly.

Three routes exist. All three were run:

| Route | Library load | Verdict |
|---|---|---|
| `xcrun metal` prebuild → `.copy("default.metallib")` | **0.6 ms** | Works. `makeDefaultLibrary(bundle:)` finds it by name. |
| `makeLibrary(source:)` at runtime, from the bundled `.metal` | **167.9 ms** | Works, needs no build-time toolchain, costs 168 ms every launch. |
| SwiftPM native compilation | — | Does not exist. |

**Chosen: the prebuild**, driven from the existing `Makefile` beside `app-bundle`. It
is 280× cheaper at launch, and — the better reason — it makes a broken shader a build
failure rather than a crash the first time a window opens. The cost is that
`make app-build` acquires a hard dependency on the Metal toolchain, which is why §1 is
written down.

The runtime route is worth remembering rather than discarding: it is the only one that
survives a machine without the toolchain, and 168 ms is tolerable for a developer
fallback if that is ever needed.

## 3. Performance is not a constraint

Release build, 900×620 window, 260 frames, first 10 dropped as warm-up. The shader drew
the full void — two radial bleeds, grain — plus the Core with its conic iridescence,
specular, rim occlusion, outer bloom and two tick rings.

| Measure | p50 | p95 | max |
|---|---|---|---|
| GPU time per frame | **1.090 ms** | 1.094 ms | 1.165 ms |
| CPU frame interval | 16.66 ms | 17.67 ms | 17.72 ms |

The 120fps budget is 8.33 ms per frame. **The Core spends about 13% of it**, leaving the
rest for everything the design language puts on top. The CPU interval sits exactly on
the 60 Hz vsync period with no dropped frames, which says the pacing is display-bound
rather than work-bound.

§13's *"the Core is a Metal/GPU shader, never CPU"* is therefore settled cheaply, and
the Core is not where the frame budget will be spent. If 2b misses 120fps, the cause
will be SwiftUI layout or the data grid, not the shader.

## 4. 120fps cannot be verified on this machine

`NSScreen.main.maximumFramesPerSecond` reports **60**. The build machine is a MacBook
Air M3 — Liquid Retina, no ProMotion — with a 60 Hz Samsung LF22T35 attached. Neither
display can show a 120fps frame.

So the north-star's *"120fps shell on ProMotion"* is unfalsifiable here, and no 2b
acceptance document may claim it was observed. **The honest proxy is GPU and CPU cost
per frame against the 8.33 ms budget**, which is what §3 measures and what the 2b
runbooks will record. Verifying the target itself needs ProMotion hardware and is
deferred to whoever has some.

## 5. What the capture says about the design, and what it does not

`.context/core-probe-states.png` — idle, listening, thinking, speaking, left to right.
It establishes that §4 is renderable and roughly what it will feel like. It is **not** a
design sign-off, and three things in it are visibly wrong:

- **The conic gradient has a seam.** `atan2` wraps at ±π and the four-stop palette does
  not close smoothly across it, so a hard radial line crosses the sphere. Most obvious
  in the idle and speaking panels.
- **The specular is too large and too hot**, so the sphere reads as pearl rather than as
  §4's *iridescent volumetric*. The 34%/26% placement is right; the radius and intensity
  are not.
- **Rim occlusion is too weak** for the sphere to feel like a volume rather than a disc.

All three are shader craft and belong to 2b-ii. None of them is structural, and none
changes anything in this document.

---

## Consequences

1. `operator-todo.md` gains the Metal toolchain download as a step distinct from
   installing Xcode.
2. 2b-ii's build gains a `make shaders` step producing `default.metallib`, run before
   `app-build`. Not 2b-i's — 2b-i draws nothing.
3. No 2b acceptance document claims 120fps. They record frame cost against the budget
   and name the display that could not test it.
4. The Core's cost is settled at ~1.1 ms; the perf risk in 2b lives in SwiftUI and the
   grid, not in Metal.
