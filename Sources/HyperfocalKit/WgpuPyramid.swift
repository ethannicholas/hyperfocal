#if HYPERFOCAL_HAVE_WGPU
import Foundation
#if canImport(simd)
import simd
#endif
import Dispatch

/// wgpu port of `GPUPyramid` — the same streaming max-coefficient Laplacian
/// fusion (5-tap separable blur, decimate, bilinear upsample, |RGB| energy
/// select with grit suppression, averaged base), with the running fused
/// pyramid and winner energies resident on the GPU across frames and one
/// command-buffer submit per frame (`WgpuEngine.Batch`). Bit parity with the
/// CPU is not expected; ≥ 60 dB agreement is (the Metal pyramid's bar).
///
/// Upload overlap works differently from Metal, by design: the Metal path
/// needs ping-pong upload buffers because `contents()` memcpys are immediate
/// and unordered against in-flight GPU work. `wgpuQueueWriteBuffer` instead
/// stages its copy on the CPU at call time (that memcpy is the part that
/// overlaps the previous frame's GPU work, same as Metal's) and applies the
/// buffer write in *queue order* — after every previously submitted command
/// buffer. One upload target per role is therefore safe; the deferred
/// `drain()` after staging is what bounds in-flight frames to one, exactly
/// like the Metal path.
enum WgpuPyramid {

    // Uniform layouts matching the WGSL structs in WgpuEngine.kernelSource
    // (bindings in dispatch order, 16-byte multiples).
    private struct WarpParams {
        var r0: SIMD4<Float>
        var r1: SIMD4<Float>
        var r2: SIMD4<Float>
        var dims: SIMD4<UInt32>   // srcW, srcH, dstW, dstH
    }
    private struct BlurParams { var width: UInt32; var height: UInt32; var radius: Int32; var pad: UInt32 = 0 }
    private struct Dims2 { var w: UInt32; var h: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    private struct Count1 { var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }
    private struct ResizeParams { var srcW: UInt32; var srcH: UInt32; var dstW: UInt32; var dstH: UInt32 }
    private struct ScaleParams { var s: Float; var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    private struct FillParams { var v: Float; var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    private struct BoxDownParams { var srcW: UInt32; var srcH: UInt32; var dstW: UInt32; var dstH: UInt32; var factor: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }
    private struct FocusParams { var count: UInt32; var threshold: Float; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }

    private static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
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
                     focusGate: PyramidFusion.GPUFocusGate? = nil,
                     frame: @escaping (Int) throws -> ImageBuffer) throws -> ImageBuffer {
        guard let engine = WgpuEngine.shared else {
            throw StackError.metal("no wgpu adapter available")
        }
        // Resolve every kernel up front so a missing entry point fails loudly
        // before any decode work starts.
        for name in ["pyr_blur5_h", "pyr_blur5_v", "pyr_decimate", "pyr_upsample",
                     "pyr_upsample_add", "pyr_select", "pyr_select_smoothed",
                     "pyr_band_energy", "pyr_add4", "pyr_scale4", "pyr_fill",
                     "blur_h", "blur_v"]
                    + (warp == nil ? [] : ["warp_lanczos3"])
                    + (focusGate == nil ? [] : ["box_downsample", "pyr_select_focus_gated",
                                                "pyr_base_darkest", "pyr_merge_focus"]) {
            _ = try engine.pipeline(name)
        }
        let gritWeights = Filters.gaussianKernel(sigma: PyramidFusion.gritSigma)

        var width = 0, height = 0, levels = 0
        var srcWidth = 0, srcHeight = 0  // unwarped frame dims (warp mode)
        var sizes: [(w: Int, h: Int)] = []
        var gauss: [WgpuEngine.Buffer] = []  // per-frame Gaussian pyramid (levels+1)
        var fused: [WgpuEngine.Buffer] = []  // running fused pyramid (levels+1)
        var bestE: [WgpuEngine.Buffer] = []  // winner energy per band level (levels)
        var uploadBuf: WgpuEngine.Buffer! = nil  // warp mode: the unwarped source
        var scratchA: WgpuEngine.Buffer! = nil   // level-0-sized float4 scratch
        var scratchB: WgpuEngine.Buffer! = nil
        var gritA: WgpuEngine.Buffer! = nil      // level-0 scalar energy (grit suppression)
        var gritB: WgpuEngine.Buffer! = nil
        var gritWeightsBuf: WgpuEngine.Buffer! = nil
        var baseTmp: WgpuEngine.Buffer! = nil    // base-sized copy for preview collapses
        var previewLevel = 0                     // coarsest level ≤ ~1600 px on a side
        // Focus-gate state (nil entries for the non-gated levels), mirroring
        // the Metal path.
        var trackB: [WgpuEngine.Buffer?] = []
        var hasFocus: [WgpuEngine.Buffer?] = []
        var bestDarkLum: [WgpuEngine.Buffer?] = []
        var focusScratch: WgpuEngine.Buffer! = nil
        var baseDarkLum: WgpuEngine.Buffer! = nil
        func gated(_ l: Int) -> Bool {
            guard let fg = focusGate else { return false }
            return l >= 1 && l >= levels - fg.coarseLevels
        }
        let baseScale: (Int) -> Float = focusGate == nil
            ? { 1 / Float($0) }        // averaged base
            : { _ in 1 }               // darkest base — no averaging

        // Decode (and warp) on background threads while the GPU chews on the
        // previous frame — decode dominates wall-clock otherwise. Callers'
        // frame closures must tolerate concurrent invocation.
        let prefetcher = FramePrefetcher(indices: Array(0..<frameCount),
                                         workers: decodeWorkers, decode: frame)
        defer { prefetcher.cancel() }

        // Wall-clock phase buckets, reported through `log` at the end —
        // optimization here must start from measurements, not vibes. `gpu`
        // is time *blocked on* the GPU: the next frame's decode wait and
        // upload staging overlap the in-flight submission, so it reads
        // lower than true GPU execution time.
        var tDecodeWait = 0.0, tUpload = 0.0, tGPU = 0.0, tPreview = 0.0
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
        func bucket(_ total: inout Double, _ body: () throws -> Void) rethrows {
            let t0 = now()
            try body()
            total += now() - t0
        }

        // The in-flight frame: submitted but not yet waited on. Draining
        // waits, then reads back and emits its preview (encoded at the tail
        // of the same command buffer — a separate synchronous readback pass
        // would force the serializing wait the deferred drain exists to
        // avoid).
        var pending: (frame: Int, preview: WgpuEngine.Buffer?)? = nil
        func drain() throws {
            guard let p = pending else { return }
            pending = nil
            bucket(&tGPU) { engine.waitIdle() }
            if let progress {
                var preview: ImageBuffer? = nil
                if let buf = p.preview {
                    let (w, h) = sizes[previewLevel]
                    var img = ImageBuffer(width: w, height: h)
                    try bucket(&tPreview) {
                        try img.pixels.withUnsafeMutableBufferPointer {
                            try engine.download(buf, into: $0.baseAddress!,
                                                byteCount: w * h * 16)
                        }
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
                    uploadBuf = try engine.makeBuffer(floats: srcWidth * srcHeight * 4)
                }
                scratchA = try engine.makeBuffer(floats: width * height * 4)
                scratchB = try engine.makeBuffer(floats: width * height * 4)
                gritA = try engine.makeBuffer(floats: width * height)
                gritB = try engine.makeBuffer(floats: width * height)
                gritWeightsBuf = try engine.makeBuffer(floats: gritWeights.count)
                gritWeights.withUnsafeBytes {
                    engine.upload($0.baseAddress!, byteCount: $0.count, to: gritWeightsBuf)
                }
                baseTmp = try engine.makeBuffer(floats: sizes[levels].w * sizes[levels].h * 4)
                previewLevel = sizes.firstIndex { max($0.w, $0.h) <= 1600 } ?? levels
                if focusGate != nil {
                    for l in 0..<levels {
                        trackB.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h * 4) : nil)
                        hasFocus.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                        bestDarkLum.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                    }
                    focusScratch = try engine.makeBuffer(floats: width * height)
                    baseDarkLum = try engine.makeBuffer(floats: sizes[levels].w * sizes[levels].h)
                }
            }
            precondition(img.width == srcWidth && img.height == srcHeight,
                         "frame \(fi) size mismatch: \(img.width)x\(img.height) vs \(srcWidth)x\(srcHeight)")
            // Identity transform on an uncropped canvas needs no warp — same
            // fast path StackSource.frame takes on the CPU.
            let needsWarp = warp.map {
                !($0.transforms[fi] == matrix_identity_float3x3
                    && width == srcWidth && height == srcHeight)
            } ?? false
            let upload = warp != nil ? uploadBuf! : gauss[0]
            bucket(&tUpload) {
                img.pixels.withUnsafeBufferPointer {
                    engine.upload($0.baseAddress!, byteCount: srcWidth * srcHeight * 16,
                                  to: upload)
                }
            }
            // The previous frame's GPU work overlapped the decode wait and
            // upload staging above; only now does the CPU need it finished.
            try drain()

            let batch = try engine.makeBatch()
            if fi == 0 {
                // bestE = −1: the first frame's bands install unconditionally.
                // The fused base is filled to 0 explicitly rather than relying
                // on WebGPU's zero-init, so a rerun on recycled buffers can
                // never inherit stale sums.
                for l in 0..<levels {
                    let count = sizes[l].w * sizes[l].h
                    try batch.dispatch("pyr_fill", buffers: [bestE[l]],
                                       uniforms: bytes(of: FillParams(v: -1, count: UInt32(count))),
                                       gridW: count)
                }
                let baseFloats = sizes[levels].w * sizes[levels].h * 4
                try batch.dispatch("pyr_fill", buffers: [fused[levels]],
                                   uniforms: bytes(of: FillParams(v: 0, count: UInt32(baseFloats))),
                                   gridW: baseFloats)
                if focusGate != nil {
                    // Focus tracks: hasFocus = 0, bestDarkLum/baseDarkLum = +inf.
                    func fill(_ buf: WgpuEngine.Buffer, _ v: Float, _ count: Int) throws {
                        try batch.dispatch("pyr_fill", buffers: [buf],
                                           uniforms: bytes(of: FillParams(v: v, count: UInt32(count))),
                                           gridW: count)
                    }
                    for l in 0..<levels where gated(l) {
                        let count = sizes[l].w * sizes[l].h
                        try fill(hasFocus[l]!, 0, count)
                        try fill(bestDarkLum[l]!, .infinity, count)
                    }
                    try fill(baseDarkLum, .infinity, sizes[levels].w * sizes[levels].h)
                }
            }
            if warp != nil && !needsWarp {
                // Identity frame in warp mode: device-side copy into level 0
                // (dimensions match — that's what made the warp skippable).
                batch.copy(from: uploadBuf, to: gauss[0],
                           byteCount: srcWidth * srcHeight * 16)
            }
            if needsWarp {
                let h = warp!.transforms[fi].inverse  // output → source
                let params = WarpParams(
                    r0: SIMD4<Float>(h[0][0], h[1][0], h[2][0], 0),
                    r1: SIMD4<Float>(h[0][1], h[1][1], h[2][1], 0),
                    r2: SIMD4<Float>(h[0][2], h[1][2], h[2][2], 0),
                    dims: SIMD4<UInt32>(UInt32(srcWidth), UInt32(srcHeight),
                                        UInt32(width), UInt32(height)))
                try batch.dispatch("warp_lanczos3", buffers: [uploadBuf, gauss[0]],
                                   uniforms: bytes(of: params), gridW: width, gridH: height)
            }
            for l in 0..<levels {
                let (w, h) = sizes[l]
                let (nw, nh) = sizes[l + 1]
                let dims = Dims2(w: UInt32(w), h: UInt32(h))
                // Blur (separable, clamp-to-edge) …
                try batch.dispatch("pyr_blur5_h", buffers: [gauss[l], scratchA],
                                   uniforms: bytes(of: dims), gridW: w, gridH: h)
                try batch.dispatch("pyr_blur5_v", buffers: [scratchA, scratchB],
                                   uniforms: bytes(of: dims), gridW: w, gridH: h)
                // … decimate to the next Gaussian level …
                let down = ResizeParams(srcW: UInt32(w), srcH: UInt32(h),
                                        dstW: UInt32(nw), dstH: UInt32(nh))
                try batch.dispatch("pyr_decimate", buffers: [scratchB, gauss[l + 1]],
                                   uniforms: bytes(of: down), gridW: nw, gridH: nh)
                // … upsample it back and select the band winners.
                let up = ResizeParams(srcW: UInt32(nw), srcH: UInt32(nh),
                                      dstW: UInt32(w), dstH: UInt32(h))
                try batch.dispatch("pyr_upsample", buffers: [gauss[l + 1], scratchA],
                                   uniforms: bytes(of: up), gridW: w, gridH: h)
                let count = Count1(count: UInt32(w * h))
                if l == 0 {
                    // Grit suppression (matches PyramidFusion.selectionEnergy):
                    // selection energy computed to a plane, blurred, then the
                    // select reads it — bands themselves are never smoothed.
                    try batch.dispatch("pyr_band_energy",
                                       buffers: [gauss[0], scratchA, gritA],
                                       uniforms: bytes(of: count), gridW: w * h)
                    let blurParams = BlurParams(width: UInt32(w), height: UInt32(h),
                                                radius: Int32(gritWeights.count / 2))
                    try batch.dispatch("blur_h", buffers: [gritA, gritB, gritWeightsBuf],
                                       uniforms: bytes(of: blurParams), gridW: w, gridH: h)
                    try batch.dispatch("blur_v", buffers: [gritB, gritA, gritWeightsBuf],
                                       uniforms: bytes(of: blurParams), gridW: w, gridH: h)
                    try batch.dispatch("pyr_select_smoothed",
                                       buffers: [gauss[0], scratchA, fused[0], bestE[0], gritA],
                                       uniforms: bytes(of: count), gridW: w * h)
                } else if gated(l) {
                    // Focus-gated two-track select. The focus map is the
                    // level-0 grit energy (in gritA after level 0) box-
                    // downsampled by 2^l — exactly focusDownsampled(toLevel:).
                    let box = BoxDownParams(srcW: UInt32(sizes[0].w), srcH: UInt32(sizes[0].h),
                                            dstW: UInt32(w), dstH: UInt32(h),
                                            factor: UInt32(1 << l))
                    try batch.dispatch("box_downsample", buffers: [gritA, focusScratch],
                                       uniforms: bytes(of: box), gridW: w, gridH: h)
                    let fp = FocusParams(count: UInt32(w * h), threshold: focusGate!.threshold)
                    try batch.dispatch("pyr_select_focus_gated",
                                       buffers: [gauss[l], scratchA, focusScratch,
                                                 fused[l], bestE[l], trackB[l]!,
                                                 bestDarkLum[l]!, hasFocus[l]!],
                                       uniforms: bytes(of: fp), gridW: w * h)
                } else {
                    try batch.dispatch("pyr_select",
                                       buffers: [gauss[l], scratchA, fused[l], bestE[l]],
                                       uniforms: bytes(of: count), gridW: w * h)
                }
            }
            // Base level: darkest-frame Gaussian (focus gate) or running sum
            // (standard, averaged after the last frame).
            let baseCount = sizes[levels].w * sizes[levels].h
            if focusGate != nil {
                try batch.dispatch("pyr_base_darkest",
                                   buffers: [fused[levels], gauss[levels], baseDarkLum],
                                   uniforms: bytes(of: Count1(count: UInt32(baseCount))),
                                   gridW: baseCount)
            } else {
                try batch.dispatch("pyr_add4", buffers: [fused[levels], gauss[levels]],
                                   uniforms: bytes(of: Count1(count: UInt32(baseCount))),
                                   gridW: baseCount)
            }
            var previewBuf: WgpuEngine.Buffer? = nil
            if progress != nil {
                // Live preview: collapse the running pyramid down to a
                // low-res level (a few ms of GPU) at the tail of this frame's
                // command buffer; drain() reads it back and emits it. (The
                // track-B merge only lands after the last frame, so a
                // focus-gate preview shows track A / darkest base.)
                try bucket(&tPreview) {
                    previewBuf = try encodeCollapse(
                        batch: batch, fused: fused, sizes: sizes,
                        levels: levels, toLevel: previewLevel,
                        baseScale: baseScale(fi + 1), baseTmp: baseTmp,
                        scratchA: scratchA, scratchB: scratchB)
                }
            }
            batch.submit()
            pending = (fi, previewBuf)
            log?("pyramid \(fi + 1)/\(frameCount) (wgpu)")
        }
        try drain()
        log?(String(format: "pyramid phases: decode-wait %.2fs, upload %.2fs, "
                    + "gpu %.2fs, preview %.2fs", tDecodeWait, tUpload, tGPU, tPreview))

        // Focus-gate merge: where no frame was in focus at a gated level, take
        // track B (darkest, bloom-free), then collapse the merged pyramid.
        if focusGate != nil {
            let mergeBatch = try engine.makeBatch()
            for l in 0..<levels where gated(l) {
                let count = sizes[l].w * sizes[l].h
                try mergeBatch.dispatch("pyr_merge_focus",
                                        buffers: [fused[l], trackB[l]!, hasFocus[l]!],
                                        uniforms: bytes(of: Count1(count: UInt32(count))),
                                        gridW: count)
            }
            mergeBatch.submit()
            engine.waitIdle()
        }

        // Collapse all the way down. Works on a copy of the base (like previews
        // do), so the running base stays intact. baseScale averages the summed
        // base (standard) or leaves the darkest base untouched (focus gate).
        let batch = try engine.makeBatch()
        let result = try encodeCollapse(batch: batch, fused: fused, sizes: sizes,
                                        levels: levels, toLevel: 0,
                                        baseScale: baseScale(frameCount),
                                        baseTmp: baseTmp,
                                        scratchA: scratchA, scratchB: scratchB)
        batch.submit()
        var out = ImageBuffer(width: width, height: height)
        try out.pixels.withUnsafeMutableBufferPointer {
            try engine.download(result, into: $0.baseAddress!,
                                byteCount: width * height * 16)
        }
        return out
    }

    /// Encodes (onto `batch`, after whatever is already there) a collapse of
    /// the running fused pyramid down to `toLevel` (0 = full resolution;
    /// higher = cheap low-res previews), averaging the base by `baseScale`
    /// into a copied scratch first so the running sum stays intact.
    /// Ping-pongs the two scratch buffers for the upsample-add chain and
    /// returns the buffer the result lands in (valid once the batch's
    /// submission completes).
    private static func encodeCollapse(batch: WgpuEngine.Batch,
                                       fused: [WgpuEngine.Buffer],
                                       sizes: [(w: Int, h: Int)], levels: Int,
                                       toLevel: Int, baseScale: Float,
                                       baseTmp: WgpuEngine.Buffer,
                                       scratchA: WgpuEngine.Buffer,
                                       scratchB: WgpuEngine.Buffer) throws -> WgpuEngine.Buffer {
        let (bw, bh) = sizes[levels]
        batch.copy(from: fused[levels], to: baseTmp, byteCount: bw * bh * 16)
        try batch.dispatch("pyr_scale4", buffers: [baseTmp],
                           uniforms: bytes(of: ScaleParams(s: baseScale,
                                                           count: UInt32(bw * bh))),
                           gridW: bw * bh)
        var current = baseTmp
        var currentSize = sizes[levels]
        for l in stride(from: levels - 1, through: toLevel, by: -1) {
            let dst = current === scratchA ? scratchB : scratchA
            let params = ResizeParams(srcW: UInt32(currentSize.w), srcH: UInt32(currentSize.h),
                                      dstW: UInt32(sizes[l].w), dstH: UInt32(sizes[l].h))
            try batch.dispatch("pyr_upsample_add", buffers: [current, fused[l], dst],
                               uniforms: bytes(of: params),
                               gridW: sizes[l].w, gridH: sizes[l].h)
            current = dst
            currentSize = sizes[l]
        }
        return current
    }
}
#endif // HYPERFOCAL_HAVE_WGPU
