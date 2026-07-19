#if HYPERFOCAL_HAVE_WGPU
import Foundation

/// Kernel-level CPU↔wgpu parity checks — the wgpu backend's equivalent of the
/// Metal path's parity discipline (ROADMAP header: ≥ 90 dB). One case per
/// kernel: the warps run against the production CPU `Warp.apply`; the rest
/// against inline references that mirror the MSL/WGSL semantics operation for
/// operation. All inputs are deterministic (xorshift).
public enum WgpuParity {

    private final class Ctx {
        let engine: WgpuEngine
        var minPSNR = Double.infinity
        let log: (String) -> Void
        var rng: UInt64 = 0x9E3779B97F4A7C15

        init(engine: WgpuEngine, log: @escaping (String) -> Void) {
            self.engine = engine
            self.log = log
        }

        func rand(_ count: Int, scale: Float = 1) -> [Float] {
            (0..<count).map { _ in
                rng ^= rng << 13
                rng ^= rng >> 7
                rng ^= rng << 17
                return Float(rng % 1_000_000) / 1_000_000 * scale
            }
        }

        func buf(_ data: [Float]) throws -> WgpuEngine.Buffer {
            let b = try engine.makeBuffer(floats: data.count)
            data.withUnsafeBytes { engine.upload($0.baseAddress!, byteCount: $0.count, to: b) }
            return b
        }

        func read(_ b: WgpuEngine.Buffer, _ count: Int) throws -> [Float] {
            var out = [Float](repeating: 0, count: count)
            try out.withUnsafeMutableBytes { try engine.download(b, into: $0.baseAddress!) }
            return out
        }

        func report(_ name: String, _ cpu: [Float], _ gpu: [Float]) {
            precondition(cpu.count == gpu.count)
            var mse = 0.0
            for i in 0..<cpu.count {
                let d = Double(cpu[i] - gpu[i])
                mse += d * d
            }
            mse /= Double(cpu.count)
            let psnr = mse == 0 ? Double.infinity : 10 * log10(1.0 / mse)
            log(String(format: "%@: %@", name,
                       psnr.isInfinite ? "inf dB" : String(format: "%.1f dB", psnr)))
            minPSNR = min(minPSNR, psnr)
        }
    }

    private static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    struct WarpParams {
        var r0: SIMD4<Float>
        var r1: SIMD4<Float>
        var r2: SIMD4<Float>
        var dims: SIMD4<UInt32>
    }
    struct BlurParams { var width: UInt32; var height: UInt32; var radius: Int32; var pad: UInt32 = 0 }
    struct Dims2 { var w: UInt32; var h: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct Count1 { var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }
    struct ArgmaxParams { var frameIdx: Float; var count: UInt32; var gain: Float; var pad: UInt32 = 0 }
    struct TentParams { var gain: SIMD4<Float>; var index: Float; var radius: Float; var count: UInt32; var pad: UInt32 = 0 }
    struct PlanePreviewParams { var srcW: UInt32; var srcH: UInt32; var dstW: UInt32; var dstH: UInt32; var scale: Float; var bias: Float; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct BoxDownParams { var srcW: UInt32; var srcH: UInt32; var dstW: UInt32; var dstH: UInt32; var factor: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }
    struct PreviewParams { var srcW: UInt32; var srcH: UInt32; var dstW: UInt32; var dstH: UInt32 }
    struct ConfidenceParams { var width: UInt32; var concW: UInt32; var concH: UInt32; var factor: UInt32; var halfFloor: Float; var conc2: Float; var count: UInt32; var pad: UInt32 = 0 }
    struct MedianParams { var width: UInt32; var height: UInt32; var radius: Int32; var step: Int32; var bins: UInt32; var consensusWindow: Int32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct GuidedApplyParams { var width: UInt32; var height: UInt32; var gridW: UInt32; var gridH: UInt32; var invFactor: Float; var guideScale: Float; var maxIndex: Float; var residualW2: Float; var hasSpill: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }
    struct ClampParams { var maxV: Float; var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct ScaleParams { var s: Float; var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct FillParams { var v: Float; var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }

    static func luma(_ p: [Float], _ i: Int) -> Float {
        0.2126 * p[i * 4] + 0.7152 * p[i * 4 + 1] + 0.0722 * p[i * 4 + 2]
    }

    /// Runs every check, printing one line each. Returns the minimum PSNR
    /// (infinity when bit-identical), or throws if the engine is unavailable.
    public static func run(log: @escaping (String) -> Void = { print($0) }) throws -> Double {
        guard let engine = WgpuEngine.shared else {
            throw StackError.metal("no wgpu adapter available")
        }
        log("wgpu adapter: \(engine.adapterSummary)")
        let c = Ctx(engine: engine, log: log)

        // -- warps vs Warp.apply (the production CPU reference) --------------
        let sw = 257, sh = 181, dw = 241, dh = 173
        let src = ImageBuffer(width: sw, height: sh, pixels: c.rand(sw * sh * 4))
        let a: Float = 0.03, s: Float = 1.02
        let H = simd_float3x3(rows: [
            SIMD3<Float>(s * cos(a), -s * sin(a), 3.7),
            SIMD3<Float>(s * sin(a), s * cos(a), -2.2),
            SIMD3<Float>(0, 0, 1),
        ])
        let wp = WarpParams(
            r0: SIMD4<Float>(H[0][0], H[1][0], H[2][0], 0),
            r1: SIMD4<Float>(H[0][1], H[1][1], H[2][1], 0),
            r2: SIMD4<Float>(H[0][2], H[1][2], H[2][2], 0),
            dims: SIMD4<UInt32>(UInt32(sw), UInt32(sh), UInt32(dw), UInt32(dh)))
        for (kernel, method) in [("warp_lanczos3", Warp.Method.lanczos3),
                                 ("warp_bilinear", Warp.Method.bilinear)] {
            let srcBuf = try c.buf(src.pixels)
            let dstBuf = try engine.makeBuffer(floats: dw * dh * 4)
            try engine.run(kernel, buffers: [srcBuf, dstBuf],
                           uniforms: bytes(of: wp), gridW: dw, gridH: dh)
            let cpu = Warp.apply(src, outputToSource: H, outWidth: dw, outHeight: dh,
                                 method: method)
            c.report(kernel, cpu.pixels, try c.read(dstBuf, dw * dh * 4))
        }

        // -- blur_h + blur_v --------------------------------------------------
        let bw = 317, bh = 211
        do {
            let plane = c.rand(bw * bh)
            let weights = Filters.gaussianKernel(sigma: 6)
            let radius = weights.count / 2
            var cpu = [Float](repeating: 0, count: bw * bh)
            var tmp = cpu
            for y in 0..<bh { for x in 0..<bw {
                var acc: Float = 0
                for i in -radius...radius {
                    acc += plane[y * bw + min(max(x + i, 0), bw - 1)] * weights[i + radius]
                }
                tmp[y * bw + x] = acc
            } }
            for y in 0..<bh { for x in 0..<bw {
                var acc: Float = 0
                for i in -radius...radius {
                    acc += tmp[min(max(y + i, 0), bh - 1) * bw + x] * weights[i + radius]
                }
                cpu[y * bw + x] = acc
            } }
            let p = try c.buf(plane), t = try engine.makeBuffer(floats: bw * bh)
            let w = try c.buf(weights)
            let bp = BlurParams(width: UInt32(bw), height: UInt32(bh), radius: Int32(radius))
            try engine.run("blur_h", buffers: [p, t, w], uniforms: bytes(of: bp), gridW: bw, gridH: bh)
            try engine.run("blur_v", buffers: [t, p, w], uniforms: bytes(of: bp), gridW: bw, gridH: bh)
            c.report("blur_h+blur_v", cpu, try c.read(p, bw * bh))
        }

        // Small shared grids for the per-pixel kernels.
        let w = 64, h = 48, n = w * h

        // -- lum_laplacian ----------------------------------------------------
        do {
            let img = c.rand(n * 4)
            var cpu = [Float](repeating: 0, count: n)
            for y in 0..<h { for x in 0..<w {
                let xl = max(x - 1, 0), xr = min(x + 1, w - 1)
                let yu = max(y - 1, 0), yd = min(y + 1, h - 1)
                cpu[y * w + x] = abs(luma(img, y * w + xl) + luma(img, y * w + xr)
                    + luma(img, yu * w + x) + luma(img, yd * w + x)
                    - 4 * luma(img, y * w + x))
            } }
            let i = try c.buf(img), o = try engine.makeBuffer(floats: n)
            try engine.run("lum_laplacian", buffers: [i, o],
                           uniforms: bytes(of: Dims2(w: UInt32(w), h: UInt32(h))),
                           gridW: w, gridH: h)
            c.report("lum_laplacian", cpu, try c.read(o, n))
        }

        // -- argmax_update (two frames) --------------------------------------
        do {
            let e0 = c.rand(n), e1 = c.rand(n)
            let f0 = c.rand(n * 4), f1 = c.rand(n * 4)
            var bestE = [Float](repeating: 0, count: n)
            var bestIdx = bestE, guide = bestE
            for (fi, (e, f, g)) in [(e0, f0, Float(1.02)), (e1, f1, Float(0.97))].enumerated() {
                for i in 0..<n {
                    let ei = e[i] * f[i * 4 + 3] * g
                    let wins = ei > bestE[i]
                    if wins { bestE[i] = ei; bestIdx[i] = Float(fi) }
                    if wins || fi == 0 { guide[i] = luma(f, i) * g }
                }
            }
            let bE = try c.buf([Float](repeating: 0, count: n))
            let bI = try c.buf([Float](repeating: 0, count: n))
            let gd = try c.buf([Float](repeating: 0, count: n))
            for (fi, (e, f, g)) in [(e0, f0, Float(1.02)), (e1, f1, Float(0.97))].enumerated() {
                let p = ArgmaxParams(frameIdx: Float(fi), count: UInt32(n), gain: g)
                try engine.run("argmax_update",
                               buffers: [try c.buf(e), try c.buf(f), bE, bI, gd],
                               uniforms: bytes(of: p), gridW: n)
            }
            c.report("argmax_update", bestE + bestIdx + guide,
                     try c.read(bE, n) + c.read(bI, n) + c.read(gd, n))
        }

        // -- tent_accumulate --------------------------------------------------
        do {
            let f = c.rand(n * 4), depth = c.rand(n, scale: 5)
            let gain = SIMD4<Float>(1.1, 0.9, 1.05, 0)
            var accum = [Float](repeating: 0, count: n * 4)
            var wsum = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let sa = f[i * 4 + 3]
                if sa <= 0 { continue }
                let tent = max(1 - abs(2.3 - depth[i]) / 1.7, 0)
                let wt = (tent + 1e-6) * sa
                accum[i * 4] += f[i * 4] * (wt * gain.x)
                accum[i * 4 + 1] += f[i * 4 + 1] * (wt * gain.y)
                accum[i * 4 + 2] += f[i * 4 + 2] * (wt * gain.z)
                accum[i * 4 + 3] += sa * wt
                wsum[i] += wt
            }
            let aB = try c.buf([Float](repeating: 0, count: n * 4))
            let wB = try c.buf([Float](repeating: 0, count: n))
            let tp = TentParams(gain: gain, index: 2.3, radius: 1.7, count: UInt32(n))
            try engine.run("tent_accumulate",
                           buffers: [try c.buf(f), try c.buf(depth), aB, wB],
                           uniforms: bytes(of: tp), gridW: n)
            c.report("tent_accumulate", accum + wsum, try c.read(aB, n * 4) + c.read(wB, n))
        }

        // -- plane_preview / box_downsample / luma_plane ----------------------
        do {
            let plane = c.rand(n, scale: 5)
            let pw = 23, ph = 17
            var cpu = [Float](repeating: 0, count: pw * ph * 4)
            for y in 0..<ph { for x in 0..<pw {
                let sx = min(x * w / pw, w - 1), sy = min(y * h / ph, h - 1)
                let v = 0.1 + plane[sy * w + sx] * 0.2
                let o = (y * pw + x) * 4
                cpu[o] = v; cpu[o + 1] = v; cpu[o + 2] = v; cpu[o + 3] = 1
            } }
            let o = try engine.makeBuffer(floats: pw * ph * 4)
            let p = PlanePreviewParams(srcW: UInt32(w), srcH: UInt32(h),
                                       dstW: UInt32(pw), dstH: UInt32(ph),
                                       scale: 0.2, bias: 0.1)
            try engine.run("plane_preview", buffers: [try c.buf(plane), o],
                           uniforms: bytes(of: p), gridW: pw, gridH: ph)
            c.report("plane_preview", cpu, try c.read(o, pw * ph * 4))

            let f = 3, dw2 = (w + f - 1) / f, dh2 = (h + f - 1) / f
            var cpuBox = [Float](repeating: 0, count: dw2 * dh2)
            for y in 0..<dh2 { for x in 0..<dw2 {
                let x0 = x * f, y0 = y * f
                let x1 = min(x0 + f, w), y1 = min(y0 + f, h)
                var acc: Float = 0
                for yy in y0..<y1 { for xx in x0..<x1 { acc += plane[yy * w + xx] } }
                cpuBox[y * dw2 + x] = acc / Float((x1 - x0) * (y1 - y0))
            } }
            let ob = try engine.makeBuffer(floats: dw2 * dh2)
            let bp = BoxDownParams(srcW: UInt32(w), srcH: UInt32(h),
                                   dstW: UInt32(dw2), dstH: UInt32(dh2), factor: UInt32(f))
            try engine.run("box_downsample", buffers: [try c.buf(plane), ob],
                           uniforms: bytes(of: bp), gridW: dw2, gridH: dh2)
            c.report("box_downsample", cpuBox, try c.read(ob, dw2 * dh2))

            let img = c.rand(n * 4)
            let cpuLuma = (0..<n).map { luma(img, $0) }
            let ol = try engine.makeBuffer(floats: n)
            try engine.run("luma_plane", buffers: [try c.buf(img), ol],
                           uniforms: bytes(of: Count1(count: UInt32(n))), gridW: n)
            c.report("luma_plane", cpuLuma, try c.read(ol, n))
        }

        // -- progressive_preview / normalize_out ------------------------------
        do {
            let accum = c.rand(n * 4)
            var wsum = c.rand(n)
            for i in stride(from: 0, to: n, by: 7) { wsum[i] = 0.001 }  // exercise the floor
            let pw = 31, ph = 23
            var cpu = [Float](repeating: 0, count: pw * ph * 4)
            for y in 0..<ph { for x in 0..<pw {
                let si = min(y * h / ph, h - 1) * w + min(x * w / pw, w - 1)
                let o = (y * pw + x) * 4
                if wsum[si] > 0.01 {
                    for ch in 0..<3 { cpu[o + ch] = accum[si * 4 + ch] / wsum[si] }
                }
                cpu[o + 3] = 1
            } }
            let o = try engine.makeBuffer(floats: pw * ph * 4)
            let p = PreviewParams(srcW: UInt32(w), srcH: UInt32(h),
                                  dstW: UInt32(pw), dstH: UInt32(ph))
            try engine.run("progressive_preview",
                           buffers: [try c.buf(accum), try c.buf(wsum), o],
                           uniforms: bytes(of: p), gridW: pw, gridH: ph)
            c.report("progressive_preview", cpu, try c.read(o, pw * ph * 4))

            var cpuNorm = [Float](repeating: 0, count: n * 4)
            for i in 0..<n {
                if wsum[i] > 1e-7 {
                    for ch in 0..<3 { cpuNorm[i * 4 + ch] = accum[i * 4 + ch] / wsum[i] }
                    cpuNorm[i * 4 + 3] = 1
                } else {
                    cpuNorm[i * 4 + 3] = 1
                }
            }
            let on = try engine.makeBuffer(floats: n * 4)
            try engine.run("normalize_out",
                           buffers: [try c.buf(accum), try c.buf(wsum), on],
                           uniforms: bytes(of: Count1(count: UInt32(n))), gridW: n)
            c.report("normalize_out", cpuNorm, try c.read(on, n * 4))
        }

        // -- confidence_map ---------------------------------------------------
        do {
            let energy = c.rand(n, scale: 0.1)
            let cw = 16, ch = 12
            let conc = c.rand(cw * ch)
            let halfFloor: Float = 0.02, conc2: Float = 0.01
            var cpu = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let es = max(energy[i] - halfFloor, 0)
                let e2 = es * es
                var cf = e2 / (e2 + halfFloor * halfFloor)
                let x = i % w, y = i / w
                let gx = min(max((Float(x) + 0.5) / 4 - 0.5, 0), Float(cw - 1))
                let gy = min(max((Float(y) + 0.5) / 4 - 0.5, 0), Float(ch - 1))
                let x0 = min(Int(gx), cw - 1), x1 = min(x0 + 1, cw - 1)
                let y0 = min(Int(gy), ch - 1), y1 = min(y0 + 1, ch - 1)
                let fx = gx - Float(x0), fy = gy - Float(y0)
                let k = (conc[y0 * cw + x0] * (1 - fx) + conc[y0 * cw + x1] * fx) * (1 - fy)
                      + (conc[y1 * cw + x0] * (1 - fx) + conc[y1 * cw + x1] * fx) * fy
                cf *= k * k / (k * k + conc2)
                cpu[i] = cf
            }
            let o = try engine.makeBuffer(floats: n)
            let p = ConfidenceParams(width: UInt32(w), concW: UInt32(cw), concH: UInt32(ch),
                                     factor: 4, halfFloor: halfFloor, conc2: conc2,
                                     count: UInt32(n))
            try engine.run("confidence_map",
                           buffers: [try c.buf(energy), o, try c.buf(conc)],
                           uniforms: bytes(of: p), gridW: n)
            c.report("confidence_map", cpu, try c.read(o, n))
        }

        // -- weighted_median --------------------------------------------------
        do {
            let bins = 8, radius = 5, step = 2, cwin = 1
            let values = c.rand(n, scale: Float(bins - 1))
            var weights = c.rand(n)
            for i in stride(from: 0, to: n, by: 5) { weights[i] = 0 }  // sparse holes
            var cpuOut = [Float](repeating: 0, count: n)
            var cpuCons = cpuOut
            for y in 0..<h { for x in 0..<w {
                var hist = [Float](repeating: 0, count: bins)
                var total: Float = 0
                for dy in stride(from: -radius, through: radius, by: step) {
                    let yy = min(max(y + dy, 0), h - 1)
                    for dx in stride(from: -radius, through: radius, by: step) {
                        let xx = min(max(x + dx, 0), w - 1)
                        let wt = weights[yy * w + xx]
                        if wt > 1e-3 {
                            hist[min(max(Int(values[yy * w + xx] + 0.5), 0), bins - 1)] += wt
                            total += wt
                        }
                    }
                }
                let i = y * w + x
                if total <= 1e-3 { cpuOut[i] = values[i]; cpuCons[i] = 0; continue }
                let halfT = total * 0.5
                var acc: Float = 0
                var lo = bins - 1
                for b in 0..<bins { acc += hist[b]; if acc >= halfT { lo = b; break } }
                var below: Float = 0
                for b in 0..<lo { below += hist[b] }
                let frac = min(max((halfT - below) / max(hist[lo], 1e-9), 0), 1)
                cpuOut[i] = Float(lo) - 0.5 + frac
                var agree: Float = 0
                for b in max(lo - cwin, 0)...min(lo + cwin, bins - 1) { agree += hist[b] }
                cpuCons[i] = agree / total
            } }
            let o = try engine.makeBuffer(floats: n)
            let cons = try engine.makeBuffer(floats: n)
            let p = MedianParams(width: UInt32(w), height: UInt32(h), radius: Int32(radius),
                                 step: Int32(step), bins: UInt32(bins),
                                 consensusWindow: Int32(cwin))
            try engine.run("weighted_median",
                           buffers: [try c.buf(values), try c.buf(weights), o, cons],
                           uniforms: bytes(of: p), gridW: w, gridH: h)
            c.report("weighted_median", cpuOut + cpuCons, try c.read(o, n) + c.read(cons, n))
        }

        // -- guided_apply_blend (spill exercised) -----------------------------
        do {
            let gw = 32, gh = 24
            let aBar = c.rand(gw * gh, scale: 2), bBar = c.rand(gw * gh, scale: 3)
            let guide = c.rand(n), conf = c.rand(n)
            let depthMed = c.rand(n, scale: 5), consensus = c.rand(n)
            let spillD = c.rand(gw * gh, scale: 5), spillS = c.rand(gw * gh, scale: 0.5)
            let maxIndex: Float = 5, guideScale: Float = 1.5, residualW2: Float = 2.25
            var cpu = [Float](repeating: 0, count: n)
            for y in 0..<h { for x in 0..<w {
                let gy = min(max((Float(y) + 0.5) * 0.5 - 0.5, 0), Float(gh - 1))
                let y0 = min(Int(gy), gh - 1), y1 = min(y0 + 1, gh - 1)
                let fy = gy - Float(y0)
                let gx = min(max((Float(x) + 0.5) * 0.5 - 0.5, 0), Float(gw - 1))
                let x0 = min(Int(gx), gw - 1), x1 = min(x0 + 1, gw - 1)
                let fx = gx - Float(x0)
                let i00 = y0 * gw + x0, i01 = y0 * gw + x1
                let i10 = y1 * gw + x0, i11 = y1 * gw + x1
                func lerp(_ p: [Float]) -> Float {
                    (p[i00] * (1 - fx) + p[i01] * fx) * (1 - fy)
                        + (p[i10] * (1 - fx) + p[i11] * fx) * fy
                }
                let i = y * w + x
                var dReg = lerp(aBar) * (guideScale * guide[i]) + lerp(bBar)
                var cf = max(conf[i], consensus[i] * consensus[i])
                let sSm = lerp(spillS), dSm = lerp(spillD)
                cf *= 1 - sSm
                dReg += sSm * (1 - cf) * (dSm - dReg)
                let r = dReg - depthMed[i]
                let t = r * r / (r * r + residualW2)
                let sg = min(max((cf - 0.35) / 0.35, 0), 1)
                let gate = sg * sg * (3 - 2 * sg)
                let cb = cf + (1 - cf) * (t * gate)
                cpu[i] = min(max(cb * depthMed[i] + (1 - cb) * dReg, 0), maxIndex)
            } }
            let o = try engine.makeBuffer(floats: n)
            let p = GuidedApplyParams(width: UInt32(w), height: UInt32(h),
                                      gridW: UInt32(gw), gridH: UInt32(gh),
                                      invFactor: 0.5, guideScale: guideScale,
                                      maxIndex: maxIndex, residualW2: residualW2,
                                      hasSpill: 1)
            try engine.run("guided_apply_blend",
                           buffers: [try c.buf(aBar), try c.buf(bBar), try c.buf(guide),
                                     try c.buf(conf), try c.buf(depthMed), o,
                                     try c.buf(consensus), try c.buf(spillD),
                                     try c.buf(spillS)],
                           uniforms: bytes(of: p), gridW: w, gridH: h)
            c.report("guided_apply_blend", cpu, try c.read(o, n))
        }

        // -- clamp_plane ------------------------------------------------------
        do {
            let plane = c.rand(n, scale: 3)
            let cpu = plane.map { min(max($0, 0), 2.0) }
            let b = try c.buf(plane)
            try engine.run("clamp_plane", buffers: [b],
                           uniforms: bytes(of: ClampParams(maxV: 2.0, count: UInt32(n))),
                           gridW: n)
            c.report("clamp_plane", cpu, try c.read(b, n))
        }

        // -- pyramid family ---------------------------------------------------
        let k5: [Float] = [1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16]
        do {
            let img = c.rand(n * 4)
            var cpuH = [Float](repeating: 0, count: n * 4)
            for y in 0..<h { for x in 0..<w { for ch in 0..<4 {
                var acc: Float = 0
                for i in -2...2 {
                    acc += img[(y * w + min(max(x + i, 0), w - 1)) * 4 + ch] * k5[i + 2]
                }
                cpuH[(y * w + x) * 4 + ch] = acc
            } } }
            var cpuV = [Float](repeating: 0, count: n * 4)
            for y in 0..<h { for x in 0..<w { for ch in 0..<4 {
                var acc: Float = 0
                for i in -2...2 {
                    acc += cpuH[(min(max(y + i, 0), h - 1) * w + x) * 4 + ch] * k5[i + 2]
                }
                cpuV[(y * w + x) * 4 + ch] = acc
            } } }
            let i = try c.buf(img)
            let t = try engine.makeBuffer(floats: n * 4)
            let o = try engine.makeBuffer(floats: n * 4)
            let d2 = Dims2(w: UInt32(w), h: UInt32(h))
            try engine.run("pyr_blur5_h", buffers: [i, t], uniforms: bytes(of: d2), gridW: w, gridH: h)
            try engine.run("pyr_blur5_v", buffers: [t, o], uniforms: bytes(of: d2), gridW: w, gridH: h)
            c.report("pyr_blur5_h+v", cpuV, try c.read(o, n * 4))

            // decimate (w,h → half)
            let hw = (w + 1) / 2, hh = (h + 1) / 2
            var cpuDec = [Float](repeating: 0, count: hw * hh * 4)
            for y in 0..<hh { for x in 0..<hw {
                let si = (min(y * 2, h - 1) * w + min(x * 2, w - 1)) * 4
                for ch in 0..<4 { cpuDec[(y * hw + x) * 4 + ch] = img[si + ch] }
            } }
            let od = try engine.makeBuffer(floats: hw * hh * 4)
            let rp = PreviewParams(srcW: UInt32(w), srcH: UInt32(h),
                                   dstW: UInt32(hw), dstH: UInt32(hh))
            try engine.run("pyr_decimate", buffers: [i, od], uniforms: bytes(of: rp),
                           gridW: hw, gridH: hh)
            c.report("pyr_decimate", cpuDec, try c.read(od, hw * hh * 4))

            // upsample (half → w,h) + upsample_add
            let small = c.rand(hw * hh * 4)
            func bilinear(_ p: [Float], _ x: Int, _ y: Int) -> [Float] {
                let fx = (Float(x) + 0.5) * Float(hw) / Float(w) - 0.5
                let fy = (Float(y) + 0.5) * Float(hh) / Float(h) - 0.5
                let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                let wx = fx - Float(x0), wy = fy - Float(y0)
                let cx0 = min(max(x0, 0), hw - 1), cx1 = min(max(x0 + 1, 0), hw - 1)
                let cy0 = min(max(y0, 0), hh - 1), cy1 = min(max(y0 + 1, 0), hh - 1)
                return (0..<4).map { ch in
                    let top = p[(cy0 * hw + cx0) * 4 + ch] * (1 - wx) + p[(cy0 * hw + cx1) * 4 + ch] * wx
                    let bot = p[(cy1 * hw + cx0) * 4 + ch] * (1 - wx) + p[(cy1 * hw + cx1) * 4 + ch] * wx
                    return top * (1 - wy) + bot * wy
                }
            }
            var cpuUp = [Float](repeating: 0, count: n * 4)
            for y in 0..<h { for x in 0..<w {
                let v = bilinear(small, x, y)
                for ch in 0..<4 { cpuUp[(y * w + x) * 4 + ch] = v[ch] }
            } }
            let sb = try c.buf(small)
            let ou = try engine.makeBuffer(floats: n * 4)
            let up = PreviewParams(srcW: UInt32(hw), srcH: UInt32(hh),
                                   dstW: UInt32(w), dstH: UInt32(h))
            try engine.run("pyr_upsample", buffers: [sb, ou], uniforms: bytes(of: up),
                           gridW: w, gridH: h)
            c.report("pyr_upsample", cpuUp, try c.read(ou, n * 4))

            let band = c.rand(n * 4)
            let cpuUpAdd = (0..<(n * 4)).map { band[$0] + cpuUp[$0] }
            let oua = try engine.makeBuffer(floats: n * 4)
            try engine.run("pyr_upsample_add", buffers: [sb, try c.buf(band), oua],
                           uniforms: bytes(of: up), gridW: w, gridH: h)
            c.report("pyr_upsample_add", cpuUpAdd, try c.read(oua, n * 4))

            // select / band_energy / select_smoothed
            let fine = c.rand(n * 4), upBuf = c.rand(n * 4)
            var cpuFused = c.rand(n * 4)
            var cpuBest = c.rand(n, scale: 0.5)
            let gpuFused = try c.buf(cpuFused)
            let gpuBest = try c.buf(cpuBest)
            for i in 0..<n {
                var e: Float = 0
                for ch in 0..<3 { e += abs(fine[i * 4 + ch] - upBuf[i * 4 + ch]) }
                if e > cpuBest[i] {
                    cpuBest[i] = e
                    for ch in 0..<4 { cpuFused[i * 4 + ch] = fine[i * 4 + ch] - upBuf[i * 4 + ch] }
                }
            }
            try engine.run("pyr_select",
                           buffers: [try c.buf(fine), try c.buf(upBuf), gpuFused, gpuBest],
                           uniforms: bytes(of: Count1(count: UInt32(n))), gridW: n)
            c.report("pyr_select", cpuFused + cpuBest,
                     try c.read(gpuFused, n * 4) + c.read(gpuBest, n))

            let cpuEnergy = (0..<n).map { i -> Float in
                (0..<3).reduce(Float(0)) { $0 + abs(fine[i * 4 + $1] - upBuf[i * 4 + $1]) }
            }
            let oe = try engine.makeBuffer(floats: n)
            try engine.run("pyr_band_energy",
                           buffers: [try c.buf(fine), try c.buf(upBuf), oe],
                           uniforms: bytes(of: Count1(count: UInt32(n))), gridW: n)
            c.report("pyr_band_energy", cpuEnergy, try c.read(oe, n))

            let smoothed = c.rand(n)
            var cpuFused2 = c.rand(n * 4)
            var cpuBest2 = c.rand(n, scale: 0.5)
            let gpuFused2 = try c.buf(cpuFused2)
            let gpuBest2 = try c.buf(cpuBest2)
            for i in 0..<n where smoothed[i] > cpuBest2[i] {
                cpuBest2[i] = smoothed[i]
                for ch in 0..<4 { cpuFused2[i * 4 + ch] = fine[i * 4 + ch] - upBuf[i * 4 + ch] }
            }
            try engine.run("pyr_select_smoothed",
                           buffers: [try c.buf(fine), try c.buf(upBuf), gpuFused2, gpuBest2,
                                     try c.buf(smoothed)],
                           uniforms: bytes(of: Count1(count: UInt32(n))), gridW: n)
            c.report("pyr_select_smoothed", cpuFused2 + cpuBest2,
                     try c.read(gpuFused2, n * 4) + c.read(gpuBest2, n))

            // add4 / scale4 / fill
            let dstA = c.rand(n * 4), srcA = c.rand(n * 4)
            let cpuAdd = (0..<(n * 4)).map { dstA[$0] + srcA[$0] }
            let da = try c.buf(dstA)
            try engine.run("pyr_add4", buffers: [da, try c.buf(srcA)],
                           uniforms: bytes(of: Count1(count: UInt32(n))), gridW: n)
            c.report("pyr_add4", cpuAdd, try c.read(da, n * 4))

            let cpuScale = dstA.map { $0 * Float(0.375) }
            let ds = try c.buf(dstA)
            try engine.run("pyr_scale4", buffers: [ds],
                           uniforms: bytes(of: ScaleParams(s: 0.375, count: UInt32(n))),
                           gridW: n)
            c.report("pyr_scale4", cpuScale, try c.read(ds, n * 4))

            let df = try c.buf(c.rand(n))
            try engine.run("pyr_fill", buffers: [df],
                           uniforms: bytes(of: FillParams(v: -1.0, count: UInt32(n))),
                           gridW: n)
            c.report("pyr_fill", [Float](repeating: -1, count: n), try c.read(df, n))
        }

        return c.minPSNR
    }
}
#endif // HYPERFOCAL_HAVE_WGPU
