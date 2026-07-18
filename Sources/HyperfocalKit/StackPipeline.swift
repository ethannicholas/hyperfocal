import Foundation
#if canImport(simd)
import simd
#endif

/// One-call orchestration of the full stack → fused image pipeline, shared by
/// the CLI and the app.
public enum StackPipeline {

    public struct Configuration {
        public var fusion: DMapFusion.Options
        public var align: Bool
        public var preferGPU: Bool
        /// When registration flags bad frames (misfires, failed alignment),
        /// exclude them all and fuse the rest. Overridden by `badFrameHandler`.
        public var autoExcludeBadFrames: Bool
        /// Decides which flagged frames to exclude (called on the fusion thread
        /// with the issues; return the frame indices to drop). Lets a UI ask
        /// the user mid-fuse. nil → `autoExcludeBadFrames` excludes all or none.
        public var badFrameHandler: (([FrameQualityIssue]) -> Set<Int>)?

        public init(fusion: DMapFusion.Options = DMapFusion.Options(),
                    align: Bool = true, preferGPU: Bool = true,
                    autoExcludeBadFrames: Bool = false,
                    badFrameHandler: (([FrameQualityIssue]) -> Set<Int>)? = nil) {
            self.fusion = fusion
            self.align = align
            self.preferGPU = preferGPU
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
        let source = makeSource(urls: fuseURLs, transforms: transforms, log: log)
        let output: DMapFusion.Output
        #if canImport(Metal)
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
        #else
        output = try DMapFusion.fuseWithDepth(frameCount: source.count,
                                              options: configuration.fusion, log: log,
                                              progress: progress,
                                              cancellation: cancellation) {
            try source.frame(at: $0)
        }
        #endif
        progress?(FusionProgress(stage: .finishing, fraction: 1))
        return FuseResult(output: output, issues: issues, fusedURLs: fuseURLs)
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
