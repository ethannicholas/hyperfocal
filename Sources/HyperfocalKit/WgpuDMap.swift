#if HYPERFOCAL_HAVE_WGPU
import Foundation
import Dispatch

/// wgpu port of `GPUDMap` — depth-map fusion with decode on CPU (prefetched)
/// and all per-pixel work (warp, sharpness energy, argmax, depth
/// regularization, tent render) on the GPU. The CPU↔GPU bar is ≥ 90 dB (the
/// Metal DMap's bar): unlike the pyramid's running-max, nothing here
/// amplifies fast-math ties, so agreement tracks kernel precision.
///
/// The Metal path's mid-frame CPU dependency — the exposure gain is measured
/// on the *warped* frame between the warp and argmax dispatches — costs a
/// readback here (wgpu buffers aren't host-visible). That download is shared
/// with the frame spill, which also needs warped pixels on the host; when
/// neither is on and the frame needs no warp, the decoded pixels serve
/// directly and nothing is downloaded.
public enum WgpuDMap {

    // Uniform layouts matching the WGSL structs in WgpuEngine.kernelSource.
    struct WarpParams {
        var r0: SIMD4<Float>
        var r1: SIMD4<Float>
        var r2: SIMD4<Float>
        var dims: SIMD4<UInt32>   // srcW, srcH, dstW, dstH
    }
    struct BlurParams { var width: UInt32; var height: UInt32; var radius: Int32; var pad: UInt32 = 0 }
    struct Dims2 { var w: UInt32; var h: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct Count1 { var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }
    struct ArgmaxParams { var frameIdx: Float; var count: UInt32; var gain: Float; var pad: UInt32 = 0 }
    struct TentParams {
        var gain: SIMD4<Float>
        var index: Float
        var radius: Float
        var count: UInt32
        var pad: UInt32 = 0
    }
    struct PreviewParams { var srcW: UInt32; var srcH: UInt32; var dstW: UInt32; var dstH: UInt32 }
    struct PlanePreviewParams {
        var srcW: UInt32; var srcH: UInt32; var dstW: UInt32; var dstH: UInt32
        var scale: Float; var bias: Float
        var pad0: UInt32 = 0; var pad1: UInt32 = 0
    }
    struct BoxDownParams {
        var srcW: UInt32; var srcH: UInt32; var dstW: UInt32; var dstH: UInt32
        var factor: UInt32
        var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0
    }
    struct ConfidenceParams {
        var width: UInt32; var concW: UInt32; var concH: UInt32; var factor: UInt32
        var halfFloor: Float; var conc2: Float
        var count: UInt32; var pad: UInt32 = 0
    }
    struct MedianParams {
        var width: UInt32; var height: UInt32; var radius: Int32; var step: Int32
        var bins: UInt32; var consensusWindow: Int32
        var pad0: UInt32 = 0; var pad1: UInt32 = 0
    }
    struct GuidedApplyParams {
        var width: UInt32; var height: UInt32; var gridW: UInt32; var gridH: UInt32
        var invFactor: Float; var guideScale: Float; var maxIndex: Float; var residualW2: Float
        var hasSpill: UInt32
        var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0
    }
    struct ClampParams { var maxV: Float; var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct FillParams { var v: Float; var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }

    private static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    public static func fuseWithDepth(source: StackSource,
                                     options: DMapFusion.Options = DMapFusion.Options(),
                                     log: ((String) -> Void)? = nil,
                                     progress: FusionProgressHandler? = nil,
                                     cancellation: CancellationToken? = nil) throws -> DMapFusion.Output {
        guard let engine = WgpuEngine.shared else {
            throw StackError.metal("no wgpu adapter available")
        }
        let frameCount = source.count
        precondition(frameCount > 0)

        // Resolve every kernel up front so a missing entry point fails loudly
        // before any decode work starts.
        for name in ["warp_lanczos3", "lum_laplacian", "blur_h", "blur_v",
                     "argmax_update", "tent_accumulate", "normalize_out",
                     "progressive_preview", "plane_preview", "box_downsample",
                     "luma_plane", "confidence_map", "weighted_median",
                     "guided_apply_blend", "clamp_plane", "pyr_fill"] {
            _ = try engine.pipeline(name)
        }

        let blurWeights = Filters.gaussianKernel(sigma: options.sharpnessSigma)
        let blurRadius = blurWeights.count / 2

        var width = 0, height = 0, pixelCount = 0   // output canvas (may be cropped)
        var srcWidth = 0, srcHeight = 0             // source frame dimensions
        var rawBuf: WgpuEngine.Buffer!, warpedBuf: WgpuEngine.Buffer!
        var lapBuf: WgpuEngine.Buffer!, tmpBuf: WgpuEngine.Buffer!, energyBuf: WgpuEngine.Buffer!
        var bestEBuf: WgpuEngine.Buffer!, bestIdxBuf: WgpuEngine.Buffer!
        var previewBuf: WgpuEngine.Buffer!
        var pw = 0, ph = 0
        var sharpBuf: WgpuEngine.Buffer!
        var lumGridBuf: WgpuEngine.Buffer!
        var guideBuf: WgpuEngine.Buffer!
        var blurWeightsBuf: WgpuEngine.Buffer!
        var sw = 0, sh = 0
        var sharpnessPlanes: [[Float]] = []
        var luminancePlanes: [[Float]] = []  // per-frame grid luminance (spill floor)
        var gains0 = [SIMD3<Float>]()  // per-channel gain per frame, vs frame 0
        var meanRGB0 = SIMD3<Float>(repeating: 1)
        // Host copy of the warped frame, for the exposure mean and the spill
        // (allocated only when a warp makes the device copy the only one).
        var warpedHost: [Float] = []

        let wantSpill = FrameSpill.wanted(options.spillEnabled)
        var spill: FrameSpill?
        var tSpillWrite = 0.0, tSpillRead = 0.0
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

        func downloadPreview() throws -> ImageBuffer {
            var preview = ImageBuffer(width: pw, height: ph)
            try preview.pixels.withUnsafeMutableBufferPointer {
                try engine.download(previewBuf, into: $0.baseAddress!,
                                    byteCount: pw * ph * 16)
            }
            return preview
        }

        /// Stages the frame upload and encodes its warp when the source has
        /// transforms (always through `warp_lanczos3`, like the Metal path —
        /// no identity fast path); returns the buffer the frame's aligned
        /// pixels land in.
        func encodeUploadAndWarp(_ img: ImageBuffer, frameIndex: Int,
                                 batch: WgpuEngine.Batch) throws -> WgpuEngine.Buffer {
            img.pixels.withUnsafeBufferPointer {
                engine.upload($0.baseAddress!, byteCount: $0.count * 4, to: rawBuf)
            }
            guard let t = source.transforms?[frameIndex] else {
                return rawBuf  // no alignment: output dims == source dims
            }
            let h = t.inverse  // output → source
            let params = WarpParams(
                r0: SIMD4<Float>(h[0][0], h[1][0], h[2][0], 0),
                r1: SIMD4<Float>(h[0][1], h[1][1], h[2][1], 0),
                r2: SIMD4<Float>(h[0][2], h[1][2], h[2][2], 0),
                dims: SIMD4<UInt32>(UInt32(srcWidth), UInt32(srcHeight),
                                    UInt32(width), UInt32(height)))
            try batch.dispatch("warp_lanczos3", buffers: [rawBuf, warpedBuf],
                               uniforms: bytes(of: params), gridW: width, gridH: height)
            return warpedBuf
        }

        // Pass 1: per-pixel argmax of smoothed |Laplacian| across the stack.
        let prefetcher = FramePrefetcher(indices: Array(0..<frameCount),
                                         workers: FramePrefetcher.workers(for: source.urls)) {
            try ImageFile.load(url: source.urls[$0])
        }
        for _ in 0..<frameCount {
            try cancellation?.checkCancelled()
            let (fi, img) = try prefetcher.next()
            if fi == 0 {
                srcWidth = img.width
                srcHeight = img.height
                width = source.outputWidth ?? img.width
                height = source.outputHeight ?? img.height
                pixelCount = width * height
                rawBuf = try engine.makeBuffer(floats: srcWidth * srcHeight * 4)
                warpedBuf = try engine.makeBuffer(floats: pixelCount * 4)
                lapBuf = try engine.makeBuffer(floats: pixelCount)
                tmpBuf = try engine.makeBuffer(floats: pixelCount)
                energyBuf = try engine.makeBuffer(floats: pixelCount)
                bestEBuf = try engine.makeBuffer(floats: pixelCount)
                bestIdxBuf = try engine.makeBuffer(floats: pixelCount)
                let previewScale = min(1.0, 1200.0 / Double(max(width, height)))
                pw = max(1, Int(Double(width) * previewScale))
                ph = max(1, Int(Double(height) * previewScale))
                previewBuf = try engine.makeBuffer(floats: pw * ph * 4)
                let factor = DMapFusion.sharpnessDownsample
                sw = (width + factor - 1) / factor
                sh = (height + factor - 1) / factor
                sharpBuf = try engine.makeBuffer(floats: sw * sh)
                lumGridBuf = try engine.makeBuffer(floats: sw * sh)
                guideBuf = try engine.makeBuffer(floats: pixelCount)
                blurWeightsBuf = try engine.makeBuffer(floats: blurWeights.count)
                blurWeights.withUnsafeBytes {
                    engine.upload($0.baseAddress!, byteCount: $0.count, to: blurWeightsBuf)
                }
                // Explicit zero fills (not the spec's lazy zero-init) so a
                // rerun on recycled buffers can never inherit stale state.
                let init0 = try engine.makeBatch()
                for buf in [bestEBuf!, bestIdxBuf!, guideBuf!] {
                    try init0.dispatch("pyr_fill", buffers: [buf],
                                       uniforms: bytes(of: FillParams(v: 0, count: UInt32(pixelCount))),
                                       gridW: pixelCount)
                }
                init0.submit()
                if wantSpill {
                    spill = FrameSpill(frameBytes: pixelCount * 16,
                                       frameCount: frameCount, log: log)
                }
                if source.transforms != nil,
                   options.normalizeExposure || spill != nil {
                    warpedHost = [Float](repeating: 0, count: pixelCount * 4)
                }
            }
            guard img.width == srcWidth && img.height == srcHeight else {
                throw StackError.metal("frame \(fi) size mismatch: \(img.width)x\(img.height) vs \(srcWidth)x\(srcHeight)")
            }

            // The exposure gain is measured on the *warped* frame (same
            // domain as the CPU path) and feeds the argmax dispatch as a
            // uniform, so when a warp runs and the mean (or the spill) needs
            // the pixels, the warp submits alone and its output downloads
            // before the rest of the frame encodes. Unwarped frames skip the
            // round trip — the decoded pixels are the warped pixels.
            var hostPixels: [Float]? = nil  // aligned frame on the host, when needed
            let needHost = options.normalizeExposure || spill != nil
            let didWarp = source.transforms?[fi] != nil
            let batch: WgpuEngine.Batch
            let input: WgpuEngine.Buffer
            if didWarp && needHost {
                let warpBatch = try engine.makeBatch()
                input = try encodeUploadAndWarp(img, frameIndex: fi, batch: warpBatch)
                warpBatch.submit()
                try warpedHost.withUnsafeMutableBytes {
                    try engine.download(input, into: $0.baseAddress!,
                                        byteCount: pixelCount * 16)
                }
                hostPixels = warpedHost
                batch = try engine.makeBatch()
            } else {
                batch = try engine.makeBatch()
                input = try encodeUploadAndWarp(img, frameIndex: fi, batch: batch)
                if needHost { hostPixels = img.pixels }
            }

            let mean = options.normalizeExposure
                ? DMapFusion.meanChannels(pixels: hostPixels!)
                : SIMD3<Float>(repeating: 1)
            if fi == 0 { meanRGB0 = mean }
            // Scalar luminance gain for the scoring side (energy plane, guide);
            // the per-channel gains are for the render (see DMapFusion).
            let gain: Float = options.normalizeExposure
                ? min(max(DMapFusion.luma(meanRGB0) / max(DMapFusion.luma(mean), 1e-6), 0.5), 2)
                : 1
            gains0.append(options.normalizeExposure
                ? (meanRGB0 / pointwiseMax(mean, .init(repeating: 1e-6)))
                    .clamped(lowerBound: .init(repeating: 0.5),
                             upperBound: .init(repeating: 2))
                : .one)

            try batch.dispatch("lum_laplacian", buffers: [input, lapBuf],
                               uniforms: bytes(of: Dims2(w: UInt32(width), h: UInt32(height))),
                               gridW: width, gridH: height)
            let blurParams = BlurParams(width: UInt32(width), height: UInt32(height),
                                        radius: Int32(blurRadius))
            try batch.dispatch("blur_h", buffers: [lapBuf, tmpBuf, blurWeightsBuf],
                               uniforms: bytes(of: blurParams), gridW: width, gridH: height)
            try batch.dispatch("blur_v", buffers: [tmpBuf, energyBuf, blurWeightsBuf],
                               uniforms: bytes(of: blurParams), gridW: width, gridH: height)

            // The kernel also records the winning frame's luminance — the
            // regularizer's all-in-focus guide estimate.
            try batch.dispatch("argmax_update",
                               buffers: [energyBuf, input, bestEBuf, bestIdxBuf, guideBuf],
                               uniforms: bytes(of: ArgmaxParams(frameIdx: Float(fi),
                                                                count: UInt32(pixelCount),
                                                                gain: gain)),
                               gridW: pixelCount)

            // Retain this frame's raw sharpness at reduced resolution — the
            // pre-regularization measurement retouching queries later.
            let boxParams = BoxDownParams(srcW: UInt32(width), srcH: UInt32(height),
                                          dstW: UInt32(sw), dstH: UInt32(sh),
                                          factor: UInt32(DMapFusion.sharpnessDownsample))
            try batch.dispatch("box_downsample", buffers: [energyBuf, sharpBuf],
                               uniforms: bytes(of: boxParams), gridW: sw, gridH: sh)

            // Grid luminance for the spill floor (tmpBuf is free after the
            // blurs). Same shape as the retained sharpness planes.
            try batch.dispatch("luma_plane", buffers: [input, tmpBuf],
                               uniforms: bytes(of: Count1(count: UInt32(pixelCount))),
                               gridW: pixelCount)
            try batch.dispatch("box_downsample", buffers: [tmpBuf, lumGridBuf],
                               uniforms: bytes(of: boxParams), gridW: sw, gridH: sh)

            if progress != nil {
                // Snapshot the argmax plane — the depth map forming. Inverted so
                // near (first frame, close-to-far capture order) is bright.
                let planeParams = PlanePreviewParams(
                    srcW: UInt32(width), srcH: UInt32(height),
                    dstW: UInt32(pw), dstH: UInt32(ph),
                    scale: frameCount > 1 ? -1 / Float(frameCount - 1) : 0,
                    bias: 1)
                try batch.dispatch("plane_preview", buffers: [bestIdxBuf, previewBuf],
                                   uniforms: bytes(of: planeParams), gridW: pw, gridH: ph)
            }
            batch.submit()

            // Spill the aligned frame while the GPU chews on it (the host
            // copy already exists). A failed write just degrades pass 2 back
            // to re-decoding — never fails the fuse.
            if let s = spill, let hostPixels {
                let t0 = now()
                do {
                    try hostPixels.withUnsafeBufferPointer {
                        try s.write(frame: fi, from: $0.baseAddress!)
                    }
                } catch {
                    log?("frame spill write failed (\(error)) — render pass will re-decode")
                    spill = nil
                }
                tSpillWrite += now() - t0
            }

            // The sharp/luminance grid downloads wait out the frame's GPU work.
            var plane = [Float](repeating: 0, count: sw * sh)
            try plane.withUnsafeMutableBytes {
                try engine.download(sharpBuf, into: $0.baseAddress!)
            }
            if gain != 1 {
                // The retained sharpness must match what the argmax compared.
                for i in plane.indices { plane[i] *= gain }
            }
            sharpnessPlanes.append(plane)
            var lumPlane = [Float](repeating: 0, count: sw * sh)
            try lumPlane.withUnsafeMutableBytes {
                try engine.download(lumGridBuf, into: $0.baseAddress!)
            }
            if gain != 1 {
                for i in lumPlane.indices { lumPlane[i] *= gain }
            }
            luminancePlanes.append(lumPlane)
            log?("depth pass \(fi + 1)/\(frameCount)")
            if let progress {
                progress(FusionProgress(stage: .depth,
                                        fraction: Double(fi + 1) / Double(frameCount),
                                        preview: try downloadPreview(),
                                        previewFullWidth: width, previewFullHeight: height,
                                        sourceFrameIndex: fi,
                                        sourcePreview: img.downsampledNearest(maxSide: 1200),
                                        sourceFullWidth: img.width, sourceFullHeight: img.height))
            }
        }

        // Winner-frame luminance guide, written by the argmax kernel, then
        // low-passed (same separable blur as the CPU path — see
        // DMapFusion.guideSigma). The shared grid stage reads this same
        // plane the apply kernel samples.
        let guideWeights = Filters.gaussianKernel(sigma: DMapFusion.guideSigma)
        let guideWeightsBuf = try engine.makeBuffer(floats: guideWeights.count)
        guideWeights.withUnsafeBytes {
            engine.upload($0.baseAddress!, byteCount: $0.count, to: guideWeightsBuf)
        }
        let guideBatch = try engine.makeBatch()
        let guideParams = BlurParams(width: UInt32(width), height: UInt32(height),
                                     radius: Int32(guideWeights.count / 2))
        try guideBatch.dispatch("blur_h", buffers: [guideBuf, tmpBuf, guideWeightsBuf],
                                uniforms: bytes(of: guideParams), gridW: width, gridH: height)
        try guideBatch.dispatch("blur_v", buffers: [tmpBuf, guideBuf, guideWeightsBuf],
                                uniforms: bytes(of: guideParams), gridW: width, gridH: height)
        guideBatch.submit()
        var guide = [Float](repeating: 0, count: pixelCount)
        try guide.withUnsafeMutableBytes {
            try engine.download(guideBuf, into: $0.baseAddress!)
        }
        DMapFusion.dumpGuide(guide)

        // Depth regularization on GPU (same chain as the CPU path).
        // Peak concentration from the retained planes — the identical
        // computation the CPU path runs, so both engines gate the same pixels.
        let concentration = DMapFusion.peakConcentrationPlane(planes: sharpnessPlanes)
        let depth = try regularizeDepth(engine: engine, bestEBuf: bestEBuf,
                                        bestIdxBuf: bestIdxBuf,
                                        concentration: concentration,
                                        concentrationWidth: sw,
                                        planes: sharpnessPlanes,
                                        luminancePlanes: luminancePlanes,
                                        guide: guide, guideBuf: guideBuf,
                                        width: width, height: height,
                                        frameCount: frameCount, options: options,
                                        log: log, cancellation: cancellation) {
            progress?(FusionProgress(stage: .regularizing, fraction: $0))
        }

        let gains = DMapFusion.renderGains(from: gains0, options: options, log: log)

        // Pass 2: render by blending frames near each pixel's depth (tent kernel).
        let radius = max(options.blendRadius, DMapFusion.minBlendRadius)
        var depthLo: Float = .infinity, depthHi: Float = -.infinity
        for d in depth {
            if d < depthLo { depthLo = d }
            if d > depthHi { depthHi = d }
        }
        let renderIndices = (0..<frameCount).filter {
            Float($0) > depthLo - radius && Float($0) < depthHi + radius
        }
        if renderIndices.count < frameCount {
            log?("render pass skips \(frameCount - renderIndices.count) unused frames")
        }

        let depthBuf = try engine.makeBuffer(floats: pixelCount)
        depth.withUnsafeBytes {
            engine.upload($0.baseAddress!, byteCount: $0.count, to: depthBuf)
        }
        let accumBuf = try engine.makeBuffer(floats: pixelCount * 4)
        let wsumBuf = try engine.makeBuffer(floats: pixelCount)
        let initRender = try engine.makeBatch()
        try initRender.dispatch("pyr_fill", buffers: [accumBuf],
                                uniforms: bytes(of: FillParams(v: 0, count: UInt32(pixelCount * 4))),
                                gridW: pixelCount * 4)
        try initRender.dispatch("pyr_fill", buffers: [wsumBuf],
                                uniforms: bytes(of: FillParams(v: 0, count: UInt32(pixelCount))),
                                gridW: pixelCount)
        initRender.submit()

        // Frames come back from the spill file when pass 1 captured one
        // (bit-identical to a re-warp); otherwise decode + warp again.
        var renderPrefetcher: FramePrefetcher?
        if spill == nil {
            renderPrefetcher = FramePrefetcher(indices: renderIndices,
                                               workers: FramePrefetcher.workers(for: source.urls)) {
                try ImageFile.load(url: source.urls[$0])
            }
        }
        var renderedCount = 0
        for step in renderIndices.indices {
            try cancellation?.checkCancelled()
            let batch = try engine.makeBatch()
            let fi: Int
            let input: WgpuEngine.Buffer
            var sourcePreview: ImageBuffer?
            var sourceW = 0, sourceH = 0
            if let spill {
                fi = renderIndices[step]
                let t0 = now()
                if warpedHost.isEmpty {
                    warpedHost = [Float](repeating: 0, count: pixelCount * 4)
                }
                try warpedHost.withUnsafeMutableBytes {
                    try spill.read(frame: fi, into: $0.baseAddress!)
                }
                tSpillRead += now() - t0
                warpedHost.withUnsafeBufferPointer {
                    engine.upload($0.baseAddress!, byteCount: $0.count * 4, to: warpedBuf)
                }
                input = warpedBuf
                if progress != nil {
                    // The spill holds the *warped* frame — show that (the
                    // aligned frame on the output canvas) as the source.
                    sourcePreview = warpedHost.withUnsafeBufferPointer {
                        ImageBuffer.downsampledNearest(
                            fromRGBA: $0.baseAddress!,
                            width: width, height: height, maxSide: 1200)
                    }
                    sourceW = width
                    sourceH = height
                }
            } else {
                let (idx, img) = try renderPrefetcher!.next()
                fi = idx
                input = try encodeUploadAndWarp(img, frameIndex: fi, batch: batch)
                if progress != nil {
                    sourcePreview = img.downsampledNearest(maxSide: 1200)
                    sourceW = img.width
                    sourceH = img.height
                }
            }

            try batch.dispatch("tent_accumulate",
                               buffers: [input, depthBuf, accumBuf, wsumBuf],
                               uniforms: bytes(of: TentParams(gain: SIMD4(gains?[fi] ?? .one, 0),
                                                              index: Float(fi), radius: radius,
                                                              count: UInt32(pixelCount))),
                               gridW: pixelCount)

            if progress != nil {
                let previewParams = PreviewParams(srcW: UInt32(width), srcH: UInt32(height),
                                                  dstW: UInt32(pw), dstH: UInt32(ph))
                try batch.dispatch("progressive_preview",
                                   buffers: [accumBuf, wsumBuf, previewBuf],
                                   uniforms: bytes(of: previewParams), gridW: pw, gridH: ph)
            }
            batch.submit()
            // Per-frame wait: keeps the staged-upload window bounded (a
            // frame's upload is pixelCount × 16 bytes of staging until the
            // GPU consumes it) and the progress preview coherent.
            engine.waitIdle()
            log?("render pass \(fi + 1)/\(frameCount)")
            renderedCount += 1
            if let progress {
                progress(FusionProgress(stage: .render,
                                        fraction: Double(renderedCount) / Double(renderIndices.count),
                                        preview: try downloadPreview(),
                                        previewFullWidth: width, previewFullHeight: height,
                                        sourceFrameIndex: fi,
                                        sourcePreview: sourcePreview,
                                        sourceFullWidth: sourceW, sourceFullHeight: sourceH))
            }
        }
        if spill != nil {
            let frameGB = Double(pixelCount) * 16 / Double(1 << 30)
            log?(String(format: "spill: wrote %.1f GB in %.2fs, read %.1f GB in %.2fs",
                        frameGB * Double(frameCount), tSpillWrite,
                        frameGB * Double(renderIndices.count), tSpillRead))
        }

        // Normalize into rawBuf (no longer needed as input) and download.
        let normBatch = try engine.makeBatch()
        try normBatch.dispatch("normalize_out", buffers: [accumBuf, wsumBuf, rawBuf],
                               uniforms: bytes(of: Count1(count: UInt32(pixelCount))),
                               gridW: pixelCount)
        normBatch.submit()
        var out = ImageBuffer(width: width, height: height)
        try out.pixels.withUnsafeMutableBufferPointer {
            try engine.download(rawBuf, into: $0.baseAddress!,
                                byteCount: pixelCount * 16)
        }
        return DMapFusion.Output(image: out,
                                 depthMap: DMapFusion.depthImage(from: depth, width: width,
                                                                 height: height,
                                                                 frameCount: frameCount),
                                 depth: depth,
                                 sharpness: FrameSharpness(fullWidth: width, fullHeight: height,
                                                           factor: DMapFusion.sharpnessDownsample,
                                                           planes: sharpnessPlanes),
                                 gains: gains)
    }

    /// The regularization chain (confidence → weighted median → guided filter
    /// + preservation blend → clamp), mirroring `GPUDMap.regularizeDepth`:
    /// grid-level work is the shared CPU stage over downloaded planes; only
    /// the full-res confidence, median, and apply passes run as kernels.
    /// Phases run as separate submits so progress and cancellation stay
    /// responsive. `bestIdxBuf` is consumed as scratch.
    static func regularizeDepth(engine: WgpuEngine,
                                bestEBuf: WgpuEngine.Buffer, bestIdxBuf: WgpuEngine.Buffer,
                                concentration: [Float], concentrationWidth: Int,
                                planes: [[Float]],
                                luminancePlanes: [[Float]] = [],
                                guide: [Float], guideBuf: WgpuEngine.Buffer,
                                width: Int, height: Int, frameCount: Int,
                                options: DMapFusion.Options,
                                log: ((String) -> Void)?,
                                cancellation: CancellationToken?,
                                progress: ((Double) -> Void)? = nil) throws -> [Float] {
        let pixelCount = width * height

        var energies = [Float](repeating: 0, count: pixelCount)
        try energies.withUnsafeMutableBytes {
            try engine.download(bestEBuf, into: $0.baseAddress!)
        }
        let floor = max(1e-6, options.noiseFloor * DMapFusion.percentile95(energies))
        let halfFloor = floor / 2
        let conc2 = options.peakConcentration * options.peakConcentration
        let factor = DMapFusion.sharpnessDownsample

        let concBuf = try engine.makeBuffer(floats: max(concentration.count, 1))
        concentration.withUnsafeBytes {
            if $0.count > 0 {
                engine.upload($0.baseAddress!, byteCount: $0.count, to: concBuf)
            }
        }
        let confBuf = try engine.makeBuffer(floats: pixelCount)
        let medBuf = try engine.makeBuffer(floats: pixelCount)
        // Consensus from the weighted median (zero when the median is
        // disabled): dense-voting evidence for the apply kernel's blend.
        let consensusBuf = try engine.makeBuffer(floats: pixelCount)

        func run(_ label: String, _ encode: (WgpuEngine.Batch) throws -> Void) throws {
            try cancellation?.checkCancelled()
            let batch = try engine.makeBatch()
            try encode(batch)
            batch.submit()
            engine.waitIdle()
        }

        try run("confidence") { batch in
            try batch.dispatch("pyr_fill", buffers: [consensusBuf],
                               uniforms: bytes(of: FillParams(v: 0, count: UInt32(pixelCount))),
                               gridW: pixelCount)
            let params = ConfidenceParams(width: UInt32(width),
                                          concW: UInt32(concentrationWidth),
                                          concH: UInt32(concentration.count
                                                        / max(concentrationWidth, 1)),
                                          factor: UInt32(factor),
                                          halfFloor: halfFloor, conc2: conc2,
                                          count: UInt32(pixelCount))
            try batch.dispatch("confidence_map", buffers: [bestEBuf, confBuf, concBuf],
                               uniforms: bytes(of: params), gridW: pixelCount)
        }
        progress?(0.1)

        // `cur` holds the current depth plane; `spare` receives each stage.
        var cur = bestIdxBuf, spare = medBuf
        if options.medianRadius > 0 {
            try run("weighted median") { batch in
                let params = MedianParams(width: UInt32(width), height: UInt32(height),
                                          radius: Int32(options.medianRadius),
                                          step: Int32(max(1, options.medianRadius / 4)),
                                          bins: UInt32(frameCount),
                                          consensusWindow: Int32(max(2, frameCount / 16)))
                try batch.dispatch("weighted_median",
                                   buffers: [cur, confBuf, spare, consensusBuf],
                                   uniforms: bytes(of: params), gridW: width, gridH: height)
                swap(&cur, &spare)
            }
        }
        progress?(0.4)

        // Grid-level work is the shared CPU stage (parity by construction)
        // over the downloaded confidence and median-depth planes; only the
        // full-res apply+blend runs as a kernel.
        var confPlane = [Float](repeating: 0, count: pixelCount)
        try confPlane.withUnsafeMutableBytes {
            try engine.download(confBuf, into: $0.baseAddress!)
        }
        var medPlane = [Float](repeating: 0, count: pixelCount)
        try medPlane.withUnsafeMutableBytes {
            try engine.download(cur, into: $0.baseAddress!)
        }
        if let coeff = DepthRegularize.gridCoefficients(
                confidence: confPlane, depthMed: medPlane, guide: guide,
                width: width, height: height, planes: planes,
                luminancePlanes: luminancePlanes,
                factor: factor, frameCount: frameCount,
                options: options, log: log) {
            progress?(0.7)
            let gridCount = coeff.gridWidth * coeff.gridHeight
            let aBuf = try engine.makeBuffer(floats: gridCount)
            let bBuf = try engine.makeBuffer(floats: gridCount)
            coeff.a.withUnsafeBytes {
                engine.upload($0.baseAddress!, byteCount: $0.count, to: aBuf)
            }
            coeff.b.withUnsafeBytes {
                engine.upload($0.baseAddress!, byteCount: $0.count, to: bBuf)
            }
            let spillDBuf = try engine.makeBuffer(floats: gridCount)
            let spillSBuf = try engine.makeBuffer(floats: gridCount)
            let hasSpill = coeff.spillDepth.count == gridCount
                && coeff.spillStrength.count == gridCount
            if hasSpill {
                coeff.spillDepth.withUnsafeBytes {
                    engine.upload($0.baseAddress!, byteCount: $0.count, to: spillDBuf)
                }
                coeff.spillStrength.withUnsafeBytes {
                    engine.upload($0.baseAddress!, byteCount: $0.count, to: spillSBuf)
                }
            }
            try run("guided apply") { batch in
                if !hasSpill {
                    // The kernel reads the spill buffers statically; zero
                    // them so the hasSpill=0 branch never sees garbage.
                    for buf in [spillDBuf, spillSBuf] {
                        try batch.dispatch("pyr_fill", buffers: [buf],
                                           uniforms: bytes(of: FillParams(v: 0, count: UInt32(gridCount))),
                                           gridW: gridCount)
                    }
                }
                let rw = Float(max(2, frameCount / 16))
                let params = GuidedApplyParams(
                    width: UInt32(width), height: UInt32(height),
                    gridW: UInt32(coeff.gridWidth), gridH: UInt32(coeff.gridHeight),
                    invFactor: 1 / Float(coeff.factor),
                    guideScale: coeff.guideScale,
                    maxIndex: Float(frameCount - 1),
                    residualW2: rw * rw,
                    hasSpill: hasSpill ? 1 : 0)
                try batch.dispatch("guided_apply_blend",
                                   buffers: [aBuf, bBuf, guideBuf, confBuf, cur, spare,
                                             consensusBuf, spillDBuf, spillSBuf],
                                   uniforms: bytes(of: params), gridW: width, gridH: height)
            }
            swap(&cur, &spare)
        } else {
            // No signal anywhere: keep the median depth, just clamped.
            try run("clamp") { batch in
                try batch.dispatch("clamp_plane", buffers: [cur],
                                   uniforms: bytes(of: ClampParams(maxV: Float(frameCount - 1),
                                                                   count: UInt32(pixelCount))),
                                   gridW: pixelCount)
            }
        }

        var depth = [Float](repeating: 0, count: pixelCount)
        try depth.withUnsafeMutableBytes {
            try engine.download(cur, into: $0.baseAddress!)
        }
        log?("depth map regularized (noise floor \(floor), guided, wgpu)")
        progress?(1.0)
        return depth
    }
}
#endif // HYPERFOCAL_HAVE_WGPU
