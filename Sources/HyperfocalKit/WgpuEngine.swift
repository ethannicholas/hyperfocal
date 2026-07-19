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
            _ = wgpuAdapterRequestDevice(adapter, nil, devCB)
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

    /// Copy a buffer back to host memory: staging copy + map + poll-to-done.
    func download(_ buffer: Buffer, into dst: UnsafeMutableRawPointer) throws {
        var desc = WGPUBufferDescriptor()
        desc.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst
        desc.size = UInt64(buffer.byteCount)
        guard let staging = wgpuDeviceCreateBuffer(device, &desc) else {
            throw StackError.metal("cannot allocate wgpu staging buffer")
        }
        defer { wgpuBufferRelease(staging) }
        let encoder = wgpuDeviceCreateCommandEncoder(device, nil)
        wgpuCommandEncoderCopyBufferToBuffer(encoder, buffer.raw, 0, staging, 0,
                                             UInt64(buffer.byteCount))
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
            _ = wgpuBufferMapAsync(staging, WGPUMapMode_Read, 0, buffer.byteCount, cb)
            var spins = 0
            while !p.pointee {
                _ = wgpuDevicePoll(device, WGPUBool(1), nil)
                spins += 1
                if spins > 1_000_000 { throw StackError.metal("wgpu map timeout") }
            }
        }
        guard let src = wgpuBufferGetConstMappedRange(staging, 0, buffer.byteCount) else {
            throw StackError.metal("wgpu map returned no range")
        }
        dst.copyMemory(from: src, byteCount: buffer.byteCount)
        wgpuBufferUnmap(staging)
    }

    // MARK: - Dispatch

    /// One kernel dispatch: bind group from the buffer list (bindings 0..n in
    /// order, uniforms — if any — as the last binding), submit, wait. The
    /// WGSL kernels declare their bindings in exactly this order.
    func run(_ kernelName: String, buffers: [Buffer],
             uniforms: [UInt8]? = nil, gridW: Int, gridH: Int = 1) throws {
        let pipeline = try pipeline(kernelName)

        var uniformBuf: WGPUBuffer? = nil
        if let uniforms {
            var desc = WGPUBufferDescriptor()
            desc.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst
            desc.size = UInt64(uniforms.count)
            uniformBuf = wgpuDeviceCreateBuffer(device, &desc)
            uniforms.withUnsafeBytes {
                wgpuQueueWriteBuffer(queue, uniformBuf, 0, $0.baseAddress!, $0.count)
            }
        }
        defer { if let u = uniformBuf { wgpuBufferRelease(u) } }

        var entries: [WGPUBindGroupEntry] = []
        for (i, b) in buffers.enumerated() {
            var e = WGPUBindGroupEntry()
            e.binding = UInt32(i)
            e.buffer = b.raw
            e.size = UInt64(b.byteCount)
            entries.append(e)
        }
        if let u = uniformBuf, let uniforms {
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
            return wgpuDeviceCreateBindGroup(device, &bgDesc)
        }
        guard let bindGroup else { throw StackError.metal("wgpu bind group failed") }
        defer { wgpuBindGroupRelease(bindGroup) }

        let encoder = wgpuDeviceCreateCommandEncoder(device, nil)
        let pass = wgpuCommandEncoderBeginComputePass(encoder, nil)
        wgpuComputePassEncoderSetPipeline(pass, pipeline)
        wgpuComputePassEncoderSetBindGroup(pass, 0, bindGroup, 0, nil)
        // Workgroup size is 16x16 for 2D kernels, 256 for 1D — matches the
        // @workgroup_size in the WGSL below.
        if gridH > 1 {
            wgpuComputePassEncoderDispatchWorkgroups(
                pass, UInt32((gridW + 15) / 16), UInt32((gridH + 15) / 16), 1)
        } else {
            wgpuComputePassEncoderDispatchWorkgroups(
                pass, UInt32((gridW + 255) / 256), 1, 1)
        }
        wgpuComputePassEncoderEnd(pass)
        wgpuComputePassEncoderRelease(pass)
        var cmd = wgpuCommandEncoderFinish(encoder, nil)
        wgpuQueueSubmit(queue, 1, &cmd)
        wgpuCommandBufferRelease(cmd!)
        wgpuCommandEncoderRelease(encoder)
        while wgpuDevicePoll(device, WGPUBool(1), nil) == WGPUBool(0) {}
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
    """
}
#endif // HYPERFOCAL_HAVE_WGPU
