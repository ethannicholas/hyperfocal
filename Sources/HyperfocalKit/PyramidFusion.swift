import Foundation
import Dispatch
#if canImport(simd)
import simd
#endif

/// Per-frame alignment for a pyramid fusion whose `frame` closure returns
/// *unwarped* frames. The GPU path applies these homographies on-device
/// (`warp_lanczos3`) — the CPU Lanczos warp was ~55% of GPU-fusion
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
    ///    - The additive-dominance clause exists because track B's premise is
    ///      keep-darkest = least contaminated, which inverts when a *dark*
    ///      subject spreads into a brighter background. Measured on a
    ///      dark-specimens-on-white stack: with the sign test off, the band
    ///      beside every silhouette rendered *below the darkest source
    ///      frame's own rendition* (0.759 vs a frame floor of 0.785) — a dark
    ///      halo painted from light no frame contains. The commercial
    ///      reference never goes below the frame floor there. The sign is
    ///      decided against the component's far-field level (median midrange
    ///      of its uncontaminated pixels): contamination is additive where
    ///      the darkest rendition is the one that matches the far field.
    ///      Note the bright-backdrop model-train silhouette fails this test
    ///      too (its roofline is dark-on-bright) — keep-darkest crisped it at
    ///      the cost of the same undershoot, so that case correctly stays
    ///      gated OFF and remains open work: fixing it needs a track B that
    ///      keeps the frame *closest to the local clean level*, not an
    ///      extreme order statistic.
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
                             env: [String: String] = ProcessInfo.processInfo.environment)
        -> (masks: [[Float]], scale: Float, mean: Float, bgFraction: Float) {
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
        let scale = max(Despill.percentileLow(lumMin0, pct), 1e-6)
        let lo = lo0 * scale, hi = hi0 * scale
        var m0 = [Float](repeating: 1, count: lumMin0.count)
        var bgFraction: Float = 0
        if !off {
            for i in m0.indices { m0[i] = 1 - Despill.smoothstep(lo, hi, lumMin0[i]) }
            if env["HYPERFOCAL_PMAX_BG_OFF"] == nil,
               let bg = openBackground(focusMax0: focusMax0, focusMin0: focusMin0,
                                       lumMin0: lumMin0, lumMax0: lumMax0,
                                       frameCount: frameCount,
                                       width: width, height: height, env: env) {
                var n = 0
                for i in m0.indices where bg[i] {
                    m0[i] = 1
                    n += 1
                }
                bgFraction = Float(n) / Float(max(m0.count, 1))
            }
        }
        // Double accumulator: a Float sum saturates near 2^24, and a 45 MP
        // plane has ~3x that many elements — the logged mean pinned at ~0.39
        // regardless of the mask until this was widened.
        let mean = Float(m0.reduce(0.0) { $0 + Double($1) } / Double(max(m0.count, 1)))
        var masks = [[Float]](repeating: [], count: levels)
        for l in 1..<levels where l >= levels - darkCoarse {
            masks[l] = off
                ? [Float](repeating: 1, count: sizes[l].w * sizes[l].h)
                : maxPool(m0, width: width, height: height, factor: 1 << l)
        }
        DMapFusion.dumpPlane(lumMin0, env: "HYPERFOCAL_DUMP_LUMMIN0")
        DMapFusion.dumpPlane(m0, env: "HYPERFOCAL_DUMP_NEARBLACK")
        return (masks, scale, mean, bgFraction)
    }

    /// The open-background membership: true where the pixel belongs to a
    /// connected never-sharp field that reaches the frame border, whose focus
    /// energy never moves with the sweep, and whose contamination is
    /// *additive-dominant* (see `debloomMasks`). Nil when the planes are
    /// unavailable (a backend not yet accumulating them).
    static func openBackground(focusMax0: [Float], focusMin0: [Float],
                               lumMin0: [Float], lumMax0: [Float],
                               frameCount: Int, width: Int, height: Int,
                               env: [String: String]) -> [Bool]? {
        guard focusMax0.count == width * height,
              focusMin0.count == width * height,
              lumMin0.count == width * height,
              lumMax0.count == width * height, width > 2, height > 2 else { return nil }
        let alpha = Float(env["HYPERFOCAL_PMAX_BG_ALPHA"] ?? "") ?? 0.15
        let closeFrac = Float(env["HYPERFOCAL_PMAX_BG_CLOSE"] ?? "") ?? 0.0031
        // Contamination-range thresholds: a pixel is "clean" below rLo (its
        // renditions agree across frames) and "contaminated" above rHi.
        let rLo = Float(env["HYPERFOCAL_PMAX_BG_RLO"] ?? "") ?? 0.02
        let rHi = Float(env["HYPERFOCAL_PMAX_BG_RHI"] ?? "") ?? 0.04
        let voteCut = Float(env["HYPERFOCAL_PMAX_BG_VOTES"] ?? "") ?? 0.7
        let t = alpha * max(Despill.percentileLow(focusMax0, 0.99), 1e-6)
        let r = max(4, Int((closeFrac * Float(min(width, height))).rounded()))
        var sharp = [Bool](repeating: false, count: width * height)
        for i in sharp.indices { sharp[i] = focusMax0[i] > t }
        // Subject support = close(sharp, r): sharp structure plus the narrow
        // gaps between it. Small r on purpose — see the doc comment above.
        var subject = Morphology.dilate(sharp, width: width, height: height, radius: r)
        subject = Morphology.erode(subject, width: width, height: height, radius: r)

        // Components of the open (non-subject) field, with border contact and
        // a log2 histogram of the focus max/min ratio for the median.
        let comps = Morphology.components(open: subject.map { !$0 },
                                          width: width, height: height)
        // Never-focuses cutoff: max/min of pure noise grows with the frame
        // count (extreme order statistics), so the cutoff does too.
        let ratioCut = Float(env["HYPERFOCAL_PMAX_BG_RATIO"] ?? "")
            ?? min(max(3 * log2(Float(max(frameCount, 2))), 6), 32)
        let logCut = log2(ratioCut)
        let minSize = 1000
        let bins = 64
        let binScale: Float = 4  // bin = log2(ratio) * 4, clamped to [0, 63]
        var ratioHist = [Int](repeating: 0, count: comps.count * bins)
        // Clean-level histogram: midrange luminance over clean (low-range)
        // pixels, 256 bins over [0, 1] — its median is the component's
        // far-field level, the anchor the sign test compares extremes to.
        let farBins = 256
        var farHist = [Int](repeating: 0, count: comps.count * farBins)
        var farCount = [Int](repeating: 0, count: comps.count)
        for i in 0..<(width * height) where comps.labels[i] > 0 {
            let c = Int(comps.labels[i]) - 1
            let ratio = focusMax0[i] / max(focusMin0[i], 1e-6)
            let b = min(max(Int(log2(max(ratio, 1)) * binScale), 0), bins - 1)
            ratioHist[c * bins + b] += 1
            if lumMax0[i] - lumMin0[i] <= rLo {
                let mid = (lumMin0[i] + lumMax0[i]) * 0.5
                let fb = min(max(Int(mid * Float(farBins)), 0), farBins - 1)
                farHist[c * farBins + fb] += 1
                farCount[c] += 1
            }
        }
        var far = [Float](repeating: .nan, count: comps.count)
        for c in 0..<comps.count where farCount[c] >= 100 {
            var seen = 0
            for b in 0..<farBins {
                seen += farHist[c * farBins + b]
                if seen * 2 >= farCount[c] {
                    far[c] = (Float(b) + 0.5) / Float(farBins)
                    break
                }
            }
        }
        // Contamination-sign votes over contaminated pixels: additive when the
        // darkest rendition is the one matching the clean level (bloom only
        // ever added light there), subtractive when the brightest is.
        var addVotes = [Int](repeating: 0, count: comps.count)
        var hiRCount = [Int](repeating: 0, count: comps.count)
        for i in 0..<(width * height) where comps.labels[i] > 0 {
            let c = Int(comps.labels[i]) - 1
            guard lumMax0[i] - lumMin0[i] >= rHi, !far[c].isNaN else { continue }
            hiRCount[c] += 1
            if abs(lumMin0[i] - far[c]) < abs(lumMax0[i] - far[c]) { addVotes[c] += 1 }
        }
        var keep = [Bool](repeating: false, count: comps.count)
        for c in 0..<comps.count {
            guard comps.sizes[c] >= minSize, comps.touchesBorder[c],
                  !far[c].isNaN else { continue }
            var seen = 0
            var medianBin = bins - 1
            for b in 0..<bins {
                seen += ratioHist[c * bins + b]
                if seen * 2 >= comps.sizes[c] { medianBin = b; break }
            }
            guard Float(medianBin) / binScale < logCut else { continue }
            // Require enough contaminated pixels to judge the sign, and the
            // additive premise to dominate them. A component too small to
            // judge stays closed: "no evidence" turned out to mean "the
            // evidence didn't reach the count floor", and such components
            // beside a silhouette are mostly band — opening them is where a
            // residual dark halo came from.
            keep[c] = hiRCount[c] >= 100
                && Float(addVotes[c]) >= voteCut * Float(hiRCount[c])
        }
        var bg = [Bool](repeating: false, count: width * height)
        for i in bg.indices where comps.labels[i] > 0 {
            let c = Int(comps.labels[i]) - 1
            guard keep[c] else { continue }
            // Per-pixel veto: a clearly subtractive pixel (its brightest
            // rendition is the clean one) keeps the plain selection even
            // inside an additive-dominant component.
            if lumMax0[i] - lumMin0[i] >= rHi,
               abs(lumMax0[i] - far[c]) + 0.01 < abs(lumMin0[i] - far[c]) { continue }
            bg[i] = true
        }
        return bg
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

    static func collapse(_ pyramid: [ImageBuffer]) -> ImageBuffer {
        var current = pyramid[pyramid.count - 1]
        for l in stride(from: pyramid.count - 2, through: 0, by: -1) {
            let band = pyramid[l]
            var up = Filters.resizeBilinear(current, toWidth: band.width, toHeight: band.height)
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
    /// That is not style. Debloom shipped ON in the app and OFF in the CLI
    /// because the CLI wrapped this in a separate boolean, so every PMax
    /// measurement taken through the CLI described a configuration no user ever
    /// saw. `isEnabled` lives here so no caller has to decide what "off" means.
    public struct Options: Sendable {
        /// Number of coarsest band levels to focus-gate. 0 disables the gate —
        /// this one value is both the off-switch and the strength dial, which
        /// is exactly what the app's single "Debloom levels" slider drives.
        public var coarseLevels: Int
        public var threshold: Float
        public var isEnabled: Bool { coarseLevels > 0 }
        public init(coarseLevels: Int = 5, threshold: Float = 0.07) {
            self.coarseLevels = coarseLevels
            self.threshold = threshold
        }
    }

    /// Focus-gate config resolved from the CLI/param/env, handed to the GPU
    /// paths (`GPUPyramid`/`WgpuPyramid`) so they can gate the coarsest
    /// `coarseLevels` band levels exactly as the CPU streaming loop does.
    struct GPUFocusGate {
        let coarseLevels: Int
        let threshold: Float
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
                            prepareDespill: Bool = false,
                            onDespillInputs: ((Despill.DespillInputs) -> Void)? = nil,
                            onSharpness: ((FrameSharpness) -> Void)? = nil)
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
                        prepareDespill: prepareDespill,
                        onDespillInputs: onDespillInputs,
                        onSharpness: onSharpness) { i in
            var img = try ImageFile.load(url: source.urls[i])
            if let gain = source.gains?[i], gain != SIMD3(repeating: 1) {
                img.scaleRGB(by: gain)
            }
            return img
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
                            prepareDespill: Bool = false,
                            onDespillInputs: ((Despill.DespillInputs) -> Void)? = nil,
                            onSharpness: ((FrameSharpness) -> Void)? = nil,
                            frame: @escaping (Int) throws -> ImageBuffer) throws -> ImageBuffer {
        precondition(frameCount > 0)
        // Settings, with env overrides for tuning/ablation — `options` is
        // authoritative, exactly as `DMapFusion.Options` is for dmap. There is
        // no separate enable var: `coarseLevels == 0` IS off (Options.isEnabled),
        // so `HYPERFOCAL_PMAX_DARK_COARSE=0` is the debloom ablation switch.
        // (A `HYPERFOCAL_PMAX_FOCUS_GATE` force-on used to exist because the
        // default was off; it is redundant now that the default is on.)
        let env = ProcessInfo.processInfo.environment
        let fgCoarse = Int(env["HYPERFOCAL_PMAX_DARK_COARSE"] ?? "") ?? options.coarseLevels
        let fgThreshold = Float(env["HYPERFOCAL_PMAX_FOCUS_THRESH"] ?? "") ?? options.threshold
        let focusGateEnabled = fgCoarse > 0
        if focusGateEnabled { log?("pmax: focus-gate on") }
        // Focus-gate config for the GPU paths (nil = standard PMax).
        let gpuFocusGate = focusGateEnabled
            ? GPUFocusGate(coarseLevels: fgCoarse, threshold: fgThreshold) : nil
        // Despill needs the per-frame grid luminance and focus planes, which only
        // the CPU loop retains today — stay on the CPU when it is requested. The
        // GPU port is a follow-up, exactly as the focus gate's was.
        if prepareDespill { log?("pmax: despill inputs requested — CPU engine") }
        let preferGPU = preferGPU && !prepareDespill
        #if canImport(Metal)
        if preferGPU, MetalEngine.shared != nil {
            do {
                return try GPUPyramid.fuse(frameCount: frameCount, warp: warp,
                                           log: log, progress: progress,
                                           cancellation: cancellation,
                                           decodeWorkers: decodeWorkers,
                                           decodeLookahead: decodeLookahead,
                                           focusGate: gpuFocusGate,
                                           onSharpness: onSharpness, frame: frame)
            } catch let error as StackError {
                log?("GPU pyramid failed (\(error)); falling back to CPU")
            }
        }
        #endif
        #if HYPERFOCAL_HAVE_WGPU
        if preferGPU, let engine = WgpuEngine.shared, engine.usableForAutoSelection {
            do {
                return try WgpuPyramid.fuse(frameCount: frameCount, warp: warp,
                                            log: log, progress: progress,
                                            cancellation: cancellation,
                                            decodeWorkers: decodeWorkers,
                                            decodeLookahead: decodeLookahead,
                                            focusGate: gpuFocusGate,
                                            onSharpness: onSharpness, frame: frame)
            } catch let error as StackError {
                log?("wgpu pyramid failed (\(error)); falling back to CPU")
            }
        }
        #endif
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
        let useDarkBase = env["HYPERFOCAL_PMAX_DARKBASE"] != nil || focusGate
        var baseBestLum: [Float] = []
        // f32 sum of every frame's coarsest Gaussian, for the averaged base.
        // See the accumulation site for why this one buffer resists f16.
        var baseAccum: [Float] = []
        var bandBestLum: [[Float]] = []
        var trackB: [ImageBuffer] = []
        var hasFocus: [[Float]] = []
        var plainC: [ImageBuffer] = []
        var plainBestE: [[Float]] = []
        var lumMin0: [Float] = []
        var lumMax0: [Float] = []
        var focusMax0: [Float] = []
        var focusMin0: [Float] = []
        // Despill inputs (only when asked): per-frame grid luminance for the
        // dark floor, and the running per-cell max of this frame's fine-scale
        // focus — the "did any frame ever resolve detail here" confidence proxy
        // that stands in for DMap's noise-floor×concentration plane.
        var luminancePlanes: [[Float]] = []
        var focusMax: [Float] = []
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
            let (fi, img) = try prefetcher.next()
            tDecode += now() - t0
            if workspace == nil {
                // Canvas = the warp's output size (common-coverage crop) or
                // the frame's own — decided before any warp so frames can be
                // resampled straight into the workspace's level 0.
                let w = warp?.outputWidth ?? img.width
                let h = warp?.outputHeight ?? img.height
                levels = max(3, Int(log2(Double(min(w, h)) / 16.0)))
                let ws = CPUWorkspace(width: w, height: h, levels: levels)
                workspace = ws
                // bestEnergy = −1: the first frame's bands install
                // unconditionally (energies are ≥ 0) — same convention as
                // the GPU paths' bestE fill.
                fused = ws.sizes.map { ImageBuffer(width: $0.w, height: $0.h) }
                bestEnergy = ws.sizes.dropLast().map {
                    [Float](repeating: -1, count: $0.w * $0.h)
                }
                if useDarkBase {
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
            }
            let ws = workspace!
            let (cw, ch) = ws.sizes[0]
            t0 = now()
            // Identity transform on an uncropped canvas needs no warp — the
            // same fast path `PyramidWarp.apply` / the GPU paths take. Warped
            // frames resample directly into the workspace's level 0.
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
            if prepareDespill || onSharpness != nil {
                // Reductions of buffers that are live right here and nowhere
                // else: gauss[0] is this frame warped onto the canvas (gains
                // already applied by the source closure, so the luminance is
                // gain-corrected as DMap's is), and `energy` is the
                // grit-blurred level-0 focus `level0BandEnergy` just wrote —
                // the same per-frame measurement the despill gate consumes
                // and, retained per frame, the sharpness planes retouch's
                // space auto-pick queries (a PMax primary has no DMap pass
                // to retain them from).
                let f = DMapFusion.sharpnessDownsample
                let focusGrid = DMapFusion.boxDownsample(ws.energy, width: cw, height: ch,
                                                         factor: f)
                if onSharpness != nil { sharpnessPlanes.append(focusGrid) }
                if prepareDespill {
                    var lum = [Float](repeating: 0, count: cw * ch)
                    ws.gauss[0].withUnsafeBufferPointer { gpBuf in
                        let gp = gpBuf.baseAddress!
                        lum.withUnsafeMutableBufferPointer { lp in
                            DispatchQueue.concurrentPerform(iterations: ch) { y in
                                for x in 0..<cw {
                                    let g = hfLoadRGBA(gp, (y * cw + x) * 4)
                                    lp[y * cw + x] = 0.2126 * g.x + 0.7152 * g.y
                                        + 0.0722 * g.z
                                }
                            }
                        }
                    }
                    luminancePlanes.append(DMapFusion.boxDownsample(lum, width: cw, height: ch,
                                                                    factor: f))
                    if focusMax.isEmpty {
                        focusMax = focusGrid
                    } else {
                        for i in focusMax.indices { focusMax[i] = max(focusMax[i], focusGrid[i]) }
                    }
                }
            }
            tBuild += now() - t0
            t0 = now()
            ws.select0(fused: &fused![0], best: &bestEnergy[0])
            for l in 1..<levels {
                if focusGate && l >= levels - darkCoarse {
                    let focus = ws.focusDownsampled(toLevel: l)
                    ws.selectStreamingFocusGated(level: l, focus: focus, threshold: focusThresh,
                                                 fused: &fused![l], bestE: &bestEnergy[l],
                                                 trackB: &trackB[l], bestDarkLum: &bandBestLum[l],
                                                 hasFocus: &hasFocus[l],
                                                 plainC: &plainC[l], plainBestE: &plainBestE[l])
                } else if darkCoarse > 0 && l >= levels - darkCoarse {
                    ws.selectStreamingDark(level: l, fused: &fused![l], bestLum: &bandBestLum[l])
                } else {
                    ws.selectStreaming(level: l, fused: &fused![l], best: &bestEnergy[l])
                }
            }
            if useDarkBase {
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

        // Average the accumulated base level (unless darkest-base kept a winner)
        // and narrow the f32 accumulator into the band pyramid.
        if !useDarkBase {
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
            let gate = Self.debloomMasks(lumMin0: lumMin0, lumMax0: lumMax0,
                                         focusMax0: focusMax0,
                                         focusMin0: focusMin0, frameCount: frameCount,
                                         width: w0, height: h0,
                                         sizes: workspace!.sizes, levels: levels,
                                         darkCoarse: darkCoarse, env: env)
            DMapFusion.dumpPlane(focusMax0, env: "HYPERFOCAL_DUMP_FOCUSMAX0")
            DMapFusion.dumpPlane(focusMin0, env: "HYPERFOCAL_DUMP_FOCUSMIN0")
            DMapFusion.dumpPlane(lumMax0, env: "HYPERFOCAL_DUMP_LUMMAX0")
            log?(String(format: "pmax debloom gate: scale=%.4f, mean mask %.3f, open-bg %.3f",
                        gate.scale, gate.mean, gate.bgFraction))
            for l in 1..<levels where l >= levels - darkCoarse {
                let hf = hasFocus[l]
                let mask = gate.masks[l]
                fused![l].pixels.withUnsafeMutableBufferPointer { apBuf in
                    let ap = apBuf.baseAddress!
                    trackB[l].pixels.withUnsafeBufferPointer { bpBuf in
                        let bp = bpBuf.baseAddress!
                        plainC[l].pixels.withUnsafeBufferPointer { cpBuf in
                            let cp = cpBuf.baseAddress!
                            for i in 0..<hf.count {
                                let pi = i * 4
                                // Debloom's own answer for this cell.
                                let d = hf[i] < 0.5 ? hfLoadRGBA(bp, pi) : hfLoadRGBA(ap, pi)
                                // Near-black membership: 1 where the cell is
                                // never bright (background), 0 where it is a lit
                                // surface. Smoothstepped so the transition can't
                                // band along the falloff.
                                let c = hfLoadRGBA(cp, pi)
                                hfStoreRGBA(ap, pi, c + (d - c) * mask[i])
                            }
                        }
                    }
                }
            }
        }
        if prepareDespill, let onDespillInputs, let ws = workspace {
            let (w, h) = ws.sizes[0]
            let f = DMapFusion.sharpnessDownsample
            let gw = (w + f - 1) / f, gh = (h + f - 1) / f
            if let strength = Despill.spillStrength(luminancePlanes: luminancePlanes,
                                                    confidence: focusMax,
                                                    gridWidth: gw, gridHeight: gh),
               let inputs = Despill.computeInputs(luminancePlanes: luminancePlanes,
                                                  spillStrength: strength,
                                                  spillWidth: gw, spillHeight: gh,
                                                  width: w, height: h, factor: f, log: log) {
                DMapFusion.dumpPlane(strength, env: "HYPERFOCAL_DUMP_SPILLW")
                onDespillInputs(inputs)
            } else {
                log?("pmax: despill inputs unavailable (need > 2 frames)")
            }
        }
        if let onSharpness, let ws = workspace, !sharpnessPlanes.isEmpty {
            let (w, h) = ws.sizes[0]
            onSharpness(FrameSharpness(fullWidth: w, fullHeight: h,
                                       factor: DMapFusion.sharpnessDownsample,
                                       planes: sharpnessPlanes))
        }
        let t0 = now()
        let out = collapse(fused!)
        log?(String(format: "pyramid phases (cpu): decode %.2fs, warp %.2fs, "
                    + "build %.2fs, select %.2fs, collapse %.2fs",
                    tDecode, tWarp, tBuild, tSelect, now() - t0))
        return out
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
                                    let up = Self.upsampleAt(coarse, sw: nw, sh: nh,
                                                             x: x, y: y, scaleX: sx, scaleY: sy)
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
            let (w, h) = sizes[0]
            let r = gritWeights.count / 2
            energy.withUnsafeBufferPointer { s in
                energyTmp.withUnsafeMutableBufferPointer { t in
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
            energyTmp.withUnsafeBufferPointer { t in
                energy.withUnsafeMutableBufferPointer { o in
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
                                        // half — see ROADMAP's parity note.)
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
                    bestE.withUnsafeMutableBufferPointer { be in
                      bestDarkLum.withUnsafeMutableBufferPointer { bd in
                        hasFocus.withUnsafeMutableBufferPointer { hf in
                          focus.withUnsafeBufferPointer { fo in
                           plainC.pixels.withUnsafeMutableBufferPointer { cpBuf in
                            let cp = cpBuf.baseAddress!
                            plainBestE.withUnsafeMutableBufferPointer { pe in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                              for x in 0..<w {
                                let i = y * w + x
                                let pi = i * 4
                                let up = Self.upsampleAt(coarse, sw: nw, sh: nh,
                                                         x: x, y: y, scaleX: sx, scaleY: sy)
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
                                        let up = Self.upsampleAt(coarse, sw: nw, sh: nh,
                                                                 x: x, y: y, scaleX: sx, scaleY: sy)
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
                                    let up = Self.upsampleAt(coarse, sw: nw, sh: nh,
                                                             x: x, y: y, scaleX: sx, scaleY: sy)
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
