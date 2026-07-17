import Foundation
import Metal
import simd

/// GPU Laplacian-pyramid fusion — the same streaming max-coefficient algorithm
/// as `PyramidFusion`'s CPU path (5-tap separable blur, decimate, bilinear
/// upsample, |RGB| energy select, averaged base), with the running fused
/// pyramid and winner energies resident on the GPU across frames. Bit parity
/// with the CPU is not expected (fast math); ≥ 60 dB agreement is.
enum GPUPyramid {

    private struct ResizeParams {
        var srcW: UInt32, srcH: UInt32, dstW: UInt32, dstH: UInt32
    }

    /// With `warp`, `frame` returns unwarped frames and the homographies
    /// apply on-device (`warp_lanczos3` into the level-0 buffer) — the CPU
    /// Lanczos warp otherwise dominates fusion wall-clock on big stacks.
    static func fuse(frameCount: Int,
                     warp: PyramidWarp? = nil,
                     log: ((String) -> Void)? = nil,
                     progress: ((Double, ImageBuffer?) -> Void)? = nil,
                     cancellation: CancellationToken? = nil,
                     decodeWorkers: Int? = nil,
                     frame: @escaping (Int) throws -> ImageBuffer) throws -> ImageBuffer {
        guard let engine = MetalEngine.shared else {
            throw StackError.metal("no Metal device available")
        }
        let warpPipeline = warp == nil ? nil : try engine.pipeline("warp_lanczos3")
        let bandEnergyPipeline = try engine.pipeline("pyr_band_energy")
        let selectSmoothed = try engine.pipeline("pyr_select_smoothed")
        let scalarBlurH = try engine.pipeline("blur_h")
        let scalarBlurV = try engine.pipeline("blur_v")
        let gritWeights = Filters.gaussianKernel(sigma: PyramidFusion.gritSigma)
        let blurH = try engine.pipeline("pyr_blur5_h")
        let blurV = try engine.pipeline("pyr_blur5_v")
        let decimate = try engine.pipeline("pyr_decimate")
        let upsample = try engine.pipeline("pyr_upsample")
        let upsampleAdd = try engine.pipeline("pyr_upsample_add")
        let select = try engine.pipeline("pyr_select")
        let add4 = try engine.pipeline("pyr_add4")
        let scale4 = try engine.pipeline("pyr_scale4")
        let fill = try engine.pipeline("pyr_fill")

        var width = 0, height = 0, levels = 0
        var srcWidth = 0, srcHeight = 0  // unwarped frame dims (warp mode)
        var sizes: [(w: Int, h: Int)] = []
        var gauss: [MTLBuffer] = []   // per-frame Gaussian pyramid (levels+1)
        var fused: [MTLBuffer] = []   // running fused pyramid (levels+1)
        var bestE: [MTLBuffer] = []   // winner energy per band level (levels)
        // Ping-pong upload targets: frame N+1's memcpy lands in one while the
        // GPU still reads the other for frame N. In warp mode they hold the
        // unwarped source; otherwise they alternate as the pyramid's level 0.
        var uploadBufs: [MTLBuffer] = []
        var scratchA: MTLBuffer! = nil  // level-0-sized float4 scratch
        var scratchB: MTLBuffer! = nil
        var gritA: MTLBuffer! = nil     // level-0 scalar energy (grit suppression)
        var gritB: MTLBuffer! = nil
        var baseTmp: MTLBuffer! = nil   // base-sized copy for preview collapses
        var previewLevel = 0            // coarsest level ≤ ~1600 px on a side

        // Decode (and warp) on background threads while the GPU chews on the
        // previous frame — decode dominates wall-clock otherwise. Callers'
        // frame closures must tolerate concurrent invocation.
        let prefetcher = FramePrefetcher(indices: Array(0..<frameCount),
                                         workers: decodeWorkers, decode: frame)
        defer { prefetcher.cancel() }

        // Wall-clock phase buckets, reported through `log` at the end —
        // optimization here must start from measurements, not vibes. `gpu`
        // is time *blocked on* the GPU: the next frame's decode wait and
        // upload memcpy overlap the in-flight command buffer, so it reads
        // lower than true GPU execution time.
        var tDecodeWait = 0.0, tUpload = 0.0, tGPU = 0.0, tPreview = 0.0
        func bucket(_ total: inout Double, _ body: () throws -> Void) rethrows {
            let t0 = CFAbsoluteTimeGetCurrent()
            try body()
            total += CFAbsoluteTimeGetCurrent() - t0
        }

        // The in-flight frame: committed but not yet waited on. Draining
        // waits, then reads back and emits its preview (encoded at the tail
        // of the same command buffer — a separate preview commit would force
        // the serializing wait the ping-pong exists to avoid).
        var pending: (cmd: MTLCommandBuffer, frame: Int, preview: MTLBuffer?)? = nil
        func drain() {
            guard let p = pending else { return }
            pending = nil
            bucket(&tGPU) {
                p.cmd.waitUntilCompleted()
            }
            if let progress, let buf = p.preview {
                var preview: ImageBuffer! = nil
                bucket(&tPreview) {
                    let (w, h) = sizes[previewLevel]
                    var img = ImageBuffer(width: w, height: h)
                    img.pixels.withUnsafeMutableBufferPointer {
                        _ = memcpy($0.baseAddress!, buf.contents(), w * h * 16)
                    }
                    preview = img
                }
                progress(Double(p.frame + 1) / Double(frameCount), preview)
            }
        }

        for fi in 0..<frameCount {
            try cancellation?.checkCancelled()
            var imgOpt: ImageBuffer! = nil
            try bucket(&tDecodeWait) { imgOpt = try prefetcher.next().image }
            let img: ImageBuffer = imgOpt
            if fi == 0 {
                srcWidth = img.width
                srcHeight = img.height
                width = warp?.outputWidth ?? img.width
                height = warp?.outputHeight ?? img.height
                levels = max(3, Int(log2(Double(min(width, height)) / 16.0)))
                sizes = [(width, height)]
                for _ in 0..<levels {
                    let p = sizes.last!
                    sizes.append(((p.w + 1) / 2, (p.h + 1) / 2))
                }
                for s in sizes {
                    gauss.append(try engine.makeBuffer(floats: s.w * s.h * 4))
                    fused.append(try engine.makeBuffer(floats: s.w * s.h * 4))
                }
                for s in sizes.dropLast() {
                    bestE.append(try engine.makeBuffer(floats: s.w * s.h))
                }
                if warp != nil {
                    uploadBufs = [try engine.makeBuffer(floats: srcWidth * srcHeight * 4),
                                  try engine.makeBuffer(floats: srcWidth * srcHeight * 4)]
                } else {
                    // No warp stage to fill level 0 on-device, so the upload
                    // buffers alternate as gauss[0] itself (one is the
                    // original allocation, reused).
                    uploadBufs = [gauss[0],
                                  try engine.makeBuffer(floats: width * height * 4)]
                }
                scratchA = try engine.makeBuffer(floats: width * height * 4)
                scratchB = try engine.makeBuffer(floats: width * height * 4)
                gritA = try engine.makeBuffer(floats: width * height)
                gritB = try engine.makeBuffer(floats: width * height)
                baseTmp = try engine.makeBuffer(floats: sizes[levels].w * sizes[levels].h * 4)
                previewLevel = sizes.firstIndex { max($0.w, $0.h) <= 1600 } ?? levels
                memset(fused[levels].contents(), 0, sizes[levels].w * sizes[levels].h * 16)
            }
            precondition(img.width == srcWidth && img.height == srcHeight,
                         "frame \(fi) size mismatch: \(img.width)x\(img.height) vs \(srcWidth)x\(srcHeight)")
            // Identity transform on an uncropped canvas needs no warp — same
            // fast path StackSource.frame takes on the CPU.
            let needsWarp = warp.map {
                !($0.transforms[fi] == matrix_identity_float3x3
                    && width == srcWidth && height == srcHeight)
            } ?? false
            let upload = uploadBufs[fi % 2]
            bucket(&tUpload) {
                img.pixels.withUnsafeBufferPointer {
                    _ = memcpy(upload.contents(), $0.baseAddress!,
                               srcWidth * srcHeight * 16)
                }
            }
            // The previous frame's GPU work overlapped the decode wait and
            // upload above; only now does the CPU need it finished.
            drain()
            if warp == nil { gauss[0] = upload }

            guard let cmd = engine.queue.makeCommandBuffer() else {
                throw StackError.metal("cannot create command buffer")
            }
            if warp != nil && !needsWarp {
                // Identity frame in warp mode: device-side copy into level 0
                // (dimensions match — that's what made the warp skippable).
                guard let blit = cmd.makeBlitCommandEncoder() else {
                    throw StackError.metal("cannot create blit encoder")
                }
                blit.copy(from: upload, sourceOffset: 0, to: gauss[0],
                          destinationOffset: 0, size: srcWidth * srcHeight * 16)
                blit.endEncoding()
            }
            guard let enc = cmd.makeComputeCommandEncoder() else {
                throw StackError.metal("cannot create command buffer")
            }
            if needsWarp {
                let h = warp!.transforms[fi].inverse  // output → source
                var params = GPUDMap.WarpParams(
                    r0: SIMD4<Float>(h[0][0], h[1][0], h[2][0], 0),
                    r1: SIMD4<Float>(h[0][1], h[1][1], h[2][1], 0),
                    r2: SIMD4<Float>(h[0][2], h[1][2], h[2][2], 0),
                    dims: SIMD4<UInt32>(UInt32(srcWidth), UInt32(srcHeight),
                                        UInt32(width), UInt32(height)))
                enc.setBuffer(upload, offset: 0, index: 0)
                enc.setBuffer(gauss[0], offset: 0, index: 1)
                enc.setBytes(&params, length: MemoryLayout<GPUDMap.WarpParams>.size, index: 2)
                engine.dispatch2D(enc, warpPipeline!, width: width, height: height)
            }
            if fi == 0 {
                // bestE = −1: the first frame's bands install unconditionally.
                for l in 0..<levels {
                    var v = Float(-1)
                    var count = UInt32(sizes[l].w * sizes[l].h)
                    enc.setBuffer(bestE[l], offset: 0, index: 0)
                    enc.setBytes(&v, length: 4, index: 1)
                    enc.setBytes(&count, length: 4, index: 2)
                    engine.dispatch1D(enc, fill, count: Int(count))
                }
            }
            for l in 0..<levels {
                let (w, h) = sizes[l]
                let (nw, nh) = sizes[l + 1]
                var dims = SIMD2<UInt32>(UInt32(w), UInt32(h))
                // Blur (separable, clamp-to-edge) …
                enc.setBuffer(gauss[l], offset: 0, index: 0)
                enc.setBuffer(scratchA, offset: 0, index: 1)
                enc.setBytes(&dims, length: 8, index: 2)
                engine.dispatch2D(enc, blurH, width: w, height: h)
                enc.setBuffer(scratchA, offset: 0, index: 0)
                enc.setBuffer(scratchB, offset: 0, index: 1)
                enc.setBytes(&dims, length: 8, index: 2)
                engine.dispatch2D(enc, blurV, width: w, height: h)
                // … decimate to the next Gaussian level …
                var down = ResizeParams(srcW: UInt32(w), srcH: UInt32(h),
                                        dstW: UInt32(nw), dstH: UInt32(nh))
                enc.setBuffer(scratchB, offset: 0, index: 0)
                enc.setBuffer(gauss[l + 1], offset: 0, index: 1)
                enc.setBytes(&down, length: 16, index: 2)
                engine.dispatch2D(enc, decimate, width: nw, height: nh)
                // … upsample it back and select the band winners.
                var up = ResizeParams(srcW: UInt32(nw), srcH: UInt32(nh),
                                      dstW: UInt32(w), dstH: UInt32(h))
                enc.setBuffer(gauss[l + 1], offset: 0, index: 0)
                enc.setBuffer(scratchA, offset: 0, index: 1)
                enc.setBytes(&up, length: 16, index: 2)
                engine.dispatch2D(enc, upsample, width: w, height: h)
                var count = UInt32(w * h)
                if l == 0 {
                    // Grit suppression (matches PyramidFusion.selectionEnergy):
                    // selection energy computed to a plane, blurred, then the
                    // select reads it — bands themselves are never smoothed.
                    enc.setBuffer(gauss[0], offset: 0, index: 0)
                    enc.setBuffer(scratchA, offset: 0, index: 1)
                    enc.setBuffer(gritA, offset: 0, index: 2)
                    enc.setBytes(&count, length: 4, index: 3)
                    engine.dispatch1D(enc, bandEnergyPipeline, count: w * h)

                    var blurParams = GPUDMap.BlurParams(width: UInt32(w), height: UInt32(h),
                                                        radius: Int32(gritWeights.count / 2))
                    gritWeights.withUnsafeBufferPointer { wp in
                        enc.setBuffer(gritA, offset: 0, index: 0)
                        enc.setBuffer(gritB, offset: 0, index: 1)
                        enc.setBytes(wp.baseAddress!, length: wp.count * 4, index: 2)
                        enc.setBytes(&blurParams, length: MemoryLayout<GPUDMap.BlurParams>.size, index: 3)
                        engine.dispatch2D(enc, scalarBlurH, width: w, height: h)

                        enc.setBuffer(gritB, offset: 0, index: 0)
                        enc.setBuffer(gritA, offset: 0, index: 1)
                        enc.setBytes(wp.baseAddress!, length: wp.count * 4, index: 2)
                        enc.setBytes(&blurParams, length: MemoryLayout<GPUDMap.BlurParams>.size, index: 3)
                        engine.dispatch2D(enc, scalarBlurV, width: w, height: h)
                    }

                    enc.setBuffer(gauss[0], offset: 0, index: 0)
                    enc.setBuffer(scratchA, offset: 0, index: 1)
                    enc.setBuffer(fused[0], offset: 0, index: 2)
                    enc.setBuffer(bestE[0], offset: 0, index: 3)
                    enc.setBuffer(gritA, offset: 0, index: 4)
                    enc.setBytes(&count, length: 4, index: 5)
                    engine.dispatch1D(enc, selectSmoothed, count: w * h)
                } else {
                    enc.setBuffer(gauss[l], offset: 0, index: 0)
                    enc.setBuffer(scratchA, offset: 0, index: 1)
                    enc.setBuffer(fused[l], offset: 0, index: 2)
                    enc.setBuffer(bestE[l], offset: 0, index: 3)
                    enc.setBytes(&count, length: 4, index: 4)
                    engine.dispatch1D(enc, select, count: w * h)
                }
            }
            // Base level: running sum (averaged after the last frame).
            var baseCount = UInt32(sizes[levels].w * sizes[levels].h)
            enc.setBuffer(fused[levels], offset: 0, index: 0)
            enc.setBuffer(gauss[levels], offset: 0, index: 1)
            enc.setBytes(&baseCount, length: 4, index: 2)
            engine.dispatch1D(enc, add4, count: Int(baseCount))
            enc.endEncoding()
            var previewBuf: MTLBuffer? = nil
            if progress != nil {
                // Live preview: collapse the running pyramid down to a
                // low-res level (a few ms of GPU) at the tail of this frame's
                // command buffer; drain() reads it back and emits it.
                try bucket(&tPreview) {
                    previewBuf = try encodeCollapse(
                        engine: engine, cmd: cmd, fused: fused, sizes: sizes,
                        levels: levels, toLevel: previewLevel,
                        baseScale: 1 / Float(fi + 1), baseTmp: baseTmp,
                        scratchA: scratchA, scratchB: scratchB,
                        scale4: scale4, upsampleAdd: upsampleAdd)
                }
            }
            cmd.commit()
            pending = (cmd, fi, previewBuf)
            log?("pyramid \(fi + 1)/\(frameCount) (GPU)")
        }
        drain()
        log?(String(format: "pyramid phases: decode-wait %.2fs, upload %.2fs, "
                    + "gpu %.2fs, preview %.2fs", tDecodeWait, tUpload, tGPU, tPreview))

        // Average the base and collapse all the way down. Works on a copy of
        // the base (like previews do), so the running sum stays intact.
        return try collapse(engine: engine, fused: fused, sizes: sizes,
                            levels: levels, toLevel: 0,
                            baseScale: 1 / Float(frameCount), baseTmp: baseTmp,
                            scratchA: scratchA, scratchB: scratchB,
                            scale4: scale4, upsampleAdd: upsampleAdd)
    }

    /// Encodes (onto `cmd`, after whatever is already there) a collapse of
    /// the running fused pyramid down to `toLevel` (0 = full resolution;
    /// higher = cheap low-res previews), averaging the base by `baseScale`
    /// into a blit-copied scratch first so the running sum stays intact.
    /// Ping-pongs the two scratch buffers for the upsample-add chain and
    /// returns the buffer the result lands in (valid once `cmd` completes).
    private static func encodeCollapse(engine: MetalEngine, cmd: MTLCommandBuffer,
                                       fused: [MTLBuffer],
                                       sizes: [(w: Int, h: Int)], levels: Int,
                                       toLevel: Int, baseScale: Float,
                                       baseTmp: MTLBuffer,
                                       scratchA: MTLBuffer, scratchB: MTLBuffer,
                                       scale4: MTLComputePipelineState,
                                       upsampleAdd: MTLComputePipelineState) throws -> MTLBuffer {
        let (bw, bh) = sizes[levels]
        guard let blit = cmd.makeBlitCommandEncoder() else {
            throw StackError.metal("cannot create blit encoder")
        }
        blit.copy(from: fused[levels], sourceOffset: 0, to: baseTmp,
                  destinationOffset: 0, size: bw * bh * 16)
        blit.endEncoding()
        guard let enc = cmd.makeComputeCommandEncoder() else {
            throw StackError.metal("cannot create command buffer")
        }
        var scale = baseScale
        var baseCount = UInt32(bw * bh)
        enc.setBuffer(baseTmp, offset: 0, index: 0)
        enc.setBytes(&scale, length: 4, index: 1)
        enc.setBytes(&baseCount, length: 4, index: 2)
        engine.dispatch1D(enc, scale4, count: Int(baseCount))
        var current: MTLBuffer = baseTmp
        var currentSize = sizes[levels]
        for l in stride(from: levels - 1, through: toLevel, by: -1) {
            let dst = current === scratchA ? scratchB : scratchA
            var params = ResizeParams(srcW: UInt32(currentSize.w), srcH: UInt32(currentSize.h),
                                      dstW: UInt32(sizes[l].w), dstH: UInt32(sizes[l].h))
            enc.setBuffer(current, offset: 0, index: 0)
            enc.setBuffer(fused[l], offset: 0, index: 1)
            enc.setBuffer(dst, offset: 0, index: 2)
            enc.setBytes(&params, length: 16, index: 3)
            engine.dispatch2D(enc, upsampleAdd, width: sizes[l].w, height: sizes[l].h)
            current = dst
            currentSize = sizes[l]
        }
        enc.endEncoding()
        return current
    }

    /// Synchronous collapse: encodes on a fresh command buffer, runs it to
    /// completion, and reads the result back.
    private static func collapse(engine: MetalEngine, fused: [MTLBuffer],
                                 sizes: [(w: Int, h: Int)], levels: Int,
                                 toLevel: Int, baseScale: Float,
                                 baseTmp: MTLBuffer,
                                 scratchA: MTLBuffer, scratchB: MTLBuffer,
                                 scale4: MTLComputePipelineState,
                                 upsampleAdd: MTLComputePipelineState) throws -> ImageBuffer {
        guard let cmd = engine.queue.makeCommandBuffer() else {
            throw StackError.metal("cannot create command buffer")
        }
        let result = try encodeCollapse(engine: engine, cmd: cmd, fused: fused,
                                        sizes: sizes, levels: levels,
                                        toLevel: toLevel, baseScale: baseScale,
                                        baseTmp: baseTmp,
                                        scratchA: scratchA, scratchB: scratchB,
                                        scale4: scale4, upsampleAdd: upsampleAdd)
        cmd.commit()
        cmd.waitUntilCompleted()
        let (w, h) = sizes[toLevel]
        var out = ImageBuffer(width: w, height: h)
        out.pixels.withUnsafeMutableBufferPointer {
            _ = memcpy($0.baseAddress!, result.contents(), w * h * 16)
        }
        return out
    }
}
