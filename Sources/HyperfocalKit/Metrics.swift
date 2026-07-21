import Foundation

public enum Metrics {

    /// PSNR over RGB (alpha ignored), after cropping `margin` pixels from every edge
    /// to exclude warp borders.
    public static func psnr(_ a: ImageBuffer, _ b: ImageBuffer, margin: Int = 0) -> Float {
        precondition(a.width == b.width && a.height == b.height, "size mismatch")
        let ca = margin > 0 ? a.cropped(margin: margin) : a
        let cb = margin > 0 ? b.cropped(margin: margin) : b
        var sum: Double = 0
        var count = 0
        for i in stride(from: 0, to: ca.pixels.count, by: 4) {
            for c in 0..<3 {
                let d = Double(ca.pixels[i + c] - cb.pixels[i + c])
                sum += d * d
            }
            count += 3
        }
        let mse = sum / Double(count)
        guard mse > 0 else { return .infinity }
        return Float(10 * log10(1.0 / mse))
    }

    /// PSNR between images of different sizes: the smaller is a crop of the
    /// larger at an unknown offset (e.g. common-coverage cropped output vs
    /// full-size ground truth). Searches all placements on subsampled luma,
    /// then reports full PSNR at the best one.
    public static func psnrBestOffset(_ a: ImageBuffer, _ b: ImageBuffer,
                                      margin: Int = 0) -> (psnr: Float, dx: Int, dy: Int) {
        let (big, small) = a.width * a.height >= b.width * b.height ? (a, b) : (b, a)
        guard big.width >= small.width, big.height >= small.height else {
            return (-1, 0, 0)
        }
        let bigLuma = big.luminancePlane()
        let smallLuma = small.luminancePlane()
        let step = 4
        var best = (mse: Double.infinity, dx: 0, dy: 0)
        for dy in 0...(big.height - small.height) {
            for dx in 0...(big.width - small.width) {
                var sum = 0.0
                var count = 0
                var y = margin
                while y < small.height - margin {
                    var x = margin
                    while x < small.width - margin {
                        let d = Double(smallLuma[y * small.width + x]
                            - bigLuma[(y + dy) * big.width + (x + dx)])
                        sum += d * d
                        count += 1
                        x += step
                    }
                    y += step
                }
                let mse = count > 0 ? sum / Double(count) : .infinity
                if mse < best.mse { best = (mse, dx, dy) }
            }
        }
        let cropped = big.cropped(x: best.dx, y: best.dy,
                                  width: small.width, height: small.height)
        return (psnr(small, cropped, margin: margin), best.dx, best.dy)
    }

    /// PSNR between two images neither of which contains the other — e.g. two
    /// common-coverage crops of the same scene whose canvases differ by a few
    /// pixels in each dimension (registration A/Bs produce exactly this).
    /// Finds the offset of `b` relative to `a` (|shift| ≤ `maxShift`) that
    /// best aligns their luma (coarse step-16 pass, then a ±2 refine), and
    /// reports RGB PSNR over the aligned intersection.
    public static func psnrIntersection(_ a: ImageBuffer, _ b: ImageBuffer,
                                        maxShift: Int = 32, margin: Int = 0)
        -> (psnr: Float, dx: Int, dy: Int) {
        let aL = a.luminancePlane()
        let bL = b.luminancePlane()

        // Mean-squared luma difference over the intersection at offset
        // (dx, dy) — b pixel (x, y) against a pixel (x + dx, y + dy).
        func lumaMSE(_ dx: Int, _ dy: Int, step: Int) -> Double {
            let x0 = max(0, -dx) + margin, x1 = min(b.width, a.width - dx) - margin
            let y0 = max(0, -dy) + margin, y1 = min(b.height, a.height - dy) - margin
            guard x1 - x0 > 64, y1 - y0 > 64 else { return .infinity }
            var sum = 0.0
            var count = 0
            var y = y0
            while y < y1 {
                var x = x0
                while x < x1 {
                    let d = Double(bL[y * b.width + x] - aL[(y + dy) * a.width + (x + dx)])
                    sum += d * d
                    count += 1
                    x += step
                }
                y += step
            }
            return count > 0 ? sum / Double(count) : .infinity
        }

        var best = (mse: Double.infinity, dx: 0, dy: 0)
        for dy in stride(from: -maxShift, through: maxShift, by: 1) {
            for dx in stride(from: -maxShift, through: maxShift, by: 1) {
                let mse = lumaMSE(dx, dy, step: 16)
                if mse < best.mse { best = (mse, dx, dy) }
            }
        }
        // Refine at a denser sampling; coarse and dense MSEs aren't
        // comparable, so the refine pass re-ranks its own candidates only.
        var refined = (mse: Double.infinity, dx: best.dx, dy: best.dy)
        for dy in (best.dy - 2)...(best.dy + 2) {
            for dx in (best.dx - 2)...(best.dx + 2) {
                let mse = lumaMSE(dx, dy, step: 4)
                if mse < refined.mse { refined = (mse, dx, dy) }
            }
        }
        let (dx, dy) = (refined.dx, refined.dy)
        let x0 = max(0, -dx), x1 = min(b.width, a.width - dx)
        let y0 = max(0, -dy), y1 = min(b.height, a.height - dy)
        let ca = a.cropped(x: x0 + dx, y: y0 + dy, width: x1 - x0, height: y1 - y0)
        let cb = b.cropped(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return (psnr(ca, cb, margin: margin), dx, dy)
    }
}
