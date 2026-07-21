#if HYPERFOCAL_HAVE_WGPU
import CWgpu
import Foundation

/// wgpu compute backend (cross-platform-plan Phase 4): the Windows/Linux
/// counterpart of `MetalEngine` — kernels compiled once from WGSL at startup,
/// pipeline cache, dispatch helpers. Same discipline as Metal: all image
/// kernels operate on raw Float32 storage buffers (no textures) with taps,
/// clamps, and luma weights identical to the CPU path.
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
                wgpuComputePassEncoderDispatchWorkgroups(
                    pass, UInt32((gridW + 255) / 256), 1, 1)
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
    struct WarpParams {
        r0: vec4f,
        r1: vec4f,
        r2: vec4f,
        dims: vec4u,   // srcW, srcH, dstW, dstH
    }

    @group(0) @binding(0) var<storage, read> warp_src: array<vec4f>;
    @group(0) @binding(1) var<storage, read_write> warp_dst: array<vec4f>;
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
                row += warp_src[ty * sw + tx] * wx[kx];
            }
            acc += row * wy[ky];
        }
        var sample = acc / (sumX * sumY);
        let cx0 = clamp(x0, 0, sw - 1);
        let cx1 = clamp(x0 + 1, 0, sw - 1);
        let cy0 = clamp(y0, 0, sh - 1);
        let cy1 = clamp(y0 + 1, 0, sh - 1);
        let a = warp_src[cy0 * sw + cx0];
        let b = warp_src[cy0 * sw + cx1];
        let c = warp_src[cy1 * sw + cx0];
        let d = warp_src[cy1 * sw + cx1];
        sample = clamp(sample, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
        let inside = sx >= -0.5 && sx <= f32(sw) - 0.5
                  && sy >= -0.5 && sy <= f32(sh) - 0.5;
        sample.w = select(0.0, sample.w, inside);
        warp_dst[gid.y * dw + gid.x] = sample;
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
        let top = mix(warp_src[cy0 * sw + cx0], warp_src[cy0 * sw + cx1], wx);
        let bot = mix(warp_src[cy1 * sw + cx0], warp_src[cy1 * sw + cx1], wx);
        var sample = mix(top, bot, wy);
        let inside = sx >= -0.5 && sx <= f32(sw) - 0.5
                  && sy >= -0.5 && sy <= f32(sh) - 0.5;
        sample.w = select(0.0, sample.w, inside);
        warp_dst[gid.y * dw + gid.x] = sample;
    }

    const kLuma = vec3f(0.2126, 0.7152, 0.0722);

    struct Dims2 { w: u32, h: u32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read> ll_img: array<vec4f>;
    @group(0) @binding(1) var<storage, read_write> ll_out: array<f32>;
    @group(0) @binding(2) var<uniform> ll_p: Dims2;

    @compute @workgroup_size(16, 16)
    fn lum_laplacian(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= ll_p.w || gid.y >= ll_p.h) { return; }
        let w = i32(ll_p.w);
        let h = i32(ll_p.h);
        let x = i32(gid.x);
        let y = i32(gid.y);
        let xl = max(x - 1, 0);
        let xr = min(x + 1, w - 1);
        let yu = max(y - 1, 0);
        let yd = min(y + 1, h - 1);
        let c = dot(ll_img[y * w + x].rgb, kLuma);
        let l = dot(ll_img[y * w + xl].rgb, kLuma);
        let r = dot(ll_img[y * w + xr].rgb, kLuma);
        let u = dot(ll_img[yu * w + x].rgb, kLuma);
        let d = dot(ll_img[yd * w + x].rgb, kLuma);
        ll_out[y * w + x] = abs(l + r + u + d - 4.0 * c);
    }

    struct ArgmaxParams { frameIdx: f32, count: u32, gain: f32, pad: u32 }

    @group(0) @binding(0) var<storage, read> am_energy: array<f32>;
    @group(0) @binding(1) var<storage, read> am_frame: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> am_bestE: array<f32>;
    @group(0) @binding(3) var<storage, read_write> am_bestIdx: array<f32>;
    @group(0) @binding(4) var<storage, read_write> am_guide: array<f32>;
    @group(0) @binding(5) var<uniform> am_p: ArgmaxParams;

    @compute @workgroup_size(256)
    fn argmax_update(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= am_p.count) { return; }
        let e = am_energy[gid.x] * am_frame[gid.x].w * am_p.gain;
        let wins = e > am_bestE[gid.x];
        if (wins) {
            am_bestE[gid.x] = e;
            am_bestIdx[gid.x] = am_p.frameIdx;
        }
        if (wins || am_p.frameIdx == 0.0) {
            am_guide[gid.x] = dot(am_frame[gid.x].rgb, kLuma) * am_p.gain;
        }
    }

    struct TentParams { gain: vec4f, index: f32, radius: f32, count: u32, pad: u32 }

    @group(0) @binding(0) var<storage, read> ta_frame: array<vec4f>;
    @group(0) @binding(1) var<storage, read> ta_depth: array<f32>;
    @group(0) @binding(2) var<storage, read_write> ta_accum: array<vec4f>;
    @group(0) @binding(3) var<storage, read_write> ta_wsum: array<f32>;
    @group(0) @binding(4) var<uniform> ta_p: TentParams;

    @compute @workgroup_size(256)
    fn tent_accumulate(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= ta_p.count) { return; }
        let s = ta_frame[gid.x];
        if (s.w <= 0.0) { return; }
        let tent = max(1.0 - abs(ta_p.index - ta_depth[gid.x]) / ta_p.radius, 0.0);
        let w = (tent + 1e-6) * s.w;
        ta_accum[gid.x] += vec4f(s.xyz * (w * ta_p.gain.xyz), s.w * w);
        ta_wsum[gid.x] += w;
    }

    struct PlanePreviewParams { srcW: u32, srcH: u32, dstW: u32, dstH: u32, scale: f32, bias: f32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read> pp_plane: array<f32>;
    @group(0) @binding(1) var<storage, read_write> pp_out: array<vec4f>;
    @group(0) @binding(2) var<uniform> pp_p: PlanePreviewParams;

    @compute @workgroup_size(16, 16)
    fn plane_preview(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pp_p.dstW || gid.y >= pp_p.dstH) { return; }
        let sx = min(gid.x * pp_p.srcW / pp_p.dstW, pp_p.srcW - 1u);
        let sy = min(gid.y * pp_p.srcH / pp_p.dstH, pp_p.srcH - 1u);
        let v = pp_p.bias + pp_plane[sy * pp_p.srcW + sx] * pp_p.scale;
        pp_out[gid.y * pp_p.dstW + gid.x] = vec4f(v, v, v, 1.0);
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

    @group(0) @binding(0) var<storage, read> lp_img: array<vec4f>;
    @group(0) @binding(1) var<storage, read_write> lp_out: array<f32>;
    @group(0) @binding(2) var<uniform> lp_p: Count1;

    @compute @workgroup_size(256)
    fn luma_plane(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= lp_p.count) { return; }
        let p = lp_img[gid.x];
        lp_out[gid.x] = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z;
    }

    struct PreviewParams { srcW: u32, srcH: u32, dstW: u32, dstH: u32 }

    @group(0) @binding(0) var<storage, read> pv_accum: array<vec4f>;
    @group(0) @binding(1) var<storage, read> pv_wsum: array<f32>;
    @group(0) @binding(2) var<storage, read_write> pv_out: array<vec4f>;
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
        pv_out[gid.y * pv_p.dstW + gid.x] = v;
    }

    @group(0) @binding(0) var<storage, read> no_accum: array<vec4f>;
    @group(0) @binding(1) var<storage, read> no_wsum: array<f32>;
    @group(0) @binding(2) var<storage, read_write> no_out: array<vec4f>;
    @group(0) @binding(3) var<uniform> no_p: Count1;

    @compute @workgroup_size(256)
    fn normalize_out(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= no_p.count) { return; }
        let w = no_wsum[gid.x];
        var v = select(vec4f(0.0), no_accum[gid.x] / w, w > 1e-7);
        v.w = 1.0;
        no_out[gid.x] = v;
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
    fn confidence_map(@builtin(global_invocation_id) gid: vec3u) {
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
    fn clamp_plane(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= cp_p.count) { return; }
        cp_plane[gid.x] = clamp(cp_plane[gid.x], 0.0, cp_p.maxV);
    }

    // ---- Laplacian pyramid fusion (PMax) ----

    const kPyr5 = array<f32, 5>(1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16);

    @group(0) @binding(0) var<storage, read> pb_src: array<vec4f>;
    @group(0) @binding(1) var<storage, read_write> pb_dst: array<vec4f>;
    @group(0) @binding(2) var<uniform> pb_p: Dims2;

    @compute @workgroup_size(16, 16)
    fn pyr_blur5_h(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pb_p.w || gid.y >= pb_p.h) { return; }
        let w = i32(pb_p.w);
        let row = i32(gid.y) * w;
        var acc = vec4f(0.0);
        for (var i = -2; i <= 2; i++) {
            let xi = clamp(i32(gid.x) + i, 0, w - 1);
            acc += pb_src[row + xi] * kPyr5[i + 2];
        }
        pb_dst[row + i32(gid.x)] = acc;
    }

    @compute @workgroup_size(16, 16)
    fn pyr_blur5_v(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pb_p.w || gid.y >= pb_p.h) { return; }
        let w = i32(pb_p.w);
        let h = i32(pb_p.h);
        var acc = vec4f(0.0);
        for (var i = -2; i <= 2; i++) {
            let yi = clamp(i32(gid.y) + i, 0, h - 1);
            acc += pb_src[yi * w + i32(gid.x)] * kPyr5[i + 2];
        }
        pb_dst[i32(gid.y) * w + i32(gid.x)] = acc;
    }

    @group(0) @binding(0) var<storage, read> pr_src: array<vec4f>;
    @group(0) @binding(1) var<storage, read_write> pr_dst: array<vec4f>;
    @group(0) @binding(2) var<uniform> pr_p: PreviewParams;

    @compute @workgroup_size(16, 16)
    fn pyr_decimate(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pr_p.dstW || gid.y >= pr_p.dstH) { return; }
        let sx = min(gid.x * 2u, pr_p.srcW - 1u);
        let sy = min(gid.y * 2u, pr_p.srcH - 1u);
        pr_dst[gid.y * pr_p.dstW + gid.x] = pr_src[sy * pr_p.srcW + sx];
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
        let top = mix(pr_src[cy0 * sw + cx0], pr_src[cy0 * sw + cx1], wx);
        let bot = mix(pr_src[cy1 * sw + cx0], pr_src[cy1 * sw + cx1], wx);
        return mix(top, bot, wy);
    }

    @compute @workgroup_size(16, 16)
    fn pyr_upsample(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pr_p.dstW || gid.y >= pr_p.dstH) { return; }
        pr_dst[gid.y * pr_p.dstW + gid.x] =
            pyr_bilinear_at(i32(pr_p.srcW), i32(pr_p.srcH), gid, pr_p.dstW, pr_p.dstH);
    }

    @group(0) @binding(0) var<storage, read> pu_src: array<vec4f>;
    @group(0) @binding(1) var<storage, read> pu_band: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> pu_dst: array<vec4f>;
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
        let top = mix(pu_src[cy0 * sw + cx0], pu_src[cy0 * sw + cx1], wx);
        let bot = mix(pu_src[cy1 * sw + cx0], pu_src[cy1 * sw + cx1], wx);
        return mix(top, bot, wy);
    }

    @compute @workgroup_size(16, 16)
    fn pyr_upsample_add(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pu_p.dstW || gid.y >= pu_p.dstH) { return; }
        let i = gid.y * pu_p.dstW + gid.x;
        pu_dst[i] = pu_band[i]
            + pu_bilinear_at(i32(pu_p.srcW), i32(pu_p.srcH), gid, pu_p.dstW, pu_p.dstH);
    }

    @group(0) @binding(0) var<storage, read> ps_fine: array<vec4f>;
    @group(0) @binding(1) var<storage, read> ps_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> ps_fused: array<vec4f>;
    @group(0) @binding(3) var<storage, read_write> ps_bestE: array<f32>;
    @group(0) @binding(4) var<uniform> ps_p: Count1;

    @compute @workgroup_size(256)
    fn pyr_select(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= ps_p.count) { return; }
        let band = ps_fine[gid.x] - ps_up[gid.x];
        let e = abs(band.x) + abs(band.y) + abs(band.z);
        if (e > ps_bestE[gid.x]) {
            ps_bestE[gid.x] = e;
            ps_fused[gid.x] = band;
        }
    }

    @group(0) @binding(0) var<storage, read> pe_fine: array<vec4f>;
    @group(0) @binding(1) var<storage, read> pe_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> pe_e: array<f32>;
    @group(0) @binding(3) var<uniform> pe_p: Count1;

    @compute @workgroup_size(256)
    fn pyr_band_energy(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pe_p.count) { return; }
        let band = pe_fine[gid.x] - pe_up[gid.x];
        pe_e[gid.x] = abs(band.x) + abs(band.y) + abs(band.z);
    }

    @group(0) @binding(0) var<storage, read> pss_fine: array<vec4f>;
    @group(0) @binding(1) var<storage, read> pss_up: array<vec4f>;
    @group(0) @binding(2) var<storage, read_write> pss_fused: array<vec4f>;
    @group(0) @binding(3) var<storage, read_write> pss_bestE: array<f32>;
    @group(0) @binding(4) var<storage, read> pss_energy: array<f32>;
    @group(0) @binding(5) var<uniform> pss_p: Count1;

    @compute @workgroup_size(256)
    fn pyr_select_smoothed(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pss_p.count) { return; }
        let e = pss_energy[gid.x];
        if (e > pss_bestE[gid.x]) {
            pss_bestE[gid.x] = e;
            pss_fused[gid.x] = pss_fine[gid.x] - pss_up[gid.x];
        }
    }

    @group(0) @binding(0) var<storage, read_write> pa_dst: array<vec4f>;
    @group(0) @binding(1) var<storage, read> pa_src: array<vec4f>;
    @group(0) @binding(2) var<uniform> pa_p: Count1;

    @compute @workgroup_size(256)
    fn pyr_add4(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pa_p.count) { return; }
        pa_dst[gid.x] += pa_src[gid.x];
    }

    struct ScaleParams { s: f32, count: u32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read_write> psc_dst: array<vec4f>;
    @group(0) @binding(1) var<uniform> psc_p: ScaleParams;

    @compute @workgroup_size(256)
    fn pyr_scale4(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= psc_p.count) { return; }
        psc_dst[gid.x] *= psc_p.s;
    }

    struct FillParams { v: f32, count: u32, pad0: u32, pad1: u32 }

    @group(0) @binding(0) var<storage, read_write> pf_dst: array<f32>;
    @group(0) @binding(1) var<uniform> pf_p: FillParams;

    @compute @workgroup_size(256)
    fn pyr_fill(@builtin(global_invocation_id) gid: vec3u) {
        if (gid.x >= pf_p.count) { return; }
        pf_dst[gid.x] = pf_p.v;
    }
    """
}
#endif // HYPERFOCAL_HAVE_WGPU
