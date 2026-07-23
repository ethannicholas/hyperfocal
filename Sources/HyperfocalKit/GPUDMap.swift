#if canImport(Metal)
import Foundation
import Metal
import simd

/// GPU path for depth-map fusion: decode on CPU (prefetched, overlapped), all
/// per-pixel work — warp, sharpness energy, argmax, depth regularization
/// (median / jump-flood / cleanup), tent accumulation — on Metal.
public enum GPUDMap {

    struct WarpParams {
        var r0: SIMD4<Float>
        var r1: SIMD4<Float>
        var r2: SIMD4<Float>
        var dims: SIMD4<UInt32>
    }

    struct BlurParams {
        var width: UInt32
        var height: UInt32
        var radius: Int32
    }

    /// Must match the Metal-side ConfidenceParams layout.
    struct ConfidenceParams {
        var width: UInt32
        var concW: UInt32
        var concH: UInt32
        var factor: UInt32
        var halfFloor: Float
        var conc2: Float
    }

    struct TentParams {
        // gain first: float4/SIMD4 16-byte alignment keeps the Swift and
        // Metal layouts identical without padding games (w unused).
        var gain: SIMD4<Float>
        var index: Float
        var radius: Float
        var count: UInt32
        private var _pad: UInt32 = 0

        init(index: Float, radius: Float, count: UInt32, gain: SIMD3<Float>) {
            self.gain = SIMD4(gain, 0)
            self.index = index
            self.radius = radius
            self.count = count
        }
    }

    struct PreviewParams {
        var srcW: UInt32
        var srcH: UInt32
        var dstW: UInt32
        var dstH: UInt32
    }

    struct PlanePreviewParams {
        var srcW: UInt32
        var srcH: UInt32
        var dstW: UInt32
        var dstH: UInt32
        var scale: Float
        var bias: Float
    }

    struct BoxDownParams {
        var srcW: UInt32
        var srcH: UInt32
        var dstW: UInt32
        var dstH: UInt32
        var factor: UInt32
    }

    struct PlaneUpParams {
        var srcW: UInt32
        var srcH: UInt32
        var dstW: UInt32
        var dstH: UInt32
    }

    public static func fuseWithDepth(source: StackSource,
                                     options: DMapFusion.Options = DMapFusion.Options(),
                                     log: ((String) -> Void)? = nil,
                                     progress: FusionProgressHandler? = nil,
                                     cancellation: CancellationToken? = nil) throws -> DMapFusion.Output {
        guard let engine = MetalEngine.shared else {
            throw StackError.metal("no Metal device available")
        }
        let frameCount = source.count
        precondition(frameCount > 0)

        let warpPipeline = try engine.pipeline("warp_lanczos3")
        let lapPipeline = try engine.pipeline("lum_laplacian")
        let blurHPipeline = try engine.pipeline("blur_h")
        let blurVPipeline = try engine.pipeline("blur_v")
        let argmaxPipeline = try engine.pipeline("argmax_update")
        let tentPipeline = try engine.pipeline("tent_accumulate")
        let normalizePipeline = try engine.pipeline("normalize_out")
        let previewPipeline = try engine.pipeline("progressive_preview")
        let planePreviewPipeline = try engine.pipeline("plane_preview")
        let boxDownPipeline = try engine.pipeline("box_downsample")
        let lumaPipeline = try engine.pipeline("luma_plane")
        let upsamplePipeline = try engine.pipeline("plane_upsample")

        // Energy blur runs on the energyGridFactor grid at σ/factor (see
        // DMapFusion.energyGridFactor — cross-engine algorithm constant).
        let egf = DMapFusion.energyGridFactor(sigma: options.sharpnessSigma)
        let blurWeights = Filters.gaussianKernel(
            sigma: options.sharpnessSigma / Float(egf))
        let blurRadius = blurWeights.count / 2

        var width = 0, height = 0, pixelCount = 0   // output canvas (may be cropped)
        var srcWidth = 0, srcHeight = 0             // source frame dimensions
        var rawBuf: MTLBuffer!, warpedBuf: MTLBuffer!
        var lapBuf: MTLBuffer!, tmpBuf: MTLBuffer!, energyBuf: MTLBuffer!
        var lapGridBuf: MTLBuffer!, gridTmpBuf: MTLBuffer!, energyGridBuf: MTLBuffer!
        var egw = 0, egh = 0                        // energy grid dims (egf > 1)
        var bestEBuf: MTLBuffer!, bestIdxBuf: MTLBuffer!
        var previewBuf: MTLBuffer!
        var pw = 0, ph = 0
        var sharpBuf: MTLBuffer!
        var lumGridBuf: MTLBuffer!
        var guideBuf: MTLBuffer!  // guided path only
        var sw = 0, sh = 0
        var sharpnessPlanes: [[Float]] = []
        var luminancePlanes: [[Float]] = []  // per-frame grid luminance (spill floor)
        var gains0 = [SIMD3<Float>]()  // per-channel gain per frame, vs frame 0
        var meanRGB0 = SIMD3<Float>(repeating: 1)

        // Pass 1 spills its warped frames so pass 2 can stream them back
        // instead of decoding + warping the stack a second time (see
        // FrameSpill — fp32, bit-identical to a re-warp). Measured faster
        // for every input format (RAW ~30%, TIFF ~20%, JPEG ~8% on 30×45 MP
        // stacks), so the only gates are the user's setting and the temp
        // volume's capacity. HYPERFOCAL_DMAP_SPILL=1/0 overrides (ablation).
        let wantSpill = FrameSpill.wanted(options.spillEnabled)
        var spill: FrameSpill?
        var tSpillWrite = 0.0, tSpillRead = 0.0
        // Wall-clock phase buckets (GPUPyramid's discipline: optimization
        // must start from measurements, not vibes). `gpu` buckets are time
        // *blocked on* command buffers — the spill write overlaps the score
        // buffer, so pass 1's reads lower than true GPU execution. `warp`
        // is the serialized upload+warp+wait: the exposure gain is measured
        // from the warped frame mid-frame, a real CPU dependency the
        // pyramid path doesn't have (see the overlap ROADMAP item).
        var tDecodeWait = 0.0, tWarp = 0.0, tMean = 0.0, tGPU = 0.0
        var tReadback = 0.0, tRenderWait = 0.0, tRenderGPU = 0.0, tRenderPreview = 0.0
        func bucket(_ total: inout Double, _ body: () throws -> Void) rethrows {
            let t0 = CFAbsoluteTimeGetCurrent()
            try body()
            total += CFAbsoluteTimeGetCurrent() - t0
        }

        func downloadPreview() -> ImageBuffer {
            var preview = ImageBuffer(width: pw, height: ph)
            preview.pixels.withUnsafeMutableBufferPointer { p in
                p.baseAddress!.update(from: previewBuf.contents().assumingMemoryBound(to: Float.self),
                                      count: pw * ph * 4)
            }
            return preview
        }

        func uploadAndWarp(_ img: ImageBuffer, frameIndex: Int,
                           encoder: MTLComputeCommandEncoder) -> MTLBuffer {
            img.pixels.withUnsafeBufferPointer { p in
                rawBuf.contents().copyMemory(from: p.baseAddress!, byteCount: p.count * 4)
            }
            guard let t = source.transforms?[frameIndex] else {
                return rawBuf  // no alignment: output dims == source dims
            }
            let h = t.inverse  // output → source
            var params = WarpParams(
                r0: SIMD4<Float>(h[0][0], h[1][0], h[2][0], 0),
                r1: SIMD4<Float>(h[0][1], h[1][1], h[2][1], 0),
                r2: SIMD4<Float>(h[0][2], h[1][2], h[2][2], 0),
                dims: SIMD4<UInt32>(UInt32(srcWidth), UInt32(srcHeight),
                                    UInt32(width), UInt32(height)))
            encoder.setBuffer(rawBuf, offset: 0, index: 0)
            encoder.setBuffer(warpedBuf, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<WarpParams>.size, index: 2)
            engine.dispatch2D(encoder, warpPipeline, width: width, height: height)
            return warpedBuf
        }

        // Pass 1: per-pixel argmax of smoothed |Laplacian| across the stack.
        let prefetcher = FramePrefetcher(indices: Array(0..<frameCount),
                                         workers: FramePrefetcher.workers(for: source.urls)) {
            try ImageFile.load(url: source.urls[$0])
        }
        for _ in 0..<frameCount {
            try cancellation?.checkCancelled()
            var next: (Int, ImageBuffer)! = nil
            try bucket(&tDecodeWait) { next = try prefetcher.next() }
            let (fi, img) = next!
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
                if egf > 1 {
                    egw = (width + egf - 1) / egf
                    egh = (height + egf - 1) / egf
                    lapGridBuf = try engine.makeBuffer(floats: egw * egh)
                    gridTmpBuf = try engine.makeBuffer(floats: egw * egh)
                    energyGridBuf = try engine.makeBuffer(floats: egw * egh)
                }
                bestEBuf = try engine.makeBuffer(floats: pixelCount)
                bestIdxBuf = try engine.makeBuffer(floats: pixelCount)
                memset(bestEBuf.contents(), 0, pixelCount * 4)
                memset(bestIdxBuf.contents(), 0, pixelCount * 4)
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
                memset(guideBuf.contents(), 0, pixelCount * 4)
                if wantSpill {
                    spill = FrameSpill(frameBytes: pixelCount * 16,
                                       frameCount: frameCount, log: log)
                }
            }
            guard img.width == srcWidth && img.height == srcHeight else {
                throw StackError.metal("frame \(fi) size mismatch: \(img.width)x\(img.height) vs \(srcWidth)x\(srcHeight)")
            }

            // Warp in its own command buffer: the exposure gain is measured on
            // the *warped* frame (same domain as the CPU path), and it feeds the
            // argmax dispatch below, so the mean must be readable mid-frame.
            guard let warpCmd = engine.queue.makeCommandBuffer(),
                  let warpEncoder = warpCmd.makeComputeCommandEncoder() else {
                throw StackError.metal("cannot create command buffer")
            }
            var input: MTLBuffer! = nil
            bucket(&tWarp) {
                input = uploadAndWarp(img, frameIndex: fi, encoder: warpEncoder)
                warpEncoder.endEncoding()
                warpCmd.commit()
                warpCmd.waitUntilCompleted()
            }
            if let error = warpCmd.error { throw StackError.metal("warp: \(error)") }

            var mean = SIMD3<Float>(repeating: 1)
            bucket(&tMean) { mean = meanChannels(buffer: input, pixelCount: pixelCount) }
            if fi == 0 { meanRGB0 = mean }
            // Scalar luminance gain for the scoring side (energy plane, guide);
            // the per-channel gains are for the render (see DMapFusion).
            var gain: Float = options.normalizeExposure
                ? min(max(DMapFusion.luma(meanRGB0) / max(DMapFusion.luma(mean), 1e-6), 0.5), 2)
                : 1
            gains0.append(options.normalizeExposure
                ? (meanRGB0 / pointwiseMax(mean, .init(repeating: 1e-6)))
                    .clamped(lowerBound: .init(repeating: 0.5),
                             upperBound: .init(repeating: 2))
                : .one)

            guard let cmd = engine.queue.makeCommandBuffer(),
                  let encoder = cmd.makeComputeCommandEncoder() else {
                throw StackError.metal("cannot create command buffer")
            }
            var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(lapBuf, offset: 0, index: 1)
            encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            engine.dispatch2D(encoder, lapPipeline, width: width, height: height)

            // Energy field: blur on the grid then upsample (egf > 1), or the
            // plain full-res blur (egf == 1) — same rule as the CPU path.
            let (blurW, blurH): (Int, Int) = egf > 1 ? (egw, egh) : (width, height)
            var blurParams = BlurParams(width: UInt32(blurW), height: UInt32(blurH),
                                        radius: Int32(blurRadius))
            if egf > 1 {
                var lapDownParams = BoxDownParams(
                    srcW: UInt32(width), srcH: UInt32(height),
                    dstW: UInt32(egw), dstH: UInt32(egh), factor: UInt32(egf))
                encoder.setBuffer(lapBuf, offset: 0, index: 0)
                encoder.setBuffer(lapGridBuf, offset: 0, index: 1)
                encoder.setBytes(&lapDownParams, length: MemoryLayout<BoxDownParams>.size, index: 2)
                engine.dispatch2D(encoder, boxDownPipeline, width: egw, height: egh)
            }
            let (blurSrc, blurTmp, blurDst) = egf > 1
                ? (lapGridBuf!, gridTmpBuf!, energyGridBuf!)
                : (lapBuf!, tmpBuf!, energyBuf!)
            blurWeights.withUnsafeBufferPointer { wp in
                encoder.setBuffer(blurSrc, offset: 0, index: 0)
                encoder.setBuffer(blurTmp, offset: 0, index: 1)
                encoder.setBytes(wp.baseAddress!, length: wp.count * 4, index: 2)
                encoder.setBytes(&blurParams, length: MemoryLayout<BlurParams>.size, index: 3)
                engine.dispatch2D(encoder, blurHPipeline, width: blurW, height: blurH)

                encoder.setBuffer(blurTmp, offset: 0, index: 0)
                encoder.setBuffer(blurDst, offset: 0, index: 1)
                encoder.setBytes(wp.baseAddress!, length: wp.count * 4, index: 2)
                encoder.setBytes(&blurParams, length: MemoryLayout<BlurParams>.size, index: 3)
                engine.dispatch2D(encoder, blurVPipeline, width: blurW, height: blurH)
            }
            if egf > 1 {
                var upParams = PlaneUpParams(srcW: UInt32(egw), srcH: UInt32(egh),
                                             dstW: UInt32(width), dstH: UInt32(height))
                encoder.setBuffer(energyGridBuf, offset: 0, index: 0)
                encoder.setBuffer(energyBuf, offset: 0, index: 1)
                encoder.setBytes(&upParams, length: MemoryLayout<PlaneUpParams>.size, index: 2)
                engine.dispatch2D(encoder, upsamplePipeline, width: width, height: height)
            }

            var frameIdx = Float(fi)
            var count32 = UInt32(pixelCount)
            encoder.setBuffer(energyBuf, offset: 0, index: 0)
            encoder.setBuffer(input, offset: 0, index: 1)  // alpha masks the vote
            encoder.setBuffer(bestEBuf, offset: 0, index: 2)
            encoder.setBuffer(bestIdxBuf, offset: 0, index: 3)
            encoder.setBytes(&frameIdx, length: 4, index: 4)
            encoder.setBytes(&count32, length: 4, index: 5)
            encoder.setBytes(&gain, length: 4, index: 6)  // exposure-corrected vote
            // The kernel also records the winning frame's luminance — the
            // regularizer's all-in-focus guide estimate.
            encoder.setBuffer(guideBuf, offset: 0, index: 7)
            engine.dispatch1D(encoder, argmaxPipeline, count: pixelCount)

            // Retain this frame's raw sharpness at reduced resolution — the
            // pre-regularization measurement retouching queries later.
            var boxParams = BoxDownParams(srcW: UInt32(width), srcH: UInt32(height),
                                          dstW: UInt32(sw), dstH: UInt32(sh),
                                          factor: UInt32(DMapFusion.sharpnessDownsample))
            encoder.setBuffer(energyBuf, offset: 0, index: 0)
            encoder.setBuffer(sharpBuf, offset: 0, index: 1)
            encoder.setBytes(&boxParams, length: MemoryLayout<BoxDownParams>.size, index: 2)
            engine.dispatch2D(encoder, boxDownPipeline, width: sw, height: sh)

            // Grid luminance for the spill floor (tmpBuf is free after the
            // blurs). Same shape as the retained sharpness planes.
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(tmpBuf, offset: 0, index: 1)
            encoder.setBytes(&count32, length: 4, index: 2)
            engine.dispatch1D(encoder, lumaPipeline, count: pixelCount)
            encoder.setBuffer(tmpBuf, offset: 0, index: 0)
            encoder.setBuffer(lumGridBuf, offset: 0, index: 1)
            encoder.setBytes(&boxParams, length: MemoryLayout<BoxDownParams>.size, index: 2)
            engine.dispatch2D(encoder, boxDownPipeline, width: sw, height: sh)

            if progress != nil {
                // Snapshot the argmax plane — the depth map forming. Inverted so
                // near (first frame, close-to-far capture order) is bright.
                var planeParams = PlanePreviewParams(
                    srcW: UInt32(width), srcH: UInt32(height),
                    dstW: UInt32(pw), dstH: UInt32(ph),
                    scale: frameCount > 1 ? -1 / Float(frameCount - 1) : 0,
                    bias: 1)
                encoder.setBuffer(bestIdxBuf, offset: 0, index: 0)
                encoder.setBuffer(previewBuf, offset: 0, index: 1)
                encoder.setBytes(&planeParams, length: MemoryLayout<PlanePreviewParams>.size, index: 2)
                engine.dispatch2D(encoder, planePreviewPipeline, width: pw, height: ph)
            }

            encoder.endEncoding()
            cmd.commit()
            // Spill the warped frame while the GPU chews on it (both sides
            // only read `input`). A failed write just degrades pass 2 back
            // to re-decoding — never fails the fuse.
            if let s = spill {
                let t0 = CFAbsoluteTimeGetCurrent()
                do {
                    try s.write(frame: fi, from: input.contents())
                } catch {
                    log?("frame spill write failed (\(error)) — render pass will re-decode")
                    spill = nil
                }
                tSpillWrite += CFAbsoluteTimeGetCurrent() - t0
            }
            bucket(&tGPU) { cmd.waitUntilCompleted() }
            if let error = cmd.error { throw StackError.metal("depth pass: \(error)") }
            var plane = [Float](UnsafeBufferPointer(
                start: sharpBuf.contents().assumingMemoryBound(to: Float.self), count: sw * sh))
            if gain != 1 {
                // The retained sharpness must match what the argmax compared.
                for i in plane.indices { plane[i] *= gain }
            }
            sharpnessPlanes.append(plane)
            var lumPlane = [Float](UnsafeBufferPointer(
                start: lumGridBuf.contents().assumingMemoryBound(to: Float.self), count: sw * sh))
            if gain != 1 {
                for i in lumPlane.indices { lumPlane[i] *= gain }
            }
            luminancePlanes.append(lumPlane)
            log?("depth pass \(fi + 1)/\(frameCount)")
            if let progress {
                bucket(&tReadback) {
                    progress(FusionProgress(stage: .depth,
                                            fraction: Double(fi + 1) / Double(frameCount),
                                            preview: downloadPreview(),
                                            previewFullWidth: width, previewFullHeight: height,
                                            sourceFrameIndex: fi,
                                            sourcePreview: img.downsampledNearest(maxSide: 1200),
                                            sourceFullWidth: img.width, sourceFullHeight: img.height))
                }
            }
        }
        log?(String(format: "dmap phases (gpu) pass 1: decode-wait %.2fs, warp %.2fs, "
                    + "mean %.2fs, gpu %.2fs, preview %.2fs, spill-write %.2fs",
                    tDecodeWait, tWarp, tMean, tGPU, tReadback, tSpillWrite))

        // Winner-frame luminance guide, written by the argmax kernel, then
        // low-passed (same separable blur as the CPU path — see
        // DMapFusion.guideSigma). The shared grid stage reads this same
        // plane the apply kernel samples.
        do {
            guard let cmd = engine.queue.makeCommandBuffer(),
                  let encoder = cmd.makeComputeCommandEncoder() else {
                throw StackError.metal("cannot create command buffer")
            }
            let guideWeights = Filters.gaussianKernel(sigma: DMapFusion.guideSigma)
            var params = BlurParams(width: UInt32(width), height: UInt32(height),
                                    radius: Int32(guideWeights.count / 2))
            guideWeights.withUnsafeBufferPointer { wp in
                encoder.setBuffer(guideBuf, offset: 0, index: 0)
                encoder.setBuffer(tmpBuf, offset: 0, index: 1)
                encoder.setBytes(wp.baseAddress!, length: wp.count * 4, index: 2)
                encoder.setBytes(&params, length: MemoryLayout<BlurParams>.size, index: 3)
                engine.dispatch2D(encoder, blurHPipeline, width: width, height: height)

                encoder.setBuffer(tmpBuf, offset: 0, index: 0)
                encoder.setBuffer(guideBuf, offset: 0, index: 1)
                encoder.setBytes(wp.baseAddress!, length: wp.count * 4, index: 2)
                encoder.setBytes(&params, length: MemoryLayout<BlurParams>.size, index: 3)
                engine.dispatch2D(encoder, blurVPipeline, width: width, height: height)
            }
            encoder.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            if let error = cmd.error { throw StackError.metal("guide blur: \(error)") }
        }
        let guide = [Float](UnsafeBufferPointer(
            start: guideBuf.contents().assumingMemoryBound(to: Float.self),
            count: pixelCount))
        DMapFusion.dumpGuide(guide)

        // Depth regularization on GPU (same chain as the CPU path).
        // Peak concentration from the retained planes — the identical
        // computation the CPU path runs, so both engines gate the same pixels.
        let concentration = DMapFusion.peakConcentrationPlane(planes: sharpnessPlanes)
        var despillInputs: Despill.DespillInputs? = nil
        let depth = try regularizeDepth(engine: engine, bestEBuf: bestEBuf,
                                        bestIdxBuf: bestIdxBuf,
                                        concentration: concentration,
                                        concentrationWidth: sw,
                                        planes: sharpnessPlanes,
                                        luminancePlanes: luminancePlanes,
                                        guide: guide, guideBuf: guideBuf,
                                        width: width, height: height,
                                        frameCount: frameCount, options: options,
                                        log: log, cancellation: cancellation,
                                        despillOut: { despillInputs = $0 }) {
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
        depth.withUnsafeBufferPointer { p in
            depthBuf.contents().copyMemory(from: p.baseAddress!, byteCount: pixelCount * 4)
        }
        let accumBuf = try engine.makeBuffer(floats: pixelCount * 4)
        let wsumBuf = try engine.makeBuffer(floats: pixelCount)
        memset(accumBuf.contents(), 0, pixelCount * 16)
        memset(wsumBuf.contents(), 0, pixelCount * 4)

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
            guard let cmd = engine.queue.makeCommandBuffer(),
                  let encoder = cmd.makeComputeCommandEncoder() else {
                throw StackError.metal("cannot create command buffer")
            }
            let fi: Int
            let input: MTLBuffer
            var sourcePreview: ImageBuffer?
            var sourceW = 0, sourceH = 0
            if let spill {
                fi = renderIndices[step]
                let t0 = CFAbsoluteTimeGetCurrent()
                try spill.read(frame: fi, into: warpedBuf.contents())
                tSpillRead += CFAbsoluteTimeGetCurrent() - t0
                input = warpedBuf
                if progress != nil {
                    // The spill holds the *warped* frame — show that (the
                    // aligned frame on the output canvas) as the source.
                    sourcePreview = ImageBuffer.downsampledNearest(
                        fromRGBA: warpedBuf.contents().assumingMemoryBound(to: Float.self),
                        width: width, height: height, maxSide: 1200)
                    sourceW = width
                    sourceH = height
                }
            } else {
                var next: (Int, ImageBuffer)! = nil
                try bucket(&tRenderWait) { next = try renderPrefetcher!.next() }
                let (idx, img) = next!
                fi = idx
                input = uploadAndWarp(img, frameIndex: fi, encoder: encoder)
                if progress != nil {
                    sourcePreview = img.downsampledNearest(maxSide: 1200)
                    sourceW = img.width
                    sourceH = img.height
                }
            }

            var params = TentParams(index: Float(fi), radius: radius, count: UInt32(pixelCount),
                                    gain: gains?[fi] ?? .one)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(depthBuf, offset: 0, index: 1)
            encoder.setBuffer(accumBuf, offset: 0, index: 2)
            encoder.setBuffer(wsumBuf, offset: 0, index: 3)
            encoder.setBytes(&params, length: MemoryLayout<TentParams>.size, index: 4)
            engine.dispatch1D(encoder, tentPipeline, count: pixelCount)

            if progress != nil {
                var previewParams = PreviewParams(srcW: UInt32(width), srcH: UInt32(height),
                                                  dstW: UInt32(pw), dstH: UInt32(ph))
                encoder.setBuffer(accumBuf, offset: 0, index: 0)
                encoder.setBuffer(wsumBuf, offset: 0, index: 1)
                encoder.setBuffer(previewBuf, offset: 0, index: 2)
                encoder.setBytes(&previewParams, length: MemoryLayout<PreviewParams>.size, index: 3)
                engine.dispatch2D(encoder, previewPipeline, width: pw, height: ph)
            }

            encoder.endEncoding()
            cmd.commit()
            bucket(&tRenderGPU) { cmd.waitUntilCompleted() }
            if let error = cmd.error { throw StackError.metal("render pass: \(error)") }
            log?("render pass \(fi + 1)/\(frameCount)")
            renderedCount += 1
            if let progress {
                bucket(&tRenderPreview) {
                    progress(FusionProgress(stage: .render,
                                            fraction: Double(renderedCount) / Double(renderIndices.count),
                                            preview: downloadPreview(),
                                            previewFullWidth: width, previewFullHeight: height,
                                            sourceFrameIndex: fi,
                                            sourcePreview: sourcePreview,
                                            sourceFullWidth: sourceW, sourceFullHeight: sourceH))
                }
            }
        }
        log?(String(format: "dmap phases (gpu) render: %@ %.2fs, gpu (incl. upload+warp) %.2fs, "
                    + "preview %.2fs",
                    spill != nil ? "spill-read" : "decode-wait",
                    spill != nil ? tSpillRead : tRenderWait, tRenderGPU, tRenderPreview))
        if spill != nil {
            let frameGB = Double(pixelCount) * 16 / Double(1 << 30)
            log?(String(format: "spill: wrote %.1f GB in %.2fs, read %.1f GB in %.2fs",
                        frameGB * Double(frameCount), tSpillWrite,
                        frameGB * Double(renderIndices.count), tSpillRead))
        }

        // Normalize into rawBuf (no longer needed as input) and download.
        guard let cmd = engine.queue.makeCommandBuffer(),
              let encoder = cmd.makeComputeCommandEncoder() else {
            throw StackError.metal("cannot create command buffer")
        }
        var count32 = UInt32(pixelCount)
        encoder.setBuffer(accumBuf, offset: 0, index: 0)
        encoder.setBuffer(wsumBuf, offset: 0, index: 1)
        encoder.setBuffer(rawBuf, offset: 0, index: 2)
        encoder.setBytes(&count32, length: 4, index: 3)
        engine.dispatch1D(encoder, normalizePipeline, count: pixelCount)
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error { throw StackError.metal("normalize: \(error)") }

        var out = ImageBuffer(width: width, height: height)
        out.pixels.withUnsafeMutableBufferPointer { p in
            p.baseAddress!.update(from: rawBuf.contents().assumingMemoryBound(to: Float.self),
                                  count: pixelCount * 4)
        }
        var output = DMapFusion.Output(image: out,
                                       depthMap: DMapFusion.depthImage(from: depth, width: width,
                                                                       height: height,
                                                                       frameCount: frameCount),
                                       depth: depth,
                                       sharpness: FrameSharpness(fullWidth: width, fullHeight: height,
                                                                 factor: DMapFusion.sharpnessDownsample,
                                                                 planes: sharpnessPlanes),
                                       gains: gains)
        output.despill = despillInputs
        return output
    }

    /// Alpha-weighted per-channel mean of an RGBA float buffer, stride-
    /// subsampled — the exposure-gain measurement, matching
    /// `DMapFusion.meanChannels`.
    static func meanChannels(buffer: MTLBuffer, pixelCount: Int) -> SIMD3<Float> {
        let p = buffer.contents().assumingMemoryBound(to: Float.self)
        var sum = SIMD3<Float>()
        var wsum: Float = 0
        var i = 0
        while i < pixelCount {
            let pi = i * 4
            let a = p[pi + 3]
            sum += SIMD3(p[pi], p[pi + 1], p[pi + 2]) * a
            wsum += a
            i += 7
        }
        return wsum > 0 ? sum / wsum : SIMD3()
    }

    struct MedianParams {
        var width: UInt32
        var height: UInt32
        var radius: Int32
        var step: Int32
        var bins: UInt32
        var consensusWindow: Int32
    }

    /// Must match the Metal-side GuidedApplyParams layout.
    struct GuidedApplyParams {
        var width: UInt32
        var height: UInt32
        var gridW: UInt32
        var gridH: UInt32
        var invFactor: Float
        var guideScale: Float
        var maxIndex: Float
        var residualW2: Float
        var hasSpill: UInt32
    }

    /// The regularization chain (confidence → weighted median → guided filter
    /// + preservation blend → clamp), mirroring `DMapFusion.regularizeDepth`:
    /// grid-level work is the shared CPU stage over downloaded planes; only
    /// the full-res confidence, median, and apply passes run as kernels.
    /// Phases run in separate command buffers so progress and cancellation
    /// stay responsive. `bestIdxBuf` is consumed as scratch.
    static func regularizeDepth(engine: MetalEngine,
                                bestEBuf: MTLBuffer, bestIdxBuf: MTLBuffer,
                                concentration: [Float], concentrationWidth: Int,
                                planes: [[Float]],
                                luminancePlanes: [[Float]] = [],
                                guide: [Float], guideBuf: MTLBuffer,
                                width: Int, height: Int, frameCount: Int,
                                options: DMapFusion.Options,
                                log: ((String) -> Void)?,
                                cancellation: CancellationToken?,
                                despillOut: ((Despill.DespillInputs) -> Void)? = nil,
                                progress: ((Double) -> Void)? = nil) throws -> [Float] {
        let pixelCount = width * height
        let confidencePipeline = try engine.pipeline("confidence_map")
        let medianPipeline = try engine.pipeline("weighted_median")
        let clampPipeline = try engine.pipeline("clamp_plane")

        let energies = UnsafeBufferPointer(
            start: bestEBuf.contents().assumingMemoryBound(to: Float.self), count: pixelCount)
        let floor = max(1e-6, options.noiseFloor * DMapFusion.percentile95(energies))
        let halfFloor = floor / 2
        let conc2 = options.peakConcentration * options.peakConcentration
        let factor = DMapFusion.sharpnessDownsample

        let concBuf = try engine.makeBuffer(floats: max(concentration.count, 1))
        _ = concentration.withUnsafeBufferPointer {
            memcpy(concBuf.contents(), $0.baseAddress!, concentration.count * 4)
        }
        var confParams = ConfidenceParams(width: UInt32(width),
                                          concW: UInt32(concentrationWidth),
                                          concH: UInt32(concentration.count
                                                        / max(concentrationWidth, 1)),
                                          factor: UInt32(factor),
                                          halfFloor: halfFloor, conc2: conc2)

        let confBuf = try engine.makeBuffer(floats: pixelCount)
        let medBuf = try engine.makeBuffer(floats: pixelCount)
        // Consensus from the weighted median (zero when the median is
        // disabled): dense-voting evidence for the apply kernel's blend.
        let consensusBuf = try engine.makeBuffer(floats: pixelCount)
        memset(consensusBuf.contents(), 0, pixelCount * 4)
        var count32 = UInt32(pixelCount)

        func run(_ label: String, _ encode: (MTLComputeCommandEncoder) -> Void) throws {
            try cancellation?.checkCancelled()
            guard let cmd = engine.queue.makeCommandBuffer(),
                  let encoder = cmd.makeComputeCommandEncoder() else {
                throw StackError.metal("cannot create command buffer")
            }
            encode(encoder)
            encoder.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            if let error = cmd.error { throw StackError.metal("\(label): \(error)") }
        }

        try run("confidence") { encoder in
            encoder.setBuffer(bestEBuf, offset: 0, index: 0)
            encoder.setBuffer(confBuf, offset: 0, index: 1)
            encoder.setBytes(&confParams, length: MemoryLayout<ConfidenceParams>.size, index: 2)
            encoder.setBytes(&count32, length: 4, index: 3)
            encoder.setBuffer(concBuf, offset: 0, index: 4)
            engine.dispatch1D(encoder, confidencePipeline, count: pixelCount)
        }
        progress?(0.1)

        // `cur` holds the current depth plane; `spare` receives each stage.
        var cur = bestIdxBuf, spare = medBuf
        if options.medianRadius > 0 {
            try run("weighted median") { encoder in
                var params = MedianParams(width: UInt32(width), height: UInt32(height),
                                          radius: Int32(options.medianRadius),
                                          step: Int32(max(1, options.medianRadius / 4)),
                                          bins: UInt32(frameCount),
                                          consensusWindow: Int32(max(2, frameCount / 16)))
                encoder.setBuffer(cur, offset: 0, index: 0)
                encoder.setBuffer(confBuf, offset: 0, index: 1)
                encoder.setBuffer(spare, offset: 0, index: 2)
                encoder.setBytes(&params, length: MemoryLayout<MedianParams>.size, index: 3)
                encoder.setBuffer(consensusBuf, offset: 0, index: 4)
                engine.dispatch2D(encoder, medianPipeline, width: width, height: height)
                swap(&cur, &spare)
            }
        }
        progress?(0.4)

        // Grid-level work is the shared CPU stage (parity by construction)
        // over the downloaded confidence and median-depth planes; only the
        // full-res apply+blend runs as a kernel.
        let confPlane = [Float](UnsafeBufferPointer(
            start: confBuf.contents().assumingMemoryBound(to: Float.self),
            count: pixelCount))
        let medPlane = [Float](UnsafeBufferPointer(
            start: cur.contents().assumingMemoryBound(to: Float.self),
            count: pixelCount))
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
            _ = coeff.a.withUnsafeBufferPointer {
                memcpy(aBuf.contents(), $0.baseAddress!, gridCount * 4)
            }
            _ = coeff.b.withUnsafeBufferPointer {
                memcpy(bBuf.contents(), $0.baseAddress!, gridCount * 4)
            }
            let spillDBuf = try engine.makeBuffer(floats: gridCount)
            let spillSBuf = try engine.makeBuffer(floats: gridCount)
            memset(spillDBuf.contents(), 0, gridCount * 4)
            memset(spillSBuf.contents(), 0, gridCount * 4)
            if coeff.spillDepth.count == gridCount, coeff.spillStrength.count == gridCount {
                _ = coeff.spillDepth.withUnsafeBufferPointer {
                    memcpy(spillDBuf.contents(), $0.baseAddress!, gridCount * 4)
                }
                _ = coeff.spillStrength.withUnsafeBufferPointer {
                    memcpy(spillSBuf.contents(), $0.baseAddress!, gridCount * 4)
                }
            }
            if options.prepareDespill, let despillOut,
               let di = Despill.computeInputs(luminancePlanes: luminancePlanes,
                                              spillStrength: coeff.spillStrength,
                                              spillWidth: coeff.gridWidth,
                                              spillHeight: coeff.gridHeight,
                                              width: width, height: height,
                                              factor: coeff.factor, log: log) {
                despillOut(di)
            }
            let applyPipeline = try engine.pipeline("guided_apply_blend")
            try run("guided apply") { encoder in
                let rw = Float(max(2, frameCount / 16))
                let hasSpill = coeff.spillDepth.count == gridCount
                    && coeff.spillStrength.count == gridCount
                var params = GuidedApplyParams(
                    width: UInt32(width), height: UInt32(height),
                    gridW: UInt32(coeff.gridWidth), gridH: UInt32(coeff.gridHeight),
                    invFactor: 1 / Float(coeff.factor),
                    guideScale: coeff.guideScale,
                    maxIndex: Float(frameCount - 1),
                    residualW2: rw * rw,
                    hasSpill: hasSpill ? 1 : 0)
                encoder.setBuffer(aBuf, offset: 0, index: 0)
                encoder.setBuffer(bBuf, offset: 0, index: 1)
                encoder.setBuffer(guideBuf, offset: 0, index: 2)
                encoder.setBuffer(confBuf, offset: 0, index: 3)
                encoder.setBuffer(cur, offset: 0, index: 4)
                encoder.setBuffer(spare, offset: 0, index: 5)
                encoder.setBytes(&params, length: MemoryLayout<GuidedApplyParams>.size,
                                 index: 6)
                encoder.setBuffer(consensusBuf, offset: 0, index: 7)
                encoder.setBuffer(spillDBuf, offset: 0, index: 8)
                encoder.setBuffer(spillSBuf, offset: 0, index: 9)
                engine.dispatch2D(encoder, applyPipeline, width: width, height: height)
            }
            swap(&cur, &spare)
        } else {
            // No signal anywhere: keep the median depth, just clamped.
            try run("clamp") { encoder in
                var maxIndex = Float(frameCount - 1)
                encoder.setBuffer(cur, offset: 0, index: 0)
                encoder.setBytes(&maxIndex, length: 4, index: 1)
                encoder.setBytes(&count32, length: 4, index: 2)
                engine.dispatch1D(encoder, clampPipeline, count: pixelCount)
            }
        }

        let depth = [Float](UnsafeBufferPointer(
            start: cur.contents().assumingMemoryBound(to: Float.self),
            count: pixelCount))
        log?("depth map regularized (noise floor \(floor), guided, GPU)")
        progress?(1.0)
        return depth
    }
}

#endif // canImport(Metal)
