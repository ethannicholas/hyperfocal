import Foundation
import Metal
import simd

/// Thin wrapper around a Metal device: kernels compiled once from source at
/// startup, pipeline cache, dispatch helpers. All image kernels operate on raw
/// Float32 buffers (no textures) so results match the CPU path bit-for-bit in
/// structure — resampling taps (Lanczos-3 by default), clamp-to-edge, and luma
/// weights are identical code.
public final class MetalEngine {

    public static let shared: MetalEngine? = MetalEngine()

    public let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        do {
            self.library = try device.makeLibrary(source: Self.kernelSource, options: nil)
        } catch {
            // A kernel source error must be loud, not a silent CPU fallback.
            FileHandle.standardError.write(Data("Metal kernel compile failed: \(error)\n".utf8))
            return nil
        }
        self.device = device
        self.queue = queue
    }

    func pipeline(_ name: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let p = pipelines[name] { return p }
        guard let fn = library.makeFunction(name: name) else {
            throw StackError.metal("missing kernel \(name)")
        }
        let p = try device.makeComputePipelineState(function: fn)
        pipelines[name] = p
        return p
    }

    func makeBuffer(floats count: Int) throws -> MTLBuffer {
        guard let b = device.makeBuffer(length: count * 4, options: .storageModeShared) else {
            throw StackError.metal("cannot allocate \(count * 4) byte buffer")
        }
        return b
    }

    func dispatch2D(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                    width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    func dispatch1D(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                    count: Int) {
        encoder.setComputePipelineState(pipeline)
        let w = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    }

    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct WarpParams {
        float4 r0; float4 r1; float4 r2;   // rows of output→source homography
        uint4 dims;                        // srcW, srcH, dstW, dstH
    };

    kernel void warp_bilinear(device const float4* src [[buffer(0)]],
                              device float4* dst [[buffer(1)]],
                              constant WarpParams& p [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint dw = p.dims.z, dh = p.dims.w;
        if (gid.x >= dw || gid.y >= dh) return;
        int sw = int(p.dims.x), sh = int(p.dims.y);
        float3 v = float3(float(gid.x), float(gid.y), 1.0);
        float z = dot(p.r2.xyz, v);
        float sx = dot(p.r0.xyz, v) / z;
        float sy = dot(p.r1.xyz, v) / z;
        int x0 = int(floor(sx)), y0 = int(floor(sy));
        float wx = sx - float(x0), wy = sy - float(y0);
        int cx0 = clamp(x0, 0, sw - 1), cx1 = clamp(x0 + 1, 0, sw - 1);
        int cy0 = clamp(y0, 0, sh - 1), cy1 = clamp(y0 + 1, 0, sh - 1);
        float4 top = mix(src[cy0 * sw + cx0], src[cy0 * sw + cx1], wx);
        float4 bot = mix(src[cy1 * sw + cx0], src[cy1 * sw + cx1], wx);
        float4 sample = mix(top, bot, wy);
        // Outside the source: colors stay edge-clamped (no artificial dark edge
        // in gradients) but alpha 0 marks "this frame has no data here".
        bool inside = sx >= -0.5f && sx <= float(sw) - 0.5f
                   && sy >= -0.5f && sy <= float(sh) - 0.5f;
        sample.w = inside ? sample.w : 0.0f;
        dst[gid.y * dw + gid.x] = sample;
    }

    // Lanczos-3 kernel via the product form 3·sin(πx)·sin(πx/3)/(πx)² —
    // identical formula to Warp.lanczos3 on the CPU.
    inline float lanczos3(float x) {
        float ax = fabs(x);
        if (ax < 1e-5f) return 1.0f;
        if (ax >= 3.0f) return 0.0f;
        float px = M_PI_F * ax;
        return 3.0f * sin(px) * sin(px / 3.0f) / (px * px);
    }

    // 6×6 windowed-sinc warp — the default resampler. Taps edge-clamped like
    // the bilinear kernel; an anti-ringing clamp to the bilinear footprint's
    // range stops the negative lobes from glowing at hard edges and at the
    // coverage boundary. Must stay tap-for-tap identical to Warp.applyLanczos3.
    kernel void warp_lanczos3(device const float4* src [[buffer(0)]],
                              device float4* dst [[buffer(1)]],
                              constant WarpParams& p [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint dw = p.dims.z, dh = p.dims.w;
        if (gid.x >= dw || gid.y >= dh) return;
        int sw = int(p.dims.x), sh = int(p.dims.y);
        float3 v = float3(float(gid.x), float(gid.y), 1.0);
        float z = dot(p.r2.xyz, v);
        float sx = dot(p.r0.xyz, v) / z;
        float sy = dot(p.r1.xyz, v) / z;
        int x0 = int(floor(sx)), y0 = int(floor(sy));
        float fx = sx - float(x0), fy = sy - float(y0);
        float wx[6], wy[6];
        float sumX = 0.0f, sumY = 0.0f;
        for (int k = 0; k < 6; k++) {
            wx[k] = lanczos3(fx - float(k - 2)); sumX += wx[k];
            wy[k] = lanczos3(fy - float(k - 2)); sumY += wy[k];
        }
        float4 acc = float4(0.0);
        for (int ky = 0; ky < 6; ky++) {
            int ty = clamp(y0 - 2 + ky, 0, sh - 1);
            float4 row = float4(0.0);
            for (int kx = 0; kx < 6; kx++) {
                int tx = clamp(x0 - 2 + kx, 0, sw - 1);
                row += src[ty * sw + tx] * wx[kx];
            }
            acc += row * wy[ky];
        }
        float4 sample = acc / (sumX * sumY);
        int cx0 = clamp(x0, 0, sw - 1), cx1 = clamp(x0 + 1, 0, sw - 1);
        int cy0 = clamp(y0, 0, sh - 1), cy1 = clamp(y0 + 1, 0, sh - 1);
        float4 a = src[cy0 * sw + cx0], b = src[cy0 * sw + cx1];
        float4 c = src[cy1 * sw + cx0], d = src[cy1 * sw + cx1];
        sample = clamp(sample, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
        bool inside = sx >= -0.5f && sx <= float(sw) - 0.5f
                   && sy >= -0.5f && sy <= float(sh) - 0.5f;
        sample.w = inside ? sample.w : 0.0f;
        dst[gid.y * dw + gid.x] = sample;
    }

    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

    kernel void lum_laplacian(device const float4* img [[buffer(0)]],
                              device float* out [[buffer(1)]],
                              constant uint2& dims [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
        int w = int(dims.x), h = int(dims.y);
        if (gid.x >= dims.x || gid.y >= dims.y) return;
        int x = int(gid.x), y = int(gid.y);
        int xl = max(x - 1, 0), xr = min(x + 1, w - 1);
        int yu = max(y - 1, 0), yd = min(y + 1, h - 1);
        float c = dot(img[y * w + x].rgb, kLuma);
        float l = dot(img[y * w + xl].rgb, kLuma);
        float r = dot(img[y * w + xr].rgb, kLuma);
        float u = dot(img[yu * w + x].rgb, kLuma);
        float d = dot(img[yd * w + x].rgb, kLuma);
        out[y * w + x] = fabs(l + r + u + d - 4.0 * c);
    }

    struct BlurParams { uint width; uint height; int radius; };

    kernel void blur_h(device const float* src [[buffer(0)]],
                       device float* dst [[buffer(1)]],
                       device const float* weights [[buffer(2)]],
                       constant BlurParams& p [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        int w = int(p.width);
        int row = int(gid.y) * w;
        float acc = 0.0;
        for (int i = -p.radius; i <= p.radius; i++) {
            int xi = clamp(int(gid.x) + i, 0, w - 1);
            acc += src[row + xi] * weights[i + p.radius];
        }
        dst[row + int(gid.x)] = acc;
    }

    kernel void blur_v(device const float* src [[buffer(0)]],
                       device float* dst [[buffer(1)]],
                       device const float* weights [[buffer(2)]],
                       constant BlurParams& p [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        int w = int(p.width), h = int(p.height);
        float acc = 0.0;
        for (int i = -p.radius; i <= p.radius; i++) {
            int yi = clamp(int(gid.y) + i, 0, h - 1);
            acc += src[yi * w + int(gid.x)] * weights[i + p.radius];
        }
        dst[int(gid.y) * w + int(gid.x)] = acc;
    }

    kernel void argmax_update(device const float* energy [[buffer(0)]],
                              device const float4* frame [[buffer(1)]],
                              device float* bestE [[buffer(2)]],
                              device float* bestIdx [[buffer(3)]],
                              constant float& frameIdx [[buffer(4)]],
                              constant uint& count [[buffer(5)]],
                              constant float& gain [[buffer(6)]],
                              device float* guide [[buffer(7)]],
                              uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        // Alpha-masked: a frame gets no depth vote where it has no data.
        // Gain: exposure-normalized energy (Laplacian is linear in gain).
        float e = energy[gid] * frame[gid].w * gain;
        bool wins = e > bestE[gid];
        if (wins) {
            bestE[gid] = e;
            bestIdx[gid] = frameIdx;
        }
        // Guide for the guided regularizer: gain-corrected luminance of the
        // winning frame — an all-in-focus luminance estimate whose edges stay
        // crisp at fine silhouette detail (a stack mean would defocus-blur
        // them away). Frame 0 seeds pixels no frame ever wins.
        if (wins || frameIdx == 0.0f) {
            guide[gid] = dot(frame[gid].rgb, kLuma) * gain;
        }
    }

    struct TentParams { float index; float radius; uint count; float gain; };

    kernel void tent_accumulate(device const float4* frame [[buffer(0)]],
                                device const float* depth [[buffer(1)]],
                                device float4* accum [[buffer(2)]],
                                device float* wsum [[buffer(3)]],
                                constant TentParams& p [[buffer(4)]],
                                uint gid [[thread_position_in_grid]]) {
        if (gid >= p.count) return;
        float4 s = frame[gid];
        if (s.w <= 0.0f) return;  // no data from this frame here
        float tent = max(1.0 - fabs(p.index - depth[gid]) / p.radius, 0.0);
        // Tiny floor: pixels whose selected frames lack coverage still average
        // the frames that do cover them, instead of dividing by zero.
        float w = (tent + 1e-6f) * s.w;
        // Exposure gain corrects color only; coverage (alpha) is exposure-free.
        accum[gid] += float4(s.xyz * (w * p.gain), s.w * w);
        wsum[gid] += w;
    }

    struct PlanePreviewParams { uint srcW; uint srcH; uint dstW; uint dstH; float scale; float bias; };

    kernel void plane_preview(device const float* plane [[buffer(0)]],
                              device float4* out [[buffer(1)]],
                              constant PlanePreviewParams& p [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.dstW || gid.y >= p.dstH) return;
        uint sx = min(gid.x * p.srcW / p.dstW, p.srcW - 1);
        uint sy = min(gid.y * p.srcH / p.dstH, p.srcH - 1);
        float v = p.bias + plane[sy * p.srcW + sx] * p.scale;
        out[gid.y * p.dstW + gid.x] = float4(v, v, v, 1.0);
    }

    struct BoxDownParams { uint srcW; uint srcH; uint dstW; uint dstH; uint factor; };

    kernel void box_downsample(device const float* src [[buffer(0)]],
                               device float* dst [[buffer(1)]],
                               constant BoxDownParams& p [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.dstW || gid.y >= p.dstH) return;
        uint x0 = gid.x * p.factor, y0 = gid.y * p.factor;
        uint x1 = min(x0 + p.factor, p.srcW);
        uint y1 = min(y0 + p.factor, p.srcH);
        float acc = 0.0;
        for (uint y = y0; y < y1; y++) {
            for (uint x = x0; x < x1; x++) {
                acc += src[y * p.srcW + x];
            }
        }
        dst[gid.y * p.dstW + gid.x] = acc / float((x1 - x0) * (y1 - y0));
    }

    struct PreviewParams { uint srcW; uint srcH; uint dstW; uint dstH; };

    // Preview threshold 0.01: above anything the tent floor alone can
    // accumulate, so untouched pixels stay black until a genuinely selected
    // frame lands (matches DMapFusion.progressivePreview).
    kernel void progressive_preview(device const float4* accum [[buffer(0)]],
                                    device const float* wsum [[buffer(1)]],
                                    device float4* out [[buffer(2)]],
                                    constant PreviewParams& p [[buffer(3)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.dstW || gid.y >= p.dstH) return;
        uint sx = min(gid.x * p.srcW / p.dstW, p.srcW - 1);
        uint sy = min(gid.y * p.srcH / p.dstH, p.srcH - 1);
        uint si = sy * p.srcW + sx;
        float w = wsum[si];
        float4 v = w > 0.01f ? accum[si] / w : float4(0.0);
        v.w = 1.0;
        out[gid.y * p.dstW + gid.x] = v;
    }

    kernel void normalize_out(device const float4* accum [[buffer(0)]],
                              device const float* wsum [[buffer(1)]],
                              device float4* out [[buffer(2)]],
                              constant uint& count [[buffer(3)]],
                              uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float w = wsum[gid];
        float4 v = w > 1e-7f ? accum[gid] / w : float4(0.0);
        v.w = 1.0;  // pixels no frame covers come out opaque black
        out[gid] = v;
    }

    // ---- Depth-map regularization ----

    struct ConfidenceParams { uint width; uint concW; uint concH; uint factor; float floor2; float conc2; };

    // Confidence = noise-floor factor × peak-concentration factor; both land
    // on 0.5 exactly at their thresholds. The concentration plane arrives at
    // the sharpness-downsample grid (bokeh sweeps are hundreds of pixels wide
    // — grid resolution is plenty) and is sampled bilinearly: nearest lookup
    // imprinted hard grid squares into the confidence-blended depth. Must
    // match DMapFusion.regularizeDepth.
    kernel void confidence_map(device const float* energy [[buffer(0)]],
                               device float* conf [[buffer(1)]],
                               constant ConfidenceParams& p [[buffer(2)]],
                               constant uint& count [[buffer(3)]],
                               device const float* concentration [[buffer(4)]],
                               uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float e2 = energy[gid] * energy[gid];
        float c = e2 / (e2 + p.floor2);
        if (p.conc2 > 0.0f) {
            float invF = 1.0f / float(p.factor);
            uint x = gid % p.width, y = gid / p.width;
            float gx = clamp((float(x) + 0.5f) * invF - 0.5f, 0.0f, float(p.concW - 1));
            float gy = clamp((float(y) + 0.5f) * invF - 0.5f, 0.0f, float(p.concH - 1));
            int x0 = min(int(gx), int(p.concW) - 1);
            int x1 = min(x0 + 1, int(p.concW) - 1);
            int y0 = min(int(gy), int(p.concH) - 1);
            int y1 = min(y0 + 1, int(p.concH) - 1);
            float fx = gx - float(x0), fy = gy - float(y0);
            int w = int(p.concW);
            float k = (concentration[y0 * w + x0] * (1.0f - fx)
                       + concentration[y0 * w + x1] * fx) * (1.0f - fy)
                    + (concentration[y1 * w + x0] * (1.0f - fx)
                       + concentration[y1 * w + x1] * fx) * fy;
            float k2 = k * k;
            c *= k2 / (k2 + p.conc2);
        }
        conf[gid] = c;
    }

    struct MedianParams { uint width; uint height; int radius; int step; uint bins; int consensusWindow; };

    // Weighted median over a subsampled window, found by binary search on the
    // cumulative weight below a candidate bin: identical result to the CPU's
    // per-pixel histogram, but needs no per-thread array (frame counts are
    // unbounded and a histogram would spill out of registers).
    kernel void weighted_median(device const float* values [[buffer(0)]],
                                device const float* weights [[buffer(1)]],
                                device float* out [[buffer(2)]],
                                constant MedianParams& p [[buffer(3)]],
                                device float* consensus [[buffer(4)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        int w = int(p.width), h = int(p.height);
        int x = int(gid.x), y = int(gid.y);
        float total = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy += p.step) {
            int yy = clamp(y + dy, 0, h - 1);
            for (int dx = -p.radius; dx <= p.radius; dx += p.step) {
                int xx = clamp(x + dx, 0, w - 1);
                float wt = weights[yy * w + xx];
                if (wt > 1e-3f) total += wt;
            }
        }
        int i = y * w + x;
        if (total <= 1e-3f) { out[i] = values[i]; consensus[i] = 0.0f; return; }
        float halfTotal = total * 0.5f;
        uint lo = 0, hi = p.bins - 1;
        while (lo < hi) {
            uint mid = (lo + hi) / 2;
            float acc = 0.0;
            for (int dy = -p.radius; dy <= p.radius; dy += p.step) {
                int yy = clamp(y + dy, 0, h - 1);
                for (int dx = -p.radius; dx <= p.radius; dx += p.step) {
                    int xx = clamp(x + dx, 0, w - 1);
                    int j = yy * w + xx;
                    float wt = weights[j];
                    if (wt > 1e-3f) {
                        uint b = uint(clamp(int(values[j] + 0.5f), 0, int(p.bins) - 1));
                        if (b <= mid) acc += wt;
                    }
                }
            }
            if (acc >= halfTotal) hi = mid; else lo = mid + 1;
        }
        // Sub-bin interpolation (matches the CPU histogram): distribute the
        // winning bin's weight uniformly across its width, or whole-frame
        // plateaus posterize into contour lines wherever the blend trusts
        // the median. One extra window scan gathers the weight below and at
        // the winning bin.
        float below = 0.0, at = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy += p.step) {
            int yy = clamp(y + dy, 0, h - 1);
            for (int dx = -p.radius; dx <= p.radius; dx += p.step) {
                int xx = clamp(x + dx, 0, w - 1);
                int j = yy * w + xx;
                float wt = weights[j];
                if (wt > 1e-3f) {
                    uint b = uint(clamp(int(values[j] + 0.5f), 0, int(p.bins) - 1));
                    if (b < lo) below += wt;
                    else if (b == lo) at += wt;
                }
            }
        }
        float frac = clamp((halfTotal - below) / max(at, 1e-9f), 0.0f, 1.0f);
        out[i] = float(lo) - 0.5f + frac;
        // Consensus: fraction of the window's vote weight within
        // +-consensusWindow frames of the chosen median — dense-voting
        // evidence for the blend. Must match the CPU histogram result.
        int bLo = max(int(lo) - p.consensusWindow, 0);
        int bHi = min(int(lo) + p.consensusWindow, int(p.bins) - 1);
        float agree = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy += p.step) {
            int yy = clamp(y + dy, 0, h - 1);
            for (int dx = -p.radius; dx <= p.radius; dx += p.step) {
                int xx = clamp(x + dx, 0, w - 1);
                int j = yy * w + xx;
                float wt = weights[j];
                if (wt > 1e-3f) {
                    int b = clamp(int(values[j] + 0.5f), 0, int(p.bins) - 1);
                    if (b >= bLo && b <= bHi) agree += wt;
                }
            }
        }
        consensus[i] = agree / total;
    }

    struct GuidedApplyParams {
        uint width; uint height; uint gridW; uint gridH;
        float invFactor; float guideScale; float maxIndex; float residualW2;
    };

    // Guided-regularizer apply + preservation blend: bilinearly sample the
    // grid-resolution WGIF coefficients (center-aligned mapping), evaluate
    // the local linear model on the normalized full-res guide, blend with
    // the median depth by confidence — residual-aware: a confident pixel
    // whose median depth sits far from the fit is a luminance outlier the
    // regression extrapolated through (speculars); trust the measurement
    // there. Mirrors DepthRegularize.applyBlend operation for operation.
    kernel void guided_apply_blend(device const float* aBar [[buffer(0)]],
                                   device const float* bBar [[buffer(1)]],
                                   device const float* guide [[buffer(2)]],
                                   device const float* conf [[buffer(3)]],
                                   device const float* depthMed [[buffer(4)]],
                                   device float* out [[buffer(5)]],
                                   constant GuidedApplyParams& p [[buffer(6)]],
                                   device const float* consensus [[buffer(7)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        int gw = int(p.gridW), gh = int(p.gridH);
        float gy = clamp((float(gid.y) + 0.5f) * p.invFactor - 0.5f, 0.0f, float(gh - 1));
        int y0 = min(int(gy), gh - 1);
        int y1 = min(y0 + 1, gh - 1);
        float fy = gy - float(y0);
        float gx = clamp((float(gid.x) + 0.5f) * p.invFactor - 0.5f, 0.0f, float(gw - 1));
        int x0 = min(int(gx), gw - 1);
        int x1 = min(x0 + 1, gw - 1);
        float fx = gx - float(x0);
        int i00 = y0 * gw + x0, i01 = y0 * gw + x1;
        int i10 = y1 * gw + x0, i11 = y1 * gw + x1;
        float aS = (aBar[i00] * (1.0f - fx) + aBar[i01] * fx) * (1.0f - fy)
                 + (aBar[i10] * (1.0f - fx) + aBar[i11] * fx) * fy;
        float bS = (bBar[i00] * (1.0f - fx) + bBar[i01] * fx) * (1.0f - fy)
                 + (bBar[i10] * (1.0f - fx) + bBar[i11] * fx) * fy;
        uint i = gid.y * p.width + gid.x;
        float dReg = aS * (p.guideScale * guide[i]) + bS;
        float agreement = consensus[i];
        float cf = max(conf[i], agreement * agreement);
        float r = dReg - depthMed[i];
        float t = r * r / (r * r + p.residualW2);
        float s = clamp((cf - 0.35f) / 0.35f, 0.0f, 1.0f);
        float gate = s * s * (3.0f - 2.0f * s);
        float cb = cf + (1.0f - cf) * (t * gate);
        out[i] = clamp(cb * depthMed[i] + (1.0f - cb) * dReg, 0.0f, p.maxIndex);
    }

    kernel void clamp_plane(device float* plane [[buffer(0)]],
                            constant float& maxV [[buffer(1)]],
                            constant uint& count [[buffer(2)]],
                            uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        plane[gid] = clamp(plane[gid], 0.0f, maxV);
    }

    // ---- Laplacian pyramid fusion (PMax) ----
    // Mirrors PyramidFusion's CPU ops: 5-tap [1,4,6,4,1]/16 separable blur
    // (clamp-to-edge), decimation at even coordinates, and bilinear upsampling
    // with Filters.resizeBilinear's center-aligned mapping.

    constant float kPyr5[5] = {1.0/16, 4.0/16, 6.0/16, 4.0/16, 1.0/16};

    kernel void pyr_blur5_h(device const float4* src [[buffer(0)]],
                            device float4* dst [[buffer(1)]],
                            constant uint2& dims [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dims.x || gid.y >= dims.y) return;
        int w = int(dims.x);
        int row = int(gid.y) * w;
        float4 acc = float4(0.0);
        for (int i = -2; i <= 2; i++) {
            int xi = clamp(int(gid.x) + i, 0, w - 1);
            acc += src[row + xi] * kPyr5[i + 2];
        }
        dst[row + int(gid.x)] = acc;
    }

    kernel void pyr_blur5_v(device const float4* src [[buffer(0)]],
                            device float4* dst [[buffer(1)]],
                            constant uint2& dims [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dims.x || gid.y >= dims.y) return;
        int w = int(dims.x), h = int(dims.y);
        float4 acc = float4(0.0);
        for (int i = -2; i <= 2; i++) {
            int yi = clamp(int(gid.y) + i, 0, h - 1);
            acc += src[yi * w + int(gid.x)] * kPyr5[i + 2];
        }
        dst[int(gid.y) * w + int(gid.x)] = acc;
    }

    struct PyrResizeParams { uint srcW; uint srcH; uint dstW; uint dstH; };

    kernel void pyr_decimate(device const float4* src [[buffer(0)]],
                             device float4* dst [[buffer(1)]],
                             constant PyrResizeParams& p [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.dstW || gid.y >= p.dstH) return;
        uint sx = min(gid.x * 2, p.srcW - 1);
        uint sy = min(gid.y * 2, p.srcH - 1);
        dst[gid.y * p.dstW + gid.x] = src[sy * p.srcW + sx];
    }

    inline float4 pyr_bilinear(device const float4* src, int sw, int sh,
                               uint2 gid, uint dstW, uint dstH) {
        float fx = (float(gid.x) + 0.5f) * float(sw) / float(dstW) - 0.5f;
        float fy = (float(gid.y) + 0.5f) * float(sh) / float(dstH) - 0.5f;
        int x0 = int(floor(fx)), y0 = int(floor(fy));
        float wx = fx - float(x0), wy = fy - float(y0);
        int cx0 = clamp(x0, 0, sw - 1), cx1 = clamp(x0 + 1, 0, sw - 1);
        int cy0 = clamp(y0, 0, sh - 1), cy1 = clamp(y0 + 1, 0, sh - 1);
        float4 top = mix(src[cy0 * sw + cx0], src[cy0 * sw + cx1], wx);
        float4 bot = mix(src[cy1 * sw + cx0], src[cy1 * sw + cx1], wx);
        return mix(top, bot, wy);
    }

    kernel void pyr_upsample(device const float4* src [[buffer(0)]],
                             device float4* dst [[buffer(1)]],
                             constant PyrResizeParams& p [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.dstW || gid.y >= p.dstH) return;
        dst[gid.y * p.dstW + gid.x] =
            pyr_bilinear(src, int(p.srcW), int(p.srcH), gid, p.dstW, p.dstH);
    }

    // Collapse step: dst = band + upsample(coarser). Same mapping as above.
    kernel void pyr_upsample_add(device const float4* src [[buffer(0)]],
                                 device const float4* band [[buffer(1)]],
                                 device float4* dst [[buffer(2)]],
                                 constant PyrResizeParams& p [[buffer(3)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.dstW || gid.y >= p.dstH) return;
        uint i = gid.y * p.dstW + gid.x;
        dst[i] = band[i] + pyr_bilinear(src, int(p.srcW), int(p.srcH), gid, p.dstW, p.dstH);
    }

    // Max-energy coefficient select: band = fine − upsampled coarser; keep it
    // wherever its |RGB| energy beats the best so far. bestE starts at −1 so
    // the first frame installs everywhere.
    kernel void pyr_select(device const float4* fine [[buffer(0)]],
                           device const float4* up [[buffer(1)]],
                           device float4* fused [[buffer(2)]],
                           device float* bestE [[buffer(3)]],
                           constant uint& count [[buffer(4)]],
                           uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float4 band = fine[gid] - up[gid];
        float e = fabs(band.x) + fabs(band.y) + fabs(band.z);
        if (e > bestE[gid]) {
            bestE[gid] = e;
            fused[gid] = band;
        }
    }

    // Finest-level selection energy for grit suppression: written to a plane
    // so it can be blurred before selection (PyramidFusion.selectionEnergy).
    kernel void pyr_band_energy(device const float4* fine [[buffer(0)]],
                                device const float4* up [[buffer(1)]],
                                device float* e [[buffer(2)]],
                                constant uint& count [[buffer(3)]],
                                uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float4 band = fine[gid] - up[gid];
        e[gid] = fabs(band.x) + fabs(band.y) + fabs(band.z);
    }

    // pyr_select with the energy read from a pre-smoothed plane instead of
    // computed inline — the band itself is recomputed (never smoothed).
    kernel void pyr_select_smoothed(device const float4* fine [[buffer(0)]],
                                    device const float4* up [[buffer(1)]],
                                    device float4* fused [[buffer(2)]],
                                    device float* bestE [[buffer(3)]],
                                    device const float* energy [[buffer(4)]],
                                    constant uint& count [[buffer(5)]],
                                    uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float e = energy[gid];
        if (e > bestE[gid]) {
            bestE[gid] = e;
            fused[gid] = fine[gid] - up[gid];
        }
    }

    kernel void pyr_add4(device float4* dst [[buffer(0)]],
                         device const float4* src [[buffer(1)]],
                         constant uint& count [[buffer(2)]],
                         uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        dst[gid] += src[gid];
    }

    kernel void pyr_scale4(device float4* dst [[buffer(0)]],
                           constant float& s [[buffer(1)]],
                           constant uint& count [[buffer(2)]],
                           uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        dst[gid] *= s;
    }

    kernel void pyr_fill(device float* dst [[buffer(0)]],
                         constant float& v [[buffer(1)]],
                         constant uint& count [[buffer(2)]],
                         uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        dst[gid] = v;
    }
    """
}

public enum StackError: Error, CustomStringConvertible {
    case metal(String)

    public var description: String {
        switch self {
        case .metal(let s): return "metal: \(s)"
        }
    }
}
