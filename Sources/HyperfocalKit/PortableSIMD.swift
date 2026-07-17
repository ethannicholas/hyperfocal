#if canImport(simd)
import simd
#endif

// Pure-Swift stand-ins for the small slice of Apple's `simd` module the
// engine uses, so HyperfocalKit + hyperfocal-cli build on Windows/Linux where
// `simd` is unavailable (Docs/cross-platform-plan.md, Phase 1). `SIMD2/3/4`
// themselves are Swift stdlib and portable; only the 3×3 matrix type and a
// handful of free functions need shimming.
//
// `Float3x3` is compiled on EVERY platform (not just non-Apple) so the probe
// can verify it against Apple's `simd_float3x3` bit-closely on macOS — that
// cross-check is the shim's correctness gate (retouch-probe: "portable simd").
// The `simd_*` aliases/functions below bind to it only where `simd` is
// absent; on Apple platforms the engine keeps using the real `simd`.

/// A 3×3 `Float` matrix matching `simd_float3x3`'s semantics for the
/// operations the engine uses: `init(rows:)` builds the matrix whose i-th row
/// is `rows[i]`, `M * v` is the row·vector product, `A * B` is the standard
/// matrix product, and — matching simd's column-major convention —
/// `subscript(i)` returns **column** i (so `M[i][j]` is row j, column i).
/// Storage is row-major and internal; `.columns` is deliberately absent
/// because nothing reads it, which frees the layout from simd's.
public struct Float3x3: Equatable {
    public var r0: SIMD3<Float>
    public var r1: SIMD3<Float>
    public var r2: SIMD3<Float>

    public init(rows: [SIMD3<Float>]) {
        precondition(rows.count == 3, "Float3x3 needs exactly 3 rows")
        r0 = rows[0]; r1 = rows[1]; r2 = rows[2]
    }

    public init(_ r0: SIMD3<Float>, _ r1: SIMD3<Float>, _ r2: SIMD3<Float>) {
        self.r0 = r0; self.r1 = r1; self.r2 = r2
    }

    public static let identity = Float3x3(
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, 1, 0),
        SIMD3<Float>(0, 0, 1))

    /// Column i (simd is column-major, so `matrix[i]` yields a column).
    public subscript(_ column: Int) -> SIMD3<Float> {
        SIMD3<Float>(r0[column], r1[column], r2[column])
    }

    private static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    public static func * (m: Float3x3, v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(dot(m.r0, v), dot(m.r1, v), dot(m.r2, v))
    }

    public static func * (a: Float3x3, b: Float3x3) -> Float3x3 {
        let c0 = b[0], c1 = b[1], c2 = b[2]
        return Float3x3(
            SIMD3<Float>(dot(a.r0, c0), dot(a.r0, c1), dot(a.r0, c2)),
            SIMD3<Float>(dot(a.r1, c0), dot(a.r1, c1), dot(a.r1, c2)),
            SIMD3<Float>(dot(a.r2, c0), dot(a.r2, c1), dot(a.r2, c2)))
    }

    /// Standard 3×3 inverse via the adjugate over the determinant.
    public var inverse: Float3x3 {
        let a = r0.x, b = r0.y, c = r0.z
        let d = r1.x, e = r1.y, f = r1.z
        let g = r2.x, h = r2.y, i = r2.z
        let A = e * i - f * h
        let B = -(d * i - f * g)
        let C = d * h - e * g
        let invDet = 1 / (a * A + b * B + c * C)
        return Float3x3(
            SIMD3<Float>(A * invDet,
                         -(b * i - c * h) * invDet,
                         (b * f - c * e) * invDet),
            SIMD3<Float>(B * invDet,
                         (a * i - c * g) * invDet,
                         -(a * f - c * d) * invDet),
            SIMD3<Float>(C * invDet,
                         -(a * h - b * g) * invDet,
                         (a * e - b * d) * invDet))
    }
}

#if !canImport(simd)

public typealias simd_float2 = SIMD2<Float>
public typealias simd_float3 = SIMD3<Float>
public typealias simd_float3x3 = Float3x3
public typealias matrix_float3x3 = Float3x3
public let matrix_identity_float3x3 = Float3x3.identity

public func simd_length(_ v: SIMD2<Float>) -> Float {
    (v.x * v.x + v.y * v.y).squareRoot()
}

public func simd_min<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable {
    a.replacing(with: b, where: b .< a)
}

public func simd_max<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable {
    a.replacing(with: b, where: b .> a)
}

public func simd_clamp<V: SIMD>(_ x: V, _ lowerBound: V, _ upperBound: V) -> V
where V.Scalar: Comparable {
    simd_min(simd_max(x, lowerBound), upperBound)
}

#endif
