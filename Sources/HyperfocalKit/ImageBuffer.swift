import Foundation
import Dispatch

/// A CPU image: RGBA interleaved **Float16**, values nominally in [0, 1], row 0
/// is the top.
///
/// Storage is half-precision; arithmetic is not. Every consumer widens to f32
/// registers through `hfLoadRGBA` and narrows on store through `hfStoreRGBA`
/// (PortableSIMD.swift carries the codegen contract for both directions) — so
/// the pipeline's numerics stay f32 while the bytes it retains and moves are
/// halved: 8 B/px instead of 16, ~0.35 GB rather than ~0.7 GB per 46 MP plane.
///
/// The quality basis for storing at f16 is measured, not assumed: `FrameSpill`'s
/// degraded tier has stored exactly these planes at f16 since it shipped, at
/// 75–80 dB vs f32 on synth and 95.9 dB on a real fused output — an order of
/// magnitude below fusion's own error against truth (~38–41 dB), which is what
/// actually bounds the result.
///
/// Boundaries that must speak f32 — ImageIO/CImaging decode, DNG, the
/// fixed-point project format, GPU upload — convert explicitly via
/// `floatPixels()` / `init(width:height:floatPixels:)` or the bulk `hfWiden` /
/// `hfNarrow` helpers. There is no implicit conversion anywhere.
public struct ImageBuffer {
    public let width: Int
    public let height: Int
    public var pixels: [Float16] // count = width * height * 4

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [Float16](repeating: 0, count: width * height * 4)
    }

    public init(width: Int, height: Int, pixels: [Float16]) {
        precondition(pixels.count == width * height * 4, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Adopts an f32 RGBA plane, narrowing into storage.
    public init(width: Int, height: Int, floatPixels: [Float]) {
        precondition(floatPixels.count == width * height * 4, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = [Float16](unsafeUninitializedCapacity: floatPixels.count) {
            buf, initialized in
            floatPixels.withUnsafeBufferPointer { src in
                hfNarrow(src.baseAddress!, buf.baseAddress!, count: floatPixels.count)
            }
            initialized = floatPixels.count
        }
    }

    /// Narrows an f32 RGBA plane straight out of foreign memory — the CImaging
    /// decoders hand back a `float*` they own, so narrowing directly replaces
    /// the full-size `Array(UnsafeBufferPointer(...))` copy that would
    /// otherwise be needed, and lands half the bytes.
    public init(width: Int, height: Int, floatPixels src: UnsafePointer<Float>) {
        let count = width * height * 4
        self.width = width
        self.height = height
        self.pixels = [Float16](unsafeUninitializedCapacity: count) { buf, initialized in
            hfNarrow(src, buf.baseAddress!, count: count)
            initialized = count
        }
    }

    /// Materializes the plane as f32 — for the boundaries that require it.
    /// This is a full-size allocation; per-pixel consumers should widen through
    /// `hfLoadRGBA` instead of calling this.
    public func floatPixels() -> [Float] {
        [Float](unsafeUninitializedCapacity: pixels.count) { buf, initialized in
            pixels.withUnsafeBufferPointer { src in
                hfWiden(src.baseAddress!, buf.baseAddress!, count: pixels.count)
            }
            initialized = pixels.count
        }
    }

    /// Multiplies RGB by a gain, leaving alpha (coverage) untouched.
    public mutating func scaleRGB(by gain: Float) {
        scaleRGB(by: SIMD3(repeating: gain))
    }

    /// Per-channel variant (exposure gains are per-channel: LED flicker
    /// wobbles white balance, not just brightness).
    public mutating func scaleRGB(by gain: SIMD3<Float>) {
        let w = width
        let g = SIMD4<Float>(gain.x, gain.y, gain.z, 1)
        pixels.withUnsafeMutableBufferPointer { px in
            let p = px.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                var pi = y * w * 4
                for _ in 0..<w {
                    hfStoreRGBA(p, pi, hfLoadRGBA(p, pi) * g)
                    pi += 4
                }
            }
        }
    }

    /// RGB → RGB × scale + offset, leaving alpha (coverage) untouched —
    /// e.g. remapping a texture into a near-white band (scale 0.05,
    /// offset 0.95) for bright-field synthetic scenes.
    public mutating func affineRGB(scale: Float, offset: Float) {
        let w = width
        let g = SIMD4<Float>(scale, scale, scale, 1)
        let o = SIMD4<Float>(offset, offset, offset, 0)
        pixels.withUnsafeMutableBufferPointer { px in
            let p = px.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                var pi = y * w * 4
                for _ in 0..<w {
                    hfStoreRGBA(p, pi, hfLoadRGBA(p, pi) * g + o)
                    pi += 4
                }
            }
        }
    }

    /// Rec. 709 luma as a single-channel plane. Planes stay f32: they are
    /// per-pixel scalars (a quarter of an RGBA plane's bytes), several of them
    /// carry frame indices and accumulator sums rather than [0,1] color, and
    /// the depth plane's exactness above 2048 frames depends on f32.
    public func luminancePlane() -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        pixels.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    var i = y * width * 4
                    for x in 0..<width {
                        let p = hfLoadRGBA(src, i)
                        dst[y * width + x] = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
                        i += 4
                    }
                }
            }
        }
        return out
    }

    /// Fast nearest-neighbor thumbnail, for progress previews.
    public func downsampledNearest(maxSide: Int) -> ImageBuffer {
        guard max(width, height) > maxSide else { return self }
        return pixels.withUnsafeBufferPointer {
            ImageBuffer.downsampledNearest(fromRGBA: $0.baseAddress!,
                                           width: width, height: height,
                                           maxSide: maxSide)
        }
    }

    /// Same thumbnail sampled straight from interleaved RGBA halves — for
    /// GPU-shared or spill memory that isn't worth wrapping in an ImageBuffer
    /// just to throw away.
    public static func downsampledNearest(fromRGBA src: UnsafePointer<Float16>,
                                          width: Int, height: Int,
                                          maxSide: Int) -> ImageBuffer {
        let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
        let pw = max(1, Int(Double(width) * scale))
        let ph = max(1, Int(Double(height) * scale))
        var out = ImageBuffer(width: pw, height: ph)
        out.pixels.withUnsafeMutableBufferPointer { dstBuf in
            let dst = dstBuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: ph) { y in
                let sy = min(y * height / ph, height - 1)
                for x in 0..<pw {
                    let sx = min(x * width / pw, width - 1)
                    let si = (sy * width + sx) * 4
                    let di = (y * pw + x) * 4
                    // Storage-to-storage: no conversion, the halves copy as-is.
                    dst[di] = src[si]
                    dst[di + 1] = src[si + 1]
                    dst[di + 2] = src[si + 2]
                    dst[di + 3] = src[si + 3]
                }
            }
        }
        return out
    }

    public func cropped(x: Int, y: Int, width cw: Int, height ch: Int) -> ImageBuffer {
        precondition(x >= 0 && y >= 0 && x + cw <= width && y + ch <= height)
        var out = ImageBuffer(width: cw, height: ch)
        for row in 0..<ch {
            let srcStart = ((y + row) * width + x) * 4
            let dstStart = row * cw * 4
            out.pixels.replaceSubrange(dstStart..<(dstStart + cw * 4),
                                       with: pixels[srcStart..<(srcStart + cw * 4)])
        }
        return out
    }

    public func cropped(margin: Int) -> ImageBuffer {
        let m = max(0, min(margin, min(width, height) / 2 - 1))
        let nw = width - 2 * m, nh = height - 2 * m
        var out = ImageBuffer(width: nw, height: nh)
        for y in 0..<nh {
            let srcStart = ((y + m) * width + m) * 4
            let dstStart = y * nw * 4
            out.pixels.replaceSubrange(dstStart..<(dstStart + nw * 4),
                                       with: pixels[srcStart..<(srcStart + nw * 4)])
        }
        return out
    }
}
