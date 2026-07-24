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
            for i in band.pixels.indices {
                band.pixels[i] = fine.pixels[i] - up.pixels[i]
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
            for i in up.pixels.indices {
                up.pixels[i] += band.pixels[i]
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
    /// real bright features. Runs on the Metal and wgpu paths
    /// (`GPUPyramid`/`WgpuPyramid`) as well as the CPU streaming loop; default
    /// (nil) leaves the standard PMax selection untouched.
    public struct FocusGate: Sendable {
        public var coarseLevels: Int
        public var threshold: Float
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
                            progress: ((Double, ImageBuffer?) -> Void)? = nil,
                            cancellation: CancellationToken? = nil,
                            focusGate: FocusGate? = nil) throws -> ImageBuffer {
        let warp = source.transforms.map {
            PyramidWarp(transforms: $0, outputWidth: source.outputWidth,
                        outputHeight: source.outputHeight)
        }
        return try fuse(frameCount: source.count, preferGPU: preferGPU,
                        warp: warp, log: log, progress: progress,
                        cancellation: cancellation,
                        decodeWorkers: FramePrefetcher.workers(for: source.urls),
                        focusGate: focusGate) { i in
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
                            progress: ((Double, ImageBuffer?) -> Void)? = nil,
                            cancellation: CancellationToken? = nil,
                            decodeWorkers: Int? = nil,
                            focusGate: FocusGate? = nil,
                            frame: @escaping (Int) throws -> ImageBuffer) throws -> ImageBuffer {
        precondition(frameCount > 0)
        // Focus-gate config (CLI/param, with env override for tuning). When on,
        // stay on the CPU — the GPU ports are a follow-up.
        let env = ProcessInfo.processInfo.environment
        let fgOn = focusGate != nil || env["HYPERFOCAL_PMAX_FOCUS_GATE"] != nil
        let fgCoarse = Int(env["HYPERFOCAL_PMAX_DARK_COARSE"] ?? "")
            ?? focusGate?.coarseLevels ?? (fgOn ? 5 : 0)
        let fgThreshold = Float(env["HYPERFOCAL_PMAX_FOCUS_THRESH"] ?? "")
            ?? focusGate?.threshold ?? 0.07
        let focusGateEnabled = fgOn && fgCoarse > 0
        if focusGateEnabled { log?("pmax: focus-gate on") }
        // Focus-gate config for the GPU paths (nil = standard PMax).
        let gpuFocusGate = focusGateEnabled
            ? GPUFocusGate(coarseLevels: fgCoarse, threshold: fgThreshold) : nil
        #if canImport(Metal)
        if preferGPU, MetalEngine.shared != nil {
            do {
                return try GPUPyramid.fuse(frameCount: frameCount, warp: warp,
                                           log: log, progress: progress,
                                           cancellation: cancellation,
                                           decodeWorkers: decodeWorkers,
                                           focusGate: gpuFocusGate, frame: frame)
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
                                            focusGate: gpuFocusGate, frame: frame)
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
        // Focus-gated coarse selection (see FocusGate): the bloom is a
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
        var bandBestLum: [[Float]] = []
        var trackB: [ImageBuffer] = []
        var hasFocus: [[Float]] = []
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
            for l in 0..<levels { ws.fusedDownsample(level: l) }
            ws.level0BandEnergy()
            tBuild += now() - t0
            t0 = now()
            ws.select0(fused: &fused![0], best: &bestEnergy[0])
            for l in 1..<levels {
                if focusGate && l >= levels - darkCoarse {
                    let focus = ws.focusDownsampled(toLevel: l)
                    ws.selectStreamingFocusGated(level: l, focus: focus, threshold: focusThresh,
                                                 fused: &fused![l], bestE: &bestEnergy[l],
                                                 trackB: &trackB[l], bestDarkLum: &bandBestLum[l],
                                                 hasFocus: &hasFocus[l])
                } else if darkCoarse > 0 && l >= levels - darkCoarse {
                    ws.selectStreamingDark(level: l, fused: &fused![l], bestLum: &bandBestLum[l])
                } else {
                    ws.selectStreaming(level: l, fused: &fused![l], best: &bestEnergy[l])
                }
            }
            if useDarkBase {
                // Keep the least-luminous frame's base RGB at each cell.
                fused![levels].pixels.withUnsafeMutableBufferPointer { fp in
                    ws.gauss[levels].withUnsafeBufferPointer { gp in
                        baseBestLum.withUnsafeMutableBufferPointer { bl in
                            for i in 0..<bl.count {
                                let pi = i * 4
                                let lum = 0.2126 * gp[pi] + 0.7152 * gp[pi + 1] + 0.0722 * gp[pi + 2]
                                if lum < bl[i] {
                                    bl[i] = lum
                                    fp[pi] = gp[pi]; fp[pi + 1] = gp[pi + 1]
                                    fp[pi + 2] = gp[pi + 2]; fp[pi + 3] = gp[pi + 3]
                                }
                            }
                        }
                    }
                }
            } else {
                // Base level accumulates a running sum for averaging.
                fused![levels].pixels.withUnsafeMutableBufferPointer { fp in
                    ws.gauss[levels].withUnsafeBufferPointer { gp in
                        for i in 0..<gp.count { fp[i] += gp[i] }
                    }
                }
            }
            tSelect += now() - t0
            log?("pyramid \(fi + 1)/\(frameCount)")
            progress?(Double(fi + 1) / Double(frameCount), nil)
        }

        // Average the accumulated base level (unless darkest-base kept a winner).
        if !useDarkBase {
            let n = Float(frameCount)
            for i in fused![levels].pixels.indices {
                fused![levels].pixels[i] /= n
            }
        }
        // Focus-gate merge: keep track A (max-energy among in-focus frames)
        // where any frame was in focus, else track B (darkest, bloom-free).
        if focusGate {
            for l in 1..<levels where l >= levels - darkCoarse {
                let hf = hasFocus[l]
                fused![l].pixels.withUnsafeMutableBufferPointer { ap in
                    trackB[l].pixels.withUnsafeBufferPointer { bp in
                        for i in 0..<hf.count where hf[i] < 0.5 {
                            let pi = i * 4
                            ap[pi] = bp[pi]; ap[pi + 1] = bp[pi + 1]
                            ap[pi + 2] = bp[pi + 2]; ap[pi + 3] = bp[pi + 3]
                        }
                    }
                }
            }
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
        var gauss: [[Float]]      // levels+1 Gaussian levels, RGBA
        var band: [Float]         // level-0 band, RGBA (kept for post-blur select)
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
            gauss = s.map { [Float](repeating: 0, count: $0.w * $0.h * 4) }
            band = [Float](repeating: 0, count: width * height * 4)
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
            gauss[l].withUnsafeBufferPointer { src in
                gauss[l + 1].withUnsafeMutableBufferPointer { dst in
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
                                            let i = (rowOff + tx) * 4
                                            acc += SIMD4<Float>(src[i], src[i + 1],
                                                                src[i + 2], src[i + 3]) * kp[kx]
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
                                    let o = (oy * nw + ox) * 4
                                    dst[o] = acc.x; dst[o + 1] = acc.y
                                    dst[o + 2] = acc.z; dst[o + 3] = acc.w
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
        private static func upsampleAt(_ src: UnsafeBufferPointer<Float>,
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
            var out = SIMD4<Float>()
            for c in 0..<4 {
                let top = src[i00 + c] * (1 - wx) + src[i10 + c] * wx
                let bot = src[i01 + c] * (1 - wx) + src[i11 + c] * wx
                out[c] = top * (1 - wy) + bot * wy
            }
            return out
        }

        /// Level 0: band + energy in one streaming pass (band kept — the
        /// select must wait for the grit blur), then the energy blur.
        func level0BandEnergy() {
            let (w, h) = sizes[0]
            let (nw, nh) = sizes[1]
            let sx = Float(nw) / Float(w), sy = Float(nh) / Float(h)
            gauss[0].withUnsafeBufferPointer { fine in
                gauss[1].withUnsafeBufferPointer { coarse in
                    band.withUnsafeMutableBufferPointer { bp in
                        energy.withUnsafeMutableBufferPointer { ep in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for x in 0..<w {
                                    let up = Self.upsampleAt(coarse, sw: nw, sh: nh,
                                                             x: x, y: y, scaleX: sx, scaleY: sy)
                                    let i = (y * w + x) * 4
                                    let b = SIMD4<Float>(fine[i], fine[i + 1],
                                                         fine[i + 2], fine[i + 3]) - up
                                    bp[i] = b.x; bp[i + 1] = b.y
                                    bp[i + 2] = b.z; bp[i + 3] = b.w
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
        func selectStreamingFocusGated(level l: Int, focus: [Float], threshold: Float,
                                       fused: inout ImageBuffer, bestE: inout [Float],
                                       trackB: inout ImageBuffer, bestDarkLum: inout [Float],
                                       hasFocus: inout [Float]) {
            let (w, h) = sizes[l]
            let (nw, nh) = sizes[l + 1]
            let sx = Float(nw) / Float(w), sy = Float(nh) / Float(h)
            gauss[l].withUnsafeBufferPointer { fine in
              gauss[l + 1].withUnsafeBufferPointer { coarse in
                fused.pixels.withUnsafeMutableBufferPointer { ap in
                  trackB.pixels.withUnsafeMutableBufferPointer { bp in
                    bestE.withUnsafeMutableBufferPointer { be in
                      bestDarkLum.withUnsafeMutableBufferPointer { bd in
                        hasFocus.withUnsafeMutableBufferPointer { hf in
                          focus.withUnsafeBufferPointer { fo in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                              for x in 0..<w {
                                let i = y * w + x
                                let pi = i * 4
                                let up = Self.upsampleAt(coarse, sw: nw, sh: nh,
                                                         x: x, y: y, scaleX: sx, scaleY: sy)
                                let bx = fine[pi] - up.x, by = fine[pi + 1] - up.y
                                let bz = fine[pi + 2] - up.z, bw = fine[pi + 3] - up.w
                                if fo[i] > threshold {
                                    let e = abs(bx) + abs(by) + abs(bz)
                                    if e > be[i] {
                                        be[i] = e; hf[i] = 1
                                        ap[pi] = bx; ap[pi + 1] = by
                                        ap[pi + 2] = bz; ap[pi + 3] = bw
                                    }
                                } else {
                                    let lum = 0.2126 * fine[pi] + 0.7152 * fine[pi + 1]
                                            + 0.0722 * fine[pi + 2]
                                    if lum < bd[i] {
                                        bd[i] = lum
                                        bp[pi] = bx; bp[pi + 1] = by
                                        bp[pi + 2] = bz; bp[pi + 3] = bw
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
            gauss[l].withUnsafeBufferPointer { fine in
                gauss[l + 1].withUnsafeBufferPointer { coarse in
                    fused.pixels.withUnsafeMutableBufferPointer { fp in
                        bestLum.withUnsafeMutableBufferPointer { bl in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for x in 0..<w {
                                    let i = y * w + x
                                    let pi = i * 4
                                    let lum = 0.2126 * fine[pi] + 0.7152 * fine[pi + 1]
                                            + 0.0722 * fine[pi + 2]
                                    if lum < bl[i] {
                                        bl[i] = lum
                                        let up = Self.upsampleAt(coarse, sw: nw, sh: nh,
                                                                 x: x, y: y, scaleX: sx, scaleY: sy)
                                        fp[pi] = fine[pi] - up.x
                                        fp[pi + 1] = fine[pi + 1] - up.y
                                        fp[pi + 2] = fine[pi + 2] - up.z
                                        fp[pi + 3] = fine[pi + 3] - up.w
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
            gauss[l].withUnsafeBufferPointer { fine in
                gauss[l + 1].withUnsafeBufferPointer { coarse in
                    fused.pixels.withUnsafeMutableBufferPointer { fp in
                        best.withUnsafeMutableBufferPointer { be in
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for x in 0..<w {
                                    let up = Self.upsampleAt(coarse, sw: nw, sh: nh,
                                                             x: x, y: y, scaleX: sx, scaleY: sy)
                                    let i = y * w + x
                                    let pi = i * 4
                                    let b = SIMD4<Float>(fine[pi], fine[pi + 1],
                                                         fine[pi + 2], fine[pi + 3]) - up
                                    let e = abs(b.x) + abs(b.y) + abs(b.z)
                                    if e > be[i] {
                                        be[i] = e
                                        fp[pi] = b.x; fp[pi + 1] = b.y
                                        fp[pi + 2] = b.z; fp[pi + 3] = b.w
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
        band.pixels.withUnsafeBufferPointer { bp in
            energy.withUnsafeMutableBufferPointer { ep in
                DispatchQueue.concurrentPerform(iterations: band.height) { y in
                    for i in (y * band.width)..<((y + 1) * band.width) {
                        let pi = i * 4
                        ep[i] = abs(bp[pi]) + abs(bp[pi + 1]) + abs(bp[pi + 2])
                    }
                }
            }
        }
        return energy
    }
}
