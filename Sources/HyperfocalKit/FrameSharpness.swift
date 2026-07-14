import Foundation

/// Per-frame raw sharpness energy at reduced resolution, retained from the
/// fusion's depth pass. This is the measurement *before* regularization: exactly
/// what a retouch auto-pick needs, since retouching happens where the
/// regularized decision was wrong.
public struct FrameSharpness {
    public let fullWidth: Int
    public let fullHeight: Int
    /// Downsample factor of the stored planes relative to full resolution.
    public let factor: Int
    /// One plane per frame, row-major, ceil(fullW/factor) × ceil(fullH/factor).
    public let planes: [[Float]]

    public var width: Int { (fullWidth + factor - 1) / factor }
    public var height: Int { (fullHeight + factor - 1) / factor }

    public init(fullWidth: Int, fullHeight: Int, factor: Int, planes: [[Float]]) {
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.factor = factor
        self.planes = planes
    }

    /// Per-pixel winner across the retained planes: the strongest energy and
    /// its frame index — the depth regularizer's inputs, recovered from the
    /// retained measurement. Parallel and optimized here in the engine; the
    /// app layer builds without optimization, where this scan would take
    /// seconds on deep stacks.
    public func winnerPlanes() -> (energy: [Float], index: [Float]) {
        let count = planes.first?.count ?? 0
        var energy = [Float](repeating: 0, count: count)
        var index = [Float](repeating: 0, count: count)
        energy.withUnsafeMutableBufferPointer { ep in
            index.withUnsafeMutableBufferPointer { ip in
                for (fi, plane) in planes.enumerated() {
                    let f = Float(fi)
                    plane.withUnsafeBufferPointer { pp in
                        DispatchQueue.concurrentPerform(iterations: 16) { chunk in
                            let lo = count * chunk / 16
                            let hi = count * (chunk + 1) / 16
                            for i in lo..<hi where pp[i] > ep[i] {
                                ep[i] = pp[i]
                                ip[i] = f
                            }
                        }
                    }
                }
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
        guard x0 <= x1, y0 <= y1 else { return planes.map { _ in 0 } }

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
        guard !offsets.isEmpty else { return planes.map { _ in 0 } }

        return planes.map { plane in
            plane.withUnsafeBufferPointer { p in
                var acc: Float = 0
                for offset in offsets { acc += p[offset] }
                return acc
            }
        }
    }
}
