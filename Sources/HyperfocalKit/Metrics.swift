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
}
