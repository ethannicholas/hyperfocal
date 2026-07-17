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

    static func applyLanczos3(_ src: ImageBuffer, outputToSource H: simd_float3x3,
                              outWidth: Int, outHeight: Int) -> ImageBuffer {
        let sw = src.width, sh = src.height
        var out = ImageBuffer(width: outWidth, height: outHeight)
        src.pixels.withUnsafeBufferPointer { s in
            out.pixels.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: outHeight) { y in
                    var wx = [Float](repeating: 0, count: 6)
                    var wy = [Float](repeating: 0, count: 6)
                    for x in 0..<outWidth {
                        let p = H * simd_float3(Float(x), Float(y), 1)
                        let sx = p.x / p.z
                        let sy = p.y / p.z
                        let x0 = Int(sx.rounded(.down))
                        let y0 = Int(sy.rounded(.down))
                        let fx = sx - Float(x0)
                        let fy = sy - Float(y0)
                        var sumX: Float = 0, sumY: Float = 0
                        for k in 0..<6 {
                            wx[k] = lanczos3(fx - Float(k - 2)); sumX += wx[k]
                            wy[k] = lanczos3(fy - Float(k - 2)); sumY += wy[k]
                        }
                        var acc = SIMD4<Float>()
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
                        var sample = acc / (sumX * sumY)
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
                        sample = simd_clamp(sample,
                                            simd_min(simd_min(a, b), simd_min(c, d)),
                                            simd_max(simd_max(a, b), simd_max(c, d)))
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
        return out
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
