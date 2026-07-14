import Foundation
import simd

/// One-call orchestration of the full stack → fused image pipeline, shared by
/// the CLI and the app.
public enum StackPipeline {

    public struct Configuration {
        public var fusion: DMapFusion.Options
        public var align: Bool
        public var preferGPU: Bool
        /// Slabbing (deep stacks): frames per slab; 0 disables. Each slab is
        /// pyramid-fused (PMax handles overlapping structures within its shallow
        /// depth range, where its weaknesses barely show), then the slab images
        /// are depth-map fused (halo control at scene scale).
        public var slabSize: Int
        /// Frames shared between adjacent slabs (continuity across seams).
        /// Defaults to slabSize / 3 when left at 0.
        public var slabOverlap: Int
        /// Where slab images are written. nil → a unique temp directory.
        public var slabDirectory: URL?
        /// When registration flags bad frames (misfires, failed alignment),
        /// exclude them all and fuse the rest. Overridden by `badFrameHandler`.
        public var autoExcludeBadFrames: Bool
        /// Decides which flagged frames to exclude (called on the fusion thread
        /// with the issues; return the frame indices to drop). Lets a UI ask
        /// the user mid-fuse. nil → `autoExcludeBadFrames` excludes all or none.
        public var badFrameHandler: (([FrameQualityIssue]) -> Set<Int>)?

        public init(fusion: DMapFusion.Options = DMapFusion.Options(),
                    align: Bool = true, preferGPU: Bool = true,
                    slabSize: Int = 0, slabOverlap: Int = 0, slabDirectory: URL? = nil,
                    autoExcludeBadFrames: Bool = false,
                    badFrameHandler: (([FrameQualityIssue]) -> Set<Int>)? = nil) {
            self.fusion = fusion
            self.align = align
            self.preferGPU = preferGPU
            self.slabSize = slabSize
            self.slabOverlap = slabOverlap
            self.slabDirectory = slabDirectory
            self.autoExcludeBadFrames = autoExcludeBadFrames
            self.badFrameHandler = badFrameHandler
        }
    }

    /// A fusion result plus, when slabbing was used, the intermediate slab
    /// images — those become the primary retouch sources (each slab is
    /// all-in-focus within its depth range, and the output's depth indexes
    /// slabs). Original frames remain available as secondary retouch sources;
    /// `slabFrameGains` carries the per-frame exposure gains that were baked
    /// into the slabs, so frame stamps match.
    public struct FuseResult {
        public let output: DMapFusion.Output
        public let slabURLs: [URL]?
        public let slabFrameGains: [Float]?
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
                    cancellation: cancellation) { fraction, index, gray, pass in
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
                                                sourceFullWidth: fw, sourceFullHeight: fh))
                    case .register:
                        // Gradient-magnitude image, a derived artifact — show
                        // it output-side, not as if it were a source frame.
                        progress(FusionProgress(stage: .aligning, fraction: fraction,
                                                preview: buffer,
                                                previewFullWidth: fw, previewFullHeight: fh,
                                                sourceFrameIndex: index))
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
        var source = makeSource(urls: fuseURLs, transforms: transforms, log: log)
        var slabURLs: [URL]? = nil
        var slabFrameGains: [Float]? = nil
        if configuration.slabSize >= 2, fuseURLs.count > configuration.slabSize {
            let slabs = try fuseSlabs(source: source, configuration: configuration,
                                      log: log, progress: progress,
                                      cancellation: cancellation)
            slabURLs = slabs.urls
            slabFrameGains = slabs.frameGains
            // Slab images are already aligned and cropped; fuse them as-is.
            source = StackSource(urls: slabs.urls)
        }
        let output: DMapFusion.Output
        if configuration.preferGPU, MetalEngine.shared != nil {
            output = try GPUDMap.fuseWithDepth(source: source, options: configuration.fusion,
                                               log: log, progress: progress,
                                               cancellation: cancellation)
        } else {
            output = try DMapFusion.fuseWithDepth(frameCount: source.count,
                                                  options: configuration.fusion, log: log,
                                                  progress: progress,
                                                  cancellation: cancellation) {
                try source.frame(at: $0)
            }
        }
        progress?(FusionProgress(stage: .finishing, fraction: 1))
        return FuseResult(output: output, slabURLs: slabURLs,
                          slabFrameGains: slabFrameGains,
                          issues: issues, fusedURLs: fuseURLs)
    }

    /// Overlapping slab windows distributed evenly so the first starts at 0 and
    /// the last ends exactly at `count`.
    static func slabRanges(count: Int, size: Int, overlap: Int) -> [Range<Int>] {
        guard count > size else { return [0..<count] }
        let stride = max(1, size - overlap)
        let slabCount = max(2, Int(ceil(Double(count - overlap) / Double(stride))))
        return (0..<slabCount).map { i in
            let start = Int((Double(i) * Double(count - size) / Double(slabCount - 1)).rounded())
            return start..<(start + size)
        }
    }

    /// Pyramid-fuses each slab of aligned frames to a 16-bit TIFF. Exposure
    /// gains (when enabled) are measured per frame against the first frame of
    /// the stack and baked into the slab pixels, so slabs are mutually
    /// comparable; the depth-map pass re-anchors to the geometric mean. The
    /// measured per-frame gains come back too — retouching from an original
    /// frame must apply the same gain its slab absorbed.
    public static func fuseSlabs(source: StackSource, configuration: Configuration,
                                 log: ((String) -> Void)? = nil,
                                 progress: FusionProgressHandler? = nil,
                                 cancellation: CancellationToken? = nil)
        throws -> (urls: [URL], frameGains: [Float]?) {
        let overlap = configuration.slabOverlap > 0
            ? configuration.slabOverlap
            : max(1, configuration.slabSize / 3)
        let ranges = slabRanges(count: source.count, size: configuration.slabSize,
                                overlap: min(overlap, configuration.slabSize - 1))
        let dir = configuration.slabDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("hyperfocal-slabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log?("slabbing: \(ranges.count) slabs of \(configuration.slabSize) frames (overlap \(overlap)) → \(dir.path)")

        // Gain anchor measured up front (one extra decode of frame 0): the
        // frame closure below may be called concurrently by the GPU path's
        // decode prefetcher, so it must not carry cross-call state. Measured
        // on the *unwarped* frame, matching the per-frame measurement below —
        // only the ratio matters, and warping must not enter the CPU path.
        var meanLum0: Float = 1
        if configuration.fusion.normalizeExposure {
            meanLum0 = DMapFusion.meanLuminance(
                pixels: try ImageFile.load(url: source.urls[0]).pixels)
        }
        // Per-frame gains, recorded as slabs consume frames (idempotent for
        // frames shared by overlapping slabs; locked — the closure runs
        // concurrently under the GPU path's prefetcher).
        let gainLock = NSLock()
        var frameGains = [Float](repeating: 1, count: source.count)
        // Output-pane nominal size for slab previews (the slab canvas).
        var fullW = source.outputWidth ?? 0
        var fullH = source.outputHeight ?? 0
        if fullW == 0, let dims = ImageFile.pixelSize(url: source.urls[0]) {
            fullW = dims.width
            fullH = dims.height
        }
        var urls = [URL]()
        for (si, range) in ranges.enumerated() {
            try cancellation?.checkCancelled()
            // Frames decode unwarped in the closure; alignment rides the warp
            // plan (GPU-side when available) instead of Warp.apply per frame.
            let slabWarp = source.transforms.map {
                PyramidWarp(transforms: Array($0[range]),
                            outputWidth: source.outputWidth,
                            outputHeight: source.outputHeight)
            }
            let slab = try PyramidFusion.fuse(frameCount: range.count,
                                              preferGPU: configuration.preferGPU,
                                              warp: slabWarp,
                                              log: log,
                                              progress: { fraction, preview in
                // The forming slab, collapsed at low res (GPU path only) —
                // without this the output pane is empty for the entire slab
                // stage, which can run for minutes on deep stacks.
                guard let progress, let preview else { return }
                progress(FusionProgress(
                    stage: .slabs,
                    fraction: (Double(si) + fraction) / Double(ranges.count),
                    preview: preview,
                    previewFullWidth: fullW, previewFullHeight: fullH))
            },
                                              cancellation: cancellation) { k in
                let fi = range.lowerBound + k
                var frame = try ImageFile.load(url: source.urls[fi])
                if configuration.fusion.normalizeExposure {
                    let mean = DMapFusion.meanLuminance(pixels: frame.pixels)
                    let gain = min(max(meanLum0 / max(mean, 1e-6), 0.5), 2)
                    gainLock.lock()
                    frameGains[fi] = gain
                    gainLock.unlock()
                    if gain != 1 { frame.scaleRGB(by: gain) }
                }
                progress?(FusionProgress(
                    stage: .slabs,
                    fraction: (Double(si) + Double(k + 1) / Double(range.count))
                        / Double(ranges.count),
                    sourceFrameIndex: fi,
                    sourcePreview: frame.downsampledNearest(maxSide: 1200),
                    sourceFullWidth: frame.width, sourceFullHeight: frame.height))
                return frame
            }
            let url = dir.appendingPathComponent(String(format: "slab_%03d.tif", si))
            try ImageFile.save(slab, to: url)
            log?("slab \(si + 1)/\(ranges.count) → \(url.lastPathComponent)")
            urls.append(url)
        }
        return (urls, configuration.fusion.normalizeExposure ? frameGains : nil)
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
