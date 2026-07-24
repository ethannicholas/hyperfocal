import Foundation

/// Export black-point: the uniform backdrop *veil* — real ambient light on the
/// background, present ±3% in every source frame — is not a fusion artifact, so
/// the rim despill leaves it. Helicon crushes it with a flat subtraction; this
/// does the same, auto-measured per channel. It is independent of the despill
/// (either can run alone), but together they take the background to Helicon-black
/// while the despill removes the structured glow.
///
/// Display-referred output only. Linear DNG deliberately carries unmodified data
/// (that is the format's whole point — see `ToneCurve` header); the raw-workflow
/// equivalent is writing the DNG BlackLevel tag so a developer subtracts without
/// touching pixels — a separate, still-to-build path.
///
/// Like the despill, this operates in LINEAR light (the veil is additive light;
/// the working buffer is sRGB-encoded — see `Despill`), so it linearizes,
/// subtracts the per-channel veil, clips at zero, and re-encodes.
public enum BlackPoint {

    /// Auto-measures the per-channel veil (a low percentile of each channel,
    /// where the large dark background dominates) and subtracts `intensity`×
    /// that level in linear light. `intensity` 0…1 (0 = no-op).
    ///
    /// Env: `HYPERFOCAL_BLACK_POINT_PCT` (default 0.5) — the per-channel
    /// percentile taken as the veil; lower is more conservative (leaves more
    /// background), higher crushes harder and risks clipping dark subject shadow.
    public static func applyExport(to image: inout ImageBuffer, intensity: Float,
                                   log: ((String) -> Void)? = nil) {
        let amount = min(max(intensity, 0), 1)
        guard amount > 0 else { return }
        let env = ProcessInfo.processInfo.environment
        let pct = min(max(Float(env["HYPERFOCAL_BLACK_POINT_PCT"] ?? "") ?? 0.5, 0), 1)
        let veil = measureVeil(image, pct: pct)   // linear, per channel
        let sub = SIMD3<Float>(veil.x * amount, veil.y * amount, veil.z * amount)
        let w = image.width
        image.pixels.withUnsafeMutableBufferPointer { px in
            DispatchQueue.concurrentPerform(iterations: image.height) { y in
                var pi = y * w * 4
                for _ in 0..<w {
                    for c in 0..<3 {
                        let lin = ToneCurve.srgbLinearize(max(px[pi + c], 0))
                        px[pi + c] = ToneCurve.srgbEncode(max(lin - sub[c], 0))
                    }
                    pi += 4
                }
            }
        }
        func enc(_ l: Float) -> Int { Int(ToneCurve.srgbEncode(l) * 65535 + 0.5) }
        log?(String(format: "black point: veil (enc) R%d G%d B%d, intensity %.2f, pct %.2f",
                    enc(veil.x), enc(veil.y), enc(veil.z), amount, pct))
    }

    /// Per-channel veil level in linear light: the `pct` percentile of each
    /// channel over a strided subsample (the background dominates the low end).
    static func measureVeil(_ image: ImageBuffer, pct: Float) -> SIMD3<Float> {
        var r = [Float](), g = [Float](), b = [Float]()
        let stride = max(1, image.pixels.count / 4 / 300_000)   // ~300k samples
        r.reserveCapacity(image.pixels.count / 4 / stride + 1)
        g.reserveCapacity(r.capacity); b.reserveCapacity(r.capacity)
        image.pixels.withUnsafeBufferPointer { px in
            var i = 0
            let pixelCount = px.count / 4
            while i < pixelCount {
                let pi = i * 4
                r.append(ToneCurve.srgbLinearize(max(px[pi], 0)))
                g.append(ToneCurve.srgbLinearize(max(px[pi + 1], 0)))
                b.append(ToneCurve.srgbLinearize(max(px[pi + 2], 0)))
                i += stride
            }
        }
        func percentile(_ a: inout [Float]) -> Float {
            guard !a.isEmpty else { return 0 }
            a.sort()
            return a[min(Int(Float(a.count) * pct), a.count - 1)]
        }
        return SIMD3(percentile(&r), percentile(&g), percentile(&b))
    }
}
