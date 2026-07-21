import Foundation
#if canImport(simd)
import simd
#endif

/// Scratch microbenchmark for the warp inner loop (`hyperfocal debug-bench
/// warp`). Lives in the Kit because the CLI target builds -Onone in debug
/// while the Kit forces -O (Package.swift) — a bench in the CLI would measure
/// unoptimized code. Numbers are only meaningful relative to each other on
/// the same machine in the same run; the dev VM stalls occasionally, so
/// trust minima over means.
public enum WarpBench {

    /// Deterministic pseudo-image: smooth gradients plus hard high-frequency
    /// detail so the anti-ringing clamp and the negative lobes both do real
    /// work, as they do on photographs.
    static func makeSource(width: Int, height: Int) -> ImageBuffer {
        var img = ImageBuffer(width: width, height: height)
        img.pixels.withUnsafeMutableBufferPointer { p in
            for y in 0..<height {
                let fy = Float(y)
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let fx = Float(x)
                    p[i] = 0.5 + 0.4 * sinf(fx * 0.31) * cosf(fy * 0.17)
                    p[i + 1] = 0.5 + 0.4 * sinf(fx * 0.011 + fy * 0.013)
                    p[i + 2] = (x / 7 + y / 11) % 2 == 0 ? 0.9 : 0.1
                    p[i + 3] = 1
                }
            }
        }
        return img
    }

    /// Max |a-b| and PSNR over two equal-length float buffers (peak 1.0).
    static func diff(_ a: [Float], _ b: [Float]) -> (maxAbs: Float, psnr: Float, exact: Bool) {
        var maxAbs: Float = 0
        var sumSq: Double = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            maxAbs = max(maxAbs, abs(d))
            sumSq += Double(d) * Double(d)
        }
        let mse = sumSq / Double(a.count)
        let psnr = mse == 0 ? Float.infinity : Float(-10 * log10(mse))
        return (maxAbs, psnr, maxAbs == 0)
    }

    public static func run(iterations: Int = 7) {
        let w = 4000, h = 2750
        print("warp bench: \(w)x\(h) (\(w * h / 1_000_000) MP), \(iterations) iterations/variant")
        let src = makeSource(width: w, height: h)
        // A registration-shaped transform: sub-degree rotation, near-unit
        // scale, few-pixel translation. Interior path dominates, border path
        // runs on the frame edges — same mix as production.
        let center = SIMD2<Float>(Float(w) / 2, Float(h) / 2)
        let M = Warp.similarity(scale: 1.0004, rotation: 0.006,
                                translation: SIMD2<Float>(3.7, -2.3), center: center)
        let H = M.inverse

        var reference = [Float](repeating: 0, count: w * h * 4)

        func bench(_ name: String, _ f: (ImageBuffer, simd_float3x3, Int, Int, inout [Float]) -> Void,
                   isReference: Bool = false) {
            var dst = [Float](repeating: 0, count: w * h * 4)
            f(src, H, w, h, &dst)   // warm-up (page faults, LUT init)
            var best = Double.infinity
            var times: [Double] = []
            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                f(src, H, w, h, &dst)
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0)
                times.append(dt)
                best = min(best, dt)
            }
            let nsPerPx = best / Double(w * h)
            let all = times.map { String(format: "%.1f", $0 / Double(w * h)) }.joined(separator: " ")
            if isReference {
                reference = dst
                print(String(format: "%@: %.1f ns/px best  [%@]", name, nsPerPx, all))
            } else {
                let d = diff(reference, dst)
                print(String(format: "%@: %.1f ns/px best  [%@]  vs ref: %@",
                             name, nsPerPx, all,
                             d.exact ? "bit-identical"
                                     : String(format: "maxAbs %.2e, %.1f dB", d.maxAbs, d.psnr)))
            }
        }

        // Add experimental variants here as extra bench() lines and diff them
        // against production. Milestones on the 2-core dev VM (2026-07-20):
        // tap-at-a-time loop 42.2-43.0 ns/px; SIMD8 pair taps 40.4-41.4
        // (landed, 151.2 dB vs the old loop). Dead ends, measured: vectorized
        // LUT weights 16.6 vs 9.0 ns/set scalar (any SIMD8<Int32> conversion
        // init is an unspecialized generic, ~250 ns/call); Chebyshev weights
        // (Mac, reverted); register-captured anti-ring pixels and a single
        // SIMD4 store — both within noise. Loop cost split at 41 ns/px:
        // weights ~16, interior taps ~7, homography/divides/clamp/store ~19.
        bench("production", Warp.applyLanczos3, isReference: true)
    }
}
