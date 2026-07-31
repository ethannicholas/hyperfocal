import Foundation
#if canImport(simd)
import simd
#endif

/// The fusion algorithm producing a stack's result. DMap (depth-map fusion)
/// yields an image plus a depth map; PMax (Laplacian-pyramid max-coefficient)
/// yields an image only. Shared by the CLI, the pipeline, and the app.
public enum FusionMethod: String, Sendable, CaseIterable {
    case dmap
    case pmax
}

/// One-call orchestration of the full stack → fused image pipeline, shared by
/// the CLI and the app.
public enum StackPipeline {

    public struct Configuration {
        /// DMap settings. Parallel to `pmax` below: same shape, both
        /// non-optional, neither algorithm a special case.
        public var dmap: DMapFusion.Options
        public var align: Bool
        public var preferGPU: Bool
        /// Which fusion algorithm to run. `.dmap` (the default) produces a
        /// depth map; `.pmax` produces an image only.
        public var method: FusionMethod
        /// PMax settings. Ignored unless `method == .pmax`; debloom is disabled
        /// by `coarseLevels == 0`, not by a separate switch. Non-optional and
        /// named to match `dmap` above — when this was an optional `FocusGate?`
        /// every caller had to decide what nil meant, and the app and the CLI
        /// decided differently, shipping debloom on in one and off in the other.
        public var pmax: PyramidFusion.Options
        /// When registration flags bad frames (misfires, failed alignment),
        /// exclude them all and fuse the rest. Overridden by `badFrameHandler`.
        public var autoExcludeBadFrames: Bool
        /// Decides which flagged frames to exclude (called on the fusion thread
        /// with the issues; return the frame indices to drop). Lets a UI ask
        /// the user mid-fuse. nil → `autoExcludeBadFrames` excludes all or none.
        public var badFrameHandler: (([FrameQualityIssue]) -> Set<Int>)?
        /// PMax only: retain per-frame sharpness planes (the grit-blurred
        /// level-0 focus each engine already computes for selection, reduced
        /// to the sharpness grid) on `Output.sharpness`. This is what
        /// retouch's space auto-pick queries — a DMap fuse retains the
        /// equivalent unconditionally; a PMax primary has no other source.
        /// Costs one small reduction + ~3 MB readback per frame, hidden
        /// under decode. Ignored by `.dmap`.
        public var retainPMaxSharpness: Bool = false
        /// Warped frames retained from a prior DMap fuse of the SAME frame
        /// list (`Options.retainSpill` → `Output.warpedFrames`). A `.pmax`
        /// fuse whose canvas matches streams these instead of re-decoding
        /// and re-warping the stack — the app's background PMax generation
        /// uses this to stay off Apple's RAW engine, which retouch's
        /// on-demand source loads are hammering at the same time (concurrent
        /// RAW decode measured ≥4× slower end-to-end). Ignored by `.dmap`
        /// (its own spill covers its second pass).
        public var warpedFrameCache: WarpedFrameCache?

        public init(dmap: DMapFusion.Options = DMapFusion.Options(),
                    align: Bool = true, preferGPU: Bool = true,
                    method: FusionMethod = .dmap,
                    pmax: PyramidFusion.Options = .init(),
                    autoExcludeBadFrames: Bool = false,
                    badFrameHandler: (([FrameQualityIssue]) -> Set<Int>)? = nil) {
            self.dmap = dmap
            self.align = align
            self.preferGPU = preferGPU
            self.method = method
            self.pmax = pmax
            self.autoExcludeBadFrames = autoExcludeBadFrames
            self.badFrameHandler = badFrameHandler
        }

    }

    public struct FuseResult {
        public let output: DMapFusion.Output
        /// Frames the registration pass flagged (empty when alignment was
        /// cached or off — detection runs only during fresh registration).
        public let issues: [FrameQualityIssue]
        /// The frames actually fused, in order — a subset of the input when
        /// flagged frames were excluded.
        public let fusedURLs: [URL]
    }

    /// Registers (optionally) and fuses the given frames, streaming from disk.
    /// `log` receives progress lines; `progress` receives structured stage
    /// progress including progressive render previews. Pass an `alignmentCache`
    /// to skip registration when the exact frame list was already aligned
    /// (alignment doesn't depend on any fusion setting).
    public static func fuse(urls: [URL], configuration: Configuration = Configuration(),
                            alignmentCache: AlignmentCache? = nil,
                            log: ((String) -> Void)? = nil,
                            progress: FusionProgressHandler? = nil,
                            cancellation: CancellationToken? = nil) throws -> DMapFusion.Output {
        try fuseResult(urls: urls, configuration: configuration,
                       alignmentCache: alignmentCache, log: log,
                       progress: progress, cancellation: cancellation).output
    }

    public static func fuseResult(urls: [URL], configuration: Configuration = Configuration(),
                                  alignmentCache: AlignmentCache? = nil,
                                  log: ((String) -> Void)? = nil,
                                  progress: FusionProgressHandler? = nil,
                                  cancellation: CancellationToken? = nil) throws -> FuseResult {
        precondition(urls.count >= 2, "need at least 2 frames")
        var transforms: [simd_float3x3]? = nil
        var fuseURLs = urls
        var issues = [FrameQualityIssue]()
        if configuration.align {
            if let cached = alignmentCache?.transforms(for: urls) {
                log?("alignment cache hit — skipping registration")
                progress?(FusionProgress(stage: .registering, fraction: 1))
                transforms = cached
            } else {
                log?("registering \(urls.count) frames")
                let registration = try Aligner.transformsAndQuality(
                    forFrames: urls, log: log,
                    cancellation: cancellation) { fraction, index, gray, pass, active in
                    guard let progress else { return }
                    var buffer: ImageBuffer? = nil
                    var fw = 0, fh = 0
                    if let gray {
                        buffer = try? ImageFile.previewBuffer(from: gray, maxSide: 1200)
                        fw = gray.width
                        fh = gray.height
                    }
                    switch pass {
                    case .decode:
                        // The frame as shot — belongs in the source pane.
                        progress(FusionProgress(stage: .registering, fraction: fraction,
                                                sourceFrameIndex: index,
                                                sourcePreview: buffer,
                                                sourceFullWidth: fw, sourceFullHeight: fh,
                                                activeFrames: active))
                    case .register:
                        // Gradient-magnitude image, a derived artifact — show
                        // it output-side, not as if it were a source frame.
                        progress(FusionProgress(stage: .aligning, fraction: fraction,
                                                preview: buffer,
                                                previewFullWidth: fw, previewFullHeight: fh,
                                                sourceFrameIndex: index,
                                                activeFrames: active))
                    }
                }
                alignmentCache?.store(registration.transforms, for: urls)
                issues = registration.issues
                var excluded = Set<Int>()
                if !issues.isEmpty {
                    if let handler = configuration.badFrameHandler {
                        excluded = handler(issues)
                    } else if configuration.autoExcludeBadFrames {
                        excluded = Set(issues.map(\.index))
                    } else {
                        for issue in issues {
                            log?("warning: \(urls[issue.index].lastPathComponent) \(issue.summary) — fusing it anyway")
                        }
                    }
                }
                if excluded.isEmpty {
                    transforms = registration.transforms
                } else {
                    for issue in issues where excluded.contains(issue.index) {
                        log?("excluding \(urls[issue.index].lastPathComponent): \(issue.summary)")
                    }
                    let keptIndices = urls.indices.filter { !excluded.contains($0) }
                    guard keptIndices.count >= 2 else {
                        throw AlignError.tooFewGoodFrames(good: keptIndices.count)
                    }
                    fuseURLs = keptIndices.map { urls[$0] }
                    transforms = keptIndices.map { registration.transforms[$0] }
                    // Cache under the reduced list too, so re-fuses and retouch
                    // source rebuilds of exactly these frames skip registration.
                    alignmentCache?.store(transforms!, for: fuseURLs)
                }
            }
        }
        let source = makeSource(urls: fuseURLs, transforms: transforms, log: log)
        var output: DMapFusion.Output
        var fusionOptions = configuration.dmap
        // Always retain the despill grid inputs on the DMap path: the render
        // cleanup below is on by default, and the planes are cheap next to a
        // fuse. (PMax only retains them on its CPU streaming loop, so its
        // despill stays opt-in until the GPU port — see ROADMAP.)
        if configuration.method == .dmap { fusionOptions.prepareDespill = true }
        switch configuration.method {
        case .pmax:
            // PMax (Laplacian-pyramid max-coefficient): image only, no depth.
            // Alignment/exclusion above is method-independent, so both
            // algorithms share the one registration pass.
            let pmaxProgress: (Double, Int, ImageBuffer?) -> Void = { fraction, frame, preview in
                // PMax streams frames through the accumulator one at a time,
                // so its render progress names the frame being folded in —
                // the Stack panel follows it like DMap's per-frame stages.
                // The final collapse reports -1 (whole-image work).
                progress?(FusionProgress(stage: .render, fraction: fraction,
                                         preview: preview,
                                         previewFullWidth: source.outputWidth ?? (preview?.width ?? 0),
                                         previewFullHeight: source.outputHeight ?? (preview?.height ?? 0),
                                         sourceFrameIndex: frame))
            }
            let image: ImageBuffer
            var pmaxSharpness: FrameSharpness? = nil
            let onSharpness: ((FrameSharpness) -> Void)? =
                configuration.retainPMaxSharpness ? { pmaxSharpness = $0 } : nil
            if let cache = configuration.warpedFrameCache,
               cache.frameCount == source.count,
               cache.width == source.outputWidth, cache.height == source.outputHeight {
                // Frames come pre-warped off the retained spill: no RAW
                // decode, no warp — plain SSD streaming. `warp: nil` because
                // the cache already holds aligned frames on this canvas.
                log?("pmax: streaming \(cache.frameCount) warped frames from the primary fuse's cache")
                // Spill reads outrun the GPU consumer, so the default
                // decode-ahead window (up to 8 frames) just fills with ~0.7 GB
                // buffers — measured as a ~5-6 GB transient while the
                // background secondary ran. Two in flight keeps the overlap;
                // SSD latency needs no deeper pipeline.
                image = try PyramidFusion.fuse(
                    frameCount: cache.frameCount, preferGPU: configuration.preferGPU,
                    warp: nil, log: log, progress: pmaxProgress,
                    cancellation: cancellation,
                    decodeWorkers: 2, decodeLookahead: 2,
                    options: configuration.pmax,
                    onSharpness: onSharpness) { try cache.frame($0) }
            } else {
                if configuration.warpedFrameCache != nil {
                    log?("pmax: warped-frame cache doesn't match this canvas — re-decoding")
                }
                image = try PyramidFusion.fuse(
                    source: source, preferGPU: configuration.preferGPU, log: log,
                    progress: pmaxProgress,
                    cancellation: cancellation, options: configuration.pmax,
                    onSharpness: onSharpness)
            }
            output = DMapFusion.Output(image: image, depthMap: ImageBuffer(width: 0, height: 0),
                                       depth: [], sharpness: pmaxSharpness, gains: nil)
        case .dmap:
        #if canImport(Metal)
        if configuration.preferGPU, MetalEngine.shared != nil {
            output = try GPUDMap.fuseWithDepth(source: source, options: fusionOptions,
                                               log: log, progress: progress,
                                               cancellation: cancellation)
        } else {
            output = try DMapFusion.fuseWithDepth(source: source,
                                                  options: fusionOptions, log: log,
                                                  progress: progress,
                                                  cancellation: cancellation)
        }
        #elseif HYPERFOCAL_HAVE_WGPU
        if configuration.preferGPU, let engine = WgpuEngine.shared,
           engine.usableForAutoSelection {
            output = try WgpuDMap.fuseWithDepth(source: source, options: fusionOptions,
                                                log: log, progress: progress,
                                                cancellation: cancellation)
        } else {
            output = try DMapFusion.fuseWithDepth(source: source,
                                                  options: fusionOptions, log: log,
                                                  progress: progress,
                                                  cancellation: cancellation)
        }
        #else
        output = try DMapFusion.fuseWithDepth(source: source,
                                              options: fusionOptions, log: log,
                                              progress: progress,
                                              cancellation: cancellation)
        #endif
        }
        applyRenderCleanup(to: &output, log: log)
        progress?(FusionProgress(stage: .finishing, fraction: 1))
        return FuseResult(output: output, issues: issues, fusedURLs: fuseURLs)
    }

    /// The always-on render cleanup: rim despill (structured defocus-spill glow
    /// hugging the silhouette) then black point (uniform backdrop veil,
    /// self-gated to dark backdrops — see `BlackPoint`). Both passes are
    /// no-risk by construction on scenes they don't apply to — despill's
    /// spill-strength gate reads a lit scene as subject, black-point's veil
    /// gate reads a non-black floor as "no backdrop" — which is why there is
    /// no user-facing control, matching commercial stackers' default-clean
    /// output. Applied to every consumer of the fused result, DNG included:
    /// the glow is baked into fused pixels, so a raw developer downstream
    /// could never remove it later.
    ///
    /// A/B escape hatches (measurement, not user settings):
    /// `HYPERFOCAL_DESPILL` / `HYPERFOCAL_BLACK_POINT` = 0 disable a pass.
    /// PMax has no despill inputs off the CPU streaming path (GPU port is a
    /// ROADMAP item), so only the black point applies there.
    static func applyRenderCleanup(to output: inout DMapFusion.Output,
                                   log: ((String) -> Void)? = nil) {
        let env = ProcessInfo.processInfo.environment
        let despill = min(max(Float(env["HYPERFOCAL_DESPILL"] ?? "") ?? 1, 0), 1)
        let blackPoint = min(max(Float(env["HYPERFOCAL_BLACK_POINT"] ?? "") ?? 1, 0), 1)
        if despill > 0, let inputs = output.despill {
            Despill.apply(to: &output.image, inputs: inputs, intensity: despill, log: log)
        }
        // The despill inputs carry two full-resolution f32 planes (~360 MB at
        // 45 MP) and nothing downstream of this cleanup reads them — they must
        // not ride the Output into the app's fuse-completion retention, which
        // holds the Output alive through retouch prewarm and the secondary
        // launch.
        output.despill = nil
        if blackPoint > 0 {
            BlackPoint.applyExport(to: &output.image, intensity: blackPoint, log: log)
        }
    }

    /// Builds the fusion's frame source, cropping the output canvas to the
    /// region every frame covers after alignment. Edge bands that only some
    /// frames reach are unfixable by construction (the only frames with data
    /// there are far out of focus), so they don't belong in the output at all.
    public static func makeSource(urls: [URL], transforms: [simd_float3x3]?,
                                  log: ((String) -> Void)? = nil) -> StackSource {
        guard let transforms, let dims = ImageFile.pixelSize(url: urls[0]) else {
            return StackSource(urls: urls, transforms: transforms)
        }
        let cropped = cropForCoverage(transforms: transforms,
                                      frameWidth: dims.width, frameHeight: dims.height)
        if cropped.width != dims.width || cropped.height != dims.height {
            log?("cropping to common coverage: \(cropped.width)x\(cropped.height) (from \(dims.width)x\(dims.height))")
        }
        return StackSource(urls: urls, transforms: cropped.transforms,
                           outputWidth: cropped.width, outputHeight: cropped.height)
    }

    /// The axis-aligned rectangle (in reference space) guaranteed to be covered
    /// by every frame, baked into the transforms as a translation so the whole
    /// pipeline — fusion, previews, depth, sharpness, retouch sources — simply
    /// works at the cropped size.
    public static func cropForCoverage(transforms: [simd_float3x3],
                                       frameWidth: Int, frameHeight: Int)
        -> (transforms: [simd_float3x3], width: Int, height: Int) {
        let w = Float(frameWidth), h = Float(frameHeight)
        var left: Float = 0, top: Float = 0, right = w, bottom = h
        for t in transforms {
            func map(_ x: Float, _ y: Float) -> SIMD2<Float> {
                let p = t * simd_float3(x, y, 1)
                return SIMD2(p.x / p.z, p.y / p.z)
            }
            let tl = map(0, 0), tr = map(w, 0), bl = map(0, h), br = map(w, h)
            // Inner axis-aligned rect of the (near-rectangular) warped quad.
            left = max(left, max(tl.x, bl.x))
            right = min(right, min(tr.x, br.x))
            top = max(top, max(tl.y, tr.y))
            bottom = min(bottom, min(bl.y, br.y))
        }
        let x0 = Int(left.rounded(.up)), y0 = Int(top.rounded(.up))
        let x1 = Int(right.rounded(.down)), y1 = Int(bottom.rounded(.down))
        guard x1 - x0 >= 16, y1 - y0 >= 16 else {
            return (transforms, frameWidth, frameHeight)  // degenerate; don't crop
        }
        let shift = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, Float(-x0)),
            SIMD3<Float>(0, 1, Float(-y0)),
            SIMD3<Float>(0, 0, 1),
        ])
        return (transforms.map { shift * $0 }, x1 - x0, y1 - y0)
    }
}

/// Cooperative cancellation for long-running fusion work. Checked at frame
/// boundaries and between regularization steps; cancel latency is bounded by
/// the longest single step (a regularization pass, tens of seconds at 45 MP).
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Remembers registration transforms per frame list. Alignment depends only
/// on the frames, so re-fusing with different settings skips the registration
/// pass. Holds several entries (a multi-stack project re-fuses and retouches
/// stacks in any order); matrices are tiny, but entries are capped anyway.
public final class AlignmentCache {
    private var entries: [[URL]: [simd_float3x3]] = [:]
    private var order: [[URL]] = []
    private let lock = NSLock()
    private static let capacity = 64

    public init() {}

    public func transforms(for urls: [URL]) -> [simd_float3x3]? {
        lock.lock()
        defer { lock.unlock() }
        return entries[urls]
    }

    public func store(_ transforms: [simd_float3x3], for urls: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        if entries[urls] == nil {
            order.append(urls)
            if order.count > Self.capacity {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        entries[urls] = transforms
    }

    /// Forget everything — a new project must not inherit alignments from
    /// frame lists the previous one registered.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }
}
