#include <metal_stdlib>
using namespace metal;

// Preview half of the tone pipeline: samples the same curve LUT the export
// path interpolates (ToneCurve.lut), as a colorEffect on the preview panes.
// SwiftUI hands colorEffect premultiplied colors in a *linear* working space;
// the curve is defined on display-referred (gamma-encoded) values, so encode,
// look up, and linearize back. `linearDomain` exists as an escape hatch
// should a future SwiftUI change the working space (pass 0 = already
// encoded); AppModel pins it to 1 today.

static inline half srgb_encode(half l) {
    return l <= 0.0031308h ? l * 12.92h : 1.055h * pow(l, 1.0h / 2.4h) - 0.055h;
}

static inline half srgb_linearize(half v) {
    return v <= 0.04045h ? v / 12.92h : pow((v + 0.055h) / 1.055h, 2.4h);
}

[[ stitchable ]] half4 toneCurve(float2 position, half4 color,
                                 texture2d<half> lut, float linearDomain) {
    half a = color.a;
    if (a <= 0.0h) { return color; }
    half3 c = clamp(color.rgb / a, 0.0h, 1.0h);
    if (linearDomain > 0.5) {
        c = half3(srgb_encode(c.r), srgb_encode(c.g), srgb_encode(c.b));
    }
    // Sample texel centers: v=0 → center of texel 0, v=1 → center of the last.
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float n = lut.get_width();
    float3 u = (float3(c) * (n - 1) + 0.5) / n;
    half3 t = half3(lut.sample(s, float2(u.r, 0.5)).r,
                    lut.sample(s, float2(u.g, 0.5)).r,
                    lut.sample(s, float2(u.b, 0.5)).r);
    if (linearDomain > 0.5) {
        t = half3(srgb_linearize(t.r), srgb_linearize(t.g), srgb_linearize(t.b));
    }
    return half4(t * a, a);
}
