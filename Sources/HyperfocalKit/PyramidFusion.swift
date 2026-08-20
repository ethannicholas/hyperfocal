import Foundation
import Dispatch
#if canImport(simd)
import simd
#endif

/// Per-frame alignment for a pyramid fusion whose `frame` closure returns
/// *unwarped* frames. The GPU path applies these homographies on-device
/// (`warp_lanczos3`) — on the CPU the Lanczos warp is ~55% of GPU-fusion
/// wall-clock on a 50×45 MP stack; the CPU path applies the identical
/// `Warp.apply` after decode, so output doesn't depend on the engine.
public struct PyramidWarp {
    public let transforms: [simd_float3x3]  // frame → reference, per frame
    /// Output canvas (common-coverage crop); nil = the frame's own size.
    public let outputWidth: Int?
    public let outputHeight: Int?

    public init(transforms: [simd_float3x3],
                outputWidth: Int? = nil, outputHeight: Int? = nil) {
        self.transforms = transforms
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    /// CPU application — must stay behavior-identical to `StackSource.frame`.
    func apply(_ img: ImageBuffer, at index: Int) -> ImageBuffer {
        let t = transforms[index]
        let w = outputWidth ?? img.width
        let h = outputHeight ?? img.height
        if t == matrix_identity_float3x3 && w == img.width && h == img.height {
            return img
        }
        return Warp.apply(img, outputToSource: t.inverse, outWidth: w, outHeight: h)
    }
}

/// Laplacian-pyramid fusion (the "PMax" family): decompose each aligned frame,
/// keep the highest-energy coefficient at every pyramid position, collapse.
/// Handles overlapping structures at different depths better than depth-map
/// fusion, at the cost of some contrast/noise amplification.
public enum PyramidFusion {

    static let downKernel: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }

    /// Full-res footprint of one source-envelope cell (see the envelope
    /// clamp in `fuse`). Regional on purpose: per-pixel energy policing
    /// would flatten noise pixel by pixel — the deadening failure — while a
    /// 32 px cell only asks that a neighborhood carry no more focus energy
    /// than the liveliest single frame does there.
    static let envCell = 32
    /// Octaves the output clamp bounds. One, deliberately: the octave sweep
    /// was measured, and every scale added past the finest trades
    /// fabrication for deadening (defocused-foliage stack, envelope tiles
    /// high/low: 1 octave 23/0, 3 octaves 23/10 — and pre-collapse
    /// per-level bounding, the extreme of the same idea, 24/37). The
    /// engine-side band measure and an output-quality measure only track
    /// each other loosely per region, so scalar energy accounting beyond
    /// the finest octave corrects noise it cannot see the structure of;
    /// the residual structured fabrication is regional-commitment
    /// territory (the hybrid-background renderer), not a clamping problem.
    static let envClampOctaves = 1

    /// Debloom membership for each gated band level: where the focus-gated
    /// tracks (A/B) are trusted over the plain max-energy selection (track C).
    /// **Shared by the CPU and GPU merges** — the gate is thresholds, a
    /// morphology pass and a reduction, and duplicating that arithmetic per
    /// backend is exactly how the paths drift apart, so every backend calls
    /// this and only the buffer plumbing differs. Returns one mask per level
    /// (empty for ungated levels), plus stats for logging.
    ///
    /// The membership is the union of two independent proofs that a pixel is
    /// background that can be bloomed into (never a bright in-focus feature —
    /// the thing debloom must not dim):
    ///
    /// 1. **Near-black** — its darkest rendition is near black, so nothing
    ///    bright lives there. `1 - smoothstep(lo, hi, lumMin0)`. This is the
    ///    only term that engages on a dark backdrop, and the only one that
    ///    reaches *inside* the subject (dark crevices beside bright lettering).
    /// 2. **Open background** — it belongs to a connected smooth field that
    ///    (a) reaches the frame border without crossing sharp structure,
    ///    (b) never comes into focus anywhere in the sweep, and (c) is
    ///    contaminated *additively* where it is contaminated at all. This is
    ///    what engages on a bright out-of-focus backdrop, where absolute
    ///    luminance says "feature". All three clauses are load-bearing,
    ///    measured on the corpus:
    ///    - Enclosure (morphological close of the sharp mask + border
    ///      connectivity) is what protects bright feature *interiors*: half
    ///      the train stack's top-1% highlights have no fine detail in any
    ///      frame (smooth painted surfaces), and an unenclosed focus test
    ///      dims them 9%. The close radius stays small (gaps ≤ ~2·8 px at
    ///      2562 px) — a large radius fills the concave backdrop margin
    ///      around a convex silhouette, switching the fix off in exactly the
    ///      band it exists for. Full enclosure is what fills wide interiors.
    ///    - The never-focuses clause (per-component median of focus
    ///      max/min over frames) is what protects an in-focus *background*:
    ///      the white-marble stack's substrate carries real texture whose
    ///      absolute energy overlaps a bright backdrop's noise floor, so no
    ///      threshold on energy alone separates them — but its energy MOVES
    ///      with the sweep (median ratio ≈ 5000 vs ≈ 2 on the never-focused
    ///      backdrop). Judged per component because the ratio is locally
    ///      contaminated near silhouettes (edge-blur leakage), which a
    ///      component median cannot be swayed by. The cutoff scales with
    ///      log2(frame count): max/min of pure noise grows with N (measured
    ///      1.9 at N=6, 8.3 at N=63 for never-focused backdrops).
    ///
    /// In open-background cells, track B is additionally *sign-aware*: the
    /// merge chooses per cell between the darkest and the brightest
    /// unfocused rendition — whichever luminance lands closer to the
    /// **clean-field plane** this function reconstructs (push-pull from the
    /// component's uncontaminated pixels). Keep-darkest alone is only "least
    /// contaminated" when the contamination is additive; where a *dark*
    /// subject spreads into a brighter background the sign inverts, and
    /// keep-darkest paints the band beside the silhouette *below the darkest
    /// source frame's own rendition* (measured 0.759 vs a frame floor of
    /// 0.785 on a dark-specimens-on-white stack; the commercial reference
    /// never goes below the floor). The clean rendition is always the extreme
    /// on the uncontaminated side, so choosing between the two extremes
    /// against the clean field is exact wherever contamination is one-sided
    /// per cell. The choice is scoped to open-background cells (near-black
    /// crevices inside a subject keep plain darkest — the clean field is
    /// extrapolated there and must not flip them toward bright).
    ///
    /// Env: `HYPERFOCAL_PMAX_NEARBLACK_LO` / `_HI` (default 0.15 / 0.35, as a
    /// fraction of `_PCT`, default the 99th percentile of the min-luminance);
    /// `HYPERFOCAL_PMAX_BG_ALPHA` (sharp threshold as a fraction of the focus
    /// max's 99th percentile, default 0.15), `_BG_CLOSE` (close radius as a
    /// fraction of the short side, default 0.0031), `_BG_RATIO` (override the
    /// never-focuses cutoff); `_BG_OFF` disables the open-background term
    /// (restoring the dark-backdrop-only gate), `_NEARBLACK_OFF` the whole
    /// membership (ungated merge, all-ones masks).
    static func debloomMasks(lumMin0: [Float], lumMax0: [Float],
                             focusMax0: [Float], focusMin0: [Float],
                             frameCount: Int, width: Int, height: Int,
                             sizes: [(w: Int, h: Int)], levels: Int,
                             darkCoarse: Int,
                             nearBlackVeto: [Float]? = nil,
                             env: [String: String] = ProcessInfo.processInfo.environment)
        -> (masks: [[Float]], bgMasks: [[Float]], clean: [[Float]],
            scale: Float, mean: Float, bgFraction: Float) {
        let off = env["HYPERFOCAL_PMAX_NEARBLACK_OFF"] != nil
        let lo0 = Float(env["HYPERFOCAL_PMAX_NEARBLACK_LO"] ?? "") ?? 0.15
        let hi0 = max(Float(env["HYPERFOCAL_PMAX_NEARBLACK_HI"] ?? "") ?? 0.35, lo0 + 1e-6)
        let pct = Float(env["HYPERFOCAL_PMAX_NEARBLACK_PCT"] ?? "") ?? 0.99

        // Scale reference: a HIGH percentile, not p95. p95 assumes the bright
        // content is a large minority of the frame; a specimen against a dark
        // backdrop can be 2-3% of pixels, so p95 lands inside the background
        // (measured 0.058 on Azurite against a p99 of 0.418) and drags the
        // thresholds onto the physical rim tail — gating debloom off in exactly
        // the band it is needed.
        let scale = max(PlaneMath.percentileLow(lumMin0, pct), 1e-6)
        let lo = lo0 * scale, hi = hi0 * scale
        var m0 = [Float](repeating: 1, count: lumMin0.count)
        var bg0: [Float] = []
        var cleanGrid: (plane: [Float], gw: Int, gh: Int)? = nil
        var bgFraction: Float = 0
        if !off {
            for i in m0.indices { m0[i] = 1 - PlaneMath.smoothstep(lo, hi, lumMin0[i]) }
            // Texture veto (see `nearBlackTextureVeto`): where the darkest
            // rendition provably isn't the true background — live defocused
            // texture — the cell leaves the membership and falls to the
            // plain track, which the envelope clamp bounds.
            if let veto = nearBlackVeto, veto.count == m0.count {
                for i in m0.indices where veto[i] > 0 { m0[i] *= 1 - veto[i] }
            }
            if env["HYPERFOCAL_PMAX_BG_OFF"] == nil,
               let open = openBackground(focusMax0: focusMax0, focusMin0: focusMin0,
                                         lumMin0: lumMin0, lumMax0: lumMax0,
                                         frameCount: frameCount,
                                         width: width, height: height, env: env) {
                bg0 = [Float](repeating: 0, count: m0.count)
                var n = 0
                for i in m0.indices where open.bg[i] {
                    // bg0 drives the open-background track choice; keep it off
                    // where the near-black membership already claims the pixel
                    // so every shipped dark-backdrop behavior stays verbatim.
                    if m0[i] < 0.5 { bg0[i] = 1 }
                    m0[i] = 1
                    n += 1
                }
                bgFraction = Float(n) / Float(max(m0.count, 1))
                cleanGrid = (open.cleanGrid, open.gw, open.gh)
            }
        }
        // Double accumulator: a Float sum saturates near 2^24, and a 45 MP
        // plane has ~3x that many elements — the logged mean pinned at ~0.39
        // regardless of the mask until this was widened.
        let mean = Float(m0.reduce(0.0) { $0 + Double($1) } / Double(max(m0.count, 1)))
        var masks = [[Float]](repeating: [], count: levels)
        var bgMasks = [[Float]](repeating: [], count: levels)
        var clean = [[Float]](repeating: [], count: levels)
        for l in 1..<levels where l >= levels - darkCoarse {
            masks[l] = off
                ? [Float](repeating: 1, count: sizes[l].w * sizes[l].h)
                : maxPool(m0, width: width, height: height, factor: 1 << l)
            if let cg = cleanGrid, !bg0.isEmpty {
                bgMasks[l] = maxPool(bg0, width: width, height: height, factor: 1 << l)
                clean[l] = Filters.resizePlaneBilinear(cg.plane, width: cg.gw, height: cg.gh,
                                                       toWidth: sizes[l].w,
                                                       toHeight: sizes[l].h)
            }
        }
        DMapFusion.dumpPlane(lumMin0, env: "HYPERFOCAL_DUMP_LUMMIN0")
        DMapFusion.dumpPlane(m0, env: "HYPERFOCAL_DUMP_NEARBLACK")
        if let cg = cleanGrid {
            DMapFusion.dumpPlane(cg.plane, env: "HYPERFOCAL_DUMP_PMAX_CLEAN")
        }
        return (masks, bgMasks, clean, scale, mean, bgFraction)
    }

    /// Never-focuses cutoff for per-pixel focus max/min ratios: max/min of
    /// pure noise grows with the frame count (extreme order statistics), so
    /// the cutoff does too — measured 1.9 at N=6, 8.3 at N=63 for
    /// never-focused backdrops. Shared by the open-background membership
    /// (component median vs the cut) and the envelope clamp (per-pixel ramp
    /// cut..3·cut): per-pixel ratio scales are stack-dependent (a small
    /// JPEG stack's sharpest pixels top out near 84 where a deep 45 MP
    /// sweep's run past 5000), so only an N-anchored cut transfers.
    static func neverFocusRatioCut(frameCount: Int) -> Float {
        min(max(3 * log2(Float(max(frameCount, 2))), 6), 32)
    }

    /// Near-black texture veto: cells where the near-black keep-darkest
    /// track's scene model — a FLAT dark backdrop whose darkest rendition is
    /// its true value — provably does not hold, because the cell's level-0
    /// band energy BREATHES with the sweep. Defocused live texture (bokeh
    /// mottle, out-of-focus foliage) breathes 4-30x across a sweep as the
    /// bokeh scale changes; a flat backdrop's noise floor breathes 1.2-1.5x
    /// (pooled over 32 px cells). Keep-darkest in breathing cells keeps the
    /// flattest rendition and deadens texture the scene really has (measured:
    /// a dark defocused garden at 0.31-0.68x the liveliest source frame,
    /// 33 of 60 background tiles outside the source envelope). Vetoed cells
    /// fall to the plain selection track, which the envelope clamp then
    /// bounds — the veto without the clamp would trade deadening for
    /// max-of-N fabrication, so they engage together (`smoothedSelection`).
    ///
    /// Same discipline as the clean-field flatness gate: a scene statistic
    /// decides where the mechanism's model holds, with a margin against
    /// engine drift, and everything else keeps shipped behavior — including
    /// every cell within one cell of sharp structure (the silhouette hug
    /// band is debloom's territory, and bloom itself breathes with the
    /// sweep, so the statistic cannot be trusted beside the subject).
    /// Returns nil when no cell qualifies. Full-res, bilinear across cell
    /// boundaries so the track handoff cannot band.
    static func nearBlackTextureVeto(envMax0: [Float], env0Min: [Float],
                                     focusMax0: [Float], frameCount: Int,
                                     width: Int, height: Int,
                                     env: [String: String]) -> [Float]? {
        let f = envCell
        let gw = (width + f - 1) / f, gh = (height + f - 1) / f
        guard envMax0.count == gw * gh, env0Min.count == gw * gh,
              focusMax0.count == width * height else { return nil }
        // The sweep-ratio cut scales with the frame count: a flat backdrop's
        // pooled noise ratio is an extreme-order statistic, measured to
        // follow 1 + c·√(2·ln N) (train N=6: p50 1.27; bug N=13: p50 1.34 —
        // both give c ≈ 0.15; per-cell p99 tails give c ≈ 0.37). The cut's
        // ramp sits above the noise tail and below the mottle population
        // (a defocused garden at N=11 measures p50 2.2).
        let spread = (2 * log(Float(max(frameCount, 2)))).squareRoot()
        let texLo = Float(env["HYPERFOCAL_PMAX_TEX_LO"] ?? "") ?? (1 + 0.25 * spread)
        let texHi = Float(env["HYPERFOCAL_PMAX_TEX_HI"] ?? "") ?? (1 + 0.45 * spread)
        let alpha = Float(env["HYPERFOCAL_PMAX_BG_ALPHA"] ?? "") ?? 0.15
        let t = alpha * max(PlaneMath.percentileLow(focusMax0, 0.99), 1e-6)
        let focusPool = maxPool(focusMax0, width: width, height: height, factor: f)
        // Energy floor on the MIN rendition: the ratio is meaningless where
        // the darkest rendition's energy is quantization junk (a
        // crushed-black JPEG backdrop pools band energy at f16 zero in some
        // frames, and noise/zero read as ratios of 10^5 on a stack whose
        // backdrop is genuinely flat — the corpus README's low-signal
        // lesson, hit here on the dark-backdrop acceptance stack). Real
        // breathing texture keeps its min well above zero (a mottled garden
        // at ratio 2-28 still has min ≥ ~4% of the population's upper end).
        // Judged against the eligible population's own p90, so it needs no
        // absolute unit.
        var eligible: [(i: Int, ratio: Float)] = []
        var maxes: [Float] = []
        for gy in 0..<gh {
            for gx in 0..<gw {
                var nearSharp = false
                for ny in max(gy - 1, 0)...min(gy + 1, gh - 1) {
                    for nx in max(gx - 1, 0)...min(gx + 1, gw - 1) {
                        if focusPool[ny * gw + nx] > t { nearSharp = true }
                    }
                }
                if nearSharp { continue }
                let i = gy * gw + gx
                // √ because the pooled energies are squared — the ratio and
                // its measured populations are in amplitude units.
                eligible.append((i, (envMax0[i] / max(env0Min[i], 1e-12)).squareRoot()))
                maxes.append(envMax0[i])
            }
        }
        guard !eligible.isEmpty else { return nil }
        let sortedMax = maxes.sorted()
        let q = { (a: [Float], p: Float) -> Float in
            a[min(Int(Float(a.count - 1) * p), a.count - 1)]
        }
        let floorLo = Float(env["HYPERFOCAL_PMAX_TEX_FLOOR"] ?? "") ?? 0.01
        let floor = floorLo * q(sortedMax, 0.9)
        // Visibility floor on the max rendition, in absolute units — the
        // engine's planes are [0, 1] luminance, so this is scene-anchored,
        // not a magic number: a cell whose LIVELIEST rendition pools less
        // squared band energy than a ~0.6/255 mean amplitude carries no
        // texture worth releasing keep-darkest for, and at those levels the
        // whole ratio population is quantization noise (measured: a black
        // backdrop's cells sit at p90 2.0e-6 with ratios into the hundreds;
        // real dark-garden mottle starts at p10 1.5e-5 — the cut is the
        // geometric middle of that gap).
        let visFloor = Float(env["HYPERFOCAL_PMAX_TEX_VIS"] ?? "") ?? 5.5e-6
        var grid = [Float](repeating: 0, count: gw * gh)
        var nVeto = 0
        for (i, ratio) in eligible
            where env0Min[i] > floor && envMax0[i] > visFloor {
            let w = PlaneMath.smoothstep(texLo, texHi, ratio)
            if w > 0 {
                grid[i] = w
                nVeto += 1
            }
        }
        if env["HYPERFOCAL_PMAX_ENV_DEBUG"] != nil {
            let s = eligible.map { $0.ratio }.sorted()
            FileHandle.standardError.write(String(
                format: "pmax tex veto: %d/%d cells, ratio p10 %.2f p50 %.2f "
                    + "p90 %.2f p99 %.2f (cut %.2f..%.2f), envMax0 p10 %.2e "
                    + "p50 %.2e p90 %.2e (floor %.2e)\n",
                nVeto, s.count, q(s, 0.1), q(s, 0.5), q(s, 0.9), q(s, 0.99),
                texLo, texHi, q(sortedMax, 0.1), q(sortedMax, 0.5),
                q(sortedMax, 0.9), floor).data(using: .utf8)!)
        }
        guard nVeto > 0 else { return nil }
        return Filters.resizePlaneBilinear(grid, width: gw, height: gh,
                                           toWidth: width, toHeight: height)
    }

    /// Source-envelope clamp, applied to the COLLAPSED image: in
    /// never-focused cells, the output may not carry more fine-scale band
    /// energy than the liveliest single source frame carries there.
    /// Max-of-N selection over N decorrelated defocused renditions is an
    /// extreme order statistic: it fabricates focus energy the sources
    /// don't contain (measured: defocused foliage at up to 2.9x the best
    /// registered frame, 43 of 77 background tiles above the envelope; the
    /// exact Burt expand made it worse by reconstructing the selected noise
    /// faithfully).
    ///
    /// Output space is load-bearing, not a convenience. A per-level clamp
    /// (each fused band bounded to the per-level liveliest frame) was built
    /// first and measurably fails BOTH ways: a mosaic's bands come from
    /// different frames and partially cancel on reconstruction, so
    /// per-level parity collapses to 0.5-0.8x in the output (37 of 77
    /// tiles pushed below the envelope's low side) — while spatial
    /// cherry-picking (each cell's bound is ITS liveliest frame) still
    /// summed above any single frame per tile (24 tiles left high). The
    /// collapsed image's own band, measured against the frames' same-
    /// operator bands, is the quantity the envelope constrains — coherence
    /// losses and cross-frame mosaicking are already inside it.
    ///
    /// Where a frame really resolves detail the clamp stands down; it only
    /// ever scales fine detail DOWN to the envelope, so it cannot deaden
    /// below the liveliest frame. Cell scales are bilinearly upsampled so
    /// the transition cannot band.
    ///
    /// "Never focused" is the per-pixel FOCUS SWEEP RATIO
    /// (focusMax0 / focusMin0) against the shared N-anchored cutoff
    /// (`neverFocusRatioCut`, ramp cut..3·cut), not an absolute energy
    /// test: energetic defocused foliage sits above any absolute cut (an
    /// absolute membership left 25 foliage tiles unclamped at up to 2.8x),
    /// while an in-focus low-energy background — real texture whose
    /// absolute energy overlaps a backdrop's noise floor, the regime the
    /// open-background never-focuses clause exists for — must NOT be
    /// clamped, because fused output legitimately exceeds the best single
    /// frame there (fusion gain, measured 1.3-1.8x on real subjects).
    /// Pixels whose min-focus is degenerate (zero-coverage warp borders
    /// render constant black, so the min is ~0 and the ratio reads as fake
    /// "focus") fall back to the absolute test.
    static func applyEnvelopeClamp(out: inout ImageBuffer,
                                   envMax: [[Float]], focusMax0: [Float],
                                   focusMin0: [Float], frameCount: Int,
                                   burtExpand: Bool, env: [String: String],
                                   log: ((String) -> Void)?) {
        let alpha = Float(env["HYPERFOCAL_PMAX_BG_ALPHA"] ?? "") ?? 0.15
        let t = alpha * max(PlaneMath.percentileLow(focusMax0, 0.99), 1e-6)
        let (w0, h0) = (out.width, out.height)
        guard focusMin0.count == focusMax0.count,
              focusMax0.count == w0 * h0 else { return }
        // The membership is judged per PIXEL and pooled as a fraction —
        // pooling max/min planes first compresses the ratio so badly that
        // subject cells read like background (measured: cell-mean ratios
        // p50 3.1 on a stack whose per-pixel focusing content runs into the
        // thousands, which engaged the clamp on 98% of cells, subject
        // included — and the subject's fusion gain, fused fine energy at
        // 1.3-1.8x any single frame, is legitimate and must never clamp).
        let rC = neverFocusRatioCut(frameCount: frameCount)
        let rLo = Float(env["HYPERFOCAL_PMAX_ENV_RLO"] ?? "") ?? rC
        let rHi = Float(env["HYPERFOCAL_PMAX_ENV_RHI"] ?? "") ?? 3 * rC
        let minValid = 1e-3 * t
        var wPix = [Float](repeating: 0, count: w0 * h0)
        wPix.withUnsafeMutableBufferPointer { wp in
            focusMax0.withUnsafeBufferPointer { fx in
                focusMin0.withUnsafeBufferPointer { fn in
                    DispatchQueue.concurrentPerform(iterations: h0) { y in
                        for i in (y * w0)..<((y + 1) * w0) {
                            wp[i] = fn[i] > minValid
                                ? 1 - PlaneMath.smoothstep(rLo, rHi, fx[i] / fn[i])
                                : 1 - PlaneMath.smoothstep(0.5 * t, t, fx[i])
                        }
                    }
                }
            }
        }
        // The output's own Gaussian pyramid over the clamped octaves, with
        // the pipeline's operators, so each octave band is the same measure
        // the per-frame envelope was pooled in. Bands are scaled per cell
        // and the pyramid reassembled — exact telescoping, so untouched
        // cells reconstruct bit-identically up to f16 storage.
        let octaves = min(envClampOctaves, envMax.count)
        var gauss: [ImageBuffer] = [out]
        for _ in 0..<octaves { gauss.append(downsample(gauss.last!)) }
        func expandTo(_ img: ImageBuffer, w: Int, h: Int) -> ImageBuffer {
            burtExpand ? expandBurt(img, toWidth: w, toHeight: h)
                       : Filters.resizeBilinear(img, toWidth: w, toHeight: h)
        }
        var totalClamped = 0
        var minScale: Float = 1
        var bands: [ImageBuffer] = []
        var scales: [[Float]] = []
        for l in 0..<octaves {
            let (wl, hl) = (gauss[l].width, gauss[l].height)
            let f = max(1, envCell >> l)
            let gw = (wl + f - 1) / f, gh = (hl + f - 1) / f
            guard envMax[l].count == gw * gh else { return }
            var band = expandTo(gauss[l + 1], w: wl, h: hl)
            band.pixels.withUnsafeMutableBufferPointer { bp in
                let b = bp.baseAddress!
                gauss[l].pixels.withUnsafeBufferPointer { gp in
                    let g = gp.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: hl) { y in
                        for i in stride(from: y * wl * 4, to: (y + 1) * wl * 4,
                                        by: 4) {
                            hfStoreRGBA(b, i, hfLoadRGBA(g, i) - hfLoadRGBA(b, i))
                        }
                    }
                }
            }
            let outPool = CPUWorkspace.poolBandEnergy(band.pixels, width: wl,
                                                      height: hl, factor: f)
            let nfCell = CPUWorkspace.poolScalarMean(wPix, width: w0, height: h0,
                                                     factor: f << l)
            let nfw = (w0 + (f << l) - 1) / (f << l)
            let nfh = (h0 + (f << l) - 1) / (f << l)
            var scale = [Float](repeating: 1, count: gw * gh)
            var clamped = 0
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let i = gy * gw + gx
                    let ni = min(gy, nfh - 1) * nfw + min(gx, nfw - 1)
                    // Sharpened at cell level: a mixed cell (subject edge)
                    // leans protected, a solidly never-focused cell engages.
                    let wNf = PlaneMath.smoothstep(0.3, 0.7, nfCell[ni])
                    guard wNf > 0 else { continue }
                    let fe = outPool[i], ee = envMax[l][i]
                    guard ee > 0, fe > ee, fe > 1e-12 else { continue }
                    // Energies are squared, so detail scales by √ratio; the
                    // ramp keeps cells just past the envelope continuous
                    // with untouched neighbours (full correction from 1.4x).
                    let r = fe / ee
                    let w = PlaneMath.smoothstep(1.0, 1.4, r) * wNf
                    guard w > 0 else { continue }
                    scale[i] = 1 + ((1 / r).squareRoot() - 1) * w
                    minScale = min(minScale, scale[i])
                    clamped += 1
                }
            }
            totalClamped += clamped
            bands.append(band)
            scales.append(scale)
            if env["HYPERFOCAL_PMAX_ENV_DEBUG"] != nil {
                FileHandle.standardError.write(String(
                    format: "pmax env clamp: octave %d, %d/%d cells scaled\n",
                    l, clamped, gw * gh).data(using: .utf8)!)
            }
        }
        guard totalClamped > 0 else { return }
        // Accumulate the CORRECTION (s−1)·band per octave, expanded up the
        // pyramid, and add it once — mathematically the same as scaling the
        // bands and reassembling, but exact zeros propagate through the
        // linear expand, so pixels outside every clamped cell (the whole
        // subject) stay bit-identical instead of paying an f16 roundtrip.
        var corr: ImageBuffer? = nil
        for l in stride(from: octaves - 1, through: 0, by: -1) {
            let (wl, hl) = (gauss[l].width, gauss[l].height)
            var c = corr.map { expandTo($0, w: wl, h: hl) }
                ?? ImageBuffer(width: wl, height: hl)
            let f = max(1, envCell >> l)
            let gw = (wl + f - 1) / f, gh = (hl + f - 1) / f
            let sPlane = Filters.resizePlaneBilinear(scales[l], width: gw,
                                                     height: gh,
                                                     toWidth: wl, toHeight: hl)
            c.pixels.withUnsafeMutableBufferPointer { cb in
                let cp = cb.baseAddress!
                bands[l].pixels.withUnsafeBufferPointer { bp in
                    let b = bp.baseAddress!
                    sPlane.withUnsafeBufferPointer { sp in
                        DispatchQueue.concurrentPerform(iterations: hl) { y in
                            for x in 0..<wl {
                                let i = y * wl + x
                                let s = min(sp[i], 1)
                                if s < 1 {
                                    let pi = i * 4
                                    hfStoreRGBA(cp, pi, hfLoadRGBA(cp, pi)
                                        + hfLoadRGBA(b, pi) * (s - 1))
                                }
                            }
                        }
                    }
                }
            }
            corr = c
        }
        if let corr {
            out.pixels.withUnsafeMutableBufferPointer { op in
                let o = op.baseAddress!
                corr.pixels.withUnsafeBufferPointer { cb in
                    let cp = cb.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: h0) { y in
                        for i in stride(from: y * w0 * 4, to: (y + 1) * w0 * 4,
                                        by: 4) {
                            let d = hfLoadRGBA(cp, i)
                            if d != SIMD4<Float>() {
                                hfStoreRGBA(o, i, hfLoadRGBA(o, i) + d)
                            }
                        }
                    }
                }
            }
        }
        if env["HYPERFOCAL_PMAX_ENV_DEBUG"] != nil {
            FileHandle.standardError.write(String(
                format: "pmax env clamp: min scale %.3f\n",
                minScale).data(using: .utf8)!)
        }
        log?("pmax: envelope clamp engaged (\(totalClamped) cells)")
    }

    /// The open-background membership — true where the pixel belongs to a
    /// connected never-sharp field that reaches the frame border and whose
    /// focus energy never moves with the sweep (see `debloomMasks`) — plus
    /// the clean-field luminance grid reconstructed from the open field's
    /// uncontaminated pixels, which the merge's sign-aware track-B choice
    /// compares renditions against. Nil when the planes are unavailable (a
    /// backend not yet accumulating them) or no component qualifies.
    static func openBackground(focusMax0: [Float], focusMin0: [Float],
                               lumMin0: [Float], lumMax0: [Float],
                               frameCount: Int, width: Int, height: Int,
                               env: [String: String])
        -> (bg: [Bool], cleanGrid: [Float], gw: Int, gh: Int)? {
        guard let open = openFieldCandidates(focusMax0: focusMax0, focusMin0: focusMin0,
                                             lumMin0: lumMin0, lumMax0: lumMax0,
                                             frameCount: frameCount,
                                             width: width, height: height,
                                             env: env) else { return nil }
        let comps = open.comps
        let candidate = open.candidate
        let flat = componentFlatness(comps: comps, candidate: candidate,
                                     lumMin0: lumMin0, lumMax0: lumMax0,
                                     rLo: open.rLo, rHi: open.rHi,
                                     width: width, height: height, env: env)
        let flatCut = Float(env["HYPERFOCAL_PMAX_BG_FLAT"] ?? "") ?? 0.0035
        var keep = [Bool](repeating: false, count: comps.count)
        var any = false
        for c in 0..<comps.count where candidate[c] && flat.sigma[c] < flatCut {
            keep[c] = true
            any = true
        }
        guard any else { return nil }
        var bg = [Bool](repeating: false, count: width * height)
        for i in bg.indices where comps.labels[i] > 0 {
            bg[i] = keep[Int(comps.labels[i]) - 1]
        }
        // Drop the anchors of rejected components, then push-pull across the
        // holes (the contaminated bands beside silhouettes).
        var vw = flat.vw, wt = flat.wt
        let gw = flat.gw, gh = flat.gh
        for gi in 0..<(gw * gh) {
            if flat.cellLabel[gi] == 0 || !keep[Int(flat.cellLabel[gi]) - 1] {
                vw[gi] = 0; wt[gi] = 0
            }
        }
        let cleanGrid = DepthRegularize.pushPull(valueWeight: vw, weight: wt,
                                                 width: gw, height: gh)
        return (bg, cleanGrid, gw, gh)
    }

    /// The open-field component analysis shared by the clean-field membership
    /// (`openBackground`) and background governance (`governBackground`):
    /// sharp-structure close, border-connected components of the open field,
    /// and the candidate test (size floor, border contact, clean-anchor
    /// floor, never-focuses ratio median). One function on purpose — two
    /// copies of these thresholds is how the two consumers would drift.
    static func openFieldCandidates(focusMax0: [Float], focusMin0: [Float],
                                    lumMin0: [Float], lumMax0: [Float],
                                    frameCount: Int, width: Int, height: Int,
                                    env: [String: String],
                                    governance: Bool = false)
        -> (comps: Morphology.Components, candidate: [Bool],
            rLo: Float, rHi: Float)? {
        guard focusMax0.count == width * height,
              focusMin0.count == width * height,
              lumMin0.count == width * height,
              lumMax0.count == width * height, width > 2, height > 2 else { return nil }
        let alpha = Float(env["HYPERFOCAL_PMAX_BG_ALPHA"] ?? "") ?? 0.15
        let closeFrac = Float(env["HYPERFOCAL_PMAX_BG_CLOSE"] ?? "") ?? 0.0031
        // Contamination-range thresholds: a pixel is "clean" below rLo (its
        // renditions agree across frames) and fully contaminated above rHi.
        let rLo = Float(env["HYPERFOCAL_PMAX_BG_RLO"] ?? "") ?? 0.02
        let rHi = Float(env["HYPERFOCAL_PMAX_BG_RHI"] ?? "") ?? 0.04
        let ratioCut = Float(env["HYPERFOCAL_PMAX_BG_RATIO"] ?? "")
            ?? neverFocusRatioCut(frameCount: frameCount)
        let logCut = log2(ratioCut)
        let t = alpha * max(PlaneMath.percentileLow(focusMax0, 0.99), 1e-6)
        let r = max(4, Int((closeFrac * Float(min(width, height))).rounded()))
        var sharp = [Bool](repeating: false, count: width * height)
        if governance {
            // Governance's subject test additionally requires the energy to
            // MOVE with the sweep. `focusMax0` alone is inflated by exactly
            // the defect governance removes: on defocused foliage the
            // max-of-N of noisy bokeh energy crosses the sharp threshold
            // (measured: whole never-focused regions read "sharp" while
            // their max/min ratios sat at 2.6-3.8 against this cutoff of
            // ~11), so the amplified regions excluded themselves from the
            // membership that would fix them. The cutoff is the same
            // frame-count-scaled never-focuses formula the component test
            // uses — a higher cut (50) was tried and dissolved the SUBJECT
            // (a hairy insect body reads 20-50:1), which nothing in the
            // acceptance criteria measures directly and per-coefficient
            // selection exists to protect. The clean-field membership keeps
            // the energy-only test verbatim — its flatness gate already
            // returns textured components to shipped behavior, so widening
            // its field would only churn.
            let sharpCut = Float(env["HYPERFOCAL_PMAX_GOV_SHARP"] ?? "") ?? ratioCut
            for i in sharp.indices {
                sharp[i] = focusMax0[i] > t
                    && focusMax0[i] > sharpCut * max(focusMin0[i], 1e-6)
            }
        } else {
            for i in sharp.indices { sharp[i] = focusMax0[i] > t }
        }
        // Subject support = close(sharp, r): sharp structure plus the narrow
        // gaps between it. Small r on purpose — see the doc comment above.
        var subject = Morphology.dilate(sharp, width: width, height: height, radius: r)
        subject = Morphology.erode(subject, width: width, height: height, radius: r)
        if governance {
            // OPEN the subject support (erode then dilate, radius 2r):
            // thin-vs-thick is the discriminator the ratio test cannot be.
            // Two measured hole classes punch through otherwise governed
            // fields and each keeps a patch of shipped max-of-N sparkle
            // plus a seam ring: isolated noise-speck ISLANDS (small — tiles
            // stuck at 1.4-1.5× the liveliest frame with 94% weight), and
            // defocused petal-edge RIDGES attached to the subject (thin —
            // breathing bokeh edges read "sharp" by ratio, and no ratio cut
            // separates them from a subject body without dissolving the
            // subject too). Opening removes both while the thick subject
            // core survives. A thin REAL structure (an antenna) losing its
            // exclusion is approximately safe: the block frame decision is
            // its own local energy argmax, so the frame that renders it is
            // the frame it is sharp in.
            let rOpen = 2 * r
            subject = Morphology.erode(subject, width: width, height: height,
                                       radius: rOpen)
            subject = Morphology.dilate(subject, width: width, height: height,
                                        radius: rOpen)
        }

        // Components of the open (non-subject) field, with border contact and
        // a log2 histogram of the focus max/min ratio for the median.
        let comps = Morphology.components(open: subject.map { !$0 },
                                          width: width, height: height)
        let minSize = 1000
        let bins = 64
        let binScale: Float = 4  // bin = log2(ratio) * 4, clamped to [0, 63]
        var ratioHist = [Int](repeating: 0, count: comps.count * bins)
        var cleanCount = [Int](repeating: 0, count: comps.count)
        for i in 0..<(width * height) where comps.labels[i] > 0 {
            let c = Int(comps.labels[i]) - 1
            let ratio = focusMax0[i] / max(focusMin0[i], 1e-6)
            let b = min(max(Int(log2(max(ratio, 1)) * binScale), 0), bins - 1)
            ratioHist[c * bins + b] += 1
            if lumMax0[i] - lumMin0[i] <= rLo { cleanCount[c] += 1 }
        }
        var candidate = [Bool](repeating: false, count: comps.count)
        var anyCandidate = false
        for c in 0..<comps.count {
            // The clean-anchor floor matters: a component too small to carry
            // uncontaminated pixels is mostly band (it hugs a silhouette),
            // and there is nothing to anchor its clean field to.
            guard comps.sizes[c] >= minSize, comps.touchesBorder[c],
                  cleanCount[c] >= 100 else { continue }
            var seen = 0
            var medianBin = bins - 1
            for b in 0..<bins {
                seen += ratioHist[c * bins + b]
                if seen * 2 >= comps.sizes[c] { medianBin = b; break }
            }
            guard Float(medianBin) / binScale < logCut else { continue }
            candidate[c] = true
            anyCandidate = true
        }
        guard anyCandidate else { return nil }
        return (comps, candidate, rLo, rHi)
    }

    /// Clean-anchor accumulation and per-component flatness sigma. Shared by
    /// the clean-field membership (`openBackground` keeps components BELOW
    /// the cut — flat backdrops, the only thing the clean field faithfully
    /// models) and background governance (`governBackground` governs the
    /// textured complement), so the two scopes stay complementary by
    /// construction: one measurement, one cut, no component served by both
    /// mechanisms. `sigma` is +infinity where a component has too few anchor
    /// cells to judge (< 30) — "not provably flat".
    ///
    /// Anchors are the midrange of the per-pixel min/max — where the
    /// renditions agree, that IS the clean value — with weight fading as
    /// contamination grows; anchoring instead of filtering is what keeps the
    /// subject from dragging the estimate. Flatness is judged on the anchors
    /// with the large-scale gradient removed: sigma of the anchor-cell mean
    /// minus its 9×9-cell box mean. Measured: flat backdrops sit at
    /// 0.001-0.003 (their noise floor), textured ones at 0.005-0.04; the cut
    /// (`HYPERFOCAL_PMAX_BG_FLAT`, default 0.0035) sits at the geometric
    /// middle of that gap so a borderline component cannot flip open on one
    /// engine and closed on another (a cut of 0.0045 did exactly that: a
    /// 0.0046-sigma component closed on the CPU's planes and opened on the
    /// GPU's).
    static func componentFlatness(comps: Morphology.Components, candidate: [Bool],
                                  lumMin0: [Float], lumMax0: [Float],
                                  rLo: Float, rHi: Float,
                                  width: Int, height: Int,
                                  env: [String: String])
        -> (sigma: [Float], vw: [Float], wt: [Float], cellLabel: [Int32],
            gw: Int, gh: Int) {
        let f = DMapFusion.sharpnessDownsample
        let gw = (width + f - 1) / f, gh = (height + f - 1) / f
        var vw = [Float](repeating: 0, count: gw * gh)
        var wt = [Float](repeating: 0, count: gw * gh)
        var cellLabel = [Int32](repeating: 0, count: gw * gh)
        for y in 0..<height {
            let gy = y / f
            for x in 0..<width {
                let i = y * width + x
                guard comps.labels[i] > 0,
                      candidate[Int(comps.labels[i]) - 1] else { continue }
                let r = lumMax0[i] - lumMin0[i]
                let w = 1 - PlaneMath.smoothstep(rLo, rHi, r)
                guard w > 0 else { continue }
                let gi = gy * gw + x / f
                vw[gi] += (lumMin0[i] + lumMax0[i]) * 0.5 * w
                wt[gi] += w
                cellLabel[gi] = comps.labels[i]
            }
        }
        let flatCut = Float(env["HYPERFOCAL_PMAX_BG_FLAT"] ?? "") ?? 0.0035
        let minW: Float = 8
        let smoothR = 4
        var cellSum = [Double](repeating: 0, count: comps.count)
        var cellSq = [Double](repeating: 0, count: comps.count)
        var cellN = [Int](repeating: 0, count: comps.count)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let gi = gy * gw + gx
                guard wt[gi] >= minW, cellLabel[gi] > 0 else { continue }
                var sv: Float = 0, sw: Float = 0
                for ny in max(gy - smoothR, 0)...min(gy + smoothR, gh - 1) {
                    for nx in max(gx - smoothR, 0)...min(gx + smoothR, gw - 1) {
                        let ni = ny * gw + nx
                        sv += vw[ni]; sw += wt[ni]
                    }
                }
                guard sw >= minW else { continue }
                let hp = Double(vw[gi] / wt[gi] - sv / sw)
                let c = Int(cellLabel[gi]) - 1
                cellSum[c] += hp
                cellSq[c] += hp * hp
                cellN[c] += 1
            }
        }
        var sigmas = [Float](repeating: .infinity, count: comps.count)
        let debug = env["HYPERFOCAL_PMAX_BG_DEBUG"] != nil
        for c in 0..<comps.count where candidate[c] {
            guard cellN[c] >= 30 else { continue }
            let mean = cellSum[c] / Double(cellN[c])
            let sigma = (max(cellSq[c] / Double(cellN[c]) - mean * mean, 0)).squareRoot()
            if debug {
                FileHandle.standardError.write(String(
                    format: "pmax bg comp: %d px, %d cells, flatness %.5f (cut %.5f)\n",
                    comps.sizes[c], cellN[c], sigma, flatCut).data(using: .utf8)!)
            }
            sigmas[c] = Float(sigma)
        }
        return (sigmas, vw, wt, cellLabel, gw, gh)
    }

    /// Max-pooled reduction, for carrying the near-black membership down to the
    /// coarse levels track B runs at. Averaging is wrong here: at 1/64 scale one
    /// cell spans the subject *and* the band beside it, so a mean drags the
    /// membership toward the subject's zero and switches debloom off in exactly
    /// the few cells next to the silhouette where it does its work. The
    /// question the mask asks is "does this cell contain background that could
    /// be bloomed into?", and that is an any-of, not an average-of.
    static func maxPool(_ plane: [Float], width: Int, height: Int,
                        factor: Int) -> [Float] {
        let ow = (width + factor - 1) / factor
        let oh = (height + factor - 1) / factor
        var out = [Float](repeating: 0, count: ow * oh)
        out.withUnsafeMutableBufferPointer { op in
            plane.withUnsafeBufferPointer { sp in
                DispatchQueue.concurrentPerform(iterations: oh) { oy in
                    for ox in 0..<ow {
                        var m: Float = 0
                        for y in (oy * factor)..<min((oy + 1) * factor, height) {
                            let row = y * width
                            for x in (ox * factor)..<min((ox + 1) * factor, width) {
                                m = max(m, sp[row + x])
                            }
                        }
                        op[oy * ow + ox] = m
                    }
                }
            }
        }
        return out
    }

    /// Land one decoded frame on the workspace's level-0 canvas — the
    /// warp/copy step shared by the streaming loop and the governance second
    /// pass. Identity transform on an uncropped canvas needs no warp — the
    /// same fast path `PyramidWarp.apply` / the GPU paths take; warped frames
    /// resample directly into the workspace's level 0.
    static func installFrame(_ img: ImageBuffer, at fi: Int, warp: PyramidWarp?,
                             ws: CPUWorkspace) {
        let (cw, ch) = ws.sizes[0]
        let needsWarp = warp.map {
            !($0.transforms[fi] == matrix_identity_float3x3
                && cw == img.width && ch == img.height)
        } ?? false
        if needsWarp {
            Warp.applyLanczos3(img, outputToSource: warp!.transforms[fi].inverse,
                               outWidth: cw, outHeight: ch, into: &ws.gauss[0])
        } else {
            precondition(img.width == cw && img.height == ch,
                         "frame size mismatch: \(img.width)x\(img.height)")
            img.pixels.withUnsafeBufferPointer { src in
                ws.gauss[0].withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
    }

    /// 3×3 box smooth of a cell-grid plane — the frame map's transition
    /// feather. With the bilinear upsample to full resolution this widens the
    /// membership and map-transition seams to one-to-two cells (8-16 px) in
    /// image space.
    static func boxSmooth3(_ plane: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: plane.count)
        for y in 0..<height {
            for x in 0..<width {
                var s: Float = 0, n: Float = 0
                for ny in max(y - 1, 0)...min(y + 1, height - 1) {
                    for nx in max(x - 1, 0)...min(x + 1, width - 1) {
                        s += plane[ny * width + nx]; n += 1
                    }
                }
                out[y * width + x] = s / n
            }
        }
        return out
    }

    /// The hybrid background renderer's second pass (design note
    /// `2026-07-28-pmax-hybrid-background-renderer.md`): in never-focused
    /// open-background regions, commit each region to ONE frame — the
    /// regularized frame map's choice — and render that frame faithfully,
    /// the way DMap renders everything, while the subject keeps the
    /// per-coefficient contest. Per-coefficient/per-level independent max
    /// selection has no right answer in a region no frame ever focuses: it
    /// renders energy no source frame contains, or (via the near-black
    /// keep-darkest track) deadens texture the scene really has.
    ///
    /// The frame decision is engine-internal (the streaming pass's cell and
    /// block energy tables), NOT the app's DMap peer: consuming an app-only
    /// input would recreate the app/CLI divergence the shared-defaults
    /// invariant exists to prevent, and the peer's depth is noise exactly
    /// where governance needs an answer.
    ///
    /// Scope, from the outside in, every clause forced by a measurement:
    /// the stack must show a provably TEXTURED open component under the
    /// clean-field geometry (flat-backdrop stacks get nothing from
    /// commitment and were measurably damaged by it); the membership is
    /// `openFieldCandidates`' governance variant (subject = focusing
    /// content, opened so noise-speck islands and petal-edge ridges melt)
    /// restricted to components that are not provably flat (the flatness
    /// gate's retirement path — governance takes over exactly where the
    /// gate excludes the clean field); eligibility within it is
    /// confidence-seeded propagation bounded by `radius`, plus
    /// self-commitment for cells whose energy moves at all. The frame per
    /// 64 px block is the measured level-0 energy argmax over ALL frames
    /// (re-measured over membership cells only among the dominant few),
    /// with near-tie hysteresis so adjacent blocks coalesce, and the render
    /// is a convex per-pixel composite in IMAGE space — bounded by its
    /// sources, so it cannot undershoot the frame floor or exceed every
    /// source the way band-space blending measurably did.
    static func governBackground(ws: CPUWorkspace, out: inout ImageBuffer,
                                 frameCount: Int,
                                 lumMin0: [Float], lumMax0: [Float],
                                 focusMax0: [Float], focusMin0: [Float],
                                 cellMax: [Float], cellMin: [Float],
                                 cellArg: [Int32] = [],
                                 blockEnergy: [Float], blockCells: Int,
                                 radius: Int,
                                 warp: PyramidWarp?, env: [String: String],
                                 log: ((String) -> Void)?,
                                 cancellation: CancellationToken?,
                                 frame: (Int) throws -> ImageBuffer) throws {
        let (w, h) = ws.sizes[0]
        let debug = env["HYPERFOCAL_PMAX_BG_DEBUG"] != nil
        var govBg = [Float](repeating: 0, count: w * h)
        // Offline study tap for the protection-side focusing veto: the
        // per-cell energy-argmax plane (frame indices as floats, -1 where
        // no frame ever installed).
        if !cellArg.isEmpty {
            DMapFusion.dumpPlane(cellArg.map { Float($0) },
                                 env: "HYPERFOCAL_DUMP_GOV_CELLARG")
        }

        // Tier L: LIT never-focused membership — scene material the stack's
        // sweep never reaches (started past the nearest structure / ended
        // before the farthest), the PMax mirror of DMap's tier R. Neither
        // existing arm can see it: the near-black arm requires darkness, and
        // the open-background arm requires ≥100 pixels whose renditions
        // agree within an absolute 0.02 — a bright defocused foreground
        // swings far past both. Membership is per-pixel: lit in its darkest
        // frame (the same scene-relative 0.05 knee DMap's spill/rescue
        // partition uses — a DARK pixel whose energy never moves is
        // backdrop, and stays with the shipped tracks), never sharp by
        // energy, and never moving by the N-anchored ratio (both together,
        // so no focusing content can qualify by either test alone), closed
        // to bridge bokeh gaps. Components below the size floor stay
        // shipped. Deliberately no border-contact, clean-anchor, or
        // flatness clause — those identify BACKDROPS, and tier L's members
        // are scene material wherever they sit.
        let litOff = env["HYPERFOCAL_PMAX_LIT_OFF"] != nil
        let litFrac = Float(env["HYPERFOCAL_PMAX_LIT_FRAC"] ?? "") ?? 0.05
        let f0 = DMapFusion.sharpnessDownsample
        let lgw = (w + f0 - 1) / f0, lgh = (h + f0 - 1) / f0
        let lbw = (lgw + blockCells - 1) / blockCells
        let lbh = (lgh + blockCells - 1) / blockCells
        // Per-block committed frame for tier-L blocks, -1 elsewhere. Filled
        // here — the commitment is part of ADMISSION: a lit component whose
        // mass curve holds no significant bump has no honest frame to
        // commit to, and admitting it anyway would hand its blocks to the
        // per-block argmax, whose scatter inside a never-focused region is
        // the exact mosaic this tier exists to remove (measured during the
        // DMap tier-R work: windows to 328 px agreed with the region's true
        // frame less than half the time). Such components stay entirely
        // with shipped rendering.
        var litBlockFrame = [Int32](repeating: -1, count: lbw * lbh)
        var litMember = 0
        if !litOff {
            // Membership at CELL level: lit AND not-confident, the exact
            // mirror of DMap tier R's "lit no-signal" partition, built from
            // the same scale-free discriminators governance already trusts.
            // Per-pixel absolute tests (never sharp below 0.15 × p99
            // energy, never moving below the N-anchored ratio) detonate at
            // full resolution: linear-light p99 is specular-dominated, so
            // most of a 45 MP scene reads "never sharp", one 27 M px
            // component swallows subject and blob alike, and its mass curve
            // — bokeh sweeps included — commits the lot to a mid-stack frame
            // at a marginal z of exactly 1.5 (why the significance floor
            // below sits at 2). The cell-ratio test has no such anchor: in-focus
            // texture moves 100–5000:1 across the sweep, defocused-garden
            // bokeh 5–30:1, a never-focused foreground's residual bump
            // 2–4:1, noise 1.1–1.3:1 — the same population figures the
            // confidence cut below was calibrated on.
            let litCut = litFrac * max(PlaneMath.percentileLow(lumMax0, 0.95), 1e-6)
            let cellLumMin = DMapFusion.boxDownsample(lumMin0, width: w, height: h,
                                                      factor: f0)
            // Two ratio cuts with distinct roles, and the measurements that
            // forced the split: the CORE (< 4, the BFS confidence family)
            // is what components and the z decision are built from — at 30
            // the blob merged with the mid-ground's own bokeh fields
            // (also 5–30) and the merged giant's mass curve diluted below
            // every z, so nothing committed at all. The EXPANSION cut
            // (< 30) is rendering coverage only: glints inside a
            // never-focused region clear 4 (their bump is real) but ride
            // the bokeh family, and excluding them left max-of-N wash
            // islands speckled through committed content. Expansion is a
            // bounded BFS from committed cores — cell-blocked by focusing
            // texture (100–5000, far above both cuts), distance-blocked
            // from the mid-ground fields the core cut exists to keep out.
            let coreRatio = Float(env["HYPERFOCAL_PMAX_LIT_CORE"] ?? "") ?? 4
            let expandRatio = Float(env["HYPERFOCAL_PMAX_LIT_RATIO"] ?? "") ?? 30
            let expandReach = Int(env["HYPERFOCAL_PMAX_LIT_REACH"] ?? "") ?? 16
            let confFloor = (Float(env["HYPERFOCAL_PMAX_GOV_FLOOR"] ?? "") ?? 0.002)
                * max(PlaneMath.percentileLow(cellMax, 0.99), 1e-7)
            var m = [Bool](repeating: false, count: lgw * lgh)
            var m30 = [Bool](repeating: false, count: lgw * lgh)
            // Coverage-rim guard: registration is estimated, so a partially
            // dark sliver of the warp border survives the common-coverage
            // crop, and with focus breathing its width shrinks monotonically
            // through the sweep — a fake edge-frame energy bump in any
            // border-touching component (measured on a low-contrast synth
            // scene: the rim's curve read z 16 at frame 0 and committed 96%
            // of a scene with no never-focused region at all; ring p99 was
            // 30x the interior's). The outer cell ring leaves MEMBERSHIP —
            // and with it the components, block majorities, and mass curves
            // — but stays reachable by the expansion BFS, so a real
            // committed region still renders its own edge cells by
            // inheritance instead of leaving a shipped-rendered ring.
            let edgeCells = 2
            for i in m.indices {
                guard cellLumMin[i] > litCut else { continue }
                let strong = cellMax[i] > confFloor
                let r30 = cellMax[i] > expandRatio * max(cellMin[i], 1e-7)
                m30[i] = !(strong && r30)
                let x = i % lgw, y = i / lgw
                guard x >= edgeCells, y >= edgeCells,
                      x < lgw - edgeCells, y < lgh - edgeCells else { continue }
                let r4 = cellMax[i] > coreRatio * max(cellMin[i], 1e-7)
                m[i] = !(strong && r4)
            }
            // Fill enclosed holes: glints inside a never-focused region are
            // "confident" (their bump clears the ratio) yet belong to the
            // region — excluded, they render as max-of-N wash islands inside
            // committed content, a patchwork of visibly different blur.
            // Hole-filling (complement components that touch no grid border,
            // below a size ceiling) admits them without moving the OUTER
            // boundary one cell — the conservative-subject-mask lesson from
            // the governance review; a morphological close was rejected for
            // exactly that reason (it also claims concave subject inlets).
            let holes = Morphology.components(open: m.map { !$0 },
                                              width: lgw, height: lgh)
            let holeMax = 4096  // cells; generous for glint clusters,
                                // far below any real scene region
            // Per-cell focusing veto on hole admission (the governance
            // review's "sharp sub-content replaced by blur" class): an
            // enclosed FOCUSING pocket — real scene content the sweep does
            // reach, visible through the never-focused layer — must not be
            // filled. Unvetoed, its cells join the component, its blocks'
            // sharp mid-sweep energy (tens of times the layer's) enters the
            // mass curve, and the argmax leaves the NEAR window: one pocket
            // silently disables the whole region's commitment (measured on
            // the pocketed foreground fixture: argmax 0 -> 10, z 2.8 ->
            // 1.0, commitment lost). The veto is the expansion mask's own
            // cell-ratio cut: glints ride the bokeh family (5-30) and stay
            // admitted; focusing texture (>30, measured 40+ even on noisy
            // synth and 100-5000 on real stacks) is excluded from the
            // fill, the curve, and the committed render — it keeps
            // per-coefficient selection, which is what protects sharpness.
            for i in m.indices where holes.labels[i] > 0 && m30[i] {
                let c = Int(holes.labels[i]) - 1
                if !holes.touchesBorder[c] && holes.sizes[c] <= holeMax {
                    m[i] = true
                }
            }
            let comps = Morphology.components(open: m, width: lgw, height: lgh)
            if debug {
                let mc = m.filter { $0 }.count
                let sizes = comps.sizes.sorted(by: >).prefix(5)
                log?("pmax gov DEBUG: lit m=\(mc)/\(m.count) cells, "
                     + "\(comps.count) comps, top sizes \(Array(sizes)), "
                     + "litCut \(litCut)")
            }
            // Size floor in cells (64 px² each): regions, not speckle — and
            // small enough that a real never-focused band still qualifies.
            let minCells = 256
            let litKeep = (0..<comps.count).map { comps.sizes[$0] >= minCells }
            if litKeep.contains(true) {
                var cellLabel = [Int32](repeating: 0, count: lgw * lgh)
                for i in cellLabel.indices where comps.labels[i] > 0
                    && litKeep[Int(comps.labels[i]) - 1] {
                    cellLabel[i] = comps.labels[i]
                }
                // Cells the focusing veto (below) protects from committed
                // rendering; filled after the curves exist. `vetoCoherent`
                // is the raw own-argmax 5x5 coherence mask, kept for the
                // expansion BFS: inherited rendering must not walk into
                // coherent-focusing content either (a pocket too
                // ratio-strong for membership is NOT labeled, so the veto
                // above never examines it — expansion was how it still got
                // painted with the committed frame).
                var vetoCell = [Bool](repeating: false, count: lgw * lgh)
                var vetoCoherent = [Bool](repeating: false, count: lgw * lgh)
                var blockComp = [Int32](repeating: 0, count: lbw * lbh)
                for by in 0..<lbh {
                    for bx in 0..<lbw {
                        // Canvas-edge blocks stay out of the mass curve:
                        // blockEnergy sums the WHOLE 64-px block, so even
                        // with the rim cells de-membered above, an edge
                        // block's energy still carries the coverage rim —
                        // whose breathing-scaled width is what fakes the
                        // edge-frame bump. Their cells still RENDER
                        // committed via the full-res membership; they just
                        // don't vote.
                        if bx == 0 || by == 0 || bx == lbw - 1 || by == lbh - 1 {
                            continue
                        }
                        var counts: [Int32: Int] = [:]
                        for y in (by * blockCells)..<min((by + 1) * blockCells, lgh) {
                            for x in (bx * blockCells)..<min((bx + 1) * blockCells, lgw) {
                                let l = cellLabel[y * lgw + x]
                                if l > 0 { counts[l, default: 0] += 1 }
                            }
                        }
                        if let (l, n) = counts.max(by: { $0.value < $1.value }),
                           n * 2 >= blockCells * blockCells {
                            blockComp[by * lbw + bx] = l
                        }
                    }
                }
                var compCurve: [Int32: [Double]] = [:]
                for b in 0..<(lbw * lbh) where blockComp[b] > 0 {
                    var cur = compCurve[blockComp[b]]
                        ?? [Double](repeating: 0, count: frameCount)
                    for fr in 0..<frameCount {
                        cur[fr] += Double(blockEnergy[b * frameCount + fr])
                    }
                    compCurve[blockComp[b]] = cur
                }
                // Per-cell focusing veto, BEFORE the commitment decision
                // (the governance review's "sharp sub-content replaced by
                // blur"): a committed region may enclose sub-content the
                // sweep DOES reach — deep dim background seen through a
                // hole in the near layer — whose late energy both poisons
                // the region's mass curve (one 128-cell pocket moved the
                // fixture band's argmax 0 -> 10 and silently killed the
                // whole commitment) and, if the region still commits,
                // gets painted with the edge frame's defocus. Cell ratios
                // cannot separate it from bokeh in the overlapping band;
                // the per-cell energy ARGMAX can: genuine focusing content
                // coheres with its neighbors at its true focus frame
                // (fixture pocket: 100% of cells within ±window), while
                // never-focused mottle scatters (measured p50 coherence
                // 0.24 across a 45 MP committed region). The reference is
                // the NEAR-window argmax of the component's own curve —
                // the only frame tier L may commit to — so the veto needs
                // no committed frame to exist yet. Vetoed cells: INTERIOR
                // only (the region's outermost rows are feather mixtures
                // whose sliver of adjacent sharp content reads coherent —
                // a 73-cell false pocket along the fixture band's top
                // feather cost 5.5 dB of committed benefit), in clusters
                // of >= 16 cells (isolated coherence accidents and lone
                // glints stay committed: per-cell exclusions are the
                // measured max-of-N wash-island failure). Blocks whose
                // labeled cells are majority-vetoed leave the mass curve,
                // then the standard argmax/z/NEAR guards decide on clean
                // evidence; the render fill below skips vetoed cells, so
                // protected pockets keep per-coefficient selection. On the
                // motivating stack this protects 19 pockets (~2% of the
                // commitment) where the same-canvas DMap render shows
                // genuinely sharp rock that commitment had painted with
                // the edge frame's defocus.
                let vetoOff = env["HYPERFOCAL_PMAX_VETO_OFF"] != nil
                let vetoWin = max(2, frameCount / 16)
                if !vetoOff, cellArg.count == lgw * lgh {
                    var nearF0: [Int32: Int32] = [:]
                    for (comp, curve) in compCurve {
                        var mx = -Double.infinity
                        var am: Int32 = 0
                        for fr in 0...min(vetoWin, frameCount - 1)
                            where curve[fr] > mx {
                            mx = curve[fr]; am = Int32(fr)
                        }
                        nearF0[comp] = am
                    }
                    let wWin = Int32(vetoWin)
                    let interior = Morphology.erode(
                        cellLabel.map { $0 > 0 },
                        width: lgw, height: lgh, radius: 2)
                    var cand = [Bool](repeating: false, count: lgw * lgh)
                    for i in cand.indices where interior[i] {
                        guard let f0 = nearF0[cellLabel[i]] else { continue }
                        let a0 = cellArg[i]
                        guard a0 >= 0, abs(a0 - f0) > wWin else { continue }
                        var agree = 0, total = 0
                        let y = i / lgw, x = i % lgw
                        for ny in max(y - 2, 0)...min(y + 2, lgh - 1) {
                            for nx in max(x - 2, 0)...min(x + 2, lgw - 1) {
                                let a = cellArg[ny * lgw + nx]
                                guard a >= 0 else { continue }
                                total += 1
                                if abs(a - a0) <= wWin { agree += 1 }
                            }
                        }
                        cand[i] = total > 0 && Float(agree) > 0.6 * Float(total)
                    }
                    // Own-argmax coherence over ALL cells (not just labeled
                    // interiors) for the expansion gate below.
                    for i in vetoCoherent.indices {
                        let a0 = cellArg[i]
                        guard a0 >= 0 else { continue }
                        var agree = 0, total = 0
                        let y = i / lgw, x = i % lgw
                        for ny in max(y - 2, 0)...min(y + 2, lgh - 1) {
                            for nx in max(x - 2, 0)...min(x + 2, lgw - 1) {
                                let a = cellArg[ny * lgw + nx]
                                guard a >= 0 else { continue }
                                total += 1
                                if abs(a - a0) <= wWin { agree += 1 }
                            }
                        }
                        vetoCoherent[i] = total > 0
                            && Float(agree) > 0.6 * Float(total)
                    }
                    let vcomps = Morphology.components(open: cand,
                                                       width: lgw, height: lgh)
                    let vetoMin = 16
                    var kept = 0
                    var pockets = Set<Int32>()
                    // Cluster ANCHOR argmax (median of the core): growth
                    // and every later comparison are judged against it —
                    // judging against the frontier cell lets a smooth
                    // argmax gradient chain-drift the growth arbitrarily
                    // far (measured on the motivating stack: a frame-116
                    // pocket's growth walked down to frame-0 cells and
                    // "protected" 1590 cells of genuinely never-focused
                    // material).
                    var anchor: [Int32: Int32] = [:]
                    var clusterOf = [Int32](repeating: 0, count: lgw * lgh)
                    var grow = [Int32]()
                    for c in 0..<vcomps.count where vcomps.sizes[c] >= vetoMin {
                        var args = [Int32]()
                        for i in cand.indices where Int(vcomps.labels[i]) - 1 == c {
                            args.append(cellArg[i])
                        }
                        args.sort()
                        anchor[Int32(c + 1)] = args[args.count / 2]
                    }
                    for i in cand.indices where vcomps.labels[i] > 0
                        && anchor[vcomps.labels[i]] != nil {
                        vetoCell[i] = true
                        clusterOf[i] = vcomps.labels[i]
                        kept += 1
                        pockets.insert(vcomps.labels[i])
                        grow.append(Int32(i))
                    }
                    // Grow accepted clusters back through argmax-COMPATIBLE
                    // labeled neighbors (compatible with the cluster's
                    // anchor): the coherence test plus the interior erosion
                    // structurally confine the core to the pocket's inside
                    // (a 128-cell pocket cores at ~46), which can leave
                    // every block under the veto-majority rule below — the
                    // curve stays poisoned and nothing commits. The
                    // surrounding never-focused cells, whose argmaxes don't
                    // match the anchor, block the growth.
                    var head = 0
                    while head < grow.count {
                        let i = Int(grow[head]); head += 1
                        let cl = clusterOf[i]
                        guard let anc = anchor[cl] else { continue }
                        let y = i / lgw, x = i % lgw
                        for ny in max(y - 1, 0)...min(y + 1, lgh - 1) {
                            for nx in max(x - 1, 0)...min(x + 1, lgw - 1) {
                                let ni = ny * lgw + nx
                                guard !vetoCell[ni], cellLabel[ni] > 0,
                                      cellArg[ni] >= 0,
                                      abs(cellArg[ni] - anc) <= wWin else { continue }
                                vetoCell[ni] = true
                                clusterOf[ni] = cl
                                kept += 1
                                grow.append(Int32(ni))
                            }
                        }
                    }
                    if kept > 0 {
                        // Rebuild curves without veto-majority blocks.
                        for b in 0..<(lbw * lbh) where blockComp[b] > 0 {
                            let bx = b % lbw, by = b / lbw
                            var vetoed = 0, labeled = 0
                            for y in (by * blockCells)..<min((by + 1) * blockCells, lgh) {
                                for x in (bx * blockCells)..<min((bx + 1) * blockCells, lgw) {
                                    let i = y * lgw + x
                                    if cellLabel[i] > 0 {
                                        labeled += 1
                                        if vetoCell[i] { vetoed += 1 }
                                    }
                                }
                            }
                            guard labeled > 0, vetoed * 2 >= labeled else { continue }
                            var cur = compCurve[blockComp[b]]!
                            for fr in 0..<frameCount {
                                cur[fr] -= Double(blockEnergy[b * frameCount + fr])
                            }
                            compCurve[blockComp[b]] = cur
                        }
                        log?("pmax gov: focusing veto kept \(kept) cells "
                             + "(\(pockets.count) pockets) on per-coefficient "
                             + "selection")
                    }
                }
                // Significance floor 2: the tier-R populations put flat
                // noise at ≤ 1.3 whatever the component size and genuine
                // bumps at 2.5+; a floor of 1.5 admits a scene-swallowing
                // component at exactly 1.5 (see the membership comment).
                let zLo = Float(env["HYPERFOCAL_PMAX_LIT_Z"] ?? "") ?? 2
                // NEAR-boundary argmaxes only, each exclusion forced by a
                // measurement. Mid-stack: the core cut's low end (2–4)
                // overlaps faint-but-real focusing texture (the measured
                // 3–8 no-man's land), and whole-region commitment painted
                // this stack's mid-scene moss pockets with a defocused
                // frame — the governance review's "sharp sub-content
                // replaced by blur" failure re-measured. FAR boundary: a
                // lit background is a focus continuum running off the
                // sweep's far end — its content peaks across many late
                // frames, and committing the lot to the last one failed
                // C7 (+0.9% background lift) and C8 (121 clustered blur
                // cells) on the lit-garden acceptance stack while touching
                // 70% of its pixels. A NEAR argmax has shown no such
                // continuum: a stack started past its nearest structure
                // yields one coherent beyond-sweep layer, and the first
                // frame is the best rendition physics permits. The far
                // case stays with shipped rendering: committing it would
                // need the C7/C8 acceptance re-run with the per-cell
                // focusing veto in place.
                let window = max(2, frameCount / 16)
                var committedFrame: [Int32: Int32] = [:]
                for (comp, curve) in compCurve {
                    var mx = -Double.infinity
                    var am = 0
                    for fr in 0..<frameCount where curve[fr] > mx {
                        mx = curve[fr]; am = fr
                    }
                    if debug {
                        let s = curve.sorted()
                        let m0 = s[frameCount / 2]
                        let p9 = s[min(Int(Float(frameCount) * 0.9), frameCount - 1)]
                        let zd = p9 - m0 > 0 ? (mx - m0) / (p9 - m0) : -1
                        log?("pmax gov DEBUG: comp \(comp) "
                             + "(\(comps.sizes[Int(comp) - 1]) cells) argmax \(am) "
                             + "window \(window) z \(String(format: "%.2f", zd)) "
                             + "curve[0..4] \(curve.prefix(5).map { Float($0) })")
                    }
                    guard am <= window else { continue }
                    let sorted = curve.sorted()
                    let med = sorted[frameCount / 2]
                    let p90 = sorted[min(Int(Float(frameCount) * 0.9), frameCount - 1)]
                    let band = p90 - med
                    guard band > 0, mx > med, Float((mx - med) / band) >= zLo
                    else { continue }
                    committedFrame[comp] = Int32(am)
                    log?("pmax gov: lit component (\(comps.sizes[Int(comp) - 1]) cells) "
                         + "committed to frame \(am + 1) "
                         + String(format: "(z %.1f)", (mx - med) / band))
                }
                if !committedFrame.isEmpty {
                    // Expansion: bounded BFS from each committed core
                    // through the wider mask. Cells inherit the core's
                    // label (and so its frame); first-come at meeting
                    // fronts, which only happens between two committed
                    // regions and lands in the feather either way.
                    var dist = [Int32](repeating: .max, count: lgw * lgh)
                    var queue = [Int32]()
                    for i in cellLabel.indices
                        where cellLabel[i] > 0
                        && committedFrame[cellLabel[i]] != nil {
                        dist[i] = 0
                        queue.append(Int32(i))
                    }
                    var head = 0
                    while head < queue.count {
                        let i = Int(queue[head]); head += 1
                        let d = dist[i]
                        guard d < Int32(expandReach) else { continue }
                        let y = i / lgw, x = i % lgw
                        for ny in max(y - 1, 0)...min(y + 1, lgh - 1) {
                            for nx in max(x - 1, 0)...min(x + 1, lgw - 1) {
                                let ni = ny * lgw + nx
                                if dist[ni] == .max, m30[ni],
                                   !(vetoCoherent[ni] && cellArg.count == m30.count
                                     && cellArg[ni] >= 0
                                     && committedFrame[cellLabel[i]].map({
                                            abs(cellArg[ni] - $0)
                                                > Int32(max(2, frameCount / 16)) }) == true) {
                                    dist[ni] = d + 1
                                    cellLabel[ni] = cellLabel[i]
                                    queue.append(Int32(ni))
                                }
                            }
                        }
                    }
                    // Blocks from the EXPANDED labels, frames from the
                    // core decision.
                    for by in 0..<lbh {
                        for bx in 0..<lbw {
                            var counts: [Int32: Int] = [:]
                            for y in (by * blockCells)..<min((by + 1) * blockCells, lgh) {
                                for x in (bx * blockCells)..<min((bx + 1) * blockCells, lgw) {
                                    let l = cellLabel[y * lgw + x]
                                    if l > 0, committedFrame[l] != nil {
                                        counts[l, default: 0] += 1
                                    }
                                }
                            }
                            if let (l, n) = counts.max(by: { $0.value < $1.value }),
                               n * 2 >= blockCells * blockCells {
                                litBlockFrame[by * lbw + bx] = committedFrame[l]!
                            }
                        }
                    }
                    // Full-res membership from the expanded labels. The
                    // composite's feather softens the boundary; focusing
                    // texture can never be a member (cell-blocked by both
                    // cuts).
                    for y in 0..<h {
                        let gy = y / f0
                        for x in 0..<w {
                            let gi = gy * lgw + x / f0
                            let l = cellLabel[gi]
                            if l > 0, committedFrame[l] != nil, !vetoCell[gi] {
                                govBg[y * w + x] = 1
                                litMember += 1
                            }
                        }
                    }
                }
            }
        }

        // Stack gate: govern only when the CLEAN-FIELD geometry (energy-only
        // subject test, where bright feature interiors stay enclosed) shows
        // a provably TEXTURED open component. Governance's own widened
        // subject test below merges never-focusing painted surfaces into
        // the open field — necessary to reach amplified texture, but it
        // destroys the component partition this judgment needs (a flat
        // backdrop merged with the subject's smooth roofs read "textured",
        // and the whole stack got repainted). The cut (0.006) sits in the
        // measured gap between the flattest textured background (0.008) and
        // the most textured flat one (0.0042); components between the
        // clean-field cut (0.0035) and this one get NEITHER mechanism —
        // shipped behavior — which is the safe default for a border case.
        let govFlatCut = Float(env["HYPERFOCAL_PMAX_GOV_FLAT"] ?? "") ?? 0.006
        // The textured-open-background arm is the still-experimental half
        // (its radius-6 calibration is the one manual review rejected):
        // it runs only on the explicit radius opt-in, while tier L above
        // ships with the focus gate.
        var member = 0
        if radius > 0, let cleanGeo = openFieldCandidates(focusMax0: focusMax0,
                                              focusMin0: focusMin0,
                                              lumMin0: lumMin0, lumMax0: lumMax0,
                                              frameCount: frameCount,
                                              width: w, height: h, env: env),
           componentFlatness(comps: cleanGeo.comps, candidate: cleanGeo.candidate,
                             lumMin0: lumMin0, lumMax0: lumMax0,
                             rLo: cleanGeo.rLo, rHi: cleanGeo.rHi,
                             width: w, height: h, env: env)
               .sigma.contains(where: { $0 != .infinity && $0 > govFlatCut }),
           let open = openFieldCandidates(focusMax0: focusMax0, focusMin0: focusMin0,
                                          lumMin0: lumMin0, lumMax0: lumMax0,
                                          frameCount: frameCount,
                                          width: w, height: h, env: env,
                                          governance: true) {
            // Governance's open-background membership is the TEXTURED
            // complement of the clean-field scope: candidate components that
            // are NOT provably flat. Flat components keep the shipped
            // clean-field/near-black rendering — it is a faithful model
            // exactly there, and governing them repainted healthy backdrops
            // wholesale.
            let flat = componentFlatness(comps: open.comps, candidate: open.candidate,
                                         lumMin0: lumMin0, lumMax0: lumMax0,
                                         rLo: open.rLo, rHi: open.rHi,
                                         width: w, height: h, env: env)
            let flatCut = Float(env["HYPERFOCAL_PMAX_BG_FLAT"] ?? "") ?? 0.0035
            for i in govBg.indices where open.comps.labels[i] > 0 && govBg[i] == 0 {
                let c = Int(open.comps.labels[i]) - 1
                if open.candidate[c] && !(flat.sigma[c] < flatCut) {
                    govBg[i] = 1; member += 1
                }
            }
        }
        // Either arm can carry the pass alone: the textured-background arm's
        // gates identify backdrops and say nothing about tier L's lit scene
        // material (a stack whose only defect is a never-focused foreground
        // has a flat black backdrop, which is exactly the geometry the
        // stack gate exists to skip).
        guard litMember + member > 0 else {
            log?("pmax gov: no textured open background and no lit "
                 + "never-focused region — pass skipped")
            return
        }
        DMapFusion.dumpPlane(govBg, env: "HYPERFOCAL_DUMP_GOV_BG")

        let f = DMapFusion.sharpnessDownsample
        let gw = (w + f - 1) / f, gh = (h + f - 1) / f
        let cells = gw * gh
        // Confidence is scale-free: a cell is confident when its energy MOVES
        // with the sweep — the baseline-subtracted vote (max − min) must
        // clear a multiple of the cell's own baseline, i.e. a max/min ratio,
        // the same discriminator family as the never-focuses component test
        // (noise breathes ~2:1, bokeh 5-30:1, focusing content 100-5000:1) —
        // plus an absolute floor against dark-noise cells whose near-zero
        // baseline explodes the ratio. A first formulation cut the raw vote
        // at 0.02 × its p99, which landed BELOW the vote median on two
        // corpus stacks: half of every backdrop was "confident" by noise,
        // and the map was per-cell patchwork instead of regional commitment.
        let ratioCut = Float(env["HYPERFOCAL_PMAX_GOV_RATIO"] ?? "") ?? 4
        let floorFrac = Float(env["HYPERFOCAL_PMAX_GOV_FLOOR"] ?? "") ?? 0.002
        let maxP99 = max(PlaneMath.percentileLow(cellMax, 0.99), 1e-7)
        let absFloor = floorFrac * maxP99
        var isConfident = [Bool](repeating: false, count: cells)
        for i in 0..<cells {
            isConfident[i] = cellMax[i] > absFloor
                && cellMax[i] > ratioCut * max(cellMin[i], 1e-7)
        }
        // Eligibility: a cell is governed when it is confident itself, a
        // confident cell reaches it (multi-source BFS, 8-connected, so
        // `radius` is a Chebyshev reach in image space), or its own energy
        // moves with the sweep at all (the self tier — leaving weak-textured
        // cells ungoverned interleaves governed/ungoverned at cell scale,
        // which dilutes every weight to ~0.5, and a half-weight blend of
        // decorrelated fields carries HALF their energy). Truly floorless
        // cells (max == min) outside every seed's reach stay unassigned —
        // the baseline-subtraction rule. WHICH frame a cell renders is
        // decided per block below, from measured energies; eligibility and
        // identity are deliberately separate questions.
        var assign = [Int32](repeating: -1, count: cells)
        var dist = [Int32](repeating: .max, count: cells)
        var queue = [Int32]()
        for i in 0..<cells where isConfident[i] {
            assign[i] = 0; dist[i] = 0; queue.append(Int32(i))
        }
        let confident = queue.count
        var head = 0
        while head < queue.count {
            let i = Int(queue[head]); head += 1
            let d = dist[i]
            guard d < Int32(radius) else { continue }
            let y = i / gw, x = i % gw
            for ny in max(y - 1, 0)...min(y + 1, gh - 1) {
                for nx in max(x - 1, 0)...min(x + 1, gw - 1) {
                    let ni = ny * gw + nx
                    if dist[ni] > d + 1 {
                        dist[ni] = d + 1; assign[ni] = 0
                        queue.append(Int32(ni))
                    }
                }
            }
        }
        var selfAssigned = 0
        for i in 0..<cells where assign[i] < 0 && cellMax[i] > cellMin[i] {
            assign[i] = 0
            selfAssigned += 1
        }
        // Eligibility is background-only: a cell participates when any of
        // its pixels are in the membership (the full-res membership weight
        // below is what keeps subject pixels of a straddling cell
        // untouched).
        let cellGov = DMapFusion.boxDownsample(govBg, width: w, height: h, factor: f)
        var governed = 0
        for i in 0..<cells {
            if cellGov[i] > 0 && assign[i] >= 0 {
                governed += 1
            } else {
                assign[i] = -1
            }
        }
        guard governed > 0 else {
            log?("pmax gov: no cell reaches a confident vote — pass skipped")
            return
        }
        // Commit per BLOCK against the MEASURED energy table: each block of
        // `blockCells`² cells takes the frame with the most summed level-0
        // energy over the sweep — for a never-focused region that IS the
        // liveliest available rendition, and beside a silhouette the sharp
        // frame's edge tail dominates the sum, so the band gets the
        // subject-sharp frame exactly as the prototype's propagation did.
        // Two measured failures force the block granularity: per-cell
        // commitment (even mode-regularized) puts a seam every few cells,
        // and with an 8-24 px feather against ~100 px acceptance tiles most
        // of every tile was transition — decorrelated blends deadened it
        // (energy is quadratic in blend weight) while the seams themselves
        // fabricated. Regions must be much larger than the feather, and the
        // feather much larger than a cell; blocks of 8 cells (64 px) keep
        // seams a small fraction of any region.
        let bw = (gw + blockCells - 1) / blockCells
        let bh = (gh + blockCells - 1) / blockCells
        // A block participates only when its energy MOVES with the sweep
        // (max/min over frames at block scale). On a flat backdrop the
        // argmax is noise, adjacent blocks commit to arbitrary frames whose
        // glow/vignette/exposure differ slightly, and the composite paints
        // a block-scale luminance mosaic — measured: 2.25% of a flat
        // backdrop under the C4 frame floor, in clean 64 px rectangles. A
        // flat block also has nothing to GAIN from commitment: every
        // rendition agrees there. Block-scale noise ratios sit at ~1.1-1.3
        // (4096 px pooled); moving content (bokeh, silhouette-band tails)
        // at 2+.
        let blockRatioCut = Float(env["HYPERFOCAL_PMAX_GOV_BLOCK_RATIO"] ?? "") ?? 1.5
        var blockBest = [Int32](repeating: -1, count: bw * bh)
        var wonMass = [Double](repeating: 0, count: frameCount)
        for b in 0..<(bw * bh) {
            var bestF = -1
            var bestE = -Float.infinity
            var minE = Float.infinity
            for fr in 0..<frameCount {
                let e = blockEnergy[b * frameCount + fr]
                if e > bestE { bestE = e; bestF = fr }
                if e < minE { minE = e }
            }
            guard bestF >= 0, bestE > blockRatioCut * max(minE, 1e-12) else { continue }
            blockBest[b] = Int32(bestF)
            // Frame ranking mass is baseline-subtracted per block, so flat
            // blocks steer the re-decode budget by exactly nothing.
            wonMass[bestF] += Double(bestE - minE)
        }
        // Tier-L committed frames carry their components' mass so the
        // dominant ranking sees them (commitment itself was decided during
        // admission, from the same block-energy table).
        for b in 0..<(bw * bh) where litBlockFrame[b] >= 0 {
            var mx = -Float.infinity
            var mn = Float.infinity
            for fr in 0..<frameCount {
                let e = blockEnergy[b * frameCount + fr]
                if e > mx { mx = e }
                if e < mn { mn = e }
            }
            wonMass[Int(litBlockFrame[b])] += Double(max(mx - mn, 0))
        }
        // The selective second pass re-decodes only the frames that win
        // significant mass, capped (a full-field textured background can
        // legitimately want many — its liveliest frame varies continuously
        // with background depth, and capping at 4 measurably deadened tiles
        // to 0.5-0.8× the liveliest rendition). Blocks whose winner did not
        // make the cut fall back to the best RANKED frame by the same
        // table — a measured second choice, not a frame-index guess.
        // Tier-L committed frames join unconditionally: their blocks render
        // that frame and no other, so it must be decoded.
        let maxDom = max(Int(env["HYPERFOCAL_PMAX_GOV_FRAMES"] ?? "") ?? 8, 1)
        let totalMass = wonMass.reduce(0, +)
        var dominant = wonMass.indices.filter { wonMass[$0] > 0.02 * totalMass }
            .sorted { wonMass[$0] > wonMass[$1] }
            .prefix(maxDom).map { $0 }
        for b in 0..<(bw * bh) where litBlockFrame[b] >= 0 {
            let fr = Int(litBlockFrame[b])
            // Concatenation, not append: at -Onone the Windows toolchain emits
            // its own copy of the Array<Int>.append prespecialization that
            // swiftSwiftOnoneSupport.dll already exports, and lld-link rejects
            // the duplicate when the output is a DLL — so a debug
            // HyperfocalBridge.dll (i.e. Scripts/build.ps1, the whole Windows
            // dev loop) fails to link while hyperfocal-cli.exe builds fine.
            // Other Array<Int>.append sites in the Kit do not trip it, so this
            // is a workaround for a toolchain bug, not a rule: if the dev-loop
            // link breaks again on $sSa6appendyyxnFSi_Tg5, this is the shape of
            // the cause. The copy is bounded by the frame count and runs only
            // for frames not already dominant, so the cost is noise.
            if !dominant.contains(fr) { dominant = dominant + [fr] }
        }
        guard !dominant.isEmpty else {
            log?("pmax gov: no frame wins significant mass — pass skipped")
            return
        }
        // The block CHOICE re-measures the dominant frames' level-0 energy
        // over the MEMBERSHIP cells only (re-decode: ≤ 8 frames, and level 0
        // dominates pyramid cost). The streaming table sums every cell in
        // the block, and beside the subject that lets subject cells hand the
        // block to the subject-sharp frame — whose background is maximally
        // defocused exactly there (measured: subject-adjacent tiles at
        // 0.19× the liveliest rendition). Background-only sums still give
        // the silhouette band to the sharp frame — its edge tail is the
        // dominant energy IN the band cells.
        var domCell = [[Float]](repeating: [], count: dominant.count)
        for (k, fr) in dominant.enumerated() {
            try cancellation?.checkCancelled()
            let img = try frame(fr)
            installFrame(img, at: fr, warp: warp, ws: ws)
            ws.fusedDownsample(level: 0)
            ws.level0BandEnergy()
            domCell[k] = DMapFusion.boxDownsample(ws.energy, width: w, height: h,
                                                  factor: f)
        }
        var blockDomE = [Float](repeating: 0, count: bw * bh * dominant.count)
        for y in 0..<gh {
            for x in 0..<gw {
                let i = y * gw + x
                guard assign[i] >= 0 else { continue }
                let b = (y / blockCells) * bw + x / blockCells
                for k in 0..<dominant.count {
                    blockDomE[b * dominant.count + k] += domCell[k][i]
                }
            }
        }
        for b in 0..<(bw * bh) {
            // A tier-L committed block is pinned: remapping it by re-measured
            // energy would reintroduce exactly the per-block scatter the
            // component decision exists to remove.
            if litBlockFrame[b] >= 0 {
                blockBest[b] = litBlockFrame[b]
                continue
            }
            guard blockBest[b] >= 0 else { continue }
            var bestK = -1
            var bestE: Float = 0
            for k in 0..<dominant.count
                where blockDomE[b * dominant.count + k] > bestE {
                bestE = blockDomE[b * dominant.count + k]; bestK = k
            }
            blockBest[b] = bestK >= 0 ? Int32(dominant[bestK]) : -1
        }
        // Near-tie hysteresis: adjacent blocks whose choices are within 15%
        // of each other coalesce onto the locally most common frame. Every
        // block boundary between two committed frames is a seam, and where
        // the stack breathes (or a frame registers imperfectly) the two
        // sides' bokeh is mutually displaced — the blend prints ghosted
        // edges the focus measure reads as fabricated energy. Fewer, larger
        // regions put the seams where the energy actually changes hands.
        for _ in 0..<2 {
            var next = blockBest
            for by in 0..<bh {
                for bx in 0..<bw {
                    let b = by * bw + bx
                    guard blockBest[b] >= 0, litBlockFrame[b] < 0 else { continue }
                    let ownK = dominant.firstIndex(of: Int(blockBest[b]))!
                    let ownE = blockDomE[b * dominant.count + ownK]
                    var bestFrame = Int(blockBest[b])
                    var bestCount = 0
                    for k in 0..<dominant.count {
                        guard blockDomE[b * dominant.count + k] >= 0.85 * ownE
                        else { continue }
                        var count = 0
                        for ny in max(by - 1, 0)...min(by + 1, bh - 1) {
                            for nx in max(bx - 1, 0)...min(bx + 1, bw - 1) {
                                if blockBest[ny * bw + nx] == Int32(dominant[k]) {
                                    count += 1
                                }
                            }
                        }
                        if count > bestCount {
                            bestCount = count; bestFrame = dominant[k]
                        }
                    }
                    next[b] = Int32(bestFrame)
                }
            }
            blockBest = next
        }
        for y in 0..<gh {
            for x in 0..<gw {
                let i = y * gw + x
                if assign[i] >= 0 {
                    let b = (y / blockCells) * bw + x / blockCells
                    assign[i] = blockBest[b] >= 0 ? blockBest[b] : -1
                }
            }
        }
        let covTxt = dominant.map { String(format: "%d:%.3g", $0, wonMass[$0]) }
            .joined(separator: " ")
        log?("pmax gov: \(governed)/\(cells) cells governed, \(confident) confident, "
             + "\(selfAssigned) self-assigned, dominant frames [\(covTxt)]")
        if debug {
            // The ratio population above the floor, so the cut's margin can
            // be re-checked when new stacks join the corpus (the flatness
            // gate's engine-dependence lesson).
            var ratios: [Float] = []
            for i in 0..<cells where cellMax[i] > absFloor {
                ratios.append(cellMax[i] / max(cellMin[i], 1e-7))
            }
            let p50 = PlaneMath.percentileLow(ratios, 0.5)
            let p90 = PlaneMath.percentileLow(ratios, 0.9)
            FileHandle.standardError.write(String(
                format: "pmax gov: cell ratio p50 %.2f p90 %.2f (cut %.2f), "
                    + "abs floor %.3g (p99 %.3g), member px %d\n",
                p50, p90, ratioCut, absFloor, maxP99, member).data(using: .utf8)!)
        }

        // Membership weight, full-res, feathered a few pixels inward so the
        // composite never hard-cuts at the subject boundary; the ramp lives
        // entirely on the background side (zero outside the membership), so
        // no subject pixel is ever governed.
        let blurred = Filters.blurPlane(govBg, width: w, height: h, sigma: 3)
        var m0 = [Float](repeating: 0, count: w * h)
        for i in m0.indices {
            m0[i] = govBg[i] > 0 ? min(max(2 * blurred[i] - 1, 0), 1) : 0
        }
        // Full-res weight for one frame's regions: the smoothed cell grid
        // carries the 1-2 cell (8-16 px) feather at membership and
        // map-transition seams; the frames partition the governed area, so
        // the weights sum to ≤ 1 everywhere by construction.
        func frameWeight(for fr: Int) -> [Float] {
            var cw = [Float](repeating: 0, count: cells)
            for i in 0..<cells where assign[i] == Int32(fr) { cw[i] = 1 }
            cw = boxSmooth3(cw, width: gw, height: gh)
            var wp = Filters.resizePlaneBilinear(cw, width: gw, height: gh,
                                                 toWidth: w, toHeight: h)
            for i in wp.indices { wp[i] *= m0[i] }
            return wp
        }
        // Composite in IMAGE space — the way DMap renders everything, which
        // is the design's stated model. At weight 1 this is identical to
        // substituting the frame's pyramid at every level (the collapse of a
        // frame's own pyramid IS the frame); in the feather it is a convex
        // per-pixel blend, so the result is bounded by its sources — no
        // pixel can undershoot the frame floor (C4) or exceed every source
        // (C2). Blending BAND COEFFICIENTS per level was measured worse
        // twice: transition widths that differ per level in image space
        // reproduce the coarse-only prototype's incoherent mix around every
        // seam, and band-space mixing of slightly misaligned content rings
        // below both sources (0.23% of a flat backdrop under the C4 floor;
        // image-space compositing cannot do that).
        var wtot = [Float](repeating: 0, count: w * h)
        for fr in dominant {
            let wp = frameWeight(for: fr)
            for i in wp.indices { wtot[i] += wp[i] }
        }
        DMapFusion.dumpPlane(wtot, env: "HYPERFOCAL_DUMP_GOV_W0")
        DMapFusion.dumpPlane(assign.map { Float($0) }, env: "HYPERFOCAL_DUMP_GOV_ASSIGN")
        out.pixels.withUnsafeMutableBufferPointer { opBuf in
            let op = opBuf.baseAddress!
            for i in 0..<(w * h) where wtot[i] > 0 {
                hfStoreRGBA(op, i * 4, hfLoadRGBA(op, i * 4) * max(1 - wtot[i], 0))
            }
        }
        // Selective second pass: re-decode each dominant frame (the closure
        // is still available after streaming, and it carries the per-frame
        // gains exactly as the streaming pass did), land it on the canvas,
        // and accumulate it into its governed regions.
        for fr in dominant {
            try cancellation?.checkCancelled()
            let img = try frame(fr)
            installFrame(img, at: fr, warp: warp, ws: ws)
            let wp = frameWeight(for: fr)
            out.pixels.withUnsafeMutableBufferPointer { opBuf in
                let op = opBuf.baseAddress!
                ws.gauss[0].withUnsafeBufferPointer { gpBuf in
                    let gp = gpBuf.baseAddress!
                    wp.withUnsafeBufferPointer { wpp in
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            for x in 0..<w {
                                let i = y * w + x
                                guard wpp[i] > 0 else { continue }
                                let pi = i * 4
                                hfStoreRGBA(op, pi, hfLoadRGBA(op, pi)
                                                + hfLoadRGBA(gp, pi) * wpp[i])
                            }
                        }
                    }
                }
            }
            log?("pmax gov: governed render from frame \(fr + 1)/\(frameCount)")
        }
    }

    static func downsample(_ img: ImageBuffer) -> ImageBuffer {
        let blurred = Filters.convolveSeparableRGBA(img, kernel: downKernel)
        let nw = (img.width + 1) / 2
        let nh = (img.height + 1) / 2
        var out = ImageBuffer(width: nw, height: nh)
        blurred.pixels.withUnsafeBufferPointer { s in
            out.pixels.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: nh) { y in
                    let srcRow = min(y * 2, img.height - 1) * img.width
                    for x in 0..<nw {
                        let si = (srcRow + min(x * 2, img.width - 1)) * 4
                        let oi = (y * nw + x) * 4
                        for c in 0..<4 { o[oi + c] = s[si + c] }
                    }
                }
            }
        }
        return out
    }

    /// Laplacian pyramid: levels[0..<top] are band-pass residuals, levels[top] is the
    /// low-pass base.
    static func laplacianPyramid(_ img: ImageBuffer, levels: Int) -> [ImageBuffer] {
        var gaussians = [img]
        for _ in 0..<levels {
            gaussians.append(downsample(gaussians.last!))
        }
        var pyramid = [ImageBuffer]()
        for l in 0..<levels {
            let fine = gaussians[l]
            let up = Filters.resizeBilinear(gaussians[l + 1], toWidth: fine.width, toHeight: fine.height)
            var band = ImageBuffer(width: fine.width, height: fine.height)
            // Difference in f32, then narrow — subtracting two halves at f16
            // would quantize the band before it is ever stored.
            band.pixels.withUnsafeMutableBufferPointer { bpBuf in
                let bp = bpBuf.baseAddress!
                fine.pixels.withUnsafeBufferPointer { fBuf in
                    up.pixels.withUnsafeBufferPointer { uBuf in
                        let f = fBuf.baseAddress!, u = uBuf.baseAddress!
                        for i in stride(from: 0, to: bpBuf.count, by: 4) {
                            hfStoreRGBA(bp, i, hfLoadRGBA(f, i) - hfLoadRGBA(u, i))
                        }
                    }
                }
            }
            pyramid.append(band)
        }
        pyramid.append(gaussians[levels])
        return pyramid
    }

    static func collapse(_ pyramid: [ImageBuffer], burtExpand: Bool = false) -> ImageBuffer {
        var current = pyramid[pyramid.count - 1]
        for l in stride(from: pyramid.count - 2, through: 0, by: -1) {
            let band = pyramid[l]
            var up = burtExpand
                ? expandBurt(current, toWidth: band.width, toHeight: band.height)
                : Filters.resizeBilinear(current, toWidth: band.width, toHeight: band.height)
            up.pixels.withUnsafeMutableBufferPointer { uBuf in
                let u = uBuf.baseAddress!
                band.pixels.withUnsafeBufferPointer { bBuf in
                    let b = bBuf.baseAddress!
                    for i in stride(from: 0, to: uBuf.count, by: 4) {
                        hfStoreRGBA(u, i, hfLoadRGBA(u, i) + hfLoadRGBA(b, i))
                    }
                }
            }
            current = up
        }
        return current
    }

    /// Full-image Burt expand (see `CPUWorkspace.upsampleBurtAt`), the
    /// collapse-side counterpart of the band computation's operator.
    static func expandBurt(_ img: ImageBuffer, toWidth w: Int, toHeight h: Int) -> ImageBuffer {
        var out = ImageBuffer(width: w, height: h)
        img.pixels.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            out.pixels.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let v = CPUWorkspace.upsampleBurtAt(src, sw: img.width, sh: img.height,
                                                            x: x, y: y)
                        hfStoreRGBA(dst, (y * w + x) * 4, v)
                    }
                }
            }
        }
        return out
    }

    /// Reduces PMax highlight bloom: a defocused bright feature spreads a
    /// smooth bright gradient whose coarse band would win the max-|Laplacian|
    /// selection and leak into its dark neighbours. Gating the coarsest
    /// `coarseLevels` band levels by focus (max-energy only where a frame has
    /// fine-scale detail, darkest elsewhere) suppresses that without dimming
    /// real bright features. Default (nil) leaves the standard PMax selection
    /// untouched. Runs on the CPU, Metal and wgpu paths; the near-black gate
    /// that keeps track B out of the regime it is invalid in is built by shared
    /// code (`debloomMasks`) that every backend calls.
    /// PMax's settings — the per-algorithm settings object, and the single
    /// source of its shipped defaults. Deliberately parallel to
    /// `DMapFusion.Options`: same name, same non-optional usage, same
    /// "construct it and mutate fields" shape, so neither algorithm's
    /// configuration is a special case. It happens to hold only debloom
    /// (focus-gate) fields today; anything added later belongs here too rather
    /// than as a new parameter alongside it.
    ///
    /// Both shells and the CLI must take their defaults from `Options()` rather
    /// than restating 5 and 0.07, and must express "off" as `coarseLevels == 0`
    /// rather than inventing their own switch.
    ///
    /// That is not style. A surface that wraps this in its own boolean can
    /// ship debloom ON in the app and OFF in the CLI, and then every PMax
    /// measurement taken through the CLI describes a configuration no user
    /// ever sees. `isEnabled` lives here so no caller has to decide what
    /// "off" means.
    public struct Options: Sendable {
        /// Number of coarsest band levels to focus-gate. 0 disables the gate —
        /// this one value is both the off-switch and the strength dial, which
        /// is exactly what the app's single "Debloom levels" slider drives.
        public var coarseLevels: Int
        public var threshold: Float
        /// Smooth the selection energy at every band level, not just level 0
        /// (default ON). The level-0 grit blur exists because the
        /// max-selector can't tell focused detail from isolated
        /// noise; the same failure repeats at coarse levels with bloom in the
        /// noise role — a defocused bright feature's smooth gradient wins
        /// scattered coarse cells against a sharp frame whose energy is dense
        /// but locally lower, and the winners reconstruct as a milky veil over
        /// lit surfaces (where the near-black debloom gate correctly stands
        /// down). Smoothing the energy (never the coefficients) at each
        /// level's own scale makes selection favor spatially supported
        /// structure at every scale, which starves those isolated wins by the
        /// same mechanism grit suppression uses at level 0. Found via the
        /// train stack's blown-text veil: +33 p99 luminance over the sharp
        /// source frame at baseline, +25 with this alone, +19.5 combined with
        /// the Burt expand — the sharp frame itself is the ground truth, and
        /// the research doc carries the full measurements. Enabling brings
        /// the source-envelope discipline with it (the output clamp and the
        /// near-black texture veto — see `applyEnvelopeClamp` /
        /// `nearBlackTextureVeto`), and forces the CPU engine until the GPU
        /// ports land.
        public var smoothedSelection: Bool
        /// EXPERIMENT (CPU-only, default off): base level from the frame with
        /// the highest local deviation per cell, instead of the darkest frame.
        /// Darkest-base is bloom-motivated (the least-luminous frame is the
        /// least-bloomed) but on bright scenes it can only darken; a
        /// texture-winner picks the in-focus frame's low-pass on any backdrop
        /// polarity. Measured on the train stack: fixes darkest-base's global
        /// −2.8 luminance dim but worsens peak veil (+36 vs +33 p99) — not a
        /// win standalone; kept for the follow-up that adds an entropy term to
        /// the winner statistic. Enabling forces the CPU engine.
        public var texturedBase: Bool
        /// Hybrid background governance (design note
        /// `2026-07-28-pmax-hybrid-background-renderer.md`): the frame map's
        /// nearest-confident-cell propagation bound, in sharpness-grid cells
        /// (`DMapFusion.sharpnessDownsample` px each, so 6 ≈ the prototype's
        /// 48 px). 0 = off, shipped behavior — one value is both the off
        /// switch and the reach dial, matching the `coarseLevels` pattern.
        /// Experimental and default-off: until the ship-on decision there is
        /// deliberately no CLI @Option or app control (the dual-UI surface
        /// lands with ship-on); candidates run via the
        /// `HYPERFOCAL_PMAX_GOV_RADIUS` env override. Requires the focus gate
        /// (`isEnabled`); enabling it routes the fuse to the CPU engine.
        public var backgroundGovernanceRadius: Int
        /// Normalize per-frame exposure flicker before any selection is made
        /// — the same correction DMap has always applied (bias-audit A0).
        /// Without it every keep-darkest / keep-brightest / argmin-luminance
        /// decision in the debloom family runs on raw exposure, so 1-2%
        /// shutter or LED flicker is signal to it and "darkest frame"
        /// degenerates to "dimmest-exposed frame". Same default and
        /// semantics as `DMapFusion.Options.normalizeExposure`; both
        /// surfaces expose the two through one control.
        public var normalizeExposure: Bool
        public var isEnabled: Bool { coarseLevels > 0 }
        public init(coarseLevels: Int = 5, threshold: Float = 0.07,
                    smoothedSelection: Bool = true, texturedBase: Bool = false,
                    backgroundGovernanceRadius: Int = 0,
                    normalizeExposure: Bool = true) {
            self.coarseLevels = coarseLevels
            self.threshold = threshold
            self.smoothedSelection = smoothedSelection
            self.texturedBase = texturedBase
            self.backgroundGovernanceRadius = backgroundGovernanceRadius
            self.normalizeExposure = normalizeExposure
        }
    }

    /// Streaming exposure normalization for the PMax paths (bias-audit A0).
    /// DMap measures per-frame channel means, chains gains against frame 0,
    /// and multiplies them in at render; PMax has no separate render pass —
    /// selection IS the render — so the chain scales each frame at ingest
    /// instead, before any energy table, luminance argmin, or envelope sees
    /// it. Gains are global scalars, so scaling the decoded frame commutes
    /// with the (possibly on-device) warp, and one CPU-side implementation
    /// serves all three engines. The output leaves ingest anchored to frame
    /// 0's exposure; `finish()` supplies the geometric-mean re-anchor
    /// (`DMapFusion.renderGains`' convention — no single frame's flicker may
    /// set the output's exposure) to apply once, after governance, plus the
    /// per-frame render gains retouch needs to stamp matching pixels.
    /// Gains within 0.05% of unity snap to exactly 1 so an unflickered
    /// stack's fuse stays bit-identical to an unnormalized one.
    final class ExposureChain {
        private(set) var applied: [SIMD3<Float>] = []
        private var meanRGB0 = SIMD3<Float>(repeating: 1)
        let enabled: Bool
        init(enabled: Bool) { self.enabled = enabled }

        /// Measure + scale a decoded frame, in stream order (frame 0 first —
        /// the same chained contract the DMap loops rely on).
        func ingest(_ img: inout ImageBuffer, at fi: Int) {
            guard enabled else { return }
            precondition(fi == applied.count, "exposure chain needs stream order")
            let mean = DMapFusion.meanChannels(pixels: img.pixels)
            if fi == 0 { meanRGB0 = mean }
            var g = (meanRGB0 / pointwiseMax(mean, .init(repeating: 1e-6)))
                .clamped(lowerBound: .init(repeating: 0.5),
                         upperBound: .init(repeating: 2))
            if abs(g.x - 1) < 5e-4, abs(g.y - 1) < 5e-4, abs(g.z - 1) < 5e-4 {
                g = .one
            }
            if g != .one { img.scaleRGB(by: g) }
            applied.append(g)
        }

        /// Re-apply a frame's recorded gain (governance re-decodes frames for
        /// its committed render; those pixels must match the ingested ones).
        func reapply(_ img: inout ImageBuffer, at fi: Int) {
            guard enabled, fi < applied.count else { return }
            let g = applied[fi]
            if g != .one { img.scaleRGB(by: g) }
        }

        /// The end-of-fuse re-anchor and the per-frame render gains, nil when
        /// no frame needed correction (output already untouched).
        func finish() -> (outputScale: SIMD3<Float>, gains: [SIMD3<Float>])? {
            guard enabled, applied.contains(where: { $0 != .one }) else { return nil }
            var logSum = SIMD3<Float>()
            for g in applied {
                logSum += SIMD3(Foundation.log(max(g.x, 1e-6)),
                                Foundation.log(max(g.y, 1e-6)),
                                Foundation.log(max(g.z, 1e-6)))
            }
            let s = logSum / Float(applied.count)
            let ref = SIMD3<Float>(exp(s.x), exp(s.y), exp(s.z))
            guard ref.min() > 0 else { return nil }
            return (SIMD3<Float>(repeating: 1) / ref, applied.map { $0 / ref })
        }
    }

    /// Focus-gate config resolved from the CLI/param/env, handed to the GPU
    /// paths (`GPUPyramid`/`WgpuPyramid`) so they can gate the coarsest
    /// `coarseLevels` band levels exactly as the CPU streaming loop does.
    struct GPUFocusGate {
        let coarseLevels: Int
        let threshold: Float
    }

    /// Background-governance config for the GPU paths: which arms are live
    /// and the textured arm's propagation radius. The GPU streaming loops
    /// accumulate the cell/block energy tables (a per-frame cell-grid
    /// reduction of the same grit-blurred level-0 energy the CPU pools) and
    /// then run the SHARED `governBackground` as a post-pass on the
    /// collapsed image — decision code identical across engines by
    /// construction, only the table accumulation is per-engine.
    struct GPUGovernance {
        let radius: Int
    }

    /// Selection configuration for the GPU paths, resolved from `Options` +
    /// env by `fuse` exactly once — the GPU paths receive it and never
    /// re-derive it (re-deriving per backend is how paths drift). `clamp`
    /// and `veto` (the source-envelope discipline) additionally require the
    /// focus gate's planes, matching the CPU path's condition.
    struct GPUSelect {
        let smoothed: Bool
        let burt: Bool
        let clamp: Bool
        let veto: Bool
        static let plain = GPUSelect(smoothed: false, burt: false,
                                     clamp: false, veto: false)
    }

    /// Fuses a StackSource: frames decode (prefetched) without warping, and
    /// alignment applies on the GPU when one is available. Prefer this over
    /// the closure form for aligned sources — `source.frame` warps on the
    /// CPU, which costs more than the fusion itself on big stacks.
    public static func fuse(source: StackSource, preferGPU: Bool = true,
                            log: ((String) -> Void)? = nil,
                            progress: ((Double, Int, ImageBuffer?) -> Void)? = nil,
                            cancellation: CancellationToken? = nil,
                            options: Options = Options(),
                            onSharpness: ((FrameSharpness) -> Void)? = nil,
                            onGains: (([SIMD3<Float>]) -> Void)? = nil)
        throws -> ImageBuffer {
        let warp = source.transforms.map {
            PyramidWarp(transforms: $0, outputWidth: source.outputWidth,
                        outputHeight: source.outputHeight)
        }
        return try fuse(frameCount: source.count, preferGPU: preferGPU,
                        warp: warp, log: log, progress: progress,
                        cancellation: cancellation,
                        decodeWorkers: FramePrefetcher.workers(for: source.urls),
                        options: options,
                        onSharpness: onSharpness, onGains: onGains) { i in
            try source.decodedFrame(at: i)
        }
    }

    /// Streams frames in a single pass: only the running fused pyramid, per-level
    /// winner energies, and the current frame's pyramid are resident. Runs on
    /// the GPU when one is available (same algorithm, ≥ 60 dB agreement;
    /// `preferGPU: false` forces the CPU path), falling back to the CPU on
    /// Metal errors. Every path prefetches: `frame` may be invoked
    /// concurrently from background threads, so it must be stateless across
    /// calls (all in-tree closures are). `progress` receives, on the GPU path,
    /// a low-res collapse of the forming pyramid to display (nil on CPU —
    /// collapsing per frame there would double the work).
    ///
    /// With `warp`, `frame` must return unwarped frames; alignment happens
    /// on the GPU (or after decode on the CPU path).
    public static func fuse(frameCount: Int, preferGPU: Bool = true,
                            warp: PyramidWarp? = nil,
                            log: ((String) -> Void)? = nil,
                            progress: ((Double, Int, ImageBuffer?) -> Void)? = nil,
                            cancellation: CancellationToken? = nil,
                            decodeWorkers: Int? = nil,
                            decodeLookahead: Int? = nil,
                            options: Options = Options(),
                            onSharpness: ((FrameSharpness) -> Void)? = nil,
                            onGains: (([SIMD3<Float>]) -> Void)? = nil,
                            frame: @escaping (Int) throws -> ImageBuffer) throws -> ImageBuffer {
        precondition(frameCount > 0)
        // Settings, with env overrides for tuning/ablation — `options` is
        // authoritative, exactly as `DMapFusion.Options` is for dmap. There is
        // no separate enable var: `coarseLevels == 0` IS off (Options.isEnabled),
        // so `HYPERFOCAL_PMAX_DARK_COARSE=0` is the debloom ablation switch.
        let env = ProcessInfo.processInfo.environment
        let fgCoarse = Int(env["HYPERFOCAL_PMAX_DARK_COARSE"] ?? "") ?? options.coarseLevels
        let fgThreshold = Float(env["HYPERFOCAL_PMAX_FOCUS_THRESH"] ?? "") ?? options.threshold
        let focusGateEnabled = fgCoarse > 0
        if focusGateEnabled { log?("pmax: focus-gate on") }
        // Focus-gate config for the GPU paths (nil = standard PMax).
        let gpuFocusGate = focusGateEnabled
            ? GPUFocusGate(coarseLevels: fgCoarse, threshold: fgThreshold) : nil
        // Smoothed selection (shipped ON — see Options) / textured base
        // (experiment, off): env-overridable both ways ("0"/"1") like the
        // gate above.
        let smoothSel = (env["HYPERFOCAL_PMAX_SMOOTH_SEL"].map { $0 != "0" })
            ?? options.smoothedSelection
        // Energy-metric variant for the smoothed path only (see
        // levelBandEnergy): squared band luminance instead of abs-sum RGB.
        let smoothSq = env["HYPERFOCAL_PMAX_SMOOTH_SQ"].map { $0 != "0" } ?? false
        // Burt expand instead of bilinear for band computation AND collapse
        // (see upsampleBurtAt — they must switch together). Always on: this
        // is operator correctness (the bilinear expand was leakier than the
        // proper reconstruction low-pass AND mismatched with the
        // corner-aligned decimation grid), not a preference — the env var is
        // the ablation switch, not a configuration surface.
        let expand5 = env["HYPERFOCAL_PMAX_EXPAND5"].map { $0 != "0" } ?? true
        let texBase = (env["HYPERFOCAL_PMAX_TEX_BASE"].map { $0 != "0" })
            ?? options.texturedBase
        // Source-envelope discipline, part of smoothed selection rather than
        // its own option (they are one shippable behavior: smoothing removes
        // unsupported wins, the clamp bounds what selection may fabricate in
        // never-focused cells, and the texture veto keeps keep-darkest out of
        // live texture — the veto without the clamp would trade deadening for
        // fabrication). Env kill-switches are for ablation only. Both need
        // the focus gate's full-res planes, so they stand down with it.
        let envClamp = smoothSel && focusGateEnabled
            && (env["HYPERFOCAL_PMAX_ENV_CLAMP"].map { $0 != "0" } ?? true)
        let texVeto = envClamp
            && (env["HYPERFOCAL_PMAX_NB_TEX_VETO"].map { $0 != "0" } ?? true)
        // The textured base and the squared-luma energy ablation force the
        // CPU path — silently taking a GPU path that ignores them would
        // measure the wrong configuration. Smoothed selection, the Burt
        // expand and the envelope discipline run on every engine,
        // configured once here via GPUSelect.
        if texBase { log?("pmax: textured base on — CPU engine") }
        if smoothSq { log?("pmax: squared-luma energy ablation — CPU engine") }
        // Background governance runs in two arms with different ship states.
        // Tier L (lit never-focused regional commitment) ships ON whenever
        // the focus gate is enabled — the debloom slider's 0 is its off
        // switch, and HYPERFOCAL_PMAX_LIT_OFF is the ablation. The textured
        // -open-background arm stays experimental behind
        // Options.backgroundGovernanceRadius / HYPERFOCAL_PMAX_GOV_RADIUS
        // (same precedent as HYPERFOCAL_PMAX_NEARBLACK_OFF, so the dual-UI
        // invariant isn't tripped before its ship-on decision). Every
        // engine runs it: the GPU paths accumulate the cell/block tables in
        // their streaming loops and call the shared `governBackground` as a
        // post-pass, so the regional decision is one piece of code
        // everywhere.
        let govRadius = Int(env["HYPERFOCAL_PMAX_GOV_RADIUS"] ?? "")
            ?? options.backgroundGovernanceRadius
        let litGov = focusGateEnabled && env["HYPERFOCAL_PMAX_LIT_OFF"] == nil
        let governance = (govRadius > 0 || litGov) && focusGateEnabled
        if governance {
            log?("pmax: background governance on (lit \(litGov ? "on" : "off"), "
                 + "textured radius \(govRadius) cells)")
        }
        let gpuGovernance = governance ? GPUGovernance(radius: govRadius) : nil
        let preferGPU = preferGPU && !texBase && !smoothSq
        let gpuSelect = GPUSelect(smoothed: smoothSel, burt: expand5,
                                  clamp: envClamp, veto: texVeto)
        // One chain per fuse, shared with whichever engine runs (a GPU
        // failure falls back to CPU with a FRESH chain — the failed
        // attempt's partial ingests must not leak into the retry).
        #if canImport(Metal)
        if preferGPU, MetalEngine.shared != nil {
            do {
                let exposure = ExposureChain(enabled: options.normalizeExposure)
                var out = try GPUPyramid.fuse(frameCount: frameCount, warp: warp,
                                              log: log, progress: progress,
                                              cancellation: cancellation,
                                              decodeWorkers: decodeWorkers,
                                              decodeLookahead: decodeLookahead,
                                              focusGate: gpuFocusGate,
                                              select: gpuSelect,
                                              governance: gpuGovernance,
                                              exposure: exposure,
                                              onSharpness: onSharpness, frame: frame)
                finishExposure(exposure, out: &out, onGains: onGains, log: log)
                return out
            } catch let error as StackError {
                log?("GPU pyramid failed (\(error)); falling back to CPU")
            }
        }
        #endif
        #if HYPERFOCAL_HAVE_WGPU
        if preferGPU, let engine = WgpuEngine.shared, engine.usableForAutoSelection {
            do {
                let exposure = ExposureChain(enabled: options.normalizeExposure)
                var out = try WgpuPyramid.fuse(frameCount: frameCount, warp: warp,
                                               log: log, progress: progress,
                                               cancellation: cancellation,
                                               decodeWorkers: decodeWorkers,
                                               decodeLookahead: decodeLookahead,
                                               focusGate: gpuFocusGate,
                                               select: gpuSelect,
                                               governance: gpuGovernance,
                                               exposure: exposure,
                                               onSharpness: onSharpness, frame: frame)
                finishExposure(exposure, out: &out, onGains: onGains, log: log)
                return out
            } catch let error as StackError {
                log?("wgpu pyramid failed (\(error)); falling back to CPU")
            }
        }
        #endif
        let exposure = ExposureChain(enabled: options.normalizeExposure)
        var levels = 0
        var fused: [ImageBuffer]? = nil
        var workspace: CPUWorkspace? = nil
        // Winner energy per band-pass level, updated as frames stream through.
        var bestEnergy: [[Float]] = []
        // Experiment: darkest-frame base instead of a flat average. The base
        // (coarsest Gaussian) low-pass carries the bloom halo — a bright feature
        // defocused in some frames spreads into its dark surround, and averaging
        // paints that spread into the low frequencies. The least-luminous frame
        // at each base cell is the least-bloomed (spill floor logic), so keeping
        // it kills the halo. Env-gated for A/B.
        // Focus-gated coarse selection (see Options): the bloom is a
        // low-frequency spread that enters through the coarse band levels — a
        // defocused bright feature's smooth bright gradient wins the
        // max-|Laplacian| selection over the dark in-focus neighbour. On the
        // coarsest `darkCoarse` band levels, keep max-energy only where a frame
        // has fine-scale focus and fall back to the darkest (least-bloomed)
        // frame elsewhere; the base uses darkest. This suppresses the bloom
        // without dimming real bright features (blunt darkest-coarse did).
        let darkCoarse = fgCoarse
        let focusGate = focusGateEnabled
        let focusThresh = fgThreshold
        let useDarkBase = (env["HYPERFOCAL_PMAX_DARKBASE"] != nil || focusGate) && !texBase
        var baseBestLum: [Float] = []
        // Textured-base winner: highest local deviation of the base Gaussian
        // per cell (−1 so the first frame installs unconditionally).
        var baseBestDev: [Float] = []
        // f32 sum of every frame's coarsest Gaussian, for the averaged base.
        // See the accumulation site for why this one buffer resists f16.
        var baseAccum: [Float] = []
        var bandBestLum: [[Float]] = []
        var bandBrightLum: [[Float]] = []
        var trackB: [ImageBuffer] = []
        var trackBright: [ImageBuffer] = []
        var hasFocus: [[Float]] = []
        var plainC: [ImageBuffer] = []
        var plainBestE: [[Float]] = []
        var lumMin0: [Float] = []
        var lumMax0: [Float] = []
        var focusMax0: [Float] = []
        var focusMin0: [Float] = []
        // Source-envelope grids: per-cell max over frames of pooled band
        // energy for the octaves the output clamp bounds (the liveliest
        // single frame's energy per octave), plus the level-0 min, whose
        // max/min ratio is the texture veto's sweep statistic.
        var envMax = [[Float]](repeating: [], count: envClampOctaves)
        var env0Min: [Float] = []
        // Governance frame-map inputs: per-cell extrema of the box-pooled
        // level-0 focus (cell = the sharpness grid,
        // `DMapFusion.sharpnessDownsample` px), plus the per-block per-frame
        // energy table the block commitment reads — blocks × frames is tiny
        // (a few MB at 45 MP × 80 frames), so the frame decision is a direct
        // measurement over ALL frames, not an inference from argmax votes.
        var govCellMax: [Float] = []
        var govCellMin: [Float] = []
        // Per-cell argmax frame of the level-0 cell energy — the raw
        // material of the protection-side focusing veto: genuine focusing
        // content coheres with its neighbors' argmaxes at its true focus
        // frame, never-focused mottle scatters (measured <50% agreement at
        // any window on a 45 MP never-focused region).
        var govCellArg: [Int32] = []
        var govBlockEnergy: [Float] = []
        var govGw = 0, govBw = 0
        let govBlockCells = max(Int(env["HYPERFOCAL_PMAX_GOV_BLOCK"] ?? "") ?? 8, 1)
        var sharpnessPlanes: [[Float]] = []
        // Wall-clock phase buckets, reported through `log` at the end — the
        // GPU path's discipline: optimization here must start from
        // measurements, not vibes. `decode` is time *blocked on* the
        // prefetcher, not decode execution.
        var tDecode = 0.0, tWarp = 0.0, tBuild = 0.0, tSelect = 0.0
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

        // Decode on background threads while this thread fuses the previous
        // frame — same overlap (and same concurrent-invocation contract on
        // `frame`) as the GPU paths.
        let prefetcher = FramePrefetcher(indices: Array(0..<frameCount),
                                         lookahead: decodeLookahead
                                             ?? FramePrefetcher.defaultLookahead,
                                         workers: decodeWorkers, decode: frame)
        defer { prefetcher.cancel() }

        for _ in 0..<frameCount {
            try cancellation?.checkCancelled()
            var t0 = now()
            let (fi, rawImg) = try prefetcher.next()
            var img = rawImg
            exposure.ingest(&img, at: fi)
            tDecode += now() - t0
            if workspace == nil {
                // Canvas = the warp's output size (common-coverage crop) or
                // the frame's own — decided before any warp so frames can be
                // resampled straight into the workspace's level 0.
                let w = warp?.outputWidth ?? img.width
                let h = warp?.outputHeight ?? img.height
                levels = max(3, Int(log2(Double(min(w, h)) / 16.0)))
                let ws = CPUWorkspace(width: w, height: h, levels: levels)
                ws.burtExpand = expand5
                workspace = ws
                if envClamp {
                    // −1 / ∞ so the first frame installs unconditionally.
                    for l in 0..<Self.envClampOctaves {
                        let g = ws.envGridSize(level: l)
                        envMax[l] = [Float](repeating: -1, count: g.gw * g.gh)
                    }
                    let g0 = ws.envGridSize(level: 0)
                    env0Min = [Float](repeating: .infinity, count: g0.gw * g0.gh)
                }
                // bestEnergy = −1: the first frame's bands install
                // unconditionally (energies are ≥ 0) — same convention as
                // the GPU paths' bestE fill.
                fused = ws.sizes.map { ImageBuffer(width: $0.w, height: $0.h) }
                bestEnergy = ws.sizes.dropLast().map {
                    [Float](repeating: -1, count: $0.w * $0.h)
                }
                if texBase {
                    baseBestDev = [Float](repeating: -1,
                                          count: ws.sizes[levels].w * ws.sizes[levels].h)
                } else if useDarkBase {
                    baseBestLum = [Float](repeating: .infinity,
                                          count: ws.sizes[levels].w * ws.sizes[levels].h)
                } else {
                    baseAccum = [Float](repeating: 0,
                                        count: ws.sizes[levels].w * ws.sizes[levels].h * 4)
                }
                bandBestLum = (0..<levels).map { l in
                    (darkCoarse > 0 && l >= levels - darkCoarse)
                        ? [Float](repeating: .infinity, count: ws.sizes[l].w * ws.sizes[l].h)
                        : []
                }
                if focusGate {
                    trackB = (0..<levels).map { l in
                        (l >= levels - darkCoarse)
                            ? ImageBuffer(width: ws.sizes[l].w, height: ws.sizes[l].h)
                            : ImageBuffer(width: 0, height: 0)
                    }
                    // The brightest unfocused rendition, kept alongside the
                    // darkest so the merge can pick per cell whichever lands
                    // closer to the clean field (sign-aware track B).
                    trackBright = (0..<levels).map { l in
                        (l >= levels - darkCoarse)
                            ? ImageBuffer(width: ws.sizes[l].w, height: ws.sizes[l].h)
                            : ImageBuffer(width: 0, height: 0)
                    }
                    bandBrightLum = (0..<levels).map { l in
                        (l >= levels - darkCoarse)
                            ? [Float](repeating: -1, count: ws.sizes[l].w * ws.sizes[l].h)
                            : []
                    }
                    hasFocus = (0..<levels).map { l in
                        (l >= levels - darkCoarse)
                            ? [Float](repeating: 0, count: ws.sizes[l].w * ws.sizes[l].h)
                            : []
                    }
                    // Track C: the plain max-energy winner over ALL frames — the
                    // un-debloomed selection, kept so bright regions can fall
                    // back to it (see the near-black gate at the merge). Cheap:
                    // these are only the coarsest levels, ≤ 1/1024 of full res.
                    plainC = (0..<levels).map { l in
                        (l >= levels - darkCoarse)
                            ? ImageBuffer(width: ws.sizes[l].w, height: ws.sizes[l].h)
                            : ImageBuffer(width: 0, height: 0)
                    }
                    plainBestE = (0..<levels).map { l in
                        (l >= levels - darkCoarse)
                            ? [Float](repeating: -1, count: ws.sizes[l].w * ws.sizes[l].h)
                            : []
                    }
                    // FULL-RES max-over-frames of the grit-blurred level-0
                    // focus energy — "was this pixel ever sharp in any
                    // frame". The focus membership's input, measured at full
                    // res for the same reason lumMin0 is (below).
                    focusMax0 = [Float](repeating: 0, count: ws.sizes[0].w * ws.sizes[0].h)
                    focusMin0 = [Float](repeating: .infinity, count: ws.sizes[0].w * ws.sizes[0].h)
                    // FULL-RES per-cell min luminance over all frames — the
                    // near-black test's input.
                    //
                    // Two things had to be right here. The statistic is the
                    // *min*, because the test asks what this cell's true
                    // background level is and the least-contaminated estimate of
                    // that is the darkest frame; a max-based test reads the glow
                    // band — debloom's whole purpose — as a lit surface, because
                    // bloom is exactly what makes it bright in some frame.
                    //
                    // And it is measured at level 0, not at the coarse level
                    // being gated. Track B runs at 1/32…1/1024 scale, where one
                    // cell spans the subject *and* the thin band beside it, so
                    // no per-cell brightness test there can separate them — a
                    // level-local test collapses the two regimes together
                    // (measured: no lo/hi pair satisfies both a dark-background
                    // and a bright-background stack). At full res they separate
                    // cleanly, so the membership is evaluated here and box-
                    // downsampled to each gated level, which also blends
                    // partial-coverage cells instead of hard-switching them.
                    lumMin0 = [Float](repeating: .infinity, count: ws.sizes[0].w * ws.sizes[0].h)
                    lumMax0 = [Float](repeating: 0, count: ws.sizes[0].w * ws.sizes[0].h)
                }
                if governance {
                    let f = DMapFusion.sharpnessDownsample
                    govGw = (w + f - 1) / f
                    let gh = (h + f - 1) / f
                    govCellMax = [Float](repeating: -1, count: govGw * gh)
                    govCellMin = [Float](repeating: .infinity, count: govGw * gh)
                    govCellArg = [Int32](repeating: -1, count: govGw * gh)
                    govBw = (govGw + govBlockCells - 1) / govBlockCells
                    let bh = (gh + govBlockCells - 1) / govBlockCells
                    govBlockEnergy = [Float](repeating: 0, count: govBw * bh * frameCount)
                }
            }
            let ws = workspace!
            let (cw, ch) = ws.sizes[0]
            t0 = now()
            installFrame(img, at: fi, warp: warp, ws: ws)
            tWarp += now() - t0
            t0 = now()
            if focusGate {
                // Running full-res min luminance for the near-black gate.
                ws.gauss[0].withUnsafeBufferPointer { gpBuf in
                    let gp = gpBuf.baseAddress!
                    lumMin0.withUnsafeMutableBufferPointer { mp in
                        lumMax0.withUnsafeMutableBufferPointer { xp in
                            DispatchQueue.concurrentPerform(iterations: ch) { y in
                                for x in 0..<cw {
                                    let i = y * cw + x
                                    let g = hfLoadRGBA(gp, i * 4)
                                    let l = 0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z
                                    if l < mp[i] { mp[i] = l }
                                    if l > xp[i] { xp[i] = l }
                                }
                            }
                        }
                    }
                }
            }
            for l in 0..<levels { ws.fusedDownsample(level: l) }
            ws.level0BandEnergy()
            if envClamp {
                // Envelope statistics from the RAW level-0 band (`band` is
                // still this frame's — see the pooling note in `CPUWorkspace`).
                let g0 = ws.envGridSize(level: 0)
                let p = CPUWorkspace.poolBandEnergy(ws.band, width: cw, height: ch,
                                                    factor: g0.f)
                for i in p.indices {
                    if p[i] > envMax[0][i] { envMax[0][i] = p[i] }
                    if p[i] < env0Min[i] { env0Min[i] = p[i] }
                }
            }
            if focusGate {
                // Running full-res max of the grit-blurred level-0 focus
                // energy — the focus membership's input.
                ws.energy.withUnsafeBufferPointer { ep in
                    focusMax0.withUnsafeMutableBufferPointer { fp in
                        focusMin0.withUnsafeMutableBufferPointer { np in
                            DispatchQueue.concurrentPerform(iterations: ch) { y in
                                for i in (y * cw)..<((y + 1) * cw) {
                                    if ep[i] > fp[i] { fp[i] = ep[i] }
                                    if ep[i] < np[i] { np[i] = ep[i] }
                                }
                            }
                        }
                    }
                }
            }
            if governance {
                // Per-cell extrema of this frame's box-pooled level-0 focus
                // (max − min is the baseline-subtracted vote: a noise-floor
                // cell whose energy never moves with the sweep contributes
                // exactly nothing), and the block × frame energy table the
                // regional frame decision reads.
                let grid = DMapFusion.boxDownsample(ws.energy, width: cw, height: ch,
                                                    factor: DMapFusion.sharpnessDownsample)
                for i in grid.indices {
                    if grid[i] > govCellMax[i] {
                        govCellMax[i] = grid[i]
                        govCellArg[i] = Int32(fi)
                    }
                    if grid[i] < govCellMin[i] { govCellMin[i] = grid[i] }
                    let b = (i / govGw / govBlockCells) * govBw
                        + (i % govGw) / govBlockCells
                    govBlockEnergy[b * frameCount + fi] += grid[i]
                }
            }
            if onSharpness != nil {
                // Reduction of a buffer that is live right here and nowhere
                // else: `energy` is the grit-blurred level-0 focus
                // `level0BandEnergy` just wrote — retained per frame, the
                // sharpness planes retouch's space auto-pick queries (a PMax
                // primary has no DMap pass to retain them from).
                let f = DMapFusion.sharpnessDownsample
                sharpnessPlanes.append(DMapFusion.boxDownsample(
                    ws.energy, width: cw, height: ch, factor: f))
            }
            tBuild += now() - t0
            t0 = now()
            ws.select0(fused: &fused![0], best: &bestEnergy[0])
            for l in 1..<levels {
                // Smoothed selection materializes the level's band + blurred
                // energy first (level 0 always works this way); the *Smoothed
                // variants then read them instead of recomputing raw energy.
                if smoothSel { ws.levelBandEnergy(level: l, squaredLuma: smoothSq) }
                if envClamp, l < Self.envClampOctaves {
                    // This frame's octave-l envelope contribution, from the
                    // band `levelBandEnergy` just materialized.
                    let g = ws.envGridSize(level: l)
                    let p = CPUWorkspace.poolBandEnergy(ws.bandL,
                                                        width: ws.sizes[l].w,
                                                        height: ws.sizes[l].h,
                                                        factor: g.f)
                    for i in p.indices where p[i] > envMax[l][i] {
                        envMax[l][i] = p[i]
                    }
                }
                if focusGate && l >= levels - darkCoarse {
                    let focus = ws.focusDownsampled(toLevel: l)
                    if smoothSel {
                        ws.selectSmoothedFocusGated(level: l, focus: focus,
                                                    threshold: focusThresh,
                                                    fused: &fused![l], bestE: &bestEnergy[l],
                                                    trackB: &trackB[l],
                                                    bestDarkLum: &bandBestLum[l],
                                                    trackBright: &trackBright[l],
                                                    bestBrightLum: &bandBrightLum[l],
                                                    hasFocus: &hasFocus[l],
                                                    plainC: &plainC[l],
                                                    plainBestE: &plainBestE[l])
                    } else {
                        ws.selectStreamingFocusGated(level: l, focus: focus,
                                                     threshold: focusThresh,
                                                     fused: &fused![l], bestE: &bestEnergy[l],
                                                     trackB: &trackB[l],
                                                     bestDarkLum: &bandBestLum[l],
                                                     trackBright: &trackBright[l],
                                                     bestBrightLum: &bandBrightLum[l],
                                                     hasFocus: &hasFocus[l],
                                                     plainC: &plainC[l],
                                                     plainBestE: &plainBestE[l])
                    }
                } else if darkCoarse > 0 && l >= levels - darkCoarse {
                    ws.selectStreamingDark(level: l, fused: &fused![l], bestLum: &bandBestLum[l])
                } else if smoothSel {
                    ws.selectSmoothed(level: l, fused: &fused![l], best: &bestEnergy[l])
                } else {
                    ws.selectStreaming(level: l, fused: &fused![l], best: &bestEnergy[l])
                }
            }
            if texBase {
                // Keep the base RGB of the frame with the highest local
                // deviation at each cell — the in-focus frame's low-pass,
                // whatever the backdrop polarity (see Options.texturedBase).
                ws.updateTexturedBase(fused: &fused![levels], bestDev: &baseBestDev)
            } else if useDarkBase {
                // Keep the least-luminous frame's base RGB at each cell.
                // Storage-to-storage once the winner is decided.
                fused![levels].pixels.withUnsafeMutableBufferPointer { fp in
                    ws.gauss[levels].withUnsafeBufferPointer { gpBuf in
                        let gp = gpBuf.baseAddress!
                        baseBestLum.withUnsafeMutableBufferPointer { bl in
                            for i in 0..<bl.count {
                                let pi = i * 4
                                let g = hfLoadRGBA(gp, pi)
                                let lum = 0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z
                                if lum < bl[i] {
                                    bl[i] = lum
                                    fp[pi] = gpBuf[pi]; fp[pi + 1] = gpBuf[pi + 1]
                                    fp[pi + 2] = gpBuf[pi + 2]; fp[pi + 3] = gpBuf[pi + 3]
                                }
                            }
                        }
                    }
                }
            } else {
                // Base level accumulates a running sum for averaging — the one
                // buffer in the pyramid that is a true ACCUMULATOR, so it stays
                // f32. Summing a stack into f16 would quantize catastrophically
                // (the running total leaves the [0,1] range where f16's steps
                // are fine, and by 40 frames its ulp exceeds a whole pixel's
                // worth of signal). Narrowed into the band pyramid after the
                // divide below.
                baseAccum.withUnsafeMutableBufferPointer { ap in
                    ws.gauss[levels].withUnsafeBufferPointer { gp in
                        for i in 0..<gp.count { ap[i] += Float(gp[i]) }
                    }
                }
            }
            tSelect += now() - t0
            log?("pyramid \(fi + 1)/\(frameCount)")
            progress?(Double(fi + 1) / Double(frameCount), fi, nil)
        }

        // Average the accumulated base level (unless darkest-base or the
        // textured base kept a winner) and narrow the f32 accumulator into the
        // band pyramid.
        if !useDarkBase && !texBase {
            let n = Float(frameCount)
            fused![levels].pixels.withUnsafeMutableBufferPointer { fp in
                baseAccum.withUnsafeBufferPointer { ap in
                    for i in 0..<ap.count { fp[i] = Float16(ap[i] / n) }
                }
            }
        }
        // Focus-gate merge. Two steps: the debloom result is track A
        // (max-energy among in-focus frames) where any frame was in focus, else
        // track B (darkest, bloom-free) — then the whole thing is gated to the
        // near-black regions it is valid in, falling back to track C (the plain
        // max-energy selection) everywhere else.
        //
        // Track B's premise is that the contaminant is additive: a bright
        // subject blooming into a dark background, which is the regime the
        // focus gate was built and tuned for. Where the neighbouring subject is
        // *darker* than the background the sign reverses, and "keep the darkest
        // frame" keeps the most contaminated one — a dark halo hugging the
        // silhouette, plus desaturation as the darker background mixes in.
        // Inverting track B to keep the brightest does not fix it (measured: it
        // trades the dark halo for a larger bright flare, because max-of-N grabs
        // the brightest outlier exactly as min-of-N grabs the darkest). The
        // failure is the extreme order statistic, not its direction — so where
        // the premise does not hold, the fix is to not use it. Track C is the
        // un-debloomed selection, which measures closest to DMap in that regime.
        //
        // Env: `HYPERFOCAL_PMAX_NEARBLACK_LO` / `_HI` (default 0.15 / 0.35, as a
        // fraction of the level's 95th-percentile luminance); `_OFF` restores
        // the ungated merge.
        if focusGate {
            let (w0, h0) = workspace!.sizes[0]
            let veto = texVeto
                ? Self.nearBlackTextureVeto(envMax0: envMax[0], env0Min: env0Min,
                                            focusMax0: focusMax0,
                                            frameCount: frameCount,
                                            width: w0, height: h0, env: env)
                : nil
            if veto != nil { log?("pmax: near-black texture veto engaged") }
            let gate = Self.debloomMasks(lumMin0: lumMin0, lumMax0: lumMax0,
                                         focusMax0: focusMax0,
                                         focusMin0: focusMin0, frameCount: frameCount,
                                         width: w0, height: h0,
                                         sizes: workspace!.sizes, levels: levels,
                                         darkCoarse: darkCoarse,
                                         nearBlackVeto: veto, env: env)
            DMapFusion.dumpPlane(focusMax0, env: "HYPERFOCAL_DUMP_FOCUSMAX0")
            DMapFusion.dumpPlane(focusMin0, env: "HYPERFOCAL_DUMP_FOCUSMIN0")
            DMapFusion.dumpPlane(lumMax0, env: "HYPERFOCAL_DUMP_LUMMAX0")
            log?(String(format: "pmax debloom gate: scale=%.4f, mean mask %.3f, open-bg %.3f",
                        gate.scale, gate.mean, gate.bgFraction))
            for l in 1..<levels where l >= levels - darkCoarse {
                let hf = hasFocus[l]
                let mask = gate.masks[l]
                let bgMask = gate.bgMasks[l]
                let clean = gate.clean[l]
                let darkLum = bandBestLum[l]
                let brightLum = bandBrightLum[l]
                let signAware = !bgMask.isEmpty && !clean.isEmpty
                fused![l].pixels.withUnsafeMutableBufferPointer { apBuf in
                    let ap = apBuf.baseAddress!
                    trackB[l].pixels.withUnsafeBufferPointer { bpBuf in
                        let bp = bpBuf.baseAddress!
                        trackBright[l].pixels.withUnsafeBufferPointer { qpBuf in
                            let qp = qpBuf.baseAddress!
                            plainC[l].pixels.withUnsafeBufferPointer { cpBuf in
                                let cp = cpBuf.baseAddress!
                                for i in 0..<hf.count {
                                    let pi = i * 4
                                    // Debloom's own answer for this cell. In
                                    // open-background cells: the peak-focus
                                    // frame's band where any frame was in focus
                                    // (max-energy would hand the cell back to a
                                    // defocused frame's bloom gradient), else
                                    // the unfocused rendition nearest the clean
                                    // field. Near-black-only cells keep the
                                    // shipped behavior (max-energy A, darkest
                                    // B) — their clean field is extrapolated.
                                    var d: SIMD4<Float>
                                    if hf[i] >= 0.5 {
                                        d = hfLoadRGBA(ap, pi)
                                    } else if signAware, bgMask[i] > 0.5,
                                              abs(brightLum[i] - clean[i])
                                                  < abs(darkLum[i] - clean[i]) {
                                        d = hfLoadRGBA(qp, pi)
                                    } else {
                                        d = hfLoadRGBA(bp, pi)
                                    }
                                    // Membership: 1 where the cell is provably
                                    // background, 0 where it is a lit surface.
                                    // Smoothstepped so the transition can't band
                                    // along the falloff.
                                    let c = hfLoadRGBA(cp, pi)
                                    hfStoreRGBA(ap, pi, c + (d - c) * mask[i])
                                }
                            }
                        }
                    }
                }
            }
        }
        if let onSharpness, let ws = workspace, !sharpnessPlanes.isEmpty {
            let (w, h) = ws.sizes[0]
            onSharpness(FrameSharpness(fullWidth: w, fullHeight: h,
                                       factor: DMapFusion.sharpnessDownsample,
                                       planes: sharpnessPlanes))
        }
        let t0 = now()
        var out = collapse(fused!, burtExpand: expand5)
        // The clamp bounds the COLLAPSED image (see applyEnvelopeClamp for
        // why per-level bounding fails both ways), after every selection and
        // merge decision and before the pipeline's downstream passes.
        if envClamp {
            Self.applyEnvelopeClamp(out: &out, envMax: envMax,
                                    focusMax0: focusMax0, focusMin0: focusMin0,
                                    frameCount: frameCount,
                                    burtExpand: expand5, env: env, log: log)
        }
        log?(String(format: "pyramid phases (cpu): decode %.2fs, warp %.2fs, "
                    + "build %.2fs, select %.2fs, collapse %.2fs",
                    tDecode, tWarp, tBuild, tSelect, now() - t0))
        // Governance composites AFTER the clamp: it replaces governed regions
        // with honest single-frame content (which needs no clamping), while
        // the ungoverned remainder keeps the clamp's protection.
        if governance, focusGate, let ws = workspace {
            try governBackground(ws: ws, out: &out, frameCount: frameCount,
                                 lumMin0: lumMin0, lumMax0: lumMax0,
                                 focusMax0: focusMax0, focusMin0: focusMin0,
                                 cellMax: govCellMax, cellMin: govCellMin,
                                 cellArg: govCellArg,
                                 blockEnergy: govBlockEnergy,
                                 blockCells: govBlockCells, radius: govRadius,
                                 warp: warp, env: env, log: log,
                                 cancellation: cancellation) { fi in
                var f = try frame(fi)
                exposure.reapply(&f, at: fi)
                return f
            }
        }
        finishExposure(exposure, out: &out, onGains: onGains, log: log)
        return out
    }

    /// The exposure chain's end-of-fuse step, shared by the three engine
    /// paths: re-anchor the output to the stack's geometric-mean exposure
    /// and hand the per-frame render gains to the caller (retouch stamps
    /// frames through them, exactly as with DMap's `Output.gains`).
    static func finishExposure(_ exposure: ExposureChain, out: inout ImageBuffer,
                               onGains: (([SIMD3<Float>]) -> Void)?,
                               log: ((String) -> Void)?) {
        guard let fin = exposure.finish() else { return }
        out.scaleRGB(by: fin.outputScale)
        var lo = fin.gains[0], hi = fin.gains[0]
        for g in fin.gains {
            lo = pointwiseMin(lo, g)
            hi = pointwiseMax(hi, g)
        }
        log?(String(format: "pmax exposure gains r %.4f…%.4f g %.4f…%.4f b %.4f…%.4f",
                    lo.x, hi.x, lo.y, hi.y, lo.z, hi.z))
        onGains?(fin.gains)
    }

    /// In-memory convenience for small stacks and tests.
    public static func fuse(_ frames: [ImageBuffer], log: ((String) -> Void)? = nil) -> ImageBuffer {
        // No throwing closure and no cancellation token: cannot actually throw.
        try! fuse(frameCount: frames.count, log: log) { frames[$0] }
    }

    /// Preallocated buffers + fused passes for the CPU streaming loop. The
    /// naive per-frame pipeline (laplacianPyramid → selectionEnergy → select)
    /// materialized every intermediate and allocated fresh buffers per level
    /// per frame — measured ~1.4 s per 11 MP frame against ~0.6 s for the
    /// same arithmetic fused (2-core reference VM). Per-pixel math and
    /// ordering are identical to the naive helpers (and to the GPU kernels):
    /// 5-tap H-then-V blur with edge clamps, min(2x, w−1) decimation,
    /// (x+0.5)·s−0.5 bilinear upsampling, |R|+|G|+|B| energy, grit blur on
    /// level 0's energy only.
    final class CPUWorkspace {
        let levels: Int
        let sizes: [(w: Int, h: Int)]
        // Gaussian levels and the level-0 band are f16 STORAGE — this is the
        // pyramid working set, the largest transient in a PMax fuse, and every
        // read below widens to f32 before it does arithmetic. `energy` and the
        // per-level `best*` planes stay f32: they are scalar, a quarter the
        // bytes, and hold running extrema/sums rather than color.
        var gauss: [[Float16]]    // levels+1 Gaussian levels, RGBA
        var band: [Float16]       // level-0 band, RGBA (kept for post-blur select)
        var energy: [Float]       // level-0 selection energy plane
        var energyTmp: [Float]    // blur scratch
        // Smoothed-selection scratch (levels ≥ 1; sized for level 1, reused by
        // every coarser level). Allocated on first use so the default
        // configuration pays nothing. Separate from `band`/`energy` because
        // `focusDownsampled` reads the level-0 energy plane inside the level
        // loop — overwriting it per level would corrupt the focus gate.
        var bandL: [Float16] = []
        var energyL: [Float] = []
        var energyLTmp: [Float] = []
        // Burt expand for band computation (see upsampleBurtAt); the caller
        // must collapse with the same operator.
        var burtExpand = false
        let gritWeights: [Float]

        init(width: Int, height: Int, levels: Int) {
            self.levels = levels
            var s: [(w: Int, h: Int)] = [(width, height)]
            for _ in 0..<levels {
                let p = s[s.count - 1]
                s.append(((p.w + 1) / 2, (p.h + 1) / 2))
            }
            sizes = s
            gauss = s.map { [Float16](repeating: 0, count: $0.w * $0.h * 4) }
            band = [Float16](repeating: 0, count: width * height * 4)
            energy = [Float](repeating: 0, count: width * height)
            energyTmp = [Float](repeating: 0, count: width * height)
            gritWeights = Filters.gaussianKernel(sigma: PyramidFusion.gritSigma)
        }

        /// 5-tap blur + decimate in one pass: horizontal blur is computed
        /// only for the 5 source rows and even columns each output row
        /// needs, so ~75% of the naive full-resolution blur (and both its
        /// full-res temporaries) never happens. Same taps, same H-then-V
        /// order, same edge clamps as `convolveSeparableRGBA` + `downsample`.
        func fusedDownsample(level l: Int) {
            let (sw, sh) = sizes[l]
            let (nw, nh) = sizes[l + 1]
            let k = PyramidFusion.downKernel
            gauss[l].withUnsafeBufferPointer { srcBuf in
                let src = srcBuf.baseAddress!
                gauss[l + 1].withUnsafeMutableBufferPointer { dstBuf in
                    let dst = dstBuf.baseAddress!
                    k.withUnsafeBufferPointer { kp in
                        DispatchQueue.concurrentPerform(iterations: nh) { oy in
                            // H-blur the 5 contributing source rows at the
                            // decimated columns, then V-blur vertically.
                            var rows = [Float](repeating: 0, count: 5 * nw * 4)
                            let syBase = min(oy * 2, sh - 1)
                            rows.withUnsafeMutableBufferPointer { rp in
                                for ky in 0..<5 {
                                    let sy = min(max(syBase - 2 + ky, 0), sh - 1)
                                    let rowOff = sy * sw
                                    for ox in 0..<nw {
                                        let sx = min(ox * 2, sw - 1)
                                        var acc = SIMD4<Float>()
                                        for kx in 0..<5 {
                                            let tx = min(max(sx - 2 + kx, 0), sw - 1)
                                            acc += hfLoadRGBA(src, (rowOff + tx) * 4) * kp[kx]
                                        }
                                        let o = (ky * nw + ox) * 4
                                        rp[o] = acc.x; rp[o + 1] = acc.y
                                        rp[o + 2] = acc.z; rp[o + 3] = acc.w
                                    }
                                }
                                for ox in 0..<nw {
                                    var acc = SIMD4<Float>()
                                    for ky in 0..<5 {
                                        let i = (ky * nw + ox) * 4
                                        acc += SIMD4<Float>(rp[i], rp[i + 1],
                                                            rp[i + 2], rp[i + 3]) * kp[ky]
                                    }
                                    hfStoreRGBA(dst, (oy * nw + ox) * 4, acc)
                                }
                            }
                        }
                    }
                }
            }
        }

        /// Burt–Adelson expand of the corner-aligned pyramid grid
        /// (`coarse[m] ↔ fine[2m]`, the decimation `fusedDownsample` applies):
        /// zero-stuff + 5-tap `downKernel`, folded to per-parity taps — even
        /// fine samples read coarse m−1/m/m+1 at (1/8, 6/8, 1/8), odd read
        /// m/m+1 at (1/2, 1/2); exact unity gain because the kernel's odd taps
        /// are exactly 1/4. The bilinear `upsampleAt` below is both a leakier
        /// reconstruction low-pass and *center*-aligned — mismatched with the
        /// decimation grid — so bands computed against it keep more residual
        /// low-frequency, which is extra bloom for max-selection to pick up.
        /// Collapse and band computation must switch together (either operator
        /// reconstructs exactly when used for both). The default operator;
        /// `HYPERFOCAL_PMAX_EXPAND5=0` is the ablation switch, and `upsample`
        /// dispatches to the bilinear only then.
        @inline(__always)
        func upsample(_ coarse: UnsafePointer<Float16>, nw: Int, nh: Int,
                      x: Int, y: Int, sx: Float, sy: Float) -> SIMD4<Float> {
            burtExpand
                ? Self.upsampleBurtAt(coarse, sw: nw, sh: nh, x: x, y: y)
                : Self.upsampleAt(coarse, sw: nw, sh: nh, x: x, y: y,
                                  scaleX: sx, scaleY: sy)
        }

        @inline(__always)
        static func upsampleBurtAt(_ src: UnsafePointer<Float16>,
                                   sw: Int, sh: Int,
                                   x: Int, y: Int) -> SIMD4<Float> {
            func taps(_ c: Int, _ limit: Int) -> ((Int, Float), (Int, Float), (Int, Float)) {
                let m = c >> 1
                if c & 1 == 0 {
                    return ((min(max(m - 1, 0), limit - 1), 0.125),
                            (min(m, limit - 1), 0.75),
                            (min(m + 1, limit - 1), 0.125))
                }
                return ((min(m, limit - 1), 0.5),
                        (min(m + 1, limit - 1), 0.5),
                        (min(m, limit - 1), 0))
            }
            let (ty0, ty1, ty2) = taps(y, sh)
            let (tx0, tx1, tx2) = taps(x, sw)
            var acc = SIMD4<Float>()
            for (yy, wy) in [ty0, ty1, ty2] where wy != 0 {
                var row = SIMD4<Float>()
                for (xx, wx) in [tx0, tx1, tx2] where wx != 0 {
                    row += hfLoadRGBA(src, (yy * sw + xx) * 4) * wx
                }
                acc += row * wy
            }
            return acc
        }

        /// Bilinear sample of `gauss[l+1]` at the position `resizeBilinear`
        /// maps output pixel (x, y) to — replicated exactly (incl. the
        /// (x+0.5)·scale−0.5 mapping and edge clamps).
        @inline(__always)
        private static func upsampleAt(_ src: UnsafePointer<Float16>,
                                       sw: Int, sh: Int, x: Int, y: Int,
                                       scaleX: Float, scaleY: Float) -> SIMD4<Float> {
            let fy = (Float(y) + 0.5) * scaleY - 0.5
            let y0 = Int(fy.rounded(.down))
            let wy = fy - Float(y0)
            let cy0 = min(max(y0, 0), sh - 1)
            let cy1 = min(max(y0 + 1, 0), sh - 1)
            let fx = (Float(x) + 0.5) * scaleX - 0.5
            let x0 = Int(fx.rounded(.down))
            let wx = fx - Float(x0)
            let cx0 = min(max(x0, 0), sw - 1)
            let cx1 = min(max(x0 + 1, 0), sw - 1)
            let i00 = (cy0 * sw + cx0) * 4, i10 = (cy0 * sw + cx1) * 4
            let i01 = (cy1 * sw + cx0) * 4, i11 = (cy1 * sw + cx1) * 4
            let top = hfLoadRGBA(src, i00) * (1 - wx) + hfLoadRGBA(src, i10) * wx
            let bot = hfLoadRGBA(src, i01) * (1 - wx) + hfLoadRGBA(src, i11) * wx
            return top * (1 - wy) + bot * wy
        }

        /// Level 0: band + energy in one streaming pass (band kept — the
        /// select must wait for the grit blur), then the energy blur.
        func level0BandEnergy() {
            let (w, h) = sizes[0]
            let (nw, nh) = sizes[1]
            let sx = Float(nw) / Float(w), sy = Float(nh) / Float(h)
            gauss[0].withUnsafeBufferPointer { fineBuf in
                let fine = fineBuf.baseAddress!
                gauss[1].withUnsafeBufferPointer { coarseBuf in
                    let coarse = coarseBuf.baseAddress!
                    band.withUnsafeMutableBufferPointer { bpBuf in
                        let bp = bpBuf.baseAddress!
                        energy.withUnsafeMutableBufferPointer { ep in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for x in 0..<w {
                                    let up = upsample(coarse, nw: nw, nh: nh,
                                                      x: x, y: y, sx: sx, sy: sy)
                                    let i = (y * w + x) * 4
                                    let b = hfLoadRGBA(fine, i) - up
                                    hfStoreRGBA(bp, i, b)
                                    ep[y * w + x] = abs(b.x) + abs(b.y) + abs(b.z)
                                }
                            }
                        }
                    }
                }
            }
            blurEnergy()
        }

        /// Separable grit blur of the energy plane, in workspace buffers —
        /// same taps and clamps as `Filters.blurPlane`.
        private func blurEnergy() {
            blurPlane(&energy, tmp: &energyTmp, width: sizes[0].w, height: sizes[0].h)
        }

        private func blurPlane(_ plane: inout [Float], tmp: inout [Float],
                               width w: Int, height h: Int) {
            let r = gritWeights.count / 2
            plane.withUnsafeBufferPointer { s in
                tmp.withUnsafeMutableBufferPointer { t in
                    gritWeights.withUnsafeBufferPointer { kp in
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            let row = y * w
                            for x in 0..<w {
                                var acc: Float = 0
                                for i in -r...r {
                                    let xi = min(max(x + i, 0), w - 1)
                                    acc += s[row + xi] * kp[i + r]
                                }
                                t[row + x] = acc
                            }
                        }
                    }
                }
            }
            tmp.withUnsafeBufferPointer { t in
                plane.withUnsafeMutableBufferPointer { o in
                    gritWeights.withUnsafeBufferPointer { kp in
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            for x in 0..<w {
                                var acc: Float = 0
                                for i in -r...r {
                                    let yi = min(max(y + i, 0), h - 1)
                                    acc += t[yi * w + x] * kp[i + r]
                                }
                                o[y * w + x] = acc
                            }
                        }
                    }
                }
            }
        }

        /// Level 0's winner update, from the stored band + blurred energy.
        func select0(fused: inout ImageBuffer, best: inout [Float]) {
            let (w, h) = sizes[0]
            band.withUnsafeBufferPointer { bp in
                energy.withUnsafeBufferPointer { ep in
                    fused.pixels.withUnsafeMutableBufferPointer { fp in
                        best.withUnsafeMutableBufferPointer { be in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for i in (y * w)..<((y + 1) * w) {
                                    if ep[i] > be[i] {
                                        be[i] = ep[i]
                                        // Storage-to-storage: both sides are f16
                                        // bands, so the winner copies verbatim.
                                        // (Making this band f32 was measured:
                                        // exactly 0 dB of parity, so it stays
                                        // half — see WgpuParity's notes.)
                                        let pi = i * 4
                                        fp[pi] = bp[pi]
                                        fp[pi + 1] = bp[pi + 1]
                                        fp[pi + 2] = bp[pi + 2]
                                        fp[pi + 3] = bp[pi + 3]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        /// This frame's fine-scale focus (the blurred level-0 selection energy)
        /// box-downsampled to level `l` — high where the frame carries real
        /// in-focus detail, ~0 where it is smooth/defocused/dark.
        func focusDownsampled(toLevel l: Int) -> [Float] {
            DMapFusion.boxDownsample(energy, width: sizes[0].w, height: sizes[0].h,
                                     factor: 1 << l)
        }

        /// Focus-gated coarse selection. Distinguishes a bright feature's own
        /// coarse structure from bloom (a defocused bright feature's smooth
        /// bright gradient) by whether the frame has fine-scale detail here.
        /// Two tracks per position: among frames in focus (focus > threshold)
        /// keep the max-energy band (track A, `fused`/`bestE`); among defocused
        /// frames keep the darkest (track B, `trackB`/`bestDarkLum`). `hasFocus`
        /// records whether any frame was in focus; the caller keeps A there and
        /// B elsewhere — so bloom can never win in a focused region, and a
        /// featureless region falls to the least-bloomed frame.
        ///
        /// Track C (`plainC`/`plainBestE`) accumulates the ordinary max-energy
        /// winner over *every* frame in parallel — the un-debloomed selection,
        /// which the caller's near-black gate falls back to outside the regime
        /// track B is valid in.
        func selectStreamingFocusGated(level l: Int, focus: [Float], threshold: Float,
                                       fused: inout ImageBuffer, bestE: inout [Float],
                                       trackB: inout ImageBuffer, bestDarkLum: inout [Float],
                                       trackBright: inout ImageBuffer,
                                       bestBrightLum: inout [Float],
                                       hasFocus: inout [Float],
                                       plainC: inout ImageBuffer, plainBestE: inout [Float]) {
            let (w, h) = sizes[l]
            let (nw, nh) = sizes[l + 1]
            let sx = Float(nw) / Float(w), sy = Float(nh) / Float(h)
            gauss[l].withUnsafeBufferPointer { fineBuf in
              let fine = fineBuf.baseAddress!
              gauss[l + 1].withUnsafeBufferPointer { coarseBuf in
                let coarse = coarseBuf.baseAddress!
                fused.pixels.withUnsafeMutableBufferPointer { apBuf in
                  let ap = apBuf.baseAddress!
                  trackB.pixels.withUnsafeMutableBufferPointer { bpBuf in
                    let bp = bpBuf.baseAddress!
                    trackBright.pixels.withUnsafeMutableBufferPointer { qpBuf in
                     let qp = qpBuf.baseAddress!
                     bestE.withUnsafeMutableBufferPointer { be in
                      bestDarkLum.withUnsafeMutableBufferPointer { bd in
                       bestBrightLum.withUnsafeMutableBufferPointer { bb in
                        hasFocus.withUnsafeMutableBufferPointer { hf in
                          focus.withUnsafeBufferPointer { fo in
                           plainC.pixels.withUnsafeMutableBufferPointer { cpBuf in
                            let cp = cpBuf.baseAddress!
                            plainBestE.withUnsafeMutableBufferPointer { pe in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                              for x in 0..<w {
                                let i = y * w + x
                                let pi = i * 4
                                let up = upsample(coarse, nw: nw, nh: nh,
                                                  x: x, y: y, sx: sx, sy: sy)
                                let f4 = hfLoadRGBA(fine, pi)
                                let b = f4 - up
                                // Track C runs for every frame, independent of
                                // the focus gate.
                                let ce = abs(b.x) + abs(b.y) + abs(b.z)
                                if ce > pe[i] {
                                    pe[i] = ce
                                    hfStoreRGBA(cp, pi, b)
                                }
                                if fo[i] > threshold {
                                    let e = abs(b.x) + abs(b.y) + abs(b.z)
                                    if e > be[i] {
                                        be[i] = e; hf[i] = 1
                                        hfStoreRGBA(ap, pi, b)
                                    }
                                } else {
                                    let lum = 0.2126 * f4.x + 0.7152 * f4.y + 0.0722 * f4.z
                                    if lum < bd[i] {
                                        bd[i] = lum
                                        hfStoreRGBA(bp, pi, b)
                                    }
                                    if lum > bb[i] {
                                        bb[i] = lum
                                        hfStoreRGBA(qp, pi, b)
                                    }
                                }
                              }
                            }
                            }
                           }
                          }
                        }
                       }
                      }
                     }
                    }
                  }
                }
              }
            }
        }

        /// Coarse-level variant: keep the band of the frame that is DARKEST in
        /// its Gaussian at this level (least bloomed), not the max-energy band.
        /// A defocused bright feature spreads a smooth bright gradient whose
        /// coarse band would win max-selection and leak into the dark neighbor;
        /// the darkest frame there is the in-focus one, whose coarse band is ≈ 0.
        func selectStreamingDark(level l: Int, fused: inout ImageBuffer, bestLum: inout [Float]) {
            let (w, h) = sizes[l]
            let (nw, nh) = sizes[l + 1]
            let sx = Float(nw) / Float(w), sy = Float(nh) / Float(h)
            gauss[l].withUnsafeBufferPointer { fineBuf in
                let fine = fineBuf.baseAddress!
                gauss[l + 1].withUnsafeBufferPointer { coarseBuf in
                    let coarse = coarseBuf.baseAddress!
                    fused.pixels.withUnsafeMutableBufferPointer { fpBuf in
                        let fp = fpBuf.baseAddress!
                        bestLum.withUnsafeMutableBufferPointer { bl in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for x in 0..<w {
                                    let i = y * w + x
                                    let pi = i * 4
                                    let f4 = hfLoadRGBA(fine, pi)
                                    let lum = 0.2126 * f4.x + 0.7152 * f4.y + 0.0722 * f4.z
                                    if lum < bl[i] {
                                        bl[i] = lum
                                        let up = upsample(coarse, nw: nw, nh: nh,
                                                          x: x, y: y, sx: sx, sy: sy)
                                        hfStoreRGBA(fp, pi, f4 - up)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        /// Levels ≥ 1: upsample, band, energy, and winner update in one
        /// streaming pass — nothing is materialized.
        func selectStreaming(level l: Int, fused: inout ImageBuffer, best: inout [Float]) {
            let (w, h) = sizes[l]
            let (nw, nh) = sizes[l + 1]
            let sx = Float(nw) / Float(w), sy = Float(nh) / Float(h)
            gauss[l].withUnsafeBufferPointer { fineBuf in
                let fine = fineBuf.baseAddress!
                gauss[l + 1].withUnsafeBufferPointer { coarseBuf in
                    let coarse = coarseBuf.baseAddress!
                    fused.pixels.withUnsafeMutableBufferPointer { fpBuf in
                        let fp = fpBuf.baseAddress!
                        best.withUnsafeMutableBufferPointer { be in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for x in 0..<w {
                                    let up = upsample(coarse, nw: nw, nh: nh,
                                                      x: x, y: y, sx: sx, sy: sy)
                                    let i = y * w + x
                                    let pi = i * 4
                                    let b = hfLoadRGBA(fine, pi) - up
                                    let e = abs(b.x) + abs(b.y) + abs(b.z)
                                    if e > be[i] {
                                        be[i] = e
                                        hfStoreRGBA(fp, pi, b)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        /// Smoothed selection (levels ≥ 1): materialize level `l`'s band into
        /// `bandL` and its grit-blurred energy into `energyL` — level 0's
        /// band/energy/blur/select shape, applied at this level's own scale.
        /// The `selectSmoothed*` variants below then read these instead of
        /// recomputing raw energy inline. See `Options.smoothedSelection`.
        /// `squaredLuma` swaps the energy for squared band luminance before
        /// the blur (L2 pooling): after smoothing, dense strong structure
        /// outweighs diffuse spread far more than under abs-sum. Measured a
        /// marginal further veil gain over abs-sum (train p99 +23 vs +25);
        /// kept as an env ablation, not the recommended configuration.
        func levelBandEnergy(level l: Int, squaredLuma: Bool) {
            let (w, h) = sizes[l]
            let (nw, nh) = sizes[l + 1]
            if bandL.isEmpty {
                bandL = [Float16](repeating: 0, count: sizes[1].w * sizes[1].h * 4)
                energyL = [Float](repeating: 0, count: sizes[1].w * sizes[1].h)
                energyLTmp = energyL
            }
            let sx = Float(nw) / Float(w), sy = Float(nh) / Float(h)
            gauss[l].withUnsafeBufferPointer { fineBuf in
                let fine = fineBuf.baseAddress!
                gauss[l + 1].withUnsafeBufferPointer { coarseBuf in
                    let coarse = coarseBuf.baseAddress!
                    bandL.withUnsafeMutableBufferPointer { bpBuf in
                        let bp = bpBuf.baseAddress!
                        energyL.withUnsafeMutableBufferPointer { ep in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for x in 0..<w {
                                    let up = upsample(coarse, nw: nw, nh: nh,
                                                      x: x, y: y, sx: sx, sy: sy)
                                    let i = (y * w + x) * 4
                                    let b = hfLoadRGBA(fine, i) - up
                                    hfStoreRGBA(bp, i, b)
                                    if squaredLuma {
                                        let luma = 0.2126 * b.x + 0.7152 * b.y + 0.0722 * b.z
                                        ep[y * w + x] = luma * luma
                                    } else {
                                        ep[y * w + x] = abs(b.x) + abs(b.y) + abs(b.z)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            blurPlane(&energyL, tmp: &energyLTmp, width: w, height: h)
        }

        /// `selectStreaming` against the materialized band + smoothed energy.
        func selectSmoothed(level l: Int, fused: inout ImageBuffer, best: inout [Float]) {
            let (w, h) = sizes[l]
            bandL.withUnsafeBufferPointer { bp in
                energyL.withUnsafeBufferPointer { ep in
                    fused.pixels.withUnsafeMutableBufferPointer { fp in
                        best.withUnsafeMutableBufferPointer { be in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for i in (y * w)..<((y + 1) * w) {
                                    if ep[i] > be[i] {
                                        be[i] = ep[i]
                                        let pi = i * 4
                                        fp[pi] = bp[pi]
                                        fp[pi + 1] = bp[pi + 1]
                                        fp[pi + 2] = bp[pi + 2]
                                        fp[pi + 3] = bp[pi + 3]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        /// `selectStreamingFocusGated` against the materialized band + smoothed
        /// energy: identical tracks and winner rules, with both track A's and
        /// track C's energies read from `energyL` (tracks B/bright pick by
        /// Gaussian luminance, which no smoothing touches).
        func selectSmoothedFocusGated(level l: Int, focus: [Float], threshold: Float,
                                      fused: inout ImageBuffer, bestE: inout [Float],
                                      trackB: inout ImageBuffer, bestDarkLum: inout [Float],
                                      trackBright: inout ImageBuffer,
                                      bestBrightLum: inout [Float],
                                      hasFocus: inout [Float],
                                      plainC: inout ImageBuffer, plainBestE: inout [Float]) {
            let (w, h) = sizes[l]
            gauss[l].withUnsafeBufferPointer { fineBuf in
              let fine = fineBuf.baseAddress!
              bandL.withUnsafeBufferPointer { blBuf in
                let bl = blBuf.baseAddress!
                energyL.withUnsafeBufferPointer { el in
                  fused.pixels.withUnsafeMutableBufferPointer { apBuf in
                    let ap = apBuf.baseAddress!
                    trackB.pixels.withUnsafeMutableBufferPointer { bpBuf in
                      let bp = bpBuf.baseAddress!
                      trackBright.pixels.withUnsafeMutableBufferPointer { qpBuf in
                       let qp = qpBuf.baseAddress!
                       bestE.withUnsafeMutableBufferPointer { be in
                        bestDarkLum.withUnsafeMutableBufferPointer { bd in
                         bestBrightLum.withUnsafeMutableBufferPointer { bb in
                          hasFocus.withUnsafeMutableBufferPointer { hf in
                            focus.withUnsafeBufferPointer { fo in
                             plainC.pixels.withUnsafeMutableBufferPointer { cpBuf in
                              let cp = cpBuf.baseAddress!
                              plainBestE.withUnsafeMutableBufferPointer { pe in
                              DispatchQueue.concurrentPerform(iterations: h) { y in
                                for x in 0..<w {
                                    let i = y * w + x
                                    let pi = i * 4
                                    let b = hfLoadRGBA(bl, pi)
                                    let e = el[i]
                                    // Track C runs for every frame, independent
                                    // of the focus gate.
                                    if e > pe[i] {
                                        pe[i] = e
                                        hfStoreRGBA(cp, pi, b)
                                    }
                                    if fo[i] > threshold {
                                        if e > be[i] {
                                            be[i] = e; hf[i] = 1
                                            hfStoreRGBA(ap, pi, b)
                                        }
                                    } else {
                                        let f4 = hfLoadRGBA(fine, pi)
                                        let lum = 0.2126 * f4.x + 0.7152 * f4.y
                                            + 0.0722 * f4.z
                                        if lum < bd[i] {
                                            bd[i] = lum
                                            hfStoreRGBA(bp, pi, b)
                                        }
                                        if lum > bb[i] {
                                            bb[i] = lum
                                            hfStoreRGBA(qp, pi, b)
                                        }
                                    }
                                }
                              }
                              }
                             }
                            }
                          }
                         }
                        }
                       }
                      }
                    }
                  }
                }
              }
            }
        }

        /// Envelope-grid geometry for a level: cells cover `envCell` full-res
        /// pixels at every level a full-res cell can hold (`f = envCell >> l`,
        /// so `f · 2^l = envCell` through the level where `f` reaches 1),
        /// coarser beyond. A level-independent footprint is what lets the
        /// full-res focus-membership grid map onto every level's clamp grid.
        func envGridSize(level l: Int) -> (gw: Int, gh: Int, f: Int) {
            let f = max(1, PyramidFusion.envCell >> l)
            let (w, h) = sizes[l]
            return ((w + f - 1) / f, (h + f - 1) / f, f)
        }

        /// Mean SQUARED band energy (|R|²+|G|²+|B|²) of an RGBA plane per
        /// envelope cell. Squared, not |·|: the clamp must hold in the same
        /// units quality is measured in (squared-Laplacian family). A
        /// max-of-N mosaic has a different L1:L2 ratio than a coherent
        /// frame — matching mean |band| over-clamps it ~25% in energy
        /// (measured: 40 of 77 background tiles pushed BELOW the envelope's
        /// low side on the defocused-foliage stack).
        static func poolBandEnergy(_ pixels: [Float16], width: Int, height: Int,
                                   factor: Int) -> [Float] {
            let gw = (width + factor - 1) / factor
            let gh = (height + factor - 1) / factor
            var out = [Float](repeating: 0, count: gw * gh)
            out.withUnsafeMutableBufferPointer { op in
                pixels.withUnsafeBufferPointer { sp in
                    let s = sp.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: gh) { gy in
                        for gx in 0..<gw {
                            var acc: Float = 0
                            var n = 0
                            for y in (gy * factor)..<min((gy + 1) * factor, height) {
                                let row = y * width
                                for x in (gx * factor)..<min((gx + 1) * factor, width) {
                                    let b = hfLoadRGBA(s, (row + x) * 4)
                                    acc += b.x * b.x + b.y * b.y + b.z * b.z
                                    n += 1
                                }
                            }
                            op[gy * gw + gx] = n > 0 ? acc / Float(n) : 0
                        }
                    }
                }
            }
            return out
        }

        /// Mean of a scalar plane per envelope cell.
        static func poolScalarMean(_ plane: [Float], width: Int, height: Int,
                                   factor: Int) -> [Float] {
            let gw = (width + factor - 1) / factor
            let gh = (height + factor - 1) / factor
            var out = [Float](repeating: 0, count: gw * gh)
            out.withUnsafeMutableBufferPointer { op in
                plane.withUnsafeBufferPointer { sp in
                    DispatchQueue.concurrentPerform(iterations: gh) { gy in
                        for gx in 0..<gw {
                            var acc: Float = 0
                            var n = 0
                            for y in (gy * factor)..<min((gy + 1) * factor, height) {
                                let row = y * width
                                for x in (gx * factor)..<min((gx + 1) * factor, width) {
                                    acc += sp[row + x]
                                    n += 1
                                }
                            }
                            op[gy * gw + gx] = n > 0 ? acc / Float(n) : 0
                        }
                    }
                }
            }
            return out
        }

        /// Textured-base winner update: keep this frame's base RGB where its
        /// local (5×5, edge-clamped) luminance deviation beats every previous
        /// frame's. The base plane is tiny (≤ 1/2^levels per side), so the
        /// windowed pass is noise-level cost. See `Options.texturedBase`.
        func updateTexturedBase(fused: inout ImageBuffer, bestDev: inout [Float]) {
            let (w, h) = sizes[levels]
            var lum = [Float](repeating: 0, count: w * h)
            gauss[levels].withUnsafeBufferPointer { gpBuf in
                let gp = gpBuf.baseAddress!
                lum.withUnsafeMutableBufferPointer { lp in
                    for i in 0..<(w * h) {
                        let g = hfLoadRGBA(gp, i * 4)
                        lp[i] = 0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z
                    }
                }
            }
            fused.pixels.withUnsafeMutableBufferPointer { fp in
                gauss[levels].withUnsafeBufferPointer { gpBuf in
                    bestDev.withUnsafeMutableBufferPointer { bv in
                        lum.withUnsafeBufferPointer { lp in
                            for y in 0..<h {
                                for x in 0..<w {
                                    var sum: Float = 0, sumSq: Float = 0
                                    for wy in -2...2 {
                                        let yy = min(max(y + wy, 0), h - 1)
                                        for wx in -2...2 {
                                            let xx = min(max(x + wx, 0), w - 1)
                                            let v = lp[yy * w + xx]
                                            sum += v; sumSq += v * v
                                        }
                                    }
                                    let mean = sum / 25
                                    let dev = sumSq / 25 - mean * mean
                                    let i = y * w + x
                                    if dev > bv[i] {
                                        bv[i] = dev
                                        let pi = i * 4
                                        fp[pi] = gpBuf[pi]
                                        fp[pi + 1] = gpBuf[pi + 1]
                                        fp[pi + 2] = gpBuf[pi + 2]
                                        fp[pi + 3] = gpBuf[pi + 3]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Per-pixel selection energy of a band-pass level: sum of |RGB| coefficients.
    /// Grit-suppression blur applied to the finest level's selection energy.
    /// At full resolution the max-selector can't distinguish focused detail
    /// from single-pixel sensor noise — the documented cause of pyramid
    /// fusion's noise amplification (commercial stackers note it and ship
    /// default-on "grit suppression"). Smoothing the *energy* (never
    /// the coefficients) makes selection favor spatially supported detail:
    /// isolated noise pixels can't win, coherent texture still does.
    static let gritSigma: Float = 1

    /// Selection energy for a band level: |R|+|G|+|B|, with the finest level
    /// smoothed for grit suppression. Must match the GPU path's kernels.
    static func selectionEnergy(_ band: ImageBuffer, level: Int) -> [Float] {
        let energy = bandEnergy(band)
        guard level == 0 else { return energy }
        return Filters.blurPlane(energy, width: band.width, height: band.height,
                                 sigma: gritSigma)
    }

    static func bandEnergy(_ band: ImageBuffer) -> [Float] {
        let count = band.width * band.height
        var energy = [Float](repeating: 0, count: count)
        band.pixels.withUnsafeBufferPointer { bpBuf in
            let bp = bpBuf.baseAddress!
            energy.withUnsafeMutableBufferPointer { ep in
                DispatchQueue.concurrentPerform(iterations: band.height) { y in
                    for i in (y * band.width)..<((y + 1) * band.width) {
                        let b = hfLoadRGBA(bp, i * 4)
                        ep[i] = abs(b.x) + abs(b.y) + abs(b.z)
                    }
                }
            }
        }
        return energy
    }
}
