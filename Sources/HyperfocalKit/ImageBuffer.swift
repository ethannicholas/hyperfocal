import Foundation
import Dispatch

/// A CPU image: RGBA interleaved Float32, values nominally in [0, 1], row 0 is the top.
public struct ImageBuffer {
    public let width: Int
    public let height: Int
    public var pixels: [Float] // count = width * height * 4

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [Float](repeating: 0, count: width * height * 4)
    }

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * 4, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Multiplies RGB by a gain, leaving alpha (coverage) untouched.
    public mutating func scaleRGB(by gain: Float) {
        let w = width
        pixels.withUnsafeMutableBufferPointer { px in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                var pi = y * w * 4
                for _ in 0..<w {
                    px[pi] *= gain
                    px[pi + 1] *= gain
                    px[pi + 2] *= gain
                    pi += 4
                }
            }
        }
    }

    /// Rec. 709 luma as a single-channel plane.
    public func luminancePlane() -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    var i = y * width * 4
                    for x in 0..<width {
                        dst[y * width + x] = 0.2126 * src[i] + 0.7152 * src[i + 1] + 0.0722 * src[i + 2]
                        i += 4
                    }
                }
            }
        }
        return out
    }

    /// Fast nearest-neighbor thumbnail, for progress previews.
    public func downsampledNearest(maxSide: Int) -> ImageBuffer {
        let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
        guard scale < 1 else { return self }
        let pw = max(1, Int(Double(width) * scale))
        let ph = max(1, Int(Double(height) * scale))
        var out = ImageBuffer(width: pw, height: ph)
        pixels.withUnsafeBufferPointer { src in
            out.pixels.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: ph) { y in
                    let sy = min(y * height / ph, height - 1)
                    for x in 0..<pw {
                        let sx = min(x * width / pw, width - 1)
                        let si = (sy * width + sx) * 4
                        let di = (y * pw + x) * 4
                        dst[di] = src[si]
                        dst[di + 1] = src[si + 1]
                        dst[di + 2] = src[si + 2]
                        dst[di + 3] = src[si + 3]
                    }
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
