#if HYPERFOCAL_HAVE_WGPU
import Foundation

/// Kernel-level CPU↔wgpu parity checks — the wgpu backend's equivalent of the
/// Metal path's parity discipline (ROADMAP header: ≥ 90 dB). Each check runs
/// one kernel against the CPU reference implementation on deterministic
/// synthetic data and reports PSNR; `run` returns the minimum. Grows a case
/// per kernel as the WGSL library grows.
public enum WgpuParity {

    /// Deterministic pixels (xorshift), values in [0, 1).
    private static func randomPlane(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(state % 1_000_000) / 1_000_000
        }
    }

    private static func psnr(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        var mse = 0.0
        for i in 0..<a.count {
            let d = Double(a[i] - b[i])
            mse += d * d
        }
        mse /= Double(a.count)
        return mse == 0 ? .infinity : 10 * log10(1.0 / mse)
    }

    struct WarpParams {
        var r0: SIMD4<Float>
        var r1: SIMD4<Float>
        var r2: SIMD4<Float>
        var dims: SIMD4<UInt32>
    }

    struct BlurParams {
        var width: UInt32
        var height: UInt32
        var radius: Int32
        var pad: UInt32 = 0
    }

    private static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    /// Runs every check, printing one line each. Returns the minimum PSNR
    /// (infinity when bit-identical), or throws if the engine is unavailable.
    public static func run(log: (String) -> Void = { print($0) }) throws -> Double {
        guard let engine = WgpuEngine.shared else {
            throw StackError.metal("no wgpu adapter available")
        }
        log("wgpu adapter: \(engine.adapterSummary)")
        var minPSNR = Double.infinity

        // -- warp_lanczos3 vs Warp.apply (the production CPU reference) ------
        let sw = 257, sh = 181, dw = 241, dh = 173
        let src = ImageBuffer(width: sw, height: sh,
                              pixels: randomPlane(sw * sh * 4, seed: 0x9E3779B97F4A7C15))
        // A gentle similarity: rotation + translation + slight scale, the
        // shape real registration homographies take.
        let a: Float = 0.03, s: Float = 1.02, tx: Float = 3.7, ty: Float = -2.2
        let H = simd_float3x3(rows: [
            SIMD3<Float>(s * cos(a), -s * sin(a), tx),
            SIMD3<Float>(s * sin(a), s * cos(a), ty),
            SIMD3<Float>(0, 0, 1),
        ])
        let cpu = Warp.apply(src, outputToSource: H, outWidth: dw, outHeight: dh,
                             method: .lanczos3)

        let srcBuf = try engine.makeBuffer(floats: sw * sh * 4)
        let dstBuf = try engine.makeBuffer(floats: dw * dh * 4)
        src.pixels.withUnsafeBytes {
            engine.upload($0.baseAddress!, byteCount: $0.count, to: srcBuf)
        }
        // Rows of H for the kernel (H[c][r] subscripts columns — same
        // extraction as GPUDMap's WarpParams).
        let params = WarpParams(
            r0: SIMD4<Float>(H[0][0], H[1][0], H[2][0], 0),
            r1: SIMD4<Float>(H[0][1], H[1][1], H[2][1], 0),
            r2: SIMD4<Float>(H[0][2], H[1][2], H[2][2], 0),
            dims: SIMD4<UInt32>(UInt32(sw), UInt32(sh), UInt32(dw), UInt32(dh)))
        try engine.run("warp_lanczos3", buffers: [srcBuf, dstBuf],
                       uniforms: bytes(of: params), gridW: dw, gridH: dh)
        var gpu = [Float](repeating: 0, count: dw * dh * 4)
        try gpu.withUnsafeMutableBytes { try engine.download(dstBuf, into: $0.baseAddress!) }
        let warpPSNR = psnr(cpu.pixels, gpu)
        log(String(format: "warp_lanczos3: %.1f dB", warpPSNR))
        minPSNR = min(minPSNR, warpPSNR)

        // -- blur_h + blur_v vs a direct separable convolution ---------------
        let bw = 317, bh = 211
        let plane = randomPlane(bw * bh, seed: 0xD1B54A32D192ED03)
        let weights = Filters.gaussianKernel(sigma: 6)
        let radius = weights.count / 2

        var cpuH = [Float](repeating: 0, count: bw * bh)
        for y in 0..<bh {
            for x in 0..<bw {
                var acc: Float = 0
                for i in -radius...radius {
                    acc += plane[y * bw + min(max(x + i, 0), bw - 1)] * weights[i + radius]
                }
                cpuH[y * bw + x] = acc
            }
        }
        var cpuV = [Float](repeating: 0, count: bw * bh)
        for y in 0..<bh {
            for x in 0..<bw {
                var acc: Float = 0
                for i in -radius...radius {
                    acc += cpuH[min(max(y + i, 0), bh - 1) * bw + x] * weights[i + radius]
                }
                cpuV[y * bw + x] = acc
            }
        }

        let planeBuf = try engine.makeBuffer(floats: bw * bh)
        let tmpBuf = try engine.makeBuffer(floats: bw * bh)
        let weightBuf = try engine.makeBuffer(floats: weights.count)
        plane.withUnsafeBytes { engine.upload($0.baseAddress!, byteCount: $0.count, to: planeBuf) }
        weights.withUnsafeBytes { engine.upload($0.baseAddress!, byteCount: $0.count, to: weightBuf) }
        let bp = BlurParams(width: UInt32(bw), height: UInt32(bh), radius: Int32(radius))
        try engine.run("blur_h", buffers: [planeBuf, tmpBuf, weightBuf],
                       uniforms: bytes(of: bp), gridW: bw, gridH: bh)
        try engine.run("blur_v", buffers: [tmpBuf, planeBuf, weightBuf],
                       uniforms: bytes(of: bp), gridW: bw, gridH: bh)
        var gpuBlur = [Float](repeating: 0, count: bw * bh)
        try gpuBlur.withUnsafeMutableBytes { try engine.download(planeBuf, into: $0.baseAddress!) }
        let blurPSNR = psnr(cpuV, gpuBlur)
        log(String(format: "blur_h+blur_v: %.1f dB", blurPSNR))
        minPSNR = min(minPSNR, blurPSNR)

        return minPSNR
    }
}
#endif // HYPERFOCAL_HAVE_WGPU
