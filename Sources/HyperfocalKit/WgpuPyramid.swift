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
    private struct PyrEnvParams { var srcW: UInt32; var srcH: UInt32; var cell: UInt32; var gw: UInt32; var gh: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }

    private static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    /// With `warp`, `frame` returns unwarped frames and the homographies
    /// apply on-device (`warp_lanczos3` into the level-0 buffer) — the CPU
    /// Lanczos warp otherwise dominates fusion wall-clock on big stacks.
    static func fuse(frameCount: Int,
                     warp: PyramidWarp? = nil,
                     log: ((String) -> Void)? = nil,
                     progress: ((Double, Int, ImageBuffer?) -> Void)? = nil,
                     cancellation: CancellationToken? = nil,
                     decodeWorkers: Int? = nil,
                     decodeLookahead: Int? = nil,
                     focusGate: PyramidFusion.GPUFocusGate? = nil,
                     select selOpts: PyramidFusion.GPUSelect = .plain,
                     onSharpness: ((FrameSharpness) -> Void)? = nil,
                     frame: @escaping (Int) throws -> ImageBuffer) throws -> ImageBuffer {
        guard let engine = WgpuEngine.shared else {
            throw StackError.metal("no wgpu adapter available")
        }
        // The envelope discipline needs the focus gate's full-res planes,
        // exactly as on the CPU path.
        let envelope = selOpts.clamp && focusGate != nil
        // Band computation and collapse switch expand operators TOGETHER
        // (see upsampleBurtAt) — both kernel names derive from one flag.
        let upsampleName = selOpts.burt ? "pyr_upsample_burt" : "pyr_upsample"
        let upsampleAddName = selOpts.burt ? "pyr_upsample_add_burt" : "pyr_upsample_add"
        let gatedSelectName = selOpts.smoothed
            ? "pyr_select_focus_gated_smoothed" : "pyr_select_focus_gated"
        // Resolve every kernel up front so a missing entry point fails loudly
        // before any decode work starts.
        for name in ["pyr_blur5_h", "pyr_blur5_v", "pyr_decimate", upsampleName,
                     upsampleAddName, "pyr_select", "pyr_select_smoothed",
                     "pyr_band_energy", "pyr_add4", "pyr_scale4", "pyr_fill",
                     "blur_h", "blur_v"]
                    + (warp == nil ? [] : ["warp_lanczos3"])
                    + (focusGate == nil && onSharpness == nil ? [] : ["box_downsample"])
                    + (focusGate == nil ? [] : [gatedSelectName,
                                                "pyr_base_darkest", "pyr_merge_focus",
                                                "pyr_lum_minmax", "pyr_focus_minmax",
                                                "pyr_merge_focus_gated"])
                    + (envelope ? ["pyr_env_pool"] : []) {
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
        var trackBright: [WgpuEngine.Buffer?] = []
        var hasFocus: [WgpuEngine.Buffer?] = []
        var bestDarkLum: [WgpuEngine.Buffer?] = []
        var bestBrightLum: [WgpuEngine.Buffer?] = []
        var focusScratch: WgpuEngine.Buffer! = nil
        var plainC: [WgpuEngine.Buffer?] = []
        var plainBestE: [WgpuEngine.Buffer?] = []
        var maskBuf: [WgpuEngine.Buffer?] = []
        var bgMaskBuf: [WgpuEngine.Buffer?] = []
        var cleanBuf: [WgpuEngine.Buffer?] = []
        var lumMin0Buf: WgpuEngine.Buffer! = nil
        var lumMax0Buf: WgpuEngine.Buffer! = nil
        var focusMin0Buf: WgpuEngine.Buffer! = nil
        var focusMax0Buf: WgpuEngine.Buffer! = nil
        var baseDarkLum: WgpuEngine.Buffer! = nil
        // Smoothed selection scratch (levels ≥ 1; sized for level 1, reused
        // by every coarser level — the CPU workspace's energyL/energyLTmp).
        var energyLA: WgpuEngine.Buffer! = nil
        var energyLB: WgpuEngine.Buffer! = nil
        // Source-envelope grids (see PyramidFusion.applyEnvelopeClamp).
        var envMaxBuf: WgpuEngine.Buffer! = nil
        var env0MinBuf: WgpuEngine.Buffer! = nil
        var envGrid = (gw: 0, gh: 0)
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
                                         lookahead: decodeLookahead
                                             ?? FramePrefetcher.defaultLookahead,
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
        // Per-frame sharpness retention (retouch's space auto-pick on a PMax
        // primary): level-0 grit energy reduced to the sharpness grid, read
        // back in drain() — mirrors the Metal path.
        var sharpBufs: [WgpuEngine.Buffer] = []
        var sharpnessPlanes: [[Float]] = []
        var sharpGrid = (w: 0, h: 0)
        var pending: (frame: Int, preview: WgpuEngine.Buffer?,
                      sharp: WgpuEngine.Buffer?)? = nil
        func drain() throws {
            guard let p = pending else { return }
            pending = nil
            bucket(&tGPU) { engine.waitIdle() }
            if let sharp = p.sharp {
                var plane = [Float](repeating: 0, count: sharpGrid.w * sharpGrid.h)
                try plane.withUnsafeMutableBufferPointer {
                    try engine.download(sharp, into: $0.baseAddress!,
                                        byteCount: sharpGrid.w * sharpGrid.h * 4)
                }
                sharpnessPlanes.append(plane)
            }
            if let progress {
                var preview: ImageBuffer? = nil
                if let buf = p.preview {
                    let (w, h) = sizes[previewLevel]
                    var img = ImageBuffer(width: w, height: h)
                    try bucket(&tPreview) {
                        // Device storage is f16, like ImageBuffer.pixels — the
                        // readback is a plain copy.
                        try img.pixels.withUnsafeMutableBufferPointer {
                            try engine.download(buf, into: $0.baseAddress!,
                                                byteCount: w * h * 8)
                        }
                    }
                    preview = img
                }
                progress(Double(p.frame + 1) / Double(frameCount), p.frame, preview)
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
                for (l, s) in sizes.enumerated() {
                    gauss.append(try engine.makeBuffer(halves: s.w * s.h * 4))
                    // The base level (the last one) is the f32 accumulator;
                    // every band level is half storage. See pyr_add4.
                    fused.append(l == levels
                        ? try engine.makeBuffer(floats: s.w * s.h * 4)
                        : try engine.makeBuffer(halves: s.w * s.h * 4))
                }
                for s in sizes.dropLast() {
                    bestE.append(try engine.makeBuffer(floats: s.w * s.h))
                }
                if warp != nil {
                    uploadBuf = try engine.makeBuffer(halves: srcWidth * srcHeight * 4)
                }
                // scratchA is the separable blur's f32 intermediate (see
                // pyr_blur5_h) and the f32 upsample target AND, in a later
                // phase, one half of the collapse's half-storage ping-pong.
                // Both roles write every element before reading it and never
                // overlap in time, so the f32 sizing simply leaves the
                // collapse room to spare.
                scratchA = try engine.makeBuffer(floats: width * height * 4)
                scratchB = try engine.makeBuffer(halves: width * height * 4)
                gritA = try engine.makeBuffer(floats: width * height)
                if onSharpness != nil {
                    let f = DMapFusion.sharpnessDownsample
                    sharpGrid = ((width + f - 1) / f, (height + f - 1) / f)
                    sharpBufs = [try engine.makeBuffer(floats: sharpGrid.w * sharpGrid.h),
                                 try engine.makeBuffer(floats: sharpGrid.w * sharpGrid.h)]
                }
                gritB = try engine.makeBuffer(floats: width * height)
                gritWeightsBuf = try engine.makeBuffer(floats: gritWeights.count)
                gritWeights.withUnsafeBytes {
                    engine.upload($0.baseAddress!, byteCount: $0.count, to: gritWeightsBuf)
                }
                baseTmp = try engine.makeBuffer(halves: sizes[levels].w * sizes[levels].h * 4)
                previewLevel = sizes.firstIndex { max($0.w, $0.h) <= 1600 } ?? levels
                if focusGate != nil {
                    for l in 0..<levels {
                        trackB.append(gated(l) ? try engine.makeBuffer(halves: sizes[l].w * sizes[l].h * 4) : nil)
                        trackBright.append(gated(l) ? try engine.makeBuffer(halves: sizes[l].w * sizes[l].h * 4) : nil)
                        hasFocus.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                        bestDarkLum.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                        bestBrightLum.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                    }
                    focusScratch = try engine.makeBuffer(floats: width * height)
                    baseDarkLum = try engine.makeBuffer(floats: sizes[levels].w * sizes[levels].h)
                    // Track C (plain max-energy over every frame) + the level-0
                    // min-luminance the near-black gate reads.
                    for l in 0..<levels {
                        plainC.append(gated(l) ? try engine.makeBuffer(halves: sizes[l].w * sizes[l].h * 4) : nil)
                        plainBestE.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                        maskBuf.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                        bgMaskBuf.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                        cleanBuf.append(gated(l) ? try engine.makeBuffer(floats: sizes[l].w * sizes[l].h) : nil)
                    }
                    lumMin0Buf = try engine.makeBuffer(floats: width * height)
                    lumMax0Buf = try engine.makeBuffer(floats: width * height)
                    focusMin0Buf = try engine.makeBuffer(floats: width * height)
                    focusMax0Buf = try engine.makeBuffer(floats: width * height)
                }
                if selOpts.smoothed {
                    energyLA = try engine.makeBuffer(floats: sizes[1].w * sizes[1].h)
                    energyLB = try engine.makeBuffer(floats: sizes[1].w * sizes[1].h)
                }
                if envelope {
                    let f = PyramidFusion.envCell
                    envGrid = ((width + f - 1) / f, (height + f - 1) / f)
                    envMaxBuf = try engine.makeBuffer(floats: envGrid.gw * envGrid.gh)
                    env0MinBuf = try engine.makeBuffer(floats: envGrid.gw * envGrid.gh)
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
                    engine.upload($0.baseAddress!, byteCount: srcWidth * srcHeight * 8,
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
                        try fill(bestBrightLum[l]!, -1, count)
                        try fill(plainBestE[l]!, -1, count)
                    }
                    try fill(baseDarkLum, .infinity, sizes[levels].w * sizes[levels].h)
                    try fill(lumMin0Buf, .infinity, width * height)
                    try fill(lumMax0Buf, 0, width * height)
                    try fill(focusMin0Buf, .infinity, width * height)
                    try fill(focusMax0Buf, 0, width * height)
                    if envelope {
                        // −1 / ∞ so the first frame installs unconditionally.
                        try fill(envMaxBuf, -1, envGrid.gw * envGrid.gh)
                        try fill(env0MinBuf, .infinity, envGrid.gw * envGrid.gh)
                    }
                }
            }
            if warp != nil && !needsWarp {
                // Identity frame in warp mode: device-side copy into level 0
                // (dimensions match — that's what made the warp skippable).
                batch.copy(from: uploadBuf, to: gauss[0],
                           byteCount: srcWidth * srcHeight * 8)
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
            if focusGate != nil {
                // Running level-0 min/max luminance for the membership.
                try batch.dispatch("pyr_lum_minmax",
                                   buffers: [lumMin0Buf, lumMax0Buf, gauss[0]],
                                   uniforms: bytes(of: Count1(count: UInt32(width * height))),
                                   gridW: width * height)
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
                try batch.dispatch(upsampleName, buffers: [gauss[l + 1], scratchA],
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
                    if envelope {
                        // scratchA still holds the level-0 upsampled coarser —
                        // pool this frame's band into the envelope grids.
                        let ep = PyrEnvParams(srcW: UInt32(w), srcH: UInt32(h),
                                              cell: UInt32(PyramidFusion.envCell),
                                              gw: UInt32(envGrid.gw),
                                              gh: UInt32(envGrid.gh))
                        try batch.dispatch("pyr_env_pool",
                                           buffers: [gauss[0], scratchA,
                                                     envMaxBuf, env0MinBuf],
                                           uniforms: bytes(of: ep),
                                           gridW: envGrid.gw, gridH: envGrid.gh)
                    }
                } else if selOpts.smoothed {
                    // Smoothed selection at this level's own scale: the level's
                    // energy is materialized and blurred with the level-0 grit
                    // kernel, then every selecting track reads it
                    // (levelBandEnergy + selectSmoothed* on the CPU).
                    try batch.dispatch("pyr_band_energy",
                                       buffers: [gauss[l], scratchA, energyLA],
                                       uniforms: bytes(of: count), gridW: w * h)
                    let blurParams = BlurParams(width: UInt32(w), height: UInt32(h),
                                                radius: Int32(gritWeights.count / 2))
                    try batch.dispatch("blur_h", buffers: [energyLA, energyLB, gritWeightsBuf],
                                       uniforms: bytes(of: blurParams), gridW: w, gridH: h)
                    try batch.dispatch("blur_v", buffers: [energyLB, energyLA, gritWeightsBuf],
                                       uniforms: bytes(of: blurParams), gridW: w, gridH: h)
                    if gated(l) {
                        let box = BoxDownParams(srcW: UInt32(sizes[0].w), srcH: UInt32(sizes[0].h),
                                                dstW: UInt32(w), dstH: UInt32(h),
                                                factor: UInt32(1 << l))
                        try batch.dispatch("box_downsample", buffers: [gritA, focusScratch],
                                           uniforms: bytes(of: box), gridW: w, gridH: h)
                        let fp = FocusParams(count: UInt32(w * h), threshold: focusGate!.threshold)
                        try batch.dispatch("pyr_select_focus_gated_smoothed",
                                           buffers: [gauss[l], scratchA, focusScratch,
                                                     fused[l], bestE[l], trackB[l]!,
                                                     bestDarkLum[l]!, trackBright[l]!,
                                                     bestBrightLum[l]!, hasFocus[l]!,
                                                     energyLA],
                                           uniforms: bytes(of: fp), gridW: w * h)
                        // Track C, smoothed: pyr_select_smoothed pointed at its
                        // own buffers over the same energy plane.
                        try batch.dispatch("pyr_select_smoothed",
                                           buffers: [gauss[l], scratchA, plainC[l]!,
                                                     plainBestE[l]!, energyLA],
                                           uniforms: bytes(of: count), gridW: w * h)
                    } else {
                        try batch.dispatch("pyr_select_smoothed",
                                           buffers: [gauss[l], scratchA, fused[l],
                                                     bestE[l], energyLA],
                                           uniforms: bytes(of: count), gridW: w * h)
                    }
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
                                                 bestDarkLum[l]!, trackBright[l]!,
                                                 bestBrightLum[l]!, hasFocus[l]!],
                                       uniforms: bytes(of: fp), gridW: w * h)
                    // Track C: `pyr_select` pointed at its own buffers.
                    try batch.dispatch("pyr_select",
                                       buffers: [gauss[l], scratchA, plainC[l]!, plainBestE[l]!],
                                       uniforms: bytes(of: count), gridW: w * h)
                } else {
                    try batch.dispatch("pyr_select",
                                       buffers: [gauss[l], scratchA, fused[l], bestE[l]],
                                       uniforms: bytes(of: count), gridW: w * h)
                }
            }
            if focusGate != nil {
                // gritA still holds this frame's grit-blurred level-0 energy —
                // accumulate the focus-movement min/max the membership reads.
                try batch.dispatch("pyr_focus_minmax",
                                   buffers: [focusMin0Buf, focusMax0Buf, gritA],
                                   uniforms: bytes(of: Count1(count: UInt32(width * height))),
                                   gridW: width * height)
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
                        scratchA: scratchA, scratchB: scratchB,
                        upsampleAddName: upsampleAddName)
                }
            }
            var sharpBuf: WgpuEngine.Buffer? = nil
            if onSharpness != nil {
                // gritA still holds this frame's grit-blurred level-0 energy
                // (gated levels only read it) — reduce to the sharpness grid.
                sharpBuf = sharpBufs[fi % 2]
                let box = BoxDownParams(srcW: UInt32(width), srcH: UInt32(height),
                                        dstW: UInt32(sharpGrid.w), dstH: UInt32(sharpGrid.h),
                                        factor: UInt32(DMapFusion.sharpnessDownsample))
                try batch.dispatch("box_downsample", buffers: [gritA, sharpBuf!],
                                   uniforms: bytes(of: box),
                                   gridW: sharpGrid.w, gridH: sharpGrid.h)
            }
            batch.submit()
            pending = (fi, previewBuf, sharpBuf)
            log?("pyramid \(fi + 1)/\(frameCount) (wgpu)")
        }
        try drain()
        if let onSharpness, sharpnessPlanes.count == frameCount {
            onSharpness(FrameSharpness(fullWidth: width, fullHeight: height,
                                       factor: DMapFusion.sharpnessDownsample,
                                       planes: sharpnessPlanes))
        }
        log?(String(format: "pyramid phases: decode-wait %.2fs, upload %.2fs, "
                    + "gpu %.2fs, preview %.2fs", tDecodeWait, tUpload, tGPU, tPreview))

        // Focus-gate merge: where no frame was in focus at a gated level, take
        // track B (darkest, bloom-free), then collapse the merged pyramid.
        // The focus planes and envelope grids outlive the merge: the veto
        // feeds the masks here, and the clamp runs on the collapsed image at
        // the end — all through the SHARED CPU helpers, so the three engines
        // cannot drift.
        var fmaxArr: [Float] = []
        var fminArr: [Float] = []
        var envMaxArr: [Float] = []
        if focusGate != nil {
            // Near-black membership from the level-0 min luminance, built by the
            // SHARED CPU helper so this merge and the CPU one cannot drift.
            var lm = [Float](repeating: 0, count: width * height)
            try lm.withUnsafeMutableBytes {
                try engine.download(lumMin0Buf, into: $0.baseAddress!, byteCount: $0.count)
            }
            var lx = [Float](repeating: 0, count: width * height)
            try lx.withUnsafeMutableBytes {
                try engine.download(lumMax0Buf, into: $0.baseAddress!, byteCount: $0.count)
            }
            var fmin = [Float](repeating: 0, count: width * height)
            try fmin.withUnsafeMutableBytes {
                try engine.download(focusMin0Buf, into: $0.baseAddress!, byteCount: $0.count)
            }
            var fmax = [Float](repeating: 0, count: width * height)
            try fmax.withUnsafeMutableBytes {
                try engine.download(focusMax0Buf, into: $0.baseAddress!, byteCount: $0.count)
            }
            fmaxArr = fmax
            fminArr = fmin
            var veto: [Float]? = nil
            if envelope {
                let cells = envGrid.gw * envGrid.gh
                var envMax = [Float](repeating: 0, count: cells)
                try envMax.withUnsafeMutableBytes {
                    try engine.download(envMaxBuf, into: $0.baseAddress!, byteCount: $0.count)
                }
                envMaxArr = envMax
                if selOpts.veto {
                    var envMin = [Float](repeating: 0, count: cells)
                    try envMin.withUnsafeMutableBytes {
                        try engine.download(env0MinBuf, into: $0.baseAddress!, byteCount: $0.count)
                    }
                    veto = PyramidFusion.nearBlackTextureVeto(
                        envMax0: envMaxArr, env0Min: envMin, focusMax0: fmaxArr,
                        frameCount: frameCount, width: width, height: height,
                        env: ProcessInfo.processInfo.environment)
                    if veto != nil { log?("pmax: near-black texture veto engaged (wgpu)") }
                }
            }
            let gate = PyramidFusion.debloomMasks(lumMin0: lm, lumMax0: lx,
                                                  focusMax0: fmax,
                                                  focusMin0: fmin,
                                                  frameCount: frameCount,
                                                  width: width, height: height,
                                                  sizes: sizes, levels: levels,
                                                  darkCoarse: focusGate!.coarseLevels,
                                                  nearBlackVeto: veto)
            log?(String(format: "pmax debloom gate: scale=%.4f, mean mask %.3f, open-bg %.3f (wgpu)",
                        gate.scale, gate.mean, gate.bgFraction))
            let mergeBatch = try engine.makeBatch()
            for l in 0..<levels where gated(l) {
                let count = sizes[l].w * sizes[l].h
                guard l >= 1, !gate.masks[l].isEmpty else {
                    // Level 0 carries no track B, so it keeps the plain merge.
                    try mergeBatch.dispatch("pyr_merge_focus",
                                            buffers: [fused[l], trackB[l]!, hasFocus[l]!],
                                            uniforms: bytes(of: Count1(count: UInt32(count))),
                                            gridW: count)
                    continue
                }
                gate.masks[l].withUnsafeBytes {
                    engine.upload($0.baseAddress!, byteCount: $0.count, to: maskBuf[l]!)
                }
                let n = sizes[l].w * sizes[l].h
                let bgm = gate.bgMasks[l].isEmpty
                    ? [Float](repeating: 0, count: n) : gate.bgMasks[l]
                bgm.withUnsafeBytes {
                    engine.upload($0.baseAddress!, byteCount: $0.count, to: bgMaskBuf[l]!)
                }
                let cln = gate.clean[l].isEmpty
                    ? [Float](repeating: 0, count: n) : gate.clean[l]
                cln.withUnsafeBytes {
                    engine.upload($0.baseAddress!, byteCount: $0.count, to: cleanBuf[l]!)
                }
                try mergeBatch.dispatch("pyr_merge_focus_gated",
                                        buffers: [fused[l], trackB[l]!, bestDarkLum[l]!,
                                                  trackBright[l]!, bestBrightLum[l]!,
                                                  hasFocus[l]!, plainC[l]!, maskBuf[l]!,
                                                  bgMaskBuf[l]!, cleanBuf[l]!],
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
                                        scratchA: scratchA, scratchB: scratchB,
                                        upsampleAddName: upsampleAddName)
        batch.submit()
        var out = ImageBuffer(width: width, height: height)
        try out.pixels.withUnsafeMutableBufferPointer {
            try engine.download(result, into: $0.baseAddress!,
                                byteCount: width * height * 8)
        }
        // Envelope clamp on the collapsed image, via the shared CPU helper —
        // a small full-res pass, same for every engine.
        if envelope, !envMaxArr.isEmpty {
            PyramidFusion.applyEnvelopeClamp(out: &out, envMax: [envMaxArr],
                                             focusMax0: fmaxArr, focusMin0: fminArr,
                                             frameCount: frameCount,
                                             burtExpand: selOpts.burt,
                                             env: ProcessInfo.processInfo.environment,
                                             log: log)
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
                                       scratchB: WgpuEngine.Buffer,
                                       upsampleAddName: String) throws -> WgpuEngine.Buffer {
        let (bw, bh) = sizes[levels]
        // scale4 divides the f32 base accumulator by the frame count and
        // narrows it into the half collapse chain in one pass — it needed a
        // device-side copy of the base first while it scaled in place.
        try batch.dispatch("pyr_scale4", buffers: [baseTmp, fused[levels]],
                           uniforms: bytes(of: ScaleParams(s: baseScale,
                                                           count: UInt32(bw * bh))),
                           gridW: bw * bh)
        var current = baseTmp
        var currentSize = sizes[levels]
        for l in stride(from: levels - 1, through: toLevel, by: -1) {
            let dst = current === scratchA ? scratchB : scratchA
            let params = ResizeParams(srcW: UInt32(currentSize.w), srcH: UInt32(currentSize.h),
                                      dstW: UInt32(sizes[l].w), dstH: UInt32(sizes[l].h))
            try batch.dispatch(upsampleAddName, buffers: [current, fused[l], dst],
                               uniforms: bytes(of: params),
                               gridW: sizes[l].w, gridH: sizes[l].h)
            current = dst
            currentSize = sizes[l]
        }
        return current
    }
}
#endif // HYPERFOCAL_HAVE_WGPU
