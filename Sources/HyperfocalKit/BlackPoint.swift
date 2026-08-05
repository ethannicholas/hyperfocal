import Foundation

/// Export black-point: the uniform backdrop *veil* — real ambient light on the
/// background, present ±3% in every source frame — is not a fusion artifact.
/// Commercial stackers crush it with a flat subtraction; this does the same,
/// auto-measured per channel.
///
/// The veil is additive light and the working buffer is sRGB-encoded
/// (display-referred), so the pass operates in LINEAR light: it linearizes,
/// subtracts the per-channel veil, clips at zero, and re-encodes. (An
/// encoded-space subtraction rings at the silhouette; don't.)
public enum BlackPoint {

    /// Auto-measures the per-channel veil (a low percentile of each channel,
    /// where the large dark background dominates) and subtracts `intensity`×
    /// that level in linear light. `intensity` 0…1 (0 = no-op).
    ///
    /// **Self-gating**: the subtraction assumes the low percentile IS a dark
    /// backdrop under a thin veil, and on scenes without one that assumption
    /// fails destructively — on a light-background stack the percentile lands
    /// in deep *subject* shadow (measured 24.5% encoded on the white-marble
    /// sample-stack, and 49% on the synthetic plane scene, vs 0.4–0.6% for the
    /// real veils on the black-backdrop reference stacks — a 40× separation).
    /// So the pass gates itself on the measured level: full strength while the
    /// max channel is near-black, fading to a no-op above a few percent. A
    /// deliberately gray backdrop is thereby left alone — only a background
    /// that is already almost black is crushed the rest of the way.
    ///
    /// Env: `HYPERFOCAL_BLACK_POINT_PCT` (default 0.5) — the per-channel
    /// percentile taken as the veil; lower is more conservative (leaves more
    /// background), higher crushes harder and risks clipping dark subject
    /// shadow. `HYPERFOCAL_BLACK_POINT_GATE_LO` / `_GATE_HI` (default
    /// 0.02 / 0.06) — the self-gate band over the max-channel encoded veil.
    public static func applyExport(to image: inout ImageBuffer, intensity: Float,
                                   log: ((String) -> Void)? = nil) {
        var amount = min(max(intensity, 0), 1)
        guard amount > 0 else { return }
        let env = ProcessInfo.processInfo.environment
        let pct = min(max(Float(env["HYPERFOCAL_BLACK_POINT_PCT"] ?? "") ?? 0.5, 0), 1)
        let veil = measureVeil(image, pct: pct)   // linear, per channel
        let gateLo = Float(env["HYPERFOCAL_BLACK_POINT_GATE_LO"] ?? "") ?? 0.02
        let gateHi = max(Float(env["HYPERFOCAL_BLACK_POINT_GATE_HI"] ?? "") ?? 0.06,
                         gateLo + 1e-6)
        let veilEnc = max(ToneCurve.srgbEncode(veil.x),
                          ToneCurve.srgbEncode(veil.y), ToneCurve.srgbEncode(veil.z))
        let gate = 1 - PlaneMath.smoothstep(gateLo, gateHi, veilEnc)
        guard gate > 0.001 else {
            log?(String(format: "black point: skipped — measured floor %.1f%% encoded "
                        + "is not a dark-backdrop veil", veilEnc * 100))
            return
        }
        amount *= gate
        let sub = SIMD3<Float>(veil.x * amount, veil.y * amount, veil.z * amount)
        let w = image.width
        image.pixels.withUnsafeMutableBufferPointer { pxBuf in
            let px = pxBuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: image.height) { y in
                var pi = y * w * 4
                for _ in 0..<w {
                    var p = hfLoadRGBA(px, pi)
                    for c in 0..<3 {
                        let lin = ToneCurve.srgbLinearize(max(p[c], 0))
                        p[c] = ToneCurve.srgbEncode(max(lin - sub[c], 0))
                    }
                    hfStoreRGBA(px, pi, p)
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
        image.pixels.withUnsafeBufferPointer { pxBuf in
            let px = pxBuf.baseAddress!
            var i = 0
            let pixelCount = pxBuf.count / 4
            while i < pixelCount {
                let p = hfLoadRGBA(px, i * 4)
                r.append(ToneCurve.srgbLinearize(max(p.x, 0)))
                g.append(ToneCurve.srgbLinearize(max(p.y, 0)))
                b.append(ToneCurve.srgbLinearize(max(p.z, 0)))
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
