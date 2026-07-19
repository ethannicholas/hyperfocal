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

    /// Fuses a StackSource: frames decode (prefetched) without warping, and
    /// alignment applies on the GPU when one is available. Prefer this over
    /// the closure form for aligned sources — `source.frame` warps on the
    /// CPU, which costs more than the fusion itself on big stacks.
    public static func fuse(source: StackSource, preferGPU: Bool = true,
                            log: ((String) -> Void)? = nil,
                            progress: ((Double, ImageBuffer?) -> Void)? = nil,
                            cancellation: CancellationToken? = nil) throws -> ImageBuffer {
        let warp = source.transforms.map {
            PyramidWarp(transforms: $0, outputWidth: source.outputWidth,
                        outputHeight: source.outputHeight)
        }
        return try fuse(frameCount: source.count, preferGPU: preferGPU,
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

    /// Streams frames in a single pass: only the running fused pyramid, per-level
    /// winner energies, and the current frame's pyramid are resident. Runs on
    /// the GPU when one is available (same algorithm, ≥ 60 dB agreement;
    /// `preferGPU: false` forces the CPU path), falling back to the CPU on
    /// Metal errors. The GPU path prefetches: `frame` may be invoked
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
                            frame: @escaping (Int) throws -> ImageBuffer) throws -> ImageBuffer {
        precondition(frameCount > 0)
        #if canImport(Metal)
        if preferGPU, MetalEngine.shared != nil {
            do {
                return try GPUPyramid.fuse(frameCount: frameCount, warp: warp,
                                           log: log, progress: progress,
                                           cancellation: cancellation,
                                           decodeWorkers: decodeWorkers, frame: frame)
            } catch let error as StackError {
                log?("GPU pyramid failed (\(error)); falling back to CPU")
            }
        }
        #endif
        #if HYPERFOCAL_HAVE_WGPU
        if preferGPU, WgpuEngine.shared != nil {
            do {
                return try WgpuPyramid.fuse(frameCount: frameCount, warp: warp,
                                            log: log, progress: progress,
                                            cancellation: cancellation,
                                            decodeWorkers: decodeWorkers, frame: frame)
            } catch let error as StackError {
                log?("wgpu pyramid failed (\(error)); falling back to CPU")
            }
        }
        #endif
        var levels = 0
        var fused: [ImageBuffer]? = nil
        // Winner energy per band-pass level, updated as frames stream through.
        var bestEnergy: [[Float]] = []

        for fi in 0..<frameCount {
            try cancellation?.checkCancelled()
            var img = try frame(fi)
            if let warp { img = warp.apply(img, at: fi) }
            if fused == nil {
                levels = max(3, Int(log2(Double(min(img.width, img.height)) / 16.0)))
            }
            let pyr = laplacianPyramid(img, levels: levels)
            if fused == nil {
                fused = pyr
                bestEnergy = pyr.dropLast().enumerated().map { l, band in
                    selectionEnergy(band, level: l)
                }
                // Base level accumulates a running sum for averaging.
            } else {
                for l in 0..<levels {
                    let band = pyr[l]
                    let energy = selectionEnergy(band, level: l)
                    let bw = band.width
                    fused![l].pixels.withUnsafeMutableBufferPointer { fp in
                        band.pixels.withUnsafeBufferPointer { bp in
                            energy.withUnsafeBufferPointer { ep in
                                bestEnergy[l].withUnsafeMutableBufferPointer { best in
                                    DispatchQueue.concurrentPerform(iterations: band.height) { y in
                                        for i in (y * bw)..<((y + 1) * bw) {
                                            if ep[i] > best[i] {
                                                best[i] = ep[i]
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
                for i in fused![levels].pixels.indices {
                    fused![levels].pixels[i] += pyr[levels].pixels[i]
                }
            }
            log?("pyramid \(fi + 1)/\(frameCount)")
            progress?(Double(fi + 1) / Double(frameCount), nil)
        }

        // Average the accumulated base level.
        let n = Float(frameCount)
        for i in fused![levels].pixels.indices {
            fused![levels].pixels[i] /= n
        }
        return collapse(fused!)
    }

    /// In-memory convenience for small stacks and tests.
    public static func fuse(_ frames: [ImageBuffer], log: ((String) -> Void)? = nil) -> ImageBuffer {
        // No throwing closure and no cancellation token: cannot actually throw.
        try! fuse(frameCount: frames.count, log: log) { frames[$0] }
    }

    /// Per-pixel selection energy of a band-pass level: sum of |RGB| coefficients.
    /// Grit-suppression blur applied to the finest level's selection energy.
    /// At full resolution the max-selector can't distinguish focused detail
    /// from single-pixel sensor noise — the documented cause of pyramid
    /// fusion's noise amplification (both Zerene and Helicon note it; Zerene
    /// ships default-on "grit suppression"). Smoothing the *energy* (never
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
