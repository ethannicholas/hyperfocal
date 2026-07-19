import ArgumentParser
import Foundation
import HyperfocalKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(simd)
import simd
#endif
#if os(Windows)
import WinSDK   // GetProcessMemoryInfo for the peak-memory report
#endif

// The CGImage-typed debug helpers (debug-align, debug-source) exist only where
// Apple's imaging stack does; the rest of the CLI is portable.
#if canImport(CoreGraphics)
private let subcommandList: [ParsableCommand.Type] =
    [Fuse.self, Batch.self, Animate.self, Synth.self, Compare.self,
     DebugAlign.self, DebugChain.self,
     DebugWarp.self, DebugDiff.self, DebugBoost.self, DebugSource.self]
#else
private let subcommandList: [ParsableCommand.Type] = {
    var list: [ParsableCommand.Type] =
        [Fuse.self, Batch.self, Animate.self, Synth.self, Compare.self,
         DebugChain.self, DebugWarp.self, DebugDiff.self, DebugBoost.self]
    #if HYPERFOCAL_HAVE_WGPU
    list.append(DebugWgpu.self)
    #endif
    return list
}()
#endif

#if HYPERFOCAL_HAVE_WGPU
struct DebugWgpu: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-wgpu",
        abstract: "Run kernel-level CPU vs wgpu parity checks (build-time opt-in).")

    @Option(help: "Fail below this minimum kernel PSNR in dB.")
    var floor: Double = 90

    @Option(help: "Fail below this minimum CPU↔GPU fusion PSNR in dB.")
    var fusionFloor: Double = 60

    func run() throws {
        let minPSNR = try WgpuParity.run()
        print(String(format: "minimum: %.1f dB (floor %.1f)", minPSNR, floor))
        if minPSNR < floor {
            throw StackError.metal("wgpu parity below floor")
        }
        print("wgpu parity: ALL PASS")
        let fusionMin = try WgpuParity.runFusion()
        print(String(format: "fusion minimum: %.1f dB (floor %.1f)", fusionMin, fusionFloor))
        if fusionMin < fusionFloor {
            throw StackError.metal("wgpu fusion parity below floor")
        }
        print("wgpu fusion: ALL PASS")
    }
}
#endif

@main
struct Hyperfocal: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hyperfocal",
        abstract: "Focus stacking engine.",
        subcommands: subcommandList
    )
}

/// Fusion parameters shared by `fuse` and `batch`.
struct FusionOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Fusion method: dmap or pmax.")
    var method: FusionMethod = .dmap

    @Flag(inversion: .prefixedNo, help: "Register and warp frames before fusing.")
    var align: Bool = true

    @Flag(help: "Drop frames that look bad (flash misfires, failed or poor alignment) and fuse the rest, printing what was excluded.")
    var autoExclude: Bool = false

    @Option(help: "DMap: sharpness smoothing sigma in pixels.")
    var sharpnessSigma: Float = 10

    @Option(help: "DMap: render blend radius in frame-index units.")
    var blendRadius: Float = 1

    @Option(help: "DMap: fraction of p95 sharpness treated as no-signal (halo control).")
    var noiseFloor: Float = 0.05

    @Option(help: "DMap: depth-map median filter radius in pixels (0 disables).")
    var medianRadius: Int = 20

    @Option(help: "DMap: required peak concentration (fraction of a pixel's above-median sharpness within its focus peak) to hold a depth opinion; suppresses bokeh-rim false sharpness on smooth surfaces near glossy subjects. 0 disables.")
    var peakConcentration: Float = 0.5

    @Flag(inversion: .prefixedNo,
          help: "DMap: normalize per-frame exposure flicker before blending.")
    var normalizeExposure: Bool = true

    @Option(help: "DMap: guided-filter window radius in full-resolution pixels.")
    var guidedRadius: Float = 128

    @Option(help: "DMap: guided-filter edge-stop epsilon (guide is normalized, so unit-free; smaller keeps weaker edges).")
    var guidedEps: Float = 1e-3

    @Flag(inversion: .prefixedNo,
          help: "DMap: cache aligned frames in a temp file between fusion passes instead of decoding the stack twice (needs width×height×16 bytes per frame of free disk; output is identical, fusing is just faster). Skipped automatically when the disk is short on space.")
    var diskCache: Bool = true

    @Option(help: "Compute engine: auto (GPU when available), gpu, or cpu.")
    var engine: Engine = .auto

    @Option(help: "Export color space: srgb, p3, or prophoto (the pipeline works in Display P3; DNG always carries P3).")
    var colorSpace: ColorSpaceChoice = .srgb

    var dmapOptions: DMapFusion.Options {
        DMapFusion.Options(sharpnessSigma: sharpnessSigma, blendRadius: blendRadius,
                           noiseFloor: noiseFloor, medianRadius: medianRadius,
                           normalizeExposure: normalizeExposure,
                           peakConcentration: peakConcentration,
                           guidedRadius: guidedRadius, guidedEps: guidedEps,
                           spillEnabled: diskCache)
    }

    func resolveUseGPU() throws -> Bool {
        #if canImport(Metal)
        switch engine {
        case .auto: return MetalEngine.shared != nil
        case .gpu:
            guard MetalEngine.shared != nil else {
                throw ValidationError("no Metal device available")
            }
            return true
        case .cpu: return false
        }
        #elseif HYPERFOCAL_HAVE_WGPU
        // wgpu backend (Windows/Linux): only the pyramid path runs on it so
        // far — DMap ignores this and fuses on the CPU until GPUDMap's port.
        switch engine {
        case .auto: return WgpuEngine.shared != nil
        case .gpu:
            guard WgpuEngine.shared != nil else {
                throw ValidationError("no wgpu adapter available")
            }
            return true
        case .cpu: return false
        }
        #else
        if engine == .gpu { throw ValidationError("GPU engine is not available on this platform") }
        return false
        #endif
    }
}

extension RockingAnimation.Path: ExpressibleByArgument {}

enum FusionMethod: String, ExpressibleByArgument {
    case dmap
    case pmax
}

enum Engine: String, ExpressibleByArgument {
    case auto
    case gpu
    case cpu
}

enum ColorSpaceChoice: String, ExpressibleByArgument {
    case srgb
    case p3
    case prophoto

    #if canImport(CoreGraphics)
    /// nil means "already the working space" — no conversion.
    var cgColorSpace: CGColorSpace? {
        switch self {
        case .srgb: return CGColorSpace(name: CGColorSpace.sRGB)
        case .p3: return nil
        case .prophoto: return CGColorSpace(name: CGColorSpace.rommrgb)
        }
    }
    #endif

    /// Portable export-space token for the non-Apple encode path (lcms2). nil
    /// keeps the Display-P3 working space — same meaning as `cgColorSpace` nil.
    var name: String? {
        switch self {
        case .srgb: return "srgb"
        case .p3: return nil
        case .prophoto: return "prophoto"
        }
    }
}

/// Save a fused result with the CLI's chosen export color space, bridging the
/// per-platform `ImageFile.save` signature (CGColorSpace on Apple, a portable
/// name elsewhere).
func saveFused(_ image: ImageBuffer, to url: URL, sourceFrame: URL?,
               colorSpace: ColorSpaceChoice) throws {
    #if canImport(CoreGraphics)
    try ImageFile.save(image, to: url, sourceFrame: sourceFrame,
                       colorSpace: colorSpace.cgColorSpace)
    #else
    try ImageFile.save(image, to: url, sourceFrame: sourceFrame,
                       colorSpaceName: colorSpace.name)
    #endif
}

func vlog(_ enabled: Bool) -> (String) -> Void {
    { message in
        if enabled { FileHandle.standardError.write(Data(("  " + message + "\n").utf8)) }
    }
}

struct Fuse: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Align and fuse a focus stack into a single image.")

    @Argument(help: "Input images, in focus order.")
    var inputs: [String]

    @Option(name: .shortAndLong, help: "Output image path (.tif, .png, or .jpg).")
    var output: String

    @OptionGroup var fusion: FusionOptions

    @Option(help: "DMap: also write the regularized depth map to this path.")
    var depthMap: String? = nil

    @Flag(name: .shortAndLong, help: "Print progress.")
    var verbose: Bool = false

    func run() throws {
        guard inputs.count >= 2 else {
            throw ValidationError("need at least 2 input images")
        }
        let log = vlog(verbose)
        let clock = ContinuousClock()
        let urls = inputs.map { URL(fileURLWithPath: $0) }

        // Frame-order sanity: inputs are taken as given ("in focus order"),
        // which is usually a shell glob in filename order. If EXIF capture
        // times disagree with that order, say so — a shuffled or interleaved
        // list fuses to garbage silently. Header reads only; cheap next to
        // the fuse itself.
        let captureDates = urls.map(StackSplitter.captureDate(of:))
        if !captureDates.contains(nil),
           StackSplitter.ordered(urls: urls, dates: captureDates,
                                 byCaptureTime: true) != urls {
            print("warning: input order differs from EXIF capture order — "
                  + "if these frames are one stack shot in sequence, reorder "
                  + "them (or check for frames from another stack mixed in)")
        }

        // Frames stream through both passes one at a time; nothing scales with depth.
        var fuseURLs = urls
        var transforms: [simd_float3x3]? = nil
        if fusion.align {
            var registration: Aligner.RegistrationOutput? = nil
            let alignTime = try clock.measure {
                registration = try Aligner.transformsAndQuality(forFrames: urls, log: log)
            }
            print("registered \(urls.count) frames in \(alignTime)")
            let issues = registration!.issues
            for issue in issues {
                print("bad frame \(urls[issue.index].lastPathComponent): \(issue.summary)")
            }
            if fusion.autoExclude && !issues.isEmpty {
                let bad = Set(issues.map(\.index))
                let keptIndices = urls.indices.filter { !bad.contains($0) }
                guard keptIndices.count >= 2 else {
                    throw ValidationError("fewer than 2 usable frames after exclusion")
                }
                fuseURLs = keptIndices.map { urls[$0] }
                transforms = keptIndices.map { registration!.transforms[$0] }
                print("auto-excluded \(bad.count) frame(s); fusing \(fuseURLs.count)")
            } else {
                transforms = registration!.transforms
                if issues.contains(where: {
                    if case .registrationFailed = $0.kind { return true } else { return false }
                }) {
                    throw ValidationError("some frames could not be registered — rerun with --auto-exclude to drop them, or remove them from the input list")
                }
                if !issues.isEmpty {
                    print("warning: fusing flagged frames anyway (use --auto-exclude to drop them)")
                }
            }
        }
        let source = StackPipeline.makeSource(urls: fuseURLs, transforms: transforms, log: log)
        if let w = source.outputWidth, let h = source.outputHeight {
            print("common-coverage canvas: \(w)x\(h)")
        }

        var result: ImageBuffer? = nil
        var depth: ImageBuffer? = nil
        let fuseTime = try clock.measure {
            switch fusion.method {
            case .dmap:
                let opts = fusion.dmapOptions
                let useGPU = try fusion.resolveUseGPU()
                let out: DMapFusion.Output
                #if canImport(Metal)
                if useGPU {
                    print("engine: GPU (\(MetalEngine.shared!.device.name))")
                    out = try GPUDMap.fuseWithDepth(source: source, options: opts, log: log)
                } else {
                    print("engine: CPU")
                    out = try DMapFusion.fuseWithDepth(frameCount: source.count, options: opts,
                                                       log: log) {
                        try source.frame(at: $0)
                    }
                }
                #else
                _ = useGPU
                print("engine: CPU")
                out = try DMapFusion.fuseWithDepth(frameCount: source.count, options: opts,
                                                   log: log) {
                    try source.frame(at: $0)
                }
                #endif
                result = out.image
                depth = out.depthMap
            case .pmax:
                result = try PyramidFusion.fuse(source: source,
                                                preferGPU: try fusion.resolveUseGPU(),
                                                log: log)
            }
        }
        print("fused (\(fusion.method.rawValue)) \(source.count) frames in \(fuseTime)")

        if let path = depthMap {
            if let depth {
                try ImageFile.save(depth, to: URL(fileURLWithPath: path))
                print("wrote depth map \(path)")
            } else {
                print("note: --depth-map is only produced by --method dmap")
            }
        }
        try saveFused(result!, to: URL(fileURLWithPath: output),
                      sourceFrame: fuseURLs.first, colorSpace: fusion.colorSpace)
        print("wrote \(output)")
        #if canImport(Darwin)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let peakGB = Double(usage.ru_maxrss) / 1_073_741_824   // Darwin: bytes
        #elseif os(Windows)
        var counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb)
        let peakGB = Double(counters.PeakWorkingSetSize) / 1_073_741_824
        #else
        var usage = rusage()
        getrusage(RUSAGE_SELF.rawValue, &usage)
        let peakGB = Double(usage.ru_maxrss) / 1_048_576        // Linux: kilobytes
        #endif
        print(String(format: "peak memory: %.2f GB", peakGB))
    }
}

struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Split a session into stacks by capture-time gaps and fuse each one.",
        discussion: "Pass every frame of a shooting session; stacks are detected where consecutive EXIF capture times are more than --gap seconds apart (frames within a burst arrive well under a second apart). Each stack fuses with the same settings; failures don't stop the batch.")

    @Argument(help: "All frames of the session, spanning any number of stacks.")
    var inputs: [String]

    @Option(name: .shortAndLong, help: "Output directory for the fused images.")
    var output: String

    @Option(help: "Start a new stack when consecutive captures are more than this many seconds apart.")
    var gap: Double = 10

    @Option(help: "Output format: tif, png, jpg, or dng.")
    var ext: String = "tif"

    @Flag(help: "Print the proposed stacks and exit without fusing.")
    var dryRun: Bool = false

    @Flag(help: "Order each stack's frames by filename instead of capture time (capture order survives filename-counter rollover).")
    var nameOrder: Bool = false

    @OptionGroup var fusion: FusionOptions

    @Flag(name: .shortAndLong, help: "Print progress.")
    var verbose: Bool = false

    func run() throws {
        guard inputs.count >= 2 else {
            throw ValidationError("need at least 2 input images")
        }
        let log = vlog(verbose)
        let urls = inputs.map { URL(fileURLWithPath: $0) }
        let groups = StackSplitter.split(urls: urls, gap: gap,
                                         orderByCaptureTime: !nameOrder)
        if groups.count == 1 {
            print("no capture-time gaps over \(Int(gap))s found (or timestamps missing) — treating as one stack")
        }
        for (i, group) in groups.enumerated() {
            print("stack \(i + 1): \(group.first!.lastPathComponent) … \(group.last!.lastPathComponent) (\(group.count) frames)")
        }
        if dryRun { return }

        let outDir = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let useGPU = try fusion.resolveUseGPU()
        let clock = ContinuousClock()
        var failures = [String]()
        for (i, group) in groups.enumerated() {
            let label = "stack \(i + 1)/\(groups.count)"
            guard group.count >= 2 else {
                failures.append("\(label): only 1 frame — skipped")
                print("\(label): only 1 frame — skipped")
                continue
            }
            let name = String(format: "stack_%02d_%@.%@", i + 1,
                              group[0].deletingPathExtension().lastPathComponent, ext)
            do {
                var image: ImageBuffer? = nil
                var fusedCount = group.count
                let elapsed = try clock.measure {
                    switch fusion.method {
                    case .dmap:
                        var config = StackPipeline.Configuration(
                            fusion: fusion.dmapOptions, align: fusion.align,
                            preferGPU: useGPU)
                        config.autoExcludeBadFrames = fusion.autoExclude
                        let result = try StackPipeline.fuseResult(urls: group,
                                                                  configuration: config, log: log)
                        for issue in result.issues {
                            print("\(label): bad frame \(group[issue.index].lastPathComponent): \(issue.summary)")
                        }
                        image = result.output.image
                        fusedCount = result.fusedURLs.count
                    case .pmax:
                        var kept = group
                        var transforms: [simd_float3x3]? = nil
                        if fusion.align {
                            let reg = try Aligner.transformsAndQuality(forFrames: group, log: log)
                            for issue in reg.issues {
                                print("\(label): bad frame \(group[issue.index].lastPathComponent): \(issue.summary)")
                            }
                            if fusion.autoExclude, !reg.issues.isEmpty {
                                let bad = Set(reg.issues.map(\.index))
                                let keptIndices = group.indices.filter { !bad.contains($0) }
                                kept = keptIndices.map { group[$0] }
                                transforms = keptIndices.map { reg.transforms[$0] }
                            } else {
                                transforms = reg.transforms
                            }
                        }
                        let source = StackPipeline.makeSource(urls: kept,
                                                              transforms: transforms, log: log)
                        image = try PyramidFusion.fuse(source: source,
                                                       preferGPU: useGPU, log: log)
                        fusedCount = kept.count
                    }
                }
                try saveFused(image!, to: outDir.appendingPathComponent(name),
                              sourceFrame: group.first, colorSpace: fusion.colorSpace)
                print("\(label): wrote \(name) (\(fusedCount) frames, \(elapsed))")
            } catch {
                failures.append("\(label) (\(group[0].lastPathComponent) …): \(error)")
                print("\(label): FAILED — \(error)")
            }
        }
        print("batch done: \(groups.count - failures.count) of \(groups.count) stacks → \(outDir.path)")
        if !failures.isEmpty {
            for failure in failures { print("  \(failure)") }
            throw ExitCode(1)
        }
    }
}

struct Animate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fuse a stack (DMap) and write a Zerene-style rocking animation from its depth plane.")

    @Argument(help: "Input images, in focus order.")
    var inputs: [String]

    @Option(name: .shortAndLong,
            help: "Output path: .mp4 (H.264), or .gif for an animation that loops automatically in every viewer (MP4 has no loop flag players honor).")
    var output: String

    @OptionGroup var fusion: FusionOptions

    @Option(help: "Animation length in seconds.")
    var duration: Double = 3

    @Option(help: "Frames per second.")
    var fps: Double = 30

    @Option(help: "Peak disparity at the depth extremes, as a fraction of the video width.")
    var amplitude: Double = 0.01

    @Option(help: "Motion path: horizontal, vertical, or circular.")
    var path: RockingAnimation.Path = .horizontal

    @Option(help: "Video long side in pixels.")
    var maxSide: Int = 1920

    @Flag(name: .shortAndLong, help: "Print progress.")
    var verbose: Bool = false

    func run() throws {
        guard inputs.count >= 2 else {
            throw ValidationError("need at least 2 input images")
        }
        let log = vlog(verbose)
        let urls = inputs.map { URL(fileURLWithPath: $0) }
        var config = StackPipeline.Configuration(fusion: fusion.dmapOptions,
                                                 align: fusion.align,
                                                 preferGPU: try fusion.resolveUseGPU())
        config.autoExcludeBadFrames = fusion.autoExclude
        let result = try StackPipeline.fuseResult(urls: urls, configuration: config, log: log)
        let options = RockingAnimation.Options(maxSide: maxSide, duration: duration,
                                               fps: fps, amplitude: amplitude,
                                               path: path)
        try RockingAnimation.write(to: URL(fileURLWithPath: output),
                                   image: result.output.image,
                                   depth: result.output.depth,
                                   options: options, log: log)
        print("wrote \(output)")
    }
}

struct Synth: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a synthetic focus stack with ground truth for testing.")

    @Option(name: .shortAndLong) var output: String = "synth"
    @Option var width: Int = 900
    @Option var height: Int = 600
    @Option var frames: Int = 15
    @Option(help: "Max defocus blur sigma in pixels.") var maxBlur: Float = 6
    @Option(help: "Total focus-breathing scale change (0.02 = 2%).") var breathing: Float = 0.02
    @Option(help: "Max per-frame translation jitter in pixels.") var jitter: Float = 3
    @Option(help: "Exposure flicker amplitude (0.1 = ±10% per-frame gain).") var flicker: Float = 0
    @Option(help: "Frame file format: tif, png, or jpg.") var ext: String = "tif"
    @Option(help: "Scene: plane (tilted texture) or object (subject on dark background).")
    var scene: String = "plane"
    @Option(help: "Darken this frame to ~2% (synthetic flash misfire, for bad-frame detection tests).")
    var misfireFrame: Int? = nil
    @Option(help: "Non-rigidly displace this frame (synthetic bumped rail, for bad-frame detection tests).")
    var bumpFrame: Int? = nil
    @Option(help: "Stamp EXIF capture times starting at this Unix epoch (for session-split tests).")
    var captureStart: Double? = nil
    @Option(help: "Seconds between stamped capture times.")
    var captureSpacing: Double = 1
    @Flag(name: .shortAndLong) var verbose: Bool = false

    func run() throws {
        guard let sceneKind = SynthStack.Scene(rawValue: scene) else {
            throw ValidationError("unknown scene '\(scene)' (use plane or object)")
        }
        let reference = (frames % 2 == 0 ? frames + 1 : frames) / 2
        if misfireFrame == reference || bumpFrame == reference {
            throw ValidationError("frame \(reference) is the alignment reference — sabotage a different frame")
        }
        let opts = SynthStack.Options(width: width, height: height, frames: frames,
                                      maxBlur: maxBlur, breathing: breathing, jitter: jitter,
                                      flicker: flicker, scene: sceneKind,
                                      misfireFrame: misfireFrame, bumpFrame: bumpFrame,
                                      captureStart: captureStart.map { Date(timeIntervalSince1970: $0) },
                                      captureSpacing: captureSpacing)
        let dir = URL(fileURLWithPath: output)
        let (truth, frameURLs) = try SynthStack.generate(options: opts, outDir: dir,
                                                         frameExtension: ext,
                                                         log: vlog(verbose))
        print("wrote \(frameURLs.count) frames + ground truth to \(dir.path)")
        print("truth: \(truth.lastPathComponent)")
    }
}

struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compute PSNR between two images.")

    @Argument var imageA: String
    @Argument var imageB: String
    @Option(help: "Crop this many pixels from every edge before comparing.")
    var margin: Int = 32

    func run() throws {
        let a = try ImageFile.load(url: URL(fileURLWithPath: imageA))
        let b = try ImageFile.load(url: URL(fileURLWithPath: imageB))
        if a.width == b.width && a.height == b.height {
            let value = Metrics.psnr(a, b, margin: margin)
            print(String(format: "PSNR: %.2f dB (margin %d)", value, margin))
        } else {
            // Different sizes: the smaller is a crop of the larger (common-
            // coverage cropped output vs full-size reference) — find it.
            let result = Metrics.psnrBestOffset(a, b, margin: margin)
            print(String(format: "PSNR: %.2f dB (margin %d, crop offset %d,%d)",
                         result.psnr, margin, result.dx, result.dy))
        }
    }
}

struct DebugWarp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-warp",
        abstract: "Apply a known similarity transform to an image (content moves by +tx,+ty, top-left coords).",
        shouldDisplay: false)

    @Argument var input: String
    @Option(name: .shortAndLong) var output: String
    @Option var scale: Float = 1
    @Option(help: "Rotation in degrees, positive = clockwise in top-left coords.")
    var rotation: Float = 0
    @Option var tx: Float = 0
    @Option var ty: Float = 0

    func run() throws {
        let img = try ImageFile.load(url: URL(fileURLWithPath: input))
        let center = SIMD2<Float>(Float(img.width) / 2, Float(img.height) / 2)
        let m = Warp.similarity(scale: scale, rotation: rotation * .pi / 180,
                                translation: SIMD2<Float>(tx, ty), center: center)
        let out = Warp.apply(img, outputToSource: m.inverse,
                             outWidth: img.width, outHeight: img.height)
        try ImageFile.save(out, to: URL(fileURLWithPath: output))
        print("wrote \(output)")
    }
}

#if canImport(CoreGraphics)
struct DebugSource: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-source",
        abstract: "Exercise the retouch aligned-source path: register, build the cropped source, decode+warp one frame.",
        shouldDisplay: false)

    @Argument(help: "Stack frames, in focus order.")
    var inputs: [String]

    func run() throws {
        let urls = inputs.map { URL(fileURLWithPath: $0) }
        let clock = ContinuousClock()
        var transforms: [simd_float3x3]? = nil
        let registerTime = try clock.measure {
            transforms = try Aligner.transforms(forFrames: urls)
        }
        print("registered \(urls.count) frames in \(registerTime)")
        let source = StackPipeline.makeSource(urls: urls, transforms: transforms) { print("  \($0)") }
        print("output canvas: \(source.outputWidth ?? -1)x\(source.outputHeight ?? -1)")
        let mid = urls.count / 2
        var frame: ImageBuffer? = nil
        let loadTime = try clock.measure {
            frame = try source.frame(at: mid)
        }
        print("frame \(mid) decode+warp: \(loadTime) → \(frame!.width)x\(frame!.height)")
        let convertTime = clock.measure {
            _ = try? ImageFile.cgImage8(from: frame!)
        }
        print("cgImage8: \(convertTime)")
    }
}
#endif

struct DebugDiff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-diff",
        abstract: "Write amplified |a - b| to visualize where two images differ.",
        shouldDisplay: false)

    @Argument var imageA: String
    @Argument var imageB: String
    @Option(name: .shortAndLong) var output: String
    @Option var gain: Float = 10

    func run() throws {
        let a = try ImageFile.load(url: URL(fileURLWithPath: imageA))
        let b = try ImageFile.load(url: URL(fileURLWithPath: imageB))
        guard a.width == b.width && a.height == b.height else {
            throw ValidationError("size mismatch")
        }
        var out = ImageBuffer(width: a.width, height: a.height)
        for i in out.pixels.indices {
            out.pixels[i] = i % 4 == 3 ? 1 : min(abs(a.pixels[i] - b.pixels[i]) * gain, 1)
        }
        try ImageFile.save(out, to: URL(fileURLWithPath: output))
        print("wrote \(output)")
    }
}

struct DebugBoost: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-boost",
        abstract: "Multiply pixel values to inspect shadow content.",
        shouldDisplay: false)

    @Argument var input: String
    @Option(name: .shortAndLong) var output: String
    @Option var gain: Float = 6

    func run() throws {
        var img = try ImageFile.load(url: URL(fileURLWithPath: input))
        for i in img.pixels.indices where i % 4 != 3 {
            img.pixels[i] = min(img.pixels[i] * gain, 1)
        }
        try ImageFile.save(img, to: URL(fileURLWithPath: output))
        print("wrote \(output)")
    }
}

struct DebugChain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-chain",
        abstract: "Run full-stack registration and print each frame's cumulative transform decomposition.",
        shouldDisplay: false)

    @Argument var inputs: [String]

    @Flag(help: "Also print each pair registration's residual as it lands.")
    var residuals: Bool = false

    func run() throws {
        let urls = inputs.map { URL(fileURLWithPath: $0) }
        let output = try Aligner.transformsAndQuality(forFrames: urls,
                                                      log: residuals ? { print("  \($0)") } : nil)
        for issue in output.issues {
            print("ISSUE frame \(issue.index) (\(urls[issue.index].lastPathComponent)): \(issue.summary)")
        }
        print("frame        scaleX    scaleY    rot°        tx        ty     persp")
        for (i, h) in output.transforms.enumerated() {
            let sx = simd_length(SIMD2<Float>(h[0][0], h[0][1]))
            let sy = simd_length(SIMD2<Float>(h[1][0], h[1][1]))
            let rot = atan2(h[0][1], h[0][0]) * 180 / .pi
            let persp = max(abs(h[0][2]), abs(h[1][2]))
            print(String(format: "%3d %@ %9.5f %9.5f %7.3f %9.2f %9.2f %9.6f",
                         i, urls[i].lastPathComponent.padding(toLength: 12, withPad: " ", startingAt: 0),
                         sx, sy, rot, h[2][0], h[2][1], persp))
        }
    }
}

#if canImport(CoreGraphics)
struct DebugAlign: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-align",
        abstract: "Register two images and print the recovered homography.",
        shouldDisplay: false)

    @Argument var fixed: String
    @Argument var moving: String

    func run() throws {
        let f = try ImageFile.load(url: URL(fileURLWithPath: fixed))
        let m = try ImageFile.load(url: URL(fileURLWithPath: moving))
        let h = try Aligner.register(moving: try ImageFile.cgImage8(from: m),
                                     fixed: try ImageFile.cgImage8(from: f))
        for r in 0..<3 {
            let row = SIMD3<Float>(h[0][r], h[1][r], h[2][r])
            print(String(format: "  [%9.5f %9.5f %12.4f]", row.x, row.y, row.z))
        }
    }
}

#endif
