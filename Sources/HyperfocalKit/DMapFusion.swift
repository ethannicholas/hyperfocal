import Foundation
import Dispatch
#if canImport(simd)
import simd
#endif

/// Depth-map fusion: estimate which frame is sharpest at every pixel, regularize
/// that index map, then render the output by sampling frames along it.
///
/// Selection happens in *depth space*, not energy space, which is what prevents
/// halos at depth discontinuities: background pixels next to a subject edge have
/// no real sharpness signal of their own (defocus spill is low-frequency and falls
/// below the noise floor), so instead of picking the frame with the brightest blur
/// glow they inherit depth from confident neighbors — and in the frame where the
/// subject is sharp, the adjacent background is clean.
///
/// Streams frames in two passes (depth estimation, then rendering); memory is a
/// handful of float planes regardless of stack depth.
public enum DMapFusion {

    public struct Options {
        public var sharpnessSigma: Float
        /// Tent-kernel radius (in frame-index units) for rendering: pixels blend
        /// frames within this distance of their depth. Wider = smoother transitions.
        public var blendRadius: Float
        /// Fraction of the 95th-percentile selection energy treated as "no signal".
        /// Pixels below it contribute no depth opinion and are filled by diffusion.
        public var noiseFloor: Float
        /// Radius of the confidence-weighted median applied to the depth map.
        /// Enforces spatial coherence: kills isolated wrong-depth patches at
        /// occlusion boundaries (background showing through defocused subject
        /// edges, defocus spill onto featureless background). 0 disables.
        public var medianRadius: Int
        /// Estimate a per-frame exposure gain and normalize, so shutter/lighting
        /// flicker doesn't imprint brightness patches wherever the depth map
        /// switches frames. Defocus preserves total light and aligned frames see
        /// the same scene, so mean luminance differences ARE the flicker.
        public var normalizeExposure: Bool
        /// Fraction of a pixel's above-median sharpness energy that must lie
        /// within the peak window (± max(2, frames/16) of its argmax) for the
        /// pixel to hold a depth opinion. Genuine focus concentrates its
        /// excess energy in one contiguous peak — however faint; the rims of
        /// defocused specular bokeh sweep excess energy through frames far
        /// from any single peak, and the argmax lands on whichever rim
        /// happened strongest ("wet look" blotches on smooth surfaces near
        /// glossy subjects). Below-concentration pixels are treated as
        /// no-signal and inherit depth like noise-floor pixels. This gates on
        /// the *shape* of the energy curve, not its height, so weak-but-real
        /// unimodal detail keeps its vote. 0 disables.
        public var peakConcentration: Float
        /// Guided-filter window radius in full-resolution pixels (rounded to
        /// whole sharpness-grid cells internally).
        public var guidedRadius: Float
        /// Guided-filter edge-stop regularization. The guide is normalized to
        /// its 95th percentile, so this is unit-free: smaller keeps weaker
        /// guide edges, larger smooths across them.
        public var guidedEps: Float
        /// Let the GPU path cache warped frames on disk between its two
        /// passes instead of decoding the stack twice (see FrameSpill —
        /// output is bit-identical either way, this is purely a time/disk
        /// trade). The temp file is width×height×16 bytes per frame, so
        /// users short on disk can turn it off and accept the slower fuse.
        public var spillEnabled: Bool

        public init(sharpnessSigma: Float = 10, blendRadius: Float = 1, noiseFloor: Float = 0.05,
                    medianRadius: Int = 20, normalizeExposure: Bool = true,
                    peakConcentration: Float = 0.5,
                    guidedRadius: Float = 128, guidedEps: Float = 1e-3,
                    spillEnabled: Bool = true) {
            self.sharpnessSigma = sharpnessSigma
            self.blendRadius = blendRadius
            self.noiseFloor = noiseFloor
            self.medianRadius = medianRadius
            self.normalizeExposure = normalizeExposure
            self.peakConcentration = peakConcentration
            self.guidedRadius = guidedRadius
            self.guidedEps = guidedEps
            self.spillEnabled = spillEnabled
        }
    }

    public struct Output {
        public let image: ImageBuffer
        /// Regularized depth as a grayscale image: white = first frame, black =
        /// last. Stacks are typically shot close-to-far, so near is bright — the
        /// usual depth/disparity convention.
        public let depthMap: ImageBuffer
        /// The regularized per-pixel frame index itself (full resolution) — the
        /// "which frame is sharpest here" table. Retouching uses it to auto-pick
        /// a source slice for a brush region without touching any pixels.
        public let depth: [Float]
        /// Per-frame raw sharpness energy, downsampled — the measurement *before*
        /// any regularization. Retouching queries it to judge a brush region's
        /// sharpness in every frame independently of what the fusion decided
        /// (which is exactly what's in question wherever the user is painting).
        public let sharpness: FrameSharpness?
        /// Per-frame, per-channel exposure gains that were applied while
        /// rendering. Retouch sources must apply the same gains or stamps
        /// carry the original flicker into the normalized result.
        public let gains: [SIMD3<Float>]?
    }

    public static func fuse(frameCount: Int, options: Options = Options(),
                            log: ((String) -> Void)? = nil,
                            frame: @escaping (Int) throws -> ImageBuffer) throws -> ImageBuffer {
        try fuseWithDepth(frameCount: frameCount, options: options, log: log, frame: frame).image
    }

    /// Below this blend radius the tent kernel can leave pixels covered by
    /// no frame at all — every consumer (both engines' render passes, the
    /// app's Blend radius slider) bottoms out here, via this one constant.
    public static let minBlendRadius: Float = 0.75

    /// Downsample factor for retained per-frame sharpness planes.
    public static let sharpnessDownsample = 8

    /// Grid factor for the per-frame energy blur: |Laplacian| is
    /// box-reduced by this factor, blurred at σ/factor, and bilinearly
    /// upsampled back to full res — ~16× less blur work, and faithful
    /// because the σ=10 blur removes everything above the grid's Nyquist
    /// anyway. Below σ=4 the grid would under-resolve the field the blur
    /// still preserves, so small sigmas keep the full-res path (factor 1).
    /// Cross-engine algorithm constant: the CPU, Metal, and WGSL paths
    /// must apply the same rule or the ≥90 dB dmap parity gate breaks.
    public static func energyGridFactor(sigma: Float) -> Int {
        sigma >= 4 ? 4 : 1
    }

    /// Light low-pass on the winner-luminance guide. The winning frame's
    /// luminance carries in-focus pixel texture, and the guided filter copies
    /// guide structure into depth wherever confidence dips — luminance
    /// speckle is not depth structure. A few pixels of blur kills the speckle
    /// while silhouette edges (tens of pixels wide) stay effectively crisp.
    public static let guideSigma: Float = 3

    /// Fuses a StackSource: frames decode (prefetched) without warping, and
    /// alignment applies on the fly into a reused canvas buffer. Prefer this
    /// over the closure form for aligned sources — `source.frame` warps on
    /// the CPU allocating a fresh canvas per frame.
    public static func fuseWithDepth(source: StackSource,
                                     options: Options = Options(),
                                     log: ((String) -> Void)? = nil,
                                     progress: FusionProgressHandler? = nil,
                                     cancellation: CancellationToken? = nil) throws -> Output {
        let warp = source.transforms.map {
            PyramidWarp(transforms: $0, outputWidth: source.outputWidth,
                        outputHeight: source.outputHeight)
        }
        return try fuseWithDepth(frameCount: source.count, options: options,
                                 warp: warp, log: log, progress: progress,
                                 cancellation: cancellation,
                                 decodeWorkers: FramePrefetcher.workers(for: source.urls)) { i in
            var img = try ImageFile.load(url: source.urls[i])
            if let gain = source.gains?[i], gain != SIMD3(repeating: 1) {
                img.scaleRGB(by: gain)
            }
            return img
        }
    }

    /// With `warp`, `frame` must return unwarped frames; alignment applies
    /// on the fly (Lanczos-3 into a reused canvas buffer — the pyramid
    /// paths' seam). Frames decode on background threads (`FramePrefetcher`),
    /// so `frame` may be invoked concurrently and must be stateless across
    /// calls (all in-tree closures are).
    public static func fuseWithDepth(frameCount: Int, options: Options = Options(),
                                     warp: PyramidWarp? = nil,
                                     log: ((String) -> Void)? = nil,
                                     progress: FusionProgressHandler? = nil,
                                     cancellation: CancellationToken? = nil,
                                     decodeWorkers: Int? = nil,
                                     frame: @escaping (Int) throws -> ImageBuffer) throws -> Output {
        precondition(frameCount > 0)
        var width = 0, height = 0
        var bestEnergy: [Float] = []
        var bestIndex: [Float] = []
        var sharpnessPlanes: [[Float]] = []
        var luminancePlanes: [[Float]] = []  // per-frame grid luminance (spill floor)
        var guidePlane: [Float] = []  // winner-frame luminance (regularizer guide)
        var gains0 = [SIMD3<Float>]()  // per-channel gain per frame, vs frame 0
        var meanRGB0 = SIMD3<Float>(repeating: 1)

        // Pass 1 spills its aligned frames so pass 2 can stream them back
        // instead of decoding + warping the stack a second time — the same
        // FrameSpill the GPU paths use (fp32 when it fits, fp16 when only
        // that does, skipped with a log when neither will).
        let wantSpill = FrameSpill.wanted(options.spillEnabled)
        var spill: FrameSpill?

        // Wall-clock phase buckets, reported through `log` at the end — the
        // pyramid paths' discipline: optimization here must start from
        // measurements, not vibes. `decode` is time *blocked on* the
        // prefetcher, not decode execution.
        var tDecode = 0.0, tWarp = 0.0, tEnergy = 0.0, tSelect = 0.0, tSpill = 0.0
        var tRegularize = 0.0, tRenderDecode = 0.0, tRender = 0.0
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

        // Reused canvas for on-the-fly warps: sized on the first frame,
        // resampled into in place every frame after (loop-scoped borrows keep
        // the pixel storage uniquely referenced between frames).
        var warped = ImageBuffer(width: 0, height: 0)
        func aligned(_ fi: Int, _ decoded: ImageBuffer) -> ImageBuffer {
            // Identity transform on an uncropped canvas needs no warp — the
            // same fast path every other engine seam takes.
            let needsWarp = warp.map {
                !($0.transforms[fi] == matrix_identity_float3x3
                    && width == decoded.width && height == decoded.height)
            } ?? false
            guard needsWarp else { return decoded }
            if warped.width != width || warped.height != height {
                warped = ImageBuffer(width: width, height: height)
            }
            Warp.applyLanczos3(decoded, outputToSource: warp!.transforms[fi].inverse,
                               outWidth: width, outHeight: height, into: &warped.pixels)
            return warped
        }

        // Decode on background threads while this thread scores the previous
        // frame — same overlap as the pyramid paths.
        let prefetcher = FramePrefetcher(indices: Array(0..<frameCount),
                                         workers: decodeWorkers, decode: frame)
        defer { prefetcher.cancel() }

        // Pass 1: per-pixel argmax of smoothed |Laplacian| across the stack.
        for _ in 0..<frameCount {
            try cancellation?.checkCancelled()
            var t0 = now()
            let (fi, decoded) = try prefetcher.next()
            tDecode += now() - t0
            if fi == 0 {
                width = warp?.outputWidth ?? decoded.width
                height = warp?.outputHeight ?? decoded.height
                bestEnergy = [Float](repeating: 0, count: width * height)
                bestIndex = [Float](repeating: 0, count: width * height)
                guidePlane = [Float](repeating: 0, count: width * height)
                if wantSpill {
                    spill = FrameSpill(frameBytes: width * height * 16,
                                       frameCount: frameCount, log: log)
                }
            }
            t0 = now()
            let img = aligned(fi, decoded)
            tWarp += now() - t0
            precondition(img.width == width && img.height == height,
                         "frame \(fi) size mismatch: \(img.width)x\(img.height) vs \(width)x\(height)")
            t0 = now()
            let lum = img.luminancePlane()
            // Gain chained against frame 0 (known once the first frame is seen),
            // so energies can be corrected as they stream. Measured per channel
            // (LED flicker wobbles white balance, not just brightness); the
            // scoring side uses the luminance combination — Laplacian energy is
            // computed on the luminance plane, and it is linear in gain, so
            // scaling the energy equals measuring the normalized frame.
            let mean = meanChannels(pixels: img.pixels)
            if fi == 0 { meanRGB0 = mean }
            let gain = options.normalizeExposure
                ? min(max(luma(meanRGB0) / max(luma(mean), 1e-6), 0.5), 2)
                : 1
            gains0.append(options.normalizeExposure
                ? (meanRGB0 / pointwiseMax(mean, .init(repeating: 1e-6)))
                    .clamped(lowerBound: .init(repeating: 0.5),
                             upperBound: .init(repeating: 2))
                : .one)
            let lap = Filters.laplacianAbs(lum, width: width, height: height)
            var energy = Self.gridEnergy(lap, width: width, height: height,
                                         sigma: options.sharpnessSigma)
            if gain != 1 {
                energy.withUnsafeMutableBufferPointer { ep in
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for i in (y * width)..<((y + 1) * width) { ep[i] *= gain }
                    }
                }
            }
            sharpnessPlanes.append(boxDownsample(energy, width: width, height: height,
                                                 factor: Self.sharpnessDownsample))
            // Grid luminance, gain-corrected like the energy, for the spill
            // floor: on signal-free background the least-contaminated frame is
            // the darkest one, and that judgment needs the luminance-vs-frame
            // curve.
            var lumGrid = boxDownsample(lum, width: width, height: height,
                                        factor: Self.sharpnessDownsample)
            if gain != 1 {
                for i in lumGrid.indices { lumGrid[i] *= gain }
            }
            luminancePlanes.append(lumGrid)
            tEnergy += now() - t0
            t0 = now()
            let index = Float(fi)
            let first = fi == 0
            energy.withUnsafeBufferPointer { ep in
                img.pixels.withUnsafeBufferPointer { fp in
                    lum.withUnsafeBufferPointer { lp in
                        bestEnergy.withUnsafeMutableBufferPointer { be in
                            bestIndex.withUnsafeMutableBufferPointer { bi in
                                guidePlane.withUnsafeMutableBufferPointer { gp in
                                    DispatchQueue.concurrentPerform(iterations: height) { y in
                                        for i in (y * width)..<((y + 1) * width) {
                                            // Alpha-masked: no depth vote where this
                                            // frame has no data (warp out-of-bounds).
                                            let e = ep[i] * fp[i * 4 + 3]
                                            let wins = e > be[i]
                                            if wins {
                                                be[i] = e
                                                bi[i] = index
                                            }
                                            // Guide for the guided regularizer:
                                            // gain-corrected luminance of the
                                            // winning frame — an all-in-focus
                                            // luminance estimate. A mean over the
                                            // stack is defocus-blurred exactly at
                                            // fine silhouette detail (thin peaks
                                            // average away against background),
                                            // and the regularizer can only stop
                                            // depth at edges the guide has. Frame
                                            // 0 seeds pixels no frame ever wins.
                                            if wins || first {
                                                gp[i] = lp[i] * gain
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            tSelect += now() - t0
            // Spill the aligned frame for pass 2 — staged synchronously, the
            // I/O overlaps the next frame's compute (write errors surface at
            // the drain before pass 2 and degrade to re-decoding). The
            // bucket therefore measures staging + backpressure, not disk.
            if let s = spill {
                t0 = now()
                img.pixels.withUnsafeBufferPointer {
                    s.writeAsync(frame: fi, from: $0.baseAddress!)
                }
                tSpill += now() - t0
            }
            log?("depth pass \(fi + 1)/\(frameCount)")
            if let progress {
                progress(FusionProgress(stage: .depth,
                                        fraction: Double(fi + 1) / Double(frameCount),
                                        preview: depthMapPreview(bestIndex: bestIndex,
                                                                 width: width, height: height,
                                                                 frameCount: frameCount),
                                        previewFullWidth: width, previewFullHeight: height,
                                        sourceFrameIndex: fi,
                                        sourcePreview: img.downsampledNearest(maxSide: 1200),
                                        sourceFullWidth: img.width, sourceFullHeight: img.height))
            }
        }

        var t0 = now()
        guidePlane = Filters.blurPlane(guidePlane, width: width, height: height,
                                       sigma: Self.guideSigma)
        dumpGuide(guidePlane)

        let concentration = peakConcentrationPlane(planes: sharpnessPlanes)
        let depth = regularizeDepth(bestEnergy: bestEnergy, bestIndex: bestIndex,
                                    concentration: concentration,
                                    concentrationWidth: (width + sharpnessDownsample - 1)
                                        / sharpnessDownsample,
                                    concentrationFactor: sharpnessDownsample,
                                    planes: sharpnessPlanes,
                                    luminancePlanes: luminancePlanes,
                                    guide: guidePlane.isEmpty ? nil : guidePlane,
                                    width: width, height: height,
                                    frameCount: frameCount, options: options, log: log,
                                    progress: {
            progress?(FusionProgress(stage: .regularizing, fraction: $0))
        })
        tRegularize = now() - t0

        let gains = renderGains(from: gains0, options: options, log: log)

        // Pass 2: render by blending frames near each pixel's depth (tent kernel).
        let radius = max(options.blendRadius, Self.minBlendRadius)
        var depthLo: Float = .infinity, depthHi: Float = -.infinity
        for d in depth {
            if d < depthLo { depthLo = d }
            if d > depthHi { depthHi = d }
        }

        var accum = [Float](repeating: 0, count: width * height * 4)
        var wsum = [Float](repeating: 0, count: width * height)
        var renderedCount = 0
        let renderIndices = (0..<frameCount).filter {
            Float($0) > depthLo - radius && Float($0) < depthHi + radius
        }
        let renderTotal = renderIndices.count
        // Pass 1's writes were queued; every slot must be on disk (and
        // error-free) before pass 2 streams them back.
        if let s = spill {
            do {
                try s.drainWrites()
            } catch {
                log?("frame spill write failed (\(error)) — render pass will re-decode")
                spill = nil
            }
        }
        // Frames come back from the spill when pass 1 captured one;
        // otherwise decode again (prefetched) and re-warp.
        var renderPrefetcher: FramePrefetcher? = nil
        if spill == nil {
            renderPrefetcher = FramePrefetcher(indices: renderIndices,
                                               workers: decodeWorkers, decode: frame)
        }
        defer { renderPrefetcher?.cancel() }
        var spillBuf = ImageBuffer(width: 0, height: 0)  // reused read target
        for fi in 0..<frameCount {
            try cancellation?.checkCancelled()
            let index = Float(fi)
            // Skip frames no pixel's tent can reach.
            guard index > depthLo - radius && index < depthHi + radius else {
                log?("render pass \(fi + 1)/\(frameCount) (skipped)")
                continue
            }
            t0 = now()
            var img: ImageBuffer
            if let s = spill {
                if spillBuf.width != width || spillBuf.height != height {
                    spillBuf = ImageBuffer(width: width, height: height)
                }
                do {
                    try spillBuf.pixels.withUnsafeMutableBufferPointer {
                        try s.read(frame: fi, into: $0.baseAddress!)
                    }
                    img = spillBuf
                } catch {
                    log?("frame spill read failed (\(error)) — re-decoding")
                    spill = nil
                    img = aligned(fi, try frame(fi))
                }
            } else if let p = renderPrefetcher {
                img = aligned(fi, try p.next().image)
            } else {
                // Spill failed mid-pass: no prefetcher was built for this path.
                img = aligned(fi, try frame(fi))
            }
            tRenderDecode += now() - t0
            t0 = now()
            let gain = gains?[fi] ?? .one
            img.pixels.withUnsafeBufferPointer { fp in
                depth.withUnsafeBufferPointer { dp in
                    accum.withUnsafeMutableBufferPointer { ap in
                        wsum.withUnsafeMutableBufferPointer { wp in
                            DispatchQueue.concurrentPerform(iterations: height) { y in
                                for i in (y * width)..<((y + 1) * width) {
                                    let pi = i * 4
                                    let a = fp[pi + 3]
                                    guard a > 0 else { continue }  // no data here
                                    let tent = max(1 - abs(index - dp[i]) / radius, 0)
                                    // Floor: pixels whose selected frames lack
                                    // coverage average the frames that do cover.
                                    let w = (tent + 1e-6) * a
                                    wp[i] += w
                                    ap[pi] += fp[pi] * w * gain.x
                                    ap[pi + 1] += fp[pi + 1] * w * gain.y
                                    ap[pi + 2] += fp[pi + 2] * w * gain.z
                                    ap[pi + 3] += fp[pi + 3] * w
                                }
                            }
                        }
                    }
                }
            }
            tRender += now() - t0
            log?("render pass \(fi + 1)/\(frameCount)")
            renderedCount += 1
            if let progress {
                progress(FusionProgress(stage: .render,
                                        fraction: Double(renderedCount) / Double(renderTotal),
                                        preview: progressivePreview(accum: accum, wsum: wsum,
                                                                    width: width, height: height),
                                        previewFullWidth: width, previewFullHeight: height,
                                        sourceFrameIndex: fi,
                                        sourcePreview: img.downsampledNearest(maxSide: 1200),
                                        sourceFullWidth: img.width, sourceFullHeight: img.height))
            }
        }

        log?(String(format: "dmap phases (cpu): decode %.2fs, warp %.2fs, "
                    + "energy %.2fs, select %.2fs, spill %.2fs, "
                    + "regularize %.2fs, render-src %.2fs, render %.2fs",
                    tDecode, tWarp, tEnergy, tSelect, tSpill, tRegularize,
                    tRenderDecode, tRender))

        var out = ImageBuffer(width: width, height: height)
        accum.withUnsafeBufferPointer { ap in
            wsum.withUnsafeBufferPointer { wp in
                out.pixels.withUnsafeMutableBufferPointer { op in
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for i in (y * width)..<((y + 1) * width) {
                            let pi = i * 4
                            if wp[i] > 1e-7 {
                                let inv = 1 / wp[i]
                                op[pi] = ap[pi] * inv
                                op[pi + 1] = ap[pi + 1] * inv
                                op[pi + 2] = ap[pi + 2] * inv
                            }
                            op[pi + 3] = 1  // uncovered pixels: opaque black
                        }
                    }
                }
            }
        }

        return Output(image: out,
                      depthMap: depthImage(from: depth, width: width, height: height,
                                           frameCount: frameCount),
                      depth: depth,
                      sharpness: FrameSharpness(fullWidth: width, fullHeight: height,
                                                factor: Self.sharpnessDownsample,
                                                planes: sharpnessPlanes),
                      gains: gains)
    }

    /// Debug hook for the winner-luminance guide plane: honors
    /// HYPERFOCAL_DUMP_GUIDE (raw Float32, row-major). Shared by both engines.
    static func dumpGuide(_ guide: [Float]) {
        dumpPlane(guide, env: "HYPERFOCAL_DUMP_GUIDE")
    }

    /// Writes a raw Float32 row-major plane to the path in the given env var,
    /// if set — the debugging tap for every regularization intermediate.
    static func dumpPlane(_ plane: [Float], env: String) {
        if let dump = ProcessInfo.processInfo.environment[env] {
            plane.withUnsafeBufferPointer {
                try? Data(buffer: $0).write(to: URL(fileURLWithPath: dump))
            }
        }
    }

    /// Alpha-weighted per-channel mean, stride-subsampled (a global gain
    /// estimate doesn't need every pixel).
    static func meanChannels(pixels: [Float]) -> SIMD3<Float> {
        var sum = SIMD3<Float>()
        var wsum: Float = 0
        let count = pixels.count / 4
        var i = 0
        while i < count {
            let pi = i * 4
            let a = pixels[pi + 3]
            sum += SIMD3(pixels[pi], pixels[pi + 1], pixels[pi + 2]) * a
            wsum += a
            i += 7
        }
        return wsum > 0 ? sum / wsum : SIMD3()
    }

    /// Rec. 709 luma of an RGB triple. Public so per-channel gains can be
    /// collapsed to the scalar the legacy project field carries.
    public static func luma(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    /// Converts frame-0-relative gains to render gains: unity at the stack's
    /// geometric-mean exposure, held per channel. Flicker is zero-mean, so the
    /// mean is the best estimate of the true exposure — anchoring to any single
    /// frame would let that frame's own flicker set the whole output's
    /// brightness (and, per-channel, its white balance). Returns nil when
    /// normalization is off or the correction is negligible.
    static func renderGains(from gains0: [SIMD3<Float>], options: Options,
                            log: ((String) -> Void)?) -> [SIMD3<Float>]? {
        guard options.normalizeExposure, !gains0.isEmpty else { return nil }
        var logSum = SIMD3<Float>()
        for g in gains0 {
            logSum += SIMD3(Foundation.log(max(g.x, 1e-6)),
                            Foundation.log(max(g.y, 1e-6)),
                            Foundation.log(max(g.z, 1e-6)))
        }
        let s = logSum / Float(gains0.count)
        let ref = SIMD3(exp(s.x), exp(s.y), exp(s.z))
        guard ref.min() > 0 else { return nil }
        let gains = gains0.map { $0 / ref }
        var lo = gains[0], hi = gains[0]
        for g in gains {
            lo = pointwiseMin(lo, g)
            hi = pointwiseMax(hi, g)
        }
        if (hi - lo).max() < 0.001 { return nil }  // no measurable flicker
        log?(String(format: "exposure gains r %.4f…%.4f g %.4f…%.4f b %.4f…%.4f",
                    lo.x, hi.x, lo.y, hi.y, lo.z, hi.z))
        return gains
    }

    /// In-memory convenience for small stacks and tests.
    public static func fuse(_ frames: [ImageBuffer], options: Options = Options(),
                            log: ((String) -> Void)? = nil) -> ImageBuffer {
        // No throwing closure and no cancellation token: cannot actually throw.
        try! fuse(frameCount: frames.count, options: options, log: log) { frames[$0] }
    }

    /// The per-frame energy field: σ-blurred |Laplacian|, computed on the
    /// energyGridFactor grid and bilinearly upsampled back to full res
    /// (factor 1 = the plain full-res blur). The CPU reference for the
    /// Metal/WGSL sequences — box_downsample → blur_h/v → plane_upsample.
    static func gridEnergy(_ lap: [Float], width: Int, height: Int,
                           sigma: Float) -> [Float] {
        let factor = energyGridFactor(sigma: sigma)
        guard factor > 1 else {
            return Filters.blurPlane(lap, width: width, height: height, sigma: sigma)
        }
        let gw = (width + factor - 1) / factor
        let gh = (height + factor - 1) / factor
        let grid = boxDownsample(lap, width: width, height: height, factor: factor)
        let blurred = Filters.blurPlane(grid, width: gw, height: gh,
                                        sigma: sigma / Float(factor))
        return Filters.resizePlaneBilinear(blurred, width: gw, height: gh,
                                           toWidth: width, toHeight: height)
    }

    /// Box-average downsample of a single-channel plane (region sums stay
    /// faithful, which is what sharpness scoring needs). Public so the app's
    /// noise-floor preview can build its grid-resolution guide.
    public static func boxDownsample(_ plane: [Float], width: Int, height: Int,
                                     factor: Int) -> [Float] {
        let dw = (width + factor - 1) / factor
        let dh = (height + factor - 1) / factor
        var out = [Float](repeating: 0, count: dw * dh)
        plane.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: dh) { dy in
                    let y0 = dy * factor, y1 = min(y0 + factor, height)
                    for dx in 0..<dw {
                        let x0 = dx * factor, x1 = min(x0 + factor, width)
                        var acc: Float = 0
                        for y in y0..<y1 {
                            for x in x0..<x1 {
                                acc += src[y * width + x]
                            }
                        }
                        dst[dy * dw + dx] = acc / Float((y1 - y0) * (x1 - x0))
                    }
                }
            }
        }
        return out
    }

    /// Downsampled snapshot of the argmax index plane — the depth map forming
    /// during the depth pass.
    static func depthMapPreview(bestIndex: [Float], width: Int, height: Int,
                                frameCount: Int, maxSide: Int = 1200) -> ImageBuffer {
        let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
        let pw = max(1, Int(Double(width) * scale))
        let ph = max(1, Int(Double(height) * scale))
        let norm = frameCount > 1 ? 1 / Float(frameCount - 1) : 0
        var out = ImageBuffer(width: pw, height: ph)
        bestIndex.withUnsafeBufferPointer { bp in
            out.pixels.withUnsafeMutableBufferPointer { op in
                DispatchQueue.concurrentPerform(iterations: ph) { y in
                    let sy = min(y * height / ph, height - 1)
                    for x in 0..<pw {
                        let sx = min(x * width / pw, width - 1)
                        let v = 1 - bp[sy * width + sx] * norm
                        let oi = (y * pw + x) * 4
                        op[oi] = v; op[oi + 1] = v; op[oi + 2] = v; op[oi + 3] = 1
                    }
                }
            }
        }
        return out
    }

    /// Downsampled normalized snapshot of the render accumulators — the output
    /// materializing mid-pass. Untouched pixels are black: the threshold sits
    /// above anything the tent floor alone can accumulate (~1e-6 per frame),
    /// so pixels show only once a genuinely selected frame lands — the
    /// fill-in reads as fill-in instead of starting as the first frame.
    static func progressivePreview(accum: [Float], wsum: [Float],
                                   width: Int, height: Int, maxSide: Int = 1200) -> ImageBuffer {
        let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
        let pw = max(1, Int(Double(width) * scale))
        let ph = max(1, Int(Double(height) * scale))
        var out = ImageBuffer(width: pw, height: ph)
        accum.withUnsafeBufferPointer { ap in
            wsum.withUnsafeBufferPointer { wp in
                out.pixels.withUnsafeMutableBufferPointer { op in
                    DispatchQueue.concurrentPerform(iterations: ph) { y in
                        let sy = min(y * height / ph, height - 1)
                        for x in 0..<pw {
                            let sx = min(x * width / pw, width - 1)
                            let si = sy * width + sx
                            let oi = (y * pw + x) * 4
                            let w = wp[si]
                            if w > 0.01 {
                                let inv = 1 / w
                                op[oi] = ap[si * 4] * inv
                                op[oi + 1] = ap[si * 4 + 1] * inv
                                op[oi + 2] = ap[si * 4 + 2] * inv
                            }
                            op[oi + 3] = 1
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Depth-map regularization

    /// Peak concentration per grid pixel from the retained per-frame sharpness
    /// planes: the fraction of above-median ("excess") energy that lies within
    /// ± max(2, frames/16) of the pixel's argmax. Genuine focus — however
    /// faint — concentrates its excess in one contiguous peak (→ ~1); the
    /// rims of defocused specular bokeh sweep excess through frames far from
    /// any peak (→ small). The median baseline makes this independent of the
    /// stack's blur range, and gating on curve *shape* rather than height
    /// spares weak-but-real unimodal detail that a prominence ratio would
    /// swallow. Shared by the CPU and GPU paths (both retain the same
    /// planes), so parity is by construction.
    public static func peakConcentrationPlane(planes: [[Float]]) -> [Float] {
        // Too few frames for a meaningful baseline: fully concentrated
        // everywhere, so the gate never fires.
        guard let first = planes.first, planes.count > 2 else {
            return [Float](repeating: 1, count: planes.first?.count ?? 0)
        }
        let count = first.count
        let n = planes.count
        // DoF spans more frames in deeper stacks (finer focus steps for the
        // same subject); bokeh sweeps span a large fraction of any stack.
        let window = max(2, n / 16)
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { rp in
            DispatchQueue.concurrentPerform(iterations: 64) { chunk in
                let lo = count * chunk / 64, hi = count * (chunk + 1) / 64
                var column = [Float](repeating: 0, count: n)
                var sorted = [Float](repeating: 0, count: n)
                for i in lo..<hi {
                    var best: Float = 0
                    var argmax = 0
                    for f in 0..<n {
                        let e = planes[f][i]
                        column[f] = e
                        if e > best { best = e; argmax = f }
                    }
                    for f in 0..<n { sorted[f] = column[f] }
                    sorted.sort()
                    let median = sorted[n / 2]
                    var total: Float = 0
                    var near: Float = 0
                    for f in 0..<n {
                        let ex = max(column[f] - median, 0)
                        total += ex
                        if abs(f - argmax) <= window { near += ex }
                    }
                    rp[i] = total > 1e-9 ? near / total : 1
                }
            }
        }
        if let dump = ProcessInfo.processInfo.environment["HYPERFOCAL_DUMP_CONCENTRATION"] {
            // Debug aid: the raw Float32 concentration plane, row-major.
            result.withUnsafeBufferPointer {
                try? Data(buffer: $0).write(to: URL(fileURLWithPath: dump))
            }
        }
        return result
    }

    /// Median via iterative Hoare quickselect, destructive to the buffer.
    /// No allocation and no full sort — tier-2 scoring runs this once per
    /// grid cell, hundreds of thousands of times per fit.
    static func medianDestructive(_ a: inout [Float]) -> Float {
        let k = a.count / 2
        var lo = 0, hi = a.count - 1
        while lo < hi {
            let pivot = a[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j {
                    a.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { break }
        }
        return a[k]
    }

    /// Scores one energy-vs-frame curve: returns the argmax and the peak
    /// concentration if the curve's above-median excess energy is concentrated
    /// (same test as pixels), nil if it's spread out (bokeh sweep / pure
    /// noise — no real focus signal). `scratch` is caller-provided reusable
    /// space (any size; resized as needed) so per-cell calls don't allocate.
    static func concentratedArgmax(curve: [Float], window: Int,
                                   concThreshold: Float,
                                   scratch: inout [Float])
        -> (depth: Float, concentration: Float)? {
        let n = curve.count
        var best: Float = 0
        var argmax = 0
        for f in 0..<n where curve[f] > best {
            best = curve[f]
            argmax = f
        }
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: curve)
        let median = medianDestructive(&scratch)
        var total: Float = 0
        var near: Float = 0
        for f in 0..<n {
            let excess = max(curve[f] - median, 0)
            total += excess
            if abs(f - argmax) <= window { near += excess }
        }
        guard total > 1e-9 else { return nil }
        let concentration = near / total
        guard concentration >= concThreshold else { return nil }
        return (Float(argmax), concentration)
    }

    /// The full regularization chain: confidence from a noise floor × peak
    /// concentration, confidence-weighted median, guided-filter regularization
    /// with a confidence-preservation blend, clamp. Shared by the CPU and GPU
    /// paths — grid-level work is identical shared code; only full-res pixel
    /// work differs. Public so the app's noise-floor preview can run the
    /// *real* regularizer on the retained low-res sharpness planes (scale
    /// `medianRadius` and `guidedRadius` by 1/`sharpnessDownsample`, pass
    /// `concentrationFactor` 1, and supply a grid-resolution guide).
    /// `isStale` (polled from worker threads, must be thread-safe) lets a
    /// caller that will discard the result — the preview mid-drag — abort
    /// the remaining work; the early return is well-formed but unspecified.
    public static func regularizeDepth(bestEnergy: [Float], bestIndex: [Float],
                                       concentration: [Float]? = nil,
                                       concentrationWidth: Int = 0,
                                       concentrationFactor: Int = 1,
                                       planes: [[Float]]? = nil,
                                       luminancePlanes: [[Float]]? = nil,
                                       guide: [Float]? = nil,
                                       width: Int, height: Int, frameCount: Int,
                                       options: Options, log: ((String) -> Void)? = nil,
                                       isStale: (@Sendable () -> Bool)? = nil,
                                       progress: ((Double) -> Void)? = nil) -> [Float] {
        // Confidence: soft threshold against a noise floor derived from the image's
        // own energy distribution (robust to overall scene contrast), times a
        // peak-concentration factor when available — excess energy scattered
        // far from the peak is bokeh sweeping through, not focus. Both factors
        // are 0.5 exactly at their thresholds: an at-threshold pixel that's
        // otherwise fully confident lands right on the seed boundary; below
        // it, it can't seed at all.
        //
        // The energy factor hard-zeros at half the floor (sigmoid over the
        // *excess* above floor/2) rather than tailing off asymptotically: on
        // featureless background the only energy is defocus glow spilling off
        // the subject, and an asymptotic tail leaves those pixels holding
        // 1e-3…1e-1 confidence — enough to outweigh the regularizer's prior
        // floor and to feed the weighted median's consensus (a weight *ratio*,
        // blind to how tiny the weights are — which is why no noise-floor
        // setting could kill the resulting halos). Below-half-floor pixels
        // must hold exactly no opinion.
        let floor = max(1e-6, options.noiseFloor * percentile95(bestEnergy))
        let halfFloor = floor / 2
        let halfFloor2 = halfFloor * halfFloor
        let conc2 = options.peakConcentration * options.peakConcentration
        var confidence = [Float](repeating: 0, count: width * height)
        // The concentration plane lives at the sharpness grid; sample it
        // bilinearly (center-aligned) — nearest-neighbor lookup imprinted the
        // grid as hard 8-px squares in the confidence plane, and the blend
        // carried them into the depth map wherever background glints hold
        // partial confidence.
        let concH = concentration.map { $0.count / max(concentrationWidth, 1) } ?? 0
        let invConcF = 1 / Float(concentrationFactor)
        bestEnergy.withUnsafeBufferPointer { be in
            confidence.withUnsafeMutableBufferPointer { cp in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    var ky0 = 0, ky1 = 0
                    var fy: Float = 0
                    if concentration != nil, conc2 > 0 {
                        let gy = min(max((Float(y) + 0.5) * invConcF - 0.5, 0),
                                     Float(concH - 1))
                        ky0 = min(Int(gy), concH - 1)
                        ky1 = min(ky0 + 1, concH - 1)
                        fy = gy - Float(ky0)
                    }
                    for x in 0..<width {
                        let i = y * width + x
                        let es = max(be[i] - halfFloor, 0)
                        let e2 = es * es
                        var c = e2 / (e2 + halfFloor2)
                        if let concentration, conc2 > 0 {
                            let gx = min(max((Float(x) + 0.5) * invConcF - 0.5, 0),
                                         Float(concentrationWidth - 1))
                            let kx0 = min(Int(gx), concentrationWidth - 1)
                            let kx1 = min(kx0 + 1, concentrationWidth - 1)
                            let fx = gx - Float(kx0)
                            let k = (concentration[ky0 * concentrationWidth + kx0] * (1 - fx)
                                     + concentration[ky0 * concentrationWidth + kx1] * fx) * (1 - fy)
                                  + (concentration[ky1 * concentrationWidth + kx0] * (1 - fx)
                                     + concentration[ky1 * concentrationWidth + kx1] * fx) * fy
                            let k2 = k * k
                            c *= k2 / (k2 + conc2)
                        }
                        cp[i] = c
                    }
                }
            }
        }

        dumpPlane(confidence, env: "HYPERFOCAL_DUMP_CONFIDENCE")
        progress?(0.1)

        // Spatial coherence: majority vote over the neighborhood overrides isolated
        // wrong-depth picks (occlusion boundaries produce confident-but-wrong pixels
        // that no threshold can catch). Consensus — how unanimous the window's
        // votes were — feeds the blend as dense-voting evidence.
        var index = bestIndex
        var consensus: [Float] = []
        if options.medianRadius > 0 {
            (index, consensus) = weightedMedianFilter(
                values: index, weights: confidence,
                width: width, height: height,
                radius: options.medianRadius, bins: frameCount,
                consensusWindow: max(2, frameCount / 16))
        }
        // Ablation switch (debug, like HYPERFOCAL_GUIDED_*): drop the
        // dense-voting consensus from the blend to measure what it costs.
        if ProcessInfo.processInfo.environment["HYPERFOCAL_NO_CONSENSUS"] != nil {
            consensus = []
        }
        dumpPlane(index, env: "HYPERFOCAL_DUMP_DMED")
        dumpPlane(consensus, env: "HYPERFOCAL_DUMP_CONSENSUS")

        progress?(0.4)

        // Confidence-weighted edge-aware guided regularization: hard argmax
        // survives where confidence is high, smooth ramps form where the guide
        // has no edges, and depth stops dead at guide edges. No uniform median
        // afterwards — it existed to absorb rogue fill basins in the old
        // Voronoi fill and would re-quantize the fractional ramps.
        var depth: [Float]
        if let guide, isStale?() != true,
           let coeff = DepthRegularize.gridCoefficients(
                confidence: confidence, depthMed: index, guide: guide,
                width: width, height: height, planes: planes ?? [],
                luminancePlanes: luminancePlanes ?? [],
                factor: concentrationFactor, frameCount: frameCount,
                options: options, log: log, isStale: isStale) {
            progress?(0.7)
            depth = DepthRegularize.applyBlend(coefficients: coeff, guide: guide,
                                               confidence: confidence, depthMed: index,
                                               consensus: consensus.isEmpty ? nil : consensus,
                                               width: width, height: height,
                                               frameCount: frameCount)
        } else {
            // No guide (caller retained none) or no signal anywhere: keep the
            // median depth, just clamped.
            depth = index
            depth.withUnsafeMutableBufferPointer { dp in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for i in (y * width)..<((y + 1) * width) {
                        dp[i] = min(max(dp[i], 0), Float(frameCount - 1))
                    }
                }
            }
        }
        dumpPlane(depth, env: "HYPERFOCAL_DUMP_DEPTH")
        log?("depth map regularized (noise floor \(floor), guided)")
        progress?(1.0)
        return depth
    }

    /// Grayscale visualization of a depth plane: white = first frame (near),
    /// black = last (far), assuming the usual close-to-far capture order.
    public static func depthImage(from depth: [Float], width: Int, height: Int,
                                  frameCount: Int) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        let scale = frameCount > 1 ? 1 / Float(frameCount - 1) : 0
        depth.withUnsafeBufferPointer { dp in
            image.pixels.withUnsafeMutableBufferPointer { op in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for i in (y * width)..<((y + 1) * width) {
                        let v = 1 - dp[i] * scale
                        let pi = i * 4
                        op[pi] = v; op[pi + 1] = v; op[pi + 2] = v; op[pi + 3] = 1
                    }
                }
            }
        }
        return image
    }

    /// Confidence-weighted median over a subsampled window. Depth values are frame
    /// indices, so the median is exact via a per-pixel weight histogram over frames.
    /// Pixels whose window has no confident samples keep their value (push-pull
    /// handles them).
    ///
    /// With `consensusWindow` > 0 also returns per-pixel consensus: the
    /// fraction of the window's vote weight within ± that many frames of the
    /// chosen median. Individually-weak votes that agree — shadowed texture
    /// whose every pixel says the same depth — are dense-voting evidence the
    /// per-pixel confidence can't see; scattered noise votes converge to
    /// (2·window+1)/frames by chance and stay low.
    static func weightedMedianFilter(values: [Float], weights: [Float],
                                     width: Int, height: Int,
                                     radius: Int, bins: Int,
                                     consensusWindow: Int = 0) -> ([Float], [Float]) {
        let step = max(1, radius / 4)
        var out = values
        var consensus = [Float](repeating: 0,
                                count: consensusWindow > 0 ? width * height : 0)
        values.withUnsafeBufferPointer { vp in
            weights.withUnsafeBufferPointer { wp in
                out.withUnsafeMutableBufferPointer { op in
                    consensus.withUnsafeMutableBufferPointer { np in
                        DispatchQueue.concurrentPerform(iterations: height) { y in
                            var hist = [Float](repeating: 0, count: bins)
                            for x in 0..<width {
                                for i in 0..<bins { hist[i] = 0 }
                                var total: Float = 0
                                var dy = -radius
                                while dy <= radius {
                                    // Ternary clamps: Swift.min/max(Int,_)
                                    // stay outlined specialized calls per tap
                                    // at -O on the Mac toolchain (profiled
                                    // 2026-07-21); ternaries compile to csel.
                                    let y0 = y + dy
                                    let yy = y0 < 0 ? 0 : (y0 >= height ? height - 1 : y0)
                                    var dx = -radius
                                    while dx <= radius {
                                        let x0 = x + dx
                                        let xx = x0 < 0 ? 0 : (x0 >= width ? width - 1 : x0)
                                        let j = yy * width + xx
                                        let w = wp[j]
                                        if w > 1e-3 {
                                            let b0 = Int(vp[j] + 0.5)
                                            let b = b0 < 0 ? 0 : (b0 >= bins ? bins - 1 : b0)
                                            hist[b] += w
                                            total += w
                                        }
                                        dx += step
                                    }
                                    dy += step
                                }
                                if total > 1e-3 {
                                    let half = total * 0.5
                                    var acc: Float = 0
                                    var m = 0
                                    while m < bins - 1 {
                                        acc += hist[m]
                                        if acc >= half { break }
                                        m += 1
                                    }
                                    // Sub-bin interpolation: distribute the
                                    // winning bin's weight uniformly across
                                    // its width. Whole-frame plateaus would
                                    // otherwise posterize wherever the blend
                                    // trusts the median — frame-index steps
                                    // render as contour lines on smooth
                                    // background.
                                    let below = acc - hist[m]
                                    let frac = min(max((half - below)
                                                       / max(hist[m], 1e-9), 0), 1)
                                    op[y * width + x] = Float(m) - 0.5 + frac
                                    if consensusWindow > 0 {
                                        let lo = max(0, m - consensusWindow)
                                        let hi = min(bins - 1, m + consensusWindow)
                                        var agree: Float = 0
                                        for b in lo...hi { agree += hist[b] }
                                        np[y * width + x] = agree / total
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return (out, consensus)
    }

    /// Approximate 95th percentile via a subsample, robust to plane size.
    static func percentile95(_ plane: [Float]) -> Float {
        plane.withUnsafeBufferPointer { percentile95($0) }
    }

    static func percentile95(_ plane: UnsafeBufferPointer<Float>) -> Float {
        var sample = [Float]()
        sample.reserveCapacity(plane.count / 97 + 1)
        var i = 0
        while i < plane.count {
            sample.append(plane[i])
            i += 97
        }
        sample.sort()
        return sample[min(Int(Float(sample.count) * 0.95), sample.count - 1)]
    }
}
