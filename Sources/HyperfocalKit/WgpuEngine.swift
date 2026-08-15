#if HYPERFOCAL_HAVE_WGPU
import CWgpu
import Foundation

/// wgpu compute backend: the Windows/Linux
/// counterpart of `MetalEngine` — kernels compiled once from WGSL at startup,
/// pipeline cache, dispatch helpers. Same discipline as Metal: all image
/// kernels operate on raw storage buffers (no textures) with taps, clamps,
/// and luma weights identical to the CPU path.
///
/// **Storage is f16, arithmetic is f32** — the same split as `MetalEngine`,
/// reached differently. WGSL's `f16` *type* needs the `shader-f16` feature,
/// which is not universal (WARP and llvmpipe, the two software surfaces this
/// backend is validated on, are exactly the cases that can lack it), so an
/// RGBA half4 is carried as a `vec2u`: four halves in two `u32` words, laid
/// out byte-identically to `ImageBuffer.pixels` and to the Metal path's
/// `half4`, so uploads and downloads are plain copies. See `h4load`/`h4store`
/// — the store side deliberately does not use `pack2x16float`, whose rounding
/// mode differs by backend. Scalar PLANES stay f32, and so do the
/// intermediates that must (`pyr_blur5_h`'s H→V result, `pyr_upsample`'s
/// output, the tent/base accumulators) — see the kernels for why each does.
///
/// Differences from Metal the callers must respect: buffers are not
/// host-visible (`upload`/`download` instead of `contents()`), and binding is
/// per-dispatch bind groups built from the buffer list (`run`).
public final class WgpuEngine {

    public static let shared: WgpuEngine? = WgpuEngine()

    let instance: WGPUInstance
    let device: WGPUDevice
    let queue: WGPUQueue
    public let adapterSummary: String
    /// True when the adapter is a software rasterizer (D3D12 WARP, llvmpipe —
    /// wgpu reports adapterType CPU). Software "GPUs" execute on the same
    /// cores the CPU engine uses, minus vectorization the CPU path has:
    /// measured on a 2-core VM, WARP pyramid fusion ran ~11 s/frame vs the
    /// CPU path's ~3 s (11 MP). Auto engine selection skips these; parity
    /// work forces them via `allowSoftwareAdapter`.
    public let isSoftwareAdapter: Bool
    /// Opt-in to auto-selecting a software adapter anyway — the CLI's
    /// explicit `--engine gpu` and the HYPERFOCAL_WGPU_SOFTWARE=1 env set
    /// this so parity/validation runs still exercise the GPU path on
    /// WARP-only machines.
    public static var allowSoftwareAdapter =
        ProcessInfo.processInfo.environment["HYPERFOCAL_WGPU_SOFTWARE"] == "1"
    /// The auto-selection gate: a real GPU, or software explicitly allowed.
    public var usableForAutoSelection: Bool {
        !isSoftwareAdapter || Self.allowSoftwareAdapter
    }
    /// HYPERFOCAL_WGPU_FALLBACK=1 asks for the *fallback* adapter (WebGPU's
    /// `forceFallbackAdapter`: D3D12 WARP here, llvmpipe on Linux) even when a
    /// real GPU is present. `HYPERFOCAL_WGPU_SOFTWARE` only permits a software
    /// adapter that was going to be picked anyway, which on a machine with a
    /// discrete card selects nothing — so without this, the surface CI gates
    /// on cannot be reproduced on a developer machine, and the surface is not
    /// incidental: it is why the WGSL carries halves as packed `u32` pairs
    /// instead of requiring `shader-f16`.
    private static let forceFallbackAdapter =
        ProcessInfo.processInfo.environment["HYPERFOCAL_WGPU_FALLBACK"] == "1"
    private let shader: WGPUShaderModule
    private var pipelines: [String: WGPUComputePipeline] = [:]
    private let lock = NSLock()

    private init?() {
        guard let instance = wgpuCreateInstance(nil) else { return nil }

        func sv(_ s: WGPUStringView) -> String {
            guard let d = s.data else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: d, count: s.length),
                          as: UTF8.self)
        }

        // Adapter + device requests are callback-shaped; wgpu-native resolves
        // them from wgpuInstanceProcessEvents, typically on the first pump.
        var adapter: WGPUAdapter? = nil
        var options = WGPURequestAdapterOptions()
        options.forceFallbackAdapter = WGPUBool(Self.forceFallbackAdapter ? 1 : 0)
        var adapterCB = WGPURequestAdapterCallbackInfo()
        adapterCB.mode = WGPUCallbackMode_AllowProcessEvents
        adapterCB.callback = { status, adapter, _, ud1, _ in
            if status == WGPURequestAdapterStatus_Success {
                ud1!.assumingMemoryBound(to: WGPUAdapter?.self).pointee = adapter
            }
        }
        withUnsafeMutablePointer(to: &adapter) { p in
            adapterCB.userdata1 = UnsafeMutableRawPointer(p)
            _ = wgpuInstanceRequestAdapter(instance, &options, adapterCB)
            for _ in 0..<1000 where p.pointee == nil {
                wgpuInstanceProcessEvents(instance)
            }
        }
        guard let adapter else {
            wgpuInstanceRelease(instance)
            return nil
        }

        var info = WGPUAdapterInfo()
        wgpuAdapterGetInfo(adapter, &info)
        self.adapterSummary = "\(sv(info.device)) [backend \(info.backendType.rawValue)]"
        self.isSoftwareAdapter = info.adapterType == WGPUAdapterType_CPU

        // The default limit of 8 storage buffers per stage is below what
        // guided_apply_blend needs (9); require the adapter's real limits.
        var limits = WGPULimits()
        _ = wgpuAdapterGetLimits(adapter, &limits)

        var device: WGPUDevice? = nil
        var devCB = WGPURequestDeviceCallbackInfo()
        devCB.mode = WGPUCallbackMode_AllowProcessEvents
        devCB.callback = { status, device, _, ud1, _ in
            if status == WGPURequestDeviceStatus_Success {
                ud1!.assumingMemoryBound(to: WGPUDevice?.self).pointee = device
            }
        }
        withUnsafeMutablePointer(to: &device) { p in
            devCB.userdata1 = UnsafeMutableRawPointer(p)
            withUnsafePointer(to: &limits) { lp in
                var desc = WGPUDeviceDescriptor()
                desc.requiredLimits = lp
                _ = wgpuAdapterRequestDevice(adapter, &desc, devCB)
            }
            for _ in 0..<1000 where p.pointee == nil {
                wgpuInstanceProcessEvents(instance)
            }
        }
        guard let device, let queue = wgpuDeviceGetQueue(device) else {
            wgpuAdapterRelease(adapter)
            wgpuInstanceRelease(instance)
            return nil
        }
        wgpuAdapterRelease(adapter)

        var wgsl = WGPUShaderSourceWGSL()
        wgsl.chain.sType = WGPUSType_ShaderSourceWGSL
        let shader: WGPUShaderModule? = Self.kernelSource.withCString { code in
            wgsl.code = WGPUStringView(data: code, length: strlen(code))
            var desc = WGPUShaderModuleDescriptor()
            return withUnsafeMutablePointer(to: &wgsl) { p -> WGPUShaderModule? in
                desc.nextInChain = UnsafeMutableRawPointer(p)
                    .assumingMemoryBound(to: WGPUChainedStruct.self)
                return wgpuDeviceCreateShaderModule(device, &desc)
            }
        }
        guard let shader else {
            // A kernel source error must be loud, not a silent CPU fallback.
            FileHandle.standardError.write(Data("wgpu kernel compile failed\n".utf8))
            return nil
        }

        self.instance = instance
        self.device = device
        self.queue = queue
        self.shader = shader
    }

    // MARK: - Pipelines

    func pipeline(_ name: String) throws -> WGPUComputePipeline {
        lock.lock()
        defer { lock.unlock() }
        if let p = pipelines[name] { return p }
        var desc = WGPUComputePipelineDescriptor()
        desc.compute.module = shader
        let p: WGPUComputePipeline? = name.withCString { entry in
            desc.compute.entryPoint = WGPUStringView(data: entry, length: strlen(entry))
            return wgpuDeviceCreateComputePipeline(device, &desc)
        }
        guard let p else { throw StackError.metal("missing wgpu kernel \(name)") }
        pipelines[name] = p
        return p
    }

    // MARK: - Buffers

    public final class Buffer {
        let raw: WGPUBuffer
        let byteCount: Int
        fileprivate init(raw: WGPUBuffer, byteCount: Int) {
            self.raw = raw
            self.byteCount = byteCount
        }
        deinit { wgpuBufferRelease(raw) }
    }

    func makeBuffer(floats count: Int) throws -> Buffer {
        var desc = WGPUBufferDescriptor()
        desc.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc | WGPUBufferUsage_CopyDst
        desc.size = UInt64(count * 4)
        guard let b = wgpuDeviceCreateBuffer(device, &desc) else {
            throw StackError.metal("cannot allocate \(count * 4) byte wgpu buffer")
        }
        return Buffer(raw: b, byteCount: count * 4)
    }

    /// Half-precision image storage — the allocation for anything the kernels
    /// declare as `array<Half4>`, and byte-identical to `ImageBuffer.pixels`,
    /// so upload and download are plain copies. `count` is halves, as
    /// `makeBuffer(floats:)` takes floats; both round the allocation up to the
    /// 4-byte multiple WebGPU requires of buffer copies (RGBA counts are
    /// multiples of 4 halves anyway, so this only matters for oddly sized
    /// scratch).
    func makeBuffer(halves count: Int) throws -> Buffer {
        var desc = WGPUBufferDescriptor()
        desc.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc | WGPUBufferUsage_CopyDst
        let byteCount = (count * 2 + 3) & ~3
        desc.size = UInt64(byteCount)
        guard let b = wgpuDeviceCreateBuffer(device, &desc) else {
            throw StackError.metal("cannot allocate \(byteCount) byte wgpu buffer")
        }
        return Buffer(raw: b, byteCount: byteCount)
    }

    func upload(_ src: UnsafeRawPointer, byteCount: Int, to buffer: Buffer) {
        wgpuQueueWriteBuffer(queue, buffer.raw, 0, src, byteCount)
    }

    /// Copy the first `byteCount` bytes (default: all) of a buffer back to
    /// host memory: staging copy + map + poll-to-done.
    func download(_ buffer: Buffer, into dst: UnsafeMutableRawPointer,
                  byteCount: Int? = nil) throws {
        let count = byteCount ?? buffer.byteCount
        var desc = WGPUBufferDescriptor()
        desc.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst
        desc.size = UInt64(count)
        guard let staging = wgpuDeviceCreateBuffer(device, &desc) else {
            throw StackError.metal("cannot allocate wgpu staging buffer")
        }
        defer { wgpuBufferRelease(staging) }
        let encoder = wgpuDeviceCreateCommandEncoder(device, nil)
        wgpuCommandEncoderCopyBufferToBuffer(encoder, buffer.raw, 0, staging, 0,
                                             UInt64(count))
        var cmd = wgpuCommandEncoderFinish(encoder, nil)
        wgpuQueueSubmit(queue, 1, &cmd)
        wgpuCommandBufferRelease(cmd!)
        wgpuCommandEncoderRelease(encoder)

        var mapped = false
        var cb = WGPUBufferMapCallbackInfo()
        cb.mode = WGPUCallbackMode_AllowProcessEvents
        cb.callback = { status, _, ud1, _ in
            if status == WGPUMapAsyncStatus_Success {
                ud1!.assumingMemoryBound(to: Bool.self).pointee = true
            }
        }
        try withUnsafeMutablePointer(to: &mapped) { p in
            cb.userdata1 = UnsafeMutableRawPointer(p)
            _ = wgpuBufferMapAsync(staging, WGPUMapMode_Read, 0, count, cb)
            var spins = 0
            while !p.pointee {
                _ = wgpuDevicePoll(device, WGPUBool(1), nil)
                spins += 1
                if spins > 1_000_000 { throw StackError.metal("wgpu map timeout") }
            }
        }
        guard let src = wgpuBufferGetConstMappedRange(staging, 0, count) else {
            throw StackError.metal("wgpu map returned no range")
        }
        dst.copyMemory(from: src, byteCount: count)
        wgpuBufferUnmap(staging)
    }

    // MARK: - Dispatch

    /// Blocks until every submitted command buffer has finished executing.
    func waitIdle() {
        while wgpuDevicePoll(device, WGPUBool(1), nil) == WGPUBool(0) {}
    }

    /// Many kernel dispatches (and device-side copies) encoded into one
    /// command buffer and submitted together — submit-per-dispatch costs a
    /// queue round-trip per kernel, which dominates at per-frame orchestration
    /// dispatch counts (WgpuPyramid encodes ~5 per pyramid level).
    ///
    /// Uniform data rides on `wgpuQueueWriteBuffer`, which is queue-ordered:
    /// writes staged before `submit()` are applied before the submitted
    /// commands execute, and writes staged *after* a submit are applied after
    /// that submit's commands finish. The latter is what lets callers stage
    /// the next frame's upload while the previous frame is still on the GPU
    /// without the Metal path's ping-pong buffers.
    final class Batch {
        private let engine: WgpuEngine
        private let encoder: WGPUCommandEncoder
        private var pass: WGPUComputePassEncoder? = nil
        // Bind groups and uniform buffers referenced by the not-yet-submitted
        // encoder: wgpu-core takes ownership of in-flight resources only at
        // submit, so hold our references until then.
        private var bindGroups: [WGPUBindGroup] = []
        private var uniformBufs: [WGPUBuffer] = []
        private var submitted = false

        // The 1-D dispatch shape. These are the Swift half of a contract with
        // the WGSL: kWG1D / kTile1D in kernelSource must hold the same values,
        // because `flatten1D` there reconstructs the linear element index from
        // the tiled workgroup grid this produces.
        fileprivate static let wg1D = 256
        fileprivate static let tile1D = 32768
        /// WebGPU's guaranteed `maxComputeWorkgroupsPerDimension`.
        fileprivate static let maxPerDimension = 65535

        fileprivate init(engine: WgpuEngine) throws {
            guard let encoder = wgpuDeviceCreateCommandEncoder(engine.device, nil) else {
                throw StackError.metal("cannot create wgpu command encoder")
            }
            self.engine = engine
            self.encoder = encoder
        }

        deinit {
            // Abandoned (error-path) batch: drop everything unsubmitted.
            if !submitted {
                if let p = pass {
                    wgpuComputePassEncoderEnd(p)
                    wgpuComputePassEncoderRelease(p)
                }
                wgpuCommandEncoderRelease(encoder)
                for bg in bindGroups { wgpuBindGroupRelease(bg) }
                for u in uniformBufs { wgpuBufferRelease(u) }
            }
        }

        /// Encode one dispatch: bind group from the buffer list (bindings
        /// 0..n in order, uniforms — if any — as the last binding). The WGSL
        /// kernels declare their bindings in exactly this order. Workgroup
        /// size is 16x16 for 2D kernels, 256 for 1D — matches the
        /// @workgroup_size in the WGSL below.
        func dispatch(_ kernelName: String, buffers: [Buffer],
                      uniforms: [UInt8]? = nil, gridW: Int, gridH: Int = 1) throws {
            precondition(!submitted, "wgpu batch already submitted")
            let pipeline = try engine.pipeline(kernelName)

            var entries: [WGPUBindGroupEntry] = []
            for (i, b) in buffers.enumerated() {
                var e = WGPUBindGroupEntry()
                e.binding = UInt32(i)
                e.buffer = b.raw
                e.size = UInt64(b.byteCount)
                entries.append(e)
            }
            if let uniforms {
                var desc = WGPUBufferDescriptor()
                desc.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst
                desc.size = UInt64(uniforms.count)
                guard let u = wgpuDeviceCreateBuffer(engine.device, &desc) else {
                    throw StackError.metal("cannot allocate wgpu uniform buffer")
                }
                uniforms.withUnsafeBytes {
                    wgpuQueueWriteBuffer(engine.queue, u, 0, $0.baseAddress!, $0.count)
                }
                uniformBufs.append(u)
                var e = WGPUBindGroupEntry()
                e.binding = UInt32(buffers.count)
                e.buffer = u
                e.size = UInt64(uniforms.count)
                entries.append(e)
            }
            var bgDesc = WGPUBindGroupDescriptor()
            bgDesc.layout = wgpuComputePipelineGetBindGroupLayout(pipeline, 0)
            bgDesc.entryCount = entries.count
            let bindGroup = entries.withUnsafeBufferPointer { p -> WGPUBindGroup? in
                bgDesc.entries = p.baseAddress
                return wgpuDeviceCreateBindGroup(engine.device, &bgDesc)
            }
            guard let bindGroup else { throw StackError.metal("wgpu bind group failed") }
            bindGroups.append(bindGroup)

            if pass == nil {
                pass = wgpuCommandEncoderBeginComputePass(encoder, nil)
            }
            wgpuComputePassEncoderSetPipeline(pass, pipeline)
            wgpuComputePassEncoderSetBindGroup(pass, 0, bindGroup, 0, nil)
            if gridH > 1 {
                wgpuComputePassEncoderDispatchWorkgroups(
                    pass, UInt32((gridW + 15) / 16), UInt32((gridH + 15) / 16), 1)
            } else {
                // WebGPU guarantees only 65535 workgroups per dimension, so a
                // flat 1-D grid caps out at 65535*256 ≈ 16.8 M elements — under
                // a 12 MP RGBA plane's ~48 M. Past one tile, wrap the grid into
                // Y; `flatten1D` in the WGSL undoes it. Exceeding the limit is
                // a validation error that aborts the process, not a soft
                // failure, so this must stay in step with kTile1D.
                let groups = (gridW + Self.wg1D - 1) / Self.wg1D
                if groups <= Self.tile1D {
                    wgpuComputePassEncoderDispatchWorkgroups(pass, UInt32(groups), 1, 1)
                } else {
                    let rows = (groups + Self.tile1D - 1) / Self.tile1D
                    // Tiling buys ~5.5e11 elements, so this is unreachable for
                    // any real image — but overrunning a WebGPU limit aborts
                    // the process from Rust rather than returning an error, and
                    // a stack trace through wgpu-native is a poor way to learn
                    // you exceeded a documented cap. Fail as ourselves instead.
                    guard rows <= Self.maxPerDimension else {
                        throw StackError.metal(
                            "wgpu 1-D dispatch too large: \(gridW) elements needs "
                            + "\(rows) rows, limit \(Self.maxPerDimension)")
                    }
                    wgpuComputePassEncoderDispatchWorkgroups(
                        pass, UInt32(Self.tile1D), UInt32(rows), 1)
                }
            }
        }

        /// Device-side buffer copy (the Metal path's blit). Copies encode at
        /// the encoder level, so this ends the open compute pass; the next
        /// dispatch begins a fresh one.
        func copy(from src: Buffer, to dst: Buffer, byteCount: Int) {
            precondition(!submitted, "wgpu batch already submitted")
            if let p = pass {
                wgpuComputePassEncoderEnd(p)
                wgpuComputePassEncoderRelease(p)
                pass = nil
            }
            wgpuCommandEncoderCopyBufferToBuffer(encoder, src.raw, 0, dst.raw, 0,
                                                 UInt64(byteCount))
        }

        /// Submit everything encoded so far as one command buffer. Returns
        /// without waiting — pair with `waitIdle` (or a `download`, whose map
        /// wait is queue-ordered behind this work) when the results are
        /// needed.
        func submit() {
            precondition(!submitted, "wgpu batch already submitted")
            submitted = true
            if let p = pass {
                wgpuComputePassEncoderEnd(p)
                wgpuComputePassEncoderRelease(p)
                pass = nil
            }
            var cmd = wgpuCommandEncoderFinish(encoder, nil)
            wgpuQueueSubmit(engine.queue, 1, &cmd)
            wgpuCommandBufferRelease(cmd!)
            wgpuCommandEncoderRelease(encoder)
            for bg in bindGroups { wgpuBindGroupRelease(bg) }
            bindGroups = []
            for u in uniformBufs { wgpuBufferRelease(u) }
            uniformBufs = []
        }
    }

    func makeBatch() throws -> Batch { try Batch(engine: self) }

    /// One kernel dispatch: single-dispatch batch, submit, wait. Convenience
    /// for the parity harness and one-off kernels; per-frame orchestration
    /// encodes whole frames through `Batch` directly.
    func run(_ kernelName: String, buffers: [Buffer],
             uniforms: [UInt8]? = nil, gridW: Int, gridH: Int = 1) throws {
        let batch = try makeBatch()
        try batch.dispatch(kernelName, buffers: buffers, uniforms: uniforms,
                           gridW: gridW, gridH: gridH)
        batch.submit()
        waitIdle()
    }

    // MARK: - Kernels (WGSL)
    // Translated one-for-one from MetalEngine.kernelSource — taps, edge
    // clamps, anti-ringing, and luma weights must stay identical to both the
    // MSL and CPU implementations. Bindings are declared per-kernel in the
    // order `run` binds them: storage buffers 0..n-1, uniforms last.

    static let kernelSource = """
    // 1-D kernels are dispatched over a grid that may be tiled in Y, because
    // WebGPU caps each dispatch dimension at 65535 workgroups
    // (maxComputeWorkgroupsPerDimension) — at 256 elements per workgroup a flat
    // 1-D grid tops out at ~16.8 M elements, which a 12 MP RGBA plane
    // (~48 M components) blows straight past. `flatten1D` turns the possibly
    // tiled workgroup grid back into the linear element index these kernels
    // index by; kTile1D must match Batch.dispatch's tile width. When the grid
    // fits in one row the Y term is zero, so the same expression serves both
    // shapes. See Batch.dispatch.
    const kWG1D: u32 = 256u;
    const kTile1D: u32 = 32768u;
    fn flatten1D(g: vec3u) -> vec3u {
        return vec3u(g.y * (kTile1D * kWG1D) + g.x, 0u, 0u);
    }

    // RGBA image storage: four halves per pixel, as two u32 words — the exact
    // bytes of ImageBuffer.pixels and of the MSL kernels' half4. WGSL's f16
    // TYPE would need the `shader-f16` feature, which WARP and llvmpipe (the
    // software surfaces this backend is validated on) can lack; nothing here
    // needs any feature. Widen on load, narrow on store — arithmetic stays
    // f32 everywhere, as in Metal.
    alias Half4 = vec2u;

    // Loads use the core builtin: f16→f32 is exact, so every backend agrees.
    fn h4load(v: Half4) -> vec4f {
        return vec4f(unpack2x16float(v.x), unpack2x16float(v.y));
    }

    // Stores do NOT use pack2x16float, and this is not premature caution.
    // WGSL leaves the narrowing's rounding mode to the backend, and they do
    // not agree: on Vulkan and Metal it is round-to-nearest-even, matching
    // Swift's `Float16(x)`, but the D3D12 backend lowers it to HLSL
    // `f32tof16`, which TRUNCATES toward zero. Every stored pixel then sits up
    // to one ulp below the CPU's, systematically — measured on WARP, that is
    // the whole difference between 71 dB and 100+ dB of CPU↔GPU agreement, and
    // it silently downgrades every kernel that writes a pixel. Rounding
    // explicitly costs ~10 ALU ops per store on kernels that are memory-bound
    // anyway (measured: no change in GPU compute time), and it buys the
    // property the whole half-storage port rests on — both engines holding
    // byte-identical pixels on every adapter, not just the one this was
    // developed on.
    //
    // The routine is the standard bit-level RTNE narrowing (Giesen's
    // float_to_half_fast3_rtne): exponent rebias plus a rounding bias for
    // normals, a magic-add for subnormals (f32 addition is itself
    // round-to-nearest-even, so the alignment does the rounding), and
    // saturation to Inf/NaN at the top.
    fn f16bits(v: f32) -> u32 {
        var u = bitcast<u32>(v);
        let sign = u & 0x80000000u;
        u = u ^ sign;
        var o: u32;
        if (u >= 0x47800000u) {
            // Inf, NaN, or magnitudes half cannot hold (≥ 65536).
            o = select(0x7c00u, 0x7e00u, u > 0x7f800000u);
        } else if (u < 0x38800000u) {
            // Result is a half subnormal (or zero): add 0.5 to shove the
            // mantissa into place, then subtract the same bias back out.
            o = bitcast<u32>(bitcast<f32>(u) + 0.5) - 0x3f000000u;
        } else {
            let mantOdd = (u >> 13u) & 1u;
            // ((15 - 127) << 23) + 0xfff, then +1 when the kept mantissa is
            // odd — that pair is what makes a tie round to even.
            o = (u + 0xC8000FFFu + mantOdd) >> 13u;
        }
        return o | (sign >> 16u);
    }
    fn h4store(v: vec4f) -> Half4 {
        return Half4(f16bits(v.x) | (f16bits(v.y) << 16u),
                     f16bits(v.z) | (f16bits(v.w) << 16u));
    }

    struct WarpParams {
        r0: vec4f,
        r1: vec4f,
        r2: vec4f,
        dims: vec4u,   // srcW, srcH, dstW, dstH
    }

    @group(0) @binding(0) var<storage, read> warp_src: array<Half4>;
    @group(0) @binding(1) var<storage, read_write> warp_dst: array<Half4>;
    @group(0) @binding(2) var<uniform> warp_p: WarpParams;

    // Lanczos-3 via the product form 3·sin(πx)·sin(πx/3)/(πx)² — identical
    // formula to Warp.lanczos3 and the MSL kernel.
    fn lanczos3(x: f32) -> f32 {
        let ax = abs(x);
        if (ax < 1e-5) { return 1.0; }
        if (ax >= 3.0) { return 0.0; }
        let px = 3.14159265358979 * ax;
        return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
    }

    @compute @workgroup_size(16, 16)
    fn warp_lanczos3(@builtin(global_invocation_id) gid: vec3u) {
        let dw = warp_p.dims.z;
        let dh = warp_p.dims.w;
        if (gid.x >= dw || gid.y >= dh) { return; }
        let sw = i32(warp_p.dims.x);
        let sh = i32(warp_p.dims.y);
        let v = vec3f(f32(gid.x), f32(gid.y), 1.0);
        let z = dot(warp_p.r2.xyz, v);
        let sx = dot(warp_p.r0.xyz, v) / z;
        let sy = dot(warp_p.r1.xyz, v) / z;
        let x0 = i32(floor(sx));
        let y0 = i32(floor(sy));
        let fx = sx - f32(x0);
        let fy = sy - f32(y0);
        var wx: array<f32, 6>;
        var wy: array<f32, 6>;
        var sumX = 0.0;
        var sumY = 0.0;
        for (var k = 0; k < 6; k++) {
            wx[k] = lanczos3(fx - f32(k - 2)); sumX += wx[k];
            wy[k] = lanczos3(fy - f32(k - 2)); sumY += wy[k];
        }
        var acc = vec4f(0.0);
        for (var ky = 0; ky < 6; ky++) {
            let ty = clamp(y0 - 2 + ky, 0, sh - 1);
            var row = vec4f(0.0);
            for (var kx = 0; kx < 6; kx++) {
                let tx = clamp(x0 - 2 + kx, 0, sw - 1);
                row += h4load(warp_src[ty * sw + tx]) * wx[kx];
            }
            acc += row * wy[ky];
        }
        var sample = acc / (sumX * sumY);
        let cx0 = clamp(x0, 0, sw - 1);
        let cx1 = clamp(x0 + 1, 0, sw - 1);
        let cy0 = clamp(y0, 0, sh - 1);
        let cy1 = clamp(y0 + 1, 0, sh - 1);
        let a = h4load(warp_src[cy0 * sw + cx0]);
        let b = h4load(warp_src[cy0 * sw + cx1]);
        let c = h4load(warp_src[cy1 * sw + cx0]);
        let d = h4load(warp_src[cy1 * sw + cx1]);
        sample = clamp(sample, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
        let inside = sx >= -0.5 && sx <= f32(sw) - 0.5
                  && sy >= -0.5 && sy <= f32(sh) - 0.5;
        sample.w = select(0.0, sample.w, inside);
        warp_dst[gid.y * dw + gid.x] = h4store(sample);
    }

    struct BlurParams {
        width: u32,
        height: u32,
        radius: i32,
    }

    @group(0) @binding(0) var<storage, read> blur_src: array<f32>;
    @group(0) @binding(1) var<storage, read_write> blur_dst: array<f32>;
    @group(0) @binding(2) var<storage, read> blur_weights: array<f32>;
    @group(0) @binding(3) var<uniform> blur_p: BlurParams;

    @compute @workgroup_size(16, 16)
    fn blur_h(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= blur_p.width || gid.y >= blur_p.height) { return; }
        let w = i32(blur_p.width);
        let row = i32(gid.y) * w;
        var acc = 0.0;
        for (var i = -blur_p.radius; i <= blur_p.radius; i++) {
            let xi = clamp(i32(gid.x) + i, 0, w - 1);
            acc += blur_src[row + xi] * blur_weights[i + blur_p.radius];
        }
        blur_dst[row + i32(gid.x)] = acc;
    }

    @compute @workgroup_size(16, 16)
    fn blur_v(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= blur_p.width || gid.y >= blur_p.height) { return; }
        let w = i32(blur_p.width);
        let h = i32(blur_p.height);
        var acc = 0.0;
        for (var i = -blur_p.radius; i <= blur_p.radius; i++) {
            let yi = clamp(i32(gid.y) + i, 0, h - 1);
            acc += blur_src[yi * w + i32(gid.x)] * blur_weights[i + blur_p.radius];
        }
        blur_dst[i32(gid.y) * w + i32(gid.x)] = acc;
    }

    // warp_bilinear shares the warp bindings.
    @compute @workgroup_size(16, 16)
    fn warp_bilinear(@builtin(global_invocation_id) gid: vec3u) {
        let dw = warp_p.dims.z;
        let dh = warp_p.dims.w;
        if (gid.x >= dw || gid.y >= dh) { return; }
        let sw = i32(warp_p.dims.x);
        let sh = i32(warp_p.dims.y);
        let v = vec3f(f32(gid.x), f32(gid.y), 1.0);
        let z = dot(warp_p.r2.xyz, v);
        let sx = dot(warp_p.r0.xyz, v) / z;
        let sy = dot(warp_p.r1.xyz, v) / z;
        let x0 = i32(floor(sx));
        let y0 = i32(floor(sy));
        let wx = sx - f32(x0);
        let wy = sy - f32(y0);
        let cx0 = clamp(x0, 0, sw - 1);
        let cx1 = clamp(x0 + 1, 0, sw - 1);
        let cy0 = clamp(y0, 0, sh - 1);
        let cy1 = clamp(y0 + 1, 0, sh - 1);
        let top = mix(h4load(warp_src[cy0 * sw + cx0]),
                      h4load(warp_src[cy0 * sw + cx1]), wx);
        let bot = mix(h4load(warp_src[cy1 * sw + cx0]),
                      h4load(warp_src[cy1 * sw + cx1]), wx);
        var sample = mix(top, bot, wy);
        let inside = sx >= -0.5 && sx <= f32(sw) - 0.5
                  && sy >= -0.5 && sy <= f32(sh) - 0.5;
        sample.w = select(0.0, sample.w, inside);
        warp_dst[gid.y * dw + gid.x] = h4store(sample);
    }

    const kLuma = vec3f(0.2126, 0.7152, 0.0722);

    struct Dims2 { w: u32, h: u32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read> ll_src: array<f32>;
    @group(0) @binding(1) var<storage, read_write> ll_out: array<f32>;
    @group(0) @binding(2) var<uniform> ll_p: Dims2;

    // (∇²)² of a float plane — the CPU's Filters.laplacianSquared. Input is
    // luminance already denoised by Options.focusPreSigma (the Laplacian's band
    // sits at Nyquist, where noise lives); squared because everything
    // downstream pools this as energy.
    @compute @workgroup_size(16, 16)
    fn plane_laplacian_sq(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= ll_p.w || gid.y >= ll_p.h) { return; }
        let w = i32(ll_p.w);
        let h = i32(ll_p.h);
        let x = i32(gid.x);
        let y = i32(gid.y);
        let xl = max(x - 1, 0);
        let xr = min(x + 1, w - 1);
        let yu = max(y - 1, 0);
        let yd = min(y + 1, h - 1);
        let v = ll_src[y * w + xl] + ll_src[y * w + xr] + ll_src[yu * w + x]
              + ll_src[yd * w + x] - 4.0 * ll_src[y * w + x];
        ll_out[y * w + x] = v * v;
    }

    struct ArgmaxParams { frameIdx: f32, count: u32, gain: f32, energyGain: f32 }

    @group(0) @binding(0) var<storage, read> am_energy: array<f32>;
    @group(0) @binding(1) var<storage, read> am_frame: array<Half4>;
    @group(0) @binding(2) var<storage, read_write> am_bestE: array<f32>;
    @group(0) @binding(3) var<storage, read_write> am_bestIdx: array<f32>;
    @group(0) @binding(4) var<storage, read_write> am_guide: array<f32>;
    @group(0) @binding(5) var<uniform> am_p: ArgmaxParams;

    @compute @workgroup_size(256)
    fn argmax_update(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= am_p.count) { return; }
        // energyGain is gain²: the measure is a squared Laplacian, so quadratic
        // in the frame's gain, while the guide luminance below is linear in it.
        let f = h4load(am_frame[gid.x]);
        let e = am_energy[gid.x] * f.w * am_p.energyGain;
        let wins = e > am_bestE[gid.x];
        if (wins) {
            am_bestE[gid.x] = e;
            am_bestIdx[gid.x] = am_p.frameIdx;
        }
        if (wins || am_p.frameIdx == 0.0) {
            am_guide[gid.x] = dot(f.rgb, kLuma) * am_p.gain;
        }
    }

    struct TentParams { gain: vec4f, index: f32, radius: f32, count: u32, pad: u32 }

    @group(0) @binding(0) var<storage, read> ta_frame: array<Half4>;
    @group(0) @binding(1) var<storage, read> ta_depth: array<f32>;
    // The accumulator stays f32: it is a running sum over the whole stack, not
    // a [0,1] pixel — same reason the MSL kernel declares it float4.
    @group(0) @binding(2) var<storage, read_write> ta_accum: array<vec4f>;
    @group(0) @binding(3) var<storage, read_write> ta_wsum: array<f32>;
    @group(0) @binding(4) var<uniform> ta_p: TentParams;

    @compute @workgroup_size(256)
    fn tent_accumulate(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= ta_p.count) { return; }
        let s = h4load(ta_frame[gid.x]);
        if (s.w <= 0.0) { return; }
        let tent = max(1.0 - abs(ta_p.index - ta_depth[gid.x]) / ta_p.radius, 0.0);
        let w = (tent + 1e-6) * s.w;
        ta_accum[gid.x] += vec4f(s.xyz * (w * ta_p.gain.xyz), s.w * w);
        ta_wsum[gid.x] += w;
    }

    struct PlanePreviewParams { srcW: u32, srcH: u32, dstW: u32, dstH: u32, scale: f32, bias: f32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read> pp_plane: array<f32>;
    @group(0) @binding(1) var<storage, read_write> pp_out: array<Half4>;
    @group(0) @binding(2) var<uniform> pp_p: PlanePreviewParams;

    @compute @workgroup_size(16, 16)
    fn plane_preview(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pp_p.dstW || gid.y >= pp_p.dstH) { return; }
        let sx = min(gid.x * pp_p.srcW / pp_p.dstW, pp_p.srcW - 1u);
        let sy = min(gid.y * pp_p.srcH / pp_p.dstH, pp_p.srcH - 1u);
        let v = pp_p.bias + pp_plane[sy * pp_p.srcW + sx] * pp_p.scale;
        pp_out[gid.y * pp_p.dstW + gid.x] = h4store(vec4f(v, v, v, 1.0));
    }

    struct BoxDownParams { srcW: u32, srcH: u32, dstW: u32, dstH: u32, factor: u32, pad0: u32, pad1: u32, pad2: u32 }

    @group(0) @binding(0) var<storage, read> bd_src: array<f32>;
    @group(0) @binding(1) var<storage, read_write> bd_dst: array<f32>;
    @group(0) @binding(2) var<uniform> bd_p: BoxDownParams;

    @compute @workgroup_size(16, 16)
    fn box_downsample(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= bd_p.dstW || gid.y >= bd_p.dstH) { return; }
        let x0 = gid.x * bd_p.factor;
        let y0 = gid.y * bd_p.factor;
        let x1 = min(x0 + bd_p.factor, bd_p.srcW);
        let y1 = min(y0 + bd_p.factor, bd_p.srcH);
        var acc = 0.0;
        for (var y = y0; y < y1; y++) {
            for (var x = x0; x < x1; x++) {
                acc += bd_src[y * bd_p.srcW + x];
            }
        }
        bd_dst[gid.y * bd_p.dstW + gid.x] = acc / f32((x1 - x0) * (y1 - y0));
    }

    struct PlaneUpParams { srcW: u32, srcH: u32, dstW: u32, dstH: u32 }

    @group(0) @binding(0) var<storage, read> plu_src: array<f32>;
    @group(0) @binding(1) var<storage, read_write> plu_dst: array<f32>;
    @group(0) @binding(2) var<uniform> plu_p: PlaneUpParams;

    // Bilinear plane upsample — must match Filters.resizePlaneBilinear
    // (center-aligned sampling, clamp-to-edge, a*(1-w)+b*w expression order,
    // NOT mix(): the CPU reference writes the two-product form).
    @compute @workgroup_size(16, 16)
    fn plane_upsample(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= plu_p.dstW || gid.y >= plu_p.dstH) { return; }
        let sw = i32(plu_p.srcW);
        let sh = i32(plu_p.srcH);
        let sx = f32(plu_p.srcW) / f32(plu_p.dstW);
        let sy = f32(plu_p.srcH) / f32(plu_p.dstH);
        let fy = (f32(gid.y) + 0.5) * sy - 0.5;
        let y0 = i32(floor(fy));
        let wy = fy - f32(y0);
        let cy0 = clamp(y0, 0, sh - 1);
        let cy1 = clamp(y0 + 1, 0, sh - 1);
        let fx = (f32(gid.x) + 0.5) * sx - 0.5;
        let x0 = i32(floor(fx));
        let wx = fx - f32(x0);
        let cx0 = clamp(x0, 0, sw - 1);
        let cx1 = clamp(x0 + 1, 0, sw - 1);
        let top = plu_src[cy0 * sw + cx0] * (1.0 - wx) + plu_src[cy0 * sw + cx1] * wx;
        let bot = plu_src[cy1 * sw + cx0] * (1.0 - wx) + plu_src[cy1 * sw + cx1] * wx;
        plu_dst[gid.y * plu_p.dstW + gid.x] = top * (1.0 - wy) + bot * wy;
    }

    struct Count1 { count: u32, pad0: u32, pad1: u32, pad2: u32 }

    @group(0) @binding(0) var<storage, read> lp_img: array<Half4>;
    @group(0) @binding(1) var<storage, read_write> lp_out: array<f32>;
    @group(0) @binding(2) var<uniform> lp_p: Count1;

    @compute @workgroup_size(256)
    fn luma_plane(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= lp_p.count) { return; }
        let p = h4load(lp_img[gid.x]);
        lp_out[gid.x] = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z;
    }

    struct PreviewParams { srcW: u32, srcH: u32, dstW: u32, dstH: u32 }

    @group(0) @binding(0) var<storage, read> pv_accum: array<vec4f>;
    @group(0) @binding(1) var<storage, read> pv_wsum: array<f32>;
    @group(0) @binding(2) var<storage, read_write> pv_out: array<Half4>;
    @group(0) @binding(3) var<uniform> pv_p: PreviewParams;

    @compute @workgroup_size(16, 16)
    fn progressive_preview(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pv_p.dstW || gid.y >= pv_p.dstH) { return; }
        let sx = min(gid.x * pv_p.srcW / pv_p.dstW, pv_p.srcW - 1u);
        let sy = min(gid.y * pv_p.srcH / pv_p.dstH, pv_p.srcH - 1u);
        let si = sy * pv_p.srcW + sx;
        let w = pv_wsum[si];
        var v = select(vec4f(0.0), pv_accum[si] / w, w > 0.01);
        v.w = 1.0;
        pv_out[gid.y * pv_p.dstW + gid.x] = h4store(v);
    }

    @group(0) @binding(0) var<storage, read> no_accum: array<vec4f>;
    @group(0) @binding(1) var<storage, read> no_wsum: array<f32>;
    @group(0) @binding(2) var<storage, read_write> no_out: array<Half4>;
    @group(0) @binding(3) var<uniform> no_p: Count1;

    @compute @workgroup_size(256)
    fn normalize_out(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= no_p.count) { return; }
        let w = no_wsum[gid.x];
        var v = select(vec4f(0.0), no_accum[gid.x] / w, w > 1e-7);
        v.w = 1.0;
        no_out[gid.x] = h4store(v);
    }

    struct ConfidenceParams {
        width: u32, concW: u32, concH: u32, factor: u32,
        halfFloor: f32, conc2: f32, count: u32, pad: u32,
    }

    @group(0) @binding(0) var<storage, read> cm_energy: array<f32>;
    @group(0) @binding(1) var<storage, read_write> cm_conf: array<f32>;
    @group(0) @binding(2) var<storage, read> cm_conc: array<f32>;
    @group(0) @binding(3) var<uniform> cm_p: ConfidenceParams;

    @compute @workgroup_size(256)
    fn confidence_map(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= cm_p.count) { return; }
        let es = max(cm_energy[gid.x] - cm_p.halfFloor, 0.0);
        let e2 = es * es;
        var c = e2 / (e2 + cm_p.halfFloor * cm_p.halfFloor);
        if (cm_p.conc2 > 0.0) {
            let invF = 1.0 / f32(cm_p.factor);
            let x = gid.x % cm_p.width;
            let y = gid.x / cm_p.width;
            let gx = clamp((f32(x) + 0.5) * invF - 0.5, 0.0, f32(cm_p.concW - 1u));
            let gy = clamp((f32(y) + 0.5) * invF - 0.5, 0.0, f32(cm_p.concH - 1u));
            let x0 = min(i32(gx), i32(cm_p.concW) - 1);
            let x1 = min(x0 + 1, i32(cm_p.concW) - 1);
            let y0 = min(i32(gy), i32(cm_p.concH) - 1);
            let y1 = min(y0 + 1, i32(cm_p.concH) - 1);
            let fx = gx - f32(x0);
            let fy = gy - f32(y0);
            let w = i32(cm_p.concW);
            let k = (cm_conc[y0 * w + x0] * (1.0 - fx)
                     + cm_conc[y0 * w + x1] * fx) * (1.0 - fy)
                  + (cm_conc[y1 * w + x0] * (1.0 - fx)
                     + cm_conc[y1 * w + x1] * fx) * fy;
            let k2 = k * k;
            c *= k2 / (k2 + cm_p.conc2);
        }
        cm_conf[gid.x] = c;
    }

    struct MedianParams {
        width: u32, height: u32, radius: i32, step: i32,
        bins: u32, consensusWindow: i32, pad0: u32, pad1: u32,
    }

    @group(0) @binding(0) var<storage, read> wm_values: array<f32>;
    @group(0) @binding(1) var<storage, read> wm_weights: array<f32>;
    @group(0) @binding(2) var<storage, read_write> wm_out: array<f32>;
    @group(0) @binding(3) var<storage, read_write> wm_consensus: array<f32>;
    @group(0) @binding(4) var<uniform> wm_p: MedianParams;

    @compute @workgroup_size(16, 16)
    fn weighted_median(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= wm_p.width || gid.y >= wm_p.height) { return; }
        let w = i32(wm_p.width);
        let h = i32(wm_p.height);
        let x = i32(gid.x);
        let y = i32(gid.y);
        var total = 0.0;
        for (var dy = -wm_p.radius; dy <= wm_p.radius; dy += wm_p.step) {
            let yy = clamp(y + dy, 0, h - 1);
            for (var dx = -wm_p.radius; dx <= wm_p.radius; dx += wm_p.step) {
                let xx = clamp(x + dx, 0, w - 1);
                let wt = wm_weights[yy * w + xx];
                if (wt > 1e-3) { total += wt; }
            }
        }
        let i = y * w + x;
        if (total <= 1e-3) {
            wm_out[i] = wm_values[i];
            wm_consensus[i] = 0.0;
            return;
        }
        let halfTotal = total * 0.5;
        var lo = 0u;
        var hi = wm_p.bins - 1u;
        while (lo < hi) {
            let mid = (lo + hi) / 2u;
            var acc = 0.0;
            for (var dy = -wm_p.radius; dy <= wm_p.radius; dy += wm_p.step) {
                let yy = clamp(y + dy, 0, h - 1);
                for (var dx = -wm_p.radius; dx <= wm_p.radius; dx += wm_p.step) {
                    let xx = clamp(x + dx, 0, w - 1);
                    let j = yy * w + xx;
                    let wt = wm_weights[j];
                    if (wt > 1e-3) {
                        let b = u32(clamp(i32(wm_values[j] + 0.5), 0, i32(wm_p.bins) - 1));
                        if (b <= mid) { acc += wt; }
                    }
                }
            }
            if (acc >= halfTotal) { hi = mid; } else { lo = mid + 1u; }
        }
        var below = 0.0;
        var at = 0.0;
        for (var dy = -wm_p.radius; dy <= wm_p.radius; dy += wm_p.step) {
            let yy = clamp(y + dy, 0, h - 1);
            for (var dx = -wm_p.radius; dx <= wm_p.radius; dx += wm_p.step) {
                let xx = clamp(x + dx, 0, w - 1);
                let j = yy * w + xx;
                let wt = wm_weights[j];
                if (wt > 1e-3) {
                    let b = u32(clamp(i32(wm_values[j] + 0.5), 0, i32(wm_p.bins) - 1));
                    if (b < lo) { below += wt; }
                    else if (b == lo) { at += wt; }
                }
            }
        }
        let frac = clamp((halfTotal - below) / max(at, 1e-9), 0.0, 1.0);
        wm_out[i] = f32(lo) - 0.5 + frac;
        let bLo = max(i32(lo) - wm_p.consensusWindow, 0);
        let bHi = min(i32(lo) + wm_p.consensusWindow, i32(wm_p.bins) - 1);
        var agree = 0.0;
        for (var dy = -wm_p.radius; dy <= wm_p.radius; dy += wm_p.step) {
            let yy = clamp(y + dy, 0, h - 1);
            for (var dx = -wm_p.radius; dx <= wm_p.radius; dx += wm_p.step) {
                let xx = clamp(x + dx, 0, w - 1);
                let j = yy * w + xx;
                let wt = wm_weights[j];
                if (wt > 1e-3) {
                    let b = clamp(i32(wm_values[j] + 0.5), 0, i32(wm_p.bins) - 1);
                    if (b >= bLo && b <= bHi) { agree += wt; }
                }
            }
        }
        wm_consensus[i] = agree / total;
    }

    struct GuidedApplyParams {
        width: u32, height: u32, gridW: u32, gridH: u32,
        invFactor: f32, guideScale: f32, maxIndex: f32, residualW2: f32,
        hasSpill: u32, pad0: u32, pad1: u32, pad2: u32,
    }

    // Spill buffers are statically referenced, so callers without spill data
    // bind a 1-float dummy to each and set hasSpill = 0.
    @group(0) @binding(0) var<storage, read> ga_aBar: array<f32>;
    @group(0) @binding(1) var<storage, read> ga_bBar: array<f32>;
    @group(0) @binding(2) var<storage, read> ga_guide: array<f32>;
    @group(0) @binding(3) var<storage, read> ga_conf: array<f32>;
    @group(0) @binding(4) var<storage, read> ga_depthMed: array<f32>;
    @group(0) @binding(5) var<storage, read_write> ga_out: array<f32>;
    @group(0) @binding(6) var<storage, read> ga_consensus: array<f32>;
    @group(0) @binding(7) var<storage, read> ga_spillD: array<f32>;
    @group(0) @binding(8) var<storage, read> ga_spillS: array<f32>;
    @group(0) @binding(9) var<uniform> ga_p: GuidedApplyParams;

    @compute @workgroup_size(16, 16)
    fn guided_apply_blend(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= ga_p.width || gid.y >= ga_p.height) { return; }
        let gw = i32(ga_p.gridW);
        let gh = i32(ga_p.gridH);
        let gy = clamp((f32(gid.y) + 0.5) * ga_p.invFactor - 0.5, 0.0, f32(gh - 1));
        let y0 = min(i32(gy), gh - 1);
        let y1 = min(y0 + 1, gh - 1);
        let fy = gy - f32(y0);
        let gx = clamp((f32(gid.x) + 0.5) * ga_p.invFactor - 0.5, 0.0, f32(gw - 1));
        let x0 = min(i32(gx), gw - 1);
        let x1 = min(x0 + 1, gw - 1);
        let fx = gx - f32(x0);
        let i00 = y0 * gw + x0;
        let i01 = y0 * gw + x1;
        let i10 = y1 * gw + x0;
        let i11 = y1 * gw + x1;
        let aS = (ga_aBar[i00] * (1.0 - fx) + ga_aBar[i01] * fx) * (1.0 - fy)
               + (ga_aBar[i10] * (1.0 - fx) + ga_aBar[i11] * fx) * fy;
        let bS = (ga_bBar[i00] * (1.0 - fx) + ga_bBar[i01] * fx) * (1.0 - fy)
               + (ga_bBar[i10] * (1.0 - fx) + ga_bBar[i11] * fx) * fy;
        let i = gid.y * ga_p.width + gid.x;
        var dReg = aS * (ga_p.guideScale * ga_guide[i]) + bS;
        let agreement = ga_consensus[i];
        var cf = max(ga_conf[i], agreement * agreement);
        if (ga_p.hasSpill != 0u) {
            let sSm = (ga_spillS[i00] * (1.0 - fx) + ga_spillS[i01] * fx) * (1.0 - fy)
                    + (ga_spillS[i10] * (1.0 - fx) + ga_spillS[i11] * fx) * fy;
            let dSm = (ga_spillD[i00] * (1.0 - fx) + ga_spillD[i01] * fx) * (1.0 - fy)
                    + (ga_spillD[i10] * (1.0 - fx) + ga_spillD[i11] * fx) * fy;
            cf *= 1.0 - sSm;
            let pull = sSm * (1.0 - cf);
            dReg += pull * (dSm - dReg);
        }
        let r = dReg - ga_depthMed[i];
        let t = r * r / (r * r + ga_p.residualW2);
        let s = clamp((cf - 0.35) / 0.35, 0.0, 1.0);
        let gate = s * s * (3.0 - 2.0 * s);
        let cb = cf + (1.0 - cf) * (t * gate);
        ga_out[i] = clamp(cb * ga_depthMed[i] + (1.0 - cb) * dReg, 0.0, ga_p.maxIndex);
    }

    struct ClampParams { maxV: f32, count: u32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read_write> cp_plane: array<f32>;
    @group(0) @binding(1) var<uniform> cp_p: ClampParams;

    @compute @workgroup_size(256)
    fn clamp_plane(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= cp_p.count) { return; }
        cp_plane[gid.x] = clamp(cp_plane[gid.x], 0.0, cp_p.maxV);
    }

    // ---- Laplacian pyramid fusion (PMax) ----

    const kPyr5 = array<f32, 5>(1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16);

    @group(0) @binding(0) var<storage, read> pbh_src: array<Half4>;
    @group(0) @binding(1) var<storage, read_write> pbh_dst: array<vec4f>;
    @group(0) @binding(2) var<uniform> pbh_p: Dims2;

    // H pass writes FLOAT4. The separable blur's intermediate stays f32
    // exactly as the CPU's `fusedDownsample` keeps its `rows` scratch in f32,
    // and as the MSL kernel does: narrowing between H and V puts a second
    // quantization into every pyramid level, which cost ~40 dB of CPU↔GPU
    // parity when it was measured on the Metal path.
    @compute @workgroup_size(16, 16)
    fn pyr_blur5_h(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pbh_p.w || gid.y >= pbh_p.h) { return; }
        let w = i32(pbh_p.w);
        let row = i32(gid.y) * w;
        var acc = vec4f(0.0);
        for (var i = -2; i <= 2; i++) {
            let xi = clamp(i32(gid.x) + i, 0, w - 1);
            acc += h4load(pbh_src[row + xi]) * kPyr5[i + 2];
        }
        pbh_dst[row + i32(gid.x)] = acc;
    }

    @group(0) @binding(0) var<storage, read> pbv_src: array<vec4f>;
    @group(0) @binding(1) var<storage, read_write> pbv_dst: array<Half4>;
    @group(0) @binding(2) var<uniform> pbv_p: Dims2;

    // V pass consumes the f32 H result and narrows once, on store.
    @compute @workgroup_size(16, 16)
    fn pyr_blur5_v(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pbv_p.w || gid.y >= pbv_p.h) { return; }
        let w = i32(pbv_p.w);
        let h = i32(pbv_p.h);
        var acc = vec4f(0.0);
        for (var i = -2; i <= 2; i++) {
            let yi = clamp(i32(gid.y) + i, 0, h - 1);
            acc += pbv_src[yi * w + i32(gid.x)] * kPyr5[i + 2];
        }
        pbv_dst[i32(gid.y) * w + i32(gid.x)] = h4store(acc);
    }

    @group(0) @binding(0) var<storage, read> pr_src: array<Half4>;
    // Upsample writes FLOAT4, and every `up` consumer below reads f32. The
    // band is `fine - up`, a difference of two nearly-equal Gaussians:
    // rounding `up` to f16 first throws away most of the band's significant
    // bits — classic catastrophic cancellation. The CPU path never
    // materializes it at all (`upsampleAt` returns f32 inline), and storing it
    // as f16 cost ~40 dB of PMax CPU↔GPU parity on the Metal path.
    @group(0) @binding(1) var<storage, read_write> pr_dst: array<vec4f>;
    @group(0) @binding(2) var<uniform> pr_p: PreviewParams;

    // Decimation's own destination is half: it picks a sample, it doesn't
    // compute one, so this is storage-to-storage and stays exact.
    @group(0) @binding(1) var<storage, read_write> prd_dst: array<Half4>;

    @compute @workgroup_size(16, 16)
    fn pyr_decimate(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pr_p.dstW || gid.y >= pr_p.dstH) { return; }
        let sx = min(gid.x * 2u, pr_p.srcW - 1u);
        let sy = min(gid.y * 2u, pr_p.srcH - 1u);
        prd_dst[gid.y * pr_p.dstW + gid.x] = pr_src[sy * pr_p.srcW + sx];
    }

    fn pyr_bilinear_at(sw: i32, sh: i32, gid: vec3u, dstW: u32, dstH: u32) -> vec4f {
        let fxf = (f32(gid.x) + 0.5) * f32(sw) / f32(dstW) - 0.5;
        let fyf = (f32(gid.y) + 0.5) * f32(sh) / f32(dstH) - 0.5;
        let x0 = i32(floor(fxf));
        let y0 = i32(floor(fyf));
        let wx = fxf - f32(x0);
        let wy = fyf - f32(y0);
        let cx0 = clamp(x0, 0, sw - 1);
        let cx1 = clamp(x0 + 1, 0, sw - 1);
        let cy0 = clamp(y0, 0, sh - 1);
        let cy1 = clamp(y0 + 1, 0, sh - 1);
        let top = mix(h4load(pr_src[cy0 * sw + cx0]),
                      h4load(pr_src[cy0 * sw + cx1]), wx);
        let bot = mix(h4load(pr_src[cy1 * sw + cx0]),
                      h4load(pr_src[cy1 * sw + cx1]), wx);
        return mix(top, bot, wy);
    }

    @compute @workgroup_size(16, 16)
    fn pyr_upsample(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pr_p.dstW || gid.y >= pr_p.dstH) { return; }
        pr_dst[gid.y * pr_p.dstW + gid.x] =
            pyr_bilinear_at(i32(pr_p.srcW), i32(pr_p.srcH), gid, pr_p.dstW, pr_p.dstH);
    }

    // Burt-Adelson expand of the corner-aligned pyramid grid — the exact
    // reconstruction low-pass matched to pyr_decimate's grid, mirroring
    // CPUWorkspace.upsampleBurtAt and the MSL kernel of the same name: even
    // fine samples read coarse m-1/m/m+1 at (1/8, 6/8, 1/8), odd read m/m+1
    // at (1/2, 1/2). Band computation and collapse switch together.
    fn pyr_burt_taps(c: u32, limit: i32) -> vec3i {
        let m = i32(c >> 1u);
        if ((c & 1u) == 0u) {
            return vec3i(clamp(m - 1, 0, limit - 1), clamp(m, 0, limit - 1),
                         clamp(m + 1, 0, limit - 1));
        }
        return vec3i(clamp(m, 0, limit - 1), clamp(m + 1, 0, limit - 1), 0);
    }

    fn pyr_burt_at(sw: i32, sh: i32, gid: vec3u) -> vec4f {
        let tx = pyr_burt_taps(gid.x, sw);
        let ty = pyr_burt_taps(gid.y, sh);
        var wx = vec3f(0.125, 0.75, 0.125);
        if ((gid.x & 1u) != 0u) { wx = vec3f(0.5, 0.5, 0.0); }
        var wy = vec3f(0.125, 0.75, 0.125);
        if ((gid.y & 1u) != 0u) { wy = vec3f(0.5, 0.5, 0.0); }
        let r0 = h4load(pr_src[ty.x * sw + tx.x]) * wx.x
               + h4load(pr_src[ty.x * sw + tx.y]) * wx.y
               + h4load(pr_src[ty.x * sw + tx.z]) * wx.z;
        let r1 = h4load(pr_src[ty.y * sw + tx.x]) * wx.x
               + h4load(pr_src[ty.y * sw + tx.y]) * wx.y
               + h4load(pr_src[ty.y * sw + tx.z]) * wx.z;
        let r2 = h4load(pr_src[ty.z * sw + tx.x]) * wx.x
               + h4load(pr_src[ty.z * sw + tx.y]) * wx.y
               + h4load(pr_src[ty.z * sw + tx.z]) * wx.z;
        return r0 * wy.x + r1 * wy.y + r2 * wy.z;
    }

    @compute @workgroup_size(16, 16)
    fn pyr_upsample_burt(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pr_p.dstW || gid.y >= pr_p.dstH) { return; }
        pr_dst[gid.y * pr_p.dstW + gid.x] =
            pyr_burt_at(i32(pr_p.srcW), i32(pr_p.srcH), gid);
    }

    // Collapse step: dst = band + upsample(coarser), all three half — the sum
    // is a reconstructed image, not a band difference, so it carries no
    // cancellation and narrows on store like every other pixel.
    @group(0) @binding(0) var<storage, read> pu_src: array<Half4>;
    @group(0) @binding(1) var<storage, read> pu_band: array<Half4>;
    @group(0) @binding(2) var<storage, read_write> pu_dst: array<Half4>;
    @group(0) @binding(3) var<uniform> pu_p: PreviewParams;

    fn pu_bilinear_at(sw: i32, sh: i32, gid: vec3u, dstW: u32, dstH: u32) -> vec4f {
        let fxf = (f32(gid.x) + 0.5) * f32(sw) / f32(dstW) - 0.5;
        let fyf = (f32(gid.y) + 0.5) * f32(sh) / f32(dstH) - 0.5;
        let x0 = i32(floor(fxf));
        let y0 = i32(floor(fyf));
        let wx = fxf - f32(x0);
        let wy = fyf - f32(y0);
        let cx0 = clamp(x0, 0, sw - 1);
        let cx1 = clamp(x0 + 1, 0, sw - 1);
        let cy0 = clamp(y0, 0, sh - 1);
        let cy1 = clamp(y0 + 1, 0, sh - 1);
        let top = mix(h4load(pu_src[cy0 * sw + cx0]),
                      h4load(pu_src[cy0 * sw + cx1]), wx);
        let bot = mix(h4load(pu_src[cy1 * sw + cx0]),
                      h4load(pu_src[cy1 * sw + cx1]), wx);
        return mix(top, bot, wy);
    }

    @compute @workgroup_size(16, 16)
    fn pyr_upsample_add(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pu_p.dstW || gid.y >= pu_p.dstH) { return; }
        let i = gid.y * pu_p.dstW + gid.x;
        pu_dst[i] = h4store(h4load(pu_band[i])
            + pu_bilinear_at(i32(pu_p.srcW), i32(pu_p.srcH), gid, pu_p.dstW, pu_p.dstH));
    }

    fn pu_burt_at(sw: i32, sh: i32, gid: vec3u) -> vec4f {
        let tx = pyr_burt_taps(gid.x, sw);
        let ty = pyr_burt_taps(gid.y, sh);
        var wx = vec3f(0.125, 0.75, 0.125);
        if ((gid.x & 1u) != 0u) { wx = vec3f(0.5, 0.5, 0.0); }
        var wy = vec3f(0.125, 0.75, 0.125);
        if ((gid.y & 1u) != 0u) { wy = vec3f(0.5, 0.5, 0.0); }
        let r0 = h4load(pu_src[ty.x * sw + tx.x]) * wx.x
               + h4load(pu_src[ty.x * sw + tx.y]) * wx.y
               + h4load(pu_src[ty.x * sw + tx.z]) * wx.z;
        let r1 = h4load(pu_src[ty.y * sw + tx.x]) * wx.x
               + h4load(pu_src[ty.y * sw + tx.y]) * wx.y
               + h4load(pu_src[ty.y * sw + tx.z]) * wx.z;
        let r2 = h4load(pu_src[ty.z * sw + tx.x]) * wx.x
               + h4load(pu_src[ty.z * sw + tx.y]) * wx.y
               + h4load(pu_src[ty.z * sw + tx.z]) * wx.z;
        return r0 * wy.x + r1 * wy.y + r2 * wy.z;
    }

    @compute @workgroup_size(16, 16)
    fn pyr_upsample_add_burt(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pu_p.dstW || gid.y >= pu_p.dstH) { return; }
        let i = gid.y * pu_p.dstW + gid.x;
        pu_dst[i] = h4store(h4load(pu_band[i])
            + pu_burt_at(i32(pu_p.srcW), i32(pu_p.srcH), gid));
    }

    @group(0) @binding(0) var<storage, read> ps_fine: array<Half4>;
    @group(0) @binding(1) var<storage, read> ps_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> ps_fused: array<Half4>;
    @group(0) @binding(3) var<storage, read_write> ps_bestE: array<f32>;
    @group(0) @binding(4) var<uniform> ps_p: Count1;

    @compute @workgroup_size(256)
    fn pyr_select(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= ps_p.count) { return; }
        let band = h4load(ps_fine[gid.x]) - ps_up[gid.x];
        let e = abs(band.x) + abs(band.y) + abs(band.z);
        if (e > ps_bestE[gid.x]) {
            ps_bestE[gid.x] = e;
            ps_fused[gid.x] = h4store(band);
        }
    }

    @group(0) @binding(0) var<storage, read> pe_fine: array<Half4>;
    @group(0) @binding(1) var<storage, read> pe_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> pe_e: array<f32>;
    @group(0) @binding(3) var<uniform> pe_p: Count1;

    @compute @workgroup_size(256)
    fn pyr_band_energy(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pe_p.count) { return; }
        let band = h4load(pe_fine[gid.x]) - pe_up[gid.x];
        pe_e[gid.x] = abs(band.x) + abs(band.y) + abs(band.z);
    }

    @group(0) @binding(0) var<storage, read> pss_fine: array<Half4>;
    @group(0) @binding(1) var<storage, read> pss_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> pss_fused: array<Half4>;
    @group(0) @binding(3) var<storage, read_write> pss_bestE: array<f32>;
    @group(0) @binding(4) var<storage, read> pss_energy: array<f32>;
    @group(0) @binding(5) var<uniform> pss_p: Count1;

    @compute @workgroup_size(256)
    fn pyr_select_smoothed(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pss_p.count) { return; }
        let e = pss_energy[gid.x];
        if (e > pss_bestE[gid.x]) {
            pss_bestE[gid.x] = e;
            pss_fused[gid.x] = h4store(h4load(pss_fine[gid.x]) - pss_up[gid.x]);
        }
    }

    // The base accumulator sums one Gaussian per frame and stays f32 — a sum
    // over tens of frames leaves [0,1], where f16's steps stop being fine.
    @group(0) @binding(0) var<storage, read_write> pa_dst: array<vec4f>;
    @group(0) @binding(1) var<storage, read> pa_src: array<Half4>;
    @group(0) @binding(2) var<uniform> pa_p: Count1;

    @compute @workgroup_size(256)
    fn pyr_add4(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pa_p.count) { return; }
        pa_dst[gid.x] += h4load(pa_src[gid.x]);
    }

    struct ScaleParams { s: f32, count: u32, pad0: u32, pad1: u32 }

    // Divides the f32 base accumulator by the frame count and lands it in the
    // half buffer the collapse chain runs on, in one pass — hence a separate
    // source, not a scale in place.
    @group(0) @binding(0) var<storage, read_write> psc_dst: array<Half4>;
    @group(0) @binding(1) var<storage, read> psc_src: array<vec4f>;
    @group(0) @binding(2) var<uniform> psc_p: ScaleParams;

    @compute @workgroup_size(256)
    fn pyr_scale4(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= psc_p.count) { return; }
        psc_dst[gid.x] = h4store(psc_src[gid.x] * psc_p.s);
    }

    struct FillParams { v: f32, count: u32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read_write> pf_dst: array<f32>;
    @group(0) @binding(1) var<uniform> pf_p: FillParams;

    @compute @workgroup_size(256)
    fn pyr_fill(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pf_p.count) { return; }
        pf_dst[gid.x] = pf_p.v;
    }

    // ---- Focus-gated coarse selection (--pmax-debloom) ----
    // Mirrors PyramidFusion.CPUWorkspace's selectStreamingFocusGated /
    // darkest-base / merge and the MSL kernels of the same name.

    struct PyrFocusParams { count: u32, threshold: f32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read> pfg_fine: array<Half4>;
    @group(0) @binding(1) var<storage, read> pfg_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read> pfg_focus: array<f32>;
    @group(0) @binding(3) var<storage, read_write> pfg_fused: array<Half4>;
    @group(0) @binding(4) var<storage, read_write> pfg_bestE: array<f32>;
    @group(0) @binding(5) var<storage, read_write> pfg_trackB: array<Half4>;
    @group(0) @binding(6) var<storage, read_write> pfg_bestDarkLum: array<f32>;
    @group(0) @binding(7) var<storage, read_write> pfg_trackBright: array<Half4>;
    @group(0) @binding(8) var<storage, read_write> pfg_bestBrightLum: array<f32>;
    @group(0) @binding(9) var<storage, read_write> pfg_hasFocus: array<f32>;
    @group(0) @binding(10) var<uniform> pfg_p: PyrFocusParams;

    // Two-track select: track A (max |RGB| energy) where the focus map exceeds
    // the threshold; track B keeps BOTH unfocused extremes (darkest and
    // brightest Gaussian luminance) so the merge can pick per cell whichever
    // lands closer to the clean field. bestE starts at -1, bestDarkLum at
    // +inf, bestBrightLum at -1.
    @compute @workgroup_size(256)
    fn pyr_select_focus_gated(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pfg_p.count) { return; }
        let f = h4load(pfg_fine[gid.x]);
        let band = f - pfg_up[gid.x];
        if (pfg_focus[gid.x] > pfg_p.threshold) {
            let e = abs(band.x) + abs(band.y) + abs(band.z);
            if (e > pfg_bestE[gid.x]) {
                pfg_bestE[gid.x] = e;
                pfg_hasFocus[gid.x] = 1.0;
                pfg_fused[gid.x] = h4store(band);
            }
        } else {
            let lum = 0.2126 * f.x + 0.7152 * f.y + 0.0722 * f.z;
            if (lum < pfg_bestDarkLum[gid.x]) {
                pfg_bestDarkLum[gid.x] = lum;
                pfg_trackB[gid.x] = h4store(band);
            }
            if (lum > pfg_bestBrightLum[gid.x]) {
                pfg_bestBrightLum[gid.x] = lum;
                pfg_trackBright[gid.x] = h4store(band);
            }
        }
    }

    @group(0) @binding(0) var<storage, read> pfs_fine: array<Half4>;
    @group(0) @binding(1) var<storage, read> pfs_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read> pfs_focus: array<f32>;
    @group(0) @binding(3) var<storage, read_write> pfs_fused: array<Half4>;
    @group(0) @binding(4) var<storage, read_write> pfs_bestE: array<f32>;
    @group(0) @binding(5) var<storage, read_write> pfs_trackB: array<Half4>;
    @group(0) @binding(6) var<storage, read_write> pfs_bestDarkLum: array<f32>;
    @group(0) @binding(7) var<storage, read_write> pfs_trackBright: array<Half4>;
    @group(0) @binding(8) var<storage, read_write> pfs_bestBrightLum: array<f32>;
    @group(0) @binding(9) var<storage, read_write> pfs_hasFocus: array<f32>;
    @group(0) @binding(10) var<storage, read> pfs_energy: array<f32>;
    @group(0) @binding(11) var<uniform> pfs_p: PyrFocusParams;

    // pyr_select_focus_gated with track A's energy read from a pre-smoothed
    // plane (the smoothed-selection port of selectSmoothedFocusGated).
    // Tracks B/bright pick by Gaussian luminance, which no smoothing
    // touches; track C runs separately via pyr_select_smoothed.
    @compute @workgroup_size(256)
    fn pyr_select_focus_gated_smoothed(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pfs_p.count) { return; }
        let f = h4load(pfs_fine[gid.x]);
        let band = f - pfs_up[gid.x];
        if (pfs_focus[gid.x] > pfs_p.threshold) {
            let e = pfs_energy[gid.x];
            if (e > pfs_bestE[gid.x]) {
                pfs_bestE[gid.x] = e;
                pfs_hasFocus[gid.x] = 1.0;
                pfs_fused[gid.x] = h4store(band);
            }
        } else {
            let lum = 0.2126 * f.x + 0.7152 * f.y + 0.0722 * f.z;
            if (lum < pfs_bestDarkLum[gid.x]) {
                pfs_bestDarkLum[gid.x] = lum;
                pfs_trackB[gid.x] = h4store(band);
            }
            if (lum > pfs_bestBrightLum[gid.x]) {
                pfs_bestBrightLum[gid.x] = lum;
                pfs_trackBright[gid.x] = h4store(band);
            }
        }
    }

    struct PyrEnvParams { srcW: u32, srcH: u32, cell: u32, gw: u32, gh: u32, pad0: u32, pad1: u32, pad2: u32 }

    @group(0) @binding(0) var<storage, read> pep_fine: array<Half4>;
    @group(0) @binding(1) var<storage, read> pep_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> pep_envMax: array<f32>;
    @group(0) @binding(3) var<storage, read_write> pep_envMin: array<f32>;
    @group(0) @binding(4) var<uniform> pep_p: PyrEnvParams;

    // Source-envelope accumulation (see PyramidFusion.applyEnvelopeClamp):
    // per envelope cell, the mean SQUARED band energy of this frame's level-0
    // band, folded into the running per-cell max (the clamp's bound) and min
    // (the texture veto's sweep statistic). One thread per cell; edge cells
    // average their actual pixel count, mirroring poolBandEnergy.
    @compute @workgroup_size(16, 16)
    fn pyr_env_pool(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pep_p.gw || gid.y >= pep_p.gh) { return; }
        let x0 = gid.x * pep_p.cell;
        let y0 = gid.y * pep_p.cell;
        let x1 = min(x0 + pep_p.cell, pep_p.srcW);
        let y1 = min(y0 + pep_p.cell, pep_p.srcH);
        var acc = 0.0;
        var n = 0u;
        for (var y = y0; y < y1; y++) {
            for (var x = x0; x < x1; x++) {
                let i = y * pep_p.srcW + x;
                let b = h4load(pep_fine[i]) - pep_up[i];
                acc += b.x * b.x + b.y * b.y + b.z * b.z;
                n += 1u;
            }
        }
        var mean = 0.0;
        if (n > 0u) { mean = acc / f32(n); }
        let c = gid.y * pep_p.gw + gid.x;
        pep_envMax[c] = max(pep_envMax[c], mean);
        pep_envMin[c] = min(pep_envMin[c], mean);
    }

    @group(0) @binding(0) var<storage, read_write> pbd_fused: array<vec4f>;
    @group(0) @binding(1) var<storage, read> pbd_gauss: array<Half4>;
    @group(0) @binding(2) var<storage, read_write> pbd_bestLum: array<f32>;
    @group(0) @binding(3) var<uniform> pbd_p: Count1;

    // Base level: keep the least-luminous (least-bloomed) frame's Gaussian.
    // bestLum starts at +inf.
    @compute @workgroup_size(256)
    fn pyr_base_darkest(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pbd_p.count) { return; }
        let g = h4load(pbd_gauss[gid.x]);
        let lum = 0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z;
        if (lum < pbd_bestLum[gid.x]) {
            pbd_bestLum[gid.x] = lum;
            pbd_fused[gid.x] = g;
        }
    }

    @group(0) @binding(0) var<storage, read_write> pmf_fused: array<Half4>;
    @group(0) @binding(1) var<storage, read> pmf_trackB: array<Half4>;
    @group(0) @binding(2) var<storage, read> pmf_hasFocus: array<f32>;
    @group(0) @binding(3) var<uniform> pmf_p: Count1;

    // Focus-gate merge: where no frame was in focus, take track B.
    @compute @workgroup_size(256)
    fn pyr_merge_focus(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pmf_p.count) { return; }
        if (pmf_hasFocus[gid.x] < 0.5) {
            pmf_fused[gid.x] = pmf_trackB[gid.x];
        }
    }

    @group(0) @binding(0) var<storage, read_write> plm_min: array<f32>;
    @group(0) @binding(1) var<storage, read_write> plm_max: array<f32>;
    @group(0) @binding(2) var<storage, read> plm_gauss: array<Half4>;
    @group(0) @binding(3) var<uniform> plm_p: Count1;

    // Running per-cell MIN and MAX luminance over all frames, at level 0 — the
    // near-black gate reads the min, the contamination-sign test both.
    // Mirrors the CPU loop's lumMin0/lumMax0.
    @compute @workgroup_size(256)
    fn pyr_lum_minmax(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= plm_p.count) { return; }
        let g = h4load(plm_gauss[gid.x]);
        let lum = 0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z;
        plm_min[gid.x] = min(plm_min[gid.x], lum);
        plm_max[gid.x] = max(plm_max[gid.x], lum);
    }

    @group(0) @binding(0) var<storage, read_write> pfm_min: array<f32>;
    @group(0) @binding(1) var<storage, read_write> pfm_max: array<f32>;
    @group(0) @binding(2) var<storage, read> pfm_src: array<f32>;
    @group(0) @binding(3) var<uniform> pfm_p: Count1;

    // Running per-pixel min/max over frames of the level-0 grit energy — the
    // focus-movement planes the debloom membership reads. Mirrors the CPU
    // loop's focusMin0/focusMax0.
    @compute @workgroup_size(256)
    fn pyr_focus_minmax(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pfm_p.count) { return; }
        let e = pfm_src[gid.x];
        pfm_min[gid.x] = min(pfm_min[gid.x], e);
        pfm_max[gid.x] = max(pfm_max[gid.x], e);
    }

    @group(0) @binding(0) var<storage, read_write> pmg_fused: array<Half4>;
    @group(0) @binding(1) var<storage, read> pmg_trackB: array<Half4>;
    @group(0) @binding(2) var<storage, read> pmg_bestDarkLum: array<f32>;
    @group(0) @binding(3) var<storage, read> pmg_trackBright: array<Half4>;
    @group(0) @binding(4) var<storage, read> pmg_bestBrightLum: array<f32>;
    @group(0) @binding(5) var<storage, read> pmg_hasFocus: array<f32>;
    @group(0) @binding(6) var<storage, read> pmg_plainC: array<Half4>;
    @group(0) @binding(7) var<storage, read> pmg_mask: array<f32>;
    @group(0) @binding(8) var<storage, read> pmg_bgMask: array<f32>;
    @group(0) @binding(9) var<storage, read> pmg_clean: array<f32>;
    @group(0) @binding(10) var<uniform> pmg_p: Count1;

    // Membership-gated focus merge: blend the debloom answer (track A where a
    // frame was in focus; else the unfocused rendition nearest the clean
    // field in open-background cells, the darkest elsewhere) toward the plain
    // max-energy selection by the membership. Same choice as the CPU merge.
    @compute @workgroup_size(256)
    fn pyr_merge_focus_gated(@builtin(global_invocation_id) gidRaw: vec3u) {
        let gid = flatten1D(gidRaw);
        if (gid.x >= pmg_p.count) { return; }
        var d = h4load(pmg_fused[gid.x]);
        if (pmg_hasFocus[gid.x] < 0.5) {
            if (pmg_bgMask[gid.x] > 0.5
                && abs(pmg_bestBrightLum[gid.x] - pmg_clean[gid.x])
                    < abs(pmg_bestDarkLum[gid.x] - pmg_clean[gid.x])) {
                d = h4load(pmg_trackBright[gid.x]);
            } else {
                d = h4load(pmg_trackB[gid.x]);
            }
        }
        let c = h4load(pmg_plainC[gid.x]);
        pmg_fused[gid.x] = h4store(c + (d - c) * pmg_mask[gid.x]);
    }
    """
}
#endif // HYPERFOCAL_HAVE_WGPU
