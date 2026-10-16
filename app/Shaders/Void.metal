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

// `setFragmentBytes` is a raw memory copy with no schema — nothing checks
// that this struct still matches `VoidUniforms` in
// `WakilKit/Visual/VoidUniforms.swift` field for field. `VoidUniformsTests`
// pins the Swift side; this pins the Metal side, so a struct edited on only
// one side fails the build here rather than silently reinterpreting bytes
// at runtime.
//
// Size alone is insufficient: the struct has 8 bytes of tail padding, so
// `sizeof` stays 112 when one or two trailing floats are inserted, and stays
// 112 under any field reordering — the latter is the worse failure, silently
// corrupting every field past the swap. Field offsets are pinned in addition
// to size to catch both reordering and adjacent insertions that sizeof misses.
// `__builtin_offsetof` is a Clang builtin (plain `offsetof` does not compile
// here — Metal has no `<cstddef>` — so the next edit won't "clean it up").
static_assert(sizeof(VoidUniforms) == 112,
              "VoidUniforms must match the Swift struct in "
              "WakilKit/Visual/VoidUniforms.swift — setFragmentBytes is a "
              "raw memory copy with no schema");
static_assert(__builtin_offsetof(VoidUniforms, time) == 56,
              "VoidUniforms.time offset diverged from WakilKit/Visual/VoidUniforms.swift — "
              "field order or adjacent fields changed; see VoidUniformsTests.theWireFormatsLayoutIsPinned");
static_assert(__builtin_offsetof(VoidUniforms, ambientScale) == 100,
              "VoidUniforms.ambientScale offset diverged from WakilKit/Visual/VoidUniforms.swift — "
              "field order or adjacent fields changed; see VoidUniformsTests.theWireFormatsLayoutIsPinned");

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
