import Foundation
#if canImport(simd)
import simd
#endif
import Dispatch

public enum Warp {

    public enum Method {
        /// 2×2 taps. Cheap, but softens every aligned frame slightly —
        /// visible at 100% on high-resolution stacks.
        case bilinear
        /// 6×6 windowed-sinc taps with an anti-ringing clamp; the default.
        case lanczos3
    }

    /// Resample `src` through a homography. `outputToSource` maps output pixel
    /// coordinates (x, y, 1) — top-left origin, y down — to source pixel coordinates.
    /// Samples outside the source get alpha 0 (colors are edge-clamped so no
    /// artificial dark edge appears in gradients); fusion treats alpha-0 pixels
    /// as "this frame has no data here" instead of smearing the border outward.
    ///
    /// The GPU `warp_lanczos3` / `warp_bilinear` kernels implement the same
    /// taps, edge clamping, and anti-ringing clamp — engine parity (≥ 60 dB
    /// between CPU and GPU fusions) depends on keeping them identical.
    public static func apply(_ src: ImageBuffer, outputToSource H: simd_float3x3,
                             outWidth: Int, outHeight: Int,
                             method: Method = .lanczos3) -> ImageBuffer {
        switch method {
        case .bilinear:
            return applyBilinear(src, outputToSource: H, outWidth: outWidth, outHeight: outHeight)
        case .lanczos3:
            return applyLanczos3(src, outputToSource: H, outWidth: outWidth, outHeight: outHeight)
        }
    }

    /// Lanczos-3 kernel: sinc(x)·sinc(x/3) for |x| < 3, via the product form
    /// 3·sin(πx)·sin(πx/3)/(πx)². Shared formula with the Metal kernel.
    @inline(__always)
    static func lanczos3(_ x: Float) -> Float {
        let ax = abs(x)
        if ax < 1e-5 { return 1 }
        if ax >= 3 { return 0 }
        let px = Float.pi * ax
        return 3 * sinf(px) * sinf(px / 3) / (px * px)
    }

    /// `lanczos3` sampled over [0, 3] with linear interpolation. The exact
    /// form costs 24 sinf calls per output pixel (~260 M per 11 MP frame) —
    /// measured at ~93% of CPU pyramid-fusion wall clock. Interpolation
    /// error at this resolution is O(1e-8), orders of magnitude below every
    /// parity floor (the wgpu kernel gate measures the GPU's transcendental
    /// precision at ~130 dB against this very function).
    static let lanczos3TableSize = 8192
    static let lanczos3Table: [Float] = {
        var t = [Float](repeating: 0, count: lanczos3TableSize + 2)
        for i in 0...lanczos3TableSize {
            t[i] = lanczos3(Float(i) * 3 / Float(lanczos3TableSize))
        }
        return t
    }()

    @inline(__always)
    static func lanczos3Fast(_ x: Float, _ table: UnsafePointer<Float>) -> Float {
        // Bit-mask abs: generic abs() dispatched through a Numeric.magnitude
        // witness (6% of warp samples) and even the concrete .magnitude
        // getter stayed an outlined call at -O on the Mac toolchain. The
        // mask is two integer ops, inlined unconditionally, and exact for
        // every input including -0 and NaN.
        let ax = min(Float(bitPattern: x.bitPattern & 0x7FFF_FFFF)
                     * (Float(lanczos3TableSize) / 3), Float(lanczos3TableSize))
        let i = Int(ax)
        let f = ax - Float(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    static func applyLanczos3(_ src: ImageBuffer, outputToSource H: simd_float3x3,
                              outWidth: Int, outHeight: Int) -> ImageBuffer {
        var out = ImageBuffer(width: outWidth, height: outHeight)
        applyLanczos3(src, outputToSource: H, outWidth: outWidth, outHeight: outHeight,
                      into: &out.pixels)
        return out
    }

    /// Warp into a preallocated RGBA buffer — the CPU fusion workspace's
    /// level 0. Skips the per-frame output allocation (a zeroed ~180 MB at
    /// 11 MP, page-faulted on first touch) and the copy that followed it.
    ///
    /// Interior tap loop runs as three SIMD8 pair loads + FMAs per row
    /// (2026-07-20): 18 loads instead of 36 and the horizontal sum grouped
    /// (even taps + odd taps) instead of left-to-right. That reassociation
    /// moves the result by ~1 ulp — measured 151.2 dB vs the tap-at-a-time
    /// loop on the bench scene (`debug-bench warp`), far above every parity
    /// floor. Scalar LUT weights are deliberate: the vectorized variant
    /// measured SLOWER (16.6 vs 9.0 ns/set — and any SIMD8<Int32> conversion
    /// init is an unspecialized generic at ~250 ns/call; see
    /// PortableSIMD.swift's contract before "improving" this).
    static func applyLanczos3(_ src: ImageBuffer, outputToSource H: simd_float3x3,
                              outWidth: Int, outHeight: Int, into dst: inout [Float]) {
        precondition(dst.count == outWidth * outHeight * 4)
        let sw = src.width, sh = src.height
        lanczos3Table.withUnsafeBufferPointer { lutBuf in
        let lut = lutBuf.baseAddress!
        src.pixels.withUnsafeBufferPointer { s in
            let sraw = UnsafeRawPointer(s.baseAddress!)
            dst.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: outHeight) { y in
                    for x in 0..<outWidth {
                        let p = H * simd_float3(Float(x), Float(y), 1)
                        let sx = p.x / p.z
                        let sy = p.y / p.z
                        let x0 = Int(sx.rounded(.down))
                        let y0 = Int(sy.rounded(.down))
                        let fx = sx - Float(x0)
                        let fy = sy - Float(y0)
                        // Weights live in SIMD8 registers, not arrays — heap
                        // subscripts in this loop cost more than the taps.
                        var wx = SIMD8<Float>(), wy = SIMD8<Float>()
                        var sumX: Float = 0, sumY: Float = 0
                        for k in 0..<6 {
                            wx[k] = lanczos3Fast(fx - Float(k - 2), lut); sumX += wx[k]
                            wy[k] = lanczos3Fast(fy - Float(k - 2), lut); sumY += wy[k]
                        }
                        var acc = SIMD4<Float>()
                        var sample: SIMD4<Float>
                        // Interior fast path: the whole 6×6 footprint (and the
                        // 2×2 anti-ring footprint) is in bounds, so the taps
                        // are contiguous vector loads with no per-tap clamps.
                        if x0 >= 2 && x0 + 3 < sw && y0 >= 2 && y0 + 3 < sh {
                            let w01 = SIMD8<Float>(lowHalf: SIMD4<Float>(repeating: wx[0]),
                                                   highHalf: SIMD4<Float>(repeating: wx[1]))
                            let w23 = SIMD8<Float>(lowHalf: SIMD4<Float>(repeating: wx[2]),
                                                   highHalf: SIMD4<Float>(repeating: wx[3]))
                            let w45 = SIMD8<Float>(lowHalf: SIMD4<Float>(repeating: wx[4]),
                                                   highHalf: SIMD4<Float>(repeating: wx[5]))
                            for ky in 0..<6 {
                                let rowBase = (y0 - 2 + ky) * sw + (x0 - 2)
                                let p01 = sraw.loadUnaligned(fromByteOffset: rowBase << 4,
                                                             as: SIMD8<Float>.self)
                                let p23 = sraw.loadUnaligned(fromByteOffset: (rowBase + 2) << 4,
                                                             as: SIMD8<Float>.self)
                                let p45 = sraw.loadUnaligned(fromByteOffset: (rowBase + 4) << 4,
                                                             as: SIMD8<Float>.self)
                                let row8 = p01 * w01 + p23 * w23 + p45 * w45
                                acc += (row8.lowHalf + row8.highHalf) * wy[ky]
                            }
                            sample = acc / (sumX * sumY)
                            let ia = (y0 * sw + x0) << 4
                            let ic = ((y0 + 1) * sw + x0) << 4
                            let a = sraw.loadUnaligned(fromByteOffset: ia, as: SIMD4<Float>.self)
                            let b = sraw.loadUnaligned(fromByteOffset: ia + 16, as: SIMD4<Float>.self)
                            let c = sraw.loadUnaligned(fromByteOffset: ic, as: SIMD4<Float>.self)
                            let d = sraw.loadUnaligned(fromByteOffset: ic + 16, as: SIMD4<Float>.self)
                            // hfMin/hfMax (concrete, PortableSIMD): the generic
                            // simd_* shims don't specialize cross-file (1089 vs
                            // 35 ns/px), and on the Mac toolchain even the
                            // stdlib's generic pointwiseMin/Max stayed
                            // witness-dispatched at -O — 33% of warp samples.
                            let lo = hfMin(hfMin(a, b), hfMin(c, d))
                            let hi = hfMax(hfMax(a, b), hfMax(c, d))
                            sample = hfMin(hfMax(sample, lo), hi)
                        } else {
                            for ky in 0..<6 {
                                let ty = min(max(y0 - 2 + ky, 0), sh - 1)
                                let rowBase = ty * sw
                                var row = SIMD4<Float>()
                                for kx in 0..<6 {
                                    let tx = min(max(x0 - 2 + kx, 0), sw - 1)
                                    let i = (rowBase + tx) * 4
                                    row += SIMD4<Float>(s[i], s[i + 1], s[i + 2], s[i + 3]) * wx[kx]
                                }
                                acc += row * wy[ky]
                            }
                            sample = acc / (sumX * sumY)
                            // Anti-ringing: the negative lobes overshoot at hard
                            // edges (and would glow at the coverage boundary);
                            // clamp to the bilinear footprint's range, which only
                            // engages on overshoot and keeps in-range detail.
                            let cx0 = min(max(x0, 0), sw - 1), cx1 = min(max(x0 + 1, 0), sw - 1)
                            let cy0 = min(max(y0, 0), sh - 1), cy1 = min(max(y0 + 1, 0), sh - 1)
                            let ia = (cy0 * sw + cx0) * 4, ib = (cy0 * sw + cx1) * 4
                            let ic = (cy1 * sw + cx0) * 4, id = (cy1 * sw + cx1) * 4
                            let a = SIMD4<Float>(s[ia], s[ia + 1], s[ia + 2], s[ia + 3])
                            let b = SIMD4<Float>(s[ib], s[ib + 1], s[ib + 2], s[ib + 3])
                            let c = SIMD4<Float>(s[ic], s[ic + 1], s[ic + 2], s[ic + 3])
                            let d = SIMD4<Float>(s[id], s[id + 1], s[id + 2], s[id + 3])
                            let lo = hfMin(hfMin(a, b), hfMin(c, d))
                            let hi = hfMax(hfMax(a, b), hfMax(c, d))
                            sample = hfMin(hfMax(sample, lo), hi)
                        }
                        let inside = sx >= -0.5 && sx <= Float(sw) - 0.5
                            && sy >= -0.5 && sy <= Float(sh) - 0.5
                        let oi = (y * outWidth + x) * 4
                        o[oi] = sample.x
                        o[oi + 1] = sample.y
                        o[oi + 2] = sample.z
                        o[oi + 3] = inside ? sample.w : 0
                    }
                }
            }
        }
        }
    }

    static func applyBilinear(_ src: ImageBuffer, outputToSource H: simd_float3x3,
                              outWidth: Int, outHeight: Int) -> ImageBuffer {
        let sw = src.width, sh = src.height
        var out = ImageBuffer(width: outWidth, height: outHeight)
        src.pixels.withUnsafeBufferPointer { s in
            out.pixels.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: outHeight) { y in
                    for x in 0..<outWidth {
                        let p = H * simd_float3(Float(x), Float(y), 1)
                        let sx = p.x / p.z
                        let sy = p.y / p.z
                        let x0 = Int(sx.rounded(.down))
                        let y0 = Int(sy.rounded(.down))
                        let wx = sx - Float(x0)
                        let wy = sy - Float(y0)
                        let cx0 = min(max(x0, 0), sw - 1)
                        let cx1 = min(max(x0 + 1, 0), sw - 1)
                        let cy0 = min(max(y0, 0), sh - 1)
                        let cy1 = min(max(y0 + 1, 0), sh - 1)
                        let i00 = (cy0 * sw + cx0) * 4, i10 = (cy0 * sw + cx1) * 4
                        let i01 = (cy1 * sw + cx0) * 4, i11 = (cy1 * sw + cx1) * 4
                        let inside = sx >= -0.5 && sx <= Float(sw) - 0.5
                            && sy >= -0.5 && sy <= Float(sh) - 0.5
                        let oi = (y * outWidth + x) * 4
                        for c in 0..<4 {
                            let top = s[i00 + c] * (1 - wx) + s[i10 + c] * wx
                            let bot = s[i01 + c] * (1 - wx) + s[i11 + c] * wx
                            o[oi + c] = c == 3 && !inside ? 0 : top * (1 - wy) + bot * wy
                        }
                    }
                }
            }
        }
        return out
    }

    /// Similarity transform about a center point, as a homography that maps
    /// destination coordinates to source coordinates when inverted by the caller.
    /// Returns M with dst = M * src (scale then translate, about `center`).
    public static func similarity(scale: Float, rotation: Float, translation: SIMD2<Float>,
                                  center: SIMD2<Float>) -> simd_float3x3 {
        let c = cosf(rotation) * scale
        let s = sinf(rotation) * scale
        // dst = R*S*(src - center) + center + t
        let tx = center.x + translation.x - (c * center.x - s * center.y)
        let ty = center.y + translation.y - (s * center.x + c * center.y)
        return simd_float3x3(rows: [
            SIMD3<Float>(c, -s, tx),
            SIMD3<Float>(s, c, ty),
            SIMD3<Float>(0, 0, 1),
        ])
    }
}
