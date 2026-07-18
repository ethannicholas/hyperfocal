#version 440
// Tone LUT on the pane layer — the Qt counterpart of the native
// ToneFilteredPaneView's color cube. The curve is per-channel-separable
// (see ToneCurve.colorCubeData), so one shared 1-D ramp sampled per
// channel IS the whole cube. lutEnabled = 0 passes data visualizations
// (depth, aligner gradients) through untouched.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float lutEnabled;
};
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D lut;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    if (lutEnabled > 0.5 && c.a > 0.0) {
        vec3 u = c.rgb / c.a;  // layer textures are premultiplied
        u = vec3(texture(lut, vec2(u.r, 0.5)).r,
                 texture(lut, vec2(u.g, 0.5)).r,
                 texture(lut, vec2(u.b, 0.5)).r);
        c = vec4(u * c.a, c.a);
    }
    fragColor = c * qt_Opacity;
}
