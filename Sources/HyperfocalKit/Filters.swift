import Foundation
import Dispatch

public enum Filters {

    public static func gaussianKernel(sigma: Float) -> [Float] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var k = [Float](repeating: 0, count: 2 * radius + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = expf(-Float(i * i) / (2 * sigma * sigma))
            k[i + radius] = v
            sum += v
        }
        for i in k.indices { k[i] /= sum }
        return k
    }

    /// Separable Gaussian blur of a single-channel plane, clamp-to-edge.
    public static func blurPlane(_ src: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        guard sigma > 0.01 else { return src }
        let k = gaussianKernel(sigma: sigma)
        let r = k.count / 2
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                k.withUnsafeBufferPointer { kp in
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        let row = y * width
                        for x in 0..<width {
                            var acc: Float = 0
                            for i in -r...r {
                                let xi = min(max(x + i, 0), width - 1)
                                acc += s[row + xi] * kp[i + r]
                            }
                            t[row + x] = acc
                        }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                k.withUnsafeBufferPointer { kp in
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for x in 0..<width {
                            var acc: Float = 0
                            for i in -r...r {
                                let yi = min(max(y + i, 0), height - 1)
                                acc += t[yi * width + x] * kp[i + r]
                            }
                            o[y * width + x] = acc
                        }
                    }
                }
            }
        }
        return out
    }

    /// Separable convolution of an RGBA image (all 4 channels), clamp-to-edge.
    public static func convolveSeparableRGBA(_ src: ImageBuffer, kernel: [Float]) -> ImageBuffer {
        let w = src.width, h = src.height
        let r = kernel.count / 2
        var tmp = ImageBuffer(width: w, height: h)
        var out = ImageBuffer(width: w, height: h)
        src.pixels.withUnsafeBufferPointer { s in
            tmp.pixels.withUnsafeMutableBufferPointer { t in
                kernel.withUnsafeBufferPointer { kp in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        let row = y * w * 4
                        for x in 0..<w {
                            var acc = (Float(0), Float(0), Float(0), Float(0))
                            for i in -r...r {
                                let xi = min(max(x + i, 0), w - 1)
                                let idx = row + xi * 4
                                let kv = kp[i + r]
                                acc.0 += s[idx] * kv
                                acc.1 += s[idx + 1] * kv
                                acc.2 += s[idx + 2] * kv
                                acc.3 += s[idx + 3] * kv
                            }
                            let o = row + x * 4
                            t[o] = acc.0; t[o + 1] = acc.1; t[o + 2] = acc.2; t[o + 3] = acc.3
                        }
                    }
                }
            }
        }
        tmp.pixels.withUnsafeBufferPointer { t in
            out.pixels.withUnsafeMutableBufferPointer { o in
                kernel.withUnsafeBufferPointer { kp in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            var acc = (Float(0), Float(0), Float(0), Float(0))
                            for i in -r...r {
                                let yi = min(max(y + i, 0), h - 1)
                                let idx = (yi * w + x) * 4
                                let kv = kp[i + r]
                                acc.0 += t[idx] * kv
                                acc.1 += t[idx + 1] * kv
                                acc.2 += t[idx + 2] * kv
                                acc.3 += t[idx + 3] * kv
                            }
                            let oi = (y * w + x) * 4
                            o[oi] = acc.0; o[oi + 1] = acc.1; o[oi + 2] = acc.2; o[oi + 3] = acc.3
                        }
                    }
                }
            }
        }
        return out
    }

    /// |∇²| of a single-channel plane (3x3 Laplacian, clamp-to-edge).
    public static func laplacianAbs(_ src: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let yu = max(y - 1, 0) * width
                    let yd = min(y + 1, height - 1) * width
                    let yc = y * width
                    for x in 0..<width {
                        let xl = max(x - 1, 0)
                        let xr = min(x + 1, width - 1)
                        let v = s[yu + x] + s[yd + x] + s[yc + xl] + s[yc + xr] - 4 * s[yc + x]
                        o[yc + x] = abs(v)
                    }
                }
            }
        }
        return out
    }

    /// 2x2 box downsample of a single-channel plane.
    public static func downsamplePlane2x(_ src: [Float], width: Int, height: Int) -> (plane: [Float], width: Int, height: Int) {
        let nw = max(1, width / 2), nh = max(1, height / 2)
        var out = [Float](repeating: 0, count: nw * nh)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: nh) { y in
                    let y0 = min(y * 2, height - 1), y1 = min(y * 2 + 1, height - 1)
                    for x in 0..<nw {
                        let x0 = min(x * 2, width - 1), x1 = min(x * 2 + 1, width - 1)
                        o[y * nw + x] = 0.25 * (s[y0 * width + x0] + s[y0 * width + x1]
                            + s[y1 * width + x0] + s[y1 * width + x1])
                    }
                }
            }
        }
        return (out, nw, nh)
    }

    /// Bilinear resize of a single-channel plane to an arbitrary size.
    public static func resizePlaneBilinear(_ src: [Float], width sw: Int, height sh: Int,
                                           toWidth tw: Int, toHeight th: Int) -> [Float] {
        var out = [Float](repeating: 0, count: tw * th)
        let sx = Float(sw) / Float(tw)
        let sy = Float(sh) / Float(th)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: th) { y in
                    let fy = (Float(y) + 0.5) * sy - 0.5
                    let y0 = Int(fy.rounded(.down))
                    let wy = fy - Float(y0)
                    let cy0 = min(max(y0, 0), sh - 1)
                    let cy1 = min(max(y0 + 1, 0), sh - 1)
                    for x in 0..<tw {
                        let fx = (Float(x) + 0.5) * sx - 0.5
                        let x0 = Int(fx.rounded(.down))
                        let wx = fx - Float(x0)
                        let cx0 = min(max(x0, 0), sw - 1)
                        let cx1 = min(max(x0 + 1, 0), sw - 1)
                        let top = s[cy0 * sw + cx0] * (1 - wx) + s[cy0 * sw + cx1] * wx
                        let bot = s[cy1 * sw + cx0] * (1 - wx) + s[cy1 * sw + cx1] * wx
                        o[y * tw + x] = top * (1 - wy) + bot * wy
                    }
                }
            }
        }
        return out
    }

    /// Bilinear resize of an RGBA image to an arbitrary size.
    public static func resizeBilinear(_ src: ImageBuffer, toWidth tw: Int, toHeight th: Int) -> ImageBuffer {
        let sw = src.width, sh = src.height
        var out = ImageBuffer(width: tw, height: th)
        let sx = Float(sw) / Float(tw)
        let sy = Float(sh) / Float(th)
        src.pixels.withUnsafeBufferPointer { s in
            out.pixels.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: th) { y in
                    let fy = (Float(y) + 0.5) * sy - 0.5
                    let y0 = Int(fy.rounded(.down))
                    let wy = fy - Float(y0)
                    let cy0 = min(max(y0, 0), sh - 1)
                    let cy1 = min(max(y0 + 1, 0), sh - 1)
                    for x in 0..<tw {
                        let fx = (Float(x) + 0.5) * sx - 0.5
                        let x0 = Int(fx.rounded(.down))
                        let wx = fx - Float(x0)
                        let cx0 = min(max(x0, 0), sw - 1)
                        let cx1 = min(max(x0 + 1, 0), sw - 1)
                        let i00 = (cy0 * sw + cx0) * 4, i10 = (cy0 * sw + cx1) * 4
                        let i01 = (cy1 * sw + cx0) * 4, i11 = (cy1 * sw + cx1) * 4
                        let oi = (y * tw + x) * 4
                        for c in 0..<4 {
                            let top = s[i00 + c] * (1 - wx) + s[i10 + c] * wx
                            let bot = s[i01 + c] * (1 - wx) + s[i11 + c] * wx
                            o[oi + c] = top * (1 - wy) + bot * wy
                        }
                    }
                }
            }
        }
        return out
    }
}
