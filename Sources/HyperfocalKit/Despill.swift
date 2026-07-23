import Foundation

/// Render-stage rim despill. Fusion leaves a low-frequency defocus-spill
/// "glow" hugging a specimen's silhouette (the halo Helicon crushes); this
/// pass removes it, in image space, on the fused buffer — down to a
/// spatially-reconstructed dark floor, shielded from the in-focus subject by
/// an edge-aware guided upsample.
///
/// It is shared CPU code: it runs identically on any engine's fused
/// `ImageBuffer`, so CPU/GPU parity is *inherited* from its grid inputs (see
/// `DespillInputs`), never re-derived here.
///
/// Domain: the working buffer is sRGB-**encoded** Display P3 (display-referred
/// — `ToneCurve` and `DNGWriter` both linearize it before use), NOT
/// scene-linear. Spill is additive light, so the correction is computed and
/// applied in LINEAR light: linearize, subtract, re-encode. (An earlier mockup
/// that subtracted in encoded space rang at the silhouette; don't.) In the
/// dark toe where despill actually operates, `srgbLinearize` is a pure 1/12.92
/// scale, so linearizing the encoded luminance floor equals the true linear
/// luminance there — floor and image luminance stay comparable.
public enum Despill {

    /// Grid-resolution inputs the pass consumes, produced inside fusion while
    /// the per-frame luminance planes and the winner-luminance guide are still
    /// alive (they don't otherwise survive fusion). All planes are row-major,
    /// `gridWidth × gridHeight`, at the 8-px sharpness grid.
    public struct DespillInputs: Sendable {
        public let gridWidth: Int
        public let gridHeight: Int
        public let factor: Int
        /// Robust per-cell dark floor — mean of the k darkest frames, LINEAR
        /// luminance. This is the primary subtract-down-to target: a pixel's
        /// excess over its own darkest aligned frame is exactly the light spill
        /// added it, so subtracting to here removes the glow and leaves the
        /// physical rim tail (which survives into the darkest frame). A cell
        /// bright in *every* frame has `L ≈ perCellFloor` → excess ≈ 0 → it is
        /// self-protecting, no separate gate needed.
        public let perCellFloor: [Float]
        /// The regularizer's own spill-strength (0…1), the gate that decides
        /// WHERE to correct. It is the only signal that separates the in-focus
        /// subject from the defocus glow here: brightness, guide, local
        /// structure, confidence, and concentration all fail on the smooth
        /// bright matrix rock (low texture → low confidence/concentration; as
        /// dim in the guide as the glow), but spill-strength reads it as
        /// subject because a large uniform patch barely swings under defocus
        /// (low `rel`), while the glow — spill over near-black — swings hard.
        /// High = spill (correct); low = real signal (protect).
        public let spillStrength: [Float]

        public init(gridWidth: Int, gridHeight: Int, factor: Int,
                    perCellFloor: [Float], spillStrength: [Float]) {
            self.gridWidth = gridWidth
            self.gridHeight = gridHeight
            self.factor = factor
            self.perCellFloor = perCellFloor
            self.spillStrength = spillStrength
        }
    }

    // MARK: - Input preparation (shared, parity-carrying)

    /// Builds the despill grid inputs from a fusion engine's retained
    /// per-frame grid luminance planes (gain-corrected, encoded) and the
    /// regularizer's spill-strength grid. Returns `nil` for degenerate stacks
    /// (< 3 frames, missing/mismatched spill grid), in which case the caller
    /// leaves `Output.despill` nil and the pass is a no-op.
    ///
    /// Env knobs (A/B tuning; sensible defaults):
    /// - `HYPERFOCAL_DESPILL_DARKK` (k, default 3): frames averaged for the floor.
    public static func computeInputs(luminancePlanes: [[Float]],
                                     spillStrength: [Float], spillWidth: Int, spillHeight: Int,
                                     width: Int, height: Int, factor: Int,
                                     log: ((String) -> Void)? = nil) -> DespillInputs? {
        let gw = (width + factor - 1) / factor
        let gh = (height + factor - 1) / factor
        let gridCount = gw * gh
        guard luminancePlanes.count > 2,
              spillStrength.count == gridCount, spillWidth == gw, spillHeight == gh,
              luminancePlanes.allSatisfy({ $0.count == gridCount }) else { return nil }
        let env = ProcessInfo.processInfo.environment
        let k = min(max(1, Int(env["HYPERFOCAL_DESPILL_DARKK"] ?? "") ?? 3),
                    luminancePlanes.count)

        // Per-cell robust dark floor: mean of the k darkest frames, linearized.
        let n = luminancePlanes.count
        var perCellFloor = [Float](repeating: 0, count: gridCount)
        perCellFloor.withUnsafeMutableBufferPointer { fp in
            DispatchQueue.concurrentPerform(iterations: gh) { gy in
                var smallest = [Float](repeating: .infinity, count: k)
                for gx in 0..<gw {
                    let i = gy * gw + gx
                    for j in 0..<k { smallest[j] = .infinity }
                    for f in 0..<n {
                        let l = luminancePlanes[f][i]
                        if l < smallest[k - 1] {
                            var p = k - 1
                            while p > 0 && smallest[p - 1] > l {
                                smallest[p] = smallest[p - 1]; p -= 1
                            }
                            smallest[p] = l
                        }
                    }
                    var s: Float = 0
                    for j in 0..<k { s += ToneCurve.srgbLinearize(max(smallest[j], 0)) }
                    fp[i] = s / Float(k)
                }
            }
        }

        log?(String(format: "despill inputs: grid %dx%d, k=%d", gw, gh, k))
        return DespillInputs(gridWidth: gw, gridHeight: gh, factor: factor,
                             perCellFloor: perCellFloor, spillStrength: spillStrength)
    }

    /// Reconstructs the clean-background level across the whole grid by
    /// push-pull from the near-black backdrop cells (soft near-black
    /// membership so the glow band — a few× the backdrop — stays out of the
    /// anchor set). Lives in `apply`, not `computeInputs`, so its knobs tune
    /// without a re-fuse. Env: `HYPERFOCAL_DESPILL_BACKDROP_PCT` (default 0.20),
    /// `_NB_LO_MULT` / `_NB_HI_MULT` (default 2 / 5, × backdrop).
    static func reconstructBackdrop(perCellFloor: [Float], width gw: Int, height gh: Int,
                                    env: [String: String]) -> (plane: [Float], backdrop: Float) {
        let gridCount = gw * gh
        let backdrop = max(percentileLow(perCellFloor,
                           Float(env["HYPERFOCAL_DESPILL_BACKDROP_PCT"] ?? "") ?? 0.20), 1e-9)
        let nbLo = (Float(env["HYPERFOCAL_DESPILL_NB_LO_MULT"] ?? "") ?? 2) * backdrop
        let nbHi = max((Float(env["HYPERFOCAL_DESPILL_NB_HI_MULT"] ?? "") ?? 5) * backdrop,
                       nbLo + 1e-9)
        var vw = [Float](repeating: 0, count: gridCount)
        var wt = [Float](repeating: 0, count: gridCount)
        var wsum: Double = 0
        for i in 0..<gridCount {
            let cleanW = 1 - smoothstep(nbLo, nbHi, perCellFloor[i])
            vw[i] = perCellFloor[i] * cleanW
            wt[i] = cleanW
            wsum += Double(cleanW)
        }
        guard wsum > Double(gridCount) * 0.001 else {
            return ([Float](repeating: backdrop, count: gridCount), backdrop)
        }
        return (DepthRegularize.pushPull(valueWeight: vw, weight: wt, width: gw, height: gh),
                backdrop)
    }

    // MARK: - Apply (shared, image-space)

    /// Subtracts the rim glow from `image` in place. `intensity` 0…1 scales the
    /// correction (0 = no-op). All thresholds are env-overridable for A/B tuning
    /// without re-fusing:
    /// - `HYPERFOCAL_DESPILL_SPILL_LO` / `_SPILL_HI` (default 0.42 / 0.55): the
    ///   spill-strength gate edges — the primary subject/glow discriminator.
    /// - `HYPERFOCAL_DESPILL_SPILL_DILATE` (default 1 cell): grow the spill gate
    ///   before upsampling so the thin rim band keeps a full gate at the
    ///   silhouette (over-growth onto the rock is held by the safety + bound).
    /// - `HYPERFOCAL_DESPILL_CONTAM_LO` / `_CONTAM_HI` (default 20 / 80): the
    ///   per-cell floor is trusted as the subtract target until its ratio to the
    ///   global backdrop crosses this band, past which the target falls back to
    ///   the reconstructed backdrop (glow-flooded concavities / rock-mixed cells).
    /// - `HYPERFOCAL_DESPILL_RADIUS` (default 8 grid cells): guided-filter box.
    /// - `HYPERFOCAL_DESPILL_EPS` (default 0.01): guided edge-stop, as a
    ///   fraction of the grid luminance p95.
    /// - `HYPERFOCAL_DESPILL_LSHIELD_REF` / `_LO` / `_HI` (default 0.99 / 0.3 /
    ///   0.9): brightness safety — hard-protects the smooth matrix rock, whose
    ///   spill-strength sits a thin margin below the glow's.
    public static func apply(to image: inout ImageBuffer, inputs: DespillInputs,
                             intensity: Float, log: ((String) -> Void)? = nil) {
        let amount = min(max(intensity, 0), 1)
        guard amount > 0 else { return }
        let env = ProcessInfo.processInfo.environment
        let f = inputs.factor
        let gw = inputs.gridWidth, gh = inputs.gridHeight
        let gridCount = gw * gh
        let width = image.width, height = image.height
        guard gw == (width + f - 1) / f, gh == (height + f - 1) / f else {
            log?("despill: input grid does not match image — skipped"); return
        }

        // Full-res linear luminance of the fused (encoded) image.
        var lFull = [Float](repeating: 0, count: width * height)
        image.pixels.withUnsafeBufferPointer { px in
            lFull.withUnsafeMutableBufferPointer { lp in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    var pi = y * width * 4
                    for x in 0..<width {
                        let r = ToneCurve.srgbLinearize(max(px[pi], 0))
                        let g = ToneCurve.srgbLinearize(max(px[pi + 1], 0))
                        let b = ToneCurve.srgbLinearize(max(px[pi + 2], 0))
                        lp[y * width + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        pi += 4
                    }
                }
            }
        }
        let lGrid = DMapFusion.boxDownsample(lFull, width: width, height: height, factor: f)

        // Spill gate: the regularizer's spill-strength, smoothstepped, decides
        // WHERE to correct. It is the only signal that separates the in-focus
        // subject from the defocus glow (see DespillInputs.spillStrength). It
        // both weights the guided fit (so the fit describes the glow, not the
        // adjacent subject — the "plume" failure) and, upsampled, gates the
        // full-res correction so the subject is protected.
        let sLo = Float(env["HYPERFOCAL_DESPILL_SPILL_LO"] ?? "") ?? 0.42
        let sHi = max(Float(env["HYPERFOCAL_DESPILL_SPILL_HI"] ?? "") ?? 0.55, sLo + 1e-6)
        var spillMask = [Float](repeating: 0, count: gridCount)
        for i in 0..<gridCount {
            spillMask[i] = smoothstep(sLo, sHi, inputs.spillStrength[i])
        }

        // Subtract-down-to target per cell: the darkest-frame floor, falling
        // back to the reconstructed backdrop where the per-cell floor is itself
        // glow-contaminated (ratio to the global backdrop exceeds the
        // contamination band — concave notches, rock-mixed cells).
        let (backdropInterp, backdrop) = reconstructBackdrop(
            perCellFloor: inputs.perCellFloor, width: gw, height: gh, env: env)
        let contamLo = Float(env["HYPERFOCAL_DESPILL_CONTAM_LO"] ?? "") ?? 20
        let contamHi = max(Float(env["HYPERFOCAL_DESPILL_CONTAM_HI"] ?? "") ?? 80, contamLo + 1e-6)
        var target = [Float](repeating: 0, count: gridCount)
        var excess = [Float](repeating: 0, count: gridCount)
        for i in 0..<gridCount {
            let contam = smoothstep(contamLo, contamHi, inputs.perCellFloor[i] / backdrop)
            let t = inputs.perCellFloor[i] * (1 - contam) + backdropInterp[i] * contam
            target[i] = t
            excess[i] = max(lGrid[i] - t, 0)
        }

        // Edge-aware upsample: WEIGHTED guided filter, weight = spill gate.
        // Fitting excess ≈ a·L + b with the subject weighted out keeps the
        // adjacent subject (excess large but not spill) from distorting the
        // glow's correction. The fit varies smoothly while the silhouette comes
        // through at full sharpness via the full-res guide (no Gaussian across
        // the edge → no fringe+moat couplet).
        let r = max(1, Int(env["HYPERFOCAL_DESPILL_RADIUS"] ?? "") ?? 8)
        let epsFrac = Float(env["HYPERFOCAL_DESPILL_EPS"] ?? "") ?? 0.01
        let gp95 = max(DMapFusion.percentile95(lGrid), 1e-8)
        let eps = Double(epsFrac * gp95) * Double(epsFrac * gp95)
        var wg = [Float](repeating: 0, count: gridCount)
        var wv = [Float](repeating: 0, count: gridCount)
        var wgg = [Float](repeating: 0, count: gridCount)
        var wgv = [Float](repeating: 0, count: gridCount)
        for i in 0..<gridCount {
            let w = spillMask[i], g = lGrid[i], v = excess[i]
            wg[i] = w * g; wv[i] = w * v; wgg[i] = w * g * g; wgv[i] = w * g * v
        }
        let satW = DepthRegularize.SummedAreaTable(spillMask, width: gw, height: gh)
        let satWG = DepthRegularize.SummedAreaTable(wg, width: gw, height: gh)
        let satWV = DepthRegularize.SummedAreaTable(wv, width: gw, height: gh)
        let satWGG = DepthRegularize.SummedAreaTable(wgg, width: gw, height: gh)
        let satWGV = DepthRegularize.SummedAreaTable(wgv, width: gw, height: gh)
        var a = [Float](repeating: 0, count: gridCount)
        var b = [Float](repeating: 0, count: gridCount)
        a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                DispatchQueue.concurrentPerform(iterations: gh) { y in
                    for x in 0..<gw {
                        let i = y * gw + x
                        let sw = satW.boxSum(x: x, y: y, radius: r)
                        guard sw > 1e-4 else { ap[i] = 0; bp[i] = 0; continue }
                        let mg = satWG.boxSum(x: x, y: y, radius: r) / sw
                        let mv = satWV.boxSum(x: x, y: y, radius: r) / sw
                        let vg = max(satWGG.boxSum(x: x, y: y, radius: r) / sw - mg * mg, 0)
                        let cov = satWGV.boxSum(x: x, y: y, radius: r) / sw - mg * mv
                        let ai = cov / (vg + eps)
                        ap[i] = Float(ai)
                        bp[i] = Float(mv - ai * mg)
                    }
                }
            }
        }
        let aBar = DepthRegularize.boxMean(a, width: gw, height: gh, radius: r)
        let bBar = DepthRegularize.boxMean(b, width: gw, height: gh, radius: r)
        if let dbg = env["HYPERFOCAL_DESPILL_DEBUG"] {
            func w(_ p: [Float], _ n: String) {
                p.withUnsafeBufferPointer {
                    try? Data(buffer: $0).write(to: URL(fileURLWithPath: dbg + "/" + n))
                }
            }
            w(lGrid, "lGrid.f32"); w(target, "target.f32"); w(excess, "excess.f32")
            w(spillMask, "spillMask.f32"); w(aBar, "aBar.f32"); w(bBar, "bBar.f32")
            w(backdropInterp, "backdropInterp.f32")
        }
        let aFull = Filters.resizePlaneBilinear(aBar, width: gw, height: gh,
                                                toWidth: width, toHeight: height)
        let bFull = Filters.resizePlaneBilinear(bBar, width: gw, height: gh,
                                                toWidth: width, toHeight: height)
        let floorFull = Filters.resizePlaneBilinear(target, width: gw, height: gh,
                                                    toWidth: width, toHeight: height)
        // Full-res spill gate: upsample the spill mask (the subject protector).
        // The thin rim glow band is only 1–2 cells wide with subject cells (low
        // spill) on one side; a plain bilinear upsample erodes its mask at the
        // silhouette and starves the correction (the glow survives). Dilate the
        // mask by a cell or two first: over-growing it onto the bright rock is
        // safe — the rock is independently held by the brightness safety and the
        // L−target bound — while it lets the glow band keep a full gate.
        let dilate = max(0, Int(env["HYPERFOCAL_DESPILL_SPILL_DILATE"] ?? "") ?? 1)
        let spillDilated = dilate > 0
            ? maxPool(spillMask, width: gw, height: gh, radius: dilate) : spillMask
        let spillFull = Filters.resizePlaneBilinear(spillDilated, width: gw, height: gh,
                                                    toWidth: width, toHeight: height)
        // Secondary safety: hard-protect the very brightest pixels (the smooth
        // matrix rock sits close to the glow in spill-strength, a thin margin).
        let lRock = max(percentileLow(lGrid, Float(env["HYPERFOCAL_DESPILL_LSHIELD_REF"] ?? "") ?? 0.99),
                        1e-8)
        let shFullLo = (Float(env["HYPERFOCAL_DESPILL_LSHIELD_LO"] ?? "") ?? 0.3) * lRock
        let shFullHi = max((Float(env["HYPERFOCAL_DESPILL_LSHIELD_HI"] ?? "") ?? 0.9) * lRock,
                           shFullLo + 1e-8)

        // Apply in linear light, per channel proportionally. Constraints:
        // correction never negative, never drives luminance below the spatial
        // floor (out ≥ floor → no over-subtracted moat). Where no correction
        // lands, the pixel is left bit-exact (no encode round-trip).
        var touched = 0
        image.pixels.withUnsafeMutableBufferPointer { px in
            lFull.withUnsafeBufferPointer { lp in
                aFull.withUnsafeBufferPointer { afp in
                    bFull.withUnsafeBufferPointer { bfp in
                        floorFull.withUnsafeBufferPointer { ffp in
                        spillFull.withUnsafeBufferPointer { spfp in
                            let counts = UnsafeMutablePointer<Int>.allocate(capacity: height)
                            counts.initialize(repeating: 0, count: height)
                            DispatchQueue.concurrentPerform(iterations: height) { y in
                                var pi = y * width * 4
                                var rowTouched = 0
                                for x in 0..<width {
                                    let idx = y * width + x
                                    let l = lp[idx]
                                    // Gate by spill (subject protector) and a
                                    // brightness safety for the smooth matrix rock.
                                    let sh = 1 - smoothstep(shFullLo, shFullHi, l)
                                    var corr = (afp[idx] * l + bfp[idx]) * amount * spfp[idx] * sh
                                    let bound = max(l - ffp[idx], 0)
                                    if corr > bound { corr = bound }
                                    if corr > 0 && l > 1e-8 {
                                        let scale = (l - corr) / l
                                        for c in 0..<3 {
                                            let lin = ToneCurve.srgbLinearize(max(px[pi + c], 0))
                                            px[pi + c] = ToneCurve.srgbEncode(lin * scale)
                                        }
                                        rowTouched += 1
                                    }
                                    pi += 4
                                }
                                counts[y] = rowTouched
                            }
                            for y in 0..<height { touched += counts[y] }
                            counts.deinitialize(count: height)
                            counts.deallocate()
                        }
                        }
                    }
                }
            }
        }
        log?(String(format: "despill: intensity %.2f, r=%d cells, eps frac %.3f, "
                    + "touched %.1f%% of pixels",
                    amount, r, epsFrac, 100 * Double(touched) / Double(width * height)))
    }

    // MARK: - Helpers

    /// Square dilation (clipped max filter) of a grid plane — grows high values
    /// into their neighborhood by `radius` cells.
    static func maxPool(_ plane: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        out.withUnsafeMutableBufferPointer { op in
            plane.withUnsafeBufferPointer { pp in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let y0 = max(y - radius, 0), y1 = min(y + radius, height - 1)
                    for x in 0..<width {
                        let x0 = max(x - radius, 0), x1 = min(x + radius, width - 1)
                        var m: Float = 0
                        for yy in y0...y1 {
                            for xx in x0...x1 { m = max(m, pp[yy * width + xx]) }
                        }
                        op[y * width + x] = m
                    }
                }
            }
        }
        return out
    }

    /// Hermite smoothstep, clamped. 0 at/below `e0`, 1 at/above `e1`.
    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        guard e1 > e0 else { return x < e0 ? 0 : 1 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Approximate low percentile via a strided subsample (matches
    /// `percentile95`'s cheap-and-robust style).
    static func percentileLow(_ plane: [Float], _ fraction: Float) -> Float {
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
