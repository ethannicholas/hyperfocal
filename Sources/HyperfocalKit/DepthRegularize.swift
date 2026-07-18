import Foundation
import Dispatch

/// Confidence-weighted, edge-aware guided-filter depth regularization — the
/// `.guided` alternative to the jump-flood Voronoi fill. Hard argmax survives
/// where confidence is high (the apply pass blends it back in by confidence);
/// where the stack has no signal, smooth ramps form wherever the *guide image*
/// (mean stack luminance) has no edges, and depth stops dead at guide edges —
/// so the silhouette stays crisp at full-res intensity-edge width instead of
/// growing wedge ghosts and rim bands.
///
/// Everything at grid resolution — tier assembly, push-pull prior, weighted
/// moments, WGIF coefficients — is shared CPU code called by both engines, so
/// CPU/GPU parity is by construction. Only guide accumulation and the full-res
/// apply pass are per-engine, and both are order-identical arithmetic.
public enum DepthRegularize {

    /// WGIF linear coefficients at the sharpness grid plus the guide
    /// normalization scalar — everything the full-res apply pass needs.
    public struct Coefficients {
        public let a: [Float]
        public let b: [Float]
        public let gridWidth: Int
        public let gridHeight: Int
        /// 1 / p95 of the grid guide; the full-res apply must scale the
        /// full-res guide by the same value or a·g is computed in different
        /// units than the coefficients were fit in.
        public let guideScale: Float
        public let factor: Int
        /// Spill floor at the grid (empty when no luminance planes were
        /// retained): the argmin-luminance frame per cell and the 0…1
        /// evidence strength. The apply pass pulls signal-free pixels
        /// toward this depth directly — the WGIF window straddling a
        /// silhouette averages subject depths into the adjacent background,
        /// and no prior seeding can fully undo that mixing.
        public let spillDepth: [Float]
        public let spillStrength: [Float]
    }

    /// Prior floor: the push-pull prior's weight in the combined value field,
    /// so every cell has a defined value even with no measurement anywhere
    /// nearby. Small enough that any real measurement dominates.
    static let priorFloor: Float = 1e-4
    /// Push-pull saturation: a level's own weight beyond which coarser levels
    /// stop contributing during the push phase.
    static let pushPullTau: Float = 1e-3
    /// Tier-2 vote scale: an aggregate-curve depth opinion never outvotes
    /// real per-pixel seeds.
    static let tier2Scale: Float = 0.1
    /// Spill-floor (tier-S) vote scale: below tier 2 so it never outvotes a
    /// real depth opinion, but decisively above `pushPullTau` so the pyramid
    /// doesn't dilute it — in signal-free regions the finest level's spill
    /// vote must win over coarser mean-of-region diffusion.
    static let spillScale: Float = 0.05
    /// Variance stabilizer for the adaptive-epsilon (WGIF) weighting.
    static let lambda: Float = 1e-6
    /// Below this max combined confidence the stage reports "no signal
    /// anywhere" (nil) and the caller keeps the median depth unchanged.
    static let minSignal: Float = 1e-3

    // MARK: - Grid stage

    /// The shared grid-resolution stage: assembles the three data tiers,
    /// fits confidence-weighted adaptive-ε guided-filter coefficients against
    /// the normalized grid guide, and box-smooths them. Returns nil when no
    /// cell holds any confidence (degenerate stack — caller falls back to the
    /// unregularized median depth).
    ///
    /// - Parameters:
    ///   - confidence: full-res confidence plane (noise floor × concentration).
    ///   - depthMed: full-res depth after the confidence-weighted median.
    ///   - guide: full-res mean gain-corrected stack luminance.
    ///   - planes: retained per-frame sharpness planes at the grid (may be
    ///     empty; tier 2 then contributes nothing).
    /// `isStale` (polled from worker threads) aborts the fit early with nil
    /// when the caller will discard the result anyway — tier-2 aggregation
    /// dominates the cost, so it polls per row.
    public static func gridCoefficients(confidence: [Float], depthMed: [Float],
                                        guide: [Float], width: Int, height: Int,
                                        planes: [[Float]],
                                        luminancePlanes: [[Float]] = [],
                                        factor: Int,
                                        frameCount: Int,
                                        options: DMapFusion.Options,
                                        log: ((String) -> Void)? = nil,
                                        isStale: (@Sendable () -> Bool)? = nil) -> Coefficients? {
        let gw = (width + factor - 1) / factor
        let gh = (height + factor - 1) / factor
        let gridCount = gw * gh

        // Normalized grid guide: unit-free ε, and the one scalar the full-res
        // apply pass must reuse.
        let gridGuide = DMapFusion.boxDownsample(guide, width: width, height: height,
                                                 factor: factor)
        let s = 1 / max(DMapFusion.percentile95(gridGuide), 1e-6)
        var g = gridGuide
        for i in g.indices { g[i] *= s }

        // Tier 1: confidence and confidence-weighted median depth, box-reduced
        // to the grid. Downsampling conf and conf·d separately keeps the grid
        // value a confidence-weighted average of the cell's depths.
        let cG = DMapFusion.boxDownsample(confidence, width: width, height: height,
                                          factor: factor)
        var cd = [Float](repeating: 0, count: width * height)
        confidence.withUnsafeBufferPointer { cp in
            depthMed.withUnsafeBufferPointer { dp in
                cd.withUnsafeMutableBufferPointer { op in
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for i in (y * width)..<((y + 1) * width) {
                            op[i] = cp[i] * dp[i]
                        }
                    }
                }
            }
        }
        let cdG = DMapFusion.boxDownsample(cd, width: width, height: height,
                                           factor: factor)

        // Tier 2: de-wedged basin refinement. Per grid cell, aggregate the
        // sharpness curves of a 5×5-cell neighborhood masked by (1 − c_g) —
        // the mask keeps confident subject energy from leaking a depth vote
        // across the silhouette rim — and score the aggregate with the same
        // concentration test pixels use. Aggregation cancels per-pixel noise,
        // so the soft peak of a barely-in-range surface emerges even where no
        // single pixel could seed.
        // Ablation switches for algorithm evaluation only (debug, like the
        // HYPERFOCAL_DUMP_* dumps): disable tier 2, its rim mask, or the
        // adaptive epsilon to measure what each contributes.
        let env = ProcessInfo.processInfo.environment
        let noTier2 = env["HYPERFOCAL_GUIDED_NO_TIER2"] != nil
        let noTier2Mask = env["HYPERFOCAL_GUIDED_NO_TIER2_MASK"] != nil
        let fixedEps = env["HYPERFOCAL_GUIDED_FIXED_EPS"] != nil

        var d2 = [Float](repeating: 0, count: gridCount)
        var c2 = [Float](repeating: 0, count: gridCount)
        if planes.count > 2, options.peakConcentration > 0, !noTier2 {
            let n = planes.count
            let window = max(2, n / 16)
            let threshold = options.peakConcentration
            d2.withUnsafeMutableBufferPointer { d2p in
                c2.withUnsafeMutableBufferPointer { c2p in
                    cG.withUnsafeBufferPointer { cgp in
                        DispatchQueue.concurrentPerform(iterations: gh) { gy in
                            if isStale?() == true { return }
                            var curve = [Float](repeating: 0, count: n)
                            var scratch = [Float](repeating: 0, count: n)
                            for gx in 0..<gw {
                                for f in 0..<n { curve[f] = 0 }
                                for ny in max(gy - 2, 0)...min(gy + 2, gh - 1) {
                                    for nx in max(gx - 2, 0)...min(gx + 2, gw - 1) {
                                        let j = ny * gw + nx
                                        let mask = noTier2Mask ? 1 : 1 - cgp[j]
                                        guard mask > 0 else { continue }
                                        for f in 0..<n {
                                            curve[f] += mask * planes[f][j]
                                        }
                                    }
                                }
                                if let scored = DMapFusion.concentratedArgmax(
                                        curve: curve, window: window,
                                        concThreshold: threshold,
                                        scratch: &scratch) {
                                    let i = gy * gw + gx
                                    d2p[i] = scored.depth
                                    c2p[i] = tier2Scale * scored.concentration
                                }
                            }
                        }
                    }
                }
            }
        }

        if isStale?() == true { return nil }

        // No measurable signal anywhere: nothing to regularize toward.
        var maxSignal: Float = 0
        for i in 0..<gridCount { maxSignal = max(maxSignal, cG[i] + c2[i]) }
        guard maxSignal >= minSignal else {
            log?("guided regularizer: no confident signal — depth left unregularized")
            return nil
        }

        // Tier S: spill floor. A signal-free pixel next to a subject shows
        // nothing of its own — every photon it ever receives is defocus
        // spill from the subject, which only ever *adds* light. The frame
        // where the cell is darkest is therefore the least-contaminated one
        // (the adjacent subject in focus), and that is the right depth to
        // render — without it the prior interpolates toward the regional
        // mean of subject depths, and those mid-stack frames carry the
        // subject's glow straight into the background (the halo). Weighted
        // by how much the cell's luminance swings across the stack (no
        // swing → no spill → nothing to protect against) and masked by
        // confidence, so cells with any real vote are untouched.
        let noSpill = env["HYPERFOCAL_GUIDED_NO_SPILL"] != nil
        var dS = [Float](repeating: 0, count: gridCount)
        var wS = [Float](repeating: 0, count: gridCount)
        var sS = [Float](repeating: 0, count: gridCount)  // 0…1 evidence strength
        if luminancePlanes.count > 2, !noSpill {
            let n = luminancePlanes.count
            var lMaxPlane = [Float](repeating: 0, count: gridCount)
            var spanPlane = [Float](repeating: 0, count: gridCount)
            lMaxPlane.withUnsafeMutableBufferPointer { mp in
                spanPlane.withUnsafeMutableBufferPointer { sp in
                    dS.withUnsafeMutableBufferPointer { dp in
                        DispatchQueue.concurrentPerform(iterations: gh) { gy in
                            if isStale?() == true { return }
                            for gx in 0..<gw {
                                let i = gy * gw + gx
                                var lo: Float = .infinity
                                var hi: Float = -.infinity
                                var argmin = 0
                                for f in 0..<n {
                                    let l = luminancePlanes[f][i]
                                    if l < lo { lo = l; argmin = f }
                                    if l > hi { hi = l }
                                }
                                mp[i] = hi
                                sp[i] = hi - lo
                                dp[i] = Float(argmin)
                            }
                        }
                    }
                }
            }
            // Absolute significance floor: black-noise cells (span at the
            // sensor floor) hold no spill evidence and stay with diffusion.
            // 0.2% of the scene's bright end — glow is dim in linear light,
            // and the relative term already shields static surfaces, so this
            // only needs to clear sensor noise.
            let spanEps = 0.002 * max(DMapFusion.percentile95(lMaxPlane), 1e-6)
            let spanEps2 = spanEps * spanEps
            sS.withUnsafeMutableBufferPointer { ssp in
                wS.withUnsafeMutableBufferPointer { wp in
                    lMaxPlane.withUnsafeBufferPointer { mp in
                        spanPlane.withUnsafeBufferPointer { sp in
                            cG.withUnsafeBufferPointer { cgp in
                                DispatchQueue.concurrentPerform(iterations: gh) { gy in
                                    for gx in 0..<gw {
                                        let i = gy * gw + gx
                                        let span = sp[i]
                                        // Relative swing ≈ 1 for spill over black,
                                        // small for any static surface (defocus
                                        // preserves a cell's mean); absolute gate
                                        // keeps noise-only cells out.
                                        let rel = span / (mp[i] + 1e-6)
                                        let sig = span * span / (span * span + spanEps2)
                                        ssp[i] = rel * sig * max(1 - min(cgp[i], 1), 0)
                                        wp[i] = spillScale * ssp[i]
                                    }
                                }
                            }
                        }
                    }
                }
            }
            DMapFusion.dumpPlane(wS, env: "HYPERFOCAL_DUMP_SPILLW")
            DMapFusion.dumpPlane(dS, env: "HYPERFOCAL_DUMP_SPILLD")
        }

        if isStale?() == true { return nil }

        // Tier 3: push-pull prior over the tier-1+2+S measurements — a dense,
        // scale-free interpolation that gives far-from-any-signal cells a
        // sane value for the α floor to lean on. Tier-1 weight is discounted
        // by spill strength: a cell whose luminance tracks the *frame* is
        // seeing defocus spill, and any sharpness it measured is the glow's
        // own edge — near-rim glow is bright enough to clear the noise floor,
        // so no confidence threshold catches it.
        var vw = [Float](repeating: 0, count: gridCount)
        var wt = [Float](repeating: 0, count: gridCount)
        for i in 0..<gridCount {
            let keep = 1 - sS[i]
            vw[i] = cdG[i] * keep + c2[i] * d2[i] + wS[i] * dS[i]
            wt[i] = cG[i] * keep + c2[i] + wS[i]
        }
        let dPP = pushPull(valueWeight: vw, weight: wt, width: gw, height: gh)

        // Combined weighted value field.
        var w = [Float](repeating: 0, count: gridCount)
        var v = [Float](repeating: 0, count: gridCount)
        for i in 0..<gridCount {
            w[i] = wt[i] + priorFloor
            v[i] = (vw[i] + priorFloor * dPP[i]) / w[i]
        }

        // WGIF: w-weighted guide/value moments over clipped box windows,
        // adaptive ε (Γ ≫ 1 at strong guide edges keeps them; Γ < 1 in flat
        // regions smooths harder), then linear coefficients.
        let r = max(1, Int((options.guidedRadius / Float(factor)).rounded()))
        var wg = [Float](repeating: 0, count: gridCount)
        var wv = [Float](repeating: 0, count: gridCount)
        var wgg = [Float](repeating: 0, count: gridCount)
        var wgv = [Float](repeating: 0, count: gridCount)
        for i in 0..<gridCount {
            wg[i] = w[i] * g[i]
            wv[i] = w[i] * v[i]
            wgg[i] = w[i] * g[i] * g[i]
            wgv[i] = w[i] * g[i] * v[i]
        }
        let satW = SummedAreaTable(w, width: gw, height: gh)
        let satWG = SummedAreaTable(wg, width: gw, height: gh)
        let satWV = SummedAreaTable(wv, width: gw, height: gh)
        let satWGG = SummedAreaTable(wgg, width: gw, height: gh)
        let satWGV = SummedAreaTable(wgv, width: gw, height: gh)

        var muG = [Float](repeating: 0, count: gridCount)
        var muV = [Float](repeating: 0, count: gridCount)
        var varG = [Float](repeating: 0, count: gridCount)
        var covGV = [Float](repeating: 0, count: gridCount)
        muG.withUnsafeMutableBufferPointer { mgp in
            muV.withUnsafeMutableBufferPointer { mvp in
                varG.withUnsafeMutableBufferPointer { vgp in
                    covGV.withUnsafeMutableBufferPointer { cvp in
                        DispatchQueue.concurrentPerform(iterations: gh) { y in
                            if isStale?() == true { return }
                            for x in 0..<gw {
                                let i = y * gw + x
                                let sw = satW.boxSum(x: x, y: y, radius: r)
                                let mg = satWG.boxSum(x: x, y: y, radius: r) / sw
                                let mv = satWV.boxSum(x: x, y: y, radius: r) / sw
                                mgp[i] = Float(mg)
                                mvp[i] = Float(mv)
                                vgp[i] = Float(max(satWGG.boxSum(x: x, y: y, radius: r) / sw
                                                   - mg * mg, 0))
                                cvp[i] = Float(satWGV.boxSum(x: x, y: y, radius: r) / sw
                                               - mg * mv)
                            }
                        }
                    }
                }
            }
        }

        if isStale?() == true { return nil }

        var invVarSum = 0.0
        for i in 0..<gridCount { invVarSum += 1 / Double(varG[i] + lambda) }
        let meanInvVar = Float(invVarSum / Double(gridCount))

        var a = [Float](repeating: 0, count: gridCount)
        var b = [Float](repeating: 0, count: gridCount)
        let eps = options.guidedEps
        for i in 0..<gridCount {
            let gamma = fixedEps ? 1 : (varG[i] + lambda) * meanInvVar
            a[i] = covGV[i] / (varG[i] + eps / gamma)
            b[i] = muV[i] - a[i] * muG[i]
        }

        // Uniform box-mean of the coefficients (the guided-filter smoothing
        // step): edges still come through at full sharpness via the guide,
        // only the *fit* varies smoothly.
        let aggDiv = Int(env["HYPERFOCAL_GUIDED_AGG_DIV"] ?? "") ?? 1
        let rAgg = max(1, r / max(1, aggDiv))
        let aBar = boxMean(a, width: gw, height: gh, radius: rAgg)
        let bBar = boxMean(b, width: gw, height: gh, radius: rAgg)

        log?(String(format: "guided regularizer: r=%d cells, eps=%g, guide scale %.4f",
                    r, eps, s))
        return Coefficients(a: aBar, b: bBar, gridWidth: gw, gridHeight: gh,
                            guideScale: s, factor: factor,
                            spillDepth: dS, spillStrength: sS)
    }

    // MARK: - Full-res apply (CPU)

    /// Full-resolution apply + preservation blend: sample the smoothed
    /// coefficients bilinearly (center-aligned grid mapping), evaluate the
    /// local linear model on the normalized full-res guide, then blend the
    /// regularized depth with the median depth by confidence — confident
    /// pixels keep their argmax exactly. The GPU kernel mirrors this
    /// arithmetic operation for operation.
    ///
    /// The blend is residual-aware: the fit is a *prior* for weak data, and
    /// a pixel that passed both confidence gates while its neighborhood-
    /// median depth sits far from the fit is proof the local linear model is
    /// wrong for that pixel — a luminance outlier the regression can only
    /// extrapolate through (a white specular on a dark subject reads as
    /// "brighter than background", so the fit maps it past background
    /// depth). There, trust the measurement. Gated on confidence so the
    /// low-confidence pixels that halo control depends on stay fully with
    /// the regularizer.
    /// `consensus` (optional, from the weighted median) is dense-voting
    /// evidence: individually-weak votes that agree — shadowed texture where
    /// every pixel measures the same depth — deserve trust that per-pixel
    /// confidence can't grant. Effective confidence is max(conf, consensus²);
    /// scattered noise votes converge to ~(2·window+1)/frames by chance, and
    /// squaring keeps that chance level negligible.
    public static func applyBlend(coefficients c: Coefficients, guide: [Float],
                                  confidence: [Float], depthMed: [Float],
                                  consensus: [Float]? = nil,
                                  width: Int, height: Int,
                                  frameCount: Int) -> [Float] {
        let maxIndex = Float(frameCount - 1)
        let gw = c.gridWidth, gh = c.gridHeight
        let invFactor = 1 / Float(c.factor)
        let scale = c.guideScale
        // Residual scale: disagreement beyond a DoF-window of frames means
        // the fit picked a visibly different focus (same window the peak-
        // concentration test uses).
        let rw = Float(max(2, frameCount / 16))
        let rw2 = rw * rw
        let gateLo = Float(ProcessInfo.processInfo.environment["HYPERFOCAL_GUIDED_GATE_LO"] ?? "")
            ?? 0.35
        let cons = consensus ?? []
        let hasConsensus = cons.count == width * height
        let hasSpill = c.spillDepth.count == gw * gh && c.spillStrength.count == gw * gh
        var out = [Float](repeating: 0, count: width * height)
        c.a.withUnsafeBufferPointer { ap in
        c.b.withUnsafeBufferPointer { bp in
        c.spillDepth.withUnsafeBufferPointer { sdp in
        c.spillStrength.withUnsafeBufferPointer { ssp in
        guide.withUnsafeBufferPointer { gp in
        confidence.withUnsafeBufferPointer { cp in
        depthMed.withUnsafeBufferPointer { dp in
        cons.withUnsafeBufferPointer { np in
        out.withUnsafeMutableBufferPointer { op in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let gy = min(max((Float(y) + 0.5) * invFactor - 0.5, 0), Float(gh - 1))
                let y0 = min(Int(gy), gh - 1)
                let y1 = min(y0 + 1, gh - 1)
                let fy = gy - Float(y0)
                for x in 0..<width {
                    let gx = min(max((Float(x) + 0.5) * invFactor - 0.5, 0), Float(gw - 1))
                    let x0 = min(Int(gx), gw - 1)
                    let x1 = min(x0 + 1, gw - 1)
                    let fx = gx - Float(x0)
                    let i00 = y0 * gw + x0, i01 = y0 * gw + x1
                    let i10 = y1 * gw + x0, i11 = y1 * gw + x1
                    let aS = (ap[i00] * (1 - fx) + ap[i01] * fx) * (1 - fy)
                           + (ap[i10] * (1 - fx) + ap[i11] * fx) * fy
                    let bS = (bp[i00] * (1 - fx) + bp[i01] * fx) * (1 - fy)
                           + (bp[i10] * (1 - fx) + bp[i11] * fx) * fy
                    let i = y * width + x
                    var dReg = aS * (scale * gp[i]) + bS
                    let agreement = hasConsensus ? np[i] : 0
                    var cf = max(cp[i], agreement * agreement)
                    if hasSpill {
                        // Spill discount + pull. Luminance that tracks the
                        // *frame* is defocus spill; sharpness measured there
                        // is the glow's own edge, and its votes agree as
                        // coherently as real texture — so the swing evidence
                        // must discount the trust itself (near-rim glow
                        // clears the noise floor, and consensus would
                        // otherwise promote it to full confidence). What
                        // trust remains after the discount still wins;
                        // the rest pulls toward the darkest (least-
                        // contaminated) frame.
                        let sSm = (ssp[i00] * (1 - fx) + ssp[i01] * fx) * (1 - fy)
                                + (ssp[i10] * (1 - fx) + ssp[i11] * fx) * fy
                        let dSm = (sdp[i00] * (1 - fx) + sdp[i01] * fx) * (1 - fy)
                                + (sdp[i10] * (1 - fx) + sdp[i11] * fx) * fy
                        cf *= 1 - sSm
                        let pull = sSm * (1 - cf)
                        dReg += pull * (dSm - dReg)
                    }
                    let r = dReg - dp[i]
                    let t = r * r / (r * r + rw2)
                    let s = min(max((cf - gateLo) / 0.35, 0), 1)
                    let gate = s * s * (3 - 2 * s)
                    let cb = cf + (1 - cf) * (t * gate)
                    op[i] = min(max(cb * dp[i] + (1 - cb) * dReg, 0), maxIndex)
                }
            }
        }}}}}}}}}
        return out
    }

    // MARK: - Push-pull prior

    /// Classic pull-push scattered-data interpolation over (value·weight,
    /// weight) pairs: average both down a 2× pyramid, then walk back up
    /// letting each level's own measurements dominate wherever their weight
    /// exceeds τ and coarser values fill the rest. Dense output — every cell
    /// gets the weight-nearest measurement's neighborhood average, at the
    /// scale where measurements exist.
    static func pushPull(valueWeight: [Float], weight: [Float],
                         width: Int, height: Int) -> [Float] {
        var vws = [valueWeight]
        var ws = [weight]
        var dims = [(w: width, h: height)]

        while dims.last!.w > 1 || dims.last!.h > 1 {
            let (w, h) = dims.last!
            let dw = (w + 1) / 2, dh = (h + 1) / 2
            var dvw = [Float](repeating: 0, count: dw * dh)
            var dwt = [Float](repeating: 0, count: dw * dh)
            let vwFine = vws.last!, wFine = ws.last!
            for dy in 0..<dh {
                let y0 = dy * 2, y1 = min(y0 + 2, h)
                for dx in 0..<dw {
                    let x0 = dx * 2, x1 = min(x0 + 2, w)
                    var sv: Float = 0, sw: Float = 0
                    for y in y0..<y1 {
                        for x in x0..<x1 {
                            sv += vwFine[y * w + x]
                            sw += wFine[y * w + x]
                        }
                    }
                    let n = Float((y1 - y0) * (x1 - x0))
                    dvw[dy * dw + dx] = sv / n
                    dwt[dy * dw + dx] = sw / n
                }
            }
            vws.append(dvw)
            ws.append(dwt)
            dims.append((dw, dh))
        }

        // Coarsest cell: the global weighted mean (weight > 0 is guaranteed
        // by the caller's signal check; 0 is a safe degenerate value).
        let topW = ws.last![0]
        var v = [topW > 0 ? vws.last![0] / topW : 0]

        for level in stride(from: dims.count - 2, through: 0, by: -1) {
            let (w, h) = dims[level]
            let (cw, ch) = dims[level + 1]
            let vwL = vws[level], wL = ws[level]
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let fy = min(max((Float(y) + 0.5) * Float(ch) / Float(h) - 0.5, 0),
                             Float(ch - 1))
                let y0 = min(Int(fy), ch - 1)
                let y1 = min(y0 + 1, ch - 1)
                let ty = fy - Float(y0)
                for x in 0..<w {
                    let fx = min(max((Float(x) + 0.5) * Float(cw) / Float(w) - 0.5, 0),
                                 Float(cw - 1))
                    let x0 = min(Int(fx), cw - 1)
                    let x1 = min(x0 + 1, cw - 1)
                    let tx = fx - Float(x0)
                    let vUp = (v[y0 * cw + x0] * (1 - tx) + v[y0 * cw + x1] * tx) * (1 - ty)
                            + (v[y1 * cw + x0] * (1 - tx) + v[y1 * cw + x1] * tx) * ty
                    let i = y * w + x
                    out[i] = (vwL[i] + pushPullTau * vUp) / (wL[i] + pushPullTau)
                }
            }
            v = out
        }
        return v
    }

    // MARK: - Box sums

    /// Clipped uniform box mean (window intersected with the plane, no edge
    /// padding — padding would bias coefficients toward border values).
    static func boxMean(_ plane: [Float], width: Int, height: Int,
                        radius: Int) -> [Float] {
        let sat = SummedAreaTable(plane, width: width, height: height)
        var out = [Float](repeating: 0, count: width * height)
        out.withUnsafeMutableBufferPointer { op in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let y0 = max(y - radius, 0), y1 = min(y + radius, height - 1)
                for x in 0..<width {
                    let x0 = max(x - radius, 0), x1 = min(x + radius, width - 1)
                    let area = Double((y1 - y0 + 1) * (x1 - x0 + 1))
                    op[y * width + x] = Float(sat.boxSum(x: x, y: y, radius: radius) / area)
                }
            }
        }
        return out
    }

    /// Summed-area table in Double: exact clipped box sums at any radius in
    /// O(1) per query, deterministic (no parallel accumulation order).
    struct SummedAreaTable {
        let width: Int
        let height: Int
        private var table: [Double]  // (width+1) × (height+1), zero row/col first

        init(_ plane: [Float], width: Int, height: Int) {
            self.width = width
            self.height = height
            let tw = width + 1
            table = [Double](repeating: 0, count: tw * (height + 1))
            table.withUnsafeMutableBufferPointer { tp in
                plane.withUnsafeBufferPointer { pp in
                    for y in 0..<height {
                        var rowSum = 0.0
                        for x in 0..<width {
                            rowSum += Double(pp[y * width + x])
                            tp[(y + 1) * tw + x + 1] = tp[y * tw + x + 1] + rowSum
                        }
                    }
                }
            }
        }

        /// Sum over the window centered at (x, y) with the given radius,
        /// clipped to the plane.
        func boxSum(x: Int, y: Int, radius: Int) -> Double {
            let x0 = max(x - radius, 0), y0 = max(y - radius, 0)
            let x1 = min(x + radius, width - 1), y1 = min(y + radius, height - 1)
            let tw = width + 1
            return table[(y1 + 1) * tw + x1 + 1] - table[y0 * tw + x1 + 1]
                 - table[(y1 + 1) * tw + x0] + table[y0 * tw + x0]
        }
    }
}
