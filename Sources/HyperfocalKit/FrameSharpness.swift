import Foundation

/// Per-frame raw sharpness energy at reduced resolution, retained from the
/// fusion's depth pass. This is the measurement *before* regularization: exactly
/// what a retouch auto-pick needs, since retouching happens where the
/// regularized decision was wrong.
///
/// Storage is 16-bit fixed point against a global-max scale — the exact
/// quantization the project file applies, so a fresh fuse and a reopened
/// project retain identical values. The Float planes it is built from are
/// fusion-pass transients; retaining them as Float would double this
/// structure's resident cost (573 MB vs 286 MB on a 250-frame 36.6 MP stack)
/// for precision the format never preserves.
public struct FrameSharpness {
    public let fullWidth: Int
    public let fullHeight: Int
    /// Downsample factor of the stored planes relative to full resolution.
    public let factor: Int
    /// One quantized plane per frame, row-major,
    /// ceil(fullW/factor) × ceil(fullH/factor). value = Float(sample) / 65535 · scale.
    public let samples: [[UInt16]]
    /// Global maximum energy across all planes — the dequantization scale
    /// (and the value the project manifest records as `sharpnessScale`).
    public let scale: Float

    public var width: Int { (fullWidth + factor - 1) / factor }
    public var height: Int { (fullHeight + factor - 1) / factor }
    public var planeCount: Int { samples.count }
    public var cellsPerPlane: Int { samples.first?.count ?? 0 }

    /// Quantizing initializer for the fusion passes, which measure in Float.
    public init(fullWidth: Int, fullHeight: Int, factor: Int, planes: [[Float]]) {
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.factor = factor
        let peak = max(planes.reduce(Float(0)) { max($0, $1.max() ?? 0) }, 1e-9)
        self.scale = peak
        let q = 65535 / peak
        self.samples = planes.map { plane in
            var out = [UInt16](repeating: 0, count: plane.count)
            plane.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<src.count {
                        dst[i] = UInt16(min(max(src[i] * q, 0), 65535) + 0.5)
                    }
                }
            }
            return out
        }
    }

    /// Raw initializer for project restore — the file stores exactly these
    /// samples and this scale, so a reopen is a straight copy.
    public init(fullWidth: Int, fullHeight: Int, factor: Int,
                samples: [[UInt16]], scale: Float) {
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.factor = factor
        self.samples = samples
        self.scale = scale
    }

    /// Dequantized planes for consumers that need real energies over the
    /// whole grid (the noise-floor preview's regularizer). Materializes the
    /// full Float copy — transient by design; don't retain the result.
    public func floatPlanes() -> [[Float]] {
        let s = scale / 65535
        return samples.map { plane in
            var out = [Float](repeating: 0, count: plane.count)
            plane.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<src.count { dst[i] = Float(src[i]) * s }
                }
            }
            return out
        }
    }

    /// Per-pixel winner across the retained planes: the strongest energy and
    /// its frame index — the depth regularizer's inputs, recovered from the
    /// retained measurement. Comparison happens on the raw samples (the
    /// quantization is monotonic); energies dequantize on the way out.
    /// Parallel and optimized here in the engine; the app layer builds
    /// without optimization, where this scan would take seconds on deep
    /// stacks.
    public func winnerPlanes() -> (energy: [Float], index: [Float]) {
        let count = cellsPerPlane
        var winner = [UInt16](repeating: 0, count: count)
        var index = [Float](repeating: 0, count: count)
        winner.withUnsafeMutableBufferPointer { wp in
            index.withUnsafeMutableBufferPointer { ip in
                for (fi, plane) in samples.enumerated() {
                    let f = Float(fi)
                    plane.withUnsafeBufferPointer { pp in
                        DispatchQueue.concurrentPerform(iterations: 16) { chunk in
                            let lo = count * chunk / 16
                            let hi = count * (chunk + 1) / 16
                            for i in lo..<hi where pp[i] > wp[i] {
                                wp[i] = pp[i]
                                ip[i] = f
                            }
                        }
                    }
                }
            }
        }
        let s = scale / 65535
        var energy = [Float](repeating: 0, count: count)
        winner.withUnsafeBufferPointer { wp in
            energy.withUnsafeMutableBufferPointer { ep in
                for i in 0..<count { ep[i] = Float(wp[i]) * s }
            }
        }
        return (energy, index)
    }

    /// Total sharpness energy of each frame within a disk (full-resolution
    /// center/radius). Returns one score per frame; instant — no pixel decodes.
    public func regionScores(centerX: Double, centerY: Double, radius: Double) -> [Float] {
        let f = Double(factor)
        let cx = centerX / f, cy = centerY / f
        let r = max(1.0, radius / f)
        let x0 = max(0, Int(cx - r)), x1 = min(width - 1, Int(cx + r))
        let y0 = max(0, Int(cy - r)), y1 = min(height - 1, Int(cy + r))
        guard x0 <= x1, y0 <= y1 else { return samples.map { _ in 0 } }

        // Disk sample offsets are identical for every frame — build once.
        var offsets = [Int]()
        for y in y0...y1 {
            let dy = Double(y) + 0.5 - cy
            for x in x0...x1 {
                let dx = Double(x) + 0.5 - cx
                if dx * dx + dy * dy <= r * r {
                    offsets.append(y * width + x)
                }
            }
        }
        guard !offsets.isEmpty else { return samples.map { _ in 0 } }

        let s = scale / 65535
        return samples.map { plane in
            plane.withUnsafeBufferPointer { p in
                var acc: Float = 0
                for offset in offsets { acc += Float(p[offset]) }
                return acc * s
            }
        }
    }
}
