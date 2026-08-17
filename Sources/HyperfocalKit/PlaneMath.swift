import Foundation

/// Small shared math helpers for grid/plane passes (PMax debloom gates, the
/// export black-point). The rim despill is deliberately absent — measurements
/// showed its subject/glow discriminator fails on translucent specimens
/// (cell-sized dark blotches) while its halo benefit on the stacks it was
/// tuned for is marginal; don't resurrect it without solving both.
public enum PlaneMath {

    /// Hermite smoothstep, clamped. 0 at/below `e0`, 1 at/above `e1`.
    public static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        guard e1 > e0 else { return x < e0 ? 0 : 1 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Approximate percentile via a strided subsample (matches
    /// `DMapFusion.percentile95`'s cheap-and-robust style).
    public static func percentileLow(_ plane: [Float], _ fraction: Float) -> Float {
        guard !plane.isEmpty else { return 0 }
        var sample = [Float]()
        sample.reserveCapacity(plane.count / 97 + 1)
        var i = 0
        while i < plane.count { sample.append(plane[i]); i += 97 }
        sample.sort()
        let f = min(max(fraction, 0), 1)
        return sample[min(Int(Float(sample.count) * f), sample.count - 1)]
    }
}
